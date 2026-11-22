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

## Graphics presets. `detail` picks the mesh file set, the rest turns the
## expensive render features on or off.
const QUALITY := {
	"performance": {
		"detail": 0, "msaa": 0, "aa": 0, "scale": 0.75,
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
const SETTINGS := "user://settings.cfg"

const TOUR_LIFT := 1.4          # cm the tour camera floats above the centreline
const HOLE_TOUR := 6.5          # cm of geometry carved away around the camera
const HOLE_TOUR_HEART := 11.5   # … and a wider bubble inside the heart
const HOLE_INTERIOR := 1.6

# preload instead of relying on the global class cache, so the project also runs
# from a plain `godot --path` (i.e. before the editor has ever opened it)
const MODEL_SCRIPT := preload("res://scripts/anatomy_model.gd")
const HUD_SCRIPT := preload("res://scripts/explorer_hud.gd")
const CAMERA_SCRIPT := preload("res://scripts/fly_camera.gd")
const PATH_SCRIPT := preload("res://scripts/blood_path.gd")

var model
var hud
var cam
var path
var environment: WorldEnvironment
var labels_root: Node3D
var headlight: SpotLight3D
var env: Environment

var mode := "free"
var hover: Dictionary = {}
var selected_part: Dictionary = {}
var labels_visible := true
var quality := "performance"

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
var _context_scale := 0.30        # ghost strength: stronger when outside the body
var _intro_done := false


func _ready() -> void:
	hud = HUD_SCRIPT.new()
	add_child(hud)
	hud.set_loading("Loading anatomy…")
	hud.set_mode("free")

	hud.mode_requested.connect(_on_mode_requested)
	hud.opacity_changed.connect(_on_opacity)
	hud.context_toggled.connect(_on_context_toggled)
	hud.labels_toggled.connect(_on_labels_toggled)
	hud.search_changed.connect(_on_search)
	hud.part_picked.connect(_on_part_picked)
	hud.quality_changed.connect(_on_quality_changed)

	await get_tree().process_frame
	await get_tree().process_frame

	_build_environment()
	_build_lights()

	model = MODEL_SCRIPT.new()
	model.name = "Anatomy"
	add_child(model)
	var startup_quality := _load_quality()
	if not model.load_anatomy(int(QUALITY[startup_quality]["detail"])):
		hud.set_loading("Could not load the anatomy data.\nCheck data/circulatory.glb")
		return

	path = PATH_SCRIPT.new()
	path.name = "BloodPath"
	add_child(path)
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
	hud.populate(model.parts_matching(""))
	hud.set_loading("")
	apply_quality(startup_quality, false)
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
	env.fog_enabled = true
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
func _on_mode_requested(m: String) -> void:
	match m:
		"free":
			_go_free(false)
		"tour":
			_go_path(false)
		"interior":
			_go_path(true)


func _go_free(first := false) -> void:
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
	_context_scale = 0.30
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
		var heart: Vector3 = model.group_centre("heart")
		cam.aim_from(heart + Vector3(27.0, 11.0, -39.0), heart)
		_look_point = heart
		_cam_up = Vector3.UP
	else:
		cam.sync_angles()
	_intro_done = true
	if not cam.captured and not first and not hud.mouse_over_ui():
		cam.capture_mouse(true)


func _go_path(interior: bool) -> void:
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
	_context_scale = 0.14          # inside the body the ghost is only a hint
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
	# depth fog is what makes the lumen read as a tunnel rather than a flat
	# red wall, so it stays on inside the vessels even on the low preset
	env.fog_enabled = interior or bool(preset["fog"])
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
func _load_quality() -> String:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS) == OK:
		var q := String(cf.get_value("graphics", "quality", "performance"))
		if QUALITY.has(q):
			return q
	return "performance"


func _save_quality(q: String) -> void:
	var cf := ConfigFile.new()
	cf.load(SETTINGS)
	cf.set_value("graphics", "quality", q)
	cf.save(SETTINGS)


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
		vp.scaling_3d_scale = float(preset["scale"])
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
		var ghost: bool = bool(preset["ghost"])
		model.set_context_visible(ghost)
		hud.context_check.set_pressed_no_signal(ghost)
		_context_was_on = ghost
		if ghost:
			_apply_context_opacity()
		_update_subtitle()
	hud.set_quality(q)
	if reload_meshes:
		_save_quality(q)


func _update_subtitle() -> void:
	if model == null:
		return
	var ghost: bool = model.is_context_visible()
	var label := String(QUALITY_NAMES[model.detail])
	if model.detail != _quality_detail():
		label += " (interior)"
	hud.set_subtitle("BodyParts3D  ·  %d parts  ·  %s triangles  ·  %s detail"
			% [model.parts.size(), _thousands(model.total_tris(ghost)), label])


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
	var d := _quality_detail()
	if mode == "interior":
		d = maxi(d, 1)
	return d


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
		"context":
			model.set_bucket_opacity("context", value * _context_scale)
			if value > 0.0 and not model.is_context_visible():
				model.set_context_visible(true)
				hud.context_check.set_pressed_no_signal(true)


func _on_context_toggled(on: bool) -> void:
	model.set_context_visible(on)
	_context_was_on = on
	_update_subtitle()
	if on:
		_apply_context_opacity()


func _apply_context_opacity() -> void:
	var v := maxf(0.05, float(hud.sliders["context"].value))
	model.set_bucket_opacity("context", v * _context_scale)


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
	if model == null or cam == null:
		return

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
			if mode == "free" and not hud.mouse_over_ui():
				cam.capture_mouse(true)


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


# -------------------------------------------------------------------- keyboard
func _unhandled_input(event: InputEvent) -> void:
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
				elif cam.captured:
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
				hud.toggle_panels()
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
			if not cam.captured and not hud.mouse_over_ui():
				cam.capture_mouse(true)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT and mode == "free":
			if not hover.is_empty():
				_on_part_picked(String(hover["id"]))
