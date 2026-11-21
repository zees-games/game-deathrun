extends "dr_client_flashlight.gd"

## The client's constants, settings and plain state, and its touch layout: what its parts share. No `class_name`; [code]dr_client.gd[/code] extends this.

const DrBindings := preload("dr_bindings.gd")
const DrTouch := preload("dr_touch.gd")
const DrWeaponIcons := preload("dr_weapon_icons.gd")
const DrSettings := preload("dr_settings.gd")
const DrServices := preload("dr_services.gd")

const DrConfig := preload("dr_config.gd")
const DrMapConfig := preload("dr_map_config.gd")
const DrPaths := preload("dr_paths.gd")
const DrKillcam := preload("dr_killcam.gd")
const KillPovView := preload("dr_kill_pov_view.gd")

const CHANNEL := "dr.client"

## Where a gs-server client link publishes itself.
const LINK_SERVICE := &"gs_client_link"

## Where the camera sits behind the player in third person, in metres.
const CHASE_BACK := 4.6
const CHASE_UP := 2.1

## The use key's default, for a HUD with no table to ask ([DrBindings] is what the client
## reads). The HUD names the key as bound ([member DrHud.use_action]).
const USE_KEY := KEY_E

@export var config_file: String = "user://cfg/deathrun.json"

## Play alone even when a link is available. `--offline`.
@export var force_offline: bool = false

## How many stand-ins an offline round gets: somebody at the buttons when you are running,
## and somebody running when you are at them.
@export_range(0, 12, 1) var offline_bots: int = 3

## Which view the camera starts in.
@export var third_person: bool = false

## Keeps the screen covered, and the local body and the input still, until the level, the
## player and the camera are all in. See [member GSGameClient.gate].
var gate: GSLoadGate = null

## gs-game's client platform: the cover, settings and menu, console, HUD theme, Tab, M, the
## pointer and the input block. See [GSGameClient].
var platform: GSGameClient = null
var chat: GSGameChatClient = null

## The player's own settings and the screen Escape opens. See [DrSettings].
var settings: DrSettings = null

## The player's console. See [method GSConsoleKit.build].
var console: GSConsoleController = null

var view_model: ZeeViewModel = null

## Asks a server whether this player may edit it (sv_workbench_remote); null offline.
var workbench_remote: GSGameWorkbenchRemoteClient = null
## The tuning panel's host: F9 solo, the admin's remote panel on a server that allows it.
var workbench: GSGameWorkbench = null
var link: Node = null
## Records every frame and replays the round's last moment ([DrKillcam]); then the reveal.
var killcam: DrKillcam = null
var winner_reveal: GSWinnerReveal = null
## The server's `mp_killcam_time`; -1 until it has said, so the config's number stands.
var _killcam_sec: float = -1.0

## The server's `mp_killview_camera` ([enum GSKillViewRules.Camera]); the eye until it has said.
var _killcam_camera: int = GSKillViewRules.Camera.EYE
var _round_ending: bool = false
var _round_end_number: int = 0
var _round_end_why: String = ""
var _round_board_open: bool = false
var _hud_was_visible: bool = true

var _sampler: GSFpsSampler = null

## The spectator's free camera while roaming, and the mouse motion not yet turned into a look.
var _free_cam: GSSpectatorFreeCam = null
var _roam_look: Vector2 = Vector2.ZERO

## The last [member DrPlayer.warps] this client re-aimed its mouse for.
var _seen_warps: int = 0

## The camera rig, in third person. Null in first.
var _arm: GSCameraBoom = null
var _fade: GSCameraFade = null

## How far above the player's feet the camera, or in third person the arm, is hung.
var _rig_height: float = 0.0

## Held buttons, read once a tick rather than sampled from an event queue.
var _firing: bool = false
var _alt: bool = false
var _reloading: bool = false
## The aim button, held (`DrBindings.AIM`); what goes on the wire is `_aim_sent`.
var _aiming: bool = false

## The field of view the menu sets (bound in `_adopt`); the lens zooms from it while aimed, never compounding.
var base_fov: float = 92.0
## The use key, held. Presses the button in front of an activator; see `DrGame._advance_buttons`.
var _use: bool = false

var _touch: DrTouch = null

## gs-game's platformer preset without sprint, board and chat (a runner has no sprint key and the board and chat are not routed from the touch cluster).
static func touch_layout() -> GSGameTouchLayout:
	var res := GSGameTouchLayout.build(GSGameTouchLayout.PLATFORMER, {
		GSGameTouchLayout.SPRINT: null, GSGameTouchLayout.BOARD: null, GSGameTouchLayout.CHAT: null,
	})
	if not res.ok:
		push_error("mg-deathrun touch layout refused: %s" % str(res.error))
		return GSGameTouchLayout.custom()
	return res.value


## Where the dead lie: gs-player-char's ragdolls under the game's (the server's) rules.
var ragdolls: GSPlayerRagdolls = null
