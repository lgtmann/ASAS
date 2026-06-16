class_name BattleIntro
extends Control

# Battle-start flourish (full-shader). A single fragment shader (battle_intro
# .gdshader) draws jagged blue shard curtains crawling in over a grainy
# starfield with a glowing folk sun-emblem; this script just drives the
# `progress` uniform through three phases and overlays the gold title.
#
#   SLAM    progress 0→1 fast (a hitch here is hidden — it's brief)
#   HOLD    progress = 1, opaque cover; waits for the scene to settle so the
#           heavy first-load frames pass behind black, then for a min hold
#   WITHDRAW progress 1→0; COLOR.a falls with it, revealing the map
#
# `begin_reveal()` (called by iso_view once terrain has rendered) unlocks the
# withdrawal. A fallback timer unlocks it anyway so the intro can't hang.

signal revealed

const SLAM_DUR := 0.22
const MIN_HOLD := 0.35
const WITHDRAW_DUR := 0.75
const FALLBACK_REVEAL := 2.5      # auto-unlock if nobody calls begin_reveal()

var _title := "ENGAGE THE ENEMY"
var _phase := 0                   # 0 slam, 1 hold, 2 withdraw
var _elapsed := 0.0
var _hold := 0.0
var _reveal_allowed := false
var _frozen := false
var _frozen_p := 1.0
var _rect: ColorRect
var _mat: ShaderMaterial
var _label: Label

func setup(title: String) -> void:
	_title = title

func begin_reveal() -> void:
	_reveal_allowed = true

func freeze_at(p: float) -> void:
	_frozen = true
	_frozen_p = p           # applied in _ready once the material exists

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_rect = ColorRect.new()
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists("res://assets/battle_intro.gdshader"):
		_mat = ShaderMaterial.new()
		_mat.shader = load("res://assets/battle_intro.gdshader")
		_rect.material = _mat
	add_child(_rect)
	_label = Label.new()
	_label.text = _title
	_label.add_theme_font_size_override("font_size", 62)
	_label.add_theme_color_override("font_color", Color(0.96, 0.82, 0.40))
	_label.add_theme_color_override("font_outline_color", Color(0.04, 0.03, 0.06))
	_label.add_theme_constant_override("outline_size", 12)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	_update_aspect()
	resized.connect(_update_aspect)
	_set_progress(_frozen_p if _frozen else 0.0)
	if not _frozen:
		Sfx.play("quake", 0.0, 0.0)

func _update_aspect() -> void:
	if _mat != null and size.y > 0.0:
		_mat.set_shader_parameter("aspect", size.x / size.y)
	if _label != null:
		var bw := 760.0
		var bh := 150.0
		_label.position = Vector2((size.x - bw) * 0.5, (size.y - bh) * 0.5)
		_label.size = Vector2(bw, bh)

func _set_progress(p: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter("progress", p)
	if _label != null:
		_label.modulate.a = clampf((p - 0.3) / 0.5, 0.0, 1.0)

func _process(delta: float) -> void:
	if _frozen:
		return
	_elapsed += delta
	match _phase:
		0:
			var k: float = clampf(_elapsed / SLAM_DUR, 0.0, 1.0)
			_set_progress(1.0 - pow(1.0 - k, 3.0))      # ease-out slam
			if k >= 1.0:
				_phase = 1
				_hold = 0.0
		1:
			_set_progress(1.0)
			_hold += delta
			if (_reveal_allowed and _hold >= MIN_HOLD) or _hold >= FALLBACK_REVEAL:
				_phase = 2
				_elapsed = 0.0
		2:
			var k2: float = clampf(_elapsed / WITHDRAW_DUR, 0.0, 1.0)
			_set_progress(1.0 - (k2 * k2))              # ease-in snap back
			if k2 >= 1.0:
				revealed.emit()
				queue_free()
