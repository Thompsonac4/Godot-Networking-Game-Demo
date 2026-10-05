# INFO Walk, sprint, slide, dodge, flight, and speed buffs

extends Node
@onready var player: CharacterBody3D = get_parent()
@onready var camera_controller: Node = $"../camera_controller"
@onready var combat_controller: Node = $"../combat_controller"
# ============================================================ 
# JUMP / BHOP SETTINGS 
# ============================================================
@export var jump_velocity := 6.0
@export var auto_bhop := true #holding jump auto bhops

# ============================================================ 
# GROUND MOVEMENT 
# ============================================================

@export var walk_speed := 7.0
@export var sprint_speed := 10.0
## Speed multiplier while holding block. 1.0 means you run at full speed.
@export var block_speed_multiplier := 1.0
@export var ground_accel := 15.0
@export var ground_decel := 10.0
@export var ground_friction :=6.0
var knockback_velocity := Vector3.ZERO
@export var knockback_decay := 20.0

# Clears slide, flight, and buffs so the player stands still
func reset_for_respawn() -> void:
	knockback_velocity = Vector3.ZERO
	slide_momentum = 0.0
	slide_dir = Vector3.ZERO
	move_state = MoveState.NORMAL
	is_sprinting = false
	wish_dir = Vector3.ZERO
	stop_flight()
	clear_buffs()
	_pad_ignore_floor = 0.0


# Freezes movement during the round countdown
func hold_still(delta: float) -> void:
	GameAudio.stop_loop("player_run")
	wish_dir = Vector3.ZERO
	player.velocity.x = 0.0
	player.velocity.z = 0.0
	knockback_velocity = Vector3.ZERO
	if player.is_on_floor():
		player.velocity.y = 0.0
	else:
		player.velocity.y -= ProjectSettings.get_setting(
			"physics/3d/default_gravity"
		) * delta
	player.move_and_slide()


# Lets a dead player fall, but not walk
func update_dead_movement(delta: float) -> void:
	GameAudio.stop_loop("player_run")
	stop_flight()
	_tick_buffs(delta)
	wish_dir = Vector3.ZERO
	player.velocity.x = 0.0
	player.velocity.z = 0.0
	knockback_velocity = Vector3.ZERO
	if player.is_on_floor():
		player.velocity.y = 0.0
	else:
		player.velocity.y -= ProjectSettings.get_setting(
			"physics/3d/default_gravity"
		) * delta
	player.move_and_slide()


# Server applies knockback on the owning peer (clients own their player).
func apply_knockback(impulse: Vector3) -> void:
	if not multiplayer.is_server():
		return

	var owner_id := player.get_multiplayer_authority()
	if owner_id == multiplayer.get_unique_id():
		knockback_velocity += impulse
	else:
		receive_knockback.rpc_id(owner_id, impulse)


# Owning player applies a shove that came from the server
@rpc("any_peer", "reliable")
func receive_knockback(impulse: Vector3) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	if not player.is_multiplayer_authority():
		return

	knockback_velocity += impulse


## World pads call this on the owning peer. Impulse is world-space.
func launch_upward(impulse: Vector3) -> void:
	if impulse.length_squared() < 0.0001:
		return
	if is_flying:
		stop_flight()
	if move_state == MoveState.SLIDING:
		_end_slide()
	move_state = MoveState.NORMAL
	player.floor_snap_length = 0.0
	player.velocity.x += impulse.x
	player.velocity.z += impulse.z
	player.velocity.y = maxf(player.velocity.y, impulse.y)
	_pad_ignore_floor = 0.2
	GameAudio.sfx_at("jumppad", player.global_position)


# ============================================================ 
# AIR MOVEMENT / AIR STRAFING 
# ============================================================
@export var air_cap := 20
@export var air_accel := 3
@export var air_move_speed := 6

# ============================================================ 
# SPRINT SYSTEM 
# ============================================================
@export var sprint_delay := 2.0
@export var sprint_requires_key := false
var walk_time := 0.0
var is_sprinting := false

# ============================================================
# SLIDE SETTINGS
# ============================================================

@export var slide_speed := 14.0
@export var slide_max_speed := 20.0
@export var slide_min_speed := 4.0
# Friction on flat ground.
@export var slide_friction := 8.0
# How strongly gravity accelerates the player downhill.
@export var slide_slope_boost := 2.5
# How strongly uphill movement is slowed.
@export var slide_uphill_friction := 16.0
# Friction while moving downhill (keep 0 to gain speed).
@export var slide_downhill_friction := 0.0
# Minimum slope required for slope acceleration.
@export var slide_min_slope := 0.05
# Max turn rate (degrees/sec) at full A/D — curves path, does not overwrite velocity.
@export var slide_steer_degrees := 140.0

# Persistent slide momentum (CharacterBody3D collisions won't eat this).
var slide_momentum := 0.0
var slide_dir := Vector3.ZERO

# ============================================================ 
# DODGE SETTINGS 
# ============================================================
@export var dodge_speed := 14.0
@export var dodge_duration := 0.35
@export var dodge_cooldown := 0.6

# ============================================================ 
# MOVEMENT STATES 
# ============================================================
enum MoveState {NORMAL, SLIDING, DODGING}
var move_state := MoveState.NORMAL
var state_time := 0.0
var dodge_cd := 0.0
var dodge_dir := Vector3.ZERO

# The direction the player wants to move. 
# 
# This is calculated from keyboard/controller input and 
# converted into world-space movement in _physics_process().
var wish_dir := Vector3.ZERO
var _was_on_floor := true
## Set each frame by `update_movement`. Slide/flight read it so the pause
## menu does not look like a released key.
var _input_locked := false
## After a jump pad, skip floor snap / grounded Y-kill so the launch sticks.
var _pad_ignore_floor := 0.0

# ============================================================
# FIREWORK FLIGHT
# ============================================================
@export var flight_duration := 4.5
@export var flight_launch_speed := 10.0
@export var flight_hover_speed := 2.4
@export var flight_up_speed := 8.5
@export var flight_down_speed := 6.0
@export var flight_move_speed := 10.0
@export var flight_accel := 18.0
var is_flying := false
var flight_remaining := 0.0
var _flight_fx_generation := 0

@onready var firework: Node3D = player.get_node_or_null("%Firework")
@onready var firework_particles: GPUParticles3D = (
	firework.get_node_or_null("GPUParticles3D") if firework else null
)


# Server starts firework flight for this player
func grant_flight() -> void:
	if not multiplayer.is_server():
		return
	# Model + sparks on every peer; only the owner gets the movement.
	sync_flight_fx.rpc(true, flight_duration)
	var owner_id := player.get_multiplayer_authority()
	if owner_id == multiplayer.get_unique_id():
		start_flight(flight_duration)
	else:
		receive_flight.rpc_id(owner_id, flight_duration)


# Owning player starts flight that came from the server
@rpc("any_peer", "reliable")
func receive_flight(duration: float) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	if not player.is_multiplayer_authority():
		return
	start_flight(duration)


# Shows the firework on every peer for the flight
@rpc("any_peer", "call_local", "reliable")
func sync_flight_fx(on: bool, duration: float = 0.0) -> void:
	if not _is_from_server():
		return
	if on:
		_set_flight_fx(true)
		_flight_fx_generation += 1
		var gen := _flight_fx_generation
		if duration > 0.0:
			await get_tree().create_timer(duration).timeout
			if is_inside_tree() and gen == _flight_fx_generation:
				_set_flight_fx(false)
	else:
		_flight_fx_generation += 1
		_set_flight_fx(false)


# Turns firework flight on for the owning player
func start_flight(duration: float) -> void:
	GameAudio.sfx_at("firework_start", player.global_position)
	GameAudio.start_loop("firework_flying")
	is_flying = true
	flight_remaining = duration
	move_state = MoveState.NORMAL
	slide_momentum = 0.0
	player.velocity.y = maxf(player.velocity.y, flight_launch_speed)


# Ends firework flight
func stop_flight() -> void:
	is_flying = false
	flight_remaining = 0.0
	_flight_fx_generation += 1
	_set_flight_fx(false)
	GameAudio.stop_loop("firework_flying")


# Shows or hides the firework model and sparks
func _set_flight_fx(on: bool) -> void:
	if firework:
		firework.visible = on
	if firework_particles:
		firework_particles.emitting = on
		if on:
			firework_particles.restart()


# True when this call came from the server
func _is_from_server() -> bool:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return multiplayer.is_server()
	return sender == 1

# ============================================================
# SPEED BUFFS (soda can / iceball)
# ============================================================
enum Buff {SPEED, SLOW}

@export var soda_speed_multiplier := 1.55
@export var soda_duration := 7.0
@export var ice_speed_multiplier := 0.45
var speed_buff_time := 0.0
var speed_buff_total := 0.0
var slow_time := 0.0
var slow_total := 0.0

@onready var buff_row: Control = get_node_or_null("%BuffRow")
@onready var buff_label: Label = get_node_or_null("%BuffLabel")
@onready var buff_bar: ProgressBar = get_node_or_null("%BuffBar")


# Starts the soda speed boost
func grant_speed_boost() -> void:
	_grant_buff(Buff.SPEED, soda_duration)


# Starts the ice slow
func apply_slow(duration: float) -> void:
	_grant_buff(Buff.SLOW, duration)


## Buffs live on the owning client because it runs the movement, so the server
## only tells it when one starts. Mirrors `grant_flight`.
func _grant_buff(kind: int, duration: float) -> void:
	if not multiplayer.is_server():
		return
	var owner_id := player.get_multiplayer_authority()
	if owner_id == multiplayer.get_unique_id():
		_start_buff(kind, duration)
	else:
		receive_buff.rpc_id(owner_id, kind, duration)


# Owning player applies a buff that came from the server
@rpc("any_peer", "reliable")
func receive_buff(kind: int, duration: float) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	if not player.is_multiplayer_authority():
		return
	_start_buff(kind, duration)


# Turns a speed boost or slow on
func _start_buff(kind: int, duration: float) -> void:
	match kind:
		Buff.SPEED:
			speed_buff_time = maxf(speed_buff_time, duration)
			speed_buff_total = maxf(speed_buff_total, duration)
			GameAudio.sfx_at("soda_crack", player.global_position)
			GameAudio.sfx_at("soda_drinking", player.global_position)
		Buff.SLOW:
			slow_time = maxf(slow_time, duration)
			slow_total = maxf(slow_total, duration)


# Clears the speed boost and the slow
func clear_buffs() -> void:
	speed_buff_time = 0.0
	speed_buff_total = 0.0
	slow_time = 0.0
	slow_total = 0.0
	_refresh_buff_hud()


## Scales both ground and air speed, so a slow cannot be bunny-hopped off and a
## boost still helps mid-jump.
func speed_multiplier() -> float:
	var mult := 1.0
	if speed_buff_time > 0.0:
		mult *= soda_speed_multiplier
	if slow_time > 0.0:
		mult *= ice_speed_multiplier
	return mult


# Counts the buff timers down
func _tick_buffs(delta: float) -> void:
	if speed_buff_time <= 0.0 and slow_time <= 0.0:
		return
	speed_buff_time = maxf(speed_buff_time - delta, 0.0)
	slow_time = maxf(slow_time - delta, 0.0)
	_refresh_buff_hud()


# Updates the buff bar. Slow wins over speed if both are on
func _refresh_buff_hud() -> void:
	if buff_row == null or not player.is_multiplayer_authority():
		return
	# Being slowed matters more than being fast, so it wins the one row.
	if slow_time > 0.0:
		buff_label.text = "Frozen"
		buff_bar.max_value = slow_total
		buff_bar.value = slow_time
		buff_bar.modulate = Color(0.55, 0.85, 1.0)
		buff_row.visible = true
	elif speed_buff_time > 0.0:
		buff_label.text = "Speed Boost"
		buff_bar.max_value = speed_buff_total
		buff_bar.value = speed_buff_time
		buff_bar.modulate = Color(1.0, 0.65, 0.2)
		buff_row.visible = true
	else:
		buff_row.visible = false

# ==============================================================================================
# MOVEMENT SPEED # Return sprint speed when sprinting. # Otherwise return normal walking speed.
# ==============================================================================================
func get_move_speed() -> float:
	var speed := sprint_speed if is_sprinting else walk_speed
	if combat_controller.is_blocking():
		speed *= block_speed_multiplier
	return speed * speed_multiplier()


## `allow_input` false keeps current velocity (menu open) but ignores WASD,
## jump, crouch, dodge and flight steering.
func update_movement(delta: float, allow_input: bool = true) -> void:
	_input_locked = not allow_input
	var grounded_at_start := player.is_on_floor()
	if allow_input:
		var input_dir = Input.get_vector("left", "right", "up", "down").normalized()
		var aim_basis: Basis = camera_controller.get_aim_basis()
		wish_dir = aim_basis * Vector3(input_dir.x, 0., input_dir.y)
	else:
		wish_dir = Vector3.ZERO
	
	# Reduce the dodge cooldown over time.
	dodge_cd = max(dodge_cd - delta, 0.0)
	_tick_buffs(delta)

	if combat_controller.is_stunned():
		_handle_stun_movement(delta)
		_was_on_floor = grounded_at_start
		return

	if is_flying:
		_handle_flight(delta)
		player.velocity += knockback_velocity
		knockback_velocity = knockback_velocity.move_toward(
			Vector3.ZERO, knockback_decay * delta
		)
		player.move_and_slide()
		_was_on_floor = grounded_at_start
		return
	
	# Update sprint state.
	if allow_input:
		_update_sprint(delta)
	
	# Check whether the player should enter a slide or dodge.
	if allow_input:
		_try_enter_special_moves()

	if _pad_ignore_floor > 0.0:
		_pad_ignore_floor = maxf(_pad_ignore_floor - delta, 0.0)
		player.floor_snap_length = 0.0
	else:
		# Stick harder to ramps while sliding.
		player.floor_snap_length = 0.8 if move_state == MoveState.SLIDING else 0.1
	if move_state != MoveState.SLIDING:
		player.floor_stop_on_slope = true
	
	# GROUNDED MOVEMENT
	if _pad_ignore_floor <= 0.0 and player.is_on_floor():
		# If currently sliding, use slide physics.
		if move_state == MoveState.SLIDING:
			_handle_slide(delta)
		# If currently dodging, use dodge physics.
		elif move_state == MoveState.DODGING:
			_handle_dodge(delta)
		#Handle Jump
		else:
			if allow_input and (
				Input.is_action_just_pressed("jump")
				or (auto_bhop and Input.is_action_pressed("jump"))
			):
				player.velocity.y = jump_velocity
				GameAudio.sfx_at("player_jump", player.global_position)
			_handle_ground_physics(delta)
	# AIRBORNE MOVEMENT
	else:
		if move_state == MoveState.SLIDING:
			# Stay in slide across ramp air gaps.
			_handle_slide(delta)
		elif move_state != MoveState.DODGING:
			move_state = MoveState.NORMAL
			_handle_air_physics(delta)
		else:
			_handle_air_physics(delta)
	# Apply combat knockback without letting normal movement
	# immediately overwrite it.
	player.velocity += knockback_velocity

	knockback_velocity = knockback_velocity.move_toward(Vector3.ZERO,knockback_decay * delta)
	#	Apply the movement
	player.move_and_slide()

	# Re-apply slide momentum after collisions — CharacterBody3D
	# otherwise bleeds speed every frame on ramps.
	if move_state == MoveState.SLIDING and player.is_on_floor() and slide_momentum > 0.0:
		var n := player.get_floor_normal()
		slide_dir = slide_dir.slide(n)
		if slide_dir.length() > 0.001:
			slide_dir = slide_dir.normalized()
			player.velocity = slide_dir * slide_momentum
	_was_on_floor = grounded_at_start
	_update_move_sfx()


# Footstep loop while running on the ground
func _update_move_sfx() -> void:
	if not player.is_multiplayer_authority():
		return
	if move_state == MoveState.SLIDING:
		GameAudio.stop_loop("player_run")
		return
	var moving := (
		player.is_on_floor()
		and wish_dir.length() > 0.1
		and move_state == MoveState.NORMAL
		and player.velocity.length() > 0.4
		and not is_flying
	)
	if moving:
		GameAudio.start_loop("player_run", 1.32 if is_sprinting else 0.9)
	else:
		GameAudio.stop_loop("player_run")


# Stops the player in place while stunned
func _handle_stun_movement(delta: float) -> void:
	wish_dir = Vector3.ZERO
	player.velocity.x = 0.0
	player.velocity.z = 0.0
	if player.is_on_floor():
		player.velocity.y = 0.0
	else:
		player.velocity.y -= ProjectSettings.get_setting(
			"physics/3d/default_gravity"
		) * delta
	player.velocity += knockback_velocity
	knockback_velocity = knockback_velocity.move_toward(
		Vector3.ZERO, knockback_decay * delta
	)
	player.move_and_slide()


# Steering while the firework is carrying the player
func _handle_flight(delta: float) -> void:
	flight_remaining -= delta
	if flight_remaining <= 0.0:
		stop_flight()
		_handle_air_physics(delta)
		return

	if _input_locked:
		# Keep whatever velocity you already had; do not steer toward hover.
		return

	var vertical := flight_hover_speed
	if Input.is_action_pressed("jump"):
		vertical = flight_up_speed
	elif Input.is_action_pressed("crouch"):
		vertical = -flight_down_speed
	player.velocity.y = vertical

	var target := wish_dir * flight_move_speed
	player.velocity.x = move_toward(player.velocity.x, target.x, flight_accel * delta)
	player.velocity.z = move_toward(player.velocity.z, target.z, flight_accel * delta)
# ============================================================ 
# SLOPE CHECK 
# ============================================================
# True when a floor is too steep to stand on
func is_surface_too_steep(normal: Vector3) -> bool:
	# Calculate the minimum Y component a surface normal 
	# needs to be considered walkable.
	var max_slope_ang_dot = Vector3(0,1,0).rotated(Vector3(1.0,0,0), player.floor_max_angle).dot(Vector3(0,1,0))
	# If the surface normal is below the allowed slope angle, 
	# the surface is considered too steep.
	if normal.dot(Vector3(0,1,0)) < max_slope_ang_dot:
		return true
	return false

# ============================================================ 
# WALL / VELOCITY CLIPPING
# ============================================================
# Slides velocity along a wall instead of stopping dead
func clip_velocity(normal: Vector3, overbounce: float, delta: float) -> void:
	# Determine how much velocity is moving into the surface.
	var backoff := player.velocity.dot(normal) * overbounce
	
	# If the player is already moving away from the surface, 
	# there is nothing to correct.
	if backoff >= 0: return
	
	# Remove the velocity pushing into the surface.
	var change := normal * backoff
	player.velocity -= change
	
	# Check if some velocity is still pushing into the surface.
	var adjust := player.velocity.dot(normal)
	
	# Remove any remaining velocity going into the surface.
	if adjust < 0.0:
		player.velocity -= normal * adjust

# ============================================================
# AIR PHYSICS 
# ============================================================
# Air strafe and gravity
func _handle_air_physics(delta) -> void:
	# Apply gravity while airborne.
	player.velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta
	
	# Determine how much velocity already exists 
	# in the desired movement direction.
	var cur_speed_in_wish_dir = player.velocity.dot(wish_dir)
	
	# Buffs scale air control too, otherwise a slow is just a hop away.
	var air_speed := air_move_speed * speed_multiplier()
	
	# Determine the maximum speed that can be gained 
	# in the desired air movement direction.
	var capped_speed = min((air_speed * wish_dir).length(), air_cap)
	
	# Determine how much additional speed can be added 
	# before reaching the cap.
	var add_speed_till_cap = capped_speed - cur_speed_in_wish_dir
	
	# Only accelerate if we are below the desired speed.
	if add_speed_till_cap > 0:
		# Calculate how much acceleration should be added 
		# this frame.
		var accel_speed = air_accel * air_speed * delta
		# Never add more speed than the remaining speed cap.
		accel_speed = min(accel_speed, add_speed_till_cap)
		# Add acceleration in the desired direction.
		player.velocity += accel_speed * wish_dir
	# Handle collisions with walls.
	if player.is_on_wall():
		# If the wall is too steep to stand on, 
		# use floating movement mode.
		if is_surface_too_steep(player.get_wall_normal()):
			player.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
		# Otherwise use normal grounded movement.
		else:
			player.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
		# Remove velocity pushing directly into the wall.
		clip_velocity(player.get_wall_normal(), 1, delta)

# ============================================================ 
# GROUND PHYSICS 
# ============================================================
# Ground accel, friction, and the wish direction
func _handle_ground_physics(delta) -> void:
	# Determine how much velocity already exists 
	# in the desired movement direction.
	var cur_speed_in_wish_dir = player.velocity.dot(wish_dir)
	# Calculate how much more speed can be added.
	var add_speed_till_cap = get_move_speed() - cur_speed_in_wish_dir
	# Only accelerate if we are below the target speed.
	if add_speed_till_cap > 0:
		# Calculate acceleration for this frame.
		var accel_speed = ground_accel * delta * get_move_speed()
		# Don't accelerate past the desired speed.
		accel_speed = min(accel_speed, add_speed_till_cap)
		# Add movement in the desired direction.
		player.velocity += accel_speed * wish_dir
	
	# Determine how strongly the player should slow down. 
	# 
	# Using velocity.length() means faster movement produces 
	# more friction.
	var control = max(player.velocity.length(), ground_decel)
	# Calculate how much speed should be removed this frame.
	var drop = control * ground_friction * delta
	# Calculate the resulting speed.
	var new_speed = max(player.velocity.length() - drop, 0.0)
	# Convert the new speed into a multiplier.
	if player.velocity.length() > 0:
		new_speed /= player.velocity.length()
	# Apply the friction multiplier to the velocity.
	player.velocity *= new_speed
	
	
# ============================================================ 
# SPRINT SYSTEM
# ============================================================
# Starts sprinting after the player has been moving
func _update_sprint(delta) -> void:
	# Keep sprint through air / bhop — only update on the ground.
	if not player.is_on_floor():
		return

	var moving := wish_dir.length() > 0.1
	var wants_sprint := not sprint_requires_key or Input.is_action_pressed("sprint")

	if moving and wants_sprint:
		walk_time += delta
		if walk_time >= sprint_delay:
			is_sprinting = true
	elif not moving:
		# Stopped on ground → lose sprint
		walk_time = 0.0
		is_sprinting = false
	elif sprint_requires_key and not wants_sprint:
		walk_time = 0.0
		is_sprinting = false

# ============================================================ 
# ============================================================
# ENTER SLIDE / DODGE
# ============================================================
# Starts a slide or a dodge from the current input
func _try_enter_special_moves() -> void:
	if not player.is_on_floor() or move_state != MoveState.NORMAL:
		return

	# --------------------------------------------------------
	# SLIDE
	# --------------------------------------------------------
	# Crouch tap on the ground, or crouch held through a jump onto landing.
	var landing_slide := (
		Input.is_action_pressed("crouch") and not _was_on_floor
	)
	if Input.is_action_just_pressed("crouch") or landing_slide:

		var speed := Vector2(player.velocity.x, player.velocity.z).length()

		# Allow sliding if:
		# - sprinting
		# - already moving faster than the minimum slide speed
		# - OR moving down a slope with enough movement
		var floor_n := player.get_floor_normal()
		var downhill := Vector3.DOWN.slide(floor_n)

		var slope_amount := downhill.length()

		var can_slide := (
			is_sprinting
			or speed > slide_min_speed
			or slope_amount > slide_min_slope and speed > 1.0
		)

		if can_slide:

			move_state = MoveState.SLIDING

			# ------------------------------------------------
			# PROJECT CURRENT MOVEMENT ONTO THE SLOPE
			# ------------------------------------------------
			slide_dir = Vector3.ZERO

			if wish_dir.length() > 0.1:
				slide_dir = wish_dir.slide(floor_n)

			# If there is no input, preserve current movement.
			if slide_dir.length() < 0.1:
				slide_dir = player.velocity.slide(floor_n)

			# If we still don't have a direction, use downhill.
			if slide_dir.length() < 0.1 and slope_amount > slide_min_slope:
				slide_dir = downhill

			# Final fallback: player forward.
			if slide_dir.length() < 0.1:
				slide_dir = -player.global_transform.basis.z.slide(floor_n)

			slide_dir = slide_dir.normalized()

			# Preserve current speed, but give a normal slide
			# a minimum starting speed.
			slide_momentum = maxf(speed, slide_speed)
			player.velocity = slide_dir * slide_momentum
			GameAudio.stop_loop("player_run")
			return

	# --------------------------------------------------------
	# DODGE
	# --------------------------------------------------------
	if Input.is_action_just_pressed("dodge") and dodge_cd <= 0.0:

		move_state = MoveState.DODGING

		state_time = dodge_duration

		dodge_cd = dodge_cooldown

		dodge_dir = wish_dir if wish_dir.length() > 0.1 else -player.global_transform.basis.z
		dodge_dir = dodge_dir.normalized()

		player.velocity = dodge_dir * dodge_speed


# ============================================================
# SLIDE PHYSICS
# ============================================================
# Slide speed, slope boost, and steering
func _handle_slide(delta: float) -> void:
	var gravity: float = ProjectSettings.get_setting(
		"physics/3d/default_gravity"
	)

	# ========================================================
	# JUMP OUT OF SLIDE
	# ========================================================

	if not _input_locked and Input.is_action_just_pressed("jump"):
		_end_slide()
		player.velocity = Vector3(player.velocity.x, 0.0, player.velocity.z)
		player.velocity.y = jump_velocity
		GameAudio.sfx_at("player_jump", player.global_position)
		return


	# ========================================================
	# RELEASE CROUCH
	# ========================================================

	if not _input_locked and not Input.is_action_pressed("crouch"):
		_end_slide()
		if player.is_on_floor():
			# Stop where you are instead of coasting out of the slide.
			player.velocity.x = 0.0
			player.velocity.z = 0.0
			walk_time = 0.0
			is_sprinting = false
		else:
			_handle_air_physics(delta)
		return


	# ========================================================
	# AIRBORNE
	# ========================================================

	if not player.is_on_floor():
		player.velocity.y -= gravity * delta
		if player.velocity.y > 0.0:
			player.velocity.y = 0.0
		# Keep horizontal slide momentum while airborne over lips.
		var horizontal := Vector3(player.velocity.x, 0.0, player.velocity.z)
		if horizontal.length() > 0.1:
			slide_dir = horizontal.normalized()
		player.velocity.x = slide_dir.x * slide_momentum
		player.velocity.z = slide_dir.z * slide_momentum
		return


	# ========================================================
	# FLOOR / SLOPE
	# ========================================================

	player.floor_stop_on_slope = false

	var floor_n := player.get_floor_normal()
	var downhill := Vector3.DOWN.slide(floor_n)
	var slope_amount := downhill.length()

	# Keep slide_dir on the current floor plane.
	slide_dir = slide_dir.slide(floor_n)
	if slide_dir.length() < 0.1:
		var from_vel := player.velocity.slide(floor_n)
		if from_vel.length() > 0.1:
			slide_dir = from_vel.normalized()
		elif slope_amount > slide_min_slope:
			slide_dir = downhill.normalized()
		else:
			slide_dir = -player.global_transform.basis.z.slide(floor_n).normalized()
	else:
		slide_dir = slide_dir.normalized()


	# ========================================================
	# CURVED WASD STEERING (lateral turn only — no overwrite)
	# ========================================================

	if wish_dir.length() > 0.1:
		var wish := wish_dir.slide(floor_n)
		if wish.length() > 0.001:
			wish = wish.normalized()
			# Right vector on the slope relative to current slide direction.
			var right := floor_n.cross(slide_dir)
			if right.length() > 0.001:
				right = right.normalized()
				var lateral := wish.dot(right)
				var turn_rad := deg_to_rad(slide_steer_degrees) * lateral * delta
				slide_dir = slide_dir.rotated(floor_n, turn_rad).normalized()

			# S (back along slide) brakes; W does not rewrite direction.
			var along_input := wish.dot(slide_dir)
			if along_input < -0.05:
				slide_momentum = maxf(
					slide_momentum + along_input * slide_friction * delta,
					0.0
				)


	# ========================================================
	# MOMENTUM: accelerate downhill / brake uphill / flat friction
	# ========================================================

	if slope_amount > slide_min_slope:
		downhill = downhill.normalized()
		var align := slide_dir.dot(downhill)  # +1 downhill, -1 uphill

		if align > 0.0:
			# Gain speed from gravity along the ramp.
			slide_momentum += gravity * slope_amount * slide_slope_boost * align * delta
			if slide_downhill_friction > 0.0:
				slide_momentum = maxf(
					slide_momentum - slide_downhill_friction * delta,
					0.0
				)
		else:
			# Uphill — dump momentum fast.
			slide_momentum = maxf(
				slide_momentum - slide_uphill_friction * (-align) * delta,
				0.0
			)
	else:
		slide_momentum = maxf(slide_momentum - slide_friction * delta, 0.0)

	slide_momentum = minf(slide_momentum, slide_max_speed)

	# Authoritative velocity from momentum (collisions can't permanently bleed it).
	player.velocity = slide_dir * slide_momentum


	# ========================================================
	# END SLIDE
	# ========================================================

	if slope_amount <= slide_min_slope and slide_momentum < slide_min_speed:
		_end_slide()


# Leaves the slide and goes back to normal movement
func _end_slide() -> void:
	move_state = MoveState.NORMAL
	slide_momentum = 0.0
	slide_dir = Vector3.ZERO
	player.floor_stop_on_slope = true
# ============================================================ 
# DODGE PHYSICS
# ============================================================
# Dodge burst, then back to normal when the timer ends
func _handle_dodge(delta: float) -> void:
	# Count down the dodge timer.
	state_time -= delta
	# Keep horizontal movement locked to the dodge direction.
	player.velocity.x = dodge_dir.x * dodge_speed
	player.velocity.z = dodge_dir.z * dodge_speed
	# Once the timer expires, return to normal movement.
	if state_time <= 0.0:
		move_state = MoveState.NORMAL
