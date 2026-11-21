extends GSGameCheckSuite

## The touch layout: three buttons that fit a phone without overlapping, the sampler a touch device gets, and dot-mobile's overlay driving that sampler (stick, look, use, jump, duck, a menu pausing it).
## Run: `godot --headless --path . res://examples/headless_touch.tscn`

const DrClient := preload("../game/dr_client.gd")
const DrPlayer := preload("../game/dr_player.gd")
const DrSettings := preload("../game/dr_settings.gd")
const DrTouch := preload("../game/dr_touch.gd")
const CHECKS := 26


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-deathrun: touch buttons")
	var ids: Array[StringName] = []
	for b: Dictionary in DrClient.touch_layout().buttons():
		ids.append(b["id"])
	_check(ids.has(&"use") and ids.has(&"jump") and ids.has(&"crouch"), "use, jump and duck are on the layout")

	GSPlatform.touch_override = 0
	_check(not DrPlayer.new_sampler(GSFpsTunables.new()) is GSFpsTouchSampler, "no touch: the plain sampler")
	GSPlatform.touch_override = 1
	var sampler := DrPlayer.new_sampler(GSFpsTunables.new())
	_check(sampler is GSFpsTouchSampler, "touch: the touch sampler")

	for size: Vector2 in [Vector2(844, 390), Vector2(667, 375), Vector2(932, 430)]:
		var buttons := GSTouchButtons.new()
		buttons.size = size
		buttons.set_buttons(DrClient.touch_layout().buttons())
		add_child(buttons)
		var bounds := Rect2(Vector2.ZERO, size)
		_check(bounds.encloses(buttons.footprint()), "the cluster fits %dx%d" % [size.x, size.y], str(buttons.footprint()))
		var clash := ""
		for i in ids.size():
			for j in range(i + 1, ids.size()):
				var gap := buttons.centre_of(ids[i]).distance_to(buttons.centre_of(ids[j])) - buttons.radius_of(ids[i]) - buttons.radius_of(ids[j])
				if gap < 4.0:
					clash = "%s and %s" % [ids[i], ids[j]]
		_check(clash == "", "no two buttons overlap at %dx%d" % [size.x, size.y], clash)
		if size.x == 844.0:
			var use_pos := buttons.centre_of(&"use")
			_check(buttons.contains_point(use_pos), "a point on use is the button's")
			_check(not buttons.contains_point(Vector2(100, 100)), "a point on the left half is the look stick's")
		buttons.free()
	sampler = null

	var settings := DrSettings.new()
	var config := settings.config
	if &"menu_button_corner" in config:
		_check(config.get(&"menu_button_corner") == &"top_left", "the menu button is in the top-left corner")
	else:
		_check(true, "this dot-menu has no menu_button_corner; nothing to set")
	config = null
	settings.free()
	GSPlatform.touch_override = 0
	var off := GSTouchButtons.new()
	add_child(off)
	_check(not off.visible, "no touch: the buttons are hidden")
	off.free()
	GSPlatform.touch_override = -1
	await _overlay()
	_report(CHECKS)


## dot-mobile's overlay over a HUD of the real type (a CanvasLayer, as DrHud is), driving a touch sampler.
func _overlay() -> void:
	GSPlatform.touch_override = 1
	var hud := CanvasLayer.new()
	add_child(hud)
	var sampler := GSFpsTouchSampler.new(GSFpsTunables.new())
	var state := {"use": false, "busy": false}
	var touch := DrTouch.new()
	touch.use_fn = func(down: bool) -> void: state["use"] = down
	touch.sampler_fn = func() -> GSFpsSampler: return sampler
	touch.busy_fn = func() -> bool: return state["busy"]
	touch.live_fn = func() -> bool: return true
	touch.build(hud, GSMobileRules.new(), DrClient.touch_layout().buttons())
	touch.sync()
	await get_tree().process_frame
	var controls := touch.controls
	_check(controls != null and controls.touch and controls.sampler == sampler, "the overlay drives the client's own sampler", str(touch.describe()))
	_check(controls.get_parent() == hud, "it hangs under the HUD")
	var ids: Array[StringName] = []
	for b: Dictionary in DrClient.touch_layout().buttons():
		ids.append(b["id"])
	var held := 0
	for id: StringName in ids:
		if controls.buttons.centre_of(id) != Vector2.ZERO:
			held += 1
	_check(held == ids.size(), "every layout button is on the overlay", str(held))
	var tap := InputEventScreenTouch.new()
	tap.pressed = true
	var fake := InputEventMouseMotion.new()
	fake.device = InputEvent.DEVICE_ID_EMULATION
	_check(touch.takes(tap) and touch.takes(fake), "it takes touches and the mouse emulated from them")
	var real := InputEventMouseMotion.new()
	_check(not touch.takes(real), "a real mouse is the game's")
	_check(controls.sampler.ignore_fn.is_valid(), "the sampler is told which fingers are buttons")
	controls.buttons.button_down.emit(&"use")
	_check(bool(state["use"]), "use is held while its button is")
	controls.buttons.button_up.emit(&"use")
	_check(not bool(state["use"]), "and let go with it")
	var thumb := InputEventScreenTouch.new()
	thumb.index = 3
	thumb.pressed = true
	thumb.position = controls.buttons.centre_of(&"jump")
	controls.buttons._input(thumb)
	_check(sampler._held == GSFpsCommand.BUTTON_JUMP, "jump is held on the sampler", str(sampler._held))
	thumb.pressed = false
	controls.buttons._input(thumb)
	_check(sampler._held == 0, "and let go with the thumb", str(sampler._held))
	state["busy"] = true
	touch.sync()
	_check(not controls.visible and not touch.active(), "a menu pauses it")
	_check(not touch.takes(tap) and not touch.takes(fake), "and a paused overlay leaves touches and the emulated mouse to the menu")
	state["busy"] = false
	touch.sync()
	_check(touch.active(), "closing the menu brings it back")
	hud.free()
	GSPlatform.touch_override = -1
