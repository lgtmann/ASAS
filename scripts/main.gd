extends Node3D

# ASAS orchestrator (point-and-click): builds the 3D world, lighting, orbit
# camera, unit/spade views, wireframe target highlights, and a context HUD that
# shows the leader's hand or the selected operator's actions. Left-click selects
# a unit or acts on a highlighted cell; right-drag orbits the camera.

var world: VoxelWorld
var rig: Node3D
var gs: GameState

var units_root: Node3D
var highlight_root: Node3D
var wire_mesh: ArrayMesh

var hud: CanvasLayer
var info_label: Label
var status_label: Label
var end_turn_btn: Button
var context_buttons: Array = []

var mode: String = ""          # "", move, dig, swing, throw
var targets: Array = []        # highlighted cells for the current mode

const TEAM_COLORS := [Color(0.3, 0.6, 1.0), Color(1.0, 0.4, 0.35)]
const LEADER_COLOR := Color(0.95, 0.8, 0.2)
const MODE_COLORS := {
	"move": Color(0.35, 1.0, 0.45),
	"dig": Color(1.0, 0.6, 0.15),
	"swing": Color(1.0, 0.4, 0.3),
	"throw": Color(0.35, 0.85, 1.0),
}

func _ready() -> void:
	world = VoxelWorld.new()
	add_child(world)
	_build_environment()

	rig = Node3D.new()
	rig.set_script(load("res://scripts/camera_rig.gd"))
	rig.position = world.center()
	add_child(rig)

	units_root = Node3D.new()
	add_child(units_root)
	highlight_root = Node3D.new()
	add_child(highlight_root)
	wire_mesh = _build_wire_mesh()

	gs = GameState.new()
	gs.setup(world)
	gs.changed.connect(_refresh_all)
	gs.notice.connect(_on_notice)

	_build_hud()        # before start(): begin_turn emits `changed` -> populates HUD
	gs.start()
	_select(gs.selected)

func _build_environment() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-52, -40, 0)
	light.light_energy = 1.1
	add_child(light)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.68, 0.85)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

# ---------------------------------------------------------------- selection / mode

func _select(u) -> void:
	mode = "move" if (u != null and u.team == 0) else ""
	gs.select(u)                      # emits changed -> _refresh_all

func _set_mode(m: String) -> void:
	mode = m
	_refresh_all()

func _targets_for_mode() -> Array:
	var u = gs.selected
	if u == null or u.team != 0:
		return []
	match mode:
		"move": return gs.move_targets(u)
		"dig": return gs.dig_targets(u)
		"swing": return gs.swing_targets(u)
		"throw": return gs.throw_targets(u)
	return []

func _refresh_all() -> void:
	_rebuild_units()
	targets = _targets_for_mode()
	_rebuild_highlights()
	_refresh_context()
	_refresh_info()

# ---------------------------------------------------------------- input / picking

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_on_click()

func _on_click() -> void:
	var cam: Camera3D = rig.cam
	if cam == null:
		return
	var mp := get_viewport().get_mouse_position()
	var from := cam.project_ray_origin(mp)
	var dir := cam.project_ray_normal(mp)

	# 1. A highlighted target cell takes priority (so you can attack a unit on it).
	var cell = _pick_cell(from, dir)
	if cell != null:
		_act_on(cell)
		return
	# 2. Otherwise select whatever unit was clicked.
	var u = _pick_unit(from, dir)
	if u != null:
		_select(u)

func _pick_cell(from: Vector3, dir: Vector3):
	var to := from + dir * 1000.0
	var best = null
	var best_d := INF
	for c in targets:
		var box := AABB(Vector3(c), Vector3.ONE)
		if box.intersects_segment(from, to):
			var d := from.distance_to(Vector3(c) + Vector3(0.5, 0.5, 0.5))
			if d < best_d:
				best_d = d
				best = c
	return best

func _pick_unit(from: Vector3, dir: Vector3):
	var to := from + dir * 1000.0
	var best = null
	var best_d := INF
	for u in gs.units:
		if not u.is_alive():
			continue
		var box := AABB(Vector3(u.grid), Vector3(1, 1.4, 1))
		if box.intersects_segment(from, to):
			var d := from.distance_to(Vector3(u.grid) + Vector3(0.5, 0.5, 0.5))
			if d < best_d:
				best_d = d
				best = u
	return best

func _act_on(cell: Vector3i) -> void:
	var u = gs.selected
	if u == null:
		return
	match mode:
		"move": gs.move_to(u, cell)
		"dig": gs.dig(u)
		"swing": gs.swing_at(u, cell)
		"throw": gs.throw_at(u, cell)
	# gs.* emits changed -> _refresh_all recomputes targets for the same mode.

# ---------------------------------------------------------------- 3D views

func _rebuild_units() -> void:
	for c in units_root.get_children():
		c.queue_free()
	for u in gs.units:
		if u.is_alive():
			_make_unit_view(u)
	for s in gs.dropped:
		_make_dropped_spade(s)

func _make_unit_view(u) -> void:
	var node := Node3D.new()
	node.position = world.world_pos(u.grid)
	units_root.add_child(node)

	var body := MeshInstance3D.new()
	var col: Color
	if u.kind == "leader":
		var cap := CapsuleMesh.new()
		cap.radius = 0.33
		cap.height = 1.3
		body.mesh = cap
		body.position = Vector3(0, 0.75, 0)
		col = LEADER_COLOR
	else:
		var cap := CapsuleMesh.new()
		cap.radius = 0.28
		cap.height = 0.9
		body.mesh = cap
		body.position = Vector3(0, 0.55, 0)
		col = TEAM_COLORS[u.team]
	if u == gs.selected:
		col = col.lightened(0.3)
	body.material_override = _mat(col)
	node.add_child(body)

	# Leader gets a little crown to read as distinct.
	if u.kind == "leader":
		var crown := MeshInstance3D.new()
		var cb := BoxMesh.new()
		cb.size = Vector3(0.5, 0.18, 0.5)
		crown.mesh = cb
		crown.position = Vector3(0, 1.55, 0)
		crown.material_override = _mat(Color(1.0, 0.92, 0.4))
		node.add_child(crown)

	if u.spade != null:
		var sp := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(0.08, 0.7, 0.08)
		sp.mesh = sb
		sp.position = Vector3(0.32, 0.5, 0)
		sp.material_override = _mat(Color(0.85, 0.85, 0.9))
		node.add_child(sp)

	if u == gs.selected:
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.42
		tm.outer_radius = 0.52
		ring.mesh = tm
		ring.position = Vector3(0, 0.05, 0)
		ring.material_override = _mat(Color(1, 1, 0.3))
		node.add_child(ring)

func _make_dropped_spade(s) -> void:
	var sp := MeshInstance3D.new()
	var sb := BoxMesh.new()
	sb.size = Vector3(0.7, 0.08, 0.12)
	sp.mesh = sb
	sp.position = world.world_pos(s.grid) + Vector3(0, 0.06, 0)
	sp.material_override = _mat(Color(0.75, 0.75, 0.8))
	units_root.add_child(sp)

func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m

# ---------------------------------------------------------------- highlights

func _build_wire_mesh() -> ArrayMesh:
	var corners := [
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
		Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1),
	]
	var edges := [[0,1],[1,2],[2,3],[3,0],[4,5],[5,6],[6,7],[7,4],[0,4],[1,5],[2,6],[3,7]]
	var verts := PackedVector3Array()
	for e in edges:
		verts.append(corners[e[0]])
		verts.append(corners[e[1]])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	return m

func _wire_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.no_depth_test = true          # always visible (e.g. the dig cell underground)
	return m

func _rebuild_highlights() -> void:
	for c in highlight_root.get_children():
		c.queue_free()
	var mat := _wire_material(MODE_COLORS.get(mode, Color.WHITE))
	for cell in targets:
		var mi := MeshInstance3D.new()
		mi.mesh = wire_mesh
		mi.material_override = mat
		mi.position = Vector3(cell)
		highlight_root.add_child(mi)

# ---------------------------------------------------------------- HUD

func _build_hud() -> void:
	hud = CanvasLayer.new()
	add_child(hud)
	info_label = _label(Vector2(12, 10))
	status_label = _label(Vector2(12, 36))
	_label(Vector2(12, 62)).text = "Left-click a unit to select; click a highlighted cell to act. Right-drag orbits, wheel zooms."
	end_turn_btn = Button.new()
	end_turn_btn.text = "End Turn"
	end_turn_btn.position = Vector2(12, 92)
	end_turn_btn.size = Vector2(110, 32)
	end_turn_btn.pressed.connect(func(): gs.end_turn())
	hud.add_child(end_turn_btn)

	var view_btn := Button.new()
	view_btn.text = "Switch to 2.5D"
	view_btn.position = Vector2(1460, 12)
	view_btn.size = Vector2(128, 32)
	view_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main.tscn"))
	hud.add_child(view_btn)

func _label(pos: Vector2) -> Label:
	var l := Label.new()
	l.position = pos
	hud.add_child(l)
	return l

func _refresh_info() -> void:
	if info_label == null:
		return
	var u = gs.selected
	var who := "none"
	if u != null:
		var held := "spade" if u.spade != null else "no spade"
		who = "%s  HP %d/%d  (%s)" % [u.kind, u.hp, u.max_hp, held]
	info_label.text = "Turn %d   Energy %d/%d   Selected: %s   [mode: %s]" % \
		[gs.turn, gs.energy, GameState.MAX_ENERGY, who, mode if mode != "" else "—"]

func _refresh_context() -> void:
	for b in context_buttons:
		b.queue_free()
	context_buttons.clear()
	var u = gs.selected
	if u == null or u.team != 0:
		return
	var x := 12.0
	var y := 840.0
	if u.kind == "leader":
		# Leader: its hand of cards (no spade actions) + a move option.
		x = _ctx_button("Move", x, y, func(): _set_mode("move"))
		for card in gs.hand:
			var b := Button.new()
			b.text = "%s\n%d e" % [card["title"], card["cost"]]
			b.position = Vector2(x, y - 6)
			b.size = Vector2(118, 40)
			b.disabled = card["cost"] > gs.energy
			b.pressed.connect(_on_card.bind(card))
			hud.add_child(b)
			context_buttons.append(b)
			x += 126.0
	else:
		# Operator: its spade actions (no hand).
		x = _ctx_button("Move", x, y, func(): _set_mode("move"))
		x = _ctx_button("Dig", x, y, func(): _set_mode("dig"))
		x = _ctx_button("Swing", x, y, func(): _set_mode("swing"))
		x = _ctx_button("Throw", x, y, func(): _set_mode("throw"))
		x = _ctx_button("Pick Up", x, y, func(): gs.pickup(gs.selected))
		x = _ctx_button("Special", x, y, func(): gs.special(gs.selected))

func _ctx_button(text: String, x: float, y: float, cb: Callable) -> float:
	var b := Button.new()
	b.text = text
	b.position = Vector2(x, y)
	b.size = Vector2(88, 34)
	if text.to_lower() == mode:
		b.modulate = Color(1.0, 1.0, 0.5)
	b.pressed.connect(cb)
	hud.add_child(b)
	context_buttons.append(b)
	return x + 92.0

func _on_card(card) -> void:
	gs.play_card(card)

func _on_notice(text: String) -> void:
	if status_label != null:
		status_label.text = text
