# INFO Score, clock, and the round banners

extends CanvasLayer

@onready var score_list: VBoxContainer = %ScoreList
@onready var winner_panel: Control = %WinnerPanel
@onready var winner_label: Label = %WinnerLabel
@onready var next_round_label: Label = %NextRoundLabel
@onready var round_label: Label = %RoundLabel
@onready var button_leave: Button = %ButtonLeave
@onready var countdown_panel: Control = %CountdownPanel
@onready var countdown_label: Label = %CountdownLabel
@onready var countdown_mode_label: Label = get_node_or_null("%CountdownMode")
@onready var title_label: Label = %Title
@onready var clock_label: Label = %ClockLabel

var _intermission := 0.0


# Hides the banners and starts listening for score changes
func _ready() -> void:
	winner_panel.hide()
	countdown_panel.hide()
	button_leave.pressed.connect(func(): Network.leave_server())
	Network.scores_changed.connect(_refresh_scores)
	Network.match_ended.connect(_on_match_ended)
	Network.round_started.connect(_on_round_started)
	Network.countdown_started.connect(_on_countdown_started)
	round_label.text = "Round %d" % Network.round_number
	_refresh_title()
	_refresh_scores()
	if Network.is_round_locked():
		_on_countdown_started()


# Updates the countdown, the clock, and the next round timer
func _process(delta: float) -> void:
	if Network.is_round_locked():
		countdown_panel.show()
		countdown_label.text = str(maxi(1, int(ceil(Network.countdown_remaining))))
		_refresh_countdown_mode()
	elif countdown_panel.visible:
		countdown_panel.hide()

	_refresh_clock()

	if _intermission <= 0.0:
		return
	_intermission = maxf(_intermission - delta, 0.0)
	next_round_label.text = "Next: %s in %d..." % [
		Network.rule_title(Network.next_rule()),
		int(ceil(_intermission)),
	]


# Writes the mode, the point limit, and the clock into the title
func _refresh_title() -> void:
	var bits: PackedStringArray = PackedStringArray()
	bits.append(Network.rule_title())
	if Network.current_rule == Network.RULE_DEATHMATCH:
		bits.append("First to %d kills" % Network.kill_limit)
	elif Network.current_rule == Network.RULE_POINT_CAPTURE:
		bits.append("First to %d captures" % Network.kill_limit)
	if Network.time_limit > 0:
		bits.append("%s clock" % Network.format_clock(float(Network.time_limit)))
	title_label.text = " · ".join(bits)


# Shows the rule name on the countdown
func _refresh_countdown_mode() -> void:
	if countdown_mode_label:
		countdown_mode_label.text = Network.rule_title()


# Updates the match clock
func _refresh_clock() -> void:
	if Network.time_limit <= 0:
		clock_label.hide()
		return
	clock_label.show()
	if Network.is_round_locked() or Network.match_time_remaining <= 0.0:
		if Network.match_in_progress and Network.winner_id == -1:
			clock_label.text = Network.format_clock(float(Network.time_limit))
		else:
			clock_label.text = "0:00"
		return
	clock_label.text = Network.format_clock(Network.match_time_remaining)


# Rebuilds the score list, by team or by player
func _refresh_scores() -> void:
	for child in score_list.get_children():
		child.queue_free()

	if Network.is_team_match():
		_refresh_team_scores()
		return

	var entries: Array = []
	for id_str in Network.lobby_members:
		entries.append({
			"id": id_str,
			"name": str(Network.lobby_members[id_str].get("name", "Player")),
			"kills": int(Network.scores.get(id_str, 0)),
		})
	entries.sort_custom(func(a, b): return int(a["kills"]) > int(b["kills"]))

	for entry in entries:
		var label := Label.new()
		var local_tag := "  <<" if str(entry["id"]) == str(multiplayer.get_unique_id()) else ""
		label.text = "%s  %d%s" % [entry["name"], entry["kills"], local_tag]
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.add_theme_color_override(
			"font_color", Network.team_color(int(entry["id"]))
		)
		score_list.add_child(label)


# Score rows for each team
func _refresh_team_scores() -> void:
	var entries: Array = []
	for team in Teams.active(Network.team_count):
		entries.append({
			"team": int(team),
			"kills": Network.get_team_score(int(team)),
		})
	entries.sort_custom(func(a, b): return int(a["kills"]) > int(b["kills"]))

	var my_team := Network.get_member_team(multiplayer.get_unique_id())
	for entry in entries:
		var label := Label.new()
		var local_tag := "  <<" if int(entry["team"]) == my_team else ""
		label.text = "%s  %d%s" % [
			Teams.team_name(int(entry["team"])),
			int(entry["kills"]),
			local_tag,
		]
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.add_theme_color_override(
			"font_color", Teams.color(int(entry["team"]))
		)
		score_list.add_child(label)


# Shows who won and starts the next round timer
func _on_match_ended(peer_id: int) -> void:
	if Network.winner_team != Teams.NONE:
		var team_name := Teams.team_name(Network.winner_team)
		if Network.get_member_team(multiplayer.get_unique_id()) == Network.winner_team:
			winner_label.text = "Your team wins!"
		else:
			winner_label.text = "%s wins!" % team_name
	else:
		var winner_name := Network.get_member_name(peer_id)
		if peer_id == multiplayer.get_unique_id():
			winner_label.text = "You win!"
		else:
			winner_label.text = "%s wins!" % winner_name
	winner_panel.show()
	_intermission = Network.ROUND_INTERMISSION
	next_round_label.text = "Next: %s in %d..." % [
		Network.rule_title(Network.next_rule()),
		int(ceil(_intermission)),
	]
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


# Hides the winner banner and shows the new round
func _on_round_started(round_number: int) -> void:
	_intermission = 0.0
	winner_panel.hide()
	round_label.text = "Round %d" % round_number
	_refresh_title()
	_refresh_scores()


# Shows the countdown at the start of a round
func _on_countdown_started() -> void:
	winner_panel.hide()
	_intermission = 0.0
	countdown_panel.show()
	countdown_label.text = str(maxi(1, int(ceil(Network.countdown_remaining))))
	_refresh_countdown_mode()
	# Winner banner freed the mouse; take it back so play can start on 0.
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
