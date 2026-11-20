extends RefCounted
class_name RailwayDimensions

# Desktop Subway Builder v1.6.0 reference dimensions, expressed in metres.
# These are reference values only. Existing mobile Vector2 geometry remains
# in its legacy coordinate system until a separately tested migration opts in.
const METRES_PER_WORLD_UNIT := 1.0

const TRACK_WIDTH_M := 1.435
const PLATFORM_TRAIN_GAP_M := 0.1

# Desktop parallelTrackSpacing is edge-to-edge. Centreline spacing therefore
# includes one full track width. Values are train-type-specific.
const HEAVY_METRO_PARALLEL_EDGE_SPACING_M := 3.81
const HEAVY_METRO_CENTERLINE_SPACING_M := HEAVY_METRO_PARALLEL_EDGE_SPACING_M + TRACK_WIDTH_M
const HEAVY_METRO_TRACK_CLEARANCE_M := 1.0
const HEAVY_METRO_TRAIN_WIDTH_M := 3.05

const LIGHT_METRO_PARALLEL_EDGE_SPACING_M := 3.81
const LIGHT_METRO_CENTERLINE_SPACING_M := LIGHT_METRO_PARALLEL_EDGE_SPACING_M + TRACK_WIDTH_M
const LIGHT_METRO_TRACK_CLEARANCE_M := 1.0
const LIGHT_METRO_TRAIN_WIDTH_M := 2.94

const COMMUTER_RAIL_PARALLEL_EDGE_SPACING_M := 4.27
const COMMUTER_RAIL_CENTERLINE_SPACING_M := COMMUTER_RAIL_PARALLEL_EDGE_SPACING_M + TRACK_WIDTH_M
const COMMUTER_RAIL_TRACK_CLEARANCE_M := 1.2
const COMMUTER_RAIL_TRAIN_WIDTH_M := 3.25

const TRAM_PARALLEL_EDGE_SPACING_M := 2.8
const TRAM_CENTERLINE_SPACING_M := TRAM_PARALLEL_EDGE_SPACING_M + TRACK_WIDTH_M
const TRAM_TRACK_CLEARANCE_M := 0.5
const TRAM_TRAIN_WIDTH_M := 2.65

const SIDE_PLATFORM_WIDTH_M := 8.0
const ISLAND_PLATFORM_WIDTH_M := 10.0
const EXPRESS_ISLAND_PLATFORM_WIDTH_M := 8.0

static func metres_to_world_units(metres: float) -> float:
	return metres / METRES_PER_WORLD_UNIT

static func world_units_to_metres(world_units: float) -> float:
	return world_units * METRES_PER_WORLD_UNIT

static func platform_half_width(platform_width_metres: float) -> float:
	return maxf(platform_width_metres, 0.0) * 0.5

static func train_half_width_with_platform_gap(train_width_metres: float = HEAVY_METRO_TRAIN_WIDTH_M) -> float:
	return maxf(train_width_metres, 0.0) * 0.5 + PLATFORM_TRAIN_GAP_M

# Desktop v1.6.0 platform-strip offsets, measured perpendicular to the
# station track centreline. Each result is an edge-to-edge strip in metres.
# This mirrors renderer getPlatformStrips(); it does not create a station
# corridor polygon or migrate legacy mobile world coordinates.
static func get_platform_strips(layout: String, train_width_metres: float, parallel_edge_spacing_metres: float, widths: Dictionary = {}) -> Array[Dictionary]:
	var side_width := maxf(float(widths.get("side", SIDE_PLATFORM_WIDTH_M)), 0.0)
	var island_width := maxf(float(widths.get("island", ISLAND_PLATFORM_WIDTH_M)), 0.0)
	var express_island_width := maxf(float(widths.get("expressIsland", EXPRESS_ISLAND_PLATFORM_WIDTH_M)), 0.0)
	var clearance := train_half_width_with_platform_gap(train_width_metres)
	var half_track := TRACK_WIDTH_M * 0.5
	var parallel_offset := half_track + parallel_edge_spacing_metres * 0.5
	var quad_offsets := get_quad_track_offsets(layout, train_width_metres, parallel_edge_spacing_metres, widths)
	var quad_outer := float(quad_offsets["outer"])
	var strips: Array[Dictionary] = []
	match layout:
		"side-left":
			strips.append({"edge1": -clearance - side_width, "edge2": -clearance})
		"side-right":
			strips.append({"edge1": clearance, "edge2": clearance + side_width})
		"side-both":
			strips.append({"edge1": -clearance - side_width, "edge2": -clearance})
			strips.append({"edge1": clearance, "edge2": clearance + side_width})
		"island":
			strips.append({"edge1": -island_width * 0.5, "edge2": island_width * 0.5})
		"side-platforms":
			var offset := parallel_offset + clearance
			strips.append({"edge1": -offset - side_width, "edge2": -offset})
			strips.append({"edge1": offset, "edge2": offset + side_width})
		"quad-local", "quad-classic":
			var offset := quad_outer + clearance
			strips.append({"edge1": -offset - side_width, "edge2": -offset})
			strips.append({"edge1": offset, "edge2": offset + side_width})
		"quad-local-outer":
			strips.append({"edge1": -express_island_width * 0.5, "edge2": express_island_width * 0.5})
		"quad-local-center":
			var platform_center := (float(quad_offsets["inner"]) + quad_outer) * 0.5
			strips.append({"edge1": -platform_center - express_island_width * 0.5, "edge2": -platform_center + express_island_width * 0.5})
			strips.append({"edge1": platform_center - express_island_width * 0.5, "edge2": platform_center + express_island_width * 0.5})
		"quad-express":
			var express_layout_outer := parallel_offset + TRACK_WIDTH_M + parallel_edge_spacing_metres
			var offset := express_layout_outer + clearance
			strips.append({"edge1": -offset - side_width, "edge2": -offset})
			strips.append({"edge1": -express_island_width * 0.5, "edge2": express_island_width * 0.5})
			strips.append({"edge1": offset, "edge2": offset + side_width})
		_:
			return strips
	return strips


static func get_parallel_track_offset(layout: String, train_width_metres: float, parallel_edge_spacing_metres: float, widths: Dictionary = {}) -> float:
	if layout == "side-platforms":
		var side_width := maxf(float(widths.get("side", SIDE_PLATFORM_WIDTH_M)), 0.0)
		return side_width * 0.5 + train_half_width_with_platform_gap(train_width_metres)
	return TRACK_WIDTH_M * 0.5 + parallel_edge_spacing_metres * 0.5


static func get_quad_track_offsets(layout: String, train_width_metres: float, parallel_edge_spacing_metres: float, widths: Dictionary = {}) -> Dictionary:
	var inner := TRACK_WIDTH_M * 0.5 + parallel_edge_spacing_metres * 0.5
	var express_width := maxf(float(widths.get("expressIsland", EXPRESS_ISLAND_PLATFORM_WIDTH_M)), 0.0)
	var clearance := train_half_width_with_platform_gap(train_width_metres)
	var outer := inner + TRACK_WIDTH_M + parallel_edge_spacing_metres
	match layout:
		"quad-express", "quad-local-outer":
			inner = express_width * 0.5 + clearance
			outer = inner + TRACK_WIDTH_M + parallel_edge_spacing_metres
		"quad-local-center":
			outer = inner + train_width_metres + 2.0 * PLATFORM_TRAIN_GAP_M + express_width
	return {"inner": inner, "outer": outer}


static func get_lane_counting_width(lanes_type: String, parallel_edge_spacing_metres: float, track_clearance_metres: float) -> float:
	var lane_count := 1
	match lanes_type:
		"parallel":
			lane_count = 2
		"quad":
			lane_count = 4
		"single":
			lane_count = 1
		_:
			return 0.0
	var width := 0.0
	for index in range(lane_count):
		width += TRACK_WIDTH_M
		if index == 0:
			width += track_clearance_metres
		width += parallel_edge_spacing_metres
		if index == lane_count - 1:
			width += track_clearance_metres
	return width


static func get_track_base_width(lanes_type: String, train_width_metres: float, parallel_edge_spacing_metres: float, track_clearance_metres: float, layout: String = "", widths: Dictionary = {}) -> float:
	var minimum_width := get_lane_counting_width(lanes_type, parallel_edge_spacing_metres, track_clearance_metres)
	if layout.is_empty():
		return minimum_width
	var track_half_extent := TRACK_WIDTH_M * 0.5
	if lanes_type == "parallel":
		track_half_extent = get_parallel_track_offset(layout, train_width_metres, parallel_edge_spacing_metres, widths) + TRACK_WIDTH_M * 0.5
	elif lanes_type == "quad":
		track_half_extent = float(get_quad_track_offsets(layout, train_width_metres, parallel_edge_spacing_metres, widths)["outer"]) + TRACK_WIDTH_M * 0.5
	var strips := get_platform_strips(layout, train_width_metres, parallel_edge_spacing_metres, widths)
	var platform_half_extent := platform_strip_half_extent(strips)
	var track_envelope := track_half_extent + parallel_edge_spacing_metres * 0.5 + track_clearance_metres
	var platform_envelope := platform_half_extent + track_clearance_metres
	return maxf(2.0 * maxf(track_envelope, platform_envelope), minimum_width)


static func platform_strip_half_extent(strips: Array[Dictionary]) -> float:
	var extent := 0.0
	for strip in strips:
		extent = maxf(extent, absf(float(strip.get("edge1", 0.0))))
		extent = maxf(extent, absf(float(strip.get("edge2", 0.0))))
	return extent

