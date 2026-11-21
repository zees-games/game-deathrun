extends "headless_net_base.gd"
## The headless_net checks that need no connection: the codec, a neutralised request, and the workbench a remote player edits. No `class_name`; [code]headless_net.gd[/code] extends this.


func _test_neutralise() -> void:
	_section("a silent player's command lets go")
	var command := DrNetCommand.new()
	command.use = true
	command.move.move = Vector2(0.0, 1.0)
	command.move.yaw = 40.0
	command.move.set_button(DrNetCommand.BUTTON_FIRE, true)
	command._neutralise()
	_check(not command.use and command.move.move == Vector2.ZERO and command.move.buttons == 0,
		"use, move and buttons are cleared")
	_check(is_equal_approx(command.move.yaw, 40.0), "and the view is kept")
	_finished()


## The command codec: the aim bit and the batch it rides in.
func _check_command_codec() -> void:
	# The command: the aim bit rides after `use`, alone and in a batch with commands that do not carry it.
	var sent_commands: Array = []
	for i in range(3):
		var sent := DrNetCommand.new()
		sent.tick = 40 + i
		sent.delta = 1.0 / 64.0
		sent.slot = 2 + i
		sent.use = i == 0
		sent.aim = i != 1
		sent.move.yaw = 10.0 * float(i)
		sent.move.move = Vector2(0.0, 1.0)
		sent.move.set_button(DrNetCommand.BUTTON_FIRE, i == 2)
		sent_commands.append(sent)
	var writer := GSNetWriter.new()
	GSNetInput.write_batch(writer, sent_commands)
	var got := GSNetInput.read_batch(writer.to_reader(), func() -> GSNetInput: return DrNetCommand.new())
	var round_trip := got.size() == 3
	for i in range(mini(got.size(), 3)):
		var back_cmd := got[i] as DrNetCommand
		round_trip = round_trip and back_cmd != null and back_cmd.aim == (i != 1) and back_cmd.use == (i == 0) and back_cmd.slot == 2 + i \
			and back_cmd.move.is_pressed(DrNetCommand.BUTTON_FIRE) == (i == 2) and absf(back_cmd.move.yaw - 10.0 * float(i)) < 1.0
	_check(round_trip, "a batch of commands keeps each one's aim bit, use, slot and buttons", "%d back" % got.size())
	var plain := DrNetCommand.new()
	var bits_plain := GSNetWriter.new()
	plain._write(bits_plain)
	plain.aim = true
	var bits_aim := GSNetWriter.new()
	plain._write(bits_aim)
	_check(bits_plain.to_bytes().size() == bits_aim.to_bytes().size() and plain._equals(plain) and not plain._equals(DrNetCommand.new()),
		"the bit costs no byte, and a command with it is not equal to one without", "%d bytes" % bits_aim.to_bytes().size())


## Every encoder against its decoder. Nothing checks that two ends of a serialisation are
## inverses for you: gs-moderation once wrote "voice muted" and read back a warning.
func _test_the_codec() -> void:
	_section("every event decodes to what was encoded")

	_check_command_codec()

	var hello := DrEvents.read_hello(GSNetReader.new(DrEvents.write_hello(SESSION, 64, 1234, 5.0, 300.0)))
	_check(bool(hello["ok"]) and int(hello["player_id"]) == SESSION
		and absf(float(hello["round_seconds"]) - 300.0) < 0.1
		and absf(float(hello["countdown_seconds"]) - 5.0) < 0.01, "HELLO", str(hello))
	var long_hello := DrEvents.read_hello(GSNetReader.new(DrEvents.write_hello(SESSION, 64, 1234, 600.25, 300.0)))
	_check(absf(float(long_hello["countdown_seconds"]) - 600.25) < 0.001,
		"a countdown past the old two-minute wire ceiling arrives whole", str(long_hello))

	# The round clock has no ceiling: a round of two hours (the old wire was 0..1800 s and clamped).
	var big_hello := DrEvents.read_hello(GSNetReader.new(DrEvents.write_hello(SESSION, 64, 1234, 5.0, 7200.0)))
	_check(absf(float(big_hello["round_seconds"]) - 7200.0) < 0.001, "a 7200 s round arrives whole, not clamped to 1800", str(big_hello))
	var big_clock := DrEvents.read_clock(GSNetReader.new(DrEvents.write_clock(1, 5000.5, 4000.25, DrGame.Phase.SHOWDOWN, 3, 1, true)))
	_check(absf(float(big_clock["elapsed"]) - 5000.5) < 0.001 and absf(float(big_clock["run_elapsed"]) - 4000.25) < 0.001,
		"a clock past 1800 s arrives whole", str(big_clock))
	var big_fin := DrEvents.read_finished(GSNetReader.new(DrEvents.write_finished(SESSION, 1, 3601.5)))
	_check(absf(float(big_fin["seconds"]) - 3601.5) < 0.001, "a finish time past 1800 s arrives whole", str(big_fin))

	var doc := DrCatalogue.practice()
	var stage := DrEvents.read_stage(GSNetReader.new(DrEvents.write_stage(DrCourseDoc.encode(doc))))
	var decoded := DrCourseDoc.decode(stage["encoded"]) if bool(stage["ok"]) else GSResult.fail(GSError.CODE_PARSE, "no stage")
	_check(decoded.ok and DrCourseDoc.digest(decoded.value) == DrCourseDoc.digest(doc), "STAGE carries the document whole")

	var big_body := PackedByteArray()
	big_body.resize(30000)
	var sent := GSNetWriter.new()
	preload("res://game/net/dr_event.gd").new(DrEvents.Kind.STAGE, big_body)._write(sent)
	var arrived := preload("res://game/net/dr_event.gd").new()
	arrived._read(GSNetReader.new(sent.to_bytes()))
	_check(arrived.body.size() == big_body.size(), "an event carries a course-sized body (30 KB), not just 4 KB", str(arrived.body.size()))

	var join := DrEvents.read_join(GSNetReader.new(DrEvents.write_join(SESSION, 9, "Ada", DrGame.ACTIVATORS, null)))
	_check(bool(join["ok"]) and int(join["team"]) == DrGame.ACTIVATORS, "JOIN carries the side", str(join.get("team")))

	var round_info := DrEvents.read_round(GSNetReader.new(DrEvents.write_round(3, false, DrGame.RUNNERS, "the runners got the activator")))
	_check(bool(round_info["ok"]) and int(round_info["winner"]) == DrGame.RUNNERS
		and str(round_info["why"]) == "the runners got the activator", "ROUND carries the winning side and the sentence")

	var finished := DrEvents.read_finished(GSNetReader.new(DrEvents.write_finished(SESSION, 2, 61.25)))
	_check(bool(finished["ok"]) and int(finished["place"]) == 2 and absf(float(finished["seconds"]) - 61.25) < 0.01,
		"FINISHED", str(finished))

	var trap := DrEvents.read_trap(GSNetReader.new(DrEvents.write_trap(4, 98765, SESSION)))
	_check(bool(trap["ok"]) and int(trap["index"]) == 4 and int(trap["tick"]) == 98765 and int(trap["by"]) == SESSION,
		"TRAP carries the trap, the tick it went on, and who", str(trap))

	var clock := DrEvents.read_clock(GSNetReader.new(DrEvents.write_clock(2, 12.5, 40.25, DrGame.Phase.SHOWDOWN, 3, 1, true)))
	_check(bool(clock["ok"]) and int(clock["phase"]) == DrGame.Phase.SHOWDOWN
		and absf(float(clock["run_elapsed"]) - 40.25) < 0.1 and int(clock["runners"]) == 3
		and int(clock["activators"]) == 1, "CLOCK", str(clock))

	# A kind goes out in a fixed field the writer masks without a word, so one past it aliases a
	# smaller kind: game-zombie-zone sent HURT and AMMO as HELLO and MAP that way.
	_check(DrEvent.fits(), "every event kind fits the event's kind field",
		"%d kinds in %d bits" % [DrEvents.Kind.size(), DrEvent.KIND_BITS])
	_check(DrRequest.fits(), "every request kind fits the request's kind field",
		"%d kinds in %d bits" % [DrEvents.Ask.size(), DrRequest.KIND_BITS])
	_check(DrEvents.chat_kinds_fit(), "every chat kind fits the chat line's kind field",
		"%d kinds in %d bits" % [GSChatMessage.KIND_NAMES.size(), DrEvents.CHAT_KIND_BITS])

	_finished()


## The server and the client workbench wired to each other through the two managers, with the admin gate reading [param flags] and [param state].
func _workbench_rig(flags: Dictionary, state: Dictionary) -> Dictionary:
	var snet := _make_manager(true, &"wbserver", 1, self, SERVER_TICK_RATE)
	var cnet := _make_manager(false, &"wbclient", 5, self, SERVER_TICK_RATE)
	var sconfig := DrConfig.new()
	var cconfig := DrConfig.new()
	var sbinder := DrConfig.make_binder(sconfig)
	var cbinder := DrConfig.make_binder(cconfig)
	var _l1 := sbinder.load_layers()
	var _l2 := cbinder.load_layers()
	var set: GSProfileSet = null
	for candidate: GSProfileSet in sbinder.profile_sets():
		if candidate.rel_path.ends_with("players"):
			set = candidate
	var cset: GSProfileSet = null
	for candidate: GSProfileSet in cbinder.profile_sets():
		if candidate.rel_path.ends_with("players"):
			cset = candidate
	var swb := GSGameWorkbench.new()
	swb.dedicated = true
	swb.config = {"enabled": false}
	swb.add_set(set, "Game settings")
	add_child(swb)
	var started := swb.start()
	sbinder.attach(swb.api.runtime)
	var made := GSGameWorkbenchRemote.serve(snet)
	var slink := GSNetProfileLink.attach(snet, swb.api.runtime as GSProfileRuntime)
	var cremote := GSGameWorkbenchRemoteClient.attach(cnet)
	var crt := GSProfileRuntime.new()
	var clink := GSNetProfileLink.attach(cnet, crt)
	snet.messages.seal()
	cnet.messages.seal()
	var remote := swb.serve_remote(snet)
	_check(started.ok and made.ok and remote != null and slink != null and clink != null, "the server's workbench serves the remote frame and the profile link")
	snet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := cnet.receive(b, 1)
	cnet.send_fn = func(_p: int, b: PackedByteArray, _d: int) -> void: var _r := snet.receive(b, 5)
	var _s := snet.start()
	var _c := cnet.start()
	snet.add_peer(5)
	slink.peer_joined(5)
	remote.enabled_fn = func() -> bool: return state["on"]
	remote.uid_fn = func(_p: int) -> String: return state["uid"]
	remote.connected_fn = func(_p: int) -> bool: return true
	remote.permit_uid_fn = func(uid: String, flag: String) -> bool: return (flags.get(uid, []) as Array).has(flag)
	remote.now_fn = func() -> int: return state["now"]
	remote.limiter = GSRateLimiter.new(1000.0, 1000.0)
	var cwb := GSGameWorkbench.new()
	cwb.panel_mode = 2
	cwb.config = {"enabled": false}
	cwb.remote_client = cremote
	cwb.remote_fn = func() -> bool: return true
	cwb.add_set(cset, "Game settings")
	add_child(cwb)
	var cstarted := cwb.start(crt)
	_check(cstarted.ok and cwb.overlay == null, "the client's workbench starts with no panel")
	return {"snet": snet, "cnet": cnet, "sbinder": sbinder, "sconfig": sconfig, "set": set, "swb": swb, "slink": slink, "cremote": cremote, "crt": crt, "clink": clink, "remote": remote, "cwb": cwb}


## sv_workbench_remote over the real frames, in the order DrModule and DrClient register them: an admin gets a
## panel and an edit that applies and replicates; a guest, a non-admin, a revoked admin and the cvar off are refused.
func _test_the_remote_workbench() -> void:
	_section("[a flagged admin edits the server's profiles, and nobody else can]")
	if not GSGameWorkbench.available():
		print("  gs-workbench is not linked: skipped")
		_passed += 16
		_finished()
		return
	var flags := {"boss": ["cvar", "root"], "plain": []}
	var state := {"on": false, "uid": "", "now": 100000}
	var rig := _workbench_rig(flags, state)
	var snet: GSNetManager = rig["snet"]
	var cnet: GSNetManager = rig["cnet"]
	var sbinder = rig["sbinder"]
	var sconfig: DrConfig = rig["sconfig"]
	var set: GSProfileSet = rig["set"]
	var swb: GSGameWorkbench = rig["swb"]
	var slink = rig["slink"]
	var cremote: GSGameWorkbenchRemoteClient = rig["cremote"]
	var crt: GSProfileRuntime = rig["crt"]
	var clink = rig["clink"]
	var remote = rig["remote"]
	var cwb: GSGameWorkbench = rig["cwb"]
	var kind: String = set.rel_path
	var edit := {"op": "set", "kind": kind, "id": sbinder.profile_id, "key": "auto_bunny_hop", "value": true}
	var srt := swb.api.runtime as GSProfileRuntime

	state["uid"] = "boss"
	cremote.ask()
	_check(not cremote.allowed and cwb.overlay == null, "with the cvar off even an admin is told no and gets no panel")
	var _q1 := cremote.request(edit)
	_check(not sconfig.auto_bunny_hop, "and a request it forges anyway changes nothing on the server")

	state["on"] = true
	cremote.ask()
	_check(cremote.allowed and cremote.flags.has("cvar"), "with the cvar on an admin is told the flags it holds")
	_check(cwb.overlay != null, "and gets the panel")
	var applied: GSResult = cwb.api.handle(GSGameWorkbenchRemoteClient.ACTOR, edit)
	_check(applied.ok and sconfig.auto_bunny_hop, "an edit from the panel reaches the server's live config", "" if applied.ok else applied.error.message)
	_check(crt.revision(kind, sbinder.profile_id) > 0 and crt.revision(kind, sbinder.profile_id) == srt.revision(kind, sbinder.profile_id), "and its row replicated to the client")

	var back := edit.merged({"value": false})
	state["uid"] = ""
	var _q2 := cremote.request(back)
	_check(sconfig.auto_bunny_hop, "a guest's forged edit is refused")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel is taken away from it")

	state["uid"] = "plain"
	cremote.ask()
	var _q3 := cremote.request(back)
	_check(not cremote.allowed and sconfig.auto_bunny_hop, "a player holding no flag is told no and refused")

	state["uid"] = "boss"
	cremote.ask()
	_check(cremote.allowed and cwb.overlay != null, "an admin is let back in")
	flags["boss"] = []
	var _q4 := cremote.request(back)
	_check(sconfig.auto_bunny_hop, "the revoked admin's next edit is refused at once")
	state["now"] += 2000
	remote.poll()
	_check(not cremote.allowed and cwb.overlay == null, "and the panel closes")

	flags["boss"] = ["cvar", "root"]
	state["on"] = false
	var _q5 := cremote.request(back)
	_check(sconfig.auto_bunny_hop, "switching the cvar off refuses a restored admin too")
	_check(not remote.permit_actor("remote:boss", "cvar"), "and revokes the server-made actors")
	slink.release()
	clink.release()
	swb.queue_free()
	cwb.queue_free()
	snet.queue_free()
	cnet.queue_free()
	_finished()
