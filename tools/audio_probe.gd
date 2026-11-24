extends GSAudioProbe

const DrAudio := preload("res://game/dr_audio.gd")

## Under xvfb-run (never --headless, whose audio driver is Dummy): does each machine make a noise? Bakes the bank as a client does and plays every trap sound beside the listener.
##   xvfb-run -a godot --path . res://tools/audio_probe.tscn


func _make_audio() -> Node:
	return DrAudio.new()


func _cue_ids() -> Array[StringName]:
	return [DrAudio.TRAP_SAW, DrAudio.TRAP_DROP, DrAudio.TRAP_CRUSH, DrAudio.TRAP_FIRE, DrAudio.TRAP_GRIND]


func _min_length() -> float:
	return 0.3
