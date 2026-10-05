# INFO Ground zone that heals players standing in it

extends Node3D

const TICK_INTERVAL := 0.5

@export var duration := 6.0
@export var radius := 4.0
@export var heal_per_tick := 40

@onready var _dome: MeshInstance3D = $Dome
@onready var _ring: MeshInstance3D = $Ring
@onready var _light: OmniLight3D = $OmniLight3D

var healer_id: int = 0
var _time_left := 0.0
var _tick_time := 0.0
var _pulse := 0.0


# Sizes the dome and lets only the server heal
func _ready() -> void:
	_time_left = duration
	_dome.scale = Vector3(radius, radius * 0.45, radius)
	_ring.scale = Vector3(radius, 1.0, radius)
	_light.omni_range = radius * 1.4
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		set_physics_process(false)


# Remembers who threw the heal
func setup(owner_id: int) -> void:
	healer_id = owner_id


# Pulses the dome and plays the heal loop when you stand in it
func _process(delta: float) -> void:
	_pulse += delta
	var wave := 0.85 + sin(_pulse * 3.2) * 0.15
	_dome.transparency = clampf(1.0 - wave, 0.0, 0.9)
	_ring.rotate_y(delta * 0.8)
	_update_heal_loop()


# Stops the heal loop when the zone goes away
func _exit_tree() -> void:
	GameAudio.stop_loop("healing")


# Heal sound while the local player is inside
func _update_heal_loop() -> void:
	var local_id := multiplayer.get_unique_id()
	var inside := false
	for player in get_tree().get_nodes_in_group("Players"):
		if not (player is Node3D):
			continue
		if player.get_multiplayer_authority() != local_id:
			continue
		var health: Node = player.get_node_or_null("health_controller")
		if health != null and health.get("is_dead"):
			continue
		if player.global_position.distance_to(global_position) <= radius:
			inside = true
		break
	if inside:
		GameAudio.start_loop("healing")
	else:
		GameAudio.stop_loop("healing")


# Heals on a tick until the zone expires
func _physics_process(delta: float) -> void:
	_time_left -= delta
	if _time_left <= 0.0:
		queue_free()
		return

	_tick_time -= delta
	if _tick_time > 0.0:
		return
	_tick_time = TICK_INTERVAL
	_heal_players_in_range()


# Heals every living player inside the dome
func _heal_players_in_range() -> void:
	for player in get_tree().get_nodes_in_group("Players"):
		if not (player is Node3D):
			continue
		if player.global_position.distance_to(global_position) > radius:
			continue
		var health: Node = player.get_node_or_null("health_controller")
		if health == null or not health.has_method("heal"):
			continue
		health.heal(heal_per_tick, healer_id)
