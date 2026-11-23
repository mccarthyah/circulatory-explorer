extends Node3D
## Circulatory System Explorer — entry point.
##
## Three ways to move through the BodyParts3D model:
##   free flight     six-degree-of-freedom camera, hover and click to inspect
##   guided tour     a cinematic pass along the real blood path, with captions
##   interior voyage the same path from inside the lumen, blood cells streaming by

const LABELS := [
	["FJ2423", "Heart"],
	["FJ3413", "Ascending aorta"],
	["FJ3411", "Arch of aorta"],
	["FJ1931", "Descending aorta"],
	["FJ1932", "Abdominal aorta"],
	["FJ3645", "Superior vena cava"],
	["FJ3441", "Inferior vena cava"],
	["FJ2966", "Pulmonary trunk"],
	["FJ3564", "Common carotid artery"],
	["FJ2271", "Brachial artery"],
	["FJ2294", "Radial artery"],
	["FJ1853", "Hepatic portal vein"],
	["FJ3565", "Common iliac artery"],
	["FJ2143", "Femoral artery"],
	["FJ2170", "Popliteal artery"],
]

## Start at Performance, but let users raise detail and resolution.

## Graphics presets. `detail` picks the mesh file set, the rest turns the
## expensive render features on or off.
const QUALITY := {
	"performance": {
		"detail": 0, "msaa": 0, "aa": 0, "scale": 0.5,
		"glow": false, "fog": false, "adjust": false,
		"ghost": false, "labels": false, "mottle": 0.0, "pick_interval": 0.16,
	},
	"balanced": {
		"detail": 1, "msaa": 0, "aa": 1, "scale": 0.90,
		"glow": true, "fog": true, "adjust": true,
		"ghost": true, "labels": true, "mottle": 0.7, "pick_interval": 0.11,
	},
	"high": {
		"detail": 2, "msaa": 2, "aa": 0, "scale": 1.0,
		"glow": true, "fog": true, "adjust": true,
		"ghost": true, "labels": true, "mottle": 1.0, "pick_interval": 0.09,
	},
}
const QUALITY_NAMES := ["performance", "balanced", "high"]
const RENDER_SCALES := [0.0, 0.5, 0.65, 0.75, 0.9, 1.0]
const SETTINGS := "user://settings.cfg"

const TOUR_LIFT := 1.4          # cm the tour camera floats above the centreline
const HOLE_TOUR := 6.5          # cm of geometry carved away around the camera
const HOLE_TOUR_HEART := 11.5   # … and a wider bubble inside the heart
const HOLE_INTERIOR := 1.6

# preload instead of relying on the global class cache, so the project also runs
# from a plain `godot --path` (i.e. before the editor has ever opened it)
const CREDITS_DIALOG := preload("res://scripts/credits_dialog.gd")
const BOX_SELECTION := preload("res://scripts/box_selection.gd")
const PRESETS_SCRIPT := preload("res://scripts/visibility_presets.gd")
const MODEL_SCRIPT := preload("res://scripts/anatomy_model.gd")
const HUD_SCRIPT := preload("res://scripts/explorer_hud.gd")
const CAMERA_SCRIPT := preload("res://scripts/fly_camera.gd")
const PATH_SCRIPT := preload("res://scripts/blood_path.gd")

var model
var visibility_presets = PRESETS_SCRIPT.new()
var box_selection = BOX_SELECTION.new()
var _box_dragging := false
var _box_start := Vector2.ZERO
var _box_end := Vector2.ZERO
var _box_cam_enabled := false
var _last_box_ids: Array = []
var _box_notice_timer := 0.0
var hud
var cam
var path
var credits_dialog
var _credits_cam_was_enabled := false
var environment: WorldEnvironment
var labels_root: Node3D
var headlight: SpotLight3D
var env: Environment

# The menu supplies a region before this node enters the tree. Running this
# scene directly from the editor must not silently load the whole model.
var region := ""
var mode := "free"
var hover: Dictionary = {}
var selected_part: Dictionary = {}
var labels_visible := true
var quality := "performance"
var render_scale := 0.0  # 0 = follow quality preset

var _pick_interval := 0.16
var _pick_timer := 0.0
var _has_pick_ray := false
var _last_pick_origin := Vector3.ZERO
var _last_pick_dir := Vector3.ZERO
var _status_timer := 0.0
var _label_timer := 0.0
var _beat := 0.0
var _cam_up := Vector3.UP
var _tour_side := Vector3.RIGHT
var _look_point := Vector3.ZERO
var _fly: Dictionary = {}
var _fade_guard := 0.0
var _context_was_on := true
var _intro_done := false
var _controller_menu := false
var _controller_active := false


func _ready() -> void:
	if region.is_empty():
		call_deferred("_return_to_menu")
		return
	_configure_controller_ui()
	hud = HUD_SCRIPT.new()
	add_child(hud)
	hud.set_loading("Loading anatomy…")
	hud.set_mode("free")

	hud.mode_requested.connect(_on_mode_requested)
	hud.menu_requested.connect(_return_to_menu)
	hud.credits_requested.connect(_show_credits)
	hud.opacity_changed.connect(_on_opacity)
	hud.part_opacity_changed.connect(_on_part_opacity)
	hud.z_organs_toggled.connect(_on_z_organs_toggled)
	hud.hra_heart_toggled.connect(_on_hra_heart_toggled)
	hud.context_toggled.connect(_on_context_toggled)
	hud.extended_toggled.connect(_on_extended_toggled)
	hud.part_visibility_requested.connect(_on_part_visibility_requested)
	hud.show_all_requested.connect(_on_show_all_requested)
	hud.undo_box_requested.connect(_undo_box_hide)
	hud.preset_save_requested.connect(_on_preset_save)
	hud.preset_load_requested.connect(_on_preset_load)
	hud.preset_delete_requested.connect(_on_preset_delete)
	hud.labels_toggled.connect(_on_labels_toggled)
	hud.search_changed.connect(_on_search)
	hud.part_picked.connect(_on_part_picked)
	hud.quality_changed.connect(_on_quality_changed)
	hud.render_scale_changed.connect(_on_render_scale_changed)

	await get_tree().process_frame
	await get_tree().process_frame

	_build_environment()
	_build_lights()

	model = MODEL_SCRIPT.new()
	model.name = "Anatomy"
	add_child(model)
	var startup_quality := _load_quality()
	render_scale = _load_render_scale()
	if not model.load_anatomy(int(QUALITY[startup_quality]["detail"]), region):
		hud.set_loading("Could not load the anatomy data.\nCheck data/circulatory.glb")
		return

	path = PATH_SCRIPT.new()
	path.name = "BloodPath"
	add_child(path)
	if region == "all":
		path.load_path()
	path.station_reached.connect(_on_station)
	path.finished.connect(_on_path_finished)

	cam = CAMERA_SCRIPT.new()
	cam.name = "FlyCamera"
	cam.fov = 68.0
	cam.near = 0.05
	cam.far = 2000.0
	add_child(cam)
	cam.current = true
	_build_headlight()

	_build_labels()
	hud.set_regional_view(region != "all")
	_refresh_presets()
	hud.populate(model.parts_matching(""))
	hud.set_loading("")
	apply_quality(startup_quality, false)
	if region == "cardiac":
		# Cardiac includes all available related coronary vessels by default.
		_on_extended_toggled(true)
	print("[explorer] anatomy parts: %d   path length: %.1f cm   stations: %d"
			% [model.parts.size(), path.length, path.stations.size()])
	_go_free(true)
	_update_status()


# ------------------------------------------------------------------ scene setup
func _build_environment() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.012, 0.016, 0.028)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.32, 0.39, 0.55)
	env.ambient_light_energy = 0.60
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.05
	env.glow_enabled = true
	env.glow_intensity = 0.32
	env.glow_strength = 1.0
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 0.80
	env.fog_enabled = false
	env.fog_light_color = Color(0.015, 0.02, 0.035)
	env.fog_density = 0.0012
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.05
	env.adjustment_saturation = 1.05

	environment = WorldEnvironment.new()
	environment.environment = env
	add_child(environment)


func _build_lights() -> void:
	var key := DirectionalLight3D.new()
	key.name = "Key"
	key.light_energy = 1.10
	key.light_color = Color(1.0, 0.96, 0.93)
	key.shadow_enabled = false
	key.rotation_degrees = Vector3(-34, -140, 0)
	add_child(key)

	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.light_energy = 0.55
	fill.light_color = Color(0.52, 0.68, 1.0)
	fill.shadow_enabled = false
	fill.rotation_degrees = Vector3(-12, 60, 0)
	add_child(fill)

	var rim := DirectionalLight3D.new()
	rim.name = "Rim"
	rim.light_energy = 0.40
	rim.light_color = Color(1.0, 0.58, 0.48)
	rim.shadow_enabled = false
	rim.rotation_degrees = Vector3(28, 15, 0)
	add_child(rim)


func _build_headlight() -> void:
	headlight = SpotLight3D.new()
	headlight.name = "Headlight"
	headlight.spot_range = 16.0
	headlight.spot_angle = 62.0
	headlight.spot_angle_attenuation = 1.0
	headlight.light_energy = 0.55
	headlight.light_color = Color(1.0, 0.90, 0.86)
	headlight.shadow_enabled = false
	headlight.visible = false
	cam.add_child(headlight)


func _build_labels() -> void:
	labels_root = Node3D.new()
	labels_root.name = "Labels"
	add_child(labels_root)
	for entry in LABELS:
		var part: Dictionary = model.by_id.get(entry[0], {})
		if part.is_empty():
			continue
		var box: AABB = part["aabb"]
		var label := Label3D.new()
		label.text = String(entry[1])
		label.set_meta("part_id", String(entry[0]))
		label.font_size = 40
		label.pixel_size = 0.032
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.shaded = false
		label.outline_size = 12
		label.outline_modulate = Color(0.02, 0.02, 0.04, 0.85)
		label.modulate = Color(0.94, 0.95, 0.99, 0.95)
		label.position = box.get_center() + Vector3(0, box.size.y * 0.5 + 1.4, 0)
		labels_root.add_child(label)


# ---------------------------------------------------------------------- modes
func _show_credits() -> void:
	if cam == null:
		return
	if cam.captured:
		cam.capture_mouse(false)
	if credits_dialog == null:
		credits_dialog = CREDITS_DIALOG.new()
		hud.add_child(credits_dialog)
		credits_dialog.visibility_changed.connect(_on_credits_visibility_changed)
	_credits_cam_was_enabled = cam.enabled
	cam.enabled = false
	credits_dialog.popup_centered(Vector2i(760, 580))


func _on_credits_visibility_changed() -> void:
	if credits_dialog != null and not credits_dialog.visible and cam != null:
		cam.enabled = _credits_cam_was_enabled


func _return_to_menu() -> void:
	if cam != null and cam.captured:
		cam.capture_mouse(false)
	get_tree().change_scene_to_file("res://scenes/start.tscn")


func _on_mode_requested(m: String) -> void:
	if region != "all" and m != "free":
		return
	match m:
		"free":
			_go_free(false)
		"tour":
			_go_path(false)
		"interior":
			_go_path(true)


func _go_free(first := false) -> void:
	_fly = {}
	_has_pick_ray = false
	mode = "free"
	hud.set_mode("free")
	path.flow_visible(false)
	path.stop()
	_set_opacity_preset(false)
	_sync_detail()
	_set_atmosphere(false)
	cam.enabled = true
	cam.fov = 68.0
	headlight.visible = false
	if _context_was_on:
		model.set_context_visible(true)
	_apply_context_opacity()
	if not hover.is_empty():
		hud.show_part(_card(hover))
	elif not selected_part.is_empty():
		hud.show_part(_card(selected_part))
	else:
		hud.show_info(false)

	if first:
		var target: Vector3 = model.group_centre("heart")
		var offset := Vector3(27.0, 11.0, -39.0)
		if region != "all":
			target = model.bounds.get_center()
			var distance: float = clampf(model.bounds.size.length() * 0.9, 18.0, 180.0)
			offset = Vector3(distance * 0.35, distance * 0.12, -distance)
		cam.aim_from(target + offset, target)
		_look_point = target
		_cam_up = Vector3.UP
	else:
		cam.sync_angles()
	_intro_done = true


func _go_path(interior: bool) -> void:
	_fly = {}
	mode = "interior" if interior else "tour"
	hud.set_mode(mode)
	cam.enabled = false
	path.flow_visible(interior)
	_set_opacity_preset(not interior)
	_set_atmosphere(interior)
	_sync_detail()
	cam.fov = 88.0 if interior else 72.0
	headlight.visible = interior
	_context_was_on = model.is_context_visible()
	_apply_context_opacity()
	path.loop = interior
	path.speed = 36.0 if interior else 20.0
	path.hold_time = 0.0 if interior else 3.6
	_cam_up = Vector3.UP
	hud.clear_part()
	model.highlight({})
	hover = {}
	labels_root.visible = false

	var start := _path_camera_position(0.0)
	var ahead := _path_camera_target(0.0)
	_look_point = ahead
	if interior:
		path.start(0.0)
		cam.global_position = path.position_at(0.0)
	else:
		# start wide: an establishing shot of the whole vascular tree, then dive in
		var heart: Vector3 = model.group_centre("heart")
		_fly = {
			"from": heart + Vector3(46.0, 16.0, -62.0), "to": start,
			"from_look": heart, "to_look": ahead, "t": 0.0, "dur": 3.2, "then": "tour",
		}


func _set_opacity_preset(xray: bool) -> void:
	var translucent := xray and quality != "performance"
	var a := 0.85 if translucent else 1.0
	model.set_bucket_opacity("arteries", a)
	model.set_bucket_opacity("veins", a)
	model.set_bucket_opacity("heart", 0.92 if translucent else 1.0)
	hud.set_slider("arteries", a)
	hud.set_slider("veins", a)
	hud.set_slider("heart", 0.92 if translucent else 1.0)


func _set_atmosphere(interior: bool) -> void:
	var preset: Dictionary = QUALITY.get(quality, QUALITY["performance"])
	# Performance stays cheap; higher presets can use depth fog, including inside.
	env.fog_enabled = bool(preset["fog"])
	if interior:
		env.fog_density = 0.05
		env.fog_light_color = Color(0.075, 0.010, 0.014)
		env.ambient_light_energy = 0.22
		env.background_color = Color(0.085, 0.011, 0.015)
		env.glow_intensity = 0.10
		env.tonemap_exposure = 0.90
	else:
		env.fog_density = 0.0012
		env.fog_light_color = Color(0.015, 0.02, 0.035)
		env.ambient_light_energy = 0.60
		env.background_color = Color(0.012, 0.016, 0.028)
		env.glow_intensity = 0.32
		env.tonemap_exposure = 1.05


# --------------------------------------------------------------------- quality
# An explicit file override keeps test and benchmark runs away from real settings.
func _settings_path() -> String:
	var override := OS.get_environment("EXPLORER_SETTINGS_PATH")
	return override if not override.is_empty() else SETTINGS


func _load_quality() -> String:
	# Always start safely even if a previous session saved a higher setting.
	return "performance"


func _load_render_scale() -> float:
	return 0.0 # follow the Performance preset on startup


func _on_render_scale_changed(scale: float) -> void:
	if not RENDER_SCALES.has(scale):
		return
	render_scale = scale
	_apply_render_scale()
	hud.set_render_scale(scale)
	var cf := ConfigFile.new()
	cf.load(_settings_path())
	cf.set_value("graphics", "render_scale", scale)
	cf.save(_settings_path())


func _apply_render_scale() -> void:
	var preset: Dictionary = QUALITY.get(quality, QUALITY["performance"])
	get_viewport().scaling_3d_scale = render_scale if render_scale > 0.0 else float(preset["scale"])


func _save_quality(q: String) -> void:
	var cf := ConfigFile.new()
	cf.load(_settings_path())
	cf.set_value("graphics", "quality", q)
	cf.save(_settings_path())


func _on_quality_changed(q: String) -> void:
	apply_quality(q, true)


func apply_quality(q: String, reload_meshes := true) -> void:
	_has_pick_ray = false
	if not QUALITY.has(q):
		q = "performance"
	quality = q
	if model != null and mode == "tour":
		_set_opacity_preset(true)
	var preset: Dictionary = QUALITY[q]

	var vp := get_viewport()
	if vp != null:
		vp.msaa_3d = int(preset["msaa"])
		vp.screen_space_aa = int(preset["aa"])
		_apply_render_scale()
	if env != null:
		env.glow_enabled = bool(preset["glow"])
		env.fog_enabled = bool(preset["fog"])
		env.adjustment_enabled = bool(preset["adjust"])
		_set_atmosphere(mode == "interior")

	_pick_interval = float(preset["pick_interval"])
	if path != null:
		path.set_flow_density(int(preset["detail"]))
	labels_visible = bool(preset["labels"])
	hud.labels_check.set_pressed_no_signal(labels_visible)

	if model != null:
		model.set_mottle(float(preset["mottle"]))
		if reload_meshes:
			hover = {}
			selected_part = {}
			model.highlight({})
			hud.clear_part()
			model.reload(_effective_detail())
		var ghost: bool = region == "all" and bool(preset["ghost"])
		model.set_context_visible(ghost)
		hud.context_check.set_pressed_no_signal(ghost)
		_context_was_on = ghost
		if ghost:
			_apply_context_opacity()
		_update_subtitle()
	hud.set_quality(q)
	hud.set_render_scale(render_scale)
	hud.set_graphics_locked(false)
	if reload_meshes:
		_save_quality(q)


func _update_subtitle() -> void:
	if model == null:
		return
	var ghost: bool = model.is_context_visible()
	var label := String(QUALITY_NAMES[model.detail])
	if model.detail != _quality_detail():
		label += " (interior)"
	hud.set_subtitle("%s  ·  %d parts  ·  %s triangles  ·  %s"
			% [region.capitalize(), model.parts.size(), _thousands(model.total_tris(ghost)), label])


func _thousands(n: int) -> String:
	var txt := str(n)
	var out := ""
	var count := 0
	for i in range(txt.length() - 1, -1, -1):
		out = txt[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return out


func _effective_detail() -> int:
	return _quality_detail()


func _sync_detail() -> void:
	if model == null:
		return
	if model.detail != _effective_detail():
		hover = {}
		model.highlight({})
		model.reload(_effective_detail())
		_update_subtitle()


func _quality_detail() -> int:
	return int(QUALITY.get(quality, QUALITY["performance"])["detail"])


# ------------------------------------------------------------------- HUD input
func _on_opacity(bucket: String, value: float) -> void:
	_has_pick_ray = false
	match bucket:
		"arteries":
			model.set_bucket_opacity("arteries", value)
		"veins":
			model.set_bucket_opacity("veins", value)
		"heart":
			model.set_bucket_opacity("heart", value)
		"z_organs", "hra_heart":
			model.set_bucket_opacity(bucket, value)
		"context":
			model.set_bucket_opacity("context", value)
			if value > 0.0 and not model.is_context_visible():
				model.set_context_visible(true)
				hud.context_check.set_pressed_no_signal(true)
				_context_was_on = true
	model.highlight(hover if not hover.is_empty() else selected_part)


func _on_z_organs_toggled(on: bool) -> void:
	var success: bool = model.set_z_organs_visible(on)
	hud.z_organs_check.set_pressed_no_signal(success and on)
	_has_pick_ray = false
	if not on:
		if String(hover.get("material", "")) == "z_organs":
			hover = {}
		if String(selected_part.get("material", "")) == "z_organs":
			selected_part = {}
			if not _fly.is_empty():
				_fly = {}
				cam.enabled = true
				cam.sync_angles()
		model.highlight(hover if not hover.is_empty() else selected_part)
		if hover.is_empty() and selected_part.is_empty():
			hud.clear_part()
	hud.populate(model.parts_matching(hud.search_box.text))
	_update_subtitle()


func _on_hra_heart_toggled(on: bool) -> void:
	var success: bool = model.set_hra_heart_visible(on)
	hud.hra_heart_check.set_pressed_no_signal(success and on)
	_has_pick_ray = false
	if not on:
		if String(hover.get("material", "")) == "hra_heart":
			hover = {}
		if String(selected_part.get("material", "")) == "hra_heart":
			selected_part = {}
			if not _fly.is_empty():
				_fly = {}
				cam.enabled = true
				cam.sync_angles()
		model.highlight(hover if not hover.is_empty() else selected_part)
		if hover.is_empty() and selected_part.is_empty():
			hud.clear_part()
	hud.populate(model.parts_matching(hud.search_box.text))
	_update_subtitle()


func _on_part_opacity(id: String, value: float) -> void:
	model.set_part_opacity(id, value)
	_has_pick_ray = false
	model.highlight(hover if not hover.is_empty() else selected_part)


func _on_context_toggled(on: bool) -> void:
	if region != "all":
		hud.context_check.set_pressed_no_signal(false)
		return
	model.set_context_visible(on)
	_context_was_on = on
	_update_subtitle()
	if on:
		_apply_context_opacity()


func _on_extended_toggled(on: bool) -> void:
	var success: bool = model.set_extended_visible(on)
	hud.extended_check.set_pressed_no_signal(success and on)
	_has_pick_ray = false
	if not model.is_extended_visible():
		if bool(hover.get("extended", false)):
			hover = {}
		if bool(selected_part.get("extended", false)):
			selected_part = {}
			if not _fly.is_empty():
				_fly = {}
				cam.enabled = true
				cam.sync_angles()
		model.highlight(hover if not hover.is_empty() else selected_part)
		if hover.is_empty() and selected_part.is_empty():
			hud.clear_part()
		elif not hover.is_empty():
			hud.show_part(_card(hover))
		else:
			hud.show_part(_card(selected_part))
	_update_subtitle()


func _apply_context_opacity() -> void:
	var v := float(hud.sliders["context"].value)
	model.set_bucket_opacity("context", v)


func _on_part_visibility_requested(id: String) -> void:
	_clear_box_undo()
	var part: Dictionary = model.by_id.get(id, {})
	if part.is_empty():
		return
	var hidden := not bool(part.get("hidden", false))
	model.set_part_hidden(id, hidden)
	selected_part = part
	hover = {}
	model.highlight({} if hidden else part)
	if hidden and not _fly.is_empty():
		_fly = {}
		cam.enabled = true
		cam.sync_angles()
	_has_pick_ray = false
	hud.show_part(_card(part))
	hud.populate(model.parts_matching(hud.search_box.text))
	_update_subtitle()


func _on_show_all_requested() -> void:
	_clear_box_undo()
	model.show_all_parts()
	_has_pick_ray = false
	hud.populate(model.parts_matching(hud.search_box.text))
	if not selected_part.is_empty():
		hud.show_part(_card(selected_part))
	_update_subtitle()


func _refresh_presets(selected: String = "") -> void:
	var result: Dictionary = visibility_presets.list_names(region)
	if result.ok:
		hud.set_preset_names(result.names, selected)
	else:
		hud.set_preset_names([])
		hud.set_preset_message(result.error)


func _on_preset_save(name: String, overwrite: bool) -> void:
	name = name.strip_edges()
	var result: Dictionary = visibility_presets.save_preset(region, name, {"hidden": model.hidden_part_ids()}, overwrite)
	if not result.ok:
		hud.set_preset_message(result.error)
		return
	_refresh_presets(name)
	hud.set_preset_message("Saved ‘%s’ for this view." % name)


func _on_preset_load(name: String) -> void:
	var result: Dictionary = visibility_presets.load_preset(region, name)
	if not result.ok:
		_refresh_presets()
		hud.set_preset_message(result.error)
		return
	_clear_box_undo()
	model.show_all_parts()
	var missing := 0
	for id in result.state.hidden:
		if model.has_part_id(id):
			model.set_part_hidden(id, true)
		else:
			missing += 1
	hover = {}
	model.highlight({})
	_has_pick_ray = false
	if not selected_part.is_empty() and bool(selected_part.get("hidden", false)) and not _fly.is_empty():
		_fly = {}
		cam.enabled = true
		cam.sync_angles()
	if not selected_part.is_empty():
		hud.show_part(_card(selected_part))
	hud.populate(model.parts_matching(hud.search_box.text))
	_update_subtitle()
	var message := "Loaded ‘%s’ for this view." % name
	if missing > 0:
		message += " %d unavailable IDs skipped." % missing
	hud.set_preset_message(message)


func _on_preset_delete(name: String) -> void:
	var result: Dictionary = visibility_presets.delete_preset(region, name)
	if not result.ok:
		hud.set_preset_message(result.error)
		return
	_refresh_presets()
	hud.set_preset_message("Deleted ‘%s’ from this view." % name)


func _on_labels_toggled(on: bool) -> void:
	labels_visible = on
	if labels_root:
		labels_root.visible = on and mode == "free"


func _on_search(text: String) -> void:
	hud.populate(model.parts_matching(text))


func _on_part_picked(id: String) -> void:
	var part: Dictionary = model.by_id.get(id, {})
	if part.is_empty():
		return
	if String(part.get("material", "")) == "hra_heart" and not model._hra_heart_on:
		_on_hra_heart_toggled(true)
	if String(part.get("material", "")) == "z_organs" and not model._z_organs_on:
		_on_z_organs_toggled(true)
	if String(part.get("group", "")) == "context" and not model.is_context_visible():
		_on_context_toggled(true)
		hud.context_check.set_pressed_no_signal(model.is_context_visible())
	if bool(part.get("extended", false)) and not model.is_extended_visible():
		_on_extended_toggled(true)
		if not model.is_extended_visible():
			return
	selected_part = part
	hud.show_part(_card(part))
	model.highlight(part)
	if mode != "free":
		_go_free(false)
	var view: Dictionary = model.viewpoint_for(part, cam.global_position)
	_fly = {
		"from": cam.global_position, "to": view["position"],
		"from_look": _look_point, "to_look": view["target"],
		"t": 0.0, "dur": clampf(0.5 + float(view["distance"]) * 0.012, 0.6, 2.6), "then": "",
	}
	cam.enabled = false


## A copy of a catalogue entry with the triangle count of the current detail.
func _card(part: Dictionary) -> Dictionary:
	if part.is_empty():
		return part
	var copy := part.duplicate()
	copy["tris"] = model.tris_of(part)
	copy["opacity_factor"] = model.part_opacity(String(part["id"]))
	return copy


# ---------------------------------------------------------------------- tour
func _on_station(index: int, st: Dictionary) -> void:
	hud.set_caption(String(st["title"]), String(st["text"]), index, path.stations.size())
	hud.set_progress(path.fraction())


func _on_path_finished() -> void:
	if mode == "interior":
		hud.fade_to(0.92, 0.20)
		_fade_guard = 0.34
	else:
		hud.set_status("tour complete  ·  press 2 to replay")


func _path_camera_position(offset_cm: float) -> Vector3:
	var p: Vector3 = path.position_at(offset_cm)
	return p + Vector3.UP * TOUR_LIFT if mode == "tour" else p


func _path_camera_target(offset_cm: float) -> Vector3:
	var ahead := 9.5 if mode == "tour" else 7.0
	var p: Vector3 = path.position_at(minf(offset_cm + ahead, path.length))
	return p + Vector3.UP * TOUR_LIFT * 0.5 if mode == "tour" else p


# ------------------------------------------------------------------- per frame
func _process(delta: float) -> void:
	if credits_dialog != null and credits_dialog.visible:
		return
	if model == null or cam == null:
		return

	if _box_notice_timer > 0.0:
		_box_notice_timer -= delta
		if _box_notice_timer <= 0.0:
			hud.set_box_notice("")
	_heartbeat(delta)
	_update_fade(delta)
	_update_labels(delta)
	var hole := 0.0
	if mode == "tour":
		# the heart is a thicket of valves, chamber casts and coronary branches:
		# open the cutaway wider there so the first stations stay readable
		var w := clampf((path.fraction() - 0.16) / 0.07, 0.0, 1.0)
		hole = lerpf(HOLE_TOUR_HEART, HOLE_TOUR, w)
	elif mode == "interior":
		hole = HOLE_INTERIOR
	model.set_hole(cam.global_position, hole)

	if _fly.size() > 0:
		_update_fly(delta)
	elif mode == "free":
		if not _box_dragging:
			_update_hover(delta)
	else:
		_update_path_camera(delta)

	_status_timer -= delta
	if _status_timer <= 0.0:
		_status_timer = 0.25
		_update_status()


func _heartbeat(delta: float) -> void:
	_beat = fmod(_beat + delta * 1.2, 1.0)          # ~72 bpm
	var pulse := pow(maxf(0.0, sin(_beat * TAU)), 6.0)
	model.set_heart_emission(0.5 + pulse * 1.8)


func _update_labels(delta: float) -> void:
	if labels_root == null:
		return
	_label_timer -= delta
	if _label_timer > 0.0:
		return
	_label_timer = 0.12
	if not labels_visible or mode != "free":
		labels_root.visible = false
		return
	labels_root.visible = true
	var ranked: Array = []
	for child in labels_root.get_children():
		var l := child as Label3D
		var labelled_part: Dictionary = model.by_id.get(String(l.get_meta("part_id", "")), {})
		if labelled_part.is_empty() or bool(labelled_part.get("hidden", false)):
			l.visible = false
			continue
		ranked.append([cam.global_position.distance_to(l.global_position), l])
	ranked.sort_custom(func(a, b): return a[0] < b[0])
	for i in ranked.size():
		var l: Label3D = ranked[i][1]
		var d: float = ranked[i][0]
		var near := clampf((d - 8.0) / 10.0, 0.0, 1.0)       # fade out when too close
		var far := clampf((130.0 - d) / 60.0, 0.0, 1.0)      # fade out when far away
		var a := near * far
		if i >= 6:
			a = 0.0                                          # only the 6 nearest labels
		l.visible = a > 0.03
		l.modulate.a = a


func _update_path_camera(delta: float) -> void:
	path.advance(delta)
	var pos := _path_camera_position(path.progress)
	cam.global_position = pos
	var target := _path_camera_target(path.progress)
	_look_point = _look_point.lerp(target, 1.0 - exp(-7.0 * delta))
	_look_at_smooth(_look_point, delta)
	hud.set_progress(path.fraction())
	if mode == "interior" and path.stations.size() > 0:
		var idx: int = path.station_at(path.fraction())
		if idx >= 0:
			var st: Dictionary = path.stations[idx]
			hud.set_caption(String(st["title"]), String(st["text"]), idx, path.stations.size())


func _look_at_smooth(target: Vector3, delta: float) -> void:
	var fwd: Vector3 = target - cam.global_position
	if fwd.length() < 0.001:
		return
	fwd = fwd.normalized()
	# parallel-transport the up vector so vertical stretches never flip the camera
	var up: Vector3 = _cam_up - fwd * _cam_up.dot(fwd)
	if up.length() < 0.001:
		up = Vector3.UP - fwd * Vector3.UP.dot(fwd)
	up = up.normalized()
	_cam_up = up
	var right := fwd.cross(up).normalized()
	up = right.cross(fwd).normalized()
	var xf: Transform3D = cam.global_transform
	xf.basis = Basis(right, up, -fwd)
	cam.global_transform = xf


func _update_hover(delta: float) -> void:
	# Keep the inspected card stable while interacting with its buttons.
	if _controller_menu or (not cam.captured and hud.mouse_over_ui()):
		return
	_pick_timer -= delta
	if _pick_timer > 0.0:
		return
	_pick_timer = _pick_interval
	var origin: Vector3 = cam.global_position
	var dir: Vector3 = -cam.global_transform.basis.z
	if _has_pick_ray and origin.is_equal_approx(_last_pick_origin) and dir.is_equal_approx(_last_pick_dir):
		return
	_has_pick_ray = true
	_last_pick_origin = origin
	_last_pick_dir = dir
	var hit: Dictionary = model.pick(origin, dir)
	if String(hit.get("id", "")) == String(hover.get("id", "")):
		return
	hover = hit
	if not hover.is_empty():
		model.highlight(hover)
		hud.show_part(_card(hover))
	else:
		model.highlight(selected_part)
		if selected_part.is_empty():
			hud.show_info(false)
		else:
			hud.show_part(_card(selected_part))


func _update_fly(delta: float) -> void:
	_fly["t"] = float(_fly["t"]) + delta / float(_fly["dur"])
	var t := clampf(float(_fly["t"]), 0.0, 1.0)
	var e := t * t * (3.0 - 2.0 * t)      # smoothstep
	cam.global_position = (Vector3(_fly["from"]) as Vector3).lerp(Vector3(_fly["to"]), e)
	_look_point = (Vector3(_fly["from_look"]) as Vector3).lerp(Vector3(_fly["to_look"]), e)
	_look_at_smooth(_look_point, delta)
	if t >= 1.0:
		var then: String = String(_fly["then"])
		_fly = {}
		if then == "tour":
			path.start(0.0)
			cam.enabled = false
			_tour_side = Vector3.RIGHT
		else:
			cam.enabled = true
			cam.sync_angles()


func _update_fade(delta: float) -> void:
	if _fade_guard > 0.0:
		_fade_guard -= delta
		if _fade_guard <= 0.0:
			hud.fade_to(0.0, 0.6)


func _update_status() -> void:
	var bits: Array = []
	match mode:
		"free":
			bits.append("free flight")
			bits.append(cam.speed_label())
		"tour":
			bits.append("guided tour")
			bits.append("%d%%" % int(path.fraction() * 100.0))
		"interior":
			bits.append("interior voyage")
			bits.append("%d%%" % int(path.fraction() * 100.0))
	bits.append("%d fps" % Engine.get_frames_per_second())
	hud.set_status("   ·   ".join(bits))


# ----------------------------------------------------------------- controller
func _configure_controller_ui() -> void:
	# Godot's default ui_accept/ui_cancel bindings do not include A/B. Extend
	# them instead of replacing the built-in keyboard bindings.
	for mapping in [["ui_accept", JOY_BUTTON_A], ["ui_cancel", JOY_BUTTON_B]]:
		var event := InputEventJoypadButton.new()
		event.device = -1
		event.button_index = mapping[1]
		if not InputMap.action_has_event(mapping[0], event):
			InputMap.action_add_event(mapping[0], event)


func _set_controller_menu(on: bool) -> void:
	_controller_menu = on
	cam.set_gamepad_enabled(not on)
	if on:
		if cam.captured:
			cam.capture_mouse(false)
		hud.focus_controller_menu()
	else:
		hud.release_controller_menu()


func _input(event: InputEvent) -> void:
	if _box_dragging:
		if event is InputEventMouseMotion:
			var motion := event as InputEventMouseMotion
			if cam.captured:
				_box_end += motion.relative
			else:
				_box_end = motion.position
			var size := get_viewport().get_visible_rect().size
			_box_end = _box_end.clamp(Vector2.ZERO, size)
			hud.set_box_drag(true, Rect2(_box_start, _box_end - _box_start).abs())
			get_viewport().set_input_as_handled()
			return
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_end_box_drag(true)
			get_viewport().set_input_as_handled()
			return
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_end_box_drag(false)
			get_viewport().set_input_as_handled()
			return
		if event is InputEventJoypadButton or event is InputEventJoypadMotion:
			_end_box_drag(false)
			return
		# Avoid changing modes, camera speed or UI controls while dragging.
		get_viewport().set_input_as_handled()
		return
	if credits_dialog != null and credits_dialog.visible:
		return
	if not _intro_done:
		return
	if event is InputEventJoypadButton:
		var button := event as InputEventJoypadButton
		if button.pressed:
			_controller_active = true
			if cam.captured:
				cam.capture_mouse(false)
			if event.is_action_pressed("pad_menu"):
				_set_controller_menu(not _controller_menu)
				get_viewport().set_input_as_handled()
				return
			if not _controller_menu:
				_handle_controller_button(event)
		if not _controller_menu:
			get_viewport().set_input_as_handled()
	elif event is InputEventJoypadMotion:
		var motion := event as InputEventJoypadMotion
		if absf(motion.axis_value) > 0.2:
			_controller_active = true
			if cam.captured:
				cam.capture_mouse(false)
		if not _controller_menu:
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton or event is InputEventKey:
		_controller_active = false


func _handle_controller_button(event: InputEvent) -> void:
	if event.is_action_pressed("pad_cycle_mode"):
		var modes := ["free", "tour", "interior"]
		_on_mode_requested(modes[(modes.find(mode) + 1) % modes.size()])
	elif event.is_action_pressed("pad_back"):
		if mode != "free" or not _fly.is_empty():
			_go_free(false)
	elif event.is_action_pressed("pad_select"):
		if mode == "free":
			if not hover.is_empty() and _fly.is_empty():
				_on_part_picked(String(hover["id"]))
		elif not _fly.is_empty():
			# Skip the tour fly-in and start paused at its first station.
			_fly = {}
			path.start(0.0)
			path.playing = false
		else:
			path.playing = not path.playing
	elif event.is_action_pressed("pad_prev"):
		if mode == "free":
			cam.base_speed = clampf(cam.base_speed / 1.18, 1.0, 400.0)
		else:
			path.prev_station()
	elif event.is_action_pressed("pad_next"):
		if mode == "free":
			cam.base_speed = clampf(cam.base_speed * 1.18, 1.0, 400.0)
		else:
			path.next_station()
	elif event.is_action_pressed("pad_ghost"):
		var on: bool = not model.is_context_visible()
		hud.context_check.set_pressed_no_signal(on)
		_on_context_toggled(on)
	elif event.is_action_pressed("pad_labels"):
		_on_labels_toggled(not labels_visible)
		hud.labels_check.set_pressed_no_signal(labels_visible)
	elif event.is_action_pressed("pad_toggle_panels"):
		hud.toggle_panels()


# -------------------------------------------------------------------- keyboard
func _unhandled_input(event: InputEvent) -> void:
	if credits_dialog != null and credits_dialog.visible:
		return
	if not _intro_done:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_1:
				_on_mode_requested("free")
			KEY_2:
				_on_mode_requested("tour")
			KEY_3:
				_on_mode_requested("interior")
			KEY_ESCAPE:
				if mode != "free":
					_on_mode_requested("free")
				if cam.captured:
					cam.capture_mouse(false)
			KEY_SPACE:
				if mode != "free":
					path.playing = not path.playing
			KEY_RIGHT:
				if mode != "free":
					path.next_station()
			KEY_LEFT:
				if mode != "free":
					path.prev_station()
			KEY_TAB:
				if _controller_menu:
					_set_controller_menu(false)
				hud.toggle_panels()
			KEY_Z:
				var focus := get_viewport().gui_get_focus_owner()
				if event.ctrl_pressed and not event.alt_pressed and not (focus is LineEdit or focus is TextEdit):
					_undo_box_hide()
			KEY_H:
				var focus := get_viewport().gui_get_focus_owner()
				if mode == "free" and cam.captured and not _controller_menu and _fly.is_empty() and not (focus is LineEdit or focus is TextEdit):
					var hit: Dictionary = model.pick(cam.global_position, -cam.global_transform.basis.z)
					if not hit.is_empty() and not bool(hit.get("hidden", false)):
						_on_part_visibility_requested(String(hit.get("id", "")))
			KEY_L:
				_on_labels_toggled(not labels_visible)
				hud.labels_check.set_pressed_no_signal(labels_visible)
			KEY_B:
				var on: bool = not model.is_context_visible()
				hud.context_check.set_pressed_no_signal(on)
				_on_context_toggled(on)
			KEY_R:
				_go_free(true)
			KEY_F9:
				var i := QUALITY_NAMES.find(quality)
				apply_quality(String(QUALITY_NAMES[(i + 1) % QUALITY_NAMES.size()]), true)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and mode == "free":
			if mb.shift_pressed and not _controller_menu and _fly.is_empty() and (cam.captured or not hud.mouse_over_ui()):
				_begin_box_drag(mb.position)
				get_viewport().set_input_as_handled()
			elif not cam.captured and not hud.mouse_over_ui():
				# Text fields must not keep consuming flight shortcuts after recapture.
				get_viewport().gui_release_focus()
				cam.capture_mouse(true)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT and mode == "free":
			if not hover.is_empty():
				_on_part_picked(String(hover["id"]))


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _box_dragging:
		_end_box_drag(false)


func _begin_box_drag(pointer: Vector2) -> void:
	get_viewport().gui_release_focus()
	_box_dragging = true
	_box_start = get_viewport().get_visible_rect().size * 0.5 if cam.captured else pointer
	_box_end = _box_start
	_box_cam_enabled = cam.enabled
	cam.enabled = false
	hud.set_box_drag(true)
	_box_notice("Box hide: release to hide through all depths · Esc cancels")


func _end_box_drag(apply: bool) -> void:
	if not _box_dragging:
		return
	_box_dragging = false
	cam.enabled = _box_cam_enabled
	hud.set_box_drag(false)
	var rect := Rect2(_box_start, _box_end - _box_start).abs()
	if not apply:
		_box_notice("Box hide cancelled")
		return
	if rect.size.x < 6.0 or rect.size.y < 6.0:
		_box_notice("Drag a larger box to hide structures")
		return
	var ids: Array = box_selection.parts_in_rect(model, cam, rect)
	if ids.is_empty():
		_box_notice("No structures in box")
		return
	_last_box_ids = ids
	for id in ids:
		model.set_part_hidden(id, true)
	hud.undo_box_button.disabled = false
	hover = {}
	model.highlight({})
	_has_pick_ray = false
	if not selected_part.is_empty():
		hud.show_part(_card(selected_part))
	hud.populate(model.parts_matching(hud.search_box.text))
	_update_subtitle()
	_box_notice("Hidden %d structures · Ctrl+Z undoes last box" % ids.size())


func _clear_box_undo() -> void:
	_last_box_ids.clear()
	if hud != null and hud.undo_box_button != null:
		hud.undo_box_button.disabled = true


func _undo_box_hide() -> void:
	if _last_box_ids.is_empty():
		return
	var count := _last_box_ids.size()
	for id in _last_box_ids:
		model.set_part_hidden(id, false)
	_clear_box_undo()
	_has_pick_ray = false
	hud.populate(model.parts_matching(hud.search_box.text))
	if not selected_part.is_empty():
		hud.show_part(_card(selected_part))
	_update_subtitle()
	_box_notice("Restored %d structures from last box" % count)


func _box_notice(text: String) -> void:
	hud.set_box_notice(text)
	_box_notice_timer = 4.0
