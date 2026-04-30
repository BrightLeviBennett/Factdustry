class_name SectorDefenseSim

# ============================================================
# SECTOR_DEFENSE_SIM.GD - Offline Sector Defense Calculator
# ============================================================
# When the player leaves a sector under attack, this computes
# how long the sector can survive without player intervention.
#
# Uses a layered attrition model:
#   1. Snapshot turret DPS, wall HP, core HP, enemy spawn rate
#   2. Compute net DPS balance at each defense layer
#   3. Calculate time for enemies to breach each layer
#   4. Sum = total time before sector falls
#
# Called by SaveManager when saving a sector that has enemies.
# Result is stored in the campaign save for PlanetSelect display.
# ============================================================


## Result of a defense simulation
class SimResult:
	## Total seconds before the sector falls. INF = sector is stable.
	var time_to_fall: float = INF
	## True if player defenses outmatch enemy spawns indefinitely.
	var is_stable: bool = true
	## Per-layer breakdown for UI display
	var layer_details: Array = []  # [{name, hp, dps, enemy_dps, time_to_breach}]
	## Summary string
	var summary: String = "Stable"


## Snapshot of a sector's defense state
class DefenseSnapshot:
	var turrets: Array = []      # [{grid_pos, block_id, dps, range_tiles, faction, hp}]
	var walls: Array = []        # [{grid_pos, block_id, hp, faction}]
	var cores: Array = []        # [{anchor, block_id, hp, faction}]
	var nests: Array = []        # [{position, spawn_unit_id, spawn_interval, spawn_count, unit_dps, unit_hp}]
	var player_units: Array = [] # [{unit_id, hp, dps}]
	var total_enemy_spawn_dps: float = 0.0
	var total_player_turret_dps: float = 0.0
	var total_wall_hp: float = 0.0
	var total_core_hp: float = 0.0


## Take a snapshot of the current sector's defense state.
static func snapshot_sector(main: Node2D) -> DefenseSnapshot:
	var snap := DefenseSnapshot.new()
	var unit_mgr = main.get_node_or_null("UnitManager")

	# --- Gather turrets ---
	var processed_turrets: Dictionary = {}
	for grid_pos in main.placed_buildings:
		var block_id: StringName = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null or not data.is_turret():
			continue
		var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if processed_turrets.has(anchor):
			continue
		processed_turrets[anchor] = true
		var faction: int = main.get_building_faction(grid_pos)
		# Skip inactive buildings (under construction, derelict)
		if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
			continue
		# Damage moved onto AmmoType entries — pick the highest-damage
		# round (the turret typically uses its strongest ammo when it
		# has stock) and account for projectiles_per_shot for shotgun-
		# style turrets. Falls back to 0 dps if no ammo configured.
		var per_shot_dmg: float = 0.0
		for ammo in data.ammo_types:
			if not (ammo is AmmoType):
				continue
			var a := ammo as AmmoType
			var d := a.damage * float(maxi(a.projectiles_per_shot, 1))
			if d > per_shot_dmg:
				per_shot_dmg = d
		var dps: float = per_shot_dmg / maxf(data.attack_speed, 0.1)
		var anchor_hp: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		var hp: float = main.building_health.get(anchor_hp, data.max_health)
		snap.turrets.append({
			"grid_pos": anchor,
			"block_id": block_id,
			"dps": dps,
			"range_tiles": data.attack_range,
			"faction": faction,
			"hp": hp,
		})
		if faction == main.Faction.LUMINA:
			snap.total_player_turret_dps += dps

	# --- Gather walls ---
	var processed_walls: Dictionary = {}
	for grid_pos in main.placed_buildings:
		var block_id: StringName = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null:
			continue
		if data.category != data.BlockCategory.WALLS:
			continue
		var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if processed_walls.has(anchor):
			continue
		processed_walls[anchor] = true
		var faction: int = main.get_building_faction(grid_pos)
		if faction != main.Faction.LUMINA:
			continue
		var hp: float = main.building_health.get(grid_pos, data.max_health)
		snap.walls.append({
			"grid_pos": anchor,
			"block_id": block_id,
			"hp": hp,
			"faction": faction,
		})
		snap.total_wall_hp += hp

	# --- Gather cores ---
	var processed_cores: Dictionary = {}
	for grid_pos in main.placed_buildings:
		var block_id: StringName = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null or not data.tags.has("core"):
			continue
		var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if processed_cores.has(anchor):
			continue
		processed_cores[anchor] = true
		var faction: int = main.get_building_faction(grid_pos)
		if faction != main.Faction.LUMINA:
			continue
		var hp: float = main.building_health.get(anchor, data.max_health)
		snap.cores.append({
			"anchor": anchor,
			"block_id": block_id,
			"hp": hp,
			"faction": faction,
		})
		snap.total_core_hp += hp

	# --- Gather enemy nests ---
	if unit_mgr:
		for nest in unit_mgr.nests:
			if not is_instance_valid(nest) or nest.is_dead:
				continue
			var unit_data = Registry.get_unit(nest.spawn_unit_id)
			var spawn_count: int = unit_data.spawn_count if unit_data else 3
			var unit_hp: float = unit_data.max_health if unit_data else 50.0
			var unit_dps: float = 0.0
			if unit_data and unit_data.attack_damage > 0:
				unit_dps = unit_data.attack_damage / maxf(unit_data.attack_speed, 0.1)
			snap.nests.append({
				"position": nest.position,
				"spawn_unit_id": nest.spawn_unit_id,
				"spawn_interval": nest.spawn_interval,
				"spawn_count": spawn_count,
				"unit_hp": unit_hp,
				"unit_dps": unit_dps,
			})
			# Enemy DPS reaching defenses per second:
			# (spawn_count / spawn_interval) * unit_dps
			var units_per_sec: float = float(spawn_count) / maxf(nest.spawn_interval, 1.0)
			snap.total_enemy_spawn_dps += units_per_sec * unit_dps

	# --- Gather player units ---
	if unit_mgr:
		for unit in unit_mgr.player_units:
			if not is_instance_valid(unit) or unit.is_dead:
				continue
			var unit_dps: float = 0.0
			if unit.data and unit.data.attack_damage > 0:
				unit_dps = unit.data.attack_damage / maxf(unit.data.attack_speed, 0.1)
			snap.player_units.append({
				"unit_id": unit.data.id if unit.data else &"unknown",
				"hp": unit.health if "health" in unit else 100.0,
				"dps": unit_dps,
			})
			snap.total_player_turret_dps += unit_dps  # Units contribute to defense

	return snap


## Run the defense simulation and return a SimResult.
static func simulate(snap: DefenseSnapshot) -> SimResult:
	var result := SimResult.new()

	# No enemies = stable
	if snap.nests.is_empty() or snap.total_enemy_spawn_dps <= 0.0:
		result.is_stable = true
		result.time_to_fall = INF
		result.summary = "No active threats"
		return result

	# --- Compute enemy HP spawned per second (for turret kill capacity) ---
	var enemy_hp_per_sec: float = 0.0
	for nest in snap.nests:
		var units_per_sec: float = float(nest["spawn_count"]) / maxf(nest["spawn_interval"], 1.0)
		enemy_hp_per_sec += units_per_sec * nest["unit_hp"]

	# --- Layer 1: Turrets vs Spawns (can turrets keep up?) ---
	# If turret DPS > enemy HP/s, turrets kill enemies before they accumulate
	var turret_kill_capacity: float = snap.total_player_turret_dps  # HP of enemies killed per second
	var enemy_overflow_dps: float = 0.0

	if turret_kill_capacity >= enemy_hp_per_sec:
		# Turrets can handle the spawn rate — sector is stable as long as turrets survive
		result.layer_details.append({
			"name": "Turret Defense",
			"hp": 0.0,
			"player_dps": turret_kill_capacity,
			"enemy_dps": snap.total_enemy_spawn_dps,
			"time_to_breach": INF,
		})
	else:
		# Some enemies get through — compute overflow
		# Fraction of enemies surviving = 1 - (turret_kill / enemy_hp_spawned)
		var kill_fraction: float = turret_kill_capacity / maxf(enemy_hp_per_sec, 0.001)
		var survival_fraction: float = 1.0 - kill_fraction
		enemy_overflow_dps = snap.total_enemy_spawn_dps * survival_fraction

		result.layer_details.append({
			"name": "Turret Defense",
			"hp": 0.0,
			"player_dps": turret_kill_capacity,
			"enemy_dps": snap.total_enemy_spawn_dps,
			"time_to_breach": 0.0,  # Enemies leak through immediately
		})

	if enemy_overflow_dps <= 0.0:
		result.is_stable = true
		result.time_to_fall = INF
		result.summary = "Defenses can hold indefinitely"
		return result

	# --- Layer 2: Walls absorb overflow damage ---
	var total_time: float = 0.0

	if snap.total_wall_hp > 0.0:
		var wall_time: float = snap.total_wall_hp / enemy_overflow_dps
		total_time += wall_time
		result.layer_details.append({
			"name": "Wall Defense",
			"hp": snap.total_wall_hp,
			"player_dps": 0.0,
			"enemy_dps": enemy_overflow_dps,
			"time_to_breach": wall_time,
		})

	# --- Layer 3: Turrets themselves can be destroyed ---
	# Once walls are gone, enemies attack turrets too
	var total_turret_hp: float = 0.0
	for t in snap.turrets:
		if t["faction"] == 0:  # LUMINA
			total_turret_hp += t["hp"]

	if total_turret_hp > 0.0:
		# As turrets die, DPS decreases — model as linear decay
		# Average effective DPS while turrets are dying = turret_kill_capacity / 2
		var avg_turret_dps_during_death: float = turret_kill_capacity * 0.5
		var effective_overflow: float = snap.total_enemy_spawn_dps - avg_turret_dps_during_death
		effective_overflow = maxf(effective_overflow, enemy_overflow_dps * 0.5)
		var turret_time: float = total_turret_hp / effective_overflow
		total_time += turret_time
		result.layer_details.append({
			"name": "Turret Structures",
			"hp": total_turret_hp,
			"player_dps": avg_turret_dps_during_death,
			"enemy_dps": effective_overflow,
			"time_to_breach": turret_time,
		})

	# --- Layer 4: Core takes direct damage ---
	if snap.total_core_hp > 0.0:
		# Once all defenses are gone, full enemy DPS hits core
		var core_time: float = snap.total_core_hp / snap.total_enemy_spawn_dps
		total_time += core_time
		result.layer_details.append({
			"name": "Core",
			"hp": snap.total_core_hp,
			"player_dps": 0.0,
			"enemy_dps": snap.total_enemy_spawn_dps,
			"time_to_breach": core_time,
		})

	result.is_stable = false
	result.time_to_fall = total_time
	result.summary = _format_time(total_time)
	return result


## Format seconds into a human-readable string.
static func _format_time(seconds: float) -> String:
	if seconds == INF:
		return "Stable"
	if seconds < 60:
		return "%d seconds" % int(seconds)
	if seconds < 3600:
		var mins: int = int(seconds / 60.0)
		var secs: int = int(seconds) % 60
		return "%dm %ds" % [mins, secs]
	var hours: int = int(seconds / 3600.0)
	var mins: int = int(fmod(seconds, 3600.0) / 60.0)
	return "%dh %dm" % [hours, mins]


## Convenience: snapshot + simulate in one call.
static func calculate_time_to_fall(main: Node2D) -> SimResult:
	var snap := snapshot_sector(main)
	return simulate(snap)
