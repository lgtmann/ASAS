extends SceneTree

# Headless balance harness: plays N campaign runs with a scripted baseline
# player (deploy operators, arm spades, fight via unit AI; auto-picks rewards
# and prefers the riverlands path) and reports per-run outcomes.
#
#   godot --headless --script res://tools/autoplay.gd -- runs=6 cap=140

func _initialize() -> void:
	var n_runs := 5
	var cap := 140
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("runs="):
			n_runs = int(arg.trim_prefix("runs="))
		elif arg.begins_with("cap="):
			cap = int(arg.trim_prefix("cap="))
	var results: Array = []
	for r in n_runs:
		print("run %d starting…" % (r + 1))
		var t0: int = Time.get_ticks_msec()
		var res: Dictionary = _play_run(cap)
		print("run %d done in %.1fs" % [r + 1, (Time.get_ticks_msec() - t0) / 1000.0])
		results.append(res)
	print("\n=== AUTOPLAY SUMMARY (%d runs, %d-turn cap) ===" % [n_runs, cap])
	var wins := 0
	var total_area := 0
	for i in results.size():
		var res: Dictionary = results[i]
		if res["won"]:
			wins += 1
		total_area += int(res["area"])
		print("run %d: %-7s area=%d (%s stage %d)  turns=%d  units_alive=%d  %s" % [
			i + 1,
			"WON" if res["won"] else ("DIED" if res["dead"] else "TIMEOUT"),
			res["area"], res["branch"], res["stage"], res["turns"], res["alive"],
			res["note"]])
	print("wins: %d/%d   avg area reached: %.1f" % [wins, n_runs,
		float(total_area) / float(n_runs)])
	quit()

func _play_run(cap: int) -> Dictionary:
	var world = VoxelWorld.new()
	get_root().add_child(world)
	if world.cells.is_empty():
		world._ready()
	var gs = GameState.new()
	gs.setup(world)
	var flags := {"won": false, "cleared": false}
	gs.campaign_won.connect(func(): flags["won"] = true)
	gs.area_cleared.connect(func(_a): flags["cleared"] = true)
	gs.start()
	var note := ""
	var loop_guard := 0
	while gs.turn <= cap and not gs.is_over:
		loop_guard += 1
		if loop_guard > cap * 4:
			break                      # safety: something stopped consuming turns
		_player_turn(gs)
		if flags["won"] or gs.is_over:
			break
		if flags["cleared"]:
			flags["cleared"] = false
			# Auto-reward: magic after bosses, warrior otherwise.
			if gs.last_area_wizard:
				var mo: Array = gs.magic_options()
				if mo.size() > 0:
					gs.grant_magic(mo[0])
			else:
				gs.grant_special("warrior")
			var opts: Array = gs.expansion_options()
			var pick: String = "riverlands" if opts.has("riverlands") else String(opts[0])
			gs.advance_area(pick)
			continue
		gs.end_turn()
		var guard := 0
		while gs.ai_step(1) and guard < 50:
			guard += 1
		if gs.is_over:
			break
		gs.end_turn()
	var dead: bool = gs.team_alive_count(0) == 0
	world.queue_free()
	return {"won": flags["won"], "dead": dead, "area": gs.area,
		"branch": gs.branch if gs.branch != "" else "intro",
		"stage": gs.stage_in_branch, "turns": gs.turn,
		"alive": gs.team_alive_count(0), "note": note}

func _player_turn(gs) -> void:
	# Choice cards: take the first offer.
	for c in gs.hand.duplicate():
		if String(c["category"]) == "choice":
			var opts: Array = gs.choice_options()
			if opts.size() > 0:
				gs.apply_choice(c, opts[0])
	# Deploy every affordable operator-type card.
	var safety := 8
	while safety > 0:
		safety -= 1
		var unit_card = null
		for c in gs.hand:
			if String(c["category"]) == "unit" and int(c["cost"]) <= gs.energy:
				unit_card = c
				break
		if unit_card == null:
			break
		var pts: Array = gs.placement_targets()
		if pts.is_empty():
			break
		gs.play_combo_at([unit_card], pts[0])
	# Arm spades.
	safety = 8
	while safety > 0:
		safety -= 1
		var sp = null
		for c in gs.hand:
			if String(c["id"]) == "spade" and int(c["cost"]) <= gs.energy:
				sp = c
				break
		if sp == null:
			break
		var tg: Array = gs.combo_targets([sp])
		if tg.is_empty():
			break
		gs.play_combo_at([sp], tg[0])
	# Apply upgrade cards (heads/shafts/handles/operator perks) like a human.
	safety = 8
	while safety > 0:
		safety -= 1
		var up_card = null
		for c in gs.hand:
			if String(c["category"]) in ["head", "shaft", "handle", "operator_upgrade"] \
					and int(c["cost"]) <= gs.energy:
				up_card = c
				break
		if up_card == null:
			break
		var ut: Array = gs.upgrade_targets(up_card)
		if ut.is_empty():
			break
		gs.play_upgrade_at(up_card, ut[0])
	# Fight/advance with the built-in unit AI.
	var guard := 0
	while gs.ai_step(0) and guard < 50:
		guard += 1
