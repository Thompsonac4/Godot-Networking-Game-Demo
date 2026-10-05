# INFO Screen wind and a wider view while the local player is moving fast

extends Node

## Screen wind that swells with how fast the local player is moving.
## Overlay only — Compatibility cannot sample the 3D backbuffer.

const WIND_SHADER := preload("res://shaders/speed_wind.gdshader")

@export var start_speed := 8.0
@export var full_speed := 28.0
@export var max_fov_boost := 12.0

@onready var player: CharacterBody3D = get_parent()

var _intensity := 0.0
var _overlay: ColorRect
var _material: ShaderMaterial
var _camera: Camera3D
var _base_fov := 75.0


# Builds the overlay for the local player only
func _ready() -> void:
	if player == null or not player.is_multiplayer_authority():
		set_process(false)
		return
	_camera = player.get_node_or_null("%Camera3D") as Camera3D
	if _camera:
		_base_fov = _camera.fov
	_build_overlay()


# Puts the camera back and removes the overlay
func _exit_tree() -> void:
	if _camera:
		_camera.fov = _base_fov
	if _overlay and is_instance_valid(_overlay):
		_overlay.queue_free()


# Strength follows how fast the player is moving
func _process(delta: float) -> void:
	if player == null:
		return
	var speed := player.velocity.length()
	var span := maxf(full_speed - start_speed, 0.01)
	var target := clampf((speed - start_speed) / span, 0.0, 1.0)
	target *= target
	_intensity = lerpf(_intensity, target, 1.0 - exp(-delta * 8.0))
	_apply_effect()


# Full screen color rect the wind shader draws on
func _build_overlay() -> void:
	var hud := player.get_node_or_null("CanvasLayer") as CanvasLayer
	if hud == null:
		return
	_material = ShaderMaterial.new()
	_material.shader = WIND_SHADER
	_material.set_shader_parameter("intensity", 0.0)
	_overlay = ColorRect.new()
	_overlay.name = "WindOverlay"
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.color = Color.WHITE
	_overlay.material = _material
	_overlay.visible = false
	hud.add_child(_overlay)
	hud.move_child(_overlay, 0)


# Shows the wind and widens the camera with speed
func _apply_effect() -> void:
	var live := _intensity > 0.02
	if _overlay:
		_overlay.visible = live
	if _material:
		_material.set_shader_parameter("intensity", _intensity)
	if _camera:
		_camera.fov = _base_fov + max_fov_boost * _intensity
