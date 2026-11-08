class_name DrTestToys
extends RefCounted

## Test-only physics props (toys) for the practice course, which places none in play: a ball in
## the start room and two in the arena. Set `DrCatalogue.practice_toys` before a game starts.
const PRACTICE := [
	{"toy": "football", "at": [1.8, 0.0, 6.5]},
	{"toy": "beach_ball", "at": [-7.0, 0.0, -64.0]},
	{"toy": "tyre", "at": [7.0, 0.0, -68.0], "yaw": 30.0},
]
