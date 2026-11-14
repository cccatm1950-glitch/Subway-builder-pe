extends Control

signal zoom_in_requested
signal zoom_out_requested

var coordinate_label: Label
var hint_label: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var title := Label.new()
	title.text = "SUBWAY BUILDER"
	title.position = Vector2(24, 22)
	title.size = Vector2(360, 42)
	title.add_theme_color_override("font_color", Color(0.91, 0.97, 1.0))
	title.add_theme_font_size_override("font_size", 24)
	add_child(title)

	coordinate_label = Label.new()
	coordinate_label.position = Vector2(24, 68)
	coordinate_label.size = Vector2(420, 30)
	coordinate_label.add_theme_color_override("font_color", Color(0.35, 0.83, 0.79))
	coordinate_label.add_theme_font_size_override("font_size", 14)
	add_child(coordinate_label)

	hint_label = Label.new()
	hint_label.text = "DRAG TO MOVE  ·  PINCH TO ZOOM"
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.anchor_left = 0.0
	hint_label.anchor_right = 1.0
	hint_label.anchor_top = 1.0
	hint_label.anchor_bottom = 1.0
	hint_label.offset_left = 12
	hint_label.offset_top = -54
	hint_label.offset_right = -12
	hint_label.offset_bottom = -24
	hint_label.add_theme_color_override("font_color", Color(0.64, 0.74, 0.79))
	hint_label.add_theme_font_size_override("font_size", 13)
	add_child(hint_label)

	var zoom_in := _make_zoom_button("+")
	zoom_in.anchor_left = 1.0
	zoom_in.anchor_right = 1.0
	zoom_in.anchor_top = 1.0
	zoom_in.anchor_bottom = 1.0
	zoom_in.offset_left = -82
	zoom_in.offset_top = -166
	zoom_in.offset_right = -22
	zoom_in.offset_bottom = -106
	zoom_in.pressed.connect(func(): zoom_in_requested.emit())
	add_child(zoom_in)

	var zoom_out := _make_zoom_button("−")
	zoom_out.anchor_left = 1.0
	zoom_out.anchor_right = 1.0
	zoom_out.anchor_top = 1.0
	zoom_out.anchor_bottom = 1.0
	zoom_out.offset_left = -82
	zoom_out.offset_top = -96
	zoom_out.offset_right = -22
	zoom_out.offset_bottom = -36
	zoom_out.pressed.connect(func(): zoom_out_requested.emit())
	add_child(zoom_out)

func _make_zoom_button(caption: String) -> Button:
	var button := Button.new()
	button.text = caption
	button.add_theme_font_size_override("font_size", 28)
	button.add_theme_color_override("font_color", Color(0.91, 0.97, 1.0))
	button.add_theme_stylebox_override("normal", _button_style(Color(0.08, 0.14, 0.17, 0.94)))
	button.add_theme_stylebox_override("hover", _button_style(Color(0.11, 0.22, 0.24, 0.98)))
	button.add_theme_stylebox_override("pressed", _button_style(Color(0.12, 0.38, 0.36, 1.0)))
	button.focus_mode = Control.FOCUS_NONE
	return button

func _button_style(fill: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.corner_radius_top_left = 30
	style.corner_radius_top_right = 30
	style.corner_radius_bottom_left = 30
	style.corner_radius_bottom_right = 30
	return style

func set_map_coordinates(position: Vector2) -> void:
	if is_instance_valid(coordinate_label):
		coordinate_label.text = "MAP  %d, %d" % [roundi(position.x), roundi(position.y)]

func _draw() -> void:
	var center := size * 0.5
	var color := Color(0.88, 0.96, 1.0, 0.92)
	draw_line(center + Vector2(-15, 0), center + Vector2(-5, 0), color, 2.0, true)
	draw_line(center + Vector2(5, 0), center + Vector2(15, 0), color, 2.0, true)
	draw_line(center + Vector2(0, -15), center + Vector2(0, -5), color, 2.0, true)
	draw_line(center + Vector2(0, 5), center + Vector2(0, 15), color, 2.0, true)
	draw_circle(center, 2.5, color)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
