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
	await _wait(4.4)
	await _shot("05_tour_heart")

	main.path.seek_fraction(0.30)
	await _wait(1.4)
	await _shot("06_tour_aorta")

	main.path.seek_fraction(0.62)
	await _wait(1.4)
	await _shot("07_tour_leg")

	main._on_mode_requested("interior")
	await _wait(2.0)
	main.path.seek_fraction(0.30)
	await _wait(1.2)
	await _shot("08_interior")

	main.path.seek_fraction(0.66)
	await _wait(1.2)
	await _shot("09_interior_leg")


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [outdir, name]
	img.save_png(path)
	print("[shot] %s" % path)
