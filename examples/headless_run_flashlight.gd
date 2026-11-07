extends "headless_run_client.gd"

## The flashlight section of the headless_run suite (headless_run.gd extends this): the course's mood sets it, runners and activators switch it, the out and a course may not.

const DrFlashlight := preload("../game/dr_flashlight.gd")


func _test_the_flashlight() -> void:
	_section("the flashlight: the course sets it, runner and activator switch it, the out and a course may not")
	var game := await _world(func(c: DrConfig) -> void: c.countdown_seconds = 0.2)
	var players := await _round(game, 3)
	var runner := players[0]
	var activator := players[2]
	var cfg := game.flashlight_conf()
	var keys := DrBindings.make()
	_check(cfg.key == "F" and game.flashlight_binder != null, "the key is F and the config has a binder", cfg.key)
	_check(str(keys.row_for_action(DrBindings.FLASHLIGHT).get("default", "")) == "F" and keys.defaults_on("F").size() == 1,
		"the key is a bindings row, and nothing else defaults to F")

	_check(DrFlashlight.mood_of("dr_horror_hall") == "interior_horror" and DrFlashlight.starts_on(cfg, "dr_horror_hall"),
		"a horror course starts lit")
	_check(not DrFlashlight.starts_on(cfg, "dr_practice"), "and the lit practice course starts dark")

	cfg.default_state = DotFlashlightConfig.START_ON
	runner.flashlight_ready = false
	await _step(game, 2)
	_check(runner.flashlight, "a config that starts lit lights the player")
	cfg.default_state = DotFlashlightConfig.START_OFF
	runner.flashlight_ready = false
	await _step(game, 2)
	_check(not runner.flashlight, "and one that starts dark does not")

	_check(game.toggle_flashlight(runner.player_id) and runner.flashlight, "the switch turns a runner's light on")
	_check(game.toggle_flashlight(activator.player_id) and activator.flashlight, "and an activator's")
	_check(game.toggle_flashlight(runner.player_id) and not runner.flashlight, "and the next press turns it off")

	players[1].watching = true
	_check(not game.toggle_flashlight(players[1].player_id) and not players[1].flashlight, "somebody out of the round has no switch")

	cfg.allowed_maps = PackedStringArray(["no_such_course"])
	_check(not game.toggle_flashlight(activator.player_id) and activator.flashlight, "a course outside allowed_maps has no light")
	cfg.allowed_maps = PackedStringArray()
	cfg.default_state = DotFlashlightConfig.START_DARK
	_finished()
