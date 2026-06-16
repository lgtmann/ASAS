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
	"place_structure": Color(0.85, 0.68, 0.35),
	"ritual": Color(0.80, 0.55, 1.00),
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
	"structure": Color(0.92, 0.82, 0.62),
	"choice": Color(1.00, 0.95, 0.45),
	"ritual": Color(0.80, 0.65, 1.00),
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
# Two-step dig source: the solid cell the player picked first. Cleared once
# the raise destination is picked (or the action is cancelled).

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
const FADE_NEAR_ABOVE := 0.92           # one level above focal (surface protrusions)
const FOG_COLOR := Color(0.66, 0.66, 0.70)   # unseen cube color
const WIRE_ALPHA := 0.55                # outline strength for above-focal cubes
const WIRE_WIDTH := 1.4                 # outline thickness for wireframe cubes

# --- Lighting ----------------------------------------------------------------
# Cheap voxel sun: rays come from up-back-left, so a cell is in shadow when any
# solid cell sits along the ray above it. Shadowed cells render darker. Costs a
# few dictionary lookups per cell, only on (cached) terrain redraws.
const SHADOW_RAY := Vector3i(-1, 1, -1)
const SHADOW_REACH := 4               # how many cells of height cast shadow
const SHADOW_DARKEN := 0.24

func _is_shadowed(c: Vector3i) -> bool:
	for k in range(1, SHADOW_REACH):
		if world.cells.has(c + SHADOW_RAY * k):
			return true
	return false

# --- Sub-cube rendering ------------------------------------------------------
# Each logical cell renders as a 3x3x4 grid of 36 sub-cubes. Game logic stays
# per-cell; this is a pure visual subdivision so cells can carry richer
# geometry (tree stump + canopy, boulder cluster) and random surface divots.
const SUB_X := 3
const SUB_Y := 4               # bottom 3 layers = tree stump, top layer = leaves
const SUB_Z := 3
const TRUNK_COLOR := Color(0.42, 0.28, 0.17)
const CANOPY_COLOR := Color(0.31, 0.55, 0.24)
const FULL_PATTERN := (1 << 36) - 1            # all 36 sub-cubes filled
var _sub_draw_order: Array = []                # filled in _ready

# Filled in _ready (enum values aren't constexpr for a const dict).
var _mat_colors := {}
# Optional sprite override per material — when present, full cells render as
# the texture (matched to iso angle) instead of three flat polygons. Keyed
# by VoxelWorld.Mat id; loaded on startup from res://assets/terrain/.
var _terrain_sprites: Dictionary = {}
# Trees render as ONE tall sprite per column anchored at the bottom cell — the
# segmented (base/trunk/canopy) approach made the trunk widths fight. Variants
# are chosen by hash so each tree column always picks the same look.
var _tree_variants: Array = []
# Small decoration sprites scattered deterministically on grass cells.
var _sprout_variants: Array = []
# Puffy cloudbank sprites drawn over unexplored (fogged) surface cells.
var _cloud_sprites: Array = []
# Building art keyed by building kind (gs.buildings[cell].kind).
var _building_sprites: Dictionary = {}
# Ballista fire animation: 4 sprite frames (loaded/tense/release/settle) and
# the in-flight animations keyed by ballista cell.
var _ballista_rig_tex: Dictionary = {}  # body / bow / spade for BallistaRig
var _ballista_anims: Dictionary = {}   # cell -> fire start time
var projectiles_visible: Array = []    # projectiles past their launch delay
const BALLISTA_LAUNCH_DELAY := 0.58    # rig release moment (T_RELEASE * DUR)

# --- ambient animation (procedural puppet motion + canvas particles) ---
var _anim_t: float = 0.0             # global animation clock (secs)
var _move_anim: Dictionary = {}      # unit -> hop start time
var _lunges: Dictionary = {}         # unit -> {"dir": Vector2, "t0": float}
var _hit_flash: Dictionary = {}      # unit -> flash start time
var _dying: Array = []               # death ghosts: {tex, team, feet, t0}
var _dmg_numbers: Array = []         # {pos, text, t0, col}
var _fx: Array = []                  # particles: {pos, vel, t0, life, col, r}
var _smoke_timers: Dictionary = {}   # building cell -> next puff time
const LUNGE_DUR := 0.22
const FLASH_DUR := 0.25
const DEATH_DUR := 0.7
const DMG_DUR := 0.9
const MAT_FX_COLORS := {
	VoxelWorld.Mat.EARTH: Color(0.55, 0.40, 0.26),
	VoxelWorld.Mat.TREE: Color(0.45, 0.70, 0.30),
	VoxelWorld.Mat.STONE: Color(0.62, 0.62, 0.65),
	VoxelWorld.Mat.GOLD: Color(0.96, 0.80, 0.25),
	VoxelWorld.Mat.CRYSTAL: Color(0.55, 0.82, 1.00),
	VoxelWorld.Mat.OIL: Color(0.20, 0.17, 0.13),
}
# Unit body art keyed by kind — auto-loaded from assets/cards/unit_<kind>.png.
# Missing kinds fall back to the capsule renderer.
var _unit_sprites: Dictionary = {}
const UNIT_SPRITE_SCALE := 0.85     # sprite width relative to TILE_W
const UNIT_GROUND_FRAC := 0.94      # vertical anchor: feet at this image fraction
const UNIT_KINDS := ["operator", "leader", "warrior", "javelin", "plow",
		"wolf", "wizard", "king", "otter", "boat"]

var hud: CanvasLayer
var info_label: Label
var status_label: Label
var hint_label: Label
var end_turn_btn: Button
var level_up_btn: Button
var level_dn_btn: Button
var level_label: Label
var draw_pile_panel: Panel
var draw_pile_label: Label
var discard_pile_panel: Panel
var discard_pile_label: Label
var sim_btn: Button
var restart_btn: Button
var _res_labels: Dictionary = {}       # resource kind -> count Label (sidebar)
var objective_label: Label             # persistent goal chip, top centre
const HINT_CONTROLS := "Click a unit to select; click a highlighted cell to act.  RIGHT-CLICK an enemy to attack (swing adjacent / throw at range); right-click elsewhere cancels.  Wheel zooms; Shift+wheel scrolls levels."
var build_modal_btn: Button
var _modal: Panel = null               # active modal (choice / harvest confirm)
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

# Static-terrain cache. The cube grid is moved to its own child Node2D whose
# _draw only fires when the terrain (or vision, or view level, or quake) has
# actually changed. iso_view's own _draw handles the dynamic layer (highlights,
# units, spades, projectiles, flow arrows) every frame as before.
var terrain_layer: TerrainLayer
# Drawing target redirection. _draw routes cube draw calls to whichever
# canvas should receive them — `terrain_layer` from terrain redraws, `self`
# from dynamic redraws. Polygon helpers in _draw_cube etc. read this.
var _draw_canvas: CanvasItem = null
# Sorted cell-key cache for the terrain pass (sorting ~1500 keys with a
# GDScript comparator every redraw is expensive). Rebuilt when cells change.
var _terrain_keys: Array = []
var _terrain_keys_dirty: bool = true
# Trackers so _on_changed only invalidates the terrain cache when something
# terrain-visible actually changed (vision growth or focal-level change).
var _last_seen_size: int = -1
var _last_tl_view_level: int = -999

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
	add_child(world)
	_sub_draw_order = _compute_sub_draw_order()

	_mat_colors[VoxelWorld.Mat.EARTH] = Color(0.55, 0.40, 0.26)
	_load_terrain_sprites()
	_mat_colors[VoxelWorld.Mat.GOLD] = Color(0.96, 0.78, 0.20)
	_mat_colors[VoxelWorld.Mat.WATER] = Color(0.28, 0.55, 0.85)
	_mat_colors[VoxelWorld.Mat.CRYSTAL] = Color(0.45, 0.78, 1.00)
	_mat_colors[VoxelWorld.Mat.RELIC] = Color(0.82, 0.38, 0.95)
	_mat_colors[VoxelWorld.Mat.OIL] = Color(0.15, 0.12, 0.08)
	_mat_colors[VoxelWorld.Mat.STONE] = Color(0.55, 0.55, 0.58)
	_mat_colors[VoxelWorld.Mat.TREE] = Color(0.30, 0.45, 0.22)
	_mat_colors[VoxelWorld.Mat.LADDER] = Color(0.78, 0.62, 0.38)
	_mat_colors[VoxelWorld.Mat.BRIDGE] = Color(0.62, 0.45, 0.28)
	_mat_colors[VoxelWorld.Mat.BALLISTA] = Color(0.38, 0.30, 0.24)
	_mat_colors[VoxelWorld.Mat.BUILDING] = Color(0.72, 0.62, 0.45)

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
	gs.area_cleared.connect(_on_area_cleared)
	gs.campaign_won.connect(func(): _show_end_screen(true))
	gs.unit_attacked.connect(_on_unit_attacked)
	gs.unit_damaged.connect(_on_unit_damaged)
	gs.unit_died.connect(_on_unit_died)
	gs.terrain_hit.connect(_on_terrain_hit)
	gs.ballista_fired.connect(_on_ballista_fired)
	gs.unit_dug.connect(_on_unit_action.bind("dig"))
	# --- audio: the signal layer drives every sound ---
	gs.terrain_hit.connect(func(_cell, mat): Sfx.terrain(mat))
	gs.unit_damaged.connect(func(_u, _a): Sfx.play("hit", 0.12))
	gs.unit_died.connect(func(_u, _g): Sfx.play("death", 0.06))
	gs.unit_attacked.connect(func(_u, _c): Sfx.play("swing", 0.10))
	gs.unit_threw.connect(func(_u, _c): Sfx.play("throw", 0.08))
	gs.unit_fished.connect(func(_u): Sfx.play("splash", 0.08))
	gs.ballista_fired.connect(func(_c): Sfx.play("ballista", 0.05))
	gs.cards_drawn.connect(func(_n): Sfx.play("card", 0.15))
	gs.quake_started.connect(func(_cols): Sfx.play("quake", 0.04))
	gs.area_cleared.connect(func(_n): Sfx.play("victory", 0.0))
	gs.game_over.connect(func(_w): Sfx.play("death", 0.0, -2.0))
	gs.unit_animated_move.connect(func(_u, _f, _t): Sfx.play("step", 0.20, -14.0))
	Sfx.ambient_start()
	gs.unit_threw.connect(_on_unit_threw)
	gs.unit_fished.connect(func(u): _start_action(u, "fish", Vector2.RIGHT))

	# Stand up the terrain cache layer AFTER world is ready and before _build_hud.
	terrain_layer = TerrainLayer.new()
	terrain_layer.view = self
	terrain_layer.z_index = -1
	add_child(terrain_layer)
	world.cells_changed.connect(_on_cells_changed)

	_build_hud()
	if Meta.RunSave.pending_load:
		Meta.RunSave.pending_load = false
		var run_data: Dictionary = Meta.RunSave.read()
		if run_data.is_empty():
			gs.start()
		else:
			gs.start_from_save(run_data)
	else:
		gs.start()
	_select(gs.selected)
	# Player base is in the near corner — pan the camera so it starts centred.
	if gs.selected != null:
		_center_on(gs.selected.grid)
	_play_battle_intro()
	queue_redraw()
	_maybe_spawn_showcase()
	_maybe_spawn_built_showcase()
	_maybe_screenshot_and_quit()

# `--showcase` spawns one unit of every kind near the player base (alternating
# teams) so a single screenshot shows all unit art — the art pipeline's judge
# looks at this to verify sprites landed correctly.
func _maybe_spawn_showcase() -> void:
	if not ("--showcase" in OS.get_cmdline_user_args()):
		return
	var lead = gs.selected
	if lead == null:
		return
	for i in UNIT_KINDS.size():
		var kind: String = UNIT_KINDS[i]
		var spot: Vector3i = gs._free_spot_near(
			lead.grid.x - 4 + (i % 5) * 2, lead.grid.z - 4 + (i / 5) * 2)
		var u = gs._spawn_unit(i % 2, spot, kind in ["operator", "warrior", "javelin"])
		u.kind = kind
	gs.recompute_vision()
	queue_redraw()

# `--showcase-built` places one of every building + ladder / bridge /
# ballista near the player base so one screenshot verifies built-item art.
func _maybe_spawn_built_showcase() -> void:
	if not ("--showcase-built" in OS.get_cmdline_user_args()):
		return
	var lead = gs.selected
	if lead == null:
		return
	var kinds := ["waterwheel", "storehouse", "village", "trebuchet",
			"farm", "campsite", "barracks"]
	for i in kinds.size():
		var spot: Vector3i = gs._free_spot_near(
			lead.grid.x - 6 + (i % 4) * 2, lead.grid.z - 6 + (i / 4) * 2)
		if world.is_standable(spot):
			world.set_material(spot, VoxelWorld.Mat.BUILDING)
			gs.buildings[spot] = {"kind": kinds[i], "team": 0, "timer": 2}
	var bspot: Vector3i = gs._free_spot_near(lead.grid.x + 2, lead.grid.z - 5)
	if world.is_standable(bspot):
		world.set_material(bspot, VoxelWorld.Mat.BALLISTA)
		gs.ballistas.append({"grid": bspot, "team": 0})
	var lspot: Vector3i = gs._free_spot_near(lead.grid.x + 3, lead.grid.z - 3)
	if world.is_standable(lspot):
		world.set_material(lspot, VoxelWorld.Mat.LADDER)
	var brspot: Vector3i = gs._free_spot_near(lead.grid.x + 4, lead.grid.z - 1)
	if world.is_standable(brspot):
		world.set_material(brspot, VoxelWorld.Mat.BRIDGE)
	gs.recompute_vision()
	queue_redraw()

# Art-pipeline harness: `godot --path . -- --screenshot=/tmp/shot.png
# [--seed=42] [--focus=x,z] [--shot-zoom=1.5]` boots the game, waits for the
# terrain + sprites to render, saves the viewport to PNG, and exits. Lets the
# asset loop verify its own work without screen-recording permissions.
func _maybe_screenshot_and_quit() -> void:
	var out_path := ""
	var focus := Vector2i(-1, -1)
	var shot_zoom := 0.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshot="):
			out_path = arg.trim_prefix("--screenshot=")
		elif arg.begins_with("--focus="):
			var parts: PackedStringArray = arg.trim_prefix("--focus=").split(",")
			if parts.size() == 2:
				focus = Vector2i(int(parts[0]), int(parts[1]))
		elif arg.begins_with("--shot-zoom="):
			shot_zoom = float(arg.trim_prefix("--shot-zoom="))
	var intro_t := -1.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--intro-t="):
			intro_t = float(arg.trim_prefix("--intro-t="))
	if out_path == "":
		return
	if intro_t >= 0.0:
		var intro := BattleIntro.new()
		intro.setup("ENGAGE THE ENEMY")
		intro.freeze_at(intro_t)
		hud.add_child(intro)
	if shot_zoom > 0.0:
		zoom = shot_zoom
		scale = Vector2(zoom, zoom)
	if focus.x >= 0:
		_center_on(Vector3i(focus.x, VoxelWorld.GROUND + 1, focus.y))
	# Two seconds: lets card-draw tweens finish and the terrain cache settle.
	await get_tree().create_timer(2.0).timeout
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(out_path)
	print("SCREENSHOT_SAVED: ", out_path)
	get_tree().quit()

# Pan the view so grid cell `g` lands mid-screen.
func _center_on(g: Vector3i) -> void:
	var target: Vector2 = iso_pt(float(g.x) + 0.5, float(g.y), float(g.z) + 0.5)
	position = Vector2(800, 420) - target * zoom

# --- Continuous ground -------------------------------------------------------
# Earth renders as flat colour planes instead of tiled outlined cubes: adjacent
# top faces share edges exactly, so the surface reads as ONE plane. Dark
# contour lines are drawn only where the plane breaks — height steps, cliff
# lips, water banks, the map silhouette — so the world looks like terrain, not
# a grid. (Cells remain individually selectable; highlights are unaffected.)
const EARTH_TOP := Color(0.80, 0.52, 0.22)
const EARTH_RIGHT := Color(0.66, 0.33, 0.15)
const EARTH_LEFT := Color(0.52, 0.22, 0.13)
const GROUND_OUTLINE := Color(0.06, 0.04, 0.05)
const OUTLINE_W := 3.5
const STRATA_W := 2.0

# Is the neighbouring column part of the same walkable plane? (Earth at the
# same level with nothing solid on top — then no line between us.)
func _same_plane(n: Vector3i) -> bool:
	return world.material_at(n) == VoxelWorld.Mat.EARTH \
			and not world.is_solid(n + Vector3i(0, 1, 0))

func _draw_flat_earth(c: Vector3i, alpha: float, shake: Vector2, shadowed: bool) -> void:
	var dk: float = (1.0 - SHADOW_DARKEN) if shadowed else 1.0
	var up := Vector3i(0, 1, 0)
	var t_back: Vector2 = iso(c + Vector3i(0, 1, 0)) + shake
	var t_right: Vector2 = iso(c + Vector3i(1, 1, 0)) + shake
	var t_front: Vector2 = iso(c + Vector3i(1, 1, 1)) + shake
	var t_left: Vector2 = iso(c + Vector3i(0, 1, 1)) + shake
	var b_right: Vector2 = iso(c + Vector3i(1, 0, 0)) + shake
	var b_front: Vector2 = iso(c + Vector3i(1, 0, 1)) + shake
	var b_left: Vector2 = iso(c + Vector3i(0, 0, 1)) + shake
	var top_exposed: bool = not world.is_solid(c + up)
	var right_exposed: bool = not world.is_solid(c + Vector3i(1, 0, 0))
	var left_exposed: bool = not world.is_solid(c + Vector3i(0, 0, 1))

	if top_exposed:
		var tc := Color(EARTH_TOP.r * dk, EARTH_TOP.g * dk, EARTH_TOP.b * dk, alpha)
		_draw_canvas.draw_colored_polygon(
			PackedVector2Array([t_back, t_right, t_front, t_left]), tc)
	if right_exposed:
		var rc := Color(EARTH_RIGHT.r * dk, EARTH_RIGHT.g * dk, EARTH_RIGHT.b * dk, alpha)
		_draw_canvas.draw_colored_polygon(
			PackedVector2Array([t_right, t_front, b_front, b_right]), rc)
		_draw_strata(t_right, t_front, b_right, b_front, rc, alpha)
	if left_exposed:
		var lc := Color(EARTH_LEFT.r * dk, EARTH_LEFT.g * dk, EARTH_LEFT.b * dk, alpha)
		_draw_canvas.draw_colored_polygon(
			PackedVector2Array([t_front, t_left, b_left, b_front]), lc)
		_draw_strata(t_front, t_left, b_front, b_left, lc, alpha)

	# Contour outlines: a top edge gets a line only when the neighbour does
	# NOT continue the same plane (height change, water, map edge, other mat).
	if top_exposed:
		var oc := Color(GROUND_OUTLINE.r, GROUND_OUTLINE.g, GROUND_OUTLINE.b, alpha)
		var edges := [
			[Vector3i(0, 0, -1), t_back, t_right],
			[Vector3i(1, 0, 0), t_right, t_front],
			[Vector3i(0, 0, 1), t_front, t_left],
			[Vector3i(-1, 0, 0), t_left, t_back],
		]
		for e in edges:
			if not _same_plane(c + e[0]):
				_draw_canvas.draw_line(e[1], e[2], oc, OUTLINE_W)
	# Cliff silhouette: front vertical corner where both faces show, and the
	# bottom lip where a face meets a lower floor instead of more cliff.
	var oc2 := Color(GROUND_OUTLINE.r, GROUND_OUTLINE.g, GROUND_OUTLINE.b, alpha * 0.9)
	if right_exposed and left_exposed:
		_draw_canvas.draw_line(t_front, b_front, oc2, OUTLINE_W)
	var below := c + Vector3i(0, -1, 0)
	if right_exposed and not (world.is_solid(below) and not world.is_solid(below + Vector3i(1, 0, 0))):
		_draw_canvas.draw_line(b_right, b_front, oc2, OUTLINE_W)
	if left_exposed and not (world.is_solid(below) and not world.is_solid(below + Vector3i(0, 0, 1))):
		_draw_canvas.draw_line(b_front, b_left, oc2, OUTLINE_W)

# Faint horizontal soil bands on exposed cliff faces. Bands sit at fixed
# height fractions, so they align across neighbouring columns into continuous
# strata lines.
func _draw_strata(ta: Vector2, tb: Vector2, ba: Vector2, bb: Vector2, base: Color, alpha: float) -> void:
	var band := Color(base.r * 0.82, base.g * 0.82, base.b * 0.82, alpha * 0.8)
	for f in [0.38, 0.72]:
		_draw_canvas.draw_line(ta.lerp(ba, f), tb.lerp(bb, f), band, STRATA_W)

# --- Continuous water ----------------------------------------------------------
# Water renders like the ground: one flat recessed plane per connected river,
# with a dark waterline and a pale foam inset only along the banks. Moving
# foam streaks (live layer) replace the old chevron arrows.
const WATER_TOP := Color(0.13, 0.16, 0.46)
const WATER_SIDE := Color(0.09, 0.10, 0.32)
const WATER_LINE := Color(0.05, 0.03, 0.06)
const WATER_FOAM := Color(0.96, 0.90, 0.72, 0.55)
const WATER_LEVEL := 0.70      # surface height within the cell (slightly recessed)

func _water_at(n: Vector3i) -> bool:
	return world.is_water(n)

func _draw_flat_water(c: Vector3i, alpha: float, shake: Vector2, shadowed: bool) -> void:
	var dk: float = (1.0 - SHADOW_DARKEN) if shadowed else 1.0
	var y: float = float(c.y) + WATER_LEVEL
	var s_back: Vector2 = iso_pt(float(c.x), y, float(c.z)) + shake
	var s_right: Vector2 = iso_pt(float(c.x) + 1.0, y, float(c.z)) + shake
	var s_front: Vector2 = iso_pt(float(c.x) + 1.0, y, float(c.z) + 1.0) + shake
	var s_left: Vector2 = iso_pt(float(c.x), y, float(c.z) + 1.0) + shake
	var centre: Vector2 = (s_back + s_front) * 0.5
	var tc := Color(WATER_TOP.r * dk, WATER_TOP.g * dk, WATER_TOP.b * dk, alpha)
	_draw_canvas.draw_colored_polygon(
		PackedVector2Array([s_back, s_right, s_front, s_left]), tc)
	# Exposed sides (map edge): flat darker panel down to the cell floor.
	for side in [[Vector3i(1, 0, 0), s_right, s_front, Vector3i(1, 0, 0), Vector3i(1, 0, 1)],
			[Vector3i(0, 0, 1), s_front, s_left, Vector3i(1, 0, 1), Vector3i(0, 0, 1)]]:
		var n: Vector3i = c + side[0]
		if not world.in_bounds(n) or (not world.is_solid(n) and not _water_at(n)):
			var ba: Vector2 = iso(c + side[3]) + shake
			var bb: Vector2 = iso(c + side[4]) + shake
			var sc := Color(WATER_SIDE.r * dk, WATER_SIDE.g * dk, WATER_SIDE.b * dk, alpha)
			_draw_canvas.draw_colored_polygon(
				PackedVector2Array([side[1], side[2], bb, ba]), sc)
	# Banks: dark waterline + pale foam inset where the neighbour isn't water.
	var edges := [
		[Vector3i(0, 0, -1), s_back, s_right],
		[Vector3i(1, 0, 0), s_right, s_front],
		[Vector3i(0, 0, 1), s_front, s_left],
		[Vector3i(-1, 0, 0), s_left, s_back],
	]
	for e in edges:
		if _water_at(c + e[0]):
			continue
		var a: Vector2 = e[1]
		var b: Vector2 = e[2]
		_draw_canvas.draw_line(a, b, Color(WATER_LINE.r, WATER_LINE.g, WATER_LINE.b, alpha), 2.2)
		var fa: Vector2 = a.lerp(centre, 0.13)
		var fb: Vector2 = b.lerp(centre, 0.13)
		var foam := WATER_FOAM
		foam.a *= alpha
		_draw_canvas.draw_line(fa, fb, foam, 2.0)

# Pull any present terrain art into the sprite override table. Each entry
# maps a material to its texture; missing files silently fall back to the
# polygon renderer, so artwork can be added one terrain type at a time.
func _load_terrain_sprites() -> void:
	var manifest := {
		VoxelWorld.Mat.STONE: "res://assets/cards/boulder.png",
		VoxelWorld.Mat.LADDER: "res://assets/cards/ladder.png",
		VoxelWorld.Mat.BRIDGE: "res://assets/cards/bridge.png",
	}
	for mat in manifest:
		var path: String = manifest[mat]
		if ResourceLoader.exists(path):
			_terrain_sprites[mat] = load(path)
	for tpath in ["res://assets/cards/tree_1.png", "res://assets/cards/tree_2.png",
			"res://assets/cards/dead_tree_1.png", "res://assets/cards/dead_tree_2.png"]:
		if ResourceLoader.exists(tpath):
			_tree_variants.append(load(tpath))
	for entry in [["body", "res://assets/cards/ballista_body.png"],
			["bow", "res://assets/cards/ballista_arm_left.png"],
			["spade", "res://assets/cards/ballista_spade_loaded.png"]]:
		if ResourceLoader.exists(entry[1]):
			_ballista_rig_tex[entry[0]] = load(entry[1])
	for bkind in ["waterwheel", "storehouse", "village", "trebuchet",
			"farm", "campsite", "barracks"]:
		var bpath: String = "res://assets/cards/building_%s.png" % bkind
		if ResourceLoader.exists(bpath):
			_building_sprites[bkind] = load(bpath)
	for cp in ["res://assets/cards/cloud_1.png", "res://assets/cards/cloud_2.png"]:
		if ResourceLoader.exists(cp):
			_cloud_sprites.append(load(cp))
	for sp in ["res://assets/cards/sprout_tall.png",
			"res://assets/cards/sprout_bush.png",
			"res://assets/cards/sprout_flower.png"]:
		if ResourceLoader.exists(sp):
			_sprout_variants.append(load(sp))
	for kind in UNIT_KINDS:
		var upath: String = "res://assets/cards/unit_%s.png" % kind
		if ResourceLoader.exists(upath):
			_unit_sprites[kind] = load(upath)

# Pick a tree variant deterministically by column position so the same column
# always draws the same tree.
func _tree_variant_for(c: Vector3i) -> Texture2D:
	if _tree_variants.is_empty():
		return null
	var h: int = (c.x * 73856093) ^ (c.z * 19349663)
	return _tree_variants[absi(h) % _tree_variants.size()]

# Full tree sprite — anchored at the BOTTOM tree cell so the grass base lands
# on the surface and the canopy sticks up through the air cells above.
const TREE_SPRITE_SCALE := 1.55       # how wide the canopy reads vs a cube
const TREE_GROUND_FRAC := 0.92        # where in the image the grass base sits
									  # (vertical fraction from top, 0..1)
func _draw_tree(c: Vector3i, alpha: float, shake: Vector2, shadowed: bool) -> void:
	var tex: Texture2D = _tree_variant_for(c)
	if tex == null:
		return
	var sprite_w: float = TILE_W * TREE_SPRITE_SCALE
	var sprite_h: float = sprite_w * float(tex.get_height()) / float(tex.get_width())
	# Anchor: the grass base in the image (TREE_GROUND_FRAC down from top) lands
	# at the bottom-front lip of the cell (cell_centre + HEIGHT_STEP/2).
	var centre: Vector2 = iso_pt(float(c.x) + 0.5, float(c.y) + 0.5, float(c.z) + 0.5) + shake
	var ground_y: float = centre.y + HEIGHT_STEP * 0.5
	var rect := Rect2(
		centre.x - sprite_w * 0.5,
		ground_y - sprite_h * TREE_GROUND_FRAC,
		sprite_w, sprite_h
	)
	var tint := Color(1, 1, 1, alpha)
	if shadowed:
		var d: float = 1.0 - SHADOW_DARKEN
		tint = Color(d, d, d, alpha)
	_draw_canvas.draw_texture_rect(tex, rect, false, tint)

# The fog cloudbank, live edition: puffs anchored over fogged surface cells,
# each drifting in a slow closed orbit around its anchor (so the bank wanders
# without ever escaping the fog) and breathing slightly in scale. The puff
# list rebuilds whenever vision changes; drawing happens every frame on the
# live canvas.
var _cloud_puffs: Array = []
var _cloud_key: String = ""

func _refresh_cloud_puffs() -> void:
	if _cloud_sprites.is_empty():
		return
	var key: String = "%d|%d" % [gs.seen.size(), world.version]
	if key == _cloud_key:
		return
	_cloud_key = key
	_cloud_puffs.clear()
	var up := Vector3i(0, 1, 0)
	for cell_v in world.cells.keys():
		var c: Vector3i = cell_v
		if gs.seen.has(c) or world.is_solid(c + up):
			continue
		var h: int = _wang_hash(c.x * 198491317 + c.z * 6542989)
		var anchor: Vector2 = iso_pt(float(c.x) + 0.5, float(c.y) + 1.6, float(c.z) + 0.5)
		var n_puffs: int = 1 + (h % 2)
		for i in n_puffs:
			var hh: int = _wang_hash(h + i * 7919)
			var tex: Texture2D = _cloud_sprites[hh % _cloud_sprites.size()]
			var w: float = TILE_W * (1.6 + float((hh >> 8) % 100) / 100.0)
			var jx: float = (float((hh >> 12) % 100) / 100.0 - 0.5) * TILE_W * 0.7
			var jy: float = (float((hh >> 19) % 100) / 100.0 - 0.5) * TILE_H * 0.8
			_cloud_puffs.append({
				"tex": tex,
				"pos": anchor + Vector2(jx, jy),
				"w": w,
				"ax": 8.0 + float((hh >> 5) % 8),
				"ay": 3.0 + float((hh >> 9) % 4),
				"fa": 0.10 + float((hh >> 13) % 10) * 0.012,
				"fb": 0.07 + float((hh >> 16) % 10) * 0.010,
				"ph": float(hh % 628) / 100.0,
			})

func _draw_cloud_layer() -> void:
	for puff in _cloud_puffs:
		var tex: Texture2D = puff["tex"]
		var drift := Vector2(
			sin(_anim_t * float(puff["fa"]) * TAU + float(puff["ph"])) * float(puff["ax"]),
			sin(_anim_t * float(puff["fb"]) * TAU + float(puff["ph"]) * 1.7) * float(puff["ay"]))
		var breathe: float = 1.0 + 0.04 * sin(_anim_t * 0.35 * TAU + float(puff["ph"]))
		var w: float = float(puff["w"]) * breathe
		var ch: float = w * float(tex.get_height()) / float(tex.get_width())
		var pos: Vector2 = Vector2(puff["pos"]) + drift
		draw_texture_rect(tex, Rect2(pos.x - w * 0.5, pos.y - ch * 0.5, w, ch),
			false, Color(1, 1, 1, 0.93))


# Avalanche hash — decorrelates neighbouring cells and slots. The previous
# multiplicative hash had linear structure that made the scatter form visible
# diagonal bands across the meadow.
func _wang_hash(v: int) -> int:
	v = (v ^ 61) ^ ((v >> 16) & 0xFFFF)
	v = (v * 9) & 0xFFFFFFFF
	v = v ^ (v >> 4)
	v = (v * 0x27D4EB2D) & 0xFFFFFFFF
	v = v ^ (v >> 15)
	return v

# Flat translucent green wash over the exposed top face — turns bare dirt
# tops into continuous meadow ground without the chunky 3D mat. Exactly
# matches the face diamond, so adjacent cells share edges with no seams.
const GRASS_TINT := Color(0.72, 0.50, 0.12, 0.20)   # subtle warm gold wash
func _draw_grass_tint(c: Vector3i, alpha: float, shake: Vector2, shadowed: bool) -> void:
	var col := GRASS_TINT
	if shadowed:
		col = col.darkened(SHADOW_DARKEN)
	col.a = GRASS_TINT.a * alpha
	var pts: PackedVector2Array = top_face(c)
	if shake != Vector2.ZERO:
		for i in pts.size():
			pts[i] += shake
	_draw_canvas.draw_colored_polygon(pts, col)

# Macro patchiness: 2x2 blocks of cells share a lushness tier, so the meadow
# reads as thick patches with thinner clearings instead of uniform speckle.
func _cell_lushness(c: Vector3i) -> float:
	var bh: int = _wang_hash((c.x >> 1) * 198491317 + (c.z >> 1) * 6542989)
	match bh % 4:
		0: return 0.15
		1: return 0.35
		_: return 0.60

# Up to SPROUT_SLOTS decoration sprites per grass cell, hashed from the cell
# coordinate so the layout never shimmers between redraws. All of this lands
# on the CACHED terrain layer — zero per-frame cost; it only re-renders when
# terrain actually changes.
const SPROUT_SLOTS := 5
const SPROUT_GROUND_FRAC := 0.85       # vertical anchor within each sprite
func _draw_sprouts(c: Vector3i, alpha: float, shake: Vector2, shadowed: bool) -> void:
	if _sprout_variants.is_empty():
		return
	var lush: float = _cell_lushness(c)
	var base_h: int = _wang_hash(c.x * 374761393 + c.z * 668265263)
	var top: Vector2 = iso_pt(float(c.x) + 0.5, float(c.y) + 1, float(c.z) + 0.5) + shake
	var tint := Color(1, 1, 1, alpha)
	if shadowed:
		var d: float = 1.0 - SHADOW_DARKEN
		tint = Color(d, d, d, alpha)
	# Collect first, then paint back-to-front so overlapping tufts layer
	# correctly within the cell.
	var draws: Array = []
	for i in SPROUT_SLOTS:
		var h: int = _wang_hash(base_h + i * 974711)
		if float(h % 1000) / 1000.0 > lush:
			continue
		var h2: int = _wang_hash(h)
		# Weighted variants: bushes carry the grass mass, tall blades second,
		# flowers as the rare accent. (Load order: tall, bush, flower.)
		var variant: int
		if _sprout_variants.size() == 3:
			var vroll: int = h2 % 100
			variant = 0 if vroll < 30 else (1 if vroll < 85 else 2)
		else:
			variant = h2 % _sprout_variants.size()
		var ox: float = float((h2 >> 8) & 0x3FF) / 1023.0 - 0.5
		var oz: float = float((h2 >> 18) & 0x3FF) / 1023.0 - 0.5
		# Spread reaches the cell edge so tufts spill across boundaries and
		# blur the lattice.
		var pos: Vector2 = top + Vector2(
			(ox - oz) * TILE_W * 0.45,
			(ox + oz) * TILE_H * 0.45
		)
		var scl: float = 0.32 + 0.30 * float(_wang_hash(h2 + 7919) & 0xFF) / 255.0
		draws.append({"y": pos.y, "pos": pos, "tex": _sprout_variants[variant], "scl": scl})
	draws.sort_custom(func(a, b): return a["y"] < b["y"])
	for d2 in draws:
		var tex: Texture2D = d2["tex"]
		var sprite_w: float = TILE_W * float(d2["scl"])
		var sprite_h: float = sprite_w * float(tex.get_height()) / float(tex.get_width())
		var pos2: Vector2 = d2["pos"]
		var rect := Rect2(
			pos2.x - sprite_w * 0.5,
			pos2.y - sprite_h * SPROUT_GROUND_FRAC,
			sprite_w, sprite_h
		)
		_draw_canvas.draw_texture_rect(tex, rect, false, tint)

# Should this EARTH cell get a grass mat overlay? True when the cell above is
# non-solid (air, water, etc.) — i.e. the earth's top face is exposed to sky.
func _grass_caps(c: Vector3i) -> bool:
	var above: Vector3i = c + Vector3i(0, 1, 0)
	return world.in_bounds(above) and not world.is_solid(above)

# Render a cube cell as a single sprite. The bounding rect is sized so the
# texture's cube portion lines up with the 3-polygon footprint it replaces:
# TILE_W wide, with the (taller) sprite anchored at the cube's bottom-front
# corner so any grass / overhang above the cube line just sticks up naturally.
# Grok generates cubes that fill only ~70% of the image frame. To make the
# rendered cube fill its footprint (instead of leaving gaps where adjacent
# cells' lower cubes peek through) we OVERSIZE the sprite so its depicted
# cube portion lands at exactly TILE_W wide. Neighbouring sprites then
# overlap and the existing back-to-front draw order hides the seams.
const TERRAIN_SPRITE_SCALE := 1.45     # fudge factor — how much bigger than TILE_W
const TERRAIN_SPRITE_V_NUDGE := 6.0    # px to shift sprites down, since image
									   # cubes tend to sit a bit below image centre
# Per-material overrides: scale & v-offset for sprites whose visual centre
# doesn't sit at the cube centre. Falls back to the constants above.
#  - WATER sits at the TOP of its cell (river surface), not centre.
#  - STONE is a rounded boulder, smaller than a full cube.
const _TERRAIN_OVERRIDES := {
	VoxelWorld.Mat.STONE: {"scale": 1.10, "v": 4.0},
	VoxelWorld.Mat.LADDER: {"scale": 1.15, "v": 0.0},
	VoxelWorld.Mat.BRIDGE: {"scale": 1.45, "v": -11.0},   # deck at the top face
	VoxelWorld.Mat.BALLISTA: {"scale": 1.30, "v": 2.0},
}

func _draw_terrain_sprite(c: Vector3i, mat: int, alpha: float, shake: Vector2, shadowed: bool) -> void:
	var tex: Texture2D = _terrain_sprites[mat]
	if tex == null:
		return
	var override: Dictionary = _TERRAIN_OVERRIDES.get(mat, {})
	var scale: float = float(override.get("scale", TERRAIN_SPRITE_SCALE))
	var v_off: float = float(override.get("v", TERRAIN_SPRITE_V_NUDGE))
	var center: Vector2 = iso_pt(float(c.x) + 0.5, float(c.y) + 0.5, float(c.z) + 0.5) + shake
	var sprite_w: float = TILE_W * scale
	var sprite_h: float = sprite_w * float(tex.get_height()) / float(tex.get_width())
	var rect := Rect2(
		center.x - sprite_w * 0.5,
		center.y - sprite_h * 0.5 + v_off,
		sprite_w, sprite_h
	)
	var tint := Color(1, 1, 1, alpha)
	if shadowed:
		var d: float = 1.0 - SHADOW_DARKEN
		tint = Color(d, d, d, alpha)
	_draw_canvas.draw_texture_rect(tex, rect, false, tint)

# Building sprite: bottom edge sits at the cell's bottom-front lip, width a
# touch wider than the cube so roofs/wheels read; height extends upward
# naturally (1:1 art is ~1.7 cube-heights tall).
func _draw_building_sprite(c: Vector3i, tex: Texture2D, alpha: float, shake: Vector2, shadowed: bool) -> void:
	var centre: Vector2 = iso_pt(float(c.x) + 0.5, float(c.y) + 0.5, float(c.z) + 0.5) + shake
	var w: float = TILE_W * 1.5
	var h: float = w * float(tex.get_height()) / float(tex.get_width())
	var ground_y: float = centre.y + (TILE_H + HEIGHT_STEP) * 0.5
	var rect := Rect2(centre.x - w * 0.5, ground_y - h, w, h)
	var tint := Color(1, 1, 1, alpha)
	if shadowed:
		var d: float = 1.0 - SHADOW_DARKEN
		tint = Color(d, d, d, alpha)
	_draw_canvas.draw_texture_rect(tex, rect, false, tint)

# ------------------------------------------------------------- animation fx

func _on_unit_attacked(attacker, target_grid: Vector3i) -> void:
	var from: Vector2 = iso_pt(attacker.draw_pos.x, attacker.draw_pos.y, attacker.draw_pos.z)
	var to: Vector2 = iso_pt(float(target_grid.x) + 0.5, float(target_grid.y), float(target_grid.z) + 0.5)
	var d: Vector2 = to - from
	_lunges[attacker] = {"dir": d.normalized() if d.length() > 0.5 else Vector2.RIGHT,
			"t0": _anim_t}
	if attacker.spade != null:
		_start_action(attacker, "swing", d)

func _on_unit_damaged(u, amount: int) -> void:
	_hit_flash[u] = _anim_t
	var feet: Vector2 = iso_pt(u.draw_pos.x, u.draw_pos.y, u.draw_pos.z)
	_dmg_numbers.append({"pos": feet + Vector2(0, -HEIGHT_STEP * 1.8),
		"text": "-%d" % amount, "t0": _anim_t,
		"col": Color(1.0, 0.32, 0.25) if u.team == 0 else Color(1.0, 0.88, 0.30)})
	_spawn_burst(feet + Vector2(0, -10), Color(1, 1, 1, 0.9), 5, 60.0)

func _on_unit_died(u, _grid: Vector3i) -> void:
	_dying.append({"tex": _unit_sprites.get(u.kind), "team": u.team,
		"feet": iso_pt(u.draw_pos.x, u.draw_pos.y, u.draw_pos.z), "t0": _anim_t})

var _ballista_shot_pending: bool = false
var _unit_throw_pending: bool = false
# Operator action animations: unit -> {type, t0, dir}. The held spade is a
# separate PROP sprite posed over the unit (the ballista two-asset pattern):
# dig plunges it, swing arcs it, throw winds up then hands off to the
# projectile, fishing dangles it over the water.
var _action_anims: Dictionary = {}

func _start_action(u, type: String, dir: Vector2) -> void:
	_action_anims[u] = {"type": type, "t0": _anim_t,
		"dir": dir.normalized() if dir.length() > 0.01 else Vector2.RIGHT}

func _on_unit_action(u, cell: Vector3i, type: String) -> void:
	var from: Vector2 = iso_pt(u.draw_pos.x, u.draw_pos.y, u.draw_pos.z)
	var to: Vector2 = iso_pt(float(cell.x) + 0.5, float(cell.y), float(cell.z) + 0.5)
	_start_action(u, type, to - from)

func _on_unit_threw(u, cell: Vector3i) -> void:
	_on_unit_action(u, cell, "throw")
	_unit_throw_pending = true     # the next spade_thrown waits out the windup

func _on_ballista_fired(cell: Vector3i) -> void:
	if not _ballista_rig_tex.is_empty():
		_ballista_anims[cell] = _anim_t
		_ballista_shot_pending = true   # next spade_thrown gets the launch delay

# Every ballista draws as a live-layer rig: idle loaded pose normally, the
# smooth fire cycle when firing. Same footprint the static sprite used.
func _draw_ballista_anims() -> void:
	if _ballista_rig_tex.is_empty():
		return
	for b in gs.ballistas:
		var cell: Vector3i = b["grid"]
		if not gs.seen.has(cell):
			continue
		var t: float = -1.0
		if _ballista_anims.has(cell):
			t = (_anim_t - float(_ballista_anims[cell])) / BallistaRig.DUR
			if t > 1.0:
				_ballista_anims.erase(cell)
				t = -1.0
		var centre: Vector2 = iso_pt(float(cell.x) + 0.5, float(cell.y) + 0.5, float(cell.z) + 0.5)
		var w: float = TILE_W * 1.30
		BallistaRig.draw(self, Rect2(centre.x - w * 0.5, centre.y - w * 0.5 + 2.0, w, w),
			t, _ballista_rig_tex)


func _on_terrain_hit(cell: Vector3i, mat: int) -> void:
	var top: Vector2 = iso_pt(float(cell.x) + 0.5, float(cell.y + 1), float(cell.z) + 0.5)
	_spawn_burst(top, MAT_FX_COLORS.get(mat, Color(0.55, 0.40, 0.26)), 8, 80.0)

func _spawn_burst(pos: Vector2, col: Color, n: int, speed: float) -> void:
	for i in n:
		var ang: float = randf() * TAU
		var v := Vector2(cos(ang), sin(ang) * 0.6) * speed * (0.5 + randf() * 0.8)
		v.y -= speed * 0.7      # pop upward, gravity pulls back in _process
		_fx.append({"pos": pos, "vel": v, "t0": _anim_t,
			"life": 0.45 + randf() * 0.3, "col": col, "r": 2.0 + randf() * 2.5})

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
	# Dynamic pass: highlights, units, dropped spades, flow arrows, projectiles.
	# Terrain cubes live on `terrain_layer` (z_index = -1, drawn behind us),
	# which only redraws when something terrain-relevant changes.
	_draw_canvas = self
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
	_draw_streamlines()
	_draw_cloud_layer()
	_draw_ballista_anims()
	_draw_projectiles()
	_draw_fx()

func _draw_streamlines() -> void:
	# Thin foam streaks drifting with the current — two per water cell, with
	# hashed lateral offsets, lengths, and phases so the river reads as a
	# living flow rather than a marching grid of arrows.
	if world == null:
		return
	for cell_v in world.water_flow.keys():
		var cell: Vector3i = cell_v
		var flow: Vector3i = world.water_flow[cell]
		var dir: Vector2 = Vector2(
			(float(flow.x) - float(flow.z)) * TILE_W * 0.5,
			(float(flow.x) + float(flow.z)) * TILE_H * 0.5).normalized()
		if dir == Vector2.ZERO:
			continue
		var perp := Vector2(-dir.y, dir.x)
		var surf: Vector2 = iso_pt(float(cell.x) + 0.5, float(cell.y) + WATER_LEVEL + 0.02,
				float(cell.z) + 0.5)
		var h: int = _wang_hash(cell.x * 92821 + cell.z * 31337)
		for i in 2:
			var hh: int = _wang_hash(h + i * 7919)
			var lat: float = (float(hh % 1000) / 1000.0 - 0.5) * TILE_H * 0.55
			var ln: float = 9.0 + float((hh >> 10) % 8)
			var speed: float = 0.42 + float((hh >> 14) % 100) / 500.0
			var phase: float = fmod(_anim_t * speed + float((hh >> 6) % 628) / 100.0, 1.0)
			var along: float = (phase - 0.5) * TILE_W * 0.52
			var p0: Vector2 = surf + perp * lat + dir * (along - ln * 0.5)
			var p2: Vector2 = surf + perp * lat + dir * (along + ln * 0.5)
			var p1: Vector2 = (p0 + p2) * 0.5 + perp * sin(phase * TAU + float(i) * 2.1) * 1.6
			var a: float = sin(phase * PI) * 0.75
			var col := Color(0.88, 0.96, 1.00, a)
			draw_polyline(PackedVector2Array([p0, p1, p2]), col, 2.0)


func _draw_fx() -> void:
	for g in _dying:
		var t: float = clampf((_anim_t - float(g["t0"])) / DEATH_DUR, 0.0, 1.0)
		var a: float = 1.0 - t
		var tex: Texture2D = g["tex"]
		var feet: Vector2 = g["feet"]
		if tex != null:
			var uw: float = TILE_W * UNIT_SPRITE_SCALE
			var uh: float = uw * float(tex.get_height()) / float(tex.get_width())
			var mod := Color(1.0, 0.7, 0.7, a) if int(g["team"]) == 1 else Color(1, 1, 1, a)
			draw_set_transform(feet, t * 1.35, Vector2.ONE)
			draw_texture_rect(tex, Rect2(-uw * 0.5, -uh * UNIT_GROUND_FRAC, uw, uh), false, mod)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		else:
			draw_circle(feet, 2.0 + 8.0 * a, Color(0.25, 0.25, 0.28, a))
	for f in _fx:
		var ft: float = clampf((_anim_t - float(f["t0"])) / float(f["life"]), 0.0, 1.0)
		var c: Color = f["col"]
		c.a *= (1.0 - ft)
		draw_circle(f["pos"], float(f["r"]) * (1.0 - ft * 0.5), c)
	var font := ThemeDB.fallback_font
	if font != null:
		for d in _dmg_numbers:
			var t2: float = clampf((_anim_t - float(d["t0"])) / DMG_DUR, 0.0, 1.0)
			var pos: Vector2 = d["pos"] + Vector2(0, -26.0 * t2)
			var col: Color = d["col"]
			col.a = 1.0 - t2 * t2
			draw_string(font, pos + Vector2(1, 1), String(d["text"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0, 0, 0, col.a * 0.8))
			draw_string(font, pos, String(d["text"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col)

func _level_alpha(y: int) -> float:
	# Alpha for solid-rendered cubes. Above-focal cubes only reach here when
	# the focal level is at/above ground (underground views wireframe them in
	# _draw_cube) — render those at the near-above fade so tall trees and
	# boulders stay fully visible on the surface view.
	if y == view_level:
		return 1.0
	if y > view_level:
		return FADE_NEAR_ABOVE
	return FADE_BELOW

func _on_cells_changed() -> void:
	_terrain_keys_dirty = true
	if terrain_layer != null:
		terrain_layer.queue_redraw()

# Cache layer's draw — only fires when we explicitly mark it dirty (vision /
# terrain / view-level / quake). Uses a cached back-to-front key sort that's
# only rebuilt when cells actually changed; `_draw_canvas` routes the
# primitives to the layer.
func _draw_terrain_layer(canvas: CanvasItem) -> void:
	if world == null or gs == null:
		return
	_draw_canvas = canvas
	if _terrain_keys_dirty:
		_terrain_keys = world.cells.keys()
		_terrain_keys.sort_custom(func(a, b):
			if a.x + a.z != b.x + b.z:
				return a.x + a.z < b.x + b.z
			return a.y < b.y)
		_terrain_keys_dirty = false
	for c in _terrain_keys:
		_draw_cube(c, _level_alpha(c.y))
	_draw_canvas = self

func _draw_cube(c: Vector3i, alpha: float) -> void:
	var seen_it: bool = gs.seen.has(c)
	var mat: int = world.material_at(c)
	# Cubes >1 level above the focal layer wireframe — but ONLY when the focal
	# level is underground. At/above ground level nothing overhead is hiding
	# anything, so surface protrusions (tall trees, boulders) render solid in
	# full instead of getting their tops trimmed to wireframe.
	if c.y > view_level + 1 and view_level < VoxelWorld.GROUND:
		var base_col: Color = (FOG_COLOR if not seen_it
				else _mat_colors.get(mat, Color(0.5, 0.5, 0.5)))
		var wire_col := Color(base_col.r, base_col.g, base_col.b, WIRE_ALPHA)
		var w010 := iso(c + Vector3i(0, 1, 0))
		var w110 := iso(c + Vector3i(1, 1, 0))
		var w111 := iso(c + Vector3i(1, 1, 1))
		var w011 := iso(c + Vector3i(0, 1, 1))
		var w100 := iso(c + Vector3i(1, 0, 0))
		var w101 := iso(c + Vector3i(1, 0, 1))
		var w001 := iso(c + Vector3i(0, 0, 1))
		_draw_canvas.draw_polyline(PackedVector2Array([w010, w110, w111, w011, w010]), wire_col, WIRE_WIDTH)
		_draw_canvas.draw_polyline(PackedVector2Array([w100, w110, w111, w101, w100]), wire_col, WIRE_WIDTH)
		_draw_canvas.draw_polyline(PackedVector2Array([w001, w011, w111, w101, w001]), wire_col, WIRE_WIDTH)
		return

	# Trees and player-built structures are surface features — always visible
	# (no fog grey) and never faded.
	if mat == VoxelWorld.Mat.TREE or mat == VoxelWorld.Mat.LADDER \
			or mat == VoxelWorld.Mat.BRIDGE or mat == VoxelWorld.Mat.BALLISTA \
			or mat == VoxelWorld.Mat.BUILDING:
		seen_it = true
		alpha = 1.0
	# Solid path. The vast majority of cells are uniform-colour materials with a
	# fully-filled pattern (plain earth, gold ore, etc). Those take a fast path
	# that draws the cell as a single big cube — 3 polygons instead of ~30.
	# Trees (variegated colour) and stones / divots (non-full pattern) fall
	# through to the sub-cube path for their richer geometry.
	var shake := Vector2(0, _quake_offset(c))
	var pattern: int = _cell_pattern(c, mat)
	var shadowed: bool = _is_shadowed(c)
	# Tree: ONE tall sprite per column, drawn from the BOTTOM cell only —
	# upper tree cells are part of the same image and skipped here.
	if mat == VoxelWorld.Mat.TREE and seen_it and not _tree_variants.is_empty():
		if world.material_at(c + Vector3i(0, -1, 0)) == VoxelWorld.Mat.TREE:
			return                  # not the base — already drawn by it
		_draw_tree(c, alpha, shake, shadowed)
		return
	# Water: continuous recessed plane with bank waterlines + foam.
	if mat == VoxelWorld.Mat.WATER and seen_it:
		_draw_flat_water(c, alpha, shake, shadowed)
		return
	# Boulder sprite override: rounded shape, not a cube.
	if mat == VoxelWorld.Mat.STONE and seen_it and _terrain_sprites.has(mat):
		_draw_terrain_sprite(c, mat, alpha, shake, shadowed)
		return
	# Ballistas render as a live-layer RIG (smooth fire animation); the cached
	# terrain pass draws nothing for them once seen.
	if mat == VoxelWorld.Mat.BALLISTA and seen_it and not _ballista_rig_tex.is_empty():
		return
	# Ladder + bridge have non-full sub-cube patterns; sprite them directly.
	if mat in [VoxelWorld.Mat.LADDER, VoxelWorld.Mat.BRIDGE] and seen_it \
			and _terrain_sprites.has(mat):
		_draw_terrain_sprite(c, mat, alpha, shake, shadowed)
		return
	if pattern == FULL_PATTERN and mat != VoxelWorld.Mat.TREE:
		# Sprite override: if we have terrain art for this material AND the
		# cell is fully visible (not fogged), draw the texture instead of the
		# 3-polygon cube. Fogged cells fall back to the polygon path so the
		# fog grey remains legible.
		if mat == VoxelWorld.Mat.BUILDING and seen_it:
			var bkind: String = String(gs.buildings.get(c, {}).get("kind", ""))
			if _building_sprites.has(bkind):
				_draw_building_sprite(c, _building_sprites[bkind], alpha, shake, shadowed)
				return
		# Earth: continuous flat planes with contour outlines (no per-cell art).
		if mat == VoxelWorld.Mat.EARTH and seen_it:
			_draw_flat_earth(c, alpha, shake, shadowed)
			if _grass_caps(c):
				_draw_grass_tint(c, alpha, shake, shadowed)
				_draw_sprouts(c, alpha, shake, shadowed)
			return
		if seen_it and _terrain_sprites.has(mat):
			_draw_terrain_sprite(c, mat, alpha, shake, shadowed)
			return
		_draw_big_cube(c, mat, seen_it, alpha, shake, shadowed)
		if mat == VoxelWorld.Mat.BUILDING:
			_draw_building_label(c, shake)
		return
	for sub: Vector3i in _sub_draw_order:
		if not _sub_filled(pattern, sub.x, sub.y, sub.z):
			continue
		_draw_sub_cube(c, sub.x, sub.y, sub.z, alpha, pattern, mat, seen_it, shake, shadowed)

# Two-letter tag on a building cube's top face so kinds are tellable apart.
func _draw_building_label(c: Vector3i, shake: Vector2) -> void:
	var b: Dictionary = gs.buildings.get(c, {})
	if b.is_empty():
		return
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var kind: String = String(b["kind"])
	var top: Vector2 = iso_pt(float(c.x) + 0.5, float(c.y + 1), float(c.z) + 0.5) + shake
	_draw_canvas.draw_string(font, top + Vector2(-8, 4), kind.substr(0, 2).to_upper(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.15, 0.10, 0.05))

# Fast path for uniform full cells — one cube, three polygons. Visually
# identical to the sub-cube path when the pattern is fully filled and the
# material has a single colour, since face culling within the sub-cube path
# would have produced the same outer surface anyway.
func _draw_big_cube(c: Vector3i, mat: int, seen: bool, alpha: float, shake: Vector2, shadowed: bool = false) -> void:
	var p010 := iso(c + Vector3i(0, 1, 0)) + shake
	var p110 := iso(c + Vector3i(1, 1, 0)) + shake
	var p111 := iso(c + Vector3i(1, 1, 1)) + shake
	var p011 := iso(c + Vector3i(0, 1, 1)) + shake
	var p100 := iso(c + Vector3i(1, 0, 0)) + shake
	var p101 := iso(c + Vector3i(1, 0, 1)) + shake
	var p001 := iso(c + Vector3i(0, 0, 1)) + shake
	var base_col: Color = (FOG_COLOR if not seen
			else _mat_colors.get(mat, Color(0.5, 0.5, 0.5)))
	if shadowed:
		base_col = base_col.darkened(SHADOW_DARKEN)
	var top_col := base_col
	top_col.a = alpha
	var right_col := top_col.darkened(0.22)
	right_col.a = alpha
	var left_col := top_col.darkened(0.42)
	left_col.a = alpha
	_draw_canvas.draw_colored_polygon(PackedVector2Array([p010, p110, p111, p011]), top_col)
	_draw_canvas.draw_colored_polygon(PackedVector2Array([p100, p110, p111, p101]), right_col)
	_draw_canvas.draw_colored_polygon(PackedVector2Array([p001, p011, p111, p101]), left_col)
	# Surface texture: a few deterministic speckles break up the flat top face.
	# Lives on the cached terrain layer, so it costs nothing per-frame.
	if mat != VoxelWorld.Mat.WATER:
		_draw_top_speckles(c, p010, p110, p011, top_col)

# 2-4 small darker/lighter mini-diamonds at hash-stable positions on the top
# face. Pure 2D surface mask — adds visual grain without geometry cost.
func _draw_top_speckles(c: Vector3i, origin_pt: Vector2, px: Vector2, pz: Vector2, top_col: Color) -> void:
	var ex: Vector2 = px - origin_pt
	var ez: Vector2 = pz - origin_pt
	var h: int = absi((c.x * 92837111) ^ (c.z * 689287499) ^ ((c.y + 7) * 283923481))
	var count: int = 2 + (h % 3)
	var dark: Color = top_col.darkened(0.16)
	dark.a = top_col.a
	var light: Color = top_col.lightened(0.10)
	light.a = top_col.a
	for i in count:
		var hx: int = absi(h ^ ((i + 1) * 374761393))
		var fx: float = clampf(float(hx % 83) / 83.0, 0.12, 0.88)
		var fz: float = clampf(float((hx / 83) % 79) / 79.0, 0.12, 0.88)
		var center: Vector2 = origin_pt + ex * fx + ez * fz
		var s: float = 0.07 + float(hx % 5) * 0.014
		var col: Color = dark if (hx & 1) == 0 else light
		_draw_canvas.draw_colored_polygon(PackedVector2Array([
			center + ex * s, center + ez * s, center - ex * s, center - ez * s,
		]), col)

# Pre-sorted 18-cell draw order: back-to-front by (sx + sz), then by sy
# ascending so stacked sub-cubes paint correctly within a cell.
func _compute_sub_draw_order() -> Array:
	var arr: Array = []
	for sy in SUB_Y:
		for sz in SUB_Z:
			for sx in SUB_X:
				arr.append(Vector3i(sx, sy, sz))
	arr.sort_custom(func(a, b):
		if (a.x + a.z) != (b.x + b.z):
			return (a.x + a.z) < (b.x + b.z)
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	return arr

# Iso projection of a sub-cube corner. Sub-cube (sx, sy, sz) in cell c spans
# fractional coords [sx/3, (sx+1)/3] × [sy/2, (sy+1)/2] × [sz/3, (sz+1)/3].
# dx/dy/dz are 0 or 1 (which of the 8 corners).
func _sub_iso(c: Vector3i, sx: int, sy: int, sz: int, dx: int, dy: int, dz: int) -> Vector2:
	return iso_pt(
		float(c.x) + float(sx + dx) / float(SUB_X),
		float(c.y) + float(sy + dy) / float(SUB_Y),
		float(c.z) + float(sz + dz) / float(SUB_Z))

func _sub_filled(pattern: int, sx: int, sy: int, sz: int) -> bool:
	if sx < 0 or sx >= SUB_X or sy < 0 or sy >= SUB_Y or sz < 0 or sz >= SUB_Z:
		return false
	return ((pattern >> (sx + sz * SUB_X + sy * SUB_X * SUB_Z)) & 1) == 1

# Deterministic 36-bit fill-mask per cell. TREE = solid box (colour decides
# stump vs leaves layer). STONE = irregular cluster. Other dirt-like
# materials = mostly full with the occasional random sub-cube divot.
func _cell_pattern(c: Vector3i, mat: int) -> int:
	if mat == VoxelWorld.Mat.TREE:
		# Trees stack vertically (TREE_HEIGHT cells per tree). Middle/bottom
		# cells are pure trunk (slim brown column, all sub-layers). The TOP
		# cell — the only one with no tree cell above it — adds a full 3×3
		# canopy on its top sub-layer.
		var has_tree_above: bool = world.material_at(c + Vector3i(0, 1, 0)) == VoxelWorld.Mat.TREE
		var p: int = 0
		var trunk_layers: int = SUB_Y if has_tree_above else (SUB_Y - 1)
		for sy in range(trunk_layers):
			p |= 1 << (1 + 1 * SUB_X + sy * SUB_X * SUB_Z)
		if not has_tree_above:
			p |= 0x1FF << ((SUB_Y - 1) * SUB_X * SUB_Z)
		return p
	if mat == VoxelWorld.Mat.LADDER:
		# Two side rails (full height) + rungs on alternating sub-layers,
		# all in the cell's middle z-slice — reads as a ladder lattice.
		var p: int = 0
		for sy in range(SUB_Y):
			p |= 1 << (0 + 1 * SUB_X + sy * SUB_X * SUB_Z)   # left rail
			p |= 1 << (2 + 1 * SUB_X + sy * SUB_X * SUB_Z)   # right rail
			if sy % 2 == 1:
				p |= 1 << (1 + 1 * SUB_X + sy * SUB_X * SUB_Z)  # rung
		return p
	if mat == VoxelWorld.Mat.BRIDGE:
		# A flat plank deck: only the top sub-layer filled.
		return 0x1FF << ((SUB_Y - 1) * SUB_X * SUB_Z)
	if mat == VoxelWorld.Mat.STONE:
		var p: int = FULL_PATTERN
		var seed: int = (c.x * 73 + c.z * 31 + c.y * 11) & 0xFFFF
		# Drop ~10 sub-cubes for craggy, irregular boulders.
		for i in range(10):
			var bit: int = ((seed >> i) ^ (c.y * 7 + i * 19)) & 0xFF
			bit = bit % (SUB_X * SUB_Y * SUB_Z)
			p &= ~(1 << bit)
		return p
	# Dirt-like materials: ~12% of cells lose one random sub-cube so the
	# surface isn't perfectly flat.
	var s: int = (c.x * 73 + c.z * 31 + c.y * 7) % 100
	if s < 12:
		var which: int = (c.x * 17 + c.z * 5 + c.y * 3) % (SUB_X * SUB_Y * SUB_Z)
		return FULL_PATTERN & ~(1 << which)
	return FULL_PATTERN

# Per-sub-cube colour. Trees' bottom-and-middle cells paint pure brown trunk;
# the TOP cell of the stack paints its top sub-layer green (canopy).
func _sub_base_color(c: Vector3i, mat: int, sx: int, sy: int, sz: int, seen: bool) -> Color:
	if not seen:
		return FOG_COLOR
	if mat == VoxelWorld.Mat.TREE:
		var has_tree_above: bool = world.material_at(c + Vector3i(0, 1, 0)) == VoxelWorld.Mat.TREE
		if not has_tree_above and sy >= SUB_Y - 1:
			return CANOPY_COLOR
		return TRUNK_COLOR
	return _mat_colors.get(mat, Color(0.5, 0.5, 0.5))

func _draw_sub_cube(c: Vector3i, sx: int, sy: int, sz: int, alpha: float,
		pattern: int, mat: int, seen: bool, shake: Vector2, shadowed: bool = false) -> void:
	var p010 := _sub_iso(c, sx, sy, sz, 0, 1, 0) + shake
	var p110 := _sub_iso(c, sx, sy, sz, 1, 1, 0) + shake
	var p111 := _sub_iso(c, sx, sy, sz, 1, 1, 1) + shake
	var p011 := _sub_iso(c, sx, sy, sz, 0, 1, 1) + shake
	var p100 := _sub_iso(c, sx, sy, sz, 1, 0, 0) + shake
	var p101 := _sub_iso(c, sx, sy, sz, 1, 0, 1) + shake
	var p001 := _sub_iso(c, sx, sy, sz, 0, 0, 1) + shake
	var base_col: Color = _sub_base_color(c, mat, sx, sy, sz, seen)
	if shadowed:
		base_col = base_col.darkened(SHADOW_DARKEN)
	var top_col := base_col
	top_col.a = alpha
	var right_col := top_col.darkened(0.22)
	right_col.a = alpha
	var left_col := top_col.darkened(0.42)
	left_col.a = alpha
	# Top face: visible if there's no filled sub above.
	if sy == SUB_Y - 1 or not _sub_filled(pattern, sx, sy + 1, sz):
		_draw_canvas.draw_colored_polygon(PackedVector2Array([p010, p110, p111, p011]), top_col)
	# +X face: visible if no sub to the right within the cell.
	if sx == SUB_X - 1 or not _sub_filled(pattern, sx + 1, sy, sz):
		_draw_canvas.draw_colored_polygon(PackedVector2Array([p100, p110, p111, p101]), right_col)
	# +Z face: visible if no sub to the front within the cell.
	if sz == SUB_Z - 1 or not _sub_filled(pattern, sx, sy, sz + 1):
		_draw_canvas.draw_colored_polygon(PackedVector2Array([p001, p011, p111, p101]), left_col)

func _draw_highlight(c: Vector3i) -> void:
	# Wireframe diamond on the visible surface for cell `c`. For air cells we
	# outline the floor (top of the cube below); for solid cells, the top face.
	var anchor: Vector3i = c if (world.is_solid(c) or world.is_water(c)) else c + Vector3i(0, -1, 0)
	var poly := top_face(anchor)
	var closed := PackedVector2Array([poly[0], poly[1], poly[2], poly[3], poly[0]])
	var color: Color = MODE_COLORS.get(mode, Color.WHITE)
	draw_polyline(closed, color, 3.0)

func _draw_unit(u, alpha: float) -> void:
	# Use the animated render position so moves lerp smoothly. Falls back to
	# the logical cell if draw_pos is uninitialised (e.g. legacy spawns).
	var dp: Vector3 = u.draw_pos if u.draw_pos != Vector3.ZERO else Vector3(u.grid.x + 0.5, float(u.grid.y), u.grid.z + 0.5)
	if u.kind == "boat":
		dp.y += WATER_LEVEL          # hull rides the water surface
	var feet: Vector2 = iso_pt(dp.x, dp.y, dp.z)
	# Procedural puppet motion: hop arc while moving, gentle idle bob (phase
	# offset per unit so the army doesn't breathe in sync), lunge on attack.
	if _move_anim.has(u):
		var mt: float = clampf((_anim_t - float(_move_anim[u])) / 0.26, 0.0, 1.0)
		feet.y -= sin(mt * PI) * 6.0
	else:
		feet.y += sin(_anim_t * 4.6 + float(u.get_instance_id() % 628) / 100.0) * 1.4
	if _lunges.has(u):
		var lt: float = clampf((_anim_t - float(_lunges[u]["t0"])) / LUNGE_DUR, 0.0, 1.0)
		feet += _lunges[u]["dir"] * (sin(lt * PI) * 12.0)
	var col: Color
	if u.kind == "leader":
		col = LEADER_COLOR
	else:
		col = TEAM_COLORS[u.team]
		# Special unit kinds read via tint: warrior darker, ranger lighter,
		# plow machine-brown (plus the letter badge drawn with the HP text).
		match u.kind:
			"warrior": col = col.darkened(0.30)
			"javelin": col = col.lightened(0.30)
			"plow": col = col.lerp(Color(0.55, 0.45, 0.28), 0.6)
			"wolf": col = col.lerp(Color(0.55, 0.55, 0.58), 0.65)
			"wizard": col = col.lerp(Color(0.62, 0.25, 0.85), 0.7)
			"king": col = col.lerp(Color(0.95, 0.75, 0.10), 0.7)
			"otter": col = col.lerp(Color(0.25, 0.60, 0.55), 0.7)
			"flud": col = col.lerp(Color(0.20, 0.35, 0.80), 0.75)
			"boat": col = col.lerp(Color(0.40, 0.30, 0.20), 0.5)
	if u == gs.selected:
		col = col.lightened(0.25)
	col.a = alpha

	# Selection ring on the floor (wireframe diamond) FIRST so the body covers part of it.
	if u == gs.selected:
		var ring := _diamond(feet, TILE_W * 0.42, TILE_H * 0.42)
		ring.append(ring[0])
		draw_polyline(ring, Color(0.96, 0.78, 0.30), 2.8)

	# Soft shadow.
	draw_colored_polygon(_diamond(feet, TILE_W * 0.30, TILE_H * 0.30), Color(0, 0, 0, 0.25))

	# Body: tall ellipse for leader, short for operator.
	var body_h: float = HEIGHT_STEP * (1.6 if u.kind == "leader" else 1.15)
	var body_w: float = 18.0 if u.kind == "leader" else 15.0
	var body_top := feet - Vector2(0, body_h)
	# Sprite body when art exists for this kind (assets/cards/unit_<kind>.png,
	# auto-loaded — drop a file in, it's used; no code change). Enemies get a
	# red wash so teams stay readable; capsules remain the fallback.
	var utex: Texture2D = _unit_sprites.get(u.kind)
	var umod := Color(1, 1, 1, alpha)
	if u.team == 1:
		umod = Color(1.0, 0.62, 0.62, alpha)
	if u == gs.selected:
		umod = umod.lightened(0.25)
	if _hit_flash.has(u):
		var ft: float = 1.0 - clampf((_anim_t - float(_hit_flash[u])) / FLASH_DUR, 0.0, 1.0)
		umod = umod.lightened(0.8 * ft)
		draw_circle(feet - Vector2(0, 14), 6.0 + 14.0 * (1.0 - ft), Color(1, 1, 1, 0.5 * ft))
	if u.kind == "operator" and OperatorRig.ready():
		# Rigged operator: 4 body parts, front arm follows the spade action.
		# Operators are little minions — half the height of other units.
		var uh2: float = TILE_W * UNIT_SPRITE_SCALE / OperatorRig.FRAME_ASPECT * 0.5
		var pose: Dictionary = {}
		var act = _action_anims.get(u)
		if act != null:
			var ty: String = String(act["type"])
			var tt: float = clampf((_anim_t - float(act["t0"])) / float(SpadeActions.DUR.get(ty, 0.6)), 0.0, 1.0)
			pose = OperatorRig.action_pose(ty, tt, act["dir"], 0.0)
		OperatorRig.draw(self, feet, uh2, pose, umod)
		body_top = feet - Vector2(0, uh2 * 0.8)
	elif utex != null:
		var uw: float = TILE_W * UNIT_SPRITE_SCALE
		var uh: float = uw * float(utex.get_height()) / float(utex.get_width())
		var urect := Rect2(feet.x - uw * 0.5, feet.y - uh * UNIT_GROUND_FRAC, uw, uh)
		draw_texture_rect(utex, urect, false, umod)
		body_top = feet - Vector2(0, uh * 0.8)   # badges anchor above the sprite
	else:
		_draw_capsule(feet, body_top, body_w, col)
	_draw_spade_prop(u, feet, alpha)

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
		# Kind initial for special units (W / R / P) on the body.
		if u.kind in ["warrior", "javelin", "plow", "wolf", "wizard", "king", "boat", "otter", "flud"]:
			draw_string(font, feet + Vector2(-4, -body_h * 0.45),
				u.kind.substr(0, 1).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.95))
		var badge_pos: Vector2 = feet + Vector2(-14, -body_h - 24)
		var is_focal: bool = (u.grid.y - 1) == view_level
		var badge_col: Color = Color(0.30, 1.00, 0.50) if is_focal else Color(0.85, 0.85, 0.95)
		# Outlined badge background for legibility on any terrain.
		draw_rect(Rect2(badge_pos - Vector2(2, 2), Vector2(28, 14)), Color(0, 0, 0, 0.6))
		draw_string(font, badge_pos + Vector2(0, 10), "L%d" % u.grid.y, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, badge_col)

# Held-spade prop: a separate sprite posed over the unit (two-asset pattern).
# Visible whenever a spade-wielder holds one; animated through dig / swing /
# throw / fish; vanishes at the throw release as the projectile takes over.
func _spade_prop_pose(u, feet: Vector2) -> Variant:
	var act = _action_anims.get(u)
	var ps: float = _prop_scale(u)
	if act == null:
		if u.spade == null or u.kind in ["leader", "javelin", "plow", "boat", "wolf", "wizard", "king", "otter"]:
			return null
		return {"pos": feet + Vector2(10.0, -12.0) * ps, "rot": -0.30, "flip": false}
	var type: String = String(act["type"])
	var t: float = clampf((_anim_t - float(act["t0"])) / float(SpadeActions.DUR.get(type, 0.6)), 0.0, 1.0)
	var pose: Variant = SpadeActions.prop_pose(type, t, act["dir"])
	if pose == null:
		return null
	return {"pos": feet + Vector2(pose["off"]) * ps, "rot": pose["rot"], "flip": pose["flip"]}

# Prop + offset scale per unit kind (operators are half-size minions).
func _prop_scale(u) -> float:
	return 0.55 if u.kind == "operator" else 1.0

func _draw_spade_prop(u, feet: Vector2, alpha: float) -> void:
	var pose: Variant = _spade_prop_pose(u, feet)
	if pose == null:
		return
	var tex: Texture2D = _texture_for("spade")
	if tex == null:
		return
	var w: float = 17.0 * _prop_scale(u)
	var h: float = w * float(tex.get_height()) / float(tex.get_width())
	var sc := Vector2(-1.0, 1.0) if pose["flip"] else Vector2.ONE
	draw_set_transform(pose["pos"], float(pose["rot"]), sc)
	draw_texture_rect(tex, Rect2(-w * 0.5, -h * 0.58, w, h), false, Color(1, 1, 1, alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

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
	# Ballista volleys hold their projectile until the release frame.
	var t0: float = 0.0
	if _ballista_shot_pending:
		_ballista_shot_pending = false
		t0 = -BALLISTA_LAUNCH_DELAY / THROW_DUR
	elif _unit_throw_pending:
		_unit_throw_pending = false
		t0 = -SpadeActions.THROW_WINDUP / THROW_DUR
	projectiles.append({
		"from": from_pos,
		"to": to_pos,
		"t": t0,
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
	# Right stick pans too (controller play).
	var jp := Vector2(
		Input.get_joy_axis(0, JOY_AXIS_RIGHT_X),
		Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if jp.length() > 0.2:
		pan -= jp
	if pan != Vector2.ZERO:
		position += pan * PAN_SPEED * delta
		queue_redraw()
	# Earthquake bounce: advance time until the quake settles, then clear.
	# During the bounce every cube is offset per-frame, so the terrain cache
	# has to redraw alongside the dynamic layer.
	if _quake_t < QUAKE_DUR:
		_quake_t += delta
		queue_redraw()
		if terrain_layer != null:
			terrain_layer.queue_redraw()
		if _quake_t >= QUAKE_DUR:
			_quake_columns.clear()
	# Move animations: tween updates u.draw_pos under the hood, but the renderer
	# only redraws when we ask it to. Keep queueing while any move is in flight.
	if _moves_in_flight > 0:
		queue_redraw()
	for p in projectiles:
		p["t"] += delta / p["dur"]
	# One-way ends at t=1; boomerangs run there-and-back, ending at t=2.
	projectiles = projectiles.filter(func(p):
		return p["t"] < (2.0 if p["boomerang"] else 1.0))
	projectiles_visible = projectiles.filter(func(p): return p["t"] >= 0.0)

	# --- ambient animation clock + particle simulation ---
	_anim_t += delta
	# Chimney smoke from villages / campsites.
	for cell_v in gs.buildings.keys():
		var b: Dictionary = gs.buildings[cell_v]
		var kind: String = String(b["kind"])
		if kind != "village" and kind != "campsite":
			continue
		if _anim_t >= float(_smoke_timers.get(cell_v, 0.0)):
			_smoke_timers[cell_v] = _anim_t + 0.9 + randf() * 0.7
			var c: Vector3i = cell_v
			var top: Vector2 = iso_pt(float(c.x) + 0.5, float(c.y) + 1.6, float(c.z) + 0.5)
			_fx.append({"pos": top, "vel": Vector2(randf() * 8.0 - 4.0, -18.0 - randf() * 8.0),
				"t0": _anim_t, "life": 1.6,
				"col": Color(0.93, 0.93, 0.96, 0.50), "r": 3.0 + randf() * 2.5})
	# Particle physics: drift + drag + gravity for bursts (smoke rises free).
	for f in _fx:
		f["pos"] += f["vel"] * delta
		if float(f["col"].a) > 0.55:
			f["vel"] = f["vel"] + Vector2(0, 160.0 * delta)   # gravity on debris
	_fx = _fx.filter(func(f): return _anim_t - float(f["t0"]) < float(f["life"]))
	# Expire transient unit effects.
	for u in _hit_flash.keys():
		if _anim_t - float(_hit_flash[u]) > FLASH_DUR:
			_hit_flash.erase(u)
	for u in _lunges.keys():
		if _anim_t - float(_lunges[u]["t0"]) > LUNGE_DUR:
			_lunges.erase(u)
	_dying = _dying.filter(func(g): return _anim_t - float(g["t0"]) < DEATH_DUR)
	for u in _action_anims.keys():
		var act: Dictionary = _action_anims[u]
		if _anim_t - float(act["t0"]) > float(SpadeActions.DUR.get(act["type"], 0.6)):
			_action_anims.erase(u)
	_dmg_numbers = _dmg_numbers.filter(func(d): return _anim_t - float(d["t0"]) < DMG_DUR)
	# Ambient animation = continuous redraw. Terrain stays cached, so the
	# per-frame cost is only units + fx + HUD overlays.
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
	_move_anim[u] = _anim_t
	var tween := create_tween()
	tween.tween_property(u, "draw_pos", to_pos, 0.26) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.finished.connect(func():
		_moves_in_flight -= 1
		_move_anim.erase(u))

func _draw_projectiles() -> void:
	for p in projectiles_visible:
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
		var tex: Texture2D = _texture_for("spade")
		if tex != null:
			# WW spade art spinning along the arc, with a soft ground shadow.
			draw_circle(Vector2(pos.x, pos.y + sin(PI * leg_t) * THROW_ARC + 6.0),
				7.0, Color(0, 0, 0, 0.18))
			var w := 34.0
			var h: float = w * float(tex.get_height()) / float(tex.get_width())
			draw_set_transform(pos, angle, Vector2.ONE)
			draw_texture_rect(tex, Rect2(-w * 0.5, -h * 0.5, w, h), false)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		else:
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
	if event is InputEventJoypadButton and event.pressed:
		match event.button_index:
			JOY_BUTTON_Y:
				_on_end_turn()
			JOY_BUTTON_X:
				if _modal == null:
					_open_build_modal()
				else:
					_close_modal()
			JOY_BUTTON_LEFT_SHOULDER:
				_zoom_at(Vector2(800, 450), 1.0 / ZOOM_STEP)
			JOY_BUTTON_RIGHT_SHOULDER:
				_zoom_at(Vector2(800, 450), ZOOM_STEP)
			JOY_BUTTON_START:
				get_tree().change_scene_to_file("res://scenes/title.tscn")
		return
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
				_on_right_click(get_local_mouse_position())
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
	if terrain_layer != null:
		terrain_layer.queue_redraw()

func _refresh_level_label() -> void:
	if level_label != null:
		level_label.text = "View: level %d" % view_level

# Right-click = attack when it lands on an enemy: swing if adjacent (Chebyshev
# 1, diagonals included), throw the spade if within throw range. Anywhere else,
# right-click keeps its cancel behaviour.
func _on_right_click(p: Vector2) -> void:
	if _ai_running or gs.is_over:
		return
	var sel = gs.selected
	if sel != null and sel.team == 0:
		var target = _pick_unit(p)
		if target != null and target.team != 0 and target.is_alive():
			var d: int = gs._cheb3(sel.grid, target.grid)
			# Spadeless melee: wolves bite for 2, bare hands punch for 1.
			if sel.spade == null:
				if d <= 1:
					gs.bite(sel, target, 2 if sel.kind == "wolf" else 1)
				else:
					gs.notice.emit("No spade — get adjacent to punch (1 dmg).")
				return
			var reach: int = gs.throw_range_for(sel)
			if d <= 1:
				gs.swing_at(sel, target.grid)
			elif d <= reach:
				gs.throw_at(sel, target.grid)
			else:
				gs.notice.emit("Out of range — throw reaches %d." % reach)
			return
	_cancel_action()

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
		return
	# Smart-click harvesting: with a unit selected in plain move mode, clicking
	# an adjacent tree chops it and an adjacent dirt cell digs it — no mode
	# button needed. The Dig button still exists for precise two-step digs.
	if mode == "move" and gs.selected != null and gs.selected.team == 0:
		var cands: Dictionary = gs.harvest_candidates(gs.selected)
		var cell = _pick_cell_in(p, cands.keys()) if not cands.is_empty() else null
		if cell != null:
			if cands[cell] == "chop":
				gs.swing_at(gs.selected, cell)
			else:
				gs.dig_at(gs.selected, cell)
			return
		# Distant tree → propose an auto-harvest task with a turn estimate.
		if gs.selected.spade != null and gs.selected.kind == "operator":
			var trees: Array = []
			for cell_v in world.cells.keys():
				if world.cells[cell_v] == VoxelWorld.Mat.TREE:
					trees.append(cell_v)
			var tcell = _pick_cell_in(p, trees)
			if tcell != null:
				_open_harvest_confirm(gs.selected, tcell)

func _pick_target(p: Vector2):
	return _pick_cell_in(p, targets)

# Hit-test a screen point against the visible top face of each candidate cell,
# front-to-back so the closest wins overlaps.
func _pick_cell_in(p: Vector2, cells: Array):
	var ts := cells.duplicate()
	ts.sort_custom(func(a, b):
		var sa: int = a.x + a.z
		var sb: int = b.x + b.z
		if sa != sb:
			return sa > sb
		return a.y > b.y)
	for c in ts:
		var anchor: Vector3i = c if (world.is_solid(c) or world.is_water(c)) else c + Vector3i(0, -1, 0)
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
	# Structure placement (ladder / bridge) takes top priority.
	if mode == "place_structure":
		var card = pending_card
		pending_card = null
		mode = "move"
		if gs.play_structure_at(card, cell):
			Sfx.play("build", 0.08)
		return
	if mode == "ritual":
		var card = pending_card
		pending_card = null
		mode = "move"
		gs.play_ritual_at(card, cell)
		return
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
	# Single-step dig: lower the tile one layer, bank +1 earth.
	if mode == "dig":
		gs.dig_at(u, cell)
		mode = "move"
		return
	match mode:
		"move": gs.move_to(u, cell)
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
	if mode == "place_structure":
		return gs.structure_targets(pending_card)
	if mode == "ritual":
		return gs.ritual_targets(pending_card)
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
	_refresh_cloud_puffs()
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
	# Terrain cache only needs a redraw when something terrain-visible changed:
	# fog lifted (seen grew) or the focal level moved. Plain selection / card
	# clicks reuse the cached render.
	if terrain_layer != null:
		if gs.seen.size() != _last_seen_size or view_level != _last_tl_view_level:
			_last_seen_size = gs.seen.size()
			_last_tl_view_level = view_level
			terrain_layer.queue_redraw()

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
	info_label.size = Vector2(540, 24)
	info_label.clip_text = true
	status_label = _label(Vector2(12, 36))
	hint_label = _label(Vector2(12, 62))
	hint_label.text = HINT_CONTROLS
	end_turn_btn = Button.new()
	end_turn_btn.text = "End Turn"
	end_turn_btn.position = Vector2(12, 88)
	end_turn_btn.size = Vector2(128, 42)
	end_turn_btn.add_theme_font_size_override("font_size", 18)
	# Accent: the one button you press every turn gets WW action-green.
	for state in [["normal", Color(0.27, 0.52, 0.23)], ["hover", Color(0.34, 0.62, 0.28)],
			["pressed", Color(0.21, 0.42, 0.18)]]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = state[1]
		sb.border_color = Color(0.12, 0.26, 0.10)
		sb.set_border_width_all(2)
		sb.border_width_bottom = 3
		sb.set_corner_radius_all(8)
		sb.set_content_margin_all(8)
		end_turn_btn.add_theme_stylebox_override(state[0], sb)
	end_turn_btn.pressed.connect(func(): Sfx.play("click", 0.05))
	end_turn_btn.pressed.connect(_on_end_turn)
	hud.add_child(end_turn_btn)

	sim_btn = Button.new()
	sim_btn.text = "Sim: OFF"
	sim_btn.toggle_mode = true
	sim_btn.position = Vector2(152, 92)
	sim_btn.size = Vector2(110, 32)
	sim_btn.toggled.connect(_on_sim_toggled)
	hud.add_child(sim_btn)

	restart_btn = Button.new()
	restart_btn.text = "Restart"
	restart_btn.position = Vector2(270, 92)
	restart_btn.size = Vector2(96, 32)
	restart_btn.pressed.connect(func(): get_tree().reload_current_scene())
	hud.add_child(restart_btn)

	# Objective chip: always-visible goal + live enemy counter, top centre.
	var obj_panel := Panel.new()
	obj_panel.position = Vector2(560, 8)
	obj_panel.size = Vector2(480, 36)
	hud.add_child(obj_panel)
	objective_label = Label.new()
	objective_label.position = Vector2(0, 6)
	objective_label.size = Vector2(480, 24)
	objective_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	objective_label.add_theme_font_size_override("font_size", 16)
	obj_panel.add_child(objective_label)

	# --- Right sidebar: resource bank, build button, deck piles ---
	var side_x := 1492.0
	var res_kinds := ["wood", "earth", "stone", "oil"]
	for ri in res_kinds.size():
		var kind: String = res_kinds[ri]
		var row_y: float = 150.0 + ri * 36.0
		var icon_path: String = "res://assets/cards/icon_%s.png" % kind
		if ResourceLoader.exists(icon_path):
			var tr := TextureRect.new()
			tr.texture = load(icon_path)
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.position = Vector2(side_x, row_y)
			tr.size = Vector2(30, 30)
			hud.add_child(tr)
		var rl := _label(Vector2(side_x + 36.0, row_y + 4.0))
		rl.add_theme_font_size_override("font_size", 17)
		rl.text = "0"
		_res_labels[kind] = rl

	build_modal_btn = Button.new()
	var hammer_path := "res://assets/cards/icon_hammer.png"
	if ResourceLoader.exists(hammer_path):
		build_modal_btn.icon = load(hammer_path)
		build_modal_btn.expand_icon = true
	build_modal_btn.text = "Build"
	build_modal_btn.position = Vector2(side_x, 302.0)
	build_modal_btn.size = Vector2(96, 52)
	build_modal_btn.pressed.connect(_open_build_modal)
	hud.add_child(build_modal_btn)

	# Deck piles live in the sidebar below the build button.
	draw_pile_panel = _pile_panel(Vector2(side_x, 372.0))
	draw_pile_label = _pile_label(draw_pile_panel, "Draw")
	discard_pile_panel = _pile_panel(Vector2(side_x, 496.0))
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


# State-driven onboarding hint for the opening turns ("" once rolling).
func _current_hint() -> String:
	if gs.is_over or gs.active_team != GameState.TEAM_PLAYER or gs.turn > 8:
		return ""
	var have_op := false
	var unarmed_op := false
	for u in gs.units:
		if u.is_alive() and u.team == 0 and u.kind == "operator":
			have_op = true
			if u.spade == null:
				unarmed_op = true
	var op_card := false
	var spade_card := false
	for c in gs.hand:
		if c["id"] == "operator":
			op_card = true
		elif c["id"] == "spade":
			spade_card = true
	if not have_op and op_card:
		return "Play an Operator card, then click a highlighted tile next to your leader to deploy."
	if unarmed_op and spade_card:
		return "Select a Spade card, then click an operator to arm them."
	if have_op and int(gs.wood[0]) == 0 and int(gs.earth[0]) == 0:
		return "Operators harvest: select one, then click a tree to chop or use Dig on the ground."
	if int(gs.wood[0]) + int(gs.earth[0]) >= 2:
		return "Spend materials in the Build menu (hammer, right sidebar) — bought cards go to your hand."
	return ""

# Battle-start flourish: jagged shard curtains crawl in with a title block,
# then withdraw to reveal the map; the area/objective banner follows on reveal.
func _play_battle_intro() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshot="):
			return        # keep harness shots clean
	var intro := BattleIntro.new()
	intro.setup("ENGAGE THE ENEMY")
	intro.revealed.connect(_show_area_banner)
	hud.add_child(intro)

# Big fading banner announcing the area + objective; shown on entry.
func _show_area_banner() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshot="):
			return        # keep harness shots clean
	var title := Label.new()
	title.text = gs.area_title()
	title.add_theme_font_size_override("font_size", 54)
	title.add_theme_color_override("font_outline_color", Color(0.16, 0.10, 0.05))
	title.add_theme_constant_override("outline_size", 12)
	title.position = Vector2(0, 300)
	title.size = Vector2(1600, 70)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(title)
	var sub := Label.new()
	sub.text = gs.objective_text()
	sub.add_theme_font_size_override("font_size", 24)
	sub.add_theme_color_override("font_outline_color", Color(0.16, 0.10, 0.05))
	sub.add_theme_constant_override("outline_size", 7)
	sub.position = Vector2(0, 370)
	sub.size = Vector2(1600, 34)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(sub)
	for l in [title, sub]:
		l.modulate = Color(1, 1, 1, 0)
		var tw := create_tween()
		tw.tween_property(l, "modulate:a", 1.0, 0.45)
		tw.tween_interval(2.4)
		tw.tween_property(l, "modulate:a", 0.0, 0.8)
		tw.tween_callback(l.queue_free)

# ---------------------------------------------------------------- modals

func _close_modal() -> void:
	if _modal != null:
		_modal.queue_free()
		_modal = null

func _make_modal(height: float) -> Panel:
	_close_modal()
	_modal = Panel.new()
	_modal.position = Vector2(560, 280)
	_modal.size = Vector2(480, height)
	hud.add_child(_modal)
	return _modal

# Pick-1-of-3 for an upgrade-choice card. Options are rolled once and stored
# on the card so closing/reopening doesn't reroll.
func _open_choice_modal(card) -> void:
	if not card.has("options"):
		card["options"] = gs.choice_options()
	var panel := _make_modal(90 + card["options"].size() * 64.0)
	var title := Label.new()
	title.text = "Choose an upgrade"
	title.add_theme_font_size_override("font_size", 18)
	title.position = Vector2(20, 14)
	panel.add_child(title)
	var y := 52.0
	for option in card["options"]:
		var b := Button.new()
		b.text = "%s\n%s" % [option["title"], option["desc"]]
		b.position = Vector2(20, y)
		b.size = Vector2(440, 56)
		b.pressed.connect(func():
			gs.apply_choice(card, option)
			_close_modal())
		panel.add_child(b)
		y += 64.0
	var cancel := Button.new()
	cancel.text = "Later"
	cancel.position = Vector2(380, 14)
	cancel.size = Vector2(80, 28)
	cancel.pressed.connect(_close_modal)
	panel.add_child(cancel)

# Area cleared → reward pick (magic cards after a wizard miniboss, special
# unit cards otherwise), then the expansion direction pick.
func _on_area_cleared(area_num: int) -> void:
	var panel := _make_modal(96 + 3 * 64.0)
	var title := Label.new()
	title.add_theme_font_size_override("font_size", 17)
	title.position = Vector2(20, 14)
	panel.add_child(title)
	var y := 52.0
	if gs.last_area_wizard:
		title.text = "Wizard defeated! Choose a MAGIC card:"
		for option in gs.magic_options():
			var b := Button.new()
			b.text = "%s — %s" % [option["title"], option["blurb"]]
			b.position = Vector2(20, y)
			b.size = Vector2(440, 56)
			var opt: Dictionary = option
			b.pressed.connect(func():
				gs.grant_magic(opt)
				_open_expand_modal())
			panel.add_child(b)
			y += 64.0
	else:
		title.text = "Area %d cleared! Choose a special unit card:" % area_num
		for id in GameState.SPECIAL_UNITS:
			var s: Dictionary = GameState.SPECIAL_UNITS[id]
			var b := Button.new()
			b.text = "%s — %s" % [s["title"], s["blurb"]]
			b.position = Vector2(20, y)
			b.size = Vector2(440, 56)
			var picked_id: String = id
			b.pressed.connect(func():
				gs.grant_special(picked_id)
				_open_expand_modal())
			panel.add_child(b)
			y += 64.0

const BRANCH_LABELS := {
	"hills": "The Hills — domain of the King of the Hill",
	"riverlands": "The Riverlands — domain of The Otter",
	"flud": "FLUD's Domain — the gurus' master (finale)",
}

func _open_expand_modal() -> void:
	var options: Array = gs.expansion_options()
	var panel := _make_modal(96 + options.size() * 64.0)
	var title := Label.new()
	title.text = "March onward:" if options.size() == 1 else "Choose your path:"
	title.add_theme_font_size_override("font_size", 17)
	title.position = Vector2(20, 14)
	panel.add_child(title)
	var y := 52.0
	for opt_v in options:
		var opt: String = String(opt_v)
		var b := Button.new()
		b.text = String(BRANCH_LABELS.get(opt, opt))
		b.position = Vector2(20, y)
		b.size = Vector2(440, 56)
		var choice: String = opt
		b.pressed.connect(func(): _advance_area(choice))
		panel.add_child(b)
		y += 64.0

func _advance_area(direction: String) -> void:
	_close_modal()
	mode = ""
	pending_card = null
	selected_cards.clear()
	gs.advance_area(direction)
	var leader = _player_leader()
	if leader != null:
		_select(leader)
		_center_on(leader.grid)
	_play_battle_intro()

# Art for a blueprint tile: structures use their placed art, buildings their
# building sprite, the boat its unit sprite, dirt walls the earth card.
func _blueprint_art(id: String) -> Texture2D:
	var candidates := []
	if id == "boat":
		candidates = ["res://assets/cards/unit_boat.png"]
	elif id == "dirt_wall":
		candidates = ["res://assets/cards/raw/earth.png", "res://assets/cards/earth.png"]
	else:
		candidates = ["res://assets/cards/building_%s.png" % id,
				"res://assets/cards/%s.png" % id]
	for c in candidates:
		if ResourceLoader.exists(c):
			return load(c)
	return null

# The hammer menu: owned schematics only, affordable builds ranked first,
# scrollable when the collection outgrows the panel. Buying puts the card in
# your hand and re-ranks.
func _open_build_modal() -> void:
	var owned: Array = []
	for bp in GameState.BLUEPRINTS:
		if Meta.is_unlocked(String(bp["id"])):
			owned.append(bp)
	var can_act: bool = gs.active_team == GameState.TEAM_PLAYER and not gs.is_over
	var ranked: Array = []
	for i in owned.size():
		var bp: Dictionary = owned[i]
		ranked.append({"bp": bp, "afford": can_act and gs.can_afford_blueprint(bp), "i": i})
	ranked.sort_custom(func(a, b):
		if a["afford"] != b["afford"]:
			return a["afford"]            # affordable first
		return a["i"] < b["i"])           # stable catalog order within groups
	var cols := 5
	var rows: int = maxi(1, int(ceil(float(ranked.size()) / float(cols))))
	var tile_w := 142.0
	var tile_h := 148.0
	var grid_h: float = rows * tile_h
	var view_h: float = minf(grid_h, 560.0)
	var panel := _make_modal(74.0 + view_h)
	panel.size = Vector2(56.0 + cols * tile_w, 74.0 + view_h)
	panel.position = Vector2((1600.0 - panel.size.x) * 0.5, 90.0)
	var title := Label.new()
	title.text = "Build — materials in bank (more schematics on the title screen)"
	title.add_theme_font_size_override("font_size", 17)
	title.position = Vector2(20, 14)
	panel.add_child(title)
	var closer := Button.new()
	closer.text = "X"
	closer.position = Vector2(panel.size.x - 46, 10)
	closer.size = Vector2(36, 30)
	closer.pressed.connect(_close_modal)
	panel.add_child(closer)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(20, 54)
	scroll.size = Vector2(cols * tile_w + 16.0, view_h)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var grid := Control.new()
	grid.custom_minimum_size = Vector2(cols * tile_w, grid_h)
	scroll.add_child(grid)
	for r in ranked.size():
		var entry: Dictionary = ranked[r]
		var bp: Dictionary = entry["bp"]
		var id: String = String(bp["id"])
		var affordable: bool = entry["afford"]
		var tile := Panel.new()
		tile.position = Vector2((r % cols) * tile_w, float(r / cols) * tile_h)
		tile.size = Vector2(tile_w - 10.0, tile_h - 10.0)
		tile.modulate = Color(1, 1, 1) if affordable else Color(0.55, 0.55, 0.55)
		grid.add_child(tile)
		var art: Texture2D = _blueprint_art(id)
		if art != null:
			var tr := TextureRect.new()
			tr.texture = art
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.position = Vector2(8, 6)
			tr.size = Vector2(tile_w - 26.0, 84.0)
			tile.add_child(tr)
		var nm := Label.new()
		nm.text = gs.blueprint_card_title(id)
		nm.add_theme_font_size_override("font_size", 12)
		nm.position = Vector2(8, 94)
		nm.size = Vector2(tile_w - 26.0, 18)
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tile.add_child(nm)
		var cost := Label.new()
		cost.text = _bp_cost_label(bp)
		cost.add_theme_font_size_override("font_size", 12)
		cost.add_theme_color_override("font_color",
				Color(0.55, 0.95, 0.55) if affordable else Color(0.95, 0.55, 0.45))
		cost.position = Vector2(8, 112)
		cost.size = Vector2(tile_w - 26.0, 18)
		cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tile.add_child(cost)
		var hit := Button.new()
		hit.flat = true
		hit.position = Vector2.ZERO
		hit.size = tile.size
		hit.disabled = not affordable
		hit.pressed.connect(func():
			if gs.buy_blueprint(id):
				_open_build_modal())
		tile.add_child(hit)

# Confirm dialog for a distant-tree harvest task.
func _open_harvest_confirm(u, tree_cell: Vector3i) -> void:
	var turns: int = gs.harvest_turns(u, tree_cell)
	if turns < 0:
		gs.notice.emit("That tree can't be reached.")
		return
	var panel := _make_modal(120)
	var lbl := Label.new()
	lbl.text = "Harvest this tree: ~%d turn(s).\nOperator will walk there and chop automatically." % turns
	lbl.position = Vector2(20, 14)
	lbl.size = Vector2(440, 50)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(lbl)
	var ok := Button.new()
	ok.text = "Confirm"
	ok.position = Vector2(120, 76)
	ok.size = Vector2(110, 32)
	ok.pressed.connect(func():
		gs.assign_harvest(u, tree_cell)
		_close_modal())
	panel.add_child(ok)
	var no := Button.new()
	no.text = "Cancel"
	no.position = Vector2(250, 76)
	no.size = Vector2(110, 32)
	no.pressed.connect(_close_modal)
	panel.add_child(no)

func _bp_cost_label(bp: Dictionary) -> String:
	var parts: Array = []
	if int(bp["wood"]) > 0:
		parts.append("%dw" % int(bp["wood"]))
	if int(bp["oil"]) > 0:
		parts.append("%do" % int(bp["oil"]))
	if int(bp.get("earth", 0)) > 0:
		parts.append("%de" % int(bp.get("earth", 0)))
	if int(bp.get("stone", 0)) > 0:
		parts.append("%ds" % int(bp.get("stone", 0)))
	return " ".join(parts)

func _pile_panel(pos: Vector2) -> Panel:
	var p := Panel.new()
	p.position = pos
	p.size = Vector2(88, 110)
	hud.add_child(p)
	# Living psychedelic card-back behind the count — the deck reads as a stack
	# of face-down folk cards (self-animating via the shader's TIME).
	if ResourceLoader.exists("res://assets/folk_back.gdshader"):
		var back := ColorRect.new()
		back.position = Vector2(5, 5)
		back.size = Vector2(78, 100)
		back.clip_contents = true
		var mat := ShaderMaterial.new()
		mat.shader = load("res://assets/folk_back.gdshader")
		back.material = mat
		p.add_child(back)
	return p

func _pile_label(parent: Panel, prefix: String) -> Label:
	var l := Label.new()
	l.text = "%s\n0" % prefix
	l.position = Vector2(6, 24)
	l.size = Vector2(76, 60)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Heavy outline so the count stays legible over the animated back.
	l.add_theme_color_override("font_color", Color(0.98, 0.94, 0.82))
	l.add_theme_color_override("font_outline_color", Color(0.05, 0.03, 0.06))
	l.add_theme_constant_override("outline_size", 6)
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
	# Fly ghost copies into the discard pile before the hand refreshes.
	var target: Vector2 = discard_pile_panel.position + discard_pile_panel.size * 0.5
	var gi := 0
	for c in to_discard:
		for b in context_buttons:
			if b.has_meta("card") and b.get_meta("card") == c:
				var ghost: Button = b.duplicate()
				ghost.position = b.position
				ghost.rotation_degrees = b.rotation_degrees
				ghost.pivot_offset = ghost.size * 0.5
				hud.add_child(ghost)
				var tw := create_tween().set_parallel(true)
				var dl: float = gi * 0.05
				tw.tween_property(ghost, "position", target - ghost.size * 0.5 * 0.3, 0.32) \
					.set_delay(dl).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
				tw.tween_property(ghost, "scale", Vector2(0.3, 0.3), 0.32).set_delay(dl)
				tw.tween_property(ghost, "rotation_degrees", 35.0, 0.32).set_delay(dl)
				tw.tween_property(ghost, "modulate", Color(1, 1, 1, 0.2), 0.32).set_delay(dl)
				tw.chain().tween_callback(ghost.queue_free)
				gi += 1
				break
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
# autopilot it. Otherwise hand control to the player and auto-select the
# leader so the camera + hand reset to base each turn.
func _on_turn_started(team: int) -> void:
	if gs.is_over:
		return
	if team == GameState.TEAM_ENEMY or gs.sim_mode:
		_kick_ai()
		return
	if team == GameState.TEAM_PLAYER:
		var leader = _player_leader()
		if leader != null:
			gs.select(leader)        # _on_changed will re-focus view_level

func _kick_ai() -> void:
	# Pause auto-play while a decision modal is up (area-clear reward /
	# expansion). Without this, sim mode flips empty turns forever waiting on
	# a choice nobody makes.
	if _ai_running or gs.is_over or _modal != null:
		return
	_ai_running = true
	mode = ""
	pending_card = null
	gs.selected = null
	await _run_ai_turn(gs.active_team)
	_ai_running = false
	# Yield a frame before handing off. _run_ai_turn returns synchronously when
	# a team has no legal action (e.g. one side wiped at battle's end), so
	# without this the turn cycle would recurse on the call stack instead of
	# iterating across frames — a guaranteed stack overflow.
	await get_tree().process_frame
	if not gs.is_over and _modal == null:
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
	if sim_btn != null:
		sim_btn.button_pressed = false
		sim_btn.text = "Sim: OFF"
		gs.sim_mode = false
	if winner_team == GameState.TEAM_ENEMY and not gs.sim_mode:
		_show_end_screen(false)

# Full-screen run summary — victory (FLUD beaten) or defeat (team wiped).
func _show_end_screen(won: bool) -> void:
	Sfx.play("victory" if won else "death", 0.0, 0.0)
	var overlay := ColorRect.new()
	overlay.color = Color(0.05, 0.04, 0.03, 0.72)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.add_child(overlay)
	var panel := Panel.new()
	panel.size = Vector2(560, 420)
	panel.position = Vector2((1600 - 560) * 0.5, 200)
	overlay.add_child(panel)
	var title := Label.new()
	title.text = "VICTORY — FLUD HAS FALLEN" if won else "DEFEAT"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color",
		Color(0.55, 0.95, 0.55) if won else Color(0.95, 0.55, 0.45))
	title.position = Vector2(0, 28)
	title.size = Vector2(560, 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(title)
	var deck_n: int = gs.draw_pile.size() + gs.hand.size() + gs.discard.size()
	var stats := Label.new()
	stats.text = "Areas cleared: %d\nTurns taken: %d\nDeck size: %d cards\n\nCoins earned this run: %d\nPurse total: %d" % 		[gs.area if won else gs.area - 1, gs.turn, deck_n, gs.run_coins, Meta.coins]
	stats.add_theme_font_size_override("font_size", 19)
	stats.position = Vector2(0, 100)
	stats.size = Vector2(560, 200)
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(stats)
	var sub := Label.new()
	sub.text = "Spend coins on schematics from the title screen." if won 		else "Your coins are banked — buy schematics and run it back."
	sub.add_theme_font_size_override("font_size", 14)
	sub.position = Vector2(0, 296)
	sub.size = Vector2(560, 22)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(sub)
	var back := Button.new()
	back.text = "Return to Title"
	back.position = Vector2(180, 340)
	back.size = Vector2(200, 50)
	back.add_theme_font_size_override("font_size", 18)
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/title.tscn"))
	panel.add_child(back)

func _on_cards_drawn(count: int) -> void:
	# Recorded here; the actual slide-in happens during the next _refresh_context
	# when the new card Buttons are instantiated.
	_pending_anim_count = count

func _label(pos: Vector2) -> Label:
	var l := Label.new()
	l.position = pos
	# Dark outline keeps HUD text legible against the bright WW sky.
	l.add_theme_color_override("font_outline_color", Color(0.08, 0.10, 0.16))
	l.add_theme_constant_override("outline_size", 4)
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
	info_label.text = "Turn %d   %s   Energy %d/%d   Selected: %s   [mode: %s]" % \
		[gs.turn, team_label, gs.energy, GameState.MAX_ENERGY,
			who, mode if mode != "" else "—"]
	if end_turn_btn != null:
		end_turn_btn.disabled = gs.is_over or _ai_running or gs.active_team != GameState.TEAM_PLAYER
	if objective_label != null:
		var n_enemies: int = gs.team_alive_count(GameState.TEAM_ENEMY)
		objective_label.text = "%s   (%d %s left)" % [gs.objective_text(),
			n_enemies, "enemy" if n_enemies == 1 else "enemies"]
	# Contextual hint for the opening turns; falls back to the controls line.
	if hint_label != null:
		var hint: String = _current_hint()
		if hint != "":
			hint_label.text = "TIP: " + hint
			hint_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.6))
		else:
			hint_label.text = HINT_CONTROLS
			hint_label.add_theme_color_override("font_color", Color(0.98, 0.96, 0.9))
	# Sidebar resource counts.
	for kind in _res_labels:
		var bank: Array = gs.get(kind)
		_res_labels[kind].text = str(int(bank[GameState.TEAM_PLAYER]))
	if build_modal_btn != null:
		build_modal_btn.disabled = gs.is_over or _ai_running \
				or gs.active_team != GameState.TEAM_PLAYER

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
		var centre_i: float = (float(n) - 1.0) * 0.5
		for card in gs.hand:
			# Fanned hand: slight per-card rotation + arc so it reads like
			# held cards rather than a toolbar.
			var off: float = float(i) - centre_i
			var fan_rot: float = off * 1.6
			var arc_y: float = pow(absf(off), 1.7) * 2.4
			var slot_y: float = HAND_Y + arc_y - (30.0 if selected_cards.has(card) else 0.0)
			var b := _make_card_button(card, card_x, slot_y, _on_card.bind(card))
			b.set_meta("card", card)
			b.pivot_offset = b.size * 0.5
			b.rotation_degrees = fan_rot
			if selected_cards.has(card):
				b.modulate = Color(1.18, 1.18, 1.00)
				b.rotation_degrees = 0.0
			hud.add_child(b)
			context_buttons.append(b)
			_attach_card_hover(b, Vector2(card_x, slot_y), fan_rot,
					selected_cards.has(card))
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
		var cant_fish: bool = no_action or not u.has_fishing_pole \
				or not gs._adjacent_to_water(u.grid)
		x = _ctx_button("Fish", x, y, func(): gs.fish(gs.selected), cant_fish)
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
# Hover: card lifts, straightens, and grows slightly; settles back on exit.
func _attach_card_hover(b: Button, base_pos: Vector2, base_rot: float, is_selected: bool) -> void:
	if is_selected:
		return        # selected cards already sit raised
	b.mouse_entered.connect(func():
		if not is_instance_valid(b):
			return
		var tw := b.create_tween().set_parallel(true)
		tw.tween_property(b, "position:y", base_pos.y - 26.0, 0.12) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(b, "scale", Vector2(1.07, 1.07), 0.12)
		tw.tween_property(b, "rotation_degrees", 0.0, 0.12))
	b.mouse_exited.connect(func():
		if not is_instance_valid(b):
			return
		var tw := b.create_tween().set_parallel(true)
		tw.tween_property(b, "position:y", base_pos.y, 0.16) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(b, "scale", Vector2.ONE, 0.16)
		tw.tween_property(b, "rotation_degrees", base_rot, 0.16))

# Draw-in: cards fly from the sidebar draw pile with a back-eased pop —
# spinning up from small, staggered per card.
func _animate_card_in(card_btn: Button, target_pos: Vector2, anim_index: int) -> void:
	var pile_pos: Vector2 = draw_pile_panel.position + draw_pile_panel.size * 0.5 \
			- Vector2(CARD_W * 0.5, CARD_H * 0.5)
	card_btn.position = pile_pos
	card_btn.modulate = Color(1, 1, 1, 0)
	card_btn.pivot_offset = card_btn.size * 0.5
	var end_rot: float = card_btn.rotation_degrees
	card_btn.rotation_degrees = -24.0
	card_btn.scale = Vector2(0.55, 0.55)
	var tween := create_tween().set_parallel(true)
	var delay: float = anim_index * 0.08
	tween.tween_property(card_btn, "position", target_pos, 0.38) \
		.set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(card_btn, "modulate", Color.WHITE, 0.22).set_delay(delay)
	tween.tween_property(card_btn, "rotation_degrees", end_rot, 0.38) \
		.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(card_btn, "scale", Vector2.ONE, 0.38) \
		.set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

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
# Cards whose item physically exists in the world show the EXACT art of the
# thing that gets placed — what you play is what you get.
const CARD_ART_ALIASES := {
	"operator": "unit_operator",
	"warrior": "unit_warrior",
	"javelin": "unit_javelin",
	"plow": "unit_plow",
	"boat": "unit_boat",
	"dirt_wall": "earth",
	"waterwheel": "building_waterwheel",
	"storehouse": "building_storehouse",
	"village": "building_village",
	"trebuchet": "building_trebuchet",
	"farm": "building_farm",
	"campsite": "building_campsite",
	"barracks": "building_barracks",
}

func _texture_for(raw_id: String):
	var id: String = String(CARD_ART_ALIASES.get(raw_id, raw_id))
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
	if _ai_running or _combo_animating:
		return
	# Upgrade-choice cards open the pick-1-of-3 modal.
	if String(card.get("category", "")) == "choice":
		selected_cards.clear()
		_open_choice_modal(card)
		return
	# Ritual cards use area targeting — except the instant ones (Call
	# Ancestors / Descendents), which resolve on click.
	if String(card.get("category", "")) == "ritual":
		selected_cards.clear()
		if String(card["id"]) in GameState.INSTANT_MAGIC:
			gs.play_instant(card)
			return
		pending_card = card
		mode = "ritual"
		_on_changed()
		if targets.is_empty():
			gs.notice.emit("No valid target for %s." % card["title"])
			pending_card = null
			mode = "move"
			_on_changed()
		else:
			gs.notice.emit("Pick a target tile for %s." % card["title"])
		return
	# Structure cards (ladder / bridge) place directly — not part of combos.
	if String(card.get("category", "")) == "structure":
		selected_cards.clear()
		pending_card = card
		mode = "place_structure"
		_on_changed()
		if targets.is_empty():
			gs.notice.emit("No valid spot for %s — move a unit closer." % card["title"])
			pending_card = null
			mode = "move"
			_on_changed()
		else:
			gs.notice.emit("Pick where to build the %s." % card["title"])
		return
	# Clicking a card toggles it in the current combo. The play happens when
	# the user clicks a valid target tile (see _act_on).
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

# Child Node2D that caches the static-terrain draw call. Sits at z_index = -1
# so it renders behind iso_view's own _draw output (units / projectiles / etc).
# Its _draw delegates back to the view; the view sets `_draw_canvas` so the
# polygon helpers in _draw_cube route their primitives to this layer.
class TerrainLayer extends Node2D:
	var view

	func _draw() -> void:
		if view != null:
			view._draw_terrain_layer(self)

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
