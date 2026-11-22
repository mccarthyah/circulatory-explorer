class_name AnatomyModel
extends Node3D
## Loads the BodyParts3D glTF exports (one mesh per anatomical part), keeps the
## catalogue of metadata next to them and exposes per-group materials, opacity
## control, the fly-through cutaway and ray picking.
##
## Three detail levels share the same catalogue and node names, so the level can
## be swapped at runtime (see reload()).

signal hovered(part: Dictionary)
signal selected(part: Dictionary)

const DATA_DIR := "res://data/"
const SHADER_OPAQUE := preload("res://shaders/vessel_opaque.gdshader")
const SHADER_ALPHA := preload("res://shaders/vessel_alpha.gdshader")

## 2 = full detail, 1 = balanced, 0 = performance
const DETAIL_SUFFIX := {2: "", 1: "_lod1", 0: "_lod2"}

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
var detail := 2
var context_root: Node3D
var circulatory_root: Node3D
var supplemental_root: Node3D
var extended_root: Node3D
var _extended_on := false
var highlighted: Node3D = null
var bounds := AABB()

var _mats: Dictionary = {}                     # key -> [ShaderMaterial opaque, ShaderMaterial alpha]
var _by_material: Dictionary = {}              # key -> Array[Dictionary]
var _context_material: StandardMaterial3D
var _hl_material: StandardMaterial3D
var _face_cache: Dictionary = {}
var _face_cache_order: Array = []
var _hole_center := Vector3.ZERO
var _hole_radius := 0.0


func load_anatomy(detail_level: int = 2) -> bool:
	meta = _read_json(DATA_DIR + "parts.json")
	if meta.is_empty():
		push_error("parts.json missing")
		return false
	_ensure_materials()
	return _build(detail_level)


## Swap the level of detail without rebuilding anything else. Returns true when
## the meshes were replaced.
func reload(detail_level: int) -> bool:
	if detail_level == detail and circulatory_root != null:
		return true
	_teardown()
	return _build(detail_level)


func _teardown() -> void:
	highlighted = null
	_face_cache.clear()
	_face_cache_order.clear()
	parts.clear()
	by_id.clear()
	_by_material.clear()
	if circulatory_root != null:
		circulatory_root.visible = false
		circulatory_root.queue_free()
		circulatory_root = null
	if context_root != null:
		context_root.visible = false
		context_root.queue_free()
		context_root = null
	if supplemental_root != null:
		supplemental_root.visible = false
		supplemental_root.queue_free()
		supplemental_root = null
	if extended_root != null:
		extended_root.visible = false
		extended_root.queue_free()
		extended_root = null


func _build(detail_level: int) -> bool:
	detail = detail_level
	var suffix: String = DETAIL_SUFFIX.get(detail_level, "")
	context_root = _instance_gltf(DATA_DIR + "context%s.glb" % suffix)
	circulatory_root = _instance_gltf(DATA_DIR + "circulatory%s.glb" % suffix)
	supplemental_root = _instance_gltf(DATA_DIR + "additional_circulatory%s.glb" % suffix)
	if circulatory_root == null or supplemental_root == null:
		# These nodes have not yet been attached to the tree.
		for n in [context_root, circulatory_root, supplemental_root]:
			if n != null:
				n.free()
		context_root = null
		circulatory_root = null
		supplemental_root = null
		return false

	# join the catalogue with the instantiated meshes
	var meshes := _collect_meshes(circulatory_root)
	meshes.merge(_collect_meshes(supplemental_root))
	add_child(supplemental_root)
	if context_root != null:
		add_child(context_root)
		meshes.merge(_collect_meshes(context_root))
	add_child(circulatory_root)

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
			_prepare_part_node(entry, node)
		if not _by_material.has(key):
			_by_material[key] = []
		_by_material[key].append(entry)
		bounds = entry["aabb"] if first else bounds.merge(entry["aabb"])
		first = false
		parts.append(entry)
		by_id[id] = entry
	set_context_visible(_context_on)
	if _extended_on and not set_extended_visible(true):
		return false
	return true


func _prepare_part_node(entry: Dictionary, node: MeshInstance3D) -> void:
	var key: String = entry["material"]
	node.set_surface_override_material(0, _material_for(key, _opacity.get(key, 1.0)))
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED


## Load the optional 405-part is_a layer only when requested.
func set_extended_visible(on: bool) -> bool:
	if on and extended_root == null:
		var suffix: String = DETAIL_SUFFIX.get(detail, "")
		var loaded := _instance_gltf(DATA_DIR + "extended_circulatory%s.glb" % suffix)
		if loaded == null:
			_extended_on = false
			return false
		var meshes := _collect_meshes(loaded)
		for entry in parts:
			if not bool(entry.get("extended", false)):
				continue
			var node: MeshInstance3D = meshes.get(String(entry["id"]))
			if node == null:
				push_error("missing extended mesh %s" % entry["id"])
				loaded.free()
				_extended_on = false
				return false
		# Only publish references after every mesh has been validated.
		extended_root = loaded
		add_child(extended_root)
		for entry in parts:
			if bool(entry.get("extended", false)):
				var node: MeshInstance3D = meshes[String(entry["id"])]
				entry["node"] = node
				_prepare_part_node(entry, node)
	_extended_on = on
	if extended_root != null:
		extended_root.visible = on
	return true


func is_extended_visible() -> bool:
	return _extended_on and extended_root != null and extended_root.visible


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
var _opacity: Dictionary = {                      # material key -> 0..1
	"artery": 1.0, "vein": 1.0, "heart_muscle": 1.0,
	"heart_valve": 1.0, "heart_blood": 1.0, "context": 0.35,
}
var _context_on := false
var _mottle := 1.0


func _ensure_materials() -> void:
	if not _mats.is_empty():
		return
	for key in SPEC.keys():
		var spec: Array = SPEC[key]
		_mats[key] = [_make_shader_material(SHADER_OPAQUE, spec, 1.0),
				_make_shader_material(SHADER_ALPHA, spec, 1.0)]

	_context_material = StandardMaterial3D.new()
	_context_material.albedo_color = Color(0.44, 0.58, 0.78, 0.16)
	_context_material.roughness = 0.9
	_context_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_context_material.cull_mode = BaseMaterial3D.CULL_BACK   # invisible from inside the body
	_context_material.rim_enabled = true
	_context_material.rim = 0.85
	_context_material.rim_tint = 0.35
	_context_material.disable_receive_shadows = true

	_hl_material = StandardMaterial3D.new()
	_hl_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hl_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hl_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_hl_material.albedo_color = Color(1.0, 0.84, 0.52, 0.26)
	_hl_material.cull_mode = BaseMaterial3D.CULL_DISABLED


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
	m.set_shader_parameter("mottle", _mottle)
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
		_opacity[key] = opacity
		var mat := _material_for(key, opacity)
		for entry in _by_material.get(key, []):
			var node: MeshInstance3D = entry.get("node")
			if node != null:
				node.set_surface_override_material(0, mat)
	if bucket == "context":
		_opacity["context"] = clampf(opacity, 0.0, 1.0)
		_context_material.albedo_color.a = _opacity["context"] * 0.30


## The cutaway sphere: geometry closer to the camera than `radius` is discarded,
## so a flying camera always has room around it.
func set_hole(centre: Vector3, radius: float) -> void:
	if is_equal_approx(radius, _hole_radius) and (radius <= 0.0 or centre.is_equal_approx(_hole_center)):
		return
	_hole_center = centre
	_hole_radius = radius
	for key in _mats.keys():
		for mat in _mats[key]:
			(mat as ShaderMaterial).set_shader_parameter("hole_center", centre)
			(mat as ShaderMaterial).set_shader_parameter("hole_radius", radius)


func set_heart_emission(energy: float) -> void:
	for key in ["heart_muscle", "heart_blood"]:
		for mat in _mats[key]:
			(mat as ShaderMaterial).set_shader_parameter("emission_strength", energy)


## 0 disables the per-fragment mottling noise (cheapest, for low-end GPUs).
func set_mottle(amount: float) -> void:
	_mottle = clampf(amount, 0.0, 1.0)
	for key in _mats.keys():
		for mat in _mats[key]:
			(mat as ShaderMaterial).set_shader_parameter("mottle", _mottle)


func set_context_visible(on: bool) -> void:
	_context_on = on
	if context_root:
		context_root.visible = on


func is_context_visible() -> bool:
	return context_root != null and context_root.visible


func is_circulatory(part: Dictionary) -> bool:
	return String(part.get("group", "")) != "context"


## Triangle count of a part at the current detail level.
func tris_of(part: Dictionary) -> int:
	match detail:
		2:
			return int(part.get("tris", 0))
		1:
			return int(part.get("tris_lod1", part.get("tris", 0)))
		_:
			return int(part.get("tris_lod2", part.get("tris", 0)))


func total_tris(include_context := true) -> int:
	var total := 0
	for p in parts:
		if not include_context and p["group"] == "context":
			continue
		if bool(p.get("extended", false)) and not _extended_on:
			continue
		total += tris_of(p)
	return total


# --------------------------------------------------------------------- picking
func pick(origin: Vector3, dir: Vector3) -> Dictionary:
	# Catalogue bounds are in model space; triangle vertices are in mesh space.
	# A bounding-box intersection is only a broad phase, never a pick by itself.
	var local_origin := to_local(origin)
	var local_dir := global_transform.basis.inverse() * dir
	var cands: Array = []
	for p in parts:
		if not is_circulatory(p) or float(_opacity.get(p.get("material", ""), 1.0)) <= 0.001:
			continue
		var node: MeshInstance3D = p.get("node")
		if node == null or not node.is_visible_in_tree():
			continue
		var box: AABB = p["aabb"]
		var hit = box.intersects_ray(local_origin, local_dir)
		if hit != null:
			# An origin inside a box has a lower bound of zero, not the exit distance.
			var distance := 0.0 if box.has_point(local_origin) else origin.distance_to(to_global(hit))
			cands.append({"p": p, "d": distance})
	cands.sort_custom(func(a, b): return a["d"] < b["d"])
	var best := {}
	var best_distance := INF
	for cand in cands:
		if float(cand["d"]) > best_distance:
			break
		var distance := _ray_mesh_distance(cand["p"], origin, dir)
		if distance < best_distance:
			best_distance = distance
			best = cand["p"]
	return best


## Return the closest world-space hit distance, or INF for a miss.
func _ray_mesh_distance(part: Dictionary, origin: Vector3, dir: Vector3) -> float:
	var id: String = part["id"]
	var node: MeshInstance3D = part.get("node")
	if node == null or node.mesh == null:
		return INF
	var faces: PackedVector3Array
	if _face_cache.has(id):
		faces = _face_cache[id]
	else:
		faces = node.mesh.get_faces()
		_face_cache[id] = faces
		_face_cache_order.append(id)
		while _face_cache_order.size() > 24:
			_face_cache.erase(_face_cache_order.pop_front())
	var local_origin := node.to_local(origin)
	var local_dir := node.global_transform.basis.inverse() * dir
	var closest := INF
	for i in range(0, faces.size(), 3):
		var hit = Geometry3D.ray_intersects_triangle(local_origin, local_dir,
				faces[i], faces[i + 1], faces[i + 2])
		if hit != null:
			closest = minf(closest, origin.distance_to(node.to_global(hit)))
	return closest


func highlight(part: Dictionary) -> void:
	var node: Node3D = null
	if not part.is_empty():
		node = part.get("node")
	if node == highlighted:
		return
	if highlighted != null and is_instance_valid(highlighted) and highlighted is GeometryInstance3D:
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
