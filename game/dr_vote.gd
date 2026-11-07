extends DotVoteRoundGame

## The players choose the next course: dot-vote's [DotVoteRoundGame] with Deathrun's names. A round here IS a course, so the ballot
## opens [member open_after_sec] into every course (no [member due_fn]) and applies when the round ends; the rest is dot-vote's settings
## (`user://cfg/deathrun_vote.json`, `game.yml` metadata `course_vote:`). `{"enabled": false}` leaves the rotation to decide alone.

const DrCatalogue := preload("dr_catalogue.gd")

const CHANNEL := "deathrun.vote"

const METADATA_KEY := "course_vote"

## What the vote command is called: `!vote 2` in chat, `vote 2` in a console.
const COMMAND_NAMES := {"vote": "vote"}


func _init() -> void:
	channel = CHANNEL
	metadata_key = METADATA_KEY
	command_names = COMMAND_NAMES
	noun = "course"
	config_path = "user://cfg/deathrun_vote.json"


func _default_kinds() -> PackedStringArray:
	return DrCatalogue.accepted_map_kinds()
