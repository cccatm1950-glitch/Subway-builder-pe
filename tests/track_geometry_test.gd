extends SceneTree

const TrackGeometryScript = preload("res://scripts/railway/track_geometry.gd")
const TrackGraphScript = preload("res://scripts/railway/track_graph.gd")

func _initialize() -> void:
	call_deferred("_run_tests")

func _run_tests() -> void:
	_test_straight_parallel_spacing()
	_test_curve_endpoints_and_tangents()
	_test_polyline_length()
	_test_degenerate_inputs()
	_test_signed_offsets_on_bends()
	_test_track_envelope_covers_multi_path_geometry()
	_test_track_envelope_rejects_missing_width_and_paths()
	_test_track_envelope_merges_overlapping_shapes()
	_test_generated_branch_envelope_merges_as_one_corridor()
	_test_disconnected_envelopes_remain_separate()
	_test_station_corridor_builder_uses_canonical_graph()
	_test_desktop_corridor_clearance_rule()
	print("TRACK_GEOMETRY_TESTS: PASS")
	quit(0)

func _test_straight_parallel_spacing() -> void:
	var centerline := PackedVector2Array([Vector2(0, 0), Vector2(100, 0)])
	var pair: Array[PackedVector2Array] = TrackGeometryScript.make_parallel_pair(centerline, 48.0)
	assert(pair.size() == 2, "Parallel pair should contain two lanes")
	assert(is_equal_approx(pair[0][0].distance_to(pair[1][0]), 48.0), "Parallel start spacing must match requested spacing")
	assert(is_equal_approx(pair[0][1].distance_to(pair[1][1]), 48.0), "Parallel end spacing must match requested spacing")
	assert(pair[0][0].y > 0.0 and pair[1][0].y < 0.0, "Lane offsets should be on opposite sides")

func _test_curve_endpoints_and_tangents() -> void:
	var start := Vector2(0, 0)
	var control := Vector2(50, 60)
	var finish := Vector2(100, 0)
	var curve: PackedVector2Array = TrackGeometryScript.sample_quadratic(start, control, finish, 40)
	assert(curve.size() == 41, "Curve should include both endpoints")
	assert(curve[0].distance_to(start) < 0.001, "Curve start must be exact")
	assert(curve[curve.size() - 1].distance_to(finish) < 0.001, "Curve finish must be exact")
	assert(TrackGeometryScript.tangent_at_start(curve).y > 0.0, "Start tangent should follow curve")
	assert(TrackGeometryScript.tangent_at_end(curve).y < 0.0, "End tangent should follow curve")

func _test_polyline_length() -> void:
	var line := PackedVector2Array([Vector2(0, 0), Vector2(3, 0), Vector2(3, 4)])
	assert(is_equal_approx(TrackGeometryScript.polyline_length(line), 7.0), "Polyline length should sum segment lengths")

func _test_degenerate_inputs() -> void:
	assert(TrackGeometryScript.offset_polyline(PackedVector2Array(), 24.0).is_empty(), "Empty line should remain empty")
	assert(TrackGeometryScript.offset_polyline(PackedVector2Array([Vector2.ZERO]), 24.0).is_empty(), "Single point cannot form an offset line")
	var repeated := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2(100, 0)])
	var offset: PackedVector2Array = TrackGeometryScript.offset_polyline(repeated, 24.0)
	assert(offset.size() == repeated.size(), "Offset should preserve point count")
	for point in offset:
		assert(is_finite(point.x) and is_finite(point.y), "Degenerate segments must not produce invalid coordinates")

func _test_signed_offsets_on_bends() -> void:
	var centerline := PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(100, 100)])
	var positive: PackedVector2Array = TrackGeometryScript.offset_polyline(centerline, 24.0)
	var negative: PackedVector2Array = TrackGeometryScript.offset_polyline(centerline, -24.0)
	assert(positive.size() == centerline.size() and negative.size() == centerline.size(), "Bend offsets should preserve point count")
	for index in range(centerline.size()):
		assert(positive[index].distance_to(centerline[index]) > 0.0, "Positive offset should move every valid point")
		assert(negative[index].distance_to(centerline[index]) > 0.0, "Negative offset should move every valid point")
		assert(is_equal_approx(positive[index].distance_to(centerline[index]), negative[index].distance_to(centerline[index])), "Signed offsets should have symmetric miter lengths")
	assert(positive[1].distance_to(negative[1]) > 40.0, "Opposite bend offsets should remain separated")


func _test_track_envelope_covers_multi_path_geometry() -> void:
	var paths: Array[PackedVector2Array] = [
		PackedVector2Array([Vector2(0, 0), Vector2(100, 0)]),
		PackedVector2Array([Vector2(50, 0), Vector2(100, 60), Vector2(150, 80)])
	]
	var envelope: Array[PackedVector2Array] = TrackGeometryScript.build_track_envelope(paths, 12.0)
	assert(not envelope.is_empty(), "Track envelope should be created from valid paths")
	assert(_envelope_contains(envelope, Vector2(50, 10)), "Envelope should cover clearance beside the straight track")
	assert(_envelope_contains(envelope, Vector2(100, 60)), "Envelope should cover the angled branch centerline")
	assert(_envelope_contains(envelope, Vector2(150, 80)), "Envelope should cover the branch endpoint")
	assert(not _envelope_contains(envelope, Vector2(150, 110)), "Envelope should respect the configured local width")

func _test_track_envelope_rejects_missing_width_and_paths() -> void:
	var paths: Array[PackedVector2Array] = [PackedVector2Array([Vector2.ZERO, Vector2(20, 0)])]
	var no_paths: Array[PackedVector2Array] = []
	assert(TrackGeometryScript.build_track_envelope(no_paths, 12.0).is_empty(), "No paths should produce no envelope")
	assert(TrackGeometryScript.build_track_envelope(paths, 0.0).is_empty(), "Zero width should produce no envelope")
	assert(TrackGeometryScript.build_track_envelope([PackedVector2Array([Vector2.ZERO])], 12.0).is_empty(), "Single-point paths should be ignored")


func _test_station_path_collection_keeps_all_lane_types() -> void:
	var straight := PackedVector2Array([Vector2(0, 0), Vector2(100, 0)])
	var branch := PackedVector2Array([Vector2(0, 0), Vector2(40, 30), Vector2(80, 60)])
	var parallel := PackedVector2Array([Vector2(0, 24), Vector2(100, 24)])
	var transfer := PackedVector2Array([Vector2(0, 0), Vector2(0, 24)])
	var edges: Array[Dictionary] = [
		{"start_station": 3, "end_station": 8, "kind": "single", "geometry": straight},
		{"start_station": 3, "end_station": 9, "kind": "curve", "geometry": branch},
		{"start_station": 7, "end_station": 3, "kind": "parallel", "geometry": parallel},
		{"start_station": 3, "end_station": 3, "kind": "station_transfer", "geometry": transfer},
		{"start_station": 4, "end_station": 8, "kind": "single", "geometry": straight}
	]
	var paths: Array[PackedVector2Array] = TrackGeometryScript.collect_station_paths(edges, 3)
	assert(paths.size() == 4, "Station collection should include single, curve, parallel and transfer paths")
	assert(paths[0].size() == straight.size(), "Straight geometry should be preserved")
	assert(paths[1].size() == branch.size(), "Curved geometry should be preserved")
	assert(paths[2].size() == parallel.size(), "Parallel lane geometry should be preserved")
	assert(paths[3].size() == transfer.size(), "Station transition geometry should be preserved")
	assert(TrackGeometryScript.collect_station_paths(edges, 99).is_empty(), "Unrelated stations should have no paths")
	assert(TrackGeometryScript.collect_station_paths(edges, -1).is_empty(), "Invalid station index should have no paths")

func _envelope_contains(polygons: Array[PackedVector2Array], point: Vector2) -> bool:
	for polygon in polygons:
		if Geometry2D.is_point_in_polygon(point, polygon):
			return true
	return false


func _test_station_path_collection_reads_canonical_graph() -> void:
	var graph = TrackGraphScript.new()
	var station_center: int = graph.add_node(Vector2.ZERO, 3)
	var station_lane: int = graph.add_node(Vector2(0, 24), 3, 11, 0)
	var other_station: int = graph.add_node(Vector2(120, 0), 8)
	var unrelated: int = graph.add_node(Vector2(240, 0), 9)
	var single := PackedVector2Array([Vector2.ZERO, Vector2(60, 0), Vector2(120, 0)])
	var transfer := PackedVector2Array([Vector2.ZERO, Vector2(0, 24)])
	var curve := PackedVector2Array([Vector2(0, 24), Vector2(50, 55), Vector2(120, 0)])
	var unrelated_path := PackedVector2Array([Vector2(120, 0), Vector2(180, 0), Vector2(240, 0)])
	assert(graph.add_edge(station_center, other_station, "single", single) > 0, "Canonical single edge should register")
	assert(graph.add_edge(station_center, station_lane, "station_transfer", transfer) > 0, "Canonical station transfer should register")
	assert(graph.add_edge(station_lane, other_station, "curve", curve) > 0, "Canonical curve should register")
	assert(graph.add_edge(other_station, unrelated, "single", unrelated_path) > 0, "Unrelated edge should register")
	var paths: Array[PackedVector2Array] = TrackGeometryScript.collect_station_paths_from_graph(graph, 3)
	assert(paths.size() == 3, "Graph collector should include all edges touching station-owned nodes only")
	assert(paths[0] == single, "Graph collector should preserve canonical single geometry")
	assert(paths[1] == transfer, "Graph collector should preserve logical station-transfer geometry")
	assert(paths[2] == curve, "Graph collector should preserve canonical curved geometry")
	assert(TrackGeometryScript.collect_station_paths_from_graph(graph, 99).is_empty(), "Unknown station should have no graph paths")
	assert(TrackGeometryScript.collect_station_paths_from_graph(graph, -1).is_empty(), "Invalid station index should have no graph paths")


func _test_track_envelope_merges_overlapping_shapes() -> void:
	var first := PackedVector2Array([Vector2(0, 0), Vector2(20, 0), Vector2(20, 20), Vector2(0, 20)])
	var second := PackedVector2Array([Vector2(10, 0), Vector2(30, 0), Vector2(30, 20), Vector2(10, 20)])
	var merged: Array[PackedVector2Array] = TrackGeometryScript.merge_track_envelope([first, second])
	assert(merged.size() == 1, "Overlapping envelope shapes should become one outer contour")
	assert(_envelope_contains(merged, Vector2(5, 10)), "Merged contour should preserve first shape coverage")
	assert(_envelope_contains(merged, Vector2(25, 10)), "Merged contour should preserve second shape coverage")
	assert(_envelope_contains(merged, Vector2(15, 10)), "Merged contour should fill the overlap without a seam")
	assert(not _envelope_contains(merged, Vector2(35, 10)), "Merged contour should not expand beyond the source shapes")


func _test_generated_branch_envelope_merges_as_one_corridor() -> void:
	var paths: Array[PackedVector2Array] = [
		PackedVector2Array([Vector2(0, 0), Vector2(40, 0), Vector2(80, 0)]),
		PackedVector2Array([Vector2(40, 0), Vector2(65, 25), Vector2(90, 50)])
	]
	var pieces: Array[PackedVector2Array] = TrackGeometryScript.build_track_envelope(paths, 12.0)
	var merged: Array[PackedVector2Array] = TrackGeometryScript.merge_track_envelope(pieces)
	assert(merged.size() == 1, "Connected straight and angled branch envelopes should form one corridor contour")
	assert(_envelope_contains(merged, Vector2(20, 0)), "Merged branch corridor should retain the straight approach")
	assert(_envelope_contains(merged, Vector2(65, 25)), "Merged branch corridor should retain the branch")
	assert(_envelope_contains(merged, Vector2(90, 50)), "Merged branch corridor should retain the branch endpoint")
	assert(not _envelope_contains(merged, Vector2(110, 70)), "Merged branch corridor should remain within configured clearance")

func _test_disconnected_envelopes_remain_separate() -> void:
	var first_path := PackedVector2Array([Vector2(0, 0), Vector2(40, 0)])
	var second_path := PackedVector2Array([Vector2(120, 0), Vector2(160, 0)])
	var paths: Array[PackedVector2Array] = [first_path, second_path]
	var pieces: Array[PackedVector2Array] = TrackGeometryScript.build_track_envelope(paths, 10.0)
	var merged: Array[PackedVector2Array] = TrackGeometryScript.merge_track_envelope(pieces)
	assert(merged.size() == 2, "Disconnected track envelopes should remain separate contours")
	assert(_envelope_contains(merged, Vector2(20, 0)), "First disconnected envelope should remain covered")
	assert(_envelope_contains(merged, Vector2(140, 0)), "Second disconnected envelope should remain covered")
	assert(not _envelope_contains(merged, Vector2(80, 0)), "The gap between disconnected envelopes must not be filled")


func _test_station_corridor_builder_uses_canonical_graph() -> void:
	var graph = TrackGraphScript.new()
	var station_center: int = graph.add_node(Vector2.ZERO, 3)
	var station_lane: int = graph.add_node(Vector2(0, 24), 3, 11, 0)
	var destination_a: int = graph.add_node(Vector2(100, 0), 8)
	var destination_b: int = graph.add_node(Vector2(100, 80), 9)
	var unrelated_start: int = graph.add_node(Vector2(220, 0), 12)
	var unrelated_finish: int = graph.add_node(Vector2(320, 0), 13)
	var straight := PackedVector2Array([Vector2.ZERO, Vector2(50, 0), Vector2(100, 0)])
	var transfer := PackedVector2Array([Vector2.ZERO, Vector2(0, 24)])
	var branch := PackedVector2Array([Vector2(0, 24), Vector2(50, 52), Vector2(100, 80)])
	var unrelated := PackedVector2Array([Vector2(220, 0), Vector2(270, 0), Vector2(320, 0)])
	assert(graph.add_edge(station_center, destination_a, "single", straight) > 0, "Station approach should register")
	assert(graph.add_edge(station_center, station_lane, "station_transfer", transfer) > 0, "Station lane transfer should register")
	assert(graph.add_edge(station_lane, destination_b, "curve", branch) > 0, "Station branch should register")
	assert(graph.add_edge(unrelated_start, unrelated_finish, "single", unrelated) > 0, "Unrelated track should register")
	var corridor: Array[PackedVector2Array] = TrackGeometryScript.build_station_corridor_from_graph(graph, 3, 12.0)
	assert(corridor.size() == 1, "Connected canonical station approaches should build one corridor contour")
	assert(_envelope_contains(corridor, Vector2(50, 0)), "Station corridor should include the straight approach")
	assert(_envelope_contains(corridor, Vector2(50, 52)), "Station corridor should include the curved branch")
	assert(not _envelope_contains(corridor, Vector2(270, 20)), "Unrelated graph tracks must not enter the station corridor")
	assert(TrackGeometryScript.build_station_corridor_from_graph(graph, 3, 0.0).is_empty(), "Corridor builder must reject an unspecified width")

func _test_desktop_corridor_clearance_rule() -> void:
	# Match the desktop track-side bound: outermost track center offset,
	# half track width, half parallel-track spacing, then track clearance.
	var track_limited := TrackGeometryScript.calculate_station_corridor_half_width(3.0, 1.435, 4.27, 1.2, 2.0)
	assert(is_equal_approx(track_limited, 7.0525), "Track envelope should include half track width, half parallel spacing and track clearance")
	# A wide platform governs when its outer edge extends beyond the track envelope.
	var platform_limited := TrackGeometryScript.calculate_station_corridor_half_width(1.0, 1.435, 2.8, 0.5, 4.0)
	assert(is_equal_approx(platform_limited, 4.5), "Platform edge plus track clearance should govern when wider")
	assert(is_zero_approx(TrackGeometryScript.calculate_station_corridor_half_width(-1.0, 1.435, 2.8, 0.5, 2.0)), "Negative track offsets must be rejected")
	assert(is_zero_approx(TrackGeometryScript.calculate_station_corridor_half_width(1.0, 0.0, 2.8, 0.5, 2.0)), "Missing track width must be rejected")
	assert(is_zero_approx(TrackGeometryScript.calculate_station_corridor_half_width(1.0, 1.435, -0.1, 0.5, 2.0)), "Negative parallel spacing must be rejected")
	assert(is_zero_approx(TrackGeometryScript.calculate_station_corridor_half_width(1.0, 1.435, 2.8, -0.5, 2.0)), "Negative track clearance must be rejected")
