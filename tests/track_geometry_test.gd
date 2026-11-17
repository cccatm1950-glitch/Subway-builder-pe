extends SceneTree

const TrackGeometryScript = preload("res://scripts/railway/track_geometry.gd")

func _initialize() -> void:
	call_deferred("_run_tests")

func _run_tests() -> void:
	_test_straight_parallel_spacing()
	_test_curve_endpoints_and_tangents()
	_test_polyline_length()
	_test_degenerate_inputs()
	_test_signed_offsets_on_bends()
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
