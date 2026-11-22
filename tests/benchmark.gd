extends SceneTree
## Run with tests/benchmark.sh on a real display, not with --headless.

const DEFAULT_WARMUP_SECONDS := 5.0
const DEFAULT_SAMPLE_SECONDS := 10.0
var warmup_seconds := DEFAULT_WARMUP_SECONDS
var sample_seconds := DEFAULT_SAMPLE_SECONDS

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
	var warmup_text := OS.get_environment("BENCH_WARMUP")
	var sample_text := OS.get_environment("BENCH_DURATION")
	if not warmup_text.is_empty():
		if not warmup_text.is_valid_float() or warmup_text.to_float() < 0.0:
			printerr("BENCH_WARMUP must be a nonnegative number")
			quit(1)
			return
		warmup_seconds = warmup_text.to_float()
	if not sample_text.is_empty():
		if not sample_text.is_valid_float() or sample_text.to_float() <= 0.0:
			printerr("BENCH_DURATION must be a positive number")
			quit(1)
			return
		sample_seconds = sample_text.to_float()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var settings_path := OS.get_environment("EXPLORER_SETTINGS_PATH")
	if settings_path.is_empty():
		printerr("EXPLORER_SETTINGS_PATH must point to an isolated settings file")
		quit(1)
		return
	var settings := ConfigFile.new()
	settings.set_value("graphics", "quality", quality)
	var scale_text := OS.get_environment("BENCH_SCALE")
	if not scale_text.is_empty():
		var scale := scale_text.to_float()
		if not scale_text.is_valid_float() or scale not in [0.0, 0.5, 0.65, 0.75, 0.9, 1.0]:
			printerr("BENCH_SCALE must be 0, 0.5, 0.65, 0.75, 0.9 or 1.0")
			quit(1)
			return
		settings.set_value("graphics", "render_scale", scale)
	if settings.save(settings_path) != OK:
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
	if main.quality != quality:
		printerr("Requested quality is unavailable while lowest graphics are locked")
		quit(1)
		return
	if not scale_text.is_empty() and scale_text.to_float() > 0.0 and not is_equal_approx(root.scaling_3d_scale, scale_text.to_float()):
		printerr("Requested scale is unavailable while lowest graphics are locked")
		quit(1)
		return
	print("BENCHMARK Godot=", Engine.get_version_info().string,
		" OS=", OS.get_name(), " GPU=", RenderingServer.get_video_adapter_name(),
		" vendor=", RenderingServer.get_video_adapter_vendor(),
		" API=", RenderingServer.get_video_adapter_api_version(),
		" renderer=", RenderingServer.get_current_rendering_method(),
		" window=", root.size, " scale=", root.scaling_3d_scale, " quality=", main.quality)
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
	while (Time.get_ticks_usec() - start) < warmup_seconds * 1000000.0:
		await process_frame
	var samples: Array[float] = []
	start = Time.get_ticks_usec()
	var previous := start
	while (Time.get_ticks_usec() - start) < sample_seconds * 1000000.0:
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
