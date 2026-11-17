extends RefCounted
class_name JunctionEngine

# Pure junction decisions. Geometry construction remains in the caller;
# this module only resolves which existing lane a diverging route should use.

const EPSILON := 0.0001

static func select_branch_lane_index(lane_positions: Array[Vector2], origin: Vector2, parallel_direction: Vector2, branch_direction: Vector2, epsilon: float = EPSILON) -> int:
	if lane_positions.size() != 2:
		return -1
	if parallel_direction.length_squared() <= epsilon * epsilon or branch_direction.length_squared() <= epsilon * epsilon:
		return -1
	var direction := parallel_direction.normalized()
	var branch := branch_direction.normalized()
	var normal := Vector2(-direction.y, direction.x)
	var branch_side := branch.dot(normal)
	if absf(branch_side) <= epsilon:
		return -1
	var best_index := -1
	var best_score := -INF
	for index in range(lane_positions.size()):
		var lane_offset := (lane_positions[index] - origin).dot(normal)
		var score := signf(branch_side) * lane_offset
		if score > best_score:
			best_score = score
			best_index = index
	if best_score <= epsilon:
		return -1
	return best_index

static func build_turnout_path(start: Vector2, finish: Vector2, start_direction: Vector2, finish_direction: Vector2, handle_length: float, sample_count: int = 40) -> PackedVector2Array:
	var result := PackedVector2Array()
	if start.distance_squared_to(finish) <= EPSILON * EPSILON:
		return result
	if start_direction.length_squared() <= EPSILON * EPSILON or finish_direction.length_squared() <= EPSILON * EPSILON:
		return result
	var count := maxi(sample_count, 2)
	var handle := maxf(handle_length, 0.0)
	var first_control := start + start_direction.normalized() * handle
	var second_control := finish - finish_direction.normalized() * handle
	for step in range(count + 1):
		var t := float(step) / float(count)
		var u := 1.0 - t
		result.append(u * u * u * start + 3.0 * u * u * t * first_control + 3.0 * u * t * t * second_control + t * t * t * finish)
	return result
