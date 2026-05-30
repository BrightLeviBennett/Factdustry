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
# See `_ready` — high-z CanvasGroup that owns the flying-unit shadow
# composition. Built on `_ready` only for flying units (movement_layer
# == FLYING); ground units leave both refs null and never draw a shadow.
var _shadow_canvas: CanvasGroup = null
var _shadow_drawer: Node2D = null
var unit_color: Color
var unit_size: float

# --- STATE ---
var health: float
var path: PackedVector2Array = PackedVector2Array()
var path_index := 0
# Cell currently held in `unit_manager._water_platform_reservation`, so
# we can release it the moment we step off / die / get repathed.
var _reserved_platform_cell: Vector2i = Vector2i(-32768, -32768)
var attack_timer := 0.0
var target_building: Variant = null
var is_dead := false
var is_selected := false

# --- STATUS EFFECTS ---
# id -> { "effect": StatusEffectData, "time_left": float, "stacks": int,
#         "boost": float (1.0 default; >1.0 if amplified by an affinity) }
var active_statuses: Dictionary = {}
var _status_tick_acc: float = 0.0

# --- FOG VISIBILITY CACHE ---
# Refreshed by `_update_fog_visibility` once every _FOG_CHECK_INTERVAL
# seconds. Toggling `visible` (a Node2D property) is much cheaper than
# guarding `_draw` because Godot skips the entire redraw path when
# the node is invisible.
var _fog_check_accum: float = 999.0   # force an initial check
const _FOG_CHECK_INTERVAL: float = 0.15
var is_controlled := false  # True when the player is directly controlling this unit

# --- FLYING-UNIT HOVER ORBIT ---
# Flying units that aren't currently being driven by the player drift
# in a small circle so they read as hovering instead of pasted in
# place. The orbit is applied as a position delta (not a render-only
# offset) so any per-frame visual element attached to the unit —
# health bar, shadow, projectile spawn, etc. — follows along
# naturally. Radius is small enough not to disturb pathfinding /
# combat.
const _ORBIT_RADIUS: float = 5.0           # pixels
const _ORBIT_SPEED: float = 1.4            # rad/sec
const _ORBIT_DECAY_RATE: float = 6.0       # how fast offset settles back to 0
var _orbit_phase: float = 0.0
var _orbit_prev_off: Vector2 = Vector2.ZERO
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

# --- COMMAND TOGGLES (player issued via the unit-mode button row) ---
## Skip every attack call for this unit while true. Movement / pathing
## still runs normally; only the fire path is gated.
var hold_fire: bool = false
## Toggle: while true, the unit will turn itself into a payload as soon
## as it's standing on a payload-receiving block (payload / freight
## conveyor, mass driver, or deconstructor). Cleared automatically once
## the unit has been ingested. The player can re-toggle it off before
## ingestion to abort.
var enter_payload_when_able: bool = false
## When the player right-clicks a payload-accepting block (typically a
## deconstructor) with `enter_payload_when_able` enabled, this anchor
## is latched so the unit will path adjacent to that specific block
## and hand itself off as soon as it's touching the footprint — even
## if the unit is too large to physically stand on the block. Cleared
## on successful ingestion, on death, on a new move/attack order, or
## when the building disappears.
var payload_target_anchor: Vector2i = Vector2i(-9999, -9999)
## Toggle: while true, the unit pulls from main.work_order — paths to
## the nearest in-flight build plan and stays in range so the build
## tick can keep progressing. Only meaningful for units whose data.id
## opts into building (`data.category == UnitData.UnitCategory.BUILDER`).
var assist_player_build: bool = false
## Set to the item_id the unit is currently mining toward (e.g.
## "mat_copper"). Empty StringName = not mining. Only meaningful for
## units whose data.id opts into mining (see `can_mine_units` in
## UnitManager). The unit seeks the nearest matching ore, mines into
## `mined_inventory`, and delivers to the closest core.
var mining_request_id: StringName = &""
## Per-unit pickup inventory for mining. item_id → count. Capped by
## `mined_inventory_cap`.
var mined_inventory: Dictionary = {}
var mined_inventory_cap: int = 30
var _mine_timer: float = 0.0
var _mine_target_cell: Vector2i = Vector2i(-9999, -9999)
var _mine_deliver_cell: Vector2i = Vector2i(-9999, -9999)

# --- BOTTLENECK YIELD / OSCILLATION BREAK ---
# Set by `_compute_separation_force` when this unit loses a same-direction
# overlap race against another unit closer to the shared goal. While > 0
# the unit skips its movement step entirely (path stays, just doesn't
# advance), letting the leader clear the chokepoint.
var _yield_timer: float = 0.0
# Counts same-direction overlap events in a sliding window so a unit that
# keeps losing the yield contest can escalate to a hard wait + repath.
var _pushback_count: int = 0
var _pushback_window: float = 0.0   # seconds remaining in the count's window
const _PUSHBACK_WINDOW_SEC := 1.5
const _PUSHBACK_HARD_THRESH := 6     # events in window before hard-yield kicks in
const _PUSHBACK_HARD_YIELD := 2.0    # seconds to freeze + repath
# Set true after a hard-yield fires so the next `_process` tick requests
# a fresh path (we can't call into UnitManager from the separator pass).
var _needs_hard_repath: bool = false

# --- RUNTIME TEAM ---
# Set by UnitManager at spawn time (overrides team which defaults to PLAYER in .tres)
var team: int = UnitData.Team.ENEMY

# --- FEROX SQUAD MEMBERSHIP ---
## Grid anchor of the fabricator that spawned this enemy. Vector2i(-1, -1)
## for wave/nest enemies that don't belong to a squad.
var squad_anchor: Vector2i = Vector2i(-1, -1)
## True while the unit is waiting at the squad's rally point. When the
## squad releases (or the unit gets pulled into an engagement), this
## flips to false and normal pathing / attack flow resumes.
var is_rallying: bool = false

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
# Mindustry-style "blocked-this-frame" counter. Ticks up every frame
# the move step actually fails to advance, regardless of position. A
# unit pressed against a freshly-placed wall flatlines its position
# but `_stuck_timer` only fires after STUCK_TIME (1.5 s). This shorter
# counter triggers a repath in ~12 frames (~0.2 s) so the unit picks
# a new route the instant the world changes under it.
var _blocked_frames: int = 0
const _BLOCKED_FRAMES_REPATH: int = 12
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
	# Flying units render with a high absolute z so their entire
	# canvas (chassis + drop-shadow drawn on the same surface) sits
	# above ground units (default z=0). z_as_relative=false locks
	# the absolute value so any parent re-parenting can't pull it
	# back down. Picked 81 — above ground units (0) and placed
	# blocks (50), below the combat overlay (70+) and unit/HUD
	# layers (4095+). The PREVIOUS CanvasGroup approach put the
	# shadow on a private buffer that apparently wasn't compositing
	# in our build; drawing on the unit's own canvas with a bumped
	# z is the simplest reliable path.
	if data and data.movement_layer == UnitData.MovementLayer.FLYING:
		# Godot 4 caps z_index at 4096. Use the cap so flying units
		# render above absolutely everything in the world layer —
		# ground units, AI shardlings (4095), blocks, fog. Combat
		# overlays at z=4095+ may still paint above on a tie, but
		# the shadow is guaranteed above ground.
		z_index = 4096
		z_as_relative = false
		print("[enemy_unit] flying z=4096 applied for %s" % str(data.id))
	# Stagger each flying unit's hover-orbit so a squad doesn't bob in
	# lockstep — the random phase makes a group look organic.
	_orbit_phase = randf() * TAU
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


## Applies a status effect to this unit, honouring opposites
## (canceling both effects) and affinities (boosting both effects'
## modifier magnitudes). If neither relation applies, the effect is
## just added/refreshed.
func apply_status_effect(effect: StatusEffectData) -> void:
	if effect == null or effect.id == &"":
		return
	# OPPOSITES: applying an effect that this unit already has an
	# opposite of cancels both (matches the user's default rule).
	for existing_id in active_statuses.keys():
		var existing_eff: StatusEffectData = active_statuses[existing_id]["effect"]
		if existing_eff == null:
			continue
		var is_opp: bool = (effect.opposites.has(existing_id)
			or existing_eff.opposites.has(effect.id))
		if is_opp:
			active_statuses.erase(existing_id)
			return  # New effect cancels with existing; neither persists.
	# AFFINITIES: applying an effect that this unit already has an
	# affinity of doubles the modifier deviation for both.
	var boost_new: float = 1.0
	for existing_id2 in active_statuses.keys():
		var existing_eff2: StatusEffectData = active_statuses[existing_id2]["effect"]
		if existing_eff2 == null:
			continue
		var is_aff: bool = (effect.affinities.has(existing_id2)
			or existing_eff2.affinities.has(effect.id))
		if is_aff:
			boost_new = 2.0
			# Boost the existing affinity too.
			active_statuses[existing_id2]["boost"] = 2.0
	# Add or refresh the effect.
	if active_statuses.has(effect.id) and effect.refresh_on_reapply:
		active_statuses[effect.id]["time_left"] = effect.duration
		if effect.stackable:
			active_statuses[effect.id]["stacks"] = mini(int(active_statuses[effect.id]["stacks"]) + 1, effect.max_stacks)
	else:
		active_statuses[effect.id] = {
			"effect": effect,
			"time_left": effect.duration,
			"stacks": 1,
			"boost": boost_new,
		}


func _tick_status_effects(delta: float) -> void:
	if active_statuses.is_empty():
		return
	_status_tick_acc += delta
	var expire: Array = []
	for sid in active_statuses:
		var ent: Dictionary = active_statuses[sid]
		ent["time_left"] = float(ent["time_left"]) - delta
		if float(ent["time_left"]) <= 0.0:
			expire.append(sid)
			continue
		var se: StatusEffectData = ent["effect"]
		# DoT tick — tick_damage > 0 dealt every tick_interval.
		if se != null and se.tick_damage > 0.0 and se.tick_interval > 0.0:
			if _status_tick_acc >= se.tick_interval:
				var dmg: float = se.tick_damage * float(ent.get("stacks", 1)) * float(ent.get("boost", 1.0))
				health -= dmg
	if _status_tick_acc >= 0.5:
		_status_tick_acc = 0.0
	for sid in expire:
		active_statuses.erase(sid)


func _process(delta: float) -> void:
	if is_dead:
		return
	# Fog visibility for ENEMY units is updated every few physics
	# frames rather than every draw. Toggling Node2D.visible lets
	# Godot skip the whole queued-redraw path while the unit is
	# under fog. PLAYER units are always shown.
	_fog_check_accum += delta
	if _fog_check_accum >= _FOG_CHECK_INTERVAL:
		_fog_check_accum = 0.0
		_update_fog_visibility()
	if main.world_paused:
		return
	_tick_status_effects(delta)
	# Hovering-orbit motion for flying units that aren't currently
	# under direct player control. Applied as a position delta so it
	# composes naturally with regular movement (the orbit just adds a
	# small per-frame wobble on top of whatever AI / path motion the
	# unit is already doing).
	_tick_hover_orbit(delta)

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
		# In-flight engagement: a FEROX unit walking past a vulnerable
		# player unit shouldn't just keep marching while taking fire.
		# Snap onto the nearest in-range LUMINA unit, hold position,
		# and shoot until it dies / leaves range. Rallying enemies
		# defend themselves too — the squad shouldn't be a sitting duck.
		if data and main.enemies_attack:
			var hostile := _ferox_find_engageable_player_unit()
			if hostile != null:
				_ferox_engage_unit(hostile, delta)
				_check_stuck(delta)
				_check_wall_overlap(delta)
				_tick_water(delta)
				_tick_aim_angle(delta)
				_tick_facing_angle(delta)
				queue_redraw()
				return
		if path.size() > 0 and path_index < path.size():
			_follow_path(delta)
		elif _is_rebuilder():
			_try_rebuild(delta)
		elif is_rallying:
			# Sitting at the rally point with no path left — just hold
			# position. Squad release will push us back into the world.
			pass
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
	# Mindustry-style anti-stuck guards apply here too — tank-steering
	# units share the same blocked-frames → fast repath escalation as
	# omnidirectional units. Tanks can't perpendicular-slide (they're
	# locked to their facing axis), so the rescue is just "reject the
	# step + bump the counter". The wider `_check_stuck` / wall-overlap
	# rescue further down catches the cases the fast repath misses.
	var ml_walk: int = data.movement_layer if data else 0
	var step_walkable := func(p: Vector2) -> bool:
		return unit_manager == null \
			or unit_manager.is_world_pos_walkable(p, ml_walk, team)
	var moved: bool = false

	# Already aligned (or close enough): drive straight forward.
	if absf(angle_err) < 0.01 or forward_step <= 0.0:
		var straight_dir: Vector2 = Vector2.RIGHT.rotated(facing_angle)
		if dist_to_waypoint > 0.0 and forward_step >= dist_to_waypoint:
			if step_walkable.call(waypoint):
				position = waypoint
				path_index += 1
				moved = true
		else:
			var cand: Vector2 = position + straight_dir * forward_step
			if step_walkable.call(cand):
				position = cand
				moved = true
		_tank_track_blocked(moved)
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
		var arc_pos: Vector2 = pivot + (position - pivot).rotated(d_angle)
		if step_walkable.call(arc_pos):
			position = arc_pos
			facing_angle = wrapf(facing_angle + d_angle, -PI, PI)
			moved = true
		else:
			# Walls along the arc — still rotate in place so the tank's
			# heading converges toward the desired direction, but don't
			# translate. Lets the unit pivot away from a wall it just
			# drove into instead of locking up.
			facing_angle = wrapf(facing_angle + d_angle, -PI, PI)
		_tank_track_blocked(moved)
		return

	# turn_radius == 0: pivot in place until aligned, then drive.
	facing_angle = _rotate_toward(facing_angle, desired_face, turn_speed * get_process_delta_time())
	var err_after: float = absf(wrapf(desired_face - facing_angle, -PI, PI))
	if err_after < deg_to_rad(10.0):
		var fwd: Vector2 = Vector2.RIGHT.rotated(facing_angle)
		if dist_to_waypoint > 0.0 and forward_step >= dist_to_waypoint:
			if step_walkable.call(waypoint):
				position = waypoint
				path_index += 1
				moved = true
		else:
			var cand2: Vector2 = position + fwd * forward_step
			if step_walkable.call(cand2):
				position = cand2
				moved = true
	else:
		# Still rotating into alignment — not "blocked", just pivoting.
		moved = true
	_tank_track_blocked(moved)


## Tank counterpart of the omnidirectional step's blocked-frames track.
## Tanks can't perpendicular-slide, but they DO share the fast-repath
## escalation so a tank pressed against a freshly-placed wall picks a
## new route in ~0.2 s instead of waiting on the 1.5 s spatial timer.
func _tank_track_blocked(moved: bool) -> void:
	if moved:
		_blocked_frames = 0
	else:
		_blocked_frames += 1
		if _blocked_frames >= _BLOCKED_FRAMES_REPATH:
			_request_repath()
			_blocked_frames = 0


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
	# Standing on a platform tile — we're on dry boards, not actually in
	# the water. Drowning timer pauses and resets.
	if unit_manager and unit_manager._is_platform_cell(grid_pos):
		_water_time = 0.0
		return
	# Shallow water (depth=1) is the "sand visible through the surface"
	# tier — wading depth, not enough to drown a ground unit. Treat it
	# like dry land for the drowning timer.
	if depth <= 1:
		_water_time = 0.0
		return
	# Submerged in medium/deep water.
	_water_time += delta
	if _water_time >= WATER_DROWN_TIME:
		take_damage(max_health)  # Fatal — drowned.


## Player-unit combined movement + combat tick.
## - Manual targets (right-click) are pursued until destroyed.
## - Otherwise auto-combat finds opportunistic targets.
## - Opportunistic firing runs EVERY frame so units can shoot while moving.
func _player_update(delta: float) -> void:
	# Player-issued command toggles take priority over any other AI.
	# Enter-Payload: if the unit is sitting on a payload-receiving block,
	# hand it off and let the despawn handler clean up. The toggle stays
	# armed until that hand-off succeeds OR the player turns it back off.
	if enter_payload_when_able:
		if _try_enter_payload_block():
			return  # We've been removed from the world; nothing else to tick.

	# Hold-fire is a pure "skip the trigger". Manual move / auto-combat
	# pursuit (which moves the unit into range) still runs — only the
	# actual attack call is gated, inside the fire helpers below.

	# Mining and assist-build pull on the unit when the player has no
	# manual order outstanding. They short-circuit the rest of the tick
	# when they own the unit's movement this frame.
	if mining_request_id != &"" and manual_target_unit == null and manual_target_building == null and move_target == null:
		if _tick_mining(delta):
			_opportunistic_fire()
			return
	if assist_player_build and manual_target_unit == null and manual_target_building == null and move_target == null:
		if _tick_assist_build(delta):
			_opportunistic_fire()
			return

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

	if hold_fire:
		return
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
	if hold_fire:
		return
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
	# Bottleneck yield: this unit lost a same-direction overlap race
	# against another unit closer to the shared goal. Skip the movement
	# step entirely so the leader can clear the chokepoint. Hard-yield
	# requests a fresh path on its first tick so the unit re-plans around
	# the bottleneck instead of just waiting.
	if _yield_timer > 0.0:
		_yield_timer = maxf(0.0, _yield_timer - delta)
		if _needs_hard_repath:
			_needs_hard_repath = false
			if unit_manager:
				unit_manager.request_new_path(self)
		return
	# Decay the sliding-window pushback counter so old contests don't
	# escalate later peaceful traffic into a hard freeze.
	if _pushback_window > 0.0:
		_pushback_window = maxf(0.0, _pushback_window - delta)
		if _pushback_window == 0.0:
			_pushback_count = 0
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

	# Ground/crawler units in water move at half speed (ignored by hover/
	# flying). Exemptions:
	#   - Standing on a platform tile: we're on dry boards, not in the
	#     water. Full speed.
	#   - Shallow water (depth=1, sand visible through the surface):
	#     wading depth; speed unaffected.
	var speed_mult: float = 1.0
	if data:
		var ml_f: int = data.movement_layer
		if ml_f == UnitData.MovementLayer.GROUND or ml_f == UnitData.MovementLayer.CRAWLER:
			var terrain_f = _terrain_ref()
			if terrain_f:
				var unit_grid: Vector2i = main.world_to_grid(position)
				var d_f: int = terrain_f.get_water_depth_at(unit_grid)
				var on_platform: bool = unit_manager != null and unit_manager._is_platform_cell(unit_grid)
				if d_f > 1 and not on_platform:
					speed_mult = 0.5

	# Water-platform gate: a ground/crawler unit may only step onto a
	# water-platform cell that nobody else is currently traversing. We
	# reserve the next cell we're about to step onto (or our current
	# cell, if it's already a platform). If the next cell is held by
	# somebody else, freeze in place this frame instead of marching
	# onto an occupied plank. Air / hover units skip the check entirely
	# (they fly over).
	const _NO_PLATFORM := Vector2i(-32768, -32768)
	if data and unit_manager:
		var ml_p: int = data.movement_layer
		if ml_p == UnitData.MovementLayer.GROUND or ml_p == UnitData.MovementLayer.CRAWLER:
			var cur_cell: Vector2i = main.world_to_grid(position)
			var tgt_cell: Vector2i = main.world_to_grid(target_pos)
			# Decide which cell we WANT to be holding this frame.
			var desired_cell: Vector2i = _NO_PLATFORM
			if tgt_cell != cur_cell and unit_manager._is_water_platform_cell(tgt_cell):
				desired_cell = tgt_cell
			elif unit_manager._is_water_platform_cell(cur_cell):
				desired_cell = cur_cell
			if desired_cell == _NO_PLATFORM:
				# Out of platform territory entirely — release anything we
				# might have been holding.
				if _reserved_platform_cell != _NO_PLATFORM:
					unit_manager.release_platform(self, _reserved_platform_cell)
					_reserved_platform_cell = _NO_PLATFORM
			elif desired_cell == _reserved_platform_cell:
				# Already holding the cell we want — nothing to do.
				pass
			elif unit_manager.try_reserve_platform(self, desired_cell):
				# Got the new cell. Hand the old one back so the unit
				# behind us can shuffle forward.
				if _reserved_platform_cell != _NO_PLATFORM \
						and _reserved_platform_cell != desired_cell:
					unit_manager.release_platform(self, _reserved_platform_cell)
				_reserved_platform_cell = desired_cell
			elif desired_cell == tgt_cell:
				# Next plank is occupied — stall. Keep our current
				# reservation (if any) so we don't lose our footing.
				return
	# Stack any active speed modifier from status effects (Wet → 0.7×,
	# Freezing → 0.2×, etc.). The `boost` field amplifies effects that
	# have an affinity active alongside them; a 1.0 boost = vanilla.
	for sid in active_statuses:
		var ent: Dictionary = active_statuses[sid]
		var se: StatusEffectData = ent["effect"]
		if se != null and se.speed_modifier != 1.0:
			var base_mod: float = se.speed_modifier
			var boost: float = float(ent.get("boost", 1.0))
			# Amplify the DEVIATION from 1.0 by the boost factor.
			var effective: float = 1.0 + (base_mod - 1.0) * boost
			speed_mult *= maxf(effective, 0.05)
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
		_blocked_frames = 0
	else:
		var ml_walk: int = data.movement_layer if data else 0
		var moved_this_frame: bool = false
		# Helper closure: ground-truth walkability for a candidate pos
		# (shield-aware via `team`). Repeated below for the original
		# direction, the separation-modified direction, and the two
		# perpendicular slide attempts.
		var step_walkable := func(p: Vector2) -> bool:
			return unit_manager == null \
				or unit_manager.is_world_pos_walkable(p, ml_walk, team)
		var candidate: Vector2 = position + move_dir * step
		if move_dir == direction or step_walkable.call(candidate):
			if step_walkable.call(candidate):
				position = candidate
				moved_this_frame = true
		else:
			# Separation-modified step would land on a wall — fall back
			# to the unmodified path step, gated on the same team-
			# aware walkability so hostile shields still block.
			var fallback: Vector2 = position + direction * step
			if step_walkable.call(fallback):
				position = fallback
				moved_this_frame = true
		# Mindustry-style wall slide. When the chosen step couldn't be
		# taken (wall placed mid-path, blocked by hostile shield, an
		# obstructing unit), try sliding along the perpendicular axis
		# at half speed before giving up. This is what stops a unit
		# from freezing nose-against-the-wall for 1.5 s waiting on the
		# stuck timer to fire — it scoots sideways and the next path
		# tick finds an open lane.
		if not moved_this_frame and step > 0.0:
			var perp := Vector2(-direction.y, direction.x)
			# Pick the perpendicular side closer to the next waypoint so
			# we slide TOWARD progress rather than away from it.
			var lookahead: Vector2 = target_pos
			if path_index + 1 < path.size():
				lookahead = path[path_index + 1]
			if perp.dot(lookahead - position) < 0.0:
				perp = -perp
			for side in [perp, -perp]:
				var slide: Vector2 = position + side * (step * 0.5)
				if step_walkable.call(slide):
					position = slide
					moved_this_frame = true
					break
		# Track the "actually got nowhere this frame" run for fast
		# repath escalation, separate from the spatial stuck timer.
		if moved_this_frame:
			_blocked_frames = 0
		else:
			_blocked_frames += 1
			if _blocked_frames >= _BLOCKED_FRAMES_REPATH:
				_request_repath()
				_blocked_frames = 0


## Sums a soft repulsion vector from every same-layer unit within
## `unit_size * 2`. Falloff is quadratic so neighbours right on top
## push hard while distant ones barely register.
##
## When a neighbour is *overlapping* (within `unit_size`), the
## behaviour splits three ways depending on who's heading where:
##
##   • Same-direction race (both moving with parallel intent_dirs):
##     instead of pushing, the unit FARTHER from the shared goal
##     yields — sets a short `_yield_timer` so it skips this frame's
##     movement step. Breaks the oscillation at 1-tile chokepoints
##     where a radial push just bounces both units back into the line.
##     Repeated yields escalate to a hard 2-second freeze + repath
##     so a unit that keeps losing the contest gets pushed onto a
##     different route.
##
##   • Push-through (we're moving, they're roughly in front along our
##     intent axis): bulldoze them along our travel direction.
##
##   • Otherwise: symmetric pair shove. The soft force returned here
##     is projected onto the path-perpendicular axis (when we have an
##     intent_dir) so it never fights the path tangent — that was
##     the source of the "push apart then re-clump" oscillation.
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
	# Our direction of intent — straight toward the next path waypoint.
	var intent_dir: Vector2 = Vector2.ZERO
	if path.size() > 0 and path_index < path.size():
		var to_wp: Vector2 = path[path_index] - position
		if to_wp.length_squared() > 0.01:
			intent_dir = to_wp.normalized()
	# Distance to our own final goal — used to break ties when two units
	# in a same-direction race need to decide who yields.
	var my_goal_dist: float = _goal_distance()
	var all_units: Array = unit_manager.enemies + unit_manager.player_units
	for other in all_units:
		if other == self or not is_instance_valid(other) or other.is_dead:
			continue
		if other.data == null or other.data.movement_layer != ml:
			continue
		# Don't try to yield to a stationary / controlled / yielding unit —
		# they aren't competing for our cell.
		var to_other: Vector2 = other.position - position
		var d: float = to_other.length()
		if d > sep_radius:
			continue
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
			# ---- (1) YIELD-TO-LEADER ----
			# Both units moving with roughly parallel intent → break the
			# oscillation by having the farther-from-goal unit yield
			# instead of getting pushed sideways.
			var other_intent: Vector2 = other._intent_dir_for_yield() if other.has_method("_intent_dir_for_yield") else Vector2.ZERO
			if intent_dir != Vector2.ZERO and other_intent != Vector2.ZERO \
					and intent_dir.dot(other_intent) > 0.5:
				var other_goal_dist: float = other._goal_distance() if other.has_method("_goal_distance") else 0.0
				if my_goal_dist > other_goal_dist:
					# We're trailing → yield to the leader.
					_register_pushback()
					# Skip the symmetric shove this frame; the soft force
					# stays in `force` so we still drift sideways slightly
					# (projected to path-perpendicular below).
					continue
				elif my_goal_dist < other_goal_dist:
					# We're the leader → make THEM yield. Mirror what we'd
					# do to ourselves in the trailing branch.
					if other.has_method("_register_pushback"):
						other._register_pushback()
					continue
				# Exact tie — fall through to the push-through / symmetric
				# branches so SOMEONE moves; otherwise both freeze.
			# ---- Push-through ----
			if intent_dir != Vector2.ZERO and dir.dot(intent_dir) > 0.3:
				var shove_amt: float = overlap_thresh - d
				var other_target: Vector2 = other.position + intent_dir * shove_amt
				var other_ml: int = other.data.movement_layer
				if other.unit_manager != null \
						and other.unit_manager.is_world_pos_walkable(other_target, other_ml):
					other.position = other_target
				continue
			# ---- Symmetric pair shove ----
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
	# ---- (2) PATH-TANGENT SEPARATION ----
	# Project the soft repulsion onto the path-perpendicular axis so
	# separation never fights forward progress. Without this, every
	# push along the path direction gets immediately undone by the
	# pathfinder pulling the unit back onto the optimal line — and
	# adjacent units oscillate forever between push and re-pull.
	if intent_dir != Vector2.ZERO and force.length_squared() > 0.0001:
		var parallel: float = force.dot(intent_dir)
		# Discard the parallel component entirely; keep only perpendicular.
		force -= intent_dir * parallel
	return force


## Distance from this unit to its effective "goal" — used to decide who
## yields at a same-direction bottleneck. Order of preference:
##   1. Length of remaining path (sum of segments) when path-following.
##   2. Distance to move_target when it's a Vector2.
##   3. Distance to manual or auto target_building / target_unit.
##   4. 0.0 (no goal known → never yield).
func _goal_distance() -> float:
	if path.size() > 0 and path_index < path.size():
		var total: float = position.distance_to(path[path_index])
		for i in range(path_index + 1, path.size()):
			total += path[i - 1].distance_to(path[i])
		return total
	if move_target != null and move_target is Vector2:
		return position.distance_to(move_target)
	if target_unit != null and is_instance_valid(target_unit):
		return position.distance_to(target_unit.position)
	if target_building != null and main != null \
			and main.placed_buildings.has(target_building):
		var bw: Vector2 = main.grid_to_world(target_building) \
			+ Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		return position.distance_to(bw)
	return 0.0


## Public read of the intent direction this unit is using right now —
## same source as the local `intent_dir` in `_compute_separation_force`.
## Pulled into a method so peers can ask without recomputing.
func _intent_dir_for_yield() -> Vector2:
	if path.size() > 0 and path_index < path.size():
		var to_wp: Vector2 = path[path_index] - position
		if to_wp.length_squared() > 0.01:
			return to_wp.normalized()
	return Vector2.ZERO


## Records that we lost a same-direction overlap race this frame. Sets
## a short yield_timer (skipping the next movement step) and counts the
## event for the escalation window. When too many events land inside
## the window, escalates to a hard 2-second freeze + path replan so the
## unit gets a chance to route around the bottleneck.
func _register_pushback() -> void:
	# Short soft yield — one frame of skipped movement is usually enough
	# for the leader to clear the cell.
	if _yield_timer < 0.12:
		_yield_timer = 0.12
	if _pushback_window <= 0.0:
		_pushback_count = 0
	_pushback_window = _PUSHBACK_WINDOW_SEC
	_pushback_count += 1
	if _pushback_count >= _PUSHBACK_HARD_THRESH:
		# Hard escalation: freeze for 2 s and replan from current
		# position. Reset the counter so we don't immediately escalate
		# again on the very next overlap after the wait ends.
		_yield_timer = _PUSHBACK_HARD_YIELD
		_needs_hard_repath = true
		_pushback_count = 0
		_pushback_window = 0.0


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

	# Range gate. Without this, a stuck unit (inside a wall / void cell
	# the path-follower can't make it out of) keeps firing on its
	# attack_cooldown regardless of distance — looking like a unit with
	# infinite attack range. Suppress the shot when we're more than the
	# unit's effective range from the target.
	var bldg_world: Vector2 = main.grid_to_world(target_building) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
	var atk_range: float = data.attack_range if data else main.GRID_SIZE / 2.0
	var effective_range: float = maxf(atk_range, main.GRID_SIZE * 1.5)
	if position.distance_to(bldg_world) > effective_range:
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
	if hold_fire:
		return
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


# =========================
# FEROX IN-FLIGHT ENGAGEMENT
# =========================

## Find a LUMINA unit close enough that this enemy should stop and
## shoot at it instead of marching past. Engagement range slightly
## extends the attack range so units commit to a fight rather than
## strafe back-and-forth at the boundary.
func _ferox_find_engageable_player_unit() -> Node2D:
	if data == null:
		return null
	var atk_range: float = data.attack_range
	if atk_range <= 0.0:
		# Melee enemies engage at melee range.
		atk_range = main.GRID_SIZE * 1.2
	# A bit of bonus reach so an enemy doesn't perpetually flicker into
	# and out of engagement mode at the edge of its range.
	var engage_range: float = atk_range * 1.15
	var range_sq: float = engage_range * engage_range
	var best: Node2D = null
	var best_d2: float = INF
	for u in unit_manager.player_units:
		if u == null or not is_instance_valid(u):
			continue
		if "is_dead" in u and u.is_dead:
			continue
		var d2: float = position.distance_squared_to(u.position)
		if d2 > range_sq:
			continue
		if d2 < best_d2:
			best_d2 = d2
			best = u
	return best


## Hold position and fire at the engaged player unit. The path is
## dropped so the enemy doesn't keep marching past. Once the target
## dies / leaves range, the regular path-following branch picks back
## up next frame.
func _ferox_engage_unit(target: Node2D, delta: float) -> void:
	# Stop moving — engagements are stationary fire.
	if path.size() > 0:
		path = PackedVector2Array()
		path_index = 0
	target_unit = target
	target_building = null
	attack_timer -= delta
	if attack_timer > 0.0:
		return
	var atk_range: float = data.attack_range if data else 0.0
	if atk_range > 0.0:
		# Ranged FEROX: spawn a projectile.
		attack_timer = attack_cooldown
		var combat = _combat_sys_ref()
		if combat and combat.has_method("enemy_attack_unit"):
			var proj_speed := 300.0
			var proj_color: Color = unit_color.lightened(0.3)
			combat.enemy_attack_unit(self, target, damage, proj_speed, proj_color)
		elif target.has_method("take_damage"):
			target.take_damage(damage)
	else:
		# Melee FEROX: punch directly if in range.
		if position.distance_to(target.position) <= main.GRID_SIZE * 1.2:
			attack_timer = attack_cooldown
			if target.has_method("take_damage"):
				target.take_damage(damage)


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
	# Unit ended up on a wall / void / building cell that its movement
	# layer can't legally occupy — usually because they nicked the
	# corner of a newly-placed block while moving past it, NOT because
	# something malicious happened. Outright killing every unit in that
	# situation made grazing a building catastrophic, so instead we
	# spiral outward looking for the nearest legal cell and teleport
	# the unit there. Only fall back to the kill if literally no
	# walkable spot exists within ~8 tiles (the unit is sealed inside
	# a wall — at that point there really is no rescue and the safest
	# thing is to remove it before it cheats from inside terrain).
	var ml_w: int = data.movement_layer
	var rescue: Vector2 = _find_nearest_walkable(position, ml_w)
	if rescue == Vector2.INF:
		take_damage(max_health + 1.0)
		return
	position = rescue
	# Path from before the rescue points away from where we are now —
	# kick a repath so the unit doesn't immediately walk back into the
	# same wall corner. Suppressed under manual control (player owns
	# the path).
	if not _skip_repath_on_unstick:
		_request_repath()


## Spirals out from `from` looking for the nearest cell that's walkable
## for movement layer `ml`. Returns Vector2.INF if nothing legal is
## found within `_RESCUE_MAX_TILES` rings. Used by the wall-overlap
## rescue path so a unit clipping the corner of a block teleports off
## instead of exploding.
const _RESCUE_MAX_TILES := 8
const _RESCUE_ANGLE_STEPS := 12
func _find_nearest_walkable(from: Vector2, ml: int) -> Vector2:
	if unit_manager == null:
		return Vector2.INF
	var gs: float = float(main.GRID_SIZE)
	for r in range(1, _RESCUE_MAX_TILES + 1):
		var step: float = float(r) * gs * 0.75
		for i in range(_RESCUE_ANGLE_STEPS):
			var ang: float = float(i) * TAU / float(_RESCUE_ANGLE_STEPS)
			var c: Vector2 = from + Vector2(cos(ang), sin(ang)) * step
			if unit_manager.is_world_pos_walkable(c, ml):
				return c
	return Vector2.INF


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
	# Hit-flash intentionally disabled — the white tint on damage was
	# noisy when many units were taking fire at once. Damage feedback
	# now lives in the audio cue + health bar only.
	var asys = main.get_node_or_null("AudioSystem")
	if asys and asys.has_method("play"):
		asys.play("hit_unit", position, -4.0)
	if health <= 0 and not is_dead:
		is_dead = true
		if asys:
			asys.play("unit_die", position)
		_on_death()


func _on_death() -> void:
	# Free up any water-platform reservation so the next unit in line
	# doesn't stall forever waiting on a corpse.
	if unit_manager and _reserved_platform_cell != Vector2i(-32768, -32768):
		unit_manager.release_platform(self, _reserved_platform_cell)
		_reserved_platform_cell = Vector2i(-32768, -32768)
	# Drop items based on .tres data
	if data and data.drops.size() > 0 and randf() <= data.drop_chance:
		for item_id in data.drops:
			if main.resources.has(item_id):
				main.resources[item_id] += data.drops[item_id]
		main.resources_changed.emit(main.resources)

	# Ring + shrapnel-line burst at the unit's last position, plus a
	# ruin decal afterward. Routed through ExplosionSystem so the
	# visual matches the new building-explosion style.
	var expl_u = main.get_node_or_null("ExplosionSystem") if main else null
	if expl_u and expl_u.has_method("explode"):
		# Small ring for unit-scale blasts.
		expl_u.explode(position, 2.0)
	var overlay = main.get_node_or_null("ParticleOverlay") if main else null
	if overlay and overlay.has_method("spawn_unit_ruins"):
		var vis_size: float = data.visual_size if data else 12.0
		overlay.spawn_unit_ruins(position, vis_size)

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


## Drops every outstanding command on this unit — manual targets, move
## orders, paths, auto-combat picks. Wired to the "Cancel Orders" button
## under the selected-unit list.
func clear_all_orders() -> void:
	manual_target_unit = null
	manual_target_building = null
	manual_target_building_block_id = &""
	target_unit = null
	target_building = null
	move_target = null
	path = PackedVector2Array()
	path_index = 0
	_stuck_timer = 0.0


# --- ENTER PAYLOAD BLOCK ---
## True if the block at `cell` will accept the unit as a payload — either
## a payload/freight conveyor or a mass driver, or a deconstructor's body.
func _payload_block_at(cell: Vector2i) -> Vector2i:
	if not main.placed_buildings.has(cell):
		return Vector2i(-9999, -9999)
	var anchor: Vector2i = main.building_origins.get(cell, cell)
	var bid: StringName = main.placed_buildings.get(anchor, &"")
	var bdata = Registry.get_block(bid)
	if bdata == null:
		return Vector2i(-9999, -9999)
	# Faction gate — only LUMINA blocks accept the player's units.
	if main.get_building_faction(anchor) != main.Faction.LUMINA:
		return Vector2i(-9999, -9999)
	var tags: PackedStringArray = bdata.tags
	var ok := tags.has("payload") or tags.has("freight") or tags.has("mass_driver") or tags.has("deconstructor")
	return anchor if ok else Vector2i(-9999, -9999)


## Returns true when the unit was successfully consumed by a payload
## block (it's been queue_freed and should not tick further).
func _try_enter_payload_block() -> bool:
	var anchor: Vector2i = Vector2i(-9999, -9999)
	# 1. Standing directly on a payload block? (Original behaviour — most
	#    units small enough to step onto a deconstructor go through here.)
	var ug: Vector2i = main.world_to_grid(position)
	anchor = _payload_block_at(ug)
	# 2. Otherwise, if we've been directed at a specific payload block
	#    via right-click and we're now touching its footprint, hand off
	#    from the adjacent tile. This is what lets large units that
	#    can't physically stand on a 1×1 deconstructor still feed
	#    themselves into it.
	if anchor == Vector2i(-9999, -9999) and payload_target_anchor != Vector2i(-9999, -9999):
		if _is_touching_payload_target():
			anchor = payload_target_anchor
		else:
			# Building destroyed or replaced? Drop the latch.
			if not main.placed_buildings.has(payload_target_anchor):
				payload_target_anchor = Vector2i(-9999, -9999)
			return false
	if anchor == Vector2i(-9999, -9999):
		return false
	var bs = main.get_node_or_null("BuildingSystem")
	if bs == null or not bs.has_method("inject_unit_as_payload"):
		return false
	var payload := {
		"type": "unit",
		"unit_id": String(data.id) if data else "",
		"health": health,
	}
	if "facing_angle" in self:
		payload["facing_angle"] = facing_angle
	if "aim_angle" in self:
		payload["aim_angle"] = aim_angle
	if bs.inject_unit_as_payload(anchor, payload):
		# We've handed our state off — leave the world. Erase the unit
		# from the UnitManager's player_units / selected_units arrays
		# directly (without going through on_player_unit_died, which
		# bumps the "destroyed" stat — being picked up isn't a death).
		is_dead = true
		if unit_manager:
			if "player_units" in unit_manager:
				unit_manager.player_units.erase(self)
			if "selected_units" in unit_manager:
				unit_manager.selected_units.erase(self)
		queue_free()
		return true
	return false


## True when the unit is on a tile bordering (Chebyshev distance ≤ 1)
## any cell of `payload_target_anchor`'s footprint — close enough to
## reach across and feed itself in as a payload.
func _is_touching_payload_target() -> bool:
	if payload_target_anchor == Vector2i(-9999, -9999):
		return false
	if not main.placed_buildings.has(payload_target_anchor):
		return false
	var bdata = Registry.get_block(main.placed_buildings[payload_target_anchor])
	if bdata == null:
		return false
	var ug: Vector2i = main.world_to_grid(position)
	# Footprint bounds — accept any cell within 1 tile of the rectangle.
	var x0: int = payload_target_anchor.x - 1
	var y0: int = payload_target_anchor.y - 1
	var x1: int = payload_target_anchor.x + bdata.grid_size.x
	var y1: int = payload_target_anchor.y + bdata.grid_size.y
	return ug.x >= x0 and ug.x <= x1 and ug.y >= y0 and ug.y <= y1


# --- MINING ---
const _MINE_RANGE_TILES := 4
const _MINE_DEPOSIT_RANGE_TILES := 6


func _tick_mining(delta: float) -> bool:
	if data == null:
		return false
	# Deposit phase — full or no more ore left.
	var inv_total := 0
	for k in mined_inventory:
		inv_total += int(mined_inventory[k])
	var must_deposit: bool = inv_total >= mined_inventory_cap
	# If the requested ore is gone from the world, deposit what we have and bail.
	if not must_deposit and mining_request_id != &"" and inv_total > 0 and not _any_ore_exists_for(mining_request_id):
		must_deposit = true

	if inv_total > 0 and must_deposit:
		return _seek_and_deposit_core(delta)

	# Mining phase — seek nearest matching ore.
	var ore_cell: Vector2i = _find_nearest_ore_cell(mining_request_id)
	if ore_cell == Vector2i(-9999, -9999):
		# No reachable ore — fall through so the unit can idle / auto-combat.
		return false

	var unit_grid: Vector2i = main.world_to_grid(position)
	var dx: int = absi(unit_grid.x - ore_cell.x)
	var dy: int = absi(unit_grid.y - ore_cell.y)
	if max(dx, dy) > _MINE_RANGE_TILES:
		if _mine_target_cell != ore_cell:
			_mine_target_cell = ore_cell
			var world_target: Vector2 = main.grid_to_world(ore_cell) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
			unit_manager.assign_path_to_position(self, world_target)
		if path.size() > 0 and path_index < path.size():
			_follow_path(delta)
		return true

	# In range — mine.
	if path.size() > 0:
		path = PackedVector2Array()
		path_index = 0
	var period: float = attack_cooldown if attack_cooldown > 0.0 else 1.0
	_mine_timer += delta
	if _mine_timer >= period:
		_mine_timer = 0.0
		mined_inventory[mining_request_id] = int(mined_inventory.get(mining_request_id, 0)) + 1
	return true


func _any_ore_exists_for(item_id: StringName) -> bool:
	var terrain = main.get_node_or_null("TerrainSystem")
	if terrain == null:
		return false
	for cell in terrain.ore_tiles.keys():
		var tile_id = terrain.ore_tiles[cell]
		var tile_data = Registry.get_tile(tile_id)
		if tile_data != null and StringName(tile_data.minable_resource) == item_id:
			return true
	return false


func _find_nearest_ore_cell(item_id: StringName) -> Vector2i:
	var terrain = main.get_node_or_null("TerrainSystem")
	if terrain == null:
		return Vector2i(-9999, -9999)
	var unit_grid: Vector2i = main.world_to_grid(position)
	var best: Vector2i = Vector2i(-9999, -9999)
	var best_d2: int = 0x7FFFFFFF
	for cell in terrain.ore_tiles.keys():
		var tile_id = terrain.ore_tiles[cell]
		var tile_data = Registry.get_tile(tile_id)
		if tile_data == null or StringName(tile_data.minable_resource) != item_id:
			continue
		var d2: int = (cell.x - unit_grid.x) * (cell.x - unit_grid.x) + (cell.y - unit_grid.y) * (cell.y - unit_grid.y)
		if d2 < best_d2:
			best_d2 = d2
			best = cell
	return best


func _find_nearest_core_cell() -> Vector2i:
	var unit_grid: Vector2i = main.world_to_grid(position)
	var best: Vector2i = Vector2i(-9999, -9999)
	var best_d2: int = 0x7FFFFFFF
	for anchor in main.placed_buildings.keys():
		var bid: StringName = main.placed_buildings[anchor]
		var bdata = Registry.get_block(bid)
		if bdata == null:
			continue
		if not bdata.tags.has("core"):
			continue
		if main.get_building_faction(anchor) != main.Faction.LUMINA:
			continue
		var d2: int = (anchor.x - unit_grid.x) * (anchor.x - unit_grid.x) + (anchor.y - unit_grid.y) * (anchor.y - unit_grid.y)
		if d2 < best_d2:
			best_d2 = d2
			best = anchor
	return best


func _seek_and_deposit_core(delta: float) -> bool:
	var core_cell: Vector2i = _find_nearest_core_cell()
	if core_cell == Vector2i(-9999, -9999):
		return false
	var unit_grid: Vector2i = main.world_to_grid(position)
	var dx: int = absi(unit_grid.x - core_cell.x)
	var dy: int = absi(unit_grid.y - core_cell.y)
	if max(dx, dy) > _MINE_DEPOSIT_RANGE_TILES:
		if _mine_deliver_cell != core_cell:
			_mine_deliver_cell = core_cell
			var target_world: Vector2 = main.grid_to_world(core_cell) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
			unit_manager.assign_path_to_position(self, target_world)
		if path.size() > 0 and path_index < path.size():
			_follow_path(delta)
		return true
	# Deposit everything into main.resources.
	if path.size() > 0:
		path = PackedVector2Array()
		path_index = 0
	for k in mined_inventory.keys():
		var amt: int = int(mined_inventory[k])
		if amt > 0:
			main.resources[k] = int(main.resources.get(k, 0)) + amt
	mined_inventory.clear()
	main.resources_changed.emit(main.resources)
	_mine_deliver_cell = Vector2i(-9999, -9999)
	return true


# --- ASSIST PLAYER (build plan helper) ---
func _tick_assist_build(delta: float) -> bool:
	if not ("work_order" in main) or main.work_order.is_empty():
		return false
	var unit_grid: Vector2i = main.world_to_grid(position)
	var best: Vector2i = Vector2i(-9999, -9999)
	var best_d2: int = 0x7FFFFFFF
	for a in main.work_order:
		var d2: int = (a.x - unit_grid.x) * (a.x - unit_grid.x) + (a.y - unit_grid.y) * (a.y - unit_grid.y)
		if d2 < best_d2:
			best_d2 = d2
			best = a
	if best == Vector2i(-9999, -9999):
		return false
	var dx: int = absi(unit_grid.x - best.x)
	var dy: int = absi(unit_grid.y - best.y)
	# Anything inside ~10 tiles counts as "in range" — the building tick
	# is gated on `_is_in_build_range` which the BuildingSystem will
	# extend for assisting units (see _is_in_build_range patch).
	if max(dx, dy) > 8:
		var target_world: Vector2 = main.grid_to_world(best) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		if path.size() == 0 or path_index >= path.size():
			unit_manager.assign_path_to_position(self, target_world)
		else:
			_follow_path(delta)
		return true
	# In build range — sit still; building_system._tick_progressive_build
	# will advance because our presence extends the build range.
	if path.size() > 0:
		path = PackedVector2Array()
		path_index = 0
	return true


# --- DRAWING ---


## Refreshes the Node2D `visible` flag based on whether the current
## cell is in fog. PLAYER-team units are always visible. ENEMY units
## are visible only when the fog system says their cell is currently
## lit. Throttled by `_FOG_CHECK_INTERVAL` so we don't pay this per
## frame for hundreds of units.
func _update_fog_visibility() -> void:
	if team != UnitData.Team.ENEMY:
		if not visible:
			visible = true
		return
	if main == null:
		return
	# Hard short-circuit: when the sector's author-time fog toggle is
	# OFF (most campaign maps ship with `fog_enabled = false`), enemy
	# units should always render. Doing this guard at the enemy_unit
	# layer — rather than relying on `FogSystem.is_cell_visible` to
	# notice the flag — avoids any sequencing window where the unit's
	# fog tick runs before SaveManager has copied the per-sector flag
	# onto `main`, leaving every enemy invisible until you toggle fog
	# manually.
	if "fog_enabled" in main and not bool(main.fog_enabled):
		if not visible:
			visible = true
		return
	var fog = main.get_node_or_null("FogSystem")
	if fog == null or not fog.has_method("is_cell_visible"):
		if not visible:
			visible = true
		return
	var cell: Vector2i = main.world_to_grid(position)
	var lit: bool = fog.is_cell_visible(cell)
	if visible != lit:
		visible = lit


func _draw() -> void:
	if is_dead:
		return

	# Fog visibility is reflected in `visible` (toggled by
	# `_update_fog_visibility`). When the unit is fogged, Godot
	# skips _draw entirely — no per-draw guard needed here.

	# Hit-flash removed — see take_damage. modulate is left untouched
	# so other systems can tint the unit if they ever need to.

	# Flying units cast a soft drop-shadow. Drawn on the unit's own
	# canvas (which `_ready` bumps to z=81) so it paints above ground
	# units. Painted FIRST so the chassis covers the shadow under
	# the unit's footprint.
	var is_flying: bool = data != null and data.movement_layer == UnitData.MovementLayer.FLYING
	if is_flying:
		_draw_flying_shadow()

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


## Per-frame hover orbit for flying units (Mindustry-style).
##
## Each unit drifts in a small fixed-radius circle that doesn't rotate
## the chassis — only the position offset moves. The offset is
## applied as a DELTA between this frame's offset and last frame's so
## any combination of orbit + AI movement composes correctly: the
## unit's "logical" position keeps advancing along its path while the
## visual position bobs.
##
## Suppressed when:
##   • the unit isn't flying,
##   • the player is directly controlling this unit (so WASD response
##     stays crisp), or
##   • the unit hasn't loaded its UnitData yet.
## On suppression the existing offset decays smoothly back to zero
## instead of snapping, so toggling control doesn't visibly jolt the
## unit.
func _tick_hover_orbit(delta: float) -> void:
	var should_orbit: bool = data != null \
			and data.movement_layer == UnitData.MovementLayer.FLYING \
			and not is_controlled
	var new_off: Vector2
	if should_orbit:
		_orbit_phase = wrapf(_orbit_phase + delta * _ORBIT_SPEED, 0.0, TAU)
		new_off = Vector2(cos(_orbit_phase), sin(_orbit_phase)) * _ORBIT_RADIUS
	else:
		# Smoothly settle back to centre when control kicks in.
		new_off = _orbit_prev_off.lerp(Vector2.ZERO, clampf(delta * _ORBIT_DECAY_RATE, 0.0, 1.0))
	position += new_off - _orbit_prev_off
	_orbit_prev_off = new_off


## Soft drop-shadow for FLYING units. Recipe lifted from Mindustry v8's
## UnitType.drawShadow():
##   - World-space offset (shadowTX, shadowTY) = (-12, -13). In libgdx
##     Y is up, so -13Y is "below" the unit — in Godot Y-down that's
##     +13Y. The offset is in WORLD pixels, independent of the unit's
##     facing, so the shadow always reads as cast by an upper-right
##     "sun" the same way it does in Mindustry.
##   - Tint = Pal.shadow = rgba(0,0,0,0.22).
##   - Shape = the unit's sprites rotated with the unit. v8 uses a
##     single pre-baked fullIcon; we mirror it by silhouetting the
##     base sprite (and the head, since rotating heads add to the
##     read of "this is the unit's outline overhead").
##   - We scale the offset by SPRITE_SCALE_FACTOR so the shadow tracks
##     the world's pixel scale — same idea as v8 baking shadow offsets
##     in world units.
## Renders the flying unit's drop-shadow inline on the unit's own
## canvas. The unit's z_index is bumped to 81 in `_ready`, so the
## whole composite (shadow + chassis) paints above ground units.
## Silhouettes use Pal.shadow alpha; overlapping chassis + head
## silhouettes will compound slightly where they overlap, which is
## an acceptable trade for getting a reliable z-order above ground.
func _draw_flying_shadow() -> void:
	const SHADOW_TX := -28.0
	const SHADOW_TY := 30.0
	var shadow_tint: Color = Color(0.0, 0.0, 0.0, 0.22)
	var sf: float = main.SPRITE_SCALE_FACTOR if main else 1.0
	var off: Vector2 = Vector2(SHADOW_TX * sf, SHADOW_TY * sf)
	var drew_tex_shadow: bool = false
	if data != null and (data.base_sprite != null or data.head_sprite != null):
		var scale_f: float = (data.sprite_scale if data and data.sprite_scale > 0.0 else 1.0) * sf
		# Base layer (rotates with chassis).
		if data.base_sprite:
			var b_size: Vector2 = data.base_sprite.get_size() * scale_f
			draw_set_transform(off, facing_angle + PI / 2.0)
			draw_texture_rect(
				data.base_sprite,
				Rect2(-b_size * 0.5, b_size),
				false,
				shadow_tint
			)
			draw_set_transform(Vector2.ZERO, 0.0)
			drew_tex_shadow = true
		# Head layer (rotates with aim).
		if data.head_sprite:
			var h_size: Vector2 = data.head_sprite.get_size() * scale_f
			var h_angle: float = aim_angle + PI / 2.0
			draw_set_transform(off, h_angle)
			draw_texture_rect(
				data.head_sprite,
				Rect2(-h_size * 0.5, h_size),
				false,
				shadow_tint
			)
			draw_set_transform(Vector2.ZERO, 0.0)
			drew_tex_shadow = true
	if not drew_tex_shadow:
		# Shape fallback — draw a filled disc the size of the unit.
		draw_circle(off, unit_size, shadow_tint)


## Renders the unit as a stacked base + rotating head, mirroring the
## turret_head_sprite pattern (source textures face UP, so +PI/2 is
## added to convert facing/aim angles into texture angles). Tinted
## toward blue when the unit is drowning, otherwise full brightness.
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
