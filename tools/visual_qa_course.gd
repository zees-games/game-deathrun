extends RefCounted

## The course half of Deathrun's visual QA capture (tools/visual_qa.gd; the loop is dot-game's docs/visual-qa.md): the traps and the
## course objects, each filmed with a runner (DrFigure) in the real built course (DrCourse, drawn as a client draws it).
##   trap_<course>_<trap>   one trap per distinct kind of parts across every shipped course, button post included. Clips:
##                          watch (the runner stands where the trap catches somebody, the trap fires at 0.6 s) and
##                          run (the runner runs at it from 7 m away, pressed so it is out as they arrive).
##   object_<kind>          one of every piece kind a course is made of (mover, turntable, ramp, ball, cylinder, kill pit,
##                          teleport) and the start pen with its gate. Clip: approach (the runner walks up to it; a mover
##                          or turntable is ridden).
## The first-person camera is the runner's eye, so f shows what a runner sees; t and o are dot-game's outside views.

const DrCatalogue := preload("../game/dr_catalogue.gd")
const DrCourse := preload("../game/dr_course.gd")

const CLIPS_TRAP: PackedStringArray = ["watch", "run"]
const CLIPS_OBJECT: PackedStringArray = ["approach"]
## When the trap's button is pressed, seconds into every trap clip.
const PRESS_AT := 0.6
## A trap that stays out, or runs very long, is filmed this long after the press (seconds).
const TRAP_TAIL := 4.0
const RUN_SPEED := 5.0
const RUN_FROM := 7.0
const OBJECT_SECONDS := 3.0
## The piece kinds filmed; everything else a runner sees is in the course around them.
const PIECE_KINDS: PackedStringArray = ["mover", "turntable", "ramp", "ball", "cylinder", "kill", "teleport"]

var entries: Dictionary = {}
var course: DrCourse = null

var _entry: Dictionary = {}
var _clip := ""


## Every item name this file makes, in a stable order; fills [member entries].
func items(catalogue: DrCatalogue) -> PackedStringArray:
	entries.clear()
	var names := PackedStringArray()
	var seen_traps := {}
	var seen_pieces := {}
	var ids: Array = catalogue.courses.keys()
	ids.sort()
	for course_id: StringName in ids:
		var doc: Dictionary = catalogue.courses[course_id]
		var traps: Array = doc.get("traps", [])
		for index in traps.size():
			var signature := _trap_signature(traps[index])
			if seen_traps.has(signature):
				continue
			seen_traps[signature] = true
			var trap_name := "trap_%s_%s" % [course_id, str(traps[index]["id"])]
			entries[trap_name] = {"doc": doc, "kind": "trap", "index": index}
			names.append(trap_name)
		var pieces: Array = doc.get("pieces", [])
		for index in pieces.size():
			var spec: Dictionary = pieces[index]
			var kind := str(spec["kind"])
			if not PIECE_KINDS.has(kind):
				continue
			var key := kind + ("_" + str(spec.get("look", "")) if kind == "kill" else "")
			if seen_pieces.has(key):
				continue
			seen_pieces[key] = true
			entries["object_" + key] = {"doc": doc, "kind": "piece", "index": index}
			names.append("object_" + key)
		if not seen_pieces.has("start"):
			seen_pieces["start"] = true
			entries["object_start"] = {"doc": doc, "kind": "start", "index": -1}
			names.append("object_start")
	return names


func has(item: String) -> bool:
	return entries.has(item)


func clips(item: String) -> PackedStringArray:
	return CLIPS_TRAP if str(entries[item]["kind"]) == "trap" else CLIPS_OBJECT


func seconds(item: String) -> float:
	var entry: Dictionary = entries[item]
	if str(entry["kind"]) != "trap":
		return OBJECT_SECONDS
	var timing: Dictionary = (entry["doc"]["traps"][int(entry["index"])] as Dictionary)["timing"]
	var run := DrCourse.duration(timing)
	return PRESS_AT + (TRAP_TAIL if is_inf(run) else minf(run, TRAP_TAIL * 2.0)) + 0.8


## Builds [param item]'s course under [param holder], pressing the trap at [constant PRESS_AT].
func stage(holder: Node3D, item: String, clip: String) -> DotResult:
	_entry = entries[item]
	_clip = clip
	course = DrCourse.new()
	course.draw_world = true
	holder.add_child(course)
	var built := course.build((_entry["doc"] as Dictionary).duplicate(true))
	if not built.ok:
		return built
	if str(_entry["kind"]) == "trap":
		course.set_fired(int(_entry["index"]), roundi(PRESS_AT * float(course.tick_rate)))
	if str(_entry["kind"]) == "start":
		course.gate_closed = true
	course.pose_at_time(0.0)
	return DotResult.success(item)


## Poses the course at [param t] and returns {at, speed} for the runner (feet position, metres a second).
func drive(t: float) -> Dictionary:
	course.pose_at_time(t)
	match str(_entry["kind"]):
		"trap":
			return _trap_runner(t)
		"start":
			return _start_runner(t)
	return _piece_runner(t)


func _trap_runner(t: float) -> Dictionary:
	var spec: Dictionary = _entry["doc"]["traps"][int(_entry["index"])]
	var stand := _victim(spec)
	if _clip == "watch":
		return {"at": stand, "speed": 0.0}
	# Arrives at the victim point at 1.4 s, and runs on past it.
	return {"at": Vector3(stand.x, stand.y, stand.z + RUN_FROM - RUN_SPEED * t), "speed": RUN_SPEED}


func _victim(spec: Dictionary) -> Vector3:
	if spec.has("victim"):
		return spec["victim"]
	var part: Dictionary = spec["parts"][0]
	var at: Vector3 = part["at"]
	return Vector3(at.x, _ground(at, at.y + 0.5), at.z)


func _start_runner(t: float) -> Dictionary:
	var start: Dictionary = _entry["doc"]["start"]
	var at: Vector3 = start["at"]
	var size: Vector3 = start["size"]
	var yaw := float(start["yaw"])
	var basis := Basis(Vector3.UP, deg_to_rad(yaw))
	# Held at the back of the pen for the countdown, then the gate drops and they run out through it.
	course.gate_closed = t < 1.2
	var run := maxf(t - 1.2, 0.0) * RUN_SPEED
	var local := Vector3(0.0, 0.0, size.z * 0.5 - 1.0 - run)
	return {"at": at + basis * local, "speed": RUN_SPEED if t >= 1.2 else 0.0, "yaw": yaw}


func _piece_runner(t: float) -> Dictionary:
	var piece: Dictionary = course.pieces[int(_entry["index"])]
	var spec: Dictionary = piece["spec"]
	var kind := str(spec["kind"])
	if kind == "mover" or kind == "turntable":
		# Ridden: stands on it, carried with it.
		var frame := course.transform_of(piece, t)
		var size: Vector3 = spec.get("size", Vector3(0.0, float(spec.get("thickness", 0.3)), 0.0))
		var offset := Vector3(float(spec.get("radius", 0.0)) * 0.5, size.y * 0.5, 0.0)
		return {"at": frame.origin + frame.basis * offset, "speed": 0.0}
	var centre: Vector3 = spec["at"]
	var extent := _footprint(spec)
	# Walks up to 1.6 m short of its near (+Z) edge: a pit or a ball is looked at, a ramp is walked at.
	var stop_z := centre.z + extent.z * 0.5 + 1.6
	var z := maxf(stop_z, stop_z + 4.0 - RUN_SPEED * t)
	var floor_y := _ground(Vector3(centre.x, centre.y, z), centre.y + 2.0)
	return {"at": Vector3(centre.x, floor_y, z), "speed": RUN_SPEED if z > stop_z else 0.0}


## The box a piece covers on the ground (x, y, z extent).
func _footprint(spec: Dictionary) -> Vector3:
	if spec.has("size"):
		return spec["size"]
	if spec.has("radius"):
		var r := float(spec["radius"])
		return Vector3(r * 2.0, float(spec.get("height", r * 2.0)), r * 2.0)
	return Vector3(2.0, 2.0, 2.0)


## The top of the highest still box under (x, z) that is no higher than [param limit]; 0 if none.
func _ground(at: Vector3, limit: float) -> float:
	var best := -INF
	for spec: Dictionary in (_entry["doc"] as Dictionary)["pieces"]:
		if str(spec["kind"]) != "box":
			continue
		var centre: Vector3 = spec["at"]
		var size: Vector3 = spec["size"]
		var top := centre.y + size.y * 0.5
		if absf(at.x - centre.x) <= size.x * 0.5 and absf(at.z - centre.z) <= size.z * 0.5 and top <= limit:
			best = maxf(best, top)
	return 0.0 if best == -INF else best


## One string per trap that names what its parts are, so two traps of the same kind film once.
static func _trap_signature(spec: Dictionary) -> String:
	var kinds := PackedStringArray()
	for part: Dictionary in spec["parts"]:
		var flags := PackedStringArray([str(part["look"])])
		if bool(part["lethal"]):
			flags.append("lethal")
		if bool(part["solid"]):
			flags.append("solid")
		if (part["move"] as Vector3) != Vector3.ZERO:
			flags.append("move")
		if part.has("turn"):
			flags.append("turn")
		if not is_zero_approx(float(part["spin"])):
			flags.append("spin")
		if (part["push"] as Vector3) != Vector3.ZERO:
			flags.append("push")
		kinds.append("+".join(flags))
	kinds.sort()
	return "|".join(kinds)
