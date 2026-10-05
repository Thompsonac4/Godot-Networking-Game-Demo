# INFO Mouse and controller look, and where the third person camera sits

extends Node

@onready var player: CharacterBody3D = get_parent()

@onready var camera_pivot: Node3D = %Head
@onready var spring_arm: SpringArm3D = %Head.get_node("SpringArm3D")
@onready var camera: Camera3D = %Head.get_node("SpringArm3D/Camera3D")


# ============================================================
# LOOK SETTINGS
# ============================================================

@export_group("Look")

@export var look_sensitivity := 0.0005
@export var controller_look_sensitivity := 0.05


# ============================================================
# PITCH
# ============================================================

@export_group("Pitch")

@export var pitch_down := 85.0 ## Maximum amount the camera can look down.

@export var pitch_up := 75.0 ## Maximum amount the camera can look up.


# ============================================================
# CAMERA ORBIT
# ============================================================

@export_group("Camera")

@export var camera_height := 1.55 ## Normal camera pivot height.

@export var camera_distance := 3.5 ## Normal distance from the player.

@export var look_down_height := 2.6 ## Camera height when looking down.

@export var look_down_distance := 2.2 ## Camera distance when looking down.

@export var look_up_height := 0.45 ## Camera height when looking up.

@export var look_up_distance := 2.8 ## Camera distance when looking up.

@export var shoulder_offset := Vector3(1.3, 0.0, 0.0) ## Horizontal shoulder offset. Keeps the body left of the aim point.

@export var camera_collision_margin := 0.25


# ============================================================
# STATE
# ============================================================

## Vertical camera angle.
##
## 0 = looking straight ahead
## negative = looking down
## positive = looking up
var pitch := 0.0


# ============================================================
# CONTROLLER STATE
# ============================================================

var _cur_controller_look := Vector2.ZERO
var _mouse_look := Vector2.ZERO


# ============================================================
# READY
# ============================================================

# Sets the spring arm up and places the camera
func _ready() -> void:

	# Run camera controller before normal visual processing.
	process_priority = -100

	# Enable SpringArm collision.
	spring_arm.collision_mask = 1
	spring_arm.margin = camera_collision_margin
	spring_arm.add_excluded_object(player.get_rid())

	# SpringArm defaults to physics-tick updates, which makes mouse look
	# look shaky/blurry. Update it on rendered frames instead.
	spring_arm.process_mode = Node.PROCESS_MODE_DISABLED

	spring_arm.rotation_degrees.y = 0.0
	
	# Camera itself has no additional rotation.
	camera.transform = Transform3D.IDENTITY

	# Make sure the player and camera start aligned.
	camera_pivot.rotation.y = 0.0

	# Set initial camera position.
	_update_camera_rig()


# ============================================================
# AIM
# ============================================================

# Horizontal facing used to turn movement input into world space
func get_aim_basis() -> Basis:
	return Basis(
		Vector3.UP,
		player.rotation.y
	)


# ============================================================
# MOUSE INPUT
# ============================================================

# True while the pause menu is open or the round countdown is running
func _is_look_locked() -> bool:
	return bool(player.immobile) or Network.is_round_locked()


# Mouse look, and capturing the cursor
func _unhandled_input(event: InputEvent) -> void:
	if not player.is_multiplayer_authority():
		return
	if _is_look_locked():
		_mouse_look = Vector2.ZERO
		return

	# Capture mouse when clicking.
	if event is InputEventMouseButton:

		Input.set_mouse_mode(
			Input.MOUSE_MODE_CAPTURED
		)


	# Release mouse with Escape.
	elif event.is_action_pressed("ui_cancel"):

		Input.set_mouse_mode(
			Input.MOUSE_MODE_VISIBLE
		)


	# Ignore mouse movement when mouse isn't captured.
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return


	# Mouse look — accumulate and apply once per rendered frame.
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		_mouse_look += motion.screen_relative


# ============================================================
# CONTROLLER LOOK
# ============================================================

# Right stick look
func _handle_controller_look_input(delta: float) -> void:

	var target := Input.get_vector(
		"look_left",
		"look_right",
		"look_up",
		"look_down"
	)

	if target.length() < 0.2:
		_cur_controller_look = Vector2.ZERO
		return


	# Smooth controller input.
	_cur_controller_look = _cur_controller_look.lerp(
		target,
		5.0 * delta
	)


	_apply_look(
		-_cur_controller_look.x * controller_look_sensitivity * delta * 60.0,
		-_cur_controller_look.y * controller_look_sensitivity * delta * 60.0
	)


# ============================================================
# APPLY LOOK
# ============================================================

# Turns the player left and right, and pitches the camera up and down
func _apply_look(yaw_delta: float,pitch_delta: float) -> void:

	# ========================================================
	# ROTATE PLAYER LEFT / RIGHT
	# ========================================================

	player.rotate_y(yaw_delta)


	# ========================================================
	# LOOK UP / DOWN
	# ========================================================

	pitch += pitch_delta

	pitch = clampf(
		pitch,
		deg_to_rad(-pitch_down),
		deg_to_rad(pitch_up)
	)


# ============================================================
# CAMERA RIG
# ============================================================

# Moves the camera in when looking up or down
func _update_camera_rig() -> void:

	var pitch_normalized: float


	# ========================================================
	# LOOKING DOWN
	# ========================================================

	if pitch < 0.0:

		pitch_normalized = clampf(
			pitch / deg_to_rad(-pitch_down),
			0.0,
			1.0
		)


		camera_pivot.position.y = lerpf(
			camera_height,
			look_down_height,
			pitch_normalized
		)


		spring_arm.spring_length = lerpf(
			camera_distance,
			look_down_distance,
			pitch_normalized
		)


	# ========================================================
	# LOOKING UP
	# ========================================================

	else:

		pitch_normalized = clampf(
			pitch / deg_to_rad(pitch_up),
			0.0,
			1.0
		)


		camera_pivot.position.y = lerpf(
			camera_height,
			look_up_height,
			pitch_normalized
		)


		spring_arm.spring_length = lerpf(
			camera_distance,
			look_up_distance,
			pitch_normalized
		)


	# ========================================================
	# CAMERA ROTATION
	# ========================================================

	# IMPORTANT:
	#
	# The player handles horizontal rotation.
	# The camera pivot only handles vertical rotation.
	#
	# This prevents the camera and player from getting
	# out of sync.

	camera_pivot.rotation.x = pitch
	camera_pivot.rotation.y = 0.0
	camera_pivot.rotation.z = 0.0


	# Shoulder offset.
	spring_arm.position = shoulder_offset

	_place_camera()


# Pulls the camera in when a wall is in the way
func _place_camera() -> void:
	var origin := spring_arm.global_position
	var cast_dir := spring_arm.global_transform.basis.z.normalized()
	var length: float = spring_arm.spring_length
	var query := PhysicsRayQueryParameters3D.create(
		origin,
		origin + cast_dir * length
	)
	query.collision_mask = spring_arm.collision_mask
	query.exclude = [player.get_rid()]

	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	var dist := length
	if not hit.is_empty():
		dist = maxf(0.2, origin.distance_to(hit.position) - spring_arm.margin)

	camera.position = Vector3(0.0, 0.0, dist)
	camera.rotation = Vector3.ZERO


# ============================================================
# PROCESS
# ============================================================

# Applies the look gathered this frame and keeps the camera on the player
func _process(delta: float) -> void:
	if not player.is_multiplayer_authority():
		return

	if _is_look_locked():
		_mouse_look = Vector2.ZERO
		_cur_controller_look = Vector2.ZERO
		_update_camera_rig()
		return

	if not _mouse_look.is_zero_approx():
		_apply_look(
			-_mouse_look.x * look_sensitivity,
			-_mouse_look.y * look_sensitivity
		)
		_mouse_look = Vector2.ZERO

	_handle_controller_look_input(delta)

	# Keep camera following the player if the player
	# is rotated by another script.
	_update_camera_rig()
