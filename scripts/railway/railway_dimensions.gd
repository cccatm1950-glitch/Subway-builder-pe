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
	var parallel_outer := half_track + parallel_edge_spacing_metres * 0.5
	var quad_outer := parallel_outer + TRACK_WIDTH_M + parallel_edge_spacing_metres
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
			var offset := parallel_outer + clearance
			strips.append({"edge1": -offset - side_width, "edge2": -offset})
			strips.append({"edge1": offset, "edge2": offset + side_width})
		"quad-local":
			var inner := express_island_width * 0.5 + clearance
			var outer := inner + TRACK_WIDTH_M + parallel_edge_spacing_metres
			strips.append({"edge1": -outer - side_width, "edge2": -outer})
			strips.append({"edge1": outer, "edge2": outer + side_width})
		"quad-local-center":
			var inner := parallel_outer
			var outer := inner + train_width_metres + 2.0 * PLATFORM_TRAIN_GAP_M + express_island_width
			strips.append({"edge1": -outer - side_width, "edge2": -outer})
			strips.append({"edge1": outer, "edge2": outer + side_width})
		"quad-express":
			var offset := quad_outer + clearance
			strips.append({"edge1": -offset - side_width, "edge2": -offset})
			strips.append({"edge1": offset, "edge2": offset + side_width})
			strips.append({"edge1": -express_island_width * 0.5, "edge2": express_island_width * 0.5})
		"quad-classic", "quad-local-outer":
			var inner := parallel_outer
			var outer := inner + TRACK_WIDTH_M + parallel_edge_spacing_metres
			strips.append({"edge1": -outer - side_width, "edge2": -outer})
			strips.append({"edge1": outer, "edge2": outer + side_width})
		_:
			return strips
	return strips


static func platform_strip_half_extent(strips: Array[Dictionary]) -> float:
	var extent := 0.0
	for strip in strips:
		extent = maxf(extent, absf(float(strip.get("edge1", 0.0))))
		extent = maxf(extent, absf(float(strip.get("edge2", 0.0))))
	return extent

