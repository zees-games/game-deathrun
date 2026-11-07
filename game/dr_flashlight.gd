extends RefCounted

## The flashlight's config and the server's start rule (the beam, the click and the replication helpers are dot-flashlight's).

const DrAmbience := preload("dr_ambience.gd")

const GAME_ID := "mg-deathrun"

## The ambience moods whose courses start with the light on: a course has no ambient energy, its mood is what says it is dark.
const DARK_MOODS: PackedStringArray = ["interior_horror", "cave_tunnel", "outdoor_night"]


## A config with this game's defaults: F, off on a lit course, on in the dark ones.
static func make_config() -> DotFlashlightConfig:
	var cfg := DotFlashlightConfig.new()
	cfg.key = "F"
	cfg.dark_moods = DARK_MOODS
	return cfg


## The binder: `dr_flashlight_<field>` cvars, `cfg/game/mg-deathrun/flashlight/game.yml`, a workbench set.
static func make_binder(cfg: DotFlashlightConfig) -> DotGameConfigBinder:
	var b := DotGameConfigBinder.create(cfg, GAME_ID, "dr_flashlight")
	b.profile_kind = "flashlight"
	return b


## The ambience mood of a course, by the same id prefixes the sound director reads.
static func mood_of(course_id: String) -> String:
	for prefix: String in DrAmbience.PREFIX_MOODS:
		if course_id.begins_with(prefix):
			return str(DrAmbience.PREFIX_MOODS[prefix])
	return str(DrAmbience.DEFAULT_MOOD)


## Whether a player starts the course with the light on: its mood against the config's dark moods.
static func starts_on(cfg: DotFlashlightConfig, course_id: String) -> bool:
	return DotFlashlightRules.start_on(cfg, course_id, 1.0, mood_of(course_id))
