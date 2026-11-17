extends SceneTree

const StationModelScript = preload("res://scripts/railway/station_model.gd")

func _initialize() -> void:
	call_deferred("_run_tests")

func _run_tests() -> void:
	_test_default_platform_footprint()
	_test_rotated_platform_footprint()
	_test_dimensions_are_clamped()
	_test_invalid_records_are_safe()
	_test_path_clearance()
	_test_platform_axis_alignment()
	_test_platform_edge_approach_points()
	print("STATION_MODEL_TESTS: PASS")
	quit(0)

func _test_default_platform_footprint() -> void:
	var record = StationModelScript.create_record(4, Vector2(100, 80))
	var footprint: PackedVector2Array = StationModelScript.get_footprint(record)
	assert(footprint.size() == 4, "Platform footprint should be a four-corner polygon")
	assert(is_equal_approx(footprint[0].x, 44.0) and is_equal_approx(footprint[0].y, 66.0), "Default footprint should be centered and dimensioned")
	assert(StationModelScript.contains_point(record, Vector2(100, 80)), "Platform center must be inside its footprint")
	assert(not StationModelScript.contains_point(record, Vector2(200, 80)), "Distant point must be outside platform footprint")

func _test_rotated_platform_footprint() -> void:
	var record = StationModelScript.create_record(1, Vector2.ZERO, 100.0, 20.0, PI * 0.5)
	var footprint: PackedVector2Array = StationModelScript.get_footprint(record)
	assert(is_equal_approx(footprint[0].x, 10.0) and is_equal_approx(footprint[0].y, -50.0), "Rotation should transform footprint corners")
	assert(StationModelScript.contains_point(record, Vector2(0, 40)), "Point along rotated platform should be inside")
	assert(not StationModelScript.contains_point(record, Vector2(40, 0)), "Point outside rotated width should be outside")

func _test_dimensions_are_clamped() -> void:
	var record = StationModelScript.create_record(2, Vector2.ZERO, 0.0, -10.0)
	assert(is_equal_approx(float(record["platform_length"]), 4.0), "Platform length must have a safe minimum")
	assert(is_equal_approx(float(record["platform_width"]), 4.0), "Platform width must have a safe minimum")
	assert(StationModelScript.get_footprint(record).size() == 4, "Clamped footprint should remain valid")

func _test_invalid_records_are_safe() -> void:
	assert(StationModelScript.get_footprint({}).is_empty(), "Missing record should have no footprint")
	assert(not StationModelScript.contains_point({}, Vector2.ZERO), "Missing record should not contain points")
	assert(is_inf(StationModelScript.distance_to_centerline({}, Vector2.ZERO)), "Missing record should return infinite distance")

func _test_path_clearance() -> void:
	var record = StationModelScript.create_record(7, Vector2.ZERO)
	var through_platform := PackedVector2Array([Vector2(-100, 0), Vector2(100, 0)])
	var alongside_platform := PackedVector2Array([Vector2(-100, 30), Vector2(100, 30)])
	assert(is_zero_approx(StationModelScript.minimum_path_clearance(record, through_platform)), "A path crossing the platform footprint must report zero clearance")
	assert(is_equal_approx(StationModelScript.minimum_path_clearance(record, alongside_platform), 16.0), "Clearance should be measured from the platform edge")
	assert(StationModelScript.path_has_clearance(record, alongside_platform, 12.0), "A path outside the requested clearance should pass")
	assert(not StationModelScript.path_has_clearance(record, alongside_platform, 18.0), "A path inside the requested clearance should fail")
	assert(not StationModelScript.path_has_clearance(record, through_platform, 1.0), "A path through the platform must fail any positive clearance")

func _test_platform_axis_alignment() -> void:
	var opposite_directions: Array[Vector2] = [Vector2.RIGHT, Vector2.LEFT]
	assert(absf(StationModelScript.resolve_rotation(opposite_directions)) < 0.0001, "Opposing approaches should resolve to the same platform axis")
	var angled_directions: Array[Vector2] = [Vector2(1, 1).normalized(), Vector2(-1, -1).normalized()]
	assert(is_equal_approx(StationModelScript.resolve_rotation(angled_directions), PI * 0.25), "Angled opposing approaches should preserve their shared axis")
	var ambiguous_branch: Array[Vector2] = [Vector2.RIGHT, Vector2.UP]
	assert(is_equal_approx(StationModelScript.resolve_rotation(ambiguous_branch, 0.37), 0.37), "Perpendicular branch approaches should preserve the existing platform orientation")
	var no_approaches: Array[Vector2] = []
	assert(is_equal_approx(StationModelScript.resolve_rotation(no_approaches, 0.62), 0.62), "An unconnected station should preserve its fallback orientation")


func _test_platform_edge_approach_points() -> void:
	var record = StationModelScript.create_record(9, Vector2.ZERO)
	var upper_lane := StationModelScript.get_approach_point(record, Vector2.RIGHT, 24.0, 8.0)
	var lower_lane := StationModelScript.get_approach_point(record, Vector2.RIGHT, -24.0, 8.0)
	assert(is_equal_approx(upper_lane.x, 64.0) and is_equal_approx(upper_lane.y, 24.0), "Approach should clear the platform end and preserve its lane offset")
	assert(is_equal_approx(lower_lane.x, 64.0) and is_equal_approx(lower_lane.y, -24.0), "Opposite lane should preserve the mirrored offset")
	assert(not StationModelScript.contains_point(record, upper_lane), "Parallel approach endpoint must not lie inside the platform")
	var reverse_lane := StationModelScript.get_approach_point(record, Vector2.LEFT, 24.0, 8.0)
	assert(is_equal_approx(reverse_lane.x, -64.0) and is_equal_approx(reverse_lane.y, -24.0), "Reverse approach should mirror the lateral lane side")
	var rotated = StationModelScript.create_record(10, Vector2(20, 30), 100.0, 20.0, PI * 0.5)
	var rotated_approach := StationModelScript.get_approach_point(rotated, Vector2.DOWN, 16.0, 6.0)
	assert(is_equal_approx(rotated_approach.x, 4.0) and is_equal_approx(rotated_approach.y, 86.0), "Rotated platform approach should follow its oriented footprint")
