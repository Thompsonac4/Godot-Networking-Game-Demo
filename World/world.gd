# INFO Publishes this map as the active world

extends Node3D

## Publishes this map as the active world. Every map root needs this script,
## a SpawnContainer child, and a MultiplayerSpawner pointing at it.


# Registers the map and its spawn container
func _ready() -> void:
	Global.world = self

	var container := get_node_or_null("SpawnContainer")
	if container == null:
		push_error(
			"Map '%s' has no SpawnContainer; pickups and projectiles cannot spawn."
			% name
		)
		return
	Global.spawn_container = container
