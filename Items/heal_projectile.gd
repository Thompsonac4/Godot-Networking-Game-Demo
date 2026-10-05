# INFO Thrown heal orb. Bursts into a heal zone

extends RigidBody3D

var thrower_id: int = 0
var _armed := false
var _spent := false


# Only the server simulates the orb, and it bursts on a timer
func _ready() -> void:
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		freeze = true
		return

	contact_monitor = true
	max_contacts_reported = 8
	body_entered.connect(_on_body_entered)
	var lifetime := Timer.new()
	lifetime.one_shot = true
	lifetime.wait_time = 6.0
	lifetime.timeout.connect(_burst)
	add_child(lifetime)
	lifetime.start()
	# Arm after a short delay so the thrower does not pop it at the hand.
	var arm := Timer.new()
	arm.one_shot = true
	arm.wait_time = 0.12
	arm.timeout.connect(func() -> void: _armed = true)
	add_child(arm)
	arm.start()


# Remembers who threw it
func setup(owner_id: int) -> void:
	thrower_id = owner_id
	_armed = false


# Bursts when it hits a player or the world
func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server():
		return
	if body == self or body is RigidBody3D:
		return

	if body is CharacterBody3D and body.is_in_group("Players"):
		if body.get_multiplayer_authority() == thrower_id and not _armed:
			return
		_burst()
		return

	if _armed:
		_burst()


# Spawns the heal zone and removes the orb
func _burst() -> void:
	if _spent or not multiplayer.is_server():
		return
	_spent = true
	# Contact callbacks run mid physics flush, so spawn after it finishes.
	Global.spawn_heal_zone.call_deferred(global_position, thrower_id)
	queue_free()
