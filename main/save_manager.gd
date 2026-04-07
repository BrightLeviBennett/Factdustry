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
# SAVE: MAP ONLY (tiles)
# =========================

## Saves just the tile layout as a reusable map template.
func save_map(map_name: String) -> bool:
	var main = get_node_or_null("/root/Main")
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if main == null or terrain == null:
		push_warning("SaveManager: Can't find Main or TerrainSystem!")
		return false

	var data := {
		"version": 2,
		"type": "map",
		"map_name": map_name,
		"grid_width": main.GRID_WIDTH,
		"grid_height": main.GRID_HEIGHT,
		"floor_tiles": _serialize_tiles(terrain.floor_tiles),
		"wall_tiles": _serialize_tiles(terrain.wall_tiles),
		"ore_tiles": _serialize_tiles(terrain.ore_tiles),
		"core_position": _vec2i_to_str(main.core_position),
	}

	return _write_json(SAVE_DIR + map_name + ".map.json", data)


# =========================
# LOAD: MAP FROM PATH
# =========================

## Loads a map from an arbitrary file path (e.g. res://data/game/tarkon/maps/SG.map.json).
func load_map_from_path(path: String) -> bool:
	var main = get_node_or_null("/root/Main")
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if main == null or terrain == null:
		push_warning("SaveManager: Can't find Main or TerrainSystem!")
		return false

	var data = _read_json(path)
	if data == null:
		return false

	# Clear all layers
	terrain.floor_tiles.clear()
	terrain.wall_tiles.clear()
	terrain.ore_tiles.clear()
	terrain.tile_health.clear()
	terrain.multi_tile_origins.clear()

	# Detect v2 by version key OR presence of floor_tiles key
	var version = data.get("version", 1)
	if version >= 2 or data.has("floor_tiles"):
		_deserialize_layer(terrain.floor_tiles, data.get("floor_tiles", {}))
		_deserialize_layer(terrain.wall_tiles, data.get("wall_tiles", {}))
		_deserialize_layer(terrain.ore_tiles, data.get("ore_tiles", {}))
		if data.has("core_position"):
			main.core_position = _str_to_vec2i(data["core_position"])
	else:
		_deserialize_tiles_layered(terrain, data.get("tiles", {}))

	_rebuild_multi_tile_origins(terrain)
	terrain.walls_changed.emit()
	terrain.queue_redraw()
	var total: int = terrain.floor_tiles.size() + terrain.wall_tiles.size() + terrain.ore_tiles.size()
	print("SaveManager: Map loaded from '%s' (%d tiles)" % [path, total])
	return true


# =========================
# LOAD: MAP ONLY (tiles)
# =========================

## Loads a map template and places tiles. Clears existing tiles first.
func load_map(map_name: String) -> bool:
	var main = get_node_or_null("/root/Main")
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if main == null or terrain == null:
		push_warning("SaveManager: Can't find Main or TerrainSystem!")
		return false

	var data = _read_json(SAVE_DIR + map_name + ".map.json")
	if data == null:
		return false

	if data.get("type") != "map":
		push_warning("SaveManager: File is not a map template!")
		return false

	# Clear all layers
	terrain.floor_tiles.clear()
	terrain.wall_tiles.clear()
	terrain.ore_tiles.clear()
	terrain.tile_health.clear()
	terrain.multi_tile_origins.clear()

	var version = data.get("version", 1)
	if version >= 2:
		# v2: separate layers
		_deserialize_layer(terrain.floor_tiles, data.get("floor_tiles", {}))
		_deserialize_layer(terrain.wall_tiles, data.get("wall_tiles", {}))
		_deserialize_layer(terrain.ore_tiles, data.get("ore_tiles", {}))
		if data.has("core_position"):
			main.core_position = _str_to_vec2i(data["core_position"])
	else:
		# v1 legacy: merged tiles, sort by category
		_deserialize_tiles_layered(terrain, data.get("tiles", {}))

	_rebuild_multi_tile_origins(terrain)
	terrain.walls_changed.emit()
	terrain.queue_redraw()
	var total: int = terrain.floor_tiles.size() + terrain.wall_tiles.size() + terrain.ore_tiles.size()
	print("SaveManager: Map '%s' loaded (%d tiles)" % [map_name, total])
	return true


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
	if unit_mgr:
		unit_mgr._setup_astar()

	# --- Redraw ---
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

## Returns an array of available map template names.
func list_maps() -> PackedStringArray:
	return _list_files(".map.json")


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

## Deletes a map template file.
func delete_map(map_name: String) -> bool:
	var path = SAVE_DIR + map_name + ".map.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		return true
	return false


## Deletes a full save file.
func delete_save(save_name: String) -> bool:
	var path = SAVE_DIR + save_name + ".save.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		return true
	return false


## Deletes a sector file.
func delete_sector(sector_name: String) -> bool:
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
	if "building_build_progress" in main:
		for anchor in main.building_build_progress:
			build_progress_save[_vec2i_to_str(anchor)] = main.building_build_progress[anchor]
	if "build_order" in main:
		for anchor in main.build_order:
			build_order_save.append(_vec2i_to_str(anchor))

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
			factory_buffers_save[_vec2i_to_str(origin)] = {
				"inputs": inputs_dict,
				"phase": state["phase"],
				"timer": state["timer"],
			}

	# Save payload transport state
	var payload_items_save := {}
	var constructor_state_save := {}
	var deconstructor_state_save := {}
	var loader_state_save := {}
	var unloader_state_save := {}
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
			var tp = cs.get("target_pos")
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
		"linked_pairs": _serialize_links(links),
		"sorter_filters": _serialize_sorter_filters(),
		"script_steps": _serialize_script_steps(),
		"resources": res_save,
		"drone_position": drone_pos,
		"build_progress": build_progress_save,
		"build_order": build_order_save,
		"player_units": units_save,
		"block_storage": block_storage_save,
		"conveyor_items": conveyor_items_save,
		"factory_buffers": factory_buffers_save,
		"payload_items": payload_items_save,
		"constructor_state": constructor_state_save,
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

	# Compute offline defense simulation (time before sector falls)
	var sim_result = SectorDefenseSim.calculate_time_to_fall(main)
	data["defense_sim"] = {
		"time_to_fall": sim_result.time_to_fall if sim_result.time_to_fall != INF else -1.0,
		"is_stable": sim_result.is_stable,
		"summary": sim_result.summary,
		"timestamp": Time.get_unix_time_from_system(),
	}

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
	if logistics:
		logistics.sorter_filters.clear()
		var sf_data = data.get("sorter_filters", {})
		for key in sf_data:
			logistics.sorter_filters[_str_to_vec2i(key)] = StringName(sf_data[key])

	# --- Load script steps ---
	var script_steps_data = data.get("script_steps", [])
	if script_steps_data.size() > 0:
		# In the editor: load into script_editor
		_deserialize_script_steps(main, script_steps_data)
		# In gameplay: load into SectorScript
		var sector_script = get_node_or_null("/root/Main/SectorScript")
		if sector_script and sector_script.has_method("load_script_steps"):
			sector_script.load_script_steps(script_steps_data)
			# Restore runtime state if saved (autosave), otherwise start fresh
			if data.has("script_runtime") and data["script_runtime"] is Dictionary:
				sector_script.call_deferred("load_runtime_state", data["script_runtime"])
			else:
				sector_script.call_deferred("start_script")

	# --- Rebuild health from BlockData.max_health ---
	for grid_pos in main.placed_buildings:
		var block_data = Registry.get_block(main.placed_buildings[grid_pos])
		if block_data:
			main.building_health[grid_pos] = block_data.max_health

	# --- Rebuild building_origins from grid_size ---
	_rebuild_building_origins(main)

	# --- Restore resources (if saved, e.g. from autosave) ---
	if data.has("resources") and data["resources"] is Dictionary:
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

	# --- Restore build progress & order (only in gameplay, not map editor) ---
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

	# --- Rebuild pathfinding ---
	if unit_mgr:
		unit_mgr._setup_astar()

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
				load_logistics.factory_buffers[origin] = {
					"inputs": inputs_dict,
					"phase": str(saved.get("phase", "collecting")),
					"timer": float(saved.get("timer", 0.0)),
					"pending_outputs": {},
				}

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
	for grid_pos in terrain.floor_tiles:
		if processed.has(grid_pos):
			continue
		var tile_id = terrain.floor_tiles[grid_pos]
		if not terrain._is_multi_tile(tile_id):
			continue
		# This cell is the origin of a 3x3 multi-tile
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var cell = grid_pos + Vector2i(dx, dy)
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
	if logistics == null:
		return {}
	var result := {}
	for grid_pos in logistics.sorter_filters:
		var filter_id = logistics.sorter_filters[grid_pos]
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
	sector_resources[active_sector_id] = main.resources.duplicate()


## Returns the global resource pool: sum of all captured sectors' resources.
func get_global_resources() -> Dictionary:
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
	}
	return _write_json(SAVE_DIR + "campaign.json", data)


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
