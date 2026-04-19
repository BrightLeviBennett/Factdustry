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
var parallax_enabled := true
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

# --- DRILL HEAD TEXTURES ---
# Keyed by variant: "N" = both ores directly in front, "A" = both ores +1 ahead,
# "R" = texture-left ore directly, texture-right ore +1 ahead,
# "L" = texture-right ore directly, texture-left ore +1 ahead.
# Texture default orientation: drill facing DOWN (heads extending south).
var _drill_head_textures: Dictionary = {}

# --- CRUSHER HEAD TEXTURE ---
# Single gear-like sprite used for both heads on every "crusher_heads" block.
# Two heads are drawn per crusher (one per front-edge cell), each spinning
# around its own center at a different rate + phase offset so they look
# mechanically independent. State is stateless — angles are derived from
# Time.get_ticks_msec() and the block's grid position.
var _crusher_head_texture: Texture2D
const CRUSHER_HEAD_SPIN_A := 3.7   # radians/sec target (head 0)
const CRUSHER_HEAD_SPIN_B := -4.2  # target: different speed AND direction (head 1)
# How fast each head's angular velocity eases toward its target (rad/s²).
# Smaller = more inertia / more noticeable spool-up + coast-down. Same rate is
# used for both accelerating and decelerating so stopping mirrors starting.
const CRUSHER_HEAD_ACCEL := 5.0
# Per-crusher rotation state. Key = anchor grid_pos. Value:
#   {"angle_a": float, "angle_b": float, "vel_a": float, "vel_b": float}
# Updated in _process when the world is not paused.
var _crusher_head_state: Dictionary = {}

# --- CABLE WIRE TEXTURE ---
var _wire_texture: Texture2D

# --- CACHED REFERENCES ---
# SectorScript is created by Main._ready AFTER its Registry await, which can
# be after our own _ready runs. So these are cached *opportunistically* in
# _ready but fall back to a live get_node_or_null on first miss.
var _logistics: Node2D
var _terrain: Node2D
var _sector_script: Node
var _power_sys: Node


## Lazy accessors — populate the cache the first time the node exists.
func _sector_script_ref() -> Node:
	if _sector_script == null:
		_sector_script = get_node_or_null("/root/Main/SectorScript")
	return _sector_script


func _terrain_ref() -> Node2D:
	if _terrain == null:
		_terrain = get_node_or_null("/root/Main/TerrainSystem")
	return _terrain


func _power_sys_ref() -> Node:
	if _power_sys == null:
		_power_sys = get_node_or_null("/root/Main/PowerSystem")
	return _power_sys

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
## Prebuilt mesh batching every visible wall's fade quad. Rebuilt with the
## wall cache, drawn in one draw_mesh call per frame with a parallax
## transform applied at draw time.
var _wall_fade_mesh: ArrayMesh = null
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
## Bridge pairs that need auto-linking after placement: Array of [Vector2i, Vector2i]
var _pathfind_bridge_pairs: Array = []
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
	# Kick off all texture loads on background threads so they can overlap
	# with Registry essentials + main/sector initialization. They're resolved
	# the first time _draw() runs (see _ensure_textures_loaded).
	_queue_texture_loads()
	main.building_placed.connect(_on_building_placed)
	main.building_destroyed.connect(_on_building_destroyed)
	# Cache references to sibling systems (available after first frame)
	await get_tree().process_frame
	_logistics = get_node_or_null("/root/Main/LogisticsSystem")
	_terrain = get_node_or_null("/root/Main/TerrainSystem")
	_sector_script = get_node_or_null("/root/Main/SectorScript")
	_power_sys = get_node_or_null("/root/Main/PowerSystem")
	# Connect terrain changes to invalidate wall cache
	if _terrain:
		_terrain.connect("walls_changed", _on_walls_changed)


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

	# Rebuild the batched fade mesh so the per-frame cost is one draw_mesh.
	_rebuild_wall_fade_mesh(terrain)


## Builds an ArrayMesh covering every visible wall with a per-corner gradient
## quad at its grid position (no parallax baked in — that's applied at draw
## time via a Transform2D so it still follows the camera).
func _rebuild_wall_fade_mesh(terrain: Node) -> void:
	_wall_fade_mesh = null
	if _cached_corner_darkness.is_empty() or terrain == null:
		return
	var gs := float(main.GRID_SIZE)
	var ss := _sector_script_ref()
	# Local tile-data memo — few unique wall tile types, so this collapses the
	# Registry.get_tile calls down to a handful.
	var tile_cache: Dictionary = {}

	var valid_positions: Array[Vector2i] = []
	for grid_pos in _cached_corner_darkness:
		if ss and ss.is_tile_hidden(grid_pos):
			continue
		if not terrain.wall_tiles.has(grid_pos):
			continue
		var wid: StringName = terrain.wall_tiles[grid_pos]
		var tile_data: TerrainTileData
		if tile_cache.has(wid):
			tile_data = tile_cache[wid]
		else:
			tile_data = Registry.get_tile(wid)
			tile_cache[wid] = tile_data
		if tile_data == null or tile_data.height <= 0:
			continue
		valid_positions.append(grid_pos)

	if valid_positions.is_empty():
		return

	var count: int = valid_positions.size()
	var verts: PackedVector3Array = PackedVector3Array()
	verts.resize(count * 4)
	var cols: PackedColorArray = PackedColorArray()
	cols.resize(count * 4)
	var idxs: PackedInt32Array = PackedInt32Array()
	idxs.resize(count * 6)
	var vi: int = 0
	var ii: int = 0
	for grid_pos in valid_positions:
		var cd: Array = _cached_corner_darkness[grid_pos]
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
	_wall_fade_mesh = ArrayMesh.new()
	_wall_fade_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)


# --- TEXTURE STREAMING ---
# The 13 block textures below used to be sync load()s at _ready() (~50-100ms
# serialized). Now every path is kicked off via load_threaded_request() in
# parallel and resolved lazily on the first _draw().
const _BELT_TEX_PATHS := {
	"straight": "res://textures/blocks/item transportation/Belt/Belt.png",
	"jr":       "res://textures/blocks/item transportation/Belt/Belt-JR.png",
	"jl":       "res://textures/blocks/item transportation/Belt/Belt-JL.png",
	"ja":       "res://textures/blocks/item transportation/Belt/Belt-JA.png",
	"ca":       "res://textures/blocks/item transportation/Belt/Belt-CA.png",
	"cb":       "res://textures/blocks/item transportation/Belt/Belt-CB.png",
}
const _DRILL_HEAD_TEX_PATHS := {
	"N": "res://textures/blocks/resource extractors/MechanicalDrill/DrillHeads-N.png",
	"R": "res://textures/blocks/resource extractors/MechanicalDrill/DrillHeads-R.png",
	"L": "res://textures/blocks/resource extractors/MechanicalDrill/DrillHeads-L.png",
	"A": "res://textures/blocks/resource extractors/MechanicalDrill/DrillHeads-A.png",
}
const _PIPE_TEX_PATH := "res://textures/blocks/fluid transportation/FluidConduit.png"
const _PUMP_TEX_PATH := "res://textures/blocks/fluid transportation/FluidPump.png"
const _WIRE_TEX_PATH := "res://textures/blocks/power/CopperWire.png"
const _CRUSHER_HEAD_TEX_PATH := "res://textures/blocks/resource extractors/WallCrusher/CrusherHead.png"

var _textures_ready: bool = false


## Issues threaded-load requests for every texture we need. Non-blocking.
func _queue_texture_loads() -> void:
	for key in _BELT_TEX_PATHS:
		ResourceLoader.load_threaded_request(_BELT_TEX_PATHS[key])
	for key in _DRILL_HEAD_TEX_PATHS:
		ResourceLoader.load_threaded_request(_DRILL_HEAD_TEX_PATHS[key])
	ResourceLoader.load_threaded_request(_PIPE_TEX_PATH)
	ResourceLoader.load_threaded_request(_PUMP_TEX_PATH)
	ResourceLoader.load_threaded_request(_WIRE_TEX_PATH)
	ResourceLoader.load_threaded_request(_CRUSHER_HEAD_TEX_PATH)


## Blocks until all queued textures are resolved, then stashes them.
## Called once before the first real draw — at that point the threaded
## loads are typically already done so this is effectively free.
func _ensure_textures_loaded() -> void:
	if _textures_ready:
		return
	for key in _BELT_TEX_PATHS:
		_belt_textures[key] = ResourceLoader.load_threaded_get(_BELT_TEX_PATHS[key])
	for key in _DRILL_HEAD_TEX_PATHS:
		_drill_head_textures[key] = ResourceLoader.load_threaded_get(_DRILL_HEAD_TEX_PATHS[key])
	_pipe_texture = ResourceLoader.load_threaded_get(_PIPE_TEX_PATH)
	_pump_texture = ResourceLoader.load_threaded_get(_PUMP_TEX_PATH)
	_wire_texture = ResourceLoader.load_threaded_get(_WIRE_TEX_PATH)
	_crusher_head_texture = ResourceLoader.load_threaded_get(_CRUSHER_HEAD_TEX_PATH)
	_textures_ready = true


## Returns the DrillHeads texture variant ("N", "R", "L", "A") to use
## for a drill at grid_pos with the given rotation and grid_size.
## Texture default is "drill facing down"; L/R are defined relative to the
## texture's own left/right slots (which rotate together with the drill).
##
## The drill mines front-edge cells and the cells one tile beyond them.
## "Directly in front" = ore sits on the front-edge cell itself.
## "Not directly in front" = front-edge cell is empty but cell one tile ahead has ore.
## If either head has no ore at all (invalid placement), fall back to "N".
func _get_drill_head_variant(grid_pos: Vector2i, rotation: int, grid_size: Vector2i) -> String:
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if terrain == null:
		return "N"

	var dir: Vector2i
	match rotation:
		0: dir = Vector2i(1, 0)
		1: dir = Vector2i(0, 1)
		2: dir = Vector2i(-1, 0)
		3: dir = Vector2i(0, -1)
		_: dir = Vector2i(1, 0)

	var front_cells := _get_front_edge(grid_pos, grid_size, rotation)
	if front_cells.size() < 2:
		return "N"

	# Map _get_front_edge's cells to the texture's left/right slots.
	# _get_front_edge ordering + texture rotation of (rotation-1)*90° produces:
	var tex_left_cell: Vector2i
	var tex_right_cell: Vector2i
	match rotation:
		0:
			tex_left_cell = front_cells[1]
			tex_right_cell = front_cells[0]
		1:
			tex_left_cell = front_cells[0]
			tex_right_cell = front_cells[1]
		2:
			tex_left_cell = front_cells[0]
			tex_right_cell = front_cells[1]
		3:
			tex_left_cell = front_cells[1]
			tex_right_cell = front_cells[0]
		_:
			tex_left_cell = front_cells[0]
			tex_right_cell = front_cells[1]

	# A head is "extended" only when ore is one tile PAST the front edge
	# (i.e. not directly in front) — the head physically has to reach forward.
	# If the front cell has ore directly, or has nothing at all, the head
	# rests in its short/default position.
	var left_extended := terrain.get_ore_at(tex_left_cell) == null \
		and terrain.get_ore_at(tex_left_cell + dir) != null
	var right_extended := terrain.get_ore_at(tex_right_cell) == null \
		and terrain.get_ore_at(tex_right_cell + dir) != null

	if not left_extended and not right_extended:
		return "N"
	if left_extended and not right_extended:
		return "L"
	if right_extended and not left_extended:
		return "R"
	return "A"


## Draws the DrillHeads overlay texture in front of a drill.
## The texture spans grid_size.x tiles wide (matching drill width) by 2 tiles
## in the forward direction (covering the front edge + one tile ahead), rotated
## so its default "facing down" orientation aligns with the drill's rotation.
func _draw_drill_heads(grid_pos: Vector2i, rotation: int, grid_size: Vector2i,
		variant: String, block_id: StringName, tint: Color = Color.WHITE) -> void:
	var texture: Texture2D = _drill_head_textures.get(variant)
	if texture == null:
		return

	var gs := float(main.GRID_SIZE)
	var world_pos: Vector2 = main.grid_to_world(grid_pos)
	var offset: Vector2 = _get_top_offset(world_pos) * _get_height_scale(block_id)

	# Drill body center in world space.
	var body_center: Vector2 = world_pos + Vector2(
		grid_size.x * gs / 2.0,
		grid_size.y * gs / 2.0
	) + offset

	# Forward unit vector (in world space) for this rotation.
	var fwd: Vector2
	match rotation:
		0: fwd = Vector2(1, 0)
		1: fwd = Vector2(0, 1)
		2: fwd = Vector2(-1, 0)
		3: fwd = Vector2(0, -1)
		_: fwd = Vector2(1, 0)

	# Texture dimensions in texture-space: width = drill width (tiles),
	# height = 2 tiles (front edge + one tile ahead).
	var heads_depth := 2.0
	var w: float = grid_size.x * gs
	var h: float = heads_depth * gs

	# Drill body half-extent along the forward direction.
	var drill_half_fwd: float
	if abs(fwd.x) > 0.5:
		drill_half_fwd = grid_size.x * gs / 2.0
	else:
		drill_half_fwd = grid_size.y * gs / 2.0

	# Position the heads-rect center: body center offset by
	# (half drill depth + half heads depth) along forward.
	var heads_center: Vector2 = body_center + fwd * (drill_half_fwd + h / 2.0)

	# Texture default faces DOWN (rot=1). Extra rotation = (rotation - 1) * 90°.
	var angle: float = (rotation - 1) * PI / 2.0

	draw_set_transform(heads_center, angle)
	draw_texture_rect(texture, Rect2(Vector2(-w / 2.0, -h / 2.0), Vector2(w, h)), false, tint)
	draw_set_transform(Vector2.ZERO, 0.0)


## Draws two gear-style crusher heads on a block tagged "crusher_heads".
## One head is placed on the inner edge of each front-edge cell (the edge
## touching the crusher body), with the texture centered on that edge — so
## half the gear sits in the crusher and half pokes into the front cell.
## When `spinning` is true the two heads rotate independently (different
## rates + per-block phase offsets derived from grid_pos); when false they
## stay at a fixed per-block orientation. The preview and any inactive
## placed crusher pass spinning=false.
func _draw_crusher_heads(grid_pos: Vector2i, rotation: int, grid_size: Vector2i,
		block_id: StringName, tint: Color = Color.WHITE,
		spinning: bool = true) -> void:
	if _crusher_head_texture == null:
		return

	var gs := float(main.GRID_SIZE)
	var world_pos: Vector2 = main.grid_to_world(grid_pos)
	var offset: Vector2 = _get_top_offset(world_pos) * _get_height_scale(block_id)

	# Front-edge cells (one per head) — same mapping _get_front_edge produces.
	var front_cells := _get_front_edge(grid_pos, grid_size, rotation)
	if front_cells.size() < 2:
		return

	# Forward unit vector for the block. Used to shift each head back toward
	# the crusher body by half a tile so the texture center lands on the
	# inner edge of the front-cell (crusher side).
	var fwd: Vector2
	match rotation:
		0: fwd = Vector2(1, 0)
		1: fwd = Vector2(0, 1)
		2: fwd = Vector2(-1, 0)
		3: fwd = Vector2(0, -1)
		_: fwd = Vector2(1, 0)

	# Square sprite centered at the pivot. Drawn below native-size so the
	# gears sit comfortably inside a single tile — tweak CRUSHER_HEAD_SCALE
	# at the top of this script (or inline here) if you want them bigger.
	const CRUSHER_HEAD_SCALE := 0.5
	var tex_size: Vector2 = _crusher_head_texture.get_size() * CRUSHER_HEAD_SCALE
	var tex_rect := Rect2(-tex_size * 0.5, tex_size)

	# Per-block phase offsets — derived from grid_pos so neighboring crushers
	# stay visually desynced. Used both for the spin animation and the
	# resting angle when the crusher isn't running.
	var seed_a: int = grid_pos.x * 73 + grid_pos.y * 31
	var seed_b: int = grid_pos.x * 17 + grid_pos.y * 53
	var phase_a: float = fposmod(float(seed_a), TAU)
	var phase_b: float = fposmod(float(seed_b), TAU)

	var angle_a: float = phase_a
	var angle_b: float = phase_b
	if spinning:
		# Placed crushers read live inertial state maintained by _process.
		# Initialize lazily at rest pose so the first draw works even if no
		# tick has happened yet (the tick will start easing velocity up/down
		# on subsequent frames).
		if not _crusher_head_state.has(grid_pos):
			_crusher_head_state[grid_pos] = {
				"angle_a": phase_a, "angle_b": phase_b,
				"vel_a": 0.0, "vel_b": 0.0,
			}
		var s: Dictionary = _crusher_head_state[grid_pos]
		angle_a = float(s["angle_a"])
		angle_b = float(s["angle_b"])
	var angles: Array = [angle_a, angle_b]

	for i in range(2):
		var cell: Vector2i = front_cells[i]
		var cell_center: Vector2 = main.grid_to_world(cell) + Vector2(gs * 0.5, gs * 0.5) + offset
		# Shift back toward the crusher by half a tile → head sits on the
		# shared edge between the crusher body and the front cell.
		var head_pos: Vector2 = cell_center - fwd * (gs * 0.5)
		draw_set_transform(head_pos, angles[i])
		draw_texture_rect(_crusher_head_texture, tex_rect, false, tint)
		draw_set_transform(Vector2.ZERO, 0.0)


## Returns true if a placed crusher should currently be spinning — i.e. it's
## finished construction, powered, not disabled by sector script, AND has at
## least one output item it can still produce (storage slot available OR an
## adjacent conveyor that can accept it). Matches the productivity checks
## the LogisticsSystem drill loop uses.
func _is_crusher_spinning(anchor: Vector2i, data: BlockData) -> bool:
	if data == null:
		return false
	# Under-construction / deconstructing crushers don't spin.
	if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
		return false
	# Sector-script-disabled blocks don't spin.
	var ss = _sector_script_ref()
	if ss and ss.has_method("is_building_disabled") and ss.is_building_disabled(anchor):
		return false
	# Not electrically powered → no spin.
	if data.electrical_power_use > 0:
		var ps = _power_sys_ref()
		if ps == null or not ps.is_electrical_powered(anchor):
			return false
	# Storage full on every output → stall.
	var logistics = _logistics
	if logistics and logistics.has_method("_is_storage_full_for"):
		var any_room := false
		for raw_id in data.output_items:
			var item_id: StringName = StringName(raw_id)
			if not logistics._is_storage_full_for(anchor, data, item_id):
				any_room = true
				break
		if not any_room and not data.output_items.is_empty():
			return false
	return true


## Per-frame inertial tick for every crusher head in the world. For each
## tracked anchor, eases its two head velocities toward their target spin
## (or 0 when idle) at CRUSHER_HEAD_ACCEL rad/s², then integrates angle.
## Also garbage-collects state for destroyed/untagged blocks.
func _tick_crusher_head_states(delta: float) -> void:
	if _crusher_head_state.is_empty():
		return
	var to_erase: Array[Vector2i] = []
	for anchor in _crusher_head_state:
		if not main.placed_buildings.has(anchor):
			to_erase.append(anchor)
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings[anchor])
		if data == null or not data.tags.has("crusher_heads"):
			to_erase.append(anchor)
			continue
		var active := _is_crusher_spinning(anchor, data)
		var target_a: float = CRUSHER_HEAD_SPIN_A if active else 0.0
		var target_b: float = CRUSHER_HEAD_SPIN_B if active else 0.0
		var s: Dictionary = _crusher_head_state[anchor]
		var step: float = CRUSHER_HEAD_ACCEL * delta
		s["vel_a"] = move_toward(float(s["vel_a"]), target_a, step)
		s["vel_b"] = move_toward(float(s["vel_b"]), target_b, step)
		s["angle_a"] = fposmod(float(s["angle_a"]) + float(s["vel_a"]) * delta, TAU)
		s["angle_b"] = fposmod(float(s["angle_b"]) + float(s["vel_b"]) * delta, TAU)
	for a in to_erase:
		_crusher_head_state.erase(a)


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
	# Pause-aware crusher-head inertial tick. While the world is paused the
	# per-block velocity/angle both freeze in place; when unpaused they ease
	# back in or out, giving each head a real spool-up/coast-down feel.
	if not ("world_paused" in main and main.world_paused):
		_tick_crusher_head_states(_delta)

	# --- Unified work queue: build + deconstruct, one at a time ---
	# Walk the queue and tick the first entry that's currently within build
	# range. Out-of-range entries are just skipped over (not removed) — they'll
	# pick up again once the drone returns. This lets the drone move on to
	# reachable work instead of stalling on a distant one. The _tickable_
	# variant also respects pause flags so paused games don't advance progress
	# (but the draw pass still highlights the frozen active anchor).
	var anchor: Vector2i = _get_tickable_work_anchor()
	if anchor != _NO_ACTIVE_WORK:
		if main.building_build_progress.has(anchor):
			_tick_progressive_build(anchor, _delta)
		elif main.building_deconstruct_progress.has(anchor):
			_tick_progressive_deconstruct(anchor, _delta)
		else:
			# Orphan entry (building destroyed externally) — remove
			main.work_order.erase(anchor)

	# Process placement queue: place entries that are now in build range
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

	# Tick archive decoders
	if not ("world_paused" in main and main.world_paused):
		_tick_archive_decoders(_delta)

	# --- The rest of _process (preview, drag, redraw) continues in the
	# indented block below. The tick helper functions follow after _process ends. ---

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
			_pathfind_bridge_pairs.clear()
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

			# Straight-line drags of a transport block also auto-junction
			# perpendicular crossings and auto-bridge parallel crossings so
			# the user doesn't have to hand-place those pieces. Uses the
			# same helper the Alt-pathfind branch uses.
			if _is_transport_block(main.selected_building) and _drag_cells.size() > 1:
				var tag2 := _get_transport_tag(main.selected_building)
				_drag_cells = _apply_transport_crossings(_drag_cells, tag2)
				if _is_directional(main.selected_building):
					_compute_path_rotations(_drag_cells)

	queue_redraw()


## Progressive build tick: consumes resources toward the build cost proportional
## to elapsed time. Pauses when no resources are available. Completes when all
## resources are consumed AND progress >= build_time.
func _tick_progressive_build(anchor: Vector2i, delta: float) -> void:
	var block_id: StringName = main.placed_buildings.get(anchor, &"")
	var data = Registry.get_block(block_id)
	if data == null:
		main.building_build_progress.erase(anchor)
		main.building_resources_consumed.erase(anchor)
		main.work_order.erase(anchor)
		return

	var consumed: Dictionary = main.building_resources_consumed.get(anchor, {})
	var build_time: float = data.build_time if data.build_time > 0 else 1.0

	# Advance progress
	main.building_build_progress[anchor] += delta
	var pct: float = clampf(main.building_build_progress[anchor] / build_time, 0.0, 1.0)

	# Try to consume resources proportional to progress
	var any_consumed := false
	var all_fully_consumed := true
	if main.require_resources and not data.build_cost.is_empty():
		for item_id in data.build_cost:
			var rk: StringName = main._resolve_resource_key(str(item_id))
			var required: int = int(data.build_cost[item_id])
			var target: int = ceili(pct * required)
			var already: int = int(consumed.get(rk, 0))
			var need: int = target - already
			if need > 0:
				var available: int = int(main.resources.get(rk, 0))
				var take: int = mini(need, available)
				if take > 0:
					main.resources[rk] -= take
					consumed[rk] = already + take
					any_consumed = true
				if consumed.get(rk, 0) < required:
					all_fully_consumed = false
			# already >= required is fine
		main.building_resources_consumed[anchor] = consumed

		# If nothing was consumed this tick AND not all consumed yet → stall progress
		if not any_consumed and not all_fully_consumed:
			# Rewind progress to match actual consumption
			var min_pct: float = 1.0
			for item_id in data.build_cost:
				var rk: StringName = main._resolve_resource_key(str(item_id))
				var required: int = int(data.build_cost[item_id])
				if required > 0:
					min_pct = minf(min_pct, float(consumed.get(rk, 0)) / float(required))
			main.building_build_progress[anchor] = min_pct * build_time
			return
	else:
		all_fully_consumed = true

	if any_consumed:
		main.resources_changed.emit(main.resources)

	# Completion: all resources consumed and enough time elapsed
	if all_fully_consumed and main.building_build_progress[anchor] >= build_time:
		main.building_build_progress.erase(anchor)
		main.building_resources_consumed.erase(anchor)
		# erase by value, not index — the active anchor may not be at [0]
		# if earlier entries were skipped for being out of build range.
		main.work_order.erase(anchor)
		# A newly-completed block flips from is_building_inactive=true to false,
		# so any system caching its presence needs to refresh. Power network
		# totals exclude inactive cells; flagging dirty lets it recompute on
		# the next tick so the new block participates in power balance.
		var ps := _power_sys_ref()
		if ps and "_networks_dirty" in ps:
			ps._networks_dirty = true


## Progressive deconstruct tick: advances deconstruct progress and proportionally
## refunds resources over the duration. When complete, destroys the building.
func _tick_progressive_deconstruct(anchor: Vector2i, delta: float) -> void:
	var entry: Dictionary = main.building_deconstruct_progress[anchor]
	entry["progress"] += delta

	# Proportionally refund resources
	var build_time: float = float(entry.get("build_time", 1.0))
	var pct: float = clampf(entry["progress"] / build_time, 0.0, 1.0)
	var total_refund: Dictionary = entry.get("total_refund", {})
	var refunded: Dictionary = main.building_resources_refunded.get(anchor, {})
	var any_refunded := false
	for rk in total_refund:
		var total: int = int(total_refund[rk])
		var target: int = floori(pct * total)
		var already: int = int(refunded.get(rk, 0))
		var give: int = target - already
		if give > 0:
			main.resources[rk] = main.resources.get(rk, 0) + give
			refunded[rk] = already + give
			any_refunded = true
	main.building_resources_refunded[anchor] = refunded
	if any_refunded:
		main.resources_changed.emit(main.resources)

	# Completion
	if entry["progress"] >= build_time:
		# Refund any remaining (rounding)
		for rk in total_refund:
			var total: int = int(total_refund[rk])
			var already: int = int(refunded.get(rk, 0))
			if already < total:
				main.resources[rk] = main.resources.get(rk, 0) + (total - already)
		main.building_deconstruct_progress.erase(anchor)
		main.building_resources_refunded.erase(anchor)
		# erase by value, not index — see _tick_progressive_build comment.
		main.work_order.erase(anchor)
		main.destroy_building(anchor)
		main.resources_changed.emit(main.resources)


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
	# If the new block is a member of a swap family (belt/duct/conduit/etc),
	# cells already holding another same-family block count as placeable —
	# the click handler in main.try_place_building will swap them.
	var new_swap_group: StringName = &""
	if data.grid_size == Vector2i(1, 1) and main.has_method("_get_swap_group"):
		new_swap_group = main._get_swap_group(data)
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
					elif cell_data and new_swap_group != &"" \
							and cell_data.grid_size == Vector2i(1, 1) \
							and main._get_swap_group(cell_data) == new_swap_group \
							and main.get_building_faction(check_pos) == main.Faction.LUMINA:
						# Swap-compatible: cell is placeable. The swap itself
						# happens in main.try_place_building.
						pass
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


## Returns the anchor of the work-order entry the drone should currently be
## building/deconstructing — i.e. the first entry in main.work_order that is
## still inside build range. Returns Vector2i(-9999,-9999) if nothing is in
## range or the queue is empty. NOTE: this function intentionally does NOT
## consider pause state, so the draw pass can keep rendering the active
## block's progress indicator (the reveal line / decon sweep) frozen at its
## current value while the game is paused. The pause guard lives in _process.
const _NO_ACTIVE_WORK := Vector2i(-9999, -9999)
func _get_active_work_anchor() -> Vector2i:
	if not ("work_order" in main) or main.work_order.is_empty():
		return _NO_ACTIVE_WORK
	for a in main.work_order:
		if _is_in_build_range(a):
			return a
	return _NO_ACTIVE_WORK


## Like _get_active_work_anchor but also honors world/build pause flags,
## returning _NO_ACTIVE_WORK when progress should not advance this frame.
## Used by _process to decide whether to tick build/deconstruct progress.
func _get_tickable_work_anchor() -> Vector2i:
	if "world_paused" in main and main.world_paused:
		return _NO_ACTIVE_WORK
	if "build_paused" in main and main.build_paused:
		return _NO_ACTIVE_WORK
	return _get_active_work_anchor()


## Like _can_place_at but skips the drone build-range check and uses a
## specific rotation instead of main.placement_rotation. Used for the ghost
## queue — blocks placed outside range are validated the same way as regular
## placement (terrain, facing ore/wall, pump-on-liquid, core zone, etc.)
## except the range requirement is deferred until the drone walks over.
func _can_place_ignoring_range(grid_pos: Vector2i, block_id: StringName, rotation: int) -> bool:
	if not _can_place_terrain(grid_pos, block_id):
		return false
	var data = Registry.get_block(block_id)
	if data == null:
		return false
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	# Core zone
	if terrain and data.tags.has("core"):
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				var check_pos = grid_pos + Vector2i(x, y)
				var floor_data = terrain.get_floor_at(check_pos)
				if floor_data == null or not floor_data.tags.has("core_zone"):
					return false
	# Extractor must face ore / wall
	if data.category == BlockData.BlockCategory.EXTRACTORS:
		if data.tags.has("wall_miner"):
			if not _is_facing_wall(grid_pos, rotation, block_id):
				return false
		else:
			if not _is_facing_ore(grid_pos, rotation, block_id):
				return false
	# Pump must be on liquid
	elif data.tags.has("pump"):
		if not _is_on_liquid(grid_pos):
			return false
	# Archive scanner must face archive
	elif data.tags.has("archive_scanner"):
		if not _is_facing_archive(grid_pos, rotation, block_id):
			return false
	# Vent-powered
	if data.tags.has("vent_powered"):
		if terrain:
			var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
			if terrain.floor_tiles.get(center, &"") != &"vent":
				return false
	# Geyser miner must be centered on a geyser tile
	if data.tags.has("geyser_miner"):
		if terrain:
			var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
			if terrain.floor_tiles.get(center, &"") != &"geyser":
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

	# Core zone rule: core blocks MUST be on a core_zone tile.
	# Non-core blocks CAN be placed on core_zone tiles (no restriction).
	if terrain and data.tags.has("core"):
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				var check_pos = grid_pos + Vector2i(x, y)
				var floor_data = terrain.get_floor_at(check_pos)
				if floor_data == null or not floor_data.tags.has("core_zone"):
					return false

	# Extractor must face ore — or, for wall_miner extractors, a blackstone wall.
	if data.category == BlockData.BlockCategory.EXTRACTORS:
		if data.tags.has("wall_miner"):
			if not _is_facing_wall(grid_pos, main.placement_rotation, block_id):
				return false
		else:
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
	# Geyser miner must be centered on a geyser tile
	if data.tags.has("geyser_miner"):
		if terrain:
			var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
			if terrain.floor_tiles.get(center, &"") != &"geyser":
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


## Returns true if this building's front edge faces a blackstone wall tile
## (or has one directly behind that front cell). Mirrors the +1-ahead check
## the mechanical drill uses for ores. Only blackstone_wall tiles without
## an ore deposit count — ore walls are reserved for regular drills.
func _is_facing_wall(grid_pos: Vector2i, rotation: int, block_id: StringName = &"") -> bool:
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if terrain == null:
		return false
	var bid: StringName = block_id if block_id != &"" else main.selected_building
	var data = Registry.get_block(bid)
	if data == null:
		return false

	var dir: Vector2i
	match rotation:
		0: dir = Vector2i(1, 0)
		1: dir = Vector2i(0, 1)
		2: dir = Vector2i(-1, 0)
		3: dir = Vector2i(0, -1)
		_: dir = Vector2i(1, 0)

	# Wall miners accept a wall either directly on the front edge OR one tile
	# further ahead, matching how drills check for ore.
	var front_cells = _get_front_edge(grid_pos, data.grid_size, rotation)
	for cell in front_cells:
		if _is_mineable_wall(terrain, cell):
			return true
		if _is_mineable_wall(terrain, cell + dir):
			return true
	return false


## Wall-miner helper: true if the cell is a blackstone_wall with no ore on it.
func _is_mineable_wall(terrain: Node, cell: Vector2i) -> bool:
	if terrain.get_ore_at(cell) != null:
		return false
	var wall_id = terrain.wall_tiles.get(cell, &"")
	return StringName(wall_id) == &"blackstone_wall"


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
						if click_data and (click_data.tags.has("sorter") or click_data.tags.has("inverted_sorter") or click_data.tags.has("unloader")):
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
							if _pathfind_bridge_cells.has(cell):
								cell_block = _pathfind_bridge_cells[cell]
							if _is_in_build_range(cell):
								# In range: place immediately
								main.placement_rotation = cell_rot
								main.selected_building = cell_block
								main.try_place_building(cell)
							elif _can_place_ignoring_range(cell, cell_block, cell_rot) and not queued_positions.has(cell):
								# Out of range but valid placement: queue as ghost
								_paused_queue.append({
									"grid_pos": cell,
									"block_id": cell_block,
									"rotation": cell_rot,
								})
						main.placement_rotation = old_rot
						main.selected_building = old_building

					# Auto-link bridge pairs that were placed by the pathfinder
					if not _pathfind_bridge_pairs.is_empty():
						var power_sys_link = get_node_or_null("/root/Main/PowerSystem")
						if power_sys_link:
							for pair in _pathfind_bridge_pairs:
								var a: Vector2i = pair[0]
								var b: Vector2i = pair[1]
								# Only link if both bridges were actually placed
								if main.placed_buildings.has(a) and main.placed_buildings.has(b):
									var a_data = Registry.get_block(main.placed_buildings[a])
									var b_data = Registry.get_block(main.placed_buildings[b])
									if a_data and b_data and a_data.tags.has("bridge") and b_data.tags.has("bridge"):
										# Remove existing links first (1:1)
										var existing_a = power_sys_link.get_linked_partner(a)
										if existing_a != null:
											power_sys_link.unlink_blocks(a, existing_a)
										var existing_b = power_sys_link.get_linked_partner(b)
										if existing_b != null:
											power_sys_link.unlink_blocks(b, existing_b)
										power_sys_link.link_blocks(a, b)

					_drag_placing = false
					_drag_cells.clear()
					_pathfind_mode = false
					_pathfind_rotations.clear()
					_pathfind_bridge_cells.clear()
					_pathfind_bridge_pairs.clear()
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
						# First check if clicking on a queued ghost block — remove it.
						# For multi-tile ghosts, check all cells of each entry.
						var removed_ghost := false
						for qi in range(_paused_queue.size() - 1, -1, -1):
							var entry_pos: Vector2i = _paused_queue[qi]["grid_pos"]
							var entry_data = Registry.get_block(_paused_queue[qi]["block_id"])
							var gw: int = entry_data.grid_size.x if entry_data else 1
							var gh: int = entry_data.grid_size.y if entry_data else 1
							var hit := false
							for gx in range(gw):
								for gy in range(gh):
									if entry_pos + Vector2i(gx, gy) == _demolish_start:
										hit = true
										break
								if hit:
									break
							if hit:
								_paused_queue.remove_at(qi)
								removed_ghost = true
								break
						if not removed_ghost:
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
	# Resolve any still-pending threaded texture loads on the first paint.
	if not _textures_ready:
		_ensure_textures_loaded()
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
	if not parallax_enabled:
		return Vector2.ZERO
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


## Draws the unit being fabricated between a fabricator's base and top sprites.
## Handles three visual phases (from factory_buffers state):
##   - "processing": left-to-right construction reveal animation
##   - "ejecting": unit slides from center toward the front edge
##   - "holding":   unit sits at the front edge waiting to be output
func _draw_fabricator_unit_layer(grid_pos: Vector2i, data: BlockData, top_pos: Vector2, width: float, height: float, rot: int) -> void:
	if _logistics == null or not _logistics.factory_buffers.has(grid_pos):
		return
	var state: Dictionary = _logistics.factory_buffers[grid_pos]
	var phase: String = state.get("phase", "")
	if phase != "processing" and phase != "ejecting" and phase != "holding":
		return
	var unit_data = Registry.get_unit(data.produced_unit)
	if unit_data == null:
		return
	var center: Vector2 = top_pos + Vector2(width / 2.0, height / 2.0)
	var dir_vec: Vector2
	match rot:
		0: dir_vec = Vector2(1, 0)
		1: dir_vec = Vector2(0, 1)
		2: dir_vec = Vector2(-1, 0)
		3: dir_vec = Vector2(0, -1)
		_: dir_vec = Vector2(1, 0)

	# Target render size: relative to the fabricator's own footprint so the
	# held/ejecting unit never overflows the building. ~50% of the smaller
	# side looks right for a 3x3 fabricator displaying a tank body.
	var base_sz: float = minf(width, height) * 0.5

	var unit_angle: float = rot * PI / 2.0  # 0=right, 1=down, 2=left, 3=up

	# Position along the build/eject track
	var front_dist: float = maxf(width, height) * 0.5 - base_sz * 0.25
	var unit_pos: Vector2 = center
	var alpha_mul: float = 1.0
	var reveal_pct: float = 1.0

	match phase:
		"processing":
			var bt: float = unit_data.build_time if unit_data.build_time > 0 else 1.0
			var timer: float = float(state.get("timer", 0.0))
			reveal_pct = clampf(1.0 - timer / bt, 0.0, 1.0)
			alpha_mul = 0.4 + 0.6 * reveal_pct
			unit_pos = center
		"ejecting":
			var ep: float = clampf(float(state.get("eject_progress", 0.0)), 0.0, 1.0)
			unit_pos = center + dir_vec * (front_dist * ep)
		"holding":
			unit_pos = center + dir_vec * front_dist

	# Draw layered (base + head) if the unit has them; else fall back to icon.
	var drew_layered: bool = false
	if unit_data.base_sprite != null or unit_data.head_sprite != null:
		drew_layered = true
		if unit_data.base_sprite:
			var bt_size: Vector2 = _fit_texture_size(unit_data.base_sprite, base_sz)
			draw_set_transform(unit_pos, 0.0)
			draw_texture_rect(
				unit_data.base_sprite,
				Rect2(-bt_size * 0.5, bt_size),
				false,
				Color(1, 1, 1, alpha_mul)
			)
			draw_set_transform(Vector2.ZERO, 0.0)
		if unit_data.head_sprite:
			var h_size: Vector2 = _fit_texture_size(unit_data.head_sprite, base_sz)
			draw_set_transform(unit_pos, unit_angle + PI / 2.0)
			draw_texture_rect(
				unit_data.head_sprite,
				Rect2(-h_size * 0.5, h_size),
				false,
				Color(1, 1, 1, alpha_mul)
			)
			draw_set_transform(Vector2.ZERO, 0.0)
	elif unit_data.icon != null:
		var i_size: Vector2 = _fit_texture_size(unit_data.icon, base_sz)
		draw_set_transform(unit_pos, unit_angle + PI / 2.0)
		draw_texture_rect(
			unit_data.icon,
			Rect2(-i_size * 0.5, i_size),
			false,
			Color(1, 1, 1, alpha_mul)
		)
		draw_set_transform(Vector2.ZERO, 0.0)
	else:
		draw_rect(
			Rect2(unit_pos - Vector2(base_sz, base_sz) * 0.5, Vector2(base_sz, base_sz)),
			Color(0.6, 0.7, 0.9, 0.95 * alpha_mul),
			true
		)

	# Construction reveal overlay (dark rectangle + progress line) drawn
	# axis-aligned over the unit center during the processing phase.
	if phase == "processing":
		var rect_sz: float = base_sz
		var rect_pos: Vector2 = center - Vector2(rect_sz * 0.5, rect_sz * 0.5)
		var reveal_x: float = rect_sz * reveal_pct
		draw_rect(
			Rect2(rect_pos.x + reveal_x, rect_pos.y, rect_sz - reveal_x, rect_sz),
			Color(0, 0, 0, 0.6),
			true
		)
		if reveal_pct < 1.0:
			draw_line(
				Vector2(rect_pos.x + reveal_x, rect_pos.y),
				Vector2(rect_pos.x + reveal_x, rect_pos.y + rect_sz),
				Color(1.0, 0.9, 0.2, 0.9), 1.5
			)
	# Silence the unused-local warning from `drew_layered` while keeping the
	# variable name around for readers.
	if drew_layered:
		pass


## Returns a size vector that fits the texture into a box of side `target_px`,
## preserving aspect ratio. Used so that source textures authored at arbitrary
## resolutions all render at the same on-screen scale.
func _fit_texture_size(tex: Texture2D, target_px: float) -> Vector2:
	var native: Vector2 = tex.get_size()
	if native.x <= 0.0 or native.y <= 0.0:
		return Vector2(target_px, target_px)
	var max_dim: float = maxf(native.x, native.y)
	var s: float = target_px / max_dim
	return native * s


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
	# Omnidirectional blocks accept/output on every side, so they never need
	# a rotation. The tag wins over the EXTRACTORS-category default.
	if data.tags.has("omnidirectional"):
		return false
	return (data.is_transport() and not data.tags.has("junction")) \
		or data.category == BlockData.BlockCategory.EXTRACTORS \
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
## Same-type transports get a weight penalty so the pathfinder prefers routing
## around existing belts, but CAN cross them when no alternative exists.
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
			# Terrain walls block transport
			if terrain and terrain.has_wall(pos):
				_transport_astar.set_point_solid(pos, true)
				continue
			# Existing buildings
			if main.placed_buildings.has(pos):
				var existing_data = Registry.get_block(main.placed_buildings[pos])
				if existing_data:
					if existing_data.tags.has(transport_tag):
						# Same-type transport: passable but expensive so path
						# prefers going around. Weight = 20 discourages crossing
						# but allows it when no empty route exists.
						_transport_astar.set_point_weight_scale(pos, 20.0)
					else:
						# Non-transport building: impassable
						_transport_astar.set_point_solid(pos, true)


## Find the junction block for a transport type by scanning the registry.
var _junction_cache: Dictionary = {}  # transport_tag -> StringName
func _find_junction_for_type(transport_tag: String) -> StringName:
	if _junction_cache.has(transport_tag):
		return _junction_cache[transport_tag]
	for block_id in Registry.blocks:
		var data = Registry.get_block(block_id)
		if data and data.tags.has(transport_tag) and data.tags.has("junction"):
			_junction_cache[transport_tag] = block_id
			return block_id
	_junction_cache[transport_tag] = &""
	return &""


## Compute a pathfound transport route, detecting bridge/junction crossings.
## When the path crosses an existing belt:
##   - Perpendicular crossing → replace the existing belt with a junction
##   - Parallel or same-direction → insert bridge pair (before + after) and link them
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

	var raw: Array[Vector2i] = []
	for p in id_path:
		raw.append(Vector2i(int(p.x), int(p.y)))

	return _apply_transport_crossings(raw, transport_tag)


## Walks a transport path (in order) and rewrites it so that any cell that
## overlaps an existing same-type transport becomes a junction (perpendicular
## crossing) or a bridge pair (same-axis crossing). The substitutions land
## in `_pathfind_bridge_cells` / `_pathfind_bridge_pairs` so the commit loop
## can pick them up. Callers are expected to have cleared those dicts first.
func _apply_transport_crossings(raw: Array[Vector2i], transport_tag: String) -> Array[Vector2i]:
	var bridge_id := _find_bridge_for_type(transport_tag)
	var junction_id := _find_junction_for_type(transport_tag)

	var result: Array[Vector2i] = []
	var i := 0
	while i < raw.size():
		var gp: Vector2i = raw[i]

		# If this cell overlaps an existing block, figure out how to bridge it.
		if main.placed_buildings.has(gp):
			var existing_id: StringName = main.placed_buildings[gp]
			var existing_data = Registry.get_block(existing_id)
			var same_transport: bool = existing_data != null and existing_data.tags.has(transport_tag)

			if same_transport:
				var existing_rot: int = main.building_rotation.get(gp, 0)
				var path_rot: int = 0
				if i > 0:
					var delta: Vector2i = gp - raw[i - 1]
					var idx: int = DIR_VECTORS.find(delta)
					if idx >= 0:
						path_rot = idx
				elif i + 1 < raw.size():
					# First cell: derive direction from the next step instead.
					var delta_next: Vector2i = raw[i + 1] - gp
					var idx_n: int = DIR_VECTORS.find(delta_next)
					if idx_n >= 0:
						path_rot = idx_n

				# 0 = same direction (overlay no-op), 1/3 = perpendicular
				# (junction), 2 = opposite axis (overlay, which re-places the
				# belt with the new drag rotation — effectively flipping it).
				var angle_diff: int = absi(path_rot - existing_rot) % 4
				var is_perpendicular: bool = (angle_diff == 1 or angle_diff == 3)

				if is_perpendicular and junction_id != &"":
					# Perpendicular crossing: replace existing belt with a junction.
					_pathfind_bridge_cells[gp] = junction_id
					result.append(gp)
				else:
					# Same or opposite direction: let the new belt overlay the
					# existing one. For opposite direction the drag rotation
					# will flip it at place time.
					result.append(gp)
			elif bridge_id != &"":
				# Non-transport obstacle (or a different transport type) in the
				# drag path — bridge over it. The cell BEFORE becomes a bridge
				# start, the cell AFTER becomes a bridge end, and the crossing
				# cell(s) are skipped entirely.
				if result.size() > 0:
					_pathfind_bridge_cells[result[-1]] = bridge_id
				# Skip consecutive occupied cells until we find an empty one
				# (the bridge may need to span multiple obstacle tiles).
				var bridge_end := i + 1
				while bridge_end < raw.size() and main.placed_buildings.has(raw[bridge_end]):
					var ed = Registry.get_block(main.placed_buildings.get(raw[bridge_end], &""))
					# A same-tag transport is a valid landing cell, not an obstacle.
					if ed != null and ed.tags.has(transport_tag):
						break
					bridge_end += 1
				if bridge_end < raw.size():
					_pathfind_bridge_cells[raw[bridge_end]] = bridge_id
					if result.size() > 0:
						_pathfind_bridge_pairs.append([result[-1], raw[bridge_end]])
					i = bridge_end
					result.append(raw[i])
				else:
					# No landing cell available — fall back to just skipping
					# the obstacle cell; placement will fail there harmlessly.
					pass
			else:
				# Obstacle but no bridge block defined — skip (placement fails).
				pass
		else:
			result.append(gp)
		i += 1

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
	# --- Per-frame caches (hot state fetched once, not per-tile-per-pass) ---
	var camera := get_viewport().get_camera_2d()
	var cam_center: Vector2 = camera.get_screen_center_position() if camera else Vector2.ZERO
	var terrain := _terrain_ref()
	var ss := _sector_script_ref()
	var power_sys := _power_sys_ref()
	var fade_off: bool = "fade_enabled" in main and not main.fade_enabled
	var has_build_progress: bool = "building_build_progress" in main and not main.building_build_progress.is_empty()
	var has_decon: bool = "building_deconstruct_progress" in main and not main.building_deconstruct_progress.is_empty()
	# The "active" anchor is the one we're actually ticking this frame — which
	# may not be work_order[0] if the head is out of build range.
	var active_work_anchor: Vector2i = _get_active_work_anchor()
	var has_active_work: bool = active_work_anchor != _NO_ACTIVE_WORK

	# Rebuild wall cache if dirty
	if _walls_dirty:
		_rebuild_wall_cache()

	# Viewport culling: compute visible grid range with margin for parallax
	var viewport_size := get_viewport_rect().size
	var cam_zoom: Vector2 = camera.zoom if camera else Vector2.ONE
	var half_view := viewport_size / (2.0 * cam_zoom)
	var margin_px: float = max_depth + float(main.GRID_SIZE)
	var view_min := cam_center - half_view - Vector2(margin_px, margin_px)
	var view_max := cam_center + half_view + Vector2(margin_px, margin_px)
	var grid_min: Vector2i = main.world_to_grid(view_min) - Vector2i(1, 1)
	var grid_max: Vector2i = main.world_to_grid(view_max) + Vector2i(1, 1)

	# Build one culled list for buildings + walls, tracking wall-ness in parallel.
	var all_positions: Array[Vector2i] = []
	var is_wall_of: Array[bool] = []
	var wall_set: Dictionary = _cached_wall_set
	var any_non_lumina := false

	for grid_pos in main.placed_buildings:
		if grid_pos.x < grid_min.x or grid_pos.x > grid_max.x:
			continue
		if grid_pos.y < grid_min.y or grid_pos.y > grid_max.y:
			continue
		if not main.is_building_anchor(grid_pos):
			continue
		all_positions.append(grid_pos)
		is_wall_of.append(false)
		if not any_non_lumina and main.get_building_faction(grid_pos) != FACTION_LUMINA:
			any_non_lumina = true

	for grid_pos in wall_set:
		if grid_pos.x < grid_min.x or grid_pos.x > grid_max.x:
			continue
		if grid_pos.y < grid_min.y or grid_pos.y > grid_max.y:
			continue
		all_positions.append(grid_pos)
		is_wall_of.append(true)

	var gs := float(main.GRID_SIZE)
	var half_gs: float = gs * 0.5

	# Pre-compute sort distances so sort_custom becomes a pure float compare.
	var n: int = all_positions.size()
	var dists: PackedFloat32Array = PackedFloat32Array()
	dists.resize(n)
	for i in range(n):
		var gp: Vector2i = all_positions[i]
		var cx: float = float(gp.x) * gs + half_gs
		var cy: float = float(gp.y) * gs + half_gs
		var dx: float = cx - cam_center.x
		var dy: float = cy - cam_center.y
		dists[i] = dx * dx + dy * dy

	# Sort an index permutation (keeps the parallel is_wall_of array aligned).
	var order: Array = []
	order.resize(n)
	for i in range(n):
		order[i] = i
	order.sort_custom(func(a: int, b: int) -> bool:
		return dists[a] > dists[b])

	# Parallax offset — _get_top_offset ignores world_pos (leading underscore),
	# so it's a single pair of values per frame. Compute once.
	var parallax_off := _get_top_offset(Vector2.ZERO)
	var parallax_off_transport: Vector2 = parallax_off * 0.5

	# Per-call memo caches.
	var wall_tile_cache: Dictionary = {}
	var ore_tile_cache: Dictionary = {}
	var block_data_cache: Dictionary = {}
	var block_transport_cache: Dictionary = {}
	var block_size_cache: Dictionary = {}


	var _get_wall_tile := func(tid: StringName) -> TerrainTileData:
		if wall_tile_cache.has(tid):
			return wall_tile_cache[tid]
		var td: TerrainTileData = Registry.get_tile(tid)
		wall_tile_cache[tid] = td
		return td

	var _get_ore_tile := func(tid: StringName) -> TerrainTileData:
		if ore_tile_cache.has(tid):
			return ore_tile_cache[tid]
		var td: TerrainTileData = Registry.get_tile(tid)
		ore_tile_cache[tid] = td
		return td

	var _get_block := func(bid: StringName) -> BlockData:
		if block_data_cache.has(bid):
			return block_data_cache[bid]
		var bd: BlockData = Registry.get_block(bid)
		block_data_cache[bid] = bd
		return bd

	var _offset_for := func(bid: StringName) -> Vector2:
		if block_transport_cache.has(bid):
			return parallax_off_transport if block_transport_cache[bid] else parallax_off
		var bd = _get_block.call(bid)
		var is_t: bool = bd != null and bd.is_transport()
		block_transport_cache[bid] = is_t
		return parallax_off_transport if is_t else parallax_off

	var _size_for := func(bid: StringName) -> Vector2i:
		if block_size_cache.has(bid):
			return block_size_cache[bid]
		var bd = _get_block.call(bid)
		var sz: Vector2i = bd.grid_size if bd else Vector2i.ONE
		block_size_cache[bid] = sz
		return sz

	# --- PASS 1: Draw ALL sides ---
	for idx in order:
		var grid_pos: Vector2i = all_positions[idx]
		var is_wall: bool = is_wall_of[idx]
		var world_pos: Vector2 = main.grid_to_world(grid_pos)
		var offset: Vector2
		var side_color: Color
		var side_color_darker: Color
		var width: float
		var height: float

		if is_wall:
			if terrain == null:
				continue
			if ss and ss.is_tile_hidden(grid_pos):
				continue
			if not terrain.wall_tiles.has(grid_pos):
				continue
			var tile_data: TerrainTileData = _get_wall_tile.call(terrain.wall_tiles[grid_pos])
			if tile_data == null or tile_data.height <= 0:
				continue
			var fade_alpha := _get_wall_fade_alpha(grid_pos)
			offset = parallax_off
			side_color = tile_data.get_side_color()
			side_color_darker = tile_data.get_side_color_dark()
			var darkness: float = 1.0 - fade_alpha
			side_color = side_color.lerp(Color.BLACK, darkness)
			side_color_darker = side_color_darker.lerp(Color.BLACK, darkness)
			width = gs
			height = gs
		else:
			if ss and ss.is_tile_hidden(grid_pos):
				continue
			var block_id: StringName = main.placed_buildings[grid_pos]
			var block_size: Vector2i = _size_for.call(block_id)
			var side_colors := _get_side_colors(block_id)
			offset = _offset_for.call(block_id)
			side_color = side_colors[0]
			side_color_darker = side_colors[1]
			width = gs * block_size.x
			height = gs * block_size.y

		var b_tl: Vector2 = world_pos
		var b_tr: Vector2 = world_pos + Vector2(width, 0)
		var b_br: Vector2 = world_pos + Vector2(width, height)
		var b_bl: Vector2 = world_pos + Vector2(0, height)
		var t_tl: Vector2 = b_tl + offset
		var t_tr: Vector2 = b_tr + offset
		var t_br: Vector2 = b_br + offset
		var t_bl: Vector2 = b_bl + offset

		if abs(offset.x) > 0.5 or abs(offset.y) > 0.5:
			var draw_south := true
			var draw_north := true
			var draw_east := true
			var draw_west := true
			if is_wall:
				draw_south = not (wall_set.has(grid_pos + Vector2i(0, 1)) or main.placed_buildings.has(grid_pos + Vector2i(0, 1)))
				draw_north = not (wall_set.has(grid_pos + Vector2i(0, -1)) or main.placed_buildings.has(grid_pos + Vector2i(0, -1)))
				draw_east = not (wall_set.has(grid_pos + Vector2i(1, 0)) or main.placed_buildings.has(grid_pos + Vector2i(1, 0)))
				draw_west = not (wall_set.has(grid_pos + Vector2i(-1, 0)) or main.placed_buildings.has(grid_pos + Vector2i(-1, 0)))

			# Degenerate-polygon guard: each side's thickness comes from one axis
			# of the parallax offset. If that axis is near zero the polygon
			# collapses to a line and draw_polygon fails triangulation. Require
			# the relevant axis to have non-trivial magnitude.
			const SIDE_MIN := 0.5
			if offset.y < -SIDE_MIN and draw_south:
				draw_polygon([b_bl, b_br, t_br, t_bl], [side_color, side_color, side_color, side_color])
			if offset.y > SIDE_MIN and draw_north:
				draw_polygon([b_tl, b_tr, t_tr, t_tl], [side_color, side_color, side_color, side_color])
			if offset.x < -SIDE_MIN and draw_east:
				draw_polygon([b_tr, b_br, t_br, t_tr], [side_color_darker, side_color_darker, side_color_darker, side_color_darker])
			if offset.x > SIDE_MIN and draw_west:
				draw_polygon([b_tl, b_bl, t_bl, t_tl], [side_color_darker, side_color_darker, side_color_darker, side_color_darker])

	# --- PASS 2: Draw ALL top faces ---
	for idx in order:
		var grid_pos: Vector2i = all_positions[idx]
		var is_wall: bool = is_wall_of[idx]
		var world_pos: Vector2 = main.grid_to_world(grid_pos)

		# Wall tile top face
		if is_wall:
			if terrain == null:
				continue
			if ss and ss.is_tile_hidden(grid_pos):
				continue
			if not terrain.wall_tiles.has(grid_pos):
				continue
			var tile_data: TerrainTileData = _get_wall_tile.call(terrain.wall_tiles[grid_pos])
			if tile_data == null:
				continue
			var w_offset: Vector2 = parallax_off if tile_data.height > 0 else Vector2.ZERO
			var w_top_pos: Vector2 = world_pos + w_offset
			var top_rect := Rect2(w_top_pos, Vector2(gs, gs))
			if tile_data.icon:
				draw_texture_rect(tile_data.icon, top_rect, false)
			else:
				draw_rect(top_rect, tile_data.color, true)
			if tile_data.draw_border:
				draw_rect(top_rect, tile_data.border_color, false, 1.0)
			# Ore overlay
			if terrain.ore_tiles.has(grid_pos):
				var ore_data: TerrainTileData = _get_ore_tile.call(terrain.ore_tiles[grid_pos])
				if ore_data:
					if ore_data.icon:
						draw_texture_rect(ore_data.icon, top_rect, false, Color(1, 1, 1, ore_data.opacity))
					else:
						var ore_color: Color = ore_data.color
						ore_color.a = ore_data.opacity
						draw_rect(top_rect, ore_color, true)
			# Wall fade overlay is batched into _wall_fade_mesh and drawn once
			# after pass 2 (see below) — no per-tile work here.
			# Health bar
			if tile_data.destructible and terrain.tile_health.has(grid_pos):
				var pct: float = terrain.tile_health[grid_pos] / tile_data.max_health
				if pct < 1.0:
					var bar_w := 40.0
					var bar_h := 4.0
					var bar_pos: Vector2 = w_top_pos + Vector2((gs - bar_w) / 2.0, -8.0)
					draw_rect(Rect2(bar_pos, Vector2(bar_w, bar_h)), Color(0.2, 0, 0, 0.8), true)
					draw_rect(Rect2(bar_pos, Vector2(bar_w * pct, bar_h)), Color(1.0 - pct, pct, 0), true)
			continue

		# --- Building top face ---
		if ss and ss.is_tile_hidden(grid_pos):
			continue

		var block_id: StringName = main.placed_buildings[grid_pos]
		var block_size: Vector2i = _size_for.call(block_id)
		var offset: Vector2 = _offset_for.call(block_id)
		var width: float = gs * block_size.x
		var height: float = gs * block_size.y
		var top_pos: Vector2 = world_pos + offset
		var data: BlockData = _get_block.call(block_id)

		# Conveyor belts use auto-tiled textures based on neighbors
		if block_id == &"conveyor_belt" and not _belt_textures.is_empty():
			var info: Dictionary = _get_belt_draw_info(grid_pos)
			var texture: Texture2D = info["texture"]
			var angle: float = info["angle"]
			if texture:
				var center: Vector2 = top_pos + Vector2(width / 2.0, height / 2.0)
				draw_set_transform(center, angle)
				draw_texture_rect(texture, Rect2(Vector2(-width / 2.0, -height / 2.0), Vector2(width, height)), false)
				draw_set_transform(Vector2.ZERO, 0.0)
			else:
				var color := _get_block_color(block_id)
				draw_rect(Rect2(top_pos, Vector2(width, height)), color, true)
				draw_rect(Rect2(top_pos, Vector2(width, height)), color.lightened(0.3), false, 2.0)

		# Fluid pumps: draw with pump texture (before pipes; pumps also transport_fluid)
		elif data and data.tags.has("pump") and _pump_texture:
			var rot: int = main.building_rotation.get(grid_pos, 0)
			var angle: float = rot * PI / 2.0 + PI / 2.0
			var center: Vector2 = top_pos + Vector2(width / 2.0, height / 2.0)
			draw_set_transform(center, angle)
			draw_texture_rect(_pump_texture, Rect2(Vector2(-width / 2.0, -height / 2.0), Vector2(width, height)), false)
			draw_set_transform(Vector2.ZERO, 0.0)

		# Fluid pipes: colored fill rectangle UNDER the pipe texture
		elif data and data.transports_fluid and _pipe_texture:
			if _logistics and _logistics.pipe_contents.has(grid_pos):
				var pipe: Dictionary = _logistics.pipe_contents[grid_pos]
				var fluid = Registry.get_fluid(pipe["fluid_id"])
				if fluid:
					var fill_pct: float = clampf(pipe["amount"] / fluid.units_per_segment, 0.0, 1.0)
					var fill_color: Color = Color(fluid.color)
					fill_color.a = fill_pct * fluid.opacity
					draw_rect(Rect2(top_pos, Vector2(width, height)), fill_color, true)

			var rot: int = main.building_rotation.get(grid_pos, 0)
			var angle: float = rot * PI / 2.0 + PI / 2.0
			var center: Vector2 = top_pos + Vector2(width / 2.0, height / 2.0)
			draw_set_transform(center, angle)
			draw_texture_rect(_pipe_texture, Rect2(Vector2(-width / 2.0, -height / 2.0), Vector2(width, height)), false)
			draw_set_transform(Vector2.ZERO, 0.0)

		else:
			var top_rect := Rect2(top_pos, Vector2(width, height))
			var is_dir: bool = _is_directional(block_id)
			var rot: int = main.building_rotation.get(grid_pos, 0) if is_dir else 0
			# Unit fabricator layered rendering: base + unit-in-construction + top
			if data and data.produced_unit != &"" and data.base_sprite and data.top_sprite:
				_draw_block_texture(data.base_sprite, top_pos, width, height, rot)
				_draw_fabricator_unit_layer(grid_pos, data, top_pos, width, height, rot)
				_draw_block_texture(data.top_sprite, top_pos, width, height, rot)
			# Faction-layered rendering (cores): base sprite + faction overlay
			elif data and data.base_sprite:
				_draw_block_texture(data.base_sprite, top_pos, width, height, rot)
				var overlay_scale := 0.7
				var ow: float = width * overlay_scale
				var oh: float = height * overlay_scale
				var overlay_pos: Vector2 = top_pos + Vector2((width - ow) / 2.0, (height - oh) / 2.0)
				var faction: int = main.get_building_faction(grid_pos)
				if faction == FACTION_FEROX and data.ferox_overlay:
					_draw_block_texture(data.ferox_overlay, overlay_pos, ow, oh, rot)
				elif faction == FACTION_DERELICT and data.derelict_overlay:
					_draw_block_texture(data.derelict_overlay, overlay_pos, ow, oh, rot)
				elif data.lumina_overlay:
					_draw_block_texture(data.lumina_overlay, overlay_pos, ow, oh, rot)
			# Regular icon texture
			elif data and data.icon:
				var draw_rot: int = (rot + 1) % 4 if data.tags.has("shaft") else rot
				_draw_block_texture(data.icon, top_pos, width, height, draw_rot)
			# Fallback: colored rectangle
			else:
				var color := _get_block_color(block_id)
				draw_rect(top_rect, color, true)
				draw_rect(top_rect, color.lightened(0.3), false, 2.0)

		# Sorter filter indicator: small colored square in center
		if _logistics and data and (data.tags.has("sorter") or data.tags.has("inverted_sorter")):
			var filter_id: StringName = _logistics.sorter_filters.get(grid_pos, &"")
			if filter_id != &"":
				var filter_item = Registry.get_item(filter_id)
				if filter_item:
					var ind_size := 16.0
					var ind_pos: Vector2 = top_pos + Vector2((width - ind_size) / 2.0, (height - ind_size) / 2.0)
					draw_rect(Rect2(ind_pos, Vector2(ind_size, ind_size)), filter_item.color, true)
					draw_rect(Rect2(ind_pos, Vector2(ind_size, ind_size)), filter_item.color.lightened(0.3), false, 1.0)

	# --- PASS 2.05: Batched wall fade (one draw_mesh instead of one draw_polygon per wall) ---
	# The mesh was built at grid positions without parallax; apply it now so
	# the fade still follows the camera like the wall tops do.
	if _wall_fade_mesh and not fade_off:
		draw_mesh(_wall_fade_mesh, null, Transform2D(0.0, parallax_off))

	# --- PASS 2.1: Extractor heads overlay (drill + crusher) ---
	# Both drill heads and crusher heads extend forward into cells that often
	# contain ore walls. Drawing them in a dedicated pass after pass 2
	# guarantees they sit on top of any wall whose top face was drawn later
	# due to painter's order.
	for idx in order:
		if is_wall_of[idx]:
			continue
		var grid_pos: Vector2i = all_positions[idx]
		if ss and ss.is_tile_hidden(grid_pos):
			continue
		var block_id: StringName = main.placed_buildings[grid_pos]
		var data: BlockData = _get_block.call(block_id)
		if data == null:
			continue
		var is_dir: bool = _is_directional(block_id)
		var rot: int = main.building_rotation.get(grid_pos, 0) if is_dir else 0
		if data.tags.has("drill_heads"):
			var dh_variant: String = _get_drill_head_variant(grid_pos, rot, data.grid_size)
			_draw_drill_heads(grid_pos, rot, data.grid_size, dh_variant, block_id)
		if data.tags.has("crusher_heads"):
			# Placed crushers always render from live state; the per-frame
			# tick (_tick_crusher_head_states) is what decides whether the
			# heads are spinning up, holding speed, or coasting to a stop.
			_draw_crusher_heads(grid_pos, rot, data.grid_size, block_id, Color.WHITE, true)

	# --- PASS 2.25: Build animation overlay (left-to-right reveal) ---
	if has_build_progress:
		for idx in order:
			if is_wall_of[idx]:
				continue
			var grid_pos: Vector2i = all_positions[idx]
			if ss and ss.is_tile_hidden(grid_pos):
				continue
			if not main.building_build_progress.has(grid_pos):
				continue
			var build_pct: float = main.get_build_progress_pct(grid_pos)
			if build_pct >= 1.0:
				continue
			var b_block_id: StringName = main.placed_buildings[grid_pos]
			var b_block_size: Vector2i = _size_for.call(b_block_id)
			var b_world_pos: Vector2 = main.grid_to_world(grid_pos)
			var b_offset: Vector2 = _offset_for.call(b_block_id)
			var b_width: float = gs * b_block_size.x
			var b_height: float = gs * b_block_size.y
			var b_top_pos: Vector2 = b_world_pos + b_offset

			var is_active_build: bool = has_active_work and active_work_anchor == grid_pos
			if is_active_build:
				var reveal_x: float = b_width * build_pct
				var unbuilt_rect := Rect2(
					b_top_pos.x + reveal_x, b_top_pos.y,
					b_width - reveal_x, b_height
				)
				draw_rect(unbuilt_rect, Color(0, 0, 0, 0.65), true)
				var line_x: float = b_top_pos.x + reveal_x
				draw_line(
					Vector2(line_x, b_top_pos.y),
					Vector2(line_x, b_top_pos.y + b_height),
					Color(1.0, 0.9, 0.2, 0.9), 2.0
				)
			else:
				draw_rect(Rect2(b_top_pos, Vector2(b_width, b_height)), Color(0, 0, 0, 0.55), true)
				draw_rect(Rect2(b_top_pos, Vector2(b_width, b_height)), Color(0.5, 0.5, 0.5, 0.4), false, 1.0)

	# --- PASS 2.3: Deconstruct animation overlay (right-to-left, red line) ---
	if has_decon:
		for idx in order:
			if is_wall_of[idx]:
				continue
			var grid_pos: Vector2i = all_positions[idx]
			if not main.building_deconstruct_progress.has(grid_pos):
				continue
			var d_entry: Dictionary = main.building_deconstruct_progress[grid_pos]
			var d_block_id: StringName = d_entry["block_id"]
			var d_block_size: Vector2i = _size_for.call(d_block_id)
			var d_world_pos: Vector2 = main.grid_to_world(grid_pos)
			var d_offset: Vector2 = _offset_for.call(d_block_id)
			var d_width: float = gs * d_block_size.x
			var d_height: float = gs * d_block_size.y
			var d_top_pos: Vector2 = d_world_pos + d_offset

			var is_active_decon: bool = has_active_work and active_work_anchor == grid_pos
			if is_active_decon:
				var d_pct: float = clampf(d_entry["progress"] / d_entry["build_time"], 0.0, 1.0)
				var max_pct: float = float(d_entry.get("max_build_pct", 1.0))
				var line_pct: float = max_pct * (1.0 - d_pct)
				var line_x: float = d_top_pos.x + d_width * line_pct
				if line_pct < max_pct:
					var dark_left: float = line_x
					var dark_right: float = d_top_pos.x + d_width * max_pct
					draw_rect(Rect2(dark_left, d_top_pos.y, dark_right - dark_left, d_height), Color(0, 0, 0, 0.65), true)
				if max_pct < 1.0:
					var never_left: float = d_top_pos.x + d_width * max_pct
					draw_rect(Rect2(never_left, d_top_pos.y, d_width * (1.0 - max_pct), d_height), Color(0, 0, 0, 0.65), true)
				draw_line(
					Vector2(line_x, d_top_pos.y),
					Vector2(line_x, d_top_pos.y + d_height),
					Color(0.9, 0.2, 0.2, 0.9), 2.0
				)
			else:
				draw_rect(Rect2(d_top_pos, Vector2(d_width, d_height)), Color(0.3, 0, 0, 0.4), true)
				draw_rect(Rect2(d_top_pos, Vector2(d_width, d_height)), Color(0.9, 0.2, 0.2, 0.4), false, 1.0)

	# --- PASS 2.5: Faction tint on enemy buildings ---
	if any_non_lumina:
		for idx in order:
			if is_wall_of[idx]:
				continue
			var grid_pos: Vector2i = all_positions[idx]
			if ss and ss.is_tile_hidden(grid_pos):
				continue
			var bfaction: int = main.get_building_faction(grid_pos)
			if bfaction == FACTION_LUMINA:
				continue
			var f_block_id: StringName = main.placed_buildings[grid_pos]
			var block_size_f: Vector2i = _size_for.call(f_block_id)
			var world_pos_f: Vector2 = main.grid_to_world(grid_pos)
			var offset_f: Vector2 = _offset_for.call(f_block_id)
			var margin_f := -1.0
			var width_f: float = gs * block_size_f.x - margin_f * 2
			var height_f: float = gs * block_size_f.y - margin_f * 2
			var top_pos_f: Vector2 = world_pos_f + Vector2(margin_f, margin_f) + offset_f
			if bfaction == FACTION_DERELICT:
				draw_rect(Rect2(top_pos_f, Vector2(width_f, height_f)), Color(0.5, 0.5, 0.6, 0.2), true)
				draw_rect(Rect2(top_pos_f, Vector2(width_f, height_f)), Color(0.6, 0.6, 0.7, 0.4), false, 2.0)
			else:
				draw_rect(Rect2(top_pos_f, Vector2(width_f, height_f)), Color(1.0, 0.2, 0.2, 0.18), true)
				draw_rect(Rect2(top_pos_f, Vector2(width_f, height_f)), Color(1.0, 0.3, 0.3, 0.45), false, 2.0)

	# --- PASS 3: Draw direction arrows on directional buildings ---
	for idx in order:
		if is_wall_of[idx]:
			continue
		var grid_pos: Vector2i = all_positions[idx]
		if ss and ss.is_tile_hidden(grid_pos):
			continue
		var block_id: StringName = main.placed_buildings[grid_pos]
		if not _is_directional(block_id):
			continue

		var rotation: int = main.building_rotation.get(grid_pos, 0)
		var block_size: Vector2i = _size_for.call(block_id)
		var world_pos: Vector2 = main.grid_to_world(grid_pos)
		var offset: Vector2 = _offset_for.call(block_id)
		var center: Vector2 = world_pos + Vector2(
			gs * block_size.x / 2.0,
			gs * block_size.y / 2.0
		) + offset

		_draw_direction_arrow(center, rotation, Color(1, 1, 1, 0.6))

	# --- PASS 4: Draw health bars on damaged buildings ---
	for idx in order:
		if is_wall_of[idx]:
			continue
		var grid_pos: Vector2i = all_positions[idx]
		if ss and ss.is_tile_hidden(grid_pos):
			continue
		var health_pct: float = main.get_building_health_pct(grid_pos)
		if health_pct < 1.0:
			var block_id: StringName = main.placed_buildings[grid_pos]
			var block_size: Vector2i = _size_for.call(block_id)
			var world_pos: Vector2 = main.grid_to_world(grid_pos)
			var offset: Vector2 = _offset_for.call(block_id)
			var bar_center_x: float = world_pos.x + gs * block_size.x / 2.0
			_draw_building_health_bar(
				Vector2(bar_center_x, world_pos.y) + offset,
				health_pct,
				gs * block_size.x
			)

	# --- PASS 5: Draw "no power" indicator on unpowered buildings ---
	if power_sys:
		for idx in order:
			if is_wall_of[idx]:
				continue
			var grid_pos: Vector2i = all_positions[idx]
			if ss and ss.is_tile_hidden(grid_pos):
				continue
			var block_id: StringName = main.placed_buildings[grid_pos]
			var data: BlockData = _get_block.call(block_id)
			if data == null or data.electrical_power_use <= 0:
				continue
			if power_sys.is_electrical_powered(grid_pos):
				continue
			var block_size: Vector2i = _size_for.call(block_id)
			var world_pos: Vector2 = main.grid_to_world(grid_pos)
			var offset: Vector2 = _offset_for.call(block_id)
			var margin := -1.0
			var width: float = gs * block_size.x - margin * 2
			var height: float = gs * block_size.y - margin * 2
			var top_pos: Vector2 = world_pos + Vector2(margin, margin) + offset
			draw_rect(Rect2(top_pos, Vector2(width, height)),
				Color(1.0, 0.0, 0.0, 0.25), true)
			var center: Vector2 = top_pos + Vector2(width / 2.0, height / 2.0)
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

		# Drill heads overlay for queued drill ghosts.
		if data.tags.has("drill_heads"):
			var dh_variant: String = _get_drill_head_variant(grid_pos, rotation, data.grid_size)
			_draw_drill_heads(grid_pos, rotation, data.grid_size, dh_variant, block_id, Color(1, 1, 1, 0.45))
		if data.tags.has("crusher_heads"):
			_draw_crusher_heads(grid_pos, rotation, data.grid_size, block_id, Color(1, 1, 1, 0.45), false)

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
			var cell_ok := cell_valid  # No affordability gate — progressive consumption

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

			# Drill heads preview: falls back to "N" when placement is invalid.
			if data and data.tags.has("drill_heads"):
				var dh_rot: int = preview_rots.get(cell, main.placement_rotation)
				var dh_variant: String = "N"
				if cell_ok:
					dh_variant = _get_drill_head_variant(cell, dh_rot, data.grid_size)
				var dh_tint: Color = Color(1, 1, 1, 0.6) if cell_ok else Color(1, 0.3, 0.3, 0.5)
				_draw_drill_heads(cell, dh_rot, data.grid_size, dh_variant, main.selected_building, dh_tint)
			if data and data.tags.has("crusher_heads"):
				var ch_rot: int = preview_rots.get(cell, main.placement_rotation)
				var ch_tint: Color = Color(1, 1, 1, 0.6) if cell_ok else Color(1, 0.3, 0.3, 0.5)
				_draw_crusher_heads(cell, ch_rot, data.grid_size, main.selected_building, ch_tint, false)
		return

	# --- Not dragging: single-cell hover preview ---
	var world_pos = main.grid_to_world(preview_grid_pos)
	var offset = _get_top_offset(world_pos) * _get_height_scale(main.selected_building)
	var color = _get_block_color(main.selected_building)
	# With progressive resource consumption, placement is valid even without
	# enough resources — the ghost is placed and builds as resources arrive.
	var cell_ok: bool = can_place

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

	# Drill heads preview: falls back to "N" when placement is invalid.
	if data and data.tags.has("drill_heads"):
		var dh_variant: String = "N"
		if can_place:
			dh_variant = _get_drill_head_variant(preview_grid_pos, main.placement_rotation, data.grid_size)
		var dh_tint: Color = Color(1, 1, 1, 0.6) if can_place else Color(1, 0.3, 0.3, 0.5)
		_draw_drill_heads(preview_grid_pos, main.placement_rotation, data.grid_size, dh_variant, main.selected_building, dh_tint)
	if data and data.tags.has("crusher_heads"):
		var ch_tint: Color = Color(1, 1, 1, 0.6) if can_place else Color(1, 0.3, 0.3, 0.5)
		_draw_crusher_heads(preview_grid_pos, main.placement_rotation, data.grid_size, main.selected_building, ch_tint, false)

	# Cable-node range preview: dashed yellow line extending ±range tiles in each
	# cardinal direction, plus a yellow outline on the nearest connectable block
	# the cable would actually wire up to.
	if data and data.tags.has("cable_node"):
		var cable_range: int = 10 if String(data.id).begins_with("cable_tower") else 5
		_draw_cable_range_preview(preview_grid_pos, data.grid_size, cable_range)


## Draws the yellow dashed range indicator and connectable-block outlines for
## a cable node at grid_pos. Skips the cable node's own cells when scanning so
## the preview doesn't self-highlight.
func _draw_cable_range_preview(origin: Vector2i, grid_size: Vector2i, cable_range: int) -> void:
	if cable_range <= 0:
		return
	var gs := float(main.GRID_SIZE)
	var parallax_off := _get_top_offset(Vector2.ZERO)
	var dash_color := Color(1.0, 0.9, 0.2, 0.85)
	var outline_color := Color(1.0, 0.9, 0.2, 1.0)

	var half_w: float = grid_size.x * gs / 2.0
	var half_h: float = grid_size.y * gs / 2.0
	var center: Vector2 = Vector2(origin) * gs + Vector2(half_w, half_h) + parallax_off

	# Set of cells occupied by the cable block itself — skip these when scanning.
	var self_cells: Dictionary = {}
	for dx in range(grid_size.x):
		for dy in range(grid_size.y):
			self_cells[origin + Vector2i(dx, dy)] = true

	# How much of each tile the dash fills (rest is gap). 1 dash per tile.
	var dash_frac := 0.55

	for dir_idx in range(4):
		var dir_v: Vector2i = DIR_VECTORS[dir_idx]
		var dir_vf: Vector2 = Vector2(dir_v)
		var edge_dist: float = half_w if absi(dir_v.x) > 0 else half_h

		# Scan first to find the connectable block (if any). The line must stop
		# at the tile BEFORE that block — cables don't transmit past their first
		# connection in a given direction.
		# cable_range is the number of EMPTY tiles the cable can bridge, so the
		# reachable distance is cable_range + 1 tiles. Default dash count also
		# reflects that so an unblocked line fills the full reachable extent.
		var line_tiles: int = cable_range
		var hit_anchor: Vector2i = Vector2i(0, 0)
		var hit_found: bool = false
		for dist in range(1, cable_range + 2):
			var scan_tile: Vector2i = origin + dir_v * dist
			if self_cells.has(scan_tile):
				continue
			if not main.placed_buildings.has(scan_tile):
				continue
			var s_data = Registry.get_block(main.placed_buildings[scan_tile])
			if s_data == null or not s_data.is_electrical_power_block():
				continue
			hit_anchor = main.building_origins.get(scan_tile, scan_tile)
			hit_found = true
			line_tiles = dist - 1  # stop before the block's tile
			break

		# Draw one dash per tile, up to line_tiles tiles along this direction.
		for i in range(line_tiles):
			var tile_start_dist: float = edge_dist + i * gs
			var s: Vector2 = center + dir_vf * tile_start_dist
			var e: Vector2 = center + dir_vf * (tile_start_dist + gs * dash_frac)
			draw_line(s, e, dash_color, 2.0)

		# Yellow outline around the connectable block.
		if hit_found:
			var anchor_data = Registry.get_block(main.placed_buildings.get(hit_anchor, &""))
			if anchor_data:
				var anchor_world: Vector2 = Vector2(hit_anchor) * gs + parallax_off
				var anchor_size: Vector2 = Vector2(anchor_data.grid_size) * gs
				draw_rect(Rect2(anchor_world, anchor_size), outline_color, false, 2.0)


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
	var data = Registry.get_block(_block_id)
	# Only dirty the wall cache when the placement actually overlaps a wall
	# tile (which hides the wall underneath). Buildings on open floor don't
	# change wall visibility, so skip the BFS rebuild.
	var terrain_ref = _terrain_ref()
	if terrain_ref and data:
		var sx: int = data.grid_size.x
		var sy: int = data.grid_size.y
		for dx in range(sx):
			for dy in range(sy):
				if terrain_ref.wall_tiles.has(_grid_pos + Vector2i(dx, dy)):
					_walls_dirty = true
					break
			if _walls_dirty:
				break
	# Initialize crane state when a crane is placed
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
	# Same logic as placement: only dirty walls if the destroyed building was
	# sitting on one (its anchor cell overlaps a wall tile). Non-wall
	# destructions don't affect the wall render cache.
	var terrain_ref = _terrain_ref()
	if terrain_ref and terrain_ref.wall_tiles.has(_grid_pos):
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

	# Draw cable node connections using copper wire texture (tiled, pixel-perfect)
	# Lines go from/to the exact tile each connection touches, not the block center
	var cable_tint := Color(1.0, 1.0, 1.0, 1.0)
	var wire_scale := 1.0  # Scale down the wire width (1.0 = native texture size)
	var half_tile := Vector2(gs / 2.0, gs / 2.0)
	if power_sys and "cable_connections" in power_sys and _wire_texture:
		var tex_w: float = 15#_wire_texture.get_width()   # 15 — wire thickness
		var tex_h: float = _wire_texture.get_height()  # 100 — wire length per tile
		var draw_w: float = tex_w * wire_scale  # Scaled wire thickness
		for pair in power_sys.cable_connections:
			var ca: Vector2i = pair[0]
			var cb: Vector2i = pair[1]
			if not main.placed_buildings.has(ca) or not main.placed_buildings.has(cb):
				continue
			if _ss_link and (_ss_link.is_tile_hidden(ca) or _ss_link.is_tile_hidden(cb)):
				continue
			var wa: Vector2 = main.grid_to_world(ca) + half_tile + _get_top_offset(main.grid_to_world(ca))
			var wb: Vector2 = main.grid_to_world(cb) + half_tile + _get_top_offset(main.grid_to_world(cb))
			var dir: Vector2 = wb - wa
			var full_len: float = dir.length()
			if full_len < 0.01:
				continue
			# Pull both endpoints to the edge of their tiles
			var norm: Vector2 = dir / full_len
			wa += norm * (gs / 2.0)
			wb -= norm * (gs / 2.0)
			dir = wb - wa
			var length: float = dir.length()
			if length < 0.01:
				continue
			var forward: Vector2 = dir / length
			var angle: float = forward.angle() - PI / 2.0
			var hw: float = draw_w / 2.0
			var segments: int = ceili(length / tex_h)
			for i in range(segments):
				var t0: float = i * tex_h
				var this_len: float = minf(tex_h, length - t0)
				var center: Vector2 = wa + forward * (t0 + this_len / 2.0)
				draw_set_transform(center, angle)
				# Source rect: full width, cropped height for last segment
				var src := Rect2(0, 0, tex_w, this_len)
				# Dest rect: texture Y runs along the wire, texture X is thickness
				draw_texture_rect_region(_wire_texture, Rect2(-hw, -this_len / 2.0, draw_w, this_len), src, cable_tint)
				draw_set_transform(Vector2.ZERO, 0.0)

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

		# Check if placeable (local var; don't shadow the class-level `can_place`).
		var slot_ok: bool = true
		var terrain = get_node_or_null("/root/Main/TerrainSystem")
		for dx in range(data.grid_size.x):
			for dy in range(data.grid_size.y):
				var cp: Vector2i = grid_pos + Vector2i(dx, dy)
				if not main.is_within_bounds(cp) or not main.is_cell_empty(cp):
					slot_ok = false
				elif terrain and terrain.has_wall(cp):
					slot_ok = false

		var color: Color = _get_block_color(block_id)
		if slot_ok:
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
		var _arm_end: Vector2 = seg3_end

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
