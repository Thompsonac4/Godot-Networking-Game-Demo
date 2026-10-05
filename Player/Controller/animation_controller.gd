# INFO This is the main Connection to the Animation Tree player and for the locomotion

extends Node

@onready var player: CharacterBody3D = get_parent()

@onready var anim_tree: AnimationTree = %WorldModel.get_node("Mannequin_Medium/AnimationTree")

@onready var movement_controller: Node = $"../movement_controller"


var anim_state: AnimationNodeStateMachinePlayback
var top_anim_state: AnimationNodeStateMachinePlayback

enum MoveState {
	NORMAL,
	SLIDING,
	DODGING
}


var was_on_floor := true
var is_playing_death := false
var held_arrow: Node3D

# Sets the Anim States since there is a lower and upper locomotion
func _ready() -> void:

	held_arrow = Global.find_model_node(player, "%Arrow") as Node3D
	anim_tree.active = true
	anim_state = anim_tree.get("parameters/StateMachine/playback")
	top_anim_state = anim_tree.get("parameters/UpperbodyStateMachine/playback")
	if top_anim_state:
		top_anim_state.start(_upper_idle(), true)

# Returns State of the Bottom Half
func get_locomotion_state() -> StringName:
	if anim_state == null:
		return &""
	return StringName(anim_state.get_current_node())

# Returns State of the Top Half
func get_upperbody_state() -> StringName:
	if top_anim_state == null:
		return &""
	return StringName(top_anim_state.get_current_node())

# Sync the states over the network
func apply_networked_states(locomotion: StringName, upperbody: StringName) -> void:
	var dying := locomotion == &"Death" or locomotion == &"Death_Pose"
	_set_upperbody_blend(0.0 if dying else 1.0)
	is_playing_death = dying
	if anim_state and locomotion != &"" and get_locomotion_state() != locomotion:
		anim_state.travel(locomotion)
	if not dying and top_anim_state and upperbody != &"" and get_upperbody_state() != upperbody:
		top_anim_state.travel(upperbody)
	_sync_held_arrow(upperbody)

#Syncs if the user is the bow user
func _sync_held_arrow(upperbody: StringName) -> void:
	var arrow := held_arrow
	if arrow == null:
		return
	arrow.visible = (
		str(player.get("weapon_type")) == "ranged"
		and (upperbody == &"Bow-Draw" or upperbody == &"Bow-Aim")
	)

#Death Animation
func play_death() -> void:
	is_playing_death = true
	_set_upperbody_blend(0.0)
	_sync_held_arrow(&"")
	if anim_state:
		anim_state.travel("Death")

#After death then reset to normal
func play_alive() -> void:
	is_playing_death = false
	_set_upperbody_blend(1.0)
	if anim_state:
		anim_state.start("Idle", true)
	if top_anim_state:
		top_anim_state.start(_upper_idle(), true)
	_sync_held_arrow(_upper_idle())

#Determines which idle to run
func _upper_idle() -> StringName:
	if str(player.get("weapon_type")) == "ranged":
		return &"Bow-Idle"
	return &"2H-Idle"

#Sets the Blend for top and bottom half
func _set_upperbody_blend(amount: float) -> void:
	anim_tree.set("parameters/Blend2/blend_amount", amount)

#Sets the Animations for different movement actions
func update_animation() -> void:
	if is_playing_death:
		_set_upperbody_blend(0.0)
		return

	var on_floor := player.is_on_floor()
	var horizontal_speed := Vector2(player.velocity.x,player.velocity.z).length()


	# ========================================================
	# SPECIAL MOVES
	# ========================================================
	if movement_controller.move_state == MoveState.SLIDING:
		anim_state.travel("Crawl")

	elif on_floor and movement_controller.move_state == MoveState.DODGING:
		anim_state.travel("Dodge")

	# ========================================================
	# JUMP START
	# ========================================================

	elif was_on_floor and not on_floor:
		anim_state.travel("Jump_Start")

	# ========================================================
	# LANDING
	# ========================================================

	elif not was_on_floor and on_floor:
		anim_state.travel("Jump_Land")
		if horizontal_speed >= movement_controller.sprint_speed:
			anim_state.travel("Run")
		elif horizontal_speed > 0.0:
			anim_state.travel("Walk")
		else:
			anim_state.travel("Idle")


	# ========================================================
	# NORMAL GROUND MOVEMENT
	# ========================================================

	elif on_floor and movement_controller.move_state == MoveState.NORMAL:
		var current := StringName(anim_state.get_current_node())
		if current != &"Jump_Land":
			if movement_controller.is_sprinting:
				anim_state.travel("Run")
			elif movement_controller.wish_dir.length() > 0.1:
				anim_state.travel("Walk")
			else:
				anim_state.travel("Idle")
	was_on_floor = on_floor

#Speed for Throwing Animation
const THROW_SPEED := 3.0
const THROW_RELEASE_NORM := 0.42
## Playback multipliers for the combat clips.
const MELEE_SWING_SPEED := 1.7
const BOW_DRAW_SPEED := 1.8
const BOW_RELEASE_SPEED := 2.0

#Basic Attack for the 2H Melee Player
func play_basic_attack() -> void:
	if is_playing_death:
		return
	if player.is_multiplayer_authority():
		GameAudio.sfx_at("shovel_swing", player.global_position)
	anim_tree.set(
		"parameters/UpperbodyStateMachine/2H-Slice/TimeScale/scale",
		MELEE_SWING_SPEED
	)
	top_anim_state.travel("2H-Slice")

#Animation Throw for both Players
func play_throw() -> void:
	if is_playing_death or top_anim_state == null:
		return
	anim_tree.set("parameters/UpperbodyStateMachine/Throw/TimeScale/scale", THROW_SPEED)
	top_anim_state.travel("Throw")

#The release this helps to sync up the throw
func get_throw_release_delay() -> float:
	return (_throw_clip_length() / THROW_SPEED) * THROW_RELEASE_NORM

#Makes sure the throw is concise and works correctly
func _throw_clip_length() -> float:
	var anim_player: AnimationPlayer = anim_tree.get_node_or_null(anim_tree.anim_player)
	if anim_player == null:
		return 1.367
	for anim_name in ["Range_Rig/Throw", "Ranged_Rig/Throw"]:
		if anim_player.has_animation(anim_name):
			return maxf(anim_player.get_animation(anim_name).length, 0.2)
	return 1.367

#The bow still has a pull time so it needs to sync arrow up with animation
func get_bow_release_length() -> float:
	var anim_player: AnimationPlayer = anim_tree.get_node_or_null(anim_tree.anim_player)
	if anim_player == null:
		return 0.6 / BOW_RELEASE_SPEED
	for anim_name in ["Ranged_Rig/Ranged_Bow_Release", "Range_Rig/Ranged_Bow_Release"]:
		if anim_player.has_animation(anim_name):
			var length: float = anim_player.get_animation(anim_name).length
			return maxf(length / BOW_RELEASE_SPEED, 0.1)
	return 0.6 / BOW_RELEASE_SPEED

#Drawing Animation for the Ranged Player
func play_bow_draw() -> void:
	if is_playing_death or top_anim_state == null:
		return
	anim_tree.set(
		"parameters/UpperbodyStateMachine/Bow-Draw/TimeScale/scale",
		BOW_DRAW_SPEED
	)
	top_anim_state.travel("Bow-Draw")

#End Animation for Bow
func play_bow_release(restart: bool = false) -> void:
	if is_playing_death or top_anim_state == null:
		return
	anim_tree.set(
		"parameters/UpperbodyStateMachine/Bow-Release/TimeScale/scale",
		BOW_RELEASE_SPEED
	)
	if restart:
		# travel() into the state we are already in does nothing, so a rapid
		# burst has to restart the clip to show each loose.
		top_anim_state.start("Bow-Release", true)
		return
	top_anim_state.travel("Bow-Release")

#Idle For the Ranged Player
func play_bow_idle() -> void:
	if is_playing_death or top_anim_state == null:
		return
	top_anim_state.travel("Bow-Idle")
