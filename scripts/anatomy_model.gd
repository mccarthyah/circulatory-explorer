class_name AnatomyModel
extends Node3D
## Loads the BodyParts3D glTF exports (one mesh per anatomical part), keeps the
## catalogue of metadata next to them and exposes per-group materials, opacity
## control, the fly-through cutaway and ray picking.

signal hovered(part: Dictionary)
signal selected(part: Dictionary)

const DATA_DIR := "res://data/"
const SHADER_OPAQUE := preload("res://shaders/vessel_opaque.gdshader")
const SHADER_ALPHA := preload("res://shaders/vessel_alpha.gdshader")

# group key -> screen-space opacity bucket used by the UI
const BUCKET := {
	"artery": "arteries",
	"vein": "veins",
	"heart_muscle": "heart",
	"heart_valve": "heart",
	"heart_blood": "heart",
	"context": "context",
}

# material key -> colour, roughness, emission colour, emission strength
const SPEC := {
	"artery": [Color(0.82, 0.13, 0.14), 0.42, Color(0.34, 0.02, 0.02), 0.55],
	"vein": [Color(0.13, 0.28, 0.75), 0.42, Color(0.02, 0.05, 0.30), 0.55],
	"heart_muscle": [Color(0.62, 0.17, 0.23), 0.55, Color(0.24, 0.03, 0.05), 0.60],
	"heart_valve": [Color(0.90, 0.81, 0.62), 0.50, Color(0.10, 0.09, 0.06), 0.30],
	"heart_blood": [Color(0.58, 0.06, 0.10), 0.30, Color(0.30, 0.02, 0.04), 0.65],
}

var parts: Array = []                          # catalogue entries with .node filled in
var by_id: Dictionary = {}
var meta: Dictionary = {}
var context_root: Node3D
var circulatory_root: Node3D
var highlighted: Node3D = null
var bounds := AABB()

var _mats: Dictionary = {}                     # key -> [ShaderMaterial opaque, ShaderMaterial alpha]
var _by_material: Dictionary = {}              # key -> Array[Dictionary]
var _context_material: StandardMaterial3D
var _started_with_context := false
var _hl_material: StandardMaterial3D
var _face_cache: Dictionary = {}
var _face_cache_order: Array = []


func load_anatomy() -> bool:
	meta = _read_json(DATA_DIR + "parts.json")
	if meta.is_empty():
		push_error("parts.json missing")
		return false

	circulatory_root = _instance_gltf(DATA_DIR + "circulatory.glb")
	if circulatory_root == null:
		return false
	add_child(circulatory_root)

	context_root = _instance_gltf(DATA_DIR + "context.glb")
	if context_root != null:
		add_child(context_root)

	_build_materials()
	_hl_material = StandardMaterial3D.new()
	_hl_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hl_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hl_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_hl_material.albedo_color = Color(1.0, 0.84, 0.52, 0.26)
	_hl_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	# join the catalogue with the instantiated meshes
	var meshes := _collect_meshes(circulatory_root)
	if context_root:
		meshes.merge(_collect_meshes(context_root))

	var first := true
	for entry in meta.get("parts", []):
		var id: String = entry["id"]
		var key: String = entry["material"]
		var node: MeshInstance3D = meshes.get(id)
		entry["node"] = node
		var lo := Vector3(entry["min"][0], entry["min"][1], entry["min"][2])
		var hi := Vector3(entry["max"][0], entry["max"][1], entry["max"][2])
		entry["aabb"] = AABB(lo, hi - lo)
		if node != null:
			node.set_surface_override_material(0, _material_for(key, 1.0))
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		if not _by_material.has(key):
			_by_material[key] = []
		_by_material[key].append(entry)
		bounds = entry["aabb"] if first else bounds.merge(entry["aabb"])
		first = false
		parts.append(entry)
		by_id[id] = entry
	set_context_visible(false)
	return true


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("missing %s" % path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _instance_gltf(path: String) -> Node3D:
	if not FileAccess.file_exists(path):
		push_error("missing %s" % path)
		return null
	# Fast path: the editor already imported the .glb as a PackedScene.
	if ResourceLoader.exists(path):
		var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
		if res is PackedScene:
			var inst: Node = (res as PackedScene).instantiate()
			if inst != null:
				return inst
	# Runtime fallback — also works when the .glb ships as a raw file.
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		push_error("glTF parse failed for %s (error %d)" % [path, err])
		return null
	return doc.generate_scene(state)


func _collect_meshes(root: Node) -> Dictionary:
	var out := {}
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and n.mesh != null:
			out[String(n.name)] = n
		for c in n.get_children():
			stack.append(c)
	return out


# ------------------------------------------------------------------ materials
func _build_materials() -> void:
	for key in SPEC.keys():
		var spec: Array = SPEC[key]
		var opaque := _make_shader_material(SHADER_OPAQUE, spec, 1.0)
		var alpha := _make_shader_material(SHADER_ALPHA, spec, 1.0)
		_mats[key] = [opaque, alpha]

	_context_material = StandardMaterial3D.new()
	_context_material.albedo_color = Color(0.44, 0.58, 0.78, 0.16)
	_context_material.roughness = 0.9
	_context_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_context_material.cull_mode = BaseMaterial3D.CULL_BACK   # invisible from inside the body
	_context_material.rim_enabled = true
	_context_material.rim = 0.85
	_context_material.rim_tint = 0.35


func _make_shader_material(shader: Shader, spec: Array, alpha: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	var col: Color = spec[0]
	col.a = alpha
	m.set_shader_parameter("albedo", col)
	m.set_shader_parameter("roughness", spec[1])
	m.set_shader_parameter("emission_color", spec[2])
	m.set_shader_parameter("emission_strength", spec[3])
	m.set_shader_parameter("hole_center", Vector3.ZERO)
	m.set_shader_parameter("hole_radius", 0.0)
	return m


func _material_for(key: String, opacity: float) -> Material:
	if key == "context":
		_context_material.albedo_color.a = opacity * 0.30
		return _context_material
	var pair: Array = _mats.get(key, _mats["artery"])
	var mat: ShaderMaterial = pair[1] if opacity < 0.999 else pair[0]
	var col: Color = mat.get_shader_parameter("albedo")
	col.a = opacity
	mat.set_shader_parameter("albedo", col)
	return mat


func set_bucket_opacity(bucket: String, opacity: float) -> void:
	for key in _mats.keys():
		if BUCKET.get(key, "") != bucket:
			continue
		var mat := _material_for(key, opacity)
		for entry in _by_material.get(key, []):
			var node: MeshInstance3D = entry.get("node")
			if node != null:
				node.set_surface_override_material(0, mat)
	if bucket == "context" and context_root:
		_context_material.albedo_color.a = clampf(opacity, 0.0, 1.0) * 0.30


## The cutaway sphere: geometry closer to the camera than `radius` is discarded,
## so a flying camera always has room around it.
func set_hole(centre: Vector3, radius: float) -> void:
	for key in _mats.keys():
		for mat in _mats[key]:
			(mat as ShaderMaterial).set_shader_parameter("hole_center", centre)
			(mat as ShaderMaterial).set_shader_parameter("hole_radius", radius)


func set_heart_emission(energy: float) -> void:
	for key in ["heart_muscle", "heart_blood"]:
		for mat in _mats[key]:
			(mat as ShaderMaterial).set_shader_parameter("emission_strength", energy)


func set_context_visible(on: bool) -> void:
	if context_root:
		context_root.visible = on


func is_context_visible() -> bool:
	return context_root != null and context_root.visible


func is_circulatory(part: Dictionary) -> bool:
	return String(part.get("group", "")) != "context"


# --------------------------------------------------------------------- picking
func pick(origin: Vector3, dir: Vector3) -> Dictionary:
	var cands: Array = []
	for p in parts:
		if not is_circulatory(p):
			continue                                     # the ghost body never blocks picking
		var hit = (p["aabb"] as AABB).intersects_ray(origin, dir)
		if hit != null:
			cands.append({"p": p, "d": origin.distance_to(hit)})
	if cands.is_empty():
		return {}
	cands.sort_custom(func(a, b): return a["d"] < b["d"])
	for i in mini(cands.size(), 5):
		var p: Dictionary = cands[i]["p"]
		if _ray_hits_mesh(p, origin, dir):
			return p
	return cands[0]["p"]


func _ray_hits_mesh(part: Dictionary, origin: Vector3, dir: Vector3) -> bool:
	var id: String = part["id"]
	var faces: PackedVector3Array
	if _face_cache.has(id):
		faces = _face_cache[id]
	else:
		var node: MeshInstance3D = part.get("node")
		if node == null:
			return false
		faces = node.mesh.get_faces()
		_face_cache[id] = faces
		_face_cache_order.append(id)
		while _face_cache_order.size() > 48:
			_face_cache.erase(_face_cache_order.pop_front())
	var count := faces.size() / 3
	var stride := maxi(1, int(ceil(count / 9000.0)))
	var i := 0
	while i < count:
		if Geometry3D.ray_intersects_triangle(origin, dir,
				faces[i * 3], faces[i * 3 + 1], faces[i * 3 + 2]) != null:
			return true
		i += stride
	return false


func highlight(part: Dictionary) -> void:
	var node: Node3D = null
	if not part.is_empty():
		node = part.get("node")
	if node == highlighted:
		return
	if highlighted != null and highlighted is GeometryInstance3D:
		(highlighted as GeometryInstance3D).material_overlay = null
	highlighted = node
	if highlighted != null and highlighted is GeometryInstance3D:
		(highlighted as GeometryInstance3D).material_overlay = _hl_material


# ------------------------------------------------------------------ navigation
func viewpoint_for(part: Dictionary, from: Vector3) -> Dictionary:
	var box: AABB = part["aabb"]
	var centre := box.get_center()
	var radius := maxf(0.8, box.size.length() * 0.5)
	var dist := clampf(radius * 2.3, 2.2, 300.0)
	var dir := from - centre
	if dir.length() < 0.001:
		dir = Vector3(0, 0.2, -1)
	dir = dir.normalized()
	return {"position": centre + dir * dist, "target": centre, "distance": dist}


func group_centre(group: String) -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for p in parts:
		if String(p["group"]) == group:
			sum += (p["aabb"] as AABB).get_center()
			n += 1
	return sum / maxf(1.0, float(n))


func parts_matching(query: String) -> Array:
	var q := query.strip_edges().to_lower()
	var out: Array = []
	for p in parts:
		if not is_circulatory(p):
			continue
		if q.is_empty() or String(p["name"]).to_lower().contains(q) \
				or String(p["fma"]).to_lower().contains(q) \
				or String(p["group"]).to_lower().contains(q):
			out.append(p)
	out.sort_custom(func(a, b): return String(a["name"]).naturalnocasecmp_to(String(b["name"])) < 0)
	return out
