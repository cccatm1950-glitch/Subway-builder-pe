extends Node2D

const MIN_ZOOM := 0.45
const MAX_ZOOM := 2.5
const TrackGraphScript = preload("res://scripts/railway/track_graph.gd")
const TrackGeometryScript = preload("res://scripts/railway/track_geometry.gd")
const JunctionEngineScript = preload("res://scripts/railway/junction_engine.gd")
const StationModelScript = preload("res://scripts/railway/station_model.gd")
const SNAP_SPACING := 32.0
const TAP_DRAG_THRESHOLD := 16.0
const STATION_PICK_RADIUS := 64.0
const PARALLEL_CENTERLINE_SPACING := 48.0

@onready var camera: Camera2D = $Camera2D
@onready var hud = $CanvasLayer/HUD

var track_graph: TrackGraph
var graph_node_ids: Dictionary = {}
var graph_edge_ids: Dictionary = {}
var active_touches: Dictionary = {}
var touch_starts: Dictionary = {}
var touch_moved: Dictionary = {}
var ignored_touches: Dictionary = {}
var previous_pinch_distance := 0.0
var build_mode := ""
var stations: Array[Vector2] = []
var station_records: Array[Dictionary] = []
var track_segments: Array[Vector2] = []
var pending_curve_start_node := -1
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
var mouse_pointer_last_position := Vector2.ZERO
var mouse_pointer_dragged := false
var curve_handle_dragging := false
var curve_handle_touch_index := -1
var editing_curve_index := -1
var editing_parallel_curve_index := -1

func _ready() -> void:
	track_graph = TrackGraphScript.new()
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

var polled_touch_active := false
var polled_touch_last_position := Vector2.ZERO

func _process(_delta: float) -> void:
	# Poll the Android touch state as a fallback for devices where drag
	# notifications are not consistently delivered to Node2D._input().
	var touch_count := Input.get_touch_count()
	if touch_count == 1:
		var current_position := Input.get_touch_position(0)
		if polled_touch_active:
			var pan_delta := current_position - polled_touch_last_position
			if not pan_delta.is_zero_approx():
				_pan_camera(pan_delta)
				hud.set_input_status("MAP DRAG · POLLED TOUCH")
		else:
			polled_touch_active = true
		polled_touch_last_position = current_position
	else:
		polled_touch_active = false

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_screen_touch(event)
	elif event is InputEventScreenDrag:
		_handle_screen_drag(event)
	elif event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion and (mouse_pointer_down or (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0):
		if curve_handle_dragging and curve_handle_touch_index == -2:
			_move_curve_handle(event.position)
			queue_redraw()
			return
		if mouse_pointer_down:
			if event.position.distance_to(mouse_pointer_start) > TAP_DRAG_THRESHOLD:
				mouse_pointer_dragged = true
			var pan_delta := event.position - mouse_pointer_last_position
			if pan_delta.is_zero_approx():
				pan_delta = event.relative
			mouse_pointer_last_position = event.position
			if not pan_delta.is_zero_approx():
				_pan_camera(pan_delta)
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
	var previous_position: Vector2 = active_touches[event.index]
	var pan_delta := event.position - previous_position
	active_touches[event.index] = event.position
	var start: Vector2 = touch_starts.get(event.index, event.position)
	if event.position.distance_to(start) > TAP_DRAG_THRESHOLD:
		touch_moved[event.index] = true
	if active_touches.size() == 1:
		# One-finger panning is handled by _process() polling so it also
		# works on Android builds that omit ScreenDrag notifications.
		hud.set_input_status("TOUCH HELD")
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
			mouse_pointer_last_position = event.position
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
	elif build_mode == "station":
		var station_position := get_snapped_world_position(crosshair_screen)
		if not stations.has(station_position):
			var station_id := stations.size()
			stations.append(station_position)
			station_records.append(StationModelScript.create_record(station_id, station_position))
			queue_redraw()
		_update_coordinate_readout()
	elif build_mode == "track" or build_mode == "parallel":
		var lane_node_id := _find_lane_node_near_screen(crosshair_screen) if build_mode == "track" else -1
		var station_index := -1
		var target_position := get_snapped_world_position(crosshair_screen)
		var has_anchor := false
		if lane_node_id >= 0:
			var lane_node := _get_lane_node(lane_node_id)
			station_index = int(lane_node.get("station_index", -1))
			target_position = Vector2(lane_node.get("position", target_position))
			has_anchor = true
		else:
			station_index = _find_station_near_screen(crosshair_screen)
			if station_index >= 0:
				target_position = stations[station_index]
				has_anchor = true
		if not has_anchor:
			hud.set_mode(build_mode, "ALIGN THE CROSSHAIR WITH A STATION OR TRACK NODE")
			return
		if pending_track_start == -1 and pending_track_start_node == -1:
			pending_track_start = station_index
			pending_track_start_node = lane_node_id
			pending_track_start_position = target_position
			hud.set_mode(build_mode, "START SELECTED  ·  ALIGN CROSSHAIR WITH ANOTHER NODE")
		elif station_index == pending_track_start and lane_node_id == pending_track_start_node:
			hud.set_mode(build_mode, "SAME NODE  ·  CHOOSE A DIFFERENT CONNECTION")
		else:
			var start_station := pending_track_start
			var start_position := pending_track_start_position
			if build_mode == "parallel":
				_add_parallel_track_pair_from_anchors(start_station, station_index, pending_track_start_position, target_position, pending_track_start_node, lane_node_id)
			else:
				_add_track_edge_from_anchors(start_station, station_index, start_position, target_position, pending_track_start_node, lane_node_id)
			pending_track_start = -1
			pending_track_start_node = -1
			pending_track_start_position = Vector2.ZERO
			queue_redraw()
			hud.set_mode(build_mode, "TRACK CONNECTED  ·  SELECT ANOTHER START")

func _handle_curve_tap(screen_position: Vector2) -> void:
	var lane_node_id := _find_lane_node_near_screen(screen_position)
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
		if lane_node_id < 0 and station_index < 0:
			hud.set_mode(build_mode, "SELECT A START STATION OR TRACK NODE")
			return
		pending_curve_start = station_index
		pending_curve_start_node = lane_node_id
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
	if (lane_node_id < 0 and station_index < 0) or (lane_node_id == pending_curve_start_node and pending_curve_start_node >= 0) or (lane_node_id < 0 and pending_curve_start_node < 0 and station_index == pending_curve_start):
		hud.set_mode(build_mode, "TAP A DIFFERENT END STATION OR TRACK NODE")
		return
	var start_fallback: Vector2 = stations[pending_curve_start] if pending_curve_start >= 0 and pending_curve_start < stations.size() else Vector2.ZERO
	start_fallback = _get_lane_node_position(pending_curve_start_node, start_fallback)
	var curve_start := _get_lane_node_position(pending_curve_start_node, start_fallback)
	var curve_end := endpoint
	var curve_control := _constrain_curve_control(curve_start, pending_curve_control, curve_end)
	var start_node := pending_curve_start_node
	if start_node < 0:
		start_node = _get_or_create_lane_node(curve_start, pending_curve_start, 0, -1)
	var end_node := lane_node_id
	if end_node < 0:
		end_node = _get_or_create_lane_node(curve_end, station_index, 0, -1)
	var curve_start_tangent := _find_connected_track_tangent(curve_start, (curve_control - curve_start).normalized(), false)
	var curve_end_tangent := _find_connected_track_tangent(curve_end, (curve_end - curve_control).normalized(), true)
	curve_segments.append({"start": curve_start, "control": curve_control, "end": curve_end, "start_node": start_node, "end_node": end_node, "start_station": pending_curve_start, "end_station": station_index, "start_tangent": curve_start_tangent, "end_tangent": curve_end_tangent})
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
		if lane_node_id < 0 and station_index < 0:
			hud.set_mode(build_mode, "SELECT A START STATION OR TRACK NODE")
			return
		pending_curve_start = station_index
		pending_curve_start_node = lane_node_id
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
	if (lane_node_id < 0 and station_index < 0) or (lane_node_id == pending_curve_start_node and pending_curve_start_node >= 0) or (lane_node_id < 0 and pending_curve_start_node < 0 and station_index == pending_curve_start):
		hud.set_mode(build_mode, "TAP A DIFFERENT END STATION OR TRACK NODE")
		return
	var start_fallback: Vector2 = stations[pending_curve_start] if pending_curve_start >= 0 and pending_curve_start < stations.size() else Vector2.ZERO
	start_fallback = _get_lane_node_position(pending_curve_start_node, start_fallback)
	var curve_start := start_fallback
	var curve_end := endpoint
	var control := _constrain_curve_control(curve_start, pending_curve_control, curve_end)
	var pair := _offset_parallel_curve(_make_curve_points(curve_start, control, curve_end), PARALLEL_CENTERLINE_SPACING * 0.5)
	if pair.size() != 2 or pair[0].size() < 2 or pair[1].size() < 2:
		hud.set_mode(build_mode, "COULD NOT CREATE PARALLEL CURVE")
		return
	# Resolve both lane endpoints first. When either end belongs to an existing
	# parallel section, the curve's true anchor is the midpoint between its two
	# lane nodes, not the one lane node the user happened to tap.
	var start_anchor_nodes := _resolve_parallel_curve_anchor_nodes(pending_curve_start, pending_curve_start_node, pair, true)
	var end_anchor_nodes := _resolve_parallel_curve_anchor_nodes(station_index, lane_node_id, pair, false)
	var start_anchor_midpoint := (Vector2(start_anchor_nodes[0]["position"]) + Vector2(start_anchor_nodes[1]["position"])) * 0.5
	var end_anchor_midpoint := (Vector2(end_anchor_nodes[0]["position"]) + Vector2(end_anchor_nodes[1]["position"])) * 0.5
	var start_tangent := _average_parallel_anchor_tangent(start_anchor_nodes, (control - curve_start).normalized(), false)
	var end_tangent := _average_parallel_anchor_tangent(end_anchor_nodes, (curve_end - control).normalized(), true)
	if int(start_anchor_nodes[0]["node_id"]) != int(start_anchor_nodes[1]["node_id"]):
		curve_start = start_anchor_midpoint
	if int(end_anchor_nodes[0]["node_id"]) != int(end_anchor_nodes[1]["node_id"]):
		curve_end = end_anchor_midpoint
	control = _constrain_curve_control(curve_start, control, curve_end)
	var centerline := _make_curve_points(curve_start, control, curve_end, start_tangent, end_tangent)
	pair = _offset_parallel_curve(centerline, PARALLEL_CENTERLINE_SPACING * 0.5)
	if pair.size() != 2 or pair[0].size() < 2 or pair[1].size() < 2:
		hud.set_mode(build_mode, "COULD NOT CREATE PARALLEL CURVE")
		return
	# Re-pair after rebuilding from the midpoint-based centerline.
	start_anchor_nodes = _resolve_parallel_curve_anchor_nodes(pending_curve_start, pending_curve_start_node, pair, true)
	end_anchor_nodes = _resolve_parallel_curve_anchor_nodes(station_index, lane_node_id, pair, false)
	var group_id := next_track_edge_id
	var start_anchor_positions: Array[Vector2] = []
	var end_anchor_positions: Array[Vector2] = []
	var transition_path_indices: Array = []
	for lane in range(2):
		start_anchor_positions.append(Vector2(start_anchor_nodes[lane]["position"]))
		end_anchor_positions.append(Vector2(end_anchor_nodes[lane]["position"]))
		transition_path_indices.append([-1, -1])
	parallel_curve_segments.append({"paths": pair, "start_station": pending_curve_start, "end_station": station_index, "start_point": curve_start, "end_point": curve_end, "start_node": pending_curve_start_node, "end_node": lane_node_id, "control": control, "start_tangent": start_tangent, "end_tangent": end_tangent, "group_id": group_id, "start_anchor_positions": start_anchor_positions, "end_anchor_positions": end_anchor_positions, "transition_path_indices": transition_path_indices})
	for lane in range(2):
		var path: PackedVector2Array = pair[lane]
		var start_anchor: Dictionary = start_anchor_nodes[lane]
		var end_anchor: Dictionary = end_anchor_nodes[lane]
		var start_anchor_position: Vector2 = start_anchor["position"]
		var end_anchor_position: Vector2 = end_anchor["position"]
		var start_node := _get_or_create_lane_node(path[0], pending_curve_start, lane, group_id)
		var end_node := _get_or_create_lane_node(path[path.size() - 1], station_index, lane, group_id)
		track_edges.append({"id": next_track_edge_id, "start_node": start_node, "end_node": end_node, "start_station": pending_curve_start, "end_station": station_index, "start_point": path[0], "end_point": path[path.size() - 1], "kind": "parallel_curve", "parallel_group": group_id, "lane_index": lane, "lane_count": 2, "centerline_spacing": PARALLEL_CENTERLINE_SPACING})
		_register_lane_edge(next_track_edge_id, start_node, end_node)
		next_track_edge_id += 1

		# Each offset curve lane connects to its corresponding existing lane
		# node. A selected parallel endpoint must never fan both new lanes into
		# the same node, which would collapse two centerlines into one junction.
		var start_path_tangent := (path[1] - path[0]).normalized()
		var start_outgoing := _find_connected_track_tangent(start_anchor_position, start_path_tangent, false)
		if start_outgoing == Vector2.ZERO:
			start_outgoing = (path[0] - start_anchor_position).normalized()
		var start_transition := _make_junction_transition(start_anchor_position, path[0], start_outgoing, start_path_tangent)
		var start_anchor_is_shared := int(start_anchor_nodes[0]["node_id"]) == int(start_anchor_nodes[1]["node_id"])
		# A shared single-track node is a real turnout root: both offset lanes
		# must have their own transition edge from that node. The paths diverge
		# toward distinct lane endpoints, so suppressing lane 1 would leave it
		# visually present but unreachable in the lane graph.
		if start_transition.size() > 1 and int(start_anchor["node_id"]) != start_node:
			var start_transition_index := junction_transition_paths.size()
			junction_transition_paths.append(start_transition)
			parallel_curve_segments[parallel_curve_segments.size() - 1]["transition_path_indices"][lane][0] = start_transition_index
			track_edges.append({"id": next_track_edge_id, "start_node": int(start_anchor["node_id"]), "end_node": start_node, "start_station": pending_curve_start, "end_station": pending_curve_start, "start_point": start_anchor_position, "end_point": path[0], "kind": "transition", "parallel_group": -1, "curve_group_id": group_id, "transition_side": "start", "lane_index": lane, "lane_count": 1, "centerline_spacing": 0.0})
			_register_lane_edge(next_track_edge_id, int(start_anchor["node_id"]), start_node)
			next_track_edge_id += 1

		var end_path_tangent := (path[path.size() - 1] - path[path.size() - 2]).normalized()
		var end_incoming := _find_connected_track_tangent(end_anchor_position, end_path_tangent, true)
		if end_incoming == Vector2.ZERO:
			end_incoming = (end_anchor_position - path[path.size() - 1]).normalized()
		var end_transition := _make_junction_transition(path[path.size() - 1], end_anchor_position, end_path_tangent, end_incoming)
		var end_anchor_is_shared := int(end_anchor_nodes[0]["node_id"]) == int(end_anchor_nodes[1]["node_id"])
		# Mirror the turnout at the destination: register both lane transitions
		# so neither parallel centerline terminates as an orphan.
		if end_transition.size() > 1 and int(end_anchor["node_id"]) != end_node:
			var end_transition_index := junction_transition_paths.size()
			junction_transition_paths.append(end_transition)
			parallel_curve_segments[parallel_curve_segments.size() - 1]["transition_path_indices"][lane][1] = end_transition_index
			track_edges.append({"id": next_track_edge_id, "start_node": end_node, "end_node": int(end_anchor["node_id"]), "start_station": station_index, "end_station": station_index, "start_point": path[path.size() - 1], "end_point": end_anchor_position, "kind": "transition", "parallel_group": -1, "curve_group_id": group_id, "transition_side": "end", "lane_index": lane, "lane_count": 1, "centerline_spacing": 0.0})
			_register_lane_edge(next_track_edge_id, end_node, int(end_anchor["node_id"]))
			next_track_edge_id += 1
	pending_curve_start = -1
	pending_curve_start_node = -1
	curve_stage = 0
	queue_redraw()
	hud.set_mode(build_mode, "PARALLEL CURVE CONNECTED  ·  SELECT ANOTHER START")

func _resolve_parallel_curve_anchor_nodes(station_index: int, selected_node_id: int, paths: Array[PackedVector2Array], at_start: bool = true) -> Array[Dictionary]:
	var anchors: Array[Dictionary] = [{}, {}]
	var candidates: Array[Dictionary] = []
	var selected_node := _get_lane_node(selected_node_id) if selected_node_id >= 0 else {}
	var selected_group := int(selected_node.get("parallel_group", -1))
	var fallback_position: Vector2 = Vector2(selected_node.get("position", stations[station_index] if station_index >= 0 and station_index < stations.size() else Vector2.ZERO))
	# A curve endpoint may be attached to either end of an existing parallel
	# group. Resolve the group node at the selected station, not simply the
	# edge's start/end according to the new curve's direction.
	var candidate_groups: Array[int] = []
	if selected_group >= 0:
		candidate_groups.append(selected_group)
	elif station_index >= 0:
		candidate_groups = _get_parallel_groups_at_station(station_index)
	if not candidate_groups.is_empty():
		var best_group := -1
		var best_group_cost := INF
		for group_id in candidate_groups:
			var group_edges := _get_parallel_group_lanes(group_id)
			if group_edges.size() != 2:
				continue
			var group_cost := 0.0
			for lane_edge in group_edges:
				var candidate_node_id := int(lane_edge.get("start_node", -1)) if int(lane_edge.get("start_station", -1)) == station_index else int(lane_edge.get("end_node", -1))
				var candidate_node := _get_lane_node(candidate_node_id)
				var candidate_position: Vector2 = candidate_node.get("position", fallback_position)
				var path_point: Vector2 = paths[0][0] if at_start else paths[0][paths[0].size() - 1]
				group_cost += path_point.distance_to(candidate_position)
			if group_cost < best_group_cost:
				best_group_cost = group_cost
				best_group = group_id
		if best_group >= 0:
			for edge in _get_parallel_group_lanes(best_group):
				var node_id := int(edge.get("start_node", -1)) if int(edge.get("start_station", -1)) == station_index else int(edge.get("end_node", -1))
				if node_id < 0:
					continue
				var node := _get_lane_node(node_id)
				if not node.is_empty():
					candidates.append({"node_id": node_id, "position": Vector2(node.get("position", fallback_position))})
	if candidates.size() == 2:
		# Match curve offsets to the closest corresponding existing lane endpoints.
		var p0: Vector2 = paths[0][0] if at_start else paths[0][paths[0].size() - 1]
		var p1: Vector2 = paths[1][0] if at_start else paths[1][paths[1].size() - 1]
		var direct_cost := p0.distance_to(candidates[0]["position"]) + p1.distance_to(candidates[1]["position"])
		var crossed_cost := p0.distance_to(candidates[1]["position"]) + p1.distance_to(candidates[0]["position"])
		if crossed_cost < direct_cost:
			candidates.reverse()
			anchors[0] = candidates[0]
			anchors[1] = candidates[1]
		else:
			anchors[0] = candidates[0]
			anchors[1] = candidates[1]
		return anchors
	if selected_node_id >= 0 and not selected_node.is_empty():
		var selected_position: Vector2 = selected_node.get("position", stations[station_index])
		anchors[0] = {"node_id": selected_node_id, "position": selected_position}
		anchors[1] = {"node_id": selected_node_id, "position": selected_position}
	else:
		var anchor_position := fallback_position
		if selected_node_id < 0 and station_index >= 0 and station_index < stations.size():
			anchor_position = stations[station_index]
		var anchor_node := selected_node_id
		if anchor_node < 0:
			anchor_node = _get_or_create_lane_node(anchor_position, station_index, 0, -1)
		var shared_anchor := {"node_id": anchor_node, "position": anchor_position}
		anchors[0] = shared_anchor
		anchors[1] = shared_anchor
	return anchors


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
	# Use the shared geometry module so straight and curved parallel placement
	# follow the same signed-offset and miter rules.
	return TrackGeometryScript.make_parallel_pair(centerline, half_spacing * 2.0)

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
		var start_point: Vector2 = parallel_curve.get("start_point", Vector2.ZERO)
		var end_point: Vector2 = parallel_curve.get("end_point", Vector2.ZERO)
		var control := _constrain_curve_control(start_point, new_control, end_point)
		var stored_start_tangent: Vector2 = parallel_curve.get("start_tangent", Vector2.ZERO)
		var stored_end_tangent: Vector2 = parallel_curve.get("end_tangent", Vector2.ZERO)
		var pair := _offset_parallel_curve(_make_curve_points(start_point, control, end_point, stored_start_tangent, stored_end_tangent), PARALLEL_CENTERLINE_SPACING * 0.5)
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
					_sync_graph_edge_geometry(track_edges[edge_index])
			# The transition curves must move with the edited offset lanes. Keeping
			# their original samples leaves gaps and stale connector strokes.
			var start_anchor_positions: Array = parallel_curve.get("start_anchor_positions", [])
			var end_anchor_positions: Array = parallel_curve.get("end_anchor_positions", [])
			var transition_indices: Array = parallel_curve.get("transition_path_indices", [])
			for lane in range(2):
				if lane >= start_anchor_positions.size() or lane >= end_anchor_positions.size() or lane >= transition_indices.size():
					continue
				var path: PackedVector2Array = pair[lane]
				var start_anchor_position: Vector2 = start_anchor_positions[lane]
				var end_anchor_position: Vector2 = end_anchor_positions[lane]
				var start_tangent := (path[1] - path[0]).normalized()
				var end_tangent := (path[path.size() - 1] - path[path.size() - 2]).normalized()
				var start_outgoing := _find_connected_track_tangent(start_anchor_position, start_tangent, false)
				if start_outgoing == Vector2.ZERO:
					start_outgoing = (path[0] - start_anchor_position).normalized()
				var end_incoming := _find_connected_track_tangent(end_anchor_position, end_tangent, true)
				if end_incoming == Vector2.ZERO:
					end_incoming = (end_anchor_position - path[path.size() - 1]).normalized()
				var indices: Array = transition_indices[lane]
				if indices.size() >= 2:
					var start_index := int(indices[0])
					var end_index := int(indices[1])
					if start_index >= 0 and start_index < junction_transition_paths.size():
						junction_transition_paths[start_index] = _make_junction_transition(start_anchor_position, path[0], start_outgoing, start_tangent)
					if end_index >= 0 and end_index < junction_transition_paths.size():
						junction_transition_paths[end_index] = _make_junction_transition(path[path.size() - 1], end_anchor_position, end_tangent, end_incoming)
				for transition_edge in track_edges:
					if int(transition_edge.get("curve_group_id", -1)) != group_id or int(transition_edge.get("lane_index", -1)) != lane:
						continue
					if String(transition_edge.get("transition_side", "")) == "start":
						transition_edge["end_point"] = path[0]
					else:
						transition_edge["start_point"] = path[path.size() - 1]
					_sync_graph_edge_geometry(transition_edge)
	elif editing_curve_index >= 0 and editing_curve_index < curve_segments.size():
		var curve: Dictionary = curve_segments[editing_curve_index]
		curve["control"] = _constrain_curve_control(curve["start"], new_control, curve["end"])
		for edge in track_edges:
			if String(edge.get("kind", "")) == "curve" and int(edge.get("start_node", -1)) == int(curve.get("start_node", -2)) and int(edge.get("end_node", -1)) == int(curve.get("end_node", -2)):
				_sync_graph_edge_geometry(edge)
	else:
		if pending_curve_start_node >= 0 or (pending_curve_start >= 0 and pending_curve_start < stations.size()):
			var start_fallback: Vector2 = stations[pending_curve_start] if pending_curve_start >= 0 and pending_curve_start < stations.size() else Vector2.ZERO
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

func _average_parallel_anchor_tangent(anchors: Array[Dictionary], preferred_direction: Vector2, at_curve_end: bool) -> Vector2:
	var tangent_sum := Vector2.ZERO
	for anchor in anchors:
		var tangent := _find_connected_track_tangent(Vector2(anchor["position"]), preferred_direction, at_curve_end)
		if tangent != Vector2.ZERO:
			if tangent_sum != Vector2.ZERO and tangent_sum.dot(tangent) < 0.0:
				tangent = -tangent
			tangent_sum += tangent
	return tangent_sum.normalized() if tangent_sum.length_squared() > 0.001 else Vector2.ZERO

func _make_curve_points(start_point: Vector2, control_point: Vector2, end_point: Vector2, start_tangent_override: Vector2 = Vector2.ZERO, end_tangent_override: Vector2 = Vector2.ZERO) -> PackedVector2Array:
	var points := PackedVector2Array()
	var chord := end_point - start_point
	var chord_length := chord.length()
	if chord_length < 0.5:
		return points

	var chord_direction := chord / chord_length
	var start_to_handle := control_point - start_point
	var handle_to_end := end_point - control_point
	if start_to_handle.length_squared() < 0.0001 or handle_to_end.length_squared() < 0.0001:
		return points

	var start_track_tangent := start_tangent_override if start_tangent_override.length_squared() > 0.001 else _find_connected_track_tangent(start_point, start_to_handle.normalized(), false)
	var end_track_tangent := end_tangent_override if end_tangent_override.length_squared() > 0.001 else _find_connected_track_tangent(end_point, handle_to_end.normalized(), true)
	var start_tangent := start_track_tangent.normalized() if start_track_tangent.length_squared() > 0.001 else start_to_handle.normalized()
	var end_tangent := end_track_tangent.normalized() if end_track_tangent.length_squared() > 0.001 else handle_to_end.normalized()
	if start_tangent.length_squared() < 0.001:
		start_tangent = chord_direction
	if end_tangent.length_squared() < 0.001:
		end_tangent = chord_direction

	# Approximate a modified-Euler track transition by integrating a smooth
	# curvature/heading profile. The draggable handle controls both arc length
	# and signed lateral bow; connected track tangents remain exact at the ends.
	var start_heading := start_tangent.angle()
	var end_heading := end_tangent.angle()
	var heading_change := wrapf(end_heading - start_heading, -PI, PI)
	var chord_normal := Vector2(-chord_direction.y, chord_direction.x)
	var handle_offset := (control_point - (start_point + end_point) * 0.5).dot(chord_normal)
	var bow_angle := clampf((handle_offset / chord_length) * 1.35, -1.15, 1.15)
	var requested_length := (start_to_handle.length() + handle_to_end.length()) * 0.9
	var arc_length := clampf(maxf(chord_length, requested_length), chord_length, chord_length * 3.0)

	var sample_count := clampi(int(ceil(arc_length / 8.0)), 48, 160)
	var step_length := arc_length / float(sample_count)
	var position := start_point
	points.append(position)
	for step in range(sample_count):
		var u0 := float(step) / float(sample_count)
		var u1 := float(step + 1) / float(sample_count)
		var smooth0 := u0 * u0 * (3.0 - 2.0 * u0)
		var smooth1 := u1 * u1 * (3.0 - 2.0 * u1)
		var bow0 := sin(PI * u0)
		var bow1 := sin(PI * u1)
		var heading0 := start_heading + heading_change * smooth0 + bow_angle * bow0 * bow0
		var heading1 := start_heading + heading_change * smooth1 + bow_angle * bow1 * bow1
		# Heun's (modified Euler) step for the planar tangent field.
		var direction0 := Vector2(cos(heading0), sin(heading0))
		var direction1 := Vector2(cos(heading1), sin(heading1))
		position += (direction0 + direction1) * (0.5 * step_length)
		points.append(position)

	# Close the small numerical endpoint residual without changing endpoint
	# tangents: smoothstep has zero derivative at both ends.
	var endpoint_error := end_point - points[points.size() - 1]
	for index in range(1, points.size()):
		var u := float(index) / float(sample_count)
		var weight := u * u * (3.0 - 2.0 * u)
		points[index] += endpoint_error * weight
	points[points.size() - 1] = end_point
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
	# Keep the new canonical graph in lockstep while legacy drawing is migrated.
	var graph_id := track_graph.add_node(position, station_index, parallel_group, lane_index)
	graph_node_ids[node_id] = graph_id
	return node_id

func _set_lane_node_position(node_id: int, position: Vector2) -> void:
	for index in range(lane_nodes.size()):
		if int(lane_nodes[index].get("id", -1)) == node_id:
			lane_nodes[index]["position"] = position
			var graph_id := int(graph_node_ids.get(node_id, -1))
			if graph_id >= 0:
				track_graph.update_node_position(graph_id, position)
			return

func _register_lane_edge(edge_id: int, start_node: int, end_node: int) -> void:
	for index in range(lane_nodes.size()):
		var node_id := int(lane_nodes[index].get("id", -1))
		if node_id == start_node or node_id == end_node:
			var incident_edges: Array = lane_nodes[index].get("edge_ids", [])
			if not incident_edges.has(edge_id):
				incident_edges.append(edge_id)
			lane_nodes[index]["edge_ids"] = incident_edges
	# Mirror topology into the canonical graph. Geometry is refined on the
	# graph edge as construction operations migrate off the legacy arrays.
	var graph_start := int(graph_node_ids.get(start_node, -1))
	var graph_end := int(graph_node_ids.get(end_node, -1))
	if graph_start < 0 or graph_end < 0:
		push_error("Cannot register railway edge %d: missing graph endpoint" % edge_id)
		return
	var source_edge: Dictionary = {}
	for candidate in track_edges:
		if int(candidate.get("id", -1)) == edge_id:
			source_edge = candidate
			break
	if source_edge.is_empty():
		push_error("Cannot register railway edge %d: missing edge record" % edge_id)
		return
	var points := _get_track_edge_geometry(source_edge)
	var graph_edge := track_graph.add_edge(graph_start, graph_end, String(source_edge.get("kind", "single")), points, int(source_edge.get("parallel_group", -1)), int(source_edge.get("lane_index", 0)))
	if graph_edge < 0:
		push_error("Canonical graph rejected railway edge %d" % edge_id)
	else:
		graph_edge_ids[edge_id] = graph_edge

func _get_track_edge_geometry(edge: Dictionary) -> PackedVector2Array:
	var kind := String(edge.get("kind", "single"))
	if kind == "curve":
		for curve in curve_segments:
			if int(curve.get("start_node", -1)) == int(edge.get("start_node", -2)) and int(curve.get("end_node", -1)) == int(edge.get("end_node", -2)):
				return _make_curve_points(Vector2(curve["start"]), Vector2(curve["control"]), Vector2(curve["end"]), Vector2(curve.get("start_tangent", Vector2.ZERO)), Vector2(curve.get("end_tangent", Vector2.ZERO)))
	elif kind == "parallel_curve":
		for curve in parallel_curve_segments:
			if int(curve.get("group_id", -1)) == int(edge.get("parallel_group", -2)):
				var lane := int(edge.get("lane_index", 0))
				var paths: Array = curve.get("paths", [])
				if lane >= 0 and lane < paths.size():
					return PackedVector2Array(paths[lane])
	elif kind == "transition" or kind == "station_transfer":
		var stored_path_index := int(edge.get("transition_path_index", -1))
		if stored_path_index >= 0 and stored_path_index < junction_transition_paths.size():
			return junction_transition_paths[stored_path_index]
		var group_id := int(edge.get("curve_group_id", -1))
		if group_id >= 0:
			for curve in parallel_curve_segments:
				if int(curve.get("group_id", -1)) != group_id:
					continue
				var lane := int(edge.get("lane_index", -1))
				var side_index := 0 if String(edge.get("transition_side", "")) == "start" else 1
				var indices: Array = curve.get("transition_path_indices", [])
				if lane >= 0 and lane < indices.size() and side_index < indices[lane].size():
					var path_index := int(indices[lane][side_index])
					if path_index >= 0 and path_index < junction_transition_paths.size():
						return junction_transition_paths[path_index]
	return PackedVector2Array([Vector2(edge.get("start_point", Vector2.ZERO)), Vector2(edge.get("end_point", Vector2.ZERO))])

func _sync_graph_edge_geometry(edge: Dictionary) -> void:
	var legacy_id := int(edge.get("id", -1))
	var graph_id := int(graph_edge_ids.get(legacy_id, -1))
	if graph_id >= 0:
		var points := _get_track_edge_geometry(edge)
		if not track_graph.update_edge_points(graph_id, points):
			push_error("Could not synchronize canonical geometry for railway edge %d" % legacy_id)

func get_graph_mirror_diagnostics() -> PackedStringArray:
	var errors := track_graph.validate()
	for legacy_node_id in graph_node_ids:
		if not track_graph.has_node(int(graph_node_ids[legacy_node_id])):
			errors.append("Legacy lane node %d has no canonical graph node" % int(legacy_node_id))
	for legacy_edge_id in graph_edge_ids:
		if not track_graph.has_edge(int(graph_edge_ids[legacy_edge_id])):
			errors.append("Legacy track edge %d has no canonical graph edge" % int(legacy_edge_id))
	for node in lane_nodes:
		var legacy_node_id := int(node.get("id", -1))
		if not graph_node_ids.has(legacy_node_id):
			errors.append("Legacy lane node %d is missing from the graph map" % legacy_node_id)
			continue
		var graph_node := track_graph.get_node(int(graph_node_ids[legacy_node_id]))
		if Vector2(graph_node.get("position", Vector2.ZERO)).distance_to(Vector2(node.get("position", Vector2.ZERO))) > 0.01:
			errors.append("Legacy lane node %d position differs from canonical graph" % legacy_node_id)
	for edge in track_edges:
		var legacy_edge_id := int(edge.get("id", -1))
		if not graph_edge_ids.has(legacy_edge_id):
			errors.append("Legacy track edge %d is missing from the graph map" % legacy_edge_id)
			continue
		var graph_edge := track_graph.get_edge(int(graph_edge_ids[legacy_edge_id]))
		var expected_start := int(graph_node_ids.get(int(edge.get("start_node", -1)), -1))
		var expected_end := int(graph_node_ids.get(int(edge.get("end_node", -1)), -1))
		if int(graph_edge.get("start_node_id", -1)) != expected_start or int(graph_edge.get("end_node_id", -1)) != expected_end:
			errors.append("Legacy track edge %d endpoints differ from canonical graph" % legacy_edge_id)
		var expected_points := _get_track_edge_geometry(edge)
		var graph_points: PackedVector2Array = graph_edge.get("points", PackedVector2Array())
		if graph_points.size() != expected_points.size():
			errors.append("Legacy track edge %d geometry sample count differs from canonical graph" % legacy_edge_id)
		else:
			for point_index in range(expected_points.size()):
				if graph_points[point_index].distance_to(expected_points[point_index]) > 0.01:
					errors.append("Legacy track edge %d geometry differs from canonical graph" % legacy_edge_id)
					break
	return errors


func _add_track_edge_from_anchors(start_station: int, end_station: int, start_point: Vector2, end_point: Vector2, start_anchor_node: int, end_anchor_node: int) -> void:
	if start_anchor_node < 0 and end_anchor_node < 0 and start_station >= 0 and end_station >= 0:
		_add_track_edge(start_station, end_station, start_point, end_point, "single", -1, 0, 1, 0.0)
		return
	var start_node := start_anchor_node if start_anchor_node >= 0 else _get_or_create_lane_node(start_point, start_station, 0, -1)
	var end_node := end_anchor_node if end_anchor_node >= 0 else _get_or_create_lane_node(end_point, end_station, 0, -1)
	if start_node == end_node:
		hud.set_mode(build_mode, "SAME NODE  ·  CHOOSE A DIFFERENT CONNECTION")
		return
	track_segments.append(start_point)
	track_segments.append(end_point)
	track_edges.append({"id": next_track_edge_id, "start_node": start_node, "end_node": end_node, "start_station": start_station, "end_station": end_station, "start_point": start_point, "end_point": end_point, "kind": "single", "parallel_group": -1, "lane_index": 0, "lane_count": 1, "centerline_spacing": 0.0})
	_register_lane_edge(next_track_edge_id, start_node, end_node)
	next_track_edge_id += 1

func _add_track_edge(start_station: int, end_station: int, start_point: Vector2, end_point: Vector2, kind: String, parallel_group: int, lane_index: int, lane_count: int, spacing: float) -> void:
	var draw_start := start_point
	var draw_end := end_point
	# Explicit lane-node connections already identify their exact centerline
	# endpoints. Do not let the legacy station-level merge heuristic move them.
	if kind == "single" and start_station >= 0 and end_station >= 0 and start_station < stations.size() and end_station < stations.size() and start_point.distance_to(stations[start_station]) <= 0.5 and end_point.distance_to(stations[end_station]) <= 0.5:
		var merge_data := _build_parallel_merge_transition(start_station, end_station, start_point, end_point)
		if not merge_data.is_empty():
			draw_start = merge_data["draw_start"]
			draw_end = merge_data["draw_end"]
			for path in merge_data["paths"]:
				junction_transition_paths.append(path)
				_register_graph_transition_path(path, start_station if start_point.distance_to(stations[start_station]) <= 0.5 else end_station, lane_index)
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

func _register_graph_transition_path(path: PackedVector2Array, station_index: int, lane_index: int) -> void:
	if path.size() < 2:
		return
	# Reuse the exact endpoint nodes used by the primary track edge. This
	# makes the transition a true graph connection, not a parallel drawing.
	var start_node := _get_or_create_lane_node(path[0], station_index, lane_index, -1)
	var end_node := _get_or_create_lane_node(path[path.size() - 1], station_index, lane_index, -1)
	var graph_start := int(graph_node_ids.get(start_node, -1))
	var graph_end := int(graph_node_ids.get(end_node, -1))
	if graph_start < 0 or graph_end < 0 or graph_start == graph_end:
		push_error("Could not resolve graph endpoints for station merge transition")
		return
	if track_graph.add_edge(graph_start, graph_end, "transition", path, -1, lane_index) < 0:
		push_error("Canonical graph rejected station merge transition")

func _get_track_edge_outward_tangent(edge: Dictionary, station_index: int) -> Vector2:
	# Station-to-station chords are not reliable headings for curved parallel
	# approaches. Use the actual sampled lane geometry at the station endpoint.
	var points := _get_track_edge_geometry(edge)
	if points.size() < 2:
		return Vector2.ZERO
	if int(edge.get("start_station", -1)) == station_index:
		return (points[1] - points[0]).normalized()
	if int(edge.get("end_station", -1)) == station_index:
		return (points[points.size() - 2] - points[points.size() - 1]).normalized()
	return Vector2.ZERO

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
		var pair_direction := _get_track_edge_outward_tangent(edge, merge_station)
		if pair_direction == Vector2.ZERO:
			pair_direction = (stations[neighbor] - stations[merge_station]).normalized()
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
				neighbor_direction = _get_track_edge_outward_tangent(edge, merge_station)
				if neighbor_direction == Vector2.ZERO:
					neighbor_direction = (stations[neighbor] - stations[merge_station]).normalized()
				break
		if neighbor_direction == Vector2.ZERO:
			return {}
		var selected_lane := JunctionEngineScript.select_branch_lane_index(lane_endpoints, original_merge_point, neighbor_direction, outward_direction)
		if selected_lane < 0:
			return {}
		var lane_point: Vector2 = lane_endpoints[selected_lane]
		var switch_length := minf(merge_length, lane_point.distance_to(merge_point) + merge_length * 0.35)
		var switch_end := merge_point
		var turnout := JunctionEngineScript.build_turnout_path(lane_point, switch_end, neighbor_direction, outward_direction, switch_length * 0.34, 40)
		if turnout.size() < 2:
			return {}
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
		# the station, not back at the station marker itself. Preserve each
		# existing lane's local endpoint heading so curved approaches do not
		# kink into a straight chord at the merge.
		merge_point = through_point + outward_direction * merge_length
		var through_tangent := _find_connected_track_tangent(through_point, outward_direction, false)
		if through_tangent == Vector2.ZERO:
			through_tangent = outward_direction
		var merging_tangent := _find_connected_track_tangent(merging_point, outward_direction, false)
		if merging_tangent == Vector2.ZERO:
			merging_tangent = outward_direction
		# The retained lane and converging lane both terminate at the exact
		# same graph node. Their transition paths are sampled curves, not
		# visual-only station connector strokes.
		var through_path := _make_junction_transition(through_point, merge_point, through_tangent, outward_direction)
		if through_path.size() < 2:
			return {}
		paths.append(through_path)
		var merge_path := PackedVector2Array()
		var merge_handle := minf(merge_length * 0.38, merging_point.distance_to(merge_point) * 0.42)
		var first_control := merging_point + merging_tangent * merge_handle
		var second_control := merge_point - outward_direction * (merge_length * 0.24)
		for step in range(41):
			var t := float(step) / 40.0
			var u := 1.0 - t
			merge_path.append(u * u * u * merging_point + 3.0 * u * u * t * first_control + 3.0 * u * t * t * second_control + t * t * t * merge_point)
		paths.append(merge_path)
	if toward_end:
		return {"draw_start": merge_point, "draw_end": end_point, "paths": paths}
	return {"draw_start": start_point, "draw_end": merge_point, "paths": paths}

func _add_parallel_track_pair_from_anchors(start_station: int, end_station: int, start_position: Vector2, end_position: Vector2, start_anchor_node: int, end_anchor_node: int) -> void:
	var direction := (end_position - start_position).normalized()
	if direction == Vector2.ZERO:
		hud.set_mode(build_mode, "CHOOSE TWO DIFFERENT CONNECTION NODES")
		return
	var normal := Vector2(-direction.y, direction.x)
	var half_spacing := PARALLEL_CENTERLINE_SPACING * 0.5
	var group_id := next_track_edge_id
	var lane_starts: Array[Vector2] = [start_position + normal * half_spacing, start_position - normal * half_spacing]
	var lane_ends: Array[Vector2] = [end_position + normal * half_spacing, end_position - normal * half_spacing]
	var start_node := start_anchor_node
	if start_node < 0:
		start_node = _get_or_create_lane_node(start_position, start_station, 0, -1)
	var end_node := end_anchor_node
	if end_node < 0:
		end_node = _get_or_create_lane_node(end_position, end_station, 0, -1)
	for lane in range(2):
		var lane_start := _get_or_create_lane_node(lane_starts[lane], start_station, lane, group_id)
		var lane_end := _get_or_create_lane_node(lane_ends[lane], end_station, lane, group_id)
		# Parallel lanes are stored as graph edges, but the renderer also
		# consumes the legacy segment list. Register both endpoints so the
		# two visible centerlines are drawn as well as their orange nodes.
		track_segments.append(lane_starts[lane])
		track_segments.append(lane_ends[lane])
		track_edges.append({"id": next_track_edge_id, "start_node": lane_start, "end_node": lane_end, "start_station": start_station, "end_station": end_station, "start_point": lane_starts[lane], "end_point": lane_ends[lane], "kind": "parallel", "parallel_group": group_id, "lane_index": lane, "lane_count": 2, "centerline_spacing": PARALLEL_CENTERLINE_SPACING})
		_register_lane_edge(next_track_edge_id, lane_start, lane_end)
		next_track_edge_id += 1
		var start_outgoing := _find_connected_track_tangent(start_position, direction, false)
		if start_outgoing == Vector2.ZERO:
			start_outgoing = direction
		var end_outgoing := _find_connected_track_tangent(end_position, -direction, false)
		if end_outgoing == Vector2.ZERO:
			end_outgoing = -direction
		var start_connector := _make_junction_transition(start_position, lane_starts[lane], start_outgoing, direction)
		var end_connector := _make_junction_transition(lane_ends[lane], end_position, direction, -end_outgoing)
		if start_connector.size() > 1 and start_node != lane_start:
			var start_path_index := junction_transition_paths.size()
			junction_transition_paths.append(start_connector)
			track_edges.append({"id": next_track_edge_id, "start_node": start_node, "end_node": lane_start, "start_station": start_station, "end_station": start_station, "start_point": start_position, "end_point": lane_starts[lane], "kind": "station_transfer", "transition_path_index": start_path_index, "parallel_group": -1, "lane_index": lane, "lane_count": 1, "centerline_spacing": 0.0})
			_register_lane_edge(next_track_edge_id, start_node, lane_start)
			next_track_edge_id += 1
		if end_connector.size() > 1 and end_node != lane_end:
			var end_path_index := junction_transition_paths.size()
			junction_transition_paths.append(end_connector)
			track_edges.append({"id": next_track_edge_id, "start_node": lane_end, "end_node": end_node, "start_station": end_station, "end_station": end_station, "start_point": lane_ends[lane], "end_point": end_position, "kind": "station_transfer", "transition_path_index": end_path_index, "parallel_group": -1, "lane_index": lane, "lane_count": 1, "centerline_spacing": 0.0})
			_register_lane_edge(next_track_edge_id, lane_end, end_node)
			next_track_edge_id += 1
	queue_redraw()

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
	# and single-track routes as independent connections.
	var degree := 0
	var counted_parallel_groups: Dictionary = {}
	for edge in track_edges:
		if String(edge.get("kind", "")) == "station_transfer":
			continue
		if int(edge.get("start_station", -1)) != station_index and int(edge.get("end_station", -1)) != station_index:
			continue
		var parallel_group := int(edge.get("parallel_group", -1)
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
		if String(edge.get("kind", "")) == "station_transfer":
			continue
		var start_index := int(edge.get("start_station", -1))
		var end_index := int(edge.get("end_station", -1))
		if start_index != station_index and end_index != station_index:
			continue
		# Use the sampled endpoint tangent, not the station-to-station chord.
		# Curves and offset parallel lanes can enter a station at a very
		# different heading from the line joining the station centers.
		var direction := _get_track_edge_outward_tangent(edge, station_index)
		if direction == Vector2.ZERO:
			var neighbor_index := end_index if start_index == station_index else start_index
			if neighbor_index >= 0 and neighbor_index < stations.size():
				direction = (stations[neighbor_index] - stations[station_index]).normalized()
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
		# Do not use another curved edge (including the curve currently being
		# drawn) as the reference tangent. Straight and parallel approaches
		# define the turnout alignment; otherwise curve geometry can become
		# dependent on the order in which additional edges are added.
		if String(edge.get("kind", "")) == "curve" or String(edge.get("kind", "")) == "transition" or String(edge.get("kind", "")) == "station_transfer":
			continue
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

func _select_curve_mode() -> void:
	pending_track_start_node = -1
	pending_track_start_position = Vector2.ZERO
	build_mode = "" if build_mode == "curve" else "curve"
	curve_handle_dragging = false
	curve_handle_touch_index = -1
	editing_curve_index = -1
	pending_track_start = -1
	pending_curve_start = -1
	pending_curve_start_node = -1
	curve_stage = 0
	hud.set_mode(build_mode, "SELECT START STATION OR TRACK NODE" if build_mode == "curve" else "DRAG TO MOVE  ·  PINCH TO ZOOM")
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
	pending_track_start_node = -1
	pending_track_start_position = Vector2.ZERO
	build_mode = "" if build_mode == "station" else "station"
	pending_track_start = -1
	pending_curve_start = -1
	curve_stage = 0
	hud.set_mode(build_mode, "TAP TO PLACE STATIONS  ·  DRAG TO MOVE MAP" if build_mode == "station" else "DRAG TO MOVE  ·  PINCH TO ZOOM")

func _select_track_mode() -> void:
	pending_track_start_node = -1
	pending_track_start_position = Vector2.ZERO
	build_mode = "" if build_mode == "track" else "track"
	pending_track_start = -1
	pending_curve_start = -1
	curve_stage = 0
	hud.set_mode(build_mode, "TAP TWO STATIONS OR TRACK NODES TO CONNECT ONE TRACK" if build_mode == "track" else "DRAG TO MOVE  ·  PINCH TO ZOOM")

func _select_parallel_mode() -> void:
	pending_track_start_node = -1
	pending_track_start_position = Vector2.ZERO
	build_mode = "" if build_mode == "parallel" else "parallel"
	pending_track_start = -1
	pending_curve_start = -1
	curve_stage = 0
	hud.set_mode(build_mode, "TAP TWO STATIONS OR TRACK NODES TO PLACE PARALLEL TRACKS" if build_mode == "parallel" else "DRAG TO MOVE  ·  PINCH TO ZOOM")

func _select_parallel_curve_mode() -> void:
	pending_track_start_node = -1
	pending_track_start_position = Vector2.ZERO
	build_mode = "" if build_mode == "parallel_curve" else "parallel_curve"
	pending_track_start = -1
	pending_curve_start = -1
	pending_curve_start_node = -1
	curve_stage = 0
	hud.set_mode(build_mode, "TAP START  ·  DRAG SHARED CURVE HANDLE  ·  TAP END" if build_mode == "parallel_curve" else "DRAG TO MOVE  ·  PINCH TO ZOOM")

func _draw() -> void:
	_draw_station_platforms()
	_draw_canonical_track_edges()
	for path in junction_transition_paths:
		if path.size() > 1 and not _canonical_graph_contains_path(path):
			draw_polyline(path, Color(0.24, 0.86, 0.78), 7.0, true)
	if build_mode == "curve":
		for index in range(curve_segments.size()):
			_draw_completed_curve_handle(curve_segments[index], index == editing_curve_index)
	if (build_mode == "track" or build_mode == "parallel") and (pending_track_start >= 0 or pending_track_start_node >= 0):
		_draw_track_preview()
	if build_mode == "curve" and (pending_curve_start >= 0 or pending_curve_start_node >= 0):
		_draw_curve_preview()
	if build_mode == "parallel_curve" and (pending_curve_start >= 0 or pending_curve_start_node >= 0):
		_draw_parallel_curve_preview()
	if build_mode == "parallel_curve":
		for segment in parallel_curve_segments:
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
		if build_mode == "track" and index == pending_track_start:
			draw_arc(station, 23.0, 0.0, TAU, 32, Color(1.0, 1.0, 1.0), 2.0, true)

func _draw_station_platforms() -> void:
	for index in range(station_records.size()):
		var record: Dictionary = station_records[index]
		# Keep the resolved axis in the station model itself. Clearance and
		# later construction checks must use the same footprint as the renderer.
		if index < stations.size():
			record["rotation"] = StationModelScript.resolve_rotation(_get_station_track_directions(index), float(record.get("rotation", 0.0)))
			station_records[index] = record
		var footprint := StationModelScript.get_footprint(record)
		if footprint.size() != 4:
			continue
		draw_colored_polygon(footprint, Color(0.18, 0.28, 0.32, 0.92))
		var outline := footprint.duplicate()
		outline.append(footprint[0])
		draw_polyline(outline, Color(0.62, 0.82, 0.84, 0.9), 2.0, true)

func _draw_canonical_track_edges() -> void:
	for graph_edge_id in track_graph.get_edge_ids():
		var edge := track_graph.get_edge(int(graph_edge_id))
		var points: PackedVector2Array = edge.get("points", PackedVector2Array())
		if points.size() > 1 and bool(edge.get("renderable", true)):
			draw_polyline(points, Color(0.24, 0.86, 0.78), 7.0, true)

func _canonical_graph_contains_path(path: PackedVector2Array) -> bool:
	for graph_edge_id in track_graph.get_edge_ids():
		var edge := track_graph.get_edge(int(graph_edge_id))
		var graph_path: PackedVector2Array = edge.get("points", PackedVector2Array())
		if graph_path.size() != path.size():
			continue
		var matches := true
		for index in range(path.size()):
			if graph_path[index].distance_to(path[index]) > 0.01:
				matches = false
				break
		if matches:
			return true
	return false

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
	if node_id >= 0:
		return _get_lane_node_position(node_id, get_snapped_world_position(center))
	var station_index := _find_station_near_screen(center)
	if station_index >= 0:
		return stations[station_index]
	return get_snapped_world_position(center)

func _draw_parallel_curve_preview() -> void:
	var start_fallback: Vector2 = stations[pending_curve_start] if pending_curve_start >= 0 and pending_curve_start < stations.size() else Vector2.ZERO
	var start_point := _get_lane_node_position(pending_curve_start_node, start_fallback)
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
	var start_fallback: Vector2 = stations[pending_curve_start] if pending_curve_start >= 0 and pending_curve_start < stations.size() else Vector2.ZERO
	var start_point := _get_lane_node_position(pending_curve_start_node, start_fallback)
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
	var preview_start: Vector2 = pending_track_start_position
	var preview_node_id := _find_lane_node_near_screen(viewport_size * 0.5) if build_mode == "track" else -1
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
