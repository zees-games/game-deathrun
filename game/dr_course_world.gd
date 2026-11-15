extends Node3D
## A course's world and markers, built from its document: the sky, the sun, the fog, the void,
## and the shapes everything is made of. No `class_name`; [code]dr_course.gd[/code] extends this.

const DrTextures := preload("dr_textures.gd")

## The normalised document this was built from. See [DrCourseDoc].
var doc: Dictionary = {}


static func _yaw_basis(yaw_degrees: float) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(yaw_degrees))


static func _add_box(parent: Node3D, size: Vector3, material: Material, solid: bool,
		offset: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = offset
	mesh.material_override = material
	parent.add_child(mesh)

	if solid:
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape
		shape.position = offset
		parent.add_child(shape)

	return mesh


## An arch over the finish. Meshes only: what counts is the volume ([method in_finish]).
func _build_markers() -> void:
	var finish: Dictionary = doc["finish"]
	var basis := _yaw_basis(float(finish["yaw"]))
	var size: Vector3 = finish["size"]
	var arch := Node3D.new()
	arch.name = "Finish"
	arch.transform = Transform3D(basis, finish["at"])
	add_child(arch)

	var height := maxf(size.y, 2.5)

	for side in [-1.0, 1.0]:
		var _post := _add_box(arch, Vector3(0.4, height, 0.4), DrTextures.surface(DrTextures.Role.PILLAR), false,
			Vector3(side * size.x * 0.5, height * 0.5, 0.0))

	var _beam := _add_box(arch, Vector3(size.x + 0.4, 0.6, 0.4), DrTextures.surface(DrTextures.Role.SAFE), false,
		Vector3(0.0, height, 0.0))


func _build_world() -> void:
	var theme: Dictionary = doc.get("theme", {})

	var lighting := Node3D.new()
	lighting.name = "Lighting"
	add_child(lighting)
	var sun := DotLightRig.apply(lighting, DotLightDocument.from_dictionary(light_document(theme)), light_profile())
	if sun != null:
		sun.shadow_blur = 1.5

	for node in lighting.get_children():
		if node is WorldEnvironment and (node as WorldEnvironment).environment.sky != null:
			var material := (node as WorldEnvironment).environment.sky.sky_material as ProceduralSkyMaterial
			if material != null:
				# The theme's sky at the zenith (the rig draws it in the ambient colour), and
				# the void's colour under the horizon, which is what a falling runner sees.
				material.sky_top_color = theme.get("sky", Color(0.48, 0.60, 0.74))
				material.ground_bottom_color = theme.get("void", Color(0.10, 0.12, 0.16))

	# The floor of the drop: what everybody who falls sees coming. Drawn only; the fall is a
	# height comparison in [DrGame], because a trigger volume can be stepped over between two
	# ticks by something falling fast enough.
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.name = "Void"
	# Below the kill height, where whoever falls is already dead: nobody stands on it.
	floor_mesh.set_meta(&"dot_no_collision", true)
	var plane := PlaneMesh.new()
	plane.size = Vector2(1600.0, 1600.0)
	floor_mesh.mesh = plane
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = theme.get("void", Color(0.10, 0.12, 0.16))
	floor_material.roughness = 1.0
	floor_mesh.material_override = floor_material
	floor_mesh.position = Vector3(0.0, kill_height() - 2.0, 0.0)
	add_child(floor_mesh)


## The dot-lighting document a course's theme describes. The angles are dot-lighting's source
## convention (a negative pitch is a sun in the sky); the brightness is divided by the profile's
## reference and square-rooted.
static func light_document(theme: Dictionary) -> Dictionary:
	var sun: Color = theme.get("sun", Color(1.0, 0.97, 0.92))
	var horizon: Color = theme.get("horizon", Color(0.80, 0.85, 0.90))
	return {
		"sun": {
			# High, so a corridor wall does not put the floor in shade, and behind the start, so
			# the faces a runner runs toward (a trap's front, the gate) are the lit ones.
			"pitch_src": -54.0,
			"yaw_src": 145.0,
			"colour": [sun.r, sun.g, sun.b],
			"brightness": 380.0,
			"spread_degrees": 1.0,
			# The light in the shade, a pale cool grey whatever the theme: a saturated fill turns
			# every shaded face into the theme's colour and a red hazard in shade into brown.
			"ambient_colour": [0.74, 0.78, 0.92],
		},
		# The theme's horizon from 120 m out (source units, metres / 0.01905), so no trap a runner
		# must read is hidden in it; the theme's `fog` density was the old exponential fog's.
		"fog": {
			"enabled": true,
			"colour": [horizon.r, horizon.g, horizon.b],
			"start": 6300.0,
			"end": 40000.0,
			"max_density": 0.25,
		},
	}


## What this machine draws of a course's light: dot-lighting's `painted()`, the family's profile
## for flat colours (the Compatibility renderer clips a sunlit pastel to white at Forward+'s numbers,
## and the grid that shows how far a jump is goes with it), with the sun's shadows kept on.
static func light_profile() -> DotLightProfile:
	# Over the hand-set numbers it replaced (the sun / 700, a fill of 0.62) it lowers the exposure,
	# grades, and trades ambient for a shadowless fill: a corridor's two walls differ in shade.
	var p := DotLightProfile.painted()
	# On in the browser too, unlike `web()`: a course is a few hundred boxes, and a trap's
	# shadow on the floor is how a runner sees where it is.
	p.sun_shadows = true
	return p


func kill_height() -> float:
	return float(doc.get("kill_height", -12.0))
