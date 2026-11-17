extends SceneTree

const TrackGraph = preload("res://scripts/railway/track_graph.gd")

func _initialize() -> void:
	call_deferred("_run_tests")

func _run_tests() -> void:
	_test_edge_connectivity()
	_test_shared_node_branches()
	_test_removal_keeps_adjacency_consistent()
	_test_rejects_invalid_edges()
	print("TRACK_GRAPH_TESTS: PASS")
	quit(0)

func _test_edge_connectivity() -> void:
	var graph = TrackGraph.new()
	var a: int = graph.add_node(Vector2(0, 0), 0)
	var b: int = graph.add_node(Vector2(100, 0), 1)
	var edge: int = graph.add_edge(a, b, "single", PackedVector2Array([Vector2(0, 0), Vector2(100, 0)]))
	assert(edge > 0, "Expected valid edge")
	assert(graph.get_incident_edges(a).size() == 1, "Start node should reference edge")
	assert(graph.get_incident_edges(b).size() == 1, "End node should reference edge")
	assert(graph.get_other_endpoint(edge, a) == b, "Endpoint lookup should be symmetric")
	assert(graph.validate().is_empty(), "Valid graph should have no diagnostics")

func _test_shared_node_branches() -> void:
	var graph = TrackGraph.new()
	var shared: int = graph.add_node(Vector2.ZERO, 0)
	var lane_a: int = graph.add_node(Vector2(100, -24), 1, 7, 0)
	var lane_b: int = graph.add_node(Vector2(100, 24), 1, 7, 1)
	var points_a := PackedVector2Array([Vector2.ZERO, Vector2(100, -24)])
	var points_b := PackedVector2Array([Vector2.ZERO, Vector2(100, 24)])
	var edge_a: int = graph.add_edge(shared, lane_a, "parallel", points_a, 7, 0)
	var edge_b: int = graph.add_edge(shared, lane_b, "parallel", points_b, 7, 1)
	assert(edge_a > 0 and edge_b > 0, "Both lane branches should be retained")
	assert(graph.get_incident_edges(shared).size() == 2, "Shared node must retain both lane connections")
	assert(graph.validate().is_empty(), "Branched graph should validate")

func _test_removal_keeps_adjacency_consistent() -> void:
	var graph = TrackGraph.new()
	var a: int = graph.add_node(Vector2.ZERO)
	var b: int = graph.add_node(Vector2.RIGHT * 100.0)
	var c: int = graph.add_node(Vector2.UP * 100.0)
	var edge_ab: int = graph.add_edge(a, b, "single", PackedVector2Array([Vector2.ZERO, Vector2.RIGHT * 100.0]))
	graph.add_edge(a, c, "single", PackedVector2Array([Vector2.ZERO, Vector2.UP * 100.0]))
	assert(graph.remove_edge(edge_ab), "Existing edge should be removable")
	assert(graph.get_incident_edges(a).size() == 1, "Removing edge must update start adjacency")
	assert(graph.get_incident_edges(b).is_empty(), "Removing edge must update end adjacency")
	assert(graph.validate().is_empty(), "Graph should remain valid after edge removal")
	assert(graph.remove_node(c), "Existing node should be removable")
	assert(graph.validate().is_empty(), "Graph should remain valid after node removal")

func _test_rejects_invalid_edges() -> void:
	var graph = TrackGraph.new()
	var a: int = graph.add_node(Vector2.ZERO)
	assert(graph.add_edge(a, 999, "single", PackedVector2Array([Vector2.ZERO, Vector2.ONE])) == -1, "Missing endpoint must be rejected")
	assert(graph.add_edge(a, a, "single", PackedVector2Array([Vector2.ZERO, Vector2.ONE])) == -1, "Self-loop must be rejected")
	assert(graph.add_edge(a, graph.add_node(Vector2.ONE), "single", PackedVector2Array()) == -1, "Empty geometry must be rejected")
	assert(graph.validate().is_empty(), "Rejected edges must not corrupt the graph")
