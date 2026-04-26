extends Node2D

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

# --- DRILL STATE ---
# Key = Vector2i (grid position of a drill)
# Value = float (seconds remaining until next item is produced)
var drill_timers := {}

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
const ITEM_RADIUS := 8.0
## Size in pixels to draw item textures on conveyors (width & height)
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

func _building_sys_ref() -> Node:
	if _building_sys == null:
		_building_sys = get_node_or_null("/root/Main/BuildingSystem")
	return _building_sys

func _unit_mgr_ref() -> Node:
	if _unit_mgr == null:
		_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	return _unit_mgr


func _ready() -> void:
	await get_tree().process_frame
	_terrain = get_node_or_null("/root/Main/TerrainSystem")
	_power_sys = get_node_or_null("/root/Main/PowerSystem")
	_sector_script = get_node_or_null("/root/Main/SectorScript")
	_building_sys = get_node_or_null("/root/Main/BuildingSystem")
	_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	main.building_placed.connect(_on_building_placed)
	main.building_destroyed.connect(_on_building_destroyed)


func _process(delta: float) -> void:
	if ("world_paused" in main and main.world_paused):
		queue_redraw()
		return
	_update_drills(delta)
	_update_pumps(delta)
	_update_factories(delta)
	_update_conveyors(delta)
	_update_payloads(delta)
	_update_constructors(delta)
	_update_deconstructors(delta)
	_update_refabricators(delta)
	_update_loaders(delta)
	_update_unloaders(delta)
	_update_mass_drivers(delta)
	_update_pipes(delta)
	_update_storage_unloading(delta)
	_update_belt_unloaders(delta)
	queue_redraw()


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

func _update_drills(delta: float) -> void:
	var processed := {}

	for grid_pos in main.placed_buildings:
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
		# Check front edge + one tile ahead for the thing this drill mines.
		var mine_cells = _get_extended_front_edge(origin, data.grid_size, rot)
		var front_cells = _get_front_edge(origin, data.grid_size, rot)

		# Wall miners (wall_crusher) mine blackstone walls into their configured
		# output_items; regular drills mine ore deposits via ore.minable_resource.
		var is_wall_miner: bool = data.tags.has("wall_miner")

		var ore: TerrainTileData = null
		var wall_found: bool = false
		if is_wall_miner:
			for cell in mine_cells:
				if terrain.get_ore_at(cell) != null:
					continue
				if StringName(terrain.wall_tiles.get(cell, &"")) == &"blackstone_wall":
					wall_found = true
					break
			if not wall_found:
				continue
		else:
			for cell in mine_cells:
				ore = terrain.get_ore_at(cell)
				if ore != null and ore.minable_resource != &"":
					break
			if ore == null or ore.minable_resource == &"":
				continue

		# Calculate efficiency: fraction of front-edge tiles that face the target
		# (direct hit or one tile further ahead).
		var front_count: int = front_cells.size()
		var hit_count: int = 0
		var dir: Vector2i
		match rot:
			0: dir = Vector2i(1, 0)
			1: dir = Vector2i(0, 1)
			2: dir = Vector2i(-1, 0)
			3: dir = Vector2i(0, -1)
			_: dir = Vector2i(1, 0)
		for cell in front_cells:
			if is_wall_miner:
				var c1_ok: bool = terrain.get_ore_at(cell) == null and StringName(terrain.wall_tiles.get(cell, &"")) == &"blackstone_wall"
				var c2_ok: bool = terrain.get_ore_at(cell + dir) == null and StringName(terrain.wall_tiles.get(cell + dir, &"")) == &"blackstone_wall"
				if c1_ok or c2_ok:
					hit_count += 1
			else:
				if terrain.get_ore_at(cell) != null:
					hit_count += 1
				elif terrain.get_ore_at(cell + dir) != null:
					hit_count += 1
		var efficiency: float = float(hit_count) / float(front_count) if front_count > 0 else 1.0

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

		drill_timers[origin] -= delta * efficiency * power_eff
		if drill_timers[origin] > 0:
			continue

		# Figure out which item(s) this cycle produces and how many of each.
		# Regular drills produce 1 × minable_resource from the ore tile.
		# Wall miners produce data.output_items (item_id → amount).
		var produced: Dictionary = {}
		if is_wall_miner:
			for raw_id in data.output_items:
				produced[StringName(raw_id)] = int(data.output_items[raw_id])
		else:
			produced[ore.minable_resource] = 1

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


## Returns the front edge cells PLUS one tile further ahead (for extended drill range).
func _get_extended_front_edge(origin: Vector2i, grid_size: Vector2i, rotation: int) -> Array[Vector2i]:
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
		var extended := cell + dir
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

func _update_pumps(delta: float) -> void:
	var processed_pumps := {}
	var terrain = _terrain_ref()
	if terrain == null:
		return
	var sector_script = _sector_script_ref()

	for grid_pos in main.placed_buildings:
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

		if not pump_timers.has(anchor):
			var cycle_time = data.production_time if data.production_time > 0 else default_drill_time
			pump_timers[anchor] = cycle_time

		# Check for liquid underneath any tile of the pump
		var liquid_tile: Variant = null
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				var check_pos: Vector2i = anchor + Vector2i(x, y)
				var lt = terrain.get_liquid_at(check_pos)
				if lt != null and lt.extracted_liquid != &"":
					liquid_tile = lt
					break
			if liquid_tile != null:
				break

		if liquid_tile == null or liquid_tile.extracted_liquid == &"":
			continue

		pump_timers[anchor] -= delta
		if pump_timers[anchor] > 0:
			continue

		var cycle_time = data.production_time if data.production_time > 0 else default_drill_time
		pump_timers[anchor] = cycle_time

		# Don't produce if storage is full
		if _is_storage_full(anchor, data):
			continue

		# Push to all edge cells of the multi-tile building
		var rot: int = main.building_rotation.get(anchor, 0)
		var pushed := false
		# Collect all cells adjacent to the building's edge
		var edge_neighbors: Array[Dictionary] = []
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				var tile: Vector2i = anchor + Vector2i(x, y)
				for dir in range(4):
					var neighbor: Vector2i = tile + DIR_VECTORS[dir]
					# Only push to cells outside the building
					if main.building_origins.get(neighbor, neighbor) != anchor:
						if _is_cross_faction(tile, neighbor):
							continue
						edge_neighbors.append({"pos": neighbor, "dir": dir})

		for edge in edge_neighbors:
			var pump_entry_dir: int = (edge["dir"] + 2) % 4
			if _try_push_item(edge["pos"], liquid_tile.extracted_liquid, pump_entry_dir):
				pushed = true
				break
		# If couldn't push to any output, try storing
		if not pushed:
			_add_to_storage(anchor, liquid_tile.extracted_liquid, data)


## Attempts to place an item or fluid onto a cell.
## Fluids are routed to pipes; items are routed to conveyors.
## entry_dir: direction the item entered from (0-3), or -1 for default (behind belt).
## Returns true if the item was successfully placed.
func _try_push_item(grid_pos: Vector2i, item_id: StringName, entry_dir: int = -1) -> bool:
	# Can't push items onto buildings under construction
	if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
		return false
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

	return false


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

			# Items sitting on an in-progress / derelict / deconstructing
			# transport cell don't move. They pick back up once the block
			# finishes construction.
			if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
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

			# Forward transfer failed. As a fallback, try to side-dump into
			# any perpendicular non-conveyor neighbour that will accept this
			# item (turrets, factories, constructors). Matches the Mindustry
			# convenience where a belt adjacent to an ammo-hungry turret
			# auto-feeds it without needing a router.
			if _try_belt_side_dump(grid_pos, drilRotation, item["item_id"]):
				conveyor_items.erase(grid_pos)

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
	# progress — they literally don't slide this frame.
	for grid_pos in conveyor_items:
		if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
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

	# Pre-decide exit direction for router items so they animate correctly
	for grid_pos in conveyor_items:
		if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
			continue
		var item = conveyor_items[grid_pos]
		if _is_router_cell(grid_pos) and not item.has("exit_dir"):
			var exit_dir: int = _pick_router_exit(grid_pos, item)
			if exit_dir >= 0:
				item["exit_dir"] = exit_dir

	# Advance junction perpendicular-axis items too
	for grid_pos in junction_items:
		if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
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
		# Junction: route to correct slot based on entry axis
		if _is_junction_cell(to) and entry_dir >= 0:
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
		var _is_instant := (_is_sorter_cell(to)
			or _is_inverted_sorter_cell(to) or _is_overflow_cell(to)
			or _is_underflow_cell(to) or _is_bridge_cell(to))

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

	return false


## Handles router item distribution: tries to push the item to 3 output
## directions (all except the entry direction), using round-robin so items
## spread evenly across outputs — just like Mindustry routers.
func _try_router_transfer(grid_pos: Vector2i, item: Dictionary) -> bool:
	var item_entry_dir: int = item.get("entry_dir", -1)

	# Build the 3 output directions (all except where the item came from)
	# If entry_dir is unknown (-1), exclude the direction behind the router's rotation
	var exclude_dir: int = item_entry_dir
	if exclude_dir < 0:
		var rot: int = main.building_rotation.get(grid_pos, 0)
		exclude_dir = (rot + 2) % 4  # behind

	var outputs: Array[int] = []
	for dir_idx in range(4):
		if dir_idx != exclude_dir:
			outputs.append(dir_idx)

	# Initialize round-robin index if needed
	if not router_output_index.has(grid_pos):
		router_output_index[grid_pos] = 0

	var rr_start: int = router_output_index[grid_pos] % outputs.size()

	# Try each output direction starting from the round-robin index
	for attempt in range(outputs.size()):
		var idx: int = (rr_start + attempt) % outputs.size()
		var out_dir: int = outputs[idx]
		var next_pos: Vector2i = grid_pos + DIR_VECTORS[out_dir]
		var entry_dir: int = (out_dir + 2) % 4  # Item enters from opposite side

		# Block cross-faction transfers
		if _is_cross_faction(grid_pos, next_pos):
			continue

		if _try_transfer_item(next_pos, item["item_id"], entry_dir):
			# Advance round-robin so the NEXT item tries a different output first
			router_output_index[grid_pos] = (idx + 1) % outputs.size()
			return true

	return false


## Fallback used when a belt can't push its item forward: tries the two
## perpendicular neighbours for a non-conveyor block that will accept this
## item (turret ammo, factory input, constructor). Never dumps sideways into
## another belt — that would silently reroute items in surprising ways.
##
## When BOTH sides could take the item, prefer the one with more free space
## so two identical turrets sandwiching a belt stay balanced — otherwise a
## fixed side-priority lets one turret hoard all the ammo while the opposite
## one starves.
func _try_belt_side_dump(grid_pos: Vector2i, belt_rot: int, item_id: StringName) -> bool:
	var sides: Array[int] = [(belt_rot + 1) % 4, (belt_rot + 3) % 4]
	# Sort sides by emptier-first so the neighbour that most recently
	# consumed ammo / used an input gets the next item.
	var scored: Array = []  # Array of [free_space, side_dir]
	for side_dir in sides:
		var side_pos: Vector2i = grid_pos + DIR_VECTORS[side_dir]
		if _is_cross_faction(grid_pos, side_pos):
			continue
		if not main.placed_buildings.has(side_pos):
			continue
		if _is_conveyor_cell(side_pos):
			continue
		# Don't side-dump into refabricators — they should only get items
		# from belts that actually point at them, so a belt running
		# alongside doesn't silently leak its contents into a neighbouring
		# refab when its forward push stalls.
		var nb_anchor: Vector2i = main.building_origins.get(side_pos, side_pos)
		var nb_data = Registry.get_block(main.placed_buildings.get(nb_anchor, &""))
		if nb_data and nb_data.tags.has("refabricator"):
			continue
		scored.append([_side_dump_free_space(side_pos, item_id), side_dir])
	scored.sort_custom(func(a, b): return a[0] > b[0])

	for entry in scored:
		var side_dir: int = entry[1]
		var side_pos: Vector2i = grid_pos + DIR_VECTORS[side_dir]
		var entry_dir: int = (side_dir + 2) % 4
		if _try_transfer_item(side_pos, item_id, entry_dir):
			return true
	return false


## Estimates how much room a side-dump target has for a given item. Higher =
## more open to a new item. Used to sort side-dump candidates so the emptier
## neighbour wins. Returns 0 for targets that can't take the item at all so
## they sort behind anything that can.
func _side_dump_free_space(grid_pos: Vector2i, item_id: StringName) -> int:
	var data = Registry.get_block(main.placed_buildings.get(grid_pos, &""))
	if data == null:
		return 0
	var anchor = main.get_building_anchor(grid_pos)
	var origin: Vector2i = anchor if anchor != null else grid_pos

	# Turret ammo storage: free = cap - current_total.
	if data.is_turret() and not data.ammo_types.is_empty():
		var matches := false
		for ammo in data.ammo_types:
			if ammo is AmmoType and (ammo as AmmoType).item_id == item_id:
				matches = true
				break
		if not matches:
			return 0
		var cap: int = data.max_stored_items if data.max_stored_items > 0 else 30
		var used: int = 0
		if block_storage.has(origin):
			for k in block_storage[origin]["items"]:
				used += int(block_storage[origin]["items"][k])
		return maxi(cap - used, 0)

	# Factory buffer: free = cap - current amount of this item.
	var is_omni: bool = data.tags.has("omnidirectional")
	var is_unit_fab: bool = data.produced_unit != &""
	if is_omni or is_unit_fab or not data.side_inputs.is_empty():
		var eff_inputs := _get_effective_inputs(data)
		var recipe_amt: int = 0
		for raw_id in eff_inputs:
			if StringName(raw_id) == item_id:
				recipe_amt = int(eff_inputs[raw_id])
				break
		if recipe_amt <= 0:
			return 0
		var cap2: int = data.max_stored_items if data.max_stored_items > 0 else recipe_amt * 10
		var have: int = 0
		if factory_buffers.has(origin):
			have = int(factory_buffers[origin]["inputs"].get(item_id, 0))
		return maxi(cap2 - have, 0)

	# Constructor: free = (needed - collected) for this item's cost slot.
	if data.tags.has("constructor") and constructor_state.has(origin):
		var state = constructor_state[origin]
		if state["phase"] != "collecting":
			return 0
		var sel: StringName = state["selected_block"]
		if sel == &"":
			return 0
		var tdata = Registry.get_block(sel)
		if tdata == null:
			return 0
		for raw_id in tdata.build_cost:
			if StringName(raw_id) == item_id or StringName("mat_" + str(raw_id)) == item_id:
				var needed: int = int(tdata.build_cost[raw_id])
				var have_c: int = int(state["collected"].get(StringName(str(raw_id)), 0))
				return maxi(needed - have_c, 0)
	return 0


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

	# --- Factory-style accept (omnidirectional, side_inputs, unit_fabricator) ---
	var is_omni: bool = data.tags.has("omnidirectional")
	var is_unit_fab: bool = data.produced_unit != &""
	if is_omni or is_unit_fab:
		var eff_inputs := _get_effective_inputs(data)
		for raw_id in eff_inputs:
			if StringName(raw_id) == item_id:
				var anchor = main.get_building_anchor(grid_pos)
				var origin: Vector2i = anchor if anchor != null else grid_pos
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
		for ammo in data.ammo_types:
			if ammo == null or not (ammo is AmmoType):
				continue
			if (ammo as AmmoType).item_id == item_id:
				return true
		return false

	return false


## Picks the exit direction for a router item without transferring it.
## Advances the round-robin index so subsequent items go different ways.
## Returns -1 if no output is available.
func _pick_router_exit(grid_pos: Vector2i, item: Dictionary) -> int:
	var item_entry_dir: int = item.get("entry_dir", -1)
	var exclude_dir: int = item_entry_dir
	if exclude_dir < 0:
		var rot: int = main.building_rotation.get(grid_pos, 0)
		exclude_dir = (rot + 2) % 4

	var outputs: Array[int] = []
	for dir_idx in range(4):
		if dir_idx != exclude_dir:
			outputs.append(dir_idx)

	if not router_output_index.has(grid_pos):
		router_output_index[grid_pos] = 0

	var rr_start: int = router_output_index[grid_pos] % outputs.size()

	# First pass: look for a direction with an accepting destination. Only
	# advance round-robin when we actually commit to an output so that a
	# fully-blocked router doesn't churn the index every frame.
	for attempt in range(outputs.size()):
		var idx: int = (rr_start + attempt) % outputs.size()
		var out_dir: int = outputs[idx]
		var next_pos: Vector2i = grid_pos + DIR_VECTORS[out_dir]
		var entry_dir: int = (out_dir + 2) % 4

		if _is_cross_faction(grid_pos, next_pos):
			continue

		# Empty conveyor ahead = perfect output.
		if _is_conveyor_cell(next_pos) and not conveyor_items.has(next_pos):
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

	# Fallback: all outputs blocked. Return the current round-robin direction
	# WITHOUT advancing the index, so the item waits on a stable exit edge
	# until something frees up.
	return outputs[rr_start] if outputs.size() > 0 else -1


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


## Teleports an item from an input bridge to its linked output bridge.
func _try_bridge_transfer(grid_pos: Vector2i, item: Dictionary) -> bool:
	var power_sys = _power_sys_ref()
	if power_sys == null:
		return false

	# Find linked partner — input bridge is pair[0], output is pair[1]
	var partner: Variant = null
	for pair in power_sys.linked_pairs:
		if pair[0] == grid_pos:
			partner = pair[1]
			break

	if partner == null:
		return false

	if not _is_bridge_cell(partner):
		return false

	# Teleport: place item at the output bridge with progress 0.0
	if not conveyor_items.has(partner):
		var out_rot: int = main.building_rotation.get(partner, 0)
		var entry_dir: int = (out_rot + 2) % 4  # enters from behind
		conveyor_items[partner] = {
			"item_id": item["item_id"],
			"progress": 0.0,
			"entry_dir": entry_dir,
		}
		return true

	return false  # Output bridge occupied


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
				var next_pos: Vector2i = grid_pos + DIR_VECTORS[exit_dir]
				var next_entry: int = (exit_dir + 2) % 4
				if not _is_cross_faction(grid_pos, next_pos):
					if _try_transfer_payload(next_pos, payload_data, next_entry):
						payload_items.erase(grid_pos)
				continue

			# --- ROUTER: distribute to 3 output directions (round-robin) ---
			if _is_router_cell(grid_pos):
				var exclude_dir: int = entry_dir
				if exclude_dir < 0:
					var rot: int = main.building_rotation.get(grid_pos, 0)
					exclude_dir = (rot + 2) % 4

				var outputs: Array[int] = []
				for dir_idx in range(4):
					if dir_idx != exclude_dir:
						outputs.append(dir_idx)

				if not payload_router_idx.has(grid_pos):
					payload_router_idx[grid_pos] = 0

				var rr_start: int = payload_router_idx[grid_pos] % outputs.size()
				var transferred := false
				for attempt in range(outputs.size()):
					var idx: int = (rr_start + attempt) % outputs.size()
					var out_dir: int = outputs[idx]
					var next_pos: Vector2i = grid_pos + DIR_VECTORS[out_dir]
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


# =========================
# PIPE LOGIC
# =========================

## Adds fluid to a pipe cell. Returns true if successful.
func _add_fluid_to_pipe(grid_pos: Vector2i, fluid_id: StringName, amount: float) -> bool:
	# Fluid can't enter a pipe that isn't fully built, is deconstructing, or is
	# derelict. This blocks every caller (pumps, factories, storage unloading,
	# belt-unloaders) without having to check at each site.
	if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
		return false
	var fluid = Registry.get_fluid(fluid_id)
	if fluid == null:
		return false

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


## Updates all pipe networks: equalize, leak, and feed factories.
func _update_pipes(delta: float) -> void:
	# --- Phase A: Find networks and equalize ---
	var visited := {}

	# Also check all placed pipe cells (even empty ones) for equalization.
	# Skip inactive pipes so they can't equalize fluid through a cell that
	# isn't finished building yet.
	var all_pipe_cells := {}
	for grid_pos in main.placed_buildings:
		if not _is_pipe_cell(grid_pos):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
			continue
		all_pipe_cells[grid_pos] = true

	for grid_pos in all_pipe_cells:
		if visited.has(grid_pos):
			continue

		# Flood-fill to find connected pipe network
		var network := _find_pipe_network(grid_pos)
		for pos in network:
			visited[pos] = true

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

	# Clean up empty pipe entries
	for pos in to_clean:
		if pipe_contents.has(pos) and pipe_contents[pos]["amount"] <= 0:
			pipe_contents.erase(pos)


## Flood-fills from a pipe cell to find all connected pipe cells.
## Pipes connect omnidirectionally (any adjacent pipe is connected).
## Only connects pipes of the same faction to prevent cross-faction fluid flow.
func _find_pipe_network(start: Vector2i) -> Array[Vector2i]:
	var network: Array[Vector2i] = []
	var queue := [start]
	var seen := {start: true}
	var start_faction: int = main.get_building_faction(start)

	while queue.size() > 0:
		var pos: Vector2i = queue.pop_front()
		network.append(pos)

		for dir in range(4):
			var neighbor: Vector2i = pos + DIR_VECTORS[dir]
			if seen.has(neighbor) or not _is_pipe_cell(neighbor):
				continue
			# Don't cross into pipes that aren't finished building / are being
			# deconstructed / are derelict — fluid can't flow through them.
			if main.has_method("is_building_inactive") and main.is_building_inactive(neighbor):
				continue
			if main.get_building_faction(neighbor) == start_faction:
				seen[neighbor] = true
				queue.append(neighbor)

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
		or data.tags.has("omnidirectional")


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
		if data.max_stored_fluids <= 0:
			return false
		var total_fluids := _get_total_stored_fluids(storage)
		if total_fluids >= data.max_stored_fluids:
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
	if data.max_stored_fluids <= 0:
		return false
	if not block_storage.has(origin):
		return false
	return _get_total_stored_fluids(block_storage[origin]) >= data.max_stored_fluids


## Returns true if the building's storage is full for the given item type.
func _is_storage_full_for(origin: Vector2i, data: BlockData, item_id: StringName) -> bool:
	var is_fluid: bool = Registry.get_fluid(item_id) != null
	if is_fluid:
		return _is_fluid_storage_full(origin, data)
	return _is_item_storage_full(origin, data)


## Returns true if ALL storage types the building uses are full.
func _is_storage_full(origin: Vector2i, data: BlockData) -> bool:
	if not _block_uses_storage(data):
		return false
	if not block_storage.has(origin):
		return false
	var items_full: bool = data.max_stored_items <= 0 or _get_total_stored_items(block_storage[origin]) >= data.max_stored_items
	var fluids_full: bool = data.max_stored_fluids <= 0 or _get_total_stored_fluids(block_storage[origin]) >= data.max_stored_fluids
	return items_full and fluids_full


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
		var grid_size: Vector2i = data.grid_size if data else Vector2i(1, 1)
		var rot: int = main.building_rotation.get(origin, 0)
		# Omnidirectional blocks push from all four edges regardless of rotation.
		var output_cells: Array
		if data and data.tags.has("omnidirectional"):
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

		# Try to push stored fluids into adjacent pipes
		var fluids_to_remove := {}
		for fluid_id in storage["fluids"]:
			if float(storage["fluids"][fluid_id]) <= 0:
				fluids_to_remove[fluid_id] = true
				continue
			for dir in range(4):
				var neighbor: Vector2i = origin + DIR_VECTORS[dir]
				if _is_cross_faction(origin, neighbor):
					continue
				if _is_pipe_cell(neighbor):
					if _add_fluid_to_pipe(neighbor, fluid_id, PIPE_PUSH_AMOUNT):
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
	for grid_pos in main.placed_buildings:
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

		# Gather source neighbors (buildings with block_storage) and
		# sink neighbors (conveyors with no item that face away from us).
		var sources: Array[Vector2i] = []
		var sinks: Array[Vector2i] = []
		for dir_idx in range(4):
			var nb: Vector2i = origin + DIR_VECTORS[dir_idx]
			if _is_cross_faction(origin, nb):
				continue
			if not main.placed_buildings.has(nb):
				continue
			var nb_anchor: Vector2i = main.building_origins.get(nb, nb)
			# Sink: empty conveyor cell facing away from us
			if _is_conveyor_cell(nb) and not conveyor_items.has(nb):
				sinks.append(nb)
			# Source: any building with items in block_storage that
			# legitimately outputs those items. Turrets store ammo in
			# block_storage so combat_system can consume it on fire —
			# that storage is an INPUT buffer, not a product stockpile,
			# so we must not let an unloader pull it back out and feed
			# the ammo in circles. Same principle for constructor /
			# deconstructor / loader-type blocks that own their storage.
			elif block_storage.has(nb_anchor) and not block_storage[nb_anchor]["items"].is_empty():
				var nb_data = Registry.get_block(main.placed_buildings.get(nb_anchor, &""))
				if nb_data == null:
					continue
				if nb_data.is_turret():
					continue
				sources.append(nb_anchor)

		if sources.is_empty() or sinks.is_empty():
			continue

		# Round-robin across sources
		var rr: int = state["round_robin"] % sources.size()
		state["round_robin"] = rr + 1
		var src: Vector2i = sources[rr]
		var storage: Dictionary = block_storage[src]

		# Pick the first matching item (or any item if no filter)
		var pulled_id: StringName = &""
		if filter_id != &"":
			if storage["items"].has(filter_id) and int(storage["items"][filter_id]) > 0:
				pulled_id = filter_id
		else:
			for item_id in storage["items"]:
				if int(storage["items"][item_id]) > 0:
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
			storage["items"][pulled_id] = int(storage["items"][pulled_id]) - 1
			if int(storage["items"][pulled_id]) <= 0:
				storage["items"].erase(pulled_id)


# =========================
# CORE ABSORPTION
# =========================

## Adds one unit of the item to the appropriate resource pool.
## Ferox cores feed the ferox pool; Lumina cores feed the player pool.
## Tries to absorb an item into core storage. Returns true if accepted, false if full.
func _absorb_item(item_id: StringName, core_grid_pos: Vector2i = Vector2i(-1, -1)) -> bool:
	# Sand isn't a real resource — cores incinerate it instead of adding
	# it to the pool. Returning true tells the conveyor/drone the deposit
	# succeeded so the item is consumed rather than backing up the belt.
	if item_id == &"mat_sand":
		return true
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


## Returns true if the cell has a fluid transport (pipe/conduit, NOT pumps).
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


## Returns true if the cell is a payload/freight loader.
func _is_payload_loader(grid_pos: Vector2i) -> bool:
	return _has_block_tag(grid_pos, "payload_loader") or _has_block_tag(grid_pos, "freight_loader")


## Returns true if the cell is a payload/freight unloader.
func _is_payload_unloader(grid_pos: Vector2i) -> bool:
	return _has_block_tag(grid_pos, "payload_unloader") or _has_block_tag(grid_pos, "freight_unloader")


func _is_core_cell(grid_pos: Vector2i) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null:
		return false
	return data.category == BlockData.BlockCategory.CORE


# =========================
# BUILDING EVENTS
# =========================

func _on_building_placed(block_id: StringName, grid_pos: Vector2i) -> void:
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
	conveyor_items.erase(grid_pos)
	pipe_contents.erase(grid_pos)
	drill_timers.erase(grid_pos)
	pump_timers.erase(grid_pos)
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
	loader_state.erase(grid_pos)
	unloader_state.erase(grid_pos)
	mass_driver_state.erase(grid_pos)
	belt_unloader_state.erase(grid_pos)
	# Drop any in-flight projectiles to/from this driver
	for i in range(mass_driver_projectiles.size() - 1, -1, -1):
		var proj: Dictionary = mass_driver_projectiles[i]
		if proj.get("target_origin") == grid_pos or proj.get("source_origin") == grid_pos:
			mass_driver_projectiles.remove_at(i)


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
func _try_accept_turret_ammo(grid_pos: Vector2i, item_id: StringName) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null or not data.is_turret():
		return false
	if data.ammo_types.is_empty():
		return false

	# Confirm the item matches one of the turret's accepted ammos.
	var accepted := false
	for ammo in data.ammo_types:
		if ammo == null or not (ammo is AmmoType):
			continue
		if (ammo as AmmoType).item_id == item_id:
			accepted = true
			break
	if not accepted:
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

	for grid_pos in main.placed_buildings:
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
					# Consume collected items and start building
					state["collected"] = {}
					state["phase"] = "building"
					state["timer"] = target_data.build_time if target_data.build_time > 0 else 2.0

			"building":
				state["timer"] -= delta
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
					# else: stall — payload conveyor is full, try again next frame


# =========================
# DECONSTRUCTOR LOGIC
# =========================

## Processes all deconstructors: accept payload → deconstruct → output items.
func _update_deconstructors(delta: float) -> void:
	var processed := {}

	for grid_pos in main.placed_buildings:
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

					# Units: find the fabricator that produces this unit and output its input_items
					if payload_data.get("type", "") == "unit":
						var unit_id := StringName(payload_data.get("unit_id", ""))
						var fab_data: BlockData = null
						# Search all blocks for the fabricator that produces this unit
						for block in Registry.blocks_list:
							if block.produced_unit == unit_id:
								fab_data = block
								break
						if fab_data != null and not fab_data.input_items.is_empty():
							var pending := {}
							for raw_id in fab_data.input_items:
								var item_key := StringName(raw_id)
								if not Registry.get_item(item_key):
									var prefixed := StringName("mat_" + str(raw_id))
									if Registry.get_item(prefixed):
										item_key = prefixed
								pending[item_key] = int(fab_data.input_items[raw_id])
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

	for grid_pos in main.placed_buildings:
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
				state["timer"] -= delta * refab_eff
				# Drain materials gradually so the buffer visibly empties
				# while the upgrade runs.
				var _sel_t2_p: StringName = StringName(state.get("selected_t2", &""))
				var _recipe_p: Dictionary = _refab_effective_recipe(data, _sel_t2_p)
				var _t_total_r: float = float(state.get("timer_total", state["timer"] + 0.0001))
				if _t_total_r <= 0.0:
					_t_total_r = 0.0001
				var _prog_r: float = clampf(1.0 - state["timer"] / _t_total_r, 0.0, 1.0)
				if not state.has("recipe_consumed"):
					state["recipe_consumed"] = {}
				_consume_progressive(item_buf, _recipe_p, state["recipe_consumed"], _prog_r)
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
	var terrain = _terrain_ref()
	var gs: int = main.GRID_SIZE

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
		spawn_world = Vector2(cell.x * gs + gs * 0.5, cell.y * gs + gs * 0.5)
		found_cell = true
		break

	if not found_cell:
		# Every perimeter cell is blocked. Spawn on the building's own
		# centre so the unit isn't lost. The unit's own pathing will sort
		# out where it goes from there (ground units can't physically be
		# "inside" a building but the renderer and combat system treat
		# units as free entities).
		spawn_world = Vector2(
			(origin.x + data.grid_size.x * 0.5) * gs,
			(origin.y + data.grid_size.y * 0.5) * gs
		)

	var unit_mgr = _unit_mgr_ref()
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


## Returns true if the refabricator's factory_buffers inputs cover every
## item in data.input_items. Handles "copper" → "mat_copper" normalisation.
func _refab_has_all_inputs(data: BlockData, buf: Dictionary) -> bool:
	return _refab_has_all_inputs_dict(_refab_effective_recipe(data, &""), buf)


## Subtracts data.input_items from the buffer (call only when
## _refab_has_all_inputs returned true).
func _refab_consume_inputs(data: BlockData, buf: Dictionary) -> void:
	_refab_consume_inputs_dict(_refab_effective_recipe(data, &""), buf)


## Dict-based variants used by the refab state machine once it resolves
## the per-tier-2 recipe. Accept any dict keyed either by short ids
## ("copper") or full runtime ids ("mat_copper").
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

	for grid_pos in main.placed_buildings:
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
					# Full — output the payload from front face only
					var rot: int = main.building_rotation.get(origin, 0)
					var front_cells: Array[Vector2i] = _get_front_edge(origin, data.grid_size, rot)
					for out_pos in front_cells:
						if _is_cross_faction(origin, out_pos):
							continue
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

	for grid_pos in main.placed_buildings:
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
				# Try to accept a storage-tagged building payload from ALL adjacent cells
				# (the conveyor system blocks transfers INTO the unloader, so payloads
				# stay on the conveyor and the unloader pulls them)
				var perimeter_u := _get_all_perimeter_cells(origin, data.grid_size)
				for edge_pos in perimeter_u:
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
func _update_mass_drivers(delta: float) -> void:
	var power_sys = _power_sys_ref()
	if not power_sys:
		return
	var processed := {}

	for grid_pos in main.placed_buildings:
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

		# Helper: snap angle to nearest 90° (cardinal direction)
		var snap_angle = func(a: float) -> float:
			return roundf(a / (PI / 2.0)) * (PI / 2.0)

		# Find role and partner
		var is_input := false
		var is_output := false
		var partner: Variant = null
		for pair in power_sys.linked_pairs:
			if pair[0] == origin:
				is_input = true
				partner = pair[1]
				break
			elif pair[1] == origin:
				is_output = true
				partner = pair[0]
				break

		# Rotate head toward target at constant speed
		var angle_diff: float = wrapf(state["target_angle"] - state["head_angle"], -PI, PI)
		var max_rot: float = rotate_speed * delta
		if absf(angle_diff) <= max_rot:
			state["head_angle"] = state["target_angle"]
		else:
			state["head_angle"] = wrapf(state["head_angle"] + signf(angle_diff) * max_rot, -PI, PI)
		var head_at_target: bool = absf(wrapf(state["target_angle"] - state["head_angle"], -PI, PI)) < 0.05

		# Decay recoil
		if state["recoil"] > 0:
			state["recoil"] = maxf(state["recoil"] - delta / cooldown_time, 0.0)

		# Decay cooldown
		if state["cooldown"] > 0:
			state["cooldown"] = maxf(state["cooldown"] - delta, 0.0)

		# === INPUT MASS DRIVER ===
		if is_input:
			match state["phase"]:
				"idle":
					if state["cooldown"] > 0:
						continue
					# Look for payload on adjacent conveyors
					var perimeter := _get_all_perimeter_cells(origin, data.grid_size)
					for edge_pos in perimeter:
						if _is_cross_faction(origin, edge_pos):
							continue
						var conv_anchor: Vector2i = main.building_origins.get(edge_pos, edge_pos)
						if not payload_items.has(conv_anchor):
							continue
						if payload_items[conv_anchor]["progress"] < 1.0:
							continue
						# Found payload — rotate toward it
						var conv_center: Vector2 = main.grid_to_world(conv_anchor) + Vector2(gs_md / 2.0, gs_md / 2.0)
						state["target_angle"] = snap_angle.call((conv_center - center).angle())
						state["input_pos"] = conv_anchor
						state["phase"] = "rotating_to_input"
						break

				"rotating_to_input":
					if head_at_target:
						# Pick up the payload
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

				"rotating_to_output":
					if head_at_target and state["payload"] != null:
						state["phase"] = "ready"

				"ready":
					# Fire — launch projectile
					if partner != null and state["payload"] != null and main.placed_buildings.has(partner):
						var partner_data = Registry.get_block(main.placed_buildings[partner])
						if partner_data == null or not partner_data.tags.has("mass_driver"):
							continue
						if not mass_driver_state.has(partner):
							mass_driver_state[partner] = {
								"payload": null, "head_angle": 0.0, "target_angle": 0.0,
								"recoil": 0.0, "phase": "idle", "cooldown": 0.0, "input_pos": Vector2i.ZERO,
							}
						var p_state: Dictionary = mass_driver_state[partner]
						if p_state["payload"] == null:
							# Make partner face this driver before projectile arrives
							var p_data = Registry.get_block(main.placed_buildings.get(partner, &""))
							var p_center: Vector2 = main.grid_to_world(partner) + Vector2(p_data.grid_size.x * gs_md / 2.0, p_data.grid_size.y * gs_md / 2.0) if p_data else main.grid_to_world(partner)
							p_state["head_angle"] = snap_angle.call((center - p_center).angle())
							p_state["target_angle"] = p_state["head_angle"]

							# Create projectile
							mass_driver_projectiles.append({
								"from": center,
								"to": p_center,
								"payload_data": state["payload"],
								"progress": 0.0,
								"source_origin": origin,
								"target_origin": partner,
							})

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
					# Just received — recoil is decaying
					if state["recoil"] <= 0:
						# Rotate to face output conveyor
						var rot_md: int = main.building_rotation.get(origin, 0)
						var front: Array[Vector2i] = _get_front_edge(origin, data.grid_size, rot_md)
						if not front.is_empty():
							var out_world: Vector2 = main.grid_to_world(front[0]) + Vector2(gs_md / 2.0, gs_md / 2.0)
							state["target_angle"] = snap_angle.call((out_world - center).angle())
						state["phase"] = "rotating_to_output"

				"rotating_to_output":
					if head_at_target and state["payload"] != null:
						# Try to output payload
						var rot_md: int = main.building_rotation.get(origin, 0)
						var front: Array[Vector2i] = _get_front_edge(origin, data.grid_size, rot_md)
						for out_pos in front:
							if _try_push_payload(out_pos, state["payload"]):
								state["payload"] = null
								state["phase"] = "idle"
								break

	# Update in-flight projectiles
	var projectiles_to_remove := []
	for i in range(mass_driver_projectiles.size()):
		var proj: Dictionary = mass_driver_projectiles[i]
		proj["progress"] += delta * 4.0  # Fast flight (0.25 seconds)
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
	_draw_drill_progress_bars()
	_draw_pump_progress_bars()
	_draw_factory_progress_bars()


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

		# Draw head (rotated rectangle)
		var head_w: float = data.grid_size.x * gs_d * 0.5
		var head_h: float = data.grid_size.y * gs_d * 0.3
		draw_set_transform(head_pos, head_angle)
		draw_rect(Rect2(-head_w / 2.0, -head_h / 2.0, head_w, head_h), Color(data.color.r * 0.8, data.color.g * 0.8, data.color.b * 0.8, 0.9), true)
		draw_rect(Rect2(-head_w / 2.0, -head_h / 2.0, head_w, head_h), data.color.lightened(0.2), false, 2.0)
		# Barrel
		draw_rect(Rect2(head_w * 0.3, -head_h * 0.15, head_w * 0.4, head_h * 0.3), data.color.darkened(0.3), true)
		draw_set_transform(Vector2.ZERO, 0.0)

		# Draw payload on top of head
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
						pw = icon.get_width()
						ph = icon.get_height()
			if icon:
				draw_texture_rect(icon, Rect2(head_pos.x - pw / 2.0, head_pos.y - ph / 2.0, pw, ph), false, Color(1, 1, 1, 0.7))

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
		draw_line(trail_start, pos, Color(0.5, 0.3, 0.9, 0.4), 3.0)


func _draw_items() -> void:
	var building_sys = _building_sys_ref()
	var _ss_items = _sector_script_ref()

	for grid_pos in conveyor_items:
		if _ss_items and _ss_items.is_tile_hidden(grid_pos):
			continue
		var entry = conveyor_items[grid_pos]
		var item_id: StringName = entry["item_id"]
		var progress: float = entry["progress"]

		var item = Registry.get_item_or_fluid(item_id)
		if item == null:
			continue

		# Figure out which direction this conveyor faces
		var rotation = main.building_rotation.get(grid_pos, 0)
		# Routers use their pre-decided exit_dir instead of cell rotation
		var exit_dir: int = entry.get("exit_dir", -1)
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
			var tex_size = Vector2(ITEM_TEXTURE_SIZE, ITEM_TEXTURE_SIZE)
			var tex_rect = Rect2(item_pos - tex_size / 2.0, tex_size)
			draw_texture_rect(item.icon, tex_rect, false)
		else:
			draw_circle(item_pos, ITEM_RADIUS, item.color.darkened(0.15))
			draw_arc(item_pos, ITEM_RADIUS, 0, TAU, 16, item.color.lightened(0.4), 2.0)

	# Draw junction perpendicular-axis items (same rendering logic)
	for grid_pos in junction_items:
		if _ss_items and _ss_items.is_tile_hidden(grid_pos):
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
			var tex_size = Vector2(ITEM_TEXTURE_SIZE, ITEM_TEXTURE_SIZE)
			var tex_rect = Rect2(item_pos - tex_size / 2.0, tex_size)
			draw_texture_rect(item.icon, tex_rect, false)
		else:
			draw_circle(item_pos, ITEM_RADIUS, item.color.darkened(0.15))
			draw_arc(item_pos, ITEM_RADIUS, 0, TAU, 16, item.color.lightened(0.4), 2.0)


## Draws payloads on payload/freight conveyors.
## Building payloads draw their block icon; unit payloads draw the unit icon.
## Size is ~48px, centered on the cell, interpolated between cells based on progress.
func _draw_payloads() -> void:
	var building_sys = _building_sys_ref()
	var _ss_payload = _sector_script_ref()
	var gs: float = main.GRID_SIZE

	for grid_pos in payload_items:
		if _ss_payload and _ss_payload.is_tile_hidden(grid_pos):
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
					var scale_f: float = unit_data.sprite_scale if unit_data.sprite_scale > 0.0 else 1.0
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
		var dir_vec := Vector2(DIR_VECTORS[rotation])
		var world_pos: Vector2 = main.grid_to_world(grid_pos)
		var conv_center: Vector2 = world_pos + Vector2(conv_size.x * gs / 2.0, conv_size.y * gs / 2.0)

		# Movement distance scaled to conveyor size (larger conveyors = longer travel)
		var travel_dist: float = maxf(conv_size.x, conv_size.y) * gs

		# Straight path from back to front of conveyor
		var payload_pos: Vector2 = conv_center + dir_vec * (progress - 0.5) * travel_dist

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
	var building_sys = _building_sys_ref()

	for grid_pos in pump_timers:
		if not main.placed_buildings.has(grid_pos):
			continue

		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null:
			continue

		# Calculate fill percentage
		var cycle_time = data.production_time if data.production_time > 0 else default_drill_time
		var remaining = pump_timers[grid_pos]
		var pct = clampf(1.0 - (remaining / cycle_time), 0.0, 1.0)

		# Check if there's actually a liquid tile underneath
		var terrain = _terrain_ref()
		if terrain == null:
			continue
		var liquid_tile = terrain.get_liquid_at(grid_pos)
		if liquid_tile == null or liquid_tile.extracted_liquid == &"":
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
		# Blue fill (distinguishes from green drill bars)
		draw_rect(Rect2(bar_pos, Vector2(bar_w * pct, bar_h)),
			Color(0.3, 0.5, 0.9, 0.8), true)


# =========================
# FACTORY LOGIC
# =========================

## Processes all factories with directional inputs/outputs.
## Phases: collecting → processing → outputting → collecting.
func _update_factories(delta: float) -> void:
	var processed := {}

	for grid_pos in main.placed_buildings:
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null:
			continue
		# Refabricators run in their own update loop; the standard factory
		# path would try to produce nothing (no produced_unit) or mishandle
		# the payload-in requirement.
		if data.tags.has("refabricator"):
			continue
		# Omnidirectional factories intentionally have empty side_inputs/side_outputs,
		# so keep them in the loop — the processing logic handles them separately.
		if data.side_inputs.is_empty() and data.side_outputs.is_empty() and data.produced_unit == &"" and not data.tags.has("omnidirectional"):
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

		match state["phase"]:
			"collecting":
				# Don't start production if storage is full (skip for unit fabricators)
				if not is_unit_fabricator and _is_storage_full(origin, data):
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
				if _factory_has_all_inputs(state, data):
					# Don't deduct upfront — _consume_progressive drains
					# the buffer in step with the timer below so the
					# tooltip's "have/needed" bars visibly tick down.
					state["phase"] = "processing"
					# Unit fabricators use the unit's build_time
					if is_unit_fabricator:
						var unit_data = Registry.get_unit(data.produced_unit)
						state["timer"] = unit_data.build_time if unit_data else 5.0
					else:
						state["timer"] = data.production_time
					state["timer_total"] = state["timer"]
					state["recipe_consumed"] = {}

			"processing":
				state["timer"] -= delta * factory_power_eff
				# Spread the recipe cost evenly across the build timer.
				var _recipe := _get_effective_inputs(data)
				var _t_total: float = float(state.get("timer_total", state["timer"] + 0.0001))
				if _t_total <= 0.0:
					_t_total = 0.0001
				var _prog: float = clampf(1.0 - state["timer"] / _t_total, 0.0, 1.0)
				if not state.has("recipe_consumed"):
					state["recipe_consumed"] = {}
				_consume_progressive(state["inputs"], _recipe, state["recipe_consumed"], _prog)
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
						if data.tags.has("omnidirectional"):
							var slot: int = 0
							for raw_id in data.output_items:
								var out_sn := StringName(raw_id)
								var amt: int = int(data.output_items[raw_id])
								for i in range(amt):
									pending[str(slot)] = out_sn
									slot += 1
									if factory_is_lumina:
										main.item_produced.emit(out_sn)
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
func _get_effective_inputs(data: BlockData) -> Dictionary:
	if data.produced_unit != &"":
		var unit = Registry.get_unit(data.produced_unit)
		if unit != null and not unit.build_cost.is_empty():
			return _normalize_item_keys(unit.build_cost)
	return data.input_items


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
func _factory_has_all_inputs(state: Dictionary, data: BlockData) -> bool:
	var inputs := _get_effective_inputs(data)
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
func _factory_try_output(origin: Vector2i, data: BlockData, state: Dictionary) -> void:
	var rot: int = main.building_rotation.get(origin, 0)
	var delivered := []
	var is_omni: bool = data.tags.has("omnidirectional")

	if is_omni:
		# Build the ring of cells around the factory's full footprint.
		var ring: Array[Vector2i] = _get_all_output_cells(origin, data.grid_size, rot)
		for rel_dir_key in state["pending_outputs"]:
			var out_item: StringName = state["pending_outputs"][rel_dir_key]
			var pushed := false
			for target_pos in ring:
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
			else:
				# Couldn't push anywhere — fall back to internal storage.
				if _add_to_storage(origin, out_item, data):
					delivered.append(rel_dir_key)
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

	var terrain = _terrain_ref()
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


## Spawns the unit produced by this fabricator at the front of its footprint.
## Wrapper kept for the base unit-fabricator path; reads produced_unit off
## the BlockData.
func _spawn_fabricated_unit(origin: Vector2i, data: BlockData) -> void:
	_spawn_unit_at_building_front(origin, data, data.produced_unit)


## Spawns `unit_id` at the front edge of the building at `origin`. Shared
## by unit fabricators (produced_unit) and refabricators (tier-2 unit
## derived from the input payload).
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

	# Omnidirectional factories accept on every side and don't need side_inputs set.
	# Unit fabricators also accept from any side — their inputs come from the
	# produced unit's build_cost, not side_inputs.
	# Refabricators accept on every side for the recipe items (same omni-buffer
	# logic), BUT reject items arriving on the front edge — that edge is the
	# output lane and belts running across it shouldn't get their contents
	# silently absorbed. Without this guard a refabricator placed under a
	# fabricator would eat the materials intended for the fabricator above it.
	var is_omni: bool = data.tags.has("omnidirectional") or data.tags.has("refabricator")
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

	# Omnidirectional / unit-fabricator path: accept any item that matches one
	# of the factory's effective inputs, regardless of entry direction. Inputs
	# buffer up to max_stored_items per ingredient (defaults to 10× recipe
	# amount so the factory can keep running for a while without a belt
	# refilling every cycle).
	if is_omni or is_unit_fab_early:
		var effective_inputs := _get_effective_inputs(data)
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
