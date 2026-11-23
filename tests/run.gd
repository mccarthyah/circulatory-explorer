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
	settings.set_value("graphics", "render_scale", 1.0)
	check(settings.save(settings_path) == OK, "save isolated startup settings")
	var scene := load("res://scenes/main.tscn") as PackedScene
	check(scene != null, "load main scene")
	if scene == null:
		quit(1)
		return
	var main = scene.instantiate()
	main.region = "all"
	root.add_child(main)
	for i in 900:
		await process_frame
		if main._intro_done:
			break
	if not main._intro_done:
		printerr("FAIL: main scene did not finish loading")
		quit(1)
		return

	check(main.quality == "performance", "startup ignores saved quality " + startup)
	check(main.model.detail == 0, "startup uses lowest mesh detail")
	check(is_equal_approx(root.scaling_3d_scale, 0.5), "startup ignores saved render scale")
	check(not main.hud.quality_option.disabled and not main.hud.scale_option.disabled, "graphics selectors are enabled")
	check(not main.hud.graphics_lock_label.visible, "graphics lock is not shown")
	check(main.model.parts.size() == 1095, "expanded catalogue size")
	check(not main.model.is_extended_visible() and main.model.extended_root == null, "extra layer starts unloaded")
	for id in ["FJ2655", "FJ2966", "FJ2428"]:
		check(main.model.by_id.has(id) and main.model.by_id[id]["node"] != null, "core anatomy loaded " + id)
	check(main.model.by_id["FJ2655"]["group"] == "vein", "coronary sinus is a vein")
	check(main.model.by_id["FJ2655"]["coronary"], "coronary sinus identified as coronary")
	check(main.model.by_id["FJ2966"]["circuit"] == "pulmonary", "pulmonary trunk is pulmonary")
	check(main.model.parts_matching("coronary sinus").size() == 1, "search finds coronary sinus")
	check(main.model.by_id["FJ2725"]["node"] == null, "extra cardiac vein is lazy-loaded")
	check(not main.model.is_context_visible(), "startup ghost hidden")
	check(not main.hud.context_check.button_pressed, "ghost checkbox matches model")
	check(main.path.length > 0.0 and main.path.stations.size() > 0, "tour data loaded")
	check(not main.env.glow_enabled and not main.env.fog_enabled, "startup effects disabled")

	for q in ["performance", "balanced", "high"]:
		main.apply_quality(q, true)
		check(main.quality == q and main.model.detail == main.QUALITY[q]["detail"], "quality loads requested detail " + q)
		check(is_equal_approx(root.scaling_3d_scale, main.QUALITY[q]["scale"]), "preset resolution " + q)
		check(main.model.by_id["FJ3411"]["node"] != null, "aorta mesh exists " + q)
		check(main.model.total_tris(false) > 0, "triangle count " + q)
	main._on_render_scale_changed(1.0)
	check(is_equal_approx(root.scaling_3d_scale, 1.0), "resolution can be raised")
	main._on_render_scale_changed(0.0)
	main.apply_quality("performance", true)
	check(is_equal_approx(root.scaling_3d_scale, 0.5), "performance returns to 50 percent")
	var stored := ConfigFile.new()
	check(stored.load(settings_path) == OK, "saved settings remain readable")
	check(stored.get_value("graphics", "quality", "") == "performance", "quality changes saved")
	check(is_equal_approx(float(stored.get_value("graphics", "render_scale", -1.0)), 0.0), "resolution changes saved")
	main._on_mode_requested("tour")
	check(main.model.detail == 0 and not main.env.fog_enabled, "performance tour uses low detail")
	check(is_equal_approx(main.hud.sliders["arteries"].value, 1.0), "tour remains opaque")
	main._on_mode_requested("interior")
	check(main.model.detail == 0 and not main.env.fog_enabled, "performance interior uses low detail")
	check(is_equal_approx(root.scaling_3d_scale, 0.5), "interior scale remains lowest")
	main.path.progress = main.path.length - 1.0
	main.path.advance(1.0)
	check(main.path.fraction() < 0.01, "interior wraps")
	main._on_mode_requested("free")
	check(main.model.detail == 0, "free flight uses performance detail")
	check(not main.model.is_context_visible(), "free flight restores hidden body")

	# Hiding an inspected part is reversible and survives detail reloads.
	main._on_part_picked("FJ3411")
	var visible_total: int = main.model.total_tris(false)
	main.hud.visibility_button.pressed.emit()
	check(main.model.by_id["FJ3411"]["hidden"] and not main.model.by_id["FJ3411"]["node"].visible, "hide inspected structure")
	check(main.hud.visibility_button.text == "Show this structure", "hidden structure offers restore")
	check(main.model.total_tris(false) < visible_total, "hidden triangles excluded")
	check(main.model.parts_matching("arch of aorta")[0]["hidden"], "hidden structure remains searchable")
	main.apply_quality("balanced", true)
	check(main.model.detail == 1 and main.model.by_id["FJ3411"]["hidden"] and not main.model.by_id["FJ3411"]["node"].visible, "hidden state survives quality reload")
	main._on_part_picked("FJ3411")
	main.hud.visibility_button.pressed.emit()
	check(not main.model.by_id["FJ3411"]["hidden"] and main.model.by_id["FJ3411"]["node"].visible, "show individual hidden structure")
	main._on_part_visibility_requested("FJ3411")
	main.hud.show_all_button.pressed.emit()
	check(not main.model.by_id["FJ3411"]["hidden"] and main.model.by_id["FJ3411"]["node"].visible, "restore all hidden structures")
	main.apply_quality("performance", true)

	# Search selection loads the optional layer.
	var baseline: int = main.model.total_tris(false)
	main._on_part_picked("FJ2725")
	check(main.model.is_extended_visible() and main.hud.extended_check.button_pressed, "search selection enables extras")
	check(main.model.by_id["FJ2725"]["node"] != null, "extra cardiac vein loaded")
	check(main.model.parts_matching("anterior cardiac vein").size() >= 1, "search finds extra cardiac vein")
	_test_real_extra_pick(main.model)
	check(main.model.total_tris(false) > baseline, "visible triangle count includes extras")
	check(main.model.detail == 0 and is_equal_approx(root.scaling_3d_scale, 0.5), "extras preserve performance graphics")
	main._on_extended_toggled(false)
	check(not main.model.is_extended_visible() and not main.hud.extended_check.button_pressed, "extra layer hides")
	check(main.model.total_tris(false) == baseline, "hidden extras excluded from triangle count")
	check(main.selected_part.is_empty() and main._fly.is_empty() and main.cam.enabled, "hiding selected extras cancels flight")
	check(main.model.by_id["FJ2655"]["node"].is_visible_in_tree(), "coronary sinus stays visible")
	main._on_extended_toggled(true)
	check(main.model.is_extended_visible(), "extra layer reopens")
	for d in [1, 2, 0]:
		check(main.model.reload(d), "reload detail " + str(d))
		check(main.model.is_extended_visible() and main.model.by_id["FJ2725"]["node"] != null, "extra layer survives detail reload " + str(d))
		check(main.model.by_id["FJ2655"]["node"] != null, "coronary sinus survives detail reload " + str(d))
	main._on_extended_toggled(false)
	main._go_free(true)

	_test_visibility_presets(main)
	_test_hide_shortcut(main)
	_test_mouse_capture(main)
	_test_controller(main)
	_test_picking()
	_test_box_selection()
	_test_box_drag(main)

	if failures.is_empty():
		print("PASS: startup=", startup)
		quit(0)
	else:
		printerr("FAILED: ", failures.size(), " checks")
		quit(1)


func _test_mouse_capture(main) -> void:
	var cam = main.cam
	cam.enabled = true
	cam.set_gamepad_enabled(true)
	cam.capture_mouse(false)
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_LEFT
	button.pressed = true
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(20, 10)
	# Regression: a press before capture and release during capture used to
	# leave a stale dragging flag that turned mouse-look back on after Escape.
	cam._unhandled_input(button)
	var yaw: float = cam._yaw
	cam._unhandled_input(motion)
	check(is_equal_approx(cam._yaw, yaw), "released mouse does not rotate on drag")
	cam.capture_mouse(true)
	cam._unhandled_input(motion)
	check(not is_equal_approx(cam._yaw, yaw), "captured mouse rotates")
	button.pressed = false
	cam._unhandled_input(button)
	cam.capture_mouse(false)
	yaw = cam._yaw
	var pitch: float = cam._pitch
	cam._unhandled_input(motion)
	check(is_equal_approx(cam._yaw, yaw) and is_equal_approx(cam._pitch, pitch), "mouse stays still after release")
	main._go_free(false)
	check(not cam.captured, "switching to free flight does not recapture mouse")
	main._fly = {"from": cam.position, "to": cam.position, "from_look": Vector3.FORWARD,
		"to_look": Vector3.FORWARD, "t": 0.0, "dur": 1.0, "then": ""}
	main._update_fly(1.0)
	check(not cam.captured, "finishing automatic flight does not recapture mouse")
	cam.capture_mouse(true)
	cam.notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(not cam.captured, "focus loss releases mouse")
	yaw = cam._yaw
	cam._unhandled_input(motion)
	check(is_equal_approx(cam._yaw, yaw), "mouse stays released after focus loss")
	cam.capture_mouse(true)
	cam._unhandled_input(motion)
	check(not is_equal_approx(cam._yaw, yaw), "mouse look resumes after recapture")
	main._on_mode_requested("tour")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	main._unhandled_input(escape)
	check(main.mode == "free" and not cam.captured, "Escape leaves tour and releases mouse")


func _test_real_extra_pick(model) -> void:
	var part: Dictionary = model.by_id["FJ2725"]
	var node: MeshInstance3D = part["node"]
	var faces: PackedVector3Array = node.mesh.get_faces()
	check(faces.size() >= 3, "extra vein has triangle geometry")
	if faces.size() < 3:
		return
	var a: Vector3 = node.to_global(faces[0])
	var b: Vector3 = node.to_global(faces[1])
	var c: Vector3 = node.to_global(faces[2])
	var normal := (b - a).cross(c - a).normalized()
	var centre := (a + b + c) / 3.0
	var original: Array = model.parts
	model.parts = [part] # Isolate this vessel from overlapping anatomical surfaces.
	var hit: Dictionary = model.pick(centre + normal * 0.1, -normal)
	check(hit.get("id", "") == "FJ2725", "extra vein is pickable by its triangles")
	model.set_part_hidden("FJ2725", true)
	check(model.pick(centre + normal * 0.1, -normal).is_empty(), "individually hidden vein is not pickable")
	model.set_part_hidden("FJ2725", false)
	check(model.pick(centre + normal * 0.1, -normal).get("id", "") == "FJ2725", "restored vein is pickable")
	model.set_extended_visible(false)
	check(model.pick(centre + normal * 0.1, -normal).is_empty(), "hidden extra vein is not pickable")
	model.set_extended_visible(true)
	model.parts = original


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


func _test_visibility_presets(main) -> void:
	var save_path := OS.get_environment("EXPLORER_VISIBILITY_PATH")
	check(not save_path.is_empty(), "visibility test path isolated")
	if save_path.is_empty():
		return
	if FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(save_path)
	var store = main.visibility_presets
	main.model.set_part_hidden("FJ3411", true)
	main.model.set_part_hidden("FJ2725", true) # optional unloaded vessel
	main._on_preset_save("Test", false)
	check(store.load_preset("all", "Test").state.hidden.has("FJ2725"), "save contains lazy hidden ID")
	check(not store.save_preset("all", "Test", {"hidden": []}).ok, "overwrite requires explicit confirmation")
	check(store.save_preset("all", "Replace", {"hidden": ["FJ3411"]}).ok, "create replace test")
	check(store.save_preset("all", "Replace", {"hidden": []}, true).ok and store.load_preset("all", "Replace").state.hidden.is_empty(), "confirmed overwrite replaces save")
	check(store.save_preset("heart", "Test", {"hidden": ["other"]}).ok, "same name in another view")
	main.model.show_all_parts()
	main.model.set_part_hidden("FJ2655", true)
	main._on_preset_load("Test")
	check(main.model.by_id["FJ3411"].hidden and main.model.by_id["FJ2725"].hidden, "load applies saved hidden IDs")
	check(not main.model.by_id["FJ2655"].hidden and not main.model.is_extended_visible(), "load replaces hides without enabling extra layer")
	main._on_extended_toggled(true)
	check(not main.model.by_id["FJ2725"].node.visible, "saved lazy hide applies when extra layer loads")
	main.apply_quality("balanced", true)
	check(main.model.by_id["FJ2725"].hidden and not main.model.by_id["FJ2725"].node.visible, "saved hides survive LOD reload")
	main.apply_quality("performance", true)
	main._on_extended_toggled(false)
	var new_store = load("res://scripts/visibility_presets.gd").new()
	check(new_store.load_preset("all", "Test").state.hidden.has("FJ3411"), "save persists across instances")
	check(new_store.load_preset("heart", "Test").state.hidden == ["other"], "separate view save preserved")
	check(new_store.save_preset("all", "Missing", {"hidden": ["no-such-part"]}).ok, "save unknown ID")
	main._on_preset_load("Missing")
	check(main.hud.preset_message.text.contains("1 unavailable"), "unknown ID reported")
	check(new_store.delete_preset("all", "Test").ok and not new_store.load_preset("all", "Test").ok, "delete save")
	var file := FileAccess.open(save_path, FileAccess.WRITE)
	file.store_string("not valid json")
	file.close()
	check(not new_store.save_preset("all", "Test", {"hidden": []}).ok, "malformed file not overwritten")
	check(FileAccess.get_file_as_string(save_path) == "not valid json", "malformed file retained")
	DirAccess.remove_absolute(save_path)
	main.model.show_all_parts()


func _test_hide_shortcut(main) -> void:
	var model = main.model
	var part: Dictionary = model.by_id["FJ3411"]
	var node: MeshInstance3D = part.node
	var faces: PackedVector3Array = node.mesh.get_faces()
	if faces.size() < 3:
		check(false, "shortcut target has triangle geometry")
		return
	var a: Vector3 = node.to_global(faces[0])
	var b: Vector3 = node.to_global(faces[1])
	var c: Vector3 = node.to_global(faces[2])
	var normal := (b - a).cross(c - a).normalized()
	var centre := (a + b + c) / 3.0
	var original: Array = model.parts
	model.parts = [part]
	main._fly = {}
	main.cam.global_position = centre + normal * 0.1
	main.cam.look_at(centre, Vector3.RIGHT if abs(normal.dot(Vector3.UP)) > 0.99 else Vector3.UP)
	main.cam.capture_mouse(true)
	var event := InputEventKey.new()
	event.keycode = KEY_H
	event.pressed = true
	main._unhandled_input(event)
	check(part.hidden and main.cam.captured, "H hides actual crosshair target without releasing mouse")
	model.set_part_hidden("FJ3411", false)
	main.cam.capture_mouse(false)
	main._unhandled_input(event)
	check(not part.hidden, "H does not hide while mouse released")
	model.parts = original


func _test_box_selection() -> void:
	var model = preload("res://scripts/anatomy_model.gd").new()
	root.add_child(model)
	var camera := Camera3D.new()
	camera.near = 0.1
	camera.far = 20.0
	root.add_child(camera)
	camera.current = true
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for vertex in [Vector3(-1, -1, 0), Vector3(1, -1, 0), Vector3(0, 1, 0)]:
		surface.add_vertex(vertex)
	var mesh := surface.commit()
	for data in [["near", Vector3(0, 0, -3), "artery"], ["far", Vector3(0, 0, -8), "vein"], ["side", Vector3(4, 0, -3), "artery"], ["behind", Vector3(0, 0, 3), "artery"], ["context", Vector3(0, 0, -3), "context"]]:
		var node := MeshInstance3D.new()
		node.mesh = mesh
		node.position = data[1]
		model.add_child(node)
		model.parts.append({"id": data[0], "group": data[2], "material": data[2], "node": node})
	var center := camera.unproject_position(Vector3(0, 0, -3))
	var selector = preload("res://scripts/box_selection.gd").new()
	var rect := Rect2(center - Vector2(10, 10), Vector2(20, 20))
	var ids: Array = selector.parts_in_rect(model, camera, rect)
	check(ids.has("near") and ids.has("far") and ids.size() == 2, "box intersects real triangles through depth, excluding off-box, behind-camera and context")
	var triangle := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(0, 10)])
	check(not selector._polygon_intersects_rect(triangle, Rect2(8, 8, 1, 1)), "box inside projected bounds but outside triangle is not selected")
	check(selector._polygon_intersects_rect(triangle, Rect2(4, 4, 2, 2)), "box crossing triangle edge selects")
	var clipped: Array = selector._clip_depth([Vector3(0, 0, 0), Vector3(-1, -1, -1), Vector3(1, -1, -1)], -0.1, true)
	check(clipped.size() == 4 and clipped.all(func(p): return p.z <= -0.1 + 0.0001), "box selection clips triangles crossing the near plane")
	model._opacity["vein"] = 0.0
	ids = selector.parts_in_rect(model, camera, rect)
	check(ids == ["near"], "box ignores transparent structures")
	model.parts[0].node.visible = false
	check(selector.parts_in_rect(model, camera, rect).is_empty(), "box ignores hidden nodes")
	model.queue_free()
	camera.queue_free()


func _test_box_drag(main) -> void:
	var model = main.model
	var part: Dictionary = model.by_id["FJ3411"]
	var original: Array = model.parts
	model.parts = [part]
	model.set_part_hidden("FJ3411", false)
	var node: MeshInstance3D = part.node
	var faces := node.mesh.get_faces()
	var a: Vector3 = node.to_global(faces[0])
	var b: Vector3 = node.to_global(faces[1])
	var c: Vector3 = node.to_global(faces[2])
	var centre := (a + b + c) / 3.0
	var normal := (b - a).cross(c - a).normalized()
	main._fly = {}
	main.cam.global_position = centre + normal * 1.0
	main.cam.look_at(centre, Vector3.RIGHT if abs(normal.dot(Vector3.UP)) > 0.99 else Vector3.UP)
	main.cam.capture_mouse(true)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.shift_pressed = true
	main._unhandled_input(press)
	check(main._box_dragging and not main.cam.enabled and main.cam.captured, "shift drag freezes camera while preserving capture")
	main._box_start = Vector2.ZERO
	main._box_end = root.get_visible_rect().size
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	main._input(release)
	check(part.hidden and main.cam.enabled and main.cam.captured and not main._box_dragging, "box hides and resumes captured camera")
	main._undo_box_hide()
	check(not part.hidden and main.hud.undo_box_button.disabled, "undo restores box-hidden structures")
	main._begin_box_drag(Vector2.ZERO)
	main._end_box_drag(false)
	check(not part.hidden and main.cam.captured and main.cam.enabled, "cancel box leaves visibility and capture unchanged")
	main.cam.capture_mouse(false)
	model.parts = original
