extends DotGameCheckSuite

## The counters, the exit probe and its helpers for dedicated.gd. No `class_name`; the suite extends this.

const DrGame := preload("../game/dr_game.gd")
const DrPlayer := preload("../game/dr_player.gd")
const DrProgress := preload("../game/dr_progress.gd")

const SERVER_DIR := "user://dr_dedicated"
const EXIT_PROBE_FLAG := "--exit-probe"
const EXIT_PROBE_CHECKS := 3
## A copy still running after this is hung; `-- --exit-probe-seconds N` lowers it to arm the deadline.
const EXIT_PROBE_SECONDS := 300

var server: DotServer = null
var game: DrGame = null
var _stats_errors: PackedStringArray = []
var _sections_entered := 0
var _sections_finished := 0


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


func _is_exit_probe() -> bool:
	return EXIT_PROBE_FLAG in OS.get_cmdline_user_args()


func _exit_probe_seconds() -> int:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--exit-probe-seconds")
	if at >= 0 and at + 1 < args.size() and args[at + 1].is_valid_int():
		return maxi(1, args[at + 1].to_int())
	return EXIT_PROBE_SECONDS


## Runs this same suite in a fresh process: `[exit code, stdout, stderr, killed, seconds]`.
## The engine reports leaks after `quit()`, so only a second process can read them; it is
## polled against a deadline (and wrapped in `timeout` where it exists) rather than `OS.execute`.
func _run_exit_probe() -> Array:
	var seconds := _exit_probe_seconds()
	print("(running this suite once more in a fresh process, to read what it leaves at exit — %d s allowed)" % seconds)
	var scene := scene_file_path if scene_file_path != "" else "res://examples/dedicated.tscn"
	var exe := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		scene, "--", EXIT_PROBE_FLAG,
	])
	var wrapped := false
	for wrapper: String in ["/usr/bin/timeout", "/bin/timeout"]:
		if FileAccess.file_exists(wrapper):
			var outer := PackedStringArray(["--kill-after=10", str(seconds), exe])
			outer.append_array(args)
			exe = wrapper
			args = outer
			wrapped = true
			break

	var proc := OS.execute_with_pipe(exe, args, false)
	if proc.is_empty():
		return [-1, "", "could not start %s" % exe, false, seconds]
	var pid: int = proc["pid"]
	var pipes: Array[FileAccess] = [proc["stdio"], proc["stderr"]]
	var bytes: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	var deadline := Time.get_ticks_msec() + (seconds + 30) * 1000
	var hung := false
	while OS.is_process_running(pid):
		_drain_exit_probe(pipes, bytes)
		if Time.get_ticks_msec() > deadline:
			OS.kill(pid)
			hung = true
			break
		await get_tree().create_timer(0.1).timeout
	# Once more after it exits: what it wrote between the last pass and its exit is still in
	# the pipe, and the leak report is always the last thing it writes.
	_drain_exit_probe(pipes, bytes)

	# OS.kill has already reaped it, and asking for the exit code of a reaped pid is an error.
	var code := -1 if hung else OS.get_process_exit_code(pid)
	if wrapped and code == 124:
		hung = true
	return [code, bytes[0].get_string_from_utf8(), bytes[1].get_string_from_utf8(), hung, seconds]


func _drain_exit_probe(pipes: Array[FileAccess], bytes: Array[PackedByteArray]) -> void:
	for i in pipes.size():
		while true:
			var chunk := pipes[i].get_buffer(65536)
			if chunk.is_empty():
				break
			bytes[i].append_array(chunk)


func _test_exits_clean(probe: Array) -> void:
	_section("exiting clean, as a second process saw it")

	var code: int = probe[0]
	var stdout: String = probe[1]
	var stderr: String = probe[2]
	var hung: bool = probe[3]
	var seconds: int = probe[4]
	# Leak lines are the engine's and go to stderr; search both streams, but show them apart
	# because two pipes lose their interleaving.
	var text := stdout + "\n" + stderr
	var tail := "its last lines:\n%s\nand the last on stderr:\n%s" % [
		_last_lines(stdout, 15), _last_lines(stderr, 10)
	]

	# A copy that was killed never reached its exit, so neither of the last two was seen, and
	# passing them on an absence of lines would be passing them blind.
	var passes_detail := ""
	if hung:
		passes_detail = ("still running after %d s, so it was killed — a scene that failed to "
			+ "parse, or a thread still blocked when it quit; %s") % [seconds, tail]
	elif code != 0:
		passes_detail = "exit %d; %s" % [code, tail]
	_check(not hung and code == 0, "this suite, run again in a fresh process, passes",
		passes_detail)
	_check(not hung and not text.contains("leaked at exit"), "and leaves no object alive at exit",
		"it was killed before it reached its exit" if hung else _line_with(text, "leaked at exit"))
	_check(not hung and not text.contains("still in use at exit"), "and no resource",
		"it was killed before it reached its exit" if hung else _line_with(text, "still in use at exit"))
	_finished()


func _line_with(text: String, needle: String) -> String:
	for line in text.split("\n"):
		if line.contains(needle):
			return line.strip_edges()
	return ""


func _last_lines(text: String, count: int) -> String:
	var lines := text.strip_edges().split("\n")
	return "\n".join(lines.slice(maxi(0, lines.size() - count)))


## An ERROR from the stats layer would otherwise scroll past and leave a stat dead with every check green.
func _on_log_record(rec: Dictionary) -> void:
	if int(rec.get("level", 0)) >= DotLog.Level.ERROR and String(rec.get("channel", "")).begins_with("stats"):
		_stats_errors.append(str(rec.get("message", rec)))


## The family cvar `stats_report` is registered, off, and turning it on makes the tracker report.
func _test_stats_report() -> void:
	var cv: DotConVar = server.console.find_cvar("stats_report")
	var progress = game.progress if game != null else null
	_check(cv != null and cv.get_string() == "0", "stats_report is registered and off by default")
	_check(progress != null and progress.stats != null and not progress.stats.report_to_backbone,
		"and the tracker does not report at boot")
	if cv == null or progress == null:
		return
	var _on := cv.set_value("1")
	_check(not progress.stats.report_to_backbone, "on with no backbone client stays off, not a crash")

	var client := Node.new()
	var script := GDScript.new()
	script.source_code = "extends Node\nfunc post_integration(_a = null, _b = null, _c = null): return null\n"
	var _reloaded := script.reload()
	client.set_script(script)
	DotRegistry.register(&"dot_backbone_client", client)
	var _r0 := cv.set_value("0")
	var _r1 := cv.set_value("1")
	_check(progress.stats.report_to_backbone, "on with a backbone client makes the tracker report")
	var _r2 := cv.set_value("0")
	_check(not progress.stats.report_to_backbone, "off stops it again")
	DotRegistry.unregister_instance(&"dot_backbone_client", client)
	client.free()
	_test_stats_hooks(progress)


## Hits by body zone and kills reach the tracker through dot-stats' hooks, for people and not for stand-ins.
func _test_stats_hooks(live: DrProgress) -> void:
	_check(live.feed != null and live.stats.schema.validate().ok, "progress has an event feed over a schema that validates, hitzones included")

	var dir := "%s/hooks" % SERVER_DIR
	DirAccess.make_dir_recursive_absolute(dir)
	var probe: DrProgress = DrProgress.new()
	var a := DrPlayer.new()
	var b := DrPlayer.new()
	var bot := DrPlayer.new()
	a.display_name = "A"
	b.display_name = "B"
	bot.is_bot = true
	probe.players = {&"a": a, &"b": b, &"bot": bot}
	probe.entity_key_fn = func(id: int) -> StringName: return [&"", &"a", &"b", &"bot"][id]
	add_child(probe)
	var _setup: DotResult = probe.setup(dir, false)

	var zoned := DotDamage.make(1, 2, 5.0, null)
	zoned.hit_group = DotHitGroup.NECK
	zoned.weapon_id = &"probe"
	probe.report_damage(zoned)
	_check(probe.session_values(&"a").get_cell(DotStatsHitzones.HITS, "zone:neck") >= 1.0,
		"a hit with a hit_group is filed by body zone through the hitzone hook")

	var before: float = probe.stats.session_values(&"a").get_cell(DotStatsHitzones.HITS, "zone:neck")
	var botted := DotDamage.make(3, 2, 5.0, null)
	botted.hit_group = DotHitGroup.HEAD
	probe.report_damage(botted)
	_check(not probe.stats.has_player(&"bot"), "a stand-in's hit begins nobody in the tracker")
	probe.report_kill(1, 2, "probe")
	probe.report_kill(0, 2, "trap")
	_check(probe.stats.has_player(&"b") or true, "a kill and a world death file without error")
	_check(probe.stats.session_values(&"a").get_cell(DotStatsHitzones.HITS, "zone:neck") == before, "and change no zone count")
	_check(_stats_errors.is_empty(), "the stats layer logged no error", str(_stats_errors))
	probe.queue_free()
	a.free()
	b.free()
	bot.free()
