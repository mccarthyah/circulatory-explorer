extends SceneTree
## Software OpenGL smoke test for CI. It is not a performance benchmark.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless" or RenderingServer.get_current_rendering_method() != "gl_compatibility":
		printerr("FAIL: expected a graphical Compatibility renderer")
		quit(1)
		return
	var settings_path := OS.get_environment("EXPLORER_SETTINGS_PATH")
	if settings_path.is_empty():
		printerr("EXPLORER_SETTINGS_PATH must point to an isolated settings file")
		quit(1)
		return
	var cf := ConfigFile.new()
	cf.set_value("graphics", "quality", "performance")
	if cf.save(settings_path) != OK:
		quit(1)
		return
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 900:
		await process_frame
		if main._intro_done:
			break
	if not main._intro_done:
		printerr("FAIL: scene startup")
		quit(1)
		return
	# Exercise actual event dispatch into Godot's GUI, not just action matching.
	await _press_button(JOY_BUTTON_START)
	if not main._controller_menu or root.gui_get_focus_owner() != main.hud.mode_buttons["free"]:
		printerr("FAIL: controller did not focus menu")
		quit(1)
		return
	await _press_button(JOY_BUTTON_DPAD_RIGHT)
	if root.gui_get_focus_owner() != main.hud.mode_buttons["tour"]:
		printerr("FAIL: controller could not navigate to tour button")
		quit(1)
		return
	await _press_button(JOY_BUTTON_A)
	if main.mode != "tour" or not main._controller_menu:
		printerr("FAIL: controller could not activate tour button")
		quit(1)
		return
	await _press_button(JOY_BUTTON_START)
	if main._controller_menu or root.gui_get_focus_owner() != null:
		printerr("FAIL: controller could not close menu")
		quit(1)
		return
	main._on_mode_requested("free")
	var before: Vector3 = main.cam.position
	var motion := InputEventJoypadMotion.new()
	motion.device = 0
	motion.axis = JOY_AXIS_LEFT_Y
	motion.axis_value = -1.0
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	main.cam._process(0.2)
	if main.cam.position.distance_to(before) < 0.1:
		printerr("FAIL: dispatched controller stick did not move camera")
		quit(1)
		return
	motion = InputEventJoypadMotion.new()
	motion.device = 0
	motion.axis = JOY_AXIS_LEFT_Y
	motion.axis_value = 0.0
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	for q in ["performance", "balanced"]:
		main.apply_quality(q, true)
		for mode in ["free", "tour", "interior"]:
			main._on_mode_requested(mode)
			main._fly = {}
			if mode != "free":
				main.path.seek_fraction(0.3)
				main.path.stop()
			for i in 12:
				await process_frame
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			if image == null or image.is_empty() or image.get_width() < 1 or image.get_height() < 1:
				printerr("FAIL: no image for ", q, " ", mode)
				quit(1)
				return
			print("render smoke: ", q, " ", mode, " ", image.get_size())
	print("PASS: Compatibility render smoke (", RenderingServer.get_video_adapter_name(), ")")
	quit(0)


func _press_button(index: JoyButton) -> void:
	var event := InputEventJoypadButton.new()
	event.device = 0
	event.button_index = index
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	var release := InputEventJoypadButton.new()
	release.device = 0
	release.button_index = index
	release.pressed = false
	Input.parse_input_event(release)
	await process_frame
