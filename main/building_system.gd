extends Node2D

# ============================================================
# BUILDING_SYSTEM.GD - Building Placement & Rendering
# ============================================================
# All building properties (colors, health, etc.) now come from
# Registry.get_block(id) instead of hardcoded dictionaries.
#
# MULTI-TILE BUILDINGS:
# Buildings bigger than 1x1 (like the 3x3 core) are drawn as
# ONE large block instead of multiple small ones. main.gd tracks
# which cell is the "anchor" (top-left). Only anchor cells are
# drawn, and they draw at the full multi-tile size.
#
# ROTATION:
# Press Q while placing to rotate the building. Rotation is
# stored per-cell in main.building_rotation as an int:
#   0 = right →   1 = down ↓   2 = left ←   3 = up ↑
# This matters for conveyors (item flow direction) and drills
# (which direction they output mined items).
# ============================================================

@onready var main: Node2D = get_node("/root/Main")

# Faction enum values (mirrors main.gd Faction enum, avoids dynamic lookup issues)
const FACTION_LUMINA := 0
const FACTION_FEROX := 1
const FACTION_DERELICT := 2

# --- PARALLAX SETTINGS ---
@export var parallax_strength := 0.025
@export var max_depth := 8.0
@export var soft_cap_factor := 0.05

# --- ARCHIVE STATE ---
## Per-archive: anchor → archive_id (StringName). Empty string = no archive selected.
var archive_holdings: Dictionary = {}
## Per-archive-decoder: anchor → { progress: float, archive_id: StringName, scanner: Vector2i }
var archive_decoder_state: Dictionary = {}

# --- CRANE STATE ---
var crane_states: Dictionary = {}  # Vector2i anchor → {arm_angle, arm_extension, grabber_open, held_payload, target_pos}
const CRANE_ARM3_WIDTH := 14.0    # Innermost segment (extends first)
const CRANE_ARM2_WIDTH := 20.0    # Middle segment
const CRANE_ARM1_WIDTH := 26.0    # Outermost segment (base)
const CRANE_ARM3_MIN := 180.0     # Minimum length of segment 3
const CRANE_ARM2_MIN := 160.0     # Minimum length of segment 2
const CRANE_ARM1_MIN := 140.0     # Minimum length of segment 1
const CRANE_ARM3_MAX := 540.0     # Maximum length of segment 3 (extends first)
const CRANE_ARM2_MAX := 480.0     # Maximum length of segment 2 (extends second)
const CRANE_ARM1_MAX := 420.0     # Maximum length of segment 1 (extends last)
const CRANE_ARM_MIN_TOTAL := 480.0 # Sum of all minimums
const CRANE_GRABBER_SIZE := 28.0  # Half-length of each cross bar

# --- PREVIEW STATE ---
var preview_grid_pos := Vector2i.ZERO
var can_place := false

# Direction arrow constants (same as logistics_system)
const DIR_VECTORS := [
	Vector2i(1, 0),   # 0 = right
	Vector2i(0, 1),   # 1 = down
	Vector2i(-1, 0),  # 2 = left
	Vector2i(0, -1),  # 3 = up
]

const DIR_NAMES := ["→", "↓", "←", "↑"]

# --- BELT AUTO-TILE TEXTURES ---
# Loaded in _ready(). Used to pick the right visual based on neighboring belts.
var _belt_textures := {}

# --- PIPE / PUMP TEXTURES ---
var _pipe_texture: Texture2D
var _pump_texture: Texture2D

# --- CACHED REFERENCES ---
var _logistics: Node2D

# --- WORLD MENU STATE (sorter filter / constructor selection) ---
var _world_menu_open := false
var _world_menu_pos := Vector2i.ZERO  # Grid position of the block that opened the menu
var _world_menu_type := ""  # "sorter", "constructor", or "archive"
var _world_menu_items: Array = []  # Array of {id: StringName, icon: Texture2D, name: String}
var _world_menu_columns := 8
var _world_menu_cell_size := 44.0
var _world_menu_hovered := -1  # Index of hovered item, -1 = none

# --- WALL RENDER CACHE ---
## Cached set of wall positions (rebuilt when terrain changes)
var _cached_wall_set := {}
## Walls that have at least one exposed side or are on the edge (skip fully interior walls)
var _cached_visible_walls: Array[Vector2i] = []
## Dirty flag — set true when wall tiles change
var _walls_dirty := true

# --- WALL FADE SYSTEM ---
## Distance from each wall tile to the nearest floor tile (Chebyshev distance).
## Used to fade walls into noise the further they are from walkable areas.
var _wall_floor_distance: Dictionary = {}  # Vector2i -> int
## Pre-computed per-corner darkness values: Vector2i -> [tl, tr, br, bl]
## Only populated for walls that have non-zero darkness (saves memory + draw time).
var _cached_corner_darkness: Dictionary = {}  # Vector2i -> Array[float]
## Pre-computed effective distance for all relevant tiles (walls, floors, void neighbors).
var _cached_eff_dist: Dictionary = {}  # Vector2i -> float
## Walls within this many tiles of the nearest floor are fully visible (no darkness)
const WALL_FADE_START := 0
## Over how many additional tiles the fade goes from opaque to fully black
const WALL_FADE_RANGE := 3.0
## How many tiles into a hidden region the wall fade extends
const HIDDEN_WALL_FADE_TILES := 2
## Distance from each hidden wall to the nearest visible wall/floor
var _hidden_wall_distance: Dictionary = {}  # Vector2i -> int

# --- PAUSED PLACEMENT QUEUE ---
## Buildings queued during pause: Array of {grid_pos: Vector2i, block_id: StringName, rotation: int}
var _paused_queue: Array = []

# --- DRAG-PLACE STATE ---
## Whether the player is currently drag-placing blocks.
var _drag_placing := false
## Grid position where the drag started.
var _drag_start := Vector2i.ZERO
## Preview cells for the axis-locked line (computed each frame while dragging).
var _drag_cells: Array[Vector2i] = []

# --- SCHEMATIC CAPTURE STATE ---
var _schematic_mode := false
var _schematic_dragging := false
var _schematic_start := Vector2i.ZERO
var _schematic_end := Vector2i.ZERO
var _schematic_confirmed := false  # Rect finalized, waiting for Enter

# --- SCHEMATIC PLACEMENT STATE ---
var _placing_schematic := false
var _schematic_place_blocks: Dictionary = {}   # Vector2i (relative) -> StringName
var _schematic_place_rotation: Dictionary = {} # Vector2i (relative) -> int
var _schematic_place_width: int = 0
var _schematic_place_height: int = 0

# --- SCHEMATIC SAVE DIALOG ---
var _schematic_popup: PopupPanel = null

# --- REBUILD MODE STATE ---
var _rebuild_mode := false  # B key held
var _rebuild_dragging := false  # Dragging a selection rect
var _rebuild_start := Vector2i.ZERO
var _rebuild_end := Vector2i.ZERO
const REBUILD_COLOR := Color(0.816, 0.808, 0.886, 0.4)  # #D0CEE2

# --- PATHFIND DRAG STATE ---
var _pathfind_mode := false
var _pathfind_rotations: Dictionary = {}  # Vector2i -> int (per-cell rotation overrides)
var _pathfind_bridge_cells: Dictionary = {}  # Vector2i -> StringName (bridge block_id)
var _transport_astar: AStarGrid2D = null

# --- DEMOLISH DRAG STATE ---
## Whether the player is currently drag-selecting a rectangle to demolish.
var _demolish_dragging := false
## Grid position where the demolish drag started.
var _demolish_start := Vector2i.ZERO
## Grid position where the demolish drag currently ends (follows mouse).
var _demolish_end := Vector2i.ZERO

# --- LINKING STATE ---
## Whether the player is currently linking two blocks.
var linking_mode := false
## The first block selected for linking (or Vector2i(-1,-1) if none).
var link_source := Vector2i(-1, -1)


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_load_belt_textures()
	_load_pipe_texture()
	main.building_placed.connect(_on_building_placed)
	main.building_destroyed.connect(_on_building_destroyed)
	# Cache reference to logistics system (available after first frame)
	await get_tree().process_frame
	_logistics = get_node_or_null("/root/Main/LogisticsSystem")
	# Connect terrain changes to invalidate wall cache
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if terrain:
		terrain.connect("walls_changed", _on_walls_changed)


func _on_walls_changed() -> void:
	_walls_dirty = true


func _rebuild_wall_cache() -> void:
	_walls_dirty = false
	_cached_wall_set.clear()
	_cached_visible_walls.clear()
	_wall_floor_distance.clear()
	_cached_eff_dist.clear()
	_cached_corner_darkness.clear()
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if terrain == null:
		return
	for grid_pos in terrain.wall_tiles:
		if main.placed_buildings.has(grid_pos):
			continue
		_cached_wall_set[grid_pos] = true
		# Skip fully surrounded walls (all 4 cardinal neighbors are walls or buildings)
		var dominated := true
		for offset in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]:
			var nb = grid_pos + offset
			if not terrain.wall_tiles.has(nb) and not main.placed_buildings.has(nb):
				dominated = false
				break
		if not dominated:
			_cached_visible_walls.append(grid_pos)

	# BFS from all floor-adjacent walls to compute distance-to-floor for fade.
	# Hidden floors don't count — walls next to hidden floors stay dark.
	var sector_script_ref = get_node_or_null("/root/Main/SectorScript")
	var queue: Array[Vector2i] = []
	for grid_pos in _cached_wall_set:
		# Hidden walls should not seed the BFS
		if sector_script_ref and sector_script_ref.is_tile_hidden(grid_pos):
			continue
		for offset in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]:
			var nb = grid_pos + offset
			if terrain.floor_tiles.has(nb) and not terrain.wall_tiles.has(nb):
				# Don't seed from hidden floors
				if sector_script_ref and sector_script_ref.is_tile_hidden(nb):
					continue
				if not _wall_floor_distance.has(grid_pos):
					_wall_floor_distance[grid_pos] = 0
					queue.append(grid_pos)
				break
	var head := 0
	while head < queue.size():
		var pos: Vector2i = queue[head]
		head += 1
		var dist: int = _wall_floor_distance[pos]
		for offset in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]:
			var nb = pos + offset
			if _cached_wall_set.has(nb) and not _wall_floor_distance.has(nb):
				# Don't expand through hidden walls
				if sector_script_ref and sector_script_ref.is_tile_hidden(nb):
					continue
				_wall_floor_distance[nb] = dist + 1
				queue.append(nb)

	# Pre-compute effective distances for all wall tiles and their neighbors
	# (avoids repeated get_node_or_null + dictionary lookups during draw)
	var sector_script = get_node_or_null("/root/Main/SectorScript")
	var relevant_positions: Dictionary = {}
	for grid_pos in _cached_wall_set:
		relevant_positions[grid_pos] = true
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				relevant_positions[grid_pos + Vector2i(dx, dy)] = true

	for pos in relevant_positions:
		var pos_is_hidden: bool = sector_script_ref != null and sector_script_ref.is_tile_hidden(pos)
		if terrain.floor_tiles.has(pos) and not terrain.wall_tiles.has(pos) and not pos_is_hidden:
			_cached_eff_dist[pos] = -1.0
		elif _wall_floor_distance.has(pos):
			_cached_eff_dist[pos] = float(_wall_floor_distance[pos])
		else:
			_cached_eff_dist[pos] = 10.0

	# Pre-compute corner darkness for all wall tiles (only store non-zero entries)
	var fade_start_f := float(WALL_FADE_START)
	for grid_pos in _cached_wall_set:
		var d0: float = _cached_eff_dist.get(grid_pos, 10.0)
		# Quick skip: if this tile and all 8 neighbors are within fade start, no darkness
		if d0 <= fade_start_f:
			var all_bright := true
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					if _cached_eff_dist.get(grid_pos + Vector2i(dx, dy), 10.0) > fade_start_f:
						all_bright = false
						break
				if not all_bright:
					break
			if all_bright:
				continue

		var d_n: float = _cached_eff_dist.get(grid_pos + Vector2i(0, -1), 10.0)
		var d_s: float = _cached_eff_dist.get(grid_pos + Vector2i(0, 1), 10.0)
		var d_e: float = _cached_eff_dist.get(grid_pos + Vector2i(1, 0), 10.0)
		var d_w: float = _cached_eff_dist.get(grid_pos + Vector2i(-1, 0), 10.0)
		var d_nw: float = _cached_eff_dist.get(grid_pos + Vector2i(-1, -1), 10.0)
		var d_ne: float = _cached_eff_dist.get(grid_pos + Vector2i(1, -1), 10.0)
		var d_se: float = _cached_eff_dist.get(grid_pos + Vector2i(1, 1), 10.0)
		var d_sw: float = _cached_eff_dist.get(grid_pos + Vector2i(-1, 1), 10.0)

		var tl := _dist_to_darkness((d0 + d_n + d_w + d_nw) / 4.0)
		var tr := _dist_to_darkness((d0 + d_n + d_e + d_ne) / 4.0)
		var br := _dist_to_darkness((d0 + d_s + d_e + d_se) / 4.0)
		var bl := _dist_to_darkness((d0 + d_s + d_w + d_sw) / 4.0)

		if tl > 0.0 or tr > 0.0 or br > 0.0 or bl > 0.0:
			_cached_corner_darkness[grid_pos] = [tl, tr, br, bl]

	# Compute hidden wall distances (distance from visible walls/floors into hidden region)
	_hidden_wall_distance.clear()
	if sector_script_ref:
		var hqueue: Array[Vector2i] = []
		for grid_pos in terrain.wall_tiles:
			if not sector_script_ref.is_tile_hidden(grid_pos):
				continue
			for offset in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]:
				var nb = grid_pos + offset
				# Adjacent to a visible wall or visible floor = distance 0
				var nb_visible_wall: bool = terrain.wall_tiles.has(nb) and not sector_script_ref.is_tile_hidden(nb)
				var nb_visible_floor: bool = terrain.floor_tiles.has(nb) and not terrain.wall_tiles.has(nb) and not sector_script_ref.is_tile_hidden(nb)
				if nb_visible_wall or nb_visible_floor:
					_hidden_wall_distance[grid_pos] = 0
					hqueue.append(grid_pos)
					break
		var hhead := 0
		while hhead < hqueue.size():
			var pos2: Vector2i = hqueue[hhead]
			hhead += 1
			var hdist: int = _hidden_wall_distance[pos2]
			if hdist >= HIDDEN_WALL_FADE_TILES:
				continue
			for offset in [Vector2i(0,-1), Vector2i(0,1), Vector2i(-1,0), Vector2i(1,0)]:
				var nb = pos2 + offset
				if terrain.wall_tiles.has(nb) and sector_script_ref.is_tile_hidden(nb) and not _hidden_wall_distance.has(nb):
					_hidden_wall_distance[nb] = hdist + 1
					hqueue.append(nb)

		# Override corner darkness for hidden walls in the fade zone
		# Per-corner gradient: each corner uses the average hidden distance of its 4 neighboring tiles
		for grid_pos in _hidden_wall_distance:
			var _get_hdist = func(pos: Vector2i) -> float:
				if not sector_script_ref.is_tile_hidden(pos):
					return -1.0  # Visible tile = bright
				if _hidden_wall_distance.has(pos):
					return float(_hidden_wall_distance[pos])
				return float(HIDDEN_WALL_FADE_TILES + 1)  # Deep hidden = fully dark

			var d0: float = _get_hdist.call(grid_pos)
			var d_n: float = _get_hdist.call(grid_pos + Vector2i(0, -1))
			var d_s: float = _get_hdist.call(grid_pos + Vector2i(0, 1))
			var d_e: float = _get_hdist.call(grid_pos + Vector2i(1, 0))
			var d_w: float = _get_hdist.call(grid_pos + Vector2i(-1, 0))
			var d_nw: float = _get_hdist.call(grid_pos + Vector2i(-1, -1))
			var d_ne: float = _get_hdist.call(grid_pos + Vector2i(1, -1))
			var d_se: float = _get_hdist.call(grid_pos + Vector2i(1, 1))
			var d_sw: float = _get_hdist.call(grid_pos + Vector2i(-1, 1))

			var _corner_dark = func(avg_dist: float) -> float:
				if avg_dist < 0.0:
					return 0.0  # Visible neighbor influence
				return clampf(float(avg_dist + 1) / float(HIDDEN_WALL_FADE_TILES + 1), 0.0, 1.0)

			var tl: float = _corner_dark.call((d0 + d_n + d_w + d_nw) / 4.0)
			var tr: float = _corner_dark.call((d0 + d_n + d_e + d_ne) / 4.0)
			var br: float = _corner_dark.call((d0 + d_s + d_e + d_se) / 4.0)
			var bl: float = _corner_dark.call((d0 + d_s + d_w + d_sw) / 4.0)
			_cached_corner_darkness[grid_pos] = [tl, tr, br, bl]


## Loads the conveyor belt texture variants for auto-tiling.
func _load_belt_textures() -> void:
	var path := "res://textures/blocks/item transportation/Belt/"
	_belt_textures = {
		"straight": load(path + "Belt.png"),
		"jr": load(path + "Belt-JR.png"),   # Left wall removed (input from left)
		"jl": load(path + "Belt-JL.png"),   # Right wall removed (input from right)
		"ja": load(path + "Belt-JA.png"),   # Both walls removed
		"ca": load(path + "Belt-CA.png"),   # Corner variant A
		"cb": load(path + "Belt-CB.png"),   # Corner variant B
	}


## Loads the fluid conduit pipe and pump textures.
func _load_pipe_texture() -> void:
	_pipe_texture = load("res://textures/blocks/fluid transportation/FluidConduit.png")
	_pump_texture = load("res://textures/blocks/fluid transportation/FluidPump.png")


## Handles Q or R key to rotate, L key to toggle linking mode.
func _input(event: InputEvent) -> void:
	if main.has_method("is_ui_blocking") and main.is_ui_blocking():
		return
	# --- SCHEMATIC CAPTURE ---
	if event.is_action("schematic_capture") and not _placing_schematic:
		if event.is_action_pressed("schematic_capture") and not _schematic_mode:
			# Start dragging immediately from current mouse position
			var mw = get_global_mouse_position()
			_schematic_mode = true
			_schematic_confirmed = false
			_schematic_start = main.world_to_grid(mw)
			_schematic_end = _schematic_start
			_schematic_dragging = true
			queue_redraw()
		elif event.is_action_released("schematic_capture") and _schematic_dragging:
			# Released — finalize the rect
			var mw = get_global_mouse_position()
			_schematic_end = main.world_to_grid(mw)
			_schematic_dragging = false
			_schematic_confirmed = true
			queue_redraw()
	if event.is_action_pressed("ui_cancel"):
		if _world_menu_open:
			_close_world_menu()
			get_viewport().set_input_as_handled()
			return
		if _schematic_mode or _schematic_confirmed:
			_schematic_mode = false
			_schematic_confirmed = false
			_schematic_dragging = false
			queue_redraw()
		elif _placing_schematic:
			_placing_schematic = false
			queue_redraw()
	if event.is_action_pressed("ui_accept") and _schematic_confirmed:
		_show_schematic_save_dialog()
	if _schematic_dragging and event is InputEventMouseMotion:
		var mw = get_global_mouse_position()
		_schematic_end = main.world_to_grid(mw)
		queue_redraw()

	# --- SCHEMATIC PLACEMENT: click to place ---
	if _placing_schematic and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_execute_schematic_placement()
		return

	# Rebuild mode (hold to show destroyed ghosts, drag to select)
	if event.is_action("rebuild_mode"):
		if event.is_action_pressed("rebuild_mode"):
			# Start dragging immediately from current mouse position
			var mouse_world = get_global_mouse_position()
			_rebuild_mode = true
			_rebuild_start = main.world_to_grid(mouse_world)
			_rebuild_end = _rebuild_start
			_rebuild_dragging = true
			queue_redraw()
		elif event.is_action_released("rebuild_mode"):
			# Released — execute rebuild if dragging, then exit mode
			if _rebuild_dragging:
				var mouse_world = get_global_mouse_position()
				_rebuild_end = main.world_to_grid(mouse_world)
				if main.has_method("convert_derelict_in_rect"):
					main.convert_derelict_in_rect(_rebuild_start, _rebuild_end)
				if main.has_method("queue_rebuild_in_rect"):
					main.queue_rebuild_in_rect(_rebuild_start, _rebuild_end)
				_rebuild_dragging = false
			_rebuild_mode = false
			queue_redraw()
	if _rebuild_mode and _rebuild_dragging and event is InputEventMouseMotion:
		var mouse_world = get_global_mouse_position()
		_rebuild_end = main.world_to_grid(mouse_world)
		queue_redraw()

	if event.is_action_pressed("rotate_clockwise"):
		if main.selected_building != &"" and _is_directional(main.selected_building):
			main.placement_rotation = (main.placement_rotation + 1) % 4
	elif event.is_action_pressed("rotate_counter_clockwise"):
		if main.selected_building != &"" and _is_directional(main.selected_building):
			main.placement_rotation = (main.placement_rotation + 3) % 4
	elif event.is_action_pressed("toggle_build_pause"):
		if "build_paused" in main:
			main.build_paused = not main.build_paused
	elif event.is_action_pressed("toggle_link_mode"):
		if linking_mode:
			linking_mode = false
			link_source = Vector2i(-1, -1)
		else:
			linking_mode = true
			link_source = Vector2i(-1, -1)
			main.select_building(&"")  # Exit build mode
			queue_redraw()


func _process(_delta: float) -> void:
	# Update build progress — only the first building in the queue gets progress
	if "build_order" in main and not ("world_paused" in main and main.world_paused) and not ("build_paused" in main and main.build_paused) and not main.build_order.is_empty():
		var anchor: Vector2i = main.build_order[0]
		if main.building_build_progress.has(anchor):
			main.building_build_progress[anchor] += _delta
			var block_id = main.placed_buildings.get(anchor, &"")
			var data = Registry.get_block(block_id)
			if data and main.building_build_progress[anchor] >= data.build_time:
				main.building_build_progress.erase(anchor)
				main.build_order.remove_at(0)
		else:
			# Anchor no longer in progress dict (destroyed?) — remove from queue
			main.build_order.remove_at(0)

	# Process placement queue: place entries that are now in build range and world isn't paused
	if not ("world_paused" in main and main.world_paused) and not _paused_queue.is_empty():
		var remaining: Array = []
		for entry in _paused_queue:
			if _is_in_build_range(entry["grid_pos"]):
				var old_building = main.selected_building
				var old_rotation = main.placement_rotation
				main.selected_building = entry["block_id"]
				main.placement_rotation = entry["rotation"]
				main.try_place_building(entry["grid_pos"])
				main.selected_building = old_building
				main.placement_rotation = old_rotation
			else:
				remaining.append(entry)
		_paused_queue = remaining

	# Update deconstruct progress — only the first in queue gets ticked
	if "deconstruct_order" in main and not ("world_paused" in main and main.world_paused) and not main.deconstruct_order.is_empty():
		var anchor: Vector2i = main.deconstruct_order[0]
		if main.building_deconstruct_progress.has(anchor):
			var entry: Dictionary = main.building_deconstruct_progress[anchor]
			entry["progress"] += _delta
			if entry["progress"] >= entry["build_time"]:
				main.building_deconstruct_progress.erase(anchor)
				main.deconstruct_order.remove_at(0)
				main.destroy_building(anchor)
		else:
			# Entry was removed externally (e.g., building already destroyed)
			main.deconstruct_order.remove_at(0)

	# Tick archive decoders
	if not ("world_paused" in main and main.world_paused):
		_tick_archive_decoders(_delta)

	# Always redraw for parallax (walls + void tiles shift with camera)
	queue_redraw()

	# Keep redrawing in linking mode so the line-to-mouse updates
	if linking_mode:
		queue_redraw()

	# Update demolish rectangle preview while dragging
	if _demolish_dragging:
		var mouse_world = get_global_mouse_position()
		_demolish_end = main.world_to_grid(mouse_world)
		queue_redraw()

	# Update world menu hover
	if _world_menu_open:
		var mw = get_global_mouse_position()
		var new_hovered := _world_menu_hit_test(mw)
		if new_hovered != _world_menu_hovered:
			_world_menu_hovered = new_hovered
			queue_redraw()

	if main.selected_building == &"":
		_drag_placing = false
		_drag_cells.clear()
		return
	var mouse_world = get_global_mouse_position()
	preview_grid_pos = main.world_to_grid(mouse_world)

	# Center multi-tile buildings on the mouse cursor
	var sel_data = Registry.get_block(main.selected_building)
	if sel_data and (sel_data.grid_size.x > 1 or sel_data.grid_size.y > 1):
		preview_grid_pos -= Vector2i(sel_data.grid_size.x / 2, sel_data.grid_size.y / 2)

	# Compute the can_place flag for the single-cell hover preview
	can_place = _can_place_at(preview_grid_pos, main.selected_building)

	# Compute drag cells (axis-locked line or pathfinding)
	if _drag_placing:
		_drag_cells.clear()
		var data = Registry.get_block(main.selected_building)
		var grid_w: int = data.grid_size.x if data else 1
		var grid_h: int = data.grid_size.y if data else 1
		var alt_held := Input.is_key_pressed(KEY_ALT)

		if alt_held and _is_transport_block(main.selected_building):
			# --- Pathfind mode: route around obstacles ---
			_pathfind_mode = true
			var tag := _get_transport_tag(main.selected_building)
			if _transport_astar == null:
				_build_transport_astar(tag)
			_drag_cells = _compute_transport_path(_drag_start, preview_grid_pos, tag)
			_compute_path_rotations(_drag_cells)
		else:
			# --- Normal axis-locked line ---
			_pathfind_mode = false
			_pathfind_rotations.clear()
			_pathfind_bridge_cells.clear()
			_transport_astar = null

			var dx := preview_grid_pos.x - _drag_start.x
			var dy := preview_grid_pos.y - _drag_start.y
			# Lock to the axis with the larger delta; step by building size
			if abs(dx) >= abs(dy):
				# Horizontal line — step by building width
				var step: int = grid_w if dx >= 0 else -grid_w
				var x := _drag_start.x
				while (step > 0 and x <= preview_grid_pos.x) or (step < 0 and x >= preview_grid_pos.x):
					_drag_cells.append(Vector2i(x, _drag_start.y))
					x += step
			else:
				# Vertical line — step by building height
				var step: int = grid_h if dy >= 0 else -grid_h
				var y := _drag_start.y
				while (step > 0 and y <= preview_grid_pos.y) or (step < 0 and y >= preview_grid_pos.y):
					_drag_cells.append(Vector2i(_drag_start.x, y))
					y += step

			# Auto-rotate directional blocks (belts, ducts, pipes, shafts) in drag direction
			if _is_directional(main.selected_building) and _drag_cells.size() > 1:
				_compute_path_rotations(_drag_cells)

	queue_redraw()

## Returns true if a block can be placed at the given grid position.
## Checks bounds, cell empty, drone range, and extractor/pump validity.
## Does NOT check affordability (handled separately for drag-line preview).
## Returns true if the terrain allows placement (ignoring build range).
func _can_place_terrain(grid_pos: Vector2i, block_id: StringName) -> bool:
	var data = Registry.get_block(block_id)
	if data == null:
		return false
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	var is_platform: bool = data.tags.has("platform")
	var is_pump: bool = data.tags.has("pump")
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var check_pos = grid_pos + Vector2i(x, y)
			if not main.is_within_bounds(check_pos):
				return false
			# Water depth rules: a platform underneath counts as "dry ground"
			# for the purpose of allowing other blocks on top, so check for an
			# existing platform at this cell first.
			var has_platform_under: bool = false
			if main.placed_buildings.has(check_pos):
				var cell_block_id: StringName = main.placed_buildings[check_pos]
				if cell_block_id != block_id:
					var cell_data = Registry.get_block(cell_block_id)
					if cell_data and cell_data.tags.has("platform"):
						has_platform_under = true
					else:
						return false
			if terrain and terrain.has_wall(check_pos):
				return false
			if terrain:
				var depth: int = terrain.get_water_depth_at(check_pos)
				if depth > 0 and not has_platform_under:
					# Platforms can be placed on any water depth (they bridge it).
					if is_platform:
						pass
					# Pumps can be placed on depth 1 or 2 water (needs to stand
					# on the liquid surface to extract).
					elif is_pump and depth <= 2:
						pass
					else:
						return false
	return true


## Returns true if the position is within drone build range.
func _is_in_build_range(grid_pos: Vector2i) -> bool:
	var drone = get_node_or_null("/root/Main/PlayerDrone")
	if drone and not drone.is_in_build_range(grid_pos):
		return false
	return true


func _can_place_at(grid_pos: Vector2i, block_id: StringName) -> bool:
	if not _can_place_terrain(grid_pos, block_id):
		return false

	# Check drone build range
	if not _is_in_build_range(grid_pos):
		return false

	var data = Registry.get_block(block_id)
	if data == null:
		return false
	var terrain = get_node_or_null("/root/Main/TerrainSystem")

	# Extractor must face ore
	if data.category == BlockData.BlockCategory.EXTRACTORS:
		if not _is_facing_ore(grid_pos, main.placement_rotation):
			return false
	# Pump must be on liquid
	elif data.tags.has("pump"):
		if not _is_on_liquid(grid_pos):
			return false
	# Archive scanner: no placement restriction — adjacency to an archive is
	# checked at decoding time, not at placement time.

	# Vent-powered buildings must be centered on a vent tile
	if data.tags.has("vent_powered"):
		if terrain:
			var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
			if terrain.floor_tiles.get(center, &"") != &"vent":
				return false

	return true


## Returns true if the player can afford N copies of the given block.
func _can_afford_n(block_id: StringName, count: int) -> bool:
	var data = Registry.get_block(block_id)
	if data == null or not ("require_resources" in main and main.require_resources):
		return true
	for item_id in data.build_cost:
		var needed: int = data.build_cost[item_id] * count
		if not main.resources.has(item_id) or main.resources[item_id] < needed:
			return false
	return true


## Returns true if the building is being placed on a liquid source tile.
func _is_on_liquid(grid_pos: Vector2i) -> bool:
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if terrain == null:
		return false
	return terrain.get_liquid_at(grid_pos) != null


## Returns true if ANY cell along the front edge of the building faces an ore deposit.
## If block_id is provided, uses that instead of main.selected_building.
func _is_facing_ore(grid_pos: Vector2i, rotation: int, block_id: StringName = &"") -> bool:
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if terrain == null:
		return false
	var bid: StringName = block_id if block_id != &"" else main.selected_building
	var data = Registry.get_block(bid)
	if data == null:
		return false

	# Check front edge + one tile further ahead
	var dir: Vector2i
	match rotation:
		0: dir = Vector2i(1, 0)
		1: dir = Vector2i(0, 1)
		2: dir = Vector2i(-1, 0)
		3: dir = Vector2i(0, -1)
		_: dir = Vector2i(1, 0)

	var front_cells = _get_front_edge(grid_pos, data.grid_size, rotation)
	for cell in front_cells:
		if terrain.get_ore_at(cell) != null:
			return true
		# Also check one tile ahead
		if terrain.get_ore_at(cell + dir) != null:
			return true
	return false


## Returns true if any cardinal neighbor of this building is an archive block.
## Scanners are not directional — placement just needs to be adjacent to an archive.
func _is_facing_archive(grid_pos: Vector2i, _rotation: int, block_id: StringName = &"") -> bool:
	var bid: StringName = block_id if block_id != &"" else main.selected_building
	var data = Registry.get_block(bid)
	if data == null:
		return false
	# Iterate every cell occupied by this (possibly multi-tile) building and
	# check each of its outward neighbors for an archive.
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var cell := grid_pos + Vector2i(x, y)
			for d in DIR_VECTORS:
				var n: Vector2i = cell + d
				# Skip cells that are part of the building itself.
				if n.x >= grid_pos.x and n.x < grid_pos.x + data.grid_size.x \
				and n.y >= grid_pos.y and n.y < grid_pos.y + data.grid_size.y:
					continue
				if not main.placed_buildings.has(n):
					continue
				var n_data = Registry.get_block(main.placed_buildings[n])
				if n_data and n_data.id == &"archive":
					return true
	return false


## Returns all cells just outside the front edge of a building.
## For a 1x1 this is just one cell. For a 2x2 it's 2 cells.
func _get_front_edge(origin: Vector2i, grid_size: Vector2i, rotation: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	match rotation:
		0: # right — column at x = origin.x + grid_size.x
			for y in range(grid_size.y):
				cells.append(Vector2i(origin.x + grid_size.x, origin.y + y))
		1: # down — row at y = origin.y + grid_size.y
			for x in range(grid_size.x):
				cells.append(Vector2i(origin.x + x, origin.y + grid_size.y))
		2: # left — column at x = origin.x - 1
			for y in range(grid_size.y):
				cells.append(Vector2i(origin.x - 1, origin.y + y))
		3: # up — row at y = origin.y - 1
			for x in range(grid_size.x):
				cells.append(Vector2i(origin.x + x, origin.y - 1))
	return cells

func _unhandled_input(event: InputEvent) -> void:
	if main.has_method("is_ui_blocking") and main.is_ui_blocking():
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if linking_mode:
					_handle_link_click()
				elif main.selected_building == &"":
					# World menu is open — check for cell click or outside click
					if _world_menu_open:
						var mouse_world = get_global_mouse_position()
						var hit := _world_menu_hit_test(mouse_world)
						if hit >= 0:
							_apply_world_menu_selection(hit)
						else:
							_close_world_menu()
						get_viewport().set_input_as_handled()
						return
					# No building selected — check if clicking on a sorter or constructor
					var mouse_world = get_global_mouse_position()
					var click_pos = main.world_to_grid(mouse_world)
					if main.placed_buildings.has(click_pos):
						var click_block_id = main.placed_buildings[click_pos]
						var click_data = Registry.get_block(click_block_id)
						var click_anchor: Vector2i = main.building_origins.get(click_pos, click_pos)
						if click_data and (click_data.tags.has("sorter") or click_data.tags.has("inverted_sorter")):
							_open_world_menu("sorter", click_anchor)
							get_viewport().set_input_as_handled()
							return
						elif click_data and click_data.tags.has("constructor"):
							_open_world_menu("constructor", click_anchor)
							get_viewport().set_input_as_handled()
							return
						elif click_data and click_data.id == &"archive":
							_open_world_menu("archive", click_anchor)
							get_viewport().set_input_as_handled()
							return
				elif main.selected_building != &"" and not event.ctrl_pressed:
					# Start drag-place: record start, don't place yet
					# (Ctrl+click is reserved for unit control)
					_drag_start = preview_grid_pos
					_drag_placing = true
					_drag_cells.clear()
			else:
				# Release: place all blocks in the preview line
				if _drag_placing:
					var old_rot: int = main.placement_rotation
					var old_building: StringName = main.selected_building
					if ("world_paused" in main and main.world_paused):
						# Queue placements for when world unpauses
						var queued_positions: Dictionary = {}
						for entry in _paused_queue:
							queued_positions[entry["grid_pos"]] = true
						for cell in _drag_cells:
							var cell_block: StringName = old_building
							var cell_rot: int = _pathfind_rotations.get(cell, old_rot)
							if _pathfind_mode:
								if _pathfind_bridge_cells.has(cell):
									cell_block = _pathfind_bridge_cells[cell]
							if (main.is_cell_empty(cell) or main.placed_buildings.get(cell, &"") == cell_block) and not queued_positions.has(cell):
								_paused_queue.append({
									"grid_pos": cell,
									"block_id": cell_block,
									"rotation": cell_rot,
								})
					else:
						var queued_positions: Dictionary = {}
						for entry in _paused_queue:
							queued_positions[entry["grid_pos"]] = true
						for cell in _drag_cells:
							var cell_block: StringName = old_building
							var cell_rot: int = _pathfind_rotations.get(cell, old_rot)
							if _pathfind_mode:
								if _pathfind_bridge_cells.has(cell):
									cell_block = _pathfind_bridge_cells[cell]
							if _is_in_build_range(cell):
								# In range: place immediately
								main.placement_rotation = cell_rot
								main.selected_building = cell_block
								main.try_place_building(cell)
							elif _can_place_terrain(cell, cell_block) and not queued_positions.has(cell):
								# Out of range but valid terrain: queue as ghost
								_paused_queue.append({
									"grid_pos": cell,
									"block_id": cell_block,
									"rotation": cell_rot,
								})
						main.placement_rotation = old_rot
						main.selected_building = old_building
					_drag_placing = false
					_drag_cells.clear()
					_pathfind_mode = false
					_pathfind_rotations.clear()
					_pathfind_bridge_cells.clear()
					_transport_astar = null
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			# Ctrl+right-click is unit control on macOS (ctrl+click = right-click)
			if event.ctrl_pressed:
				return
			# Skip right-click entirely when the player is in unit mode
			# with units selected (unit mode owns right-click for commands).
			# Outside of unit mode, right-click goes to demolish even if
			# units are still selected in the background.
			var unit_mgr = get_node_or_null("/root/Main/UnitManager")
			if unit_mgr and unit_mgr.unit_mode_active and unit_mgr.selected_units.size() > 0:
				return
			if event.pressed:
				_drag_placing = false
				_drag_cells.clear()
				if linking_mode:
					linking_mode = false
					link_source = Vector2i(-1, -1)
					queue_redraw()
				else:
					# Start demolish drag
					var mouse_world = get_global_mouse_position()
					_demolish_start = main.world_to_grid(mouse_world)
					_demolish_end = _demolish_start
					_demolish_dragging = true
			else:
				# Right mouse released — finish demolish drag
				if _demolish_dragging:
					_demolish_dragging = false
					var mouse_world = get_global_mouse_position()
					_demolish_end = main.world_to_grid(mouse_world)
					# If it was just a click (no drag movement)
					if _demolish_start == _demolish_end:
						# If clicking on a building, queue it for deconstruction
						if main.placed_buildings.has(_demolish_start):
							var click_block_id = main.placed_buildings[_demolish_start]
							var click_data = Registry.get_block(click_block_id)
							var click_faction = main.get_building_faction(_demolish_start)
							if click_faction == FACTION_LUMINA and (click_data == null or not click_data.tags.has("core")):
								var click_anchor: Vector2i = main.building_origins.get(_demolish_start, _demolish_start)
								if main.has_method("start_deconstruct"):
									main.start_deconstruct(click_anchor)
						else:
							main.select_building(&"")
					elif not ("world_paused" in main and main.world_paused):
						_demolish_rect(_demolish_start, _demolish_end)
					queue_redraw()


## Handles a left-click while in linking mode.
func _handle_link_click() -> void:
	var mouse_world = get_global_mouse_position()
	var grid_pos = main.world_to_grid(mouse_world)

	if not main.placed_buildings.has(grid_pos):
		return

	# Resolve to anchor for multi-tile blocks
	grid_pos = main.building_origins.get(grid_pos, grid_pos)

	var block_id = main.placed_buildings[grid_pos]
	var data = Registry.get_block(block_id)
	if data == null or not data.tags.has("linkable"):
		return  # Can only link blocks tagged "linkable"

	if link_source == Vector2i(-1, -1):
		# First selection — remember source (anchor)
		link_source = grid_pos
	else:
		# Second selection — enforce type matching (bridges only link to bridges)
		if grid_pos != link_source:
			var source_id = main.placed_buildings[link_source]
			var source_data = Registry.get_block(source_id)
			if source_data != null:
				var source_is_bridge = source_data.tags.has("bridge")
				var target_is_bridge = data.tags.has("bridge")
				if source_is_bridge != target_is_bridge:
					# Can't link bridge to non-bridge or vice versa
					linking_mode = false
					link_source = Vector2i(-1, -1)
					return
		# Create the link
		if grid_pos != link_source:
			var power_sys = get_node_or_null("/root/Main/PowerSystem")
			if power_sys:
				# Check if source already has a link — remove it first (1:1 links)
				var existing = power_sys.get_linked_partner(link_source)
				if existing != null:
					power_sys.unlink_blocks(link_source, existing)
				existing = power_sys.get_linked_partner(grid_pos)
				if existing != null:
					power_sys.unlink_blocks(grid_pos, existing)
				power_sys.link_blocks(link_source, grid_pos)
		# Done linking
		linking_mode = false
		link_source = Vector2i(-1, -1)
	queue_redraw()


## Opens the in-world selection menu for a sorter or constructor block.
func _open_world_menu(type: String, grid_pos: Vector2i) -> void:
	_world_menu_type = type
	_world_menu_pos = grid_pos
	_world_menu_items.clear()
	_world_menu_hovered = -1

	if type == "sorter":
		# First entry is the "clear filter" option
		_world_menu_items.append({"id": &"", "icon": null, "name": "Clear"})
		for item in Registry.items_list:
			if not item.conveyable:
				continue
			_world_menu_items.append({"id": item.id, "icon": item.icon, "name": item.display_name})
	elif type == "constructor":
		var block_id = main.placed_buildings.get(grid_pos, &"")
		var block_data = Registry.get_block(block_id)
		var max_ps: int = block_data.max_payload_size if block_data else 0
		var tech_tree = get_node_or_null("/root/Main/TechTree")
		for block in Registry.blocks_list:
			if block.tags.has("core"):
				continue
			if block.grid_size.x > max_ps or block.grid_size.y > max_ps:
				continue
			if main.require_research and tech_tree and not tech_tree.is_researched(block.id):
				continue
			_world_menu_items.append({"id": block.id, "icon": block.icon, "name": block.display_name})
	elif type == "archive":
		# First entry clears the archive selection
		_world_menu_items.append({"id": &"", "icon": null, "name": "Clear"})
		# List every known archive id from TechTree.archive_ids (autoload)
		for aid in TechTree.archive_ids:
			var nd = TechTree.get_node_data(aid)
			var aname: String = nd["name"] if nd else String(aid)
			_world_menu_items.append({"id": aid, "icon": null, "name": aname})

	_world_menu_open = true
	queue_redraw()


## Closes the in-world menu.
func _close_world_menu() -> void:
	_world_menu_open = false
	_world_menu_hovered = -1
	queue_redraw()


## Applies the selection from the world menu.
func _apply_world_menu_selection(index: int) -> void:
	if index < 0 or index >= _world_menu_items.size():
		_close_world_menu()
		return

	var selected_id: StringName = _world_menu_items[index]["id"]

	if _world_menu_type == "sorter":
		if _logistics:
			_logistics.sorter_filters[_world_menu_pos] = selected_id
	elif _world_menu_type == "constructor":
		if _logistics and _logistics.constructor_state.has(_world_menu_pos):
			_logistics.constructor_state[_world_menu_pos]["selected_block"] = selected_id
			if selected_id != &"":
				_logistics.constructor_state[_world_menu_pos]["phase"] = "collecting"
	elif _world_menu_type == "archive":
		archive_holdings[_world_menu_pos] = selected_id

	_close_world_menu()


## Returns the world-space bounding rect for the world menu, or Rect2() if closed.
func _get_world_menu_rect() -> Rect2:
	if not _world_menu_open or _world_menu_items.is_empty():
		return Rect2()
	var cols := mini(_world_menu_columns, _world_menu_items.size())
	var rows := ceili(float(_world_menu_items.size()) / float(cols))
	var padding := 6.0
	var menu_w: float = cols * _world_menu_cell_size + padding * 2.0
	var menu_h: float = rows * _world_menu_cell_size + padding * 2.0
	# Position above the building, centered
	var block_id = main.placed_buildings.get(_world_menu_pos, &"")
	var data = Registry.get_block(block_id)
	var gs := Vector2i(1, 1)
	if data:
		gs = data.grid_size
	var block_world: Vector2 = main.grid_to_world(_world_menu_pos)
	var block_center_x: float = block_world.x + float(gs.x) * main.GRID_SIZE * 0.5
	var block_top_y: float = block_world.y - 8.0  # 8px gap above block
	var menu_x: float = block_center_x - menu_w * 0.5
	var menu_y: float = block_top_y - menu_h
	return Rect2(menu_x, menu_y, menu_w, menu_h)


## Returns the item index under the given world position, or -1.
func _world_menu_hit_test(world_pos: Vector2) -> int:
	var menu_rect := _get_world_menu_rect()
	if not menu_rect.has_point(world_pos):
		return -1
	var padding := 6.0
	var local_x: float = world_pos.x - menu_rect.position.x - padding
	var local_y: float = world_pos.y - menu_rect.position.y - padding
	if local_x < 0.0 or local_y < 0.0:
		return -1
	var col := int(local_x / _world_menu_cell_size)
	var row := int(local_y / _world_menu_cell_size)
	var cols := mini(_world_menu_columns, _world_menu_items.size())
	if col < 0 or col >= cols:
		return -1
	var idx := row * cols + col
	if idx < 0 or idx >= _world_menu_items.size():
		return -1
	return idx


## Draws the in-world selection menu (called from _draw).
func _draw_world_menu() -> void:
	if not _world_menu_open or _world_menu_items.is_empty():
		return
	var menu_rect := _get_world_menu_rect()
	var padding := 6.0
	var cols := mini(_world_menu_columns, _world_menu_items.size())

	# Background
	draw_rect(menu_rect, Color(0.08, 0.08, 0.1, 0.92), true)
	draw_rect(menu_rect, Color(0.4, 0.4, 0.5, 0.8), false, 1.5)

	# Draw cells
	var origin := menu_rect.position + Vector2(padding, padding)
	for i in _world_menu_items.size():
		var col := i % cols
		var row := i / cols
		var cell_pos := origin + Vector2(col * _world_menu_cell_size, row * _world_menu_cell_size)
		var cell_rect := Rect2(cell_pos, Vector2(_world_menu_cell_size, _world_menu_cell_size))

		# Hover highlight
		if i == _world_menu_hovered:
			draw_rect(cell_rect, Color(0.3, 0.5, 0.8, 0.5), true)

		# Cell border
		draw_rect(cell_rect, Color(0.25, 0.25, 0.3, 0.6), false, 1.0)

		var entry: Dictionary = _world_menu_items[i]

		# Clear button (first cell in sorter or archive mode)
		if (_world_menu_type == "sorter" or _world_menu_type == "archive") and i == 0:
			# Draw X for clear
			var cx := cell_pos.x + _world_menu_cell_size * 0.5
			var cy := cell_pos.y + _world_menu_cell_size * 0.5
			var hs := _world_menu_cell_size * 0.25
			draw_line(Vector2(cx - hs, cy - hs), Vector2(cx + hs, cy + hs), Color(1.0, 0.3, 0.3), 2.0)
			draw_line(Vector2(cx + hs, cy - hs), Vector2(cx - hs, cy + hs), Color(1.0, 0.3, 0.3), 2.0)
			continue

		# Draw icon if available
		var icon_tex: Texture2D = entry.get("icon")
		if icon_tex:
			var icon_margin := 4.0
			var icon_rect := Rect2(
				cell_pos + Vector2(icon_margin, icon_margin),
				Vector2(_world_menu_cell_size - icon_margin * 2.0, _world_menu_cell_size - icon_margin * 2.0)
			)
			draw_texture_rect(icon_tex, icon_rect, false)
		else:
			# Fallback: draw abbreviated name
			var font := ThemeDB.fallback_font
			var font_size := 10
			var short_name: String = entry.get("name", "?").left(4)
			var text_pos := cell_pos + Vector2(4.0, _world_menu_cell_size * 0.65)
			draw_string(font, text_pos, short_name, HORIZONTAL_ALIGNMENT_LEFT, _world_menu_cell_size - 8.0, font_size, Color.WHITE)


func _draw() -> void:
	_draw_placed_buildings()
	_draw_cranes()
	_draw_paused_queue()
	_draw_preview()
	_draw_links()
	_draw_demolish_rect()
	_draw_rebuild_mode()
	_draw_schematic_rect()
	_draw_schematic_placement()
	_draw_world_menu()


## Returns the fade alpha for a wall tile (1.0 = fully visible, 0.0 = fully dark).
## Based on distance from nearest floor tile.
## Walls within WALL_FADE_START tiles of floor are fully visible.
## Beyond that, they fade over WALL_FADE_RANGE tiles.
## Walls with no path to floor (unreachable) are fully dark.
func _get_wall_fade_alpha(grid_pos: Vector2i) -> float:
	# Check script-hidden tiles
	var sector_script = get_node_or_null("/root/Main/SectorScript")
	if sector_script and sector_script.is_tile_hidden(grid_pos):
		return 0.0
	if not _wall_floor_distance.has(grid_pos):
		return 0.0  # No path to floor — fully dark
	var dist: int = _wall_floor_distance[grid_pos]
	if dist <= WALL_FADE_START:
		return 1.0
	var fade_dist := float(dist - WALL_FADE_START)
	return clampf(1.0 - fade_dist / WALL_FADE_RANGE, 0.0, 1.0)


## Convert effective distance to darkness (0.0 = visible, 1.0 = black).
func _dist_to_darkness(eff_dist: float) -> float:
	if eff_dist <= float(WALL_FADE_START):
		return 0.0
	var fade_dist := eff_dist - float(WALL_FADE_START)
	return clampf(fade_dist / WALL_FADE_RANGE, 0.0, 1.0)


## Returns pre-computed per-corner darkness [tl, tr, br, bl].
## Returns null if the wall has no darkness (fully bright). Check with has() first or use get().
func _get_corner_darkness(grid_pos: Vector2i) -> Variant:
	return _cached_corner_darkness.get(grid_pos)


func _soft_cap_value(value: float) -> float:
	if abs(value) <= max_depth:
		return value
	var sign_v = sign(value)
	var excess = abs(value) - max_depth
	return sign_v * (max_depth + excess * soft_cap_factor)


func _get_top_offset(_world_pos: Vector2) -> Vector2:
	var camera = get_viewport().get_camera_2d()
	if not camera:
		return Vector2.ZERO
	var cam_center = camera.get_screen_center_position()
	var map_center = Vector2(
		main.GRID_SIZE * main.GRID_WIDTH / 2.0,
		main.GRID_SIZE * main.GRID_HEIGHT / 2.0
	)
	var raw_offset = (map_center - cam_center) * parallax_strength
	return Vector2(
		_soft_cap_value(raw_offset.x),
		_soft_cap_value(raw_offset.y)
	)


## Draws a block texture at the given position, rotated by building rotation.
## Draws a block texture, rotated for directional blocks.
## rot: 0=right, 1=down, 2=left, 3=up. Textures face up by default, so +90° offset applied.
func _draw_block_texture(texture: Texture2D, top_pos: Vector2, w: float, h: float, rot: int = 0, tint: Color = Color.WHITE) -> void:
	var angle: float = rot * PI / 2.0 + PI / 2.0  # +90° because textures face up, rot 0 = right
	var center := top_pos + Vector2(w / 2.0, h / 2.0)
	draw_set_transform(center, angle)
	draw_texture_rect(texture, Rect2(Vector2(-w / 2.0, -h / 2.0), Vector2(w, h)), false, tint)
	draw_set_transform(Vector2.ZERO, 0.0)


# Gets the color for a block from the Registry.
func _get_block_color(block_id: StringName) -> Color:
	var data = Registry.get_block(block_id)
	if data:
		return data.color
	return Color.MAGENTA  # Bright pink = missing data, easy to spot


# Gets the side colors from the Registry block data.
func _get_side_colors(block_id: StringName) -> Array:
	var data = Registry.get_block(block_id)
	if data:
		return [data.get_side_color(), data.get_side_color_dark()]
	return [Color.MAGENTA.darkened(0.4), Color.MAGENTA.darkened(0.55)]


## Returns the grid_size of a block (how many tiles it spans).
func _get_block_grid_size(block_id: StringName) -> Vector2i:
	var data = Registry.get_block(block_id)
	if data:
		return data.grid_size
	return Vector2i(1, 1)


## Returns the visual height multiplier for a block (0.0–1.0).
## Transport blocks (conveyors) are drawn flatter than other buildings.
func _get_height_scale(block_id: StringName) -> float:
	var data = Registry.get_block(block_id)
	if data and data.is_transport():
		return 0.5
	return 1.0


## Returns true if a block is directional (conveyors, drills).
func _is_directional(block_id: StringName) -> bool:
	var data = Registry.get_block(block_id)
	if data == null:
		return false
	return data.is_transport() or data.category == BlockData.BlockCategory.EXTRACTORS \
		or data.tags.has("shaft") \
		or data.tags.has("constructor") or data.tags.has("deconstructor") \
		or data.tags.has("payload_loader") or data.tags.has("freight_loader") \
		or data.tags.has("payload_unloader") or data.tags.has("freight_unloader") \
		or data.tags.has("archive_scanner") \
		or not data.side_inputs.is_empty() or not data.side_outputs.is_empty()


# =========================
# TRANSPORT PATHFINDING
# =========================

## Returns true if the block is a transport type (belt, duct, pipe).
func _is_transport_block(block_id: StringName) -> bool:
	var data = Registry.get_block(block_id)
	return data != null and data.is_transport()


## Get the transport type tag for a block ("belt", "duct", "fluid", or "").
func _get_transport_tag(block_id: StringName) -> String:
	var data = Registry.get_block(block_id)
	if data == null:
		return ""
	if data.tags.has("belt"):
		return "belt"
	if data.tags.has("duct"):
		return "duct"
	if data.tags.has("fluid"):
		return "fluid"
	return ""


## Build a local AStarGrid2D for transport pathfinding (cardinal only).
func _build_transport_astar(transport_tag: String) -> void:
	_transport_astar = AStarGrid2D.new()
	_transport_astar.region = Rect2i(0, 0, main.GRID_WIDTH, main.GRID_HEIGHT)
	_transport_astar.cell_size = Vector2(1, 1)
	_transport_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_transport_astar.update()

	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	for x in range(main.GRID_WIDTH):
		for y in range(main.GRID_HEIGHT):
			var pos := Vector2i(x, y)
			var is_solid := false
			# Terrain walls block transport
			if terrain and terrain.has_wall(pos):
				is_solid = true
			# Existing buildings block (except same-type transports which can be bridged)
			elif main.placed_buildings.has(pos):
				var existing_data = Registry.get_block(main.placed_buildings[pos])
				if existing_data:
					if not existing_data.tags.has(transport_tag):
						is_solid = true
					# Same-type transport: passable (bridge crossing)
			if is_solid:
				_transport_astar.set_point_solid(pos, true)


## Compute a pathfound transport route, detecting bridge crossings.
func _compute_transport_path(from: Vector2i, to: Vector2i, transport_tag: String) -> Array[Vector2i]:
	_pathfind_bridge_cells.clear()
	if _transport_astar == null:
		_build_transport_astar(transport_tag)

	if not _transport_astar.is_in_boundsv(from) or not _transport_astar.is_in_boundsv(to):
		return []
	if _transport_astar.is_point_solid(from) or _transport_astar.is_point_solid(to):
		return []

	var id_path: PackedVector2Array = _transport_astar.get_point_path(from, to)
	if id_path.is_empty():
		return []

	var result: Array[Vector2i] = []
	for p in id_path:
		var gp := Vector2i(int(p.x), int(p.y))
		result.append(gp)
		# Check if this cell has an existing same-type transport (needs bridge)
		if main.placed_buildings.has(gp):
			var bridge_id := _find_bridge_for_type(transport_tag)
			if bridge_id != &"":
				_pathfind_bridge_cells[gp] = bridge_id

	return result


## Compute per-cell rotations for a transport path (each cell faces the next).
func _compute_path_rotations(path: Array[Vector2i]) -> void:
	_pathfind_rotations.clear()
	for i in range(path.size()):
		var rot := 0
		if i < path.size() - 1:
			var delta: Vector2i = path[i + 1] - path[i]
			var idx: int = DIR_VECTORS.find(delta)
			if idx >= 0:
				rot = idx
		elif i > 0:
			# Last cell: same rotation as previous
			rot = _pathfind_rotations.get(path[i - 1], 0)
		_pathfind_rotations[path[i]] = rot


## Cache for bridge block lookups
var _bridge_cache: Dictionary = {}  # transport_tag -> StringName

## Find the bridge block for a transport type by scanning the registry.
func _find_bridge_for_type(transport_tag: String) -> StringName:
	if _bridge_cache.has(transport_tag):
		return _bridge_cache[transport_tag]
	for block_id in Registry.blocks:
		var data = Registry.get_block(block_id)
		if data and data.tags.has(transport_tag) and data.tags.has("bridge"):
			_bridge_cache[transport_tag] = block_id
			return block_id
	_bridge_cache[transport_tag] = &""
	return &""


## Returns true if a building at from_pos could output items toward to_pos.
## Checks transports (conveyors), extractors (drills), pumps, and factories.
func _transport_outputs_to(from_pos: Vector2i, to_pos: Vector2i) -> bool:
	if not main.placed_buildings.has(from_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[from_pos])
	if data == null:
		return false

	# Find the building's origin for correct rotation lookup on multi-tile buildings
	var anchor = main.get_building_anchor(from_pos)
	var origin: Vector2i = anchor if anchor != null else from_pos
	var rot: int = main.building_rotation.get(origin, 0)
	var dir: Vector2i = DIR_VECTORS[rot]

	# Transport blocks: output in their facing direction only
	if data.is_transport():
		return from_pos + dir == to_pos

	# Pumps: extract from underneath, output in all 4 directions
	if data.tags.has("pump"):
		return true

	# Extractors (drills): output on all sides EXCEPT the front (mining) edge
	if data.category == BlockData.BlockCategory.EXTRACTORS:
		var is_front := false
		match rot:
			0: is_front = to_pos.x == origin.x + data.grid_size.x   # right face
			1: is_front = to_pos.y == origin.y + data.grid_size.y   # bottom face
			2: is_front = to_pos.x == origin.x - 1                   # left face
			3: is_front = to_pos.y == origin.y - 1                   # top face
		return not is_front

	# Factories: check directional outputs if defined, otherwise any direction
	if data.category == BlockData.BlockCategory.FACTORIES:
		if data.side_outputs.is_empty():
			return true  # Generic factory without defined outputs
		# Check if to_pos is on one of the defined output sides
		for rel_dir_key in data.side_outputs:
			var rel_dir: int = int(rel_dir_key)
			var world_dir: int = (rel_dir + rot) % 4
			if from_pos + DIR_VECTORS[world_dir] == to_pos:
				return true
		return false

	# Constructors/deconstructors/loaders/unloaders: output items on all sides
	if data.tags.has("constructor") or data.tags.has("deconstructor") \
		or data.tags.has("payload_loader") or data.tags.has("freight_loader") \
		or data.tags.has("payload_unloader") or data.tags.has("freight_unloader"):
		return true

	return false


## Determines which belt texture variant and rotation angle to use.
## Checks the back, left, and right neighbors to detect side inputs.
func _get_belt_draw_info(grid_pos: Vector2i) -> Dictionary:
	var rot: int = main.building_rotation.get(grid_pos, 0)
	var facing: Vector2i = DIR_VECTORS[rot]

	# "Left" and "right" are relative to the belt's travel direction.
	# Facing right: left=up, right=down.
	var behind: Vector2i = grid_pos - facing
	var left_pos: Vector2i = grid_pos + Vector2i(facing.y, -facing.x)   # 90° CCW
	var right_pos: Vector2i = grid_pos + Vector2i(-facing.y, facing.x)  # 90° CW

	var has_back := _transport_outputs_to(behind, grid_pos)
	var has_left := _transport_outputs_to(left_pos, grid_pos)
	var has_right := _transport_outputs_to(right_pos, grid_pos)

	var tex_key := "straight"
	if has_left and has_right:
		tex_key = "ja"
	elif has_left:
		tex_key = "jl" if has_back else "cb"  # Junction or corner
	elif has_right:
		tex_key = "jr" if has_back else "ca"  # Junction or corner

	# Corner textures: no extra offset needed.
	# Straight/junction textures face UP in base → need PI/2 offset for rot 0 = RIGHT.
	var angle := rot * PI / 2.0
	if tex_key != "ca" and tex_key != "cb":
		angle += PI / 2.0
	
	if tex_key == "cb":
		angle += -(PI / 2.0)

	return {"texture": _belt_textures.get(tex_key), "angle": angle}


## Like _transport_outputs_to but also checks virtual preview cells.
func _virtual_transport_outputs_to(from_pos: Vector2i, to_pos: Vector2i,
		preview_set: Dictionary, preview_rots: Dictionary,
		preview_block_id: StringName) -> bool:
	# Check real placed buildings first
	if _transport_outputs_to(from_pos, to_pos):
		return true
	# Check virtual preview cells
	if preview_set.has(from_pos):
		var pdata = Registry.get_block(preview_block_id)
		if pdata and pdata.is_transport():
			var rot: int = preview_rots.get(from_pos, 0)
			var dir: Vector2i = DIR_VECTORS[rot]
			return from_pos + dir == to_pos
	return false


## Like _get_belt_draw_info but considers preview cells as virtual neighbors.
func _get_belt_draw_info_with_preview(grid_pos: Vector2i,
		preview_set: Dictionary, preview_rots: Dictionary,
		preview_block_id: StringName) -> Dictionary:
	var rot: int = preview_rots.get(grid_pos, main.building_rotation.get(grid_pos, 0))
	var facing: Vector2i = DIR_VECTORS[rot]

	var behind: Vector2i = grid_pos - facing
	var left_pos: Vector2i = grid_pos + Vector2i(facing.y, -facing.x)
	var right_pos: Vector2i = grid_pos + Vector2i(-facing.y, facing.x)

	var has_back := _virtual_transport_outputs_to(behind, grid_pos, preview_set, preview_rots, preview_block_id)
	var has_left := _virtual_transport_outputs_to(left_pos, grid_pos, preview_set, preview_rots, preview_block_id)
	var has_right := _virtual_transport_outputs_to(right_pos, grid_pos, preview_set, preview_rots, preview_block_id)

	var tex_key := "straight"
	if has_left and has_right:
		tex_key = "ja"
	elif has_left:
		tex_key = "jl" if has_back else "cb"
	elif has_right:
		tex_key = "jr" if has_back else "ca"

	var angle := rot * PI / 2.0
	if tex_key != "ca" and tex_key != "cb":
		angle += PI / 2.0
	if tex_key == "cb":
		angle += -(PI / 2.0)

	return {"texture": _belt_textures.get(tex_key), "angle": angle}


func _draw_placed_buildings() -> void:
	var camera = get_viewport().get_camera_2d()
	var cam_center = camera.get_screen_center_position() if camera else Vector2.ZERO
	var terrain = get_node_or_null("/root/Main/TerrainSystem")

	# Rebuild wall cache if dirty
	if _walls_dirty:
		_rebuild_wall_cache()

	# Viewport culling: compute visible grid range with margin for parallax
	var viewport_size = get_viewport_rect().size
	var cam_zoom = camera.zoom if camera else Vector2.ONE
	var half_view = viewport_size / (2.0 * cam_zoom)
	var margin_px = max_depth + float(main.GRID_SIZE)
	var view_min = cam_center - half_view - Vector2(margin_px, margin_px)
	var view_max = cam_center + half_view + Vector2(margin_px, margin_px)
	var grid_min = main.world_to_grid(view_min) - Vector2i(1, 1)
	var grid_max = main.world_to_grid(view_max) + Vector2i(1, 1)

	# Collect visible building anchors and walls into a unified list
	var all_positions: Array[Vector2i] = []
	var _wall_set := _cached_wall_set

	for grid_pos in main.placed_buildings:
		if main.is_building_anchor(grid_pos):
			if grid_pos.x >= grid_min.x and grid_pos.x <= grid_max.x and grid_pos.y >= grid_min.y and grid_pos.y <= grid_max.y:
				all_positions.append(grid_pos)

	for grid_pos in _wall_set:
		if grid_pos.x >= grid_min.x and grid_pos.x <= grid_max.x and grid_pos.y >= grid_min.y and grid_pos.y <= grid_max.y:
			all_positions.append(grid_pos)

	# Sort so further ones draw first (painter's algorithm)
	all_positions.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var world_a = main.grid_to_world(a) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		var world_b = main.grid_to_world(b) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		var dist_a = world_a.distance_squared_to(cam_center)
		var dist_b = world_b.distance_squared_to(cam_center)
		return dist_a > dist_b
	)

	var gs := float(main.GRID_SIZE)

	# --- PASS 1: Draw ALL sides ---
	for grid_pos in all_positions:
		var world_pos = main.grid_to_world(grid_pos)
		var margin := 0
		var offset: Vector2
		var side_color: Color
		var side_color_darker: Color
		var width: float
		var height: float

		if _wall_set.has(grid_pos):
			if terrain == null:
				continue
			var _ss_side = get_node_or_null("/root/Main/SectorScript")
			if _ss_side and _ss_side.is_tile_hidden(grid_pos):
				continue
			var fade_alpha := _get_wall_fade_alpha(grid_pos)
			var tile_data = Registry.get_tile(terrain.wall_tiles[grid_pos])
			if tile_data == null or tile_data.height <= 0:
				continue
			offset = _get_top_offset(world_pos)
			side_color = tile_data.get_side_color()
			side_color_darker = tile_data.get_side_color_dark()
			# Darken sides based on distance from floor (blend toward black)
			var darkness := 1.0 - fade_alpha
			side_color = side_color.lerp(Color.BLACK, darkness)
			side_color_darker = side_color_darker.lerp(Color.BLACK, darkness)
			width = float(main.GRID_SIZE) - margin * 2
			height = width
		else:
			# Skip buildings in hidden areas
			var ss = get_node_or_null("/root/Main/SectorScript")
			if ss and ss.is_tile_hidden(grid_pos):
				continue
			var block_id = main.placed_buildings[grid_pos]
			var block_size = _get_block_grid_size(block_id)
			var side_colors = _get_side_colors(block_id)
			offset = _get_top_offset(world_pos) * _get_height_scale(block_id)
			side_color = side_colors[0]
			side_color_darker = side_colors[1]
			width = float(main.GRID_SIZE) * block_size.x - margin * 2
			height = float(main.GRID_SIZE) * block_size.y - margin * 2

		var b_tl = world_pos + Vector2(margin, margin)
		var b_tr = world_pos + Vector2(margin + width, margin)
		var b_br = world_pos + Vector2(margin + width, margin + height)
		var b_bl = world_pos + Vector2(margin, margin + height)
		var t_tl = b_tl + offset
		var t_tr = b_tr + offset
		var t_br = b_br + offset
		var t_bl = b_bl + offset

		if abs(offset.x) > 0.5 or abs(offset.y) > 0.5:
			# Walls occlude sides where adjacent wall/building exists
			var is_wall := _wall_set.has(grid_pos)
			var draw_south := true
			var draw_north := true
			var draw_east := true
			var draw_west := true
			if is_wall:
				draw_south = not (_wall_set.has(grid_pos + Vector2i(0, 1)) or main.placed_buildings.has(grid_pos + Vector2i(0, 1)))
				draw_north = not (_wall_set.has(grid_pos + Vector2i(0, -1)) or main.placed_buildings.has(grid_pos + Vector2i(0, -1)))
				draw_east = not (_wall_set.has(grid_pos + Vector2i(1, 0)) or main.placed_buildings.has(grid_pos + Vector2i(1, 0)))
				draw_west = not (_wall_set.has(grid_pos + Vector2i(-1, 0)) or main.placed_buildings.has(grid_pos + Vector2i(-1, 0)))

			if offset.y < 0 and draw_south:
				draw_polygon([b_bl, b_br, t_br, t_bl], [side_color, side_color, side_color, side_color])
			if offset.y > 0 and draw_north:
				draw_polygon([b_tl, b_tr, t_tr, t_tl], [side_color, side_color, side_color, side_color])
			if offset.x < 0 and draw_east:
				draw_polygon([b_tr, b_br, t_br, t_tr], [side_color_darker, side_color_darker, side_color_darker, side_color_darker])
			if offset.x > 0 and draw_west:
				draw_polygon([b_tl, b_bl, t_bl, t_tl], [side_color_darker, side_color_darker, side_color_darker, side_color_darker])

	# --- PASS 2: Draw ALL top faces ---
	for grid_pos in all_positions:
		var world_pos = main.grid_to_world(grid_pos)
		var margin := 0

		# Wall tile top face
		if _wall_set.has(grid_pos):
			if terrain == null:
				continue
			# Skip hidden walls entirely — visible wall gradients handle the transition
			var _ss_wall = get_node_or_null("/root/Main/SectorScript")
			if _ss_wall and _ss_wall.is_tile_hidden(grid_pos):
				continue
			var top_size = float(main.GRID_SIZE) - margin * 2
			var tile_data = Registry.get_tile(terrain.wall_tiles[grid_pos])
			if tile_data == null:
				continue
			var w_offset = _get_top_offset(world_pos) if tile_data.height > 0 else Vector2.ZERO
			var w_top_pos = world_pos + Vector2(margin, margin) + w_offset
			var top_rect = Rect2(w_top_pos, Vector2(top_size, top_size))
			# Draw texture/color at full opacity
			if tile_data.icon:
				draw_texture_rect(tile_data.icon, top_rect, false)
			else:
				draw_rect(top_rect, tile_data.color, true)
			if tile_data.draw_border:
				draw_rect(top_rect, tile_data.border_color, false, 1.0)
			# Ore overlay
			if terrain.ore_tiles.has(grid_pos):
				var ore_data = Registry.get_tile(terrain.ore_tiles[grid_pos])
				if ore_data:
					if ore_data.icon:
						draw_texture_rect(ore_data.icon, top_rect, false, Color(1, 1, 1, ore_data.opacity))
					else:
						var ore_color = ore_data.color
						ore_color.a = ore_data.opacity
						draw_rect(top_rect, ore_color, true)
			# Black fade overlay — uses pre-computed corner darkness (cached)
			var _fade_off: bool = "fade_enabled" in main and not main.fade_enabled
			var cd = _cached_corner_darkness.get(grid_pos)
			if cd != null and not _fade_off:
				var pts: PackedVector2Array = [
					w_top_pos,
					w_top_pos + Vector2(top_size, 0),
					w_top_pos + Vector2(top_size, top_size),
					w_top_pos + Vector2(0, top_size),
				]
				var cols: PackedColorArray = [
					Color(0, 0, 0, cd[0]),
					Color(0, 0, 0, cd[1]),
					Color(0, 0, 0, cd[2]),
					Color(0, 0, 0, cd[3]),
				]
				draw_polygon(pts, cols)
			# Health bar
			if tile_data.destructible and terrain.tile_health.has(grid_pos):
				var pct = terrain.tile_health[grid_pos] / tile_data.max_health
				if pct < 1.0:
					var bar_w := 40.0
					var bar_h := 4.0
					var bar_pos = w_top_pos + Vector2((main.GRID_SIZE - bar_w) / 2.0, -8.0)
					draw_rect(Rect2(bar_pos, Vector2(bar_w, bar_h)), Color(0.2, 0, 0, 0.8), true)
					draw_rect(Rect2(bar_pos, Vector2(bar_w * pct, bar_h)), Color(1.0 - pct, pct, 0), true)
			continue

		# Skip buildings in hidden areas
		var sector_script_draw = get_node_or_null("/root/Main/SectorScript")
		if sector_script_draw and sector_script_draw.is_tile_hidden(grid_pos):
			continue

		var block_id = main.placed_buildings[grid_pos]
		var block_size = _get_block_grid_size(block_id)
		var offset = _get_top_offset(world_pos) * _get_height_scale(block_id)

		var width: float = float(main.GRID_SIZE) * block_size.x - margin * 2
		var height: float = float(main.GRID_SIZE) * block_size.y - margin * 2
		var top_pos = (world_pos + Vector2(margin, margin) + offset)

		var data = Registry.get_block(block_id)

		# Conveyor belts use auto-tiled textures based on neighbors
		if block_id == &"conveyor_belt" and not _belt_textures.is_empty():
			var info = _get_belt_draw_info(grid_pos)
			var texture: Texture2D = info["texture"]
			var angle: float = info["angle"]
			if texture:
				var center = top_pos + Vector2(width / 2.0, height / 2.0)
				draw_set_transform(center, angle)
				draw_texture_rect(texture, Rect2(Vector2(-width / 2.0, -height / 2.0), Vector2(width, height)), false)
				draw_set_transform(Vector2.ZERO, 0.0)
			else:
				var color = _get_block_color(block_id)
				draw_rect(Rect2(top_pos, Vector2(width, height)), color, true)
				draw_rect(Rect2(top_pos, Vector2(width, height)), color.lightened(0.3), false, 2.0)

		# Fluid pumps: draw with pump texture (check before pipes since pumps also have transports_fluid)
		elif data and data.tags.has("pump") and _pump_texture:
			var rot: int = main.building_rotation.get(grid_pos, 0)
			var angle: float = rot * PI / 2.0 + PI / 2.0
			var center = top_pos + Vector2(width / 2.0, height / 2.0)
			draw_set_transform(center, angle)
			draw_texture_rect(_pump_texture, Rect2(Vector2(-width / 2.0, -height / 2.0), Vector2(width, height)), false)
			draw_set_transform(Vector2.ZERO, 0.0)

		# Fluid pipes: draw colored fill rectangle UNDER the pipe texture
		elif data and data.transports_fluid and _pipe_texture:
			# Draw fluid fill first (colored rect with opacity based on fill level)
			if _logistics and _logistics.pipe_contents.has(grid_pos):
				var pipe = _logistics.pipe_contents[grid_pos]
				var fluid = Registry.get_fluid(pipe["fluid_id"])
				if fluid:
					var fill_pct := clampf(pipe["amount"] / fluid.units_per_segment, 0.0, 1.0)
					var fill_color: Color = Color(fluid.color)
					fill_color.a = fill_pct * fluid.opacity
					draw_rect(Rect2(top_pos, Vector2(width, height)), fill_color, true)

			# Draw pipe texture on top
			var rot: int = main.building_rotation.get(grid_pos, 0)
			var angle: float = rot * PI / 2.0 + PI / 2.0
			var center = top_pos + Vector2(width / 2.0, height / 2.0)
			draw_set_transform(center, angle)
			draw_texture_rect(_pipe_texture, Rect2(Vector2(-width / 2.0, -height / 2.0), Vector2(width, height)), false)
			draw_set_transform(Vector2.ZERO, 0.0)

		else:
			var top_rect := Rect2(top_pos, Vector2(width, height))
			var is_dir: bool = _is_directional(block_id)
			var rot: int = main.building_rotation.get(grid_pos, 0) if is_dir else 0
			# Faction-layered rendering (cores): base sprite + faction overlay
			if data and data.base_sprite:
				_draw_block_texture(data.base_sprite, top_pos, width, height, rot)
				var faction: int = main.get_building_faction(grid_pos)
				if faction == FACTION_FEROX and data.ferox_overlay:
					_draw_block_texture(data.ferox_overlay, top_pos, width, height, rot)
				elif faction == FACTION_DERELICT and data.derelict_overlay:
					_draw_block_texture(data.derelict_overlay, top_pos, width, height, rot)
				elif data.lumina_overlay:
					_draw_block_texture(data.lumina_overlay, top_pos, width, height, rot)
			# Regular icon texture
			elif data and data.icon:
				# Shafts: rotate texture +90° (visual only)
				var draw_rot: int = (rot + 1) % 4 if data.tags.has("shaft") else rot
				_draw_block_texture(data.icon, top_pos, width, height, draw_rot)
			# Fallback: colored rectangle
			else:
				var color = _get_block_color(block_id)
				draw_rect(top_rect, color, true)
				draw_rect(top_rect, color.lightened(0.3), false, 2.0)

		# Sorter filter indicator: small colored square in center
		if _logistics and data and (data.tags.has("sorter") or data.tags.has("inverted_sorter")):
			var filter_id: StringName = _logistics.sorter_filters.get(grid_pos, &"")
			if filter_id != &"":
				var filter_item = Registry.get_item(filter_id)
				if filter_item:
					var ind_size := 16.0
					var ind_pos = top_pos + Vector2((width - ind_size) / 2.0, (height - ind_size) / 2.0)
					draw_rect(Rect2(ind_pos, Vector2(ind_size, ind_size)), filter_item.color, true)
					draw_rect(Rect2(ind_pos, Vector2(ind_size, ind_size)), filter_item.color.lightened(0.3), false, 1.0)

	# --- PASS 2.25: Build animation overlay (left-to-right reveal) ---
	var _ss_build = get_node_or_null("/root/Main/SectorScript")
	var has_build_progress: bool = "building_build_progress" in main
	for grid_pos in all_positions:
		if _wall_set.has(grid_pos):
			continue
		if _ss_build and _ss_build.is_tile_hidden(grid_pos):
			continue
		if not has_build_progress or not main.building_build_progress.has(grid_pos):
			continue
		var build_pct: float = main.get_build_progress_pct(grid_pos)
		if build_pct >= 1.0:
			continue
		var b_block_id = main.placed_buildings[grid_pos]
		var b_block_size = _get_block_grid_size(b_block_id)
		var b_world_pos = main.grid_to_world(grid_pos)
		var b_offset = _get_top_offset(b_world_pos) * _get_height_scale(b_block_id)
		var b_margin := 0
		var b_width: float = float(main.GRID_SIZE) * b_block_size.x - b_margin * 2
		var b_height: float = float(main.GRID_SIZE) * b_block_size.y - b_margin * 2
		var b_top_pos = b_world_pos + Vector2(b_margin, b_margin) + b_offset

		# Check if this is the currently-building entry or just queued
		var is_active_build: bool = "build_order" in main and not main.build_order.is_empty() and main.build_order[0] == grid_pos
		if is_active_build:
			# Active build: left-to-right reveal animation
			var reveal_x: float = b_width * build_pct
			# Dark overlay on the not-yet-built portion (right side)
			var unbuilt_rect = Rect2(
				b_top_pos.x + reveal_x, b_top_pos.y,
				b_width - reveal_x, b_height
			)
			draw_rect(unbuilt_rect, Color(0, 0, 0, 0.65), true)
			# Yellow construction line at the reveal front
			var line_x: float = b_top_pos.x + reveal_x
			draw_line(
				Vector2(line_x, b_top_pos.y),
				Vector2(line_x, b_top_pos.y + b_height),
				Color(1.0, 0.9, 0.2, 0.9), 2.0
			)
		else:
			# Queued but not yet building: dim overlay with dotted outline
			draw_rect(Rect2(b_top_pos, Vector2(b_width, b_height)), Color(0, 0, 0, 0.55), true)
			draw_rect(Rect2(b_top_pos, Vector2(b_width, b_height)), Color(0.5, 0.5, 0.5, 0.4), false, 1.0)

	# --- PASS 2.3: Deconstruct animation overlay (right-to-left, red line) ---
	var _has_decon: bool = "building_deconstruct_progress" in main
	for grid_pos in all_positions:
		if _wall_set.has(grid_pos):
			continue
		if not _has_decon or not main.building_deconstruct_progress.has(grid_pos):
			continue
		var d_entry: Dictionary = main.building_deconstruct_progress[grid_pos]
		var d_block_id: StringName = d_entry["block_id"]
		var d_block_size = _get_block_grid_size(d_block_id)
		var d_world_pos = main.grid_to_world(grid_pos)
		var d_offset = _get_top_offset(d_world_pos) * _get_height_scale(d_block_id)
		var d_width: float = float(main.GRID_SIZE) * d_block_size.x
		var d_height: float = float(main.GRID_SIZE) * d_block_size.y
		var d_top_pos = d_world_pos + d_offset

		var is_active_decon: bool = "deconstruct_order" in main and not main.deconstruct_order.is_empty() and main.deconstruct_order[0] == grid_pos
		if is_active_decon:
			var d_pct: float = clampf(d_entry["progress"] / d_entry["build_time"], 0.0, 1.0)
			# Right-to-left: the deconstructed portion grows from the right
			var decon_x: float = d_width * (1.0 - d_pct)
			# Dark overlay on the deconstructed portion (right side)
			var decon_rect = Rect2(
				d_top_pos.x + decon_x, d_top_pos.y,
				d_width - decon_x, d_height
			)
			draw_rect(decon_rect, Color(0, 0, 0, 0.65), true)
			# Red deconstruction line at the front
			var line_x: float = d_top_pos.x + decon_x
			draw_line(
				Vector2(line_x, d_top_pos.y),
				Vector2(line_x, d_top_pos.y + d_height),
				Color(0.9, 0.2, 0.2, 0.9), 2.0
			)
		else:
			# Queued for deconstruction: dim red overlay
			draw_rect(Rect2(d_top_pos, Vector2(d_width, d_height)), Color(0.3, 0, 0, 0.4), true)
			draw_rect(Rect2(d_top_pos, Vector2(d_width, d_height)), Color(0.9, 0.2, 0.2, 0.4), false, 1.0)

	# --- PASS 2.5: Faction tint on enemy buildings ---
	var _ss = get_node_or_null("/root/Main/SectorScript")
	for grid_pos in all_positions:
		if _wall_set.has(grid_pos):
			continue
		if _ss and _ss.is_tile_hidden(grid_pos):
			continue
		var bfaction: int = main.get_building_faction(grid_pos)
		if bfaction == FACTION_LUMINA:
			continue
		var block_size_f = _get_block_grid_size(main.placed_buildings[grid_pos])
		var world_pos_f = main.grid_to_world(grid_pos)
		var offset_f = _get_top_offset(world_pos_f) * _get_height_scale(main.placed_buildings[grid_pos])
		var margin_f := -1.0
		var width_f: float = float(main.GRID_SIZE) * block_size_f.x - margin_f * 2
		var height_f: float = float(main.GRID_SIZE) * block_size_f.y - margin_f * 2
		var top_pos_f = world_pos_f + Vector2(margin_f, margin_f) + offset_f
		if bfaction == FACTION_DERELICT:
			# Gray/purple tint for derelict
			draw_rect(Rect2(top_pos_f, Vector2(width_f, height_f)), Color(0.5, 0.5, 0.6, 0.2), true)
			draw_rect(Rect2(top_pos_f, Vector2(width_f, height_f)), Color(0.6, 0.6, 0.7, 0.4), false, 2.0)
		else:
			# Red tint for FEROX
			draw_rect(Rect2(top_pos_f, Vector2(width_f, height_f)), Color(1.0, 0.2, 0.2, 0.18), true)
			draw_rect(Rect2(top_pos_f, Vector2(width_f, height_f)), Color(1.0, 0.3, 0.3, 0.45), false, 2.0)

	# --- PASS 3: Draw direction arrows on directional buildings ---
	for grid_pos in all_positions:
		if _wall_set.has(grid_pos):
			continue
		if _ss and _ss.is_tile_hidden(grid_pos):
			continue
		var block_id = main.placed_buildings[grid_pos]
		if not _is_directional(block_id):
			continue

		var rotation = main.building_rotation.get(grid_pos, 0)
		var block_size = _get_block_grid_size(block_id)
		var world_pos = main.grid_to_world(grid_pos)
		var offset = _get_top_offset(world_pos) * _get_height_scale(block_id)
		# Center the arrow in the middle of the full building
		var center = world_pos + Vector2(
			main.GRID_SIZE * block_size.x / 2.0,
			main.GRID_SIZE * block_size.y / 2.0
		) + offset

		_draw_direction_arrow(center, rotation, Color(1, 1, 1, 0.6))

	# --- PASS 4: Draw health bars on damaged buildings ---
	for grid_pos in all_positions:
		if _wall_set.has(grid_pos):
			continue
		if _ss and _ss.is_tile_hidden(grid_pos):
			continue
		var health_pct = main.get_building_health_pct(grid_pos)
		if health_pct < 1.0:
			var block_id = main.placed_buildings[grid_pos]
			var block_size = _get_block_grid_size(block_id)
			var world_pos = main.grid_to_world(grid_pos)
			var offset = _get_top_offset(world_pos) * _get_height_scale(block_id)
			# Center the health bar over the full building
			var bar_center_x = world_pos.x + main.GRID_SIZE * block_size.x / 2.0
			_draw_building_health_bar(
				Vector2(bar_center_x, world_pos.y) + offset,
				health_pct,
				main.GRID_SIZE * block_size.x
			)

	# --- PASS 5: Draw "no power" indicator on unpowered buildings ---
	var power_sys = get_node_or_null("/root/Main/PowerSystem")
	if power_sys:
		for grid_pos in all_positions:
			if _wall_set.has(grid_pos):
				continue
			if _ss and _ss.is_tile_hidden(grid_pos):
				continue
			var block_id = main.placed_buildings[grid_pos]
			var data = Registry.get_block(block_id)
			if data == null:
				continue
			# Only show indicator on buildings that need rotational or electrical power
			var needs_rot: bool = data.rotational_power_use > 0
			var needs_elec: bool = data.electrical_power_use > 0
			if not needs_rot and not needs_elec:
				continue
			var is_powered := true
			if needs_rot and not power_sys.is_rotational_powered(grid_pos):
				is_powered = false
			if needs_elec and not power_sys.is_electrical_powered(grid_pos):
				is_powered = false
			if is_powered:
				continue
			# Draw red "no power" overlay
			var block_size = _get_block_grid_size(block_id)
			var world_pos = main.grid_to_world(grid_pos)
			var offset = _get_top_offset(world_pos) * _get_height_scale(block_id)
			var margin := -1.0
			var width: float = float(main.GRID_SIZE) * block_size.x - margin * 2
			var height: float = float(main.GRID_SIZE) * block_size.y - margin * 2
			var top_pos = world_pos + Vector2(margin, margin) + offset
			# Semi-transparent red tint
			draw_rect(Rect2(top_pos, Vector2(width, height)),
				Color(1.0, 0.0, 0.0, 0.25), true)
			# Draw a small lightning bolt / "no power" icon
			var center = top_pos + Vector2(width / 2.0, height / 2.0)
			_draw_no_power_icon(center)


## Draws a direction arrow at the given center position.
func _draw_direction_arrow(center: Vector2, rotation: int, color: Color) -> void:
	var arrow_size := 14.0
	var dir = Vector2(DIR_VECTORS[rotation])

	# Arrow shaft
	var start_pt = center - dir * arrow_size * 0.5
	var end_pt = center + dir * arrow_size * 0.5
	draw_line(start_pt, end_pt, color, 2.5)

	# Arrowhead (two lines forming a V)
	var perp = Vector2(-dir.y, dir.x) * arrow_size * 0.35
	var back = dir * arrow_size * 0.4
	draw_line(end_pt, end_pt - back + perp, color, 2.5)
	draw_line(end_pt, end_pt - back - perp, color, 2.5)


## Draws a health bar centered above a building.
## bar_width_base is the pixel width of the building (scales with size).
func _draw_building_health_bar(world_pos: Vector2, health_pct: float, building_pixel_width: float = 64.0) -> void:
	var bar_width = clamp(building_pixel_width * 0.8, 30.0, 150.0)
	var bar_height := 5.0
	var bar_pos = world_pos + Vector2(
		(building_pixel_width - bar_width) / 2.0 - building_pixel_width / 2.0 + main.GRID_SIZE / 2.0,
		-10.0
	)

	draw_rect(
		Rect2(bar_pos, Vector2(bar_width, bar_height)),
		Color(0.2, 0.0, 0.0, 0.8),
		true
	)

	var fill_color = Color(1.0 - health_pct, health_pct, 0.0)
	draw_rect(
		Rect2(bar_pos, Vector2(bar_width * health_pct, bar_height)),
		fill_color,
		true
	)

	draw_rect(
		Rect2(bar_pos, Vector2(bar_width, bar_height)),
		Color(0.8, 0.8, 0.8, 0.5),
		false,
		1.0
	)


## Draws a small "no power" icon (lightning bolt with X) at the given center.
func _draw_no_power_icon(center: Vector2) -> void:
	var s := 10.0  # Scale factor
	var bolt_color := Color(1.0, 0.3, 0.3, 0.9)
	# Simple lightning bolt shape
	var points: PackedVector2Array = [
		center + Vector2(-2, -s),
		center + Vector2(2, -3),
		center + Vector2(-1, -1),
		center + Vector2(3, -1),
		center + Vector2(-1, s),
		center + Vector2(0, 2),
		center + Vector2(-4, 2),
	]
	for i in range(points.size() - 1):
		draw_line(points[i], points[i + 1], bolt_color, 2.0)
	# Draw X through it
	draw_line(center + Vector2(-s, -s), center + Vector2(s, s), Color(1.0, 0.0, 0.0, 0.7), 2.5)
	draw_line(center + Vector2(s, -s), center + Vector2(-s, s), Color(1.0, 0.0, 0.0, 0.7), 2.5)


func _draw_paused_queue() -> void:
	if _paused_queue.is_empty():
		return

	# Build a preview set of all queued positions + rotations for belt context
	var queue_set: Dictionary = {}
	var queue_rots: Dictionary = {}
	for entry in _paused_queue:
		queue_set[entry["grid_pos"]] = true
		queue_rots[entry["grid_pos"]] = entry["rotation"]

	for entry in _paused_queue:
		var grid_pos: Vector2i = entry["grid_pos"]
		var block_id: StringName = entry["block_id"]
		var rotation: int = entry["rotation"]
		var data = Registry.get_block(block_id)
		if data == null:
			continue
		var world_pos = main.grid_to_world(grid_pos)
		var offset = _get_top_offset(world_pos) * _get_height_scale(block_id)
		var w: float = float(main.GRID_SIZE) * data.grid_size.x
		var h: float = float(main.GRID_SIZE) * data.grid_size.y
		var top_pos = world_pos + offset

		# Draw belt texture preview or fallback ghost
		var is_belt_q: bool = block_id == &"conveyor_belt" and not _belt_textures.is_empty()
		if is_belt_q:
			var info: Dictionary = _get_belt_draw_info_with_preview(grid_pos, queue_set, queue_rots, block_id)
			var texture: Texture2D = info["texture"]
			var angle: float = info["angle"]
			if texture:
				var center: Vector2 = top_pos + Vector2(w / 2.0, h / 2.0)
				draw_set_transform(center, angle)
				draw_texture_rect(texture, Rect2(Vector2(-w / 2.0, -h / 2.0), Vector2(w, h)), false, Color(1, 1, 1, 0.45))
				draw_set_transform(Vector2.ZERO, 0.0)
			else:
				var color: Color = _get_block_color(block_id)
				color.a = 0.35
				draw_rect(Rect2(top_pos, Vector2(w, h)), color, true)
		else:
			var q_rot: int = rotation if _is_directional(block_id) else 0
			var tint := Color(1, 1, 1, 0.45)
			if data.icon:
				_draw_block_texture(data.icon, top_pos, w, h, q_rot, tint)
			else:
				var color: Color = _get_block_color(block_id)
				color.a = 0.35
				draw_rect(Rect2(top_pos, Vector2(w, h)), color, true)
				# Draw direction arrow for directional blocks without textures
				if _is_directional(block_id):
					var center = world_pos + Vector2(w / 2.0, h / 2.0) + offset
					_draw_direction_arrow(center, rotation, Color(1, 1, 1, 0.5))

		# Yellow outline for all queued blocks
		draw_rect(Rect2(top_pos, Vector2(w, h)), Color(1.0, 0.9, 0.2, 0.5), false, 1.5)


func _draw_preview() -> void:
	if main.selected_building == &"":
		return

	var data = Registry.get_block(main.selected_building)
	var grid_w = data.grid_size.x if data else 1
	var grid_h = data.grid_size.y if data else 1
	var is_dir := _is_directional(main.selected_building)

	# --- Drag-placing: draw a ghost at every cell in the line ---
	if _drag_placing and not _drag_cells.is_empty():
		var base_color = _get_block_color(main.selected_building)
		var valid_count := 0  # tracks how many valid cells so far for affordability
		var is_belt: bool = main.selected_building == &"conveyor_belt" and not _belt_textures.is_empty()

		# Build preview context for accurate belt textures
		var preview_set: Dictionary = {}
		var preview_rots: Dictionary = {}
		for cell in _drag_cells:
			preview_set[cell] = true
			if _pathfind_rotations.has(cell):
				preview_rots[cell] = _pathfind_rotations[cell]
			else:
				preview_rots[cell] = main.placement_rotation

		for cell in _drag_cells:
			var cell_valid := _can_place_at(cell, main.selected_building)
			var cell_affordable := _can_afford_n(main.selected_building, valid_count + 1)
			var cell_ok := cell_valid and cell_affordable

			if cell_ok:
				valid_count += 1

			var cell_world: Vector2 = main.grid_to_world(cell)
			var cell_offset := _get_top_offset(cell_world) * _get_height_scale(main.selected_building)
			var w: float = float(main.GRID_SIZE) * grid_w
			var h: float = float(main.GRID_SIZE) * grid_h
			var cell_pos: Vector2 = cell_world + cell_offset

			# Draw belt texture preview or fallback rectangle
			if is_belt:
				var info: Dictionary = _get_belt_draw_info_with_preview(cell, preview_set, preview_rots, main.selected_building)
				var texture: Texture2D = info["texture"]
				var angle: float = info["angle"]
				if texture:
					var tint: Color = Color(1, 1, 1, 0.6) if cell_ok else Color(1, 0.3, 0.3, 0.5)
					var center: Vector2 = cell_pos + Vector2(w / 2.0, h / 2.0)
					draw_set_transform(center, angle)
					draw_texture_rect(texture, Rect2(Vector2(-w / 2.0, -h / 2.0), Vector2(w, h)), false, tint)
					draw_set_transform(Vector2.ZERO, 0.0)
				else:
					var color: Color = base_color if cell_ok else Color(1, 0, 0, 0.4)
					color.a = 0.5
					draw_rect(Rect2(cell_pos, Vector2(w, h)), color, true)
			else:
				var cell_rot: int = preview_rots.get(cell, main.placement_rotation) if is_dir else 0
				var tint: Color = Color(1, 1, 1, 0.6) if cell_ok else Color(1, 0.3, 0.3, 0.5)
				# Try texture first
				if data and data.icon:
					var draw_rot: int = (cell_rot + 1) % 4 if data.tags.has("shaft") else cell_rot
					_draw_block_texture(data.icon, cell_pos, w, h, draw_rot, tint)
				else:
					var color: Color
					if cell_ok:
						color = base_color
						color.a = 0.5
					else:
						color = Color(1, 0, 0, 0.4)
					draw_rect(Rect2(cell_pos, Vector2(w, h)), color, true)
					draw_rect(Rect2(cell_pos, Vector2(w, h)), color.lightened(0.2), false, 2.0)

			if is_dir and not is_belt and not (data and data.icon):
				var cell_rot: int = preview_rots.get(cell, main.placement_rotation)
				var center: Vector2 = cell_world + Vector2(
					main.GRID_SIZE * grid_w / 2.0,
					main.GRID_SIZE * grid_h / 2.0
				) + cell_offset
				var arrow_color = Color(1, 1, 1, 0.8) if cell_ok else Color(1, 0.3, 0.3, 0.6)
				_draw_direction_arrow(center, cell_rot, arrow_color)
		return

	# --- Not dragging: single-cell hover preview ---
	var world_pos = main.grid_to_world(preview_grid_pos)
	var offset = _get_top_offset(world_pos) * _get_height_scale(main.selected_building)
	var color = _get_block_color(main.selected_building)
	var cell_ok: bool = can_place and main.can_afford(main.selected_building)

	var width: float = float(main.GRID_SIZE) * grid_w
	var height: float = float(main.GRID_SIZE) * grid_h
	var top_pos = world_pos + offset

	# Draw belt/pipe/duct texture preview or fallback rectangle
	var is_belt_hover: bool = main.selected_building == &"conveyor_belt" and not _belt_textures.is_empty()
	if is_belt_hover:
		var hover_set: Dictionary = {preview_grid_pos: true}
		var hover_rots: Dictionary = {preview_grid_pos: main.placement_rotation}
		var info: Dictionary = _get_belt_draw_info_with_preview(preview_grid_pos, hover_set, hover_rots, main.selected_building)
		var texture: Texture2D = info["texture"]
		var angle: float = info["angle"]
		if texture:
			var tint: Color = Color(1, 1, 1, 0.6) if cell_ok else Color(1, 0.3, 0.3, 0.5)
			var center: Vector2 = top_pos + Vector2(width / 2.0, height / 2.0)
			draw_set_transform(center, angle)
			draw_texture_rect(texture, Rect2(Vector2(-width / 2.0, -height / 2.0), Vector2(width, height)), false, tint)
			draw_set_transform(Vector2.ZERO, 0.0)
		else:
			if cell_ok:
				color.a = 0.5
			else:
				color = Color(1, 0, 0, 0.4)
			draw_rect(Rect2(top_pos, Vector2(width, height)), color, true)
	else:
		var hover_rot: int = main.placement_rotation if is_dir else 0
		var tint: Color = Color(1, 1, 1, 0.6) if cell_ok else Color(1, 0.3, 0.3, 0.5)
		# Try texture first
		if data and data.icon:
			var draw_rot: int = (hover_rot + 1) % 4 if data.tags.has("shaft") else hover_rot
			_draw_block_texture(data.icon, top_pos, width, height, draw_rot, tint)
		else:
			if cell_ok:
				color.a = 0.5
			else:
				color = Color(1, 0, 0, 0.4)
			draw_rect(Rect2(top_pos, Vector2(width, height)), color, true)
			draw_rect(Rect2(top_pos, Vector2(width, height)), color.lightened(0.2), false, 2.0)

	if is_dir and not is_belt_hover and not (data and data.icon):
		var center = world_pos + Vector2(
			main.GRID_SIZE * grid_w / 2.0,
			main.GRID_SIZE * grid_h / 2.0
		) + offset
		var arrow_color = Color(1, 1, 1, 0.8) if can_place else Color(1, 0.3, 0.3, 0.6)
		_draw_direction_arrow(center, main.placement_rotation, arrow_color)


## Draws the red demolish rectangle while the player is drag-selecting.
func _draw_demolish_rect() -> void:
	if not _demolish_dragging:
		return
	var min_x := mini(_demolish_start.x, _demolish_end.x)
	var min_y := mini(_demolish_start.y, _demolish_end.y)
	var max_x := maxi(_demolish_start.x, _demolish_end.x)
	var max_y := maxi(_demolish_start.y, _demolish_end.y)

	var top_left: Vector2 = main.grid_to_world(Vector2i(min_x, min_y))
	var width := float((max_x - min_x + 1) * main.GRID_SIZE)
	var height := float((max_y - min_y + 1) * main.GRID_SIZE)
	var offset := _get_top_offset(top_left)
	var rect_pos: Vector2 = top_left + offset

	# Filled red overlay
	draw_rect(Rect2(rect_pos, Vector2(width, height)), Color(1, 0, 0, 0.2), true)
	# Red outline
	draw_rect(Rect2(rect_pos, Vector2(width, height)), Color(1, 0, 0, 0.6), false, 2.0)


func _draw_rebuild_mode() -> void:
	if not _rebuild_mode:
		return

	var gs := float(main.GRID_SIZE)

	# Draw ghost previews of destroyed player buildings (very faded)
	if not "destroyed_player_buildings" in main:
		return
	for anchor in main.destroyed_player_buildings:
		var info: Dictionary = main.destroyed_player_buildings[anchor]
		var block_id: StringName = info["block_id"]
		var data = Registry.get_block(block_id)
		if data == null:
			continue
		var world_pos = main.grid_to_world(anchor)
		var offset = _get_top_offset(world_pos) * _get_height_scale(block_id)
		var w: float = gs * data.grid_size.x
		var h: float = gs * data.grid_size.y
		var top_pos = world_pos + offset
		# Very faded ghost
		var color: Color = _get_block_color(block_id)
		color.a = 0.15
		draw_rect(Rect2(top_pos, Vector2(w, h)), color, true)
		draw_rect(Rect2(top_pos, Vector2(w, h)), Color(0.816, 0.808, 0.886, 0.25), false, 1.0)

	# Draw selection rectangle if dragging
	if _rebuild_dragging:
		var min_x := mini(_rebuild_start.x, _rebuild_end.x)
		var min_y := mini(_rebuild_start.y, _rebuild_end.y)
		var max_x := maxi(_rebuild_start.x, _rebuild_end.x)
		var max_y := maxi(_rebuild_start.y, _rebuild_end.y)
		var top_left: Vector2 = main.grid_to_world(Vector2i(min_x, min_y))
		var width := float((max_x - min_x + 1) * main.GRID_SIZE)
		var height := float((max_y - min_y + 1) * main.GRID_SIZE)
		var offset := _get_top_offset(top_left)
		var rect_pos: Vector2 = top_left + offset
		draw_rect(Rect2(rect_pos, Vector2(width, height)), REBUILD_COLOR, true)
		draw_rect(Rect2(rect_pos, Vector2(width, height)), Color(0.816, 0.808, 0.886, 0.7), false, 2.0)


## Demolishes all buildings inside the rectangle and refunds their build costs.
func _demolish_rect(from: Vector2i, to: Vector2i) -> void:
	var min_x := mini(from.x, to.x)
	var min_y := mini(from.y, to.y)
	var max_x := maxi(from.x, to.x)
	var max_y := maxi(from.y, to.y)

	# Collect unique building anchors inside the rectangle
	var anchors := {}
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			var cell := Vector2i(x, y)
			if main.placed_buildings.has(cell):
				var block_id: StringName = main.placed_buildings[cell]
				var data = Registry.get_block(block_id)
				# Skip cores (check tag, not just ID)
				if data and data.tags.has("core"):
					continue
				# Skip enemy/derelict faction buildings
				if main.get_building_faction(cell) != FACTION_LUMINA:
					continue
				var anchor: Vector2i = main.building_origins.get(cell, cell)
				anchors[anchor] = block_id

	# Queue each unique building for deconstruction (not instant destroy)
	if main.has_method("start_deconstruct"):
		for anchor in anchors:
			main.start_deconstruct(anchor)


func _on_building_placed(_block_id: StringName, _grid_pos: Vector2i) -> void:
	_walls_dirty = true
	# Initialize crane state when a crane is placed
	var data = Registry.get_block(_block_id)
	if data and data.tags.has("crane"):
		crane_states[_grid_pos] = {
			"arm_angle": -PI / 2.0,
			"arm_extension": CRANE_ARM_MIN_TOTAL,
			"grabber_open": true,
			"grabber_angle": 0.0,
			"held_payload": null,
			"target_pos": Vector2.ZERO,
		}
	if data and data.id == &"archive":
		archive_holdings[_grid_pos] = &""
	if data and data.tags.has("archive_decoder"):
		archive_decoder_state[_grid_pos] = {
			"progress": 0.0,
			"archive_id": &"",
			"scanner": Vector2i(-9999, -9999),
		}
	queue_redraw()


func _on_building_destroyed(_grid_pos: Vector2i) -> void:
	_walls_dirty = true
	crane_states.erase(_grid_pos)
	archive_holdings.erase(_grid_pos)
	archive_decoder_state.erase(_grid_pos)
	# Clean up links involving this building
	var power_sys = get_node_or_null("/root/Main/PowerSystem")
	if power_sys and "linked_pairs" in power_sys:
		var to_remove := []
		for i in range(power_sys.linked_pairs.size()):
			var pair = power_sys.linked_pairs[i]
			if pair[0] == _grid_pos or pair[1] == _grid_pos:
				to_remove.append(i)
		for i in range(to_remove.size() - 1, -1, -1):
			power_sys.linked_pairs.remove_at(to_remove[i])
	queue_redraw()


## Draws visual lines between linked blocks and linking-mode highlights.
func _draw_links() -> void:
	var power_sys = get_node_or_null("/root/Main/PowerSystem")
	if power_sys == null:
		return

	# Draw existing links as dashed lines
	var _ss_link = get_node_or_null("/root/Main/SectorScript")
	var link_color := Color(0.3, 0.8, 1.0, 0.6)
	var gs: float = main.GRID_SIZE
	for pair in power_sys.linked_pairs:
		var pos_a: Vector2i = pair[0]
		var pos_b: Vector2i = pair[1]
		# Skip links to destroyed buildings
		if not main.placed_buildings.has(pos_a) or not main.placed_buildings.has(pos_b):
			continue
		if _ss_link and (_ss_link.is_tile_hidden(pos_a) or _ss_link.is_tile_hidden(pos_b)):
			continue
		# Get block center for multi-tile buildings
		var data_a = Registry.get_block(main.placed_buildings[pos_a])
		var data_b = Registry.get_block(main.placed_buildings[pos_b])
		var size_a: Vector2 = Vector2(data_a.grid_size) * gs if data_a else Vector2(gs, gs)
		var size_b: Vector2 = Vector2(data_b.grid_size) * gs if data_b else Vector2(gs, gs)
		var world_a: Vector2 = main.grid_to_world(pos_a) + size_a / 2.0
		var world_b: Vector2 = main.grid_to_world(pos_b) + size_b / 2.0
		world_a += _get_top_offset(main.grid_to_world(pos_a))
		world_b += _get_top_offset(main.grid_to_world(pos_b))
		_draw_dashed_line(world_a, world_b, link_color, 2.0, 8.0)
		draw_circle(world_a, 4.0, link_color)
		draw_circle(world_b, 4.0, link_color)

	# Draw linking-mode highlights
	if not linking_mode:
		return

	# Highlight all linkable blocks (only anchors, not every tile)
	var highlighted_anchors := {}
	for grid_pos in main.placed_buildings:
		var anchor_pos: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if highlighted_anchors.has(anchor_pos):
			continue
		var block_id = main.placed_buildings[anchor_pos]
		var data = Registry.get_block(block_id)
		if data == null or not data.tags.has("linkable"):
			continue
		highlighted_anchors[anchor_pos] = true
		var world_pos: Vector2 = main.grid_to_world(anchor_pos)
		var offset = _get_top_offset(world_pos)
		var rect_pos: Vector2 = world_pos + offset
		var block_w: float = data.grid_size.x * gs
		var block_h: float = data.grid_size.y * gs
		var highlight_color := Color(0.3, 0.8, 1.0, 0.3)
		if anchor_pos == link_source:
			highlight_color = Color(0.0, 1.0, 0.5, 0.5)
		draw_rect(Rect2(rect_pos, Vector2(block_w, block_h)), highlight_color, true)
		draw_rect(Rect2(rect_pos, Vector2(block_w, block_h)), highlight_color.lightened(0.3), false, 2.0)

	# Draw line from source to mouse if source is selected
	if link_source != Vector2i(-1, -1):
		var source_world = main.grid_to_world(link_source) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		source_world += _get_top_offset(main.grid_to_world(link_source))
		var mouse_pos = get_global_mouse_position()
		_draw_dashed_line(source_world, mouse_pos, Color(0.3, 1.0, 0.5, 0.5), 2.0, 6.0)


## Draws a dashed line between two points.
func _draw_dashed_line(from: Vector2, to: Vector2, color: Color, width: float, dash_length: float) -> void:
	var direction = to - from
	var length = direction.length()
	if length < 1.0:
		return
	var normalized = direction / length
	var drawn := 0.0
	var drawing := true
	while drawn < length:
		var segment = minf(dash_length, length - drawn)
		if drawing:
			var start = from + normalized * drawn
			var end = from + normalized * (drawn + segment)
			draw_line(start, end, color, width)
		drawn += dash_length
		drawing = not drawing


# =========================
# SCHEMATIC SYSTEM
# =========================

func _draw_schematic_rect() -> void:
	if not _schematic_dragging and not _schematic_confirmed:
		return
	var min_x: int = mini(_schematic_start.x, _schematic_end.x)
	var min_y: int = mini(_schematic_start.y, _schematic_end.y)
	var max_x: int = maxi(_schematic_start.x, _schematic_end.x)
	var max_y: int = maxi(_schematic_start.y, _schematic_end.y)
	var top_left: Vector2 = main.grid_to_world(Vector2i(min_x, min_y))
	var w: float = float((max_x - min_x + 1) * main.GRID_SIZE)
	var h: float = float((max_y - min_y + 1) * main.GRID_SIZE)
	var offset: Vector2 = _get_top_offset(top_left)
	var rect_pos: Vector2 = top_left + offset
	draw_rect(Rect2(rect_pos, Vector2(w, h)), Color(1, 0.9, 0, 0.2), true)
	draw_rect(Rect2(rect_pos, Vector2(w, h)), Color(1, 0.9, 0, 0.6), false, 2.0)
	if _schematic_confirmed:
		# Draw "Press Enter to save" text
		var font: Font = ThemeDB.fallback_font
		var text_pos: Vector2 = rect_pos + Vector2(4, -6)
		draw_string(font, text_pos, "Press Enter to save schematic", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 0.9, 0.3))


func _capture_schematic_rect(from: Vector2i, to: Vector2i) -> Dictionary:
	var min_pos := Vector2i(mini(from.x, to.x), mini(from.y, to.y))
	var max_pos := Vector2i(maxi(from.x, to.x), maxi(from.y, to.y))
	var blocks: Dictionary = {}
	var rotation: Dictionary = {}
	var anchors_seen: Dictionary = {}
	for x in range(min_pos.x, max_pos.x + 1):
		for y in range(min_pos.y, max_pos.y + 1):
			var pos := Vector2i(x, y)
			if not main.placed_buildings.has(pos):
				continue
			var anchor: Vector2i = main.building_origins.get(pos, pos)
			if anchors_seen.has(anchor):
				continue
			anchors_seen[anchor] = true
			# Skip if anchor is outside the rect
			if anchor.x < min_pos.x or anchor.x > max_pos.x or anchor.y < min_pos.y or anchor.y > max_pos.y:
				continue
			var block_id: StringName = main.placed_buildings[anchor]
			var rot: int = main.building_rotation.get(anchor, 0)
			var rel: Vector2i = anchor - min_pos
			var key: String = "%d,%d" % [rel.x, rel.y]
			blocks[key] = String(block_id)
			if rot != 0:
				rotation[key] = rot
	var w: int = max_pos.x - min_pos.x + 1
	var h: int = max_pos.y - min_pos.y + 1
	return {"blocks": blocks, "rotation": rotation, "width": w, "height": h}


func _show_schematic_save_dialog() -> void:
	if _schematic_popup and is_instance_valid(_schematic_popup):
		_schematic_popup.queue_free()

	var captured: Dictionary = _capture_schematic_rect(_schematic_start, _schematic_end)
	if captured["blocks"].is_empty():
		_schematic_mode = false
		_schematic_confirmed = false
		return

	_schematic_popup = PopupPanel.new()
	_schematic_popup.size = Vector2(320, 400)
	add_child(_schematic_popup)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	_schematic_popup.add_child(vbox)

	var title = Label.new()
	title.text = "Save Schematic"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1, 0.9, 0.3))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	vbox.add_child(HSeparator.new())

	# Block summary
	var block_counts: Dictionary = {}
	for key in captured["blocks"]:
		var bid: String = captured["blocks"][key]
		block_counts[bid] = block_counts.get(bid, 0) + 1

	var summary_label = Label.new()
	summary_label.text = "Blocks:"
	summary_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(summary_label)

	var summary_scroll = ScrollContainer.new()
	summary_scroll.custom_minimum_size.y = 100
	vbox.add_child(summary_scroll)
	var summary_vbox = VBoxContainer.new()
	summary_scroll.add_child(summary_vbox)

	for bid in block_counts:
		var data = Registry.get_block(StringName(bid))
		var display_name: String = data.display_name if data else bid
		var lbl = Label.new()
		lbl.text = "  %dx %s" % [block_counts[bid], display_name]
		lbl.add_theme_font_size_override("font_size", 11)
		summary_vbox.add_child(lbl)

	vbox.add_child(HSeparator.new())

	# Total cost
	var cost_label = Label.new()
	cost_label.text = "Total Cost:"
	cost_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(cost_label)

	var total_cost: Dictionary = {}
	for key in captured["blocks"]:
		var bid: StringName = StringName(captured["blocks"][key])
		var data = Registry.get_block(bid)
		if data:
			for item_id in data.build_cost:
				total_cost[item_id] = total_cost.get(item_id, 0) + data.build_cost[item_id]

	for item_id in total_cost:
		var item_data = Registry.get_item(item_id)
		var hbox = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 4)
		if item_data and item_data.icon:
			var tex = TextureRect.new()
			tex.texture = item_data.icon
			tex.custom_minimum_size = Vector2(14, 14)
			tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			hbox.add_child(tex)
		var clbl = Label.new()
		var dn: String = item_data.display_name if item_data else String(item_id)
		clbl.text = "%s: %d" % [dn, total_cost[item_id]]
		clbl.add_theme_font_size_override("font_size", 11)
		hbox.add_child(clbl)
		vbox.add_child(hbox)

	vbox.add_child(HSeparator.new())

	# Name input
	var name_label = Label.new()
	name_label.text = "Name:"
	name_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(name_label)

	var name_input = LineEdit.new()
	name_input.placeholder_text = "Schematic name..."
	vbox.add_child(name_input)

	# Buttons
	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(func():
		_schematic_popup.queue_free()
		_schematic_mode = false
		_schematic_confirmed = false
		queue_redraw()
	)
	btn_row.add_child(cancel_btn)

	var save_btn = Button.new()
	save_btn.text = "Save"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cap_ref: Dictionary = captured
	save_btn.pressed.connect(func():
		var sname: String = name_input.text.strip_edges()
		if sname == "":
			sname = "Unnamed"
		SaveManager.save_schematic(sname, cap_ref["blocks"], cap_ref["rotation"], cap_ref["width"], cap_ref["height"])
		_schematic_popup.queue_free()
		_schematic_mode = false
		_schematic_confirmed = false
		queue_redraw()
	)
	btn_row.add_child(save_btn)

	_schematic_popup.popup_centered()


## Called by HUD to enter schematic placement mode.
func start_schematic_placement(data: Dictionary) -> void:
	_schematic_place_blocks.clear()
	_schematic_place_rotation.clear()
	var blocks_data: Dictionary = data.get("blocks", {})
	var rot_data: Dictionary = data.get("rotation", {})
	for key in blocks_data:
		var parts: PackedStringArray = key.split(",")
		if parts.size() >= 2:
			var pos := Vector2i(int(parts[0]), int(parts[1]))
			_schematic_place_blocks[pos] = StringName(blocks_data[key])
			if rot_data.has(key):
				_schematic_place_rotation[pos] = int(rot_data[key])
	_schematic_place_width = int(data.get("width", 1))
	_schematic_place_height = int(data.get("height", 1))
	_placing_schematic = true
	main.select_building(&"")  # Exit build mode
	queue_redraw()


func _draw_schematic_placement() -> void:
	if not _placing_schematic:
		return
	var mouse_world: Vector2 = get_global_mouse_position()
	var base_grid: Vector2i = main.world_to_grid(mouse_world)
	var gs: float = float(main.GRID_SIZE)

	for rel_pos in _schematic_place_blocks:
		var grid_pos: Vector2i = base_grid + rel_pos
		var block_id: StringName = _schematic_place_blocks[rel_pos]
		var data = Registry.get_block(block_id)
		if data == null:
			continue
		var world_pos: Vector2 = main.grid_to_world(grid_pos)
		var offset: Vector2 = _get_top_offset(world_pos) * _get_height_scale(block_id)
		var w: float = gs * data.grid_size.x
		var h: float = gs * data.grid_size.y
		var top_pos: Vector2 = world_pos + offset

		# Check if placeable
		var can_place: bool = true
		var terrain = get_node_or_null("/root/Main/TerrainSystem")
		for dx in range(data.grid_size.x):
			for dy in range(data.grid_size.y):
				var cp: Vector2i = grid_pos + Vector2i(dx, dy)
				if not main.is_within_bounds(cp) or not main.is_cell_empty(cp):
					can_place = false
				elif terrain and terrain.has_wall(cp):
					can_place = false

		var color: Color = _get_block_color(block_id)
		if can_place:
			color.a = 0.4
			draw_rect(Rect2(top_pos, Vector2(w, h)), color, true)
			draw_rect(Rect2(top_pos, Vector2(w, h)), Color(0.3, 1.0, 0.3, 0.6), false, 1.5)
		else:
			color = Color(1.0, 0.3, 0.3, 0.3)
			draw_rect(Rect2(top_pos, Vector2(w, h)), color, true)
			draw_rect(Rect2(top_pos, Vector2(w, h)), Color(1.0, 0.3, 0.3, 0.6), false, 1.5)


func _execute_schematic_placement() -> void:
	var mouse_world: Vector2 = get_global_mouse_position()
	var base_grid: Vector2i = main.world_to_grid(mouse_world)
	var placed := 0
	for rel_pos in _schematic_place_blocks:
		var grid_pos: Vector2i = base_grid + rel_pos
		var block_id: StringName = _schematic_place_blocks[rel_pos]
		var rot: int = _schematic_place_rotation.get(rel_pos, 0)
		if main.place_building_for_schematic(grid_pos, block_id, rot):
			placed += 1
	print("BuildingSystem: Placed %d/%d schematic blocks." % [placed, _schematic_place_blocks.size()])
	_placing_schematic = false
	queue_redraw()


# =========================
# CRANE — TELESCOPING ARM + CROSS GRABBER
# =========================

const CRANE_ROTATE_SPEED := 1    # Radians per second
const CRANE_EXTEND_SPEED := 300.0 # Pixels per second

## Updates crane arm angle and extension toward target at constant speed.
func update_crane_telescope(anchor: Vector2i, target: Vector2, delta: float) -> void:
	if not crane_states.has(anchor):
		return
	var state: Dictionary = crane_states[anchor]
	var data = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if data == null:
		return
	var gs: float = main.GRID_SIZE
	var base: Vector2 = main.grid_to_world(anchor) + Vector2(data.grid_size.x * gs / 2.0, data.grid_size.y * gs / 2.0)

	var max_reach: float = data.crane_range * gs
	var to_target: Vector2 = target - base
	var target_dist: float = clampf(to_target.length(), CRANE_ARM_MIN_TOTAL, max_reach)
	var target_angle: float = to_target.angle() if to_target.length() > 1.0 else state["arm_angle"]

	# Rotate at constant speed
	var angle_diff: float = wrapf(target_angle - state["arm_angle"], -PI, PI)
	var max_rotate: float = CRANE_ROTATE_SPEED * delta
	if absf(angle_diff) <= max_rotate:
		state["arm_angle"] = target_angle
	else:
		state["arm_angle"] = wrapf(state["arm_angle"] + signf(angle_diff) * max_rotate, -PI, PI)

	# Extend/retract at constant speed
	var ext_diff: float = target_dist - state["arm_extension"]
	var max_extend: float = CRANE_EXTEND_SPEED * delta
	if absf(ext_diff) <= max_extend:
		state["arm_extension"] = target_dist
	else:
		state["arm_extension"] += signf(ext_diff) * max_extend


## Draws all crane telescoping arms and cross grabbers.
func _draw_cranes() -> void:
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	for anchor in crane_states:
		if not main.placed_buildings.has(anchor):
			continue
		var state: Dictionary = crane_states[anchor]
		var data = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null:
			continue
		var gs: float = main.GRID_SIZE
		var base: Vector2 = main.grid_to_world(anchor) + Vector2(data.grid_size.x * gs / 2.0, data.grid_size.y * gs / 2.0)

		var angle: float = state["arm_angle"]
		var ext: float = state["arm_extension"]
		var arm_dir: Vector2 = Vector2(cos(angle), sin(angle))

		# Distribute extension: arm3 extends first to max, then arm2, then arm1.
		# Each has a minimum length it never goes below.
		var remaining: float = maxf(ext - CRANE_ARM_MIN_TOTAL, 0.0)

		# Arm3 (innermost, thinnest) extends first
		var arm3_extra: float = minf(remaining, CRANE_ARM3_MAX - CRANE_ARM3_MIN)
		remaining -= arm3_extra
		# Arm2 (middle) extends second
		var arm2_extra: float = minf(remaining, CRANE_ARM2_MAX - CRANE_ARM2_MIN)
		remaining -= arm2_extra
		# Arm1 (outermost, widest) extends last
		var arm1_extra: float = minf(remaining, CRANE_ARM1_MAX - CRANE_ARM1_MIN)

		var seg1_len: float = CRANE_ARM1_MIN + arm1_extra
		var seg2_len: float = CRANE_ARM2_MIN + arm2_extra
		var seg3_len: float = CRANE_ARM3_MIN + arm3_extra

		var seg1_end: Vector2 = base + arm_dir * seg1_len
		var seg2_end: Vector2 = seg1_end + arm_dir * seg2_len
		var seg3_end: Vector2 = seg2_end + arm_dir * seg3_len
		var arm_end: Vector2 = seg3_end

		# --- Grabber position: slides along the arm to reach the mouse ---
		# The grabber can travel anywhere from the base to arm_end
		var target: Vector2 = state["target_pos"]
		var to_target_dist: float = (target - base).length()
		var total_arm_len: float = seg1_len + seg2_len + seg3_len
		var grabber_t: float = clampf(to_target_dist / total_arm_len, 0.0, 1.0)
		var grabber_pos: Vector2 = base + arm_dir * (grabber_t * total_arm_len)

		var holding: bool = state["held_payload"] != null
		var cs: float = CRANE_GRABBER_SIZE * (0.7 if holding else 1.0)
		var grabber_thickness: float = 6.0
		var grabber_color := Color(0.6, 0.5, 0.2, 0.9)
		var g_angle: float = state.get("grabber_angle", 0.0)

		# --- Draw held payload UNDER everything (first) ---
		if holding:
			var payload: Dictionary = state["held_payload"]
			if payload.get("type", "") == "building":
				var block_data = Registry.get_block(StringName(payload.get("block_id", "")))
				if block_data:
					var bw: float = block_data.grid_size.x * gs
					var bh: float = block_data.grid_size.y * gs
					if block_data.icon:
						# Use smooth grabber_angle for directional blocks, fixed for non-directional
						var visual_angle: float = g_angle + PI / 2.0  # +90° base offset for textures
						if block_data.tags.has("shaft"):
							visual_angle += PI / 2.0  # Extra +90° for shafts
						draw_set_transform(grabber_pos, visual_angle)
						draw_texture_rect(block_data.icon, Rect2(-bw / 2.0, -bh / 2.0, bw, bh), false, Color(1, 1, 1, 0.55))
						draw_set_transform(Vector2.ZERO, 0.0)
					else:
						draw_rect(Rect2(grabber_pos.x - bw / 2.0, grabber_pos.y - bh / 2.0, bw, bh), Color(block_data.color.r, block_data.color.g, block_data.color.b, 0.45), true)
					# Outline (axis-aligned)
					draw_rect(Rect2(grabber_pos.x - bw / 2.0, grabber_pos.y - bh / 2.0, bw, bh), Color(1, 1, 1, 0.25), false, 2.0)
			elif payload.get("type", "") == "unit":
				var unit_data = Registry.get_unit(StringName(payload.get("unit_id", "")))
				if unit_data:
					if unit_data.icon:
						var tex_size: Vector2 = unit_data.icon.get_size()
						draw_texture_rect(unit_data.icon, Rect2(grabber_pos.x - tex_size.x / 2.0, grabber_pos.y - tex_size.y / 2.0, tex_size.x, tex_size.y), false, Color(1, 1, 1, 0.6))
					else:
						# Draw the unit's actual shape and color
						var us: float = unit_data.visual_size if unit_data.visual_size > 0 else 8.0
						var uc: Color = unit_data.color if unit_data.color != Color() else Color(0.5, 0.8, 0.3)
						uc.a = 0.7
						draw_circle(grabber_pos, us, uc)
						draw_arc(grabber_pos, us, 0, TAU, 24, uc.lightened(0.3), 1.5)
				else:
					draw_circle(grabber_pos, 8.0, Color(0.3, 0.5, 0.9, 0.45))

		# --- Draw cross grabber UNDER the arm (rotates with grabber_angle) ---
		draw_set_transform(grabber_pos, g_angle)
		# Horizontal bar
		draw_rect(Rect2(-cs, -grabber_thickness / 2.0, cs * 2, grabber_thickness), grabber_color, true)
		# Vertical bar
		draw_rect(Rect2(-grabber_thickness / 2.0, -cs, grabber_thickness, cs * 2), grabber_color, true)
		draw_set_transform(Vector2.ZERO, 0.0)

		# --- Draw arm segments ON TOP of grabber and payload ---
		# Segment 1 (outermost, widest — base)
		var c1: Vector2 = (base + seg1_end) / 2.0
		draw_set_transform(c1, angle)
		draw_rect(Rect2(-seg1_len / 2.0, -CRANE_ARM1_WIDTH / 2.0, seg1_len, CRANE_ARM1_WIDTH), Color(0.5, 0.5, 0.5, 0.85), true)
		draw_rect(Rect2(-seg1_len / 2.0, -CRANE_ARM1_WIDTH / 2.0, seg1_len, CRANE_ARM1_WIDTH), Color(0.6, 0.6, 0.6, 0.3), false, 1.0)
		draw_set_transform(Vector2.ZERO, 0.0)

		# Segment 2 (middle — slides out from seg1)
		var c2: Vector2 = (seg1_end + seg2_end) / 2.0
		draw_set_transform(c2, angle)
		draw_rect(Rect2(-seg2_len / 2.0, -CRANE_ARM2_WIDTH / 2.0, seg2_len, CRANE_ARM2_WIDTH), Color(0.42, 0.42, 0.42, 0.9), true)
		draw_rect(Rect2(-seg2_len / 2.0, -CRANE_ARM2_WIDTH / 2.0, seg2_len, CRANE_ARM2_WIDTH), Color(0.55, 0.55, 0.55, 0.3), false, 1.0)
		draw_set_transform(Vector2.ZERO, 0.0)

		# Segment 3 (innermost, thinnest — slides out from seg2)
		var c3: Vector2 = (seg2_end + seg3_end) / 2.0
		draw_set_transform(c3, angle)
		draw_rect(Rect2(-seg3_len / 2.0, -CRANE_ARM3_WIDTH / 2.0, seg3_len, CRANE_ARM3_WIDTH), Color(0.35, 0.35, 0.35, 0.95), true)
		draw_rect(Rect2(-seg3_len / 2.0, -CRANE_ARM3_WIDTH / 2.0, seg3_len, CRANE_ARM3_WIDTH), Color(0.5, 0.5, 0.5, 0.3), false, 1.0)
		draw_set_transform(Vector2.ZERO, 0.0)

		# Draw range circle when controlled
		if unit_mgr and unit_mgr.controlled_type == "crane" and unit_mgr.controlled_entity == anchor:
			var range_px: float = data.crane_range * gs
			draw_arc(base, range_px, 0, TAU, 64, Color(0.4, 0.8, 0.4, 0.15), 1.5)

		# Draw base pivot circle
		draw_circle(base, 5.0, Color(0.6, 0.6, 0.6, 0.7))


# =========================
# ARCHIVE DECODING
# =========================

## Ticks every active archive decoder. A decoder is active when:
##   - it has electrical power
##   - an archive scanner is in one of its 4 cardinal neighbors (and powered)
##   - that scanner's front edge faces an archive block (and powered if applicable)
##   - the archive's archive_id is set (non-empty)
## When progress reaches the decoder's production_time, fires
## Main.archive_decoded(archive_id) and resets state.
func _tick_archive_decoders(delta: float) -> void:
	if archive_decoder_state.is_empty():
		return
	var power_sys = get_node_or_null("/root/Main/PowerSystem")

	for anchor in archive_decoder_state.keys():
		if not main.placed_buildings.has(anchor):
			archive_decoder_state.erase(anchor)
			continue
		var data = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null or not data.tags.has("archive_decoder"):
			continue
		var state: Dictionary = archive_decoder_state[anchor]

		# 1. Decoder must be powered electrically
		if power_sys and not power_sys.is_electrical_powered(anchor):
			state["progress"] = 0.0
			state["archive_id"] = &""
			continue

		# 2. Find a touching, powered archive scanner whose front faces an archive
		var scanner_pos: Vector2i = Vector2i(-9999, -9999)
		var archive_id: StringName = &""
		var archive_pos: Vector2i = Vector2i(-9999, -9999)
		var found := false
		for dir_idx in range(4):
			var n: Vector2i = anchor + DIR_VECTORS[dir_idx]
			if not main.placed_buildings.has(n):
				continue
			var n_anchor: Vector2i = main.building_origins.get(n, n)
			var n_data = Registry.get_block(main.placed_buildings.get(n_anchor, &""))
			if n_data == null or not n_data.tags.has("archive_scanner"):
				continue
			# Scanner must also be electrically powered
			if power_sys and not power_sys.is_electrical_powered(n_anchor):
				continue
			# Find the archive that scanner is facing
			var rot: int = main.building_rotation.get(n_anchor, 0)
			var front_cells = _get_front_edge(n_anchor, n_data.grid_size, rot)
			for cell in front_cells:
				if not main.placed_buildings.has(cell):
					continue
				var a_anchor: Vector2i = main.building_origins.get(cell, cell)
				var a_data = Registry.get_block(main.placed_buildings.get(a_anchor, &""))
				if a_data == null or a_data.id != &"archive":
					continue
				var aid: StringName = archive_holdings.get(a_anchor, &"")
				if aid == &"":
					continue
				# Skip already-decoded archives
				if TechTree.is_researched(aid):
					continue
				scanner_pos = n_anchor
				archive_id = aid
				archive_pos = a_anchor
				found = true
				break
			if found:
				break

		if not found:
			state["progress"] = 0.0
			state["archive_id"] = &""
			continue

		# 3. Track which archive we're decoding (reset progress if it changed)
		if state.get("archive_id", &"") != archive_id:
			state["archive_id"] = archive_id
			state["progress"] = 0.0
			state["scanner"] = scanner_pos
		state["scanner"] = scanner_pos

		# 4. Tick progress
		var cycle: float = data.production_time if data.production_time > 0 else 8.0
		state["progress"] += delta
		if state["progress"] >= cycle:
			state["progress"] = 0.0
			state["archive_id"] = &""
			# Fire the decoded signal — TechTree's archive_decoded rule will research
			# any -D-archive_id markers and the dependent nodes.
			if main.has_signal("archive_decoded"):
				main.archive_decoded.emit(archive_id)
