class_name BattleIntro
extends Control

# Battle-start title flourish in the Son-of-the-White-Mare shard language:
# jagged near-black / indigo curtains crawl inward from all four screen edges,
# a centred text block slams in, then the shards withdraw to reveal the map.
# Procedural draw — crisp at any resolution, no frames. Self-frees when done.
#
# Phases over normalised _t (0..1):
#   crawl in  → hold (covered, text up) → withdraw → done(reveal)

signal revealed                       # fires once the curtains finish withdrawing

const DUR := 2.2
const CRAWL_END := 0.30
const HOLD_END := 0.50
const WITHDRAW_END := 0.84
const TEETH := 13
const MAX_DEPTH := 0.74               # fraction of screen each curtain reaches at peak
const ROOT_DEPTH := 0.46              # fraction of MAX the valleys reach (interlock)

const SHARD := Color(0.05, 0.04, 0.08)        # near-black shard body
const SHARD_RIM := Color(0.13, 0.16, 0.46)    # indigo rim on the leading edge
const GOLD := Color(0.96, 0.86, 0.55)

var _t := 0.0
var _title := "ENGAGE THE ENEMY"
var _frozen := false                  # harness: hold at a fixed _t for screenshots
var _label: Label
var _backing: ColorRect
var _teeth := []                      # [edge][tooth] hashed tip lengths 0..1

func setup(title: String) -> void:
	_title = title

func freeze_at(tv: float) -> void:
	_frozen = true
	_t = tv

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP        # eat input during the flourish
	# Deterministic ragged tooth lengths per edge.
	var seed := 0x51ED
	for e in 4:
		var row := []
		for i in TEETH:
			seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
			row.append(0.60 + float(seed % 1000) / 1000.0 * 0.40)
		_teeth.append(row)
	# Central text block: dark backing panel + gold folk title.
	_backing = ColorRect.new()
	_backing.color = Color(0.05, 0.04, 0.08, 1.0)
	add_child(_backing)
	_label = Label.new()
	_label.text = _title
	_label.add_theme_font_size_override("font_size", 60)
	_label.add_theme_color_override("font_color", GOLD)
	_label.add_theme_color_override("font_outline_color", Color(0.05, 0.03, 0.06))
	_label.add_theme_constant_override("outline_size", 10)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_label)
	if not _frozen:
		Sfx.play("quake", 0.0, 0.0)   # low rumble on the slam
	queue_redraw()

func _process(delta: float) -> void:
	if _frozen:
		return
	_t += delta / DUR
	if _t >= 1.0:
		revealed.emit()
		queue_free()
		return
	queue_redraw()

# Curtain extension 0..1: in, hold, out.
func _depth() -> float:
	if _t < CRAWL_END:
		var k: float = _t / CRAWL_END
		return 1.0 - pow(1.0 - k, 3.0)          # ease out (slam)
	if _t < HOLD_END:
		return 1.0
	if _t < WITHDRAW_END:
		var k2: float = (_t - HOLD_END) / (WITHDRAW_END - HOLD_END)
		return 1.0 - (k2 * k2)                   # ease in (snap back)
	return 0.0

# Map (along 0..1, into px) to a screen point for the given edge.
func _map(edge: int, along: float, into: float, w: float, h: float) -> Vector2:
	match edge:
		0: return Vector2(along * w, into)             # top
		1: return Vector2(along * w, h - into)         # bottom
		2: return Vector2(into, along * h)             # left
		_: return Vector2(w - into, along * h)         # right

func _draw_curtain(edge: int, depth: float, w: float, h: float) -> void:
	var span: float = h if edge < 2 else w
	var max_into: float = span * MAX_DEPTH * depth
	var root: float = max_into * ROOT_DEPTH
	var pts := PackedVector2Array()
	pts.append(_map(edge, 0.0, 0.0, w, h))           # edge corner A
	var rim := PackedVector2Array()
	var n := TEETH * 2
	for j in n + 1:
		var along: float = float(j) / float(n)
		var into: float
		if j % 2 == 0:
			into = root                              # valley
		else:
			into = max_into * _teeth[edge][(j - 1) / 2]   # tip
		var pos: Vector2 = _map(edge, along, into, w, h)
		pts.append(pos)
		rim.append(pos)
	pts.append(_map(edge, 1.0, 0.0, w, h))           # edge corner B
	draw_colored_polygon(pts, SHARD)
	draw_polyline(rim, SHARD_RIM, 3.0, true)

func _draw() -> void:
	var w := size.x
	var h := size.y
	var depth := _depth()
	# Text + backing visible while the screen is mostly covered.
	var ta: float = clampf((depth - 0.45) / 0.35, 0.0, 1.0)
	if _label != null:
		var bw := 720.0
		var bh := 150.0
		_backing.position = Vector2((w - bw) * 0.5, (h - bh) * 0.5)
		_backing.size = Vector2(bw, bh)
		_backing.color.a = ta
		_label.position = Vector2((w - bw) * 0.5, (h - bh) * 0.5)
		_label.size = Vector2(bw, bh)
		_label.modulate.a = ta
	if depth <= 0.001:
		return
	# Solid backing ramps in as the shards close so peak cover is total; it
	# fades on withdrawal, so the curtain reads as breaking back into shards
	# that retract over the revealed map.
	var cover: float = smoothstep(0.70, 0.99, depth)
	if cover > 0.0:
		draw_rect(Rect2(0, 0, w, h), Color(SHARD.r, SHARD.g, SHARD.b, cover))
	for edge in 4:
		_draw_curtain(edge, depth, w, h)
