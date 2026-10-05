# INFO Melee swings, blocking, and the bow

extends Node

const BLOCK_HITS_TO_BREAK := 2
const STUN_DURATION := 0.2
const BOW_MIN_DAMAGE := 50
const BOW_MAX_DAMAGE := 250
## Time to a full-power shot. Kept in step with the sped-up draw animation
## (`animation_controller.BOW_DRAW_SPEED`) so the charge fills as the bow does.
const BOW_FULL_DRAW := 0.5
## Arrows loosed per burst, the gap between them, and the lockout afterwards.
const RAPID_SHOTS := 3
const RAPID_INTERVAL := 0.16
const RAPID_COOLDOWN := 5.0
## Per-arrow damage. Landing all three takes half of a 1000 HP player.
const RAPID_DAMAGE := 167
const AIM_DISTANCE := 120.0
# World geometry (1) + players (2).
const AIM_MASK := 3

@export_group("Shovel")

## Damage a landed shovel swing deals.
@export var shovel_damage := 334
## Horizontal shove applied to the victim.
@export var shovel_knockback := 1.4
## Upward lift applied to the victim.
@export var shovel_knockback_lift := 1.0
## Knockback multiplier when the swing breaks a block.
@export var guard_break_knockback := 1.25

@export_group("Stamina")

@export var max_stamina := 100.0
@export var block_drain_rate := 22.0
@export var stamina_regen_rate := 28.0
@export var exhausted_regen_rate := 10.0
@export var block_hit_stamina_cost := 50.0

@onready var player: CharacterBody3D = get_parent()
@onready var animation_controller: Node = $"../animation_controller"
@onready var health_controller: Node = $"../health_controller"
@onready var stamina_bar: ProgressBar = %StaminaBar
@onready var rapid_row: Control = get_node_or_null("%RapidCooldownRow")
@onready var rapid_bar: ProgressBar = get_node_or_null("%RapidCooldownBar")
@onready var rapid_label: Label = get_node_or_null("%RapidCooldownLabel")

var shovel_hitbox: Area3D
var held_arrow: Node3D
# Bow States
var _drawing_bow := false
var _draw_started_msec := 0

#Bow rapid shot timers
var _rapid_cooldown := 0.0
var _rapid_shots_left := 0 # Arrows still left on the rapid shot
var _rapid_timer := 0.0
var _rapid_granted := 0 # Server-side budget: arrows already allowed during this cooldown window.
var _bow_recovery := 0.0 # Blocks a new draw or shot until the release animation finishes.

#Stats
var stamina := 100.0 #Stamina for Blocking
var _blocking := false
var exhausted := false #Break state
var stun_remaining := 0.0 #stun after break
var block_hits := 0
var _want_block := false
var _sent_block := false
var _sync_acc := 0.0

#Enum Block
enum HitResult { NONE, BLOCKED, GUARD_BREAK }


# Finds the shovel hitbox and the held arrow, and sets up the bars
func _ready() -> void:
	
	stamina = max_stamina
	shovel_hitbox = Global.find_model_node(player, "%Shovel_Hitbox_Area3D") as Area3D
	held_arrow = Global.find_model_node(player, "%Arrow") as Node3D
	
	if shovel_hitbox:
		shovel_hitbox.area_entered.connect(_on_shovel_hit)
		shovel_hitbox.monitoring = false
	elif not is_ranged():
		push_warning("Melee player %s has no %%Shovel_Hitbox_Area3D; swings cannot hit." % player.name)
	if held_arrow:
		held_arrow.visible = false
	if stamina_bar:
		if is_ranged():
			stamina_bar.max_value = BOW_MAX_DAMAGE
			stamina_bar.value = 0.0
			var label := stamina_bar.get_parent().get_node_or_null("StaminaLabel")
			if label is Label:
				(label as Label).text = "Draw"
		else:
			stamina_bar.max_value = max_stamina
			stamina_bar.value = stamina
	if rapid_row:
		rapid_row.visible = is_ranged()
	_refresh_rapid_hud()


# Counts down stun, stamina, bow recovery, and the rapid shot
func _process(delta: float) -> void:
	var simulate := multiplayer.is_server() or player.is_multiplayer_authority()
	if simulate:
		_bow_recovery = maxf(_bow_recovery - delta, 0.0)
		_tick_rapid_cooldown(delta)
		if not health_controller.is_dead:
			_tick_stun(delta)
			_tick_stamina(delta)

	if health_controller.is_dead:
		if _blocking or stun_remaining > 0.0:
			_blocking = false
			stun_remaining = 0.0
			_want_block = false
			_sent_block = false
		return

	if player.is_multiplayer_authority():
		if Network.is_round_locked() or bool(player.immobile):
			if _blocking:
				_update_block_input()
		else:
			if not is_ranged():
				_update_block_input()
			_advance_rapid_burst(delta)
		_refresh_stamina_hud()
		_refresh_rapid_hud()

	if multiplayer.is_server():
		_sync_acc += delta
		if _sync_acc >= 0.15:
			_sync_acc = 0.0
			if _blocking or exhausted or stun_remaining > 0.0 or stamina < max_stamina:
				_replicate_block_state()


# True while a guard break has the player locked
func is_stunned() -> bool:
	return stun_remaining > 0.0


# True while the shovel guard is up
func is_blocking() -> bool:
	return _blocking


# Clears block, bow, and stun when the player dies
func on_death() -> void:
	_blocking = false
	_want_block = false
	_sent_block = false
	_drawing_bow = false
	_draw_started_msec = 0
	_bow_recovery = 0.0
	_rapid_shots_left = 0
	_rapid_timer = 0.0
	if held_arrow:
		held_arrow.visible = false
	block_hits = 0
	stun_remaining = 0.0
	exhausted = false
	stamina = max_stamina
	if multiplayer.is_server():
		_replicate_block_state()


# Same cleanup as death, used when a round puts the player back
func reset_for_respawn() -> void:
	on_death()


# Reads the block button and tells the server
func _update_block_input() -> void:
	var want: bool = (
		Input.is_action_pressed("attack2")
		and not bool(player.immobile)
		and not Network.is_round_locked()
		and not is_stunned()
		and stamina > 0.0
	)
	if want == _sent_block:
		return
	_sent_block = want
	# Do the drawback before server so the bar lines up
	if want:
		if not _blocking:
			block_hits = 0
			GameAudio.sfx_at("block_ready", player.global_position)
		_blocking = true
	else:
		_blocking = false
	if multiplayer.is_server():
		_server_set_block(player.get_multiplayer_authority(), want)
	else:
		request_block.rpc_id(1, want)


# Client asks the server to raise or drop the block
@rpc("any_peer", "reliable")
func request_block(pressed: bool) -> void:
	if not multiplayer.is_server():
		return
	_server_set_block(multiplayer.get_remote_sender_id(), pressed)


# Server accepts a block only from this player's owner
func _server_set_block(requester_id: int, pressed: bool) -> void:
	if requester_id != player.get_multiplayer_authority():
		return
	if health_controller.is_dead or is_stunned():
		pressed = false
	if pressed and stamina <= 0.0:
		pressed = false

	_want_block = pressed
	if pressed:
		if not _blocking:
			block_hits = 0
			stop_attack_hitbox()
		_blocking = true
	else:
		_blocking = false
	_replicate_block_state()


# Counts the stun down and drops the block while it lasts
func _tick_stun(delta: float) -> void:
	if stun_remaining <= 0.0:
		return
	stun_remaining = maxf(stun_remaining - delta, 0.0)
	_blocking = false
	_want_block = false
	if _drawing_bow:
		_cancel_bow_draw()


# Drains stamina while blocking and refills it after
func _tick_stamina(delta: float) -> void:
	if _blocking and stun_remaining <= 0.0 and stamina > 0.0:
		stamina = maxf(stamina - block_drain_rate * delta, 0.0)
		if stamina <= 0.0:
			stamina = 0.0
			_blocking = false
			_want_block = false
			_sent_block = false
			exhausted = true
			if multiplayer.is_server():
				_replicate_block_state()
		return

	if stamina >= max_stamina:
		stamina = max_stamina
		if exhausted:
			exhausted = false
			if multiplayer.is_server():
				_replicate_block_state()
		return

	var regen := exhausted_regen_rate if exhausted else stamina_regen_rate
	stamina = minf(stamina + regen * delta, max_stamina)
	if stamina >= max_stamina:
		stamina = max_stamina
		exhausted = false


# Decides if a hit is blocked, breaks the guard, or goes through
func resolve_incoming_hit() -> int:
	if not multiplayer.is_server():
		return HitResult.NONE
	if health_controller.is_dead or not _blocking or stamina <= 0.0:
		return HitResult.NONE

	block_hits += 1
	stamina = maxf(stamina - block_hit_stamina_cost, 0.0)
	var emptied := stamina <= 0.0
	var broken := emptied or block_hits >= BLOCK_HITS_TO_BREAK

	if emptied:
		exhausted = true
		_blocking = false
		_want_block = false
		_apply_stun(STUN_DURATION)
		_replicate_block_state()
		return HitResult.GUARD_BREAK

	if broken:
		_blocking = false
		_want_block = false
		_replicate_block_state()
		return HitResult.GUARD_BREAK

	_replicate_block_state()
	return HitResult.BLOCKED


# Server stuns the owning player after a guard break
func _apply_stun(duration: float) -> void:
	if not multiplayer.is_server():
		return
	stun_remaining = duration
	_blocking = false
	var owner_id := player.get_multiplayer_authority()
	if owner_id == multiplayer.get_unique_id():
		stun_remaining = duration
	else:
		receive_stun.rpc_id(owner_id, duration)


# Owning player applies a stun that came from the server
@rpc("any_peer", "reliable")
func receive_stun(duration: float) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	if not player.is_multiplayer_authority():
		return
	stun_remaining = duration
	_blocking = false
	_want_block = false
	_sent_block = false


# Sends stamina, block, and stun to every peer
func _replicate_block_state() -> void:
	if not multiplayer.is_server():
		return
	sync_block_state.rpc(stamina, _blocking, exhausted, stun_remaining)


# Applies the block state the server sent
@rpc("any_peer", "call_local", "reliable")
func sync_block_state(
	new_stamina: float,
	blocking: bool,
	is_exhausted: bool,
	stun: float
) -> void:
	if not _is_from_server():
		return
	stamina = new_stamina
	_blocking = blocking
	exhausted = is_exhausted
	stun_remaining = stun
	_refresh_stamina_hud()


# Updates the stamina bar, or the bow draw bar for the ranged player
func _refresh_stamina_hud() -> void:
	if stamina_bar == null or not player.is_multiplayer_authority():
		return
	if is_ranged():
		stamina_bar.max_value = BOW_MAX_DAMAGE
		var charged := _bow_damage(_draw_elapsed()) if _drawing_bow else 0
		stamina_bar.value = charged
		if charged >= BOW_MAX_DAMAGE:
			stamina_bar.modulate = Color(1.0, 0.55, 0.2, 1)
		elif _drawing_bow:
			stamina_bar.modulate = Color(0.95, 0.82, 0.25, 1)
		else:
			stamina_bar.modulate = Color(0.75, 0.75, 0.75, 1)
		return
	stamina_bar.max_value = max_stamina
	stamina_bar.value = stamina
	if is_stunned():
		stamina_bar.modulate = Color(0.95, 0.35, 0.2, 1)
	elif exhausted:
		stamina_bar.modulate = Color(1.0, 0.45, 0.2, 1)
	elif _blocking:
		stamina_bar.modulate = Color(0.55, 0.85, 1.0, 1)
	else:
		stamina_bar.modulate = Color(0.95, 0.82, 0.25, 1)


# True when this call came from the server
func _is_from_server() -> bool:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return multiplayer.is_server()
	return sender == 1


# True for the bow character
func is_ranged() -> bool:
	return str(player.get("weapon_type")) == "ranged"


# Starts the draw timer and shows the nocked arrow
func _begin_bow_draw() -> void:
	_drawing_bow = true
	_draw_started_msec = Time.get_ticks_msec()
	if held_arrow:
		held_arrow.visible = true


# How long the current draw has been held
func _draw_elapsed() -> float:
	if not _drawing_bow:
		return 0.0
	return float(Time.get_ticks_msec() - _draw_started_msec) / 1000.0


# Damage from how long the bow was drawn
func _bow_damage(draw_seconds: float) -> int:
	var t := clampf(draw_seconds / BOW_FULL_DRAW, 0.0, 1.0)
	return int(round(lerpf(float(BOW_MIN_DAMAGE), float(BOW_MAX_DAMAGE), t)))


# Counts down the rapid shot lockout
func _tick_rapid_cooldown(delta: float) -> void:
	if _rapid_cooldown <= 0.0:
		return
	_rapid_cooldown = maxf(_rapid_cooldown - delta, 0.0)


# Updates the rapid shot bar and label
func _refresh_rapid_hud() -> void:
	if rapid_row == null or not player.is_multiplayer_authority():
		return
	if not is_ranged():
		rapid_row.hide()
		return
	rapid_row.show()
	if rapid_bar:
		rapid_bar.max_value = RAPID_COOLDOWN
		rapid_bar.value = RAPID_COOLDOWN - _rapid_cooldown
		if _rapid_cooldown > 0.0:
			rapid_bar.modulate = Color(0.95, 0.55, 0.25, 1)
		else:
			rapid_bar.modulate = Color(0.45, 0.85, 0.55, 1)
	if rapid_label:
		if _rapid_shots_left > 0:
			rapid_label.text = "Rapid Shot  x%d" % _rapid_shots_left
		elif _rapid_cooldown > 0.0:
			rapid_label.text = "Rapid Shot  %.1fs" % _rapid_cooldown
		else:
			rapid_label.text = "Rapid Shot"


# Begins a charged shot
func start_bow_draw() -> void:
	if not is_ranged():
		return
	if health_controller.is_dead or is_stunned():
		return
	if _drawing_bow or _bow_recovery > 0.0 or _rapid_shots_left > 0:
		return
	_begin_bow_draw()
	GameAudio.sfx_at("bow_draw", player.global_position)
	animation_controller.play_bow_draw()
	if not multiplayer.is_server():
		request_bow_draw.rpc_id(1)


# Lets the drawn arrow go
func release_bow() -> void:
	if not is_ranged():
		return
	if health_controller.is_dead or is_stunned():
		_cancel_bow_draw()
		return
	if _bow_recovery > 0.0 or _rapid_shots_left > 0:
		return
	if not _drawing_bow:
		return
	_bow_recovery = _bow_release_time()
	GameAudio.sfx_at("bow_release", player.global_position, 0.0, 0.5)
	animation_controller.play_bow_release()
	if held_arrow:
		held_arrow.visible = false
	var origin := _arrow_origin()
	var direction := _arrow_aim(origin)
	if multiplayer.is_server():
		_server_fire_bow(player.get_multiplayer_authority(), origin, direction)
	else:
		_drawing_bow = false
		_draw_started_msec = 0
		request_bow_fire.rpc_id(1, origin, direction)


# ============================================================
# RAPID SHOT
# ============================================================
# The owning client paces the burst and re-aims between arrows, so each shot
# follows the crosshair instead of the direction the burst started in. The
# server only caps how many arrows a cooldown window may produce.

# Starts the three arrow burst
func fire_rapid_shot() -> void:
	if not is_ranged():
		return
	if health_controller.is_dead or is_stunned():
		return
	if _rapid_cooldown > 0.0 or _rapid_shots_left > 0 or _bow_recovery > 0.0:
		return
	# Drop any half-drawn charge shot; the burst takes over the bow.
	_drawing_bow = false
	_draw_started_msec = 0
	_rapid_granted = 0
	_rapid_cooldown = RAPID_COOLDOWN
	_rapid_shots_left = RAPID_SHOTS
	_rapid_timer = 0.0
	_fire_rapid_arrow()


# Fires the next arrow in the burst when its gap is up
func _advance_rapid_burst(delta: float) -> void:
	if _rapid_shots_left <= 0:
		return
	_rapid_timer -= delta
	if _rapid_timer <= 0.0:
		_fire_rapid_arrow()


# Shoots one arrow of the rapid burst
func _fire_rapid_arrow() -> void:
	_rapid_shots_left -= 1
	_rapid_timer = RAPID_INTERVAL
	# Only lock the bow once the last arrow is away.
	if _rapid_shots_left <= 0:
		_bow_recovery = _bow_release_time()
	GameAudio.sfx_at("bow_release", player.global_position, 0.04, 0.5)
	animation_controller.play_bow_release(true)
	if held_arrow:
		held_arrow.visible = false
	var origin := _arrow_origin()
	var direction := _arrow_aim(origin)
	if multiplayer.is_server():
		_server_rapid_arrow(player.get_multiplayer_authority(), origin, direction)
	else:
		request_rapid_arrow.rpc_id(1, origin, direction)


# Client asks the server to spawn one rapid arrow
@rpc("any_peer", "reliable")
func request_rapid_arrow(origin: Vector3, direction: Vector3) -> void:
	if not multiplayer.is_server():
		return
	_server_rapid_arrow(multiplayer.get_remote_sender_id(), origin, direction)


# Server caps the burst and spawns the arrow
func _server_rapid_arrow(requester_id: int, origin: Vector3, direction: Vector3) -> void:
	if requester_id != player.get_multiplayer_authority():
		return
	if health_controller.is_dead:
		return
	if _rapid_cooldown <= 0.0:
		# First arrow of a new burst opens the window and resets the budget.
		_rapid_cooldown = RAPID_COOLDOWN
		_rapid_granted = 0
	if _rapid_granted >= RAPID_SHOTS:
		return
	_rapid_granted += 1

	_drawing_bow = false
	_draw_started_msec = 0
	if held_arrow:
		held_arrow.visible = false
	if not player.is_multiplayer_authority():
		animation_controller.play_bow_release(true)
	Global.shoot_arrow(origin, direction, requester_id, RAPID_DAMAGE)


# How long to wait before another shot, matching the release animation
func _bow_release_time() -> float:
	if animation_controller.has_method("get_bow_release_length"):
		return float(animation_controller.get_bow_release_length())
	return 0.6


# Drops a half drawn bow back to idle
func _cancel_bow_draw() -> void:
	_drawing_bow = false
	_draw_started_msec = 0
	if held_arrow:
		held_arrow.visible = false
	if animation_controller.has_method("play_bow_idle"):
		animation_controller.play_bow_idle()


# Client tells the server a draw started
@rpc("any_peer", "reliable")
func request_bow_draw() -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != player.get_multiplayer_authority():
		return
	_begin_bow_draw()
	if not player.is_multiplayer_authority():
		animation_controller.play_bow_draw()


# Client asks the server to fire the charged shot
@rpc("any_peer", "reliable")
func request_bow_fire(origin: Vector3, direction: Vector3) -> void:
	if not multiplayer.is_server():
		return
	_server_fire_bow(multiplayer.get_remote_sender_id(), origin, direction)


# Server spawns the charged arrow
func _server_fire_bow(requester_id: int, origin: Vector3, direction: Vector3) -> void:
	if requester_id != player.get_multiplayer_authority():
		return
	if health_controller.is_dead:
		return
	if not _drawing_bow:
		return
	if _bow_recovery > 0.0 and not player.is_multiplayer_authority():
		return
	_bow_recovery = _bow_release_time()
	var damage := _bow_damage(_draw_elapsed())
	_drawing_bow = false
	_draw_started_msec = 0
	if held_arrow:
		held_arrow.visible = false
	if not player.is_multiplayer_authority():
		animation_controller.play_bow_release()
	Global.shoot_arrow(origin, direction, requester_id, damage)


# Spawn point just in front of the chest
func _arrow_origin() -> Vector3:
	var chest := player.global_position + Vector3.UP * 1.4
	var aim := _arrow_aim(chest)
	return chest + aim * 1.05


# Aims at whatever the crosshair is over
func _arrow_aim(origin: Vector3) -> Vector3:
	var camera: Camera3D = player.get_node_or_null("%Camera3D")
	if camera == null:
		return -player.global_transform.basis.z

	var screen_center: Vector2 = player.get_viewport().get_visible_rect().size * 0.5
	var ray_origin := camera.project_ray_origin(screen_center)
	var ray_dir := camera.project_ray_normal(screen_center)
	var target := ray_origin + ray_dir * AIM_DISTANCE

	# The camera sits off the shoulder, so aiming parallel to its ray lands
	# wide. Aim at whatever the crosshair is actually over instead.
	var query := PhysicsRayQueryParameters3D.create(ray_origin, target)
	query.collision_mask = AIM_MASK
	query.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var point: Vector3 = hit["position"]
		# Ignore anything behind the arrow, such as a wall the camera
		# is backed into.
		if (point - origin).dot(ray_dir) > 0.5:
			target = point

	var aim := target - origin
	if aim.length_squared() < 0.001:
		return -camera.global_transform.basis.z
	return aim.normalized()


# ============================================================
# ATTACK REQUEST
# ============================================================

# Left click. Draws the bow, or swings the shovel
func handle_basic_attack() -> void:
	if is_ranged():
		start_bow_draw()
		return
	if health_controller.is_dead or is_stunned() or _blocking:
		return

	animation_controller.play_basic_attack()

	if multiplayer.is_server():
		_start_attack()
	else:
		request_attack.rpc_id(1)


# Client asks the server to start a shovel swing
@rpc("any_peer", "reliable")
func request_attack() -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id != player.get_multiplayer_authority():
		return
	if health_controller.is_dead or is_stunned() or _blocking:
		return

	_start_attack()


# Plays the swing on other players
func _start_attack() -> void:
	if not player.is_multiplayer_authority():
		animation_controller.play_basic_attack()


# Server resolves a shovel hit on another player
func _on_shovel_hit(hurt_box: Area3D) -> void:
	if not multiplayer.is_server():
		return

	var target := hurt_box.get_parent()
	if target == player:
		return

	if target is CharacterBody3D:
		var target_player: CharacterBody3D = target
		if Network.are_allies(
			player.get_multiplayer_authority(),
			target_player.get_multiplayer_authority()
		):
			return
		var target_health: Node = target_player.get_node("health_controller")
		if target_health.is_dead:
			return

		var target_combat: Node = target_player.get_node("combat_controller")
		var hit_result: int = target_combat.resolve_incoming_hit()
		if hit_result == HitResult.BLOCKED:
			GameAudio.sfx_all("block_hit", 0.06, 0.0, target_player.global_position)
			return
		if hit_result == HitResult.GUARD_BREAK:
			GameAudio.sfx_all("block_break", 0.06, 0.0, target_player.global_position)
		GameAudio.sfx_all("shovel_hit", 0.06, 0.0, target_player.global_position)

		var direction: Vector3 = (
			target_player.global_position -
			player.global_position
		).normalized()
		var impulse: Vector3 = (
			direction * shovel_knockback
			+ Vector3.UP * shovel_knockback_lift
		)
		if hit_result == HitResult.GUARD_BREAK:
			impulse *= guard_break_knockback

		var target_movement: Node = target_player.get_node("movement_controller")
		target_health.take_damage(shovel_damage, player.get_multiplayer_authority())
		target_movement.apply_knockback(impulse)


# Turns the shovel hitbox on during the swing
func start_attack_hitbox() -> void:
	if not multiplayer.is_server() or shovel_hitbox == null:
		return
	if _blocking or is_stunned():
		return
	shovel_hitbox.monitoring = true


# Turns the shovel hitbox off
func stop_attack_hitbox() -> void:
	if not multiplayer.is_server() or shovel_hitbox == null:
		return
	shovel_hitbox.monitoring = false
