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
	var settings := ConfigFile.new()
	settings.set_value("graphics", "quality", startup)
	check(settings.save("user://settings.cfg") == OK, "save isolated startup settings")
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

	if failures.is_empty():
		print("PASS: startup=", startup)
		quit(0)
	else:
		printerr("FAILED: ", failures.size(), " checks")
		quit(1)
