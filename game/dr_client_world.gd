extends "dr_client_state.gd"
## What the client does with the world's news, offline or from the server: deaths, phases, a new stage, a press and a finish. No `class_name`; [code]dr_client.gd[/code] extends this.


## [param who]'s body falls the way the server picked ([member DrPlayer.death]), copied from the
## figure this client draws, which stays hidden while they are dead ([method DrPlayer.present_body]).
## No figure (a first-person player never drawn here), no fall.
func _fall(who: DrPlayer) -> void:
	if who == null or ragdolls == null or who.figure == null or not who.figure.is_inside_tree():
		return
	if game.physics != null:
		# The course is on `world`; a body lands on it and on nothing else.
		game.ragdoll_rules.collision_mask = game.physics.layer_mask(&"world")
	var velocity := who.controller.state.velocity if who.controller != null else Vector3.ZERO
	var _body := ragdolls.spawn(who.figure, who.death if who.death != null else GSPlayerDeath.new(), velocity)


func _on_phase(phase: int) -> void:
	_hear_phase(phase)

	match phase:
		DrGame.Phase.COUNTDOWN:
			_disarm_locally()

			if is_activator():
				hud.shout("YOU ARE THE ACTIVATOR — %s presses a button" % hud.use_label(), 3.5)
			else:
				hud.shout("RUN — the gate drops soon", 2.5)
		DrGame.Phase.RUN:
			hud.shout("GO", 1.4)

			if game.effects != null:
				var _flashed := game.effects.flash(&"go")
		DrGame.Phase.SHOWDOWN:
			if is_activator():
				hud.shout("A RUNNER MADE IT — to the end with you", 3.0)
			else:
				hud.shout("SOMEBODY MADE IT — the activators are at the end", 3.0)


## Whether this client's own player is pressing buttons this round.
func is_activator() -> bool:
	return player != null and game != null and game.team_of(player.player_id) == DrGame.ACTIVATORS


## The course's file sets the client-side rules it predicts with (gravity, auto-hop); the last course's come back.
func _apply_map_config(stage_id: StringName) -> void:
	if platform == null or game == null:
		return
	if platform.map_config_keys.is_empty():
		platform.map_config_keys = DrMapConfig.client_keys()
		platform.map_config_game = DrMapConfig.GAME
		platform.map_config_get_fn = func(key: String) -> Variant:
			return str(game.config.gravity) if key == "dr_gravity" else ("1" if game.config.auto_bunny_hop else "0")
		platform.map_config_set_fn = func(key: String, value: Variant) -> bool:
			if key == "dr_gravity":
				game.config.gravity = float(str(value))
			else:
				game.config.auto_bunny_hop = str(value) in ["1", "true"]
			return true
	platform.map_changed(String(stage_id))


## A new course. The name, once, big.
func _on_stage(stage_id: StringName) -> void:
	_apply_map_config(stage_id)
	# The new course's toys are heard: a ball's bounce off a crusher.
	if game.stage != null and game.stage.toys != null and not game.stage.toys.sound.is_connected(_toy_sound):
		var _c := game.stage.toys.sound.connect(_toy_sound)

	if ragdolls != null:
		# A body on the old course would hang in the new one's air.
		ragdolls.clear()

	if game.stage == null:
		return

	if audio != null:
		audio.on_course(stage_id, game.stage.doc)

	var name_of := str(game.stage.doc.get("name", ""))
	var blurb := str(game.stage.doc.get("blurb", ""))

	hud.shout(name_of, 3.0)

	if chat != null and name_of != "":
		var author := str(game.stage.doc.get("author", ""))
		chat.say_locally("%s%s — %s" % [name_of, " by %s" % author if author != "" else "", blurb],
			Color(0.80, 0.90, 1.0))


## A runner reached the end. What the feed and the speakers say.
func _on_finished(session_id: int, place: int, seconds: float) -> void:
	var who: DrPlayer = game.players.get(DrNetBridge.player_key(session_id))

	if killcam != null:
		killcam.note_moment(DrNetBridge.player_key(session_id), "reached the end #%d" % place)
	var mine := session_id == _watch_id

	if audio != null:
		var _heard := audio.on_finish(mine)

	if mine:
		hud.shout("MADE IT #%d — %.1f s. Now the activator." % [place, seconds], 3.0)

	if chat != null and who != null:
		chat.say_locally("%s made it to the end #%d in %.1f s" % [who.display_name, place, seconds],
			Color(0.98, 0.86, 0.40))


## A trap went. A sound where it is, and a shake if it is near enough to matter.
func _on_trap(index: int, _tick: int, by: int) -> void:
	if game.stage == null or index < 0 or index >= game.stage.trap_count():
		return

	var at := game.stage.trap_zone(index).get_center()

	if audio != null:
		var spec: Variant = game.stage.traps[index].get("spec", {})
		var _heard := audio.on_trap(at, spec if spec is Dictionary else {})

	if game.effects != null and camera != null:
		game.effects.viewer_position = camera.global_position
		game.effects.shake_at(&"trap", at, 8.0)

	if by == _watch_id and hud != null:
		hud.shout(game.stage.trap_name(index), 1.0)


## The round's last moment, a death or a finish. A shot puts the victim in the shooter's eyes,
## anything else (a trap, the pit, a fall) in the victim's own.
func _note_death(victim: StringName, by: StringName, why: StringName, weapon_id: StringName = &"") -> void:
	if killcam == null:
		return
	var who: DrPlayer = game.players.get(victim)
	var name_of := who.display_name if who != null else String(victim)
	if by != &"" and game.players.has(by) and by != victim:
		killcam.note_moment(by, "put down", name_of, weapon_id)
		return
	var what := "caught by a trap"
	match why:
		DrGame.DIED_PIT:
			what = "went in the pit"
		DrGame.DIED_FELL:
			what = "fell"
		DrGame.DIED_SHOT:
			what = "put down at the end"
	killcam.note_moment(victim, what)


func _on_death(session_id: int, by: int, why: StringName, weapon_id: StringName) -> void:
	var id := DrNetBridge.player_key(session_id)
	var who: DrPlayer = game.players.get(id)

	_note_death(id, DrNetBridge.player_key(by) if by > 0 else &"", why, weapon_id)

	_hear_death(who, why)

	if chat == null:
		return

	var name_of := who.display_name if who != null else String(id)

	var line := "%s is out" % name_of

	match why:
		DrGame.DIED_TRAP:
			line = "%s was caught by a trap" % name_of
		DrGame.DIED_PIT:
			line = "%s went in the pit" % name_of
		DrGame.DIED_FELL:
			line = "%s fell" % name_of
		DrGame.DIED_SHOT:
			line = "%s was put down at the end" % name_of

	chat.say_locally(line, Color(0.80, 0.82, 0.86))


func _hear_phase(phase: int) -> void:
	if audio == null:
		return

	match phase:
		DrGame.Phase.RUN:
			var _heard := audio.on_gate()
		DrGame.Phase.SHOWDOWN:
			var _heard := audio.on_showdown()


func _hear_death(who: DrPlayer, why: StringName) -> void:
	_fall(who)

	if audio == null or who == null:
		return

	var _heard := audio.on_death(who.global_position, who == player)


func _disarm_locally() -> void:
	if weapons != null:
		player.remove_child(weapons)
		weapons.queue_free()
		weapons = null

	if view_model != null and is_instance_valid(view_model):
		view_model.queue_free()
		view_model = null


func _toy_sound(id: StringName, at: Vector3, strength: float) -> void:
	if audio != null:
		var _played := audio.on_toy(id, at, strength)
