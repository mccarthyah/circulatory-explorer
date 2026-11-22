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
