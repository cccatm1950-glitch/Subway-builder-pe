extends Node2D

const MIN_ZOOM := 0.45
const MAX_ZOOM := 2.5
const SNAP_SPACING := 32.0
const TAP_DRAG_THRESHOLD := 14.0
const STATION_PICK_RADIUS := 64.0

@onready var camera: Camera2D = $Camera2D
@onready var hud = $CanvasLayer/HUD

var active_touches: Dictionary = {}
var touch_starts: Dictionary = {}
var gesture_invalid := false
var previous_pinch_distance := 0.0
var mouse_start := Vector2.ZERO
var mouse_dragged := false
var build_mode := ""
var stations: Array[Vector2] = []
var track_segments: Array[Vector2] = []
var pending_track_start := -1

func _ready() -> void:
	camera.enabled = true
	camera.position = Vector2.ZERO
	camera.zoom = Vector2.ONE
	hud.zoom_in_requested.connect(_zoom_in)
	hud.zoom_out_requested.connect(_zoom_out)
	hud.station_mode_requested.connect(_select_station_mode)
	hud.track_mode_requested.connect(_select_track_mode)
	_update_coordinate_readout()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			if active_touches.is_empty():
				gesture_invalid = false
			active_touches[event.index] = event.position
			touch_starts[event.index] = event.position
			if active_touches.size() > 1:
				gesture_invalid = true
				previous_pinch_distance = _touch_distance()
		else:
			var is_final_finger := active_touches.size() == 1
			var start_position: Vector2 = touch_starts.get(event.index, event.position)
			var is_stationary_tap := is_final_finger and not gesture_invalid and event.position.distance_to(start_position) <= TAP_DRAG_THRESHOLD
			active_touches.erase(event.index)
			touch_starts.erase(event.index)
			if active_touches.is_empty():
				previous_pinch_distance = 0.0
				if is_stationary_tap:
					_handle_map_tap(event.position)
				gesture_invalid = false
	elif event is InputEventScreenDrag:
		active_touches[event.index] = event.position
		if touch_starts.has(event.index) and event.position.distance_to(touch_starts[event.index]) > TAP_DRAG_THRESHOLD:
			gesture_invalid = true
		if active_touches.size() == 1:
			_pan_camera(event.relative)
		elif active_touches.size() >= 2:
			gesture_invalid = true
			_update_pinch_zoom()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_in()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_out()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				mouse_start = event.position
				mouse_dragged = false
			elif not mouse_dragged and event.position.distance_to(mouse_start) <= TAP_DRAG_THRESHOLD:
				_handle_map_tap(event.position)
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if event.position.distance_to(mouse_start) > TAP_DRAG_THRESHOLD:
			mouse_dragged = true
		_pan_camera(event.relative)

func _handle_map_tap(screen_position: Vector2) -> void:
	if build_mode == "station":
		var station_position := get_snapped_world_position(screen_position)
		if not stations.has(station_position):
			stations.append(station_position)
			queue_redraw()
		_update_coordinate_readout()
	elif build_mode == "track":
		var station_index := _find_station_near_screen(screen_position)
		if station_index == -1:
			hud.set_mode(build_mode, "TAP DIRECTLY ON A STATION")
			return
		if pending_track_start == -1:
			pending_track_start = station_index
			hud.set_mode(build_mode, "START SELECTED  ·  TAP A DIFFERENT STATION")
		elif station_index == pending_track_start:
			hud.set_mode(build_mode, "SAME STATION  ·  CHOOSE A DIFFERENT ONE")
		else:
			track_segments.append(stations[pending_track_start])
			track_segments.append(stations[station_index])
			pending_track_start = -1
			queue_redraw()
			hud.set_mode(build_mode, "TRACK CONNECTED  ·  SELECT ANOTHER START")

func _find_station_near_screen(screen_position: Vector2) -> int:
	var nearest_index := -1
	var nearest_distance := STATION_PICK_RADIUS
	var canvas_transform := get_viewport().get_canvas_transform()
	for index in range(stations.size()):
		var station_screen: Vector2 = canvas_transform * stations[index]
		var distance := station_screen.distance_to(screen_position)
		if distance <= nearest_distance:
			nearest_distance = distance
			nearest_index = index
	return nearest_index

func _select_station_mode() -> void:
	build_mode = "" if build_mode == "station" else "station"
	pending_track_start = -1
	hud.set_mode(build_mode, "TAP TO PLACE STATIONS  ·  DRAG TO MOVE MAP" if build_mode == "station" else "DRAG TO MOVE  ·  PINCH TO ZOOM")

func _select_track_mode() -> void:
	build_mode = "" if build_mode == "track" else "track"
	pending_track_start = -1
	hud.set_mode(build_mode, "TAP TWO DIFFERENT STATIONS TO CONNECT" if build_mode == "track" else "DRAG TO MOVE  ·  PINCH TO ZOOM")

func _draw() -> void:
	for index in range(0, track_segments.size(), 2):
		if index + 1 < track_segments.size():
			draw_line(track_segments[index], track_segments[index + 1], Color(0.24, 0.86, 0.78), 7.0, true)
	for index in range(stations.size()):
		var station := stations[index]
		draw_circle(station, 12.0, Color(0.88, 0.96, 1.0))
		draw_arc(station, 16.0, 0.0, TAU, 32, Color(0.25, 0.88, 0.82), 2.0, true)
		if build_mode == "track" and index == pending_track_start:
			draw_arc(station, 23.0, 0.0, TAU, 32, Color(1.0, 1.0, 1.0), 2.0, true)

func _pan_camera(screen_delta: Vector2) -> void:
	camera.position -= screen_delta / camera.zoom.x
	_update_coordinate_readout()

func _update_pinch_zoom() -> void:
	var distance := _touch_distance()
	if previous_pinch_distance > 0.0 and distance > 0.0:
		_set_zoom(camera.zoom.x * distance / previous_pinch_distance)
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
	return Vector2(snappedf(world_position.x, SNAP_SPACING), snappedf(world_position.y, SNAP_SPACING))

func _update_coordinate_readout() -> void:
	if is_instance_valid(hud):
		var snapped_center := get_snapped_world_position(get_viewport_rect().size * 0.5)
		hud.set_map_coordinates(snapped_center)
