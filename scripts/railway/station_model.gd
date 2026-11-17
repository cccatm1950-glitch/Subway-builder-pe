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
