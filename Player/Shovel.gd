# INFO Forwards the swing animation into the combat controller

extends Area3D

var combat_controller: Node


# Finds the combat controller on this player
func _ready() -> void:
	combat_controller = _find_combat_controller()


# Walk up to the player instead of counting parents, so the hitbox can be
# reparented anywhere inside the character model.
func _find_combat_controller() -> Node:
	var node := get_parent()
	while node != null:
		var found := node.get_node_or_null("combat_controller")
		if found != null:
			return found
		node = node.get_parent()
	return null


# Animation calls this to turn the hitbox on
func call_attack_hitbox() -> void:
	if combat_controller == null:
		combat_controller = _find_combat_controller()
	if combat_controller:
		combat_controller.start_attack_hitbox()


# Animation calls this to turn the hitbox off
func call_end_attack_hitbox() -> void:
	if combat_controller == null:
		combat_controller = _find_combat_controller()
	if combat_controller:
		combat_controller.stop_attack_hitbox()
