extends SceneTree

const StationModelScript = preload("res://scripts/railway/station_model.gd")

func _initialize() -> void:
	call_deferred("_run_tests")

func _run_tests() -> void:
	_test_default_platform_footprint()
	_test_rotated_platform_footprint()
	_test_dimensions_are_clamped()
	_test_invalid_records_are_safe()
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
