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

# --- WATER RENDERING ---
## Sand texture drawn under water at shallow/medium depths.
var _sand_texture: Texture2D = null

func _ready() -> void:
	_sand_texture = load("res://textures/terrain/Sand.png") if ResourceLoader.exists("res://textures/terrain/Sand.png") else null
	await get_tree().process_frame


func _process(_delta: float) -> void:
	# Always redraw so wall parallax updates with camera movement
	queue_redraw()


func _input(event: InputEvent) -> void:
	if not paint_mode or selected_tile == &"":
		return

	if event is InputEventMouseButton:
		if event.pressed:
			var grid_pos = main.world_to_grid(get_global_mouse_position())
			if not main.is_within_bounds(grid_pos):
				return
			if event.button_index == MOUSE_BUTTON_LEFT:
				place_tile(grid_pos, selected_tile)
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				remove_tile(grid_pos)

	elif event is InputEventMouseMotion:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and selected_tile != &"":
			var grid_pos = main.world_to_grid(get_global_mouse_position())
			if main.is_within_bounds(grid_pos):
				place_tile(grid_pos, selected_tile)
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			var grid_pos = main.world_to_grid(get_global_mouse_position())
			if main.is_within_bounds(grid_pos):
				remove_tile(grid_pos)


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
		var unit_mgr = get_node_or_null("/root/Main/UnitManager")
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
			var unit_mgr = get_node_or_null("/root/Main/UnitManager")
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
## nearest non-water floor tile (including void / wall edges).
##   distance 1 from land → depth 1 (shallow)
##   distance 2           → depth 2 (medium)
##   distance 3+          → depth 3 (deep)
func _rebuild_water_depth() -> void:
	_water_depth_dirty = false
	_water_depth_map.clear()

	# 1. Identify all water cells and seed the BFS with non-water floor
	#    cells that are adjacent to at least one water cell.
	var water_cells := {}  # all floor cells that are water
	for pos in floor_tiles:
		var td = Registry.get_tile(floor_tiles[pos])
		if td and td.is_liquid and td.tags.has("water"):
			water_cells[pos] = true

	if water_cells.is_empty():
		return

	# BFS seed: every water cell that is adjacent to a non-water cell
	# (non-water = no floor tile, or floor tile without "water" tag, or wall).
	var dist: Dictionary = {}  # Vector2i → int distance from land
	var queue: Array[Vector2i] = []
	var neighbors := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

	for pos in water_cells:
		for nb in neighbors:
			var adj: Vector2i = pos + nb
			if not water_cells.has(adj):
				# This water cell borders land/void → distance 1
				if not dist.has(pos):
					dist[pos] = 1
					queue.append(pos)
				break

	# 2. BFS outward: each unvisited water neighbor gets distance + 1.
	var head := 0
	while head < queue.size():
		var pos: Vector2i = queue[head]
		head += 1
		var d: int = dist[pos]
		for nb in neighbors:
			var adj: Vector2i = pos + nb
			if water_cells.has(adj) and not dist.has(adj):
				dist[adj] = d + 1
				queue.append(adj)

	# 3. Map distance to depth tiers and store.
	#   dist 1-4  → depth 1 (shallow)
	#   dist 5-8  → depth 2 (medium)
	#   dist 9+   → depth 3 (deep)
	for pos in dist:
		var d: int = dist[pos]
		if d <= 4:
			_water_depth_map[pos] = 1
		elif d <= 8:
			_water_depth_map[pos] = 2
		else:
			_water_depth_map[pos] = 3


## Rebuild the floor-edge distance cache (BFS inward from edges).
func _rebuild_floor_edge_cache() -> void:
	_floor_edge_dirty = false
	_floor_edge_distance.clear()
	var sector_script = get_node_or_null("/root/Main/SectorScript")
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
			# A wall neighbor lets the fade through if the wall itself borders
			# void on any side (it's an edge wall, not an interior wall).
			var nb_is_edge_wall := false
			if wall_tiles.has(nb) and not floor_tiles.has(nb):
				for wo in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]:
					var wnb = nb + wo
					if not floor_tiles.has(wnb) and not wall_tiles.has(wnb):
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


## Returns the fade alpha for a floor tile (1.0 = fully visible, 0.0 = fully dark).
## Floors within FLOOR_FADE_START tiles of void fade to black.
func _get_floor_fade_alpha(grid_pos: Vector2i) -> float:
	var sector_script = get_node_or_null("/root/Main/SectorScript")
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
## Void/hidden tiles return 0 (edge). Wall tiles return FLOOR_FADE_START (bright, wall system handles fade).
func _get_floor_eff_dist(pos: Vector2i) -> float:
	var ss = get_node_or_null("/root/Main/SectorScript")
	if ss and ss.is_tile_hidden(pos):
		# Hidden walls still count as walls for floor fade
		if wall_tiles.has(pos):
			return float(FLOOR_FADE_START)
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
		return float(FLOOR_FADE_START)  # Walls are bright — wall system handles its own fade
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
	var sector_script = get_node_or_null("/root/Main/SectorScript")
	var bounds: Rect2i = _get_visible_bounds()
	var fade_off: bool = "fade_enabled" in main and not main.fade_enabled
	var size = float(main.GRID_SIZE)

	for grid_pos in floor_tiles:
		# Screen culling — skip tiles outside camera view
		if grid_pos.x < bounds.position.x or grid_pos.x >= bounds.position.x + bounds.size.x:
			continue
		if grid_pos.y < bounds.position.y or grid_pos.y >= bounds.position.y + bounds.size.y:
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

		# Pre-baked fade overlay (skip if fade disabled or no darkness at this tile)
		if fade_off:
			continue
		if not _fade_darkness.has(grid_pos):
			continue
		var cd: Array = _fade_darkness[grid_pos]
		var pts: PackedVector2Array = [
			world_pos,
			world_pos + Vector2(size, 0),
			world_pos + Vector2(size, size),
			world_pos + Vector2(0, size),
		]
		var cols: PackedColorArray = [
			Color(0, 0, 0, cd[0]),
			Color(0, 0, 0, cd[1]),
			Color(0, 0, 0, cd[2]),
			Color(0, 0, 0, cd[3]),
		]
		draw_polygon(pts, cols)


## Draws 3x3 multi-tiles (Geyser, Vent).
## The origin cell is opaque. The 8 surrounding cells are semi-transparent
## so floor tiles underneath still show through.
func _draw_multi_tiles() -> void:
	var drawn_origins := {}
	var _ss_multi = get_node_or_null("/root/Main/SectorScript")
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
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
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
		var building_sys = get_node_or_null("/root/Main/BuildingSystem")
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
