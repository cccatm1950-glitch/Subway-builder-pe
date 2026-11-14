extends Node2D

const MIN_ZOOM := 0.45
const MAX_ZOOM := 2.5
const SNAP_SPACING := 32.0

@onready var camera: Camera2D = $Camera2D
@onready var hud = $CanvasLayer/HUD

var active_touches: Dictionary = {}
var previous_pinch_distance := 0.0

func _ready() -> void:
	camera.enabled = true
	camera.position = Vector2.ZERO
	camera.zoom = Vector2.ONE
	hud.zoom_in_requested.connect(_zoom_in)
	hud.zoom_out_requested.connect(_zoom_out)
	_update_coordinate_readout()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			active_touches[event.index] = event.position
			if active_touches.size() == 2:
				previous_pinch_distance = _touch_distance()
		else:
			active_touches.erase(event.index)
			previous_pinch_distance = 0.0
	elif event is InputEventScreenDrag:
		active_touches[event.index] = event.position
		if active_touches.size() == 1:
			_pan_camera(event.relative)
		elif active_touches.size() >= 2:
			_update_pinch_zoom()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_in()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_out()
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_pan_camera(event.relative)

func _pan_camera(screen_delta: Vector2) -> void:
	camera.position -= screen_delta / camera.zoom.x
	_update_coordinate_readout()

func _update_pinch_zoom() -> void:
	var distance := _touch_distance()
	if previous_pinch_distance > 0.0 and distance > 0.0:
		var zoom_factor := distance / previous_pinch_distance
		_set_zoom(camera.zoom.x * zoom_factor)
	previous_pinch_distance = distance
	_update_coordinate_readout()

func _touch_distance() -> float:
	if active_touches.size() < 2:
		return 0.0
	var points: Array = active_touches.values()
	return points[0].distance_to(points[1])

func _zoom_in() -> void:
	_set_zoom(camera.zoom.x * 1.2)
	_update_coordinate_readout()

func _zoom_out() -> void:
	_set_zoom(camera.zoom.x / 1.2)
	_update_coordinate_readout()

func _set_zoom(value: float) -> void:
	var zoom_level := clampf(value, MIN_ZOOM, MAX_ZOOM)
	camera.zoom = Vector2.ONE * zoom_level

func screen_to_world(screen_position: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen_position

func get_snapped_world_position(screen_position: Vector2) -> Vector2:
	var world_position := screen_to_world(screen_position)
	return Vector2(
		snappedf(world_position.x, SNAP_SPACING),
		snappedf(world_position.y, SNAP_SPACING)
	)

func _update_coordinate_readout() -> void:
	if is_instance_valid(hud):
		var snapped_center := get_snapped_world_position(get_viewport_rect().size * 0.5)
		hud.set_map_coordinates(snapped_center)
