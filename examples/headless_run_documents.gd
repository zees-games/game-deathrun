extends "headless_run_flashlight.gd"
## The headless_run checks on what a course is before it is built: the config, the documents, the wire, the catalogue and a delivered pack. No `class_name`; [code]headless_run.gd[/code] extends this.


func _test_config() -> void:
	_section("the configuration")
	var config := DrConfig.new()
	_check(config.validate().ok, "the defaults validate")
	_check(config.activators_for(1) == 0, "one person is not a round")
	_check(config.activators_for(2) == 1 and config.activators_for(15) == 1,
		"one activator up to fifteen players")
	_check(config.activators_for(16) == 2, "two at sixteen")
	_check(config.activators_for(40) == 5, "and five at forty, which the brief asked for")
	_check(config.activators_for(200) == config.max_activators, "never more than the most",
		"%d" % config.activators_for(200))
	var open := DrConfig.new()
	open.max_activators = 0
	_check(open.activators_for(200) == 25 and open.activators_for(2) == 1, "0 is no limit: one per eight, never everybody",
		"%d" % open.activators_for(200))
	open.max_activators = 30
	_check(open.validate().ok and open.activators_for(400) == 30, "and any count is a count", "%d" % open.activators_for(400))
	open.max_activators = -1
	_check(not open.validate().ok, "a negative most is refused")

	config.timeout_winner = 5
	_check(not config.validate().ok, "a timeout winner that is no side is refused")
	_finished()


func _test_documents() -> void:
	_section("a course is a document, and a bad one is refused with a reason")
	var practice := DrCatalogue.practice()
	_check(str(practice.get("id", "")) == "dr_practice", "the practice course validates")
	_check(practice["start"]["at"] is Vector3, "positions are normalised to vectors")
	_check((practice["traps"] as Array).size() == 5, "it has its five traps")

	var timing: Dictionary = (practice["traps"][0] as Dictionary)["timing"]
	_check(timing.has("delay") and is_zero_approx(float(timing["delay"])),
		"an omitted delay is filled in", str(timing))

	var unknown := practice.duplicate(true)
	(unknown["pieces"] as Array).append({"kind": "trampoline", "at": [0, 0, 0]})
	var refused := DrCourseDoc.validate(unknown)
	_check(not refused.ok and str(refused.error).contains("trampoline"),
		"an unknown piece kind is refused, naming it", str(refused.error) if not refused.ok else "")

	var no_button := practice.duplicate(true)
	(no_button["traps"][0] as Dictionary).erase("button")
	refused = DrCourseDoc.validate(no_button)
	_check(not refused.ok and str(refused.error).contains("button"),
		"a trap with no button is refused, saying so")

	var no_parts := practice.duplicate(true)
	(no_parts["traps"][1] as Dictionary)["parts"] = []
	_check(not DrCourseDoc.validate(no_parts).ok, "a trap that moves nothing is refused")

	var twice := practice.duplicate(true)
	(twice["traps"][1] as Dictionary)["id"] = "trapdoor"
	refused = DrCourseDoc.validate(twice)
	_check(not refused.ok and str(refused.error).contains("trapdoor"), "two traps with one id is refused")

	var ugly := practice.duplicate(true)
	((ugly["traps"][2] as Dictionary)["parts"][0] as Dictionary)["look"] = "glitter"
	_check(not DrCourseDoc.validate(ugly).ok, "a part that looks like nothing this build draws is refused")

	var later := practice.duplicate(true)
	later["format"] = 2
	_check(not DrCourseDoc.validate(later).ok, "a document from a later format is refused")

	var no_end := practice.duplicate(true)
	no_end.erase("end")
	_check(not DrCourseDoc.validate(no_end).ok, "a course with no end arena is refused")

	var lethal: Dictionary = (practice["traps"][1] as Dictionary)["parts"][0]
	_check(bool(lethal["lethal"]) and not bool(lethal["solid"]),
		"a part that kills is not solid unless the document says so")
	_finished()


func _test_the_wire() -> void:
	_section("the document travels, and arrives as the same document")
	var practice := DrCatalogue.practice()
	var bytes := DrCourseDoc.encode(practice)
	var back := DrCourseDoc.decode(bytes)
	_check(back.ok, "it decodes", back.error.message if not back.ok else "")
	_check(back.ok and DrCourseDoc.digest(back.value) == DrCourseDoc.digest(practice),
		"its digest is the one the server sent", "%d bytes" % bytes.size())
	_check(bytes.size() < DrCourseDoc.WIRE_LIMIT, "it is under the wire limit")

	var torn := bytes.slice(0, bytes.size() / 2)
	_check(not DrCourseDoc.decode(torn).ok, "half of it is refused, not built")

	# A death carries how the body falls (dot-player-char's DotPlayerDeath), last and optional.
	var fall := DotPlayerDeath.new()
	fall.reaction = &"face_plant"
	fall.roll_seed = 1234
	fall.damage = 100.0
	fall.direction = Vector3(1, 0, 0)
	var died := DrEvents.read_death(DotNetReader.new(DrEvents.write_death(5, 6, DrGame.DIED_SHOT, fall)))
	var carried: DotPlayerDeath = died.get("death")
	_check(bool(died["ok"]) and carried != null and carried.reaction == &"face_plant" and carried.roll_seed == 1234
		and carried.direction.distance_to(Vector3(1, 0, 0)) < 0.02, "a DEATH carries the fall the server picked")
	var bare := DrEvents.read_death(DotNetReader.new(DrEvents.write_death(5, 6, DrGame.DIED_SHOT)))
	_check(bool(bare["ok"]) and not bare.has("death"), "and one without a fall still reads")
	_finished()


func _test_catalogue() -> void:
	_section("the catalogue")
	var catalogue := DrCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	_check(catalogue.courses.has(DrCatalogue.PRACTICE), "the built-in course is always there")
	_check(catalogue.refused.is_empty(), "no installed document was refused",
		", ".join(catalogue.refused.keys()))

	var ids := catalogue.playable_courses(PackedStringArray())
	_check(ids.size() == 1 or not ids.has(DrCatalogue.PRACTICE),
		"practice drops out once there is a real course", "%d playable" % ids.size())

	var stream := DotRandomStream.new(7)
	var first := catalogue.next_course(PackedStringArray(), true, stream, &"")
	var second := catalogue.next_course(PackedStringArray(), true, stream, StringName(str(first["id"])))
	_check(ids.size() < 2 or str(first["id"]) != str(second["id"]),
		"a shuffle does not repeat the course just played")
	_finished()


## Every bare `"res://…"` string in a shipped script that names one of this game's own
## directories, and every `class_name`. A delivered pack cannot use either; see
## mg-smash-copter's Decision 7.
func _test_delivery() -> void:
	_section("what a delivered pack cannot do, nobody here does")
	var bare := PackedStringArray()
	var named := PackedStringArray()
	var own := ["game", "scenes", "assets", "textures", "courses", "audio"]

	for path in _scripts("res://game"):
		var lines := FileAccess.get_file_as_string(path).split("\n")

		for index in range(lines.size()):
			var line := lines[index].strip_edges()

			if line.begins_with("#"):
				continue

			if line.begins_with("class_name "):
				named.append("%s:%d" % [path, index + 1])

			for folder in own:
				var needle := "\"res://%s/" % folder

				if line.contains(needle) and not line.contains("Paths.rebase(\"res://%s/" % folder):
					bare.append("%s:%d" % [path, index + 1])

	_check(named.is_empty(), "no class_name anywhere", ", ".join(named))
	_check(bare.is_empty(), "no bare res:// path to this game's own files", ", ".join(bare))

	var root := "res://dot_cloud/someone/mg-deathrun/1.0.0/"
	var once := DrPaths.rebase_onto("res://textures/prototype/deck.png", root)
	_check(once == root + "textures/prototype/deck.png", "a path is rebased onto a mount", once)
	_check(DrPaths.rebase_onto(once, root) == once, "and a rebased path is left alone")
	_finished()


func _scripts(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)

	if dir == null:
		return out

	for file in dir.get_files():
		if file.ends_with(".gd"):
			out.append(dir_path.path_join(file))

	for sub in dir.get_directories():
		out.append_array(_scripts(dir_path.path_join(sub)))

	return out
