extends DotGameNetchaosServer

## Deathrun's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosServer): the world scene and the module, as a dedicated server loads them, with no stand-ins and no warmup.

var _scene: Node = null


func _configure() -> void:
	map_id = "dr_ice_works"


func _boot_world() -> void:
	if not (await boot_server()).ok:
		return
	_scene = (load("res://scenes/dr_server.tscn") as PackedScene).instantiate()
	add_child(_scene)
	_scene.game.config.course_ids = PackedStringArray([map_id])
	_scene.game.config.warmup_seconds = 0.0
	_scene.game.config.minimum_players = 0
	await get_tree().process_frame
	var loaded: DotResult = await server.modules.load_module("res://game/dr_module.gd")
	if not loaded.ok:
		printerr("netchaos server: ", loaded.error)
		return
	module = server.modules.get_module("deathrun")
	var bots: DotConVar = server.console.find_cvar("dr_bots")
	if bots != null:
		bots.force_set("0")
	if solid != "":
		var cv: DotConVar = server.console.find_cvar("mp_solidplayers")
		if cv != null:
			cv.force_set(solid)


func _players() -> Array:
	return _scene.game.players.values() if _scene != null and _scene.game != null else []
