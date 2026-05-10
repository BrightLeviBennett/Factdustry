extends Node2D


# Overlay child Node2D used to draw the in-world menu / storage popup.
# Sits at a very high z_index so popups always render above units and
# any other in-world content, no matter what's stacked beneath them.
class PopupOverlay extends Node2D:
	var owner_sys: Node = null
	func _process(_delta: float) -> void:
		# Self-paced redraw so the popup repaints every frame whenever a
		# menu / storage panel is open. Fixes the map editor case where
		# the parent BuildingSystem has `set_process(false)` and the
		# normal _draw → queue_redraw cascade isn't running.
		if owner_sys == null:
			return
		if owner_sys._world_menu_open or owner_sys._storage_panel_open:
			queue_redraw()
	func _draw() -> void:
		if owner_sys:
			owner_sys._draw_world_menu(self)
			owner_sys._draw_storage_panel(self)


var _popup_overlay: PopupOverlay = null
## Companion node that hosts cable-wire drawing on z 52 (above the
## LogisticsSystem layer at 51) so items running on conveyors don't
## render on top of the wires. Created in _ready alongside the popup
## overlay; calls back to `_draw_cable_links(self)` for the actual
## drawing so all the texture / state still lives on BuildingSystem.
var _cable_overlay: Node2D = null
var _crane_overlay: Node2D = null
# When non-null (set by _crane_overlay before invoking the crane
# draw routines), all crane / held-payload draw calls go to this
# canvas instead of `self`. Lets the overlay paint cranes on a much
# higher z_index without duplicating any of the draw code.
var _crane_draw_canvas: CanvasItem = null

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
var parallax_enabled := false
@export var parallax_strength := 0.025
@export var max_depth := 8.0
@export var soft_cap_factor := 0.05

# --- ARCHIVE STATE ---
## Per-archive: anchor → archive_id (StringName). Empty string = no archive selected.
var archive_holdings: Dictionary = {}

# Editor-only fallback stores for the in-world block/unit/filter menus.
# In-game, this state lives on LogisticsSystem; the map editor has no
# LogisticsSystem instance, so BuildingSystem owns the dicts directly
# so authored selections survive a save/load round-trip.
var editor_constructor_state: Dictionary = {}    # Vector2i → {selected_block: StringName}
var editor_refabricator_state: Dictionary = {}   # Vector2i → {selected_t2: StringName}
var editor_sorter_filters: Dictionary = {}       # Vector2i → StringName
## Per-archive-decoder: anchor → { progress: float, archive_id: StringName, scanner: Vector2i }
var archive_decoder_state: Dictionary = {}

# --- CRANE STATE ---
var crane_states: Dictionary = {}  # Vector2i anchor → {arm_angle, arm_extension, grabber_open, held_payload, target_pos}
# Crane dimensions — defaults tuned at the 64-px grid baseline. Scaled to
# `main.SPRITE_SCALE_FACTOR` in `_ready` so cranes stay proportional to
# tiles after grid changes. Stored as `var` (not `const`) so we can mutate
# them at startup; treat them as read-only after `_ready`.
var CRANE_ARM3_WIDTH := 14.0    # Innermost segment (extends first)
var CRANE_ARM2_WIDTH := 20.0    # Middle segment
var CRANE_ARM1_WIDTH := 26.0    # Outermost segment (base)
var CRANE_ARM3_MIN := 180.0     # Minimum length of segment 3
var CRANE_ARM2_MIN := 160.0     # Minimum length of segment 2
var CRANE_ARM1_MIN := 140.0     # Minimum length of segment 1
var CRANE_ARM3_MAX := 540.0     # Maximum length of segment 3 (extends first)
var CRANE_ARM2_MAX := 480.0     # Maximum length of segment 2 (extends second)
var CRANE_ARM1_MAX := 420.0     # Maximum length of segment 1 (extends last)
var CRANE_ARM_MIN_TOTAL := 480.0 # Sum of all minimums
var CRANE_GRABBER_SIZE := 28.0  # Half-length of each cross bar

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
var _duct_textures := {}
# Phase for the conveyor scroll effect (pixels). Advances every unpaused
# frame so the belt texture appears to move in its travel direction;
# rendering wraps via texture_repeat so a single tile of art tiles
# infinitely along the belt. Gated by `belt_scroll_enabled` — when off,
# belts render statically and we skip the per-frame queue_redraw too.
var _belt_scroll_phase: float = 0.0
var belt_scroll_enabled: bool = false
const _BELT_SCROLL_PIXELS_PER_SEC: float = 96.0
var _payload_conveyor_textures := {}

# --- PIPE / PUMP TEXTURES ---
var _pipe_texture: Texture2D
var _pump_texture: Texture2D
var _faction_overlay_ferox: Texture2D
var _faction_overlay_derelict: Texture2D

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

# --- SCRAPER HEAD TEXTURE ---
# Single drum-like sprite drawn UNDER the ground scraper's base, spinning
# whenever the scraper has power and storage room. Same inertia model as
# the crusher heads but with a single head per block (centered) instead
# of two front-edge gears.
var _scraper_head_texture: Texture2D
const SCRAPER_HEAD_SPIN := -4.5    # radians/sec target (negative = CCW)
const SCRAPER_HEAD_ACCEL := 5.0    # eases to/from target (rad/s²)
# Per-scraper state. Key = anchor. Value: {"angle": float, "vel": float}.
var _scraper_head_state: Dictionary = {}

# Vent turbine: layered render with two spinning inner blade discs under
# a static base plate. Same inertia model as the scraper head — `vel` eases
# toward `VENT_TURBINE_SPIN` while the building is active, drops back to
# zero when it isn't, then `angle` integrates from `vel`.
var _vent_turbine_base_texture: Texture2D
var _vent_turbine_inner_texture: Texture2D
const VENT_TURBINE_SPIN := 7.5    # radians/sec target
const VENT_TURBINE_ACCEL := 5.0   # rad/s²
var _vent_turbine_state: Dictionary = {}

# Vent condenser: same layered base + spinning inner pattern as the
# vent turbine, with its own textures. The condenser carries the `pump`
# tag so without this override the regular draw flow would route it
# through the generic `FluidPump.png` instead.
var _vent_condenser_base_texture: Texture2D
var _vent_condenser_inner_texture: Texture2D
const VENT_CONDENSER_SPIN := 7.5
const VENT_CONDENSER_ACCEL := 5.0
var _vent_condenser_state: Dictionary = {}

# Pre-baked composite of inner@0 + inner@45 + base, captured in a
# SubViewport at startup. Drawn as a single semi-transparent layer in
# the placement preview so the alpha-blended overlaps between the
# layered sprites don't stack into dark blobs (which is what happened
# when each layer was painted separately at preview alpha).
var _vent_turbine_preview_texture: Texture2D = null
var _vent_condenser_preview_texture: Texture2D = null

# Generic cache for per-block layered-preview composites. Keyed by
# `"<block_id>|<rotation>"`. Populated lazily on first request and reused
# every frame thereafter — same idea as the turbine / condenser bakes
# above, but generalized so cores (base + faction overlay) and turrets
# (chassis + heads + body sprites) can share the path.
var _preview_bake_cache: Dictionary = {}
var _preview_bake_pending: Dictionary = {}

# Archive-scan reveal-line phase. Advanced in _process when the world
# isn't paused so the scan line freezes in place during pause. Used as a
# triangle-wave input so the line ping-pongs across the archive instead
# of snapping from end → start.
var _archive_scan_phase: float = 0.0
const _ARCHIVE_SCAN_PERIOD: float = 2.0
# Per-archive-anchor fade alpha [0, 1]. Climbs toward 1 while a powered
# scanner is locked on it, drops toward 0 once that condition lapses
# (scanner destroyed, lost power, archive decoded). Drawn entries hang
# around until alpha hits 0, then evict.
var _archive_scan_fade: Dictionary = {}
const _ARCHIVE_SCAN_FADE_RATE: float = 4.0  # alpha units / second

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

# --- CRANE LINK STATE ---
# crane_links[crane_anchor] = {
#   "inputs":  Array of LinkSpec,
#   "outputs": Array of LinkSpec,
# }
# LinkSpec = {
#   "kind": "ground" | "block",
#   "pos":  Vector2i,            # ground tile (clicked center) or block anchor
#   "filter": Array[StringName], # empty = accept all, otherwise allowed unit/block ids
# }
var crane_links: Dictionary = {}

# Currently selected crane in link-mode (Vector2i(-1,-1) = none)
var _crane_link_anchor: Vector2i = Vector2i(-1, -1)
# Next placement alternates: "input" or "output"
var _crane_link_next_kind: String = "input"

# In-world filter menu (shift+click on a diamond)
var _crane_filter_menu_open := false
var _crane_filter_menu_anchor: Vector2i = Vector2i(-1, -1)  # crane this menu belongs to
var _crane_filter_menu_kind: String = "input"  # "input" or "output"
var _crane_filter_menu_index: int = -1  # which entry in inputs/outputs
var _crane_filter_menu_world_pos: Vector2 = Vector2.ZERO
var _crane_filter_menu_items: Array = []  # Array of {id: StringName, icon: Texture2D, name: String}
var _crane_filter_menu_columns: int = 6
var _crane_filter_menu_cell: float = 44.0
var _crane_filter_menu_hovered: int = -1

# --- WORLD MENU STATE (sorter filter / constructor selection) ---
var _world_menu_open := false
var _world_menu_pos := Vector2i.ZERO  # Grid position of the block that opened the menu
var _world_menu_type := ""  # "sorter", "constructor", or "archive"
var _world_menu_items: Array = []  # Array of {id: StringName, icon: Texture2D, name: String}
var _world_menu_columns := 8
## Cell size for in-world menus (storage / sorter / constructor pickers).
## Tuned at 64 px grid (= 44 px); scaled in `_ready` to current GRID_SIZE.
var _world_menu_cell_size := 44.0
var _world_menu_hovered := -1  # Index of hovered item, -1 = none

# --- Secondary "resource" panel ---
# Opens alongside a UI world menu (sorter / constructor / refabricator /
# archive) whenever the underlying block also has stored items. Lets the
# player both pick a recipe / filter AND inspect/withdraw the block's
# inventory in one click.
var _storage_panel_open := false
var _storage_panel_pos := Vector2i.ZERO
var _storage_panel_items: Array = []
var _storage_panel_hovered := -1

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
## Mindustry-style ad-hoc linking: clicking any `linkable` block selects it
## as `link_source` (yellow highlight). Clicking a second linkable block
## creates the link and makes THAT block the new source (blue flash on the
## previous one). RMB / Escape / clicking a non-linkable block clears it.
## `Vector2i(-1, -1)` = nothing selected.
var link_source := Vector2i(-1, -1)
## Set briefly after a link is created so the just-linked partner flashes
## blue alongside the new source's yellow. Cleared on the next selection
## change. Anchor of the previous source after a successful link.
var _link_just_linked := Vector2i(-1, -1)

# Anchor of the turret currently sitting under the cursor (or
# `Vector2i(-1, -1)` if none). Used to drive the hover range circle —
# `_process` queues a redraw whenever this flips so the circle appears
# / disappears as the cursor enters / leaves a turret tile.
var _last_hovered_turret_anchor := Vector2i(-1, -1)


func _ready() -> void:
	# Mindustry-style smooth filtering on every in-world draw. Was
	# `TEXTURE_FILTER_NEAREST` (strict pixel art) — flipped to
	# Linear-with-Mipmaps so floor tiles, building bases, faction
	# overlays, etc. sample from the mip pyramid at any zoom.
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# Conveyor belts animate by drawing a moving source rect into a static
	# destination rect (see `_belt_scroll_phase`); for that to wrap
	# seamlessly when the source rect runs past the texture's bounds,
	# this CanvasItem needs to sample with repeat enabled.
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	# Scale world-menu cell size to current GRID_SIZE so storage / sorter /
	# picker panels stay proportional to a tile.
	_world_menu_cell_size *= main.SPRITE_SCALE_FACTOR
	_crane_filter_menu_cell *= main.SPRITE_SCALE_FACTOR
	# Scale crane dimensions (originally tuned at the 64-px grid baseline).
	var sf: float = main.SPRITE_SCALE_FACTOR
	CRANE_ARM3_WIDTH *= sf
	CRANE_ARM2_WIDTH *= sf
	CRANE_ARM1_WIDTH *= sf
	CRANE_ARM3_MIN *= sf
	CRANE_ARM2_MIN *= sf
	CRANE_ARM1_MIN *= sf
	CRANE_ARM3_MAX *= sf
	CRANE_ARM2_MAX *= sf
	CRANE_ARM1_MAX *= sf
	CRANE_ARM_MIN_TOTAL *= sf
	CRANE_GRABBER_SIZE *= sf
	# Popup overlay: drawn on a separate Node2D so we can pin a very high
	# z_index without affecting BuildingSystem's main draw stack. With
	# z_as_relative = false, this beats every in-world Node2D regardless
	# of where it sits in the tree.
	_popup_overlay = PopupOverlay.new()
	_popup_overlay.owner_sys = self
	_popup_overlay.z_index = 4096
	_popup_overlay.z_as_relative = false
	_popup_overlay.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	add_child(_popup_overlay)
	# Cable wires render on their own layer (z 52, absolute) so the
	# LogisticsSystem at z 51 can't draw items over them. Same pattern
	# as the popup overlay above — separate Node2D, callback into
	# `_draw_cable_links(self)` for the actual draws.
	_cable_overlay = Node2D.new()
	_cable_overlay.name = "CableOverlay"
	_cable_overlay.z_index = 52
	_cable_overlay.z_as_relative = false
	_cable_overlay.set_script(preload("res://main/cable_overlay.gd"))
	_cable_overlay.set("building_sys", self)
	add_child(_cable_overlay)
	# Crane overlay: arms + grabbers + held cargo render here, on top
	# of every in-world layer (units, turret heads, projectiles) so a
	# crane carrying something never visually disappears underneath
	# whatever's at its grabber.
	_crane_overlay = Node2D.new()
	_crane_overlay.name = "CraneOverlay"
	# Godot caps z_index at 4096; 4097 was silently rejected and the
	# overlay fell back to z=0, dropping the cranes UNDER blocks (z=50)
	# and terrain walls (z≈52). 4096 is the documented max — same z as
	# popup_overlay, but our overlay is added AFTER popup so siblings
	# break the tie in our favour.
	_crane_overlay.z_index = 4096
	_crane_overlay.z_as_relative = false
	_crane_overlay.set_script(preload("res://main/crane_overlay.gd"))
	_crane_overlay.set("building_sys", self)
	add_child(_crane_overlay)
	# Lift the building layer above ground/crawler/hover units so
	# placed buildings AND placement previews paint over them. Without
	# this a 2×2 ghost can completely vanish behind a stray crawler in
	# its footprint, defeating the point of the preview. Popups stay
	# on top via their own much-higher z_index (4096).
	z_index = 50
	z_as_relative = false
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
	# Pre-bake the layered-spinner preview textures (vent turbine /
	# condenser). Done once at startup, off the main draw path, so the
	# placement ghost can paint a single composite layer instead of
	# stacking two semi-transparent inner copies (which alpha-doubles
	# at every spoke crossing).
	_bake_spinner_preview_textures()


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
const _DUCT_TEX_PATHS := {
	"straight": "res://textures/blocks/item transportation/Duct/Duct.png",
	"jr":       "res://textures/blocks/item transportation/Duct/Duct-JR.png",
	"jl":       "res://textures/blocks/item transportation/Duct/Duct-JL.png",
	"ja":       "res://textures/blocks/item transportation/Duct/Duct-JA.png",
	"ca":       "res://textures/blocks/item transportation/Duct/Duct-CA.png",
	"cb":       "res://textures/blocks/item transportation/Duct/Duct-CB.png",
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
const _SCRAPER_HEAD_TEX_PATH := "res://textures/blocks/resource extractors/Ground Scraper/GroundScraperHead.png"
const _VENT_TURBINE_BASE_TEX_PATH := "res://textures/blocks/power/VentTurbineBase.png"
const _VENT_TURBINE_INNER_TEX_PATH := "res://textures/blocks/power/VentTurbineInner.png"
const _VENT_CONDENSER_BASE_TEX_PATH := "res://textures/blocks/resource extractors/Vent Condenser/VentCondenserBase.png"
const _VENT_CONDENSER_INNER_TEX_PATH := "res://textures/blocks/resource extractors/Vent Condenser/VentCondenserInner.png"
# Generic faction-overlay sprites stamped on top of the building's base
# instead of tinting the whole footprint a flat colour. Centered on the
# bottom-left tile of multi-tile buildings (and on the only tile of 1×1
# buildings) so the silhouette is unmistakable without obscuring the
# rest of the building art.
const _FACTION_OVERLAY_FEROX_PATH := "res://textures/blocks/cores/FactionOverlayFerox.png"
const _FACTION_OVERLAY_DERELICT_PATH := "res://textures/blocks/cores/FactionOverlayDerelict.png"
# Payload conveyor swaps to a merge texture when an upstream payload source
# feeds it from the left/right side. Default ("PayloadConveyor.png") is used
# when the back is fed (or nothing is fed).
const _PAYLOAD_CONV_TEX_PATHS := {
	"straight": "res://textures/blocks/units/PayloadConveyor/PayloadConveyor.png",
	"left":     "res://textures/blocks/units/PayloadConveyor/PayloadConveyorLeft.png",
	"right":    "res://textures/blocks/units/PayloadConveyor/PayloadConveyorRight.png",
}

var _textures_ready: bool = false


## Issues threaded-load requests for every texture we need. Non-blocking.
func _queue_texture_loads() -> void:
	for key in _BELT_TEX_PATHS:
		ResourceLoader.load_threaded_request(_BELT_TEX_PATHS[key])
	for key in _DUCT_TEX_PATHS:
		ResourceLoader.load_threaded_request(_DUCT_TEX_PATHS[key])
	for key in _DRILL_HEAD_TEX_PATHS:
		ResourceLoader.load_threaded_request(_DRILL_HEAD_TEX_PATHS[key])
	ResourceLoader.load_threaded_request(_PIPE_TEX_PATH)
	ResourceLoader.load_threaded_request(_PUMP_TEX_PATH)
	ResourceLoader.load_threaded_request(_WIRE_TEX_PATH)
	ResourceLoader.load_threaded_request(_CRUSHER_HEAD_TEX_PATH)
	ResourceLoader.load_threaded_request(_SCRAPER_HEAD_TEX_PATH)
	ResourceLoader.load_threaded_request(_VENT_TURBINE_BASE_TEX_PATH)
	ResourceLoader.load_threaded_request(_VENT_TURBINE_INNER_TEX_PATH)
	ResourceLoader.load_threaded_request(_VENT_CONDENSER_BASE_TEX_PATH)
	ResourceLoader.load_threaded_request(_VENT_CONDENSER_INNER_TEX_PATH)
	ResourceLoader.load_threaded_request(_FACTION_OVERLAY_FEROX_PATH)
	ResourceLoader.load_threaded_request(_FACTION_OVERLAY_DERELICT_PATH)
	for key in _PAYLOAD_CONV_TEX_PATHS:
		ResourceLoader.load_threaded_request(_PAYLOAD_CONV_TEX_PATHS[key])


## Blocks until all queued textures are resolved, then stashes them.
## Called once before the first real draw — at that point the threaded
## loads are typically already done so this is effectively free.
func _ensure_textures_loaded() -> void:
	if _textures_ready:
		return
	for key in _BELT_TEX_PATHS:
		_belt_textures[key] = ResourceLoader.load_threaded_get(_BELT_TEX_PATHS[key])
	for key in _DUCT_TEX_PATHS:
		_duct_textures[key] = ResourceLoader.load_threaded_get(_DUCT_TEX_PATHS[key])
	for key in _DRILL_HEAD_TEX_PATHS:
		_drill_head_textures[key] = ResourceLoader.load_threaded_get(_DRILL_HEAD_TEX_PATHS[key])
	_pipe_texture = ResourceLoader.load_threaded_get(_PIPE_TEX_PATH)
	_pump_texture = ResourceLoader.load_threaded_get(_PUMP_TEX_PATH)
	_wire_texture = ResourceLoader.load_threaded_get(_WIRE_TEX_PATH)
	_crusher_head_texture = ResourceLoader.load_threaded_get(_CRUSHER_HEAD_TEX_PATH)
	_scraper_head_texture = ResourceLoader.load_threaded_get(_SCRAPER_HEAD_TEX_PATH)
	_vent_turbine_base_texture = ResourceLoader.load_threaded_get(_VENT_TURBINE_BASE_TEX_PATH)
	_vent_turbine_inner_texture = ResourceLoader.load_threaded_get(_VENT_TURBINE_INNER_TEX_PATH)
	_vent_condenser_base_texture = ResourceLoader.load_threaded_get(_VENT_CONDENSER_BASE_TEX_PATH)
	_vent_condenser_inner_texture = ResourceLoader.load_threaded_get(_VENT_CONDENSER_INNER_TEX_PATH)
	_faction_overlay_ferox = ResourceLoader.load_threaded_get(_FACTION_OVERLAY_FEROX_PATH)
	_faction_overlay_derelict = ResourceLoader.load_threaded_get(_FACTION_OVERLAY_DERELICT_PATH)
	for key in _PAYLOAD_CONV_TEX_PATHS:
		_payload_conveyor_textures[key] = ResourceLoader.load_threaded_get(_PAYLOAD_CONV_TEX_PATHS[key])
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
	var tex_size: Vector2 = _crusher_head_texture.get_size() * CRUSHER_HEAD_SCALE * main.SPRITE_SCALE_FACTOR
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
	# No electrical power at all → no spin. Efficiency > 0 keeps the spin
	# running (just visually implied to be slower isn't worth the extra math).
	if data.electrical_power_use > 0:
		var ps = _power_sys_ref()
		if ps == null or ps.get_electrical_efficiency(anchor) <= 0.0:
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


## Same shape as `_is_crusher_spinning` but generalized for any extractor:
## active iff finished construction, not sector-disabled, has any power
## (when it draws power), and its output buffer isn't full. Used by the
## ground scraper's spinning drum.
func _is_scraper_spinning(anchor: Vector2i, data: BlockData) -> bool:
	if data == null:
		return false
	if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
		return false
	var ss = _sector_script_ref()
	if ss and ss.has_method("is_building_disabled") and ss.is_building_disabled(anchor):
		return false
	if data.electrical_power_use > 0:
		var ps = _power_sys_ref()
		if ps == null or ps.get_electrical_efficiency(anchor) <= 0.0:
			return false
	if _logistics and _logistics.has_method("_is_storage_full"):
		if _logistics._is_storage_full(anchor, data):
			return false
	return true


## Per-frame tick for scraper heads. Mirrors `_tick_crusher_head_states`
## but with a single angle/velocity per block instead of two.
func _tick_scraper_head_states(delta: float) -> void:
	if _scraper_head_state.is_empty():
		return
	var to_erase: Array[Vector2i] = []
	for anchor in _scraper_head_state:
		if not main.placed_buildings.has(anchor):
			to_erase.append(anchor)
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings[anchor])
		if data == null or not data.tags.has("scraper_head"):
			to_erase.append(anchor)
			continue
		var active := _is_scraper_spinning(anchor, data)
		var target: float = SCRAPER_HEAD_SPIN if active else 0.0
		var s: Dictionary = _scraper_head_state[anchor]
		var step: float = SCRAPER_HEAD_ACCEL * delta
		s["vel"] = move_toward(float(s["vel"]), target, step)
		s["angle"] = fposmod(float(s["angle"]) + float(s["vel"]) * delta, TAU)
	for a in to_erase:
		_scraper_head_state.erase(a)


## Draws the scraper's spinning head texture centered on the block's
## footprint at the same `top_pos` the base will draw at. Called BEFORE
## the base sprite so the base ends up painted over the center of the
## head and only the rim peeks out — matching the wall crusher's
## "gear-under-shell" composition. Lazily initializes spin state so the
## first draw works even if no tick has run yet.
func _draw_scraper_head(grid_pos: Vector2i, top_pos: Vector2, width: float, height: float, tint: Color = Color.WHITE) -> void:
	if _scraper_head_texture == null:
		return
	if not _scraper_head_state.has(grid_pos):
		_scraper_head_state[grid_pos] = {"angle": 0.0, "vel": 0.0}
	var s: Dictionary = _scraper_head_state[grid_pos]
	var center: Vector2 = top_pos + Vector2(width * 0.5, height * 0.5)
	var size := Vector2(width, height)
	draw_set_transform(center, float(s["angle"]))
	draw_texture_rect(_scraper_head_texture, Rect2(-size * 0.5, size), false, tint)
	draw_set_transform(Vector2.ZERO, 0.0)


## Per-frame tick for vent turbines. Mirrors `_tick_scraper_head_states` —
## each anchor's angular velocity eases toward `VENT_TURBINE_SPIN` while
## the building is active and back to zero when inactive, with the angle
## integrated from the velocity each frame.
func _tick_vent_turbine_states(delta: float) -> void:
	if _vent_turbine_state.is_empty():
		return
	var to_erase: Array[Vector2i] = []
	for anchor in _vent_turbine_state:
		if not main.placed_buildings.has(anchor):
			to_erase.append(anchor)
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings[anchor])
		if data == null or data.id != &"vent_turbine":
			to_erase.append(anchor)
			continue
		var active: bool = not (main.has_method("is_building_inactive") \
			and main.is_building_inactive(anchor))
		var target: float = VENT_TURBINE_SPIN if active else 0.0
		var s: Dictionary = _vent_turbine_state[anchor]
		var step: float = VENT_TURBINE_ACCEL * delta
		s["vel"] = move_toward(float(s["vel"]), target, step)
		s["angle"] = fposmod(float(s["angle"]) + float(s["vel"]) * delta, TAU)
	for a in to_erase:
		_vent_turbine_state.erase(a)


## Draws a dashed circle at `radius` around `center`. Used by the
## turret-range visualisers (placement preview + hover-over-existing).
## Each dash is a `draw_polyline` rather than a `draw_arc` so the line
## caps and segment joins are flat — `draw_arc` was leaving slight
## connector slivers between adjacent calls that read as a faint gray
## ring under the white dashes.
func _draw_dashed_circle(center: Vector2, radius: float, color: Color, width: float, dashes: int = 48) -> void:
	if radius <= 0.0 or dashes <= 0:
		return
	var slot: float = TAU / float(dashes)
	# Each dash spans 60% of its slot; the remaining 40% is the gap.
	var dash_arc: float = slot * 0.6
	var samples: int = 5  # vertices per dash; 4 segments
	for i in range(dashes):
		var a0: float = slot * float(i)
		var pts: PackedVector2Array = PackedVector2Array()
		pts.resize(samples)
		for j in range(samples):
			var t: float = float(j) / float(samples - 1)
			var a: float = a0 + dash_arc * t
			pts[j] = center + Vector2(cos(a), sin(a)) * radius
		draw_polyline(pts, color, width, false)


## Hover-over-turret range indicator: when the cursor is sitting on a
## placed turret, paint its `attack_range` as a dashed white circle so
## the player can see how far it'll shoot. Skipped while placement /
## drag preview is showing the same circle for the selected block.
func _draw_hovered_turret_range() -> void:
	# Don't compete with the placement preview's range circle.
	if main.selected_building != &"":
		return
	# UI-blocking states freeze world hover (matches the existing
	# input-gating in `_unhandled_input`).
	if main.has_method("is_ui_blocking") and main.is_ui_blocking():
		return
	var mouse_world: Vector2 = get_global_mouse_position()
	var grid_pos: Vector2i = main.world_to_grid(mouse_world)
	if not main.placed_buildings.has(grid_pos):
		return
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if data == null or not data.is_turret() or data.attack_range <= 0.0:
		return
	var gs: float = float(main.GRID_SIZE)
	var center: Vector2 = main.grid_to_world(anchor) + Vector2(
		data.grid_size.x * gs * 0.5,
		data.grid_size.y * gs * 0.5,
	)
	var range_px: float = data.attack_range * gs
	_draw_dashed_circle(center, range_px, Color(1, 1, 1, 0.85), 3.0)


## Crane placement preview: draws the arm + cross grabber + base pivot
## at the default pose (arm pointing up, fully retracted) on top of
## whatever block sprite the standard preview path already painted.
## Uses the same constants the live `_draw_cranes` uses so the silhouette
## matches the placed crane.
func _draw_crane_preview(top_pos: Vector2, width: float, height: float, tint: Color = Color(1, 1, 1, 0.6)) -> void:
	# Default pose used in `_on_building_placed` for crane initialisation.
	var angle: float = -PI / 2.0
	var ext: float = CRANE_ARM_MIN_TOTAL
	var arm_dir: Vector2 = Vector2(cos(angle), sin(angle))

	var base: Vector2 = top_pos + Vector2(width * 0.5, height * 0.5)

	# Distribute the minimum extension across the three telescoping
	# segments, mirroring `_draw_cranes` so the preview's silhouette
	# matches the placed crane.
	var remaining: float = maxf(ext - CRANE_ARM_MIN_TOTAL, 0.0)
	var arm3_extra: float = minf(remaining, CRANE_ARM3_MAX - CRANE_ARM3_MIN)
	remaining -= arm3_extra
	var arm2_extra: float = minf(remaining, CRANE_ARM2_MAX - CRANE_ARM2_MIN)
	remaining -= arm2_extra
	var arm1_extra: float = minf(remaining, CRANE_ARM1_MAX - CRANE_ARM1_MIN)
	var seg1_len: float = CRANE_ARM1_MIN + arm1_extra
	var seg2_len: float = CRANE_ARM2_MIN + arm2_extra
	var seg3_len: float = CRANE_ARM3_MIN + arm3_extra

	var seg1_end: Vector2 = base + arm_dir * seg1_len
	var seg2_end: Vector2 = seg1_end + arm_dir * seg2_len
	var seg3_end: Vector2 = seg2_end + arm_dir * seg3_len

	var grabber_pos: Vector2 = seg3_end
	var grabber_size: float = CRANE_GRABBER_SIZE
	var grabber_thickness: float = 6.0 * main.SPRITE_SCALE_FACTOR
	var grabber_color := Color(0.6, 0.5, 0.2, 0.9)
	grabber_color.a *= tint.a

	# Cross grabber UNDER the arm (default grabber_angle = 0).
	draw_set_transform(grabber_pos, 0.0)
	draw_rect(Rect2(-grabber_size, -grabber_thickness * 0.5,
		grabber_size * 2.0, grabber_thickness), grabber_color, true)
	draw_rect(Rect2(-grabber_thickness * 0.5, -grabber_size,
		grabber_thickness, grabber_size * 2.0), grabber_color, true)
	draw_set_transform(Vector2.ZERO, 0.0)

	# Arm segments — outermost first (widest), then middle, then innermost.
	var seg1_fill := Color(0.5, 0.5, 0.5, 0.85)
	var seg2_fill := Color(0.42, 0.42, 0.42, 0.9)
	var seg3_fill := Color(0.35, 0.35, 0.35, 0.95)
	seg1_fill.a *= tint.a
	seg2_fill.a *= tint.a
	seg3_fill.a *= tint.a

	var c1: Vector2 = (base + seg1_end) * 0.5
	draw_set_transform(c1, angle)
	draw_rect(Rect2(-seg1_len * 0.5, -CRANE_ARM1_WIDTH * 0.5,
		seg1_len, CRANE_ARM1_WIDTH), seg1_fill, true)
	draw_set_transform(Vector2.ZERO, 0.0)

	var c2: Vector2 = (seg1_end + seg2_end) * 0.5
	draw_set_transform(c2, angle)
	draw_rect(Rect2(-seg2_len * 0.5, -CRANE_ARM2_WIDTH * 0.5,
		seg2_len, CRANE_ARM2_WIDTH), seg2_fill, true)
	draw_set_transform(Vector2.ZERO, 0.0)

	var c3: Vector2 = (seg2_end + seg3_end) * 0.5
	draw_set_transform(c3, angle)
	draw_rect(Rect2(-seg3_len * 0.5, -CRANE_ARM3_WIDTH * 0.5,
		seg3_len, CRANE_ARM3_WIDTH), seg3_fill, true)
	draw_set_transform(Vector2.ZERO, 0.0)

	# Base pivot circle.
	var pivot_color := Color(0.6, 0.6, 0.6, 0.7)
	pivot_color.a *= tint.a
	draw_circle(base, 5.0, pivot_color)


## Static (frozen) vent-turbine layered preview, used by the placement
## ghost. Paints a single pre-baked composite (inner@0 + inner@45 +
## base) so the preview is one semi-transparent layer — no alpha
## stacking between layers. Falls back to drawing the layers separately
## while the bake is still pending.
func _draw_vent_turbine_preview(top_pos: Vector2, width: float, height: float, tint: Color = Color.WHITE) -> void:
	var size := Vector2(width, height)
	if _vent_turbine_preview_texture:
		draw_texture_rect(_vent_turbine_preview_texture, Rect2(top_pos, size), false, tint)
		return
	if _vent_turbine_base_texture == null:
		return
	if _vent_turbine_inner_texture:
		draw_texture_rect(_vent_turbine_inner_texture, Rect2(top_pos, size), false, tint)
	draw_texture_rect(_vent_turbine_base_texture, Rect2(top_pos, size), false, tint)


## Asynchronously composes the layered-spinner preview textures by
## rendering inner@0° + inner@45° + base into a SubViewport for each
## block, then capturing the result as a single ImageTexture. The
## placement preview then paints that composite as one semi-transparent
## layer — no alpha-doubling at the spoke crossings, no stacking dark
## blobs at the base/inner overlap.
func _bake_spinner_preview_textures() -> void:
	# Wait until the threaded texture loads have resolved.
	while not _textures_ready:
		await get_tree().process_frame
	if _vent_turbine_inner_texture and _vent_turbine_base_texture:
		_vent_turbine_preview_texture = await _bake_spinner_preview_composite(
			_vent_turbine_inner_texture, _vent_turbine_base_texture)
	if _vent_condenser_inner_texture and _vent_condenser_base_texture:
		_vent_condenser_preview_texture = await _bake_spinner_preview_composite(
			_vent_condenser_inner_texture, _vent_condenser_base_texture)


## Generic layered-preview bake. Returns a cached composite for
## (`block_id`, `rot`) if available, otherwise kicks off an async bake.
## Cached value is a Dictionary with three keys:
##   tex         — the captured ImageTexture
##   rect_offset — Vector2 offset from the block's top_pos to where the
##                 texture should be painted (negative when the bake
##                 padded outside the block footprint, e.g. so turret
##                 heads pointing past the edge aren't clipped)
##   rect_size   — Vector2 the texture should be painted at
## An empty dictionary means the bake hasn't resolved yet — caller paints
## a fallback for that frame.
func _request_preview_composite(block_id: StringName, rot: int) -> Dictionary:
	var key := "%s|%d" % [String(block_id), rot]
	if _preview_bake_cache.has(key):
		return _preview_bake_cache[key]
	if not _preview_bake_pending.has(key):
		_preview_bake_pending[key] = true
		_run_preview_bake.call_deferred(block_id, rot, key)
	return {}


## Returns the per-side padding (in pixels) the bake should add around
## the block's footprint so the layered draw can extend past the block
## without getting clipped. Currently only turret heads need padding —
## the rest of the bakeable block types fit inside their footprint.
func _preview_bake_padding_for(data: BlockData) -> float:
	if data == null:
		return 0.0
	if data.is_turret() and data.turret_head_sprite:
		var head_size: Vector2 = data.turret_head_sprite.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
		var bcount: int = maxi(data.barrel_count, 1)
		# Multi-barrel pivots can sit `(bcount-1)/2 * spacing` off-center
		# along one axis; the head can extend `head_size.length()` from
		# the pivot in any direction (because rotation is unconstrained).
		var max_lateral: float = (float(bcount) - 1.0) * 0.5 * data.barrel_spacing
		var head_reach: float = head_size.length()
		return max_lateral + head_reach
	return 0.0


## Async bake worker. Sets up a SubViewport with the right Sprite2D
## layers for `block_id` at `rot`, waits one frame for it to render,
## captures the result, and stows it in `_preview_bake_cache[key]`.
func _run_preview_bake(block_id: StringName, rot: int, key: String) -> void:
	var data := Registry.get_block(block_id)
	if data == null:
		_preview_bake_pending.erase(key)
		return
	while not _textures_ready:
		await get_tree().process_frame
	var gs: float = float(main.GRID_SIZE)
	var pad: float = _preview_bake_padding_for(data)
	var block_size := Vector2i(int(data.grid_size.x * gs), int(data.grid_size.y * gs))
	# Round padding up to a whole pixel so SubViewport size stays integer.
	var pad_i: int = int(ceil(pad))
	var sv_size: Vector2i = block_size + Vector2i(pad_i * 2, pad_i * 2)
	if sv_size.x <= 0 or sv_size.y <= 0:
		_preview_bake_pending.erase(key)
		return
	var sv := SubViewport.new()
	sv.size = sv_size
	sv.transparent_bg = true
	sv.disable_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(sv)

	_populate_preview_layers(sv, data, rot, Vector2(pad_i, pad_i))

	# Two `frame_post_draw`s — Godot needs one for child nodes to register
	# in the SubViewport's tree and another for the actual capture.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var img: Image = sv.get_texture().get_image()
	if img:
		_preview_bake_cache[key] = {
			"tex": ImageTexture.create_from_image(img),
			"rect_offset": Vector2(-float(pad_i), -float(pad_i)),
			"rect_size": Vector2(sv_size),
		}
	sv.queue_free()
	_preview_bake_pending.erase(key)
	queue_redraw()


## Populates `sv` with the Sprite2D children that compose the layered
## preview for `data` at `rot`. Branches on block type — each branch
## adds the same set of layers the live render would paint, in the
## same order, so the captured texture matches the in-game appearance.
## `pad` is the per-side padding the SubViewport was sized with — body
## sprites sit at +pad inside the SV so the block footprint stays
## centered while turret heads have room to extend outside it.
func _populate_preview_layers(sv: SubViewport, data: BlockData, rot: int, pad: Vector2 = Vector2.ZERO) -> void:
	var sv_size := Vector2(sv.size)
	var gs: float = float(main.GRID_SIZE)
	var block_size := Vector2(data.grid_size.x * gs, data.grid_size.y * gs)
	var center := pad + block_size * 0.5
	# Helper: add a Sprite2D scaled to fill a given rect inside the SV
	# (in SubViewport-pixel coordinates).
	var add_fill := func(tex: Texture2D, pos: Vector2, fill_size: Vector2, rotation: float = 0.0):
		if tex == null:
			return
		var s := Sprite2D.new()
		s.texture = tex
		s.centered = true
		s.position = pos + fill_size * 0.5
		s.rotation = rotation
		var ts := tex.get_size()
		if ts.x > 0 and ts.y > 0:
			s.scale = Vector2(fill_size.x / ts.x, fill_size.y / ts.y)
		sv.add_child(s)

	# --- Cores: base sprite + faction overlay (LUMINA in placement). ---
	if data.tags.has("core"):
		if data.base_sprite:
			add_fill.call(data.base_sprite, pad, block_size)
		var overlay_tex: Texture2D = data.lumina_overlay
		if overlay_tex:
			var overlay_scale := 0.7
			var ow: float = block_size.x * overlay_scale
			var oh: float = block_size.y * overlay_scale
			add_fill.call(overlay_tex,
				pad + Vector2((block_size.x - ow) * 0.5, (block_size.y - oh) * 0.5),
				Vector2(ow, oh))
		return

	# --- Turrets: body (base/top) + chassis (multi-barrel) + heads. ---
	if data.is_turret():
		if data.base_sprite:
			add_fill.call(data.base_sprite, pad, block_size)
		if data.top_sprite and data.top_sprite != data.base_sprite:
			add_fill.call(data.top_sprite, pad, block_size)
		var aim_angle: float = float(rot) * (PI / 2.0)
		var draw_angle: float = aim_angle + PI / 2.0
		var bcount: int = maxi(data.barrel_count, 1)
		var head_tex: Texture2D = data.turret_head_sprite
		if head_tex:
			var tex_size: Vector2 = head_tex.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
			var chassis_dir := Vector2.from_angle(aim_angle)
			var chassis_perp := Vector2(-chassis_dir.y, chassis_dir.x)
			# Chassis plate (multi-barrel only).
			if bcount > 1 and data.turret_chassis_sprite:
				var ctex: Texture2D = data.turret_chassis_sprite
				var csize: Vector2 = ctex.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
				var cs := Sprite2D.new()
				cs.texture = ctex
				cs.centered = true
				cs.position = center
				cs.rotation = draw_angle
				var cts := ctex.get_size()
				cs.scale = Vector2(csize.x / cts.x, csize.y / cts.y)
				sv.add_child(cs)
			# Heads — one per barrel. Wraps each head Sprite2D in a
			# Node2D pivot so rotation happens around the chassis pivot
			# (`pivot`) and the head's offset from that pivot is in the
			# pivot's *local* space — same composition as the live
			# `_draw_turret_preview_heads` rect.
			var hts := head_tex.get_size()
			for i in range(bcount):
				var lateral: float = 0.0
				if bcount > 1:
					lateral = (float(i) - (float(bcount) - 1.0) * 0.5) * data.barrel_spacing
				var pivot: Vector2 = center + chassis_perp * lateral
				var pivot_node := Node2D.new()
				pivot_node.position = pivot
				pivot_node.rotation = draw_angle
				sv.add_child(pivot_node)
				var hs := Sprite2D.new()
				hs.texture = head_tex
				hs.centered = true
				# Live render rect:
				#   Rect2((-tex_size.x*0.5, -tex_size.y + 14*sf), tex_size)
				# Center of that rect in pivot-local: (0, -tex_size.y*0.5 + 14*sf)
				hs.position = Vector2(0.0, -tex_size.y * 0.5 + 14.0 * main.SPRITE_SCALE_FACTOR)
				hs.scale = Vector2(tex_size.x / hts.x, tex_size.y / hts.y)
				pivot_node.add_child(hs)
		return

	# Fallback: just paint whatever single sprite the block has — gives
	# a safe baseline for any block type we ask to bake but haven't
	# specialised yet.
	if data.top_sprite:
		add_fill.call(data.top_sprite, pad, block_size)
	elif data.base_sprite:
		add_fill.call(data.base_sprite, pad, block_size)


## Renders inner@0 + inner@45 + base into a transparent SubViewport and
## captures the composite as an ImageTexture. The output's size matches
## the base texture's size — base is painted last so it sits on top of
## the spinning blades, same draw order as the live render.
func _bake_spinner_preview_composite(inner_tex: Texture2D, base_tex: Texture2D) -> Texture2D:
	if inner_tex == null or base_tex == null:
		return null
	var size: Vector2i = base_tex.get_size()
	if size.x <= 0 or size.y <= 0:
		return null
	var sv := SubViewport.new()
	sv.size = size
	sv.transparent_bg = true
	sv.disable_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(sv)

	var center := Vector2(size) * 0.5

	# Inner @ 0° — drawn first (under everything).
	var s1 := Sprite2D.new()
	s1.texture = inner_tex
	s1.centered = true
	s1.position = center
	sv.add_child(s1)

	# Inner @ 45°.
	var s2 := Sprite2D.new()
	s2.texture = inner_tex
	s2.centered = true
	s2.position = center
	s2.rotation = PI / 4.0
	sv.add_child(s2)

	# Base on top.
	var s3 := Sprite2D.new()
	s3.texture = base_tex
	s3.centered = true
	s3.position = center
	sv.add_child(s3)

	# Wait for the SubViewport to finish rendering this frame.
	await RenderingServer.frame_post_draw

	var img: Image = sv.get_texture().get_image()
	var tex: ImageTexture = null
	if img:
		tex = ImageTexture.create_from_image(img)
	sv.queue_free()
	return tex


## Per-frame tick for vent condensers. Same shape as the vent turbine
## tick — each anchor's angular velocity eases toward `VENT_CONDENSER_SPIN`
## while the building is active and back to zero when it isn't.
func _tick_vent_condenser_states(delta: float) -> void:
	if _vent_condenser_state.is_empty():
		return
	var to_erase: Array[Vector2i] = []
	for anchor in _vent_condenser_state:
		if not main.placed_buildings.has(anchor):
			to_erase.append(anchor)
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings[anchor])
		if data == null or data.id != &"vent_condenser":
			to_erase.append(anchor)
			continue
		var active: bool = not (main.has_method("is_building_inactive") \
			and main.is_building_inactive(anchor))
		var target: float = VENT_CONDENSER_SPIN if active else 0.0
		var s: Dictionary = _vent_condenser_state[anchor]
		var step: float = VENT_CONDENSER_ACCEL * delta
		s["vel"] = move_toward(float(s["vel"]), target, step)
		s["angle"] = fposmod(float(s["angle"]) + float(s["vel"]) * delta, TAU)
	for a in to_erase:
		_vent_condenser_state.erase(a)


## Static (frozen) vent-condenser layered preview. Mirrors the turbine
## preview — uses the pre-baked composite when ready, falls back to
## individual layers while the bake is still pending.
func _draw_vent_condenser_preview(top_pos: Vector2, width: float, height: float, tint: Color = Color.WHITE) -> void:
	var size := Vector2(width, height)
	if _vent_condenser_preview_texture:
		draw_texture_rect(_vent_condenser_preview_texture, Rect2(top_pos, size), false, tint)
		return
	if _vent_condenser_base_texture == null:
		return
	if _vent_condenser_inner_texture:
		draw_texture_rect(_vent_condenser_inner_texture, Rect2(top_pos, size), false, tint)
	draw_texture_rect(_vent_condenser_base_texture, Rect2(top_pos, size), false, tint)


## Vent condenser: two spinning copies of `VentCondenserInner` under a
## static `VentCondenserBase`. Mirrors the vent-turbine composition.
func _draw_vent_condenser(grid_pos: Vector2i, top_pos: Vector2, width: float, height: float, tint: Color = Color.WHITE) -> void:
	if _vent_condenser_base_texture == null:
		return
	if not _vent_condenser_state.has(grid_pos):
		_vent_condenser_state[grid_pos] = {"angle": 0.0, "vel": 0.0}
	var s: Dictionary = _vent_condenser_state[grid_pos]
	var angle: float = float(s["angle"])
	var center: Vector2 = top_pos + Vector2(width * 0.5, height * 0.5)
	var size := Vector2(width, height)
	if _vent_condenser_inner_texture:
		draw_set_transform(center, angle)
		draw_texture_rect(_vent_condenser_inner_texture, Rect2(-size * 0.5, size), false, tint)
		draw_set_transform(center, angle + PI / 4.0)
		draw_texture_rect(_vent_condenser_inner_texture, Rect2(-size * 0.5, size), false, tint)
		draw_set_transform(Vector2.ZERO, 0.0)
	draw_texture_rect(_vent_condenser_base_texture, Rect2(top_pos, size), false, tint)


## Vent turbine: two spinning copies of `VentTurbineInner` under a static
## `VentTurbineBase`. The second inner copy is offset by 45° so the blades
## look interleaved as they rotate. Both share the same `angle` so they
## stay locked together.
func _draw_vent_turbine(grid_pos: Vector2i, top_pos: Vector2, width: float, height: float, tint: Color = Color.WHITE) -> void:
	if _vent_turbine_base_texture == null:
		return
	if not _vent_turbine_state.has(grid_pos):
		_vent_turbine_state[grid_pos] = {"angle": 0.0, "vel": 0.0}
	var s: Dictionary = _vent_turbine_state[grid_pos]
	var angle: float = float(s["angle"])
	var center: Vector2 = top_pos + Vector2(width * 0.5, height * 0.5)
	var size := Vector2(width, height)
	# Spinning inner blades — drawn first so the static base plate sits
	# on top, masking everything except the rim of the discs.
	if _vent_turbine_inner_texture:
		draw_set_transform(center, angle)
		draw_texture_rect(_vent_turbine_inner_texture, Rect2(-size * 0.5, size), false, tint)
		draw_set_transform(center, angle + PI / 4.0)
		draw_texture_rect(_vent_turbine_inner_texture, Rect2(-size * 0.5, size), false, tint)
		draw_set_transform(Vector2.ZERO, 0.0)
	# Static base plate.
	draw_texture_rect(_vent_turbine_base_texture, Rect2(top_pos, size), false, tint)


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
		# Filter menu first, then crane link mode, then power-link source.
		if _crane_filter_menu_open:
			_close_crane_filter_menu()
			get_viewport().set_input_as_handled()
			return
		if _crane_link_anchor != Vector2i(-1, -1):
			_crane_link_anchor = Vector2i(-1, -1)
			_crane_link_next_kind = "input"
			queue_redraw()
			get_viewport().set_input_as_handled()
			return
		if link_source != Vector2i(-1, -1):
			link_source = Vector2i(-1, -1)
			_link_just_linked = Vector2i(-1, -1)
			queue_redraw()
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
		# Schematics drop a whole batch of build orders — also locked
		# while piloting a non-builder.
		if _is_controlling_non_builder():
			return
		_execute_schematic_placement()
		return

	# Rebuild mode (hold to show destroyed ghosts, drag to select)
	if event.is_action("rebuild_mode"):
		# Hold-B reconstructs destroyed buildings in a rect → also a
		# placement action, so block it while piloting.
		if _is_controlling_non_builder():
			# Make sure we don't get stuck mid-drag if control was taken
			# while the key was already held.
			_rebuild_mode = false
			_rebuild_dragging = false
			return
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
		# Legacy "L" key: now just clears any pending link selection.
		# Linking happens via plain clicks on linkable blocks.
		if link_source != Vector2i(-1, -1):
			link_source = Vector2i(-1, -1)
			_link_just_linked = Vector2i(-1, -1)
			queue_redraw()


func _process(_delta: float) -> void:
	# Pause-aware crusher-head inertial tick. While the world is paused the
	# per-block velocity/angle both freeze in place; when unpaused they ease
	# back in or out, giving each head a real spool-up/coast-down feel.
	if not ("world_paused" in main and main.world_paused):
		_tick_crusher_head_states(_delta)
		_tick_scraper_head_states(_delta)
		_tick_vent_turbine_states(_delta)
		_tick_vent_condenser_states(_delta)
		_tick_autonomous_cranes(_delta)
		_tick_held_payload_simulation(_delta)
		if belt_scroll_enabled:
			# Advance the conveyor scroll phase. Wrap on a 1024 px window —
			# big enough that no single belt segment hits the modulus,
			# small enough that the float doesn't lose precision over a
			# long session. Frozen while the world is paused so visuals
			# match the "items aren't moving" reading the player gets
			# from logistics. Skipped entirely when the toggle is off so
			# we don't pay the per-frame redraw on machines that aren't
			# using this effect.
			_belt_scroll_phase = fposmod(_belt_scroll_phase + _delta * _BELT_SCROLL_PIXELS_PER_SEC, 1024.0)
			queue_redraw()

	# --- Unified work queue: build + deconstruct, one at a time ---
	# Walk the queue and tick the first entry that's currently within build
	# range. Out-of-range entries are just skipped over (not removed) — they'll
	# pick up again once the drone returns. This lets the drone move on to
	# reachable work instead of stalling on a distant one. The _tickable_
	# variant also respects pause flags so paused games don't advance progress
	# (but the draw pass still highlights the frozen active anchor).
	var anchor: Vector2i = _get_tickable_work_anchor()
	if anchor != _NO_ACTIVE_WORK:
		# Deferred same-group swap (belt → junction, etc.): tick the
		# build progress on the pending_swaps entry while leaving the
		# OLD block live in placed_buildings. The atomic destroy/replace
		# only fires at the end so the player never sees the cell as
		# "non-constructed" during the build.
		if "pending_swaps" in main and main.pending_swaps.has(anchor):
			_tick_pending_swap(anchor, _delta)
		elif main.building_build_progress.has(anchor):
			_tick_progressive_build(anchor, _delta)
		elif main.building_deconstruct_progress.has(anchor):
			_tick_progressive_deconstruct(anchor, _delta)
		else:
			# Orphan entry (building destroyed externally) — remove
			main.work_order.erase(anchor)
			if main.has_method("resume_auto_paused_by"):
				main.resume_auto_paused_by(anchor)
			if "work_paused" in main:
				main.work_paused.erase(anchor)

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
		# Advance the scan-line phase only while the world is running so
		# the reveal line freezes at its current position during pause.
		_archive_scan_phase += _delta
		_tick_archive_scan_fade(_delta)

	# --- The rest of _process (preview, drag, redraw) continues in the
	# indented block below. The tick helper functions follow after _process ends. ---

	# Always redraw for parallax (walls + void tiles shift with camera)
	queue_redraw()

	# Keep redrawing while a link source is selected so the dashed
	# line-to-mouse animates with the cursor.
	if link_source != Vector2i(-1, -1):
		queue_redraw()

	# Update demolish rectangle preview while dragging
	if _demolish_dragging:
		var mouse_world = get_global_mouse_position()
		_demolish_end = main.world_to_grid(mouse_world)
		queue_redraw()

	# Keep redrawing while in crane link mode (highlight + diamonds).
	# Also exit link mode if the linked crane has started deconstructing —
	# the player tearing it down shouldn't keep its link UI active.
	if _crane_link_anchor != Vector2i(-1, -1):
		var still_valid: bool = main.placed_buildings.has(_crane_link_anchor)
		if still_valid and "building_deconstruct_progress" in main \
				and main.building_deconstruct_progress.has(_crane_link_anchor):
			still_valid = false
		if not still_valid:
			_crane_link_anchor = Vector2i(-1, -1)
			_crane_link_next_kind = "input"
			if _crane_filter_menu_open:
				_close_crane_filter_menu()
		queue_redraw()

	# Crane filter menu hover
	if _crane_filter_menu_open:
		var fmw := get_global_mouse_position()
		var new_h := _crane_filter_menu_hit_test(fmw)
		if new_h != _crane_filter_menu_hovered:
			_crane_filter_menu_hovered = new_h
			queue_redraw()

	# Update world menu hover
	if _world_menu_open:
		var mw = get_global_mouse_position()
		var new_hovered := _world_menu_hit_test(mw)
		if new_hovered != _world_menu_hovered:
			_world_menu_hovered = new_hovered
			queue_redraw()
		if _storage_panel_open:
			var sh := _storage_panel_hit_test(mw)
			if sh != _storage_panel_hovered:
				_storage_panel_hovered = sh
				queue_redraw()

	# When nothing is selected for placement, still tick the
	# hover-over-turret range indicator: redraw whenever the hovered
	# turret anchor changes (entering / leaving / different turret).
	if main.selected_building == &"":
		_drag_placing = false
		_drag_cells.clear()
		var idle_mw: Vector2 = get_global_mouse_position()
		var idle_grid: Vector2i = main.world_to_grid(idle_mw)
		var idle_anchor: Vector2i = main.building_origins.get(idle_grid, Vector2i(-1, -1))
		var idle_data: BlockData = Registry.get_block(main.placed_buildings.get(idle_anchor, &""))
		var hover_turret: Vector2i = idle_anchor if (idle_data != null and idle_data.is_turret()) else Vector2i(-1, -1)
		if hover_turret != _last_hovered_turret_anchor:
			_last_hovered_turret_anchor = hover_turret
			queue_redraw()
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
			# When the drag starts on an existing belt, treat the drag as
			# "extend this belt" rather than "cross it" — skip the auto
			# junction/bridge substitution.
			var skip_crossings: bool = _drag_starts_on_same_transport(_drag_start, tag)
			_drag_cells = _compute_transport_path(_drag_start, preview_grid_pos, tag, skip_crossings)
			# Pass the cursor cell as a target hint so the trailing belt
			# faces INTO whatever block the user dragged onto, even when
			# A* had to reroute to a non-solid neighbour.
			_compute_path_rotations(_drag_cells, preview_grid_pos)
		else:
			# --- Normal axis-locked line ---
			_pathfind_mode = false
			_pathfind_rotations.clear()
			_pathfind_bridge_cells.clear()
			_pathfind_bridge_pairs.clear()
			_transport_astar = null

			var dx := preview_grid_pos.x - _drag_start.x
			var dy := preview_grid_pos.y - _drag_start.y
			# Walls + Option (Alt on Mac): allow 8-direction drag, so
			# horizontal / vertical / both diagonals are all valid line
			# orientations. Snaps to whichever of the 8 cardinal &
			# diagonal axes the cursor is closest to so a slightly-off
			# drag still produces a clean line.
			var allow_diagonal: bool = alt_held \
				and data and data.tags.has("wall")
			if allow_diagonal:
				var sx: int = signi(dx)
				var sy: int = signi(dy)
				var ax: int = absi(dx)
				var ay: int = absi(dy)
				# If one axis dominates by more than ~2:1 treat the drag
				# as axis-locked; otherwise it's diagonal. The cutoff
				# lets the player commit to a single axis intentionally
				# while still snapping to diag for ~45° drags.
				if ax >= ay * 2:
					sy = 0
				elif ay >= ax * 2:
					sx = 0
				if sx == 0 and sy == 0:
					_drag_cells.append(_drag_start)
				else:
					var step_x: int = sx * grid_w
					var step_y: int = sy * grid_h
					var max_steps: int
					if step_x != 0 and step_y != 0:
						max_steps = maxi(int(ax / float(grid_w)), int(ay / float(grid_h)))
					elif step_x != 0:
						max_steps = int(ax / float(grid_w))
					else:
						max_steps = int(ay / float(grid_h))
					for k in range(max_steps + 1):
						_drag_cells.append(Vector2i(
							_drag_start.x + step_x * k,
							_drag_start.y + step_y * k,
						))
			# Lock to the axis with the larger delta; step by building size
			elif abs(dx) >= abs(dy):
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

			# Auto-rotate directional blocks (belts, ducts, pipes, shafts) in drag direction.
			# Pass `preview_grid_pos` as a hint so a single-cell drag ending
			# adjacent to a block, or the trailing cell of a multi-cell drag
			# whose path's last leg was sideways, both face the cursor cell.
			if _is_directional(main.selected_building) and _drag_cells.size() >= 1:
				_compute_path_rotations(_drag_cells, preview_grid_pos)

			# Straight-line drags of a transport block also auto-junction
			# perpendicular crossings and auto-bridge parallel crossings so
			# the user doesn't have to hand-place those pieces. Uses the
			# same helper the Alt-pathfind branch uses.
			#
			# IMPORTANT: skip the substitution when the drag STARTS on a
			# same-type belt. Starting on a belt reads as "rotate this
			# existing belt (and extend from it)", so we keep the raw line
			# and let the overlay-rotation code (try_place_building's
			# same-block rotation branch) handle direction changes.
			if _is_transport_block(main.selected_building) and _drag_cells.size() > 1:
				var tag2 := _get_transport_tag(main.selected_building)
				if not _drag_starts_on_same_transport(_drag_start, tag2):
					_drag_cells = _apply_transport_crossings(_drag_cells, tag2)
					if _is_directional(main.selected_building):
						_compute_path_rotations(_drag_cells, preview_grid_pos)

	queue_redraw()


## Mirrors _tick_progressive_build but operates on a pending_swaps entry —
## the old block stays live in placed_buildings while progress ticks on
## the swap dict itself. When progress hits build_time AND every build
## cost has been paid, `execute_pending_swap` atomically destroys the
## old block and places the new one fully built. Until then the world
## still sees the original belt / pipe / shaft, with the new block
## drawn as a translucent ghost overlay.
func _tick_pending_swap(anchor: Vector2i, delta: float) -> void:
	var entry: Dictionary = main.pending_swaps[anchor]
	var new_id: StringName = StringName(entry.get("new_block_id", &""))
	var new_data = Registry.get_block(new_id)
	if new_data == null:
		main.pending_swaps.erase(anchor)
		main.work_order.erase(anchor)
		return
	var build_time: float = float(entry.get("build_time", new_data.build_time))
	if build_time <= 0.0:
		build_time = 1.0

	entry["progress"] = float(entry.get("progress", 0.0)) + delta
	var pct: float = clampf(float(entry["progress"]) / build_time, 0.0, 1.0)
	var consumed: Dictionary = entry.get("consumed", {})

	var any_consumed := false
	var all_fully_consumed := true
	if main.require_resources and not new_data.build_cost.is_empty():
		for item_id in new_data.build_cost:
			var rk: StringName = main._resolve_resource_key(str(item_id))
			var required: int = int(new_data.build_cost[item_id])
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
				if int(consumed.get(rk, 0)) < required:
					all_fully_consumed = false
		entry["consumed"] = consumed

	# Mirror-refund the OLD block's build_cost in lockstep with `pct`
	# so deconstructing the existing block is paid for as the swap
	# advances, rather than at the end. Matches the player's mental
	# model: "I'm gradually undoing the old block while building the
	# new one, so I should be getting materials back as I go."
	var refund_pool: Dictionary = entry.get("refund_pool", {})
	var refunded: Dictionary = entry.get("refunded", {})
	if not refund_pool.is_empty():
		for rk in refund_pool:
			var pool_amt: int = int(refund_pool[rk])
			var target_refund: int = floori(pct * pool_amt)
			var already_refunded: int = int(refunded.get(rk, 0))
			var grant: int = target_refund - already_refunded
			if grant > 0:
				main._grant_resource_capped(rk, grant)
				refunded[rk] = already_refunded + grant
		entry["refunded"] = refunded

		# Stall progress when nothing more can be paid for, so the swap
		# pauses cleanly under resource starvation rather than silently
		# advancing past the available budget.
		if not any_consumed and not all_fully_consumed:
			var min_pct: float = 1.0
			for item_id in new_data.build_cost:
				var rk2: StringName = main._resolve_resource_key(str(item_id))
				var required2: int = int(new_data.build_cost[item_id])
				if required2 > 0:
					min_pct = minf(min_pct, float(consumed.get(rk2, 0)) / float(required2))
			entry["progress"] = min_pct * build_time
			return

	if any_consumed:
		main.resources_changed.emit(main.resources)

	if all_fully_consumed and float(entry["progress"]) >= build_time:
		# Drop work-order bookkeeping BEFORE the swap so completion
		# matches what the build tick does for normal placements.
		main.work_order.erase(anchor)
		if main.has_method("resume_auto_paused_by"):
			main.resume_auto_paused_by(anchor)
		if "work_paused" in main:
			main.work_paused.erase(anchor)
		main.execute_pending_swap(anchor)


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
		if main.has_method("resume_auto_paused_by"):
			main.resume_auto_paused_by(anchor)
		if "work_paused" in main:
			main.work_paused.erase(anchor)
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
		# Fire the completion signal so listeners that care about *fully
		# built* blocks (sector-script "placed", tutorial counters, etc.)
		# advance now rather than at queue time.
		var built_id: StringName = main.placed_buildings.get(anchor, &"")
		if built_id != &"" and main.has_signal("building_completed"):
			main.building_completed.emit(built_id, anchor)
		# erase by value, not index — the active anchor may not be at [0]
		# if earlier entries were skipped for being out of build range.
		main.work_order.erase(anchor)
		# Any queued work that was auto-paused waiting for THIS anchor to
		# finish now resumes; explicit pauses on this anchor are cleared too.
		if main.has_method("resume_auto_paused_by"):
			main.resume_auto_paused_by(anchor)
		if "work_paused" in main:
			main.work_paused.erase(anchor)
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
		# Resume anything that was waiting on this decon to finish; clear
		# any explicit pause on this anchor.
		if main.has_method("resume_auto_paused_by"):
			main.resume_auto_paused_by(anchor)
		if "work_paused" in main:
			main.work_paused.erase(anchor)
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
	# Walls and platforms additionally allow size-up swaps where a bigger
	# block absorbs smaller same-group blocks whose footprints all fall
	# inside the new block's footprint.
	var new_swap_group: StringName = &""
	if main.has_method("_get_swap_group"):
		new_swap_group = main._get_swap_group(data)
	var size_up_eligible: bool = (data.tags.has("wall") or data.tags.has("platform")) \
			and (data.grid_size.x > 1 or data.grid_size.y > 1) \
			and new_swap_group != &""
	var rect_min: Vector2i = grid_pos
	var rect_max: Vector2i = grid_pos + data.grid_size - Vector2i(1, 1)
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
						# Reject stacking platform-on-platform unless the
						# new block is a bigger platform that can absorb
						# this one via the size-up swap.
						if is_platform and not size_up_eligible:
							return false
						if is_platform and size_up_eligible:
							var ex_anchor: Vector2i = main.building_origins.get(check_pos, check_pos)
							var ex_max: Vector2i = ex_anchor + cell_data.grid_size - Vector2i(1, 1)
							if ex_anchor.x < rect_min.x or ex_anchor.y < rect_min.y \
									or ex_max.x > rect_max.x or ex_max.y > rect_max.y \
									or main.get_building_faction(ex_anchor) != main.Faction.LUMINA:
								return false
							# Absorbed — treat as if cell were empty for the
							# rest of this iteration.
						else:
							has_platform_under = true
					elif cell_data and new_swap_group != &"" \
							and data.grid_size == Vector2i(1, 1) \
							and cell_data.grid_size == Vector2i(1, 1) \
							and main._get_swap_group(cell_data) == new_swap_group \
							and main.get_building_faction(check_pos) == main.Faction.LUMINA:
						# 1×1 same-group swap: cell is placeable. The swap
						# itself happens in main.try_place_building.
						pass
					elif size_up_eligible and cell_data \
							and main._get_swap_group(cell_data) == new_swap_group \
							and main.get_building_faction(check_pos) == main.Faction.LUMINA:
						# Size-up swap: the existing same-group block must
						# lie ENTIRELY inside the new block's footprint;
						# otherwise we'd corrupt cells of an unrelated tile.
						var ex_anchor2: Vector2i = main.building_origins.get(check_pos, check_pos)
						var ex_max2: Vector2i = ex_anchor2 + cell_data.grid_size - Vector2i(1, 1)
						if ex_anchor2.x < rect_min.x or ex_anchor2.y < rect_min.y \
								or ex_max2.x > rect_max.x or ex_max2.y > rect_max.y:
							return false
					else:
						return false
			if terrain and terrain.has_wall(check_pos):
				return false
			# Void rejection: no floor, no wall — nothing builds on the abyss,
			# not even platforms (platforms bridge water, not nothing).
			if terrain and terrain.is_void(check_pos) and not has_platform_under:
				return false
			if terrain:
				var depth: int = terrain.get_water_depth_at(check_pos)
				# Platforms are water-only — they bridge any water depth
				# but reject placement on dry land. The red "can't place"
				# overlay falls out of the same _can_place_terrain check.
				if is_platform and depth <= 0 and not has_platform_under:
					return false
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
	var paused: Dictionary = main.work_paused if "work_paused" in main else {}
	# First pass: prefer the earliest-queued entry that can actually make
	# progress this frame. A progressive build whose remaining build_cost
	# items have zero stock would stall on a regular tick, leaving later
	# queued work blocked behind it — skip past it so the drone keeps
	# busy on something it can finish.
	for a in main.work_order:
		if paused.has(a):
			continue
		if not _is_in_build_range(a):
			continue
		if _anchor_can_progress(a):
			return a
	# Second pass: nothing could progress, fall back to the original
	# "first in-range entry" so the active anchor still renders / the
	# drone visibly waits at the next thing it'll work on.
	for a in main.work_order:
		if paused.has(a):
			continue
		if _is_in_build_range(a):
			return a
	return _NO_ACTIVE_WORK


## True if the anchor's build can advance this tick. Deconstructs always
## can (they produce resources). Builds need either:
##   - all build_cost items already paid (timer is just ticking), or
##   - at least one unpaid item that has stock > 0 in main.resources.
## Otherwise the build is starved and we should yield to a later queue
## entry that has work it can actually do.
func _anchor_can_progress(anchor: Vector2i) -> bool:
	if not main.require_resources:
		return true
	# Deconstruct / unknown anchors: not a progressive-build entry, no
	# resource gating to evaluate.
	if not ("building_build_progress" in main) or not main.building_build_progress.has(anchor):
		return true
	var bid: StringName = main.placed_buildings.get(anchor, &"")
	var data = Registry.get_block(bid)
	if data == null or data.build_cost.is_empty():
		return true
	var consumed: Dictionary = main.building_resources_consumed.get(anchor, {}) \
		if "building_resources_consumed" in main else {}
	var any_remaining := false
	for item_id in data.build_cost:
		var rk: StringName = main._resolve_resource_key(str(item_id))
		var required: int = int(data.build_cost[item_id])
		var already: int = int(consumed.get(rk, 0))
		if already < required:
			any_remaining = true
			if int(main.resources.get(rk, 0)) > 0:
				return true
	# Nothing left to pay for — let the timer tick out.
	if not any_remaining:
		return true
	return false


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
	# Pump must be on liquid — except for condensers, which extract from
	# steam and need a vent or geyser tile centered under their footprint.
	elif data.tags.has("pump"):
		if data.tags.has("condenser"):
			if terrain:
				var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
				var tid = terrain.floor_tiles.get(center, &"")
				if tid != &"vent" and tid != &"geyser":
					return false
		elif not _is_on_liquid(grid_pos):
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

	# Unit-occupied check: if any non-flying unit overlaps the footprint,
	# the placement gate in main.gd will reject — so the preview should
	# read red. Flying units don't count (they're a different layer).
	if main.has_method("_is_cell_occupied_by_unit"):
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				if main._is_cell_occupied_by_unit(grid_pos + Vector2i(x, y)):
					return false

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
	# Pump must be on liquid — except for condensers, which extract from
	# steam and need a vent or geyser tile centered under their footprint.
	elif data.tags.has("pump"):
		if data.tags.has("condenser"):
			if terrain:
				var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
				var tid = terrain.floor_tiles.get(center, &"")
				if tid != &"vent" and tid != &"geyser":
					return false
		elif not _is_on_liquid(grid_pos):
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

	# Floor miners only accept floor-ore patches (coal); regular drills
	# only accept wall-embedded ores. Without this split, placing a
	# mechanical drill next to a coal patch would succeed but the live
	# tick would refuse to mine — confusing.
	var is_floor_miner: bool = data.tags.has("floor_miner")
	# Floor miners (ground scraper) sit DIRECTLY on top of their ore —
	# the front edge is past the ore patch, so check the FOOTPRINT cells
	# instead. Any covered floor-ore tile passes placement; the
	# efficiency calc determines how productive that ends up being.
	if is_floor_miner:
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				if _ore_matches_miner(terrain, grid_pos + Vector2i(x, y), true):
					return true
		return false
	var front_cells = _get_front_edge(grid_pos, data.grid_size, rotation)
	for cell in front_cells:
		if _ore_matches_miner(terrain, cell, is_floor_miner):
			return true
		if _ore_matches_miner(terrain, cell + dir, is_floor_miner):
			return true
	return false


func _ore_matches_miner(terrain, cell: Vector2i, is_floor_miner: bool) -> bool:
	var ore_data: TerrainTileData = terrain.get_ore_at(cell)
	if ore_data == null:
		return false
	var is_floor_ore: bool = ore_data.tags.has("floor_ore")
	if is_floor_miner:
		return is_floor_ore
	return not is_floor_ore


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

## Returns every cell on the *outside* perimeter of a rectangular block
## footprint — i.e. the cells the building would touch if you walked
## around its outline. Used by multi-tile-aware adjacency checks
## (archive decoder, etc.) so they don't only see the four cells
## bordering the anchor.
func _get_block_perimeter_cells(origin: Vector2i, grid_size: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	# Top edge
	for x in range(grid_size.x):
		cells.append(Vector2i(origin.x + x, origin.y - 1))
	# Bottom edge
	for x in range(grid_size.x):
		cells.append(Vector2i(origin.x + x, origin.y + grid_size.y))
	# Left edge
	for y in range(grid_size.y):
		cells.append(Vector2i(origin.x - 1, origin.y + y))
	# Right edge
	for y in range(grid_size.y):
		cells.append(Vector2i(origin.x + grid_size.x, origin.y + y))
	return cells


## Handles left-click on a cell that has active/pending work attached
## (build, deconstruct, or a deferred swap). Returns true when the click
## was consumed and no further handling should happen.
##
## Rules:
##   - Click the block currently being worked on: pause it in place.
##   - Click a paused or queued-but-not-yet-active block: promote it to the
##     front of work_order, unpause it, and pause whatever was active so it
##     resumes automatically once the promoted block finishes.
func _handle_work_click(click_pos: Vector2i) -> bool:
	if not ("work_order" in main):
		return false
	var anchor: Vector2i = main.building_origins.get(click_pos, click_pos)
	# If the cell is a deferred same-group swap the "real" anchor is just
	# the cell itself (the old building still maps to its own origin).
	if "pending_swaps" in main and main.pending_swaps.has(click_pos):
		anchor = click_pos
	var has_build: bool = "building_build_progress" in main and main.building_build_progress.has(anchor)
	var has_decon: bool = "building_deconstruct_progress" in main and main.building_deconstruct_progress.has(anchor)
	var has_pending_swap: bool = "pending_swaps" in main and main.pending_swaps.has(anchor)
	var in_queue: bool = main.work_order.has(anchor)
	if not (has_build or has_decon or has_pending_swap or in_queue):
		return false

	var active: Vector2i = _get_active_work_anchor()
	var paused: Dictionary = main.work_paused if "work_paused" in main else {}

	if anchor == active and not paused.has(anchor):
		# Clicked the actively-working block → explicit pause.
		main.work_paused[anchor] = true
		queue_redraw()
		return true

	# Click on a paused deconstruction → reverse direction. The block
	# becomes a partial-build again at its current progress so the
	# player can salvage a block they started tearing down by mistake.
	if has_decon and paused.has(anchor):
		if _reverse_decon_to_build(anchor):
			queue_redraw()
			return true

	# Otherwise promote to front: unpause this one, auto-pause the
	# previously-active anchor (it will resume when this finishes), and
	# reorder so work picks up the new front on its next tick.
	if in_queue:
		var idx: int = main.work_order.find(anchor)
		if idx > 0:
			main.work_order.remove_at(idx)
			main.work_order.insert(0, anchor)
	else:
		main.work_order.insert(0, anchor)
	if main.work_paused.has(anchor):
		main.work_paused.erase(anchor)
	if active != _NO_ACTIVE_WORK and active != anchor:
		# Store the promoting anchor as the auto-resume trigger.
		main.work_paused[active] = anchor
	queue_redraw()
	return true


## Converts a paused deconstruct entry at `anchor` back into a partial
## build at the same visible progress. Resources already refunded stay
## refunded — the player has to pay them again to finish the build, but
## the block isn't destroyed or re-queued from scratch.
func _reverse_decon_to_build(anchor: Vector2i) -> bool:
	if not ("building_deconstruct_progress" in main) or not main.building_deconstruct_progress.has(anchor):
		return false
	var entry: Dictionary = main.building_deconstruct_progress[anchor]
	var block_id: StringName = entry["block_id"]
	var data = Registry.get_block(block_id)
	if data == null:
		return false

	var d_pct: float = clampf(entry["progress"] / entry["build_time"], 0.0, 1.0)
	var max_build_pct: float = float(entry.get("max_build_pct", 1.0))
	var current_build_pct: float = clampf(max_build_pct * (1.0 - d_pct), 0.0, 1.0)

	var full_time: float = data.build_time if data.build_time > 0 else 1.0
	var new_progress: float = current_build_pct * full_time

	var new_consumed := {}
	for item_id in data.build_cost:
		var rk: StringName = main._resolve_resource_key(str(item_id))
		new_consumed[rk] = int(floor(float(data.build_cost[item_id]) * current_build_pct))

	main.building_deconstruct_progress.erase(anchor)
	if "building_resources_refunded" in main:
		main.building_resources_refunded.erase(anchor)

	main.building_build_progress[anchor] = new_progress
	if "building_resources_consumed" in main:
		main.building_resources_consumed[anchor] = new_consumed

	if not main.work_order.has(anchor):
		main.work_order.insert(0, anchor)
	if "work_paused" in main and main.work_paused.has(anchor):
		main.work_paused.erase(anchor)

	# Rebuilding flips the power network state back; keep it in sync.
	var ps := _power_sys_ref()
	if ps and "_networks_dirty" in ps:
		ps._networks_dirty = true

	return true


## True when the player is currently piloting a unit / turret / crane that
## isn't classified as a BUILDER. Used to gate drone-driven build and
## deconstruct so manual control doesn't accidentally trigger them. A
## controlled BUILDER unit is allowed to build/deconstruct, anticipating
## future builder-unit gameplay.
func _is_controlling_non_builder() -> bool:
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if unit_mgr == null or unit_mgr.controlled_entity == null:
		return false
	# Turret / crane control always blocks; only direct-piloted units
	# could potentially be builders.
	if unit_mgr.controlled_type != "unit":
		return true
	var u = unit_mgr.controlled_entity
	if u == null or not is_instance_valid(u):
		return false
	if u.get("data") == null:
		return true
	return u.data.category != UnitData.UnitCategory.BUILDER


func _unhandled_input(event: InputEvent) -> void:
	if main.has_method("is_ui_blocking") and main.is_ui_blocking():
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if _handle_crane_link_click(event):
					get_viewport().set_input_as_handled()
					return
				if main.selected_building == &"":
					# World menu is open — check for cell click or outside click
					if _world_menu_open:
						var mouse_world = get_global_mouse_position()
						var hit := _world_menu_hit_test(mouse_world)
						if hit >= 0:
							_apply_world_menu_selection(hit)
						elif _storage_panel_open:
							# Clicking on the secondary resource panel
							# withdraws into the drone (same behaviour as
							# the standalone storage popup), without
							# closing the UI menu beside it.
							var shit := _storage_panel_hit_test(mouse_world)
							if shit >= 0:
								var sid: StringName = StringName(_storage_panel_items[shit].get("id", &""))
								if sid != &"":
									_withdraw_block_to_drone(_storage_panel_pos, sid)
							else:
								_close_world_menu()
						else:
							_close_world_menu()
						get_viewport().set_input_as_handled()
						return
					# No building selected — first check for work-queue interactions
					# (pause/resume/promote), then fall through to block menus.
					var mouse_world = get_global_mouse_position()
					var click_pos = main.world_to_grid(mouse_world)
					if _handle_work_click(click_pos):
						get_viewport().set_input_as_handled()
						return
					if main.placed_buildings.has(click_pos):
						var click_block_id = main.placed_buildings[click_pos]
						var click_data = Registry.get_block(click_block_id)
						var click_anchor: Vector2i = main.building_origins.get(click_pos, click_pos)
						# In-world UI (sorter / constructor / refab pickers,
						# storage popup) is player-only. Clicking an enemy
						# (FEROX) or DERELICT block in the campaign should
						# not surface their internals — those are opaque.
						# The map editor uses its own click handler, so this
						# guard only affects in-game clicks.
						var click_faction: int = main.get_building_faction(click_anchor) if main.has_method("get_building_faction") else FACTION_LUMINA
						if click_faction == FACTION_LUMINA and click_data:
							# Mindustry-style ad-hoc linking. The same click
							# also opens any in-world UI the block has — a
							# linkable storage block (e.g. an MD with a
							# stored payload) gets BOTH the link selection
							# AND its resource popup on a single click.
							var is_linkable: bool = click_data.tags.has("linkable")
							var link_changed: bool = false
							if is_linkable:
								link_changed = _handle_link_click_on_anchor(click_anchor, click_data)
							else:
								# Clicking a non-linkable block abandons any
								# pending link selection — same as clicking
								# in empty space would feel.
								if link_source != Vector2i(-1, -1):
									link_source = Vector2i(-1, -1)
									_link_just_linked = Vector2i(-1, -1)
									queue_redraw()
							if click_data.tags.has("sorter") or click_data.tags.has("inverted_sorter") or click_data.tags.has("unloader"):
								_open_world_menu("sorter", click_anchor)
								get_viewport().set_input_as_handled()
								return
							elif click_data.tags.has("constructor"):
								_open_world_menu("constructor", click_anchor)
								get_viewport().set_input_as_handled()
								return
							elif click_data.tags.has("refabricator"):
								_open_world_menu("refabricator", click_anchor)
								get_viewport().set_input_as_handled()
								return
							# Fallback: any block with non-empty storage shows a
							# read-only inventory popup (Mindustry-style).
							elif _block_has_any_stored(click_anchor):
								_open_world_menu("storage", click_anchor)
								get_viewport().set_input_as_handled()
								return
							# No UI to open — but if the click changed the
							# link selection, still consume so it doesn't
							# fall through to placement preview.
							if link_changed:
								get_viewport().set_input_as_handled()
								return
				elif main.selected_building != &"" and not event.ctrl_pressed:
					# Build commit is locked while the player is directly
					# controlling something (a unit / turret / crane) — but
					# the drag-place PREVIEW is still allowed so the player
					# can plan a layout while piloting. The release-side
					# gate below cancels the actual placement.
					# Start drag-place: record start, don't place yet
					# (Ctrl+click is reserved for unit control)
					_drag_start = preview_grid_pos
					_drag_placing = true
					_drag_cells.clear()
			else:
				# Release: place all blocks in the preview line
				if _drag_placing:
					# If the player took control of a unit / turret / crane
					# mid-drag, cancel the placement on release rather than
					# committing it. Mirrors the press-side gate so a drag
					# started before the gate flipped doesn't sneak through.
					if _is_controlling_non_builder():
						_drag_placing = false
						_drag_cells.clear()
						return
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
							# _can_place_ignoring_range allows empty cells,
							# same-block re-placements, AND swap-compatible
							# cells (belt → junction, conduit → bridge, etc.)
							# via _can_place_terrain, so paused drag-place
							# now queues swaps the same way the unpaused
							# path does.
							if _can_place_ignoring_range(cell, cell_block, cell_rot) and not queued_positions.has(cell):
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
						# Restore the selected block, but carry the drag's
						# exit direction into placement_rotation so the next
						# click continues that orientation. Gated on the
						# drag actually moving and the block being
						# directional — otherwise fall back to old rotation.
						main.selected_building = old_building
						var sticky_rot: int = old_rot
						if _drag_cells.size() > 1 and _is_directional(old_building):
							# Use the last cell's computed rotation as the
							# authoritative drag-direction for future clicks.
							var last_cell: Vector2i = _drag_cells[_drag_cells.size() - 1]
							sticky_rot = _pathfind_rotations.get(last_cell, old_rot)
						main.placement_rotation = sticky_rot

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
			# Right-click while in crane link mode deletes the diamond under
			# the cursor (and is consumed so it doesn't fall through to
			# demolish).
			if event.pressed and _crane_link_anchor != Vector2i(-1, -1):
				if _handle_crane_link_right_click():
					get_viewport().set_input_as_handled()
					return
			# Skip right-click entirely when the player is in unit mode
			# with units selected (unit mode owns right-click for commands).
			# Outside of unit mode, right-click goes to demolish even if
			# units are still selected in the background.
			var unit_mgr = get_node_or_null("/root/Main/UnitManager")
			if unit_mgr and unit_mgr.unit_mode_active and unit_mgr.selected_units.size() > 0:
				return
			# Same gate as left-click placement: deconstruct via the drone
			# is unavailable while the player is piloting a non-builder
			# unit / turret / crane. Clear any in-flight drag state so a
			# drag started before the gate flipped doesn't get committed
			# the next frame the player releases control. Right-click on
			# an empty cell is still allowed to deselect the current
			# building so the player can drop the placement preview
			# without releasing control.
			if _is_controlling_non_builder():
				_demolish_dragging = false
				if event.pressed and main.selected_building != &"":
					var rmb_world: Vector2 = get_global_mouse_position()
					var rmb_grid: Vector2i = main.world_to_grid(rmb_world)
					if not main.placed_buildings.has(rmb_grid):
						main.select_building(&"")
						_drag_placing = false
						_drag_cells.clear()
						queue_redraw()
				return
			if event.pressed:
				# Two-stage right-click semantics: with a block selected
				# for placement, RMB clears the selection (drops the
				# preview) but does NOT demolish on the same press. The
				# next RMB — now with no selection — falls through to
				# the demolish path below as normal.
				if main.selected_building != &"":
					main.select_building(&"")
					_drag_placing = false
					_drag_cells.clear()
					queue_redraw()
					return
				_drag_placing = false
				_drag_cells.clear()
				# RMB also clears any pending link selection (same as a
				# non-linkable click would). Then falls through to the
				# normal demolish-drag start.
				if link_source != Vector2i(-1, -1):
					link_source = Vector2i(-1, -1)
					_link_just_linked = Vector2i(-1, -1)
					queue_redraw()
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
								# LUMINA blocks: standard deconstruct path.
								# DERELICT blocks: also deconstructable so the
								# player can clean up an old enemy base before
								# bothering to repair it. FEROX (live enemy)
								# stays off-limits — units have to take those
								# down. Cores never deconstruct.
								var can_decon: bool = (click_faction == FACTION_LUMINA \
									or click_faction == FACTION_DERELICT) \
									and (click_data == null or not click_data.tags.has("core"))
								if can_decon:
									var click_anchor: Vector2i = main.building_origins.get(_demolish_start, _demolish_start)
									if main.has_method("start_deconstruct"):
										main.start_deconstruct(click_anchor)
							else:
								main.select_building(&"")
					else:
						# Rect-demolish queues deconstructions for every
						# Lumina building in the drag box. Safe to run
						# while paused — start_deconstruct just registers
						# the work entry; the drone won't actually pull
						# them apart until the world resumes.
						_demolish_rect(_demolish_start, _demolish_end)
					queue_redraw()


## Handles a left-click while in linking mode.
## Mindustry-style ad-hoc link click: called inline from the regular
## block-click flow (NOT a separate mode). Toggles / chains the link
## source on each click of a `linkable` block. Returns true iff a link
## was created or the selection changed (caller uses this to decide
## whether to consume the click).
func _handle_link_click_on_anchor(anchor: Vector2i, data: BlockData) -> bool:
	if data == null or not data.tags.has("linkable"):
		return false

	# Click on the current source — deselect.
	if anchor == link_source:
		link_source = Vector2i(-1, -1)
		_link_just_linked = Vector2i(-1, -1)
		queue_redraw()
		return true

	# Nothing selected yet — make this the source.
	if link_source == Vector2i(-1, -1):
		link_source = anchor
		_link_just_linked = Vector2i(-1, -1)
		queue_redraw()
		return true

	# Source already set: validate compatibility, then link.
	var source_id: StringName = main.placed_buildings.get(link_source, &"")
	var source_data: BlockData = Registry.get_block(source_id)
	if source_data == null:
		# Source vanished (e.g. demolished mid-flow). Treat this click as
		# the new source.
		link_source = anchor
		_link_just_linked = Vector2i(-1, -1)
		queue_redraw()
		return true

	var source_is_bridge: bool = source_data.tags.has("bridge")
	var target_is_bridge: bool = data.tags.has("bridge")
	if source_is_bridge != target_is_bridge:
		# Bridge ↔ bridge only (and non-bridge ↔ non-bridge). Don't
		# silently fail — make the clicked block the new source so the
		# player can keep going.
		link_source = anchor
		_link_just_linked = Vector2i(-1, -1)
		queue_redraw()
		return true

	# Bridge ↔ bridge AND mass-driver ↔ mass-driver pairs share the
	# `linkable` tag, but cross-type pairs (bridge ↔ mass driver) are
	# meaningless. Block them.
	var source_is_md: bool = source_data.tags.has("mass_driver")
	var target_is_md: bool = data.tags.has("mass_driver")
	if source_is_md != target_is_md:
		link_source = anchor
		_link_just_linked = Vector2i(-1, -1)
		queue_redraw()
		return true

	# Range gate: linkable blocks with a non-zero `link_range` only
	# accept partners within that euclidean tile distance (anchor to
	# anchor). Out-of-range clicks reset the source rather than silently
	# linking nothing.
	var max_range: float = maxf(source_data.link_range, data.link_range)
	if max_range > 0.0:
		var dx: float = float(anchor.x - link_source.x)
		var dy: float = float(anchor.y - link_source.y)
		if sqrt(dx * dx + dy * dy) > max_range:
			link_source = anchor
			_link_just_linked = Vector2i(-1, -1)
			queue_redraw()
			return true

	var power_sys = get_node_or_null("/root/Main/PowerSystem")
	if power_sys:
		# 1:1 — drop any existing partner on either endpoint first.
		var existing = power_sys.get_linked_partner(link_source)
		if existing != null:
			power_sys.unlink_blocks(link_source, existing)
		existing = power_sys.get_linked_partner(anchor)
		if existing != null:
			power_sys.unlink_blocks(anchor, existing)
		power_sys.link_blocks(link_source, anchor)

	# Link complete — clear the selection. The just-clicked block does
	# NOT become the new source (so its UI / partner highlight don't pop
	# up). Player can click either endpoint later to start a new link.
	link_source = Vector2i(-1, -1)
	_link_just_linked = Vector2i(-1, -1)
	queue_redraw()
	return true


## Returns true if the given block is a valid crane-link target (block-kind):
## payload-handling blocks the autonomous crane AI knows how to interact with.
func _is_crane_link_block(data: BlockData) -> bool:
	if data == null:
		return false
	return data.tags.has("crane") \
		or data.tags.has("mass_driver") \
		or data.tags.has("payload") \
		or data.tags.has("freight") \
		or data.tags.has("constructor") \
		or data.tags.has("refabricator")


## Returns the world-space rectangle for a 3x3-tile diamond centered on `pos`
## (ground-kind) or covering the block footprint (block-kind).
func _crane_diamond_world_pos(spec: Dictionary) -> Vector2:
	var gs: float = main.GRID_SIZE
	var p: Vector2i = spec.get("pos", Vector2i.ZERO)
	if spec.get("kind", "") == "block":
		var data = Registry.get_block(main.placed_buildings.get(p, &""))
		if data:
			return main.grid_to_world(p) + Vector2(data.grid_size.x * gs / 2.0, data.grid_size.y * gs / 2.0)
	# Ground: clicked tile is the center of the diamond
	return main.grid_to_world(p) + Vector2(gs / 2.0, gs / 2.0)


## Hit-test against an existing crane-link entry. Returns
## { "kind": "input"|"output", "index": int } or empty dict if no hit.
## A diamond covers ~3 tiles in radius for ground / block-anchored entries.
func _crane_link_hit_at(world_pos: Vector2) -> Dictionary:
	if _crane_link_anchor == Vector2i(-1, -1):
		return {}
	if not crane_links.has(_crane_link_anchor):
		return {}
	var gs: float = main.GRID_SIZE
	var radius: float = gs * 1.5  # 3-tile diamond → half-width = 1.5 tiles
	var entry: Dictionary = crane_links[_crane_link_anchor]
	var inputs: Array = entry.get("inputs", [])
	for i in range(inputs.size()):
		var c: Vector2 = _crane_diamond_world_pos(inputs[i])
		var d: Vector2 = world_pos - c
		if absf(d.x) + absf(d.y) <= radius:
			return {"kind": "input", "index": i}
	var outputs: Array = entry.get("outputs", [])
	for i in range(outputs.size()):
		var c: Vector2 = _crane_diamond_world_pos(outputs[i])
		var d: Vector2 = world_pos - c
		if absf(d.x) + absf(d.y) <= radius:
			return {"kind": "output", "index": i}
	return {}


## Centralized left-click handler for crane-link mode. Returns true iff the
## click was consumed (caller should set_input_as_handled).
func _handle_crane_link_click(event: InputEventMouseButton) -> bool:
	var mouse_world := get_global_mouse_position()

	# 1) Filter menu open: hit-test it, otherwise close on outside click.
	if _crane_filter_menu_open:
		var hit := _crane_filter_menu_hit_test(mouse_world)
		if hit >= 0:
			_apply_crane_filter_selection(hit)
		else:
			_close_crane_filter_menu()
		return true

	# 2) In link mode: handle add / shift+filter / toggle off.
	if _crane_link_anchor != Vector2i(-1, -1):
		# Don't intercept Ctrl+click — that's reserved for unit/turret/crane
		# direct-control. Let it fall through (control will exit link mode
		# implicitly the next time the player Esc's or clicks).
		if event.ctrl_pressed:
			return false

		var click_pos: Vector2i = main.world_to_grid(mouse_world)

		# Shift+click on existing diamond: open filter menu.
		if event.shift_pressed:
			var hit_existing: Dictionary = _crane_link_hit_at(mouse_world)
			if not hit_existing.is_empty():
				_open_crane_filter_menu(hit_existing.get("kind", "input"), int(hit_existing.get("index", 0)))
				return true
			# Shift+click empty space — ignore (don't add).
			return true

		# Click on the source crane itself: exit link mode.
		var src_anchor: Vector2i = main.building_origins.get(click_pos, click_pos)
		if main.placed_buildings.has(click_pos):
			var src_data = Registry.get_block(main.placed_buildings[click_pos])
			if src_data and src_data.tags.has("crane") and src_anchor == _crane_link_anchor:
				_crane_link_anchor = Vector2i(-1, -1)
				_crane_link_next_kind = "input"
				queue_redraw()
				return true

		# Left-click on existing diamond (no shift): cycle input ↔ output.
		# (Right-click deletes; shift+click opens the filter menu.)
		var hit_existing2: Dictionary = _crane_link_hit_at(mouse_world)
		if not hit_existing2.is_empty():
			var k: String = hit_existing2.get("kind", "input")
			var idx: int = int(hit_existing2.get("index", 0))
			var entry: Dictionary = crane_links.get(_crane_link_anchor, {})
			var src_arr: Array = entry.get(k + "s", [])
			if idx >= 0 and idx < src_arr.size():
				var spec: Dictionary = src_arr[idx]
				src_arr.remove_at(idx)
				var other_key: String = "output" if k == "input" else "input"
				(entry[other_key + "s"] as Array).append(spec)
				# If the filter menu was tracking this entry, close it (the
				# index is stale now).
				if _crane_filter_menu_open and _crane_filter_menu_anchor == _crane_link_anchor:
					_close_crane_filter_menu()
			queue_redraw()
			return true

		# Otherwise, add a new entry (alternating input → output).
		var spec := {}
		if main.placed_buildings.has(click_pos):
			var anchor: Vector2i = main.building_origins.get(click_pos, click_pos)
			var bdata = Registry.get_block(main.placed_buildings[anchor])
			if _is_crane_link_block(bdata):
				spec = {"kind": "block", "pos": anchor, "filter": []}
			else:
				# Clicked a non-payload block — ignore (don't add anything).
				return true
		else:
			spec = {"kind": "ground", "pos": click_pos, "filter": []}

		if not crane_links.has(_crane_link_anchor):
			crane_links[_crane_link_anchor] = {"inputs": [], "outputs": []}
		var entry2: Dictionary = crane_links[_crane_link_anchor]
		# Every new placement is an INPUT — the player toggles to output
		# by left-clicking the diamond afterwards. Avoids the input/
		# output alternation getting out of sync with what the player
		# expects when they drop multiple diamonds in a row.
		(entry2["inputs"] as Array).append(spec)
		queue_redraw()
		return true

	# 3) Not in link mode — clicking a LUMINA crane enters link mode for it.
	if event.ctrl_pressed:
		return false  # Ctrl+click = direct control, handled by UnitManager
	if main.selected_building != &"":
		return false  # Don't steal placement clicks
	var click_pos2: Vector2i = main.world_to_grid(mouse_world)
	if main.placed_buildings.has(click_pos2):
		var bdata2 = Registry.get_block(main.placed_buildings[click_pos2])
		if bdata2 and bdata2.tags.has("crane"):
			var anchor2: Vector2i = main.building_origins.get(click_pos2, click_pos2)
			var faction: int = main.get_building_faction(anchor2) if main.has_method("get_building_faction") else FACTION_LUMINA
			if faction == FACTION_LUMINA:
				# Crane is mid-build, mid-deconstruct, or in the work queue:
				# defer to the work-queue click handler (pause / promote /
				# reverse) instead of entering link mode.
				var has_build: bool = "building_build_progress" in main and main.building_build_progress.has(anchor2)
				var has_decon: bool = "building_deconstruct_progress" in main and main.building_deconstruct_progress.has(anchor2)
				var in_queue: bool = "work_order" in main and main.work_order.has(anchor2)
				if has_build or has_decon or in_queue:
					return false
				_crane_link_anchor = anchor2
				_crane_link_next_kind = "input"
				if not crane_links.has(anchor2):
					crane_links[anchor2] = {"inputs": [], "outputs": []}
				queue_redraw()
				return true

	return false


## Right-click while in link mode: delete the diamond under the cursor.
## Returns true iff a diamond was deleted (caller consumes the click).
func _handle_crane_link_right_click() -> bool:
	if _crane_link_anchor == Vector2i(-1, -1):
		return false
	var hit: Dictionary = _crane_link_hit_at(get_global_mouse_position())
	if hit.is_empty():
		return false
	var k: String = hit.get("kind", "input")
	var idx: int = int(hit.get("index", 0))
	var entry: Dictionary = crane_links.get(_crane_link_anchor, {})
	var arr: Array = entry.get(k + "s", [])
	if idx >= 0 and idx < arr.size():
		arr.remove_at(idx)
	# If we deleted the entry whose filter menu is open, close it.
	if _crane_filter_menu_open and _crane_filter_menu_kind == k and _crane_filter_menu_index == idx:
		_close_crane_filter_menu()
	queue_redraw()
	return true


## Opens the in-world filter menu for an existing crane link entry.
func _open_crane_filter_menu(kind: String, index: int) -> void:
	_crane_filter_menu_open = true
	_crane_filter_menu_anchor = _crane_link_anchor
	_crane_filter_menu_kind = kind
	_crane_filter_menu_index = index
	_crane_filter_menu_hovered = -1
	_crane_filter_menu_items.clear()

	var entry: Dictionary = crane_links.get(_crane_link_anchor, {})
	var arr: Array = entry.get(kind + "s", [])
	if index < 0 or index >= arr.size():
		_close_crane_filter_menu()
		return
	var spec: Dictionary = arr[index]
	_crane_filter_menu_world_pos = _crane_diamond_world_pos(spec)

	# Populate items: unlocked units always, plus unlocked ≥3x3 blocks if
	# the spec is anchored on a payload block (block-kind). Items without a
	# tech-tree node are treated as always-unlocked (mirrors the build menu's
	# `TechTree.nodes.has(id) and not is_researched(id)` gate).
	var include_blocks: bool = spec.get("kind", "ground") == "block"

	for u in Registry.units_list:
		if u == null:
			continue
		if TechTree.nodes.has(u.id) and not TechTree.is_researched(u.id):
			continue
		_crane_filter_menu_items.append({"id": u.id, "icon": u.icon, "name": u.display_name})

	if include_blocks:
		for b in Registry.blocks_list:
			if b == null:
				continue
			if b.grid_size.x < 3 or b.grid_size.y < 3:
				continue
			if TechTree.nodes.has(b.id) and not TechTree.is_researched(b.id):
				continue
			_crane_filter_menu_items.append({"id": b.id, "icon": b.icon, "name": b.display_name})

	queue_redraw()


func _close_crane_filter_menu() -> void:
	_crane_filter_menu_open = false
	_crane_filter_menu_anchor = Vector2i(-1, -1)
	_crane_filter_menu_index = -1
	_crane_filter_menu_items.clear()
	_crane_filter_menu_hovered = -1
	queue_redraw()


## Hit-test the filter menu grid; returns clicked item index or -1.
func _crane_filter_menu_hit_test(world_pos: Vector2) -> int:
	if not _crane_filter_menu_open or _crane_filter_menu_items.is_empty():
		return -1
	var cell: float = _crane_filter_menu_cell
	var cols: int = mini(_crane_filter_menu_columns, _crane_filter_menu_items.size())
	var rows: int = ceili(float(_crane_filter_menu_items.size()) / float(cols))
	var grid_w: float = cell * cols
	var grid_h: float = cell * rows
	var origin: Vector2 = _crane_filter_menu_world_pos + Vector2(-grid_w / 2.0, main.GRID_SIZE * 1.7)
	for i in range(_crane_filter_menu_items.size()):
		var col: int = i % cols
		var row: int = i / cols
		var r := Rect2(origin + Vector2(col * cell, row * cell), Vector2(cell, cell))
		if r.has_point(world_pos):
			return i
	return -1


## Toggles the clicked item in the link's filter list.
func _apply_crane_filter_selection(idx: int) -> void:
	if idx < 0 or idx >= _crane_filter_menu_items.size():
		return
	if _crane_filter_menu_anchor == Vector2i(-1, -1):
		return
	var entry: Dictionary = crane_links.get(_crane_filter_menu_anchor, {})
	var arr: Array = entry.get(_crane_filter_menu_kind + "s", [])
	if _crane_filter_menu_index < 0 or _crane_filter_menu_index >= arr.size():
		return
	var spec: Dictionary = arr[_crane_filter_menu_index]
	var item_id: StringName = _crane_filter_menu_items[idx].get("id", &"")
	var filter: Array = spec.get("filter", [])
	if filter.has(item_id):
		filter.erase(item_id)
	else:
		filter.append(item_id)
	spec["filter"] = filter
	queue_redraw()


## Opens the in-world selection menu for a sorter or constructor block.
func _open_world_menu(type: String, grid_pos: Vector2i) -> void:
	_world_menu_type = type
	_world_menu_pos = grid_pos
	_world_menu_items.clear()
	_world_menu_hovered = -1

	if type == "storage":
		# Read-only inventory display. Items come from any of the places a
		# block can stash things: LogisticsSystem.block_storage, the factory
		# input/output buffers, and the refabricator's loose buffers. They're
		# merged here so the popup shows everything the block currently
		# holds, regardless of which subsystem owns the slot.
		var merged: Dictionary = _collect_block_stored_items(grid_pos)
		for item_id in merged:
			var count: int = int(merged[item_id])
			if count <= 0:
				continue
			var it = Registry.get_item(item_id)
			var disp_name: String = it.display_name if it else String(item_id)
			var it_icon: Texture2D = it.icon if it else null
			_world_menu_items.append({
				"id": item_id,
				"icon": it_icon,
				"name": disp_name,
				"count": count,
			})
	elif type == "sorter":
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
		# In the editor there is no `require_research` on Main — show all
		# blocks regardless so a sector author can pick anything. In-game,
		# only list blocks the player has actually researched (TechTree is
		# an autoload — a `get_node_or_null("/root/Main/TechTree")` lookup
		# silently returned null and skipped the gate, which is why every
		# 3×3 block was showing up).
		var gate_on_research: bool = "require_research" in main and main.require_research
		for block in Registry.blocks_list:
			if block.tags.has("core"):
				continue
			if block.grid_size.x > max_ps or block.grid_size.y > max_ps:
				continue
			if gate_on_research and not TechTree.is_researched(block.id):
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
	elif type == "refabricator":
		# First entry clears the selection (refab goes dormant).
		_world_menu_items.append({"id": &"", "icon": null, "name": "Clear"})
		# Collect only *tier-2* units — units whose tech-tree parent is
		# itself a unit AND that parent has no unit-typed parents (i.e.
		# the parent is tier-1). Tier-3+ units are upgrades for higher-
		# tier refabricators and shouldn't clutter this menu.
		# Unresearched units stay hidden regardless of the require_research
		# placement toggle (that toggle governs block placement, not
		# recipe discovery). TechTree.unlock_all → is_researched returns
		# true, so sandbox mode still lists everything.
		var is_unit_node := func(nid: StringName) -> bool:
			return Registry.get_unit(nid) != null
		var is_tier1_unit := func(nid: StringName) -> bool:
			if not is_unit_node.call(nid):
				return false
			var pts: Array = TechTree.nodes.get(nid, {}).get("parents", [])
			for pid in pts:
				if is_unit_node.call(pid):
					return false
			return true
		var seen := {}
		for node_id in TechTree.nodes:
			var unit_res = Registry.get_unit(node_id)
			if unit_res == null:
				continue
			var parents: Array = TechTree.nodes[node_id].get("parents", [])
			var has_t1_unit_parent := false
			for parent_id in parents:
				if is_tier1_unit.call(parent_id):
					has_t1_unit_parent = true
					break
			if not has_t1_unit_parent:
				continue
			# Editor mode (no LogisticsSystem running) lists every tier-2
			# unit unconditionally so authors can pick pre-researched
			# recipes into sector saves.
			if _logistics != null and not TechTree.is_researched(node_id):
				continue
			if seen.has(node_id):
				continue
			seen[node_id] = true
			_world_menu_items.append({
				"id": node_id,
				"icon": unit_res.icon,
				"name": unit_res.display_name,
			})

	_world_menu_open = true
	# Whenever a UI-style menu (sorter / constructor / refabricator /
	# archive) opens for a block that also has stored items, open the
	# secondary resource panel beside it. The standalone "storage" popup
	# already shows that data itself, so don't double-up.
	if type != "storage":
		_open_storage_panel(grid_pos)
	else:
		_close_storage_panel()
	queue_redraw()
	# In the map editor BuildingSystem._process is disabled, so the
	# per-frame `_popup_overlay.queue_redraw()` chain at the end of
	# `_draw` doesn't run reliably between user actions. Kick the popup
	# overlay directly so the menu paints the moment it opens.
	if _popup_overlay:
		_popup_overlay.queue_redraw()


## Opens the secondary resource panel for a block. Snapshots its current
## stored items; _draw_storage_panel re-pulls fresh counts each frame so
## the display animates as the block fills/empties.
func _open_storage_panel(grid_pos: Vector2i) -> void:
	_storage_panel_items.clear()
	_storage_panel_hovered = -1
	var merged: Dictionary = _collect_block_stored_items(grid_pos)
	for item_id in merged:
		var count: int = int(merged[item_id])
		if count <= 0:
			continue
		var it = Registry.get_item(item_id)
		_storage_panel_items.append({
			"id": item_id,
			"icon": it.icon if it else null,
			"name": it.display_name if it else String(item_id),
			"count": count,
		})
	if _storage_panel_items.is_empty():
		_storage_panel_open = false
		return
	_storage_panel_pos = grid_pos
	_storage_panel_open = true


func _close_storage_panel() -> void:
	_storage_panel_open = false
	_storage_panel_hovered = -1
	_storage_panel_items.clear()


## Closes the in-world menu.
func _close_world_menu() -> void:
	_world_menu_open = false
	_world_menu_hovered = -1
	_close_storage_panel()
	queue_redraw()
	# Mirrors `_open_world_menu` — needed for the editor where the
	# popup-overlay redraw chain at the end of `_draw` doesn't run
	# every frame.
	if _popup_overlay:
		_popup_overlay.queue_redraw()


## Applies the selection from the world menu.
func _apply_world_menu_selection(index: int) -> void:
	if index < 0 or index >= _world_menu_items.size():
		_close_world_menu()
		return

	var selected_id: StringName = _world_menu_items[index]["id"]

	if _world_menu_type == "storage":
		# Click-to-withdraw: move as much of the clicked item as possible
		# (up to the drone's MAX_INVENTORY headroom) from the block into
		# the drone. Leave the popup open so the player can take from
		# another slot or repeat — _draw_world_menu auto-closes it the
		# frame the block ends up empty.
		var item_id: StringName = StringName(_world_menu_items[index].get("id", &""))
		if item_id != &"":
			_withdraw_block_to_drone(_world_menu_pos, item_id)
		return
	if _world_menu_type == "sorter":
		if _logistics:
			_logistics.sorter_filters[_world_menu_pos] = selected_id
		else:
			editor_sorter_filters[_world_menu_pos] = selected_id
	elif _world_menu_type == "constructor":
		if _logistics:
			if _logistics.constructor_state.has(_world_menu_pos):
				_logistics.constructor_state[_world_menu_pos]["selected_block"] = selected_id
				if selected_id != &"":
					_logistics.constructor_state[_world_menu_pos]["phase"] = "collecting"
		else:
			editor_constructor_state[_world_menu_pos] = {"selected_block": selected_id}
	elif _world_menu_type == "archive":
		archive_holdings[_world_menu_pos] = selected_id
	elif _world_menu_type == "refabricator":
		if _logistics:
			if not _logistics.refabricator_state.has(_world_menu_pos):
				_logistics.refabricator_state[_world_menu_pos] = {
					"phase": "idle",
					"in_unit_id": &"",
					"timer": 0.0,
					"out_unit_id": &"",
					"selected_t2": &"",
				}
			var rs: Dictionary = _logistics.refabricator_state[_world_menu_pos]
			# Changing selection while mid-process would be confusing —
			# clear out any work-in-progress so the new recipe starts
			# fresh. Items already in the buffer stay (they transfer to
			# the new recipe if keys overlap, otherwise accumulate).
			rs["selected_t2"] = selected_id
			rs["in_unit_id"] = &""
			rs["out_unit_id"] = &""
			rs["timer"] = 0.0
			rs["phase"] = "idle"
		else:
			editor_refabricator_state[_world_menu_pos] = {"selected_t2": selected_id}

	_close_world_menu()


## Returns the width/height (in that order) of a single cell for the
## current menu type. Icon-based menus use the square `_world_menu_cell_size`;
## the archive menu has no item icons, so it drops into a vertical list
## layout with wide cells that can fit each archive's full display name.
func _world_menu_cell_dim() -> Vector2:
	if _world_menu_type == "archive":
		return Vector2(160.0, 26.0) * main.SPRITE_SCALE_FACTOR
	return Vector2(_world_menu_cell_size, _world_menu_cell_size)


## How many columns the current menu type uses. Archive = single column
## list so each row gets the full cell width for its name.
func _world_menu_col_count() -> int:
	if _world_menu_type == "archive":
		return 1
	return _world_menu_columns


## Returns the world-space bounding rect for a resource (storage) panel
## anchored on the tile immediately to the right of the block's top-right
## corner. Used both for the standalone storage popup and the secondary
## resource panel that opens beside a UI menu.
func _get_resource_panel_rect_for(grid_pos: Vector2i, items: Array) -> Rect2:
	if items.is_empty():
		return Rect2()
	var dim: Vector2 = Vector2(_world_menu_cell_size, _world_menu_cell_size)
	var cols: int = mini(_world_menu_columns, items.size())
	var rows: int = ceili(float(items.size()) / float(cols))
	var padding := 6.0
	var menu_w: float = cols * dim.x + padding * 2.0
	var menu_h: float = rows * dim.y + padding * 2.0
	var data = Registry.get_block(main.placed_buildings.get(grid_pos, &""))
	var gs: Vector2i = data.grid_size if data else Vector2i(1, 1)
	# Top-right corner tile is at (grid_pos.x + gs.x - 1, grid_pos.y).
	# One tile to the right of that = (grid_pos.x + gs.x, grid_pos.y).
	var anchor_world: Vector2 = main.grid_to_world(Vector2i(grid_pos.x + gs.x, grid_pos.y))
	return Rect2(anchor_world, Vector2(menu_w, menu_h))


## Returns the world-space bounding rect for the secondary resource panel.
## Anchored at the same tile-right-of-top-right column as the primary
## world menu, but stacked underneath it so the two panels don't overlap.
func _get_storage_panel_rect() -> Rect2:
	if not _storage_panel_open:
		return Rect2()
	var rect := _get_resource_panel_rect_for(_storage_panel_pos, _storage_panel_items)
	if _world_menu_open:
		var top := _get_world_menu_rect()
		if top.size != Vector2.ZERO:
			rect.position.y = top.position.y + top.size.y + 6.0
	return rect


## Returns the world-space bounding rect for the world menu, or Rect2() if closed.
func _get_world_menu_rect() -> Rect2:
	if not _world_menu_open or _world_menu_items.is_empty():
		return Rect2()
	# Storage popup anchors 1 tile right of the block's top-right corner so
	# inventory readouts don't overlap the block they belong to. Other
	# pickers (sorter / constructor / refabricator / archive) keep the
	# original centred-above-the-block layout.
	if _world_menu_type == "storage":
		return _get_resource_panel_rect_for(_world_menu_pos, _world_menu_items)
	var dim: Vector2 = _world_menu_cell_dim()
	var col_max: int = _world_menu_col_count()
	var cols := mini(col_max, _world_menu_items.size())
	var rows := ceili(float(_world_menu_items.size()) / float(cols))
	var padding := 6.0
	var menu_w: float = cols * dim.x + padding * 2.0
	var menu_h: float = rows * dim.y + padding * 2.0
	var block_id = main.placed_buildings.get(_world_menu_pos, &"")
	var data = Registry.get_block(block_id)
	var gs := Vector2i(1, 1)
	if data:
		gs = data.grid_size
	var block_world: Vector2 = main.grid_to_world(_world_menu_pos)
	var block_center_x: float = block_world.x + float(gs.x) * main.GRID_SIZE * 0.5
	var block_top_y: float = block_world.y - 8.0
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
	var dim: Vector2 = _world_menu_cell_dim()
	var col := int(local_x / dim.x)
	var row := int(local_y / dim.y)
	var cols := mini(_world_menu_col_count(), _world_menu_items.size())
	if col < 0 or col >= cols:
		return -1
	var idx := row * cols + col
	if idx < 0 or idx >= _world_menu_items.size():
		return -1
	return idx


## Returns the storage-panel item index under the given world position, or -1.
func _storage_panel_hit_test(world_pos: Vector2) -> int:
	if not _storage_panel_open:
		return -1
	var rect := _get_storage_panel_rect()
	if not rect.has_point(world_pos):
		return -1
	var padding := 6.0
	var local_x: float = world_pos.x - rect.position.x - padding
	var local_y: float = world_pos.y - rect.position.y - padding
	if local_x < 0.0 or local_y < 0.0:
		return -1
	var dim: float = _world_menu_cell_size
	var col := int(local_x / dim)
	var row := int(local_y / dim)
	var cols: int = mini(_world_menu_columns, _storage_panel_items.size())
	if col < 0 or col >= cols:
		return -1
	var idx := row * cols + col
	if idx < 0 or idx >= _storage_panel_items.size():
		return -1
	return idx


## Draws the secondary resource (storage) panel — same look-and-feel as the
## standalone storage popup, but anchored 1 tile right of the parent
## block's top-right corner.
func _draw_storage_panel(ci: CanvasItem) -> void:
	if not _storage_panel_open:
		return
	# Re-pull counts each frame so the display animates live.
	_storage_panel_items.clear()
	var merged: Dictionary = _collect_block_stored_items(_storage_panel_pos)
	for item_id in merged:
		var count: int = int(merged[item_id])
		if count <= 0:
			continue
		var it = Registry.get_item(item_id)
		_storage_panel_items.append({
			"id": item_id,
			"icon": it.icon if it else null,
			"name": it.display_name if it else String(item_id),
			"count": count,
		})
	if _storage_panel_items.is_empty():
		_storage_panel_open = false
		return
	var rect := _get_storage_panel_rect()
	var padding := 6.0
	var dim: float = _world_menu_cell_size
	var cols: int = mini(_world_menu_columns, _storage_panel_items.size())

	ci.draw_rect(rect, Color(0.08, 0.08, 0.1, 0.92), true)
	ci.draw_rect(rect, Color(0.4, 0.4, 0.5, 0.8), false, 1.5)

	var origin := rect.position + Vector2(padding, padding)
	for i in _storage_panel_items.size():
		var col := i % cols
		var row := i / cols
		var cell_pos := origin + Vector2(col * dim, row * dim)
		var cell_rect := Rect2(cell_pos, Vector2(dim, dim))
		if i == _storage_panel_hovered:
			ci.draw_rect(cell_rect, Color(0.3, 0.5, 0.8, 0.5), true)
		ci.draw_rect(cell_rect, Color(0.25, 0.25, 0.3, 0.6), false, 1.0)
		var entry: Dictionary = _storage_panel_items[i]
		var icon_tex: Texture2D = entry.get("icon")
		if icon_tex:
			var icon_margin := 4.0
			var icon_rect := Rect2(
				cell_pos + Vector2(icon_margin, icon_margin),
				Vector2(dim - icon_margin * 2.0, dim - icon_margin * 2.0)
			)
			ci.draw_texture_rect(icon_tex, icon_rect, false)
		# Count overlay
		var font_c := ThemeDB.fallback_font
		var font_sz_c := 11
		var count_str: String = str(int(entry.get("count", 0)))
		var tsz: Vector2 = font_c.get_string_size(count_str, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_c)
		var pad := 2.0
		var tx := cell_pos.x + dim - tsz.x - pad
		var ty := cell_pos.y + dim - pad
		ci.draw_string(font_c, Vector2(tx + 1, ty + 1), count_str,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_c, Color(0, 0, 0, 0.85))
		ci.draw_string(font_c, Vector2(tx, ty), count_str,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_c, Color.WHITE)


## Draws the in-world selection menu onto `ci` (the popup overlay).
func _draw_world_menu(ci: CanvasItem) -> void:
	if not _world_menu_open:
		return
	# Storage popup is read-only and lives — rebuild the item list from
	# the current buffers each frame so counts animate in real time
	# instead of snapshotting at open-time. If the block emptied out
	# entirely while the popup was open, close it rather than drawing
	# a zero-item box.
	if _world_menu_type == "storage":
		_world_menu_items.clear()
		var merged: Dictionary = _collect_block_stored_items(_world_menu_pos)
		for item_id in merged:
			var count: int = int(merged[item_id])
			if count <= 0:
				continue
			var it = Registry.get_item(item_id)
			_world_menu_items.append({
				"id": item_id,
				"icon": it.icon if it else null,
				"name": it.display_name if it else String(item_id),
				"count": count,
			})
		if _world_menu_items.is_empty():
			_close_world_menu()
			return
	if _world_menu_items.is_empty():
		return
	var menu_rect := _get_world_menu_rect()
	var padding := 6.0
	var dim: Vector2 = _world_menu_cell_dim()
	var cols := mini(_world_menu_col_count(), _world_menu_items.size())

	# For the archive / sorter / unloader menus, resolve the currently-
	# selected id once so we can highlight its cell. Empty id (= "Clear")
	# matches when nothing is set.
	var selected_archive: StringName = &""
	if _world_menu_type == "archive":
		selected_archive = StringName(archive_holdings.get(_world_menu_pos, &""))
	var selected_sorter: StringName = &""
	if _world_menu_type == "sorter" and _logistics:
		selected_sorter = StringName(_logistics.sorter_filters.get(_world_menu_pos, &""))

	# Background
	ci.draw_rect(menu_rect, Color(0.08, 0.08, 0.1, 0.92), true)
	ci.draw_rect(menu_rect, Color(0.4, 0.4, 0.5, 0.8), false, 1.5)

	# Draw cells
	var origin := menu_rect.position + Vector2(padding, padding)
	for i in _world_menu_items.size():
		var col := i % cols
		var row := i / cols
		var cell_pos := origin + Vector2(col * dim.x, row * dim.y)
		var cell_rect := Rect2(cell_pos, dim)

		# Hover highlight
		if i == _world_menu_hovered:
			ci.draw_rect(cell_rect, Color(0.3, 0.5, 0.8, 0.5), true)

		# Cell border — thicker/brighter blue when this row is the
		# currently-selected archive / sorter filter so the player can
		# see what's set at a glance. Skip the "Clear" cell at index 0
		# when nothing is selected (avoids the X cell looking active).
		var entry_id: StringName = StringName(_world_menu_items[i].get("id", &""))
		var is_selected: bool = false
		if _world_menu_type == "archive":
			is_selected = entry_id == selected_archive and entry_id != &""
		elif _world_menu_type == "sorter":
			is_selected = entry_id == selected_sorter and entry_id != &""
		if is_selected:
			ci.draw_rect(cell_rect, Color(0.35, 0.65, 1.0, 1.0), false, 2.0)
		else:
			ci.draw_rect(cell_rect, Color(0.25, 0.25, 0.3, 0.6), false, 1.0)

		var entry: Dictionary = _world_menu_items[i]

		# Clear button (first cell in sorter or archive mode)
		if (_world_menu_type == "sorter" or _world_menu_type == "archive") and i == 0:
			# Draw X for clear
			var cx := cell_pos.x + dim.x * 0.5
			var cy := cell_pos.y + dim.y * 0.5
			var hs: float = minf(dim.x, dim.y) * 0.25
			ci.draw_line(Vector2(cx - hs, cy - hs), Vector2(cx + hs, cy + hs), Color(1.0, 0.3, 0.3), 2.0)
			ci.draw_line(Vector2(cx + hs, cy - hs), Vector2(cx - hs, cy + hs), Color(1.0, 0.3, 0.3), 2.0)
			continue

		# Draw icon if available
		var icon_tex: Texture2D = entry.get("icon")
		if icon_tex:
			var icon_margin := 4.0
			var icon_rect := Rect2(
				cell_pos + Vector2(icon_margin, icon_margin),
				Vector2(dim.x - icon_margin * 2.0, dim.y - icon_margin * 2.0)
			)
			ci.draw_texture_rect(icon_tex, icon_rect, false)
		else:
			# Text-label cells (e.g. archive list) fit their full display
			# name into the wider list-mode cell. Square icon-less cells
			# fall back to a 4-char abbreviation as before.
			var font := ThemeDB.fallback_font
			var font_size := 11
			var full_name: String = entry.get("name", "?")
			var side_pad := 6.0
			var avail_w: float = dim.x - side_pad * 2.0
			if _world_menu_type == "archive":
				var text_pos := cell_pos + Vector2(side_pad, dim.y * 0.5 + font_size * 0.35)
				ci.draw_string(font, text_pos, full_name, HORIZONTAL_ALIGNMENT_LEFT, avail_w, font_size, Color.WHITE)
			else:
				var short_name: String = full_name.left(4)
				var text_pos := cell_pos + Vector2(4.0, dim.y * 0.65)
				ci.draw_string(font, text_pos, short_name, HORIZONTAL_ALIGNMENT_LEFT, avail_w, 10, Color.WHITE)

		# Storage popup: overlay an item count in the bottom-right corner.
		if _world_menu_type == "storage" and entry.has("count"):
			var font_c := ThemeDB.fallback_font
			var font_sz_c := 11
			var count_str: String = str(entry["count"])
			var tsz: Vector2 = font_c.get_string_size(count_str, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_c)
			var pad := 2.0
			var tx := cell_pos.x + dim.x - tsz.x - pad
			var ty := cell_pos.y + dim.y - pad
			# Drop-shadow for legibility over any icon colour.
			ci.draw_string(font_c, Vector2(tx + 1, ty + 1), count_str,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_c, Color(0, 0, 0, 0.85))
			ci.draw_string(font_c, Vector2(tx, ty), count_str,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_c, Color.WHITE)


func _draw() -> void:
	# Resolve any still-pending threaded texture loads on the first paint.
	if not _textures_ready:
		_ensure_textures_loaded()
	_draw_placed_buildings()
	_draw_block_hitboxes()
	# `_draw_cranes` now runs on `_crane_overlay` (z_index 4097) so
	# arms / grabbers / held cargo paint above units, turret heads,
	# and bullets. The overlay calls into us with `_crane_draw_canvas`
	# set so every draw call lands on its higher-z surface.
	_draw_crane_link_overlays()
	_draw_hovered_turret_range()
	_draw_archive_scan_overlay()
	_draw_paused_queue()
	_draw_preview()
	_draw_links()
	_draw_demolish_rect()
	_draw_rebuild_mode()
	_draw_schematic_rect()
	_draw_schematic_placement()
	# World menu / storage panel render on the popup overlay so they sit
	# above units and other in-world content.
	if _popup_overlay:
		_popup_overlay.queue_redraw()


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
## rot: 0=right, 1=down, 2=left, 3=up. Directional source textures face
## UP (top of texture = front), so a +90° offset turns them into the
## "rot 0 = right" baseline. Non-directional textures are authored
## upright in source and shouldn't be rotated at all — pass
## `directional = false` so the offset (and `rot`) are skipped, keeping
## the art identical to the source file.
func _draw_block_texture(texture: Texture2D, top_pos: Vector2, w: float, h: float, rot: int = 0, tint: Color = Color.WHITE, directional: bool = true) -> void:
	var angle: float = 0.0
	if directional:
		angle = rot * PI / 2.0 + PI / 2.0
	var center := top_pos + Vector2(w / 2.0, h / 2.0)
	draw_set_transform(center, angle)
	draw_texture_rect(texture, Rect2(Vector2(-w / 2.0, -h / 2.0), Vector2(w, h)), false, tint)
	draw_set_transform(Vector2.ZERO, 0.0)


## Draws the refabricator: base sprite plus per-side "input" overlays that
## light up when a payload conveyor is adjacent on that side of the
## building. Each overlay texture rotates with the base.
func _draw_refabricator(origin: Vector2i, data: BlockData, top_pos: Vector2, w: float, h: float, rot: int) -> void:
	var gsz: Vector2i = data.grid_size
	var back_dir: int = (rot + 2) % 4
	var left_dir: int = (rot + 3) % 4
	var right_dir: int = (rot + 1) % 4
	var back_fed: bool = _side_has_payload_input(origin, gsz, back_dir)
	var left_fed: bool = _side_has_payload_input(origin, gsz, left_dir)
	var right_fed: bool = _side_has_payload_input(origin, gsz, right_dir)
	# Pick ONE active feeding side. A previously-locked side keeps priority
	# as long as it's still feeding (so the first-placed conveyor wins and
	# later additions don't stack on top of it). When no side is locked or
	# the locked side stops feeding, fall back to a stable tiebreak order
	# (back > left > right).
	var active_side := -1  # 0=back, 1=left, 2=right
	var state_ref: Dictionary = {}
	if _logistics and _logistics.refabricator_state.has(origin):
		state_ref = _logistics.refabricator_state[origin]
		var prev: int = int(state_ref.get("active_feed_side", -1))
		if prev == 0 and back_fed:
			active_side = 0
		elif prev == 1 and left_fed:
			active_side = 1
		elif prev == 2 and right_fed:
			active_side = 2
	if active_side == -1:
		if back_fed:
			active_side = 0
		elif left_fed:
			active_side = 1
		elif right_fed:
			active_side = 2
	if not state_ref.is_empty():
		state_ref["active_feed_side"] = active_side

	var base_tex: Texture2D = data.base_sprite
	var overlay_tex: Texture2D = null
	match active_side:
		0:
			if data.base_sprite_back:
				base_tex = data.base_sprite_back
			overlay_tex = data.feed_overlay_back
		1:
			if data.base_sprite_left:
				base_tex = data.base_sprite_left
			overlay_tex = data.feed_overlay_left
		2:
			if data.base_sprite_right:
				base_tex = data.base_sprite_right
			overlay_tex = data.feed_overlay_right
		_:
			# Idle frame: use the back variant as the default look.
			if data.base_sprite_back:
				base_tex = data.base_sprite_back
			overlay_tex = data.feed_overlay_back
	_draw_block_texture(base_tex, top_pos, w, h, rot)
	_draw_refabricator_unit_layer(origin, top_pos, w, h, rot)
	if overlay_tex:
		_draw_block_texture(overlay_tex, top_pos, w, h, rot)


## Draws the unit currently held inside a refabricator — the tier-1 input
## during collecting/processing, or the tier-2 output while it waits to
## eject. Mirrors the visual style of `_draw_fabricator_unit_layer` but
## reads from `refabricator_state` instead of `factory_buffers`.
func _draw_refabricator_unit_layer(origin: Vector2i, top_pos: Vector2, w: float, h: float, rot: int) -> void:
	if _logistics == null or not _logistics.refabricator_state.has(origin):
		return
	var state: Dictionary = _logistics.refabricator_state[origin]
	var phase: String = String(state.get("phase", ""))
	var unit_id: StringName = &""
	match phase:
		"collecting", "processing":
			unit_id = StringName(state.get("in_unit_id", &""))
		"outputting":
			unit_id = StringName(state.get("out_unit_id", &""))
	if unit_id == &"":
		return
	var unit_data = Registry.get_unit(unit_id)
	if unit_data == null:
		return
	var center: Vector2 = top_pos + Vector2(w / 2.0, h / 2.0)
	var dir_vec: Vector2
	match rot:
		0: dir_vec = Vector2(1, 0)
		1: dir_vec = Vector2(0, 1)
		2: dir_vec = Vector2(-1, 0)
		3: dir_vec = Vector2(0, -1)
		_: dir_vec = Vector2(1, 0)
	var base_sz: float = minf(w, h) * 0.5
	var unit_angle: float = rot * PI / 2.0
	var unit_pos: Vector2 = center
	var alpha_mul: float = 1.0
	if phase == "processing":
		var timer: float = float(state.get("timer", 0.0))
		var pt: float = 6.0
		var block = Registry.get_block(main.placed_buildings.get(origin, &""))
		if block != null and block.production_time > 0:
			pt = block.production_time
		var reveal_pct: float = clampf(1.0 - timer / pt, 0.0, 1.0)
		alpha_mul = 0.4 + 0.6 * reveal_pct
	elif phase == "outputting":
		unit_pos = center + dir_vec * (maxf(w, h) * 0.5 - base_sz * 0.25)

	if unit_data.base_sprite != null or unit_data.head_sprite != null:
		if unit_data.base_sprite:
			var bt_size: Vector2 = _fit_texture_size(unit_data.base_sprite, base_sz)
			draw_set_transform(unit_pos, 0.0)
			draw_texture_rect(unit_data.base_sprite, Rect2(-bt_size * 0.5, bt_size), false, Color(1, 1, 1, alpha_mul))
			draw_set_transform(Vector2.ZERO, 0.0)
		if unit_data.head_sprite:
			var h_size: Vector2 = _fit_texture_size(unit_data.head_sprite, base_sz)
			draw_set_transform(unit_pos, unit_angle + PI / 2.0)
			draw_texture_rect(unit_data.head_sprite, Rect2(-h_size * 0.5, h_size), false, Color(1, 1, 1, alpha_mul))
			draw_set_transform(Vector2.ZERO, 0.0)
	elif unit_data.icon != null:
		var i_size: Vector2 = _fit_texture_size(unit_data.icon, base_sz)
		draw_set_transform(unit_pos, unit_angle + PI / 2.0)
		draw_texture_rect(unit_data.icon, Rect2(-i_size * 0.5, i_size), false, Color(1, 1, 1, alpha_mul))
		draw_set_transform(Vector2.ZERO, 0.0)


## Returns true if any cell along the `dir` edge of the footprint at `origin`
## contains a payload/freight conveyor. `dir` uses the building convention:
## 0=east, 1=south, 2=west, 3=north.
## Returns true if the block at `anchor` has any items stashed anywhere
## LogisticsSystem tracks per-block storage (shared storage, factory I/O
## buffers, refabricator holding slots). Fluids are intentionally left
## out — the storage popup is items-only for now.
func _block_has_any_stored(anchor: Vector2i) -> bool:
	var merged: Dictionary = _collect_block_stored_items(anchor)
	for item_id in merged:
		if int(merged[item_id]) > 0:
			return true
	return false


## Merges every item-storage source a block can hold into a single
## `{item_id: count}` dict for the inventory popup. Keeps overlapping
## item_ids on separate sources summed together (e.g. a factory that has
## copper in both its input buffer and its generic storage shows the
## combined total).
func _collect_block_stored_items(anchor: Vector2i) -> Dictionary:
	var merged: Dictionary = {}
	var block_id: StringName = main.placed_buildings.get(anchor, &"")
	var data = Registry.get_block(block_id)

	# Cores: the player resource pool is shared across every Lumina core,
	# so clicking any core shows the entire stockpile (mirrors Mindustry).
	if data and data.tags.has("core") \
			and main.has_method("get_building_faction") \
			and main.get_building_faction(anchor) == FACTION_LUMINA:
		for k in main.resources:
			var c: int = int(main.resources[k])
			if c > 0:
				merged[k] = int(merged.get(k, 0)) + c
		return merged

	# Conveyors: a belt cell holds at most one item, tracked in
	# LogisticsSystem.conveyor_items. Show it as a one-count entry so the
	# player can inspect what's currently riding the belt.
	if _logistics and "conveyor_items" in _logistics \
			and _logistics.conveyor_items.has(anchor):
		var ci: Dictionary = _logistics.conveyor_items[anchor]
		var cid: StringName = StringName(ci.get("item_id", &""))
		if cid != &"":
			merged[cid] = int(merged.get(cid, 0)) + 1

	if _logistics == null:
		return merged
	# Shared block storage (loaders, unloaders, generic storage blocks).
	if "block_storage" in _logistics and _logistics.block_storage.has(anchor):
		var s: Dictionary = _logistics.block_storage[anchor]
		var items: Dictionary = s.get("items", {})
		for k in items:
			merged[k] = int(merged.get(k, 0)) + int(items[k])
	# Factory input + output buffers (furnaces, crushers, fabricators).
	if "factory_buffers" in _logistics and _logistics.factory_buffers.has(anchor):
		var fb: Dictionary = _logistics.factory_buffers[anchor]
		var fin: Dictionary = fb.get("inputs", {})
		for k in fin:
			merged[k] = int(merged.get(k, 0)) + int(fin[k])
		var fout: Dictionary = fb.get("outputs", {})
		for k in fout:
			merged[k] = int(merged.get(k, 0)) + int(fout[k])
	return merged


## Withdraws up to `count` of `item_id` from the block at `anchor`.
## Drains sources in priority order (core pool → factory outputs → factory
## inputs → block storage → conveyor cell) and returns the total amount
## actually taken.
func _withdraw_items_from_block(anchor: Vector2i, item_id: StringName, count: int) -> int:
	if count <= 0:
		return 0
	var remaining: int = count
	var block_id: StringName = main.placed_buildings.get(anchor, &"")
	var data = Registry.get_block(block_id)

	# Core: pull from main.resources (shared player stockpile).
	if data and data.tags.has("core") \
			and main.has_method("get_building_faction") \
			and main.get_building_faction(anchor) == FACTION_LUMINA:
		var have: int = int(main.resources.get(item_id, 0))
		var take: int = mini(have, remaining)
		if take > 0:
			main.resources[item_id] = have - take
			if "resources_changed" in main:
				main.resources_changed.emit(main.resources)
			remaining -= take
		return count - remaining

	if _logistics == null:
		return 0
	# Conveyor cell holds a single unit.
	if "conveyor_items" in _logistics and _logistics.conveyor_items.has(anchor) and remaining > 0:
		var ci: Dictionary = _logistics.conveyor_items[anchor]
		if StringName(ci.get("item_id", &"")) == item_id:
			_logistics.conveyor_items.erase(anchor)
			remaining -= 1
	# Factory output buffers next (already-produced items).
	if "factory_buffers" in _logistics and _logistics.factory_buffers.has(anchor) and remaining > 0:
		var fb: Dictionary = _logistics.factory_buffers[anchor]
		var fout: Dictionary = fb.get("outputs", {})
		if fout.has(item_id):
			var have_o: int = int(fout[item_id])
			var take_o: int = mini(have_o, remaining)
			if take_o > 0:
				fout[item_id] = have_o - take_o
				if int(fout[item_id]) <= 0:
					fout.erase(item_id)
				remaining -= take_o
		var fin: Dictionary = fb.get("inputs", {})
		if remaining > 0 and fin.has(item_id):
			var have_i: int = int(fin[item_id])
			var take_i: int = mini(have_i, remaining)
			if take_i > 0:
				fin[item_id] = have_i - take_i
				if int(fin[item_id]) <= 0:
					fin.erase(item_id)
				remaining -= take_i
	# Shared block storage.
	if "block_storage" in _logistics and _logistics.block_storage.has(anchor) and remaining > 0:
		var s: Dictionary = _logistics.block_storage[anchor]
		var items: Dictionary = s.get("items", {})
		if items.has(item_id):
			var have_s: int = int(items[item_id])
			var take_s: int = mini(have_s, remaining)
			if take_s > 0:
				items[item_id] = have_s - take_s
				if int(items[item_id]) <= 0:
					items.erase(item_id)
				remaining -= take_s
	return count - remaining


## Click-to-withdraw handler: fills the drone's mined_inventory from the
## block, capped by the drone's MAX_INVENTORY.
func _withdraw_block_to_drone(anchor: Vector2i, item_id: StringName) -> int:
	# Locked while paused — pulling items into the drone during a freeze
	# would side-step pause-aware production / consumption ticks. The
	# storage popup itself stays open so the player can read counts.
	if "world_paused" in main and main.world_paused:
		return 0
	# While the player is piloting something, withdrawing into the
	# drone's bag would smuggle resources around the drone's location
	# (the drone isn't where the cursor is). Allow it only when the
	# controlled entity is a unit with its own item storage — those
	# units are stand-ins for the drone in this case.
	var unit_mgr_w = get_node_or_null("/root/Main/UnitManager")
	if unit_mgr_w and unit_mgr_w.controlled_entity != null:
		var ok_storage_unit: bool = false
		if unit_mgr_w.controlled_type == "unit":
			var u = unit_mgr_w.controlled_entity
			if is_instance_valid(u) and u.get("data") != null:
				# A unit "has storage for items" if its UnitData declares any
				# inventory capacity (max_inventory > 0).
				if "max_inventory" in u.data and int(u.data.max_inventory) > 0:
					ok_storage_unit = true
		if not ok_storage_unit:
			return 0
	var drone = get_node_or_null("/root/Main/PlayerDrone")
	if drone == null:
		return 0
	var max_inv: int = int(drone.MAX_INVENTORY) if "MAX_INVENTORY" in drone else 60
	var current_total: int = 0
	if drone.has_method("_get_inventory_total"):
		current_total = drone._get_inventory_total()
	var capacity: int = max_inv - current_total
	if capacity <= 0:
		return 0
	var taken: int = _withdraw_items_from_block(anchor, item_id, capacity)
	if taken > 0 and "mined_inventory" in drone:
		drone.mined_inventory[item_id] = int(drone.mined_inventory.get(item_id, 0)) + taken
	return taken


## Deposits up to `count` of `item_id` into the block at `anchor`. Returns
## the amount actually accepted. Picks the right bucket based on the
## block's role:
##   - storage-tagged blocks fill block_storage up to max_stored_items
##   - factories fill factory_buffers["inputs"] for items in input_items
##     (also capped by max_stored_items when set)
##   - cores drop into main.resources (subject to storage capacity)
## Blocks that don't match any of the above accept nothing.
## Resolves the *effective* input recipe for a block. Unit fabricators
## have empty `input_items` and pull their recipe from the produced
## unit's `build_cost`; refabricators look up `refab_recipes[selected]`
## from the player's currently-selected tier-2 unit. Returns the dict
## with item ids normalised through LogisticsSystem so the keys match
## what the drone is actually carrying.
func _get_effective_input_recipe(anchor: Vector2i, data: BlockData) -> Dictionary:
	if data == null:
		return {}
	var recipe: Dictionary = data.input_items
	if data.produced_unit != &"":
		var unit_res = Registry.get_unit(data.produced_unit)
		if unit_res and not unit_res.build_cost.is_empty():
			recipe = unit_res.build_cost
	if data.tags.has("refabricator") and _logistics and "refabricator_state" in _logistics \
			and _logistics.refabricator_state.has(anchor):
		var rsel: StringName = StringName(_logistics.refabricator_state[anchor].get("selected_t2", &""))
		if rsel != &"" and data.refab_recipes != null and data.refab_recipes.has(rsel):
			var custom = data.refab_recipes[rsel]
			if custom is Dictionary and not custom.is_empty():
				recipe = custom
	if _logistics and _logistics.has_method("_normalize_item_keys"):
		recipe = _logistics._normalize_item_keys(recipe)
	return recipe


func _deposit_items_into_block(anchor: Vector2i, item_id: StringName, count: int) -> int:
	if count <= 0 or _logistics == null:
		return 0
	var block_id: StringName = main.placed_buildings.get(anchor, &"")
	var data = Registry.get_block(block_id)
	if data == null:
		return 0

	# Core deposit: hand off to main.resources (honors can_accept_resource
	# so we don't exceed core storage capacity). Under-construction or
	# being-deconstructed cores reject deposits — silently swallowing
	# items into a non-functional core would surprise the player.
	if data.tags.has("core") \
			and main.has_method("get_building_faction") \
			and main.get_building_faction(anchor) == FACTION_LUMINA \
			and not main.is_building_inactive(anchor):
		# Coal / sand vanish at the core — return `count` to the caller
		# so the deposit reads as fully accepted (deletes the held stack)
		# without inflating the resource pool.
		if main.has_method("is_incinerated_at_core") and main.is_incinerated_at_core(item_id):
			if main.has_signal("item_absorbed_in_core"):
				for _i in range(count):
					main.item_absorbed_in_core.emit(item_id)
			return count
		var accepted_c: int = 0
		for _i in range(count):
			if main.has_method("can_accept_resource") and not main.can_accept_resource(item_id):
				break
			main.resources[item_id] = int(main.resources.get(item_id, 0)) + 1
			accepted_c += 1
		if accepted_c > 0 and "resources_changed" in main:
			main.resources_changed.emit(main.resources)
		return accepted_c

	# Factory input buffer: only accept items the *effective* recipe
	# actually uses (see `_get_effective_input_recipe`).
	var effective_recipe: Dictionary = _get_effective_input_recipe(anchor, data)
	if not effective_recipe.is_empty() and effective_recipe.has(item_id):
		if not _logistics.factory_buffers.has(anchor):
			_logistics.factory_buffers[anchor] = {
				"inputs": {},
				"phase": "collecting",
				"timer": 0.0,
				"pending_outputs": {},
			}
		var fb: Dictionary = _logistics.factory_buffers[anchor]
		if not fb.has("inputs"):
			fb["inputs"] = {}
		var fin: Dictionary = fb["inputs"]
		var have_i: int = int(fin.get(item_id, 0))
		var cap_i: int = data.max_stored_items if data.max_stored_items > 0 else int(effective_recipe[item_id]) * 10
		var space_i: int = maxi(0, cap_i - have_i)
		var take_i: int = mini(space_i, count)
		if take_i > 0:
			fin[item_id] = have_i + take_i
		return take_i

	# Turret: accepts items whose id matches one of its AmmoType entries,
	# filling block_storage up to max_stored_items (default 30).
	if data.is_turret() and not data.ammo_types.is_empty():
		var is_ammo := false
		for ammo in data.ammo_types:
			if ammo is AmmoType and (ammo as AmmoType).item_id == item_id:
				is_ammo = true
				break
		if not is_ammo:
			return 0
		if not _logistics.block_storage.has(anchor):
			_logistics.block_storage[anchor] = {"items": {}, "fluids": {}}
		var ts: Dictionary = _logistics.block_storage[anchor]
		if not ts.has("items"):
			ts["items"] = {}
		var titems: Dictionary = ts["items"]
		var cap_t: int = data.max_stored_items if data.max_stored_items > 0 else 30
		var total_t: int = 0
		for k in titems:
			total_t += int(titems[k])
		var space_t: int = maxi(0, cap_t - total_t)
		var take_t: int = mini(space_t, count)
		if take_t > 0:
			titems[item_id] = int(titems.get(item_id, 0)) + take_t
		return take_t

	# Conveyor: a single empty belt cell takes one unit. Payload/freight
	# conveyors move buildings, not items — skip those.
	if data.is_transport() and not data.transports_fluid \
			and not data.tags.has("payload") and not data.tags.has("freight"):
		if not _logistics.conveyor_items.has(anchor):
			_logistics.conveyor_items[anchor] = {
				"item_id": item_id,
				"progress": 0.0,
				"entry_dir": -1,
			}
			return 1
		return 0

	# Generic storage block.
	if data.tags.has("storage"):
		if not _logistics.block_storage.has(anchor):
			_logistics.block_storage[anchor] = {"items": {}, "fluids": {}}
		var s: Dictionary = _logistics.block_storage[anchor]
		if not s.has("items"):
			s["items"] = {}
		var items: Dictionary = s["items"]
		var cap_s: int = data.max_stored_items if data.max_stored_items > 0 else 0
		if cap_s <= 0:
			return 0
		var total_s: int = 0
		for k in items:
			total_s += int(items[k])
		var space_s: int = maxi(0, cap_s - total_s)
		var take_s: int = mini(space_s, count)
		if take_s > 0:
			items[item_id] = int(items.get(item_id, 0)) + take_s
		return take_s

	return 0


## Returns true when the block at `anchor` is a valid drop target for any
## amount of `item_id` — used by the drone's drag-drop to decide between
## "deposit here" and "drop on terrain" (delete).
func _block_accepts_item(anchor: Vector2i, item_id: StringName) -> bool:
	var block_id: StringName = main.placed_buildings.get(anchor, &"")
	var data = Registry.get_block(block_id)
	if data == null:
		return false
	if data.tags.has("core") \
			and main.has_method("get_building_faction") \
			and main.get_building_faction(anchor) == FACTION_LUMINA:
		return true
	# Consult the effective recipe so unit fabricators (whose `input_items`
	# is empty — the recipe lives on the produced unit's build_cost) and
	# selection-driven refabricators don't get rejected by the drone's
	# drag-drop just because their static `input_items` dict is bare.
	var effective_recipe: Dictionary = _get_effective_input_recipe(anchor, data)
	if not effective_recipe.is_empty() and effective_recipe.has(item_id):
		return true
	if data.tags.has("storage"):
		return true
	# Turret accepts anything listed in its ammo_types.
	if data.is_turret() and not data.ammo_types.is_empty():
		for ammo in data.ammo_types:
			if ammo is AmmoType and (ammo as AmmoType).item_id == item_id:
				return true
	# Item conveyors accept any item when the cell is empty.
	if data.is_transport() and not data.transports_fluid \
			and not data.tags.has("payload") and not data.tags.has("freight"):
		if _logistics and not _logistics.conveyor_items.has(anchor):
			return true
	return false


func _side_has_payload_input(origin: Vector2i, gsz: Vector2i, dir: int) -> bool:
	var cells: Array[Vector2i] = []
	match dir:
		0:
			for y in range(gsz.y):
				cells.append(Vector2i(origin.x + gsz.x, origin.y + y))
		1:
			for x in range(gsz.x):
				cells.append(Vector2i(origin.x + x, origin.y + gsz.y))
		2:
			for y in range(gsz.y):
				cells.append(Vector2i(origin.x - 1, origin.y + y))
		3:
			for x in range(gsz.x):
				cells.append(Vector2i(origin.x + x, origin.y - 1))
	# For a neighbour on the refab's `dir` side to feed INTO the refab,
	# its own output must point back toward the refab. The direction from
	# the neighbour pointing into the refab is (dir + 2) % 4.
	var into_dir: int = (dir + 2) % 4
	for c in cells:
		if not main.placed_buildings.has(c):
			continue
		var nb_anchor: Vector2i = main.building_origins.get(c, c)
		var d = Registry.get_block(main.placed_buildings[nb_anchor])
		if d == null:
			continue
		var nb_rot: int = main.building_rotation.get(nb_anchor, 0)
		# Payload / freight conveyors (directional transports)
		if (d.tags.has("payload") or d.tags.has("freight")) and d.transport_speed > 0:
			if nb_rot == into_dir:
				return true
			continue
		# Unit fabricators / refabricators eject their produced unit out
		# their front edge — count them as feeding when they face the refab.
		if d.tags.has("fabricator") or d.tags.has("refabricator") \
				or (d.produced_unit != &""):
			if nb_rot == into_dir:
				return true
	return false


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


## Draws the block currently being constructed (or deconstructed) between
## the constructor / deconstructor's base and top sprites, with a reveal-
## line animation so the player can see progress at a glance.
##   Constructor:    icon reveals left → right as build_time elapses.
##   Deconstructor:  icon hides   left → right as decon time elapses.
func _draw_constructor_layer(grid_pos: Vector2i, data: BlockData, top_pos: Vector2, width: float, height: float, _rot: int) -> void:
	if _logistics == null:
		return
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var is_constructor: bool = data.tags.has("constructor")
	var is_deconstructor: bool = data.tags.has("deconstructor")
	var target_block: StringName = &""
	var reveal_pct: float = 0.0
	var phase_str: String = ""
	if is_constructor and _logistics.constructor_state.has(anchor):
		var cs: Dictionary = _logistics.constructor_state[anchor]
		phase_str = String(cs.get("phase", ""))
		if phase_str == "building":
			target_block = StringName(cs.get("selected_block", &""))
			var bd_for_time: BlockData = Registry.get_block(target_block) if target_block != &"" else null
			var bt: float = bd_for_time.build_time if bd_for_time and bd_for_time.build_time > 0 else 2.0
			reveal_pct = clampf(1.0 - float(cs.get("timer", bt)) / maxf(bt, 0.0001), 0.0, 1.0)
	elif is_deconstructor and _logistics.deconstructor_state.has(anchor):
		var ds: Dictionary = _logistics.deconstructor_state[anchor]
		phase_str = String(ds.get("phase", ""))
		if phase_str == "deconstructing":
			var pd_var = ds.get("payload")
			if pd_var is Dictionary:
				var pd: Dictionary = pd_var
				if String(pd.get("type", "")) == "building":
					target_block = StringName(pd.get("block_id", ""))
					var bd_for_time2: BlockData = Registry.get_block(target_block) if target_block != &"" else null
					var bt2: float = bd_for_time2.build_time if bd_for_time2 and bd_for_time2.build_time > 0 else 2.0
					reveal_pct = clampf(1.0 - float(ds.get("timer", bt2)) / maxf(bt2, 0.0001), 0.0, 1.0)
	if target_block == &"":
		return
	var bd: BlockData = Registry.get_block(target_block)
	if bd == null or bd.icon == null:
		return
	var center: Vector2 = top_pos + Vector2(width / 2.0, height / 2.0)
	var icon_size: float = minf(width, height) * 0.55
	var icon_sz: Vector2 = _fit_texture_size(bd.icon, icon_size)
	var rect_pos: Vector2 = center - icon_sz * 0.5
	var alpha_mul: float = 0.4 + 0.6 * (reveal_pct if is_constructor else (1.0 - reveal_pct))
	draw_texture_rect(bd.icon, Rect2(rect_pos, icon_sz), false, Color(1, 1, 1, alpha_mul))
	# Reveal-line overlay. For the constructor the dark portion shrinks
	# left → right; for the deconstructor it grows left → right.
	var dark_pct: float = 1.0 - reveal_pct if is_constructor else reveal_pct
	var dark_w: float = icon_sz.x * dark_pct
	if dark_w > 0.0:
		draw_rect(
			Rect2(rect_pos.x + (icon_sz.x - dark_w), rect_pos.y, dark_w, icon_sz.y),
			Color(0, 0, 0, 0.55),
			true
		)
	if reveal_pct > 0.0 and reveal_pct < 1.0:
		var line_x: float = rect_pos.x + icon_sz.x * (reveal_pct if is_constructor else (1.0 - reveal_pct))
		draw_line(
			Vector2(line_x, rect_pos.y),
			Vector2(line_x, rect_pos.y + icon_sz.y),
			Color(1.0, 0.9, 0.2, 0.9), 1.5
		)


## Draws the held payload of a loader / unloader between its base and
## top sprites, mirroring how `_draw_fabricator_unit_layer` shows the
## unit under construction. Items don't render in-world — they surface
## in the hover tooltip — but seeing the held building/unit in-place is
## the at-a-glance signal that the block has actually grabbed something.
func _draw_loader_payload_layer(grid_pos: Vector2i, _data: BlockData, top_pos: Vector2, width: float, height: float, _rot: int) -> void:
	if _logistics == null:
		return
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var payload: Dictionary = {}
	if _logistics.loader_state.has(anchor):
		var ls: Dictionary = _logistics.loader_state[anchor]
		if ls.get("payload") != null and ls["payload"] is Dictionary:
			payload = ls["payload"]
	if payload.is_empty() and _logistics.unloader_state.has(anchor):
		var us: Dictionary = _logistics.unloader_state[anchor]
		if us.get("payload") != null and us["payload"] is Dictionary:
			payload = us["payload"]
	if payload.is_empty():
		return
	var center: Vector2 = top_pos + Vector2(width / 2.0, height / 2.0)
	var p_size: float = minf(width, height) * 0.55
	var ptype: String = String(payload.get("type", ""))
	if ptype == "building":
		var bd: BlockData = Registry.get_block(StringName(payload.get("block_id", "")))
		if bd and bd.icon:
			var bsz: Vector2 = _fit_texture_size(bd.icon, p_size)
			draw_texture_rect(bd.icon, Rect2(center - bsz * 0.5, bsz), false, Color(1, 1, 1, 0.85))
	elif ptype == "unit":
		var ud = Registry.get_unit(StringName(payload.get("unit_id", "")))
		if ud and ud.icon:
			var usz: Vector2 = _fit_texture_size(ud.icon, p_size)
			draw_texture_rect(ud.icon, Rect2(center - usz * 0.5, usz), false, Color(1, 1, 1, 0.85))
		elif ud:
			draw_circle(center, p_size * 0.4, Color(ud.color.r, ud.color.g, ud.color.b, 0.75))


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


## Developer overlay: outlines every placed block's tile footprint in
## magenta when `main.show_hitboxes` is on. Only iterates anchors (the
## origin cells of each building), so multi-tile blocks render as one
## rect instead of one per covered cell.
func _draw_block_hitboxes() -> void:
	# `main` here is whatever wired this BuildingSystem up — usually the
	# game's `Main` node, but the map editor reuses the same draw code
	# with its own root that doesn't carry the developer toggles. Guard
	# the property check so the editor doesn't crash on missing fields.
	if main == null or not ("show_hitboxes" in main) or not main.show_hitboxes:
		return
	var gs := float(main.GRID_SIZE)
	var color := Color(1.0, 0.2, 0.9, 0.9)
	for anchor in main.placed_buildings:
		var block_id: StringName = main.placed_buildings[anchor]
		var data = Registry.get_block(block_id)
		if data == null:
			continue
		var size: Vector2i = data.grid_size
		var origin: Vector2 = main.grid_to_world(anchor)
		var rect := Rect2(origin, Vector2(size.x * gs, size.y * gs))
		draw_rect(rect, color, false, 1.5)


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
	# Floor miners (ground scraper) read ore from straight under their
	# footprint instead of facing forward into a wall, so rotation is
	# meaningless for them — also overrides the EXTRACTORS default.
	if data.tags.has("floor_miner"):
		return false
	return (data.is_transport() and not data.tags.has("junction")) \
		or data.category == BlockData.BlockCategory.EXTRACTORS \
		or data.tags.has("shaft") \
		or data.tags.has("constructor") or data.tags.has("deconstructor") \
		or data.tags.has("payload_loader") or data.tags.has("freight_loader") \
		or data.tags.has("payload_unloader") or data.tags.has("freight_unloader") \
		or data.tags.has("archive_scanner") \
		or data.tags.has("fabricator") \
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
					elif existing_data.tags.has("platform"):
						# Platforms are terrain — drag-place freely lays
						# transport across them (the platform stays
						# stashed underneath via main._platform_under).
						pass
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
## When `skip_crossings` is true the raw path is returned as-is; used when
## the drag starts on an existing same-tag belt (treat as direction change).
func _compute_transport_path(from: Vector2i, to: Vector2i, transport_tag: String, skip_crossings: bool = false) -> Array[Vector2i]:
	_pathfind_bridge_cells.clear()
	if _transport_astar == null:
		_build_transport_astar(transport_tag)

	if not _transport_astar.is_in_boundsv(from) or not _transport_astar.is_in_boundsv(to):
		return []
	if _transport_astar.is_point_solid(from):
		return []
	# If the user dragged the cursor onto a non-transport block (the
	# A* graph marks those solid), reroute to the nearest non-solid
	# neighbour of that block instead of bailing with an empty path.
	# Picking the cardinal neighbour closest to `from` makes the
	# fall-back land on the side the player was approaching from, so
	# the trailing belt sits flush against the block. Callers that
	# care about "where the user actually pointed" can still pass the
	# original `to` separately as a rotation hint.
	var actual_to: Vector2i = to
	if _transport_astar.is_point_solid(to):
		actual_to = _nearest_walkable_neighbour(to, from, _transport_astar)
		if actual_to == Vector2i(-9999, -9999):
			return []

	var id_path: PackedVector2Array = _transport_astar.get_point_path(from, actual_to)
	if id_path.is_empty():
		return []

	var raw: Array[Vector2i] = []
	for p in id_path:
		raw.append(Vector2i(int(p.x), int(p.y)))

	if skip_crossings:
		return raw
	return _apply_transport_crossings(raw, transport_tag)


## Returns the cardinal neighbour of `cell` that's walkable in the given
## A* graph and closest to `from` (Manhattan). Returns
## Vector2i(-9999, -9999) when every neighbour is solid / out of bounds.
func _nearest_walkable_neighbour(cell: Vector2i, from: Vector2i, astar: AStarGrid2D) -> Vector2i:
	var best: Vector2i = Vector2i(-9999, -9999)
	var best_dist: int = 0x7FFFFFFF
	for dir_idx in range(4):
		var n: Vector2i = cell + DIR_VECTORS[dir_idx]
		if not astar.is_in_boundsv(n):
			continue
		if astar.is_point_solid(n):
			continue
		var d: int = absi(n.x - from.x) + absi(n.y - from.y)
		if d < best_dist:
			best_dist = d
			best = n
	return best


## Returns true when `start` is a cell already occupied by a same-type
## transport. Drag-placing that starts from an existing belt is interpreted
## as "rotate the belt at this cell and extend from it", NOT as "cross
## the belt with junctions", so the auto-substitution is skipped.
func _drag_starts_on_same_transport(start: Vector2i, transport_tag: String) -> bool:
	if not main.placed_buildings.has(start):
		return false
	var existing = Registry.get_block(main.placed_buildings[start])
	if existing == null:
		return false
	return existing.tags.has(transport_tag)


## Walks a transport path (in order) and rewrites it so that any cell that
## overlaps an existing same-type transport becomes a junction (perpendicular
## crossing) or a bridge pair (same-axis crossing). The substitutions land
## in `_pathfind_bridge_cells` / `_pathfind_bridge_pairs` so the commit loop
## can pick them up. Callers are expected to have cleared those dicts first.
##
## Junction / bridge substitutions are only used when the corresponding
## block has been researched; if the player hasn't unlocked the junction
## yet, a perpendicular crossing falls back to overlay (old belt stays).
## Same for bridges — without the research we won't try to span obstacles.
func _apply_transport_crossings(raw: Array[Vector2i], transport_tag: String) -> Array[Vector2i]:
	var bridge_id := _find_bridge_for_type(transport_tag)
	var junction_id := _find_junction_for_type(transport_tag)
	if bridge_id != &"" and not TechTree.is_researched(bridge_id):
		bridge_id = &""
	if junction_id != &"" and not TechTree.is_researched(junction_id):
		junction_id = &""

	var result: Array[Vector2i] = []
	var i := 0
	while i < raw.size():
		var gp: Vector2i = raw[i]

		# If this cell overlaps an existing block, figure out how to bridge it.
		if main.placed_buildings.has(gp):
			var existing_id: StringName = main.placed_buildings[gp]
			var existing_data = Registry.get_block(existing_id)
			var same_transport: bool = existing_data != null and existing_data.tags.has(transport_tag)
			# Platforms are terrain, not obstacles — drag straight onto them
			# without trying to bridge over. The transport block's normal
			# placement path stashes the platform underneath via
			# `main._platform_under` and overwrites the cell with the new
			# transport block.
			var is_platform_under: bool = existing_data != null and existing_data.tags.has("platform")
			if is_platform_under:
				result.append(gp)
				i += 1
				continue

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
				# drag path — bridge over it. We need BOTH a placeable start
				# cell (must come before the obstacle, can't be another
				# substitution) AND a placeable end cell past the obstacle.
				# If either is missing, skip the obstacle silently instead of
				# emitting a dangling bridge half.
				var can_start: bool = result.size() > 0 \
					and not _pathfind_bridge_cells.has(result[-1])
				# Scan forward past any consecutive obstacles to find the
				# first cell we could land the bridge on. A same-tag transport
				# counts as a valid landing (we exit the obstacle span into
				# existing belt).
				var bridge_end := i + 1
				while bridge_end < raw.size() and main.placed_buildings.has(raw[bridge_end]):
					var ed = Registry.get_block(main.placed_buildings.get(raw[bridge_end], &""))
					if ed != null and ed.tags.has(transport_tag):
						break
					bridge_end += 1
				var can_end: bool = bridge_end < raw.size()
				if can_start and can_end:
					_pathfind_bridge_cells[result[-1]] = bridge_id
					_pathfind_bridge_cells[raw[bridge_end]] = bridge_id
					_pathfind_bridge_pairs.append([result[-1], raw[bridge_end]])
					i = bridge_end
					result.append(raw[i])
				# Otherwise: silently skip the obstacle cells. Placement at
				# those cells would fail anyway; no dangling bridge stub.
			# Different-tag transport with no bridge available: silently skip.
		else:
			result.append(gp)
		i += 1

	return result


## Compute per-cell rotations for a transport path (each cell faces the next).
## `target_hint` (optional) is the cell the player's cursor was on when the
## drag ended — when the path's last cell is one step away from it, we
## point the trailing belt straight at the hint instead of using the
## path's last delta. This is what makes drag-into-a-block place the
## boundary belt facing INTO the block: A* falls back to a neighbour, but
## the rotation still aims at the original target.
func _compute_path_rotations(path: Array[Vector2i], target_hint: Vector2i = Vector2i(-9999, -9999)) -> void:
	_pathfind_rotations.clear()
	var has_hint: bool = target_hint != Vector2i(-9999, -9999)
	for i in range(path.size()):
		var rot := 0
		var delta: Vector2i
		if i < path.size() - 1:
			# Forward-looking: this cell's rotation points to the next.
			delta = path[i + 1] - path[i]
		elif i > 0:
			# Last cell. If we have a target hint and it's a unit
			# vector away, prefer it — that way a path that ended on
			# the boundary of a block faces INTO the block. Otherwise
			# derive from the path's own last step.
			if has_hint and target_hint != path[i]:
				var hint_delta: Vector2i = target_hint - path[i]
				if DIR_VECTORS.find(hint_delta) >= 0:
					delta = hint_delta
				else:
					delta = path[i] - path[i - 1]
			else:
				delta = path[i] - path[i - 1]
		else:
			# Single-cell path. If we have a unit-vector target hint,
			# face it; otherwise leave the entry empty so the placement
			# loop falls back to `placement_rotation` (Q-rotation).
			if has_hint and target_hint != path[i]:
				var hint_delta_s: Vector2i = target_hint - path[i]
				if DIR_VECTORS.find(hint_delta_s) >= 0:
					delta = hint_delta_s
				else:
					continue
			else:
				continue
		var idx: int = DIR_VECTORS.find(delta)
		if idx >= 0:
			rot = idx
		else:
			# Delta isn't a unit vector — happens when a bridge span is
			# collapsed from raw path → result. Pick the dominant axis
			# direction so the bridge start still faces toward its pair
			# instead of defaulting to 0 (east).
			if absi(delta.x) >= absi(delta.y):
				rot = 0 if delta.x > 0 else 2
			else:
				rot = 1 if delta.y > 0 else 3
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

	# Transport blocks: output in their facing direction only — except
	# routers (split flow across every face EXCEPT the back) and
	# junctions (passthrough on all 4 axes). Without these, neighbouring
	# belts can't detect the splitter and stay straight instead of
	# picking up their corner / junction texture variants.
	if data.is_transport():
		if data.tags.has("router"):
			var back: Vector2i = -dir
			var rel: Vector2i = to_pos - from_pos
			return rel != back and (rel == dir \
				or rel == Vector2i(dir.y, -dir.x) \
				or rel == Vector2i(-dir.y, dir.x))
		if data.tags.has("junction"):
			var rel2: Vector2i = to_pos - from_pos
			return rel2 == Vector2i(1, 0) or rel2 == Vector2i(-1, 0) \
				or rel2 == Vector2i(0, 1) or rel2 == Vector2i(0, -1)
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

	# Pick the right texture set based on the block at this cell. Belts and
	# ducts share the corner / junction logic but have different art.
	var textures: Dictionary = _belt_textures
	var bid: StringName = main.placed_buildings.get(grid_pos, &"")
	if bid == &"duct":
		textures = _duct_textures
	return {"texture": textures.get(tex_key), "angle": angle, "key": tex_key}


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

	# Pick the texture set based on the previewed block id. Belts and
	# ducts share corner / junction logic but have different art.
	var textures: Dictionary = _belt_textures
	if preview_block_id == &"duct":
		textures = _duct_textures
	return {"texture": textures.get(tex_key), "angle": angle, "key": tex_key}


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

	# Stable painter's-order sort by world position. The previous
	# camera-distance sort flipped z-order whenever a block crossed from one
	# side of the camera to the other, so two adjacent blocks would visibly
	# swap who paints over whom as you panned past them — and a covered
	# platform could end up painting on top of the block placed on it.
	# World-Y ascending (north→south) is the standard 2.5D painter's order;
	# X breaks side-by-side ties; platform-flag breaks same-cell ties so
	# the cover always paints on top of its platform.
	var n: int = all_positions.size()
	var sort_y: PackedInt32Array = PackedInt32Array()
	var sort_x: PackedInt32Array = PackedInt32Array()
	var sort_under: PackedByteArray = PackedByteArray()
	sort_y.resize(n)
	sort_x.resize(n)
	sort_under.resize(n)
	var _platform_id_cache: Dictionary = {}
	for i in range(n):
		var gp: Vector2i = all_positions[i]
		sort_y[i] = gp.y
		sort_x[i] = gp.x
		var is_plat := false
		if not is_wall_of[i]:
			var bid_check: StringName = main.placed_buildings.get(gp, &"")
			if bid_check != &"":
				if _platform_id_cache.has(bid_check):
					is_plat = _platform_id_cache[bid_check]
				else:
					var bd_check: BlockData = Registry.get_block(bid_check)
					is_plat = bd_check != null and bd_check.tags.has("platform")
					_platform_id_cache[bid_check] = is_plat
		sort_under[i] = 1 if is_plat else 0

	# Sort an index permutation (keeps the parallel is_wall_of array aligned).
	var order: Array = []
	order.resize(n)
	for i in range(n):
		order[i] = i
	order.sort_custom(func(a: int, b: int) -> bool:
		if sort_y[a] != sort_y[b]:
			return sort_y[a] < sort_y[b]
		if sort_x[a] != sort_x[b]:
			return sort_x[a] < sort_x[b]
		return sort_under[a] > sort_under[b])

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
			side_color = Color.BLACK
			side_color_darker = Color.BLACK
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

		# A queued-but-not-yet-actively-building block renders as a faded
		# ghost so the player can tell which one the drone is currently
		# working on. The active anchor and any partially-built block keep
		# the full-texture render plus the overlay reveal line / dim.
		if has_build_progress and main.building_build_progress.has(grid_pos):
			var anchor_q: Vector2i = main.building_origins.get(grid_pos, grid_pos)
			var pct_q: float = main.get_build_progress_pct(anchor_q)
			if pct_q == 0.0 and not (has_active_work and active_work_anchor == anchor_q):
				_draw_block_ghost_preview(grid_pos, block_id, data, top_pos, width, height,
					main.building_rotation.get(grid_pos, 0))
				continue

		# Conveyor belts and ducts use auto-tiled textures based on neighbours.
		var _is_belt_or_duct: bool = (block_id == &"conveyor_belt" and not _belt_textures.is_empty()) \
				or (block_id == &"duct" and not _duct_textures.is_empty())
		if _is_belt_or_duct:
			var info: Dictionary = _get_belt_draw_info(grid_pos)
			var texture: Texture2D = info["texture"]
			var angle: float = info["angle"]
			var tex_key: String = info.get("key", "straight")
			if texture:
				var center: Vector2 = top_pos + Vector2(width / 2.0, height / 2.0)
				draw_set_transform(center, angle)
				var dst_rect := Rect2(Vector2(-width / 2.0, -height / 2.0), Vector2(width, height))
				if not belt_scroll_enabled:
					# Animation disabled — static draw via the same region-
					# sampling path as the scrolling branch so corner /
					# junction tiles render identically (no subpixel-clamp
					# gaps from draw_texture_rect rotated by 90/180°).
					var s_tex_size: Vector2 = texture.get_size()
					draw_texture_rect_region(texture, dst_rect, Rect2(Vector2.ZERO, s_tex_size))
					draw_set_transform(Vector2.ZERO, 0.0)
					continue
				# Per-variant UV scroll vector. Belt textures are authored
				# "facing up" (see _get_belt_draw_info — the rotation adds
				# PI/2 so rot 0 = right), so the through-line travel in
				# texture-local coords is -y; sliding the source window
				# down (+y) makes the visible surface scroll up. Corners
				# scroll on a diagonal that approximates the curve's exit
				# direction. Junctions reuse the straight scroll — the
				# side spurs end up frozen-but-textured, which reads
				# better than the whole tile sliding in one wrong axis.
				# Without a separate "moving surface" mask we can't
				# selectively animate just the curved strip; this is the
				# nearest approximation a single PNG per variant allows.
				var s: float = _belt_scroll_phase
				var diag: float = s * 0.70710678  # 1/sqrt(2)
				var scroll_off: Vector2
				match tex_key:
					"straight", "jl", "jr", "ja":
						scroll_off = Vector2(0.0, s)
					"ca":
						# CA: through-line bends from back to right —
						# in texture-local space the surface flows up
						# and to the right.
						scroll_off = Vector2(-diag, diag)
					"cb":
						# CB: mirror of CA, bends back to left.
						scroll_off = Vector2(diag, diag)
					_:
						scroll_off = Vector2(0.0, s)
				var tex_size: Vector2 = texture.get_size()
				var src_rect := Rect2(scroll_off, tex_size)
				draw_texture_rect_region(texture, dst_rect, src_rect)
				draw_set_transform(Vector2.ZERO, 0.0)
			else:
				var color := _get_block_color(block_id)
				draw_rect(Rect2(top_pos, Vector2(width, height)), color, true)
				draw_rect(Rect2(top_pos, Vector2(width, height)), color.lightened(0.3), false, 2.0)

		# Vent condenser: same layered base + spinning inner pattern as
		# the vent turbine. Hits before the generic pump draw because it
		# carries the `pump` tag and would otherwise grab `_pump_texture`.
		elif block_id == &"vent_condenser":
			_draw_vent_condenser(grid_pos, top_pos, width, height)
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
			# Scraper head: spinning drum drawn UNDER whatever this block's
			# base sprite ends up being, so the base covers the center of
			# the head and only the rim peeks out — same composition as
			# the wall crusher's gears.
			if data and data.tags.has("scraper_head"):
				_draw_scraper_head(grid_pos, top_pos, width, height)
			# Unit fabricator layered rendering: base + unit-in-construction + top
			if data and data.produced_unit != &"" and data.base_sprite and data.top_sprite:
				_draw_block_texture(data.base_sprite, top_pos, width, height, rot, Color.WHITE, is_dir)
				_draw_fabricator_unit_layer(grid_pos, data, top_pos, width, height, rot)
				_draw_block_texture(data.top_sprite, top_pos, width, height, rot, Color.WHITE, is_dir)
			# Refabricator: base + per-side input overlays reflecting
			# adjacent payload conveyors.
			elif data and data.tags.has("refabricator") and data.base_sprite:
				_draw_refabricator(grid_pos, data, top_pos, width, height, rot)
			# Payload conveyor: swap top texture based on whether an upstream
			# payload source feeds the left/right side. Back-fed (or no feed)
			# uses the straight texture.
			elif block_id == &"payload_conveyor" and not _payload_conveyor_textures.is_empty():
				var anchor_pc: Vector2i = main.building_origins.get(grid_pos, grid_pos)
				var gsz_pc: Vector2i = data.grid_size if data else Vector2i(3, 3)
				# In our convention rot=0 → facing right. "Left" in the
				# conveyor's local frame is `(rot + 3) % 4`, "right" is
				# `(rot + 1) % 4`. Texture rotation handles world-space
				# orientation, so picking the right local texture is enough.
				var left_dir_pc: int = (rot + 3) % 4
				var right_dir_pc: int = (rot + 1) % 4
				var fed_left: bool = _side_has_payload_input(anchor_pc, gsz_pc, left_dir_pc)
				var fed_right: bool = _side_has_payload_input(anchor_pc, gsz_pc, right_dir_pc)
				var tex_key: String = "straight"
				if fed_left and not fed_right:
					tex_key = "left"
				elif fed_right and not fed_left:
					tex_key = "right"
				var tex: Texture2D = _payload_conveyor_textures.get(tex_key)
				if tex == null:
					tex = data.top_sprite
				_draw_block_texture(tex, top_pos, width, height, rot, Color.WHITE, is_dir)
			# Constructor / deconstructor: base + in-progress block (with
			# build / decon reveal animation) + top.
			elif data and data.base_sprite and data.top_sprite \
					and (data.tags.has("constructor") or data.tags.has("deconstructor")):
				_draw_block_texture(data.base_sprite, top_pos, width, height, rot, Color.WHITE, is_dir)
				_draw_constructor_layer(grid_pos, data, top_pos, width, height, rot)
				_draw_block_texture(data.top_sprite, top_pos, width, height, rot, Color.WHITE, is_dir)
			# Loader / unloader: base + held payload (between layers) + top.
			# Item counts surface in the hover tooltip; the in-world layer
			# only draws the held building/unit so the player can see at a
			# glance that the block has grabbed something.
			elif data and data.base_sprite and data.top_sprite \
					and (data.tags.has("payload_loader") or data.tags.has("freight_loader") \
						or data.tags.has("payload_unloader") or data.tags.has("freight_unloader")):
				_draw_block_texture(data.base_sprite, top_pos, width, height, rot, Color.WHITE, is_dir)
				_draw_loader_payload_layer(grid_pos, data, top_pos, width, height, rot)
				_draw_block_texture(data.top_sprite, top_pos, width, height, rot, Color.WHITE, is_dir)
			# Plain layered render: base + top (no faction overlay, no
			# fabricator unit layer, no refabricator side overlays). Used
			# by any block that just wants a static two-layer sprite.
			elif data and data.base_sprite and data.top_sprite:
				_draw_block_texture(data.base_sprite, top_pos, width, height, rot, Color.WHITE, is_dir)
				_draw_block_texture(data.top_sprite, top_pos, width, height, rot, Color.WHITE, is_dir)
			# Faction-layered rendering (cores): base sprite + faction overlay
			elif data and data.base_sprite:
				_draw_block_texture(data.base_sprite, top_pos, width, height, rot, Color.WHITE, is_dir)
				var overlay_scale := 0.7
				var ow: float = width * overlay_scale
				var oh: float = height * overlay_scale
				var overlay_pos: Vector2 = top_pos + Vector2((width - ow) / 2.0, (height - oh) / 2.0)
				var faction: int = main.get_building_faction(grid_pos)
				if faction == FACTION_FEROX and data.ferox_overlay:
					_draw_block_texture(data.ferox_overlay, overlay_pos, ow, oh, rot, Color.WHITE, is_dir)
				elif faction == FACTION_DERELICT and data.derelict_overlay:
					_draw_block_texture(data.derelict_overlay, overlay_pos, ow, oh, rot, Color.WHITE, is_dir)
				elif data.lumina_overlay:
					_draw_block_texture(data.lumina_overlay, overlay_pos, ow, oh, rot, Color.WHITE, is_dir)
			# Vent turbine: spinning inner-blade discs under a static base.
			# Custom layered render — the .tres still sets a `top_sprite`
			# but it's ignored in favour of the `VentTurbineBase` +
			# `VentTurbineInner` pair loaded on this system.
			elif block_id == &"vent_turbine":
				_draw_vent_turbine(grid_pos, top_pos, width, height)
			# Top sprite only (single-layer world texture)
			elif data and data.top_sprite:
				var draw_rot: int = (rot + 1) % 4 if data.tags.has("shaft") else rot
				_draw_block_texture(data.top_sprite, top_pos, width, height, draw_rot, Color.WHITE, is_dir)
			# Fallback: colored rectangle. data.icon is intentionally NOT
			# used here — it's reserved for UI (HUD/tooltips) only.
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

		# Single-direction output indicator: when this block sends a particular
		# item / fluid out exactly ONE side, paint that resource's icon at the
		# midpoint of that edge, half a tile beyond the block. Resources that
		# leave through multiple sides are skipped — the icon would just clutter
		# the block. Skipped entirely for omnidirectional factories.
		if data and not data.side_outputs.is_empty() and not data.tags.has("omnidirectional"):
			var dir_count: Dictionary = {}
			var dir_for: Dictionary = {}
			for rel_key in data.side_outputs:
				var oid := StringName(data.side_outputs[rel_key])
				if oid == &"":
					continue
				dir_count[oid] = int(dir_count.get(oid, 0)) + 1
				dir_for[oid] = int(rel_key)
			var blk_rot: int = main.building_rotation.get(grid_pos, 0)
			var blk_center: Vector2 = top_pos + Vector2(width * 0.5, height * 0.5)
			var icon_sz: float = gs * 0.5
			for oid in dir_count:
				if dir_count[oid] != 1:
					continue
				var world_dir: int = (int(dir_for[oid]) + blk_rot) % 4
				var icon_center: Vector2 = blk_center
				match world_dir:
					0: icon_center = blk_center + Vector2(width * 0.5 + gs * 0.5, 0)
					1: icon_center = blk_center + Vector2(0, height * 0.5 + gs * 0.5)
					2: icon_center = blk_center - Vector2(width * 0.5 + gs * 0.5, 0)
					3: icon_center = blk_center - Vector2(0, height * 0.5 + gs * 0.5)
				var out_tex: Texture2D = null
				var item_d = Registry.get_item(oid)
				if item_d and item_d.icon:
					out_tex = item_d.icon
				else:
					var fluid_d = Registry.get_fluid(oid)
					if fluid_d and fluid_d.icon:
						out_tex = fluid_d.icon
				if out_tex:
					var rect := Rect2(icon_center - Vector2(icon_sz * 0.5, icon_sz * 0.5), Vector2(icon_sz, icon_sz))
					draw_texture_rect(out_tex, rect, false)

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

	# --- PASS 2.25: Build animation overlay ---
	# Only the block currently being constructed gets the left-to-right
	# reveal; every other pending block (whether in range or not) renders as
	# a subtle ghost preview, matching the out-of-range queue style so the
	# player reads the two states the same way.
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
			if build_pct > 0.0:
				# Partially built: draw the dark overlay only on the unbuilt
				# portion so the reveal stays visible whether this anchor is
				# actively being worked on or just paused mid-build. The
				# moving yellow line only renders when actively building.
				var reveal_x: float = b_width * build_pct
				var unbuilt_rect := Rect2(
					b_top_pos.x + reveal_x, b_top_pos.y,
					b_width - reveal_x, b_height
				)
				draw_rect(unbuilt_rect, Color(0, 0, 0, 0.65), true)
				if is_active_build:
					var line_x: float = b_top_pos.x + reveal_x
					draw_line(
						Vector2(line_x, b_top_pos.y),
						Vector2(line_x, b_top_pos.y + b_height),
						Color(1.0, 0.9, 0.2, 0.9), 2.0
					)
				# CombatSystem only draws heads for fully-built turrets
				# (inactive blocks are filtered out of its targeting/state
				# init), so a turret under construction would otherwise
				# show only its base. Overlay the head/chassis here at a
				# slightly muted tint so the in-progress turret reads as
				# what it'll become.
				var b_data = Registry.get_block(b_block_id)
				if b_data and b_data.is_turret():
					var b_rot: int = int(main.building_rotation.get(grid_pos, 0))
					_draw_turret_preview_heads(
						b_data, b_top_pos, b_width, b_height, b_rot, Color(1, 1, 1, 0.7)
					)
			# Pending-not-active blocks are now rendered by the faded
			# ghost preview path in PASS 2 — nothing to overlay here.

	# --- PASS 2.27: Deferred same-group swap preview ---
	# pending_swaps are junctions / bridges / etc. queued over an existing
	# belt or pipe. The old block is still live (and being drawn at full
	# opacity by pass 2), so we just overlay a translucent ghost of the
	# incoming block so the player can see what's coming.
	if "pending_swaps" in main and not main.pending_swaps.is_empty():
		for grid_pos in main.pending_swaps:
			if ss and ss.is_tile_hidden(grid_pos):
				continue
			var entry: Dictionary = main.pending_swaps[grid_pos]
			var new_id: StringName = StringName(entry.get("new_block_id", &""))
			var new_data = Registry.get_block(new_id)
			if new_data == null:
				continue
			var new_rot: int = int(entry.get("new_rotation", 0))
			var world_pos_s: Vector2 = main.grid_to_world(grid_pos)
			var off_s: Vector2 = _get_top_offset(world_pos_s) * _get_height_scale(new_id)
			var w_s: float = gs * new_data.grid_size.x
			var h_s: float = gs * new_data.grid_size.y
			var top_pos_s: Vector2 = world_pos_s + off_s
			var tint_s := Color(1, 1, 1, 0.55)
			if (new_id == &"conveyor_belt" and not _belt_textures.is_empty()) \
					or (new_id == &"duct" and not _duct_textures.is_empty()):
				# Use the with-preview variant so the texture set is picked
				# from `new_id` (the swapped-in block) rather than whatever
				# is currently placed at this cell.
				var info_s: Dictionary = _get_belt_draw_info_with_preview(grid_pos, {}, {}, new_id)
				var texture_s: Texture2D = info_s["texture"]
				var angle_s: float = info_s["angle"]
				if texture_s:
					var centre_s: Vector2 = top_pos_s + Vector2(w_s / 2.0, h_s / 2.0)
					draw_set_transform(centre_s, angle_s)
					draw_texture_rect(texture_s, Rect2(Vector2(-w_s / 2.0, -h_s / 2.0), Vector2(w_s, h_s)), false, tint_s)
					draw_set_transform(Vector2.ZERO, 0.0)
			else:
				# Prefer world-facing top/base sprites. data.icon is UI-only.
				var swap_tex: Texture2D = null
				if new_data.top_sprite:
					swap_tex = new_data.top_sprite
				elif new_data.base_sprite:
					swap_tex = new_data.base_sprite
				if swap_tex:
					var is_dir_s: bool = _is_directional(new_id)
					var draw_rot: int = new_rot if is_dir_s else 0
					_draw_block_texture(swap_tex, top_pos_s, w_s, h_s, draw_rot, tint_s, is_dir_s)
				else:
					var col_s: Color = _get_block_color(new_id)
					col_s.a = 0.45
					draw_rect(Rect2(top_pos_s, Vector2(w_s, h_s)), col_s, true)
			draw_rect(Rect2(top_pos_s, Vector2(w_s, h_s)), Color(1, 1, 1, 0.35), false, 1.0)

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
			# Moving red line only while actively deconstructing. Paused
			# entries freeze the reveal at its current position so the
			# player can see exactly how far decon has gotten.
			if is_active_decon:
				draw_line(
					Vector2(line_x, d_top_pos.y),
					Vector2(line_x, d_top_pos.y + d_height),
					Color(0.9, 0.2, 0.2, 0.9), 2.0
				)
			else:
				# Tint the still-intact (already-built) area a faint red so
				# paused decons are distinguishable from normal buildings.
				var intact_w: float = line_x - d_top_pos.x
				if intact_w > 0.0:
					draw_rect(Rect2(d_top_pos.x, d_top_pos.y, intact_w, d_height), Color(0.9, 0.2, 0.2, 0.18), true)

	# --- PASS 2.5: Faction overlay on enemy buildings ---
	# Draws a single sprite (FactionOverlayFerox.png / FactionOverlayDerelict.png)
	# centered on the BOTTOM-RIGHT tile of the building's footprint, instead
	# of tinting the entire footprint a flat colour. For 1×1 blocks the
	# bottom-right tile == the only tile, so the overlay simply sits in
	# the centre. For multi-tile blocks (e.g. cores), the overlay anchors
	# to a single-tile slot at the bottom-right so the rest of the
	# building art stays clearly visible.
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
			var overlay_tex: Texture2D = null
			if bfaction == FACTION_DERELICT:
				overlay_tex = _faction_overlay_derelict
			elif bfaction == FACTION_FEROX:
				overlay_tex = _faction_overlay_ferox
			if overlay_tex == null:
				continue
			var f_block_id: StringName = main.placed_buildings[grid_pos]
			var block_size_f: Vector2i = _size_for.call(f_block_id)
			var world_pos_f: Vector2 = main.grid_to_world(grid_pos)
			var offset_f: Vector2 = _offset_for.call(f_block_id)
			# Bottom-right tile in the footprint: x = anchor.x + (w − 1),
			# y = anchor.y + (h − 1). Centre of that tile is
			# ((w − 0.5)*gs, (h − 0.5)*gs) in local space.
			var br_centre: Vector2 = world_pos_f + offset_f + Vector2(
				(float(block_size_f.x) - 0.5) * gs,
				(float(block_size_f.y) - 0.5) * gs,
			)
			# Match the on-screen footprint of one tile so the overlay
			# scales with the block and never bleeds past the bottom-
			# right cell.
			var ov_size: Vector2 = Vector2(gs, gs)
			var ov_rect := Rect2(br_centre - ov_size * 0.5, ov_size)
			draw_texture_rect(overlay_tex, ov_rect, false)

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


## Stamps a held turret's chassis plate (multi-barrel) and head
## sprite(s) on top of the picked-up icon at the saved world-space
## aim angles, so the heads visibly preserve where they were pointing
## when picked up. `aim_world` is the chassis aim (or the per-barrel
## aim if `barrel_angles` is supplied per-head).
func _draw_held_turret_heads_at(data: BlockData, center: Vector2, aim_world: float, barrel_angles: Array, scale: float) -> void:
	if data == null or not data.is_turret() or data.turret_head_sprite == null:
		return
	var c: CanvasItem = _ccanvas()
	var bcount: int = maxi(data.barrel_count, 1)
	var head_tex: Texture2D = data.turret_head_sprite
	var tex_size: Vector2 = head_tex.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR * scale
	var draw_angle_chassis: float = aim_world + PI / 2.0
	var chassis_dir := Vector2.from_angle(aim_world)
	var chassis_perp := Vector2(-chassis_dir.y, chassis_dir.x)
	var spacing: float = data.barrel_spacing * scale
	if bcount > 1:
		c.draw_set_transform(center, draw_angle_chassis)
		if data.turret_chassis_sprite:
			var ctex: Texture2D = data.turret_chassis_sprite
			var csize: Vector2 = ctex.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR * scale
			c.draw_texture_rect(ctex, Rect2(Vector2(-csize.x * 0.5, -csize.y * 0.5), csize), false, Color(1, 1, 1, 1.0))
		else:
			var plate_w: float = (float(bcount) - 1.0) * spacing + tex_size.x * 0.9
			var plate_h: float = tex_size.y * 0.35
			c.draw_rect(Rect2(Vector2(-plate_w * 0.5, -plate_h * 0.5), Vector2(plate_w, plate_h)), Color(0.32, 0.32, 0.34, 1.0))
		c.draw_set_transform(Vector2.ZERO, 0.0)
	for i in range(bcount):
		var lateral: float = 0.0
		if bcount > 1:
			lateral = (float(i) - (float(bcount) - 1.0) * 0.5) * spacing
		var pivot: Vector2 = center + chassis_perp * lateral
		var barrel_aim: float = aim_world
		if i < barrel_angles.size():
			barrel_aim = float(barrel_angles[i])
		c.draw_set_transform(pivot, barrel_aim + PI / 2.0)
		var rect := Rect2(
			Vector2(-tex_size.x * 0.5, -tex_size.y + 14.0 * main.SPRITE_SCALE_FACTOR * scale),
			tex_size,
		)
		c.draw_texture_rect(head_tex, rect, false, Color(1, 1, 1, 1.0))
		c.draw_set_transform(Vector2.ZERO, 0.0)


## Draws the turret chassis (multi-barrel only) and head sprite(s) on top
## of an existing block preview, rotated to face `rot` (0=right, 1=down,
## 2=left, 3=up — same convention as placement_rotation). No-op when the
## block isn't a turret with a head sprite. Mirrors the live-draw math
## in CombatSystem._draw_turret_heads so what the player sees in the
## ghost is what they get on placement.
func _draw_turret_preview_heads(data: BlockData, top_pos: Vector2, w: float, h: float, rot: int, tint: Color) -> void:
	if data == null or not data.is_turret() or data.turret_head_sprite == null:
		return
	var center: Vector2 = top_pos + Vector2(w / 2.0, h / 2.0)
	var aim_angle: float = float(rot) * (PI / 2.0)
	var draw_angle: float = aim_angle + PI / 2.0
	var bcount: int = maxi(data.barrel_count, 1)
	var head_tex: Texture2D = data.turret_head_sprite
	var tex_size: Vector2 = head_tex.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
	var chassis_dir := Vector2.from_angle(aim_angle)
	var chassis_perp := Vector2(-chassis_dir.y, chassis_dir.x)
	# Chassis plate (multi-barrel only).
	if bcount > 1:
		draw_set_transform(center, draw_angle)
		if data.turret_chassis_sprite:
			var ctex: Texture2D = data.turret_chassis_sprite
			var csize: Vector2 = ctex.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
			draw_texture_rect(
				ctex,
				Rect2(Vector2(-csize.x * 0.5, -csize.y * 0.5), csize),
				false,
				tint,
			)
		else:
			var plate_w: float = (float(bcount) - 1.0) * data.barrel_spacing + tex_size.x * 0.9
			var plate_h: float = tex_size.y * 0.35
			draw_rect(
				Rect2(Vector2(-plate_w * 0.5, -plate_h * 0.5), Vector2(plate_w, plate_h)),
				Color(0.32, 0.32, 0.34, tint.a),
			)
		draw_set_transform(Vector2.ZERO, 0.0)
	# Heads — one per barrel, perpendicular to the aim axis.
	for i in range(bcount):
		var lateral: float = 0.0
		if bcount > 1:
			lateral = (float(i) - (float(bcount) - 1.0) * 0.5) * data.barrel_spacing
		var pivot: Vector2 = center + chassis_perp * lateral
		draw_set_transform(pivot, draw_angle)
		var rect := Rect2(
			Vector2(-tex_size.x * 0.5, -tex_size.y + 14.0 * main.SPRITE_SCALE_FACTOR),
			tex_size,
		)
		draw_texture_rect(head_tex, rect, false, tint)
		draw_set_transform(Vector2.ZERO, 0.0)


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


## Paints an orange arrow on the cell directly in front of a directional
## block's front edge — i.e. the cell items/units would flow into.
## Used by the placement previews so the player can see the eject
## direction before committing, even on textured blocks where the
## sprite alone doesn't make orientation obvious. The arrow rotates
## with the block; the cell it sits on shifts whenever the player
## presses Q to re-rotate the preview.
const _FRONT_DIR_ARROW_COLOR := Color(1.0, 0.55, 0.0, 0.95)
func _draw_front_direction_arrow(grid_pos: Vector2i, grid_size: Vector2i, rotation: int) -> void:
	var gs: float = float(main.GRID_SIZE)
	var dir_v: Vector2i = DIR_VECTORS[rotation]
	# Compute the arrow's center in world space directly. For odd-size
	# blocks (1, 3, 5…) this lands on a cell center; for even-size
	# blocks (2, 4…) it lands on the SHARED EDGE between the two middle
	# cells — i.e. the geometric center of the face — so the arrow is
	# always visually centered on the front of the block regardless of
	# whether the block has an odd or even footprint.
	var origin_world: Vector2 = Vector2(float(grid_pos.x), float(grid_pos.y)) * gs
	var face_w: float = float(grid_size.x) * gs
	var face_h: float = float(grid_size.y) * gs
	var cell_center: Vector2
	match rotation:
		0:  # right — past the right edge, vertically centered
			cell_center = origin_world + Vector2(face_w + gs * 0.5, face_h * 0.5)
		1:  # down — past the bottom edge, horizontally centered
			cell_center = origin_world + Vector2(face_w * 0.5, face_h + gs * 0.5)
		2:  # left — past the left edge, vertically centered
			cell_center = origin_world + Vector2(-gs * 0.5, face_h * 0.5)
		_:  # up (3) — past the top edge, horizontally centered
			cell_center = origin_world + Vector2(face_w * 0.5, -gs * 0.5)
	# Slightly oversize the arrow so it reads from a distance — the
	# preview is informational, not part of the final block art.
	var dir_f := Vector2(dir_v)
	var size: float = clampf(gs * 0.45, 14.0, 64.0)
	var start_pt: Vector2 = cell_center - dir_f * size * 0.5
	var end_pt: Vector2 = cell_center + dir_f * size * 0.5
	draw_line(start_pt, end_pt, _FRONT_DIR_ARROW_COLOR, 4.0)
	var perp := Vector2(-dir_f.y, dir_f.x) * size * 0.35
	var back := dir_f * size * 0.4
	draw_line(end_pt, end_pt - back + perp, _FRONT_DIR_ARROW_COLOR, 4.0)
	draw_line(end_pt, end_pt - back - perp, _FRONT_DIR_ARROW_COLOR, 4.0)


## Draws a health bar centered above a building.
## bar_width_base is the pixel width of the building (scales with size).
func _draw_building_health_bar(world_pos: Vector2, health_pct: float, building_pixel_width: float = 128.0) -> void:
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

		# Draw belt / duct texture preview or fallback ghost
		var is_belt_q: bool = (block_id == &"conveyor_belt" and not _belt_textures.is_empty()) \
				or (block_id == &"duct" and not _duct_textures.is_empty())
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
			# Prefer world-facing top/base sprites. data.icon is UI-only.
			var q_tex: Texture2D = null
			var q_drew_layered := false
			# Fabricators/refabricators layer base + top so the block reads
			# as a whole building, not just its overlay.
			if data.base_sprite and data.top_sprite:
				_draw_block_texture(data.base_sprite, top_pos, w, h, q_rot, tint)
				_draw_block_texture(data.top_sprite, top_pos, w, h, q_rot, tint)
				q_drew_layered = true
			elif data.base_sprite and (data.feed_overlay_back or data.feed_overlay_left or data.feed_overlay_right):
				_draw_block_texture(data.base_sprite, top_pos, w, h, q_rot, tint)
				if data.feed_overlay_back:
					_draw_block_texture(data.feed_overlay_back, top_pos, w, h, q_rot, tint)
				q_drew_layered = true
			elif data.top_sprite:
				q_tex = data.top_sprite
			elif data.base_sprite:
				q_tex = data.base_sprite
			if q_tex:
				_draw_block_texture(q_tex, top_pos, w, h, q_rot, tint)
			elif not q_drew_layered:
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
		# Turret heads / chassis overlay so paused-queue and out-of-
		# build-range turret ghosts visibly show their barrels.
		if data.is_turret():
			_draw_turret_preview_heads(data, top_pos, w, h, rotation, Color(1, 1, 1, 0.45))

		# Yellow outline for all queued blocks
		draw_rect(Rect2(top_pos, Vector2(w, h)), Color(1.0, 0.9, 0.2, 0.5), false, 1.5)


## Renders a queued (in-range, build_progress == 0, not actively being
## built) block as a faded ghost — same look-and-feel as the out-of-range
## paused-queue preview, so the player can tell at a glance which block
## the drone is actually working on right now versus the rest of the
## queue. Anchored at `top_pos` with the block's full footprint.
func _draw_block_ghost_preview(grid_pos: Vector2i, block_id: StringName, data: BlockData, top_pos: Vector2,
		w: float, h: float, rot: int) -> void:
	if data == null:
		return
	var tint := Color(1, 1, 1, 0.45)
	# Conveyor belts and ducts use the auto-tile texture system so the
	# ghost orients with its neighbours instead of always pointing the
	# same way.
	if (block_id == &"conveyor_belt" and not _belt_textures.is_empty()) \
			or (block_id == &"duct" and not _duct_textures.is_empty()):
		var info: Dictionary = _get_belt_draw_info(grid_pos)
		var texture: Texture2D = info["texture"]
		var angle: float = info["angle"]
		if texture:
			var center: Vector2 = top_pos + Vector2(w / 2.0, h / 2.0)
			draw_set_transform(center, angle)
			draw_texture_rect(texture, Rect2(Vector2(-w / 2.0, -h / 2.0), Vector2(w, h)), false, tint)
			draw_set_transform(Vector2.ZERO, 0.0)
			return
	var q_rot: int = rot if _is_directional(block_id) else 0
	var q_tex: Texture2D = null
	var q_drew_layered := false
	if data.base_sprite and data.top_sprite:
		_draw_block_texture(data.base_sprite, top_pos, w, h, q_rot, tint)
		_draw_block_texture(data.top_sprite, top_pos, w, h, q_rot, tint)
		q_drew_layered = true
	elif data.base_sprite and (data.feed_overlay_back or data.feed_overlay_left or data.feed_overlay_right):
		_draw_block_texture(data.base_sprite, top_pos, w, h, q_rot, tint)
		if data.feed_overlay_back:
			_draw_block_texture(data.feed_overlay_back, top_pos, w, h, q_rot, tint)
		q_drew_layered = true
	elif data.top_sprite:
		q_tex = data.top_sprite
	elif data.base_sprite:
		q_tex = data.base_sprite
	if q_tex:
		_draw_block_texture(q_tex, top_pos, w, h, q_rot, tint)
	elif not q_drew_layered:
		var color: Color = _get_block_color(block_id)
		color.a = 0.35
		draw_rect(Rect2(top_pos, Vector2(w, h)), color, true)
		if _is_directional(block_id):
			var center := top_pos + Vector2(w / 2.0, h / 2.0)
			_draw_direction_arrow(center, q_rot, Color(1, 1, 1, 0.5))
	# Turret heads / chassis ghost overlay so a queued turret reads as
	# what it'll become, not just a flat base.
	_draw_turret_preview_heads(data, top_pos, w, h, q_rot, tint)
	# Yellow outline marks "queued, waiting for the drone".
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
		var is_belt: bool = (main.selected_building == &"conveyor_belt" and not _belt_textures.is_empty()) \
				or (main.selected_building == &"duct" and not _duct_textures.is_empty())

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
			# If the crossings helper decided this cell becomes a junction or
			# bridge, preview that specific block instead of the selected one
			# so the player sees what they'll actually get.
			var cell_block_id: StringName = main.selected_building
			if _pathfind_bridge_cells.has(cell):
				cell_block_id = _pathfind_bridge_cells[cell]
			var cell_data: BlockData = Registry.get_block(cell_block_id)
			var cell_is_belt: bool = (cell_block_id == &"conveyor_belt" and not _belt_textures.is_empty()) \
					or (cell_block_id == &"duct" and not _duct_textures.is_empty())

			var cell_valid := _can_place_at(cell, cell_block_id)
			var cell_ok := cell_valid  # No affordability gate — progressive consumption

			# Per-cell flag: set true when a baked composite painted all
			# the layered content (body + heads, etc.), so the downstream
			# turret-heads draw doesn't double-stamp.
			var cell_used_bake := false

			var cell_world: Vector2 = main.grid_to_world(cell)
			var cell_offset := _get_top_offset(cell_world) * _get_height_scale(cell_block_id)
			var cell_grid_w: int = cell_data.grid_size.x if cell_data else grid_w
			var cell_grid_h: int = cell_data.grid_size.y if cell_data else grid_h
			var w: float = float(main.GRID_SIZE) * cell_grid_w
			var h: float = float(main.GRID_SIZE) * cell_grid_h
			var cell_pos: Vector2 = cell_world + cell_offset

			# Draw belt texture preview or fallback rectangle
			if cell_is_belt:
				var info: Dictionary = _get_belt_draw_info_with_preview(cell, preview_set, preview_rots, cell_block_id)
				var texture: Texture2D = info["texture"]
				var angle: float = info["angle"]
				if texture:
					var tint: Color = Color(1, 1, 1, 0.6) if cell_ok else Color(1, 0.3, 0.3, 0.5)
					var center: Vector2 = cell_pos + Vector2(w / 2.0, h / 2.0)
					draw_set_transform(center, angle)
					draw_texture_rect(texture, Rect2(Vector2(-w / 2.0, -h / 2.0), Vector2(w, h)), false, tint)
					draw_set_transform(Vector2.ZERO, 0.0)
				else:
					var cell_color: Color = _get_block_color(cell_block_id) if cell_ok else Color(1, 0, 0, 0.4)
					cell_color.a = 0.5
					draw_rect(Rect2(cell_pos, Vector2(w, h)), cell_color, true)
			else:
				var cell_rot: int = preview_rots.get(cell, main.placement_rotation) if _is_directional(cell_block_id) else 0
				var tint: Color = Color(1, 1, 1, 0.6) if cell_ok else Color(1, 0.3, 0.3, 0.5)
				# Layered-render blocks get their own preview branch so the
				# drag ghost matches what the live render will paint.
				var cell_layered := false
				if cell_block_id == &"vent_turbine":
					_draw_vent_turbine_preview(cell_pos, w, h, tint)
					cell_layered = true
				elif cell_block_id == &"vent_condenser":
					_draw_vent_condenser_preview(cell_pos, w, h, tint)
					cell_layered = true
				# Cores + turrets: paint the pre-baked composite when ready
				# so layered overlays don't alpha-stack at preview tint.
				if not cell_layered and cell_data and (cell_data.tags.has("core") or cell_data.is_turret()):
					var cell_info: Dictionary = _request_preview_composite(cell_block_id, cell_rot)
					if not cell_info.is_empty():
						draw_texture_rect(
							cell_info["tex"],
							Rect2(cell_pos + cell_info["rect_offset"], cell_info["rect_size"]),
							false, tint)
						cell_layered = true
						cell_used_bake = true
				# Prefer world-facing top/base sprites. `icon` is UI-only.
				var cell_tex: Texture2D = null
				if not cell_layered and cell_data:
					if cell_data.top_sprite:
						cell_tex = cell_data.top_sprite
					elif cell_data.base_sprite:
						cell_tex = cell_data.base_sprite
				if cell_layered:
					pass
				elif cell_tex:
					var draw_rot: int = (cell_rot + 1) % 4 if cell_data.tags.has("shaft") else cell_rot
					_draw_block_texture(cell_tex, cell_pos, w, h, draw_rot, tint)
				else:
					var color: Color
					if cell_ok:
						color = _get_block_color(cell_block_id)
						color.a = 0.5
					else:
						color = Color(1, 0, 0, 0.4)
					draw_rect(Rect2(cell_pos, Vector2(w, h)), color, true)
					draw_rect(Rect2(cell_pos, Vector2(w, h)), color.lightened(0.2), false, 2.0)

			if _is_directional(cell_block_id) and not cell_is_belt and not (cell_data and (cell_data.top_sprite or cell_data.base_sprite)):
				var cell_rot: int = preview_rots.get(cell, main.placement_rotation)
				var center: Vector2 = cell_world + Vector2(
					main.GRID_SIZE * cell_grid_w / 2.0,
					main.GRID_SIZE * cell_grid_h / 2.0
				) + cell_offset
				var arrow_color = Color(1, 1, 1, 0.8) if cell_ok else Color(1, 0.3, 0.3, 0.6)
				_draw_direction_arrow(center, cell_rot, arrow_color)
			# Front-cell orange arrow — drawn for ALL directional previews
			# (textured and belts included). Lands on the cell one tile
			# past the front face so the player sees exactly where the
			# block will eject to.
			if _is_directional(cell_block_id):
				var dl_grid_size: Vector2i = cell_data.grid_size if cell_data else Vector2i(cell_grid_w, cell_grid_h)
				var dl_rot: int = preview_rots.get(cell, main.placement_rotation)
				_draw_front_direction_arrow(cell, dl_grid_size, dl_rot)

			# Turret heads / chassis preview: only the selected block shows
			# these, not junction/bridge substitutions. Skipped when the
			# bake path already painted the heads.
			if cell_block_id == main.selected_building and cell_data and cell_data.is_turret() and not cell_used_bake:
				var t_rot_dl: int = preview_rots.get(cell, main.placement_rotation)
				var t_tint_dl: Color = Color(1, 1, 1, 0.6) if cell_ok else Color(1, 0.3, 0.3, 0.5)
				_draw_turret_preview_heads(cell_data, cell_pos, w, h, t_rot_dl, t_tint_dl)
			# Crane preview overlay — only the selected crane shows the
			# arm silhouette, not junction/bridge substitutions.
			if cell_block_id == main.selected_building and cell_data and cell_data.tags.has("crane"):
				var c_tint_dl: Color = Color(1, 1, 1, 0.6) if cell_ok else Color(1, 0.3, 0.3, 0.5)
				_draw_crane_preview(cell_pos, w, h, c_tint_dl)
			# Drill/crusher heads preview: only the selected block shows
			# these, not junction/bridge substitutions.
			if cell_block_id == main.selected_building and data and data.tags.has("drill_heads"):
				var dh_rot: int = preview_rots.get(cell, main.placement_rotation)
				var dh_variant: String = "N"
				if cell_ok:
					dh_variant = _get_drill_head_variant(cell, dh_rot, data.grid_size)
				var dh_tint: Color = Color(1, 1, 1, 0.6) if cell_ok else Color(1, 0.3, 0.3, 0.5)
				_draw_drill_heads(cell, dh_rot, data.grid_size, dh_variant, main.selected_building, dh_tint)
			if cell_block_id == main.selected_building and data and data.tags.has("crusher_heads"):
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

	# Function-scope flag: set true when a baked composite painted all
	# the layered content (body + heads, etc.), so the downstream
	# turret-heads draw doesn't double-stamp.
	var hover_used_bake := false
	# Draw belt / duct texture preview or fallback rectangle
	var is_belt_hover: bool = (main.selected_building == &"conveyor_belt" and not _belt_textures.is_empty()) \
			or (main.selected_building == &"duct" and not _duct_textures.is_empty())
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
		# Prefer the world-facing top_sprite; data.icon is UI-only and
		# intentionally skipped here.
		var hover_tex: Texture2D = null
		var hover_layered := false
		# Vent turbine / condenser: custom multi-layer preview (base +
		# inner discs) matching the live render — overrides the generic
		# single-sprite preview that would otherwise just show
		# `top_sprite` (or, for the condenser, the pump fallback).
		if main.selected_building == &"vent_turbine":
			_draw_vent_turbine_preview(top_pos, width, height, tint)
			hover_layered = true
		elif main.selected_building == &"vent_condenser":
			_draw_vent_condenser_preview(top_pos, width, height, tint)
			hover_layered = true
		# Cores + turrets paint a pre-baked composite (base + faction
		# overlay for cores; body + chassis + heads for turrets). Falls
		# back to the standard layered-draw path while the bake is still
		# resolving on first use.
		elif data and (data.tags.has("core") or data.is_turret()):
			var composite_info: Dictionary = _request_preview_composite(main.selected_building, hover_rot)
			if not composite_info.is_empty():
				draw_texture_rect(
					composite_info["tex"],
					Rect2(top_pos + composite_info["rect_offset"], composite_info["rect_size"]),
					false, tint)
				hover_layered = true
				hover_used_bake = true
			elif data.base_sprite and data.top_sprite:
				_draw_block_texture(data.base_sprite, top_pos, width, height, hover_rot, tint)
				_draw_block_texture(data.top_sprite, top_pos, width, height, hover_rot, tint)
				hover_layered = true
			elif data.base_sprite:
				_draw_block_texture(data.base_sprite, top_pos, width, height, hover_rot, tint)
				if data.lumina_overlay:
					var ow: float = width * 0.7
					var oh: float = height * 0.7
					var op: Vector2 = top_pos + Vector2((width - ow) * 0.5, (height - oh) * 0.5)
					_draw_block_texture(data.lumina_overlay, op, ow, oh, hover_rot, tint)
				hover_layered = true
		elif data and data.base_sprite and data.top_sprite:
			var draw_rot_l: int = (hover_rot + 1) % 4 if data.tags.has("shaft") else hover_rot
			_draw_block_texture(data.base_sprite, top_pos, width, height, draw_rot_l, tint)
			_draw_block_texture(data.top_sprite, top_pos, width, height, draw_rot_l, tint)
			hover_layered = true
		elif data and data.base_sprite and (data.feed_overlay_back or data.feed_overlay_left or data.feed_overlay_right):
			var draw_rot_l: int = (hover_rot + 1) % 4 if data.tags.has("shaft") else hover_rot
			_draw_block_texture(data.base_sprite, top_pos, width, height, draw_rot_l, tint)
			if data.feed_overlay_back:
				_draw_block_texture(data.feed_overlay_back, top_pos, width, height, draw_rot_l, tint)
			hover_layered = true
		elif data:
			if data.top_sprite:
				hover_tex = data.top_sprite
			elif data.base_sprite:
				hover_tex = data.base_sprite
		if hover_tex:
			var draw_rot: int = (hover_rot + 1) % 4 if data.tags.has("shaft") else hover_rot
			_draw_block_texture(hover_tex, top_pos, width, height, draw_rot, tint)
		elif not hover_layered:
			if cell_ok:
				color.a = 0.5
			else:
				color = Color(1, 0, 0, 0.4)
			draw_rect(Rect2(top_pos, Vector2(width, height)), color, true)
			draw_rect(Rect2(top_pos, Vector2(width, height)), color.lightened(0.2), false, 2.0)

	if is_dir and not is_belt_hover and not (data and (data.top_sprite or data.base_sprite)):
		var center = world_pos + Vector2(
			main.GRID_SIZE * grid_w / 2.0,
			main.GRID_SIZE * grid_h / 2.0
		) + offset
		var arrow_color = Color(1, 1, 1, 0.8) if can_place else Color(1, 0.3, 0.3, 0.6)
		_draw_direction_arrow(center, main.placement_rotation, arrow_color)
	# Front-cell orange arrow — drawn for ALL directional previews
	# (textured and belts included) so the player can see exactly
	# where the block will eject to.
	if is_dir and data:
		_draw_front_direction_arrow(preview_grid_pos, data.grid_size, main.placement_rotation)

	# Turret heads / chassis preview overlay (mirrors the drag-line path
	# below). Drawn after base/top so the heads sit on top of the body.
	# Skipped when the bake path already painted the heads as part of
	# the composite — otherwise the heads would render twice.
	if data and data.is_turret() and not hover_used_bake:
		var t_tint: Color = Color(1, 1, 1, 0.6) if can_place else Color(1, 0.3, 0.3, 0.5)
		_draw_turret_preview_heads(data, top_pos, width, height, main.placement_rotation, t_tint)

	# Crane preview: arm + grabber + base pivot at the default pose so
	# the player sees the silhouette before placing.
	if data and data.tags.has("crane"):
		var c_tint: Color = Color(1, 1, 1, 0.6) if can_place else Color(1, 0.3, 0.3, 0.5)
		_draw_crane_preview(top_pos, width, height, c_tint)

	# Turret attack-range circle in the placement preview — dashed, same
	# look as the hover-over-existing-turret indicator.
	if data and data.is_turret() and data.attack_range > 0.0:
		var range_center: Vector2 = top_pos + Vector2(width * 0.5, height * 0.5)
		var range_px: float = data.attack_range * float(main.GRID_SIZE)
		_draw_dashed_circle(range_center, range_px, Color(1, 1, 1, 0.85), 3.0)

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

	# Extractor efficiency readout — preview-only. A white tick the width
	# of the block sits just above its top edge with "[icon] NN%(N.N/s)"
	# centered over it, so the player sees both the percentage and the
	# concrete throughput for a candidate placement before committing.
	# Not drawn after placement — the live readout would clutter every
	# drill on the map.
	if data and _logistics and (data.category == BlockData.BlockCategory.EXTRACTORS or data.tags.has("pump")) \
			and _logistics.has_method("compute_extractor_preview_efficiency"):
		var pv_eff: float = _logistics.compute_extractor_preview_efficiency(preview_grid_pos, data, main.placement_rotation)
		var pv_w: float = float(main.GRID_SIZE) * grid_w
		var pv_line_y: float = world_pos.y - 6.0
		draw_line(Vector2(world_pos.x, pv_line_y), Vector2(world_pos.x + pv_w, pv_line_y), Color.WHITE, 2.0)
		var pv_font: Font = ThemeDB.fallback_font
		if pv_font:
			var out_info: Dictionary = {"item_id": StringName(""), "per_sec": 0.0}
			if _logistics.has_method("compute_extractor_preview_output"):
				out_info = _logistics.compute_extractor_preview_output(preview_grid_pos, data, main.placement_rotation)
			var per_sec: float = float(out_info.get("per_sec", 0.0))
			var pv_text := "%d%%(%.2f/s)" % [int(round(pv_eff * 100.0)), per_sec]
			var pv_font_size: int = 12
			var text_w: float = pv_font.get_string_size(pv_text, HORIZONTAL_ALIGNMENT_LEFT, -1, pv_font_size).x
			var icon_size: float = 16.0
			var icon_gap: float = 3.0
			var item_id: StringName = StringName(out_info.get("item_id", &""))
			var icon_tex: Texture2D = null
			if item_id != &"":
				var item_d = Registry.get_item(item_id)
				if item_d and item_d.icon:
					icon_tex = item_d.icon
				else:
					var fluid_d = Registry.get_fluid(item_id)
					if fluid_d and fluid_d.icon:
						icon_tex = fluid_d.icon
			var total_w: float = text_w + (icon_size + icon_gap if icon_tex else 0.0)
			var center_x: float = world_pos.x + pv_w * 0.5
			var draw_x: float = center_x - total_w * 0.5
			# draw_string anchors to the BASELINE, so position the text
			# slightly below the icon's vertical center for visual balance.
			var baseline_y: float = pv_line_y - 4.0
			if icon_tex:
				var icon_y: float = baseline_y - pv_font_size * 0.85
				draw_texture_rect(icon_tex,
					Rect2(Vector2(draw_x, icon_y), Vector2(icon_size, icon_size)), false)
				draw_x += icon_size + icon_gap
			draw_string(pv_font, Vector2(draw_x, baseline_y), pv_text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, pv_font_size, Color.WHITE)

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


## Walks placed buildings to figure out which archives are *currently*
## under a powered scanner. Returns a dict of anchor → {scanner_rot, data}.
func _scan_active_archives() -> Dictionary:
	var power_sys = get_node_or_null("/root/Main/PowerSystem")
	var scanned: Dictionary = {}
	for grid_pos in main.placed_buildings:
		if main.building_origins.get(grid_pos, grid_pos) != grid_pos:
			continue
		var data = Registry.get_block(main.placed_buildings[grid_pos])
		if data == null or not data.tags.has("archive_scanner"):
			continue
		if power_sys and not power_sys.is_electrical_powered(grid_pos):
			continue
		var rot: int = main.building_rotation.get(grid_pos, 0)
		var front_cells: Array[Vector2i] = _get_front_edge(grid_pos, data.grid_size, rot)
		for cell in front_cells:
			if not main.placed_buildings.has(cell):
				continue
			var a_anchor: Vector2i = main.building_origins.get(cell, cell)
			var a_data = Registry.get_block(main.placed_buildings.get(a_anchor, &""))
			if a_data == null or a_data.id != &"archive":
				continue
			var aid: StringName = archive_holdings.get(a_anchor, &"")
			if aid == &"" or TechTree.is_researched(aid):
				continue
			if scanned.has(a_anchor):
				continue
			scanned[a_anchor] = {"scanner_rot": rot, "data": a_data}
			break
	return scanned


## Steps every fade entry toward 1.0 (when currently scanned) or 0.0
## (when not). Removes entries that have fully faded out so the dict
## doesn't accumulate stale keys, and refreshes the cached scanner
## rotation / archive data while a scan is live so the box / line
## continues to track the right cell as long as it's visible.
func _tick_archive_scan_fade(delta: float) -> void:
	var scanned: Dictionary = _scan_active_archives()
	# Bring fade UP for currently-scanned archives; refresh their cached
	# rotation + data so the overlay tracks rebinds.
	for a_anchor in scanned:
		var info: Dictionary = scanned[a_anchor]
		var entry: Dictionary = _archive_scan_fade.get(a_anchor, {})
		entry["alpha"] = minf(float(entry.get("alpha", 0.0)) + delta * _ARCHIVE_SCAN_FADE_RATE, 1.0)
		entry["scanner_rot"] = int(info["scanner_rot"])
		entry["data"] = info["data"]
		_archive_scan_fade[a_anchor] = entry
	# Decay anyone NOT in the active set; drop entries that have
	# finished fading out.
	for a_anchor in _archive_scan_fade.keys():
		if scanned.has(a_anchor):
			continue
		var entry: Dictionary = _archive_scan_fade[a_anchor]
		var new_a: float = maxf(float(entry.get("alpha", 0.0)) - delta * _ARCHIVE_SCAN_FADE_RATE, 0.0)
		if new_a <= 0.0:
			_archive_scan_fade.erase(a_anchor)
		else:
			entry["alpha"] = new_a
			_archive_scan_fade[a_anchor] = entry


## Renders the purple scan box + sweeping reveal line for every archive
## tracked in `_archive_scan_fade`, scaled by the per-anchor fade alpha
## so the overlay smoothly fades in when a scanner activates and fades
## out when the scanner is destroyed, depowered, or its archive gets
## decoded.
func _draw_archive_scan_overlay() -> void:
	if _archive_scan_fade.is_empty():
		return
	var gs := float(main.GRID_SIZE)
	# Triangle-wave sweep: ping-pongs from one edge to the other and
	# back again over `_ARCHIVE_SCAN_PERIOD * 2` seconds.
	var saw: float = fposmod(_archive_scan_phase / _ARCHIVE_SCAN_PERIOD, 2.0)
	var sweep_pct: float = saw if saw <= 1.0 else 2.0 - saw

	for a_anchor in _archive_scan_fade:
		var entry: Dictionary = _archive_scan_fade[a_anchor]
		var alpha: float = float(entry.get("alpha", 0.0))
		if alpha <= 0.0:
			continue
		var a_data: BlockData = entry.get("data")
		if a_data == null:
			# Entry kept around for fade-out after data went stale —
			# fall back to whatever's at the anchor right now.
			a_data = Registry.get_block(main.placed_buildings.get(a_anchor, &""))
			if a_data == null:
				continue
		var scanner_rot: int = int(entry.get("scanner_rot", 0))
		var world_pos: Vector2 = main.grid_to_world(a_anchor)
		var w: float = a_data.grid_size.x * gs
		var h: float = a_data.grid_size.y * gs
		var rect := Rect2(world_pos, Vector2(w, h))
		var box_color := Color(0.7, 0.35, 1.0, alpha)
		var fill_color := Color(0.7, 0.35, 1.0, 0.12 * alpha)
		draw_rect(rect, fill_color, true)
		draw_rect(rect, box_color, false, 2.0)
		if scanner_rot == 0 or scanner_rot == 2:
			var line_x: float = world_pos.x + w * sweep_pct
			draw_line(
				Vector2(line_x, world_pos.y),
				Vector2(line_x, world_pos.y + h),
				box_color,
				2.0,
			)
		else:
			var line_y: float = world_pos.y + h * sweep_pct
			draw_line(
				Vector2(world_pos.x, line_y),
				Vector2(world_pos.x + w, line_y),
				box_color,
				2.0,
			)


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
		# Turret heads on the destroyed-building ghost so rebuild mode
		# previews the original orientation, not just a flat rectangle.
		if data.is_turret():
			var rb_rot: int = int(info.get("rotation", 0))
			_draw_turret_preview_heads(data, top_pos, w, h, rb_rot, Color(1, 1, 1, 0.2))

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
				# LUMINA + DERELICT are both deconstructable. Live FEROX
				# stays off-limits — unit combat handles those.
				var rect_faction: int = main.get_building_faction(cell)
				if rect_faction != FACTION_LUMINA and rect_faction != FACTION_DERELICT:
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
	# Remove this crane's link plan AND any references to it from other
	# cranes' inputs/outputs (block-kind specs that point at this anchor).
	if crane_links.has(_grid_pos):
		crane_links.erase(_grid_pos)
	for ca in crane_links.keys():
		var ce: Dictionary = crane_links[ca]
		for arr_key in ["inputs", "outputs"]:
			var arr: Array = ce.get(arr_key, [])
			for i in range(arr.size() - 1, -1, -1):
				var spec: Dictionary = arr[i]
				if spec.get("kind", "") == "block" and Vector2i(spec.get("pos", Vector2i.ZERO)) == _grid_pos:
					arr.remove_at(i)
	if _crane_link_anchor == _grid_pos:
		_crane_link_anchor = Vector2i(-1, -1)
		_crane_link_next_kind = "input"
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
## Renders a single payload at `pos` (rotated by `angle` for buildings).
## When the payload is a crane carrying its own held_payload (because
## another crane picked it up mid-haul), recurses with a smaller scale
## so the player can see what's nested inside the grabber.
##   `gs`    — current grid size in pixels.
##   `scale` — multiplier on the visible footprint, lets the recursive
##             call shrink the inner payload so it visibly sits "inside"
##             the outer crane's icon.
func _draw_crane_payload(payload: Dictionary, pos: Vector2, angle: float, gs: float, scale: float) -> void:
	if payload == null or payload.is_empty():
		return
	var c: CanvasItem = _ccanvas()
	var ptype: String = payload.get("type", "")
	if ptype == "building":
		var block_data = Registry.get_block(StringName(payload.get("block_id", "")))
		if block_data == null:
			return
		var bw: float = block_data.grid_size.x * gs * scale
		var bh: float = block_data.grid_size.y * gs * scale
		var visual_angle: float = angle + PI / 2.0
		if block_data.tags.has("shaft"):
			visual_angle += PI / 2.0
		var is_turret: bool = block_data.is_turret() and block_data.turret_head_sprite != null
		# Turrets need head positions to come from the saved aim angles,
		# not the rot=0 bake — otherwise the heads "reset" to a neutral
		# pose the moment the crane closes. Bake covers chassis-only
		# blocks (cores, vents); turrets fall through to icon + manual
		# head overlay below.
		var composite_info: Dictionary = {}
		if not is_turret:
			composite_info = _request_preview_composite(block_data.id, 0)
		if not composite_info.is_empty():
			var rs: Vector2 = composite_info["rect_size"]
			c.draw_set_transform(pos, visual_angle, Vector2(scale, scale))
			c.draw_texture_rect(composite_info["tex"], Rect2(-rs.x / 2.0, -rs.y / 2.0, rs.x, rs.y), false, Color(1, 1, 1, 1.0))
			c.draw_set_transform(Vector2.ZERO, 0.0)
		elif block_data.icon:
			c.draw_set_transform(pos, visual_angle)
			c.draw_texture_rect(block_data.icon, Rect2(-bw / 2.0, -bh / 2.0, bw, bh), false, Color(1, 1, 1, 1.0))
			c.draw_set_transform(Vector2.ZERO, 0.0)
		else:
			c.draw_rect(Rect2(pos.x - bw / 2.0, pos.y - bh / 2.0, bw, bh), Color(block_data.color.r, block_data.color.g, block_data.color.b, 1.0), true)
		# Manual turret head overlay at the saved aim angle so the heads
		# stay glued to whatever direction they were pointing — and
		# anchored to the rotated icon's local frame so the chassis +
		# head visually move together.
		if is_turret:
			var saved_aim: float = float(payload.get("turret_aim_angle", 0.0))
			var saved_barrels: Array = payload.get("turret_barrel_angles", [])
			# Convert the saved world-space aim into a head offset from
			# the chassis (i.e. "where was the head pointing relative
			# to the body when picked up?"). The held chassis points
			# along `angle` in world space, so the held head sits at
			# `angle + offset` — and the relative pose is preserved
			# even though the held block tumbles with the grabber.
			var rot_at_pickup: int = int(payload.get("rotation", 0))
			var chassis_at_pickup: float = float(rot_at_pickup) * (PI / 2.0)
			var head_offset: float = wrapf(saved_aim - chassis_at_pickup, -PI, PI)
			var aim_world: float = angle + head_offset
			var barrel_world: Array = []
			for b in saved_barrels:
				barrel_world.append(angle + wrapf(float(b) - chassis_at_pickup, -PI, PI))
			_draw_held_turret_heads_at(block_data, pos, aim_world, barrel_world, scale)
		# If this building is itself a crane, draw a scaled-down version
		# of its arm + grabber so the player can see where its head was
		# when it got picked up. If it was holding something, that inner
		# payload renders at the inner grabber's head position. Recurses
		# for nested cranes (crane → crane → …).
		if block_data.tags.has("crane"):
			var inner_state: Dictionary = payload.get("crane_state", {})
			if not inner_state.is_empty():
				# Reuse the same draw path placed cranes use, rooted at
				# the held icon's center and rotated by the outer
				# grabber so the inner pose follows the held block.
				_draw_crane_pose(inner_state, block_data, pos, gs, angle)
	elif ptype == "unit":
		var unit_data = Registry.get_unit(StringName(payload.get("unit_id", "")))
		# Held units render slightly smaller than their on-foot footprint so
		# they visibly read as "cargo" inside the grabber instead of bumping
		# up against the block icon they're nested with.
		var held_unit_scale: float = 0.85
		var unit_visual: float = gs * scale * held_unit_scale
		# Saved poses from the moment of pickup. `facing_angle` is the
		# chassis/body rotation, `aim_angle` is the head rotation —
		# both world-space at pickup time. Held draw rotates them with
		# the outer grabber so the unit reads as being carried in its
		# original pose.
		var saved_facing: float = float(payload.get("facing_angle", 0.0))
		var saved_aim: float = float(payload.get("aim_angle", saved_facing))
		var head_offset_u: float = wrapf(saved_aim - saved_facing, -PI, PI)
		var body_world: float = angle
		var head_world: float = body_world + head_offset_u
		if unit_data:
			if unit_data.base_sprite or unit_data.head_sprite:
				if unit_data.base_sprite:
					var bt_size: Vector2 = _fit_texture_size(unit_data.base_sprite, unit_visual)
					c.draw_set_transform(pos, body_world + PI / 2.0)
					c.draw_texture_rect(unit_data.base_sprite, Rect2(-bt_size * 0.5, bt_size), false, Color(1, 1, 1, 1.0))
					c.draw_set_transform(Vector2.ZERO, 0.0)
				if unit_data.head_sprite:
					var h_size: Vector2 = _fit_texture_size(unit_data.head_sprite, unit_visual)
					c.draw_set_transform(pos, head_world + PI / 2.0)
					c.draw_texture_rect(unit_data.head_sprite, Rect2(-h_size * 0.5, h_size), false, Color(1, 1, 1, 1.0))
					c.draw_set_transform(Vector2.ZERO, 0.0)
			elif unit_data.icon:
				var tex_size: Vector2 = _fit_texture_size(unit_data.icon, unit_visual)
				c.draw_set_transform(pos, body_world + PI / 2.0)
				c.draw_texture_rect(unit_data.icon, Rect2(-tex_size * 0.5, tex_size), false, Color(1, 1, 1, 1.0))
				c.draw_set_transform(Vector2.ZERO, 0.0)
			else:
				var us: float = (unit_data.visual_size if unit_data.visual_size > 0 else 8.0) * scale * held_unit_scale
				var uc: Color = unit_data.color if unit_data.color != Color() else Color(0.5, 0.8, 0.3)
				uc.a = 1.0
				c.draw_circle(pos, us, uc)
				c.draw_arc(pos, us, 0, TAU, 24, uc.lightened(0.3), 1.5)
		else:
			c.draw_circle(pos, 8.0 * scale * held_unit_scale, Color(0.3, 0.5, 0.9, 1.0))


## Draws every active cable-node / cable-tower connection onto
## `canvas`. Hosted on the `_cable_overlay` child (z 52) so the wires
## render above the LogisticsSystem layer (51) and items running on
## conveyors underneath a cable line never visually clip the wire.
func _draw_cable_links(canvas: CanvasItem) -> void:
	var power_sys = get_node_or_null("/root/Main/PowerSystem")
	if power_sys == null:
		return
	if _wire_texture == null:
		return
	if not ("cable_connections" in power_sys):
		return
	var _ss_link = get_node_or_null("/root/Main/SectorScript")
	var gs: float = main.GRID_SIZE
	var half_tile := Vector2(gs / 2.0, gs / 2.0)
	var cable_tint := Color(1.0, 1.0, 1.0, 1.0)
	var wire_scale := 1.0
	var tex_w: float = 15.0 * main.SPRITE_SCALE_FACTOR
	var tex_h: float = _wire_texture.get_height()
	var draw_w: float = tex_w * wire_scale
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
			canvas.draw_set_transform(center, angle)
			var src := Rect2(0, 0, tex_w, this_len)
			canvas.draw_texture_rect_region(_wire_texture, Rect2(-hw, -this_len / 2.0, draw_w, this_len), src, cable_tint)
			canvas.draw_set_transform(Vector2.ZERO, 0.0)


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

	# Cable wires are now drawn by `_cable_overlay` (z 52, above the
	# LogisticsSystem layer at 51) so items running on conveyors
	# underneath a cable line don't render on top of the wire.
	# `_draw_cable_links(canvas)` is the shared implementation; the
	# overlay calls it with itself as the target canvas.

	# --- Mindustry-style linking highlights ---
	# Colors describe ROLE in the link, not which side was clicked:
	#   yellow = INPUT  (pair[0], the block that initiated the link)
	#   blue   = OUTPUT (pair[1], the partner)
	# So clicking either end of an existing pair shows the same coloring.
	# When a block is selected with no existing link yet, paint it yellow
	# (it's about to become the input of a new link).
	if link_source == Vector2i(-1, -1):
		return

	var src_data: BlockData = Registry.get_block(main.placed_buildings.get(link_source, &""))
	if src_data == null:
		return

	# Find the pair this block belongs to so we know which side is input
	# vs output. Falls back to "no pair yet" if it's a brand-new selection.
	var input_anchor: Vector2i = link_source
	var output_anchor: Vector2i = Vector2i(-1, -1)
	if power_sys and "linked_pairs" in power_sys:
		for pair in power_sys.linked_pairs:
			var pa: Vector2i = main.building_origins.get(pair[0], pair[0])
			var pb: Vector2i = main.building_origins.get(pair[1], pair[1])
			if pa == link_source or pb == link_source:
				input_anchor = pa
				output_anchor = pb
				break

	var draw_block_highlight := func(a: Vector2i, fill: Color, outline: Color):
		var bd: BlockData = Registry.get_block(main.placed_buildings.get(a, &""))
		if bd == null:
			return
		var wp: Vector2 = main.grid_to_world(a)
		var off = _get_top_offset(wp)
		var rp: Vector2 = wp + off
		var bw: float = bd.grid_size.x * gs
		var bh: float = bd.grid_size.y * gs
		draw_rect(Rect2(rp, Vector2(bw, bh)), fill, true)
		draw_rect(Rect2(rp, Vector2(bw, bh)), outline, false, 2.0)

	var yellow_fill := Color(1.0, 0.85, 0.2, 0.35)
	var yellow_outline := Color(1.0, 0.95, 0.4, 0.9)
	var blue_fill := Color(0.3, 0.7, 1.0, 0.35)
	var blue_outline := Color(0.5, 0.85, 1.0, 0.9)

	draw_block_highlight.call(input_anchor, yellow_fill, yellow_outline)
	if output_anchor != Vector2i(-1, -1):
		draw_block_highlight.call(output_anchor, blue_fill, blue_outline)

	# Dashed yellow line from source to the mouse so the player can see
	# where their next click will go.
	var src_world: Vector2 = main.grid_to_world(link_source) \
		+ Vector2(src_data.grid_size.x * gs / 2.0, src_data.grid_size.y * gs / 2.0)
	src_world += _get_top_offset(main.grid_to_world(link_source))
	_draw_dashed_line(src_world, get_global_mouse_position(),
		Color(1.0, 0.9, 0.3, 0.6), 2.0, 6.0)

	# Range circle: shows the block's `link_range` (in tiles) as a faint
	# disc the player can use to gauge where a partner is reachable.
	if src_data.link_range > 0.0:
		draw_arc(src_world, src_data.link_range * gs, 0.0, TAU, 96,
			Color(1.0, 0.9, 0.3, 0.5), 1.5)


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

	# Re-anchor on the actual topmost-leftmost block. Captures stored
	# rels relative to the user's drag-rect corner, so empty rows/cols
	# above or to the left of the schematic's content would shift the
	# cursor off the block and silently break the top-left placement.
	var raw: Array[Vector2i] = []
	for key in blocks_data:
		var parts: PackedStringArray = key.split(",")
		if parts.size() >= 2:
			raw.append(Vector2i(int(parts[0]), int(parts[1])))
	var min_x: int = 0
	var min_y: int = 0
	if not raw.is_empty():
		min_x = raw[0].x
		min_y = raw[0].y
		for p in raw:
			if p.x < min_x: min_x = p.x
			if p.y < min_y: min_y = p.y

	for key in blocks_data:
		var parts2: PackedStringArray = key.split(",")
		if parts2.size() >= 2:
			var pos := Vector2i(int(parts2[0]) - min_x, int(parts2[1]) - min_y)
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
		var slot_tint: Color
		if slot_ok:
			color.a = 0.4
			draw_rect(Rect2(top_pos, Vector2(w, h)), color, true)
			draw_rect(Rect2(top_pos, Vector2(w, h)), Color(0.3, 1.0, 0.3, 0.6), false, 1.5)
			slot_tint = Color(1, 1, 1, 0.6)
		else:
			color = Color(1.0, 0.3, 0.3, 0.3)
			draw_rect(Rect2(top_pos, Vector2(w, h)), color, true)
			draw_rect(Rect2(top_pos, Vector2(w, h)), Color(1.0, 0.3, 0.3, 0.6), false, 1.5)
			slot_tint = Color(1, 0.3, 0.3, 0.5)
		# Turret heads / chassis ghost so a schematic with turrets visibly
		# previews barrels in the right direction before the player commits.
		if data.is_turret():
			var t_rot: int = int(_schematic_place_rotation.get(rel_pos, 0))
			_draw_turret_preview_heads(data, top_pos, w, h, t_rot, slot_tint)


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

## Returns the world-space head/grabber position of a crane right now.
func crane_head_world(anchor: Vector2i) -> Vector2:
	if not crane_states.has(anchor):
		return Vector2.ZERO
	var state: Dictionary = crane_states[anchor]
	var data = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if data == null:
		return Vector2.ZERO
	var gs: float = main.GRID_SIZE
	var base: Vector2 = main.grid_to_world(anchor) + Vector2(data.grid_size.x * gs / 2.0, data.grid_size.y * gs / 2.0)
	var arm_angle: float = state.get("arm_angle", 0.0)
	var ext: float = state.get("arm_extension", CRANE_ARM_MIN_TOTAL)
	var arm_dir: Vector2 = Vector2(cos(arm_angle), sin(arm_angle))
	var tp_v = state.get("target_pos", base)
	var target: Vector2 = tp_v if tp_v is Vector2 else base
	var to_target: float = (target - base).length()
	var grabber_t: float = clampf(to_target / ext, 0.0, 1.0) if ext > 1.0 else 1.0
	return base + arm_dir * (grabber_t * ext)


## Walks a crane's nested held-cargo chain and returns the world
## position of the deepest payload — i.e. where the held entity
## actually sits, after every nested crane's saved arm length is
## applied. Without this, crane→crane→block reports the block at the
## outer crane's grabber, capping the effective reach to the outer
## crane's range alone. Each nested crane's saved `arm_angle` is
## taken in the outer pose's local frame and added on top of the
## current cumulative grabber angle, mirroring `_draw_crane_pose`.
## Enumerates every nested held entity in a crane's chain as a separate
## targetable layer. depth=0 is whatever the placed crane is holding
## directly (its centre = the placed crane's grabber); depth=N is the
## thing held by the depth=(N-1) crane (centre = depth=(N-1) crane's
## grabber). Lets enemies shoot at — and destroy — a SPECIFIC layer of
## the chain instead of the whole cargo column collapsing whenever a
## bullet hits the tip.
func collect_held_chain(crane_anchor: Vector2i) -> Array:
	var out: Array = []
	if not crane_states.has(crane_anchor):
		return out
	var state: Dictionary = crane_states[crane_anchor]
	var payload = state.get("held_payload", null)
	if not (payload is Dictionary):
		return out
	var pos: Vector2 = crane_head_world(crane_anchor)
	var outer_g_angle: float = float(state.get("grabber_angle", 0.0))
	var depth: int = 0
	for _i in range(16):
		if not (payload is Dictionary):
			break
		var pdict: Dictionary = payload
		var ptype: String = String(pdict.get("type", ""))
		if ptype == "":
			break
		out.append({"depth": depth, "pos": pos, "payload": pdict})
		if ptype != "building":
			break
		var bd = Registry.get_block(StringName(pdict.get("block_id", "")))
		if bd == null or not bd.tags.has("crane"):
			break
		var inner_state = pdict.get("crane_state", null)
		if not (inner_state is Dictionary) or (inner_state as Dictionary).is_empty():
			break
		var ist: Dictionary = inner_state
		var inner_arm_angle: float = float(ist.get("arm_angle", 0.0)) + outer_g_angle
		var inner_ext: float = float(ist.get("arm_extension", CRANE_ARM_MIN_TOTAL))
		pos = pos + Vector2(cos(inner_arm_angle), sin(inner_arm_angle)) * inner_ext
		outer_g_angle = wrapf(outer_g_angle + float(ist.get("grabber_angle", 0.0)), -PI, PI)
		payload = ist.get("held_payload", null)
		depth += 1
	return out


## World position of the held entity at `depth` in `crane_anchor`'s
## chain (0 = directly held). Returns Vector2.ZERO if the depth is
## past the chain length.
func held_entity_world_at_depth(crane_anchor: Vector2i, depth: int) -> Vector2:
	var chain: Array = collect_held_chain(crane_anchor)
	if depth < 0 or depth >= chain.size():
		return Vector2.ZERO
	return chain[depth]["pos"]


## Returns the payload Dictionary at `depth` in the chain (mutable
## reference into the crane state, so callers can write back to e.g.
## `health` or `internal_battery_charge`).
func get_held_payload_at_depth(crane_anchor: Vector2i, depth: int) -> Dictionary:
	if not crane_states.has(crane_anchor):
		return {}
	if depth < 0:
		return {}
	var payload = (crane_states[crane_anchor] as Dictionary).get("held_payload", null)
	for _i in range(16):
		if not (payload is Dictionary):
			return {}
		if depth == 0:
			return payload
		var pdict: Dictionary = payload
		if String(pdict.get("type", "")) != "building":
			return {}
		var inner_state = pdict.get("crane_state", null)
		if not (inner_state is Dictionary):
			return {}
		payload = (inner_state as Dictionary).get("held_payload", null)
		depth -= 1
	return {}


func held_entity_world(crane_anchor: Vector2i) -> Vector2:
	if not crane_states.has(crane_anchor):
		return Vector2.ZERO
	var pos: Vector2 = crane_head_world(crane_anchor)
	var outer_g_angle: float = float((crane_states[crane_anchor] as Dictionary).get("grabber_angle", 0.0))
	var payload = (crane_states[crane_anchor] as Dictionary).get("held_payload", null)
	# Defensive depth cap — pathological save data shouldn't loop.
	for _depth in range(16):
		if not (payload is Dictionary):
			break
		var pdict: Dictionary = payload
		if String(pdict.get("type", "")) != "building":
			break
		var bd = Registry.get_block(StringName(pdict.get("block_id", "")))
		if bd == null or not bd.tags.has("crane"):
			break
		var inner_state = pdict.get("crane_state", null)
		if not (inner_state is Dictionary) or (inner_state as Dictionary).is_empty():
			break
		var ist: Dictionary = inner_state
		var inner_arm_angle: float = float(ist.get("arm_angle", 0.0)) + outer_g_angle
		var inner_ext: float = float(ist.get("arm_extension", CRANE_ARM_MIN_TOTAL))
		pos += Vector2(cos(inner_arm_angle), sin(inner_arm_angle)) * inner_ext
		outer_g_angle = wrapf(outer_g_angle + float(ist.get("grabber_angle", 0.0)), -PI, PI)
		payload = ist.get("held_payload", null)
	return pos


## AI-time target position for `spec` from the perspective of `my_anchor`.
## Crane → crane links return the midpoint between the two cranes' centers
## (so both cranes converging on this same point cause their heads to meet).
## Everything else falls back to the diamond's visual center.
func _crane_ai_target_pos(my_anchor: Vector2i, spec: Dictionary) -> Vector2:
	if spec.get("kind", "") == "block":
		var p: Vector2i = spec.get("pos", Vector2i.ZERO)
		if main.placed_buildings.has(p) and main.placed_buildings.has(my_anchor):
			var bdata = Registry.get_block(main.placed_buildings[p])
			if bdata and bdata.tags.has("crane"):
				var my_data = Registry.get_block(main.placed_buildings[my_anchor])
				if my_data:
					var gs: float = main.GRID_SIZE
					var my_center: Vector2 = main.grid_to_world(my_anchor) + Vector2(my_data.grid_size.x * gs / 2.0, my_data.grid_size.y * gs / 2.0)
					var other_center: Vector2 = main.grid_to_world(p) + Vector2(bdata.grid_size.x * gs / 2.0, bdata.grid_size.y * gs / 2.0)
					return (my_center + other_center) / 2.0
	return _crane_diamond_world_pos(spec)


## Per-frame autonomous AI for cranes that have configured links and aren't
## currently being directly controlled by the player. Crane state machine:
##   - held_payload == null  → seek next available input
##   - held_payload != null  → seek next acceptable output
## When the head is "over" a target tile and the precondition is met, the
## interaction (pickup/drop) fires. Targets are visited in declaration order.
## Routes a projectile hit at the held entity carried by `crane_anchor`
## through the payload's health field. When health reaches 0 the crane
## drops the cargo (clears `held_payload`) and the held entity is gone
## for good — same outcome as a placed turret/unit destruction.
func damage_held_entity(crane_anchor: Vector2i, amount: float, depth: int = 0) -> void:
	if not crane_states.has(crane_anchor):
		return
	var state: Dictionary = crane_states[crane_anchor]
	# Walk to the parent crane state of the targeted layer so we can
	# clear it on death. depth=0 → parent is `state` itself; depth=1 →
	# parent is the inner crane's `crane_state`, etc.
	var parent: Dictionary = state
	for _i in range(depth):
		var pl = parent.get("held_payload", null)
		if not (pl is Dictionary):
			return
		var inner_state = (pl as Dictionary).get("crane_state", null)
		if not (inner_state is Dictionary):
			return
		parent = inner_state
	var payload = parent.get("held_payload", null)
	if not (payload is Dictionary):
		return
	var p: Dictionary = payload
	var hp: float = float(p.get("health", 0.0))
	hp -= amount
	if hp <= 0.0:
		# Cargo destroyed. Whatever WAS held by this layer (deeper
		# nesting, if any) goes with it — same outcome as a placed
		# crane being destroyed mid-haul.
		parent["held_payload"] = null
		parent["grabber_open"] = true
	else:
		p["health"] = hp


## Walks every crane state with a held building payload and ticks the
## payload's internal battery + factory_state. Held blocks keep running
## off their 10B reservoir while detached from any electrical network;
## when the battery is drained, production stalls. Output items merge
## back into the payload's `stored_items` so the dropped block lands
## with whatever it produced en-route.
func _tick_held_payload_simulation(delta: float) -> void:
	if delta <= 0.0:
		return
	var power_sys = get_node_or_null("/root/Main/PowerSystem")
	for anchor in crane_states:
		var state: Dictionary = crane_states[anchor]
		var payload: Variant = state.get("held_payload", null)
		if payload == null or not (payload is Dictionary):
			continue
		var pdict: Dictionary = payload
		if pdict.get("type", "") != "building":
			continue
		_tick_held_building(pdict, delta, power_sys)


## Held-payload tick for a single building. Shared by the autonomous
## crane sim above (so a held block keeps working in transit) and any
## other path that wants to advance a detached factory snapshot.
##
## Drains the payload's `internal_battery_charge` at the block's
## `electrical_power_use` rate. When the battery has charge, factory
## state advances at full speed; when empty, production stalls.
func _tick_held_building(pdict: Dictionary, delta: float, power_sys) -> void:
	var data := Registry.get_block(StringName(pdict.get("block_id", "")))
	if data == null:
		return

	# Battery drain. Power-only blocks (no consumption) skip the
	# drain entirely; they just sit there happily.
	var power_eff: float = 1.0
	if data.electrical_power_use > 0.0:
		var cap: float = 0.0
		if power_sys and power_sys.has_method("resolve_block_battery_capacity"):
			cap = power_sys.resolve_block_battery_capacity(data)
		var charge: float = float(pdict.get("internal_battery_charge", 0.0))
		var needed: float = data.electrical_power_use * delta
		if charge >= needed:
			pdict["internal_battery_charge"] = clampf(charge - needed, 0.0, cap)
		elif charge > 0.0:
			power_eff = charge / maxf(needed, 0.0001)
			pdict["internal_battery_charge"] = 0.0
		else:
			# Battery empty — no production this tick. Inner held cargo
			# (if this is a crane carrying something) still ticks; its
			# own battery is independent.
			power_eff = 0.0

	# Factory advance.
	if power_eff > 0.0 and data.production_time > 0.0 and (not data.input_items.is_empty() or not data.output_items.is_empty()):
		_held_factory_advance(pdict, data, delta * power_eff)

	# Recurse into nested held cargo: a held crane keeps its own
	# `crane_state.held_payload` snapshot. Without this, only the
	# outermost crane's cargo simulates — the second level down would
	# freeze the moment its outer crane was picked up.
	if data.tags.has("crane"):
		var inner_state: Dictionary = pdict.get("crane_state", {})
		if not inner_state.is_empty():
			var inner_payload = inner_state.get("held_payload", null)
			if inner_payload is Dictionary:
				var ipd: Dictionary = inner_payload
				match String(ipd.get("type", "")):
					"building":
						_tick_held_building(ipd, delta, power_sys)


## Minimal off-grid factory advance. Operates on the merged
## `stored_items` buffer the payload carries (factory inputs were folded
## into stored_items at pickup, see main.gd:1709). Outputs land back in
## stored_items so place_payload_building drops them into block_storage.
func _held_factory_advance(pdict: Dictionary, data: BlockData, delta: float) -> void:
	if delta <= 0.0:
		return
	var state: Dictionary = pdict.get("factory_state", {})
	if state.is_empty():
		state = {"phase": "collecting", "timer": 0.0}
		pdict["factory_state"] = state
	var stored: Dictionary = pdict.get("stored_items", {})
	if stored.is_empty() and not data.input_items.is_empty():
		# Nothing to consume.
		return

	var phase: String = String(state.get("phase", "collecting"))
	if phase == "collecting":
		# Held factories don't take new inputs (no conveyors). They run
		# only off whatever was buffered at pickup. If inputs cover one
		# full recipe, kick off processing.
		if _held_factory_has_inputs(stored, data):
			state["phase"] = "processing"
			state["timer"] = data.production_time
			state["timer_total"] = data.production_time
		return

	if phase == "processing":
		var t: float = float(state.get("timer", data.production_time)) - delta
		state["timer"] = t
		if t <= 0.0:
			# Consume one recipe's inputs.
			for item_id in data.input_items:
				var key := String(item_id)
				var have: int = int(stored.get(key, 0))
				stored[key] = maxi(0, have - int(data.input_items[item_id]))
			# Produce outputs.
			for out_id in data.output_items:
				var okey := String(out_id)
				stored[okey] = int(stored.get(okey, 0)) + int(data.output_items[out_id])
			state["phase"] = "collecting"
			state["timer"] = 0.0
		pdict["stored_items"] = stored


func _held_factory_has_inputs(stored: Dictionary, data: BlockData) -> bool:
	for item_id in data.input_items:
		var have: int = int(stored.get(String(item_id), 0))
		if have < int(data.input_items[item_id]):
			return false
	return true


func _tick_autonomous_cranes(delta: float) -> void:
	if crane_states.is_empty():
		return
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	var gs: float = main.GRID_SIZE
	var arrive_radius: float = gs * 0.5

	for anchor in crane_states.keys():
		# Skip if not a real placed crane any more.
		if not main.placed_buildings.has(anchor):
			continue
		# Player-controlled cranes are driven by UnitManager exclusively.
		if unit_mgr and unit_mgr.controlled_type == "crane" and unit_mgr.controlled_entity == anchor:
			continue
		# Even cranes without their own link plan still passively respond
		# to other cranes that have THEM as an output target — the sender's
		# drop logic needs both heads to meet.
		var entry: Dictionary = crane_links.get(anchor, {"inputs": [], "outputs": []})
		var inputs: Array = entry.get("inputs", [])
		var outputs: Array = entry.get("outputs", [])

		var state: Dictionary = crane_states[anchor]
		var data = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null:
			continue
		var base: Vector2 = main.grid_to_world(anchor) + Vector2(data.grid_size.x * gs / 2.0, data.grid_size.y * gs / 2.0)
		var max_reach: float = data.crane_range * gs

		var head_pos: Vector2 = crane_head_world(anchor)

		if state.get("held_payload", null) == null:
			# --- Seeking input ---
			var picked := false
			for spec in inputs:
				var available: bool = _crane_input_has_payload(spec)
				if not available:
					continue
				var t_pos: Vector2 = _crane_ai_target_pos(anchor, spec)
				var t_clamped: Vector2 = _clamp_to_reach(base, t_pos, max_reach)
				state["target_pos"] = t_clamped
				update_crane_telescope(anchor, t_clamped, delta)
				if (head_pos - t_pos).length() <= arrive_radius:
					_crane_autonomous_pickup(anchor, state, head_pos, spec)
				picked = true
				break
			if not picked:
				# No input has a payload yet. Before parking on a ground
				# input, check if any OTHER crane has us configured as an
				# output AND is currently holding — passively rendezvous so
				# the sender's drop logic can fire when both heads meet.
				var sender_anchor: Vector2i = _crane_find_incoming_sender(anchor)
				if sender_anchor != Vector2i(-1, -1):
					var meet: Vector2 = _crane_midpoint(anchor, sender_anchor)
					var meet_clamped: Vector2 = _clamp_to_reach(base, meet, max_reach)
					state["target_pos"] = meet_clamped
					update_crane_telescope(anchor, meet_clamped, delta)
				else:
					# Otherwise park near first ground input (if any), so the
					# head hovers in place waiting for a unit to arrive.
					for spec in inputs:
						if spec.get("kind", "") == "ground":
							var t_pos2: Vector2 = _crane_ai_target_pos(anchor, spec)
							var t_clamped2: Vector2 = _clamp_to_reach(base, t_pos2, max_reach)
							state["target_pos"] = t_clamped2
							update_crane_telescope(anchor, t_clamped2, delta)
							break
		else:
			# --- Seeking output for currently held payload ---
			var payload: Dictionary = state["held_payload"]
			# Prefer the first output that's actually ready to accept right
			# now. If none are ready, fall back to the first filter-matching
			# output and park there (head-over-target, waiting).
			var chosen_spec: Dictionary = {}
			for spec in outputs:
				if not _crane_payload_matches_filter(payload, spec):
					continue
				if _crane_output_ready(spec):
					chosen_spec = spec
					break
			if chosen_spec.is_empty():
				for spec in outputs:
					if _crane_payload_matches_filter(payload, spec):
						chosen_spec = spec
						break
			if not chosen_spec.is_empty():
				var t_pos3: Vector2 = _crane_ai_target_pos(anchor, chosen_spec)
				var t_clamped3: Vector2 = _clamp_to_reach(base, t_pos3, max_reach)
				state["target_pos"] = t_clamped3
				update_crane_telescope(anchor, t_clamped3, delta)
				if (head_pos - t_pos3).length() <= arrive_radius:
					_crane_autonomous_drop(anchor, state, head_pos, chosen_spec)


## Returns the midpoint of two cranes' centers (in world space).
func _crane_midpoint(a_anchor: Vector2i, b_anchor: Vector2i) -> Vector2:
	var gs: float = main.GRID_SIZE
	var a_data = Registry.get_block(main.placed_buildings.get(a_anchor, &""))
	var b_data = Registry.get_block(main.placed_buildings.get(b_anchor, &""))
	if a_data == null or b_data == null:
		return Vector2.ZERO
	var a_c: Vector2 = main.grid_to_world(a_anchor) + Vector2(a_data.grid_size.x * gs / 2.0, a_data.grid_size.y * gs / 2.0)
	var b_c: Vector2 = main.grid_to_world(b_anchor) + Vector2(b_data.grid_size.x * gs / 2.0, b_data.grid_size.y * gs / 2.0)
	return (a_c + b_c) / 2.0


## Finds another crane whose output points at `me` and is currently holding
## a payload (so it's ready to deliver). Returns its anchor or (-1, -1).
func _crane_find_incoming_sender(me: Vector2i) -> Vector2i:
	for other_anchor in crane_states.keys():
		if other_anchor == me:
			continue
		if not crane_links.has(other_anchor):
			continue
		var ostate: Dictionary = crane_states[other_anchor]
		if ostate.get("held_payload", null) == null:
			continue
		var olinks: Dictionary = crane_links[other_anchor]
		for spec in olinks.get("outputs", []):
			if spec.get("kind", "") != "block":
				continue
			if Vector2i(spec.get("pos", Vector2i.ZERO)) == me:
				return other_anchor
	return Vector2i(-1, -1)


func _clamp_to_reach(base: Vector2, target: Vector2, max_reach: float) -> Vector2:
	var d: Vector2 = target - base
	var L: float = d.length()
	if L <= max_reach:
		return target
	if L < 0.01:
		return base + Vector2(max_reach, 0)
	return base + d / L * max_reach


## True iff this crane-link spec currently has a payload available to pick up.
func _crane_input_has_payload(spec: Dictionary) -> bool:
	var kind: String = spec.get("kind", "")
	if kind == "ground":
		# A player unit standing within the diamond is the "available payload".
		var unit_mgr = get_node_or_null("/root/Main/UnitManager")
		if unit_mgr == null:
			return false
		var c: Vector2 = _crane_diamond_world_pos(spec)
		var r: float = main.GRID_SIZE * 1.5
		for u in unit_mgr.player_units:
			if u == null or not is_instance_valid(u):
				continue
			if (u.position - c).length() <= r:
				if _crane_payload_matches_filter({"type": "unit", "unit_id": str(u.data.id) if u.data else ""}, spec):
					return true
		return false
	# kind == "block"
	var p: Vector2i = spec.get("pos", Vector2i.ZERO)
	if not main.placed_buildings.has(p):
		return false
	var bdata = Registry.get_block(main.placed_buildings[p])
	if bdata == null:
		return false
	# Other crane: payload is available when that crane is holding something
	# AND its head is reachable / "meeting" ours.
	if bdata.tags.has("crane"):
		var other_state: Dictionary = crane_states.get(p, {})
		return other_state.get("held_payload", null) != null
	# Mass driver / payload conveyor / router / constructor: rely on
	# logistics_system's payload_items map (the cell holds a stalled payload).
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	if logistics and "payload_items" in logistics:
		if logistics.payload_items.has(p):
			return true
	return false


## True iff dropping a payload at this output spec right now would succeed.
## Used to skip blocked outputs (full conveyor, busy crane, …) so the holding
## crane moves on to the next configured output instead of stalling.
func _crane_output_ready(spec: Dictionary) -> bool:
	var kind: String = spec.get("kind", "")
	if kind == "ground":
		return true
	var p: Vector2i = spec.get("pos", Vector2i.ZERO)
	if not main.placed_buildings.has(p):
		return false
	var bdata = Registry.get_block(main.placed_buildings[p])
	if bdata == null:
		return false
	if bdata.tags.has("crane"):
		# Receiver crane must be empty (transfer fires when heads meet).
		return crane_states.get(p, {}).get("held_payload", null) == null
	# Conveyor / router / mass driver / constructor: ready iff the cell
	# has no stalled payload sitting on it.
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	if logistics and "payload_items" in logistics:
		return not logistics.payload_items.has(p)
	return true


## True iff the held payload is allowed by the spec's filter (empty = any).
func _crane_payload_matches_filter(payload: Dictionary, spec: Dictionary) -> bool:
	var filter: Array = spec.get("filter", [])
	if filter.is_empty():
		return true
	var t: String = payload.get("type", "")
	var pid: StringName = &""
	if t == "unit":
		pid = StringName(payload.get("unit_id", ""))
	elif t == "building":
		pid = StringName(payload.get("block_id", ""))
	return filter.has(pid)


func _crane_autonomous_pickup(anchor: Vector2i, state: Dictionary, head_pos: Vector2, spec: Dictionary) -> void:
	var kind: String = spec.get("kind", "")
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	if kind == "ground":
		if unit_mgr == null:
			return
		var c: Vector2 = _crane_diamond_world_pos(spec)
		var r: float = main.GRID_SIZE * 1.5
		for u in unit_mgr.player_units.duplicate():
			if u == null or not is_instance_valid(u):
				continue
			if (u.position - c).length() > r:
				continue
			if not _crane_payload_matches_filter({"type": "unit", "unit_id": str(u.data.id) if u.data else ""}, spec):
				continue
			var unit_payload := {
				"type": "unit",
				"unit_id": str(u.data.id) if u.data else "",
				"health": u.health,
				"team": u.team if "team" in u else 0,
				# Snapshot the unit's pose so the held draw shows the head
				# pointing where the unit was aiming, and respawning it
				# from the payload restores the same facing.
				"aim_angle": float(u.aim_angle) if "aim_angle" in u else 0.0,
				"facing_angle": float(u.facing_angle) if "facing_angle" in u else 0.0,
			}
			unit_mgr.player_units.erase(u)
			u.queue_free()
			state["held_payload"] = unit_payload
			state["grabber_open"] = false
			return
		return
	# kind == "block"
	var p: Vector2i = spec.get("pos", Vector2i.ZERO)
	if not main.placed_buildings.has(p):
		return
	var bdata = Registry.get_block(main.placed_buildings[p])
	if bdata == null:
		return
	if bdata.tags.has("crane"):
		# Crane-to-crane handoff: only when both heads are coincident.
		var other_state: Dictionary = crane_states.get(p, {})
		if other_state.get("held_payload", null) == null:
			return
		var other_head: Vector2 = crane_head_world(p)
		if (head_pos - other_head).length() > main.GRID_SIZE * 0.6:
			return
		var p2: Dictionary = other_state["held_payload"]
		if not _crane_payload_matches_filter(p2, spec):
			return
		state["held_payload"] = p2
		other_state["held_payload"] = null
		other_state["grabber_open"] = true
		state["grabber_open"] = false
		return
	# Conveyor / router / mass-driver / constructor with stalled payload
	if logistics and "payload_items" in logistics and logistics.payload_items.has(p):
		var pdata: Dictionary = logistics.payload_items[p].get("payload_data", {})
		if not _crane_payload_matches_filter(pdata, spec):
			return
		state["held_payload"] = pdata.duplicate(true)
		logistics.payload_items.erase(p)
		state["grabber_open"] = false

func _crane_autonomous_drop(anchor: Vector2i, state: Dictionary, head_pos: Vector2, spec: Dictionary) -> void:
	var kind: String = spec.get("kind", "")
	var payload: Dictionary = state["held_payload"]
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	if kind == "ground":
		var c: Vector2 = _crane_diamond_world_pos(spec)
		if payload.get("type", "") == "unit":
			# Drop unit at center; spawn via UnitManager.
			if unit_mgr == null:
				return
			var unit_id := StringName(payload.get("unit_id", ""))
			if unit_id != &"":
				unit_mgr.spawn_player_unit(c, unit_id)
				if not unit_mgr.player_units.is_empty():
					var spawned = unit_mgr.player_units[-1]
					if is_instance_valid(spawned):
						spawned.health = float(payload.get("health", spawned.health))
						# Restore the saved pose so the dropped unit
						# resumes facing/aiming the same way it was
						# when picked up, instead of snapping to a
						# default forward.
						if "facing_angle" in spawned and payload.has("facing_angle"):
							spawned.facing_angle = float(payload["facing_angle"])
						if "aim_angle" in spawned and payload.has("aim_angle"):
							spawned.aim_angle = float(payload["aim_angle"])
				state["held_payload"] = null
				state["grabber_open"] = true
		elif payload.get("type", "") == "building":
			# Try to place onto the ground tile (centered on the diamond).
			var grid_target: Vector2i = main.world_to_grid(c)
			var gsx: int = int(payload.get("grid_size_x", 1))
			var gsy: int = int(payload.get("grid_size_y", 1))
			var center_pos := Vector2i(grid_target.x - gsx / 2, grid_target.y - gsy / 2)
			if main.has_method("place_payload_building") and main.place_payload_building(payload, center_pos):
				state["held_payload"] = null
				state["grabber_open"] = true
		return
	# kind == "block"
	var p: Vector2i = spec.get("pos", Vector2i.ZERO)
	if not main.placed_buildings.has(p):
		return
	var bdata = Registry.get_block(main.placed_buildings[p])
	if bdata == null:
		return
	if bdata.tags.has("crane"):
		# Crane-to-crane: hold until receiving crane's head meets ours.
		var other_state: Dictionary = crane_states.get(p, {})
		if other_state.get("held_payload", null) != null:
			return  # they're full, hold
		var other_head: Vector2 = crane_head_world(p)
		if (head_pos - other_head).length() > main.GRID_SIZE * 0.6:
			return
		other_state["held_payload"] = state["held_payload"]
		state["held_payload"] = null
		state["grabber_open"] = true
		other_state["grabber_open"] = false
		return
	# Conveyor / router / mass-driver / constructor: push via logistics.
	if logistics and logistics.has_method("_is_payload_cell") and logistics._is_payload_cell(p):
		if logistics.has_method("_try_push_payload") and logistics._try_push_payload(p, payload):
			state["held_payload"] = null
			state["grabber_open"] = true


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
	var c: CanvasItem = _ccanvas()
	for anchor in crane_states:
		if not main.placed_buildings.has(anchor):
			continue
		var state: Dictionary = crane_states[anchor]
		var data = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null:
			continue
		var gs: float = main.GRID_SIZE
		var base: Vector2 = main.grid_to_world(anchor) + Vector2(data.grid_size.x * gs / 2.0, data.grid_size.y * gs / 2.0)

		_draw_crane_pose(state, data, base, gs, 0.0)

		# Draw range circle when controlled
		if unit_mgr and unit_mgr.controlled_type == "crane" and unit_mgr.controlled_entity == anchor:
			var range_px: float = data.crane_range * gs
			c.draw_arc(base, range_px, 0, TAU, 64, Color(0.4, 0.8, 0.4, 0.15), 1.5)


## Returns the canvas crane drawing should target — `_crane_draw_canvas`
## when `_crane_overlay` is invoking us, otherwise `self` for any
## legacy code path that still calls the helpers from `_draw`.
func _ccanvas() -> CanvasItem:
	return _crane_draw_canvas if _crane_draw_canvas != null else self


## Renders a crane's three telescoping segments + grabber + held payload
## given a `state` dictionary, `base` world position, and an `angle_offset`
## (rotates the whole pose, used so a crane held by another crane moves
## with the outer grabber). Shared by `_draw_cranes` (placed cranes) and
## `_draw_crane_payload` (cranes held as payloads), so the picked-up
## visual is identical to the live one.
func _draw_crane_pose(state: Dictionary, data: BlockData, base: Vector2, gs: float, angle_offset: float) -> void:
	var angle: float = float(state.get("arm_angle", 0.0)) + angle_offset
	var ext: float = float(state.get("arm_extension", CRANE_ARM_MIN_TOTAL))
	var arm_dir: Vector2 = Vector2(cos(angle), sin(angle))

	# Distribute extension: arm3 first, then arm2, then arm1.
	var remaining: float = maxf(ext - CRANE_ARM_MIN_TOTAL, 0.0)
	var arm3_extra: float = minf(remaining, CRANE_ARM3_MAX - CRANE_ARM3_MIN)
	remaining -= arm3_extra
	var arm2_extra: float = minf(remaining, CRANE_ARM2_MAX - CRANE_ARM2_MIN)
	remaining -= arm2_extra
	var arm1_extra: float = minf(remaining, CRANE_ARM1_MAX - CRANE_ARM1_MIN)

	var seg1_len: float = CRANE_ARM1_MIN + arm1_extra
	var seg2_len: float = CRANE_ARM2_MIN + arm2_extra
	var seg3_len: float = CRANE_ARM3_MIN + arm3_extra

	var seg1_end: Vector2 = base + arm_dir * seg1_len
	var seg2_end: Vector2 = seg1_end + arm_dir * seg2_len
	var seg3_end: Vector2 = seg2_end + arm_dir * seg3_len

	# Grabber slides along the arm. `target_pos` is in world coords and
	# only meaningful for placed cranes — for a held crane its saved
	# target is stale, so fall back to the arm tip when re-rooting from
	# `base`. Using distance-from-base keeps the grabber positioned
	# along the rotated arm correctly.
	var tp_raw = state.get("target_pos", base)
	var to_target_dist: float
	if tp_raw is Vector2 and angle_offset == 0.0:
		to_target_dist = (tp_raw as Vector2 - base).length()
	else:
		to_target_dist = ext
	var total_arm_len: float = seg1_len + seg2_len + seg3_len
	var grabber_t: float = clampf(to_target_dist / total_arm_len, 0.0, 1.0)
	var grabber_pos: Vector2 = base + arm_dir * (grabber_t * total_arm_len)

	var holding: bool = state.get("held_payload", null) != null
	var cs: float = CRANE_GRABBER_SIZE * (0.7 if holding else 1.0)
	var grabber_thickness: float = 6.0 * main.SPRITE_SCALE_FACTOR
	var grabber_color := Color(0.6, 0.5, 0.2, 0.9)
	var g_angle: float = float(state.get("grabber_angle", 0.0)) + angle_offset

	var c: CanvasItem = _ccanvas()
	# Held payload UNDER everything.
	if holding:
		_draw_crane_payload(state["held_payload"], grabber_pos, g_angle, gs, 1.0)

	# Cross grabber UNDER the arm.
	c.draw_set_transform(grabber_pos, g_angle)
	c.draw_rect(Rect2(-cs, -grabber_thickness / 2.0, cs * 2, grabber_thickness), grabber_color, true)
	c.draw_rect(Rect2(-grabber_thickness / 2.0, -cs, grabber_thickness, cs * 2), grabber_color, true)
	c.draw_set_transform(Vector2.ZERO, 0.0)

	# Arm segments ON TOP.
	var c1: Vector2 = (base + seg1_end) / 2.0
	c.draw_set_transform(c1, angle)
	c.draw_rect(Rect2(-seg1_len / 2.0, -CRANE_ARM1_WIDTH / 2.0, seg1_len, CRANE_ARM1_WIDTH), Color(0.5, 0.5, 0.5, 0.85), true)
	c.draw_rect(Rect2(-seg1_len / 2.0, -CRANE_ARM1_WIDTH / 2.0, seg1_len, CRANE_ARM1_WIDTH), Color(0.6, 0.6, 0.6, 0.3), false, 1.0)
	c.draw_set_transform(Vector2.ZERO, 0.0)

	var c2: Vector2 = (seg1_end + seg2_end) / 2.0
	c.draw_set_transform(c2, angle)
	c.draw_rect(Rect2(-seg2_len / 2.0, -CRANE_ARM2_WIDTH / 2.0, seg2_len, CRANE_ARM2_WIDTH), Color(0.42, 0.42, 0.42, 0.9), true)
	c.draw_rect(Rect2(-seg2_len / 2.0, -CRANE_ARM2_WIDTH / 2.0, seg2_len, CRANE_ARM2_WIDTH), Color(0.55, 0.55, 0.55, 0.3), false, 1.0)
	c.draw_set_transform(Vector2.ZERO, 0.0)

	var c3: Vector2 = (seg2_end + seg3_end) / 2.0
	c.draw_set_transform(c3, angle)
	c.draw_rect(Rect2(-seg3_len / 2.0, -CRANE_ARM3_WIDTH / 2.0, seg3_len, CRANE_ARM3_WIDTH), Color(0.35, 0.35, 0.35, 0.95), true)
	c.draw_rect(Rect2(-seg3_len / 2.0, -CRANE_ARM3_WIDTH / 2.0, seg3_len, CRANE_ARM3_WIDTH), Color(0.5, 0.5, 0.5, 0.3), false, 1.0)
	c.draw_set_transform(Vector2.ZERO, 0.0)

	# Base pivot circle.
	c.draw_circle(base, 5.0, Color(0.6, 0.6, 0.6, 0.7))


# =========================
# CRANE LINK OVERLAYS
# =========================

## Draws blue (input) / yellow (output) 3-tile diamonds for the currently
## selected crane in link mode, plus a subtle highlight on the source crane
## itself, plus the in-world filter menu when shift+click opened it.
func _draw_crane_link_overlays() -> void:
	# Diamonds are only visible while the player is actively linking the
	# crane they belong to — outside link mode, the world is clean.
	if _crane_link_anchor != Vector2i(-1, -1) and crane_links.has(_crane_link_anchor) \
			and main.placed_buildings.has(_crane_link_anchor):
		var entry: Dictionary = crane_links[_crane_link_anchor]
		for spec in entry.get("inputs", []):
			_draw_crane_link_diamond(spec, Color(0.25, 0.55, 1.0, 0.85), true)
		for spec in entry.get("outputs", []):
			_draw_crane_link_diamond(spec, Color(1.0, 0.85, 0.15, 0.85), true)

	# Highlight the source crane.
	if _crane_link_anchor != Vector2i(-1, -1) and main.placed_buildings.has(_crane_link_anchor):
		var sd = Registry.get_block(main.placed_buildings[_crane_link_anchor])
		if sd:
			var gs: float = main.GRID_SIZE
			var w: Vector2 = main.grid_to_world(_crane_link_anchor)
			var size := Vector2(sd.grid_size.x * gs, sd.grid_size.y * gs)
			draw_rect(Rect2(w, size), Color(0.4, 0.9, 0.4, 0.25), true)
			draw_rect(Rect2(w, size), Color(0.4, 1.0, 0.4, 0.9), false, 2.0)

	# Filter menu.
	if _crane_filter_menu_open:
		_draw_crane_filter_menu()


## Renders one 3-tile diamond at the spec's world position, plus a small
## icon stack for any filter entries.
func _draw_crane_link_diamond(spec: Dictionary, color: Color, active: bool) -> void:
	var gs: float = main.GRID_SIZE
	var c: Vector2 = _crane_diamond_world_pos(spec)
	var r: float = gs * 1.5  # 3-tile diamond
	var pts := PackedVector2Array([
		c + Vector2(0, -r),
		c + Vector2(r, 0),
		c + Vector2(0, r),
		c + Vector2(-r, 0),
	])
	var fill: Color = color
	fill.a = color.a * 0.45
	draw_colored_polygon(pts, fill)
	var outline: Color = color
	outline.a = color.a
	# Polyline closed
	var loop := PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]])
	draw_polyline(loop, outline, 2.0, true)

	# Filter icons (stacked under the diamond) — only when actively editing.
	if active:
		var filter: Array = spec.get("filter", [])
		if not filter.is_empty():
			var icon_size: float = gs * 0.6
			var ox: float = c.x - (filter.size() * icon_size) / 2.0
			var oy: float = c.y + r + 4.0
			for i in range(filter.size()):
				var fid: StringName = filter[i]
				var tex: Texture2D = null
				var u = Registry.get_unit(fid)
				if u and u.icon:
					tex = u.icon
				else:
					var b = Registry.get_block(fid)
					if b and b.icon:
						tex = b.icon
				if tex:
					draw_texture_rect(tex, Rect2(ox + i * icon_size, oy, icon_size, icon_size), false, Color(1, 1, 1, 0.95))
				else:
					draw_rect(Rect2(ox + i * icon_size, oy, icon_size, icon_size), Color(0.6, 0.6, 0.6, 0.7), true)


## Renders the filter menu (icon grid) anchored under the diamond.
func _draw_crane_filter_menu() -> void:
	if _crane_filter_menu_items.is_empty():
		return
	var cell: float = _crane_filter_menu_cell
	var cols: int = mini(_crane_filter_menu_columns, _crane_filter_menu_items.size())
	var rows: int = ceili(float(_crane_filter_menu_items.size()) / float(cols))
	var grid_w: float = cell * cols
	var grid_h: float = cell * rows
	var origin: Vector2 = _crane_filter_menu_world_pos + Vector2(-grid_w / 2.0, main.GRID_SIZE * 1.7)

	# Background panel
	draw_rect(Rect2(origin - Vector2(6, 6), Vector2(grid_w + 12, grid_h + 12)), Color(0.08, 0.08, 0.12, 0.92), true)
	draw_rect(Rect2(origin - Vector2(6, 6), Vector2(grid_w + 12, grid_h + 12)), Color(0.7, 0.7, 0.8, 0.7), false, 1.0)

	# Selected ids — currently in the spec's filter list (highlighted).
	var selected: Array = []
	if _crane_filter_menu_anchor != Vector2i(-1, -1):
		var entry: Dictionary = crane_links.get(_crane_filter_menu_anchor, {})
		var arr: Array = entry.get(_crane_filter_menu_kind + "s", [])
		if _crane_filter_menu_index >= 0 and _crane_filter_menu_index < arr.size():
			selected = arr[_crane_filter_menu_index].get("filter", [])

	for i in range(_crane_filter_menu_items.size()):
		var col: int = i % cols
		var row: int = i / cols
		var r := Rect2(origin + Vector2(col * cell, row * cell), Vector2(cell, cell))
		var item: Dictionary = _crane_filter_menu_items[i]
		var is_sel: bool = selected.has(item.get("id", &""))
		var bg: Color = Color(0.25, 0.4, 0.7, 0.7) if is_sel else Color(0.18, 0.18, 0.22, 0.8)
		if i == _crane_filter_menu_hovered:
			bg = bg.lightened(0.15)
		draw_rect(r, bg, true)
		draw_rect(r, Color(0.6, 0.6, 0.7, 0.7), false, 1.0)
		var tex: Texture2D = item.get("icon", null)
		if tex:
			var pad: float = cell * 0.1
			draw_texture_rect(tex, Rect2(r.position + Vector2(pad, pad), Vector2(cell - pad * 2, cell - pad * 2)), false, Color(1, 1, 1, 1))


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

		# 2. Find a touching, powered archive scanner whose front faces an
		# archive. Multi-tile decoders need to scan their entire footprint
		# perimeter — the old 4-DIR-from-anchor scan only saw cells next
		# to the top-left tile, so a scanner adjacent to any other tile of
		# a 3x3 decoder went unrecognised.
		var scanner_pos: Vector2i = Vector2i(-9999, -9999)
		var archive_id: StringName = &""
		var found := false
		var seen_scanners: Dictionary = {}
		var perimeter: Array[Vector2i] = _get_block_perimeter_cells(anchor, data.grid_size)
		for n in perimeter:
			if not main.placed_buildings.has(n):
				continue
			var n_anchor: Vector2i = main.building_origins.get(n, n)
			if seen_scanners.has(n_anchor):
				continue
			seen_scanners[n_anchor] = true
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
