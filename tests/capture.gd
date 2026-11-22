extends Node
## QA helper (not part of the game): drives the explorer through every mode and
## saves screenshots. Enable by adding
##     QaCapture="*res://tests/capture.gd"
## under a [autoload] section in project.godot, then run the project.

var main: Node
var outdir := "res://tests/out"


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(outdir))
	await _run()
	get_tree().quit()


func _run() -> void:
	for i in 900:
		await get_tree().process_frame
		if get_node_or_null("/root/Main") != null and get_node("/root/Main").model != null:
			break
	main = get_node("/root/Main")
	await _wait(1.2)

	# stills are documented at the "balanced" preset; the shipped default is
	# "performance" and is captured separately at the end for comparison
	main.apply_quality("balanced", true)
	await _wait(1.0)
	await _shot("01_hero")

	main.cam.aim_from(Vector3(105, 55, -175), Vector3(0, 12, 0))
	await _wait(0.8)
	await _shot("02_whole_body")

	main.hud.context_check.set_pressed_no_signal(false)
	main._on_context_toggled(false)
	var heart: Dictionary = main.model.by_id["FJ2423"]
	var hc: Vector3 = heart["aabb"].get_center()
	main.cam.aim_from(hc + Vector3(13.0, 5.0, -17.0), hc)
	await _wait(0.8)
	await _shot("03_heart_closeup")

	var arch: Dictionary = main.model.by_id["FJ3411"]
	main.cam.aim_from(arch["aabb"].get_center() + Vector3(9.0, 2.0, -13.0),
			arch["aabb"].get_center())
	main.model.highlight(arch)
	main.hud.show_part(arch)
	main.hover = arch
	await _wait(0.8)
	await _shot("04_inspect")

	main._on_mode_requested("tour")
	await _wait(1.2)
	main._fly = {}                      # skip the establishing fly-in
	# station 1 is the SVC mouth; step into the right atrium / ventricle part of
	# the tour where the heart itself fills the frame
	main.path.seek_fraction(0.10)
	await _wait(3.6)
	await _shot("05_tour_heart")

	main.path.seek_fraction(0.30)
	await _wait(4.5)
	await _shot("06_tour_aorta")

	main.path.seek_fraction(0.72)
	await _wait(5.0)
	await _shot("07_tour_leg")

	main._on_mode_requested("interior")
	await _wait(2.0)
	main.path.seek_fraction(0.30)
	await _wait(1.2)
	await _shot("08_interior")

	main.path.seek_fraction(0.66)
	await _wait(1.2)
	await _shot("09_interior_leg")

	# detail-level comparison from the same viewpoint
	main._on_mode_requested("free")
	var hcc: Vector3 = main.model.by_id["FJ2423"]["aabb"].get_center()
	main.cam.aim_from(hcc + Vector3(13.0, 5.0, -17.0), hcc)
	for item in [["performance", "10_perf"], ["high", "11_high"]]:
		main.apply_quality(item[0], true)
		await _wait(1.6)
		await _shot(item[1])
	main.apply_quality("balanced", true)
	main._on_mode_requested("interior")
	main.path.seek_fraction(0.30)
	main.apply_quality("performance", true)
	await _wait(1.6)
	await _shot("12_perf_interior")


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [outdir, name]
	img.save_png(path)
	print("[shot] %s" % path)
