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
var curve_segments: Array[Dictionary] = []
var pending_track_start := -1
var pending_curve_start := -1
var pending_curve_control := Vector2.ZERO
var curve_stage := 0
var mouse_pointer_down := false
var mouse_pointer_start := Vector2.ZERO
var mouse_pointer_dragged := false
var curve_handle_dragging := false
var curve_handle_touch_index := -1
var editing_curve_index := -1

func _ready() -> void:
	camera.enabled = true
	camera.position = Vector2.ZERO
	camera.zoom = Vector2.ONE
	hud.zoom_in_requested.connect(_zoom_in)
	hud.zoom_out_requested.connect(_zoom_out)
	hud.station_mode_requested.connect(_select_station_mode)
	hud.track_mode_requested.connect(_select_track_mode)
	hud.curve_mode_requested.connect(_select_curve_mode)
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
		if curve_handle_dragging and curve_handle_touch_index == -2:
			_move_curve_handle(event.position)
			queue_redraw()
			return
		if mouse_pointer_down:
			if event.position.distance_to(mouse_pointer_start) > TAP_DRAG_THRESHOLD:
				mouse_pointer_dragged = true
			_pan_camera(event.relative)
			hud.set_input_status("MOUSE DRAG")

func _handle_screen_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if _try_begin_curve_handle_drag(event.position, event.index):
			return
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
		if curve_handle_dragging and curve_handle_touch_index == event.index:
			curve_handle_dragging = false
			curve_handle_touch_index = -1
			editing_curve_index = -1
			hud.set_mode(build_mode, "BEND SET  ·  DRAG AGAIN OR TAP AN END STATION")
			queue_redraw()
			return
		if ignored_touches.has(event.index):
			ignored_touches.erase(event.index)
			return
		var was_last_touch := active_touches.size() == 1 and active_touches.has(event.index)
		var start: Vector2 = touch_starts.get(event.index, event.position)
		var moved: bool = bool(touch_moved.get(event.index, true))
		var is_tap: bool = was_last_touch and not moved and event.position.distance_to(start) <= TAP_DRAG_THRESHOLD
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
	if curve_handle_dragging and curve_handle_touch_index == event.index:
		_move_curve_handle(event.position)
		queue_redraw()
		return
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
			if _try_begin_curve_handle_drag(event.position, -2):
				return
			if hud.is_ui_position(event.position):
				return
			mouse_pointer_down = true
			mouse_pointer_start = event.position
			mouse_pointer_dragged = false
			hud.set_input_status("POINTER DOWN")
		else:
			if curve_handle_dragging and curve_handle_touch_index == -2:
				curve_handle_dragging = false
				curve_handle_touch_index = -1
				editing_curve_index = -1
				hud.set_mode(build_mode, "BEND SET  ·  DRAG AGAIN OR TAP AN END STATION")
				queue_redraw()
				return
			if mouse_pointer_down and not mouse_pointer_dragged and not hud.is_ui_position(event.position):
				_handle_map_tap(event.position)
				hud.set_input_status("POINTER TAP")
			elif mouse_pointer_dragged:
				hud.set_input_status("POINTER DRAG END")
			mouse_pointer_down = false

func _handle_map_tap(screen_position: Vector2) -> void:
	if build_mode == "curve":
		_handle_curve_tap(screen_position)
	elif build_mode == "station":
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

func _handle_curve_tap(screen_position: Vector2) -> void:
	if curve_stage == 0:
		var station_index := _find_station_near_screen(screen_position)
		if station_index == -1:
			hud.set_mode(build_mode, "SELECT AN EXISTING START STATION")
			return
		pending_curve_start = station_index
		curve_stage = 1
		var start_screen: Vector2 = get_viewport().get_canvas_transform() * stations[station_index]
		var center := get_viewport_rect().size * 0.5
		var direction := (center - start_screen).normalized()
		if direction.length_squared() < 0.01:
			direction = Vector2.RIGHT
		var normal := Vector2(-direction.y, direction.x)
		pending_curve_control = screen_to_world(start_screen + direction * 90.0 + normal * 55.0)
		hud.set_mode(build_mode, "DRAG THE CURVE HANDLE TO SHAPE THE BEND")
		queue_redraw()
	else:
		var end_index := _find_station_near_screen(screen_position)
		if end_index == -1:
			hud.set_mode(build_mode, "TAP AN EXISTING END STATION")
			return
		if end_index == pending_curve_start:
			hud.set_mode(build_mode, "CHOOSE A DIFFERENT END STATION")
			return
		var curve_start: Vector2 = stations[pending_curve_start]
		var curve_end: Vector2 = stations[end_index]
		var curve_control := _constrain_curve_control(curve_start, pending_curve_control, curve_end)
		curve_segments.append({"start": curve_start, "control": curve_control, "end": curve_end})
		pending_curve_start = -1
		curve_stage = 0
		queue_redraw()
		hud.set_mode(build_mode, "CURVE CONNECTED  ·  SELECT ANOTHER START")

func _try_begin_curve_handle_drag(screen_position: Vector2, touch_index: int) -> bool:
	if curve_handle_dragging:
		return true
	if build_mode != "curve":
		return false
	var transform := get_viewport().get_canvas_transform()
	if curve_stage == 1 and pending_curve_start >= 0:
		var pending_screen: Vector2 = transform * pending_curve_control
		if pending_screen.distance_to(screen_position) <= 48.0:
			editing_curve_index = -1
			curve_handle_dragging = true
			curve_handle_touch_index = touch_index
			hud.set_input_status("SHAPING NEW CURVE")
			return true
	for index in range(curve_segments.size() - 1, -1, -1):
		var handle_screen: Vector2 = transform * curve_segments[index]["control"]
		if handle_screen.distance_to(screen_position) <= 48.0:
			editing_curve_index = index
			curve_handle_dragging = true
			curve_handle_touch_index = touch_index
			hud.set_input_status("EDITING COMPLETED CURVE")
			return true
	return false

func _move_curve_handle(screen_position: Vector2) -> void:
	var new_control := screen_to_world(screen_position)
	if editing_curve_index >= 0 and editing_curve_index < curve_segments.size():
		var curve: Dictionary = curve_segments[editing_curve_index]
		curve["control"] = _constrain_curve_control(curve["start"], new_control, curve["end"])
	else:
		if pending_curve_start >= 0 and pending_curve_start < stations.size():
			var preview_end := get_snapped_world_position(get_viewport_rect().size * 0.5)
			pending_curve_control = _constrain_curve_control(stations[pending_curve_start], new_control, preview_end)
		else:
			pending_curve_control = new_control

func _constrain_curve_control(start_point: Vector2, raw_control: Vector2, end_point: Vector2) -> Vector2:
	var chord := end_point - start_point
	var chord_length := chord.length()
	if chord_length < 1.0:
		return (start_point + end_point) * 0.5
	var direction := chord / chord_length
	var normal := Vector2(-direction.y, direction.x)
	var midpoint := (start_point + end_point) * 0.5
	var offset := raw_control - midpoint
	var along := clampf(offset.dot(direction), -chord_length * 0.35, chord_length * 0.35)
	var sideways := clampf(offset.dot(normal), -chord_length * 0.8, chord_length * 0.8)
	return midpoint + direction * along + normal * sideways

func _make_curve_points(start_point: Vector2, control_point: Vector2, end_point: Vector2) -> PackedVector2Array:
	var points := PackedVector2Array()
	var chord := end_point - start_point
	var chord_length := chord.length()
	var chord_direction := chord.normalized() if chord_length > 0.001 else Vector2.RIGHT
	var start_direction := (control_point - start_point).normalized()
	var end_direction := (end_point - control_point).normalized()
	if start_direction == Vector2.ZERO:
		start_direction = chord_direction
	if end_direction == Vector2.ZERO:
		end_direction = chord_direction
	var start_track_tangent := _find_connected_track_tangent(start_point, start_direction, false)
	var end_track_tangent := _find_connected_track_tangent(end_point, end_direction, true)
	if start_track_tangent == Vector2.ZERO and end_track_tangent == Vector2.ZERO:
		for step in range(25):
			var t := float(step) / 24.0
			var one_minus_t := 1.0 - t
			points.append(one_minus_t * one_minus_t * start_point + 2.0 * one_minus_t * t * control_point + t * t * end_point)
		return points

	# Preserve tangent continuity where a curve joins an existing straight track.
	# The middle pair of control points remains tied to the user's draggable handle.
	var start_tangent := start_track_tangent
	if start_tangent == Vector2.ZERO:
		start_tangent = (control_point - start_point).normalized()
	var end_tangent := end_track_tangent
	if end_tangent == Vector2.ZERO:
		end_tangent = (end_point - control_point).normalized()
	if start_tangent == Vector2.ZERO:
		start_tangent = chord_direction
	if end_tangent == Vector2.ZERO:
		end_tangent = chord_direction
	var tangent_length := maxf(chord_length * 0.22, 8.0)
	var p0 := start_point
	var p1 := start_point + start_tangent * tangent_length
	var p2 := control_point
	var p3 := control_point
	var p4 := end_point - end_tangent * tangent_length
	var p5 := end_point
	for step in range(41):
		var t := float(step) / 40.0
		var a := p0.lerp(p1, t)
		var b := p1.lerp(p2, t)
		var c := p2.lerp(p3, t)
		var d := p3.lerp(p4, t)
		var e := p4.lerp(p5, t)
		var f := a.lerp(b, t)
		var g := b.lerp(c, t)
		var h := c.lerp(d, t)
		var i := d.lerp(e, t)
		var j := f.lerp(g, t)
		var k := g.lerp(h, t)
		var l := h.lerp(i, t)
		var m := j.lerp(k, t)
		var n := k.lerp(l, t)
		points.append(m.lerp(n, t))
	return points

func _find_connected_track_tangent(station_point: Vector2, preferred_direction: Vector2, at_curve_end: bool) -> Vector2:
	var best_tangent := Vector2.ZERO
	var best_alignment := -INF
	for index in range(0, track_segments.size(), 2):
		if index + 1 >= track_segments.size():
			continue
		var first: Vector2 = track_segments[index]
		var second: Vector2 = track_segments[index + 1]
		var neighbor := Vector2.ZERO
		if first == station_point:
			neighbor = second
		elif second == station_point:
			neighbor = first
		else:
			continue
		var away_from_station := (neighbor - station_point).normalized()
		if away_from_station == Vector2.ZERO:
			continue
		# At the curve's end, travel points from the neighboring track into the station.
		var travel_tangent := -away_from_station if at_curve_end else away_from_station
		var alignment := travel_tangent.dot(preferred_direction)
		if alignment > best_alignment:
			best_alignment = alignment
			best_tangent = travel_tangent
	return best_tangent

func _select_curve_mode() -> void:
	build_mode = "" if build_mode == "curve" else "curve"
	curve_handle_dragging = false
	curve_handle_touch_index = -1
	editing_curve_index = -1
	pending_track_start = -1
	pending_curve_start = -1
	curve_stage = 0
	hud.set_mode(build_mode, "SELECT START STATION" if build_mode == "curve" else "DRAG TO MOVE  ·  PINCH TO ZOOM")
	queue_redraw()

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
	pending_curve_start = -1
	curve_stage = 0
	hud.set_mode(build_mode, "TAP TO PLACE STATIONS  ·  DRAG TO MOVE MAP" if build_mode == "station" else "DRAG TO MOVE  ·  PINCH TO ZOOM")

func _select_track_mode() -> void:
	build_mode = "" if build_mode == "track" else "track"
	pending_track_start = -1
	pending_curve_start = -1
	curve_stage = 0
	hud.set_mode(build_mode, "TAP TWO DIFFERENT STATIONS TO CONNECT" if build_mode == "track" else "DRAG TO MOVE  ·  PINCH TO ZOOM")

func _draw() -> void:
	for index in range(curve_segments.size()):
		var curve: Dictionary = curve_segments[index]
		var curve_points := _make_curve_points(curve["start"], curve["control"], curve["end"])
		if curve_points.size() > 1:
			draw_polyline(curve_points, Color(0.24, 0.86, 0.78), 7.0, true)
		if build_mode == "curve":
			_draw_completed_curve_handle(curve, index == editing_curve_index)
	for index in range(0, track_segments.size(), 2):
		if index + 1 < track_segments.size():
			draw_line(track_segments[index], track_segments[index + 1], Color(0.24, 0.86, 0.78), 7.0, true)
	if build_mode == "track" and pending_track_start >= 0 and pending_track_start < stations.size():
		_draw_track_preview()
	if build_mode == "curve" and pending_curve_start >= 0 and pending_curve_start < stations.size():
		_draw_curve_preview()
	for index in range(stations.size()):
		var station := stations[index]
		draw_circle(station, 12.0, Color(0.88, 0.96, 1.0))
		draw_arc(station, 16.0, 0.0, TAU, 32, Color(0.25, 0.88, 0.82), 2.0, true)
		if build_mode == "track" and index == pending_track_start:
			draw_arc(station, 23.0, 0.0, TAU, 32, Color(1.0, 1.0, 1.0), 2.0, true)

func _draw_completed_curve_handle(curve: Dictionary, is_being_edited: bool) -> void:
	var control: Vector2 = curve["control"]
	var zoom_scale := camera.zoom.x
	draw_line(curve["start"], control, Color(0.72, 1.0, 0.97, 0.55), 2.0 / zoom_scale, true)
	var radius := 19.0 / zoom_scale
	var fill := Color(0.08, 0.22, 0.23, 0.98) if not is_being_edited else Color(0.12, 0.34, 0.34, 1.0)
	draw_circle(control, radius, fill)
	draw_circle(control, 10.0 / zoom_scale, Color(0.55, 1.0, 0.94, 0.98))
	draw_arc(control, 27.0 / zoom_scale, 0.0, TAU, 40, Color(0.72, 1.0, 0.97, 1.0), 3.0 / zoom_scale, true)

func _draw_curve_preview() -> void:
	var start_point: Vector2 = stations[pending_curve_start]
	var end_point := get_snapped_world_position(get_viewport_rect().size * 0.5)
	var points := _make_curve_points(start_point, pending_curve_control, end_point)
	draw_polyline(points, Color(0.42, 1.0, 0.92, 0.9), 4.0 / camera.zoom.x, true)
	# A persistent guide makes the draggable control point easy to identify.
	draw_line(start_point, pending_curve_control, Color(0.72, 1.0, 0.97, 0.72), 2.0 / camera.zoom.x, true)
	var handle_radius := 19.0 / camera.zoom.x
	draw_circle(pending_curve_control, handle_radius, Color(0.05, 0.16, 0.17, 0.96))
	draw_circle(pending_curve_control, 10.0 / camera.zoom.x, Color(0.55, 1.0, 0.94, 0.95))
	draw_arc(pending_curve_control, 27.0 / camera.zoom.x, 0.0, TAU, 40, Color(0.72, 1.0, 0.97, 1.0), 3.0 / camera.zoom.x, true)

func _draw_track_preview() -> void:
	var viewport_size := get_viewport_rect().size
	var preview_end := get_snapped_world_position(viewport_size * 0.5)
	var preview_start: Vector2 = stations[pending_track_start]
	var canvas_transform := get_viewport().get_canvas_transform()
	var inverse_transform := canvas_transform.affine_inverse()
	var start_screen := canvas_transform * preview_start
	var end_screen := canvas_transform * preview_end
	var clipped := _clip_preview_segment(start_screen, end_screen, Rect2(Vector2.ZERO, viewport_size))
	if clipped.size() == 2:
		var clipped_start: Vector2 = clipped[0]
		var clipped_end: Vector2 = clipped[1]
		var segment_length := clipped_start.distance_to(clipped_end)
		var direction := (clipped_end - clipped_start).normalized()
		var dash_start := 0.0
		while dash_start < segment_length:
			var dash_end := minf(dash_start + 10.0, segment_length)
			var a := inverse_transform * (clipped_start + direction * dash_start)
			var b := inverse_transform * (clipped_start + direction * dash_end)
			draw_line(a, b, Color(0.42, 1.0, 0.92, 0.92), 4.0, true)
			dash_start += 18.0
	# The target remains fixed to the snapped world point beneath the screen crosshair.
	draw_circle(preview_end, 9.0, Color(0.35, 0.95, 0.88, 0.16))
	draw_arc(preview_end, 13.0, 0.0, TAU, 32, Color(0.72, 1.0, 0.97, 1.0), 2.5, true)

func _clip_preview_segment(a: Vector2, b: Vector2, rect: Rect2) -> Array[Vector2]:
	var delta := b - a
	var p_values := [-delta.x, delta.x, -delta.y, delta.y]
	var q_values := [a.x - rect.position.x, rect.end.x - a.x, a.y - rect.position.y, rect.end.y - a.y]
	var t_min := 0.0
	var t_max := 1.0
	for index in range(4):
		var p: float = p_values[index]
		var q: float = q_values[index]
		if is_zero_approx(p):
			if q < 0.0:
				return []
		else:
			var ratio := q / p
			if p < 0.0:
				t_min = maxf(t_min, ratio)
			else:
				t_max = minf(t_max, ratio)
			if t_min > t_max:
				return []
	return [a + delta * t_min, a + delta * t_max]

func _pan_camera(screen_delta: Vector2) -> void:
	camera.position -= screen_delta / camera.zoom.x
	queue_redraw()
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
	queue_redraw()

func screen_to_world(screen_position: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen_position

func get_snapped_world_position(screen_position: Vector2) -> Vector2:
	var world_position := screen_to_world(screen_position)
	return Vector2(snappedf(world_position.x, SNAP_SPACING), snappedf(world_position.y, SNAP_SPACING))

func _update_coordinate_readout() -> void:
	if is_instance_valid(hud):
		var snapped_center := get_snapped_world_position(get_viewport_rect().size * 0.5)
		hud.set_map_coordinates(snapped_center)
