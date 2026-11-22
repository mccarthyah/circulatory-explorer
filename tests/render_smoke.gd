extends SceneTree
## Software OpenGL smoke test for CI. It is not a performance benchmark.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless" or RenderingServer.get_current_rendering_method() != "gl_compatibility":
		printerr("FAIL: expected a graphical Compatibility renderer")
		quit(1)
		return
	var cf := ConfigFile.new()
	cf.set_value("graphics", "quality", "performance")
	if cf.save("user://settings.cfg") != OK:
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
