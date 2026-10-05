# INFO Launches a player who steps on it

extends Area3D

## Launches the owning player along this pad's +Y when they step on it.

@export var launch_speed := 32.0
@export var cooldown := 0.65

@onready var _ring: MeshInstance3D = $Ring
@onready var _light: OmniLight3D = $OmniLight3D

var _cooldown_until: Dictionary = {}
var _pulse := 0.0


# Listens for players stepping on the pad
func _ready() -> void:
	collision_layer = 0
	collision_mask = 2
	monitoring = true
	monitorable = false
	body_entered.connect(_on_body_entered)


# Spins the ring and flashes it after a launch
func _process(delta: float) -> void:
	if _ring:
		_ring.rotate_y(delta * 1.6)
	if _pulse > 0.0:
		_pulse = maxf(_pulse - delta, 0.0)
		var glow := 1.0 + _pulse * 2.4
		if _light:
			_light.light_energy = 1.1 + _pulse * 3.0
		if _ring and _ring.material_override is BaseMaterial3D:
			(_ring.material_override as BaseMaterial3D).emission_energy_multiplier = glow


# Launches anyone still standing on the pad
func _physics_process(_delta: float) -> void:
	for body in get_overlapping_bodies():
		_try_launch(body)


# Launches a player the moment they touch the pad
func _on_body_entered(body: Node) -> void:
	_try_launch(body)


# Sends the owning player up, with a short cooldown
func _try_launch(body: Node) -> void:
	if body == null or not (body is CharacterBody3D):
		return
	if not body.is_in_group("Players"):
		return
	if not body.is_multiplayer_authority():
		return
	var health: Node = body.get_node_or_null("health_controller")
	if health and health.get("is_dead"):
		return

	var now := Time.get_ticks_msec()
	var id := body.get_instance_id()
	if int(_cooldown_until.get(id, 0)) > now:
		return

	var move: Node = body.get_node_or_null("movement_controller")
	if move == null or not move.has_method("launch_upward"):
		return

	_cooldown_until[id] = now + int(cooldown * 1000.0)
	move.launch_upward(global_transform.basis.y.normalized() * launch_speed)
	_pulse = 0.35
