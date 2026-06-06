class_name VoxelWorld
extends Node3D

# The 3D voxel grid for ASAS. Each cell holds a material; air cells are simply
# absent from `cells`. Owns the cube meshes and exposes queries/mutations the
# game logic uses (dig, clear, walkability). World units == grid units (1 cube).

enum Mat { AIR, EARTH, WATER, GOLD, CRYSTAL, RELIC }

const SX := 10        # footprint width  (x)
const SZ := 10        # footprint depth  (z)
const SY := 9         # total height     (y, up)
const GROUND := 4     # top solid layer (y = 0..GROUND are solid by default)
# Underground treasure budget. Tiers escalate: Gold → +1 energy, Crystal → +2
# energy + draw a card, Relic → random upgrade card straight into the hand.
const GOLD_POCKETS := 14
const CRYSTAL_POCKETS := 6
const RELIC_POCKETS := 2

var cells := {}                 # Vector3i -> Mat (non-air only)
var cube_nodes := {}            # Vector3i -> MeshInstance3D
var cubes_root: Node3D
var _box: BoxMesh
var _mats := {}                 # Mat -> StandardMaterial3D
var skip_3d_rendering: bool = false   # set before add_child for 2D views

func _ready() -> void:
	generate()
	if not skip_3d_rendering:
		cubes_root = Node3D.new()
		add_child(cubes_root)
		_box = BoxMesh.new()
		_box.size = Vector3(0.96, 0.96, 0.96)
		_build_materials()
		rebuild()

func _build_materials() -> void:
	_mats[Mat.EARTH] = _make_mat(Color(0.46, 0.33, 0.22))
	_mats[Mat.GOLD] = _make_mat(Color(0.95, 0.78, 0.18))
	_mats[Mat.WATER] = _make_mat(Color(0.25, 0.5, 0.85))
	_mats[Mat.CRYSTAL] = _make_mat(Color(0.45, 0.78, 1.00))
	_mats[Mat.RELIC] = _make_mat(Color(0.82, 0.38, 0.95))

func _make_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m

# ---------------------------------------------------------------- generation

func generate() -> void:
	cells.clear()
	for x in SX:
		for z in SZ:
			for y in range(0, GROUND + 1):
				cells[Vector3i(x, y, z)] = Mat.EARTH
	for i in GOLD_POCKETS:
		var p := Vector3i(randi() % SX, randi() % GROUND, randi() % SZ)
		cells[p] = Mat.GOLD
	for i in CRYSTAL_POCKETS:
		var p := Vector3i(randi() % SX, randi() % GROUND, randi() % SZ)
		cells[p] = Mat.CRYSTAL
	for i in RELIC_POCKETS:
		var p := Vector3i(randi() % SX, randi() % GROUND, randi() % SZ)
		cells[p] = Mat.RELIC

# ---------------------------------------------------------------- queries

func in_bounds(p: Vector3i) -> bool:
	return p.x >= 0 and p.x < SX and p.y >= 0 and p.y < SY and p.z >= 0 and p.z < SZ

func material_at(p: Vector3i) -> int:
	return cells.get(p, Mat.AIR)

func is_solid(p: Vector3i) -> bool:
	var m: int = material_at(p)
	return m == Mat.EARTH or m == Mat.GOLD or m == Mat.CRYSTAL or m == Mat.RELIC

func is_air(p: Vector3i) -> bool:
	return in_bounds(p) and material_at(p) == Mat.AIR

# A cell a unit can stand in: in-bounds air with solid ground directly below
# (the floor at the very bottom counts as solid).
func is_standable(p: Vector3i) -> bool:
	if not is_air(p):
		return false
	if p.y == 0:
		return true
	return is_solid(p + Vector3i(0, -1, 0))

# Highest standable cell in a column (where a unit rests on the surface).
func surface_cell(x: int, z: int) -> Vector3i:
	for y in range(SY - 1, -1, -1):
		var p := Vector3i(x, y, z)
		if is_standable(p):
			return p
	return Vector3i(x, GROUND + 1, z)

func world_pos(p: Vector3i) -> Vector3:
	return Vector3(p.x + 0.5, p.y, p.z + 0.5)

func center() -> Vector3:
	return Vector3(SX * 0.5, GROUND, SZ * 0.5)

# ---------------------------------------------------------------- mutations

# Remove a solid cell; returns the material that was there (for bonuses).
func dig_cell(p: Vector3i) -> int:
	var m: int = material_at(p)
	if m == Mat.EARTH or m == Mat.GOLD or m == Mat.CRYSTAL or m == Mat.RELIC:
		set_material(p, Mat.AIR)
	return m

func set_material(p: Vector3i, m: int) -> void:
	if not in_bounds(p):
		return
	if m == Mat.AIR:
		cells.erase(p)
	else:
		cells[p] = m
	_refresh_cube(p)

# ---------------------------------------------------------------- rendering

func rebuild() -> void:
	for c in cube_nodes.values():
		c.queue_free()
	cube_nodes.clear()
	for p in cells:
		_make_cube(p)

func _refresh_cube(p: Vector3i) -> void:
	if skip_3d_rendering:
		return
	if cube_nodes.has(p):
		cube_nodes[p].queue_free()
		cube_nodes.erase(p)
	if cells.has(p):
		_make_cube(p)

func _make_cube(p: Vector3i) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _box
	mi.material_override = _mats.get(cells[p], _mats[Mat.EARTH])
	mi.position = world_pos(p) + Vector3(0, 0.5, 0)
	cubes_root.add_child(mi)
	cube_nodes[p] = mi
