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

# --- WATER DEPTH ---
## Auto-computed water depth for each water floor tile: Vector2i → int (1-3).
## Distance from the nearest non-water floor tile. Recomputed when floor tiles change.
var _water_depth_map: Dictionary = {}  # Vector2i -> int
var _water_depth_dirty := true
## Floor tiles within fewer than this distance of void start fading (higher = wider fade)
const FLOOR_FADE_START := 6
## How many tiles into a hidden region the fade extends
const HIDDEN_FADE_TILES := 2
## Pre-baked per-corner darkness for each floor tile. Rebuilt when _floor_edge_dirty.
var _fade_darkness: Dictionary = {}  # Vector2i -> [tl, tr, br, bl]

## Prebuilt mesh that batches every faded floor quad. Rebuilt alongside
## _fade_darkness whenever _floor_edge_dirty flips, so the per-frame cost is
## a single draw_mesh call instead of one draw_polygon per faded tile.
var _fade_mesh: ArrayMesh = null

# --- WATER RENDERING ---
## Sand texture drawn under water at shallow/medium depths.
var _sand_texture: Texture2D = null

# --- VENT PARTICLES ---
## Live steam-puff particles emitted from vent tiles.
## Each entry: { "pos": Vector2, "vel": Vector2, "age": float,
##               "life": float, "radius": float }
var _vent_particles: Array = []
## Per-vent-origin emission timer: Vector2i -> seconds until next puff.
var _vent_emit_timers: Dictionary = {}
## Average seconds between emissions per vent. Tuned with VENT_PARTICLE_LIFE
## so each vent continually has several sprites in flight, forming a
## continuous stream rather than discrete puffs.
const VENT_EMIT_INTERVAL := 0.22
## How many sprites spawn per emission.
const VENT_PARTICLES_PER_PUFF := 1
## Lifetime of a particle in seconds. Longer = taller stream tail.
const VENT_PARTICLE_LIFE := 1.8
## Starting upward speed in pixels per second.
const VENT_PARTICLE_SPEED := 22.0
## Starting half-size in pixels (sprite renders at 2× this).
const VENT_PARTICLE_RADIUS := 44.0
## Modulate color for the steam sprite. Slight yellow/tan so the puff reads
## as hot vent gas rather than plain white steam (same trick the tech-tree
## checkmark uses — draw_texture's modulate tints the whole texture).
const VENT_PARTICLE_COLOR := Color(1.0, 0.95, 0.75, 0.75)
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
		# z_index sandwich: buildings sit at 0, steam at 1 (just above),
		# and units/bullets/drone get bumped to 2 below so they draw over
		# the steam. This keeps smoke floating above the vent/turbine
		# without hiding flying units or projectiles.
		overlay.z_index = 1
		overlay.z_as_relative = false
		add_child(overlay)
	await get_tree().process_frame
	_sector_script = get_node_or_null("/root/Main/SectorScript")
	_building_sys = get_node_or_null("/root/Main/BuildingSystem")
	_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	# Promote the "things that should draw over steam" layers now that the
	# scene is up. Safe if any of these are missing.
	for node_path in ["/root/Main/UnitManager", "/root/Main/CombatSystem", "/root/Main/PlayerDrone"]:
		var n = get_node_or_null(node_path)
		if n is CanvasItem:
			(n as CanvasItem).z_index = 2


func _process(delta: float) -> void:
	# Always redraw so wall parallax updates with camera movement
	_tick_vent_particles(delta)
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
			if floor_tiles[origin] != &"vent":
				continue
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
			# Slight drag so puffs decelerate as they dissipate.
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
		# Ore can only be placed on a wall
		if not wall_tiles.has(grid_pos):
			return
		ore_tiles[grid_pos] = tile_id
	elif data.is_wall():
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
		if unit_mgr:
			unit_mgr._recompute_crawler_wall_passability()
		walls_changed.emit()
		_floor_edge_dirty = true
		_water_depth_dirty = true
	else:
		floor_tiles[grid_pos] = tile_id
		_floor_edge_dirty = true
		_water_depth_dirty = true

	queue_redraw()


func remove_tile(grid_pos: Vector2i) -> void:
	if multi_tile_origins.has(grid_pos):
		_remove_multi_tile(multi_tile_origins[grid_pos])
		queue_redraw()
		return

	# Remove top layer first: ore → wall → floor
	if ore_tiles.has(grid_pos):
		ore_tiles.erase(grid_pos)
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
		floor_tiles.erase(grid_pos)
		_floor_edge_dirty = true
		_water_depth_dirty = true
	else:
		return

	queue_redraw()


func damage_tile(grid_pos: Vector2i, amount: float) -> void:
	if not tile_health.has(grid_pos):
		return
	tile_health[grid_pos] -= amount
	if tile_health[grid_pos] <= 0:
		remove_tile(grid_pos)
	queue_redraw()


# =========================
# 3x3 MULTI-TILE (GEYSER / VENT)
# =========================

## Returns true if this tile ID should be placed as a 3x3.
func _is_multi_tile(tile_id: StringName) -> bool:
	var data = Registry.get_tile(tile_id)
	if not data:
		return false
	# Check display_name for "Geyser" or "Vent"
	return data.display_name == "Geyser" or data.display_name == "Vent"


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
	queue_redraw()


## Removes a 3x3 tile by its origin position.
func _remove_multi_tile(origin: Vector2i) -> void:
	# Clear all 9 cells from multi_tile_origins
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var cell = origin + Vector2i(dx, dy)
			multi_tile_origins.erase(cell)

	floor_tiles.erase(origin)


# =========================
# GETTERS
# =========================

## Returns the TerrainTileData at a position.
## Checks wall layer first (top), then floor layer.
func get_tile_at(grid_pos: Vector2i) -> TerrainTileData:
	if wall_tiles.has(grid_pos):
		return Registry.get_tile(wall_tiles[grid_pos])
	if floor_tiles.has(grid_pos):
		return Registry.get_tile(floor_tiles[grid_pos])
	return null


## Returns the floor tile at a position (ignoring walls).
func get_floor_at(grid_pos: Vector2i) -> TerrainTileData:
	if floor_tiles.has(grid_pos):
		return Registry.get_tile(floor_tiles[grid_pos])
	return null


## Returns the wall tile at a position (ignoring floors).
func get_wall_at(grid_pos: Vector2i) -> TerrainTileData:
	if wall_tiles.has(grid_pos):
		return Registry.get_tile(wall_tiles[grid_pos])
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


## Returns the auto-computed water depth at a position, or 0 if the tile
## isn't water. 1 = shallow, 2 = medium, 3 = deep.
## Computed via BFS distance from the nearest non-water floor tile.
func get_water_depth_at(grid_pos: Vector2i) -> int:
	if _water_depth_dirty:
		_rebuild_water_depth()
	return _water_depth_map.get(grid_pos, 0)


## Returns the speed modifier at a position.
## Walls override floor modifiers.
func get_speed_modifier(grid_pos: Vector2i) -> float:
	var wall_data = get_wall_at(grid_pos)
	if wall_data:
		return wall_data.speed_modifier
	var floor_data = get_floor_at(grid_pos)
	if floor_data:
		return floor_data.speed_modifier
	return 1.0


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

func enter_paint_mode() -> void:
	paint_mode = true
	main.select_building(&"")


func exit_paint_mode() -> void:
	paint_mode = false
	selected_tile = &""
	queue_redraw()


func select_tile(tile_id: StringName) -> void:
	selected_tile = tile_id
	enter_paint_mode()


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
		if sz > 0 and sz <= SMALL_ISLAND_TILES:
			if d <= 2:
				_water_depth_map[pos] = 1
			elif d <= 4:
				_water_depth_map[pos] = 2
			else:
				_water_depth_map[pos] = 3
		else:
			if d <= 3:
				_water_depth_map[pos] = 1
			elif d <= 6:
				_water_depth_map[pos] = 2
			else:
				_water_depth_map[pos] = 3


## Rebuild the floor-edge distance cache (BFS inward from edges).
func _rebuild_floor_edge_cache() -> void:
	_floor_edge_dirty = false
	_floor_edge_distance.clear()
	var sector_script = _sector_script_ref()
	# Seed: visible floor tiles adjacent to void or hidden tiles.
	# Walls only block the fade if they have floor behind them (interior walls).
	# Edge walls (walls with void on at least one side) let the fade through.
	var queue: Array[Vector2i] = []
	for grid_pos in floor_tiles:
		if sector_script and sector_script.is_tile_hidden(grid_pos):
			continue
		for offset in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]:
			var nb = grid_pos + offset
			var nb_is_void: bool = not floor_tiles.has(nb) and not wall_tiles.has(nb)
			# A wall neighbor lets the fade through if the wall borders void OR
			# a hidden tile on any side. Interior walls with visible floor on
			# all sides still block the fade.
			var nb_is_edge_wall := false
			if wall_tiles.has(nb) and not floor_tiles.has(nb):
				for wo in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]:
					var wnb = nb + wo
					# Void side
					if not floor_tiles.has(wnb) and not wall_tiles.has(wnb):
						nb_is_edge_wall = true
						break
					# Hidden side (hidden floor or hidden wall)
					if sector_script and sector_script.is_tile_hidden(wnb):
						nb_is_edge_wall = true
						break
			var nb_is_hidden: bool = sector_script != null and floor_tiles.has(nb) and not wall_tiles.has(nb) and sector_script.is_tile_hidden(nb)
			if nb_is_void or nb_is_edge_wall or nb_is_hidden:
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
			if floor_tiles.has(nb) and not _floor_edge_distance.has(nb):
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
		if sector_script and sector_script.is_tile_hidden(grid_pos):
			continue
		var cd: Array = _get_floor_corner_darkness(grid_pos)
		if cd[0] > 0.0 or cd[1] > 0.0 or cd[2] > 0.0 or cd[3] > 0.0:
			_fade_darkness[grid_pos] = cd

	# Rebuild the batched fade mesh so each frame only costs one draw call.
	_rebuild_fade_mesh()


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


## Returns the fade alpha for a floor tile (1.0 = fully visible, 0.0 = fully dark).
## Floors within FLOOR_FADE_START tiles of void fade to black.
func _get_floor_fade_alpha(grid_pos: Vector2i) -> float:
	var sector_script = _sector_script_ref()
	if sector_script and sector_script.is_tile_hidden(grid_pos):
		return 0.0
	if not _floor_edge_distance.has(grid_pos):
		return 1.0
	var dist: int = _floor_edge_distance[grid_pos]
	if dist >= FLOOR_FADE_START:
		return 1.0
	# dist 0 = at void edge (darkest), dist FLOOR_FADE_START = fully visible
	return clampf(float(dist) / float(FLOOR_FADE_START), 0.0, 1.0)


## Returns the effective edge distance for a position (for per-corner interpolation).
## Void/hidden tiles return 0 (edge). Walls contribute to fade if they border
## void or hidden tiles themselves (edge walls); interior walls stay bright.
func _get_floor_eff_dist(pos: Vector2i) -> float:
	var ss = _sector_script_ref()
	if ss and ss.is_tile_hidden(pos):
		# Hidden walls still count as walls for floor fade
		if wall_tiles.has(pos):
			return 0.0  # edge — let floor fade through
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
	if wall_tiles.has(pos):
		# Edge walls (bordering void or hidden) are treated as edges so the
		# floor fade bleeds through them. Interior walls with visible floor
		# on every side stay bright and don't affect adjacent fade.
		for offset in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]:
			var wnb = pos + offset
			if not floor_tiles.has(wnb) and not wall_tiles.has(wnb):
				return 0.0  # borders void
			if ss and ss.is_tile_hidden(wnb):
				return 0.0  # borders hidden
		return float(FLOOR_FADE_START)  # interior wall — wall system handles its own fade
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
	var d_nw: float = _get_floor_eff_dist(grid_pos + Vector2i(-1, -1))
	var d_ne: float = _get_floor_eff_dist(grid_pos + Vector2i(1, -1))
	var d_se: float = _get_floor_eff_dist(grid_pos + Vector2i(1, 1))
	var d_sw: float = _get_floor_eff_dist(grid_pos + Vector2i(-1, 1))

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


# =========================
# DRAWING
# =========================

func _draw() -> void:
	if _floor_edge_dirty:
		_rebuild_floor_edge_cache()
	_draw_floor_tiles()
	_draw_multi_tiles()

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
		var alpha: float = VENT_PARTICLE_COLOR.a * fade_in * fade_out
		# Radius eases from ~0.55× to ~1.8× over life. Starting smaller gives
		# the "building up" look instead of a sudden full-size appearance.
		var radius: float = float(p["radius"]) * lerp(0.55, 1.8, smoothstep(0.0, 1.0, t))
		var col := Color(VENT_PARTICLE_COLOR.r, VENT_PARTICLE_COLOR.g, VENT_PARTICLE_COLOR.b, alpha)
		if tex and native_size.x > 0.0 and native_size.y > 0.0:
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
	var sector_script = _sector_script_ref()
	var bounds: Rect2i = _get_visible_bounds()
	var fade_off: bool = "fade_enabled" in main and not main.fade_enabled
	var size = float(main.GRID_SIZE)


	# Iterate only the visible rectangle instead of the entire floor dict.
	# On huge maps this is O(visible) rather than O(all_floor_tiles).
	var bx0: int = bounds.position.x
	var by0: int = bounds.position.y
	var bx1: int = bx0 + bounds.size.x
	var by1: int = by0 + bounds.size.y
	for y in range(by0, by1):
		for x in range(bx0, bx1):
			var grid_pos: Vector2i = Vector2i(x, y)
			if not floor_tiles.has(grid_pos):
				continue

			var tile_id = floor_tiles[grid_pos]
			var data = Registry.get_tile(tile_id)
			if data == null:
				continue
			if multi_tile_origins.has(grid_pos) and multi_tile_origins[grid_pos] == grid_pos:
				continue
			if data.is_wall():
				continue
			var is_hidden: bool = sector_script and sector_script.is_tile_hidden(grid_pos)
			if is_hidden:
				continue

			var world_pos = main.grid_to_world(grid_pos)

			# Water tiles: draw sand underneath then water on top with depth-based
			# blend. Depth 1 = 50% sand / 50% water, depth 2 = 30% sand / 70% water,
			# depth 3 = 100% water (no sand visible).
			var depth: int = get_water_depth_at(grid_pos)
			if depth > 0 and _sand_texture != null:
				var rect := Rect2(world_pos, Vector2(size, size))
				if depth <= 2:
					var sand_alpha: float = 0.5 if depth == 1 else 0.3
					draw_texture_rect(_sand_texture, rect, false, Color(1, 1, 1, sand_alpha * data.opacity))
				# Water layer on top
				var water_alpha: float
				if depth == 1:
					water_alpha = 0.5
				elif depth == 2:
					water_alpha = 0.7
				else:
					water_alpha = 1.0
				_draw_tile_texture(data, world_pos, size, water_alpha * data.opacity)
			else:
				_draw_tile_texture(data, world_pos, size, data.opacity)

			# Fade overlay is now rendered in one batched draw_mesh after the
			# loop (see below). No per-tile fade work here.

	# Single draw call for all faded floor tiles, using a mesh rebuilt only
	# when _floor_edge_dirty flips. GPU culls off-screen triangles for free.
	if _fade_mesh and not fade_off:
		draw_mesh(_fade_mesh, null)



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

		if data.draw_border:
			draw_rect(rect, data.border_color, false, 2.0)


## Draws all wall tiles. If a wall has render_tile_underneath = true,
## the floor tile at that position is drawn first, then the wall on top.
func _draw_wall_tiles() -> void:
	var building_sys = _building_sys_ref()
	var camera = get_viewport().get_camera_2d()
	var cam_center = camera.get_screen_center_position() if camera else Vector2.ZERO

	# Sort walls so further ones draw first (painter's algorithm)
	var sorted_walls: Array[Vector2i] = []
	for grid_pos in wall_tiles:
		sorted_walls.append(grid_pos)
	sorted_walls.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var world_a = main.grid_to_world(a)
		var world_b = main.grid_to_world(b)
		return world_a.distance_squared_to(cam_center) > world_b.distance_squared_to(cam_center)
	)

	# --- PASS 1: Draw floor underneath + sides ---
	for grid_pos in sorted_walls:
		var tile_id = wall_tiles[grid_pos]
		var data = Registry.get_tile(tile_id)
		if data == null:
			continue

		var world_pos = main.grid_to_world(grid_pos)
		var size = float(main.GRID_SIZE)

		# If this wall allows the floor to show through, draw the floor first
		if data.render_tile_underneath and floor_tiles.has(grid_pos):
			var floor_data = Registry.get_tile(floor_tiles[grid_pos])
			if floor_data:
				_draw_tile_texture(floor_data, world_pos, size, floor_data.opacity)

		# Calculate parallax offset — use same offset as buildings so walls are flush
		var offset = Vector2.ZERO
		if building_sys and data.height > 0:
			offset = building_sys._get_top_offset(world_pos)

		if abs(offset.x) > 0.5 or abs(offset.y) > 0.5:
			var sc = data.get_side_color()
			var scd = data.get_side_color_dark()

			# Match building margin so walls sit flush with adjacent blocks
			var margin := -1.0
			var b_tl = world_pos + Vector2(margin, margin)
			var b_tr = world_pos + Vector2(size - margin, margin)
			var b_br = world_pos + Vector2(size - margin, size - margin)
			var b_bl = world_pos + Vector2(margin, size - margin)
			var t_tl = b_tl + offset
			var t_tr = b_tr + offset
			var t_br = b_br + offset
			var t_bl = b_bl + offset

			# Skip sides where an adjacent wall occludes them
			var has_south = wall_tiles.has(grid_pos + Vector2i(0, 1))
			var has_north = wall_tiles.has(grid_pos + Vector2i(0, -1))
			var has_east = wall_tiles.has(grid_pos + Vector2i(1, 0))
			var has_west = wall_tiles.has(grid_pos + Vector2i(-1, 0))

			# Bottom side (visible when camera above, offset.y < 0)
			if offset.y < 0 and not has_south:
				draw_polygon([b_bl, b_br, t_br, t_bl], [sc, sc, sc, sc])
			# Top side (visible when camera below, offset.y > 0)
			if offset.y > 0 and not has_north:
				draw_polygon([b_tl, b_tr, t_tr, t_tl], [sc, sc, sc, sc])
			# Right side (visible when camera left, offset.x < 0)
			if offset.x < 0 and not has_east:
				draw_polygon([b_tr, b_br, t_br, t_tr], [scd, scd, scd, scd])
			# Left side (visible when camera right, offset.x > 0)
			if offset.x > 0 and not has_west:
				draw_polygon([b_tl, b_bl, t_bl, t_tl], [scd, scd, scd, scd])

	# --- PASS 2: Draw all top faces ---
	for grid_pos in sorted_walls:
		var tile_id = wall_tiles[grid_pos]
		var data = Registry.get_tile(tile_id)
		if data == null:
			continue

		var world_pos = main.grid_to_world(grid_pos)
		var size = float(main.GRID_SIZE)

		var offset = Vector2.ZERO
		if building_sys and data.height > 0:
			offset = building_sys._get_top_offset(world_pos)

		var margin := -1.0
		var top_pos = world_pos + offset + Vector2(margin, margin)
		var top_size = size - margin * 2
		_draw_tile_texture(data, top_pos, top_size, 1.0)

		# Health bar for destructible walls
		if data.destructible and tile_health.has(grid_pos):
			var pct = tile_health[grid_pos] / data.max_health
			if pct < 1.0:
				_draw_tile_health_bar(top_pos, pct)

## Draws ore overlays on top of walls.
func _draw_ore_tiles() -> void:
	for grid_pos in ore_tiles:
		var tile_id = ore_tiles[grid_pos]
		var data = Registry.get_tile(tile_id)
		if data == null:
			continue

		var world_pos = main.grid_to_world(grid_pos)
		var size = float(main.GRID_SIZE)

		# Apply same parallax offset as the wall underneath
		var offset = Vector2.ZERO
		var building_sys = _building_sys_ref()
		if building_sys and wall_tiles.has(grid_pos):
			var wall_data = Registry.get_tile(wall_tiles[grid_pos])
			if wall_data and wall_data.height > 0:
				offset = building_sys._get_top_offset(world_pos)

		var top_pos = world_pos + offset
		_draw_tile_texture(data, top_pos, size, data.opacity)

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
	if data.draw_border:
		draw_rect(rect, data.border_color, false, 1.0)

func _draw_tile_health_bar(world_pos: Vector2, pct: float) -> void:
	var bar_w := 40.0
	var bar_h := 4.0
	var bar_pos = world_pos + Vector2((main.GRID_SIZE - bar_w) / 2.0, -8.0)
	draw_rect(Rect2(bar_pos, Vector2(bar_w, bar_h)), Color(0.2, 0, 0, 0.8), true)
	draw_rect(Rect2(bar_pos, Vector2(bar_w * pct, bar_h)), Color(1.0 - pct, pct, 0), true)


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
