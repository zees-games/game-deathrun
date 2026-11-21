extends GSNetInput

const DrNetCommand := preload("dr_net_command.gd")

## One tick of a player's intent, on the wire: a movement command, a weapon slot and the
## use key. The game buttons ride in [member GSFpsCommand.buttons] so they order against
## movement; the slot has a field of its own (see [member DrPlayer.wanted_slot]).

## Fire. `BUTTON_USER_0`, which dot-player-controller reserves.
const BUTTON_FIRE := GSFpsCommand.BUTTON_USER_0

## The alt-fire, which on every blaster in the pack is a bash.
const BUTTON_ALT := GSFpsCommand.BUTTON_USER_1

const BUTTON_RELOAD := GSFpsCommand.BUTTON_USER_2

## How many bits the slot takes. Eight slots is one more than the pack uses.
const SLOT_BITS := 3

var move: GSFpsCommand = GSFpsCommand.new()

## Which weapon the player has asked for, or zero for "leave it alone".
var slot: int = 0

## Whether the use key is held. In this message, not [GSFpsCommand], whose spare buttons are
## taken; held every tick and edged by the server (`DrGame._advance_buttons`).
var use: bool = false

## The aim button, held: the sights are up. One bit after `use`, so a batch is bit-packed and a server of a build before this one reads the next
## input from the wrong bit; client and server are one pack version (the join handshake pins it, see docs/comment-notes.md "Aim on the wire").
var aim: bool = false


func _write(writer: GSNetWriter) -> void:
	move.write(writer)
	writer.write_uint(clampi(slot, 0, (1 << SLOT_BITS) - 1), SLOT_BITS)
	writer.write_bool(use)
	writer.write_bool(aim)


func _read(reader: GSNetReader) -> void:
	move = GSFpsCommand.new()
	move.read(reader)
	slot = reader.read_uint(SLOT_BITS)
	use = reader.read_bool()
	aim = reader.read_bool()


## Not optional. Quantisation bounds each field; it cannot bound the relationship between
## them, and a move vector of (1, 1) is 41% more speed than anybody else — which on a course
## of timed traps is a runner through a trap before it can close.
func _sanitise() -> void:
	move.sanitise()
	slot = clampi(slot, 0, (1 << SLOT_BITS) - 1)


## A silent player lets go: the default neutralises `move`, the plain `use` is cleared here.
func _neutralise() -> void:
	super()
	use = false


func _equals(other: GSNetInput) -> bool:
	var them := other as DrNetCommand
	return them != null and slot == them.slot and use == them.use and aim == them.aim and move.equals(them.move)
