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


# Build a local envelope around a collection of connected or crossing track
# paths. The supplied half_width is explicit world-space clearance; this helper
# does not infer station dimensions or decide which tracks belong to a station.
# The result can contain multiple polygons when the source paths are disjoint.
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
			var disk := _make_envelope_disk(path[point_index], radius, segments)
			result = _merge_envelope_polygon(result, disk)
			if point_index == 0:
				continue
			var start := path[point_index - 1]
			var finish := path[point_index]
			var direction := finish - start
			if direction.length_squared() <= EPSILON:
				continue
			var normal := Vector2(-direction.y, direction.x).normalized() * radius
			var strip := PackedVector2Array([start + normal, finish + normal, finish - normal, start - normal])
			result = _merge_envelope_polygon(result, strip)
	return result

static func _make_envelope_disk(center: Vector2, radius: float, segments: int) -> PackedVector2Array:
	var polygon := PackedVector2Array()
	for index in range(segments):
		var angle := TAU * float(index) / float(segments)
		polygon.append(center + Vector2(cos(angle), sin(angle)) * radius)
	return polygon

static func _merge_envelope_polygon(current: Array[PackedVector2Array], addition: PackedVector2Array) -> Array[PackedVector2Array]:
	if current.is_empty():
		var initial: Array[PackedVector2Array] = []
		initial.append(addition)
		return initial
	var merged: Array[PackedVector2Array] = []
	var pending: Array[PackedVector2Array] = [addition]
	for existing in current:
		var next_pending: Array[PackedVector2Array] = []
		for candidate in pending:
			var union := Geometry2D.merge_polygons(existing, candidate)
			if union.is_empty():
				next_pending.append(candidate)
			else:
				# Preserve every returned component; subsequent pieces will be
				# merged against each component in turn.
				for component in union:
					merged.append(component)
		if next_pending.size() == pending.size():
			merged.append(existing)
		pending = next_pending
	for remaining in pending:
		merged.append(remaining)
	return merged

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
