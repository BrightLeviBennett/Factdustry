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
##   "powered": bool, "efficiency": float,
##   "capacity": float, "stored": float, "battery_anchors": Array[Vector2i] }
## `stored` and `capacity` are derived from `_battery_stored` plus the
## per-block `electrical_power_storage` field; `battery_anchors` lets the
## per-frame charge/drain spread the change across the actual batteries
## so each one's individual reserve survives a topology rebuild.
var elec_networks: Array = []
# Per-anchor stored power (in power-seconds). Survives network
# rebuilds — when a wire is added/removed and the network re-walks, the
# rebuild reads this dict to seed each network's `stored` field. Cleared
# on building destroy (see _on_building_destroyed).
var _battery_stored: Dictionary = {}
# Per-anchor INTERNAL battery (in power-seconds). Independent of
# `_battery_stored` (which is the network-wide buffer contributed by
# explicit battery blocks). This is each block's own private reservoir
# (defaulted to 10B = 600 ps for any block with electrical_power_use > 0)
# that keeps the block running while detached from the network — carried
# by a crane, or during a brief brownout. Charges from network surplus
# at BATTERY_CHARGE_RATE; drains at the block's own consumption rate
# while detached.
var _block_internal_battery: Dictionary = {}

## 1B = 60 power-seconds (20 power × 3 s).
const BATTERY_UNIT_PS := 60.0
## Charge rate (power-seconds per real-world second) — fills 1B in 3 s.
const BATTERY_CHARGE_RATE := 20.0
## Default capacity in B units for blocks that consume power without an
## explicit `internal_battery_units` override.
const BATTERY_DEFAULT_UNITS := 10
# Per-anchor dynamic power-use override. When a block needs a draw that
# changes at runtime (mass driver weight, future variable-load
# machines, etc.) the owning system writes a value here and PowerSystem
# uses it instead of the static `electrical_power_use` for that anchor
# in every gen/use computation. `null`/missing entries fall back to the
# static field so most blocks need no extra plumbing.
var _dynamic_power_use: Dictionary = {}
## Maps each cell → its electrical network index for O(1) lookup.
var elec_cell_to_net: Dictionary = {}

## Linked block pairs: Array of [Vector2i, Vector2i] pairs.
## Linked blocks act as if adjacent for network connectivity.
var linked_pairs: Array = []

## Dirty flag — rebuild networks next frame instead of immediately.
var _networks_dirty := true

## Throttle for the per-frame activity recompute. Network *topology* only
## changes on placed/destroyed (flagged via `_networks_dirty`), but per-block
## "is this consumer actually working right now?" state changes every tick
## as drills fill up, factories swap phases, etc. We re-sum the gen/use
## totals a few times per second so the bar/efficiency stay live without
## doing the full flood-fill every frame.
var _activity_timer: float = 0.0
const _ACTIVITY_INTERVAL := 0.15

## Cable node connections discovered during the last network rebuild.
## Array of [Vector2i, Vector2i] pairs (cable_pos, target_pos).
## Used by BuildingSystem to draw connection lines.
var cable_connections: Array = []

# --- HISTORY SAMPLING (for the HUD's network info / graph) ---
# Networks rebuild whenever a power block is placed/destroyed and their
# array indices shift, so we key history by a stable "representative
# cell" (the smallest cell in the network). When a rebuild happens, the
# new network finds its history by re-deriving that key. Networks that
# truly disappear stop receiving samples and age out naturally as their
# entries fall off the 10-minute window.
const _HISTORY_WINDOW_SECONDS := 600.0
const _HISTORY_SAMPLE_INTERVAL := 1.0
var _history_timer: float = 0.0
var _network_history: Dictionary = {}  # Vector2i (rep cell) -> Array[{t, gen, use}]
# Per-block active-power history. Keyed by building anchor; each entry
# is an Array of `{t: float, p: float}` over the same 10-minute window.
# `p` is the block's effective draw / output at sample time (0 when
# inactive). Lets the HUD render a 10-minute icon stack on the
# network-wide power graph regardless of when the info panel was
# opened — the rows used to grow their own history only while visible,
# which is why the stack only went back ~2 min in practice.
var _block_history: Dictionary = {}  # Vector2i (anchor) -> Array[{t, p}]


## Returns the representative cell for the network containing grid_pos, or
## Vector2i(-9999,-9999) if no network covers it.
func _network_rep_cell(net: Dictionary) -> Vector2i:
	var best: Vector2i = Vector2i(2147483647, 2147483647)
	for cell in net.get("cells", []):
		if cell.y < best.y or (cell.y == best.y and cell.x < best.x):
			best = cell
	return best


## Public: returns the recent (gen,use,t) samples for the network the
## given cell belongs to. Empty array if not in any network.
func get_network_history(grid_pos: Vector2i) -> Array:
	if not elec_cell_to_net.has(grid_pos):
		return []
	var net_idx: int = elec_cell_to_net[grid_pos]
	if net_idx < 0 or net_idx >= elec_networks.size():
		return []
	var rep := _network_rep_cell(elec_networks[net_idx])
	return _network_history.get(rep, [])




func _sample_network_history(delta: float) -> void:
	_history_timer -= delta
	if _history_timer > 0.0:
		return
	_history_timer = _HISTORY_SAMPLE_INTERVAL
	# Use the HUD's pause-aware graph clock (matches the per-row
	# sparkline samples) so paused time doesn't appear in the X-axis
	# and a paused-then-unpaused session lines up correctly.
	var now: float = _graph_clock_now()
	var cutoff: float = now - _HISTORY_WINDOW_SECONDS
	var live_keys: Dictionary = {}
	for net in elec_networks:
		var rep := _network_rep_cell(net)
		if rep.x == 2147483647:
			continue
		live_keys[rep] = true
		var samples: Array = _network_history.get(rep, [])
		samples.append({
			"t": now,
			"gen": float(net.get("gen", 0.0)),
			"use": float(net.get("use", 0.0)),
			# Total stored power across every block in the network's
			# 10B internal-battery reservoirs, in B units (1B = 60 ps).
			"stored": _sum_internal_battery_units(net),
		})
		# Prune old samples (keep only the 10-minute window).
		while samples.size() > 0 and float(samples[0]["t"]) < cutoff:
			samples.pop_front()
		_network_history[rep] = samples
	# Also age out histories whose networks vanished — their last sample
	# is already older than the window, so we drop the whole entry once
	# everything has rolled off.
	for k in _network_history.keys():
		if live_keys.has(k):
			continue
		var samples2: Array = _network_history[k]
		while samples2.size() > 0 and float(samples2[0]["t"]) < cutoff:
			samples2.pop_front()
		if samples2.is_empty():
			_network_history.erase(k)
		else:
			_network_history[k] = samples2

	# --- Per-block active-power history (drives the network graph's
	# hover icon stack). Walks every electrical producer/consumer and
	# stamps its current output / draw, so the HUD doesn't have to
	# wait for the panel to be open to start collecting data. ---
	var live_anchors: Dictionary = {}
	for grid_pos in main.placed_buildings:
		if main.building_origins.get(grid_pos, grid_pos) != grid_pos:
			continue
		var data = Registry.get_block(main.placed_buildings[grid_pos])
		if data == null:
			continue
		if data.electrical_power_gen <= 0.0 and data.electrical_power_use <= 0.0:
			continue
		var anchor: Vector2i = grid_pos
		live_anchors[anchor] = true
		var active: bool = _is_block_active(anchor, data)
		var p: float = 0.0
		var e: float = 0.0
		if active:
			if data.electrical_power_gen > 0.0:
				p = _get_effective_elec_gen(anchor, data)
				if data.electrical_power_gen > 0.0:
					e = clampf(p / data.electrical_power_gen, 0.0, 1.0)
			else:
				p = _get_effective_elec_use(anchor, data)
				e = clampf(get_electrical_efficiency(anchor), 0.0, 1.0)
		var bs: Array = _block_history.get(anchor, [])
		bs.append({"t": now, "p": p, "e": e})
		while bs.size() > 0 and float(bs[0]["t"]) < cutoff:
			bs.pop_front()
		_block_history[anchor] = bs
	# Age out anchors that vanished.
	for k in _block_history.keys():
		if live_anchors.has(k):
			continue
		var bs2: Array = _block_history[k]
		while bs2.size() > 0 and float(bs2[0]["t"]) < cutoff:
			bs2.pop_front()
		if bs2.is_empty():
			_block_history.erase(k)
		else:
			_block_history[k] = bs2


## Returns the rolling per-block power samples (Array of {t, p}) for the
## building anchored at `anchor`. Empty array when the block isn't
## participating in any network or hasn't been observed long enough yet.
func get_block_history(anchor: Vector2i) -> Array:
	return _block_history.get(anchor, [])


## External hook for blocks whose power draw changes with state (e.g.
## the payload mass driver scales its draw with the loaded payload's
## weight). Call with the block's anchor + new draw in watts; pass 0
## or call `clear_dynamic_power_use(anchor)` to revert to the static
## `electrical_power_use` field. PowerSystem reads this map every time
## it tallies network usage.
func set_dynamic_power_use(anchor: Vector2i, watts: float) -> void:
	if watts <= 0.0:
		_dynamic_power_use.erase(anchor)
	else:
		_dynamic_power_use[anchor] = watts


func clear_dynamic_power_use(anchor: Vector2i) -> void:
	_dynamic_power_use.erase(anchor)


## Returns the effective draw for the block at `anchor` — dynamic
## override when one is registered, otherwise the BlockData baseline.
func _get_effective_elec_use(anchor: Vector2i, data: BlockData) -> float:
	if _dynamic_power_use.has(anchor):
		return float(_dynamic_power_use[anchor])
	return data.electrical_power_use


## Forwards to whatever activity helper the rest of the file uses to
## decide if a block should be counted in active totals. Falls back to
## `is_electrical_powered` when no helper is available so the history
## degrades gracefully instead of throwing.
func _is_block_active(anchor: Vector2i, data) -> bool:
	if has_method("_is_block_drawing_power"):
		return _is_block_drawing_power(anchor, data)
	return is_electrical_powered(anchor)


func _ready() -> void:
	await get_tree().process_frame
	# Defensive: the awaited frame can land mid-scene-swap, by which
	# point `main` (resolved via @onready) might be a freed instance.
	# Bail out instead of crashing on a null deref.
	if main == null or not is_instance_valid(main):
		return
	main.building_placed.connect(_on_building_changed)
	main.building_destroyed.connect(_on_building_destroyed)
	_networks_dirty = true


## Returns the HUD's pause-aware graph clock when available so all
## graph samples share one timeline; falls back to wall-clock seconds
## (for editor / standalone testing) when no HUD is in the tree.
func _graph_clock_now() -> float:
	var hud := get_node_or_null("/root/Main/HUD")
	if hud and "_network_graph_clock" in hud:
		return float(hud._network_graph_clock)
	return Time.get_ticks_msec() / 1000.0


func _process(delta: float) -> void:
	if _networks_dirty:
		_rebuild_electrical_networks()
		_networks_dirty = false
		# Align the "active" totals with topology immediately so there's
		# no one-frame flash of idle consumers being counted.
		_recompute_active_totals()
	# Periodic recompute of each network's gen/use so idle consumers stop
	# drawing power and resume drawing as soon as they start working again.
	_activity_timer -= delta
	if _activity_timer <= 0.0:
		_activity_timer = _ACTIVITY_INTERVAL
		_recompute_active_totals()
	# Freeze the rolling history AND the battery charge tick while paused
	# so an unattended save with surplus generation doesn't silently fill
	# every battery to the brim during a pause.
	if not ("world_paused" in main and main.world_paused):
		_tick_batteries(delta)
		_sample_network_history(delta)


# =========================
# PUBLIC API
# =========================

## Returns true if the building at grid_pos is in an electrical network
## with enough generation to cover all consumption.
## Returns the total internal-battery charge in B units across every
## anchor in `net`'s cells (deduped). 1B = 60 power-seconds; the
## network info panel + power graph display the result directly.
func _sum_internal_battery_units(net: Dictionary) -> float:
	var seen: Dictionary = {}
	var total_ps: float = 0.0
	for cell in net.get("cells", []):
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if seen.has(anchor):
			continue
		seen[anchor] = true
		total_ps += float(_block_internal_battery.get(anchor, 0.0))
	return total_ps / BATTERY_UNIT_PS




## Public accessor — total stored B in the network the cell belongs to,
## along with the matching capacity. Used by the HUD's network panel.
func get_network_total_internal_battery_units(grid_pos: Vector2i) -> Dictionary:
	if not elec_cell_to_net.has(grid_pos):
		return {"charge_b": 0.0, "capacity_b": 0.0}
	var net_idx: int = elec_cell_to_net[grid_pos]
	if net_idx < 0 or net_idx >= elec_networks.size():
		return {"charge_b": 0.0, "capacity_b": 0.0}
	var net: Dictionary = elec_networks[net_idx]
	var seen: Dictionary = {}
	var charge_ps: float = 0.0
	var cap_ps: float = 0.0
	for cell in net.get("cells", []):
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if seen.has(anchor):
			continue
		seen[anchor] = true
		var d: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if d == null:
			continue
		var c: float = resolve_block_battery_capacity(d)
		if c <= 0.0:
			continue
		cap_ps += c
		charge_ps += float(_block_internal_battery.get(anchor, 0.0))
	return {"charge_b": charge_ps / BATTERY_UNIT_PS, "capacity_b": cap_ps / BATTERY_UNIT_PS}


## Resolves the effective internal-battery capacity (in power-seconds)
## for a block, applying the auto-default for blocks that consume power
## without an explicit override.
func resolve_block_battery_capacity(data: BlockData) -> float:
	if data == null:
		return 0.0
	var units: int = data.internal_battery_units
	if units <= 0:
		if data.electrical_power_use > 0.0:
			units = BATTERY_DEFAULT_UNITS
		else:
			return 0.0
	return float(units) * BATTERY_UNIT_PS


## Current internal battery charge (in power-seconds) for a placed
## block. 0 if no battery / no charge.
func block_internal_battery_charge(grid_pos: Vector2i) -> float:
	return float(_block_internal_battery.get(grid_pos, 0.0))




## True if the block at `grid_pos` is powered, either by its electrical
## network OR by its own internal battery reserve.
func is_powered_or_battery(grid_pos: Vector2i) -> bool:
	if is_electrical_powered(grid_pos):
		return true
	return block_internal_battery_charge(grid_pos) > 0.0




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
	# Reject EXACT same-direction duplicates only. The reverse pair
	# (pos_b → pos_a) is a separate directional link — used by
	# bridges that support both an outgoing and an incoming partner.
	for pair in linked_pairs:
		if pair[0] == pos_a and pair[1] == pos_b:
			return
	linked_pairs.append([pos_a, pos_b])
	_networks_dirty = true


## Removes a link between two blocks (in either direction).
func unlink_blocks(pos_a: Vector2i, pos_b: Vector2i) -> void:
	for i in range(linked_pairs.size() - 1, -1, -1):
		var pair = linked_pairs[i]
		if (pair[0] == pos_a and pair[1] == pos_b) or \
		   (pair[0] == pos_b and pair[1] == pos_a):
			linked_pairs.remove_at(i)
	_networks_dirty = true


## Removes only the directional pair (pos_a → pos_b). Used by bridges,
## which can have separate links in each direction — unlinking the
## outgoing leg must not also kill the incoming one.
func unlink_directed(pos_a: Vector2i, pos_b: Vector2i) -> void:
	for i in range(linked_pairs.size() - 1, -1, -1):
		var pair = linked_pairs[i]
		if pair[0] == pos_a and pair[1] == pos_b:
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






## All destinations this position sends to (every pair where it's
## pair[0]). Empty array if none. Used by multi-output bridges
## (duct bridge supports up to 3 outgoing partners).
func get_links_as_source_all(grid_pos: Vector2i) -> Array:
	var out: Array = []
	for pair in linked_pairs:
		if pair[0] == grid_pos:
			out.append(pair[1])
	return out


## All sources this position receives from (every pair where it's
## pair[1]). Empty array if none. Used by multi-input bridges
## (duct bridge supports up to 3 incoming partners).
func get_links_as_destination_all(grid_pos: Vector2i) -> Array:
	var out: Array = []
	for pair in linked_pairs:
		if pair[1] == grid_pos:
			out.append(pair[0])
	return out


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

	# Each faction runs its own grid — LUMINA can't power a FEROX block by
	# laying cable next to it (or vice versa), and DERELICT acts as an
	# inert third party. Without this, a captured turret next to an
	# enemy generator would silently feed off the player's network (or
	# the other way round). Blocks of the same faction connect normally.
	var _same_faction := func(a: Vector2i, b: Vector2i) -> bool:
		if main.has_method("get_building_faction"):
			return main.get_building_faction(a) == main.get_building_faction(b)
		return true

	var _link_edge := func(a: Vector2i, b: Vector2i) -> void:
		if not adjacency.has(a) or not adjacency.has(b):
			return
		if not _same_faction.call(a, b):
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
				# so the reachable distance is cable_range + 1 tiles. Cross-
				# faction blocks are skipped (and don't terminate the scan)
				# so a player cable can reach past an enemy generator to a
				# friendly node further down the line.
				for dist in range(1, cable_range + 2):
					var scan: Vector2i = pos + DIR_VECTORS[dir_idx] * dist
					if not main.placed_buildings.has(scan):
						continue
					if not cell_data.has(scan):
						continue  # Non-electrical building — keep scanning
					if not _same_faction.call(pos, scan):
						continue
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
		var total_capacity := 0.0
		var total_stored := 0.0
		var battery_anchors: Array[Vector2i] = []
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
			total_use += _get_effective_elec_use(anchor_cell, d)
			# Battery contribution: capacity + carried-over stored amount.
			if d.electrical_power_storage > 0.0:
				total_capacity += d.electrical_power_storage
				var carried: float = clampf(float(_battery_stored.get(anchor_cell, 0.0)),
					0.0, d.electrical_power_storage)
				_battery_stored[anchor_cell] = carried
				total_stored += carried
				battery_anchors.append(anchor_cell)

		var net_idx := elec_networks.size()
		var powered: bool = total_gen >= total_use or (total_stored > 0.0 and total_capacity > 0.0)
		elec_networks.append({
			"cells": network_cells,
			"gen": total_gen,
			"use": total_use,
			"capacity": total_capacity,
			"stored": total_stored,
			"battery_anchors": battery_anchors,
			"powered": powered,
			"efficiency": _compute_efficiency_with_storage(total_gen, total_use, total_stored, total_capacity),
		})
		for cell in network_cells:
			elec_cell_to_net[cell] = net_idx


func _compute_efficiency_with_storage(gen: float, use: float, stored: float, capacity: float) -> float:
	if use <= 0.0:
		return 1.0
	if gen >= use:
		return 1.0
	if capacity > 0.0 and stored > 0.0:
		return 1.0
	return clampf(gen / use, 0.0, 1.0)


## Per-frame battery charge/drain. Surplus (`gen > use`) charges the
## network's batteries; deficit drains them. Each network's `stored`
## field is updated, and the change is distributed across the batteries
## proportionally so individual `_battery_stored[anchor]` values track
## the network's total.
func _tick_batteries(delta: float) -> void:
	if delta <= 0.0:
		return
	_tick_block_internal_batteries(delta)
	for net in elec_networks:
		var capacity: float = float(net.get("capacity", 0.0))
		if capacity <= 0.0:
			continue
		var stored: float = float(net.get("stored", 0.0))
		var net_flow: float = float(net.get("gen", 0.0)) - float(net.get("use", 0.0))
		var new_stored: float = clampf(stored + net_flow * delta, 0.0, capacity)
		var actual_change: float = new_stored - stored
		net["stored"] = new_stored
		# Refresh efficiency now that storage state may have shifted —
		# without this a freshly-empty buffer keeps reading 100% until
		# the next activity recompute.
		net["efficiency"] = _compute_efficiency_with_storage(
			float(net["gen"]), float(net["use"]), new_stored, capacity)
		net["powered"] = float(net["gen"]) >= float(net["use"]) or new_stored > 0.0
		var anchors: Array = net.get("battery_anchors", [])
		if anchors.is_empty() or actual_change == 0.0:
			continue
		# Spread the change across batteries proportionally to their
		# remaining headroom (when charging) or remaining stock (when
		# draining), so the smaller batteries don't get stuck at
		# extremes while the big one carries everything.
		var weights: PackedFloat32Array = PackedFloat32Array()
		weights.resize(anchors.size())
		var total_w: float = 0.0
		for i in range(anchors.size()):
			var a: Vector2i = anchors[i]
			var d: BlockData = Registry.get_block(main.placed_buildings.get(a, &""))
			if d == null:
				weights[i] = 0.0
				continue
			var cur: float = float(_battery_stored.get(a, 0.0))
			var w: float = (d.electrical_power_storage - cur) if actual_change > 0.0 else cur
			weights[i] = maxf(w, 0.0)
			total_w += weights[i]
		if total_w <= 0.0:
			continue
		for i in range(anchors.size()):
			var a2: Vector2i = anchors[i]
			var d2: BlockData = Registry.get_block(main.placed_buildings.get(a2, &""))
			if d2 == null:
				continue
			var share: float = actual_change * (weights[i] / total_w)
			_battery_stored[a2] = clampf(
				float(_battery_stored.get(a2, 0.0)) + share,
				0.0, d2.electrical_power_storage)


## Per-frame charge for every placed block's private internal battery.
##   - When the cell is powered AND battery isn't full: charge by
##     BATTERY_CHARGE_RATE × delta (capped at capacity).
##   - When the cell is unpowered AND the block has consumption: drain
##     at `electrical_power_use` × delta down to 0. Consumers that want
##     to "fall through" to battery during a brownout call
##     `is_powered_or_battery` and the drain is handled here uniformly.
##   - Blocks without consumption (cable nodes etc.) just hold their
##     last charge.
func _tick_block_internal_batteries(delta: float) -> void:
	# Only iterate placed-building anchors so we don't repeat work for
	# each tile of a multi-tile block. Track which anchors we've seen.
	var seen: Dictionary = {}
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if seen.has(anchor):
			continue
		seen[anchor] = true
		var d: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if d == null:
			continue
		var cap: float = resolve_block_battery_capacity(d)
		if cap <= 0.0:
			continue
		var cur: float = float(_block_internal_battery.get(anchor, 0.0))
		if is_electrical_powered(anchor):
			# Charge from network surplus.
			if cur < cap:
				cur = minf(cap, cur + BATTERY_CHARGE_RATE * delta)
		else:
			# Brownout / disconnected. Drain to keep the block alive.
			if d.electrical_power_use > 0.0 and cur > 0.0:
				cur = maxf(0.0, cur - d.electrical_power_use * delta)
		_block_internal_battery[anchor] = cur


## Lightweight rewalk of each network's cells to sum gen/use counting only
## currently-active consumers (_is_block_drawing_power). Called on a ~0.15s
## timer so a drill with full storage stops dragging the bar down the moment
## it stalls, and starts again the moment its storage drains.
func _recompute_active_totals() -> void:
	for net in elec_networks:
		var total_gen := 0.0
		var total_use := 0.0
		var counted_anchors: Dictionary = {}
		for cell in net["cells"]:
			if main.has_method("is_building_inactive") and main.is_building_inactive(cell):
				continue
			var anchor: Vector2i = main.building_origins.get(cell, cell)
			if counted_anchors.has(anchor):
				continue
			counted_anchors[anchor] = true
			var d: BlockData = Registry.get_block(main.placed_buildings.get(cell, &""))
			if d == null:
				continue
			total_gen += _get_effective_elec_gen(cell, d)
			if _is_block_drawing_power(anchor, d):
				total_use += _get_effective_elec_use(anchor, d)
		net["gen"] = total_gen
		net["use"] = total_use
		var stored: float = float(net.get("stored", 0.0))
		var capacity: float = float(net.get("capacity", 0.0))
		net["powered"] = total_gen >= total_use or stored > 0.0
		net["efficiency"] = _compute_efficiency_with_storage(total_gen, total_use, stored, capacity)


## Returns true if the block at `anchor` is currently doing work that would
## draw its `electrical_power_use`. Drills with full output storage stop
## drawing. Factories / fabricators / refabricators only draw while in
## their "processing" phase. Other consumers (turrets, etc.) always draw
## so scans, tracking, etc. stay responsive.
func _is_block_drawing_power(anchor: Vector2i, data: BlockData) -> bool:
	if data.electrical_power_use <= 0.0:
		return false
	# Sector-scripted disables turn the block fully off.
	var sector = get_node_or_null("/root/Main/SectorScript")
	if sector and sector.has_method("is_building_disabled") and sector.is_building_disabled(anchor):
		return false
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	if logistics == null:
		return true

	# Drills / extractors / fluid pumps: idle when storage is full (nothing
	# to mine into / nowhere to push fluid). Pumps live in the FLUIDS
	# category rather than EXTRACTORS, so check the tag too.
	if data.category == BlockData.BlockCategory.EXTRACTORS or data.tags.has("pump"):
		if logistics.has_method("_is_storage_full") and logistics._is_storage_full(anchor, data):
			return false
		return true

	# Refabricators: consume only while actually processing a unit.
	if data.tags.has("refabricator"):
		if "refabricator_state" in logistics and logistics.refabricator_state.has(anchor):
			return logistics.refabricator_state[anchor].get("phase", "") == "processing"
		return false

	# Regular factories / unit fabricators: consume only while in the
	# processing/ejecting phase. Collecting-with-no-inputs counts as idle.
	var is_factory: bool = not data.output_items.is_empty() or data.produced_unit != &""
	if is_factory:
		if "factory_buffers" in logistics and logistics.factory_buffers.has(anchor):
			var phase: String = logistics.factory_buffers[anchor].get("phase", "")
			return phase == "processing" or phase == "ejecting"
		return false

	# Default: always drawing (turrets, misc active blocks).
	return true


## Returns the effective electrical generation for a block, accounting for
## terrain conditions and fuel state. Vent-powered blocks need a vent
## tile under them. Fuel-powered blocks (combustion generator) only
## generate while their factory loop is in the "processing" phase —
## i.e. while they have at least one fuel item buffered and consuming.
func _get_effective_elec_gen(grid_pos: Vector2i, data: BlockData) -> float:
	if data.electrical_power_gen <= 0.0:
		return 0.0
	if data.tags.has("vent_powered") and not _is_on_vent(grid_pos):
		return 0.0
	if data.tags.has("fuel_powered"):
		var logistics = get_node_or_null("/root/Main/LogisticsSystem")
		if logistics == null:
			return 0.0
		var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if not ("factory_buffers" in logistics) or not logistics.factory_buffers.has(anchor):
			return 0.0
		var phase: String = String(logistics.factory_buffers[anchor].get("phase", ""))
		# Output during both processing (burning fuel) and outputting
		# (the brief intra-cycle settlement step) — without the second,
		# the generator visibly blinks to 0 power between fuel ticks.
		if phase != "processing" and phase != "outputting":
			return 0.0
	# Nuclear reactors only generate while the dedicated reactor system
	# has them in an active fuel cycle — without fuel rods OR after a
	# coolant-loss shutdown, the 500-power output drops to 0.
	if data.tags.has("nuclear_reactor"):
		var nuc = get_node_or_null("/root/Main/NuclearReactorSystem")
		if nuc == null:
			return 0.0
		var nuc_anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if not nuc.is_reactor_active(nuc_anchor):
			return 0.0
	# Sun-deprived sectors (Nightfall Depths, Dark Valley) starve solar
	# AND vent-driven generators of their full output — vent turbines
	# only manage 40 power instead of the usual 120 there. Lore: the
	# whole side of the planet sees almost no sun, so the vents run
	# colder / weaker. Other generator types are unaffected.
	if data.id == &"vent_turbine":
		var sid: StringName = SaveManager.active_sector_id
		if sid == &"nightfall_depths" or sid == &"dark_valley":
			return 40.0
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
	# Drop any dynamic-power override the block had registered.
	_dynamic_power_use.erase(_grid_pos)
	# Drop any stored battery charge for the destroyed anchor — survival
	# across rebuilds is intentional, but a destroyed battery's charge is
	# gone for good (no salvage refund).
	_battery_stored.erase(_grid_pos)
	# Per-block internal battery is bound to the placement; gone with it.
	_block_internal_battery.erase(_grid_pos)
	_networks_dirty = true
