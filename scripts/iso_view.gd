extends Node2D

# ASAS 2.5D isometric view: data-compatible with the 3D `main.gd` — both share
# `VoxelWorld` + `GameState`. Draws solid cubes back-to-front (top + 2 shaded
# side faces), renders wireframe iso-diamond highlights for the action target
# set, and picks targets via point-in-polygon hit-tests. No camera orbit;
# fixed iso angle keeps clicks predictable.

const TILE_W := 64.0
const TILE_H := 32.0
const HEIGHT_STEP := 22.0

const MODE_COLORS := {
	"move": Color(0.40, 1.00, 0.50),
	"dig": Color(1.00, 0.60, 0.15),
	"swing": Color(1.00, 0.40, 0.30),
	"throw": Color(0.35, 0.85, 1.00),
	"place_operator": Color(0.55, 0.90, 1.00),
	"upgrade": Color(1.00, 0.45, 1.00),
}

# --- Card UI (frame + art + labels composite) -------------------------------
const CARD_W := 144.0
const CARD_H := 216.0
const CARDS_DIR := "res://assets/cards/"
# Cards from this hand row sit at y = HAND_Y; action buttons + level controls
# sit BELOW at y = ACTION_Y so a leader can see hand + Move at once.
const HAND_Y := 624.0
# Per-category frame tint (the same frame texture, modulated to match
# category color). Keeps the wood-tone aesthetic but signals card type.
const CATEGORY_TINT := {
	"unit": Color(1.00, 0.95, 0.70),
	"spade": Color(1.00, 1.00, 1.00),
	"head": Color(0.85, 0.95, 1.00),
	"shaft": Color(0.92, 1.00, 0.88),
	"handle": Color(1.00, 0.90, 0.75),
	"operator_upgrade": Color(1.00, 0.85, 0.85),
}
# Layout proportions inside the 2:3 card (matches the frame prompt I wrote).
# Cost sits on the gem (top-left); title is centred across the whole plaque so
# it reads centred on the card rather than offset right of the gem.
const COST_RECT := Rect2(0.02, 0.02, 0.17, 0.14)          # gem
const TITLE_RECT := Rect2(0.10, 0.03, 0.80, 0.12)         # full plaque, centred
const ART_RECT := Rect2(0.10, 0.17, 0.80, 0.50)           # keyhole
const BLURB_RECT := Rect2(0.09, 0.70, 0.82, 0.22)         # parchment

var _card_textures: Dictionary = {}     # cache: id -> Texture2D (or null)
const TEAM_COLORS := [Color(0.30, 0.55, 1.0), Color(1.0, 0.40, 0.35)]
const LEADER_COLOR := Color(0.96, 0.78, 0.20)

var world: VoxelWorld
var gs: GameState
var origin: Vector2 = Vector2(800, 280)
var mode: String = ""
var targets: Array = []
var pending_card = null            # card that's mid-placement (Operator)

# Cosmetic in-flight spade projectiles. Each: {from, to, t, dur, boomerang}.
# A one-way throw runs t in [0, 1]; a boomerang runs t in [0, 2] (out then back).
var projectiles: Array = []
const THROW_DUR := 0.45             # seconds per leg (boomerang = 2 legs)
const THROW_ARC := 36.0             # pixel lift at the apex

# Camera-ish state (we use Node2D scale/position for pan+zoom).
var zoom: float = 1.0
const ZOOM_MIN := 0.5
const ZOOM_MAX := 2.2
const ZOOM_STEP := 1.12

# Camera pan: middle-mouse drag, or WASD / arrow keys.
var _panning: bool = false
const PAN_SPEED := 720.0   # screen-pixels per second at zoom 1.0

# Level viewer: cubes at view_level are fully opaque. Layers BELOW fade modestly
# (depth cue, still solid). Layers ABOVE render as WIREFRAME ONLY — only the
# cube edges are drawn, so you see right through them to ops on the focal
# level. Units render at full alpha regardless, so an op on any layer reads.
var view_level: int = VoxelWorld.GROUND
# Last cube-level we auto-followed the selected unit to. Lets us re-sync the
# view ONLY when the unit's y changes (so Level +/- buttons still work the
# rest of the time without snapping back).
var _last_selected_level: int = -999
const FADE_BELOW := 0.32                # one+ levels below focal
const FOG_COLOR := Color(0.66, 0.66, 0.70)   # unseen cube color
const WIRE_ALPHA := 0.55                # outline strength for above-focal cubes
const WIRE_WIDTH := 1.4                 # outline thickness for wireframe cubes

# Filled in _ready (enum values aren't constexpr for a const dict).
var _mat_colors := {}

var hud: CanvasLayer
var info_label: Label
var status_label: Label
var hint_label: Label
var end_turn_btn: Button
var view_btn: Button
var level_up_btn: Button
var level_dn_btn: Button
var level_label: Label
var draw_pile_panel: Panel
var draw_pile_label: Label
var discard_pile_panel: Panel
var discard_pile_label: Label
var sim_btn: Button
var restart_btn: Button
var context_buttons: Array = []
var _pending_anim_count: int = 0       # newly-drawn cards to slide in
var _ai_running: bool = false          # locks player input while AI is acting

# Combo system: clicking a card toggles it in `selected_cards`; click a valid
# target tile to play the combo (cards rise → merge into a ball → ball arcs to
# the target → operator spawns).
var selected_cards: Array = []
var _combo_animating: bool = false
var ball_overlay: BallOverlay
var _moves_in_flight: int = 0           # > 0 → queue_redraw every frame to follow lerp

# Earthquake animation: when gs emits quake_started, every solid cube whose
# (x, z) column is in this dict bounces with a random phase, amplitude decaying
# quadratically to zero over QUAKE_DUR seconds. Then the visual settles.
var _quake_columns: Dictionary = {}     # Vector2i -> phase offset (radians)
var _quake_t: float = 0.0
const QUAKE_DUR := 0.85
const QUAKE_AMP := 28.0                 # peak vertical screen-pixel offset
const QUAKE_FREQ := 28.0                # rad/sec (≈4.5 cycles/sec)

func _ready() -> void:
	world = VoxelWorld.new()
	world.skip_3d_rendering = true
	add_child(world)

	_mat_colors[VoxelWorld.Mat.EARTH] = Color(0.55, 0.40, 0.26)
	_mat_colors[VoxelWorld.Mat.GOLD] = Color(0.96, 0.78, 0.20)
	_mat_colors[VoxelWorld.Mat.WATER] = Color(0.28, 0.55, 0.85)
	_mat_colors[VoxelWorld.Mat.CRYSTAL] = Color(0.45, 0.78, 1.00)
	_mat_colors[VoxelWorld.Mat.RELIC] = Color(0.82, 0.38, 0.95)
	_mat_colors[VoxelWorld.Mat.OIL] = Color(0.15, 0.12, 0.08)

	gs = GameState.new()
	gs.setup(world)
	gs.changed.connect(_on_changed)
	gs.notice.connect(_on_notice)
	gs.spade_thrown.connect(_on_spade_thrown)
	gs.cards_drawn.connect(_on_cards_drawn)
	gs.turn_started.connect(_on_turn_started)
	gs.game_over.connect(_on_game_over)
	gs.unit_animated_move.connect(_on_unit_animated_move)
	gs.quake_started.connect(_on_quake_started)

	_build_hud()
	gs.start()
	_select(gs.selected)
	queue_redraw()

# ---------------------------------------------------------------- iso math

func iso_pt(x: float, y: float, z: float) -> Vector2:
	return origin + Vector2(
		(x - z) * TILE_W * 0.5,
		(x + z) * TILE_H * 0.5 - y * HEIGHT_STEP
	)

func iso(p: Vector3i) -> Vector2:
	return iso_pt(float(p.x), float(p.y), float(p.z))

# 4 corners of a cube cell's TOP face (y = cy+1). Standing-on-it diamond.
func top_face(c: Vector3i) -> PackedVector2Array:
	return PackedVector2Array([
		iso(c + Vector3i(0, 1, 0)),     # W (left)
		iso(c + Vector3i(1, 1, 0)),     # N (back)
		iso(c + Vector3i(1, 1, 1)),     # E (right)
		iso(c + Vector3i(0, 1, 1)),     # S (front)
	])

func iso_depth(p: Vector3i) -> int:
	# Back-to-front sort key for the iso camera angle.
	return p.x + p.z

# ---------------------------------------------------------------- drawing

func _draw() -> void:
	var keys: Array = world.cells.keys()
	keys.sort_custom(func(a, b):
		if a.x + a.z != b.x + b.z:
			return a.x + a.z < b.x + b.z
		return a.y < b.y)
	for c in keys:
		_draw_cube(c, _level_alpha(c.y))
	for c in targets:
		_draw_highlight(c)
	var us := []
	for u in gs.units:
		if not u.is_alive():
			continue
		# Hide enemies in cells the player hasn't seen.
		if u.team != 0 and not gs.seen.has(u.grid):
			continue
		us.append(u)
	us.sort_custom(func(a, b):
		var sa: int = a.grid.x + a.grid.z
		var sb: int = b.grid.x + b.grid.z
		if sa != sb:
			return sa < sb
		return a.grid.y < b.grid.y)
	for u in us:
		# Units always render at full alpha so an op on any level reads clearly
		# through the wireframe terrain above. The screen-y position already
		# communicates their level (taller = higher y in iso projection).
		_draw_unit(u, 1.0)
	for s in gs.dropped:
		_draw_dropped_spade(s, 1.0)
	_draw_projectiles()

func _level_alpha(y: int) -> float:
	# Alpha for cubes AT/BELOW the focal level. Above-focal cubes don't go through
	# this — they wireframe instead (see _draw_cube).
	if y == view_level:
		return 1.0
	if y < view_level:
		return FADE_BELOW
	return 0.0   # never used; above-focal cubes early-out into the wireframe path

func _draw_cube(c: Vector3i, alpha: float) -> void:
	var shake := Vector2(0, _quake_offset(c))
	var p010 := iso(c + Vector3i(0, 1, 0)) + shake
	var p110 := iso(c + Vector3i(1, 1, 0)) + shake
	var p111 := iso(c + Vector3i(1, 1, 1)) + shake
	var p011 := iso(c + Vector3i(0, 1, 1)) + shake
	var p100 := iso(c + Vector3i(1, 0, 0)) + shake
	var p101 := iso(c + Vector3i(1, 0, 1)) + shake
	var p001 := iso(c + Vector3i(0, 0, 1)) + shake
	var seen_it: bool = gs.seen.has(c)
	var base_col: Color
	if seen_it:
		var mat: int = world.material_at(c)
		base_col = _mat_colors.get(mat, Color(0.5, 0.5, 0.5))
	else:
		base_col = FOG_COLOR

	# Cubes ABOVE the focal level render as wireframe only — see-through to ops
	# below. The line color is the material's hue at WIRE_ALPHA so you still
	# read what tier the cube is (gold / crystal / relic glow through).
	if c.y > view_level:
		var wire_col := Color(base_col.r, base_col.g, base_col.b, WIRE_ALPHA)
		draw_polyline(PackedVector2Array([p010, p110, p111, p011, p010]), wire_col, WIRE_WIDTH)
		draw_polyline(PackedVector2Array([p100, p110, p111, p101, p100]), wire_col, WIRE_WIDTH)
		draw_polyline(PackedVector2Array([p001, p011, p111, p101, p001]), wire_col, WIRE_WIDTH)
		return

	# Solid render for at-focal and below-focal cubes.
	var top_col := base_col
	top_col.a = alpha
	var right_col := top_col.darkened(0.22)
	right_col.a = alpha
	var left_col := top_col.darkened(0.42)
	left_col.a = alpha
	# Three visible faces: top + +X (right) + +Z (left/front).
	draw_colored_polygon(PackedVector2Array([p010, p110, p111, p011]), top_col)
	draw_colored_polygon(PackedVector2Array([p100, p110, p111, p101]), right_col)
	draw_colored_polygon(PackedVector2Array([p001, p011, p111, p101]), left_col)
	var outline := Color(0, 0, 0, 0.25 * alpha)
	draw_polyline(PackedVector2Array([p010, p110, p111, p011, p010]), outline, 1.0)
	draw_polyline(PackedVector2Array([p100, p110, p111, p101, p100]), outline, 1.0)
	draw_polyline(PackedVector2Array([p001, p011, p111, p101, p001]), outline, 1.0)

func _draw_highlight(c: Vector3i) -> void:
	# Wireframe diamond on the visible surface for cell `c`. For air cells we
	# outline the floor (top of the cube below); for solid cells, the top face.
	var anchor: Vector3i = c if world.is_solid(c) else c + Vector3i(0, -1, 0)
	var poly := top_face(anchor)
	var closed := PackedVector2Array([poly[0], poly[1], poly[2], poly[3], poly[0]])
	var color: Color = MODE_COLORS.get(mode, Color.WHITE)
	draw_polyline(closed, color, 3.0)

func _draw_unit(u, alpha: float) -> void:
	# Use the animated render position so moves lerp smoothly. Falls back to
	# the logical cell if draw_pos is uninitialised (e.g. legacy spawns).
	var dp: Vector3 = u.draw_pos if u.draw_pos != Vector3.ZERO else Vector3(u.grid.x + 0.5, float(u.grid.y), u.grid.z + 0.5)
	var feet: Vector2 = iso_pt(dp.x, dp.y, dp.z)
	var col: Color
	if u.kind == "leader":
		col = LEADER_COLOR
	else:
		col = TEAM_COLORS[u.team]
	if u == gs.selected:
		col = col.lightened(0.25)
	col.a = alpha

	# Selection ring on the floor (wireframe diamond) FIRST so the body covers part of it.
	if u == gs.selected:
		var ring := _diamond(feet, TILE_W * 0.42, TILE_H * 0.42)
		ring.append(ring[0])
		draw_polyline(ring, Color(1, 1, 0.3), 2.5)

	# Soft shadow.
	draw_colored_polygon(_diamond(feet, TILE_W * 0.30, TILE_H * 0.30), Color(0, 0, 0, 0.25))

	# Body: tall ellipse for leader, short for operator.
	var body_h: float = HEIGHT_STEP * (1.6 if u.kind == "leader" else 1.15)
	var body_w: float = 18.0 if u.kind == "leader" else 15.0
	var body_top := feet - Vector2(0, body_h)
	_draw_capsule(feet, body_top, body_w, col)

	# Crown for the leader (distinct silhouette).
	if u.kind == "leader":
		var crown_y := body_top.y - 6
		var pts := PackedVector2Array([
			Vector2(body_top.x - 10, crown_y + 6),
			Vector2(body_top.x - 7, crown_y - 4),
			Vector2(body_top.x - 3, crown_y + 2),
			Vector2(body_top.x, crown_y - 6),
			Vector2(body_top.x + 3, crown_y + 2),
			Vector2(body_top.x + 7, crown_y - 4),
			Vector2(body_top.x + 10, crown_y + 6),
		])
		draw_colored_polygon(pts, Color(1.0, 0.92, 0.40))
		draw_polyline(pts, Color(0.6, 0.45, 0.0), 1.5)

	# Held spade.
	if u.spade != null:
		var sp_top := feet + Vector2(10, -body_h * 0.95)
		var sp_bot := feet + Vector2(14, -body_h * 0.15)
		draw_line(sp_top, sp_bot, Color(0.78, 0.78, 0.85), 3.0)
		# Spade head triangle.
		draw_colored_polygon(PackedVector2Array([
			sp_bot + Vector2(-4, 0),
			sp_bot + Vector2(4, 0),
			sp_bot + Vector2(0, 8),
		]), Color(0.78, 0.78, 0.85))

	# HP text + small "L<y>" level badge so the layer is unambiguous.
	var font := ThemeDB.fallback_font
	if font != null:
		draw_string(font, body_top - Vector2(8, 6), "%d" % u.hp, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
		var badge_pos: Vector2 = feet + Vector2(-14, -body_h - 24)
		var is_focal: bool = (u.grid.y - 1) == view_level
		var badge_col: Color = Color(0.30, 1.00, 0.50) if is_focal else Color(0.85, 0.85, 0.95)
		# Outlined badge background for legibility on any terrain.
		draw_rect(Rect2(badge_pos - Vector2(2, 2), Vector2(28, 14)), Color(0, 0, 0, 0.6))
		draw_string(font, badge_pos + Vector2(0, 10), "L%d" % u.grid.y, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, badge_col)

func _draw_capsule(feet: Vector2, top: Vector2, width: float, col: Color) -> void:
	var mid_y := (feet.y + top.y) * 0.5
	# Rectangle body + two end-caps approximated with circles.
	draw_rect(Rect2(Vector2(feet.x - width * 0.5, top.y), Vector2(width, feet.y - top.y)), col)
	draw_circle(Vector2(feet.x, top.y), width * 0.5, col)
	draw_circle(Vector2(feet.x, feet.y), width * 0.5, col)
	# Outline.
	draw_arc(Vector2(feet.x, top.y), width * 0.5, PI, TAU, 16, col.darkened(0.4), 1.5)
	draw_line(Vector2(feet.x - width * 0.5, top.y), Vector2(feet.x - width * 0.5, feet.y), col.darkened(0.4), 1.5)
	draw_line(Vector2(feet.x + width * 0.5, top.y), Vector2(feet.x + width * 0.5, feet.y), col.darkened(0.4), 1.5)

func _on_spade_thrown(from_g: Vector3i, to_g: Vector3i, boomerang: bool) -> void:
	# Spade's centre fires from the operator's chest height (slightly above
	# their feet) and aims for the destination cell's feet position.
	var from_pos: Vector2 = iso_pt(from_g.x + 0.5, float(from_g.y), from_g.z + 0.5) - Vector2(0, 16)
	var to_pos: Vector2 = iso_pt(to_g.x + 0.5, float(to_g.y), to_g.z + 0.5) - Vector2(0, 16)
	projectiles.append({
		"from": from_pos,
		"to": to_pos,
		"t": 0.0,
		"dur": THROW_DUR,
		"boomerang": boomerang,
	})

func _process(delta: float) -> void:
	# Keyboard pan: WASD or arrow keys. Speed is in screen pixels (independent
	# of zoom so the map feels equally responsive zoomed in or out).
	var pan := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		pan.y += 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		pan.y -= 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		pan.x += 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		pan.x -= 1.0
	if pan != Vector2.ZERO:
		position += pan * PAN_SPEED * delta
		queue_redraw()
	# Earthquake bounce: advance time until the quake settles, then clear.
	if _quake_t < QUAKE_DUR:
		_quake_t += delta
		queue_redraw()
		if _quake_t >= QUAKE_DUR:
			_quake_columns.clear()
	# Move animations: tween updates u.draw_pos under the hood, but the renderer
	# only redraws when we ask it to. Keep queueing while any move is in flight.
	if _moves_in_flight > 0:
		queue_redraw()
	if projectiles.is_empty():
		return
	for p in projectiles:
		p["t"] += delta / p["dur"]
	# One-way ends at t=1; boomerangs run there-and-back, ending at t=2.
	projectiles = projectiles.filter(func(p):
		return p["t"] < (2.0 if p["boomerang"] else 1.0))
	queue_redraw()

# Earthquake fired — set up a random phase per affected (x, z) column so they
# bounce out-of-sync. `_process` will tick `_quake_t` until the quake settles.
func _on_quake_started(columns: Array) -> void:
	_quake_columns.clear()
	for col in columns:
		_quake_columns[col] = randf() * TAU
	_quake_t = 0.0
	queue_redraw()

# How much (in screen Y px) a cube at `c` should shift this frame to look like
# it's thrashing during a quake. Negative = up. Amplitude decays quadratically
# from QUAKE_AMP → 0 over QUAKE_DUR seconds.
func _quake_offset(c: Vector3i) -> float:
	if _quake_columns.is_empty():
		return 0.0
	var key := Vector2i(c.x, c.z)
	if not _quake_columns.has(key):
		return 0.0
	var k: float = 1.0 - clampf(_quake_t / QUAKE_DUR, 0.0, 1.0)
	var amp: float = QUAKE_AMP * k * k
	return sin(_quake_t * QUAKE_FREQ + float(_quake_columns[key])) * amp

# A unit moved logically; tween its render position from the old cell to the
# new one over ~0.25 s. `u.grid` is already set to `to_g` by GameState, so
# only the visual lags.
func _on_unit_animated_move(u, from_g: Vector3i, to_g: Vector3i) -> void:
	u.draw_pos = Vector3(from_g.x + 0.5, float(from_g.y), from_g.z + 0.5)
	var to_pos := Vector3(to_g.x + 0.5, float(to_g.y), to_g.z + 0.5)
	_moves_in_flight += 1
	var tween := create_tween()
	tween.tween_property(u, "draw_pos", to_pos, 0.26) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.finished.connect(func(): _moves_in_flight -= 1)

func _draw_projectiles() -> void:
	for p in projectiles:
		var t: float = p["t"]
		var from_pos: Vector2 = p["from"]
		var to_pos: Vector2 = p["to"]
		var leg_t: float = t                  # phase within the current leg [0,1]
		var pos: Vector2
		if p["boomerang"]:
			if t < 1.0:
				pos = from_pos.lerp(to_pos, t)
				leg_t = t
			else:
				pos = to_pos.lerp(from_pos, t - 1.0)
				leg_t = t - 1.0
		else:
			pos = from_pos.lerp(to_pos, t)
		# Parabolic lift via sin(pi * leg_t).
		pos.y -= sin(PI * leg_t) * THROW_ARC
		# Spinning spade: rotates a few times over the flight.
		var angle: float = t * TAU * 2.4
		_draw_spinning_spade(pos, angle)

func _draw_spinning_spade(pos: Vector2, angle: float) -> void:
	var dir := Vector2(cos(angle), sin(angle))
	var perp := Vector2(-dir.y, dir.x)
	var shaft_back: Vector2 = pos - dir * 12.0
	var shaft_front: Vector2 = pos + dir * 7.0
	var head_tip: Vector2 = pos + dir * 15.0
	# Soft shadow at the ground projection so the throw reads in iso space.
	var shadow_pos: Vector2 = Vector2(pos.x, pos.y + 18.0)
	draw_circle(shadow_pos, 5.0, Color(0, 0, 0, 0.20))
	# Shaft + triangular spade head.
	draw_line(shaft_back, shaft_front, Color(0.82, 0.82, 0.88), 3.0)
	draw_colored_polygon(PackedVector2Array([
		head_tip, shaft_front + perp * 5.0, shaft_front - perp * 5.0
	]), Color(0.88, 0.88, 0.92))
	draw_polyline(PackedVector2Array([
		head_tip, shaft_front + perp * 5.0, shaft_front - perp * 5.0, head_tip
	]), Color(0.35, 0.35, 0.40), 1.0)

func _draw_dropped_spade(s, alpha: float) -> void:
	var c: Vector2 = iso_pt(s.grid.x + 0.5, float(s.grid.y), s.grid.z + 0.5)
	var col := Color(0.78, 0.78, 0.85, alpha)
	draw_line(c + Vector2(-14, -2), c + Vector2(10, -2), col, 3.0)
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(10, -6), c + Vector2(16, 0), c + Vector2(10, 2)
	]), col)

func _diamond(center: Vector2, hw: float, hh: float) -> PackedVector2Array:
	return PackedVector2Array([
		center + Vector2(0, -hh),
		center + Vector2(hw, 0),
		center + Vector2(0, hh),
		center + Vector2(-hw, 0),
	])

# ---------------------------------------------------------------- input / picking

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = event.pressed
			return
		if not event.pressed:
			return
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				_on_click(get_local_mouse_position())
			MOUSE_BUTTON_RIGHT:
				_cancel_action()
			MOUSE_BUTTON_WHEEL_UP:
				if event.shift_pressed:
					_set_view_level(view_level + 1)
				else:
					_zoom_at(event.position, ZOOM_STEP)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.shift_pressed:
					_set_view_level(view_level - 1)
				else:
					_zoom_at(event.position, 1.0 / ZOOM_STEP)
	elif event is InputEventMouseMotion and _panning:
		# Drag-pan: move the Node2D so the world tracks the cursor.
		position += event.relative
		queue_redraw()

# Zoom around the mouse position so the world point under the cursor stays put.
func _zoom_at(mouse_screen: Vector2, factor: float) -> void:
	var new_zoom: float = clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
	if new_zoom == zoom:
		return
	# Mouse position in our local (pre-transform) coordinates.
	var local_before: Vector2 = (mouse_screen - position) / zoom
	zoom = new_zoom
	scale = Vector2(zoom, zoom)
	position = mouse_screen - local_before * zoom

func _set_view_level(level: int) -> void:
	view_level = clampi(level, 0, VoxelWorld.SY - 1)
	_refresh_level_label()
	queue_redraw()

func _refresh_level_label() -> void:
	if level_label != null:
		level_label.text = "View: level %d" % view_level

func _cancel_action() -> void:
	if _ai_running or gs.is_over or _combo_animating:
		return
	# Clear the current combo selection first.
	if not selected_cards.is_empty():
		selected_cards.clear()
		_on_changed()
		return
	if pending_card != null:
		pending_card = null
		mode = "move"
		_on_changed()
		return
	if mode != "move" and gs.selected != null and gs.selected.team == 0:
		mode = "move"
		_on_changed()

func _on_click(p: Vector2) -> void:
	if _ai_running or gs.is_over:
		return
	var hit = _pick_target(p)
	if hit != null:
		_act_on(hit)
		return
	var u = _pick_unit(p)
	if u != null:
		_select(u)

func _pick_target(p: Vector2):
	var ts := targets.duplicate()
	# Front-to-back so the closest highlight wins overlaps.
	ts.sort_custom(func(a, b):
		var sa: int = a.x + a.z
		var sb: int = b.x + b.z
		if sa != sb:
			return sa > sb
		return a.y > b.y)
	for c in ts:
		var anchor: Vector3i = c if world.is_solid(c) else c + Vector3i(0, -1, 0)
		if Geometry2D.is_point_in_polygon(p, top_face(anchor)):
			return c
	return null

func _pick_unit(p: Vector2):
	var us := []
	for u in gs.units:
		if u.is_alive():
			us.append(u)
	us.sort_custom(func(a, b):
		var sa: int = a.grid.x + a.grid.z
		var sb: int = b.grid.x + b.grid.z
		if sa != sb:
			return sa > sb
		return a.grid.y > b.grid.y)
	for u in us:
		var feet: Vector2 = iso_pt(u.grid.x + 0.5, float(u.grid.y), u.grid.z + 0.5)
		var body_h: float = HEIGHT_STEP * (1.6 if u.kind == "leader" else 1.15)
		var rect := Rect2(feet - Vector2(14, body_h + 4), Vector2(28, body_h + 8))
		if rect.has_point(p):
			return u
	return null

func _act_on(cell) -> void:
	# Combo play takes priority over single-unit actions.
	if not selected_cards.is_empty():
		var v: Dictionary = gs.combo_validate(selected_cards)
		if not v.get("valid", false):
			gs.notice.emit(String(v.get("reason", "Invalid combo.")))
			return
		_play_combo_animation(selected_cards.duplicate(), cell)
		return
	var u = gs.selected
	if u == null:
		return
	match mode:
		"move": gs.move_to(u, cell)
		"dig": gs.dig_at(u, cell)
		"swing": gs.swing_at(u, cell)
		"throw": gs.throw_at(u, cell)

# ---------------------------------------------------------------- selection / mode

func _select(u) -> void:
	mode = "move" if (u != null and u.team == 0) else ""
	# view_level auto-syncs via _on_changed (called by gs.select → changed.emit).
	gs.select(u)

func _set_mode(m: String) -> void:
	mode = m
	_on_changed()

func _targets_for_mode() -> Array:
	if not selected_cards.is_empty():
		return gs.combo_targets(selected_cards)
	var u = gs.selected
	if u == null or u.team != 0:
		return []
	match mode:
		"move": return gs.move_targets(u)
		"dig": return gs.dig_targets(u)
		"swing": return gs.swing_targets(u)
		"throw": return gs.throw_targets(u)
	return []

func _on_changed() -> void:
	# Auto-follow the selected unit's level: snap view_level whenever their y
	# changes (initial select, move_to, dig descent, …). Level +/- still works
	# while a unit's level is steady, because we only sync on a CHANGE.
	if gs.selected != null:
		var u_level: int = clampi(gs.selected.grid.y - 1, 0, VoxelWorld.SY - 1)
		if u_level != _last_selected_level:
			_last_selected_level = u_level
			view_level = u_level
			_refresh_level_label()
	else:
		_last_selected_level = -999
	targets = _targets_for_mode()
	_refresh_context()
	_refresh_info()
	_refresh_combo_status()
	queue_redraw()

func _refresh_combo_status() -> void:
	if status_label == null:
		return
	if selected_cards.is_empty():
		return
	var v: Dictionary = gs.combo_validate(selected_cards)
	if v.get("valid", false):
		status_label.text = "Combo (%d e): %s — click a green tile" % \
			[int(v["total_cost"]), gs.combo_summary(selected_cards)]
	else:
		status_label.text = "Combo: %s — %s" % \
			[gs.combo_summary(selected_cards), String(v.get("reason", ""))]

func _on_notice(text: String) -> void:
	if status_label != null:
		status_label.text = text

# ---------------------------------------------------------------- HUD

func _build_hud() -> void:
	hud = CanvasLayer.new()
	add_child(hud)
	info_label = _label(Vector2(12, 10))
	status_label = _label(Vector2(12, 36))
	hint_label = _label(Vector2(12, 62))
	hint_label.text = "Click a unit to select; click a highlighted cell to act.  Wheel zooms; Shift+wheel scrolls levels; right-click cancels."
	end_turn_btn = Button.new()
	end_turn_btn.text = "End Turn"
	end_turn_btn.position = Vector2(12, 92)
	end_turn_btn.size = Vector2(110, 32)
	end_turn_btn.pressed.connect(_on_end_turn)
	hud.add_child(end_turn_btn)

	sim_btn = Button.new()
	sim_btn.text = "Sim: OFF"
	sim_btn.toggle_mode = true
	sim_btn.position = Vector2(130, 92)
	sim_btn.size = Vector2(110, 32)
	sim_btn.toggled.connect(_on_sim_toggled)
	hud.add_child(sim_btn)

	restart_btn = Button.new()
	restart_btn.text = "Restart"
	restart_btn.position = Vector2(248, 92)
	restart_btn.size = Vector2(96, 32)
	restart_btn.pressed.connect(func(): get_tree().reload_current_scene())
	hud.add_child(restart_btn)

	# Draw + discard pile panels framing the hand row.
	draw_pile_panel = _pile_panel(Vector2(40, HAND_Y + 70))
	draw_pile_label = _pile_label(draw_pile_panel, "Draw")
	discard_pile_panel = _pile_panel(Vector2(1470, HAND_Y + 70))
	discard_pile_label = _pile_label(discard_pile_panel, "Discard")

	# Ball overlay sits on top of every HUD element for the combo animation.
	ball_overlay = BallOverlay.new()
	ball_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ball_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.add_child(ball_overlay)

	# Level viewer controls (right-side stack).
	level_label = _label(Vector2(1470, 50))
	level_up_btn = Button.new()
	level_up_btn.text = "Level +"
	level_up_btn.position = Vector2(1470, 76)
	level_up_btn.size = Vector2(118, 30)
	level_up_btn.pressed.connect(func(): _set_view_level(view_level + 1))
	hud.add_child(level_up_btn)
	level_dn_btn = Button.new()
	level_dn_btn.text = "Level -"
	level_dn_btn.position = Vector2(1470, 110)
	level_dn_btn.size = Vector2(118, 30)
	level_dn_btn.pressed.connect(func(): _set_view_level(view_level - 1))
	hud.add_child(level_dn_btn)
	_refresh_level_label()

	view_btn = Button.new()
	view_btn.text = "Switch to 3D"
	view_btn.position = Vector2(1470, 12)
	view_btn.size = Vector2(118, 32)
	view_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main_3d.tscn"))
	hud.add_child(view_btn)

func _pile_panel(pos: Vector2) -> Panel:
	var p := Panel.new()
	p.position = pos
	p.size = Vector2(88, 110)
	hud.add_child(p)
	return p

func _pile_label(parent: Panel, prefix: String) -> Label:
	var l := Label.new()
	l.text = "%s\n0" % prefix
	l.position = Vector2(6, 24)
	l.size = Vector2(76, 60)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(l)
	return l

func _on_end_turn() -> void:
	if _ai_running:
		return
	# Clear any active mode/pending card and deselect the current unit so the
	# next turn starts fresh.
	mode = ""
	pending_card = null
	gs.selected = null
	gs.end_turn()

func _on_discard_selected() -> void:
	if _ai_running or _combo_animating or selected_cards.is_empty():
		return
	var to_discard: Array = selected_cards.duplicate()
	selected_cards.clear()
	gs.discard_cards(to_discard)

func _on_sim_toggled(on: bool) -> void:
	gs.sim_mode = on
	sim_btn.text = "Sim: ON" if on else "Sim: OFF"
	# If sim flips on mid-turn and it's currently the player's turn, kick AI
	# off so the simulation starts immediately.
	if on and gs.active_team == GameState.TEAM_PLAYER and not gs.is_over and not _ai_running:
		_kick_ai()

# Turn-started → if the active team is AI-controlled (enemy, or sim mode),
# autopilot it. Otherwise hand control to the player.
func _on_turn_started(team: int) -> void:
	if gs.is_over:
		return
	if team == GameState.TEAM_ENEMY or gs.sim_mode:
		_kick_ai()

func _kick_ai() -> void:
	if _ai_running or gs.is_over:
		return
	_ai_running = true
	mode = ""
	pending_card = null
	gs.selected = null
	await _run_ai_turn(gs.active_team)
	_ai_running = false
	if not gs.is_over:
		gs.end_turn()

func _run_ai_turn(team: int) -> void:
	# Cap iterations at a generous safety value so a buggy AI can't lock the
	# game; in practice this exits as soon as ai_step returns false (no
	# valid actions left for the energy budget).
	var safety: int = 30
	while safety > 0 and not gs.is_over:
		if not gs.ai_step(team):
			break
		safety -= 1
		await get_tree().create_timer(0.32).timeout

func _on_game_over(winner_team: int) -> void:
	_ai_running = false
	var msg: String
	match winner_team:
		GameState.TEAM_PLAYER: msg = "GAME OVER — You win!"
		GameState.TEAM_ENEMY: msg = "GAME OVER — Enemy wins."
		_: msg = "GAME OVER — draw (mutual annihilation)."
	if status_label != null:
		status_label.text = msg
	if sim_btn != null:
		sim_btn.button_pressed = false
		sim_btn.text = "Sim: OFF"
		gs.sim_mode = false

func _on_cards_drawn(count: int) -> void:
	# Recorded here; the actual slide-in happens during the next _refresh_context
	# when the new card Buttons are instantiated.
	_pending_anim_count = count

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
	var team_label := "PLAYER" if gs.active_team == GameState.TEAM_PLAYER else "ENEMY"
	info_label.text = "Turn %d   %s   Energy %d/%d   Oil %d   Selected: %s   [mode: %s]" % \
		[gs.turn, team_label, gs.energy, GameState.MAX_ENERGY,
			int(gs.oil[GameState.TEAM_PLAYER]), who, mode if mode != "" else "—"]
	if end_turn_btn != null:
		end_turn_btn.disabled = gs.is_over or _ai_running or gs.active_team != GameState.TEAM_PLAYER

func _refresh_context() -> void:
	# Don't blow away the buttons mid-animation — the combo animation owns them
	# until it finishes (after which it re-emits changed and we land here).
	if _combo_animating:
		return
	for b in context_buttons:
		b.queue_free()
	context_buttons.clear()
	_refresh_pile_counts()
	var u = gs.selected
	if u == null or u.team != 0:
		return
	var x := 12.0
	var y := 840.0
	if u.kind == "leader":
		# Move button + Discard button stay in the action row. Discard is only
		# enabled when at least one card is selected.
		x = _ctx_button("Move", x, y, func(): _set_mode("move"), u.moved)
		x = _ctx_button("Discard", x, y, _on_discard_selected, selected_cards.is_empty())
		# Cards: centred row above the action row, using composite frame+art.
		var n: int = gs.hand.size()
		var step := CARD_W + 8.0
		var total: float = (n * CARD_W + (n - 1) * 8.0) if n > 0 else 0.0
		var card_x: float = (1600.0 - total) * 0.5
		# Newest N cards animate in from the draw pile; older ones snap.
		var anim_count: int = min(_pending_anim_count, n)
		var first_anim_idx: int = n - anim_count
		_pending_anim_count = 0           # consume so reruns don't repeat
		var i := 0
		for card in gs.hand:
			var slot_y: float = HAND_Y - (28.0 if selected_cards.has(card) else 0.0)
			var b := _make_card_button(card, card_x, slot_y, _on_card.bind(card))
			b.set_meta("card", card)
			if selected_cards.has(card):
				b.modulate = Color(1.18, 1.18, 1.00)
			hud.add_child(b)
			context_buttons.append(b)
			if i >= first_anim_idx and anim_count > 0:
				_animate_card_in(b, Vector2(card_x, slot_y), i - first_anim_idx)
			card_x += step
			i += 1
	else:
		# Per-unit budget: Move greys out if used; spade actions grey out if the
		# op has no spade or already used their action this turn.
		var moved: bool = u.moved
		var no_action: bool = u.acted
		var no_spade: bool = u.spade == null
		var spade_locked: bool = no_spade or no_action
		var has_special: bool = (not no_spade) and u.spade.head == "spade_earthquake"
		x = _ctx_button("Move", x, y, func(): _set_mode("move"), moved)
		x = _ctx_button("Dig", x, y, func(): _set_mode("dig"), spade_locked)
		x = _ctx_button("Swing", x, y, func(): _set_mode("swing"), spade_locked)
		x = _ctx_button("Throw", x, y, func(): _set_mode("throw"), spade_locked)
		x = _ctx_button("Pick Up", x, y, func(): gs.pickup(gs.selected), no_action)
		x = _ctx_button("Special", x, y, func(): gs.special(gs.selected), spade_locked or not has_special)

# Play the rise → merge → ball-arc animation, then commit the combo to state.
# Cards rise + converge into a glowing white ball, which arcs to `target_cell`
# in iso space. State changes (energy / spawn / discard) happen AFTER the
# animation lands, so the visual feels causal.
func _play_combo_animation(cards: Array, target_cell: Vector3i) -> void:
	if _combo_animating:
		return
	_combo_animating = true

	# Snapshot the actual Button nodes for the selected cards (in hand order).
	var card_btns: Array = []
	for c in cards:
		for b in context_buttons:
			if b.has_meta("card") and b.get_meta("card") == c:
				card_btns.append(b)
				break

	# Converge point: centred horizontally, just above the hand row.
	var converge: Vector2 = Vector2(800.0 - CARD_W * 0.5 * 0.4, HAND_Y - 110.0)
	# Centre of the ball when it appears.
	var ball_center: Vector2 = converge + Vector2(CARD_W * 0.5 * 0.4, CARD_H * 0.5 * 0.4)

	# Phase 1: cards rise + shrink + brighten + converge.
	if not card_btns.is_empty():
		var rise := create_tween().set_parallel(true)
		for b: Button in card_btns:
			rise.tween_property(b, "position", converge, 0.35) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
			rise.tween_property(b, "scale", Vector2(0.4, 0.4), 0.35)
			rise.tween_property(b, "modulate", Color(1.7, 1.7, 1.7, 0.85), 0.35)
		await rise.finished

	# Hide the card buttons so only the ball remains.
	for b: Button in card_btns:
		b.visible = false

	# Phase 2: ball materialises and grows from 0 → 34 px.
	ball_overlay.pos = ball_center
	ball_overlay.radius = 0.0
	ball_overlay.active = true
	ball_overlay.queue_redraw()
	var grow := create_tween()
	grow.tween_method(_set_ball_radius, 0.0, 34.0, 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await grow.finished

	# Phase 3: ball arcs from converge point to target cell (in screen space).
	# iso_pt is local Node2D coords; map to screen via the Node2D transform.
	var target_local: Vector2 = iso_pt(target_cell.x + 0.5, float(target_cell.y), target_cell.z + 0.5)
	var target_screen: Vector2 = self.global_transform * target_local
	var start_screen: Vector2 = ball_center
	var fly := create_tween()
	fly.tween_method(_set_ball_arc.bind(start_screen, target_screen), 0.0, 1.0, 0.45) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await fly.finished

	# Phase 4: pop + collapse, commit state.
	var collapse := create_tween()
	collapse.tween_method(_set_ball_radius, 34.0, 0.0, 0.14) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	await collapse.finished

	ball_overlay.active = false
	ball_overlay.queue_redraw()
	selected_cards.clear()
	_combo_animating = false
	gs.play_combo_at(cards, target_cell)        # _emit_changed rebuilds the hand

func _set_ball_radius(r: float) -> void:
	if ball_overlay == null:
		return
	ball_overlay.radius = r
	ball_overlay.queue_redraw()

func _set_ball_arc(t: float, from_p: Vector2, to_p: Vector2) -> void:
	if ball_overlay == null:
		return
	var pos: Vector2 = from_p.lerp(to_p, t)
	pos.y -= sin(PI * t) * 100.0                # arc lift
	ball_overlay.pos = pos
	ball_overlay.queue_redraw()

# Slide a freshly-drawn card from the draw pile into its hand slot, fading in.
func _animate_card_in(card_btn: Button, target_pos: Vector2, anim_index: int) -> void:
	var pile_pos := Vector2(40 + 44 - CARD_W * 0.5, HAND_Y + 70 + 55 - CARD_H * 0.5)
	card_btn.position = pile_pos
	card_btn.modulate = Color(1, 1, 1, 0)
	var tween := create_tween().set_parallel(true)
	var delay: float = anim_index * 0.07
	tween.tween_property(card_btn, "position", target_pos, 0.30) \
		.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(card_btn, "modulate", Color.WHITE, 0.30).set_delay(delay)

func _refresh_pile_counts() -> void:
	if draw_pile_label != null:
		draw_pile_label.text = "Draw\n%d" % gs.draw_pile.size()
	if discard_pile_label != null:
		discard_pile_label.text = "Discard\n%d" % gs.discard.size()

func _ctx_button(text: String, x: float, y: float, cb: Callable, disabled: bool = false) -> float:
	var b := Button.new()
	b.text = text
	b.position = Vector2(x, y)
	b.size = Vector2(96, 36)
	b.disabled = disabled
	if disabled:
		# Greyed out: Godot's Button already darkens disabled, but lift the alpha
		# down a bit more so it reads as "spent / unavailable".
		b.modulate = Color(1.0, 1.0, 1.0, 0.45)
	elif text.to_lower() == mode:
		b.modulate = Color(1.0, 1.0, 0.5)
	b.pressed.connect(cb)
	hud.add_child(b)
	context_buttons.append(b)
	return x + 100.0

# Runtime-load a card image (bypasses the editor import system so dropping a
# new PNG into assets/cards/ doesn't require re-opening Godot). Returns null
# if the file is missing; result cached either way for the session.
func _texture_for(id: String):
	if _card_textures.has(id):
		return _card_textures[id]
	var path := "%s%s.png" % [CARDS_DIR, id]
	var img := Image.new()
	if img.load(path) != OK:
		_card_textures[id] = null
		return null
	var tex := ImageTexture.create_from_image(img)
	_card_textures[id] = tex
	return tex

# Position a child Control inside its parent Card by proportional Rect2.
func _place(child: Control, rect: Rect2) -> void:
	child.position = Vector2(CARD_W * rect.position.x, CARD_H * rect.position.y)
	child.size = Vector2(CARD_W * rect.size.x, CARD_H * rect.size.y)
	child.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _make_card_label(text: String, rect: Rect2, font_size: int, font_color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", font_color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.clip_text = true
	_place(l, rect)
	return l

# Outlined label — used for the cost digit so it's readable on any gem tint.
func _make_outlined_label(text: String, rect: Rect2, font_size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", Color(1, 1, 1))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	l.add_theme_constant_override("outline_size", 8)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.clip_text = true
	_place(l, rect)
	return l

# Build a card as a Button (root, captures click) with layered children:
# art (lowest) -> frame (modulated by category) -> labels (cost / title / blurb).
# A missing art file just leaves the keyhole empty so the card still renders.
func _make_card_button(card: Dictionary, x: float, y: float, cb: Callable) -> Button:
	var b := Button.new()
	b.flat = true
	b.custom_minimum_size = Vector2(CARD_W, CARD_H)
	b.position = Vector2(x, y)
	b.size = Vector2(CARD_W, CARD_H)
	var cost: int = int(card["cost"])
	var disabled: bool = cost > gs.energy
	b.disabled = disabled

	var cat: String = String(card.get("category", ""))
	var tint: Color = CATEGORY_TINT.get(cat, Color.WHITE)
	if disabled:
		tint = tint.darkened(0.45)

	# 1. Art (behind the frame, inside the keyhole region).
	var art_tex = _texture_for(card["id"])
	if art_tex != null:
		var art := TextureRect.new()
		art.texture = art_tex
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		if disabled:
			art.modulate = Color(0.55, 0.55, 0.55, 1.0)
		_place(art, ART_RECT)
		b.add_child(art)

	# 2. Frame on top (transparent keyhole shows the art through).
	var frame_tex = _texture_for("_frame")
	if frame_tex != null:
		var fr := TextureRect.new()
		fr.texture = frame_tex
		fr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		fr.stretch_mode = TextureRect.STRETCH_SCALE
		fr.modulate = tint
		_place(fr, Rect2(0, 0, 1, 1))
		b.add_child(fr)

	# 3. Labels — cost on the gem, title on the plaque, blurb on the parchment.
	var label_col := Color(0.18, 0.13, 0.08) if not disabled else Color(0.32, 0.30, 0.27)
	b.add_child(_make_outlined_label(str(cost), COST_RECT, 26))
	b.add_child(_make_card_label(String(card["title"]), TITLE_RECT, 12, label_col))
	b.add_child(_make_card_label(String(card.get("blurb", "")), BLURB_RECT, 10, label_col))

	b.pressed.connect(cb)
	return b

func _on_card(card) -> void:
	# Clicking a card toggles it in the current combo. The play happens when
	# the user clicks a valid target tile (see _act_on).
	if _ai_running or _combo_animating:
		return
	if selected_cards.has(card):
		selected_cards.erase(card)
	else:
		selected_cards.append(card)
	# Make sure the leader is selected so the combo-targets show.
	if _player_leader() != null and gs.selected != _player_leader():
		gs.selected = _player_leader()
	_on_changed()

func _player_leader():
	for u in gs.units:
		if u.is_alive() and u.team == 0 and u.kind == "leader":
			return u
	return null

# A small overlay that draws the combo ball in HUD (screen) space.
class BallOverlay extends Control:
	var pos: Vector2 = Vector2.ZERO
	var radius: float = 0.0
	var active: bool = false

	func _draw() -> void:
		if not active or radius <= 0.5:
			return
		draw_circle(pos, radius + 8, Color(1, 1, 1, 0.18))
		draw_circle(pos, radius + 3, Color(1, 1, 1, 0.55))
		draw_circle(pos, radius, Color(1, 1, 1))
		draw_circle(pos, radius * 0.55, Color(1, 1, 0.85))
