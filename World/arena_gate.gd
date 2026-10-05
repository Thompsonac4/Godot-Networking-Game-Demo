# INFO Gate that lets you in from the spawn side and blocks the way back out

extends StaticBody3D

## Players on the spawn side walk through; players already inside cannot leave.
## Height does not matter — only which side of the wall plane you stand on.

@export var inward := Vector3.LEFT

## How far into the arena before the wall starts blocking.
const INSIDE_MARGIN := 0.75


# Sets who can pass on the first frame
func _ready() -> void:
	_update_exceptions()


# Updates who the gate blocks as players move
func _physics_process(_delta: float) -> void:
	_update_exceptions()


# Lets players on the spawn side walk through
func _update_exceptions() -> void:
	if not is_inside_tree():
		return
	var normal := _plane_normal()
	if normal.length_squared() < 0.01:
		return
	var plane_point := global_position
	plane_point.y = 0.0
	for node in get_tree().get_nodes_in_group("Players"):
		if not node is PhysicsBody3D:
			continue
		var player := node as PhysicsBody3D
		var pos := player.global_position
		pos.y = 0.0
		var side := (pos - plane_point).dot(normal)
		if side > INSIDE_MARGIN:
			player.remove_collision_exception_with(self)
		else:
			player.add_collision_exception_with(self)


# Direction that counts as into the arena
func _plane_normal() -> Vector3:
	var n := inward
	n.y = 0.0
	if n.length_squared() < 0.01:
		n = _thinnest_horizontal_axis()
	return n.normalized()


# The wall's thin axis, used when no facing was set
func _thinnest_horizontal_axis() -> Vector3:
	var basis := global_transform.basis
	var axes: Array[Vector3] = [basis.x, basis.z]
	var best := axes[0]
	for axis in axes:
		if axis.length() < best.length():
			best = axis
	best.y = 0.0
	var to_arena := Vector3(-111.0, 0.0, -131.0) - Vector3(global_position.x, 0.0, global_position.z)
	if best.dot(to_arena) < 0.0:
		best = -best
	return best
