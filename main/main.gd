extends Node2D

# ============================================================
# MAIN.GD - The root game controller
# ============================================================
# All building data now comes from the Registry and .tres files.
# No more hardcoded enums or dictionaries — adding a new building
# is just creating a new .tres file.
#
# placed_buildings stores StringName IDs (like &"drill")
# instead of enum integers. To look up properties:
#     var data = Registry.get_block(placed_buildings[grid_pos])
#
# MULTI-TILE BUILDINGS:
# building_origins maps every cell of a multi-tile building
# to its "anchor" (top-left corner). When drawing, only the
# anchor cell draws the full-size block; child cells are skipped.
# ============================================================

# --- GRID SETTINGS ---
const GRID_SIZE := 64
var GRID_WIDTH := 100
var GRID_HEIGHT := 100

# --- RESOURCE TRACKING ---
# Starting resources for the player.
var resources := {
	&"mat_copper": 0,
	&"mat_silicon": 0,
}

# Ferox faction resource pool — items deposited into ferox cores go here.
# Used by ferox core units to rebuild destroyed ferox buildings.
var ferox_resources := {}

# Queue of destroyed ferox buildings waiting to be rebuilt.
# Each entry: { "block_id": StringName, "grid_pos": Vector2i, "rotation": int }
var ferox_rebuild_queue: Array = []

# --- FACTIONS ---
enum Faction { LUMINA, FEROX, DERELICT }

# --- STATE ---
# Now a StringName block ID (e.g. &"drill") or empty &"" for nothing.
var selected_building: StringName = &""
var require_resources := true
var require_research := true
var enemies_attack := false

## Tracks player buildings destroyed by enemies for potential rebuild.
## Key = Vector2i (anchor), Value = { "block_id": StringName, "rotation": int }
var destroyed_player_buildings: Dictionary = {}

## Whether all enemy cores have been destroyed (triggers derelict conversion).
var all_enemy_cores_destroyed := false

# Tracks which grid cells have buildings.
# Key = Vector2i, Value = StringName block ID
var placed_buildings := {}
# Tracks building health.
# Key = Vector2i, Value = current HP (float)
var building_health := {}

# Tracks building rotation (direction it faces).
# Key = Vector2i, Value = int (0=right, 1=down, 2=left, 3=up)
var building_rotation := {}

# MULTI-TILE: Maps every occupied cell → anchor (top-left) position.
# For 1x1 buildings, the anchor IS the cell itself.
# For a 3x3 core at (48,48), cells (48,48) through (50,50) all map to (48,48).
#var building_origins := {}
## Maps every cell of a multi-tile building back to its origin (top-left).
## Key = Vector2i (any occupied cell), Value = Vector2i (origin)
var building_origins := {}

## Tracks which faction owns each building cell.
## Key = Vector2i, Value = int (Faction.LUMINA or Faction.FEROX)
## Missing entries default to LUMINA for backward compatibility.
var building_factions := {}

## Tracks buildings currently under construction.
## Key = Vector2i (anchor), Value = float (seconds elapsed since placement).
## Buildings not in this dict are fully built.
var building_build_progress := {}

## FIFO build order — DEPRECATED, kept for save compat. Use work_order instead.
var build_order: Array[Vector2i] = []

## Set by SaveManager when drone position is restored from a save.
var _drone_position_restored := false

## When true, construction/deconstruction is paused (no progress ticks).
var build_paused := false

## Tracks buildings being deconstructed (reverse build animation).
## Key = Vector2i (anchor), Value = Dictionary {"block_id": StringName, "progress": float, "build_time": float, "rotation": int}
var building_deconstruct_progress := {}

## FIFO deconstruct order — DEPRECATED, kept for save compat. Use work_order instead.
var deconstruct_order: Array[Vector2i] = []

## Unified FIFO work queue — interleaves build and deconstruct operations.
## Only the first entry gets progress each frame. Entries are anchors (Vector2i).
## Check building_build_progress / building_deconstruct_progress to determine
## whether a given anchor is a build or a deconstruct.
var work_order: Array[Vector2i] = []

## Pending same-group replacements (belt → junction, pipe → fluid bridge, …).
## Key = Vector2i (the cell), Value = { "new_block_id", "new_rotation" }.
## The original block stays in placed_buildings and keeps functioning until
## the drone begins work on this cell, at which point the real swap happens.
## Lets drag-placed auto-junctions keep the underlying belt flowing during
## the build.
var pending_swaps := {}

## Paused work anchors. A paused entry stays in work_order at its current
## position but is skipped when picking the next tickable work item, so its
## progress freezes in place.
##
## Values distinguish two kinds of pause:
##   • `true`    — explicit user pause (click on actively-working block).
##                 Only clears when the user clicks the block again.
##   • Vector2i  — auto-pause triggered by promoting a different anchor to
##                 the front of the queue. Clears automatically when that
##                 promoting anchor finishes, so work resumes where the
##                 player left off before the detour.
var work_paused: Dictionary = {}


## Clears any entries in `work_paused` whose auto-resume trigger is the
## given anchor. Call this whenever an anchor is removed from work_order
## (build complete, deconstruct complete, or cancelled) so anything that
## was waiting on it can resume.
func resume_auto_paused_by(anchor: Vector2i) -> void:
	var to_erase: Array = []
	for paused in work_paused:
		var v = work_paused[paused]
		if v is Vector2i and v == anchor:
			to_erase.append(paused)
	for p in to_erase:
		work_paused.erase(p)

## Tracks how much of each resource has been consumed so far for a building
## under construction. Key = Vector2i (anchor), Value = { StringName: int }.
var building_resources_consumed := {}

## Tracks how much of each resource has been refunded so far for a building
## being deconstructed. Key = Vector2i (anchor), Value = { StringName: int }.
var building_resources_refunded := {}

# --- CACHED CHILD NODE REFERENCES ---
# Populated by _refresh_child_cache() at the end of _ready(), but because
# SectorScript / HUD / TechTreeUI are added dynamically at various points,
# every read goes through a `_x_ref()` lazy accessor below that auto-populates
# the first time the child actually exists.
var _hud: Node
var _tech_ui: Node
var _db_ui: Node
var _drone: Node2D
var _unit_mgr: Node
var _terrain: Node2D
var _building_sys: Node
var _logistics: Node2D
var _combat_sys: Node
var _power_sys: Node


func _hud_ref() -> Node:
	if _hud == null:
		_hud = get_node_or_null("HUD")
	return _hud
func _tech_ui_ref() -> Node:
	if _tech_ui == null:
		_tech_ui = get_node_or_null("TechTreeUI")
	return _tech_ui
func _db_ui_ref() -> Node:
	if _db_ui == null:
		_db_ui = get_node_or_null("DatabaseUI")
	return _db_ui
func _drone_ref() -> Node2D:
	if _drone == null:
		_drone = get_node_or_null("PlayerDrone")
	return _drone
func _unit_mgr_ref() -> Node:
	if _unit_mgr == null:
		_unit_mgr = get_node_or_null("UnitManager")
	return _unit_mgr
func _terrain_ref() -> Node2D:
	if _terrain == null:
		_terrain = get_node_or_null("TerrainSystem")
	return _terrain
func _building_sys_ref() -> Node:
	if _building_sys == null:
		_building_sys = get_node_or_null("BuildingSystem")
	return _building_sys
func _logistics_ref() -> Node2D:
	if _logistics == null:
		_logistics = get_node_or_null("LogisticsSystem")
	return _logistics
func _combat_sys_ref() -> Node:
	if _combat_sys == null:
		_combat_sys = get_node_or_null("CombatSystem")
	return _combat_sys
func _power_sys_ref() -> Node:
	if _power_sys == null:
		_power_sys = get_node_or_null("PowerSystem")
	return _power_sys


## Returns true if a blocking UI is open (pause menu, tech tree, database, loss screen).
## Game input (building, mining, unit control) should be suppressed.
func is_ui_blocking() -> bool:
	if sector_lost:
		return true
	var hud := _hud_ref()
	if hud and hud.escape_menu_open:
		return true
	var tech_ui := _tech_ui_ref()
	if tech_ui and tech_ui.is_open:
		return true
	var db_ui := _db_ui_ref()
	if db_ui and db_ui.is_open:
		return true
	if hud and hud.settings_ui and hud.settings_ui.is_open:
		return true
	return false

# --- SESSION STATS ---
var stats_blocks_placed := 0
var stats_blocks_removed := 0
var stats_enemy_blocks_destroyed := 0
var stats_units_produced := 0
var stats_units_destroyed := 0
var stats_enemy_units_destroyed := 0
var stats_play_time := 0.0
var sector_lost := false

# Current rotation for the NEXT building placement.
# Player presses Q to cycle this.
var placement_rotation := 0

# Core position (top-left tile of the 3x3 core)
var core_position := Vector2i(48, 48)

## Partial world pause: camera/drone still move, preview works, but no placement,
## units don't move, logistics freeze, items don't enter core.
var world_paused := false

# --- SIGNALS ---
# Several of these are emitted from sibling systems (LogisticsSystem,
# PlayerDrone, BuildingSystem, SectorScript) which call main.<signal>.emit(...).
# GDScript's "unused_signal" warning only inspects the declaring class, so we
# suppress it here since the cross-module emits are legitimate.
signal resources_changed(resources: Dictionary)
@warning_ignore("unused_signal") signal ferox_resources_changed(ferox_resources: Dictionary)
signal building_selected(block_id: StringName)
signal building_placed(block_id: StringName, grid_pos: Vector2i)
signal building_destroyed(grid_pos: Vector2i)
@warning_ignore("unused_signal") signal item_mined(item_id: StringName)
@warning_ignore("unused_signal") signal item_absorbed_in_core(item_id: StringName)
@warning_ignore("unused_signal") signal core_unit_item_mined(item_id: StringName)
@warning_ignore("unused_signal") signal item_produced(item_id: StringName)
signal sector_launched(sector_id: StringName)
@warning_ignore("unused_signal") signal sector_captured(sector_id: StringName)
@warning_ignore("unused_signal") signal archive_decoded(archive_id: StringName)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Auto-save sector and campaign when the game window is closed
		SaveManager.sync_active_sector_resources()
		if SaveManager.active_sector_id != &"":
			SaveManager.save_sector(SaveManager.active_sector_id)
		SaveManager.save_campaign()
		print("Main: Auto-saved on close.")
		get_tree().quit()


func _ready() -> void:
	# Allow Main to process input even while paused (for space to unpause)
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Wait for Registry ESSENTIALS (items, blocks, units, fluids, tiles) only.
	# Non-essential groups (status_effects, sectors, planets) keep loading in the
	# background after the sector is already playable.
	while not Registry.essentials_loaded:
		await get_tree().process_frame
	await get_tree().process_frame

	# Create SectorScript node for walkthrough/tutorial step execution
	var sector_script_node := SectorScript.new()
	sector_script_node.name = "SectorScript"
	add_child(sector_script_node)

	# Initialize resources from item .tres files
	_init_resources()

	# Load a sector map if one was queued by PlanetSelect
	# (must happen before place_core so core_position is set from the map)
	print("Main._ready: pending_map_path = '%s'" % SaveManager.pending_map_path)
	if SaveManager.pending_map_path != "":
		var path := SaveManager.pending_map_path
		SaveManager.pending_map_path = ""
		print("Main._ready: Loading map from '%s'" % path)
		var ok: bool
		if path.ends_with(".sector.json"):
			ok = SaveManager.load_sector_from_path(path)
		else:
			ok = SaveManager.load_map_from_path(path)
		print("Main._ready: load returned %s" % ok)
		print("Main._ready: core_position is now %s" % core_position)
	else:
		print("Main._ready: No pending map")

	resources_changed.emit(resources)
	place_core()
	print("Main._ready: Core placed at %s" % core_position)

	# Move drone to core spawn — but only if the sector save didn't restore a position
	var drone = _drone_ref()
	if drone and drone.has_method("_move_to_core"):
		if not _drone_position_restored:
			drone._move_to_core()

	# Stats tracking
	building_placed.connect(func(_bid, _pos): stats_blocks_placed += 1)
	building_destroyed.connect(func(_pos): stats_blocks_removed += 1)

	# Sync resources to global pool whenever they change
	resources_changed.connect(_on_resources_changed_sync)

	# Connect tech tree to game events
	TechTree.connect_to_main(self)

	# Emit sector_launched if we came from planet select
	if SaveManager.pending_sector_id != &"":
		var sid := SaveManager.pending_sector_id
		SaveManager.pending_sector_id = &""
		SaveManager.active_sector_id = sid
		# Sync starting resources into the global pool for this sector
		SaveManager.sector_resources[sid] = resources.duplicate()
		SaveManager.save_campaign()
		sector_launched.emit(sid)

	_refresh_child_cache()


## Populates the _hud / _tech_ui / etc. cache. Call after the main scene tree
## has its expected children (typically at the end of _ready).
func _refresh_child_cache() -> void:
	_hud = get_node_or_null("HUD")
	_tech_ui = get_node_or_null("TechTreeUI")
	_db_ui = get_node_or_null("DatabaseUI")
	_drone = get_node_or_null("PlayerDrone")
	_unit_mgr = get_node_or_null("UnitManager")
	_terrain = get_node_or_null("TerrainSystem")
	_building_sys = get_node_or_null("BuildingSystem")
	_logistics = get_node_or_null("LogisticsSystem")
	_combat_sys = get_node_or_null("CombatSystem")
	_power_sys = get_node_or_null("PowerSystem")


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("pause_world"):
		if not is_ui_blocking():
			world_paused = not world_paused
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		# Block game input when a UI overlay is open
		if is_ui_blocking():
			return

# Sets up the resources dictionary from all registered items.
# This way new items added as .tres files automatically get a resource slot.
func _init_resources() -> void:
	for item in Registry.items_list:
		if not resources.has(item.id):
			resources[item.id] = 0
		if not ferox_resources.has(item.id):
			ferox_resources[item.id] = 0


## Keeps the global resource pool in sync with in-game resource changes.
func _on_resources_changed_sync(_res: Dictionary) -> void:
	if SaveManager.active_sector_id != &"":
		SaveManager.sector_resources[SaveManager.active_sector_id] = resources.duplicate()


# =========================
# BUILDING FUNCTIONS
# =========================

func select_building(block_id: StringName) -> void:
	selected_building = block_id
	building_selected.emit(block_id)


# Checks if the player can afford a block using its .tres data.
## Resolves a build_cost key (like "copper") to the matching resources key
## (like "mat_copper"). Tries the raw key first, then prepends "mat_".
func _resolve_resource_key(cost_key: String) -> StringName:
	var sn := StringName(cost_key)
	if resources.has(sn):
		return sn
	var mat_sn := StringName("mat_" + cost_key)
	if resources.has(mat_sn):
		return mat_sn
	return sn  # Fallback — will miss, but at least doesn't crash


func can_afford(block_id: StringName) -> bool:
	if not require_resources:
		return true
	var data = Registry.get_block(block_id)
	if data == null:
		return false
	for item_id in data.build_cost:
		var rk := _resolve_resource_key(str(item_id))
		if not resources.has(rk) or resources[rk] < int(data.build_cost[item_id]):
			return false
	return true


func is_cell_empty(grid_pos: Vector2i) -> bool:
	return not placed_buildings.has(grid_pos)


## Returns the anchor (top-left) position for a building at grid_pos.
## Returns null if no building exists there.
func get_building_anchor(grid_pos: Vector2i) -> Variant:
	if building_origins.has(grid_pos):
		return building_origins[grid_pos]
	return null


## Returns true if this cell is the anchor (top-left) of its building.
## For 1x1 buildings this is always true. For multi-tile, only the
## top-left cell returns true.
func is_building_anchor(grid_pos: Vector2i) -> bool:
	if not building_origins.has(grid_pos):
		return false
	return building_origins[grid_pos] == grid_pos


## Returns the faction of the building at grid_pos.
## Defaults to LUMINA if not set (backward compat with old saves).
func get_building_faction(grid_pos: Vector2i) -> int:
	return building_factions.get(grid_pos, Faction.LUMINA)


## Returns the per-type unit capacity based on all placed LUMINA cores.
## Each core's unit_capacity adds to the total.
func get_unit_cap_per_type() -> int:
	var cap := 0
	for grid_pos in placed_buildings:
		var block_id: StringName = placed_buildings[grid_pos]
		# Only count anchor cells (avoid counting multi-tile cores multiple times)
		if building_origins.get(grid_pos, grid_pos) != grid_pos:
			continue
		if get_building_faction(grid_pos) != Faction.LUMINA:
			continue
		var data = Registry.get_block(block_id)
		if data and data.unit_capacity > 0:
			cap += data.unit_capacity
	return cap


## Returns the count of player units of a specific type currently alive.
func get_player_unit_count(unit_id: StringName) -> int:
	var unit_mgr = _unit_mgr_ref()
	if not unit_mgr:
		return 0
	var count := 0
	for unit in unit_mgr.player_units:
		if is_instance_valid(unit) and unit.data and unit.data.id == unit_id:
			count += 1
	return count


## Returns true if another unit of this type can be spawned.
func can_spawn_unit(unit_id: StringName) -> bool:
	return get_player_unit_count(unit_id) < get_unit_cap_per_type()


## Returns the per-resource storage capacity based on all placed LUMINA cores.
## Each core's storage_capacity adds to the total. 0 = no cores placed.
func get_storage_cap_per_resource() -> int:
	var cap := 0
	for grid_pos in placed_buildings:
		var block_id: StringName = placed_buildings[grid_pos]
		if building_origins.get(grid_pos, grid_pos) != grid_pos:
			continue
		if get_building_faction(grid_pos) != Faction.LUMINA:
			continue
		var data = Registry.get_block(block_id)
		if data and data.storage_capacity > 0:
			cap += data.storage_capacity
	return cap


## Returns true if the core storage can accept one more of this resource.
func can_accept_resource(item_id: StringName) -> bool:
	var cap: int = get_storage_cap_per_resource()
	if cap <= 0:
		return true  # No cores = no limit (shouldn't happen in normal gameplay)
	return resources.get(item_id, 0) < cap


## Returns how much room is left for a specific resource.
func get_resource_room(item_id: StringName) -> int:
	var cap: int = get_storage_cap_per_resource()
	if cap <= 0:
		return 999999
	return maxi(0, cap - resources.get(item_id, 0))


## Returns build progress as 0.0–1.0 (1.0 = fully built).
## Buildings not in the progress dict are fully built.
func get_build_progress_pct(grid_pos: Vector2i) -> float:
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	if not building_build_progress.has(anchor):
		return 1.0
	var block_id = placed_buildings.get(anchor, &"")
	var data = Registry.get_block(block_id)
	if data == null or data.build_time <= 0:
		return 1.0
	return clampf(building_build_progress[anchor] / data.build_time, 0.0, 1.0)


## Returns true if the building at grid_pos is still under construction.
func is_building_constructing(grid_pos: Vector2i) -> bool:
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	return building_build_progress.has(anchor)


## Returns true if the building should not function (under construction,
## being deconstructed, or derelict). **Every** block type is inactive while
## its construction progress is advancing — including transport (conveyors,
## pipes). Items already on a half-built belt just sit there until the belt
## finishes; new items can't be pushed in. Systems that tick block behavior
## MUST consult this before doing any work on the cell.
func is_building_inactive(grid_pos: Vector2i) -> bool:
	if get_building_faction(grid_pos) == Faction.DERELICT:
		return true
	# Deconstructing buildings are fully inactive
	var anchor_check: Vector2i = building_origins.get(grid_pos, grid_pos)
	if building_deconstruct_progress.has(anchor_check):
		return true
	if is_building_constructing(grid_pos):
		return true
	return false


## Places a building directly without cost/range checks, assigning a specific faction.
## Used by sector loading and the map editor.
func place_building_with_faction(grid_pos: Vector2i, block_id: StringName, rotation: int, faction: int) -> bool:
	var data = Registry.get_block(block_id)
	if data == null:
		return false

	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var tile_pos = grid_pos + Vector2i(x, y)
			if not is_within_bounds(tile_pos):
				return false

	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var tile_pos = grid_pos + Vector2i(x, y)
			placed_buildings[tile_pos] = block_id
			building_health[tile_pos] = data.max_health
			building_rotation[tile_pos] = rotation
			building_origins[tile_pos] = grid_pos
			building_factions[tile_pos] = faction

	building_placed.emit(block_id, grid_pos)
	return true


## Returns a swap-group identifier for a block, or &"" if the block isn't
## part of any swappable family. Blocks in the same group can replace each
## other on placement (costing the new block's build_time), so you can e.g.
## replace a Belt Junction with a Conveyor Belt by just clicking on it.
##
## Groups:
##   &"belt"        — conveyor_belt and all its variants (junctions, routers,
##                    sorters, bridges, overflow/underflow)
##   &"duct"        — ducts and their variants
##   &"conduit"     — fluid conduits and their variants
##   &"payload"     — payload transport parts
##   &"freight"     — freight transport parts
##   &"shaft_power" — shaft, gearbox, overhead belt (legacy power-line group)
func _get_swap_group(data: BlockData) -> StringName:
	if data == null:
		return &""
	var id_str := String(data.id)
	# Belts
	if id_str == "conveyor_belt" or id_str.begins_with("belt_") \
			or id_str == "overflow_belt" or id_str == "underflow_belt" \
			or id_str == "inverted_belt_sorter":
		return &"belt"
	# Ducts
	if id_str == "duct" or id_str.begins_with("duct_") \
			or id_str == "overflow_duct" or id_str == "underflow_duct" \
			or id_str == "inverted_duct_sorter":
		return &"duct"
	# Fluid conduits
	if id_str == "fluid_conduit" or id_str.begins_with("conduit_") \
			or id_str == "overflow_conduit" or id_str == "underflow_conduit" \
			or id_str == "inverted_conduit_sorter":
		return &"conduit"
	# Payload transport
	if id_str == "payload_conveyor" or id_str == "payload_router" \
			or id_str == "payload_junction" or id_str == "payload_bridge" \
			or id_str == "payload_loader" or id_str == "payload_unloader":
		return &"payload"
	# Freight transport
	if id_str == "freight_conveyor" or id_str == "freight_router" \
			or id_str == "freight_junction" or id_str == "freight_bridge" \
			or id_str == "freight_loader" or id_str == "freight_unloader":
		return &"freight"
	# Legacy shaft/gearbox/overhead-belt group — kept so any existing
	# placements with these block ids still swap among themselves.
	if id_str == "shaft" or id_str == "gearbox" or id_str == "overhead_belt":
		return &"shaft_power"
	return &""


## Swaps an existing 1x1 building for a different 1x1 building at the same
## cell, clearing any logistics/power state the old block had and then placing
## the new one with the new block's build_time. Used by the belt/shaft swap
## feature in try_place_building.
func _swap_building_in_place(grid_pos: Vector2i, _old_data: BlockData, new_data: BlockData) -> bool:
	# Defer the swap: leave the existing block in placed_buildings so it keeps
	# functioning (belts keep moving items, drills keep producing, etc.) while
	# the drone walks over to do the work. The real destroy + re-place happens
	# in execute_pending_swap() when BuildingSystem begins ticking this anchor.
	if new_data.build_time > 0:
		# Replace any previous pending swap on the same cell (e.g. the player
		# dragged over it twice with different block selections).
		pending_swaps[grid_pos] = {
			"new_block_id": new_data.id,
			"new_rotation": placement_rotation,
		}
		if not work_order.has(grid_pos):
			work_order.append(grid_pos)
		# Signal so HUD / save layers can refresh queued-work readouts.
		building_placed.emit(new_data.id, grid_pos)
		return true
	# Zero-build-time swaps commit immediately (no drone work to schedule).
	return _execute_swap_now(grid_pos, new_data.id, placement_rotation)


## Executes a deferred same-group swap: destroys the old block (firing all
## the normal building_destroyed cleanup) and places the new one with build
## progress starting at 0, so the usual progressive-build flow picks up.
## Called by BuildingSystem when the drone arrives at a pending_swaps cell.
func execute_pending_swap(grid_pos: Vector2i) -> bool:
	if not pending_swaps.has(grid_pos):
		return false
	var entry: Dictionary = pending_swaps[grid_pos]
	pending_swaps.erase(grid_pos)
	var new_id: StringName = StringName(entry.get("new_block_id", &""))
	var new_rot: int = int(entry.get("new_rotation", 0))
	if new_id == &"":
		return false
	var new_data = Registry.get_block(new_id)
	if new_data == null:
		return false
	return _execute_swap_now(grid_pos, new_id, new_rot)


## Immediate swap: destroys the old block and places the new one at the same
## cell. Build progress starts at 0 (the drone will tick it up as usual).
func _execute_swap_now(grid_pos: Vector2i, new_id: StringName, new_rot: int) -> bool:
	var new_data = Registry.get_block(new_id)
	if new_data == null:
		return false
	# Destroy the existing block first — this fires building_destroyed so every
	# system clears its per-anchor state (conveyor_items, sorter_filters,
	# factory_buffers, power networks, etc.) and refunds nothing.
	destroy_building(grid_pos)

	# No immediate cost deduction — progressive consumption during build.

	# Place the new block at the same cell, rotation = new_rot.
	placed_buildings[grid_pos] = new_id
	building_health[grid_pos] = new_data.max_health
	building_rotation[grid_pos] = new_rot
	building_origins[grid_pos] = grid_pos
	building_factions[grid_pos] = Faction.LUMINA

	# Start build with progressive resource consumption.
	if new_data.build_time > 0:
		building_build_progress[grid_pos] = 0.0
		building_resources_consumed[grid_pos] = {}
		if not work_order.has(grid_pos):
			work_order.append(grid_pos)

	resources_changed.emit(resources)
	building_placed.emit(new_id, grid_pos)
	return true


func try_place_building(grid_pos: Vector2i) -> bool:
	if selected_building == &"":
		return false

	var data = Registry.get_block(selected_building)
	if data == null:
		return false

	# --- Same-block rotation update ---
	if placed_buildings.has(grid_pos) and placed_buildings[grid_pos] == selected_building:
		var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
		if anchor == grid_pos:
			var old_rot: int = building_rotation.get(grid_pos, 0)
			if old_rot != placement_rotation:
				for x in range(data.grid_size.x):
					for y in range(data.grid_size.y):
						building_rotation[grid_pos + Vector2i(x, y)] = placement_rotation
				building_placed.emit(selected_building, grid_pos)
			return true

	# --- Same-group swap: placing a belt part on top of another belt part
	# (or duct/conduit/payload/freight/shaft) replaces the existing block with
	# the new one, still paying the new block's build time. Only works for
	# 1x1 blocks (the families all use 1x1 parts).
	if data.grid_size == Vector2i(1, 1) and placed_buildings.has(grid_pos):
		var existing_id: StringName = placed_buildings[grid_pos]
		if existing_id != selected_building:
			var existing_data = Registry.get_block(existing_id)
			if existing_data != null and existing_data.grid_size == Vector2i(1, 1):
				var new_group: StringName = _get_swap_group(data)
				var old_group: StringName = _get_swap_group(existing_data)
				if new_group != &"" and new_group == old_group:
					# Only LUMINA can swap its own blocks.
					if get_building_faction(grid_pos) == Faction.LUMINA:
						return _swap_building_in_place(grid_pos, existing_data, data)

	# Check all tiles the building occupies (for multi-tile buildings)
	var terrain = _terrain_ref()
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var check_pos = grid_pos + Vector2i(x, y)
			if not is_within_bounds(check_pos) or not is_cell_empty(check_pos):
				return false
			# Can't place on walls
			if terrain and terrain.has_wall(check_pos):
				return false

	# Core zone rule: core blocks MUST be on core_zone floor tiles.
	if terrain and data.tags.has("core"):
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				var check_pos = grid_pos + Vector2i(x, y)
				var floor_data = terrain.get_floor_at(check_pos)
				if floor_data == null or not floor_data.tags.has("core_zone"):
					return false

	# Vent-powered buildings must be centered on a vent tile
	if data.tags.has("vent_powered"):
		if terrain:
			var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
			var tile_id = terrain.floor_tiles.get(center, &"")
			if tile_id != &"vent":
				return false

	# Extractors must face ore — or, for wall miners, a blackstone wall.
	# Geyser miners must be on a geyser (not face ore).
	if data.category == BlockData.BlockCategory.EXTRACTORS:
		if data.tags.has("geyser_miner"):
			if terrain:
				var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
				if terrain.floor_tiles.get(center, &"") != &"geyser":
					return false
		else:
			var building_sys = _building_sys_ref()
			if building_sys:
				if data.tags.has("wall_miner"):
					if not building_sys._is_facing_wall(grid_pos, placement_rotation, selected_building):
						return false
				else:
					if not building_sys._is_facing_ore(grid_pos, placement_rotation):
						return false

	# Pumps must be on liquid
	if data.tags.has("pump"):
		var building_sys = _building_sys_ref()
		if building_sys and not building_sys._is_on_liquid(grid_pos):
			return false

	# Check if within drone build range
	var drone = _drone_ref()
	if drone and not drone.is_in_build_range(grid_pos):
		return false

	# No immediate cost deduction — resources are consumed progressively
	# during construction by the build tick in building_system._process.

	# Place all tiles
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var tile_pos = grid_pos + Vector2i(x, y)
			placed_buildings[tile_pos] = selected_building
			building_health[tile_pos] = data.max_health
			building_rotation[tile_pos] = placement_rotation
			building_origins[tile_pos] = grid_pos
			building_factions[tile_pos] = Faction.LUMINA

	# Start build with progressive resource consumption.
	# build_time 0 → instant (no queue entry needed).
	if data.build_time > 0:
		building_build_progress[grid_pos] = 0.0
		building_resources_consumed[grid_pos] = {}
		work_order.append(grid_pos)

	resources_changed.emit(resources)
	building_placed.emit(selected_building, grid_pos)
	return true


## Places a building by explicit block_id and rotation (for schematics).
## Does NOT require selected_building/placement_rotation to be set.
func place_building_for_schematic(grid_pos: Vector2i, block_id: StringName, rot: int) -> bool:
	var data = Registry.get_block(block_id)
	if data == null:
		return false

	# Validate all tiles
	var terrain = _terrain_ref()
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var check_pos = grid_pos + Vector2i(x, y)
			if not is_within_bounds(check_pos) or not is_cell_empty(check_pos):
				return false
			if terrain and terrain.has_wall(check_pos):
				return false

	# Deduct costs
	if require_resources:
		if not can_afford(block_id):
			return false
		for item_id in data.build_cost:
			var rk := _resolve_resource_key(str(item_id))
			resources[rk] -= int(data.build_cost[item_id])

	# Place all tiles
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var tile_pos = grid_pos + Vector2i(x, y)
			placed_buildings[tile_pos] = block_id
			building_health[tile_pos] = data.max_health
			building_rotation[tile_pos] = rot
			building_origins[tile_pos] = grid_pos
			building_factions[tile_pos] = Faction.LUMINA

	# Start build animation
	if data.build_time > 0:
		building_build_progress[grid_pos] = 0.0
		build_order.append(grid_pos)

	resources_changed.emit(resources)
	building_placed.emit(block_id, grid_pos)
	return true


# Deals damage to a building. Destroys it if HP reaches 0.
func damage_building(grid_pos: Vector2i, amount: float) -> void:
	if not building_health.has(grid_pos):
		return
	building_health[grid_pos] -= amount
	if building_health[grid_pos] <= 0:
		destroy_building(grid_pos)


# Queues a building for deconstruction. Resources are refunded progressively
# during the deconstruct tick, not instantly.
func destroy_building_with_refund(grid_pos: Vector2i) -> void:
	if not placed_buildings.has(grid_pos):
		return
	var block_id = placed_buildings[grid_pos]
	var data = Registry.get_block(block_id)
	# Don't refund or destroy cores
	if data and data.tags.has("core"):
		return
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	# If already deconstructing, skip
	if building_deconstruct_progress.has(anchor):
		return
	# How much was actually paid so far — this is what gets refunded.
	var total_to_refund := {}
	var starting_progress: float = 0.0

	if building_build_progress.has(anchor):
		# Partially built — reverse from where construction got to.
		total_to_refund = building_resources_consumed.get(anchor, {}).duplicate()
		# Deconstruct starts at the current build progress and counts down to 0.
		var build_time_full: float = data.build_time if data else 1.0
		if build_time_full <= 0:
			build_time_full = 1.0
		starting_progress = clampf(building_build_progress[anchor], 0.0, build_time_full)
		# Clean up the build entry — it's now a deconstruct.
		building_build_progress.erase(anchor)
		building_resources_consumed.erase(anchor)
		var wi := work_order.find(anchor)
		if wi >= 0:
			work_order.remove_at(wi)
	else:
		# Fully built — refund full build cost over the full build_time.
		if data:
			for item_id in data.build_cost:
				var rk := _resolve_resource_key(str(item_id))
				total_to_refund[rk] = int(data.build_cost[item_id])

	# Deconstruct duration = how far the build got (partially built) or
	# full build_time (fully built). Minimum 0.5s for visual feedback.
	var build_time_full: float = data.build_time if data else 1.0
	if build_time_full <= 0:
		build_time_full = 1.0
	var decon_time: float
	var max_build_pct: float  # How far the build got (0-1); 1.0 = fully built
	if starting_progress > 0.0:
		decon_time = maxf(starting_progress, 0.5)
		max_build_pct = clampf(starting_progress / build_time_full, 0.0, 1.0)
	else:
		decon_time = build_time_full
		if decon_time <= 0:
			decon_time = 0.5
		max_build_pct = 1.0

	building_deconstruct_progress[anchor] = {
		"block_id": block_id,
		"progress": 0.0,
		"build_time": decon_time,
		"rotation": building_rotation.get(grid_pos, 0),
		"total_refund": total_to_refund,
		"max_build_pct": max_build_pct,  # For the visual: line starts here and goes back to 0
	}
	building_resources_refunded[anchor] = {}
	# Deconstruct is more urgent than queued builds — insert at the front
	# of the work queue (after any currently-active item at index 0, unless
	# this anchor WAS the active item, in which case it takes slot 0).
	if work_order.is_empty() or work_order[0] == anchor:
		if not work_order.is_empty():
			work_order.remove_at(0)
		work_order.insert(0, anchor)
	else:
		work_order.insert(1, anchor)

	# Block has just flipped from active → inactive (is_building_inactive
	# returns true whenever a decon entry exists). Invalidate the power
	# network so its contribution is removed from the balance on the next
	# tick, matching the signal-less construction-completion path.
	var ps := _power_sys_ref()
	if ps and "_networks_dirty" in ps:
		ps._networks_dirty = true


## Alias for destroy_building_with_refund — starts deconstruct animation with refund.
func start_deconstruct(grid_pos: Vector2i) -> void:
	destroy_building_with_refund(grid_pos)


## Picks up a building into a payload dictionary, silently removing it from the grid.
## Returns the payload data, or an empty dict if pickup failed.
## Does NOT emit building_destroyed — the building is just "lifted", not destroyed.
func pickup_building(grid_pos: Vector2i) -> Dictionary:
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	if not placed_buildings.has(anchor):
		return {}
	var block_id: StringName = placed_buildings[anchor]
	var data = Registry.get_block(block_id)
	if data == null:
		return {}
	# Don't pick up cores
	if data.tags.has("core"):
		return {}
	var rot: int = building_rotation.get(anchor, 0)
	var health: float = building_health.get(anchor, data.max_health)
	var faction: int = get_building_faction(anchor)

	# Capture stored items/fluids from logistics
	var stored_items := {}
	var stored_fluids := {}
	var logistics = _logistics_ref()
	if logistics and logistics.block_storage.has(anchor):
		var storage = logistics.block_storage[anchor]
		stored_items = storage.get("items", {}).duplicate()
		stored_fluids = storage.get("fluids", {}).duplicate()
		logistics.block_storage.erase(anchor)
	# Also capture factory buffer inputs
	var factory_state := {}
	if logistics and logistics.factory_buffers.has(anchor):
		factory_state = logistics.factory_buffers[anchor].duplicate(true)
		var fb_inputs = factory_state.get("inputs", {})
		for item_id in fb_inputs:
			stored_items[item_id] = stored_items.get(item_id, 0) + int(fb_inputs[item_id])
		factory_state.erase("inputs")  # Items merged into stored_items
		logistics.factory_buffers.erase(anchor)

	# Capture constructor state
	var constructor_data := {}
	if logistics and "constructor_state" in logistics and logistics.constructor_state.has(anchor):
		constructor_data = logistics.constructor_state[anchor].duplicate(true)
		logistics.constructor_state.erase(anchor)

	# Capture sorter filter
	var sorter_filter: StringName = &""
	if logistics and logistics.sorter_filters.has(anchor):
		sorter_filter = logistics.sorter_filters[anchor]
		logistics.sorter_filters.erase(anchor)

	# Capture drill timer
	var drill_timer: float = -1.0
	if logistics and logistics.drill_timers.has(anchor):
		drill_timer = logistics.drill_timers[anchor]
		logistics.drill_timers.erase(anchor)

	# Build payload data
	var payload := {
		"type": "building",
		"block_id": str(block_id),
		"rotation": rot,
		"health": health,
		"faction": faction,
		"stored_items": stored_items,
		"stored_fluids": stored_fluids,
		"grid_size_x": data.grid_size.x,
		"grid_size_y": data.grid_size.y,
		"factory_state": factory_state,
		"constructor_data": constructor_data,
		"sorter_filter": str(sorter_filter),
		"drill_timer": drill_timer,
	}

	# Silently remove all tiles of this building
	if data.grid_size.x > 1 or data.grid_size.y > 1:
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				var tile_pos = anchor + Vector2i(x, y)
				placed_buildings.erase(tile_pos)
				building_health.erase(tile_pos)
				building_rotation.erase(tile_pos)
				building_origins.erase(tile_pos)
				building_factions.erase(tile_pos)
	else:
		placed_buildings.erase(anchor)
		building_health.erase(anchor)
		building_rotation.erase(anchor)
		building_origins.erase(anchor)
		building_factions.erase(anchor)

	# Clean up build/deconstruct progress and unified work queue
	building_build_progress.erase(anchor)
	building_deconstruct_progress.erase(anchor)
	building_resources_consumed.erase(anchor)
	building_resources_refunded.erase(anchor)
	var work_idx: int = work_order.find(anchor)
	if work_idx >= 0:
		work_order.remove_at(work_idx)
	# Legacy compat
	var order_idx: int = build_order.find(anchor)
	if order_idx >= 0:
		build_order.remove_at(order_idx)
	var decon_idx: int = deconstruct_order.find(anchor)
	if decon_idx >= 0:
		deconstruct_order.remove_at(decon_idx)

	# Clean up turret angles (combat system)
	var combat = _combat_sys_ref()
	if combat and "turret_angles" in combat:
		combat.turret_angles.erase(anchor)

	# Clean up links (power system)
	var power_sys = _power_sys_ref()
	if power_sys and "linked_pairs" in power_sys:
		var to_remove := []
		for i in range(power_sys.linked_pairs.size()):
			var pair = power_sys.linked_pairs[i]
			if pair[0] == anchor or pair[1] == anchor:
				to_remove.append(i)
		for i in range(to_remove.size() - 1, -1, -1):
			power_sys.linked_pairs.remove_at(to_remove[i])

	# Clean up crane states (building system)
	var building_sys = _building_sys_ref()
	if building_sys and "crane_states" in building_sys:
		building_sys.crane_states.erase(anchor)
	if building_sys and "archive_holdings" in building_sys:
		building_sys.archive_holdings.erase(anchor)
	if building_sys and "archive_decoder_state" in building_sys:
		building_sys.archive_decoder_state.erase(anchor)

	# Clean up conveyor items on this building's tiles
	if logistics:
		if data.grid_size.x > 1 or data.grid_size.y > 1:
			for x in range(data.grid_size.x):
				for y in range(data.grid_size.y):
					var tile_pos = anchor + Vector2i(x, y)
					logistics.conveyor_items.erase(tile_pos)
					if "payload_items" in logistics:
						logistics.payload_items.erase(tile_pos)
		else:
			logistics.conveyor_items.erase(anchor)
			if "payload_items" in logistics:
				logistics.payload_items.erase(anchor)

	# Clean up remaining per-anchor state via the logistics destroy handler.
	# Pickup does not emit building_destroyed (to avoid stats/rebuild side effects),
	# so we call the cleanup directly to keep state dictionaries in sync.
	if logistics and logistics.has_method("_on_building_destroyed"):
		logistics._on_building_destroyed(anchor)

	return payload


## Places a building from a payload dictionary onto the grid.
## Returns true if placement succeeded.
func place_payload_building(payload: Dictionary, grid_pos: Vector2i) -> bool:
	var block_id := StringName(payload.get("block_id", ""))
	var data = Registry.get_block(block_id)
	if data == null:
		return false

	# Check all tiles are available
	var terrain = _terrain_ref()
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var check_pos = grid_pos + Vector2i(x, y)
			if not is_within_bounds(check_pos) or not is_cell_empty(check_pos):
				return false
			if terrain and terrain.has_wall(check_pos):
				return false

	# Extractor placement checks
	if data.category == BlockData.BlockCategory.EXTRACTORS:
		var building_sys = _building_sys_ref()
		if building_sys:
			var pay_rot := int(payload.get("rotation", 0))
			if data.tags.has("wall_miner"):
				if not building_sys._is_facing_wall(grid_pos, pay_rot, block_id):
					return false
			else:
				if not building_sys._is_facing_ore(grid_pos, pay_rot, block_id):
					return false

	# Vent-powered check
	if data.tags.has("vent_powered") and terrain:
		var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
		if terrain.floor_tiles.get(center, &"") != &"vent":
			return false

	var rot: int = int(payload.get("rotation", 0))
	var health: float = float(payload.get("health", data.max_health))
	var faction: int = int(payload.get("faction", Faction.LUMINA))

	# Place all tiles
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var tile_pos = grid_pos + Vector2i(x, y)
			placed_buildings[tile_pos] = block_id
			building_health[tile_pos] = health
			building_rotation[tile_pos] = rot
			building_origins[tile_pos] = grid_pos
			building_factions[tile_pos] = faction

	# Restore stored items/fluids
	var logistics = _logistics_ref()
	if logistics:
		var stored_items: Dictionary = payload.get("stored_items", {})
		var stored_fluids: Dictionary = payload.get("stored_fluids", {})
		if not stored_items.is_empty() or not stored_fluids.is_empty():
			logistics.block_storage[grid_pos] = {
				"items": stored_items.duplicate(),
				"fluids": stored_fluids.duplicate(),
			}

		# Restore factory state (phase, timer, pending outputs)
		var factory_state: Dictionary = payload.get("factory_state", {})
		if not factory_state.is_empty():
			factory_state["inputs"] = {}  # Items already in block_storage
			logistics.factory_buffers[grid_pos] = factory_state

		# Restore constructor state
		var constructor_data: Dictionary = payload.get("constructor_data", {})
		if not constructor_data.is_empty():
			logistics.constructor_state[grid_pos] = constructor_data

		# Restore sorter filter
		var sorter_filter: String = payload.get("sorter_filter", "")
		if sorter_filter != "":
			logistics.sorter_filters[grid_pos] = StringName(sorter_filter)

		# Restore drill timer
		var drill_timer: float = float(payload.get("drill_timer", -1.0))
		if drill_timer >= 0.0:
			logistics.drill_timers[grid_pos] = drill_timer

	building_placed.emit(block_id, grid_pos)
	return true


## Returns the deconstruct progress (0.0 = just started, 1.0 = done) or -1.0 if not deconstructing.
func get_deconstruct_pct(grid_pos: Vector2i) -> float:
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	if not building_deconstruct_progress.has(anchor):
		return -1.0
	var entry: Dictionary = building_deconstruct_progress[anchor]
	return clampf(entry["progress"] / entry["build_time"], 0.0, 1.0)


# Completely removes a building from the grid.
func destroy_building(grid_pos: Vector2i) -> void:
	if not placed_buildings.has(grid_pos):
		return

	var block_id = placed_buildings[grid_pos]
	var data = Registry.get_block(block_id)
	var faction = get_building_faction(grid_pos)
	var anchor = building_origins.get(grid_pos, grid_pos)
	var rot = building_rotation.get(grid_pos, 0)

	# Track enemy block destroyed stat
	if faction == Faction.FEROX or faction == Faction.DERELICT:
		stats_enemy_blocks_destroyed += 1

	# Queue ferox buildings for rebuild (only anchors, to avoid duplicates)
	if faction == Faction.FEROX and data and anchor == grid_pos:
		# Don't queue cores for rebuild
		if data.category != BlockData.BlockCategory.CORE:
			ferox_rebuild_queue.append({
				"block_id": block_id,
				"grid_pos": anchor,
				"rotation": rot,
			})

	# Track destroyed player buildings for rebuild mode (only anchors)
	if faction == Faction.LUMINA and data and anchor == grid_pos:
		destroyed_player_buildings[anchor] = {
			"block_id": block_id,
			"rotation": rot,
		}

	# Emit BEFORE erasing so signal handlers can still read building data
	building_destroyed.emit(grid_pos)

	# For multi-tile buildings, remove all tiles that share this block ID
	# and are adjacent (part of the same structure)
	if data and (data.grid_size.x > 1 or data.grid_size.y > 1):
		_remove_multi_tile_building(grid_pos, block_id, data)
	else:
		placed_buildings.erase(grid_pos)
		building_health.erase(grid_pos)
		building_rotation.erase(grid_pos)
		building_origins.erase(grid_pos)
		building_factions.erase(grid_pos)

	# Check AFTER removal so the destroyed core isn't found in the scan
	if faction == Faction.FEROX and data and data.tags.has("core"):
		_check_enemy_cores_remaining()
	if faction == Faction.LUMINA and data and data.tags.has("core"):
		_check_player_cores_remaining()

	building_build_progress.erase(anchor)
	building_deconstruct_progress.erase(anchor)
	building_resources_consumed.erase(anchor)
	building_resources_refunded.erase(anchor)
	pending_swaps.erase(anchor)
	var work_idx2: int = work_order.find(anchor)
	if work_idx2 >= 0:
		work_order.remove_at(work_idx2)
	var order_idx: int = build_order.find(anchor)
	if order_idx >= 0:
		build_order.remove_at(order_idx)
	# Clean up pause bookkeeping so nothing is left stranded-paused by
	# a destroyed trigger, and any explicit pause on this anchor is gone.
	resume_auto_paused_by(anchor)
	work_paused.erase(anchor)

	var unit_mgr = _unit_mgr_ref()
	if unit_mgr:
		unit_mgr.on_building_destroyed(grid_pos)


# Removes all tiles belonging to a multi-tile building.
func _remove_multi_tile_building(grid_pos: Vector2i, block_id: StringName, data: BlockData) -> void:
	# Find the anchor for this building
	var anchor = building_origins.get(grid_pos, grid_pos)

	# Remove all tiles belonging to this anchor
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var check_pos = anchor + Vector2i(x, y)
			if placed_buildings.has(check_pos) and placed_buildings[check_pos] == block_id:
				placed_buildings.erase(check_pos)
				building_health.erase(check_pos)
				building_rotation.erase(check_pos)
				building_origins.erase(check_pos)
				building_factions.erase(check_pos)
				var unit_mgr = _unit_mgr_ref()
				if unit_mgr:
					unit_mgr.on_building_destroyed(check_pos)


# Returns the health percentage (0.0 to 1.0) of a building.
func get_building_health_pct(grid_pos: Vector2i) -> float:
	if not building_health.has(grid_pos) or not placed_buildings.has(grid_pos):
		return 1.0
	var block_id = placed_buildings[grid_pos]
	var data = Registry.get_block(block_id)
	if data == null:
		return 1.0
	return building_health[grid_pos] / data.max_health


# =========================
# CORE
# =========================

func place_core() -> void:
	var core_data = Registry.get_block(&"core_shard")
	if core_data == null:
		push_warning("Core block not found in Registry!")
		return

	for x in range(core_data.grid_size.x):
		for y in range(core_data.grid_size.y):
			var grid_pos = core_position + Vector2i(x, y)
			placed_buildings[grid_pos] = &"core_shard"
			building_health[grid_pos] = core_data.max_health
			building_origins[grid_pos] = core_position
			building_factions[grid_pos] = Faction.LUMINA

	building_placed.emit(&"core_shard", core_position)


# =========================
# COORDINATE HELPERS
# =========================

func world_to_grid(world_pos: Vector2) -> Vector2i:
	return Vector2i(
		floori(world_pos.x / GRID_SIZE),
		floori(world_pos.y / GRID_SIZE)
	)

func grid_to_world(grid_pos: Vector2i) -> Vector2:
	return Vector2(grid_pos.x * GRID_SIZE, grid_pos.y * GRID_SIZE)

func is_within_bounds(grid_pos: Vector2i) -> bool:
	return (
		grid_pos.x >= 0 and grid_pos.x < GRID_WIDTH and
		grid_pos.y >= 0 and grid_pos.y < GRID_HEIGHT
	)


## Draws a Mindustry-style beam between two points.
## canvas: the CanvasItem calling draw functions on
## from_pos / to_pos: positions in canvas-local coordinates
## color: the outer beam color (e.g. yellow for mining)
## pulse: 0.0-1.0 animation phase for pulsing alpha
## width: base width of the outer colored lines
## circle_radius: radius of the endpoint circles
static func draw_beam(canvas: CanvasItem, from_pos: Vector2, to_pos: Vector2, color: Color, pulse: float = 1.0, width: float = 5.0, circle_radius: float = 8.0) -> void:
	var alpha: float = 0.6 + 0.3 * pulse
	var outer_color := Color(color.r, color.g, color.b, alpha)
	var inner_color := Color(1.0, 1.0, 1.0, alpha)
	var inner_width: float = width * 0.5
	var inner_radius: float = circle_radius * 0.5

	# Outer colored lines (offset perpendicular to beam direction)
	var dir: Vector2 = (to_pos - from_pos).normalized()
	var perp: Vector2 = Vector2(-dir.y, dir.x)
	var offset: float = width * 0.6

	canvas.draw_line(from_pos + perp * offset, to_pos + perp * offset, outer_color, width, true)
	canvas.draw_line(from_pos - perp * offset, to_pos - perp * offset, outer_color, width, true)

	# Center white line
	canvas.draw_line(from_pos, to_pos, inner_color, inner_width, true)

	# Endpoint circles — outer colored, inner white
	# From
	canvas.draw_circle(from_pos, circle_radius, outer_color)
	canvas.draw_circle(from_pos, inner_radius, inner_color)
	# To
	canvas.draw_circle(to_pos, circle_radius, outer_color)
	canvas.draw_circle(to_pos, inner_radius, inner_color)


# =========================
# DERELICT CONVERSION
# =========================

## Check if any FEROX cores remain. If not, convert all FEROX buildings to DERELICT.
func _check_player_cores_remaining() -> void:
	for pos in placed_buildings:
		if get_building_faction(pos) == Faction.LUMINA:
			var bid = placed_buildings[pos]
			var d = Registry.get_block(bid)
			if d and d.tags.has("core"):
				return  # At least one LUMINA core still exists
	# No LUMINA cores remain — sector lost
	if not sector_lost:
		sector_lost = true
		world_paused = true
		var hud_node = _hud_ref()
		if hud_node and hud_node.has_method("show_sector_loss"):
			hud_node.show_sector_loss()


func _check_enemy_cores_remaining() -> void:
	for pos in placed_buildings:
		if get_building_faction(pos) == Faction.FEROX:
			var bid = placed_buildings[pos]
			var d = Registry.get_block(bid)
			if d and d.tags.has("core"):
				return  # At least one FEROX core still exists
	# No FEROX cores remain — convert all FEROX to DERELICT
	all_enemy_cores_destroyed = true
	_convert_ferox_to_derelict()


## Convert all remaining FEROX buildings to DERELICT faction.
func _convert_ferox_to_derelict() -> void:
	var converted := 0
	for pos in building_factions.keys():
		if building_factions[pos] == Faction.FEROX:
			building_factions[pos] = Faction.DERELICT
			converted += 1
	ferox_rebuild_queue.clear()  # Stop ferox rebuilds
	print("Main: Converted %d FEROX blocks to DERELICT." % converted)


## Convert all DERELICT buildings in a rect to LUMINA.
func convert_derelict_in_rect(from: Vector2i, to: Vector2i) -> void:
	var min_pos := Vector2i(mini(from.x, to.x), mini(from.y, to.y))
	var max_pos := Vector2i(maxi(from.x, to.x), maxi(from.y, to.y))
	for x in range(min_pos.x, max_pos.x + 1):
		for y in range(min_pos.y, max_pos.y + 1):
			var pos := Vector2i(x, y)
			if building_factions.get(pos, -1) == Faction.DERELICT:
				building_factions[pos] = Faction.LUMINA


## Queue destroyed player buildings in a rect for rebuild.
## Returns the number of buildings queued.
func queue_rebuild_in_rect(from: Vector2i, to: Vector2i) -> int:
	var min_pos := Vector2i(mini(from.x, to.x), mini(from.y, to.y))
	var max_pos := Vector2i(maxi(from.x, to.x), maxi(from.y, to.y))
	var count := 0
	for anchor in destroyed_player_buildings.keys():
		if anchor.x >= min_pos.x and anchor.x <= max_pos.x and anchor.y >= min_pos.y and anchor.y <= max_pos.y:
			var info: Dictionary = destroyed_player_buildings[anchor]
			var block_id: StringName = info["block_id"]
			var rot: int = info["rotation"]
			# Check if position is still empty
			if is_cell_empty(anchor):
				var old_building = selected_building
				var old_rotation = placement_rotation
				selected_building = block_id
				placement_rotation = rot
				try_place_building(anchor)
				selected_building = old_building
				placement_rotation = old_rotation
				count += 1
			destroyed_player_buildings.erase(anchor)
	return count
