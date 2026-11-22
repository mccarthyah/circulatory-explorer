class_name ExplorerHUD
extends CanvasLayer
## All interface: mode switching, structure search, opacity control, the
## "inspecting" card, tour captions and the loading/fade overlays.

signal mode_requested(mode: String)
signal opacity_changed(bucket: String, value: float)
signal context_toggled(on: bool)
signal labels_toggled(on: bool)
signal search_changed(text: String)
signal part_picked(id: String)
signal pause_toggled()
signal station_step(direction: int)

const TEXT := Color(0.94, 0.95, 0.97)
const DIM := Color(0.63, 0.68, 0.77)
const ACCENT_A := Color(0.90, 0.36, 0.33)
const ACCENT_V := Color(0.45, 0.65, 1.0)
const ACCENT_H := Color(0.90, 0.60, 0.62)
const PANEL_BG := Color(0.043, 0.052, 0.078, 0.86)
const PANEL_BORDER := Color(1, 1, 1, 0.075)

var root: Control
var top_bar: PanelContainer
var left_panel: PanelContainer
var info_panel: PanelContainer
var caption_panel: PanelContainer
var crosshair: Control
var vignette: TextureRect
var fade_rect: ColorRect
var loading_panel: PanelContainer
var loading_label: Label
var subtitle_label: Label
var status_label: Label
var name_label: Label
var meta_label: Label
var lineage_label: Label
var fly_button: Button
var search_box: LineEdit
var list: ItemList
var caption_title: Label
var caption_text: RichTextLabel
var caption_index: Label
var progress_bar: ProgressBar
var mode_buttons: Dictionary = {}
var sliders: Dictionary = {}
var context_check: CheckBox
var labels_check: CheckBox

var _list_ids: Array = []
var _mode := "free"
var _current_id := ""
var panel_visible := true


func _ready() -> void:
	layer = 10
	root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_build_vignette()
	_build_top_bar()
	_build_left_panel()
	_build_info_panel()
	_build_caption()
	_build_fade()
	_build_loading()

	crosshair = Crosshair.new()
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(crosshair)
	crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_centre(crosshair, 28)

	set_caption_visible(false)
	show_info(false)
	set_vignette(false)


# --------------------------------------------------------------------- widgets
func _panel(alpha := 0.86) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	var bg := PANEL_BG
	bg.a = alpha
	sb.bg_color = bg
	sb.border_color = PANEL_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(14)
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 12
	p.add_theme_stylebox_override("panel", sb)
	return p


func _label(text: String, size := 13, colour := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	return l


func _section(text: String) -> Label:
	var l := _label(text, 10, DIM)
	l.add_theme_constant_override("line_spacing", 4)
	return l


func _spacer(min_width := 0) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(min_width, 0)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


func _centre(c: Control, size: int) -> void:
	c.custom_minimum_size = Vector2(size, size)
	c.offset_left = -size * 0.5
	c.offset_top = -size * 0.5
	c.offset_right = size * 0.5
	c.offset_bottom = size * 0.5


func _mode_button(text: String, mode: String) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 13)
	b.custom_minimum_size = Vector2(0, 34)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.06)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(12)
	sb.border_color = Color(1, 1, 1, 0.06)
	sb.set_border_width_all(1)
	b.add_theme_stylebox_override("normal", sb)
	var sb_hover: StyleBoxFlat = sb.duplicate()
	sb_hover.bg_color = Color(1, 1, 1, 0.12)
	b.add_theme_stylebox_override("hover", sb_hover)
	var sb_on: StyleBoxFlat = sb.duplicate()
	sb_on.bg_color = Color(0.86, 0.34, 0.32, 0.95)
	sb_on.border_color = Color(1, 1, 1, 0.18)
	b.add_theme_stylebox_override("pressed", sb_on)
	b.add_theme_stylebox_override("focus", sb.duplicate())
	b.pressed.connect(func() -> void:
		set_mode(mode)
		mode_requested.emit(mode))
	mode_buttons[mode] = b
	return b


# --------------------------------------------------------------------- layout
func _build_vignette() -> void:
	vignette = TextureRect.new()
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, 0))
	g.set_color(1, Color(0, 0, 0, 0.92))
	g.add_point(0.55, Color(0, 0, 0, 0.06))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.05, 1.05)
	tex.width = 512
	tex.height = 512
	vignette.texture = tex
	vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	vignette.stretch_mode = TextureRect.STRETCH_SCALE
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(vignette)


func _build_top_bar() -> void:
	top_bar = _panel(0.90)
	top_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_bar.offset_left = 16
	top_bar.offset_right = -16
	top_bar.offset_top = 14
	top_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(top_bar)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	top_bar.add_child(row)

	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", 1)
	titles.add_child(_label("Circulatory System Explorer", 19, TEXT))
	subtitle_label = _label("BodyParts3D", 11, DIM)
	titles.add_child(subtitle_label)
	row.add_child(titles)
	row.add_child(_spacer())

	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 8)
	modes.add_child(_mode_button("Free flight", "free"))
	modes.add_child(_mode_button("Guided tour", "tour"))
	modes.add_child(_mode_button("Interior voyage", "interior"))
	row.add_child(modes)

	status_label = _label("", 11, DIM)
	status_label.custom_minimum_size = Vector2(160, 0)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(status_label)


func _build_left_panel() -> void:
	left_panel = _panel()
	left_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	left_panel.offset_left = 16
	left_panel.offset_top = 92
	left_panel.custom_minimum_size = Vector2(290, 0)
	left_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(left_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	left_panel.add_child(col)

	col.add_child(_section("FIND A STRUCTURE"))
	search_box = LineEdit.new()
	search_box.placeholder_text = "search  e.g. aorta, FMA3734"
	search_box.add_theme_font_size_override("font_size", 13)
	search_box.custom_minimum_size = Vector2(0, 32)
	search_box.text_changed.connect(func(t: String) -> void: search_changed.emit(t))
	col.add_child(search_box)

	list = ItemList.new()
	list.custom_minimum_size = Vector2(0, 196)
	list.add_theme_font_size_override("font_size", 12)
	list.allow_reselect = true
	list.item_selected.connect(func(i: int) -> void:
		if i >= 0 and i < _list_ids.size():
			part_picked.emit(_list_ids[i]))
	col.add_child(list)

	col.add_child(HSeparator.new())
	col.add_child(_section("VISIBILITY"))
	_add_slider(col, "arteries", "Arteries", ACCENT_A, 1.0)
	_add_slider(col, "veins", "Veins", ACCENT_V, 1.0)
	_add_slider(col, "heart", "Heart", ACCENT_H, 1.0)
	_add_slider(col, "context", "Body context", Color(0.65, 0.75, 0.9), 0.35)

	context_check = CheckBox.new()
	context_check.text = "Show body outline   B"
	context_check.button_pressed = true
	context_check.add_theme_font_size_override("font_size", 12)
	context_check.add_theme_color_override("font_color", TEXT)
	context_check.toggled.connect(func(on: bool) -> void: context_toggled.emit(on))
	col.add_child(context_check)

	labels_check = CheckBox.new()
	labels_check.text = "Show labels   L"
	labels_check.button_pressed = true
	labels_check.add_theme_font_size_override("font_size", 12)
	labels_check.add_theme_color_override("font_color", TEXT)
	labels_check.toggled.connect(func(on: bool) -> void: labels_toggled.emit(on))
	col.add_child(labels_check)

	col.add_child(HSeparator.new())
	var help := _label("WASD fly  ·  Q/E down/up  ·  Shift boost  ·  wheel = speed\n" \
			+ "Click to capture the mouse  ·  Esc releases  ·  right-click flies to a part\n" \
			+ "1 / 2 / 3 modes  ·  Space pauses  ·  ←/→ stations  ·  Tab hides the UI",
			10, Color(0.52, 0.57, 0.66))
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.custom_minimum_size = Vector2(262, 0)
	col.add_child(help)


func _add_slider(parent: Control, bucket: String, caption: String, tint: Color, value: float) -> void:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 1)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 7)
	var dot := ColorRect.new()
	dot.color = tint
	dot.custom_minimum_size = Vector2(7, 7)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(dot)
	head.add_child(_label(caption, 12, TEXT))
	head.add_child(_spacer())
	var pct := _label("%d%%" % int(value * 100), 11, DIM)
	head.add_child(pct)
	row.add_child(head)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = value
	slider.custom_minimum_size = Vector2(0, 12)
	slider.value_changed.connect(func(v: float) -> void:
		pct.text = "%d%%" % int(v * 100)
		opacity_changed.emit(bucket, v))
	row.add_child(slider)
	sliders[bucket] = slider
	parent.add_child(row)


func _build_info_panel() -> void:
	info_panel = _panel(0.92)
	info_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	info_panel.offset_left = -358
	info_panel.offset_right = -16
	info_panel.offset_top = 92
	info_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(info_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 7)
	info_panel.add_child(col)

	col.add_child(_section("INSPECTING"))
	name_label = _label("", 18, TEXT)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.custom_minimum_size = Vector2(300, 0)
	col.add_child(name_label)
	meta_label = _label("", 11, DIM)
	meta_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	meta_label.custom_minimum_size = Vector2(300, 0)
	col.add_child(meta_label)
	lineage_label = _label("", 11, Color(0.55, 0.60, 0.70))
	lineage_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lineage_label.custom_minimum_size = Vector2(300, 0)
	col.add_child(lineage_label)

	fly_button = Button.new()
	fly_button.text = "Fly to this structure"
	fly_button.add_theme_font_size_override("font_size", 12)
	fly_button.custom_minimum_size = Vector2(0, 30)
	fly_button.pressed.connect(func() -> void:
		if _current_id != "":
			part_picked.emit(_current_id))
	col.add_child(fly_button)


func _build_caption() -> void:
	caption_panel = _panel(0.94)
	caption_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	caption_panel.offset_left = -470
	caption_panel.offset_right = 470
	caption_panel.offset_bottom = -16
	caption_panel.offset_top = -16
	caption_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	caption_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(caption_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	caption_panel.add_child(col)

	var head := HBoxContainer.new()
	caption_title = _label("", 15, TEXT)
	head.add_child(caption_title)
	head.add_child(_spacer())
	caption_index = _label("", 11, DIM)
	head.add_child(caption_index)
	col.add_child(head)

	caption_text = RichTextLabel.new()
	caption_text.bbcode_enabled = true
	caption_text.fit_content = true
	caption_text.scroll_active = false
	caption_text.custom_minimum_size = Vector2(0, 38)
	caption_text.add_theme_font_size_override("normal_font_size", 13)
	caption_text.add_theme_color_override("default_color", Color(0.82, 0.86, 0.92))
	col.add_child(caption_text)

	progress_bar = ProgressBar.new()
	progress_bar.custom_minimum_size = Vector2(0, 4)
	progress_bar.show_percentage = false
	progress_bar.max_value = 1.0
	progress_bar.step = 0.001
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(1, 1, 1, 0.10)
	bg.set_corner_radius_all(2)
	progress_bar.add_theme_stylebox_override("background", bg)
	var fg := StyleBoxFlat.new()
	fg.bg_color = Color(0.86, 0.34, 0.32, 0.95)
	fg.set_corner_radius_all(2)
	progress_bar.add_theme_stylebox_override("fill", fg)
	col.add_child(progress_bar)


func _build_fade() -> void:
	fade_rect = ColorRect.new()
	fade_rect.color = Color(0.02, 0.02, 0.03, 0.0)
	fade_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(fade_rect)


func _build_loading() -> void:
	loading_panel = _panel(0.95)
	loading_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	loading_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	loading_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	loading_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(loading_panel)
	loading_label = _label("Loading anatomy…", 14, TEXT)
	loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_panel.add_child(loading_label)


# ------------------------------------------------------------------------ API
func set_mode(mode: String) -> void:
	_mode = mode
	for key in mode_buttons:
		(mode_buttons[key] as Button).set_pressed_no_signal(key == mode)
	crosshair.visible = mode == "free"
	set_caption_visible(mode != "free")
	set_vignette(mode == "interior")


func current_mode() -> String:
	return _mode


func set_vignette(on: bool) -> void:
	if vignette:
		vignette.visible = on


func set_subtitle(text: String) -> void:
	subtitle_label.text = text


func populate(matches: Array) -> void:
	list.clear()
	_list_ids.clear()
	for p in matches:
		var idx := list.add_item(String(p["name"]))
		list.set_item_tooltip(idx, "%s  ·  %s" % [String(p["fma"]), String(p["group"])])
		var colour := ACCENT_A
		match String(p["group"]):
			"vein":
				colour = ACCENT_V
			"heart":
				colour = ACCENT_H
		list.set_item_custom_fg_color(idx, colour)
		_list_ids.append(String(p["id"]))


func show_info(on: bool) -> void:
	info_panel.visible = on and panel_visible


func show_part(part: Dictionary) -> void:
	if part.is_empty():
		clear_part()
		return
	_current_id = String(part["id"])
	show_info(true)
	name_label.text = String(part["name"])
	var colour := ACCENT_A
	match String(part["group"]):
		"vein":
			colour = ACCENT_V
		"heart":
			colour = ACCENT_H
	name_label.add_theme_color_override("font_color", colour)
	var bits: Array = [String(part["fma"])]
	bits.append(String(part["group"]).to_upper())
	if String(part.get("circuit", "")) == "pulmonary":
		bits.append("PULMONARY CIRCUIT")
	bits.append("%s triangles" % _thousands(int(part.get("tris", 0))))
	meta_label.text = "  ·  ".join(bits)
	var lineage: Array = part.get("lineage", [])
	lineage_label.text = " › ".join(lineage) if lineage.size() > 1 else ""


func clear_part() -> void:
	_current_id = ""
	show_info(false)


func set_caption(title: String, text: String, index: int, total: int) -> void:
	caption_title.text = title
	caption_text.text = text
	caption_index.text = ("%d / %d" % [index + 1, total]) if total > 0 else ""


func set_caption_visible(on: bool) -> void:
	caption_panel.visible = on and panel_visible


func set_progress(v: float) -> void:
	progress_bar.value = clampf(v, 0.0, 1.0)


func set_status(text: String) -> void:
	status_label.text = text


func set_loading(text: String) -> void:
	loading_label.text = text
	loading_panel.visible = text != ""


func fade_to(alpha: float, seconds: float) -> void:
	var tw := create_tween()
	tw.tween_property(fade_rect, "color:a", alpha, seconds)


func toggle_panels() -> void:
	panel_visible = not panel_visible
	left_panel.visible = panel_visible
	info_panel.visible = panel_visible and _current_id != ""
	top_bar.visible = panel_visible
	caption_panel.visible = panel_visible and _mode != "free"
	crosshair.visible = panel_visible and _mode == "free"


func mouse_over_ui() -> bool:
	var m := root.get_viewport().get_mouse_position()
	for c in [top_bar, left_panel, info_panel, caption_panel]:
		if (c as Control).visible and (c as Control).get_global_rect().has_point(m):
			return true
	return false


func set_slider(bucket: String, value: float) -> void:
	if sliders.has(bucket):
		(sliders[bucket] as HSlider).set_value_no_signal(value)


func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return out


# ------------------------------------------------------------------ crosshair
class Crosshair extends Control:
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		draw_arc(c, 9.0, 0.0, TAU, 32, Color(1, 1, 1, 0.30), 1.0, true)
		draw_arc(c, 2.0, 0.0, TAU, 16, Color(1, 1, 1, 0.75), 1.0, true)
