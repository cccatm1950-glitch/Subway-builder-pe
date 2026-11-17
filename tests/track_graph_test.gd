extends SceneTree

const TrackGraphScript = preload("res://scripts/railway/track_graph.gd")
const JunctionEngineScript = preload("res://scripts/railway/junction_engine.gd")

func _initialize() -> void:
	call_deferred("_run_tests")

func _run_tests() -> void:
	_test_edge_connectivity()
	_test_shared_node_branches()
	_test_removal_keeps_adjacency_consistent()
	_test_rejects_invalid_edges()
	_test_geometry_updates()
	_test_parallel_to_single_merge_topology()
	_test_branch_turnout_preserves_other_lane()
	_test_branch_lane_selection_both_sides_and_directions()
	print("TRACK_GRAPH_TESTS: PASS")
	quit(0)

func _test_edge_connectivity() -> void:
	var graph = TrackGraphScript.new()
	var a: int = graph.add_node(Vector2(0, 0), 0)
	var b: int = graph.add_node(Vector2(100, 0), 1)
	var edge: int = graph.add_edge(a, b, "single", PackedVector2Array([Vector2(0, 0), Vector2(100, 0)]))
	assert(edge > 0, "Expected valid edge")
	assert(graph.get_incident_edges(a).size() == 1, "Start node should reference edge")
	assert(graph.get_incident_edges(b).size() == 1, "End node should reference edge")
	assert(graph.get_other_endpoint(edge, a) == b, "Endpoint lookup should be symmetric")
	assert(graph.validate().is_empty(), "Valid graph should have no diagnostics")

func _test_shared_node_branches() -> void:
	var graph = TrackGraphScript.new()
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
	var graph = TrackGraphScript.new()
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
	var graph = TrackGraphScript.new()
	var a: int = graph.add_node(Vector2.ZERO)
	assert(graph.add_edge(a, 999, "single", PackedVector2Array([Vector2.ZERO, Vector2.ONE])) == -1, "Missing endpoint must be rejected")
	assert(graph.add_edge(a, a, "single", PackedVector2Array([Vector2.ZERO, Vector2.ONE])) == -1, "Self-loop must be rejected")
	assert(graph.add_edge(a, graph.add_node(Vector2.ONE), "single", PackedVector2Array()) == -1, "Empty geometry must be rejected")
	assert(graph.validate().is_empty(), "Rejected edges must not corrupt the graph")

func _test_parallel_to_single_merge_topology() -> void:
	var graph = TrackGraphScript.new()
	var through_lane: int = graph.add_node(Vector2(0, -24), 0, 12, 0)
	var merging_lane: int = graph.add_node(Vector2(0, 24), 0, 12, 1)
	var merge_point: int = graph.add_node(Vector2(120, 0), 1)
	var single_end: int = graph.add_node(Vector2(260, 0), 2)
	var through_path := PackedVector2Array([Vector2(0, -24), Vector2(60, -12), Vector2(120, 0)])
	var merging_path := PackedVector2Array([Vector2(0, 24), Vector2(60, 12), Vector2(120, 0)])
	var through_transition: int = graph.add_edge(through_lane, merge_point, "transition", through_path)
	var merge_transition: int = graph.add_edge(merging_lane, merge_point, "transition", merging_path)
	var outgoing: int = graph.add_edge(merge_point, single_end, "single", PackedVector2Array([Vector2(120, 0), Vector2(260, 0)]))
	assert(through_transition > 0 and merge_transition > 0 and outgoing > 0, "Both merge approaches and the outgoing single track should be connected")
	assert(graph.get_incident_edges(merge_point).size() == 3, "Merge node must connect both parallel lanes to the outgoing single track")
	assert(graph.get_other_endpoint(through_transition, merge_point) == through_lane, "Through-lane transition should retain its lane endpoint")
	assert(graph.get_other_endpoint(merge_transition, merge_point) == merging_lane, "Converging-lane transition should retain its lane endpoint")
	assert(graph.validate().is_empty(), "Parallel-to-single merge topology should validate")

func _test_geometry_updates() -> void:
	var graph = TrackGraphScript.new()
	var a: int = graph.add_node(Vector2.ZERO)
	var b: int = graph.add_node(Vector2.RIGHT * 100.0)
	var edge: int = graph.add_edge(a, b, "curve", PackedVector2Array([Vector2.ZERO, Vector2.RIGHT * 100.0]))
	var revised := PackedVector2Array([Vector2.ZERO, Vector2(50, 30), Vector2.RIGHT * 100.0])
	assert(graph.update_edge_points(edge, revised), "Existing edge geometry should update")
	assert(graph.get_edge(edge)["points"].size() == 3, "Updated edge should retain its complete path")
	assert(not graph.update_edge_points(999, revised), "Missing edge geometry update should fail")
	assert(not graph.update_edge_points(edge, PackedVector2Array()), "Invalid geometry update should fail")
	assert(graph.validate().is_empty(), "Geometry update should preserve graph validity")

func _test_branch_turnout_preserves_other_lane() -> void:
	var graph = TrackGraphScript.new()
	var selected_lane: int = graph.add_node(Vector2.ZERO, 0, 21, 0)
	var untouched_lane: int = graph.add_node(Vector2(0, 48), 0, 21, 1)
	var selected_continuation: int = graph.add_node(Vector2(160, 0), 1, 21, 0)
	var untouched_continuation: int = graph.add_node(Vector2(160, 48), 1, 21, 1)
	var turnout_merge: int = graph.add_node(Vector2(120, -72), 2)
	var branch_end: int = graph.add_node(Vector2(240, -160), 3)
	var lane_a: int = graph.add_edge(selected_lane, selected_continuation, "parallel", PackedVector2Array([Vector2.ZERO, Vector2(160, 0)]), 21, 0)
	var lane_b: int = graph.add_edge(untouched_lane, untouched_continuation, "parallel", PackedVector2Array([Vector2(0, 48), Vector2(160, 48)]), 21, 1)
	var turnout: int = graph.add_edge(selected_lane, turnout_merge, "transition", PackedVector2Array([Vector2.ZERO, Vector2(60, -36), Vector2(120, -72)]))
	var branch: int = graph.add_edge(turnout_merge, branch_end, "single", PackedVector2Array([Vector2(120, -72), Vector2(240, -160)]))
	assert(lane_a > 0 and lane_b > 0 and turnout > 0 and branch > 0, "Branch turnout and both original parallel lanes should exist")
	assert(graph.get_incident_edges(selected_lane).size() == 2, "Selected lane should connect to its continuation and turnout")
	assert(graph.get_incident_edges(untouched_lane).size() == 1, "Unselected parallel lane must remain independent")
	assert(graph.get_incident_edges(turnout_merge).size() == 2, "Turnout must share its merge node with the outgoing branch")
	assert(graph.get_other_endpoint(turnout, turnout_merge) == selected_lane, "Turnout must originate at the selected parallel lane")
	assert(graph.validate().is_empty(), "Branch turnout topology should validate")

func _test_branch_lane_selection_both_sides_and_directions() -> void:
	var origin := Vector2.ZERO
	var east := Vector2.RIGHT
	var north_lane := Vector2(0, -24)
	var south_lane := Vector2(0, 24)
	var lanes: Array[Vector2] = [north_lane, south_lane]
	assert(JunctionEngineScript.select_branch_lane_index(lanes, origin, east, Vector2(1, -1)) == 0, "Northeast branch should select north lane")
	assert(JunctionEngineScript.select_branch_lane_index(lanes, origin, east, Vector2(1, 1)) == 1, "Southeast branch should select south lane")
	assert(JunctionEngineScript.select_branch_lane_index(lanes, origin, -east, Vector2(-1, -1)) == 0, "Reversed southwest branch should select the geometrically correct lane")
	assert(JunctionEngineScript.select_branch_lane_index(lanes, origin, -east, Vector2(-1, 1)) == 1, "Reversed northwest branch should select the geometrically correct lane")
	var reversed_order: Array[Vector2] = [south_lane, north_lane]
	assert(JunctionEngineScript.select_branch_lane_index(reversed_order, origin, east, Vector2(1, -1)) == 1, "Lane selection must not depend on array order")
	assert(JunctionEngineScript.select_branch_lane_index(lanes, origin, east, east) == -1, "A straight continuation must not be classified as a branch-side selection")
	assert(JunctionEngineScript.select_branch_lane_index(lanes, origin, Vector2.ZERO, Vector2.UP) == -1, "Degenerate directions must be rejected")
