class_name Meta

# Persistent meta-progression (survives across runs): coins earned by
# clearing areas, and schematics bought with them. A schematic unlocks its
# blueprint in the in-run Build menu. Fresh players can only build the
# fishing pole; everything else is earned.

const PATH := "user://meta.json"
const DEFAULT_UNLOCKED := ["fishing_pole"]

# Coin price of each schematic. Blueprints not listed fall back to 10.
const PRICES := {
	"ladder": 5, "bridge": 8, "dirt_wall": 4, "boat": 10,
	"ballista": 15, "waterwheel": 12, "storehouse": 12, "village": 15,
	"trebuchet": 25, "farm": 10, "campsite": 8, "barracks": 20,
	"spade_wings": 8, "spade_dousing_rod": 8, "double_barrel_spade": 12,
	"spade_laser_rangefinder": 10, "spade_boomerang": 10,
	"spade_propulsion": 12, "spade_trigger": 12, "spade_warhead": 15,
	"spade_metal_detector": 12, "spade_earthquake": 18,
	"spade_grappling_hook": 14, "spade_pogostick": 14,
	"strength": 12, "endurance": 12, "hand_eye": 10, "dual_wield": 18,
}

static var coins: int = 0
static var unlocked: Dictionary = {}
static var _loaded: bool = false

static func load_meta() -> void:
	if _loaded:
		return
	_loaded = true
	for id in DEFAULT_UNLOCKED:
		unlocked[id] = true
	if FileAccess.file_exists(PATH):
		var f := FileAccess.open(PATH, FileAccess.READ)
		var data: Variant = JSON.parse_string(f.get_as_text())
		if data is Dictionary:
			coins = int(data.get("coins", 0))
			for id in data.get("unlocked", []):
				unlocked[String(id)] = true

static func save_meta() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"coins": coins, "unlocked": unlocked.keys()}))

static func price(id: String) -> int:
	return int(PRICES.get(id, 10))

static func is_unlocked(id: String) -> bool:
	load_meta()
	return unlocked.has(id)

static func add_coins(n: int) -> void:
	load_meta()
	coins += n
	save_meta()

static func buy_schematic(id: String) -> bool:
	load_meta()
	if unlocked.has(id) or coins < price(id):
		return false
	coins -= price(id)
	unlocked[id] = true
	save_meta()
	return true


class RunSave:
	# Snapshot of a campaign run, written at the start of every area. Quitting
	# mid-area resumes from that area's start (fresh map, same force/deck).
	const RUN_PATH := "user://run.json"
	static var pending_load: bool = false

	static func exists() -> bool:
		return FileAccess.file_exists(RUN_PATH)

	static func clear() -> void:
		if exists():
			DirAccess.remove_absolute(RUN_PATH)

	static func write(gs) -> void:
		var units_out: Array = []
		for u in gs.units:
			if not u.is_alive() or u.team != 0:
				continue
			var ud := {
				"kind": u.kind, "hp": u.hp, "max_hp": u.max_hp,
				"strength": u.strength, "endurance": u.endurance,
				"dual_wield": u.dual_wield, "hand_eye": u.hand_eye,
				"fishing_pole": u.has_fishing_pole,
			}
			if u.spade != null:
				ud["spade"] = {"head": u.spade.head, "shaft": u.spade.shaft,
					"handle": u.spade.handle, "dig_depth": u.spade.dig_depth,
					"swing_dmg": u.spade.swing_dmg, "throw_range": u.spade.throw_range}
			units_out.append(ud)
		var cards := func(pile: Array) -> Array:
			var out: Array = []
			for c in pile:
				out.append({"id": c["id"], "title": c["title"], "cost": c["cost"],
					"category": c["category"], "blurb": c["blurb"],
					"bought": bool(c.get("bought", false))})
			return out
		var data := {
			"area": gs.area, "branch": gs.branch,
			"stage_in_branch": gs.stage_in_branch,
			"bosses_defeated": gs.bosses_defeated,
			"turn": gs.turn,
			"wood": int(gs.wood[0]), "earth": int(gs.earth[0]),
			"stone": int(gs.stone[0]), "oil": int(gs.oil[0]),
			"passives": gs.passives.keys(),
			"units": units_out,
			"draw_pile": cards.call(gs.draw_pile),
			"hand": cards.call(gs.hand),
			"discard": cards.call(gs.discard),
		}
		var f := FileAccess.open(RUN_PATH, FileAccess.WRITE)
		f.store_string(JSON.stringify(data))

	static func read() -> Dictionary:
		if not exists():
			return {}
		var f := FileAccess.open(RUN_PATH, FileAccess.READ)
		var data: Variant = JSON.parse_string(f.get_as_text())
		return data if data is Dictionary else {}
