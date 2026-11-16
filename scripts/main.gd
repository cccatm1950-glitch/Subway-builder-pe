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
var waypoint_paths: Array[PackedVector2Array] = []
var pending_waypoints: Array[Vector2] = []
var waypoint_markers: Array[Vector2] = []
var pending_waypoint_start_node := -1
var pending_curve_start_node := -1
var pending_curve_start_position := Vector2.ZERO
# Topology records keep station connectivity and future parallel-lane metadata
# separate from the legacy endpoint array used by current drawing code.
var track_edges: Array[Dictionary] = []
# Each centerline endpoint has an explicit lane node; shared nodes represent true continuity.
var lane_nodes: Array[Dictionary] = []
var next_lane_node_id := 1
var junction_transition_paths: Array[PackedVector2Array] = []
var next_track_edge_id := 1
var curve_segments: Array[Dictionary] = []
var parallel_curve_segments: Array[Dictionary] = []
var pending_track_start := -1
var pending_track_start_node := -1
var pending_track_start_position := Vector2.ZERO
var pending_curve_start := -1
var pending_curve_control := Vector2.ZERO
var curve_stage := 0
var mouse_pointer_down := false
var mouse_pointer_start := Vector2.ZERO
var mouse_pointer_dragged := false
var curve_handle_dragging := false
var curve_handle_touch_index := -1
var editing_curve_index := -1
var editing_parallel_curve_index := -1

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
	hud.waypoint_mode_requested.connect(_select_waypoint_mode)
	_update_coordinate_readout()
	hud.set_input_status("INPUT READY")

func _process(_delta: float) -> void:
	# Android fallback: poll active touch coordinates every frame. Some device/
	# Godot combinations deliver touch-down but omit or coalesce ScreenDrag events.
	if active_touches.is_empty():
		return
	var live_positions: Dictionary = {}
	for touch_id in active_touches.keys():
		var current_position := Input.get_touch_position(int(touch_id))
		live_positions[touch_id] = current_position
		var previous_position: Vector2 = active_touches[touch_id]
		var start_position: Vector2 = touch_starts.get(touch_id, previous_position)
		if current_position.distance_to(start_position) > TAP_DRAG_THRESHOLD:
			touch_moved[touch_id] = true
		if active_touches.size() == 1 and not curve_handle_dragging:
			var delta := current_position - previous_position
			if delta.length_squared() > 0.0:
				_pan_camera(delta)
	for touch_id in live_positions:
		active_touches[touch_id] = live_positions[touch_id]
	if active_touches.size() >= 2:
		_update_pinch_zoom()

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
			editing_parallel_curve_index = -1
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
	# Use the change from the previous stored touch position rather than
	# InputEventScreenDrag.relative, which can be zero on some Android devices.
	var previous_position: Vector2 = active_touches[event.index]
	var drag_delta := event.position - previous_position
	active_touches[event.index] = event.position
	var start: Vector2 = touch_starts.get(event.index, event.position)
	if event.position.distance_to(start) > TAP_DRAG_THRESHOLD:
		touch_moved[event.index] = true
	# Camera movement is polled in _process from Input touch positions so
	# missed/coalesced Android ScreenDrag events cannot freeze the map.
	if active_touches.size() == 1:
		hud.set_input_status("MAP DRAG")
	elif active_touches.size() >= 2:
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
				editing_parallel_curve_index = -1
				hud.set_mode(build_mode, "BEND SET  ·  DRAG AGAIN OR TAP AN END STATION")
				queue_redraw()
				return
			if mouse_pointer_down and not mouse_pointer_dragged and not hud.is_ui_position(event.position):
				_handle_map_tap(event.position)
				hud.set_input_status("POINTER TAP")
			elif mouse_pointer_dragged:
				hud.set_input_status("POINTER DRAG END")
			mouse_pointer_down = false

func _handle_map_tap(_screen_position: Vector2) -> void:
	# Construction taps are routed to the fixed screen-center crosshair.
	# Finger position never relocates the target; map drags remain camera pans.
	var crosshair_screen := get_viewport_rect().size * 0.5
	if build_mode == "curve":
		_handle_curve_tap(crosshair_screen)
	elif build_mode == "parallel_curve":
		_handle_parallel_curve_tap(crosshair_screen)
	elif build_mode == "waypoint":
		_handle_waypoint_tap(crosshair_screen)
	elif build_mode == "station":
		var station_position := get_snapped_world_position(crosshair_screen)
		if not stations.has(station_position):
			stations.append(station_position)
			queue_redraw()
		_update_coordinate_readout()
	elif build_mode == "track" or build_mode == "parallel":
		var lane_node_id := _find_lane_node_near_screen(crosshair_screen) if build_mode == "track" else -1
		if build_mode == "track" and lane_node_id < 0:
			lane_node_id = _find_waypoint_node_near_screen(crosshair_screen)
		var station_index := -1
		var target_position := get_snapped_world_position(crosshair_screen)
		if lane_node_id >= 0:
			var lane_node := _get_lane_node(lane_node_id)
			station_index = int(lane_node.get("station_index", -1))
			target_position = Vector2(lane_node.get("position", target_position))
		else:
			station_index = _find_station_near_screen(crosshair_screen)
			if station_index >= 0:
				target_position = stations[station_index]
				if build_mode == "track":
					lane_node_id = _get_or_create_lane_node(target_position, station_index, 0, -1)
		if station_index == -1 and lane_node_id < 0:
			hud.set_mode(build_mode, "ALIGN CROSSHAIR WITH A STATION, LANE NODE OR WAYPOINT")
			return
		if pending_track_start_node < 0:
			pending_track_start = station_index
			pending_track_start_node = lane_node_id
			pending_track_start_position = target_position
			hud.set_mode(build_mode, "START SELECTED  ·  ALIGN CROSSHAIR WITH ANOTHER NODE")
		elif lane_node_id >= 0 and lane_node_id == pending_track_start_node:
			hud.set_mode(build_mode, "SAME NODE  ·  CHOOSE A DIFFERENT CONNECTION")
		else:
			var start_station := pending_track_start
			var start_position := _get_lane_node_position(pending_track_start_node, pending_track_start_position)
			if build_mode == "parallel":
				_add_parallel_track_pair(start_station, station_index)
			else:
				_add_track_edge(start_station, station_index, start_position, target_position, "single", -1, 0, 1, 0.0)
			pending_track_start = -1
			pending_track_start_node = -1
			queue_redraw()
			hud.set_mode(build_mode, "TRACKS CONNECTED  ·  SELECT ANOTHER START" if build_mode == "parallel" else "TRACK CONNECTED  ·  SELECT ANOTHER START")

func _handle_waypoint_tap(screen_position: Vector2) -> void:
	# WAYPOINT is a free placement tool, like STATION. Markers are persistent
	# planning anchors and do not create a route preview while being placed.
	var waypoint_position := get_snapped_world_position(screen_position)
	for existing in waypoint_markers:
		if existing.distance_to(waypoint_position) < SNAP_SPACING:
			hud.set_mode(build_mode, "WAYPOINT ALREADY PLACED NEARBY")
			return
	waypoint_markers.append(waypoint_position)
	queue_redraw()
	_update_coordinate_readout()
	hud.set_mode(build_mode, "WAYPOINT PLACED  ·  PLACE ANOTHER OR SELECT A ROUTING TOOL")

func _make_waypoint_route(route_points: Array[Vector2]) -> PackedVector2Array:
	var result := PackedVector2Array()
	var point_count := route_points.size()
	if point_count < 2:
		return result
	if point_count == 2:
		result.append(route_points[0])
		result.append(route_points[1])
		return result

	# A chord-length-parameterized natural cubic spline passes through every
	# placed waypoint and has matching first and second derivatives at joins.
	# The anchors themselves are never moved or replaced.
	var intervals: Array[float] = []
	for index in range(point_count - 1):
		var distance := route_points[index].distance_to(route_points[index + 1])
		if distance < 0.001:
			return PackedVector2Array()
		intervals.append(distance)

	var lower: Array[float] = []
	var diagonal: Array[float] = []
	var upper: Array[float] = []
	var rhs: Array[Vector2] = []
	for index in range(point_count):
		lower.append(0.0)
		diagonal.append(1.0)
		upper.append(0.0)
		rhs.append(Vector2.ZERO)

	for index in range(1, point_count - 1):
		var previous_h: float = intervals[index - 1]
		var next_h: float = intervals[index]
		lower[index] = previous_h
		diagonal[index] = 2.0 * (previous_h + next_h)
		upper[index] = next_h
		rhs[index] = 6.0 * (
			(route_points[index + 1] - route_points[index]) / next_h
			- (route_points[index] - route_points[index - 1]) / previous_h
		)

	# Thomas algorithm for the tridiagonal system of vector second derivatives.
	var c_prime: Array[float] = []
	var d_prime: Array[Vector2] = []
	for index in range(point_count):
		var denominator := diagonal[index]
		if index > 0:
			denominator -= lower[index] * c_prime[index - 1]
		var c_value := upper[index] / denominator if index < point_count - 1 else 0.0
		var d_value := (rhs[index] - lower[index] * d_prime[index - 1]) / denominator if index > 0 else rhs[index] / denominator
		c_prime.append(c_value)
		d_prime.append(d_value)

	var second_derivatives: Array[Vector2] = []
	for index in range(point_count):
		second_derivatives.append(Vector2.ZERO)
	second_derivatives[point_count - 1] = d_prime[point_count - 1]
	for index in range(point_count - 2, -1, -1):
		second_derivatives[index] = d_prime[index] - c_prime[index] * second_derivatives[index + 1]

	for segment in range(point_count - 1):
		var h: float = intervals[segment]
		for step in range(17):
			if segment > 0 and step == 0:
				continue
			var t := float(step) / 16.0
			var a := 1.0 - t
			var b := t
			var point := a * route_points[segment] + b * route_points[segment + 1]
			point += ((a * a * a - a) * second_derivatives[segment] + (b * b * b - b) * second_derivatives[segment + 1]) * (h * h / 6.0)
			result.append(point)
	return result

func _draw_waypoint_preview() -> void:
	if pending_curve_start < 0 or pending_curve_start >= stations.size():
		return
	var preview_points: Array[Vector2] = [stations[pending_curve_start]]
	preview_points.append_array(pending_waypoints)
	preview_points.append(get_snapped_world_position(get_viewport_rect().size * 0.5))
	var preview := _make_waypoint_route(preview_points)
	if preview.size() > 1:
		for index in range(preview.size() - 1):
			if index % 2 == 0:
				draw_line(preview[index], preview[index + 1], Color(0.42, 1.0, 0.92, 0.72), 3.0 / camera.zoom.x, true)
	for point in pending_waypoints:
		draw_circle(point, 8.0 / camera.zoom.x, Color(0.08, 0.24, 0.25, 1.0))
		draw_arc(point, 13.0 / camera.zoom.x, 0.0, TAU, 24, Color(0.65, 1.0, 0.95, 1.0), 2.0 / camera.zoom.x, true)

func _handle_curve_tap(screen_position: Vector2) -> void:
	var lane_node_id := _find_lane_node_near_screen(screen_position)
	if lane_node_id < 0:
		lane_node_id = _find_waypoint_node_near_screen(screen_position)
	var station_index := -1
	var endpoint := get_snapped_world_position(screen_position)
	if lane_node_id >= 0:
		var node := _get_lane_node(lane_node_id)
		station_index = int(node.get("station_index", -1))
		endpoint = Vector2(node.get("position", endpoint))
	else:
		station_index = _find_station_near_screen(screen_position)
		if station_index >= 0:
			endpoint = stations[station_index]
	if curve_stage == 0:
		if station_index < 0 and lane_node_id < 0:
			hud.set_mode(build_mode, "SELECT A START STATION, LANE NODE OR WAYPOINT")
			return
		pending_curve_start = station_index
		pending_curve_start_node = lane_node_id
		pending_curve_start_position = endpoint
		curve_stage = 1
		var start_screen: Vector2 = get_viewport().get_canvas_transform() * endpoint
		var center := get_viewport_rect().size * 0.5
		var direction := (center - start_screen).normalized()
		if direction.length_squared() < 0.01:
			direction = Vector2.RIGHT
		var normal := Vector2(-direction.y, direction.x)
		pending_curve_control = screen_to_world(start_screen + direction * 90.0 + normal * 55.0)
		hud.set_mode(build_mode, "DRAG THE CURVE HANDLE  ·  TAP END NODE")
		queue_redraw()
		return
	if (station_index < 0 and lane_node_id < 0) or (lane_node_id >= 0 and lane_node_id == pending_curve_start_node):
		hud.set_mode(build_mode, "TAP A DIFFERENT END STATION OR LANE NODE")
		return
	var curve_start := _get_lane_node_position(pending_curve_start_node, pending_curve_start_position)
	var curve_end := endpoint
	var curve_control := _constrain_curve_control(curve_start, pending_curve_control, curve_end)
	var start_node := pending_curve_start_node
	if start_node < 0:
		start_node = _get_or_create_lane_node(curve_start, pending_curve_start, 0, -1)
	var end_node := lane_node_id
	if end_node < 0:
		end_node = _get_or_create_lane_node(curve_end, station_index, 0, -1)
	curve_segments.append({"start": curve_start, "control": curve_control, "end": curve_end, "start_node": start_node, "end_node": end_node, "start_station": pending_curve_start, "end_station": station_index})
	track_edges.append({"id": next_track_edge_id, "start_node": start_node, "end_node": end_node, "start_station": pending_curve_start, "end_station": station_index, "start_point": curve_start, "end_point": curve_end, "kind": "curve", "parallel_group": -1, "lane_index": 0, "lane_count": 1, "centerline_spacing": 0.0})
	_register_lane_edge(next_track_edge_id, start_node, end_node)
	next_track_edge_id += 1
	pending_curve_start = -1
	pending_curve_start_node = -1
	curve_stage = 0
	queue_redraw()
	hud.set_mode(build_mode, "CURVE CONNECTED  ·  SELECT ANOTHER START")

func _handle_parallel_curve_tap(screen_position: Vector2) -> void:
	var lane_node_id := _find_lane_node_near_screen(screen_position)
	if lane_node_id < 0:
		lane_node_id = _find_waypoint_node_near_screen(screen_position)
	var station_index := -1
	var endpoint := get_snapped_world_position(screen_position)
	if lane_node_id >= 0:
		var node := _get_lane_node(lane_node_id)
		station_index = int(node.get("station_index", -1))
		endpoint = Vector2(node.get("position", endpoint))
	else:
		station_index = _find_station_near_screen(screen_position)
		if station_index >= 0:
			endpoint = stations[station_index]
	if curve_stage == 0:
		if station_index < 0 and lane_node_id < 0:
			hud.set_mode(build_mode, "SELECT A START STATION, LANE NODE OR WAYPOINT")
			return
		pending_curve_start = station_index
		pending_curve_start_node = lane_node_id
		pending_curve_start_position = endpoint
		curve_stage = 1
		var start_screen: Vector2 = get_viewport().get_canvas_transform() * endpoint
		var center := get_viewport_rect().size * 0.5
		var direction := (center - start_screen).normalized()
		if direction.length_squared() < 0.01:
			direction = Vector2.RIGHT
		var normal := Vector2(-direction.y, direction.x)
		pending_curve_control = screen_to_world(start_screen + direction * 90.0 + normal * 55.0)
		hud.set_mode(build_mode, "DRAG SHARED HANDLE  ·  TAP END NODE")
		queue_redraw()
		return
	if (station_index < 0 and lane_node_id < 0) or (lane_node_id >= 0 and lane_node_id == pending_curve_start_node):
		hud.set_mode(build_mode, "TAP A DIFFERENT END STATION OR LANE NODE")
		return
	var curve_start := _get_lane_node_position(pending_curve_start_node, pending_curve_start_position)
	var curve_end := endpoint
	var control := _constrain_curve_control(curve_start, pending_curve_control, curve_end)
	var pair := _offset_parallel_curve(_make_curve_points(curve_start, control, curve_end), PARALLEL_CENTERLINE_SPACING * 0.5)
	if pair.size() != 2 or pair[0].size() < 2 or pair[1].size() < 2:
		hud.set_mode(build_mode, "COULD NOT CREATE PARALLEL CURVE")
		return
	var group_id := next_track_edge_id
	parallel_curve_segments.append({"paths": pair, "start_station": pending_curve_start, "end_station": station_index, "start_point": curve_start, "end_point": curve_end, "start_node": pending_curve_start_node, "end_node": lane_node_id, "control": control, "group_id": group_id})
	var start_junction_node := pending_curve_start_node
	if start_junction_node < 0:
		start_junction_node = _get_or_create_lane_node(curve_start, pending_curve_start, 0, -1)
	var end_junction_node := lane_node_id
	if end_junction_node < 0:
		end_junction_node = _get_or_create_lane_node(curve_end, station_index, 0, -1)
	for lane in range(2):
		var path: PackedVector2Array = pair[lane]
		var start_node := _get_or_create_lane_node(path[0], pending_curve_start, lane, group_id)
		var end_node := _get_or_create_lane_node(path[path.size() - 1], station_index, lane, group_id)
		track_edges.append({"id": next_track_edge_id, "start_node": start_node, "end_node": end_node, "start_station": pending_curve_start, "end_station": station_index, "start_point": path[0], "end_point": path[path.size() - 1], "kind": "parallel_curve", "parallel_group": group_id, "lane_index": lane, "lane_count": 2, "centerline_spacing": PARALLEL_CENTERLINE_SPACING})
		_register_lane_edge(next_track_edge_id, start_node, end_node)
		next_track_edge_id += 1

		# Blend both ends of each offset lane into the selected centerline nodes.
		var start_path_tangent := (path[1] - path[0]).normalized()
		var start_outgoing := _find_connected_track_tangent(curve_start, start_path_tangent, false)
		if start_outgoing == Vector2.ZERO:
			start_outgoing = (path[0] - curve_start).normalized()
		var start_transition := _make_junction_transition(curve_start, path[0], start_outgoing, start_path_tangent)
		if start_transition.size() > 1:
			junction_transition_paths.append(start_transition)
			track_edges.append({"id": next_track_edge_id, "start_node": start_junction_node, "end_node": start_node, "start_station": pending_curve_start, "end_station": pending_curve_start, "start_point": curve_start, "end_point": path[0], "kind": "transition", "parallel_group": -1, "lane_index": lane, "lane_count": 1, "centerline_spacing": 0.0})
			_register_lane_edge(next_track_edge_id, start_junction_node, start_node)
			next_track_edge_id += 1

		var end_path_tangent := (path[path.size() - 1] - path[path.size() - 2]).normalized()
		var end_incoming := _find_connected_track_tangent(curve_end, end_path_tangent, true)
		if end_incoming == Vector2.ZERO:
			end_incoming = (curve_end - path[path.size() - 1]).normalized()
		var end_transition := _make_junction_transition(path[path.size() - 1], curve_end, end_path_tangent, end_incoming)
		if end_transition.size() > 1:
			junction_transition_paths.append(end_transition)
			track_edges.append({"id": next_track_edge_id, "start_node": end_node, "end_node": end_junction_node, "start_station": station_index, "end_station": station_index, "start_point": path[path.size() - 1], "end_point": curve_end, "kind": "transition", "parallel_group": -1, "lane_index": lane, "lane_count": 1, "centerline_spacing": 0.0})
			_register_lane_edge(next_track_edge_id, end_node, end_junction_node)
			next_track_edge_id += 1
	pending_curve_start = -1
	pending_curve_start_node = -1
	curve_stage = 0
	queue_redraw()
	hud.set_mode(build_mode, "PARALLEL CURVE CONNECTED  ·  SELECT ANOTHER START")

func _make_junction_transition(start_point: Vector2, end_point: Vector2, start_tangent: Vector2, end_tangent: Vector2) -> PackedVector2Array:
	var result := PackedVector2Array()
	var distance := start_point.distance_to(end_point)
	if distance < 0.5:
		return result
	var chord := (end_point - start_point).normalized()
	var outgoing := start_tangent.normalized() if start_tangent.length_squared() > 0.001 else chord
	var incoming := end_tangent.normalized() if end_tangent.length_squared() > 0.001 else chord
	var handle_length := minf(distance * 0.42, maxf(distance * 0.22, 8.0))
	var control_a := start_point + outgoing * handle_length
	var control_b := end_point - incoming * handle_length
	for step in range(25):
		var t := float(step) / 24.0
		var u := 1.0 - t
		result.append(u * u * u * start_point + 3.0 * u * u * t * control_a + 3.0 * u * t * t * control_b + t * t * t * end_point)
	return result

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
		return curve_handle_touch_index == touch_index
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
	if build_mode == "parallel_curve":
		for index in range(parallel_curve_segments.size() - 1, -1, -1):
			var parallel_curve: Dictionary = parallel_curve_segments[index]
			var parallel_screen: Vector2 = transform * parallel_curve["control"]
			if parallel_screen.distance_to(screen_position) <= 48.0:
				editing_parallel_curve_index = index
				editing_curve_index = -1
				curve_handle_dragging = true
				curve_handle_touch_index = touch_index
				hud.set_input_status("EDITING PLACED PARALLEL CURVE")
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
	if editing_parallel_curve_index >= 0 and editing_parallel_curve_index < parallel_curve_segments.size():
		var parallel_curve: Dictionary = parallel_curve_segments[editing_parallel_curve_index]
		var start_point: Vector2 = parallel_curve.get("start_point", stations[int(parallel_curve["start_station"])])
		var end_point: Vector2 = parallel_curve.get("end_point", stations[int(parallel_curve["end_station"])])
		var control := _constrain_curve_control(start_point, new_control, end_point)
		var pair := _offset_parallel_curve(_make_curve_points(start_point, control, end_point), PARALLEL_CENTERLINE_SPACING * 0.5)
		if pair.size() == 2 and pair[0].size() > 1 and pair[1].size() > 1:
			parallel_curve["control"] = control
			parallel_curve["paths"] = pair
			var group_id := int(parallel_curve["group_id"])
			for edge_index in range(track_edges.size()):
				if int(track_edges[edge_index].get("parallel_group", -1)) == group_id:
					var lane_index := int(track_edges[edge_index].get("lane_index", 0))
					var start_position: Vector2 = pair[lane_index][0]
					var end_position: Vector2 = pair[lane_index][pair[lane_index].size() - 1]
					track_edges[edge_index]["start_point"] = start_position
					track_edges[edge_index]["end_point"] = end_position
					_set_lane_node_position(int(track_edges[edge_index].get("start_node", -1)), start_position)
					_set_lane_node_position(int(track_edges[edge_index].get("end_node", -1)), end_position)
	elif editing_curve_index >= 0 and editing_curve_index < curve_segments.size():
		var curve: Dictionary = curve_segments[editing_curve_index]
		curve["control"] = _constrain_curve_control(curve["start"], new_control, curve["end"])
	else:
		if pending_curve_start >= 0 and pending_curve_start < stations.size():
			var start_fallback: Vector2 = stations[pending_curve_start]
			var start_point := _get_lane_node_position(pending_curve_start_node, start_fallback)
			var preview_end := _get_curve_preview_endpoint()
			pending_curve_control = _constrain_curve_control(start_point, new_control, preview_end)
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

func _get_or_create_lane_node(position: Vector2, station_index: int, lane_index: int, parallel_group: int) -> int:
	# Node identity belongs to a centerline position, not the station marker.
	# This deliberately keeps the two offset lanes as separate endpoints.
	for node in lane_nodes:
		if int(node.get("station_index", -1)) == station_index and Vector2(node.get("position", Vector2.ZERO)).distance_to(position) <= 0.5:
			return int(node["id"])
	var node_id := next_lane_node_id
	next_lane_node_id += 1
	lane_nodes.append({
		"id": node_id,
		"position": position,
		"station_index": station_index,
		"lane_index": lane_index,
		"parallel_group": parallel_group
	})
	return node_id

func _set_lane_node_position(node_id: int, position: Vector2) -> void:
	for index in range(lane_nodes.size()):
		if int(lane_nodes[index].get("id", -1)) == node_id:
			lane_nodes[index]["position"] = position
			return

func _register_lane_edge(edge_id: int, start_node: int, end_node: int) -> void:
	for index in range(lane_nodes.size()):
		var node_id := int(lane_nodes[index].get("id", -1))
		if node_id == start_node or node_id == end_node:
			var incident_edges: Array = lane_nodes[index].get("edge_ids", [])
			if not incident_edges.has(edge_id):
				incident_edges.append(edge_id)
			lane_nodes[index]["edge_ids"] = incident_edges


func _add_track_edge(start_station: int, end_station: int, start_point: Vector2, end_point: Vector2, kind: String, parallel_group: int, lane_index: int, lane_count: int, spacing: float) -> void:
	var draw_start := start_point
	var draw_end := end_point
	# Explicit lane-node connections already identify their exact centerline
	# endpoints. Do not let the legacy station-level merge heuristic move them.
	if kind == "single" and start_station >= 0 and end_station >= 0 and start_point.distance_to(stations[start_station]) <= 0.5 and end_point.distance_to(stations[end_station]) <= 0.5:
		var merge_data := _build_parallel_merge_transition(start_station, end_station, start_point, end_point)
		if not merge_data.is_empty():
			draw_start = merge_data["draw_start"]
			draw_end = merge_data["draw_end"]
			for path in merge_data["paths"]:
				junction_transition_paths.append(path)
	track_segments.append(draw_start)
	track_segments.append(draw_end)
	var start_node := _get_or_create_lane_node(draw_start, start_station, lane_index, parallel_group)
	var end_node := _get_or_create_lane_node(draw_end, end_station, lane_index, parallel_group)
	track_edges.append({
		"id": next_track_edge_id,
		"start_node": start_node,
		"end_node": end_node,
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
	_register_lane_edge(next_track_edge_id, start_node, end_node)
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
	var best_alignment := -1.0
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
	# Resolve lanes in their explicit lane_index order. Never rely on the
	# incidental order in which track_edges were appended; that can swap the
	# inner and outer lane when a pair is connected in the reverse direction.
	var lane_endpoints: Array[Vector2] = []
	var ordered_lanes := _get_parallel_group_lanes(selected_group)
	for edge in ordered_lanes:
		if int(edge.get("start_station", -1)) == merge_station:
			lane_endpoints.append(edge.get("start_point", stations[merge_station]))
		elif int(edge.get("end_station", -1)) == merge_station:
			lane_endpoints.append(edge.get("end_point", stations[merge_station]))
	if lane_endpoints.size() != 2:
		return {}

	var original_merge_point := stations[merge_station]
	var single_length := start_point.distance_to(end_point)
	var merge_length := minf(PARALLEL_CENTERLINE_SPACING * 3.5, single_length * 0.42)
	if merge_length < PARALLEL_CENTERLINE_SPACING * 0.9:
		return {}
	var merge_point := original_merge_point + outward_direction * merge_length
	var normal := Vector2(-outward_direction.y, outward_direction.x)
	var paths: Array[PackedVector2Array] = []

	if best_alignment < 0.72:
		# Diverging connection: preserve the unselected parallel lane and
		# create one turnout from the lane on the side of the outgoing route.
		var neighbor_direction := Vector2.ZERO
		for edge in track_edges:
			if int(edge.get("parallel_group", -1)) != selected_group:
				continue
			var edge_start := int(edge.get("start_station", -1))
			var edge_end := int(edge.get("end_station", -1))
			var neighbor := edge_end if edge_start == merge_station else edge_start
			if neighbor >= 0 and neighbor < stations.size():
				neighbor_direction = (stations[merge_station] - stations[neighbor]).normalized()
				break
		if neighbor_direction == Vector2.ZERO:
			return {}
		var parallel_normal := Vector2(-neighbor_direction.y, neighbor_direction.x)
		var branch_side := outward_direction.dot(parallel_normal)
		var selected_lane := 0
		var selected_offset := (lane_endpoints[0] - original_merge_point).dot(parallel_normal)
		for lane_index in range(1, lane_endpoints.size()):
			var lane_offset := (lane_endpoints[lane_index] - original_merge_point).dot(parallel_normal)
			if (branch_side >= 0.0 and lane_offset > selected_offset) or (branch_side < 0.0 and lane_offset < selected_offset):
				selected_lane = lane_index
				selected_offset = lane_offset
		var lane_point: Vector2 = lane_endpoints[selected_lane]
		var switch_length := minf(merge_length, lane_point.distance_to(merge_point) + merge_length * 0.35)
		var switch_end := merge_point
		var first_control := lane_point + neighbor_direction * (switch_length * 0.34)
		var second_control := switch_end - outward_direction * (switch_length * 0.34)
		var turnout := PackedVector2Array()
		for step in range(41):
			var t := float(step) / 40.0
			var u := 1.0 - t
			turnout.append(u * u * u * lane_point + 3.0 * u * u * t * first_control + 3.0 * u * t * t * second_control + t * t * t * switch_end)
		paths.append(turnout)
	else:
		# True parallel-to-single merge: keep one existing lane as the
		# through route and bring only the other lane into it. Never create a
		# new single centerline between the two parallel tracks.
		var through_lane := 0
		var merge_lane := 1
		var through_point: Vector2 = lane_endpoints[through_lane]
		var merging_point: Vector2 = lane_endpoints[merge_lane]
		# Continue the retained lane forward; convergence happens beyond
		# the station, not back at the station marker itself.
		merge_point = through_point + outward_direction * merge_length
		var first_control := merging_point + outward_direction * (merge_length * 0.38)
		var second_control := merge_point - outward_direction * (merge_length * 0.24)
		var merge_path := PackedVector2Array()
		for step in range(41):
			var t := float(step) / 40.0
			var u := 1.0 - t
			merge_path.append(u * u * u * merging_point + 3.0 * u * u * t * first_control + 3.0 * u * t * t * second_control + t * t * t * merge_point)
		paths.append(merge_path)
	if toward_end:
		return {"draw_start": merge_point, "draw_end": end_point, "paths": paths}
	return {"draw_start": start_point, "draw_end": merge_point, "paths": paths}

func _add_parallel_track_pair(start_station: int, end_station: int) -> void:
	var start_point: Vector2 = stations[start_station]
	var end_point: Vector2 = stations[end_station]
	var direction := (end_point - start_point).normalized()
	if direction == Vector2.ZERO:
		return
	var normal := Vector2(-direction.y, direction.x)
	var half_spacing := PARALLEL_CENTERLINE_SPACING * 0.5
	var group_id := next_track_edge_id
	var lane_a_start := start_point + normal * half_spacing
	var lane_a_end := end_point + normal * half_spacing
	var lane_b_start := start_point - normal * half_spacing
	var lane_b_end := end_point - normal * half_spacing
	# Each lane terminates at its own offset point, while short station
	# connectors make both approaches visibly meet the shared station node.
	junction_transition_paths.append(PackedVector2Array([start_point, lane_a_start]))
	junction_transition_paths.append(PackedVector2Array([start_point, lane_b_start]))
	junction_transition_paths.append(PackedVector2Array([end_point, lane_a_end]))
	junction_transition_paths.append(PackedVector2Array([end_point, lane_b_end]))
	_add_track_edge(start_station, end_station, lane_a_start, lane_a_end, "parallel", group_id, 0, 2, PARALLEL_CENTERLINE_SPACING)
	_add_track_edge(start_station, end_station, lane_b_start, lane_b_end, "parallel", group_id, 1, 2, PARALLEL_CENTERLINE_SPACING)

func _get_station_track_degree(station_index: int) -> int:
	# A two-lane parallel pair is one physical connection at a station.
	# Count each parallel group once, while keeping individual single lanes
	# and waypoint routes as independent connections.
	var degree := 0
	var counted_parallel_groups: Dictionary = {}
	for edge in track_edges:
		if int(edge.get("start_station", -1)) != station_index and int(edge.get("end_station", -1)) != station_index:
			continue
		var parallel_group := int(edge.get("parallel_group", -1))
		if parallel_group >= 0:
			if counted_parallel_groups.has(parallel_group):
				continue
			counted_parallel_groups[parallel_group] = true
		degree += 1
	return degree


func _get_parallel_groups_at_station(station_index: int) -> Array[int]:
	var groups: Array[int] = []
	for edge in track_edges:
		if int(edge.get("parallel_group", -1)) < 0:
			continue
		if int(edge.get("start_station", -1)) != station_index and int(edge.get("end_station", -1)) != station_index:
			continue
		var group_id := int(edge.get("parallel_group", -1))
		if not groups.has(group_id):
			groups.append(group_id)
	return groups


func _get_parallel_group_lanes(group_id: int) -> Array[Dictionary]:
	var lanes: Array[Dictionary] = []
	for edge in track_edges:
		if int(edge.get("parallel_group", -1)) == group_id:
			lanes.append(edge)
	lanes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("lane_index", 0)) < int(b.get("lane_index", 0))
	)
	return lanes

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

func _find_connected_track_tangent(endpoint_position: Vector2, preferred_direction: Vector2, at_curve_end: bool) -> Vector2:
	# Resolve the exact lane node first. Station-center matching breaks as soon
	# as a curve is attached to an offset lane centerline.
	var endpoint_node := -1
	var closest_distance := 1.0
	for node in lane_nodes:
		var distance: float = Vector2(node.get("position", Vector2.ZERO)).distance_to(endpoint_position)
		if distance <= closest_distance:
			closest_distance = distance
			endpoint_node = int(node.get("id", -1))
	if endpoint_node < 0:
		return Vector2.ZERO

	var best_tangent := Vector2.ZERO
	var best_alignment := -INF
	for edge in track_edges:
		var is_start := int(edge.get("start_node", -1)) == endpoint_node
		var is_end := int(edge.get("end_node", -1)) == endpoint_node
		if not is_start and not is_end:
			continue
		var start_point: Vector2 = edge.get("start_point", endpoint_position)
		var end_point: Vector2 = edge.get("end_point", endpoint_position)
		var tangent := (end_point - start_point).normalized()
		# Offset curve edges have a sampled path; use its endpoint segment
		# instead of the long endpoint chord to preserve the true local heading.
		var group_id := int(edge.get("parallel_group", -1))
		if group_id >= 0:
			var lane_index := int(edge.get("lane_index", 0))
			for segment in parallel_curve_segments:
				if int(segment.get("group_id", -1)) != group_id:
					continue
				var paths: Array = segment.get("paths", [])
				if lane_index >= 0 and lane_index < paths.size():
					var path: PackedVector2Array = paths[lane_index]
					if path.size() >= 2:
						tangent = (path[1] - path[0]).normalized() if is_start else (path[path.size() - 2] - path[path.size() - 1]).normalized()
				break
		if tangent == Vector2.ZERO:
			continue
		# Orient the tangent away from the junction node. A curve's end
		# tangent points toward its endpoint, so reverse it for comparison.
		if not is_start:
			tangent = -tangent
		if at_curve_end:
			tangent = -tangent
		var alignment := tangent.dot(preferred_direction.normalized())
		if alignment > best_alignment:
			best_alignment = alignment
			best_tangent = tangent
	if best_alignment < 0.15:
		return Vector2.ZERO
	return best_tangent

func _select_waypoint_mode() -> void:
	build_mode = "" if build_mode == "waypoint" else "waypoint"
	pending_track_start = -1
	pending_curve_start = -1
	pending_waypoints.clear()
	pending_waypoint_start_node = -1
	curve_stage = 0
	hud.set_mode(build_mode, "TAP MAP TO PLACE WAYPOINT MARKERS  ·  NO PREVIEW" if build_mode == "waypoint" else "DRAG TO MOVE  ·  PINCH TO ZOOM")
	queue_redraw()


func _select_curve_mode() -> void:
	build_mode = "" if build_mode == "curve" else "curve"
	curve_handle_dragging = false
	curve_handle_touch_index = -1
	editing_curve_index = -1
	pending_track_start = -1
	pending_curve_start = -1
	pending_curve_start_node = -1
	curve_stage = 0
	hud.set_mode(build_mode, "SELECT START STATION" if build_mode == "curve" else "DRAG TO MOVE  ·  PINCH TO ZOOM")
	queue_redraw()

func _find_lane_node_near_screen(screen_position: Vector2) -> int:
	var nearest_id := -1
	var nearest_distance := STATION_PICK_RADIUS * 0.55
	var canvas_transform := get_viewport().get_canvas_transform()
	for node in lane_nodes:
		var node_screen: Vector2 = canvas_transform * Vector2(node.get("position", Vector2.ZERO))
		var distance := node_screen.distance_to(screen_position)
		if distance <= nearest_distance:
			nearest_distance = distance
			nearest_id = int(node.get("id", -1))
	return nearest_id

func _get_lane_node(node_id: int) -> Dictionary:
	for node in lane_nodes:
		if int(node.get("id", -1)) == node_id:
			return node
	return {}

func _get_lane_node_position(node_id: int, fallback: Vector2) -> Vector2:
	var node := _get_lane_node(node_id)
	return Vector2(node.get("position", fallback))

func _find_waypoint_node_near_screen(screen_position: Vector2) -> int:
	var canvas_transform := get_viewport().get_canvas_transform()
	var nearest_index := -1
	var nearest_distance := STATION_PICK_RADIUS * 0.55
	for index in range(waypoint_markers.size()):
		var marker_screen: Vector2 = canvas_transform * waypoint_markers[index]
		var distance := marker_screen.distance_to(screen_position)
		if distance <= nearest_distance:
			nearest_distance = distance
			nearest_index = index
	if nearest_index < 0:
		return -1
	return _get_or_create_lane_node(waypoint_markers[nearest_index], -1, 0, -1)

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
	pending_curve_start_node = -1
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
	# Standalone planning waypoints: distinct from passenger stations and
	# lane endpoint nodes, with no connecting preview during placement.
	for waypoint in waypoint_markers:
		draw_circle(waypoint, 8.0 / camera.zoom.x, Color(0.08, 0.24, 0.25, 1.0))
		draw_arc(waypoint, 14.0 / camera.zoom.x, 0.0, TAU, 28, Color(0.65, 1.0, 0.95, 1.0), 2.5 / camera.zoom.x, true)
	for path in waypoint_paths:
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
	for segment_index in range(parallel_curve_segments.size()):
		var segment: Dictionary = parallel_curve_segments[segment_index]
		for path in segment["paths"]:
			if path.size() > 1:
				draw_polyline(path, Color(0.24, 0.86, 0.78), 7.0, true)
		if build_mode == "parallel_curve":
			var handle: Vector2 = segment["control"]
			var zoom_scale := camera.zoom.x
			draw_line(segment["paths"][0][0], handle, Color(0.72, 1.0, 0.97, 0.55), 2.0 / zoom_scale, true)
			draw_circle(handle, 19.0 / zoom_scale, Color(0.08, 0.22, 0.23, 0.98))
			draw_circle(handle, 10.0 / zoom_scale, Color(0.55, 1.0, 0.94, 0.98))
			draw_arc(handle, 27.0 / zoom_scale, 0.0, TAU, 40, Color(0.72, 1.0, 0.97, 1.0), 3.0 / zoom_scale, true)
	# Orange endpoint markers expose the selectable centerline graph nodes.
	for node in lane_nodes:
		var node_position: Vector2 = node.get("position", Vector2.ZERO)
		draw_circle(node_position, 5.5, Color(1.0, 0.48, 0.16, 0.95))
		draw_arc(node_position, 9.0, 0.0, TAU, 24, Color(1.0, 0.68, 0.32, 0.9), 1.5, true)
	for index in range(stations.size()):
		var station := stations[index]
		draw_circle(station, 12.0, Color(0.88, 0.96, 1.0))
		draw_arc(station, 16.0, 0.0, TAU, 32, Color(0.25, 0.88, 0.82), 2.0, true)
		if build_mode == "track" and int(node.get("id", -1)) == pending_track_start_node:
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

func _get_curve_preview_endpoint() -> Vector2:
	var center := get_viewport_rect().size * 0.5
	var node_id := _find_lane_node_near_screen(center)
	if node_id < 0:
		node_id = _find_waypoint_node_near_screen(center)
	if node_id >= 0:
		return _get_lane_node_position(node_id, get_snapped_world_position(center))
	var station_index := _find_station_near_screen(center)
	if station_index >= 0:
		return stations[station_index]
	return get_snapped_world_position(center)

func _draw_parallel_curve_preview() -> void:
	var start_point := _get_lane_node_position(pending_curve_start_node, pending_curve_start_position)
	var end_point := _get_curve_preview_endpoint()
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
	var start_point := _get_lane_node_position(pending_curve_start_node, pending_curve_start_position)
	var end_point := _get_curve_preview_endpoint()
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
	var preview_start: Vector2 = _get_lane_node_position(pending_track_start_node, pending_track_start_position)
	var preview_node_id := _find_lane_node_near_screen(viewport_size * 0.5) if build_mode == "track" else -1
	if build_mode == "track" and preview_node_id < 0:
		preview_node_id = _find_waypoint_node_near_screen(viewport_size * 0.5)
	var preview_end := _get_lane_node_position(preview_node_id, get_snapped_world_position(viewport_size * 0.5))
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
