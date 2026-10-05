# INFO Item sitting in the world waiting to be picked up

extends Area3D

@export var item_id: String = "mudball"
@export var spot_id: int = 0

@onready var _visuals: Node3D = $Visuals
@onready var _label: Label3D = $Label3D

var _bob_origin: Vector3
var _bob_time := 0.0
var _offer_cooldown := 0.0


# Labels the pickup and listens for players walking into it
func _ready() -> void:
	_bob_origin = _visuals.position
	_label.text = _display_name()
	body_entered.connect(_on_body_entered)
	collision_layer = 0
	collision_mask = 2
	monitoring = true


# Bobs and spins the pickup
func _process(delta: float) -> void:
	_bob_time += delta
	_visuals.position = _bob_origin + Vector3(0.0, sin(_bob_time * 2.2) * 0.12, 0.0)
	_visuals.rotate_y(delta * 1.4)


# Offers the item to a nearby player
func _physics_process(delta: float) -> void:
	_offer_cooldown = maxf(_offer_cooldown - delta, 0.0)
	if _offer_cooldown > 0.0:
		return

	if multiplayer.is_server():
		for player in get_tree().get_nodes_in_group("Players"):
			if player is Node3D and player.global_position.distance_to(global_position) <= 2.4:
				if _try_offer(player):
					_offer_cooldown = 0.2
					return
		return

	for body in get_overlapping_bodies():
		if _try_offer(body):
			_offer_cooldown = 0.35
			return


# Offers the item when a body first touches it
func _on_body_entered(body: Node) -> void:
	_try_offer(body)


# Asks that player's hotbar to take this item
func _try_offer(body: Node) -> bool:
	if body == null or not (body is CharacterBody3D):
		return false
	if not body.is_in_group("Players"):
		return false

	var items: Node = body.get_node_or_null("item_controller")
	if items == null:
		return false

	var id := _resolved_spot_id()
	if multiplayer.is_server() and items.has_method("server_try_pickup"):
		return items.server_try_pickup(id)
	if body.is_multiplayer_authority() and items.has_method("request_pickup"):
		items.request_pickup(id)
		return true
	return false


# Spot id from the node name, so respawns stay on the same pad
func _resolved_spot_id() -> int:
	if String(name).begins_with("Pickup_"):
		return int(String(name).get_slice("_", 1))
	return spot_id


# Name shown above the pickup
func _display_name() -> String:
	match item_id:
		"firework":
			return "Firework"
		"heal":
			return "Heal"
		"soda":
			return "Soda"
		"iceball":
			return "Iceball"
		_:
			return "Mudball"
