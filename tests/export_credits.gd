extends SceneTree
## Executed from an isolated exported PCK by CI, not from the source checkout.
const NOTICE := preload("res://scripts/credits_text.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var menu = load("res://scenes/start.tscn").instantiate()
	root.add_child(menu)
	await process_frame
	menu.credits_button.pressed.emit()
	await process_frame
	if menu.credits_dialog == null or not menu.credits_dialog.visible:
		printerr("FAIL: exported menu credits did not open")
		quit(1)
		return
	var text: String = menu.credits_dialog.notice.text
	if text != NOTICE.NOTICE or not text.contains("The Database Center for Life Science") or not text.contains("CC BY-SA 2.1 Japan") or not text.contains("CC BY 4.0"):
		printerr("FAIL: exported credits are incomplete")
		quit(1)
		return
	print("PASS: exported pack displays embedded attribution")
	quit(0)
