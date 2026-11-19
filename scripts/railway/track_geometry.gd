extends RefCounted
class_name TrackGeometry

# Pure geometry helpers. These functions never create graph connectivity;
# callers must explicitly register the resulting paths in TrackGraph.

const EPSILON := 0.0001
const DEFAULT_MITER_LIMIT := 3.0

static func polyline_length(points: PackedVector2Array) -> float:
	var total := 0.0
	for index in range(1, points.size()):
		total += points[index - 1].distance_to(points[index])
	return total

static func tangent_at_start(points: PackedVector2Array) -> Vector2:
	for index in range(1, points.size()):
		var delta := points[index] - points[0]
		if delta.length_squared() > EPSILON:
			return delta.normalized()
	return Vector2.ZERO

static func tangent_at_end(points: PackedVector2Array) -> Vector2:
	for index in range(points.size() - 2, -1, -1):
		var delta := points[points.size() - 1] - points[index]
		if delta.length_squared() > EPSILON:
			return delta.normalized()
	return Vector2.ZERO

static func sample_quadratic(start: Vector2, control: Vector2, finish: Vector2, sample_count: int = 32) -> PackedVector2Array:
	var result := PackedVector2Array()
	var count := maxi(sample_count, 2)
	for index in range(count + 1):
		var t := float(index) / float(count)
		var one_minus_t := 1.0 - t
		var point := one_minus_t * one_minus_t * start + 2.0 * one_minus_t * t * control + t * t * finish
		result.append(point)
	return result

static func offset_polyline(points: PackedVector2Array, offset: float, miter_limit: float = DEFAULT_MITER_LIMIT) -> PackedVector2Array:
	var result := PackedVector2Array()
	if points.size() < 2:
		return result
	var limit := maxf(absf(miter_limit), 1.0)
	var segment_normals := PackedVector2Array()
	for index in range(points.size() - 1):
		var direction := points[index + 1] - points[index]
		if direction.length_squared() <= EPSILON:
			segment_normals.append(Vector2.ZERO)
		else:
			direction = direction.normalized()
			segment_normals.append(Vector2(-direction.y, direction.x))
	for index in range(points.size()):
		var normal := Vector2.ZERO
		if index == 0:
			normal = segment_normals[0]
		elif index == points.size() - 1:
			normal = segment_normals[segment_normals.size() - 1]
		else:
			var previous_normal := segment_normals[index - 1]
			var next_normal := segment_normals[index]
			if previous_normal.length_squared() <= EPSILON:
				normal = next_normal
			elif next_normal.length_squared() <= EPSILON:
				normal = previous_normal
			else:
				var summed := previous_normal + next_normal
				if summed.length_squared() <= EPSILON:
					normal = next_normal
				else:
					var miter := summed.normalized()
					var denominator := miter.dot(next_normal)
					if absf(denominator) <= EPSILON:
						normal = next_normal
					else:
						var miter_length := offset / denominator
						var max_length := absf(offset) * limit
						if absf(miter_length) > max_length:
							normal = next_normal * signf(miter_length) * limit
							result.append(points[index] + normal * offset)
							continue
						result.append(points[index] + miter * miter_length)
						continue
		result.append(points[index] + normal * offset)
	return result

static func make_parallel_pair(centerline: PackedVector2Array, spacing: float, miter_limit: float = DEFAULT_MITER_LIMIT) -> Array[PackedVector2Array]:
	var pair: Array[PackedVector2Array] = []
	if centerline.size() < 2:
		pair.append(PackedVector2Array())
		pair.append(PackedVector2Array())
		return pair
	var half_spacing := absf(spacing) * 0.5
	pair.append(offset_polyline(centerline, half_spacing, miter_limit))
	pair.append(offset_polyline(centerline, -half_spacing, miter_limit))
	return pair

static func endpoints_match(a: PackedVector2Array, b: PackedVector2Array, tolerance: float = 0.01) -> bool:
	if a.size() < 2 or b.size() < 2:
		return false
	return a[0].distance_to(b[0]) <= tolerance and a[a.size() - 1].distance_to(b[b.size() - 1]) <= tolerance


# Build a local envelope as overlapping strip and cap polygons around a
# collection of track paths. half_width is an explicit world-space clearance;
# this helper does not infer station dimensions or decide track membership.
# Overlapping polygons are intentionally kept separate to avoid lossy hulls.
static func build_track_envelope(paths: Array[PackedVector2Array], half_width: float, circle_segments: int = 12) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	var radius := maxf(half_width, 0.0)
	if radius <= EPSILON:
		return result
	var segments := maxi(circle_segments, 8)
	for path in paths:
		if path.size() < 2:
			continue
		for point_index in range(path.size()):
			result.append(_make_envelope_disk(path[point_index], radius, segments))
			if point_index == 0:
				continue
			var start := path[point_index - 1]
			var finish := path[point_index]
			var direction := finish - start
			if direction.length_squared() <= EPSILON:
				continue
			var normal := Vector2(-direction.y, direction.x).normalized() * radius
			result.append(PackedVector2Array([start + normal, finish + normal, finish - normal, start - normal]))
	return result

static func _make_envelope_disk(center: Vector2, radius: float, segments: int) -> PackedVector2Array:
	var polygon := PackedVector2Array()
	for index in range(segments):
		var angle := TAU * float(index) / float(segments)
		polygon.append(center + Vector2(cos(angle), sin(angle)) * radius)
	return polygon


# Select the actual sampled paths attached to a station. Callers provide
# geometry resolved from the canonical edge records; lane type does not affect
# membership, so single, parallel, curve and transition paths are all retained.
static func collect_station_paths(edges: Array[Dictionary], station_index: int) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	if station_index < 0:
		return result
	for edge in edges:
		var starts_here := int(edge.get("start_station", -1)) == station_index
		var ends_here := int(edge.get("end_station", -1)) == station_index
		if not starts_here and not ends_here:
			continue
		var points: PackedVector2Array = edge.get("geometry", PackedVector2Array())
		if points.size() >= 2:
			result.append(points.duplicate())
	return result


# Read station ownership from canonical graph endpoints and preserve each
# incident edge's sampled geometry, including logical transfer paths.
static func collect_station_paths_from_graph(graph, station_index: int) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	if station_index < 0 or graph == null:
		return result
	var edge_records: Array[Dictionary] = []
	for graph_edge_id in graph.get_edge_ids():
		var graph_edge: Dictionary = graph.get_edge(int(graph_edge_id))
		var start_node: Dictionary = graph.get_node(int(graph_edge.get("start_node_id", -1)))
		var end_node: Dictionary = graph.get_node(int(graph_edge.get("end_node_id", -1)))
		edge_records.append({
			"start_station": int(start_node.get("station_id", -1)),
			"end_station": int(end_node.get("station_id", -1)),
			"kind": String(graph_edge.get("kind", "single")),
			"geometry": PackedVector2Array(graph_edge.get("points", PackedVector2Array()))
		})
	return collect_station_paths(edge_records, station_index)


# Union overlapping envelope pieces into clean outer contours. Disconnected
# components remain separate polygons; hole contours retain their winding.
static func merge_track_envelope(envelope: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var merged: Array[PackedVector2Array] = []
	for source_polygon in envelope:
		if source_polygon.size() < 3:
			continue
		var candidate := source_polygon.duplicate()
		var absorbed_shape := true
		while absorbed_shape:
			absorbed_shape = false
			for index in range(merged.size()):
				var union_result := Geometry2D.merge_polygons(merged[index], candidate)
				# A single contour means these shapes formed one connected outer
				# boundary. Keep disconnected or hole-producing results separate.
				if union_result.size() == 1 and union_result[0].size() >= 3:
					candidate = union_result[0]
					merged.remove_at(index)
					absorbed_shape = true
					break
		merged.append(candidate)
	return merged
