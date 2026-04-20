extends Node2D

# ============================================================
# COMBAT_SYSTEM.GD - Projectiles, Turrets, and Combat
# ============================================================
# Handles ALL combat in the game:
#
#   1. TURRETS: Defense buildings auto-target the nearest enemy
#      in range and fire projectiles at them.
#   2. PLAYER DRONE: Left-click (with no building selected) to
#      shoot the nearest enemy in range.
#   3. RANGED ENEMIES: Enemy units with attack_range > 0 fire
#      projectiles at buildings instead of walking up and punching.
#
# PROJECTILE LIFECYCLE:
#   - Spawned with a position, target, speed, damage, and color.
#   - Every frame, moves toward the target.
#   - On arrival (within hit_radius), deals damage and is removed.
#   - If the target is destroyed mid-flight, the projectile
#     continues to the last known position, then fizzles out.

@onready var main: Node2D = get_node("/root/Main")

# Cached sibling references (populated in _ready).
var _unit_mgr: Node
var _drone: Node2D
var _terrain: Node2D
var _building_sys: Node
var _sector_script: Node
var _logistics: Node2D

# --- PROJECTILE DATA ---
# Each projectile is a Dictionary with these keys:
#   "pos"       : Vector2  — current world position
#   "target_pos": Vector2  — where it's heading (updated if target moves)
#   "target_ref": Variant  — reference to enemy Node2D or grid_pos Vector2i
#   "target_type": String  — "enemy", "building", or "drone"
#   "speed"     : float    — pixels per second
#   "damage"    : float    — damage dealt on hit
#   "color"     : Color    — projectile color
#   "radius"    : float    — visual size
#   "source"    : String   — "turret", "drone", or "enemy" (for filtering)
#   "aoe"       : bool     — does it explode on impact?
#   "aoe_radius": float    — explosion radius in pixels
var projectiles: Array[Dictionary] = []

# --- TURRET STATE ---
# Key = Vector2i grid pos of a turret, Value = float (cooldown remaining)
var turret_cooldowns := {}

# Key = Vector2i grid pos of a turret, Value = float (current angle in radians)
var turret_angles := {}

# --- MANUAL CONTROL ---
## Set by UnitManager when the player manually controls a turret (Ctrl+click).
## When set, that turret skips auto-targeting and is aimed/fired by the player.
var manually_controlled_turret: Variant = null  # Vector2i or null

# --- DRONE COMBAT ---
## Drone's attack damage per shot
@export var drone_damage := 15.0
## Drone's attack range in grid tiles
@export var drone_range := 4.0
## Seconds between drone shots
@export var drone_attack_speed := 0.3
## Drone projectile speed in pixels/sec
@export var drone_projectile_speed := 600.0

var drone_cooldown := 0.0
var drone_is_shooting := false

# --- PROJECTILE SETTINGS ---
## How close a projectile must be to its target to "hit" (in pixels)
@export var hit_radius := 12.0
## Default projectile speed for turrets
@export var default_projectile_speed := 400.0

# --- TRAIL SETTINGS ---
## How many past positions to store for each projectile's trail
const TRAIL_LENGTH := 4

# --- THREADING ---
var _targeting_worker: TargetingWorker
## Cached turret scan results from the worker thread (keyed by grid_pos)
var _turret_targets: Dictionary = {}  # Vector2i -> Dictionary
## Cached unit scan results from the worker thread (keyed by unit instance ID)
var unit_target_results: Dictionary = {}  # int -> Dictionary



func _unit_mgr_ref() -> Node:
	if _unit_mgr == null:
		_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	return _unit_mgr

func _drone_ref() -> Node2D:
	if _drone == null:
		_drone = get_node_or_null("/root/Main/PlayerDrone")
	return _drone

func _terrain_ref() -> Node2D:
	if _terrain == null:
		_terrain = get_node_or_null("/root/Main/TerrainSystem")
	return _terrain

func _building_sys_ref() -> Node:
	if _building_sys == null:
		_building_sys = get_node_or_null("/root/Main/BuildingSystem")
	return _building_sys

func _sector_script_ref() -> Node:
	if _sector_script == null:
		_sector_script = get_node_or_null("/root/Main/SectorScript")
	return _sector_script

func _logistics_ref() -> Node2D:
	if _logistics == null:
		_logistics = get_node_or_null("/root/Main/LogisticsSystem")
	return _logistics


func _ready() -> void:
	await get_tree().process_frame
	_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	_drone = get_node_or_null("/root/Main/PlayerDrone")
	_terrain = get_node_or_null("/root/Main/TerrainSystem")
	_building_sys = get_node_or_null("/root/Main/BuildingSystem")
	_sector_script = get_node_or_null("/root/Main/SectorScript")
	_logistics = get_node_or_null("/root/Main/LogisticsSystem")
	main.building_placed.connect(_on_building_placed)
	main.building_destroyed.connect(_on_building_destroyed)
	_targeting_worker = TargetingWorker.new()
	_targeting_worker.start()


func _exit_tree() -> void:
	if _targeting_worker:
		_targeting_worker.stop()
		_targeting_worker = null


func _process(delta: float) -> void:
	if ("world_paused" in main and main.world_paused):
		queue_redraw()
		return
	_poll_targeting_results()
	_push_targeting_snapshot()
	_update_turrets(delta)
	_update_drone_combat(delta)
	_update_projectiles(delta)
	queue_redraw()


func _poll_targeting_results() -> void:
	if _targeting_worker == null:
		return
	var turret_results := _targeting_worker.poll_turret_results()
	if turret_results.size() > 0:
		_turret_targets.clear()
		for r in turret_results:
			_turret_targets[r["grid_pos"]] = r
	var unit_results := _targeting_worker.poll_unit_results()
	if unit_results.size() > 0:
		unit_target_results.clear()
		for r in unit_results:
			unit_target_results[r["unit_id"]] = r


func _push_targeting_snapshot() -> void:
	if _targeting_worker == null:
		return

	var unit_mgr = _unit_mgr_ref()
	if unit_mgr == null:
		return

	# Build enemy snapshot
	var enemies_snap: Array = []
	for e in unit_mgr.enemies:
		if is_instance_valid(e):
			enemies_snap.append({
				"id": e.get_instance_id(),
				"pos": e.position,
				"is_dead": e.is_dead,
				"unit_size": e.unit_size,
			})

	# Build player unit snapshot
	var player_snap: Array = []
	for u in unit_mgr.player_units:
		if is_instance_valid(u):
			player_snap.append({
				"id": u.get_instance_id(),
				"pos": u.position,
				"is_dead": u.is_dead,
				"unit_size": u.unit_size,
			})

	# Build turret list
	var turrets_snap: Array = []
	for grid_pos in main.placed_buildings:
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null or not data.is_turret():
			continue
		if grid_pos == manually_controlled_turret:
			continue
		# Skip disabled or under-construction buildings
		var sector_script = _sector_script_ref()
		if sector_script and sector_script.is_building_disabled(grid_pos):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
			continue
		var turret_faction: int = main.get_building_faction(grid_pos)
		turrets_snap.append({
			"grid_pos": grid_pos,
			"faction": turret_faction,
			"range_pixels": data.attack_range * main.GRID_SIZE,
			"block_id": block_id,
		})

	# Build idle player units list (for auto-target scanning)
	var idle_units_snap: Array = []
	for u in unit_mgr.player_units:
		if not is_instance_valid(u) or u.is_dead or u.is_controlled:
			continue
		if u.move_target != null:
			continue
		if u.target_unit != null or u.target_building != null:
			continue
		var detect_range: float = u.data.detection_range if u.data else 500.0
		idle_units_snap.append({
			"id": u.get_instance_id(),
			"pos": u.position,
			"detect_range": detect_range,
		})

	_targeting_worker.push_snapshot({
		"enemies": enemies_snap,
		"player_units": player_snap,
		"buildings": main.placed_buildings.duplicate(),
		"factions": main.building_factions.duplicate(),
		"origins": main.building_origins.duplicate(),
		"turrets": turrets_snap,
		"idle_player_units": idle_units_snap,
		"grid_size": main.GRID_SIZE,
	})


# =========================
# TURRET AI
# =========================

func _update_turrets(delta: float) -> void:
	var unit_mgr = _unit_mgr_ref()
	if unit_mgr == null:
		return

	for grid_pos in main.placed_buildings:
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null or not data.is_turret():
			continue

		# Skip turrets being manually controlled by the player
		if grid_pos == manually_controlled_turret:
			continue

		# Initialize state for new turrets
		if not turret_cooldowns.has(grid_pos):
			turret_cooldowns[grid_pos] = 0.0
		if not turret_angles.has(grid_pos):
			turret_angles[grid_pos] = 0.0

		# Electrical power: scale the cooldown countdown by network
		# efficiency, so an over-drawn grid fires slower rather than not
		# at all. Fully brownout'd turrets (efficiency == 0) freeze.
		var turret_power_eff: float = 1.0
		if data.electrical_power_use > 0:
			var power_sys_t = get_node_or_null("/root/Main/PowerSystem")
			if power_sys_t:
				turret_power_eff = power_sys_t.get_electrical_efficiency(grid_pos)
		turret_cooldowns[grid_pos] -= delta * turret_power_eff
		if turret_power_eff <= 0.0:
			continue

		# Use pre-computed target from worker thread
		if not _turret_targets.has(grid_pos):
			continue

		var target_info: Dictionary = _turret_targets[grid_pos]
		var turret_world: Vector2 = main.grid_to_world(grid_pos) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		var turret_faction: int = main.get_building_faction(grid_pos)

		var target_world: Vector2 = target_info["target_pos"]
		var shoot_at_unit: bool = target_info["target_type"] == "unit"

		# Resolve live target references
		var nearest_unit: Node2D = null
		var nearest_bldg := Vector2i(-1, -1)
		if shoot_at_unit:
			var target_id: int = target_info["target_id"]
			var obj = instance_from_id(target_id)
			if obj != null and is_instance_valid(obj) and not obj.is_dead:
				nearest_unit = obj
				target_world = nearest_unit.position  # Use live position
			else:
				continue  # Target died since scan
		else:
			nearest_bldg = target_info["target_bldg"]
			if not main.placed_buildings.has(nearest_bldg):
				continue  # Building destroyed since scan
			target_world = main.grid_to_world(nearest_bldg) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)

		# Live range re-check: the targeting worker may have pre-computed this
		# target when it was in range, but the target may have moved away since.
		# Skip aiming AND firing if the target is now outside attack_range.
		var live_range_px: float = data.attack_range * main.GRID_SIZE
		if live_range_px > 0.0 and turret_world.distance_to(target_world) > live_range_px:
			continue

		# Smoothly rotate the turret head toward the target
		var target_angle: float = (target_world - turret_world).angle()
		var current_angle = turret_angles[grid_pos]
		turret_angles[grid_pos] = lerp_angle(current_angle, target_angle, delta * 8.0)

		if turret_cooldowns[grid_pos] > 0:
			continue

		# --- Ammo check: if turret has ammo_types, it needs resources to fire ---
		var fire_damage: float = data.attack_damage
		var fire_reload_mult: float = 1.0
		var fire_color: Color = data.color.lightened(0.3)
		var fire_speed: float = default_projectile_speed
		var fire_aoe: bool = data.is_aoe
		var fire_aoe_radius: float = data.aoe_radius
		var fire_lifetime: float = 2.0
		var fire_radius: float = 4.0
		var fire_pierce: int = 0
		var fire_homing: float = 0.0
		var fire_knockback: float = 0.0
		var fire_inaccuracy: float = 0.0
		var fire_pellets: int = 1
		var fire_range_bonus: float = 0.0
		var fire_status: Resource = null
		var fire_trail_color: Color = fire_color
		var fire_collides_air: bool = true
		var fire_collides_ground: bool = true
		var fire_bldg_mult: float = 1.0
		var fire_unit_mult: float = 1.0
		var fire_splash_mult: float = 1.0

		if data.ammo_types.size() > 0:
			var log_ref: Node2D = _logistics
			var ammo_found := false
			var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
			for ammo in data.ammo_types:
				if ammo == null or not (ammo is AmmoType):
					continue
				var ammo_data: AmmoType = ammo as AmmoType
				if log_ref and log_ref.has_method("get_stored_item_count"):
					var stored: int = log_ref.get_stored_item_count(anchor, ammo_data.item_id)
					var amt: int = maxi(ammo_data.amount_per_shot, 1)
					if stored >= amt:
						log_ref.remove_from_storage(anchor, ammo_data.item_id, amt)
						fire_damage = ammo_data.damage
						fire_reload_mult = ammo_data.reload_multiplier
						fire_color = ammo_data.projectile_color
						fire_status = ammo_data.status_effect
						fire_speed = ammo_data.projectile_speed
						fire_lifetime = ammo_data.projectile_lifetime
						fire_radius = ammo_data.projectile_radius
						fire_pierce = ammo_data.pierce_count
						fire_homing = ammo_data.homing
						fire_knockback = ammo_data.knockback
						fire_inaccuracy = ammo_data.inaccuracy
						fire_pellets = ammo_data.projectiles_per_shot
						fire_range_bonus = ammo_data.range_bonus
						fire_trail_color = ammo_data.get_trail_color()
						fire_collides_air = ammo_data.collides_air
						fire_collides_ground = ammo_data.collides_ground
						fire_bldg_mult = ammo_data.building_damage_mult
						fire_unit_mult = ammo_data.unit_damage_mult
						# Splash overrides the block-level AoE if the ammo opts in
						if ammo_data.is_splash:
							fire_aoe = true
							fire_aoe_radius = ammo_data.splash_radius
							fire_splash_mult = ammo_data.splash_damage_mult
						ammo_found = true
						break
			if not ammo_found:
				continue  # No ammo available — can't fire
		# When the turret has NO ammo_types configured at all, it CANNOT fire.
		# (Mindustry-style: every turret must be loaded.)
		else:
			continue

		# Fire!
		turret_cooldowns[grid_pos] = data.attack_speed * fire_reload_mult

		# Spawn projectile from the barrel TIP, not the building center
		var barrel_length = main.GRID_SIZE * 0.4
		var fire_pos = turret_world + Vector2.from_angle(turret_angles[grid_pos]) * barrel_length

		# Spawn one projectile per pellet, applying inaccuracy spread.
		for pellet_i in range(maxi(fire_pellets, 1)):
			var spread_rad: float = 0.0
			if fire_inaccuracy > 0.0:
				spread_rad = deg_to_rad(randf_range(-fire_inaccuracy, fire_inaccuracy))
			var pellet_angle: float = (target_world - fire_pos).angle() + spread_rad
			var pellet_target: Vector2 = fire_pos + Vector2.from_angle(pellet_angle) * (target_world - fire_pos).length()

			# Turret effective range in pixels (base range in grid tiles + any
			# ammo range bonus). Projectiles despawn once they've traveled this
			# far from their spawn point.
			var fire_max_range: float = (data.attack_range * main.GRID_SIZE) + fire_range_bonus

			if shoot_at_unit:
				_spawn_projectile(
					fire_pos,
					nearest_unit,
					nearest_unit.position if pellet_i == 0 and fire_pellets == 1 else pellet_target,
					"enemy",
					fire_speed,
					fire_damage * fire_unit_mult,
					fire_color,
					"turret",
					fire_aoe,
					fire_aoe_radius,
					turret_faction,
					{
						"lifetime": fire_lifetime,
						"radius": fire_radius,
						"pierce": fire_pierce,
						"homing": fire_homing,
						"knockback": fire_knockback,
						"trail_color": fire_trail_color,
						"collides_air": fire_collides_air,
						"collides_ground": fire_collides_ground,
						"status": fire_status,
						"splash_mult": fire_splash_mult,
						"max_range": fire_max_range,
					},
				)
			else:
				_spawn_projectile(
					fire_pos,
					nearest_bldg,
					target_world if pellet_i == 0 and fire_pellets == 1 else pellet_target,
					"building",
					fire_speed,
					fire_damage * fire_bldg_mult,
					fire_color,
					"turret",
					fire_aoe,
					fire_aoe_radius,
					turret_faction,
					{
						"lifetime": fire_lifetime,
						"radius": fire_radius,
						"pierce": fire_pierce,
						"homing": fire_homing,
						"knockback": fire_knockback,
						"trail_color": fire_trail_color,
						"collides_air": fire_collides_air,
						"collides_ground": fire_collides_ground,
						"status": fire_status,
						"splash_mult": fire_splash_mult,
						"max_range": fire_max_range,
					},
				)


# =========================
# PLAYER DRONE COMBAT
# =========================

func _update_drone_combat(delta: float) -> void:
	drone_cooldown -= delta

	# Don't fire drone while manually controlling a unit/turret
	var unit_mgr = _unit_mgr_ref()
	if unit_mgr and unit_mgr.controlled_entity != null:
		drone_is_shooting = false
		return

	# Check if left mouse is held AND no building is selected
	drone_is_shooting = (
		Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and
		main.selected_building == &""
	)

	if not drone_is_shooting or drone_cooldown > 0:
		return

	# Don't shoot when clicking on GUI controls (block menu, HUD buttons, etc.)
	if get_viewport().gui_get_hovered_control() != null:
		drone_is_shooting = false
		return

	var drone = _drone_ref()
	if drone == null:
		return

	# Don't shoot while mining ore
	if drone.mining_target != null:
		drone_is_shooting = false
		return

	# Check if terrain paint mode is active — don't shoot while painting
	var terrain = _terrain_ref()
	if terrain and terrain.paint_mode:
		return

	# Fire!
	drone_cooldown = drone_attack_speed

	var mouse_pos = get_global_mouse_position()
	var direction = (mouse_pos - drone.position).normalized()
	# Calculate a far-off target point in that direction
	var target_pos = drone.position + direction * drone_range * main.GRID_SIZE

	_spawn_projectile(
		drone.position,
		null,              # no target ref — flies straight
		target_pos,
		"none",            # special type: hits nothing automatically
		drone_projectile_speed,
		drone_damage,
		Color(0.3, 0.9, 1.0, 1.0),
		"drone",
		false,
		0.0,
	)


# =========================
# RANGED ENEMY ATTACKS
# =========================

## Called by player units (LUMINA) to fire a projectile at an enemy unit.
func player_unit_attack_unit(unit: Node2D, target_enemy: Node2D, dmg: float, proj_speed: float, proj_color: Color, aoe: bool = false, aoe_radius: float = 0.0) -> void:
	_spawn_projectile(
		unit.position,
		target_enemy,
		target_enemy.position,
		"enemy",
		proj_speed,
		dmg,
		proj_color,
		"player_unit",
		aoe,
		aoe_radius,
		main.Faction.LUMINA,
	)


## Called by player units (LUMINA) to fire a projectile at a FEROX building.
func player_unit_attack_building(unit: Node2D, target_grid_pos: Vector2i, dmg: float, proj_speed: float, proj_color: Color, aoe: bool = false, aoe_radius: float = 0.0) -> void:
	var target_world = main.grid_to_world(target_grid_pos) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
	_spawn_projectile(
		unit.position,
		target_grid_pos,
		target_world,
		"building",
		proj_speed,
		dmg,
		proj_color,
		"player_unit",
		aoe,
		aoe_radius,
		main.Faction.LUMINA,
	)


## Called by enemy_unit.gd when a ranged enemy wants to shoot.
## Returns true if a projectile was spawned.
func enemy_ranged_attack(enemy: Node2D, target_grid_pos: Vector2i, damage: float, proj_speed: float, proj_color: Color) -> bool:
	var target_world = main.grid_to_world(target_grid_pos) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)

	_spawn_projectile(
		enemy.position,
		target_grid_pos,         # target ref is the grid position
		target_world,
		"building",
		proj_speed,
		damage,
		proj_color,
		"enemy",
		false,
		0.0,
	)
	return true


# =========================
# PROJECTILE MANAGEMENT
# =========================

func _spawn_projectile(
	start_pos: Vector2,
	target_ref: Variant,
	target_pos: Vector2,
	target_type: String,
	speed: float,
	damage: float,
	color: Color,
	source: String,
	aoe: bool,
	aoe_radius: float,
	source_faction: int = 0,  # 0 = LUMINA, 1 = FEROX
	extras: Dictionary = {},
) -> void:
	var proj: Dictionary = {
		"pos": start_pos,
		"spawn_pos": start_pos,
		"target_ref": target_ref,
		"target_pos": target_pos,
		"target_type": target_type,
		"speed": speed,
		"damage": damage,
		"color": color,
		"radius": float(extras.get("radius", 4.0)),
		"source": source,
		"aoe": aoe,
		"aoe_radius": aoe_radius,
		"source_faction": source_faction,
		"trail": [],
		# --- Mindustry-style extras (from AmmoType) ---
		"lifetime": float(extras.get("lifetime", 4.0)),
		"age": 0.0,
		"max_range": float(extras.get("max_range", 0.0)),  # 0 = no range cap
		"pierce_remaining": int(extras.get("pierce", 0)),
		"hit_targets": {},  # de-dupes pierce hits
		"homing": float(extras.get("homing", 0.0)),
		"knockback": float(extras.get("knockback", 0.0)),
		"trail_color": extras.get("trail_color", color),
		"collides_air": bool(extras.get("collides_air", true)),
		"collides_ground": bool(extras.get("collides_ground", true)),
		"status": extras.get("status", null),
		"splash_mult": float(extras.get("splash_mult", 1.0)),
	}
	projectiles.append(proj)


func _update_projectiles(delta: float) -> void:
	var unit_mgr = _unit_mgr_ref()
	var to_remove: Array[int] = []

	for i in range(projectiles.size()):
		var proj = projectiles[i]

		# Lifetime expiry — Mindustry-style despawn after N seconds.
		proj["age"] = proj.get("age", 0.0) + delta
		if proj["age"] >= proj.get("lifetime", 999.0):
			to_remove.append(i)
			continue

		# Max-range despawn — stop the projectile once it has travelled further
		# than the turret's effective range from where it was fired.
		var max_range: float = float(proj.get("max_range", 0.0))
		if max_range > 0.0:
			var spawn_pos: Vector2 = proj.get("spawn_pos", proj["pos"])
			if proj["pos"].distance_to(spawn_pos) >= max_range:
				to_remove.append(i)
				continue

		# Update target position if the target is still alive/valid
		_update_target_pos(proj)

		# Homing: bend the target_pos toward the live target each frame
		var homing: float = proj.get("homing", 0.0)
		if homing > 0.0 and proj["target_type"] == "enemy":
			var enemy = proj.get("target_ref")
			if is_instance_valid(enemy) and not enemy.is_dead:
				var to_enemy: Vector2 = enemy.position - proj["pos"]
				var current_dir: Vector2 = (proj["target_pos"] - proj["pos"]).normalized()
				var desired: Vector2 = to_enemy.normalized()
				var bent: Vector2 = current_dir.lerp(desired, clampf(homing, 0.0, 1.0)).normalized()
				proj["target_pos"] = proj["pos"] + bent * to_enemy.length()

		# Store trail position
		proj["trail"].append(proj["pos"])
		if proj["trail"].size() > TRAIL_LENGTH:
			proj["trail"].remove_at(0)

		# Move toward target
		var direction = (proj["target_pos"] - proj["pos"]).normalized()
		var distance = proj["pos"].distance_to(proj["target_pos"])
		var step = proj["speed"] * delta

		# --- Direct-fire bullets (drone, controlled unit/turret): hit enemies and buildings along path ---
		if proj["target_type"] == "none" and unit_mgr:
			var new_pos = proj["pos"] + direction * step
			var hit_enemy = _check_bullet_hit_enemy(new_pos, proj["pos"], unit_mgr)
			if hit_enemy:
				hit_enemy.take_damage(proj["damage"])
				to_remove.append(i)
				continue
			# Check if the bullet hits an opposing-faction building
			var source_faction: int = proj.get("source_faction", 0)
			var hit_bldg: Vector2i = _check_bullet_hit_building(new_pos, proj["pos"], source_faction)
			if hit_bldg != Vector2i(-1, -1):
				main.damage_building(hit_bldg, proj["damage"])
				to_remove.append(i)
				continue

		if step >= distance or distance < hit_radius:
			# HIT!
			_on_projectile_hit(proj, unit_mgr)
			to_remove.append(i)
		else:
			proj["pos"] += direction * step

	# Remove hit projectiles (iterate in reverse to keep indices valid)
	for i in range(to_remove.size() - 1, -1, -1):
		projectiles.remove_at(to_remove[i])


func _update_target_pos(proj: Dictionary) -> void:
	# Only home in on the live target position if the ammo's homing value is
	# > 0. Non-homing projectiles keep flying toward the position the target
	# was at when the shot was fired (ballistic behavior).
	var homing_strength: float = float(proj.get("homing", 0.0))
	if homing_strength <= 0.0:
		return
	match proj["target_type"]:
		"enemy":
			# Target is an enemy Node2D
			var enemy = proj["target_ref"]
			if is_instance_valid(enemy) and not enemy.is_dead:
				proj["target_pos"] = enemy.position
			# If enemy is dead, projectile continues to last known pos

		"building":
			# Target is a Vector2i grid position
			var grid_pos = proj["target_ref"] as Vector2i
			if main.placed_buildings.has(grid_pos):
				proj["target_pos"] = main.grid_to_world(grid_pos) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)

		"drone":
			var drone = _drone_ref()
			if drone:
				proj["target_pos"] = drone.position


func _on_projectile_hit(proj: Dictionary, unit_mgr: Node2D) -> void:
	var splash_mult: float = float(proj.get("splash_mult", 1.0))
	var knockback: float = float(proj.get("knockback", 0.0))
	var status: Resource = proj.get("status")

	match proj["target_type"]:
		"enemy":
			if proj["aoe"] and unit_mgr:
				# AoE damage — FEROX turrets blast player units, LUMINA turrets blast enemies
				var units_in_blast: Array[Node2D]
				if proj.get("source_faction", 0) == main.Faction.FEROX:
					units_in_blast = unit_mgr.get_player_units_in_range(proj["target_pos"], proj["aoe_radius"])
				else:
					units_in_blast = unit_mgr.get_enemies_in_range(proj["target_pos"], proj["aoe_radius"])
				for unit in units_in_blast:
					if not is_instance_valid(unit) or unit.is_dead:
						continue
					if not _can_hit_unit(proj, unit):
						continue
					unit.take_damage(proj["damage"] * splash_mult)
					_apply_knockback(unit, proj["target_pos"], knockback)
					_apply_status(unit, status)
			else:
				# Single target
				var enemy = proj["target_ref"]
				if is_instance_valid(enemy) and not enemy.is_dead and _can_hit_unit(proj, enemy):
					enemy.take_damage(proj["damage"])
					_apply_knockback(enemy, proj["pos"], knockback)
					_apply_status(enemy, status)

		"building":
			# Splash on buildings: also damage buildings inside the radius
			if proj["aoe"]:
				var center: Vector2 = proj["target_pos"]
				var r: float = proj["aoe_radius"]
				var r_sq: float = r * r
				var checked := {}
				for grid_pos in main.placed_buildings:
					var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
					if checked.has(anchor):
						continue
					checked[anchor] = true
					var bw: Vector2 = main.grid_to_world(anchor) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
					if bw.distance_squared_to(center) <= r_sq:
						main.damage_building(anchor, proj["damage"] * splash_mult)
			else:
				var grid_pos = proj["target_ref"] as Vector2i
				if main.placed_buildings.has(grid_pos):
					main.damage_building(grid_pos, proj["damage"])

		"drone":
			var drone = _drone_ref()
			if drone:
				drone.take_damage(proj["damage"])


## Returns true if this projectile is allowed to hit the given unit, based on
## its collides_air / collides_ground filters.
func _can_hit_unit(proj: Dictionary, unit: Node2D) -> bool:
	var collides_air: bool = bool(proj.get("collides_air", true))
	var collides_ground: bool = bool(proj.get("collides_ground", true))
	if collides_air and collides_ground:
		return true
	# UnitData.MovementLayer: 0=ground, 1=crawler, 2=hover, 3=flying
	var ml: int = unit.data.movement_layer if unit.data else 0
	var is_air: bool = ml == 3
	if is_air and not collides_air:
		return false
	if not is_air and not collides_ground:
		return false
	return true


## Applies knockback to a unit by nudging its world position away from origin.
func _apply_knockback(unit: Node2D, origin: Vector2, amount: float) -> void:
	if amount <= 0.0:
		return
	var dir: Vector2 = (unit.position - origin)
	if dir.length_squared() < 0.01:
		return
	unit.position += dir.normalized() * amount


## Applies a status effect to a unit. Currently a no-op stub — units don't have
## a status system yet. Wired up so AmmoType can pass effects through.
func _apply_status(unit: Node2D, effect: Resource) -> void:
	if effect == null or unit == null:
		return
	if unit.has_method("apply_status_effect"):
		unit.apply_status_effect(effect)


# =========================
# HELPERS
# =========================

func _find_nearest_enemy(from_pos: Vector2, enemies: Array[Node2D]) -> Node2D:
	var nearest: Node2D = null
	var nearest_dist := INF
	for enemy in enemies:
		if not is_instance_valid(enemy) or enemy.is_dead:
			continue
		var dist = from_pos.distance_squared_to(enemy.position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = enemy
	return nearest

## Checks if a drone bullet is close enough to any enemy to hit it.
## Uses line-segment collision so fast bullets can't skip over enemies.
func _check_bullet_hit_enemy(bullet_pos: Vector2, bullet_prev: Vector2, unit_mgr: Node2D) -> Node2D:
	for enemy in unit_mgr.enemies:
		if not is_instance_valid(enemy) or enemy.is_dead:
			continue
		# Check distance from enemy to the line segment (prev → current)
		var closest = Geometry2D.get_closest_point_to_segment(enemy.position, bullet_prev, bullet_pos)
		if closest.distance_to(enemy.position) < hit_radius + enemy.unit_size:
			return enemy
	return null


## Checks if a direct-fire bullet passes through an opposing-faction building.
## Returns the grid position of the hit building, or Vector2i(-1, -1) if none.
func _check_bullet_hit_building(bullet_pos: Vector2, bullet_prev: Vector2, source_faction: int) -> Vector2i:
	var opposing_faction: int = main.Faction.FEROX if source_faction == main.Faction.LUMINA else main.Faction.LUMINA
	var half := Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)

	# Check grid cells along the bullet path
	# Sample the line at small intervals to catch buildings the bullet passes through
	var seg_dir := bullet_pos - bullet_prev
	var seg_len := seg_dir.length()
	if seg_len < 1.0:
		# Just check the single cell at bullet_pos
		var grid_pos: Vector2i = main.world_to_grid(bullet_pos)
		if main.placed_buildings.has(grid_pos) and main.get_building_faction(grid_pos) == opposing_faction:
			return main.building_origins.get(grid_pos, grid_pos)
		return Vector2i(-1, -1)

	# Sample every half-grid-size along the segment
	var step_size: float = main.GRID_SIZE * 0.5
	var steps := int(ceil(seg_len / step_size)) + 1
	var checked := {}  # Avoid checking the same cell twice

	for s in range(steps):
		var t := float(s) / float(maxi(steps - 1, 1))
		var sample_pos: Vector2 = bullet_prev.lerp(bullet_pos, t)
		var grid_pos: Vector2i = main.world_to_grid(sample_pos)

		if checked.has(grid_pos):
			continue
		checked[grid_pos] = true

		if main.placed_buildings.has(grid_pos) and main.get_building_faction(grid_pos) == opposing_faction:
			# Return the anchor so damage goes to the right cell
			return main.building_origins.get(grid_pos, grid_pos)

	return Vector2i(-1, -1)


func _on_building_placed(block_id: StringName, grid_pos: Vector2i) -> void:
	var data = Registry.get_block(block_id)
	if data and data.is_turret():
		turret_cooldowns[grid_pos] = 0.0


func _on_building_destroyed(grid_pos: Vector2i) -> void:
	turret_cooldowns.erase(grid_pos)
	turret_angles.erase(grid_pos)


# =========================
# DRAWING
# =========================

func _draw() -> void:
	_draw_turret_heads()
	_draw_projectiles()
	_draw_turret_ranges()

func _draw_turret_heads() -> void:
	var building_sys = _building_sys_ref()

	var _ss_turret = _sector_script_ref()
	for grid_pos in turret_angles:
		if not main.placed_buildings.has(grid_pos):
			continue
		if _ss_turret and _ss_turret.is_tile_hidden(grid_pos):
			continue

		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null:
			continue

		var world_pos = main.grid_to_world(grid_pos)
		var center = world_pos + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)

		# Apply the same parallax offset as buildings
		var offset = Vector2.ZERO
		if building_sys:
			offset = building_sys._get_top_offset(world_pos)
		center += offset

		var angle = turret_angles[grid_pos]

		# If the block defines a turret_head_sprite, draw that rotated to the
		# aim angle at its native pixel size (like cable wires), instead of
		# stretching to the block's tile size.
		if data.turret_head_sprite:
			var tex: Texture2D = data.turret_head_sprite
			var tex_size: Vector2 = tex.get_size() * 0.3
			# Barrel is assumed to point up in the source image, so add PI/2
			# to convert aim-angle (0 = +x/right) to texture-angle.
			var draw_angle: float = angle + PI / 2.0
			draw_set_transform(center, draw_angle)
			draw_texture_rect(
				tex,
				# Pivot at bottom-center (the "back" when facing up) so the turret
				# rotates around its base attachment point, not its center.
				Rect2(Vector2(-tex_size.x * 0.5, -tex_size.y + 14.0), tex_size),
				false
			)
			draw_set_transform(Vector2.ZERO, 0.0)
		else:
			# Fallback: generic circle+barrel placeholder.
			var head_radius = main.GRID_SIZE * 0.22
			var barrel_length = main.GRID_SIZE * 0.4
			var barrel_width = 4.0

			# --- Draw the barrel (a thick line from center outward) ---
			var barrel_end = center + Vector2.from_angle(angle) * barrel_length
			var barrel_color = data.color.darkened(0.2)
			draw_line(center, barrel_end, barrel_color, barrel_width + 2.0)
			draw_line(center, barrel_end, data.color.lightened(0.1), barrel_width)

			# --- Draw the muzzle (small circle at barrel tip) ---
			draw_circle(barrel_end, barrel_width * 0.6, data.color.lightened(0.3))

			# --- Draw the turret head (circle on top of building) ---
			draw_circle(center, head_radius, data.color.darkened(0.15))
			draw_arc(center, head_radius, 0, TAU, 24, data.color.lightened(0.2), 1.5)

			# --- Draw a small dot in the center ---
			draw_circle(center, 3.0, data.color.lightened(0.4))

func _draw_projectiles() -> void:
	for proj in projectiles:
		var pos = proj["pos"]
		var color = proj["color"]
		var radius = proj["radius"]

		# Draw trail
		var trail = proj["trail"] as Array
		if trail.size() > 1:
			for t in range(trail.size() - 1):
				var alpha = float(t) / trail.size() * 0.5
				var trail_color = Color(color.r, color.g, color.b, alpha)
				var width = radius * (float(t) / trail.size())
				draw_line(trail[t], trail[t + 1], trail_color, width)

		# Draw trail line from last trail point to current pos
		if trail.size() > 0:
			var trail_color = Color(color.r, color.g, color.b, 0.5)
			draw_line(trail[trail.size() - 1], pos, trail_color, radius * 0.8)

		# Draw the projectile itself — bright glowing circle
		draw_circle(pos, radius + 1.0, Color(color.r, color.g, color.b, 0.3))
		draw_circle(pos, radius, color)
		draw_circle(pos, radius * 0.5, color.lightened(0.5))


func _draw_turret_ranges() -> void:
	# Only draw range circles when hovering over a turret or when
	# a turret block is selected for placement
	if main.selected_building != &"":
		var data = Registry.get_block(main.selected_building)
		if data and data.is_turret():
			var mouse_world = get_global_mouse_position()
			var grid_pos = main.world_to_grid(mouse_world)
			var center = main.grid_to_world(grid_pos) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
			var range_px = data.attack_range * main.GRID_SIZE
			draw_arc(center, range_px, 0, TAU, 48, Color(1, 0.3, 0.3, 0.25), 1.5)
