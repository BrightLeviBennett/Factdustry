class_name SectorProductionSim

# ============================================================
# SECTOR_PRODUCTION_SIM.GD — Offline Sector Resource Estimator
# ============================================================
# Snapshots a sector's expected resource-production rate (in
# items per second) so that SaveManager can accrue those
# resources while the player is away (other sectors / planet
# menu / closed game).
#
# Scope:
#   - Extractors / drills: rate = efficiency × power_eff × output/cycle_time
#   - Factories: net rate per item (output - input) scaled by power_eff.
#     Input-availability isn't simulated — SaveManager clamps the per-
#     sector pool at 0 when applying accrual so under-fed factories
#     don't drive stockpiles negative.
# ============================================================


## Computes {item_id: rate_per_second} for the currently-loaded sector.
## Reads efficiency (front-edge ore coverage) and power efficiency from
## the live scene so rates reflect the actual drill layout.
## Item ids that are intentionally excluded from offline accrual so their
## in-sector stockpiles don't drift away from reality while the player is
## away. The pattern is: mid-chain intermediates that are produced AND
## consumed by another block on the same factory floor. When the
## production rate balances the consumption rate the net is ~0 and the
## stockpile would stay flat — but the moment the balance tips
## negative (e.g. the player has more silicon refineries than graphite
## supply at the time of save) the offline calc drains the stockpile
## faster than live play actually would, since live play only consumes
## what's flowing on belts, not what's parked in core storage.
##   - mat_iron     → consumed by steel furnace
##   - mat_sand     → consumed by silicon mixer / glass etc.
##   - mat_graphite → consumed by silicon mixer
const EXCLUDED_ITEMS: Array[StringName] = [&"mat_iron", &"mat_sand", &"mat_graphite"]


static func calculate_rates(main: Node2D) -> Dictionary:
	var rates: Dictionary = {}
	if main == null:
		return rates

	var terrain = main.get_node_or_null("TerrainSystem")
	var power_sys = main.get_node_or_null("PowerSystem")
	var sector_script = main.get_node_or_null("SectorScript")
	if terrain == null:
		return rates

	var processed: Dictionary = {}
	for grid_pos in main.placed_buildings:
		var block_id: StringName = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null:
			continue
		if data.category != BlockData.BlockCategory.EXTRACTORS:
			continue

		var origin: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if processed.has(origin):
			continue
		processed[origin] = true

		# Skip non-player, disabled, or under-construction drills.
		if main.has_method("get_building_faction"):
			if main.get_building_faction(origin) != main.Faction.LUMINA:
				continue
		if sector_script and sector_script.has_method("is_building_disabled") \
				and sector_script.is_building_disabled(origin):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue

		var rot: int = 0
		if main.has_method("get") and main.get("building_rotation") != null:
			rot = int(main.building_rotation.get(origin, 0))

		var front_cells = _get_front_edge(origin, data.grid_size, rot)
		var mine_cells = _get_extended_front_edge(origin, data.grid_size, rot)

		var is_wall_miner: bool = data.tags.has("wall_miner")

		# Determine what this drill is mining + its per-front-cell hit count.
		var hit_count: int = 0
		var dir: Vector2i = _dir_vec(rot)
		var mined_item: StringName = &""
		if is_wall_miner:
			for cell in front_cells:
				var c1: bool = terrain.get_ore_at(cell) == null \
					and StringName(terrain.wall_tiles.get(cell, &"")) == &"blackstone_wall"
				var c2: bool = terrain.get_ore_at(cell + dir) == null \
					and StringName(terrain.wall_tiles.get(cell + dir, &"")) == &"blackstone_wall"
				if c1 or c2:
					hit_count += 1
		else:
			# Regular drill: find first ore in range to identify the resource.
			for cell in mine_cells:
				var ore = terrain.get_ore_at(cell)
				if ore != null and ore.minable_resource != &"":
					mined_item = ore.minable_resource
					break
			if mined_item == &"":
				continue
			for cell in front_cells:
				if terrain.get_ore_at(cell) != null:
					hit_count += 1
				elif terrain.get_ore_at(cell + dir) != null:
					hit_count += 1

		var front_count: int = front_cells.size()
		if front_count == 0 or hit_count == 0:
			continue
		var efficiency: float = float(hit_count) / float(front_count)

		var power_eff: float = 1.0
		if data.electrical_power_use > 0 and power_sys != null:
			power_eff = power_sys.get_electrical_efficiency(origin)
			if power_eff <= 0.0:
				continue

		var cycle_time: float = data.production_time if data.production_time > 0 else 2.0
		var cycles_per_sec: float = efficiency * power_eff / cycle_time

		if is_wall_miner:
			for raw_id in data.output_items:
				var k: StringName = StringName(raw_id)
				if EXCLUDED_ITEMS.has(k):
					continue
				var per_cycle: float = float(data.output_items[raw_id])
				rates[k] = rates.get(k, 0.0) + per_cycle * cycles_per_sec
		else:
			if not EXCLUDED_ITEMS.has(mined_item):
				rates[mined_item] = rates.get(mined_item, 0.0) + cycles_per_sec

	# --- Factories (furnaces, crushers, etc.): net rate = out - in, ---
	# optimistically assuming inputs are available. SaveManager clamps
	# sector pools at 0 on apply, so under-fed factories won't drive
	# stockpiles negative — they just contribute nothing until their
	# inputs catch up.
	var processed_fact: Dictionary = {}
	for grid_pos in main.placed_buildings:
		var block_id: StringName = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null:
			continue
		if data.category != BlockData.BlockCategory.FACTORIES:
			continue
		if data.output_items.is_empty() or data.production_time <= 0:
			continue
		# Unit fabricators produce units, not items — handled elsewhere.
		if data.produced_unit != &"":
			continue

		var origin: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if processed_fact.has(origin):
			continue
		processed_fact[origin] = true

		if main.has_method("get_building_faction") \
				and main.get_building_faction(origin) != main.Faction.LUMINA:
			continue
		if sector_script and sector_script.has_method("is_building_disabled") \
				and sector_script.is_building_disabled(origin):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(origin):
			continue

		var power_eff: float = 1.0
		if data.electrical_power_use > 0 and power_sys != null:
			power_eff = power_sys.get_electrical_efficiency(origin)
			if power_eff <= 0.0:
				continue

		var cycle_time: float = data.production_time
		var cycles_per_sec: float = power_eff / cycle_time

		for raw_id in data.output_items:
			var k: StringName = StringName(raw_id)
			if EXCLUDED_ITEMS.has(k):
				continue
			rates[k] = rates.get(k, 0.0) \
				+ float(data.output_items[raw_id]) * cycles_per_sec
		for raw_id in data.input_items:
			var k: StringName = StringName(raw_id)
			if EXCLUDED_ITEMS.has(k):
				continue
			rates[k] = rates.get(k, 0.0) \
				- float(data.input_items[raw_id]) * cycles_per_sec

	return rates


static func _dir_vec(rot: int) -> Vector2i:
	match rot:
		0: return Vector2i(1, 0)
		1: return Vector2i(0, 1)
		2: return Vector2i(-1, 0)
		3: return Vector2i(0, -1)
	return Vector2i(1, 0)


static func _get_front_edge(origin: Vector2i, gsz: Vector2i, rot: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	match rot:
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
	return cells


static func _get_extended_front_edge(origin: Vector2i, gsz: Vector2i, rot: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = _get_front_edge(origin, gsz, rot)
	var dir: Vector2i = _dir_vec(rot)
	var extended: Array[Vector2i] = []
	for c in cells:
		extended.append(c)
		extended.append(c + dir)
	return extended
