extends SceneTree
## Run with tests/benchmark.sh on a real display, not with --headless.

const WARMUP_SECONDS := 5.0
const SAMPLE_SECONDS := 10.0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Benchmark needs a graphical display and renderer, not --headless.")
		quit(1)
		return
	var args := OS.get_cmdline_user_args()
	var quality := args[0] if not args.is_empty() else "performance"
	if quality not in ["performance", "balanced", "high"]:
		printerr("Expected performance, balanced or high")
		quit(1)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var settings := ConfigFile.new()
	settings.set_value("graphics", "quality", quality)
	if settings.save("user://settings.cfg") != OK:
		printerr("Could not write isolated benchmark settings")
		quit(1)
		return
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 900:
		await process_frame
		if main._intro_done:
			break
	if not main._intro_done:
		printerr("Main scene failed to load")
		quit(1)
		return
	print("BENCHMARK Godot=", Engine.get_version_info().string,
		" OS=", OS.get_name(), " GPU=", RenderingServer.get_video_adapter_name(),
		" vendor=", RenderingServer.get_video_adapter_vendor(),
		" API=", RenderingServer.get_video_adapter_api_version(),
		" renderer=", RenderingServer.get_current_rendering_method(),
		" window=", root.size, " scale=", root.scaling_3d_scale, " quality=", quality)
	# Fixed views and a paused path make runs comparable; hover and particles remain active.
	await _measure(main, "free-heart")
	main.cam.aim_from(Vector3(105, 55, -175), Vector3(0, 12, 0))
	await _measure(main, "free-whole-body")
	main._on_mode_requested("tour")
	main._fly = {}
	main.path.seek_fraction(0.10)
	main.path.stop()
	await _measure(main, "tour-heart")
	main._on_mode_requested("interior")
	main.path.seek_fraction(0.30)
	main.path.stop()
	await _measure(main, "interior-aorta")
	quit(0)

func _measure(main, label: String) -> void:
	var start := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - start) < WARMUP_SECONDS * 1000000.0:
		await process_frame
	var samples: Array[float] = []
	start = Time.get_ticks_usec()
	var previous := start
	while (Time.get_ticks_usec() - start) < SAMPLE_SECONDS * 1000000.0:
		await process_frame
		var now := Time.get_ticks_usec()
		samples.append((now - previous) / 1000.0)
		previous = now
	samples.sort()
	var elapsed := (previous - start) / 1000000.0
	var p50: float = samples[int((samples.size() - 1) * 0.50)]
	var p95: float = samples[int((samples.size() - 1) * 0.95)]
	var p99: float = samples[int((samples.size() - 1) * 0.99)]
	print("BENCHMARK view=%s fps=%.1f frame_ms_p50=%.2f p95=%.2f p99=%.2f draws=%d triangles=%d detail=%d samples=%d" % [
		label, samples.size() / elapsed, p50, p95, p99,
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		main.model.detail, samples.size()])
