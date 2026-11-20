extends SceneTree

const TrackGraphScript = preload("res://scripts/railway/track_graph.gd")

func _initialize() -> void:
	call_deferred("_run_tests")

func _run_tests() -> void:
	_test_free_nodes_connect_without_station_ids()
	_test_station_identity_is_optional_metadata()
	_test_node_can_join_multiple_track_segments()
	print("FREE_PLACEMENT_TRACK_NODE_TESTS: PASS")
	quit(0)

func _test_free_nodes_connect_without_station_ids() -> void:
	var graph = TrackGraphScript.new()
	var start_node := graph.add_node(Vector2(32, 64), -1, -1, 0)
	var end_node := graph.add_node(Vector2(256, 64), -1, -1, 0)
	var points := PackedVector2Array([Vector2(32, 64), Vector2(256, 64)])
	var edge := graph.add_edge(start_node, end_node, "single", points)
	assert(edge > 0, "Freely placed track nodes should connect without station IDs")
	assert(graph.get_node(start_node)["station_id"] == -1, "Free node must not acquire a station association")
	assert(graph.get_other_endpoint(edge, start_node) == end_node, "Track connectivity must resolve through endpoint nodes")
	assert(graph.validate().is_empty(), "Free node connection should preserve graph invariants")

func _test_station_identity_is_optional_metadata() -> void:
	var graph = TrackGraphScript.new()
	var free_node := graph.add_node(Vector2.ZERO)
	var associated_node := graph.add_node(Vector2(100, 0), 7)
	assert(graph.get_node(free_node)["station_id"] == -1, "Default node should be independent of stations")
	assert(graph.get_node(associated_node)["station_id"] == 7, "Optional station association should remain supported")

func _test_node_can_join_multiple_track_segments() -> void:
	var graph = TrackGraphScript.new()
	var junction := graph.add_node(Vector2.ZERO)
	var east := graph.add_node(Vector2(100, 0))
	var north := graph.add_node(Vector2(0, -100))
	var west := graph.add_node(Vector2(-100, 0))
	assert(graph.add_edge(junction, east, "single", PackedVector2Array([Vector2.ZERO, Vector2(100, 0)])) > 0, "First segment should attach to track node")
	assert(graph.add_edge(junction, north, "curve", PackedVector2Array([Vector2.ZERO, Vector2(0, -50), Vector2(0, -100)])) > 0, "Curve should attach to same track node")
	assert(graph.add_edge(junction, west, "single", PackedVector2Array([Vector2.ZERO, Vector2(-100, 0)])) > 0, "Third segment should form a junction through the shared node")
	assert(graph.get_incident_edges(junction).size() == 3, "Junction connectivity should be defined by track-node adjacency")
	assert(graph.validate().is_empty(), "Multi-edge track node should preserve graph invariants")
