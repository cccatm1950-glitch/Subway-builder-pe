extends Node2D

const Dimensions = preload("res://scripts/railway/railway_dimensions.gd")
const DISPLAY_PIXELS_PER_METRE := 24.0
const LEFT := 72.0
const LABEL_X := 72.0
const BAR_X := 300.0
const BAR_COLOR := Color(0.30, 0.88, 0.92, 1.0)
const TEXT_COLOR := Color(0.92, 0.96, 0.98, 1.0)
const MUTED_COLOR := Color(0.58, 0.68, 0.73, 1.0)

func _draw() -> void:
	var font := ThemeDB.fallback_font
	var font_size := 18
	draw_string(font, Vector2(LEFT, 62), "DESKTOP METRIC REFERENCE", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, TEXT_COLOR)
	draw_string(font, Vector2(LEFT, 94), "Display ruler only — existing mobile geometry is unchanged", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, MUTED_COLOR)

	var rows := [
		{"label": "Track width / gauge reference", "value": Dimensions.TRACK_WIDTH_M},
		{"label": "Heavy-metro centre spacing", "value": Dimensions.HEAVY_METRO_CENTERLINE_SPACING_M},
		{"label": "Track clearance", "value": Dimensions.HEAVY_METRO_TRACK_CLEARANCE_M},
		{"label": "Side platform width", "value": Dimensions.SIDE_PLATFORM_WIDTH_M},
		{"label": "Island platform width", "value": Dimensions.ISLAND_PLATFORM_WIDTH_M}
	]
	var y := 160.0
	for row in rows:
		var value := float(row["value"])
		var end_x := BAR_X + value * DISPLAY_PIXELS_PER_METRE
		draw_string(font, Vector2(LABEL_X, y + 5.0), String(row["label"]), HORIZONTAL_ALIGNMENT_LEFT, 214.0, 14, TEXT_COLOR)
		draw_line(Vector2(BAR_X, y), Vector2(end_x, y), BAR_COLOR, 4.0, true)
		draw_line(Vector2(BAR_X, y - 8.0), Vector2(BAR_X, y + 8.0), BAR_COLOR, 2.0)
		draw_line(Vector2(end_x, y - 8.0), Vector2(end_x, y + 8.0), BAR_COLOR, 2.0)
		draw_string(font, Vector2(end_x + 10.0, y + 5.0), "%.3f m" % value, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, TEXT_COLOR)
		y += 76.0

	var scale_y := y + 24.0
	var scale_end := BAR_X + 10.0 * DISPLAY_PIXELS_PER_METRE
	draw_line(Vector2(BAR_X, scale_y), Vector2(scale_end, scale_y), MUTED_COLOR, 3.0, true)
	for tick in range(11):
		var x := BAR_X + float(tick) * DISPLAY_PIXELS_PER_METRE
		draw_line(Vector2(x, scale_y - 6.0), Vector2(x, scale_y + 6.0), MUTED_COLOR, 1.0)
	draw_string(font, Vector2(BAR_X, scale_y + 30.0), "10 m scale bar  ·  24 display pixels per metre", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, MUTED_COLOR)
	draw_string(font, Vector2(LEFT, scale_y + 82.0), "1 world unit = 1 metre is a coordinate convention, not a measured legacy conversion.", HORIZONTAL_ALIGNMENT_LEFT, 570.0, 13, MUTED_COLOR)
