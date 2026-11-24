extends GSNetInput

const DrNetCommand := preload("dr_net_command.gd")

## One tick of a player's intent, on the wire: a movement command, a weapon slot and the
## use key. The game buttons ride in [member GSFpsCommand.buttons] so they order against
## movement; the slot has a field of its own (see [member DrPlayer.wanted_slot]).

## Fire. `BUTTON_USER_0`, which gs-player-controller reserves.
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

## Bits of [member view_lag_q]: quarter ticks, so 1023 ticks, past any `max_rewind_sec` a server allows.
const VIEW_LAG_BITS := 12
const MAX_VIEW_LAG_Q := (1 << VIEW_LAG_BITS) - 1
## Bits of [member view_back] and [member view_span]. A view the pair does not fit is sent with no bracket (the lag alone), never clamped.
const VIEW_BACK_BITS := 10
const VIEW_SPAN_BITS := 6

## How far behind this command's tick the sender drew every other player, in quarter ticks; -1 sends none (`mp_solidplayers` or `mp_solidplayers_unlag` off, a client not synced yet).
## The server rewinds the other players' hulls to `tick - view_lag_q / 4` for this tick's move ([GSPlayerHullRewind], through [GSPlayerHullView]); a command with none moves against the present.
var view_lag_q: int = -1

## The snapshot bracket the sender drew between: `tick - view_back` is the older snapshot tick and `+ view_span` the newer, so both ends blend the same two samples. -1: no bracket named.
var view_back: int = -1
var view_span: int = 0


func _write(writer: GSNetWriter) -> void:
	move.write(writer)
	writer.write_uint(clampi(slot, 0, (1 << SLOT_BITS) - 1), SLOT_BITS)
	writer.write_bool(use)
	writer.write_bool(aim)
	# Appended after the aim bit, as every addition to this wire is. One bit when there is no view.
	var lagged := view_lag_q >= 0
	writer.write_bool(lagged)
	if lagged:
		writer.write_uint(clampi(view_lag_q, 0, MAX_VIEW_LAG_Q), VIEW_LAG_BITS)
		var bracketed := view_back >= 0
		writer.write_bool(bracketed)
		if bracketed:
			writer.write_uint(clampi(view_back, 0, (1 << VIEW_BACK_BITS) - 1), VIEW_BACK_BITS)
			writer.write_uint(clampi(view_span, 0, (1 << VIEW_SPAN_BITS) - 1), VIEW_SPAN_BITS)


func _read(reader: GSNetReader) -> void:
	move = GSFpsCommand.new()
	move.read(reader)
	slot = reader.read_uint(SLOT_BITS)
	use = reader.read_bool()
	aim = reader.read_bool()
	view_lag_q = -1
	view_back = -1
	view_span = 0
	if reader.read_bool():
		view_lag_q = reader.read_uint(VIEW_LAG_BITS)
		if reader.read_bool():
			view_back = reader.read_uint(VIEW_BACK_BITS)
			view_span = reader.read_uint(VIEW_SPAN_BITS)


## Not optional. Quantisation bounds each field; it cannot bound the relationship between
## them, and a move vector of (1, 1) is 41% more speed than anybody else — which on a course
## of timed traps is a runner through a trap before it can close.
func _sanitise() -> void:
	move.sanitise()
	slot = clampi(slot, 0, (1 << SLOT_BITS) - 1)
	view_lag_q = clampi(view_lag_q, -1, MAX_VIEW_LAG_Q)
	view_back = clampi(view_back, -1, (1 << VIEW_BACK_BITS) - 1)
	view_span = clampi(view_span, 0, (1 << VIEW_SPAN_BITS) - 1)


## A silent player lets go: the default neutralises `move`, the plain `use` is cleared here.
func _neutralise() -> void:
	super()
	use = false
	view_lag_q = -1
	view_back = -1
	view_span = 0


func _equals(other: GSNetInput) -> bool:
	var them := other as DrNetCommand
	return them != null and slot == them.slot and use == them.use and aim == them.aim and move.equals(them.move) \
			and view_lag_q == them.view_lag_q and view_back == them.view_back and view_span == them.view_span
