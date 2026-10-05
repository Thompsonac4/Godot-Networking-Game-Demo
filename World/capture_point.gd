# INFO One capture pad on the map

extends Area3D

const GROUP := "CapturePoints"

@onready var _pad: MeshInstance3D = $Pad
@onready var _ring: MeshInstance3D = $Ring
@onready var _light: OmniLight3D = $OmniLight3D
@onready var _bar_sprite: Sprite3D = $BarSprite
@onready var _bar_viewport: SubViewport = $BarViewport
@onready var _bar: ProgressBar = %CaptureBar
@onready var _status: Label3D = $Status

var point_index := 0
var is_live := false
var progress := 0.0
var side := 0
var contested := false

var _pad_mat: StandardMaterial3D
var _ring_mat: StandardMaterial3D
var _pulse := 0.0


# Joins the capture point group
func _enter_tree() -> void:
	add_to_group(GROUP)


# Sets up the pad visuals and starts idle
func _ready() -> void:
	collision_layer = 0
	collision_mask = 2
	monitoring = false
	monitorable = false
	_prepare_visuals()
	apply_state(false, 0.0, 0, false)


# Makes unique materials so each pad can tint on its own
func _prepare_visuals() -> void:
	if _pad:
		_pad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if _pad.material_override is StandardMaterial3D:
			_pad_mat = (_pad.material_override as StandardMaterial3D).duplicate()
			_pad_mat.next_pass = null
			_pad.material_override = _pad_mat
	if _ring:
		_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if _ring.material_override is StandardMaterial3D:
			_ring_mat = (_ring.material_override as StandardMaterial3D).duplicate()
			_ring_mat.next_pass = null
			_ring.material_override = _ring_mat
	if _status:
		_status.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _bar_sprite:
		_bar_sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var sprite_mat := StandardMaterial3D.new()
		sprite_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sprite_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sprite_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		sprite_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		if _bar_viewport:
			sprite_mat.albedo_texture = _bar_viewport.get_texture()
		_bar_sprite.material_override = sprite_mat
		if _bar_viewport:
			_bar_sprite.texture = _bar_viewport.get_texture()


# Pulses the ring while the point is live
func _process(delta: float) -> void:
	if not is_live:
		return
	if _ring:
		_ring.rotate_y(delta * 1.8)
	_pulse += delta
	var glow := 1.15 + sin(_pulse * 4.0) * 0.35
	if _light:
		_light.light_energy = glow
	if _ring_mat:
		_ring_mat.emission_energy_multiplier = glow


# Living players standing on this pad
func living_players() -> Array[Node]:
	var found: Array[Node] = []
	if not is_live or not monitoring:
		return found
	for body in get_overlapping_bodies():
		if body == null or not body.is_in_group("Players"):
			continue
		var health: Node = body.get_node_or_null("health_controller")
		if health and health.get("is_dead"):
			continue
		found.append(body)
	return found


# Updates the color, the bar, and the status text
func apply_state(live: bool, amount: float, capture_side: int, is_contested: bool) -> void:
	is_live = live
	progress = amount
	side = capture_side
	contested = is_contested
	monitoring = live
	# Keep this Area3D visible so the SubViewport texture stays valid.
	# GLES3 crashes if Sprite3D/Label3D are shown later with a null material.
	if _pad:
		_pad.visible = live
	if _ring:
		_ring.visible = live
	if _bar_sprite:
		_bar_sprite.visible = live
	if _status:
		_status.visible = live
		if live and _status.text == "":
			_status.text = "CAPTURE"
	if _light:
		_light.visible = live

	var tint := Color(0.35, 0.38, 0.42)
	if live:
		if contested:
			tint = Color(0.92, 0.78, 0.22)
		elif capture_side != 0:
			tint = Network.capture_color(capture_side)
		else:
			tint = Color(0.72, 0.86, 1.0)
	if _pad_mat:
		_pad_mat.albedo_color = tint.darkened(0.45 if live else 0.72)
		_pad_mat.emission_enabled = live
		_pad_mat.emission = tint
		_pad_mat.emission_energy_multiplier = 0.7 if live else 0.0
	if _ring_mat:
		_ring_mat.albedo_color = Color(tint.r, tint.g, tint.b, 0.72 if live else 0.18)
		_ring_mat.emission = tint
		_ring_mat.emission_energy_multiplier = 1.4 if live else 0.15
	if _light:
		_light.light_color = tint

	if _bar:
		_bar.max_value = 1.0
		_bar.value = amount
		var fill := _bar.get_theme_stylebox("fill")
		if fill is StyleBoxFlat:
			var box := (fill as StyleBoxFlat).duplicate()
			box.bg_color = tint
			_bar.add_theme_stylebox_override("fill", box)
	if _status:
		if not live:
			_status.text = "CAPTURE"
		elif contested:
			_status.text = "CONTESTED"
			_status.modulate = Color(1.0, 0.86, 0.3)
		elif capture_side != 0:
			_status.text = "CAPTURING"
			_status.modulate = tint
		else:
			_status.text = "CAPTURE"
			_status.modulate = Color(0.85, 0.92, 1.0)
