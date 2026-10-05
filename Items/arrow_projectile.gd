# INFO Handler for the Arrow Projectiles
extends RigidBody3D

#Gets the ID of Player, Base Damage and Toggle for if the user is still in that attack
var shooter_id: int = 0
var damage: int = 200
var _armed := false

#Sets up nodes and makes sure the hitbox is checking
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
	lifetime.timeout.connect(queue_free)
	add_child(lifetime)
	lifetime.start()
	var arm := Timer.new()
	arm.one_shot = true
	arm.wait_time = 0.08
	arm.timeout.connect(func() -> void: _armed = true)
	add_child(arm)
	arm.start()

#Assign Variables to Players Arrow
func setup(owner_id: int, shot_damage: int = 100) -> void:
	shooter_id = owner_id
	damage = shot_damage
	_armed = false

#Send data for the arrow connection
func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server():
		return
	if body == self:
		return

	if body is RigidBody3D:
		return

	if body is CharacterBody3D and body.is_in_group("Players"):
		var victim_id := body.get_multiplayer_authority()
		if victim_id == shooter_id or Network.are_allies(shooter_id, victim_id):
			return
		
		var target_health: Node = body.get_node_or_null("health_controller")
		if target_health == null or target_health.is_dead:
			queue_free()
			return
		
		var target_combat: Node = body.get_node_or_null("combat_controller")
		if target_combat != null and target_combat.has_method("resolve_incoming_hit"):
			var hit_result: int = target_combat.resolve_incoming_hit()
			if hit_result == 1:
				GameAudio.sfx_all("block_hit", 0.06, 0.0, global_position)
				queue_free()
				return
			if hit_result == 2:
				GameAudio.sfx_all("block_break", 0.06, 0.0, global_position)
				
		var direction: Vector3 = (body.global_position - global_position).normalized()
		var impulse := direction * 1.6 + Vector3.UP * 0.8
		var target_movement: Node = body.get_node_or_null("movement_controller")
		
		GameAudio.sfx_all("arrow_hit", 0.06, 0.0, global_position)
		target_health.take_damage(damage, shooter_id)
		if target_movement != null and target_movement.has_method("apply_knockback"):
			target_movement.apply_knockback(impulse)
		queue_free()
		return

	if _armed:
		queue_free()
