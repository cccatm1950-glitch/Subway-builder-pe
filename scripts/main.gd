extends Node2D

const MIN_ZOOM := 0.45
const MAX_ZOOM := 2.5
const SNAP_SPACING := 32.0
const TAP_DRAG_THRESHOLD := 16.0
const STATION_PICK_RADIUS := 64.0
const PARALLEL_CENTERLINE_SPACING := 48.0

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
# Topology records keep station connectivity and future parallel-lane metadata
# separate from the legacy endpoint array used by current drawing code.
var track_edges: Array[Dictionary] = []
var junction_transition_paths: Array[PackedVector2Array] = []
var next_track_edge_id := 1
var curve_segments: Array[Dictionary] = []
var parallel_curve_segments: Array[Dictionary] = []
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
	hud.parallel_mode_requested.connect(_select_parallel_mode)
	hud.parallel_curve_mode_requested.connect(_select_parallel_curve_mode)
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
	elif build_mode == "parallel_curve":
		_handle_parallel_curve_tap(screen_position)
	elif build_mode == "station":
		var station_position := get_snapped_world_position(screen_position)
		if not stations.has(station_position):
			stations.append(station_position)
			queue_redraw()
		_update_coordinate_readout()
	elif build_mode == "track" or build_mode == "parallel":
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
			var start_station := pending_track_start
			var end_station := station_index
			if build_mode == "parallel":
				_add_parallel_track_pair(start_station, end_station)
			else:
				_add_track_edge(start_station, end_station, stations[start_station], stations[end_station], "single", -1, 0, 1, 0.0)
			pending_track_start = -1
			queue_redraw()
			hud.set_mode(build_mode, "TRACKS CONNECTED  ·  SELECT ANOTHER START" if build_mode == "parallel" else "TRACK CONNECTED  ·  SELECT ANOTHER START")

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

func _handle_parallel_curve_tap(screen_position: Vector2) -> void:
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
		hud.set_mode(build_mode, "DRAG SHARED HANDLE  ·  TAP END STATION")
		queue_redraw()
		return
	var end_index := _find_station_near_screen(screen_position)
	if end_index == -1:
		hud.set_mode(build_mode, "TAP AN EXISTING END STATION")
		return
	if end_index == pending_curve_start:
		hud.set_mode(build_mode, "CHOOSE A DIFFERENT END STATION")
		return
	var curve_start: Vector2 = stations[pending_curve_start]
	var curve_end: Vector2 = stations[end_index]
	var control := _constrain_curve_control(curve_start, pending_curve_control, curve_end)
	var pair := _offset_parallel_curve(_make_curve_points(curve_start, control, curve_end), PARALLEL_CENTERLINE_SPACING * 0.5)
	if pair.size() != 2 or pair[0].size() < 2 or pair[1].size() < 2:
		hud.set_mode(build_mode, "COULD NOT CREATE PARALLEL CURVE")
		return
	parallel_curve_segments.append({"paths": pair, "start_station": pending_curve_start, "end_station": end_index})
	var group_id := next_track_edge_id
	for lane in range(2):
		var path: PackedVector2Array = pair[lane]
		track_edges.append({"id": next_track_edge_id, "start_station": pending_curve_start, "end_station": end_index, "start_point": path[0], "end_point": path[path.size() - 1], "kind": "parallel_curve", "parallel_group": group_id, "lane_index": lane, "lane_count": 2, "centerline_spacing": PARALLEL_CENTERLINE_SPACING})
		next_track_edge_id += 1
	pending_curve_start = -1
	curve_stage = 0
	queue_redraw()
	hud.set_mode(build_mode, "PARALLEL CURVE CONNECTED  ·  SELECT ANOTHER START")

func _offset_parallel_curve(centerline: PackedVector2Array, half_spacing: float) -> Array[PackedVector2Array]:
	var first := PackedVector2Array()
	var second := PackedVector2Array()
	if centerline.size() < 2:
		return [first, second]

	var segment_normals: Array[Vector2] = []
	for index in range(centerline.size() - 1):
		var segment := centerline[index + 1] - centerline[index]
		if segment.length_squared() < 0.0001:
			return []
		var tangent := segment.normalized()
		segment_normals.append(Vector2(-tangent.y, tangent.x))

	for index in range(centerline.size()):
		var offset_normal: Vector2
		if index == 0:
			offset_normal = segment_normals[0]
		elif index == centerline.size() - 1:
			offset_normal = segment_normals[segment_normals.size() - 1]
		else:
			var normal_sum := segment_normals[index - 1] + segment_normals[index]
			if normal_sum.length_squared() < 0.0001:
				return []
			offset_normal = normal_sum.normalized()
		# Keep the two lane centerlines exactly one full spacing apart at
		# every sampled point. The centerline is densely sampled, so averaging
		# adjacent normals avoids the exaggerated miter spread at tight bends.
		var offset := offset_normal * half_spacing
		first.append(centerline[index] + offset)
		second.append(centerline[index] - offset)
	return [first, second]

func _try_begin_curve_handle_drag(screen_position: Vector2, touch_index: int) -> bool:
	if curve_handle_dragging:
		return true
	if build_mode != "curve" and build_mode != "parallel_curve":
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
	var start_to_handle := control_point - start_point
	var handle_to_end := end_point - control_point
	var first_length := start_to_handle.length()
	var second_length := handle_to_end.length()
	if first_length < 0.001 or second_length < 0.001:
		return points

	var start_track_tangent := _find_connected_track_tangent(start_point, start_to_handle.normalized(), false)
	var end_track_tangent := _find_connected_track_tangent(end_point, handle_to_end.normalized(), true)
	var start_tangent := start_track_tangent if start_track_tangent != Vector2.ZERO else start_to_handle.normalized()
	var end_tangent := end_track_tangent if end_track_tangent != Vector2.ZERO else handle_to_end.normalized()
	if start_tangent == Vector2.ZERO:
		start_tangent = chord_direction
	if end_tangent == Vector2.ZERO:
		end_tangent = chord_direction

	# Build two cubic sections with matched first and second derivatives
	# at the draggable handle. Matching curvature removes the visible "knee"
	# where the two halves previously met.
	var start_handle_length := minf(first_length * 0.38, maxf(chord_length * 0.22, 8.0))
	var end_handle_length := minf(second_length * 0.38, maxf(chord_length * 0.22, 8.0))

	var a0 := start_point
	var a1 := start_point + start_tangent * start_handle_length
	var b2 := end_point - end_tangent * end_handle_length
	# For equal parameter intervals, this center vector makes the second
	# derivatives equal on both sides of the handle (C2 continuity).
	var center_vector := (b2 - a1) * 0.25
	var max_center_handle := minf(minf(first_length, second_length) * 0.32, maxf(chord_length * 0.18, 6.0))
	if center_vector.length() > max_center_handle:
		center_vector = center_vector.normalized() * max_center_handle
	var a2 := control_point - center_vector
	var a3 := control_point
	var b0 := control_point
	var b1 := control_point + center_vector
	var b3 := end_point
	for step in range(21):
		var t := float(step) / 20.0
		var u := 1.0 - t
		var first_point := u * u * u * a0 + 3.0 * u * u * t * a1 + 3.0 * u * t * t * a2 + t * t * t * a3
		points.append(first_point)
	for step in range(1, 21):
		var t := float(step) / 20.0
		var u := 1.0 - t
		var second_point := u * u * u * b0 + 3.0 * u * u * t * b1 + 3.0 * u * t * t * b2 + t * t * t * b3
		points.append(second_point)
	return points

func _add_track_edge(start_station: int, end_station: int, start_point: Vector2, end_point: Vector2, kind: String, parallel_group: int, lane_index: int, lane_count: int, spacing: float) -> void:
	var draw_start := start_point
	var draw_end := end_point
	if kind == "single":
		var merge_data := _build_parallel_merge_transition(start_station, end_station, start_point, end_point)
		if not merge_data.is_empty():
			draw_start = merge_data["draw_start"]
			draw_end = merge_data["draw_end"]
			for path in merge_data["paths"]:
				junction_transition_paths.append(path)
	track_segments.append(draw_start)
	track_segments.append(draw_end)
	track_edges.append({
		"id": next_track_edge_id,
		"start_station": start_station,
		"end_station": end_station,
		"start_point": draw_start,
		"end_point": draw_end,
		"kind": kind,
		"parallel_group": parallel_group,
		"lane_index": lane_index,
		"lane_count": lane_count,
		"centerline_spacing": spacing
	})
	next_track_edge_id += 1

func _build_parallel_merge_transition(start_station: int, end_station: int, start_point: Vector2, end_point: Vector2) -> Dictionary:
	if start_station < 0 or end_station < 0 or start_station >= stations.size() or end_station >= stations.size():
		return {}
	var merge_station := -1
	var outward_direction := Vector2.ZERO
	var toward_end := true
	if _get_parallel_groups_at_station(start_station).size() > 0:
		merge_station = start_station
		outward_direction = (end_point - start_point).normalized()
	elif _get_parallel_groups_at_station(end_station).size() > 0:
		merge_station = end_station
		outward_direction = (start_point - end_point).normalized()
		toward_end = false
	if merge_station == -1 or outward_direction == Vector2.ZERO:
		return {}

	# Only create a merge when the new single track continues in roughly the
	# same direction as an existing parallel pair. A perpendicular or opposing
	# connection is a branch/junction, not a merge, and must remain independent.
	var selected_group := -1
	var best_alignment := 0.72
	for edge in track_edges:
		var group_id := int(edge.get("parallel_group", -1))
		if group_id < 0:
			continue
		var edge_start := int(edge.get("start_station", -1))
		var edge_end := int(edge.get("end_station", -1))
		var neighbor := -1
		if edge_start == merge_station:
			neighbor = edge_end
		elif edge_end == merge_station:
			neighbor = edge_start
		if neighbor < 0 or neighbor >= stations.size():
			continue
		var pair_direction := (stations[neighbor] - stations[merge_station]).normalized()
		var alignment := pair_direction.dot(outward_direction)
		if alignment > best_alignment:
			best_alignment = alignment
			selected_group = group_id
	if selected_group < 0:
		return {}
	var lane_endpoints: Array[Vector2] = []
	for edge in track_edges:
		if int(edge.get("parallel_group", -1)) != selected_group:
			continue
		if int(edge.get("start_station", -1)) == merge_station:
			lane_endpoints.append(edge.get("start_point", stations[merge_station]))
		elif int(edge.get("end_station", -1)) == merge_station:
			lane_endpoints.append(edge.get("end_point", stations[merge_station]))
	if lane_endpoints.size() < 2:
		return {}
	if lane_endpoints.size() > 2:
		lane_endpoints.resize(2)

	var original_merge_point := stations[merge_station]
	var single_length := start_point.distance_to(end_point)
	# Give both lanes enough room to converge gradually while reserving a
	# meaningful straight section after the merge.
	var merge_length := minf(PARALLEL_CENTERLINE_SPACING * 4.0, single_length * 0.58)
	if merge_length < PARALLEL_CENTERLINE_SPACING * 1.25:
		return {}
	var merge_point := original_merge_point + outward_direction * merge_length
	var normal := Vector2(-outward_direction.y, outward_direction.x)
	var paths: Array[PackedVector2Array] = []
	for lane_point in lane_endpoints:
		var lateral_offset := (lane_point - original_merge_point).dot(normal)
		var path := PackedVector2Array()
		# The first control preserves the lane's initial direction. The second
		# retains a small fraction of its lateral offset, then eases to a shared
		# merge point with a tangent aligned to the outgoing single track.
		var first_control := lane_point + outward_direction * (merge_length * 0.38)
		var second_control := merge_point - outward_direction * (merge_length * 0.24) + normal * (lateral_offset * 0.22)
		for step in range(31):
			var t := float(step) / 30.0
			var u := 1.0 - t
			var point := u * u * u * lane_point + 3.0 * u * u * t * first_control + 3.0 * u * t * t * second_control + t * t * t * merge_point
			path.append(point)
		paths.append(path)
	if toward_end:
		return {"draw_start": merge_point, "draw_end": end_point, "paths": paths}
	return {"draw_start": start_point, "draw_end": merge_point, "paths": paths}

func _get_parallel_groups_at_station(station_index: int) -> Array[int]:
	var groups: Array[int] = []
	for edge in track_edges:
		if int(edge.get("parallel_group", -1)) < 0:
			continue
		if int(edge.get("start_station", -1)) == station_index or int(edge.get("end_station", -1)) == station_index:
			var group_id := int(edge.get("parallel_group", -1))
			if not groups.has(group_id):
				groups.append(group_id)
	return groups

func _add_parallel_track_pair(start_station: int, end_station: int) -> void:
	var start_point: Vector2 = stations[start_station]
	var end_point: Vector2 = stations[end_station]
	var direction := (end_point - start_point).normalized()
	if direction == Vector2.ZERO:
		return
	var normal := Vector2(-direction.y, direction.x)
	var half_spacing := PARALLEL_CENTERLINE_SPACING * 0.5
	var group_id := next_track_edge_id
	_add_track_edge(start_station, end_station, start_point + normal * half_spacing, end_point + normal * half_spacing, "parallel", group_id, 0, 2, PARALLEL_CENTERLINE_SPACING)
	_add_track_edge(start_station, end_station, start_point - normal * half_spacing, end_point - normal * half_spacing, "parallel", group_id, 1, 2, PARALLEL_CENTERLINE_SPACING)

func _get_station_track_degree(station_index: int) -> int:
	var degree := 0
	for edge in track_edges:
		if int(edge.get("start_station", -1)) == station_index or int(edge.get("end_station", -1)) == station_index:
			degree += 1
	return degree

func _get_junction_type(station_index: int) -> String:
	var degree := _get_station_track_degree(station_index)
	if degree <= 1:
		return "terminal"
	if degree == 2:
		return "through"
	return "branch"

func _get_station_track_directions(station_index: int) -> Array[Vector2]:
	var directions: Array[Vector2] = []
	if station_index < 0 or station_index >= stations.size():
		return directions
	for edge in track_edges:
		var start_index := int(edge.get("start_station", -1))
		var end_index := int(edge.get("end_station", -1))
		var neighbor_index := -1
		if start_index == station_index:
			neighbor_index = end_index
		elif end_index == station_index:
			neighbor_index = start_index
		if neighbor_index >= 0 and neighbor_index < stations.size():
			var direction := (stations[neighbor_index] - stations[station_index]).normalized()
			if direction != Vector2.ZERO:
				directions.append(direction)
	return directions

func _find_connected_track_tangent(station_point: Vector2, preferred_direction: Vector2, at_curve_end: bool) -> Vector2:
	var best_tangent := Vector2.ZERO
	var best_alignment := -INF
	for edge in track_edges:
		var start_index := int(edge.get("start_station", -1))
		var end_index := int(edge.get("end_station", -1))
		if start_index < 0 or end_index < 0 or start_index >= stations.size() or end_index >= stations.size():
			continue
		if stations[start_index] != station_point and stations[end_index] != station_point:
			continue
		var start_point: Vector2 = edge.get("start_point", stations[start_index])
		var end_point: Vector2 = edge.get("end_point", stations[end_index])
		var tangent := (end_point - start_point).normalized()
		if tangent == Vector2.ZERO:
			continue
		if tangent.dot(preferred_direction) < 0.0:
			tangent = -tangent
		var alignment := tangent.dot(preferred_direction)
		if alignment > best_alignment:
			best_alignment = alignment
			best_tangent = tangent
	if best_alignment < 0.15:
		return Vector2.ZERO
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
	hud.set_mode(build_mode, "TAP TWO STATIONS TO CONNECT ONE TRACK" if build_mode == "track" else "DRAG TO MOVE  ·  PINCH TO ZOOM")

func _select_parallel_mode() -> void:
	build_mode = "" if build_mode == "parallel" else "parallel"
	pending_track_start = -1
	pending_curve_start = -1
	curve_stage = 0
	hud.set_mode(build_mode, "TAP TWO STATIONS TO PLACE STRAIGHT PARALLEL TRACKS" if build_mode == "parallel" else "DRAG TO MOVE  ·  PINCH TO ZOOM")

func _select_parallel_curve_mode() -> void:
	build_mode = "" if build_mode == "parallel_curve" else "parallel_curve"
	pending_track_start = -1
	pending_curve_start = -1
	curve_stage = 0
	hud.set_mode(build_mode, "TAP START  ·  DRAG SHARED CURVE HANDLE  ·  TAP END" if build_mode == "parallel_curve" else "DRAG TO MOVE  ·  PINCH TO ZOOM")

func _draw() -> void:
	for index in range(curve_segments.size()):
		var curve: Dictionary = curve_segments[index]
		var curve_points := _make_curve_points(curve["start"], curve["control"], curve["end"])
		if curve_points.size() > 1:
			draw_polyline(curve_points, Color(0.24, 0.86, 0.78), 7.0, true)
		if build_mode == "curve":
			_draw_completed_curve_handle(curve, index == editing_curve_index)
	for path in junction_transition_paths:
		if path.size() > 1:
			draw_polyline(path, Color(0.24, 0.86, 0.78), 7.0, true)
	for index in range(0, track_segments.size(), 2):
		if index + 1 < track_segments.size():
			draw_line(track_segments[index], track_segments[index + 1], Color(0.24, 0.86, 0.78), 7.0, true)
	if (build_mode == "track" or build_mode == "parallel") and pending_track_start >= 0 and pending_track_start < stations.size():
		_draw_track_preview()
	if build_mode == "curve" and pending_curve_start >= 0 and pending_curve_start < stations.size():
		_draw_curve_preview()
	if build_mode == "parallel_curve" and pending_curve_start >= 0 and pending_curve_start < stations.size():
		_draw_parallel_curve_preview()
	for segment in parallel_curve_segments:
		for path in segment["paths"]:
			if path.size() > 1:
				draw_polyline(path, Color(0.24, 0.86, 0.78), 7.0, true)
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

func _draw_parallel_curve_preview() -> void:
	var start_point: Vector2 = stations[pending_curve_start]
	var end_point := get_snapped_world_position(get_viewport_rect().size * 0.5)
	var control := _constrain_curve_control(start_point, pending_curve_control, end_point)
	var pair := _offset_parallel_curve(_make_curve_points(start_point, control, end_point), PARALLEL_CENTERLINE_SPACING * 0.5)
	for path in pair:
		if path.size() > 1:
			draw_polyline(path, Color(0.42, 1.0, 0.92, 0.92), 4.0 / camera.zoom.x, true)
	draw_line(start_point, control, Color(0.72, 1.0, 0.97, 0.72), 2.0 / camera.zoom.x, true)
	var radius := 19.0 / camera.zoom.x
	draw_circle(control, radius, Color(0.05, 0.16, 0.17, 0.96))
	draw_circle(control, 10.0 / camera.zoom.x, Color(0.55, 1.0, 0.94, 0.95))
	draw_arc(control, 27.0 / camera.zoom.x, 0.0, TAU, 40, Color(0.72, 1.0, 0.97, 1.0), 3.0 / camera.zoom.x, true)

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
	if build_mode == "parallel":
		var direction := (preview_end - preview_start).normalized()
		if direction != Vector2.ZERO:
			var normal := Vector2(-direction.y, direction.x) * (PARALLEL_CENTERLINE_SPACING * 0.5)
			_draw_dashed_preview_line(preview_start + normal, preview_end + normal, viewport_size)
			_draw_dashed_preview_line(preview_start - normal, preview_end - normal, viewport_size)
	else:
		_draw_dashed_preview_line(preview_start, preview_end, viewport_size)
	draw_circle(preview_end, 9.0, Color(0.35, 0.95, 0.88, 0.16))
	draw_arc(preview_end, 13.0, 0.0, TAU, 32, Color(0.72, 1.0, 0.97, 1.0), 2.5, true)

func _draw_dashed_preview_line(world_start: Vector2, world_end: Vector2, viewport_size: Vector2) -> void:
	var canvas_transform := get_viewport().get_canvas_transform()
	var inverse_transform := canvas_transform.affine_inverse()
	var clipped := _clip_preview_segment(canvas_transform * world_start, canvas_transform * world_end, Rect2(Vector2.ZERO, viewport_size))
	if clipped.size() != 2:
		return
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
