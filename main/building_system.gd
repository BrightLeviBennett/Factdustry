extends Node2D

# Preloaded so `EnemyUnit.draw_unit_payload(...)` resolves regardless of
# global class_name registration timing (the editor may not have reimported
# enemy_unit.gd's class_name yet when this script first parses).
const EnemyUnit = preload("res://main/enemy_unit.gd")


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
		var ui = owner_sys._world_ui if "_world_ui" in owner_sys else null
		if ui and (ui.world_menu_open or ui.storage_panel_open):
			queue_redraw()
	func _draw() -> void:
		if owner_sys == null:
			return
		var ui = owner_sys._world_ui if "_world_ui" in owner_sys else null
		if ui:
			ui.draw_world_menu(self)
			ui.draw_storage_panel(self)


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
## Per-archive-decoder state (`anchor → { progress, archive_id, scanner }`)
## now lives on the ArchiveDecoderSystem sibling node. Reads happen via
## `_ad_state(anchor)` and the in-progress tick advances on its own
## `_process`. Save / load and HUD tooltips query the system directly.

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
## Same checks as `can_place` minus the drone build-range constraint.
## Drives the preview TINT so an out-of-range-but-otherwise-valid
## placement reads as a normal white ghost (queued for the drone)
## rather than a red "invalid" warning. Actual click-to-place gating
## still uses `can_place`, which keeps the range check.
var can_place_excluding_range := false

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

# Build-beam scrolling stripe phase. Cycles [0, 1) over `_BUILD_BEAM_PERIOD`
# seconds — frozen while the world is paused so the visual matches the
# stalled build tick.
var _build_beam_phase: float = 0.0
const _BUILD_BEAM_PERIOD: float = 1.0

# Derelict-→-LUMINA conversion flash. anchor → Time.get_ticks_msec() at
# conversion, in seconds. Reused by `get_conversion_flash_tint` in the
# pass 4 overlay so freshly-captured blocks visibly "lock in" with the
# same yellow flash the launch-animation paints on pre-placed LUMINA
# blocks, minus the white kicker.
var _conversion_flash: Dictionary = {}
const _CONVERSION_FLASH_YELLOW: float = 0.18
const _CONVERSION_FLASH_FADE: float = 0.32  # total duration
var belt_scroll_enabled: bool = false
const _BELT_SCROLL_PIXELS_PER_SEC: float = 96.0
var _payload_conveyor_textures := {}

# --- PIPE / PUMP TEXTURES ---
var _pipe_textures := {}
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
var _grinder_head_texture: Texture2D
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

# --- IMPACT HEAD TEXTURE ---
# Same layered render as the scraper (head texture drawn UNDER the base
# sprite), but the head does NOT spin. Instead it scales between
# IMPACT_HEAD_MIN_SCALE and IMPACT_HEAD_MAX_SCALE: it snaps to MIN on
# every slam (the drill cycle's output moment), then eases back to MAX
# over the production cycle to read as "retracting" between hits.
# Particles burst out from under the head at the slam moment.
var _impact_head_texture: Texture2D

# Incinerator power-state textures: one each for powered / unpowered.
# The world render swaps between them every frame based on
# `PowerSystem.get_electrical_efficiency`.
var _incinerator_powered_texture: Texture2D
var _incinerator_unpowered_texture: Texture2D

# Payload crane art: arm-segment + head (cross-grabber) textures
# drawn dynamically by `_draw_crane_pose`. Base texture lives on the
# .tres as `top_sprite` so the standard block render path paints it.
var _payload_crane_arm_texture: Texture2D
var _payload_crane_head_texture: Texture2D
const IMPACT_HEAD_MIN_SCALE := 0.7   # head scale at the moment of impact (slam down)
const IMPACT_HEAD_MAX_SCALE := 1.0   # head scale fully retracted (waiting for next slam)
# Per-impact-drill state. Key = anchor. Value:
#   {"slam_progress": float, "prev_progress": float} — slam_progress
#   eases 0 (just slammed) → 1 (fully retracted) over the drill's
#   production cycle. A drop in progress signals a new slam moment
#   (used to fire the particle burst).
var _impact_head_state: Dictionary = {}

# Vent turbine: layered render with two spinning inner blade discs under
# a static base plate. Same inertia model as the scraper head — `vel` eases
# toward `VENT_TURBINE_SPIN` while the building is active, drops back to
# zero when it isn't, then `angle` integrates from `vel`.
var _vent_turbine_base_texture: Texture2D
var _vent_turbine_inner_texture: Texture2D
const VENT_TURBINE_SPIN := 7.5    # radians/sec target
const VENT_TURBINE_ACCEL := 5.0   # rad/s²
var _vent_turbine_state: Dictionary = {}

# --- LAYERED SPINNER BLOCKS ---
# Generic three-layer render: Base (static) → Head (rotates while the
# factory is producing) → Top (static). One entry per supported block
# in `_LAYERED_SPINNERS`. Each entry stores the three texture paths,
# the head's spin / accel constants, and is keyed by block_id. Adding
# a new block is a single entry in the dict — no new tick / draw
# functions required.
const _LAYERED_SPINNERS := {
	&"brass_mixer": {
		"base": "res://textures/blocks/factories/Brass Mixer/BrassMixerBase.png",
		"head": "res://textures/blocks/factories/Brass Mixer/BrassMixerHead.png",
		"top":  "res://textures/blocks/factories/Brass Mixer/BrassMixerTop.png",
		"spin":  4.5,
		"accel": 8.0,
	},
	&"silicon_mixer": {
		"base": "res://textures/blocks/factories/Silicon Refinery/SiliconRefineryBase.png",
		"head": "res://textures/blocks/factories/Silicon Refinery/SiliconRefineryHead.png",
		"top":  "res://textures/blocks/factories/Silicon Refinery/SiliconRefineryTop.png",
		"spin":  4.5,
		"accel": 8.0,
	},
	&"compound_mixer": {
		"base": "res://textures/blocks/factories/Compound Mixer/CompoundMixerBase.png",
		"head": "res://textures/blocks/factories/Compound Mixer/CompoundMixerHead.png",
		"top":  "res://textures/blocks/factories/Compound Mixer/CompoundMixerTop.png",
		"spin":  4.5,
		"accel": 8.0,
	},
}
# Loaded Texture2D per block_id → {"base": Texture2D, "head": ..., "top": ...}.
var _layered_spinner_textures: Dictionary = {}
# Per-anchor head state: angle, vel, prev_timer (for stall detection).
var _layered_spinner_state: Dictionary = {}

# Vent condenser: same layered base + spinning inner pattern as the
# vent turbine, with its own textures. The condenser carries the `pump`
# tag so without this override the regular draw flow would route it
# through the generic `FluidPump.png` instead.
var _vent_condenser_base_texture: Texture2D
var _vent_condenser_inner_texture: Texture2D
const VENT_CONDENSER_SPIN := 7.5
const VENT_CONDENSER_ACCEL := 5.0
var _vent_condenser_state: Dictionary = {}

# Smoothly-eased displayed fluid total per anchor for the blue
# storage bar. Logical `block_storage[anchor]["fluids"]` totals
# change in discrete jumps (pipe push / pump tick); this dict carries
# the value the bar actually paints, eased toward the true total at
# FLUID_BAR_EASE_PER_SEC units per second so the bar slides instead
# of teleporting.
var _fluid_bar_display: Dictionary = {}
const FLUID_BAR_EASE_PER_SEC := 8.0

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

# --- BRIDGE LINK VISUALIZER TEXTURE ---
# Tiled along belt / duct bridge links (Mindustry-style) instead of a
# dashed line. Repeated end-to-end and clipped to the exact span length.
var _bridge_visualizer_texture: Texture2D

# --- CACHED REFERENCES ---
# SectorScript is created by Main._ready AFTER its Registry await, which can
# be after our own _ready runs. So these are cached *opportunistically* in
# _ready but fall back to a live get_node_or_null on first miss.
var _logistics: Node2D
var _terrain: Node2D
var _sector_script: Node
var _power_sys: Node
var _schematic: Node     # SchematicSystem — schematic capture / paste / save
# WorldUiSystem — world menu + storage panel popups. Accessed via a
# lazy-fetch property getter (below) so the very first frame's input —
# which can run before our `await get_tree().process_frame` resolves —
# doesn't crash on a null reference.
var _world_ui_cache: Node = null
var _world_ui: Node:
	get:
		if _world_ui_cache == null or not is_instance_valid(_world_ui_cache):
			_world_ui_cache = get_node_or_null("/root/Main/WorldUiSystem")
		return _world_ui_cache
	set(value):
		_world_ui_cache = value


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

# World menu, storage panel, and landing-pad pick state moved to
# WorldUiSystem — access via `_world_ui.<field>`.

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

# Schematic state lives on the SchematicSystem sibling node — accessed
# via the `_schematic` accessor below. Kept here as a comment so the
# old vars are easy to grep for.

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
	# Picking a real block from the build menu exits paste mode so the
	# schematic stamp doesn't fight the block placement preview.
	if main.has_signal("building_selected"):
		main.building_selected.connect(_on_main_building_selected)
	# Scale world-menu cell size to current GRID_SIZE so storage / sorter /
	# picker panels stay proportional to a tile.
	# `_world_menu_cell_size` scale now happens inside WorldUiSystem._ready.
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
	_schematic = get_node_or_null("/root/Main/SchematicSystem")
	_world_ui = get_node_or_null("/root/Main/WorldUiSystem")
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
	# Use the cached terrain reference instead of walking the scene
	# tree every wall-cache rebuild.
	var terrain = _terrain_ref()
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
	var sector_script_ref = _sector_script_ref()
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
	# (avoids repeated get_node_or_null + dictionary lookups during draw).
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
## Drill heads are now split into per-side textures keyed by the
## number of tiles each head needs to reach forward into ore.
##   L0 / R0 = head sits at the drill's front edge (no extension).
##   L1 / R1 = head reaches 1 tile past the front edge.
##   L2 / R2 = head reaches 2 tiles past (mechanical_drill's max).
## Picking the variant per side avoids the combinatorial explosion of
## per-(left,right) combo art the old N/L/R/A system required.
## -L2 / -R2 are taller than L0/L1 to fit the extra extension tile;
## the renderer sizes its rect against the natural per-level depth
## so the artwork lands flush.
const _DRILL_HEAD_TEX_PATHS := {
	"L0": "res://textures/blocks/resource extractors/MechanicalDrill/DrillHeads-L0.png",
	"L1": "res://textures/blocks/resource extractors/MechanicalDrill/DrillHeads-L1.png",
	"L2": "res://textures/blocks/resource extractors/MechanicalDrill/DrillHeads-L2.png",
	"R0": "res://textures/blocks/resource extractors/MechanicalDrill/DrillHeads-R0.png",
	"R1": "res://textures/blocks/resource extractors/MechanicalDrill/DrillHeads-R1.png",
	"R2": "res://textures/blocks/resource extractors/MechanicalDrill/DrillHeads-R2.png",
}
const _PIPE_TEX_PATHS := {
	"straight": "res://textures/blocks/fluid transportation/pipe/Pipe.png",
	"jr":       "res://textures/blocks/fluid transportation/pipe/Pipe-JR.png",
	"jl":       "res://textures/blocks/fluid transportation/pipe/Pipe-JL.png",
	"ja":       "res://textures/blocks/fluid transportation/pipe/Pipe-JA.png",
	"ca":       "res://textures/blocks/fluid transportation/pipe/Pipe-CA.png",
	"cb":       "res://textures/blocks/fluid transportation/pipe/Pipe-CB.png",
}
const _PUMP_TEX_PATH := "res://textures/blocks/fluid transportation/FluidPump.png"
const _WIRE_TEX_PATH := "res://textures/blocks/power/CopperWire.png"
const _BRIDGE_VISUALIZER_TEX_PATH := "res://textures/blocks/item transportation/BridgeVisualizer.png"
const _CRUSHER_HEAD_TEX_PATH := "res://textures/blocks/resource extractors/WallCrusher/CrusherHead.png"
const _GRINDER_HEAD_TEX_PATH := "res://textures/blocks/resource extractors/WallGrinder/GrinderHead.png"
const _SCRAPER_HEAD_TEX_PATH := "res://textures/blocks/resource extractors/Ground Scraper/GroundScraperHead.png"
const _IMPACT_HEAD_TEX_PATH := "res://textures/blocks/resource extractors/Impact Drill/ImpactDrillHead.png"
const _INCINERATOR_POWERED_TEX_PATH := "res://textures/blocks/item transportation/Incinerator-P.png"
const _INCINERATOR_UNPOWERED_TEX_PATH := "res://textures/blocks/item transportation/Incinerator-NP.png"
const _PAYLOAD_CRANE_ARM_TEX_PATH := "res://textures/blocks/units/PayloadCrane/PayloadCraneArm.png"
const _PAYLOAD_CRANE_HEAD_TEX_PATH := "res://textures/blocks/units/PayloadCrane/PayloadCraneHead.png"
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
	for key in _PIPE_TEX_PATHS:
		ResourceLoader.load_threaded_request(_PIPE_TEX_PATHS[key])
	ResourceLoader.load_threaded_request(_PUMP_TEX_PATH)
	ResourceLoader.load_threaded_request(_WIRE_TEX_PATH)
	ResourceLoader.load_threaded_request(_BRIDGE_VISUALIZER_TEX_PATH)
	ResourceLoader.load_threaded_request(_CRUSHER_HEAD_TEX_PATH)
	ResourceLoader.load_threaded_request(_GRINDER_HEAD_TEX_PATH)
	ResourceLoader.load_threaded_request(_SCRAPER_HEAD_TEX_PATH)
	ResourceLoader.load_threaded_request(_IMPACT_HEAD_TEX_PATH)
	ResourceLoader.load_threaded_request(_INCINERATOR_POWERED_TEX_PATH)
	ResourceLoader.load_threaded_request(_INCINERATOR_UNPOWERED_TEX_PATH)
	ResourceLoader.load_threaded_request(_PAYLOAD_CRANE_ARM_TEX_PATH)
	ResourceLoader.load_threaded_request(_PAYLOAD_CRANE_HEAD_TEX_PATH)
	ResourceLoader.load_threaded_request(_VENT_TURBINE_BASE_TEX_PATH)
	ResourceLoader.load_threaded_request(_VENT_TURBINE_INNER_TEX_PATH)
	for bid in _LAYERED_SPINNERS:
		var entry: Dictionary = _LAYERED_SPINNERS[bid]
		ResourceLoader.load_threaded_request(entry["base"])
		ResourceLoader.load_threaded_request(entry["head"])
		ResourceLoader.load_threaded_request(entry["top"])
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
	for key in _PIPE_TEX_PATHS:
		_pipe_textures[key] = ResourceLoader.load_threaded_get(_PIPE_TEX_PATHS[key])
	_pump_texture = ResourceLoader.load_threaded_get(_PUMP_TEX_PATH)
	_wire_texture = ResourceLoader.load_threaded_get(_WIRE_TEX_PATH)
	_bridge_visualizer_texture = ResourceLoader.load_threaded_get(_BRIDGE_VISUALIZER_TEX_PATH)
	_crusher_head_texture = ResourceLoader.load_threaded_get(_CRUSHER_HEAD_TEX_PATH)
	_grinder_head_texture = ResourceLoader.load_threaded_get(_GRINDER_HEAD_TEX_PATH)
	_scraper_head_texture = ResourceLoader.load_threaded_get(_SCRAPER_HEAD_TEX_PATH)
	_impact_head_texture = ResourceLoader.load_threaded_get(_IMPACT_HEAD_TEX_PATH)
	_incinerator_powered_texture = ResourceLoader.load_threaded_get(_INCINERATOR_POWERED_TEX_PATH)
	_incinerator_unpowered_texture = ResourceLoader.load_threaded_get(_INCINERATOR_UNPOWERED_TEX_PATH)
	_payload_crane_arm_texture = ResourceLoader.load_threaded_get(_PAYLOAD_CRANE_ARM_TEX_PATH)
	_payload_crane_head_texture = ResourceLoader.load_threaded_get(_PAYLOAD_CRANE_HEAD_TEX_PATH)
	_vent_turbine_base_texture = ResourceLoader.load_threaded_get(_VENT_TURBINE_BASE_TEX_PATH)
	_vent_turbine_inner_texture = ResourceLoader.load_threaded_get(_VENT_TURBINE_INNER_TEX_PATH)
	for bid in _LAYERED_SPINNERS:
		var entry: Dictionary = _LAYERED_SPINNERS[bid]
		_layered_spinner_textures[bid] = {
			"base": ResourceLoader.load_threaded_get(entry["base"]),
			"head": ResourceLoader.load_threaded_get(entry["head"]),
			"top":  ResourceLoader.load_threaded_get(entry["top"]),
		}
	_vent_condenser_base_texture = ResourceLoader.load_threaded_get(_VENT_CONDENSER_BASE_TEX_PATH)
	_vent_condenser_inner_texture = ResourceLoader.load_threaded_get(_VENT_CONDENSER_INNER_TEX_PATH)
	_faction_overlay_ferox = ResourceLoader.load_threaded_get(_FACTION_OVERLAY_FEROX_PATH)
	_faction_overlay_derelict = ResourceLoader.load_threaded_get(_FACTION_OVERLAY_DERELICT_PATH)
	for key in _PAYLOAD_CONV_TEX_PATHS:
		_payload_conveyor_textures[key] = ResourceLoader.load_threaded_get(_PAYLOAD_CONV_TEX_PATHS[key])
	_textures_ready = true


## Maximum supported extension level (capped at the number of L*/R*
## textures shipped). mine_range > MAX_DRILL_HEAD_LEVEL just clamps —
## the last texture is reused for any deeper reach.
const MAX_DRILL_HEAD_LEVEL := 2


## Returns `{left: int, right: int}` — each entry is the extension
## level (0 / 1 / 2) for that side, or -1 if that side has no
## reachable ore at all and shouldn't render a head. The level is the
## number of tiles BEYOND the front edge the head needs to reach,
## clamped to MAX_DRILL_HEAD_LEVEL. Each side is independent so the
## left head can be retracted while the right is fully extended.
func _get_drill_head_levels(grid_pos: Vector2i, rotation: int, grid_size: Vector2i) -> Dictionary:
	var none := {"left": -1, "right": -1}
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if terrain == null:
		return none

	var dir: Vector2i
	match rotation:
		0: dir = Vector2i(1, 0)
		1: dir = Vector2i(0, 1)
		2: dir = Vector2i(-1, 0)
		3: dir = Vector2i(0, -1)
		_: dir = Vector2i(1, 0)

	var front_cells := _get_front_edge(grid_pos, grid_size, rotation)
	if front_cells.size() < 2:
		return none

	# Same texture-left / texture-right mapping the old variant
	# resolver used (front_cells order vs the (rotation-1)*90° canvas
	# rotation that comes later in the draw).
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

	# Level = number of tiles past the front cell the head reaches.
	# Ore at the front cell itself (offset 0) → L0 (no extension).
	# Ore one tile past (offset 1) → L1. Two past (offset 2) → L2.
	# No ore in scan range → L0 (head sits idle at the body face).
	var find_level := func(start_cell: Vector2i) -> int:
		for n in range(MAX_DRILL_HEAD_LEVEL + 1):
			var c: Vector2i = start_cell + dir * n
			if terrain.get_ore_at(c) != null:
				return clampi(n, 0, MAX_DRILL_HEAD_LEVEL)
		return 0
	return {
		"left": find_level.call(tex_left_cell),
		"right": find_level.call(tex_right_cell),
	}


## Draws the DrillHeads overlay textures in front of a drill — one
## texture per side, sized per its own extension level. Each side's
## rect is positioned half-a-tile off the drill's local center along
## the texture-local X axis (since the body is 2 tiles wide for the
## mechanical drill) and rooted with its near edge at the drill's
## front face along Y, with depth = (level + 1) tiles. That makes
## L2's taller artwork land 1 tile deeper than L0/L1 without changing
## where the head "starts" against the body.
func _draw_drill_heads(grid_pos: Vector2i, rotation: int, grid_size: Vector2i,
		levels: Dictionary, block_id: StringName, tint: Color = Color.WHITE) -> void:
	var gs := float(main.GRID_SIZE)
	var world_pos: Vector2 = main.grid_to_world(grid_pos)
	var offset: Vector2 = _get_top_offset(world_pos) * _get_height_scale(block_id)

	# Drill body center in world space.
	var body_center: Vector2 = world_pos + Vector2(
		grid_size.x * gs / 2.0,
		grid_size.y * gs / 2.0
	) + offset

	# Forward unit vector (world-space) for this rotation. Picks the
	# correct half-extent of the body along the forward axis.
	var fwd: Vector2
	match rotation:
		0: fwd = Vector2(1, 0)
		1: fwd = Vector2(0, 1)
		2: fwd = Vector2(-1, 0)
		3: fwd = Vector2(0, -1)
		_: fwd = Vector2(1, 0)
	var drill_half_fwd: float
	if abs(fwd.x) > 0.5:
		drill_half_fwd = grid_size.x * gs / 2.0
	else:
		drill_half_fwd = grid_size.y * gs / 2.0

	# Front-face center: where the head rects START (near edge).
	var front_center: Vector2 = body_center + fwd * drill_half_fwd

	# After draw_set_transform(front_center, angle):
	#   local +Y = forward (out of the drill)
	#   local +X = texture's right side
	#   local origin = exact middle of the drill's front face
	# `angle` = (rotation - 1) * 90° so the texture's default "drill
	# faces DOWN" orientation rotates into the live drill's facing.
	var angle: float = (rotation - 1) * PI / 2.0
	draw_set_transform(front_center, angle)

	# Each L/R texture is authored at FULL drill width — its art only
	# occupies the matching half of the image, and the other half is
	# transparent. Drawing them both at the same full-width rect
	# layers the left head from the L texture and the right head from
	# the R texture without distorting the artwork. Depth scales with
	# each texture's natural aspect so L2's taller artwork (1.5×) is
	# drawn at 1.5× the depth of L0/L1 (1:1).
	var full_w: float = grid_size.x * gs
	var paint_side := func(prefix: String, lvl: int):
		if lvl < 0:
			return
		var clamped: int = clampi(lvl, 0, MAX_DRILL_HEAD_LEVEL)
		var tex: Texture2D = _drill_head_textures.get("%s%d" % [prefix, clamped])
		if tex == null:
			return
		var ts: Vector2 = tex.get_size()
		var depth: float = full_w  # square fallback
		if ts.x > 0.0:
			depth = full_w * (ts.y / ts.x)
		var rect := Rect2(Vector2(-full_w * 0.5, 0.0), Vector2(full_w, depth))
		draw_texture_rect(tex, rect, false, tint)

	paint_side.call("L", int(levels.get("left", -1)))
	paint_side.call("R", int(levels.get("right", -1)))
	draw_set_transform(Vector2.ZERO, 0.0)


## Draws one red plasma beam per front-edge cell for blocks tagged
## `drill_lasers` (plasma_bore, advanced_plasma_bore). Each beam runs
## from the front face of the bore's front-edge cell to the far face
## of the cell it's actively mining. Uses `Main.draw_beam` — the same
## render path the player drone's mining + heal lasers use, so the
## visual language (white core, colored sheath, endpoint discs,
## breathing pulse) is consistent across all in-game beams.
func _draw_drill_lasers(grid_pos: Vector2i, rotation: int, grid_size: Vector2i, mine_range: int) -> void:
	if main == null:
		return
	var gs := float(main.GRID_SIZE)
	var parallax: Vector2 = _get_top_offset(main.grid_to_world(grid_pos))
	var fwd: Vector2
	var fwd_i: Vector2i
	match rotation:
		0:
			fwd = Vector2(1, 0); fwd_i = Vector2i(1, 0)
		1:
			fwd = Vector2(0, 1); fwd_i = Vector2i(0, 1)
		2:
			fwd = Vector2(-1, 0); fwd_i = Vector2i(-1, 0)
		3:
			fwd = Vector2(0, -1); fwd_i = Vector2i(0, -1)
		_:
			fwd = Vector2(1, 0); fwd_i = Vector2i(1, 0)
	# Inner front-edge cells (the LAST row of the bore's footprint along
	# the facing direction). `_get_front_edge` returns the cells just
	# OUTSIDE the bore, so step them back by one to land on the bore's
	# own front face.
	var outer_front_cells := _get_front_edge(grid_pos, grid_size, rotation)
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	var pulse: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() / 333.0)
	var laser_color := Color(1.0, 0.15, 0.15)
	# The drill actually scans `mine_range + 1` tiles beyond the bore
	# (the front edge + mine_range more, matching `_get_extended_front_edge`),
	# so the laser needs to do the same — otherwise ore at the very
	# end of range looks like it falls outside the beam.
	var max_reach: int = mine_range + 1
	for outer in outer_front_cells:
		var inner_front: Vector2i = outer - fwd_i
		# Find the first ore tile within reach; else use max-range.
		var hit_dist: int = max_reach
		for step in range(1, max_reach + 1):
			var scan: Vector2i = outer + fwd_i * (step - 1)
			if terrain != null and terrain.has_method("get_ore_at"):
				var ore = terrain.get_ore_at(scan)
				if ore != null and ore.minable_resource != &"":
					hit_dist = step
					break
		var hit_cell: Vector2i = outer + fwd_i * (hit_dist - 1)
		# Start: front face of the bore's own front-edge cell (the emitter
		# port — touches the boundary between the bore and the mined area).
		var start: Vector2 = main.grid_to_world(inner_front) + Vector2(gs * 0.5, gs * 0.5) + fwd * (gs * 0.5) + parallax
		# End: NEAR face of the hit cell (the side facing the bore).
		var end: Vector2 = main.grid_to_world(hit_cell) + Vector2(gs * 0.5, gs * 0.5) - fwd * (gs * 0.5) + parallax
		# `draw_beam` is a static helper on Main — call it on the class, not
		# the `main` node, so it also works when the building renderer runs
		# under the Map Editor (whose root node has no draw_beam method).
		Main.draw_beam(self, start, end, laser_color, pulse)


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
	# Pick texture by block tag: wall_grinder (3 heads) uses GrinderHead,
	# everything else (wall_crusher etc.) uses CrusherHead.
	var bd_h = Registry.get_block(block_id)
	var is_grinder: bool = bd_h != null and bd_h.tags.has("grinder_heads")
	var head_tex: Texture2D = _grinder_head_texture if is_grinder else _crusher_head_texture
	if head_tex == null:
		return

	var gs := float(main.GRID_SIZE)
	var world_pos: Vector2 = main.grid_to_world(grid_pos)
	var offset: Vector2 = _get_top_offset(world_pos) * _get_height_scale(block_id)

	# Front-edge cells (one per head) — same mapping _get_front_edge
	# produces. Wall crusher = 2 cells, wall grinder = 3 cells, etc.
	var front_cells := _get_front_edge(grid_pos, grid_size, rotation)
	if front_cells.size() < 1:
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

	# Square sprite centered at the pivot. Sized as a fraction of a tile
	# (not the texture's native px), so swapping the head art for a
	# higher-resolution version doesn't blow up the in-world size.
	const CRUSHER_HEAD_TILE_FRACTION := 0.75
	var head_world_size: float = gs * CRUSHER_HEAD_TILE_FRACTION
	var tex_size: Vector2 = Vector2(head_world_size, head_world_size)
	var tex_rect := Rect2(-tex_size * 0.5, tex_size)

	var head_count: int = front_cells.size()
	# Compute live angles for each head. The state dict stores
	# `angle_<i>` / `vel_<i>` per head index so the existing 2-head
	# crusher inertial state keeps working AND new 3-head grinders
	# extend it without breaking.
	var angles: Array = []
	if spinning:
		if not _crusher_head_state.has(grid_pos):
			_crusher_head_state[grid_pos] = {}
		var s: Dictionary = _crusher_head_state[grid_pos]
		for i in range(head_count):
			var key_a: String = "angle_%d" % i
			if not s.has(key_a):
				var seed_i: int = grid_pos.x * (73 + i * 11) + grid_pos.y * (31 + i * 7)
				s[key_a] = fposmod(float(seed_i), TAU)
				s["vel_%d" % i] = 0.0
			angles.append(float(s[key_a]))
	else:
		for i in range(head_count):
			var seed_i: int = grid_pos.x * (73 + i * 11) + grid_pos.y * (31 + i * 7)
			angles.append(fposmod(float(seed_i), TAU))

	# Axis along the front edge (perpendicular to `fwd`). Used to nudge
	# the outer heads inward so they line up with the indicator arrows
	# drawn into the body texture (the artwork insets its arrows from
	# the body's outer corners; cell centers don't match that inset
	# without an explicit pull-toward-center).
	var side: Vector2 = Vector2(-fwd.y, fwd.x)
	const CRUSHER_HEAD_EDGE_SQUEEZE := 0.1
	# Front-edge midpoint along `side` (cell-center coordinates).
	var edge_mid: float = (float(head_count) - 1.0) * 0.5
	for i in range(head_count):
		var cell: Vector2i = front_cells[i]
		var cell_center: Vector2 = main.grid_to_world(cell) + Vector2(gs * 0.5, gs * 0.5) + offset
		# Shift back toward the crusher by half a tile → head sits on the
		# shared edge between the crusher body and the front cell.
		var head_pos: Vector2 = cell_center - fwd * (gs * 0.5)
		# Pull the head inward along the front edge by a small fraction
		# of its distance from the edge midpoint.
		var lateral_tiles: float = float(i) - edge_mid
		head_pos += side * (lateral_tiles * gs * CRUSHER_HEAD_EDGE_SQUEEZE)
		draw_set_transform(head_pos, angles[i])
		draw_texture_rect(head_tex, tex_rect, false, tint)
		draw_set_transform(Vector2.ZERO, 0.0)










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






## Draws the impact drill's head texture centered on the footprint at
## a scale that snaps to MIN on every slam and eases back to MAX
## across the production cycle. Drawn BEFORE the base sprite so the
## base covers the head's center (same composition as the scraper).
func _draw_impact_head(grid_pos: Vector2i, top_pos: Vector2, width: float, height: float, tint: Color = Color.WHITE) -> void:
	if _impact_head_texture == null:
		return
	if not _impact_head_state.has(grid_pos):
		_impact_head_state[grid_pos] = {"slam_progress": 1.0, "prev_progress": 1.0}
	var s: Dictionary = _impact_head_state[grid_pos]
	# Ease so the bounce-back from a slam feels cushioned rather than
	# linear (similar feel to ease(t, 1.6) used elsewhere).
	var p: float = clampf(float(s.get("slam_progress", 1.0)), 0.0, 1.0)
	var eased: float = ease(p, 1.6)
	var scale_factor: float = lerpf(IMPACT_HEAD_MIN_SCALE, IMPACT_HEAD_MAX_SCALE, eased)
	var center: Vector2 = top_pos + Vector2(width * 0.5, height * 0.5)
	var draw_w: float = width * scale_factor
	var draw_h: float = height * scale_factor
	draw_set_transform(center, 0.0)
	draw_texture_rect(_impact_head_texture, Rect2(Vector2(-draw_w * 0.5, -draw_h * 0.5), Vector2(draw_w, draw_h)), false, tint)
	draw_set_transform(Vector2.ZERO, 0.0)




## Draws a dashed circle at `radius` around `center`. Used by the
## turret-range visualisers (placement preview + hover-over-existing).
## Each dash is a `draw_polyline` rather than a `draw_arc` so the line
## caps and segment joins are flat — `draw_arc` was leaving slight
## connector slivers between adjacent calls that read as a faint gray
## ring under the white dashes.
## Paints a "pod under construction" sprite on top of every Launchpad
## whose mandatory cost is still being collected. Once collected, the
## pod renders solid — the cargo is loaded and the pad is ready to
## launch. Mirrors the block-build animation: dark/blueprint wash on
## the unbuilt portion, with a yellow build-front line sweeping right.
func _draw_launchpad_pod_previews() -> void:
	if main == null:
		return
	var lp_sys = get_node_or_null("/root/Main/LaunchpadSystem")
	if lp_sys == null or not lp_sys.has_method("get_pod_build_progress"):
		return
	var pod_tex: Texture2D = null
	# Borrow the launch_animation's pod texture so we render exactly the
	# same art the launch animation will animate.
	var anim = get_node_or_null("/root/Main/LaunchAnimation")
	if anim and "_pod_tex" in anim:
		pod_tex = anim._pod_tex
	if pod_tex == null:
		# Fallback path: don't draw anything rather than a placeholder
		# rect that'd be confusing on top of the pad sprite.
		return
	var gs: float = float(main.GRID_SIZE)
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if anchor != cell:
			continue
		if main.placed_buildings.get(anchor, &"") != &"launchpad":
			continue
		# Only LUMINA launchpads — captured enemy launchpads would render
		# nonsensical previews.
		if main.get_building_faction(anchor) != main.Faction.LUMINA:
			continue
		var data = Registry.get_block(&"launchpad")
		if data == null:
			continue
		var world_pos: Vector2 = main.grid_to_world(anchor)
		var offset: Vector2 = _get_top_offset(world_pos) * _get_height_scale(&"launchpad")
		var w: float = gs * float(data.grid_size.x)
		var h: float = gs * float(data.grid_size.y)
		var top_pos: Vector2 = world_pos + offset
		# Pod is rendered in the centre of the launchpad at ~70% of the
		# launchpad footprint so the player can still see the pad art
		# around the pod.
		var pod_size: float = minf(w, h) * 0.7
		var pod_rect := Rect2(
			top_pos + Vector2((w - pod_size) * 0.5, (h - pod_size) * 0.5),
			Vector2(pod_size, pod_size))
		var pct: float = clampf(lp_sys.get_pod_build_progress(anchor), 0.0, 1.0)
		# Pod isn't "fabricated" until the build_timer has filled. While
		# building, only the BUILT portion of the pod sprite is rendered
		# — the rest of the pad stays clear so the player can see the
		# pod growing into existence rather than waiting under a wash.
		if pct >= 1.0:
			draw_texture_rect(pod_tex, pod_rect, false, Color(1, 1, 1, 1.0))
		elif pct > 0.0:
			# Sample only the left (built) part of the source texture so
			# the right edge is a clean cut, not a stretched compression.
			var src_w: float = pod_tex.get_width() * pct
			var src_rect := Rect2(0.0, 0.0, src_w, pod_tex.get_height())
			var dst_rect := Rect2(
				pod_rect.position,
				Vector2(pod_rect.size.x * pct, pod_rect.size.y))
			draw_texture_rect_region(pod_tex, dst_rect, src_rect, Color(1, 1, 1, 1.0))
			# Yellow build-front line at the construction edge.
			var line_x: float = pod_rect.position.x + pod_rect.size.x * pct
			draw_line(
				Vector2(line_x, pod_rect.position.y),
				Vector2(line_x, pod_rect.position.y + pod_rect.size.y),
				Color(1.0, 0.9, 0.2, 0.9), 2.0)


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
## Hover preview for any placed LUMINA extractor / pump — paints a
## small floating icon above the building showing which item / fluid
## it's currently outputting. Same data path the placement preview
## uses (`compute_extractor_preview_output`), so a freshly-placed
## drill and a long-running one read the same.
func _draw_hovered_extractor_output() -> void:
	# Hold off while a placement is in flight — the placement preview
	# already draws its own efficiency + icon readout.
	if main.selected_building != &"":
		return
	if main.has_method("is_ui_blocking") and main.is_ui_blocking():
		return
	if _logistics == null or not _logistics.has_method("compute_extractor_preview_output"):
		return
	var mouse_world: Vector2 = get_global_mouse_position()
	var grid_pos: Vector2i = main.world_to_grid(mouse_world)
	if not main.placed_buildings.has(grid_pos):
		return
	if main.get_building_faction(grid_pos) != FACTION_LUMINA:
		return
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if data == null:
		return
	# Limit to actual extractors / pumps so a turret hover doesn't draw
	# an empty floating icon slot.
	var is_extractor: bool = data.category == BlockData.BlockCategory.EXTRACTORS or data.tags.has("pump")
	if not is_extractor:
		return
	if data.id == &"vent_turbine" or data.id == &"vent_condenser":
		return
	var rot: int = main.building_rotation.get(anchor, 0)
	var out_info: Dictionary = _logistics.compute_extractor_preview_output(anchor, data, rot)
	var item_id: StringName = StringName(out_info.get("item_id", &""))
	if item_id == &"":
		return
	var icon_tex: Texture2D = null
	var item_d = Registry.get_item(item_id)
	if item_d and item_d.icon:
		icon_tex = item_d.icon
	else:
		var fluid_d = Registry.get_fluid(item_id)
		if fluid_d and fluid_d.icon:
			icon_tex = fluid_d.icon
	if icon_tex == null:
		return
	var gs: float = float(main.GRID_SIZE)
	var top_left: Vector2 = main.grid_to_world(anchor)
	var icon_size: float = gs * 0.5
	var icon_rect := Rect2(top_left - Vector2(icon_size * 0.5, icon_size * 0.5), Vector2(icon_size, icon_size))
	draw_texture_rect(icon_tex, icon_rect, false)


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
	# Player's own blocks only — enemy / derelict structures shouldn't
	# advertise their reach to the player on hover.
	if main.get_building_faction(grid_pos) != main.Faction.LUMINA:
		return
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if data == null:
		return
	# Pick the appropriate range based on what kind of block this is:
	#   - turret   → attack_range (firing radius)
	#   - crane    → crane_range  (reach of the grabber)
	#   - mass_driver → link_range (max partner distance)
	#   - overdrive → overdrive_radius (boost zone radius)
	#   - mender   → mend_radius  (heal zone radius)
	var range_tiles: float = 0.0
	var ring_color := Color(1, 1, 1, 0.85)
	var is_overdrive: bool = data.tags.has("overdrive") and data.overdrive_radius > 0.0
	var is_mender: bool = data.tags.has("mender") and data.mend_radius > 0.0
	if data.is_turret() and data.attack_range > 0.0:
		range_tiles = data.attack_range
	elif data.tags.has("crane") and data.crane_range > 0.0:
		range_tiles = data.crane_range
	elif data.tags.has("mass_driver") and data.link_range > 0.0:
		range_tiles = data.link_range
	elif is_overdrive:
		range_tiles = data.overdrive_radius
		ring_color = Color(1.0, 0.65, 0.15, 0.85)
	elif is_mender:
		range_tiles = data.mend_radius
		ring_color = Color(0.4, 1.0, 0.5, 0.85)
	if range_tiles <= 0.0:
		return
	var gs: float = float(main.GRID_SIZE)
	var center: Vector2 = main.grid_to_world(anchor) + Vector2(
		data.grid_size.x * gs * 0.5,
		data.grid_size.y * gs * 0.5,
	)
	var range_px: float = range_tiles * gs
	_draw_dashed_circle(center, range_px, ring_color, 3.0)
	# Highlight every block actually affected by this overdriver / mender
	# with a thin outline matching the ring colour so the player can see
	# at a glance which neighbours benefit.
	if is_overdrive or is_mender:
		_draw_affected_block_outlines(anchor, data, center, range_px, ring_color, is_overdrive)


## Paints a thin outline around every friendly placed building that
## sits inside the hovered overdriver's / mender's effect radius.
## `is_overdrive` switches the eligibility check between the
## overdrive-target rules in `main.get_overdrive_multiplier` and the
## damaged-friendly-block rules used by menders (any friendly building
## with max_health > 0).
func _draw_affected_block_outlines(source_anchor: Vector2i, _source_data: BlockData,
		source_center: Vector2, radius_px: float, color: Color, is_overdrive: bool) -> void:
	var gs: float = float(main.GRID_SIZE)
	var seen := {}
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if seen.has(anchor):
			continue
		seen[anchor] = true
		if anchor == source_anchor:
			continue
		if main.get_building_faction(anchor) != main.Faction.LUMINA:
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null:
			continue
		var center: Vector2 = main.grid_to_world(anchor) \
			+ Vector2(data.grid_size.x * gs * 0.5, data.grid_size.y * gs * 0.5)
		if source_center.distance_to(center) > radius_px:
			continue
		# Eligibility gate
		if is_overdrive:
			var eligible: bool = false
			if data.category == BlockData.BlockCategory.EXTRACTORS:
				eligible = true
			elif data.category == BlockData.BlockCategory.FACTORIES:
				eligible = true
			elif data.tags.has("pump") or data.tags.has("condenser"):
				eligible = true
			if data.category == BlockData.BlockCategory.TURRETS:
				eligible = false
			if data.tags.has("vent_turbine") or data.tags.has("combustion_generator"):
				eligible = false
			if data.is_transport():
				eligible = false
			if not eligible:
				continue
		else:
			if data.max_health <= 0.0:
				continue
		var world_pos: Vector2 = main.grid_to_world(anchor)
		var rect := Rect2(world_pos, Vector2(data.grid_size.x * gs, data.grid_size.y * gs))
		draw_rect(rect, color, false, 2.0)


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
## Static placement-preview render for any layered-spinner block
## (brass mixer, silicon refinery, …). Paints Base → Head → Top from
## the loaded texture set at the same tint the rest of the preview
## uses, so the ghost matches what the placed render will draw.
func _draw_layered_spinner_preview(block_id: StringName, top_pos: Vector2, width: float, height: float, tint: Color = Color.WHITE) -> void:
	var c: CanvasItem = _ccanvas()
	var tex_set: Dictionary = _layered_spinner_textures.get(block_id, {})
	if tex_set.is_empty():
		return
	var size := Vector2(width, height)
	var rect := Rect2(top_pos, size)
	var base_tex: Texture2D = tex_set.get("base", null)
	if base_tex:
		c.draw_texture_rect(base_tex, rect, false, tint)
	var head_tex: Texture2D = tex_set.get("head", null)
	if head_tex:
		# Head is drawn at angle 0 in the preview — no spin state to
		# read for an unplaced block.
		c.draw_texture_rect(head_tex, rect, false, tint)
	var top_tex: Texture2D = tex_set.get("top", null)
	if top_tex:
		c.draw_texture_rect(top_tex, rect, false, tint)


func _draw_vent_turbine_preview(top_pos: Vector2, width: float, height: float, tint: Color = Color.WHITE) -> void:
	var c: CanvasItem = _ccanvas()
	var size := Vector2(width, height)
	if _vent_turbine_preview_texture:
		c.draw_texture_rect(_vent_turbine_preview_texture, Rect2(top_pos, size), false, tint)
		return
	if _vent_turbine_base_texture == null:
		return
	if _vent_turbine_inner_texture:
		c.draw_texture_rect(_vent_turbine_inner_texture, Rect2(top_pos, size), false, tint)
	c.draw_texture_rect(_vent_turbine_base_texture, Rect2(top_pos, size), false, tint)


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
	var _sv_size := Vector2(sv.size)
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

	# --- Ground scraper / impact drill: base sprite + their rotating /
	# pulsing head on top. The live draw routes through
	# _draw_scraper_head / _draw_impact_head and adds the head over the
	# block body; the bake mirrors that so the placement preview
	# doesn't look like a headless base plate.
	if data.tags.has("scraper_head") or data.tags.has("impact_head"):
		if data.base_sprite:
			add_fill.call(data.base_sprite, pad, block_size)
		elif data.top_sprite:
			add_fill.call(data.top_sprite, pad, block_size)
		var head_tex: Texture2D = null
		if data.tags.has("scraper_head"):
			head_tex = _scraper_head_texture
		else:
			head_tex = _impact_head_texture
		if head_tex:
			# Scraper sits at its idle angle (0); impact head at its
			# max-scale rest pose — matches what the player sees on a
			# block that's powered but not yet cycling.
			add_fill.call(head_tex, pad, block_size)
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




## Static (frozen) vent-condenser layered preview. Mirrors the turbine
## preview — uses the pre-baked composite when ready, falls back to
## individual layers while the bake is still pending.
func _draw_vent_condenser_preview(top_pos: Vector2, width: float, height: float, tint: Color = Color.WHITE) -> void:
	var c: CanvasItem = _ccanvas()
	var size := Vector2(width, height)
	if _vent_condenser_preview_texture:
		c.draw_texture_rect(_vent_condenser_preview_texture, Rect2(top_pos, size), false, tint)
		return
	if _vent_condenser_base_texture == null:
		return
	if _vent_condenser_inner_texture:
		c.draw_texture_rect(_vent_condenser_inner_texture, Rect2(top_pos, size), false, tint)
	c.draw_texture_rect(_vent_condenser_base_texture, Rect2(top_pos, size), false, tint)


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






## Generic layered-spinner draw: static Base → rotating Head → static
## Top, all sized to the block's footprint. Reads the texture set
## from `_layered_spinner_textures[block_id]` and the head angle from
## the per-anchor state dict.
func _draw_layered_spinner(grid_pos: Vector2i, block_id: StringName, top_pos: Vector2, width: float, height: float, tint: Color = Color.WHITE) -> void:
	var tex_set: Dictionary = _layered_spinner_textures.get(block_id, {})
	var base_tex: Texture2D = tex_set.get("base", null)
	if base_tex == null:
		return
	if not _layered_spinner_state.has(grid_pos):
		_layered_spinner_state[grid_pos] = {"angle": 0.0, "vel": 0.0, "prev_timer": -1.0}
	var s: Dictionary = _layered_spinner_state[grid_pos]
	var angle: float = float(s.get("angle", 0.0))
	var size := Vector2(width, height)
	var center: Vector2 = top_pos + Vector2(width * 0.5, height * 0.5)
	# Base (bottom layer, static).
	draw_texture_rect(base_tex, Rect2(top_pos, size), false, tint)
	# Head (middle layer, rotating).
	var head_tex: Texture2D = tex_set.get("head", null)
	if head_tex:
		draw_set_transform(center, angle)
		draw_texture_rect(head_tex, Rect2(-size * 0.5, size), false, tint)
		draw_set_transform(Vector2.ZERO, 0.0)
	# Top (top layer, static).
	var top_tex: Texture2D = tex_set.get("top", null)
	if top_tex:
		draw_texture_rect(top_tex, Rect2(top_pos, size), false, tint)


# Head-spin state portability (crane pickup / drop) lives on
# SpinnerHeadSystem — see capture_spin_state / restore_spin_state /
# tick_held_spin_state there.





## Handles Q or R key to rotate, L key to toggle linking mode.
func _input(event: InputEvent) -> void:
	if main.has_method("is_ui_blocking") and main.is_ui_blocking():
		return
	# --- SCHEMATIC CAPTURE (C) → straight into copy/paste placement ---
	# Pressing C again while in paste mode begins a fresh selection
	# (the previous paste buffer is replaced on release).
	if event.is_action("schematic_capture") and _schematic:
		if event.is_action_pressed("schematic_capture") and not _schematic.mode:
			# A fresh C-drag overrides any active paste session.
			if _schematic.placing:
				_schematic.placing = false
			var mw = get_global_mouse_position()
			_schematic.mode = true
			_schematic.confirmed = false
			_schematic.start = main.world_to_grid(mw)
			_schematic.end = _schematic.start
			_schematic.dragging = true
			queue_redraw()
		elif event.is_action_released("schematic_capture") and _schematic.dragging:
			var mw = get_global_mouse_position()
			_schematic.end = main.world_to_grid(mw)
			_schematic.dragging = false
			_schematic.mode = false
			_schematic.confirmed = false
			_schematic.enter_paste_mode_from_rect(_schematic.start, _schematic.end)
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
		if _world_ui and _world_ui.world_menu_open:
			_world_ui.close()
			get_viewport().set_input_as_handled()
			return
		if _schematic and (_schematic.mode or _schematic.dragging):
			_schematic.mode = false
			_schematic.confirmed = false
			_schematic.dragging = false
			queue_redraw()
		elif _schematic and _schematic.placing:
			_schematic.placing = false
			queue_redraw()
	if _schematic and _schematic.dragging and event is InputEventMouseMotion:
		var mw = get_global_mouse_position()
		_schematic.end = main.world_to_grid(mw)
		queue_redraw()

	# Right-click cancels an active schematic selection or paste-mode
	# stamp — same effect as Esc, just reachable without leaving the
	# mouse. Consume the event so it doesn't fall through to "rotate
	# placed block" or any other right-click handler.
	if _schematic and event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if _schematic.mode or _schematic.dragging:
			_schematic.mode = false
			_schematic.confirmed = false
			_schematic.dragging = false
			queue_redraw()
			get_viewport().set_input_as_handled()
			return
		elif _schematic.placing:
			_schematic.placing = false
			queue_redraw()
			get_viewport().set_input_as_handled()
			return

	# --- SCHEMATIC PLACEMENT: click to place, flip-x / flip-y / save actions ---
	if _schematic and _schematic.placing and event is InputEventKey and event.pressed and not event.echo:
		if event.is_action_pressed("schematic_flip_x"):
			_schematic.flip_placement_x()
			get_viewport().set_input_as_handled()
			return
		elif event.is_action_pressed("schematic_flip_y"):
			_schematic.flip_placement_y()
			get_viewport().set_input_as_handled()
			return
		elif event.is_action_pressed("schematic_save_placement"):
			_schematic.show_save_dialog_from_placement()
			get_viewport().set_input_as_handled()
			return
	if _schematic and _schematic.placing and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if _is_controlling_non_builder():
			return
		var mouse_world: Vector2 = get_global_mouse_position()
		_schematic.execute_placement(main.world_to_grid(mouse_world))
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
		# Spinner-head inertial ticks moved to SpinnerHeadSystem — that
		# node's own _process drives the tick under PROCESS_MODE_PAUSABLE,
		# so we no longer call them from here.
		_tick_fluid_bar_display(_delta)
		# Autonomous crane AI + held-payload simulation moved to
		# CraneSystem — that node's own _process drives both ticks
		# under PROCESS_MODE_PAUSABLE.
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
		# Build-beam stripe phase ticks independent of the belt-scroll
		# toggle so the build laser still animates when the player has
		# belt scrolling disabled.
		_build_beam_phase = fposmod(_build_beam_phase + _delta / _BUILD_BEAM_PERIOD, 1.0)
		_tick_menders(_delta)

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

	# Archive decoder ticking lives on the ArchiveDecoderSystem sibling
	# node now and ticks itself. Only the scan-line phase still belongs
	# to the building draw path.
	if not ("world_paused" in main and main.world_paused):
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
	if _world_ui and _world_ui.world_menu_open:
		var mw = get_global_mouse_position()
		var new_hovered: int = _world_ui.hit_test(mw)
		if new_hovered != _world_ui.world_menu_hovered:
			_world_ui.world_menu_hovered = new_hovered
			queue_redraw()
		if _world_ui.storage_panel_open:
			var sh: int = _world_ui.storage_hit_test(mw)
			if sh != _world_ui.storage_panel_hovered:
				_world_ui.storage_panel_hovered = sh
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
	# Tint-only flag: same checks minus the build-range constraint, so
	# hovering outside the drone's reach still reads as a valid ghost.
	can_place_excluding_range = _can_place_ignoring_range(
		preview_grid_pos, main.selected_building, main.placement_rotation)

	# Compute drag cells (axis-locked line or pathfinding)
	if _drag_placing:
		_drag_cells.clear()
		var data = Registry.get_block(main.selected_building)
		var grid_w: int = data.grid_size.x if data else 1
		var grid_h: int = data.grid_size.y if data else 1
		var alt_held := Input.is_action_pressed("pathfind_modifier")

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

	# Same multi-builder boost as `_tick_progressive_build` — N builders
	# in range = N× advance per tick.
	var swap_speed: int = _count_builders_in_range_of(anchor)
	entry["progress"] = float(entry.get("progress", 0.0)) + delta * float(swap_speed)
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

	# Advance progress — scaled by the number of builders (primary drone,
	# AI shardlings, and assist-mode player units) whose ranges cover
	# this anchor, so N builders on one block finish it N× as fast.
	var build_speed: int = _count_builders_in_range_of(anchor)
	main.building_build_progress[anchor] += delta * float(build_speed)
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
	# Multi-builder boost: tearing a block down also speeds up with
	# extra drones / assisting units in range, mirroring builds.
	var decon_speed: int = _count_builders_in_range_of(anchor)
	entry["progress"] += delta * float(decon_speed)

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
		# Deconstruct pulse + shrapnel — fire BEFORE destroy_building so
		# the BlockData is still resolvable for footprint sizing.
		var decon_data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if decon_data != null:
			var po = get_node_or_null("/root/Main/ParticleOverlay")
			if po and po.has_method("spawn_decon_pulse"):
				po.spawn_decon_pulse(anchor, decon_data.grid_size)
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
	# Vent extractors (e.g. Water Extractor on sand) must sit on their required
	# floor tile — reject the placement unless at least one footprint cell is on
	# `vent_tile`, matching the cell where it actually produces fluid.
	if data.vent_tile != &"" and terrain != null and "floor_tiles" in terrain:
		var on_vent_tile: bool = false
		for vx in range(data.grid_size.x):
			for vy in range(data.grid_size.y):
				if StringName(terrain.floor_tiles.get(grid_pos + Vector2i(vx, vy), &"")) == data.vent_tile:
					on_vent_tile = true
					break
			if on_vent_tile:
				break
		if not on_vent_tile:
			return false
	# If the new block is a member of a swap family (belt/duct/pipe/etc),
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
				# Platforms bridge SHALLOW water only — depths 1-2, where the
				# shore tile is still visible beneath the surface. Reject dry
				# land (0) and deep water (3, fully submerged). The red
				# "can't place" overlay falls out of this same check.
				if is_platform and not has_platform_under and (depth <= 0 or depth >= 3):
					return false
				if depth > 0 and not has_platform_under:
					# Shallow water (depth 1) is buildable by ANY block, like land.
					if depth == 1:
						pass
					# Platforms reach here only for depth 2 (deep water and dry
					# land were already rejected above); they bridge it.
					elif is_platform:
						pass
					# Pumps can be placed on depth 1 or 2 water (needs to stand
					# on the liquid surface to extract).
					elif is_pump and depth <= 2:
						pass
					else:
						return false
	return true


## Returns true if the position is within build range — either ANY
## player_drone-script node's range (primary drone OR AI shardling
## from a secondary core) OR the range of any player unit currently
## in `assist_player_build` mode. Build / deconstruct ticks gate on
## this, so an assisting unit camping next to a half-built wall lets
## the build progress without the drone needing to be nearby.
func _is_in_build_range(grid_pos: Vector2i) -> bool:
	var drones: Array = _all_player_drones()
	for d in drones:
		if d.is_in_build_range(grid_pos):
			return true
	# Fall back to assisting player units. An 8-tile Chebyshev radius
	# matches the soft "in range" threshold used in _tick_assist_build.
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if unit_mgr and "player_units" in unit_mgr:
		for u in unit_mgr.player_units:
			if u == null or not is_instance_valid(u):
				continue
			if not ("assist_player_build" in u) or not u.assist_player_build:
				continue
			var ug: Vector2i = main.world_to_grid(u.position)
			var dx: int = absi(ug.x - grid_pos.x)
			var dy: int = absi(ug.y - grid_pos.y)
			if maxi(dx, dy) <= 8:
				return true
	# When there's no drone at all (legacy / map editor), preserve the
	# old "no gate" behavior so builds still work.
	if drones.is_empty():
		return true
	return false


## Returns every live drone-script node directly under Main: the
## primary "PlayerDrone" plus any AI shardlings spawned for secondary
## LUMINA cores ("AIShardling_<x>_<y>"). They share player_drone.gd
## so the build-range / fire / heal helpers all work on them.
func _all_player_drones() -> Array:
	var out: Array = []
	if main == null:
		return out
	for child in main.get_children():
		if child == null or not is_instance_valid(child):
			continue
		if not child.has_method("is_in_build_range"):
			continue
		# FEROX shardlings share the player_drone.gd script but must
		# NOT contribute to player build/deconstruct progress. Skip
		# any drone flying the `ferox_controlled` flag.
		if "ferox_controlled" in child and bool(child.get("ferox_controlled")):
			continue
		out.append(child)
	return out


## Counts every builder whose range covers `anchor` — used to scale
## the build/deconstruct tick rate so N drones building a single
## block advance N× faster than one. Clamped to >= 1 so a build
## that's somehow ticking without a builder doesn't stall on a 0×
## multiplier.
func _count_builders_in_range_of(anchor: Vector2i) -> int:
	var count: int = 0
	for d in _all_player_drones():
		if d.is_in_build_range(anchor):
			count += 1
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if unit_mgr and "player_units" in unit_mgr:
		for u in unit_mgr.player_units:
			if u == null or not is_instance_valid(u):
				continue
			if not ("assist_player_build" in u) or not u.assist_player_build:
				continue
			var ug: Vector2i = main.world_to_grid(u.position)
			var dx: int = absi(ug.x - anchor.x)
			var dy: int = absi(ug.y - anchor.y)
			if maxi(dx, dy) <= 8:
				count += 1
	return maxi(count, 1)


## Every world-space position currently contributing build effort to
## `anchor` — primary drone, AI shardlings, assisting player units —
## along with their facing angle so the beam can root at the front
## of each unit's sprite. Returned as
##   [{"pos": Vector2, "facing": float}, ...]
## FEROX shardlings (ferox_controlled drones) currently rebuilding the
## block at `anchor` — i.e. they've broken ground (`_ferox_rebuild_placed`)
## and their target's grid_pos matches. Returns the same {pos, facing}
## shape as `_builders_with_facing_for` so the work-laser can root at the
## shardling's sprite front.
func _ferox_builders_with_facing_for(anchor: Vector2i) -> Array:
	var out: Array = []
	if main == null:
		return out
	for child in main.get_children():
		if child == null or not is_instance_valid(child):
			continue
		if not ("ferox_controlled" in child) or not bool(child.get("ferox_controlled")):
			continue
		if not ("_ferox_rebuild_placed" in child) or not bool(child.get("_ferox_rebuild_placed")):
			continue
		var tgt = child.get("_ferox_rebuild_target") if "_ferox_rebuild_target" in child else null
		if tgt == null or typeof(tgt) != TYPE_DICTIONARY:
			continue
		if Vector2i(tgt.get("grid_pos", Vector2i(-9999, -9999))) != anchor:
			continue
		var fa: float = float(child.get("facing_angle")) if "facing_angle" in child else 0.0
		out.append({"pos": child.position, "facing": fa})
	return out


func _builders_with_facing_for(anchor: Vector2i) -> Array:
	# FEROX rebuilds are carried out by FEROX shardlings, not player drones;
	# route the beam's root points to whichever shardling is on the job.
	if main != null and main.get_building_faction(anchor) == main.Faction.FEROX:
		return _ferox_builders_with_facing_for(anchor)
	var out: Array = []
	for d in _all_player_drones():
		if not d.is_in_build_range(anchor):
			continue
		var fa: float = 0.0
		if "facing_angle" in d:
			fa = float(d.facing_angle)
		out.append({"pos": d.position, "facing": fa})
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if unit_mgr and "player_units" in unit_mgr:
		for u in unit_mgr.player_units:
			if u == null or not is_instance_valid(u):
				continue
			if not ("assist_player_build" in u) or not u.assist_player_build:
				continue
			var ug: Vector2i = main.world_to_grid(u.position)
			var dx: int = absi(ug.x - anchor.x)
			var dy: int = absi(ug.y - anchor.y)
			if maxi(dx, dy) > 8:
				continue
			var fa: float = 0.0
			if "facing_angle" in u:
				fa = float(u.facing_angle)
			out.append({"pos": u.position, "facing": fa})
	return out


## Mindustry-style work-laser: filled translucent triangle from each
## builder to the two endpoints of the reveal line, with a darker
## stripe band that scrolls along the unit→block axis plus a pulsing
## diamond at the unit's tip. Yellow + forward-scroll for builds,
## red + reverse-scroll for deconstruction.
##   `line_top` / `line_bot` — endpoints of the reveal line.
##   `anchor`                — block being worked on (for builder lookup).
##   `hue`                   — base saturated colour (yellow or red).
##   `reverse_stripe`        — false: stripes slide unit→block (build).
##                              true: stripes slide block→unit (decon).
func _draw_active_build_beams(anchor: Vector2i, line_top: Vector2, line_bot: Vector2,
		hue: Color = Color(1.0, 0.9, 0.2), reverse_stripe: bool = false) -> void:
	# Hide the laser while the player has explicitly paused construction
	# (build_paused) — that's a deliberate "stop working" toggle. World
	# pause is different: the player just wants time to stop. Keep the
	# laser drawn there so they can still see what the drone is on; the
	# stripe phase doesn't advance under world pause (see `_process`),
	# so the moving bands freeze in place naturally.
	if "build_paused" in main and main.build_paused:
		return
	var builders: Array = _builders_with_facing_for(anchor)
	if builders.is_empty():
		return
	# Derive the four palette tints from the supplied hue so the build
	# and decon flavours stay in lockstep visually.
	var fill_color := Color(hue.r, hue.g, hue.b, 0.38)
	var edge_color := Color(hue.r, hue.g, hue.b, 0.55)
	var stripe_color := Color(hue.r * 0.85, hue.g * 0.78, hue.b * 0.55, 0.45)
	# Two stripes scrolling on offset phases give the "moving belt of
	# light" feel without needing an actual shader. Decon walks the
	# phase backward so its band reads as travel block→unit instead of
	# unit→block — top-right → down-left in screen space.
	const _STRIPE_HALF_WIDTH := 0.05
	var base_phase: float = (1.0 - _build_beam_phase) if reverse_stripe else _build_beam_phase
	var phases: Array[float] = [
		base_phase,
		fposmod(base_phase + 0.5, 1.0),
	]
	for b in builders:
		var unit_pos: Vector2 = b["pos"]
		# Push the beam origin out to the front of the unit's sprite —
		# the same convention movement uses (sprite is authored facing
		# up, so forward = facing_angle + PI/2). Without this the
		# triangle's apex would sit at the center of the chassis and
		# the beam visibly emerges from the body's midpoint.
		var facing: float = float(b["facing"])
		var fwd: Vector2 = Vector2.from_angle(facing + PI / 2.0)
		var origin: Vector2 = unit_pos + fwd * (main.GRID_SIZE * 0.25)
		# Filled triangle: origin → line_top → line_bot.
		var tri := PackedVector2Array([origin, line_top, line_bot])
		draw_colored_polygon(tri, fill_color)
		# Two outer lines from the origin to each end of the reveal
		# line so the triangle reads as a beam rather than a vague
		# wedge of fog.
		draw_line(origin, line_top, edge_color, 1.5)
		draw_line(origin, line_bot, edge_color, 1.5)
		# Scrolling stripe(s) — for each phase, a quadrilateral that
		# spans the same fraction-of-the-way along both outer edges.
		# Because both edges share the same origin and end at the
		# reveal line, the quad is naturally trapezoid-shaped (wide
		# at the block, narrow at the unit) and stays clipped inside
		# the outer triangle for free.
		# Shear gives each stripe a diagonal lean. For builds, the top
		# edge sits slightly ahead of the bottom edge (leading corner
		# down-left → top-right). For decon, flip the sign so the
		# lean reverses to top-right → down-left.
		const _STRIPE_SHEAR := 0.06
		var shear: float = -_STRIPE_SHEAR if reverse_stripe else _STRIPE_SHEAR
		for ph in phases:
			var t0: float = ph - _STRIPE_HALF_WIDTH
			var t1: float = ph + _STRIPE_HALF_WIDTH
			if t1 <= 0.0 or t0 >= 1.0:
				continue
			var top_t0: float = clampf(t0 + shear, 0.0, 1.0)
			var top_t1: float = clampf(t1 + shear, 0.0, 1.0)
			var bot_t0: float = clampf(t0 - shear, 0.0, 1.0)
			var bot_t1: float = clampf(t1 - shear, 0.0, 1.0)
			var top_a: Vector2 = origin.lerp(line_top, top_t0)
			var top_b: Vector2 = origin.lerp(line_top, top_t1)
			var bot_a: Vector2 = origin.lerp(line_bot, bot_t0)
			var bot_b: Vector2 = origin.lerp(line_bot, bot_t1)
			var stripe := PackedVector2Array([top_a, top_b, bot_b, bot_a])
			draw_colored_polygon(stripe, stripe_color)
	# Diamond is rendered separately (via crane_overlay at z 4096) so
	# it sits ON TOP of the drone / unit sprite (z 4095) rather than
	# being clipped by the chassis. See `_draw_active_work_diamonds`.


## Draws the pulsing emitter diamond at one builder's tip, oriented
## along `axis` (unit→block) with `hue` colouring. Routed onto
## whichever CanvasItem is currently driving the draw — the
## crane_overlay's `_draw` parks itself in `_crane_draw_canvas`
## before invoking us so the diamond lands above the drone sprite.
func _draw_build_beam_diamond_on(canvas: CanvasItem, origin: Vector2, axis: Vector2, hue: Color) -> void:
	if canvas == null:
		return
	if axis.length_squared() < 0.0001:
		return
	var perp: Vector2 = Vector2(-axis.y, axis.x)
	var pulse: float = sin(_build_beam_phase * TAU * 2.0)
	var base_size: float = main.GRID_SIZE * 0.09
	var size_d: float = base_size * (1.0 + pulse * 0.20)
	var fwd_size: float = size_d * 1.4
	var alpha: float = clampf(0.7 + pulse * 0.25, 0.0, 1.0)
	var diamond := PackedVector2Array([
		origin + axis * fwd_size,        # tip → block
		origin + perp * size_d,          # right
		origin - axis * fwd_size * 0.7,  # tail
		origin - perp * size_d,          # left
	])
	canvas.draw_colored_polygon(diamond, Color(hue.r, hue.g, hue.b, alpha))
	var outline_hue := Color(
		clampf(hue.r + 0.0, 0.0, 1.0),
		clampf(hue.g + 0.05, 0.0, 1.0),
		clampf(hue.b + 0.2, 0.0, 1.0),
	)
	canvas.draw_polyline(PackedVector2Array([
		diamond[0], diamond[1], diamond[2], diamond[3], diamond[0],
	]), Color(outline_hue.r, outline_hue.g, outline_hue.b, clampf(alpha + 0.2, 0.0, 1.0)), 1.0)


## Iterates every actively-progressing build / deconstruct anchor and
## paints a pulsing diamond at each contributing builder's tip,
## colour-coded yellow for builds and red for decons. Called from
## the crane_overlay so the result renders at z 4096 — above units
## (z ~70) and drones (z 4095). Without this routing the diamond
## would sit at the BuildingSystem's default z and disappear behind
## the very sprite it's supposed to emerge from.
func _draw_active_work_diamonds() -> void:
	# Pulsing diamond is the "I'm actively working on this" cue. Hide
	# it only when the player has explicitly paused construction —
	# under plain world pause we keep it visible (frozen in mid-pulse
	# since `_build_beam_phase` doesn't advance) so it stays in sync
	# with the laser triangle next to it.
	if "build_paused" in main and main.build_paused:
		return
	var canvas: CanvasItem = _crane_draw_canvas if _crane_draw_canvas != null else self
	# Active build anchor — at most one ticks per frame (the work
	# queue advances a single entry at a time).
	var active_anchor: Vector2i = _get_active_work_anchor()
	if active_anchor == _NO_ACTIVE_WORK:
		return
	var gs: float = float(main.GRID_SIZE)
	var build_data = Registry.get_block(main.placed_buildings.get(active_anchor, &""))
	if build_data == null:
		return
	var block_size: Vector2i = build_data.grid_size
	var block_world: Vector2 = main.grid_to_world(active_anchor)
	var top_pos: Vector2 = block_world + _get_top_offset(block_world)
	var block_w: float = gs * block_size.x
	var block_h: float = gs * block_size.y
	# Are we building or deconstructing? Build state takes priority.
	var is_build: bool = "building_build_progress" in main and main.building_build_progress.has(active_anchor)
	var is_decon: bool = (not is_build) and "building_deconstruct_progress" in main \
			and main.building_deconstruct_progress.has(active_anchor)
	if not (is_build or is_decon):
		return
	var hue: Color
	var line_x: float
	if is_build:
		var bp: float = main.get_build_progress_pct(active_anchor)
		if bp <= 0.0 or bp >= 1.0:
			return
		line_x = top_pos.x + block_w * bp
		hue = Color(1.0, 0.9, 0.2)
	else:
		var entry: Dictionary = main.building_deconstruct_progress[active_anchor]
		var bt: float = float(entry.get("build_time", 1.0))
		var dp: float = clampf(float(entry.get("progress", 0.0)) / maxf(bt, 0.0001), 0.0, 1.0)
		var max_pct: float = float(entry.get("max_build_pct", 1.0))
		line_x = top_pos.x + block_w * (max_pct * (1.0 - dp))
		hue = Color(0.95, 0.25, 0.25)
	var line_mid := Vector2(line_x, top_pos.y + block_h * 0.5)
	for b in _builders_with_facing_for(active_anchor):
		var unit_pos: Vector2 = b["pos"]
		var facing: float = float(b["facing"])
		var fwd: Vector2 = Vector2.from_angle(facing + PI / 2.0)
		# Sit the diamond at the front edge of the unit sprite. The
		# diamond renders on the crane_overlay at z 4096 so it stays
		# visible over the drone art (z 4095) even when it sits
		# directly on top of the chassis nose.
		var origin: Vector2 = unit_pos + fwd * (gs * 0.50)
		var axis: Vector2 = (line_mid - origin)
		if axis.length_squared() < 0.0001:
			continue
		axis = axis.normalized()
		_draw_build_beam_diamond_on(canvas, origin, axis, hue)


## Paints the build/decon overlays that the user expects to sit on TOP
## of every in-world layer — the dim wash over the unbuilt / deconstructed
## portion and the turret head preview for in-progress turrets. Invoked
## from `crane_overlay._draw()` which parks itself in `_crane_draw_canvas`
## first, so every `c.draw_*()` call here lands at z 4096 (above units at
## 4095 and the projectile overlay at 4095).
func _draw_active_build_overlays_high_z() -> void:
	var c: CanvasItem = _ccanvas()
	if c == null:
		return
	var gs: float = float(main.GRID_SIZE)
	var has_active_work: bool = false
	var active_work_anchor: Vector2i = Vector2i(-9999, -9999)
	if has_method("_get_active_work_anchor"):
		active_work_anchor = _get_active_work_anchor()
		has_active_work = active_work_anchor != _NO_ACTIVE_WORK
	# --- Build progress overlays ---
	if "building_build_progress" in main and not main.building_build_progress.is_empty():
		for grid_pos in main.building_build_progress:
			if not main.placed_buildings.has(grid_pos):
				continue
			var block_id: StringName = main.placed_buildings[grid_pos]
			var data: BlockData = Registry.get_block(block_id)
			if data == null:
				continue
			var b_size: Vector2i = data.grid_size
			var b_world: Vector2 = main.grid_to_world(grid_pos)
			var b_offset: Vector2 = _get_top_offset(b_world) * _get_height_scale(block_id)
			var b_width: float = gs * b_size.x
			var b_height: float = gs * b_size.y
			var b_top_pos: Vector2 = b_world + b_offset
			var pct: float = main.get_build_progress_pct(grid_pos)
			var b_rot: int = int(main.building_rotation.get(grid_pos, 0))
			var is_queued: bool = (pct == 0.0) and not (has_active_work and active_work_anchor == grid_pos)
			if is_queued:
				# Queued block — paint the full faded ghost (block art +
				# yellow outline) up here, AND the turret head preview.
				# Skip the dim wash; the faded ghost already reads as
				# "not yet built".
				_draw_block_ghost_preview(grid_pos, block_id, data, b_top_pos, b_width, b_height, b_rot, false)
				if data.is_turret():
					_draw_turret_preview_heads(data, b_top_pos, b_width, b_height, b_rot, Color(1, 1, 1, 0.45))
			else:
				# Active build — dim wash on the unbuilt right portion,
				# plus the bright head preview at 0.7 alpha.
				var reveal_x: float = b_width * pct
				var unbuilt_w: float = b_width - reveal_x
				if unbuilt_w > 0.0:
					c.draw_rect(
						Rect2(b_top_pos.x + reveal_x, b_top_pos.y, unbuilt_w, b_height),
						Color(0, 0, 0, 0.45), true,
					)
				if data.is_turret():
					_draw_turret_preview_heads(data, b_top_pos, b_width, b_height, b_rot, Color(1, 1, 1, 0.7))
	# --- Deconstruct overlays ---
	if "building_deconstruct_progress" in main and not main.building_deconstruct_progress.is_empty():
		for grid_pos in main.building_deconstruct_progress:
			var d_entry: Dictionary = main.building_deconstruct_progress[grid_pos]
			var d_block_id: StringName = d_entry.get("block_id", &"")
			if d_block_id == &"":
				continue
			var d_data: BlockData = Registry.get_block(d_block_id)
			if d_data == null:
				continue
			var d_size: Vector2i = d_data.grid_size
			var d_world: Vector2 = main.grid_to_world(grid_pos)
			var d_offset: Vector2 = _get_top_offset(d_world) * _get_height_scale(d_block_id)
			var d_width: float = gs * d_size.x
			var d_height: float = gs * d_size.y
			var d_top_pos: Vector2 = d_world + d_offset
			var d_bt: float = float(d_entry.get("build_time", 1.0))
			var d_pct: float = clampf(float(d_entry.get("progress", 0.0)) / maxf(d_bt, 0.0001), 0.0, 1.0)
			var max_pct: float = float(d_entry.get("max_build_pct", 1.0))
			var line_pct: float = max_pct * (1.0 - d_pct)
			var line_x: float = d_top_pos.x + d_width * line_pct
			if line_pct < max_pct:
				var dark_left: float = line_x
				var dark_right: float = d_top_pos.x + d_width * max_pct
				c.draw_rect(
					Rect2(dark_left, d_top_pos.y, dark_right - dark_left, d_height),
					Color(0, 0, 0, 0.45), true,
				)
			if max_pct < 1.0:
				var never_left: float = d_top_pos.x + d_width * max_pct
				c.draw_rect(
					Rect2(never_left, d_top_pos.y, d_width * (1.0 - max_pct), d_height),
					Color(0, 0, 0, 0.45), true,
				)


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
	if _is_build_paused():
		return _NO_ACTIVE_WORK
	return _get_active_work_anchor()


## True if either the world or the build queue is paused, i.e. the
## drone is NOT making progress this frame. The "active work" visuals
## (laser triangle + pulsing diamond) consult this to hide themselves
## during pause — without it they keep drawing as though the build
## were ticking, which reads as a bug.
func _is_build_paused() -> bool:
	if "world_paused" in main and main.world_paused:
		return true
	if "build_paused" in main and main.build_paused:
		return true
	return false


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

	# Floor miners accept floor-ore patches plus block-specific floor
	# sources; regular drills only accept wall-embedded ores. Without
	# this split, placing a mechanical drill next to a coal patch would
	# succeed but the live tick would refuse to mine — confusing.
	var is_floor_miner: bool = data.tags.has("floor_miner")
	# Floor miners (ground scraper) sit DIRECTLY on top of their source —
	# the front edge is past the patch, so check the FOOTPRINT cells
	# instead. Any covered source tile passes placement; the
	# efficiency calc determines how productive that ends up being.
	if is_floor_miner:
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				if _ore_matches_miner(terrain, grid_pos + Vector2i(x, y), true, data):
					return true
		return false
	# Drills accept ore anywhere within their data-driven mine_range
	# beyond the front edge — so a plasma bore (mine_range=4) can be
	# placed up to 4 tiles back from the ore wall.
	var max_extend: int = maxi(data.mine_range, 1)
	var front_cells = _get_front_edge(grid_pos, data.grid_size, rotation)
	for cell in front_cells:
		if _ore_matches_miner(terrain, cell, is_floor_miner, data):
			return true
		for step in range(1, max_extend + 1):
			if _ore_matches_miner(terrain, cell + dir * step, is_floor_miner, data):
				return true
	return false


func _ore_matches_miner(terrain, cell: Vector2i, is_floor_miner: bool, data: BlockData = null) -> bool:
	var ore_data: TerrainTileData = terrain.get_ore_at(cell)
	if is_floor_miner and data != null and data.id == &"ground_scraper":
		var floor_id: StringName = StringName(terrain.floor_tiles.get(cell, &""))
		var floor_data: TerrainTileData = Registry.get_tile(floor_id)
		if floor_data != null and floor_data.tags.has("sand"):
			return true
	if is_floor_miner and data != null and data.id == &"impact_drill":
		var floor_id_s: StringName = StringName(terrain.floor_tiles.get(cell, &""))
		var floor_data_s: TerrainTileData = Registry.get_tile(floor_id_s)
		if floor_data_s != null and floor_data_s.tags.has("salt"):
			return true
	if ore_data == null:
		return false
	var is_floor_ore: bool = ore_data.tags.has("floor_ore")
	if is_floor_miner:
		if not is_floor_ore:
			return false
	else:
		if is_floor_ore:
			return false
	# Whitelist filter: when the block lists `accepted_ores`, the tile
	# id must match. Lets the ground scraper claim coal + sulfur while
	# impact / earthquake / eruption harvesters take the rest.
	if data != null and data.accepted_ores.size() > 0:
		if not data.accepted_ores.has(ore_data.id):
			return false
	return true


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
		if _is_mineable_wall(terrain, cell, data):
			return true
		if _is_mineable_wall(terrain, cell + dir, data):
			return true
	return false


## Wall-miner helper: true if the cell is a wall this block can mine
## (consults `data.accepted_walls`, defaulting to blackstone_wall) and
## has no ore on it.
func _is_mineable_wall(terrain: Node, cell: Vector2i, data: BlockData = null) -> bool:
	if terrain.get_ore_at(cell) != null:
		return false
	var wall_id: StringName = StringName(terrain.wall_tiles.get(cell, &""))
	if wall_id == &"":
		return false
	if data != null and data.accepted_walls.size() > 0:
		return data.accepted_walls.has(wall_id)
	return wall_id == &"blackstone_wall"


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
					if _world_ui and _world_ui.world_menu_open:
						var mouse_world = get_global_mouse_position()
						var hit: int = _world_ui.hit_test(mouse_world)
						if hit >= 0:
							_world_ui.apply_selection(hit)
						elif _world_ui.storage_panel_open:
							var shit: int = _world_ui.storage_hit_test(mouse_world)
							if shit >= 0:
								var sid: StringName = StringName(_world_ui.storage_panel_items[shit].get("id", &""))
								if sid != &"":
									_withdraw_block_to_drone(_world_ui.storage_panel_pos, sid)
							else:
								_world_ui.close()
						else:
							_world_ui.close()
						# Guard against a pending scene change (e.g. the
						# launchpad's `__pick` action) — if BuildingSystem
						# was already removed from the tree by `_apply_…`,
						# `get_viewport()` returns null and the trailing
						# `set_input_as_handled` would crash.
						var vp_after_apply = get_viewport()
						if vp_after_apply:
							vp_after_apply.set_input_as_handled()
						return
					# No building selected — first check for work-queue interactions
					# (pause/resume/promote), then fall through to block menus.
					var mouse_world = get_global_mouse_position()
					var click_pos = main.world_to_grid(mouse_world)
					if _handle_work_click(click_pos):
						get_viewport().set_input_as_handled()
						return
					if not main.placed_buildings.has(click_pos):
						# Clicking empty ground while a link source is pending
						# abandons the selection — same feel as clicking a
						# non-linkable block.
						if link_source != Vector2i(-1, -1):
							link_source = Vector2i(-1, -1)
							_link_just_linked = Vector2i(-1, -1)
							queue_redraw()
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
						# Clicking a DERELICT block claims it for the player.
						# Reuses the rect-conversion helper with a 1-tile rect
						# so the conversion flash + faction flip happen the
						# same way as the Hold-B rebuild rectangle.
						if click_faction == FACTION_DERELICT and main.has_method("convert_derelict_in_rect"):
							main.convert_derelict_in_rect(click_anchor, click_anchor)
							get_viewport().set_input_as_handled()
							return
						if click_faction == FACTION_LUMINA and click_data:
							# Shift+click on a duct bridge that has any
							# incoming links opens the per-input filter menu
							# instead of running the link / popup flow.
							# Without incoming links there's nothing to
							# filter so we fall through to the normal click.
							if event.shift_pressed and click_data.id == &"duct_bridge":
								var power_sys_shift = get_node_or_null("/root/Main/PowerSystem")
								var has_incoming: bool = false
								if power_sys_shift and power_sys_shift.has_method("get_links_as_destination_all"):
									has_incoming = not (power_sys_shift.get_links_as_destination_all(click_anchor) as Array).is_empty()
								if has_incoming:
									if _world_ui: _world_ui.open("duct_filter", click_anchor)
									get_viewport().set_input_as_handled()
									return
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
							# A click that did anything link-related (set
							# source, established a link, cleared source)
							# should NOT also pop the block's storage /
							# sorter / constructor menu — otherwise selecting
							# a bridge as a link source instantly opens its
							# in-transit-items popup and you have to click
							# through that before the second click can land.
							if link_changed:
								get_viewport().set_input_as_handled()
								return
							if click_data.id == &"resource_source":
								if _world_ui: _world_ui.open("resource_source", click_anchor)
								get_viewport().set_input_as_handled()
								return
							elif click_data.id == &"payload_source":
								if _world_ui: _world_ui.open("payload_source", click_anchor)
								get_viewport().set_input_as_handled()
								return
							elif click_data.tags.has("sorter") or click_data.tags.has("inverted_sorter") or click_data.tags.has("unloader"):
								if _world_ui: _world_ui.open("sorter", click_anchor)
								get_viewport().set_input_as_handled()
								return
							elif click_data.tags.has("constructor"):
								if _world_ui: _world_ui.open("constructor", click_anchor)
								get_viewport().set_input_as_handled()
								return
							elif click_data.tags.has("refabricator"):
								if _world_ui: _world_ui.open("refabricator", click_anchor)
								get_viewport().set_input_as_handled()
								return
							elif click_data.tags.has("recipe_select") and click_data.factory_recipes != null and click_data.factory_recipes.size() > 0:
								# Rod Shapper-style factory — clicking opens a recipe
								# picker. Selection persists per-anchor in
								# logistics.factory_recipe_state.
								if _world_ui: _world_ui.open("recipe_select", click_anchor)
								get_viewport().set_input_as_handled()
								return
							elif click_data.id == &"launchpad":
								# Launchpad opens the standard world menu in
								# "launchpad" mode — two clickable rows: the
								# current destination + a Launch action.
								if _world_ui: _world_ui.open("launchpad", click_anchor)
								get_viewport().set_input_as_handled()
								return
							elif click_data.id == &"landing_pad":
								# Landing pad opens the standard world menu
								# in "landing_pad" mode — two slot rows that
								# open a sub-picker on click.
								if _world_ui: _world_ui.open("landing_pad", click_anchor)
								get_viewport().set_input_as_handled()
								return
							elif click_data.tags.has("logistic_requestor"):
								# Logistical Requestor — if a dispatcher is
								# waiting for its link target, this click
								# completes the link instead of opening
								# the condition picker.
								if _world_ui and _world_ui.try_complete_dispatcher_link(click_anchor):
									get_viewport().set_input_as_handled()
									return
								# Otherwise: open the condition picker
								# (storage_has / units_produced).
								if _world_ui: _world_ui.open("requestor", click_anchor)
								get_viewport().set_input_as_handled()
								return
							elif click_data.tags.has("logistic_dispatcher"):
								# Logistical Dispatcher — opens the action
								# picker (stop_block / manual_toggle).
								if _world_ui: _world_ui.open("dispatcher", click_anchor)
								get_viewport().set_input_as_handled()
								return
							# Fallback: any block with non-empty storage shows a
							# read-only inventory popup (Mindustry-style).
							elif _block_has_any_stored(click_anchor):
								if _world_ui: _world_ui.open("storage", click_anchor)
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
							# cells (belt → junction, pipe → bridge, etc.)
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
			# Skip right-click entirely while the player is in unit mode.
			# Unit mode owns right-click for unit commands; deconstruct is
			# disabled outright (even with no units currently selected)
			# so a stray right-click can't tear down a building while the
			# player is busy commanding units. Outside of unit mode,
			# right-click goes to demolish as normal.
			var unit_mgr = get_node_or_null("/root/Main/UnitManager")
			if unit_mgr and unit_mgr.unit_mode_active:
				# Also clear any in-flight demolish drag so a drag that
				# started just before unit mode was entered doesn't
				# commit on release.
				_demolish_dragging = false
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


## Maximum simultaneous links a bridge can hold on each role (source
## OR destination). Belt bridges keep the simple 1+1 behavior; duct
## bridges support up to 3+3 so a single output bridge can merge from
## three inputs and a single input can fan out to three outputs.
func _bridge_link_cap(data: BlockData) -> int:
	if data == null:
		return 1
	if data.id == &"duct_bridge":
		return 3
	return 1


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
		# Bridge-to-bridge links allow up to TWO partners per bridge —
		# one outgoing (this bridge is the source / pair[0]) and one
		# incoming (this bridge is the destination / pair[1]). So only
		# drop the role-specific existing link, not both partners.
		# Mass drivers and other non-bridge linkables keep the original
		# 1:1 behavior.
		if source_is_bridge and target_is_bridge:
			# Per-bridge link caps: belt = 1 outgoing / 1 incoming,
			# duct = 3 outgoing / 3 incoming. If the new link would
			# push a side past its cap, drop the OLDEST link on that
			# side first (FIFO replacement) so the player can rebind
			# at will. Direction-aware unlinks keep the opposite role
			# unaffected.
			var src_cap: int = _bridge_link_cap(source_data)
			var dst_cap: int = _bridge_link_cap(data)
			var existing_src: Array = power_sys.get_links_as_source_all(link_source)
			while existing_src.size() >= src_cap:
				var oldest_dst: Vector2i = existing_src[0]
				power_sys.unlink_directed(link_source, oldest_dst)
				existing_src.remove_at(0)
			var existing_dst: Array = power_sys.get_links_as_destination_all(anchor)
			while existing_dst.size() >= dst_cap:
				var oldest_src: Vector2i = existing_dst[0]
				power_sys.unlink_directed(oldest_src, anchor)
				existing_dst.remove_at(0)
		else:
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
	var _grid_h: float = cell * rows
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






























func _draw() -> void:
	# Resolve any still-pending threaded texture loads on the first paint.
	if not _textures_ready:
		_ensure_textures_loaded()
	_draw_placed_buildings()
	_draw_launchpad_pod_previews()
	_draw_block_hitboxes()
	# `_draw_cranes` now runs on `_crane_overlay` (z_index 4097) so
	# arms / grabbers / held cargo paint above units, turret heads,
	# and bullets. The overlay calls into us with `_crane_draw_canvas`
	# set so every draw call lands on its higher-z surface.
	_draw_crane_link_overlays()
	_draw_hovered_turret_range()
	_draw_hovered_extractor_output()
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
	# Check script-hidden tiles. _sector_script_ref() caches the node
	# reference; the previous `get_node_or_null(...)` here was walking
	# the scene tree 220+ times per frame for a value that never
	# changes across an entire session.
	var sector_script = _sector_script_ref()
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
	# Route through _ccanvas() so queued / in-progress block ghosts
	# can be painted via crane_overlay at z 4096 (above units and
	# placed blocks) when invoked from that pass.
	var c: CanvasItem = _ccanvas()
	var angle: float = 0.0
	if directional:
		angle = rot * PI / 2.0 + PI / 2.0
	var center := top_pos + Vector2(w / 2.0, h / 2.0)
	c.draw_set_transform(center, angle)
	c.draw_texture_rect(texture, Rect2(Vector2(-w / 2.0, -h / 2.0), Vector2(w, h)), false, tint)
	c.draw_set_transform(Vector2.ZERO, 0.0)


## Mindustry DrawLiquidTile look: re-draws the block's `base_sprite` tinted by
## its most-stored fluid, with alpha = stored ÷ liquid_capacity, so the base
## silhouette fades toward the fluid colour as the tank fills (the Graphite
## Electrolyzer's base turning blue with water). Drawn between base and top.
## No-op unless the block opts in (`liquid_tint`), has a base sprite + liquid
## capacity, and is actually holding fluid.
func _draw_block_liquid_tint(grid_pos: Vector2i, data: BlockData, top_pos: Vector2, w: float, h: float, rot: int, is_dir: bool) -> void:
	if not data.liquid_tint or data.base_sprite == null or data.liquid_capacity <= 0.0:
		return
	if _logistics == null:
		return
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var is_auto: bool = data.tags.has("auto_recipe")
	# Gather the fluids to tint by. Two sources:
	#  - factory_buffers["inputs"]: the INPUT fluids a consuming factory is
	#    actively buffering (e.g. the electrolyzer's water, the centrifuge's
	#    salt / sulfur water). Input fluids never land in block_storage, so
	#    without this the tint on consuming factories would never show.
	#  - block_storage["fluids"]: pump output / backed-up product fluids.
	#    Skipped for auto_recipe factories so a PRODUCT fluid (the centrifuge's
	#    output water) can't override the input-fluid tint.
	var fluids: Dictionary = {}
	if _logistics.factory_buffers.has(anchor):
		var buf_inputs: Dictionary = _logistics.factory_buffers[anchor].get("inputs", {})
		for iid in buf_inputs:
			var isn := StringName(iid)
			if Registry.get_fluid(isn) != null:
				fluids[isn] = fluids.get(isn, 0.0) + float(buf_inputs[iid])
	if not is_auto and _logistics.block_storage.has(anchor):
		var stored_fluids: Dictionary = _logistics.block_storage[anchor].get("fluids", {})
		for fid in stored_fluids:
			var fsn := StringName(fid)
			fluids[fsn] = fluids.get(fsn, 0.0) + float(stored_fluids[fid])
	if fluids.is_empty():
		return
	var best_id: StringName = &""
	var best_amt: float = 0.0
	if data.liquid_tint_fluid != &"":
		# Single-fluid tint: only ever show this fluid's level (e.g. the
		# electrolyzer tints by water, never by its hydrogen / oxygen output).
		best_id = data.liquid_tint_fluid
		best_amt = float(fluids.get(best_id, 0.0))
	else:
		# Pick the dominant stored fluid (the one with the most units) to tint by.
		for fid in fluids:
			var amt: float = float(fluids[fid])
			if amt > best_amt:
				best_amt = amt
				best_id = fid
	if best_id == &"" or best_amt <= 0.0:
		return
	var fluid = Registry.get_fluid(best_id)
	if fluid == null:
		return
	# alpha = fill fraction, scaled by the fluid's own opacity so different
	# fluids read at sensible strengths.
	var frac: float = clampf(best_amt / data.liquid_capacity, 0.0, 1.0)
	var tint: Color = Color(fluid.color)
	tint.a = frac * fluid.opacity
	_draw_block_texture(data.base_sprite, top_pos, w, h, rot, tint, is_dir)


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
	# One resource type at a time — refuse the withdrawal if the drone is
	# already carrying a different item.
	if drone.has_method("can_hold_item") and not drone.can_hold_item(item_id):
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
		if not data.ammo_accepts(item_id):
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

	# Generic storage block — also the path that runs for launchpads
	# since they store cargo in block_storage["items"]. The launchpad's
	# accept rules mirror this (any item, capped by max_stored_items).
	if data.tags.has("storage") or data.tags.has("launchpad"):
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
	# Launchpad: accepts any item the player wants to throw into the pod
	# buffer — the launch logic deducts the mandatory cost off the top
	# and ships the rest as cargo. Cap is enforced by max_stored_items
	# inside `_deposit_items_into_block`.
	if data.tags.has("launchpad"):
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
	# Turret accepts anything its ammo needs (primary or extra_cost).
	if data.is_turret() and not data.ammo_types.is_empty():
		if data.ammo_accepts(item_id):
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
			# Unit stays fully opaque; the construction-reveal overlay (dark
			# rect + progress line) below conveys build progress instead.
			alpha_mul = 1.0
			unit_pos = center
		"ejecting":
			var ep: float = clampf(
				maxf(float(state.get("eject_progress", 0.0)), float(state.get("eject_visual_progress", 0.0))),
				0.0,
				1.0
			)
			unit_pos = center + dir_vec * (front_dist * ep)
		"holding":
			unit_pos = center + dir_vec * front_dist

	# Draw layered (base + head + weapon mounts) via the shared unit-payload
	# renderer so the in-fabricator unit looks EXACTLY like it will in-world
	# — chassis + rotating head + turret heads — facing the build/output
	# direction. The fabricator builds a fresh unit (no captured pose), so we
	# synthesise a payload facing `unit_angle`; any held payload that carried
	# a real pose (refabricator etc.) is handled by its own draw path.
	# During "processing" the unit is mid-construction: only the already-built
	# (revealed) LEFT portion should be visible. The reveal box is the unit's
	# on-screen footprint, but CLAMPED to the fabricator's own footprint so the
	# build-front line never spills outside the building. The reveal sweeps
	# left→right as `reveal_pct` grows to 1.
	#
	# NOTE: we cannot use RenderingServer.canvas_item_set_clip here — that flag
	# is per-canvas-item state evaluated at render time, not a queued command,
	# so toggling it on/off inside one _draw() pass clips nothing (and would
	# clip the WHOLE block-draw item if it stuck). Instead we draw the unit in
	# full, then re-paint the fabricator's own base_sprite over the unbuilt
	# (right) portion to hide it — the unit is sandwiched base→unit→top, so the
	# re-painted base restores the empty-chamber look and the caller's top
	# sprite covers the seam.
	var box_w: float = minf(base_sz * 2.2, width)
	var box_h: float = minf(base_sz * 2.2, height)
	var reveal_active: bool = (phase == "processing" and reveal_pct < 1.0)
	var edge_x: float = center.x - box_w * 0.5 + box_w * reveal_pct

	# On-screen half-extents of the unit's body, so the build-front line can
	# hug the unit's silhouette — only as tall as the unit is wide at the line's
	# x — instead of spanning the whole reveal box. The chassis sprite's rotated
	# axis-aligned bounding box gives a good ellipse to approximate the outline.
	var uh_x: float = box_w * 0.5
	var uh_y: float = box_h * 0.5
	var body_tex: Texture2D = unit_data.base_sprite if unit_data.base_sprite != null else unit_data.head_sprite
	if body_tex != null:
		var ssf: float = float(main.SPRITE_SCALE_FACTOR)
		var b_scale: float = (unit_data.sprite_scale if unit_data.sprite_scale > 0.0 else 1.0) * ssf
		var bsz: Vector2 = body_tex.get_size() * b_scale
		var phi: float = unit_angle + PI / 2.0 + unit_data.sprite_angle_offset
		var ca: float = absf(cos(phi))
		var sa: float = absf(sin(phi))
		uh_x = (bsz.x * 0.5) * ca + (bsz.y * 0.5) * sa
		uh_y = (bsz.x * 0.5) * sa + (bsz.y * 0.5) * ca
	# Keep the line inside the reveal box (and thus the building footprint).
	uh_x = minf(uh_x, box_w * 0.5)
	uh_y = minf(uh_y, box_h * 0.5)

	var drew_layered: bool = false
	if unit_data.base_sprite != null or unit_data.head_sprite != null:
		drew_layered = true
		# render_scale 1.0 = exactly the unit's in-world size + mount geometry.
		var synth := {
			"facing_angle": unit_angle, "aim_angle": unit_angle,
			"unit_id": String(unit_data.id),
		}
		EnemyUnit.draw_unit_payload(self, unit_data, synth, unit_pos, 1.0, 0.0, alpha_mul)
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

	# Cover the not-yet-built (right of edge_x) portion with the fabricator's
	# base sprite so the unbuilt side of the unit is hidden rather than visible.
	if reveal_active and data.base_sprite != null:
		var cover_left: float = edge_x
		var cover_right: float = center.x + box_w * 0.5
		var cover_top: float = center.y - box_h * 0.5
		var cover_bot: float = center.y + box_h * 0.5
		if cover_right > cover_left:
			# Re-paint the base sprite using the SAME rotated transform the
			# caller used, restricted (in the base's local frame) to the screen
			# strip we want to hide. The block's draw angle matches
			# `_draw_block_texture`: directional blocks rotate rot*90+90.
			var b_is_dir: bool = _is_directional(data.id)
			var b_angle: float = (float(rot) * PI / 2.0 + PI / 2.0) if b_is_dir else 0.0
			var b_origin: Vector2 = top_pos + Vector2(width / 2.0, height / 2.0)
			var inv := Transform2D(b_angle, b_origin).affine_inverse()
			# Screen cover-rect corners → base-local coords (axis-aligned for
			# the 90° multiples fabricators rotate by).
			var corners := [
				inv * Vector2(cover_left, cover_top),
				inv * Vector2(cover_right, cover_top),
				inv * Vector2(cover_right, cover_bot),
				inv * Vector2(cover_left, cover_bot),
			]
			var lmin := Vector2(INF, INF)
			var lmax := Vector2(-INF, -INF)
			for cp in corners:
				lmin.x = minf(lmin.x, cp.x); lmin.y = minf(lmin.y, cp.y)
				lmax.x = maxf(lmax.x, cp.x); lmax.y = maxf(lmax.y, cp.y)
			# Clamp to the sprite's local footprint and map to texture pixels.
			var half := Vector2(width / 2.0, height / 2.0)
			lmin.x = clampf(lmin.x, -half.x, half.x); lmin.y = clampf(lmin.y, -half.y, half.y)
			lmax.x = clampf(lmax.x, -half.x, half.x); lmax.y = clampf(lmax.y, -half.y, half.y)
			var tex_size: Vector2 = data.base_sprite.get_size()
			var src := Rect2(
				((lmin + half) / Vector2(width, height)) * tex_size,
				((lmax - lmin) / Vector2(width, height)) * tex_size
			)
			var dst := Rect2(lmin, lmax - lmin)
			if dst.size.x > 0.0 and dst.size.y > 0.0:
				draw_set_transform(b_origin, b_angle)
				draw_texture_rect_region(data.base_sprite, dst, src)
				draw_set_transform(Vector2.ZERO, 0.0)

	# Yellow build-front line at the construction edge (the boundary between the
	# revealed unit and the freshly-covered unbuilt side). Its half-length is the
	# unit's silhouette half-height at the line's x (ellipse chord), so the line
	# only spans the unit's actual width at the build front rather than the full
	# reveal box — and vanishes in the margins where the unit doesn't reach.
	if reveal_active:
		var dx: float = edge_x - center.x
		var t: float = (dx / uh_x) if uh_x > 0.0 else 2.0
		var chord_half: float = (uh_y * sqrt(maxf(0.0, 1.0 - t * t))) if absf(t) <= 1.0 else 0.0
		if chord_half > 0.5:
			draw_line(
				Vector2(edge_x, center.y - chord_half),
				Vector2(edge_x, center.y + chord_half),
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
## Cached result of _is_directional per block_id. Block definitions don't
## change at runtime, so this cache is permanent (lifetime of the engine
## session) instead of per-frame. Brought call cost down from ~150
## tag-lookups per frame to ~150 dict lookups in the hot draw path.
static var _is_directional_cache: Dictionary = {}


func _is_directional(block_id: StringName) -> bool:
	if _is_directional_cache.has(block_id):
		return _is_directional_cache[block_id]
	var result: bool = _compute_is_directional(block_id)
	_is_directional_cache[block_id] = result
	return result


func _compute_is_directional(block_id: StringName) -> bool:
	var data = Registry.get_block(block_id)
	if data == null:
		return false
	# Per-output directional routing (output_sides) needs a rotation to rotate
	# its output sides with the block — wins over the omnidirectional default.
	if not data.output_sides.is_empty():
		return true
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
		or data.tags.has("payload_source") \
		or data.tags.has("refit_bay") \
		or data.tags.has("logistic_dispatcher") \
		or data.tags.has("logistic_requestor") \
		or data.shield_shape != "" \
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
			# A different-tag transport in the same swap family (e.g.
			# dragging a duct over a belt — both share the "belt_duct"
			# group) should overlay-swap rather than be bridged over.
			# Treat it as same_transport so the perpendicular/parallel
			# branch runs and try_place_building's swap_group swap
			# replaces the belt with the new block at commit time.
			if not same_transport and existing_data != null:
				var sel_data = Registry.get_block(main.selected_building)
				if sel_data and main.has_method("_get_swap_group"):
					var sel_group: StringName = main._get_swap_group(sel_data)
					var ex_group: StringName = main._get_swap_group(existing_data)
					if sel_group != &"" and sel_group == ex_group:
						same_transport = true
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

	# Kind match: the receiving cell (to_pos) is the belt / duct / pipe whose
	# texture we're picking. A belt (item transport) must only connect to a
	# neighbour that outputs ITEMS, and a pipe (fluid transport) only to one
	# that outputs FLUIDS — so belts don't treat a pipe / fluid-only block as an
	# input (and vice versa).
	var recv = Registry.get_block(main.placed_buildings.get(to_pos, &""))
	if recv != null and recv.is_transport():
		if recv.transports_fluid:
			if not _block_outputs_fluid(data):
				return false
		else:
			if not _block_outputs_item(data):
				return false

	# Find the building's origin for correct rotation lookup on multi-tile buildings
	var anchor = main.get_building_anchor(from_pos)
	var origin: Vector2i = anchor if anchor != null else from_pos
	var rot: int = main.building_rotation.get(origin, 0)
	var dir: Vector2i = DIR_VECTORS[rot]

	# Pumps: extract from underneath and output fluid on all 4 sides. Checked
	# BEFORE the transport branch because pumps also carry `transport_speed`
	# (so is_transport() is true) but should connect on every face, not just
	# their facing direction — otherwise adjacent pipes never pick up a corner /
	# junction texture toward the pump.
	if data.tags.has("pump"):
		return true

	# Transport blocks: output in their facing direction only — except
	# routers (split flow across every face EXCEPT the back) and
	# junctions (passthrough on all 4 axes). Without these, neighbouring
	# belts can't detect the splitter and stay straight instead of
	# picking up their corner / junction texture variants.
	if data.is_transport():
		# Routers AND the directional splitters (sorter / inverted sorter /
		# overflow / underflow) all take input on the back and can output on
		# the front + both sides, so neighbouring belts on ANY non-back face
		# should pick up their corner / junction texture variant.
		if data.tags.has("router") or data.tags.has("sorter") \
				or data.tags.has("inverted_sorter") or data.tags.has("overflow") \
				or data.tags.has("underflow"):
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

	# Extractors (drills): output on all sides EXCEPT the front (mining) edge
	if data.category == BlockData.BlockCategory.EXTRACTORS:
		if data.tags.has("omnidirectional"):
			return true
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


## True if the block can put out a FLUID — fluid pipes, pumps, condensers, or
## any factory whose output (incl. recipe-select outputs) is a fluid. Used by
## the transport texture picker to keep belts from connecting to fluid sources.
func _block_outputs_fluid(data: BlockData) -> bool:
	if data.transports_fluid:
		return true
	if data.tags.has("pump") or data.vent_fluid != &"":
		return true
	for k in data.output_items:
		if Registry.get_fluid(StringName(k)) != null:
			return true
	for rk in data.side_outputs:
		if Registry.get_fluid(StringName(data.side_outputs[rk])) != null:
			return true
	for r in data.factory_recipes:
		if typeof(r) == TYPE_DICTIONARY:
			for ok in r.get("output", {}):
				if Registry.get_fluid(StringName(ok)) != null:
					return true
	return false


## True if the block can put out an ITEM — belts/ducts, drills, constructors,
## loaders, or any factory whose output (incl. recipe-select outputs) is an
## item. Used so pipes don't connect to item sources.
func _block_outputs_item(data: BlockData) -> bool:
	if data.is_transport() and not data.transports_fluid:
		return true
	# Drills / scrapers mine ore items (fluid extractors carry pump/vent_fluid).
	if data.category == BlockData.BlockCategory.EXTRACTORS \
			and not data.tags.has("pump") and data.vent_fluid == &"":
		return true
	if data.tags.has("constructor") or data.tags.has("deconstructor") \
			or data.tags.has("payload_loader") or data.tags.has("freight_loader") \
			or data.tags.has("payload_unloader") or data.tags.has("freight_unloader"):
		return true
	for k in data.output_items:
		if Registry.get_item(StringName(k)) != null and Registry.get_fluid(StringName(k)) == null:
			return true
	for rk in data.side_outputs:
		var oid := StringName(data.side_outputs[rk])
		if Registry.get_item(oid) != null and Registry.get_fluid(oid) == null:
			return true
	for r in data.factory_recipes:
		if typeof(r) == TYPE_DICTIONARY:
			for ok in r.get("output", {}):
				var okid := StringName(ok)
				if Registry.get_item(okid) != null and Registry.get_fluid(okid) == null:
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

	# Pick the right texture set based on the block at this cell. Belts,
	# ducts, and fluid pipes share the corner / junction logic but each
	# has its own art.
	var textures: Dictionary = _belt_textures
	var bid: StringName = main.placed_buildings.get(grid_pos, &"")
	if bid == &"duct":
		textures = _duct_textures
	elif bid == &"fluid_pipe":
		textures = _pipe_textures
	return {"texture": textures.get(tex_key), "angle": angle, "key": tex_key}


## Draws a pipe's stored fluid as a centred channel — a hub at the block centre
## plus an arm toward each connected cardinal neighbour — so the tint follows
## the pipe's I/L/T/+ footprint. A corner pipe only draws its two arms, leaving
## the empty quadrant untinted (fixes the fluid bleeding past the corner art).
## Hub + arms are laid out non-overlapping so a semi-transparent fill doesn't
## double-blend (darken) where they meet.
## Draws a fluid-transport cell's stored fluid as a tint behind its sprite,
## masked by the sprite's OWN alpha footprint. The pipe channel is a
## semi-transparent band in the art, so the fill shows through it; the opaque
## walls/chevrons cover it; and the fully-transparent corner cutout / bridge
## margins get nothing (no bleed). This is pixel-exact for every variant
## (straight / corner / T / router / junction / bridge) with no geometry
## guessing. Reads the fill from the pipe network (or junction compartments).
func _draw_pipe_fluid_shape(grid_pos: Vector2i, block_id: StringName, top_pos: Vector2, w: float, h: float) -> void:
	if _logistics == null:
		return
	var fluid_id: StringName = &""
	var amount: float = 0.0
	if "pipe_contents" in _logistics and _logistics.pipe_contents.has(grid_pos):
		var pc: Dictionary = _logistics.pipe_contents[grid_pos]
		fluid_id = StringName(pc.get("fluid_id", &""))
		amount = float(pc.get("amount", 0.0))
	elif "pipe_junction_state" in _logistics and _logistics.pipe_junction_state.has(grid_pos):
		var js: Dictionary = _logistics.pipe_junction_state[grid_pos]
		var va: float = float(js.get("v_amount", 0.0))
		var ha: float = float(js.get("h_amount", 0.0))
		# Tint by whichever channel holds more.
		if va >= ha and StringName(js.get("v_fluid", &"")) != &"":
			fluid_id = StringName(js["v_fluid"]); amount = va
		elif StringName(js.get("h_fluid", &"")) != &"":
			fluid_id = StringName(js["h_fluid"]); amount = ha
	if fluid_id == &"" or amount <= 0.0:
		return
	var fluid = Registry.get_fluid(fluid_id)
	if fluid == null:
		return
	var cap: float = fluid.units_per_segment if fluid.units_per_segment > 0.0 else 10.0
	var fill: Color = Color(fluid.color)
	fill.a = clampf(amount / cap, 0.0, 1.0) * fluid.opacity

	if block_id == &"fluid_pipe":
		# Auto-tiled pipe: mask = the chosen variant texture's footprint, drawn
		# with the same rotation so it lines up with the sprite.
		var info: Dictionary = _get_belt_draw_info(grid_pos)
		var mask: Texture2D = _alpha_mask_for(info.get("texture"))
		if mask == null:
			return
		var center: Vector2 = top_pos + Vector2(w / 2.0, h / 2.0)
		draw_set_transform(center, float(info.get("angle", 0.0)))
		draw_texture_rect_region(mask, Rect2(Vector2(-w / 2.0, -h / 2.0), Vector2(w, h)),
				Rect2(Vector2.ZERO, mask.get_size()), fill)
		draw_set_transform(Vector2.ZERO, 0.0)
	else:
		# Router / junction / bridge: mask = their top sprite's footprint.
		var data2: BlockData = Registry.get_block(block_id)
		if data2 == null or data2.top_sprite == null:
			return
		var mask2: Texture2D = _alpha_mask_for(data2.top_sprite)
		if mask2 == null:
			return
		var is_dir: bool = _is_directional(block_id)
		var rot: int = main.building_rotation.get(grid_pos, 0) if is_dir else 0
		_draw_block_texture(mask2, top_pos, w, h, rot, fill, is_dir)


## Returns a cached white-silhouette mask of `tex` (white where the texture has
## any opacity, transparent where fully transparent). Used to tint the pipe
## fluid fill confined to the sprite's footprint. Generated lazily on first use.
var _alpha_mask_cache: Dictionary = {}
func _alpha_mask_for(tex: Texture2D) -> Texture2D:
	if tex == null:
		return null
	if _alpha_mask_cache.has(tex):
		return _alpha_mask_cache[tex]
	var src: Image = tex.get_image()
	var result: Texture2D = null
	if src != null:
		var ww: int = src.get_width()
		var hh: int = src.get_height()
		var m: Image = Image.create(ww, hh, false, Image.FORMAT_RGBA8)
		var white := Color(1, 1, 1, 1)
		var clear := Color(0, 0, 0, 0)
		for y in range(hh):
			for x in range(ww):
				m.set_pixel(x, y, white if src.get_pixel(x, y).a > 0.05 else clear)
		result = ImageTexture.create_from_image(m)
	_alpha_mask_cache[tex] = result
	return result


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

	# Pick the texture set based on the previewed block id. Belts,
	# ducts, and fluid pipes share corner / junction logic but each has
	# its own art.
	var textures: Dictionary = _belt_textures
	if preview_block_id == &"duct":
		textures = _duct_textures
	elif preview_block_id == &"fluid_pipe":
		textures = _pipe_textures
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

	# LaunchAnimation hides pre-built LUMINA blocks until the ring
	# sweep crosses them — the sector visually "spawns into existence"
	# as the ring travels. Skip those anchors entirely so they don't
	# appear early in any of the building draw passes.
	var la_filter = get_node_or_null("/root/Main/LaunchAnimation")
	# Iterate ANCHORS only. The previous loop walked every tile of
	# every multi-tile block and threw away non-anchor cells via
	# `is_building_anchor`, which scales as O(total_tiles) rather than
	# O(building_count). For a map of 5000 building tiles where the
	# average block is 3 tiles, this is ~3× fewer iterations.
	var anchors: Dictionary = main.get_building_anchors() if main.has_method("get_building_anchors") else {}
	for grid_pos in anchors:
		# Cull against the block's FULL footprint, not just its anchor
		# cell. A 3×3 turret anchored just off the left edge still has
		# 6 of its 9 tiles visible — checking only the anchor would
		# pop the whole block out the moment the anchor crossed the
		# edge. Read grid_size from BlockData; fall back to 1×1 if the
		# id can't be resolved.
		var bdata_cull: BlockData = Registry.get_block(main.placed_buildings.get(grid_pos, &""))
		var fx_max: int = grid_pos.x
		var fy_max: int = grid_pos.y
		if bdata_cull != null:
			fx_max = grid_pos.x + maxi(bdata_cull.grid_size.x, 1) - 1
			fy_max = grid_pos.y + maxi(bdata_cull.grid_size.y, 1) - 1
		if fx_max < grid_min.x or grid_pos.x > grid_max.x:
			continue
		if fy_max < grid_min.y or grid_pos.y > grid_max.y:
			continue
		if la_filter and la_filter.has_method("is_block_hidden") and la_filter.is_block_hidden(grid_pos):
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
	var _half_gs: float = gs * 0.5

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

	# --- PASS 0: Covered-platform underlay ---
	# Platforms that got "covered" by a block placed on top are stashed
	# in `main._platform_under` and pulled out of `placed_buildings`,
	# so the normal anchor loop would never draw them. Paint their
	# top sprite here, before the covering block's sides + top, so the
	# platform peeks out under the cover's parallax (and stays visible
	# at the cover's base instead of disappearing). Multi-tile covered
	# platforms only need one draw per unique anchor.
	if "_platform_under" in main and not main._platform_under.is_empty():
		var drawn_p_anchors: Dictionary = {}
		for pcell in main._platform_under:
			var pstash: Dictionary = main._platform_under[pcell]
			var p_anchor: Vector2i = pstash.get("anchor", pcell)
			if drawn_p_anchors.has(p_anchor):
				continue
			drawn_p_anchors[p_anchor] = true
			# Skip platforms whose anchor cell is still in
			# `placed_buildings` as the platform — those still take the
			# normal draw path (only non-anchor cells got covered).
			if main.placed_buildings.get(p_anchor, &"") == pstash.get("block_id", &""):
				continue
			# Cull against the visible grid.
			var p_block_id: StringName = StringName(pstash.get("block_id", &""))
			if p_block_id == &"":
				continue
			var p_data: BlockData = Registry.get_block(p_block_id)
			if p_data == null or p_data.top_sprite == null:
				continue
			var p_fx_max: int = p_anchor.x + maxi(p_data.grid_size.x, 1) - 1
			var p_fy_max: int = p_anchor.y + maxi(p_data.grid_size.y, 1) - 1
			if p_fx_max < grid_min.x or p_anchor.x > grid_max.x:
				continue
			if p_fy_max < grid_min.y or p_anchor.y > grid_max.y:
				continue
			if ss and ss.is_tile_hidden(p_anchor):
				continue
			var p_world: Vector2 = main.grid_to_world(p_anchor)
			var p_w: float = float(p_data.grid_size.x) * gs
			var p_h: float = float(p_data.grid_size.y) * gs
			var p_rot: int = int(pstash.get("rotation", 0))
			_draw_block_texture(p_data.top_sprite, p_world, p_w, p_h, p_rot, Color.WHITE, _is_directional(p_block_id))

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
				# Queued — every visual (block ghost + turret head +
				# yellow outline) is painted from
				# `_draw_active_build_overlays_high_z()` via crane_overlay
				# so the queued footprint renders above units (z 4095)
				# and live blocks instead of being clipped under them.
				# Skip the block-layer paint entirely.
				continue

		# Conveyor belts, ducts, and fluid pipes all use auto-tiled
		# textures based on neighbours. (The pipe branch additionally
		# paints a fluid-fill rect under the texture; that's handled
		# in its own `elif` below — keep the pipe out of this gate.)
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
		# Vent turbine: dedicated power-block art. It also carries the
		# `pump` tag now (so the water-byproduct path runs) — without
		# this guard the elif below would paint it with the generic
		# fluid-pump texture, masking the turbine's own sprite.
		elif block_id == &"vent_turbine":
			_draw_vent_turbine(grid_pos, top_pos, width, height)
		# Fluid pumps: draw with pump texture (before pipes; pumps also transport_fluid)
		elif data and data.tags.has("pump") and _pump_texture:
			var rot: int = main.building_rotation.get(grid_pos, 0)
			var angle: float = rot * PI / 2.0 + PI / 2.0
			var center: Vector2 = top_pos + Vector2(width / 2.0, height / 2.0)
			draw_set_transform(center, angle)
			draw_texture_rect(_pump_texture, Rect2(Vector2(-width / 2.0, -height / 2.0), Vector2(width, height)), false)
			draw_set_transform(Vector2.ZERO, 0.0)

		# Fluid pipes: corner / junction variant + colored fluid fill
		# rectangle painted UNDER the pipe texture. Uses the same
		# auto-tile classifier as belts/ducts so a pipe joining its
		# neighbours picks the right CA / CB / JA / JL / JR / straight
		# art.
		elif block_id == &"fluid_pipe" and not _pipe_textures.is_empty():
			# Fluid tint behind the pipe sprite, filling only the quadrants the
			# auto-tile shape occupies (full channel for straights, both arms
			# for corners, empty quadrant left clear).
			_draw_pipe_fluid_shape(grid_pos, block_id, top_pos, width, height)
			var info: Dictionary = _get_belt_draw_info(grid_pos)
			var texture: Texture2D = info["texture"]
			var angle: float = info["angle"]
			if texture:
				var center: Vector2 = top_pos + Vector2(width / 2.0, height / 2.0)
				draw_set_transform(center, angle)
				# Use draw_texture_rect_region (full-texture src window)
				# instead of draw_texture_rect — rotated draw_texture_rect
				# subpixel-clamps the edges and leaves visible seams at
				# corner / junction tile boundaries (see the belt branch
				# at line ~6280 for the same fix).
				var dst_rect := Rect2(Vector2(-width / 2.0, -height / 2.0), Vector2(width, height))
				var tex_size: Vector2 = texture.get_size()
				draw_texture_rect_region(texture, dst_rect, Rect2(Vector2.ZERO, tex_size))
				draw_set_transform(Vector2.ZERO, 0.0)
			else:
				var color := _get_block_color(block_id)
				draw_rect(Rect2(top_pos, Vector2(width, height)), color, true)
				draw_rect(Rect2(top_pos, Vector2(width, height)), color.lightened(0.3), false, 2.0)

		else:
			var top_rect := Rect2(top_pos, Vector2(width, height))
			var is_dir: bool = _is_directional(block_id)
			var rot: int = main.building_rotation.get(grid_pos, 0) if is_dir else 0
			# Fluid tint for non-pipe fluid transport (router / junction /
			# bridge), drawn BEHIND the sprite so it shows through the channel.
			if data and data.is_transport() and data.transports_fluid:
				_draw_pipe_fluid_shape(grid_pos, block_id, top_pos, width, height)
			# Scraper head: spinning drum drawn UNDER whatever this block's
			# base sprite ends up being, so the base covers the center of
			# the head and only the rim peeks out — same composition as
			# the wall crusher's gears.
			if data and data.tags.has("scraper_head"):
				_draw_scraper_head(grid_pos, top_pos, width, height)
			# Impact head: still-but-scaling drum that slams down on
			# every drill cycle, eases back across the CD.
			elif data and data.tags.has("impact_head"):
				_draw_impact_head(grid_pos, top_pos, width, height)
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
			# by any block that just wants a static two-layer sprite. Blocks
			# with `liquid_tint` get a fluid-coloured layer between the two
			# whose alpha tracks how full the tank is (Mindustry DrawLiquidTile).
			elif data and data.base_sprite and data.top_sprite:
				_draw_block_texture(data.base_sprite, top_pos, width, height, rot, Color.WHITE, is_dir)
				_draw_block_liquid_tint(grid_pos, data, top_pos, width, height, rot, is_dir)
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
			# Layered spinner factories (brass_mixer, silicon_mixer, …):
			# Base → rotating Head → Top, driven by `_LAYERED_SPINNERS`.
			elif _LAYERED_SPINNERS.has(block_id):
				_draw_layered_spinner(grid_pos, block_id, top_pos, width, height)
			# Incinerator: swap between -P (powered) and -NP (unpowered)
			# textures so the player can see at a glance whether the
			# network is supplying its 5 W draw.
			elif data and data.tags.has("incinerator"):
				var anchor_inc: Vector2i = main.building_origins.get(grid_pos, grid_pos)
				var ps_inc = _power_sys_ref()
				var inc_powered: bool = ps_inc != null and ps_inc.get_electrical_efficiency(anchor_inc) > 0.0
				var inc_tex: Texture2D = _incinerator_powered_texture if inc_powered else _incinerator_unpowered_texture
				if inc_tex:
					draw_texture_rect(inc_tex, Rect2(top_pos, Vector2(width, height)), false, Color.WHITE)
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
			var dh_levels: Dictionary = _get_drill_head_levels(grid_pos, rot, data.grid_size)
			_draw_drill_heads(grid_pos, rot, data.grid_size, dh_levels, block_id)
		if data.tags.has("drill_lasers"):
			# Only fire lasers when the bore is fully built AND powered —
			# a ghost / under-construction / unpowered bore shouldn't be
			# emitting plasma.
			var lasers_active: bool = true
			if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
				lasers_active = false
			if lasers_active:
				if power_sys and power_sys.has_method("is_powered_or_battery"):
					lasers_active = power_sys.is_powered_or_battery(grid_pos)
			if lasers_active:
				_draw_drill_lasers(grid_pos, rot, data.grid_size, data.mine_range)
		if data.tags.has("crusher_heads") or data.tags.has("grinder_heads"):
			# Placed crushers / grinders read live inertial state; the
			# per-frame tick (_tick_crusher_head_states) decides whether
			# the heads spin up, hold speed, or coast to a stop.
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

			# A block draws the moving reveal line + builder beams when it's
			# the player's active work anchor, OR when a FEROX shardling is
			# actively rebuilding it (FEROX rebuilds run outside the player
			# work_order, so they never set active_work_anchor — but they
			# should show the same construction laser).
			var is_ferox_build: bool = main.get_building_faction(grid_pos) == main.Faction.FEROX \
				and not _ferox_builders_with_facing_for(grid_pos).is_empty()
			var is_active_build: bool = (has_active_work and active_work_anchor == grid_pos) \
				or is_ferox_build
			if build_pct > 0.0:
				# Active build — pass 2 rendered the block at full opacity
				# already. The dim wash over the unbuilt portion AND the
				# in-progress turret head preview are painted in
				# `_draw_active_build_overlays_high_z()` from crane_overlay
				# so they sit above units (z 4095) and live turret heads.
				# Reveal line + builder beams stay here so they remain
				# visually anchored to the block at the building layer.
				var reveal_x: float = b_width * build_pct
				if is_active_build:
					var line_x: float = b_top_pos.x + reveal_x
					var line_top := Vector2(line_x, b_top_pos.y)
					var line_bot := Vector2(line_x, b_top_pos.y + b_height)
					# Build laser: every builder in range projects a
					# translucent yellow triangle from its sprite front
					# to the two endpoints of the reveal line, with a
					# scrolling darker stripe so the beam reads as live.
					# Drawn UNDER the reveal line so the line itself
					# stays the brightest element.
					_draw_active_build_beams(grid_pos, line_top, line_bot)
					draw_line(line_top, line_bot, Color(1.0, 0.9, 0.2, 0.9), 2.0)
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
					or (new_id == &"duct" and not _duct_textures.is_empty()) \
					or (new_id == &"fluid_pipe" and not _pipe_textures.is_empty()):
				# Use the with-preview variant so the texture set is picked
				# from `new_id` (the swapped-in block) rather than whatever
				# is currently placed at this cell.
				var info_s: Dictionary = _get_belt_draw_info_with_preview(grid_pos, {}, {}, new_id)
				var texture_s: Texture2D = info_s["texture"]
				var angle_s: float = info_s["angle"]
				if texture_s:
					var centre_s: Vector2 = top_pos_s + Vector2(w_s / 2.0, h_s / 2.0)
					draw_set_transform(centre_s, angle_s)
					var dst_s := Rect2(Vector2(-w_s / 2.0, -h_s / 2.0), Vector2(w_s, h_s))
					var tex_size_s: Vector2 = texture_s.get_size()
					draw_texture_rect_region(texture_s, dst_s, Rect2(Vector2.ZERO, tex_size_s), tint_s)
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
			# Dim washes over the deconstructed / never-built portion are
			# drawn from `_draw_active_build_overlays_high_z()` so they
			# sit above units instead of being painted over by them.
			# Moving red line only while actively deconstructing. Paused
			# entries freeze the reveal at its current position so the
			# player can see exactly how far decon has gotten.
			if is_active_decon:
				var d_line_top := Vector2(line_x, d_top_pos.y)
				var d_line_bot := Vector2(line_x, d_top_pos.y + d_height)
				# Red work-laser variant: same triangle + scrolling
				# stripe + pulsing diamond as the build beam, but the
				# stripe rides block→unit instead of unit→block so the
				# diagonal cadence reads top-right → down-left.
				_draw_active_build_beams(
					grid_pos, d_line_top, d_line_bot,
					Color(0.95, 0.25, 0.25), true,
				)
				draw_line(d_line_top, d_line_bot, Color(0.9, 0.2, 0.2, 0.9), 2.0)
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

	# --- PASS 4: Draw health bars on damaged buildings ---
	for idx in order:
		if is_wall_of[idx]:
			continue
		var grid_pos: Vector2i = all_positions[idx]
		if ss and ss.is_tile_hidden(grid_pos):
			continue
		var health_pct: float = main.get_building_health_pct(grid_pos)
		# Launch-anim reveal tint: paints over the freshly-drawn sprite
		# while the ring sweep is running. Color.WHITE = no-op so the
		# overlay only kicks in for blocks the ring has actually touched
		# (or for pre-built blocks waiting their turn). Reuse the
		# `la_filter` reference fetched once at the top of this function
		# instead of re-walking the scene tree per building.
		if la_filter and la_filter.has_method("get_block_reveal_tint"):
			var t_anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
			var reveal_tint: Color = la_filter.get_block_reveal_tint(t_anchor)
			if reveal_tint.a > 0.001:
				var rev_id: StringName = main.placed_buildings[grid_pos]
				var rev_size: Vector2i = _size_for.call(rev_id)
				var rev_world: Vector2 = main.grid_to_world(grid_pos)
				var rev_offset: Vector2 = _offset_for.call(rev_id)
				draw_rect(
					Rect2(rev_world + rev_offset, Vector2(gs * rev_size.x, gs * rev_size.y)),
					reveal_tint, true)
		# Derelict → LUMINA conversion flash: yellow band over freshly-
		# captured blocks. Only the anchor cell is tracked; we expand
		# to the block's full footprint so multi-tile cores flash as a
		# whole, not just their top-left tile.
		var conv_anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if grid_pos == conv_anchor:
			var conv_tint: Color = get_conversion_flash_tint(conv_anchor)
			if conv_tint.a > 0.001:
				var conv_id: StringName = main.placed_buildings[grid_pos]
				var conv_size: Vector2i = _size_for.call(conv_id)
				var conv_world: Vector2 = main.grid_to_world(grid_pos)
				var conv_offset: Vector2 = _offset_for.call(conv_id)
				draw_rect(
					Rect2(conv_world + conv_offset, Vector2(gs * conv_size.x, gs * conv_size.y)),
					conv_tint, true)
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
		# (Fluid storage bar moved to the hover tooltip — see
		# `HUD._add_tooltip_fluid_bar`. We still tick
		# `_fluid_bar_display` per frame so the tooltip's eased value
		# stays smooth even when the panel rebuilds.)



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
	# Route through _ccanvas() so the crane_overlay can pipe this draw onto
	# its high-z (4096) canvas — putting in-progress turret heads above
	# units (z 4095) and live turret heads instead of being clipped by them.
	var c: CanvasItem = _ccanvas()
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
		c.draw_set_transform(center, draw_angle)
		if data.turret_chassis_sprite:
			var ctex: Texture2D = data.turret_chassis_sprite
			var csize: Vector2 = ctex.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
			c.draw_texture_rect(
				ctex,
				Rect2(Vector2(-csize.x * 0.5, -csize.y * 0.5), csize),
				false,
				tint,
			)
		else:
			var plate_w: float = (float(bcount) - 1.0) * data.barrel_spacing + tex_size.x * 0.9
			var plate_h: float = tex_size.y * 0.35
			c.draw_rect(
				Rect2(Vector2(-plate_w * 0.5, -plate_h * 0.5), Vector2(plate_w, plate_h)),
				Color(0.32, 0.32, 0.34, tint.a),
			)
		c.draw_set_transform(Vector2.ZERO, 0.0)
	# Heads — one per barrel, perpendicular to the aim axis.
	for i in range(bcount):
		var lateral: float = 0.0
		if bcount > 1:
			lateral = (float(i) - (float(bcount) - 1.0) * 0.5) * data.barrel_spacing
		var pivot: Vector2 = center + chassis_perp * lateral
		c.draw_set_transform(pivot, draw_angle)
		var rect := Rect2(
			Vector2(-tex_size.x * 0.5, -tex_size.y + 14.0 * main.SPRITE_SCALE_FACTOR),
			tex_size,
		)
		c.draw_texture_rect(head_tex, rect, false, tint)
		c.draw_set_transform(Vector2.ZERO, 0.0)


## Draws a direction arrow at the given center position.
func _draw_direction_arrow(center: Vector2, rotation: int, color: Color) -> void:
	var c: CanvasItem = _ccanvas()
	var arrow_size := 14.0
	var dir = Vector2(DIR_VECTORS[rotation])

	# Arrow shaft
	var start_pt = center - dir * arrow_size * 0.5
	var end_pt = center + dir * arrow_size * 0.5
	c.draw_line(start_pt, end_pt, color, 2.5)

	# Arrowhead (two lines forming a V)
	var perp = Vector2(-dir.y, dir.x) * arrow_size * 0.35
	var back = dir * arrow_size * 0.4
	c.draw_line(end_pt, end_pt - back + perp, color, 2.5)
	c.draw_line(end_pt, end_pt - back - perp, color, 2.5)


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


## Eases every fluid-storing block's displayed total toward its true
## value at FLUID_BAR_EASE_PER_SEC units/sec. Anchors with empty
## storage (or where the building is gone) get dropped from the dict
## so the bar fades back to zero before disappearing.
func _tick_fluid_bar_display(delta: float) -> void:
	if _logistics == null or not "block_storage" in _logistics:
		return
	var to_erase: Array[Vector2i] = []
	# Seed entries for any newly-fluid-bearing anchors.
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if _fluid_bar_display.has(anchor):
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null or data.liquid_capacity <= 0.0:
			continue
		_fluid_bar_display[anchor] = 0.0
	# Ease each tracked anchor's displayed value toward the live total.
	for anchor in _fluid_bar_display:
		if not main.placed_buildings.has(anchor):
			to_erase.append(anchor)
			continue
		var data2: BlockData = Registry.get_block(main.placed_buildings[anchor])
		if data2 == null or data2.liquid_capacity <= 0.0:
			to_erase.append(anchor)
			continue
		var storage: Dictionary = _logistics.block_storage.get(anchor, {})
		var fluids: Dictionary = storage.get("fluids", {})
		var total: float = 0.0
		for fid in fluids:
			total += float(fluids[fid])
		var cur: float = float(_fluid_bar_display.get(anchor, 0.0))
		_fluid_bar_display[anchor] = move_toward(cur, total, FLUID_BAR_EASE_PER_SEC * delta)
	for a in to_erase:
		_fluid_bar_display.erase(a)


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
				or (block_id == &"duct" and not _duct_textures.is_empty()) \
				or (block_id == &"fluid_pipe" and not _pipe_textures.is_empty())
		if is_belt_q:
			var info: Dictionary = _get_belt_draw_info_with_preview(grid_pos, queue_set, queue_rots, block_id)
			var texture: Texture2D = info["texture"]
			var angle: float = info["angle"]
			if texture:
				var center: Vector2 = top_pos + Vector2(w / 2.0, h / 2.0)
				draw_set_transform(center, angle)
				var dst_q := Rect2(Vector2(-w / 2.0, -h / 2.0), Vector2(w, h))
				var tex_size_q: Vector2 = texture.get_size()
				draw_texture_rect_region(texture, dst_q, Rect2(Vector2.ZERO, tex_size_q), Color(1, 1, 1, 0.45))
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
			# Layered-spinner / vent-turbine / vent-condenser factories
			# carry their artwork in dynamic texture sets, not on the
			# .tres (`base_sprite` / `top_sprite` are null), so the
			# generic branches below all fall through to the flat-color
			# fallback. Route them to the same preview helpers used by
			# `_draw_block_ghost_preview` / drag-line previews so the
			# paused-queue ghost actually shows the block's art.
			if _LAYERED_SPINNERS.has(block_id):
				_draw_layered_spinner_preview(block_id, top_pos, w, h, tint)
				q_drew_layered = true
			elif block_id == &"vent_turbine":
				_draw_vent_turbine_preview(top_pos, w, h, tint)
				q_drew_layered = true
			elif block_id == &"vent_condenser":
				_draw_vent_condenser_preview(top_pos, w, h, tint)
				q_drew_layered = true
			# Fabricators/refabricators layer base + top so the block reads
			# as a whole building, not just its overlay.
			elif data.base_sprite and data.top_sprite:
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
			var dh_levels: Dictionary = _get_drill_head_levels(grid_pos, rotation, data.grid_size)
			_draw_drill_heads(grid_pos, rotation, data.grid_size, dh_levels, block_id, Color(1, 1, 1, 0.45))
		if data.tags.has("crusher_heads") or data.tags.has("grinder_heads"):
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
		w: float, h: float, rot: int, draw_heads: bool = true) -> void:
	if data == null:
		return
	# Route every draw call through _ccanvas() so the queued ghost can
	# be painted on crane_overlay (z 4096) — above units, live blocks,
	# and live turret heads — instead of being clipped under them at
	# the BuildingSystem's default z (50).
	var c: CanvasItem = _ccanvas()
	var tint := Color(1, 1, 1, 0.45)
	# Conveyor belts and ducts use the auto-tile texture system so the
	# ghost orients with its neighbours instead of always pointing the
	# same way.
	if (block_id == &"conveyor_belt" and not _belt_textures.is_empty()) \
			or (block_id == &"duct" and not _duct_textures.is_empty()) \
			or (block_id == &"fluid_pipe" and not _pipe_textures.is_empty()):
		var info: Dictionary = _get_belt_draw_info(grid_pos)
		var texture: Texture2D = info["texture"]
		var angle: float = info["angle"]
		if texture:
			var center: Vector2 = top_pos + Vector2(w / 2.0, h / 2.0)
			c.draw_set_transform(center, angle)
			var dst_g := Rect2(Vector2(-w / 2.0, -h / 2.0), Vector2(w, h))
			var tex_size_g: Vector2 = texture.get_size()
			c.draw_texture_rect_region(texture, dst_g, Rect2(Vector2.ZERO, tex_size_g), tint)
			c.draw_set_transform(Vector2.ZERO, 0.0)
			return
	var q_rot: int = rot if _is_directional(block_id) else 0
	var q_tex: Texture2D = null
	var q_drew_layered := false
	# Layered spinner blocks (brass mixer, silicon refinery) have no
	# base/top sprite on the .tres — their artwork lives in the
	# dynamic texture set. Paint Base + Head + Top so the queued
	# ghost matches what will land.
	if _LAYERED_SPINNERS.has(block_id):
		_draw_layered_spinner_preview(block_id, top_pos, w, h, tint)
		q_drew_layered = true
	elif block_id == &"vent_turbine":
		_draw_vent_turbine_preview(top_pos, w, h, tint)
		q_drew_layered = true
	elif block_id == &"vent_condenser":
		_draw_vent_condenser_preview(top_pos, w, h, tint)
		q_drew_layered = true
	elif data.base_sprite and data.top_sprite:
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
		c.draw_rect(Rect2(top_pos, Vector2(w, h)), color, true)
		if _is_directional(block_id):
			var center := top_pos + Vector2(w / 2.0, h / 2.0)
			_draw_direction_arrow(center, q_rot, Color(1, 1, 1, 0.5))
	# Turret heads / chassis ghost overlay so a queued turret reads as
	# what it'll become, not just a flat base. `draw_heads=false` is
	# passed from the active-build fade path — that path has its own
	# brighter head overlay so we don't want to double-stamp.
	if draw_heads:
		_draw_turret_preview_heads(data, top_pos, w, h, q_rot, tint)
	# Yellow outline marks "queued, waiting for the drone".
	c.draw_rect(Rect2(top_pos, Vector2(w, h)), Color(1.0, 0.9, 0.2, 0.5), false, 1.5)


func _draw_preview() -> void:
	if main.selected_building == &"":
		return

	var data = Registry.get_block(main.selected_building)
	var grid_w = data.grid_size.x if data else 1
	var grid_h = data.grid_size.y if data else 1
	var is_dir := _is_directional(main.selected_building)

	# --- Drag-placing: draw a ghost at every cell in the line ---
	if _drag_placing and not _drag_cells.is_empty():
		var _base_color = _get_block_color(main.selected_building)
		var _is_belt: bool = (main.selected_building == &"conveyor_belt" and not _belt_textures.is_empty()) \
				or (main.selected_building == &"duct" and not _duct_textures.is_empty()) \
				or (main.selected_building == &"fluid_pipe" and not _pipe_textures.is_empty())

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
					or (cell_block_id == &"duct" and not _duct_textures.is_empty()) \
					or (cell_block_id == &"fluid_pipe" and not _pipe_textures.is_empty())

			# Out-of-range cells stay white — the drone will pick them up
			# when it walks past. Only "actually invalid" cells (bad
			# terrain, overlap, wrong facing, etc.) tint red.
			var cell_rot_check: int = _pathfind_rotations.get(cell, main.placement_rotation) if _is_directional(cell_block_id) else 0
			var cell_valid := _can_place_ignoring_range(cell, cell_block_id, cell_rot_check)
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
					var dst_dl := Rect2(Vector2(-w / 2.0, -h / 2.0), Vector2(w, h))
					var tex_size_dl: Vector2 = texture.get_size()
					draw_texture_rect_region(texture, dst_dl, Rect2(Vector2.ZERO, tex_size_dl), tint)
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
				elif _LAYERED_SPINNERS.has(cell_block_id):
					_draw_layered_spinner_preview(cell_block_id, cell_pos, w, h, tint)
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
				# Always render heads in the preview — L0/R0 sit at the
				# body face by default so the ghost reads as a complete
				# drill even when placement is invalid (no ore in front).
				var dh_levels: Dictionary = _get_drill_head_levels(cell, dh_rot, data.grid_size)
				var dh_tint: Color = Color(1, 1, 1, 0.6) if cell_ok else Color(1, 0.3, 0.3, 0.5)
				_draw_drill_heads(cell, dh_rot, data.grid_size, dh_levels, main.selected_building, dh_tint)
			if cell_block_id == main.selected_building and data and (data.tags.has("crusher_heads") or data.tags.has("grinder_heads")):
				var ch_rot: int = preview_rots.get(cell, main.placement_rotation)
				var ch_tint: Color = Color(1, 1, 1, 0.6) if cell_ok else Color(1, 0.3, 0.3, 0.5)
				_draw_crusher_heads(cell, ch_rot, data.grid_size, main.selected_building, ch_tint, false)
		return

	# --- Not dragging: single-cell hover preview ---
	var world_pos = main.grid_to_world(preview_grid_pos)
	var offset = _get_top_offset(world_pos) * _get_height_scale(main.selected_building)
	var color = _get_block_color(main.selected_building)
	# With progressive resource consumption, placement is valid even
	# without enough resources — the ghost is placed and builds as
	# resources arrive. Range likewise doesn't matter for the TINT —
	# an out-of-range ghost is queued for the drone, so render white.
	var cell_ok: bool = can_place_excluding_range

	var width: float = float(main.GRID_SIZE) * grid_w
	var height: float = float(main.GRID_SIZE) * grid_h
	var top_pos = world_pos + offset

	# Function-scope flag: set true when a baked composite painted all
	# the layered content (body + heads, etc.), so the downstream
	# turret-heads draw doesn't double-stamp.
	var hover_used_bake := false
	# Draw belt / duct texture preview or fallback rectangle
	var is_belt_hover: bool = (main.selected_building == &"conveyor_belt" and not _belt_textures.is_empty()) \
			or (main.selected_building == &"duct" and not _duct_textures.is_empty()) \
			or (main.selected_building == &"fluid_pipe" and not _pipe_textures.is_empty())
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
			var dst_h := Rect2(Vector2(-width / 2.0, -height / 2.0), Vector2(width, height))
			var tex_size_h: Vector2 = texture.get_size()
			draw_texture_rect_region(texture, dst_h, Rect2(Vector2.ZERO, tex_size_h), tint)
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
		elif _LAYERED_SPINNERS.has(main.selected_building):
			_draw_layered_spinner_preview(main.selected_building, top_pos, width, height, tint)
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
		var arrow_color = Color(1, 1, 1, 0.8) if can_place_excluding_range else Color(1, 0.3, 0.3, 0.6)
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
		var t_tint: Color = Color(1, 1, 1, 0.6) if can_place_excluding_range else Color(1, 0.3, 0.3, 0.5)
		_draw_turret_preview_heads(data, top_pos, width, height, main.placement_rotation, t_tint)

	# Scraper / impact-drill heads in the preview. Both draw on top of
	# the base sprite the same way the live render does — without this,
	# the placement ghost was a headless body plate.
	if data and data.tags.has("scraper_head"):
		var sh_tint: Color = Color(1, 1, 1, 0.6) if can_place_excluding_range else Color(1, 0.3, 0.3, 0.5)
		if _scraper_head_texture:
			var sh_center: Vector2 = top_pos + Vector2(width * 0.5, height * 0.5)
			draw_set_transform(sh_center, 0.0)
			draw_texture_rect(_scraper_head_texture,
				Rect2(Vector2(-width * 0.5, -height * 0.5), Vector2(width, height)),
				false, sh_tint)
			draw_set_transform(Vector2.ZERO, 0.0)
	if data and data.tags.has("impact_head"):
		var ih_tint: Color = Color(1, 1, 1, 0.6) if can_place_excluding_range else Color(1, 0.3, 0.3, 0.5)
		if _impact_head_texture:
			# At-rest pose = full IMPACT_HEAD_MAX_SCALE (slam_progress = 1).
			var ih_center: Vector2 = top_pos + Vector2(width * 0.5, height * 0.5)
			var ih_w: float = width * IMPACT_HEAD_MAX_SCALE
			var ih_h: float = height * IMPACT_HEAD_MAX_SCALE
			draw_set_transform(ih_center, 0.0)
			draw_texture_rect(_impact_head_texture,
				Rect2(Vector2(-ih_w * 0.5, -ih_h * 0.5), Vector2(ih_w, ih_h)),
				false, ih_tint)
			draw_set_transform(Vector2.ZERO, 0.0)

	# Crane preview: arm + grabber + base pivot at the default pose so
	# the player sees the silhouette before placing.
	if data and data.tags.has("crane"):
		var c_tint: Color = Color(1, 1, 1, 0.6) if can_place_excluding_range else Color(1, 0.3, 0.3, 0.5)
		_draw_crane_preview(top_pos, width, height, c_tint)

	# Turret attack-range circle in the placement preview — dashed, same
	# look as the hover-over-existing-turret indicator.
	if data and data.is_turret() and data.attack_range > 0.0:
		var range_center: Vector2 = top_pos + Vector2(width * 0.5, height * 0.5)
		var range_px: float = data.attack_range * float(main.GRID_SIZE)
		_draw_dashed_circle(range_center, range_px, Color(1, 1, 1, 0.85), 3.0)

	# Drill heads preview: always shows the heads (L0/R0 by default
	# when no ore is in scan range) so the ghost reads as a complete
	# drill regardless of placement validity.
	if data and data.tags.has("drill_heads"):
		var dh_levels: Dictionary = _get_drill_head_levels(preview_grid_pos, main.placement_rotation, data.grid_size)
		var dh_tint: Color = Color(1, 1, 1, 0.6) if can_place_excluding_range else Color(1, 0.3, 0.3, 0.5)
		_draw_drill_heads(preview_grid_pos, main.placement_rotation, data.grid_size, dh_levels, main.selected_building, dh_tint)
	if data and (data.tags.has("crusher_heads") or data.tags.has("grinder_heads")):
		var ch_tint: Color = Color(1, 1, 1, 0.6) if can_place_excluding_range else Color(1, 0.3, 0.3, 0.5)
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

	# Drill / extractor mining range preview: reuse the dashed line style
	# the cable preview uses, but only along the front edge in the
	# facing direction. Shows how far the drill will reach into ore.
	# Omnidirectional / floor / geyser / wall miners don't have a
	# meaningful "forward" so they skip the preview.
	if data and data.category == BlockData.BlockCategory.EXTRACTORS \
			and data.mine_range > 0 \
			and not data.tags.has("floor_miner") \
			and not data.tags.has("omnidirectional") \
			and not data.tags.has("geyser_miner") \
			and not data.tags.has("wall_miner"):
		_draw_drill_range_preview(preview_grid_pos, data.grid_size,
			main.placement_rotation, data.mine_range)


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


## Draws a yellow dashed range indicator along the drill's facing
## direction, marking the front edge + `mine_range` tiles ahead. Same
## visual language as `_draw_cable_range_preview` so the player reads
## both as "this is what it reaches".
func _draw_drill_range_preview(origin: Vector2i, grid_size: Vector2i, rotation: int, mine_range: int) -> void:
	if mine_range <= 0:
		return
	var gs := float(main.GRID_SIZE)
	var parallax_off := _get_top_offset(Vector2.ZERO)
	var dash_color := Color(1.0, 0.9, 0.2, 0.85)

	var dir_v: Vector2i
	match rotation:
		0: dir_v = Vector2i(1, 0)
		1: dir_v = Vector2i(0, 1)
		2: dir_v = Vector2i(-1, 0)
		3: dir_v = Vector2i(0, -1)
		_: dir_v = Vector2i(1, 0)
	var dir_vf: Vector2 = Vector2(dir_v)

	var front_cells := _get_front_edge(origin, grid_size, rotation)
	# One dash per tile of mine_range, starting at the front edge cell
	# and walking forward. mine_range = 4 → 4 dashes (plasma bore),
	# mine_range = 6 → 6 dashes (advanced plasma bore).
	var line_tiles: int = mine_range
	var dash_frac := 0.55

	for front in front_cells:
		# Start at the centre of the front-edge tile.
		var center: Vector2 = Vector2(front) * gs + Vector2(gs * 0.5, gs * 0.5) + parallax_off
		for t in range(line_tiles):
			var seg_start: Vector2 = center + dir_vf * (gs * (float(t) - 0.5))
			var seg_end: Vector2 = seg_start + dir_vf * (gs * dash_frac)
			draw_line(seg_start, seg_end, dash_color, 2.0)


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
		var ad_sys = get_node_or_null("/root/Main/ArchiveDecoderSystem")
		if ad_sys and ad_sys.has_method("register"):
			ad_sys.register(_grid_pos)
	queue_redraw()


func _on_building_destroyed(_grid_pos: Vector2i) -> void:
	# Same logic as placement: only dirty walls if the destroyed building was
	# sitting on one (its anchor cell overlaps a wall tile). Non-wall
	# destructions don't affect the wall render cache.
	var terrain_ref = _terrain_ref()
	if terrain_ref and terrain_ref.wall_tiles.has(_grid_pos):
		_walls_dirty = true
	# Drop any LogisticControlSystem state attached to this anchor so a
	# destroyed dispatcher / requestor doesn't keep emitting disable
	# assertions, and so a destroyed FACED block's disable entry clears.
	var lc = get_node_or_null("/root/Main/LogisticControlSystem")
	if lc and lc.has_method("on_block_removed"):
		lc.on_block_removed(_grid_pos)
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
	var ad_sys_d = get_node_or_null("/root/Main/ArchiveDecoderSystem")
	if ad_sys_d and ad_sys_d.has_method("unregister"):
		ad_sys_d.unregister(_grid_pos)
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
## Held-block render for the three block kinds whose live appearance
## relies on per-frame dynamic layers — vent turbine, vent condenser,
## and wall crusher / grinder. The standard composite bake at rot=0
## either misses these layers entirely (no top_sprite for the
## condenser → blank icon, no head sprite for the crusher) or
## bakes them at a single frozen angle (turbine). This helper
## replays the live draw using the saved `head_spin_state` so the
## blades keep turning while the block is in transit.
func _draw_held_dynamic_block(payload: Dictionary, block_data: BlockData, pos: Vector2, visual_angle: float, bw: float, bh: float, scale: float) -> void:
	var c: CanvasItem = _ccanvas()
	var spin_root: Dictionary = payload.get("head_spin_state", {})

	# --- VENT TURBINE / CONDENSER --------------------------------
	# Two spinning inner copies (offset 45° from each other) under a
	# static base plate. Matches `_draw_vent_turbine` / `_draw_vent_condenser`.
	if block_data.id == &"vent_turbine" or block_data.id == &"vent_condenser":
		var is_turbine: bool = block_data.id == &"vent_turbine"
		var inner_tex: Texture2D = _vent_turbine_inner_texture if is_turbine else _vent_condenser_inner_texture
		var base_tex: Texture2D = _vent_turbine_base_texture if is_turbine else _vent_condenser_base_texture
		var sub: Dictionary = spin_root.get("vent_turbine" if is_turbine else "vent_condenser", {})
		var spin_angle: float = float(sub.get("angle", 0.0))
		var size := Vector2(bw, bh)
		# Apply the held transform once; everything below is in local space.
		c.draw_set_transform(pos, visual_angle, Vector2(scale, scale))
		if inner_tex:
			# Two interleaved discs, same `angle` so they stay locked.
			c.draw_set_transform(pos, visual_angle + spin_angle, Vector2(scale, scale))
			c.draw_texture_rect(inner_tex, Rect2(-size * 0.5, size), false)
			c.draw_set_transform(pos, visual_angle + spin_angle + PI / 4.0, Vector2(scale, scale))
			c.draw_texture_rect(inner_tex, Rect2(-size * 0.5, size), false)
		if base_tex:
			c.draw_set_transform(pos, visual_angle, Vector2(scale, scale))
			c.draw_texture_rect(base_tex, Rect2(-size * 0.5, size), false)
		c.draw_set_transform(Vector2.ZERO, 0.0)
		return

	# --- WALL CRUSHER / GRINDER ----------------------------------
	# Body sprite first, then `head_count` heads pinned along the
	# block's local front edge. The bake's visual_angle rotates the
	# block as a whole; head positions are stamped in the held block's
	# local frame (which assumes rotation 0 = front along +X).
	if block_data.tags.has("crusher_heads") or block_data.tags.has("grinder_heads"):
		# Body sprite first (top_sprite, or icon as fallback). Centered
		# at pos and rotated by visual_angle so the held block tumbles
		# with the grabber.
		var body_tex: Texture2D = block_data.top_sprite if block_data.top_sprite else block_data.icon
		if body_tex:
			c.draw_set_transform(pos, visual_angle, Vector2(scale, scale))
			c.draw_texture_rect(body_tex, Rect2(-bw * 0.5, -bh * 0.5, bw, bh), false)
			c.draw_set_transform(Vector2.ZERO, 0.0)
		var is_grinder: bool = block_data.tags.has("grinder_heads")
		var head_tex: Texture2D = _grinder_head_texture if is_grinder else _crusher_head_texture
		if head_tex == null:
			return
		var crusher_sub: Dictionary = spin_root.get("crusher", {})
		var gs: float = float(main.GRID_SIZE)
		# Number of front-edge cells when rotation = 0 is the block's
		# Y dim (front faces +X, edge runs along +Y). Each head sits at
		# the body's right edge, vertically along the front.
		var head_count: int = block_data.grid_size.y
		var head_world_size: float = gs * 0.75
		var head_size := Vector2(head_world_size, head_world_size)
		var edge_mid: float = (float(head_count) - 1.0) * 0.5
		for i in range(head_count):
			var angle_i: float = float(crusher_sub.get("angle_%d" % i, 0.0))
			# Local position of head i, relative to block CENTER, in the
			# block's rot=0 frame. Front edge x = (grid_size.x/2 - 0.5)*gs.
			# Heads centered on each front cell along Y, with the same
			# 0.1×lateral-tiles edge squeeze the placed render uses.
			var local_x: float = (float(block_data.grid_size.x) / 2.0 - 0.5) * gs
			var local_y: float = (float(i) + 0.5 - float(block_data.grid_size.y) / 2.0) * gs
			var lateral_tiles: float = float(i) - edge_mid
			local_y -= lateral_tiles * gs * 0.1
			c.draw_set_transform(pos, visual_angle, Vector2(scale, scale))
			# Compose local pos × head rotation by translating the
			# transform: re-set transform centered on the head's local
			# position, with the held block's visual rotation PLUS the
			# head's own spin angle.
			var head_world: Vector2 = pos + Vector2(local_x, local_y).rotated(visual_angle) * scale
			c.draw_set_transform(head_world, visual_angle + angle_i, Vector2(scale, scale))
			c.draw_texture_rect(head_tex, Rect2(-head_size * 0.5, head_size), false)
		c.draw_set_transform(Vector2.ZERO, 0.0)
		return


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
		# Block types with dynamic per-frame layers (vent turbine /
		# condenser spin, crusher / grinder heads) skip the static
		# composite bake — that bake would freeze the inner blade at
		# a single angle and drop the heads entirely, making picked-
		# up versions look broken. We layer them manually below using
		# the captured spin state in `payload.head_spin_state`.
		var has_dyn_layers: bool = (block_data.id == &"vent_turbine") \
			or (block_data.id == &"vent_condenser") \
			or block_data.tags.has("crusher_heads") \
			or block_data.tags.has("grinder_heads")
		# Turrets need head positions to come from the saved aim angles,
		# not the rot=0 bake — otherwise the heads "reset" to a neutral
		# pose the moment the crane closes. Bake covers chassis-only
		# blocks (cores, vents); turrets fall through to icon + manual
		# head overlay below.
		var composite_info: Dictionary = {}
		if not is_turret and not has_dyn_layers:
			composite_info = _request_preview_composite(block_data.id, 0)
		if has_dyn_layers:
			_draw_held_dynamic_block(payload, block_data, pos, visual_angle, bw, bh, scale)
		elif not composite_info.is_empty():
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
		# Crane-held units render at their full in-world size (no shrink), so
		# a carried unit looks identical to the same unit on the ground.
		var unit_visual: float = gs * scale
		# Saved poses from the moment of pickup. `facing_angle` is the
		# chassis/body rotation, `aim_angle` is the head rotation —
		# both world-space at pickup time. Held draw rotates them with
		# the outer grabber so the unit reads as being carried in its
		# original pose.
		var saved_facing: float = float(payload.get("facing_angle", 0.0))
		var body_world: float = saved_facing   # carried unit keeps its own facing
		if unit_data:
			if unit_data.base_sprite or unit_data.head_sprite:
				# Render via the shared unit-payload path so the carried unit
				# shows chassis + head + turret heads exactly like in-world,
				# at ITS OWN saved facing/aim/mount rotations (extra_rot = 0) —
				# the unit keeps its pickup pose rather than aligning to the
				# grabber. render_scale 1.0 = exact in-world size + geometry.
				EnemyUnit.draw_unit_payload(c, unit_data, payload, pos, 1.0, 0.0, 1.0)
			elif unit_data.icon:
				var tex_size: Vector2 = _fit_texture_size(unit_data.icon, unit_visual)
				c.draw_set_transform(pos, body_world + PI / 2.0)
				c.draw_texture_rect(unit_data.icon, Rect2(-tex_size * 0.5, tex_size), false, Color(1, 1, 1, 1.0))
				c.draw_set_transform(Vector2.ZERO, 0.0)
			else:
				var us: float = (unit_data.visual_size if unit_data.visual_size > 0 else 8.0) * scale
				var uc: Color = unit_data.color if unit_data.color != Color() else Color(0.5, 0.8, 0.3)
				uc.a = 1.0
				c.draw_circle(pos, us, uc)
				c.draw_arc(pos, us, 0, TAU, 24, uc.lightened(0.3), 1.5)
		else:
			c.draw_circle(pos, 8.0 * scale, Color(0.3, 0.5, 0.9, 1.0))


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
	# LaunchAnimation hides prebuilt blocks until the ring sweep crosses
	# them — skip cable wires that would dangle from a revealed node to
	# a still-hidden node, since the network can't be connected yet.
	var _la_link = get_node_or_null("/root/Main/LaunchAnimation")
	var gs: float = main.GRID_SIZE
	var half_tile := Vector2(gs / 2.0, gs / 2.0)
	var cable_tint := Color(1.0, 1.0, 1.0, 1.0)
	# Cable is drawn at the texture's NATIVE pixel resolution — source
	# rect and destination rect always match 1:1, so no axis gets
	# stretched. Tiling does the heavy lifting:
	#   * Cross-cable width: `draw_w` is chosen as 2 × native_w so we
	#     show TWO complete copies of the texture across the cable's
	#     thickness. Source rect is `draw_w` wide (in texture pixels)
	#     and `texture_repeat = ENABLED` wraps the second copy in
	#     automatically.
	#   * Along the length: each tile is exactly native_h tall in both
	#     source and destination. A 600-px cable shows 6 tiles laid
	#     end-to-end at full native scale, so the texture's pattern
	#     visibly repeats instead of appearing as one giant stretched
	#     image.
	var tex_native_w: float = _wire_texture.get_width()
	var tex_native_h: float = _wire_texture.get_height()
	# 2× native_w gives roughly the same visible width as the previous
	# 15 × SPRITE_SCALE_FACTOR constant while keeping the tiling clean.
	var draw_w: float = tex_native_w * 2.0
	var hw: float = draw_w / 2.0
	var tile_world_h: float = tex_native_h
	for pair in power_sys.cable_connections:
		var ca: Vector2i = pair[0]
		var cb: Vector2i = pair[1]
		if not main.placed_buildings.has(ca) or not main.placed_buildings.has(cb):
			continue
		if _ss_link and (_ss_link.is_tile_hidden(ca) or _ss_link.is_tile_hidden(cb)):
			continue
		# Only consult LaunchAnimation while it's actively in a non-IDLE
		# phase. Once IDLE, _hidden_until_hit has been cleared, but
		# gating on state here also protects against any future paths
		# that might leave stale entries in the dict.
		if _la_link and "state" in _la_link and int(_la_link.state) != 0 \
				and _la_link.has_method("is_block_hidden") \
				and (_la_link.is_block_hidden(ca) or _la_link.is_block_hidden(cb)):
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
		var segments: int = ceili(length / tile_world_h)
		for i in range(segments):
			var t0: float = i * tile_world_h
			var this_world_h: float = minf(tile_world_h, length - t0)
			# Source rect matches the destination 1:1 on both axes so
			# nothing gets stretched. Width samples `draw_w` from a
			# native-width texture — texture_repeat wraps it so two
			# complete copies appear side-by-side. Height samples
			# `this_world_h` from a native-height texture; for full
			# tiles that's exactly the native height, for the final
			# partial tile it's the remaining stub.
			var center: Vector2 = wa + forward * (t0 + this_world_h / 2.0)
			canvas.draw_set_transform(center, angle)
			var src := Rect2(0, 0, draw_w, this_world_h)
			canvas.draw_texture_rect_region(
				_wire_texture,
				Rect2(-hw, -this_world_h / 2.0, draw_w, this_world_h),
				src, cable_tint,
			)
			canvas.draw_set_transform(Vector2.ZERO, 0.0)


## Draws every belt / duct bridge link's tiled visualizer strip onto
## `canvas`. Hosted on the cable overlay (z=52) so the strips render OVER
## copper cables instead of under them. Each strip runs from the EDGE of
## the start bridge's footprint to the EDGE of the end bridge's footprint
## (the segment is clipped at each block's boundary along the link line),
## so at an angle the part that would lie over a bridge is removed and the
## strip still reaches the bridge edge on both ends.
func _draw_bridge_links(canvas: CanvasItem) -> void:
	var power_sys = get_node_or_null("/root/Main/PowerSystem")
	if power_sys == null or not ("linked_pairs" in power_sys):
		return
	if _bridge_visualizer_texture == null:
		return
	var _ss_link = get_node_or_null("/root/Main/SectorScript")
	var gs: float = main.GRID_SIZE
	for pair in power_sys.linked_pairs:
		var pos_a: Vector2i = pair[0]
		var pos_b: Vector2i = pair[1]
		if not main.placed_buildings.has(pos_a) or not main.placed_buildings.has(pos_b):
			continue
		if _ss_link and (_ss_link.is_tile_hidden(pos_a) or _ss_link.is_tile_hidden(pos_b)):
			continue
		var data_a = Registry.get_block(main.placed_buildings[pos_a])
		var data_b = Registry.get_block(main.placed_buildings[pos_b])
		# Belt/duct bridge pair only: both ends carry the bridge tag AND the
		# same belt or duct transport tag.
		var is_belt_bridge: bool = data_a != null and data_b != null \
			and data_a.tags.has("bridge") and data_b.tags.has("bridge") \
			and data_a.tags.has("belt") and data_b.tags.has("belt")
		var is_duct_bridge: bool = data_a != null and data_b != null \
			and data_a.tags.has("bridge") and data_b.tags.has("bridge") \
			and data_a.tags.has("duct") and data_b.tags.has("duct")
		if not (is_belt_bridge or is_duct_bridge):
			continue
		var size_a: Vector2 = Vector2(data_a.grid_size) * gs
		var size_b: Vector2 = Vector2(data_b.grid_size) * gs
		var off_a: Vector2 = _get_top_offset(main.grid_to_world(pos_a))
		var off_b: Vector2 = _get_top_offset(main.grid_to_world(pos_b))
		var center_a: Vector2 = main.grid_to_world(pos_a) + size_a / 2.0 + off_a
		var center_b: Vector2 = main.grid_to_world(pos_b) + size_b / 2.0 + off_b
		var dir: Vector2 = center_b - center_a
		if dir.length_squared() < 0.01:
			continue
		var fwd: Vector2 = dir.normalized()
		# Clip each endpoint to where the center-to-center line exits that
		# block's footprint rect, so the strip begins/ends exactly at the
		# bridge edges (the span over each bridge body is removed). At an
		# angle this lands on the correct edge automatically.
		var rect_a := Rect2(main.grid_to_world(pos_a) + off_a, size_a)
		var rect_b := Rect2(main.grid_to_world(pos_b) + off_b, size_b)
		var edge_a: Vector2 = _ray_exit_point(center_a, fwd, rect_a)
		var edge_b: Vector2 = _ray_exit_point(center_b, -fwd, rect_b)
		# Degenerate (bridges overlapping / adjacent): nothing to draw.
		if (edge_b - edge_a).dot(fwd) <= 0.0:
			continue
		_draw_bridge_visualizer(canvas, edge_a, edge_b)


## Returns the point where a ray from `origin` along unit vector `d` leaves
## axis-aligned `rect`. If the origin is inside (the normal case — block
## centers), this is the boundary crossing in the +d direction. Falls back
## to `origin` if the direction is degenerate.
func _ray_exit_point(origin: Vector2, d: Vector2, rect: Rect2) -> Vector2:
	var t_max: float = INF
	if absf(d.x) > 1e-6:
		var tx1: float = (rect.position.x - origin.x) / d.x
		var tx2: float = (rect.position.x + rect.size.x - origin.x) / d.x
		t_max = minf(t_max, maxf(tx1, tx2))
	if absf(d.y) > 1e-6:
		var ty1: float = (rect.position.y - origin.y) / d.y
		var ty2: float = (rect.position.y + rect.size.y - origin.y) / d.y
		t_max = minf(t_max, maxf(ty1, ty2))
	if t_max == INF or t_max <= 0.0:
		return origin
	return origin + d * t_max


## Mindustry-style bridge link visual: tiles `_bridge_visualizer_texture`
## end-to-end from `world_a` to `world_b`, clipping the final partial tile
## so the strip is exactly the span length (no stretch). Mirrors the cable
## tiling in `_draw_cable_links`: source rect matches destination 1:1 so
## nothing is squashed, the texture just repeats along the run.
## Visual scale for the tiled strip. The texture is drawn at this fraction
## of its native pixel size (kept uniform so the art isn't distorted), then
## tiled+clipped along the span. Lower = smaller / thinner.
const _BRIDGE_VISUALIZER_SCALE := 0.28
func _draw_bridge_visualizer(canvas: CanvasItem, world_a: Vector2, world_b: Vector2) -> void:
	if _bridge_visualizer_texture == null:
		return
	var dir: Vector2 = world_b - world_a
	var length: float = dir.length()
	if length < 0.01:
		return
	var forward: Vector2 = dir / length
	# +PI/2 (instead of -PI/2) flips the strip 180° so the texture's arrows
	# point the opposite way along the span.
	var angle: float = forward.angle() + PI / 2.0
	var s: float = _BRIDGE_VISUALIZER_SCALE
	# On-screen size = native × scale, so the strip is much smaller than the
	# full-resolution texture while keeping its aspect ratio undistorted.
	var native_w: float = _bridge_visualizer_texture.get_width()
	var native_h: float = _bridge_visualizer_texture.get_height()
	if native_h < 1.0 or native_w < 1.0:
		return
	var draw_w: float = native_w * s
	var hw: float = draw_w / 2.0
	var tile_world_h: float = native_h * s   # one tile's on-screen length
	var tint := Color(1, 1, 1, 1)
	var segments: int = ceili(length / tile_world_h)
	for i in range(segments):
		var t0: float = i * tile_world_h
		var this_world_h: float = minf(tile_world_h, length - t0)
		var center: Vector2 = world_a + forward * (t0 + this_world_h / 2.0)
		canvas.draw_set_transform(center, angle)
		# Source samples the proportional region from the texture top so the
		# final partial tile is CLIPPED (not scaled): dest_h / scale texels.
		var src := Rect2(0, 0, native_w, this_world_h / s)
		canvas.draw_texture_rect_region(
			_bridge_visualizer_texture,
			Rect2(-hw, -this_world_h / 2.0, draw_w, this_world_h),
			src, tint,
		)
		canvas.draw_set_transform(Vector2.ZERO, 0.0)


func _draw_links() -> void:
	var power_sys = get_node_or_null("/root/Main/PowerSystem")
	if power_sys == null:
		return

	# Belt / duct bridge link strips are NOT drawn here — they render on the
	# cable overlay (z=52) via `_draw_bridge_links(canvas)` so they sit OVER
	# cables instead of under them (BuildingSystem itself is z=50). All other
	# link types (mass drivers, etc.) draw no line at all.
	var gs: float = main.GRID_SIZE

	# Cable wires are now drawn by `_cable_overlay` (z 52, above the
	# LogisticsSystem layer at 51) so items running on conveyors
	# underneath a cable line don't render on top of the wire.
	# `_draw_cable_links(canvas)` is the shared implementation; the
	# overlay calls it with itself as the target canvas.

	# --- Mindustry-style linking highlights ---
	# An OUTLINE (no fill) around each relevant block, colored by its role
	# relative to `link_source`. Bridges support multi-link (duct: 3+3), so
	# this walks EVERY pair touching the source, not just the first.
	#   BLUE   = input only  (block sends to source / is an incoming end)
	#   YELLOW = output only (block receives from source / outgoing end)
	#   GREEN  = both (has at least one incoming AND one outgoing link)
	#   RED    = a valid link candidate in range, but NOT connected yet
	if link_source == Vector2i(-1, -1):
		return

	var src_data: BlockData = Registry.get_block(main.placed_buildings.get(link_source, &""))
	if src_data == null:
		return

	var blue_outline := Color(0.4, 0.75, 1.0, 0.95)
	var yellow_outline := Color(1.0, 0.9, 0.3, 0.95)
	var green_outline := Color(0.45, 1.0, 0.55, 0.95)
	var red_outline := Color(1.0, 0.35, 0.35, 0.95)

	var draw_block_outline := func(a: Vector2i, outline: Color):
		var bd: BlockData = Registry.get_block(main.placed_buildings.get(a, &""))
		if bd == null:
			return
		var wp: Vector2 = main.grid_to_world(a)
		var off = _get_top_offset(wp)
		var rp: Vector2 = wp + off
		var bw: float = bd.grid_size.x * gs
		var bh: float = bd.grid_size.y * gs
		draw_rect(Rect2(rp, Vector2(bw, bh)), outline, false, 2.5)

	# Role color for one anchor by its link membership. In a linked_pair,
	# pair[0] is the SOURCE (sends items across the link → that end is an
	# OUTPUT) and pair[1] is the DESTINATION (receives → that end is an
	# INPUT). So: pair[1] member → input (BLUE), pair[0] member → output
	# (YELLOW), both → GREEN. Walks linked_pairs ONCE per anchor — cheap
	# given bridges cap at 6 links each.
	var role_outline_for := func(anchor: Vector2i) -> Color:
		var has_output := false   # anchor is a source end (pair[0])
		var has_input := false    # anchor is a destination end (pair[1])
		if power_sys and "linked_pairs" in power_sys:
			for pair in power_sys.linked_pairs:
				if pair[0] == anchor:
					has_output = true
				elif pair[1] == anchor:
					has_input = true
				if has_output and has_input:
					break
		if has_output and has_input:
			return green_outline
		if has_input:
			return blue_outline
		if has_output:
			return yellow_outline
		# Brand-new selection with no links yet — show as a pending source.
		return blue_outline

	# Collect every anchor connected to link_source (plus link_source itself)
	# and outline each with its own role color.
	var to_highlight: Dictionary = {link_source: true}
	if power_sys and "linked_pairs" in power_sys:
		for pair in power_sys.linked_pairs:
			var pa: Vector2i = main.building_origins.get(pair[0], pair[0])
			var pb: Vector2i = main.building_origins.get(pair[1], pair[1])
			if pa == link_source:
				to_highlight[pb] = true
			elif pb == link_source:
				to_highlight[pa] = true

	# RED outlines: blocks that COULD legally link to the source (same
	# bridge / mass-driver kind, within range) but aren't connected yet.
	# Mirrors the validity gate in `_handle_link_click_on_anchor`.
	var src_is_bridge: bool = src_data.tags.has("bridge")
	var src_is_md: bool = src_data.tags.has("mass_driver")
	var anchors: Dictionary = main.get_building_anchors()
	for cand in anchors:
		if cand == link_source or to_highlight.has(cand):
			continue
		var cdata: BlockData = Registry.get_block(main.placed_buildings.get(cand, &""))
		if cdata == null:
			continue
		# Same link family (bridge↔bridge or mass-driver↔mass-driver).
		if cdata.tags.has("bridge") != src_is_bridge:
			continue
		if cdata.tags.has("mass_driver") != src_is_md:
			continue
		if not (src_is_bridge or src_is_md):
			continue
		var max_range: float = maxf(src_data.link_range, cdata.link_range)
		if max_range <= 0.0:
			continue
		var dx: float = float(cand.x - link_source.x)
		var dy: float = float(cand.y - link_source.y)
		if sqrt(dx * dx + dy * dy) > max_range:
			continue
		draw_block_outline.call(cand, red_outline)

	# Connected + source outlines drawn last so they sit over any red ones.
	for a in to_highlight:
		draw_block_outline.call(a, role_outline_for.call(a))

	# (No extending source→mouse line and no link-range circle — the block
	# outlines above already show what's selectable / connected.)


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
	if _schematic == null or not _schematic.dragging:
		return
	var min_x: int = mini(_schematic.start.x, _schematic.end.x)
	var min_y: int = mini(_schematic.start.y, _schematic.end.y)
	var max_x: int = maxi(_schematic.start.x, _schematic.end.x)
	var max_y: int = maxi(_schematic.start.y, _schematic.end.y)
	var top_left: Vector2 = main.grid_to_world(Vector2i(min_x, min_y))
	var w: float = float((max_x - min_x + 1) * main.GRID_SIZE)
	var h: float = float((max_y - min_y + 1) * main.GRID_SIZE)
	var offset: Vector2 = _get_top_offset(top_left)
	var rect_pos: Vector2 = top_left + offset
	draw_rect(Rect2(rect_pos, Vector2(w, h)), Color(1, 0.9, 0, 0.2), true)
	draw_rect(Rect2(rect_pos, Vector2(w, h)), Color(1, 0.9, 0, 0.6), false, 2.0)


## Records that the block at `anchor` was just flipped from DERELICT
## to LUMINA so the draw pass can paint a brief yellow flash over it.
## Same visual cadence as the launch-animation block reveal but
## without the white kicker — just yellow → fade to normal.
func register_conversion_flash(anchor: Vector2i) -> void:
	_conversion_flash[anchor] = Time.get_ticks_msec() / 1000.0
	queue_redraw()


## Returns the tint to composite over `anchor` for the conversion
## flash, or `Color(0,0,0,0)` when the flash is done / not active.
## RGB picks the colour, alpha picks the strength — drawn over the
## block's painted sprite in pass 4.
func get_conversion_flash_tint(anchor: Vector2i) -> Color:
	if not _conversion_flash.has(anchor):
		return Color(0, 0, 0, 0)
	var now: float = Time.get_ticks_msec() / 1000.0
	var dt: float = now - float(_conversion_flash[anchor])
	if dt >= _CONVERSION_FLASH_FADE:
		_conversion_flash.erase(anchor)
		return Color(0, 0, 0, 0)
	if dt < _CONVERSION_FLASH_YELLOW:
		# Full-strength yellow band.
		return Color(1.0, 0.85, 0.2, 0.85)
	# Fade band: yellow alpha drops linearly to 0.
	var fade_t: float = (dt - _CONVERSION_FLASH_YELLOW) \
			/ maxf(_CONVERSION_FLASH_FADE - _CONVERSION_FLASH_YELLOW, 0.001)
	return Color(1.0, 0.85, 0.2, lerpf(0.85, 0.0, fade_t))


## Pushes a unit-payload dict directly onto the block anchored at `anchor`.
## Handles three accept paths:
##   • payload / freight conveyors → logistics.payload_items[anchor]
##   • mass drivers                → logistics.mass_driver_state[anchor].payload
##   • deconstructors              → logistics.deconstructor_state[anchor]
## Returns true when the payload was accepted.
func inject_unit_as_payload(anchor: Vector2i, payload: Dictionary) -> bool:
	if _logistics == null:
		return false
	if not main.placed_buildings.has(anchor):
		return false
	var bid: StringName = main.placed_buildings[anchor]
	var bdata = Registry.get_block(bid)
	if bdata == null:
		return false

	# Deconstructor: occupies its `deconstructor_state` slot with a fresh
	# payload. Skip when something's already being processed.
	if bdata.tags.has("deconstructor"):
		if not _logistics.deconstructor_state.has(anchor):
			_logistics.deconstructor_state[anchor] = {
				"payload": null, "phase": "idle", "timer": 0.0, "pending_items": {},
			}
		var dst: Dictionary = _logistics.deconstructor_state[anchor]
		if dst.get("payload") != null:
			return false
		var decon_time := 2.0
		dst["payload"] = payload
		dst["phase"] = "deconstructing"
		dst["timer"] = decon_time
		return true

	# Unit Upgrader: takes a unit payload into its held slot, or a module
	# building payload into its queue.
	if bdata.tags.has("upgrader"):
		if _logistics.has_method("_try_accept_upgrader_payload"):
			return _logistics._try_accept_upgrader_payload(anchor, payload)
		return false

	# Payload Refit Bay: only takes a unit payload that carries ≥1 upgrade.
	if bdata.tags.has("refit_bay"):
		if payload.get("type", "") != "unit":
			return false
		if (payload.get("applied_upgrades", []) as Array).is_empty():
			return false
		if not _logistics.refit_state.has(anchor):
			_logistics.refit_state[anchor] = {"unit": null, "pending": [], "timer": 0.0, "ejecting": false}
		var rst: Dictionary = _logistics.refit_state[anchor]
		if rst.get("unit") != null:
			return false
		rst["unit"] = payload
		rst["pending"] = (payload.get("applied_upgrades", []) as Array).duplicate()
		rst["ejecting"] = false
		rst["timer"] = 0.0
		return true

	# Mass driver: park the payload in `mass_driver_state[anchor].payload`
	# and let the rotate→fire pipeline pick it up next tick.
	if bdata.tags.has("mass_driver"):
		if not _logistics.mass_driver_state.has(anchor):
			_logistics.mass_driver_state[anchor] = {}
		var mst: Dictionary = _logistics.mass_driver_state[anchor]
		if mst.get("payload") != null:
			return false
		mst["payload"] = payload
		mst["phase"] = mst.get("phase", "idle")
		return true

	# Payload / freight conveyor: drop straight into payload_items keyed
	# by anchor. Skip when the slot is already occupied.
	if (bdata.tags.has("payload") or bdata.tags.has("freight")) and bdata.transport_speed > 0:
		if _logistics.payload_items.has(anchor):
			return false
		_logistics.payload_items[anchor] = {
			"payload_data": payload,
			"progress": 0.0,
			"entry_dir": -1,
		}
		return true

	return false


func _on_main_building_selected(block_id: StringName) -> void:
	if _schematic:
		_schematic.on_building_selected(block_id)


# (Schematic functions extracted to schematic_system.gd)


func _draw_schematic_placement() -> void:
	if _schematic == null or not _schematic.placing:
		return
	var mouse_world: Vector2 = get_global_mouse_position()
	var base_grid: Vector2i = main.world_to_grid(mouse_world)
	var gs: float = float(main.GRID_SIZE)
	for rel_pos in _schematic.place_blocks:
		var grid_pos: Vector2i = base_grid + rel_pos
		var block_id: StringName = _schematic.place_blocks[rel_pos]
		var data = Registry.get_block(block_id)
		if data == null:
			continue
		var world_pos: Vector2 = main.grid_to_world(grid_pos)
		var offset: Vector2 = _get_top_offset(world_pos) * _get_height_scale(block_id)
		var w: float = gs * data.grid_size.x
		var h: float = gs * data.grid_size.y
		var top_pos: Vector2 = world_pos + offset
		var slot_ok: bool = true
		for dx in range(data.grid_size.x):
			for dy in range(data.grid_size.y):
				var cp: Vector2i = grid_pos + Vector2i(dx, dy)
				if not main.is_within_bounds(cp) or not main.is_cell_empty(cp):
					slot_ok = false
				elif _terrain and _terrain.has_wall(cp):
					slot_ok = false
		var slot_tint: Color
		var sprite_tint: Color
		var border_col: Color
		if slot_ok:
			sprite_tint = Color(1, 1, 1, 0.85)
			border_col = Color(0.3, 1.0, 0.3, 0.6)
			slot_tint = Color(1, 1, 1, 0.6)
		else:
			sprite_tint = Color(1.0, 0.55, 0.55, 0.85)
			border_col = Color(1.0, 0.3, 0.3, 0.7)
			slot_tint = Color(1, 0.3, 0.3, 0.5)
		# Use the actual block sprite(s) instead of a flat colour. Prefer
		# base+top layered (matches what a placed block looks like); fall
		# back to top-only, then icon, then the legacy colour rect.
		var t_rot: int = int(_schematic.place_rotation.get(rel_pos, 0))
		var is_dir: bool = _is_directional(block_id)
		if data.base_sprite and data.top_sprite:
			_draw_block_texture(data.base_sprite, top_pos, w, h, t_rot, sprite_tint, is_dir)
			_draw_block_texture(data.top_sprite, top_pos, w, h, t_rot, sprite_tint, is_dir)
		elif data.top_sprite:
			_draw_block_texture(data.top_sprite, top_pos, w, h, t_rot, sprite_tint, is_dir)
		elif data.base_sprite:
			_draw_block_texture(data.base_sprite, top_pos, w, h, t_rot, sprite_tint, is_dir)
		elif data.icon:
			draw_texture_rect(data.icon, Rect2(top_pos, Vector2(w, h)), false, sprite_tint)
		else:
			var fallback_col: Color = _get_block_color(block_id)
			fallback_col.a = 0.4
			draw_rect(Rect2(top_pos, Vector2(w, h)), fallback_col, true)
		# Tint frame: green = placeable, red = blocked.
		draw_rect(Rect2(top_pos, Vector2(w, h)), border_col, false, 1.5)
		if data.is_turret():
			_draw_turret_preview_heads(data, top_pos, w, h, t_rot, slot_tint)


## Wrapper retained so HUD's start_schematic_placement(data) call site keeps
## resolving. Forwards into SchematicSystem.start_placement.
func start_schematic_placement(data: Dictionary) -> void:
	if _schematic:
		_schematic.start_placement(data)




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
## Heals every friendly placed building within each placed mender's
## `mend_radius` by `mend_amount` HP/sec. Skips fully-healed targets,
## the menders' own selves are healed too. Inactive / unpowered menders
## (matching the overdrive eligibility rules) are skipped.
func _tick_menders(delta: float) -> void:
	if delta <= 0.0:
		return
	var gs: float = float(main.GRID_SIZE)
	var power_sys = _power_sys_ref()
	var menders: Array = []
	for anchor in main.placed_buildings:
		if main.building_origins.get(anchor, anchor) != anchor:
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings[anchor])
		if data == null or not data.tags.has("mender"):
			continue
		if data.mend_radius <= 0.0 or data.mend_amount <= 0.0:
			continue
		if main.get_building_faction(anchor) != main.Faction.LUMINA:
			continue
		if main.is_building_inactive(anchor):
			continue
		# Power gate. Menders with `electrical_power_use > 0` scale
		# their heal rate by the network's efficiency — fully powered
		# → full mend_amount; brownout → proportionally weaker; zero
		# power → mender is skipped entirely. Menders that authored
		# zero power use (free heal) are unaffected.
		var eff: float = 1.0
		if power_sys and data.electrical_power_use > 0.0:
			if power_sys.has_method("get_electrical_efficiency"):
				eff = clampf(float(power_sys.get_electrical_efficiency(anchor)), 0.0, 1.0)
			if eff <= 0.0:
				continue
		var center: Vector2 = main.grid_to_world(anchor) \
			+ Vector2(data.grid_size.x * gs * 0.5, data.grid_size.y * gs * 0.5)
		menders.append({
			"center": center,
			"radius_px": data.mend_radius * gs,
			"amount": data.mend_amount * eff,
		})
	if menders.is_empty():
		return
	var shield_sys = main.get_node_or_null("ShieldSystem")
	# For each friendly placed building, find the strongest mender in
	# range and apply its heal. (Multiple menders covering the same
	# target don't stack — taking the max keeps the math predictable
	# and matches how overdrive picks the best zone.) The same loop
	# also applies the heal to the target's shield (if any) so a
	# shield projector / shielded core inside a mender field tops
	# its barrier back up — not just its chassis HP.
	for t_anchor in main.placed_buildings:
		if main.building_origins.get(t_anchor, t_anchor) != t_anchor:
			continue
		if main.get_building_faction(t_anchor) != main.Faction.LUMINA:
			continue
		var t_data: BlockData = Registry.get_block(main.placed_buildings[t_anchor])
		if t_data == null or t_data.max_health <= 0.0:
			continue
		var current: float = float(main.building_health.get(t_anchor, 0.0))
		# Anything that needs SOMETHING healed (block HP and/or shield HP)
		# is a candidate this tick. The two pools are processed
		# independently below.
		var block_needs_heal: bool = current > 0.0 and current < t_data.max_health
		var shield_needs_heal: bool = shield_sys != null \
			and shield_sys.has_method("is_shield_damaged") \
			and shield_sys.is_shield_damaged(t_anchor)
		if not block_needs_heal and not shield_needs_heal:
			continue
		var t_center: Vector2 = main.grid_to_world(t_anchor) \
			+ Vector2(t_data.grid_size.x * gs * 0.5, t_data.grid_size.y * gs * 0.5)
		var best_rate: float = 0.0
		for m in menders:
			if t_center.distance_to(m["center"]) <= m["radius_px"]:
				best_rate = maxf(best_rate, float(m["amount"]))
		if best_rate <= 0.0:
			continue
		if block_needs_heal:
			main.building_health[t_anchor] = minf(current + best_rate * delta, t_data.max_health)
		if shield_needs_heal:
			shield_sys.heal_shield(t_anchor, best_rate * delta)



























## Updates crane arm angle and extension toward target at constant
## speed. Pinned to BuildingSystem because the ARM length constants
## here are also referenced by the draw stack. The motion multiplier
## (power × water boost) is delegated to CraneSystem.
func update_crane_telescope(anchor: Vector2i, target: Vector2, delta: float) -> void:
	if not crane_states.has(anchor):
		return
	var state: Dictionary = crane_states[anchor]
	var data = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if data == null:
		return
	# Cranes can't operate without power. A starved network freezes
	# arm motion entirely; a brownout (efficiency in (0, 1)) slows the
	# motion proportionally — same gating model the drill / factory
	# loops use. The multiplier (power × water-boost) lives on
	# CraneSystem now; query through it.
	var crane_sys = get_node_or_null("/root/Main/CraneSystem")
	var speed_mult: float = crane_sys.crane_speed_multiplier(anchor) if crane_sys else 1.0
	if speed_mult <= 0.0:
		return
	var gs: float = main.GRID_SIZE
	var base: Vector2 = main.grid_to_world(anchor) + Vector2(data.grid_size.x * gs / 2.0, data.grid_size.y * gs / 2.0)

	var max_reach: float = data.crane_range * gs
	var to_target: Vector2 = target - base
	var target_dist: float = clampf(to_target.length(), CRANE_ARM_MIN_TOTAL, max_reach)
	var target_angle: float = to_target.angle() if to_target.length() > 1.0 else state["arm_angle"]

	var eff_delta: float = delta * speed_mult

	# Rotate at constant speed
	var angle_diff: float = wrapf(target_angle - state["arm_angle"], -PI, PI)
	var max_rotate: float = CRANE_ROTATE_SPEED * eff_delta
	if absf(angle_diff) <= max_rotate:
		state["arm_angle"] = target_angle
	else:
		state["arm_angle"] = wrapf(state["arm_angle"] + signf(angle_diff) * max_rotate, -PI, PI)

	# Extend/retract at constant speed
	var ext_diff: float = target_dist - state["arm_extension"]
	var max_extend: float = CRANE_EXTEND_SPEED * eff_delta
	if absf(ext_diff) <= max_extend:
		state["arm_extension"] = target_dist
	else:
		state["arm_extension"] += signf(ext_diff) * max_extend


# Crane motion multiplier (power × water boost), dynamic power model,
# and water-boost drain all live on CraneSystem now.



## Draws all crane telescoping arms and cross grabbers.
func _draw_cranes() -> void:
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
		# Range overlay for cranes is now unified with turrets via the
		# hover-driven `_draw_hovered_turret_range`. The old per-frame
		# green arc was redundant and only appeared while controlling.


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
func _draw_crane_pose(state: Dictionary, _data: BlockData, base: Vector2, gs: float, angle_offset: float) -> void:
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
	var g_angle: float = float(state.get("grabber_angle", 0.0)) + angle_offset

	var c: CanvasItem = _ccanvas()
	# Held payload UNDER everything.
	if holding:
		_draw_crane_payload(state["held_payload"], grabber_pos, g_angle, gs, 1.0)

	# Cross grabber UNDER the arm. The head texture is a single bar
	# (orange w/ a diamond), so we draw it twice — once at g_angle
	# and once at g_angle + 90° — to form the cross. Each pass is a
	# square sized to `cs * 2`; the bar art inside is naturally
	# centered so the two passes form a symmetric +.
	if _payload_crane_head_texture:
		var head_size: float = cs * 2.0
		var head_rect := Rect2(-head_size * 0.5, -head_size * 0.5, head_size, head_size)
		c.draw_set_transform(grabber_pos, g_angle)
		c.draw_texture_rect(_payload_crane_head_texture, head_rect, false)
		c.draw_set_transform(grabber_pos, g_angle + PI / 2.0)
		c.draw_texture_rect(_payload_crane_head_texture, head_rect, false)
		c.draw_set_transform(Vector2.ZERO, 0.0)

	# Arm segments ON TOP. Texture is 128 wide × 512 tall — i.e. its
	# LONG dimension is the Y axis. The arm itself extends along the
	# local +X (after `draw_set_transform(center, angle)`), so we
	# rotate the local frame by an extra −90° (`angle − PI/2`) and
	# size the rect as (arm_width × seg_len) so the texture's long
	# axis aligns with the arm direction without being squashed.
	var arm_tex: Texture2D = _payload_crane_arm_texture
	var c1: Vector2 = (base + seg1_end) / 2.0
	if arm_tex:
		c.draw_set_transform(c1, angle - PI / 2.0)
		c.draw_texture_rect(arm_tex, Rect2(-CRANE_ARM1_WIDTH / 2.0, -seg1_len / 2.0, CRANE_ARM1_WIDTH, seg1_len), false)
	else:
		c.draw_set_transform(c1, angle)
		c.draw_rect(Rect2(-seg1_len / 2.0, -CRANE_ARM1_WIDTH / 2.0, seg1_len, CRANE_ARM1_WIDTH), Color(0.5, 0.5, 0.5, 0.85), true)
	c.draw_set_transform(Vector2.ZERO, 0.0)

	var c2: Vector2 = (seg1_end + seg2_end) / 2.0
	if arm_tex:
		c.draw_set_transform(c2, angle - PI / 2.0)
		c.draw_texture_rect(arm_tex, Rect2(-CRANE_ARM2_WIDTH / 2.0, -seg2_len / 2.0, CRANE_ARM2_WIDTH, seg2_len), false)
	else:
		c.draw_set_transform(c2, angle)
		c.draw_rect(Rect2(-seg2_len / 2.0, -CRANE_ARM2_WIDTH / 2.0, seg2_len, CRANE_ARM2_WIDTH), Color(0.42, 0.42, 0.42, 0.9), true)
	c.draw_set_transform(Vector2.ZERO, 0.0)

	var c3: Vector2 = (seg2_end + seg3_end) / 2.0
	if arm_tex:
		c.draw_set_transform(c3, angle - PI / 2.0)
		c.draw_texture_rect(arm_tex, Rect2(-CRANE_ARM3_WIDTH / 2.0, -seg3_len / 2.0, CRANE_ARM3_WIDTH, seg3_len), false)
	else:
		c.draw_set_transform(c3, angle)
		c.draw_rect(Rect2(-seg3_len / 2.0, -CRANE_ARM3_WIDTH / 2.0, seg3_len, CRANE_ARM3_WIDTH), Color(0.35, 0.35, 0.35, 0.95), true)
	c.draw_set_transform(Vector2.ZERO, 0.0)


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
