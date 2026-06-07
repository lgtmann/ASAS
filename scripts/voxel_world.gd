class_name VoxelWorld
extends Node3D

# The 3D voxel grid for ASAS. Each cell holds a material; air cells are simply
# absent from `cells`. Owns the cube meshes and exposes queries/mutations the
# game logic uses (dig, clear, walkability). World units == grid units (1 cube).

enum Mat { AIR, EARTH, WATER, GOLD, CRYSTAL, RELIC, OIL, STONE, TREE }

const SX := 16        # footprint width  (x)  — RTS-scale map
const SZ := 16        # footprint depth  (z)
const SY := 9         # total height     (y, up)
const GROUND := 4     # top solid layer (y = 0..GROUND are solid by default)
# Underground treasure budget — tier counts scale roughly with map area.
# Gold → +1 energy, Crystal → +2 energy + 1 card, Relic → random upgrade card.
# Oil is a stockpiled strategic resource (accumulates, unlocks advanced gear).
const GOLD_POCKETS := 32
const CRYSTAL_POCKETS := 12
const RELIC_POCKETS := 4
const OIL_POCKETS := 16
const STONE_PIECES := 6        # surface boulders (+1 height)
const TREE_PIECES := 12        # surface trees (chop for +1 wood)

var cells := {}                 # Vector3i -> Mat (non-air only)
var cube_nodes := {}            # Vector3i -> MeshInstance3D
var cubes_root: Node3D
var _box: BoxMesh
var _mats := {}                 # Mat -> StandardMaterial3D
var skip_3d_rendering: bool = false   # set before add_child for 2D views
# Each water cell's local flow direction (Vector3i; cardinal +/-X / +/-Z).
# When the river is diverted (via dig), new water cells inherit the direction
# of the adjacent water cell they were spread from.
var water_flow: Dictionary = {}
# Starting cell(s) of every river — connectivity BFS uses these. If a water
# cell can't be reached by following flow from a source, it dries to AIR.
var water_sources: Array = []
const TREE_HEIGHT := 3            # cells tall — bottom 2 = full trunk, top = trunk + canopy

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
	_mats[Mat.OIL] = _make_mat(Color(0.15, 0.12, 0.08))
	_mats[Mat.STONE] = _make_mat(Color(0.55, 0.55, 0.58))
	_mats[Mat.TREE] = _make_mat(Color(0.30, 0.45, 0.22))

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
	for i in OIL_POCKETS:
		# Oil sits deeper than other treasures — you have to dig for it.
		var p := Vector3i(randi() % SX, randi() % (GROUND - 1), randi() % SZ)
		cells[p] = Mat.OIL
	# Cut the river FIRST so surface scatter can skip its columns.
	_generate_river()
	# Boulders sit on the surface (y = GROUND + 1). Trees are 3 cells tall.
	for i in STONE_PIECES:
		var x: int = randi() % SX
		var z: int = randi() % SZ
		if _is_safe_zone(x, z):
			continue
		var p := Vector3i(x, GROUND + 1, z)
		if cells.has(p) or _column_has_water(x, z):
			continue
		cells[p] = Mat.STONE
	for i in TREE_PIECES:
		var x: int = randi() % SX
		var z: int = randi() % SZ
		if _is_safe_zone(x, z):
			continue
		if _column_has_water(x, z):
			continue
		var any_taken := false
		for dy in TREE_HEIGHT:
			if cells.has(Vector3i(x, GROUND + 1 + dy, z)):
				any_taken = true
				break
		if any_taken:
			continue
		for dy in TREE_HEIGHT:
			cells[Vector3i(x, GROUND + 1 + dy, z)] = Mat.TREE

func _column_has_water(x: int, z: int) -> bool:
	for y in range(SY):
		if cells.get(Vector3i(x, y, z), Mat.AIR) == Mat.WATER:
			return true
	return false

# Wander a river path from one random map edge to the opposite edge at the
# standable air layer (y = GROUND + 1). Each step is biased toward the target
# but can sidestep, so the river snakes a bit. Tree/stone cells along the way
# get overwritten with water.
func _generate_river() -> void:
	water_flow.clear()
	water_sources.clear()
	# River runs in a trench cut into the top earth layer — y = GROUND. The
	# air above (GROUND + 1) stays open so the trench reads visually as a ditch.
	var y: int = GROUND
	var horiz: bool = (randi() & 1) == 1
	var start: Vector3i
	var end: Vector3i
	if horiz:
		var sz: int = randi() % SZ
		var ez: int = randi() % SZ
		start = Vector3i(0, y, sz)
		end = Vector3i(SX - 1, y, ez)
	else:
		var sx: int = randi() % SX
		var ex: int = randi() % SX
		start = Vector3i(sx, y, 0)
		end = Vector3i(ex, y, SZ - 1)
	water_sources.append(start)
	var cur: Vector3i = start
	var safety: int = SX * SZ
	while safety > 0:
		safety -= 1
		var step: Vector3i = _river_step(cur, end)
		cells[cur] = Mat.WATER
		water_flow[cur] = step
		if cur == end:
			break
		cur += step
		if not in_bounds(cur):
			break

# Walk the river from every source, dropping any water cell that the flow
# graph can no longer reach. Call after any terrain change that touches water
# (a dam, a diversion). Returns the dropped cells so the caller can notice.
func recompute_water_flow() -> Array:
	var live: Dictionary = {}
	var queue: Array = []
	for s in water_sources:
		if is_water(s):
			live[s] = true
			queue.append(s)
	while not queue.is_empty():
		var cur: Vector3i = queue.pop_front()
		var flow: Vector3i = water_flow.get(cur, Vector3i.ZERO)
		if flow == Vector3i.ZERO:
			continue
		var nxt: Vector3i = cur + flow
		if is_water(nxt) and not live.has(nxt):
			live[nxt] = true
			queue.append(nxt)
	var dropped: Array = []
	for cell_v in water_flow.keys():
		var cell: Vector3i = cell_v
		if not live.has(cell):
			set_material(cell, Mat.AIR)
			water_flow.erase(cell)
			dropped.append(cell)
	return dropped

func _river_step(cur: Vector3i, target: Vector3i) -> Vector3i:
	var dx: int = signi(target.x - cur.x)
	var dz: int = signi(target.z - cur.z)
	var ax: int = absi(target.x - cur.x)
	var az: int = absi(target.z - cur.z)
	if ax == 0 and az == 0:
		return Vector3i(0, 0, 1)
	# Probability of an x-step is proportional to the remaining x distance.
	if randf() < float(ax) / float(ax + az):
		if dx != 0:
			return Vector3i(dx, 0, 0)
	if dz != 0:
		return Vector3i(0, 0, dz)
	if dx != 0:
		return Vector3i(dx, 0, 0)
	return Vector3i(0, 0, 1)

func _is_safe_zone(x: int, z: int) -> bool:
	# 5x5 buffer around each starting base corner.
	if x <= 4 and z <= 4:
		return true
	if x >= SX - 5 and z >= SZ - 5:
		return true
	return false

# ---------------------------------------------------------------- queries

func in_bounds(p: Vector3i) -> bool:
	return p.x >= 0 and p.x < SX and p.y >= 0 and p.y < SY and p.z >= 0 and p.z < SZ

func material_at(p: Vector3i) -> int:
	return cells.get(p, Mat.AIR)

func is_solid(p: Vector3i) -> bool:
	var m: int = material_at(p)
	return m == Mat.EARTH or m == Mat.GOLD or m == Mat.CRYSTAL or m == Mat.RELIC \
			or m == Mat.OIL or m == Mat.STONE or m == Mat.TREE

func is_air(p: Vector3i) -> bool:
	return in_bounds(p) and material_at(p) == Mat.AIR

func is_water(p: Vector3i) -> bool:
	return in_bounds(p) and material_at(p) == Mat.WATER

# A cell a unit can pass through (not solid). Air OR water — water cells are
# walk-into-able; the current pushes you on the next end-of-turn tick.
func is_passable(p: Vector3i) -> bool:
	if not in_bounds(p):
		return false
	var m: int = material_at(p)
	return m == Mat.AIR or m == Mat.WATER

# A cell a unit can stand in: passable with solid ground directly below
# (the floor at the very bottom counts as solid).
func is_standable(p: Vector3i) -> bool:
	if not is_passable(p):
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
	if m == Mat.EARTH or m == Mat.GOLD or m == Mat.CRYSTAL or m == Mat.RELIC \
			or m == Mat.OIL or m == Mat.STONE or m == Mat.TREE:
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
