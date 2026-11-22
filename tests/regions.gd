extends SceneTree

var failures := 0
func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL: ", message)

func _run() -> void:
	check(ProjectSettings.get_setting("application/run/main_scene") == "res://scenes/start.tscn", "project starts at menu")
	# Simulate the editor's Run Current Scene on main.tscn: it must redirect
	# before it instantiates a model, rather than bypassing the menu.
	var direct = load("res://scenes/main.tscn").instantiate()
	root.add_child(direct)
	current_scene = direct
	check(direct.model == null and direct.hud == null, "direct scene has not loaded anatomy")
	for i in 20:
		await process_frame
		if current_scene != direct and current_scene != null:
			break
	var menu = current_scene
	if menu == direct or menu == null:
		check(false, "direct scene redirects to menu")
		quit(1)
		return
	await process_frame
	check(menu.buttons.size() == 5, "five main menu choices")
	check(menu.get_node_or_null("Anatomy") == null, "menu does not instantiate a model")
	for choice in ["torso", "lower", "head", "heart", "all"]:
		menu.buttons[choice].pressed.emit()
		for i in 900:
			await process_frame
			if current_scene != menu and current_scene != null and current_scene.get("_intro_done"):
				break
		var main = current_scene
		if main == menu or main == null or not main.get("_intro_done"):
			check(false, "load selection " + choice)
			quit(1)
			return
		check(main.region == choice and main.model.region == choice, "correct selection " + choice)
		check(main.model.detail == 0 and is_equal_approx(root.scaling_3d_scale, 0.5), "regional graphics lock " + choice)
		if choice != "all":
			check(main.model.context_root == null and main.model.supplemental_root == null, "region does not load full-body assets " + choice)
			check(main.model.extended_root == null, "extra vessels start unloaded " + choice)
			check(main.hud.mode_buttons["tour"].disabled and main.hud.mode_buttons["interior"].disabled, "full-body routes disabled " + choice)
			check(main.hud.context_check.disabled, "full-body context disabled " + choice)
			main._on_mode_requested("tour")
			check(main.mode == "free", "tour shortcut blocked " + choice)
			var extra := ""
			for part in main.model.parts:
				if part.get("extended", false):
					extra = part.id
					break
			check(not extra.is_empty(), "regional extra exists " + choice)
			if not extra.is_empty():
				main._on_part_picked(extra)
				check(main.model.is_extended_visible() and main.model.by_id[extra]["node"] != null, "regional extra loads on selection " + choice)
				check(main.model.extended_root.get_child_count() < 410, "uses regional extra file " + choice)
			if choice == "torso": check(not main.model.by_id.has("FJ2271"), "torso excludes brachial artery")
			if choice == "heart": check(main.model.by_id.has("FJ2655") and not main.model.by_id.has("FJ2143"), "heart includes coronary sinus, excludes femoral artery")
			if choice == "lower": check(main.model.by_id.has("FJ2143") and not main.model.by_id.has("FJ2655"), "lower includes femoral artery, excludes coronary sinus")
		else:
			check(main.model.parts.size() == 1095 and main.model.context_root != null, "all loads original full model")
		main._return_to_menu()
		for i in 10:
			await process_frame
			if current_scene != main and current_scene != null:
				break
		menu = current_scene
		check(menu != main and menu.get_node_or_null("Anatomy") == null, "return unloads model " + choice)
	if failures == 0:
		print("PASS: main menu and regional loading")
	quit(1 if failures else 0)
