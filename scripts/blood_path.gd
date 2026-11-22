class_name BloodPath
extends Node3D
## The blood path: a Catmull-Rom spline built from medial lines of the real
## vessel meshes (see bp3d_export/build.py). Drives both the guided tour and
## the interior voyage, and carries the streaming blood-cell particles.

signal station_reached(index: int, station: Dictionary)
signal finished()

const SAMPLES_PER_SEGMENT := 10

var curve := Curve3D.new()
var length := 0.0
var stations: Array = []
var progress := 0.0            # metres along the curve
var playing := false
var speed := 22.0              # cm/s
var hold_time := 3.6           # seconds paused at each station
var loop := false

var _hold := 0.0
var _next_station := 0
var _flow: MultiMeshInstance3D
var _visible := 420
var _t: PackedFloat32Array = PackedFloat32Array()
var _off: PackedVector3Array = PackedVector3Array()
var _spd: PackedFloat32Array = PackedFloat32Array()
var _flow_speed := 140.0


func load_path(path := "res://data/tour.json") -> bool:
	if not FileAccess.file_exists(path):
		push_error("tour.json missing")
		return false
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (data is Dictionary):
		return false
	var pts: Array = []
	for p in data.get("points", []):
		pts.append(Vector3(p[0], p[1], p[2]))
	if pts.size() < 3:
		return false
	_build_curve(pts)
	stations = data.get("stations", [])
	_build_flow()
	return true


func _build_curve(pts: Array) -> void:
	var dense: Array = []
	var n := pts.size()
	for i in range(n - 1):
		var p0: Vector3 = pts[maxi(0, i - 1)]
		var p1: Vector3 = pts[i]
		var p2: Vector3 = pts[i + 1]
		var p3: Vector3 = pts[mini(n - 1, i + 2)]
		for s in range(SAMPLES_PER_SEGMENT):
			var t := float(s) / float(SAMPLES_PER_SEGMENT)
			dense.append(_catmull(p0, p1, p2, p3, t))
	dense.append(pts[n - 1])
	curve.clear_points()
	for p in dense:
		curve.add_point(p)
	curve.bake_interval = 0.25
	length = curve.get_baked_length()


func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t
			+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
			+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


func position_at(offset_cm: float) -> Vector3:
	if length <= 0.0:
		return Vector3.ZERO
	return curve.sample_baked(clampf(offset_cm, 0.0, length))


func tangent_at(offset_cm: float) -> Vector3:
	var a := position_at(offset_cm)
	var b := position_at(minf(offset_cm + 1.5, length))
	var d := b - a
	if d.length() < 0.0001:
		return Vector3.FORWARD
	return d.normalized()


func fraction() -> float:
	return clampf(progress / maxf(0.001, length), 0.0, 1.0)


func station_at(f: float) -> int:
	var best := -1
	for i in stations.size():
		if float(stations[i]["t"]) <= f + 0.0001:
			best = i
	return best


# ------------------------------------------------------------------ playback
func start(from_fraction := 0.0) -> void:
	progress = clampf(from_fraction, 0.0, 1.0) * length
	_next_station = 0
	while _next_station < stations.size() and float(stations[_next_station]["t"]) < from_fraction:
		_next_station += 1
	_hold = 0.0
	playing = true


func stop() -> void:
	playing = false


func advance(delta: float) -> void:
	if not playing:
		return
	if _hold > 0.0:
		_hold -= delta
		return
	progress += speed * delta
	# did we pass a station?
	while _next_station < stations.size() \
			and fraction() >= float(stations[_next_station]["t"]):
		var st: Dictionary = stations[_next_station]
		station_reached.emit(_next_station, st)
		_next_station += 1
		_hold = hold_time
	if progress >= length:
		if loop:
			progress = 0.0
			_next_station = 0
			finished.emit()
		else:
			progress = length
			playing = false
			finished.emit()


## Jump along the path. Announces the station you land on, so that stepping
## with the arrow keys (and any seek) keeps the caption panel in sync.
func seek_fraction(f: float) -> void:
	progress = clampf(f, 0.0, 1.0) * length
	var here := station_at(f)
	_next_station = here + 1
	_hold = 0.0
	if here >= 0:
		station_reached.emit(here, stations[here])


func next_station() -> void:
	if stations.is_empty():
		return
	var i := mini(stations.size() - 1, station_at(fraction()) + 1)
	seek_fraction(float(stations[i]["t"]))


func prev_station() -> void:
	if stations.is_empty():
		return
	var i := maxi(0, station_at(fraction()) - 1)
	seek_fraction(float(stations[i]["t"]))


func hold_remaining() -> float:
	return maxf(0.0, _hold)


# --------------------------------------------------------------- particles
func _build_flow() -> void:
	_flow = MultiMeshInstance3D.new()
	_flow.name = "BloodFlow"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var sphere := SphereMesh.new()
	sphere.radius = 0.11
	sphere.height = 0.22
	sphere.radial_segments = 8
	sphere.rings = 5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.16, 0.15)
	mat.roughness = 0.95
	mat.emission_enabled = true
	mat.emission = Color(0.55, 0.07, 0.06)
	mat.emission_energy_multiplier = 0.35
	sphere.material = mat
	mm.mesh = sphere
	mm.instance_count = 420
	mm.visible_instance_count = -1
	_flow.multimesh = mm
	_flow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flow.visible = false
	add_child(_flow)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in mm.instance_count:
		_t.append(rng.randf())
		var ang := rng.randf() * TAU
		var rad := sqrt(rng.randf()) * 0.45
		_off.append(Vector3(cos(ang) * rad, sin(ang) * rad, 0.0))
		_spd.append(rng.randf_range(0.8, 1.35))


## 0 = few cells (low-detail preset), 1 = normal, 2 = dense
func set_flow_density(level: int) -> void:
	if _flow == null:
		return
	var counts := [110, 240, 420]
	_visible = clampi(int(counts[clampi(level, 0, 2)]), 0, _flow.multimesh.instance_count)
	_flow.multimesh.visible_instance_count = _visible


func flow_visible(on: bool) -> void:
	if _flow:
		_flow.visible = on


func _process(delta: float) -> void:
	if _flow == null or not _flow.visible or length <= 0.0:
		return
	var mm := _flow.multimesh
	var cam := get_viewport().get_camera_3d()
	var cam_pos := cam.global_position if cam != null else Vector3(1e9, 1e9, 1e9)
	for i in _visible:
		var t: float = _t[i] + (_flow_speed * _spd[i] * delta) / length
		if t > 1.0:
			t -= 1.0
		_t[i] = t
		var offset := t * length
		var pos := position_at(offset)
		var tan := tangent_at(offset)
		var side := tan.cross(Vector3.UP)
		if side.length() < 0.001:
			side = Vector3.RIGHT
		side = side.normalized()
		var up := side.cross(tan).normalized()
		pos += side * _off[i].x + up * _off[i].y
		# keep the apparent size roughly constant: a cell 1 cm from the lens must
		# not fill the screen, a cell 20 cm away still has to be visible
		var d := cam_pos.distance_to(pos)
		var k := clampf(0.24 * d, 0.12, 1.0)
		var b := Basis.looking_at(tan, up).scaled(Vector3(k, k, k * 2.2))
		mm.set_instance_transform(i, Transform3D(b, pos))
