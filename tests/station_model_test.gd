extends SceneTree

const StationModelScript = preload("res://scripts/railway/station_model.gd")

func _initialize() -> void:
	call_deferred("_run_tests")

func _run_tests() -> void:
	_test_default_platform_footprint()
	_test_side_and_island_platform_dimensions()
	_test_rotated_platform_footprint()
	_test_dimensions_are_clamped()
	_test_invalid_records_are_safe()
	_test_path_clearance()
	_test_platform_axis_alignment()
	_test_platform_edge_approach_points()
	_test_corridor_is_separate_from_platform()
	_test_corridor_queries_and_clearance()
	_test_irregular_corridor_and_angled_approach()
	_test_multiple_corridor_contours_and_legacy_compatibility()
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


func _test_corridor_is_separate_from_platform() -> void:
	var record = StationModelScript.create_record(11, Vector2.ZERO)
	assert(StationModelScript.get_corridor_footprint(record).is_empty(), "Unspecified corridor must remain undefined, not inherit platform bounds")
	var corridor := PackedVector2Array([Vector2(-180, -72), Vector2(180, -72), Vector2(180, 72), Vector2(-180, 72)])
	var updated: Dictionary = StationModelScript.set_corridor_footprint(record, corridor)
	var platform: PackedVector2Array = StationModelScript.get_footprint(updated)
	var stored_corridor: PackedVector2Array = StationModelScript.get_corridor_footprint(updated)
	assert(platform.size() == 4 and stored_corridor.size() == 4, "Platform and corridor should be independent polygons")
	assert(stored_corridor[0].distance_to(corridor[0]) < 0.001, "Corridor geometry should preserve authored coordinates")
	assert(stored_corridor[0].distance_to(platform[0]) > 1.0, "Corridor must not alias the smaller platform footprint")
	stored_corridor[0] = Vector2(999, 999)
	assert(StationModelScript.get_corridor_footprint(updated)[0].distance_to(corridor[0]) < 0.001, "Returned corridor geometry must not mutate stored station data")
	var cleared: Dictionary = StationModelScript.set_corridor_footprint(updated, PackedVector2Array())
	assert(StationModelScript.get_corridor_footprint(cleared).is_empty(), "Invalid corridor geometry should be cleared safely")

func _test_corridor_queries_and_clearance() -> void:
	var record = StationModelScript.create_record(12, Vector2.ZERO)
	var corridor := PackedVector2Array([Vector2(-180, -72), Vector2(180, -72), Vector2(180, 72), Vector2(-180, 72)])
	record = StationModelScript.set_corridor_footprint(record, corridor)
	assert(StationModelScript.corridor_contains_point(record, Vector2.ZERO), "Corridor should contain its interior")
	assert(not StationModelScript.corridor_contains_point(record, Vector2(200, 0)), "Corridor should reject exterior points")
	assert(is_zero_approx(StationModelScript.distance_to_corridor(record, Vector2.ZERO)), "Interior corridor distance should be zero")
	assert(is_equal_approx(StationModelScript.distance_to_corridor(record, Vector2(200, 0)), 20.0), "Corridor distance should use the nearest polygon edge")
	var through_corridor := PackedVector2Array([Vector2(-220, 0), Vector2(220, 0)])
	var outside_corridor := PackedVector2Array([Vector2(-220, 100), Vector2(220, 100)])
	assert(is_zero_approx(StationModelScript.minimum_path_corridor_clearance(record, through_corridor)), "A path crossing the corridor should report zero clearance")
	assert(is_equal_approx(StationModelScript.minimum_path_corridor_clearance(record, outside_corridor), 28.0), "Path clearance should be measured from the corridor boundary")
	assert(StationModelScript.path_has_corridor_clearance(record, outside_corridor, 24.0), "Path beyond requested corridor clearance should pass")
	assert(not StationModelScript.path_has_corridor_clearance(record, outside_corridor, 32.0), "Path inside requested corridor clearance should fail")
	assert(is_inf(StationModelScript.distance_to_corridor(StationModelScript.create_record(13, Vector2.ZERO), Vector2.ZERO)), "Undefined corridor should not fall back to platform bounds")
	assert(not StationModelScript.path_has_corridor_clearance(record, through_corridor, -1.0), "Negative corridor clearance must be rejected")


func _test_irregular_corridor_and_angled_approach() -> void:
	var record = StationModelScript.create_record(14, Vector2.ZERO)
	# A widened station body with a skewed approach edge; this is deliberately
	# not a platform-sized rectangle or a symmetric clearance box.
	var corridor := PackedVector2Array([
		Vector2(-180, -60),
		Vector2(80, -60),
		Vector2(180, 30),
		Vector2(150, 110),
		Vector2(-160, 110),
		Vector2(-200, 20)
	])
	record = StationModelScript.set_corridor_footprint(record, corridor)
	var stored := StationModelScript.get_corridor_footprint(record)
	assert(stored.size() == 6, "Irregular corridor polygon must retain all authored boundary vertices")
	assert(stored[2].distance_to(Vector2(180, 30)) < 0.001, "Angled approach boundary must retain its authored vertex")
	assert(StationModelScript.corridor_contains_point(record, Vector2.ZERO), "Station-area interior should be inside the irregular corridor")
	assert(not StationModelScript.corridor_contains_point(record, Vector2(220, 80)), "Point beyond the angled approach should remain outside the corridor")
	var approach_path := PackedVector2Array([Vector2(100, 0), Vector2(170, 45)])
	assert(is_zero_approx(StationModelScript.minimum_path_corridor_clearance(record, approach_path)), "Track approach running within the corridor must not be treated as outside clearance")
	var exterior_path := PackedVector2Array([Vector2(220, 150), Vector2(260, 180)])
	assert(StationModelScript.minimum_path_corridor_clearance(record, exterior_path) > 0.0, "Track geometry beyond the corridor boundary should report positive separation")

func _test_multiple_corridor_contours_and_legacy_compatibility() -> void:
	var record = StationModelScript.create_record(15, Vector2.ZERO)
	var first := PackedVector2Array([Vector2(-40, -20), Vector2(0, -20), Vector2(0, 20), Vector2(-40, 20)])
	var second := PackedVector2Array([Vector2(60, -20), Vector2(100, -20), Vector2(100, 20), Vector2(60, 20)])
	var contours: Array[PackedVector2Array] = [first, second]
	var updated := StationModelScript.set_corridor_contours(record, contours)
	var retrieved := StationModelScript.get_corridor_contours(updated)
	assert(retrieved.size() == 2, "Disconnected corridor components should both be retained")
	assert(Geometry2D.is_point_in_polygon(Vector2(-20, 0), retrieved[0]), "First corridor component should retain its geometry")
	assert(Geometry2D.is_point_in_polygon(Vector2(80, 0), retrieved[1]), "Second corridor component should retain its geometry")
	assert(not Geometry2D.is_point_in_polygon(Vector2(30, 0), retrieved[0]) and not Geometry2D.is_point_in_polygon(Vector2(30, 0), retrieved[1]), "Disconnected components must not be bridged")
	assert(StationModelScript.corridor_contains_point(updated, Vector2(-20, 0)), "Containment queries should recognize the first disconnected contour")
	assert(StationModelScript.corridor_contains_point(updated, Vector2(80, 0)), "Containment queries should recognize the second disconnected contour")
	assert(not StationModelScript.corridor_contains_point(updated, Vector2(30, 0)), "Containment queries must not bridge disconnected contours")
	assert(is_zero_approx(StationModelScript.distance_to_corridor(updated, Vector2(80, 0))), "Distance queries should return zero inside either contour")
	assert(is_equal_approx(StationModelScript.distance_to_corridor(updated, Vector2(30, 0)), 30.0), "Distance queries should measure to the nearest disconnected contour")
	var second_component_path := PackedVector2Array([Vector2(70, 0), Vector2(90, 0)])
	assert(is_zero_approx(StationModelScript.minimum_path_corridor_clearance(updated, second_component_path)), "Path clearance should detect paths inside the second contour")
	var gap_path := PackedVector2Array([Vector2(30, 0)])
	assert(is_equal_approx(StationModelScript.minimum_path_corridor_clearance(updated, gap_path), 30.0), "Path clearance should measure from the nearest contour without bridging the gap")
	assert(StationModelScript.path_has_corridor_clearance(updated, gap_path, 25.0), "Clearance outside the nearest disconnected contour should pass")
	assert(not StationModelScript.path_has_corridor_clearance(updated, gap_path, 35.0), "Clearance inside the nearest disconnected contour should fail")
	retrieved[0][0] = Vector2(999, 999)
	assert(StationModelScript.get_corridor_contours(updated)[0][0].distance_to(first[0]) < 0.001, "Returned contours must not mutate stored station data")
	var legacy := StationModelScript.set_corridor_footprint(record, first)
	assert(StationModelScript.get_corridor_contours(legacy).size() == 1, "Legacy single corridor polygons should remain readable")
	var cleared := StationModelScript.set_corridor_contours(legacy, [])
	assert(StationModelScript.get_corridor_contours(cleared).is_empty(), "Empty contour updates should clear both corridor representations")

func _test_side_and_island_platform_dimensions() -> void:
	assert(is_equal_approx(StationModelScript.get_platform_width_meters(StationModelScript.PLATFORM_TYPE_SIDE), 8.0), "Side platforms should retain the desktop 8 m reference width")
	assert(is_equal_approx(StationModelScript.get_platform_width_meters(StationModelScript.PLATFORM_TYPE_ISLAND), 10.0), "Island platforms should retain the desktop 10 m reference width")
	assert(is_zero_approx(StationModelScript.get_platform_width_world_units(StationModelScript.PLATFORM_TYPE_SIDE, 0.0)), "An uncalibrated world scale must not invent mobile dimensions")
	var side := StationModelScript.create_record(20, Vector2.ZERO, StationModelScript.DEFAULT_PLATFORM_LENGTH, StationModelScript.DEFAULT_PLATFORM_WIDTH, 0.0, StationModelScript.PLATFORM_TYPE_SIDE, 2.0)
	var island := StationModelScript.create_record(21, Vector2.ZERO, StationModelScript.DEFAULT_PLATFORM_LENGTH, StationModelScript.DEFAULT_PLATFORM_WIDTH, 0.0, StationModelScript.PLATFORM_TYPE_ISLAND, 2.0)
	assert(is_equal_approx(float(side["platform_width"]), 16.0), "Side platform width should use the shared explicit world scale")
	assert(is_equal_approx(float(island["platform_width"]), 20.0), "Island platform width should use the same explicit world scale")
	assert(is_equal_approx(float(side["platform_width_meters"]), 8.0) and is_equal_approx(float(island["platform_width_meters"]), 10.0), "Station records should retain their desktop reference dimensions")
	assert(String(side["platform_type"]) == StationModelScript.PLATFORM_TYPE_SIDE and String(island["platform_type"]) == StationModelScript.PLATFORM_TYPE_ISLAND, "Station records should retain their selected platform type")
	var legacy := StationModelScript.create_record(22, Vector2.ZERO)
	assert(is_equal_approx(float(legacy["platform_width"]), StationModelScript.DEFAULT_PLATFORM_WIDTH), "Uncalibrated legacy station widths must remain unchanged")
