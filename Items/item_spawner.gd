# INFO Map spot that rolls and spawns a pickup

extends Node3D

const DEFAULT_ITEMS := ["mudball", "firework", "heal", "soda", "iceball"]

## Items this pad can roll. Leave empty to allow every item.
@export var items: PackedStringArray = PackedStringArray(DEFAULT_ITEMS)
@export var respawn_time := 16.0
@export var first_spawn_delay := 0.0
## The editor marker is hidden in game unless this is on.
@export var show_marker_in_game := false

@onready var _marker: Node3D = $Marker

var spot_id := -1


# Registers with the match and spawns the first item
func _ready() -> void:
	_marker.visible = show_marker_in_game
	if not multiplayer.is_server():
		return
	spot_id = Global.register_item_spawner(self)
	_spawn_first.call_deferred()


# Drops this pad from the spawner list
func _exit_tree() -> void:
	Global.unregister_item_spawner(self)


# Rolls which item this pad spawns
func pick_item() -> String:
	if items.is_empty():
		return String(DEFAULT_ITEMS.pick_random())
	return String(items[randi() % items.size()])


# Spawns the first pickup after the optional delay
func _spawn_first() -> void:
	if first_spawn_delay > 0.0:
		await get_tree().create_timer(first_spawn_delay).timeout
	if not is_inside_tree() or not multiplayer.is_server():
		return
	Global.spawn_pickup(spot_id, pick_item(), global_position)
