class_name Spade
extends RefCounted

# A spade: the core implement. Held by a unit (grants dig/swing/throw/special),
# or dropped on the ground at `grid` when thrown or when its owner dies. Upgrade
# slots (head/shaft/handle) are stubs for now and will tune the stats/specials.

var owner = null                   # Unit, or null when on the ground
var grid: Vector3i = Vector3i.ZERO # position while dropped / in flight

# Upgrade slots (one each); empty string = none.
var head: String = ""
var shaft: String = ""
var handle: String = ""

# Base stats (upgrades will modify these later).
var dig_depth: int = 1
var swing_dmg: int = 2
var throw_range: int = 3

func held() -> bool:
	return owner != null
