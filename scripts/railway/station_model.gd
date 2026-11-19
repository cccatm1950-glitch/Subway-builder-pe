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


# Return a lane endpoint beyond the platform's longitudinal end. The lateral
# offset places parallel tracks beside the platform instead of drawing a
# connector across its footprint.
static func get_approach_point(record: Dictionary, outward_direction: Vector2, lateral_offset: float = 0.0, clearance: float = 0.0) -> Vector2:
	if record.is_empty() or not record.has("center") or outward_direction.length_squared() <= 0.0001:
		return Vector2(record.get("center", Vector2.ZERO))
	var axis := outward_direction.normalized()
	var normal := Vector2(-axis.y, axis.x)
	var rotation := float(record.get("rotation", 0.0))
	var platform_axis := Vector2.RIGHT.rotated(rotation)
	var half_length := maxf(float(record.get("platform_length", DEFAULT_PLATFORM_LENGTH)), MIN_PLATFORM_DIMENSION) * 0.5
	var axis_alignment := absf(axis.dot(platform_axis))
	# The approach exits through the end face only when aligned with the
	# platform's long axis. For branch directions, use the support distance
	# of the oriented rectangle along that direction.
	var half_width := maxf(float(record.get("platform_width", DEFAULT_PLATFORM_WIDTH)), MIN_PLATFORM_DIMENSION) * 0.5
	var platform_support := half_length * axis_alignment + half_width * sqrt(maxf(0.0, 1.0 - axis_alignment * axis_alignment))
	return Vector2(record.get("center", Vector2.ZERO)) + axis * (platform_support + maxf(clearance, 0.0)) + normal * lateral_offset

# The corridor is an independently authored polygon. It may include track
# approaches, switches and other station-area geometry beyond the platform.
# An empty polygon means corridor dimensions have not yet been established;
# callers must not silently substitute the platform footprint.
static func get_corridor_footprint(record: Dictionary) -> PackedVector2Array:
	if record.is_empty():
		return PackedVector2Array()
	var corridor: PackedVector2Array = record.get("corridor_footprint", PackedVector2Array())
	if corridor.size() < 3:
		return PackedVector2Array()
	return corridor.duplicate()

static func set_corridor_footprint(record: Dictionary, footprint: PackedVector2Array) -> Dictionary:
	var updated := record.duplicate(true)
	updated["corridor_footprint"] = footprint.duplicate() if footprint.size() >= 3 else PackedVector2Array()
	updated.erase("corridor_contours")
	return updated


# Multiple disconnected corridor components are stored independently. The
# legacy single-polygon field remains readable for existing station records.
static func get_corridor_contours(record: Dictionary) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	if record.is_empty():
		return result
	var stored: Array = record.get("corridor_contours", [])
	if not stored.is_empty():
		for contour in stored:
			var polygon := PackedVector2Array(contour)
			if polygon.size() >= 3:
				result.append(polygon.duplicate())
		return result
	var legacy := get_corridor_footprint(record)
	if legacy.size() >= 3:
		result.append(legacy)
	return result


static func set_corridor_contours(record: Dictionary, contours: Array[PackedVector2Array]) -> Dictionary:
	var updated := record.duplicate(true)
	var valid_contours: Array[PackedVector2Array] = []
	for contour in contours:
		if contour.size() >= 3:
			valid_contours.append(contour.duplicate())
	updated["corridor_contours"] = valid_contours
	updated["corridor_footprint"] = PackedVector2Array()
	return updated


# Corridor queries operate only on the independently authored corridor polygon.
# They intentionally return INF/false when no corridor has been defined.
static func corridor_contains_point(record: Dictionary, point: Vector2) -> bool:
	var corridor := get_corridor_footprint(record)
	return corridor.size() >= 3 and Geometry2D.is_point_in_polygon(point, corridor)

static func distance_to_corridor(record: Dictionary, point: Vector2) -> float:
	return _distance_to_polygon(get_corridor_footprint(record), point)

static func minimum_path_corridor_clearance(record: Dictionary, path: PackedVector2Array, sample_spacing: float = 4.0) -> float:
	var corridor := get_corridor_footprint(record)
	if corridor.size() < 3 or path.is_empty():
		return INF
	if path.size() == 1:
		return _distance_to_polygon(corridor, path[0])
	var spacing := maxf(sample_spacing, 0.5)
	var minimum_distance := INF
	for index in range(1, path.size()):
		var start := path[index - 1]
		var finish := path[index]
		var segment_length := start.distance_to(finish)
		var sample_count := maxi(1, int(ceil(segment_length / spacing)))
		for sample_index in range(sample_count + 1):
			var point := start.lerp(finish, float(sample_index) / float(sample_count))
			minimum_distance = minf(minimum_distance, _distance_to_polygon(corridor, point))
			if is_zero_approx(minimum_distance):
				return 0.0
	return minimum_distance

static func path_has_corridor_clearance(record: Dictionary, path: PackedVector2Array, clearance: float, sample_spacing: float = 4.0) -> bool:
	if clearance < 0.0:
		return false
	return minimum_path_corridor_clearance(record, path, sample_spacing) >= clearance

static func _distance_to_polygon(polygon: PackedVector2Array, point: Vector2) -> float:
	if polygon.size() < 3:
		return INF
	if Geometry2D.is_point_in_polygon(point, polygon):
		return 0.0
	var closest_distance := INF
	for index in range(polygon.size()):
		var next_index := (index + 1) % polygon.size()
		var closest := Geometry2D.get_closest_point_to_segment(point, polygon[index], polygon[next_index])
		closest_distance = minf(closest_distance, point.distance_to(closest))
	return closest_distance

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
