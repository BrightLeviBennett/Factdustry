extends Node2D

# ============================================================
# POWER_SYSTEM.GD - Rotational & Electrical Power Networks
# ============================================================
# Manages two independent power network types:
#   1. ROTATIONAL: Transmitted via shafts (axial) and gearboxes
#      (3-way split). Vent turbines generate when on vent tiles.
#   2. ELECTRICAL: Framework for future use.
#
# NETWORK RULES:
#   - Two adjacent cells are connected if BOTH have a port facing
#     each other. Shafts only connect along their axis (front/back).
#     Gearboxes connect all 4 directions. Generators and consumers
#     connect all 4 directions.
#   - Networks are rebuilt whenever a building is placed or destroyed.
#   - A network is "powered" if total_gen >= total_use.
#
# LINKED BLOCKS (Overhead Belts):
#   - Blocks tagged "linkable" can be linked to each other.
#   - Linked pairs share their power network — power flows through
#     the link as if the two blocks were adjacent.
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
## Array of network dicts: { "cells": Array[Vector2i], "gen": float, "use": float, "powered": bool }
var rot_networks: Array = []
## Maps each cell → its rotational network index for O(1) lookup.
var rot_cell_to_net: Dictionary = {}

## Same for electrical networks.
var elec_networks: Array = []
var elec_cell_to_net: Dictionary = {}

## Linked block pairs: Array of [Vector2i, Vector2i] pairs.
## Linked blocks act as if adjacent for network connectivity.
var linked_pairs: Array = []

## Dirty flag — rebuild networks next frame instead of immediately.
var _networks_dirty := true


func _ready() -> void:
	await get_tree().process_frame
	main.building_placed.connect(_on_building_changed)
	main.building_destroyed.connect(_on_building_destroyed)
	_networks_dirty = true


func _process(_delta: float) -> void:
	if _networks_dirty:
		_rebuild_all_networks()
		_networks_dirty = false


# =========================
# PUBLIC API
# =========================

## Returns true if the building at grid_pos is in a rotational network
## with enough generation to cover all consumption.
func is_rotational_powered(grid_pos: Vector2i) -> bool:
	if not rot_cell_to_net.has(grid_pos):
		return false
	var net_idx: int = rot_cell_to_net[grid_pos]
	if net_idx < 0 or net_idx >= rot_networks.size():
		return false
	return rot_networks[net_idx]["powered"]


## Returns true if the building at grid_pos is in an electrical network
## with enough generation to cover all consumption.
func is_electrical_powered(grid_pos: Vector2i) -> bool:
	if not elec_cell_to_net.has(grid_pos):
		return false
	var net_idx: int = elec_cell_to_net[grid_pos]
	if net_idx < 0 or net_idx >= elec_networks.size():
		return false
	return elec_networks[net_idx]["powered"]


## Returns debug info about the network at grid_pos.
func get_rotational_network_info(grid_pos: Vector2i) -> Dictionary:
	if not rot_cell_to_net.has(grid_pos):
		return {"gen": 0.0, "use": 0.0, "powered": false, "cells": 0}
	var net_idx: int = rot_cell_to_net[grid_pos]
	var net = rot_networks[net_idx]
	return {
		"gen": net["gen"],
		"use": net["use"],
		"powered": net["powered"],
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

func _rebuild_all_networks() -> void:
	_rebuild_rotational_networks()
	_rebuild_electrical_networks()


func _rebuild_rotational_networks() -> void:
	rot_networks.clear()
	rot_cell_to_net.clear()

	var visited := {}

	for grid_pos in main.placed_buildings:
		if visited.has(grid_pos):
			continue
		var data = Registry.get_block(main.placed_buildings[grid_pos])
		if data == null or not data.is_rotational_power_block():
			continue

		# Flood-fill to discover this network
		var network_cells: Array[Vector2i] = []
		var queue: Array[Vector2i] = [grid_pos]
		visited[grid_pos] = true

		while queue.size() > 0:
			var pos: Vector2i = queue.pop_front()
			network_cells.append(pos)

			# Check 4 cardinal neighbors
			for dir_idx in range(4):
				var neighbor: Vector2i = pos + DIR_VECTORS[dir_idx]
				if visited.has(neighbor):
					continue
				if not main.placed_buildings.has(neighbor):
					continue
				var n_data = Registry.get_block(main.placed_buildings[neighbor])
				if n_data == null or not n_data.is_rotational_power_block():
					continue

				# Check directional connectivity: both sides must have a port
				var opposite_dir := (dir_idx + 2) % 4
				if _has_rot_port(pos, dir_idx) and _has_rot_port(neighbor, opposite_dir):
					visited[neighbor] = true
					queue.append(neighbor)

			# Check linked partners
			for pair in linked_pairs:
				var partner: Vector2i = Vector2i(-1, -1)
				if pair[0] == pos:
					partner = pair[1]
				elif pair[1] == pos:
					partner = pair[0]
				else:
					continue

				if visited.has(partner):
					continue
				if not main.placed_buildings.has(partner):
					continue
				var p_data = Registry.get_block(main.placed_buildings[partner])
				if p_data == null or not p_data.is_rotational_power_block():
					continue

				visited[partner] = true
				queue.append(partner)

		# Calculate power balance for this network
		var total_gen := 0.0
		var total_use := 0.0
		for cell in network_cells:
			if main.has_method("is_building_inactive") and main.is_building_inactive(cell):
				continue
			var d = Registry.get_block(main.placed_buildings[cell])
			if d:
				total_gen += _get_effective_rot_gen(cell, d)
				total_use += d.rotational_power_use

		var net_idx := rot_networks.size()
		rot_networks.append({
			"cells": network_cells,
			"gen": total_gen,
			"use": total_use,
			"powered": total_gen >= total_use,
		})
		for cell in network_cells:
			rot_cell_to_net[cell] = net_idx


func _rebuild_electrical_networks() -> void:
	elec_networks.clear()
	elec_cell_to_net.clear()

	var visited := {}

	for grid_pos in main.placed_buildings:
		if visited.has(grid_pos):
			continue
		var data = Registry.get_block(main.placed_buildings[grid_pos])
		if data == null or not data.is_electrical_power_block():
			continue

		var network_cells: Array[Vector2i] = []
		var queue: Array[Vector2i] = [grid_pos]
		visited[grid_pos] = true

		while queue.size() > 0:
			var pos: Vector2i = queue.pop_front()
			network_cells.append(pos)

			for dir_idx in range(4):
				var neighbor: Vector2i = pos + DIR_VECTORS[dir_idx]
				if visited.has(neighbor):
					continue
				if not main.placed_buildings.has(neighbor):
					continue
				var n_data = Registry.get_block(main.placed_buildings[neighbor])
				if n_data == null or not n_data.is_electrical_power_block():
					continue
				# Electrical blocks connect all 4 directions (for now)
				visited[neighbor] = true
				queue.append(neighbor)

			# Check linked partners for electrical too
			for pair in linked_pairs:
				var partner: Vector2i = Vector2i(-1, -1)
				if pair[0] == pos:
					partner = pair[1]
				elif pair[1] == pos:
					partner = pair[0]
				else:
					continue

				if visited.has(partner):
					continue
				if not main.placed_buildings.has(partner):
					continue
				var p_data = Registry.get_block(main.placed_buildings[partner])
				if p_data == null or not p_data.is_electrical_power_block():
					continue
				visited[partner] = true
				queue.append(partner)

		var total_gen := 0.0
		var total_use := 0.0
		for cell in network_cells:
			var d = Registry.get_block(main.placed_buildings[cell])
			if d:
				total_gen += d.electrical_power_gen
				total_use += d.electrical_power_use

		var net_idx := elec_networks.size()
		elec_networks.append({
			"cells": network_cells,
			"gen": total_gen,
			"use": total_use,
			"powered": total_gen >= total_use,
		})
		for cell in network_cells:
			elec_cell_to_net[cell] = net_idx


# =========================
# CONNECTION LOGIC
# =========================

## Returns true if the block at `pos` has a rotational power port
## facing the given direction index (0=right, 1=down, 2=left, 3=up).
func _has_rot_port(pos: Vector2i, dir_idx: int) -> bool:
	if not main.placed_buildings.has(pos):
		return false
	var data = Registry.get_block(main.placed_buildings[pos])
	if data == null:
		return false

	var rot: int = main.building_rotation.get(pos, 0)

	# Shafts transmit power in both directions regardless of facing
	if data.tags.has("shaft"):
		return true

	# Gearboxes connect all 4 directions (input from back, output to front+sides)
	if data.tags.has("gearbox"):
		return true  # All 4 directions

	# Linkable blocks (overhead belts) connect all 4 directions locally
	if data.tags.has("linkable"):
		return true

	# Generators and consumers connect all 4 directions
	if data.rotational_power_gen > 0 or data.rotational_power_use > 0:
		return true

	return false


## Returns the effective rotational power generation for a block,
## accounting for terrain conditions (e.g., vent_powered blocks on vents).
func _get_effective_rot_gen(grid_pos: Vector2i, data: BlockData) -> float:
	if data.rotational_power_gen <= 0:
		return 0.0

	# Blocks tagged "vent_powered" only generate when on a vent tile
	if data.tags.has("vent_powered"):
		if not _is_on_vent(grid_pos):
			return 0.0

	return data.rotational_power_gen


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
