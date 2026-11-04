extends DotGameClientBench

const DrConfig := preload("../game/dr_config.gd")
const DrGame := preload("../game/dr_game.gd")

## Client prediction bench (dot-game's DotGameClientBench): see that class for the flags.
## `--bots N` seats N stand-ins through the module's minimum_players; `--play` supplies the movement.


func _configure() -> void:
	client_scene = "res://game/dr.tscn"
	forward_action = &"dot_fps_forward"


func _boot_server(bots_wanted: int, data_dir: String) -> DotNetManager:
	var dir := ProjectSettings.globalize_path(data_dir)
	var config := make_server_config(data_dir)
	config.max_players = 24
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)
	for _i in 60:
		await get_tree().process_frame
		if server.state == DotServer.State.RUNNING:
			break
	var dr_config := DrConfig.new()
	dr_config.warmup_seconds = 0.0
	dr_config.intermission_seconds = 0.0
	dr_config.countdown_seconds = 0.5
	dr_config.round_seconds = 600.0
	dr_config.minimum_players = bots_wanted
	dr_config.course_ids = PackedStringArray(["dr_practice"])
	var game := DrGame.new()
	game.name = "World"
	game.config = dr_config
	game.config_binder = DrConfig.make_binder(dr_config)
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)
	await get_tree().process_frame
	(load("res://game/dr_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % dir)
	var loaded: DotResult = await server.modules.load_module("res://game/dr_module.gd")
	if not loaded.ok:
		printerr("client_bench server: ", loaded.error)
		return null
	for n in server.modules.loaded_names():
		var m: Object = server.modules.get_module(n)
		if m != null and m.get("net") != null:
			return m.get("net")
	return null
