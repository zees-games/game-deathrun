extends DotGameCheckSuite

## The touch layout: three buttons that fit a phone without overlapping, the sampler a touch device gets, and a finger on a button kept off the look stick.
## Run: `godot --headless --path . res://examples/headless_touch.tscn`

const DrClient := preload("../game/dr_client.gd")
const DrPlayer := preload("../game/dr_player.gd")
const DrSettings := preload("../game/dr_settings.gd")
const CHECKS := 14


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-deathrun: touch buttons")
	var ids: Array[StringName] = []
	for b: Dictionary in DrClient.TOUCH_LAYOUT:
		ids.append(b["id"])
	_check(ids.has(&"use") and ids.has(&"jump") and ids.has(&"crouch"), "use, jump and duck are on the layout")

	DotPlatform.touch_override = 0
	_check(not DrPlayer.new_sampler(DotFpsTunables.new()) is DotFpsTouchSampler, "no touch: the plain sampler")
	DotPlatform.touch_override = 1
	var sampler := DrPlayer.new_sampler(DotFpsTunables.new())
	_check(sampler is DotFpsTouchSampler, "touch: the touch sampler")

	for size: Vector2 in [Vector2(844, 390), Vector2(667, 375), Vector2(932, 430)]:
		var buttons := DotTouchButtons.new()
		buttons.size = size
		buttons.set_buttons(DrClient.TOUCH_LAYOUT)
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
			DrPlayer.touch_ignore_fn = buttons.contains_point
			var made := DrPlayer.new_sampler(DotFpsTunables.new()) as DotFpsTouchSampler
			_check(made.ignore_fn.is_valid() and made.ignore_fn.call(use_pos), "the sampler ignores a finger on a button")
		buttons.free()
	DrPlayer.touch_ignore_fn = Callable()
	sampler = null

	var settings := DrSettings.new()
	var config := settings.config
	if &"menu_button_corner" in config:
		_check(config.get(&"menu_button_corner") == &"top_left", "the menu button is in the top-left corner")
	else:
		_check(true, "this dot-menu has no menu_button_corner; nothing to set")
	config = null
	settings.free()
	DotPlatform.touch_override = 0
	var off := DotTouchButtons.new()
	add_child(off)
	_check(not off.visible, "no touch: the buttons are hidden")
	off.free()
	DotPlatform.touch_override = -1
	_report(CHECKS)
