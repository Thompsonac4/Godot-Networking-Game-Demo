# INFO Plays music and sound effects, and keeps the volume sliders

extends Node

signal volumes_changed

const BUS_MUSIC := "Music"
const BUS_SFX := "SFX"
const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "audio"
const POOL_SIZE := 16

const STREAMS := {
	"menu_music": "res://Assets/Sounds/Menu Music.wav",
	"game_music_1": "res://Assets/Sounds/Game Music 1.wav",
	"game_music_2": "res://Assets/Sounds/Game Music 2.wav",
	"game_music_3": "res://Assets/Sounds/Game Music 3.wav",
	"game_won": "res://Assets/Sounds/Game Won.wav",
	"game_lost": "res://Assets/Sounds/Game Lost.wav",
	"ball_throw": "res://Assets/Sounds/ball throw.wav",
	"player_hit_shovel": "res://Assets/Sounds/Player Hit Shovel.wav",
	"ice_freezing": "res://Assets/Sounds/Ice Freezing.wav",
	"firework_flying": "res://Assets/Sounds/Firework Flying.wav",
	"bow_draw": "res://Assets/Sounds/Bow Draw.wav",
	"block_hit": "res://Assets/Sounds/Block Hit.wav",
	"arrow_hit": "res://Assets/Sounds/Arrow Hit.wav",
	"bow_release": "res://Assets/Sounds/Bow Release.wav",
	"block_break": "res://Assets/Sounds/Block Break.wav",
	"block_ready": "res://Assets/Sounds/Block Ready.wav",
	"firework_start": "res://Assets/Sounds/Firework Start.wav",
	"jumppad": "res://Assets/Sounds/Jumppad.wav",
	"item_pickup": "res://Assets/Sounds/Item Pickup.wav",
	"soda_crack": "res://Assets/Sounds/Soda Crack.wav",
	"player_run": "res://Assets/Sounds/Player Run.wav",
	"respawn": "res://Assets/Sounds/Respawn.wav",
	"menu_select": "res://Assets/Sounds/Menu Select.wav",
	"shovel_swing": "res://Assets/Sounds/Shovel Swing.wav",
	"mudball_hit": "res://Assets/Sounds/Mudball Hit.wav",
	"point_spawn": "res://Assets/Sounds/Point Spawn.wav",
	"soda_drinking": "res://Assets/Sounds/Soda Drinking.wav",
	"player_death": "res://Assets/Sounds/Player Death.wav",
	"player_jump": "res://Assets/Sounds/Player Jump.wav",
	"point_contested": "res://Assets/Sounds/Point Contested.wav",
	"shovel_hit": "res://Assets/Sounds/Shovel Hit.wav",
	"point_capture": "res://Assets/Sounds/Point Capture.wav",
	"player_damage": "res://Assets/Sounds/Player Damage Noise.wav",
	"point_capturing": "res://Assets/Sounds/Point Capturing.wav",
	"healing": "res://Assets/Sounds/Healing.mp3",
	"kill_confirm": "res://Assets/Sounds/Kill Confirm.mp3",
}

const PITCH := {
	"shovel_hit": 0.76,
	"point_capture": 0.74,
}

const GAIN := {
	"point_spawn": 0.08,
	"point_contested": 1.0 / 3.0,
	"point_capture": 1.0 / 3.0,
	"point_capturing": 1.0 / 3.0,
}

const ATTEN_NEAR := 8.0
const ATTEN_FAR := 52.0

const GAME_MUSIC_GAIN := 2.2

var sfx_volume := 0.85
var music_volume := 0.7

var _loaded: Dictionary = {}
var _pool: Array[AudioStreamPlayer] = []
var _pool_index := 0
var _loops: Dictionary = {}
var _music: AudioStreamPlayer
var _music_gain := 1.0
var _last_capture_index := -2
var _last_contested := false
var _volume_sliders: Array[Dictionary] = []


# Sets up the buses, the sound pool, and the menu music
func _ready() -> void:
	_ensure_buses()
	_load_settings()
	_load_streams()
	_music = AudioStreamPlayer.new()
	_music.bus = BUS_MUSIC
	add_child(_music)
	for i in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = BUS_SFX
		add_child(player)
		_pool.append(player)
	_apply_volumes()
	volumes_changed.connect(_sync_volume_sliders)

	_apply_borderless_fullscreen()
	if Network.has_signal("match_started"):
		Network.match_started.connect(_on_match_started)
	if Network.has_signal("returned_to_lobby"):
		Network.returned_to_lobby.connect(_on_returned_to_lobby)
	if Network.has_signal("match_ended"):
		Network.match_ended.connect(_on_match_ended)
	play_music("menu_music")


# Plays a sound effect once, quieter when it is far from the local player
func play_sfx(
	id: String,
	pitch_vary: float = 0.06,
	max_seconds: float = 0.0,
	from: Vector3 = Vector3.INF
) -> void:
	var stream := _get_stream(id)
	if stream == null or _pool.is_empty():
		return
	var dist_gain := _distance_gain(from)
	if dist_gain <= 0.001:
		return
	var player := _free_voice()
	var gen := int(player.get_meta("play_gen", 0)) + 1
	player.set_meta("play_gen", gen)
	player.stop()
	player.stream = stream
	player.bus = BUS_SFX
	player.set_meta("clip_id", id)
	player.volume_db = _clip_db(id, sfx_volume * dist_gain)
	var base_pitch := float(PITCH.get(id, 1.0))
	player.pitch_scale = base_pitch + randf_range(-pitch_vary, pitch_vary)
	player.play()
	if max_seconds > 0.0:
		_stop_after(player, gen, max_seconds)


# Plays a sound here and tells every other player to play it too
func sfx_all(
	id: String,
	pitch_vary: float = 0.06,
	max_seconds: float = 0.0,
	from: Vector3 = Vector3.INF
) -> void:
	play_sfx(id, pitch_vary, max_seconds, from)
	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		_rpc_sfx.rpc(id, pitch_vary, max_seconds, from)


# Plays a sound at a world position and syncs it from the server
func sfx_at(
	id: String,
	origin: Vector3,
	pitch_vary: float = 0.06,
	max_seconds: float = 0.0
) -> void:
	play_sfx(id, pitch_vary, max_seconds, origin)
	if multiplayer.multiplayer_peer == null:
		return
	if multiplayer.is_server():
		_rpc_sfx.rpc(id, pitch_vary, max_seconds, origin)
	else:
		_request_sfx.rpc_id(1, id, pitch_vary, max_seconds, origin)


# Plays a sound for one player only
func play_for(
	peer_id: int,
	id: String,
	pitch_vary: float = 0.0,
	max_seconds: float = 0.0
) -> void:
	if peer_id <= 0:
		return
	if multiplayer.get_unique_id() == peer_id:
		play_sfx(id, pitch_vary, max_seconds)
		return
	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		_rpc_sfx.rpc_id(peer_id, id, pitch_vary, max_seconds, Vector3.INF)


# Menu click sound
func play_ui() -> void:
	play_sfx("menu_select", 0.0)


# Plays a music track and loops it
func play_music(id: String) -> void:
	var stream := _get_stream(id)
	if stream == null or _music == null:
		return
	var looped := _looped(stream)
	if _music.playing and _music.stream == looped:
		return
	_music_gain = GAME_MUSIC_GAIN if id.begins_with("game_music") else 1.0
	_music.stream = looped
	_music.bus = BUS_MUSIC
	_music.volume_db = _linear_db(music_volume * _music_gain)
	_music.play()


# Starts a sound that keeps looping until it is stopped
func start_loop(id: String, pitch: float = 1.0) -> void:
	var stream := _get_stream(id)
	if stream == null:
		return
	var player := _loops.get(id) as AudioStreamPlayer
	if player == null:
		player = AudioStreamPlayer.new()
		player.bus = BUS_SFX
		add_child(player)
		_loops[id] = player
	player.volume_db = _clip_db(id, sfx_volume)
	player.pitch_scale = maxf(pitch, 0.1)
	if not player.playing:
		player.stream = _looped(stream)
		player.play()


# Stops a looping sound
func stop_loop(id: String) -> void:
	var player := _loops.get(id) as AudioStreamPlayer
	if player:
		player.stop()


# Saves the sound effect volume
func set_sfx_volume(value: float) -> void:
	sfx_volume = clampf(value, 0.0, 1.0)
	_apply_volumes()
	_save_settings()
	volumes_changed.emit()


# Saves the music volume
func set_music_volume(value: float) -> void:
	music_volume = clampf(value, 0.0, 1.0)
	_apply_volumes()
	_save_settings()
	volumes_changed.emit()


# Builds the music and sound effect sliders into a menu
func mount_volume_sliders(parent: Node, insert_at: int = -1) -> Node:
	if parent == null:
		return null
	var existing := parent.get_node_or_null("VolumeSliders")
	if existing:
		return existing
	var box := VBoxContainer.new()
	box.name = "VolumeSliders"
	box.custom_minimum_size = Vector2(220, 0)
	parent.add_child(box)
	if insert_at >= 0:
		parent.move_child(box, insert_at)
	_add_slider(box, "Music", true)
	_add_slider(box, "Sound Effects", false)
	return box


# Plays the capture point sounds when that point changes state
func notify_capture_state(
	index: int,
	capturing: bool,
	contested: bool,
	from: Vector3 = Vector3.INF
) -> void:
	if index != _last_capture_index and index >= 0:
		play_sfx("point_spawn", 0.0, 0.0, from)
	if contested and not _last_contested:
		play_sfx("point_contested", 0.0, 0.0, from)
	if capturing and not contested:
		start_loop("point_capturing")
	else:
		stop_loop("point_capturing")
	_last_capture_index = index
	_last_contested = contested


# Stops a sound after a set time, unless a newer play took that voice
func _stop_after(player: AudioStreamPlayer, gen: int, seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	if is_instance_valid(player) and int(player.get_meta("play_gen", 0)) == gen:
		player.stop()


# Client asks the server to share a sound with everyone else
@rpc("any_peer", "reliable")
func _request_sfx(
	id: String,
	pitch_vary: float,
	max_seconds: float,
	from: Vector3
) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	play_sfx(id, pitch_vary, max_seconds, from)
	for peer in multiplayer.get_peers():
		if peer != sender:
			_rpc_sfx.rpc_id(peer, id, pitch_vary, max_seconds, from)


# Server tells this client to play a sound
@rpc("authority", "reliable")
func _rpc_sfx(
	id: String,
	pitch_vary: float = 0.06,
	max_seconds: float = 0.0,
	from: Vector3 = Vector3.INF
) -> void:
	if multiplayer.is_server():
		return
	play_sfx(id, pitch_vary, max_seconds, from)


# Fades a sound out between the near and far distances
func _distance_gain(from: Vector3) -> float:
	if from == Vector3.INF:
		return 1.0
	var listener := _listener_pos()
	if listener == Vector3.INF:
		return 1.0
	var dist := listener.distance_to(from)
	if dist <= ATTEN_NEAR:
		return 1.0
	if dist >= ATTEN_FAR:
		return 0.0
	var t := (dist - ATTEN_NEAR) / (ATTEN_FAR - ATTEN_NEAR)
	return (1.0 - t) * (1.0 - t)


# World position of the local player, used to judge sound distance
func _listener_pos() -> Vector3:
	if not is_inside_tree():
		return Vector3.INF
	for node in get_tree().get_nodes_in_group("Players"):
		if node is Node3D and node.is_multiplayer_authority():
			return (node as Node3D).global_position
	return Vector3.INF


# Adds one labeled slider for music or sound effects
func _add_slider(box: VBoxContainer, title: String, is_music: bool) -> void:
	var label := Label.new()
	label.text = title
	box.add_child(label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = music_volume if is_music else sfx_volume
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(220, 28)
	slider.mouse_filter = Control.MOUSE_FILTER_STOP
	slider.scrollable = false
	box.add_child(slider)
	if is_music:
		slider.value_changed.connect(set_music_volume)
	else:
		slider.value_changed.connect(set_sfx_volume)
	# Keep the slider on this node. A lambda that closes over the local
	# variable sees null once _add_slider returns, then crashes on the next
	# volume change.
	_volume_sliders.append({ "slider": slider, "music": is_music })
	slider.tree_exiting.connect(_forget_slider.bind(slider))


# Drops a slider that is leaving the tree
func _forget_slider(slider: Node) -> void:
	for i in range(_volume_sliders.size() - 1, -1, -1):
		if _volume_sliders[i]["slider"] == slider:
			_volume_sliders.remove_at(i)


# Copies the saved volumes back onto every open slider
func _sync_volume_sliders() -> void:
	for i in range(_volume_sliders.size() - 1, -1, -1):
		var slider: HSlider = _volume_sliders[i]["slider"]
		if not is_instance_valid(slider):
			_volume_sliders.remove_at(i)
			continue
		var value := music_volume if _volume_sliders[i]["music"] else sfx_volume
		slider.set_value_no_signal(value)


# Pushes the saved volumes onto the buses and anything already playing
func _apply_volumes() -> void:
	_set_bus_volume(BUS_SFX, sfx_volume)
	_set_bus_volume(BUS_MUSIC, music_volume)
	for player in _pool:
		var clip_id := String(player.get_meta("clip_id", ""))
		player.volume_db = _clip_db(clip_id, sfx_volume)
		player.bus = BUS_SFX
	for id in _loops:
		var loop_player := _loops[id] as AudioStreamPlayer
		if loop_player == null:
			continue
		loop_player.volume_db = _clip_db(String(id), sfx_volume)
		loop_player.bus = BUS_SFX
	if _music:
		_music.volume_db = _linear_db(music_volume * _music_gain)
		_music.bus = BUS_MUSIC


# Sets one audio bus, and mutes it when the slider is at zero
func _set_bus_volume(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	AudioServer.set_bus_mute(idx, linear <= 0.001)
	AudioServer.set_bus_volume_db(idx, _linear_db(linear))


# Volume for one clip, including its own gain
func _clip_db(id: String, slider: float) -> float:
	return _linear_db(slider * float(GAIN.get(id, 1.0)))


# Turns a 0 to 1 volume into decibels
func _linear_db(linear: float) -> float:
	if linear <= 0.001:
		return -80.0
	return linear_to_db(linear)


# Makes sure the Music and SFX buses exist
func _ensure_buses() -> void:
	_ensure_bus(BUS_MUSIC)
	_ensure_bus(BUS_SFX)


# Adds one bus if the project does not already have it
func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, "Master")


# Loads every sound listed in STREAMS
func _load_streams() -> void:
	for id in STREAMS:
		var path := String(STREAMS[id])
		if ResourceLoader.exists(path):
			_loaded[id] = load(path)
		elif FileAccess.file_exists(path):
			_loaded[id] = load(path)


# Returns a loaded sound, loading it now if it was missed at startup
func _get_stream(id: String) -> AudioStream:
	var stream := _loaded.get(id) as AudioStream
	if stream != null:
		return stream
	if not STREAMS.has(id):
		return null
	var path := String(STREAMS[id])
	if ResourceLoader.exists(path) or FileAccess.file_exists(path):
		stream = load(path) as AudioStream
		if stream:
			_loaded[id] = stream
	return stream


# Picks a pool player that is not busy, or the oldest one
func _free_voice() -> AudioStreamPlayer:
	for player in _pool:
		if not player.playing:
			return player
	var player := _pool[_pool_index]
	_pool_index = (_pool_index + 1) % _pool.size()
	return player


# Copies a stream and turns looping on
func _looped(stream: AudioStream) -> AudioStream:
	var copy := stream.duplicate()
	if copy is AudioStreamWAV:
		var wav := copy as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		if wav.loop_end <= 0:
			wav.loop_end = maxi(wav.data.size() - 1, 1)
		return wav
	if copy is AudioStreamMP3:
		(copy as AudioStreamMP3).loop = true
		return copy
	return stream


# Opens the game in a borderless fullscreen window
func _apply_borderless_fullscreen() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


# Switches to a random match music track
func _on_match_started() -> void:
	stop_loop("player_run")
	stop_loop("firework_flying")
	stop_loop("point_capturing")
	stop_loop("healing")
	var tracks := ["game_music_1", "game_music_2", "game_music_3"]
	play_music(tracks[randi() % tracks.size()])


# Goes back to the menu music
func _on_returned_to_lobby() -> void:
	stop_loop("player_run")
	stop_loop("firework_flying")
	stop_loop("point_capturing")
	play_music("menu_music")


# Plays the win or loss sting for the local player
func _on_match_ended(winner_id: int) -> void:
	stop_loop("point_capturing")
	var local_id := multiplayer.get_unique_id()
	var won := winner_id == local_id
	if Network.winner_team != Teams.NONE:
		won = Network.get_member_team(local_id) == Network.winner_team
	play_sfx("game_won" if won else "game_lost", 0.0)


# Reads the saved music and sound volumes
func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	sfx_volume = clampf(float(cfg.get_value(SETTINGS_SECTION, "sfx", sfx_volume)), 0.0, 1.0)
	music_volume = clampf(float(cfg.get_value(SETTINGS_SECTION, "music", music_volume)), 0.0, 1.0)


# Writes the music and sound volumes to disk
func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value(SETTINGS_SECTION, "sfx", sfx_volume)
	cfg.set_value(SETTINGS_SECTION, "music", music_volume)
	cfg.save(SETTINGS_PATH)
