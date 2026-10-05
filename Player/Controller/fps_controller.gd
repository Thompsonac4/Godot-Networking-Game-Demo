# INFO The player body. Reads input and tells the other controllers what to do

extends CharacterBody3D

@onready var movement_controller = $movement_controller
@onready var animation_controller = $animation_controller
@onready var camera_controller: Node = $camera_controller
@onready var combat_controller: Node = $combat_controller
@onready var health_controller: Node = $health_controller
@onready var item_controller: Node = $item_controller
@onready var camera_3d: Camera3D = %Camera3D
@onready var nameplate: Label3D = $Nameplate
@onready var label_session: Label = %LabelSession
@onready var button_copy_session: Button = %ButtonCopySession
@onready var shovel_hitbox: Area3D = Global.find_model_node(self, "%Shovel_Hitbox_Area3D") as Area3D

@onready var crosshair: Control = get_node_or_null("%Crosshair")
@onready var menu: Control = %Menu
@onready var button_leave: Button = %ButtonLeave
@onready var button_return_lobby: Button = get_node_or_null("%ButtonReturnLobby")
@onready var anim_tree: AnimationTree = %WorldModel.get_node("Mannequin_Medium/AnimationTree")


@export var weapon_type := "melee"
var immobile: bool = false
var push_force: float = 5.0

var anim_state: AnimationNodeStateMachinePlayback
var top_anim_state: AnimationNodeStateMachinePlayback
var previous_top_animation: StringName

# Claims this body for its peer and puts it in the Players group
func _enter_tree() -> void:
	set_multiplayer_authority(int(name))
	add_to_group("Players")


# Drops the lobby listener when this player leaves
func _exit_tree() -> void:
	if Network.lobby_changed.is_connected(_refresh_affiliation):
		Network.lobby_changed.disconnect(_refresh_affiliation)


# ============================================================ 
# INITIALIZATION # Setup any pre requisites for character
# ============================================================
# Hides the menu, hooks the pause buttons, and turns on the local camera
func _ready() -> void:
	menu.hide()
	if crosshair:
		crosshair.visible = is_multiplayer_authority()
	
	anim_state = anim_tree.get("parameters/StateMachine/playback")
	top_anim_state = anim_tree.get("parameters/UpperbodyStateMachine/playback")

	if shovel_hitbox:
		shovel_hitbox.monitoring = false
	
	if not Network.lobby_changed.is_connected(_refresh_affiliation):
		Network.lobby_changed.connect(_refresh_affiliation)
	_refresh_affiliation()
	
	if is_multiplayer_authority():
		nameplate.hide()
	if not is_multiplayer_authority():
		set_process(false)
		set_physics_process(false)
	
	label_session.text = Network.tube_client.session_id
	if is_multiplayer_authority():
		button_copy_session.pressed.connect(func(): DisplayServer.clipboard_set(Network.tube_client.session_id))
	
	if is_multiplayer_authority():	
		camera_3d.current = true
		_setup_pause_audio_and_exit()
		button_leave.pressed.connect(func() -> void:
			GameAudio.play_ui()
			Network.leave_server()
		)
		if button_return_lobby:
			var is_host := multiplayer.is_server()
			button_return_lobby.visible = is_host
			if is_host:
				button_return_lobby.pressed.connect(func(): Network.host_return_to_lobby())
	else:
		# Proxies must not steal the dedicated server's world camera.
		camera_3d.current = false
		camera_controller.set_process(false)
		camera_controller.set_process_unhandled_input(false)


# ============================================================ 
# FRAME UPDATE 
# ============================================================
# Pause menu and attack input for the local player
func _process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	if Input.is_action_just_pressed('menu') and menu.visible == false:
		immobile = true
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		menu.show()
	elif Input.is_action_just_pressed('menu') and menu.visible == true:
		immobile = false
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		menu.hide()
	
	if health_controller.is_dead:
		return
	if immobile or Network.is_round_locked():
		return

	if Input.is_action_just_pressed("spawn_ball"):
		ball()
	
	if Input.is_action_just_pressed('attack1'):
		combat_controller.handle_basic_attack()
	if weapon_type == "ranged":
		if Input.is_action_just_released("attack1"):
			combat_controller.release_bow()
		if Input.is_action_just_pressed("attack2"):
			combat_controller.fire_rapid_shot()

	item_controller.try_use_hotbar()
	
	var current_top_animation := top_anim_state.get_current_node()

	if current_top_animation != previous_top_animation:
		if current_top_animation == &"2H-Idle" and shovel_hitbox:
			shovel_hitbox.monitoring = false

		previous_top_animation = current_top_animation

# ============================================================ 
# MAIN PHYSICS LOOP 
# ============================================================
# Steps movement and animation, and shoves anything the body runs into
func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	if health_controller.is_dead:
		movement_controller.update_dead_movement(delta)
	elif Network.is_round_locked():
		movement_controller.hold_still(delta)
	else:
		# Menu open: still simulate so you keep falling / sliding, but
		# WASD and look are ignored.
		movement_controller.update_movement(delta, not immobile)
	if not health_controller.is_dead:
		animation_controller.update_animation()
	_push_rigid_bodies()


# Shoves balls and other rigid bodies the player walks into
func _push_rigid_bodies() -> void:
	for i in get_slide_collision_count():
		var col := get_slide_collision(i)
		var collider := col.get_collider()
		if collider is RigidBody3D:
			var strength := push_force * maxf(velocity.length(), 1.0)
			var impulse := -col.get_normal() * strength
			var hit_point := col.get_position()
			if collider.has_method("apply_push"):
				if multiplayer.is_server():
					collider.apply_push(impulse, hit_point)
				else:
					collider.apply_push.rpc_id(1, impulse, hit_point)
			elif multiplayer.multiplayer_peer == null or multiplayer.is_server():
				(collider as RigidBody3D).apply_impulse(impulse, hit_point - collider.global_position)
				
# Spawns a ball aimed through the crosshair
func ball() -> void:
	var force: float = 100.0

	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var screen_center: Vector2 = viewport_size / 2.0

	# Get the camera ray going through the crosshair.
	var ray_origin: Vector3 = camera_3d.project_ray_origin(screen_center)
	var ray_direction: Vector3 = camera_3d.project_ray_normal(screen_center)

	# Pick a point far in front of the camera.
	var target_point: Vector3 = ray_origin + ray_direction * 100.0

	# Spawn in front of the player's body.
	var spawn_position: Vector3 = global_position
	spawn_position += -global_transform.basis.z * 1.5
	spawn_position.y += 1.5

	# Aim from the ball's actual spawn point toward the crosshair.
	var shoot_dir: Vector3 = (target_point - spawn_position).normalized()

	if multiplayer.is_server():
		Global.shoot_ball(spawn_position, shoot_dir, force)
	else:
		Global.shoot_ball.rpc_id(1, spawn_position, shoot_dir, force)


# Adds the volume sliders and the exit button to the pause menu
func _setup_pause_audio_and_exit() -> void:
	var box := button_leave.get_parent() as VBoxContainer if button_leave else null
	if box == null:
		return
	for leftover in ["MusicLabel", "MusicSlider", "Sound EffectsLabel", "Sound EffectsSlider"]:
		var old := box.get_node_or_null(leftover)
		if old:
			old.queue_free()
	GameAudio.mount_volume_sliders(box, button_leave.get_index())
	if box.get_node_or_null("ButtonExitGame") == null:
		var exit_btn := Button.new()
		exit_btn.name = "ButtonExitGame"
		exit_btn.text = "Exit Game"
		box.add_child(exit_btn)
		exit_btn.pressed.connect(func() -> void:
			GameAudio.play_ui()
			get_tree().quit()
		)


# Updates the nameplate when the lobby roster changes
func _refresh_affiliation() -> void:
	_set_nameplate(Network.get_member_name(int(name)))
	if is_multiplayer_authority():
		nameplate.hide()


# Writes the player name and team color onto the nameplate
func _set_nameplate(display_name: String) -> void:
	nameplate.text = display_name
	# Every peer derives this from the replicated roster, so it needs no
	# syncing of its own.
	if Network.game_mode == Network.MODE_TEAMS:
		nameplate.modulate = Network.team_color(int(name))
	elif int(name) != multiplayer.get_unique_id():
		nameplate.modulate = Teams.color(Teams.RED)
	else:
		nameplate.modulate = Color.WHITE
