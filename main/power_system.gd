extends Node2D

# ============================================================
# POWER_SYSTEM.GD - Electrical Power Networks
# ============================================================
# Manages electrical power networks.
#
# NETWORK RULES:
#   - Adjacent electrical blocks auto-connect on all 4 sides.
#   - Cable nodes / cable towers bridge over empty tiles up to their
#     configured range, connecting to the first electrical block along
#     each cardinal scanline.
#   - Linked pairs ("linkable" blocks like overhead belts) act as if
#     adjacent so they stitch two clusters into one network.
#   - Each network stores an efficiency = clamp(gen / max(use, eps), 0, 1).
#     Mindustry-style: when gen >= use every consumer runs at 100%; when
#     gen < use every consumer time-dilates uniformly to (gen / use), so
#     overdrawing just slows production instead of hard-stopping it.
#   - Blocks tagged "vent_powered" only produce their electrical_power_gen
#     when sitting on a vent floor tile.
#
# SCENE TREE: Place AFTER BuildingSystem.
#   Main
#   ├── ...
#   ├── BuildingSystem
#   ├── PowerSystem    ← this script
#   ├── LogisticsSystem
#   ├── ...
# ============================================================

@onready var main: Node2D = get_node("/root/Main")

# Direction constants (same as logistics_system.gd)
const DIR_VECTORS := [
	Vector2i(1, 0),   # 0 = right →
	Vector2i(0, 1),   # 1 = down  ↓
	Vector2i(-1, 0),  # 2 = left  ←
	Vector2i(0, -1),  # 3 = up    ↑
]

# --- NETWORK STATE ---
## Array of network dicts:
## { "cells": Array[Vector2i], "gen": float, "use": float,
##   "powered": bool, "efficiency": float }
var elec_networks: Array = []
## Maps each cell → its electrical network index for O(1) lookup.
var elec_cell_to_net: Dictionary = {}

## Linked block pairs: Array of [Vector2i, Vector2i] pairs.
## Linked blocks act as if adjacent for network connectivity.
var linked_pairs: Array = []

## Dirty flag — rebuild networks next frame instead of immediately.
var _networks_dirty := true

## Cable node connections discovered during the last network rebuild.
## Array of [Vector2i, Vector2i] pairs (cable_pos, target_pos).
## Used by BuildingSystem to draw connection lines.
var cable_connections: Array = []


func _ready() -> void:
	await get_tree().process_frame
	main.building_placed.connect(_on_building_changed)
	main.building_destroyed.connect(_on_building_destroyed)
	_networks_dirty = true


func _process(_delta: float) -> void:
	if _networks_dirty:
		_rebuild_electrical_networks()
		_networks_dirty = false


# =========================
# PUBLIC API
# =========================

## Returns true if the building at grid_pos is in an electrical network
## with enough generation to cover all consumption.
func is_electrical_powered(grid_pos: Vector2i) -> bool:
	if not elec_cell_to_net.has(grid_pos):
		return false
	var net_idx: int = elec_cell_to_net[grid_pos]
	if net_idx < 0 or net_idx >= elec_networks.size():
		return false
	return elec_networks[net_idx]["powered"]


## Efficiency (0..1) of the electrical network this cell belongs to. Callers
## that need to time-dilate production (drills, factories, turrets) multiply
## their delta by this value: 1.0 = full speed, 0.5 = half speed, 0.0 = idle.
## Blocks outside any electrical network return 1.0 so unaffected logic
## (e.g. blocks with electrical_power_use == 0) is never slowed.
func get_electrical_efficiency(grid_pos: Vector2i) -> float:
	if not elec_cell_to_net.has(grid_pos):
		return 1.0
	var net_idx: int = elec_cell_to_net[grid_pos]
	if net_idx < 0 or net_idx >= elec_networks.size():
		return 1.0
	return float(elec_networks[net_idx].get("efficiency", 1.0))


## Debug/HUD info about the network this cell belongs to.
func get_electrical_network_info(grid_pos: Vector2i) -> Dictionary:
	if not elec_cell_to_net.has(grid_pos):
		return {"gen": 0.0, "use": 0.0, "powered": false, "efficiency": 1.0, "cells": 0}
	var net_idx: int = elec_cell_to_net[grid_pos]
	var net = elec_networks[net_idx]
	return {
		"gen": net["gen"],
		"use": net["use"],
		"powered": net["powered"],
		"efficiency": float(net.get("efficiency", 1.0)),
		"cells": net["cells"].size(),
	}


## Links two blocks together (e.g., overhead belts).
## Linked blocks share power networks as if adjacent.
func link_blocks(pos_a: Vector2i, pos_b: Vector2i) -> void:
	# Don't add duplicate links
	for pair in linked_pairs:
		if (pair[0] == pos_a and pair[1] == pos_b) or \
		   (pair[0] == pos_b and pair[1] == pos_a):
			return
	linked_pairs.append([pos_a, pos_b])
	_networks_dirty = true


## Removes a link between two blocks.
func unlink_blocks(pos_a: Vector2i, pos_b: Vector2i) -> void:
	for i in range(linked_pairs.size() - 1, -1, -1):
		var pair = linked_pairs[i]
		if (pair[0] == pos_a and pair[1] == pos_b) or \
		   (pair[0] == pos_b and pair[1] == pos_a):
			linked_pairs.remove_at(i)
	_networks_dirty = true


## Returns the block this position is linked to, or null.
func get_linked_partner(grid_pos: Vector2i) -> Variant:
	for pair in linked_pairs:
		if pair[0] == grid_pos:
			return pair[1]
		if pair[1] == grid_pos:
			return pair[0]
	return null


# =========================
# NETWORK REBUILDING
# =========================

func _rebuild_electrical_networks() -> void:
	elec_networks.clear()
	elec_cell_to_net.clear()
	cable_connections.clear()

	# --- Phase 1: collect every electrical cell and cache its BlockData ---
	# Inactive cells (under construction, deconstructing, derelict) are
	# excluded entirely so they don't bridge power through themselves. A
	# half-built cable node must not transmit, and a pending consumer must
	# not appear in any network as powered. _networks_dirty is flipped when
	# a build completes or a decon is queued so the network rebuilds at
	# those transitions.
	var elec_cells: Array[Vector2i] = []
	var cell_data: Dictionary = {}  # Vector2i -> BlockData
	for grid_pos in main.placed_buildings:
		var data = Registry.get_block(main.placed_buildings[grid_pos])
		if data == null or not data.is_electrical_power_block():
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
			continue
		elec_cells.append(grid_pos)
		cell_data[grid_pos] = data

	# --- Phase 2: build an undirected adjacency map ---
	# Bugfix: the old single-pass BFS skipped already-visited cells when a
	# later cable reached into an earlier network, so two halves linked by
	# a cable could stay in separate networks (visible line, no power flow).
	# Building the full edge set up front sidesteps that by deferring
	# component labeling to a dedicated flood fill below.
	var adjacency: Dictionary = {}  # Vector2i -> Array[Vector2i]
	for cell in elec_cells:
		adjacency[cell] = []

	var _link_edge := func(a: Vector2i, b: Vector2i) -> void:
		if not adjacency.has(a) or not adjacency.has(b):
			return
		if a not in adjacency[b]:
			adjacency[b].append(a)
		if b not in adjacency[a]:
			adjacency[a].append(b)

	for pos in elec_cells:
		var pos_data: BlockData = cell_data[pos]
		var is_cable: bool = pos_data.tags.has("cable_node")
		var cable_range: int = 0
		if is_cable:
			cable_range = 10 if String(pos_data.id).begins_with("cable_tower") else 5

		for dir_idx in range(4):
			if is_cable and cable_range > 0:
				# Straight-line scan — connect to the nearest electrical block.
				# cable_range is the number of EMPTY tiles the cable can bridge,
				# so the reachable distance is cable_range + 1 tiles.
				for dist in range(1, cable_range + 2):
					var scan: Vector2i = pos + DIR_VECTORS[dir_idx] * dist
					if not main.placed_buildings.has(scan):
						continue
					if not cell_data.has(scan):
						continue  # Non-electrical building — keep scanning
					_link_edge.call(pos, scan)
					cable_connections.append([pos, scan])
					break
			else:
				var neighbor: Vector2i = pos + DIR_VECTORS[dir_idx]
				if cell_data.has(neighbor):
					_link_edge.call(pos, neighbor)

		# Linked partners (overhead belts etc.) always bridge networks.
		for pair in linked_pairs:
			var partner: Vector2i
			if pair[0] == pos:
				partner = pair[1]
			elif pair[1] == pos:
				partner = pair[0]
			else:
				continue
			if cell_data.has(partner):
				_link_edge.call(pos, partner)

	# --- Phase 3: flood fill connected components ---
	var visited: Dictionary = {}
	for start_pos in elec_cells:
		if visited.has(start_pos):
			continue
		var network_cells: Array[Vector2i] = []
		var queue: Array[Vector2i] = [start_pos]
		visited[start_pos] = true
		while queue.size() > 0:
			var pos: Vector2i = queue.pop_front()
			network_cells.append(pos)
			for adj in adjacency[pos]:
				if visited.has(adj):
					continue
				visited[adj] = true
				queue.append(adj)

		var total_gen := 0.0
		var total_use := 0.0
		var counted_anchors: Dictionary = {}
		for cell in network_cells:
			if main.has_method("is_building_inactive") and main.is_building_inactive(cell):
				continue
			# Multi-tile buildings register every cell of their footprint in
			# placed_buildings, so a 3x3 vent turbine would otherwise add its
			# gen 9 times. Dedupe by anchor so each building contributes once.
			var anchor_cell: Vector2i = main.building_origins.get(cell, cell)
			if counted_anchors.has(anchor_cell):
				continue
			counted_anchors[anchor_cell] = true
			var d: BlockData = cell_data[cell]
			total_gen += _get_effective_elec_gen(cell, d)
			total_use += d.electrical_power_use

		var net_idx := elec_networks.size()
		elec_networks.append({
			"cells": network_cells,
			"gen": total_gen,
			"use": total_use,
			"powered": total_gen >= total_use,
			"efficiency": _compute_efficiency(total_gen, total_use),
		})
		for cell in network_cells:
			elec_cell_to_net[cell] = net_idx


## Network efficiency in [0, 1]. When gen ≥ use the network runs at 100%;
## when demand exceeds supply every consumer is time-dilated uniformly to
## gen/use. Networks with no consumers return 1.0 so a standalone generator
## doesn't report 0% efficiency.
func _compute_efficiency(gen: float, use: float) -> float:
	if use <= 0.0:
		return 1.0
	return clampf(gen / use, 0.0, 1.0)


## Returns the effective electrical generation for a block, accounting for
## terrain conditions: vent_powered blocks only generate when sitting on a
## vent floor tile.
func _get_effective_elec_gen(grid_pos: Vector2i, data: BlockData) -> float:
	if data.electrical_power_gen <= 0.0:
		return 0.0
	if data.tags.has("vent_powered") and not _is_on_vent(grid_pos):
		return 0.0
	return data.electrical_power_gen


## Returns true if the given grid position is on a vent tile.
func _is_on_vent(grid_pos: Vector2i) -> bool:
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if terrain == null:
		return false

	# Check direct floor tile
	var tile = terrain.get_floor_at(grid_pos)
	if tile and tile.id == &"vent":
		return true

	# Check multi-tile origins (vent is 3x3)
	if terrain.multi_tile_origins.has(grid_pos):
		var origin: Vector2i = terrain.multi_tile_origins[grid_pos]
		tile = terrain.get_floor_at(origin)
		if tile and tile.id == &"vent":
			return true

	return false


# =========================
# SIGNAL HANDLERS
# =========================

func _on_building_changed(_block_id: StringName, _grid_pos: Vector2i) -> void:
	_networks_dirty = true


func _on_building_destroyed(_grid_pos: Vector2i) -> void:
	# Clean up any links involving the destroyed building
	for i in range(linked_pairs.size() - 1, -1, -1):
		var pair = linked_pairs[i]
		if pair[0] == _grid_pos or pair[1] == _grid_pos:
			linked_pairs.remove_at(i)
	_networks_dirty = true
