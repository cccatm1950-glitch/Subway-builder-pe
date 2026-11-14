extends Node2D

const GRID_SPACING := 64.0
const MAJOR_EVERY := 8
const GRID_EXTENT := 8192.0

func _draw() -> void:
	var minor_color := Color(0.12, 0.19, 0.23, 0.48)
	var major_color := Color(0.17, 0.27, 0.31, 0.72)
	var half_steps := int(GRID_EXTENT / GRID_SPACING)
	for step in range(-half_steps, half_steps + 1):
		var coordinate := float(step) * GRID_SPACING
		var line_color := major_color if step % MAJOR_EVERY == 0 else minor_color
		draw_line(Vector2(coordinate, -GRID_EXTENT), Vector2(coordinate, GRID_EXTENT), line_color, 1.0)
		draw_line(Vector2(-GRID_EXTENT, coordinate), Vector2(GRID_EXTENT, coordinate), line_color, 1.0)
	draw_line(Vector2(-GRID_EXTENT, 0), Vector2(GRID_EXTENT, 0), Color(0.22, 0.48, 0.49, 0.8), 2.0)
	draw_line(Vector2(0, -GRID_EXTENT), Vector2(0, GRID_EXTENT), Color(0.22, 0.48, 0.49, 0.8), 2.0)
