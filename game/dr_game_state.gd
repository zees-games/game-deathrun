extends "dr_game_bots.gd"

## The world's constants, signals and plain state: what the simulation and the parts around it share. No `class_name`; [code]dr_game.gd[/code] extends this.

const DrCatalogue := preload("dr_catalogue.gd")
const DrAmbience := preload("dr_ambience.gd")
const DrCourseDoc := preload("dr_course_doc.gd")
const DrFlashlight := preload("dr_flashlight.gd")
const DrProgress := preload("dr_progress.gd")
const DrRules := preload("dr_rules.gd")
const DrSpectate := preload("dr_spectate.gd")
const DrWeaponLayer := preload("dr_weapon_layer.gd")

const CHANNEL := "dr.game"

## Where this world publishes itself, so a module can find it. A registry name and not an
## autoload: a server and a client in one process are two of these.
const SERVICE := &"dr_game"

## Where a host that runs this game with no server (the client shell's Solo play) publishes
## the map packs it mounted for it. See [method solo_map_dirs].
const SOLO_SERVICE := &"gs_solo"

## Snapshots a second. Thirty, like mg-wipeout: what a player reads continuously here is other
## people on floors that move under them.
const NET_SNAPSHOT_RATE := 30

## How far a position may be from the origin, in metres, on the wire. Both ends read it here.
const NET_WORLD_EXTENT := 512.0

## The two sides. Fixed ids, because the whole game is about which of the two somebody is.
const RUNNERS := 1
const ACTIVATORS := 2

const TEAM_COLOURS: Array[Color] = [
	Color(0.32, 0.58, 0.90),
	Color(0.88, 0.30, 0.26),
]

## What the stand-ins are called, solo and on a server, through gs-bot's [GSBotNames]
## (never doubled up, and numbered only past the end of the list). Not "Stand-in 2": a board of
## numbered stand-ins tells a player they are alone.
const BOT_NAMES := ["Lever", "Pressure Plate", "Tripwire", "Pitfall", "Hinge", "Ratchet", "Sprocket", "Fuse"]

const TEAM_NAMES: Array[String] = ["Runners", "Activators"]

## Which part of the round it is.
enum Phase {
	## Between rounds, or waiting for enough people to start one.
	IDLE,
	## The runners behind the gate, the activators finding their feet.
	COUNTDOWN,
	## The gate is down and the course is open.
	RUN,
	## Somebody reached the end and the activators have been called to it. The traps still
	## work for whoever is still on the course — but there is nobody left at the buttons.
	SHOWDOWN,
}

const DIED_TRAP := &"trap"
const DIED_PIT := &"pit"
const DIED_FELL := &"fell"
const DIED_SHOT := &"shot"

## Seconds after being in a running trap's reach that a fall or a pit is still that trap's.
##
## A trapdoor does not kill anybody; the spikes under it do, so a death in a pit is still credited to the activator who opened the floor.

signal player_added(player_id: StringName)
signal player_removed(player_id: StringName)

## A round began, on [param course_id].
signal round_began(number: int, course_id: StringName)

## The stage is about to be taken down and rebuilt. Before, for the bridge's sake.
signal world_clearing()

## The stage has just been rebuilt. The bridge answers by sending the document.
signal world_rebuilt()

## A round ended. [param winner] is a side (0 for a draw); [param winner_name] says why.
signal round_over(number: int, winner: int, winner_name: String)

signal phase_changed(phase: int)

## Somebody changed sides: the draw at the top of a round, or a joiner put on one.
signal side_changed(player_id: StringName, side: int)

signal player_died(player_id: StringName, by: StringName, why: StringName, weapon_id: StringName)

## An activator pressed trap [param index]'s button on [param tick].
signal trap_fired(index: int, tick: int, by: StringName)

## Somebody pressed a button that did nothing, and why. Told to them alone.
signal button_refused(player_id: StringName, why: String)

## A runner crossed the finish, [param place] first, in [param seconds].
signal player_finished(player_id: StringName, place: int, seconds: float)

signal achievement_earned(player_id: StringName, title: String, points: int)

## Somebody was handed a weapon.
signal player_armed(player_id: StringName, weapon_id: StringName)

## A weapon's shot took health off somebody: to [param player_id], the shooter, for the hit
## marker and the hit drawn on the body. The server's word, never a client's prediction.
signal hit_landed(player_id: StringName, point: Vector3, killed: bool, headshot: bool)

## The binder that layered [member config] (cfg/ yml, env, argv); null in a suite that built the config by hand.
var config_binder: GSGameConfigBinder = null

## The workbench's profile rows, made on first ask: the bridge's profile link must exist before the netcode seals, the workbench after.
var profile_runtime: GSProfileRuntime = null


func ensure_runtime() -> GSProfileRuntime:
	if profile_runtime == null:
		profile_runtime = GSProfileRuntime.new()
		profile_runtime.permit = func(actor: Variant, _flag: String) -> bool:
			return typeof(actor) == TYPE_STRING_NAME and actor == &"local"
	return profile_runtime

## gs-team's block rules (`mp_teamblock`, `!block`, `!noblock`), set by the module or the client's `add_noblock`; null without gs-team.
var block_rules: Object = null

## Whether this instance decides anything. A client sets this false.
@export var authoritative: bool = true

## Whether something else drives the tick: the bridge, on both ends.
@export var external_tick: bool = false

## Asked every tick of a world that ticks itself: true while a cover is up (the client's load
## gate). Only the bodies are stepped then, so they settle onto the floor, and the phase, the
## buttons, the course's deaths, the bots and the round clock wait. Unset, never held.
var hold_clock: Callable = Callable()

## Whether this world publishes itself under [constant SERVICE].
@export var register_service: bool = true

## Whether the stage draws its sky and its void. A client sets it.
@export var draw_world: bool = false

var catalogue: DrCatalogue = null
var combat: GSCombatManager = null

## `func(player_id: StringName) -> bool`: whether a player may be hurt now, assigned by the
## module from gs-game's `can_peer_be_harmed`. Unset offline, and a bot is never loading.
var harm_gate: Callable = Callable()
var match_node: GSMatch = null
var random: GSRandomManager = null
## What a dead body does, and which death reactions the server allows: gs-player-char's
## `sv_ragdoll*` cvars, bound by the module (REPLICATED) and followed by a client through its
## link, because the client draws the bodies. The game's, not the course's.
var ragdoll_rules: GSPlayerRagdollRules = GSPlayerRagdollRules.new()

## gs-props' `sv_toys*` (whether a course's toys are there, how many simulate at once, how hard a
## walk pushes one). Bound by the module (REPLICATED) and followed by a client, which draws them.
var toy_rules: GSPropBodyRules = GSPropBodyRules.new()

## Guns lying about (`dr_weapon_layer.gd`), built on both ends, and the `sv_weapon_drop*` rules it runs under: bound by the module, REPLICATED.
var weapon_layer: DrWeaponLayer = null
var drop_rules: GSWeaponDropRules = _walk_over_drops()

## Aim-down-sights numbers (`zee_ads_rules`, REPLICATED): the server's cfg over the shipped defaults, handed to every weapon
## rig. Bound by the module and followed by a client, so its prediction agrees. The aim bit (`DrNetCommand.aim`) sets BUTTON_AIM on the rig and scales the motor (`DrPlayer.step_controller`).
var ads_rules: ZeeAdsRules = ZeeAdsRules.load_config()

## gs-player-controller's `mp_forceview` (may a player switch to third person) and `mp_solidplayers`
## (do players and stand-ins block each other). Bound by the module (REPLICATED) and followed by a
## client, which places its camera under the first and predicts its own player under the second.
var view_rules: GSPlayerViewRules = GSPlayerViewRules.new()
## gs-mobile's `sv_mobile_*`, `sv_aim_assist*` and `sv_autofire*`: what a phone player may use. Bound REPLICATED by the module, followed by the client.
var mobile_rules: GSMobileRules = GSMobileRules.new()
var body_rules: GSPlayerBodyRules = GSPlayerBodyRules.new()
## Lag-compensated hulls (`mp_solidplayers_unlag`): a `DrHullView`, set by a netcode bridge on both ends; null with no network, where nothing is lagged. Its rewind moves the bodies in `players`.
var hull_view: RefCounted = null


## Runs [param work] (a mover's step, at [param tick]) against the hulls where the mover's own view drew them when the rules ask (mp_solidplayers_unlag), else as it is.
func step_against_view(id: StringName, tick: int, work: Callable) -> void:
	if hull_view != null and body_rules.solid and body_rules.unlag:
		hull_view.around(id, tick, work)
	else:
		work.call()
## The ambience cvars (`dr_ambient*`): bound by the module (REPLICATED), followed by a client through its link.
var ambient_rules: GSAmbienceRules = DrAmbience.make_rules()

## The flashlight's config and binder, made on first use so a suite that builds a game by hand still has one; the course id the lights were last set for.
var flashlight_config: GSFlashlightConfig = null
var flashlight_binder: GSGameConfigBinder = null
var _flashlight_course: String = ""


func _init() -> void:
	# This game's pick: runners pass through each other (see `_build_physics`). An owner who
	# wants bodies sets `mp_solidplayers 1`.
	body_rules.solid = false

## The weapon definitions by id, for the death reaction a weapon asks for. Built on first use.
var _weapon_defs: Dictionary = {}
var effects: GSFxManager = null
var spectate: DrSpectate = null
## Who a spectator may watch and whether they may fly a free camera: gs-spectate's `mp_forcecamera`,
## `mp_freeroam` and `mp_freeroam_speed`. One object for the game's life, shared with [DrSpectate]'s
## manager so a cvar change reaches it. Bound by the module (REPLICATED); a client flies the camera.
var spectate_rules: GSSpectatorRules = GSSpectatorRules.new()
var progress: DrProgress = null

## The course the next round plays, set by the players' vote ([code]game/dr_vote.gd[/code]) or
## an operator, and used once. Empty lets the rotation choose.
var next_course_id: StringName = &""

## Seconds into the current phase. Simulated, never a wall clock.
var phase_elapsed: float = 0.0

## Seconds since the gate dropped. What a finish time is, and the round clock.
var run_elapsed: float = 0.0

var phase: int = Phase.IDLE

## The course this round is run on.
var course_doc: Dictionary = {}

var entities := GSEntityTable.new()

## What the server last said about numbers a client cannot count. Negative is "count it".
var remote_runners: int = -1
var remote_activators: int = -1
var remote_playable: bool = false

## trap index -> who pressed it last. Who a trap's deaths are credited to.
var pressed_by: Dictionary = {}

var _round_seed: int = 0
var _finish_count: int = 0

## Whether the course standing now has not been run yet: the warmup's, until round one.
var _course_unplayed: bool = false

## Whether the round has been decided, and who won. What [DrRules] reads.
var _decided: bool = false
var _winner: int = 0
var _winner_name: String = ""

## Who was an activator last round, so the draw can pass them over.
var _last_activators: Array[StringName] = []

## player id -> `[trap index, tick]`: the last running trap whose reach they were in.
var _credit: Dictionary = {}

## player id -> tick they become hurtable again, after arriving in the end arena.
var _grace: Dictionary = {}

## Bots: player id -> the route point they are heading for, their aim error, the tick a
## runner entered the trap they are watching, and `[position, tick]` a second ago.
var _bot_route: Dictionary = {}
## Stand-in activators: player id -> [the trap they head for, the tick it was chosen].
var _bot_goal: Dictionary = {}
var _bot_watch: Dictionary = {}
var _bot_stuck: Dictionary = {}


## Players take a gun by walking over it: there is no use key to press at the end.
static func _walk_over_drops() -> GSWeaponDropRules:
	var rules := GSWeaponDropRules.new()
	rules.auto_pickup = true
	return rules
