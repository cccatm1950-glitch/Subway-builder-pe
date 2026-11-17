extends RefCounted
class_name TrackGraph

# Canonical railway topology. Geometry and rendering consume this graph;
# neither is allowed to invent connectivity independently.

var _nodes: Dictionary = {}
var _edges: Dictionary = {}
var _next_node_id: int = 1
var _next_edge_id: int = 1

func add_node(position: Vector2, station_id: int = -1, lane_group_id: int = -1, lane_index: int = -1) -> int:
	var node_id := _next_node_id
	_next_node_id += 1
	_nodes[node_id] = {
		"id": node_id,
		"position": position,
		"station_id": station_id,
		"lane_group_id": lane_group_id,
		"lane_index": lane_index,
		"edge_ids": []
	}
	return node_id

func add_edge(start_node_id: int, end_node_id: int, kind: String, points: PackedVector2Array, lane_group_id: int = -1, lane_index: int = 0) -> int:
	if start_node_id == end_node_id or not _nodes.has(start_node_id) or not _nodes.has(end_node_id):
		return -1
	if points.size() < 2:
		return -1
	var edge_id := _next_edge_id
	_next_edge_id += 1
	_edges[edge_id] = {
		"id": edge_id,
		"start_node_id": start_node_id,
		"end_node_id": end_node_id,
		"kind": kind,
		"renderable": kind != "station_transfer",
		"points": points,
		"lane_group_id": lane_group_id,
		"lane_index": lane_index
	}
	_nodes[start_node_id]["edge_ids"].append(edge_id)
	_nodes[end_node_id]["edge_ids"].append(edge_id)
	return edge_id

func remove_edge(edge_id: int) -> bool:
	if not _edges.has(edge_id):
		return false
	var edge: Dictionary = _edges[edge_id]
	for node_id in [int(edge["start_node_id"]), int(edge["end_node_id"])]:
		var node: Dictionary = _nodes[node_id]
		var incident: Array = node["edge_ids"]
		incident.erase(edge_id)
	_edges.erase(edge_id)
	return true

func remove_node(node_id: int) -> bool:
	if not _nodes.has(node_id):
		return false
	var incident: Array = _nodes[node_id]["edge_ids"].duplicate()
	for edge_id in incident:
		remove_edge(int(edge_id))
	_nodes.erase(node_id)
	return true

func update_node_position(node_id: int, position: Vector2) -> bool:
	if not _nodes.has(node_id):
		return false
	_nodes[node_id]["position"] = position
	return true

func update_edge_points(edge_id: int, points: PackedVector2Array) -> bool:
	if not _edges.has(edge_id) or points.size() < 2:
		return false
	_edges[edge_id]["points"] = points
	return true

func has_node(node_id: int) -> bool:
	return _nodes.has(node_id)

func has_edge(edge_id: int) -> bool:
	return _edges.has(edge_id)

func get_node(node_id: int) -> Dictionary:
	return _nodes.get(node_id, {}).duplicate(true)

func get_edge(edge_id: int) -> Dictionary:
	return _edges.get(edge_id, {}).duplicate(true)

func get_node_ids() -> Array:
	return _nodes.keys()

func get_edge_ids() -> Array:
	return _edges.keys()

func get_incident_edges(node_id: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not _nodes.has(node_id):
		return result
	for edge_id in _nodes[node_id]["edge_ids"]:
		result.append(get_edge(int(edge_id)))
	return result

func get_other_endpoint(edge_id: int, node_id: int) -> int:
	if not _edges.has(edge_id):
		return -1
	var edge: Dictionary = _edges[edge_id]
	if int(edge["start_node_id"]) == node_id:
		return int(edge["end_node_id"])
	if int(edge["end_node_id"]) == node_id:
		return int(edge["start_node_id"])
	return -1

func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	for edge_id in _edges:
		var edge: Dictionary = _edges[edge_id]
		var start_id := int(edge["start_node_id"])
		var end_id := int(edge["end_node_id"])
		if not _nodes.has(start_id) or not _nodes.has(end_id):
			errors.append("Edge %d references a missing endpoint" % int(edge_id))
			continue
		if not _nodes[start_id]["edge_ids"].has(edge_id):
			errors.append("Edge %d missing from start-node adjacency" % int(edge_id))
		if not _nodes[end_id]["edge_ids"].has(edge_id):
			errors.append("Edge %d missing from end-node adjacency" % int(edge_id))
		if PackedVector2Array(edge["points"]).size() < 2:
			errors.append("Edge %d has insufficient geometry points" % int(edge_id))
	for node_id in _nodes:
		for edge_id in _nodes[node_id]["edge_ids"]:
			if not _edges.has(edge_id):
				errors.append("Node %d references missing edge %d" % [int(node_id), int(edge_id)])
	return errors

func clear() -> void:
	_nodes.clear()
	_edges.clear()
	_next_node_id = 1
	_next_edge_id = 1
