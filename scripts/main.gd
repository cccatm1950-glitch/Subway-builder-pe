extends Node2D

const MIN_ZOOM := 0.45
const MAX_ZOOM := 2.5
const SNAP_SPACING := 32.0
const TAP_DRAG_THRESHOLD := 16.0
const STATION_PICK_RADIUS := 64.0

@onready var camera: Camera2D = $Camera2D
@onready var hud = $CanvasLayer/HUD

var active_touches: Dictionary = {}
var touch_starts: Dictionary = {}
var touch_moved: Dictionary = {}
var ignored_touches: Dictionary = {}
var previous_pinch_distance := 0.0
var build_mode := ""
var stations: Array[Vector2] = []
var track_segments: Array[Vector2] = []
var pending_track_start := -1
var mouse_pointer_down := false
var mouse_pointer_start := Vector2.ZERO
var mouse_pointer_dragged := false

func _ready() -> void:
	camera.enabled = true
	camera.position = Vector2.ZERO
	camera.zoom = Vector2.ONE
	hud.zoom_in_requested.connect(_zoom_in)
	hud.zoom_out_requested.connect(_zoom_out)
	hud.station_mode_requested.connect(_select_station_mode)
	hud.track_mode_requested.connect(_select_track_mode)
	_update_coordinate_readout()
	hud.set_input_status("INPUT READY")

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_screen_touch(event)
	elif event is InputEventScreenDrag:
		_handle_screen_drag(event)
	elif event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		if mouse_pointer_down:
			if event.position.distance_to(mouse_pointer_start) > TAP_DRAG_THRESHOLD:
				mouse_pointer_dragged = true
			_pan_camera(event.relative)
			hud.set_input_status("MOUSE DRAG")

func _handle_screen_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if hud.is_ui_position(event.position):
			ignored_touches[event.index] = true
			return
		active_touches[event.index] = event.position
		touch_starts[event.index] = event.position
		touch_moved[event.index] = false
		hud.set_input_status("TOUCH %d DOWN" % active_touches.size())
		if active_touches.size() >= 2:
			for touch_id in active_touches:
				touch_moved[touch_id] = true
			previous_pinch_distance = _touch_distance()
	else:
		if ignored_touches.has(event.index):
			ignored_touches.erase(event.index)
			return
		var was_last_touch := active_touches.size() == 1 and active_touches.has(event.index)
		var start: Vector2 = touch_starts.get(event.index, event.position)
		var moved := touch_moved.get(event.index, true)
		var is_tap := was_last_touch and not moved and event.position.distance_to(start) <= TAP_DRAG_THRESHOLD
		active_touches.erase(event.index)
		touch_starts.erase(event.index)
		touch_moved.erase(event.index)
		if active_touches.size() < 2:
			previous_pinch_distance = 0.0
		if active_touches.is_empty():
			if is_tap:
				_handle_map_tap(event.position)
				hud.set_input_status("MAP TAP")
			else:
				hud.set_input_status("GESTURE END")
		elif active_touches.size() == 1:
			var remaining_id = active_touches.keys()[0]
			touch_starts[remaining_id] = active_touches[remaining_id]
			touch_moved[remaining_id] = true

func _handle_screen_drag(event: InputEventScreenDrag) -> void:
	if ignored_touches.has(event.index):
		return
	if not active_touches.has(event.index):
		return
	active_touches[event.index] = event.position
	var start: Vector2 = touch_starts.get(event.index, event.position)
	if event.position.distance_to(start) > TAP_DRAG_THRESHOLD:
		touch_moved[event.index] = true
	if active_touches.size() == 1:
		_pan_camera(event.relative)
		hud.set_input_status("MAP DRAG")
	elif active_touches.size() >= 2:
		_update_pinch_zoom()
		hud.set_input_status("PINCH ZOOM")

func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
		_zoom_in()
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
		_zoom_out()
	elif event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if hud.is_ui_position(event.position):
				return
			mouse_pointer_down = true
			mouse_pointer_start = event.position
			mouse_pointer_dragged = false
			hud.set_input_status("POINTER DOWN")
		else:
			if mouse_pointer_down and not mouse_pointer_dragged and not hud.is_ui_position(event.position):
				_handle_map_tap(event.position)
				hud.set_input_status("POINTER TAP")
			elif mouse_pointer_dragged:
				hud.set_input_status("POINTER DRAG END")
			mouse_pointer_down = false

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
