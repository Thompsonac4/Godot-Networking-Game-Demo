# INFO Thrown mudball. Splats the player it hits

extends RigidBody3D

var thrower_id: int = 0
var _armed := false

# Only the server simulates the mudball, and it cleans itself up
func _ready() -> void:
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		freeze = true
		return

	contact_monitor = true
	max_contacts_reported = 8
	body_entered.connect(_on_body_entered)
	var lifetime := Timer.new()
	lifetime.one_shot = true
	lifetime.wait_time = 8.0
	lifetime.timeout.connect(queue_free)
	add_child(lifetime)
	lifetime.start()
	# Arm after a short delay so the thrower is not hit at the muzzle.
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


# Splats a player, or pops when it hits the world
func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server():
		return
	if body == self:
		return

	if body is CharacterBody3D and body.is_in_group("Players"):
		var victim_id := body.get_multiplayer_authority()
		if victim_id == thrower_id and not _armed:
			return
		if Network.are_allies(thrower_id, victim_id):
			return
		var items: Node = body.get_node_or_null("item_controller")
		if items != null and items.has_method("splat_mud"):
			items.splat_mud()
		GameAudio.sfx_all("mudball_hit", 0.06, 0.0, global_position)
		queue_free()
		return

	if _armed:
		queue_free()
