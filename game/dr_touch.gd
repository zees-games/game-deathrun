extends RefCounted

## The phone's controls: dot-mobile's stick, drag-look and buttons over the HUD, driving the client's own
## [DotFpsTouchSampler]. A run has no weapon in hand to aim, so no crosshair, aim assist or auto-fire is wired; the
## server's `sv_mobile_*` cvars still bound the rest. The buttons are the platformer preset of [method DrClient.touch_layout]:
## use (held, like the key), jump and duck (command bits held on the sampler). Stick and drag-look are dot-mobile's.

const USE := &"use"
## The command bit the overlay holds on the sampler for a button.
const HOLDS := {&"jump": DotFpsCommand.BUTTON_JUMP, &"crouch": DotFpsCommand.BUTTON_CROUCH}

var controls: DotMobileControls = null
## (down: bool): the client's use key, held.
var use_fn: Callable = Callable()
## () -> DotFpsSampler: the sampler the keys drive now (the player's own offline, the client's online).
var sampler_fn: Callable = Callable()
## () -> bool: a menu, the console, the cover or spectating has the screen.
var busy_fn: Callable = Callable()
## () -> bool: this player is in the run (alive, not watching, not under the cover).
var live_fn: Callable = Callable()
## () -> Button: dot-menu's Menu button, whose touches are the GUI's, or null before the menu exists.
var menu_button_fn: Callable = Callable()

var _layout: Array[Dictionary] = []
var _use_down := false


## Builds the overlay under [param host] (the HUD), following [param rules] (the server's). [param rows] are the layout's
## buttons; the holds are added here. Set the callables first.
func build(host: Node, rules: DotMobileRules, rows: Array[Dictionary], platform: Object = null) -> void:
	controls = DotMobileControls.new()
	controls.name = "TouchControls"
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if rules != null:
		controls.rules = rules
	controls.ignore_fn = _on_menu_button
	controls.live_fn = func() -> bool: return live_fn.is_valid() and bool(live_fn.call())
	controls.button_pressed.connect(_pressed.bind(true))
	controls.button_released.connect(_pressed.bind(false))
	for row: Dictionary in rows:
		var made := row.duplicate()
		if HOLDS.has(row["id"]):
			made["hold"] = HOLDS[row["id"]]
		_layout.append(made)
	host.add_child(controls)
	var sampler: DotFpsSampler = sampler_fn.call() if sampler_fn.is_valid() else null
	if sampler != null:
		controls.setup(sampler, _layout)
	if platform != null and platform.has_method(&"fit_touch_buttons") and controls.buttons != null:
		platform.call(&"fit_touch_buttons", controls.buttons, _layout)


## Follows the live sampler and pauses while anything else has the screen. Called every frame by the client.
func sync() -> void:
	if controls == null:
		return
	var sampler: DotFpsSampler = sampler_fn.call() if sampler_fn.is_valid() else null
	if sampler != null and sampler != controls.sampler:
		controls.setup(sampler, _layout)
	controls.paused = busy_fn.is_valid() and bool(busy_fn.call())
	if controls.paused and _use_down:
		_pressed(USE, false)


## True when [param event] is the overlay's: a touch it forwards, or the mouse Godot emulates from that touch, which
## would otherwise turn the view a second time.
func takes(event: InputEvent) -> bool:
	if controls == null or not controls.touch:
		return false
	return controls.takes(event) or (event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION)


## Whether the overlay is up: a touch device and the server allows it.
func active() -> bool:
	return controls != null and controls.touch


func is_held(id: StringName) -> bool:
	return controls != null and controls.is_held(id)


func describe() -> Dictionary:
	return controls.describe() if controls != null else {"built": false}


func _pressed(id: StringName, down: bool) -> void:
	if id == USE:
		_use_down = down
		if use_fn.is_valid():
			use_fn.call(down)


func _on_menu_button(at: Vector2) -> bool:
	var button: Button = menu_button_fn.call() if menu_button_fn.is_valid() else null
	return button != null and is_instance_valid(button) and button.visible and button.get_global_rect().has_point(at)
