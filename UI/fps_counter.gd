# INFO FPS and speed readout

extends CanvasLayer

@onready var _fps_label: Label = %FpsLabel
@onready var _speed_label: Label = %SpeedLabel


# Keeps the counter on top, even while the game is paused
func _ready() -> void:
	layer = 32
	process_mode = Node.PROCESS_MODE_ALWAYS


# Writes the current FPS and speed
func _process(_delta: float) -> void:
	_fps_label.text = "%d FPS" % Engine.get_frames_per_second()
	_speed_label.text = "%.1f" % _local_speed()


# Speed of the local player
func _local_speed() -> float:
	var tree := get_tree()
	if tree == null:
		return 0.0
	for node in tree.get_nodes_in_group("Players"):
		if node is CharacterBody3D and (node as CharacterBody3D).is_multiplayer_authority():
			return (node as CharacterBody3D).velocity.length()
	return 0.0
