extends SceneTree
## Run with tests/run.sh, which isolates user:// and imports the project first.

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		printerr("FAIL: ", message)

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var startup := args[0] if not args.is_empty() else "performance"
	var settings_path := OS.get_environment("EXPLORER_SETTINGS_PATH")
	if settings_path.is_empty():
		printerr("EXPLORER_SETTINGS_PATH must point to an isolated settings file")
		quit(1)
		return
	var settings := ConfigFile.new()
	settings.set_value("graphics", "quality", startup)
	check(settings.save(settings_path) == OK, "save isolated startup settings")
	var scene := load("res://scenes/main.tscn") as PackedScene
	check(scene != null, "load main scene")
	if scene == null:
		quit(1)
		return
	var main = scene.instantiate()
	root.add_child(main)
	for i in 900:
		await process_frame
		if main._intro_done:
			break
	if not main._intro_done:
		printerr("FAIL: main scene did not finish loading")
		quit(1)
		return

	var expected := {"performance": 0, "balanced": 1, "high": 2}
	check(main.quality == startup, "restore startup quality " + startup)
	check(main.model.detail == expected[startup], "startup mesh detail " + startup)
	check(main.model.parts.size() == 687, "catalogue size")
	check(main.model.is_context_visible() == (startup != "performance"), "startup ghost visibility")
	check(main.hud.context_check.button_pressed == main.model.is_context_visible(), "ghost checkbox matches model")
	check(main.path.length > 0.0 and main.path.stations.size() > 0, "tour data loaded")
	for q in ["performance", "balanced", "high"]:
		main.apply_quality(q, true)
		check(main.model.detail == expected[q], "quality detail " + q)
		check(main.model.is_context_visible() == (q != "performance"), "quality ghost " + q)
		check(main.model.by_id["FJ3411"]["node"] != null, "aorta mesh exists " + q)
		check(main.model.total_tris(false) > 0, "triangle count " + q)

	main.apply_quality("performance", true)
	check(is_equal_approx(root.scaling_3d_scale, 0.75), "default performance render scale")
	main._on_render_scale_changed(0.5)
	check(is_equal_approx(root.scaling_3d_scale, 0.5), "custom render scale")
	main.apply_quality("balanced", true)
	check(is_equal_approx(root.scaling_3d_scale, 0.5), "custom scale survives quality change")
	check(is_equal_approx(main._load_render_scale(), 0.5), "custom scale saved")
	main._on_render_scale_changed(0.0)
	check(is_equal_approx(root.scaling_3d_scale, 0.9), "preset scale restored")
	main.apply_quality("performance", true)
	main._on_mode_requested("tour")
	check(is_equal_approx(main.hud.sliders["arteries"].value, 1.0), "performance tour opaque")
	main.apply_quality("balanced", true)
	check(is_equal_approx(main.hud.sliders["arteries"].value, 0.85), "balanced tour transparent")
	main.apply_quality("performance", true)
	check(is_equal_approx(main.hud.sliders["arteries"].value, 1.0), "tour returns to opaque on quality change")
	main._on_mode_requested("interior")
	check(main.model.detail == 1, "interior preserves lumen detail")
	main.path.progress = main.path.length - 1.0
	main.path.advance(1.0)
	check(main.path.fraction() < 0.01, "interior wraps")
	main._on_mode_requested("free")
	check(main.model.detail == 0, "free flight restores performance detail")
	check(not main.model.is_context_visible(), "free flight restores hidden body")

	_test_controller(main)
	_test_picking()

	if failures.is_empty():
		print("PASS: startup=", startup)
		quit(0)
	else:
		printerr("FAILED: ", failures.size(), " checks")
		quit(1)


func _test_picking() -> void:
	var model = preload("res://scripts/anatomy_model.gd").new()
	root.add_child(model)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.add_vertex(Vector3(-1, -1, 0))
	surface.add_vertex(Vector3(1, -1, 0))
	surface.add_vertex(Vector3(0, 1, 0))
	var mesh := surface.commit()
	var far := MeshInstance3D.new()
	far.mesh = mesh
	far.position = Vector3(0, 0, -8)
	model.add_child(far)
	var near := MeshInstance3D.new()
	near.mesh = mesh
	near.position = Vector3(0, 0, -3)
	model.add_child(near)
	var a := {"id": "far", "group": "artery", "material": "artery", "node": far,
		"aabb": AABB(Vector3(-2, -2, -9), Vector3(4, 4, 9))}
	var b := {"id": "near", "group": "vein", "material": "vein", "node": near,
		"aabb": AABB(Vector3(-1, -1, -4), Vector3(2, 2, 2))}
	model.parts = [a, b]
	var hit: Dictionary = model.pick(Vector3.ZERO, Vector3.FORWARD)
	check(hit.get("id", "") == "near", "pick nearest triangle, not nearest bounds")
	model._opacity["vein"] = 0.0
	hit = model.pick(Vector3.ZERO, Vector3.FORWARD)
	check(hit.get("id", "") == "far", "pick ignores invisible opacity bucket")
	far.position.x = 4.0
	hit = model.pick(Vector3.ZERO, Vector3.FORWARD)
	check(hit.is_empty(), "pick does not fall back to bounding boxes")
	model.queue_free()


func _pad_button(main, index: JoyButton) -> void:
	var event := InputEventJoypadButton.new()
	event.button_index = index
	event.pressed = true
	main._input(event)


func _test_controller(main) -> void:
	var axis := InputEventJoypadMotion.new()
	axis.device = 2
	axis.axis = JOY_AXIS_LEFT_Y
	axis.axis_value = -1.0
	check(axis.is_action_pressed("pad_move_forward"), "left stick forward mapping")
	axis.axis = JOY_AXIS_RIGHT_X
	axis.axis_value = 1.0
	check(axis.is_action_pressed("pad_look_right"), "right stick look mapping")
	var button := InputEventJoypadButton.new()
	button.device = 2
	button.button_index = JOY_BUTTON_START
	button.pressed = true
	check(button.is_action_pressed("pad_menu"), "controller menu mapping")

	main.cam.aim_from(Vector3.ZERO, Vector3.FORWARD)
	Input.action_press("pad_move_forward", 1.0)
	main.cam._process(0.2)
	check(main.cam.position.z < -0.1, "controller moves camera forward")
	Input.action_release("pad_move_forward")
	var yaw: float = main.cam.rotation.y
	Input.action_press("pad_look_right", 1.0)
	main.cam._process(0.2)
	check(main.cam.rotation.y < yaw, "controller turns camera right")
	Input.action_release("pad_look_right")

	_pad_button(main, JOY_BUTTON_START)
	check(main._controller_menu and not main.cam.gamepad_enabled, "controller menu disables flight")
	check(root.gui_get_focus_owner() != null, "controller menu focuses a control")
	var before: Vector3 = main.cam.position
	Input.action_press("pad_move_forward", 1.0)
	main.cam._process(0.2)
	check(main.cam.position.is_equal_approx(before), "controller menu blocks movement")
	Input.action_release("pad_move_forward")
	_pad_button(main, JOY_BUTTON_Y)
	check(main.mode == "free", "menu input does not change flight mode")
	_pad_button(main, JOY_BUTTON_START)
	check(not main._controller_menu and main.cam.gamepad_enabled, "controller menu closes")
	check(root.gui_get_focus_owner() == null, "controller menu releases focus")

	_pad_button(main, JOY_BUTTON_Y)
	check(main.mode == "tour", "controller cycles to tour")
	check(not main._fly.is_empty(), "tour fly-in started")
	_pad_button(main, JOY_BUTTON_A)
	check(main._fly.is_empty() and not main.path.playing, "controller skips fly-in and pauses")
	_pad_button(main, JOY_BUTTON_A)
	check(main.path.playing, "controller resumes tour")
	_pad_button(main, JOY_BUTTON_Y)
	check(main.mode == "interior" and main._fly.is_empty(), "controller cycles to interior")
	_pad_button(main, JOY_BUTTON_B)
	check(main.mode == "free" and not main.cam.captured, "controller returns to free without capturing mouse")
	var speed: float = main.cam.base_speed
	_pad_button(main, JOY_BUTTON_DPAD_RIGHT)
	check(main.cam.base_speed > speed, "controller adjusts free-flight speed")
	var ghost: bool = main.model.is_context_visible()
	_pad_button(main, JOY_BUTTON_DPAD_UP)
	check(main.model.is_context_visible() != ghost, "controller toggles body")
