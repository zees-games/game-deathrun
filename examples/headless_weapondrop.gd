extends "headless_run_flashlight.gd"

const DrWeaponNet := preload("../game/net/dr_weapon_net.gd")

## Dropped guns at the end: the drop key, pickup with ammunition, a dead player's gun, floor clearing,
## the sv_weapon_drop* cvars, and the same floor on a client.
## Run: godot --headless --path . res://examples/headless_weapondrop.tscn

const SECTIONS := 3
const CHECKS := 13


class FakeBridge extends RefCounted:
	var wire: Array = []

	func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
		wire.append([peer_id, kind, body])

	func _broadcast(kind: int, body: PackedByteArray) -> void:
		wire.append([0, kind, body])

	func announce_armed(_id: StringName, _weapon: StringName) -> void:
		pass

	func session_of(_id: StringName) -> int:
		return 1


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-deathrun: weapon drops")
	await _test_throw_and_pickup()
	await _test_death_and_clearing()
	await _test_wire()
	for world in _worlds.duplicate():
		await _dispose(world)
	_report_sections(_sections_entered, _sections_finished, SECTIONS, CHECKS)


## A round whose first runner has crossed the line and stands armed in the end arena.
func _end_round() -> Array:
	var game := await _world(func(c: DrConfig) -> void:
		c.countdown_seconds = 0.2
		c.arrival_grace_seconds = 0.5
	)
	var players := await _round(game, 3)
	await _step(game, int(0.3 * TICK_RATE))
	players[0].place_at(game.course_doc["finish"]["at"], 0.0)
	await _step(game, int(0.7 * TICK_RATE))
	return [game, players]


func _test_throw_and_pickup() -> void:
	_section("Throw and pickup")
	var made := await _end_round()
	var game: DrGame = made[0]
	var layer = game.weapon_layer
	var runner: DrPlayer = made[1][0]
	var rules: DotWeaponDropRules = game.drop_rules
	if not _check(layer != null and runner.weapons != null and runner.at_end, "the game builds a layer and the runner is armed at the end"):
		return
	_check(layer.drops.is_authority, "the server layer is authoritative")

	rules.key_enabled = false
	_check(layer.throw_for(runner.player_id) == 0, "sv_weapon_drop_key 0 throws nothing")
	rules.key_enabled = true

	var id: int = layer.throw_for(runner.player_id)
	_check(id > 0 and layer.drops.count() == 1, "the key throws the gun in hand")

	var entry: Dictionary = layer.drops.snapshot()[0]
	runner.controller.state.position = (entry["at"] as Transform3D).origin - Vector3.UP * 0.5
	layer.drops.tick(5.0)
	layer.tick()
	_check(layer.drops.count() == 0, "a player in reach takes the gun back")
	_finished()


func _test_death_and_clearing() -> void:
	_section("Death and clearing")
	var made := await _end_round()
	var game: DrGame = made[0]
	var layer = game.weapon_layer
	_fell(game, made[1][0])
	_check(layer.drops.count() == 1, "a dead player leaves the gun lying")
	layer.clear()
	_check(layer.drops.count() == 0, "clearing empties the floor")

	var made2 := await _end_round()
	var g2: DrGame = made2[0]
	g2.drop_rules.on_death = false
	_fell(g2, made2[1][0])
	_check(g2.weapon_layer.drops.count() == 0, "sv_weapon_drop_death 0 leaves nothing")
	_finished()


func _test_wire() -> void:
	_section("Wire")
	var made := await _end_round()
	var game: DrGame = made[0]
	var layer = game.weapon_layer
	var runner: DrPlayer = made[1][0]
	var bridge := FakeBridge.new()
	var server_net := DrWeaponNet.new()
	var client_net := DrWeaponNet.new()
	var lost: Array = []
	client_net.lost_received.connect(func(session_id: int, weapon_id: StringName) -> void: lost.append([session_id, weapon_id]))
	server_net.attach(bridge)
	server_net.watch(layer)

	var config := DrConfig.new()
	config.warmup_seconds = 0.0
	config.minimum_players = 0
	config.course_ids = PackedStringArray(["dr_practice"])
	var client := DrGame.new()
	client.name = "Client"
	client.config = config
	client.tick_rate = TICK_RATE
	client.authoritative = false
	client.register_service = false
	add_child(client)
	client.set_physics_process(false)
	_worlds.append(client)
	await _physics_frame()
	await _physics_frame()
	var mirror = client.weapon_layer
	_check(not client_net.apply(DrEvents.Kind.TRAP, DotNetReader.new(PackedByteArray()), mirror),
		"another game event is left to the bridge")
	var id: int = layer.throw_for(runner.player_id)
	_check(id > 0 and bridge.wire.size() >= 1, "a throw puts events on the wire", str(bridge.wire.size()))
	for item in bridge.wire:
		var _ok := client_net.apply(item[1], DotNetReader.new(item[2]), mirror)
	bridge.wire.clear()
	_check(mirror.drops.count() == 1 and mirror.drops.has_drop(id), "the client draws the same drop under the same id")
	_check(lost.size() == 1, "the thrower is told the gun left their hands")

	server_net.send_snapshot(7, layer)
	_check(bridge.wire.size() == layer.drops.count(), "a joiner is sent every gun lying")
	layer.clear()
	_finished()


## A player dies the way a fall kills: damage from nobody, stamped with the tick.
func _fell(game: DrGame, victim: DrPlayer) -> void:
	var fall := DotDamage.make(0, victim.entity_id, 10000.0, null)
	fall.tick = game._tick
	fall.context = {"why": DrGame.DIED_FELL}
	var _applied := game.combat.apply_damage(fall)
