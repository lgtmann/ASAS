class_name OperatorRig

# Cutout rig for the operator: masked head, tunic torso, legs, and one arm
# texture drawn twice (front + mirrored back). Parts come from the art
# pipeline as centred sprites; each is auto-cropped to its opaque bounding
# box at load and assembled via anchor metadata below, so the model's framing
# choices don't matter. Front arm follows the held-spade action; parts can
# later be swapped for equipped gear.
#
# Coordinates: character space is a box `unit_h` tall and unit_h*ASPECT wide,
# anchored at feet bottom-centre. `attach` is (x fraction of width from
# centre, y fraction of height up from feet). `anchor` is the point within
# the part's cropped bbox (0..1) that lands on `attach` — rotations pivot
# there too.

const FRAME_ASPECT := 0.67

const PARTS := {
	"legs": {"path": "res://assets/cards/op_legs.png", "h": 0.30,
		"anchor": Vector2(0.5, 1.0), "attach": Vector2(0.0, 0.0)},
	"torso": {"path": "res://assets/cards/op_torso.png", "h": 0.38,
		"anchor": Vector2(0.5, 1.0), "attach": Vector2(0.0, 0.22)},
	"head": {"path": "res://assets/cards/op_head.png", "h": 0.50,
		"anchor": Vector2(0.5, 0.94), "attach": Vector2(0.0, 0.50)},
	"arm": {"path": "res://assets/cards/op_arm_left.png", "h": 0.27,
		"anchor": Vector2(0.5, 0.08), "attach": Vector2(0.17, 0.54)},
}
const DRAW_ORDER := ["arm_back", "legs", "torso", "head", "arm_front"]

static var _tex: Dictionary = {}
static var _loaded: bool = false

static func ready() -> bool:
	if not _loaded:
		_loaded = true
		for k in PARTS:
			var path: String = PARTS[k]["path"]
			if not ResourceLoader.exists(path):
				continue
			var src: Texture2D = load(path)
			var img: Image = src.get_image()
			var used: Rect2i = img.get_used_rect()
			if used.size.x > 0 and used.size.y > 0:
				_tex[k] = ImageTexture.create_from_image(img.get_region(used))
	return _tex.size() == PARTS.size()

static func draw(canvas: CanvasItem, feet: Vector2, unit_h: float,
		pose: Dictionary, tint: Color) -> void:
	if not ready():
		return
	var w: float = unit_h * FRAME_ASPECT
	var bob: float = float(pose.get("bob", 0.0))
	var lean: Vector2 = pose.get("lean", Vector2.ZERO)
	var arm_rot: float = float(pose.get("arm_rot", 0.0))
	var head_tilt: float = float(pose.get("head_tilt", 0.0))
	var flip: bool = bool(pose.get("flip", false))
	var fs: float = -1.0 if flip else 1.0

	for slot in DRAW_ORDER:
		var key: String = "arm" if slot.begins_with("arm") else slot
		var meta: Dictionary = PARTS[key]
		var tex: Texture2D = _tex.get(key)
		if tex == null:
			continue
		var ph: float = unit_h * float(meta["h"])
		var pw: float = ph * float(tex.get_width()) / float(tex.get_height())
		var attach: Vector2 = meta["attach"]
		var off := Vector2.ZERO
		var rot := 0.0
		var mirror: bool = flip
		match slot:
			"arm_back":
				attach = Vector2(-attach.x, attach.y)
				off = Vector2(0, bob) + lean
				rot = -arm_rot * 0.25 * fs
				mirror = not flip       # the off-side arm mirrors the texture
			"arm_front":
				off = Vector2(0, bob) + lean
				rot = arm_rot * fs
			"torso":
				off = Vector2(0, bob) + lean
			"head":
				off = Vector2(0, bob * 1.35) + lean
				rot = head_tilt * fs
			"legs":
				pass
		var pivot: Vector2 = feet + Vector2(attach.x * w * fs, -attach.y * unit_h) + off
		var anchor: Vector2 = meta["anchor"]
		var sc := Vector2(-1.0, 1.0) if mirror else Vector2.ONE
		canvas.draw_set_transform(pivot, rot, sc)
		var ax: float = anchor.x if not mirror else (1.0 - anchor.x)
		canvas.draw_texture_rect(tex,
			Rect2(Vector2(-ax * pw, -anchor.y * ph), Vector2(pw, ph)), false, tint)
		canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

# Pose for an action animation at normalised time t — the front arm tracks
# the spade prop's rotation so hand and tool read as one motion.
static func action_pose(type: String, t: float, dir: Vector2, bob: float) -> Dictionary:
	var pose := {"bob": bob, "flip": dir.x < 0.0}
	var prop: Variant = SpadeActions.prop_pose(type, t, dir)
	if prop != null:
		pose["arm_rot"] = float(prop["rot"]) * 0.55
	var side: float = 1.0 if dir.x >= 0.0 else -1.0
	match type:
		"dig":
			pose["lean"] = Vector2(4.0 * side, 2.0) * sin(clampf(t / 0.6, 0.0, 1.0) * PI)
			pose["head_tilt"] = 0.10 * sin(clampf(t / 0.6, 0.0, 1.0) * PI)
		"swing", "throw":
			pose["lean"] = Vector2(5.0 * side * sin(clampf(t, 0.0, 1.0) * PI), 0.0)
		"fish":
			pose["head_tilt"] = 0.08 * sin(t * TAU)
	return pose
