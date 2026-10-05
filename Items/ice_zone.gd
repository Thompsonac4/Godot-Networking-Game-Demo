# INFO Ground zone that slows players standing in it

extends Node3D

const TICK_INTERVAL := 0.4
## Each tick tops the slow back up to this, so it wears off shortly after you
## leave the circle instead of needing the zone to track who walked out.
const SLOW_REFRESH := 0.9

@export var duration := 7.0
@export var radius := 5.0

@onready var _dome: MeshInstance3D = $Dome
@onready var _ring: MeshInstance3D = $Ring
@onready var _frost: MeshInstance3D = $Frost
@onready var _light: OmniLight3D = $OmniLight3D

var thrower_id: int = 0
var _time_left := 0.0
var _tick_time := 0.0
var _pulse := 0.0


# Plays the freeze sound, sizes the dome, and lets only the server slow
func _ready() -> void:
	GameAudio.play_sfx("ice_freezing")
	_time_left = duration
	_dome.scale = Vector3(radius, radius * 0.4, radius)
	_ring.scale = Vector3(radius, 1.0, radius)
	_frost.scale = Vector3(radius, 1.0, radius)
	_light.omni_range = radius * 1.4
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		set_physics_process(false)


# Remembers who threw the iceball
func setup(owner_id: int) -> void:
	thrower_id = owner_id


# Pulses the frost dome
func _process(delta: float) -> void:
	_pulse += delta
	var wave := 0.8 + sin(_pulse * 2.4) * 0.12
	_dome.transparency = clampf(1.0 - wave, 0.0, 0.9)
	_ring.rotate_y(-delta * 0.6)


# Slows players on a tick until the zone expires
func _physics_process(delta: float) -> void:
	_time_left -= delta
	if _time_left <= 0.0:
		queue_free()
		return

	_tick_time -= delta
	if _tick_time > 0.0:
		return
	_tick_time = TICK_INTERVAL
	_slow_players_in_range()


# Slows enemies inside the dome
func _slow_players_in_range() -> void:
	for player in get_tree().get_nodes_in_group("Players"):
		if not (player is Node3D):
			continue
		if player.global_position.distance_to(global_position) > radius:
			continue

		var victim_id: int = player.get_multiplayer_authority()
		if victim_id == thrower_id or Network.are_allies(thrower_id, victim_id):
			continue

		var health: Node = player.get_node_or_null("health_controller")
		if health != null and health.is_dead:
			continue

		var movement: Node = player.get_node_or_null("movement_controller")
		if movement != null and movement.has_method("apply_slow"):
			movement.apply_slow(SLOW_REFRESH)
