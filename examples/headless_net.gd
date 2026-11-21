extends "headless_net_offline.gd"
const DrTestToys := preload("dr_test_toys.gd")


## The real path minus the socket: two worlds, two managers, two bridges, two links with the
## RPC replaced by a queue — so the codec, the seal, the snapshots, the prediction and the
## reconciliation all run, in one process, in two physics worlds.
##
## [b]What this suite is for is the claim the whole game rests on:[/b] a course is sent once,
## as a document, and after that a press is ONE event — a trap and the tick it went on — from
## which the client works out where every part of that trap is at every tick that follows. If
## that is false, a trapdoor the client draws shut is open on the server, and a runner's own
## prediction carries them across a floor that is not there. So this asserts it from both
## ends — the same transform at the same tick, the same answer to "does this kill" — and that a
## client carried by a falling block is carried by its own prediction; and then everything else
## that crosses: the sides, the finish, the end, the result, a joiner told what was pressed.
##
## Sections and checks are both counted; mg-smash-copter's notes say why the second matters.

const SECTIONS := 19
const CHECKS := 114


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	DrCatalogue.practice_toys = DrTestToys.PRACTICE
	print("deathrun over the wire")
	print("")

	var errors := EngineErrors.new()
	OS.add_logger(errors)

	_test_the_codec()
	_test_neutralise()

	if await _build():
		await _test_a_client_joins()
		await _test_the_course_arrives()
		await _test_the_local_player_is_predicted()
		await _test_free_roam_crosses()
		await _test_the_flashlight_crosses()
		await _test_a_press_agrees()
		await _test_a_carry_is_predicted()
		await _test_the_end_crosses()
		await _test_the_toys_reach_the_client()
		await _test_a_teleport_is_predicted()
		await _test_leaving()
		await _test_killcam_icon()

	_test_the_remote_workbench()

	OS.remove_logger(errors)
	# Engine errors go to stderr and change no exit code: six `!is_inside_tree()` from a toy
	# pulled after its course was rebuilt mid-tick printed on every green run of this suite.
	var seen := errors.seen()
	_check(seen.is_empty(), "the engine reported no error over the whole run",
		"%d: %s" % [seen.size(), ", ".join(seen.slice(0, 3))])

	_report_sections(_sections_entered, _sections_finished, SECTIONS, CHECKS)


# --- The codec ------------------------------------------------------------------


# --- Bringing both halves up ---------------------------------------------------------

func _build() -> bool:
	_section("bringing both halves up")
	var failed_before := _failed

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	# The client's own physics space: two processes would be two worlds, and one world holding
	# both copies of a course is two of every collider in the same cubic metres.
	var client_view := SubViewport.new()
	client_view.name = "ClientView"
	client_view.own_world_3d = true
	client_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(client_view)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	client_view.add_child(client_side)

	_server_game = _make_game(true, server_side)
	_client_game = _make_game(false, client_side)
	await get_tree().process_frame

	_check(_server_game.get_world_3d() != _client_game.get_world_3d(), "two physics worlds, as two processes would have")
	_check(_client_game.stage.doc.is_empty() and _client_game.catalogue == null,
		"the client has no course and reads no course files; it will be sent one")

	Engine.physics_ticks_per_second = CLIENT_ENGINE_TICK_RATE

	_server_net = _make_manager(true, &"server", 1, server_side, SERVER_TICK_RATE)
	_client_net = _make_manager(false, &"client", CLIENT_PEER, client_side, CLIENT_ENGINE_TICK_RATE)
	# This harness stamps every command itself (`_tick + INPUT_LEAD`), not from the client's
	# clock, so the client must not ask for dot-net's input-lead report: steered by reports
	# about commands it never stamped, the clock runs away from them (only dot-net's cap
	# holds it). By the constant map, so this parses against a dot-net from before the report.
	var lead_bit := int((GSNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_INPUT_LEAD", 0))
	_client_net.messages.features &= ~lead_bit

	_server_bridge = DrNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)

	_client_bridge = DrNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	var attached := _server_bridge.attach(_server_game, _server_net)
	var client_attached := _client_bridge.attach(_client_game, _client_net)
	_check(attached.ok and client_attached.ok, "both bridges attach")

	_server_bridge.open_link(server_side)
	_client_bridge.open_link(client_side)
	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(_server_net.messages.schema_hash() == _client_net.messages.schema_hash(), "both ends agree on the schema")

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send
	_client_bridge.rtt_source = func() -> float: return 40.0

	var _s := _server_net.start()
	var _c := _client_net.start()

	_client_bridge.stage_received.connect(func(id: StringName) -> void:
		_heard["stage"] = id)
	_client_bridge.finished_received.connect(func(who: int, place: int, seconds: float) -> void:
		_heard["finished"] = [who, place, seconds])
	_client_bridge.trap_received.connect(func(index: int, tick: int, by: int) -> void:
		_heard["traps"] = int(_heard.get("traps", 0)) + 1
		_heard["trap"] = [index, tick, by])
	_client_bridge.hit_received.connect(func(point: Vector3, killed: bool, headshot: bool) -> void:
		_hits.append([point, killed, headshot]))
	_client_bridge.armed_received.connect(func(who: int, weapon: StringName) -> void:
		_heard["armed_%d" % who] = weapon)
	_client_bridge.round_changed.connect(func(n: int, began: bool, winner: int, why: String) -> void:
		if not began:
			_heard["round_over"] = [n, winner, why])

	_stand_in = _server_bridge.add_bot("Stand-in")
	_check(_stand_in != null and _stand_in.is_bot, "a stand-in is seated before anybody joins")
	# Seated as a stand-in, driven by the suite: a stand-in activator presses traps on its own,
	# and this suite presses them itself, when it wants them.
	_stand_in.is_bot = false

	# Started AFTER the bridge exists, which is what the module does: a course laid out before
	# anything listened to `world_rebuilt` would be a course no client is ever sent.
	_server_game.start()
	_check(not _server_game.stage.doc.is_empty(), "the server lays its course out on start")
	_finished()
	return _failed == failed_before


func _test_a_client_joins() -> void:
	_section("a client joins, and is told its side")
	# The READY first, as over ENet with loss: a client is PLAYING by its own reckoning once it has
	# sent `loaded`, on another channel, so its READY can reach the server before its seat. Kept,
	# and answered by the seat; a bridge that drops it never tells this client who it is.
	_client_bridge.ask_ready()
	_exchange()
	_check(_client_bridge.local_player_id != SESSION, "a READY before the seat is told nothing yet")
	var seated := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(seated.ok, "the server seats them")
	_exchange()
	_exchange()
	await _steps(6)

	_check(_client_bridge.local_player_id == SESSION, "the client is told who it is")
	_check(_client_game.tick_rate == SERVER_TICK_RATE and _client_game.stage.tick_rate == SERVER_TICK_RATE,
		"it adopts the server's tick rate, and so does its course", "%d / %d" % [_client_game.tick_rate, _client_game.stage.tick_rate])
	_check(Engine.max_physics_steps_per_frame >= ceili(0.25 * float(SERVER_TICK_RATE)),
		"the engine's step cap covers a quarter second at the adopted rate",
		"%d steps for %d Hz" % [Engine.max_physics_steps_per_frame, SERVER_TICK_RATE])
	_check(_client_game.players.size() == 2, "it has a body for itself and for the stand-in", "%d" % _client_game.players.size())

	# Into a round, with the client a runner and the stand-in at the buttons whatever the draw
	# said, and the server's world telling the client so the way a draw does.
	for _i in range(SERVER_TICK_RATE):
		if _server_game.phase == DrGame.Phase.COUNTDOWN:
			break
		await _step()

	_server_game._set_side(DrNetBridge.player_key(SESSION), DrGame.RUNNERS)
	_server_game._set_side(_stand_in.player_id, DrGame.ACTIVATORS)
	_server_game._place_everybody()
	await _steps(6)
	_check(_client_game.team_of(DrNetBridge.player_key(SESSION)) == DrGame.RUNNERS
		and _client_game.team_of(_stand_in.player_id) == DrGame.ACTIVATORS,
		"the client knows who is running and who is at the buttons")
	_finished()


func _test_the_course_arrives() -> void:
	_section("the course arrives, as the document the server built")
	_check(not _client_game.stage.doc.is_empty(), "the client built a course")
	_check(DrCourseDoc.digest(_client_game.stage.doc) == DrCourseDoc.digest(_server_game.stage.doc),
		"the same document, to the byte", DrCourseDoc.digest(_client_game.stage.doc))
	_check(_client_game.stage.pieces.size() == _server_game.stage.pieces.size()
		and _client_game.stage.trap_count() == _server_game.stage.trap_count(),
		"every piece and every trap", "%d, %d" % [_client_game.stage.pieces.size(), _client_game.stage.trap_count()])
	_check(_heard.has("stage"), "and the client said so")
	_finished()


var _client_peak := 0.0


## The claim: the aim bit a client sends is the server body's `aiming`, the rig's `BUTTON_AIM` and the pace of the motor on both ends.
## Armed: with `ensure_game_ticked` not copying `last_aim` onto the body, the aimed checks fail.
func _test_the_aim_bit_crosses() -> void:
	_section("the aim bit crosses the wire, slows the runner and the prediction agrees")
	var server_me: DrPlayer = _server_game.players[DrNetBridge.player_key(SESSION)]
	var rig: ZeeWeaponRig = server_me.weapons
	var armed := rig != null and rig.current_def() != null and _mine() != null
	_check(armed, "the server's runner holds a gun (from the section before)")
	if not armed:
		_finished()
		return

	var paced := _server_game.ads_rules.move_speed_for(rig.current_def().id)
	# The client's own drawn gun, as the client builds it when the player is armed (`_arm_locally`): a rig under the predicted player, no authority,
	# driven with the aim button every tick, which is what the prediction's pace reads (`step_controller`).
	var drawn := ZeeWeaponRig.new()
	drawn.name = "Weapons"
	drawn.role = ZeeWeaponRig.Role.SERVER
	drawn.authority = false
	drawn.tick_rate = _client_game.tick_rate
	drawn.player_ref = GSNodeRef.of_path(_mine().get_path())
	drawn.ads_rules = _client_game.ads_rules
	_mine().add_child(drawn)
	var drawn_ready := drawn.setup()
	var _drawn_given := drawn.give(rig.current_def().id)
	_check(drawn_ready.ok, "the client's drawn rig sets up", "" if drawn_ready.ok else drawn_ready.error.message)
	var drawn_tick := 500000
	var aim_step := func(command: GSFpsCommand, aim: bool) -> void:
		drawn_tick += 1
		var weapon_command := GSWeaponCommand.new()
		weapon_command.set_button(GSWeaponCommand.BUTTON_AIM, aim)
		var _o := drawn.simulate_tick(weapon_command, drawn_tick)
		await _step(command, aim)
	var start := server_me.global_position

	var run := func(direction: Vector2, aim: bool) -> float:
		var walk := GSFpsCommand.new()
		walk.move = direction
		server_me.place_at(start, 0.0)
		for _i in range(INPUT_LEAD + 8):
			await aim_step.call(null, false)
		var peak := 0.0
		var client_peak := 0.0
		for _i in range(SERVER_TICK_RATE / 2):
			await aim_step.call(walk, aim)
			var v := server_me.controller.state.velocity
			peak = maxf(peak, Vector2(v.x, v.z).length())
			var cv := _mine().controller.state.velocity
			client_peak = maxf(client_peak, Vector2(cv.x, cv.z).length())
		_client_peak = client_peak
		return peak
	var best := Vector2.ZERO
	var hip_run := 0.0
	for direction: Vector2 in [Vector2(0.0, 1.0), Vector2(1.0, 0.0), Vector2(-1.0, 0.0), Vector2(0.0, -1.0)]:
		var reach: float = await run.call(direction, false)
		if reach > hip_run:
			hip_run = reach
			best = direction
	_check(not server_me.aiming and rig.ads_move_scale() == 1.0, "unaimed, the server's body is not aiming and not slowed")

	var aimed_run: float = await run.call(best, true)
	var forward := GSFpsCommand.new()
	forward.move = best
	_check(server_me.aiming and _mine().aiming and absf(rig.ads_move_scale() - paced) < 0.001,
		"aimed, the server's body and the client's both are, and the rig is at the rules' pace",
		"server %s client %s scale %.2f of %.2f" % [server_me.aiming, _mine().aiming, rig.ads_move_scale(), paced])
	_check(hip_run > 0.5 and absf(aimed_run / hip_run - paced) < 0.1,
		"and the server's body walks at that pace", "hip %.2f m/s aimed %.2f m/s, ratio %.2f of %.2f" % [hip_run, aimed_run, aimed_run / maxf(hip_run, 0.001), paced])
	_check(absf(_client_peak - aimed_run) < 0.3, "the prediction, slowed alike, tops out where the server does",
		"client %.2f m/s, server %.2f m/s" % [_client_peak, aimed_run])

	for _i in range(INPUT_LEAD + 8):
		await aim_step.call(forward, false)
	_check(not server_me.aiming and rig.ads_move_scale() == 1.0, "let go, the pace comes back")
	_mine().remove_child(drawn)
	drawn.queue_free()
	_finished()


## The course's toys over the wire: paired by index on both ends, frozen copies, and a ball
## kicked on the server followed on the client.
func _test_the_toys_reach_the_client() -> void:
	_section("the course's toys reach the client")
	await _steps(4)
	var count := _server_game.stage.toys.count()
	_check(count > 0 and _server_bridge.toy_count() == count and _client_bridge.toy_count() == count,
		"every toy is an entity on both ends, paired by index", "%d toys, %d and %d" % [count, _server_bridge.toy_count(), _client_bridge.toy_count()])
	var server_ball := _server_game.stage.toys.toy(0)
	var client_ball := _client_game.stage.toys.toy(0)
	_check(client_ball.body.freeze and not client_ball.authoritative, "the client's are frozen copies")
	var start := client_ball.body.global_position
	var _kicked := _server_game.stage.toys.hit(server_ball.body, server_ball.body.global_position, Vector3(-1, 0.2, 0), 2.0)
	await _steps(60)
	var apart := client_ball.body.global_position.distance_to(server_ball.body.global_position)
	_check(client_ball.body.global_position.distance_to(start) > 0.5 and apart < 0.6,
		"a ball kicked on the server is followed on the client, and rests where the server's did",
		"%.2f m moved, %.2f m apart" % [client_ball.body.global_position.distance_to(start), apart])
	_finished()


func _test_the_local_player_is_predicted() -> void:
	_section("the local player is predicted, and the server agrees")
	await _run_open()
	var mine := _mine()
	var server_me: DrPlayer = _server_game.players[DrNetBridge.player_key(SESSION)]
	server_me.place_at(Vector3(0.0, 0.1, -4.0), 0.0)
	await _steps(20)
	var before := mine.controller.state.position
	var forward := GSFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _step(forward)
	_check(mine.controller.state.position.distance_to(before) > 0.01,
		"a key moves the client's own player on the tick it is pressed")
	await _steps(24, forward)
	await _steps(24)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(apart < 0.25, "and after running, the two ends agree", "%.3f m" % apart)
	_finished()


## The claim: one event per press, and from it the same trap at every tick on both ends.
func _test_a_press_agrees() -> void:
	_section("a press crosses as one event, and the trap is where the server has it at every tick")
	var heard_before := int(_heard.get("traps", 0))
	var pressed := _server_game.press(2, _stand_in.player_id)
	var pressed_on := _server_game.current_tick()
	await _steps(4)
	_check(pressed and int(_heard.get("traps", 0)) == heard_before + 1, "one TRAP event crossed",
		"%d" % (int(_heard.get("traps", 0)) - heard_before))
	_check(_client_game.stage.fired[2] == pressed_on, "carrying the tick it went on, not the tick it arrived",
		"%d / %d" % [_client_game.stage.fired[2], pressed_on])

	var worst := 0.0
	var agree := 0
	var asked := 0

	for offset in range(0, SERVER_TICK_RATE * 3, 5):
		var tick := pressed_on + offset
		_server_game.stage.pose_at(tick)
		_client_game.stage.pose_at(tick)

		for part_index in range((_server_game.stage.traps[2]["parts"] as Array).size()):
			var a: Node3D = _server_game.stage.traps[2]["parts"][part_index]["node"]
			var b: Node3D = _client_game.stage.traps[2]["parts"][part_index]["node"]
			worst = maxf(worst, a.transform.origin.distance_to(b.transform.origin))

		for at in [Vector3(0.5, 0.0, -27.0), Vector3(-2.5, 0.0, -26.0), Vector3(0.0, 0.0, -24.0)]:
			asked += 1
			if _server_game.stage.lethal_at(at, false, tick) == _client_game.stage.lethal_at(at, false, tick):
				agree += 1

	_check(worst < 0.0001, "the crusher is in the same place on both ends", "worst %.6f m" % worst)
	_check(agree == asked, "and both ends agree about who it kills, every time", "%d of %d" % [agree, asked])

	# A client that asks to be told everything again — a joiner — is told what was pressed.
	_client_game.stage.reset_traps()
	_client_bridge.ask_ready()
	_exchange()
	_exchange()
	await _steps(2)
	_check(_client_game.stage.fired[2] == pressed_on, "a joiner is told every trap already pressed, and when",
		"%d" % _client_game.stage.fired[2])
	_finished()


## Standing on a falling block, the client's own prediction carries them down with it.
func _test_a_carry_is_predicted() -> void:
	_section("a runner on a trap that moves is carried by their own prediction")
	var mine := _mine()
	var server_me: DrPlayer = _server_game.players[DrNetBridge.player_key(SESSION)]
	server_me.place_at(Vector3(1.0, 0.1, -35.5), 0.0)
	await _steps(30)
	var before := mine.controller.state.position.y
	_check(absf(before) < 0.3, "standing on the block, on the client", "y %.2f" % before)

	var _pressed := _server_game.press(3, _stand_in.player_id)
	var lowest := before

	# The tell, then the fall: trap_tell_seconds of nothing, then the block goes.
	for _i in range(16 + int(_server_game.config.trap_tell_seconds * float(_server_game.tick_rate))):
		await _step()
		lowest = minf(lowest, mine.controller.state.position.y)

	_check(lowest < before - 1.0, "the client's own player went down with it", "lowest y %.2f" % lowest)
	_finished()


func _test_the_end_crosses() -> void:
	_section("the end crosses: the finish, the weapon, the showdown, the result")
	await _wait_for_a_round()
	var server_me: DrPlayer = _server_game.players[DrNetBridge.player_key(SESSION)]
	server_me.place_at(_server_game.course_doc["finish"]["at"], 0.0)
	await _steps(10)
	_check(_heard.has("finished") and int(_heard["finished"][0]) == SESSION, "the finish is announced, with who")
	_check(_mine().finished and _mine().at_end, "the client's player is across and at the end")
	_check(_heard.has("armed_%d" % SESSION), "and was told what it was handed", str(_heard.get("armed_%d" % SESSION)))
	_check(_client_game.phase == DrGame.Phase.SHOWDOWN, "the client knows the activators were called")

	# The gun in their hand, as somebody else draws it: the client's copy of this player,
	# drawn as a watcher would (not its own first-person view), holds what the server handed.
	_check(server_me.weapons != null and server_me.weapons.ads_rules == _server_game.ads_rules, "the server rig takes the game's zee_ads_rules")
	var held_def := server_me.weapons.arsenal.current_def() if server_me.weapons != null else null
	var copy := _mine()
	var _shown := copy.present_body(false, copy.global_position, Color.WHITE)
	var hand := copy.figure.attachment(&"right_hand") if copy.figure != null else null
	_check(
		held_def != null and copy.figure != null and copy.figure.holding == held_def.id
			and copy.figure.held != null and copy.figure.held.equipped() == held_def.id
			and hand != null and hand.get_parent() is BoneAttachment3D,
		"a watcher draws the weapon in their hand (the person's gun-hand bone)",
		"%s drawn, %s held, dealt %s" % [
			String(copy.figure.holding) if copy.figure != null else "-",
			String(held_def.id) if held_def != null else "-", str(copy.dealt)
		]
	)

	await _steps(int(_server_game.config.arrival_grace_seconds * SERVER_TICK_RATE) + 4)
	_finished()

	await _test_a_hit_is_the_shooters()
	await _test_the_aim_bit_crosses()

	_section("the showdown's result crosses")
	var damage := GSDamage.make(server_me.entity_id, _stand_in.entity_id, 1000.0, null)
	damage.tick = _tick
	var _applied := _server_game.combat.apply_damage(damage)
	await _steps(6)
	_check(_heard.has("round_over") and int(_heard["round_over"][1]) == DrGame.RUNNERS,
		"the runners won, and the client is told", str(_heard.get("round_over")))
	_check(_heard.has("round_over") and str(_heard["round_over"][2]).contains("activator"),
		"with the server's own sentence")
	_finished()


## The weapon-feel pass's wire half (`DrGame.hit_landed` → HIT → `hit_received`, and the owner-only
## magazine and reserve that `DrClient.correct_drawn` adopts). `headless_run` only proves the
## offline half, where the world's own signal flashes the marker and nothing crosses. Armed: with
## the bridge's HIT send removed the first check fails; sent with `_broadcast` the second does.
func _test_a_hit_is_the_shooters() -> void:
	_section("a shot that lands is told to the shooter alone, and the drawn gun takes the server's count")
	var server_me: DrPlayer = _server_game.players[DrNetBridge.player_key(SESSION)]
	# A second connected player, READY, so a HIT that went to everybody would reach somebody.
	var _seated := _server_bridge.add_player(BYSTANDER_PEER, BYSTANDER_SESSION, "Bo")
	_server_bridge._admit(BYSTANDER_PEER)
	await _steps(2)

	# Point-blank, straight down the aim: the stand-in three metres in front of the shooter's eye.
	var aim := GSWeaponCommand.new()
	aim.yaw = 0.0
	aim.pitch = 0.0
	var ahead := aim.aim_direction()
	_stand_in.place_at(server_me.global_position + ahead * 3.0, 180.0)
	var full := server_me.weapons.arsenal.current().magazine
	# Hit but never killed: a kill would end the showdown and take the gun this section counts.
	var target_health := _server_game.combat.health_of(_stand_in.entity_id)
	target_health.cannot_die = true
	_hits.clear()
	_sent_events.clear()

	var fire := GSFpsCommand.new()
	fire.yaw = aim.yaw
	fire.pitch = aim.pitch
	fire.set_button(GSFpsCommand.BUTTON_USER_0, true)
	await _steps(3, fire)
	var still := GSFpsCommand.new()
	still.yaw = aim.yaw
	await _steps(INPUT_LEAD + 6, still)

	var to_shooter := _events_of(DrEvents.Kind.HIT, CLIENT_PEER)
	_check(not _hits.is_empty() and to_shooter > 0, "the shooter's bridge is told the shot landed",
		"%d heard, %d sent to the shooter" % [_hits.size(), to_shooter])
	var elsewhere := _events_of(DrEvents.Kind.HIT, BYSTANDER_PEER) + _events_of(DrEvents.Kind.HIT, 0)
	_check(elsewhere == 0, "and nobody else is: no HIT to the other player, none broadcast", "%d" % elsewhere)
	_check(not _hits.is_empty() and (_hits[0][0] as Vector3).distance_to(_stand_in.global_position) < 2.5,
		"at the server's point, on the body that was hit",
		"%s, body at %s" % [str(_hits[0][0]) if not _hits.is_empty() else "-", str(_stand_in.global_position)])

	# Shot back: the shooter is now the victim, and a victim is told nothing (the stand-in has no
	# peer, so a HIT routed by anything but the shooter's session would land on this client).
	_hits.clear()
	_sent_events.clear()
	var shot_back := GSShot.new()
	shot_back.attacker = _stand_in.entity_id
	var wound := GSDamage.make(_stand_in.entity_id, server_me.entity_id, 1.0, null)
	wound.health_lost = 1.0
	wound.point = server_me.global_position + Vector3.UP
	shot_back.damages.append(wound)
	_server_game._note_hits(_stand_in, shot_back)
	await _steps(4, still)
	_check(_hits.is_empty() and _events_of(DrEvents.Kind.HIT, CLIENT_PEER) == 0,
		"a hit somebody else landed on this player is not this player's marker", "%d" % _hits.size())

	# The count: the magazine the server spent arrives in the owner's snapshot fields, and a drawn
	# gun that predicted wrong adopts it once quiet, through the client's own correct_drawn.
	var server_mag := server_me.weapons.arsenal.current().magazine
	var behaviour: Variant = _client_bridge._behaviours.get(SESSION)
	var net_mag := int(behaviour.get(&"net_magazine")) if behaviour != null else -1
	_check(server_mag < full and net_mag == server_mag,
		"the server's magazine, spent, crosses to the owner", "full %d, server %d, client told %d" % [full, server_mag, net_mag])

	var client: Node = (load("res://game/dr_client.gd") as GDScript).new()
	var rig := ZeeWeaponRig.new()
	rig.name = "DrawnForTest"
	rig.role = ZeeWeaponRig.Role.SERVER
	rig.authority = false
	rig.tick_rate = _client_game.tick_rate
	_mine().add_child(rig)
	var _set := rig.setup()
	var held_id := server_me.weapons.current_def().id
	var _given := rig.give(held_id)
	if rig.arsenal.current() == null or rig.arsenal.current_slot() != server_me.weapons.arsenal.current_slot():
		var _picked := rig.arsenal.select(server_me.weapons.arsenal.current_slot(), 0)
	rig.arsenal.current().magazine = rig.arsenal.current().def.magazine
	client.set(&"weapons", rig)
	client.set(&"player", _mine())
	client.set(&"bridge", _client_bridge)
	client.set(&"_offline", false)
	client.set(&"_watch_id", SESSION)
	client.set(&"_drawn_quiet", 0.0)
	var early: bool = client.call(&"correct_drawn")
	var drawn_early := rig.arsenal.current().magazine
	client.set(&"_drawn_quiet", 1.0)
	var corrected: bool = client.call(&"correct_drawn")
	_check(not early and drawn_early != server_mag and corrected and rig.arsenal.current().magazine == server_mag,
		"the drawn gun takes the server's count once quiet, and not before",
		"before %d, after %d, server %d" % [drawn_early, rig.arsenal.current().magazine, server_mag])
	client.free()
	_mine().remove_child(rig)
	rig.free()

	target_health.cannot_die = false
	_server_bridge.remove_peer(BYSTANDER_PEER)
	await _steps(2)
	_finished()


## A trigger volume in the corridor: a runner who walks into it is sent by their own prediction in
## the tick they cross it, and the server, deciding the same from the same position, agrees.
## The pad is added to the server's document and the course laid out again, so it reaches the
## client the way every course does, as the document.
func _test_a_teleport_is_predicted() -> void:
	_section("a teleport is decided by the tick on both ends: the runner lands where the server says")
	var made := DrCourseDoc._piece({
		"kind": "teleport", "at": [0.0, 0.9, -6.0], "size": [3.0, 1.8, 1.0], "to": [-1.5, 0.1, 4.0],
		"heading": 90.0, "solid": false, "for": "runners",
	}, 0)
	var id := StringName(str(_server_game.stage.doc.get("id", "")))
	(_server_game.catalogue.courses[id]["pieces"] as Array).append(made.value)
	_server_game._lay_out_course()
	await _steps(8)
	await _wait_for_a_round()
	var sent := _client_game.stage.teleport_at(Vector3(0.0, 0.1, -6.0))
	_check(sent.size() == 3 and (sent[0] as Vector3).is_equal_approx(Vector3(-1.5, 0.1, 4.0)),
		"the pad arrived with the course, as the same trigger and destination", str(sent))

	var mine := _mine()
	var server_me: DrPlayer = _server_game.players[DrNetBridge.player_key(SESSION)]
	server_me.place_at(Vector3(0.0, 0.1, -2.0), 0.0)
	await _steps(20)
	var warps_before := mine.warps
	var forward := GSFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _steps(40, forward)
	await _steps(30)
	_check(mine.warps > warps_before, "the client's own tick sent it, not only a snapshot", "%d -> %d" % [warps_before, mine.warps])
	var landed := Vector2(mine.controller.state.position.x + 1.5, mine.controller.state.position.z - 4.0).length()
	_check(landed < 1.0, "and it stands at the destination", "%.2f m from it" % landed)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(apart < 0.25, "where the server has it too", "%.3f m" % apart)
	# The scripted commands here always say yaw 0, so the motor takes the heading back; a real client's
	# sampler is re-aimed (dr_client) and the heading itself is checked in headless_courses. What must hold
	# here is that both ends agree on the facing.
	_check(absf(angle_difference(deg_to_rad(mine.controller.state.yaw), deg_to_rad(server_me.controller.state.yaw))) < 0.2,
		"client and server face the same way after it", "%.1f / %.1f" % [mine.controller.state.yaw, server_me.controller.state.yaw])
	_check(server_me.is_alive(), "and nobody died of the trip")
	_finished()


func _test_free_roam_crosses() -> void:
	_section("free roam is asked for, the server decides, and the mode crosses the wire")
	var spectate := _server_game.spectate
	var rules := _server_game.spectate_rules
	var key := DrNetBridge.player_key(SESSION)
	var me: DrPlayer = _server_game.players[key]
	# The round's clock is held for the section: with the only runner out the traps win and the
	# next round puts the watcher back in play, in the middle of it.
	var held_phase := _server_game.phase
	_server_game.phase = DrGame.Phase.IDLE
	me.watching = true
	spectate.on_died(key, _stand_in.player_id, false, Vector3(0, 2, 0), 0.0, _tick)
	await _steps(SERVER_TICK_RATE * 4)
	_check(spectate.is_spectating(key) and not spectate.is_roaming(key),
		"a watcher starts on a player, not in a free camera", str(spectate.mode_of(key)))
	_check(_client_game.spectate.is_spectating(key), "and the client's mirror is watching too")

	_client_bridge.ask_roam()
	await _steps(6)
	_check(spectate.is_roaming(key), "the server puts a watcher who asks into the free camera")
	_check(_client_game.spectate.is_roaming(key) and _client_game.spectate.is_spectating(key),
		"and the client's mirror is told ROAMING, and still watching")

	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(key) and not _client_game.spectate.is_roaming(key),
		"the same key hands the camera back to a player on both ends")

	rules.force_camera = 1
	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(key), "mp_forcecamera 1 refuses the request")
	rules.force_camera = 0

	rules.allow_roaming = false
	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(key) and not _client_game.spectate.is_roaming(key),
		"mp_freeroam 0 refuses it")
	rules.allow_roaming = true

	_client_bridge.ask_roam()
	await _steps(6)
	rules.allow_roaming = false
	await _steps(6)
	_check(not spectate.is_roaming(key) and not _client_game.spectate.is_roaming(key),
		"switching mp_freeroam off mid-roam puts the roamer back on a player on both ends")
	rules.allow_roaming = true
	me.watching = false
	spectate.spawned(String(key))
	_server_game.phase = held_phase
	await _steps(6)
	_finished()


func _test_the_flashlight_crosses() -> void:
	_section("the flashlight is asked for, and the server's state comes back to everybody")
	await _wait_for_a_round()
	var server_me: DrPlayer = _server_game.players[DrNetBridge.player_key(SESSION)]
	var was := server_me.flashlight
	_client_bridge.ask_flashlight()
	await _steps(8)
	_check(server_me.flashlight != was, "the server switched it")
	_check(_mine().flashlight == server_me.flashlight, "and the owner is told")
	var theirs: DrPlayer = _client_game.players[_stand_in.player_id]
	_stand_in.flashlight = true
	await _steps(8)
	_check(theirs.flashlight, "and the others' flag is the server's")
	_client_bridge.ask_flashlight()
	await _steps(8)
	_check(server_me.flashlight == was and _mine().flashlight == was, "the next ask switches it back")
	_finished()


func _test_leaving() -> void:
	_section("leaving")
	_server_bridge.remove_peer(CLIENT_PEER)
	await _steps(4)
	_check(not _server_game.players.has(DrNetBridge.player_key(SESSION)), "the server lets them go")
	_check(not _client_game.players.has(DrNetBridge.player_key(SESSION)) or _server_bridge.describe()["ready_peers"] == 0,
		"and stops talking to them")
	_finished()


# --- Helpers --------------------------------------------------------------------


func _test_killcam_icon() -> void:
	_section("the killcam banner shows the weapon's icon")
	var fatal := DrEvents.read_death(GSNetReader.new(DrEvents.write_death(5, 6, DrGame.DIED_SHOT, null, &"rifle")))
	_check(bool(fatal["ok"]) and fatal["weapon_id"] == &"rifle", "a DEATH carries the weapon id")
	var client := DrClient.new()
	client._build_killcam()
	var kc := client.killcam
	client.remove_child(kc)
	add_child(kc)
	kc.note_moment(&"a", "put down", "Bo", &"rifle")
	var moment := kc.buffer.last_event(&"moment")
	_check(moment["data"].get("weapon_id", "") == "rifle", "the moment keeps the weapon id")
	_check(kc.killcam.icon_provider.is_valid(), "the killcam has an icon provider")
	var banner := GSKillcamBanner.new()
	banner.icon_provider = kc.killcam.icon_provider
	add_child(banner)
	banner.present({"killer": "A", "weapon": "put down", "weapon_id": "rifle"})
	_check(banner.icon_rect.visible and banner.icon_rect.texture != null, "the banner shows the rifle's picture")
	banner.free()
	_check(kc.camera_mode_fn.call() == GSKillViewRules.Camera.EYE, "the killcam camera is the eye until the server says")
	var pov := preload("../game/dr_kill_pov.gd")
	_check(pov.weapon_name(pov.hash_of(&"pistol")) != "" and pov.weapon_name(0.0) == "" and pov.aux_of(null) == [0.0], "the killer's screen names a recorded weapon and nothing for an empty hand")
	client._on_killcam_cvar("mp_killview_camera", "1")
	_check(kc.camera_mode_fn.call() == GSKillViewRules.Camera.BEHIND, "mp_killview_camera 1 puts the killcam camera behind the killer")
	var framing := GSKillcamFraming.new(null, 1)
	var eye := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var placed: Dictionary = framing.place(GSKillViewRules.Camera.BEHIND, eye, 75.0, Vector3(0, 1.2, -20))
	_check((placed["transform"] as Transform3D).origin.z > 1.0, "the behind camera sits behind the killer's eye")
	kc.free()
	client.free()
	_finished()
