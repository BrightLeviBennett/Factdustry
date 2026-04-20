extends Node3D

# ============================================================
# PLANET_SELECT.GD - Solar System + Planet Sector Selection
# ============================================================
# All planets orbit a central sun in one 3D scene.
# Two camera modes:
#   SOLAR_SYSTEM — zoomed out, see all planets, click one to zoom in
#   PLANET       — zoomed in on one planet, see/click geodesic sectors
#
# The camera tweens smoothly between views.
#
# SCENE TREE (built in _ready):
#   PlanetSelect (Node3D)
#   ├── WorldEnvironment
#   ├── Sun (OmniLight3D + glowing sphere)
#   ├── Planets (Node3D)
#   │   └── PlanetNode (Node3D per planet, positioned in orbit)
#   │       ├── MeshInstance3D (planet sphere + shader)
#   │       ├── MeshInstance3D (atmosphere)
#   │       ├── Label3D (planet name)
#   │       ├── StaticBody3D (click detection for planet)
#   │       └── Sectors (Node3D, only shown when zoomed in)
#   │           ├── MeshInstance3D (geodesic cell fills)
#   │           ├── MeshInstance3D (hover outline)
#   │           └── MeshInstance3D (connection arcs)
#   ├── OrbitRings (MeshInstance3D, orbit path lines)
#   ├── CameraPivot → Camera3D
#   └── HUD (CanvasLayer)
# ============================================================


# =========================
# CONSTANTS
# =========================

const GAME_SCENE_PATH := "res://main/Main.tscn"
const ORBIT_SENSITIVITY := 0.005
const ZOOM_SPEED := 0.5
const AUTO_ROTATE_SPEED := 0.02
const MARKER_RADIUS := 0.25
const MARKER_HEIGHT := 0.05
const MARKER_LIFT := 1.02
const OUTLINE_THICKNESS := 0.05  # Width of sector outline edges
const HOVER_THICKNESS := 0.05    # Width of hover outline edges

## Camera limits for planet view
const PLANET_ZOOM_MIN := 4.5
const PLANET_ZOOM_MAX := 14.0

## Cell colors
const COLOR_EMPTY     = Color(0, 0, 0, 0)           # invisible
const COLOR_LOCKED    = Color(0, 0, 0, 0)            # invisible
const COLOR_UNLOCKED  = Color(0.7, 0.85, 0.7, 0.55)  # visible white-green
const COLOR_CAPTURED  = Color(1.0, 0.85, 0.0, 0.65)  # visible gold
const COLOR_HOVER     = Color(0.4, 0.6, 0.4, 0.3)    # hover highlight for any cell
const EDGE_COLOR      = Color(0.3, 0.5, 0.3, 0.4)    # grid edge color

# =========================
# STATE
# =========================

var current_planet: PlanetData = null
var selected_sector: SectorData = null
var hovered_sector: SectorData = null
var hovered_planet: PlanetData = null
var planet_tabs_hbox: HBoxContainer

var camera_yaw := 0.0
var camera_pitch := 0.5
var camera_distance := 35.0
## Where the camera pivot is focused (origin for solar, planet pos for planet)
var camera_focus := Vector3.ZERO
var is_dragging := false
var _press_pos := Vector2(-1, -1)

## Maps StaticBody3D → PlanetData (for planet clicking in solar view)
var planet_bodies: Dictionary = {}
## Maps PlanetData.id → Node3D (the planet's root node)
var planet_nodes: Dictionary = {}
## Maps PlanetData.id → Node3D (the Sectors container per planet)
var sector_containers: Dictionary = {}
## Maps StaticBody3D → PlanetData for planet click detection
var body_to_planet: Dictionary = {}
## Tracks which planets have had sector markers built (lazy loading)
var _sectors_built: Dictionary = {}  # planet_id → true

## Geodesic grid state
var _dual_mesh_cache: Dictionary = {}      # planet_id -> DualMeshResult
var _cell_to_sector: Dictionary = {}       # planet_id -> Dictionary{int -> SectorData}
var _sector_to_cell: Dictionary = {}       # planet_id -> Dictionary{StringName -> int}
var _outline_mesh_inst: Dictionary = {}    # planet_id -> MeshInstance3D (sector outlines)
var _hover_mesh_inst: Dictionary = {}      # planet_id -> MeshInstance3D (hover outline)
var _hovered_cell: int = -1
var _selected_cell: int = -1
var _prev_hovered_cell: int = -1


# =========================
# NODE REFERENCES
# =========================

var camera_pivot: Node3D
var camera: Camera3D
var planets_container: Node3D
var hud: CanvasLayer
var info_panel: PanelContainer
var launch_btn: Button

## Full-screen resource-requirement overlay shown when the player tries to
## launch into a sector they haven't played yet (or one whose core has been
## destroyed). Built lazily the first time it's needed.
var launch_overlay: ColorRect
var launch_overlay_panel: PanelContainer
var launch_overlay_title: Label
var launch_overlay_requirements: VBoxContainer
var launch_overlay_confirm: Button
var launch_overlay_cancel: Button
var launch_overlay_sector: Resource = null
var back_btn: Button
var sector_name_label: Label
var sector_desc_label: Label
var sector_stats_container: VBoxContainer
var tech_tree_ui: CanvasLayer

# =========================
# INITIALIZATION
# =========================

func _ready() -> void:
	_build_hud()

	# If planets are already loaded (sync), build immediately
	if Registry.planets_list.size() > 0:
		_build_3d_scene()
		_update_camera()
		_update_info_panel()
		# Defer sector building to next frame so the scene renders immediately
		call_deferred("_deferred_zoom_to_planet")
	else:
		# Planets are loading in background — wait for them
		_update_camera()
		_update_info_panel()
		Registry.all_resources_loaded.connect(_on_registry_loaded, CONNECT_ONE_SHOT)


func _deferred_zoom_to_planet() -> void:
	var target = _default_planet()
	if target != null:
		_zoom_to_planet(target)
		_update_planet_tab_highlight()


func _on_registry_loaded() -> void:
	_build_3d_scene()
	_update_camera()
	_update_info_panel()
	var target = _default_planet()
	if target != null:
		_zoom_to_planet(target)
		_update_planet_tab_highlight()


## Returns the planet that should be focused when the screen opens.
## Prefers Tarkon (the campaign starting planet) and falls back to the first
## loaded planet if Tarkon isn't available for some reason.
func _default_planet() -> PlanetData:
	var tarkon = Registry.get_planet(&"Tarkon") if Registry.has_method("get_planet") else null
	if tarkon == null:
		tarkon = Registry.planets.get(&"Tarkon", null)
	if tarkon != null:
		return tarkon
	if Registry.planets_list.size() > 0:
		return Registry.planets_list[0]
	return null


# =========================
# 3D SCENE
# =========================

func _build_3d_scene() -> void:
	# --- Environment ---
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.005, 0.005, 0.015)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.3, 0.35)
	env.ambient_light_energy = 0.8
	env.glow_enabled = false

	var world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	# --- Star field background ---
	_build_starfield()

	# --- Sun ---
	_build_sun()

	# --- Camera ---
	camera_pivot = Node3D.new()
	camera_pivot.name = "CameraPivot"
	add_child(camera_pivot)

	camera = Camera3D.new()
	camera.fov = 50.0
	camera.near = 0.1
	camera.far = 200.0
	camera_pivot.add_child(camera)

	# --- Planets Container ---
	planets_container = Node3D.new()
	planets_container.name = "Planets"
	add_child(planets_container)

	# Build each planet — parents first so moons can find them.
	for planet in Registry.planets_list:
		if planet.parent_planet_id == &"":
			_build_planet(planet)
	for planet in Registry.planets_list:
		if planet.parent_planet_id != &"":
			_build_planet(planet)

	# Draw orbit rings
	_draw_orbit_rings()


func _build_sun() -> void:
	# OmniLight radiates in all directions from the center
	var light = OmniLight3D.new()
	light.light_energy = 3.0
	light.light_color = Color(1.0, 0.95, 0.8)
	light.omni_range = 100.0
	light.omni_attenuation = 0.5
	light.shadow_enabled = false
	add_child(light)

	# Glowing sun sphere
	var sphere = SphereMesh.new()
	sphere.radius = 2.0
	sphere.height = 4.0
	sphere.radial_segments = 16
	sphere.rings = 8

	var sun_mesh = MeshInstance3D.new()
	sun_mesh.mesh = sphere
	sun_mesh.name = "SunMesh"

	# Unshaded + emission so the sun always looks bright
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.9, 0.6)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.85, 0.5)
	mat.emission_energy_multiplier = 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sun_mesh.material_override = mat

	add_child(sun_mesh)


## Builds a star field — thousands of tiny billboard quads scattered on a
## large sphere around the camera. Mindustry-style background flicker.
func _build_starfield() -> void:
	var STAR_COUNT := 1500
	var STAR_RADIUS := 150.0  # Far enough away to feel infinite, inside camera.far

	# Use a simple quad mesh — billboarded so each star always faces the camera.
	var quad := QuadMesh.new()
	quad.size = Vector2(0.6, 0.6)

	# Generate a small radial-gradient texture so each billboard renders as a
	# soft round dot instead of a flat square. 16x16 is plenty.
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	var center := Vector2(7.5, 7.5)
	for px in range(16):
		for py in range(16):
			var d: float = Vector2(px, py).distance_to(center) / 7.5
			var a: float = clampf(1.0 - d, 0.0, 1.0)
			# Smooth falloff so the edge feathers nicely
			a = a * a
			img.set_pixel(px, py, Color(1, 1, 1, a))
	var star_tex := ImageTexture.create_from_image(img)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.disable_receive_shadows = true
	mat.albedo_color = Color(1, 1, 1, 1)
	mat.albedo_texture = star_tex
	mat.vertex_color_use_as_albedo = true
	quad.material = mat

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = quad
	multimesh.instance_count = STAR_COUNT

	# Deterministic-ish random spread (different every run is fine here)
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	for i in range(STAR_COUNT):
		# Uniformly distributed point on a sphere
		var u: float = rng.randf()
		var v: float = rng.randf()
		var theta: float = TAU * u
		var phi: float = acos(2.0 * v - 1.0)
		var x: float = STAR_RADIUS * sin(phi) * cos(theta)
		var y: float = STAR_RADIUS * sin(phi) * sin(theta)
		var z: float = STAR_RADIUS * cos(phi)

		var t := Transform3D()
		t.origin = Vector3(x, y, z)
		# Random scale variation for star "size" diversity
		var scale_jitter: float = rng.randf_range(0.4, 1.6)
		t.basis = t.basis.scaled(Vector3.ONE * scale_jitter)
		multimesh.set_instance_transform(i, t)

		# Color variation: mostly white, occasional warm/cool tints, varying brightness.
		var brightness: float = rng.randf_range(0.4, 1.0)
		var tint: float = rng.randf()
		var c: Color
		if tint < 0.7:
			c = Color(brightness, brightness, brightness, 1.0)            # white
		elif tint < 0.85:
			c = Color(brightness, brightness * 0.85, brightness * 0.6, 1.0)  # warm yellow
		else:
			c = Color(brightness * 0.7, brightness * 0.8, brightness, 1.0)   # cool blue
		multimesh.set_instance_color(i, c)

	var mm_inst := MultiMeshInstance3D.new()
	mm_inst.name = "Starfield"
	mm_inst.multimesh = multimesh
	add_child(mm_inst)


## Builds one planet: mesh, atmosphere, click body, sector container.
func _build_planet(planet: PlanetData) -> void:
	var planet_node = Node3D.new()
	planet_node.name = "Planet_" + str(planet.id)
	planet_node.position = planet.get_orbit_position()
	# Moons: parent the node to their parent planet so the moon's local
	# orbit_distance / orbit_angle become an offset from the parent.
	if planet.parent_planet_id != &"" and planet_nodes.has(planet.parent_planet_id):
		planet_nodes[planet.parent_planet_id].add_child(planet_node)
	else:
		planets_container.add_child(planet_node)
	planet_nodes[planet.id] = planet_node

	# --- Planet Sphere ---
	var sphere = SphereMesh.new()
	sphere.radius = planet.mesh_radius
	sphere.height = planet.mesh_radius * 2.0
	sphere.radial_segments = 32
	sphere.rings = 16

	var mesh_inst = MeshInstance3D.new()
	mesh_inst.mesh = sphere
	mesh_inst.material_override = _make_planet_material(planet)
	planet_node.add_child(mesh_inst)

	# --- Atmosphere ---
	var atmo_sphere = SphereMesh.new()
	atmo_sphere.radius = planet.mesh_radius * 1.08
	atmo_sphere.height = planet.mesh_radius * 2.16
	atmo_sphere.radial_segments = 24
	atmo_sphere.rings = 12

	var atmo = MeshInstance3D.new()
	atmo.mesh = atmo_sphere
	atmo.material_override = _make_atmosphere_material(planet)
	planet_node.add_child(atmo)

	# --- Click body (collision layer 4 = planets) ---
	var body = StaticBody3D.new()
	body.collision_layer = 4
	body.collision_mask = 0
	var col_shape = CollisionShape3D.new()
	var sphere_shape = SphereShape3D.new()
	sphere_shape.radius = planet.mesh_radius
	col_shape.shape = sphere_shape
	body.add_child(col_shape)
	planet_node.add_child(body)
	body_to_planet[body] = planet

	# A second, slightly larger click-sphere makes picking the planet easier
	# at distance without changing the visible mesh. Added to the same body.
	var shape = SphereShape3D.new()
	shape.radius = planet.mesh_radius * 1.2
	var col = CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)

	planet_bodies[body] = planet

	# --- Sectors Container (built on-demand when planet is viewed) ---
	var sec_cont = Node3D.new()
	sec_cont.name = "Sectors"
	sec_cont.visible = false
	planet_node.add_child(sec_cont)
	sector_containers[planet.id] = sec_cont
	# Sector markers are built lazily in _zoom_to_planet()


## Draws thin orbit ring circles around the sun for each planet.
func _draw_orbit_rings() -> void:
	var im = ImmediateMesh.new()
	var ring_node = MeshInstance3D.new()
	ring_node.mesh = im
	ring_node.name = "OrbitRings"

	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.2, 0.3, 0.4)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_node.material_override = mat

	var segments = 32
	for planet in Registry.planets_list:
		var dist = planet.orbit_distance
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for i in range(segments + 1):
			var angle = TAU * float(i) / float(segments)
			var x = dist * sin(angle)
			var z = dist * cos(angle)
			im.surface_add_vertex(Vector3(x, 0, z))
		im.surface_end()

	add_child(ring_node)


# =========================
# MATERIALS
# =========================

func _make_planet_material(planet: PlanetData) -> ShaderMaterial:
	var shader = Shader.new()
	shader.code = "shader_type spatial;\nuniform sampler2D surface_tex : source_color, filter_linear, repeat_enable;\nuniform vec4 grid_color : source_color = vec4(0.2, 0.5, 0.3, 1.0);\nuniform float grid_density = 14.0;\nuniform float grid_opacity = 0.4;\nuniform vec4 tint_color : source_color = vec4(1.0);\nvarying vec3 local_pos;\nvoid vertex() { local_pos = VERTEX; }\nvoid fragment() {\n\tvec3 tex_col = texture(surface_tex, UV).rgb * tint_color.rgb;\n\tvec3 n = normalize(local_pos);\n\tfloat lat = asin(n.y);\n\tfloat lon = atan(n.x, n.z);\n\tfloat lat_l = abs(fract(lat * grid_density / 3.14159) - 0.5) * 2.0;\n\tfloat lon_l = abs(fract(lon * grid_density / 6.28318) - 0.5) * 2.0;\n\tfloat line = smoothstep(0.02, 0.06, min(lat_l, lon_l));\n\tALBEDO = mix(grid_color.rgb, tex_col, line);\n\tEMISSION = grid_color.rgb * (1.0 - line) * grid_opacity;\n}\n"

	var mat = ShaderMaterial.new()
	mat.shader = shader

	var tex: Texture2D = planet.surface_texture if planet.surface_texture else _gen_texture(planet)
	mat.set_shader_parameter("surface_tex", tex)
	mat.set_shader_parameter("grid_color", planet.grid_color)
	mat.set_shader_parameter("grid_density", planet.grid_density)
	mat.set_shader_parameter("grid_opacity", 0.4)
	mat.set_shader_parameter("tint_color", planet.surface_color * 3.0)
	return mat


func _gen_texture(planet: PlanetData) -> NoiseTexture2D:
	var noise = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = planet.texture_frequency
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.seed = planet.texture_seed

	var nt = NoiseTexture2D.new()
	nt.noise = noise
	nt.width = 256
	nt.height = 128
	nt.seamless = true
	nt.normalize = true
	# NoiseTexture2D generates asynchronously in Godot —
	# it returns a placeholder immediately and fills in later

	var grad = Gradient.new()
	grad.set_offset(0, 0.0)
	grad.set_color(0, planet.surface_color)
	grad.add_point(0.4, planet.surface_color.lerp(planet.grid_color, 0.3))
	grad.add_point(0.7, planet.grid_color.darkened(0.3))
	grad.add_point(1.0, planet.grid_color.darkened(0.1))
	nt.color_ramp = grad
	return nt


func _make_atmosphere_material(planet: PlanetData) -> ShaderMaterial:
	var shader = Shader.new()
	shader.code = "shader_type spatial;\nrender_mode unshaded, blend_add, cull_front;\nuniform vec4 atmo_color : source_color = vec4(0.3, 0.7, 1.0, 0.3);\nvoid fragment() {\n\tfloat f = pow(1.0 - abs(dot(NORMAL, VIEW)), 3.0);\n\tALBEDO = atmo_color.rgb;\n\tALPHA = f * atmo_color.a;\n}\n"
	var mat = ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("atmo_color", planet.atmosphere_color)
	return mat


func _make_outline_mat(color: Color) -> StandardMaterial3D:
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.8
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _surface_transform(pos: Vector3) -> Transform3D:
	var n = pos.normalized()
	var ref = Vector3.FORWARD if abs(n.y) > 0.99 else Vector3.UP
	var x = n.cross(ref).normalized()
	var z = x.cross(n).normalized()
	return Transform3D(Basis(x, n, z), pos)


# =========================
# GEODESIC GRID
# =========================

## Builds the geodesic dual-mesh grid for a planet, replacing the old hex markers.
func _build_geodesic_grid(planet: PlanetData, container: Node3D) -> void:
	var r: float = planet.mesh_radius * MARKER_LIFT

	# 1. Generate icosphere and dual mesh
	var ico = Icosphere.generate(planet.subdivision_level, r)
	var dual = Icosphere.generate_dual_mesh(ico, r)

	# 2. Cache the dual mesh
	_dual_mesh_cache[planet.id] = dual

	# 3. Assign sectors to cells
	_assign_sectors_to_cells(planet)

	# 4. Build sector outline mesh (colored edges for unlocked/captured sectors)
	var outline_inst := MeshInstance3D.new()
	outline_inst.name = "SectorOutlines"
	outline_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	container.add_child(outline_inst)
	_outline_mesh_inst[planet.id] = outline_inst
	_rebuild_outline_mesh(planet.id)

	# 5. Build hover outline mesh (initially empty)
	var hover_inst := MeshInstance3D.new()
	hover_inst.name = "HoverOutline"
	hover_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	container.add_child(hover_inst)
	_hover_mesh_inst[planet.id] = hover_inst

	var sectors = _get_planet_sectors(planet.id)
	print("PlanetSelect: %d sectors on %d-cell geodesic grid for '%s'" % [sectors.size(), dual.cell_centers.size(), planet.id])



## Assigns each sector to its nearest cell in the dual mesh.
func _assign_sectors_to_cells(planet: PlanetData) -> void:
	var sectors = _get_planet_sectors(planet.id)
	var dual = _dual_mesh_cache[planet.id]
	var cell_map: Dictionary = {}
	var sec_map: Dictionary = {}
	var r: float = planet.mesh_radius * MARKER_LIFT

	for sector in sectors:
		var target: Vector3 = sector.get_surface_position(r, MARKER_RADIUS).normalized()
		var best_idx: int = -1
		var best_dot: float = -2.0
		for i in range(dual.cell_centers.size()):
			var d: float = target.dot(dual.cell_centers[i].normalized())
			if d > best_dot:
				best_dot = d
				best_idx = i
		if best_idx >= 0:
			cell_map[best_idx] = sector
			sec_map[sector.id] = best_idx

	_cell_to_sector[planet.id] = cell_map
	_sector_to_cell[planet.id] = sec_map


## Returns the fill color for a cell based on its sector state.
## Returns the outline color for a sector cell. Empty/locked = invisible.
func _get_cell_outline_color(planet_id: StringName, cell_idx: int) -> Color:
	var cell_map: Dictionary = _cell_to_sector.get(planet_id, {})
	if not cell_map.has(cell_idx):
		return COLOR_EMPTY
	var sector: SectorData = cell_map[cell_idx]
	# Sectors render as RESEARCHED in the tech tree as soon as they become
	# accessible, so "captured" vs "unlocked but not yet captured" has to be
	# distinguished by the hidden "-C-sector_id" marker instead of NodeState.
	if TechTree.is_sector_captured(sector.id):
		return COLOR_CAPTURED
	elif not TechTree.is_locked(sector.id):
		return COLOR_UNLOCKED
	return COLOR_LOCKED


## Rebuilds the outline mesh for all sector cells based on current state.
## Edges are drawn as quads (two triangles) for configurable thickness.
func _rebuild_outline_mesh(planet_id: StringName) -> void:
	if not _outline_mesh_inst.has(planet_id):
		return
	var dual = _dual_mesh_cache.get(planet_id)
	if not dual:
		return

	var outline_inst: MeshInstance3D = _outline_mesh_inst[planet_id]
	var im := ImmediateMesh.new()
	var has_tris := false

	for i in range(dual.cell_polygons.size()):
		var color: Color = _get_cell_outline_color(planet_id, i)
		if color.a < 0.01:
			continue  # Skip invisible cells

		# Brighten selected cell
		if i == _selected_cell:
			color = color.lightened(0.2)
			color.a = min(color.a + 0.15, 1.0)

		var polygon: PackedVector3Array = dual.cell_polygons[i]
		var n_corners: int = polygon.size()
		if n_corners < 3:
			continue

		if not has_tris:
			im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
			has_tris = true

		_add_cell_outline(im, polygon, OUTLINE_THICKNESS, color)

	if has_tris:
		im.surface_end()

	outline_inst.mesh = im

	# Material for colored outlines
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(1, 1, 1)
	mat.emission_energy_multiplier = 0.6
	outline_inst.material_override = mat


## Adds the full outline for a cell polygon as quads with miter joints.
## Uses a single consistent normal (cell center) for all corners to avoid
## stretching artifacts from varying sphere normals across the polygon.
func _add_cell_outline(im: ImmediateMesh, polygon: PackedVector3Array, thickness: float, color: Color) -> void:
	var n: int = polygon.size()
	if n < 3:
		return

	var half_t := thickness * 0.5

	# Use cell center normal for all corners (consistent tangent plane)
	var center := Vector3.ZERO
	for c in polygon:
		center += c
	center /= float(n)
	var cell_normal: Vector3 = center.normalized()
	var nudge: Vector3 = cell_normal * 0.005

	# Precompute outer/inner points using miter joints
	var outer := PackedVector3Array()
	var inner := PackedVector3Array()
	outer.resize(n)
	inner.resize(n)

	for i in range(n):
		var prev_c: Vector3 = polygon[(i - 1 + n) % n]
		var curr_c: Vector3 = polygon[i]
		var next_c: Vector3 = polygon[(i + 1) % n]

		# Project edge directions onto the cell tangent plane
		var dir_in: Vector3 = (curr_c - prev_c)
		dir_in = (dir_in - cell_normal * dir_in.dot(cell_normal)).normalized()
		var dir_out: Vector3 = (next_c - curr_c)
		dir_out = (dir_out - cell_normal * dir_out.dot(cell_normal)).normalized()

		# Perpendiculars (outward from polygon) in the tangent plane
		var perp_in: Vector3 = dir_in.cross(cell_normal).normalized()
		var perp_out: Vector3 = dir_out.cross(cell_normal).normalized()

		# Miter direction: average of the two perpendiculars
		var miter_dir: Vector3 = (perp_in + perp_out).normalized()
		var cos_half: float = maxf(miter_dir.dot(perp_in), 0.5)
		var miter: Vector3 = miter_dir * (half_t / cos_half)

		outer[i] = curr_c + miter + nudge
		inner[i] = curr_c - miter + nudge

	# Emit quads between consecutive corner outer/inner pairs
	for i in range(n):
		var j: int = (i + 1) % n
		im.surface_set_color(color)
		im.surface_add_vertex(outer[i])
		im.surface_set_color(color)
		im.surface_add_vertex(inner[i])
		im.surface_set_color(color)
		im.surface_add_vertex(inner[j])
		im.surface_set_color(color)
		im.surface_add_vertex(outer[i])
		im.surface_set_color(color)
		im.surface_add_vertex(inner[j])
		im.surface_set_color(color)
		im.surface_add_vertex(outer[j])


## Returns a dictionary of {cell_index: distance} for all cells within `max_dist` hops.
func _get_cells_in_radius(planet_id: StringName, center_cell: int, max_dist: int) -> Dictionary:
	var dual = _dual_mesh_cache.get(planet_id)
	if not dual:
		return {}
	var result: Dictionary = {center_cell: 0}
	var queue: Array[int] = [center_cell]
	var head := 0
	while head < queue.size():
		var cell: int = queue[head]
		head += 1
		var dist: int = result[cell]
		if dist >= max_dist:
			continue
		var neighbors: PackedInt32Array = dual.cell_neighbor_indices[cell]
		for nb in neighbors:
			if not result.has(nb):
				result[nb] = dist + 1
				queue.append(nb)
	return result


## Creates or updates the hover outline for the hovered cell plus neighbors in a radius.
func _build_hover_outline(planet_id: StringName, cell_idx: int) -> void:
	if not _hover_mesh_inst.has(planet_id):
		return
	var hover_inst: MeshInstance3D = _hover_mesh_inst[planet_id]

	if cell_idx < 0:
		hover_inst.mesh = null
		return

	var dual = _dual_mesh_cache.get(planet_id)
	if not dual:
		hover_inst.mesh = null
		return

	# Get all cells within 3 hops
	var nearby: Dictionary = _get_cells_in_radius(planet_id, cell_idx, 3)

	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	for ci in nearby:
		var dist: int = nearby[ci]
		var polygon: PackedVector3Array = dual.cell_polygons[ci]
		if polygon.size() < 3:
			continue
		# Fade opacity based on distance: center = bright, edges = faint
		var alpha: float = lerpf(0.6, 0.08, float(dist) / 3.0)
		var hover_color := Color(0.8, 1.0, 0.8, alpha)
		var t: float = lerpf(HOVER_THICKNESS, HOVER_THICKNESS * 0.6, float(dist) / 3.0)
		_add_cell_outline(im, polygon, t, hover_color)

	im.surface_end()

	hover_inst.mesh = im

	# Material for the hover outlines
	if not hover_inst.material_override:
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.emission_enabled = true
		mat.emission = Color(0.6, 0.9, 0.6)
		mat.emission_energy_multiplier = 1.2
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		hover_inst.material_override = mat


## Draws arc lines between prerequisite sectors on a planet using cell centers.
func _draw_planet_connections(planet: PlanetData, container: Node3D) -> void:
	var sec_map: Dictionary = _sector_to_cell.get(planet.id, {})
	var dual = _dual_mesh_cache.get(planet.id)
	if not dual:
		return

	var im = ImmediateMesh.new()
	var conn_node = MeshInstance3D.new()
	conn_node.mesh = im
	conn_node.name = "Connections"

	var line_mat = StandardMaterial3D.new()
	line_mat.albedo_color = planet.grid_color.lightened(0.3)
	line_mat.emission_enabled = true
	line_mat.emission = planet.grid_color
	line_mat.emission_energy_multiplier = 0.6
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	conn_node.material_override = line_mat

	var sectors = _get_planet_sectors(planet.id)
	var sd: Dictionary = {}
	for s in sectors:
		sd[s.id] = s

	var r: float = planet.mesh_radius * MARKER_LIFT

	for sector in sectors:
		if not sec_map.has(sector.id):
			continue
		var to_cell: int = sec_map[sector.id]
		var to_pos: Vector3 = dual.cell_centers[to_cell]

		for req_id in sector.required_sectors:
			if not sd.has(req_id):
				continue
			if not sec_map.has(req_id):
				continue
			var from_cell: int = sec_map[req_id]
			var from_pos: Vector3 = dual.cell_centers[from_cell]

			im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
			for i in range(21):
				var t: float = float(i) / 20.0
				var point: Vector3 = from_pos.slerp(to_pos, t).normalized() * r
				im.surface_add_vertex(point)
			im.surface_end()

	container.add_child(conn_node)


# =========================
# VIEW MODE SWITCHING
# =========================

## Zooms to view a specific planet.
func _zoom_to_planet(planet: PlanetData) -> void:
	# Hide old planet's sectors
	if current_planet and sector_containers.has(current_planet.id):
		sector_containers[current_planet.id].visible = false

	current_planet = planet

	# Build geodesic grid on first visit (lazy)
	if not _sectors_built.has(planet.id) and sector_containers.has(planet.id):
		_build_geodesic_grid(planet, sector_containers[planet.id])
		_sectors_built[planet.id] = true

	# Show new planet's sectors
	if sector_containers.has(planet.id):
		sector_containers[planet.id].visible = true

	camera_focus = planet.get_orbit_position()
	camera_pitch = planet.camera_pitch
	camera_distance = planet.camera_distance
	camera_yaw = 0.0
	selected_sector = null
	hovered_sector = null
	_hovered_cell = -1
	_selected_cell = -1
	_update_camera()
	_update_info_panel()


# =========================
# CAMERA
# =========================

func _update_camera() -> void:
	if not camera_pivot:
		return
	camera_pitch = clamp(camera_pitch, -1.4, 1.4)
	camera_distance = clamp(camera_distance, PLANET_ZOOM_MIN, PLANET_ZOOM_MAX)

	camera_pivot.position = camera_focus
	camera_pivot.rotation = Vector3(camera_pitch, camera_yaw, 0)
	camera.position = Vector3(0, 0, camera_distance)


func _input(event: InputEvent) -> void:
	# Scroll zoom always works (even over UI panels)
	if event is InputEventMouseButton:
		var mb = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_distance -= ZOOM_SPEED
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance += ZOOM_SPEED
			_update_camera()
	# Trackpad pinch/pan gesture zoom
	if event is InputEventPanGesture:
		camera_distance += event.delta.y * ZOOM_SPEED * 0.3
		_update_camera()


func _unhandled_input(event: InputEvent) -> void:
	# Left-click and drag go through _unhandled_input so UI buttons
	# consume the event first (prevents deselecting sectors when
	# clicking the Launch button or other HUD elements).
	if event is InputEventMouseButton:
		var mb = event as InputEventMouseButton

		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press_pos = mb.position
				is_dragging = false
			else:
				if _press_pos.distance_to(mb.position) < 5.0:
					_handle_click()
				is_dragging = false
				_press_pos = Vector2(-1, -1)

	if event is InputEventMouseMotion:
		var mm = event as InputEventMouseMotion
		if _press_pos != Vector2(-1, -1) and not is_dragging:
			if _press_pos.distance_to(mm.position) > 4.0:
				is_dragging = true
		if is_dragging:
			camera_yaw -= mm.relative.x * ORBIT_SENSITIVITY
			camera_pitch -= mm.relative.y * ORBIT_SENSITIVITY
			_update_camera()


func _process(_delta: float) -> void:
	if not camera_pivot:
		return

	_update_camera()
	_update_hover()


# =========================
# INTERACTION
# =========================

## Math-based ray-sphere intersection. Returns hit point or null.
func _ray_sphere_intersect(origin: Vector3, dir: Vector3, center: Vector3, radius: float) -> Variant:
	var oc: Vector3 = origin - center
	var a: float = dir.dot(dir)
	var b: float = 2.0 * oc.dot(dir)
	var c: float = oc.dot(oc) - radius * radius
	var discriminant: float = b * b - 4.0 * a * c
	if discriminant < 0.0:
		return null
	var sqrt_disc: float = sqrt(discriminant)
	var t1: float = (-b - sqrt_disc) / (2.0 * a)
	var t2: float = (-b + sqrt_disc) / (2.0 * a)
	# Use the nearest positive intersection
	var t: float
	if t1 > 0.001:
		t = t1
	elif t2 > 0.001:
		t = t2
	else:
		return null
	return origin + dir * t


## Raycast from mouse to the planet's grid sphere surface.
func _raycast_planet_surface() -> Variant:
	if not current_planet or not camera:
		return null
	var mouse_pos = get_viewport().get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = camera.project_ray_normal(mouse_pos)
	var planet_node = planet_nodes.get(current_planet.id)
	if not planet_node:
		return null
	var planet_pos: Vector3 = planet_node.global_position
	var radius: float = current_planet.mesh_radius * MARKER_LIFT
	return _ray_sphere_intersect(from, dir, planet_pos, radius)


## Finds the nearest cell index to a world-space surface point.
func _find_nearest_cell(planet_id: StringName, surface_point: Vector3) -> int:
	var dual = _dual_mesh_cache.get(planet_id)
	if not dual:
		return -1

	# Convert to planet-local coordinates
	var planet_node = planet_nodes.get(planet_id)
	var local_point: Vector3
	if planet_node:
		local_point = (surface_point - planet_node.global_position).normalized()
	else:
		local_point = surface_point.normalized()

	var best_idx: int = -1
	var best_dot: float = -2.0
	for i in range(dual.cell_centers.size()):
		var d: float = local_point.dot(dual.cell_centers[i].normalized())
		if d > best_dot:
			best_dot = d
			best_idx = i
	return best_idx


func _update_hover() -> void:
	if not current_planet:
		return

	var result = _raycast_planet_surface()
	if result == null:
		if _hovered_cell != -1:
			_prev_hovered_cell = _hovered_cell
			_hovered_cell = -1
			hovered_sector = null
			_build_hover_outline(current_planet.id, -1)
			_rebuild_outline_mesh(current_planet.id)
		return

	var cell_idx: int = _find_nearest_cell(current_planet.id, result)
	if cell_idx == _hovered_cell:
		return  # No change

	_prev_hovered_cell = _hovered_cell
	_hovered_cell = cell_idx
	var cell_map: Dictionary = _cell_to_sector.get(current_planet.id, {})
	hovered_sector = cell_map.get(cell_idx)
	_build_hover_outline(current_planet.id, cell_idx)
	_rebuild_outline_mesh(current_planet.id)


func _handle_click() -> void:
	if _hovered_cell >= 0 and hovered_sector:
		if not TechTree.is_locked(hovered_sector.id):
			if selected_sector == hovered_sector:
				selected_sector = null
				_selected_cell = -1
			else:
				selected_sector = hovered_sector
				_selected_cell = _hovered_cell
		_rebuild_outline_mesh(current_planet.id)
		_update_info_panel()
		return

	if _hovered_cell < 0:
		# Check if a planet was clicked (physics raycast on layer 4)
		var mouse_pos = get_viewport().get_mouse_position()
		var from = camera.project_ray_origin(mouse_pos)
		var dir = camera.project_ray_normal(mouse_pos)
		var query = PhysicsRayQueryParameters3D.create(from, from + dir * 200.0)
		query.collision_mask = 4
		query.collide_with_bodies = true
		var space = get_world_3d().direct_space_state
		var result = space.intersect_ray(query)
		if result and result.has("collider") and body_to_planet.has(result["collider"]):
			var clicked_planet = body_to_planet[result["collider"]]
			if clicked_planet != current_planet:
				current_planet = clicked_planet
				_zoom_to_planet(clicked_planet)
				_update_planet_tab_highlight()
			return

	# Clicked on an empty cell or non-sector cell — deselect
	if selected_sector:
		selected_sector = null
		_selected_cell = -1
		_rebuild_outline_mesh(current_planet.id)
		_update_info_panel()


## Refreshes sector cell colors based on current tech tree state.
## Called when returning from a sector to update captures/unlocks without rebuilding.
func _update_sector_highlights() -> void:
	if not current_planet:
		return
	_rebuild_outline_mesh(current_planet.id)
	_update_info_panel()


# =========================
# HUD
# =========================

func _build_hud() -> void:
	hud = CanvasLayer.new()
	hud.layer = 10
	add_child(hud)
	_build_info_panel()
	_build_back_button()
	_build_planet_tabs()
	_build_tech_tree_button()

func _build_planet_tabs() -> void:
	# MarginContainer anchored to top-left
	var margin = MarginContainer.new()
	margin.anchor_left = 0.0
	margin.anchor_right = 0.0
	margin.offset_left = 20
	margin.offset_top = 20
	margin.offset_right = 400
	hud.add_child(margin)

	planet_tabs_hbox = HBoxContainer.new()
	planet_tabs_hbox.add_theme_constant_override("separation", 8)
	planet_tabs_hbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	margin.add_child(planet_tabs_hbox)

	for planet in Registry.planets_list:
		# Hide moons (planets with a parent) from the tab list — they're
		# selected by clicking them in 3D, not via a top-level tab.
		if planet.parent_planet_id != &"":
			continue
		var btn = Button.new()
		btn.custom_minimum_size = Vector2(120, 36)
		btn.add_theme_font_size_override("font_size", 15)
		btn.add_theme_stylebox_override("normal", _make_tab_style(Color(0.1, 0.15, 0.1, 0.8)))
		btn.add_theme_stylebox_override("hover", _make_tab_style(Color(0.15, 0.25, 0.15, 0.9)))
		btn.add_theme_color_override("font_color", planet.grid_color)
		btn.pressed.connect(_on_planet_tab_pressed.bind(planet))

		if planet.icon:
			var hbox = HBoxContainer.new()
			hbox.alignment = BoxContainer.ALIGNMENT_CENTER
			hbox.add_theme_constant_override("separation", 6)
			hbox.anchors_preset = Control.PRESET_FULL_RECT
			hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
			var tex_rect = TextureRect.new()
			tex_rect.texture = planet.icon
			tex_rect.expand_mode = TextureRect.EXPAND_FIT_HEIGHT_PROPORTIONAL
			tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tex_rect.custom_minimum_size = Vector2(24, 24)
			hbox.add_child(tex_rect)
			var label = Label.new()
			label.text = planet.display_name
			label.add_theme_font_size_override("font_size", 15)
			label.add_theme_color_override("font_color", planet.grid_color)
			hbox.add_child(label)
			btn.add_child(hbox)
		else:
			btn.text = planet.display_name

		planet_tabs_hbox.add_child(btn)

	_update_planet_tab_highlight()


func _on_planet_tab_pressed(planet: PlanetData) -> void:
	if current_planet == planet:
		return
	current_planet = planet
	_zoom_to_planet(planet)
	_update_planet_tab_highlight()


func _update_planet_tab_highlight() -> void:
	for i in planet_tabs_hbox.get_child_count():
		if i >= Registry.planets_list.size():
			break
		var btn = planet_tabs_hbox.get_child(i) as Button
		var planet = Registry.planets_list[i]
		if current_planet and planet.id == current_planet.id:
			btn.add_theme_stylebox_override("normal", _make_tab_style(planet.grid_color.darkened(0.5)))
		else:
			btn.add_theme_stylebox_override("normal", _make_tab_style(Color(0.1, 0.15, 0.1, 0.8)))

func _build_info_panel() -> void:
	info_panel = PanelContainer.new()
	# Bottom-center, compact
	info_panel.anchor_left = 0.5
	info_panel.anchor_right = 0.5
	info_panel.anchor_top = 1.0
	info_panel.anchor_bottom = 1.0
	info_panel.offset_left = -250
	info_panel.offset_right = 250
	info_panel.offset_top = -160
	info_panel.offset_bottom = -10
	info_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	info_panel.visible = false  # Hidden until a sector is selected

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.06, 0.04, 0.92)
	style.border_color = Color(0.15, 0.3, 0.15, 0.5)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	info_panel.add_theme_stylebox_override("panel", style)
	hud.add_child(info_panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	info_panel.add_child(vbox)

	# Top row: sector name + launch button
	var top_hbox = HBoxContainer.new()
	top_hbox.add_theme_constant_override("separation", 12)
	vbox.add_child(top_hbox)

	sector_name_label = Label.new()
	sector_name_label.add_theme_font_size_override("font_size", 18)
	sector_name_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.5))
	sector_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_hbox.add_child(sector_name_label)

	launch_btn = Button.new()
	launch_btn.text = "▶ LAUNCH"
	launch_btn.custom_minimum_size = Vector2(120, 36)
	launch_btn.add_theme_font_size_override("font_size", 15)
	var ls = StyleBoxFlat.new()
	ls.bg_color = Color(0.12, 0.35, 0.18, 0.9)
	ls.set_corner_radius_all(6)
	ls.content_margin_left = 12
	ls.content_margin_right = 12
	launch_btn.add_theme_stylebox_override("normal", ls)
	var lh = ls.duplicate()
	lh.bg_color = Color(0.18, 0.5, 0.25, 0.95)
	launch_btn.add_theme_stylebox_override("hover", lh)
	launch_btn.add_theme_color_override("font_color", Color(0.8, 1.0, 0.8))
	launch_btn.pressed.connect(_on_launch_pressed)
	launch_btn.visible = false
	top_hbox.add_child(launch_btn)

	# Description
	sector_desc_label = Label.new()
	sector_desc_label.add_theme_font_size_override("font_size", 12)
	sector_desc_label.add_theme_color_override("font_color", Color(0.55, 0.7, 0.55))
	sector_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(sector_desc_label)

	# Stats
	sector_stats_container = VBoxContainer.new()
	sector_stats_container.add_theme_constant_override("separation", 3)
	vbox.add_child(sector_stats_container)


func _build_back_button() -> void:
	var show_back = SaveManager.return_to_game or SaveManager.return_to_menu

	back_btn = Button.new()
	if SaveManager.return_to_game:
		back_btn.text = "← Back to Map"
	else:
		back_btn.text = "← Back to Menu"
	back_btn.anchor_top = 1.0
	back_btn.anchor_bottom = 1.0
	back_btn.offset_left = 20
	back_btn.offset_top = -60
	back_btn.offset_bottom = -20
	back_btn.custom_minimum_size = Vector2(160, 40)
	back_btn.add_theme_font_size_override("font_size", 15)
	back_btn.add_theme_stylebox_override("normal", _make_tab_style(Color(0.1, 0.1, 0.1, 0.7)))
	var hover_style = _make_tab_style(Color(0.2, 0.2, 0.25, 0.85))
	back_btn.add_theme_stylebox_override("hover", hover_style)
	back_btn.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	back_btn.pressed.connect(_on_back_pressed)
	back_btn.visible = show_back
	hud.add_child(back_btn)


func _build_tech_tree_button() -> void:
	var btn = Button.new()
	btn.text = "⬡ Tech Tree"
	btn.anchor_left = 1.0
	btn.anchor_right = 1.0
	btn.anchor_top = 1.0
	btn.anchor_bottom = 1.0
	btn.offset_left = -180
	btn.offset_top = -60
	btn.offset_right = -20
	btn.offset_bottom = -20
	btn.custom_minimum_size = Vector2(160, 40)
	btn.add_theme_font_size_override("font_size", 15)
	btn.add_theme_stylebox_override("normal", _make_tab_style(Color(0.1, 0.15, 0.2, 0.8)))
	btn.add_theme_stylebox_override("hover", _make_tab_style(Color(0.15, 0.25, 0.35, 0.9)))
	btn.add_theme_color_override("font_color", Color(0.3, 0.75, 1.0))
	btn.pressed.connect(_on_tech_tree_pressed)
	hud.add_child(btn)

	# Create the tech tree UI (CanvasLayer) as a child of this scene
	var script = load("res://main/tech_tree_ui.gd")
	tech_tree_ui = CanvasLayer.new()
	tech_tree_ui.set_script(script)
	tech_tree_ui.layer = 20
	add_child(tech_tree_ui)


func _on_tech_tree_pressed() -> void:
	if tech_tree_ui:
		tech_tree_ui._show_ui()


func _on_back_pressed() -> void:
	if SaveManager.return_to_game:
		SaveManager.return_to_game = false
		# Restore the sector that was being played from the autosave
		var sector_id: StringName = SaveManager.active_sector_id
		if sector_id != &"" and sector_id != &"_default":
			var autosave_path: String = SaveManager.SAVE_DIR + str(sector_id) + ".sector.json"
			if FileAccess.file_exists(autosave_path):
				SaveManager.pending_map_path = autosave_path
			else:
				# Fall back to base sector map
				var sector_data = Registry.get_sector(sector_id)
				if sector_data and sector_data.map_path != "":
					SaveManager.pending_map_path = sector_data.map_path
			SaveManager.pending_sector_id = sector_id
		get_tree().change_scene_to_file(GAME_SCENE_PATH)
	else:
		SaveManager.return_to_menu = false
		get_tree().change_scene_to_file("res://main/MainMenu.tscn")


func _update_info_panel() -> void:
	# Only show for clicked (selected) sectors, not hovered
	var sector = selected_sector
	if not sector:
		info_panel.visible = false
		return
	# Don't show details for locked sectors
	if TechTree.is_locked(sector.id):
		info_panel.visible = false
		return

	info_panel.visible = true
	sector_name_label.text = sector.display_name
	sector_desc_label.text = sector.description
	_clear_stats()

	if sector.available_resources.size() > 0:
		# Icons instead of names — names on hover via tooltip.
		_add_stat_icons("Resources", sector.available_resources)

	if sector.waves > 0:
		_add_stat("Waves", str(sector.waves))

	if sector.unlocks.size() > 0:
		var unlock_names: PackedStringArray = []
		for uid in sector.unlocks:
			var node_data = TechTree.get_node_data(StringName(uid))
			unlock_names.append(node_data["name"] if node_data else str(uid))
		_add_stat_colored("Unlocks", ", ".join(unlock_names), Color(0.95, 0.82, 0.2))

	# Only show launch for unlocked/researched sectors
	if selected_sector != null and not TechTree.is_locked(selected_sector.id):
		launch_btn.visible = true
		match _launch_state(selected_sector):
			"LAUNCH", "LAUNCH_FREE":
				launch_btn.text = "▶ LAUNCH"
			"CONTINUE":
				launch_btn.text = "▶ CONTINUE"
			"PLAY":
				launch_btn.text = "▶ PLAY"
	else:
		launch_btn.visible = false


## Returns the semantic state of the launch button for a given sector:
##   "LAUNCH_FREE" — starting_grounds, no autosave yet. First launch is
##                   always free; subsequent launches fall through to the
##                   usual CONTINUE/PLAY rules.
##   "LAUNCH"      — any other sector with no autosave (fresh / abandoned /
##                   core destroyed). Shows the resource requirement overlay.
##   "CONTINUE"    — has autosave and either not yet captured OR still the
##                   active sector (you were just playing it).
##   "PLAY"        — has autosave, captured, and not the active sector
##                   (revisit).
func _launch_state(sector) -> String:
	if sector == null:
		return "LAUNCH"
	var save_path: String = SaveManager.SAVE_DIR + str(sector.id) + ".sector.json"
	var has_save: bool = FileAccess.file_exists(save_path)
	if not has_save:
		# First-ever launch: starting_grounds is free; anything else needs
		# the resource stockpile from the sector you're launching from.
		if StringName(sector.id) == &"starting_grounds":
			return "LAUNCH_FREE"
		return "LAUNCH"
	var captured: bool = TechTree.is_sector_captured(sector.id)
	var is_active: bool = SaveManager.active_sector_id == sector.id
	if is_active:
		return "CONTINUE"
	if not captured:
		return "CONTINUE"
	return "PLAY"


func _clear_stats() -> void:
	for c in sector_stats_container.get_children():
		c.queue_free()

func _add_stat(l: String, v: String) -> void:
	_add_stat_colored(l, v, Color(0.8, 0.95, 0.8))

func _add_stat_colored(l: String, v: String, vc: Color) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var lbl = Label.new()
	lbl.text = l + (":" if l != "" else "")
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.45, 0.6, 0.45))
	lbl.custom_minimum_size.x = 90
	hbox.add_child(lbl)
	var val = Label.new()
	val.text = v
	val.add_theme_font_size_override("font_size", 13)
	val.add_theme_color_override("font_color", vc)
	hbox.add_child(val)
	sector_stats_container.add_child(hbox)


## Stat row whose value is a sequence of item icons instead of a comma-
## separated name list. Used for "Resources" so the sector card reads at a
## glance — hovering an icon still surfaces the item's display name.
func _add_stat_icons(l: String, item_ids: Array) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var lbl = Label.new()
	lbl.text = l + (":" if l != "" else "")
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.45, 0.6, 0.45))
	lbl.custom_minimum_size.x = 90
	hbox.add_child(lbl)
	var icons_row = HBoxContainer.new()
	icons_row.add_theme_constant_override("separation", 4)
	for item_id in item_ids:
		var item = Registry.get_item_or_fluid(StringName(item_id))
		var icon_rect = TextureRect.new()
		icon_rect.custom_minimum_size = Vector2(20, 20)
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		if item and item.icon:
			icon_rect.texture = item.icon
		icon_rect.tooltip_text = item.display_name if item else str(item_id)
		icons_row.add_child(icon_rect)
	hbox.add_child(icons_row)
	sector_stats_container.add_child(hbox)

func _make_tab_style(c: Color) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(6)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s


# =========================
# CALLBACKS
# =========================

func _on_launch_pressed() -> void:
	if not selected_sector:
		return
	# LAUNCH state gates on resources from the source sector; everything
	# else (CONTINUE / PLAY / starting_grounds) skips the overlay and loads
	# straight into the sector.
	if _launch_state(selected_sector) == "LAUNCH":
		_open_launch_overlay(selected_sector)
		return
	_do_launch(selected_sector)


## Actually changes scene into the selected sector, handling autosave vs
## fresh-map loading. Extracted so the launch overlay can call it after the
## player confirms the resource cost.
func _do_launch(sector) -> void:
	SaveManager.pending_sector_id = sector.id
	var autosave_path: String = SaveManager.SAVE_DIR + str(sector.id) + ".sector.json"
	if FileAccess.file_exists(autosave_path):
		SaveManager.pending_map_path = autosave_path
	elif sector.map_path != "":
		SaveManager.pending_map_path = sector.map_path
	else:
		SaveManager.pending_map_path = ""
	get_tree().change_scene_to_file(GAME_SCENE_PATH)


# =========================
# LAUNCH RESOURCE OVERLAY
# =========================

## Hardcoded cost to bootstrap a new sector. Pulled from core_shard's
## build_cost so designers can tweak it in one place.
func _get_launch_cost() -> Dictionary:
	var core_data = Registry.get_block(&"core_shard")
	if core_data == null:
		return {}
	return core_data.build_cost


## Returns the per-sector resource storage we should charge for a launch.
## Keyed by the "mat_*" runtime id the rest of the game uses.
func _get_source_resources() -> Dictionary:
	var src_id: StringName = SaveManager.active_sector_id
	if src_id == &"" or src_id == &"_default":
		return {}
	if not SaveManager.sector_resources.has(src_id):
		return {}
	return SaveManager.sector_resources[src_id]


## Converts a short build-cost key ("copper") to the runtime item key
## ("mat_copper"), which is what per-sector resource dicts are keyed by.
func _resolve_cost_key(short_id: String) -> StringName:
	if short_id.begins_with("mat_"):
		return StringName(short_id)
	return StringName("mat_" + short_id)


func _build_launch_overlay() -> void:
	if launch_overlay != null:
		return
	# Full-screen dim background blocks clicks to the planet behind it.
	launch_overlay = ColorRect.new()
	launch_overlay.color = Color(0, 0, 0, 0.6)
	launch_overlay.anchor_left = 0.0
	launch_overlay.anchor_top = 0.0
	launch_overlay.anchor_right = 1.0
	launch_overlay.anchor_bottom = 1.0
	launch_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	launch_overlay.visible = false
	launch_overlay.gui_input.connect(_on_launch_overlay_bg_input)
	hud.add_child(launch_overlay)

	launch_overlay_panel = PanelContainer.new()
	launch_overlay_panel.anchor_left = 0.5
	launch_overlay_panel.anchor_right = 0.5
	launch_overlay_panel.anchor_top = 0.5
	launch_overlay_panel.anchor_bottom = 0.5
	launch_overlay_panel.offset_left = -220
	launch_overlay_panel.offset_right = 220
	launch_overlay_panel.offset_top = -160
	launch_overlay_panel.offset_bottom = 160
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.04, 0.06, 0.04, 0.97)
	panel_style.border_color = Color(0.2, 0.4, 0.22, 0.8)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(10)
	panel_style.content_margin_left = 18
	panel_style.content_margin_right = 18
	panel_style.content_margin_top = 14
	panel_style.content_margin_bottom = 14
	launch_overlay_panel.add_theme_stylebox_override("panel", panel_style)
	launch_overlay.add_child(launch_overlay_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	launch_overlay_panel.add_child(vbox)

	launch_overlay_title = Label.new()
	launch_overlay_title.add_theme_font_size_override("font_size", 18)
	launch_overlay_title.add_theme_color_override("font_color", Color(0.8, 1.0, 0.8))
	vbox.add_child(launch_overlay_title)

	var req_label := Label.new()
	req_label.text = "Requires:"
	req_label.add_theme_font_size_override("font_size", 13)
	req_label.add_theme_color_override("font_color", Color(0.55, 0.7, 0.55))
	vbox.add_child(req_label)

	launch_overlay_requirements = VBoxContainer.new()
	launch_overlay_requirements.add_theme_constant_override("separation", 4)
	vbox.add_child(launch_overlay_requirements)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spacer)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	vbox.add_child(btn_row)

	launch_overlay_cancel = Button.new()
	launch_overlay_cancel.text = "Cancel"
	launch_overlay_cancel.custom_minimum_size = Vector2(100, 32)
	launch_overlay_cancel.pressed.connect(_close_launch_overlay)
	btn_row.add_child(launch_overlay_cancel)

	launch_overlay_confirm = Button.new()
	launch_overlay_confirm.text = "▶ LAUNCH"
	launch_overlay_confirm.custom_minimum_size = Vector2(120, 32)
	launch_overlay_confirm.add_theme_color_override("font_color", Color(0.8, 1.0, 0.8))
	launch_overlay_confirm.pressed.connect(_on_launch_confirm)
	btn_row.add_child(launch_overlay_confirm)


func _open_launch_overlay(sector) -> void:
	_build_launch_overlay()
	launch_overlay_sector = sector
	launch_overlay_title.text = "Launch to %s" % sector.display_name
	_refresh_launch_overlay_requirements()
	launch_overlay.visible = true


func _close_launch_overlay() -> void:
	if launch_overlay:
		launch_overlay.visible = false
	launch_overlay_sector = null


func _on_launch_overlay_bg_input(event: InputEvent) -> void:
	# Clicking the dark backdrop (outside the panel) dismisses the overlay.
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_close_launch_overlay()


## Rebuilds the requirement list: one row per item with "have / needed"
## and a colour that flips red when the source sector is short.
func _refresh_launch_overlay_requirements() -> void:
	for c in launch_overlay_requirements.get_children():
		c.queue_free()
	var cost: Dictionary = _get_launch_cost()
	var src: Dictionary = _get_source_resources()
	var all_met: bool = true
	for short_id in cost:
		var need: int = int(cost[short_id])
		var key: StringName = _resolve_cost_key(str(short_id))
		var have: int = int(src.get(key, 0))
		if have < need:
			all_met = false
		var item_data = Registry.get_item_or_fluid(key)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.alignment = BoxContainer.ALIGNMENT_BEGIN
		# Item icon — replaces the text name. Tooltip keeps the display name
		# discoverable for anyone who can't recognise the sprite.
		var icon_rect := TextureRect.new()
		icon_rect.custom_minimum_size = Vector2(24, 24)
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		if item_data and item_data.icon:
			icon_rect.texture = item_data.icon
		if item_data:
			icon_rect.tooltip_text = item_data.display_name
		else:
			icon_rect.tooltip_text = str(short_id).capitalize()
		row.add_child(icon_rect)
		var val := Label.new()
		val.text = "%d / %d" % [have, need]
		val.add_theme_font_size_override("font_size", 13)
		val.add_theme_color_override("font_color",
			Color(0.6, 0.95, 0.6) if have >= need else Color(0.95, 0.45, 0.45))
		row.add_child(val)
		launch_overlay_requirements.add_child(row)
	# When the source sector can't cover the cost, the confirm button is
	# disabled and tinted so it's clear the launch isn't possible yet.
	launch_overlay_confirm.disabled = not all_met
	launch_overlay_confirm.modulate = Color(1, 1, 1, 1) if all_met else Color(0.7, 0.7, 0.7, 0.8)


func _on_launch_confirm() -> void:
	if launch_overlay_sector == null:
		_close_launch_overlay()
		return
	var cost: Dictionary = _get_launch_cost()
	var src_id: StringName = SaveManager.active_sector_id
	if src_id == &"" or src_id == &"_default":
		# No source sector to pay from — refuse (starting_grounds goes
		# through LAUNCH_FREE, so this only happens for a bad state).
		_refresh_launch_overlay_requirements()
		return
	# Make sure SaveManager's stored source-sector resources match the
	# latest snapshot, then operate on an explicit copy so the write-back
	# is unambiguous regardless of GDScript reference semantics.
	if SaveManager.has_method("sync_active_sector_resources"):
		SaveManager.sync_active_sector_resources()
	var src: Dictionary = {}
	if SaveManager.sector_resources.has(src_id):
		src = SaveManager.sector_resources[src_id].duplicate()
	# Verify once more (prevents double-click races / stale state).
	for short_id in cost:
		var need: int = int(cost[short_id])
		var key: StringName = _resolve_cost_key(str(short_id))
		if int(src.get(key, 0)) < need:
			_refresh_launch_overlay_requirements()
			return
	# Deduct from the source sector's pool and persist it back to the
	# SaveManager. This is the sector the player is "launching from", so
	# the resources leave that sector's stockpile for good.
	for short_id in cost:
		var need2: int = int(cost[short_id])
		var key2: StringName = _resolve_cost_key(str(short_id))
		src[key2] = int(src.get(key2, 0)) - need2
	SaveManager.sector_resources[src_id] = src
	SaveManager.save_campaign()
	var sector = launch_overlay_sector
	_close_launch_overlay()
	_do_launch(sector)


# =========================
# HELPERS
# =========================

func _get_planet_sectors(planet_id: StringName) -> Array:
	var result: Array = []
	for s in Registry.sectors_list:
		if s.planet_id == planet_id:
			result.append(s)
	return result
