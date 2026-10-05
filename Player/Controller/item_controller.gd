# INFO Hotbar pickups and using items

extends Node

const SLOT_ACTIONS := ["attack3", "attack4", "attack5", "attack6"]
const ITEM_MUDBALL := "mudball"
const ITEM_FIREWORK := "firework"
const ITEM_HEAL := "heal"
const ITEM_SODA := "soda"
const ITEM_ICEBALL := "iceball"
const THROWN_ITEMS := [ITEM_MUDBALL, ITEM_HEAL, ITEM_ICEBALL]
const MUD_DURATION := 5.0
const PICKUP_RANGE := 4.5
const SLOT_COUNT := 4
const AIM_DISTANCE := 120.0
# World geometry (1) + players (2).
const AIM_MASK := 3

@onready var player: CharacterBody3D = get_parent()
@onready var health_controller: Node = $"../health_controller"
@onready var movement_controller: Node = $"../movement_controller"
@onready var combat_controller: Node = $"../combat_controller"
@onready var animation_controller: Node = $"../animation_controller"
@onready var camera_3d: Camera3D = %Camera3D
@onready var right_hand: Node3D = %WorldModel.get_node_or_null(
	"Mannequin_Medium/Rig_Medium/Skeleton3D/RightHand"
)
@onready var combat_hud: Control = %CombatHud
@onready var slot0: Control = %Slot0
@onready var slot1: Control = %Slot1
@onready var slot2: Control = %Slot2
@onready var slot3: Control = %Slot3
@onready var slot0_item: Label = %Slot0Item
@onready var slot1_item: Label = %Slot1Item
@onready var slot2_item: Label = %Slot2Item
@onready var slot3_item: Label = %Slot3Item
@onready var mud_overlay: Control = %MudOverlay

var slots: Array[String] = ["", "", "", ""]
var mud_time := 0.0
var _pickup_cooldown := 0.0
var _throwing := false
var slot_item_labels: Array[Label] = []
var slot_panels: Array[Control] = []


# Shows the hotbar for the local player
func _ready() -> void:
	slot_item_labels = [slot0_item, slot1_item, slot2_item, slot3_item]
	slot_panels = [slot0, slot1, slot2, slot3]
	var local := player.is_multiplayer_authority()
	combat_hud.visible = local
	mud_overlay.hide()
	mud_overlay.modulate.a = 1.0
	if not local:
		set_process(false)
	_refresh_hud()


# Fades the mud on the screen
func _process(delta: float) -> void:
	_pickup_cooldown = maxf(_pickup_cooldown - delta, 0.0)
	if mud_time <= 0.0:
		return
	mud_time -= delta
	if mud_time <= 0.0:
		mud_overlay.hide()
		mud_overlay.modulate.a = 1.0
		return
	if mud_time < 1.5:
		mud_overlay.modulate.a = clampf(mud_time / 1.5, 0.0, 1.0)


# Server tries to put a world pickup into this player's hotbar
func server_try_pickup(spot_id: int) -> bool:
	if not multiplayer.is_server():
		return false
	return _server_pickup(spot_id, player.get_multiplayer_authority())


# Local player asks to pick an item up
func request_pickup(spot_id: int) -> void:
	if not player.is_multiplayer_authority():
		return
	if health_controller.is_dead:
		return
	if _pickup_cooldown > 0.0:
		return
	_pickup_cooldown = 0.25
	if multiplayer.is_server():
		_server_pickup(spot_id, player.get_multiplayer_authority())
	else:
		request_pickup_rpc.rpc_id(1, spot_id)


# Client tells the server which pickup they touched
@rpc("any_peer", "reliable")
func request_pickup_rpc(spot_id: int) -> void:
	if not multiplayer.is_server():
		return
	_server_pickup(spot_id, multiplayer.get_remote_sender_id())


# Uses whichever hotbar key was just pressed
func try_use_hotbar() -> void:
	if not player.is_multiplayer_authority():
		return
	if health_controller.is_dead:
		return
	if combat_controller.is_stunned():
		return
	for i in SLOT_COUNT:
		if Input.is_action_just_pressed(SLOT_ACTIONS[i]):
			try_use_slot(i)
			return


# Uses the item in one hotbar slot
func try_use_slot(slot_index: int) -> void:
	if not player.is_multiplayer_authority():
		return
	if slot_index < 0 or slot_index >= SLOT_COUNT:
		return
	if health_controller.is_dead or slots[slot_index] == "":
		return
	if combat_controller.is_stunned():
		return

	if slots[slot_index] in THROWN_ITEMS:
		_start_thrown_item(slot_index)
		return

	var origin := _throw_origin()
	var direction := _camera_aim_direction(origin)
	if multiplayer.is_server():
		_server_use(player.get_multiplayer_authority(), slot_index, origin, direction)
	else:
		request_use.rpc_id(1, slot_index, origin, direction)


# Client asks the server to use a hotbar item
@rpc("any_peer", "reliable")
func request_use(slot_index: int, origin: Vector3, direction: Vector3) -> void:
	if not multiplayer.is_server():
		return
	_server_use(multiplayer.get_remote_sender_id(), slot_index, origin, direction)


# Server covers this player's screen in mud
func splat_mud() -> void:
	if not multiplayer.is_server():
		return
	apply_mud.rpc()


# Drops the hotbar and clears mud on death
func on_death() -> void:
	if multiplayer.is_server():
		var had_item := false
		for i in SLOT_COUNT:
			if slots[i] != "":
				had_item = true
			slots[i] = ""
		if had_item:
			sync_slots.rpc(_slots_packet())
	clear_mud()


# Hides the mud overlay
func clear_mud() -> void:
	mud_time = 0.0
	if mud_overlay:
		mud_overlay.hide()
		mud_overlay.modulate.a = 1.0


# ============================================================
# SERVER
# ============================================================

# Server checks range and puts the item in an empty slot
func _server_pickup(spot_id: int, requester_id: int) -> bool:
	if not multiplayer.is_server():
		return false
	if requester_id != player.get_multiplayer_authority():
		return false
	if health_controller.is_dead:
		return false

	var pickup := _find_pickup(spot_id)
	if pickup == null:
		return false
	if player.global_position.distance_to(pickup.global_position) > PICKUP_RANGE:
		return false

	var item_id: String = pickup.item_id
	if _has_item(item_id):
		return false
	var empty := _first_empty_slot()
	if empty < 0:
		return false

	var pos: Vector3 = pickup.global_position
	slots[empty] = item_id
	sync_slots.rpc(_slots_packet())
	pickup.queue_free()
	Global.schedule_pickup_respawn(spot_id, item_id, pos)
	return true


# Server spends the slot and throws or uses the item
func _server_use(
	requester_id: int,
	slot_index: int,
	origin: Vector3,
	direction: Vector3
) -> void:
	if not multiplayer.is_server():
		return
	if requester_id != player.get_multiplayer_authority():
		return
	if health_controller.is_dead:
		return
	if slot_index < 0 or slot_index >= SLOT_COUNT:
		return

	var item := slots[slot_index]
	if item == "":
		return

	slots[slot_index] = ""
	sync_slots.rpc(_slots_packet())

	match item:
		ITEM_MUDBALL:
			Global.throw_mudball(origin, direction, requester_id)
		ITEM_HEAL:
			Global.throw_heal(origin, direction, requester_id)
		ITEM_ICEBALL:
			Global.throw_iceball(origin, direction, requester_id)
		ITEM_FIREWORK:
			movement_controller.grant_flight()
		ITEM_SODA:
			movement_controller.grant_speed_boost()


# Finds a pickup in the world by its spot id
func _find_pickup(spot_id: int) -> Node:
	if Global.spawn_container == null:
		return null
	return Global.spawn_container.get_node_or_null("Pickup_%d" % spot_id)


# True if this item is already in the hotbar
func _has_item(item_id: String) -> bool:
	return slots.has(item_id)


# First open hotbar slot, or -1 if the bar is full
func _first_empty_slot() -> int:
	for i in SLOT_COUNT:
		if slots[i] == "":
			return i
	return -1


# Packs the hotbar so it can be sent over the network
func _slots_packet() -> PackedStringArray:
	var packet := PackedStringArray()
	for item in slots:
		packet.append(item)
	return packet


# ============================================================
# REPLICATION
# ============================================================

# Applies the hotbar the server sent
@rpc("any_peer", "call_local", "reliable")
func sync_slots(new_slots: PackedStringArray) -> void:
	if not _is_from_server():
		return
	var previous_count := 0
	for item in slots:
		if item != "":
			previous_count += 1
	slots.clear()
	var next_count := 0
	for i in SLOT_COUNT:
		if i < new_slots.size():
			slots.append(String(new_slots[i]))
		else:
			slots.append("")
		if slots[i] != "":
			next_count += 1
	if next_count > previous_count and player.is_multiplayer_authority():
		GameAudio.sfx_at("item_pickup", player.global_position)
	_refresh_hud()


# Shows mud on the local player's screen
@rpc("any_peer", "call_local", "reliable")
func apply_mud() -> void:
	if not _is_from_server():
		return
	if not player.is_multiplayer_authority():
		return
	mud_time = MUD_DURATION
	mud_overlay.modulate.a = 1.0
	mud_overlay.show()


# Writes the item names into the hotbar
func _refresh_hud() -> void:
	if combat_hud == null or not player.is_multiplayer_authority():
		return
	combat_hud.show()
	for i in SLOT_COUNT:
		var item := slots[i] if i < slots.size() else ""
		slot_item_labels[i].text = _item_display_name(item)
		if item == "":
			slot_panels[i].modulate = Color(1, 1, 1, 0.55)
		else:
			slot_panels[i].modulate = Color(1, 1, 1, 1)


# Display name for a hotbar item
func _item_display_name(item_id: String) -> String:
	match item_id:
		ITEM_MUDBALL:
			return "Mudball"
		ITEM_FIREWORK:
			return "Firework"
		ITEM_HEAL:
			return "Heal"
		ITEM_SODA:
			return "Soda"
		ITEM_ICEBALL:
			return "Iceball"
		_:
			return "—"


# Plays the throw, then releases the item on the animation
func _start_thrown_item(slot_index: int) -> void:
	if _throwing:
		return
	var item := slots[slot_index]
	_throwing = true
	GameAudio.sfx_at("ball_throw", player.global_position)
	animation_controller.play_throw()
	var delay := 0.2
	if animation_controller.has_method("get_throw_release_delay"):
		delay = animation_controller.get_throw_release_delay()
	await get_tree().create_timer(delay).timeout
	_throwing = false
	if not is_inside_tree() or not player.is_multiplayer_authority():
		return
	if health_controller.is_dead or combat_controller.is_stunned():
		return
	if slot_index < 0 or slot_index >= SLOT_COUNT:
		return
	if slots[slot_index] != item:
		return
	var origin := _throw_origin()
	var direction := _camera_aim_direction(origin)
	if multiplayer.is_server():
		_server_use(player.get_multiplayer_authority(), slot_index, origin, direction)
	else:
		request_use.rpc_id(1, slot_index, origin, direction)


# Spawn point at the right hand
func _throw_origin() -> Vector3:
	if right_hand != null:
		return right_hand.to_global(Vector3(0.0, 0.1, 0.0))
	var origin := player.global_position
	origin.y += 1.35
	origin += -player.global_transform.basis.z * 0.45
	return origin


# Aims a throw at whatever the crosshair is over
func _camera_aim_direction(origin: Vector3) -> Vector3:
	if camera_3d == null:
		return -player.global_transform.basis.z
	var viewport_size: Vector2 = player.get_viewport().get_visible_rect().size
	var screen_center: Vector2 = viewport_size * 0.5
	var ray_origin: Vector3 = camera_3d.project_ray_origin(screen_center)
	var ray_dir: Vector3 = camera_3d.project_ray_normal(screen_center)
	var target: Vector3 = ray_origin + ray_dir * AIM_DISTANCE

	# The camera is offset off the shoulder, so throw at the point under the
	# crosshair rather than parallel to the camera ray.
	var query := PhysicsRayQueryParameters3D.create(ray_origin, target)
	query.collision_mask = AIM_MASK
	query.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var point: Vector3 = hit["position"]
		if (point - origin).dot(ray_dir) > 0.5:
			target = point

	var aim := target - origin
	if aim.length_squared() < 0.001:
		return ray_dir
	return aim.normalized()


# True when this call came from the server
func _is_from_server() -> bool:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return multiplayer.is_server()
	return sender == 1
