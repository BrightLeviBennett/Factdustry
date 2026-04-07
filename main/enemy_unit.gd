extends Node2D

# ============================================================
# ENEMY_UNIT.GD - Basic Enemy Unit
# ============================================================
# Stats are loaded from a UnitData .tres resource passed in
# by the UnitManager when spawning.
# ============================================================

# --- DATA ---
# The UnitData resource this enemy was created from.
# Set by UnitManager before adding to scene tree.
var data: UnitData

# --- STATS (loaded from data) ---
var max_health: float
var move_speed: float
var damage: float
var attack_cooldown: float
var unit_color: Color
var unit_size: float

# --- STATE ---
var health: float
var path: PackedVector2Array = PackedVector2Array()
var path_index := 0
var attack_timer := 0.0
var target_building: Variant = null
var is_dead := false
var is_selected := false
var is_controlled := false  # True when the player is directly controlling this unit
var target_unit: Variant = null  # Node2D — enemy unit targeted by player units

# --- MOVE COMMAND ---
# When a player unit is given a move command, it moves there instead of idling.
var move_target: Variant = null  # Vector2 or null

# --- RUNTIME TEAM ---
# Set by UnitManager at spawn time (overrides team which defaults to PLAYER in .tres)
var team: int = UnitData.Team.ENEMY

# --- REBUILD (Ferox core unit) ---
# When a ferox ENEMY unit has category SUPPORT and id "rebuild", it will
# try to rebuild destroyed ferox buildings from the rebuild queue.
var rebuild_target: Variant = null  # Dictionary from ferox_rebuild_queue or null
var rebuild_timer := 0.0
const REBUILD_TIME := 3.0  # Seconds to rebuild a building
var _rebuild_arrived := false  # True when unit is at the rebuild location

# --- STUCK DETECTION ---
# When a unit has a destination but stays nearly stationary for STUCK_TIME seconds,
# it disperses away from nearby units so groups don't pile up forever.
var _stuck_timer := 0.0
var _stuck_origin := Vector2.ZERO
const STUCK_TIME := 3.0
const STUCK_RADIUS := 5.0  # Must move at least this many pixels in STUCK_TIME to not be "stuck"

# --- REFERENCES (set by UnitManager) ---
var main: Node2D
var unit_manager: Node2D


func _ready() -> void:
	# Load stats from the UnitData resource
	if data:
		max_health = data.max_health
		move_speed = data.move_speed
		damage = data.attack_damage
		attack_cooldown = data.attack_speed
		unit_color = data.color
		unit_size = data.visual_size
	else:
		# Fallbacks
		push_warning("EnemyUnit: No UnitData assigned!")
		max_health = 50.0
		move_speed = 80.0
		damage = 10.0
		attack_cooldown = 1.0
		unit_color = Color(1.0, 0.3, 0.3)
		unit_size = 8.0

	health = max_health


func _process(delta: float) -> void:
	if is_dead:
		return
	if main.world_paused:
		return

	if path.size() > 0 and path_index < path.size():
		_follow_path(delta)
	elif _is_rebuilder():
		_try_rebuild(delta)
	elif data and team == UnitData.Team.PLAYER:
		_try_player_combat(delta)
	else:
		_try_attack(delta)

	_check_stuck(delta)
	queue_redraw()


func _follow_path(delta: float) -> void:
	var target_pos = path[path_index]
	var direction = (target_pos - position).normalized()
	var distance = position.distance_to(target_pos)

	# Units chasing an enemy — stop at attack_range
	if data and target_unit != null:
		if is_instance_valid(target_unit) and not target_unit.is_dead:
			var dist_to_enemy := position.distance_to(target_unit.position)
			if data.attack_range > 0 and dist_to_enemy <= data.attack_range:
				path = PackedVector2Array()
				path_index = 0
				return
		else:
			target_unit = null

	# Any unit attacking a building — stop at effective attack range
	# so ranged units don't walk on top of their target
	if data and target_building != null and target_unit == null and move_target == null:
		var bldg_world: Vector2 = main.grid_to_world(target_building) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		var dist_to_bldg: float = position.distance_to(bldg_world)
		var effective_range: float = maxf(data.attack_range, main.GRID_SIZE * 1.5) if data.attack_range > 0 else 0.0
		if effective_range > 0.0 and dist_to_bldg <= effective_range:
			path = PackedVector2Array()
			path_index = 0
			return

	# Arrival tolerance: on the LAST waypoint of a move command (no building target),
	# stop when close enough instead of fighting for the exact pixel.
	if target_building == null and path_index == path.size() - 1 and distance < unit_size:
		path = PackedVector2Array()
		path_index = 0
		move_target = null
		return

	var step = move_speed * delta

	if step >= distance:
		position = target_pos
		path_index += 1
	else:
		position += direction * step


func _try_attack(delta: float) -> void:
	if not main.enemies_attack:
		return
	attack_timer -= delta
	if attack_timer > 0:
		return

	if target_building == null or not main.placed_buildings.has(target_building):
		target_building = null
		unit_manager.request_new_path(self)
		return

	# Don't attack buildings of the same faction
	if team == UnitData.Team.ENEMY and main.get_building_faction(target_building) == main.Faction.FEROX:
		target_building = null
		unit_manager.request_new_path(self)
		return
	if team == UnitData.Team.PLAYER and main.get_building_faction(target_building) == main.Faction.LUMINA:
		target_building = null
		unit_manager.request_new_path(self)
		return

	attack_timer = attack_cooldown

	# Check if this enemy has ranged attacks
	# attack_range > 0 in the .tres means it shoots projectiles
	if data and data.attack_range > 0:
		# RANGED ATTACK: Fire a projectile via CombatSystem
		var combat = get_node_or_null("/root/Main/CombatSystem")
		if combat:
			var proj_speed = 300.0
			var proj_color = unit_color.lightened(0.3)
			combat.enemy_ranged_attack(
				self,
				target_building,   # Vector2i grid pos
				damage,
				proj_speed,
				proj_color,
			)
	else:
		# MELEE ATTACK: Direct damage (the old punch behavior)
		main.damage_building(target_building, damage)


# =========================
# PLAYER UNIT COMBAT
# =========================

## Player units auto-target nearby FEROX enemies and buildings when idle.
func _try_player_combat(delta: float) -> void:
	# Don't auto-fight if player is directly controlling this unit
	if is_controlled:
		return
	# Don't auto-fight if the player gave a move command
	if move_target != null:
		return

	attack_timer -= delta

	# Validate current targets
	if target_unit != null:
		if not is_instance_valid(target_unit) or target_unit.is_dead:
			target_unit = null
	if target_building != null:
		if not main.placed_buildings.has(target_building):
			target_building = null

	# If no valid target, scan for one
	if target_unit == null and target_building == null:
		_find_player_target()

	if target_unit == null and target_building == null:
		return

	# Get target position
	var target_pos: Vector2
	if target_unit != null:
		target_pos = target_unit.position
	else:
		target_pos = main.grid_to_world(target_building) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)

	var dist := position.distance_to(target_pos)
	var atk_range: float = data.attack_range if data else 32.0

	# Buildings occupy solid cells so units can't stand on them.
	# Ensure the effective range is at least 1.5 grid cells so units
	# on adjacent tiles can attack.
	var effective_range: float = atk_range
	if target_building != null:
		effective_range = maxf(atk_range, main.GRID_SIZE * 1.5)

	# Not in range — pathfind toward target
	if dist > effective_range:
		if path.size() == 0 or path_index >= path.size():
			# Use async path request — result arrives next frame
			# Pass target_building so it's preserved when the path result is applied
			unit_manager.request_path_to_position_async_with_target(self, target_pos, target_building)
		return

	# In range — attack!
	if attack_timer > 0:
		return

	attack_timer = attack_cooldown

	if target_unit != null:
		_attack_enemy_unit()
	elif target_building != null:
		_attack_ferox_building()


## Looks up the pre-computed target from the TargetingWorker (via CombatSystem).
## Falls back to inline scan if no threaded result is available.
func _find_player_target() -> void:
	var combat = get_node_or_null("/root/Main/CombatSystem")
	if combat and combat.unit_target_results.has(get_instance_id()):
		var result: Dictionary = combat.unit_target_results[get_instance_id()]
		if result["target_type"] == "enemy":
			var target_id: int = result["target_id"]
			var obj = instance_from_id(target_id)
			if obj != null and is_instance_valid(obj) and not obj.is_dead:
				target_unit = obj
				return
		elif result["target_type"] == "building":
			var bldg_pos: Vector2i = result["target_bldg"]
			if main.placed_buildings.has(bldg_pos):
				target_building = bldg_pos
				return

	# Fallback: inline scan when no threaded result is available
	var detect_range: float = data.detection_range if data else 500.0
	var detect_range_sq: float = detect_range * detect_range

	# Check for nearby enemy units first
	for e in unit_manager.enemies:
		if not is_instance_valid(e) or e.is_dead:
			continue
		if e.data and e.team == UnitData.Team.PLAYER:
			continue
		if position.distance_squared_to(e.position) <= detect_range_sq:
			target_unit = e
			return

	# Check for nearby FEROX buildings
	var best_dist_sq := detect_range_sq
	var best_bldg: Variant = null
	for grid_pos in main.placed_buildings:
		if main.get_building_faction(grid_pos) != main.Faction.FEROX:
			continue
		if not main.is_building_anchor(grid_pos):
			continue
		var bldg_world: Vector2 = main.grid_to_world(grid_pos) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		var dist_sq := position.distance_squared_to(bldg_world)
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_bldg = grid_pos

	if best_bldg != null:
		target_building = best_bldg


## Fire a projectile at the targeted enemy unit.
func _attack_enemy_unit() -> void:
	var combat = get_node_or_null("/root/Main/CombatSystem")
	if combat:
		var proj_speed := 300.0
		var proj_color: Color = unit_color.lightened(0.3)
		combat.player_unit_attack_unit(
			self,
			target_unit,
			damage,
			proj_speed,
			proj_color,
			data.is_aoe if data else false,
			data.aoe_radius if data else 0.0,
		)
	else:
		target_unit.take_damage(damage)


## Fire a projectile at the targeted FEROX building.
func _attack_ferox_building() -> void:
	var combat = get_node_or_null("/root/Main/CombatSystem")
	if combat:
		var proj_speed := 300.0
		var proj_color: Color = unit_color.lightened(0.3)
		combat.player_unit_attack_building(
			self,
			target_building,
			damage,
			proj_speed,
			proj_color,
			data.is_aoe if data else false,
			data.aoe_radius if data else 0.0,
		)
	else:
		main.damage_building(target_building, damage)


# =========================
# FEROX REBUILD BEHAVIOR
# =========================

## Returns true if this is a ferox rebuilder unit.
func _is_rebuilder() -> bool:
	return data != null and team == UnitData.Team.ENEMY and data.id == &"rebuild"


## Ferox rebuild logic: pick a target from the queue, pathfind to it, rebuild.
func _try_rebuild(delta: float) -> void:
	# If no rebuild target, try to pick one from the queue
	if rebuild_target == null:
		if main.ferox_rebuild_queue.size() == 0:
			# Nothing to rebuild — fall back to normal enemy attack
			_try_attack(delta)
			return
		rebuild_target = main.ferox_rebuild_queue.pop_front()
		rebuild_timer = 0.0
		_rebuild_arrived = false
		# Pathfind to the rebuild location
		var target_pos: Vector2 = main.grid_to_world(rebuild_target["grid_pos"]) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		unit_manager.assign_path_to_position(self, target_pos)
		return

	# Check if the rebuild location is already occupied (someone else rebuilt it)
	var grid_pos: Vector2i = rebuild_target["grid_pos"]
	if main.placed_buildings.has(grid_pos):
		rebuild_target = null
		_rebuild_arrived = false
		return

	# Check distance to target
	var target_world: Vector2 = main.grid_to_world(grid_pos) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
	var dist := position.distance_to(target_world)
	var build_range := maxf(data.attack_range, main.GRID_SIZE * 2.0)

	if dist > build_range:
		# Not close enough — request path again if we've run out of waypoints
		if path.size() == 0 or path_index >= path.size():
			unit_manager.assign_path_to_position(self, target_world)
		return

	# In range — start building
	_rebuild_arrived = true
	rebuild_timer += delta

	if rebuild_timer >= REBUILD_TIME:
		_finish_rebuild()


## Completes rebuilding: checks resources, places the building.
func _finish_rebuild() -> void:
	if rebuild_target == null:
		return

	var block_id: StringName = rebuild_target["block_id"]
	var grid_pos: Vector2i = rebuild_target["grid_pos"]
	var rot: int = rebuild_target["rotation"]
	var bdata = Registry.get_block(block_id)

	if bdata == null:
		rebuild_target = null
		_rebuild_arrived = false
		return

	# Check if ferox has enough resources
	var can_build := true
	for item_id in bdata.build_cost:
		var needed: int = bdata.build_cost[item_id]
		if main.ferox_resources.get(item_id, 0) < needed:
			can_build = false
			break

	if not can_build:
		# Can't afford — put it back in the queue for later
		main.ferox_rebuild_queue.append(rebuild_target)
		rebuild_target = null
		_rebuild_arrived = false
		return

	# Check if space is clear
	for x in range(bdata.grid_size.x):
		for y in range(bdata.grid_size.y):
			var tile_pos = grid_pos + Vector2i(x, y)
			if main.placed_buildings.has(tile_pos):
				# Space blocked — discard this rebuild
				rebuild_target = null
				_rebuild_arrived = false
				return

	# Deduct ferox resources
	for item_id in bdata.build_cost:
		main.ferox_resources[item_id] -= bdata.build_cost[item_id]
	main.ferox_resources_changed.emit(main.ferox_resources)

	# Place the building as ferox faction
	for x in range(bdata.grid_size.x):
		for y in range(bdata.grid_size.y):
			var tile_pos = grid_pos + Vector2i(x, y)
			main.placed_buildings[tile_pos] = block_id
			main.building_health[tile_pos] = bdata.max_health
			main.building_rotation[tile_pos] = rot
			main.building_origins[tile_pos] = grid_pos
			main.building_factions[tile_pos] = main.Faction.FEROX

	main.building_placed.emit(block_id, grid_pos)

	rebuild_target = null
	_rebuild_arrived = false


# =========================
# STUCK DETECTION & DISPERSAL
# =========================

## Checks if this unit has a destination but hasn't moved significantly.
## After STUCK_TIME seconds of being stuck near other units, disperses outward.
func _check_stuck(delta: float) -> void:
	var has_destination: bool = (path.size() > 0 and path_index < path.size()) or move_target != null
	if not has_destination:
		_stuck_timer = 0.0
		return

	# Start tracking from current position when timer resets
	if _stuck_timer == 0.0:
		_stuck_origin = position

	_stuck_timer += delta

	if _stuck_timer >= STUCK_TIME:
		if position.distance_to(_stuck_origin) < STUCK_RADIUS:
			_disperse_from_nearby_units()
		# Reset timer whether we dispersed or not (re-evaluate in another 3s)
		_stuck_timer = 0.0


## Pushes this unit away from the centroid of nearby same-layer units.
func _disperse_from_nearby_units() -> void:
	var nearby_center := Vector2.ZERO
	var nearby_count := 0
	var check_radius := unit_size * 5.0

	# Gather all units on the same movement layer
	var all_units: Array = unit_manager.enemies + unit_manager.player_units

	for other in all_units:
		if other == self or not is_instance_valid(other) or other.is_dead:
			continue
		if other.data and data and other.data.movement_layer != data.movement_layer:
			continue
		var dist := position.distance_to(other.position)
		if dist < check_radius:
			nearby_center += other.position
			nearby_count += 1

	if nearby_count == 0:
		return

	nearby_center /= nearby_count
	var away_dir := (position - nearby_center).normalized()

	# If we're right on top of the centroid, pick a random direction
	if away_dir.length_squared() < 0.01:
		var angle := randf() * TAU
		away_dir = Vector2(cos(angle), sin(angle))

	# Nudge away — enough to break the cluster but not teleport across the map
	var nudge_dist := unit_size * 3.0
	position += away_dir * nudge_dist

	# Clamp to map bounds
	var map_w: float = main.GRID_SIZE * main.GRID_WIDTH
	var map_h: float = main.GRID_SIZE * main.GRID_HEIGHT
	position.x = clampf(position.x, 0.0, map_w)
	position.y = clampf(position.y, 0.0, map_h)


func take_damage(amount: float) -> void:
	# Apply armor from .tres data
	var actual_damage = amount
	if data:
		actual_damage = data.calc_damage_taken(amount)
	health -= actual_damage
	if health <= 0 and not is_dead:
		is_dead = true
		_on_death()


func _on_death() -> void:
	# Drop items based on .tres data
	if data and data.drops.size() > 0 and randf() <= data.drop_chance:
		for item_id in data.drops:
			if main.resources.has(item_id):
				main.resources[item_id] += data.drops[item_id]
		main.resources_changed.emit(main.resources)

	if data and team == UnitData.Team.PLAYER:
		unit_manager.on_player_unit_died(self)
	else:
		unit_manager.on_enemy_died(self)
	queue_free()


func set_path(new_path: PackedVector2Array, target: Variant) -> void:
	path = new_path
	path_index = 0
	target_building = target
	_stuck_timer = 0.0


## Command this unit to move to a world position via pathfinding.
func move_to_position(world_pos: Vector2) -> void:
	move_target = world_pos
	target_building = null
	target_unit = null
	_stuck_timer = 0.0
	unit_manager.assign_path_to_position(self, world_pos)


# --- DRAWING ---
func _draw() -> void:
	if is_dead:
		return

	# Draw shape based on .tres data
	var shape = data.shape if data else UnitData.UnitShape.CIRCLE
	match shape:
		UnitData.UnitShape.CIRCLE:
			_draw_circle_shape()
		UnitData.UnitShape.DIAMOND:
			_draw_diamond_shape()
		UnitData.UnitShape.TRIANGLE:
			_draw_triangle_shape()
		UnitData.UnitShape.HEXAGON:
			_draw_hexagon_shape()

	_draw_rebuild_progress()
	_draw_health_bar()
	_draw_selection_ring()


func _draw_circle_shape() -> void:
	draw_circle(Vector2.ZERO, unit_size, unit_color)
	draw_arc(Vector2.ZERO, unit_size, 0, TAU, 24, unit_color.lightened(0.3), 1.5)


func _draw_diamond_shape() -> void:
	var s = unit_size
	var points = PackedVector2Array([
		Vector2(0, -s), Vector2(s, 0), Vector2(0, s), Vector2(-s, 0)
	])
	draw_polygon(points, [unit_color, unit_color, unit_color, unit_color])
	draw_polyline(
		PackedVector2Array([Vector2(0, -s), Vector2(s, 0), Vector2(0, s), Vector2(-s, 0), Vector2(0, -s)]),
		unit_color.lightened(0.3), 1.5
	)


func _draw_triangle_shape() -> void:
	var s = unit_size
	var points = PackedVector2Array([
		Vector2(0, -s), Vector2(s, s * 0.7), Vector2(-s, s * 0.7)
	])
	draw_polygon(points, [unit_color, unit_color, unit_color])
	draw_polyline(
		PackedVector2Array([Vector2(0, -s), Vector2(s, s * 0.7), Vector2(-s, s * 0.7), Vector2(0, -s)]),
		unit_color.lightened(0.3), 1.5
	)


func _draw_hexagon_shape() -> void:
	var points = PackedVector2Array()
	var colors = PackedColorArray()
	for i in range(6):
		var angle = i * TAU / 6.0
		points.append(Vector2(cos(angle), sin(angle)) * unit_size)
		colors.append(unit_color)
	draw_polygon(points, colors)
	var outline = PackedVector2Array()
	for i in range(7):
		var angle = i * TAU / 6.0
		outline.append(Vector2(cos(angle), sin(angle)) * unit_size)
	draw_polyline(outline, unit_color.lightened(0.3), 1.5)


func _draw_rebuild_progress() -> void:
	if not _rebuild_arrived or rebuild_target == null:
		return
	var pct := rebuild_timer / REBUILD_TIME
	var radius := unit_size + 6.0
	draw_arc(Vector2.ZERO, radius, -PI / 2.0, -PI / 2.0 + pct * TAU, 24, Color(0.3, 1.0, 0.5, 0.8), 2.0)


func _draw_health_bar() -> void:
	if health >= max_health:
		return

	var bar_width := 20.0
	var bar_height := 3.0
	var bar_offset := Vector2(-bar_width / 2.0, -unit_size - 6.0)

	draw_rect(
		Rect2(bar_offset, Vector2(bar_width, bar_height)),
		Color(0.2, 0.0, 0.0, 0.8),
		true
	)

	var health_pct = health / max_health
	var fill_color = Color(1.0 - health_pct, health_pct, 0.0)
	draw_rect(
		Rect2(bar_offset, Vector2(bar_width * health_pct, bar_height)),
		fill_color,
		true
	)

	draw_rect(
		Rect2(bar_offset, Vector2(bar_width, bar_height)),
		Color(0.8, 0.8, 0.8, 0.5),
		false,
		1.0
	)


func _draw_selection_ring() -> void:
	if not is_selected:
		return
	var ring_radius := unit_size + 4.0
	draw_arc(Vector2.ZERO, ring_radius, 0, TAU, 24, Color(1.0, 0.84, 0.0, 0.9), 2.0)
	draw_arc(Vector2.ZERO, ring_radius + 1.0, 0, TAU, 24, Color(1.0, 0.84, 0.0, 0.35), 1.0)
