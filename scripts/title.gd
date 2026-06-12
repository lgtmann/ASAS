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

	Sfx.ambient_start()
	Meta.load_meta()

	if Meta.RunSave.exists():
		var cont := Button.new()
		cont.text = "Continue Run"
		cont.position = Vector2(660, 552)
		cont.size = Vector2(280, 46)
		cont.add_theme_font_size_override("font_size", 18)
		cont.pressed.connect(func():
			Meta.RunSave.pending_load = true
			get_tree().change_scene_to_file("res://scenes/main.tscn"))
		add_child(cont)

	var schem := Button.new()
	schem.text = "Schematics (%d coins)" % Meta.coins
	schem.position = Vector2(660, 606)
	schem.size = Vector2(280, 46)
	schem.add_theme_font_size_override("font_size", 17)
	schem.pressed.connect(_open_schematics)
	add_child(schem)

	var anims := Button.new()
	anims.text = "See Animations"
	anims.position = Vector2(660, 660)
	anims.size = Vector2(280, 44)
	anims.add_theme_font_size_override("font_size", 17)
	anims.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/anim_viewer.tscn"))
	add_child(anims)

	var vol_label := Label.new()
	vol_label.text = "Volume"
	vol_label.add_theme_font_size_override("font_size", 15)
	vol_label.add_theme_color_override("font_outline_color", Color(0.16, 0.10, 0.05))
	vol_label.add_theme_constant_override("outline_size", 4)
	vol_label.position = Vector2(660, 718)
	add_child(vol_label)
	var vol := HSlider.new()
	vol.min_value = 0.0
	vol.max_value = 1.0
	vol.step = 0.05
	vol.value = Sfx.volume
	vol.position = Vector2(730, 720)
	vol.size = Vector2(210, 20)
	vol.value_changed.connect(func(v): Sfx.set_volume(v))
	vol.drag_ended.connect(func(_ch): Sfx.play("click", 0.0))
	add_child(vol)

var _shop: Panel = null

func _schem_art(id: String) -> Texture2D:
	for c in ["res://assets/cards/building_%s.png" % id,
			"res://assets/cards/unit_%s.png" % id,
			"res://assets/cards/%s.png" % id]:
		if ResourceLoader.exists(c):
			return load(c)
	return null

func _schem_title(id: String) -> String:
	if GameState.STRUCTURES.has(id):
		return String(GameState.STRUCTURES[id]["title"])
	if GameState.UPGRADES.has(id):
		return String(GameState.UPGRADES[id]["title"])
	return id.capitalize()

# The schematics shop: every blueprint as a tile — owned, buyable, or too
# expensive. Coins persist across runs; buying unlocks the blueprint in the
# in-run Build menu forever.
func _open_schematics() -> void:
	if _shop != null:
		_shop.queue_free()
	Meta.load_meta()
	var bps: Array = GameState.BLUEPRINTS
	var cols := 6
	var rows: int = int(ceil(float(bps.size()) / float(cols)))
	var tile_w := 150.0
	var tile_h := 128.0
	_shop = Panel.new()
	_shop.size = Vector2(50.0 + cols * tile_w, 96.0 + rows * tile_h)
	_shop.position = Vector2((1600.0 - _shop.size.x) * 0.5,
		(900.0 - _shop.size.y) * 0.5)
	add_child(_shop)
	var title := Label.new()
	title.text = "Schematics — %d coins" % Meta.coins
	title.add_theme_font_size_override("font_size", 22)
	title.position = Vector2(24, 16)
	_shop.add_child(title)
	var closer := Button.new()
	closer.text = "X"
	closer.position = Vector2(_shop.size.x - 52, 12)
	closer.size = Vector2(38, 32)
	closer.pressed.connect(func():
		_shop.queue_free()
		_shop = null)
	_shop.add_child(closer)
	for i in bps.size():
		var id: String = String(bps[i]["id"])
		var tx: float = 26.0 + (i % cols) * tile_w
		var ty: float = 62.0 + float(i / cols) * tile_h
		var owned: bool = Meta.is_unlocked(id)
		var afford: bool = Meta.coins >= Meta.price(id)
		var tile := Panel.new()
		tile.position = Vector2(tx, ty)
		tile.size = Vector2(tile_w - 10.0, tile_h - 10.0)
		if not owned and not afford:
			tile.modulate = Color(0.55, 0.55, 0.55)
		_shop.add_child(tile)
		var art: Texture2D = _schem_art(id)
		if art != null:
			var tr := TextureRect.new()
			tr.texture = art
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.position = Vector2(8, 4)
			tr.size = Vector2(tile_w - 26.0, 62.0)
			if not owned:
				tr.modulate = Color(0.45, 0.45, 0.45)
			tile.add_child(tr)
		var nm := Label.new()
		nm.text = _schem_title(id)
		nm.add_theme_font_size_override("font_size", 11)
		nm.position = Vector2(6, 68)
		nm.size = Vector2(tile_w - 22.0, 16)
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nm.clip_text = true
		tile.add_child(nm)
		var status := Label.new()
		status.text = "OWNED" if owned else "%d coins" % Meta.price(id)
		status.add_theme_font_size_override("font_size", 12)
		status.add_theme_color_override("font_color",
			Color(0.55, 0.95, 0.55) if owned
			else (Color(1.0, 0.9, 0.4) if afford else Color(0.9, 0.55, 0.45)))
		status.position = Vector2(6, 86)
		status.size = Vector2(tile_w - 22.0, 16)
		status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tile.add_child(status)
		if not owned and afford:
			var hit := Button.new()
			hit.flat = true
			hit.size = tile.size
			var buy_id: String = id
			hit.pressed.connect(func():
				if Meta.buy_schematic(buy_id):
					Sfx.play("build", 0.0)
					_open_schematics())
			tile.add_child(hit)

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
