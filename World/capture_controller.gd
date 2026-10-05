# INFO Runs the capture point during a match

extends Node

const CAPTURE_SECONDS := 10.0

var _active_index := -1
var _progress := 0.0
var _side := 0
var _contested := false
var _sync_accum := 0.0


# Listens for the match starting, a new round, and the match ending
func _ready() -> void:
	if not Network.match_started.is_connected(_on_match_flow):
		Network.match_started.connect(_on_match_flow)
	if not Network.round_started.is_connected(_on_round_started):
		Network.round_started.connect(_on_round_started)
	if not Network.match_ended.is_connected(_on_match_ended):
		Network.match_ended.connect(_on_match_ended)
	call_deferred("_boot")


# Finds the points and turns one on if this is a capture round
func _boot() -> void:
	_index_points()
	if Network.current_rule != Network.RULE_POINT_CAPTURE:
		_set_all_idle()
		return
	if multiplayer.is_server() and _active_index < 0:
		_activate_random(-1)


# Stops listening when this node is freed
func _exit_tree() -> void:
	if Network.match_started.is_connected(_on_match_flow):
		Network.match_started.disconnect(_on_match_flow)
	if Network.round_started.is_connected(_on_round_started):
		Network.round_started.disconnect(_on_round_started)
	if Network.match_ended.is_connected(_on_match_ended):
		Network.match_ended.disconnect(_on_match_ended)


# Sets the points up again at the start of a round
func _on_round_started(_round_number: int) -> void:
	_on_match_flow()


# Turns capture on or off based on the current rule
func _on_match_flow() -> void:
	if Network.current_rule != Network.RULE_POINT_CAPTURE:
		_active_index = -1
		_progress = 0.0
		_side = 0
		_contested = false
		_set_all_idle()
		return
	if multiplayer.is_server():
		_activate_random(-1)


# Shuts the points off when the round ends
func _on_match_ended(_winner_id: int) -> void:
	if multiplayer.is_server():
		_broadcast_idle()


# Advances the active point while players stand on it
func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	if Network.current_rule != Network.RULE_POINT_CAPTURE:
		return
	if not Network.match_in_progress or Network.winner_id != -1:
		return
	if Network.is_round_locked():
		return
	var point: Node = _active_point()
	if point == null or not point.has_method("living_players"):
		_activate_random(-1)
		return

	var occupants: Array[Node] = []
	var raw: Variant = point.call("living_players")
	if raw is Array:
		for item in raw:
			if item is Node:
				occupants.append(item)
	var sides: Array[int] = []
	for player in occupants:
		var capture_side := Network.capture_side(int(str(player.name)))
		if capture_side != 0 and not sides.has(capture_side):
			sides.append(capture_side)

	_contested = sides.size() > 1
	if sides.size() == 1:
		var next_side := sides[0]
		if next_side != _side:
			_side = next_side
			_progress = 0.0
		_progress = minf(_progress + delta / CAPTURE_SECONDS, 1.0)
		if _progress >= 1.0:
			_finish_capture()
			return
	elif sides.is_empty():
		pass

	_sync_accum += delta
	if _sync_accum >= 0.12:
		_sync_accum = 0.0
		_broadcast_state()


# Scores the capture and moves the point somewhere else
func _finish_capture() -> void:
	var scorer := _side
	var previous := _active_index
	GameAudio.sfx_all("point_capture", 0.06, 0.0, _capture_origin())
	Network.register_capture(scorer)
	_progress = 0.0
	_side = 0
	_contested = false
	if Network.match_in_progress and Network.winner_id == -1:
		_activate_random(previous)
	else:
		_broadcast_idle()


# Turns on a random point, skipping the one that just finished
func _activate_random(except_index: int) -> void:
	var points := _points()
	if points.is_empty():
		return
	var choices: Array[int] = []
	for i in points.size():
		if i != except_index:
			choices.append(i)
	if choices.is_empty():
		choices.append(0)
	_active_index = choices[randi() % choices.size()]
	_progress = 0.0
	_side = 0
	_contested = false
	_broadcast_state()


# Tells everyone every point is off
func _broadcast_idle() -> void:
	_active_index = -1
	_progress = 0.0
	_side = 0
	_contested = false
	sync_state.rpc(-1, 0.0, 0, false)


# Sends the active point's progress to everyone
func _broadcast_state() -> void:
	sync_state.rpc(_active_index, _progress, _side, _contested)


# Applies the capture state the server sent
@rpc("authority", "call_local", "reliable")
func sync_state(index: int, amount: float, capture_side: int, is_contested: bool) -> void:
	_active_index = index
	_progress = amount
	_side = capture_side
	_contested = is_contested
	var points := _points()
	for i in points.size():
		points[i].apply_state(i == index, amount if i == index else 0.0, capture_side, is_contested and i == index)
	GameAudio.notify_capture_state(
		index,
		amount > 0.0 and capture_side != 0,
		is_contested,
		_point_origin(index)
	)


# Turns every point off
func _set_all_idle() -> void:
	for point in _points():
		point.apply_state(false, 0.0, 0, false)


# World position of the point that is live
func _capture_origin() -> Vector3:
	return _point_origin(_active_index)


# World position of one point
func _point_origin(index: int) -> Vector3:
	var points := _points()
	if index < 0 or index >= points.size():
		return Vector3.INF
	var point := points[index]
	if point is Node3D:
		return (point as Node3D).global_position
	return Vector3.INF


# The point that is currently live
func _active_point() -> Node:
	var points: Array[Node] = _points()
	if _active_index < 0 or _active_index >= points.size():
		return null
	return points[_active_index]


# Every capture point on the map
func _points() -> Array[Node]:
	var found: Array[Node] = []
	if not is_inside_tree():
		return found
	for node in get_tree().get_nodes_in_group("CapturePoints"):
		if node is Node:
			found.append(node)
	found.sort_custom(func(a, b): return str(a.name) < str(b.name))
	_index_points(found)
	return found


# Gives each point a stable index
func _index_points(points: Array[Node] = []) -> void:
	if points.is_empty() and is_inside_tree():
		for node in get_tree().get_nodes_in_group("CapturePoints"):
			if node is Node:
				points.append(node)
		points.sort_custom(func(a, b): return str(a.name) < str(b.name))
	for i in points.size():
		points[i].set("point_index", i)
