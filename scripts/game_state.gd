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

# Turn-team tracking and a flag so iso_view can auto-play BOTH sides
# (visible combat simulation).
var active_team: int = TEAM_PLAYER
var sim_mode: bool = false
var is_over: bool = false

# Stockpiled strategic resources (per team). Oil unlocks advanced cards later.
# Energy is still per-turn — these are persistent banks that fill over time.
var oil: Array = [0, 0]   # oil[team] = barrels in the bank
var wood: Array = [0, 0]  # wood[team] = logs in the bank (chopped trees)

# ---------------------------------------------------------------- setup

func setup(w) -> void:
	world = w

func start() -> void:
	randomize()
	_build_deck()
	# Player base in one corner, enemy base across the map — RTS-scale spacing
	# so the early game is exploration / build-up before contact.
	var leader = _spawn_unit(0, world.surface_cell(2, 2), false)
	leader.kind = "leader"
	leader.hp = 8
	leader.max_hp = 8
	_spawn_unit(0, world.surface_cell(3, 2), true)
	_spawn_unit(0, world.surface_cell(2, 3), true)
	var ex: int = world.SX - 3
	var ez: int = world.SZ - 3
	var enemy_leader = _spawn_unit(1, world.surface_cell(ex, ez), false)
	enemy_leader.kind = "leader"
	enemy_leader.hp = 8
	enemy_leader.max_hp = 8
	_spawn_unit(1, world.surface_cell(ex - 1, ez), true)
	_spawn_unit(1, world.surface_cell(ex, ez - 1), true)
	selected = leader
	recompute_vision()
	begin_turn()

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
	if team_alive_count(TEAM_PLAYER) == 0 or team_alive_count(TEAM_ENEMY) == 0:
		is_over = true
		game_over.emit(winner())

# ---------------------------------------------------------------- AI

# Plays one visible AI action for `team`; returns true if anything happened.
# Iso_view calls this in a delay-paced loop so each action is watchable.
# v1 behaviour: for each non-leader unit holding a spade, find the nearest
# enemy; swing if adjacent, otherwise step toward them with move_to.
func ai_step(team: int) -> bool:
	# Operators are no longer energy-bound — each unit has 1 move + 1 action per
	# turn. Loop ends when no team unit can do anything useful.
	if is_over:
		return false
	for u in units:
		if not u.is_alive() or u.team != team:
			continue
		if u.kind == "leader":
			continue                          # leaders stand still in v1
		if u.spade == null:
			continue
		if u.moved and u.acted:
			continue
		var target = _ai_nearest_enemy(u)
		if target == null:
			continue
		var dist: int = _cheb3(u.grid, target.grid)
		if dist == 1 and not u.acted:
			swing_at(u, target.grid)
			return true
		if u.moved:
			continue
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
	for u in units:
		if u.team != 0 or not u.is_alive():
			continue
		_reveal_from(u)

func _reveal_from(u) -> void:
	# A friendly unit reveals every cell on its own y-plane reachable by an
	# unobstructed 2D ray (Bresenham), plus the cube directly below each
	# revealed air cell (the visible floor).
	var y: int = u.grid.y
	for tx in world.SX:
		for tz in world.SZ:
			if not _xz_los(u.grid.x, u.grid.z, tx, tz, y):
				continue
			var here := Vector3i(tx, y, tz)
			seen[here] = true
			var below := Vector3i(tx, y - 1, tz)
			if world.is_solid(below):
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

func _build_deck() -> void:
	draw_pile.clear()
	hand.clear()
	discard.clear()
	for i in 4:
		draw_pile.append(_make_card("operator", "Operator", 2, "unit", "place adjacent"))
	for i in 3:
		draw_pile.append(_make_card("spade", "Spade", 1, "spade", "give to operator"))
	for id in UPGRADES:
		var u: Dictionary = UPGRADES[id]
		draw_pile.append(_make_card(id, u["title"], u["cost"], u["category"], u["blurb"]))
	draw_pile.shuffle()

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

# Reset every unit on `team` to a fresh per-turn budget (1 move + 1 action).
func _refresh_team_budgets(team: int) -> void:
	for u in units:
		if u.is_alive() and u.team == team:
			u.moved = false
			u.acted = false

# Consume a unit's move slot for the turn. Returns false (with notice) if the
# unit has already moved.
func _consume_move(u) -> bool:
	if u.moved:
		notice.emit("That unit already moved this turn.")
		return false
	u.moved = true
	return true

# Same for the action slot (dig / swing / throw / pickup / special).
func _consume_action(u) -> bool:
	if u.acted:
		notice.emit("That unit already used their action this turn.")
		return false
	u.acted = true
	return true

func begin_turn() -> void:
	energy = MAX_ENERGY
	_refresh_team_budgets(active_team)
	# Only the player has a hand of cards; enemies just act with their units.
	if active_team == TEAM_PLAYER:
		# First turn gets a larger hand so combos start firing immediately.
		var target_size: int = FIRST_TURN_HAND if turn == 1 else HAND_SIZE
		_draw_up(target_size)
	turn_started.emit(active_team)
	_emit_changed()
	if is_over:
		return
	if active_team == TEAM_PLAYER:
		notice.emit("Turn %d — your move." % turn)
	else:
		notice.emit("Enemy turn %d…" % turn)

func end_turn() -> void:
	# Apply water current BEFORE the hand-off — units in the river drift
	# downstream one cell, then the next team takes over.
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

func move_targets(u) -> Array:
	var out := []
	if u == null or u.moved:
		return out
	var dist := {u.grid: 0}
	var queue := [u.grid]
	while not queue.is_empty():
		var cur: Vector3i = queue.pop_front()
		if dist[cur] >= MOVE_RANGE:
			continue
		for d in DIRS:
			for dy in [0, 1, -1]:
				var np: Vector3i = cur + d + Vector3i(0, dy, 0)
				if dist.has(np):
					continue
				if world.is_standable(np) and unit_at(np) == null:
					dist[np] = dist[cur] + 1
					out.append(np)
					queue.append(np)
	return out

func dig_targets(u) -> Array:
	# Dig works on dirt-like solids (EARTH/GOLD/CRYSTAL/RELIC/OIL). Trees and
	# boulders are obstacles — chop those with Swing, not Dig (no dirt to move).
	if u == null or u.spade == null or u.acted:
		return []
	var out := []
	for d in CARDINAL_6:
		var p: Vector3i = u.grid + d
		if not world.is_solid(p):
			continue
		var m: int = world.material_at(p)
		if m == VoxelWorld.Mat.TREE or m == VoxelWorld.Mat.STONE:
			continue
		out.append(p)
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
	var r: int = u.spade.throw_range
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
	# Shaft upgrades require lumber to craft (1 wood per shaft card).
	var wood_cost: int = shaft
	if wood_cost > wood[TEAM_PLAYER]:
		return {"valid": false, "reason":
			"Need %d wood for shaft (you have %d)." % [wood_cost, wood[TEAM_PLAYER]]}
	return {"valid": true, "total_cost": cost, "wood_cost": wood_cost,
			"is_spade_only": op_count == 0}

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
	wood[TEAM_PLAYER] -= int(v.get("wood_cost", 0))
	var op = _spawn_unit(TEAM_PLAYER, target_cell, false)
	op.kind = "operator"
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
	wood[TEAM_PLAYER] -= int(v.get("wood_cost", 0))
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
		hand.erase(c)
		discard.append(c)

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
	hand.erase(card)
	discard.append(card)
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
	unit_animated_move.emit(u, from_g, cell)
	_emit_changed()

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
			var label: String = _treasure_reward(mat)
			if label != "":
				rewards.append(label)
			u.grid = below
	else:
		var mat: int = world.dig_cell(cell)
		var label: String = _treasure_reward(mat)
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
func _treasure_reward(mat: int) -> String:
	match mat:
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
			wood[active_team] += 1
			return "Chopped tree (+1 wood, bank=%d)" % wood[active_team]
	return ""

func _draw_one_card() -> bool:
	if draw_pile.is_empty():
		draw_pile = discard.duplicate()
		discard.clear()
		draw_pile.shuffle()
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
			var label: String = _treasure_reward(mat)
			if label != "":
				rewards.append(label)
			u.grid = below
	else:
		var mat: int = world.dig_cell(source)
		var label: String = _treasure_reward(mat)
		if label != "":
			rewards.append(label)
	world.set_material(dest, VoxelWorld.Mat.EARTH)
	# Diversion: if the just-cleared source sits next to a water cell at the
	# same y level, the river spreads into it. Inherits flow direction.
	_maybe_divert_water(source)
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
	# Base swing damage + Strength + head-type bonus (computed at use).
	var base: int = u.spade.swing_dmg + (1 if u.strength else 0)
	var enemy = unit_at(cell)
	if enemy != null and enemy.team != u.team:
		if not _consume_action(u):
			return
		var dmg: int = base + (1 if u.spade.head == "spade_blade" else 0)
		_damage(enemy, dmg)
		notice.emit("Swing hit for %d." % dmg)
	elif world.is_solid(cell):
		if not _consume_action(u):
			return
		# Pick adds wall damage, but walls don't have HP yet — note for later.
		var m: int = world.dig_cell(cell)
		var reward: String = _treasure_reward(m)
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
	if not u.is_alive():
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
			draw_pile = discard.duplicate()
			discard.clear()
			draw_pile.shuffle()
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
