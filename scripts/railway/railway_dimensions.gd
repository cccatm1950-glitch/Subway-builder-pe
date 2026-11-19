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
