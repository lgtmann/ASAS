class_name Unit
extends RefCounted

# A playable character (operator for now). Lives in a grid cell, faces one of the
# four compass directions, and may hold a spade.

var team: int = 0                       # 0 = player, 1 = enemy
var kind: String = "operator"           # "leader" (plays cards) or "operator" (wields a spade)
var grid: Vector3i = Vector3i.ZERO
var facing: Vector3i = Vector3i(0, 0, 1) # one of +Z/+X/-Z/-X
var hp: int = 5
var max_hp: int = 5
var spade = null                         # held Spade, or null

# Continuous render position (centre of the air cell the unit stands in) — the
# rendering reads this so a move can lerp smoothly while `grid` updates
# instantly for logic. Set on spawn / gravity snap, tweened on move_to.
var draw_pos: Vector3 = Vector3.ZERO

# Per-turn action budget (resets at the start of the owner's team's turn).
# Operator actions consume `acted`; movement consumes `moved`. Energy is now
# only for leader-played card combos.
var moved: bool = false
var acted: bool = false

# Operator upgrades — applied via upgrade cards, persistent for the run.
var strength: bool = false              # +1 to dig depth / swing dmg / throw dmg
var endurance: bool = false              # 2 actions per turn (turn-budget stub)
var dual_wield: bool = false             # can carry a second spade (slot stub)
var hand_eye: bool = false               # can catch thrown spades from teammates (stub)

func is_alive() -> bool:
	return hp > 0
