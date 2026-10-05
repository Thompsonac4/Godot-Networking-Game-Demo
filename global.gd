# INFO Shared spawning for balls, pickups, and projectiles

extends Node

var world: Node3D
var spawn_container: Node3D
var username = ''
const BALL = preload("uid://cmvltdukjryr4")
const PICKUP_MUDBALL = preload("uid://dkq8m2n4p7xwb")
const PICKUP_FIREWORK = preload("uid://bh3r9vw2k5qnt")
const PICKUP_HEAL = preload("res://Scenes/Items/PickupHeal.tscn")
const PICKUP_SODA = preload("res://Scenes/Items/PickupSoda.tscn")
const PICKUP_ICEBALL = preload("res://Scenes/Items/PickupIceball.tscn")
const MUDBALL_PROJECTILE = preload("uid://c8mudbllproj1")
const HEAL_PROJECTILE = preload("res://Scenes/Items/HealProjectile.tscn")
const HEAL_ZONE = preload("res://Scenes/Items/HealZone.tscn")
const ICEBALL_PROJECTILE = preload("res://Scenes/Items/IceballProjectile.tscn")
const ICE_ZONE = preload("res://Scenes/Items/IceZone.tscn")
const ARROW_PROJECTILE = preload("res://Scenes/Items/ArrowProjectile.tscn")

const PICKUP_RESPAWN := 16.0
## Mudball is thrown flat and hard, like a baseball; the heal orb keeps its
## lob so it drops onto the ground where you aim.
const MUDBALL_LOB_UP := 0.06
const MUDBALL_FORCE := 40.0
const HEAL_LOB_UP := 0.42
const HEAL_FORCE := 19.0
## Iceball sits between the two: enough arc to lob into a doorway, flat enough
## to hit someone at range.
const ICE_LOB_UP := 0.2
const ICE_FORCE := 28.0
const ARROW_SPEED := 78.0

const PICKUP_SPOTS := [
	{"item": "mudball", "pos": Vector3(3.5, 0.35, 3.5)},
	{"item": "firework", "pos": Vector3(-3.5, 0.35, 3.5)},
	{"item": "mudball", "pos": Vector3(5.5, 0.35, -2.5)},
	{"item": "firework", "pos": Vector3(-5.5, 0.35, -2.5)},
	{"item": "mudball", "pos": Vector3(0.0, 0.35, 7.0)},
	{"item": "firework", "pos": Vector3(7.0, 0.35, 0.0)},
]

# Spawners placed in a map register here and own their pickup spot.
var item_spawners := {}
var _next_spawner_spot_id := 1000


## Looks up a scene-unique node inside a player's character model, so moving
## nodes around inside the mannequin does not break these references.
func find_model_node(player: Node, unique_name: String) -> Node:
	if player == null:
		return null
	var world_model: Node = player.get_node_or_null("%WorldModel")
	if world_model == null:
		return null
	var model: Node = world_model.get_node_or_null("Mannequin_Medium")
	if model == null:
		return null
	var found := model.get_node_or_null(unique_name)
	if found == null:
		# Fall back to a name search if the scene-unique flag was lost.
		found = model.find_child(unique_name.trim_prefix("%"), true, false)
	return found


# Server spawns a ball and throws it
@rpc("any_peer", "reliable")
func shoot_ball(pos: Vector3, dir: Vector3, force: float) -> void:
	if not multiplayer.is_server():
		return

	if spawn_container == null:
		return

	var new_ball: RigidBody3D = BALL.instantiate()

	# Add the ball to the tree FIRST.
	spawn_container.add_child(new_ball, true)

	# Now global_position is valid.
	new_ball.global_position = pos

	# Launch toward the crosshair.
	new_ball.apply_central_impulse(dir.normalized() * force)


# Gives a map spawner a spot id
func register_item_spawner(spawner: Node) -> int:
	var id := _next_spawner_spot_id
	_next_spawner_spot_id += 1
	item_spawners[id] = spawner
	return id


# Removes a spawner when its pad leaves the tree
func unregister_item_spawner(spawner: Node) -> void:
	for id in item_spawners.keys():
		if item_spawners[id] == spawner:
			item_spawners.erase(id)
			return


# Spawns the default pickups when the map has no item pads
func spawn_match_pickups() -> void:
	if not multiplayer.is_server() or spawn_container == null:
		return
	# Maps with their own ItemSpawner nodes handle their own placement.
	if not item_spawners.is_empty():
		return
	for i in PICKUP_SPOTS.size():
		spawn_pickup(i, String(PICKUP_SPOTS[i]["item"]), PICKUP_SPOTS[i]["pos"])


## Clears leftover pickups, projectiles and heal zones, then re-rolls every
## spawner. Used between rounds so each one starts from the same board.
func reset_pickups() -> void:
	if not multiplayer.is_server() or spawn_container == null:
		return

	for child in spawn_container.get_children():
		# Detach immediately so the pickup names are free to reuse below;
		# queue_free alone would leave them in the tree until end of frame.
		spawn_container.remove_child(child)
		child.queue_free()

	if item_spawners.is_empty():
		for i in PICKUP_SPOTS.size():
			spawn_pickup(i, String(PICKUP_SPOTS[i]["item"]), PICKUP_SPOTS[i]["pos"])
		return

	for spot_id in item_spawners:
		var spawner: Node = item_spawners[spot_id]
		if is_instance_valid(spawner):
			spawn_pickup(spot_id, spawner.pick_item(), spawner.global_position)


# Spawns one pickup if that spot is empty
func spawn_pickup(spot_id: int, item_id: String, pos: Vector3) -> void:
	if not multiplayer.is_server() or spawn_container == null:
		return
	var existing := spawn_container.get_node_or_null("Pickup_%d" % spot_id)
	if existing != null:
		return

	var pickup: Area3D = _pickup_scene(item_id).instantiate()
	pickup.name = "Pickup_%d" % spot_id
	pickup.spot_id = spot_id
	pickup.item_id = item_id
	spawn_container.add_child(pickup, true)
	pickup.global_position = pos


# Scene for an item id
func _pickup_scene(item_id: String) -> PackedScene:
	match item_id:
		"firework":
			return PICKUP_FIREWORK
		"heal":
			return PICKUP_HEAL
		"soda":
			return PICKUP_SODA
		"iceball":
			return PICKUP_ICEBALL
		_:
			return PICKUP_MUDBALL


# Waits, then puts a new item back on that spot
func schedule_pickup_respawn(spot_id: int, item_id: String, pos: Vector3) -> void:
	if not multiplayer.is_server():
		return
	_respawn_pickup(spot_id, item_id, pos)


# Respawns after the pad's delay, or rolls a new item if a spawner owns it
func _respawn_pickup(spot_id: int, item_id: String, pos: Vector3) -> void:
	var spawner: Node = item_spawners.get(spot_id)
	var delay := PICKUP_RESPAWN
	if spawner != null and is_instance_valid(spawner):
		delay = float(spawner.respawn_time)

	await get_tree().create_timer(delay).timeout
	if spawn_container == null or not Network.match_in_progress:
		return

	spawner = item_spawners.get(spot_id)
	if spawner != null and is_instance_valid(spawner):
		spawn_pickup(spot_id, spawner.pick_item(), spawner.global_position)
	else:
		spawn_pickup(spot_id, item_id, pos)


# Server throws a mudball
func throw_mudball(pos: Vector3, dir: Vector3, thrower_id: int) -> void:
	if not multiplayer.is_server() or spawn_container == null:
		return

	var mudball: RigidBody3D = MUDBALL_PROJECTILE.instantiate()
	spawn_container.add_child(mudball, true)
	mudball.global_position = pos
	if mudball.has_method("setup"):
		mudball.setup(thrower_id)
	for node in spawn_container.get_tree().get_nodes_in_group("Players"):
		if node is PhysicsBody3D and node.get_multiplayer_authority() == thrower_id:
			mudball.add_collision_exception_with(node)

	var look := dir.normalized()
	if look.length_squared() < 0.001:
		look = Vector3.FORWARD
	var lob := (look + Vector3.UP * MUDBALL_LOB_UP).normalized()
	mudball.apply_central_impulse(lob * MUDBALL_FORCE)


# Server throws a heal orb
func throw_heal(pos: Vector3, dir: Vector3, thrower_id: int) -> void:
	if not multiplayer.is_server() or spawn_container == null:
		return

	var orb: RigidBody3D = HEAL_PROJECTILE.instantiate()
	orb.position = spawn_container.to_local(pos)
	if orb.has_method("setup"):
		orb.setup(thrower_id)
	spawn_container.add_child(orb, true)
	for node in spawn_container.get_tree().get_nodes_in_group("Players"):
		if node is PhysicsBody3D and node.get_multiplayer_authority() == thrower_id:
			orb.add_collision_exception_with(node)

	var look := dir.normalized()
	if look.length_squared() < 0.001:
		look = Vector3.FORWARD
	var lob := (look + Vector3.UP * HEAL_LOB_UP).normalized()
	orb.apply_central_impulse(lob * HEAL_FORCE)


# Server throws an iceball
func throw_iceball(pos: Vector3, dir: Vector3, thrower_id: int) -> void:
	if not multiplayer.is_server() or spawn_container == null:
		return

	var ball: RigidBody3D = ICEBALL_PROJECTILE.instantiate()
	ball.position = spawn_container.to_local(pos)
	if ball.has_method("setup"):
		ball.setup(thrower_id)
	spawn_container.add_child(ball, true)
	for node in spawn_container.get_tree().get_nodes_in_group("Players"):
		if node is PhysicsBody3D and node.get_multiplayer_authority() == thrower_id:
			ball.add_collision_exception_with(node)

	var look := dir.normalized()
	if look.length_squared() < 0.001:
		look = Vector3.FORWARD
	var lob := (look + Vector3.UP * ICE_LOB_UP).normalized()
	ball.apply_central_impulse(lob * ICE_FORCE)


# Server drops an ice zone on the ground
func spawn_ice_zone(pos: Vector3, thrower_id: int) -> void:
	if not multiplayer.is_server() or spawn_container == null:
		return
	var zone: Node3D = ICE_ZONE.instantiate()
	# Place it before it enters the tree so the spawn packet carries the
	# final position, otherwise clients get the zone at the container origin.
	zone.position = spawn_container.to_local(_ground_below(pos))
	if zone.has_method("setup"):
		zone.setup(thrower_id)
	spawn_container.add_child(zone, true)


# Server drops a heal zone on the ground
func spawn_heal_zone(pos: Vector3, healer_id: int) -> void:
	if not multiplayer.is_server() or spawn_container == null:
		return
	var zone: Node3D = HEAL_ZONE.instantiate()
	# Place it before it enters the tree so the spawn packet carries the
	# final position, otherwise clients get the zone at the container origin.
	zone.position = spawn_container.to_local(_ground_below(pos))
	if zone.has_method("setup"):
		zone.setup(healer_id)
	spawn_container.add_child(zone, true)


# Snaps a point down onto the floor
func _ground_below(pos: Vector3) -> Vector3:
	if world == null:
		return pos
	var space := world.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		pos + Vector3.UP * 0.5,
		pos + Vector3.DOWN * 8.0
	)
	query.collision_mask = 1
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return pos
	return hit["position"] + Vector3.UP * 0.05


# Server fires an arrow
func shoot_arrow(pos: Vector3, dir: Vector3, shooter_id: int, damage: int = 100) -> RigidBody3D:
	if not multiplayer.is_server() or spawn_container == null:
		return null
	var look := dir.normalized()
	if look.length_squared() < 0.001:
		look = Vector3.FORWARD
	var spawn_pos := pos + look * 0.35
	var arrow: RigidBody3D = ARROW_PROJECTILE.instantiate()
	spawn_container.add_child(arrow, true)
	arrow.global_position = spawn_pos
	if arrow.has_method("setup"):
		arrow.setup(shooter_id, damage)
	var up := Vector3.UP
	if absf(look.dot(up)) > 0.99:
		up = Vector3.FORWARD
	arrow.look_at(spawn_pos + look, up)
	arrow.linear_velocity = look * ARROW_SPEED
	for node in spawn_container.get_tree().get_nodes_in_group("Players"):
		if node is PhysicsBody3D and node.get_multiplayer_authority() == shooter_id:
			arrow.add_collision_exception_with(node)
	return arrow
