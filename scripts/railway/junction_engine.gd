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
