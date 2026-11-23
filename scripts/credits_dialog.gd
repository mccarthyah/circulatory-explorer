extends AcceptDialog
## The notice is compiled into the app, even if raw .txt files are excluded by
## an export preset. ATTRIBUTION.txt remains the standalone source of truth.

const CREDITS := preload("res://scripts/credits_text.gd")
var notice: RichTextLabel


func _ready() -> void:
	title = "Credits and data licenses"
	get_ok_button().text = "Close"
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	add_child(col)
	notice = RichTextLabel.new()
	notice.text = CREDITS.NOTICE
	notice.selection_enabled = true
	notice.scroll_active = true
	notice.size_flags_vertical = Control.SIZE_EXPAND_FILL
	notice.custom_minimum_size = Vector2(600, 340)
	col.add_child(notice)
	var links := HBoxContainer.new()
	links.add_theme_constant_override("separation", 8)
	col.add_child(links)
	_add_link(links, "BodyParts3D", "https://dbarchive.biosciencedbc.jp/en/bodyparts3d/lic.html")
	_add_link(links, "CC BY 4.0", "https://creativecommons.org/licenses/by/4.0/")
	_add_link(links, "CC BY-SA 2.1 JP", "https://creativecommons.org/licenses/by-sa/2.1/jp/")


func _add_link(parent: Control, label: String, url: String) -> void:
	var button := Button.new()
	button.text = label
	button.pressed.connect(func() -> void: OS.shell_open(url))
	parent.add_child(button)
