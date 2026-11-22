extends Node
## Headless smoke test: runs the tour to the end, checks the interior voyage
## wraps, and verifies that picking hits the expected structures.

func _ready() -> void:
	for i in 900:
		await get_tree().process_frame
		var m = get_node_or_null("/root/Main")
		if m != null and m.model != null:
			break
	var main = get_node("/root/Main")
	await get_tree().process_frame
	print("[test] stations=%d length=%.1f parts=%d"
			% [main.path.stations.size(), main.path.length, main.model.parts.size()])

	# --- guided tour, played to the end
	main._on_mode_requested("tour")
	main._fly = {}                       # skip the establishing fly-in
	main.path.start(0.0)
	main.path.hold_time = 0.0
	main.path.speed = 2500.0
	var seen := {}
	var frames := 0
	while frames < 4000 and main.path.fraction() < 0.999:
		await get_tree().process_frame
		frames += 1
		var idx: int = main.path.station_at(main.path.fraction())
		if idx >= 0:
			seen[idx] = true
	var cam_error: float = main.cam.global_position.distance_to(
			main.path.position_at(main.path.progress))
	print("[test] tour: fraction=%.3f frames=%d stations_seen=%d cam_error=%.2f playing=%s"
			% [main.path.fraction(), frames, seen.size(), cam_error, str(main.path.playing)])

	# --- interior voyage wraps around
	main._on_mode_requested("interior")
	main._fly = {}
	main.path.progress = main.path.length - 3.0
	var wrapped := false
	for i in 600:
		await get_tree().process_frame
		if main.path.fraction() < 0.2:
			wrapped = true
			break
	print("[test] interior wrapped: ", wrapped, "  fraction=%.3f" % main.path.fraction())

	# --- picking
	main._on_mode_requested("free")
	await get_tree().process_frame
	var misses := 0
	for id in ["FJ3411", "FJ2143", "FJ2422", "FJ3645", "FJ2294", "FJ1932"]:
		var part: Dictionary = main.model.by_id[id]
		var c: Vector3 = part["aabb"].get_center()
		var o: Vector3 = c + Vector3(0, 0, -30)
		var hit: Dictionary = main.model.pick(o, (c - o).normalized())
		if hit.is_empty():
			misses += 1
			print("[test] pick miss for ", id, " (", part["name"], ")")
	print("[test] pick misses: ", misses)
	print("[test] DONE")
	get_tree().quit()
