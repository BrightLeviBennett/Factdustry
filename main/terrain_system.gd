extends Node2D

# ============================================================
# TERRAIN_SYSTEM.GD - Two-Layer Tile System (Floor + Wall)
# ============================================================
# Manages TWO separate tile layers:
#   floor_tiles: ground tiles like organic_floor, acid_floor, etc.
#   wall_tiles:  walls like rock_wall, membrane_wall, etc.
#
# Placing a wall no longer removes the floor underneath.
# Walls with render_tile_underneath = true let the floor show through.
#
# Special tiles: "Geyser" and "Vent" are 3x3 floor tiles.
# They render at 3x the normal size, but surrounding cells still
# show their own floor tiles on top (only the origin cell is opaque).
# ============================================================

signal walls_changed
signal terrain_changed(grid_pos: Vector2i)

@onready var main: Node2D = get_node("/root/Main")

# Cached sibling references. SectorScript is created lazily by Main._ready
# after Registry essentials load, so these may still be null at our _ready().
# Use _sector_script_ref() etc. to fetch-on-first-use.
var _sector_script: Node
var _building_sys: Node
var _unit_mgr: Node


## Lazy accessor — populates _sector_script the first time it's available.
## Needed because Main creates SectorScript after its own Registry await,
## which may happen after TerrainSystem._ready has already run.
func _sector_script_ref() -> Node:
	if _sector_script == null:
		_sector_script = get_node_or_null("/root/Main/SectorScript")
	return _sector_script


func _building_sys_ref() -> Node:
	if _building_sys == null:
		_building_sys = get_node_or_null("/root/Main/BuildingSystem")
	return _building_sys


func _unit_mgr_ref() -> Node:
	if _unit_mgr == null:
		_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	return _unit_mgr

# --- STATE ---
## Floor layer: Vector2i → StringName tile ID
var floor_tiles := {}
## Wall layer: Vector2i → StringName tile ID
var wall_tiles := {}
## Health for destructible walls: Vector2i → float
var tile_health := {}
## Tracks 3x3 tile origins: Vector2i → StringName (the origin pos → tile ID)
## All 9 cells of a 3x3 tile point back to the origin.
var multi_tile_origins := {}
## Ore layer: Vector2i → StringName tile ID (sits on top of walls)
var ore_tiles := {}

var selected_tile: StringName = &""
var paint_mode := false
## Last grid cell touched by the mouse while holding a paint-button. Lets
## _input interpolate a line between successive mouse-motion events so fast
## drags don't skip cells. Reset to a sentinel (Vector2i.MIN) on press and
## whenever a button is released.
var _paint_last_cell: Vector2i = Vector2i(-2147483648, -2147483648)

# --- FLOOR EDGE FADE ---
## Distance from each floor tile to the nearest non-floor edge (wall or void).
var _floor_edge_distance: Dictionary = {}  # Vector2i -> int
## Distance from each hidden floor tile to the nearest visible floor tile.
var _hidden_floor_distance: Dictionary = {}  # Vector2i -> int
var _floor_edge_dirty := true
## Separate, cheap dirty flag for just the floor-tile geometry meshes
## (which tiles exist + their textures). Set on every terrain edit so
## painted tiles appear immediately, while the far more expensive
## edge-fade / darkness BFS behind `_floor_edge_dirty` can be deferred.
## Full-rebuild flag for the floor-geometry meshes — set on map load / bulk
## edits / fog reveal (and by SaveManager). Single tile edits use the cheaper
## per-chunk `_floor_dirty_chunks` path instead.
var _floor_geom_dirty := true
## When true, `_draw` skips the expensive edge-fade / darkness rebuild
## even if `_floor_edge_dirty` is set. The map editor raises this for
## the duration of a paint stroke so the O(floor_tiles) BFS runs once
## on release instead of every frame of the drag. Always false during
## gameplay, so runtime behaviour is unchanged.
var defer_floor_fade := false

# --- WATER DEPTH ---
## Auto-computed water depth for each water floor tile: Vector2i → int (1-3).
## Distance from the nearest non-water floor tile. Recomputed when floor tiles change.
var _water_depth_map: Dictionary = {}  # Vector2i -> int (1/2/3 — legacy gameplay tier)
## Continuous depth factor for rendering: 0.0 = right at shore, 1.0 = fully
## deep. Lets the water blend smoothly instead of snapping between three
## discrete alpha bands.
var _water_depth_t: Dictionary = {}  # Vector2i -> float in [0, 1]
## Pre-baked per-corner depth factor — averaged across the 4 tiles sharing
## each corner so neighbouring cells line up smoothly at their shared
## edges. Format: Vector2i -> PackedFloat32Array [tl, tr, br, bl].
var _water_corner_t: Dictionary = {}
var _water_depth_dirty := true
## Set when a mid-stroke prune dropped a cell from the water render set.
## The (cheap, water-cells-only) mesh rebuild is coalesced to once per
## `_draw` instead of running per painted cell — a fast drag over water
## stamps many cells per frame, and rebuilding the whole water mesh on
## each one was O(cells × water_cells) and froze the editor.
var _water_mesh_dirty := false
## Batched water layer meshes, grouped by water texture. Each entry is
## `{texture: Texture2D, mesh: ArrayMesh}` so `_draw_floor_tiles` can
## blast the whole water layer in one draw call per distinct texture
## instead of one `draw_polygon` per cell per frame.
var _water_meshes: Array = []
## Batched sand underlay: a single ArrayMesh covering every water cell
## that still shows any sand (any corner with t < 1). Drawn before the
## water meshes at full opacity.
## One entry per distinct shore texture: {texture: Texture2D, mesh: ArrayMesh}.
## Most maps use only the default sand texture (one entry); a tile with a
## custom `shore_icon` (e.g. sulfur water) adds its own bucket.
var _sand_meshes: Array = []
## Floor tiles within fewer than this distance of void start fading (higher = wider fade).
## Pushed deeper inward so the darkening reaches full black well before the void
## edge — otherwise the hard void tiles peek through at the shallow end of the fade.
const FLOOR_FADE_START := 9
## How many tiles into a hidden region the fade extends
const HIDDEN_FADE_TILES := 2
## Pre-baked per-corner darkness for each floor tile. Rebuilt when _floor_edge_dirty.
var _fade_darkness: Dictionary = {}  # Vector2i -> [tl, tr, br, bl]

## Prebuilt mesh that batches every faded floor quad. Rebuilt alongside
## _fade_darkness whenever _floor_edge_dirty flips, so the per-frame cost is
## a single draw_mesh call instead of one draw_polygon per faded tile.
var _fade_mesh: ArrayMesh = null

## Batched FLOOR-tile meshes, grouped by tile texture. One draw call
## per distinct floor texture in view. Rebuilt only when terrain
## changes; per-frame cost is N draw_mesh calls (N ~ unique floor
## textures), not 6000+ per-cell dict lookups + draw_texture_rect.
##
## Water tiles are NOT included here — they go through `_water_meshes`
## with the gradient-corner shading. Hidden tiles are skipped at bake
## time and re-baked when the hidden set changes.
##
## Floor-tile meshes are batched per CHUNK (FLOOR_CHUNK×FLOOR_CHUNK cells) so a
## single tile edit only rebuilds that one chunk's quads (~256 cells) instead of
## the whole map (~14k). Drawing iterates chunks (visible-culled), each costing
## one draw call per distinct texture it contains.
##   chunk:Vector2i -> {
##     "tex":   Array of { texture: Texture2D, mesh: ArrayMesh },  # base floor
##     "ore":   Array of { texture: Texture2D, mesh: ArrayMesh },  # floor-ore overlay
##     "color": ArrayMesh | null,                                  # untextured tiles
##   }
## Water tiles are NOT included (they go through `_water_meshes`); hidden tiles
## are skipped at bake time and re-baked when the hidden set changes.
const FLOOR_CHUNK := 16
var _floor_chunk_meshes: Dictionary = {}
## Chunks awaiting an incremental rebuild after a single tile edit. Processed
## in `_draw` — far cheaper than the full `_floor_geom_dirty` rebuild, which is
## reserved for map load / bulk edits / fog reveal.
var _floor_dirty_chunks: Dictionary = {}

## Dedicated child CanvasItem that hosts the water-mesh draws so a
## ShaderMaterial can scroll the water surface without affecting the
## rest of the floor pass. The shader pulls TIME each frame so we
## don't have to `queue_redraw` per-frame — the canvas item keeps its
## (static) draw list and the GPU re-samples per frame.
var _water_canvas: Node2D = null
var _water_material: ShaderMaterial = null
var _slag_canvas: Node2D = null
var _slag_material: ShaderMaterial = null
var _slag_meshes: Array = []
var _slag_mesh_dirty := false
## Dedicated canvas for the sector-edge floor fade, sitting at z=2 — ABOVE the
## water canvas (z=1) so the dark gradient veils water tiles too. Drawn on the
## terrain canvas (z=0) it was painted UNDER the water and hidden on water
## sectors (hard black edge instead of a fade).
var _fade_canvas: Node2D = null
## Pausable clock fed into the water shader. Advances by delta each
## frame in _process unless the game is paused — keeps the wobble +
## drift frozen during pause alongside everything else.
var _water_anim_time: float = 0.0
## 1×1 white texture used as a stand-in when calling `draw_mesh` with
## a vertex-coloured mesh and no real texture. In Godot 4 the canvas
## item path doesn't always blend vertex colours correctly when
## texture is `null` — passing this opaque-white pixel makes the
## colour modulation behave as expected, which is what fixed the
## missing sector-edge fade and the untextured-floor colour pass.
var _white_pixel_tex: Texture2D = null


func _ensure_white_pixel_tex() -> Texture2D:
	if _white_pixel_tex == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.set_pixel(0, 0, Color(1, 1, 1, 1))
		_white_pixel_tex = ImageTexture.create_from_image(img)
	return _white_pixel_tex

# --- WATER RENDERING ---
## Sand texture drawn under water at shallow/medium depths.
var _sand_texture: Texture2D = null

# --- VENT PARTICLES ---
## Live steam-puff particles emitted from vent tiles.
## Each entry: { "pos": Vector2, "vel": Vector2, "age": float,
##               "life": float, "radius": float, "color": Color,
##               "circle_only": bool }
## `color` defaults to VENT_PARTICLE_COLOR; geyser bursts override with
## a blue tint. `circle_only` skips the steam texture and renders a
## solid circle, used by geyser spurts.
var _vent_particles: Array = []
## Per-vent-origin emission timer: Vector2i -> seconds until next puff.
var _vent_emit_timers: Dictionary = {}
## Per-geyser-origin emission timer: separate from vents because the
## emission cadence is much slower (sporadic bursts vs continuous stream).
var _geyser_emit_timers: Dictionary = {}
## Average seconds between emissions per vent. Tuned with VENT_PARTICLE_LIFE
## so each vent continually has several sprites in flight, forming a
## continuous stream rather than discrete puffs.
const VENT_EMIT_INTERVAL := 0.22
## How many sprites spawn per emission.
const VENT_PARTICLES_PER_PUFF := 1
## Lifetime of a particle in seconds. Longer = taller stream tail.
const VENT_PARTICLE_LIFE := 1.8
## Starting upward speed in pixels per second.
const VENT_PARTICLE_SPEED := 44.0
## Starting half-size in pixels (sprite renders at 2× this).
const VENT_PARTICLE_RADIUS := 88.0
## Modulate color for the steam sprite. Slight yellow/tan so the puff reads
## as hot vent gas rather than plain white steam (same trick the tech-tree
## checkmark uses — draw_texture's modulate tints the whole texture).
const VENT_PARTICLE_COLOR := Color(1.0, 0.95, 0.75, 0.75)

# --- GEYSER PARTICLES ---
## Geysers spurt sporadically rather than streaming. Every burst spawns
## a small cluster of upward-moving blue circles that fade out as they
## rise. Suppressed (no animation) when covered by a non-condenser block.
const GEYSER_BURST_INTERVAL := 4.5
## Sprites per burst — enough to read as a "splash" without overwhelming
## the screen.
const GEYSER_PARTICLES_PER_BURST := 6
## Lifetime of each geyser droplet.
const GEYSER_PARTICLE_LIFE := 1.2
## Initial upward speed; geyser droplets actually move (vent steam doesn't).
const GEYSER_PARTICLE_SPEED := 140.0
## Horizontal spread velocity at spawn so droplets fan out into a fountain.
const GEYSER_PARTICLE_SPREAD := 36.0
## Drop-radius in pixels. Smaller than vent steam — these are water beads.
const GEYSER_PARTICLE_RADIUS := 14.0
## Slight downward acceleration so the spurt arcs back toward ground.
const GEYSER_PARTICLE_GRAVITY := 90.0
## Bright blue with a hint of teal — reads as water droplets.
const GEYSER_PARTICLE_COLOR := Color(0.35, 0.65, 1.0, 0.95)

## Steam sprite rendered for each particle.
var _vent_steam_tex: Texture2D = null

func _ready() -> void:
	_sand_texture = load("res://textures/terrain/Sand.png") if ResourceLoader.exists("res://textures/terrain/Sand.png") else null
	_vent_steam_tex = load("res://textures/terrain/VentSteam.png") if ResourceLoader.exists("res://textures/terrain/VentSteam.png") else null
	# Spawn the overlay node that redraws vent puffs on top of the building
	# layer. Rendering from TerrainSystem itself would place them under every
	# building because TerrainSystem draws before BuildingSystem.
	var overlay_script: Script = load("res://main/vent_particle_overlay.gd")
	if overlay_script:
		var overlay := Node2D.new()
		overlay.set_script(overlay_script)
		overlay.name = "VentParticleOverlay"
		overlay.terrain = self
		# z_index sandwich:
		#   50 BuildingSystem (placed blocks + previews)
		#   51 LogisticsSystem (items on conveyors / pipes)
		#   52 vent/geyser steam puffs (this overlay)
		#   53 UnitManager + CombatSystem + PlayerDrone
		#   60 SectorScript (tutorial/hint overlays — top of the world)
		# Steam sits between conveyor items and units so a vent puff
		# softly veils items but flying units / projectiles still cut
		# through cleanly.
		overlay.z_index = 52
		overlay.z_as_relative = false
		add_child(overlay)
	# Water-animation child. Hosts the per-shader scrolling water
	# surface so the same TerrainSystem canvas can also draw plain
	# floor / sand / ore tiles with no shader. Sits between sand (drawn
	# from TerrainSystem at z=0) and floor-ore (drawn just after via
	# `_floor_ore_meshes`), so visually it occupies the same slot it
	# used to inside `_draw_floor_tiles`.
	_water_canvas = Node2D.new()
	_water_canvas.name = "WaterCanvas"
	# Repeat the water texture so the shader's world-position UVs wrap
	# cleanly across the map — otherwise each tile's sample stops at
	# its 0..1 boundary and the seams become visible as soon as the
	# scroll offset crosses a cell edge.
	_water_canvas.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	var water_shader: Shader = load("res://shaders/water_animated.gdshader") if ResourceLoader.exists("res://shaders/water_animated.gdshader") else null
	if water_shader:
		_water_material = ShaderMaterial.new()
		_water_material.shader = water_shader
		# Match the shader's world-tile size to GRID_SIZE so one full
		# water-texture tile spans one cell footprint.
		_water_material.set_shader_parameter("world_tile_size", float(main.GRID_SIZE))
		_water_canvas.material = _water_material
	_water_canvas.z_as_relative = false
	_water_canvas.z_index = 1   # above terrain (0), below building/logistics layers
	_water_canvas.draw.connect(_draw_water_layer)
	add_child(_water_canvas)
	_slag_canvas = Node2D.new()
	_slag_canvas.name = "SlagCanvas"
	_slag_canvas.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	var slag_shader: Shader = load("res://shaders/slag_animated.gdshader") if ResourceLoader.exists("res://shaders/slag_animated.gdshader") else null
	if slag_shader:
		_slag_material = ShaderMaterial.new()
		_slag_material.shader = slag_shader
		_slag_material.set_shader_parameter("world_tile_size", float(main.GRID_SIZE))
		_slag_canvas.material = _slag_material
	_slag_canvas.z_as_relative = false
	_slag_canvas.z_index = 1
	_slag_canvas.draw.connect(_draw_slag_layer)
	add_child(_slag_canvas)
	# Sector-edge fade canvas — z=2 so the dark gradient overlays BOTH the
	# floor (z=0) and the water surface (z=1), but still sits below buildings
	# (z=50). Repainted in lockstep with the terrain canvas (see _draw).
	_fade_canvas = Node2D.new()
	_fade_canvas.name = "FadeCanvas"
	_fade_canvas.z_as_relative = false
	_fade_canvas.z_index = 2
	_fade_canvas.draw.connect(_draw_fade_layer)
	add_child(_fade_canvas)
	await get_tree().process_frame
	_sector_script = get_node_or_null("/root/Main/SectorScript")
	_building_sys = get_node_or_null("/root/Main/BuildingSystem")
	_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	# Promote the "things that should draw over steam" layers now that the
	# scene is up. Safe if any of these are missing.
	for node_path in ["/root/Main/UnitManager", "/root/Main/CombatSystem", "/root/Main/PlayerDrone"]:
		var n = get_node_or_null(node_path)
		if n is CanvasItem:
			(n as CanvasItem).z_index = 53


func _process(delta: float) -> void:
	# Always redraw so wall parallax updates with camera movement
	_tick_vent_particles(delta)
	# Advance the water-shader clock, but only while the game is
	# running. The shader uses `anim_time` (not Godot's built-in TIME)
	# so this freezes the wobble / drift alongside everything else
	# during pause.
	var w_paused: bool = "world_paused" in main and bool(main.world_paused)
	if not w_paused and _water_material != null:
		_water_anim_time += delta
		_water_material.set_shader_parameter("anim_time", _water_anim_time)
		if _slag_material != null:
			_slag_material.set_shader_parameter("anim_time", _water_anim_time)
	queue_redraw()


## Spawns steam puffs from vent origins and advances existing particles.
## Mindustry-style: each vent periodically emits a small cluster of rising,
## slightly-spreading particles that fade out over their lifetime.
func _tick_vent_particles(delta: float) -> void:
	# --- Spawn: walk vent origins and drop a puff when their timer expires.
	# Vent floor tiles are 3x3; `floor_tiles` is keyed by the origin cell.
	# Emission is suppressed if the vent is covered by a non-vent-powered
	# block (the vent is plugged). Vent turbines don't suppress — the steam
	# reads as venting through the turbine.
	var world_paused: bool = "world_paused" in main and main.world_paused
	if not world_paused:
		for origin in floor_tiles:
			var tile_id: StringName = floor_tiles[origin]
			if tile_id == &"vent":
				if not _vent_can_emit(origin):
					# Reset the timer so the puff doesn't instantly fire the
					# moment the covering block is removed.
					_vent_emit_timers[origin] = VENT_EMIT_INTERVAL * randf_range(0.5, 1.0)
					continue
				var timer: float = _vent_emit_timers.get(origin, randf() * VENT_EMIT_INTERVAL)
				timer -= delta
				if timer <= 0.0:
					_spawn_vent_puff(origin)
					# Small jitter so the stream feels natural without gaps.
					timer = VENT_EMIT_INTERVAL * randf_range(0.85, 1.15)
				_vent_emit_timers[origin] = timer
			elif tile_id == &"geyser":
				if not _geyser_can_emit(origin):
					# Hold the timer above zero so the moment the covering
					# block is removed, the geyser doesn't immediately
					# spurt — give it a beat to "build pressure".
					_geyser_emit_timers[origin] = GEYSER_BURST_INTERVAL * randf_range(0.4, 0.8)
					continue
				var g_timer: float = _geyser_emit_timers.get(origin,
					GEYSER_BURST_INTERVAL * randf_range(0.3, 1.0))
				g_timer -= delta
				if g_timer <= 0.0:
					_spawn_geyser_burst(origin)
					# Wide jitter so neighboring geysers don't sync up.
					g_timer = GEYSER_BURST_INTERVAL * randf_range(0.7, 1.4)
				_geyser_emit_timers[origin] = g_timer

	# --- Update live particles. Paused world = freeze every sprite exactly
	# where it is (no aging, rotation, or motion) and resume on unpause.
	if world_paused:
		return
	var i := _vent_particles.size() - 1
	while i >= 0:
		var p: Dictionary = _vent_particles[i]
		p["age"] += delta
		# Rotation decays as the particle ages: full spin early in life,
		# easing toward zero as it dissipates. (1 - t)² gives a steeper
		# falloff than a linear ramp so late-life sprites look settled.
		var spin_t: float = clampf(p["age"] / p["life"], 0.0, 1.0)
		var spin_scale: float = (1.0 - spin_t) * (1.0 - spin_t)
		p["angle"] = wrapf(float(p.get("angle", 0.0)) + float(p.get("spin", 0.0)) * spin_scale * delta, -PI, PI)
		if p["age"] >= p["life"]:
			_vent_particles.remove_at(i)
		else:
			# Geyser droplets fall under gravity; vent steam drifts on
			# pure drag. The per-particle "gravity" field is 0 by default
			# so vent puffs keep their original behavior.
			var grav: float = float(p.get("gravity", 0.0))
			if grav != 0.0:
				p["vel"] = Vector2(p["vel"].x, p["vel"].y + grav * delta)
			else:
				p["vel"] *= 1.0 - minf(delta * 0.6, 1.0)
			p["pos"] += p["vel"] * delta
		i -= 1


## Returns true if the given vent origin should currently be emitting steam.
## Open vents emit. Vents with a vent-powered block (turbine) on top still
## emit — the puff reads as escaping through the turbine. Vents with any
## other building on top are considered plugged and emit nothing.
func _vent_can_emit(origin: Vector2i) -> bool:
	if not main.placed_buildings.has(origin):
		return true
	var block_id: StringName = main.placed_buildings[origin]
	var data = Registry.get_block(block_id)
	if data == null:
		return true
	return data.tags.has("vent_powered")


## Mirror of `_vent_can_emit` for geysers. Open geysers spurt; geysers
## with a vent-condenser on top still spurt — the spray reads as water
## being collected. Anything else covering the geyser plugs it.
func _geyser_can_emit(origin: Vector2i) -> bool:
	if not main.placed_buildings.has(origin):
		return true
	var block_id: StringName = main.placed_buildings[origin]
	var data = Registry.get_block(block_id)
	if data == null:
		return true
	return data.tags.has("condenser")


func _spawn_vent_puff(origin: Vector2i) -> void:
	var gs: float = float(main.GRID_SIZE)
	# Vent is a 3x3 multi-tile whose `origin` IS the center cell (the 3x3
	# footprint spans origin + (-1..1, -1..1)). Emit from the middle of that
	# cell, i.e. origin + (0.5, 0.5) tiles.
	var center: Vector2 = Vector2(
		(float(origin.x) + 0.5) * gs,
		(float(origin.y) + 0.5) * gs
	)
	for _n in range(VENT_PARTICLES_PER_PUFF):
		_vent_particles.append({
			# Every sprite sits dead-center on the vent — no jitter.
			"pos": center,
			"vel": Vector2.ZERO,
			"age": 0.0,
			"life": VENT_PARTICLE_LIFE * randf_range(0.9, 1.1),
			"radius": VENT_PARTICLE_RADIUS * randf_range(0.9, 1.1),
			# Random rotation + a small angular drift per sprite breaks the
			# "same shape stacked" look — overlapping sprites read as turbulent
			# gas instead of concentric copies.
			"angle": randf() * TAU,
			"spin": randf_range(-0.8, 0.8),
			# Slight non-uniform scale so not every particle is a perfect circle.
			"aspect": Vector2(randf_range(0.85, 1.15), randf_range(0.85, 1.15)),
		})


## Geyser burst: a small fountain of upward-moving blue droplets. Unlike
## vent steam (which is a continuous stream of slow puffs), geyser
## particles have real velocity + gravity so each burst arcs visibly.
func _spawn_geyser_burst(origin: Vector2i) -> void:
	var gs: float = float(main.GRID_SIZE)
	# Geyser is a 3x3 multi-tile keyed at its center cell, same as vent.
	var center: Vector2 = Vector2(
		(float(origin.x) + 0.5) * gs,
		(float(origin.y) + 0.5) * gs
	)
	for _n in range(GEYSER_PARTICLES_PER_BURST):
		var spread: float = randf_range(-GEYSER_PARTICLE_SPREAD, GEYSER_PARTICLE_SPREAD)
		# A bit of vertical variance so droplets don't all crest at the
		# same height — gives the spurt a more natural splash shape.
		var up_speed: float = GEYSER_PARTICLE_SPEED * randf_range(0.85, 1.15)
		_vent_particles.append({
			"pos": center + Vector2(spread * 0.15, 0.0),
			"vel": Vector2(spread, -up_speed),
			"age": 0.0,
			"life": GEYSER_PARTICLE_LIFE * randf_range(0.85, 1.15),
			"radius": GEYSER_PARTICLE_RADIUS * randf_range(0.8, 1.2),
			"angle": 0.0,
			"spin": 0.0,
			"aspect": Vector2.ONE,
			# Per-particle overrides: blue circle + downward gravity
			# distinguish geyser droplets from vent steam without
			# branching the renderer on tile type.
			"color": GEYSER_PARTICLE_COLOR,
			"circle_only": true,
			"gravity": GEYSER_PARTICLE_GRAVITY,
		})


func _input(event: InputEvent) -> void:
	if not paint_mode or selected_tile == &"":
		return

	if event is InputEventMouseButton:
		if event.pressed:
			var grid_pos = main.world_to_grid(get_global_mouse_position())
			if not main.is_within_bounds(grid_pos):
				return
			# Start a fresh drag stroke from the clicked cell — rasterize
			# from this position on subsequent motion events so a fast
			# drag covers every cell between samples.
			_paint_last_cell = grid_pos
			if event.button_index == MOUSE_BUTTON_LEFT:
				place_tile(grid_pos, selected_tile)
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				remove_tile(grid_pos)
		else:
			# Button released → forget the last cell so the next stroke
			# starts fresh instead of drawing a line from the previous
			# click's endpoint to wherever the mouse ends up next.
			_paint_last_cell = Vector2i(-2147483648, -2147483648)

	elif event is InputEventMouseMotion:
		var left_held: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		var right_held: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
		if not (left_held or right_held):
			return
		var grid_pos: Vector2i = main.world_to_grid(get_global_mouse_position())
		# Walk every cell along the line from the last-painted cell to
		# the current one so a fast drag doesn't leave gaps. If we have
		# no prior cell (first motion after entering paint mode), fall
		# back to painting just the current cell.
		var cells: Array[Vector2i]
		if _paint_last_cell != Vector2i(-2147483648, -2147483648):
			cells = _line_cells(_paint_last_cell, grid_pos)
		else:
			cells = [grid_pos] as Array[Vector2i]
		for cell in cells:
			if not main.is_within_bounds(cell):
				continue
			if left_held and selected_tile != &"":
				place_tile(cell, selected_tile)
			elif right_held:
				remove_tile(cell)
		_paint_last_cell = grid_pos


## Bresenham line rasterization between two grid cells. Returns every cell
## the line passes through, EXCLUDING `from` (it was already painted on
## the previous event) and INCLUDING `to`.
func _line_cells(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if from == to:
		result.append(to)
		return result
	var x0: int = from.x
	var y0: int = from.y
	var x1: int = to.x
	var y1: int = to.y
	var dx: int = absi(x1 - x0)
	var dy: int = absi(y1 - y0)
	var sx: int = 1 if x0 < x1 else -1
	var sy: int = 1 if y0 < y1 else -1
	var err: int = dx - dy
	var cx: int = x0
	var cy: int = y0
	while true:
		if cx != x0 or cy != y0:
			result.append(Vector2i(cx, cy))
		if cx == x1 and cy == y1:
			break
		var e2: int = err * 2
		if e2 > -dy:
			err -= dy
			cx += sx
		if e2 < dx:
			err += dx
			cy += sy
	return result


# =========================
# TILE PLACEMENT
# =========================

func place_tile(grid_pos: Vector2i, tile_id: StringName) -> void:
	var data = Registry.get_tile(tile_id)
	if data == null:
		return

	if data.is_wall() and main.placed_buildings.has(grid_pos):
		return

	if _is_multi_tile(tile_id):
		_place_multi_tile(grid_pos, tile_id)
		return

	if data.is_ore():
		# "floor_ore" ores (e.g. surface coal) sit on the ground instead
		# of being embedded in walls — they need a floor under them and
		# explicitly reject wall cells. Standard ores are wall-only.
		var is_floor_ore: bool = data.tags.has("floor_ore")
		if is_floor_ore:
			if not floor_tiles.has(grid_pos) or wall_tiles.has(grid_pos):
				return
		else:
			if not wall_tiles.has(grid_pos):
				return
		ore_tiles[grid_pos] = tile_id
		# Floor-ore overlay layer participates in the batched floor
		# mesh — re-bake on any ore add so surface coal etc. shows.
		if data.tags.has("floor_ore"):
			# Ore is an overlay in the chunk mesh only — no edge-fade change.
			_mark_floor_chunk_dirty(grid_pos)
	elif data.is_wall():
		# Overwriting a vent/geyser footprint cell with a wall — dissolve the
		# 3x3 first so it doesn't keep rendering across the new tile.
		_dissolve_multi_tile_at(grid_pos)
		wall_tiles[grid_pos] = tile_id
		if data.destructible:
			tile_health[grid_pos] = data.max_health
		var unit_mgr = _unit_mgr_ref()
		if data.blocks_pathfinding:
			if unit_mgr and unit_mgr.astar:
				unit_mgr.astar.set_point_solid(grid_pos, true)
			if unit_mgr and unit_mgr.astar_crawler:
				unit_mgr.astar_crawler.set_point_solid(grid_pos, true)
			if unit_mgr and unit_mgr.astar_hover:
				unit_mgr.astar_hover.set_point_solid(grid_pos, true)
			if unit_mgr and unit_mgr.astar_naval:
				unit_mgr.astar_naval.set_point_solid(grid_pos, true)
		if unit_mgr:
			unit_mgr._recompute_crawler_wall_passability()
		walls_changed.emit()
		_floor_edge_dirty = true
		_mark_floor_chunk_dirty(grid_pos)
		# Water depth only when the wall borders water (a wall acts as shore).
		if _edit_touches_water(grid_pos, &""):
			_water_depth_dirty = true
	else:
		var was_floor: bool = floor_tiles.has(grid_pos)
		var was_water: bool = _cell_is_water(grid_pos)
		var was_slag: bool = _cell_is_slag(grid_pos)
		# Overwriting a vent/geyser footprint cell with a plain floor — dissolve
		# the 3x3 first, else its stale origin keeps the multi-tile renderer
		# drawing this new tile across the full 3x3.
		_dissolve_multi_tile_at(grid_pos)
		floor_tiles[grid_pos] = tile_id
		# Edge fade depends only on floor/wall PRESENCE (the void boundary), not
		# the tile texture — so re-texturing already-floored land needs no edge
		# rebuild (that full-map BFS was the bulk of the on-release hitch). Only
		# a new void→floor transition changes the boundary.
		if not was_floor:
			_floor_edge_dirty = true
		_mark_floor_chunk_dirty(grid_pos)
		# Water depth only needs the full flood-fill when the edit actually
		# touches water — painting land away from water skips it entirely.
		if was_water or _edit_touches_water(grid_pos, tile_id):
			_water_depth_dirty = true
		if was_slag or _edit_touches_slag(grid_pos, tile_id):
			_slag_mesh_dirty = true
		# Painting a non-water floor over a water cell: drop it from the
		# water render NOW so the (z=1) water mesh stops drawing over the
		# new floor. The full depth/shore recompute is deferred during an
		# editor stroke (`defer_floor_fade`), so without this prune the old
		# water quad lingered on top until the drag released.
		_prune_water_cell_if_not_water(grid_pos)

	queue_redraw()
	terrain_changed.emit(grid_pos)


func remove_tile(grid_pos: Vector2i) -> void:
	if multi_tile_origins.has(grid_pos):
		_remove_multi_tile(multi_tile_origins[grid_pos])
		queue_redraw()
		return

	# Remove top layer first: ore → wall → floor
	if ore_tiles.has(grid_pos):
		ore_tiles.erase(grid_pos)
		# Ore is an overlay only — drop it from the chunk mesh; no edge change.
		_mark_floor_chunk_dirty(grid_pos)
	elif wall_tiles.has(grid_pos):
		var old_data = Registry.get_tile(wall_tiles[grid_pos])
		wall_tiles.erase(grid_pos)
		tile_health.erase(grid_pos)
		# Also remove any ore that was on this wall
		ore_tiles.erase(grid_pos)
		if old_data and old_data.is_wall():
			var unit_mgr = _unit_mgr_ref()
			if not main.placed_buildings.has(grid_pos):
				if unit_mgr and unit_mgr.astar:
					unit_mgr.astar.set_point_solid(grid_pos, false)
				if unit_mgr and unit_mgr.astar_crawler:
					unit_mgr.astar_crawler.set_point_solid(grid_pos, false)
				if unit_mgr and unit_mgr.astar_hover:
					unit_mgr.astar_hover.set_point_solid(grid_pos, false)
			if unit_mgr:
				unit_mgr._recompute_crawler_wall_passability()
		walls_changed.emit()
	elif floor_tiles.has(grid_pos):
		var was_water_r: bool = _cell_is_water(grid_pos)
		var was_slag_r: bool = _cell_is_slag(grid_pos)
		floor_tiles.erase(grid_pos)
		# Floor-ores (e.g. surface coal) sit ON the floor — once the
		# floor is gone, the ore has nothing to rest on. Mirrors how
		# wall removal also clears the ore embedded in it.
		if ore_tiles.has(grid_pos):
			var ore_data = Registry.get_tile(ore_tiles[grid_pos])
			if ore_data and ore_data.tags.has("floor_ore"):
				ore_tiles.erase(grid_pos)
		# Removing a floor always changes the void boundary → edge rebuild.
		_floor_edge_dirty = true
		_mark_floor_chunk_dirty(grid_pos)
		# Water depth only when the erased cell was water or borders water.
		if was_water_r or _edit_touches_water(grid_pos, &""):
			_water_depth_dirty = true
		if was_slag_r or _edit_touches_slag(grid_pos, &""):
			_slag_mesh_dirty = true
		# See place_tile: erasing a water cell must immediately drop it from
		# the water render so the stale water quad doesn't keep covering the
		# now-bare cell mid-stroke (full recompute is deferred).
		_prune_water_cell_if_not_water(grid_pos)
	else:
		return

	queue_redraw()
	terrain_changed.emit(grid_pos)




# =========================
# 3x3 MULTI-TILE (GEYSER / VENT)
# =========================

## Returns true if this tile ID should be placed as a 3x3.
func _is_multi_tile(tile_id: StringName) -> bool:
	var data = Registry.get_tile(tile_id)
	if not data:
		return false
	# Geyser, Vent, and Sulfur Vent all use the 3x3 multi-tile renderer.
	return data.id == "geyser" or data.id == "vent" or data.id == "sulfur_vent"


## Places a 3x3 floor tile. The origin is grid_pos (center).
## All 9 cells record this origin in multi_tile_origins.
func _place_multi_tile(origin: Vector2i, tile_id: StringName) -> void:
	# Check all 9 cells are valid
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var cell = origin + Vector2i(dx, dy)
			if not main.is_within_bounds(cell):
				return
			if main.placed_buildings.has(cell):
				return

	# Place: mark all 9 cells as belonging to this origin
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var cell = origin + Vector2i(dx, dy)
			multi_tile_origins[cell] = origin

	# Store the tile in floor layer at the origin
	floor_tiles[origin] = tile_id
	# The origin cell leaves the batched floor mesh (multi-tiles draw
	# themselves), and any floor under the footprint may need refreshing.
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var dirty_cell := origin + Vector2i(dx, dy)
			_mark_floor_chunk_dirty(dirty_cell)
			terrain_changed.emit(dirty_cell)
	queue_redraw()


## Removes a 3x3 tile by its origin position.
func _remove_multi_tile(origin: Vector2i) -> void:
	# Clear all 9 cells from multi_tile_origins
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var cell = origin + Vector2i(dx, dy)
			multi_tile_origins.erase(cell)
			# Footprint cells revert to plain floor (or bare) — refresh meshes.
			_mark_floor_chunk_dirty(cell)
			terrain_changed.emit(cell)

	floor_tiles.erase(origin)


## Dissolve a 3x3 multi-tile (vent/geyser) ONLY when its CENTER (origin) cell is
## being overwritten. Called before placing a plain 1x1 floor/wall: overwriting
## the center removes the whole vent (otherwise its stale origin would make the
## new tile render across the full 3x3); overwriting one of the 8 surrounding
## footprint cells leaves the vent intact.
func _dissolve_multi_tile_at(cell: Vector2i) -> void:
	if multi_tile_origins.get(cell, null) == cell:
		_remove_multi_tile(cell)


## True if `cell` currently holds a water floor tile.
func _cell_is_water(cell: Vector2i) -> bool:
	if not floor_tiles.has(cell):
		return false
	var d = Registry.get_tile(floor_tiles[cell])
	return d != null and d.is_liquid and d.tags.has("water")


func _is_slag_tile(data: TerrainTileData) -> bool:
	return data != null and data.is_liquid and data.tags.has("slag")


func _cell_is_slag(cell: Vector2i) -> bool:
	if not floor_tiles.has(cell):
		return false
	return _is_slag_tile(Registry.get_tile(floor_tiles[cell]))


func _edit_touches_slag(cell: Vector2i, new_tile_id: StringName) -> bool:
	if new_tile_id != &"":
		var nd = Registry.get_tile(new_tile_id)
		if _is_slag_tile(nd):
			return true
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if _cell_is_slag(cell + Vector2i(dx, dy)):
				return true
	return false


## True if an edit at `cell` could affect water-depth shading: the placed tile
## is water, or any cell in the 3x3 around it is water. Lets a land edit far
## from any water skip the (full-map) depth flood-fill entirely.
func _edit_touches_water(cell: Vector2i, new_tile_id: StringName) -> bool:
	if new_tile_id != &"":
		var nd = Registry.get_tile(new_tile_id)
		if nd != null and nd.is_liquid and nd.tags.has("water"):
			return true
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if _cell_is_water(cell + Vector2i(dx, dy)):
				return true
	return false


# =========================
# GETTERS
# =========================



## Returns the floor tile at a position (ignoring walls).
func get_floor_at(grid_pos: Vector2i) -> TerrainTileData:
	if floor_tiles.has(grid_pos):
		return Registry.get_tile(floor_tiles[grid_pos])
	return null



## Returns the ore tile at a position, or null.
func get_ore_at(grid_pos: Vector2i) -> TerrainTileData:
	if ore_tiles.has(grid_pos):
		return Registry.get_tile(ore_tiles[grid_pos])
	return null


## Returns the liquid source tile at a position, or null.
## Checks both multi-tile origins (Geyser/Vent) and regular floor tiles.
func get_liquid_at(grid_pos: Vector2i) -> TerrainTileData:
	# Check if this position is part of a multi-tile (Geyser/Vent)
	if multi_tile_origins.has(grid_pos):
		var origin = multi_tile_origins[grid_pos]
		if floor_tiles.has(origin):
			var data = Registry.get_tile(floor_tiles[origin])
			if data and data.is_liquid:
				return data
	# Also check regular floor tiles
	if floor_tiles.has(grid_pos):
		var data = Registry.get_tile(floor_tiles[grid_pos])
		if data and data.is_liquid:
			return data
	return null

## Returns whether a position has a wall (for pathfinding etc).
func has_wall(grid_pos: Vector2i) -> bool:
	return wall_tiles.has(grid_pos)


## Returns true if a cell has a floor tile, including cells that are
## members of a multi-tile floor (Vent / Geyser) where only the origin
## lives in `floor_tiles`. Water counts as a floor.
func has_floor(grid_pos: Vector2i) -> bool:
	return floor_tiles.has(grid_pos) or multi_tile_origins.has(grid_pos)


## Returns true if a cell is void — no floor and no wall. Nothing can
## be built on the abyss.
func is_void(grid_pos: Vector2i) -> bool:
	return not has_floor(grid_pos) and not wall_tiles.has(grid_pos)


## Returns the auto-computed water depth at a position, or 0 if the tile
## isn't water. 1 = shallow, 2 = medium, 3 = deep.
## Computed via BFS distance from the nearest non-water floor tile.
func get_water_depth_at(grid_pos: Vector2i) -> int:
	# Skip the (full-map) rebuild while an editor stroke is in progress —
	# `defer_floor_fade` means the depth map is intentionally stale until the
	# stroke commits. Without this guard, any per-frame gameplay query during
	# editing would force a full flood-fill every frame, defeating the defer.
	if _water_depth_dirty and not defer_floor_fade:
		_rebuild_water_depth()
	return _water_depth_map.get(grid_pos, 0)



# =========================
# BACKWARD COMPATIBILITY
# =========================

## Legacy getter — returns all tiles (both layers merged, walls take priority).
var placed_tiles: Dictionary:
	get:
		var merged = floor_tiles.duplicate()
		merged.merge(wall_tiles, true)
		return merged


# =========================
# PAINT MODE
# =========================







# =========================
# FLOOR EDGE FADE
# =========================

## Rebuilds the auto-computed water depth map via BFS.
## Every water floor tile gets a depth of 1-3 based on its distance from the
## nearest actual land tile (non-water floor). Void tiles are ignored.
##
## Small islands in open water use a TIGHTER depth-tier gradient than large
## continents: a tiny piece of land surrounded by deep ocean shouldn't push
## a huge halo of shallow/medium water around it. The gradient is:
##   - nearest land is a small island (<= SMALL_ISLAND_TILES tiles):
##       dist 1-2 → shallow, dist 3-4 → medium, dist 5+ → deep
##   - otherwise (mainland shoreline):
##       dist 1-3 → shallow, dist 4-6 → medium, dist 7+ → deep
func _rebuild_water_depth() -> void:
	_water_depth_dirty = false
	_water_depth_map.clear()
	_water_depth_t.clear()
	_water_corner_t.clear()

	const SMALL_ISLAND_TILES := 30

	# 1. Identify water and land cells.
	var water_cells := {}
	var land_cells := {}
	for pos in floor_tiles:
		var td = Registry.get_tile(floor_tiles[pos])
		if td and td.is_liquid and td.tags.has("water"):
			water_cells[pos] = true
		elif floor_tiles.has(pos):
			# Any non-water floor tile counts as land for shoreline purposes.
			land_cells[pos] = true

	if water_cells.is_empty():
		_rebuild_water_meshes()
		return

	# 2. Flood-fill land into connected islands so we can tag each land
	#    tile with the size of its landmass. This only walks land cells,
	#    so a huge ocean with a single 3-tile island correctly reports
	#    "island is tiny" rather than treating the whole map as one mass.
	var island_id_of: Dictionary = {}  # Vector2i → int
	var island_size: Dictionary = {}   # int → int (tile count)
	var next_id := 0
	var neighbors := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for seed in land_cells:
		if island_id_of.has(seed):
			continue
		var this_id := next_id
		next_id += 1
		var count := 0
		var stack: Array[Vector2i] = [seed]
		while not stack.is_empty():
			var p: Vector2i = stack.pop_back()
			if island_id_of.has(p):
				continue
			island_id_of[p] = this_id
			count += 1
			for nb in neighbors:
				var ap: Vector2i = p + nb
				if land_cells.has(ap) and not island_id_of.has(ap):
					stack.append(ap)
		island_size[this_id] = count

	# 3. BFS seed: every water cell that borders land. Each seeded cell
	#    remembers which island it was seeded from (used later to pick a
	#    depth-tier gradient). Void tiles are ignored — a water body that
	#    opens onto the void stays deep all the way to the edge.
	var dist: Dictionary = {}        # Vector2i → int distance from land
	var nearest_island: Dictionary = {}  # Vector2i → int island id
	var queue: Array[Vector2i] = []

	for pos in water_cells:
		var min_iid := -1
		var min_iid_size := 0
		for nb in neighbors:
			var adj: Vector2i = pos + nb
			if water_cells.has(adj):
				continue
			if not land_cells.has(adj):
				continue  # void / wall
			var iid: int = island_id_of[adj]
			var isz: int = island_size[iid]
			# Prefer the SMALLEST neighbouring island so a water tile
			# sandwiched between a tiny isle and a big continent uses the
			# isle's tight gradient (otherwise the continent dominates).
			if min_iid == -1 or isz < min_iid_size:
				min_iid = iid
				min_iid_size = isz
		if min_iid != -1:
			dist[pos] = 1
			nearest_island[pos] = min_iid
			queue.append(pos)

	# 4. BFS outward. Propagating `nearest_island` alongside distance
	#    keeps the "which shoreline owns this water cell" assignment
	#    consistent even when two islands meet in the middle of a
	#    channel (the closer island wins by BFS order).
	var head := 0
	while head < queue.size():
		var pos: Vector2i = queue[head]
		head += 1
		var d: int = dist[pos]
		var iid: int = nearest_island[pos]
		for nb in neighbors:
			var adj: Vector2i = pos + nb
			if water_cells.has(adj) and not dist.has(adj):
				dist[adj] = d + 1
				nearest_island[adj] = iid
				queue.append(adj)

	# 5. Map distance → depth tier using the nearest island's size to
	#    pick the gradient. Small islands use a 2-tile step so their
	#    shallow halo only covers 1-2 tiles around them; mainland
	#    coastline uses the wider 3-tile step.
	for pos in dist:
		var d: int = dist[pos]
		var iid_p: int = nearest_island.get(pos, -1)
		var sz: int = island_size.get(iid_p, 0)
		# Deep-start distance depends on island size — small islands ramp
		# faster. `deep_at` is the dist at which water is fully deep.
		var deep_at: float
		if sz > 0 and sz <= SMALL_ISLAND_TILES:
			deep_at = 5.0  # dist 1-2 shallow, 3-4 medium, 5+ deep
			if d <= 2:
				_water_depth_map[pos] = 1
			elif d <= 4:
				_water_depth_map[pos] = 2
			else:
				_water_depth_map[pos] = 3
		else:
			deep_at = 7.0  # dist 1-3 shallow, 4-6 medium, 7+ deep
			if d <= 3:
				_water_depth_map[pos] = 1
			elif d <= 6:
				_water_depth_map[pos] = 2
			else:
				_water_depth_map[pos] = 3
		# Continuous depth factor: 0 at the first water tile adjacent to
		# land, 1 by the time we hit the deep tier. Renderer smoothly
		# interpolates water/sand alpha across this.
		_water_depth_t[pos] = clampf(float(d - 1) / maxf(deep_at - 1.0, 1.0), 0.0, 1.0)

	# Water with no shoreline seed (e.g. editor bucket-fill into void) still
	# needs to render immediately. Treat unreached water as fully deep.
	for water_pos in water_cells:
		if not _water_depth_map.has(water_pos):
			_water_depth_map[water_pos] = 3
			_water_depth_t[water_pos] = 1.0

	# Bake per-corner depth by averaging the 4 tiles that share each
	# corner. Non-water neighbours contribute t=0 (shore-adjacent), which
	# pulls the corner's alpha down and makes the shoreline fade in over
	# the diagonal instead of snapping at cell edges.
	var corner_offsets: Array = [
		[Vector2i(0, 0), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1)],  # TL
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(1, -1)],    # TR
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],      # BR
		[Vector2i(0, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(-1, 1)],    # BL
	]
	for pos in _water_depth_t:
		var c := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
		for ci in range(4):
			var sum_t := 0.0
			for off in corner_offsets[ci]:
				sum_t += float(_water_depth_t.get(pos + off, 0.0))
			c[ci] = sum_t * 0.25
		_water_corner_t[pos] = c

	_rebuild_water_meshes()


## Bakes the per-frame water & sand draw cost down to one `draw_mesh` per
## water texture (plus one for sand). A mesh holds every visible water
## cell's quad with per-corner vertex colors carrying the fade alphas, so
## the GPU interpolates the shore→deep gradient for free and culls
## off-screen tiles automatically. Rebuilt alongside `_water_depth_t`,
## and whenever `_water_depth_dirty` flips back on (terrain edits,
## sector_script hide/reveal).
## Renders every batched water mesh onto the dedicated `_water_canvas`.
## Hooked up via `draw.connect` in `_ready`; called automatically by
## the engine whenever the canvas is invalidated (terrain changes →
## `queue_redraw`).
func _draw_water_layer() -> void:
	if _water_canvas == null:
		return
	for bucket in _water_meshes:
		_water_canvas.draw_mesh(bucket["mesh"], bucket["texture"])


func _draw_slag_layer() -> void:
	if _slag_canvas == null:
		return
	for bucket in _slag_meshes:
		_slag_canvas.draw_mesh(bucket["mesh"], bucket["texture"])


## Renders the batched sector-edge fade mesh onto `_fade_canvas` (z=2), above
## the water layer. `_ensure_white_pixel_tex()` instead of null: Godot 4's
## canvas path drops per-vertex Color modulation when no texture is supplied,
## so the dark gradient quads would render fully transparent → no fade at all.
func _draw_fade_layer() -> void:
	if _fade_canvas == null or _fade_mesh == null:
		return
	var fade_off: bool = "fade_enabled" in main and not main.fade_enabled
	if fade_off:
		return
	_fade_canvas.draw_mesh(_fade_mesh, _ensure_white_pixel_tex())


## Immediately drops `cell` from the water render set if its current floor
## is no longer a water tile, then rebuilds the (cheap, water-cells-only)
## water mesh. Used when a stroke paints / erases over water while the full
## depth + shore-shading recompute is deferred behind `defer_floor_fade`,
## so the stale water quad doesn't keep drawing on top of the new floor
## until the drag releases. No-op if the cell wasn't water.
func _prune_water_cell_if_not_water(cell: Vector2i) -> void:
	if not _water_depth_t.has(cell):
		return
	# Still water? (e.g. painted one water variant over another) — leave it;
	# the deferred recompute will refresh shading on release.
	var data = Registry.get_tile(floor_tiles.get(cell, &""))
	if data != null and data.is_liquid and data.tags.has("water"):
		return
	_water_depth_t.erase(cell)
	_water_corner_t.erase(cell)
	# Neighbours' shore corners are now stale, but recomputing them needs
	# the full flood-fill (deferred). Dropping just this cell is enough to
	# stop the wrong quad covering the new floor; shore re-shades on release.
	# Defer the mesh rebuild to once per frame (see `_water_mesh_dirty`) so a
	# fast multi-cell stroke doesn't rebuild the whole water layer per cell.
	_water_mesh_dirty = true


func _rebuild_water_meshes() -> void:
	_water_meshes.clear()
	_sand_meshes.clear()
	if _water_depth_t.is_empty():
		# No water left — still repaint so the now-empty mesh set clears any
		# previously-drawn water (e.g. the last water cell was just painted
		# over). Without this the final water quad lingered until release.
		if _water_canvas != null:
			_water_canvas.queue_redraw()
		return

	var ss := _sector_script_ref()
	# Group water cells by their tile-icon texture so a map with multiple
	# water variants (e.g. fresh water + salt water) still compresses to
	# one draw per distinct texture.
	var by_tex: Dictionary = {}  # Texture2D -> Array of {pos, corners, opacity}
	# Shore (underlay) cells grouped by their shore texture so a tile with a
	# custom `shore_icon` (sulfur water) fades into its own shore, not sand.
	var shore_by_tex: Dictionary = {}  # Texture2D -> Array of [pos, opacity]
	for pos in _water_depth_t:
		if ss and ss.is_tile_hidden(pos):
			continue
		if not floor_tiles.has(pos):
			continue
		var data = Registry.get_tile(floor_tiles[pos])
		if data == null or data.icon == null:
			continue
		var corners: PackedFloat32Array = _water_corner_t.get(pos,
			PackedFloat32Array([1.0, 1.0, 1.0, 1.0]))
		if not by_tex.has(data.icon):
			by_tex[data.icon] = []
		by_tex[data.icon].append([pos, corners, data.opacity])
		# Skip the underlay under fully-deep cells — water is opaque there, so
		# the shore beneath is wasted fill.
		if corners[0] < 1.0 or corners[1] < 1.0 \
				or corners[2] < 1.0 or corners[3] < 1.0:
			var shore_tex: Texture2D = data.shore_icon if data.shore_icon != null else _sand_texture
			if shore_tex != null:
				if not shore_by_tex.has(shore_tex):
					shore_by_tex[shore_tex] = []
				shore_by_tex[shore_tex].append([pos, data.opacity])

	for stex in shore_by_tex:
		var smesh: ArrayMesh = _build_flat_quad_mesh(shore_by_tex[stex])
		if smesh != null:
			_sand_meshes.append({"texture": stex, "mesh": smesh})
	for tex in by_tex:
		var cells: Array = by_tex[tex]
		var mesh: ArrayMesh = _build_water_quad_mesh(cells)
		if mesh != null:
			_water_meshes.append({"texture": tex, "mesh": mesh})
	# Tell the dedicated water canvas to repaint with the new mesh set.
	# The shader animates via TIME so we DON'T have to keep redrawing —
	# this only fires on terrain change.
	if _water_canvas != null:
		_water_canvas.queue_redraw()


func _rebuild_slag_meshes() -> void:
	_slag_meshes.clear()
	var ss := _sector_script_ref()
	var by_tex: Dictionary = {}
	for pos in floor_tiles:
		if ss and ss.is_tile_hidden(pos):
			continue
		var data: TerrainTileData = Registry.get_tile(floor_tiles[pos])
		if not _is_slag_tile(data) or data.icon == null:
			continue
		if not by_tex.has(data.icon):
			by_tex[data.icon] = []
		by_tex[data.icon].append([pos, data.opacity])
	for tex in by_tex:
		var mesh: ArrayMesh = _build_flat_quad_mesh(by_tex[tex])
		if mesh != null:
			_slag_meshes.append({"texture": tex, "mesh": mesh})
	if _slag_canvas != null:
		_slag_canvas.queue_redraw()


## Builds a batched textured quad mesh with uniform white vertex color
## modulated by `opacity`. Used for the sand underlay.
func _build_flat_quad_mesh(cells: Array) -> ArrayMesh:
	var n := cells.size()
	if n == 0:
		return null
	var gs := float(main.GRID_SIZE)
	var verts := PackedVector3Array()
	verts.resize(n * 4)
	var cols := PackedColorArray()
	cols.resize(n * 4)
	var uvs := PackedVector2Array()
	uvs.resize(n * 4)
	var idxs := PackedInt32Array()
	idxs.resize(n * 6)
	var vi := 0
	var ii := 0
	for entry in cells:
		var pos: Vector2i = entry[0]
		var opac: float = float(entry[1])
		var wx: float = float(pos.x) * gs
		var wy: float = float(pos.y) * gs
		verts[vi + 0] = Vector3(wx, wy, 0.0)
		verts[vi + 1] = Vector3(wx + gs, wy, 0.0)
		verts[vi + 2] = Vector3(wx + gs, wy + gs, 0.0)
		verts[vi + 3] = Vector3(wx, wy + gs, 0.0)
		var c := Color(1, 1, 1, opac)
		cols[vi + 0] = c
		cols[vi + 1] = c
		cols[vi + 2] = c
		cols[vi + 3] = c
		uvs[vi + 0] = Vector2(0, 0)
		uvs[vi + 1] = Vector2(1, 0)
		uvs[vi + 2] = Vector2(1, 1)
		uvs[vi + 3] = Vector2(0, 1)
		idxs[ii + 0] = vi + 0
		idxs[ii + 1] = vi + 1
		idxs[ii + 2] = vi + 2
		idxs[ii + 3] = vi + 0
		idxs[ii + 4] = vi + 2
		idxs[ii + 5] = vi + 3
		vi += 4
		ii += 6
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idxs
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


## Builds a batched textured quad mesh with per-corner alpha driven by
## `_water_corner_t`. Each cell = `[pos, corners: PackedFloat32Array(4),
## opacity: float]`. The corner→alpha curve (0.5 at shore, 1.0 at deep)
## matches the old per-tile path and is what gives the smooth fade.
func _build_water_quad_mesh(cells: Array) -> ArrayMesh:
	var n := cells.size()
	if n == 0:
		return null
	var gs := float(main.GRID_SIZE)
	var verts := PackedVector3Array()
	verts.resize(n * 4)
	var cols := PackedColorArray()
	cols.resize(n * 4)
	var uvs := PackedVector2Array()
	uvs.resize(n * 4)
	var idxs := PackedInt32Array()
	idxs.resize(n * 6)
	var vi := 0
	var ii := 0
	for entry in cells:
		var pos: Vector2i = entry[0]
		var corners: PackedFloat32Array = entry[1]
		var opac: float = float(entry[2])
		var wx: float = float(pos.x) * gs
		var wy: float = float(pos.y) * gs
		verts[vi + 0] = Vector3(wx, wy, 0.0)
		verts[vi + 1] = Vector3(wx + gs, wy, 0.0)
		verts[vi + 2] = Vector3(wx + gs, wy + gs, 0.0)
		verts[vi + 3] = Vector3(wx, wy + gs, 0.0)
		cols[vi + 0] = Color(1, 1, 1, (0.5 + 0.5 * corners[0]) * opac)
		cols[vi + 1] = Color(1, 1, 1, (0.5 + 0.5 * corners[1]) * opac)
		cols[vi + 2] = Color(1, 1, 1, (0.5 + 0.5 * corners[2]) * opac)
		cols[vi + 3] = Color(1, 1, 1, (0.5 + 0.5 * corners[3]) * opac)
		uvs[vi + 0] = Vector2(0, 0)
		uvs[vi + 1] = Vector2(1, 0)
		uvs[vi + 2] = Vector2(1, 1)
		uvs[vi + 3] = Vector2(0, 1)
		idxs[ii + 0] = vi + 0
		idxs[ii + 1] = vi + 1
		idxs[ii + 2] = vi + 2
		idxs[ii + 3] = vi + 0
		idxs[ii + 4] = vi + 2
		idxs[ii + 5] = vi + 3
		vi += 4
		ii += 6
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idxs
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


## Rebuild the floor-edge distance cache (BFS inward from edges).
func _rebuild_floor_edge_cache() -> void:
	_floor_edge_dirty = false
	_floor_edge_distance.clear()
	var sector_script = _sector_script_ref()
	# Seed: visible floor tiles adjacent to void or hidden tiles.
	# Walls block the floor fade, even if the wall has void behind it.
	var queue: Array[Vector2i] = []
	for grid_pos in floor_tiles:
		if wall_tiles.has(grid_pos):
			continue
		if sector_script and sector_script.is_tile_hidden(grid_pos):
			continue
		for offset in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]:
			var nb = grid_pos + offset
			var nb_is_void: bool = not floor_tiles.has(nb) and not wall_tiles.has(nb)
			var nb_is_hidden: bool = sector_script != null and floor_tiles.has(nb) and not wall_tiles.has(nb) and sector_script.is_tile_hidden(nb)
			if nb_is_void or nb_is_hidden:
				_floor_edge_distance[grid_pos] = 0
				queue.append(grid_pos)
				break
	# BFS expand inward (skip hidden tiles)
	var head := 0
	while head < queue.size():
		var pos: Vector2i = queue[head]
		head += 1
		var dist: int = _floor_edge_distance[pos]
		for offset in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]:
			var nb = pos + offset
			if floor_tiles.has(nb) and not wall_tiles.has(nb) and not _floor_edge_distance.has(nb):
				if sector_script and sector_script.is_tile_hidden(nb):
					continue
				_floor_edge_distance[nb] = dist + 1
				queue.append(nb)

	# Second BFS: compute distance from visible floors INTO hidden region
	# so hidden tiles near the boundary get a fade instead of hard cutoff
	_hidden_floor_distance.clear()
	if sector_script:
		var hqueue: Array[Vector2i] = []
		# Seed: hidden floor tiles adjacent to a visible floor or visible wall
		for grid_pos in floor_tiles:
			if not sector_script.is_tile_hidden(grid_pos):
				continue
			for offset in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]:
				var nb = grid_pos + offset
				var nb_is_visible_floor: bool = floor_tiles.has(nb) and not sector_script.is_tile_hidden(nb)
				var nb_is_visible_wall: bool = wall_tiles.has(nb) and not sector_script.is_tile_hidden(nb)
				if nb_is_visible_floor or nb_is_visible_wall:
					_hidden_floor_distance[grid_pos] = 0
					hqueue.append(grid_pos)
					break
		# BFS expand through hidden tiles (up to HIDDEN_FADE_TILES)
		var hhead := 0
		while hhead < hqueue.size():
			var pos2: Vector2i = hqueue[hhead]
			hhead += 1
			var hdist: int = _hidden_floor_distance[pos2]
			if hdist >= HIDDEN_FADE_TILES:
				continue
			for offset in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]:
				var nb = pos2 + offset
				if floor_tiles.has(nb) and sector_script.is_tile_hidden(nb) and not _hidden_floor_distance.has(nb):
					_hidden_floor_distance[nb] = hdist + 1
					hqueue.append(nb)

	# Pre-bake per-corner darkness for all visible floor tiles
	_fade_darkness.clear()
	for grid_pos in floor_tiles:
		if wall_tiles.has(grid_pos):
			continue
		if sector_script and sector_script.is_tile_hidden(grid_pos):
			continue
		var cd: Array = _get_floor_corner_darkness(grid_pos)
		if cd[0] > 0.0 or cd[1] > 0.0 or cd[2] > 0.0 or cd[3] > 0.0:
			_fade_darkness[grid_pos] = cd

	# Rebuild the batched fade mesh so each frame only costs one draw call.
	_rebuild_fade_mesh()
	# Refresh the base floor-tile meshes ONLY when a full rebuild was requested
	# (map load / bulk edit set `_floor_geom_dirty`). During editor strokes the
	# floor geometry is kept current incrementally via `_floor_dirty_chunks`, so
	# a full rebuild here would be redundant — and that redundant full-map pass
	# on every stroke commit was a big part of the on-release hitch.
	if _floor_geom_dirty:
		_floor_geom_dirty = false
		_rebuild_floor_meshes()


## Builds one ArrayMesh per distinct floor texture, covering every
## visible non-water non-hidden floor tile. Drawn once per texture per
## frame instead of iterating the visible bounds per cell.
##
## Also builds a parallel set of meshes for floor-ore overlays (e.g.
## surface coal), which previously took a separate `_draw_tile_texture`
## call per cell. Wall-embedded ores keep their existing path through
## BuildingSystem.
func _rebuild_floor_meshes() -> void:
	# Full rebuild — re-bake every chunk from scratch. Used on map load / bulk
	# edits / fog reveal. Single tile edits go through `_rebuild_floor_chunk`.
	_floor_chunk_meshes.clear()
	_floor_dirty_chunks.clear()
	if floor_tiles.is_empty():
		return
	var ss := _sector_script_ref()
	# One pass over all floor tiles, bucketed by chunk so each chunk's mesh
	# set is built independently (and can later be rebuilt in isolation).
	# chunk:Vector2i -> {by_tex, ore_by_tex, colored}
	var per_chunk: Dictionary = {}
	for grid_pos in floor_tiles:
		var ch: Vector2i = _chunk_of(grid_pos)
		var b: Dictionary = per_chunk.get(ch, {})
		if b.is_empty():
			b = {"by_tex": {}, "ore_by_tex": {}, "colored": []}
			per_chunk[ch] = b
		_classify_floor_cell(grid_pos, ss, b["by_tex"], b["ore_by_tex"], b["colored"])
	for ch in per_chunk:
		var b: Dictionary = per_chunk[ch]
		var entry: Dictionary = _build_chunk_mesh_entry(b["by_tex"], b["ore_by_tex"], b["colored"])
		if entry != null and not _chunk_entry_empty(entry):
			_floor_chunk_meshes[ch] = entry


## Chunk coordinate containing a cell. Cells are always within [0, GRID_*),
## so plain integer division is correct (no negative-floor issue).
func _chunk_of(cell: Vector2i) -> Vector2i:
	return Vector2i(cell.x / FLOOR_CHUNK, cell.y / FLOOR_CHUNK)


## Flags the chunk owning `cell` for an incremental floor-mesh rebuild.
func _mark_floor_chunk_dirty(cell: Vector2i) -> void:
	_floor_dirty_chunks[_chunk_of(cell)] = true


## Clears all cached render products after a bulk terrain wipe. Dictionary
## contents are owned by callers; this only resets draw-time caches.
func clear_render_caches() -> void:
	_floor_edge_distance.clear()
	_hidden_floor_distance.clear()
	_fade_darkness.clear()
	_water_depth_map.clear()
	_water_depth_t.clear()
	_water_corner_t.clear()
	_water_meshes.clear()
	_sand_meshes.clear()
	_slag_meshes.clear()
	_floor_chunk_meshes.clear()
	_floor_dirty_chunks.clear()
	_fade_mesh = null
	_floor_edge_dirty = true
	_water_depth_dirty = true
	_slag_mesh_dirty = true
	_floor_geom_dirty = true
	if _water_canvas != null:
		_water_canvas.queue_redraw()
	if _slag_canvas != null:
		_slag_canvas.queue_redraw()
	if _fade_canvas != null:
		_fade_canvas.queue_redraw()
	queue_redraw()


## Rebuilds the batched floor meshes for ONE chunk by scanning only its cells
## (FLOOR_CHUNK²), so a single tile edit costs ~256 cells instead of the whole
## map. Erases the chunk's entry when it ends up empty.
func _rebuild_floor_chunk(chunk: Vector2i) -> void:
	var ss := _sector_script_ref()
	var by_tex: Dictionary = {}
	var ore_by_tex: Dictionary = {}
	var colored_cells: Array = []
	var x0: int = chunk.x * FLOOR_CHUNK
	var y0: int = chunk.y * FLOOR_CHUNK
	for cx in range(x0, x0 + FLOOR_CHUNK):
		for cy in range(y0, y0 + FLOOR_CHUNK):
			var grid_pos := Vector2i(cx, cy)
			if floor_tiles.has(grid_pos):
				_classify_floor_cell(grid_pos, ss, by_tex, ore_by_tex, colored_cells)
	var entry: Dictionary = _build_chunk_mesh_entry(by_tex, ore_by_tex, colored_cells)
	if _chunk_entry_empty(entry):
		_floor_chunk_meshes.erase(chunk)
	else:
		_floor_chunk_meshes[chunk] = entry


## Classifies one floor cell into the texture/ore/color buckets, applying the
## same skips the batched pass always used:
##   • hidden tiles (sector-script fog override)
##   • multi-tile origins (vents/geysers draw themselves)
##   • wall tiles (owned by the building/wall pass)
##   • animated liquids (water / slag) — tested on the
##     ACTUAL tile data, not the deferred `_water_depth_t` set, so a freshly
##     painted non-water floor over an old water cell shows immediately.
func _classify_floor_cell(grid_pos: Vector2i, ss, by_tex: Dictionary, ore_by_tex: Dictionary, colored_cells: Array) -> void:
	if ss and ss.is_tile_hidden(grid_pos):
		return
	if multi_tile_origins.has(grid_pos) and multi_tile_origins[grid_pos] == grid_pos:
		return
	var data = Registry.get_tile(floor_tiles[grid_pos])
	if data == null:
		return
	if data.is_wall():
		return
	if data.is_liquid and (data.tags.has("water") or data.tags.has("slag")):
		return
	if data.icon != null:
		if not by_tex.has(data.icon):
			by_tex[data.icon] = []
		by_tex[data.icon].append([grid_pos, data.opacity])
	else:
		colored_cells.append([grid_pos, data.color, data.opacity])
	# Floor-ore overlay layer.
	if ore_tiles.has(grid_pos):
		var ore_data: TerrainTileData = Registry.get_tile(ore_tiles[grid_pos])
		if ore_data and ore_data.icon != null and ore_data.tags.has("floor_ore"):
			if not ore_by_tex.has(ore_data.icon):
				ore_by_tex[ore_data.icon] = []
			ore_by_tex[ore_data.icon].append([grid_pos, ore_data.opacity])


## Builds a chunk's mesh-entry dict from its bucketed cells.
func _build_chunk_mesh_entry(by_tex: Dictionary, ore_by_tex: Dictionary, colored_cells: Array) -> Dictionary:
	var entry: Dictionary = {"tex": [], "ore": [], "color": null}
	for tex in by_tex:
		var mesh: ArrayMesh = _build_flat_quad_mesh(by_tex[tex])
		if mesh != null:
			entry["tex"].append({"texture": tex, "mesh": mesh})
	for tex in ore_by_tex:
		var mesh: ArrayMesh = _build_flat_quad_mesh(ore_by_tex[tex])
		if mesh != null:
			entry["ore"].append({"texture": tex, "mesh": mesh})
	if not colored_cells.is_empty():
		entry["color"] = _build_colored_quad_mesh(colored_cells)
	return entry


func _chunk_entry_empty(entry: Dictionary) -> bool:
	return entry["tex"].is_empty() and entry["ore"].is_empty() and entry["color"] == null


## Like `_build_flat_quad_mesh` but takes a per-cell color so untextured
## tiles render with their authored `data.color`. Drawn without a
## texture so the vertex color is the final pixel colour.
func _build_colored_quad_mesh(cells: Array) -> ArrayMesh:
	var n: int = cells.size()
	if n == 0:
		return null
	var gs: float = float(main.GRID_SIZE)
	var verts: PackedVector3Array = PackedVector3Array()
	verts.resize(n * 4)
	var cols: PackedColorArray = PackedColorArray()
	cols.resize(n * 4)
	var idxs: PackedInt32Array = PackedInt32Array()
	idxs.resize(n * 6)
	var vi: int = 0
	var ii: int = 0
	for entry in cells:
		var pos: Vector2i = entry[0]
		var col: Color = entry[1]
		var opac: float = float(entry[2])
		col.a = opac
		var wx: float = float(pos.x) * gs
		var wy: float = float(pos.y) * gs
		verts[vi + 0] = Vector3(wx, wy, 0.0)
		verts[vi + 1] = Vector3(wx + gs, wy, 0.0)
		verts[vi + 2] = Vector3(wx + gs, wy + gs, 0.0)
		verts[vi + 3] = Vector3(wx, wy + gs, 0.0)
		cols[vi + 0] = col
		cols[vi + 1] = col
		cols[vi + 2] = col
		cols[vi + 3] = col
		idxs[ii + 0] = vi + 0
		idxs[ii + 1] = vi + 1
		idxs[ii + 2] = vi + 2
		idxs[ii + 3] = vi + 0
		idxs[ii + 4] = vi + 2
		idxs[ii + 5] = vi + 3
		vi += 4
		ii += 6
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idxs
	var m: ArrayMesh = ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


## Builds a single ArrayMesh that covers every faded floor tile with a
## per-corner gradient quad. Called whenever _fade_darkness is regenerated.
func _rebuild_fade_mesh() -> void:
	_fade_mesh = null
	if _fade_darkness.is_empty():
		return
	var gs := float(main.GRID_SIZE)
	var count: int = _fade_darkness.size()
	var verts: PackedVector3Array = PackedVector3Array()
	verts.resize(count * 4)
	var cols: PackedColorArray = PackedColorArray()
	cols.resize(count * 4)
	var idxs: PackedInt32Array = PackedInt32Array()
	idxs.resize(count * 6)
	var vi: int = 0
	var ii: int = 0
	for grid_pos in _fade_darkness:
		var cd: Array = _fade_darkness[grid_pos]
		var wx: float = float(grid_pos.x) * gs
		var wy: float = float(grid_pos.y) * gs
		verts[vi + 0] = Vector3(wx, wy, 0.0)
		verts[vi + 1] = Vector3(wx + gs, wy, 0.0)
		verts[vi + 2] = Vector3(wx + gs, wy + gs, 0.0)
		verts[vi + 3] = Vector3(wx, wy + gs, 0.0)
		cols[vi + 0] = Color(0, 0, 0, cd[0])
		cols[vi + 1] = Color(0, 0, 0, cd[1])
		cols[vi + 2] = Color(0, 0, 0, cd[2])
		cols[vi + 3] = Color(0, 0, 0, cd[3])
		idxs[ii + 0] = vi + 0
		idxs[ii + 1] = vi + 1
		idxs[ii + 2] = vi + 2
		idxs[ii + 3] = vi + 0
		idxs[ii + 4] = vi + 2
		idxs[ii + 5] = vi + 3
		vi += 4
		ii += 6
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idxs
	_fade_mesh = ArrayMesh.new()
	_fade_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	if _fade_canvas != null:
		_fade_canvas.queue_redraw()




## Returns the effective edge distance for a position (for per-corner interpolation).
## Void/hidden tiles return 0 (edge). Walls block floor fade and stay bright;
## the wall renderer handles any wall-specific edge treatment.
func _get_floor_eff_dist(pos: Vector2i) -> float:
	var ss = _sector_script_ref()
	if wall_tiles.has(pos):
		return float(FLOOR_FADE_START)
	if ss and ss.is_tile_hidden(pos):
		# Hidden floors only fade if directly adjacent to a visible floor (4-connected).
		# Otherwise they're behind walls and shouldn't bleed darkness through diagonals.
		if floor_tiles.has(pos):
			var has_visible_floor_neighbor := false
			for offset in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]:
				var nb = pos + offset
				if floor_tiles.has(nb) and not ss.is_tile_hidden(nb):
					has_visible_floor_neighbor = true
					break
			if not has_visible_floor_neighbor:
				return float(FLOOR_FADE_START)
		return 0.0
	if not floor_tiles.has(pos):
		return 0.0  # Void = edge (darkest)
	if not _floor_edge_distance.has(pos):
		return float(FLOOR_FADE_START)  # Interior floor = fully bright
	return float(_floor_edge_distance[pos])


## Returns per-corner darkness values [tl, tr, br, bl] for a floor tile.
## Each corner averages the edge distances of the 4 tiles meeting there.
func _get_floor_corner_darkness(grid_pos: Vector2i) -> Array:
	var d0: float = _get_floor_eff_dist(grid_pos)
	var d_n: float = _get_floor_eff_dist(grid_pos + Vector2i(0, -1))
	var d_s: float = _get_floor_eff_dist(grid_pos + Vector2i(0, 1))
	var d_e: float = _get_floor_eff_dist(grid_pos + Vector2i(1, 0))
	var d_w: float = _get_floor_eff_dist(grid_pos + Vector2i(-1, 0))
	var d_nw: float = _get_diagonal_floor_eff_dist(grid_pos, Vector2i(-1, -1))
	var d_ne: float = _get_diagonal_floor_eff_dist(grid_pos, Vector2i(1, -1))
	var d_se: float = _get_diagonal_floor_eff_dist(grid_pos, Vector2i(1, 1))
	var d_sw: float = _get_diagonal_floor_eff_dist(grid_pos, Vector2i(-1, 1))

	var fade_start_f: float = float(FLOOR_FADE_START)
	var tl_avg: float = (d0 + d_n + d_w + d_nw) / 4.0
	var tr_avg: float = (d0 + d_n + d_e + d_ne) / 4.0
	var br_avg: float = (d0 + d_s + d_e + d_se) / 4.0
	var bl_avg: float = (d0 + d_s + d_w + d_sw) / 4.0

	var _to_dark = func(avg: float) -> float:
		if avg >= fade_start_f:
			return 0.0  # Interior = no darkness
		return clampf(1.0 - avg / fade_start_f, 0.0, 1.0)

	return [_to_dark.call(tl_avg), _to_dark.call(tr_avg), _to_dark.call(br_avg), _to_dark.call(bl_avg)]


## Diagonal void should not darken a floor corner when a wall occupies either
## orthogonal cell between that floor and the diagonal. This prevents fade
## bleeding around/through wall corners.
func _get_diagonal_floor_eff_dist(origin: Vector2i, diag: Vector2i) -> float:
	var side_a := origin + Vector2i(diag.x, 0)
	var side_b := origin + Vector2i(0, diag.y)
	if wall_tiles.has(side_a) or wall_tiles.has(side_b):
		return float(FLOOR_FADE_START)
	return _get_floor_eff_dist(origin + diag)


# =========================
# DRAWING
# =========================

func _draw() -> void:
	# Water depth bake is lazy through get_water_depth_at(), but the
	# renderer reads _water_depth_t directly — force a rebuild here if
	# dirty so the fade shows on first paint (editor, post-load, or after
	# bulk terrain edits) instead of only after the first gameplay query.
	# Rebuilt before the floor meshes so they exclude water cells correctly.
	# Also a full-map flood-fill, so it's deferred mid-stroke alongside the
	# edge-fade pass; newly painted water shows flat until the stroke ends.
	if _water_depth_dirty and not defer_floor_fade:
		_rebuild_water_depth()
		_water_mesh_dirty = false   # full recompute already rebuilt the mesh
	elif _water_mesh_dirty:
		# Mid-stroke prune: coalesced cheap water-mesh rebuild (water cells
		# only, no flood-fill). Runs at most once per frame regardless of how
		# many cells the stroke painted over water this frame.
		_water_mesh_dirty = false
		_rebuild_water_meshes()
	if _slag_mesh_dirty:
		_slag_mesh_dirty = false
		_rebuild_slag_meshes()
	# Rebuild floor-tile geometry meshes so newly painted/erased tiles show up.
	# A full rebuild (load / bulk edit / fog reveal) wins; otherwise only the
	# chunks touched by recent tile edits are re-baked (~256 cells each), so a
	# fast paint drag over a big map no longer rebuilds all ~14k quads per frame.
	if _floor_geom_dirty:
		_floor_geom_dirty = false
		_rebuild_floor_meshes()
		_slag_mesh_dirty = false
		_rebuild_slag_meshes()
	elif not _floor_dirty_chunks.is_empty():
		for ch in _floor_dirty_chunks:
			_rebuild_floor_chunk(ch)
		_floor_dirty_chunks.clear()
	# Expensive pass: edge-fade distance BFS + per-corner darkness bake +
	# fade mesh. Deferrable mid-stroke in the editor (see `defer_floor_fade`)
	# so this O(floor_tiles) work runs once per stroke, not once per frame.
	if _floor_edge_dirty and not defer_floor_fade:
		_rebuild_floor_edge_cache()
	_draw_floor_tiles()
	_draw_multi_tiles()
	# Keep the edge-fade overlay (its own z=2 canvas) in sync with this
	# terrain repaint — covers camera moves, terrain edits, and fade toggles.
	if _fade_canvas != null:
		_fade_canvas.queue_redraw()

	if paint_mode and selected_tile != &"":
		_draw_paint_preview()


## Renders steam puffs onto the given canvas. Called by the overlay node so
## the puffs sit above the building layer, yet a vent turbine placed on top
## of the vent still shows the steam escaping from its top.
func draw_vent_particles_to(canvas: CanvasItem) -> void:
	if _vent_particles.is_empty() or canvas == null:
		return
	var ss := _sector_script_ref()
	var gs: float = float(main.GRID_SIZE)
	var tex: Texture2D = _vent_steam_tex
	var native_size: Vector2 = tex.get_size() if tex else Vector2.ZERO
	for p in _vent_particles:
		var t: float = clampf(p["age"] / p["life"], 0.0, 1.0)
		if ss:
			var cell := Vector2i(int(p["pos"].x / gs), int(p["pos"].y / gs))
			if ss.has_method("is_tile_hidden") and ss.is_tile_hidden(cell):
				continue
		# Ease in over the first ~20% of life so new sprites grow/fade in
		# smoothly instead of popping in at full size and opacity. Ease out
		# over the rest of the life with smoothstep for a soft dissipation.
		var fade_in: float = smoothstep(0.0, 0.2, t)
		var fade_out: float = 1.0 - smoothstep(0.35, 1.0, t)
		# Per-particle base color (geyser droplets override). Vent
		# steam keeps the original tan tint via the default.
		var base_col: Color = p.get("color", VENT_PARTICLE_COLOR)
		var alpha: float = base_col.a * fade_in * fade_out
		# Geyser droplets keep a roughly constant size (water beads
		# don't billow), vent steam grows from 0.55× to 1.8×.
		var circle_only: bool = bool(p.get("circle_only", false))
		var radius: float
		if circle_only:
			radius = float(p["radius"]) * lerp(1.0, 0.7, t)
		else:
			radius = float(p["radius"]) * lerp(0.55, 1.8, smoothstep(0.0, 1.0, t))
		var col := Color(base_col.r, base_col.g, base_col.b, alpha)
		if not circle_only and tex and native_size.x > 0.0 and native_size.y > 0.0:
			var aspect: Vector2 = p.get("aspect", Vector2.ONE)
			var size: Vector2 = Vector2(radius * 2.0, radius * 2.0) * aspect
			var angle: float = float(p.get("angle", 0.0))
			# Draw rotated around the particle center so stacked sprites at
			# different angles don't all share the same silhouette.
			canvas.draw_set_transform(p["pos"], angle)
			canvas.draw_texture_rect(tex, Rect2(-size * 0.5, size), false, col)
			canvas.draw_set_transform(Vector2.ZERO, 0.0)
		else:
			canvas.draw_circle(p["pos"], radius, col)


## Returns the visible grid bounds based on the camera viewport.
func _get_visible_bounds() -> Rect2i:
	var camera = get_viewport().get_camera_2d()
	if not camera:
		return Rect2i(0, 0, main.GRID_WIDTH, main.GRID_HEIGHT)
	var vp_size = get_viewport().get_visible_rect().size
	var cam_zoom = camera.zoom if camera else Vector2.ONE
	var cam_center = camera.get_screen_center_position()
	var half_view = vp_size / (2.0 * cam_zoom)
	var gs = float(main.GRID_SIZE)
	var margin_tiles := 2
	var min_x: int = maxi(0, int((cam_center.x - half_view.x) / gs) - margin_tiles)
	var min_y: int = maxi(0, int((cam_center.y - half_view.y) / gs) - margin_tiles)
	var max_x: int = mini(main.GRID_WIDTH - 1, int((cam_center.x + half_view.x) / gs) + margin_tiles)
	var max_y: int = mini(main.GRID_HEIGHT - 1, int((cam_center.y + half_view.y) / gs) + margin_tiles)
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


## Draws all regular (1x1) floor tiles.
func _draw_floor_tiles() -> void:

	# Batched floor pass, per chunk: a few draw_mesh calls per on-screen chunk.
	# Off-screen chunks are skipped entirely (cheaper than relying on GPU
	# triangle culling of one giant full-map mesh). Two passes keep the
	# base→sand→ore layering: all chunk bases first, then the sand underlay,
	# then all chunk ores.
	var white := _ensure_white_pixel_tex()
	var vis: Rect2i = _get_visible_bounds()
	# Visible bounds in chunk space (inclusive), padded by one chunk for safety.
	var c_min := Vector2i((vis.position.x / FLOOR_CHUNK) - 1, (vis.position.y / FLOOR_CHUNK) - 1)
	var c_max := Vector2i(((vis.position.x + vis.size.x) / FLOOR_CHUNK) + 1, ((vis.position.y + vis.size.y) / FLOOR_CHUNK) + 1)
	for ch in _floor_chunk_meshes:
		if ch.x < c_min.x or ch.x > c_max.x or ch.y < c_min.y or ch.y > c_max.y:
			continue
		var entry: Dictionary = _floor_chunk_meshes[ch]
		if entry["color"] != null:
			draw_mesh(entry["color"], white)
		for bucket in entry["tex"]:
			draw_mesh(bucket["mesh"], bucket["texture"])

	# Sand underlay stays on the terrain canvas (no shader). Water
	# meshes have moved to `_water_canvas`, which paints them with
	# the scrolling-UV shader (`_draw_water_layer`).
	for sbucket in _sand_meshes:
		draw_mesh(sbucket["mesh"], sbucket["texture"])

	# Floor ores layered over the base floor (surface coal etc.) —
	# wall-embedded ores keep their own path through BuildingSystem.
	for ch in _floor_chunk_meshes:
		if ch.x < c_min.x or ch.x > c_max.x or ch.y < c_min.y or ch.y > c_max.y:
			continue
		for bucket in _floor_chunk_meshes[ch]["ore"]:
			draw_mesh(bucket["mesh"], bucket["texture"])

	# NOTE: the edge-fade is NOT drawn here anymore. It now lives on the
	# dedicated `_fade_canvas` (z=2) so the dark gradient overlays the water
	# surface too — when it was drawn on this canvas (z=0) the water layer
	# (z=1) painted over it and water sectors lost their edge fade entirely.
	# See `_draw_fade_layer`.



## Draws 3x3 multi-tiles (Geyser, Vent).
## The origin cell is opaque. The 8 surrounding cells are semi-transparent
## so floor tiles underneath still show through.
func _draw_multi_tiles() -> void:
	var drawn_origins := {}
	var _ss_multi = _sector_script_ref()
	var bounds: Rect2i = _get_visible_bounds()
	# Expand bounds by multi-tile size (3) to catch origins just off screen
	var mb: Rect2i = Rect2i(bounds.position - Vector2i(3, 3), bounds.size + Vector2i(6, 6))

	for cell_pos in multi_tile_origins:
		var origin = multi_tile_origins[cell_pos]
		if drawn_origins.has(origin):
			continue
		drawn_origins[origin] = true

		# Screen culling
		if origin.x < mb.position.x or origin.x >= mb.position.x + mb.size.x:
			continue
		if origin.y < mb.position.y or origin.y >= mb.position.y + mb.size.y:
			continue

		# Skip hidden multi-tiles (vents, geysers)
		if _ss_multi and _ss_multi.is_tile_hidden(origin):
			continue

		if not floor_tiles.has(origin):
			continue
		var tile_id = floor_tiles[origin]
		var data = Registry.get_tile(tile_id)
		if data == null:
			continue

		var size = float(main.GRID_SIZE)
		var origin_world = main.grid_to_world(origin)
		var top_left = origin_world - Vector2(size, size)
		var full_size = size * 3.0

		# Draw floor tiles underneath the 8 non-origin cells
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var cell = origin + Vector2i(dx, dy)
				if floor_tiles.has(cell) and not multi_tile_origins.has(cell):
					var cw = main.grid_to_world(cell)
					var cdata = Registry.get_tile(floor_tiles[cell])
					if cdata:
						_draw_tile_texture(cdata, cw, size, cdata.opacity)

		# Draw one texture across the full 3x3 area
		var rect = Rect2(top_left, Vector2(full_size, full_size))
		if data.icon:
			draw_texture_rect(data.icon, rect, false, Color(1, 1, 1, data.opacity))
		else:
			var color = data.color
			color.a = data.opacity
			draw_rect(rect, color, true)




## Draws a tile using its texture if available, falling back to color.
func _draw_tile_texture(data: TerrainTileData, pos: Vector2, size: float, alpha: float) -> void:
	var rect = Rect2(pos, Vector2(size, size))
	if data.icon:
		var tint = Color(1, 1, 1, alpha)
		draw_texture_rect(data.icon, rect, false, tint)
	else:
		var color = data.color
		color.a = alpha
		draw_rect(rect, color, true)



func _draw_paint_preview() -> void:
	var grid_pos = main.world_to_grid(get_global_mouse_position())
	if not main.is_within_bounds(grid_pos):
		return

	var data = Registry.get_tile(selected_tile)
	if data == null:
		return

	var world_pos = main.grid_to_world(grid_pos)
	var size = float(main.GRID_SIZE)
	var preview_color = data.color
	preview_color.a = 0.5

	if _is_multi_tile(selected_tile):
		# Show 3x3 preview
		var top_left = world_pos - Vector2(size, size)
		draw_rect(Rect2(top_left, Vector2(size * 3, size * 3)), preview_color, true)
		draw_rect(Rect2(top_left, Vector2(size * 3, size * 3)), Color(1, 1, 1, 0.3), false, 2.0)
		# Highlight origin cell
		draw_rect(Rect2(world_pos, Vector2(size, size)), preview_color.lightened(0.2), true)
	else:
		draw_rect(Rect2(world_pos, Vector2(size, size)), preview_color, true)
		draw_rect(Rect2(world_pos, Vector2(size, size)), Color(1, 1, 1, 0.3), false, 2.0)
