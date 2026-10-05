# INFO A spawn pad. Teams use their own color, and free for all can use any

@tool
extends Node3D

## A map-placed spawn point. Set `team` to decide who starts here; a spawner
## left on "Any" serves free-for-all matches and any team with no spawner of
## its own. Drop as many as you like per team — players cycle through them.

@export_enum("Any:0", "Red:1", "Blue:2", "Green:3", "Yellow:4") var team: int = Teams.RED:
	set(value):
		team = value
		_tint_marker()

## How far above the node a player is placed, so the capsule clears the floor.
@export var spawn_height := 1.2

## The editor marker is hidden in game unless this is on.
@export var show_marker_in_game := false


# Tints the marker, joins the spawn group, and faces the castle
func _ready() -> void:
	_tint_marker()
	if Engine.is_editor_hint():
		return
	var marker := get_node_or_null("Marker") as Node3D
	if marker:
		marker.visible = show_marker_in_game
	add_to_group(Teams.SPAWN_GROUP)
	_face_castle.call_deferred()


# Where a player is placed so they clear the floor
func spawn_position() -> Vector3:
	return global_position + Vector3.UP * spawn_height


# Turns the pad toward the castle
func _face_castle() -> void:
	var castle := _find_castle()
	if castle == null:
		return
	var target := castle.global_position
	target.y = global_position.y
	if global_position.distance_squared_to(target) < 0.25:
		return
	look_at(target)


# Looks up the castle on the map
func _find_castle() -> Node3D:
	var map := get_parent()
	if map == null:
		map = get_tree().current_scene
	if map == null:
		return null
	var named := map.find_child("New Castle", true, false)
	if named is Node3D:
		return named
	return map.find_child("Castle", true, false) as Node3D


# Colors the editor marker to match the team
func _tint_marker() -> void:
	# Runs from the setter during scene load too, before children exist.
	var marker := get_node_or_null("Marker") as MeshInstance3D
	if marker == null:
		return
	var material := marker.material_override
	if material is StandardMaterial3D:
		var tint := Teams.color(team)
		tint.a = 0.55
		(material as StandardMaterial3D).albedo_color = tint
