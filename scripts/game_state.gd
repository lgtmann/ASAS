class_name GameState
extends RefCounted

# Turn/energy/hand loop and the spade action set for the core sandbox. Pure data
# + logic; the 3D views and HUD live in main.gd and refresh on the `changed`
# signal. World is untyped to keep things decoupled.

signal notice(text)
signal changed()
signal spade_thrown(from_grid, to_grid, boomerang)
signal cards_drawn(count)               # how many new cards were just added to the hand
signal turn_started(team)               # fires from begin_turn (use to kick off AI)
signal game_over(winner_team)           # fires once when a team is wiped
signal unit_animated_move(unit, from_grid, to_grid)   # iso_view tweens draw_pos
signal quake_started(columns)           # Array[Vector2i] of (x, z) columns to shake
signal area_cleared(area_num)           # all enemies dead — offer reward + expansion
signal unit_attacked(attacker, target_grid)  # melee swing/bite — lunge animation
signal unit_damaged(unit, amount)            # any damage — hit flash + number
signal unit_died(unit, grid)                 # death — tip-over ghost animation
signal terrain_hit(cell, mat)                # dig/chop/smash — particle burst

const MAX_ENERGY := 6                  # leader's combo budget per turn
const HAND_SIZE := 5
const FIRST_TURN_HAND := 7             # extra cards on the very first player turn
const DIRS := [Vector3i(0, 0, 1), Vector3i(1, 0, 0), Vector3i(0, 0, -1), Vector3i(-1, 0, 0)]
const DOWN := Vector3i(0, -1, 0)
const CARDINAL_6 := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
]
const MOVE_RANGE := 4       # BFS step budget for move highlights
const THROW_RADIUS := 2     # base cube radius (used as Spade.throw_range default)
const TEAM_PLAYER := 0
const TEAM_ENEMY := 1

# ----- Upgrade catalog --------------------------------------------------------
# Card "category" determines what they upgrade:
#   "head" / "shaft" / "handle" → fill a slot on the recipient's held spade
#   "operator_upgrade"          → persistent flag on the operator itself
# Fully-implemented effects are noted in the blurb. Slot-only ones still apply
# (their slot fills, blocking duplicates) but their mechanic is a stub for now.
const UPGRADES := {
	# --- Head (7) ---
	"spade_blade":           {"title": "Spade Blade",         "cost": 2, "category": "head",   "blurb": "+1 swing vs enemies"},
	"spade_pick":            {"title": "Spade Pick",          "cost": 2, "category": "head",   "blurb": "+1 swing vs walls"},
	"spade_tip":             {"title": "Spade Tip",           "cost": 2, "category": "head",   "blurb": "+1 dig depth"},
	"spade_grappling_hook":  {"title": "Grappling Hook",      "cost": 3, "category": "head",   "blurb": "climb 3 up (stub)"},
	"spade_warhead":         {"title": "Spade Warhead",       "cost": 3, "category": "head",   "blurb": "thrown spade AOE r1"},
	"spade_pogostick":       {"title": "Spade Pogostick",     "cost": 3, "category": "head",   "blurb": "2x move (stub)"},
	"spade_metal_detector":  {"title": "Metal Detector",      "cost": 2, "category": "head",   "blurb": "reveals all gold"},
	"spade_earthquake":      {"title": "Spade Earthquake",    "cost": 3, "category": "head",   "blurb": "Special: shake r2"},
	# --- Shaft (4) ---
	"spade_laser_rangefinder": {"title": "Laser Rangefinder", "cost": 2, "category": "shaft",  "blurb": "guided throw (stub)"},
	"spade_wings":           {"title": "Spade Wings",         "cost": 2, "category": "shaft",  "blurb": "+3 throw range"},
	"double_barrel_spade":   {"title": "Double Barrel",       "cost": 3, "category": "shaft",  "blurb": "two heads (stub)"},
	"spade_dousing_rod":     {"title": "Dousing Rod",         "cost": 2, "category": "shaft",  "blurb": "reveals water"},
	# --- Handle (3) ---
	"spade_propulsion":      {"title": "Spade Propulsion",    "cost": 3, "category": "handle", "blurb": "launch (stub)"},
	"spade_boomerang":       {"title": "Spade Boomerang",     "cost": 2, "category": "handle", "blurb": "thrown spade returns"},
	"spade_trigger":         {"title": "Spade Trigger",       "cost": 3, "category": "handle", "blurb": "act twice (stub)"},
	# --- Operator (4) ---
	"dual_wield":            {"title": "Dual Wield",          "cost": 3, "category": "operator_upgrade", "blurb": "carry 2 spades (stub)"},
	"endurance":             {"title": "Endurance",           "cost": 2, "category": "operator_upgrade", "blurb": "2 actions/turn (stub)"},
	"strength":              {"title": "Strength",            "cost": 2, "category": "operator_upgrade", "blurb": "+1 dig/swing/throw"},
	"hand_eye":              {"title": "Hand-Eye Coord",      "cost": 2, "category": "operator_upgrade", "blurb": "catch thrown spades (stub)"},
	"fishing_pole":          {"title": "Fishing Pole",        "cost": 1, "category": "operator_upgrade", "blurb": "Fish food from water"},
}

var world = null
var units: Array = []        # Array[Unit]
var dropped: Array = []      # Array[Spade] lying on the ground
var selected = null          # Unit
var energy: int = MAX_ENERGY
var turn: int = 1

var draw_pile: Array = []
var hand: Array = []
var discard: Array = []
var _next_card_instance: int = 0   # monotonic id so identical-content cards don't compare equal

# Fog of war: every cell ever revealed by a friendly unit's line-of-sight.
# Unseen solid cells render as light grey (you see shape, not material).
var seen: Dictionary = {}
# Cache key for the last vision recompute (terrain version + friendly unit
# positions). Recompute is the CPU hot path — skip it when nothing relevant
# moved or changed.
var _vision_key: String = ""

# Turn-team tracking and a flag so iso_view can auto-play BOTH sides
# (visible combat simulation).
var active_team: int = TEAM_PLAYER
var sim_mode: bool = false
var is_over: bool = false

# Campaign: the run is a chain of increasingly hard areas. Clearing one offers
# a special-unit card, then a choice of expansion direction.
var area: int = 1
var _area_clear_emitted: bool = false

# Overworld: after the intro area you pick a governor's domain. Each branch is
# an intro area (wizard miniboss) then the governor boss. Beat both governors
# to unlock Flud, their guru.
var branch: String = ""                 # "", "hills", "riverlands", "flud"
var stage_in_branch: int = 0            # 0 = intro/none, 1 = branch intro, 2 = boss
var bosses_defeated: Dictionary = {"hills": false, "riverlands": false}

# Where can the player expand right now?
func expansion_options() -> Array:
	if stage_in_branch == 1 and branch != "":
		return [branch]                  # mid-branch: the boss is next, no detours
	var opts: Array = []
	if not bool(bosses_defeated["hills"]):
		opts.append("hills")
	if not bool(bosses_defeated["riverlands"]):
		opts.append("riverlands")
	if opts.is_empty():
		opts.append("flud")
	return opts

# Stockpiled strategic resources (per team). Oil unlocks advanced cards later.
# Energy is still per-turn — these are persistent banks that fill over time.
var oil: Array = [0, 0]   # oil[team] = barrels in the bank
var wood: Array = [0, 0]  # wood[team] = logs in the bank (chopped trees)
var earth: Array = [0, 0] # earth[team] = dirt in the bank (dug cells)
var stone: Array = [0, 0] # stone[team] = rocks in the bank (smashed boulders)

# Built structures with per-kind behaviour: grid -> {kind, team, timer}.
# (Ballistas predate this registry and keep their own list.)
var buildings: Dictionary = {}

# Run-progression passives gained from upgrade-choice cards ("exhaust" picks).
var passives: Dictionary = {}
# Player-built ballistas: [{grid: Vector3i, team: int}] — auto-fire at end of
# their team's turn.
var ballistas: Array = []

# ---------------------------------------------------------------- setup

func setup(w) -> void:
	world = w

func start() -> void:
	# `--seed=N` (after the `--` separator) pins the map for reproducible
	# screenshots — the art pipeline diffs before/after shots on one layout.
	var fixed_seed: int = -1
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			fixed_seed = int(arg.trim_prefix("--seed="))
	if fixed_seed >= 0:
		seed(fixed_seed)
		world.generate()          # regenerate deterministically under the seed
		world.version += 1
	else:
		randomize()
	_build_deck()
	# Player base in the near corner (closest to the screen in iso = highest
	# x+z), enemy in the far corner. Player starts with ONLY the leader —
	# operators come from cards.
	var px: int = world.SX - 3
	var pz: int = world.SZ - 3
	var leader = _spawn_unit(0, world.surface_cell(px, pz), false)
	leader.kind = "leader"
	leader.hp = 8
	leader.max_hp = 8
	_spawn_enemy_force()
	selected = leader
	recompute_vision()
	begin_turn()

# Whether the area just played grants MAGIC rewards (miniboss / governor /
# guru areas). Read at area-clear time by the reward modal.
var last_area_wizard: bool = false

# Spawn the enemy force for the current campaign position. Intro area is a
# plain leader + 2 operators; branch intro areas are wizard minibosses with a
# mixed force; branch boss areas spawn the governor (King / Otter); Flud is
# the (stubbed) finale. Minibosses + bosses grant magic rewards.
func _spawn_enemy_force() -> void:
	last_area_wizard = false
	if branch == "flud" and stage_in_branch == 2:
		last_area_wizard = true
		_spawn_flud_force()
		return
	if stage_in_branch == 2:
		last_area_wizard = true
		if branch == "hills":
			_spawn_king_force()
		else:
			_spawn_otter_force()
		return
	if stage_in_branch == 1:
		last_area_wizard = true
		_apply_branch_flavour()
		var wiz = _spawn_unit(TEAM_ENEMY, _free_spot_near(2, 2), false)
		wiz.kind = "wizard"
		wiz.hp = 8 + 2 * area
		wiz.max_hp = wiz.hp
		var kinds := ["wolf", "warrior", "javelin", "operator"]
		for i in (1 + area):
			var kind: String = kinds[i % kinds.size()]
			var m = _spawn_unit(TEAM_ENEMY, _free_spot_near(2, 2), kind != "wolf")
			m.kind = kind
			if kind == "wolf":
				m.hp = 4
				m.max_hp = 4
			elif kind == "javelin" and m.spade != null:
				m.spade.handle = "spade_boomerang"
		return
	# Intro area (area 1).
	var el = _spawn_unit(TEAM_ENEMY, _free_spot_near(2, 2), false)
	el.kind = "leader"
	el.hp = 8
	el.max_hp = el.hp
	_spawn_unit(TEAM_ENEMY, _free_spot_near(3, 2), true)
	_spawn_unit(TEAM_ENEMY, _free_spot_near(2, 3), true)

# Branch terrain flavour: the hills get extra boulders + raised mounds; the
# riverlands get a second river.
func _apply_branch_flavour() -> void:
	if branch == "hills":
		for i in 10:
			var x: int = randi() % world.SX
			var z: int = randi() % world.SZ
			if world._is_safe_zone(x, z):
				continue
			var top: Vector3i = world.surface_cell(x, z)
			if world.is_air(top) and unit_at(top) == null:
				world.set_material(top, VoxelWorld.Mat.EARTH if (i % 2 == 0) else VoxelWorld.Mat.STONE)
	elif branch == "riverlands":
		world.add_river()

# The Otter — governor of the riverlands. Stands by the water; alternates
# between launching boat-riders and bending the river toward you.
func _spawn_otter_force() -> void:
	# Find the river reach nearest the enemy corner.
	var best_w := Vector3i(2, world.GROUND, 2)
	var best_s: int = 99999
	for w_v in world.water_flow.keys():
		var w: Vector3i = w_v
		if w.x + w.z < best_s:
			best_s = w.x + w.z
			best_w = w
	var otter = _spawn_unit(TEAM_ENEMY, _free_spot_near(best_w.x, best_w.z), false)
	otter.kind = "otter"
	otter.hp = 12 + 2 * area
	otter.max_hp = otter.hp
	for i in 2:
		var jt = _spawn_unit(TEAM_ENEMY, _free_spot_near(3, 3), true)
		jt.kind = "javelin"
		if jt.spade != null:
			jt.spade.handle = "spade_boomerang"
	# Two boat-riders already patrolling the river.
	var placed: int = 0
	for w_v in world.water_flow.keys():
		if placed >= 2:
			break
		var w: Vector3i = w_v
		if unit_at(w) == null:
			var b = _spawn_unit(TEAM_ENEMY, w, false)
			b.kind = "boat"
			b.hp = 4
			b.max_hp = 4
			placed += 1

# Flud, the guru — full battle comes later. For now: a brutal mixed vanguard.
func _spawn_flud_force() -> void:
	notice.emit("FLUD's domain — the waters rise… (full battle coming soon)")
	world.add_river()
	var flud = _spawn_unit(TEAM_ENEMY, _free_spot_near(2, 2), false)
	flud.kind = "wizard"
	flud.hp = 24
	flud.max_hp = 24
	for i in 3:
		var m = _spawn_unit(TEAM_ENEMY, _free_spot_near(3, 3), i > 0)
		m.kind = ["wolf", "warrior", "javelin"][i]
		if m.kind == "wolf":
			m.hp = 4
			m.max_hp = 4

# King of the Hill: a tower-building boss guarded by javelin throwers and
# crewed ballistas. Approach and the ranged screen shreds you; hang back and
# his hill grows ever higher.
func _spawn_king_force() -> void:
	var king = _spawn_unit(TEAM_ENEMY, _free_spot_near(2, 2), false)
	king.kind = "king"
	king.hp = 10 + 3 * area
	king.max_hp = king.hp
	# Javelin screen.
	for i in (2 + area / 3):
		var jt = _spawn_unit(TEAM_ENEMY, _free_spot_near(3, 3), true)
		jt.kind = "javelin"
		if jt.spade != null:
			jt.spade.handle = "spade_boomerang"
	# Two crewed ballistas flanking the hill.
	for i in 2:
		var bspot: Vector3i = _free_spot_near(2 + i * 3, 4)
		world.set_material(bspot, VoxelWorld.Mat.BALLISTA)
		ballistas.append({"grid": bspot, "team": TEAM_ENEMY})
		var gunner = _spawn_unit(TEAM_ENEMY, _free_spot_near(bspot.x, bspot.z), true)
		gunner.kind = "operator"

# Wrap `changed.emit()` so gravity + vision stay in sync without sprinkling
# refreshes through every action.
func _emit_changed() -> void:
	apply_gravity()
	recompute_vision()
	_check_game_over()
	changed.emit()

# ---------------------------------------------------------------- victory

func team_alive_count(team: int) -> int:
	var n := 0
	for u in units:
		if u.is_alive() and u.team == team:
			n += 1
	return n

func winner() -> int:
	# Only meaningful once `is_over` is true. Returns the winning team's id, or
	# -1 if both teams are out (mutual annihilation).
	var p_alive: bool = team_alive_count(TEAM_PLAYER) > 0
	var e_alive: bool = team_alive_count(TEAM_ENEMY) > 0
	if p_alive and not e_alive:
		return TEAM_PLAYER
	if e_alive and not p_alive:
		return TEAM_ENEMY
	return -1

func _check_game_over() -> void:
	if is_over:
		return
	# Losing your whole team ends the run.
	if team_alive_count(TEAM_PLAYER) == 0:
		is_over = true
		game_over.emit(TEAM_ENEMY)
		return
	# Wiping the enemy CLEARS THE AREA (campaign continues) instead of ending.
	if team_alive_count(TEAM_ENEMY) == 0 and not _area_clear_emitted:
		_area_clear_emitted = true
		if stage_in_branch == 2 and bosses_defeated.has(branch):
			bosses_defeated[branch] = true
			notice.emit("The governor of the %s has fallen!" % branch)
		notice.emit("Area %d cleared!" % area)
		area_cleared.emit(area)

# ---------------------------------------------------------------- AI

# Plays one visible AI action for `team`; returns true if anything happened.
# Iso_view calls this in a delay-paced loop so each action is watchable.
# v1 behaviour: for each non-leader unit holding a spade, find the nearest
# enemy; swing if adjacent, otherwise step toward them with move_to.
func ai_step(team: int) -> bool:
	# One visible action per call. Per-kind behaviour: wolves bite (twice) and
	# sprint, javelin throwers attack at range (boomerang spades), wizards
	# summon minions, everyone else swings + advances.
	if is_over:
		return false
	for u in units:
		if not u.is_alive() or u.team != team:
			continue
		if u.kind == "leader":
			continue                          # leaders stand still in v1
		var can_bonus: bool = (u.kind == "wolf" and not u.bonus_attack_used)
		if u.moved and u.acted and not can_bonus:
			continue
		var target = _ai_nearest_enemy(u)
		if target == null:
			continue
		var dist: int = _cheb3(u.grid, target.grid)
		# King of the Hill boss: every turn he piles earth beneath himself and
		# rides it upward — a living tower defended by javelins + ballistas.
		if u.kind == "king":
			if not u.acted and u.grid.y + 1 < world.SY:
				var stand: Vector3i = u.grid
				u.grid = stand + Vector3i(0, 1, 0)
				u.draw_pos = Vector3(u.grid.x + 0.5, float(u.grid.y), u.grid.z + 0.5)
				world.set_material(stand, VoxelWorld.Mat.EARTH)
				u.acted = true
				notice.emit("The King builds his hill higher!")
				_emit_changed()
				return true
			continue                          # the King never leaves his hill
		# The Otter: alternates launching boat-riders and bending the river.
		if u.kind == "otter":
			if not u.acted:
				if (turn % 2) == 0 and team_alive_count(team) < 9:
					for w_v in world.water_flow.keys():
						var w: Vector3i = w_v
						if unit_at(w) == null and _cheb3(w, u.grid) <= 6:
							var rider = _spawn_unit(team, w, false)
							rider.kind = "boat"
							rider.hp = 4
							rider.max_hp = 4
							u.acted = true
							notice.emit("The Otter launches a boat-rider!")
							_emit_changed()
							return true
				else:
					if _otter_extend_river(u, target):
						u.acted = true
						return true
			continue                      # the Otter holds the riverbank
		# Wizard miniboss: summon a wolf instead of fighting (capped force).
		if u.kind == "wizard":
			if not u.acted and team_alive_count(team) < 9:
				var spot: Vector3i = _free_spot_near(u.grid.x, u.grid.z)
				if unit_at(spot) == null and world.is_standable(spot):
					var minion = _spawn_unit(team, spot, false)
					minion.kind = "wolf"
					minion.hp = 4
					minion.max_hp = 4
					u.acted = true
					notice.emit("The wizard summons a wolf!")
					_emit_changed()
					return true
			continue                          # wizards don't chase
		# Melee when adjacent.
		if dist == 1 and (not u.acted or can_bonus):
			if u.spade != null and u.kind != "wolf":
				swing_at(u, target.grid)
			else:
				bite(u, target)
			return true
		# Javelin barbarians attack from range (their spade boomerangs back).
		if u.kind == "javelin" and u.spade != null and not u.acted \
				and dist > 1 and dist <= throw_range_for(u):
			throw_at(u, target.grid)
			return true
		if u.moved:
			continue
		if u.spade == null and u.kind != "wolf" and u.kind != "boat":
			continue                          # spadeless humanoids hold position
		if _adjacent_own_ballista(u):
			continue                          # gunners hold their post
		var moves: Array = move_targets(u)
		if moves.is_empty():
			continue
		var best: Vector3i = u.grid
		var best_d: int = dist
		for m: Vector3i in moves:
			var d: int = _cheb3(m, target.grid)
			if d < best_d:
				best_d = d
				best = m
		if best != u.grid:
			move_to(u, best)
			return true
	return false

# Bend the river one cell toward the Otter's prey: pick the water cell nearest
# the target and flood the best adjacent earth column. Units standing there
# get dunked by gravity on the next state change.
func _otter_extend_river(u, target) -> bool:
	if target == null:
		return false
	var best_w := Vector3i(-9999, 0, 0)
	var best_d: int = 99999
	for w_v in world.water_flow.keys():
		var w: Vector3i = w_v
		var d: int = _cheb3(w, target.grid)
		if d < best_d:
			best_d = d
			best_w = w
	if best_w.x == -9999:
		return false
	var best_n := Vector3i(-9999, 0, 0)
	var best_nd: int = 99999
	for d in DIRS:
		var n: Vector3i = best_w + d
		if not world.in_bounds(n):
			continue
		if world.material_at(n) != VoxelWorld.Mat.EARTH:
			continue
		var nd: int = _cheb3(n, target.grid)
		if nd < best_nd:
			best_nd = nd
			best_n = n
	if best_n.x == -9999:
		return false
	world.set_material(best_n, VoxelWorld.Mat.WATER)
	world.water_flow[best_n] = best_n - best_w
	notice.emit("The Otter bends the river!")
	_emit_changed()
	return true

func _adjacent_own_ballista(u) -> bool:
	for b in ballistas:
		if int(b["team"]) == u.team and _cheb3(u.grid, b["grid"]) == 1:
			return true
	return false

func _ai_nearest_enemy(u):
	var best = null
	var best_d: int = 99999
	for o in units:
		if o.is_alive() and o.team != u.team:
			var d: int = _cheb3(u.grid, o.grid)
			if d < best_d:
				best_d = d
				best = o
	return best

# Drop every unit whose tile has no solid floor; 1 dmg per cell fallen. Lands
# on solid ground, the world floor (y=0), or atop another unit (no pile-ups).
func apply_gravity() -> void:
	for u in units.duplicate():
		if not u.is_alive():
			continue
		# Hanging on a ladder — no fall.
		if world.material_at(u.grid) == VoxelWorld.Mat.LADDER:
			continue
		var fall_dist := 0
		while u.grid.y > 0:
			var below: Vector3i = u.grid + DOWN
			if world.is_solid(below):
				break
			if unit_at(below) != null and unit_at(below) != u:
				break
			u.grid = below
			fall_dist += 1
		if fall_dist > 0:
			# Snap the visual to the landing spot — falls aren't animated for now.
			u.draw_pos = Vector3(u.grid.x + 0.5, float(u.grid.y), u.grid.z + 0.5)
			notice.emit("%s fell %d cell%s!" % [u.kind.capitalize(), fall_dist, "" if fall_dist == 1 else "s"])
			_damage(u, fall_dist)

# ---------------------------------------------------------------- vision

func recompute_vision() -> void:
	if world == null:
		return
	# Skip the (expensive) Bresenham sweep when neither the terrain nor any
	# friendly unit position has changed since the last recompute.
	var key: String = str(world.version)
	for u in units:
		if u.team == 0 and u.is_alive():
			key += "|%d,%d,%d" % [u.grid.x, u.grid.y, u.grid.z]
	if key == _vision_key:
		return
	_vision_key = key
	for u in units:
		if u.team != 0 or not u.is_alive():
			continue
		_reveal_from(u)

func _reveal_from(u) -> void:
	# A friendly unit reveals every cell on its own y-plane reachable by an
	# unobstructed 2D ray (Bresenham), plus the cube directly below each
	# revealed air cell (the visible floor — solid earth OR water in a trench).
	var y: int = u.grid.y
	for tx in world.SX:
		for tz in world.SZ:
			if not _xz_los(u.grid.x, u.grid.z, tx, tz, y):
				continue
			var here := Vector3i(tx, y, tz)
			seen[here] = true
			var below := Vector3i(tx, y - 1, tz)
			if world.material_at(below) != VoxelWorld.Mat.AIR:
				seen[below] = true

# Returns true iff the 2D segment from (sx,sz) to (tx,tz) at y has no solid
# cell strictly between the endpoints.
func _xz_los(sx: int, sz: int, tx: int, tz: int, y: int) -> bool:
	var line := _bresenham_xz(sx, sz, tx, tz)
	for i in range(1, line.size() - 1):
		var p: Vector2i = line[i]
		if world.is_solid(Vector3i(p.x, y, p.y)):
			return false
	return true

func _bresenham_xz(x0: int, z0: int, x1: int, z1: int) -> Array:
	var out := [Vector2i(x0, z0)]
	var dx: int = absi(x1 - x0)
	var dz: int = absi(z1 - z0)
	var sx: int = 1 if x0 < x1 else -1
	var sz: int = 1 if z0 < z1 else -1
	var err: int = dx - dz
	var x := x0
	var z := z0
	while x != x1 or z != z1:
		var e2: int = 2 * err
		if e2 > -dz:
			err -= dz
			x += sx
		if e2 < dx:
			err += dx
			z += sz
		out.append(Vector2i(x, z))
	return out

# Starter deck is deliberately MINIMAL — 3 operators + 3 spades. Power comes
# from the Build Bar (materials) and from the upgrade-choice card that appears
# every time the deck cycles (see _reshuffle_with_upgrade / CHOICE_POOL).
func _build_deck() -> void:
	draw_pile.clear()
	hand.clear()
	discard.clear()
	for i in 3:
		draw_pile.append(_make_card("operator", "Operator", 2, "unit", "place adjacent"))
	for i in 3:
		draw_pile.append(_make_card("spade", "Spade", 1, "spade", "give to operator"))
	draw_pile.shuffle()

# Reshuffle the discard into the draw pile; every completed cycle of the deck
# also surfaces ONE upgrade-choice card as the next draw — the run-progression
# beat ("pick 1 of 3").
func _reshuffle_with_upgrade() -> void:
	draw_pile = discard.duplicate()
	discard.clear()
	draw_pile.shuffle()
	if not draw_pile.is_empty():
		draw_pile.append(_make_card("upgrade_choice", "UPGRADE", 0, "choice", "pick 1 of 3"))

# ---------------------------------------------------------------- Build Bar
# Mid-game card acquisition: spend banked wood / oil to put a card straight
# into your hand. The progression arc — simple starter deck, then materials
# unlock structures (ladder / bridge) and advanced upgrades.
const BLUEPRINTS := [
	{"id": "ladder",  "wood": 2, "oil": 0},
	{"id": "bridge",  "wood": 3, "oil": 0},
	{"id": "ballista", "wood": 3, "oil": 0},
	{"id": "dirt_wall", "wood": 0, "oil": 0, "earth": 2},
	{"id": "waterwheel", "wood": 3, "oil": 0},
	{"id": "storehouse", "wood": 5, "oil": 0},
	{"id": "village", "wood": 2, "oil": 0, "earth": 3},
	{"id": "trebuchet", "wood": 10, "oil": 0},
	{"id": "farm", "wood": 1, "oil": 0, "earth": 4},
	{"id": "campsite", "wood": 0, "oil": 0, "earth": 1, "stone": 1},
	{"id": "barracks", "wood": 8, "oil": 0},
	{"id": "fishing_pole", "wood": 1, "oil": 0},
	{"id": "boat", "wood": 3, "oil": 0},
	{"id": "spade_wings",            "wood": 2, "oil": 0},
	{"id": "spade_dousing_rod",      "wood": 2, "oil": 0},
	{"id": "double_barrel_spade",    "wood": 2, "oil": 0},
	{"id": "spade_laser_rangefinder","wood": 2, "oil": 0},
	{"id": "spade_boomerang",        "wood": 1, "oil": 1},
	{"id": "spade_propulsion",       "wood": 1, "oil": 1},
	{"id": "spade_trigger",          "wood": 1, "oil": 1},
	{"id": "spade_warhead",          "wood": 0, "oil": 2},
	{"id": "spade_metal_detector",   "wood": 0, "oil": 2},
	{"id": "spade_earthquake",       "wood": 0, "oil": 2},
	{"id": "spade_grappling_hook",   "wood": 0, "oil": 2},
	{"id": "spade_pogostick",        "wood": 0, "oil": 2},
	{"id": "strength",  "wood": 1, "oil": 1},
	{"id": "endurance", "wood": 1, "oil": 1},
	{"id": "hand_eye",  "wood": 1, "oil": 1},
	{"id": "dual_wield","wood": 2, "oil": 2},
]
const STRUCTURES := {
	"ladder": {"title": "Ladder", "cost": 1, "blurb": "climb walls"},
	"bridge": {"title": "Bridge", "cost": 1, "blurb": "cross water"},
	"ballista": {"title": "Ballista", "cost": 1, "blurb": "manned: fires r3, 2 dmg"},
	"dirt_wall": {"title": "Dirt Wall", "cost": 1, "blurb": "raise an earth block"},
	"waterwheel": {"title": "Waterwheel", "cost": 1, "blurb": "+1 energy/turn (needs river)"},
	"storehouse": {"title": "Storehouse", "cost": 1, "blurb": "+1 hand size"},
	"village": {"title": "Village", "cost": 1, "blurb": "spawns operator / 2 turns"},
	"trebuchet": {"title": "Trebuchet", "cost": 1, "blurb": "3 crew: AOE + levels walls"},
	"farm": {"title": "Farm", "cost": 1, "blurb": "+1 food card / 2 turns"},
	"campsite": {"title": "Campsite", "cost": 1, "blurb": "food becomes cooked (+1 heal)"},
	"barracks": {"title": "Barracks", "cost": 1, "blurb": "warriors +1 dmg"},
	"boat": {"title": "Boat", "cost": 1, "blurb": "water-only, huge movement"},
}
# Buildings that live in the `buildings` registry (Mat.BUILDING cells).
const REGISTERED_BUILDINGS := ["waterwheel", "storehouse", "village", "trebuchet",
		"farm", "campsite", "barracks"]

func blueprint_card_title(id: String) -> String:
	if STRUCTURES.has(id):
		return String(STRUCTURES[id]["title"])
	return String(UPGRADES.get(id, {}).get("title", id))

func can_afford_blueprint(bp: Dictionary) -> bool:
	return wood[TEAM_PLAYER] >= int(bp["wood"]) and oil[TEAM_PLAYER] >= int(bp["oil"]) \
			and earth[TEAM_PLAYER] >= int(bp.get("earth", 0)) \
			and stone[TEAM_PLAYER] >= int(bp.get("stone", 0))

func buy_blueprint(id: String) -> bool:
	if is_over or active_team != TEAM_PLAYER:
		return false
	var bp: Dictionary = {}
	for b in BLUEPRINTS:
		if b["id"] == id:
			bp = b
			break
	if bp.is_empty():
		return false
	if not can_afford_blueprint(bp):
		notice.emit("Need %dw %do for %s." % [int(bp["wood"]), int(bp["oil"]), blueprint_card_title(id)])
		return false
	wood[TEAM_PLAYER] -= int(bp["wood"])
	oil[TEAM_PLAYER] -= int(bp["oil"])
	earth[TEAM_PLAYER] -= int(bp.get("earth", 0))
	stone[TEAM_PLAYER] -= int(bp.get("stone", 0))
	var card: Dictionary
	if STRUCTURES.has(id):
		var s: Dictionary = STRUCTURES[id]
		card = _make_card(id, s["title"], s["cost"], "structure", s["blurb"])
	else:
		var u: Dictionary = UPGRADES[id]
		card = _make_card(id, u["title"], u["cost"], u["category"], u["blurb"])
	# Construction-material purchases EXHAUST when played (one building per
	# buy). Voluntarily discarding them still cycles them through the deck.
	card["bought"] = true
	hand.append(card)
	cards_drawn.emit(1)
	notice.emit("Built %s — added to hand." % card["title"])
	_emit_changed()
	return true

# ---------------------------------------------------------------- structures

# Valid placement cells for a structure card. Built by any friendly unit:
# within Chebyshev 1 of one. Ladder mounts an air cell that touches a solid
# wall horizontally (or stacks on a ladder below). Bridge planks an air cell
# directly above water.
func structure_targets(card) -> Array:
	var out: Array = []
	if card == null:
		return out
	var id: String = String(card["id"])
	var seen_cells: Dictionary = {}
	for u in units:
		if not u.is_alive() or u.team != TEAM_PLAYER:
			continue
		if u.kind == "javelin":
			continue          # javelin throwers can't build
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					var p: Vector3i = u.grid + Vector3i(dx, dy, dz)
					if seen_cells.has(p) or not world.in_bounds(p):
						continue
					seen_cells[p] = true
					if unit_at(p) != null:
						continue
					if not world.is_air(p) and not (id == "boat" and world.is_water(p)):
						continue
					if id == "ladder":
						if _ladder_mountable(p):
							out.append(p)
					elif id == "bridge":
						if world.is_water(p + DOWN):
							out.append(p)
					elif id == "waterwheel":
						# Must hug flowing water: ground cell with a water neighbour.
						if world.is_solid(p + DOWN) and _adjacent_to_water(p):
							out.append(p)
					elif id == "boat":
						# Boats launch ONTO a water cell.
						if world.is_water(p):
							out.append(p)
					elif id == "ballista" or id == "dirt_wall" or id in REGISTERED_BUILDINGS:
						# Needs solid ground under it.
						if world.is_solid(p + DOWN):
							out.append(p)
	return out

func _adjacent_to_water(p: Vector3i) -> bool:
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				if world.is_water(p + Vector3i(dx, dy, dz)):
					return true
	return false

func _ladder_mountable(p: Vector3i) -> bool:
	for d in DIRS:
		if world.is_solid(p + d):
			return true
	return world.material_at(p + DOWN) == VoxelWorld.Mat.LADDER

func play_structure_at(card, cell: Vector3i) -> bool:
	if card == null or not hand.has(card):
		return false
	if not structure_targets(card).has(cell):
		notice.emit("Can't build there.")
		return false
	if not _spend(int(card["cost"])):
		return false
	var id: String = String(card["id"])
	if id == "ladder":
		world.set_material(cell, VoxelWorld.Mat.LADDER)
		notice.emit("Ladder built.")
	elif id == "bridge":
		world.set_material(cell, VoxelWorld.Mat.BRIDGE)
		notice.emit("Bridge built.")
	elif id == "ballista":
		world.set_material(cell, VoxelWorld.Mat.BALLISTA)
		ballistas.append({"grid": cell, "team": TEAM_PLAYER})
		notice.emit("Ballista built — fires automatically each turn.")
	elif id == "dirt_wall":
		world.set_material(cell, VoxelWorld.Mat.EARTH)
		notice.emit("Dirt wall raised.")
	elif id == "boat":
		var boat = _spawn_unit(TEAM_PLAYER, cell, false)
		boat.kind = "boat"
		boat.hp = 6
		boat.max_hp = 6
		notice.emit("Boat launched.")
	elif id in REGISTERED_BUILDINGS:
		world.set_material(cell, VoxelWorld.Mat.BUILDING)
		buildings[cell] = {"kind": id, "team": TEAM_PLAYER, "timer": 2}
		notice.emit("%s built." % STRUCTURES[id]["title"])
		if id == "campsite":
			_cook_all_food()
	_consume_played(card)
	_emit_changed()
	return true

# Remove a just-played card from the hand. Blueprint-bought cards exhaust
# (leave the game); everything else cycles into the discard pile.
func _consume_played(card) -> void:
	hand.erase(card)
	if not bool(card.get("bought", false)):
		discard.append(card)

# ---------------------------------------------------------------- areas / campaign

# Special unit cards offered on area clear (pick 1 of 3).
const SPECIAL_UNITS := {
	"warrior": {"title": "Warrior", "cost": 2, "blurb": "+2 dmg; can't dig/chop"},
	"javelin": {"title": "Javelin Thrower", "cost": 2, "blurb": "throw range +4; can't build"},
	"plow": {"title": "Plow", "cost": 3, "blurb": "levels a 3-wide path as it moves"},
}

func grant_special(id: String) -> void:
	if not SPECIAL_UNITS.has(id):
		return
	var s: Dictionary = SPECIAL_UNITS[id]
	hand.append(_make_card(id, s["title"], s["cost"], "unit", s["blurb"]))
	notice.emit("%s card added to your hand." % s["title"])
	_emit_changed()

# Move the run into the next area: fresh (harder) map, surviving player units
# carry over to the near corner, fog resets, enemies scale with area number.
# `direction` ("top_left" / "top_right") is recorded flavour for now.
func advance_area(direction: String) -> void:
	# direction: "hills" / "riverlands" / "flud".
	if direction == branch and stage_in_branch == 1:
		stage_in_branch = 2              # deeper in: the governor awaits
	elif direction == "flud":
		branch = "flud"
		stage_in_branch = 2
	else:
		branch = direction
		stage_in_branch = 1
	area += 1
	_area_clear_emitted = false
	dropped.clear()
	ballistas.clear()
	buildings.clear()
	pending_card_cleanup()
	world.generate()
	world.version += 1
	world.cells_changed.emit()
	seen.clear()
	_vision_key = ""
	# Carry survivors; everything else despawns with the old area.
	var survivors: Array = []
	for u in units:
		if u.is_alive() and u.team == TEAM_PLAYER:
			u.task = {}
			survivors.append(u)
	units = survivors
	var corner_x: int = world.SX - 3
	var corner_z: int = world.SZ - 3
	for i in survivors.size():
		var u = survivors[i]
		u.grid = _free_spot_near(corner_x, corner_z)
		u.draw_pos = Vector3(u.grid.x + 0.5, float(u.grid.y), u.grid.z + 0.5)
	# Enemy force scales with the area number (wizard miniboss on even areas).
	_spawn_enemy_force()
	active_team = TEAM_PLAYER
	notice.emit("Entered area %d (%s). The enemy grows stronger…" % [area, direction])
	begin_turn()

# First unoccupied standable surface cell spiralling out from (x, z).
func _free_spot_near(x: int, z: int) -> Vector3i:
	for r in range(0, 6):
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				var cx: int = clampi(x + dx, 0, world.SX - 1)
				var cz: int = clampi(z + dz, 0, world.SZ - 1)
				var p: Vector3i = world.surface_cell(cx, cz)
				if world.is_standable(p) and unit_at(p) == null:
					return p
	return world.surface_cell(x, z)

# Drop any in-flight UI card refs that no longer make sense across areas.
func pending_card_cleanup() -> void:
	pass    # hook for future cross-area cleanup

# ---------------------------------------------------------------- upgrade choices
# Drawn when the deck cycles; playing one shows 3 of these. "passive" picks
# apply immediately and exhaust; "card" picks add a reusable ritual card.
const CHOICE_POOL := [
	{"id": "swift_ops", "kind": "passive", "title": "Swift Operators",
		"desc": "Operators move 2x per turn (exhaust)"},
	{"id": "lumber_bonus", "kind": "passive", "title": "Efficient Lumber",
		"desc": "+1 wood per tree cell chopped (exhaust)"},
	{"id": "plant_grove", "kind": "card", "title": "Plant Grove",
		"desc": "Spawn trees in an area (retain)"},
	{"id": "mass_excavation", "kind": "card", "title": "Mass Excavation",
		"desc": "Dig 5 tiles down one level (retain)"},
]

func choice_options() -> Array:
	var pool: Array = []
	for o in CHOICE_POOL:
		if o["kind"] == "passive" and passives.has(o["id"]):
			continue              # already owned — don't offer again
		pool.append(o)
	pool.shuffle()
	return pool.slice(0, mini(3, pool.size()))

func apply_choice(card, option: Dictionary) -> void:
	if card == null or not hand.has(card):
		return
	hand.erase(card)              # the choice card itself always exhausts
	match String(option["kind"]):
		"passive":
			passives[String(option["id"])] = true
			notice.emit("Gained: %s" % option["title"])
		"card":
			hand.append(_make_card(String(option["id"]), String(option["title"]),
					1, "ritual", String(option["desc"])))
			notice.emit("%s added to your hand." % option["title"])
	_emit_changed()

# ---------------------------------------------------------------- magic cards
# Miniboss (wizard) rewards. All "ritual" category; ancestors/descendents are
# instant (no target).
const MAGIC_POOL := [
	{"id": "raise_earth", "title": "Raise Earth", "cost": 2,
		"blurb": "lift a 3x3 area +1"},
	{"id": "lower_earth", "title": "Lower Earth", "cost": 2,
		"blurb": "sink a 3x3 area -1"},
	{"id": "call_ancestors", "title": "Call Ancestors", "cost": 1,
		"blurb": "pull a card from discard"},
	{"id": "call_descendents", "title": "Call Descendents", "cost": 1,
		"blurb": "pull a card from draw pile"},
	{"id": "convert_opponent", "title": "Convert Opponent", "cost": 4,
		"blurb": "control an enemy for 2 turns"},
	{"id": "call_lightning", "title": "Call Lightning", "cost": 6,
		"blurb": "5 dmg to any enemy"},
]
const INSTANT_MAGIC := ["call_ancestors", "call_descendents"]

func magic_options() -> Array:
	var pool: Array = MAGIC_POOL.duplicate()
	pool.shuffle()
	return pool.slice(0, 3)

func grant_magic(option: Dictionary) -> void:
	hand.append(_make_card(String(option["id"]), String(option["title"]),
			int(option["cost"]), "ritual", String(option["blurb"])))
	notice.emit("%s added to your hand." % option["title"])
	_emit_changed()

# Instant rituals — play on click, no targeting.
func play_instant(card) -> bool:
	if card == null or not hand.has(card):
		return false
	match String(card["id"]):
		"call_ancestors":
			if discard.is_empty():
				notice.emit("Your discard pile is empty.")
				return false
			if not _spend(int(card["cost"])):
				return false
			var pick = discard[randi() % discard.size()]
			discard.erase(pick)
			hand.append(pick)
			cards_drawn.emit(1)
			notice.emit("The ancestors return %s to your hand." % pick["title"])
		"call_descendents":
			if draw_pile.is_empty():
				notice.emit("Your draw pile is empty.")
				return false
			if not _spend(int(card["cost"])):
				return false
			var pick2 = draw_pile[randi() % draw_pile.size()]
			draw_pile.erase(pick2)
			hand.append(pick2)
			cards_drawn.emit(1)
			notice.emit("The descendents bring %s to your hand." % pick2["title"])
		_:
			return false
	hand.erase(card)
	discard.append(card)      # retain
	_emit_changed()
	return true

# ---------------------------------------------------------------- ritual cards

# Targets: standable surface cells within Chebyshev 3 (xz) of a friendly unit.
# Convert Opponent instead targets enemy units within Chebyshev 4 of one.
func ritual_targets(card) -> Array:
	var out: Array = []
	if card == null:
		return out
	# Food heals any friendly unit; lightning strikes any visible enemy.
	if String(card["id"]) in ["food", "cooked_food"]:
		for u in units:
			if u.is_alive() and u.team == TEAM_PLAYER:
				out.append(u.grid)
		return out
	if String(card["id"]) == "call_lightning":
		for e in units:
			if e.is_alive() and e.team == TEAM_ENEMY:
				out.append(e.grid)
		return out
	if String(card["id"]) == "convert_opponent":
		for e in units:
			if not e.is_alive() or e.team != TEAM_ENEMY:
				continue
			for u in units:
				if u.is_alive() and u.team == TEAM_PLAYER and _cheb3(u.grid, e.grid) <= 4:
					out.append(e.grid)
					break
		return out
	var seen_c: Dictionary = {}
	for u in units:
		if not u.is_alive() or u.team != TEAM_PLAYER:
			continue
		for dx in range(-3, 4):
			for dz in range(-3, 4):
				var cx: int = u.grid.x + dx
				var cz: int = u.grid.z + dz
				if cx < 0 or cx >= world.SX or cz < 0 or cz >= world.SZ:
					continue
				var p: Vector3i = world.surface_cell(cx, cz)
				if not seen_c.has(p):
					seen_c[p] = true
					out.append(p)
	return out

func play_ritual_at(card, cell: Vector3i) -> bool:
	if card == null or not hand.has(card):
		return false
	if not ritual_targets(card).has(cell):
		notice.emit("Out of range for %s." % card["title"])
		return false
	if not _spend(int(card["cost"])):
		return false
	match String(card["id"]):
		"plant_grove":
			var planted: int = 0
			var spots: Array = []
			for dx in range(-1, 2):
				for dz in range(-1, 2):
					spots.append(Vector2i(cell.x + dx, cell.z + dz))
			spots.shuffle()
			for s in spots:
				if planted >= 5:
					break
				if s.x < 0 or s.x >= world.SX or s.y < 0 or s.y >= world.SZ:
					continue
				var base: Vector3i = world.surface_cell(s.x, s.y)
				if not world.is_air(base) or unit_at(base) != null:
					continue
				var fits: bool = true
				for dy in VoxelWorld.TREE_HEIGHT:
					var tp: Vector3i = base + Vector3i(0, dy, 0)
					if not world.in_bounds(tp) or world.cells.has(tp):
						fits = false
						break
				if not fits:
					continue
				for dy in VoxelWorld.TREE_HEIGHT:
					world.set_material(base + Vector3i(0, dy, 0), VoxelWorld.Mat.TREE)
				planted += 1
			notice.emit("Grove planted — %d tree(s)." % planted)
		"mass_excavation":
			var dug: int = 0
			for d in [Vector3i.ZERO, Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
				var cx: int = cell.x + d.x
				var cz: int = cell.z + d.z
				if cx < 0 or cx >= world.SX or cz < 0 or cz >= world.SZ:
					continue
				for y in range(world.SY - 1, -1, -1):
					var p := Vector3i(cx, y, cz)
					if world.is_solid(p):
						_treasure_reward(world.dig_cell(p), p)
						dug += 1
						break
			notice.emit("Excavated %d tile(s)." % dug)
		"raise_earth":
			var raised: int = 0
			for dx in range(-1, 2):
				for dz in range(-1, 2):
					var cx: int = cell.x + dx
					var cz: int = cell.z + dz
					if cx < 0 or cx >= world.SX or cz < 0 or cz >= world.SZ:
						continue
					# Top solid of the column grows by one block.
					for y in range(world.SY - 1, -1, -1):
						var p := Vector3i(cx, y, cz)
						if not world.is_solid(p):
							continue
						var above := Vector3i(cx, y + 1, cz)
						if above.y >= world.SY:
							break
						# A unit standing there rides the new block up.
						var rider = unit_at(above)
						if rider != null:
							if above.y + 1 >= world.SY:
								break
							rider.grid = above + Vector3i(0, 1, 0)
							rider.draw_pos = Vector3(rider.grid.x + 0.5, float(rider.grid.y), rider.grid.z + 0.5)
						world.set_material(above, VoxelWorld.Mat.EARTH)
						raised += 1
						break
			notice.emit("The earth rises — %d column(s) lifted." % raised)
		"lower_earth":
			var sunk: int = 0
			for dx in range(-1, 2):
				for dz in range(-1, 2):
					var cx: int = cell.x + dx
					var cz: int = cell.z + dz
					if cx < 0 or cx >= world.SX or cz < 0 or cz >= world.SZ:
						continue
					for y in range(world.SY - 1, -1, -1):
						var p := Vector3i(cx, y, cz)
						if world.is_solid(p):
							world.dig_cell(p)   # magic destroys, no materials
							sunk += 1
							break
			notice.emit("The earth sinks — %d column(s) lowered." % sunk)
		"food", "cooked_food":
			var ally = unit_at(cell)
			if ally == null or ally.team != TEAM_PLAYER:
				notice.emit("No friendly unit there.")
				return false
			var heal: int = 2 if String(card["id"]) == "cooked_food" else 1
			ally.hp = mini(ally.max_hp, ally.hp + heal)
			notice.emit("%s heals %d hp." % [ally.kind.capitalize(), heal])
			hand.erase(card)      # consumed — food exhausts, no discard
			_emit_changed()
			return true
		"call_lightning":
			var victim2 = unit_at(cell)
			if victim2 == null or victim2.team != TEAM_ENEMY:
				notice.emit("No enemy there.")
				return false
			spade_thrown.emit(Vector3i(cell.x, world.SY - 1, cell.z), cell, false)
			_damage(victim2, 5)
			notice.emit("LIGHTNING strikes for 5!")
		"convert_opponent":
			var victim = unit_at(cell)
			if victim == null or victim.team != TEAM_ENEMY:
				notice.emit("No enemy there to convert.")
				return false
			if victim.kind in ["king", "otter", "wizard"]:
				notice.emit("%s is too strong-willed to convert!" % victim.kind.capitalize())
				return false
			victim.team = TEAM_PLAYER
			victim.converted_turns = 2
			victim.moved = false
			victim.acted = false
			notice.emit("%s fights for YOU for 2 turns!" % victim.kind.capitalize())
	hand.erase(card)
	discard.append(card)          # retain: cycles back through the deck
	_emit_changed()
	return true

# ---------------------------------------------------------------- ballistas

# A ballista is manned when a same-team unit stands within Chebyshev 1 of it
# (beside it or on top). Manning is passive — it costs no action.
func is_ballista_manned(b: Dictionary) -> bool:
	var g: Vector3i = b["grid"]
	for u in units:
		if u.is_alive() and u.team == int(b["team"]) and _cheb3(u.grid, g) == 1:
			return true
	return false

# Fire every MANNED ballista belonging to `team`: nearest enemy within
# Chebyshev 3 takes 2 damage. Called at end of that team's turn.
func _fire_ballistas(team: int) -> void:
	for b in ballistas.duplicate():
		var g: Vector3i = b["grid"]
		if world.material_at(g) != VoxelWorld.Mat.BALLISTA:
			ballistas.erase(b)    # demolished
			continue
		if int(b["team"]) != team:
			continue
		if not is_ballista_manned(b):
			continue              # no crew, no shot
		var best = null
		var best_d: int = 99
		for u in units:
			if u.is_alive() and u.team != team:
				var d: int = _cheb3(g, u.grid)
				if d <= 3 and d < best_d:
					best_d = d
					best = u
		if best != null:
			spade_thrown.emit(g, best.grid, false)   # reuse the projectile arc
			_damage(best, 2)
			notice.emit("Ballista fires — 2 dmg!")

# ---------------------------------------------------------------- buildings

func _count_buildings(team: int, kind: String) -> int:
	var n := 0
	for cell in buildings:
		var b: Dictionary = buildings[cell]
		if int(b["team"]) == team and String(b["kind"]) == kind \
				and world.material_at(cell) == VoxelWorld.Mat.BUILDING:
			n += 1
	return n

# Per-player-turn building effects. Also prunes demolished entries.
func _tick_buildings() -> void:
	for cell in buildings.keys().duplicate():
		if world.material_at(cell) != VoxelWorld.Mat.BUILDING:
			buildings.erase(cell)
			continue
		var b: Dictionary = buildings[cell]
		if int(b["team"]) != TEAM_PLAYER:
			continue
		match String(b["kind"]):
			"waterwheel":
				# Only spins beside live water.
				if _adjacent_to_water(cell):
					energy += 1
					notice.emit("Waterwheel: +1 energy.")
			"village":
				b["timer"] = int(b["timer"]) - 1
				if int(b["timer"]) <= 0:
					b["timer"] = 2
					var spot: Vector3i = _free_spot_near(cell.x, cell.z)
					if world.is_standable(spot) and unit_at(spot) == null:
						var op = _spawn_unit(TEAM_PLAYER, spot, false)
						op.kind = "operator"
						notice.emit("The village raises a new operator.")
			"farm":
				b["timer"] = int(b["timer"]) - 1
				if int(b["timer"]) <= 0:
					b["timer"] = 2
					hand.append(_make_food_card(_count_buildings(TEAM_PLAYER, "campsite") > 0))
					cards_drawn.emit(1)
					notice.emit("Harvest! A food card joins your hand.")
			"campsite":
				_cook_all_food()

func _make_food_card(cooked: bool) -> Dictionary:
	if cooked:
		return _make_card("cooked_food", "Cooked Food", 0, "ritual", "heal a unit +2")
	return _make_card("food", "Food", 0, "ritual", "heal a unit +1")

# Campsite: every raw food card anywhere in the deck becomes cooked food.
func _cook_all_food() -> void:
	var cooked: int = 0
	for pile in [hand, draw_pile, discard]:
		for c in pile:
			if String(c["id"]) == "food":
				c["id"] = "cooked_food"
				c["title"] = "Cooked Food"
				c["blurb"] = "heal a unit +2"
				cooked += 1
	if cooked > 0:
		notice.emit("Campsite cooks %d food card(s)." % cooked)

# Trebuchets need a 3-unit crew within Chebyshev 1. They lob at the nearest
# enemy within range 5: 3 AOE damage to enemies within r1 of the impact, and
# the 3x3 columns around it are levelled one block.
func _fire_trebuchets(team: int) -> void:
	for cell in buildings.keys().duplicate():
		var b: Dictionary = buildings[cell]
		if String(b["kind"]) != "trebuchet" or int(b["team"]) != team:
			continue
		if world.material_at(cell) != VoxelWorld.Mat.BUILDING:
			buildings.erase(cell)
			continue
		var crew: int = 0
		for u in units:
			if u.is_alive() and u.team == team and _cheb3(u.grid, cell) == 1:
				crew += 1
		if crew < 3:
			continue
		var best = null
		var best_d: int = 99
		for u in units:
			if u.is_alive() and u.team != team:
				var d: int = _cheb3(cell, u.grid)
				if d <= 5 and d < best_d:
					best_d = d
					best = u
		if best == null:
			continue
		var impact: Vector3i = best.grid
		spade_thrown.emit(cell, impact, false)
		for u in units.duplicate():
			if u.is_alive() and u.team != team and _cheb3(u.grid, impact) <= 1:
				_damage(u, 3)
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var cx: int = impact.x + dx
				var cz: int = impact.z + dz
				if cx < 0 or cx >= world.SX or cz < 0 or cz >= world.SZ:
					continue
				for y in range(world.SY - 1, -1, -1):
					var p := Vector3i(cx, y, cz)
					if world.is_solid(p):
						world.dig_cell(p)
						break
		notice.emit("TREBUCHET strike — 3 AOE dmg, walls levelled!")

# Fishing: a unit with a fishing pole next to water reels in a food card.
func fish(u) -> void:
	if u == null or not u.has_fishing_pole:
		notice.emit("Needs a fishing pole.")
		return
	if not _adjacent_to_water(u.grid):
		notice.emit("No water within reach.")
		return
	if not _consume_action(u):
		return
	hand.append(_make_food_card(_count_buildings(TEAM_PLAYER, "campsite") > 0))
	cards_drawn.emit(1)
	notice.emit("Caught something — food card added.")
	_emit_changed()

# ---------------------------------------------------------------- worker tasks

# All cells of the tree column containing `tree_cell` (walks to the base first).
func tree_column_cells(tree_cell: Vector3i) -> Array:
	var cells_out: Array = []
	var base: Vector3i = tree_cell
	if world.material_at(base) != VoxelWorld.Mat.TREE:
		return cells_out
	while world.material_at(base + DOWN) == VoxelWorld.Mat.TREE:
		base += DOWN
	var p: Vector3i = base
	while world.material_at(p) == VoxelWorld.Mat.TREE:
		cells_out.append(p)
		p += Vector3i(0, 1, 0)
	return cells_out

# Standable cells from which a swing reaches some cell of the tree column.
func _chop_positions(tree_cell: Vector3i) -> Dictionary:
	var out: Dictionary = {}
	for tc in tree_column_cells(tree_cell):
		for d in DIRS:
			var p: Vector3i = tc + d
			if world.is_standable(p):
				out[p] = true
	return out

# Multi-source BFS distance field flowing OUT from the goal cells over
# standable terrain (ignores unit occupancy — it's an estimate).
func _dist_field_to(goals: Dictionary) -> Dictionary:
	var dist: Dictionary = {}
	var queue: Array = []
	for g in goals.keys():
		dist[g] = 0
		queue.append(g)
	while not queue.is_empty():
		var cur: Vector3i = queue.pop_front()
		for d in DIRS:
			for dy in [0, 1, -1]:
				var np: Vector3i = cur + d + Vector3i(0, dy, 0)
				if dist.has(np) or not world.is_standable(np):
					continue
				dist[np] = int(dist[cur]) + 1
				queue.append(np)
	return dist

func harvest_steps(u, tree_cell: Vector3i) -> int:
	var goals: Dictionary = _chop_positions(tree_cell)
	if goals.is_empty():
		return -1
	if goals.has(u.grid):
		return 0
	var field: Dictionary = _dist_field_to(goals)
	return int(field.get(u.grid, -1))

# Estimated player-turns to walk there and chop (chop happens on the arrival
# turn since move and action are separate budgets).
func harvest_turns(u, tree_cell: Vector3i) -> int:
	var steps: int = harvest_steps(u, tree_cell)
	if steps < 0:
		return -1
	return maxi(1, int(ceil(float(steps) / float(move_range_for(u)))))

func assign_harvest(u, tree_cell: Vector3i) -> void:
	if u == null or u.spade == null:
		notice.emit("Needs a spade to harvest.")
		return
	if u.kind == "warrior" or u.kind == "plow":
		notice.emit("%s can't fell trees." % u.kind.capitalize())
		return
	u.task = {"type": "harvest", "target": tree_cell}
	notice.emit("Harvest assigned (~%d turn(s))." % harvest_turns(u, tree_cell))
	_run_unit_task(u)             # start working right now
	_emit_changed()

func _run_tasks(team: int) -> void:
	for u in units.duplicate():
		if u.is_alive() and u.team == team and not u.task.is_empty():
			_run_unit_task(u)

func _run_unit_task(u) -> void:
	if String(u.task.get("type", "")) != "harvest":
		return
	var target: Vector3i = u.task["target"]
	var col: Array = tree_column_cells(target)
	if col.is_empty():
		u.task = {}
		notice.emit("Harvest target is gone — task cleared.")
		return
	if _try_chop_adjacent(u, col):
		return
	# Walk toward the tree along the distance field, then try chopping again.
	if not u.moved:
		var field: Dictionary = _dist_field_to(_chop_positions(target))
		var best: Vector3i = u.grid
		var best_d: int = int(field.get(u.grid, 99999))
		for m in move_targets(u):
			var d: int = int(field.get(m, 99999))
			if d < best_d:
				best_d = d
				best = m
		if best != u.grid:
			move_to(u, best)
	_try_chop_adjacent(u, tree_column_cells(target))

# Swing at the column if a cell is cardinally adjacent at the unit's level.
# Returns true (and clears the task) when the chop lands.
func _try_chop_adjacent(u, col: Array) -> bool:
	if u.acted or u.spade == null:
		return false
	for tc in col:
		if (tc - u.grid) in DIRS:
			swing_at(u, tc)
			u.task = {}
			return true
	return false

func _make_card(id: String, title: String, cost: int, category: String, blurb: String) -> Dictionary:
	_next_card_instance += 1
	return {
		"id": id, "title": title, "cost": cost,
		"category": category, "blurb": blurb,
		"instance": _next_card_instance,    # disambiguates otherwise-identical cards
	}

func _spawn_unit(team: int, p: Vector3i, give_spade: bool):
	var u := Unit.new()
	u.team = team
	u.grid = p
	u.draw_pos = Vector3(p.x + 0.5, float(p.y), p.z + 0.5)
	u.facing = DIRS[0]
	units.append(u)
	if give_spade:
		var s := Spade.new()
		s.owner = u
		u.spade = s
	return u

# Reset every unit on `team` to a fresh per-turn budget (1 move + 1 action;
# wolves also get their bonus attack back).
func _refresh_team_budgets(team: int) -> void:
	for u in units:
		if u.is_alive() and u.team == team:
			u.moved = false
			u.acted = false
			u.bonus_attack_used = false

# Consume a unit's move slot for the turn. Returns false (with notice) if the
# unit has already moved.
func _consume_move(u) -> bool:
	if u.moved:
		notice.emit("That unit already moved this turn.")
		return false
	u.moved = true
	return true

# Same for the action slot (dig / swing / throw / pickup / special). Wolves
# attack twice: the first consume sets `acted`, the second burns the bonus.
func _consume_action(u) -> bool:
	if u.acted:
		if u.kind == "wolf" and not u.bonus_attack_used:
			u.bonus_attack_used = true
			return true
		notice.emit("That unit already used their action this turn.")
		return false
	u.acted = true
	return true

# Innate melee for spadeless beasts (wolves) and converted units: 2 damage.
func bite(u, target) -> void:
	if target == null or not target.is_alive():
		return
	if not _consume_action(u):
		return
	unit_attacked.emit(u, target.grid)
	_damage(target, 2)
	notice.emit("%s attacks for 2." % u.kind.capitalize())
	_emit_changed()

func begin_turn() -> void:
	energy = MAX_ENERGY
	# Converted enemies tick down at the start of each player turn; at 0 they
	# return to the enemy's side.
	if active_team == TEAM_PLAYER:
		for u in units:
			if u.is_alive() and u.converted_turns > 0 and u.team == TEAM_PLAYER:
				u.converted_turns -= 1
				if u.converted_turns == 0:
					u.team = TEAM_ENEMY
					notice.emit("%s shakes off the spell and rejoins the enemy!" % u.kind.capitalize())
	_refresh_team_budgets(active_team)
	# Only the player has a hand of cards; enemies just act with their units.
	if active_team == TEAM_PLAYER:
		_tick_buildings()
		# First turn gets a larger hand; storehouses raise the cap permanently.
		var target_size: int = FIRST_TURN_HAND if turn == 1 else HAND_SIZE
		target_size += _count_buildings(TEAM_PLAYER, "storehouse")
		_draw_up(target_size)
	# Standing work orders (auto-harvest etc.) run before the player gets control.
	_run_tasks(active_team)
	turn_started.emit(active_team)
	_emit_changed()
	if is_over:
		return
	if active_team == TEAM_PLAYER:
		notice.emit("Turn %d — your move." % turn)
	else:
		notice.emit("Enemy turn %d…" % turn)

func end_turn() -> void:
	# Siege engines volley, the water simulation steps (drain waves advance,
	# live water grows into dry beds), then the current pushes — before hand-off.
	_fire_ballistas(active_team)
	_fire_trebuchets(active_team)
	var wr: Dictionary = world.tick_water()
	if int(wr["drained"]) > 0:
		notice.emit("The riverbed dries (%d cell(s))…" % int(wr["drained"]))
	elif int(wr["grown"]) > 0:
		notice.emit("Water flows onward (%d cell(s))." % int(wr["grown"]))
	_apply_water_current()
	# Hand off to the other side; turn counter ticks when wrapping to player.
	active_team = TEAM_ENEMY if active_team == TEAM_PLAYER else TEAM_PLAYER
	if active_team == TEAM_PLAYER:
		turn += 1
	begin_turn()

# Push every unit / dropped spade sitting in a water cell one step along that
# cell's flow direction. Skips pushes that would land on another unit, fall
# off-map (current stalls at the edge), or onto non-passable terrain.
func _apply_water_current() -> void:
	if world == null:
		return
	var pushed_units := {}
	var moves: Array = []     # (unit, from_grid, to_grid) tuples for animation
	for cell_v in world.water_flow.keys():
		var cell: Vector3i = cell_v
		var flow: Vector3i = world.water_flow[cell]
		var dest: Vector3i = cell + flow
		if not world.is_passable(dest):
			continue
		var u = unit_at(cell)
		if u != null and not pushed_units.has(u) and unit_at(dest) == null:
			var from_g: Vector3i = u.grid
			u.grid = dest
			pushed_units[u] = true
			moves.append([u, from_g, dest])
		for s in dropped:
			if s.grid == cell:
				s.grid = dest
	# Emit animations after the iteration so we don't disturb the dict.
	for m in moves:
		unit_animated_move.emit(m[0], m[1], m[2])
	if not moves.is_empty():
		notice.emit("The current drifts %d unit(s) downstream." % moves.size())
		_emit_changed()

# ---------------------------------------------------------------- queries

func unit_at(p: Vector3i):
	for u in units:
		if u.is_alive() and u.grid == p:
			return u
	return null

func spade_on_ground(p: Vector3i):
	for s in dropped:
		if s.grid == p:
			return s
	return null

func select(u) -> void:
	selected = u
	_emit_changed()

func _spend(n: int) -> bool:
	if energy < n:
		notice.emit("Not enough energy (%d/%d)." % [energy, MAX_ENERGY])
		return false
	energy -= n
	return true

# ---------------------------------------------------------------- movement

# --- target sets (cells a mode can act on; used for wireframe highlights) ---

# Effective throw range: spade range, +4 for rangers (their whole specialty).
func throw_range_for(u) -> int:
	if u == null or u.spade == null:
		return 0
	var r: int = u.spade.throw_range
	if u.kind == "javelin":
		r += 4
	return r

func move_range_for(u) -> int:
	var r: int = MOVE_RANGE
	if u != null and u.team == TEAM_PLAYER and passives.has("swift_ops"):
		r *= 2
	if u != null and u.kind == "wolf":
		r *= 2
	if u != null and u.kind == "boat":
		r = 8      # the current adds the downstream/upstream asymmetry
	return r

func move_targets(u) -> Array:
	var out := []
	if u == null or u.moved:
		return out
	var budget: int = move_range_for(u)
	var boat: bool = (u.kind == "boat")
	var dist := {u.grid: 0}
	var queue := [u.grid]
	while not queue.is_empty():
		var cur: Vector3i = queue.pop_front()
		if dist[cur] >= budget:
			continue
		for d in DIRS:
			for dy in [0, 1, -1]:
				var np: Vector3i = cur + d + Vector3i(0, dy, 0)
				if dist.has(np):
					continue
				if boat and not world.is_water(np):
					continue
				if world.is_standable(np) and unit_at(np) == null:
					dist[np] = dist[cur] + 1
					out.append(np)
					queue.append(np)
	return out

func dig_targets(u) -> Array:
	# Dig works on dirt-like solids (EARTH/GOLD/CRYSTAL/RELIC/OIL) anywhere in
	# the full 26-cell adjacent neighbourhood — so you can excavate diagonals
	# and below-diagonals without tunnelling straight down under your own feet.
	# Only digging the cell DIRECTLY below still descends you (tunneling).
	# Trees and boulders are obstacles — chop those with Swing, not Dig.
	if u == null or u.spade == null or u.acted:
		return []
	if u.kind == "warrior" or u.kind == "plow":
		return []      # warriors don't dig; plows level terrain by moving
	var out := []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				if dx == 0 and dy == 0 and dz == 0:
					continue
				var p: Vector3i = u.grid + Vector3i(dx, dy, dz)
				if not world.is_solid(p):
					continue
				var m: int = world.material_at(p)
				if m == VoxelWorld.Mat.TREE or m == VoxelWorld.Mat.STONE:
					continue
				out.append(p)
	return out

# Cells the selected unit can harvest with a single click (no mode button):
# adjacent trees → "chop" (whole-column fell), adjacent dirt-like solids →
# "dig" (with auto-placed spoil). Returns {Vector3i: "chop"|"dig"}.
func harvest_candidates(u) -> Dictionary:
	var out: Dictionary = {}
	if u == null or u.team != TEAM_PLAYER or u.spade == null or u.acted:
		return out
	for d in DIRS:
		var p: Vector3i = u.grid + d
		if world.material_at(p) == VoxelWorld.Mat.TREE:
			out[p] = "chop"
	for p in dig_targets(u):
		if not out.has(p):
			out[p] = "dig"
	return out

func swing_targets(u) -> Array:
	if u == null or u.spade == null or u.acted:
		return []
	var out := []
	for d in DIRS:
		var p: Vector3i = u.grid + d
		if world.in_bounds(p):
			out.append(p)
	return out

func throw_targets(u) -> Array:
	# Standable ground tiles within a cube of radius `spade.throw_range`. Only
	# tile tops light up, not the airspace above them. Spade Wings widens this.
	if u == null or u.spade == null or u.acted:
		return []
	var r: int = throw_range_for(u)
	var out := []
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if dx == 0 and dy == 0 and dz == 0:
					continue
				var p: Vector3i = u.grid + Vector3i(dx, dy, dz)
				if world.is_standable(p) or (unit_at(p) != null and unit_at(p) != u):
					out.append(p)
	return out

# Standable cells next to the leader where a summoned operator can land.
func placement_targets() -> Array:
	var leader = _player_leader()
	if leader == null:
		return []
	var out := []
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for dy in [0, 1, -1]:
				if dx == 0 and dz == 0 and dy == 0:
					continue
				var p: Vector3i = leader.grid + Vector3i(dx, dy, dz)
				if world.is_standable(p) and unit_at(p) == null:
					out.append(p)
	return out

func _player_leader():
	for u in units:
		if u.is_alive() and u.team == 0 and u.kind == "leader":
			return u
	return null

# --- Combo plays --------------------------------------------------------------
# A combo combines N cards into a single play that summons one operator,
# optionally giving them a spade and pre-equipping upgrades. Rules:
#   * exactly 1 Operator card (the anchor / "unit")
#   * at most 1 Spade card
#   * at most 1 of each upgrade slot (head / shaft / handle)
#   * any number of operator_upgrade cards (no duplicates)
#   * spade upgrades (head/shaft/handle) require a Spade card in the same combo
#   * total cost is the sum of all cards; must fit in current energy
# Returns a dict with "valid" plus diagnostics; if invalid, "reason" explains.
func combo_validate(cards: Array) -> Dictionary:
	if cards.is_empty():
		return {"valid": false, "reason": "Select cards from your hand."}
	var op_count := 0
	var spade_count := 0
	var head := 0
	var shaft := 0
	var handle := 0
	var op_upgrades := []
	var cost := 0
	for c in cards:
		cost += int(c["cost"])
		match String(c.get("category", "")):
			"unit": op_count += 1
			"spade": spade_count += 1
			"head": head += 1
			"shaft": shaft += 1
			"handle": handle += 1
			"operator_upgrade": op_upgrades.append(String(c["id"]))
	if op_count > 1:
		return {"valid": false, "reason": "Only one Operator per combo."}
	if spade_count > 1:
		return {"valid": false, "reason": "Only one Spade per combo."}
	if head > 1: return {"valid": false, "reason": "Only one Head upgrade."}
	if shaft > 1: return {"valid": false, "reason": "Only one Shaft upgrade."}
	if handle > 1: return {"valid": false, "reason": "Only one Handle upgrade."}
	if (head + shaft + handle) > 0 and spade_count == 0:
		return {"valid": false, "reason": "Spade upgrades need a Spade card."}
	var seen_ou := {}
	for id in op_upgrades:
		if seen_ou.has(id):
			return {"valid": false, "reason": "Duplicate operator upgrade."}
		seen_ou[id] = true
	# Two valid shapes: Operator combo (creates a new op) or Spade-only combo
	# (drops a spade on the ground or hands it to a spadeless operator).
	if op_count == 0:
		if spade_count == 0:
			return {"valid": false, "reason": "Combo needs an Operator or Spade card."}
		if op_upgrades.size() > 0:
			return {"valid": false, "reason": "Operator upgrades need an Operator card."}
	if cost > energy:
		return {"valid": false, "reason": "Not enough energy (%d / %d)." % [cost, energy]}
	# (Materials are paid when cards are BOUGHT from the Build Bar, so combos
	# only cost energy.)
	return {"valid": true, "total_cost": cost, "is_spade_only": op_count == 0}

func combo_targets(cards: Array) -> Array:
	var v: Dictionary = combo_validate(cards)
	if not v.get("valid", false):
		return []
	if v.get("is_spade_only", false):
		# Drop-on-ground targets (adjacent to leader) + hand-off targets
		# (every spadeless friendly operator, wherever they are).
		var out: Array = placement_targets().duplicate()
		for u in units:
			if u.is_alive() and u.team == TEAM_PLAYER \
					and u.kind == "operator" and u.spade == null:
				if not out.has(u.grid):
					out.append(u.grid)
		return out
	return placement_targets()

func combo_summary(cards: Array) -> String:
	var parts := []
	for c in cards:
		parts.append(String(c["title"]))
	return " + ".join(parts)

# Execute the combo. Two shapes:
#   * Operator combo: spawns a new op at `target_cell` (standable + empty),
#     attaches a spade if included, applies upgrades to spade/op.
#   * Spade-only combo: either drops a (possibly upgraded) spade on `target_cell`
#     (if empty + standable) or hands it to the friendly operator standing there
#     (if they have no spade).
# Returns true on success.
func play_combo_at(cards: Array, target_cell: Vector3i) -> bool:
	var v: Dictionary = combo_validate(cards)
	if not v.get("valid", false):
		notice.emit(String(v.get("reason", "Invalid combo.")))
		return false
	if v.get("is_spade_only", false):
		return _play_spade_only_combo(cards, target_cell, v)
	# --- Operator combo --------------------------------------------------------
	if not world.is_standable(target_cell) or unit_at(target_cell) != null:
		notice.emit("Pick a standable, empty tile.")
		return false
	energy -= int(v["total_cost"])
	var op = _spawn_unit(TEAM_PLAYER, target_cell, false)
	# The anchor "unit" card decides the kind (operator / warrior / ranger / plow).
	op.kind = "operator"
	for c in cards:
		if String(c.get("category", "")) == "unit" and SPECIAL_UNITS.has(String(c["id"])):
			op.kind = String(c["id"])
			break
	match op.kind:
		"warrior":
			op.hp = 7
			op.max_hp = 7
		"plow":
			op.hp = 8
			op.max_hp = 8
	# Spade card (if included) attaches before slot upgrades.
	for c in cards:
		if String(c.get("category", "")) == "spade":
			var s := Spade.new()
			s.owner = op
			op.spade = s
			break
	_apply_combo_upgrades(op, cards)
	_discard_combo(cards)
	notice.emit("Combo: %s" % combo_summary(cards))
	_emit_changed()
	return true

func _play_spade_only_combo(cards: Array, target_cell: Vector3i, v: Dictionary) -> bool:
	# Target validation: either an empty standable tile (drop on ground) or a
	# friendly operator at this cell who has no spade (hand-off).
	var recipient = unit_at(target_cell)
	var hand_off: bool = recipient != null and recipient.team == TEAM_PLAYER \
			and recipient.kind == "operator" and recipient.spade == null
	var drop_on_ground: bool = recipient == null \
			and world.is_standable(target_cell)
	if not (hand_off or drop_on_ground):
		notice.emit("Spade needs an empty tile or a spadeless operator.")
		return false
	energy -= int(v["total_cost"])
	var s := Spade.new()
	# Apply slot upgrades to the freshly-made spade.
	for c in cards:
		var cat := String(c.get("category", ""))
		if cat in ["head", "shaft", "handle"]:
			_apply_spade_upgrade(s, String(c["id"]), cat)
	if hand_off:
		s.owner = recipient
		recipient.spade = s
		notice.emit("Spade handed to operator.")
	else:
		s.owner = null
		s.grid = target_cell
		dropped.append(s)
		notice.emit("Spade dropped here.")
	_discard_combo(cards)
	_emit_changed()
	return true

# Apply every upgrade in the combo (after the spade exists if it's included).
func _apply_combo_upgrades(op, cards: Array) -> void:
	for c in cards:
		var cat := String(c.get("category", ""))
		match cat:
			"head", "shaft", "handle":
				if op.spade != null:
					_apply_spade_upgrade(op.spade, String(c["id"]), cat)
			"operator_upgrade":
				_apply_operator_upgrade(op, String(c["id"]))

func _discard_combo(cards: Array) -> void:
	for c in cards:
		_consume_played(c)

# Voluntary discard of selected cards (no energy cost). Drawn replacements
# only come at the next own-team begin_turn, so discarding mid-turn means
# playing out the round with the smaller hand.
func discard_cards(cards: Array) -> void:
	if cards.is_empty():
		return
	var removed: int = 0
	for c in cards:
		if hand.has(c):
			hand.erase(c)
			discard.append(c)
			removed += 1
	if removed > 0:
		notice.emit("Discarded %d card%s." % [removed, "" if removed == 1 else "s"])
		_emit_changed()

# --- Upgrade cards (head / shaft / handle / operator_upgrade) ----------------

# Cells where a valid upgrade recipient stands (operators with a spade for
# head/shaft/handle; any friendly operator for operator_upgrade).
func upgrade_targets(card) -> Array:
	var out := []
	if card == null:
		return out
	var cat: String = card.get("category", "")
	for u in units:
		if not u.is_alive() or u.team != 0:
			continue
		if cat == "head" or cat == "shaft" or cat == "handle":
			if u.spade == null:
				continue
			if cat == "head" and u.spade.head != "": continue
			if cat == "shaft" and u.spade.shaft != "": continue
			if cat == "handle" and u.spade.handle != "": continue
		elif cat == "operator_upgrade":
			if _already_has(u, card["id"]):
				continue
		else:
			continue
		out.append(u.grid)
	return out

func _already_has(u, id: String) -> bool:
	match id:
		"strength": return u.strength
		"endurance": return u.endurance
		"dual_wield": return u.dual_wield
		"hand_eye": return u.hand_eye
		"fishing_pole": return u.has_fishing_pole
	return false

func play_upgrade_at(card, target_cell: Vector3i) -> void:
	if card == null or not hand.has(card):
		return
	if card["cost"] > energy:
		notice.emit("Not enough energy.")
		return
	var u = unit_at(target_cell)
	if u == null or u.team != 0:
		notice.emit("Pick a friendly operator.")
		return
	var cat: String = card.get("category", "")
	var id: String = card["id"]
	if cat == "head" or cat == "shaft" or cat == "handle":
		if u.spade == null:
			notice.emit("Target needs a spade.")
			return
		_apply_spade_upgrade(u.spade, id, cat)
	elif cat == "operator_upgrade":
		_apply_operator_upgrade(u, id)
	else:
		return
	energy -= card["cost"]
	_consume_played(card)
	notice.emit("Applied %s." % card["title"])
	_emit_changed()

func _apply_spade_upgrade(spade, id: String, slot: String) -> void:
	if slot == "head": spade.head = id
	elif slot == "shaft": spade.shaft = id
	elif slot == "handle": spade.handle = id
	# Static stat bumps (the simpler ones) take effect on equip:
	match id:
		"spade_tip":
			spade.dig_depth += 1
		"spade_wings":
			spade.throw_range += 3
		"spade_metal_detector":
			_reveal_material(VoxelWorld.Mat.GOLD)
		"spade_dousing_rod":
			_reveal_material(VoxelWorld.Mat.WATER)

func _apply_operator_upgrade(u, id: String) -> void:
	match id:
		"strength": u.strength = true
		"endurance": u.endurance = true
		"dual_wield": u.dual_wield = true
		"hand_eye": u.hand_eye = true
		"fishing_pole": u.has_fishing_pole = true

func _reveal_material(mat: int) -> void:
	for c in world.cells:
		if world.cells[c] == mat:
			seen[c] = true

func _cheb3(a: Vector3i, b: Vector3i) -> int:
	return maxi(maxi(absi(a.x - b.x), absi(a.y - b.y)), absi(a.z - b.z))

# Targeted card play — used for cards that need a placement (Operator).
func play_card_at(card, cell: Vector3i) -> void:
	if card == null:
		return
	if not hand.has(card):
		return
	if card["cost"] > energy:
		notice.emit("Not enough energy.")
		return
	match card["id"]:
		"operator":
			if not world.is_standable(cell) or unit_at(cell) != null:
				notice.emit("Pick a standable, empty tile.")
				return
			energy -= card["cost"]
			_spawn_unit(0, cell, false)        # bare operator — combos add the spade
			notice.emit("Operator deployed.")
		_:
			# Fallback: defer to non-targeted path.
			play_card(card)
			return
	hand.erase(card)
	discard.append(card)
	_emit_changed()

# --- targeted actions (driven by clicking a highlighted cell) ---

func _face_toward(u, cell: Vector3i) -> void:
	var dx: int = cell.x - u.grid.x
	var dz: int = cell.z - u.grid.z
	if abs(dx) >= abs(dz) and dx != 0:
		u.facing = Vector3i(signi(dx), 0, 0)
	elif dz != 0:
		u.facing = Vector3i(0, 0, signi(dz))

func move_to(u, cell: Vector3i) -> void:
	if not _consume_move(u):
		return
	_face_toward(u, cell)
	var from_g: Vector3i = u.grid
	u.grid = cell
	# Auto-pickup: walking onto a dropped spade grabs it for free (no action).
	if u.spade == null:
		var s = spade_on_ground(cell)
		if s != null:
			dropped.erase(s)
			s.owner = u
			u.spade = s
			notice.emit("Picked up a spade.")
	unit_animated_move.emit(u, from_g, cell)
	if u.kind == "plow":
		_plow_swath(u, from_g, cell)
	_emit_changed()

# The plow levels the 3-wide swath directly ahead of its movement: each of the
# three columns (front, front-left, front-right) is knocked down one level —
# tree columns fell entirely — and the materials are banked.
func _plow_swath(u, from_g: Vector3i, dest: Vector3i) -> void:
	var dx: int = signi(dest.x - from_g.x)
	var dz: int = signi(dest.z - from_g.z)
	var dir: Vector3i
	if absi(dest.x - from_g.x) >= absi(dest.z - from_g.z) and dx != 0:
		dir = Vector3i(dx, 0, 0)
	elif dz != 0:
		dir = Vector3i(0, 0, dz)
	else:
		return
	var perp := Vector3i(dir.z, 0, dir.x)
	var rewards: Array = []
	var hit: int = 0
	for off in [-1, 0, 1]:
		var col: Vector3i = dest + dir + perp * off
		if col.x < 0 or col.x >= world.SX or col.z < 0 or col.z >= world.SZ:
			continue
		for y in range(world.SY - 1, -1, -1):
			var p := Vector3i(col.x, y, col.z)
			if not world.is_solid(p):
				continue
			if world.material_at(p) == VoxelWorld.Mat.TREE:
				for tc in tree_column_cells(p):
					var lab2: String = _treasure_reward(world.dig_cell(tc), tc)
					if lab2 != "":
						rewards.append(lab2)
			else:
				var lab: String = _treasure_reward(world.dig_cell(p), p)
				if lab != "":
					rewards.append(lab)
			hit += 1
			break
	if hit > 0:
		notice.emit("Plow levels %d column(s). %s" % [hit, ", ".join(rewards.slice(0, 3))])

# ---------------------------------------------------------------- spade actions

# Targeted dig: clear any solid neighbour. A below-dig descends the unit (and
# may chain `spade.dig_depth` cells of vertical tunneling); a lateral/up dig
# just clears the one cell. Gold tiles refund +1 energy.
func dig_at(u, cell: Vector3i) -> void:
	if u == null or u.spade == null:
		notice.emit("No spade to dig with.")
		return
	if not world.is_solid(cell):
		notice.emit("Nothing to dig there.")
		return
	if not _consume_action(u):
		return
	var rewards: Array = []
	# Remember where the unit started so we can animate any descent at the end.
	var dig_from: Vector3i = u.grid
	# Strength bumps vertical dig depth by 1.
	var depth: int = u.spade.dig_depth + (1 if u.strength else 0)
	if cell == u.grid + DOWN:
		# Vertical tunneling: descend through `depth` solid cells.
		for i in depth:
			var below: Vector3i = u.grid + DOWN
			if not world.is_solid(below):
				break
			var mat: int = world.dig_cell(below)
			var label: String = _treasure_reward(mat, below)
			if label != "":
				rewards.append(label)
			u.grid = below
	else:
		var mat: int = world.dig_cell(cell)
		var label: String = _treasure_reward(mat, cell)
		if label != "":
			rewards.append(label)
	# Dirt has to go somewhere. Pick an adjacent empty standable cell (preferring
	# neighbours of the dig source so reshaping happens locally) and fill it.
	var dest = _pick_dig_raise_dest(u, cell)
	if dest != null:
		world.set_material(dest, VoxelWorld.Mat.EARTH)
	if not rewards.is_empty():
		notice.emit("Dug — " + ", ".join(rewards))
	elif dest != null:
		notice.emit("Dug — dirt moved to %d, %d, %d." % [dest.x, dest.y, dest.z])
	else:
		notice.emit("Dug out a tile.")
	# Animate the descent if the unit actually dropped (vertical dig path).
	if u.grid != dig_from:
		unit_animated_move.emit(u, dig_from, u.grid)
	_emit_changed()

# Choose an empty standable cell to deposit the dug-out dirt. Preference order:
# (1) cells adjacent to the dig source, (2) cells adjacent to the operator.
# Returns null if there's nowhere reasonable for the dirt to land.
# Apply the energy / card / hand reward for breaking through a treasure tile.
# Returns a short label of what was hit, for the notice line.
func _treasure_reward(mat: int, cell := Vector3i(-9999, 0, 0)) -> String:
	if cell.x != -9999:
		terrain_hit.emit(cell, mat)
	match mat:
		VoxelWorld.Mat.EARTH:
			earth[active_team] += 1
			return "Earth (+1, bank=%d)" % earth[active_team]
		VoxelWorld.Mat.GOLD:
			energy += 1
			return "Gold (+1 energy)"
		VoxelWorld.Mat.CRYSTAL:
			energy += 2
			_draw_one_card()
			return "Crystal (+2 energy, +1 card)"
		VoxelWorld.Mat.RELIC:
			var added: Dictionary = _add_random_upgrade_to_hand()
			return "RELIC! (+%s card)" % String(added.get("title", "upgrade"))
		VoxelWorld.Mat.OIL:
			# Stockpiled barrels, not instant energy — accumulates per team.
			oil[active_team] += 1
			return "Oil (+1 barrel, bank=%d)" % oil[active_team]
		VoxelWorld.Mat.TREE:
			# "Efficient Lumber" passive doubles the per-cell yield.
			var amt: int = 1
			if passives.has("lumber_bonus") and active_team == TEAM_PLAYER:
				amt = 2
			wood[active_team] += amt
			return "Chopped tree (+%d wood, bank=%d)" % [amt, wood[active_team]]
		VoxelWorld.Mat.STONE:
			stone[active_team] += 1
			return "Smashed boulder (+1 stone, bank=%d)" % stone[active_team]
	return ""

func _draw_one_card() -> bool:
	if draw_pile.is_empty():
		_reshuffle_with_upgrade()
	if draw_pile.is_empty():
		return false
	hand.append(draw_pile.pop_back())
	cards_drawn.emit(1)
	return true

func _add_random_upgrade_to_hand() -> Dictionary:
	var ids: Array = UPGRADES.keys()
	var id: String = String(ids[randi() % ids.size()])
	var defn: Dictionary = UPGRADES[id]
	var card := _make_card(id, defn["title"], defn["cost"], defn["category"], defn["blurb"])
	hand.append(card)
	cards_drawn.emit(1)
	return card

func _pick_dig_raise_dest(u, source: Vector3i):
	var cands: Array = []
	for d in CARDINAL_6:
		var p: Vector3i = source + d
		if p == u.grid:
			continue
		if world.is_standable(p) and unit_at(p) == null:
			cands.append(p)
	if cands.is_empty():
		for d in CARDINAL_6:
			var p: Vector3i = u.grid + d
			if p == source:
				continue
			if world.is_standable(p) and unit_at(p) == null:
				cands.append(p)
	if cands.is_empty():
		return null
	return cands[randi() % cands.size()]

# Cells the player can pick to *deposit* the dug-out dirt: empty standable
# cells adjacent to either the dig source or the operator's current position
# (so the choice covers the natural reshape area).
func dig_raise_targets(u, source: Vector3i) -> Array:
	if u == null:
		return []
	var out: Array = []
	for d in CARDINAL_6:
		var p: Vector3i = source + d
		if p == u.grid:
			continue
		if world.is_standable(p) and unit_at(p) == null:
			out.append(p)
	for d in CARDINAL_6:
		var p: Vector3i = u.grid + d
		if p == source:
			continue
		if world.is_standable(p) and unit_at(p) == null:
			if not out.has(p):
				out.append(p)
	return out

# Two-step atomic dig: clear `source`, raise `dest` to EARTH. Mirrors dig_at's
# treasure / descent / strength behaviour but with a player-chosen deposit
# instead of the random auto-pick.
func dig_and_raise(u, source: Vector3i, dest: Vector3i) -> bool:
	if u == null or u.spade == null:
		notice.emit("No spade to dig with.")
		return false
	if not world.is_solid(source):
		notice.emit("Source isn't a solid tile.")
		return false
	# Standable cells (air or water with solid below) are valid raise targets.
	# Picking a water cell as the dest dams the river there.
	if not (world.is_standable(dest) and unit_at(dest) == null):
		notice.emit("Destination isn't a valid raise target.")
		return false
	if not _consume_action(u):
		return false
	var rewards: Array = []
	var depth: int = u.spade.dig_depth + (1 if u.strength else 0)
	var dig_from: Vector3i = u.grid
	if source == u.grid + DOWN:
		for i in depth:
			var below: Vector3i = u.grid + DOWN
			if not world.is_solid(below):
				break
			var mat: int = world.dig_cell(below)
			var label: String = _treasure_reward(mat, below)
			if label != "":
				rewards.append(label)
			u.grid = below
	else:
		var mat: int = world.dig_cell(source)
		var label: String = _treasure_reward(mat, source)
		if label != "":
			rewards.append(label)
	var damming: bool = world.is_water(dest)
	if damming:
		world.water_flow.erase(dest)        # remove this cell from the river
	world.set_material(dest, VoxelWorld.Mat.EARTH)
	# Diversion: if the just-cleared source sits next to a water cell at the
	# same y level, the river spreads into it. Inherits flow direction.
	_maybe_divert_water(source)
	# After any change involving water, re-check connectivity. A dam SCHEDULES
	# a gradual drain wave that spreads from the dam, one layer per turn.
	if damming or world.is_water(source):
		var scheduled: Array = world.recompute_water_flow(dest if damming else source)
		if scheduled.size() > 0:
			notice.emit("River blocked — %d cell(s) will dry, turn by turn." % scheduled.size())
	if not rewards.is_empty():
		notice.emit("Dug — " + ", ".join(rewards))
	else:
		notice.emit("Dirt moved to %d, %d, %d." % [dest.x, dest.y, dest.z])
	if u.grid != dig_from:
		unit_animated_move.emit(u, dig_from, u.grid)
	_emit_changed()
	return true

# After a dig clears `source` to AIR, see if it's cardinally adjacent to water
# at the same y. If so, the river extends into the new cell (matching flow).
func _maybe_divert_water(source: Vector3i) -> void:
	if world == null:
		return
	if not world.is_air(source):
		return
	for d in DIRS:
		var n: Vector3i = source + d
		if world.is_water(n):
			world.set_material(source, VoxelWorld.Mat.WATER)
			var flow: Vector3i = world.water_flow.get(n, d)
			world.water_flow[source] = flow
			notice.emit("River diverted into %d,%d,%d." % [source.x, source.y, source.z])
			return

# Back-compat shim for the 3D scene's hotkey-driven dig.
func dig(u) -> void:
	if u == null:
		return
	dig_at(u, u.grid + DOWN)

func swing_at(u, cell: Vector3i) -> void:
	if u.spade == null:
		notice.emit("No spade to swing.")
		return
	_face_toward(u, cell)
	# Base swing damage + Strength + Warrior bonus + head-type bonus.
	var base: int = u.spade.swing_dmg + (1 if u.strength else 0) \
			+ (2 if u.kind == "warrior" else 0)
	if u.kind == "warrior" and _count_buildings(u.team, "barracks") > 0:
		base += 1      # barracks drill their warriors
	var enemy = unit_at(cell)
	if enemy != null and enemy.team != u.team:
		if not _consume_action(u):
			return
		unit_attacked.emit(u, cell)
		var dmg: int = base + (1 if u.spade.head == "spade_blade" else 0)
		_damage(enemy, dmg)
		notice.emit("Swing hit for %d." % dmg)
	elif world.is_solid(cell):
		# Warriors are fighters only — no chopping or wall-clearing.
		if u.kind == "warrior" or u.kind == "plow":
			notice.emit("%s can't dig or chop." % u.kind.capitalize())
			return
		if not _consume_action(u):
			return
		# Pick adds wall damage, but walls don't have HP yet — note for later.
		var m: int = world.dig_cell(cell)
		if m == VoxelWorld.Mat.TREE:
			# One chop fells the WHOLE trunk column — wood for every cell.
			_treasure_reward(m, cell)
			var felled: int = 1
			for vdir in [Vector3i(0, 1, 0), Vector3i(0, -1, 0)]:
				var p: Vector3i = cell + vdir
				while world.material_at(p) == VoxelWorld.Mat.TREE:
					_treasure_reward(world.dig_cell(p), p)
					felled += 1
					p += vdir
			notice.emit("Felled the tree! (+%d wood, bank=%d)" % [felled, wood[active_team]])
		else:
			var reward: String = _treasure_reward(m, cell)
			if reward != "":
				notice.emit(reward)
			elif m == VoxelWorld.Mat.STONE:
				notice.emit("Smashed a boulder.")
			else:
				notice.emit("Cleared the cell.")
	else:
		notice.emit("Nothing there to swing at.")
		return
	_emit_changed()

func throw_at(u, cell: Vector3i) -> void:
	if u.spade == null:
		notice.emit("No spade to throw.")
		return
	if not _consume_action(u):
		return
	_face_toward(u, cell)
	var s = u.spade
	var dmg: int = s.swing_dmg + (1 if u.strength else 0)
	var hit = unit_at(cell)
	if hit == u:
		hit = null
	# Tell the view layer to animate a flying spade between the cells. The
	# state-side bookkeeping (damage / drop / boomerang) still happens
	# immediately below — only the visual is in flight.
	spade_thrown.emit(u.grid, cell, s.handle == "spade_boomerang")
	if hit != null:
		_damage(hit, dmg)
		notice.emit("Thrown spade hit for %d." % dmg)
	else:
		notice.emit("Spade thrown.")
	# Warhead detonates on landing: AOE damage to all OTHER units within r1.
	if s.head == "spade_warhead":
		var blast := 0
		for nu in units.duplicate():
			if nu == u or nu == hit or not nu.is_alive():
				continue
			if _cheb3(nu.grid, cell) <= 1:
				_damage(nu, dmg)
				blast += 1
		if blast > 0:
			notice.emit("Warhead caught %d nearby!" % blast)
	# Boomerang: spade returns to the thrower's hand instead of dropping.
	if s.handle == "spade_boomerang":
		notice.emit("Spade boomeranged back.")
	else:
		var landing: Vector3i = cell
		if not world.is_air(landing):
			landing = u.grid
		u.spade = null
		s.owner = null
		s.grid = landing
		dropped.append(s)
	_emit_changed()

func pickup(u) -> void:
	if u.spade != null:
		notice.emit("Already holding a spade.")
		return
	var s = spade_on_ground(u.grid)
	if s == null:
		for d in DIRS:
			s = spade_on_ground(u.grid + d)
			if s != null:
				break
	if s == null:
		notice.emit("No spade here to pick up.")
		return
	if not _consume_action(u):
		return
	dropped.erase(s)
	s.owner = u
	s.grid = Vector3i.ZERO
	u.spade = s
	notice.emit("Picked up a spade.")
	_emit_changed()

func special(u) -> void:
	if u == null or u.spade == null:
		notice.emit("Need a spade to use a special action.")
		return
	# Dispatch on the spade's head upgrade. Each upgrade that grants a Special
	# wires up its own case.
	match u.spade.head:
		"spade_earthquake":
			if not _consume_action(u):
				return
			_special_earthquake(u, 2)
			notice.emit("EARTHQUAKE — the earth shifts around you.")
			_emit_changed()
		_:
			notice.emit("This spade has no Special action equipped.")

# Randomise the surface heights of every column within radius `radius` (Chebyshev)
# of the operator's column by ±1 from the starting height. Skips raises that
# would crush a unit; lowers leave gravity to handle any falls. Emits
# `quake_started` with the affected column list so the view can shake them.
func _special_earthquake(u, radius: int) -> void:
	var ox: int = u.grid.x
	var oz: int = u.grid.z
	var affected: Array = []
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			if dx == 0 and dz == 0:
				continue
			var x: int = ox + dx
			var z: int = oz + dz
			if x < 0 or x >= world.SX or z < 0 or z >= world.SZ:
				continue
			# Find the current top solid cell for this (x, z) column.
			var top: int = -1
			for y in range(world.SY - 1, -1, -1):
				if world.is_solid(Vector3i(x, y, z)):
					top = y
					break
			if top < 0:
				continue
			affected.append(Vector2i(x, z))
			var delta: int = randi_range(-1, 1)
			if delta > 0 and top + 1 < world.SY:
				var above := Vector3i(x, top + 1, z)
				if unit_at(above) == null:           # don't crush a unit
					world.set_material(above, VoxelWorld.Mat.EARTH)
			elif delta < 0:
				world.set_material(Vector3i(x, top, z), VoxelWorld.Mat.AIR)
	quake_started.emit(affected)

# ---------------------------------------------------------------- combat

func _damage(u, amount: int) -> void:
	u.hp -= amount
	unit_damaged.emit(u, amount)
	if not u.is_alive():
		unit_died.emit(u, u.grid)
		_kill(u)

func _kill(u) -> void:
	if u.spade != null:
		var s = u.spade
		s.owner = null
		s.grid = u.grid
		dropped.append(s)
		u.spade = null
	units.erase(u)
	if selected == u:
		selected = _first_player_unit()

func _first_player_unit():
	for u in units:
		if u.is_alive() and u.team == 0:
			return u
	return null

# ---------------------------------------------------------------- cards

func _draw_up(n: int) -> void:
	var drawn := 0
	while hand.size() < n:
		if draw_pile.is_empty():
			_reshuffle_with_upgrade()
		if draw_pile.is_empty():
			break
		hand.append(draw_pile.pop_back())
		drawn += 1
	if drawn > 0:
		cards_drawn.emit(drawn)

func play_card(card) -> void:
	if selected == null:
		notice.emit("Select a unit first.")
		return
	match card["id"]:
		"operator":
			var spot := _adjacent_standable(selected.grid)
			if spot == Vector3i(-999, -999, -999):
				notice.emit("No open space to summon.")
				return
			if not _spend(card["cost"]):
				return
			_spawn_unit(0, spot, false)        # bare operator — combos add the spade
			notice.emit("Summoned an operator.")
		"spade":
			if selected.spade != null:
				notice.emit("That unit already holds a spade.")
				return
			if not _spend(card["cost"]):
				return
			var s := Spade.new()
			s.owner = selected
			selected.spade = s
			notice.emit("Handed over a spade.")
	hand.erase(card)
	discard.append(card)
	_emit_changed()

func _adjacent_standable(center: Vector3i) -> Vector3i:
	for d in DIRS:
		for dy in [0, 1, -1]:
			var p: Vector3i = center + d + Vector3i(0, dy, 0)
			if world.is_standable(p) and unit_at(p) == null:
				return p
	return Vector3i(-999, -999, -999)
