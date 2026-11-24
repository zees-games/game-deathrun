extends "dr_game_state.gd"

## The simulation. Headless, authoritative, and the only thing that decides anything.
## A round is a corridor of traps: runners run one long course to its end, activators drawn fresh each round press a button per trap from a corridor beside it. The first runner to the end arena calls the activators down; there is no respawn, so a press is worth something.
## The round, sides and scoreboard are gs-match's (through [DrRules]); health and damage are gs-combat's; weapons are zee-gs-weapons'. The course, traps and presses are [DrCourse], this game's own.


func _ready() -> void:
	if config == null:
		config = DrConfig.new()

	var valid := config.validate()

	if not valid.ok:
		# FATAL is reserved for "the process cannot continue", and a configuration that
		# contradicts itself is not that: say so loudly and refuse to run a round.
		GSLog.error(CHANNEL, "the configuration is not usable", {"why": valid.error.message})
		return

	_round_seed = config.seed_value

	_build_physics()
	if not body_rules.changed.is_connected(_on_body_rules_changed):
		body_rules.changed.connect(_on_body_rules_changed)
	_apply_gravity()
	_build_random()
	_build_stage()
	_build_combat()
	weapon_layer = DrWeaponLayer.new()
	weapon_layer.setup(self)
	_build_effects()
	_build_match()
	_build_spectate()
	_build_progress()

	if authoritative:
		catalogue = DrCatalogue.new()
		var _loaded := catalogue.load_from(config.course_directory)
		# Solo in the client shell: the map packs it mounted for this game, which a server
		# would have named. See [method solo_map_dirs].
		for root in solo_map_dirs("courses"):
			var _added := catalogue.add_directory(root)
		# The Workshop's courses, solo only by the index's own session (an online session lists none).
		catalogue.follow_content(GSContentIndex.shared(), DrCatalogue.accepted_map_kinds())
		var _rotation := load_rotation()
		# Laid out now, not on the first round: gs-match runs a warmup first, and an empty
		# world through the warmup is indistinguishable from a map that failed to load.
		_lay_out_course()

	if register_service:
		GSRegistry.register(SERVICE, self)

	GSLog.info(CHANNEL, "world ready", config.describe())


## The `<pack>/<subdir>` directories of the map packs a host running this game with no server
## has mounted for it: the client shell's Solo play, which fetches the packs a server owner
## would name (gs-server-deploy's `client/solo.json`) because a tab has no server to name
## them. Read the way the module reads its server's ([GSGameContent]). Empty everywhere else:
## a server, a suite, a run from the repository. Looked up by name and duck-typed, because a
## delivered game may not name a host's class.
static func solo_map_dirs(subdir: String) -> PackedStringArray:
	var host: Object = GSRegistry.get_service(SOLO_SERVICE)
	if host == null or not host.has_method(&"map_dirs"):
		return PackedStringArray()
	return host.call(&"map_dirs", subdir)


func _exit_tree() -> void:
	if register_service:
		GSRegistry.unregister_instance(SERVICE, self)


# --- Building ---------------------------------------------------------------

## The player's motor mask under `mp_solidplayers`, and the standing hull the others stop at
## (a player's body has no shape of its own). Through `apply_to`: `set_collision_mask`, which
## a style does not undo, and the players' layer as one a player may walk out of. With the rule
## on, a stand-in stops at your shoulder instead of walking through your face (the first
## play test).
func _apply_body_mask(player: DrPlayer) -> void:
	if physics == null or player == null or player.controller == null:
		return
	body_rules.apply_to(player.controller, physics.collision_mask(&"player"), physics.layer_mask(&"player"))
	var tunables := player.controller.tunables
	if player.weapons != null:
		player.weapons.wall_extra_mask = tunables.collision_mask
	body_rules.apply_hull(player, tunables.stand_height, tunables.radius)


## `mp_solidplayers` changed: every player's mask and hull now.
func _on_body_rules_changed() -> void:
	for id in players:
		_apply_body_mask(players[id] as DrPlayer)


## The named collision layers: the world and the players.
func _build_physics() -> void:
	physics = GSPhysicsLayout.custom(&"deathrun", [&"world", &"player", &"toy", &"footprint"])

	for layer in physics.layers:
		match layer.id:
			&"player":
				# Not other players. Two runners shoving on a ledge is a race decided by who
				# walked into whom, drawn in the past on every client — and on a course where a
				# shove is a death, it would be the deadliest thing on it. So `mp_solidplayers`
				# is 0 by default here (see `body_rules`); the camera fade keeps a runner who
				# walks through you out of the lens.
				layer.collides_with = [&"world"]
			# A course's loose toy (gs-props'): the course, its traps and the other toys,
			# never a runner, who walks through it and pushes it (`_advance_toys`).
			&"toy":
				layer.collides_with = [&"world", &"toy"]
			# A toy's footprint, for a walkable mesh's bake only: nothing collides with it.
			&"footprint":
				layer.collides_with = []
			_:
				layer.collides_with = [&"player"]

	var built := physics.build()

	if not built.ok:
		GSLog.error(CHANNEL, "the collision layout would not build", {"why": built.error.message})
		physics = null


## The gravity the course is tuned against, on this world's own physics SPACE. A project
## setting does not travel with a delivered pack; see [member DrConfig.gravity].
func _apply_gravity() -> void:
	var world := get_world_3d()

	if world == null:
		GSLog.warn(CHANNEL, "no world to set gravity on", {})
		return

	PhysicsServer3D.area_set_param(world.space, PhysicsServer3D.AREA_PARAM_GRAVITY, config.gravity)


func _build_random() -> void:
	random = GSRandomManager.new()
	random.name = "Random"
	# Off: a registry name is process-wide, and two worlds in one process is every suite.
	random.register_as_service = false
	add_child(random)
	var _started := random.setup()
	random.reseed(_round_seed)


func _build_stage() -> void:
	stage = DrCourse.new()
	stage.name = "Stage"
	stage.physics = physics
	stage.tick_rate = tick_rate
	stage.draw_world = draw_world
	stage.authoritative = authoritative
	stage.toy_rules = toy_rules
	stage.gravity = config.gravity
	add_child(stage)


func _build_combat() -> void:
	combat = GSCombatManager.new()
	combat.name = "Combat"
	combat.is_authority = authoritative
	combat.register_service = false

	var rules := GSDamageRules.new()
	rules.friendly_fire = config.friendly_fire
	rules.self_damage = true
	rules.hit_groups = true
	combat.rules = rules

	# Lag compensation OFF here and turned on by the bridge with the callables that make it
	# real — mg-smash-copter's finding: left on, a delivered server logged "no rewind function"
	# at every boot about a server where it works.
	var settings := GSCombatConfig.new()
	settings.lag_compensation = false
	combat.config = settings

	# A trace, or every shot goes through the arena's walls. Before `setup`, which warns.
	var trace := GSTracePhysics.for_world(get_world_3d())

	if physics != null:
		trace.collision_mask = physics.layer_mask(&"world")

	combat.trace = trace

	# Which side an entity is on, or friendly fire is ON between two runners.
	combat.resolver = GSDamageResolver.with_rules(rules)
	combat.resolver.hit_groups = GSHitGroup.defaults()
	combat.resolver.team_of = func(entity_id: int) -> int:
		return team_of(entities.key_for_id(entity_id))

	# gs-game's "still loading": the one place every hurt passes (a trap's kill, the floor, a
	# weapon), so a covered seat is neither hurt nor eliminated, and a round counts the living
	# from health. An admin's slay or slap is the operator's word and passes.
	combat.resolver.adjust = func(damage: GSDamage) -> void:
		if damage.context.get("admin", false):
			return

		if not can_be_harmed(entities.key_for_id(damage.victim)):
			damage.refuse("still loading")

	# `add_child` IS the setup; calling it again doubled every boot line. See mg-smash-copter.
	add_child(combat)


## A flash for the gate and a shake for a trap going off near you. Client side.
func _build_effects() -> void:
	if authoritative and not draw_world:
		return

	var catalogue_fx := GSFxCatalogue.new()

	var trap := GSFxDef.new()
	trap.id = &"trap"
	trap.kind = GSFxDef.Kind.SHAKE
	trap.shake_trauma = 0.4
	trap.max_distance = 14.0
	catalogue_fx.add(trap)

	var go := GSFxDef.new()
	go.id = &"go"
	go.kind = GSFxDef.Kind.SCREEN
	go.flash_peak = 0.22
	go.flash_colour = Color(0.98, 0.86, 0.35, 1.0)
	go.flash_decay_ms = 380
	catalogue_fx.add(go)

	effects = GSFxManager.new()
	effects.name = "Effects"
	effects.catalogue = catalogue_fx
	effects.config = GSFxConfig.new()
	effects.register_as_service = false
	add_child(effects)

	GSLog.result(CHANNEL, "the effects layer", effects.setup())


## The intermission is the pause plus the killcam the clients play inside it, so the server never waits on one.
func apply_intermission(rules: GSMatchRules = null) -> void:
	var target: GSMatchRules = rules if rules != null else (match_node.rules if match_node != null else null)
	if target == null:
		return
	var pause := config.intermission_seconds
	target.intermission_sec = pause + (config.killcam_seconds if pause > 0.0 else 0.0)


func _build_match() -> void:
	match_node = GSMatch.new()
	match_node.name = "Match"
	match_node.register_service = false

	var match_config := GSMatchConfig.new()
	match_config.tick_rate = tick_rate
	match_config.auto_start = false
	match_config.log_transitions = false
	# Off: the sides are drawn by this game every round (see [method _draw_sides]), and a
	# rebalance after the draw would move the activator back among the runners.
	match_config.balance_between_rounds = false
	match_node.config = match_config

	var rules: GSMatchRules = DrRules.make()
	apply_intermission(rules)
	rules.warmup_sec = config.warmup_seconds
	rules.countdown_sec = 0.0
	rules.team_based = true
	# Two: an activator and a runner is the smallest round that is a round.
	rules.min_players = 2
	rules.set(&"decision_fn", _decision)
	rules.time_limit_sec = config.countdown_seconds + config.round_seconds + 60.0
	match_node.rules = rules

	# Scoped to the match node, which finds nothing: this game places its own players, and an
	# unset `spawns_ref` walks the whole scene and finds another world's.
	match_node.spawns_ref = GSNodeRef.of_path(^".")

	add_child(match_node)

	match_node.round_started.connect(_on_round_started)
	match_node.round_ended.connect(_on_round_ended)

	var teams: Array[GSTeam] = [
		GSTeam.make(RUNNERS, TEAM_NAMES[0], TEAM_COLOURS[0]),
		GSTeam.make(ACTIVATORS, TEAM_NAMES[1], TEAM_COLOURS[1]),
	]

	match_node.teams.teams = teams
	match_node.teams.force_balance = false
	match_node.teams.allow_choice = false
	# Off: the sides are this game's to draw, and gs-match's default difference of one refused
	# a ninth runner against one activator.
	match_node.teams.max_difference = 0
	match_node.teams.reindex()


func _decision() -> Dictionary:
	return {"decided": _decided, "winner": _winner}


func _build_spectate() -> void:
	spectate = DrSpectate.new()
	spectate.name = "Spectate"
	spectate.players = players
	spectate.sides = sides
	spectate.death_cam_seconds = config.death_cam_seconds
	spectate.freeze_cam_seconds = config.freeze_cam_seconds
	spectate.authoritative = authoritative
	spectate.tick_rate = tick_rate
	spectate.rules = spectate_rules
	spectate.fixed_index_fn = func(_key: String) -> int:
		return DrSpectate.OVERVIEW_SHOWDOWN if phase == Phase.SHOWDOWN else DrSpectate.OVERVIEW_FIELD
	add_child(spectate)

	# The config's number is only the starting point: from here `mp_forcecamera` is the rule.
	spectate_rules.force_camera = clampi(config.spectate_camera, 0, 2)
	var ready_now := spectate.setup()

	if not ready_now.ok:
		GSLog.warn(CHANNEL, "spectating is off", {"why": ready_now.error.message})
		remove_child(spectate)
		spectate.queue_free()
		spectate = null


func _build_progress() -> void:
	if not authoritative or not config.keep_progress:
		return

	progress = DrProgress.new()
	progress.name = "Progress"
	progress.players = players
	progress.sides = sides
	progress.entity_key_fn = func(entity_id: int) -> StringName: return entities.key_for_id(entity_id)
	add_child(progress)

	var ready_now := progress.setup(config.progress_directory, config.report_progress)

	if not ready_now.ok:
		GSLog.warn(CHANNEL, "progress is off", {"why": ready_now.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null
		return

	progress.earned.connect(func(id: StringName, title: String, points: int) -> void:
		achievement_earned.emit(id, title, points)
	)


func _refresh_overviews() -> void:
	if spectate == null or stage == null or stage.doc.is_empty():
		return

	var box := stage.bounds()
	var centre := box.get_center()
	var reach := maxf(box.size.length() * 0.5, 12.0)
	var eye := centre + Vector3(reach * 0.55, reach * 0.5 + 10.0, reach * 0.2)
	var field := Transform3D(Basis.IDENTITY, eye).looking_at(centre, Vector3.UP)

	# The arena's camera: above the runners' end, looking at the activators'.
	var end: Dictionary = stage.doc["end"]
	var from: Vector3 = (end["runners"] as Dictionary)["at"]
	var to: Vector3 = (end["activators"] as Dictionary)["at"]
	var middle := from.lerp(to, 0.5)
	var arena := Transform3D(Basis.IDENTITY, from + (from - to).normalized() * 3.0 + Vector3(0.0, 9.0, 0.0)) \
		.looking_at(middle, Vector3.UP)
	var cameras: Array[Transform3D] = [field, arena]
	spectate.set_overviews(cameras)


# --- Players ----------------------------------------------------------------

## Puts somebody in the world. [param wanted_side] is a side, or 0 to be placed.
func add_player(
	player_id: StringName,
	display_name: String,
	wanted_side: int = 0,
	samples_input: bool = false
) -> DrPlayer:
	if players.has(player_id):
		return players[player_id]

	var side := ACTIVATORS if wanted_side == ACTIVATORS else RUNNERS

	var player := DrPlayer.new()
	player.name = "Player_%s" % String(player_id)
	player.player_id = player_id
	player.display_name = display_name
	player.samples_input = samples_input
	player.tick_rate = tick_rate
	player.config = config
	player.stage = stage
	player.team = side
	add_child(player)

	if physics != null:
		var applied := physics.apply_to(player, &"player")

		if not applied.ok:
			GSLog.warn(CHANNEL, "a player could not be put on its collision layer", {
				"why": applied.error.message,
			})

		# And the motor's own mask, which defaults to 1. A controller left on the default
		# sweeps against layer one only, which is a player falling through the course.
		_apply_body_mask(player)

	var opened := entities.open(
		GSEntity.KIND_PLAYER, player, &"", player_id, float(_tick) / float(maxi(tick_rate, 1))
	)

	if not opened.ok:
		GSLog.error(CHANNEL, "could not open an entity for a player", {
			"id": String(player_id), "why": opened.error.message,
		})

	player.entity_id = (opened.value as GSEntityHandle).id if opened.ok else 0

	var health := GSHealth.new()
	health.name = "Health"
	health.max_health = config.player_health
	health.health = config.player_health
	player.add_child(health)
	player.health = health

	if combat != null:
		combat.register_health(player.entity_id, health)
		_give_hitboxes(player)

	health.died.connect(func(damage: GSDamage) -> void: _on_player_died(player, damage))

	players[player_id] = player
	sides[player_id] = side

	if match_node != null:
		var seated := match_node.add_player(String(player_id), display_name, _tick, side)

		if not seated.ok:
			GSLog.error(CHANNEL, "gs-match refused a player", {
				"id": String(player_id), "side": side, "why": seated.error.message,
			})

	# Placed NOW, not only at the top of a round: a joiner left at the origin is a joiner
	# falling, and mg-smash-copter's version of that ended rounds.
	place_one(player)

	GSLog.debug(CHANNEL, "player joined", {"id": String(player_id), "side": side})

	# Last, after the health and the side: the bridge answers this by replicating the player.
	player_added.emit(player_id)
	return player


## Somewhere on a player a shot can land. Without it nobody can be shot and nothing says so.
func _give_hitboxes(player: DrPlayer) -> void:
	var boxes := GSHitboxSet.new()
	boxes.name = "Hitboxes"
	boxes.owner_ref = GSNodeRef.of_path(^"..")
	player.add_child(boxes)

	var body := GSHitbox.new()
	body.name = "Chest"
	body.group = GSHitGroup.CHEST
	body.shape = GSHitbox.Shape.CAPSULE
	body.radius = 0.34
	body.height = 1.25
	body.position = Vector3(0.0, 0.78, 0.0)
	body.damage_scale = 1.0
	body.precedence = 0
	boxes.add_child(body)

	var head := GSHitbox.new()
	head.name = "Head"
	head.group = GSHitGroup.HEAD
	head.shape = GSHitbox.Shape.SPHERE
	head.radius = 0.19
	head.position = Vector3(0.0, DrPlayer.EYE_HEIGHT + 0.06, 0.0)
	head.damage_scale = 2.2
	head.precedence = 10
	boxes.add_child(head)

	boxes.refresh()
	boxes.register_with(combat, player.entity_id)


## Puts one player somewhere they can be, for the phase it is.
##
## [b]A joiner in the middle of a round watches it.[/b] Starting them at the start behind
## everybody would be a runner the activator has already spent every trap on, and putting
## them in the activators' corridor would hand a stranger the buttons.
func place_one(player: DrPlayer) -> void:
	if stage == null or stage.doc.is_empty():
		return

	var spot := stage.start_spot(players.size() - 1, 1000)

	if int(sides.get(player.player_id, RUNNERS)) == ACTIVATORS:
		spot = stage.activator_spot(0, 1000)

	player.place_at(spot[0], spot[1])

	if authoritative and (phase == Phase.RUN or phase == Phase.SHOWDOWN):
		_bench(player)
	elif spectate != null:
		spectate.spawned(String(player.player_id))


## Sits somebody out for the rest of the round: watching, unhurtable, not counted.
func _bench(player: DrPlayer) -> void:
	player.watching = true

	if player.health != null:
		player.health.invulnerable = true

	if spectate != null:
		spectate.on_died(player.player_id, &"", false, player.controller.state.position,
			stage.kill_height() + 8.0, _tick)


func remove_player(player_id: StringName) -> void:
	if not players.has(player_id):
		return

	var player: DrPlayer = players[player_id]

	# Before the node goes: gs-combat keyed a health on this entity, and a stale record has
	# no symptom until the process runs out of memory.
	if combat != null and is_instance_valid(combat) and player.entity_id != 0:
		combat.forget(player.entity_id)
		var _closed := entities.close(player.entity_id, GSEntityTable.REASON_OWNER_LEFT)

	if match_node != null:
		match_node.remove_player(String(player_id))

	players.erase(player_id)
	sides.erase(player_id)
	_last_activators.erase(player_id)

	for table in [_bot_route, _bot_walk, _bot_goal, _bot_hands, _bot_watch, _bot_stuck, _bot_settle, _credit, _grace]:
		(table as Dictionary).erase(player_id)

	player.queue_free()

	if spectate != null:
		spectate.left(String(player_id))

	if progress != null:
		progress.leave(player_id)

	player_removed.emit(player_id)


func team_of(player_id: StringName) -> int:
	return int(sides.get(player_id, 0))


## The side a player stands on for the block rules: the team, "" for none.
func team_of_side(id: Variant) -> Variant:
	var side := team_of(StringName(id))
	return str(side) if side > 0 else ""


func side_name(side: int) -> String:
	if side == RUNNERS or side == ACTIVATORS:
		return TEAM_NAMES[side - 1]

	return "nobody"


func side_colour(side: int) -> Color:
	if side == RUNNERS or side == ACTIVATORS:
		return TEAM_COLOURS[side - 1]

	return Color(0.7, 0.7, 0.7)


func players_on(side: int) -> Array[DrPlayer]:
	var out: Array[DrPlayer] = []

	for id: StringName in players:
		if int(sides.get(id, 0)) == side:
			out.append(players[id])

	return out


## Whether [param player_id] may be damaged or eliminated now: false while their client is behind
## its loading cover. True for anybody the gate does not know (bots, offline).
func can_be_harmed(player_id: StringName) -> bool:
	return not harm_gate.is_valid() or bool(harm_gate.call(player_id))


## How many of a side are up and in the round.
func alive_on(side: int) -> int:
	if not authoritative:
		if side == RUNNERS and remote_runners >= 0:
			return remote_runners
		if side == ACTIVATORS and remote_activators >= 0:
			return remote_activators

	var total := 0

	for player in players_on(side):
		if player.is_alive() and not player.watching:
			total += 1

	return total


func finished_count() -> int:
	return _finish_count


## Whether there are enough people for a round. Two, of anybody.
func sides_are_playable() -> bool:
	if not authoritative:
		return remote_playable

	return players.size() >= 2


# --- The round --------------------------------------------------------------

func start() -> void:
	if not authoritative:
		return

	# Built again here, not only in `_ready`: on a server nothing is listening when the world
	# opens — the module builds the bridge that answers `world_rebuilt` — and a course built
	# before it is a course no client is ever sent. The SAME course, unless it is no longer one
	# this server plays (a delivered server's courses arrive after the world opened).
	var id := StringName(str(course_doc.get("id", "")))

	if not course_doc.is_empty() and catalogue != null \
			and catalogue.playable_courses(config.course_ids).has(id):
		var _rebuilt := build_stage(course_doc)
		_place_everybody()
	else:
		_lay_out_course()

	match_node.start(_tick)


func _on_round_started(number: int) -> void:
	round_number = number
	_round_seed = config.seed_value + number * 7919
	random.reseed(_round_seed)

	# The course the warmup showed, for the first round — not built again, only put back: every
	# client already has it, and a second STAGE for the same document is a second build on every
	# one of them for nothing. The next course after that.
	if _course_unplayed and not course_doc.is_empty() and stage.id() == StringName(str(course_doc["id"])):
		stage.reset_traps()
		# And the toys home, which a warmup kicked about.
		if stage.toys != null:
			stage.toys.reset()
	else:
		_lay_out_course()

	_course_unplayed = false
	_decided = false
	_winner = 0
	_winner_name = ""
	_finish_count = 0
	run_elapsed = 0.0
	pressed_by.clear()
	_credit.clear()
	_grace.clear()
	_bot_watch.clear()

	_draw_sides()
	_place_everybody()

	if progress != null:
		progress.on_round_began()

	_set_phase(Phase.COUNTDOWN)
	round_began.emit(number, stage.id())

	GSLog.info(CHANNEL, "round began", {
		"number": number, "course": String(stage.id()), "seed": _round_seed,
		"players": players.size(), "activators": ", ".join(_names(players_on(ACTIVATORS))),
	})


func _on_round_ended(number: int, winner: int, _outcome: int) -> void:
	_set_phase(Phase.IDLE)

	# The clock gs-match itself called, past every clock this game keeps: a backstop that
	# should never be what ends a round, and is said so when it is.
	if not _decided:
		_winner_name = "the round ran out"

	if progress != null:
		progress.on_round_over(winner)

	round_over.emit(number, winner, _winner_name)
	GSLog.info(CHANNEL, "round over", {"number": number, "winner": _winner_name})


## Who presses the buttons this round.
##
## [b]Drawn, seeded, and never the same person twice running when there is anybody else.[/b]
## A rotation would be fairer on paper and is gamed in practice — the order is learned and
## somebody leaves and rejoins to move up it — while a draw that repeats is read as the server
## playing favourites. So: everybody who was not an activator last round goes in the hat, and
## the hat is the round's own seed.
func _draw_sides() -> void:
	var ids: Array[StringName] = []
	for id: StringName in players.keys():
		ids.append(id)
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	# The players' own choices: a volunteer is drawn first, anybody who asked to run only if
	# the round would otherwise be short of an activator, because there must always be one.
	var wishes := {}
	if config.allow_side_choice:
		for id in ids:
			match (players[id] as DrPlayer).side_wish:
				ACTIVATORS:
					wishes[id] = 1
				RUNNERS:
					wishes[id] = -1

	# A seat still behind its loading cover is the last choice for an activator: its buttons
	# would sit unpressed (and its traps unaimed) while it cannot see. Treated as asking to
	# run, so it is drawn only when the round would otherwise have no activator.
	for id in ids:
		if not can_be_harmed(id):
			wishes[id] = -1

	# gs-team's draw, which was extracted from this one. rest_first keeps this game's rule:
	# last round's activators sit out even if they volunteered, and come back only when there
	# are not enough fresh names (unless the server lets them repeat).
	var history := {}
	GSTeamRotation.note(history, ids, _last_activators, 0)
	var result := GSTeamRotation.pick(
		ids, config.activators_for(ids.size()), GSTeamRotation.Mode.RANDOM, history,
		random.stream(&"activators").next(), wishes, config.activator_may_repeat, true
	)
	var drawn: Array[StringName] = []
	drawn.assign(result["picked"])

	_last_activators = drawn

	for id in ids:
		_set_side(id, ACTIVATORS if drawn.has(id) else RUNNERS)


## A player's choice of side, from chat. Server side. Takes effect at the next draw.
func wish_side(id: StringName, side: int) -> void:
	var player: DrPlayer = players.get(id)
	if player != null:
		player.side_wish = side if side == RUNNERS or side == ACTIVATORS else 0


func _set_side(id: StringName, side: int) -> void:
	var player: DrPlayer = players.get(id)

	if player == null:
		return

	var was := int(sides.get(id, 0))
	sides[id] = side
	player.team = side

	if match_node != null and was != side:
		var _moved := match_node.switch_team(String(id), side, _tick)

	if was != side:
		side_changed.emit(id, side)


static func _names(of: Array[DrPlayer]) -> PackedStringArray:
	var out := PackedStringArray()

	for player in of:
		out.append(player.display_name)

	return out


## The next course, built.
func _lay_out_course() -> void:
	if catalogue == null:
		return

	var doc: Dictionary = {}

	# What the players voted for, once, if it is still a course this server plays (a
	# dr_reload between the vote and the round can take it away). The rotation otherwise.
	if next_course_id != &"" and catalogue.playable_courses(config.course_ids).has(next_course_id):
		doc = catalogue.courses[next_course_id]

	next_course_id = &""

	if doc.is_empty():
		doc = catalogue.next_course(
			config.course_ids, config.shuffle_courses, random.stream(&"course"),
			StringName(str(course_doc.get("id", "")))
		)

	catalogue.note_played(StringName(str(doc.get("id", ""))))
	build_stage(with_tell(doc, config.trap_tell_seconds))
	_place_everybody()
	_course_unplayed = true


## Reads maps.yml (the `--config` directory first) and applies it. Called at boot and by
## `sv_map_rotation_file`. A file that is present and unreadable is an ERROR and changes nothing:
## rotating every course is a better failure than rotating none.
func load_rotation() -> GSResult:
	if catalogue == null:
		return GSResult.fail(GSError.CODE_STATE, "There is no catalogue to rotate.")

	var stem := config.map_rotation_file
	var dir := GSMapRotationFile.config_dir_arg()
	GSAddonConfig.game = "mg-deathrun"
	var found := GSMapRotationFile.find(stem, dir)

	if found == "" and stem != "" and (dir != "" or stem != DrConfig.new().map_rotation_file):
		# The default name being absent is an install with no maps.yml; a name or a directory
		# somebody chose that finds nothing is a typo they would otherwise never hear about.
		GSLog.warn(CHANNEL, "the map rotation file was not found; every course rotates", {
			"file": stem, "config_dir": dir,
		})

	var paths := PackedStringArray()

	if found != "":
		# The layers that apply (an operator file replaces the shipped one unless it says merge: true); a named file or the legacy file stands alone.
		var layers := GSMapRotationFile.find_layers(dir, "mg-deathrun")
		paths = layers if layers.has(found) else PackedStringArray([found])

	var read := GSMapRotationFile.load_files(paths, "mg-deathrun")

	if not read.ok:
		GSLog.error(CHANNEL, "the map rotation file could not be read; every course rotates", {
			"why": read.error.message,
		})
		catalogue.rotation_file = null
		catalogue.apply_rotation(config.course_ids)
		return read

	catalogue.rotation_file = read.value
	catalogue.apply_rotation(config.course_ids)

	if catalogue.has_rotation_file():
		GSLog.info(CHANNEL, "the map rotation file", {
			"paths": ", ".join(catalogue.rotation_file.sources),
			"active": catalogue.rotation_file.active_name(),
		})

	return read


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func rotation_commands() -> Dictionary:
	if catalogue == null or catalogue.rotation_file == null:
		return {}

	return catalogue.rotation_file.commands()


## Every name a role of this game's own answers to (the first is the one help shows), from
## maps.yml's `commands:` block; the role's own name with no file.
func command_names(role: String) -> PackedStringArray:
	var names: Dictionary = rotation_commands().get("names", {})

	if not names.has(role):
		return PackedStringArray([role])

	return GSCommandNames.all_of("", names, {}, role)


## Every course this server plays, as the map menu (M) lists them: `{id, name, detail,
## current}`, the blurb under the name (a course's `theme` is its colours, not a word). Solo the
## client's list, online the server's (the module hands it to gs-vote's map menu).
func course_rows() -> Array:
	var out: Array = []
	if catalogue == null:
		return out
	var now := StringName(str(course_doc.get("id", "")))
	for id in catalogue.playable_courses(config.course_ids):
		var doc: Dictionary = catalogue.courses.get(id, {})
		var rotates := catalogue.in_rotation(id)
		var row := {"id": String(id),
			"name": catalogue.label_of(id) + ("" if rotates else " (not in rotation)"),
			"in_rotation": rotates, "current": id == now,
			"detail": str(doc.get("blurb", ""))}
		if doc.has("thumbnail"):
			row["thumbnail"] = str(doc["thumbnail"])
		out.append(row)
	return out


## The map menu's change: [param id] now, not after this round. The next course is set and a
## fresh round begins on it (gs-match's `begin_round_now`: the round called off has no
## winner and no activator's score); with no match running it is simply built. Authority only.
func change_course_now(id: StringName) -> GSResult:
	if not authoritative:
		return GSResult.fail(GSError.CODE_STATE, "Only the server changes the course.")
	if catalogue == null or not catalogue.playable_courses(config.course_ids).has(id):
		return GSResult.fail(GSError.CODE_INVALID, "There is no course called '%s' here." % id)
	next_course_id = id
	# The warmup's course is not the one to keep: the next round is the chosen one.
	_course_unplayed = false
	if match_node == null or not match_node.begin_round_now(_tick):
		_lay_out_course()
	GSLog.info(CHANNEL, "course changed from the map menu", {"course": String(id)})
	return GSResult.success(id)


## [param doc] with [param tell] seconds added to every trap's delay: the tell, written into the
## document itself so the course a client is sent and the course the server runs move every
## trap at the same tick. A copy: the catalogue's documents stay as their files say.
static func with_tell(doc: Dictionary, tell: float) -> Dictionary:
	if tell <= 0.0:
		return doc

	var out: Dictionary = doc.duplicate(true)

	for trap: Dictionary in out.get("traps", []):
		var timing: Dictionary = trap.get("timing", {})
		timing["delay"] = float(timing.get("delay", 0.0)) + tell
		timing["tell"] = tell

	return out


## Builds [param doc] as the stage. What the server does at a round start, and what a client
## does when it is sent one.
func build_stage(doc: Dictionary) -> GSResult:
	world_clearing.emit()

	var built := stage.build(doc)

	if not built.ok:
		GSLog.error(CHANNEL, "a course would not build", {
			"id": str(doc.get("id", "?")), "why": built.error.message,
		})
		return built

	course_doc = stage.doc
	stage.gate_closed = phase == Phase.COUNTDOWN or phase == Phase.IDLE
	_refresh_overviews()

	# Last, once it is all standing: the bridge answers this by sending the document.
	world_rebuilt.emit()
	return built


## Everybody to where their side starts, whole, holding nothing.
func _place_everybody() -> void:
	var ids := players.keys()
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	var runners := 0
	var activators := 0
	var runner_count := 0

	for id: StringName in ids:
		if int(sides.get(id, RUNNERS)) == RUNNERS:
			runner_count += 1

	for id: StringName in ids:
		var player: DrPlayer = players[id]
		player.reset_progress()
		_disarm(player)

		if player.health != null:
			player.health.max_health = config.player_health
			player.health.health = config.player_health
			player.health.alive = true
			player.health.invulnerable = false

		var spot: Array

		if int(sides.get(id, RUNNERS)) == ACTIVATORS:
			spot = stage.activator_spot(activators, maxi(players.size() - runner_count, 1))
			activators += 1
		else:
			spot = stage.start_spot(runners, maxi(runner_count, 1))
			runners += 1

		player.place_at(spot[0], spot[1])
		_bot_route[player.player_id] = 0
		_bot_walk[player.player_id] = -1

		if spectate != null:
			spectate.spawned(String(player.player_id))


func _set_phase(to: int) -> void:
	if phase == to:
		return

	phase = to
	phase_elapsed = 0.0

	if stage != null:
		stage.gate_closed = to == Phase.COUNTDOWN or to == Phase.IDLE

	phase_changed.emit(to)
	GSLog.debug(CHANNEL, "the round changed phase", {"phase": Phase.keys()[to]})


## The clock, and every decision it makes.
func _advance_phase(delta: float) -> void:
	if phase == Phase.IDLE:
		return

	phase_elapsed += delta

	match phase:
		Phase.COUNTDOWN:
			if phase_elapsed >= config.countdown_seconds:
				run_elapsed = 0.0
				_set_phase(Phase.RUN)
		Phase.RUN, Phase.SHOWDOWN:
			run_elapsed += delta
			_check_round()


## The round's own clock: the document's, under the server's ceiling.
func round_limit() -> float:
	var asked := float(course_doc.get("round_seconds", 0.0))
	return minf(asked, config.round_seconds) if asked > 0.0 else config.round_seconds


## Last side standing, or the clock.
func _check_round() -> void:
	var runners := alive_on(RUNNERS)
	var activators := alive_on(ACTIVATORS)

	if runners == 0 and activators == 0:
		_decide(0, "nobody is left")
	elif runners == 0:
		_decide(ACTIVATORS, "the traps got everybody")
	elif activators == 0:
		_decide(RUNNERS, "the runners got the activator" if players_on(ACTIVATORS).size() <= 1 \
			else "the runners got the activators")
	elif run_elapsed >= round_limit():
		match config.timeout_winner:
			RUNNERS:
				_decide(RUNNERS, "time: the runners held out")
			ACTIVATORS:
				_decide(ACTIVATORS, "time: nobody got to the end")
			_:
				_decide(0, "time")


func _decide(winner: int, why: String) -> void:
	if _decided:
		return

	_decided = true
	_winner = winner
	_winner_name = why

	if authoritative and winner != 0:
		for id: StringName in players:
			if team_of(id) == winner:
				(players[id] as DrPlayer).points += config.winner_points

	GSLog.info(CHANNEL, "the round is decided", {"winner": winner, "why": why})


# --- The traps ---------------------------------------------------------------

## Each activator's hand on the buttons: a press is the use key going down near one.
##
## [b]An edge, made here from the held state[/b], as mg-wipeout made its grab: the key rides in
## every input packet, and a press sent as a reliable request would arrive a round trip after
## the key, which on a trap is a runner who was in it and now is not.
func _advance_buttons() -> void:
	for id: StringName in players:
		var player: DrPlayer = players[id]
		var pressed := player.wants_use and not bool(player.get_meta(&"use_held", false))
		player.set_meta(&"use_held", player.wants_use)

		if not pressed:
			continue

		if int(sides.get(id, 0)) != ACTIVATORS or not player.is_alive() or player.watching \
				or player.at_end:
			continue

		var index := stage.button_for(player.eye_position(), player.aim_direction(),
			config.button_reach, config.button_cone)

		if index < 0:
			continue

		var _fired := press(index, id)


## Fires trap [param index] for [param by], now, if it can be. What a button does, and what a
## suite and an admin do directly.
func press(index: int, by: StringName) -> bool:
	if stage == null or index < 0 or index >= stage.trap_count():
		return false

	if phase != Phase.RUN and phase != Phase.SHOWDOWN:
		button_refused.emit(by, "The traps are locked until the gate drops.")
		return false

	if not stage.trap_ready(index, _tick):
		button_refused.emit(by, "%s is spent." % stage.trap_name(index) if not stage.trap_running(index, _tick) \
			else "%s is still going." % stage.trap_name(index))
		return false

	stage.set_fired(index, _tick)
	pressed_by[index] = by
	trap_fired.emit(index, _tick, by)

	if progress != null and players.has(by):
		progress.on_pressed(by)

	GSLog.debug(CHANNEL, "a trap was pressed", {
		"trap": stage.trap_name(index), "by": String(by), "tick": _tick,
	})
	return true


## A press the server made, applied on a client: the trap and the tick it went on.
func apply_trap_fired(index: int, tick: int, by: StringName = &"") -> void:
	if stage == null:
		return

	stage.set_fired(index, tick)
	pressed_by[index] = by


## What the course did to everybody this tick: the traps, the pits, the drop and the finish.
##
## [b]A height comparison for the drop, not a trigger volume,[/b] as gs-timer and mg-wipeout
## both say: something falling fast crosses a thin trigger between two ticks without ever being
## inside it.
func _watch_course() -> void:
	if stage == null or stage.doc.is_empty() or phase == Phase.IDLE:
		return

	for id: StringName in players:
		var player: DrPlayer = players[id]

		# A death can decide the round, and gs-match can end it inside the call: nothing after
		# that is this round's.
		if phase == Phase.IDLE:
			return

		if not player.is_alive() or player.watching:
			continue

		var feet := player.controller.state.position

		if feet.y < stage.kill_height():
			_kill(player, _credited(id), DIED_FELL)
			continue

		if player.at_end:
			continue

		# A teleport already moved them, inside their own tick (DrPlayer._after_tick: the same on
		# a predicting client); what is left for the server is a stand-in, which carries on from
		# the route point nearest where it landed.
		if player.teleported:
			player.teleported = false
			var as_runner := int(sides.get(id, 0)) == RUNNERS

			if player.is_bot and as_runner:
				_bot_route[player.player_id] = _route_after(feet, int(_bot_route.get(player.player_id, 0)))
			elif player.is_bot:
				_bot_walk[player.player_id] = _walk_after(feet, int(_bot_walk.get(player.player_id, -1)))

			continue

		_note_reach(id, feet)

		var lethal := stage.lethal_at(feet, player.controller.state.is_crouched(), _tick)

		if lethal >= 0:
			_kill(player, lethal, DIED_TRAP)
			continue

		if lethal == DrCourse.KILLED_BY_COURSE:
			_kill(player, _credited(id), DIED_PIT)
			continue

		if int(sides.get(id, 0)) == RUNNERS and stage.in_finish(feet) \
				and (phase == Phase.RUN or phase == Phase.SHOWDOWN):
			_finish(player)


## The route point a stand-in sent to [param landed] carries on to: the nearest one at or after
## [param from_index], so it never turns back for a point it has already passed.
func _route_after(landed: Vector3, from_index: int) -> int:
	var route := stage.route()
	var best := from_index
	var best_distance := INF

	for i in range(from_index, route.size()):
		var distance := ((route[i] as Dictionary)["at"] as Vector3).distance_to(landed)

		if distance < best_distance:
			best_distance = distance
			best = i

	return best


## The walkway point a stand-in activator sent to [param landed] carries on from: the nearest one
## at or after [param from_index], as it has already walked everything before.
func _walk_after(landed: Vector3, from_index: int) -> int:
	var points := stage.walkway()
	var best := from_index
	var best_distance := INF

	for i in range(maxi(from_index, 0), points.size()):
		var distance := ((points[i] as Dictionary)["at"] as Vector3).distance_to(landed)

		if distance < best_distance:
			best_distance = distance
			best = i

	return best


## Remembers the running trap somebody is in the reach of, for `credit_seconds`.
func _note_reach(id: StringName, feet: Vector3) -> void:
	for index in range(stage.trap_count()):
		if stage.trap_running(index, _tick) and stage.trap_zone(index).has_point(feet + Vector3(0.0, 0.5, 0.0)):
			_credit[id] = [index, _tick]
			return


## The trap a fall or a pit is credited to, or -1.
func _credited(id: StringName) -> int:
	var entry: Variant = _credit.get(id)

	if entry == null:
		return -1

	if _tick - int((entry as Array)[1]) > int(config.credit_seconds * float(tick_rate)):
		return -1

	return int((entry as Array)[0])


## Kills [param player] for the course, credited to whoever pressed [param trap] (or nobody).
func _kill(player: DrPlayer, trap: int, why: StringName) -> void:
	if combat == null or player.health == null:
		return

	var by: StringName = pressed_by.get(trap, &"") if trap >= 0 else &""
	var attacker: DrPlayer = players.get(by)
	var damage := GSDamage.make(
		attacker.entity_id if attacker != null else 0, player.entity_id,
		player.health.max_health * 10.0, null
	)
	damage.point = player.controller.state.position
	damage.direction = Vector3.DOWN
	damage.tick = _tick
	damage.weapon_id = StringName("trap:%s" % str((stage.traps[trap]["spec"] as Dictionary)["id"])) \
		if trap >= 0 else why
	damage.context = {"why": why, "trap": trap}
	var _applied := combat.apply_damage(damage)


## A runner across the line: into the end arena, armed, and — if they are the first — the
## activators called down to meet them.
func _finish(player: DrPlayer) -> void:
	_finish_count += 1
	player.finished = true
	player.place = _finish_count
	player.finish_seconds = run_elapsed
	if authoritative and _finish_count == 1:
		player.points += config.first_across_points
	_send_to_end(player, true, _finish_count - 1)

	if progress != null:
		progress.on_finished(player.player_id, player.place, run_elapsed)

	player_finished.emit(player.player_id, player.place, run_elapsed)
	GSLog.debug(CHANNEL, "somebody finished", {
		"id": String(player.player_id), "place": player.place, "seconds": "%.2f" % run_elapsed,
	})

	if phase == Phase.RUN:
		_call_activators()


## The activators to the end, armed and a little tougher, because it is one against several.
##
## [b]All of them, and the buttons stop.[/b] The traps are the activators' and they are leaving
## them; a runner still on the course runs it with nobody pressing, which is the reward for
## the runner ahead getting there.
func _call_activators() -> void:
	_set_phase(Phase.SHOWDOWN)

	var seat := 0

	for player in players_on(ACTIVATORS):
		if not player.is_alive() or player.watching:
			continue

		_send_to_end(player, false, seat)
		seat += 1

		if player.health != null:
			player.health.max_health = config.player_health * config.activator_health_scale
			player.health.health = player.health.max_health

	GSLog.info(CHANNEL, "the activators were called to the end", {"activators": seat})


func _send_to_end(player: DrPlayer, runner: bool, seat: int) -> void:
	var spot := stage.end_spot(runner, seat)
	player.place_at(spot[0], spot[1])
	player.at_end = true
	_grace[player.player_id] = _tick + int(config.arrival_grace_seconds * float(tick_rate))

	if player.health != null:
		player.health.invulnerable = true

	var weapon: StringName

	if not runner and config.activator_weapon != "":
		weapon = StringName(config.activator_weapon)
	else:
		var pool := _weapon_pool()
		var draw := random.stream_for(&"end_weapon", round_number * 4096 + int(player.entity_id % 4096))
		weapon = pool[draw.next_range_i(0, pool.size() - 1)] if not pool.is_empty() else &""

	if weapon != &"":
		var _armed := arm(player, weapon)


## Ends the grace of everybody whose arrival was long enough ago.
func _advance_grace() -> void:
	for id: StringName in _grace.keys():
		if _tick < int(_grace[id]):
			continue

		_grace.erase(id)
		var player: DrPlayer = players.get(id)

		if player != null and player.health != null and not player.watching:
			player.health.invulnerable = false


## Which weapons a runner can be handed. Each one able to win a fight on its own, because the
## end is not a place to find a second.
func _weapon_pool() -> Array[StringName]:
	var out: Array[StringName] = []

	if not config.weapon_pool.is_empty():
		for id in config.weapon_pool:
			out.append(StringName(id))
		return out

	out.append_array([
		ZeeWeaponIds.REVOLVER, ZeeWeaponIds.SMG, ZeeWeaponIds.CARBINE, ZeeWeaponIds.RIFLE,
		ZeeWeaponIds.SHOTGUN, ZeeWeaponIds.MARKSMAN,
	])
	return out


# --- Weapons -----------------------------------------------------------------

## Hands [param player] a weapon, building their rig the first time.
func arm(player: DrPlayer, weapon_id: StringName) -> bool:
	if player.weapons == null:
		var rig := ZeeWeaponRig.new()
		rig.catalogue = DrPlayer.weapon_catalogue()
		rig.name = "Weapons"
		# SERVER on a server: the role only decides what is DRAWN, and a headless process has
		# no art to draw a view model from.
		rig.role = ZeeWeaponRig.Role.SERVER
		rig.authority = authoritative
		rig.tick_rate = tick_rate
		rig.wall_extra_mask = player.controller.tunables.collision_mask if player.controller != null else 0
		rig.player_ref = GSNodeRef.of_path(player.get_path())
		rig.ads_rules = ads_rules
		player.add_child(rig)

		var ready_now := rig.setup()

		if not ready_now.ok:
			GSLog.warn(CHANNEL, "a weapon rig would not set up", {
				"player": String(player.player_id), "why": ready_now.error.message,
			})
			player.remove_child(rig)
			rig.queue_free()
			return false

		player.weapons = rig

	if not player.weapons.give(weapon_id).ok:
		return false

	var def := player.weapons.arsenal.catalogue.get_def(weapon_id)

	if def != null:
		# select refuses while a round's freeze disables the arsenal, leaving a bot on the first weapon given.
		if not player.weapons.arsenal.equip(def.slot):
			var _selected := player.weapons.arsenal.select(def.slot, _tick)
		player.wanted_slot = def.slot

	player_armed.emit(player.player_id, weapon_id)
	return true


func _disarm(player: DrPlayer) -> void:
	if player.weapons == null:
		return

	player.remove_child(player.weapons)
	player.weapons.queue_free()
	player.weapons = null


func _advance_weapons() -> void:
	if combat == null or (phase != Phase.RUN and phase != Phase.SHOWDOWN):
		return

	weapon_layer.tick()

	for id: StringName in players:
		var player: DrPlayer = players[id]

		if player.weapons == null or not player.is_alive() or player.watching or not player.at_end:
			continue

		var outcome := player.weapons.simulate_tick(weapon_command_for(player), _tick)

		for shot in outcome.shots:
			shot.attacker = player.entity_id
			shot.tick = _tick
			_shoot_toys(shot)
			var resolved := combat.resolve_shot(shot)
			_note_hits(player, resolved)


## A player's movement command as a weapon command: fire, alt-fire and reload are the
## movement command's three spare buttons; the slot is this game's own input message.
func weapon_command_for(player: DrPlayer) -> GSWeaponCommand:
	var command := GSWeaponCommand.new()
	var pending := player.controller.current_command

	if pending == null:
		return command

	command.set_button(GSWeaponCommand.BUTTON_ATTACK, pending.is_pressed(GSFpsCommand.BUTTON_USER_0))
	command.set_button(GSWeaponCommand.BUTTON_ALT, pending.is_pressed(GSFpsCommand.BUTTON_USER_1))
	command.set_button(GSWeaponCommand.BUTTON_RELOAD, pending.is_pressed(GSFpsCommand.BUTTON_USER_2))
	command.set_button(GSWeaponCommand.BUTTON_AIM, player.aiming)
	command.yaw = pending.yaw
	command.pitch = pending.pitch
	command.slot = player.wanted_slot
	return command


# --- The tick ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not authoritative or match_node == null or external_tick:
		return

	simulate(delta)


## One tick, counted by this world. What an offline client and the suite use.
func simulate(delta: float) -> void:
	_tick += 1

	if hold_clock.is_valid() and hold_clock.call():
		_step_bodies_only(delta)
		return

	_step(delta)


## A tick under a cover: the bodies move, nothing else happens. A body that is not alive or is
## watching is left alone, as in [method _step].
func _step_bodies_only(delta: float) -> void:
	for id: StringName in players:
		var body: DrPlayer = players[id]

		if body.is_alive() and not body.watching:
			body.simulate(_tick, delta)


## One tick, numbered by the netcode. What the bridge uses. The step is still a fixed
## `1 / tick_rate`; a simulation stepped by a frame's delta runs differently on a bad second.
func tick_once(tick: int) -> void:
	if match_node == null:
		return

	_tick = tick
	_step(delta_for_tick())


func current_tick() -> int:
	return _tick


## Each part of the tick is a `dr.*` span ([GSFrameCost]: free while no profiler listens), so a
## bench pins a slow tick on one of them and not on "physics scripts".
func _step(delta: float) -> void:
	var t := GSFrameCost.now()
	_advance_phase(delta)
	GSFrameCost.add(&"dr.phase", t)

	t = GSFrameCost.now()
	if stage != null:
		stage.pose_at(_tick)
	GSFrameCost.add(&"dr.pose", t)

	t = GSFrameCost.now()
	_drive_bots()
	GSFrameCost.add(&"dr.bots", t)

	t = GSFrameCost.now()
	for id: StringName in players:
		var player: DrPlayer = players[id]

		# Nobody out is simulated: a body left to fall would fall for the rest of the round,
		# and one standing in a corridor would be a body the next runner collides with.
		if player.is_alive() and not player.watching:
			step_against_view(id, _tick, player.simulate.bind(_tick, delta))
	GSFrameCost.add(&"dr.players", t)

	t = GSFrameCost.now()
	_advance_flashlights()
	_advance_buttons()
	GSFrameCost.add(&"dr.buttons", t)

	t = GSFrameCost.now()
	_watch_course()
	GSFrameCost.add(&"dr.watch_course", t)

	t = GSFrameCost.now()
	_advance_grace()
	_advance_weapons()
	if authoritative:
		_advance_toys(delta)
	if combat != null:
		combat.tick(_tick, delta)
	GSFrameCost.add(&"dr.combat", t)

	t = GSFrameCost.now()
	if spectate != null:
		spectate.advance(_tick)

	if sides_are_playable() or phase != Phase.IDLE:
		match_node.tick(_tick)
	GSFrameCost.add(&"dr.match", t)


# --- The flashlight --------------------------------------------------------------

## The flashlight config, made on first use.
func flashlight_conf() -> GSFlashlightConfig:
	if flashlight_config == null:
		flashlight_config = DrFlashlight.make_config()
		flashlight_binder = DrFlashlight.make_binder(flashlight_config)
		GSLog.result(CHANNEL, "flashlight config", flashlight_binder.load_layers())
	return flashlight_config


## A new course sets everybody's light by its mood (dark ones start lit). Server side.
func _advance_flashlights() -> void:
	if not authoritative:
		return

	var cfg := flashlight_conf()
	var course_id := String(course_doc.get("id", ""))

	if course_id != _flashlight_course:
		_flashlight_course = course_id
		for p: DrPlayer in players.values():
			p.flashlight_ready = false

	for player: DrPlayer in players.values():
		if not player.flashlight_ready:
			player.flashlight_ready = true
			player.flashlight = DrFlashlight.starts_on(cfg, course_id)


## A living player in the round switches their light, runner or activator. Refused for somebody out, and where the course or the config disallows it. Server side.
func toggle_flashlight(id: StringName) -> bool:
	var player: DrPlayer = players.get(id)

	if player == null or not player.is_alive() or player.watching \
			or not GSFlashlightRules.allowed_on(flashlight_conf(), str(course_doc.get("id", ""))):
		return false

	player.flashlight = not player.flashlight
	return true


## Everybody against the course's toys, after they moved: a walk into a ball sends it on; then
## the box's own tick (the awake cap, the lost sent home). Server side.
func _advance_toys(delta: float) -> void:
	if stage == null or stage.toys == null or stage.toys.count() == 0:
		return
	for id: StringName in players:
		var player: DrPlayer = players[id]
		if not player.is_alive() or player.watching:
			continue
		var state := player.controller.state
		var tunables := player.controller.tunables
		var radius := tunables.radius if tunables != null else 0.35
		var height := lerpf(tunables.stand_height, tunables.crouch_height, state.crouch_fraction) if tunables != null else 1.8
		var _pushed := stage.toys.push_from(state.position, state.velocity, radius, height)
	stage.toys.advance(delta)


## An armed runner's shot against the toys: the first one on its ray, nearer than a wall, is
## pushed (gs-props' `shot_along`). The shot goes on to the combat, whose trace never sees a
## toy, so a ball is never cover in the arena. Server side.
func _shoot_toys(shot: GSShot) -> void:
	if not authoritative or stage == null or stage.toys == null or stage.toys.count() == 0:
		return
	var directions: Array = shot.pellets if not shot.pellets.is_empty() else [shot.direction]
	for raw: Variant in directions:
		var _pushed := stage.toys.shot_along(shot.origin, raw as Vector3, maxf(shot.max_range, 1.0), shot.damage, physics.layer_mask(&"world"))


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


## Adopts a tick rate, on a client being told what the server runs at: this world, every
## player's controller and the stage, or the client walks at the wrong speed and is corrected
## for it on every snapshot.
func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	tick_rate = rate

	if stage != null:
		stage.tick_rate = rate

	for id: StringName in players:
		(players[id] as DrPlayer).tick_rate = rate

	if match_node != null and match_node.config != null:
		match_node.config.tick_rate = rate

	return true


# --- Bots -------------------------------------------------------------------

## What a stand-in does. A runner follows the document's route; an activator walks to the
## button of the trap the runners are about to reach and presses it when one is in it; either,
## at the end, fights.
func _drive_bots() -> void:
	for id: StringName in players:
		var player: DrPlayer = players[id]

		if not player.is_bot or not player.is_alive() or player.watching:
			continue

		var command := GSFpsCommand.new()
		command.yaw = player.controller.state.yaw
		command.pitch = player.controller.state.pitch

		if phase == Phase.COUNTDOWN and int(sides.get(id, 0)) == ACTIVATORS:
			_bot_take_position(player, command)
		elif phase == Phase.IDLE or phase == Phase.COUNTDOWN:
			pass
		elif player.at_end:
			_bot_fight(player, command)
		elif int(sides.get(id, 0)) == ACTIVATORS:
			_bot_activate(player, command)
		else:
			_bot_run(player, command)

		player.controller.apply_command(command)


## A stand-in runner: along the route, and over every gap the route lands it across.
## A `jump` point is where the jump LANDS; the take-off is wherever a ray finds no floor ahead.
func _bot_run(player: DrPlayer, command: GSFpsCommand) -> void:
	var route := stage.route()

	if route.is_empty():
		return

	var index := mini(int(_bot_route.get(player.player_id, 0)), route.size() - 1)
	var point: Dictionary = route[index]
	var at := player.controller.state.position
	var toward: Vector3 = (point["at"] as Vector3) - at
	toward.y = 0.0
	var grounded := player.controller.state.mode == GSFpsState.Mode.GROUND

	command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
	command.move = Vector2(0.0, 1.0)

	_bot_cancel_drift(player, command, route, index, point, toward)

	if bool(point["walk"]):
		command.set_button(GSFpsCommand.BUTTON_WALK, true)

	if bool(point["crouch"]):
		command.set_button(GSFpsCommand.BUTTON_CROUCH, true)

	if grounded and _bot_settle_step(player, command, at):
		return

	_bot_take_off(player, command, point, index, toward, grounded)

	_bot_unstick(player, command)

	if toward.length() > float(point["reach"]):
		return

	# A landing is not reached until the bot is on its feet on it.
	if bool(point["jump"]) and not grounded:
		return

	# Nor from the foot of the step it is on: reach is flat, and a landing 1.2 m back on top of
	# a 0.94 m riser was ticked off by a bot standing against the riser, which then walked into
	# the face toward the next point and waited a second for the unstick jump, on every step.
	# (The take-off above is allowed that close for the same reason: still below the landing.)
	if bool(point["jump"]) and at.y < (point["at"] as Vector3).y - 0.5:
		return

	if bool(point["jump"]) and index + 1 < route.size() and bool((route[index + 1] as Dictionary)["jump"]):
		_bot_settle[player.player_id] = point["at"]

	_bot_route[player.player_id] = index + 1


## Jumps from the right spot toward a jump waypoint, unless this bot fumbles it.
func _bot_take_off(player: DrPlayer, command: GSFpsCommand, point: Dictionary, index: int, toward: Vector3, grounded: bool) -> void:
	var at := player.controller.state.position

	if bool(point["jump"]):
		if not grounded:
			# In the air toward the landing: brake if the jump is going to carry past it.
			_bot_land_on(player, command, point["at"])
		elif toward.length() > float(point["reach"]) + 0.5 or at.y < (point["at"] as Vector3).y - 0.5:
			var heading := toward.normalized()
			var flat_speed := Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()
			# Fast enough to cover the distance to the landing within a standing jump's airtime.
			var airtime := 2.0 * sqrt(2.0 * config.jump_height / maxf(config.gravity, 0.1))
			var fast_enough := flat_speed * airtime >= toward.length() - 0.3

			# Two rays, because a seam between floor pieces misses for one tick; at_edge jumps at any speed.
			var at_edge := not _floor_at(at + heading * 0.35)
			var gap_ahead := not _floor_at(at + heading * 0.7) and not _floor_at(at + heading * 1.4)

			if at_edge or (gap_ahead and fast_enough):
				# A fumble is a jump not taken, fixed per bot, waypoint and round.
				var draw := random.stream_for(&"bot_fumble",
					round_number * 65536 + int(player.entity_id % 256) * 256 + index)

				if draw.next_range_f(0.0, 100.0) >= config.bot_fumble_chance:
					command.set_button(GSFpsCommand.BUTTON_JUMP, true)


## Jumps when the bot has been running for a second and got nowhere.
func _bot_unstick(player: DrPlayer, command: GSFpsCommand) -> void:
	var at := player.controller.state.position
	var mark: Array = _bot_stuck.get(player.player_id, [])

	if mark.is_empty() or _tick - int(mark[1]) >= tick_rate:
		var stuck := not mark.is_empty() and command.move != Vector2.ZERO \
			and Vector2(at.x - (mark[0] as Vector3).x, at.z - (mark[0] as Vector3).z).length() < 0.4

		if stuck and player.controller.state.mode == GSFpsState.Mode.GROUND:
			command.set_button(GSFpsCommand.BUTTON_JUMP, true)

		_bot_stuck[player.player_id] = [at, _tick]


## While the runners wait behind the gate, walks a stand-in activator to the first trap's button,
## so it is there when the clump arrives (run speed is the runners' too).
func _bot_take_position(player: DrPlayer, command: GSFpsCommand) -> void:
	var first := -1
	var first_progress := 1 << 30

	for index in range(stage.trap_count()):
		if not stage.route_touches_trap(index):
			continue

		var progress := stage.route_progress(stage.trap_zone(index).get_center())

		if progress >= 0 and progress < first_progress:
			first_progress = progress
			first = index

	if first < 0 and stage.trap_count() > 0:
		first = 0

	if first >= 0:
		var _there := bot_walk_toward(player, first, command)


## A stand-in at the buttons: walks (in a straight line) to the first trap a runner reaches and presses it
## once somebody has been in it for [member DrConfig.bot_trap_delay].
func _bot_activate(player: DrPlayer, command: GSFpsCommand) -> void:
	var target := _bot_target_trap(player)

	if target < 0:
		return

	var eyes := player.eye_position()
	var button := stage.button_point(target)

	if not bot_walk_toward(player, target, command):
		player.wants_use = false
		return

	var look := button - eyes
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)

	var zone := stage.trap_zone(target)
	var someone_in := false

	for runner in players_on(RUNNERS):
		if runner.is_alive() and not runner.watching and not runner.at_end \
				and zone.has_point(runner.controller.state.position + Vector3(0.0, 0.5, 0.0)):
			someone_in = true
			break

	if not someone_in:
		_bot_watch.erase(player.player_id)
		player.wants_use = false
		return

	var since: int = _bot_watch.get(player.player_id, _tick)
	_bot_watch[player.player_id] = since

	# Released and pressed again, so the server sees an edge every other tick it is wanted.
	# The operator's delay, scaled by how quickly this preset reacts (`bot_reaction` against
	# medium's): medium presses exactly when it always did, easy later, nightmare sooner.
	var reacts := GSBotSettings.of(self).profile.reaction / _MEDIUM_BOT.reaction
	player.wants_use = _tick - since >= int(config.bot_trap_delay * reacts * float(tick_rate)) \
		and not player.wants_use


static var _MEDIUM_BOT: GSBotProfile = GSBotProfile.new()


## Walks a stand-in activator one step toward trap [param index]'s button and says whether it
## is there (close enough to press). A course with a `walkway` names the points to walk through
## (forward or back, to the point that trap's button is pressed from); without one, or for a
## button the walkway does not name, it is straight at the button.
func bot_walk_toward(player: DrPlayer, index: int, command: GSFpsCommand) -> bool:
	var eyes := player.eye_position()
	var button := stage.button_point(index)
	var goal := button
	var points := stage.walkway()
	var stop := stage.walkway_stop(index) if not points.is_empty() else -1

	if stop >= 0:
		var here: int = int(_bot_walk.get(player.player_id, -1))

		if here != stop:
			if here < 0:
				here = _walkway_shortcut(player, points, here, stop)
				_bot_walk[player.player_id] = here
			var next := here + (1 if here < stop else -1)
			var point: Dictionary = points[next]
			goal = point["at"]
			var gap := Vector2(goal.x - player.controller.state.position.x, goal.z - player.controller.state.position.z).length()

			if gap <= float(point["reach"]):
				_bot_walk[player.player_id] = next

	var flat := Vector3(goal.x - eyes.x, 0.0, goal.z - eyes.z)

	if goal != button or flat.length() > config.button_reach * 0.6:
		command.yaw = rad_to_deg(atan2(-flat.x, -flat.z))
		command.move = Vector2(0.0, 1.0)
		_bot_unstick(player, command)
		return false

	return true


## The ready trap this activator can reach in time and a runner is closest to: the buttons it
## would arrive at before the runner has passed (walking its walkway at run speed), else the one
## it is likeliest to catch. Chosen by distance alone, an activator spawned far from the first
## trap walked toward a button it could never reach while every runner went by. Re-chosen
## twice a second, so it does not turn round on every step.
func _bot_target_trap(player: DrPlayer = null) -> int:
	if player != null:
		var held: Array = _bot_goal.get(player.player_id, [])

		if not held.is_empty() and _tick - int(held[1]) < tick_rate / 2 and stage.trap_ready(int(held[0]), _tick):
			return int(held[0])

	var best := -1
	var best_score := INF

	for index in range(stage.trap_count()):
		if not stage.trap_ready(index, _tick) or not stage.route_touches_trap(index):
			continue

		var zone := stage.trap_zone(index)
		var arrive := _bot_walk_distance(player, index) / maxf(config.run_speed, 0.1) if player != null else 0.0

		for runner in players_on(RUNNERS):
			if not runner.is_alive() or runner.watching or runner.at_end:
				continue

			var at := runner.controller.state.position
			# Ahead of a runner or around them, never wholly behind: a trap the runners have
			# passed is not one to walk back to. A course with a route is measured along it (it
			# may bend); one without runs along -Z.
			var ahead := stage.route_progress(zone.get_center())

			if ahead >= 0:
				if ahead < stage.route_progress(at):
					continue
			elif zone.position.z > at.z + 0.5:
				continue

			var distance := at.distance_to(zone.get_center())
			# Seconds late, with a second's grace for the zone's width; ties go to the nearer zone.
			var late := maxf(arrive - distance / maxf(config.run_speed, 0.1) - 1.0, 0.0)
			var score := late * 100.0 + distance * 0.001

			if score < best_score:
				best_score = score
				best = index

	if player != null:
		_bot_goal[player.player_id] = [best, _tick]

	return best


func _bot_fight(player: DrPlayer, command: GSFpsCommand) -> void:
	var enemy := _nearest_enemy(player)

	if enemy == null:
		return

	_aim_bot(player, command, enemy)
	var distance := enemy.controller.state.position.distance_to(player.controller.state.position)

	if distance > 7.0:
		command.move = Vector2(0.0, 1.0)
	elif distance < 3.0:
		command.move = Vector2(0.0, -1.0)
	else:
		# Sideways, a step each second the other way: a bot that stands still to shoot is a
		# bot that is shot.
		command.move = Vector2(1.0 if (_tick / tick_rate) % 2 == 0 else -1.0, 0.0)



func _on_player_died(player: DrPlayer, damage: GSDamage) -> void:
	var by := entities.key_for_id(damage.attacker)
	var why: StringName = damage.context.get("why", DIED_SHOT)

	# Spectating and progress BEFORE gs-match: `report_kill` can end the round inside the
	# call, and a kill counted after that is counted in no round. mg-smash-copter's finding.
	if spectate != null and authoritative:
		spectate.on_died(
			player.player_id, by, why == DIED_FELL,
			damage.point if damage.point != Vector3.ZERO else player.global_position,
			stage.kill_height() + 8.0, _tick
		)

	if progress != null:
		progress.on_died(player.player_id, by, why)
		progress.report_kill(damage.attacker, player.entity_id, String(damage.weapon_id))

	if match_node != null and GSEntity.is_kind(player.entity_id, GSEntity.KIND_PLAYER):
		match_node.report_kill(String(by), String(player.player_id), why, _tick)

	if authoritative and weapon_layer != null:
		weapon_layer.drop_dead(player.player_id)

	# How the body falls, picked once, here, and carried on DEATH to every client.
	if authoritative:
		player.death = decide_death(player, damage)

	player_died.emit(player.player_id, by, why, damage.weapon_id)
	GSLog.debug(CHANNEL, "player died", {
		"id": String(player.player_id), "by": String(by), "why": String(why),
	})


## The fall a death gets: gs-player-char's reaction rule over the server's weights, seeded from
## the player and the tick, with the killing weapon's def (zee's sniper and launcher always throw
## the body). A trap kills "downward", which pushes nothing; the body just drops.
func decide_death(player: DrPlayer, damage: GSDamage) -> GSPlayerDeath:
	if _weapon_defs.is_empty():
		_weapon_defs = ZeeWeaponPack.table()
	var direction := damage.direction
	var attacker: DrPlayer = players.get(entities.key_for_id(damage.attacker)) if damage.attacker != 0 else null
	if direction.length_squared() < 0.0001 and attacker != null and attacker != player:
		direction = player.controller.state.position - attacker.controller.state.position
	return GSPlayerDeath.decide(
		ragdoll_rules.reactions(), damage.is_headshot(), damage.amount, direction,
		GSPlayerDeath.seed_of(player.entity_id, _tick), _weapon_defs.get(damage.weapon_id)
	)


# --- Reporting --------------------------------------------------------------

func seconds_left() -> float:
	match phase:
		Phase.COUNTDOWN:
			return maxf(config.countdown_seconds - phase_elapsed, 0.0)
		Phase.RUN, Phase.SHOWDOWN:
			return maxf(round_limit() - run_elapsed, 0.0)
		_:
			return 0.0


func describe() -> Dictionary:
	var used := 0

	if stage != null:
		for index in range(stage.trap_count()):
			if not stage.trap_ready(index, _tick):
				used += 1

	return {
		"round": round_number,
		"phase": Phase.keys()[phase],
		"left": "%.0f s" % seconds_left(),
		"course": str(course_doc.get("id", "-")),
		"players": players.size(),
		"runners": alive_on(RUNNERS),
		"activators": alive_on(ACTIVATORS),
		"finished": _finish_count,
		"traps": "%d of %d spent" % [used, stage.trap_count() if stage != null else 0],
		"decided": _winner_name if _decided else "-",
		"courses": catalogue.courses.size() if catalogue != null else 0,
		"phase_id": phase,
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["deathrun, round %d" % round_number])
	var facts := describe()

	for key: String in facts:
		lines.append("  %-10s %s" % [key, facts[key]])

	for player in players_on(ACTIVATORS):
		lines.append("  activator  %s%s" % [player.display_name, "" if player.is_alive() else " (out)"])

	if stage != null:
		lines.append_array(stage.describe_lines())

	return lines


## Every damage a weapon's shot did to somebody else, as [signal hit_landed] for the shooter.
## Only what took health and only on the authority: a refused hit, a dead body or the
## shooter's own splash is no confirmation anybody wants a marker for.
func _note_hits(shooter: DrPlayer, shot: GSShot) -> void:
	if not authoritative or shot == null or shooter == null:
		return
	if progress != null:
		progress.report_shot(shot)
	for damage: GSDamage in shot.damages:
		if damage == null or damage.refused or damage.health_lost <= 0.0 or damage.victim == shooter.entity_id:
			continue
		if progress != null:
			progress.report_damage(damage)
		hit_landed.emit(shooter.player_id, damage.point, damage.lethal, damage.hit_group == GSHitGroup.HEAD)
