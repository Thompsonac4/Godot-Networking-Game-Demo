# INFO Lobby screen for picking a character, team, and match rules

extends CanvasLayer

const MELEE_DESC := "Shovel fighter. Close-range melee."
const RANGED_DESC := "Bow fighter. Hold left click to draw (up to 250 damage). Right click fires a 3-arrow rapid burst."

@onready var label_session: Label = %LabelSession
@onready var button_copy: Button = %ButtonCopy
@onready var player_list: ItemList = %PlayerList
@onready var button_melee: Button = %ButtonMelee
@onready var button_ranged: Button = %ButtonRanged
@onready var button_start: Button = %ButtonStart
@onready var button_leave: Button = %ButtonLeave
@onready var label_status: Label = %LabelStatus
@onready var character_desc: Label = %CharacterDesc

@onready var button_ffa: Button = %ButtonFfa
@onready var button_teams: Button = %ButtonTeams
@onready var team_count_row: Control = %TeamCountRow
@onready var option_team_count: OptionButton = %OptionTeamCount
@onready var assign_label: Label = %AssignLabel
@onready var team_buttons: GridContainer = %TeamButtons
@onready var check_deathmatch: CheckBox = %CheckDeathmatch
@onready var check_point_capture: CheckBox = %CheckPointCapture
@onready var check_coin_chase: CheckBox = %CheckCoinChase
@onready var kill_limit_row: Control = %KillLimitRow
@onready var spin_kill_limit: SpinBox = %SpinKillLimit
@onready var spin_time_limit: SpinBox = %SpinTimeLimit

## team id -> Button
var _team_buttons: Dictionary = {}
var _syncing_rules := false


# Hooks the lobby buttons and fills the list
func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	button_melee.button_pressed = true
	button_ranged.button_pressed = false
	button_melee.pressed.connect(_on_melee_pressed)
	button_ranged.pressed.connect(_on_ranged_pressed)
	button_start.pressed.connect(_on_start_pressed)
	button_leave.pressed.connect(func(): Network.leave_server())
	button_copy.pressed.connect(_copy_session)

	_team_buttons = {
		Teams.RED: %ButtonTeamRed,
		Teams.BLUE: %ButtonTeamBlue,
		Teams.GREEN: %ButtonTeamGreen,
		Teams.YELLOW: %ButtonTeamYellow,
	}
	for team in _team_buttons:
		var button: Button = _team_buttons[team]
		button.add_theme_color_override("font_color", Teams.color(team))
		button.pressed.connect(_on_team_pressed.bind(team))

	button_ffa.pressed.connect(func(): Network.host_set_game_mode(Network.MODE_FFA))
	button_teams.pressed.connect(func(): Network.host_set_game_mode(Network.MODE_TEAMS))
	option_team_count.item_selected.connect(_on_team_count_selected)
	check_deathmatch.toggled.connect(_on_rule_toggled.bind(Network.RULE_DEATHMATCH))
	check_point_capture.toggled.connect(_on_rule_toggled.bind(Network.RULE_POINT_CAPTURE))
	check_coin_chase.toggled.connect(_on_rule_toggled.bind(Network.RULE_COIN_CHASE))
	spin_kill_limit.value_changed.connect(_on_kill_limit_changed)
	spin_time_limit.value_changed.connect(_on_time_limit_changed)
	# Team buttons only make sense once someone is picked.
	player_list.item_selected.connect(func(_index): _refresh_team_controls())

	Network.lobby_changed.connect(_refresh)
	Network.match_started.connect(_on_match_started)
	Network.tube_client.error_raised.connect(_on_error)
	_refresh()


# Picks the shovel fighter
func _on_melee_pressed() -> void:
	button_melee.button_pressed = true
	button_ranged.button_pressed = false
	if character_desc:
		character_desc.text = MELEE_DESC
	Network.select_character(Network.CHARACTER_MELEE)


# Picks the bow fighter
func _on_ranged_pressed() -> void:
	button_ranged.button_pressed = true
	button_melee.button_pressed = false
	if character_desc:
		character_desc.text = RANGED_DESC
	Network.select_character(Network.CHARACTER_RANGED)


# Host starts the match
func _on_start_pressed() -> void:
	Network.host_start_match()


# Host puts the selected player on that team
func _on_team_pressed(team: int) -> void:
	var peer_id := _selected_peer_id()
	if peer_id > 0:
		Network.host_assign_team(peer_id, team)


# Host changes how many teams are in play
func _on_team_count_selected(index: int) -> void:
	Network.host_set_team_count(option_team_count.get_item_id(index))


# Host toggles a playlist rule
func _on_rule_toggled(on: bool, rule: String) -> void:
	if _syncing_rules:
		return
	Network.host_set_rule(rule, on)


# Host changes the point limit
func _on_kill_limit_changed(value: float) -> void:
	if _syncing_rules:
		return
	Network.host_set_kill_limit(int(value))


# Host changes the round clock, in minutes
func _on_time_limit_changed(value: float) -> void:
	if _syncing_rules:
		return
	Network.host_set_time_limit(int(value) * 60)


# Player currently selected in the list
func _selected_peer_id() -> int:
	var selected := player_list.get_selected_items()
	if selected.is_empty():
		return -1
	return int(player_list.get_item_metadata(selected[0]))


# Copies the session code
func _copy_session() -> void:
	DisplayServer.clipboard_set(Network.tube_client.session_id)


# Rebuilds the player list and the host controls
func _refresh() -> void:
	var session := str(Network.tube_client.session_id)
	label_session.text = "Session: " + session if session != "" else "Session: connecting..."

	# Rebuilding the list drops the selection, so put it back afterwards.
	var was_selected := _selected_peer_id()
	player_list.clear()
	for id_str in Network.lobby_members:
		var peer_id := int(id_str)
		var member: Dictionary = Network.lobby_members[id_str]
		var display_name := str(member.get("name", "Player"))
		var character := str(member.get("character", Network.CHARACTER_MELEE)).capitalize()
		var team := int(member.get("team", Teams.NONE))
		var suffix := " (you)" if peer_id == multiplayer.get_unique_id() else ""
		var host_tag := " [Host]" if peer_id == 1 else ""
		var team_tag := ""
		if Network.game_mode == Network.MODE_TEAMS:
			team_tag = " · %s" % Teams.team_name(team)
		var index := player_list.add_item(
			"%s — %s%s%s%s" % [display_name, character, team_tag, host_tag, suffix]
		)
		player_list.set_item_metadata(index, peer_id)
		player_list.set_item_custom_fg_color(index, Teams.color(team))
		if peer_id == was_selected:
			player_list.select(index)

	var is_host := _is_host()
	button_start.visible = is_host
	button_start.disabled = Network.lobby_members.is_empty()
	var mine: Dictionary = Network.lobby_members.get(str(multiplayer.get_unique_id()), {})
	var selected := str(mine.get("character", Network.CHARACTER_MELEE))
	button_ranged.button_pressed = selected == Network.CHARACTER_RANGED
	button_melee.button_pressed = selected != Network.CHARACTER_RANGED
	if character_desc:
		character_desc.text = RANGED_DESC if selected == Network.CHARACTER_RANGED else MELEE_DESC

	_refresh_team_controls()

	if is_host:
		label_status.text = "Start when everyone is ready."
	elif Network.lobby_members.is_empty():
		label_status.text = "Connecting to lobby..."
	else:
		label_status.text = "Waiting for host to start."


# Shows team and rule controls based on what the host picked
func _refresh_team_controls() -> void:
	var is_host := _is_host()
	var teams_on: bool = Network.game_mode == Network.MODE_TEAMS

	button_ffa.button_pressed = not teams_on
	button_teams.button_pressed = teams_on
	button_ffa.disabled = not is_host
	button_teams.disabled = not is_host

	team_count_row.visible = teams_on
	option_team_count.disabled = not is_host
	for i in option_team_count.item_count:
		if option_team_count.get_item_id(i) == Network.team_count:
			option_team_count.selected = i

	# Only the host moves people around.
	assign_label.visible = teams_on and is_host
	team_buttons.visible = teams_on and is_host
	var has_selection := _selected_peer_id() > 0
	var active := Teams.active(Network.team_count)
	for team in _team_buttons:
		var button: Button = _team_buttons[team]
		button.visible = active.has(team)
		button.disabled = not has_selection

	_syncing_rules = true
	check_deathmatch.button_pressed = Network.has_rule(Network.RULE_DEATHMATCH)
	check_point_capture.button_pressed = Network.has_rule(Network.RULE_POINT_CAPTURE)
	check_coin_chase.button_pressed = Network.has_rule(Network.RULE_COIN_CHASE)
	check_deathmatch.disabled = not is_host
	check_point_capture.disabled = not is_host
	check_coin_chase.disabled = true
	kill_limit_row.visible = (
		Network.has_rule(Network.RULE_DEATHMATCH)
		or Network.has_rule(Network.RULE_POINT_CAPTURE)
	)
	spin_kill_limit.editable = is_host
	spin_kill_limit.value = Network.kill_limit
	spin_time_limit.editable = is_host
	spin_time_limit.value = Network.time_limit / 60
	_syncing_rules = false


# True for the player who created the session
func _is_host() -> bool:
	return Network.tube_client.peer_id == 1


# Closes the lobby when the match starts
func _on_match_started() -> void:
	queue_free()


# Leaves if the session failed, otherwise warns about signaling
func _on_error(code: int, message: String) -> void:
	push_warning("Tube session error: %s" % message)
	if Network.should_leave_on_error(code):
		Network.leave_server()
		return
	if not Network.is_fatal_session_error(code):
		label_status.text = "Signaling trouble — new players may not be able to join."
