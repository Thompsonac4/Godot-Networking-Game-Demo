# INFO Match networking, the lobby, and scoring

extends Node
const FPS_CONTROLLER = preload("uid://s2q2mk82khf6")
const FPS_CONTROLLER_RANGED = preload("res://Scenes/Player/fpsController_ranged.tscn")
const TUBE_CONTEXT = preload("uid://d27bcauc2t7a")
## The map every match loads. Swap this one line to change worlds.
const WORLD_SCENE = preload("res://Scenes/World/Map.tscn")
## Node name the map is given in the tree. Kept stable so replication paths
## match across peers no matter which map is loaded.
const WORLD_NODE_NAME := "World"
const MATCH_HUD = preload("res://Scenes/UI/MatchHUD.tscn")
const LOBBY_SCENE = preload("res://Scenes/UI/Lobby.tscn")
var tube_client := TubeClient.new()
var tube_enabled = true
var enet_peer := ENetMultiplayerPeer.new()
var _leaving := false

const CHARACTER_MELEE := "melee"
const CHARACTER_RANGED := "ranged"
const KILL_LIMIT := 10

const MODE_FFA := "ffa"
const MODE_TEAMS := "teams"

## Playlist entries. Enabled rules rotate after each round.
const RULE_DEATHMATCH := "deathmatch"
const RULE_POINT_CAPTURE := "point_capture"
const RULE_COIN_CHASE := "coin_chase"

const RULE_TITLES := {
	RULE_DEATHMATCH: "Deathmatch",
	RULE_POINT_CAPTURE: "Point Capture",
	RULE_COIN_CHASE: "Coin Chase",
}

const FFA_CAPTURE_COLORS := [
	Color(0.93, 0.28, 0.27),
	Color(0.29, 0.56, 0.96),
	Color(0.36, 0.83, 0.42),
	Color(0.97, 0.81, 0.24),
	Color(0.72, 0.42, 0.95),
	Color(0.95, 0.55, 0.18),
]

## Seconds the winner banner stays up before the next round starts.
const ROUND_INTERMISSION := 6.0
## Seconds players are locked in place at the start of every round.
const ROUND_COUNTDOWN := 5.0

signal lobby_changed
signal match_started
signal scores_changed
signal match_ended(winner_id: int)
signal round_started(round_number: int)
signal countdown_started
signal returned_to_lobby

var PORT = 9999
var IP_ADDRESS = '127.0.0.1'

## peer_id string -> { "name": String, "character": String, "team": int }
var lobby_members: Dictionary = {}
## peer_id string -> int
var scores: Dictionary = {}
var match_in_progress := false
var winner_id := -1
var winner_team := Teams.NONE
var round_number := 1
var countdown_remaining := 0.0
var match_time_remaining := 0.0

## Host-owned match settings, replicated with the member list.
var game_mode := MODE_FFA
var team_count := 2
var kill_limit := KILL_LIMIT
## Seconds. 0 means the clock is off and only the kill limit can end a round.
var time_limit := 0
var enabled_rules: PackedStringArray = PackedStringArray([RULE_DEATHMATCH])
var current_rule := RULE_DEATHMATCH
var _clock_pending := false
## team id -> next spawn marker index, so teammates do not stack up.
var _team_spawn_cursor := {}


## How long to negotiate a WebRTC connection with one peer, and how many
## tries. The addon defaults (2s x 3) leave only six seconds for hole
## punching, which a slow NAT or a UPnP mapping that has not opened yet can
## miss.
const PEER_SIGNALING_TIMEOUT := 4.0
const PEER_SIGNALING_ATTEMPTS := 6


# Starts the Tube client when online play is on
func _ready() -> void:
	if tube_enabled:
		tube_client.context = TUBE_CONTEXT
		tube_client.peer_signaling_timeout = PEER_SIGNALING_TIMEOUT
		tube_client.peer_signaling_max_attempts = PEER_SIGNALING_ATTEMPTS
		get_tree().root.add_child.call_deferred(tube_client)


## Tube reports signaling trouble through the same signal as real failures.
## Only these two mean this peer has no usable session. The signaling codes
## are documented as non-fatal: everyone already connected keeps playing and
## only *new* players are blocked from finding the session.
func is_fatal_session_error(code: int) -> bool:
	return (
		code == TubeClient.SessionError.CREATE_SESSION_FAILED
		or code == TubeClient.SessionError.JOIN_SESSION_FAILED
	)


## Whether a Tube error should tear this peer's session down.
func should_leave_on_error(code: int) -> bool:
	if _leaving or match_in_progress:
		return false
	if not is_fatal_session_error(code):
		return false
	# A host with players already in stays up. The failure belongs to whoever
	# was trying to join, and closing the session would drop the whole lobby.
	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		return multiplayer.get_peers().is_empty()
	return true

# Hosts a new online session
func tube_create():
	_reset_match_state()
	_connect_multiplayer_signals()
	tube_client.create_session()
	_set_member(multiplayer.get_unique_id(), Global.username, CHARACTER_MELEE)
	lobby_changed.emit()

# Joins an online session by its code
func tube_join(session_id: String):
	_reset_match_state()
	_connect_multiplayer_signals()
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_lobby):
		multiplayer.connected_to_server.connect(_on_connected_to_lobby)
	tube_client.join_session(session_id)

# Starts a local ENet server
func start_server():
	enet_peer.create_server(PORT)
	multiplayer.multiplayer_peer = enet_peer
	_connect_multiplayer_signals()
	
# Joins the local ENet server
func join_server():
	enet_peer.create_client(IP_ADDRESS, PORT)
	_connect_multiplayer_signals()
	multiplayer.connected_to_server.connect(on_connected_to_server)
	multiplayer.multiplayer_peer = enet_peer

# Spawns this player after a local server connect
func on_connected_to_server():
	add_player(multiplayer.get_unique_id())


# Sends this player's name and character to the host
func _on_connected_to_lobby() -> void:
	submit_lobby_profile.rpc_id(1, Global.username, CHARACTER_MELEE)


# Display name for a player in the lobby
func get_member_name(peer_id: int) -> String:
	var key := str(peer_id)
	if lobby_members.has(key):
		return str(lobby_members[key].get("name", "Player"))
	return "Player"


# Team id for a player, or none
func get_member_team(peer_id: int) -> int:
	var member: Dictionary = lobby_members.get(str(peer_id), {})
	return int(member.get("team", Teams.NONE))


# Color of a player's team
func team_color(peer_id: int) -> Color:
	return Teams.color(get_member_team(peer_id))


## True only in a team match when both players share a team. Damage sources
## use this to skip friendly fire.
func are_allies(a_id: int, b_id: int) -> bool:
	if game_mode != MODE_TEAMS:
		return false
	var team := get_member_team(a_id)
	return team != Teams.NONE and team == get_member_team(b_id)


# Picks melee or ranged and tells the host
func select_character(character: String) -> void:
	if multiplayer.is_server():
		_set_member(multiplayer.get_unique_id(), Global.username, character)
		_broadcast_lobby()
	else:
		submit_lobby_profile.rpc_id(1, Global.username, character)


# Host stores a player's name and character
@rpc("any_peer", "reliable")
func submit_lobby_profile(player_name: String, character: String) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	_set_member(sender_id, player_name, character)
	_broadcast_lobby()


# ============================================================
# TEAM SETUP (host only)
# ============================================================

# Host switches between free for all and teams
func host_set_game_mode(mode: String) -> void:
	if not multiplayer.is_server():
		return
	game_mode = MODE_TEAMS if mode == MODE_TEAMS else MODE_FFA
	_rebalance_teams()
	_broadcast_lobby()


# Host sets how many points end a round
func host_set_kill_limit(value: int) -> void:
	if not multiplayer.is_server():
		return
	kill_limit = clampi(value, 1, 99)
	_broadcast_lobby()


# Host sets the round clock. Zero turns it off
func host_set_time_limit(seconds: int) -> void:
	if not multiplayer.is_server():
		return
	time_limit = maxi(seconds, 0)
	_broadcast_lobby()


# Host turns a playlist rule on or off
func host_set_rule(rule: String, on: bool) -> void:
	if not multiplayer.is_server():
		return
	if not _is_known_rule(rule) or not _is_playable_rule(rule):
		return
	var next := PackedStringArray()
	for existing in enabled_rules:
		if existing != rule:
			next.append(existing)
	if on:
		next.append(rule)
	if _playlist_from(next).is_empty():
		next.append(RULE_DEATHMATCH)
	enabled_rules = next
	if not _playlist().has(current_rule):
		current_rule = _first_playlist_rule()
	_broadcast_lobby()


# True if that rule is in the playlist
func has_rule(rule: String) -> bool:
	return enabled_rules.has(rule)


# Display name for the current rule
func rule_title(rule: String = "") -> String:
	var key := rule if rule != "" else current_rule
	return String(RULE_TITLES.get(key, "Match"))


# Next rule in the playlist after this round
func next_rule() -> String:
	var rules := _playlist()
	if rules.is_empty():
		return current_rule
	var idx := rules.find(current_rule)
	return rules[(idx + 1) % rules.size()]


# Who a capture point counts as. A team in team modes, the player otherwise
func capture_side(peer_id: int) -> int:
	if is_team_match():
		return get_member_team(peer_id)
	return peer_id


# Color used on a capture point for that side
func capture_color(side: int) -> Color:
	if is_team_match():
		return Teams.color(side)
	return FFA_CAPTURE_COLORS[absi(side) % FFA_CAPTURE_COLORS.size()]


# True if this is a rule the game knows about
func _is_known_rule(rule: String) -> bool:
	return (
		rule == RULE_DEATHMATCH
		or rule == RULE_POINT_CAPTURE
		or rule == RULE_COIN_CHASE
	)


# True if that rule can actually be played right now
func _is_playable_rule(rule: String) -> bool:
	return rule == RULE_DEATHMATCH or rule == RULE_POINT_CAPTURE


# Rules that will rotate, in playlist order
func _playlist() -> PackedStringArray:
	return _playlist_from(enabled_rules)


# Keeps only the playable rules, in a fixed order
func _playlist_from(rules: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for rule in [RULE_DEATHMATCH, RULE_POINT_CAPTURE, RULE_COIN_CHASE]:
		if rules.has(rule) and _is_playable_rule(rule):
			out.append(rule)
	return out


# First rule a match should start on
func _first_playlist_rule() -> String:
	var rules := _playlist()
	if rules.is_empty():
		return RULE_DEATHMATCH
	return rules[0]


# Moves to the next rule in the playlist
func _advance_rule() -> void:
	current_rule = next_rule()


# True when the lobby is in team mode
func is_team_match() -> bool:
	return game_mode == MODE_TEAMS


# Adds up every player's score on one team
func get_team_score(team: int) -> int:
	var total := 0
	if team == Teams.NONE:
		return 0
	for id_str in lobby_members:
		if int(lobby_members[id_str].get("team", Teams.NONE)) == team:
			total += int(scores.get(id_str, 0))
	return total


# Host sets how many teams are in play
func host_set_team_count(count: int) -> void:
	if not multiplayer.is_server():
		return
	team_count = clampi(count, Teams.MIN_COUNT, Teams.MAX_COUNT)
	_rebalance_teams()
	_broadcast_lobby()


# Host moves one player onto a team
func host_assign_team(peer_id: int, team: int) -> void:
	if not multiplayer.is_server() or game_mode != MODE_TEAMS:
		return
	var key := str(peer_id)
	if not lobby_members.has(key) or not Teams.active(team_count).has(team):
		return
	var member: Dictionary = lobby_members[key]
	member["team"] = team
	lobby_members[key] = member
	_broadcast_lobby()


## Drops everyone to no team in free-for-all, or pulls anyone sitting on a
## team that is no longer in play onto the emptiest one.
func _rebalance_teams() -> void:
	for key in lobby_members:
		if game_mode == MODE_TEAMS:
			_ensure_valid_team(key)
		else:
			var member: Dictionary = lobby_members[key]
			member["team"] = Teams.NONE
			lobby_members[key] = member


# Puts a player on a team that is still in play
func _ensure_valid_team(key: String) -> void:
	var member: Dictionary = lobby_members.get(key, {})
	if member.is_empty():
		return
	if Teams.active(team_count).has(int(member.get("team", Teams.NONE))):
		return
	member["team"] = _emptiest_team(key)
	lobby_members[key] = member


# Team with the fewest players
func _emptiest_team(skip_key: String) -> int:
	var active := Teams.active(team_count)
	var counts := {}
	for id in active:
		counts[id] = 0
	for id_str in lobby_members:
		if id_str == skip_key:
			continue
		var member_team := int(lobby_members[id_str].get("team", Teams.NONE))
		if counts.has(member_team):
			counts[member_team] = int(counts[member_team]) + 1

	var best := int(active[0])
	for id in active:
		if int(counts[id]) < int(counts[best]):
			best = int(id)
	return best


# Sends the lobby roster and settings to everyone
func _broadcast_lobby() -> void:
	sync_lobby.rpc(
		lobby_members,
		game_mode,
		team_count,
		enabled_rules,
		kill_limit,
		time_limit
	)


# Applies the lobby roster the host sent
@rpc("authority", "call_local", "reliable")
func sync_lobby(
	members: Dictionary,
	mode: String,
	count: int,
	rules: PackedStringArray,
	kills: int,
	seconds: int
) -> void:
	lobby_members = members
	game_mode = mode
	team_count = count
	enabled_rules = rules
	if enabled_rules.is_empty():
		enabled_rules = PackedStringArray([RULE_DEATHMATCH])
	kill_limit = maxi(kills, 1)
	time_limit = maxi(seconds, 0)
	lobby_changed.emit()


# Host starts the match
func host_start_match() -> void:
	if not multiplayer.is_server():
		return
	if lobby_members.is_empty():
		return
	begin_match.rpc()


# Host sends everyone back to the lobby
func host_return_to_lobby() -> void:
	if not multiplayer.is_server():
		return
	return_to_lobby.rpc()


# Clears the match and opens the lobby again
@rpc("authority", "call_local", "reliable")
func return_to_lobby() -> void:
	match_in_progress = false
	winner_id = -1
	round_number = 1
	countdown_remaining = 0.0
	match_time_remaining = 0.0
	_clock_pending = false
	winner_team = Teams.NONE
	scores.clear()
	scores_changed.emit()

	var tree := get_tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene == null:
		return

	for player in tree.get_nodes_in_group("Players"):
		player.queue_free()

	var world := scene.get_node_or_null(WORLD_NODE_NAME)
	if world:
		world.queue_free()
	Global.world = null
	Global.spawn_container = null

	var hud := scene.get_node_or_null("MatchHUD")
	if hud:
		hud.queue_free()

	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if scene.get_node_or_null("Lobby") == null:
		var lobby := LOBBY_SCENE.instantiate()
		lobby.name = "Lobby"
		scene.add_child(lobby)

	returned_to_lobby.emit()
	lobby_changed.emit()


# Loads the map, spawns players, and starts the countdown
@rpc("authority", "call_local", "reliable")
func begin_match() -> void:
	match_in_progress = true
	winner_id = -1
	winner_team = Teams.NONE
	round_number = 1
	current_rule = _first_playlist_rule()
	scores.clear()
	for id_str in lobby_members:
		scores[id_str] = 0
	scores_changed.emit()
	_load_match_world()
	spawn_match_players()
	if multiplayer.is_server():
		Global.spawn_match_pickups()
	match_started.emit()
	_start_round_countdown()


# Loads the map and the match hud if they are not already there
func _load_match_world() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	if scene.get_node_or_null(WORLD_NODE_NAME) == null and Global.world == null:
		var world := WORLD_SCENE.instantiate()
		world.name = WORLD_NODE_NAME
		scene.add_child(world)
	if scene.get_node_or_null("MatchHUD") == null:
		var hud := MATCH_HUD.instantiate()
		hud.name = "MatchHUD"
		scene.add_child(hud)


# Spawns one player for everyone in the lobby
func spawn_match_players() -> void:
	_team_spawn_cursor.clear()
	for id_str in lobby_members:
		add_player(int(id_str))


# Gives a deathmatch point to the killer
func register_kill(killer_id: int) -> void:
	GameAudio.play_for(killer_id, "kill_confirm", 0.0, 1.5)
	if current_rule != RULE_DEATHMATCH:
		return
	_add_score(killer_id, get_member_team(killer_id))


# Gives a point for capturing the point
func register_capture(side: int) -> void:
	if not multiplayer.is_server():
		return
	if current_rule != RULE_POINT_CAPTURE:
		return
	var peer_id := side
	var team := Teams.NONE
	if is_team_match():
		team = side
		peer_id = _first_peer_on_team(side)
	_add_score(peer_id, team)


# Adds one point and ends the round if the limit is hit
func _add_score(peer_id: int, team: int) -> void:
	if not multiplayer.is_server():
		return
	if not match_in_progress or winner_id != -1 or is_round_locked():
		return
	var key := str(peer_id)
	if peer_id <= 0 or not lobby_members.has(key):
		if team == Teams.NONE:
			return
		peer_id = _first_peer_on_team(team)
		key = str(peer_id)
		if peer_id <= 0 or not lobby_members.has(key):
			return
	if not scores.has(key):
		scores[key] = 0
	scores[key] = int(scores[key]) + 1
	sync_scores.rpc(scores)
	if is_team_match():
		if team == Teams.NONE:
			team = get_member_team(peer_id)
		if team != Teams.NONE and get_team_score(team) >= kill_limit:
			_end_round(peer_id, team)
		return
	if int(scores[key]) >= kill_limit:
		_end_round(peer_id, Teams.NONE)


## Waits out the winner banner, then rolls straight into another round
## instead of dropping everyone back to the lobby.
func _queue_next_round() -> void:
	await get_tree().create_timer(ROUND_INTERMISSION).timeout
	if not multiplayer.is_server():
		return
	# The host may have gone back to the lobby or left while we waited.
	if match_in_progress or Global.world == null or lobby_members.is_empty():
		return
	_advance_rule()
	start_next_round.rpc(current_rule)


# Resets scores and starts the next round
@rpc("authority", "call_local", "reliable")
func start_next_round(rule: String = "") -> void:
	if rule != "":
		current_rule = rule
	round_number += 1
	winner_id = -1
	winner_team = Teams.NONE
	match_in_progress = true
	for id_str in lobby_members:
		scores[id_str] = 0
	scores_changed.emit()
	round_started.emit(round_number)
	_start_round_countdown()

	if multiplayer.is_server():
		Global.reset_pickups()
		for node in get_tree().get_nodes_in_group("Players"):
			var health: Node = node.get_node_or_null("health_controller")
			if health and health.has_method("round_reset"):
				var spawn := pick_spawn_transform(int(str(node.name)))
				health.round_reset.rpc(spawn.origin, spawn.basis.get_euler().y)


# Applies the scoreboard the host sent
@rpc("authority", "call_local", "reliable")
func sync_scores(new_scores: Dictionary) -> void:
	scores = new_scores
	scores_changed.emit()


# Names the winner and queues the next round
func _end_round(peer_id: int, team: int) -> void:
	if not multiplayer.is_server():
		return
	winner_id = peer_id
	winner_team = team
	announce_winner.rpc(peer_id, team)
	_queue_next_round()


# Ends the round for whoever is ahead when the clock hits zero
func _end_round_by_time() -> void:
	if not multiplayer.is_server():
		return
	if is_team_match():
		var best_team := Teams.NONE
		var best_score := -1
		for team in Teams.active(team_count):
			var total := get_team_score(int(team))
			if total > best_score:
				best_score = total
				best_team = int(team)
		var representative := _first_peer_on_team(best_team)
		_end_round(representative, best_team)
		return
	var best_id := -1
	var best_kills := -1
	for id_str in lobby_members:
		var kills := int(scores.get(id_str, 0))
		if kills > best_kills:
			best_kills = kills
			best_id = int(id_str)
	_end_round(best_id, Teams.NONE)


# One player on that team, used when a team scores
func _first_peer_on_team(team: int) -> int:
	for id_str in lobby_members:
		if int(lobby_members[id_str].get("team", Teams.NONE)) == team:
			return int(id_str)
	return -1


# Shows the winner and stops the match clock
@rpc("authority", "call_local", "reliable")
func announce_winner(peer_id: int, team: int = 0) -> void:
	winner_id = peer_id
	winner_team = team
	match_in_progress = false
	match_time_remaining = 0.0
	_clock_pending = false
	match_ended.emit(peer_id)


# Melee or ranged player scene for this lobby member
func _player_scene_for(peer_id: int) -> PackedScene:
	var member: Dictionary = lobby_members.get(str(peer_id), {})
	if str(member.get("character", CHARACTER_MELEE)) == CHARACTER_RANGED:
		return FPS_CONTROLLER_RANGED
	return FPS_CONTROLLER


# Spawns a player on a random pad for their team
func add_player(peer_id: int):
	if peer_id == 1 and multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		return
	var scene := get_tree().current_scene
	if scene == null or scene.get_node_or_null(str(peer_id)) != null:
		return
	var new_player = _player_scene_for(peer_id).instantiate()
	new_player.name = str(peer_id)
	var spawn := pick_spawn_transform(peer_id)
	new_player.position = spawn.origin
	new_player.rotation.y = spawn.basis.get_euler().y
	scene.add_child(new_player, true)


## Random pad each time. FFA uses every team platform; teams stay on
## their own colour. Spawners already look at the castle.
func pick_spawn_transform(peer_id: int) -> Transform3D:
	var spawns := _spawn_markers_for(peer_id)
	if spawns.is_empty():
		spawns = _player_spawn_markers()
	if spawns.is_empty():
		return Transform3D(Basis.IDENTITY, Vector3(
			randf_range(-4.0, 4.0), 1.0, randf_range(-4.0, 4.0)
		))

	var marker: Node3D = spawns[randi() % spawns.size()]
	var pos := marker.global_position
	if marker.has_method("spawn_position"):
		pos = marker.spawn_position()
	var yaw := marker.global_transform.basis.get_euler().y
	return Transform3D(Basis.from_euler(Vector3(0.0, yaw, 0.0)), pos)


# Spawn pads this player is allowed to use
func _spawn_markers_for(peer_id: int) -> Array[Node3D]:
	if game_mode != MODE_TEAMS or get_member_team(peer_id) == Teams.NONE:
		return _all_team_spawn_markers()
	var exact := _team_spawn_markers(get_member_team(peer_id))
	if not exact.is_empty():
		return exact
	return _all_team_spawn_markers()


# Every team spawn pad on the map
func _all_team_spawn_markers() -> Array[Node3D]:
	var markers: Array[Node3D] = []
	if not is_inside_tree():
		return markers
	for node in get_tree().get_nodes_in_group(Teams.SPAWN_GROUP):
		if node is Node3D:
			markers.append(node as Node3D)
	return markers


## Spawners for one team, falling back to the map's "Any" spawners.
func _team_spawn_markers(team: int) -> Array[Node3D]:
	var exact: Array[Node3D] = []
	var neutral: Array[Node3D] = []
	for node in get_tree().get_nodes_in_group(Teams.SPAWN_GROUP):
		if not node is Node3D:
			continue
		var spawn_team := int(node.get("team"))
		if spawn_team == Teams.NONE:
			neutral.append(node as Node3D)
		elif spawn_team == team:
			exact.append(node as Node3D)
	return exact if not exact.is_empty() else neutral


# Older PlayerSpawns folder, used if the map has no team pads
func _player_spawn_markers() -> Array[Node3D]:
	var markers: Array[Node3D] = []
	if Global.world == null:
		return markers
	var holder := Global.world.get_node_or_null("PlayerSpawns")
	if holder == null:
		return markers
	for child in holder.get_children():
		if child is Node3D:
			markers.append(child as Node3D)
	return markers
	
# Removes a player who left, or leaves if the host did
func remove_player(peer_id):
	if peer_id == 1:
		leave_server()
		return
	var players: Array[Node] = get_tree().get_nodes_in_group('Players')
	var player_to_remove = players.find_custom(func(item): return item.name == str(peer_id))
	if player_to_remove != -1:
		players[player_to_remove].queue_free()
	
# Drops the session and reloads back to the menu
func leave_server():
	if _leaving:
		return
	_leaving = true
	if tube_enabled:
		tube_client.leave_session()
		
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	clean_up_signals()
	_reset_match_state()
	var tree := get_tree()
	if tree != null and tree.current_scene != null:
		tree.reload_current_scene()
	_leaving = false

# Listens for players joining and leaving
func _connect_multiplayer_signals() -> void:
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)

# Stops listening to multiplayer signals
func clean_up_signals():
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
	if multiplayer.connected_to_server.is_connected(on_connected_to_server):
		multiplayer.connected_to_server.disconnect(on_connected_to_server)
	if multiplayer.connected_to_server.is_connected(_on_connected_to_lobby):
		multiplayer.connected_to_server.disconnect(_on_connected_to_lobby)


# Sends the lobby to a player who just joined
func _on_peer_connected(peer_id: int) -> void:
	if multiplayer.is_server():
		# Late joiners need the roster too, or their nameplates have no
		# name and no team colour.
		sync_lobby.rpc_id(
			peer_id,
			lobby_members,
			game_mode,
			team_count,
			enabled_rules,
			kill_limit,
			time_limit
		)
		sync_current_rule.rpc_id(peer_id, current_rule)
		if countdown_remaining > 0.0:
			sync_countdown.rpc_id(peer_id, countdown_remaining)
		elif match_time_remaining > 0.0:
			sync_clock.rpc_id(peer_id, match_time_remaining)
	if match_in_progress:
		add_player(peer_id)


# Drops a player who left, or leaves if the host did
func _on_peer_disconnected(peer_id: int) -> void:
	if peer_id == 1:
		leave_server()
		return
	lobby_members.erase(str(peer_id))
	scores.erase(str(peer_id))
	lobby_changed.emit()
	scores_changed.emit()
	if match_in_progress:
		remove_player(peer_id)
	if multiplayer.is_server():
		_broadcast_lobby()


# Stores a lobby member, keeping the team they already have
func _set_member(peer_id: int, player_name: String, character: String) -> void:
	var cleaned := player_name.strip_edges()
	if cleaned == "":
		cleaned = "Player"
	if character == "" or (character != CHARACTER_MELEE and character != CHARACTER_RANGED):
		character = CHARACTER_MELEE
	var key := str(peer_id)
	# Keep whatever team the host already put them on.
	var existing: Dictionary = lobby_members.get(key, {})
	lobby_members[key] = {
		"name": cleaned,
		"character": character,
		"team": int(existing.get("team", Teams.NONE)),
	}
	if game_mode == MODE_TEAMS:
		_ensure_valid_team(key)


# Clears scores, teams, and the clock back to a fresh lobby
func _reset_match_state() -> void:
	lobby_members.clear()
	scores.clear()
	match_in_progress = false
	winner_id = -1
	winner_team = Teams.NONE
	game_mode = MODE_FFA
	team_count = 2
	kill_limit = KILL_LIMIT
	time_limit = 0
	enabled_rules = PackedStringArray([RULE_DEATHMATCH])
	current_rule = RULE_DEATHMATCH
	countdown_remaining = 0.0
	match_time_remaining = 0.0
	_clock_pending = false
	_team_spawn_cursor.clear()


# True during the countdown at the start of a round
func is_round_locked() -> bool:
	return countdown_remaining > 0.0


# Locks players in place and starts the countdown
func _start_round_countdown() -> void:
	countdown_remaining = ROUND_COUNTDOWN
	match_time_remaining = 0.0
	_clock_pending = time_limit > 0
	countdown_started.emit()


# Applies the rule the host is running
@rpc("authority", "call_local", "reliable")
func sync_current_rule(rule: String) -> void:
	if _is_playable_rule(rule):
		current_rule = rule


# Applies the countdown a late joiner needs
@rpc("authority", "call_local", "reliable")
func sync_countdown(remaining: float) -> void:
	countdown_remaining = remaining
	if remaining > 0.0:
		countdown_started.emit()


# Applies the match clock a late joiner needs
@rpc("authority", "call_local", "reliable")
func sync_clock(remaining: float) -> void:
	match_time_remaining = remaining
	_clock_pending = false


# Turns seconds into a minutes and seconds string
func format_clock(seconds: float) -> String:
	var total := maxi(int(ceil(seconds)), 0)
	return "%d:%02d" % [total / 60, total % 60]


# Counts down the round lock, then the match clock
func _process(delta: float) -> void:
	if countdown_remaining > 0.0:
		countdown_remaining = maxf(countdown_remaining - delta, 0.0)
		if countdown_remaining > 0.0:
			return
		if _clock_pending:
			match_time_remaining = float(time_limit)
			_clock_pending = false
		return

	if not match_in_progress or winner_id != -1:
		return
	if match_time_remaining <= 0.0:
		return
	match_time_remaining = maxf(match_time_remaining - delta, 0.0)
	if match_time_remaining <= 0.0 and multiplayer.is_server():
		_end_round_by_time()


# Leaves the online session when this node is freed
func _exit_tree() -> void:
	if tube_enabled:
		tube_client.leave_session()
