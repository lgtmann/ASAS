extends Control

# Animation viewer: pick an animation from the left rail, watch it loop on
# the big stage. Speed controls + frame readout make it a judging tool for
# the art pipeline as much as a gallery. Add new entries to ANIMATIONS as
# frame cycles come out of the generator.

const ANIMATIONS := [
	{
		"name": "Ballista (RIG)",
		"rig": true,
	},
	{
		"name": "Ballista Fire (16f)",
		"frames": [
			"res://assets/cards/ballista_f01.png",
			"res://assets/cards/ballista_f02.png",
			"res://assets/cards/ballista_f03.png",
			"res://assets/cards/ballista_f04.png",
			"res://assets/cards/ballista_f05.png",
			"res://assets/cards/ballista_f06.png",
			"res://assets/cards/ballista_f07.png",
			"res://assets/cards/ballista_f08.png",
			"res://assets/cards/ballista_f09.png",
			"res://assets/cards/ballista_f10.png",
			"res://assets/cards/ballista_f11.png",
			"res://assets/cards/ballista_f12.png",
			"res://assets/cards/ballista_f13.png",
			"res://assets/cards/ballista_f14.png",
			"res://assets/cards/ballista_f15.png",
			"res://assets/cards/ballista_f16.png",
		],
		"labels": ["rest", "draw 15%", "draw 30%", "draw 45%", "draw 60%", "draw 75%", "draw 90%", "max draw", "RELEASE", "rebound", "vibration 3", "vibration 2", "vibration 1", "settle + dust", "dust fades", "rest"],
		"times": [0.07, 0.07, 0.07, 0.07, 0.07, 0.07, 0.07, 0.09, 0.045, 0.045, 0.06, 0.06, 0.06, 0.09, 0.09, 0.09],
	},
]

var _frames: Array = []
var _labels: Array = []
var _times: Array = []
var _anim_name: String = ""
var _idx: int = 0
var _t: float = 0.0
var _speed: float = 1.0
var _playing: bool = true

var stage: TextureRect
var rig_stage: Control
var _rig_mode: bool = false
var _rig_t: float = -0.3        # idle hold before the cycle starts
var _rig_tex: Dictionary = {}
var info: Label
var play_btn: Button

func _ready() -> void:
	var title := Label.new()
	title.text = "Animation Viewer"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_outline_color", Color(0.16, 0.10, 0.05))
	title.add_theme_constant_override("outline_size", 8)
	title.position = Vector2(40, 24)
	add_child(title)

	var back := Button.new()
	back.text = "< Title"
	back.position = Vector2(1460, 24)
	back.size = Vector2(110, 40)
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/title.tscn"))
	add_child(back)

	# Left rail: one button per registered animation.
	for i in ANIMATIONS.size():
		var a: Dictionary = ANIMATIONS[i]
		var b := Button.new()
		b.text = String(a["name"])
		b.position = Vector2(40, 90 + i * 48)
		b.size = Vector2(220, 40)
		b.pressed.connect(_load_anim.bind(i))
		add_child(b)

	# Stage: dark panel + big texture view.
	var panel := Panel.new()
	panel.position = Vector2(420, 90)
	panel.size = Vector2(760, 640)
	add_child(panel)
	stage = TextureRect.new()
	stage.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stage.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	stage.position = Vector2(40, 30)
	stage.size = Vector2(680, 560)
	panel.add_child(stage)

	info = Label.new()
	info.add_theme_font_size_override("font_size", 18)
	info.add_theme_color_override("font_outline_color", Color(0.16, 0.10, 0.05))
	info.add_theme_constant_override("outline_size", 5)
	info.position = Vector2(420, 744)
	info.size = Vector2(760, 30)
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(info)

	# Controls row.
	play_btn = Button.new()
	play_btn.text = "Pause"
	play_btn.position = Vector2(620, 790)
	play_btn.size = Vector2(110, 44)
	play_btn.pressed.connect(_toggle_play)
	add_child(play_btn)
	var speeds := [["0.25x", 0.25], ["0.5x", 0.5], ["1x", 1.0]]
	for i in speeds.size():
		var sp: Array = speeds[i]
		var sb := Button.new()
		sb.text = String(sp[0])
		sb.position = Vector2(750 + i * 80, 790)
		sb.size = Vector2(70, 44)
		sb.pressed.connect(func(): _speed = float(sp[1]))
		add_child(sb)
	var step := Button.new()
	step.text = "Step >"
	step.position = Vector2(1010, 790)
	step.size = Vector2(96, 44)
	step.pressed.connect(func():
		_playing = false
		play_btn.text = "Play"
		_advance())
	add_child(step)

	# Rig stage: custom-draw control sharing the frame stage's footprint.
	rig_stage = Control.new()
	rig_stage.position = stage.position
	rig_stage.size = stage.size
	rig_stage.draw.connect(func():
		var sz: float = minf(rig_stage.size.x, rig_stage.size.y)
		var rect := Rect2((rig_stage.size.x - sz) * 0.5, (rig_stage.size.y - sz) * 0.5, sz, sz)
		BallistaRig.draw(rig_stage, rect, _rig_t, _rig_tex))
	stage.get_parent().add_child(rig_stage)
	for entry in [["body", "res://assets/cards/ballista_body.png"],
			["bow", "res://assets/cards/ballista_arm_left.png"],
			["spade", "res://assets/cards/spade.png"]]:
		if ResourceLoader.exists(entry[1]):
			_rig_tex[entry[0]] = load(entry[1])

	_load_anim(0)
	# Tuning harness: --anim-shot=path [--anim-idx=N] [--anim-t=f]
	var shot_path := ""
	var shot_t := 0.5
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--anim-shot="):
			shot_path = arg.trim_prefix("--anim-shot=")
		elif arg.begins_with("--anim-idx="):
			_load_anim(int(arg.trim_prefix("--anim-idx=")))
		elif arg.begins_with("--anim-t="):
			shot_t = float(arg.trim_prefix("--anim-t="))
	if shot_path != "":
		_playing = false
		_rig_t = shot_t
		rig_stage.queue_redraw()
		_shot_and_quit(shot_path)

func _shot_and_quit(out_path: String) -> void:
	await get_tree().create_timer(0.5).timeout
	get_viewport().get_texture().get_image().save_png(out_path)
	print("SCREENSHOT_SAVED: %s" % out_path)
	get_tree().quit()

func _load_anim(i: int) -> void:
	var a: Dictionary = ANIMATIONS[i]
	_anim_name = String(a["name"])
	_rig_mode = bool(a.get("rig", false))
	if rig_stage != null:
		rig_stage.visible = _rig_mode
	stage.visible = not _rig_mode
	if _rig_mode:
		_rig_t = -0.3
		info.text = "%s   |   %s" % [_anim_name, BallistaRig.phase_name(_rig_t)]
		return
	_frames.clear()
	_labels.clear()
	_times.clear()
	for j in a["frames"].size():
		var path: String = a["frames"][j]
		if ResourceLoader.exists(path):
			_frames.append(load(path))
			_labels.append(a["labels"][j])
			_times.append(a["times"][j])
	_idx = 0
	_t = 0.0
	_show_frame()

func _toggle_play() -> void:
	_playing = not _playing
	play_btn.text = "Pause" if _playing else "Play"

func _advance() -> void:
	if _rig_mode:
		_rig_t += 0.04
		if _rig_t > 1.1:
			_rig_t = -0.3
		rig_stage.queue_redraw()
		info.text = "%s   |   t=%.2f   |   %s" % [_anim_name, _rig_t, BallistaRig.phase_name(_rig_t)]
		return
	if _frames.is_empty():
		return
	_idx = (_idx + 1) % _frames.size()
	_t = 0.0
	_show_frame()

func _show_frame() -> void:
	if _frames.is_empty():
		info.text = "%s — no frames found" % _anim_name
		return
	stage.texture = _frames[_idx]
	info.text = "%s   |   frame %d/%d  (%s)   |   %.2fs   |   %.2fx" % \
		[_anim_name, _idx + 1, _frames.size(), _labels[_idx], _times[_idx], _speed]

func _process(delta: float) -> void:
	if not _playing:
		return
	if _rig_mode:
		_rig_t += delta * _speed / BallistaRig.DUR
		if _rig_t > 1.25:
			_rig_t = -0.3
		rig_stage.queue_redraw()
		info.text = "%s   |   t=%.2f   |   %s" % [_anim_name, _rig_t, BallistaRig.phase_name(_rig_t)]
		return
	if _frames.is_empty():
		return
	_t += delta * _speed
	if _t >= float(_times[_idx]):
		_advance()
