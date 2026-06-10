extends Node2D

# Preloaded so `EnemyUnit.draw_unit_payload(...)` resolves regardless of
# global class_name registration timing.
const EnemyUnit = preload("res://main/enemy_unit.gd")


# Sibling overlay that paints fluid puddles at z 49 — UNDER buildings
# (z 50) but above the world terrain. The puddles dict lives on the
# parent LogisticsSystem; this child just reads it and draws. Pause
# is honoured by virtue of LogisticsSystem only ticking the puddle
# state while unpaused — the draw itself doesn't move on its own.
class PuddleOverlay extends Node2D:
	var owner_sys: Node = null
	func _process(_delta: float) -> void:
		if owner_sys and not owner_sys.puddles.is_empty():
			queue_redraw()
	func _draw() -> void:
		if owner_sys and owner_sys.has_method("_draw_puddles"):
			owner_sys._draw_puddles(self)


# ============================================================
# LOGISTICS_SYSTEM.GD - Item Movement & Production
# ============================================================
# The factory's circulatory system. Handles the full item pipeline:
#
#   1. DRILLS mine resources from deposit tiles underneath them
#      and push items onto the adjacent cell in their output direction.
#   2. CONVEYORS slide items across cells in their facing direction.
#      Each conveyor cell holds at most 1 item at a time.
#   3. PIPES transport fluids as a continuous fill level (not discrete items).
#      Connected pipes equalize fluid amounts across the network.
#      Pipes with no connected pipe in front leak fluid.
#   4. The CORE absorbs items/fluids that reach it.
#
# Items are rendered as small colored circles that smoothly
# glide along conveyors. The "progress" float (0.0 → 1.0) tracks
# how far an item has slid across its current cell.
#
# Fluids are rendered as colored rectangles under the pipe texture,
# with opacity based on fill level (drawn by BuildingSystem).
#
# SCENE TREE: Place AFTER BuildingSystem so items draw on top.
#   Main
#   ├── ...
#   ├── BuildingSystem
#   ├── LogisticsSystem   ← this script
#   ├── ...
# ============================================================

@onready var main: Node2D = get_node("/root/Main")

# --- CACHED SIBLING REFERENCES (populated in _ready) ---
# Centralized here so the hot _process sub-functions don't re-query the
# scene tree every call. Safe because these siblings live for the lifetime
# of the main scene.
var _terrain: Node2D
var _power_sys: Node
var _sector_script: Node
var _launch_anim: Node
var _building_sys: Node
var _unit_mgr: Node

# --- DIRECTION CONSTANTS ---
# Index: 0=right, 1=down, 2=left, 3=up
# These match the rotation values stored in main.building_rotation.
const DIR_VECTORS := [
	Vector2i(1, 0),   # 0 = right →
	Vector2i(0, 1),   # 1 = down  ↓
	Vector2i(-1, 0),  # 2 = left  ←
	Vector2i(0, -1),  # 3 = up    ↑
]

# --- CONVEYOR STATE ---
# Key = Vector2i (grid position of a conveyor cell)
# Value = Dictionary:
#   "item_id": StringName — which item is on this cell
#   "progress": float — 0.0 (just entered) to 1.0 (ready to transfer)
var conveyor_items := {}

# --- PIPE STATE ---
# Key = Vector2i (grid position of a pipe cell)
# Value = Dictionary:
#   "fluid_id": StringName — which fluid is in this pipe
#   "amount": float — 0.0 to units_per_segment (from FluidData)
var pipe_contents := {}

# --- PIPE JUNCTION STATE ---
# Pipe junctions act like their belt-counterpart junctions: fluid
# crosses through without mixing. Each junction is two independent
# fluid channels — `v` (vertical N↔S axis) and `h` (horizontal E↔W
# axis). They never share fluid through this cell, so a vertical
# pipe network and a horizontal one can cross the same junction
# without merging.
#
# Key  = Vector2i (junction anchor)
# Value = {
#   "v_fluid":  StringName, "v_amount": float,    # vertical channel
#   "h_fluid":  StringName, "h_amount": float,    # horizontal channel
# }
#
# Junctions are EXCLUDED from `pipe_contents` and from the pipe-network
# flood-fill (`_find_pipe_network`). They equalize with their plain-pipe
# neighbours actively each tick via `_tick_pipe_junctions`.
var pipe_junction_state := {}

# --- PUDDLE STATE ---
# Spawned by the pipe-leak tick: a pipe whose facing-front cell has no
# building (or a wall) leaks 0.5 fluid/sec into the front cell, forming
# a puddle in the colour of the carried fluid. Puddles dry up over time
# when no longer fed.
#
# Key = Vector2i (grid position of the puddle — the empty cell in front
#                 of the leaking pipe)
# Value = Dictionary:
#   "fluid_id":   StringName — which fluid is pooling
#   "color":      Color      — pre-cached from the fluid's display colour
#   "amount":     float      — current level [0, PUDDLE_MAX_AMOUNT]
#   "shape":      PackedVector2Array — pre-randomised polygon vertices
#                                      in local cell space [0, GRID_SIZE]
#   "fed":        bool       — set true each frame a pipe leaks into it,
#                              read by the dry-up pass and then cleared
var puddles: Dictionary = {}
const PUDDLE_LEAK_RATE := 2.5    # fluid units / second drained from pipe
# Mindustry PuddleComp parity: at `amount >= maxLiquid / 1.5` a puddle
# starts overflowing into its 4 cardinal neighbours. Used both in the
# spread tick (Phase E) and in the visual draw (the `f` fill ratio is
# `amount / _SPREAD_THRESHOLD`, matching Mindustry's `amount / (maxLiquid/1.5f)`).
const _SPREAD_THRESHOLD: float = 15.0 / 1.5    # == PUDDLE_MAX_AMOUNT / 1.5
const _SPREAD_DEPOSIT_CAP: float = 0.3         # units per neighbour per second
# A fully-fed puddle reaches PUDDLE_MAX_AMOUNT after ~6 seconds of
# continuous dripping (15 / 2.5). At that point the visible blob is
# at full size — roughly the central 8 px Mindustry-scale × 4 tile
# scale = ~one tile across.
const PUDDLE_MAX_AMOUNT := 15.0
const PUDDLE_DRY_RATE := 1.5     # units / second drained from puddle when not fed
# Max circles in a fully-fed puddle. The pre-generated template
# stores this many; how many are actually drawn each frame is gated
# by each circle's own `threshold` against the puddle's current fill.
const _PUDDLE_MAX_CIRCLES := 12
# Max radius (in tiles, from the cluster centre to its farthest
# circle's outer edge). 1.25 tiles → 2.5-tile diameter when every
# circle is active.
const _PUDDLE_MAX_RADIUS_TILES := 1.25
# Vertex count when approximating each circle for `merge_polygons`.
const _PUDDLE_CIRCLE_VERTS := 16
var _puddle_overlay: Node2D = null

# --- DRILL STATE ---
# Key = Vector2i (grid position of a drill)
# Value = float (seconds remaining until next item is produced)
var drill_timers := {}

# --- EXTRACTOR EFFICIENCY ---
# Key = Vector2i (anchor of a drill / wall crusher / fluid pump)
# Value = float in [0, ~1.5]; 1.0 = baseline. Renderer reads this for
# the per-extractor "Efficiency: NN%" overlay.
var extractor_efficiency := {}

# --- PUMP STATE ---
# Key = Vector2i (grid position of a fluid pump)
# Value = float (seconds remaining until next item is produced)
var pump_timers := {}

# --- FACTORY STATE ---
# Key = Vector2i (factory origin position)
# Value = Dictionary:
#   "inputs": Dictionary (item_id -> count accumulated)
#   "phase": String ("collecting", "processing", "outputting")
#   "timer": float (production countdown)
#   "pending_outputs": Dictionary (rel_dir_key -> item_id, remaining outputs to push)
var factory_buffers := {}

# --- DUCT BRIDGE STATE ---
# Round-robin index per multi-output input duct bridge. Lets a single
# input fan out evenly across its 2 or 3 destinations instead of
# always trying the same one first (which would starve the rest).
#   Key = Vector2i (input bridge anchor)
#   Value = int (next destination index to try)
var bridge_output_rr := {}

# Per-output item filter for duct bridges. Maps an output bridge
# anchor to the single item id it'll accept (from ANY incoming
# source). Empty / missing entry means "no filter, accept anything".
# Edited via the world-menu UI (shift+click on an output duct bridge).
#   Key = Vector2i (output anchor)
#   Value = StringName (item id)
var duct_bridge_filters := {}

# --- BLOCK STORAGE ---
# Key = Vector2i (building origin position)
# Value = Dictionary:
#   "items": Dictionary (item_id -> count stored)
#   "fluids": Dictionary (fluid_id -> amount stored)
var block_storage := {}

# --- ROUTER STATE ---
# Key = Vector2i (grid position of a belt router)
# Value = int (round-robin output index)
var router_output_index := {}

# --- JUNCTION STATE ---
# Holds the second item slot for belt junction cells (perpendicular axis).
# Primary-axis items use conveyor_items; perpendicular-axis items use this.
var junction_items := {}

# --- SORTER FILTER STATE ---
# Key = Vector2i (grid position of a sorter / inverted sorter)
# Value = StringName (item_id the sorter filters for, or &"" for unset)
var sorter_filters := {}

# --- SORTER SIDE OUTPUT INDEX ---
# Key = Vector2i, Value = int (0 or 1, alternates between left/right side output)
var sorter_side_index := {}

# --- PAYLOAD STATE ---
# Key = Vector2i (grid position of a payload conveyor cell)
# Value = Dictionary:
#   "payload_data": Dictionary — the payload being transported (building or unit)
#   "progress": float — 0.0 (just entered) to 1.0 (ready to transfer)
#   "entry_dir": int — direction the payload entered from (0-3)
var payload_items := {}

# --- PAYLOAD ROUTER STATE ---
# Key = Vector2i (grid position of a payload router)
# Value = int (round-robin output index)
var payload_router_idx := {}

# --- CONSTRUCTOR STATE ---
# Key = Vector2i (constructor origin position)
# Value = Dictionary:
#   "selected_block": StringName — block_id chosen by the player (or &"" for none)
#   "collected": Dictionary (item_id -> count accumulated toward build_cost)
#   "phase": String ("waiting", "collecting", "building")
#   "timer": float (build countdown during "building" phase)
var constructor_state := {}

# --- DECONSTRUCTOR STATE ---
# Key = Vector2i (deconstructor origin position)
# Value = Dictionary:
#   "payload": Dictionary or null — the building payload being deconstructed
#   "phase": String ("idle", "deconstructing", "outputting")
#   "timer": float (deconstruction countdown)
#   "pending_items": Dictionary (item_id -> count remaining to output)
var deconstructor_state := {}

# --- UNIT UPGRADER STATE ---
# anchor -> {unit: payload|null, queue: [module payloads], applying: StringName,
#            timer: float, applied_session: int}
var upgrader_state := {}

# --- PAYLOAD REFIT BAY STATE ---
# anchor -> {unit: payload|null, pending: [upgrade ids], timer: float, ejecting: bool}
var refit_state := {}

# --- DEV SOURCE BLOCKS ---
# resource_source: anchor -> StringName (item or fluid id) emitted forever.
var source_resource := {}
# payload_source: anchor -> {id: StringName, kind: "block"/"unit", team: int}
var source_payload := {}

# --- REFABRICATOR STATE ---
# Key = Vector2i (refabricator origin position)
# Value = Dictionary:
#   "phase": String ("idle" → "processing" → "outputting")
#   "in_unit_id": StringName — tier-1 unit held (payload snatched from a
#                 payload conveyor).
#   "timer": float — processing countdown in seconds.
#   "out_unit_id": StringName — tier-2 unit derived from in_unit_id,
#                  held as a payload until output conveyor accepts it.
var refabricator_state := {}

# --- FACTORY RECIPE SELECTION STATE ---
# Key = Vector2i (factory origin / anchor).
# Value = StringName — the active recipe id matched against
#         `BlockData.factory_recipes[*].id`. Empty / missing keeps the
#         factory idle (mirrors the refabricator's "pick a T2 first"
#         gate). Populated via `set_factory_recipe(anchor, recipe_id)`.
var factory_recipe_state := {}

# --- LANDING PAD FILTERS ---
# Key = Vector2i (landing pad anchor).
# Value = Array[StringName] of up to 2 entries — item or fluid ids the pad
#         accepts. An empty array means "no filter" (accepts any pod).
# Source-side launchpad code reads `SaveManager.landing_pad_filters` (which
# mirrors this dict per saved sector) so it can validate cross-sector
# routing before queuing a pod.
var landing_pad_filters := {}

# --- LOADER STATE ---
# Key = Vector2i (loader origin position)
# Value = Dictionary:
#   "payload": Dictionary or null — the storage building being filled
#   "phase": String ("idle", "filling")
#   "fill_target": Dictionary (item_id -> amount the storage can hold)
var loader_state := {}

# --- UNLOADER STATE ---
# Key = Vector2i (unloader origin position)
# Value = Dictionary:
#   "payload": Dictionary or null — the storage building being emptied
#   "phase": String ("idle", "emptying")
var unloader_state := {}

# --- MASS DRIVER STATE ---
# Key = Vector2i (mass driver origin position)
# Value = Dictionary:
#   "payload": Dictionary or null — payload waiting to be launched
#   "charge": float — charge progress (0.0 to 1.0)
var mass_driver_state := {}
# --- BELT UNLOADER STATE ---
# Key = Vector2i (unloader origin)
# Value = Dictionary:
#   "timer": float — cooldown until next pull
#   "round_robin": int — rotates which source neighbor to pull from
var belt_unloader_state := {}

# --- MASS DRIVER PROJECTILES ---
# Array of {from: Vector2, to: Vector2, payload_data: Dictionary, progress: float}
var mass_driver_projectiles: Array = []

# --- SETTINGS ---
## How fast items slide across one conveyor cell.
## 2.5 means it takes 0.4 seconds to cross one cell (1.0 / 2.5).
@export var conveyor_speed := 2.5

## Default drill production cycle in seconds.
## Individual drills can override this via their .tres production_time.
@export var default_drill_time := 2.0

# --- PIPE SETTINGS ---
## Fluid units added to a pipe per pump cycle.
const PIPE_PUSH_AMOUNT := 25.0
## Fluid units drained per second from a pipe with no front connection.
const PIPE_LEAK_RATE := 5.0

# --- VISUAL ---
## Tuned at the 64-px baseline grid. Actual drawn size = constant *
## main.SPRITE_SCALE_FACTOR so items scale with GRID_SIZE.
const ITEM_RADIUS := 8.0
const ITEM_TEXTURE_SIZE := 20.0



func _terrain_ref() -> Node2D:
	if _terrain == null:
		_terrain = get_node_or_null("/root/Main/TerrainSystem")
	return _terrain

func _power_sys_ref() -> Node:
	if _power_sys == null:
		_power_sys = get_node_or_null("/root/Main/PowerSystem")
	return _power_sys

func _sector_script_ref() -> Node:
	if _sector_script == null:
		_sector_script = get_node_or_null("/root/Main/SectorScript")
	return _sector_script

func _launch_anim_ref() -> Node:
	if _launch_anim == null or not is_instance_valid(_launch_anim):
		_launch_anim = get_node_or_null("/root/Main/LaunchAnimation")
	return _launch_anim

func _building_sys_ref() -> Node:
	if _building_sys == null:
		_building_sys = get_node_or_null("/root/Main/BuildingSystem")
	return _building_sys

func _unit_mgr_ref() -> Node:
	if _unit_mgr == null:
		_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	return _unit_mgr


func _ready() -> void:
	# Items on conveyors / pipes / etc. need to paint ABOVE the building
	# layer (BuildingSystem sits at z 51) so the player can see resources
	# flowing across the top of belts/ducts. Without this they'd vanish
	# behind every block they crossed.
	z_index = 51
	z_as_relative = false
	# Puddle overlay: a child Node2D pinned at z 49 (under the building
	# layer at 50) so leaked puddles paint UNDER the blocks that sit on
	# top of them. Same pattern BuildingSystem uses for its popup /
	# cable / crane companion overlays.
	_puddle_overlay = PuddleOverlay.new()
	_puddle_overlay.owner_sys = self
	_puddle_overlay.z_index = 49
	_puddle_overlay.z_as_relative = false
	add_child(_puddle_overlay)
	await get_tree().process_frame
	_terrain = get_node_or_null("/root/Main/TerrainSystem")
	_power_sys = get_node_or_null("/root/Main/PowerSystem")
	_sector_script = get_node_or_null("/root/Main/SectorScript")
	_building_sys = get_node_or_null("/root/Main/BuildingSystem")
	_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	main.building_placed.connect(_on_building_placed)
	main.building_destroyed.connect(_on_building_destroyed)
	# A finished build flips a pipe inactive→active (joins its network), so
	# the cached pipe partition must rebuild then too.
	if main.has_signal("building_completed"):
		main.building_completed.connect(_on_building_completed_for_pipes)


func _process(delta: float) -> void:
	if ("world_paused" in main and main.world_paused):
		queue_redraw()
		return
	# Slow producers (drills / pumps / factories) are pure delta-timer state
	# machines: a cycle completes after `production_time` of accumulated
	# delta, then resets. Running them at ~12 Hz instead of 60 Hz with the
	# accumulated delta keeps production RATES identical (only the update
	# granularity coarsens, imperceptible for multi-second recipes) while
	# cutting their per-frame cost ~5×. The three accumulators start at
	# staggered offsets so they fire on different frames — spreading the
	# work rather than spiking it all on one frame every ~83 ms.
	_accum_drill += delta
	if _accum_drill >= _SLOW_TICK_INTERVAL:
		_update_drills(_accum_drill)
		_accum_drill = 0.0
	_accum_pump += delta
	if _accum_pump >= _SLOW_TICK_INTERVAL:
		_update_pumps(_accum_pump)
		_accum_pump = 0.0
	_accum_factory += delta
	if _accum_factory >= _SLOW_TICK_INTERVAL:
		_update_factories(_accum_factory)
		_accum_factory = 0.0
	# Item / fluid / payload motion stays at full frame rate for smoothness.
	_update_conveyors(delta)
	_update_payloads(delta)
	_update_constructors(delta)
	_update_deconstructors(delta)
	_update_refabricators(delta)
	_update_loaders(delta)
	_update_unloaders(delta)
	_update_mass_drivers(delta)
	_update_unit_upgraders(delta)
	_update_refit_bays(delta)
	_update_resource_sources(delta)
	_update_payload_sources(delta)
	_update_pipes(delta)
	_update_storage_unloading(delta)
	_update_belt_unloaders(delta)
	queue_redraw()


# =========================
# CATEGORY-INDEXED BUILDING BUCKETS (perf)
# =========================
# Each per-type update used to re-scan EVERY entry of main.placed_buildings
# once per frame just to find its handful of matching blocks — O(all
# buildings) × number-of-systems every frame, the dominant lag source on
# large sectors. Instead we classify every placed cell ONCE per structural
# change into role buckets, so each update iterates only its own pre-filtered
# list. Rebuilt lazily when `_buckets_dirty` (set on place/destroy) or when
# the building count drifts (a bulk load / any path that bypasses the
# building_placed/destroyed signals). Buckets are keyed by block type only —
# faction flips, disable/enable, and build progress don't change membership,
# so those stay handled by the (cheap) per-building checks in each loop body.
var _buckets: Dictionary = {}
var _buckets_dirty := true
var _buckets_count := -1

# --- Slow-producer throttle (perf) ---
# Drills / pumps / factories tick at ~12 Hz instead of every frame. They're
# delta-timer driven, so passing the accumulated delta keeps rates exact.
# Accumulators start staggered (0, 1/3, 2/3 of the interval) so the three
# batches land on different frames instead of spiking together.
const _SLOW_TICK_INTERVAL := 1.0 / 12.0
var _accum_drill := 0.0
var _accum_pump := _SLOW_TICK_INTERVAL / 3.0
var _accum_factory := _SLOW_TICK_INTERVAL * 2.0 / 3.0

# --- Pipe network partition cache (perf) ---
# The per-frame `_find_pipe_network` flood-fill was the single biggest
# large-map CPU cost: it rebuilt EVERY connected pipe network from scratch
# every frame (plus a linked_pairs scan per bridge cell). Pipe TOPOLOGY
# only changes on structural events, so we cache the partition (a list of
# networks, each an Array[Vector2i]) and reuse it. Fluid equalization still
# runs every frame on the cached topology, so flow stays perfectly smooth;
# only the expensive partitioning is throttled.
#
# Invalidation is belt-and-suspenders: we set `_pipe_net_dirty` on the
# structural signals we can hook (place / destroy / build-complete), AND
# refresh on a low-frequency timer as a safety net for membership changes
# that don't fire a clean signal (faction flips → derelict, bridge-link
# toggles, bulk loads). Worst-case staleness is one `_PIPE_NET_REFRESH`
# window (~125 ms) — imperceptible for fluid, and flow never stops because
# equalization keeps running on whatever partition is current.
var _pipe_networks: Array = []        # Array of Array[Vector2i]
var _pipe_net_dirty := true
var _pipe_net_refresh_accum := 0.0
const _PIPE_NET_REFRESH := 1.0 / 8.0  # rebuild partition at most ~8 Hz

## Returns the cached cell list for `role`, rebuilding all buckets first if
## the cache is stale. The list contains every placed cell matching the
## role's predicate (anchors and non-anchor tiles of multi-tile blocks
## alike — same set the old `for grid_pos in placed_buildings` produced,
## so each loop body's existing anchor-dedup still applies unchanged).
func _bucket(role: String) -> Array:
	if _buckets_dirty or main.placed_buildings.size() != _buckets_count:
		_rebuild_buckets()
	return _buckets.get(role, [])


func _rebuild_buckets() -> void:
	_buckets_dirty = false
	_buckets_count = main.placed_buildings.size()
	var extractor: Array = []
	var pump: Array = []
	var pipe: Array = []
	var junction: Array = []
	var unloader: Array = []
	var constructor: Array = []
	var deconstructor: Array = []
	var refabricator: Array = []
	var payload_loader: Array = []
	var payload_unloader: Array = []
	var mass_driver: Array = []
	var factory: Array = []
	var upgrader: Array = []
	var refit_bay: Array = []
	var resource_source: Array = []
	var payload_source: Array = []
	for grid_pos in main.placed_buildings:
		var data = Registry.get_block(main.placed_buildings[grid_pos])
		if data == null:
			continue
		var tags = data.tags
		if data.category == BlockData.BlockCategory.EXTRACTORS:
			extractor.append(grid_pos)
		if tags.has("pump"):
			pump.append(grid_pos)
		if tags.has("unloader"):
			unloader.append(grid_pos)
		if tags.has("constructor"):
			constructor.append(grid_pos)
		if tags.has("deconstructor"):
			deconstructor.append(grid_pos)
		if tags.has("refabricator"):
			refabricator.append(grid_pos)
		if tags.has("payload_loader") or tags.has("freight_loader"):
			payload_loader.append(grid_pos)
		if tags.has("payload_unloader") or tags.has("freight_unloader"):
			payload_unloader.append(grid_pos)
		if tags.has("mass_driver"):
			mass_driver.append(grid_pos)
		if tags.has("upgrader"):
			upgrader.append(grid_pos)
		if tags.has("refit_bay"):
			refit_bay.append(grid_pos)
		if tags.has("resource_source"):
			resource_source.append(grid_pos)
		if tags.has("payload_source"):
			payload_source.append(grid_pos)
		if tags.has("junction"):
			junction.append(grid_pos)
		# Pipe cell — mirrors `_is_pipe_cell` exactly.
		if data.is_transport() and data.transports_fluid and not tags.has("pump"):
			pipe.append(grid_pos)
		# Factory — mirrors the structural pre-filter in `_update_factories`
		# (everything before the per-building anchor/disabled/inactive gates,
		# which stay in the loop body).
		if not tags.has("refabricator") \
				and data.category != BlockData.BlockCategory.EXTRACTORS \
				and not (data.side_inputs.is_empty() and data.side_outputs.is_empty() \
					and data.produced_unit == &"" and not tags.has("omnidirectional") \
					and data.output_sides.is_empty()):
			factory.append(grid_pos)
	_buckets = {
		"extractor": extractor,
		"pump": pump,
		"pipe": pipe,
		"junction": junction,
		"unloader": unloader,
		"constructor": constructor,
		"deconstructor": deconstructor,
		"refabricator": refabricator,
		"payload_loader": payload_loader,
		"payload_unloader": payload_unloader,
		"mass_driver": mass_driver,
		"factory": factory,
		"upgrader": upgrader,
		"refit_bay": refit_bay,
		"resource_source": resource_source,
		"payload_source": payload_source,
	}


# =========================
# FACTION HELPERS
# =========================

## Returns true if transferring items between these two cells would cross faction lines.
## Only blocks when BOTH cells have buildings (ground/empty cells are neutral).
func _is_cross_faction(from_pos: Vector2i, to_pos: Vector2i) -> bool:
	if not main.placed_buildings.has(from_pos) or not main.placed_buildings.has(to_pos):
		return false
	return main.get_building_faction(from_pos) != main.get_building_faction(to_pos)


# =========================
# DRILL LOGIC
# =========================

## Computes the efficiency this extractor *would* produce at `origin` if
## placed there with rotation `rot`. Used by the placement preview to
## show "Efficiency: NN%" before commit. Returns a value in [0, ~1.5];
## 1.0 = baseline. Returns 1.0 for blocks that aren't extractors.
func compute_extractor_preview_efficiency(origin: Vector2i, data: BlockData, rot: int) -> float:
	if data == null:
		return 1.0
	var terrain = _terrain_ref()
	if terrain == null:
		return 1.0
	var is_pump: bool = data.tags.has("pump")
	if is_pump:
		var max_depth: int = 0
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				var cell: Vector2i = origin + Vector2i(x, y)
				var lt = terrain.get_liquid_at(cell)
				if lt == null or lt.extracted_liquid == &"":
					continue
				if terrain.has_method("get_water_depth_at"):
					var d_here: int = int(terrain.get_water_depth_at(cell))
					if d_here > max_depth:
						max_depth = d_here
		if max_depth <= 0:
			return 0.0
		return float(max_depth) / 2.0
	if data.category != BlockData.BlockCategory.EXTRACTORS:
		return 1.0
	var is_wall_miner: bool = data.tags.has("wall_miner")
	var is_floor_miner: bool = data.tags.has("floor_miner")
	# Floor miners (ground scraper) read every cell of their FOOTPRINT —
	# not the front edge — because they strip topsoil straight down.
	# Each covered ore cell after the first adds +25% throughput, so a
	# 2×2 scraper sitting on four coal cells caps at 175%.
	if is_floor_miner:
		return _floor_miner_efficiency(origin, data.grid_size)
	var front_cells := _get_front_edge(origin, data.grid_size, rot)
	var dir: Vector2i
	match rot:
		0: dir = Vector2i(1, 0)
		1: dir = Vector2i(0, 1)
		2: dir = Vector2i(-1, 0)
		3: dir = Vector2i(0, -1)
		_: dir = Vector2i(1, 0)
	var front_count: int = front_cells.size()
	if front_count == 0:
		return 0.0
	# Each front cell counts as a "hit" if ANY tile within mine_range
	# beyond it has matching ore / blackstone — so a plasma bore can
	# reach ore up to `mine_range` tiles ahead and still register at
	# 100 %, not just at its adjacent tile.
	var max_extend: int = maxi(data.mine_range, 1)
	# Mirror `_update_drills`: per-wall efficiency multiplier (so the
	# preview tooltip reads the same number the runtime will produce).
	var accepted_walls_eff: Array = data.accepted_walls if data.accepted_walls.size() > 0 \
			else [&"blackstone_wall"]
	var eff_sum: float = 0.0
	for cell in front_cells:
		var hit_mult: float = 0.0
		if is_wall_miner:
			var hit_wall: StringName = &""
			var wid_e: StringName = StringName(terrain.wall_tiles.get(cell, &""))
			if terrain.get_ore_at(cell) == null and accepted_walls_eff.has(wid_e):
				hit_wall = wid_e
			else:
				for step in range(1, max_extend + 1):
					var scan: Vector2i = cell + dir * step
					var wid_s: StringName = StringName(terrain.wall_tiles.get(scan, &""))
					if terrain.get_ore_at(scan) == null and accepted_walls_eff.has(wid_s):
						hit_wall = wid_s
						break
			if hit_wall != &"":
				hit_mult = float(data.wall_efficiency.get(hit_wall, 1.0))
		else:
			if _ore_is_minable_by(terrain.get_ore_at(cell), is_floor_miner, data):
				hit_mult = 1.0
			else:
				for step in range(1, max_extend + 1):
					if _ore_is_minable_by(terrain.get_ore_at(cell + dir * step), is_floor_miner, data):
						hit_mult = 1.0
						break
		eff_sum += hit_mult
	return eff_sum / float(front_count)


## Counts how many cells of `origin`'s footprint have a floor-ore
## underneath, then converts to an efficiency multiplier:
##   0 covered → 0.0   (idle — nothing to scrape)
##   1 covered → 1.0   (baseline)
##   N covered → 1.0 + 0.25 × (N - 1)
## So each tile beyond the first contributes +25% throughput.
func _floor_miner_efficiency(origin: Vector2i, grid_size: Vector2i) -> float:
	var terrain = _terrain_ref()
	if terrain == null:
		return 0.0
	var covered: int = 0
	for x in range(grid_size.x):
		for y in range(grid_size.y):
			var cell: Vector2i = origin + Vector2i(x, y)
			var ore: TerrainTileData = terrain.get_ore_at(cell)
			if ore != null and ore.tags.has("floor_ore") and ore.minable_resource != &"":
				covered += 1
	if covered <= 0:
		return 0.0
	return 1.0 + 0.25 * float(covered - 1)


## Computes what an extractor / pump / condenser would output if placed
## here. Returns `{item_id, per_sec}`; `item_id` is empty + per_sec=0 if
## the block isn't an extractor or has nothing to mine. The per-second
## rate already factors in `efficiency` so the caller can render it
## directly without re-doing the math.
func compute_extractor_preview_output(origin: Vector2i, data: BlockData, rot: int) -> Dictionary:
	var blank := {"item_id": StringName(""), "per_sec": 0.0}
	if data == null:
		return blank
	var efficiency: float = compute_extractor_preview_efficiency(origin, data, rot)
	var terrain = _terrain_ref()
	# Pumps & condensers run their own per-tile lookup. Pump rate scales
	# with depth_mult (= efficiency) on PUMP_BASE_RATE_PER_SEC; condenser
	# rate is the geyser-or-vent base (8 / 4) scaled by efficiency, where
	# `efficiency` for condensers is geyser→1.0, vent→0.5.
	if data.tags.has("pump"):
		var fluid_id: StringName = &""
		if data.tags.has("condenser"):
			fluid_id = &"mat_water"
			# 8 = geyser baseline; vent reads as 0.5 efficiency → 4/s.
			# Vent turbine produces half of a dedicated condenser at
			# the same source.
			var rate_preview: float = 8.0 * efficiency
			if data.id == &"vent_turbine":
				rate_preview *= 0.5
			return {"item_id": fluid_id, "per_sec": rate_preview}
		if terrain:
			for x in range(data.grid_size.x):
				for y in range(data.grid_size.y):
					var lt = terrain.get_liquid_at(origin + Vector2i(x, y))
					if lt != null and lt.extracted_liquid != &"":
						fluid_id = lt.extracted_liquid
						break
				if fluid_id != &"":
					break
		if fluid_id == &"":
			return blank
		return {"item_id": fluid_id, "per_sec": PUMP_BASE_RATE_PER_SEC * efficiency}
	if data.category != BlockData.BlockCategory.EXTRACTORS:
		return blank
	# Production cycle length (seconds for the block to finish 1 cycle
	# at 100% efficiency). Drills produce 1 item per cycle of
	# ore.minable_resource; wall miners produce sum(output_items).
	var cycle: float = data.production_time if data.production_time > 0.0 else default_drill_time
	if cycle <= 0.0:
		cycle = 1.0
	var is_wall_miner: bool = data.tags.has("wall_miner")
	var is_floor_miner: bool = data.tags.has("floor_miner")
	if is_wall_miner:
		var first_id: StringName = &""
		var total_per_cycle: int = 0
		for raw_id in data.output_items:
			if first_id == &"":
				first_id = StringName(raw_id)
			total_per_cycle += int(data.output_items[raw_id])
		if first_id == &"" or total_per_cycle <= 0:
			return blank
		return {"item_id": first_id, "per_sec": float(total_per_cycle) * efficiency / cycle}
	# Regular drill / floor miner — sample one valid ore tile under the
	# scan window and report its minable_resource.
	if terrain == null:
		return blank
	var scan_cells: Array = []
	if is_floor_miner:
		for fx in range(data.grid_size.x):
			for fy in range(data.grid_size.y):
				scan_cells.append(origin + Vector2i(fx, fy))
	else:
		scan_cells = _get_extended_front_edge(origin, data.grid_size, rot, data.mine_range)
	for cell in scan_cells:
		var ore: TerrainTileData = terrain.get_ore_at(cell)
		if not _ore_is_minable_by(ore, is_floor_miner, data):
			continue
		if ore.minable_resource == &"":
			continue
		# Honor per-cycle output_items override (impact drill: 6/slam)
		# — defaults to 1 ore per cycle if the block doesn't specify.
		var per_cycle: int = 1
		if data.output_items.has(ore.minable_resource):
			per_cycle = int(data.output_items[ore.minable_resource])
		elif data.output_items.has(String(ore.minable_resource)):
			per_cycle = int(data.output_items[String(ore.minable_resource)])
		return {"item_id": ore.minable_resource, "per_sec": float(per_cycle) * efficiency / cycle}
	return blank


## True if this ore tile can be mined by a drill of the given type.
## Floor-miner drills (ground scrapers) only mine surface ores tagged
## "floor_ore"; regular drills only mine wall-embedded ores. Without
## this split, a coal patch in the dirt would be free pickings for any
## mechanical drill placed next to it.
func _ore_is_minable_by(ore_data: TerrainTileData, is_floor_miner: bool, data: BlockData = null) -> bool:
	if ore_data == null:
		return false
	var is_floor_ore: bool = ore_data.tags.has("floor_ore")
	if is_floor_miner:
		if not is_floor_ore:
			return false
	else:
		if is_floor_ore:
			return false
	# Whitelist: if the block specifies accepted_ores, the tile id
	# must be in it. Empty list = accept anything matching the
	# floor/wall split above.
	if data != null and data.accepted_ores.size() > 0:
		if not data.accepted_ores.has(ore_data.id):
			return false
	return true


func _update_drills(delta: float) -> void:
	var processed := {}

	for grid_pos in _bucket("extractor"):
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null:
			continue
		if data.category != BlockData.BlockCategory.EXTRACTORS:
			continue

		var origin = _find_drill_origin(grid_pos, data)
		if processed.has(origin):
			continue
		processed[origin] = true

		# Skip disabled or under-construction buildings
		var sector_script = _sector_script_ref()
		if sector_script and sector_script.is_building_disabled(origin):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue

		if not drill_timers.has(origin):
			var cycle_time = data.production_time if data.production_time > 0 else default_drill_time
			drill_timers[origin] = cycle_time

		var terrain = _terrain_ref()
		if terrain == null:
			continue

		var rot: int = main.building_rotation.get(origin, 0)
		var front_cells = _get_front_edge(origin, data.grid_size, rot)

		# Wall miners (wall_crusher) mine blackstone walls into their configured
		# output_items. Floor miners (ground scraper) mine surface ores tagged
		# "floor_ore". Regular drills mine wall-embedded ores via
		# ore.minable_resource. Each kind ignores ores that aren't theirs so a
		# mechanical drill can't snipe coal from a patch the scraper is
		# supposed to handle.
		var is_wall_miner: bool = data.tags.has("wall_miner")
		var is_floor_miner: bool = data.tags.has("floor_miner")
		var is_geyser_miner: bool = data.tags.has("geyser_miner")

		# Pick the right scan window. Wall/regular drills look at the
		# front edge + one tile beyond (they reach forward into ore
		# walls). Floor miners pull from straight under the footprint —
		# their target is a coal patch the block is sitting on, not
		# something it faces. Geyser miners ignore the scan window
		# entirely: the geyser tile they sit on IS their resource, so
		# they always extract their full output_items per cycle.
		var mine_cells: Array
		if is_floor_miner:
			mine_cells = []
			for fx in range(data.grid_size.x):
				for fy in range(data.grid_size.y):
					mine_cells.append(origin + Vector2i(fx, fy))
		else:
			mine_cells = _get_extended_front_edge(origin, data.grid_size, rot, data.mine_range)

		var ore: TerrainTileData = null
		var wall_found: bool = false
		var accepted_walls: Array = data.accepted_walls if data.accepted_walls.size() > 0 \
				else [&"blackstone_wall"]
		if is_geyser_miner:
			# Placement gate already guarantees we're centered on a
			# geyser tile; nothing to scan for. Skip ore/wall detection.
			pass
		elif is_wall_miner:
			for cell in mine_cells:
				if terrain.get_ore_at(cell) != null:
					continue
				var wid: StringName = StringName(terrain.wall_tiles.get(cell, &""))
				if wid == &"":
					continue
				if accepted_walls.has(wid):
					wall_found = true
					break
			if not wall_found:
				extractor_efficiency[origin] = 0.0
				continue
		else:
			for cell in mine_cells:
				var candidate: TerrainTileData = terrain.get_ore_at(cell)
				if not _ore_is_minable_by(candidate, is_floor_miner, data):
					continue
				if candidate.minable_resource == &"":
					continue
				ore = candidate
				break
			if ore == null:
				extractor_efficiency[origin] = 0.0
				continue

		# Calculate efficiency. Floor miners (ground scraper) read every
		# cell of their FOOTPRINT — not the front edge — and earn +25%
		# per extra ore tile under them on top of a 100% baseline. Wall
		# miners and standard drills keep the front-edge coverage
		# fraction (direct hit + one tile ahead).
		var efficiency: float = 1.0
		if is_geyser_miner:
			# Geyser tile = the resource; fixed 100 % output.
			efficiency = 1.0
		elif is_floor_miner:
			efficiency = _floor_miner_efficiency(origin, data.grid_size)
		else:
			var front_count: int = front_cells.size()
			var dir: Vector2i
			match rot:
				0: dir = Vector2i(1, 0)
				1: dir = Vector2i(0, 1)
				2: dir = Vector2i(-1, 0)
				3: dir = Vector2i(0, -1)
				_: dir = Vector2i(1, 0)
			# Each front cell counts as a hit if there's matching ore /
			# blackstone anywhere within mine_range beyond it — the
			# same range the actual mining loop uses, so a plasma bore
			# (mine_range=4) registers 100 % when ore is 4 tiles ahead.
			var max_extend: int = maxi(data.mine_range, 1)
			var accepted_walls_eff: Array = data.accepted_walls if data.accepted_walls.size() > 0 \
					else [&"blackstone_wall"]
			# Wall miners use a per-wall efficiency multiplier (so a
			# wall_crusher chews purple_wall at 0.75× vs blackstone's
			# 1.0×). Each front-cell's contribution is the matched
			# wall's multiplier (1.0 if unspecified), summed and
			# averaged. Ore drills stay binary 0/1 per cell.
			var eff_sum: float = 0.0
			for cell in front_cells:
				var hit_mult: float = 0.0
				if is_wall_miner:
					var hit_wall: StringName = &""
					var wid_e: StringName = StringName(terrain.wall_tiles.get(cell, &""))
					if terrain.get_ore_at(cell) == null and accepted_walls_eff.has(wid_e):
						hit_wall = wid_e
					else:
						for step in range(1, max_extend + 1):
							var scan: Vector2i = cell + dir * step
							var wid_s: StringName = StringName(terrain.wall_tiles.get(scan, &""))
							if terrain.get_ore_at(scan) == null and accepted_walls_eff.has(wid_s):
								hit_wall = wid_s
								break
					if hit_wall != &"":
						hit_mult = float(data.wall_efficiency.get(hit_wall, 1.0))
				else:
					if _ore_is_minable_by(terrain.get_ore_at(cell), is_floor_miner, data):
						hit_mult = 1.0
					else:
						for step in range(1, max_extend + 1):
							if _ore_is_minable_by(terrain.get_ore_at(cell + dir * step), is_floor_miner, data):
								hit_mult = 1.0
								break
				eff_sum += hit_mult
			efficiency = eff_sum / float(front_count) if front_count > 0 else 1.0
		extractor_efficiency[origin] = efficiency

		# Electrical power: scale production speed by the network's
		# efficiency. Over-drawn networks slow all consumers proportionally
		# (Mindustry-style) instead of hard-stopping at gen < use.
		var power_eff: float = 1.0
		if data.electrical_power_use > 0:
			var power_sys = _power_sys_ref()
			if power_sys:
				power_eff = power_sys.get_electrical_efficiency(origin)
			if power_eff <= 0.0:
				continue  # No generation at all — idle this tick.

		var od_mult: float = 1.0
		if main.has_method("get_overdrive_multiplier"):
			od_mult = main.get_overdrive_multiplier(origin)
		drill_timers[origin] -= delta * efficiency * power_eff * od_mult
		if drill_timers[origin] > 0:
			continue

		# Figure out which item(s) this cycle produces and how many of each.
		# Regular drills produce 1 × minable_resource by default, but
		# may override the per-cycle amount via output_items entry
		# keyed by that resource (e.g. impact drill: 6 × mat_zinc per
		# slam). Wall miners always use the full output_items dict.
		var produced: Dictionary = {}
		if is_wall_miner or is_geyser_miner:
			for raw_id in data.output_items:
				produced[StringName(raw_id)] = int(data.output_items[raw_id])
		else:
			var resource_key: StringName = ore.minable_resource
			var amount: int = 1
			if data.output_items.has(resource_key):
				amount = int(data.output_items[resource_key])
			elif data.output_items.has(String(resource_key)):
				amount = int(data.output_items[String(resource_key)])
			produced[resource_key] = amount

		# Don't produce if storage for any of these items is full — stall at 0.
		var any_full: bool = false
		for item_id in produced:
			if _is_storage_full_for(origin, data, item_id):
				any_full = true
				break
		if any_full:
			drill_timers[origin] = 0.0
			continue

		var cycle_time = data.production_time if data.production_time > 0 else default_drill_time
		drill_timers[origin] = cycle_time

		# `item_mined` is a tech-tree progression signal, not a general
		# "any drill fired" event — only the player's own drills count.
		# Pre-placed FEROX mining chains would otherwise unlock Copper/
		# Graphite/etc. the moment the sector loads, before the player
		# has mined anything themselves.
		var drill_is_lumina: bool = main.get_building_faction(origin) == main.Faction.LUMINA
		var output_cells = _get_all_output_cells(origin, data.grid_size, rot)
		for item_id in produced:
			var amount: int = int(produced[item_id])
			for _i in range(amount):
				var pushed := false
				for out_pos in output_cells:
					if _is_cross_faction(origin, out_pos):
						continue
					var push_entry_dir := _get_entry_dir_from_building(out_pos, origin, data.grid_size)
					if _try_push_item(out_pos, item_id, push_entry_dir):
						pushed = true
						if drill_is_lumina and main.has_signal("item_mined"):
							main.item_mined.emit(item_id)
						break
				if not pushed:
					if _add_to_storage(origin, item_id, data):
						if drill_is_lumina and main.has_signal("item_mined"):
							main.item_mined.emit(item_id)

## Finds the top-left origin cell of a multi-tile building.
## For 1x1 buildings, just returns grid_pos.
func _find_drill_origin(grid_pos: Vector2i, data: BlockData) -> Vector2i:
	if data.grid_size == Vector2i(1, 1):
		return grid_pos
	# Try each possible offset — grid_pos could be any cell of the building
	for ox in range(data.grid_size.x):
		for oy in range(data.grid_size.y):
			var candidate = grid_pos - Vector2i(ox, oy)
			var valid = true
			for dx in range(data.grid_size.x):
				for dy in range(data.grid_size.y):
					if main.placed_buildings.get(candidate + Vector2i(dx, dy), &"") != data.id:
						valid = false
						break
				if not valid:
					break
			if valid:
				return candidate
	return grid_pos

## Returns all cells just outside the front edge of a building.
func _get_front_edge(origin: Vector2i, grid_size: Vector2i, rotation: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	match rotation:
		0: # right
			for y in range(grid_size.y):
				cells.append(Vector2i(origin.x + grid_size.x, origin.y + y))
		1: # down
			for x in range(grid_size.x):
				cells.append(Vector2i(origin.x + x, origin.y + grid_size.y))
		2: # left
			for y in range(grid_size.y):
				cells.append(Vector2i(origin.x - 1, origin.y + y))
		3: # up
			for x in range(grid_size.x):
				cells.append(Vector2i(origin.x + x, origin.y - 1))
	return cells


## Returns the front edge cells PLUS `extend` tiles further ahead (for
## extended drill range). `extend = 1` matches the original
## mechanical-drill behaviour; plasma bores pass higher values to reach
## deeper into ore walls.
func _get_extended_front_edge(origin: Vector2i, grid_size: Vector2i, rotation: int, extend: int = 1) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var dir: Vector2i
	match rotation:
		0: dir = Vector2i(1, 0)
		1: dir = Vector2i(0, 1)
		2: dir = Vector2i(-1, 0)
		3: dir = Vector2i(0, -1)
		_: dir = Vector2i(1, 0)
	var front := _get_front_edge(origin, grid_size, rotation)
	for cell in front:
		if not cells.has(cell):
			cells.append(cell)
		for step in range(1, max(extend, 0) + 1):
			var extended := cell + dir * step
			if not cells.has(extended):
				cells.append(extended)
	return cells


## Returns all cells around the building's perimeter EXCEPT the front edge.
## These are valid output positions for mined items.
func _get_all_output_cells(origin: Vector2i, grid_size: Vector2i, rotation: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	# Top edge (y = origin.y - 1)
	if rotation != 3:
		for x in range(grid_size.x):
			cells.append(Vector2i(origin.x + x, origin.y - 1))
	# Bottom edge (y = origin.y + grid_size.y)
	if rotation != 1:
		for x in range(grid_size.x):
			cells.append(Vector2i(origin.x + x, origin.y + grid_size.y))
	# Left edge (x = origin.x - 1)
	if rotation != 2:
		for y in range(grid_size.y):
			cells.append(Vector2i(origin.x - 1, origin.y + y))
	# Right edge (x = origin.x + grid_size.x)
	if rotation != 0:
		for y in range(grid_size.y):
			cells.append(Vector2i(origin.x + grid_size.x, origin.y + y))
	return cells


## Like _get_all_output_cells but always returns the full ring of cells
## around a building footprint, regardless of rotation. Used for
## omnidirectional factories that push on every side.
func _get_full_ring(origin: Vector2i, grid_size: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for x in range(grid_size.x):
		cells.append(Vector2i(origin.x + x, origin.y - 1))
		cells.append(Vector2i(origin.x + x, origin.y + grid_size.y))
	for y in range(grid_size.y):
		cells.append(Vector2i(origin.x - 1, origin.y + y))
		cells.append(Vector2i(origin.x + grid_size.x, origin.y + y))
	return cells


## Cells immediately adjacent to ONE world side of a building footprint.
## world_dir: 0=right, 1=down, 2=left, 3=up. Used for per-output directional
## routing on omnidirectional factories (output_sides).
func _side_neighbor_cells(origin: Vector2i, grid_size: Vector2i, world_dir: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	match world_dir:
		3:  # up
			for x in range(grid_size.x):
				cells.append(Vector2i(origin.x + x, origin.y - 1))
		1:  # down
			for x in range(grid_size.x):
				cells.append(Vector2i(origin.x + x, origin.y + grid_size.y))
		2:  # left
			for y in range(grid_size.y):
				cells.append(Vector2i(origin.x - 1, origin.y + y))
		0:  # right
			for y in range(grid_size.y):
				cells.append(Vector2i(origin.x + grid_size.x, origin.y + y))
	return cells


## Determines which direction an item enters an output cell from, based on
## which edge of the building footprint it's on.
func _get_entry_dir_from_building(out_pos: Vector2i, origin: Vector2i, grid_size: Vector2i) -> int:
	if out_pos.y < origin.y:
		return 1   # Output above building → item enters from south (down)
	elif out_pos.y >= origin.y + grid_size.y:
		return 3   # Output below building → item enters from north (up)
	elif out_pos.x < origin.x:
		return 0   # Output left of building → item enters from east (right)
	else:
		return 2   # Output right of building → item enters from west (left)


# =========================
# FLUID PUMP LOGIC
# =========================

## Pumps now produce continuously (instead of one big batch per cycle).
## The output rate per second is:
##   rate = PUMP_BASE_RATE_PER_SEC × (water_depth / 2.0) × power_efficiency
## Shallower water (depth 1) → half rate, medium (2) → full rate, deep
## (3) → 1.5×. Power efficiency comes from PowerSystem so a brownout
## slows the pump linearly the same way drills / factories do.
const PUMP_BASE_RATE_PER_SEC: float = 12.5
func _update_pumps(delta: float) -> void:
	var processed_pumps := {}
	var terrain = _terrain_ref()
	if terrain == null:
		return
	var sector_script = _sector_script_ref()
	var power_sys = _power_sys_ref()

	for grid_pos in _bucket("pump"):
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null:
			continue
		if not data.tags.has("pump"):
			continue

		# For multi-tile pumps, only process the anchor once
		var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if processed_pumps.has(anchor):
			continue
		processed_pumps[anchor] = true

		# Skip disabled or under-construction buildings
		if sector_script and sector_script.is_building_disabled(anchor):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
			continue

		# Condenser branch: rate is determined by the steam source under
		# the footprint (vent → 4 water/s, geyser → 8 water/s) instead
		# of the standard pump's water-depth math.
		var is_condenser: bool = data.tags.has("condenser")
		var fluid_id: StringName = &""
		var rate_per_sec: float = 0.0
		if is_condenser and data.vent_fluid != &"":
			# Data-driven vent extractor (e.g. Fume Extractor on a sulfur vent):
			# produces `vent_fluid` while any footprint cell sits on `vent_tile`,
			# at `vent_rate`. Generalises the built-in water condenser below.
			var on_vent_tile := false
			for x in range(data.grid_size.x):
				for y in range(data.grid_size.y):
					var cp_v: Vector2i = anchor + Vector2i(x, y)
					if StringName(terrain.floor_tiles.get(cp_v, &"")) == data.vent_tile:
						on_vent_tile = true
			if not on_vent_tile:
				extractor_efficiency[anchor] = 0.0
				continue
			fluid_id = data.vent_fluid
			rate_per_sec = data.vent_rate if data.vent_rate > 0.0 else 4.0
			extractor_efficiency[anchor] = 1.0
		elif is_condenser:
			var on_geyser := false
			var on_vent := false
			for x in range(data.grid_size.x):
				for y in range(data.grid_size.y):
					var cp: Vector2i = anchor + Vector2i(x, y)
					var ftid: StringName = StringName(terrain.floor_tiles.get(cp, &""))
					if ftid == &"geyser":
						on_geyser = true
					elif ftid == &"vent":
						on_vent = true
			if not (on_vent or on_geyser):
				extractor_efficiency[anchor] = 0.0
				continue
			fluid_id = &"mat_water"
			# Geyser wins on tie — a footprint that touches both is rare
			# but the higher-yield source is the one the player placed
			# the condenser FOR.
			rate_per_sec = 8.0 if on_geyser else 4.0
			# Vent turbine condenses water as a byproduct of its main
			# job (power gen). Half the throughput of a dedicated
			# condenser at the same source.
			if data.id == &"vent_turbine":
				rate_per_sec *= 0.5
			# Efficiency overlay shows 100% on a geyser (max), 50% on a
			# vent (half) so the live indicator matches the pump's
			# normalized scale.
			extractor_efficiency[anchor] = rate_per_sec / 8.0
		else:
			# Check for liquid underneath any tile of the pump and pick the
			# DEEPEST tile beneath the footprint — pumps with one tile in
			# shallows and another in deep water output at the deep rate.
			var liquid_tile: Variant = null
			var max_depth: int = 0
			for x in range(data.grid_size.x):
				for y in range(data.grid_size.y):
					var check_pos: Vector2i = anchor + Vector2i(x, y)
					var lt = terrain.get_liquid_at(check_pos)
					if lt != null and lt.extracted_liquid != &"":
						if liquid_tile == null:
							liquid_tile = lt
						if terrain.has_method("get_water_depth_at"):
							var d_here: int = int(terrain.get_water_depth_at(check_pos))
							if d_here > max_depth:
								max_depth = d_here

			if liquid_tile == null or liquid_tile.extracted_liquid == &"":
				extractor_efficiency[anchor] = 0.0
				continue

			# A floor tile with `is_liquid` but no depth reading (e.g. lava
			# or a custom tile with no BFS depth entry) defaults to medium
			# depth so it still produces something.
			if max_depth <= 0:
				max_depth = 2

			fluid_id = liquid_tile.extracted_liquid
			var depth_mult: float = float(max_depth) / 2.0
			extractor_efficiency[anchor] = depth_mult
			rate_per_sec = PUMP_BASE_RATE_PER_SEC * depth_mult

		# Power efficiency (shared between condensers and standard pumps).
		var net_eff: float = 1.0
		if power_sys and power_sys.has_method("get_electrical_efficiency"):
			net_eff = clampf(float(power_sys.get_electrical_efficiency(anchor)), 0.0, 1.0)

		# Drain any previously-accumulated stored fluid into adjacent
		# pipes BEFORE the storage-full short-circuit below. Without
		# this, fluid that fell into the pump's own buffer (because no
		# pipe was downstream at the time) gets stranded forever: the
		# storage-full check skips the entire push branch and the
		# stored fluid never moves. Symptom: pump → pipe → destroy
		# pipe → place new pipe → new pipe never receives water.
		_drain_pump_storage_to_pipes(anchor, data, delta)

		# Don't waste production into a full storage.
		if _is_storage_full(anchor, data):
			continue

		var pump_od: float = 1.0
		if main.has_method("get_overdrive_multiplier"):
			pump_od = main.get_overdrive_multiplier(anchor)
		var amount: float = rate_per_sec * net_eff * pump_od * delta
		if amount <= 0.0:
			continue
		var pushed_any := false
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				var tile: Vector2i = anchor + Vector2i(x, y)
				for dir in range(4):
					var neighbor: Vector2i = tile + DIR_VECTORS[dir]
					if main.building_origins.get(neighbor, neighbor) == anchor:
						continue
					if _is_cross_faction(tile, neighbor):
						continue
					if not _is_pipe_cell(neighbor):
						continue
					if _add_fluid_to_pipe(neighbor, fluid_id, amount, dir):
						pushed_any = true
					if pushed_any:
						break
				if pushed_any:
					break
			if pushed_any:
				break
		# If no pipe was available, accumulate into the pump's own
		# fluid storage so the production doesn't just evaporate.
		if not pushed_any:
			_add_to_storage(anchor, fluid_id, data)


## Empties whatever fluid is already in a pump's block_storage into
## adjacent pipes, one fluid at a time. Called at the top of each pump
## tick so a pump that filled up its own buffer when no pipe was
## downstream will re-feed the network the moment a pipe is placed.
##
## The drain rate is the pump's base rate (×2 so a backlog drains a
## little faster than it filled) per delta — same order of magnitude
## as the production push, so the network sees continuous flow rather
## than a one-shot dump.
func _drain_pump_storage_to_pipes(anchor: Vector2i, data: BlockData, delta: float) -> void:
	if not block_storage.has(anchor):
		return
	var storage: Dictionary = block_storage[anchor]
	var fluids: Dictionary = storage.get("fluids", {})
	if fluids.is_empty():
		return
	var max_drain: float = PUMP_BASE_RATE_PER_SEC * delta * 2.0
	if max_drain <= 0.0:
		return
	var dirty := false
	for fluid_id in fluids.keys():
		var available: float = float(fluids[fluid_id])
		if available <= 0.0:
			continue
		var to_drain: float = minf(max_drain, available)
		var pushed := false
		for x in range(data.grid_size.x):
			if pushed:
				break
			for y in range(data.grid_size.y):
				if pushed:
					break
				var tile: Vector2i = anchor + Vector2i(x, y)
				for dir in range(4):
					var neighbor: Vector2i = tile + DIR_VECTORS[dir]
					# Skip cells inside the pump's own footprint.
					if main.building_origins.get(neighbor, neighbor) == anchor:
						continue
					if _is_cross_faction(tile, neighbor):
						continue
					if not _is_pipe_cell(neighbor):
						continue
					if _add_fluid_to_pipe(neighbor, fluid_id, to_drain, dir):
						available = maxf(0.0, available - to_drain)
						pushed = true
						dirty = true
						break
		if available <= 0.0:
			fluids.erase(fluid_id)
		else:
			fluids[fluid_id] = available
	if dirty:
		storage["fluids"] = fluids
		block_storage[anchor] = storage


## Attempts to place an item or fluid onto a cell.
## Fluids are routed to pipes; items are routed to conveyors.
## entry_dir: direction the item entered from (0-3), or -1 for default (behind belt).
## Returns true if the item was successfully placed.
func _try_push_item(grid_pos: Vector2i, item_id: StringName, entry_dir: int = -1) -> bool:
	# Can't push items onto buildings under construction
	if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
		return false
	# Incinerator: destroys any item or fluid pushed in, as long as the
	# network can cover its 5-power draw. With power down, items back
	# up on the belt (return false) instead of vanishing for free.
	if _is_incinerator_cell(grid_pos):
		var power_sys_inc = _power_sys_ref()
		var inc_anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if power_sys_inc and power_sys_inc.get_electrical_efficiency(inc_anchor) <= 0.0:
			return false
		return true
	# Direct deposit into the core — reject if storage full (backs up conveyor)
	if _is_core_cell(grid_pos):
		return _absorb_item(item_id, grid_pos)

	# Check if this is a fluid
	var is_fluid: bool = Registry.get_fluid(item_id) != null

	if is_fluid:
		# Route fluid to pipe
		if _is_pipe_cell(grid_pos):
			return _add_fluid_to_pipe(grid_pos, item_id, PIPE_PUSH_AMOUNT)
	else:
		# Route item to conveyor
		if _is_conveyor_cell(grid_pos) and not conveyor_items.has(grid_pos):
			conveyor_items[grid_pos] = {
				"item_id": item_id,
				"progress": 0.0,
				"entry_dir": entry_dir,
			}
			return true

	# Accept into factory input side (works for both items and fluids)
	if entry_dir >= 0 and _try_accept_factory_item(grid_pos, item_id, entry_dir):
		return true

	# Accept into constructor (any side, no direction restriction)
	if _try_accept_constructor_item(grid_pos, item_id):
		return true

	# Accept into turret as ammo (any side, no direction restriction)
	if _try_accept_turret_ammo(grid_pos, item_id):
		return true

	# Accept into a "storage"-tagged container (e.g. small_container)
	# from any side — same conveyor-fed semantics as factory inputs,
	# but it just stockpiles into the block's internal storage. Lets
	# players fill containers directly off a belt instead of needing
	# a payload loader.
	if _try_accept_storage_block(grid_pos, item_id):
		return true

	return false


## Routes a conveyor-fed item into a storage-tagged block's internal
## storage, respecting the block's `max_stored_items` cap. Returns true
## on success so the conveyor consumes the item.
func _try_accept_storage_block(grid_pos: Vector2i, item_id: StringName) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var data = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if data == null or not data.tags.has("storage"):
		return false
	if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
		return false
	# Items only — fluids would need a fluid-storage container variant
	# and a different cap field.
	if Registry.get_fluid(item_id) != null:
		return false
	return _add_to_storage(anchor, item_id, data)


# =========================
# CONVEYOR LOGIC
# =========================

func _update_conveyors(delta: float) -> void:
	# --- PHASE 1: TRANSFER ---
	# Try to move items that have reached the end of their cell.
	# We may need multiple passes because transferring one item
	# can free up space for the item behind it. 2 passes is enough
	# for smooth flow in practice.
	for _pass in range(2):
		var cells_with_full_items = []
		for grid_pos in conveyor_items:
			if conveyor_items[grid_pos]["progress"] >= 1.0:
				cells_with_full_items.append(grid_pos)

		for grid_pos in cells_with_full_items:
			if not conveyor_items.has(grid_pos):
				continue  # Already transferred by a previous iteration

			# Items sitting on an in-progress / derelict / actively-
			# decommissioning transport cell don't move. A belt that's
			# only QUEUED for deconstruction (drone hasn't started yet)
			# keeps conveying — the items still get a chance to clear
			# before the belt actually disappears.
			if main.has_method("is_belt_conveyance_blocked") and main.is_belt_conveyance_blocked(grid_pos):
				continue

			var item = conveyor_items[grid_pos]

			# --- BRIDGE: teleport to linked output bridge ---
			if _is_bridge_cell(grid_pos):
				if _is_bridge_input(grid_pos):
					if _try_bridge_transfer(grid_pos, item):
						conveyor_items.erase(grid_pos)
					continue
				# Output bridge: fall through to normal conveyor transfer below

			# --- JUNCTION: pass straight through (handled per-axis) ---
			if _is_junction_cell(grid_pos):
				if _try_junction_transfer(grid_pos, item):
					conveyor_items.erase(grid_pos)
				continue

			# --- SORTER: match→front, else→sides ---
			if _is_sorter_cell(grid_pos):
				if _try_sorter_transfer(grid_pos, item, false):
					conveyor_items.erase(grid_pos)
				continue

			# --- INVERTED SORTER: match→sides, else→front ---
			if _is_inverted_sorter_cell(grid_pos):
				if _try_sorter_transfer(grid_pos, item, true):
					conveyor_items.erase(grid_pos)
				continue

			# --- OVERFLOW: front first, then sides ---
			if _is_overflow_cell(grid_pos):
				if _try_overflow_transfer(grid_pos, item):
					conveyor_items.erase(grid_pos)
				continue

			# --- UNDERFLOW: sides first, then front ---
			if _is_underflow_cell(grid_pos):
				if _try_underflow_transfer(grid_pos, item):
					conveyor_items.erase(grid_pos)
				continue

			# --- ROUTER: distribute to 3 output directions (round-robin) ---
			if _is_router_cell(grid_pos):
				# Use pre-decided exit direction if available
				var exit_dir: int = item.get("exit_dir", -1)
				if exit_dir >= 0:
					var next_pos: Vector2i = grid_pos + DIR_VECTORS[exit_dir]
					var entry_dir: int = (exit_dir + 2) % 4
					if not _is_cross_faction(grid_pos, next_pos) and _try_transfer_item(next_pos, item["item_id"], entry_dir):
						conveyor_items.erase(grid_pos)
					else:
						# Pre-decided path blocked. Try the other outputs; if any
						# succeeds, transfer. If ALL blocked, leave exit_dir intact
						# so the item visually stalls at the chosen exit instead
						# of flicking through all 3 edges every frame.
						if _try_router_transfer(grid_pos, item):
							conveyor_items.erase(grid_pos)
				else:
					if _try_router_transfer(grid_pos, item):
						conveyor_items.erase(grid_pos)
				continue

			# --- Normal conveyor: push forward ---
			var drilRotation = main.building_rotation.get(grid_pos, 0)
			var next_pos = grid_pos + DIR_VECTORS[drilRotation]
			var entry_dir = (drilRotation + 2) % 4  # Item enters from opposite of sender's facing

			# Block cross-faction transfers
			if _is_cross_faction(grid_pos, next_pos):
				continue

			if _try_transfer_item(next_pos, item["item_id"], entry_dir):
				conveyor_items.erase(grid_pos)
				continue
			# No side-dump fallback: a belt only delivers to the cell it's
			# facing. Without this, a belt running E-W next to a factory to
			# its north would silently feed it whenever its forward push
			# stalled — items shouldn't leak into blocks the belt isn't
			# pointed at. If the player wants the perpendicular block fed,
			# they need to route a belt that actually faces it.

		# --- Junction perpendicular-axis items ---
		var junction_full = []
		for grid_pos in junction_items:
			if junction_items[grid_pos]["progress"] >= 1.0:
				junction_full.append(grid_pos)
		for grid_pos in junction_full:
			if not junction_items.has(grid_pos):
				continue
			var item = junction_items[grid_pos]
			if _try_junction_transfer(grid_pos, item):
				junction_items.erase(grid_pos)

	# --- PHASE 2: ADVANCE ---
	# Move all items forward along their conveyor cell.
	# Each conveyor uses its own transport_speed from BlockData.
	# Items on inactive (under-construction/derelict/decon) cells hold their
	# progress — they literally don't slide this frame. Belts that are
	# only queued (not actively decommissioning) keep advancing items.
	for grid_pos in conveyor_items:
		if main.has_method("is_belt_conveyance_blocked") and main.is_belt_conveyance_blocked(grid_pos):
			continue
		var item = conveyor_items[grid_pos]
		if item["progress"] < 1.0:
			var speed := conveyor_speed
			var block_id = main.placed_buildings.get(grid_pos, &"")
			if block_id != &"":
				var data = Registry.get_block(block_id)
				if data != null and data.transport_speed > 0:
					speed = data.transport_speed
			item["progress"] = minf(item["progress"] + speed * delta, 1.0)

	# Pre-decide exit direction for router items so they animate correctly.
	# Items keep their cached exit_dir as long as that direction still has
	# an accepting destination — but if the chosen output gets blocked
	# while the item is still traversing the router AND a different
	# output is now valid, we re-pick so the animation matches where the
	# item is actually going to end up. A fully-blocked router still
	# keeps its current exit_dir so a stalled item doesn't visually
	# flicker between edges.
	for grid_pos in conveyor_items:
		if main.has_method("is_belt_conveyance_blocked") and main.is_belt_conveyance_blocked(grid_pos):
			continue
		if not _is_router_cell(grid_pos):
			continue
		var item = conveyor_items[grid_pos]
		var current_exit: int = item.get("exit_dir", -1)
		if current_exit >= 0 and _router_exit_accepts(grid_pos, current_exit, item["item_id"]):
			continue
		var picked: int = _pick_router_exit(grid_pos, item)
		if picked < 0:
			continue
		# Only overwrite a previously chosen exit when the new direction is
		# *actually* accepting. Otherwise the picker's fallback (rr_start
		# when all blocked) would silently flip the animation while still
		# being unable to deliver — leaving the item to oscillate between
		# edges every frame.
		if current_exit < 0:
			item["exit_dir"] = picked
		elif _router_exit_accepts(grid_pos, picked, item["item_id"]):
			item["exit_dir"] = picked

	# Pre-decide exit direction for overflow / underflow items so they animate
	# toward the face they'll actually leave by — front-first for overflow,
	# sides-first for underflow, mirroring their transfer priority. Recomputed
	# each tick by priority; if nothing accepts, the last choice is kept so a
	# stalled item holds instead of flickering.
	for grid_pos in conveyor_items:
		if main.has_method("is_belt_conveyance_blocked") and main.is_belt_conveyance_blocked(grid_pos):
			continue
		var is_of: bool = _is_overflow_cell(grid_pos)
		var is_uf: bool = _is_underflow_cell(grid_pos)
		if not is_of and not is_uf:
			continue
		var of_item = conveyor_items[grid_pos]
		var of_rot: int = main.building_rotation.get(grid_pos, 0)
		var of_front: int = of_rot
		var of_left: int = (of_rot + 3) % 4
		var of_right: int = (of_rot + 1) % 4
		var of_prio: Array = [of_front, of_left, of_right] if is_of else [of_left, of_right, of_front]
		for d in of_prio:
			if _router_exit_accepts(grid_pos, d, of_item["item_id"]):
				of_item["exit_dir"] = d
				break

	# Advance junction perpendicular-axis items too
	for grid_pos in junction_items:
		if main.has_method("is_belt_conveyance_blocked") and main.is_belt_conveyance_blocked(grid_pos):
			continue
		var item = junction_items[grid_pos]
		if item["progress"] < 1.0:
			var speed := conveyor_speed
			var block_id = main.placed_buildings.get(grid_pos, &"")
			if block_id != &"":
				var data = Registry.get_block(block_id)
				if data != null and data.transport_speed > 0:
					speed = data.transport_speed
			item["progress"] = minf(item["progress"] + speed * delta, 1.0)


## Tries to move an item into the destination cell.
## Fluids are routed to pipes; items to conveyors.
## entry_dir: direction the item entered from (0-3), or -1 for default.
func _try_transfer_item(to: Vector2i, item_id: StringName, entry_dir: int = -1) -> bool:
	# Reject transfers into any block that isn't fully built (under
	# construction, deconstructing, or derelict). Items just pile up on the
	# upstream belt until the destination finishes construction. The core
	# itself is always active so it's allowed to absorb even if is_building_inactive
	# would otherwise return true for a derelict variant.
	if not _is_core_cell(to) and main.has_method("is_building_inactive") and main.is_building_inactive(to):
		return false

	# Incinerator: destroys items / fluids on input as long as it has
	# power. With power down, the item bounces back upstream.
	if _is_incinerator_cell(to):
		var power_sys_inc2 = _power_sys_ref()
		var inc_anchor2: Vector2i = main.building_origins.get(to, to)
		if power_sys_inc2 and power_sys_inc2.get_electrical_efficiency(inc_anchor2) <= 0.0:
			return false
		return true

	# Core absorbs if not full — reject if storage full (item stays on belt)
	if _is_core_cell(to):
		return _absorb_item(item_id, to)

	# Check if this is a fluid
	var is_fluid: bool = Registry.get_fluid(item_id) != null

	if is_fluid:
		# Route fluid to pipe
		if _is_pipe_cell(to):
			return _add_fluid_to_pipe(to, item_id, PIPE_PUSH_AMOUNT)
	else:
		# Junction: route to correct slot based on entry axis. Refuse to
		# accept anything if the cell on the FAR side (the exit) has no
		# placed building — items would otherwise queue forever inside a
		# junction whose output spills onto bare terrain. They stay on the
		# upstream belt until something exists for the junction to feed.
		if _is_junction_cell(to) and entry_dir >= 0:
			var exit_dir: int = (entry_dir + 2) % 4
			var exit_pos: Vector2i = to + DIR_VECTORS[exit_dir]
			if not main.placed_buildings.has(exit_pos):
				return false
			if _is_junction_primary_axis(to, entry_dir):
				if not conveyor_items.has(to):
					conveyor_items[to] = {
						"item_id": item_id,
						"progress": 1.0,
						"entry_dir": entry_dir,
					}
					return true
			else:
				if not junction_items.has(to):
					junction_items[to] = {
						"item_id": item_id,
						"progress": 1.0,
						"entry_dir": entry_dir,
					}
					return true
			return false

		# Special blocks: items pass through instantly (no visual sliding)
		# Overflow / underflow are NOT instant — they animate the item across the
		# cell like a router (exit_dir is pre-decided for the draw below).
		var _is_instant := (_is_sorter_cell(to)
			or _is_inverted_sorter_cell(to) or _is_bridge_cell(to))

		# Routers only accept items entering from their BACK side (the
		# direction opposite the rotation arrow). Items hitting any other
		# face are rejected and stay on the upstream belt — every other
		# face is reserved for output. entry_dir < 0 means "unknown source"
		# (drone deposits etc.), which we still let through.
		if _is_router_cell(to) and entry_dir >= 0:
			var router_rot: int = main.building_rotation.get(to, 0)
			if entry_dir != (router_rot + 2) % 4:
				return false

		# Route item to conveyor
		if _is_conveyor_cell(to) and not conveyor_items.has(to):
			conveyor_items[to] = {
				"item_id": item_id,
				"progress": 1.0 if _is_instant else 0.0,
				"entry_dir": entry_dir,
			}
			return true

	# Factory accepts on input side (works for both items and fluids)
	if entry_dir >= 0 and _try_accept_factory_item(to, item_id, entry_dir):
		return true

	# Constructor accepts items from any side
	if _try_accept_constructor_item(to, item_id):
		return true

	# Turret accepts matching ammo from any side
	if _try_accept_turret_ammo(to, item_id):
		return true

	# Storage container accepts any non-fluid item from any side
	# (small_container et al). Same fallback the drill / drone push
	# path uses; without this, items riding a conveyor INTO the
	# container's footprint never get consumed by the container.
	if _try_accept_storage_block(to, item_id):
		return true

	return false


## Handles router item distribution: tries to push the item to 3 output
## directions (all except the entry direction), using round-robin so items
## spread evenly across outputs — just like Mindustry routers.
func _try_router_transfer(grid_pos: Vector2i, item: Dictionary) -> bool:
	# Routers reserve their BACK face for input only — outputs are the
	# other three sides regardless of which face the item entered from.
	var rot: int = main.building_rotation.get(grid_pos, 0)
	var exclude_dir: int = (rot + 2) % 4

	var outputs: Array[int] = []
	for dir_idx in range(4):
		if dir_idx != exclude_dir:
			outputs.append(dir_idx)

	# Initialize round-robin index if needed
	if not router_output_index.has(grid_pos):
		router_output_index[grid_pos] = 0

	# Honour the cached exit_dir the picker pass committed to. If it's
	# set, we ONLY try that direction — falling back to a round-robin
	# scan when the cached side is blocked would silently ship the
	# item out a different side than the one the animation has been
	# showing. If the cached side is blocked, return false and let
	# the item stall; the next picker pass will re-commit `exit_dir`
	# to whichever side is accepting now.
	var cached_exit: int = item.get("exit_dir", -1)
	if cached_exit >= 0 and cached_exit != exclude_dir \
			and not _is_cross_faction(grid_pos, grid_pos + DIR_VECTORS[cached_exit]):
		var cached_pos: Vector2i = grid_pos + DIR_VECTORS[cached_exit]
		var cached_entry: int = (cached_exit + 2) % 4
		if _try_transfer_item(cached_pos, item["item_id"], cached_entry):
			var ci: int = outputs.find(cached_exit)
			if ci >= 0:
				router_output_index[grid_pos] = (ci + 1) % outputs.size()
			return true
		return false

	var rr_start: int = router_output_index[grid_pos] % outputs.size()

	# No cached exit (fresh arrival picker hasn't reached yet) — round-
	# robin scan. Stamp the winning direction onto `item.exit_dir` so the
	# animation matches even on this first frame.
	for attempt in range(outputs.size()):
		var idx: int = (rr_start + attempt) % outputs.size()
		var out_dir: int = outputs[idx]
		var next_pos: Vector2i = grid_pos + DIR_VECTORS[out_dir]
		var entry_dir: int = (out_dir + 2) % 4  # Item enters from opposite side

		# Block cross-faction transfers
		if _is_cross_faction(grid_pos, next_pos):
			continue

		if _try_transfer_item(next_pos, item["item_id"], entry_dir):
			item["exit_dir"] = out_dir
			router_output_index[grid_pos] = (idx + 1) % outputs.size()
			return true

	return false


## Non-mutating "will this block accept this item?" check. Used by the
## router picker so it only locks an exit direction onto adjacent buildings
## that can actually take the item — walls, incompatible factory sides,
## and full storage inputs all return false and the picker looks elsewhere.
func _could_block_accept_item(grid_pos: Vector2i, item_id: StringName, entry_dir: int) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null:
		return false

	# Core — absorbs items into the resource pool. This is the non-mutating
	# mirror of `_absorb_item`: FEROX cores always take; LUMINA cores take while
	# under their storage cap. Without this branch the router picker thought the
	# core could NEVER accept, so it never routed there (items piled toward a
	# full belt instead of the core that had room).
	if _is_core_cell(grid_pos):
		if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
			return false
		if main.get_building_faction(grid_pos) == main.Faction.FEROX:
			return true
		if main.has_method("can_accept_resource"):
			return main.can_accept_resource(item_id)
		return true

	# Launchpad — accepts any item into passenger storage, capped by
	# max_stored_items. The pod's build cost is now power-only, so the
	# launchpad no longer special-cases mandatory items.
	if data.tags.has("launchpad"):
		var lp_anchor = main.get_building_anchor(grid_pos)
		var lp_origin: Vector2i = lp_anchor if lp_anchor != null else grid_pos
		var storage_lp: Dictionary = block_storage.get(lp_origin, {})
		var items_lp: Dictionary = storage_lp.get("items", {})
		var total_lp: int = 0
		for k in items_lp:
			total_lp += int(items_lp[k])
		var cap_lp: int = data.max_stored_items if data.max_stored_items > 0 else 200
		return total_lp < cap_lp

	# Nuclear reactor — accepts uranium / graphite rods on any side as
	# long as the merged item bucket isn't full.
	if data.tags.has("nuclear_reactor"):
		if item_id != &"mat_uranium_rod" and item_id != &"mat_graphite_rod":
			return false
		var nuc_anchor = main.get_building_anchor(grid_pos)
		var nuc_origin: Vector2i = nuc_anchor if nuc_anchor != null else grid_pos
		var storage_n: Dictionary = block_storage.get(nuc_origin, {})
		var items_n: Dictionary = storage_n.get("items", {})
		var total_n: int = 0
		for k in items_n:
			total_n += int(items_n[k])
		var cap_n: int = data.max_stored_items if data.max_stored_items > 0 else 8
		return total_n < cap_n

	# --- Auto-recipe factory (Water Centrifuge) ---
	# Reports "accepts X" for any recipe input fluid, UNLESS a different
	# recipe's input is already buffered (one fluid at a time). Mirrors the
	# gate in `_try_accept_factory_item` so routers don't try to push a
	# second, incompatible fluid at it.
	if data.tags.has("auto_recipe"):
		var ar_anchor = main.get_building_anchor(grid_pos)
		var ar_origin: Vector2i = ar_anchor if ar_anchor != null else grid_pos
		var ar_buf: Dictionary = factory_buffers[ar_origin].get("inputs", {}) if factory_buffers.has(ar_origin) else {}
		var ar_amt: int = -1
		var ar_locked_other: bool = false
		for entry in data.factory_recipes:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var in_dict: Dictionary = entry.get("input", {})
			for in_id in in_dict:
				var in_sn := StringName(in_id)
				if in_sn == item_id:
					ar_amt = int(in_dict[in_id])
				elif int(ar_buf.get(in_sn, 0)) > 0:
					ar_locked_other = true
		if ar_amt < 0 or ar_locked_other:
			return false
		var ar_cap2: int = data.max_stored_items if data.max_stored_items > 0 else maxi(ar_amt, 1) * 10
		return int(ar_buf.get(item_id, 0)) < ar_cap2

	# --- Factory-style accept (omnidirectional, side_inputs, unit_fabricator) ---
	# Directional factories that route outputs via `output_sides` accept inputs
	# on any side (only their output is directional), so treat them like omni.
	var is_omni: bool = data.tags.has("omnidirectional") or not data.output_sides.is_empty()
	var is_unit_fab: bool = data.produced_unit != &""
	if is_omni or is_unit_fab:
		var anchor = main.get_building_anchor(grid_pos)
		var origin: Vector2i = anchor if anchor != null else grid_pos
		# Pass origin so recipe-select factories report their ACTIVE recipe's
		# ingredients (otherwise routers think they accept nothing).
		var eff_inputs := _get_effective_inputs(data, origin)
		for raw_id in eff_inputs:
			if StringName(raw_id) == item_id:
				var cap: int = data.max_stored_items if data.max_stored_items > 0 else int(eff_inputs[raw_id]) * 10
				var have: int = 0
				if factory_buffers.has(origin):
					have = int(factory_buffers[origin]["inputs"].get(item_id, 0))
				return have < cap
	elif not data.side_inputs.is_empty():
		var anchor2 = main.get_building_anchor(grid_pos)
		var origin2: Vector2i = anchor2 if anchor2 != null else grid_pos
		var rot: int = main.building_rotation.get(origin2, 0)
		for rel_dir_key in data.side_inputs:
			var rel_dir: int = int(rel_dir_key)
			if (rel_dir + rot) % 4 == entry_dir:
				if StringName(data.side_inputs[rel_dir_key]) == item_id:
					return true
				return false

	# --- Constructor (any side, needs item in selected block's build_cost) ---
	if data.tags.has("constructor"):
		var anchor_c = main.get_building_anchor(grid_pos)
		var origin_c: Vector2i = anchor_c if anchor_c != null else grid_pos
		if not constructor_state.has(origin_c):
			return false
		var state = constructor_state[origin_c]
		if state["phase"] != "collecting":
			return false
		var sel: StringName = state["selected_block"]
		if sel == &"":
			return false
		var tdata = Registry.get_block(sel)
		if tdata == null:
			return false
		for raw_id in tdata.build_cost:
			if StringName(raw_id) == item_id or StringName("mat_" + str(raw_id)) == item_id:
				var have_c: int = int(state["collected"].get(StringName(str(raw_id)), 0))
				return have_c < int(tdata.build_cost[raw_id])
		return false

	# --- Turret ammo (any side) ---
	if data.is_turret() and not data.ammo_types.is_empty():
		if not data.ammo_accepts(item_id):
			return false
		# Respect the turret's ammo cap — otherwise the router picker
		# would keep committing to a full turret because "the ammo type
		# matches", even though `_try_accept_turret_ammo` is rejecting
		# every transfer for being over capacity. That stranded items
		# at the router and prevented round-robin to other outputs.
		var turret_anchor = main.get_building_anchor(grid_pos)
		var turret_origin: Vector2i = turret_anchor if turret_anchor != null else grid_pos
		var cap_t: int = data.max_stored_items if data.max_stored_items > 0 else 30
		var storage_t: Dictionary = block_storage.get(turret_origin, {})
		var items_t: Dictionary = storage_t.get("items", {})
		var total_t: int = 0
		for k in items_t:
			total_t += int(items_t[k])
		return total_t < cap_t

	return false


## Picks the exit direction for a router item without transferring it.
## Advances the round-robin index so subsequent items go different ways.
## Returns -1 if no output is available.
## True if the cell `grid_pos + DIR_VECTORS[dir]` will currently accept
## `item_id` via the router's animation contract — i.e. either an empty
## same-faction conveyor cell, or a non-conveyor block whose input side
## faces back toward the router and accepts this item. Used by the
## pre-decide pass to decide whether the cached exit_dir is still valid.
##
## A conveyor cell that's currently OCCUPIED still counts as accepting:
## the item just visually waits at this exit edge until the downstream
## belt clears, instead of flicking its committed direction over to
## whatever side happens to be empty this frame. Without that rule a
## router with one busy downstream and two bare-terrain sides would
## animate items toward bare terrain.
func _router_exit_accepts(grid_pos: Vector2i, dir: int, item_id: StringName) -> bool:
	if dir < 0 or dir > 3:
		return false
	var next_pos: Vector2i = grid_pos + DIR_VECTORS[dir]
	if _is_cross_faction(grid_pos, next_pos):
		return false
	if _is_conveyor_cell(next_pos):
		# Cell currently holding an item is not accepting.
		if conveyor_items.has(next_pos):
			return false
		# Dead-end check: a straight conveyor whose own downstream is
		# bare terrain will trap any item we ship to it. Without this
		# the picker happily commits to a stub conveyor (the user's
		# "items go down half the time" complaint) — items would
		# pile up there even though the side technically reads as
		# "empty" right now. Special belts (router/sorter/junction/
		# bridge/overflow/underflow) have non-trivial routing of their
		# own and are always treated as accepting.
		if _is_simple_conveyor(next_pos):
			var next_rot: int = main.building_rotation.get(next_pos, 0)
			var beyond: Vector2i = next_pos + DIR_VECTORS[next_rot]
			if not main.placed_buildings.has(beyond):
				return false
		return true
	if main.placed_buildings.has(next_pos):
		var entry_dir: int = (dir + 2) % 4
		return _could_block_accept_item(next_pos, item_id, entry_dir)
	return false


## True for plain straight belts — anything whose forward output is the
## single cell in front of it. False for routers/junctions/sorters/etc
## which split items in non-forward directions, so the simple lookahead
## above doesn't apply.
func _is_simple_conveyor(grid_pos: Vector2i) -> bool:
	if not _is_conveyor_cell(grid_pos):
		return false
	if _is_router_cell(grid_pos) or _is_junction_cell(grid_pos):
		return false
	if _is_sorter_cell(grid_pos) or _is_inverted_sorter_cell(grid_pos):
		return false
	if _is_overflow_cell(grid_pos) or _is_underflow_cell(grid_pos):
		return false
	if _is_bridge_cell(grid_pos):
		return false
	return true


func _pick_router_exit(grid_pos: Vector2i, item: Dictionary) -> int:
	# Back side is input-only; outputs are the other three sides.
	var rot: int = main.building_rotation.get(grid_pos, 0)
	var exclude_dir: int = (rot + 2) % 4

	var outputs: Array[int] = []
	for dir_idx in range(4):
		if dir_idx != exclude_dir:
			outputs.append(dir_idx)

	if not router_output_index.has(grid_pos):
		router_output_index[grid_pos] = 0

	var rr_start: int = router_output_index[grid_pos] % outputs.size()

	# First pass: look for an empty downstream we can commit AND advance to
	# this frame. Only advance round-robin when we actually commit so that
	# a fully-blocked router doesn't churn the index every frame. Routes
	# through `_router_exit_accepts` so dead-end stubs (straight belt
	# pointing at bare terrain) are skipped instead of becoming silent
	# black holes for round-robin'd items.
	for attempt in range(outputs.size()):
		var idx: int = (rr_start + attempt) % outputs.size()
		var out_dir: int = outputs[idx]
		var next_pos: Vector2i = grid_pos + DIR_VECTORS[out_dir]
		var entry_dir: int = (out_dir + 2) % 4

		if _is_cross_faction(grid_pos, next_pos):
			continue

		# Empty (and non-dead-end) conveyor ahead = perfect output.
		if _is_conveyor_cell(next_pos) and _router_exit_accepts(grid_pos, out_dir, item["item_id"]):
			router_output_index[grid_pos] = (idx + 1) % outputs.size()
			return out_dir
		# Non-conveyor building (factory, turret, constructor, etc.) —
		# only lock onto this direction if the building will actually
		# accept this specific item from this side. Otherwise we'd
		# animate the item toward a wall or an incompatible input side
		# and leave it stalled on the router.
		if main.placed_buildings.has(next_pos) and not _is_conveyor_cell(next_pos):
			if _could_block_accept_item(next_pos, item["item_id"], entry_dir):
				router_output_index[grid_pos] = (idx + 1) % outputs.size()
				return out_dir

	# Second pass: no side is currently accepting, but pick a side that
	# at least has a real downstream chain so the animation points
	# somewhere plausible while we wait. A "real downstream" means:
	#   - a conveyor whose own forward cell isn't bare terrain (or a
	#     special belt like a router/junction/sorter), OR
	#   - a non-conveyor building that could accept this item from the
	#     entry side.
	# Walls, bare terrain, and incompatible buildings are all filtered
	# out — so the item never animates toward "nothing" (the user's
	# "going down into nothing" complaint). Don't advance round-robin:
	# we haven't actually transferred yet.
	for attempt in range(outputs.size()):
		var idx2: int = (rr_start + attempt) % outputs.size()
		var out_dir2: int = outputs[idx2]
		var next_pos2: Vector2i = grid_pos + DIR_VECTORS[out_dir2]
		var entry_dir2: int = (out_dir2 + 2) % 4
		if _is_cross_faction(grid_pos, next_pos2):
			continue
		if _is_conveyor_cell(next_pos2):
			if _is_simple_conveyor(next_pos2):
				var beyond_rot: int = main.building_rotation.get(next_pos2, 0)
				var beyond2: Vector2i = next_pos2 + DIR_VECTORS[beyond_rot]
				if not main.placed_buildings.has(beyond2):
					continue
			return out_dir2
		if main.placed_buildings.has(next_pos2):
			if _could_block_accept_item(next_pos2, item["item_id"], entry_dir2):
				return out_dir2

	# Truly nothing usable on any side. Leave `exit_dir` as the caller
	# had it (the calling code skips the overwrite on -1 → -1, so a
	# fresh item just stays uncommitted).
	return -1


# =========================
# BELT BRIDGE
# =========================

## Returns true if this bridge is the input end of a link (pair[0]).
func _is_bridge_input(grid_pos: Vector2i) -> bool:
	var power_sys = _power_sys_ref()
	if power_sys == null:
		return false
	for pair in power_sys.linked_pairs:
		if pair[0] == grid_pos:
			return true
	return false


## Teleports an item from an input bridge to one of its linked output
## bridges. Duct bridges may fan out to up to 3 destinations and merge
## from up to 3 sources; the dispatch picks the next round-robin
## destination that can currently accept the item (slot empty, filter
## match, and lock allows). Belt bridges keep 1:1 behavior since their
## cap is 1.
func _try_bridge_transfer(grid_pos: Vector2i, item: Dictionary) -> bool:
	var power_sys = _power_sys_ref()
	if power_sys == null:
		return false

	# All destinations this input bridge fans out to.
	var partners: Array = power_sys.get_links_as_source_all(grid_pos)
	if partners.is_empty():
		return false

	var item_id: StringName = StringName(item.get("item_id", &""))
	var rr_start: int = int(bridge_output_rr.get(grid_pos, 0)) % maxi(partners.size(), 1)
	for offset in range(partners.size()):
		var idx: int = (rr_start + offset) % partners.size()
		var partner = partners[idx]
		if partner == null or not _is_bridge_cell(partner):
			continue
		# Filter gate: per-output filter — single item id the output
		# bridge accepts from ANY incoming source. Empty / missing
		# entry = no filter.
		var filt_id: StringName = StringName(duct_bridge_filters.get(partner, &""))
		if filt_id != &"" and filt_id != item_id:
			continue
		# Slot gate: output bridge cell must be empty.
		if conveyor_items.has(partner):
			continue
		# Push the item across.
		var out_rot: int = main.building_rotation.get(partner, 0)
		var entry_dir: int = (out_rot + 2) % 4  # enters from behind
		conveyor_items[partner] = {
			"item_id": item_id,
			"progress": 0.0,
			"entry_dir": entry_dir,
		}
		# Advance round-robin so the next call tries the NEXT
		# destination first — even spread across multi-output ducts.
		bridge_output_rr[grid_pos] = (idx + 1) % partners.size()
		return true
	return false  # No destination could accept


# =========================
# BELT JUNCTION
# =========================

## Returns true if entry_dir aligns with the junction's primary axis.
## Junctions are non-directional: horizontal (left/right) is always primary,
## vertical (up/down) is always perpendicular.
func _is_junction_primary_axis(_grid_pos: Vector2i, entry_dir: int) -> bool:
	# 0 = right, 2 = left → primary (horizontal)
	# 1 = down, 3 = up   → perpendicular (vertical)
	return entry_dir == 0 or entry_dir == 2


## Pass item straight through the junction (exit = opposite of entry).
func _try_junction_transfer(grid_pos: Vector2i, item: Dictionary) -> bool:
	var entry_dir: int = item.get("entry_dir", -1)
	if entry_dir < 0:
		# Fallback: use junction's facing direction
		entry_dir = (main.building_rotation.get(grid_pos, 0) + 2) % 4
	var exit_dir: int = (entry_dir + 2) % 4  # straight through
	var next_pos: Vector2i = grid_pos + DIR_VECTORS[exit_dir]
	var next_entry: int = (exit_dir + 2) % 4

	if _is_cross_faction(grid_pos, next_pos):
		return false

	return _try_transfer_item(next_pos, item["item_id"], next_entry)


# =========================
# BELT SORTER / INVERTED SORTER
# =========================

## Sorter: matching items go front, non-matching go sides.
## Inverted sorter: matching items go sides, non-matching go front.
func _try_sorter_transfer(grid_pos: Vector2i, item: Dictionary, inverted: bool) -> bool:
	var rot: int = main.building_rotation.get(grid_pos, 0)
	var item_id: StringName = item["item_id"]
	var filter_id: StringName = sorter_filters.get(grid_pos, &"")

	var matches: bool = (filter_id != &"" and item_id == filter_id)

	# Normal: match→front, no-match→sides. Inverted: reversed.
	var use_front: bool = matches if not inverted else not matches

	if use_front:
		var front_pos: Vector2i = grid_pos + DIR_VECTORS[rot]
		var entry_dir: int = (rot + 2) % 4
		if not _is_cross_faction(grid_pos, front_pos):
			return _try_transfer_item(front_pos, item_id, entry_dir)
		return false
	else:
		# Try sides (alternating left/right)
		var left_dir: int = (rot + 3) % 4   # CCW
		var right_dir: int = (rot + 1) % 4  # CW

		if not sorter_side_index.has(grid_pos):
			sorter_side_index[grid_pos] = 0

		var side_dirs: Array[int] = [left_dir, right_dir]
		var start: int = sorter_side_index[grid_pos] % 2

		for attempt in range(2):
			var idx: int = (start + attempt) % 2
			var side: int = side_dirs[idx]
			var side_pos: Vector2i = grid_pos + DIR_VECTORS[side]
			var entry_dir: int = (side + 2) % 4
			if _is_cross_faction(grid_pos, side_pos):
				continue
			if _try_transfer_item(side_pos, item_id, entry_dir):
				sorter_side_index[grid_pos] = (idx + 1) % 2
				return true
		return false


# =========================
# OVERFLOW BELT
# =========================

## Try front first; if front fails, overflow to sides.
func _try_overflow_transfer(grid_pos: Vector2i, item: Dictionary) -> bool:
	var rot: int = main.building_rotation.get(grid_pos, 0)
	var item_id: StringName = item["item_id"]

	# Try front
	var front_pos: Vector2i = grid_pos + DIR_VECTORS[rot]
	var front_entry: int = (rot + 2) % 4
	if not _is_cross_faction(grid_pos, front_pos):
		if _try_transfer_item(front_pos, item_id, front_entry):
			return true

	# Front blocked — try sides
	var left_dir: int = (rot + 3) % 4
	var right_dir: int = (rot + 1) % 4
	for side_dir in [left_dir, right_dir]:
		var side_pos: Vector2i = grid_pos + DIR_VECTORS[side_dir]
		var entry_dir: int = (side_dir + 2) % 4
		if _is_cross_faction(grid_pos, side_pos):
			continue
		if _try_transfer_item(side_pos, item_id, entry_dir):
			return true
	return false


# =========================
# UNDERFLOW BELT
# =========================

## Try sides first; if both sides fail, underflow to front.
func _try_underflow_transfer(grid_pos: Vector2i, item: Dictionary) -> bool:
	var rot: int = main.building_rotation.get(grid_pos, 0)
	var item_id: StringName = item["item_id"]

	# Try sides first
	var left_dir: int = (rot + 3) % 4
	var right_dir: int = (rot + 1) % 4
	for side_dir in [left_dir, right_dir]:
		var side_pos: Vector2i = grid_pos + DIR_VECTORS[side_dir]
		var entry_dir: int = (side_dir + 2) % 4
		if _is_cross_faction(grid_pos, side_pos):
			continue
		if _try_transfer_item(side_pos, item_id, entry_dir):
			return true

	# Both sides blocked — try front
	var front_pos: Vector2i = grid_pos + DIR_VECTORS[rot]
	var front_entry: int = (rot + 2) % 4
	if not _is_cross_faction(grid_pos, front_pos):
		return _try_transfer_item(front_pos, item_id, front_entry)
	return false


# =========================
# PAYLOAD LOGIC
# =========================

## Moves payloads along payload/freight conveyors.
## Mirrors the regular conveyor system: transfer first, then advance.
func _update_payloads(delta: float) -> void:
	# --- PHASE 1: TRANSFER ---
	for _pass in range(2):
		var cells_with_full_payloads := []
		for grid_pos in payload_items:
			if payload_items[grid_pos]["progress"] >= 1.0:
				cells_with_full_payloads.append(grid_pos)

		for grid_pos in cells_with_full_payloads:
			if not payload_items.has(grid_pos):
				continue  # Already transferred
			# Payload cells that aren't finished building don't hand off
			# their payload — the carrier just sits at the end of the belt.
			if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
				continue

			var entry = payload_items[grid_pos]
			var payload_data: Dictionary = entry["payload_data"]
			var entry_dir: int = entry.get("entry_dir", -1)

			# --- BRIDGE: teleport to linked output bridge ---
			if _is_bridge_cell(grid_pos):
				if _is_bridge_input(grid_pos):
					var power_sys = _power_sys_ref()
					if power_sys:
						var partner: Variant = null
						for pair in power_sys.linked_pairs:
							if pair[0] == grid_pos:
								partner = pair[1]
								break
						if partner != null and _is_payload_cell(partner) and not payload_items.has(partner):
							var out_rot: int = main.building_rotation.get(partner, 0)
							payload_items[partner] = {
								"payload_data": payload_data,
								"progress": 0.0,
								"entry_dir": (out_rot + 2) % 4,
							}
							payload_items.erase(grid_pos)
					continue

			# --- JUNCTION: pass straight through ---
			if _is_junction_cell(grid_pos):
				var junc_entry: int = entry_dir if entry_dir >= 0 else (main.building_rotation.get(grid_pos, 0) + 2) % 4
				var exit_dir: int = (junc_entry + 2) % 4
				# Step past the junction's far edge in `exit_dir`. For
				# multi-tile junctions (payload_junction is 3×3) the
				# anchor + DIR_VECTORS step would land INSIDE the
				# junction's own footprint, the transfer would target
				# the junction's anchor (which already holds this
				# payload), `_try_transfer_payload` rejects it as
				# already-occupied, and the payload stalls forever.
				var jdata = Registry.get_block(main.placed_buildings.get(grid_pos, &""))
				var jsize: Vector2i = jdata.grid_size if jdata else Vector2i(1, 1)
				var next_pos: Vector2i
				match exit_dir:
					0: next_pos = grid_pos + Vector2i(jsize.x, 0)
					1: next_pos = grid_pos + Vector2i(0, jsize.y)
					2: next_pos = grid_pos + Vector2i(-1, 0)
					3: next_pos = grid_pos + Vector2i(0, -1)
					_: next_pos = grid_pos + DIR_VECTORS[exit_dir]
				var next_entry: int = (exit_dir + 2) % 4
				if not _is_cross_faction(grid_pos, next_pos):
					if _try_transfer_payload(next_pos, payload_data, next_entry):
						payload_items.erase(grid_pos)
				continue

			# --- ROUTER: distribute to 3 output directions (round-robin) ---
			# Back face is input-only; outputs are the other three sides.
			if _is_router_cell(grid_pos):
				var rot: int = main.building_rotation.get(grid_pos, 0)
				var exclude_dir: int = (rot + 2) % 4

				var outputs: Array[int] = []
				for dir_idx in range(4):
					if dir_idx != exclude_dir:
						outputs.append(dir_idx)

				if not payload_router_idx.has(grid_pos):
					payload_router_idx[grid_pos] = 0

				# Prefer the exit direction the renderer was promised
				# (set by the advance pass). If that direction's target
				# can actually receive the payload, deliver there so the
				# arc-animation lines up exactly with the actual handoff;
				# otherwise fall back to the round-robin scan.
				var transferred := false
				var cached_exit: int = int(entry.get("exit_dir", -1))
				if cached_exit >= 0:
					var ce_pos: Vector2i = _payload_exit_cell(grid_pos, cached_exit)
					var ce_entry: int = (cached_exit + 2) % 4
					if not _is_cross_faction(grid_pos, ce_pos) \
							and _try_transfer_payload(ce_pos, payload_data, ce_entry):
						var ce_idx: int = outputs.find(cached_exit)
						if ce_idx >= 0:
							payload_router_idx[grid_pos] = (ce_idx + 1) % outputs.size()
						transferred = true
				if not transferred:
					var rr_start: int = payload_router_idx[grid_pos] % outputs.size()
					for attempt in range(outputs.size()):
						var idx: int = (rr_start + attempt) % outputs.size()
						var out_dir: int = outputs[idx]
						var next_pos: Vector2i = _payload_exit_cell(grid_pos, out_dir)
						var next_entry: int = (out_dir + 2) % 4
						if _is_cross_faction(grid_pos, next_pos):
							continue
						if _try_transfer_payload(next_pos, payload_data, next_entry):
							payload_router_idx[grid_pos] = (idx + 1) % outputs.size()
							transferred = true
							break
				if transferred:
					payload_items.erase(grid_pos)
				continue

			# --- Normal payload conveyor: push forward via front edge ---
			var rot: int = main.building_rotation.get(grid_pos, 0)
			var conv_block_id: StringName = main.placed_buildings.get(grid_pos, &"")
			var conv_data = Registry.get_block(conv_block_id)
			var conv_gs: Vector2i = conv_data.grid_size if conv_data else Vector2i(1, 1)
			var front_cells: Array[Vector2i] = _get_front_edge(grid_pos, conv_gs, rot)
			var next_entry: int = (rot + 2) % 4
			var transferred := false
			for front_pos in front_cells:
				if _is_cross_faction(grid_pos, front_pos):
					continue
				if _try_transfer_payload(front_pos, payload_data, next_entry):
					transferred = true
					break
			if transferred:
				payload_items.erase(grid_pos)
			elif payload_data.get("type", "") == "unit":
				# End-of-line: no payload-handling block in front accepted
				# the unit. If the front edge is clear or walkable (empty,
				# grass, or a passable transport tile), spawn the unit into
				# the world right off the conveyor. Another payload cell
				# that couldn't accept right now (e.g. currently full) stays
				# in the "hold" state — we don't dump units onto a
				# downstream stuck conveyor.
				if _try_spawn_unit_off_conveyor(grid_pos, conv_gs, rot, front_cells, payload_data):
					payload_items.erase(grid_pos)

	# --- PHASE 2: ADVANCE ---
	for grid_pos in payload_items:
		# Don't advance payloads on inactive cells — the carrier freezes until
		# the underlying conveyor finishes construction.
		if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
			continue
		var entry = payload_items[grid_pos]
		if entry["progress"] < 1.0:
			var speed := conveyor_speed
			var block_id = main.placed_buildings.get(grid_pos, &"")
			var conv_tile_size: float = 1.0
			if block_id != &"":
				var data = Registry.get_block(block_id)
				if data != null:
					if data.transport_speed > 0:
						speed = data.transport_speed
					conv_tile_size = float(maxi(data.grid_size.x, data.grid_size.y))
			# Scale progress by conveyor tile size (larger = slower progress per frame)
			entry["progress"] = minf(entry["progress"] + speed * delta / conv_tile_size, 1.0)

	# Pre-decide exit direction so the renderer can curve the payload
	# along its actual path (mirrors what conveyor items do for routers).
	# Junctions: exit = opposite of entry, fixed for the lifetime of the
	# payload on this cell. Routers: keep a cached choice while it's
	# still valid; re-pick only when the chosen exit becomes blocked, so
	# the visual doesn't oscillate between edges every frame on a fully
	# stalled router. Conveyors: leave unset — renderer falls back to
	# the cell's placement rotation.
	for grid_pos in payload_items:
		var entry: Dictionary = payload_items[grid_pos]
		if _is_junction_cell(grid_pos):
			var jentry_dir: int = int(entry.get("entry_dir", -1))
			if jentry_dir >= 0 and not entry.has("exit_dir"):
				entry["exit_dir"] = (jentry_dir + 2) % 4
			continue
		if _is_router_cell(grid_pos):
			var cur_exit: int = int(entry.get("exit_dir", -1))
			if cur_exit >= 0 and _payload_router_exit_open(grid_pos, cur_exit):
				continue
			var rentry_dir: int = int(entry.get("entry_dir", -1))
			var picked: int = _pick_payload_router_exit(grid_pos, rentry_dir)
			if picked >= 0:
				entry["exit_dir"] = picked


## Returns the cell directly past the router/junction footprint in
## `exit_dir` — handles multi-tile so 3×3 payload routers step past
## their own anchor row instead of landing inside themselves.
func _payload_exit_cell(grid_pos: Vector2i, exit_dir: int) -> Vector2i:
	var rdata = Registry.get_block(main.placed_buildings.get(grid_pos, &""))
	var rsize: Vector2i = rdata.grid_size if rdata else Vector2i(1, 1)
	match exit_dir:
		0: return grid_pos + Vector2i(rsize.x, 0)
		1: return grid_pos + Vector2i(0, rsize.y)
		2: return grid_pos + Vector2i(-1, 0)
		3: return grid_pos + Vector2i(0, -1)
	return grid_pos + DIR_VECTORS[exit_dir]


## True if the cell past the router in `exit_dir` is currently a
## payload cell AND not already holding a payload — i.e. transferring
## that way would actually succeed.
func _payload_router_exit_open(grid_pos: Vector2i, exit_dir: int) -> bool:
	var np: Vector2i = _payload_exit_cell(grid_pos, exit_dir)
	if _is_cross_faction(grid_pos, np):
		return false
	if not _is_payload_cell(np):
		return false
	var np_anchor: Vector2i = main.building_origins.get(np, np)
	return not payload_items.has(np_anchor)


## Picks the next router exit direction for a payload in round-robin
## order, skipping the entry side. Returns -1 if every candidate is
## blocked (caller leaves any cached `exit_dir` in place so the visual
## doesn't oscillate while stalled). Mirrors item routers' picker.
func _pick_payload_router_exit(grid_pos: Vector2i, _entry_dir: int) -> int:
	# Back face is input-only; outputs are the other three sides regardless
	# of which face the payload entered from.
	var rot: int = main.building_rotation.get(grid_pos, 0)
	var exclude_dir: int = (rot + 2) % 4
	var outputs: Array[int] = []
	for d in range(4):
		if d != exclude_dir:
			outputs.append(d)
	var rr_start: int = int(payload_router_idx.get(grid_pos, 0)) % outputs.size()
	for attempt in range(outputs.size()):
		var idx: int = (rr_start + attempt) % outputs.size()
		var od: int = outputs[idx]
		if _payload_router_exit_open(grid_pos, od):
			return od
	return -1


## Tries to place a payload onto a payload cell.
## Checks if cell is a payload cell, is empty, and can fit the payload's grid size.
func _try_push_payload(grid_pos: Vector2i, payload_data: Dictionary, entry_dir: int = -1) -> bool:
	if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
		return false
	if not _is_payload_cell(grid_pos):
		return false

	# Don't push onto blocks that pull payloads themselves
	var push_block_id: StringName = main.placed_buildings.get(grid_pos, &"")
	if push_block_id != &"":
		var push_data = Registry.get_block(push_block_id)
		if push_data and (push_data.tags.has("payload_loader") or push_data.tags.has("freight_loader") \
			or push_data.tags.has("payload_unloader") or push_data.tags.has("freight_unloader") \
			or push_data.tags.has("deconstructor") or push_data.tags.has("mass_driver")):
			return false

	# Use anchor position — only 1 payload per conveyor block (even multi-tile)
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	if payload_items.has(anchor):
		return false

	# Check max_payload_size vs payload's grid_size
	var block_id = main.placed_buildings.get(anchor, &"")
	if block_id != &"":
		var data = Registry.get_block(block_id)
		if data != null and data.max_payload_size > 0:
			var payload_size: int = 1
			if payload_data.get("type", "") == "building":
				payload_size = maxi(
					int(payload_data.get("grid_size_x", 1)),
					int(payload_data.get("grid_size_y", 1))
				)
			if payload_size > data.max_payload_size:
				return false

	payload_items[anchor] = {
		"payload_data": payload_data,
		"progress": 0.0,
		"entry_dir": entry_dir,
	}
	return true


## Tries to transfer a payload into the destination cell.
## Handles router (round-robin), junction, bridge logic via instant placement.
func _try_transfer_payload(to: Vector2i, payload_data: Dictionary, entry_dir: int) -> bool:
	if not _is_payload_cell(to):
		return false
	# Payload routers only accept payloads entering from their BACK face;
	# the other three sides are reserved for output. Unknown entry_dir
	# (-1) is allowed through for non-belt sources (drones, scripts, etc.).
	if _is_router_cell(to) and entry_dir >= 0:
		var to_anchor: Vector2i = main.building_origins.get(to, to)
		var router_rot: int = main.building_rotation.get(to_anchor, 0)
		if entry_dir != (router_rot + 2) % 4:
			return false
	# Don't push into loaders/unloaders/deconstructors — they pull payloads themselves
	var to_block_id: StringName = main.placed_buildings.get(to, &"")
	if to_block_id != &"":
		var to_data = Registry.get_block(to_block_id)
		if to_data and (to_data.tags.has("payload_loader") or to_data.tags.has("freight_loader") \
			or to_data.tags.has("payload_unloader") or to_data.tags.has("freight_unloader") \
			or to_data.tags.has("deconstructor") or to_data.tags.has("constructor") \
			or to_data.tags.has("mass_driver")):
			return false
	var to_anchor: Vector2i = main.building_origins.get(to, to)
	if payload_items.has(to_anchor):
		return false

	# Check max_payload_size
	var block_id = main.placed_buildings.get(to_anchor, &"")
	if block_id != &"":
		var data = Registry.get_block(block_id)
		if data != null and data.max_payload_size > 0:
			var payload_size: int = 1
			if payload_data.get("type", "") == "building":
				payload_size = maxi(
					int(payload_data.get("grid_size_x", 1)),
					int(payload_data.get("grid_size_y", 1))
				)
			if payload_size > data.max_payload_size:
				return false

	# Instant-progress blocks (routers, junctions, bridges) get progress 1.0
	var _is_instant := (_is_router_cell(to) or _is_junction_cell(to) or _is_bridge_cell(to))

	payload_items[to_anchor] = {
		"payload_data": payload_data,
		"progress": 1.0 if _is_instant else 0.0,
		"entry_dir": entry_dir,
	}
	return true


## Hands a payload directly into an adjacent loader / unloader / mass driver
## / deconstructor, bypassing payload conveyors. Used by every block that
## outputs payloads so two of these blocks placed next to each other can
## hand off without an intermediate belt.
##
## Returns true iff the neighbour at `out_pos` accepted the payload.
## `source_origin` is the anchor of the block doing the handoff — used to
## reject handing back into yourself (multi-tile blocks have multiple
## perimeter cells that all map to the same anchor).
func _try_handoff_payload_to_block(out_pos: Vector2i, payload_data: Dictionary, source_origin: Vector2i) -> bool:
	var anchor: Vector2i = main.building_origins.get(out_pos, out_pos)
	if anchor == source_origin:
		return false
	if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
		return false
	if _is_cross_faction(source_origin, anchor):
		return false
	var block_id: StringName = main.placed_buildings.get(anchor, &"")
	if block_id == &"":
		return false
	var data = Registry.get_block(block_id)
	if data == null:
		return false

	var sector_script = _sector_script_ref()
	if sector_script and sector_script.is_building_disabled(anchor):
		return false

	var rot: int = main.building_rotation.get(anchor, 0)

	# --- LOADER input — accepts a storage-tagged building payload from
	# ANY adjacent face. The belt-fed pickup in `_update_loaders` still
	# enforces "back face only" (so a conveyor running past the loader's
	# output side doesn't dump into it), but direct neighbour-to-
	# neighbour drops are unrestricted: orient the loader however you
	# want and it'll grab the payload.
	if data.tags.has("payload_loader") or data.tags.has("freight_loader"):
		if payload_data.get("type", "") != "building":
			return false
		var t_id := StringName(payload_data.get("block_id", ""))
		var t_data = Registry.get_block(t_id)
		if t_data == null or not t_data.tags.has("storage"):
			return false
		if not loader_state.has(anchor):
			loader_state[anchor] = {"payload": null, "phase": "idle", "fill_target": {}}
		var st: Dictionary = loader_state[anchor]
		if st.get("payload") != null:
			return false
		st["payload"] = payload_data
		st["phase"] = "filling"
		var stored: Dictionary = payload_data.get("stored_items", {})
		var total_stored := 0
		for sid in stored:
			total_stored += int(stored[sid])
		var capacity: int = t_data.max_stored_items if t_data.max_stored_items > 0 else 0
		st["fill_target"] = {"_capacity": capacity, "_current": total_stored}
		return true

	# --- UNLOADER input — any perimeter cell, only storage-tagged buildings,
	# only when the unloader has no held payload.
	if data.tags.has("payload_unloader") or data.tags.has("freight_unloader"):
		if payload_data.get("type", "") != "building":
			return false
		var t_id := StringName(payload_data.get("block_id", ""))
		var t_data = Registry.get_block(t_id)
		if t_data == null or not t_data.tags.has("storage"):
			return false
		if not unloader_state.has(anchor):
			unloader_state[anchor] = {"payload": null, "phase": "idle", "internal_storage": {}}
		var st: Dictionary = unloader_state[anchor]
		if st.get("payload") != null:
			return false
		st["payload"] = payload_data
		st["phase"] = "transferring"
		return true

	# --- MASS DRIVER input — any perimeter cell EXCEPT the front (which is
	# the launch face). Skips MDs that already hold a payload. Bumps the
	# state straight to `rotating_to_output` so `_update_mass_drivers` will
	# pick it up next tick (matches what the regular pickup branch does).
	if data.tags.has("mass_driver"):
		var front_cells: Array[Vector2i] = _get_front_edge(anchor, data.grid_size, rot)
		if front_cells.has(out_pos):
			return false
		if not mass_driver_state.has(anchor):
			mass_driver_state[anchor] = {
				"payload": null, "head_angle": 0.0, "target_angle": 0.0,
				"recoil": 0.0, "phase": "idle", "cooldown": 0.0,
				"input_pos": Vector2i.ZERO,
			}
		var st: Dictionary = mass_driver_state[anchor]
		if st.get("payload") != null:
			return false
		st["payload"] = payload_data
		st["phase"] = "rotating_to_output"
		return true

	# --- DECONSTRUCTOR input — accepts on any adjacent perimeter for
	# direct hand-offs. Belt-fed pickup still uses front face only (see
	# `_update_deconstructors`) so output items don't collide with the
	# input belt, but a direct neighbour-to-neighbour drop is fine.
	if data.tags.has("deconstructor"):
		if not deconstructor_state.has(anchor):
			deconstructor_state[anchor] = {
				"payload": null, "phase": "idle",
				"timer": 0.0, "pending_items": {},
			}
		var st: Dictionary = deconstructor_state[anchor]
		if st.get("payload") != null:
			return false
		var decon_time := 2.0
		if payload_data.get("type", "") == "building":
			var t_id := StringName(payload_data.get("block_id", ""))
			var t_data = Registry.get_block(t_id)
			if t_data != null and t_data.build_time > 0:
				decon_time = t_data.build_time
		st["payload"] = payload_data
		st["phase"] = "deconstructing"
		st["timer"] = decon_time
		return true

	return false


# =========================
# PIPE LOGIC
# =========================

## Adds fluid to a pipe cell. Returns true if successful.
##
## When `grid_pos` is a junction, the new fluid is routed into the
## junction's V (vertical N↔S) or H (horizontal E↔W) channel based on
## `from_dir` — the direction the caller went TO REACH `grid_pos`. So
## a pump pushing east (dir 0) pumps into the junction's H channel
## (fluid enters from the west = the H axis). Callers that don't know
## the direction (factory unload, etc.) pass `from_dir = -1`; the
## function then refuses the add for junctions, and the junction
## receives fluid via the per-axis equalize tick instead.
func _add_fluid_to_pipe(grid_pos: Vector2i, fluid_id: StringName, amount: float, from_dir: int = -1) -> bool:
	# Fluid can't enter a pipe that isn't fully built, is deconstructing, or is
	# derelict. This blocks every caller (pumps, factories, storage unloading,
	# belt-unloaders) without having to check at each site.
	if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
		return false
	var fluid = Registry.get_fluid(fluid_id)
	if fluid == null:
		return false
	# Junction handling: route into the correct axis compartment.
	if _is_junction_cell(grid_pos):
		if from_dir < 0:
			return false
		# dirs 0 (east) and 2 (west) → H channel; dirs 1 (south) and
		# 3 (north) → V channel.
		var axis: String = "h" if from_dir == 0 or from_dir == 2 else "v"
		var state: Dictionary = pipe_junction_state.get(grid_pos, {
			"v_fluid": &"", "v_amount": 0.0,
			"h_fluid": &"", "h_amount": 0.0,
		})
		var fluid_key: String = axis + "_fluid"
		var amount_key: String = axis + "_amount"
		var existing_fluid: StringName = state.get(fluid_key, &"")
		var existing_amount: float = float(state.get(amount_key, 0.0))
		if existing_fluid != &"" and existing_fluid != fluid_id:
			return false
		if existing_amount >= fluid.units_per_segment:
			return false
		state[fluid_key] = fluid_id
		state[amount_key] = minf(existing_amount + amount, fluid.units_per_segment)
		pipe_junction_state[grid_pos] = state
		return true

	if pipe_contents.has(grid_pos):
		var pipe = pipe_contents[grid_pos]
		# Reject if different fluid already in pipe
		if pipe["fluid_id"] != fluid_id:
			return false
		# Cap at units_per_segment
		if pipe["amount"] >= fluid.units_per_segment:
			return false
		pipe["amount"] = minf(pipe["amount"] + amount, fluid.units_per_segment)
	else:
		pipe_contents[grid_pos] = {
			"fluid_id": fluid_id,
			"amount": minf(amount, fluid.units_per_segment),
		}
	return true


# =========================
# UNIT UPGRADER / PAYLOAD REFIT BAY
# =========================

## True if `up_data` (a module block) may be applied to `unit_data`. When the
## module's `module_unit_layers` is empty it fits any unit; otherwise the
## unit's movement layer must be in the list (e.g. Lift Engine = [HOVER, FLYING]).
func _module_fits_unit(up_data: BlockData, unit_data: UnitData) -> bool:
	var layers: Array = up_data.module_unit_layers
	if layers.is_empty():
		return true
	return layers.has(int(unit_data.movement_layer))


## Whether `up_data` can be applied to the held unit right now: layer-
## compatible, the unit has a free slot, AND it isn't already at this
## module's per-unit cap (`module_max_applies`, e.g. Armor Plate ×3).
func _module_can_apply_to(up_data: BlockData, unit_data: UnitData, unit_payload: Dictionary) -> bool:
	if not _module_fits_unit(up_data, unit_data):
		return false
	if _unit_free_slots(unit_payload) < 1:
		return false
	var count := 0
	for u in (unit_payload.get("applied_upgrades", []) as Array):
		if StringName(u) == up_data.id:
			count += 1
	return count < maxi(1, up_data.module_max_applies)


## Free upgrade slots left on a unit payload = tier capacity - applied count.
func _unit_free_slots(unit_payload: Dictionary) -> int:
	var ud = Registry.get_unit(StringName(unit_payload.get("unit_id", "")))
	if ud == null:
		return 0
	var applied: int = (unit_payload.get("applied_upgrades", []) as Array).size()
	return maxi(0, ud.upgrade_slots() - applied)


## Builds a building payload dict for an upgrade module (so the refit bay can
## eject it onto a payload conveyor).
func _build_module_payload(block_id: StringName) -> Dictionary:
	var bd = Registry.get_block(block_id)
	if bd == null:
		return {}
	return {
		"type": "building",
		"block_id": String(block_id),
		"grid_size_x": bd.grid_size.x,
		"grid_size_y": bd.grid_size.y,
		"health": bd.max_health,
		"rotation": 0,
	}


## Unit Upgrader: holds one unit (accepted only with a free slot), buffers
## incoming compatible module payloads, and applies each over 4s + 25 power
## (scaled by power efficiency). Ejects the kitted unit once it has no free
## slot left, or once ≥1 upgrade was applied and nothing compatible remains
## queued. Inputs from the front edge, ejects to the other sides.
func _update_unit_upgraders(delta: float) -> void:
	for grid_pos in _bucket("upgrader"):
		var origin: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if origin != grid_pos:
			continue
		var data = Registry.get_block(main.placed_buildings.get(origin, &""))
		if data == null:
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue
		if not upgrader_state.has(origin):
			upgrader_state[origin] = {"unit": null, "queue": [], "applying": &"", "timer": 0.0, "applied_session": 0}
		var state: Dictionary = upgrader_state[origin]
		var rot: int = main.building_rotation.get(origin, 0)
		var front_cells := _get_front_edge(origin, data.grid_size, rot)
		var output_cells := _get_all_output_cells(origin, data.grid_size, rot)

		# 1. Pull one payload from a front conveyor.
		for edge in front_cells:
			var conv: Vector2i = main.building_origins.get(edge, edge)
			if not payload_items.has(conv):
				continue
			if float(payload_items[conv].get("progress", 0.0)) < 1.0:
				continue
			var pd: Dictionary = payload_items[conv]["payload_data"]
			var ptype: String = pd.get("type", "")
			if ptype == "unit":
				if state["unit"] == null and _unit_free_slots(pd) >= 1:
					state["unit"] = pd
					state["applied_session"] = 0
					payload_items.erase(conv)
					break
			elif ptype == "building":
				var bd = Registry.get_block(StringName(pd.get("block_id", "")))
				if bd != null and bd.tags.has("module"):
					var take := true
					if state["unit"] != null:
						var ud = Registry.get_unit(StringName(state["unit"].get("unit_id", "")))
						take = ud != null and _module_can_apply_to(bd, ud, state["unit"])
					if take:
						state["queue"].append(pd)
						payload_items.erase(conv)
						break

		if state["unit"] == null:
			continue
		var unit_data = Registry.get_unit(StringName(state["unit"].get("unit_id", "")))
		if unit_data == null:
			_eject_payload(state, "unit", output_cells)
			continue

		var power_eff: float = 1.0
		var ps = _power_sys_ref()
		if ps and data.electrical_power_use > 0:
			power_eff = clampf(float(ps.get_electrical_efficiency(origin)), 0.0, 1.0)

		# 2. Apply current upgrade, or pick the next compatible one, or eject.
		if state["applying"] != &"":
			if power_eff > 0.0:
				state["timer"] -= delta * power_eff
				if state["timer"] <= 0.0:
					var ups: Array = state["unit"].get("applied_upgrades", [])
					ups.append(state["applying"])
					state["unit"]["applied_upgrades"] = ups
					state["applied_session"] = int(state["applied_session"]) + 1
					state["applying"] = &""
		else:
			var idx: int = -1
			if _unit_free_slots(state["unit"]) >= 1:
				for i in range(state["queue"].size()):
					var qbd = Registry.get_block(StringName(state["queue"][i].get("block_id", "")))
					if qbd != null and _module_can_apply_to(qbd, unit_data, state["unit"]):
						idx = i
						break
			if idx >= 0:
				state["applying"] = StringName(state["queue"][idx].get("block_id", ""))
				state["queue"].remove_at(idx)
				state["timer"] = 4.0
			elif _unit_free_slots(state["unit"]) <= 0 or int(state["applied_session"]) > 0:
				# Full, or done applying everything we had — eject the unit.
				_eject_payload(state, "unit", output_cells)


## Payload Refit Bay: accepts only a unit carrying ≥1 upgrade, ejects each
## upgrade as its own module payload (4s + 25 power each), then ejects the
## stripped unit. Inputs from the front edge, ejects to the other sides.
func _update_refit_bays(delta: float) -> void:
	for grid_pos in _bucket("refit_bay"):
		var origin: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if origin != grid_pos:
			continue
		var data = Registry.get_block(main.placed_buildings.get(origin, &""))
		if data == null:
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue
		if not refit_state.has(origin):
			refit_state[origin] = {"unit": null, "pending": [], "timer": 0.0, "ejecting": false}
		var state: Dictionary = refit_state[origin]
		var rot: int = main.building_rotation.get(origin, 0)
		var front_cells := _get_front_edge(origin, data.grid_size, rot)
		var output_cells := _get_all_output_cells(origin, data.grid_size, rot)

		# 1. Pull a unit WITH upgrades from a front conveyor.
		if state["unit"] == null:
			for edge in front_cells:
				var conv: Vector2i = main.building_origins.get(edge, edge)
				if not payload_items.has(conv):
					continue
				if float(payload_items[conv].get("progress", 0.0)) < 1.0:
					continue
				var pd: Dictionary = payload_items[conv]["payload_data"]
				if pd.get("type", "") != "unit":
					continue
				var ups: Array = pd.get("applied_upgrades", [])
				if ups.is_empty():
					continue   # refit bay only accepts kitted units
				state["unit"] = pd
				state["pending"] = ups.duplicate()
				state["ejecting"] = false
				state["timer"] = 0.0
				payload_items.erase(conv)
				break

		if state["unit"] == null:
			continue

		var power_eff: float = 1.0
		var ps = _power_sys_ref()
		if ps and data.electrical_power_use > 0:
			power_eff = clampf(float(ps.get_electrical_efficiency(origin)), 0.0, 1.0)

		# 2. Eject upgrades one at a time, then the stripped unit.
		if not state["pending"].is_empty():
			if not state["ejecting"]:
				state["timer"] = 4.0
				state["ejecting"] = true
			if power_eff > 0.0:
				state["timer"] -= delta * power_eff
				if state["timer"] <= 0.0:
					var up_id: StringName = StringName(state["pending"][0])
					var up_payload := _build_module_payload(up_id)
					var done := false
					if up_payload.is_empty():
						done = true  # unknown module — drop it
					else:
						for out in output_cells:
							if _try_push_payload(out, up_payload):
								done = true
								break
					if done:
						state["pending"].remove_at(0)
						(state["unit"]["applied_upgrades"] as Array).erase(up_id)
						state["ejecting"] = false
					# else: outputs blocked — retry next frame
		else:
			# All upgrades stripped — eject the unit itself.
			_eject_payload(state, "unit", output_cells)


## Pushes `state[key]` (a payload dict) onto the first available output cell,
## clearing the slot + transient fields on success.
func _eject_payload(state: Dictionary, key: String, output_cells: Array) -> void:
	if state.get(key) == null:
		return
	for out in output_cells:
		if _try_push_payload(out, state[key]):
			state[key] = null
			state["applying"] = &""
			state["applied_session"] = 0
			state["timer"] = 0.0
			state["ejecting"] = false
			return


# =========================
# DEV SOURCE BLOCKS
# =========================

## Resource Source: emits the chosen item/fluid out every side each frame.
## `_try_push_item` routes items onto conveyors and fluids into pipes, and
## fails when the target is full — so this is naturally rate-limited.
func _update_resource_sources(_delta: float) -> void:
	for grid_pos in _bucket("resource_source"):
		var origin: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if origin != grid_pos:
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue
		var res: StringName = source_resource.get(origin, &"")
		if res == &"":
			continue
		var data = Registry.get_block(main.placed_buildings.get(origin, &""))
		if data == null:
			continue
		var rot: int = main.building_rotation.get(origin, 0)
		for out in _get_all_output_cells(origin, data.grid_size, rot):
			var entry_dir := _get_entry_dir_from_building(out, origin, data.grid_size)
			_try_push_item(out, res, entry_dir)


## Payload Source: emits the chosen block/unit as a payload onto an output
## payload conveyor. `_try_push_payload` fails when the conveyor already holds
## one, so it streams at belt speed. Units carry the chosen team so they
## spawn Lumina/Ferox when unpacked.
func _update_payload_sources(_delta: float) -> void:
	for grid_pos in _bucket("payload_source"):
		var origin: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if origin != grid_pos:
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue
		var sel: Dictionary = source_payload.get(origin, {})
		if sel.is_empty():
			continue
		var data = Registry.get_block(main.placed_buildings.get(origin, &""))
		if data == null:
			continue
		var sid: StringName = StringName(sel.get("id", ""))
		var payload: Dictionary = {}
		if sel.get("kind", "") == "unit":
			var ud = Registry.get_unit(sid)
			if ud == null:
				continue
			var team_sel: int = int(sel.get("team", 0))
			payload = {
				"type": "unit", "unit_id": String(sid), "health": ud.max_health,
				"team": team_sel, "applied_upgrades": [],
				# Payload-Source enemies spawn as inert, commandable test dummies.
				"is_dummy": team_sel == 1,
			}
		else:
			var bd = Registry.get_block(sid)
			if bd == null:
				continue
			payload = {
				"type": "building", "block_id": String(sid),
				"grid_size_x": bd.grid_size.x, "grid_size_y": bd.grid_size.y,
				"health": bd.max_health, "rotation": 0,
			}
		# Directional: emit only out the front edge (the facing direction),
		# not every side. Rotate with Q at placement like other directional
		# blocks.
		var rot: int = main.building_rotation.get(origin, 0)
		for out in _get_front_edge(origin, data.grid_size, rot):
			if _try_push_payload(out, payload.duplicate(true)):
				break   # one payload per frame; belt occupancy rate-limits us


## Re-derives the pipe network partition: the set of connected-component
## networks the per-frame equalization runs over. This is the expensive
## flood-fill (O(active pipe cells), plus a linked_pairs scan per bridge)
## that used to run EVERY frame — now gated behind the dirty flag + refresh
## timer in `_update_pipes`. Skips junctions (their per-axis channels are
## handled in `_tick_pipe_junctions`) and inactive/under-construction pipes.
func _rebuild_pipe_networks() -> void:
	_pipe_networks.clear()
	var all_pipe_cells := {}
	for grid_pos in _bucket("pipe"):
		if not _is_pipe_cell(grid_pos):
			continue
		if _is_junction_cell(grid_pos):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
			continue
		all_pipe_cells[grid_pos] = true

	var visited := {}
	for grid_pos in all_pipe_cells:
		if visited.has(grid_pos):
			continue
		var network := _find_pipe_network(grid_pos)
		for pos in network:
			visited[pos] = true
		_pipe_networks.append(network)


## Updates all pipe networks: equalize, leak, and feed factories.
func _update_pipes(delta: float) -> void:
	# --- Phase A: Find networks and equalize ---
	# The network PARTITION (which cells flood-fill into which network) is
	# cached and only re-derived when topology changes (dirty flag) or the
	# safety-net refresh timer elapses — see `_rebuild_pipe_networks`. Fluid
	# EQUALIZATION runs every frame on the cached partition, so flow stays
	# smooth; only the expensive flood-fill is throttled.
	_pipe_net_refresh_accum += delta
	if _pipe_net_dirty or _pipe_net_refresh_accum >= _PIPE_NET_REFRESH:
		_rebuild_pipe_networks()
		_pipe_net_dirty = false
		_pipe_net_refresh_accum = 0.0

	for network: Array in _pipe_networks:
		if network.is_empty():
			continue
		# Sum total fluid in the network
		var total_amount := 0.0
		var fluid_id := &""
		for pos in network:
			if pipe_contents.has(pos):
				total_amount += pipe_contents[pos]["amount"]
				if fluid_id == &"":
					fluid_id = pipe_contents[pos]["fluid_id"]

		if total_amount <= 0 or fluid_id == &"":
			continue

		# Equalize: distribute fluid evenly across all pipes in network
		var avg := total_amount / network.size()
		for pos in network:
			if avg > 0:
				if pipe_contents.has(pos):
					pipe_contents[pos]["amount"] = avg
				else:
					pipe_contents[pos] = {"fluid_id": fluid_id, "amount": avg}
			elif pipe_contents.has(pos):
				pipe_contents[pos]["amount"] = 0.0

	# --- Phase A.5: Junction cross-without-mixing ---
	# Each junction is two independent fluid channels — vertical (N↔S)
	# and horizontal (E↔W). They never share fluid through the junction
	# cell, so a vertical and a horizontal pipe network can cross the
	# same tile without merging. Implemented by equalizing each axis
	# with its 2 same-axis plain-pipe neighbours and skipping junctions
	# during the regular pipe-network flood-fill (above).
	_tick_pipe_junctions()

	# --- Phase B: Leak from fully orphaned pipes (no neighbors at all) ---
	var to_clean := []
	for grid_pos in pipe_contents:
		var pipe = pipe_contents[grid_pos]
		if pipe["amount"] <= 0:
			to_clean.append(grid_pos)
			continue

		# Only leak if this pipe has NO pipe/factory neighbor in any direction
		var has_any_neighbor := false
		for dir in range(4):
			var nb: Vector2i = grid_pos + DIR_VECTORS[dir]
			if _is_pipe_cell(nb):
				has_any_neighbor = true
				break
			if _factory_accepts_fluid_from(nb, pipe["fluid_id"], (dir + 2) % 4):
				has_any_neighbor = true
				break
			# Also check if a pump is adjacent (source)
			if main.placed_buildings.has(nb):
				var nb_data = Registry.get_block(main.placed_buildings[nb])
				if nb_data and nb_data.tags.has("pump"):
					has_any_neighbor = true
					break

		if not has_any_neighbor:
			pipe["amount"] = maxf(pipe["amount"] - PIPE_LEAK_RATE * delta, 0.0)
			if pipe["amount"] <= 0:
				to_clean.append(grid_pos)

	# --- Phase C: Feed factories from pipes ---
	for grid_pos in pipe_contents:
		var pipe = pipe_contents[grid_pos]
		if pipe["amount"] <= 0:
			continue

		var fluid = Registry.get_fluid(pipe["fluid_id"])
		if fluid == null:
			continue

		var units_needed: float = fluid.units_per_item if fluid.units_per_item > 0 else 10.0

		# Check all 4 adjacent cells for factory inputs
		for dir in range(4):
			var neighbor: Vector2i = grid_pos + DIR_VECTORS[dir]
			var entry_dir: int = (dir + 2) % 4  # Fluid enters factory from opposite side

			if pipe["amount"] < units_needed:
				break

			# Block cross-faction pipe→factory feed
			if _is_cross_faction(grid_pos, neighbor):
				continue

			if _try_accept_factory_item(neighbor, pipe["fluid_id"], entry_dir):
				pipe["amount"] -= units_needed
				if pipe["amount"] <= 0:
					break
				continue
			# Booster-fluid sip: blocks like the double-barrel /
			# payload crane that declare a fluid-based booster but
			# aren't factories siphon water (or whatever fluid the
			# booster references) into their generic fluid storage.
			if _try_accept_booster_fluid(neighbor, pipe["fluid_id"]):
				pipe["amount"] -= units_needed
				if pipe["amount"] <= 0:
					break

	# Feed factories directly adjacent to junctions, using whichever
	# axis compartment lines up with the factory's side. Without this,
	# a factory sitting right next to a junction (no plain pipe in
	# between) would never be fed.
	for j_anchor in pipe_junction_state:
		if not _is_junction_cell(j_anchor):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(j_anchor):
			continue
		var j_state: Dictionary = pipe_junction_state[j_anchor]
		# axis → (fluid_key, amount_key, neighbour offsets)
		var axis_specs := [
			{"axis": "v", "neighbors": [Vector2i(0, -1), Vector2i(0, 1)], "dirs": [3, 1]},
			{"axis": "h", "neighbors": [Vector2i(1, 0), Vector2i(-1, 0)], "dirs": [0, 2]},
		]
		for spec in axis_specs:
			var ax: String = spec["axis"]
			var fk: String = ax + "_fluid"
			var ak: String = ax + "_amount"
			var jf_id: StringName = j_state.get(fk, &"")
			if jf_id == &"":
				continue
			var jf_data = Registry.get_fluid(jf_id)
			if jf_data == null:
				continue
			var jf_needed: float = jf_data.units_per_item if jf_data.units_per_item > 0 else 10.0
			var jf_amount: float = float(j_state.get(ak, 0.0))
			var neighbours: Array = spec["neighbors"]
			var dirs: Array = spec["dirs"]
			for i in range(neighbours.size()):
				if jf_amount < jf_needed:
					break
				var nb_cell: Vector2i = j_anchor + neighbours[i]
				var entry_dir: int = (int(dirs[i]) + 2) % 4
				if _is_cross_faction(j_anchor, nb_cell):
					continue
				if _try_accept_factory_item(nb_cell, jf_id, entry_dir):
					jf_amount -= jf_needed
					continue
				if _try_accept_booster_fluid(nb_cell, jf_id):
					jf_amount -= jf_needed
			j_state[ak] = maxf(0.0, jf_amount)
		pipe_junction_state[j_anchor] = j_state

	# Clean up empty pipe entries
	for pos in to_clean:
		if pipe_contents.has(pos) and pipe_contents[pos]["amount"] <= 0:
			pipe_contents.erase(pos)

	# --- Phase D: Front-leak (open-end pipes drip into a puddle) ---
	# A pipe whose facing-front cell has no building (and isn't a wall)
	# drips 0.5 fluid/sec into the front cell. Existing puddle in that
	# cell grows (capped at PUDDLE_MAX_AMOUNT); a fresh one is spawned
	# with a random polygon shape.
	for grid_pos in pipe_contents:
		var pipe2 = pipe_contents[grid_pos]
		if pipe2["amount"] <= 0:
			continue
		if not _is_pipe_cell(grid_pos):
			continue
		# Skip junctions, routers, and bridges — these are connector /
		# crossover blocks. They don't have a single "front" facing and
		# shouldn't drip into the cell their rotation happens to point
		# at. Only plain pipe segments leak from an open front.
		if _is_junction_cell(grid_pos) or _has_block_tag(grid_pos, "router") \
				or _is_bridge_cell(grid_pos):
			continue
		var rot: int = main.building_rotation.get(grid_pos, 0)
		var front_cell: Vector2i = grid_pos + DIR_VECTORS[rot]
		# Only leak when the front cell is genuinely open ground —
		# another building (pipe, factory, pump, anything) means the
		# pipe is "connected" out the front and shouldn't dribble.
		# Walls block the spill too (water can't pool inside rock).
		if main.placed_buildings.has(front_cell):
			continue
		if _terrain and _terrain.has_method("has_wall") and _terrain.has_wall(front_cell):
			continue
		if not main.is_within_bounds(front_cell):
			continue
		# Target drain: 0.5 fluid units / second per leaking pipe.
		# Capped by:
		#   - the pipe's own remaining content (can't drain what's
		#     not there)
		#   - the puddle's remaining capacity (a full puddle stops
		#     accepting drips, so the pipe stops bleeding too —
		#     fluid doesn't silently disappear into a full puddle)
		var attempted: float = PUDDLE_LEAK_RATE * delta
		var drip: float = minf(attempted, pipe2["amount"])
		if drip <= 0.0:
			continue
		# Refuse to drain past the puddle's headroom so the pipe's
		# fluid-loss rate matches what the puddle actually receives.
		var existing_puddle: Dictionary = puddles.get(front_cell, {})
		var fluid_id: StringName = pipe2["fluid_id"]
		if not existing_puddle.is_empty() \
				and existing_puddle.get("fluid_id", &"") == fluid_id:
			var room: float = PUDDLE_MAX_AMOUNT - float(existing_puddle.get("amount", 0.0))
			drip = minf(drip, maxf(0.0, room))
		if drip <= 0.0:
			continue
		pipe2["amount"] -= drip
		# Direction from the puddle cell BACK to the leaking pipe —
		# used by `_make_puddle_shape` to pool the puddle against the
		# pipe-facing edge of the cell instead of the centre.
		var back_dir: Vector2i = -DIR_VECTORS[rot]
		_feed_puddle(front_cell, fluid_id, drip, back_dir)

	# --- Phase F: Wet status on units inside puddles ---
	# Cheap radius test (unit centre within scaled puddle radius) rather
	# than a full point-in-polygon — saves the hot-loop polygon walk
	# and the result is visually equivalent for blob-shaped puddles.
	if not puddles.is_empty() and _unit_mgr:
		_apply_puddle_wet_status()

	# --- Phase E: Mindustry-style spread + viscosity-modulated dry-up ---
	# Mirrors Mindustry's PuddleComp:
	#   amount -= delta * (1 - viscosity) / (5 + addSpeed)
	#   if amount >= maxLiquid/1.5 → deposit (amount - maxLiquid/1.5)/4
	#                                 (capped at 0.3 * delta) to each
	#                                 of the 4 cardinal neighbour tiles.
	# We piggy-back on `_feed_puddle` for the deposit so the receiving
	# tile (a) creates a new puddle if one wasn't there, (b) ignores
	# walls / solid floors via the existing pipe-leak gates, and
	# (c) refuses to mix different fluids (first-in wins).
	var puddle_to_erase: Array = []
	# Build the spread queue first; applying spreads inside the iter
	# loop would mutate `puddles` mid-iteration.
	var spread_queue: Array = []  # [from_cell, fluid_id, amount_per_neighbour]
	for pp in puddles:
		var pd: Dictionary = puddles[pp]
		var amt: float = float(pd["amount"])

		# (1) Spread once we cross the threshold.
		if amt >= _SPREAD_THRESHOLD:
			var overflow: float = (amt - _SPREAD_THRESHOLD) / 4.0
			var dep: float = minf(overflow, _SPREAD_DEPOSIT_CAP * delta)
			if dep > 0.0:
				spread_queue.append([pp, StringName(pd.get("fluid_id", &"")), dep])

		# (2) Evaporate. Mindustry: rate scales with (1 - viscosity);
		# water (viscosity ~0.3) evaporates faster than oil. The
		# PUDDLE_DRY_RATE multiplier maps Mindustry's constants into
		# our timeline (15-unit puddle vs. their 70).
		if pd.get("fed", false):
			pd["fed"] = false
		else:
			var visc: float = 1.0
			var fid: StringName = StringName(pd.get("fluid_id", &""))
			if fid != &"":
				var fdata = Registry.get_fluid(fid)
				if fdata != null:
					visc = clampf(float(fdata.viscosity), 0.0, 1.0)
			# At viscosity 0 → full PUDDLE_DRY_RATE; viscosity 1 → 0.
			var dry_rate: float = PUDDLE_DRY_RATE * maxf(0.05, 1.0 - visc)
			pd["amount"] = maxf(0.0, float(pd["amount"]) - dry_rate * delta)
			if pd["amount"] <= 0.0:
				puddle_to_erase.append(pp)

	# Apply spreads. Each entry pushes `dep` units into the 4 cardinal
	# neighbours of `from_cell`, leaving `from_cell` lighter by the
	# total delivered. _feed_puddle already enforces same-fluid +
	# wall / out-of-bounds rejection (we replicate the wall check here
	# since _feed_puddle currently has no such gate).
	for entry in spread_queue:
		var from_cell: Vector2i = entry[0]
		var spread_fid: StringName = entry[1]
		var per_nb: float = entry[2]
		if spread_fid == &"":
			continue
		var src_pd: Dictionary = puddles.get(from_cell, {})
		if src_pd.is_empty():
			continue
		for dir in range(4):
			var nb: Vector2i = from_cell + DIR_VECTORS[dir]
			if not main.is_within_bounds(nb):
				continue
			# Walls / buildings block the spread the same way they
			# block a pipe's initial front-leak — water doesn't pool
			# inside rock or under a placed block.
			if main.placed_buildings.has(nb):
				continue
			if _terrain and _terrain.has_method("has_wall") and _terrain.has_wall(nb):
				continue
			# Different-fluid neighbour blocks the spread (Mindustry
			# would react here; we simply refuse the deposit so the
			# existing puddle keeps its identity).
			var nb_pd: Dictionary = puddles.get(nb, {})
			if not nb_pd.is_empty() \
					and StringName(nb_pd.get("fluid_id", &"")) != spread_fid:
				continue
			var back_dir: Vector2i = -DIR_VECTORS[dir]
			# Stronger edge bias for SPREAD puddles — pulls the new
			# blob's centre to the shared edge with the source so the
			# two visibly merge instead of leaving a gap in the
			# middle of the receiving tile.
			_feed_puddle(nb, spread_fid, per_nb, back_dir, 0.5)
			src_pd["amount"] = maxf(0.0, float(src_pd["amount"]) - per_nb)
		puddles[from_cell] = src_pd
		if float(src_pd["amount"]) <= 0.0 and not puddle_to_erase.has(from_cell):
			puddle_to_erase.append(from_cell)

	for pp in puddle_to_erase:
		puddles.erase(pp)


## Adds `amount` units of `fluid_id` to the puddle at `cell`, creating
## it (with a fresh random polygon shape) if it didn't exist. Resets
## the puddle's fluid when a different fluid drips into an existing
## puddle — first one in wins, then loses if the source changes.
## `pipe_back_dir` points from the puddle cell back to the leaking
## pipe, so the puddle pools against that edge of the cell.
func _feed_puddle(cell: Vector2i, fluid_id: StringName, amount: float,
		pipe_back_dir: Vector2i = Vector2i.ZERO,
		edge_offset: float = 0.32) -> void:
	if amount <= 0.0:
		return
	var existing: Dictionary = puddles.get(cell, {})
	if existing.is_empty() or existing.get("fluid_id", &"") != fluid_id:
		var fluid = Registry.get_fluid(fluid_id)
		var col: Color = fluid.color if fluid else Color(0.4, 0.6, 0.95, 1.0)
		var shape_data: Dictionary = _make_puddle_shape(cell, pipe_back_dir, edge_offset)
		existing = {
			"fluid_id": fluid_id,
			"color": col,
			"amount": 0.0,
			# Unit vector pointing INTO the source side of this
			# puddle (i.e. opposite of pipe_back_dir for leaks, and
			# pointing back at the source puddle for spreads). The
			# draw uses this to bias the 3 satellite circles toward
			# the source so a spread puddle visually merges with
			# whatever fed it instead of scattering off to one side
			# of the neighbour tile.
			"primary_dir": Vector2(pipe_back_dir.x, pipe_back_dir.y),
			# Pre-generated 12-circle template: every entry stores its
			# local pos / radius / activation threshold / reach. The
			# active circles are the ones whose `threshold <= amount`.
			"template": shape_data["template"],
			# Cached union polygons for the CURRENT active circle set.
			# Recomputed only when `active_count` changes — so the
			# expensive `Geometry2D.merge_polygons` walk runs once
			# every ~`PUDDLE_MAX_AMOUNT / N` units of accumulated
			# fluid, not every frame.
			"polygons": [] as Array,
			"active_count": 0,
			# Outer reach of the CURRENT active set (pixels). Refreshed
			# alongside `polygons`. Used by the wet-status pass.
			"active_max_radius_px": 0.0,
			"shape_centre": shape_data["centre"],
			"max_radius_px": shape_data["max_radius_px"],
			"fed": false,
		}
	existing["amount"] = minf(PUDDLE_MAX_AMOUNT, float(existing["amount"]) + amount)
	existing["fed"] = true
	puddles[cell] = existing


## Walks every ground / crawler-layer unit and applies the "wet"
## status to any whose centre is inside a puddle's current visible
## extent. The "extent" is the puddle's max polygon radius × the
## same `scale_t` the draw code uses, so a small puddle (still
## filling) only catches units directly on top of it while a
## fully-fed 2.5-tile puddle wets anything walking through it.
##
## Status effects auto-refresh on reapply (see wet.tres), so a unit
## standing in a puddle stays wet as long as it's there + ~5 s
## after stepping out (the effect's natural duration).
func _apply_puddle_wet_status() -> void:
	if _unit_mgr == null:
		return
	var wet_effect: StatusEffectData = Registry.get_status_effect(&"wet") \
		if Registry.has_method("get_status_effect") else null
	if wet_effect == null:
		return
	# Pre-compute world-space centre + active reach once per puddle.
	# Skip empty puddles (amount <= 0) — they're about to be erased.
	# `active_max_radius_px` already tracks the current active set
	# (refreshed lazily by the draw path); fall back to `max_radius_px`
	# for puddles that haven't been drawn yet this frame.
	var hits: Array = []   # Array of [Vector2 centre, float radius_sq]
	for cell in puddles:
		var pd: Dictionary = puddles[cell]
		var amt: float = float(pd.get("amount", 0.0))
		if amt <= 0.0:
			continue
		var radius: float = float(pd.get("active_max_radius_px", 0.0))
		if radius <= 0.0:
			radius = float(pd.get("max_radius_px", float(main.GRID_SIZE) * 0.5))
		if radius <= 0.0:
			continue
		var shape_centre: Vector2 = pd.get("shape_centre",
			Vector2(float(main.GRID_SIZE) * 0.5, float(main.GRID_SIZE) * 0.5))
		var origin: Vector2 = main.grid_to_world(cell)
		hits.append([origin + shape_centre, radius * radius])
	if hits.is_empty():
		return
	# Apply wet to every ground / crawler unit inside any puddle.
	var all_units: Array = []
	if _unit_mgr.has_method("get") and "enemies" in _unit_mgr:
		all_units.append_array(_unit_mgr.enemies)
	if _unit_mgr.has_method("get") and "player_units" in _unit_mgr:
		all_units.append_array(_unit_mgr.player_units)
	# Track per-puddle hazard payload alongside the centre / radius so
	# units standing in an acid / petroleum etc. puddle also take its
	# `hazard_damage` per second (Mindustry's PuddleComp does this via
	# the liquid's effect; ours is a separate stat on FluidData).
	var dt: float = get_process_delta_time()
	var hazards: Array = []   # parallel to `hits`: float dmg-per-sec
	hazards.resize(hits.size())
	for i in range(hits.size()):
		hazards[i] = 0.0
	var hi := 0
	for cell in puddles:
		var pd: Dictionary = puddles[cell]
		var amt: float = float(pd.get("amount", 0.0))
		if amt <= 0.0:
			continue
		var fid: StringName = StringName(pd.get("fluid_id", &""))
		if fid != &"":
			var fdata = Registry.get_fluid(fid)
			if fdata != null and bool(fdata.is_hazardous):
				hazards[hi] = float(fdata.hazard_damage)
		hi += 1
	for u in all_units:
		if u == null or not is_instance_valid(u) or u.is_dead:
			continue
		if u.data == null:
			continue
		# Hover / flying units skim above water — no wet.
		var ml: int = u.data.movement_layer
		if ml != UnitData.MovementLayer.GROUND and ml != UnitData.MovementLayer.CRAWLER:
			continue
		var pos: Vector2 = u.position
		for ei in range(hits.size()):
			var entry: Array = hits[ei]
			var centre: Vector2 = entry[0]
			var r2: float = entry[1]
			if pos.distance_squared_to(centre) <= r2:
				u.apply_status_effect(wet_effect)
				var dmg: float = float(hazards[ei])
				if dmg > 0.0 and u.has_method("take_damage"):
					u.take_damage(dmg * dt)
				break


## Generates the cluster of overlapping circles that make up a puddle.
## Mindustry-style "blob" look: 8 circles fanned around the centre
## with varied sizes, no outline — the union of the circles reads as
## a soft organic puddle. Each circle is stored in local cell space
## (offset relative to `centre`); the draw code applies the per-frame
## shrink and translates into world space.
##
## `pipe_back_dir` points from the puddle cell back to the leaking
## pipe so the centre is offset toward that edge (puddle pools at
## the pipe mouth, not the geometric middle of the cell).
##
## Seeded by (cell, back_dir) — same leak source always regenerates
## the same cluster, so save/load doesn't need to persist the shape.
## Builds the per-puddle CIRCLE TEMPLATE — every entry stores its
## local position, radius, and a `threshold` fluid level. As the
## puddle accumulates more fluid, additional circles cross their
## threshold and join the visible union; as it dries, circles drop
## off in reverse order. The puddle visibly grows / shrinks by
## adding / removing circles rather than uniformly scaling one
## fixed cluster.
##
## Circles are seeded deterministically (cell + back_dir) so save /
## load doesn't need to persist the template.
##
## Circle 0 sits at the centre and has threshold 0 — a single drip
## already shows a tiny puddle. Subsequent circles spread outward
## (distance from centre grows with index) so the puddle expands
## roughly radially as fluid accumulates.
func _make_puddle_shape(cell: Vector2i, pipe_back_dir: Vector2i = Vector2i.ZERO,
		edge_offset: float = 0.32) -> Dictionary:
	var gs: float = float(main.GRID_SIZE)
	# Offset centre toward the source edge of the cell. The default
	# `0.32` is for pipe leaks (pipe-mouth pooling); the spread tick
	# passes a larger value (~0.5) so a spread puddle's centre sits
	# right at the shared edge with the source — the blob grows out
	# of the source puddle instead of starting alone in the middle of
	# the next tile.
	var centre: Vector2 = Vector2(gs * 0.5, gs * 0.5) \
		+ Vector2(pipe_back_dir.x, pipe_back_dir.y) * (gs * edge_offset)
	var rng := RandomNumberGenerator.new()
	rng.seed = (int(cell.x) * 73856093) ^ (int(cell.y) * 19349663) \
		^ (int(pipe_back_dir.x) * 83492791) ^ (int(pipe_back_dir.y) * 49979687)
	var max_r_px: float = _PUDDLE_MAX_RADIUS_TILES * gs
	# `template_circles[i]` = {pos, radius, threshold, reach}.
	#   pos:       Vector2 local position relative to the cluster centre
	#   radius:    float in pixels
	#   threshold: fluid level (units of `amount`) at which this circle
	#              becomes active. Sorted ascending across the template.
	#   reach:     |pos| + radius — distance from cluster centre to this
	#              circle's farthest edge; used for the wet-status
	#              radius check (max across active circles).
	var template: Array = []
	# Circle 0: tiny core at the cluster centre. Threshold 0 → visible
	# from the first drip.
	var core_r: float = max_r_px * rng.randf_range(0.20, 0.28)
	template.append({
		"pos": Vector2.ZERO,
		"radius": core_r,
		"threshold": 0.0,
		"reach": core_r,
	})
	# Remaining circles fan outward. `t` lerps 0 → 1 across the indices
	# so later circles sit progressively farther from the centre, giving
	# the puddle a radial growth feel.
	var n_outer: int = _PUDDLE_MAX_CIRCLES - 1
	for i in range(1, _PUDDLE_MAX_CIRCLES):
		var t: float = float(i - 1) / float(maxi(1, n_outer - 1))
		var dist_frac: float = lerpf(0.18, 0.78, t) + rng.randf_range(-0.06, 0.06)
		dist_frac = clampf(dist_frac, 0.0, 0.85)
		# Golden-angle-ish spread keeps satellites from clustering in
		# one quadrant as the puddle grows.
		var ang: float = float(i) * 2.39996 + rng.randf_range(-0.45, 0.45)
		var radius_frac: float = rng.randf_range(0.22, 0.38)
		# Clamp so reach (dist + radius) never exceeds 1.0 — keeps a
		# fully-fed puddle inside the 2.5-tile diameter envelope.
		if dist_frac + radius_frac > 1.0:
			radius_frac = maxf(0.16, 1.0 - dist_frac)
		var local_pos: Vector2 = Vector2(cos(ang), sin(ang)) * (dist_frac * max_r_px)
		var radius: float = radius_frac * max_r_px
		# Linear thresholds across [0, PUDDLE_MAX_AMOUNT] — each new
		# circle joins after roughly `PUDDLE_MAX_AMOUNT / N` more fluid.
		var threshold: float = float(i) / float(_PUDDLE_MAX_CIRCLES) * PUDDLE_MAX_AMOUNT
		template.append({
			"pos": local_pos,
			"radius": radius,
			"threshold": threshold,
			"reach": local_pos.length() + radius,
		})
	return {
		"template": template,
		"centre": centre,
		# `max_radius_px` is the FULLY-FED extent — used only as a
		# fallback for legacy puddles or for the very first frame
		# before the active set is built.
		"max_radius_px": max_r_px,
	}


## Approximates a circle as a regular n-gon (`segments` vertices). Used
## to feed `Geometry2D.merge_polygons` so the cluster's circles can be
## unioned into one outline.
func _circle_polygon(c: Vector2, radius: float, segments: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(segments)
	for i in range(segments):
		var ang: float = (float(i) / float(segments)) * TAU
		out[i] = c + Vector2(cos(ang), sin(ang)) * radius
	return out


## Sequentially merges an array of (overlapping) polygons into the
## union outline(s). Each merge returns an Array[PackedVector2Array]
## — usually one polygon for our overlapping circle clusters, but the
## code carries forward all returned pieces in case the cluster ever
## ends up disconnected.
func _union_polygons(polys: Array) -> Array:
	if polys.is_empty():
		return []
	var accum: Array = [polys[0]]
	for i in range(1, polys.size()):
		var next_poly: PackedVector2Array = polys[i]
		var new_accum: Array = []
		var merged := false
		for existing in accum:
			if merged:
				new_accum.append(existing)
				continue
			var union: Array = Geometry2D.merge_polygons(existing, next_poly)
			if union.size() == 1:
				# Single combined outline — replace `existing` with
				# the merged result and continue.
				next_poly = union[0]
				merged = true
			elif union.size() > 1:
				# Disjoint pieces returned — keep the existing and try
				# the next iteration with the same `next_poly`.
				new_accum.append(existing)
			else:
				# merge_polygons returned nothing (shouldn't happen
				# with valid input). Keep existing and skip the merge.
				new_accum.append(existing)
		new_accum.append(next_poly)
		accum = new_accum
	return accum


## Paints every active puddle on the supplied canvas (the PuddleOverlay
## child). Polygons are filled with the fluid's colour at a constant
## near-opaque alpha; the SHAPE itself shrinks toward the cell centre
## as the puddle dries, so a fading puddle visibly contracts rather
## than fading away in place.
func _draw_puddles(canvas: CanvasItem) -> void:
	if puddles.is_empty():
		return
	# Port of Mindustry's `Liquid.drawPuddle`:
	#   float f = clamp(amount / (maxLiquid / 1.5));
	#   Draw color (base, shiftValue(-0.05));   // 5% darker
	#   Fill.circle(x + wob, y + wob, f * 8);   // central blob
	#   for(i = 0; i < 3; i++):
	#       v = trns(rand(360), rand(f * 6));
	#       Fill.circle(x + v.x + wob, y + v.y + wob, f * 5);
	# Mindustry tiles are 32 px, ours are 128 px, so radii / offsets
	# all multiply by `tile_scale = gs / 32.0` to read at the same
	# relative size.
	var gs: float = float(main.GRID_SIZE)
	var tile_scale: float = gs / 32.0
	var t: float = float(Time.get_ticks_msec()) * 0.001
	var wob_scl: float = 25.0
	var wob_mag: float = 0.6 * tile_scale
	for cell in puddles:
		var pd: Dictionary = puddles[cell]
		var amt: float = float(pd.get("amount", 0.0))
		if amt <= 0.0:
			continue
		var f: float = clampf(amt / _SPREAD_THRESHOLD, 0.0, 1.0)
		if f <= 0.0:
			continue
		var base_col: Color = pd.get("color", Color(0.4, 0.6, 0.95, 1.0))
		# Mindustry's `shiftValue(-0.05)` = drop HSV value by 5 %.
		var col: Color = base_col.darkened(0.05)
		# Tail-fade so a draining puddle doesn't pop out at the end.
		var fade_window: float = _SPREAD_THRESHOLD * 0.15
		if amt < fade_window and fade_window > 0.0:
			col.a *= clampf(amt / fade_window, 0.0, 1.0)
		# Centre on the cell's grid-to-world position + shape_centre
		# bias (so pipe-fed puddles pool toward the pipe mouth instead
		# of the geometric middle of the tile).
		var shape_centre: Vector2 = pd.get("shape_centre", Vector2(gs * 0.5, gs * 0.5))
		var x: float = main.grid_to_world(cell).x + shape_centre.x
		var y: float = main.grid_to_world(cell).y + shape_centre.y
		# Deterministic per-puddle seed for the 3 satellite offsets,
		# matching Mindustry's `rand.setSeed(id)` then 3 random draws.
		var pseed: int = (cell.x * 73856093) ^ (cell.y * 19349663)
		var rng := RandomNumberGenerator.new()
		rng.seed = pseed
		# (1) Central blob.
		var c_wob_x: float = sin(t / wob_scl + float(pseed) * 0.0013) * wob_mag
		var c_wob_y: float = sin(t / wob_scl + float(pseed) * 0.0017) * wob_mag
		canvas.draw_circle(Vector2(x + c_wob_x, y + c_wob_y), f * 8.0 * tile_scale, col)
		# (2) Three satellite blobs. Mindustry scatters across the
		# full 360°; we restrict to a 180° arc facing the source side
		# when `primary_dir` is set (every puddle the system creates
		# has one — pipes point at the leak edge, spreads point back
		# at the feeding puddle). The result is satellite blobs that
		# cluster on the source-facing half of the cell so a spread
		# puddle visibly merges with the puddle that fed it instead
		# of dropping detached dots in the next tile over.
		var primary: Vector2 = pd.get("primary_dir", Vector2.ZERO)
		var has_primary: bool = primary.length_squared() > 0.01
		var base_ang: float = primary.angle() if has_primary else 0.0
		var length: float = f * 6.0 * tile_scale
		for i in range(3):
			var ang: float
			if has_primary:
				# Random ±90° around primary_dir → satellites all sit
				# on the source side of the cell centre.
				ang = base_ang + rng.randf_range(-PI * 0.5, PI * 0.5)
			else:
				ang = rng.randf_range(0.0, TAU)
			var dist: float = rng.randf_range(0.0, length)
			var vx: float = x + cos(ang) * dist
			var vy: float = y + sin(ang) * dist
			var s_wob_x: float = sin(t / wob_scl + float(i) * 0.532) * wob_mag
			var s_wob_y: float = sin(t / wob_scl + float(i) * 0.053) * wob_mag
			canvas.draw_circle(Vector2(vx + s_wob_x, vy + s_wob_y), f * 5.0 * tile_scale, col)
		# Update the cached reach for `_apply_puddle_wet_status` — the
		# farthest point any satellite can reach is `length + f*5`.
		pd["active_max_radius_px"] = (f * 6.0 + f * 5.0) * tile_scale


## Recomputes `pd.polygons` + `pd.active_count` + `pd.active_max_radius_px`
## when `amount` has crossed a circle's threshold since the last call.
## A no-op when the active count is unchanged, so this is cheap on the
## hot path — the heavy `Geometry2D.merge_polygons` walk runs only on
## the rare frames where a circle joins or drops out of the cluster.
func _refresh_puddle_active_set(pd: Dictionary) -> void:
	var template: Array = pd.get("template", [])
	if template.is_empty():
		pd["polygons"] = [] as Array
		pd["active_count"] = 0
		pd["active_max_radius_px"] = 0.0
		return
	var amt: float = float(pd.get("amount", 0.0))
	var target_count: int = 0
	# Templates are sorted by threshold ascending, so we can short-
	# circuit the moment we hit a threshold above the current amount.
	for c in template:
		if float(c.get("threshold", 0.0)) <= amt:
			target_count += 1
		else:
			break
	# Always keep at least the core visible while the puddle has any
	# fluid at all (the tail-fade in the draw handles disappearance).
	if amt > 0.0 and target_count <= 0:
		target_count = 1
	var current_count: int = int(pd.get("active_count", -1))
	if target_count == current_count:
		return
	# Rebuild the union polygon for the new active set.
	var circle_polys: Array = []
	var active_reach: float = 0.0
	for i in range(target_count):
		var c: Dictionary = template[i]
		var pos: Vector2 = c.get("pos", Vector2.ZERO)
		var radius: float = float(c.get("radius", 0.0))
		circle_polys.append(_circle_polygon(pos, radius, _PUDDLE_CIRCLE_VERTS))
		var reach: float = float(c.get("reach", radius))
		if reach > active_reach:
			active_reach = reach
	var union: Array = _union_polygons(circle_polys)
	pd["polygons"] = union
	pd["active_count"] = target_count
	pd["active_max_radius_px"] = active_reach


## Flood-fills from a pipe cell to find all connected pipe cells.
## Pipes connect omnidirectionally (any adjacent pipe is connected).
## Only connects pipes of the same faction to prevent cross-faction fluid flow.
## Equalizes every active junction's two axis compartments with their
## same-axis plain-pipe neighbours. Vertical channel averages with the
## N + S pipe cells; horizontal channel averages with E + W. The two
## channels share no fluid — that's the entire point of a junction.
##
## Junction-to-junction direct chains (a vertical channel touching
## another junction's vertical channel as its N neighbour) are NOT
## propagated through here. If the player wants to chain, they can
## drop a 1-tile pipe segment between the two junctions and fluid
## will pass through via that pipe.
func _tick_pipe_junctions() -> void:
	if pipe_junction_state.is_empty() and not _any_junction_placed():
		return
	# GC: drop state entries for junctions that no longer exist (block
	# was removed / faction-flipped).
	var dead: Array = []
	for anchor in pipe_junction_state:
		if not main.placed_buildings.has(anchor) or not _is_junction_cell(anchor):
			dead.append(anchor)
	for d in dead:
		pipe_junction_state.erase(d)

	for anchor in _bucket("junction"):
		if not _is_junction_cell(anchor):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
			continue
		var state: Dictionary = pipe_junction_state.get(anchor, {
			"v_fluid": &"", "v_amount": 0.0,
			"h_fluid": &"", "h_amount": 0.0,
		})
		_equalize_junction_axis(state, anchor, "v",
			[anchor + Vector2i(0, -1), anchor + Vector2i(0, 1)])
		_equalize_junction_axis(state, anchor, "h",
			[anchor + Vector2i(1, 0), anchor + Vector2i(-1, 0)])
		# Persist if any channel has live fluid, otherwise drop the
		# entry to keep the dict small.
		if float(state["v_amount"]) > 0.0 or float(state["h_amount"]) > 0.0:
			pipe_junction_state[anchor] = state
		else:
			pipe_junction_state.erase(anchor)


## Cheap precheck so `_tick_pipe_junctions` can skip the GC walk + main
## loop when there are no junctions placed at all.
func _any_junction_placed() -> bool:
	for grid_pos in _bucket("junction"):
		if _is_junction_cell(grid_pos):
			return true
	return false


## Averages a junction axis compartment with the two same-axis
## neighbours, with same-fluid mixing rules.
##
## `state`   — the junction's state dict; mutated in place.
## `anchor`  — the junction's grid cell.
## `axis`    — "v" or "h" (which compartment keys to read/write).
## `neighbors` — the two grid cells on this axis (N+S for v, E+W for h).
func _equalize_junction_axis(state: Dictionary, anchor: Vector2i, axis: String, neighbors: Array) -> void:
	var fluid_key: String = axis + "_fluid"
	var amount_key: String = axis + "_amount"
	var j_fluid: StringName = state.get(fluid_key, &"")
	var j_amount: float = float(state.get(amount_key, 0.0))
	# Pick a unifying fluid_id. Prefer the junction's existing fluid
	# (so a half-full channel doesn't randomly switch fluid). Otherwise
	# adopt the first non-empty neighbour's fluid.
	var unifying: StringName = j_fluid
	for nb in neighbors:
		if unifying != &"":
			break
		if pipe_contents.has(nb):
			unifying = pipe_contents[nb]["fluid_id"]
	if unifying == &"":
		# Nothing in this axis at all — nothing to equalize. Reset
		# fluid id for cleanliness.
		state[fluid_key] = &""
		state[amount_key] = 0.0
		return
	# Collect contributors that share the unifying fluid. Mismatched
	# neighbours are skipped (you can't equalize copper into water).
	var contributors: Array = []   # array of {kind, ref, amount}
	var total: float = 0.0
	# Include the junction's own channel.
	if j_fluid == unifying or j_fluid == &"":
		contributors.append({"kind": "junction", "ref": null, "amount": j_amount})
		total += j_amount
	# Include matching plain-pipe neighbours that aren't themselves
	# junctions/routers/bridges and are the same faction as the
	# junction (cross-faction fluid is rejected just like in the
	# regular network loop).
	var jf: int = main.get_building_faction(anchor)
	for nb in neighbors:
		if _is_junction_cell(nb):
			continue
		if not _is_pipe_cell(nb):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(nb):
			continue
		if main.get_building_faction(nb) != jf:
			continue
		if pipe_contents.has(nb):
			var nb_data: Dictionary = pipe_contents[nb]
			if nb_data["fluid_id"] != unifying:
				continue
			contributors.append({"kind": "pipe", "ref": nb, "amount": float(nb_data["amount"])})
			total += float(nb_data["amount"])
		else:
			# Empty cell — still counts as a contributor (its amount
			# is 0) so the junction's overflow can flow into it.
			contributors.append({"kind": "pipe_empty", "ref": nb, "amount": 0.0})
	if contributors.is_empty() or total <= 0.0:
		state[fluid_key] = unifying
		state[amount_key] = j_amount
		return
	var avg: float = total / float(contributors.size())
	# Push the averaged amount back to every contributor.
	for c in contributors:
		match c["kind"]:
			"junction":
				state[amount_key] = avg
				state[fluid_key] = unifying
			"pipe":
				pipe_contents[c["ref"]]["amount"] = avg
			"pipe_empty":
				if avg > 0.0001:
					pipe_contents[c["ref"]] = {
						"fluid_id": unifying,
						"amount": avg,
					}


func _find_pipe_network(start: Vector2i) -> Array[Vector2i]:
	var network: Array[Vector2i] = []
	var queue := [start]
	var seen := {start: true}
	var start_faction: int = main.get_building_faction(start)
	var power_sys = _power_sys_ref()

	while queue.size() > 0:
		var pos: Vector2i = queue.pop_front()
		network.append(pos)

		for dir in range(4):
			var neighbor: Vector2i = pos + DIR_VECTORS[dir]
			if seen.has(neighbor) or not _is_pipe_cell(neighbor):
				continue
			# Junctions are explicitly NOT part of any pipe network —
			# the flood-fill stops at them, and their per-axis state
			# bridges fluid through them in `_tick_pipe_junctions`. This
			# is what enforces "cross without mixing": a vertical
			# network ends at a junction's V side and the matching S
			# network is its own thing; they exchange fluid only via
			# the junction's V channel.
			if _is_junction_cell(neighbor):
				continue
			# Don't cross into pipes that aren't finished building / are being
			# deconstructed / are derelict — fluid can't flow through them.
			if main.has_method("is_building_inactive") and main.is_building_inactive(neighbor):
				continue
			if main.get_building_faction(neighbor) == start_faction:
				seen[neighbor] = true
				queue.append(neighbor)

		# Bridge link: if this cell is a fluid bridge, also pull in its
		# linked partner(s) so fluid equalizes across the bridge. Without
		# this, a linked pair of pipe_bridges acts like two disjoint
		# networks and no fluid ever crosses the link.
		if power_sys != null and _is_bridge_cell(pos):
			for pair in power_sys.linked_pairs:
				var partner: Vector2i
				if pair[0] == pos:
					partner = pair[1]
				elif pair[1] == pos:
					partner = pair[0]
				else:
					continue
				if seen.has(partner) or not _is_pipe_cell(partner):
					continue
				if main.has_method("is_building_inactive") and main.is_building_inactive(partner):
					continue
				if main.get_building_faction(partner) != start_faction:
					continue
				seen[partner] = true
				queue.append(partner)

	return network


## Returns true if a factory at grid_pos would accept the given fluid from entry_dir.
func _factory_accepts_fluid_from(grid_pos: Vector2i, fluid_id: StringName, entry_dir: int) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null or data.side_inputs.is_empty():
		return false

	var anchor = main.get_building_anchor(grid_pos)
	var origin: Vector2i = anchor if anchor != null else grid_pos
	var rot: int = main.building_rotation.get(origin, 0)

	for rel_dir_key in data.side_inputs:
		var rel_dir: int = int(rel_dir_key)
		var world_dir: int = (rel_dir + rot) % 4
		if world_dir == entry_dir:
			var expected := StringName(data.side_inputs[rel_dir_key])
			if fluid_id == expected:
				return true
	return false


# =========================
# BLOCK STORAGE
# =========================

## Returns true if this block type uses internal storage.
## Only extractors, turrets, factories (with side I/O), and pumps have storage.
func _block_uses_storage(data: BlockData) -> bool:
	return data.category == BlockData.BlockCategory.EXTRACTORS \
		or data.category == BlockData.BlockCategory.TURRETS \
		or not data.side_outputs.is_empty() \
		or not data.output_items.is_empty() \
		or data.tags.has("pump") \
		or data.tags.has("omnidirectional") \
		or data.tags.has("storage")


## Adds an item or fluid to a building's internal storage.
## Returns true if successfully stored, false if storage is full.
func _add_to_storage(origin: Vector2i, item_id: StringName, data: BlockData) -> bool:
	if not _block_uses_storage(data):
		return false
	if not block_storage.has(origin):
		block_storage[origin] = {"items": {}, "fluids": {}}

	var storage = block_storage[origin]
	var is_fluid: bool = Registry.get_fluid(item_id) != null

	if is_fluid:
		if data.liquid_capacity <= 0:
			return false
		var total_fluids := _get_total_stored_fluids(storage)
		if total_fluids >= data.liquid_capacity:
			return false
		storage["fluids"][item_id] = storage["fluids"].get(item_id, 0.0) + 1.0
	else:
		if data.max_stored_items <= 0:
			return false
		var total_items := _get_total_stored_items(storage)
		if total_items >= data.max_stored_items:
			return false
		storage["items"][item_id] = storage["items"].get(item_id, 0) + 1

	return true


## Returns the total number of items in storage.
func _get_total_stored_items(storage: Dictionary) -> int:
	var total := 0
	for item_id in storage["items"]:
		total += int(storage["items"][item_id])
	return total


## Returns how many of a specific item are in a building's storage.
func get_stored_item_count(origin: Vector2i, item_id: StringName) -> int:
	if not block_storage.has(origin):
		return 0
	var storage: Dictionary = block_storage[origin]
	return int(storage.get("items", {}).get(item_id, 0))


## Removes up to `amount` of an item from a building's storage. Returns amount actually removed.
func remove_from_storage(origin: Vector2i, item_id: StringName, amount: int) -> int:
	if not block_storage.has(origin):
		return 0
	var storage: Dictionary = block_storage[origin]
	if not storage.has("items"):
		return 0
	var current: int = int(storage["items"].get(item_id, 0))
	var to_remove: int = mini(current, amount)
	if to_remove <= 0:
		return 0
	storage["items"][item_id] = current - to_remove
	if storage["items"][item_id] <= 0:
		storage["items"].erase(item_id)
	return to_remove


## Returns the total amount of fluids in storage.
func _get_total_stored_fluids(storage: Dictionary) -> float:
	var total := 0.0
	for fluid_id in storage["fluids"]:
		total += float(storage["fluids"][fluid_id])
	return total


## Returns true if item storage is full.
func _is_item_storage_full(origin: Vector2i, data: BlockData) -> bool:
	if data.max_stored_items <= 0:
		return false
	if not block_storage.has(origin):
		return false
	return _get_total_stored_items(block_storage[origin]) >= data.max_stored_items


## Returns true if fluid storage is full.
func _is_fluid_storage_full(origin: Vector2i, data: BlockData) -> bool:
	if data.liquid_capacity <= 0:
		return false
	if not block_storage.has(origin):
		return false
	return _get_total_stored_fluids(block_storage[origin]) >= data.liquid_capacity


## Returns true if the building's storage is full for the given item type.
func _is_storage_full_for(origin: Vector2i, data: BlockData, item_id: StringName) -> bool:
	var is_fluid: bool = Registry.get_fluid(item_id) != null
	if is_fluid:
		return _is_fluid_storage_full(origin, data)
	return _is_item_storage_full(origin, data)


## Returns true if every buffer this block actually outputs into is full.
## Buffers the block never produces into don't count — without this gate
## a drill (items-only) would never look "full" because its unused fluid
## buffer always sits at 0 below the default cap, and the power gate
## would keep the drill drawing power forever even with a maxed-out
## item buffer.
func _is_storage_full(origin: Vector2i, data: BlockData) -> bool:
	if not _block_uses_storage(data):
		return false
	if not block_storage.has(origin):
		return false
	var produces_items: bool = _block_produces_items(data) and data.max_stored_items > 0
	var produces_fluids: bool = _block_produces_fluids(data) and data.liquid_capacity > 0
	if not produces_items and not produces_fluids:
		# Pure storage / unclassified — fall back to "any cap reached".
		var i_full: bool = data.max_stored_items > 0 and _get_total_stored_items(block_storage[origin]) >= data.max_stored_items
		var f_full: bool = data.liquid_capacity > 0 and _get_total_stored_fluids(block_storage[origin]) >= data.liquid_capacity
		return i_full or f_full
	var items_full: bool = (not produces_items) or _get_total_stored_items(block_storage[origin]) >= data.max_stored_items
	var fluids_full: bool = (not produces_fluids) or _get_total_stored_fluids(block_storage[origin]) >= data.liquid_capacity
	return items_full and fluids_full


## True if this block can produce items (drills, wall miners, factories
## with output_items, factories with item-typed side_outputs).
func _block_produces_items(data: BlockData) -> bool:
	if data.category == BlockData.BlockCategory.EXTRACTORS and not data.tags.has("pump"):
		return true
	if not data.output_items.is_empty():
		return true
	# Random-output factories (Slag Caster) produce items even though their
	# output table lives in `random_outputs` rather than `output_items`.
	if data.random_outputs != null and not data.random_outputs.is_empty():
		return true
	for k in data.side_outputs:
		var oid := StringName(data.side_outputs[k])
		if oid != &"" and Registry.get_fluid(oid) == null:
			return true
	return false


## Weighted-random pick from a `random_outputs` table (list of
## {"item": StringName, "weight": float}). Returns &"" if the table is empty
## or all weights are non-positive.
func _pick_random_output(table: Array) -> StringName:
	var total: float = 0.0
	for entry in table:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		total += maxf(0.0, float(entry.get("weight", 1.0)))
	if total <= 0.0:
		return &""
	var roll: float = randf() * total
	for entry in table:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var w: float = maxf(0.0, float(entry.get("weight", 1.0)))
		if w <= 0.0:
			continue
		roll -= w
		if roll <= 0.0:
			return StringName(entry.get("item", &""))
	# Floating-point fallthrough — return the last valid entry.
	for i in range(table.size() - 1, -1, -1):
		if typeof(table[i]) == TYPE_DICTIONARY:
			return StringName(table[i].get("item", &""))
	return &""


## True if this block can produce fluids (pumps, factories with
## fluid-typed side_outputs).
func _block_produces_fluids(data: BlockData) -> bool:
	if data.tags.has("pump"):
		return true
	for k in data.side_outputs:
		var oid := StringName(data.side_outputs[k])
		if oid != &"" and Registry.get_fluid(oid) != null:
			return true
	return false


## Tries to unload items/fluids from block storage to adjacent conveyors/pipes.
func _update_storage_unloading(_delta: float) -> void:
	var to_clean := []

	for origin in block_storage:
		var storage = block_storage[origin]
		if storage["items"].is_empty() and storage["fluids"].is_empty():
			to_clean.append(origin)
			continue

		if not main.placed_buildings.has(origin):
			to_clean.append(origin)
			continue

		# Buildings that aren't fully built shouldn't leak stored items/fluids
		# onto adjacent conveyors — skip until construction completes.
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue

		# Try to push stored items onto adjacent conveyors
		# For multi-tile buildings, check all output cells (not just origin neighbors)
		var block_id: StringName = main.placed_buildings.get(origin, &"")
		var data: BlockData = Registry.get_block(block_id) if block_id != &"" else null
		# Turret ammo lives in `block_storage` so combat_system can pop a
		# round off the stack per shot — it's an INPUT buffer, not a
		# product stockpile. Auto-unloading it onto adjacent conveyors
		# caused copper fed in as ammo to immediately cycle back out
		# onto the same belt that delivered it, so the loop "pulls items
		# out of the turret" even though nothing asked it to. Same
		# principle for any future block whose storage is an input-only
		# buffer: add a guard here.
		if data and data.is_turret():
			continue
		# Storage-tagged blocks (small_container, etc.) only release
		# items via a belt unloader. Without this guard, a regular
		# conveyor placed against a stocked container would suck items
		# straight onto the belt — making the belt unloader pointless
		# and turning storage into a passive output station.
		# Exception: landing pads carry the "storage" tag because they
		# stockpile incoming pod cargo, but they're meant to passively
		# feed conveyors / pipes — they're the destination of the
		# logistics chain, not a manual buffer.
		if data and data.tags.has("storage") and not data.tags.has("landing_pad"):
			continue
		var grid_size: Vector2i = data.grid_size if data else Vector2i(1, 1)
		var rot: int = main.building_rotation.get(origin, 0)
		# Omnidirectional blocks push from all four edges regardless of rotation.
		# Landing pads also use the full ring — they don't have a real
		# "input face" (cargo arrives from the sky), so the player
		# should be able to attach belts on any side.
		var output_cells: Array
		if data and (data.tags.has("omnidirectional") or data.tags.has("landing_pad")):
			output_cells = _get_full_ring(origin, grid_size)
		else:
			output_cells = _get_all_output_cells(origin, grid_size, rot)

		var items_to_remove := {}
		for item_id in storage["items"]:
			if int(storage["items"][item_id]) <= 0:
				items_to_remove[item_id] = true
				continue
			for out_pos in output_cells:
				if _is_cross_faction(origin, out_pos):
					continue
				# Don't push onto a conveyor that's feeding INTO this building.
				if _conveyor_feeds_toward_building(out_pos, origin, grid_size):
					continue
				var entry_dir: int = _get_entry_dir_from_building(out_pos, origin, grid_size)
				if _is_conveyor_cell(out_pos) and not conveyor_items.has(out_pos):
					conveyor_items[out_pos] = {
						"item_id": item_id,
						"progress": 0.0,
						"entry_dir": entry_dir,
					}
					storage["items"][item_id] = int(storage["items"][item_id]) - 1
					if int(storage["items"][item_id]) <= 0:
						items_to_remove[item_id] = true
					break
				# Also try pushing directly into cores
				if _is_core_cell(out_pos):
					if _absorb_item(item_id, out_pos):
						storage["items"][item_id] = int(storage["items"][item_id]) - 1
						if int(storage["items"][item_id]) <= 0:
							items_to_remove[item_id] = true
						break
				# Also try pushing directly into an adjacent factory's input
				# buffer. Without this, two omnidirectional factories placed
				# next to each other (e.g. mineral extractor → steel furnace)
				# can't feed each other — the storage would only drain onto
				# belts or cores otherwise.
				if _try_accept_factory_item(out_pos, item_id, entry_dir):
					storage["items"][item_id] = int(storage["items"][item_id]) - 1
					if int(storage["items"][item_id]) <= 0:
						items_to_remove[item_id] = true
					break

		for item_id in items_to_remove:
			storage["items"].erase(item_id)

		# Try to push stored fluids into adjacent pipes.
		# Only fluids the block actually PRODUCES are released — input fluids
		# (e.g. the Graphite Electrolyzer's water) must stay buffered to be
		# consumed, never leaked back out. Blocks with no declared fluid
		# output (pumps, condensers) have an empty product set and drain
		# everything they hold, as before.
		var produced_fluids := {}
		if data:
			var eff_out: Dictionary = _get_effective_outputs(data, origin)
			for oid in eff_out:
				var osn := StringName(oid)
				if Registry.get_fluid(osn) != null:
					produced_fluids[osn] = true
		var has_output_sides: bool = data != null and not data.output_sides.is_empty()
		var fluids_to_remove := {}
		for fluid_id in storage["fluids"]:
			var fsn := StringName(fluid_id)
			if float(storage["fluids"][fluid_id]) <= 0:
				fluids_to_remove[fluid_id] = true
				continue
			# Skip inputs / anything this block doesn't produce.
			if not produced_fluids.is_empty() and not produced_fluids.has(fsn):
				continue
			# Honour output_sides routing: a routed fluid (e.g. hydrogen up /
			# oxygen down) may ONLY exit its configured edge. Unrouted fluids
			# drain to every side (the previous all-directions behaviour, kept
			# so pumps / condensers still feed pipes on any face).
			var fluid_cells: Array = _get_full_ring(origin, grid_size)
			if has_output_sides and data.output_sides.has(fsn):
				# output_sides routes are relative to the block's facing, so
				# rotate them by the building's rotation (see _factory_try_output).
				var wdir: int = (int(data.output_sides[fsn]) + rot) % 4
				fluid_cells = _side_neighbor_cells(origin, grid_size, wdir)
			for neighbor in fluid_cells:
				if _is_cross_faction(origin, neighbor):
					continue
				if _is_pipe_cell(neighbor):
					var from_dir: int = (_get_entry_dir_from_building(neighbor, origin, grid_size) + 2) % 4
					if _add_fluid_to_pipe(neighbor, fluid_id, PIPE_PUSH_AMOUNT, from_dir):
						storage["fluids"][fluid_id] = float(storage["fluids"][fluid_id]) - 1.0
						if float(storage["fluids"][fluid_id]) <= 0:
							fluids_to_remove[fluid_id] = true
						break
				else:
					# Deposit directly into an adjacent factory's fluid input
					# buffer (e.g. electrolyzer oxygen → compound mixer), the
					# same as a pipe would feed it — no pipe required between them.
					var f_entry: int = _get_entry_dir_from_building(neighbor, origin, grid_size)
					if _try_accept_factory_item(neighbor, fluid_id, f_entry):
						storage["fluids"][fluid_id] = float(storage["fluids"][fluid_id]) - 1.0
						if float(storage["fluids"][fluid_id]) <= 0:
							fluids_to_remove[fluid_id] = true
						break

		for fluid_id in fluids_to_remove:
			storage["fluids"].erase(fluid_id)

	for pos in to_clean:
		if block_storage.has(pos):
			var s = block_storage[pos]
			if s["items"].is_empty() and s["fluids"].is_empty():
				block_storage.erase(pos)


# =========================
# BELT UNLOADER (Mindustry-style)
# =========================

## Ticks every belt unloader block. Each tick it:
##   1. Finds an adjacent building with block_storage that has items.
##   2. Pulls one item (respecting the sorter filter if set).
##   3. Pushes it onto an adjacent conveyor facing away from the unloader.
## Uses round-robin so it distributes pulls across multiple source neighbors.
func _update_belt_unloaders(_delta: float) -> void:
	var processed := {}
	for grid_pos in _bucket("unloader"):
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null or not data.tags.has("unloader"):
			continue
		var anchor = main.get_building_anchor(grid_pos)
		var origin: Vector2i = anchor if anchor != null else grid_pos
		if processed.has(origin):
			continue
		processed[origin] = true
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue

		if not belt_unloader_state.has(origin):
			belt_unloader_state[origin] = {"timer": 0.0, "round_robin": 0}
		var state: Dictionary = belt_unloader_state[origin]

		state["timer"] -= _delta
		if state["timer"] > 0:
			continue
		# Unload speed: use the block's transport_speed as items/sec
		var speed: float = data.transport_speed if data.transport_speed > 0 else 4.0
		state["timer"] = 1.0 / speed

		# Item filter (reuses sorter_filters dict — click the unloader to set)
		var filter_id: StringName = sorter_filters.get(origin, &"")

		# Unloader is fully directional: input is the cell directly behind
		# it, output is the cell directly in front. The two perpendicular
		# sides are ignored entirely.
		# Source entries are tagged so the pull step knows which storage to
		# read from: {"anchor": Vector2i, "kind": "block" | "core"}.
		var sources: Array = []
		var sinks: Array[Vector2i] = []
		var rot: int = int(main.building_rotation.get(origin, 0))
		var front_dir: int = rot
		var back_dir: int = (rot + 2) % 4
		for dir_idx in [front_dir, back_dir]:
			var nb: Vector2i = origin + DIR_VECTORS[dir_idx]
			if _is_cross_faction(origin, nb):
				continue
			if not main.placed_buildings.has(nb):
				continue
			var nb_anchor: Vector2i = main.building_origins.get(nb, nb)
			# Front: the only valid sink — must be an empty conveyor cell.
			if dir_idx == front_dir:
				if _is_conveyor_cell(nb) and not conveyor_items.has(nb):
					sinks.append(nb)
				continue
			# Skip neighbours mid-construction — they shouldn't leak items.
			if main.has_method("is_building_inactive") and main.is_building_inactive(nb_anchor):
				continue
			# Source (core): unloader pulls from the LUMINA pool when adjacent
			# to a player core, FEROX pool when adjacent to an enemy core.
			if _is_core_cell(nb_anchor):
				sources.append({"anchor": nb_anchor, "kind": "core"})
				continue
			# Source (block_storage): any building that owns its storage and
			# legitimately outputs items. Turrets store ammo as an INPUT
			# buffer (combat_system consumes from it on fire) — letting the
			# unloader pull from there would cycle ammo back onto the same
			# belt that fed it. Same principle for any future input-only
			# storage block.
			if block_storage.has(nb_anchor) and not block_storage[nb_anchor]["items"].is_empty():
				var nb_data = Registry.get_block(main.placed_buildings.get(nb_anchor, &""))
				if nb_data == null:
					continue
				if nb_data.is_turret():
					continue
				sources.append({"anchor": nb_anchor, "kind": "block"})

		if sources.is_empty() or sinks.is_empty():
			continue

		# Round-robin across sources
		var rr: int = state["round_robin"] % sources.size()
		state["round_robin"] = rr + 1
		var src_entry: Dictionary = sources[rr]
		var src: Vector2i = src_entry["anchor"]
		var src_kind: String = src_entry["kind"]

		# Pick the first matching item (or any item if no filter).
		var pulled_id: StringName = &""
		var src_pool: Dictionary = {}
		if src_kind == "core":
			# Pick the right faction pool for the core we're adjacent to.
			var face: int = main.get_building_faction(src) if main.has_method("get_building_faction") else 0
			var ferox_face_value: int = 1
			if "Faction" in main and "FEROX" in main.Faction:
				ferox_face_value = int(main.Faction.FEROX)
			if face == ferox_face_value and "ferox_resources" in main:
				src_pool = main.ferox_resources
			else:
				src_pool = main.resources
		else:
			src_pool = block_storage[src]["items"]

		if filter_id != &"":
			if src_pool.has(filter_id) and int(src_pool[filter_id]) > 0:
				pulled_id = filter_id
		else:
			for item_id in src_pool:
				if int(src_pool[item_id]) > 0:
					pulled_id = item_id
					break
		if pulled_id == &"":
			continue

		# Push onto the first open sink
		var pushed := false
		for sink_pos in sinks:
			if conveyor_items.has(sink_pos):
				continue
			var entry_dir: int = -1
			for d in range(4):
				if origin + DIR_VECTORS[d] == sink_pos:
					entry_dir = (d + 2) % 4
					break
			conveyor_items[sink_pos] = {
				"item_id": pulled_id,
				"progress": 0.0,
				"entry_dir": entry_dir,
			}
			pushed = true
			break
		if pushed:
			src_pool[pulled_id] = int(src_pool[pulled_id]) - 1
			if int(src_pool[pulled_id]) <= 0:
				src_pool.erase(pulled_id)
			# Cores: emit the resources_changed signal so HUD totals + the
			# storage-cap recompute fire immediately, the same way
			# core-absorption does.
			if src_kind == "core":
				if main.has_signal("resources_changed") and src_pool == main.resources:
					main.resources_changed.emit(main.resources)
				elif main.has_signal("ferox_resources_changed") and "ferox_resources" in main and src_pool == main.ferox_resources:
					main.ferox_resources_changed.emit(main.ferox_resources)


# =========================
# CORE ABSORPTION
# =========================

## Adds one unit of the item to the appropriate resource pool.
## Ferox cores feed the ferox pool; Lumina cores feed the player pool.
## Tries to absorb an item into core storage. Returns true if accepted, false if full.
func _absorb_item(item_id: StringName, core_grid_pos: Vector2i = Vector2i(-1, -1)) -> bool:
	# Refuse deposits into a core that isn't fully built (under
	# construction or actively being deconstructed). Returning false
	# backs the conveyor up and the drone retries against the next
	# valid core.
	if core_grid_pos != Vector2i(-1, -1) \
			and main.has_method("is_building_inactive") and main.is_building_inactive(core_grid_pos):
		return false
	var is_ferox := false
	if core_grid_pos != Vector2i(-1, -1):
		is_ferox = main.get_building_faction(core_grid_pos) == main.Faction.FEROX

	if is_ferox:
		if "ferox_resources" in main:
			if main.ferox_resources.has(item_id):
				main.ferox_resources[item_id] += 1
			else:
				main.ferox_resources[item_id] = 1
			if main.has_signal("ferox_resources_changed"):
				main.ferox_resources_changed.emit(main.ferox_resources)
	else:
		# Check storage capacity before accepting
		if main.has_method("can_accept_resource") and not main.can_accept_resource(item_id):
			return false
		if main.resources.has(item_id):
			main.resources[item_id] += 1
		else:
			main.resources[item_id] = 1
		main.resources_changed.emit(main.resources)

	if main.has_signal("item_absorbed_in_core"):
		main.item_absorbed_in_core.emit(item_id)
	return true


# =========================
# CELL TYPE CHECKS
# =========================

## Returns true if the cell has an item transport (conveyor/belt, NOT pipes or payloads).
func _is_conveyor_cell(grid_pos: Vector2i) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null:
		return false
	# Payload/freight conveyors are NOT regular conveyors
	if data.tags.has("payload") or data.tags.has("freight"):
		return false
	return data.is_transport() and not data.transports_fluid


## Returns true if the cell at conv_pos is a conveyor whose direction points
## TOWARD toward_pos (i.e. the conveyor is feeding that neighbor). Used to
## prevent a factory from trying to output onto a conveyor that is already
## pushing items into it — that would create a deadlock.
func _conveyor_feeds_into(conv_pos: Vector2i, toward_pos: Vector2i) -> bool:
	if not _is_conveyor_cell(conv_pos):
		return false
	var rot: int = main.building_rotation.get(conv_pos, 0)
	var forward: Vector2i = DIR_VECTORS[rot % 4]
	return conv_pos + forward == toward_pos


## Returns true if the cell has a fluid transport (pipe, NOT pumps).
func _is_pipe_cell(grid_pos: Vector2i) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null:
		return false
	return data.is_transport() and data.transports_fluid and not data.tags.has("pump")


## Returns true if the cell is a router (splits items to 3 outputs like Mindustry).
func _is_router_cell(grid_pos: Vector2i) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null:
		return false
	return data.tags.has("router")


func _has_block_tag(grid_pos: Vector2i, tag: String) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	return data != null and data.tags.has(tag)


func _is_bridge_cell(grid_pos: Vector2i) -> bool:
	return _has_block_tag(grid_pos, "bridge")


func _is_junction_cell(grid_pos: Vector2i) -> bool:
	return _has_block_tag(grid_pos, "junction")


func _is_sorter_cell(grid_pos: Vector2i) -> bool:
	return _has_block_tag(grid_pos, "sorter")


func _is_inverted_sorter_cell(grid_pos: Vector2i) -> bool:
	return _has_block_tag(grid_pos, "inverted_sorter")


func _is_overflow_cell(grid_pos: Vector2i) -> bool:
	return _has_block_tag(grid_pos, "overflow")


func _is_underflow_cell(grid_pos: Vector2i) -> bool:
	return _has_block_tag(grid_pos, "underflow")


## Returns true if the cell is a payload/freight transport (has "payload" or "freight" tag + transport_speed > 0).
func _is_payload_cell(grid_pos: Vector2i) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null:
		return false
	return (data.tags.has("payload") or data.tags.has("freight")) and data.transport_speed > 0



func _is_core_cell(grid_pos: Vector2i) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null:
		return false
	return data.category == BlockData.BlockCategory.CORE


func _is_incinerator_cell(grid_pos: Vector2i) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null:
		return false
	return data.tags.has("incinerator")


# =========================
# BUILDING EVENTS
# =========================

func _on_building_placed(block_id: StringName, grid_pos: Vector2i) -> void:
	# Structural change — the role buckets must be rebuilt before next use.
	_buckets_dirty = true
	_pipe_net_dirty = true
	var data = Registry.get_block(block_id)
	if data == null:
		return

	# `building_placed` also fires for in-place rotations of an existing
	# block (same id, same position). In that case the logistics state
	# tables are already populated with the player's work-in-progress
	# (constructor's selected block, loader's target fill, held payloads,
	# timers, etc.) and must be preserved — only initialise entries that
	# don't already exist. `_on_building_destroyed` handles the opposite
	# direction (full erase) when the block actually goes away.

	# Pre-initialize the drill timer so it starts counting immediately
	if data.tags.has("harvester"):
		if not drill_timers.has(grid_pos):
			var cycle_time = data.production_time if data.production_time > 0 else default_drill_time
			drill_timers[grid_pos] = cycle_time

	# Pre-initialize the pump timer
	if data.tags.has("pump"):
		if not pump_timers.has(grid_pos):
			var cycle_time = data.production_time if data.production_time > 0 else default_drill_time
			pump_timers[grid_pos] = cycle_time

	# Pre-initialize constructor state
	if data.tags.has("constructor"):
		if not constructor_state.has(grid_pos):
			constructor_state[grid_pos] = {
				"selected_block": &"",
				"collected": {},
				"phase": "waiting",
				"timer": 0.0,
			}

	# Pre-initialize deconstructor state
	if data.tags.has("deconstructor"):
		if not deconstructor_state.has(grid_pos):
			deconstructor_state[grid_pos] = {
				"payload": null,
				"phase": "idle",
				"timer": 0.0,
				"pending_items": {},
			}

	# Pre-initialize loader state
	if data.tags.has("payload_loader") or data.tags.has("freight_loader"):
		if not loader_state.has(grid_pos):
			loader_state[grid_pos] = {
				"payload": null,
				"phase": "idle",
				"fill_target": {},
			}

	# Pre-initialize unloader state
	if data.tags.has("payload_unloader") or data.tags.has("freight_unloader"):
		if not unloader_state.has(grid_pos):
			unloader_state[grid_pos] = {
				"payload": null,
				"phase": "idle",
			}


func _on_building_destroyed(grid_pos: Vector2i) -> void:
	# Structural change — the role buckets must be rebuilt before next use.
	_buckets_dirty = true
	_pipe_net_dirty = true
	conveyor_items.erase(grid_pos)
	pipe_contents.erase(grid_pos)
	drill_timers.erase(grid_pos)
	pump_timers.erase(grid_pos)
	extractor_efficiency.erase(grid_pos)
	factory_buffers.erase(grid_pos)
	block_storage.erase(grid_pos)
	router_output_index.erase(grid_pos)
	junction_items.erase(grid_pos)
	sorter_filters.erase(grid_pos)
	sorter_side_index.erase(grid_pos)
	payload_items.erase(grid_pos)
	payload_router_idx.erase(grid_pos)
	constructor_state.erase(grid_pos)
	deconstructor_state.erase(grid_pos)
	refabricator_state.erase(grid_pos)
	upgrader_state.erase(grid_pos)
	refit_state.erase(grid_pos)
	source_resource.erase(grid_pos)
	source_payload.erase(grid_pos)
	loader_state.erase(grid_pos)
	unloader_state.erase(grid_pos)
	mass_driver_state.erase(grid_pos)
	belt_unloader_state.erase(grid_pos)
	# Duct-bridge state cleanup: filter + round-robin index.
	duct_bridge_filters.erase(grid_pos)
	bridge_output_rr.erase(grid_pos)
	# Drop any in-flight projectiles to/from this driver
	for i in range(mass_driver_projectiles.size() - 1, -1, -1):
		var proj: Dictionary = mass_driver_projectiles[i]
		if proj.get("target_origin") == grid_pos or proj.get("source_origin") == grid_pos:
			mass_driver_projectiles.remove_at(i)


## A finished build flips its cell from inactive to active, which adds it to
## the live pipe partition — so invalidate the cached networks.
func _on_building_completed_for_pipes(_block_id: StringName, _grid_pos: Vector2i) -> void:
	_pipe_net_dirty = true


# =========================
# CONSTRUCTOR LOGIC
# =========================

## Tries to accept an item into a constructor's collection buffer.
## Constructors accept items from ALL sides (no directional restriction).
## Returns true if the item was accepted.
func _try_accept_constructor_item(grid_pos: Vector2i, item_id: StringName) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null or not data.tags.has("constructor"):
		return false

	# Find the building's origin for multi-tile constructors
	var anchor = main.get_building_anchor(grid_pos)
	var origin: Vector2i = anchor if anchor != null else grid_pos

	if not constructor_state.has(origin):
		return false

	var state = constructor_state[origin]

	# Only accept during "collecting" phase
	if state["phase"] != "collecting":
		return false

	var selected: StringName = state["selected_block"]
	if selected == &"":
		return false

	var target_data = Registry.get_block(selected)
	if target_data == null:
		return false

	# Check if this item is part of the build_cost
	# Build costs use short keys like "copper", items use "mat_copper"
	var needed: int = 0
	var cost_key: String = ""
	for raw_id in target_data.build_cost:
		var sn_raw := StringName(raw_id)
		# Match directly or with "mat_" prefix
		if sn_raw == item_id or StringName("mat_" + str(raw_id)) == item_id:
			needed = int(target_data.build_cost[raw_id])
			cost_key = str(raw_id)
			break

	if needed <= 0:
		return false  # Item not required

	# Use the cost_key for tracking (consistent with build_cost keys)
	var have: int = state["collected"].get(StringName(cost_key), 0)
	if have >= needed:
		return false  # Already have enough of this item

	state["collected"][StringName(cost_key)] = have + 1
	return true


## Tries to feed an item into a turret as ammo. The turret accepts the item
## from any side (no direction restriction) iff the item id matches one of
## the turret's AmmoType entries AND the turret has spare storage capacity.
## Items are stored in block_storage[anchor]["items"] just like every other
## building, so combat_system can pull them out via remove_from_storage.
## Pipe-side fluid intake for non-factory blocks. Any block that lists
## a booster matching `fluid_id` AND has `liquid_capacity > 0`
## accepts the fluid into `block_storage[anchor]["fluids"]`, capped by
## `liquid_capacity`. This is what lets a turret / crane sip water
## from an adjacent pipe even though it has no factory `side_inputs`.
func _try_accept_booster_fluid(grid_pos: Vector2i, fluid_id: StringName) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null:
		return false
	# Launchpad: accepts any fluid into its passenger buffer, capped by
	# liquid_capacity. The booster-table check below would reject this,
	# so handle it up front.
	if data.tags.has("launchpad"):
		if data.liquid_capacity <= 0:
			return false
		var lp_anchor = main.get_building_anchor(grid_pos)
		var lp_origin: Vector2i = lp_anchor if lp_anchor != null else grid_pos
		if not block_storage.has(lp_origin):
			block_storage[lp_origin] = {"items": {}, "fluids": {}}
		var lp_storage: Dictionary = block_storage[lp_origin]
		var lp_fluids: Dictionary = lp_storage.get("fluids", {})
		var lp_total: float = 0.0
		for k in lp_fluids:
			lp_total += float(lp_fluids[k])
		if lp_total >= float(data.liquid_capacity):
			return false
		lp_fluids[fluid_id] = float(lp_fluids.get(fluid_id, 0.0)) + 1.0
		lp_storage["fluids"] = lp_fluids
		block_storage[lp_origin] = lp_storage
		return true
	# Turret fluid-ammo intake: a turret whose ammo_types reference this fluid
	# (Corrosion → acid, Fume → sulfur fumes) draws it straight from an
	# adjacent pipe into its fluid buffer, capped by liquid_capacity. This is
	# separate from the booster table below (no passive per-second drain).
	if data.is_turret() and data.liquid_capacity > 0 and not data.ammo_types.is_empty():
		# Accept any fluid the ammo needs — primary OR extra_cost (the Eclipse
		# beam needs oxygen + hydrogen together, so both must flow in).
		if data.ammo_accepts(fluid_id):
			var t_anchor = main.get_building_anchor(grid_pos)
			var t_origin: Vector2i = t_anchor if t_anchor != null else grid_pos
			if not block_storage.has(t_origin):
				block_storage[t_origin] = {"items": {}, "fluids": {}}
			var t_storage: Dictionary = block_storage[t_origin]
			if not t_storage.has("fluids"):
				t_storage["fluids"] = {}
			var t_fluids: Dictionary = t_storage["fluids"]
			# One ammo type at a time: reject if a fluid from a DIFFERENT ammo
			# group is already loaded (so a Spritz holding water won't also take
			# slag). A combined ammo_type's co-required fluids (the Cutter's
			# oxygen + hydrogen) share a group, so they're allowed together.
			var grp: Array = data.ammo_group_ids(fluid_id)
			for f in t_fluids:
				if float(t_fluids[f]) > 0.0 and not grp.has(f):
					return false
			# Cap PER FLUID (not total) so a turret needing two distinct ammo
			# fluids gives each its own liquid_capacity buffer — otherwise the
			# first fluid fills the shared cap and starves the second.
			if float(t_fluids.get(fluid_id, 0.0)) >= float(data.liquid_capacity):
				return false
			t_fluids[fluid_id] = float(t_fluids.get(fluid_id, 0.0)) + 1.0
			t_storage["fluids"] = t_fluids
			block_storage[t_origin] = t_storage
			return true

	if data.liquid_capacity <= 0 or data.boosters.is_empty():
		return false
	# Match against the booster table: at least one entry must reference
	# this fluid id, otherwise the block has no business storing it.
	var accepted := false
	for entry in data.boosters:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if StringName(entry.get("item_id", &"")) == fluid_id:
			accepted = true
			break
	if not accepted:
		return false
	# Multi-tile blocks share one buffer at the anchor.
	var anchor = main.get_building_anchor(grid_pos)
	var origin: Vector2i = anchor if anchor != null else grid_pos
	if not block_storage.has(origin):
		block_storage[origin] = {"items": {}, "fluids": {}}
	var storage: Dictionary = block_storage[origin]
	if not storage.has("fluids"):
		storage["fluids"] = {}
	var fluids: Dictionary = storage["fluids"]
	# Respect the building's liquid_capacity cap so a single pipe
	# can't overflow the buffer.
	var total: float = 0.0
	for k in fluids:
		total += float(fluids[k])
	if total >= float(data.liquid_capacity):
		return false
	fluids[fluid_id] = float(fluids.get(fluid_id, 0.0)) + 1.0
	storage["fluids"] = fluids
	block_storage[origin] = storage
	return true


func _try_accept_turret_ammo(grid_pos: Vector2i, item_id: StringName) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null or not data.is_turret():
		return false
	if data.ammo_types.is_empty():
		return false

	# Confirm the item matches one of the turret's accepted ammos (primary or
	# extra_cost, e.g. the Protium's silicon).
	if not data.ammo_accepts(item_id):
		return false

	# Resolve to the turret's anchor for multi-tile turrets.
	var anchor = main.get_building_anchor(grid_pos)
	var origin: Vector2i = anchor if anchor != null else grid_pos

	# Initialise storage on demand.
	if not block_storage.has(origin):
		block_storage[origin] = {"items": {}, "fluids": {}}
	var storage: Dictionary = block_storage[origin]
	if not storage.has("items"):
		storage["items"] = {}

	# Respect the building's max_stored_items cap (default to 30 for turrets
	# if the .tres didn't specify one).
	var cap: int = data.max_stored_items if data.max_stored_items > 0 else 30
	var current_total: int = 0
	for k in storage["items"]:
		current_total += int(storage["items"][k])
	if current_total >= cap:
		return false

	storage["items"][item_id] = int(storage["items"].get(item_id, 0)) + 1
	return true


## Processes all constructors: collecting → building → output payload.
func _update_constructors(delta: float) -> void:
	var processed := {}

	for grid_pos in _bucket("constructor"):
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null or not data.tags.has("constructor"):
			continue

		var anchor = main.get_building_anchor(grid_pos)
		var origin: Vector2i = anchor if anchor != null else grid_pos
		if processed.has(origin):
			continue
		processed[origin] = true

		# Skip disabled or under-construction buildings
		var sector_script = _sector_script_ref()
		if sector_script and sector_script.is_building_disabled(origin):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue

		if not constructor_state.has(origin):
			constructor_state[origin] = {
				"selected_block": &"",
				"collected": {},
				"phase": "waiting",
				"timer": 0.0,
			}

		var state = constructor_state[origin]

		match state["phase"]:
			"waiting":
				# Idle — waiting for player to select a block via UI
				pass

			"collecting":
				var selected: StringName = state["selected_block"]
				if selected == &"":
					state["phase"] = "waiting"
					continue

				var target_data = Registry.get_block(selected)
				if target_data == null:
					state["phase"] = "waiting"
					state["selected_block"] = &""
					continue

				# Check if all build_cost items have been collected
				var all_met := true
				for raw_id in target_data.build_cost:
					var sn_id := StringName(raw_id)
					var needed: int = int(target_data.build_cost[raw_id])
					if state["collected"].get(sn_id, 0) < needed:
						all_met = false
						break

				if all_met:
					# Don't pre-consume — items drain gradually during the
					# building phase so the player can see materials being
					# spent in step with the on-block reveal animation.
					state["phase"] = "building"
					state["timer"] = target_data.build_time if target_data.build_time > 0 else 2.0
					state["paid"] = {}

			"building":
				var selected_b: StringName = state["selected_block"]
				var target_data_b = Registry.get_block(selected_b)
				if target_data_b == null:
					state["phase"] = "waiting"
					state["selected_block"] = &""
					continue
				var bt: float = target_data_b.build_time if target_data_b.build_time > 0 else 2.0
				if not state.has("paid") or not (state["paid"] is Dictionary):
					state["paid"] = {}
				# Compute how many of each item should have been paid by
				# the time the next tick lands. If we can pay the delta,
				# advance the timer and decrement `collected`. Otherwise
				# stall — the player gets a stalled-build visual without
				# losing any items they haven't covered yet.
				var bt_safe: float = maxf(bt, 0.0001)
				var done_pct_next: float = clampf((bt - (state["timer"] - delta)) / bt_safe, 0.0, 1.0)
				var to_pay: Dictionary = {}
				var enough := true
				for raw_id_b in target_data_b.build_cost:
					var sn_id_b := StringName(raw_id_b)
					var total_b: int = int(target_data_b.build_cost[raw_id_b])
					var need_b: int = int(ceil(float(total_b) * done_pct_next))
					var paid_b: int = int(state["paid"].get(sn_id_b, 0))
					var delta_pay: int = need_b - paid_b
					if delta_pay <= 0:
						continue
					var have_b: int = int(state["collected"].get(sn_id_b, 0))
					if have_b < delta_pay:
						enough = false
						break
					to_pay[sn_id_b] = delta_pay
				if not enough:
					# Hold the timer here — wait for the missing items.
					continue
				state["timer"] -= delta
				for sn_pay in to_pay:
					state["collected"][sn_pay] = int(state["collected"][sn_pay]) - int(to_pay[sn_pay])
					if int(state["collected"][sn_pay]) <= 0:
						state["collected"].erase(sn_pay)
					state["paid"][sn_pay] = int(state["paid"].get(sn_pay, 0)) + int(to_pay[sn_pay])
				if state["timer"] <= 0:
					# Build complete — try to output a building payload
					var selected: StringName = state["selected_block"]
					var target_data = Registry.get_block(selected)
					if target_data == null:
						state["phase"] = "waiting"
						state["selected_block"] = &""
						continue

					# Create payload data for the constructed building
					var payload := {
						"type": "building",
						"block_id": str(selected),
						"rotation": 0,
						"health": target_data.max_health,
						"faction": main.get_building_faction(origin),
						"stored_items": {},
						"stored_fluids": {},
						"grid_size_x": target_data.grid_size.x,
						"grid_size_y": target_data.grid_size.y,
					}

					# Try to push payload onto front-facing payload conveyors only
					var rot: int = main.building_rotation.get(origin, 0)
					var front_cells: Array[Vector2i] = _get_front_edge(origin, data.grid_size, rot)
					var pushed := false
					for out_pos in front_cells:
						if _is_cross_faction(origin, out_pos):
							continue
						var entry_dir := _get_entry_dir_from_building(out_pos, origin, data.grid_size)
						if _try_push_payload(out_pos, payload, entry_dir):
							pushed = true
							break

					if pushed:
						# Return to collecting — keep selected block for continuous production
						state["phase"] = "collecting"
						state["paid"] = {}
					# else: stall — payload conveyor is full, try again next frame


# =========================
# DECONSTRUCTOR LOGIC
# =========================

## Processes all deconstructors: accept payload → deconstruct → output items.
## Resolves a build-cost key ("copper") to the Registry item id ("mat_copper").
## Build-cost dicts use short names; item ids are prefixed.
func _resolve_refund_key(raw_id) -> StringName:
	var item_key := StringName(raw_id)
	if not Registry.get_item(item_key):
		var prefixed := StringName("mat_" + str(raw_id))
		if Registry.get_item(prefixed):
			item_key = prefixed
	return item_key


func _update_deconstructors(delta: float) -> void:
	var processed := {}

	for grid_pos in _bucket("deconstructor"):
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null or not data.tags.has("deconstructor"):
			continue

		var anchor = main.get_building_anchor(grid_pos)
		var origin: Vector2i = anchor if anchor != null else grid_pos
		if processed.has(origin):
			continue
		processed[origin] = true

		# Skip disabled or under-construction buildings
		var sector_script = _sector_script_ref()
		if sector_script and sector_script.is_building_disabled(origin):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue

		if not deconstructor_state.has(origin):
			deconstructor_state[origin] = {
				"payload": null,
				"phase": "idle",
				"timer": 0.0,
				"pending_items": {},
			}

		var state = deconstructor_state[origin]

		match state["phase"]:
			"idle":
				# Try to accept a payload from front-facing payload conveyors only
				var rot: int = main.building_rotation.get(origin, 0)
				var front_cells: Array[Vector2i] = _get_front_edge(origin, data.grid_size, rot)
				for edge_pos in front_cells:
					if _is_cross_faction(origin, edge_pos):
						continue
					# Find the conveyor anchor at this cell (payloads are keyed by anchor)
					var conv_anchor: Vector2i = main.building_origins.get(edge_pos, edge_pos)
					if not payload_items.has(conv_anchor):
						continue
					if payload_items[conv_anchor]["progress"] < 1.0:
						continue

					var payload_data: Dictionary = payload_items[conv_anchor]["payload_data"]
					# Accept the payload
					state["payload"] = payload_data
					state["phase"] = "deconstructing"

					# Determine deconstruction time from the payload's block data
					var decon_time := 2.0
					if payload_data.get("type", "") == "building":
						var target_id := StringName(payload_data.get("block_id", ""))
						var target_data = Registry.get_block(target_id)
						if target_data != null and target_data.build_time > 0:
							decon_time = target_data.build_time
					state["timer"] = decon_time

					# Remove payload from conveyor (keyed by conveyor anchor)
					payload_items.erase(conv_anchor)
					break

			"deconstructing":
				state["timer"] -= delta
				if state["timer"] <= 0:
					var payload_data: Dictionary = state["payload"]
					if payload_data == null:
						state["phase"] = "idle"
						continue

					# Units: refund the unit's own build_cost, mirroring how
					# building deconstruction refunds the block's build_cost
					# below. (Previously the deconstructor cribbed the
					# fabricator's `input_items`, which sometimes paid out a
					# different set of items than the unit was actually
					# crafted from.)
					if payload_data.get("type", "") == "unit":
						var unit_id := StringName(payload_data.get("unit_id", ""))
						var unit_data: UnitData = Registry.get_unit(unit_id)
						var pending := {}
						# Unit's own build cost.
						if unit_data != null:
							for raw_id in unit_data.build_cost:
								var k: StringName = _resolve_refund_key(raw_id)
								pending[k] = int(pending.get(k, 0)) + int(unit_data.build_cost[raw_id])
						# PLUS the build cost of every upgrade applied to the unit
						# — deconstructing a kitted unit returns its modules' cost too.
						for up_id in payload_data.get("applied_upgrades", []):
							var up_data = Registry.get_block(StringName(up_id))
							if up_data == null:
								continue
							for raw_id in up_data.build_cost:
								var k: StringName = _resolve_refund_key(raw_id)
								pending[k] = int(pending.get(k, 0)) + int(up_data.build_cost[raw_id])
						if not pending.is_empty():
							state["pending_items"] = pending
							state["phase"] = "outputting"
						else:
							state["phase"] = "idle"
						state["payload"] = null
						continue

					# Buildings: recover build_cost items
					var target_id := StringName(payload_data.get("block_id", ""))
					var target_data = Registry.get_block(target_id)
					if target_data != null and not target_data.build_cost.is_empty():
						var pending := {}
						for raw_id in target_data.build_cost:
							# Build cost keys use short names ("copper"), items use "mat_copper"
							var item_key := StringName(raw_id)
							if not Registry.get_item(item_key):
								var prefixed := StringName("mat_" + str(raw_id))
								if Registry.get_item(prefixed):
									item_key = prefixed
							pending[item_key] = int(target_data.build_cost[raw_id])
						state["pending_items"] = pending
						state["phase"] = "outputting"
					else:
						# No build cost — nothing to output
						state["payload"] = null
						state["phase"] = "idle"

			"outputting":
				var rot: int = main.building_rotation.get(origin, 0)
				var output_cells = _get_all_output_cells(origin, data.grid_size, rot)
				var delivered := []

				for item_id in state["pending_items"]:
					var remaining: int = state["pending_items"][item_id]
					if remaining <= 0:
						delivered.append(item_id)
						continue

					for out_pos in output_cells:
						if _is_cross_faction(origin, out_pos):
							continue
						var entry_dir := _get_entry_dir_from_building(out_pos, origin, data.grid_size)
						if _try_push_item(out_pos, item_id, entry_dir):
							remaining -= 1
							state["pending_items"][item_id] = remaining
							if remaining <= 0:
								delivered.append(item_id)
							break  # One item per output cell per frame

				for item_id in delivered:
					state["pending_items"].erase(item_id)

				if state["pending_items"].is_empty():
					state["payload"] = null
					state["phase"] = "idle"


## Returns all cells on the perimeter of a building (adjacent outside cells).
func _get_all_perimeter_cells(origin: Vector2i, grid_size: Vector2i) -> Array[Vector2i]:
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


# =========================
# LOADER LOGIC
# =========================

## Processes all loaders: accept storage payload → fill from conveyors → output.
## Tier-upgrade lookup: finds the unit whose tech-tree parent list includes
## the given tier-1 unit id. First hit that resolves to an actual UnitData
## wins (guards against pointing at a building/material node that merely
## happens to inherit from this unit). Result is cached.
var _refab_tier_cache: Dictionary = {}  # StringName -> StringName
func _get_tier2_unit(tier1_unit: StringName) -> StringName:
	if tier1_unit == &"":
		return &""
	if _refab_tier_cache.has(tier1_unit):
		return _refab_tier_cache[tier1_unit]
	var result: StringName = &""
	if TechTree.nodes.has(tier1_unit):
		for node_id in TechTree.nodes:
			var node = TechTree.nodes[node_id]
			var parents: Array = node.get("parents", [])
			if not parents.has(tier1_unit):
				continue
			if Registry.get_unit(node_id) != null:
				result = node_id
				break
	_refab_tier_cache[tier1_unit] = result
	return result


## Runs refabricators: pulls a tier-1 unit payload from an adjacent
## payload conveyor, waits for input_items to accumulate, then processes
## and ejects a tier-2 unit payload. Items enter via the standard
## factory_buffers pipeline (omnidirectional).
func _update_refabricators(delta: float) -> void:
	var processed := {}
	var gs: float = main.GRID_SIZE

	for grid_pos in _bucket("refabricator"):
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null or not data.tags.has("refabricator"):
			continue

		var anchor = main.get_building_anchor(grid_pos)
		var origin: Vector2i = anchor if anchor != null else grid_pos
		if processed.has(origin):
			continue
		processed[origin] = true

		# Skip disabled / under-construction buildings.
		var sector_script = _sector_script_ref()
		if sector_script and sector_script.is_building_disabled(origin):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue

		# Electrical efficiency throttles the *processing* timer only; the
		# rest of the state machine (payload pickup, item buffering,
		# output ejection) runs without power so an unpowered refabricator
		# still accepts input and holds state until power returns.
		var power_sys_r = _power_sys_ref()
		var refab_eff: float = 1.0
		if power_sys_r and data.electrical_power_use > 0:
			refab_eff = power_sys_r.get_electrical_efficiency(origin)

		# Lazy state init.
		if not refabricator_state.has(origin):
			refabricator_state[origin] = {
				"phase": "idle",
				"in_unit_id": &"",
				"timer": 0.0,
				"out_unit_id": &"",
				"selected_t2": &"",
			}
		elif not refabricator_state[origin].has("selected_t2"):
			# Back-compat for saves from before the selection menu existed.
			refabricator_state[origin]["selected_t2"] = &""
		# Factory buffer init — used to buffer item inputs that arrived via
		# conveyor before the refabricator had a unit to upgrade.
		if not factory_buffers.has(origin):
			factory_buffers[origin] = {
				"inputs": {},
				"phase": "collecting",
				"timer": 0.0,
				"pending_outputs": {},
			}

		var state = refabricator_state[origin]
		var item_buf: Dictionary = factory_buffers[origin]["inputs"]

		var rot_r: int = main.building_rotation.get(origin, 0)
		# Refabricators accept the input unit payload on any side — the
		# block description promises as much and players routinely drop
		# the tier-1 unit in from whatever side their factory happens to
		# face. The front edge is still reserved for OUTPUT (where the
		# tier-2 unit is pushed / spawned), but the tier-1 pickup scan
		# covers the full ring so a conveyor feeding in from the "front"
		# side of a newly-placed refab still works.
		var input_cells: Array[Vector2i] = _get_full_ring(origin, data.grid_size)
		var output_cells: Array[Vector2i] = _get_front_edge(origin, data.grid_size, rot_r)

		match state["phase"]:
			"idle":
				# Without a tier-2 selection the refab is dormant — it
				# won't accept units or buffer items. Prevents a fresh
				# refab from silently eating the first ant that wanders
				# by before the player configures it.
				var selected_t2: StringName = StringName(state.get("selected_t2", &""))
				if selected_t2 == &"":
					continue
				# Don't consume a tier-1 unit when the tier-2 slot is full
				# for this faction — there'd be nowhere for the upgraded
				# unit to spawn, and eating the tier-1 anyway would be a
				# silent unit-count regression.
				var refab_faction: int = main.get_building_faction(origin)
				if refab_faction != main.Faction.FEROX:
					if main.has_method("can_spawn_unit") and not main.can_spawn_unit(selected_t2):
						continue
				# Pull a unit payload from any adjacent payload conveyor.
				# Only the tier-1 that upgrades to the selected tier-2 is
				# accepted — other payloads stay on the belt so they can
				# pass through to their intended refab.
				for edge_pos in input_cells:
					if _is_cross_faction(origin, edge_pos):
						continue
					var conv_anchor: Vector2i = main.building_origins.get(edge_pos, edge_pos)
					if not payload_items.has(conv_anchor):
						continue
					if payload_items[conv_anchor]["progress"] < 1.0:
						continue
					var pd: Dictionary = payload_items[conv_anchor]["payload_data"]
					if pd.get("type", "") != "unit":
						continue
					var uid := StringName(pd.get("unit_id", ""))
					if uid == &"":
						continue
					# Only accept the tier-1 that upgrades to the refab's
					# selected tier-2.
					if _get_tier2_unit(uid) != selected_t2:
						continue
					state["in_unit_id"] = uid
					payload_items.erase(conv_anchor)
					# Check if items are already buffered — if so, start
					# processing immediately; otherwise wait for them.
					var recipe_idle: Dictionary = _refab_effective_recipe(data, selected_t2)
					if _refab_has_all_inputs_dict(recipe_idle, item_buf):
						state["timer"] = data.production_time if data.production_time > 0 else 5.0
						state["timer_total"] = state["timer"]
						state["recipe_consumed"] = {}
						state["phase"] = "processing"
					else:
						state["phase"] = "collecting"
					break

			"collecting":
				var selected_t2_c: StringName = StringName(state.get("selected_t2", &""))
				var recipe_c: Dictionary = _refab_effective_recipe(data, selected_t2_c)
				# We have a unit — wait for input_items to accumulate.
				if _refab_has_all_inputs_dict(recipe_c, item_buf):
					state["timer"] = data.production_time if data.production_time > 0 else 5.0
					state["timer_total"] = state["timer"]
					state["recipe_consumed"] = {}
					state["phase"] = "processing"

			"processing":
				# Drain materials gradually so the buffer visibly empties
				# while the upgrade runs. Stall the timer when the buffer
				# can't afford the next step (e.g. player withdrew items
				# from the storage popup mid-build) so progress matches
				# what's been paid for.
				var _sel_t2_p: StringName = StringName(state.get("selected_t2", &""))
				var _recipe_p: Dictionary = _refab_effective_recipe(data, _sel_t2_p)
				var _t_total_r: float = float(state.get("timer_total", state["timer"] + 0.0001))
				if _t_total_r <= 0.0:
					_t_total_r = 0.0001
				if not state.has("recipe_consumed"):
					state["recipe_consumed"] = {}
				var _tentative_timer_r: float = state["timer"] - delta * refab_eff
				var _new_prog_r: float = clampf(1.0 - _tentative_timer_r / _t_total_r, 0.0, 1.0)
				if _can_afford_progress(item_buf, _recipe_p, state["recipe_consumed"], _new_prog_r):
					state["timer"] = _tentative_timer_r
					_consume_progressive(item_buf, _recipe_p, state["recipe_consumed"], _new_prog_r)
				if state["timer"] <= 0.0:
					_consume_progressive(item_buf, _recipe_p, state["recipe_consumed"], 1.0)
					# Prefer the explicit selection; fall back to the
					# tech-tree lookup if the selection is somehow empty.
					var t2_out: StringName = StringName(state.get("selected_t2", &""))
					if t2_out == &"":
						t2_out = _get_tier2_unit(state["in_unit_id"])
					state["out_unit_id"] = t2_out
					state["in_unit_id"] = &""
					state["phase"] = "outputting"

			"outputting":
				var out_id: StringName = StringName(state.get("out_unit_id", &""))
				# Recover from a half-loaded save / any state where we ended
				# up in "outputting" with no out_unit_id: derive it from the
				# in_unit_id (tier-1) → tier-2 mapping if possible, or bail
				# back to idle. Mirrors the tank-fab held_payload rebuild
				# so a refab doesn't sit here forever with nothing to eject.
				if out_id == &"":
					var in_id: StringName = StringName(state.get("in_unit_id", &""))
					if in_id != &"":
						out_id = _get_tier2_unit(in_id)
						if out_id != &"":
							state["out_unit_id"] = out_id
							state["in_unit_id"] = &""
				if out_id == &"":
					state["phase"] = "idle"
					continue
				var payload := {"type": "unit", "unit_id": out_id}
				var delivered := false
				# 1) Payload conveyor on the front edge.
				for out_pos in output_cells:
					if _is_cross_faction(origin, out_pos):
						continue
					var entry_dir: int = (rot_r + 2) % 4
					if _is_payload_cell(out_pos) and _try_push_payload(out_pos, payload, entry_dir):
						delivered = true
						break
				# 2) Front-edge delivery (push to payload target / spawn on
				#    ground if front is clear or passable).
				if not delivered:
					if _try_deliver_fabricated_unit(origin, data, payload):
						delivered = true
				# 3) Whole-perimeter ground spawn fallback.
				if not delivered:
					if _spawn_unit_on_free_perimeter(origin, data, out_id):
						delivered = true
				if delivered:
					state["out_unit_id"] = &""
					state["phase"] = "idle"
				# Unused `gs` silencer (kept around for possible future
				# world-coord math in this loop).
				var _unused := gs


## Drops a unit payload off the front edge of a payload conveyor when no
## downstream payload-handling block will accept it. Every front cell has
## to be either empty, walkable terrain, or a passable transport block —
## if any is a non-passable building (including a payload target that's
## currently full) the conveyor holds instead of unloading so we don't
## silently lose payloads that would otherwise queue up. Returns true when
## a spawn happened.
func _try_spawn_unit_off_conveyor(conv_pos: Vector2i, conv_gs: Vector2i, rot: int, front_cells: Array[Vector2i], payload_data: Dictionary) -> bool:
	var unit_id: StringName = StringName(payload_data.get("unit_id", ""))
	if unit_id == &"":
		return false
	var unit_data = Registry.get_unit(unit_id)
	if unit_data == null:
		return false
	var faction: int = main.get_building_faction(conv_pos)
	if faction != main.Faction.FEROX:
		if main.has_method("can_spawn_unit") and not main.can_spawn_unit(unit_id):
			return false

	# Hold if *any* block sits on the conveyor's front edge. Even walkable
	# transport tiles (plain belts / ducts) count as obstruction here —
	# the player deliberately laid a block against the belt, so dumping a
	# unit on top of it isn't the behaviour they're expecting.
	# Pathfinding-blocking terrain (walls) also forces a hold.
	# `_payload_target_accepts_unit` already returned true / the refab
	# would have pulled earlier, so when we get here the front is either
	# empty grass or something the unit cannot stand on.
	var ml: int = unit_data.movement_layer
	var is_flying: bool = (ml == UnitData.MovementLayer.HOVER or ml == UnitData.MovementLayer.FLYING)
	var terrain = _terrain_ref()
	for cell in front_cells:
		if main.placed_buildings.has(cell) and not is_flying:
			return false
		if not is_flying and terrain != null and terrain.wall_tiles.has(cell):
			var tile_data = Registry.get_tile(terrain.wall_tiles[cell])
			if tile_data and tile_data.blocks_pathfinding:
				return false

	# Front is clear — spawn one tile ahead of the conveyor's front edge,
	# centred on the belt's axis so the unit appears where the payload
	# would have been pushed. Using the conveyor's rotation (not a
	# perimeter search) is what keeps the facing correct; the previous
	# "free-cell scan" would happily pick a side cell and make the unit
	# look like it came out of the wrong side of the belt.
	var gs: int = main.GRID_SIZE
	var anchor: Vector2i = main.building_origins.get(conv_pos, conv_pos)
	var center := Vector2(
		(anchor.x + conv_gs.x * 0.5) * gs,
		(anchor.y + conv_gs.y * 0.5) * gs
	)
	var spawn_world: Vector2
	match rot:
		0: spawn_world = center + Vector2((conv_gs.x * 0.5 + 0.5) * gs, 0)
		1: spawn_world = center + Vector2(0, (conv_gs.y * 0.5 + 0.5) * gs)
		2: spawn_world = center + Vector2(-(conv_gs.x * 0.5 + 0.5) * gs, 0)
		3: spawn_world = center + Vector2(0, -(conv_gs.y * 0.5 + 0.5) * gs)
		_: spawn_world = center + Vector2((conv_gs.x * 0.5 + 0.5) * gs, 0)

	var unit_mgr = _unit_mgr_ref()
	if unit_mgr == null:
		return false
	# Naval units can only deploy onto navigable water (water floor, no
	# platform). If the cell in front of the fabricator isn't water, HOLD
	# the unit (don't dump it on dry land) — the player must aim the
	# fabricator's output at open water, the same way a belt would carry
	# the payload there. is_world_pos_walkable on the NAVAL layer is exactly
	# "this is navigable water", so reuse it.
	if ml == UnitData.MovementLayer.NAVAL:
		if unit_mgr.has_method("is_world_pos_walkable") \
				and not unit_mgr.is_world_pos_walkable(spawn_world, ml):
			return false
	var spawned_unit: Node2D = null
	if faction == main.Faction.FEROX:
		unit_mgr.spawn_enemy(spawn_world, unit_id)
		if "enemies" in unit_mgr and not unit_mgr.enemies.is_empty():
			spawned_unit = unit_mgr.enemies[-1]
	else:
		unit_mgr.spawn_player_unit(spawn_world, unit_id)
		if "player_units" in unit_mgr and not unit_mgr.player_units.is_empty():
			spawned_unit = unit_mgr.player_units[-1]
		if "stats_units_produced" in main:
			main.stats_units_produced += 1
		var sector_script = _sector_script_ref()
		if sector_script:
			sector_script.on_unit_produced(unit_id)
	# Restore the carried unit's full runtime state (pose, turret rotations,
	# commands) so a unit that travelled a payload belt deploys exactly as it
	# was captured.
	if spawned_unit != null and is_instance_valid(spawned_unit) \
			and spawned_unit.has_method("apply_payload_state") \
			and payload_data.get("type", "") == "unit":
		spawned_unit.apply_payload_state(payload_data)
	return true


## Spawns `unit_id` on the first open perimeter cell around the building
## at `origin`. Used as a last-ditch fallback for refabricators whose
## front edge is blocked. If every perimeter cell is blocked too, falls
## back to spawning at the building's own centre so production never
## permanently jams. Returns true when a spawn happened.
func _spawn_unit_on_free_perimeter(origin: Vector2i, data: BlockData, unit_id: StringName) -> bool:
	if unit_id == &"":
		return false
	var unit_data = Registry.get_unit(unit_id)
	if unit_data == null:
		return false
	var faction: int = main.get_building_faction(origin)
	if faction != main.Faction.FEROX:
		if main.has_method("can_spawn_unit") and not main.can_spawn_unit(unit_id):
			return false
	var ml: int = unit_data.movement_layer
	var is_flying: bool = (ml == UnitData.MovementLayer.HOVER or ml == UnitData.MovementLayer.FLYING)
	var is_naval: bool = (ml == UnitData.MovementLayer.NAVAL)
	var terrain = _terrain_ref()
	var gs: int = main.GRID_SIZE
	var unit_mgr = _unit_mgr_ref()

	var spawn_world: Vector2 = Vector2.ZERO
	var found_cell := false
	var ring: Array[Vector2i] = _get_full_ring(origin, data.grid_size)
	for cell in ring:
		if _is_cross_faction(origin, cell):
			continue
		if main.placed_buildings.has(cell) and not is_flying:
			var blocker = Registry.get_block(main.placed_buildings[cell])
			var walkable: bool = blocker != null and blocker.is_transport() \
				and not (blocker.tags.has("payload") or blocker.tags.has("freight"))
			if not walkable:
				continue
		if not is_flying and terrain != null and terrain.wall_tiles.has(cell):
			var tile_data = Registry.get_tile(terrain.wall_tiles[cell])
			if tile_data and tile_data.blocks_pathfinding:
				continue
		# Naval units may ONLY land on navigable water (water floor, no
		# platform). is_world_pos_walkable on the NAVAL layer encodes exactly
		# that, so reuse it — a perimeter cell of dry land is rejected.
		if is_naval:
			var cw: Vector2 = Vector2(cell.x * gs + gs * 0.5, cell.y * gs + gs * 0.5)
			if unit_mgr == null or not unit_mgr.is_world_pos_walkable(cw, ml):
				continue
		spawn_world = Vector2(cell.x * gs + gs * 0.5, cell.y * gs + gs * 0.5)
		found_cell = true
		break

	if not found_cell:
		# Naval units must never be dumped on dry land — if no perimeter
		# water cell is open, HOLD the unit (the caller keeps it queued)
		# rather than spawning it on the building's (land) centre.
		if is_naval:
			return false
		# Every perimeter cell is blocked. Spawn on the building's own
		# centre so the unit isn't lost. The unit's own pathing will sort
		# out where it goes from there (ground units can't physically be
		# "inside" a building but the renderer and combat system treat
		# units as free entities).
		spawn_world = Vector2(
			(origin.x + data.grid_size.x * 0.5) * gs,
			(origin.y + data.grid_size.y * 0.5) * gs
		)

	if unit_mgr == null:
		return false
	if faction == main.Faction.FEROX:
		unit_mgr.spawn_enemy(spawn_world, unit_id)
	else:
		unit_mgr.spawn_player_unit(spawn_world, unit_id)
		if "stats_units_produced" in main:
			main.stats_units_produced += 1
		var sector_script = _sector_script_ref()
		if sector_script:
			sector_script.on_unit_produced(unit_id)
	return true


## Tries to hand a tier-1 unit directly into a refabricator at `anchor`
## without going through a payload conveyor. Used when a unit factory
## sits flush against a refabricator. Returns true when accepted.
## Rejects if the refabricator already holds a unit, or the input unit
## has no tier-2 successor.
func _try_feed_refabricator_direct(anchor: Vector2i, data: BlockData, unit_id: StringName) -> bool:
	if unit_id == &"":
		return false
	if _get_tier2_unit(unit_id) == &"":
		return false
	# Inactive refabs (construction / decon / derelict) don't accept.
	if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
		return false

	# Init refabricator state if this is its first interaction.
	if not refabricator_state.has(anchor):
		refabricator_state[anchor] = {
			"phase": "idle",
			"in_unit_id": &"",
			"timer": 0.0,
			"out_unit_id": &"",
			"selected_t2": &"",
		}
	elif not refabricator_state[anchor].has("selected_t2"):
		refabricator_state[anchor]["selected_t2"] = &""
	var state: Dictionary = refabricator_state[anchor]
	if state["phase"] != "idle" or StringName(state.get("in_unit_id", &"")) != &"":
		return false  # Busy
	var selected_t2: StringName = StringName(state.get("selected_t2", &""))
	# Refab with no selection won't accept anything (matches the idle-pull
	# behaviour). Refab with a selection only accepts the tier-1 that
	# upgrades to that tier-2.
	if selected_t2 == &"":
		return false
	if _get_tier2_unit(unit_id) != selected_t2:
		return false
	# Don't accept if the tier-2 slot is already full — we'd consume the
	# tier-1 with nowhere to put the upgraded unit.
	var ref_faction: int = main.get_building_faction(anchor)
	if ref_faction != main.Faction.FEROX:
		if main.has_method("can_spawn_unit") and not main.can_spawn_unit(selected_t2):
			return false

	# Also ensure a factory_buffer exists for item storage.
	if not factory_buffers.has(anchor):
		factory_buffers[anchor] = {
			"inputs": {},
			"phase": "collecting",
			"timer": 0.0,
			"pending_outputs": {},
		}
	var buf: Dictionary = factory_buffers[anchor]["inputs"]

	state["in_unit_id"] = unit_id
	var recipe: Dictionary = _refab_effective_recipe(data, selected_t2)
	if _refab_has_all_inputs_dict(recipe, buf):
		_refab_consume_inputs_dict(recipe, buf)
		state["timer"] = data.production_time if data.production_time > 0 else 5.0
		state["phase"] = "processing"
	else:
		state["phase"] = "collecting"
	return true




func _refab_has_all_inputs_dict(recipe: Dictionary, buf: Dictionary) -> bool:
	for raw_id in recipe:
		var need: int = int(recipe[raw_id])
		var k: StringName = _refab_input_key(raw_id)
		if int(buf.get(k, 0)) < need:
			return false
	return true


func _refab_consume_inputs_dict(recipe: Dictionary, buf: Dictionary) -> void:
	for raw_id in recipe:
		var need: int = int(recipe[raw_id])
		var k: StringName = _refab_input_key(raw_id)
		var have: int = int(buf.get(k, 0))
		buf[k] = have - need
		if buf[k] <= 0:
			buf.erase(k)


## Resolves the recipe (item -> amount) for a refab processing `t2_id`.
## Checks `data.refab_recipes[t2_id]` first so authors can give specific
## tier-2 units their own cost, and falls back to `data.input_items`
## otherwise. Accepts an empty `t2_id` to get the generic fallback.
func _refab_effective_recipe(data: BlockData, t2_id: StringName) -> Dictionary:
	if t2_id != &"" and data.refab_recipes.has(t2_id):
		var r = data.refab_recipes[t2_id]
		if r is Dictionary and not r.is_empty():
			return r
	return data.input_items


## Normalises a build-cost-style key ("copper") to the runtime item id
## ("mat_copper") the factory buffer uses. Already-prefixed ids pass through.
func _refab_input_key(raw_id) -> StringName:
	var s := String(raw_id)
	if s.begins_with("mat_"):
		return StringName(s)
	return StringName("mat_" + s)


func _update_loaders(_delta: float) -> void:
	var processed := {}

	for grid_pos in _bucket("payload_loader"):
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null:
			continue
		if not data.tags.has("payload_loader") and not data.tags.has("freight_loader"):
			continue

		var anchor = main.get_building_anchor(grid_pos)
		var origin: Vector2i = anchor if anchor != null else grid_pos
		if processed.has(origin):
			continue
		processed[origin] = true

		# Skip disabled or under-construction buildings
		var sector_script = _sector_script_ref()
		if sector_script and sector_script.is_building_disabled(origin):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue

		if not loader_state.has(origin):
			loader_state[origin] = {
				"payload": null,
				"phase": "idle",
				"fill_target": {},
			}

		var state = loader_state[origin]

		match state["phase"]:
			"idle":
				# Try to accept a storage-tagged building payload from the BACK face
				var rot_l: int = main.building_rotation.get(origin, 0)
				var back_rot_l: int = (rot_l + 2) % 4
				var back_cells_l: Array[Vector2i] = _get_front_edge(origin, data.grid_size, back_rot_l)
				for edge_pos in back_cells_l:
					if _is_cross_faction(origin, edge_pos):
						continue
					var conv_anchor_l: Vector2i = main.building_origins.get(edge_pos, edge_pos)
					if not payload_items.has(conv_anchor_l):
						continue
					if payload_items[conv_anchor_l]["progress"] < 1.0:
						continue

					var payload_data: Dictionary = payload_items[conv_anchor_l]["payload_data"]
					if payload_data.get("type", "") != "building":
						continue

					# Only accept blocks with the "storage" tag
					var target_id := StringName(payload_data.get("block_id", ""))
					var target_data = Registry.get_block(target_id)
					if target_data == null or not target_data.tags.has("storage"):
						continue

					# Accept the payload
					state["payload"] = payload_data
					state["phase"] = "filling"

					# Determine fill targets based on storage capacity
					if target_data.max_stored_items > 0:
						# Fill target = remaining capacity
						var stored: Dictionary = payload_data.get("stored_items", {})
						var total_stored := 0
						for sid in stored:
							total_stored += int(stored[sid])
						# We'll accept any items up to the capacity
						state["fill_target"] = {"_capacity": target_data.max_stored_items, "_current": total_stored}
					else:
						state["fill_target"] = {"_capacity": 0, "_current": 0}

					payload_items.erase(conv_anchor_l)
					break

			"filling":
				if state["payload"] == null:
					state["phase"] = "idle"
					continue

				var payload_data: Dictionary = state["payload"]
				var target_id := StringName(payload_data.get("block_id", ""))
				var target_data = Registry.get_block(target_id)
				if target_data == null:
					state["phase"] = "idle"
					state["payload"] = null
					continue

				# Check if storage is full
				var stored_items: Dictionary = payload_data.get("stored_items", {})
				var total_stored := 0
				for sid in stored_items:
					total_stored += int(stored_items[sid])
				var capacity: int = target_data.max_stored_items if target_data.max_stored_items > 0 else 0

				if capacity > 0 and total_stored >= capacity:
					# Full — output the payload from front face only.
					# Try a direct hand-off into an adjacent unloader / MD /
					# deconstructor first, then fall back to dropping onto a
					# payload conveyor.
					var rot: int = main.building_rotation.get(origin, 0)
					var front_cells: Array[Vector2i] = _get_front_edge(origin, data.grid_size, rot)
					for out_pos in front_cells:
						if _is_cross_faction(origin, out_pos):
							continue
						if _try_handoff_payload_to_block(out_pos, payload_data, origin):
							state["payload"] = null
							state["phase"] = "idle"
							break
						var entry_dir := _get_entry_dir_from_building(out_pos, origin, data.grid_size)
						if _try_push_payload(out_pos, payload_data, entry_dir):
							state["payload"] = null
							state["phase"] = "idle"
							break
					continue

				# Try to pull items from adjacent conveyors into the payload's storage
				var edge_cells := _get_all_perimeter_cells(origin, data.grid_size)
				for edge_pos in edge_cells:
					if total_stored >= capacity and capacity > 0:
						break
					if not conveyor_items.has(edge_pos):
						continue
					if conveyor_items[edge_pos]["progress"] < 1.0:
						continue
					if _is_cross_faction(origin, edge_pos):
						continue

					var item_id: StringName = conveyor_items[edge_pos]["item_id"]
					# Accept the item into the payload's stored_items
					if not payload_data.has("stored_items"):
						payload_data["stored_items"] = {}
					payload_data["stored_items"][item_id] = int(payload_data["stored_items"].get(item_id, 0)) + 1
					conveyor_items.erase(edge_pos)
					total_stored += 1


# =========================
# UNLOADER LOGIC
# =========================

## Processes all unloaders: accept storage payload → extract items → output empty payload.
func _update_unloaders(_delta: float) -> void:
	var processed := {}

	for grid_pos in _bucket("payload_unloader"):
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null:
			continue
		if not data.tags.has("payload_unloader") and not data.tags.has("freight_unloader"):
			continue

		var anchor = main.get_building_anchor(grid_pos)
		var origin: Vector2i = anchor if anchor != null else grid_pos
		if processed.has(origin):
			continue
		processed[origin] = true

		# Skip disabled or under-construction buildings
		var sector_script = _sector_script_ref()
		if sector_script and sector_script.is_building_disabled(origin):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue

		if not unloader_state.has(origin):
			unloader_state[origin] = {
				"payload": null,
				"phase": "idle",  # "idle", "transferring", "draining"
				"internal_storage": {},  # item_id → count (buffered items)
			}

		var state = unloader_state[origin]

		match state["phase"]:
			"idle":
				# Try to accept a storage-tagged building payload from
				# adjacent cells where the conveyor is actually flowing
				# INTO the unloader. Without the flow-direction check,
				# the unloader would grab a payload sitting on a
				# payload conveyor flowing AWAY from it (treating its
				# own output side as an input). Compute each candidate
				# conveyor's downstream cell — if that cell falls
				# inside the unloader's footprint, this conveyor is
				# feeding the unloader and we can grab from it.
				var perimeter_u := _get_all_perimeter_cells(origin, data.grid_size)
				for edge_pos in perimeter_u:
					if _is_cross_faction(origin, edge_pos):
						continue
					var conv_anchor_l: Vector2i = main.building_origins.get(edge_pos, edge_pos)
					if not payload_items.has(conv_anchor_l):
						continue
					if payload_items[conv_anchor_l]["progress"] < 1.0:
						continue

					# Skip conveyors whose flow doesn't terminate inside the
					# unloader. Compute downstream from `edge_pos` (the actual
					# conveyor cell adjacent to the unloader), not from the
					# conveyor's anchor — for multi-tile conveyors the anchor
					# can be several cells away from the exit edge, and
					# `anchor + DIR_VECTORS[rot]` lands inside the conveyor's
					# own footprint instead of past it.
					var conv_data = Registry.get_block(main.placed_buildings.get(conv_anchor_l, &""))
					if conv_data != null and conv_data.tags.has("payload") and conv_data.transport_speed > 0:
						var conv_rot: int = main.building_rotation.get(conv_anchor_l, 0)
						var downstream: Vector2i = edge_pos + DIR_VECTORS[conv_rot]
						if main.building_origins.get(downstream, downstream) != origin:
							continue

					var payload_data: Dictionary = payload_items[conv_anchor_l]["payload_data"]
					if payload_data.get("type", "") != "building":
						continue

					var target_id := StringName(payload_data.get("block_id", ""))
					var target_data = Registry.get_block(target_id)
					if target_data == null or not target_data.tags.has("storage"):
						continue

					state["payload"] = payload_data
					state["phase"] = "transferring"
					payload_items.erase(conv_anchor_l)
					break

			"transferring", "draining":
				var internal: Dictionary = state.get("internal_storage", {})
				var capacity: int = data.max_stored_items if data.max_stored_items > 0 else 200

				# --- TRANSFER: move items from container to internal storage ---
				if state["payload"] != null:
					var payload_data: Dictionary = state["payload"]
					var stored_items: Dictionary = payload_data.get("stored_items", {})

					var internal_total := 0
					for sid in internal:
						internal_total += int(internal[sid])

					var items_to_remove := []
					for item_id in stored_items:
						var count: int = int(stored_items[item_id])
						if count <= 0:
							items_to_remove.append(item_id)
							continue
						if internal_total >= capacity:
							break
						internal[item_id] = int(internal.get(item_id, 0)) + 1
						stored_items[item_id] = count - 1
						if count - 1 <= 0:
							items_to_remove.append(item_id)
						internal_total += 1
						break

					for item_id in items_to_remove:
						stored_items.erase(item_id)

					# Check if container is empty → output it
					var payload_empty := true
					for sid in stored_items:
						if int(stored_items[sid]) > 0:
							payload_empty = false
							break

					if payload_empty:
						var rot_t: int = main.building_rotation.get(origin, 0)
						var front_cells_t: Array[Vector2i] = _get_front_edge(origin, data.grid_size, rot_t)
						for out_pos in front_cells_t:
							if _is_cross_faction(origin, out_pos):
								continue
							# Hand off directly to an adjacent loader / MD /
							# deconstructor before falling back to a belt push.
							if _try_handoff_payload_to_block(out_pos, payload_data, origin):
								state["payload"] = null
								break
							var entry_dir := _get_entry_dir_from_building(out_pos, origin, data.grid_size)
							if _try_push_payload(out_pos, payload_data, entry_dir):
								state["payload"] = null
								break

				# --- DRAIN: push internal storage onto conveyors (runs every frame) ---
				var rot_d: int = main.building_rotation.get(origin, 0)
				var output_cells_d = _get_all_output_cells(origin, data.grid_size, rot_d)
				var items_to_remove_d := []

				for item_id in internal:
					var count: int = int(internal[item_id])
					if count <= 0:
						items_to_remove_d.append(item_id)
						continue

					for out_pos in output_cells_d:
						if _is_cross_faction(origin, out_pos):
							continue
						var entry_dir := _get_entry_dir_from_building(out_pos, origin, data.grid_size)
						if _try_push_item(out_pos, item_id, entry_dir):
							count -= 1
							internal[item_id] = count
							if count <= 0:
								items_to_remove_d.append(item_id)
							break

				for item_id in items_to_remove_d:
					internal.erase(item_id)
				state["internal_storage"] = internal

				# If no payload and no internal storage, go idle
				if state["payload"] == null and internal.is_empty():
					state["phase"] = "idle"


# =========================
# MASS DRIVER LOGIC
# =========================

## Mass drivers accept payloads from adjacent conveyors, charge up, and launch to a linked partner.
## No-op stub — was a throttled per-origin debug logger; kept in place so
## existing call sites compile while staying silent. Args are intentionally
## unused. Remove the call sites entirely once the logic is settled.
func _md_dbg(_origin: Vector2i, _tag: String, _msg: String) -> void:
	pass


## Computes the dynamic power-use override (in watts) for a mass driver
## with the given held payload. Returns 0 when no payload is loaded.
## Weight model (per spec):
##   tileWeight  = 8 w per tile of the held block / unit
##   itemWeight  = 0.5 w per stored item
##   fluidWeight = 1 w per 1.0 of stored fluid
## Required power = floor(weight / 2). 1 w → 0, 2 w → 1, etc.
func _mass_driver_power_for_payload(payload: Variant) -> int:
	if payload == null:
		return 0
	if not (payload is Dictionary):
		return 0
	var p: Dictionary = payload
	var weight: float = 0.0
	var ptype: String = String(p.get("type", ""))
	if ptype == "building":
		var sx: int = int(p.get("grid_size_x", 1))
		var sy: int = int(p.get("grid_size_y", 1))
		weight += 8.0 * float(sx) * float(sy)
	elif ptype == "unit":
		# Units are flagged as "1 tile equivalent" so the chassis still
		# costs something to launch even though they have no footprint.
		weight += 8.0
	# Items / fluids the held block was carrying when it was lifted
	# (see Main.pickup_building's "stored_items"/"stored_fluids" fields).
	var stored_items: Dictionary = p.get("stored_items", {})
	for it_id in stored_items:
		weight += 0.5 * float(int(stored_items[it_id]))
	var stored_fluids: Dictionary = p.get("stored_fluids", {})
	for fl_id in stored_fluids:
		weight += float(stored_fluids[fl_id])
	# floor(weight / 2)
	return int(floor(weight / 2.0))


func _update_mass_drivers(delta: float) -> void:
	var power_sys = _power_sys_ref()
	if not power_sys:
		return
	var processed := {}

	for grid_pos in _bucket("mass_driver"):
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null or not data.tags.has("mass_driver"):
			continue

		var anchor = main.get_building_anchor(grid_pos)
		var origin: Vector2i = anchor if anchor != null else grid_pos
		if processed.has(origin):
			continue
		processed[origin] = true

		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue

		if not mass_driver_state.has(origin):
			mass_driver_state[origin] = {
				"payload": null,
				"head_angle": 0.0,       # Current head rotation (radians)
				"target_angle": 0.0,     # Where head wants to face
				"recoil": 0.0,           # 0=none, 1=max recoil, decays over cooldown
				"phase": "idle",         # "idle", "rotating_to_input", "picking_up", "rotating_to_output", "ready", "recoil_out"
				"cooldown": 0.0,         # Cooldown timer
				"input_pos": Vector2i.ZERO,  # Where the payload was picked up from
			}

		var state: Dictionary = mass_driver_state[origin]
		var gs_md: float = main.GRID_SIZE
		var center: Vector2 = main.grid_to_world(origin) + Vector2(data.grid_size.x * gs_md / 2.0, data.grid_size.y * gs_md / 2.0)
		var cooldown_time: float = data.build_time if data.build_time > 0 else 2.0
		var rotate_speed: float = 3.0  # radians/sec

		# --- Dynamic power draw based on currently-loaded payload weight.
		# Formula (per spec):
		#   tileWeight  = 8 w  per tile
		#   itemWeight  = 0.5 w per stored item
		#   fluidWeight = 1 w  per 1.0 stored fluid
		# Required power = floor(weight / 2) — 2 w costs 1 power, 1 w
		# rounds down to 0. Idle drivers fall back to the static
		# `electrical_power_use` from BlockData (no payload, no extra
		# draw on top of the chassis baseline).
		var weight_power: int = _mass_driver_power_for_payload(state.get("payload"))
		if weight_power > 0:
			power_sys.set_dynamic_power_use(origin, float(weight_power) + data.electrical_power_use)
		else:
			power_sys.clear_dynamic_power_use(origin)
		# Network efficiency drives the MD's cycle speed — same model
		# the drills / factories use. 1.0 = full speed, 0.5 = half
		# speed (cooldown takes twice as long, head rotates half as
		# fast), 0.0 = fully starved (no progression at all). Avoids
		# the all-or-nothing fire gate we had before, which locked the
		# whole pair the moment the network tipped slightly into
		# overdraw from the MDs' own draw.
		var net_eff: float = 1.0
		if power_sys.has_method("get_electrical_efficiency"):
			net_eff = clampf(float(power_sys.get_electrical_efficiency(origin)), 0.0, 1.0)
		var is_powered: bool = net_eff > 0.0

		# Helper: snap angle to nearest 90° (cardinal direction)
		var snap_angle = func(a: float) -> float:
			return roundf(a / (PI / 2.0)) * (PI / 2.0)

		# Find role and partner. Normalise BOTH pair endpoints to anchors
		# before comparing so links saved before the link-normalization
		# fix (where pair endpoints could be any clicked cell of a
		# multi-tile MD) still match the MD's own anchor here. Without
		# this, a legacy save's link would fail every comparison and
		# both drivers would silently sit in "idle" forever.
		var is_input := false
		var is_output := false
		var partner: Variant = null
		for pair in power_sys.linked_pairs:
			var a_anchor: Vector2i = main.building_origins.get(pair[0], pair[0])
			var b_anchor: Vector2i = main.building_origins.get(pair[1], pair[1])
			if a_anchor == origin:
				is_input = true
				partner = b_anchor
				break
			elif b_anchor == origin:
				is_output = true
				partner = a_anchor
				break
		_md_dbg(origin, "state",
			"phase=%s payload=%s is_input=%s is_output=%s partner=%s powered=%s weight_pwr=%d cd=%.2f"
			% [
				str(state.get("phase", "?")),
				"yes" if state.get("payload") != null else "no",
				str(is_input), str(is_output),
				"none" if partner == null else str(partner),
				str(is_powered),
				weight_power,
				float(state.get("cooldown", 0.0)),
			])

		# Time-dilated tick — every progression below scales with the
		# network's efficiency so a 50 %-efficient network produces a
		# 50 %-speed cycle. `eff_dt` is a single common factor we apply
		# anywhere we'd otherwise use raw `delta`.
		var eff_dt: float = delta * net_eff

		# Rotate head toward target at constant speed
		var angle_diff: float = wrapf(state["target_angle"] - state["head_angle"], -PI, PI)
		var max_rot: float = rotate_speed * eff_dt
		if absf(angle_diff) <= max_rot:
			state["head_angle"] = state["target_angle"]
		else:
			state["head_angle"] = wrapf(state["head_angle"] + signf(angle_diff) * max_rot, -PI, PI)
		var head_at_target: bool = absf(wrapf(state["target_angle"] - state["head_angle"], -PI, PI)) < 0.05

		# Decay recoil
		if state["recoil"] > 0:
			state["recoil"] = maxf(state["recoil"] - eff_dt / cooldown_time, 0.0)

		# Decay cooldown
		if state["cooldown"] > 0:
			state["cooldown"] = maxf(state["cooldown"] - eff_dt, 0.0)

		# === INPUT MASS DRIVER ===
		if is_input:
			match state["phase"]:
				"idle":
					if state["cooldown"] > 0:
						_md_dbg(origin, "idle-wait", "cooldown=%.2f" % state["cooldown"])
						continue
					# Look for payload on adjacent conveyors
					var perimeter := _get_all_perimeter_cells(origin, data.grid_size)
					var found_payload := false
					var perim_payloads := 0
					var perim_progress_lt1 := 0
					var perim_cross := 0
					for edge_pos in perimeter:
						if _is_cross_faction(origin, edge_pos):
							perim_cross += 1
							continue
						var conv_anchor: Vector2i = main.building_origins.get(edge_pos, edge_pos)
						if not payload_items.has(conv_anchor):
							continue
						perim_payloads += 1
						if payload_items[conv_anchor]["progress"] < 1.0:
							perim_progress_lt1 += 1
							continue
						# Found payload — rotate toward it
						var conv_center: Vector2 = main.grid_to_world(conv_anchor) + Vector2(gs_md / 2.0, gs_md / 2.0)
						state["target_angle"] = snap_angle.call((conv_center - center).angle())
						state["input_pos"] = conv_anchor
						state["phase"] = "rotating_to_input"
						found_payload = true
						_md_dbg(origin, "pickup",
							"locked conv_anchor=%s target_angle=%.2f"
							% [str(conv_anchor), state["target_angle"]])
						break
					if not found_payload:
						_md_dbg(origin, "idle-scan",
							"perimeter=%d cross=%d payloads_seen=%d progress<1=%d"
							% [perimeter.size(), perim_cross, perim_payloads, perim_progress_lt1])

				"rotating_to_input":
					if head_at_target:
						# Pick up the payload. If the conveyor lost the
						# payload between detection and rotation finish
						# (e.g. another consumer grabbed it), drop back
						# to idle instead of advancing to rotating_to_output —
						# we'd otherwise sit there forever with payload=null.
						var conv_anchor: Vector2i = state["input_pos"]
						if payload_items.has(conv_anchor):
							state["payload"] = payload_items[conv_anchor]["payload_data"]
							payload_items.erase(conv_anchor)
							state["phase"] = "rotating_to_output"
							# Set target to face the partner
							if partner != null and main.placed_buildings.has(partner):
								var p_data = Registry.get_block(main.placed_buildings[partner])
								var p_center: Vector2 = main.grid_to_world(partner) + Vector2(p_data.grid_size.x * gs_md / 2.0, p_data.grid_size.y * gs_md / 2.0) if p_data else main.grid_to_world(partner)
								state["target_angle"] = snap_angle.call((p_center - center).angle())
							_md_dbg(origin, "pickup-ok", "got payload from %s" % str(conv_anchor))
						else:
							_md_dbg(origin, "pickup-miss",
								"conv_anchor=%s no longer has payload — reverting to idle"
								% str(conv_anchor))
							state["phase"] = "idle"

				"rotating_to_output":
					if state["payload"] == null:
						# Defensive: can't be in rotating_to_output without
						# a payload. If somehow we got here, recover by
						# going back to idle so we can rescan instead of
						# locking the MD.
						_md_dbg(origin, "rotating-empty", "no payload — reverting to idle")
						state["phase"] = "idle"
					elif head_at_target:
						state["phase"] = "ready"

				"ready":
					# Fire — launch projectile. Requires enough power on
					# the network to cover the weight-based draw computed
					# above; otherwise the driver just sits charged until
					# the grid catches up.
					if not is_powered:
						_md_dbg(origin, "fire-blocked", "no power")
						continue
					if partner == null:
						_md_dbg(origin, "fire-blocked", "no partner")
						continue
					if state["payload"] == null:
						_md_dbg(origin, "fire-blocked", "no payload (state desync)")
						continue
					if not main.placed_buildings.has(partner):
						_md_dbg(origin, "fire-blocked", "partner cell missing in placed_buildings")
						continue
					var partner_data = Registry.get_block(main.placed_buildings[partner])
					if partner_data == null or not partner_data.tags.has("mass_driver"):
						_md_dbg(origin, "fire-blocked", "partner is not a mass_driver: %s" % str(main.placed_buildings.get(partner, &"")))
						continue
					if not mass_driver_state.has(partner):
						mass_driver_state[partner] = {
							"payload": null, "head_angle": 0.0, "target_angle": 0.0,
							"recoil": 0.0, "phase": "idle", "cooldown": 0.0, "input_pos": Vector2i.ZERO,
						}
					var p_state: Dictionary = mass_driver_state[partner]
					if p_state["payload"] != null:
						_md_dbg(origin, "fire-blocked", "partner already holding payload")
						continue
					# Aim the partner at this driver and only fire once it's
					# rotated all the way around — both MDs have to be
					# *physically* pointing at each other before a launch
					# happens, instead of the partner snapping instantly.
					var p_data = Registry.get_block(main.placed_buildings.get(partner, &""))
					var p_center: Vector2 = main.grid_to_world(partner) + Vector2(p_data.grid_size.x * gs_md / 2.0, p_data.grid_size.y * gs_md / 2.0) if p_data else main.grid_to_world(partner)
					var p_face_angle: float = snap_angle.call((center - p_center).angle())
					p_state["target_angle"] = p_face_angle
					var p_off: float = absf(wrapf(p_face_angle - float(p_state.get("head_angle", 0.0)), -PI, PI))
					if p_off >= 0.05:
						_md_dbg(origin, "fire-wait",
							"partner not yet aligned (off=%.2f rad)" % p_off)
						continue

					# Create projectile
					mass_driver_projectiles.append({
						"from": center,
						"to": p_center,
						"payload_data": state["payload"],
						"progress": 0.0,
						"source_origin": origin,
						"target_origin": partner,
					})
					_md_dbg(origin, "fire", "→ partner=%s" % str(partner))

					state["payload"] = null
					state["recoil"] = 1.0
					state["cooldown"] = cooldown_time
					state["phase"] = "idle"

		# === OUTPUT MASS DRIVER ===
		elif is_output:

			match state["phase"]:
				"idle":
					pass  # Waiting for input driver to send payload

				"recoil_in":
					# Just received — recoil is decaying. Once it's done,
					# try a direct hand-off to any adjacent receiver
					# (loader / unloader / deconstructor) on ANY side,
					# skipping the head-rotation animation. If none
					# accept, fall through to the rotate-then-belt-push
					# path.
					if state["recoil"] <= 0:
						var perim: Array[Vector2i] = _get_all_perimeter_cells(origin, data.grid_size)
						var handoff_done := false
						for out_pos in perim:
							if _try_handoff_payload_to_block(out_pos, state["payload"], origin):
								state["payload"] = null
								state["phase"] = "idle"
								handoff_done = true
								break
						if handoff_done:
							continue
						# No direct receiver — rotate to face output conveyor
						var rot_md: int = main.building_rotation.get(origin, 0)
						var front: Array[Vector2i] = _get_front_edge(origin, data.grid_size, rot_md)
						if not front.is_empty():
							var out_world: Vector2 = main.grid_to_world(front[0]) + Vector2(gs_md / 2.0, gs_md / 2.0)
							state["target_angle"] = snap_angle.call((out_world - center).angle())
						state["phase"] = "rotating_to_output"

				"rotating_to_output":
					if head_at_target and state["payload"] != null:
						# Try direct hand-off to any adjacent loader /
						# unloader / deconstructor first (any side), then
						# fall back to a payload-conveyor push on the
						# front face only.
						var rot_md: int = main.building_rotation.get(origin, 0)
						var front: Array[Vector2i] = _get_front_edge(origin, data.grid_size, rot_md)
						var perim: Array[Vector2i] = _get_all_perimeter_cells(origin, data.grid_size)
						var pushed_ok := false
						for out_pos in perim:
							if _try_handoff_payload_to_block(out_pos, state["payload"], origin):
								state["payload"] = null
								state["phase"] = "idle"
								pushed_ok = true
								break
						if not pushed_ok:
							for out_pos in front:
								if _try_push_payload(out_pos, state["payload"]):
									state["payload"] = null
									state["phase"] = "idle"
									pushed_ok = true
									break

	# Update in-flight projectiles. Travel time scales with the source
	# network's efficiency so an underpowered launch coasts more slowly
	# (matches the cycle-speed scaling above).
	var projectiles_to_remove := []
	for i in range(mass_driver_projectiles.size()):
		var proj: Dictionary = mass_driver_projectiles[i]
		var src_origin: Vector2i = proj.get("source_origin", Vector2i.ZERO)
		var proj_eff: float = 1.0
		if power_sys and power_sys.has_method("get_electrical_efficiency"):
			proj_eff = clampf(float(power_sys.get_electrical_efficiency(src_origin)), 0.0, 1.0)
		proj["progress"] += delta * 4.0 * proj_eff  # Fast flight (~0.25 s @ full power)
		if proj["progress"] >= 1.0:
			# Deliver to target
			var target_origin: Vector2i = proj["target_origin"]
			if mass_driver_state.has(target_origin):
				var p_state: Dictionary = mass_driver_state[target_origin]
				p_state["payload"] = proj["payload_data"]
				p_state["phase"] = "recoil_in"
				p_state["recoil"] = 1.0
			projectiles_to_remove.append(i)
	for i in range(projectiles_to_remove.size() - 1, -1, -1):
		mass_driver_projectiles.remove_at(projectiles_to_remove[i])


# =========================
# DRAWING
# =========================

func _draw() -> void:
	_draw_items()
	_draw_payloads()
	_draw_mass_drivers()
	# In-world cycle progress bars were removed — the player reads
	# production state from tooltips / per-block visuals (slam ease,
	# scraper spin, factory item layer) instead.
	# _draw_drill_progress_bars()
	# _draw_pump_progress_bars()
	# _draw_factory_progress_bars()


func _draw_mass_drivers() -> void:
	var gs_d: float = main.GRID_SIZE
	for origin in mass_driver_state:
		if not main.placed_buildings.has(origin):
			continue
		var data = Registry.get_block(main.placed_buildings[origin])
		if data == null:
			continue
		var state: Dictionary = mass_driver_state[origin]
		var center: Vector2 = main.grid_to_world(origin) + Vector2(data.grid_size.x * gs_d / 2.0, data.grid_size.y * gs_d / 2.0)
		var head_angle: float = state.get("head_angle", 0.0)
		var recoil: float = state.get("recoil", 0.0)
		var head_dir: Vector2 = Vector2(cos(head_angle), sin(head_angle))

		# Recoil pushes the head backward
		var recoil_offset: Vector2 = -head_dir * recoil * gs_d * 0.4
		var head_pos: Vector2 = center + recoil_offset

		# Draw head — prefers the block's authored head sprite (drawn at
		# its native pixel size scaled down, pushed forward along the
		# aim axis so it sits near the muzzle end of the chassis rather
		# than dead-centred on the block). Falls back to the procedural
		# rectangle for blocks without a head texture.
		if data.turret_head_sprite:
			var head_tex: Texture2D = data.turret_head_sprite
			# Smaller, mounted-near-the-muzzle look: scale the native
			# sprite down and push it ~40 % of a tile forward along the
			# aim direction. The recoil offset still applies so a fired
			# shot still kicks the head back.
			const HEAD_SCALE: float = 0.5
			const HEAD_FORWARD_TILES: float = 0.7
			var head_tex_size: Vector2 = head_tex.get_size() * HEAD_SCALE * main.SPRITE_SCALE_FACTOR
			var forward_offset: Vector2 = head_dir * gs_d * HEAD_FORWARD_TILES
			# The mass-driver head art points along its local +Y axis
			# (the barrel runs from the centre of the sprite to its
			# bottom edge), so the world rotation adds π/2 to map the
			# texture's natural-up forward onto the +X aim direction.
			draw_set_transform(head_pos + forward_offset, head_angle + PI / 2.0)
			draw_texture_rect(
				head_tex,
				Rect2(-head_tex_size * 0.5, head_tex_size),
				false,
			)
			draw_set_transform(Vector2.ZERO, 0.0)
		else:
			var head_w: float = data.grid_size.x * gs_d * 0.5
			var head_h: float = data.grid_size.y * gs_d * 0.3
			draw_set_transform(head_pos, head_angle)
			draw_rect(Rect2(-head_w / 2.0, -head_h / 2.0, head_w, head_h), Color(data.color.r * 0.8, data.color.g * 0.8, data.color.b * 0.8, 0.9), true)
			draw_rect(Rect2(-head_w / 2.0, -head_h / 2.0, head_w, head_h), data.color.lightened(0.2), false, 2.0)
			# Barrel
			draw_rect(Rect2(head_w * 0.3, -head_h * 0.15, head_w * 0.4, head_h * 0.3), data.color.darkened(0.3), true)
			draw_set_transform(Vector2.ZERO, 0.0)

		# Draw payload on top of head — positioned at the muzzle tip,
		# not the chassis centre. Pushed slightly further forward than
		# the head sprite itself so it visibly sits at the launch end
		# of the barrel.
		if state["payload"] != null:
			var payload: Dictionary = state["payload"]
			var icon: Texture2D = null
			var pw: float = gs_d
			var ph: float = gs_d
			if payload.get("type", "") == "building":
				var bd = Registry.get_block(StringName(payload.get("block_id", "")))
				if bd:
					icon = bd.icon
					pw = bd.grid_size.x * gs_d
					ph = bd.grid_size.y * gs_d
			elif payload.get("type", "") == "unit":
				var ud = Registry.get_unit(StringName(payload.get("unit_id", "")))
				if ud:
					icon = ud.icon
					if icon:
						# Fit unit icon to a single tile so it stays grid-proportional.
						pw = gs_d
						ph = gs_d
			if icon:
				# Position payload at the head's muzzle tip — same forward
				# direction as the head sprite, but a bit further out so
				# it visually sits at the front of the barrel rather than
				# overlapping the chassis. Tweak `PAYLOAD_TIP_TILES` to
				# move the icon further toward / further past the tip.
				const PAYLOAD_TIP_TILES: float = 0.7
				var payload_pos: Vector2 = head_pos + head_dir * gs_d * PAYLOAD_TIP_TILES
				draw_texture_rect(
					icon,
					Rect2(payload_pos.x - pw / 2.0, payload_pos.y - ph / 2.0, pw, ph),
					false,
					Color(1, 1, 1, 0.7),
				)

	# Draw in-flight projectiles
	for proj in mass_driver_projectiles:
		var from: Vector2 = proj["from"]
		var to: Vector2 = proj["to"]
		var t: float = proj["progress"]
		var pos: Vector2 = from.lerp(to, t)
		var payload: Dictionary = proj["payload_data"]
		var icon: Texture2D = null
		var pw: float = gs_d
		var ph: float = gs_d
		if payload.get("type", "") == "building":
			var bd = Registry.get_block(StringName(payload.get("block_id", "")))
			if bd:
				icon = bd.icon
				pw = bd.grid_size.x * gs_d
				ph = bd.grid_size.y * gs_d
		if icon:
			draw_texture_rect(icon, Rect2(pos.x - pw / 2.0, pos.y - ph / 2.0, pw, ph), false, Color(1, 1, 1, 0.9))
		else:
			draw_circle(pos, gs_d * 0.4, Color(0.5, 0.3, 0.8, 0.8))
		# Trail effect
		var trail_start: Vector2 = from.lerp(to, maxf(t - 0.15, 0.0))
		draw_line(trail_start, pos, Color(0.5, 0.3, 0.9, 0.4), 3.0 * main.SPRITE_SCALE_FACTOR)


func _draw_items() -> void:
	var building_sys = _building_sys_ref()
	var _ss_items = _sector_script_ref()
	# Launch-animation reveal: items on a belt the landing ring hasn't
	# "built" yet must stay hidden — the belt itself isn't drawn until the
	# sweep reaches it, so its cargo shouldn't float on bare ground either.
	var _la_items = _launch_anim_ref()

	# Viewport culling: items off-screen contribute nothing visible but
	# cost full draw work otherwise. On a large map with thousands of
	# items moving across belts this was the dominant per-frame script
	# cost — culling drops it to "items on screen" instead of "items on
	# the entire map".
	var camera := get_viewport().get_camera_2d()
	var vp_grid_min: Vector2i = Vector2i(-1, -1)
	var vp_grid_max: Vector2i = Vector2i(-1, -1)
	if camera != null:
		var cam_center: Vector2 = camera.get_screen_center_position()
		var viewport_size: Vector2 = get_viewport_rect().size
		var cam_zoom: Vector2 = camera.zoom if camera.zoom != Vector2.ZERO else Vector2.ONE
		var half_view: Vector2 = viewport_size / (2.0 * cam_zoom)
		vp_grid_min = main.world_to_grid(cam_center - half_view) - Vector2i(1, 1)
		vp_grid_max = main.world_to_grid(cam_center + half_view) + Vector2i(1, 1)

	for grid_pos in conveyor_items:
		if vp_grid_min != Vector2i(-1, -1):
			if grid_pos.x < vp_grid_min.x or grid_pos.x > vp_grid_max.x:
				continue
			if grid_pos.y < vp_grid_min.y or grid_pos.y > vp_grid_max.y:
				continue
		if _ss_items and _ss_items.is_tile_hidden(grid_pos):
			continue
		if _la_items and _la_items.has_method("is_block_hidden") \
				and _la_items.is_block_hidden(main.building_origins.get(grid_pos, grid_pos)):
			continue
		# Bridges are visually "underground" — items inside one are
		# being teleported between the input and output ends and
		# shouldn't appear on the conveyor surface. Skip the draw.
		if _is_bridge_cell(grid_pos):
			continue
		var entry = conveyor_items[grid_pos]
		var item_id: StringName = entry["item_id"]
		var progress: float = entry["progress"]

		var item = Registry.get_item_or_fluid(item_id)
		if item == null:
			continue

		# Figure out which direction this conveyor faces
		var rotation = main.building_rotation.get(grid_pos, 0)
		# Routers use their pre-decided exit_dir instead of cell rotation.
		# Until the picker commits one, hold the item at cell center
		# instead of animating it toward the cell's `rotation` — which on
		# a router points at the back (input) side and would otherwise
		# slide the item visibly toward whatever's behind the router
		# (often bare terrain).
		var exit_dir: int = entry.get("exit_dir", -1)
		# Routers and overflow/underflow belts hold the item at cell centre until
		# an exit is decided, then animate it out toward that face.
		var holds_center: bool = _is_router_cell(grid_pos) \
			or _is_overflow_cell(grid_pos) or _is_underflow_cell(grid_pos)
		if holds_center and exit_dir < 0:
			var cw: Vector2 = main.grid_to_world(grid_pos) \
				+ Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
			var off: Vector2 = Vector2.ZERO
			if building_sys:
				off = building_sys._get_top_offset(main.grid_to_world(grid_pos))
			var ip: Vector2 = cw + off
			if item.icon != null:
				var ts := Vector2(ITEM_TEXTURE_SIZE * main.SPRITE_SCALE_FACTOR, ITEM_TEXTURE_SIZE * main.SPRITE_SCALE_FACTOR)
				draw_texture_rect(item.icon, Rect2(ip - ts / 2.0, ts), false)
			else:
				draw_circle(ip, ITEM_RADIUS * main.SPRITE_SCALE_FACTOR, item.color.darkened(0.15))
				draw_arc(ip, ITEM_RADIUS * main.SPRITE_SCALE_FACTOR, 0, TAU, 16, item.color.lightened(0.4), 2.0)
			continue
		var effective_dir: int = exit_dir if exit_dir >= 0 else rotation
		var dir_vec = Vector2(DIR_VECTORS[effective_dir])

		# World position of the cell center
		var world_pos = main.grid_to_world(grid_pos)
		var cell_center = world_pos + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)

		# Apply the same parallax offset as buildings
		var offset = Vector2.ZERO
		if building_sys:
			offset = building_sys._get_top_offset(world_pos)

		# Determine entry direction (default = behind the belt)
		var entry_dir: int = entry.get("entry_dir", -1)
		var back_dir: int = (effective_dir + 2) % 4
		if entry_dir < 0 or entry_dir > 3:
			entry_dir = back_dir

		var item_pos: Vector2
		if entry_dir == back_dir:
			# STRAIGHT PATH: item entered from behind → slide linearly
			item_pos = cell_center + offset + dir_vec * (progress - 0.5) * main.GRID_SIZE
		else:
			# CURVED PATH: item entered from the side → quarter-circle arc
			var entry_vec = Vector2(DIR_VECTORS[entry_dir])  # From center toward entry edge
			var exit_vec = dir_vec                             # From center toward exit edge
			var half: float = main.GRID_SIZE / 2.0

			# Pivot = corner of cell where entry and exit edges meet
			var pivot = cell_center + entry_vec * half + exit_vec * half

			# Arc from entry point to exit point around the pivot
			var angle_start = atan2(-exit_vec.y, -exit_vec.x)
			var angle_end = atan2(-entry_vec.y, -entry_vec.x)
			var angle = lerp_angle(angle_start, angle_end, progress)
			item_pos = pivot + Vector2(cos(angle), sin(angle)) * half + offset

		# Draw: item texture if available, otherwise colored circle fallback
		if item.icon != null:
			var tex_size = Vector2(ITEM_TEXTURE_SIZE * main.SPRITE_SCALE_FACTOR, ITEM_TEXTURE_SIZE * main.SPRITE_SCALE_FACTOR)
			var tex_rect = Rect2(item_pos - tex_size / 2.0, tex_size)
			draw_texture_rect(item.icon, tex_rect, false)
		else:
			draw_circle(item_pos, ITEM_RADIUS * main.SPRITE_SCALE_FACTOR, item.color.darkened(0.15))
			draw_arc(item_pos, ITEM_RADIUS * main.SPRITE_SCALE_FACTOR, 0, TAU, 16, item.color.lightened(0.4), 2.0)

	# Draw junction perpendicular-axis items (same rendering logic)
	for grid_pos in junction_items:
		if _ss_items and _ss_items.is_tile_hidden(grid_pos):
			continue
		if _la_items and _la_items.has_method("is_block_hidden") \
				and _la_items.is_block_hidden(main.building_origins.get(grid_pos, grid_pos)):
			continue
		var entry = junction_items[grid_pos]
		var item_id: StringName = entry["item_id"]
		var progress: float = entry["progress"]

		var item = Registry.get_item_or_fluid(item_id)
		if item == null:
			continue

		var entry_dir: int = entry.get("entry_dir", -1)
		if entry_dir < 0:
			continue  # Junction items must have an entry direction

		# Exit direction = opposite of entry
		var exit_dir: int = (entry_dir + 2) % 4
		var dir_vec = Vector2(DIR_VECTORS[exit_dir])

		var world_pos = main.grid_to_world(grid_pos)
		var cell_center = world_pos + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)

		var offset = Vector2.ZERO
		if building_sys:
			offset = building_sys._get_top_offset(world_pos)

		# Junction items always go straight through
		var item_pos: Vector2 = cell_center + offset + dir_vec * (progress - 0.5) * main.GRID_SIZE

		if item.icon != null:
			var tex_size = Vector2(ITEM_TEXTURE_SIZE * main.SPRITE_SCALE_FACTOR, ITEM_TEXTURE_SIZE * main.SPRITE_SCALE_FACTOR)
			var tex_rect = Rect2(item_pos - tex_size / 2.0, tex_size)
			draw_texture_rect(item.icon, tex_rect, false)
		else:
			draw_circle(item_pos, ITEM_RADIUS * main.SPRITE_SCALE_FACTOR, item.color.darkened(0.15))
			draw_arc(item_pos, ITEM_RADIUS * main.SPRITE_SCALE_FACTOR, 0, TAU, 16, item.color.lightened(0.4), 2.0)


## Draws payloads on payload/freight conveyors.
## Building payloads draw their block icon; unit payloads draw the unit icon.
## Size is ~48px, centered on the cell, interpolated between cells based on progress.
func _draw_payloads() -> void:
	var building_sys = _building_sys_ref()
	var _ss_payload = _sector_script_ref()
	var _la_payload = _launch_anim_ref()
	var gs: float = main.GRID_SIZE

	# Same viewport culling as `_draw_items` — payloads off-screen
	# contribute nothing visible but cost full draw work otherwise.
	var camera := get_viewport().get_camera_2d()
	var vp_grid_min: Vector2i = Vector2i(-1, -1)
	var vp_grid_max: Vector2i = Vector2i(-1, -1)
	if camera != null:
		var cam_center: Vector2 = camera.get_screen_center_position()
		var viewport_size: Vector2 = get_viewport_rect().size
		var cam_zoom: Vector2 = camera.zoom if camera.zoom != Vector2.ZERO else Vector2.ONE
		var half_view: Vector2 = viewport_size / (2.0 * cam_zoom)
		# Payloads are bigger than items, so pad the culling box more
		# generously to avoid clipping at the screen edge.
		vp_grid_min = main.world_to_grid(cam_center - half_view) - Vector2i(3, 3)
		vp_grid_max = main.world_to_grid(cam_center + half_view) + Vector2i(3, 3)

	for grid_pos in payload_items:
		if vp_grid_min != Vector2i(-1, -1):
			if grid_pos.x < vp_grid_min.x or grid_pos.x > vp_grid_max.x:
				continue
			if grid_pos.y < vp_grid_min.y or grid_pos.y > vp_grid_max.y:
				continue
		if _ss_payload and _ss_payload.is_tile_hidden(grid_pos):
			continue
		if _la_payload and _la_payload.has_method("is_block_hidden") \
				and _la_payload.is_block_hidden(main.building_origins.get(grid_pos, grid_pos)):
			continue
		var entry = payload_items[grid_pos]
		var payload_data: Dictionary = entry["payload_data"]
		var progress: float = entry["progress"]

		# Get the conveyor block's data for its size
		var conv_block_id: StringName = main.placed_buildings.get(grid_pos, &"")
		var conv_data = Registry.get_block(conv_block_id)
		var conv_size: Vector2i = conv_data.grid_size if conv_data else Vector2i(1, 1)

		# Determine the icon and full size of the payload
		var icon: Texture2D = null
		var payload_pixel_w: float = gs
		var payload_pixel_h: float = gs
		var payload_rot: int = 0
		if payload_data.get("type", "") == "building":
			var block_id: StringName = StringName(payload_data.get("block_id", ""))
			if block_id != &"":
				var block_data = Registry.get_block(block_id)
				if block_data != null:
					icon = block_data.icon if block_data.icon != null else block_data.top_sprite
					payload_pixel_w = block_data.grid_size.x * gs
					payload_pixel_h = block_data.grid_size.y * gs
					payload_rot = int(payload_data.get("rotation", 0))
		elif payload_data.get("type", "") == "unit":
			var unit_id: StringName = StringName(payload_data.get("unit_id", ""))
			if unit_id != &"":
				var unit_data = Registry.get_unit(unit_id)
				if unit_data != null:
					# Match the unit's on-screen world size: base_sprite/head_sprite
					# scaled by sprite_scale, same as enemy_unit.gd renders them.
					# Previously the icon texture was drawn at its raw pixel
					# size, which on large icon art made payloads look huge.
					var scale_f: float = (unit_data.sprite_scale if unit_data.sprite_scale > 0.0 else 1.0) * main.SPRITE_SCALE_FACTOR
					var world_tex: Texture2D = null
					if unit_data.base_sprite != null:
						world_tex = unit_data.base_sprite
					elif unit_data.head_sprite != null:
						world_tex = unit_data.head_sprite
					if world_tex != null:
						icon = world_tex
						payload_pixel_w = world_tex.get_width() * scale_f
						payload_pixel_h = world_tex.get_height() * scale_f
					elif unit_data.icon != null:
						icon = unit_data.icon
						payload_pixel_w = unit_data.icon.get_width() * scale_f
						payload_pixel_h = unit_data.icon.get_height() * scale_f
					else:
						var us: float = unit_data.visual_size if unit_data.visual_size > 0 else 8.0
						payload_pixel_w = us * 2
						payload_pixel_h = us * 2

		# Conveyor center (multi-tile aware)
		var rotation: int = main.building_rotation.get(grid_pos, 0)
		# Effective exit direction. For routers + junctions the advance
		# pass writes `exit_dir` onto the payload entry so we can curve
		# the visual along the actual path instead of always sliding
		# along the cell's placement rotation.
		var exit_dir_d: int = int(entry.get("exit_dir", -1))
		var effective_dir: int = exit_dir_d if exit_dir_d >= 0 else rotation
		var dir_vec := Vector2(DIR_VECTORS[effective_dir])
		var world_pos: Vector2 = main.grid_to_world(grid_pos)
		var conv_center: Vector2 = world_pos + Vector2(conv_size.x * gs / 2.0, conv_size.y * gs / 2.0)

		# Movement distance scaled to conveyor size (larger conveyors = longer travel)
		var travel_dist: float = maxf(conv_size.x, conv_size.y) * gs
		var half_dist: float = travel_dist / 2.0

		var payload_pos: Vector2
		var entry_dir_d: int = int(entry.get("entry_dir", -1))
		var back_dir_d: int = (effective_dir + 2) % 4
		if entry_dir_d < 0 or entry_dir_d > 3:
			entry_dir_d = back_dir_d
		if entry_dir_d == back_dir_d:
			# STRAIGHT PATH: payload entered from the back, slide linearly
			# from back-edge to front-edge over the conveyor.
			payload_pos = conv_center + dir_vec * (progress - 0.5) * travel_dist
		else:
			# CURVED PATH: payload entered from a side and exits a
			# different side (router round-robin, junction perpendicular
			# axis). Draw a quarter-circle arc through the corner where
			# the entry and exit edges meet.
			var entry_vec := Vector2(DIR_VECTORS[entry_dir_d])
			var exit_vec: Vector2 = dir_vec
			var pivot: Vector2 = conv_center + entry_vec * half_dist + exit_vec * half_dist
			var angle_start: float = atan2(-exit_vec.y, -exit_vec.x)
			var angle_end: float = atan2(-entry_vec.y, -entry_vec.x)
			var angle: float = lerp_angle(angle_start, angle_end, progress)
			payload_pos = pivot + Vector2(cos(angle), sin(angle)) * half_dist

		# Unit payloads render through the shared EnemyUnit.draw_unit_payload
		# so a unit on a payload belt shows EXACTLY like it would in-world —
		# chassis + rotating head + weapon-mount turret heads at the saved
		# facing/aim/mount rotations — instead of a static icon.
		if payload_data.get("type", "") == "unit":
			var ud_p = Registry.get_unit(StringName(payload_data.get("unit_id", "")))
			if ud_p != null and (ud_p.base_sprite != null or ud_p.head_sprite != null):
				# render_scale 1.0 = exact in-world size + mount geometry;
				# fully opaque (a real unit, not a ghost).
				EnemyUnit.draw_unit_payload(self, ud_p, payload_data, payload_pos, 1.0, 0.0, 1.0)
				continue
		# Draw the payload at full size (draw directly on this canvas, not via building_sys)
		if icon != null:
			if payload_data.get("type", "") == "building":
				# Buildings use rotation + texture offset
				var effective_rot: int = payload_rot
				var pd_block = Registry.get_block(StringName(payload_data.get("block_id", "")))
				if pd_block and pd_block.tags.has("shaft"):
					effective_rot = (payload_rot + 1) % 4
				var draw_angle: float = effective_rot * PI / 2.0 + PI / 2.0
				draw_set_transform(payload_pos, draw_angle)
				draw_texture_rect(icon, Rect2(-payload_pixel_w / 2.0, -payload_pixel_h / 2.0, payload_pixel_w, payload_pixel_h), false, Color(1, 1, 1, 0.8))
				draw_set_transform(Vector2.ZERO, 0.0)
			else:
				# Units: draw without rotation, at actual texture size
				draw_texture_rect(icon, Rect2(payload_pos.x - payload_pixel_w / 2.0, payload_pos.y - payload_pixel_h / 2.0, payload_pixel_w, payload_pixel_h), false, Color(1, 1, 1, 0.8))
		else:
			if payload_data.get("type", "") == "unit":
				var uid: StringName = StringName(payload_data.get("unit_id", ""))
				var ud = Registry.get_unit(uid)
				var uc: Color = ud.color if ud and ud.color != Color() else Color(0.5, 0.8, 0.3)
				uc.a = 0.8
				draw_circle(payload_pos, payload_pixel_w / 2.0, uc)
				draw_arc(payload_pos, payload_pixel_w / 2.0, 0, TAU, 24, uc.lightened(0.3), 1.5)
			else:
				draw_rect(Rect2(payload_pos.x - payload_pixel_w / 2.0, payload_pos.y - payload_pixel_h / 2.0, payload_pixel_w, payload_pixel_h),
					Color(0.6, 0.6, 0.6, 0.8), true)
		# Outline around payload
		draw_rect(Rect2(payload_pos.x - payload_pixel_w / 2.0, payload_pos.y - payload_pixel_h / 2.0, payload_pixel_w, payload_pixel_h),
			Color(1, 1, 1, 0.2), false, 1.0)


func _draw_drill_progress_bars() -> void:
	var building_sys = _building_sys_ref()

	for grid_pos in drill_timers:
		if not main.placed_buildings.has(grid_pos):
			continue

		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null:
			continue

		# Calculate fill percentage
		var cycle_time = data.production_time if data.production_time > 0 else default_drill_time
		var remaining = drill_timers[grid_pos]
		var pct = clampf(1.0 - (remaining / cycle_time), 0.0, 1.0)

		# Also check if there's actually a deposit underneath
		var terrain = _terrain_ref()
		if terrain == null:
			continue

		# Drill faces toward the ore on the adjacent wall
		var rotation = main.building_rotation.get(grid_pos, 0)
		var facing_pos = grid_pos + DIR_VECTORS[rotation]
		var ore = terrain.get_ore_at(facing_pos)
		if ore == null or ore.minable_resource == &"":
			continue

		var world_pos = main.grid_to_world(grid_pos)
		var offset = Vector2.ZERO
		if building_sys:
			offset = building_sys._get_top_offset(world_pos)

		var bar_w := 40.0
		var bar_h := 3.0
		var bar_pos = world_pos + offset + Vector2(
			(main.GRID_SIZE - bar_w) / 2.0,
			main.GRID_SIZE + 2.0
		)

		# Background
		draw_rect(Rect2(bar_pos, Vector2(bar_w, bar_h)),
			Color(0.1, 0.1, 0.1, 0.6), true)
		# Green fill
		draw_rect(Rect2(bar_pos, Vector2(bar_w * pct, bar_h)),
			Color(0.3, 0.9, 0.3, 0.8), true)


func _draw_pump_progress_bars() -> void:
	# Pumps now produce continuously, so the cycle progress bar that
	# used to fill over `production_time` no longer applies. Instead,
	# show a static blue bar whose fill = current power-efficiency × depth
	# multiplier — so the player can see at a glance how productive
	# each pump is.
	var building_sys = _building_sys_ref()
	var terrain = _terrain_ref()
	if terrain == null:
		return
	var power_sys = _power_sys_ref()
	for grid_pos in _bucket("pump"):
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null or not data.tags.has("pump"):
			continue
		var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if anchor != grid_pos:
			continue
		# Need a liquid underneath at all.
		var max_depth: int = 0
		var has_liquid := false
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				var cp: Vector2i = anchor + Vector2i(x, y)
				var lt = terrain.get_liquid_at(cp)
				if lt != null and lt.extracted_liquid != &"":
					has_liquid = true
					if terrain.has_method("get_water_depth_at"):
						var d_here: int = int(terrain.get_water_depth_at(cp))
						if d_here > max_depth:
							max_depth = d_here
		if not has_liquid:
			continue
		if max_depth <= 0:
			max_depth = 2
		var depth_mult: float = float(max_depth) / 2.0
		var net_eff: float = 1.0
		if power_sys and power_sys.has_method("get_electrical_efficiency"):
			net_eff = clampf(float(power_sys.get_electrical_efficiency(anchor)), 0.0, 1.0)
		var pct: float = clampf(depth_mult * net_eff, 0.0, 1.5) / 1.5

		var world_pos = main.grid_to_world(anchor)
		var offset = Vector2.ZERO
		if building_sys:
			offset = building_sys._get_top_offset(world_pos)
		var bar_w: float = float(data.grid_size.x) * main.GRID_SIZE * 0.6
		var bar_h := 3.0
		var bar_pos: Vector2 = world_pos + offset + Vector2(
			(float(data.grid_size.x) * main.GRID_SIZE - bar_w) / 2.0,
			float(data.grid_size.y) * main.GRID_SIZE + 2.0,
		)
		draw_rect(Rect2(bar_pos, Vector2(bar_w, bar_h)),
			Color(0.1, 0.1, 0.1, 0.6), true)
		draw_rect(Rect2(bar_pos, Vector2(bar_w * pct, bar_h)),
			Color(0.3, 0.5, 0.9, 0.8), true)


# =========================
# FACTORY LOGIC
# =========================

## Processes all factories with directional inputs/outputs.
## Phases: collecting → processing → outputting → collecting.
func _update_factories(delta: float) -> void:
	var processed := {}

	for grid_pos in _bucket("factory"):
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null:
			continue
		# Refabricators run in their own update loop; the standard factory
		# path would try to produce nothing (no produced_unit) or mishandle
		# the payload-in requirement.
		if data.tags.has("refabricator"):
			continue
		# Extractors (drills, scrapers, impact drills, …) are driven by
		# `_update_drills` — they have their own `drill_timers` cycle.
		# Without this skip an `omnidirectional` extractor like the
		# impact drill ends up tracked by BOTH loops, painting two
		# in-world progress bars (green from the drill loop + orange
		# from the factory loop).
		if data.category == BlockData.BlockCategory.EXTRACTORS:
			continue
		# Omnidirectional factories intentionally have empty side_inputs/side_outputs,
		# so keep them in the loop — the processing logic handles them separately.
		if data.side_inputs.is_empty() and data.side_outputs.is_empty() and data.produced_unit == &"" and not data.tags.has("omnidirectional") and data.output_sides.is_empty():
			continue

		# Handle multi-tile factories (use anchor as origin)
		var anchor = main.get_building_anchor(grid_pos)
		var origin: Vector2i = anchor if anchor != null else grid_pos
		if processed.has(origin):
			continue
		processed[origin] = true

		# Skip disabled or under-construction buildings
		var sector_script = _sector_script_ref()
		if sector_script and sector_script.is_building_disabled(origin):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue

		# Electrical power: efficiency scales the processing timer below
		# instead of gating the factory on/off. A fully-brownout'd network
		# (no generators at all) still skips this tick so nothing progresses.
		var power_sys_f = _power_sys_ref()
		var is_unit_fabricator: bool = data.produced_unit != &""
		# Per-recipe power: a recipe-select factory whose active recipe specifies
		# "power" draws that instead of the block's electrical_power_use. Pushed
		# to the power system as a dynamic override (cleared back to static when
		# the recipe has no override / none is selected).
		if power_sys_f and data.factory_recipes != null and data.factory_recipes.size() > 0:
			var rp_rec: Dictionary = _get_selected_recipe(data, origin)
			if not rp_rec.is_empty() and rp_rec.has("power"):
				power_sys_f.set_dynamic_power_use(origin, float(rp_rec["power"]))
			else:
				power_sys_f.clear_dynamic_power_use(origin)
		var factory_power_eff: float = 1.0
		if power_sys_f and (data.electrical_power_use > 0 or is_unit_fabricator):
			factory_power_eff = power_sys_f.get_electrical_efficiency(origin)
			if factory_power_eff <= 0.0:
				continue

		# Initialize state if needed
		if not factory_buffers.has(origin):
			factory_buffers[origin] = {
				"inputs": {},
				"phase": "collecting",
				"timer": 0.0,
				"pending_outputs": {},
			}

		var state = factory_buffers[origin]

		# Recipe-select factories (Rod Shapper etc.) stay idle until the
		# player picks a recipe via the world menu. Without a selection the
		# factory refuses inputs and does not advance — matches the Unit
		# Refabricator's "pick a T2 first" gate.
		if data.factory_recipes != null and data.factory_recipes.size() > 0:
			if _get_selected_recipe(data, origin).is_empty():
				continue

		match state["phase"]:
			"collecting":
				# Don't start production if storage is full — UNLESS at least one
				# output can still be delivered externally. That lets a multi-
				# output factory keep running while one product is backed up (the
				# electrolyzer keeps making hydrogen with its oxygen pipe jammed;
				# the surplus oxygen is vented in _factory_try_output). Skipped
				# for unit fabricators.
				if not is_unit_fabricator and _is_storage_full(origin, data) \
						and not _factory_has_output_route(origin, data):
					continue
				# FEROX (enemy) fabricators ignore both the player's tech
				# tree and the player's per-unit cap — those gates are
				# about player progression, not enemy spawning.
				var fab_faction: int = main.get_building_faction(origin)
				var is_player_fab: bool = fab_faction != main.Faction.FEROX
				# Don't start unit production if the unit isn't researched
				# yet. The require_research toggle only governs block
				# placement — producing a unit you haven't unlocked would
				# bypass the tech tree's intent regardless of that flag.
				# Sandbox mode (TechTree.unlock_all) still short-circuits
				# is_researched to true, so that mode keeps working.
				if is_player_fab and is_unit_fabricator and TechTree.nodes.has(data.produced_unit) and not TechTree.is_researched(data.produced_unit):
					continue
				# Don't start unit production if at unit cap for this type
				if is_player_fab and is_unit_fabricator and main.has_method("can_spawn_unit") and not main.can_spawn_unit(data.produced_unit):
					continue
				# Check if all required inputs are met
				if _factory_has_all_inputs(state, data, origin):
					# Don't deduct upfront — _consume_progressive drains
					# the buffer in step with the timer below so the
					# tooltip's "have/needed" bars visibly tick down.
					state["phase"] = "processing"
					# Unit fabricators use the unit's build_time
					if is_unit_fabricator:
						var unit_data = Registry.get_unit(data.produced_unit)
						state["timer"] = unit_data.build_time if unit_data else 5.0
					else:
						state["timer"] = _get_effective_production_time(data, origin)
					state["timer_total"] = state["timer"]
					state["recipe_consumed"] = {}

			"processing":
				# Progress is gated by what's actually in the buffer —
				# if the player pulls items out mid-build, the timer
				# stalls until enough material returns to cover the
				# next step. Mirrors the way drone construction stalls
				# on a missing resource.
				var _recipe := _get_effective_inputs(data, origin)
				var _t_total: float = float(state.get("timer_total", state["timer"] + 0.0001))
				if _t_total <= 0.0:
					_t_total = 0.0001
				if not state.has("recipe_consumed"):
					state["recipe_consumed"] = {}
				var _factory_od: float = 1.0
				if main.has_method("get_overdrive_multiplier"):
					_factory_od = main.get_overdrive_multiplier(origin)
				var _tentative_timer: float = state["timer"] - delta * factory_power_eff * _factory_od
				var _new_prog: float = clampf(1.0 - _tentative_timer / _t_total, 0.0, 1.0)
				if _can_afford_progress(state["inputs"], _recipe, state["recipe_consumed"], _new_prog):
					state["timer"] = _tentative_timer
					_consume_progressive(state["inputs"], _recipe, state["recipe_consumed"], _new_prog)
				# Otherwise: don't advance the timer this tick, leaving
				# the build paused until items show up.
				if state["timer"] <= 0:
					# Final flush — guarantee the full recipe has been
					# deducted by the time output begins.
					_consume_progressive(state["inputs"], _recipe, state["recipe_consumed"], 1.0)
					if is_unit_fabricator:
						# Enter the ejection animation phase. Actual placement/
						# payload-push happens when the animation finishes.
						state["timer"] = 0.0
						state["phase"] = "ejecting"
						state["eject_progress"] = 0.0
					else:
						state["phase"] = "outputting"
						# Same tech-tree gating as the drill path: only the
						# player's own factories count toward `item_produced`
						# so pre-placed FEROX furnaces / extractors don't
						# unlock Iron and Steel on sector landing.
						var factory_is_lumina: bool = main.get_building_faction(origin) == main.Faction.LUMINA
						# Build pending outputs list. Omnidirectional factories
						# have no side_outputs — derive the pending list from
						# output_items instead (one entry per item unit to push).
						var pending := {}
						if data.tags.has("omnidirectional") or not data.output_sides.is_empty():
							var slot: int = 0
							# Recipe-select factories override output_items per
							# the picked recipe; fall back to data.output_items
							# for normal factories.
							var out_dict: Dictionary = _get_effective_outputs(data, origin)
							for raw_id in out_dict:
								var out_sn := StringName(raw_id)
								var amt: int = int(out_dict[raw_id])
								for i in range(amt):
									pending[str(slot)] = out_sn
									slot += 1
									if factory_is_lumina:
										main.item_produced.emit(out_sn)
							# Random one-of-N output table (Slag Caster etc.):
							# emit a SINGLE weighted-random pick on top of the
							# deterministic outputs above.
							if data.random_outputs != null and not data.random_outputs.is_empty():
								var rand_sn: StringName = _pick_random_output(data.random_outputs)
								if rand_sn != &"":
									pending[str(slot)] = rand_sn
									slot += 1
									if factory_is_lumina:
										main.item_produced.emit(rand_sn)
						else:
							for rel_dir_key in data.side_outputs:
								var out_id := StringName(data.side_outputs[rel_dir_key])
								pending[rel_dir_key] = out_id
								if factory_is_lumina:
									main.item_produced.emit(out_id)
						state["pending_outputs"] = pending

			"outputting":
				_factory_try_output(origin, data, state)
				if state["pending_outputs"].is_empty():
					state["phase"] = "collecting"

			"ejecting":
				# Animate the finished unit from the fabricator center toward
				# the front edge. Eject speed also scales with power so the
				# unit doesn't slide out of a brownout'd fabricator at full
				# speed while production was throttled.
				var eject_speed: float = 1.6
				state["eject_progress"] = minf(1.0, float(state.get("eject_progress", 0.0)) + delta * eject_speed * factory_power_eff)
				if state["eject_progress"] >= 1.0:
					var payload_data := {
						"type": "unit",
						"unit_id": data.produced_unit,
					}
					if _try_deliver_fabricated_unit(origin, data, payload_data):
						state["phase"] = "collecting"
						state.erase("eject_progress")
					else:
						state["phase"] = "holding"
						state["held_payload"] = payload_data

			"holding":
				# Keep retrying delivery until it succeeds. `held_payload`
				# isn't persisted across save/load (see save_manager.gd),
				# so reconstruct it from data.produced_unit when missing
				# — otherwise a fabricator that was saved mid-hold would
				# sit here forever with nothing to retry.
				var held = state.get("held_payload", null)
				if held == null and data.produced_unit != &"":
					held = {"type": "unit", "unit_id": data.produced_unit}
					state["held_payload"] = held
				if held != null and _try_deliver_fabricated_unit(origin, data, held):
					state.erase("held_payload")
					state.erase("eject_progress")
					state["phase"] = "collecting"


## Returns the effective input requirement dict for a factory.
## For unit fabricators, this is the produced unit's build_cost (with the
## short item ids like "copper" normalized to full runtime ids like
## "mat_copper" so they match what conveyors carry).
## For regular factories, it's the BlockData's input_items as-is.
func _get_effective_inputs(data: BlockData, anchor: Vector2i = Vector2i(-2147483648, -2147483648)) -> Dictionary:
	if data.produced_unit != &"":
		var unit = Registry.get_unit(data.produced_unit)
		if unit != null and not unit.build_cost.is_empty():
			return _normalize_item_keys(unit.build_cost)
	# Recipe-select factories override input_items with the active recipe.
	# The caller passes the factory's anchor so we can look up the
	# per-instance selection. Falls back to data.input_items when no anchor
	# is supplied (e.g. tooltip / preview previews that just want a baseline).
	if data.factory_recipes != null and data.factory_recipes.size() > 0:
		var rec: Dictionary = _get_selected_recipe(data, anchor)
		if not rec.is_empty():
			return _normalize_item_keys(rec.get("input", {}))
		return {}
	return data.input_items


## Returns the currently-selected recipe Dictionary for `anchor`, or {} if
## no recipe is selected (factory should stay idle). Looks up
## `factory_recipe_state[anchor]` against `data.factory_recipes`.
func _get_selected_recipe(data: BlockData, anchor: Vector2i) -> Dictionary:
	if data == null or data.factory_recipes == null or data.factory_recipes.size() == 0:
		return {}
	# Auto-recipe factories (Water Centrifuge) have no player picker: the
	# active recipe is whichever recipe's input is currently buffered. The
	# input gate (`_try_accept_factory_item`) only ever lets ONE recipe's
	# input in at a time, so at most one recipe matches here.
	if data.tags.has("auto_recipe"):
		if not factory_buffers.has(anchor):
			return {}
		var buf_inputs: Dictionary = factory_buffers[anchor].get("inputs", {})
		for entry in data.factory_recipes:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var in_dict: Dictionary = entry.get("input", {})
			for in_id in in_dict:
				if int(buf_inputs.get(StringName(in_id), 0)) > 0:
					return entry
		return {}
	var sel: StringName = StringName(factory_recipe_state.get(anchor, &""))
	if sel == &"":
		return {}
	for entry in data.factory_recipes:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if StringName(entry.get("id", &"")) == sel:
			return entry
	return {}


## Returns the output dict for this factory: selected recipe's output for
## recipe-select factories, or `data.output_items` otherwise.
func _get_effective_outputs(data: BlockData, anchor: Vector2i = Vector2i(-2147483648, -2147483648)) -> Dictionary:
	if data.factory_recipes != null and data.factory_recipes.size() > 0:
		var rec: Dictionary = _get_selected_recipe(data, anchor)
		if not rec.is_empty():
			return _normalize_item_keys(rec.get("output", {}))
		return {}
	return data.output_items


## Production-cycle length for this factory — the selected recipe's per-recipe
## "time" override when present, otherwise the block's `production_time`.
func _get_effective_production_time(data: BlockData, anchor: Vector2i = Vector2i(-2147483648, -2147483648)) -> float:
	if data.factory_recipes != null and data.factory_recipes.size() > 0:
		var rec: Dictionary = _get_selected_recipe(data, anchor)
		if not rec.is_empty() and rec.has("time"):
			return float(rec["time"])
	return data.production_time


## Electrical draw for this factory — the selected recipe's per-recipe "power"
## override when present, otherwise the block's `electrical_power_use`. The
## block still needs a non-zero `electrical_power_use` baseline to register as
## a consumer at all; the override only changes the amount drawn.
func _get_effective_power(data: BlockData, anchor: Vector2i = Vector2i(-2147483648, -2147483648)) -> float:
	if data.factory_recipes != null and data.factory_recipes.size() > 0:
		var rec: Dictionary = _get_selected_recipe(data, anchor)
		if not rec.is_empty() and rec.has("power"):
			return float(rec["power"])
	return data.electrical_power_use


## Public setter for the recipe-pick world menu. `recipe_id` must match one
## of `BlockData.factory_recipes[*].id`, or be empty to reset the factory
## to "no recipe — idle". Wipes the factory_buffers slot so a stale
## in-progress production of the previous recipe doesn't leak into the new
## one.
## Sets the landing pad's filter slot. `slot` is 0 or 1; `item_id` may be
## an item, fluid, or `&""` to clear the slot. The filter array always
## stays compact (no empty middle slots) so the popup UI doesn't have
## to special-case gap rendering.
func set_landing_pad_filter_slot(anchor: Vector2i, slot: int, item_id: StringName) -> void:
	var arr: Array = landing_pad_filters.get(anchor, [])
	# Pad the array out so the slot index is valid, then assign / clear.
	while arr.size() <= slot:
		arr.append(&"")
	arr[slot] = item_id
	# Compact: drop trailing empties so the dict reads the same regardless
	# of which slot the player cleared first.
	while arr.size() > 0 and arr[arr.size() - 1] == &"":
		arr.pop_back()
	if arr.is_empty():
		landing_pad_filters.erase(anchor)
	else:
		landing_pad_filters[anchor] = arr


func get_landing_pad_filter(anchor: Vector2i) -> Array:
	return landing_pad_filters.get(anchor, [])


func set_factory_recipe(anchor: Vector2i, recipe_id: StringName) -> void:
	factory_recipe_state[anchor] = recipe_id
	# Reset the build buffer so a half-finished cycle of recipe A doesn't
	# carry into recipe B. Inputs already in storage stay put (player can
	# pull them back out via the storage menu).
	if factory_buffers.has(anchor):
		factory_buffers[anchor]["phase"] = "collecting"
		factory_buffers[anchor]["timer"] = 0.0
		factory_buffers[anchor]["recipe_consumed"] = {}


## Normalizes an item dict's keys to the full "mat_*" form used by runtime
## item_ids on conveyors. Accepts keys like "copper" → "mat_copper" and
## leaves already-prefixed keys ("mat_copper") alone. Used so that unit
## build_cost dicts (which use the short BlockData.build_cost convention)
## can be compared against runtime conveyor item StringNames.
func _normalize_item_keys(d: Dictionary) -> Dictionary:
	var out := {}
	for raw_id in d:
		var s := String(raw_id)
		var normalized: String = s if s.begins_with("mat_") else "mat_" + s
		# If the normalized id doesn't exist as an item, fall back to the
		# original so we don't silently lose non-material inputs.
		if Registry.get_item_or_fluid(StringName(normalized)) == null \
				and Registry.get_item_or_fluid(StringName(s)) != null:
			normalized = s
		out[normalized] = d[raw_id]
	return out


## Returns true if `inputs` has enough material to cover the recipe up to
## `progress` (0..1) given what's already been consumed. Used by factory
## and refab tick loops to stall the timer when the buffer can't pay for
## the next progress step — e.g. the player pulled an ingredient out via
## the storage menu mid-build.
func _can_afford_progress(inputs: Dictionary, recipe: Dictionary, consumed: Dictionary, progress: float) -> bool:
	progress = clampf(progress, 0.0, 1.0)
	for raw_id in recipe:
		var sn := StringName(raw_id)
		var needed: int = int(recipe[raw_id])
		var target: int = int(progress * float(needed))
		var already: int = int(consumed.get(sn, 0))
		var diff: int = target - already
		if diff <= 0:
			continue
		if int(inputs.get(sn, 0)) < diff:
			return false
	return true


## Drains items from `inputs` to match the per-recipe consumption ratio
## `progress` (0..1). `consumed` tracks the cumulative per-item amount
## already deducted across previous ticks so each call only takes the
## delta. Used by factories and refabricators to spread the build cost
## evenly over the production timer instead of charging it all upfront —
## the buffer visibly drains as the unit/item is being constructed.
func _consume_progressive(inputs: Dictionary, recipe: Dictionary, consumed: Dictionary, progress: float) -> void:
	progress = clampf(progress, 0.0, 1.0)
	for raw_id in recipe:
		var sn := StringName(raw_id)
		var needed: int = int(recipe[raw_id])
		# Floor so we never deduct more than the linear ratio at the
		# current progress; the final flush at progress=1.0 picks up the
		# remainder.
		var target: int = int(progress * float(needed))
		var already: int = int(consumed.get(sn, 0))
		if target <= already:
			continue
		var diff: int = target - already
		var have: int = int(inputs.get(sn, 0))
		var take: int = mini(diff, have)
		if take <= 0:
			continue
		var rem: int = have - take
		if rem <= 0:
			inputs.erase(sn)
		else:
			inputs[sn] = rem
		consumed[sn] = already + take


## Returns true if the factory's input buffer has all required items.
## Handles String/.tres keys vs StringName/runtime keys.
func _factory_has_all_inputs(state: Dictionary, data: BlockData, anchor: Vector2i = Vector2i(-2147483648, -2147483648)) -> bool:
	var inputs := _get_effective_inputs(data, anchor)
	for raw_id in inputs:
		var sn_id := StringName(raw_id)
		var needed: int = int(inputs[raw_id])
		if state["inputs"].get(sn_id, 0) < needed:
			return false
	return true


## Tries to push all pending outputs to their target cells.
## If a push fails, the item goes into block storage instead.
## Successfully delivered outputs are removed from pending_outputs.
##
## Omnidirectional factories (tag "omnidirectional") ignore side_outputs and
## instead try every cell around their full footprint, skipping conveyors
## that are pointing INTO the factory (those are input-feeders).
## True if at least one of the factory's outputs has somewhere external to go
## (a pipe for fluids, an empty conveyor / core for items) on its output side.
## Lets the production gate keep a multi-output factory running when one output
## is backed up but another can still be delivered (e.g. the electrolyzer
## keeps making hydrogen while its oxygen pipe is jammed).
func _factory_has_output_route(origin: Vector2i, data: BlockData) -> bool:
	var rot: int = main.building_rotation.get(origin, 0)
	var outs: Dictionary = _get_effective_outputs(data, origin)
	if outs.is_empty():
		return false
	var has_os: bool = not data.output_sides.is_empty()
	var is_omni: bool = data.tags.has("omnidirectional")
	for raw_id in outs:
		var oid := StringName(raw_id)
		var cells: Array
		if has_os and data.output_sides.has(oid):
			var wdir: int = (int(data.output_sides[oid]) + rot) % 4
			cells = _side_neighbor_cells(origin, data.grid_size, wdir)
		elif is_omni:
			cells = _get_full_ring(origin, data.grid_size)
		else:
			cells = _get_all_output_cells(origin, data.grid_size, rot)
		var is_fluid: bool = Registry.get_fluid(oid) != null
		for cell in cells:
			if _is_cross_faction(origin, cell):
				continue
			if is_fluid:
				if _is_pipe_cell(cell):
					return true
			else:
				if _is_core_cell(cell):
					return true
				if _is_conveyor_cell(cell) and not conveyor_items.has(cell):
					return true
	return false


func _factory_try_output(origin: Vector2i, data: BlockData, state: Dictionary) -> void:
	var rot: int = main.building_rotation.get(origin, 0)
	var delivered := []
	var is_omni: bool = data.tags.has("omnidirectional")
	var has_output_sides: bool = not data.output_sides.is_empty()

	# Omnidirectional factories AND directional factories that route their
	# products via `output_sides` (e.g. the Graphite Electrolyzer) share this
	# ring-based output path. Plain directional factories use the side_outputs
	# path below.
	if is_omni or has_output_sides:
		# Build the ring of cells around the factory's full footprint.
		var ring: Array[Vector2i] = _get_all_output_cells(origin, data.grid_size, rot)
		# Track how many outputs left via an external destination (pipe /
		# conveyor / core) this tick, plus any fluid outputs that couldn't be
		# delivered OR stored. If something got out externally, those stuck
		# fluids are vented at the end so a single jammed output (e.g. oxygen)
		# doesn't halt the whole factory's other output (hydrogen).
		var delivered_external: int = 0
		var stuck_fluid_keys := []
		for rel_dir_key in state["pending_outputs"]:
			var out_item: StringName = state["pending_outputs"][rel_dir_key]
			# Per-output directional routing: an item/fluid listed in
			# `output_sides` may ONLY exit the configured side, ROTATED by the
			# block's rotation (so the electrolyzer's hydrogen-up / oxygen-down
			# turns with the building). Unlisted outputs use the full ring.
			var candidates: Array[Vector2i] = ring
			if has_output_sides and data.output_sides.has(out_item):
				var wdir: int = (int(data.output_sides[out_item]) + rot) % 4
				candidates = _side_neighbor_cells(origin, data.grid_size, wdir)
			var pushed := false
			for target_pos in candidates:
				if _is_cross_faction(origin, target_pos):
					continue
				# Skip conveyors that are pointing INTO the factory (feeders).
				if _conveyor_feeds_toward_building(target_pos, origin, data.grid_size):
					continue
				var push_entry_dir := _get_entry_dir_from_building(target_pos, origin, data.grid_size)
				if _try_push_item(target_pos, out_item, push_entry_dir):
					pushed = true
					break
			if pushed:
				delivered.append(rel_dir_key)
				delivered_external += 1
			elif _add_to_storage(origin, out_item, data):
				# Couldn't push anywhere — fall back to internal storage.
				delivered.append(rel_dir_key)
			elif Registry.get_fluid(out_item) != null:
				# A fluid output that can't be pushed OR stored — a candidate
				# for venting (resolved below). Items instead hold (back-pressure).
				stuck_fluid_keys.append(rel_dir_key)
		# Vent stuck fluid outputs ONLY if another output got out this tick. A
		# fully-blocked factory holds everything (no waste); a partially-blocked
		# one keeps its working output flowing and vents the jammed surplus.
		if delivered_external > 0:
			for k in stuck_fluid_keys:
				delivered.append(k)
	else:
		for rel_dir_key in state["pending_outputs"]:
			var rel_dir: int = int(rel_dir_key)
			var world_dir: int = (rel_dir + rot) % 4
			var target_pos: Vector2i = origin + DIR_VECTORS[world_dir]
			var out_item: StringName = state["pending_outputs"][rel_dir_key]
			var entry_dir: int = (world_dir + 2) % 4  # Item enters target from opposite side

			# Skip conveyors that are pointing INTO the factory (feeders).
			if _conveyor_feeds_into(target_pos, origin):
				# Can't use this side — fall back to storage for this cycle.
				if _add_to_storage(origin, out_item, data):
					delivered.append(rel_dir_key)
				continue

			# Block cross-faction factory output
			if _is_cross_faction(origin, target_pos):
				if _add_to_storage(origin, out_item, data):
					delivered.append(rel_dir_key)
			elif _try_push_item(target_pos, out_item, entry_dir):
				delivered.append(rel_dir_key)
			else:
				if _add_to_storage(origin, out_item, data):
					delivered.append(rel_dir_key)

	for key in delivered:
		state["pending_outputs"].erase(key)


## Returns true if a cell is a conveyor whose forward direction points into
## ANY cell of the given building footprint. Multi-tile variant of
## _conveyor_feeds_into.
func _conveyor_feeds_toward_building(conv_pos: Vector2i, origin: Vector2i, grid_size: Vector2i) -> bool:
	if not _is_conveyor_cell(conv_pos):
		return false
	var rot: int = main.building_rotation.get(conv_pos, 0)
	var forward: Vector2i = DIR_VECTORS[rot % 4]
	var target: Vector2i = conv_pos + forward
	# Check if target lands inside the footprint rect.
	if target.x >= origin.x and target.x < origin.x + grid_size.x \
	and target.y >= origin.y and target.y < origin.y + grid_size.y:
		return true
	return false


## Attempts to deliver a freshly-built unit out of a fabricator.
##
## Rules (applied per front cell, summarised across the whole front edge):
##   1. If any front cell is a payload-interacting block (payload/freight
##      conveyor, mass driver, refabricator), try to hand the unit to it.
##      If at least one accepts, delivery succeeds.
##   2. If every payload target on the front is currently full/busy, the
##      fabricator holds — we don't spawn on the ground next to a payload
##      output that's supposed to carry this unit away.
##   3. Otherwise, if every front cell is either empty, a walkable terrain
##      tile, or a passable transport block (regular conveyor, duct), the
##      unit spawns on the ground at the front edge.
##   4. Otherwise (non-passable building or pathfinding-blocking wall on
##      any front cell) the fabricator holds and retries next tick.
##
## Returns true when delivery succeeded. Callers that get false should
## keep the unit as a held payload and retry.
func _try_deliver_fabricated_unit(origin: Vector2i, data: BlockData, payload_data: Dictionary) -> bool:
	# Resolve the unit this delivery is for. Unit fabricators set it via
	# data.produced_unit; refabricators (and other wrappers) supply it in
	# the payload dict — use whichever is populated.
	var unit_id: StringName = data.produced_unit
	if unit_id == &"":
		unit_id = StringName(payload_data.get("unit_id", ""))
	if unit_id == &"":
		return false

	# Unit cap (player only). Enemy fabricators don't respect this.
	var faction: int = main.get_building_faction(origin)
	if faction != main.Faction.FEROX:
		if main.has_method("can_spawn_unit") and not main.can_spawn_unit(unit_id):
			return false

	var rot: int = main.building_rotation.get(origin, 0)
	var front_cells: Array[Vector2i] = _get_front_edge(origin, data.grid_size, rot)
	if front_cells.is_empty():
		return false
	var entry_dir: int = (rot + 2) % 4

	# Rule 1 + 2: if any front cell is a payload target, the unit must
	# enter *that* block — first cell that accepts wins. If none accept,
	# hold instead of falling through to a ground spawn.
	var has_payload_target := false
	for cell in front_cells:
		if _is_unit_payload_target(cell):
			has_payload_target = true
			if _try_deliver_to_payload_target(cell, payload_data, unit_id, entry_dir):
				return true
	if has_payload_target:
		return false

	# Rule 3 + 4: no payload targets on the front — either spawn on the
	# ground or hold if there's a solid blocker.
	var unit_data = Registry.get_unit(unit_id)
	if unit_data == null:
		return false
	var ml: int = unit_data.movement_layer
	var is_flying: bool = (ml == UnitData.MovementLayer.HOVER or ml == UnitData.MovementLayer.FLYING)
	var is_naval: bool = (ml == UnitData.MovementLayer.NAVAL)

	var terrain = _terrain_ref()
	var unit_mgr_n = _unit_mgr_ref()
	var gs_n: int = main.GRID_SIZE
	for cell in front_cells:
		if main.placed_buildings.has(cell) and not is_flying:
			# Passable transport blocks (plain belts, ducts) let the unit
			# stand on the tile and walk off. Anything else (a factory, a
			# turret, a wall-building) is a solid blocker.
			var blocker = Registry.get_block(main.placed_buildings[cell])
			var blocker_walkable: bool = blocker != null and blocker.is_transport() \
				and not (blocker.tags.has("payload") or blocker.tags.has("freight"))
			if not blocker_walkable:
				return false
		if not is_flying and terrain != null and terrain.wall_tiles.has(cell):
			var tile_data = Registry.get_tile(terrain.wall_tiles[cell])
			if tile_data and tile_data.blocks_pathfinding:
				return false
		# Naval units may only deploy onto navigable water. If any front cell
		# isn't water, HOLD (return false) rather than dumping on dry land.
		if is_naval:
			var cw: Vector2 = Vector2(cell.x * gs_n + gs_n * 0.5, cell.y * gs_n + gs_n * 0.5)
			if unit_mgr_n == null or not unit_mgr_n.is_world_pos_walkable(cw, ml):
				return false

	_spawn_unit_at_building_front(origin, data, unit_id)
	return true


## Variant of `_is_unit_payload_target` that returns true only when the
## target would actually accept the given unit right now. A refabricator
## configured for a different tier-2 (or not configured at all) reports
## false so the payload flow doesn't dead-lock waiting on a target that
## would never pull. Other payload targets (payload/freight conveyor,
## mass driver) report true whenever they're present, even when full —
## those are queue-pressure cases the caller handles separately.
func _payload_target_accepts_unit(cell: Vector2i, unit_id: StringName) -> bool:
	if not main.placed_buildings.has(cell):
		return false
	var anchor: Vector2i = main.building_origins.get(cell, cell)
	var d = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if d == null:
		return false
	if d.tags.has("refabricator"):
		if unit_id == &"":
			return false
		var rs: Dictionary = refabricator_state.get(anchor, {})
		var sel: StringName = StringName(rs.get("selected_t2", &""))
		if sel == &"":
			return false
		# Matching refab counts as an accepting target even when the
		# tier-2 slot is currently full — the player often wants to
		# queue tier-1s on the conveyor so upgrades resume the moment a
		# tier-2 dies, rather than dumping the tier-1 on the ground.
		# Cap-full is a "payload target IS in front but not ready right
		# now" case, which should hold the belt.
		return _get_tier2_unit(unit_id) == sel
	return d.tags.has("payload") or d.tags.has("freight") or d.tags.has("mass_driver")


## Returns true if the cell at `cell` contains a block that interacts with
## unit payloads — payload/freight conveyor, mass driver, or refabricator.
## Used by the fabricator ejection logic to decide whether to push the
## produced unit into the block or spawn it on the ground.
func _is_unit_payload_target(cell: Vector2i) -> bool:
	if not main.placed_buildings.has(cell):
		return false
	var anchor: Vector2i = main.building_origins.get(cell, cell)
	var d = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if d == null:
		return false
	return d.tags.has("payload") or d.tags.has("freight") \
		or d.tags.has("refabricator") or d.tags.has("mass_driver")


## Tries to deliver the produced unit to a payload-interacting block at
## `cell`. Returns true if the block accepted it right now.
##   - refabricator: direct-feed (bypasses payload conveyor routing)
##   - payload / freight conveyor: standard payload push
##   - mass driver: loaded straight into the driver's own state slot so
##     its update loop sees it like a payload picked off an adjacent
##     conveyor, then rotates and launches it
func _try_deliver_to_payload_target(cell: Vector2i, payload_data: Dictionary, unit_id: StringName, entry_dir: int) -> bool:
	var anchor: Vector2i = main.building_origins.get(cell, cell)
	var d = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if d == null:
		return false
	if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
		return false
	if _is_cross_faction(anchor, cell):
		return false

	if d.tags.has("refabricator"):
		return _try_feed_refabricator_direct(anchor, d, unit_id)

	if _is_payload_cell(cell):
		return _try_push_payload(cell, payload_data, entry_dir)

	if d.tags.has("mass_driver"):
		if not mass_driver_state.has(anchor):
			mass_driver_state[anchor] = {
				"payload": null, "head_angle": 0.0, "target_angle": 0.0,
				"recoil": 0.0, "phase": "idle", "cooldown": 0.0, "input_pos": Vector2i.ZERO,
			}
		var md_state: Dictionary = mass_driver_state[anchor]
		if md_state.get("payload") != null:
			return false
		md_state["payload"] = payload_data
		return true

	return false


func _spawn_unit_at_building_front(origin: Vector2i, data: BlockData, unit_id: StringName) -> void:
	if unit_id == &"":
		return
	var unit_data = Registry.get_unit(unit_id)
	if unit_data == null:
		push_warning("LogisticsSystem: Unit '%s' not found for building at %s" % [unit_id, origin])
		return

	var rot: int = main.building_rotation.get(origin, 0)
	var gs: int = main.GRID_SIZE
	var sx: int = data.grid_size.x
	var sy: int = data.grid_size.y

	# Center of the building in world coords
	var center := Vector2(
		(origin.x + sx * 0.5) * gs,
		(origin.y + sy * 0.5) * gs
	)

	# Offset to the middle of the facing edge, then one tile further out
	var spawn_world: Vector2
	match rot:
		0:  # right
			spawn_world = center + Vector2((sx * 0.5 + 0.5) * gs, 0)
		1:  # down
			spawn_world = center + Vector2(0, (sy * 0.5 + 0.5) * gs)
		2:  # left
			spawn_world = center + Vector2(-(sx * 0.5 + 0.5) * gs, 0)
		3:  # up
			spawn_world = center + Vector2(0, -(sy * 0.5 + 0.5) * gs)
		_:
			spawn_world = center + Vector2((sx * 0.5 + 0.5) * gs, 0)

	var unit_mgr = _unit_mgr_ref()
	if unit_mgr:
		var faction: int = main.get_building_faction(origin)
		if faction == main.Faction.FEROX:
			# Route through the fabricator-squad system: the new unit
			# rallies a few tiles in front of its fabricator until the
			# squad has enough firepower (or it's been waiting too long)
			# to break through the player's defenses.
			if unit_mgr.has_method("spawn_enemy_for_fabricator"):
				unit_mgr.spawn_enemy_for_fabricator(spawn_world, unit_id, origin)
			else:
				unit_mgr.spawn_enemy(spawn_world, unit_id)
		else:
			# Check unit cap before spawning player units
			if main.has_method("can_spawn_unit") and not main.can_spawn_unit(unit_id):
				return  # At capacity for this unit type
			unit_mgr.spawn_player_unit(spawn_world, unit_id)
		# Notify sector script of unit production (Lumina only)
		if faction != main.Faction.FEROX:
			if "stats_units_produced" in main:
				main.stats_units_produced += 1
			var sector_script = _sector_script_ref()
			if sector_script:
				sector_script.on_unit_produced(unit_id)


## Tries to accept an item into a factory's input buffer.
## Returns true if the item was accepted (correct side and item type).
func _try_accept_factory_item(grid_pos: Vector2i, item_id: StringName, entry_dir: int) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null:
		return false

	# Launchpad: accepts any item from any side as passenger cargo,
	# capped by max_stored_items. The pod is power-built so the
	# launchpad doesn't reserve any items for construction.
	if data.tags.has("launchpad"):
		var lp_anchor = main.get_building_anchor(grid_pos)
		var lp_origin: Vector2i = lp_anchor if lp_anchor != null else grid_pos
		if not block_storage.has(lp_origin):
			block_storage[lp_origin] = {"items": {}, "fluids": {}}
		var lp_storage: Dictionary = block_storage[lp_origin]
		var lp_items: Dictionary = lp_storage.get("items", {})
		var lp_total: int = 0
		for k in lp_items:
			lp_total += int(lp_items[k])
		var lp_cap: int = data.max_stored_items if data.max_stored_items > 0 else 200
		if lp_total >= lp_cap:
			return false
		lp_items[item_id] = int(lp_items.get(item_id, 0)) + 1
		lp_storage["items"] = lp_items
		block_storage[lp_origin] = lp_storage
		return true

	# Nuclear reactor: accepts uranium_rod / graphite_rod into its
	# block_storage["items"] bucket from any side, capped by
	# max_stored_items. The dedicated NuclearReactorSystem consumes them.
	if data.tags.has("nuclear_reactor"):
		if item_id != &"mat_uranium_rod" and item_id != &"mat_graphite_rod":
			return false
		var nuc_anchor = main.get_building_anchor(grid_pos)
		var nuc_origin: Vector2i = nuc_anchor if nuc_anchor != null else grid_pos
		if not block_storage.has(nuc_origin):
			block_storage[nuc_origin] = {"items": {}, "fluids": {}}
		var nuc_storage: Dictionary = block_storage[nuc_origin]
		var nuc_items: Dictionary = nuc_storage.get("items", {})
		var total: int = 0
		for k in nuc_items:
			total += int(nuc_items[k])
		var nuc_cap: int = data.max_stored_items if data.max_stored_items > 0 else 8
		if total >= nuc_cap:
			return false
		nuc_items[item_id] = int(nuc_items.get(item_id, 0)) + 1
		nuc_storage["items"] = nuc_items
		block_storage[nuc_origin] = nuc_storage
		return true

	# Omnidirectional factories accept on every side and don't need side_inputs set.
	# Unit fabricators also accept from any side — their inputs come from the
	# produced unit's build_cost, not side_inputs.
	# Refabricators accept on every side for the recipe items (same omni-buffer
	# logic), BUT reject items arriving on the front edge — that edge is the
	# output lane and belts running across it shouldn't get their contents
	# silently absorbed. Without this guard a refabricator placed under a
	# fabricator would eat the materials intended for the fabricator above it.
	# A factory that routes outputs via `output_sides` (e.g. the electrolyzer)
	# still accepts inputs on ANY side — only its OUTPUT is directional — so it
	# shares the omnidirectional input path here.
	var is_omni: bool = data.tags.has("omnidirectional") or data.tags.has("refabricator") or not data.output_sides.is_empty()
	var is_unit_fab_early: bool = data.produced_unit != &""
	if not is_omni and not is_unit_fab_early and data.side_inputs.is_empty():
		return false

	# Find the building's origin for multi-tile factories
	var anchor = main.get_building_anchor(grid_pos)
	var origin: Vector2i = anchor if anchor != null else grid_pos
	var rot: int = main.building_rotation.get(origin, 0)

	# Initialize state if needed
	if not factory_buffers.has(origin):
		factory_buffers[origin] = {
			"inputs": {},
			"phase": "collecting",
			"timer": 0.0,
			"pending_outputs": {},
		}

	var state = factory_buffers[origin]
	var is_unit_fab: bool = data.produced_unit != &""

	# Regular factories only accept during collecting; unit fabricators accept
	# during processing too. Omnidirectional factories ALSO accept in every
	# phase — they buffer inputs up to max_stored_items so the belt-fed
	# ingredient side can keep topping up while the factory is mid-cycle.
	if state["phase"] != "collecting":
		var accepts_in_processing: bool = is_unit_fab or is_omni
		if not accepts_in_processing or state["phase"] != "processing":
			if not is_omni or state["phase"] != "outputting":
				return false

	# Auto-recipe factories (Water Centrifuge): accept exactly one of the
	# recipe input fluids at a time. The first matching input "locks" the
	# factory to that recipe until its buffer drains; the OTHER recipe's
	# input is refused while locked, so salt water and sulfur water can never
	# be loaded simultaneously. The active recipe is then resolved from the
	# buffered fluid in `_get_selected_recipe`.
	if data.tags.has("auto_recipe"):
		var matched_amt: int = -1
		var is_known_input: bool = false
		var locked_other: bool = false
		for entry in data.factory_recipes:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var in_dict: Dictionary = entry.get("input", {})
			for in_id in in_dict:
				var in_sn := StringName(in_id)
				if in_sn == item_id:
					is_known_input = true
					matched_amt = int(in_dict[in_id])
				elif int(state["inputs"].get(in_sn, 0)) > 0:
					locked_other = true
		if not is_known_input or locked_other:
			return false
		if matched_amt < 1:
			matched_amt = 1
		var ar_cap: int = data.max_stored_items if data.max_stored_items > 0 else matched_amt * 10
		var ar_have: int = int(state["inputs"].get(item_id, 0))
		if ar_have >= ar_cap:
			return false
		state["inputs"][item_id] = ar_have + 1
		return true

	# Omnidirectional / unit-fabricator path: accept any item that matches one
	# of the factory's effective inputs, regardless of entry direction. Inputs
	# buffer up to max_stored_items per ingredient (defaults to 10× recipe
	# amount so the factory can keep running for a while without a belt
	# refilling every cycle).
	if is_omni or is_unit_fab_early:
		# Pass `origin` so recipe-select factories (Rod Shapper, Compound Mixer,
		# Water Centrifuge) resolve the ACTIVE recipe's inputs. Without the
		# anchor this returned {} for any recipe-select factory and the omni
		# path rejected every ingredient.
		var effective_inputs := _get_effective_inputs(data, origin)
		var recipe_amt: int = -1
		for raw_id in effective_inputs:
			if StringName(raw_id) == item_id:
				recipe_amt = int(effective_inputs[raw_id])
				break
		if recipe_amt < 0:
			return false  # Not one of this factory's inputs
		if recipe_amt < 1:
			recipe_amt = 1
		var cap_o: int = data.max_stored_items if data.max_stored_items > 0 else recipe_amt * 10
		var have_o: int = state["inputs"].get(item_id, 0)
		if have_o >= cap_o:
			return false
		state["inputs"][item_id] = have_o + 1
		return true

	# Check each input side to see if entry_dir matches
	for rel_dir_key in data.side_inputs:
		var rel_dir: int = int(rel_dir_key)
		var world_dir: int = (rel_dir + rot) % 4
		if world_dir == entry_dir:
			# Convert .tres String value to StringName for comparison
			var expected_item := StringName(data.side_inputs[rel_dir_key])
			if item_id == expected_item:
				# Unit fabricators use max_stored_items as cap; regular factories use recipe amount
				var cap: int = 1
				if is_unit_fab and data.max_stored_items > 0:
					cap = data.max_stored_items
				else:
					for raw_id in data.input_items:
						if StringName(raw_id) == item_id:
							cap = data.input_items[raw_id]
							break
				var have: int = state["inputs"].get(item_id, 0)
				if have >= cap:
					return false  # Already full
				state["inputs"][item_id] = have + 1
				return true

	return false


func _draw_factory_progress_bars() -> void:
	var building_sys = _building_sys_ref()

	for grid_pos in factory_buffers:
		var state = factory_buffers[grid_pos]
		if state["phase"] != "processing":
			continue

		if not main.placed_buildings.has(grid_pos):
			continue
		var data = Registry.get_block(main.placed_buildings[grid_pos])
		if data == null:
			continue

		var cycle_time = data.production_time
		var remaining: float = state["timer"]
		var pct = clampf(1.0 - (remaining / cycle_time), 0.0, 1.0)

		var world_pos = main.grid_to_world(grid_pos)
		var offset = Vector2.ZERO
		if building_sys:
			offset = building_sys._get_top_offset(world_pos)

		var bar_w := 40.0
		var bar_h := 3.0
		var bar_pos = world_pos + offset + Vector2(
			(main.GRID_SIZE - bar_w) / 2.0,
			main.GRID_SIZE + 2.0
		)

		# Background
		draw_rect(Rect2(bar_pos, Vector2(bar_w, bar_h)),
			Color(0.1, 0.1, 0.1, 0.6), true)
		# Orange fill (distinguishes from green drill / blue pump bars)
		draw_rect(Rect2(bar_pos, Vector2(bar_w * pct, bar_h)),
			Color(0.9, 0.6, 0.2, 0.8), true)
