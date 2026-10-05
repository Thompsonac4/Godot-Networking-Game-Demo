# INFO Physics ball the player can shove

extends RigidBody3D

# Only the server simulates the ball
func _ready() -> void:
	# Server handles physics and collisions.
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		freeze = true
		return

	# Only the server needs to listen for collisions.
	body_entered.connect(_on_body_entered)


# Removes the ball when it hits something
func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server():
		return

	# Don't destroy the ball if it somehow collides with itself/another ball.
	if body == self:
		return

	# Destroy the ball when it hits a RigidBody3D or CharacterBody3D.
	if body is RigidBody3D or body is CharacterBody3D:
		queue_free()
	else:
		queue_free()

# Server shoves the ball from a player walking into it
@rpc("any_peer", "reliable")
func apply_push(impulse: Vector3, hit_point: Vector3) -> void:
	if not multiplayer.is_server():
		return

	apply_impulse(impulse, hit_point - global_position)
