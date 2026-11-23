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
	var menu = load("res://scenes/start.tscn").instantiate()
	root.add_child(menu)
	current_scene = menu
	await process_frame
	await process_frame
	if menu.get_node_or_null("Anatomy") != null or root.gui_get_focus_owner() != menu.buttons["torso"]:
		printerr("FAIL: menu startup or initial controller focus")
		quit(1)
		return
	menu.credits_button.pressed.emit()
	await process_frame
	if menu.credits_dialog == null or not menu.credits_dialog.visible:
		printerr("FAIL: menu credits did not open")
		quit(1)
		return
	await RenderingServer.frame_post_draw
	if root.get_texture().get_image().is_empty():
		printerr("FAIL: credits dialog did not render")
		quit(1)
		return
	menu.credits_dialog.hide()
	menu.buttons["torso"].grab_focus()
	await _press_button(JOY_BUTTON_A)
	for i in 900:
		await process_frame
		if current_scene != menu and current_scene != null and current_scene.get("_intro_done"):
			break
	var regional = current_scene
	if regional == menu or regional == null or not regional.get("_intro_done") or regional.region != "torso":
		printerr("FAIL: controller menu did not load torso")
		quit(1)
		return
	if regional.model.context_root != null or not regional.hud.mode_buttons["tour"].disabled:
		printerr("FAIL: regional view loaded full-body context or tour")
		quit(1)
		return
	regional.apply_quality("balanced", true)
	if regional.model.detail != 1:
		printerr("FAIL: focused view could not switch to balanced")
		quit(1)
		return
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	if root.get_texture().get_image().is_empty():
		printerr("FAIL: regional render")
		quit(1)
		return
	regional._return_to_menu()
	for i in 20:
		await process_frame
		if current_scene != regional and current_scene != null:
			break
	menu = current_scene
	menu.buttons["all"].grab_focus()
	await _press_button(JOY_BUTTON_A)
	for i in 900:
		await process_frame
		if current_scene != menu and current_scene != null and current_scene.get("_intro_done"):
			break
	var main = current_scene
	if main == menu or main == null or not main.get("_intro_done") or main.region != "all":
		printerr("FAIL: controller menu did not load all anatomy")
		quit(1)
		return
	# Exercise real mouse event dispatch: click captures, Escape releases, and
	# subsequent mouse motion must not rotate until the user clicks again.
	main.hud.search_box.grab_focus()
	if root.gui_get_focus_owner() != main.hud.search_box:
		printerr("FAIL: search could not receive focus")
		quit(1)
		return
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(640, 360)
	click.global_position = click.position
	Input.parse_input_event(click)
	await process_frame
	if not main.cam.captured or root.gui_get_focus_owner() != null:
		printerr("FAIL: scene click did not capture mouse and release text focus")
		quit(1)
		return
	click.pressed = false
	Input.parse_input_event(click)
	await process_frame
	var yaw: float = main.cam._yaw
	var movement := InputEventMouseMotion.new()
	movement.position = Vector2(640, 360)
	movement.global_position = movement.position
	movement.relative = Vector2(28, 0)
	Input.parse_input_event(movement)
	await process_frame
	if is_equal_approx(main.cam._yaw, yaw):
		printerr("FAIL: captured mouse motion did not rotate camera")
		quit(1)
		return
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	Input.parse_input_event(escape)
	await process_frame
	if main.cam.captured:
		printerr("FAIL: Escape did not release mouse")
		quit(1)
		return
	yaw = main.cam._yaw
	Input.parse_input_event(movement)
	await process_frame
	if not is_equal_approx(main.cam._yaw, yaw):
		printerr("FAIL: released mouse still rotates camera")
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
	# Switch the full model to high once on the real Compatibility renderer.
	main.apply_quality("high", true)
	if main.model.detail != 2:
		printerr("FAIL: full view could not switch to high")
		quit(1)
		return
	await process_frame
	await RenderingServer.frame_post_draw
	for q in ["performance"]:
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
