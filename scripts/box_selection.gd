extends RefCounted
## Finds actual projected triangle intersections, not catalogue AABBs alone.
## This is a through-selection: occluded geometry is deliberately included.

const EDGES := [[0, 1], [0, 2], [0, 4], [1, 3], [1, 5], [2, 3], [2, 6], [3, 7], [4, 5], [4, 6], [5, 7], [6, 7]]


func parts_in_rect(model, camera: Camera3D, rect: Rect2) -> Array:
	var ids: Array = []
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return ids
	for part in model.parts:
		if not model.is_circulatory(part) or bool(part.get("hidden", false)):
			continue
		if model.effective_part_opacity(part) <= 0.001:
			continue
		var node: MeshInstance3D = part.get("node")
		if node == null or node.mesh == null or not node.is_visible_in_tree():
			continue
		var to_camera: Transform3D = camera.global_transform.affine_inverse() * node.global_transform
		if not _bounds_intersect(node.mesh.get_aabb(), to_camera, camera, rect):
			continue
		var faces: PackedVector3Array = node.mesh.get_faces()
		for i in range(0, faces.size() - 2, 3):
			var poly: Array = [to_camera * faces[i], to_camera * faces[i + 1], to_camera * faces[i + 2]]
			poly = _clip_depth(poly, -camera.near, true)
			poly = _clip_depth(poly, -camera.far, false)
			if poly.size() < 3:
				continue
			var screen := PackedVector2Array()
			for point in poly:
				screen.append(camera.unproject_position(camera.to_global(point)))
			if _polygon_intersects_rect(screen, rect):
				ids.append(String(part["id"]))
				break
	return ids


# Retain z <= plane (near) or z >= plane (far), interpolating crossings.
func _clip_depth(poly: Array, plane: float, keep_less: bool) -> Array:
	var out: Array = []
	if poly.is_empty():
		return out
	var previous: Vector3 = poly.back()
	var prev_inside: bool = previous.z <= plane if keep_less else previous.z >= plane
	for item in poly:
		var current: Vector3 = item
		var inside: bool = current.z <= plane if keep_less else current.z >= plane
		if inside != prev_inside:
			out.append(previous.lerp(current, (plane - previous.z) / (current.z - previous.z)))
		if inside:
			out.append(current)
		previous = current
		prev_inside = inside
	return out


func _bounds_intersect(box: AABB, transform: Transform3D, camera: Camera3D, rect: Rect2) -> bool:
	var points: Array = []
	for i in 8:
		points.append(transform * (box.position + Vector3(box.size.x if (i & 1) != 0 else 0.0, box.size.y if (i & 2) != 0 else 0.0, box.size.z if (i & 4) != 0 else 0.0)))
	var clipped: Array = []
	for p in points:
		if p.z <= -camera.near and p.z >= -camera.far:
			clipped.append(p)
	for edge in EDGES:
		var a: Vector3 = points[edge[0]]
		var b: Vector3 = points[edge[1]]
		for plane in [-camera.near, -camera.far]:
			if (a.z < plane and b.z > plane) or (a.z > plane and b.z < plane):
				clipped.append(a.lerp(b, (plane - a.z) / (b.z - a.z)))
	if clipped.is_empty():
		return false
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for point in clipped:
		var screen := camera.unproject_position(camera.to_global(point))
		lo = lo.min(screen)
		hi = hi.max(screen)
	return Rect2(lo, hi - lo).intersects(rect, true)


func _polygon_intersects_rect(poly: PackedVector2Array, rect: Rect2) -> bool:
	for point in poly:
		if rect.has_point(point):
			return true
	var corners := PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	for corner in corners:
		if Geometry2D.is_point_in_polygon(corner, poly):
			return true
	for i in poly.size():
		for j in 4:
			if Geometry2D.segment_intersects_segment(poly[i], poly[(i + 1) % poly.size()], corners[j], corners[(j + 1) % 4]) != null:
				return true
	return false
