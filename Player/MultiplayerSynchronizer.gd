# INFO Sends the local animation state to the other players

extends Node

@onready var player: CharacterBody3D = get_parent()
@onready var animation_controller: Node = $"../animation_controller"

var _last_locomotion: StringName = &""
var _last_upperbody: StringName = &""


# Asks the owner for the current animation if this is a copy
func _ready() -> void:
	set_physics_process(player.is_multiplayer_authority())
	if not player.is_multiplayer_authority():
		request_animations.rpc_id(player.get_multiplayer_authority())


# Sends the animation when it changes
func _physics_process(_delta: float) -> void:
	if not player.is_multiplayer_authority():
		return

	var locomotion: StringName = animation_controller.get_locomotion_state()
	var upperbody: StringName = animation_controller.get_upperbody_state()
	if locomotion == _last_locomotion and upperbody == _last_upperbody:
		return

	_last_locomotion = locomotion
	_last_upperbody = upperbody
	sync_animations.rpc(locomotion, upperbody)


# A copy asks the owner for the current animation
@rpc("any_peer", "reliable")
func request_animations() -> void:
	if not player.is_multiplayer_authority():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	sync_animations.rpc_id(
		sender_id,
		animation_controller.get_locomotion_state(),
		animation_controller.get_upperbody_state()
	)


# Applies the animation the owner sent
@rpc("authority", "call_remote", "reliable")
func sync_animations(locomotion: StringName, upperbody: StringName) -> void:
	_last_locomotion = locomotion
	_last_upperbody = upperbody
	animation_controller.apply_networked_states(locomotion, upperbody)
