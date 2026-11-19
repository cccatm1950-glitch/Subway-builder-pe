extends RefCounted
class_name RailwayDimensions

# Canonical desktop-reference dimensions, expressed in metres.
# This module defines the metric reference only. Existing mobile Vector2
# geometry remains in its legacy coordinate system until a separately tested
# migration explicitly opts into this convention.
const METRES_PER_WORLD_UNIT := 1.0

const TRACK_WIDTH_M := 1.435
# Desktop parallelTrackSpacing is edge-to-edge; convert to centreline spacing.
const HEAVY_METRO_PARALLEL_EDGE_SPACING_M := 4.27
const HEAVY_METRO_CENTERLINE_SPACING_M := HEAVY_METRO_PARALLEL_EDGE_SPACING_M + TRACK_WIDTH_M
const HEAVY_METRO_TRACK_CLEARANCE_M := 1.2
const HEAVY_METRO_TRAIN_WIDTH_M := 3.25
const PLATFORM_TRAIN_GAP_M := 0.1

const SIDE_PLATFORM_WIDTH_M := 8.0
const ISLAND_PLATFORM_WIDTH_M := 10.0
const EXPRESS_ISLAND_PLATFORM_WIDTH_M := 8.0
const MIN_STATION_LENGTH_M := 104.0
const MAX_STATION_LENGTH_M := 312.0

static func metres_to_world_units(metres: float) -> float:
	return metres / METRES_PER_WORLD_UNIT

static func world_units_to_metres(world_units: float) -> float:
	return world_units * METRES_PER_WORLD_UNIT

static func platform_half_width(platform_width_metres: float) -> float:
	return maxf(platform_width_metres, 0.0) * 0.5

static func train_half_width_with_platform_gap() -> float:
	return HEAVY_METRO_TRAIN_WIDTH_M * 0.5 + PLATFORM_TRAIN_GAP_M
