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

# --- MANUAL COMBAT ORDERS (player right-click) ---
# When set, the unit chases & attacks this target until it's destroyed.
# These persist across re-pathing, while target_unit / target_building can be
# reassigned by auto-combat for opportunistic fire.
var manual_target_unit: Variant = null       # Node2D or null
var manual_target_building: Variant = null   # Vector2i or null
## Block id at `manual_target_building` when the order was issued. If the
## cell is destroyed and a new block is placed there, or the block gets
## converted to the unit's own faction, we compare against this snapshot
## so the unit stops attacking instead of chewing on the wrong target.
var manual_target_building_block_id: StringName = &""

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

# --- AIM ANGLE (for units with head_sprite) ---
# Current head facing in radians; 0 = +x (right). Smoothly lerps toward
# the angle of the active target each frame. Also used as a fallback body
# facing when the unit has a base_sprite but no head_sprite.
var aim_angle: float = 0.0
var _has_aim_target: bool = false

# --- FACING ANGLE (body/chassis rotation) ---
# Smoothly tracks the unit's movement direction, mirroring how the shardling
# rotates its sprite to face where it's going. Used to rotate base_sprite.
var facing_angle: float = 0.0
var _prev_position: Vector2 = Vector2.ZERO
var _facing_initialized: bool = false

# --- WATER SUBMERSION ---
# Tracks how long a ground/crawler unit has been standing in water. Used for
# visual tint and the drowning damage-over-time. Reset to 0 while out of water.
var _water_time: float = 0.0
## Seconds a ground/crawler unit can spend in water before it drowns and dies.
const WATER_DROWN_TIME := 8.0

# --- STUCK DETECTION ---
# When a unit has a destination but stays nearly stationary for STUCK_TIME seconds,
# it disperses away from nearby units AND requests a fresh path to its move_target /
# target_building so an obsolete path (e.g. a building placed across it) gets
# replaced. Repeated stuck events ramp up to a hard repath even if the unit hasn't
# fully cleared its origin radius.
var _stuck_timer := 0.0
var _stuck_origin := Vector2.ZERO
var _stuck_streak: int = 0           # Consecutive stuck triggers — escalates rescue
var _last_repath_time: float = -10.0 # Wall-clock seconds; throttled to REPATH_COOLDOWN
# Set while a manually-controlled unit runs `_check_wall_overlap` so the
# rescue can still slide the unit out of a solid cell without firing a
# repath the player never asked for.
var _skip_repath_on_unstick: bool = false
const STUCK_TIME := 1.5
const STUCK_RADIUS := 4.0    # Pixels — must move > this within STUCK_TIME or we're "stuck"
const REPATH_COOLDOWN := 1.0 # Per-unit floor on repath spam
# Throttle for the wall-overlap rescue. Cheap enough we could do it
# every tick but no need — a unit "phasing" into a wall via a building
# placement is a rare event.
var _wall_check_timer: float = 0.0
const WALL_CHECK_INTERVAL := 0.5

# --- REFERENCES (set by UnitManager) ---
var main: Node2D
var unit_manager: Node2D
# Cached sibling refs (populated in _ready). Avoid per-process lookups.
var _terrain: Node2D
var _combat_sys: Node



func _terrain_ref() -> Node2D:
	if _terrain == null:
		_terrain = get_node_or_null("/root/Main/TerrainSystem")
	return _terrain

func _combat_sys_ref() -> Node:
	if _combat_sys == null:
		_combat_sys = get_node_or_null("/root/Main/CombatSystem")
	return _combat_sys


## Returns true when the building at `grid_pos` belongs to the same
## faction as this unit's team — i.e. attacking it would be friendly
## fire. PLAYER units treat LUMINA as own-side; ENEMY units treat FEROX
## as own-side. DERELICT is considered "no-one's side" so units keep
## attacking derelict targets when explicitly ordered, but auto-target
## validators use this check to drop converted targets.
func _is_same_faction_as_target(grid_pos: Vector2i) -> bool:
	if main == null or not main.placed_buildings.has(grid_pos):
		return false
	var bfaction: int = main.get_building_faction(grid_pos)
	match team:
		UnitData.Team.PLAYER:
			return bfaction == main.Faction.LUMINA
		UnitData.Team.ENEMY:
			return bfaction == main.Faction.FEROX
	return false


## True only when `grid_pos` houses a building whose faction is the
## *opposing* side for this unit. DERELICT is neither side, so it's never
## a valid attack target — units shouldn't maul abandoned blocks, and a
## live target that converts to DERELICT (or to our own faction) should
## drop out of the attack queue immediately.
func _is_valid_attack_target(grid_pos: Vector2i) -> bool:
	if main == null or not main.placed_buildings.has(grid_pos):
		return false
	var bfaction: int = main.get_building_faction(grid_pos)
	match team:
		UnitData.Team.PLAYER:
			return bfaction == main.Faction.FEROX
		UnitData.Team.ENEMY:
			return bfaction == main.Faction.LUMINA
	return false


func _ready() -> void:
	_terrain = get_node_or_null("/root/Main/TerrainSystem")
	_combat_sys = get_node_or_null("/root/Main/CombatSystem")
	# Load stats from the UnitData resource. UnitData.move_speed is stored in
	# tiles/sec; convert once here into pixels/sec (what _tick_movement uses).
	if data:
		max_health = data.max_health
		move_speed = data.move_speed * float(main.GRID_SIZE)
		damage = data.attack_damage
		attack_cooldown = data.attack_speed
		unit_color = data.color
		# Hitbox radius: if the unit has textured rendering (base/head sprites),
		# derive unit_size from the on-screen texture footprint so hitboxes,
		# click targets, and projectile hit checks match what the player sees.
		# Falls back to the authored visual_size for shape-based units.
		var tex_for_hitbox: Texture2D = null
		if data.base_sprite != null:
			tex_for_hitbox = data.base_sprite
		elif data.head_sprite != null:
			tex_for_hitbox = data.head_sprite
		if tex_for_hitbox != null:
			var scale_f: float = (data.sprite_scale if data.sprite_scale > 0.0 else 1.0) * main.SPRITE_SCALE_FACTOR
			var sz: Vector2 = tex_for_hitbox.get_size() * scale_f
			# Average half-extent: roughly inscribed-circle radius for a square
			# sprite, and a sensible middle ground for rectangular ones.
			unit_size = (sz.x + sz.y) * 0.25
		else:
			unit_size = data.visual_size
	else:
		# Fallbacks (1.25 t/s * GRID_SIZE px/tile)
		push_warning("EnemyUnit: No UnitData assigned!")
		max_health = 50.0
		move_speed = 1.25 * float(main.GRID_SIZE)
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

	# PLAYER UNIT: allow shooting while moving. Opportunistic fire always ticks,
	# and manual targets (right-click orders) are pursued persistently.
	if is_controlled:
		# The player is driving this unit directly — skip every AI
		# behaviour that would fight or override their input. We don't
		# follow paths, don't try to attack, don't auto-rebuild, and
		# don't run stuck-detection (which would otherwise spam repath
		# requests at the path worker the player isn't using).
		# `_check_wall_overlap` still runs as a pure safety rescue:
		# it'll only snap the unit out of a solid cell, and we suppress
		# its repath side effect via `_skip_repath_on_unstick`.
		_skip_repath_on_unstick = true
		_check_wall_overlap(delta)
		_skip_repath_on_unstick = false
		_tick_water(delta)
		_tick_aim_angle(delta)
		_tick_facing_angle(delta)
		queue_redraw()
		return
	if data and team == UnitData.Team.PLAYER:
		_player_update(delta)
	else:
		if path.size() > 0 and path_index < path.size():
			_follow_path(delta)
		elif _is_rebuilder():
			_try_rebuild(delta)
		else:
			_try_attack(delta)

	_check_stuck(delta)
	_check_wall_overlap(delta)
	_tick_water(delta)
	_tick_aim_angle(delta)
	_tick_facing_angle(delta)
	queue_redraw()


## Smoothly rotates `facing_angle` toward the unit's current movement direction.
## Mirrors the shardling's chassis-rotates-to-face-travel behavior. When the
## unit is standing still, facing_angle keeps its last value instead of
## snapping back to 0.
func _tick_facing_angle(delta: float) -> void:
	if not _facing_initialized:
		_prev_position = position
		_facing_initialized = true
		# Seed facing to the first aim target if we have one so newly-spawned
		# units don't visibly swing from 0° on their first step.
		if _has_aim_target:
			facing_angle = aim_angle
		return
	# Tank-steering units drive their own facing from _follow_path (so the
	# chassis leads the motion instead of chasing it). Skip the velocity-
	# based update for them to avoid fighting that logic.
	if data and data.tank_steering:
		_prev_position = position
		return
	var velocity: Vector2 = position - _prev_position
	_prev_position = position
	# Require a small minimum movement to avoid jitter from pathing rounding.
	if velocity.length_squared() < 0.25:
		return
	var desired: float = velocity.angle()
	var turn_speed: float = data.body_turn_speed if data else 2.0
	facing_angle = _rotate_toward(facing_angle, desired, turn_speed * delta)


## Smoothly rotates `aim_angle` toward the best available reference point.
## Priority: active combat target → nearest hostile within detection_range →
## current path waypoint. When none apply, the head keeps its last angle
## (same idle behavior as a turret with no target).
func _tick_aim_angle(delta: float) -> void:
	var target_pos: Vector2
	var have_target: bool = false
	# Manual control: aim at the mouse cursor, matching controlled-turret behavior.
	if is_controlled:
		target_pos = get_global_mouse_position()
		have_target = true
	elif target_unit != null and is_instance_valid(target_unit) and not target_unit.is_dead:
		target_pos = target_unit.position
		have_target = true
	elif target_building != null and main.placed_buildings.has(target_building):
		target_pos = main.grid_to_world(target_building) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		have_target = true
	else:
		var scan_pos: Variant = _find_nearest_hostile_pos()
		if scan_pos != null:
			target_pos = scan_pos
			have_target = true
		elif path.size() > 0 and path_index < path.size():
			target_pos = path[path_index]
			if target_pos.distance_squared_to(position) > 1.0:
				have_target = true

	_has_aim_target = have_target
	if not have_target:
		return
	var desired: float = (target_pos - position).angle()
	var turn_speed: float = data.head_turn_speed if data else 3.0
	aim_angle = _rotate_toward(aim_angle, desired, turn_speed * delta)


## Rotates `from` toward `to` by at most `max_step` radians. Unlike lerp_angle
## this moves at a constant speed (matching the crane arm), so heavy units
## feel mechanical rather than magnetized to their target.
func _rotate_toward(from: float, to: float, max_step: float) -> float:
	var diff: float = wrapf(to - from, -PI, PI)
	if absf(diff) <= max_step:
		return to
	return wrapf(from + signf(diff) * max_step, -PI, PI)


## One step of tank-style locomotion.
##
## `desired_face` is the world-space angle we want to drive toward.
## `forward_step` is the distance the tank can cover this frame (pixels).
## `waypoint` / `dist_to_waypoint` are optional: when dist_to_waypoint > 0,
## the helper will honor path-waypoint snapping/advancement. Pass 0 when
## there is no path (manual control).
##
## Behavior:
## - When turn_radius > 0, the tank arcs around a pivot offset perpendicular
##   to its current facing. Rotation and translation happen together at a
##   rate determined by forward_step / turn_radius, so the chassis traces a
##   real curve (matches the labeled sketch the player drew).
## - When turn_radius <= 0, the tank pivots in place at body_turn_speed
##   until aligned, then drives forward. Same fallback as the old model.
func _tank_steer_step(desired_face: float, forward_step: float, waypoint: Vector2, dist_to_waypoint: float) -> void:
	var angle_err: float = wrapf(desired_face - facing_angle, -PI, PI)
	var turn_radius: float = data.turn_radius if data else 0.0
	var turn_speed: float = data.body_turn_speed if data and data.body_turn_speed > 0.0 else 2.0

	# Already aligned (or close enough): drive straight forward.
	if absf(angle_err) < 0.01 or forward_step <= 0.0:
		var straight_dir: Vector2 = Vector2.RIGHT.rotated(facing_angle)
		if dist_to_waypoint > 0.0 and forward_step >= dist_to_waypoint:
			position = waypoint
			path_index += 1
		else:
			position += straight_dir * forward_step
		return

	if turn_radius > 0.0:
		# Arc around a pivot perpendicular to the chassis. `signf(angle_err)`
		# picks which side the pivot sits on so the tank curves toward the
		# desired heading rather than away from it.
		var side_dir: Vector2 = Vector2.RIGHT.rotated(facing_angle + signf(angle_err) * PI / 2.0)
		var pivot: Vector2 = position + side_dir * turn_radius
		# Angular step from arc length; clamp to remaining error AND to the
		# configured body turn speed so the unit can't out-spin its authored
		# rotation limit on tight curves.
		var arc_step: float = forward_step / turn_radius
		var limit_step: float = turn_speed * get_process_delta_time() if turn_speed > 0.0 else arc_step
		var step_size: float = minf(absf(angle_err), minf(arc_step, limit_step))
		var d_angle: float = step_size * signf(angle_err)
		position = pivot + (position - pivot).rotated(d_angle)
		facing_angle = wrapf(facing_angle + d_angle, -PI, PI)
		return

	# turn_radius == 0: pivot in place until aligned, then drive.
	facing_angle = _rotate_toward(facing_angle, desired_face, turn_speed * get_process_delta_time())
	var err_after: float = absf(wrapf(desired_face - facing_angle, -PI, PI))
	if err_after < deg_to_rad(10.0):
		var fwd: Vector2 = Vector2.RIGHT.rotated(facing_angle)
		if dist_to_waypoint > 0.0 and forward_step >= dist_to_waypoint:
			position = waypoint
			path_index += 1
		else:
			position += fwd * forward_step


## Returns the world position of the nearest opposing unit (or Ferox building
## for player units) within `detection_range`, or null if nothing is visible.
## Used to keep heads tracking threats even when no attack is active.
func _find_nearest_hostile_pos() -> Variant:
	if data == null or unit_manager == null:
		return null
	var scan_r: float = data.detection_range if data.detection_range > 0.0 else data.attack_range * 4.0
	if scan_r <= 0.0:
		return null
	var best_dist_sq: float = scan_r * scan_r
	var best_pos: Variant = null

	# Look at opposing units
	var all_units: Array = unit_manager.enemies if "enemies" in unit_manager else []
	for u in all_units:
		if not is_instance_valid(u) or u.is_dead:
			continue
		if u.team == team:
			continue
		var d: float = position.distance_squared_to(u.position)
		if d < best_dist_sq:
			best_dist_sq = d
			best_pos = u.position

	# Buildings are intentionally skipped from the idle scan — iterating all
	# placed_buildings every frame per unit is too expensive. Units already
	# acquire building targets through the normal targeting pipeline
	# (target_building), which the first branch of _tick_aim_angle handles.
	return best_pos


## Ticks water submersion effects for ground / crawler units.
## Hover and flying units skip the check entirely (they just glide over).
## Ground/crawler units in water:
##   - move at the tile's speed_modifier (handled by _follow_path reading the tile)
##   - accumulate _water_time which tints them progressively blue
##   - die after WATER_DROWN_TIME seconds of continuous submersion
## _water_time is cleared the moment the unit steps back onto dry land.
func _tick_water(delta: float) -> void:
	if is_dead or data == null:
		return
	# Hover (2) and Flying (3) ignore water entirely.
	var ml: int = data.movement_layer
	if ml == UnitData.MovementLayer.HOVER or ml == UnitData.MovementLayer.FLYING:
		_water_time = 0.0
		return
	var terrain = _terrain_ref()
	if terrain == null:
		return
	var grid_pos: Vector2i = main.world_to_grid(position)
	var depth: int = terrain.get_water_depth_at(grid_pos)
	if depth <= 0:
		_water_time = 0.0
		return
	# Submerged.
	_water_time += delta
	if _water_time >= WATER_DROWN_TIME:
		take_damage(max_health)  # Fatal — drowned.


## Player-unit combined movement + combat tick.
## - Manual targets (right-click) are pursued until destroyed.
## - Otherwise auto-combat finds opportunistic targets.
## - Opportunistic firing runs EVERY frame so units can shoot while moving.
func _player_update(delta: float) -> void:
	# Validate manual targets (they might be destroyed meanwhile)
	if manual_target_unit != null:
		if not is_instance_valid(manual_target_unit) or manual_target_unit.is_dead:
			manual_target_unit = null
	if manual_target_building != null:
		# Cell empty → target gone. Different block at the same tile → the
		# block we were ordered to attack is gone too (replaced), stop.
		# Target faction no longer opposing (converted to our own side OR
		# to DERELICT) → drop the order; PLAYER units only fight FEROX and
		# ENEMY units only fight LUMINA, nothing attacks DERELICT.
		if not main.placed_buildings.has(manual_target_building):
			manual_target_building = null
			manual_target_building_block_id = &""
		else:
			var current_bid: StringName = main.placed_buildings[manual_target_building]
			if manual_target_building_block_id != &"" and current_bid != manual_target_building_block_id:
				manual_target_building = null
				manual_target_building_block_id = &""
			elif not _is_valid_attack_target(manual_target_building):
				manual_target_building = null
				manual_target_building_block_id = &""
	# Auto-acquired target_building should invalidate the same way so a
	# FEROX building that gets converted to DERELICT (or captured) stops
	# being fired at by in-flight attacks.
	if target_building != null:
		if not main.placed_buildings.has(target_building):
			target_building = null
		elif not _is_valid_attack_target(target_building):
			target_building = null

	# Decrement the shared attack timer so both path-following and auto-combat can fire.
	attack_timer = maxf(attack_timer - delta, -1.0)

	# 1. Pursue a manual target if we have one
	if manual_target_unit != null or manual_target_building != null:
		_pursue_manual_target(delta)
	# 2. Otherwise, if the player issued a pure move order, just travel
	elif move_target != null and path.size() > 0 and path_index < path.size():
		_follow_path(delta)
	# 3. Otherwise, fall through to auto-combat
	else:
		# Clear a completed move_target so auto-combat can re-engage
		if move_target != null and (path.size() == 0 or path_index >= path.size()):
			move_target = null
		_try_player_combat(delta)

	# Always attempt an opportunistic shot at any in-range hostile.
	_opportunistic_fire()


## Pursues whatever manual target is set: path toward it, stop in range, attack.
func _pursue_manual_target(delta: float) -> void:
	var target_pos: Vector2
	var atk_range: float = data.attack_range if data else main.GRID_SIZE / 2.0
	var effective_range: float = atk_range

	if manual_target_unit != null:
		target_pos = manual_target_unit.position
		target_unit = manual_target_unit
		target_building = null
	else:
		target_pos = main.grid_to_world(manual_target_building) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		target_building = manual_target_building
		target_unit = null
		effective_range = maxf(atk_range, main.GRID_SIZE * 1.5)

	var dist := position.distance_to(target_pos)
	if dist > effective_range:
		# Need to move closer. Re-request a path occasionally if we have none.
		if path.size() == 0 or path_index >= path.size():
			unit_manager.request_path_to_position_async_with_target(self, target_pos, manual_target_building)
		else:
			_follow_path(delta)
		return

	# In range — stop moving and attack.
	if path.size() > 0:
		path = PackedVector2Array()
		path_index = 0

	if attack_timer > 0:
		return
	attack_timer = attack_cooldown
	if manual_target_unit != null:
		_attack_enemy_unit()
	elif manual_target_building != null:
		_attack_ferox_building()


## Scans for any in-range hostile and fires a shot if the attack timer is ready.
## Does NOT move or change path. Runs every frame for all player units.
func _opportunistic_fire() -> void:
	if attack_timer > 0:
		return
	var atk_range: float = data.attack_range if data else 0.0
	if atk_range <= 0.0:
		return
	var range_sq: float = atk_range * atk_range

	# Prefer the currently-designated target if still valid and in range.
	if manual_target_unit != null and is_instance_valid(manual_target_unit) and not manual_target_unit.is_dead:
		if position.distance_squared_to(manual_target_unit.position) <= range_sq:
			attack_timer = attack_cooldown
			target_unit = manual_target_unit
			_attack_enemy_unit()
			return

	# Any nearby enemy unit
	for e in unit_manager.enemies:
		if not is_instance_valid(e) or e.is_dead:
			continue
		if e.team == UnitData.Team.PLAYER:
			continue
		if position.distance_squared_to(e.position) <= range_sq:
			attack_timer = attack_cooldown
			target_unit = e
			_attack_enemy_unit()
			return

	# Then any nearby FEROX building (opportunistic). Skip if the manual
	# target is no longer a valid attack target (captured, converted to
	# DERELICT, etc.) — `_player_update` clears it next frame, but we
	# don't want to get one last free shot off at an ally.
	if manual_target_building != null \
			and main.placed_buildings.has(manual_target_building) \
			and _is_valid_attack_target(manual_target_building):
		var bw: Vector2 = main.grid_to_world(manual_target_building) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		if position.distance_squared_to(bw) <= range_sq:
			attack_timer = attack_cooldown
			target_building = manual_target_building
			_attack_ferox_building()
			return


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

	# Ground/crawler units in water move at half speed (ignored by hover/flying).
	var speed_mult: float = 1.0
	if data:
		var ml_f: int = data.movement_layer
		if ml_f == UnitData.MovementLayer.GROUND or ml_f == UnitData.MovementLayer.CRAWLER:
			var terrain_f = _terrain_ref()
			if terrain_f and terrain_f.get_water_depth_at(main.world_to_grid(position)) > 0:
				speed_mult = 0.5
	var step = move_speed * speed_mult * delta

	# --- Tank-style steering -----------------------------------------------
	# Moves the tank along its current facing; when the desired direction
	# diverges from that facing, the motion arcs around a pivot point
	# perpendicular to the chassis (turn_radius) instead of pivoting in place.
	if data and data.tank_steering:
		_tank_steer_step(direction.angle(), step, target_pos, distance)
		return
	# -----------------------------------------------------------------------

	# Continuous separation from nearby same-layer units so a clump of
	# units slides past itself instead of pile-jamming until the 1.5 s
	# stuck-timer fires. The force is mixed into the path direction and
	# the resulting position is validated against the movement-layer
	# walkability map — separation can never push a unit onto a wall or
	# building.
	var sep: Vector2 = _compute_separation_force()
	var move_dir: Vector2 = direction
	if sep.length_squared() > 0.0001:
		move_dir = (direction + sep * 0.6).normalized()

	if step >= distance:
		position = target_pos
		path_index += 1
	else:
		var candidate: Vector2 = position + move_dir * step
		if move_dir == direction or unit_manager == null \
				or unit_manager.is_world_pos_walkable(candidate, data.movement_layer if data else 0):
			position = candidate
		else:
			# Separation-modified step would land on a wall — fall back
			# to the unmodified path step. A wall-overlap check will
			# still rescue us if even that ends up solid.
			position += direction * step


## Sums a soft repulsion vector from every same-layer unit within
## `unit_size * 2`. Falloff is quadratic so neighbours right on top
## push hard while distant ones barely register.
##
## When a neighbour is *overlapping* (within `unit_size`), this also
## directly shoves the other unit outward — the soft per-frame force
## alone struggles when the path gradient pulls every member of a
## clump toward the same destination, so we need an active push to
## break the symmetry. Each pair only shoves once (lower instance id
## drives the shove) so the work doesn't double up.
func _compute_separation_force() -> Vector2:
	if data == null or unit_manager == null:
		return Vector2.ZERO
	var ml: int = data.movement_layer
	var sep_radius: float = unit_size * 2.0
	if sep_radius <= 0.0:
		return Vector2.ZERO
	var force: Vector2 = Vector2.ZERO
	var overlap_thresh: float = unit_size
	var my_id: int = get_instance_id()
	# A moving unit's "intent" — direction toward the next path waypoint.
	# When set, an overlap with someone in front of us bulldozes them
	# forward along this axis instead of doing the symmetric pair shove,
	# so a unit can push through a wall of stationary blockers.
	var intent_dir: Vector2 = Vector2.ZERO
	if path.size() > 0 and path_index < path.size():
		var to_wp: Vector2 = path[path_index] - position
		if to_wp.length_squared() > 0.01:
			intent_dir = to_wp.normalized()
	var all_units: Array = unit_manager.enemies + unit_manager.player_units
	for other in all_units:
		if other == self or not is_instance_valid(other) or other.is_dead:
			continue
		if other.data == null or other.data.movement_layer != ml:
			continue
		var to_other: Vector2 = other.position - position
		var d: float = to_other.length()
		if d > sep_radius:
			continue
		# Co-located: pick a random direction so we still get a force
		# (and the active shove below has something to act on).
		var dir: Vector2
		if d < 0.001:
			var ang: float = randf() * TAU
			dir = Vector2(cos(ang), sin(ang))
			d = unit_size * 0.25
		else:
			dir = to_other / d
		var t: float = 1.0 - d / sep_radius
		var weight: float = t * t
		force -= dir * weight
		# Active shove on overlap.
		if d < overlap_thresh:
			# Push-through: if we're moving and `other` sits between us
			# and our next waypoint, shove them along our travel direction
			# without taking a counter-push ourselves. Lets a unit force
			# its way through a wall of stationary blockers.
			if intent_dir != Vector2.ZERO and dir.dot(intent_dir) > 0.3:
				var shove_amt: float = overlap_thresh - d
				var other_target: Vector2 = other.position + intent_dir * shove_amt
				var other_ml: int = other.data.movement_layer
				if other.unit_manager != null \
						and other.unit_manager.is_world_pos_walkable(other_target, other_ml):
					other.position = other_target
				continue
			# Otherwise fall through to the symmetric pair shove. Lower
			# instance id drives both halves so the work doesn't double.
			if my_id < other.get_instance_id():
				var shove_amt: float = (overlap_thresh - d) * 0.5
				var other_target: Vector2 = other.position + dir * shove_amt
				var other_ml: int = other.data.movement_layer
				if other.unit_manager != null \
						and other.unit_manager.is_world_pos_walkable(other_target, other_ml):
					other.position = other_target
				var my_target: Vector2 = position - dir * shove_amt
				if unit_manager.is_world_pos_walkable(my_target, ml):
					position = my_target
	return force


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

	# Only attack opposing-faction buildings. DERELICT is off-limits for
	# both teams — neutral blocks shouldn't get chewed on just because a
	# unit ended up near one.
	if not _is_valid_attack_target(target_building):
		target_building = null
		unit_manager.request_new_path(self)
		return

	attack_timer = attack_cooldown

	# Check if this enemy has ranged attacks
	# attack_range > 0 in the .tres means it shoots projectiles
	if data and data.attack_range > 0:
		# RANGED ATTACK: Fire a projectile via CombatSystem
		var combat = _combat_sys_ref()
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
## NOTE: attack_timer is ticked by _player_update now (once per frame), so we
## don't decrement it again here.
func _try_player_combat(_delta: float) -> void:
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
	var atk_range: float = data.attack_range if data else main.GRID_SIZE / 2.0

	# Buildings occupy solid cells so units can't stand on them.
	# Ensure the effective range is at least 1.5 grid cells so units
	# on adjacent tiles can attack.
	var effective_range: float = atk_range
	if target_building != null:
		effective_range = maxf(atk_range, main.GRID_SIZE * 1.5)

	# Not in range — pathfind toward target
	if dist > effective_range:
		if path.size() == 0 or path_index >= path.size():
			unit_manager.request_path_to_position_async_with_target(self, target_pos, target_building)
		else:
			_follow_path(_delta)
		return

	# In range — stop moving and fire
	if path.size() > 0:
		path = PackedVector2Array()
		path_index = 0
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
	var combat = _combat_sys_ref()
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
	var combat = _combat_sys_ref()
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
	var combat = _combat_sys_ref()
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
## After STUCK_TIME seconds of being stuck, escalates through three rescues:
##   1st trigger: nudge away from the cluster centroid.
##   2nd trigger: repath to the original destination — disperse alone can't
##                fix a path that's been obsoleted by terrain changes.
##   3rd+:        both, plus a wider search radius for the disperse nudge.
func _check_stuck(delta: float) -> void:
	var has_destination: bool = (path.size() > 0 and path_index < path.size()) or move_target != null
	if not has_destination:
		_stuck_timer = 0.0
		_stuck_streak = 0
		return

	# Start tracking from current position when timer resets
	if _stuck_timer == 0.0:
		_stuck_origin = position

	_stuck_timer += delta

	if _stuck_timer >= STUCK_TIME:
		if position.distance_to(_stuck_origin) < STUCK_RADIUS:
			_stuck_streak += 1
			# Always try the cheap, local fix first.
			_disperse_from_nearby_units()
			# If we've been stuck more than once, the path itself is
			# probably the problem — request a fresh one to whatever
			# destination we still have.
			if _stuck_streak >= 2:
				_request_repath()
		else:
			# We did make progress this window — reset the streak.
			_stuck_streak = 0
		# Re-evaluate after another STUCK_TIME window regardless.
		_stuck_timer = 0.0


## Requests a fresh path back to the unit's outstanding destination
## (move_target world pos OR target_building grid cell). Throttled so a
## stuck unit can't spam the path worker every tick.
func _request_repath() -> void:
	if unit_manager == null or main == null:
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _last_repath_time < REPATH_COOLDOWN:
		return
	# Pick the most authoritative destination.
	var dest: Variant = null
	if target_building != null and main.placed_buildings.has(target_building):
		dest = main.grid_to_world(target_building) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
	elif move_target != null and move_target is Vector2:
		dest = move_target
	elif path.size() > 0:
		# Fall back to the existing path's final waypoint so a unit with
		# no remembered destination still tries something.
		dest = path[path.size() - 1]
	if dest == null or not (dest is Vector2):
		return
	_last_repath_time = now
	if target_building != null and unit_manager.has_method("request_path_to_position_async_with_target"):
		unit_manager.request_path_to_position_async_with_target(self, dest, target_building)
	elif unit_manager.has_method("request_path_to_position_async"):
		unit_manager.request_path_to_position_async(self, dest)
	elif unit_manager.has_method("assign_path_to_position"):
		unit_manager.assign_path_to_position(self, dest)


## Pushes this unit away from the centroid of nearby same-layer units.
## Periodic safety check — if the unit's current cell turned solid for
## its movement layer (e.g. a building was placed on top of it, or a
## disperse / push from another unit landed it on a wall), search a small
## ring of neighbours for a walkable cell and slide there. Throttled so
## the cost is negligible per-unit.
func _check_wall_overlap(delta: float) -> void:
	_wall_check_timer -= delta
	if _wall_check_timer > 0.0:
		return
	_wall_check_timer = WALL_CHECK_INTERVAL
	if data == null or unit_manager == null:
		return
	if data.movement_layer == UnitData.MovementLayer.FLYING:
		return
	# If the *next* waypoint we're heading toward is no longer walkable,
	# the path is stale (typically: a building or wall got placed across
	# it). Trigger a repath immediately instead of marching into the
	# obstacle and waiting for stuck-detection to time out. Suppressed
	# while manually controlled — the player owns movement, not AI.
	if not _skip_repath_on_unstick and path.size() > 0 and path_index < path.size():
		var next_wp: Vector2 = path[path_index]
		if not unit_manager.is_world_pos_walkable(next_wp, data.movement_layer):
			_request_repath()
	if unit_manager.is_world_pos_walkable(position, data.movement_layer):
		return
	# Spiral outward looking for a free cell.
	var here: Vector2i = main.world_to_grid(position)
	for radius in range(1, 5):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if absi(dx) != radius and absi(dy) != radius:
					continue
				var probe: Vector2i = here + Vector2i(dx, dy)
				var probe_world: Vector2 = main.grid_to_world(probe) + Vector2(main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5)
				if unit_manager.is_world_pos_walkable(probe_world, data.movement_layer):
					position = probe_world
					# Position changed — the existing path is now garbage,
					# pull a fresh one to wherever we were heading.
					# Skipped while manually controlled (player owns
					# movement, not the path worker).
					if not _skip_repath_on_unstick:
						_request_repath()
					return


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

	# Nudge away — enough to break the cluster but not teleport across
	# the map. Validate the destination against the unit's movement
	# layer first so a disperse never pushes someone onto a wall /
	# building / void cell. If the primary direction is blocked, try a
	# few rotated alternates before giving up; better to stay clustered
	# one tick than to phase through a wall.
	var nudge_dist := unit_size * 3.0
	var ml: int = data.movement_layer if data else 0
	var candidate_dirs: Array[Vector2] = [
		away_dir,
		away_dir.rotated(deg_to_rad(45.0)),
		away_dir.rotated(deg_to_rad(-45.0)),
		away_dir.rotated(deg_to_rad(90.0)),
		away_dir.rotated(deg_to_rad(-90.0)),
	]
	var moved := false
	for dir in candidate_dirs:
		var target_pos: Vector2 = position + dir * nudge_dist
		if unit_manager.is_world_pos_walkable(target_pos, ml):
			position = target_pos
			moved = true
			break
	if not moved:
		return

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

	# Textured rendering (turret-style: base + rotating head) takes precedence
	# over the primitive-shape fallbacks whenever the .tres supplies sprites.
	var drew_textured: bool = false
	if data and (data.base_sprite != null or data.head_sprite != null):
		_draw_textured_unit()
		drew_textured = true

	if not drew_textured:
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
	if main and main.show_hitboxes:
		draw_arc(Vector2.ZERO, unit_size, 0, TAU, 32, Color(1.0, 0.2, 0.9, 0.9), 1.5)


## Renders the unit as a stacked base + rotating head, mirroring the
## turret_head_sprite pattern (source textures face UP, so +PI/2 is added
## to convert the aim angle into a texture angle). Tinted by water state.
func _draw_textured_unit() -> void:
	var tint: Color = _get_display_color()
	# Preserve alpha but otherwise render the textures at full brightness
	# unless the unit is drowning (then lerp toward blue like the shapes do).
	var base_tint: Color = Color(1, 1, 1, tint.a)
	if _water_time > 0.0:
		base_tint = tint
	var scale_f: float = (data.sprite_scale if data and data.sprite_scale > 0.0 else 1.0) * main.SPRITE_SCALE_FACTOR

	if data.base_sprite:
		var b_size: Vector2 = data.base_sprite.get_size() * scale_f
		# Base rotates to face the unit's current movement direction (the
		# shardling-style chassis rotation). Source art faces UP, so the
		# usual +PI/2 offset converts facing_angle into a texture angle.
		draw_set_transform(Vector2.ZERO, facing_angle + PI / 2.0)
		draw_texture_rect(
			data.base_sprite,
			Rect2(-b_size * 0.5, b_size),
			false,
			base_tint
		)
		draw_set_transform(Vector2.ZERO, 0.0)

	if data.head_sprite:
		var h_size: Vector2 = data.head_sprite.get_size() * scale_f
		var h_angle: float = aim_angle + PI / 2.0
		draw_set_transform(Vector2.ZERO, h_angle)
		draw_texture_rect(
			data.head_sprite,
			Rect2(-h_size * 0.5, h_size),
			false,
			base_tint
		)
		draw_set_transform(Vector2.ZERO, 0.0)


## Returns the current body color, blended toward deep blue based on how long
## the unit has been submerged. At 0 time → base unit_color. At drown time →
## almost fully blue. Hover/flying units never accumulate _water_time so they
## always draw with their base color.
func _get_display_color() -> Color:
	if _water_time <= 0.0:
		return unit_color
	var t: float = clampf(_water_time / WATER_DROWN_TIME, 0.0, 1.0)
	var water_tint := Color(0.15, 0.35, 0.8, unit_color.a)
	return unit_color.lerp(water_tint, t * 0.75)


func _draw_circle_shape() -> void:
	var c := _get_display_color()
	draw_circle(Vector2.ZERO, unit_size, c)
	draw_arc(Vector2.ZERO, unit_size, 0, TAU, 24, c.lightened(0.3), 1.5)


func _draw_diamond_shape() -> void:
	var s = unit_size
	var c := _get_display_color()
	var points = PackedVector2Array([
		Vector2(0, -s), Vector2(s, 0), Vector2(0, s), Vector2(-s, 0)
	])
	draw_polygon(points, [c, c, c, c])
	draw_polyline(
		PackedVector2Array([Vector2(0, -s), Vector2(s, 0), Vector2(0, s), Vector2(-s, 0), Vector2(0, -s)]),
		c.lightened(0.3), 1.5
	)


func _draw_triangle_shape() -> void:
	var s = unit_size
	var c := _get_display_color()
	var points = PackedVector2Array([
		Vector2(0, -s), Vector2(s, s * 0.7), Vector2(-s, s * 0.7)
	])
	draw_polygon(points, [c, c, c])
	draw_polyline(
		PackedVector2Array([Vector2(0, -s), Vector2(s, s * 0.7), Vector2(-s, s * 0.7), Vector2(0, -s)]),
		c.lightened(0.3), 1.5
	)


func _draw_hexagon_shape() -> void:
	var c := _get_display_color()
	var points = PackedVector2Array()
	var colors = PackedColorArray()
	for i in range(6):
		var angle = i * TAU / 6.0
		points.append(Vector2(cos(angle), sin(angle)) * unit_size)
		colors.append(c)
	draw_polygon(points, colors)
	var outline = PackedVector2Array()
	for i in range(7):
		var angle = i * TAU / 6.0
		outline.append(Vector2(cos(angle), sin(angle)) * unit_size)
	draw_polyline(outline, c.lightened(0.3), 1.5)


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
	# Only draw the selection ring while the player is in unit mode.
	if unit_manager and "unit_mode_active" in unit_manager and not unit_manager.unit_mode_active:
		return
	var ring_radius := unit_size + 4.0
	draw_arc(Vector2.ZERO, ring_radius, 0, TAU, 24, Color(1.0, 0.84, 0.0, 0.9), 2.0)
	draw_arc(Vector2.ZERO, ring_radius + 1.0, 0, TAU, 24, Color(1.0, 0.84, 0.0, 0.35), 1.0)
