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


func _ready() -> void:
	await get_tree().process_frame
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

	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
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
		var sector_script = get_node_or_null("/root/Main/SectorScript")
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
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
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

		# Count down
		turret_cooldowns[grid_pos] -= delta

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

		# Smoothly rotate the turret head toward the target
		var target_angle: float = (target_world - turret_world).angle()
		var current_angle = turret_angles[grid_pos]
		turret_angles[grid_pos] = lerp_angle(current_angle, target_angle, delta * 8.0)

		if turret_cooldowns[grid_pos] > 0:
			continue

		# --- Ammo check: if turret has ammo_types, it needs resources to fire ---
		var fire_damage: float = data.attack_damage
		var fire_speed_mult: float = 1.0
		var fire_color: Color = data.color.lightened(0.3)
		var fire_status: Resource = null

		if data.ammo_types.size() > 0:
			var _logistics = get_node_or_null("/root/Main/LogisticsSystem")
			var ammo_found := false
			var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
			for ammo in data.ammo_types:
				if ammo == null or not (ammo is AmmoType):
					continue
				var ammo_data: AmmoType = ammo as AmmoType
				# Check if turret has this ammo in its storage
				if _logistics and _logistics.has_method("get_stored_item_count"):
					var stored: int = _logistics.get_stored_item_count(anchor, ammo_data.item_id)
					if stored > 0:
						_logistics.remove_from_storage(anchor, ammo_data.item_id, 1)
						fire_damage = ammo_data.damage
						fire_speed_mult = ammo_data.speed_multiplier
						fire_color = ammo_data.projectile_color
						fire_status = ammo_data.status_effect
						ammo_found = true
						break
			if not ammo_found:
				continue  # No ammo available — can't fire

		# Fire!
		turret_cooldowns[grid_pos] = data.attack_speed * fire_speed_mult

		# Spawn projectile from the barrel TIP, not the building center
		var barrel_length = main.GRID_SIZE * 0.4
		var fire_pos = turret_world + Vector2.from_angle(turret_angles[grid_pos]) * barrel_length

		var proj_color = fire_color

		if shoot_at_unit:
			_spawn_projectile(
				fire_pos,
				nearest_unit,
				nearest_unit.position,
				"enemy",
				default_projectile_speed,
				fire_damage,
				proj_color,
				"turret",
				data.is_aoe,
				data.aoe_radius,
				turret_faction,
			)
		else:
			_spawn_projectile(
				fire_pos,
				nearest_bldg,
				target_world,
				"building",
				default_projectile_speed,
				fire_damage,
				proj_color,
				"turret",
				data.is_aoe,
				data.aoe_radius,
				turret_faction,
			)


# =========================
# PLAYER DRONE COMBAT
# =========================

func _update_drone_combat(delta: float) -> void:
	drone_cooldown -= delta

	# Don't fire drone while manually controlling a unit/turret
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
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

	var drone = get_node_or_null("/root/Main/PlayerDrone")
	if drone == null:
		return

	# Don't shoot while mining ore
	if drone.mining_target != null:
		drone_is_shooting = false
		return

	# Check if terrain paint mode is active — don't shoot while painting
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
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
) -> void:
	projectiles.append({
		"pos": start_pos,
		"target_ref": target_ref,
		"target_pos": target_pos,
		"target_type": target_type,
		"speed": speed,
		"damage": damage,
		"color": color,
		"radius": 4.0,
		"source": source,
		"aoe": aoe,
		"aoe_radius": aoe_radius,
		"source_faction": source_faction,
		"trail": [],  # Array of past positions for trail effect
	})


func _update_projectiles(delta: float) -> void:
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	var to_remove: Array[int] = []

	for i in range(projectiles.size()):
		var proj = projectiles[i]

		# Update target position if the target is still alive/valid
		_update_target_pos(proj)

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
			var drone = get_node_or_null("/root/Main/PlayerDrone")
			if drone:
				proj["target_pos"] = drone.position


func _on_projectile_hit(proj: Dictionary, unit_mgr: Node2D) -> void:
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
					if is_instance_valid(unit) and not unit.is_dead:
						unit.take_damage(proj["damage"])
			else:
				# Single target
				var enemy = proj["target_ref"]
				if is_instance_valid(enemy) and not enemy.is_dead:
					enemy.take_damage(proj["damage"])

		"building":
			var grid_pos = proj["target_ref"] as Vector2i
			if main.placed_buildings.has(grid_pos):
				main.damage_building(grid_pos, proj["damage"])

		"drone":
			var drone = get_node_or_null("/root/Main/PlayerDrone")
			if drone:
				drone.take_damage(proj["damage"])


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
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")

	var _ss_turret = get_node_or_null("/root/Main/SectorScript")
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
