extends Control
## Lightweight entry screen. It does not create an AnatomyModel or load any GLBs.

const CREDITS_DIALOG := preload("res://scripts/credits_dialog.gd")
const CHOICES := [
	["torso", "Torso", "Chest, abdomen and shoulder vessels"],
	["lower", "Waist down", "Pelvis and lower limbs"],
	["head", "Head & neck", "Cerebral and neck vessels"],
	["heart", "Heart", "Heart structures and coronary vessels"],
	["cardiac", "Cardiac", "Heart, coronary and pulmonary vessels"],
	["all", "All anatomy", "Full model, guided tour and interior voyage"],
]
var buttons: Dictionary = {}
var _loading := false
var note: Label
var credits_button: Button
var credits_dialog


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var accept := InputEventJoypadButton.new()
	accept.device = -1
	accept.button_index = JOY_BUTTON_A
	if not InputMap.action_has_event("ui_accept", accept):
		InputMap.action_add_event("ui_accept", accept)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.012, 0.019, 0.035)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 30)
	margin.add_theme_constant_override("margin_right", 30)
	margin.add_theme_constant_override("margin_top", 32)
	margin.add_theme_constant_override("margin_bottom", 32)
	center.add_child(margin)
	var col := VBoxContainer.new()
	col.custom_minimum_size.x = 600
	col.add_theme_constant_override("separation", 12)
	margin.add_child(col)
	var eyebrow := _label("BODY PARTS 3D    /    INTERACTIVE ATLAS", 12, Color(0.48, 0.67, 0.86))
	col.add_child(eyebrow)
	var title := _label("Circulatory System\nExplorer", 38, Color(0.95, 0.97, 1.0))
	col.add_child(title)
	var desc := _label("Choose an area to explore. Anatomy loads only after you choose.", 15, Color(0.68, 0.73, 0.81))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(desc)
	credits_button = Button.new()
	credits_button.text = "Credits and data licenses"
	credits_button.focus_mode = Control.FOCUS_ALL
	credits_button.pressed.connect(_show_credits)
	col.add_child(credits_button)
	col.add_child(HSeparator.new())
	for item in CHOICES:
		var button := Button.new()
		button.text = "%s     —     %s" % [item[1], item[2]]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size = Vector2(0, 56)
		button.add_theme_font_size_override("font_size", 15)
		button.add_theme_stylebox_override("normal", _button_style(Color(0.055, 0.077, 0.115), Color(0.22, 0.29, 0.39)))
		button.add_theme_stylebox_override("hover", _button_style(Color(0.09, 0.15, 0.22), Color(0.42, 0.66, 0.8)))
		button.add_theme_stylebox_override("focus", _button_style(Color(0.08, 0.13, 0.20), Color(0.5, 0.75, 0.9)))
		button.pressed.connect(_choose.bind(String(item[0])))
		buttons[item[0]] = button
		col.add_child(button)
	note = _label("Starts in Performance · Graphics can be changed in the explorer", 12, Color(0.51, 0.58, 0.68))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(note)
	buttons["torso"].grab_focus.call_deferred()


func _show_credits() -> void:
	if credits_dialog == null:
		credits_dialog = CREDITS_DIALOG.new()
		add_child(credits_dialog)
	credits_dialog.popup_centered(Vector2i(760, 580))


func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _button_style(color: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(16)
	return style


func _choose(region: String) -> void:
	if _loading or not buttons.has(region):
		return
	_loading = true
	for button in buttons.values():
		button.disabled = true
	note.text = "Loading %s…" % region.capitalize()
	# Wait for the loading message to paint before the synchronous GLB load.
	await get_tree().process_frame
	await get_tree().process_frame
	var packed := load("res://scenes/main.tscn") as PackedScene
	if packed == null:
		note.text = "Could not open the explorer. Please restart the application."
		_loading = false
		for button in buttons.values():
			button.disabled = false
		return
	var explorer = packed.instantiate()
	explorer.region = region
	get_tree().root.add_child(explorer)
	get_tree().current_scene = explorer
	queue_free()
