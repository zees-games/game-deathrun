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
	var sun := GSLightRig.apply(lighting, GSLightDocument.from_dictionary(light_document(theme)), light_profile())
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
static func light_profile() -> GSLightProfile:
	# Over the hand-set numbers it replaced (the sun / 700, a fill of 0.62) it lowers the exposure,
	# grades, and trades ambient for a shadowless fill: a corridor's two walls differ in shade.
	var p := GSLightProfile.painted()
	# On in the browser too, unlike `web()`: a course is a few hundred boxes, and a trap's
	# shadow on the floor is how a runner sees where it is.
	p.sun_shadows = true
	return p


func kill_height() -> float:
	return float(doc.get("kill_height", -12.0))


## Draws one box-shaped thing as what it looks like. Meshes only; what it does is decided by
## the box, never by the drawing.
func _draw_look(parent: Node3D, size: Vector3, look: String, face: String, tint: Color,
		moving: bool, role: DrTextures.Role = DrTextures.Role.HAZARD) -> void:
	match look:
		"none":
			pass
		"spikes":
			_draw_spikes(parent, size, face, tint, moving)
		"blade":
			var disc := MeshInstance3D.new()
			disc.name = "Blade"
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = maxf(size.x, size.z) * 0.5
			cylinder.bottom_radius = cylinder.top_radius
			cylinder.height = size.y
			cylinder.radial_segments = 40
			disc.mesh = cylinder
			disc.material_override = _metal(tint)
			parent.add_child(disc)

			# Teeth, so a spinning disc reads as spinning.
			for tooth in range(8):
				var spike := MeshInstance3D.new()
				var box := BoxMesh.new()
				box.size = Vector3(cylinder.top_radius * 0.35, size.y * 1.02, cylinder.top_radius * 0.12)
				spike.mesh = box
				var angle := TAU * float(tooth) / 8.0
				spike.position = Vector3(cos(angle), 0.0, sin(angle)) * cylinder.top_radius
				spike.rotation = Vector3(0.0, -angle, 0.0)
				spike.material_override = DrTextures.surface(DrTextures.Role.HAZARD, true)
				disc.add_child(spike)
		"fire":
			var flame := MeshInstance3D.new()
			flame.name = "Flame"
			var box := BoxMesh.new()
			box.size = size
			flame.mesh = box
			flame.material_override = _glow(tint if tint != Color.WHITE else Color(1.0, 0.45, 0.08), 0.62)
			parent.add_child(flame)
		"wind":
			# Streaks along the push, not a solid-looking box: a runner reads a fan from a jump
			# away, and a block of glass reads as a wall.
			var air := MeshInstance3D.new()
			air.name = "Wind"
			var box := BoxMesh.new()
			box.size = size
			air.mesh = box
			air.material_override = _glow(tint if tint != Color.WHITE else Color(0.7, 0.9, 1.0), 0.18, 0.4)
			parent.add_child(air)
		"liquid":
			var pool := MeshInstance3D.new()
			pool.name = "Liquid"
			var box := BoxMesh.new()
			box.size = size
			pool.mesh = box
			pool.material_override = _glow(tint if tint != Color.WHITE else Color(0.25, 0.55, 0.85), 0.78, 0.15)
			parent.add_child(pool)
		_:
			var _box := _add_box(parent, size, DrTextures.tinted(role, tint, moving), false)


## A bed of spikes filling [param size], pointing along [param face]: cones on a hazard-red
## base plate. The cones are the whole tell; a runner reads them from a jump away where a
## colour alone does not.
func _draw_spikes(parent: Node3D, size: Vector3, face: String, tint: Color, moving: bool) -> void:
	# Which way the points go, and the box's extent along it and across it.
	var up := Vector3.UP
	match face:
		"down":
			up = Vector3.DOWN
		"forward":
			up = Vector3.FORWARD
		"back":
			up = Vector3.BACK
		"left":
			up = Vector3.LEFT
		"right":
			up = Vector3.RIGHT

	var along := absf(up.dot(size))
	var across_a := Vector3.RIGHT if absf(up.x) < 0.5 else Vector3.FORWARD
	var across_b := up.cross(across_a).normalized()
	var width_a := absf(across_a.dot(size))
	var width_b := absf(across_b.dot(size))

	# The plate the points stand on: a fifth of the depth, at the back.
	var plate_depth := along * 0.18
	var plate := MeshInstance3D.new()
	var plate_box := BoxMesh.new()
	plate_box.size = (size - up.abs() * (along - plate_depth))
	plate.mesh = plate_box
	plate.position = -up * (along * 0.5 - plate_depth * 0.5)
	# The hazard red, not the walls' colour: the walls are a pale lavender, and a spike wall's
	# plate in the walls' colour was a spike wall that vanished into the wall it slides out of.
	plate.material_override = DrTextures.surface(DrTextures.Role.HAZARD, moving)
	parent.add_child(plate)

	var pitch := clampf(minf(width_a, width_b) / 2.0, 0.35, 0.6)
	var count_a := maxi(int(width_a / pitch), 1)
	var count_b := maxi(int(width_b / pitch), 1)
	var radius := pitch * 0.42
	var height := along - plate_depth
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = radius
	cone.height = height
	cone.radial_segments = 8
	var material := _metal(tint)
	# The arc from up to the face, except straight down, where the arc has no one axis.
	var turn := Basis(Vector3.RIGHT, PI) if up.y < -0.99 else Basis(Quaternion(Vector3.UP, up))

	for a in range(count_a):
		for b in range(count_b):
			var spike := MeshInstance3D.new()
			spike.mesh = cone
			spike.material_override = material
			var offset := across_a * ((float(a) + 0.5) / float(count_a) - 0.5) * width_a \
				+ across_b * ((float(b) + 0.5) / float(count_b) - 0.5) * width_b
			spike.transform = Transform3D(turn, offset + up * (plate_depth * 0.5))
			parent.add_child(spike)

	# Very many points is very many draw calls; a field of fifty is past where they read as
	# separate points anyway.
	if count_a * count_b > 400:
		GSLog.debug("dr.course", "a large bed of spikes", {"points": count_a * count_b})


static func _metal(tint: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.78, 0.80, 0.84) * (tint if tint != Color.WHITE else Color(1, 1, 1))
	material.metallic = 0.7
	material.roughness = 0.35
	return material


## Something drawn as light rather than surface: fire, a pool. Translucent ON PURPOSE and the
## only material here that is: alpha is sorted per surface, not per pixel, which suits a pool
## and would draw a floor through itself (docs/gdscript-hazards.md).
static func _glow(colour: Color, alpha: float, emission: float = 0.9) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(colour.r, colour.g, colour.b, alpha)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.emission_enabled = emission > 0.0
	material.emission = colour
	material.emission_energy_multiplier = emission
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material
