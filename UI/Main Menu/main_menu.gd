# INFO Main menu for joining or hosting a session

extends CanvasLayer
@onready var button_join: Button = %ButtonJoin
@onready var button_quit: Button = %ButtonQuit

@onready var tube: VBoxContainer = %Tube
@onready var enet: VBoxContainer = %Enet
@onready var label_session: Label = %Label_Session
@onready var session_edit: LineEdit = %Session_Edit
@onready var label_username: Label = %Label_Username
@onready var username_edit: LineEdit = %Username_Edit
@onready var button_join_tube: Button = %ButtonJoinTube
@onready var button_quit_tube: Button = %ButtonQuitTube
@onready var button_create_tube: Button = %ButtonCreateTube

const LOBBY_SCENE = preload("res://Scenes/UI/Lobby.tscn")

# Hooks the menu buttons and the volume sliders
func _ready() -> void:
	
	if Network.tube_enabled:
		enet.hide()
	else:
		tube.hide()

	button_join.pressed.connect(on_join)
	button_quit.pressed.connect(func() -> void:
		GameAudio.play_ui()
		get_tree().quit()
	)
	
	username_edit.placeholder_text = "Required"
	session_edit.placeholder_text = "Session code"
	session_edit.text_changed.connect(_update_menu_buttons)
	username_edit.text_changed.connect(_update_menu_buttons)
	button_join_tube.pressed.connect(on_join_tube)
	button_quit_tube.pressed.connect(func() -> void:
		GameAudio.play_ui()
		get_tree().quit()
	)
	button_create_tube.pressed.connect(on_create_tube)
	button_join_tube.pressed.connect(func() -> void: GameAudio.play_ui())
	button_create_tube.pressed.connect(func() -> void: GameAudio.play_ui())
	var menu_box := tube.get_parent().get_parent() as VBoxContainer
	GameAudio.mount_volume_sliders(menu_box)
	_update_menu_buttons()
	
	Network.tube_client.error_raised.connect(on_error_raised)
	
	if OS.has_feature('server'):
		Network.start_server()
		await get_tree().create_timer(0.1).timeout
		add_world()

# Joins the local server
func on_join():
	Network.join_server()
	

# Loads the map for a dedicated server
func add_world():
	var new_world = Network.WORLD_SCENE.instantiate()
	new_world.name = Network.WORLD_NODE_NAME
	get_tree().current_scene.add_child(new_world)
	hide()


# Joins an online session with the typed code
func on_join_tube():
	if not _has_valid_name() or session_edit.text.strip_edges() == "":
		return
	Global.username = username_edit.text.strip_edges()
	Network.tube_join(session_edit.text.strip_edges())
	_open_lobby()

# Hosts a new online session
func on_create_tube():
	if not _has_valid_name():
		return
	Global.username = username_edit.text.strip_edges()
	Network.tube_create()
	_open_lobby()


# Opens the lobby and hides this menu
func _open_lobby() -> void:
	var lobby := LOBBY_SCENE.instantiate()
	get_tree().current_scene.add_child(lobby)
	hide()


# True when a name has been typed
func _has_valid_name() -> bool:
	return username_edit.text.strip_edges() != ""


# Enables join and host once a name, and a code for join, is filled in
func _update_menu_buttons(_new_text: String = "") -> void:
	var named := _has_valid_name()
	if named:
		Global.username = username_edit.text.strip_edges()
	button_create_tube.disabled = not named
	button_join_tube.disabled = not named or session_edit.text.strip_edges() == ""

# Drops the session only when the error is fatal
func on_error_raised(code, message):
	push_warning("Tube session error: %s" % message)
	# This menu only hides when a session starts, so it keeps hearing about
	# errors as the host. Signaling warnings are not a reason to drop a
	# session that is already running.
	if not Network.is_fatal_session_error(code):
		return

	session_edit.text = ''
	button_join_tube.add_theme_color_override('font_disabled_color', Color.DARK_RED)
	_update_menu_buttons()

	if not Network.should_leave_on_error(code):
		return
	if visible:
		Network.clean_up_signals()
	else:
		Network.leave_server()
