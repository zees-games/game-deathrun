extends "dr_module_base.gd"
## The module's course vote and the cvar helpers it shares with the rest of the module. No
## `class_name`: a module in a pack cannot have one; [code]dr_module.gd[/code] extends this.

## The drawn ballot's notice topic. The client shell draws one menu per topic.
const COURSE_BALLOT_TOPIC := &"map_ballot"


## A number as an operator would type it: `34`, not `34.000000`.
static func _number(value: float) -> String:
	# Not `%g`, which GDScript's format strings lack: it parses, then fails at runtime inside
	# `_game_load`, which unwinds the whole module (buses-from-hell's netcode came up, then the
	# game would not load).
	return "%d" % int(round(value)) if is_equal_approx(value, round(value)) else "%.3f" % value


## One cvar, its default the value the world was built with, not a literal: a second copy would
## undo `defaults < JSON < environment < argv` (`DR_ROUND_SECONDS=240` reported as 300, then reset).
## [param at_least] refuses a lower value or a non-number with the reason; it never clamps.
func _tunable(
	cvar_name: String, current: float, description: String, apply: Callable, at_least: float = NAN
) -> void:
	var cvar := add_cvar(cvar_name, _number(current), description)

	if cvar == null:
		return

	if not is_nan(at_least):
		var _v := cvar.with_validator(_at_least.bind(cvar_name, at_least))

	# The handler must not capture `cvar`: it would be a reference cycle the engine never frees.
	cvar.changed.connect(func(_old: String, new_value: String) -> void:
		apply.call(new_value.to_float())
		log_info("a tunable changed", {"cvar": cvar_name, "now": new_value})
	)


static func _at_least(value: String, cvar_name: String, least: float) -> DotResult:
	if not value.is_valid_float() or value.to_float() < least:
		return DotResult.fail(DotError.CODE_INVALID,
			"%s is %s; it takes a number of %s or more." % [cvar_name, value, _number(least)])
	return DotResult.success(value)


## The players' vote for the next course, over dot-vote (`!vote`, `!rtv`, `!nominate`): opened
## [member DrVote.open_after_sec] into every course and applied when the round ends, because a
## round here is a course; see [code]game/dr_vote.gd[/code].
func _build_vote(world: DrGame) -> void:
	# A server owner turns it off or reshapes it in `user://cfg/deathrun_vote.json` or `game.yml`'s
	# `metadata: course_vote:`, keyed as dot-vote's [DotVoteRules]. One that cannot be built is a
	# WARN and the rotation alone, never a server that will not start.
	if world.catalogue == null:
		return

	vote = DrVote.new()
	vote.name = "CourseVote"
	vote.commands_spec_fn = world.rotation_commands
	vote.in_rotation_fn = func(id: StringName) -> bool: return world.catalogue.in_rotation(id)
	vote.maps_fn = func() -> Array:
		var out: Array = []

		# The game's own courses only: the Workshop's come from the source's own follow, which
		# reads the index on every ballot and so shows none of them online.
		for id in world.catalogue.rotating(world.config.course_ids):
			if not world.catalogue.is_workshop(id):
				out.append([id, str((world.catalogue.courses.get(id, {}) as Dictionary).get("name", id))])

		return out
	vote.apply_fn = func(id: StringName) -> DotResult:
		world.next_course_id = id
		return DotResult.success(id)
	# People only: a stand-in is not a voter, and a ballot it could swing is not the players'.
	vote.voters_fn = func() -> Array:
		var out: Array = []

		for id: Variant in world.players:
			var player: DrPlayer = world.players[id]

			if player == null or player.is_bot:
				continue

			var userid := DrNetBridge.session_of(StringName(str(id)))

			if userid > 0:
				out.append(StringName(str(userid)))

		return out
	_wire_vote_server()

	# Whether a round is live, for `time_up: finish_round`: warmup and the gap between rounds
	# have nothing to play out, so a limit that runs out there changes at once. No match is
	# "cannot tell", which holds as before.
	vote.round_in_progress_fn = func() -> bool:
		return world.match_node == null or world.match_node.is_live()

	add_child(vote)
	var ready := vote.setup()

	if not ready.ok:
		DotLog.result(CHANNEL, "the course vote; the rotation alone chooses", ready)
		vote.queue_free()
		vote = null
		return

	var commanded := vote.install_commands(self)
	DotLog.result(CHANNEL, "the course vote's commands", commanded)

	_wire_vote_world(world)


## The vote's hooks into the server: announcing, admins, the drawn ballot and who a voter is.
func _wire_vote_server() -> void:
	vote.announce_fn = func(line: String) -> void:
		var chat: Object = services.get("chat") if services != null else null

		if chat != null:
			var _said: Variant = chat.call("announce", line, DrServices.CH_ALL)
		elif server != null:
			server.broadcast_message(line)
	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null
		return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)
	vote.ballot_fn = func(state: Dictionary) -> void:
		if server == null:
			return

		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = str(session.userid)
			server.send_notice(session, DotNotice.make(
				&"", "", float(state.get("seconds", -1.0)), COURSE_BALLOT_TOPIC, data
			))
	vote.people_fn = func(voter: StringName) -> Dictionary:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null

		if session == null:
			return {}

		var avatar: Variant = session.identity.get("avatar_url") if session.identity != null else ""
		return {"name": session.display_name, "avatar": avatar if avatar is String else ""}


## The vote's hooks into the world: the map menu, its cvar, and the plays, rounds and leavers it counts.
func _wire_vote_world(world: DrGame) -> void:
	# The map menu (M), dot-vote's: a player holding the owner's `sv_map_menu_flag` changes the
	# course now, not next round, and sees the same rows a solo player does. Read by name,
	# because a server on a dot-vote older than the menu has no `map_menu` and runs without it.
	var menu_half: Variant = vote.commands.get(&"map_menu") if vote.commands != null else null
	if menu_half is Object:
		(menu_half as Object).set(&"change_fn", world.change_course_now)
		(menu_half as Object).set(&"rows_fn", func(_rows: Array) -> Array: return world.course_rows())

	_tunable("dr_vote_after", vote.open_after_sec,
		"Seconds into a course before the vote for the next one opens",
		func(value: float) -> void:
			if vote != null:
				vote.open_after_sec = maxf(value, 0.0))

	# No note_map for the course already built: start() builds it again, which is a
	# world_rebuilt, and two begin()s for one play is one play counted twice in the cooldowns.
	world.world_rebuilt.connect(func() -> void:
		if vote != null and world.stage != null:
			vote.note_map(world.stage.id())
	)
	world.match_node.round_ended.connect(func(_number: int, _winner: int, _outcome: int) -> void:
		if vote != null:
			vote.note_round_end()
	)

	if server != null:
		server.client_disconnected.connect(func(session: DotClientSession, _reason: String) -> void:
			if vote != null:
				vote.forget_voter(StringName(str(session.userid)))
		)
