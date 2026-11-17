extends RefCounted
class_name StationModel

# Station identity and platform footprint are data, not renderer-owned shapes.
const DEFAULT_PLATFORM_LENGTH := 112.0
const DEFAULT_PLATFORM_WIDTH := 28.0
const MIN_PLATFORM_DIMENSION := 4.0

static func create_record(station_id: int, center: Vector2, platform_length: float = DEFAULT_PLATFORM_LENGTH, platform_width: float = DEFAULT_PLATFORM_WIDTH, rotation: float = 0.0) -> Dictionary:
	return {
		"id": station_id,
		"center": center,
		"platform_length": maxf(platform_length, MIN_PLATFORM_DIMENSION),
		"platform_width": maxf(platform_width, MIN_PLATFORM_DIMENSION),
		"rotation": rotation
	}

static func get_footprint(record: Dictionary) -> PackedVector2Array:
	if record.is_empty() or not record.has("center"):
		return PackedVector2Array()
	var center: Vector2 = record.get("center", Vector2.ZERO)
	var half_length := maxf(float(record.get("platform_length", DEFAULT_PLATFORM_LENGTH)), MIN_PLATFORM_DIMENSION) * 0.5
	var half_width := maxf(float(record.get("platform_width", DEFAULT_PLATFORM_WIDTH)), MIN_PLATFORM_DIMENSION) * 0.5
	var angle := float(record.get("rotation", 0.0))
	var local_corners := [
		Vector2(-half_length, -half_width),
		Vector2(half_length, -half_width),
		Vector2(half_length, half_width),
		Vector2(-half_length, half_width)
	]
	var footprint := PackedVector2Array()
	for corner in local_corners:
		footprint.append(center + corner.rotated(angle))
	return footprint

static func contains_point(record: Dictionary, point: Vector2) -> bool:
	var footprint := get_footprint(record)
	return footprint.size() == 4 and Geometry2D.is_point_in_polygon(point, footprint)

static func distance_to_centerline(record: Dictionary, point: Vector2) -> float:
	if record.is_empty() or not record.has("center"):
		return INF
	var center: Vector2 = record.get("center", Vector2.ZERO)
	var angle := float(record.get("rotation", 0.0))
	var local_point := (point - center).rotated(-angle)
	return absf(local_point.y)

static func distance_to_footprint(record: Dictionary, point: Vector2) -> float:
	var footprint := get_footprint(record)
	if footprint.size() != 4:
		return INF
	if Geometry2D.is_point_in_polygon(point, footprint):
		return 0.0
	var closest_distance := INF
	for index in range(footprint.size()):
		var next_index := (index + 1) % footprint.size()
		var closest := Geometry2D.get_closest_point_to_segment(point, footprint[index], footprint[next_index])
		closest_distance = minf(closest_distance, point.distance_to(closest))
	return closest_distance

static func minimum_path_clearance(record: Dictionary, path: PackedVector2Array, sample_spacing: float = 4.0) -> float:
	if path.is_empty() or get_footprint(record).size() != 4:
		return INF
	if path.size() == 1:
		return distance_to_footprint(record, path[0])
	var spacing := maxf(sample_spacing, 0.5)
	var minimum_distance := INF
	for index in range(1, path.size()):
		var start := path[index - 1]
		var finish := path[index]
		var segment_length := start.distance_to(finish)
		var sample_count := maxi(1, int(ceil(segment_length / spacing)))
		for sample_index in range(sample_count + 1):
			var point := start.lerp(finish, float(sample_index) / float(sample_count))
			minimum_distance = minf(minimum_distance, distance_to_footprint(record, point))
			if is_zero_approx(minimum_distance):
				return 0.0
	return minimum_distance

static func path_has_clearance(record: Dictionary, path: PackedVector2Array, clearance: float, sample_spacing: float = 4.0) -> bool:
	if clearance < 0.0:
		return false
	return minimum_path_clearance(record, path, sample_spacing) >= clearance

# Treat opposite approach directions as the same platform axis. A branch with
# equally weighted perpendicular approaches is ambiguous and keeps its fallback.
static func resolve_rotation(directions: Array[Vector2], fallback_rotation: float = 0.0) -> float:
	var axis_x := 0.0
	var axis_y := 0.0
	var valid_count := 0
	for direction in directions:
		if direction.length_squared() <= 0.0001:
			continue
		var angle := direction.angle()
		axis_x += cos(angle * 2.0)
		axis_y += sin(angle * 2.0)
		valid_count += 1
	if valid_count == 0 or Vector2(axis_x, axis_y).length_squared() <= 0.0001:
		return fallback_rotation
	return atan2(axis_y, axis_x) * 0.5
