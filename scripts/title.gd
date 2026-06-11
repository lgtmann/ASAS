extends Control

# Title screen: Play Game / See Animations. WW-styled with existing art as
# set dressing. The art-pipeline harness (--screenshot / --showcase flags)
# skips the title entirely and boots the game scene.

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--screenshot=") or arg.begins_with("--seed=") \
				or arg == "--showcase" or arg == "--showcase-built":
			get_tree().change_scene_to_file.call_deferred("res://scenes/main.tscn")
			return
	_build_ui()
	for arg in args:
		if arg.begins_with("--title-shot="):
			_screenshot_and_quit(arg.trim_prefix("--title-shot="))

func _build_ui() -> void:
	# Corner set dressing from the game's own art.
	_decor("res://assets/cards/tree_1.png", Vector2(70, 290), Vector2(300, 450))
	_decor("res://assets/cards/tree_2.png", Vector2(1240, 310), Vector2(290, 430))
	_decor("res://assets/cards/ballista.png", Vector2(1050, 600), Vector2(240, 240))
	_decor("res://assets/cards/boulder.png", Vector2(330, 650), Vector2(180, 180))
	_decor("res://assets/cards/unit_operator.png", Vector2(500, 560), Vector2(180, 270))

	# Floating spade emblem above the title, with a gentle idle bob.
	var spade := _decor("res://assets/cards/spade.png", Vector2(690, 60), Vector2(220, 220))
	if spade != null:
		var tw := create_tween().set_loops()
		tw.tween_property(spade, "position:y", 72.0, 1.4) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(spade, "position:y", 60.0, 1.4) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	var title := Label.new()
	title.text = "A SPADE'S A SPADE"
	title.add_theme_font_size_override("font_size", 72)
	title.add_theme_color_override("font_outline_color", Color(0.16, 0.10, 0.05))
	title.add_theme_constant_override("outline_size", 14)
	title.position = Vector2(0, 290)
	title.size = Vector2(1600, 90)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	var sub := Label.new()
	sub.text = "dig - build - conquer"
	sub.add_theme_font_size_override("font_size", 22)
	sub.add_theme_color_override("font_outline_color", Color(0.16, 0.10, 0.05))
	sub.add_theme_constant_override("outline_size", 6)
	sub.position = Vector2(0, 372)
	sub.size = Vector2(1600, 30)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(sub)

	var play := Button.new()
	play.text = "Play Game"
	play.position = Vector2(660, 480)
	play.size = Vector2(280, 64)
	play.add_theme_font_size_override("font_size", 24)
	for state in [["normal", Color(0.27, 0.52, 0.23)], ["hover", Color(0.34, 0.62, 0.28)],
			["pressed", Color(0.21, 0.42, 0.18)]]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = state[1]
		sb.border_color = Color(0.12, 0.26, 0.10)
		sb.set_border_width_all(2)
		sb.border_width_bottom = 4
		sb.set_corner_radius_all(10)
		sb.set_content_margin_all(10)
		play.add_theme_stylebox_override(state[0], sb)
	play.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main.tscn"))
	add_child(play)

	var anims := Button.new()
	anims.text = "See Animations"
	anims.position = Vector2(660, 564)
	anims.size = Vector2(280, 52)
	anims.add_theme_font_size_override("font_size", 19)
	anims.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/anim_viewer.tscn"))
	add_child(anims)

func _decor(path: String, pos: Vector2, sz: Vector2) -> TextureRect:
	if not ResourceLoader.exists(path):
		return null
	var tr := TextureRect.new()
	tr.texture = load(path)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.position = pos
	tr.size = sz
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tr)
	return tr

func _screenshot_and_quit(out_path: String) -> void:
	await get_tree().create_timer(0.9).timeout
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(out_path)
	print("SCREENSHOT_SAVED: %s" % out_path)
	get_tree().quit()
