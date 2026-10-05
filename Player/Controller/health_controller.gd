# INFO Health, damage, death, and respawn

extends Node

@export var max_health: int = 1000
@export var passive_healing: int = 2
@export var healing_interval: float = 1.0
@export var respawn_delay: float = 5.0

@onready var player: CharacterBody3D = get_parent()
@onready var death_screen: Control = %DeathScreen
@onready var movement_controller: Node = $"../movement_controller"
@onready var animation_controller: Node = $"../animation_controller"
@onready var combat_controller: Node = $"../combat_controller"
@onready var item_controller: Node = $"../item_controller"
@onready var hurtbox: Area3D = %PlayerHurtBox
@onready var health_hud: Control = get_node_or_null("%HealthHud")
@onready var health_bar: ProgressBar = get_node_or_null("%HealthBar")
@onready var health_label: Label = get_node_or_null("%HealthLabel")
@onready var nameplate_health: Sprite3D = player.get_node_or_null("NameplateHealth")
@onready var nameplate_bar: ProgressBar = get_node_or_null("%NameplateBar")
@onready var nameplate_bar_label: Label = get_node_or_null("%NameplateBarLabel")

const PLAYER_HURT_LAYER := 2

var current_health: int
var is_dead: bool = false
var spawn_position: Vector3
var spawn_yaw: float = 0.0
var respawn_timer: Timer


# Sets the health bars and starts the heal and respawn timers
func _ready() -> void:
	current_health = max_health
	spawn_position = player.global_position
	spawn_yaw = player.rotation.y
	death_screen.hide()

	var local := player.is_multiplayer_authority()
	if health_hud:
		health_hud.visible = local
	if health_bar:
		health_bar.max_value = max_health
	# Only other players see the health above the nameplate.
	if nameplate_health:
		_ensure_nameplate_material(nameplate_health)
		nameplate_health.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		nameplate_health.visible = not local
		var viewport := nameplate_health.get_node_or_null("NameplateViewport")
		if viewport is SubViewport:
			# Nothing to draw for the owning player, so stop rendering it.
			(viewport as SubViewport).render_target_update_mode = (
				SubViewport.UPDATE_DISABLED if local else SubViewport.UPDATE_ALWAYS
			)
	if nameplate_bar:
		nameplate_bar.max_value = max_health
	_refresh_health_ui()

	if multiplayer.is_server():
		var heal_timer := Timer.new()
		heal_timer.wait_time = healing_interval
		heal_timer.autostart = true
		heal_timer.timeout.connect(_passive_heal)
		add_child(heal_timer)

		respawn_timer = Timer.new()
		respawn_timer.one_shot = true
		respawn_timer.timeout.connect(_server_respawn)
		add_child(respawn_timer)
	else:
		# Wait until this replica is in the tree on the server too.
		call_deferred("_request_health_when_ready")


# Asks the server for this player's health once the replica exists
func _request_health_when_ready() -> void:
	if not is_inside_tree() or multiplayer.is_server():
		return
	if multiplayer.multiplayer_peer == null:
		return
	request_health.rpc_id(1)


# Server subtracts health and credits a kill at zero
func take_damage(damage_amount: int, attacker_id: int = 0) -> void:
	if not multiplayer.is_server() or is_dead:
		return

	current_health = clampi(
		current_health - damage_amount,
		0,
		max_health
	)

	sync_health.rpc(current_health)

	if current_health <= 0 and attacker_id > 0:
		var victim_id := player.get_multiplayer_authority()
		if attacker_id != victim_id:
			Network.register_kill(attacker_id)


# ============================================================
# CLIENT -> SERVER
# ============================================================

# Client asks the server for the current health
@rpc("any_peer", "reliable")
func request_health() -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	sync_health.rpc_id(sender_id, current_health)


# ============================================================
# SERVER -> EVERYONE
# ============================================================
# "any_peer" (not "authority"): players are client-owned, so the
# server must be allowed to broadcast health on guest nodes.

# Applies health from the server, and dies or respawns when it crosses zero
@rpc("any_peer", "call_local", "reliable")
func sync_health(new_health: int) -> void:
	if not _is_from_server():
		return

	var was_alive := not is_dead
	var previous := current_health
	current_health = new_health
	_refresh_health_ui()

	if was_alive and current_health <= 0:
		die()
	elif is_dead and current_health > 0:
		_finish_respawn()
	elif previous > current_health and current_health > 0:
		if player.is_multiplayer_authority():
			GameAudio.sfx_at("player_damage", player.global_position)


# Server adds health, up to the max
func heal(amount: int, _healer_id: int = 0) -> void:
	if not multiplayer.is_server() or is_dead or amount <= 0:
		return
	if current_health >= max_health:
		return

	current_health = clampi(current_health + amount, 0, max_health)
	sync_health.rpc(current_health)


# Slow heal while the player is alive and not full
func _passive_heal() -> void:
	if not multiplayer.is_server() or is_dead:
		return
	if current_health <= 0 or current_health >= max_health:
		return

	current_health = clampi(
		current_health + passive_healing,
		0,
		max_health
	)

	sync_health.rpc(current_health)


# Death animation, disables the hurtbox, and starts the respawn timer
func die() -> void:
	is_dead = true
	if player.is_multiplayer_authority():
		GameAudio.play_sfx("player_death")
	_set_hurtboxes_enabled(false)
	combat_controller.stop_attack_hitbox()
	combat_controller.on_death()
	animation_controller.play_death()
	movement_controller.stop_flight()
	item_controller.on_death()

	if player.is_multiplayer_authority():
		death_screen.show()

	if multiplayer.is_server() and respawn_timer:
		respawn_timer.start(respawn_delay)


## Fresh start for a new round: full health, alive, on a new random pad.
## Unlike `sync_health`, this also resets players who were still alive.
@rpc("any_peer", "call_local", "reliable")
func round_reset(pos: Vector3, yaw: float) -> void:
	if not _is_from_server():
		return
	if multiplayer.is_server() and respawn_timer:
		respawn_timer.stop()
	spawn_position = pos
	spawn_yaw = yaw
	current_health = max_health
	item_controller.on_death()
	_finish_respawn()
	_refresh_health_ui()


# Remembers where this player should come back
@rpc("any_peer", "call_local", "reliable")
func apply_spawn(pos: Vector3, yaw: float) -> void:
	if not _is_from_server():
		return
	spawn_position = pos
	spawn_yaw = yaw


# Server picks a new pad and brings the player back to full health
func _server_respawn() -> void:
	if not multiplayer.is_server() or not is_dead:
		return

	var spawn := Network.pick_spawn_transform(player.get_multiplayer_authority())
	apply_spawn.rpc(spawn.origin, spawn.basis.get_euler().y)
	current_health = max_health
	sync_health.rpc(current_health)


# Puts the player back on their feet at the spawn pad
func _finish_respawn() -> void:
	is_dead = false
	_set_hurtboxes_enabled(true)
	movement_controller.reset_for_respawn()
	combat_controller.reset_for_respawn()
	animation_controller.play_alive()

	if player.is_multiplayer_authority():
		player.global_position = spawn_position
		player.rotation.y = spawn_yaw
		player.velocity = Vector3.ZERO
		item_controller.clear_mud()
		death_screen.hide()
		if player.menu.visible:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			player.immobile = false


# Updates the health bar and the bar above the nameplate
func _refresh_health_ui() -> void:
	var fraction := 0.0
	if max_health > 0:
		fraction = clampf(float(current_health) / float(max_health), 0.0, 1.0)
	var color := _health_color(fraction)

	if health_bar:
		health_bar.max_value = max_health
		health_bar.value = current_health
		health_bar.modulate = color
	if health_label:
		health_label.text = "Health  %d / %d" % [current_health, max_health]

	if nameplate_bar:
		nameplate_bar.max_value = max_health
		nameplate_bar.value = current_health
		# Local to the scene, so each player's bar keeps its own fill colour.
		var fill := nameplate_bar.get_theme_stylebox("fill")
		if fill is StyleBoxFlat:
			(fill as StyleBoxFlat).bg_color = color
	if nameplate_bar_label:
		if current_health <= 0:
			nameplate_bar_label.text = "DOWN"
		else:
			nameplate_bar_label.text = "%d / %d" % [current_health, max_health]


# Makes the nameplate health sprite draw unshaded so it stays readable
func _ensure_nameplate_material(sprite: Sprite3D) -> void:
	if sprite.material_override is BaseMaterial3D:
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	if sprite.texture:
		mat.albedo_texture = sprite.texture
	sprite.material_override = mat


# Green, yellow, or red from how much health is left
func _health_color(fraction: float) -> Color:
	if fraction <= 0.25:
		return Color(0.95, 0.3, 0.25, 1)
	if fraction <= 0.6:
		return Color(0.98, 0.78, 0.25, 1)
	return Color(0.4, 0.88, 0.45, 1)


# Turns collision and the hurtbox off while dead
func _set_hurtboxes_enabled(enabled: bool) -> void:
	# Death can be triggered from a physics callback, where these are locked.
	if hurtbox:
		hurtbox.set_deferred("monitoring", enabled)
		hurtbox.set_deferred("monitorable", enabled)
	player.set_deferred("collision_layer", PLAYER_HURT_LAYER if enabled else 0)


# True when this call came from the server
func _is_from_server() -> bool:
	var sender := multiplayer.get_remote_sender_id()
	# Local call_local only when the server initiates; remotes only
	# accept this RPC from the server (peer 1).
	if sender == 0:
		return multiplayer.is_server()
	return sender == 1
