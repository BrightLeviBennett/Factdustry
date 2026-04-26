extends Node

# ============================================================
# SAVE_MANAGER.GD - Map Save/Load System (Autoload)
# ============================================================
# Saves and loads maps as JSON files in user://maps/.
#
# Two save modes:
#   1. "Map only" — Just tiles (the terrain layout). Like a
#      reusable map template you can start fresh games on.
#   2. "Full save" — Tiles + buildings + resources + drone
#      position. A complete game state snapshot.
#   3. "Sector" — Tiles + pre-placed buildings with factions.
#      A blank slate map template with enemy/player structures.
#
# Files are stored in Godot's user data directory:
#   - Windows: %APPDATA%\Godot\app_userdata\Bacteriums\maps\
#   - macOS:   ~/Library/Application Support/Godot/app_userdata/Bacteriums/maps/
#   - Linux:   ~/.local/share/godot/app_userdata/Bacteriums/maps/
#
# HOW TO SET UP:
# 1. Go to Project → Project Settings → Autoload
# 2. Add this script with the name "SaveManager"
# ============================================================

const SAVE_DIR := "user://maps/"
const SCHEMATIC_DIR := "res://data/user/Schematics/"

## Set to true when navigating to PlanetSelect from an active game.
## PlanetSelect checks this to show a "Back to Map" button.
var return_to_game := false

## Set to true when navigating to PlanetSelect from the main menu.
## PlanetSelect checks this to show a "Back to Menu" button.
var return_to_menu := false

## If set, the game scene loads this map file on startup, then clears it.
## Used by PlanetSelect to pass sector map paths across scene transitions.
var pending_map_path := ""

## Sector ID that was launched (set by PlanetSelect, consumed by Main).
var pending_sector_id: StringName = &""

## The sector currently being played (set by Main, cleared on exit).
var active_sector_id: StringName = &""

## Per-sector resource storage for the global tech tree pool.
## Maps sector_id (StringName) → resources Dictionary (item_id → amount).
var sector_resources: Dictionary = {}

## Per-sector offline production rates (items per second).
## Maps sector_id → {item_id: float rate}. Captured when the sector is saved
## via SectorProductionSim, then applied to sector_resources across elapsed
## real-time via advance_offline_production().
var sector_production_rates: Dictionary = {}

## Per-sector unix timestamp of the last accrual tick. When a sector is
## re-entered or accrual is requested, (now - timestamp) * rate is added to
## that sector's sector_resources, then the timestamp resets to now.
var sector_production_timestamps: Dictionary = {}

## Fractional carryover so slow producers don't lose sub-integer production
## between accrual calls. Maps sector_id → {item_id: float fractional}.
var _sector_production_fractions: Dictionary = {}

## Per-sector storage cap (per resource) captured at snapshot time. Offline
## accrual clamps against this so a sector with a 4K-capacity shard can't
## keep filling up past 4K while the player is away. Maps sector_id → int.
var sector_storage_caps: Dictionary = {}


func _ready() -> void:
	# Create the maps directory if it doesn't exist.
	# DirAccess is Godot's file system API.
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	DirAccess.make_dir_recursive_absolute(SCHEMATIC_DIR)
	# Wait for TechTree to finish threaded loading before loading campaign save
	if TechTree.is_loaded:
		call_deferred("load_campaign")
	else:
		TechTree.tech_tree_ready.connect(_on_tech_tree_ready, CONNECT_ONE_SHOT)


## Autoload-level close-request handler so pressing the X button works from
## ANY scene (main menu, planet select, in-game). The project has
## application/config/auto_accept_quit disabled so in-game saves fire before
## quit — without this handler, closing the window from any non-Main scene
## would silently do nothing, forcing the player to kill the process.
## Main.gd additionally handles its own NOTIFICATION_WM_CLOSE_REQUEST for
## save-on-close; both handlers ultimately call get_tree().quit().
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# If an in-game sector is active, persist it before exiting.
		if active_sector_id != &"" and active_sector_id != &"_default":
			sync_active_sector_resources()
			save_sector(active_sector_id)
		save_campaign()
		get_tree().quit()


func _on_tech_tree_ready() -> void:
	load_campaign()


## Check if a sector has fallen while the player was away.
## Returns a Dictionary: {fallen: bool, time_remaining: float, summary: String}
func check_sector_status(sector_id: StringName) -> Dictionary:
	var save_path := SAVE_DIR + str(sector_id) + ".sector.json"
	var data = _read_json(save_path)
	if data == null or not data.has("defense_sim"):
		return {"fallen": false, "time_remaining": INF, "summary": "No data"}

	var sim = data["defense_sim"]
	var is_stable: bool = sim.get("is_stable", true)
	if is_stable:
		return {"fallen": false, "time_remaining": INF, "summary": "Stable"}

	var time_to_fall: float = float(sim.get("time_to_fall", -1.0))
	if time_to_fall < 0:
		return {"fallen": false, "time_remaining": INF, "summary": "Stable"}

	var save_timestamp: float = float(sim.get("timestamp", 0.0))
	var now: float = Time.get_unix_time_from_system()
	var elapsed: float = now - save_timestamp
	var remaining: float = time_to_fall - elapsed

	if remaining <= 0:
		return {"fallen": true, "time_remaining": 0.0, "summary": "SECTOR LOST"}
	else:
		return {
			"fallen": false,
			"time_remaining": remaining,
			"summary": SectorDefenseSim._format_time(remaining) + " remaining",
		}


# =========================
# SAVE: FULL GAME STATE
# =========================

## Saves everything: tiles, buildings, resources, drone position.
func save_game(save_name: String) -> bool:
	var main = get_node_or_null("/root/Main")
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	var drone = get_node_or_null("/root/Main/PlayerDrone")
	if main == null or terrain == null:
		push_warning("SaveManager: Can't find Main or TerrainSystem!")
		return false

	var data := {
		"version": 2,
		"type": "save",
		"save_name": save_name,
		"grid_width": main.GRID_WIDTH,
		"grid_height": main.GRID_HEIGHT,

		# Tiles (separate layers so overlapping tiles are preserved)
		"floor_tiles": _serialize_tiles(terrain.floor_tiles),
		"wall_tiles": _serialize_tiles(terrain.wall_tiles),
		"ore_tiles": _serialize_tiles(terrain.ore_tiles),
		"tile_health": _serialize_health(terrain.tile_health),

		# Buildings
		"buildings": _serialize_buildings(main.placed_buildings),
		"building_health": _serialize_health(main.building_health),
		"building_rotation": _serialize_rotation(main.building_rotation),
		"building_factions": _serialize_factions(main.building_factions),

		# Resources
		"resources": _serialize_resources(main.resources),
		"ferox_resources": _serialize_resources(main.ferox_resources),
		"ferox_rebuild_queue": _serialize_rebuild_queue(main.ferox_rebuild_queue),

		# Core
		"core_position": _vec2i_to_str(main.core_position),

		# Drone
		"drone_position": _vec2_to_array(drone.position) if drone else [0, 0],
		"drone_health": drone.health if drone else 100.0,
	}

	return _write_json(SAVE_DIR + save_name + ".save.json", data)


# =========================
# LOAD: FULL GAME STATE
# =========================

## Loads a complete game state.
func load_game(save_name: String) -> bool:
	var main = get_node_or_null("/root/Main")
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	var drone = get_node_or_null("/root/Main/PlayerDrone")
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if main == null or terrain == null:
		push_warning("SaveManager: Can't find required nodes!")
		return false

	var data = _read_json(SAVE_DIR + save_name + ".save.json")
	if data == null:
		return false

	if data.get("type") != "save":
		push_warning("SaveManager: File is not a full save!")
		return false

	# --- Clear everything ---
	terrain.floor_tiles.clear()
	terrain.wall_tiles.clear()
	terrain.ore_tiles.clear()
	terrain.tile_health.clear()
	terrain.multi_tile_origins.clear()
	main.placed_buildings.clear()
	main.building_health.clear()
	main.building_rotation.clear()
	main.building_factions.clear()

	# --- Restore map size ---
	if data.has("grid_width"):
		main.GRID_WIDTH = int(data["grid_width"])
	if data.has("grid_height"):
		main.GRID_HEIGHT = int(data["grid_height"])

	# --- Load tiles ---
	var version = data.get("version", 1)
	if version >= 2:
		_deserialize_layer(terrain.floor_tiles, data.get("floor_tiles", {}))
		_deserialize_layer(terrain.wall_tiles, data.get("wall_tiles", {}))
		_deserialize_layer(terrain.ore_tiles, data.get("ore_tiles", {}))
	else:
		_deserialize_tiles_layered(terrain, data.get("tiles", {}))
	_deserialize_tile_health(terrain, data.get("tile_health", {}))
	_rebuild_multi_tile_origins(terrain)

	# --- Load buildings ---
	_deserialize_buildings(main, data.get("buildings", {}))
	_deserialize_building_health(main, data.get("building_health", {}))
	_deserialize_building_rotation(main, data.get("building_rotation", {}))
	_deserialize_building_factions(main, data.get("building_factions", {}))

	# --- Load resources ---
	var saved_resources = data.get("resources", {})
	for key in saved_resources:
		main.resources[StringName(key)] = int(saved_resources[key])
	main.resources_changed.emit(main.resources)

	# --- Load ferox resources ---
	var saved_ferox = data.get("ferox_resources", {})
	for key in saved_ferox:
		main.ferox_resources[StringName(key)] = int(saved_ferox[key])
	main.ferox_resources_changed.emit(main.ferox_resources)

	# --- Load ferox rebuild queue ---
	main.ferox_rebuild_queue = _deserialize_rebuild_queue(data.get("ferox_rebuild_queue", []))

	# --- Load core position ---
	if data.has("core_position"):
		main.core_position = _str_to_vec2i(data["core_position"])

	# --- Load drone ---
	if drone and data.has("drone_position"):
		var pos = data["drone_position"]
		drone.position = Vector2(pos[0], pos[1])
		drone.health = data.get("drone_health", drone.max_health)

	# --- Rebuild pathfinding ---
	# Both the main-thread astar AND the threaded path_worker need a
	# fresh solids list — the worker was started at unit_manager._ready
	# with whatever terrain existed at that moment (often empty, before
	# the sector load populated walls / floor tiles), so leaving it
	# stale causes async paths to walk right across walls into void.
	if unit_mgr:
		unit_mgr._setup_astar()
		unit_mgr._setup_path_worker()

	# --- Redraw ---
	# Bulk-loaded terrain bypassed the `place_tile` dirty hooks, so any
	# rebuild triggered between map-clear and now ran against an empty
	# floor_tiles set and latched _water_depth_dirty / _floor_edge_dirty
	# to false. Re-arm them so the next draw pass actually bakes the
	# gradient meshes against the real tile set.
	terrain._water_depth_dirty = true
	terrain._floor_edge_dirty = true
	terrain.walls_changed.emit()
	terrain.queue_redraw()
	if building_sys:
		building_sys.queue_redraw()

	var total_tiles: int = terrain.floor_tiles.size() + terrain.wall_tiles.size() + terrain.ore_tiles.size()
	print("SaveManager: Game '%s' loaded (%d tiles, %d buildings)" % [
		save_name, total_tiles, main.placed_buildings.size()
	])
	return true


# =========================
# LIST SAVES
# =========================

## Returns an array of available full save names.
func list_saves() -> PackedStringArray:
	return _list_files(".save.json")


## Returns an array of available sector names.
func list_sectors() -> PackedStringArray:
	return _list_files(".sector.json")


func _list_files(suffix: String) -> PackedStringArray:
	var result = PackedStringArray()
	var dir = DirAccess.open(SAVE_DIR)
	if dir == null:
		return result

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name.ends_with(suffix):
			# Strip the suffix to get just the name
			result.append(file_name.replace(suffix, ""))
		file_name = dir.get_next()
	dir.list_dir_end()
	return result


# =========================
# DELETE
# =========================

## Deletes a full save file.
func delete_save(save_name: String) -> bool:
	var path = SAVE_DIR + save_name + ".save.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		return true
	return false


## Deletes a sector file.
func delete_sector(sector_name: String) -> bool:
	# Wipe campaign-level pools for this sector too — otherwise an abandon
	# leaves the on-disk file gone but the accrued offline-production
	# stockpile (and rates / timestamps / fractions / caps) lingers in the
	# campaign save, and a relaunch hands it back to the player on landing.
	var sid: StringName = StringName(sector_name)
	# If this sector was captured, leave a breadcrumb so planet-select can
	# render its outline in white ("abandoned") instead of gold ("captured")
	# or green ("unlocked, never captured"). Re-capturing clears the flag.
	if TechTree.is_sector_captured(sid):
		TechTree.mark_sector_abandoned(sid)
	sector_resources.erase(sid)
	sector_production_rates.erase(sid)
	sector_production_timestamps.erase(sid)
	_sector_production_fractions.erase(sid)
	sector_storage_caps.erase(sid)
	# Persist the cleared pools so a crash before the next save doesn't
	# resurrect them from the previous campaign.json.
	save_campaign()
	var path = SAVE_DIR + sector_name + ".sector.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		return true
	return false


# =========================
# SAVE: SECTOR (tiles + buildings + factions)
# =========================

## Saves terrain + pre-placed buildings with factions (no resources/drone/health).
func save_sector(sector_name: String) -> bool:
	var main = get_node_or_null("/root/Main")
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	if main == null or terrain == null:
		push_warning("SaveManager: Can't find Main or TerrainSystem!")
		return false

	# Links live on main.linked_pairs in the editor, PowerSystem.linked_pairs in gameplay
	var links: Array = []
	if main.get("linked_pairs") != null:
		links = main.linked_pairs
	else:
		var power_sys = get_node_or_null("/root/Main/PowerSystem")
		if power_sys and power_sys.get("linked_pairs") != null:
			links = power_sys.linked_pairs

	# Save drone position
	var drone = get_node_or_null("/root/Main/PlayerDrone")
	var drone_pos := ""
	if drone:
		drone_pos = "%d,%d" % [int(drone.position.x), int(drone.position.y)]

	# Save resources
	var res_save := {}
	for item_id in main.resources:
		if main.resources[item_id] > 0:
			res_save[str(item_id)] = main.resources[item_id]

	# Save build progress & order (only in gameplay, not map editor)
	var build_progress_save := {}
	var build_order_save: Array = []
	var work_order_save: Array = []
	var resources_consumed_save := {}
	var resources_refunded_save := {}
	if "building_build_progress" in main:
		for anchor in main.building_build_progress:
			build_progress_save[_vec2i_to_str(anchor)] = main.building_build_progress[anchor]
	if "build_order" in main:
		for anchor in main.build_order:
			build_order_save.append(_vec2i_to_str(anchor))
	if "work_order" in main:
		for anchor in main.work_order:
			work_order_save.append(_vec2i_to_str(anchor))
	if "building_resources_consumed" in main:
		for anchor in main.building_resources_consumed:
			var inner := {}
			for rk in main.building_resources_consumed[anchor]:
				inner[str(rk)] = int(main.building_resources_consumed[anchor][rk])
			resources_consumed_save[_vec2i_to_str(anchor)] = inner
	if "building_resources_refunded" in main:
		for anchor in main.building_resources_refunded:
			var inner := {}
			for rk in main.building_resources_refunded[anchor]:
				inner[str(rk)] = int(main.building_resources_refunded[anchor][rk])
			resources_refunded_save[_vec2i_to_str(anchor)] = inner

	# Save player units
	var units_save: Array = []
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if unit_mgr:
		for unit in unit_mgr.player_units:
			if unit and is_instance_valid(unit) and unit.data:
				units_save.append({
					"unit_id": str(unit.data.id),
					"x": unit.position.x,
					"y": unit.position.y,
					"health": unit.health,
				})

	# Save logistics state (block storage, conveyor items, factory buffers)
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	var block_storage_save := {}
	var conveyor_items_save := {}
	var factory_buffers_save := {}
	if logistics:
		for origin in logistics.block_storage:
			var storage = logistics.block_storage[origin]
			var items_dict := {}
			for k in storage["items"]:
				items_dict[str(k)] = storage["items"][k]
			var fluids_dict := {}
			for k in storage["fluids"]:
				fluids_dict[str(k)] = storage["fluids"][k]
			if not items_dict.is_empty() or not fluids_dict.is_empty():
				block_storage_save[_vec2i_to_str(origin)] = {"items": items_dict, "fluids": fluids_dict}
		for pos in logistics.conveyor_items:
			var entry = logistics.conveyor_items[pos]
			conveyor_items_save[_vec2i_to_str(pos)] = {
				"item_id": str(entry["item_id"]),
				"progress": entry["progress"],
				"entry_dir": entry.get("entry_dir", -1),
			}
		for origin in logistics.factory_buffers:
			var state = logistics.factory_buffers[origin]
			var inputs_dict := {}
			for k in state["inputs"]:
				inputs_dict[str(k)] = state["inputs"][k]
			var save_entry := {
				"inputs": inputs_dict,
				"phase": state["phase"],
				"timer": state["timer"],
			}
			# Persist ejection/holding bookkeeping so a unit fabricator
			# that was mid-eject or waiting on a blocked output resumes
			# cleanly after a reload instead of stalling with no payload.
			if state.has("eject_progress"):
				save_entry["eject_progress"] = state["eject_progress"]
			if state.get("held_payload") != null:
				var hp: Dictionary = state["held_payload"]
				var hp_save := {}
				for k in hp:
					hp_save[str(k)] = hp[k]
				save_entry["held_payload"] = hp_save
			factory_buffers_save[_vec2i_to_str(origin)] = save_entry

	# Save payload transport state
	var payload_items_save := {}
	var constructor_state_save := {}
	var deconstructor_state_save := {}
	var loader_state_save := {}
	var unloader_state_save := {}
	var refabricator_state_save := {}
	if logistics:
		if "payload_items" in logistics:
			for pos in logistics.payload_items:
				var entry = logistics.payload_items[pos]
				var pd = entry.get("payload_data", {})
				var pd_save := {}
				for k in pd:
					if k == "stored_items" or k == "stored_fluids":
						var inner := {}
						for ik in pd[k]:
							inner[str(ik)] = pd[k][ik]
						pd_save[str(k)] = inner
					else:
						pd_save[str(k)] = pd[k]
				payload_items_save[_vec2i_to_str(pos)] = {
					"payload_data": pd_save,
					"progress": entry.get("progress", 0.0),
					"entry_dir": entry.get("entry_dir", -1),
				}
		# Refabricator state: phase + in/out unit ids + processing timer.
		# Without this the refab resets to idle on every reload, losing any
		# unit that was mid-process, and a refab that was stuck in
		# "outputting" (output blocked downstream) wouldn't be recoverable
		# without re-feeding it from scratch.
		if "refabricator_state" in logistics:
			for pos in logistics.refabricator_state:
				var rs: Dictionary = logistics.refabricator_state[pos]
				refabricator_state_save[_vec2i_to_str(pos)] = {
					"phase": String(rs.get("phase", "idle")),
					"in_unit_id": String(rs.get("in_unit_id", &"")),
					"out_unit_id": String(rs.get("out_unit_id", &"")),
					"timer": float(rs.get("timer", 0.0)),
					"selected_t2": String(rs.get("selected_t2", &"")),
				}
		if "constructor_state" in logistics:
			for pos in logistics.constructor_state:
				var state = logistics.constructor_state[pos]
				var collected_save := {}
				for k in state.get("collected", {}):
					collected_save[str(k)] = state["collected"][k]
				constructor_state_save[_vec2i_to_str(pos)] = {
					"selected_block": str(state.get("selected_block", &"")),
					"collected": collected_save,
					"phase": str(state.get("phase", "idle")),
					"timer": state.get("timer", 0.0),
				}
	# Editor mode (no LogisticsSystem): fall back to BuildingSystem's
	# authored-selection dicts so selections made in the map editor
	# survive into the sector .json.
	if building_sys:
		if refabricator_state_save.is_empty() and "editor_refabricator_state" in building_sys:
			for pos in building_sys.editor_refabricator_state:
				var rs_e: Dictionary = building_sys.editor_refabricator_state[pos]
				refabricator_state_save[_vec2i_to_str(pos)] = {
					"phase": "idle",
					"in_unit_id": "",
					"out_unit_id": "",
					"timer": 0.0,
					"selected_t2": String(rs_e.get("selected_t2", &"")),
				}
		if constructor_state_save.is_empty() and "editor_constructor_state" in building_sys:
			for pos in building_sys.editor_constructor_state:
				var cs_e: Dictionary = building_sys.editor_constructor_state[pos]
				constructor_state_save[_vec2i_to_str(pos)] = {
					"selected_block": str(cs_e.get("selected_block", &"")),
					"collected": {},
					"phase": "idle",
					"timer": 0.0,
				}
	if logistics:
		if "deconstructor_state" in logistics:
			for pos in logistics.deconstructor_state:
				var state = logistics.deconstructor_state[pos]
				var payload_save = null
				if state.get("payload") != null:
					payload_save = {}
					for k in state["payload"]:
						payload_save[str(k)] = state["payload"][k]
				var pending_save := {}
				for k in state.get("pending_items", {}):
					pending_save[str(k)] = state["pending_items"][k]
				deconstructor_state_save[_vec2i_to_str(pos)] = {
					"payload": payload_save,
					"phase": str(state.get("phase", "idle")),
					"timer": state.get("timer", 0.0),
					"pending_items": pending_save,
				}
		if "loader_state" in logistics:
			for pos in logistics.loader_state:
				var state = logistics.loader_state[pos]
				var payload_save = null
				if state.get("payload") != null:
					payload_save = {}
					for k in state["payload"]:
						payload_save[str(k)] = state["payload"][k]
				loader_state_save[_vec2i_to_str(pos)] = {
					"payload": payload_save,
					"phase": str(state.get("phase", "idle")),
				}
		if "unloader_state" in logistics:
			for pos in logistics.unloader_state:
				var state = logistics.unloader_state[pos]
				var payload_save = null
				if state.get("payload") != null:
					payload_save = {}
					for k in state["payload"]:
						payload_save[str(k)] = state["payload"][k]
				unloader_state_save[_vec2i_to_str(pos)] = {
					"payload": payload_save,
					"phase": str(state.get("phase", "idle")),
				}

	# Save crane states from BuildingSystem
	var crane_states_save := {}
	if building_sys and "crane_states" in building_sys:
		for pos in building_sys.crane_states:
			var cs = building_sys.crane_states[pos]
			var held_save = null
			if cs.get("held_payload") != null:
				held_save = {}
				for k in cs["held_payload"]:
					held_save[str(k)] = cs["held_payload"][k]
			var _tp = cs.get("target_pos")
			crane_states_save[_vec2i_to_str(pos)] = {
				"arm_angle": cs.get("arm_angle", 0.0),
				"arm_extension": cs.get("arm_extension", 20.0),
				"grabber_open": cs.get("grabber_open", true),
				"held_payload": held_save,
			}

	var data := {
		"version": 3,
		"type": "sector",
		"sector_name": sector_name,
		"grid_width": main.GRID_WIDTH,
		"grid_height": main.GRID_HEIGHT,
		"floor_tiles": _serialize_tiles(terrain.floor_tiles),
		"wall_tiles": _serialize_tiles(terrain.wall_tiles),
		"ore_tiles": _serialize_tiles(terrain.ore_tiles),
		"core_position": _vec2i_to_str(main.core_position),
		"buildings": _serialize_buildings(main.placed_buildings),
		"building_rotation": _serialize_rotation(main.building_rotation),
		"building_factions": _serialize_factions(main.building_factions),
		"building_health": _serialize_health(main.building_health),
		"linked_pairs": _serialize_links(links),
		"sorter_filters": _serialize_sorter_filters(),
		"script_steps": _serialize_script_steps(),
		"hints": _serialize_hints(),
		"resources": res_save,
		"drone_position": drone_pos,
		"build_progress": build_progress_save,
		"build_order": build_order_save,
		"work_order": work_order_save,
		"building_resources_consumed": resources_consumed_save,
		"building_resources_refunded": resources_refunded_save,
		"player_units": units_save,
		"block_storage": block_storage_save,
		"conveyor_items": conveyor_items_save,
		"factory_buffers": factory_buffers_save,
		"payload_items": payload_items_save,
		"constructor_state": constructor_state_save,
		"refabricator_state": refabricator_state_save,
		"deconstructor_state": deconstructor_state_save,
		"loader_state": loader_state_save,
		"unloader_state": unloader_state_save,
		"crane_states": crane_states_save,
		"archive_holdings": _serialize_archive_holdings(),
		"archive_decoder_state": _serialize_archive_decoder_state(),
	}

	# Save script runtime state if sector script exists
	var sector_script = get_node_or_null("/root/Main/SectorScript")
	if sector_script and sector_script.has_method("get_runtime_state"):
		data["script_runtime"] = sector_script.get_runtime_state()
	if sector_script and sector_script.has_method("get_hints_runtime_state"):
		data["hints_runtime"] = sector_script.get_hints_runtime_state()

	# Authored enemy-wave bundle: global config + spawn points + either
	# manual waves or an auto-generation template set. Pull from the
	# live WaveManager in-game, or from the editor's staging fields in
	# map-editor mode.
	var wm_script = preload("res://main/wave_manager.gd")
	var wm_live = get_node_or_null("/root/Main/WaveManager")
	var cfg_src: Dictionary = {}
	var spawns_src: Array = []
	var waves_src: Array = []
	if wm_live and wm_live.get("config") != null:
		cfg_src = wm_live.config
		spawns_src = wm_live.spawn_points
		waves_src = wm_live.waves
	elif main.get("editor_wave_config") != null:
		cfg_src = main.editor_wave_config
		spawns_src = main.editor_wave_spawns
		waves_src = main.editor_waves
	if not cfg_src.is_empty() or not spawns_src.is_empty() or not waves_src.is_empty():
		data["waves_bundle"] = wm_script.serialize_all(cfg_src, spawns_src, waves_src)

	# Compute offline defense simulation (time before sector falls)
	var sim_result = SectorDefenseSim.calculate_time_to_fall(main)
	data["defense_sim"] = {
		"time_to_fall": sim_result.time_to_fall if sim_result.time_to_fall != INF else -1.0,
		"is_stable": sim_result.is_stable,
		"summary": sim_result.summary,
		"timestamp": Time.get_unix_time_from_system(),
	}

	# Capture production rate so the sector keeps earning items while the
	# player is on the planet menu / in another sector / the game is closed.
	capture_production_snapshot(StringName(sector_name), main)

	return _write_json(SAVE_DIR + sector_name + ".sector.json", data)


# =========================
# LOAD: SECTOR FROM PATH
# =========================

## Loads a sector from an arbitrary file path. Loads terrain + pre-placed buildings
## with factions. Health is rebuilt from BlockData, building_origins from grid_size.
func load_sector_from_path(path: String) -> bool:
	var main = get_node_or_null("/root/Main")
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if main == null or terrain == null:
		push_warning("SaveManager: Can't find Main or TerrainSystem!")
		return false

	var data = _read_json(path)
	if data == null:
		return false

	# --- Clear everything ---
	terrain.floor_tiles.clear()
	terrain.wall_tiles.clear()
	terrain.ore_tiles.clear()
	terrain.tile_health.clear()
	terrain.multi_tile_origins.clear()
	main.placed_buildings.clear()
	main.building_health.clear()
	main.building_rotation.clear()
	main.building_origins.clear()
	main.building_factions.clear()
	var power_sys = get_node_or_null("/root/Main/PowerSystem")
	if main.get("linked_pairs") != null:
		main.linked_pairs.clear()
	if power_sys and power_sys.get("linked_pairs") != null:
		power_sys.linked_pairs.clear()

	# --- Restore map size ---
	if data.has("grid_width"):
		main.GRID_WIDTH = int(data["grid_width"])
	if data.has("grid_height"):
		main.GRID_HEIGHT = int(data["grid_height"])

	# --- Load terrain ---
	_deserialize_layer(terrain.floor_tiles, data.get("floor_tiles", {}))
	_deserialize_layer(terrain.wall_tiles, data.get("wall_tiles", {}))
	_deserialize_layer(terrain.ore_tiles, data.get("ore_tiles", {}))
	_rebuild_multi_tile_origins(terrain)

	if data.has("core_position"):
		main.core_position = _str_to_vec2i(data["core_position"])

	# --- Load buildings ---
	_deserialize_buildings(main, data.get("buildings", {}))
	_deserialize_building_rotation(main, data.get("building_rotation", {}))
	_deserialize_building_factions(main, data.get("building_factions", {}))

	# --- Load links ---
	var links_data = data.get("linked_pairs", [])
	if links_data.size() > 0:
		if main.get("linked_pairs") != null:
			_deserialize_links(main, links_data)
		elif power_sys and power_sys.get("linked_pairs") != null:
			_deserialize_links_to(power_sys.linked_pairs, links_data)
			power_sys._networks_dirty = true

	# --- Load sorter filters ---
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	var building_sys_early = get_node_or_null("/root/Main/BuildingSystem")
	var sf_data = data.get("sorter_filters", {})
	if logistics:
		logistics.sorter_filters.clear()
		for key in sf_data:
			logistics.sorter_filters[_str_to_vec2i(key)] = StringName(sf_data[key])
	elif building_sys_early and "editor_sorter_filters" in building_sys_early:
		building_sys_early.editor_sorter_filters.clear()
		for key in sf_data:
			building_sys_early.editor_sorter_filters[_str_to_vec2i(key)] = StringName(sf_data[key])
	# Editor-mode constructor/refab state. In-game these are restored
	# later in this function from the same data dict into the live
	# LogisticsSystem; for the editor we mirror them into BuildingSystem
	# so menus show the right selection on re-open.
	if logistics == null and building_sys_early:
		if "editor_constructor_state" in building_sys_early:
			building_sys_early.editor_constructor_state.clear()
			var cs_data = data.get("constructor_state", {})
			for key in cs_data:
				var raw = cs_data[key]
				var sel: StringName = StringName(raw.get("selected_block", "")) if raw is Dictionary else &""
				building_sys_early.editor_constructor_state[_str_to_vec2i(key)] = {"selected_block": sel}
		if "editor_refabricator_state" in building_sys_early:
			building_sys_early.editor_refabricator_state.clear()
			var rs_data = data.get("refabricator_state", {})
			for key in rs_data:
				var raw = rs_data[key]
				var sel2: StringName = StringName(raw.get("selected_t2", "")) if raw is Dictionary else &""
				building_sys_early.editor_refabricator_state[_str_to_vec2i(key)] = {"selected_t2": sel2}

	# --- Load hints ---
	var hints_data = data.get("hints", [])
	print("SaveManager: loading %d hint(s) from %s" % [hints_data.size() if hints_data is Array else -1, path])
	if hints_data is Array:
		var se_h = main.get("script_editor")
		if se_h and se_h.has_method("set_hints_data"):
			se_h.set_hints_data(hints_data)
		var sector_script_h = get_node_or_null("/root/Main/SectorScript")
		if sector_script_h and sector_script_h.has_method("load_hints"):
			sector_script_h.load_hints(hints_data)
			print("SaveManager: SectorScript now has %d hints" % sector_script_h._hints.size())
			var is_user_save_h: bool = path.begins_with(SAVE_DIR) or path.begins_with("user://")
			if is_user_save_h and data.has("hints_runtime") and data["hints_runtime"] is Dictionary \
					and sector_script_h.has_method("load_hints_runtime_state"):
				sector_script_h.call_deferred("load_hints_runtime_state", data["hints_runtime"])

	# --- Load script steps ---
	var script_steps_data = data.get("script_steps", [])
	if script_steps_data.size() > 0:
		# In the editor: load into script_editor
		_deserialize_script_steps(main, script_steps_data)
		# In gameplay: load into SectorScript
		var sector_script = get_node_or_null("/root/Main/SectorScript")
		if sector_script and sector_script.has_method("load_script_steps"):
			sector_script.load_script_steps(script_steps_data)
			# Only restore runtime state when loading a USER autosave
			# (under user://maps/). Bundled map_paths (res://…) can ship
			# with a `script_runtime` block baked in from whatever state
			# the map editor was in at save-time — restoring that on a
			# fresh launch would make the script think it had already
			# run, so an abandoned-and-re-launched sector never re-arms
			# its steps. Treat bundled loads as always-fresh.
			var is_user_autosave: bool = path.begins_with(SAVE_DIR) \
				or path.begins_with("user://")
			if is_user_autosave \
					and data.has("script_runtime") \
					and data["script_runtime"] is Dictionary:
				sector_script.call_deferred("load_runtime_state", data["script_runtime"])
			else:
				sector_script.call_deferred("start_script")

	# --- Load authored wave bundle into WaveManager (gameplay) or onto
	# the editor's staging fields (map editor). Fresh/empty bundle
	# clears any inherited wave data.
	var wm_script_l = preload("res://main/wave_manager.gd")
	var bundle_raw = data.get("waves_bundle", {})
	var bundle: Dictionary = wm_script_l.deserialize_all(bundle_raw)
	var wave_mgr_l = get_node_or_null("/root/Main/WaveManager")
	if wave_mgr_l:
		wave_mgr_l.config = bundle.get("config", {})
		wave_mgr_l.spawn_points = bundle.get("spawn_points", [])
		wave_mgr_l.waves = bundle.get("waves", [])
		# Only auto-start when the authored config says "on landing";
		# script-triggered runs wait for a sector-script start_waves
		# action. `start()` itself also honors the start_mode flag so
		# calling it is always safe — included for backwards compat
		# with the previous call site.
		if String(wave_mgr_l.config.get("start_mode", "landing")) == "landing":
			if wave_mgr_l.has_method("start"):
				wave_mgr_l.call_deferred("start")
	elif main.get("editor_wave_config") != null:
		main.editor_wave_config = bundle.get("config", {})
		main.editor_wave_spawns = bundle.get("spawn_points", [])
		main.editor_waves = bundle.get("waves", [])

	# --- Restore building health (use saved values if present, else max_health) ---
	if data.has("building_health") and data["building_health"] is Dictionary:
		_deserialize_building_health(main, data["building_health"])
	else:
		for grid_pos in main.placed_buildings:
			var block_data = Registry.get_block(main.placed_buildings[grid_pos])
			if block_data:
				main.building_health[grid_pos] = block_data.max_health

	# --- Rebuild building_origins from grid_size ---
	_rebuild_building_origins(main)

	# --- Restore resources (if saved, e.g. from autosave) ---
	# Bundled res:// sectors can ship with a `resources` block baked in
	# from playtest/authoring; applying it on a fresh landing would gift
	# the player a stockpile they didn't earn. Only user autosaves under
	# user://maps/ restore the saved stockpile — bundled loads start clean.
	var is_user_save_res: bool = path.begins_with(SAVE_DIR) or path.begins_with("user://")
	if is_user_save_res and data.has("resources") and data["resources"] is Dictionary:
		for item_id in data["resources"]:
			main.resources[StringName(item_id)] = int(data["resources"][item_id])

	# --- Restore drone position ---
	if data.has("drone_position") and data["drone_position"] != "":
		var drone = get_node_or_null("/root/Main/PlayerDrone")
		if drone:
			var parts = str(data["drone_position"]).split(",")
			if parts.size() >= 2:
				drone.position = Vector2(float(parts[0].strip_edges()), float(parts[1].strip_edges()))
				if "_drone_position_restored" in main:
					main._drone_position_restored = true

	# --- Restore build progress & order ---
	if "building_build_progress" in main:
		main.building_build_progress.clear()
		if data.has("build_progress") and data["build_progress"] is Dictionary:
			for key in data["build_progress"]:
				main.building_build_progress[_str_to_vec2i(key)] = float(data["build_progress"][key])
	if "build_order" in main:
		main.build_order.clear()
		if data.has("build_order") and data["build_order"] is Array:
			for entry in data["build_order"]:
				main.build_order.append(_str_to_vec2i(str(entry)))

	# --- Restore unified work queue (new format) ---
	if "work_order" in main:
		main.work_order.clear()
		if data.has("work_order") and data["work_order"] is Array:
			for entry in data["work_order"]:
				main.work_order.append(_str_to_vec2i(str(entry)))
		elif not main.build_order.is_empty():
			# Migrate old build_order into work_order
			for anchor in main.build_order:
				main.work_order.append(anchor)
	if "building_resources_consumed" in main:
		main.building_resources_consumed.clear()
		if data.has("building_resources_consumed") and data["building_resources_consumed"] is Dictionary:
			for key in data["building_resources_consumed"]:
				var inner := {}
				for rk in data["building_resources_consumed"][key]:
					inner[StringName(rk)] = int(data["building_resources_consumed"][key][rk])
				main.building_resources_consumed[_str_to_vec2i(key)] = inner
		else:
			# Old save: assume all resources were consumed (old system deducted up front)
			for anchor in main.building_build_progress:
				var block_id = main.placed_buildings.get(anchor, &"")
				var bdata = Registry.get_block(block_id)
				if bdata:
					var consumed := {}
					for item_id in bdata.build_cost:
						var rk: StringName = main._resolve_resource_key(str(item_id))
						consumed[rk] = int(bdata.build_cost[item_id])
					main.building_resources_consumed[anchor] = consumed
	if "building_resources_refunded" in main:
		main.building_resources_refunded.clear()
		if data.has("building_resources_refunded") and data["building_resources_refunded"] is Dictionary:
			for key in data["building_resources_refunded"]:
				var inner := {}
				for rk in data["building_resources_refunded"][key]:
					inner[StringName(rk)] = int(data["building_resources_refunded"][key][rk])
				main.building_resources_refunded[_str_to_vec2i(key)] = inner

	# --- Rebuild pathfinding ---
	# Both the main-thread astar AND the threaded path_worker need a
	# fresh solids list — the worker was started at unit_manager._ready
	# with whatever terrain existed at that moment (often empty, before
	# the sector load populated walls / floor tiles), so leaving it
	# stale causes async paths to walk right across walls into void.
	if unit_mgr:
		unit_mgr._setup_astar()
		unit_mgr._setup_path_worker()

	# --- Restore player units ---
	if unit_mgr and data.has("player_units") and data["player_units"] is Array:
		for unit_entry in data["player_units"]:
			var uid: StringName = StringName(unit_entry.get("unit_id", ""))
			var ux: float = float(unit_entry.get("x", 0))
			var uy: float = float(unit_entry.get("y", 0))
			var uhp: float = float(unit_entry.get("health", -1))
			if uid != &"":
				unit_mgr.spawn_player_unit(Vector2(ux, uy), uid)
				if uhp >= 0 and not unit_mgr.player_units.is_empty():
					var spawned = unit_mgr.player_units[-1]
					if spawned and is_instance_valid(spawned):
						spawned.health = uhp

	# --- Restore logistics state (block storage, conveyor items, factory buffers) ---
	var load_logistics = get_node_or_null("/root/Main/LogisticsSystem")
	if load_logistics:
		if data.has("block_storage") and data["block_storage"] is Dictionary:
			load_logistics.block_storage.clear()
			for key in data["block_storage"]:
				var origin: Vector2i = _str_to_vec2i(key)
				var saved = data["block_storage"][key]
				var items_dict := {}
				for k in saved.get("items", {}):
					items_dict[StringName(k)] = int(saved["items"][k])
				var fluids_dict := {}
				for k in saved.get("fluids", {}):
					fluids_dict[StringName(k)] = float(saved["fluids"][k])
				load_logistics.block_storage[origin] = {"items": items_dict, "fluids": fluids_dict}
		if data.has("conveyor_items") and data["conveyor_items"] is Dictionary:
			load_logistics.conveyor_items.clear()
			for key in data["conveyor_items"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["conveyor_items"][key]
				load_logistics.conveyor_items[pos] = {
					"item_id": StringName(saved.get("item_id", "")),
					"progress": float(saved.get("progress", 0.0)),
					"entry_dir": int(saved.get("entry_dir", -1)),
				}
		if data.has("factory_buffers") and data["factory_buffers"] is Dictionary:
			load_logistics.factory_buffers.clear()
			for key in data["factory_buffers"]:
				var origin: Vector2i = _str_to_vec2i(key)
				var saved = data["factory_buffers"][key]
				var inputs_dict := {}
				for k in saved.get("inputs", {}):
					inputs_dict[StringName(k)] = int(saved["inputs"][k])
				var entry: Dictionary = {
					"inputs": inputs_dict,
					"phase": str(saved.get("phase", "collecting")),
					"timer": float(saved.get("timer", 0.0)),
					"pending_outputs": {},
				}
				if saved.has("eject_progress"):
					entry["eject_progress"] = float(saved["eject_progress"])
				if saved.has("held_payload") and saved["held_payload"] is Dictionary:
					# held_payload uses plain string keys (see fabricator
					# ejection code: {"type": "unit", "unit_id": ...}).
					var hp_raw: Dictionary = saved["held_payload"]
					var hp := {}
					for k in hp_raw:
						hp[str(k)] = hp_raw[k]
					entry["held_payload"] = hp
				load_logistics.factory_buffers[origin] = entry

		# --- Restore payload transport state ---
		if "payload_items" in load_logistics and data.has("payload_items") and data["payload_items"] is Dictionary:
			load_logistics.payload_items.clear()
			for key in data["payload_items"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["payload_items"][key]
				var pd_raw = saved.get("payload_data", {})
				var pd := {}
				for k in pd_raw:
					if k == "stored_items" or k == "stored_fluids":
						var inner := {}
						for ik in pd_raw[k]:
							inner[StringName(ik)] = pd_raw[k][ik]
						pd[k] = inner
					else:
						pd[k] = pd_raw[k]
				load_logistics.payload_items[pos] = {
					"payload_data": pd,
					"progress": float(saved.get("progress", 0.0)),
					"entry_dir": int(saved.get("entry_dir", -1)),
				}
		if "refabricator_state" in load_logistics and data.has("refabricator_state") and data["refabricator_state"] is Dictionary:
			load_logistics.refabricator_state.clear()
			for key in data["refabricator_state"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["refabricator_state"][key]
				load_logistics.refabricator_state[pos] = {
					"phase": String(saved.get("phase", "idle")),
					"in_unit_id": StringName(saved.get("in_unit_id", "")),
					"out_unit_id": StringName(saved.get("out_unit_id", "")),
					"timer": float(saved.get("timer", 0.0)),
					"selected_t2": StringName(saved.get("selected_t2", "")),
				}
		if "constructor_state" in load_logistics and data.has("constructor_state") and data["constructor_state"] is Dictionary:
			load_logistics.constructor_state.clear()
			for key in data["constructor_state"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["constructor_state"][key]
				var collected := {}
				for k in saved.get("collected", {}):
					collected[StringName(k)] = int(saved["collected"][k])
				load_logistics.constructor_state[pos] = {
					"selected_block": StringName(saved.get("selected_block", "")),
					"collected": collected,
					"phase": str(saved.get("phase", "idle")),
					"timer": float(saved.get("timer", 0.0)),
				}
		if "deconstructor_state" in load_logistics and data.has("deconstructor_state") and data["deconstructor_state"] is Dictionary:
			load_logistics.deconstructor_state.clear()
			for key in data["deconstructor_state"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["deconstructor_state"][key]
				var payload = null
				if saved.get("payload") != null:
					payload = {}
					for k in saved["payload"]:
						payload[StringName(k)] = saved["payload"][k]
				var pending := {}
				for k in saved.get("pending_items", {}):
					pending[StringName(k)] = int(saved["pending_items"][k])
				load_logistics.deconstructor_state[pos] = {
					"payload": payload,
					"phase": str(saved.get("phase", "idle")),
					"timer": float(saved.get("timer", 0.0)),
					"pending_items": pending,
				}
		if "loader_state" in load_logistics and data.has("loader_state") and data["loader_state"] is Dictionary:
			load_logistics.loader_state.clear()
			for key in data["loader_state"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["loader_state"][key]
				var payload = null
				if saved.get("payload") != null:
					payload = {}
					for k in saved["payload"]:
						payload[StringName(k)] = saved["payload"][k]
				load_logistics.loader_state[pos] = {
					"payload": payload,
					"phase": str(saved.get("phase", "idle")),
				}
		if "unloader_state" in load_logistics and data.has("unloader_state") and data["unloader_state"] is Dictionary:
			load_logistics.unloader_state.clear()
			for key in data["unloader_state"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["unloader_state"][key]
				var payload = null
				if saved.get("payload") != null:
					payload = {}
					for k in saved["payload"]:
						payload[StringName(k)] = saved["payload"][k]
				load_logistics.unloader_state[pos] = {
					"payload": payload,
					"phase": str(saved.get("phase", "idle")),
				}

	# --- Restore crane states ---
	if building_sys and "crane_states" in building_sys and data.has("crane_states") and data["crane_states"] is Dictionary:
		building_sys.crane_states.clear()
		for key in data["crane_states"]:
			var pos: Vector2i = _str_to_vec2i(key)
			var saved = data["crane_states"][key]
			var held = null
			if saved.get("held_payload") != null:
				held = {}
				for k in saved["held_payload"]:
					held[StringName(k)] = saved["held_payload"][k]
			building_sys.crane_states[pos] = {
				"arm_angle": float(saved.get("arm_angle", -PI / 2.0)),
				"arm_extension": float(saved.get("arm_extension", 20.0)),
				"grabber_open": bool(saved.get("grabber_open", true)),
				"held_payload": held,
				"target_pos": Vector2.ZERO,
			}

	# --- Restore archive holdings ---
	if building_sys and "archive_holdings" in building_sys and data.has("archive_holdings") and data["archive_holdings"] is Dictionary:
		building_sys.archive_holdings.clear()
		for key in data["archive_holdings"]:
			building_sys.archive_holdings[_str_to_vec2i(key)] = StringName(data["archive_holdings"][key])

	# --- Restore archive decoder state ---
	if building_sys and "archive_decoder_state" in building_sys and data.has("archive_decoder_state") and data["archive_decoder_state"] is Dictionary:
		building_sys.archive_decoder_state.clear()
		for key in data["archive_decoder_state"]:
			var saved_a = data["archive_decoder_state"][key]
			building_sys.archive_decoder_state[_str_to_vec2i(key)] = {
				"progress": float(saved_a.get("progress", 0.0)),
				"archive_id": StringName(saved_a.get("archive_id", "")),
				"scanner": Vector2i(-9999, -9999),
			}

	# --- Redraw ---
	# Bulk-loaded terrain bypassed the `place_tile` dirty hooks, so any
	# rebuild triggered between map-clear and now ran against an empty
	# floor_tiles set and latched _water_depth_dirty / _floor_edge_dirty
	# to false. Re-arm them so the next draw pass actually bakes the
	# gradient meshes against the real tile set.
	terrain._water_depth_dirty = true
	terrain._floor_edge_dirty = true
	terrain.walls_changed.emit()
	terrain.queue_redraw()
	if building_sys:
		building_sys.queue_redraw()

	var total_tiles: int = terrain.floor_tiles.size() + terrain.wall_tiles.size() + terrain.ore_tiles.size()
	print("SaveManager: Sector loaded from '%s' (%d tiles, %d building cells, %d player units)" % [
		path, total_tiles, main.placed_buildings.size(),
		data.get("player_units", []).size() if data.has("player_units") else 0
	])
	return true


## Loads a sector from user://maps/ by name.
func load_sector(sector_name: String) -> bool:
	return load_sector_from_path(SAVE_DIR + sector_name + ".sector.json")


## Rebuilds multi_tile_origins for floor tiles (vents, geysers) after loading.
## Scans floor_tiles for any tile that TerrainSystem considers multi-tile (3x3),
## then populates multi_tile_origins so all 9 cells point back to the origin.
func _rebuild_multi_tile_origins(terrain: Node2D) -> void:
	terrain.multi_tile_origins.clear()
	var processed := {}
	# Cache _is_multi_tile(tile_id) per id so we stop re-entering Registry
	# for every floor cell (100x100 map × N floor types).
	var is_mt_cache := {}
	for grid_pos in terrain.floor_tiles:
		if processed.has(grid_pos):
			continue
		var tile_id: StringName = terrain.floor_tiles[grid_pos]
		var is_mt: bool
		if is_mt_cache.has(tile_id):
			is_mt = is_mt_cache[tile_id]
		else:
			is_mt = terrain._is_multi_tile(tile_id)
			is_mt_cache[tile_id] = is_mt
		if not is_mt:
			continue
		# This cell is the origin of a 3x3 multi-tile
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var cell: Vector2i = grid_pos + Vector2i(dx, dy)
				terrain.multi_tile_origins[cell] = grid_pos
				processed[cell] = true


## Rebuilds building_origins for all placed buildings by finding anchors.
## For 1x1 buildings, origin = self. For multi-tile, scans for the top-left cell.
func _rebuild_building_origins(main: Node2D) -> void:
	main.building_origins.clear()
	var processed := {}  # Track which cells we've already assigned origins

	for grid_pos in main.placed_buildings:
		if processed.has(grid_pos):
			continue

		var block_id = main.placed_buildings[grid_pos]
		var block_data = Registry.get_block(block_id)
		if block_data == null:
			main.building_origins[grid_pos] = grid_pos
			processed[grid_pos] = true
			continue

		if block_data.grid_size == Vector2i(1, 1):
			main.building_origins[grid_pos] = grid_pos
			processed[grid_pos] = true
			continue

		# Multi-tile: find origin by checking if grid_pos could be the anchor
		var origin := _find_anchor_for_cell(main, grid_pos, block_id, block_data)
		for x in range(block_data.grid_size.x):
			for y in range(block_data.grid_size.y):
				var cell = origin + Vector2i(x, y)
				main.building_origins[cell] = origin
				processed[cell] = true


## Finds the anchor (top-left cell) for a multi-tile building that includes grid_pos.
func _find_anchor_for_cell(main: Node2D, grid_pos: Vector2i, block_id: StringName, block_data: BlockData) -> Vector2i:
	for ox in range(block_data.grid_size.x):
		for oy in range(block_data.grid_size.y):
			var candidate = grid_pos - Vector2i(ox, oy)
			var valid = true
			for dx in range(block_data.grid_size.x):
				for dy in range(block_data.grid_size.y):
					if main.placed_buildings.get(candidate + Vector2i(dx, dy), &"") != block_id:
						valid = false
						break
				if not valid:
					break
			if valid:
				return candidate
	return grid_pos


# =========================
# SERIALIZATION HELPERS
# =========================

# Converts Vector2i dictionary keys to strings for JSON.
# JSON only supports string keys, so Vector2i(5,10) becomes "5,10".

func _vec2i_to_str(v: Vector2i) -> String:
	return "%d,%d" % [v.x, v.y]

func _str_to_vec2i(s: String) -> Vector2i:
	var parts = s.split(",")
	return Vector2i(int(parts[0]), int(parts[1]))

func _vec2_to_array(v: Vector2) -> Array:
	return [v.x, v.y]


func _serialize_tiles(tiles: Dictionary) -> Dictionary:
	var result := {}
	for grid_pos in tiles:
		result[_vec2i_to_str(grid_pos)] = String(tiles[grid_pos])
	return result


func _serialize_buildings(buildings: Dictionary) -> Dictionary:
	var result := {}
	for grid_pos in buildings:
		result[_vec2i_to_str(grid_pos)] = String(buildings[grid_pos])
	return result


func _serialize_health(health_dict: Dictionary) -> Dictionary:
	var result := {}
	for grid_pos in health_dict:
		result[_vec2i_to_str(grid_pos)] = health_dict[grid_pos]
	return result


func _serialize_resources(resources: Dictionary) -> Dictionary:
	var result := {}
	for key in resources:
		result[String(key)] = resources[key]
	return result


func _serialize_rebuild_queue(queue: Array) -> Array:
	var result := []
	for entry in queue:
		result.append({
			"block_id": String(entry["block_id"]),
			"grid_pos": _vec2i_to_str(entry["grid_pos"]),
			"rotation": entry["rotation"],
		})
	return result


func _deserialize_rebuild_queue(arr: Array) -> Array:
	var result := []
	for entry in arr:
		result.append({
			"block_id": StringName(entry.get("block_id", "")),
			"grid_pos": _str_to_vec2i(entry.get("grid_pos", "0,0")),
			"rotation": int(entry.get("rotation", 0)),
		})
	return result


func _deserialize_tiles(terrain: Node2D, tiles_data: Dictionary) -> void:
	for pos_str in tiles_data:
		var grid_pos = _str_to_vec2i(pos_str)
		var tile_id = StringName(tiles_data[pos_str])
		terrain.placed_tiles[grid_pos] = tile_id

		# Set wall tiles as solid in pathfinding
		var data = Registry.get_tile(tile_id)
		if data and data.is_wall():
			var unit_mgr = get_node_or_null("/root/Main/UnitManager")
			if unit_mgr and unit_mgr.astar:
				unit_mgr.astar.set_point_solid(grid_pos, true)


## Deserializes a single tile layer dictionary from save data.
func _deserialize_layer(layer_dict: Dictionary, data: Dictionary) -> void:
	for pos_str in data:
		layer_dict[_str_to_vec2i(pos_str)] = StringName(data[pos_str])


## Deserializes v1 merged tiles into separate layers by looking up tile category.
func _deserialize_tiles_layered(terrain: Node2D, tiles_data: Dictionary) -> void:
	for pos_str in tiles_data:
		var grid_pos = _str_to_vec2i(pos_str)
		var tile_id = StringName(tiles_data[pos_str])
		var tile_data = Registry.get_tile(tile_id)
		if tile_data == null:
			continue
		if tile_data.is_ore():
			terrain.ore_tiles[grid_pos] = tile_id
		elif tile_data.is_wall():
			terrain.wall_tiles[grid_pos] = tile_id
		else:
			terrain.floor_tiles[grid_pos] = tile_id


func _deserialize_tile_health(terrain: Node2D, health_data: Dictionary) -> void:
	for pos_str in health_data:
		var grid_pos = _str_to_vec2i(pos_str)
		terrain.tile_health[grid_pos] = float(health_data[pos_str])


func _deserialize_buildings(main: Node2D, buildings_data: Dictionary) -> void:
	for pos_str in buildings_data:
		var grid_pos = _str_to_vec2i(pos_str)
		var block_id = StringName(buildings_data[pos_str])
		main.placed_buildings[grid_pos] = block_id


func _deserialize_building_health(main: Node2D, health_data: Dictionary) -> void:
	for pos_str in health_data:
		var grid_pos = _str_to_vec2i(pos_str)
		main.building_health[grid_pos] = float(health_data[pos_str])


func _serialize_rotation(rotation_dict: Dictionary) -> Dictionary:
	var result := {}
	for grid_pos in rotation_dict:
		result[_vec2i_to_str(grid_pos)] = rotation_dict[grid_pos]
	return result


func _deserialize_building_rotation(main: Node2D, rotation_data: Dictionary) -> void:
	for pos_str in rotation_data:
		var grid_pos = _str_to_vec2i(pos_str)
		main.building_rotation[grid_pos] = int(rotation_data[pos_str])


func _serialize_factions(factions: Dictionary) -> Dictionary:
	var result := {}
	for grid_pos in factions:
		result[_vec2i_to_str(grid_pos)] = factions[grid_pos]
	return result


func _deserialize_building_factions(main: Node2D, factions_data: Dictionary) -> void:
	for pos_str in factions_data:
		var grid_pos = _str_to_vec2i(pos_str)
		main.building_factions[grid_pos] = int(factions_data[pos_str])


func _serialize_archive_holdings() -> Dictionary:
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	if building_sys == null or not "archive_holdings" in building_sys:
		return {}
	var result := {}
	for grid_pos in building_sys.archive_holdings:
		result[_vec2i_to_str(grid_pos)] = String(building_sys.archive_holdings[grid_pos])
	return result


func _serialize_archive_decoder_state() -> Dictionary:
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	if building_sys == null or not "archive_decoder_state" in building_sys:
		return {}
	var result := {}
	for grid_pos in building_sys.archive_decoder_state:
		var s = building_sys.archive_decoder_state[grid_pos]
		result[_vec2i_to_str(grid_pos)] = {
			"progress": float(s.get("progress", 0.0)),
			"archive_id": String(s.get("archive_id", "")),
		}
	return result


func _serialize_sorter_filters() -> Dictionary:
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	var result := {}
	if logistics != null:
		for grid_pos in logistics.sorter_filters:
			var filter_id = logistics.sorter_filters[grid_pos]
			if filter_id != &"":
				result[_vec2i_to_str(grid_pos)] = String(filter_id)
		return result
	# Editor fallback: BuildingSystem.editor_sorter_filters
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	if building_sys and "editor_sorter_filters" in building_sys:
		for grid_pos in building_sys.editor_sorter_filters:
			var filter_id = building_sys.editor_sorter_filters[grid_pos]
			if filter_id != &"":
				result[_vec2i_to_str(grid_pos)] = String(filter_id)
	return result


func _serialize_links(linked_pairs: Array) -> Array:
	var result := []
	for pair in linked_pairs:
		result.append([_vec2i_to_str(pair[0]), _vec2i_to_str(pair[1])])
	return result


func _deserialize_links(main: Node2D, links_data: Array) -> void:
	for pair in links_data:
		if pair is Array and pair.size() == 2:
			main.linked_pairs.append([_str_to_vec2i(pair[0]), _str_to_vec2i(pair[1])])


func _deserialize_links_to(target_array: Array, links_data: Array) -> void:
	for pair in links_data:
		if pair is Array and pair.size() == 2:
			target_array.append([_str_to_vec2i(pair[0]), _str_to_vec2i(pair[1])])


func _serialize_script_steps() -> Array:
	# In gameplay: get steps from SectorScript
	var sector_script = get_node_or_null("/root/Main/SectorScript")
	if sector_script and sector_script.get("_script_steps") != null and not sector_script._script_steps.is_empty():
		return sector_script._script_steps.duplicate(true)
	# In editor: get steps from script_editor
	var main_node = get_node_or_null("/root/Main")
	if main_node == null:
		return []
	var se = main_node.get("script_editor")
	if se == null or not se.has_method("get_script_data"):
		return []
	return se.get_script_data()


func _deserialize_script_steps(main_node: Node2D, steps_data: Array) -> void:
	var se = main_node.get("script_editor")
	if se and se.has_method("set_script_data"):
		se.set_script_data(steps_data)


func _serialize_hints() -> Array:
	# Prefer in-game hints (live SectorScript) over editor staging.
	var sector_script = get_node_or_null("/root/Main/SectorScript")
	if sector_script and sector_script.has_method("get_hints"):
		var live: Array = sector_script.get_hints()
		if live.size() > 0:
			return live
	var main_node = get_node_or_null("/root/Main")
	if main_node == null:
		return []
	var se = main_node.get("script_editor")
	if se and se.has_method("get_hints_data"):
		return se.get_hints_data()
	return []


# =========================
# FILE I/O
# =========================

func _write_json(path: String, data: Dictionary) -> bool:
	# FileAccess.open() opens a file for reading or writing.
	# WRITE mode creates the file if it doesn't exist.
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("SaveManager: Could not open file for writing: " + path)
		return false

	# JSON.stringify() converts a Dictionary to a JSON string.
	# The second argument "\t" adds tab indentation for readability.
	var json_string = JSON.stringify(data, "\t")
	file.store_string(json_string)
	file.close()

	print("SaveManager: Saved to " + path)
	return true


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_warning("SaveManager: File not found: " + path)
		return null

	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("SaveManager: Could not open file: " + path)
		return null

	var json_string = file.get_as_text()
	file.close()

	# JSON.new() creates a parser, .parse() reads the string.
	var json = JSON.new()
	var error = json.parse(json_string)
	if error != OK:
		push_warning("SaveManager: JSON parse error: " + json.get_error_message())
		return null

	return json.data


# =========================
# GLOBAL RESOURCE POOL
# =========================

## Syncs the currently active sector's resources from Main.
## Call this before spending from the global pool while in-game.
func sync_active_sector_resources() -> void:
	var main = get_node_or_null("/root/Main")
	if main == null or not main.get("resources"):
		return
	if active_sector_id == &"":
		# No sector ID set — use a fallback key so resources are still accessible
		active_sector_id = &"_default"
	# Refresh the live cap every sync so placing/losing cores while
	# playing keeps the offline accrual ceiling accurate.
	if main.has_method("get_storage_cap_per_resource"):
		sector_storage_caps[active_sector_id] = int(main.get_storage_cap_per_resource())
	sector_resources[active_sector_id] = main.resources.duplicate()


## Returns the global resource pool: sum of all captured sectors' resources.
func get_global_resources() -> Dictionary:
	# Apply offline accrual so UIs that poll this see live-updating totals
	# while the player is on the planet menu.
	advance_offline_production()
	var pool: Dictionary = {}
	for sector_id in sector_resources:
		for item_id in sector_resources[sector_id]:
			pool[item_id] = pool.get(item_id, 0) + sector_resources[sector_id][item_id]
	return pool


## Takes up to `amount` of `item_id` from the global pool.
## Deducts from the sector with the most of that resource first.
## Returns the amount actually taken.
func take_from_global_pool(item_id: StringName, amount: int) -> int:
	if amount <= 0:
		return 0
	var remaining = amount

	# Collect sectors that have this item, sorted by amount descending
	var sectors_with_item: Array = []
	for sid in sector_resources:
		var amt: int = sector_resources[sid].get(item_id, 0)
		if amt > 0:
			sectors_with_item.append(sid)
	sectors_with_item.sort_custom(func(a, b):
		return sector_resources[a].get(item_id, 0) > sector_resources[b].get(item_id, 0)
	)

	for sid in sectors_with_item:
		if remaining <= 0:
			break
		var available: int = sector_resources[sid].get(item_id, 0)
		var to_take: int = mini(remaining, available)
		sector_resources[sid][item_id] -= to_take
		remaining -= to_take

	# If we deducted from the active sector, push changes back to Main
	if active_sector_id != &"" and sector_resources.has(active_sector_id):
		var main = get_node_or_null("/root/Main")
		if main and main.get("resources"):
			for key in sector_resources[active_sector_id]:
				main.resources[key] = sector_resources[active_sector_id][key]

	return amount - remaining


# =========================
# CAMPAIGN SAVE / LOAD
# =========================

## Saves campaign-level state: tech tree progress + per-sector resources.
func save_campaign() -> bool:
	var data := {
		"version": 1,
		"type": "campaign",
		"tech_tree": TechTree.get_save_data(),
		"sector_resources": _serialize_sector_resources(),
		"sector_production_rates": _serialize_production_rates(),
		"sector_production_timestamps": _serialize_production_timestamps(),
		"sector_storage_caps": _serialize_storage_caps(),
	}
	return _write_json(SAVE_DIR + "campaign.json", data)


func _serialize_storage_caps() -> Dictionary:
	var result := {}
	for sid in sector_storage_caps:
		result[String(sid)] = int(sector_storage_caps[sid])
	return result


func _deserialize_storage_caps(data: Dictionary) -> void:
	sector_storage_caps.clear()
	for sid_str in data:
		sector_storage_caps[StringName(sid_str)] = int(data[sid_str])


## Trims every sector's stockpile down to its saved per-resource cap.
## No-op for sectors that never had a cap recorded (old saves / sectors
## that were never actually saved) so we don't zero out legit progress.
func _clamp_sector_resources_to_caps() -> void:
	for sid in sector_resources.keys():
		var cap: int = int(sector_storage_caps.get(sid, 0))
		if cap <= 0:
			continue
		var bucket: Dictionary = sector_resources[sid]
		for item_id in bucket.keys():
			if int(bucket[item_id]) > cap:
				bucket[item_id] = cap


## Captures the live sector's resource production rate and stamps "now".
## Called when the active sector is about to go idle (player returns to
## planet menu, quits, or switches sectors) so its rates are locked in
## for offline accrual. The caller must ensure `main` is the live scene
## for the sector identified by `sector_id`.
func capture_production_snapshot(sector_id: StringName, main: Node2D) -> void:
	if sector_id == &"":
		return
	var rates: Dictionary = SectorProductionSim.calculate_rates(main)
	sector_production_rates[sector_id] = rates
	sector_production_timestamps[sector_id] = Time.get_unix_time_from_system()
	# Snapshot storage cap at the same moment so offline accrual knows
	# when to stop producing for this sector even though the sector
	# isn't simulated in full.
	if main.has_method("get_storage_cap_per_resource"):
		sector_storage_caps[sector_id] = int(main.get_storage_cap_per_resource())


## Advances offline production for every non-active sector: for each one,
## adds `rate * elapsed` of each item_id into its sector_resources dict
## and resets its timestamp to `now`. Fractional leftovers are preserved
## so slow producers still accrue integer items over multiple calls.
func advance_offline_production() -> void:
	var now: float = Time.get_unix_time_from_system()
	for sid in sector_production_rates:
		if sid == active_sector_id:
			# Live sector is simulated by the running game — skip.
			sector_production_timestamps[sid] = now
			continue
		var rates: Dictionary = sector_production_rates[sid]
		if rates.is_empty():
			sector_production_timestamps[sid] = now
			continue
		var last: float = float(sector_production_timestamps.get(sid, now))
		var elapsed: float = now - last
		if elapsed <= 0.0:
			continue
		if not sector_resources.has(sid):
			sector_resources[sid] = {}
		if not _sector_production_fractions.has(sid):
			_sector_production_fractions[sid] = {}
		var bucket: Dictionary = sector_resources[sid]
		var fracs: Dictionary = _sector_production_fractions[sid]
		var cap: int = int(sector_storage_caps.get(sid, 0))
		for item_id in rates:
			var rate: float = float(rates[item_id])
			if rate == 0.0:
				continue
			var added: float = rate * elapsed + float(fracs.get(item_id, 0.0))
			var whole: int = int(floor(added))
			fracs[item_id] = added - float(whole)
			if whole == 0:
				continue
			var current: int = int(bucket.get(item_id, 0))
			var new_amt: int = current + whole
			# Net-negative rates (under-fed factories) can't drive a
			# stockpile below zero — clamp and drop the fractional
			# carryover so the factory doesn't keep "owing" items.
			if new_amt < 0:
				new_amt = 0
				fracs[item_id] = 0.0
			# Storage cap: a sector can't accrue past what its cores
			# could actually hold if it were live. Clamp AND stop
			# carrying fractional overflow so it doesn't just leak out
			# next tick.
			if cap > 0 and new_amt > cap:
				new_amt = cap
				fracs[item_id] = 0.0
			bucket[item_id] = new_amt
		# Defensive sweep: if the bucket has pre-existing items that
		# already exceed the cap (destroyed core, data migration, etc.)
		# clamp them too. Zero-rate items were never visited by the loop.
		if cap > 0:
			for item_id in bucket.keys():
				if int(bucket[item_id]) > cap:
					bucket[item_id] = cap
		sector_production_timestamps[sid] = now


func _serialize_production_rates() -> Dictionary:
	var result := {}
	for sid in sector_production_rates:
		var inner := {}
		for item_id in sector_production_rates[sid]:
			inner[String(item_id)] = float(sector_production_rates[sid][item_id])
		result[String(sid)] = inner
	return result


func _serialize_production_timestamps() -> Dictionary:
	var result := {}
	for sid in sector_production_timestamps:
		result[String(sid)] = float(sector_production_timestamps[sid])
	return result


func _deserialize_production_rates(data: Dictionary) -> void:
	sector_production_rates.clear()
	for sid_str in data:
		var sid := StringName(sid_str)
		var inner := {}
		for item_id_str in data[sid_str]:
			inner[StringName(item_id_str)] = float(data[sid_str][item_id_str])
		sector_production_rates[sid] = inner


func _deserialize_production_timestamps(data: Dictionary) -> void:
	sector_production_timestamps.clear()
	for sid_str in data:
		sector_production_timestamps[StringName(sid_str)] = float(data[sid_str])


## Loads campaign-level state. Called automatically on startup.
func load_campaign() -> bool:
	var path = SAVE_DIR + "campaign.json"
	if not FileAccess.file_exists(path):
		return false
	var data = _read_json(path)
	if data == null:
		return false
	if data.has("tech_tree"):
		var td: Dictionary = {}
		for key in data["tech_tree"]:
			var spent_data: Dictionary = {}
			for item_key in data["tech_tree"][key]:
				spent_data[StringName(item_key)] = int(data["tech_tree"][key][item_key])
			td[StringName(key)] = spent_data
		TechTree.load_save_data(td)
	if data.has("sector_resources"):
		_deserialize_sector_resources(data["sector_resources"])
	if data.has("sector_production_rates"):
		_deserialize_production_rates(data["sector_production_rates"])
	if data.has("sector_production_timestamps"):
		_deserialize_production_timestamps(data["sector_production_timestamps"])
	if data.has("sector_storage_caps"):
		_deserialize_storage_caps(data["sector_storage_caps"])
	# Clamp any existing stockpile against its saved cap before the
	# accrual pass — handles the "a core was destroyed last session"
	# case, old saves that pre-date the cap, and any other over-cap
	# state that somehow got persisted.
	_clamp_sector_resources_to_caps()
	# Apply any resources produced while the game was closed. Uses the
	# saved per-sector rates + timestamps captured at last snapshot.
	advance_offline_production()
	print("SaveManager: Campaign loaded (%d sectors with resources)" % sector_resources.size())
	return true


func _serialize_sector_resources() -> Dictionary:
	var result := {}
	for sector_id in sector_resources:
		var res_data := {}
		for item_id in sector_resources[sector_id]:
			res_data[String(item_id)] = sector_resources[sector_id][item_id]
		result[String(sector_id)] = res_data
	return result


func _deserialize_sector_resources(data: Dictionary) -> void:
	sector_resources.clear()
	for sector_id_str in data:
		var sid = StringName(sector_id_str)
		sector_resources[sid] = {}
		for item_id_str in data[sector_id_str]:
			sector_resources[sid][StringName(item_id_str)] = int(data[sector_id_str][item_id_str])


# =========================
# SCHEMATICS
# =========================

## Save a schematic to disk. blocks/rotation are Dictionaries with "x,y" string keys.
func save_schematic(schem_name: String, blocks: Dictionary, rotation: Dictionary, width: int, height: int) -> bool:
	# Compute total cost
	var total_cost: Dictionary = {}
	for pos_str in blocks:
		var block_id: StringName = StringName(blocks[pos_str])
		var data = Registry.get_block(block_id)
		if data:
			for item_id in data.build_cost:
				total_cost[String(item_id)] = total_cost.get(String(item_id), 0) + data.build_cost[item_id]

	var save_data: Dictionary = {
		"version": 1,
		"type": "schematic",
		"name": schem_name,
		"width": width,
		"height": height,
		"blocks": blocks,
		"rotation": rotation,
		"total_cost": total_cost,
	}
	var safe_name: String = schem_name.replace("/", "_").replace("\\", "_").replace(":", "_").strip_edges()
	if safe_name == "":
		safe_name = "unnamed"
	return _write_json(SCHEMATIC_DIR + safe_name + ".schematic.json", save_data)


## Load a schematic from disk. Returns the parsed Dictionary or null.
func load_schematic(schem_name: String) -> Variant:
	var safe_name: String = schem_name.replace("/", "_").replace("\\", "_").replace(":", "_").strip_edges()
	return _read_json(SCHEMATIC_DIR + safe_name + ".schematic.json")


## List all saved schematic names (without extension).
func list_schematics() -> PackedStringArray:
	var result: PackedStringArray = []
	var dir = DirAccess.open(SCHEMATIC_DIR)
	if dir == null:
		return result
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if file_name.ends_with(".schematic.json"):
			result.append(file_name.replace(".schematic.json", ""))
		file_name = dir.get_next()
	dir.list_dir_end()
	result.sort()
	return result


## Delete a schematic file.
func delete_schematic(schem_name: String) -> bool:
	var safe_name: String = schem_name.replace("/", "_").replace("\\", "_").replace(":", "_").strip_edges()
	var path: String = SCHEMATIC_DIR + safe_name + ".schematic.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		return true
	return false
