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
	{"name": "Operator: Dig", "action": "dig"},
	{"name": "Operator: Swing", "action": "swing"},
	{"name": "Operator: Throw", "action": "throw"},
	{"name": "Operator: Fish", "action": "fish"},
	{"name": "Jankovics Probe (shader)", "shader": true},
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
var action_stage: Control
var shader_stage: ColorRect
var _shader_mat: ShaderMaterial
var _shader_mode: bool = false
var _shader_t: float = 0.0
var _action_type: String = ""
var _act_t: float = -0.25       # idle hold, then the action cycle
var _act_tex: Dictionary = {}
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
			["spade", "res://assets/cards/ballista_spade_loaded.png"]]:
		if ResourceLoader.exists(entry[1]):
			_rig_tex[entry[0]] = load(entry[1])

	# Action stage: replays the shared SpadeActions pose math, scaled up.
	action_stage = Control.new()
	action_stage.position = stage.position
	action_stage.size = stage.size
	action_stage.draw.connect(_draw_action_stage)
	stage.get_parent().add_child(action_stage)
	for entry in [["operator", "res://assets/cards/unit_operator.png"],
			["spade", "res://assets/cards/spade.png"]]:
		if ResourceLoader.exists(entry[1]):
			_act_tex[entry[0]] = load(entry[1])

	# Shader stage: a full-rect ColorRect running the Jankovics probe shader.
	shader_stage = ColorRect.new()
	shader_stage.position = stage.position
	shader_stage.size = stage.size
	if ResourceLoader.exists("res://assets/jankovics_probe.gdshader"):
		_shader_mat = ShaderMaterial.new()
		_shader_mat.shader = load("res://assets/jankovics_probe.gdshader")
		shader_stage.material = _shader_mat
	shader_stage.visible = false
	stage.get_parent().add_child(shader_stage)

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
		_act_t = shot_t
		_shader_t = shot_t
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("t", shot_t)
		rig_stage.queue_redraw()
		action_stage.queue_redraw()
		_shot_and_quit(shot_path)

# Draw the operator + spade prop at stage scale, replaying the exact pose
# math the game uses. Throw also shows the projectile leg so the two-asset
# handoff is visible.
func _draw_action_stage() -> void:
	var k := 6.0                                    # rescaled from unit_h below
	var feet := Vector2(action_stage.size.x * 0.42, action_stage.size.y * 0.80)
	var tt: float = clampf(_act_t, 0.0, 1.0)
	# Ground line.
	action_stage.draw_line(feet + Vector2(-170, 16), feet + Vector2(240, 16),
		Color(0.22, 0.14, 0.09, 0.55), 4.0, true)
	if _action_type == "fish":
		# Water hint to the right.
		action_stage.draw_rect(Rect2(feet.x + 90, feet.y - 4, 170, 40),
			Color(0.18, 0.46, 0.82, 0.75))
		action_stage.draw_line(feet + Vector2(90, -4), feet + Vector2(260, -4),
			Color(0.07, 0.16, 0.34), 3.0, true)
	# Body: the SAME rig the game draws, at stage height. One scale factor
	# (unit_h -> k) drives rig and prop together, so proportions are exact.
	var unit_h := 480.0
	var game_unit_h: float = 64.0 * 0.85 / OperatorRig.FRAME_ASPECT
	k = unit_h / game_unit_h
	if OperatorRig.ready():
		var pose: Dictionary = {}
		if _act_t >= 0.0:
			pose = OperatorRig.action_pose(_action_type, tt, Vector2.RIGHT, 0.0)
		OperatorRig.draw(action_stage, feet, unit_h, pose, Color.WHITE)
	else:
		var body: Texture2D = _act_tex.get("operator")
		if body != null:
			var bh := unit_h
			var bw: float = bh * float(body.get_width()) / float(body.get_height())
			action_stage.draw_texture_rect(body,
				Rect2(feet.x - bw * 0.5, feet.y - bh, bw, bh), false)
	# Spade prop via the shared pose math.
	var spade: Texture2D = _act_tex.get("spade")
	if spade != null:
		var pose: Variant
		if _act_t < 0.0:
			pose = {"off": Vector2(10.0, -12.0), "rot": -0.30, "flip": false}
		else:
			pose = SpadeActions.prop_pose(_action_type, tt, Vector2.RIGHT)
		if pose != null:
			var w: float = 17.0 * k
			var h: float = w * float(spade.get_height()) / float(spade.get_width())
			action_stage.draw_set_transform(feet + pose["off"] * k, float(pose["rot"]), Vector2.ONE)
			action_stage.draw_texture_rect(spade, Rect2(-w * 0.5, -h * 0.58, w, h), false)
			action_stage.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		# Throw: the projectile leg after release.
		var rel: float = SpadeActions.THROW_WINDUP / float(SpadeActions.DUR["throw"])
		if _action_type == "throw" and _act_t >= rel:
			var u: float = clampf((tt - rel) / (1.0 - rel), 0.0, 1.0)
			var start: Vector2 = feet + Vector2(-9.0, -20.0) * k * 0.2
			var endp: Vector2 = feet + Vector2(330.0, -40.0)
			var pos: Vector2 = start.lerp(endp, u) + Vector2(0, -110.0 * sin(u * PI))
			var w2 := 40.0
			var h2: float = w2 * float(spade.get_height()) / float(spade.get_width())
			action_stage.draw_set_transform(pos, u * TAU * 2.0, Vector2.ONE)
			action_stage.draw_texture_rect(spade, Rect2(-w2 * 0.5, -h2 * 0.5, w2, h2), false)
			action_stage.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _shot_and_quit(out_path: String) -> void:
	await get_tree().create_timer(0.5).timeout
	get_viewport().get_texture().get_image().save_png(out_path)
	print("SCREENSHOT_SAVED: %s" % out_path)
	get_tree().quit()

func _load_anim(i: int) -> void:
	var a: Dictionary = ANIMATIONS[i]
	_anim_name = String(a["name"])
	_rig_mode = bool(a.get("rig", false))
	_shader_mode = bool(a.get("shader", false))
	_action_type = String(a.get("action", ""))
	if rig_stage != null:
		rig_stage.visible = _rig_mode
	if action_stage != null:
		action_stage.visible = _action_type != ""
	if shader_stage != null:
		shader_stage.visible = _shader_mode
	stage.visible = not _rig_mode and not _shader_mode and _action_type == ""
	if _shader_mode:
		_shader_t = 0.0
		info.text = "%s   |   metamorphosis + colour-cycle + radial ornament" % _anim_name
		return
	if _rig_mode:
		_rig_t = -0.3
		info.text = "%s   |   %s" % [_anim_name, BallistaRig.phase_name(_rig_t)]
		return
	if _action_type != "":
		_act_t = -0.25
		info.text = "%s   |   %s" % [_anim_name, SpadeActions.phase_name(_action_type, _act_t)]
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
	if _shader_mode:
		_shader_t = fmod(_shader_t + 0.04, 1.0)
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("t", _shader_t)
		info.text = "%s   |   t=%.2f" % [_anim_name, _shader_t]
		return
	if _action_type != "":
		_act_t += 0.04
		if _act_t > 1.2:
			_act_t = -0.25
		action_stage.queue_redraw()
		info.text = "%s   |   t=%.2f   |   %s" % [_anim_name, _act_t,
			SpadeActions.phase_name(_action_type, _act_t)]
		return
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
	if _shader_mode:
		_shader_t = fmod(_shader_t + delta * _speed * 0.18, 1.0)
		if _shader_mat != null:
			_shader_mat.set_shader_parameter("t", _shader_t)
		info.text = "%s   |   t=%.2f   |   %.2fx" % [_anim_name, _shader_t, _speed]
		return
	if _action_type != "":
		_act_t += delta * _speed / float(SpadeActions.DUR.get(_action_type, 0.6))
		if _act_t > 1.35:
			_act_t = -0.25
		action_stage.queue_redraw()
		info.text = "%s   |   t=%.2f   |   %s" % [_anim_name, _act_t,
			SpadeActions.phase_name(_action_type, _act_t)]
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
