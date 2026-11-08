extends RefCounted

## What the round killcam records of the killer's screen beyond the camera: the weapon in hand.
## The rest of dot-replay's aux (reload, aim-down-sights) stays zero: this game's weapons keep that on the rig, not the wire.

## Aux slot of the held weapon's id hash.
const WEAPON := 0

static var _names: Dictionary = {}


## The aux floats for [param p].
static func aux_of(p: Object) -> Array:
	var id: Variant = p.call(&"held_id") if p != null and p.has_method(&"held_id") else &""
	return [hash_of(StringName(id))]


static func hash_of(id: StringName) -> float:
	return float(int(String(id).hash() & 0xFFFFFF)) if id != &"" else 0.0


## The display name of the weapon an aux hash names, or empty.
static func weapon_name(hash_value: float) -> String:
	if _names.is_empty():
		for def: DotWeaponDef in ZeeWeaponPack.weapons():
			_names[int(hash_of(def.id))] = def.name_or_id()
	return String(_names.get(int(hash_value), ""))
