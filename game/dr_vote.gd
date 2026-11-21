extends GSVoteRoundGame

## The players choose the next course: gs-vote's [GSVoteRoundGame] with Deathrun's names. A round IS a course: the ballot
## opens [member open_after_sec] into every course and applies when it ends. Settings: `user://cfg/deathrun_vote.json`, `game.yml`
## metadata `course_vote:`; `{"enabled": false}` leaves the rotation to decide alone.

const DrCatalogue := preload("dr_catalogue.gd")

const METADATA_KEY := "course_vote"

## What the vote command is called: `!vote 2` in chat, `vote 2` in a console.
const COMMAND_NAMES := {"vote": "vote"}


func _init() -> void:
	channel = "deathrun.vote"
	metadata_key = METADATA_KEY
	command_names = COMMAND_NAMES
	noun = "course"
	config_path = "user://cfg/deathrun_vote.json"


func _default_kinds() -> PackedStringArray:
	return DrCatalogue.accepted_map_kinds()
