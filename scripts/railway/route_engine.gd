extends RefCounted
class_name RouteEngine

# Route planning reads only the canonical TrackGraph. Edge weights use the
# stored sampled geometry so curved track distance is not reduced to a chord.

static func find_shortest_path(graph, start_node_id: int, end_node_id: int) -> Dictionary:
	if graph == null or not graph.has_node(start_node_id) or not graph.has_node(end_node_id):
		return {}
	if start_node_id == end_node_id:
		return {
			"node_ids": [start_node_id],
			"edge_ids": [],
			"total_length": 0.0
		}

	var distances: Dictionary = {start_node_id: 0.0}
	var previous_nodes: Dictionary = {}
	var previous_edges: Dictionary = {}
	var visited: Dictionary = {}

	while true:
		var current_id := -1
		var current_distance := INF
		for candidate in distances:
			if visited.has(candidate):
				continue
			var candidate_distance := float(distances[candidate])
			if candidate_distance < current_distance:
				current_distance = candidate_distance
				current_id = int(candidate)
		if current_id < 0:
			break
		if current_id == end_node_id:
			break
		visited[current_id] = true

		for edge in graph.get_incident_edges(current_id):
			var edge_id := int(edge.get("id", -1))
			var neighbor_id: int = int(graph.get_other_endpoint(edge_id, current_id))
			if neighbor_id < 0 or visited.has(neighbor_id):
				continue
			var points: PackedVector2Array = edge.get("points", PackedVector2Array())
			var edge_length := _polyline_length(points)
			if edge_length <= 0.0001:
				continue
			var candidate_total := current_distance + edge_length
			if candidate_total < float(distances.get(neighbor_id, INF)):
				distances[neighbor_id] = candidate_total
				previous_nodes[neighbor_id] = current_id
				previous_edges[neighbor_id] = edge_id

	if not distances.has(end_node_id):
		return {}

	var node_path: Array[int] = [end_node_id]
	var edge_path: Array[int] = []
	var cursor := end_node_id
	while cursor != start_node_id:
		if not previous_nodes.has(cursor) or not previous_edges.has(cursor):
			return {}
		edge_path.push_front(int(previous_edges[cursor]))
		cursor = int(previous_nodes[cursor])
		node_path.push_front(cursor)

	return {
		"node_ids": node_path,
		"edge_ids": edge_path,
		"total_length": float(distances[end_node_id])
	}

static func _polyline_length(points: PackedVector2Array) -> float:
	var total := 0.0
	for index in range(1, points.size()):
		total += points[index - 1].distance_to(points[index])
	return total
