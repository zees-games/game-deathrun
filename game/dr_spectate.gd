extends DotSpectatorHost

const DrPlayer := preload("dr_player.gd")

## Where somebody who is out looks, and what the server lets them see: [DotSpectatorHost] with this game's numbers.
## No delay: every client already receives every player's live position, so one would hide nothing. No `class_name`; reached by preload from [DrGame], which hands it the world's two dictionaries and no reference back, so there is no cycle.

const CHANNEL := "dr.spectate"

## How far above the floor a faller's death camera hangs, looking straight down the drop.
## A fall is recorded at the kill height, where nothing is worth seeing, so the camera goes back up over the point they left.
const DROP_CAM_RISE := 6.0

## Which of the two overview cameras is the end arena's. See [DrGame._refresh_overviews].
const OVERVIEW_FIELD := 0
const OVERVIEW_SHOWDOWN := 1

## player id -> DrPlayer. The world's own dictionary, shared rather than copied, so a join is visible here the moment the world has it.
var players: Dictionary = {}

## player id -> team id. Also the world's own.
var sides: Dictionary = {}


func _init() -> void:
	chase_distance = 4.6
	chase_height = 1.2
	history_seconds = 0.0
	eye_height = DrPlayer.EYE_HEIGHT
	prefer_own_side = true
	guard_roam = true


func _channel() -> String:
	return CHANNEL


func _tune_rules(r: DotSpectatorRules) -> DotSpectatorRules:
	# Dead players stay dead until the next round, so a list including them would be bodies at the kill height.
	r.cycle_includes_dead = false
	r.delay_ticks = 0
	return r


## Somebody is out. Starts the death camera; the server's tick hands it over.
## A fall is recorded at the kill height, so the death camera is moved back up over the point they went down.
func on_died(
	player_id: StringName, by: StringName, fell: bool, at: Vector3, deck_height: float, tick: int
) -> void:
	if manager == null or not authoritative:
		return

	var where := at

	if fell:
		where = Vector3(at.x, deck_height + DROP_CAM_RISE - 2.0, at.z)

	death(String(player_id), where, String(by), tick)
	DotLog.debug(CHANNEL, "somebody who is out is watching", {
		"player": String(player_id), "by": String(by), "fell": fell,
	})


func _name_of(key: String) -> String:
	var body: DrPlayer = players.get(StringName(key))
	return body.display_name if body != null else key


func _participants() -> PackedStringArray:
	var out := PackedStringArray()

	for id: StringName in players:
		out.append(String(id))

	return out


func _team_of(key: String) -> int:
	return int(sides.get(StringName(key), 0))


func _is_alive(key: String) -> bool:
	var body: DrPlayer = players.get(StringName(key))
	# Somebody in the gallery is up and is not in the fight; a camera on them is a camera on a wall of other spectators.
	return body != null and is_instance_valid(body) and body.is_alive() and not body.watching


## Where somebody's eyes are, from where this process DRAWS them.
## The drawn position, not the node, on a world that simulates: a node moves once a tick, so a camera hung on it steps. A mirror's remote players are written every frame by the interpolator, so there the node is right, and a rider's controller is not simulated.
func _pose_of(key: String) -> Transform3D:
	var body: DrPlayer = players.get(StringName(key))

	if body == null or not is_instance_valid(body) or body.controller == null:
		return Transform3D.IDENTITY

	var at := body.global_position

	if authoritative:
		at = body.controller.render_state().position

	var state := body.controller.state
	return eye_pose(at, state.pitch, state.yaw)
