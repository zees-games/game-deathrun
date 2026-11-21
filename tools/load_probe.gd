extends GSLoadProbe

## The load probe: dot-game's [GSLoadProbe] on this game's offline solo client, with the phase and tick
## column(s) before player/cam/hud. Needs xvfb-run, never --headless:
##   xvfb-run -a godot --path . res://tools/load_probe.tscn -- [--frames=90] [--shot=N]
const DrClient := preload("../game/dr_client.gd")


func _make_client() -> Node:
	var c := DrClient.new()
	c.set("force_offline", true)
	return c


func _columns(gate: Object) -> String:
	return "phase=%s tick=%s %s" % [client.get("game").phase, client.get("game").current_tick(), super(gate)]
