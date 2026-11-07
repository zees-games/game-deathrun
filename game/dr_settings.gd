extends DotMenuGameSettings

const DrBindings := preload("dr_bindings.gd")

## A player's own settings and the menu that changes them, on dot-menu's `DotMenuGameSettings` with this game's spec.
## Call `setup()`, then `bind_look`, `bind_camera` and `bind_audio`; `open()` shows the menu.
## Why the scopes are the family's: docs/comment-notes.md.

const SCHEMA_VERSION := 1

## Where this game's own document lives. The shared account document is dot-settings'.
const SETTINGS_DIR := "user://deathrun_settings"

## The app's namespace. ACCOUNT settings are shared under dot-menu's `tmc_account`.
const APP_NAMESPACE := &"deathrun"

## The field of view the camera had before this existed, and still the default.
const DEFAULT_FOV := 92

## Stock keys nothing here applies: every sound is on the SFX bus, the client binds no
## effects, and the chat box has no switch.
const NOT_APPLIED: Array[StringName] = [
	&"ui_volume", &"shake_scale", &"allow_flashes", &"fx_quality", &"chat_window",
]


func _init() -> void:
	super(spec_for())


## The game's settings as data: names, field of view, extra settings, keys and the help screen's goal and rules.
static func spec_for() -> DotMenuGameSpec:
	var s := DotMenuGameSpec.new()
	s.schema_version = SCHEMA_VERSION
	s.brand_name = "Deathrun"
	s.settings_dir = SETTINGS_DIR
	s.app_namespace = APP_NAMESPACE
	s.default_fov = DEFAULT_FOV
	s.reduce_motion_text = "The end-of-round announcement appears at once, with nothing sliding, rising or bursting."
	s.comfort_row_text = "The end-of-round announcement appears at once."
	# Top left keeps the menu button off the thumbs' corner.
	s.menu_button_corner = &"top_left"
	s.ambient_text = "Quiet sounds under the course."
	s.not_applied = NOT_APPLIED
	s.bindings_maker = func() -> DotMenuBindings: return DrBindings.make()
	s.help_about = "One long course of traps. Most players run it; one or more activators, drawn fresh each round, stand on a walkway beside it with a button for every trap. Runners try to reach the end; activators try to catch them in the traps."
	s.help_cards = [
		["Activators", "Stand at a button and press the use key while a runner is in its trap. Each trap shows its name when you look at its button."],
		["The end", "Whoever reaches the end is handed a weapon, and the first one there calls the activators down to settle it."],
	]
	s.help_sections = [["Mouse", [["Left", "Fire, at the end; watch the next player while out"], ["Right", "Alternate fire; watch the one before while out"]], &"keys"]]
	return s
