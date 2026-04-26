extends Node

# ============================================================
# TECH_TREE.GD - Full Tech Tree System (Autoload)
# ============================================================
# Each node has a hardcoded grid position: Vector2(column, row).
# Row 0 = Core: Shard. Positive row = upward on screen.
# The UI multiplies by cell size to get pixel coordinates.
#
# To reposition a node, just change its Vector2 in the _add call.
#
# ADD AS AUTOLOAD:
# Project → Project Settings → Autoload → Add tech_tree.gd as "TechTree"
# ============================================================

enum NodeState { LOCKED, UNLOCKED, RESEARCHED }

var nodes: Dictionary = {}

signal node_state_changed(node_id: StringName, new_state: int)
signal resources_spent(node_id: StringName)
signal tech_tree_ready

var is_loaded := false
var _thread: Thread

## Campaign sector ids, in capture order. Used both to register the capture
## chain rules and to normalize legacy save data that stored sectors in the
## (no-longer-used) UNLOCKED state.
const CAMPAIGN_CHAIN: Array[StringName] = [
	&"starting_grounds", &"crevice", &"ferrum_ridge", &"waterfront_ruins",
	&"nightfall_depths", &"zinc_deposits", &"aluminum_mountains", &"dark_valley",
	&"ruins", &"the_nexus", &"snowy_plains",
]

## When true, every tech-tree node is treated as RESEARCHED regardless of
## its real unlock state. Flipped by the "Unlock All Tech" setting in the
## Game tab of the pause menu. Off by default — the normal research rules
## apply. Turning it off again instantly reverts to the real state.
var unlock_all: bool = false


func _ready() -> void:
	_thread = Thread.new()
	_thread.start(_thread_register)


func _thread_register() -> void:
	_register_all_nodes()
	_register_unlock_rules()
	call_deferred("_finish_loading")


func _finish_loading() -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null

	for id in nodes:
		if nodes[id]["parents"].is_empty() and nodes[id]["research_cost"].is_empty() and not nodes[id].get("event_only", false):
			_force_researched(id)
	# Starting Grounds is always available
	if nodes.has(&"starting_grounds"):
		_force_researched(&"starting_grounds")
	is_loaded = true
	print("TechTree loaded: %d nodes" % nodes.size())
	tech_tree_ready.emit()


# ================================
# PUBLIC API — State Queries
# ================================

func get_state(id: StringName) -> NodeState:
	if not nodes.has(id): return NodeState.LOCKED
	# Sandbox/cheat: short-circuit to RESEARCHED for everything. Keeps the
	# underlying state dicts untouched so toggling it off instantly reverts.
	if unlock_all:
		return NodeState.RESEARCHED
	# Event-only nodes stay LOCKED until force-unlocked or force-researched
	if nodes[id].get("event_only", false):
		if nodes[id]["amount_spent"].has(&"_event_researched"):
			return NodeState.RESEARCHED
		if nodes[id]["amount_spent"].has(&"_event_unlocked"):
			return NodeState.UNLOCKED
		return NodeState.LOCKED
	# Check visible connections (parents)
	for parent_id in nodes[id]["parents"]:
		if get_state(parent_id) != NodeState.RESEARCHED:
			return NodeState.LOCKED
	# Check hidden dependencies
	for dep_id in nodes[id].get("dependencies", []):
		# Unwrap "-D-archive_id" deps to the underlying archive node so the
		# dependency is satisfied as soon as the archive itself is researched
		# (no need to also research a separate marker).
		var actual_dep: StringName = dep_id
		var dep_str := String(dep_id)
		if dep_str.begins_with("-D-"):
			actual_dep = StringName(dep_str.substr(3))
		if get_state(actual_dep) != NodeState.RESEARCHED:
			return NodeState.LOCKED
	if _is_fully_paid(id):
		return NodeState.RESEARCHED
	return NodeState.UNLOCKED

func is_researched(id: StringName) -> bool: return get_state(id) == NodeState.RESEARCHED
func is_unlocked(id: StringName) -> bool: return get_state(id) == NodeState.UNLOCKED
func is_locked(id: StringName) -> bool: return get_state(id) == NodeState.LOCKED

## Returns true if the player has actually captured this sector (beat its
## objective). Sectors that are merely accessible but not yet captured
## return false. Backed by the hidden "-C-sector_id" marker so this stays
## accurate even though sector nodes themselves render as RESEARCHED as
## soon as they become accessible.
func is_sector_captured(sector_id: StringName) -> bool:
	var marker := StringName("-C-%s" % sector_id)
	if not nodes.has(marker):
		return false
	return nodes[marker]["amount_spent"].has(&"_event_researched")


# ================================
# PUBLIC API — Resource Spending
# ================================

func spend_resources(id: StringName, player_resources: Dictionary) -> bool:
	if get_state(id) != NodeState.UNLOCKED: return false
	var node = nodes[id]
	var any_spent := false
	for item_id in node["research_cost"]:
		var required: int = node["research_cost"][item_id]
		var already_spent: int = node["amount_spent"].get(item_id, 0)
		var still_needed: int = required - already_spent
		if still_needed <= 0: continue
		var available: int = player_resources.get(item_id, 0)
		if available <= 0: continue
		var to_spend: int = mini(still_needed, available)
		node["amount_spent"][item_id] = already_spent + to_spend
		player_resources[item_id] -= to_spend
		any_spent = true
	if any_spent:
		resources_spent.emit(id)
		if _is_fully_paid(id):
			node_state_changed.emit(id, NodeState.RESEARCHED)
	return any_spent

## Spends resources toward a node using the global pool (all sectors combined).
## Deducts from whichever sector has the most of each resource.
## Syncs the active sector first if we're in-game.
func spend_resources_from_global(id: StringName) -> bool:
	if get_state(id) != NodeState.UNLOCKED: return false
	# Sync active sector's current resources before spending
	SaveManager.sync_active_sector_resources()
	var node = nodes[id]
	var any_spent := false
	for item_id in node["research_cost"]:
		var required: int = node["research_cost"][item_id]
		var already_spent: int = node["amount_spent"].get(item_id, 0)
		var still_needed: int = required - already_spent
		if still_needed <= 0: continue
		var actually_taken: int = SaveManager.take_from_global_pool(item_id, still_needed)
		if actually_taken > 0:
			node["amount_spent"][item_id] = already_spent + actually_taken
			any_spent = true
	if any_spent:
		resources_spent.emit(id)
		if _is_fully_paid(id):
			node_state_changed.emit(id, NodeState.RESEARCHED)
		SaveManager.save_campaign()
	return any_spent


func get_spent(id: StringName, item_id: StringName) -> int:
	if not nodes.has(id): return 0
	return nodes[id]["amount_spent"].get(item_id, 0)

func get_cost(id: StringName, item_id: StringName) -> int:
	if not nodes.has(id): return 0
	return nodes[id]["research_cost"].get(item_id, 0)

func get_research_cost(id: StringName) -> Dictionary:
	if not nodes.has(id): return {}
	return nodes[id]["research_cost"]

func get_amount_spent(id: StringName) -> Dictionary:
	if not nodes.has(id): return {}
	return nodes[id]["amount_spent"]

func get_progress(id: StringName) -> float:
	if not nodes.has(id): return 0.0
	var cost = nodes[id]["research_cost"]
	if cost.is_empty(): return 1.0
	var total_cost := 0
	var total_spent := 0
	for item_id in cost:
		total_cost += cost[item_id]
		total_spent += nodes[id]["amount_spent"].get(item_id, 0)
	if total_cost == 0: return 1.0
	return float(total_spent) / float(total_cost)


# ================================
# PUBLIC API — Data Queries
# ================================

func get_node_data(id: StringName) -> Variant:
	return nodes.get(id, null)


func get_tech_children(id: StringName) -> Array[StringName]:
	var result: Array[StringName] = []
	for node_id in nodes:
		if id in nodes[node_id]["parents"] or id in nodes[node_id].get("dependencies", []):
			result.append(node_id)
	return result

func get_depth(id: StringName) -> int:
	if not nodes.has(id): return 0
	if nodes[id]["parents"].is_empty(): return 0
	var max_d := 0
	for pid in nodes[id]["parents"]:
		var pd = get_depth(pid)
		if pd > max_d: max_d = pd
	return max_d + 1


# ================================
# SAVE / LOAD
# ================================

func get_save_data() -> Dictionary:
	var data = {}
	for id in nodes:
		if not nodes[id]["amount_spent"].is_empty():
			data[id] = nodes[id]["amount_spent"].duplicate()
	return data

func load_save_data(data: Dictionary) -> void:
	for id in nodes:
		if data.has(id):
			nodes[id]["amount_spent"] = data[id]
		else:
			nodes[id]["amount_spent"] = {}
	# Re-apply always-researched nodes after load
	for id in nodes:
		if nodes[id]["parents"].is_empty() and nodes[id]["research_cost"].is_empty() and not nodes[id].get("event_only", false):
			_force_researched(id)
	_force_researched(&"starting_grounds")
	# Legacy migration: campaign sectors used to sit in UNLOCKED between
	# "previous sector captured" and "this sector captured". We no longer
	# use that state — upgrade any `_event_unlocked`-only sector to
	# `_event_researched` so the tech tree renders it with the same outline
	# as a finished node.
	for sector_id in CAMPAIGN_CHAIN:
		if not nodes.has(sector_id):
			continue
		var spent: Dictionary = nodes[sector_id]["amount_spent"]
		if spent.has(&"_event_unlocked") and not spent.has(&"_event_researched"):
			_force_researched(sector_id)


# ================================
# EVENT LISTENERS
# ================================

## Maps event type → Array of {trigger_value, node_id} entries.
## When the event fires with a matching value, that node gets auto-researched.
var _unlock_rules: Dictionary = {}

## Known archive ids (used to spawn -D-archive_id hidden markers).
## Add a new archive id here when content is added.
var archive_ids: Array[StringName] = []

func _register_unlock_rules() -> void:
	# Materials unlock when their resource is first mined
	_add_rule("item_mined", &"mat_copper", &"mat_copper")
	_add_rule("item_mined", &"mat_graphite", &"mat_graphite")
	_add_rule("item_mined", &"mat_sand", &"mat_sand")
	# Iron is produced by the mineral extractor, not mined — unlock it as
	# soon as the extractor emits its first unit.
	_add_rule("item_produced", &"mat_iron", &"mat_iron")
	# Steel is smelted from iron + graphite in the steel furnace.
	_add_rule("item_produced", &"mat_steel", &"mat_steel")
	# Silicon is refined from sand + graphite in the silicon refinery.
	_add_rule("item_produced", &"mat_silicon", &"mat_silicon")

	# Campaign sector chain (shared with the save-migration pass in load_save_data).
	var campaign_chain: Array[StringName] = CAMPAIGN_CHAIN
	# Capturing a sector researches BOTH the captured sector and the next
	# one in the chain. Sectors never sit in the UNLOCKED state — they go
	# straight from LOCKED to RESEARCHED so the tech tree shows them with
	# the same "researched" outline finished nodes use. Landing/capture
	# progression for non-sector tech is still handled by the hidden
	# "-L-" / "-C-" markers registered below.
	for i in range(campaign_chain.size() - 1):
		_add_rule("sector_captured", campaign_chain[i], campaign_chain[i + 1])
	for sector_id in campaign_chain:
		_add_rule("sector_captured", sector_id, sector_id)

	# Create hidden marker nodes for sector landed/captured dependencies
	# Format: "-L-sector_name" = landed on, "-C-sector_name" = captured
	for sector_id in campaign_chain:
		var landed_id := StringName("-L-%s" % sector_id)
		var captured_id := StringName("-C-%s" % sector_id)
		_add_hidden_marker(landed_id)
		_add_hidden_marker(captured_id)
		# Landing on a sector → mark -L- node as researched
		_add_rule("sector_launched", sector_id, landed_id)
		# Capturing a sector → mark -C- node as researched
		_add_rule("sector_captured", sector_id, captured_id)

	# Hidden marker nodes for archive-decoded dependencies
	# Format: "-D-archive_id" — fired when an archive is fully decoded.
	for archive_id in archive_ids:
		var decoded_id := StringName("-D-%s" % archive_id)
		_add_hidden_marker(decoded_id)
		_add_rule("archive_decoded", archive_id, decoded_id)

func _add_rule(event: String, trigger_value: StringName, node_id: StringName, unlock_only: bool = false) -> void:
	if not _unlock_rules.has(event):
		_unlock_rules[event] = []
	_unlock_rules[event].append({"trigger": trigger_value, "node": node_id, "unlock_only": unlock_only})

## Call this once the Main scene is ready so we can connect to its signals.
func connect_to_main(main_node: Node2D) -> void:
	if main_node.has_signal("item_mined"):
		main_node.item_mined.connect(_on_item_mined)
	if main_node.has_signal("item_absorbed_in_core"):
		main_node.item_absorbed_in_core.connect(_on_item_absorbed_in_core)
	if main_node.has_signal("item_produced"):
		main_node.item_produced.connect(_on_item_produced)
	if main_node.has_signal("sector_launched"):
		main_node.sector_launched.connect(_on_sector_launched)
	if main_node.has_signal("sector_captured"):
		main_node.sector_captured.connect(_on_sector_captured)
	if main_node.has_signal("archive_decoded"):
		main_node.archive_decoded.connect(_on_archive_decoded)

func _on_item_mined(item_id: StringName) -> void:
	_process_event("item_mined", item_id)

func _on_item_absorbed_in_core(item_id: StringName) -> void:
	_process_event("item_absorbed_in_core", item_id)

func _on_item_produced(item_id: StringName) -> void:
	_process_event("item_produced", item_id)

func _on_sector_launched(sector_id: StringName) -> void:
	_process_event("sector_launched", sector_id)

func _on_sector_captured(sector_id: StringName) -> void:
	_process_event("sector_captured", sector_id)

func _on_archive_decoded(archive_id: StringName) -> void:
	_process_event("archive_decoded", archive_id)

func _process_event(event: String, value: StringName) -> void:
	if not _unlock_rules.has(event):
		return
	for rule in _unlock_rules[event]:
		if rule["trigger"] == value:
			var node_id: StringName = rule["node"]
			if not nodes.has(node_id) or is_researched(node_id):
				continue
			if rule.get("unlock_only", false):
				_force_unlocked(node_id)
				node_state_changed.emit(node_id, NodeState.UNLOCKED)
			else:
				_force_researched(node_id)
				node_state_changed.emit(node_id, NodeState.RESEARCHED)


# ================================
# INTERNAL
# ================================

func _is_fully_paid(id: StringName) -> bool:
	var node = nodes[id]
	if node["research_cost"].is_empty(): return true
	for item_id in node["research_cost"]:
		if node["amount_spent"].get(item_id, 0) < node["research_cost"][item_id]:
			return false
	return true

func _force_unlocked(id: StringName) -> void:
	var node = nodes[id]
	if node.get("event_only", false):
		node["amount_spent"][&"_event_unlocked"] = 1

func _force_researched(id: StringName) -> void:
	var node = nodes[id]
	for item_id in node["research_cost"]:
		node["amount_spent"][item_id] = node["research_cost"][item_id]
	# For event_only nodes, set a marker so get_state knows they've been researched
	if node.get("event_only", false):
		node["amount_spent"][&"_event_researched"] = 1

## Creates a hidden marker node (no UI, no position, event_only).
## Used for -L- (landed) and -C- (captured) sector dependency markers.
func _add_hidden_marker(id: StringName) -> void:
	nodes[id] = {
		"id": id,
		"name": str(id),
		"parents": [],
		"dependencies": [],
		"research_cost": {},
		"amount_spent": {},
		"pos": Vector2.ZERO,
		"event_only": true,
		"hidden": true,
	}

## pos = Vector2(column, row) grid position. Row 0 = Core: Shard level.
## Positive row = upward. The UI converts to pixels.
## connections: visible parent lines (drawn in UI) + unlock requirement
## dependencies: hidden unlock requirements (not drawn, but must be researched to unlock)
func _add(id: StringName, display_name: String, parents: Array, dependencies: Array, cost: Dictionary, pos: Vector2, event_only: bool = false) -> void:
	nodes[id] = {
		"id": id,
		"name": display_name,
		"parents": parents,
		"dependencies": dependencies,
		"research_cost": cost,
		"amount_spent": {},
		"pos": pos,
		"event_only": event_only,
	}


func _register_all_nodes() -> void:
	_register_cores()
	_register_campaign()
	_register_power()
	_register_belt_transport()
	_register_duct_transport()
	_register_fluid_transport()
	_register_mining()
	_register_materials()
	_register_production()
	_register_turrets()
	_register_support()
	_register_units()
	_register_payload_freight()
	_register_walls()
	_register_platforms()
	_register_archives()


# ================================================================
# NODE REGISTRATION — All positions are Vector2(column, row)
# Row 0 = Core: Shard. Positive row = up on screen.
# Columns spread left (negative) and right (positive) from center.
# ================================================================

func _register_cores() -> void:
	_add(&"core_shard",        "Core: Shard",        [],                  [], {}, Vector2(0, 0))
	_add(&"core_fragment",     "Core: Fragment",     [&"core_shard"],     [&"mat_steel"], {&"mat_copper": 1500, &"mat_graphite": 1200, &"mat_silicon": 300, &"mat_steel": 50}, Vector2(-2, 1))
	_add(&"core_remanent",     "Core: Remanent",     [&"core_fragment"],  [], {&"mat_copper": 2500, &"mat_graphite": 2000, &"mat_silicon": 600, &"mat_steel": 150}, Vector2(-2, 2))
	_add(&"core_bastion",      "Core: Bastion",      [&"core_remanent"],  [], {&"mat_copper": 4000, &"mat_graphite": 3500, &"mat_silicon": 1200, &"mat_steel": 400}, Vector2(-2, 3))
	_add(&"core_fortress",     "Core: Fortress",     [&"core_bastion"],   [], {&"mat_copper": 5500, &"mat_graphite": 5000, &"mat_silicon": 2000, &"mat_steel": 1000}, Vector2(-2, 4))
	_add(&"core_crucible",     "Core: Crucible",     [&"core_fortress"],  [], {&"mat_copper": 7500, &"mat_graphite": 6500, &"mat_silicon": 3000, &"mat_steel": 1800, &"mat_brass": 300}, Vector2(-2, 5))
	_add(&"core_pantheon",     "Core: Pantheon",     [&"core_crucible"],  [], {&"mat_copper": 10000, &"mat_graphite": 9000, &"mat_silicon": 4500, &"mat_steel": 3000, &"mat_brass": 700}, Vector2(-2, 6))
	_add(&"core_aegis",        "Core: Aegis",        [&"core_pantheon"],  [], {&"mat_copper": 13500, &"mat_graphite": 12000, &"mat_silicon": 6000, &"mat_steel": 4500, &"mat_aluminum": 1000}, Vector2(-2, 7))
	_add(&"core_singularity",  "Core: Singularity",  [&"core_aegis"],     [], {&"mat_copper": 18000, &"mat_graphite": 16000, &"mat_silicon": 8500, &"mat_steel": 6500, &"mat_aluminum": 2000}, Vector2(-2, 8))
	# Archive line
	_add(&"archive_scanner",   "Archive Scanner",    [&"core_shard"],     [&"-L-waterfront_ruins"], {&"mat_copper": 180}, Vector2(-3, 1))
	_add(&"data_cable",        "Data Cable",         [&"archive_scanner"],[], {&"mat_copper": 40}, Vector2(-4, 1))
	_add(&"archive_decoder",   "Archive Decoder",    [&"archive_scanner"],[], {&"mat_copper": 240}, Vector2(-3, 2))

func _register_campaign() -> void:
	_add(&"starting_grounds",    "Starting Grounds",    [&"core_shard"],          [], {}, Vector2(2, 1), true)
	_add(&"crevice",             "Crevice",             [&"starting_grounds"],    [], {}, Vector2(2, 2), true)
	_add(&"ferrum_ridge",        "Ferrum Ridge",        [&"crevice"],             [], {}, Vector2(2, 3), true)
	_add(&"waterfront_ruins",    "Waterfront Ruins",    [&"ferrum_ridge"],        [], {}, Vector2(2, 4), true)
	_add(&"nightfall_depths",    "Nightfall Depths",    [&"waterfront_ruins"],    [], {}, Vector2(2, 5), true)
	_add(&"zinc_deposits",       "Zinc Deposits",       [&"nightfall_depths"],    [], {}, Vector2(2, 6), true)
	_add(&"aluminum_mountains",  "Aluminum Mountains",  [&"zinc_deposits"],       [], {}, Vector2(2, 7), true)
	_add(&"dark_valley",         "Dark Valley",         [&"aluminum_mountains"],  [], {}, Vector2(2, 8), true)
	_add(&"ruins",               "Ruins",               [&"dark_valley"],         [], {}, Vector2(2, 9), true)
	_add(&"the_nexus",           "The Nexus",           [&"ruins"],               [], {}, Vector2(2, 10), true)
	_add(&"snowy_plains",        "Snowy Plains",        [&"the_nexus"],           [], {}, Vector2(2, 11), true)

func _register_power() -> void:
	_add(&"vent_turbine",         "Vent Turbine",         [&"core_shard"],              [&"mat_copper"], {&"mat_copper": 30}, Vector2(0, 1))
	_add(&"cable_node",           "Cable Node",           [&"vent_turbine"],            [], {&"mat_copper": 15}, Vector2(0, 2))
	_add(&"solar_panel",          "Solar Panel",          [&"vent_turbine"],            [&"Not unlockable in campaign"], {&"mat_copper": 50, &"mat_silicon": 20}, Vector2(-1, 2))
	_add(&"solar_array",          "Solar Array",          [&"solar_panel"],             [&"Not unlockable in campaign"], {&"mat_copper": 120, &"mat_silicon": 60}, Vector2(-1, 3))
	_add(&"cable_tower",          "Cable Tower",          [&"cable_node"],              [], {&"mat_copper": 200, &"mat_silicon": 80, &"mat_steel": 40}, Vector2(0, 3))
	_add(&"power_distributor",    "Power Distributor",    [&"cable_tower"],             [], {&"mat_copper": 400, &"mat_silicon": 150, &"mat_steel": 140}, Vector2(0, 4))
	_add(&"combustion_generator", "Combustion Generator", [&"vent_turbine"],            [&"mat_coal"], {&"mat_copper": 120, &"mat_silicon": 40, &"mat_graphite": 20}, Vector2(1, 2))
	_add(&"combustion_reactor",   "Combustion Reactor",   [&"combustion_generator"],    [&"Not unlockable in campaign"], {&"mat_copper": 120, &"mat_silicon": 40, &"mat_graphite": 20}, Vector2(1, 2))

func _register_belt_transport() -> void:
	_add(&"conveyor_belt",       "Conveyor Belt",       [&"core_shard"],        [&"mat_copper"], {&"mat_copper": 20}, Vector2(5, 1))
	_add(&"belt_junction",       "Belt Junction",       [&"conveyor_belt"],     [], {&"mat_copper": 60}, Vector2(3, 2))
	_add(&"belt_router",         "Belt Router",         [&"conveyor_belt"],     [], {&"mat_copper": 60}, Vector2(4, 2))
	_add(&"belt_bridge",         "Belt Bridge",         [&"conveyor_belt"],     [], {&"mat_copper": 80}, Vector2(5, 2))
	_add(&"belt_sorter",         "Belt Sorter",         [&"conveyor_belt"],     [], {&"mat_copper": 80}, Vector2(6, 2))
	_add(&"overflow_belt",       "Overflow Belt",       [&"conveyor_belt"],     [], {&"mat_copper": 70}, Vector2(7, 2))
	_add(&"small_container",     "Small Container",     [&"belt_router"],       [&"mat_silicon"], {&"mat_copper": 150}, Vector2(4, 3))
	_add(&"unloader",            "Unloader",            [&"belt_router"],       [&"mat_silicon"], {&"mat_copper": 60, &"mat_silicon": 25}, Vector2(3, 3))
	_add(&"cargo_mass_driver",   "Cargo Mass Driver",   [&"belt_bridge"],       [], {&"mat_copper": 150}, Vector2(5, 3))
	_add(&"inverted_belt_sorter","Inverted Belt Sorter", [&"belt_sorter"],      [], {&"mat_copper": 120, &"mat_silicon": 50, &"mat_graphite": 20}, Vector2(6, 3))
	_add(&"underflow_belt",      "Underflow Belt",      [&"overflow_belt"],     [], {&"mat_copper": 120, &"mat_silicon": 50, &"mat_graphite": 20}, Vector2(7, 3))

func _register_duct_transport() -> void:
	_add(&"duct",                  "Duct",                  [&"conveyor_belt"],    [&"mat_steel"], {&"mat_copper": 80, &"mat_graphite": 20}, Vector2(10, 2))
	_add(&"duct_junction",         "Duct Junction",         [&"duct"],             [], {&"mat_copper": 120, &"mat_graphite": 40, &"mat_silicon": 20}, Vector2(8, 3))
	_add(&"duct_router",           "Duct Router",           [&"duct"],             [], {&"mat_copper": 120, &"mat_graphite": 40, &"mat_silicon": 20}, Vector2(9, 3))
	_add(&"duct_bridge",           "Duct Bridge",           [&"duct"],             [], {&"mat_copper": 140, &"mat_graphite": 50, &"mat_silicon": 25}, Vector2(10, 3))
	_add(&"duct_sorter",           "Duct Sorter",           [&"duct"],             [], {&"mat_copper": 140, &"mat_silicon": 50, &"mat_graphite": 30}, Vector2(11, 3))
	_add(&"overflow_duct",         "Overflow Duct",         [&"duct"],             [], {&"mat_copper": 130, &"mat_silicon": 45, &"mat_graphite": 25}, Vector2(12, 3))
	_add(&"inverted_duct_sorter",  "Inverted Duct Sorter",  [&"duct_sorter"],      [], {&"mat_copper": 200, &"mat_silicon": 80, &"mat_steel": 30}, Vector2(11, 4))
	_add(&"underflow_duct",        "Underflow Duct",        [&"overflow_duct"],    [], {&"mat_copper": 200, &"mat_silicon": 80, &"mat_steel": 30}, Vector2(12, 4))

func _register_fluid_transport() -> void:
	_add(&"fluid_conduit",              "Fluid Conduit",              [&"core_shard"],          [&"mat_steel"], {&"mat_copper": 25, &"mat_graphite": 10}, Vector2(18, 1))
	_add(&"fluid_pump",                 "Fluid Pump",                 [&"fluid_conduit"],       [], {&"mat_copper": 80, &"mat_silicon": 30, &"mat_graphite": 15}, Vector2(14, 2))
	_add(&"vent_condenser",             "Vent Condenser",             [&"fluid_conduit"],       [], {&"mat_copper": 70, &"mat_graphite": 25}, Vector2(15, 2))
	_add(&"geyser_condenser",           "Geyser Condenser",           [&"vent_condenser"],      [], {&"mat_copper": 150, &"mat_silicon": 50, &"mat_steel": 30}, Vector2(15, 3))
	_add(&"conduit_junction",           "Conduit Junction",           [&"fluid_conduit"],       [], {&"mat_copper": 60, &"mat_graphite": 20}, Vector2(16, 2))
	_add(&"conduit_router",             "Conduit Router",             [&"fluid_conduit"],       [], {&"mat_copper": 60, &"mat_graphite": 20}, Vector2(17, 2))
	_add(&"conduit_bridge",             "Conduit Bridge",             [&"fluid_conduit"],       [], {&"mat_copper": 80, &"mat_graphite": 25, &"mat_silicon": 15}, Vector2(18, 2))
	_add(&"conduit_sorter",             "Conduit Sorter",             [&"fluid_conduit"],       [], {&"mat_copper": 80, &"mat_silicon": 30, &"mat_graphite": 15}, Vector2(19, 2))
	_add(&"overflow_conduit",           "Overflow Conduit",           [&"fluid_conduit"],       [], {&"mat_copper": 70, &"mat_silicon": 25, &"mat_graphite": 15}, Vector2(20, 2))
	_add(&"sealed_cargo_mass_driver",   "Sealed Cargo Mass Driver",   [&"conduit_bridge"],      [], {&"mat_copper": 180, &"mat_silicon": 70, &"mat_steel": 35}, Vector2(18, 3))
	_add(&"inverted_conduit_sorter",    "Inverted Conduit Sorter",    [&"conduit_sorter"],      [], {&"mat_copper": 130, &"mat_silicon": 50, &"mat_steel": 20}, Vector2(19, 3))
	_add(&"underflow_conduit",          "Underflow Conduit",          [&"overflow_conduit"],    [], {&"mat_copper": 130, &"mat_silicon": 50, &"mat_steel": 20}, Vector2(20, 3))

func _register_mining() -> void:
	_add(&"mechanical_drill",      "Mechanical Drill",      [&"core_shard"],            [&"mat_copper"], {&"mat_copper": 30}, Vector2(22, -1))
	_add(&"impact_driller",        "Impact Driller",        [&"mechanical_drill"],      [&"-L-zinc_deposits"], {&"mat_copper": 90, &"mat_graphite": 30}, Vector2(25, -2))
	_add(&"bauxite_crusher",       "Bauxite Crusher",       [&"mechanical_drill"],      [&"-L-aluminum_mountains"], {&"mat_copper": 80, &"mat_silicon": 25}, Vector2(24, -2))
	_add(&"wall_crusher",          "Wall Crusher",          [&"mechanical_drill"],      [&"mat_graphite"], {&"mat_copper": 80, &"mat_graphite": 25}, Vector2(23, -2))
	_add(&"plasma_bore",           "Plasma Bore",           [&"mechanical_drill"],      [&"mat_steel"], {&"mat_copper": 100, &"mat_silicon": 40}, Vector2(22, -2))
	_add(&"mineral_extractor",     "Mineral Extractor",     [&"mechanical_drill"],      [&"-L-ferrum_ridge"], {&"mat_copper": 70, &"mat_graphite": 20}, Vector2(21, -2))
	_add(&"ground_scraper",        "Ground Scraper",        [&"impact_driller"],        [&"-L-nightfall_depths"], {&"mat_copper": 180, &"mat_graphite": 60, &"mat_steel": 30}, Vector2(26, -3))
	_add(&"earthquake_harvester",  "Earthquake Harvester",  [&"impact_driller"],        [], {&"mat_copper": 200, &"mat_silicon": 70, &"mat_steel": 40}, Vector2(25, -3))
	_add(&"bauxite_grinder",       "Bauxite Grinder",       [&"bauxite_crusher"],       [], {&"mat_copper": 160, &"mat_silicon": 60, &"mat_graphite": 30}, Vector2(24, -3))
	_add(&"wall_grinder",          "Wall Grinder",          [&"wall_crusher"],          [&"mat_steel"], {&"mat_copper": 160, &"mat_steel": 50, &"mat_graphite": 30}, Vector2(23, -3))
	_add(&"advanced_plasma_bore",  "Advanced Plasma Bore",  [&"plasma_bore"],           [&"Not unlockable in campaign"], {&"mat_copper": 200, &"mat_silicon": 80, &"mat_steel": 40}, Vector2(22, -3))
	_add(&"petroleum_drill",       "Petroleum Drill",       [&"mechanical_drill"],      [&"-L-dark_valley"], {&"mat_copper": 150, &"mat_graphite": 50, &"mat_steel": 25}, Vector2(21, -3))
	_add(&"ground_harvester",      "Ground Harvester",      [&"ground_scraper"],        [], {&"mat_copper": 300, &"mat_silicon": 120, &"mat_steel": 80}, Vector2(26, -4))
	_add(&"eruption_harvester",    "Eruption Harvester",    [&"earthquake_harvester"],  [], {&"mat_copper": 300, &"mat_silicon": 120, &"mat_steel": 80}, Vector2(25, -4))

func _register_materials() -> void:
	# Row 1 — Root. Copper is the entry-point material and sits centered
	# below the eight primary extractables.
	_add(&"mat_copper",   "Copper",   [&"core_shard"],  [], {}, Vector2(27, 1), true)

	# Row 2 — Primary extractables. Each is Copper's direct child; even
	# the ones with no shown children (Coal, Water, Graphite, Silver)
	# still appear in the row so the eight slots line up.
	_add(&"mat_coal",     "Coal",     [&"mat_copper"],  [], {}, Vector2(25, 2), true)
	_add(&"mat_water",    "Water",    [&"mat_copper"],  [], {}, Vector2(26, 2), true)
	_add(&"mat_graphite", "Graphite", [&"mat_copper"],  [], {}, Vector2(27, 2), true)
	_add(&"mat_sand",     "Sand",     [&"mat_copper"],  [], {}, Vector2(28, 2), true)
	_add(&"mat_iron",     "Iron",     [&"mat_copper"],  [], {}, Vector2(29, 2), true)
	_add(&"mat_bauxite",  "Bauxite",  [&"mat_copper"],  [], {}, Vector2(30, 2), true)
	_add(&"mat_zinc",     "Zinc",     [&"mat_copper"],  [], {}, Vector2(31, 2), true)
	_add(&"mat_silver",   "Silver",   [&"mat_copper"],  [], {}, Vector2(32, 2), true)

	# Row 3 — First-pass refinements sitting directly above their
	# source extractable.
	_add(&"mat_silicon",  "Silicon",  [&"mat_sand"],    [], {}, Vector2(28, 3), true)
	_add(&"mat_steel",    "Steel",    [&"mat_iron"],    [], {}, Vector2(29, 3), true)
	_add(&"mat_alumina",  "Alumina",  [&"mat_bauxite"], [], {}, Vector2(30, 3), true)
	_add(&"mat_brass",    "Brass",    [&"mat_zinc"],    [], {}, Vector2(31, 3), true)

	# Row 4 — Second-pass refinement. Aluminum sits above Alumina.
	_add(&"mat_aluminum", "Aluminum", [&"mat_alumina"], [], {}, Vector2(30, 4), true)

	# Keep the legacy nodes in the data model but mark them hidden so
	# they don't render in the tech-tree UI. They stay reachable from
	# code (e.g. event-based unlocks) and from any content that still
	# references them; re-exposing one is a matter of dropping the
	# `hidden` flag + giving it a position.
	var hidden_legacy: Array[StringName] = [
		&"mat_salt_water", &"mat_salt", &"mat_oxygen", &"mat_hydrogen",
		&"mat_petroleum", &"mat_acetylene",
		&"mat_ethane", &"mat_methane", &"mat_butane", &"mat_propane",
	]
	_add(&"mat_salt_water", "Salt Water", [&"mat_copper"], [], {}, Vector2.ZERO, true)
	_add(&"mat_salt",       "Salt",       [&"mat_salt_water"], [], {}, Vector2.ZERO, true)
	_add(&"mat_oxygen",     "Oxygen",     [&"mat_water"], [], {}, Vector2.ZERO, true)
	_add(&"mat_hydrogen",   "Hydrogen",   [&"mat_water"], [], {}, Vector2.ZERO, true)
	_add(&"mat_petroleum",  "Petroleum",  [&"mat_graphite"], [], {}, Vector2.ZERO, true)
	_add(&"mat_acetylene",  "Acetylene",  [&"mat_graphite"], [], {}, Vector2.ZERO, true)
	_add(&"mat_ethane",     "Ethane",     [&"mat_petroleum"], [], {}, Vector2.ZERO, true)
	_add(&"mat_methane",    "Methane",    [&"mat_petroleum"], [], {}, Vector2.ZERO, true)
	_add(&"mat_butane",     "Butane",     [&"mat_petroleum"], [], {}, Vector2.ZERO, true)
	_add(&"mat_propane",    "Propane",    [&"mat_petroleum"], [], {}, Vector2.ZERO, true)
	for id in hidden_legacy:
		if nodes.has(id):
			nodes[id]["hidden"] = true

func _register_production() -> void:
	_add(&"silicon_mixer",               "Silicon Refinery",            [&"core_shard"],                       [&"mat_graphite"], {&"mat_copper": 100, &"mat_graphite": 20}, Vector2(-6, 1))
	_add(&"steel_furnace",               "Steel Furnace",               [&"silicon_mixer"],                    [&"mat_iron"], {&"mat_copper": 180, &"mat_silicon": 60, &"mat_graphite": 40}, Vector2(-7, 2))
	_add(&"graphite_electrolyzer",       "Graphite Electrolyzer",       [&"silicon_mixer"],                    [&"Not unlockable in campaign"], {&"mat_copper": 150, &"mat_silicon": 50, &"mat_graphite": 30}, Vector2(-6, 2))
	_add(&"circuit_printer",             "Circuit Printer",             [&"silicon_mixer"],                    [&"Not unlockable in campaign"], {&"mat_copper": 160, &"mat_silicon": 60, &"mat_graphite": 25}, Vector2(-5, 2))
	_add(&"water_filter",                "Water Filter",                [&"silicon_mixer"],                    [&"Not unlockable in campaign"], {&"mat_copper": 120, &"mat_silicon": 40, &"mat_graphite": 20}, Vector2(-4, 2))
	_add(&"brass_mixer",                 "Brass Mixer",                 [&"steel_furnace"],                    [&"mat_zinc"], {&"mat_copper": 180, &"mat_silicon": 60, &"mat_steel": 30}, Vector2(-7, 3))
	_add(&"petroleum_refinery",          "Petroleum Refinery",          [&"brass_mixer"],                      [&"Not unlockable in campaign"], {&"mat_copper": 250, &"mat_steel": 110, &"mat_silicon": 60}, Vector2(-7, 4))
	_add(&"air_filter",                  "Air Filter",                  [&"graphite_electrolyzer"],            [&"Not unlockable in campaign"], {&"mat_copper": 200, &"mat_silicon": 70, &"mat_graphite": 40, &"mat_steel": 25}, Vector2(-6, 3))

func _register_turrets() -> void:
	# Single Barrel branch
	_add(&"single_barrel",   "Single Barrel",   [&"core_shard"],                       [], {&"mat_copper": 40}, Vector2(-11, 1))
	_add(&"diffuse",         "Diffuse",         [&"single_barrel"],                    [&"mat_steel"], {&"mat_copper": 80, &"mat_silicon": 25}, Vector2(-11, 2))
	_add(&"double_barrel",   "Double Barrel",   [&"single_barrel"],                    [&"mat_steel"], {&"mat_copper": 90, &"mat_steel": 30}, Vector2(-10, 2))
	_add(&"homing_diffuse",  "Homing Diffuse",  [&"diffuse"],                          [&"Not unlockable in campaign"], {&"mat_copper": 150, &"mat_silicon": 60, &"mat_graphite": 25}, Vector2(-11, 3))
	_add(&"quad_barrel",     "Quad Barrel",     [&"double_barrel"],                    [&"Not unlockable in campaign"], {&"mat_copper": 180, &"mat_steel": 60, &"mat_silicon": 30}, Vector2(-9, 2))
	_add(&"shardstorm",      "Shardstorm",      [&"homing_diffuse", &"double_barrel"], [], {&"mat_copper": 250, &"mat_silicon": 100, &"mat_steel": 50}, Vector2(-10, 3))
	_add(&"octo_barrel",     "Octo Barrel",     [&"quad_barrel"],                      [], {&"mat_copper": 280, &"mat_steel": 100, &"mat_silicon": 60}, Vector2(-9, 3))
	_add(&"thunderburst",    "Thunderburst",    [&"shardstorm"],                       [], {&"mat_copper": 400, &"mat_silicon": 150, &"mat_steel": 110}, Vector2(-10, 4))
	_add(&"duodec",          "Duodec",          [&"octo_barrel"],                      [], {&"mat_copper": 400, &"mat_steel": 200, &"mat_silicon": 80}, Vector2(-9, 4))
	_add(&"quaddec",         "Quaddec",         [&"duodec"],                           [], {&"mat_copper": 600, &"mat_steel": 280, &"mat_silicon": 120}, Vector2(-9, 5))
	# Gauss Launcher branch
	_add(&"gauss_launcher",  "Gauss Launcher",  [&"disarm"],                           [], {&"mat_copper": 200, &"mat_steel": 80, &"mat_graphite": 40}, Vector2(-14, 2))
	_add(&"disarm",          "Disarm",          [&"destroy_turret"],                   [], {&"mat_copper": 150, &"mat_silicon": 50, &"mat_steel": 30}, Vector2(-13, 2))
	_add(&"destroy_turret",  "Destroy",         [&"single_barrel"],                    [&"Not unlockable in campaign"], {&"mat_copper": 120, &"mat_steel": 40, &"mat_graphite": 20}, Vector2(-12, 2))
	_add(&"annihilate",      "Annihilate",      [&"destroy_turret"],                   [], {&"mat_copper": 300, &"mat_silicon": 60, &"mat_steel": 120}, Vector2(-12, 3))
	_add(&"eclipse",         "Eclipse",         [&"annihilate"],                       [&"-L-ruins"], {&"mat_copper": 500, &"mat_steel": 240, &"mat_silicon": 100}, Vector2(-12, 4))
	_add(&"aegis_arc",       "Aegis Arc",       [&"emp_diffuse"],                      [&"-L-ruins"], {&"mat_copper": 600, &"mat_silicon": 200, &"mat_steel": 200}, Vector2(-11, 5))
	_add(&"missile_launcher","Missile Launcher", [&"annihilate"],                      [], {&"mat_copper": 250, &"mat_steel": 105}, Vector2(-13, 4))
	_add(&"emp_diffuse",     "EMP Diffuse",     [&"homing_diffuse"],                   [], {&"mat_copper": 300, &"mat_silicon": 100, &"mat_steel": 50}, Vector2(-11, 4))

func _register_support() -> void:
	_add(&"build_tower",                    "Build Tower",                    [&"core_bastion"],                  [], {&"mat_copper": 150, &"mat_steel": 50}, Vector2(-8, 6))
	_add(&"barrier_projector",              "Barrier Projector",              [&"core_bastion"],                  [], {&"mat_copper": 200, &"mat_steel": 80, &"mat_silicon": 40}, Vector2(-7, 6))
	_add(&"mender",                         "Mender",                         [&"core_bastion"],                  [], {&"mat_copper": 180, &"mat_steel": 60, &"mat_silicon": 50}, Vector2(-6, 6))
	_add(&"overdriver",                     "Overdriver",                     [&"core_bastion"],                  [], {&"mat_copper": 220, &"mat_steel": 70, &"mat_silicon": 45}, Vector2(-5, 6))
	_add(&"interplanetary_core_launchpad",  "Interplanetary Core Launchpad",  [&"core_bastion"],                  [], {&"mat_copper": 250, &"mat_steel": 120}, Vector2(-4, 6))
	_add(&"large_build_tower",              "Large Build Tower",              [&"build_tower"],                   [], {&"mat_copper": 250, &"mat_steel": 80, &"mat_graphite": 30}, Vector2(-8, 7))
	_add(&"force_field_projector",          "Force Field Projector",          [&"barrier_projector"],             [], {&"mat_copper": 400, &"mat_steel": 210, &"mat_silicon": 80}, Vector2(-7, 7))
	_add(&"mending_dome",                   "Mending Dome",                   [&"mender"],                        [], {&"mat_copper": 350, &"mat_steel": 170, &"mat_silicon": 70}, Vector2(-6, 7))
	_add(&"overdrive_dome",                 "Overdrive Dome",                 [&"overdriver"],                    [], {&"mat_copper": 380, &"mat_steel": 185, &"mat_silicon": 60}, Vector2(-5, 7))
	_add(&"launchpad",                      "Launchpad",                      [&"interplanetary_core_launchpad"], [], {&"mat_copper": 450, &"mat_steel": 230}, Vector2(-4, 7))
	_add(&"satellite_launchpad",            "Satellite Launchpad",            [&"interplanetary_core_launchpad"], [], {&"mat_copper": 500, &"mat_steel": 260, &"mat_graphite": 40}, Vector2(-3, 7))
	_add(&"huge_build_tower",               "Huge Build Tower",               [&"large_build_tower"],             [], {&"mat_copper": 400, &"mat_graphite": 50, &"mat_steel": 150}, Vector2(-8, 8))
	_add(&"shield_projector",               "Shield Projector",               [&"force_field_projector"],         [], {&"mat_copper": 800, &"mat_steel": 450, &"mat_silicon": 120}, Vector2(-7, 8))
	_add(&"mending_field",                  "Mending Field",                  [&"mending_dome"],                  [], {&"mat_copper": 650, &"mat_steel": 340, &"mat_silicon": 100}, Vector2(-6, 8))
	_add(&"overdrive_field",                "Overdrive Field",                [&"overdrive_dome"],                [], {&"mat_copper": 700, &"mat_steel": 380, &"mat_silicon": 110}, Vector2(-5, 8))
	_add(&"landing_pad",                    "Landing Pad",                    [&"launchpad"],                     [], {&"mat_copper": 600, &"mat_steel": 300, &"mat_graphite": 60}, Vector2(-4, 8))
	_add(&"interplanetary_launchpad",       "Interplanetary Launchpad",       [&"landing_pad"],                   [&"-L-the_nexus"], {&"mat_copper": 750, &"mat_steel": 440, &"mat_aluminum": 40}, Vector2(-4, 9))

func _register_units() -> void:
	_add(&"tank_fabricator",          "Tank Fabricator",          [&"core_shard"],                [], {&"mat_copper": 60}, Vector2(-25, 1))
	_add(&"ant",                      "Ant",                      [&"tank_fabricator"],           [], {&"mat_copper": 100}, Vector2(-28, 2))
	_add(&"beattle",                  "Beattle",                  [&"ant"],                       [&"unit_refabricator"], {&"mat_copper": 180, &"mat_steel": 60, &"mat_graphite": 20}, Vector2(-28, 3))
	_add(&"termite",                  "Termite",                  [&"beattle"],                   [&"unit_upgrader"], {&"mat_copper": 300, &"mat_steel": 130}, Vector2(-28, 4))
	_add(&"armadillo",                "Armadillo",                [&"beattle"],                   [&"unit_assembler"], {&"mat_copper": 350, &"mat_steel": 160}, Vector2(-28, 5))
	_add(&"turtle",                   "Turtle",                   [&"armadillo"],                 [&"unit_reassembler"], {&"mat_copper": 600, &"mat_steel": 280}, Vector2(-28, 6))
	# Crawler branch
	_add(&"crawler_fabricator",       "Crawler Fabricator",       [&"tank_fabricator"],           [&"-L-aluminum_mountains"], {&"mat_copper": 120, &"mat_silicon": 40}, Vector2(-29, 2))
	_add(&"geckeo",                   "Geckeo",                   [&"crawler_fabricator"],        [], {&"mat_copper": 250, &"mat_silicon": 80, &"mat_steel": 40}, Vector2(-29, 3))
	_add(&"lizard",                   "Lizard",                   [&"geckeo"],                    [&"unit_refabricator"], {&"mat_copper": 400, &"mat_silicon": 130, &"mat_steel": 80}, Vector2(-29, 4))
	_add(&"iguana",                   "Iguana",                   [&"lizard"],                    [&"unit_upgrader"], {&"mat_copper": 600, &"mat_silicon": 200, &"mat_steel": 150}, Vector2(-29, 5))
	_add(&"chameleon",                "Chameleon",                [&"iguana"],                    [&"unit_assembler"], {&"mat_copper": 800, &"mat_silicon": 300, &"mat_steel": 230}, Vector2(-29, 6))
	_add(&"moniter",                  "Moniter",                  [&"chameleon"],                 [&"unit_reassembler"], {&"mat_copper": 1200, &"mat_silicon": 450, &"mat_steel": 370, &"mat_aluminum": 30}, Vector2(-29, 7))
	# Support Hover branch
	_add(&"support_hover_fabricator", "Support Hover Fabricator", [&"tank_fabricator"],           [&"mat_steel"], {&"mat_copper": 110, &"mat_graphite": 35}, Vector2(-27, 2))
	_add(&"destroy_unit",             "Destroy",                  [&"support_hover_fabricator"],  [], {&"mat_copper": 200, &"mat_graphite": 60, &"mat_steel": 30}, Vector2(-27, 3))
	_add(&"rebuild",                  "Rebuild",                  [&"destroy_unit"],              [&"unit_refabricator"], {&"mat_copper": 300, &"mat_graphite": 100, &"mat_steel": 50}, Vector2(-27, 4))
	_add(&"assist",                   "Assist",                   [&"rebuild"],                   [&"unit_upgrader"], {&"mat_copper": 450, &"mat_graphite": 150, &"mat_steel": 105}, Vector2(-27, 5))
	_add(&"support",                  "Support",                  [&"assist"],                    [&"unit_assembler"], {&"mat_copper": 650, &"mat_graphite": 220, &"mat_steel": 170}, Vector2(-27, 6))
	_add(&"protect",                  "Protect",                  [&"support"],                   [&"unit_reassembler"], {&"mat_copper": 900, &"mat_graphite": 300, &"mat_steel": 270}, Vector2(-27, 7))
	# Hover branch
	_add(&"hover_fabricator",         "Hover Fabricator",         [&"tank_fabricator"],           [&"-L-crevice"], {&"mat_copper": 130}, Vector2(-26, 2))
	_add(&"hoverboard",               "Hoverboard",               [&"hover_fabricator"],          [], {&"mat_copper": 220, &"mat_graphite": 25}, Vector2(-26, 3))
	_add(&"hover_transport",          "Hover-transport",          [&"hoverboard"],                [&"unit_refabricator"], {&"mat_copper": 350, &"mat_silicon": 120, &"mat_steel": 40}, Vector2(-26, 4))
	_add(&"hoverlift",                "Hoverlift",                [&"hover_transport"],           [&"unit_upgrader"], {&"mat_copper": 500, &"mat_silicon": 180, &"mat_steel": 95}, Vector2(-26, 5))
	_add(&"hovercraft",               "Hovercraft",               [&"hoverlift"],                 [&"unit_assembler"], {&"mat_copper": 700, &"mat_silicon": 250, &"mat_steel": 165}, Vector2(-26, 6))
	_add(&"hovership",                "Hovership",                [&"hovercraft"],                [&"unit_reassembler"], {&"mat_copper": 1000, &"mat_silicon": 380, &"mat_steel": 250}, Vector2(-26, 7))
	# Ship branch
	_add(&"ship_fabricator",          "Ship Fabricator",          [&"tank_fabricator"],           [&"dark_valley"], {&"mat_copper": 140, &"mat_graphite": 40}, Vector2(-25, 2))
	_add(&"fly",                      "Fly",                      [&"ship_fabricator"],           [], {&"mat_copper": 230, &"mat_graphite": 70, &"mat_steel": 25}, Vector2(-25, 3))
	_add(&"moth",                     "Moth",                     [&"fly"],                       [&"unit_refabricator"], {&"mat_copper": 360, &"mat_graphite": 120, &"mat_steel": 50}, Vector2(-25, 4))
	_add(&"kestrel",                  "Kestrel",                  [&"moth"],                      [&"unit_upgrader"], {&"mat_copper": 520, &"mat_graphite": 180, &"mat_steel": 110}, Vector2(-25, 5))
	_add(&"hawk",                     "Hawk",                     [&"kestrel"],                   [&"unit_assembler"], {&"mat_copper": 750, &"mat_graphite": 260, &"mat_steel": 190}, Vector2(-25, 6))
	_add(&"eagle",                    "Eagle",                    [&"hawk"],                      [&"unit_reassembler"], {&"mat_copper": 1100, &"mat_graphite": 400, &"mat_steel": 300}, Vector2(-25, 7))
	# Unit Upgrader branch
	_add(&"unit_refabricator",        "Unit Refabricator",        [&"tank_fabricator"],           [&"mat_steel"], {&"mat_copper": 150, &"mat_silicon": 50}, Vector2(-24, 2))
	_add(&"unit_upgrader",            "Unit Upgrader",            [&"unit_refabricator"],         [&"Not unlockable in campaign"], {&"mat_copper": 280, &"mat_silicon": 90, &"mat_steel": 35}, Vector2(-24, 3))
	_add(&"unit_assembler",           "Unit Assembler",           [&"unit_upgrader"],             [], {&"mat_copper": 420, &"mat_silicon": 140, &"mat_steel": 80}, Vector2(-24, 4))
	_add(&"unit_reassembler",         "Unit Reassembler",         [&"unit_assembler"],            [&"-L-ruins"], {&"mat_copper": 580, &"mat_silicon": 200, &"mat_steel": 130}, Vector2(-24, 5))

func _register_payload_freight() -> void:
	_add(&"payload_conveyor",    "Payload Conveyor",    [&"tank_fabricator"],     [&"-D-archive_payload_systems"], {}, Vector2(-22, 2))
	_add(&"payload_router",      "Payload Router",      [&"payload_conveyor"],    [&"-D-archive_payload_systems"], {}, Vector2(-23, 3))
	_add(&"payload_junction",    "Payload Junction",    [&"payload_router"],      [&"-D-archive_payload_systems"], {}, Vector2(-23, 4))
	_add(&"payload_bridge",      "Payload Bridge",      [&"payload_junction"],    [&"-D-archive_payload_systems"], {}, Vector2(-23, 5))
	
	_add(&"freight_conveyor",    "Freight Conveyor",    [&"payload_conveyor"],    [&"-L-zinc_deposits"], {&"mat_copper": 1}, Vector2(-22, 3))
	_add(&"freight_router",      "Freight Router",      [&"freight_conveyor"],    [&"-L-zinc_deposits"], {&"mat_copper": 1}, Vector2(-22, 4))
	_add(&"freight_junction",    "Freight Junction",    [&"freight_router"],      [&"-L-zinc_deposits"], {&"mat_copper": 1}, Vector2(-22, 5))
	_add(&"freight_bridge",      "Freight Bridge",      [&"freight_junction"],    [&"-L-zinc_deposits"], {&"mat_copper": 1}, Vector2(-22, 6))
	
	_add(&"payload_mass_driver", "Payload Mass Driver", [&"tank_fabricator"],     [&"-D-archive_payload_systems"], {}, Vector2(-19, 2))
	_add(&"freight_mass_driver", "Freight Mass Driver", [&"payload_mass_driver"], [&"-L-zinc_deposits"], {&"mat_copper": 1}, Vector2(-19, 3))
	
	_add(&"payload_loader",      "Payload Loader",      [&"tank_fabricator"],     [&"-D-archive_payload_systems"], {}, Vector2(-21, 2))
	_add(&"payload_unloader",    "Payload Unloader",    [&"payload_loader"],      [&"-D-archive_payload_systems"], {}, Vector2(-21, 3))
	_add(&"freight_loader",      "Freight Loader",      [&"payload_loader"],      [&"-L-zinc_deposits"], {&"mat_copper": 1}, Vector2(-20, 3))
	_add(&"freight_unloader",    "Freight Unloader",    [&"freight_loader"],      [&"-L-zinc_deposits"], {&"mat_copper": 1}, Vector2(-20, 4))
	
	_add(&"constructor",         "Constructor",         [&"tank_fabricator"],     [&"-D-archive_payload_systems"], {}, Vector2(-18, 2))
	_add(&"deconstructor",       "Deconstructor",       [&"constructor"],         [&"-D-archive_payload_systems"], {}, Vector2(-18, 3))
	_add(&"payload_crane",       "Payload Crane",       [&"tank_fabricator"],     [&"-L-zinc_deposits"], {&"mat_copper": 1}, Vector2(-17, 2))
	_add(&"large_constructor",   "Large Constructor",   [&"deconstructor"],       [&"-L-zinc_deposits"], {&"mat_copper": 1}, Vector2(-18, 4))
	_add(&"large_deconstructor", "Large Deconstructor", [&"large_constructor"],   [&"-L-zinc_deposits"], {&"mat_copper": 1}, Vector2(-18, 5))

func _register_walls() -> void:
	# Copper tier (base)
	_add(&"copper_wall",         "Copper Wall",         [&"core_shard"],       [], {&"mat_copper": 30}, Vector2(-32, 1))
	_add(&"large_copper_wall",   "Large Copper Wall",   [&"copper_wall"],      [], {&"mat_copper": 45}, Vector2(-33, 1))
	_add(&"huge_copper_wall",    "Huge Copper Wall",    [&"large_copper_wall"],[&"Not unlockable in campaign"], {&"mat_copper": 65}, Vector2(-34, 1))
	_add(&"giant_copper_wall",   "Giant Copper Wall",   [&"huge_copper_wall"], [], {&"mat_copper": 100}, Vector2(-35, 1))
	# Steel tier
	_add(&"steel_wall",          "Steel Wall",          [&"copper_wall"],      [&"mat_steel"], {&"mat_copper": 60, &"mat_steel": 45}, Vector2(-32, 2))
	_add(&"large_steel_wall",    "Large Steel Wall",    [&"steel_wall"],       [], {&"mat_copper": 90, &"mat_steel": 67}, Vector2(-33, 2))
	_add(&"huge_steel_wall",     "Huge Steel Wall",     [&"large_steel_wall"], [&"Not unlockable in campaign"], {&"mat_copper": 135, &"mat_steel": 101}, Vector2(-34, 2))
	_add(&"giant_steel_wall",    "Giant Steel Wall",    [&"huge_steel_wall"],  [], {&"mat_copper": 200, &"mat_steel": 150}, Vector2(-35, 2))
	# Brass tier
	_add(&"brass_wall",          "Brass Wall",          [&"steel_wall"],       [&"Not unlockable in campaign"], {&"mat_copper": 80, &"mat_brass": 30, &"mat_steel": 20}, Vector2(-32, 3))
	_add(&"large_brass_wall",    "Large Brass Wall",    [&"brass_wall"],       [], {&"mat_copper": 120, &"mat_brass": 45, &"mat_steel": 30}, Vector2(-33, 3))
	_add(&"huge_brass_wall",     "Huge Brass Wall",     [&"large_brass_wall"], [], {&"mat_copper": 180, &"mat_brass": 68, &"mat_steel": 45}, Vector2(-34, 3))
	_add(&"giant_brass_wall",    "Giant Brass Wall",    [&"huge_brass_wall"],  [], {&"mat_copper": 270, &"mat_brass": 100, &"mat_steel": 68}, Vector2(-35, 3))
	# Aluminum tier
	_add(&"aluminum_wall",       "Aluminum Wall",       [&"brass_wall"],       [], {&"mat_copper": 100, &"mat_aluminum": 40, &"mat_steel": 25}, Vector2(-32, 4))
	_add(&"large_aluminum_wall", "Large Aluminum Wall", [&"aluminum_wall"],    [], {&"mat_copper": 150, &"mat_aluminum": 60, &"mat_steel": 38}, Vector2(-33, 4))
	_add(&"huge_aluminum_wall",  "Huge Aluminum Wall",  [&"large_aluminum_wall"],[], {&"mat_copper": 225, &"mat_aluminum": 90, &"mat_steel": 56}, Vector2(-34, 4))
	_add(&"giant_aluminum_wall", "Giant Aluminum Wall", [&"huge_aluminum_wall"],[], {&"mat_copper": 340, &"mat_aluminum": 135, &"mat_steel": 85}, Vector2(-35, 4))
	# Silver tier
	_add(&"silver_wall",         "Silver Wall",         [&"aluminum_wall"],    [], {&"mat_copper": 160, &"mat_silver": 60, &"mat_steel": 40}, Vector2(-32, 5))
	_add(&"large_silver_wall",   "Large Silver Wall",   [&"silver_wall"],      [], {&"mat_copper": 240, &"mat_silver": 90, &"mat_steel": 60}, Vector2(-33, 5))
	_add(&"huge_silver_wall",    "Huge Silver Wall",    [&"large_silver_wall"],[], {&"mat_copper": 360, &"mat_silver": 135, &"mat_steel": 90}, Vector2(-34, 5))
	_add(&"giant_silver_wall",   "Giant Silver Wall",   [&"huge_silver_wall"], [], {&"mat_copper": 540, &"mat_silver": 200, &"mat_steel": 135}, Vector2(-35, 5))

func _register_platforms() -> void:
	# Copper tier (base)
	_add(&"copper_platform",         "Copper Platform",         [&"core_shard"],           [&"Not unlockable in campaign"], {&"mat_copper": 25}, Vector2(-38, 1))
	_add(&"large_copper_platform",   "Large Copper Platform",   [&"copper_platform"],      [], {&"mat_copper": 38}, Vector2(-38, 2))
	_add(&"huge_copper_platform",    "Huge Copper Platform",    [&"large_copper_platform"],[], {&"mat_copper": 55}, Vector2(-38, 3))
	_add(&"giant_copper_platform",   "Giant Copper Platform",   [&"huge_copper_platform"], [], {&"mat_copper": 85}, Vector2(-38, 4))

## Archive nodes — each represents a recoverable archive. Decoding the
## matching archive in-world (Archive + Scanner + Decoder + power) auto-
## researches the node and any tech that depends on it via &"-D-archive_id".
## They live in their own branch to the right of the drill branch.
func _register_archives() -> void:
	# NOTE: the &"archive" and &"power_source" blocks are intentionally NOT
	# added to the tech tree. The build palette only gates blocks that exist
	# in the tree, so leaving them out makes them always available for testing.

	# Archive content nodes — placeholder set for testing.
	# Marked event_only so they CANNOT be researched manually; only the
	# archive_decoded signal flips them via _force_researched.
	# Marked hidden so they never render in the tech tree UI — they exist
	# only as research milestones that other tech depends on via -D-archive_id.
	_add(&"archive_payload_systems",   "Archive: Payload Systems",   [], [], {}, Vector2(30, -1), true)
	_add(&"archive_better_turrets", "Archive: Better Turrets", [], [], {}, Vector2(30, -2), true)
	_add(&"archive_better_units",  "Archive: Better Units",  [], [], {}, Vector2(30, -3), true)
	_add(&"archive_launch_systems",  "Archive: Launch Systems",  [], [], {}, Vector2(30, -3), true)
	_add(&"archive_interplanetary_launch_systems",  "Archive: Interplanetary Launch Systems",  [], [], {}, Vector2(30, -3), true)
	nodes[&"archive_payload_systems"]["hidden"] = true
	nodes[&"archive_better_turrets"]["hidden"] = true
	nodes[&"archive_better_units"]["hidden"] = true
	nodes[&"archive_launch_systems"]["hidden"] = true
	nodes[&"archive_interplanetary_launch_systems"]["hidden"] = true

	# Track archive ids so the -D- markers and archive_decoded rules get created.
	archive_ids = [
		&"archive_payload_systems",
		&"archive_better_turrets",
		&"archive_better_units",
		&"archive_launch_systems",
		&"archive_interplanetary_launch_systems",
	]
	# Auto-research the archive's own node when its archive is decoded in-world.
	for aid in archive_ids:
		_add_rule("archive_decoded", aid, aid)
