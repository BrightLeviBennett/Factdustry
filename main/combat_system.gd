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

# Multi-barrel turrets track a per-barrel cooldown instead of the single
# `turret_cooldowns[grid_pos]` float. Alternating fire is achieved by
# staggering the initial cooldowns across the array (barrel i starts at
# attack_speed * i / N), then every tick the first barrel with cooldown
# <= 0 gets to fire and is reset to the full cooldown. With N=2 that
# produces an exact "left, right, left, right" cadence at 2× the rate.
# Key = Vector2i (turret anchor), Value = Array[float].
var turret_barrel_cooldowns := {}
# Per-barrel fire flash timer, drawn as a brief muzzle highlight so the
# player can tell which barrel just shot. Value = Array[float].
var turret_barrel_fire_flash := {}
# Per-barrel recoil progress in [0, 1]: 1.0 the frame a barrel fires, then
# decays back to 0 over RECOIL_DECAY_TIME. _draw_turret_heads offsets each
# head along -aim by recoil * RECOIL_PIXELS so the barrel kicks back.
# Value = Array[float], one entry per barrel (single-barrel turrets get
# a 1-element array).
var turret_barrel_recoil := {}
const RECOIL_PIXELS := 12.0
const RECOIL_DECAY_TIME := 0.25

# Per-barrel aim angle. Multi-barrel turrets let each head toe in toward
# the target from its own muzzle pivot, clamped to ±BARREL_TOE_IN_MAX
# from the chassis angle so the heads can converge on a close target
# instead of firing straight forward and missing past it. Single-barrel
# turrets store one entry that just mirrors `turret_angles[grid_pos]`.
# Key = Vector2i (anchor). Value = Array[float], one absolute angle per
# barrel.
var turret_barrel_angles := {}
const BARREL_TOE_IN_MAX: float = deg_to_rad(20.0)
const BARREL_TURN_SPEED: float = 8.0
## Constant angular velocity (rad / sec) used by multi-barrel turret
## chassis rotation. Single-barrel turrets keep the original ease-out
## lerp (smooth swing), multi-barrel rotates at this fixed rate so the
## chassis feels mechanical / rigid instead of swaying into position.
const MULTI_BARREL_CHASSIS_TURN_RATE: float = 4.0

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

# --- SHOT GROUPING ---
# Multi-pellet salvos (shotgun-style turrets like the Diffuse) tag every
# pellet with a shared shot_id. When two pellets from the same salvo hit
# the same target, the second one deals half damage, the third a quarter,
# and so on. _shot_hits[sid][target_key] = number of prior hits applied.
# _shot_active[sid] tracks how many of the salvo's pellets are still
# alive so we can free the bucket once they've all landed/expired.
var _shot_id_counter: int = 0
var _shot_hits: Dictionary = {}
var _shot_active: Dictionary = {}

func _next_shot_id() -> int:
	_shot_id_counter += 1
	return _shot_id_counter

## Returns the damage to apply for `proj` against `target_key`, halving it
## per prior hit from the same shot. Records the hit so the next pellet of
## the salvo sees an incremented count.
func _shot_damage(proj: Dictionary, target_key: Variant, base: float) -> float:
	var sid: int = int(proj.get("shot_id", 0))
	if sid == 0:
		return base
	var bucket: Dictionary = _shot_hits.get(sid, {})
	var prior: int = int(bucket.get(target_key, 0))
	bucket[target_key] = prior + 1
	_shot_hits[sid] = bucket
	if prior <= 0:
		return base
	return base / pow(2.0, prior)

func _release_shot_id(sid: int) -> void:
	if sid == 0:
		return
	var n: int = int(_shot_active.get(sid, 0)) - 1
	if n <= 0:
		_shot_active.erase(sid)
		_shot_hits.erase(sid)
	else:
		_shot_active[sid] = n

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


## Dedicated overlay node for projectile rendering. Lives as a child
## of CombatSystem with `top_level = true` (so it ignores parent
## transform and draws in world space using its own coords) and a
## very high z_index so bullets always render above the chassis,
## buildings, and any other in-world Node2D no matter what z_index
## those siblings adopt.
var _projectile_overlay: Node2D = null


func _ready() -> void:
	# Bullets, turret heads, and the like draw above the player drone
	# AND the building / logistics / terrain overlay layers (which set
	# absolute z_indices in the 50–60 range), so the shardling's
	# tracers visibly emerge from its barrels instead of vanishing
	# behind the chassis or the building art they fly past.
	z_index = 70
	z_as_relative = false
	# Mount a separate Node2D specifically for projectile draws so the
	# bullets render on a guaranteed-on-top layer regardless of what
	# any other in-world system does with z_index. The overlay's
	# `_draw` defers back to `_draw_projectiles` here, keeping all the
	# state (`projectiles` array, etc.) on this node.
	_projectile_overlay = Node2D.new()
	_projectile_overlay.name = "ProjectileOverlay"
	_projectile_overlay.z_index = 4095
	_projectile_overlay.z_as_relative = false
	_projectile_overlay.set_script(preload("res://main/projectile_overlay.gd"))
	_projectile_overlay.set("combat", self)
	add_child(_projectile_overlay)
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

	# Build turret list. Only anchor cells generate snapshot entries —
	# otherwise a 2×2 turret would be simulated four times (quadrupling
	# its fire rate), and non-anchor cells can hold stale/default
	# faction values after a conversion pass, flipping a captured turret
	# back to acting Lumina for a frame.
	var turrets_snap: Array = []
	var seen_anchors: Dictionary = {}
	for grid_pos in main.placed_buildings:
		var block_id = main.placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null or not data.is_turret():
			continue
		var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if seen_anchors.has(anchor):
			continue
		seen_anchors[anchor] = true
		if anchor == manually_controlled_turret:
			continue
		# Skip disabled or under-construction buildings
		var sector_script = _sector_script_ref()
		if sector_script and sector_script.is_building_disabled(anchor):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
			continue
		var turret_faction: int = main.get_building_faction(anchor)
		turrets_snap.append({
			"grid_pos": anchor,
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

	# Strip platform cells from the buildings snapshot so the targeting
	# worker (which feeds both turret AI and idle player-unit auto-shoot)
	# never even considers them as targets. Platforms are damage-immune
	# anyway, but filtering here saves wasted shot-arc rotations.
	var filtered_buildings: Dictionary = {}
	for cell in main.placed_buildings:
		var bid_f: StringName = main.placed_buildings[cell]
		var bd_f = Registry.get_block(bid_f)
		if bd_f and bd_f.tags.has("platform"):
			continue
		filtered_buildings[cell] = bid_f
	_targeting_worker.push_snapshot({
		"enemies": enemies_snap,
		"player_units": player_snap,
		"buildings": filtered_buildings,
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

		# Derelict / under-construction / deconstructing / sector-disabled
		# turrets must not rotate, fire, or consume ammo. The targeting
		# worker already filters these out of its snapshot, but we guard
		# here too so a stale `_turret_targets` entry (present for one
		# frame after a faction convert, for example) can't sneak off a
		# shot before the next worker poll clears it.
		if main.has_method("is_building_inactive") and main.is_building_inactive(grid_pos):
			continue
		var sector_script_guard = _sector_script_ref()
		if sector_script_guard and sector_script_guard.is_building_disabled(grid_pos):
			continue

		var barrel_count: int = maxi(data.barrel_count, 1)
		# Recoil + per-barrel aim state must tick BEFORE the manual-
		# control skip below, otherwise neither decays/converges for the
		# turret the player is driving.
		if not turret_barrel_recoil.has(grid_pos):
			var recoil_arr: Array[float] = []
			for _i in range(barrel_count):
				recoil_arr.append(0.0)
			turret_barrel_recoil[grid_pos] = recoil_arr
		var brc: Array = turret_barrel_recoil[grid_pos]
		var recoil_step: float = delta / RECOIL_DECAY_TIME
		for i in range(brc.size()):
			brc[i] = maxf(float(brc[i]) - recoil_step, 0.0)
		# Seed per-barrel angles to the chassis angle on first sight so
		# the heads don't snap from 0° on the first frame they exist.
		if not turret_barrel_angles.has(grid_pos):
			var seed_a: float = float(turret_angles.get(grid_pos, 0.0))
			var ang_arr: Array[float] = []
			for _i in range(barrel_count):
				ang_arr.append(seed_a)
			turret_barrel_angles[grid_pos] = ang_arr
		# Default: relax barrels back toward the chassis angle each tick.
		# When a target is acquired later in the loop, toe-in overrides.
		_relax_barrels_to_chassis(grid_pos, delta)

		# Skip turrets being manually controlled by the player
		if grid_pos == manually_controlled_turret:
			continue

		# Initialize state for new turrets
		if not turret_cooldowns.has(grid_pos):
			turret_cooldowns[grid_pos] = 0.0
		if not turret_angles.has(grid_pos):
			turret_angles[grid_pos] = 0.0
		if barrel_count > 1:
			if not turret_barrel_cooldowns.has(grid_pos):
				# Stagger initial cooldowns so barrels fire in sequence:
				# barrel 0 ready immediately, barrel i offset by i/N of a
				# full attack_speed into its cycle. That gives perfect
				# alternation once steady-state kicks in.
				var init_arr: Array[float] = []
				for i in range(barrel_count):
					init_arr.append(data.attack_speed * float(i) / float(barrel_count))
				turret_barrel_cooldowns[grid_pos] = init_arr
			if not turret_barrel_fire_flash.has(grid_pos):
				var flash_arr: Array[float] = []
				for _i in range(barrel_count):
					flash_arr.append(0.0)
				turret_barrel_fire_flash[grid_pos] = flash_arr

		# Electrical power: scale the cooldown countdown by network
		# efficiency, so an over-drawn grid fires slower rather than not
		# at all. Fully brownout'd turrets (efficiency == 0) freeze.
		var turret_power_eff: float = 1.0
		if data.electrical_power_use > 0:
			var power_sys_t = get_node_or_null("/root/Main/PowerSystem")
			if power_sys_t:
				turret_power_eff = power_sys_t.get_electrical_efficiency(grid_pos)
		turret_cooldowns[grid_pos] -= delta * turret_power_eff
		# Tick every barrel's cooldown and fire-flash timer.
		if barrel_count > 1:
			var bcd: Array = turret_barrel_cooldowns[grid_pos]
			var bff: Array = turret_barrel_fire_flash[grid_pos]
			for i in range(bcd.size()):
				bcd[i] = float(bcd[i]) - delta * turret_power_eff
				bff[i] = maxf(float(bff[i]) - delta, 0.0)
		if turret_power_eff <= 0.0:
			continue

		# Use pre-computed target from worker thread
		if not _turret_targets.has(grid_pos):
			continue

		var target_info: Dictionary = _turret_targets[grid_pos]
		var turret_world: Vector2 = main.grid_to_world(grid_pos) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		# Prefer the anchor's faction: multi-tile buildings only guarantee
		# building_factions entries on tiles placed via the full placement
		# path, and conversion loops (Ferox→Derelict, Derelict→Lumina) can
		# leave non-anchor cells with a stale/default value. Reading the
		# anchor's faction is authoritative.
		var turret_anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		var turret_faction: int = main.get_building_faction(turret_anchor)

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

		# Final-pass faction guard: the pre-computed target is up to one
		# worker tick stale. If the turret was captured (FEROX → LUMINA)
		# or the target itself converted factions since the snapshot, the
		# cached `target_info` would happily aim the new-LUMINA turret at
		# its new-LUMINA ally for a frame. Drop the shot when the two
		# sides are the same or neither side is opposing.
		var target_faction: int = -1
		if shoot_at_unit:
			if nearest_unit and "team" in nearest_unit:
				target_faction = main.Faction.LUMINA if nearest_unit.team == UnitData.Team.PLAYER else main.Faction.FEROX
		else:
			var bldg_anchor: Vector2i = main.building_origins.get(nearest_bldg, nearest_bldg)
			target_faction = main.get_building_faction(bldg_anchor)
		if turret_faction == main.Faction.DERELICT \
				or target_faction == main.Faction.DERELICT \
				or target_faction == -1 \
				or target_faction == turret_faction:
			continue

		# Live range re-check: the targeting worker may have pre-computed this
		# target when it was in range, but the target may have moved away since.
		# Skip aiming AND firing if the target is now outside attack_range.
		var live_range_px: float = data.attack_range * main.GRID_SIZE
		if live_range_px > 0.0 and turret_world.distance_to(target_world) > live_range_px:
			continue

		# Rotate the chassis toward the target. Single-barrel turrets use
		# the original ease-out lerp (smooth swing). Multi-barrel turrets
		# rotate at a constant angular rate so the chassis reads as a
		# rigid mechanical mount rather than swaying into place.
		var target_angle: float = (target_world - turret_world).angle()
		var current_angle = turret_angles[grid_pos]
		if barrel_count > 1:
			var ang_diff: float = wrapf(target_angle - current_angle, -PI, PI)
			var max_step: float = MULTI_BARREL_CHASSIS_TURN_RATE * delta
			if absf(ang_diff) <= max_step:
				turret_angles[grid_pos] = target_angle
			else:
				turret_angles[grid_pos] = wrapf(current_angle + signf(ang_diff) * max_step, -PI, PI)
		else:
			turret_angles[grid_pos] = lerp_angle(current_angle, target_angle, delta * 8.0)
		# Per-barrel toe-in: each head aims at the target from its own
		# muzzle pivot and is clamped to ±BARREL_TOE_IN_MAX from the
		# chassis angle so the heads can converge on a close target.
		_update_barrel_toe_in(grid_pos, data, turret_world, target_world, delta)

		# Multi-barrel: any barrel with a cooldown <= 0 is ready to fire.
		# Single-barrel falls back to the original scalar cooldown.
		var ready_barrel: int = -1
		if barrel_count > 1:
			var bcd_r: Array = turret_barrel_cooldowns[grid_pos]
			for i in range(bcd_r.size()):
				if float(bcd_r[i]) <= 0.0:
					ready_barrel = i
					break
			if ready_barrel < 0:
				continue
		elif turret_cooldowns[grid_pos] > 0:
			continue
		else:
			# Single-barrel: barrel index is implicitly 0 once we pass the
			# cooldown gate. Used by recoil (and any other per-barrel
			# bookkeeping that assumes a non-negative index).
			ready_barrel = 0

		# --- Ammo check: if turret has ammo_types, it needs resources to fire ---
		# Damage now lives on AmmoType. The block-level field was removed,
		# so seed with 0 — the ammo branch below overwrites this before
		# any shot fires (and the no-ammo path returns early).
		var fire_damage: float = 0.0
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
		var full_cooldown: float = data.attack_speed * fire_reload_mult
		if barrel_count > 1:
			# Reset just this barrel; the other barrels keep their own
			# cooldowns so the stagger holds across fires.
			var bcd_w: Array = turret_barrel_cooldowns[grid_pos]
			bcd_w[ready_barrel] = full_cooldown
			var bff_w: Array = turret_barrel_fire_flash[grid_pos]
			bff_w[ready_barrel] = 0.1
			# Also keep the scalar cooldown in sync with the soonest-
			# ready barrel so non-firing code paths (tooltip, analytics)
			# see the right value.
			var min_cd: float = full_cooldown
			for v in bcd_w:
				min_cd = minf(min_cd, float(v))
			turret_cooldowns[grid_pos] = maxf(min_cd, 0.0)
		else:
			turret_cooldowns[grid_pos] = full_cooldown
		# Kick the firing barrel back. Decay handled by the per-frame loop.
		var brc_fire: Array = turret_barrel_recoil[grid_pos]
		if ready_barrel >= 0 and ready_barrel < brc_fire.size():
			brc_fire[ready_barrel] = 1.0

		# Spawn projectile from the rendered barrel TIP. The head sprite is
		# drawn with its tip at local (lateral, -tex_size.y + 14) before
		# being rotated by aim+π/2 — mirror that math here so the bullet
		# comes out of the actual muzzle no matter which barrel just fired
		# or how big the head texture is. Fallback to GRID_SIZE*0.4 when
		# the turret has no head sprite (legacy shape-only turrets).
		# Chassis basis = where the barrels are mounted (no toe-in). The
		# muzzle pivot for barrel i sits perpendicular to the chassis
		# aim, but the bullet leaves along that barrel's own toe-in
		# angle so a converged target gets hit head-on.
		var chassis_dir := Vector2.from_angle(turret_angles[grid_pos])
		var chassis_perp := Vector2(-chassis_dir.y, chassis_dir.x)
		var barrel_a: float = float(turret_barrel_angles[grid_pos][ready_barrel])
		var aim_dir := Vector2.from_angle(barrel_a)
		var barrel_length: float = main.GRID_SIZE * 0.4
		if data.turret_head_sprite:
			var head_tex_size: Vector2 = data.turret_head_sprite.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
			# +14 matches the pivot offset used in _draw_turret_heads.
			barrel_length = maxf(head_tex_size.y - 14.0 * main.SPRITE_SCALE_FACTOR, 0.0)
		var lateral_offset: float = 0.0
		if barrel_count > 1:
			lateral_offset = (float(ready_barrel) - (float(barrel_count) - 1.0) * 0.5) * data.barrel_spacing
		var fire_pos = turret_world + chassis_perp * lateral_offset + aim_dir * barrel_length

		# Spawn one projectile per pellet, applying inaccuracy spread.
		# Shot direction starts along the aim axis from the firing barrel's
		# muzzle, not "fire_pos toward target_world". With a lateral barrel
		# offset (multi-barrel turrets), targeting the absolute target
		# position would make each bullet veer diagonally back toward the
		# turret's centre the instant it spawned, which visually reads as
		# "all bullets come from the middle". Travelling along aim_dir
		# keeps each bullet in a straight line out of its own barrel.
		var base_shot_dir: Vector2 = aim_dir
		if lateral_offset == 0.0 and (target_world - fire_pos).length() > 0.001:
			base_shot_dir = (target_world - fire_pos).normalized()
		var shot_distance: float = maxf((target_world - fire_pos).length(), 1.0)
		var pellet_total: int = maxi(fire_pellets, 1)
		# Multi-pellet salvos share a shot_id so repeat hits on the same
		# target halve damage per extra pellet.
		var salvo_shot_id: int = _next_shot_id() if pellet_total > 1 else 0
		for pellet_i in range(pellet_total):
			# Evenly distribute pellets across the inaccuracy cone instead
			# of pure random spread. Each pellet gets its own slot of the
			# cone (1/N of the total width) and we only jitter inside that
			# slot, so 6 pellets always come out as a fan rather than
			# clustering near the centre by chance.
			var spread_rad: float = 0.0
			if fire_inaccuracy > 0.0 and pellet_total > 1:
				var t: float = float(pellet_i) / float(pellet_total - 1)  # 0..1
				var slot_w: float = (2.0 * fire_inaccuracy) / float(pellet_total)
				var center_deg: float = lerp(-fire_inaccuracy, fire_inaccuracy, t)
				var jitter_deg: float = randf_range(-slot_w * 0.5, slot_w * 0.5)
				spread_rad = deg_to_rad(center_deg + jitter_deg)
			elif fire_inaccuracy > 0.0:
				spread_rad = deg_to_rad(randf_range(-fire_inaccuracy, fire_inaccuracy))
			var pellet_angle: float = base_shot_dir.angle() + spread_rad
			var pellet_target: Vector2 = fire_pos + Vector2.from_angle(pellet_angle) * shot_distance

			# Turret effective range in pixels (base range in grid tiles + any
			# ammo range bonus). Projectiles despawn once they've traveled this
			# far from their spawn point.
			var fire_max_range: float = (data.attack_range * main.GRID_SIZE) + fire_range_bonus

			if shoot_at_unit:
				# Multi-barrel turrets need their projectiles to travel
				# along the aim axis so each bullet visibly comes out of
				# its own barrel instead of snapping back toward the
				# centre. For single-barrel / centred turrets we preserve
				# the historical "aim at actual target" behaviour so the
				# bullet lands exactly on the unit.
				var proj_target: Vector2 = pellet_target if lateral_offset != 0.0 else \
					(nearest_unit.position if pellet_i == 0 and fire_pellets == 1 else pellet_target)
				_spawn_projectile(
					fire_pos,
					nearest_unit,
					proj_target,
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
						"shot_id": salvo_shot_id,
					},
				)
			else:
				var proj_target_b: Vector2 = pellet_target if lateral_offset != 0.0 else \
					(target_world if pellet_i == 0 and fire_pellets == 1 else pellet_target)
				_spawn_projectile(
					fire_pos,
					nearest_bldg,
					proj_target_b,
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
						"shot_id": salvo_shot_id,
					},
				)


## Springs every barrel angle back toward the chassis angle. Called each
## tick so a turret that just lost its target eventually re-centres.
func _relax_barrels_to_chassis(grid_pos: Vector2i, delta: float) -> void:
	if not turret_barrel_angles.has(grid_pos):
		return
	var arr: Array = turret_barrel_angles[grid_pos]
	var chassis_a: float = float(turret_angles.get(grid_pos, 0.0))
	var step: float = delta * BARREL_TURN_SPEED
	for i in range(arr.size()):
		var lerped: float = lerp_angle(float(arr[i]), chassis_a, step)
		# Hard-clamp to ±BARREL_TOE_IN_MAX so a chassis snap can't leave
		# a barrel parked outside its cone for a frame.
		var off: float = wrapf(lerped - chassis_a, -PI, PI)
		off = clampf(off, -BARREL_TOE_IN_MAX, BARREL_TOE_IN_MAX)
		arr[i] = chassis_a + off


## Per-barrel toe-in update. Each barrel's pivot is offset perpendicular
## to the chassis aim by the same lateral mounting math used for drawing
## and firing. From that pivot, each head wants to look directly at the
## target; we clamp the deviation to ±BARREL_TOE_IN_MAX from the chassis
## angle so the heads can converge on close targets without spinning all
## the way to a side. Single-barrel turrets still call this — the array
## is length 1 and the pivot equals the centre, so the per-barrel angle
## just tracks the chassis with no visible difference.
func _update_barrel_toe_in(grid_pos: Vector2i, data, turret_world: Vector2, target_world: Vector2, delta: float) -> void:
	if not turret_barrel_angles.has(grid_pos):
		return
	var barrel_arr: Array = turret_barrel_angles[grid_pos]
	var bcount: int = barrel_arr.size()
	if bcount <= 0:
		return
	var chassis_a: float = float(turret_angles.get(grid_pos, 0.0))
	var chassis_dir := Vector2.from_angle(chassis_a)
	var chassis_perp := Vector2(-chassis_dir.y, chassis_dir.x)
	var spacing: float = data.barrel_spacing if data else 10.0
	var step: float = delta * BARREL_TURN_SPEED
	for i in range(bcount):
		var lateral: float = 0.0
		if bcount > 1:
			lateral = (float(i) - (float(bcount) - 1.0) * 0.5) * spacing
		var pivot: Vector2 = turret_world + chassis_perp * lateral
		var to_target: Vector2 = target_world - pivot
		var desired: float = chassis_a
		if to_target.length_squared() > 0.001:
			desired = to_target.angle()
		var off: float = wrapf(desired - chassis_a, -PI, PI)
		off = clampf(off, -BARREL_TOE_IN_MAX, BARREL_TOE_IN_MAX)
		var clamped: float = chassis_a + off
		var lerped: float = lerp_angle(float(barrel_arr[i]), clamped, step)
		# Hard-clamp the post-lerp angle so the barrel can NEVER sit
		# outside its ±BARREL_TOE_IN_MAX cone — even mid-transition. The
		# lerp can momentarily land outside if the previous frame's
		# chassis angle was different and the per-barrel angle drifted.
		var final_off: float = wrapf(lerped - chassis_a, -PI, PI)
		final_off = clampf(final_off, -BARREL_TOE_IN_MAX, BARREL_TOE_IN_MAX)
		barrel_arr[i] = chassis_a + final_off


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

	var drone = _drone_ref()
	if drone == null:
		return

	# Don't shoot while mining ore
	if drone.mining_target != null:
		drone_is_shooting = false
		return

	# Don't shoot while terrain paint mode is active.
	var terrain = _terrain_ref()
	if terrain and terrain.paint_mode:
		drone_is_shooting = false
		return

	# Manual shoot is active only in default mode AND while LMB is held
	# (with no GUI hover / no building selected). Outside that window
	# the drone falls through to the AI auto-shoot branch so it keeps
	# returning fire while the player is busy manually healing in heal
	# mode — and so it passively defends in default mode when idle.
	var heal_active: bool = "heal_mode" in drone and bool(drone.heal_mode)
	var manual_shoot_active: bool = false
	if not heal_active:
		var lmb: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		if main.selected_building != &"":
			lmb = false
		if get_viewport().gui_get_hovered_control() != null:
			lmb = false
		manual_shoot_active = lmb
	drone_is_shooting = manual_shoot_active

	if not manual_shoot_active:
		# AI auto-shoot: nearest enemy in range, on the same cooldown
		# clock as manual fire. Runs in either mode whenever manual
		# shooting isn't actively driving. Targets enemy units first,
		# then falls back to nearest enemy building in range so the
		# drone helps chip away at FEROX bases when no units are around.
		if drone_cooldown > 0:
			return
		var range_px_a: float = drone_range * main.GRID_SIZE
		var enemies_a: Array[Node2D] = unit_mgr.enemies if unit_mgr else [] as Array[Node2D]
		var nearest_a: Node2D = _find_nearest_enemy(drone.position, enemies_a)
		if nearest_a != null and drone.position.distance_to(nearest_a.position) <= range_px_a:
			drone_cooldown = drone_attack_speed
			# Bullet flies along the muzzle's actual facing direction
			# (not muzzle→target) so a free-rotating head whose front
			# isn't quite on-target this frame still spits projectiles
			# out the barrel rather than firing them sideways.
			var muzzle_a: Dictionary = _drone_muzzle_info(drone, nearest_a.position)
			_spawn_projectile(
				muzzle_a["pos"],
				nearest_a,
				muzzle_a["pos"] + muzzle_a["dir"] * range_px_a,
				"enemy",
				drone_projectile_speed,
				drone_damage,
				Color(0.3, 0.9, 1.0, 1.0),
				"drone",
				false,
				0.0,
			)
			return

		# No enemy unit in range — try a hostile building (FEROX, plus
		# any non-LUMINA-non-DERELICT block). Picks the closest anchor
		# tile within range.
		var nearest_bldg: Vector2i = _find_nearest_enemy_building(drone.position, range_px_a)
		if nearest_bldg == Vector2i(-9999, -9999):
			return
		var b_world: Vector2 = main.grid_to_world(nearest_bldg) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		drone_cooldown = drone_attack_speed
		var muzzle_b: Dictionary = _drone_muzzle_info(drone, b_world)
		_spawn_projectile(
			muzzle_b["pos"],
			nearest_bldg,
			muzzle_b["pos"] + muzzle_b["dir"] * range_px_a,
			"building",
			drone_projectile_speed,
			drone_damage,
			Color(0.3, 0.9, 1.0, 1.0),
			"drone",
			false,
			0.0,
		)
		return

	if drone_cooldown > 0:
		return

	# Fire!
	drone_cooldown = drone_attack_speed

	var mouse_pos = get_global_mouse_position()
	var muzzle_m: Dictionary = _drone_muzzle_info(drone, mouse_pos)
	# Bullet leaves the muzzle along the muzzle's own facing axis so
	# the trajectory matches whatever direction the visible head is
	# pointing — even if it's lagged behind the cursor or rotated past
	# the chassis-forward arc.
	var target_pos = muzzle_m["pos"] + muzzle_m["dir"] * drone_range * main.GRID_SIZE

	_spawn_projectile(
		muzzle_m["pos"],
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


## Resolves both the next muzzle's world position and its forward
## direction for the player drone. Falls back gracefully on builds
## without `next_turret_muzzle_world_info` — older drones return only
## a position, in which case we synthesise a direction from the muzzle
## back to the drone center → target line.
func _drone_muzzle_info(drone: Node2D, fallback_target: Vector2) -> Dictionary:
	if drone.has_method("next_turret_muzzle_world_info"):
		return drone.next_turret_muzzle_world_info()
	var pos: Vector2 = drone.position
	if drone.has_method("next_turret_muzzle_world_pos"):
		pos = drone.next_turret_muzzle_world_pos()
	var dir: Vector2 = (fallback_target - drone.position).normalized()
	if dir.length_squared() < 0.001:
		dir = Vector2(1.0, 0.0)
	return {"pos": pos, "dir": dir}


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
		"shot_id": int(extras.get("shot_id", 0)),
	}
	var sid: int = int(proj["shot_id"])
	if sid != 0:
		_shot_active[sid] = int(_shot_active.get(sid, 0)) + 1
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

		# --- Wall collision along the flight path ---
		# Walls block bullets regardless of projectile type — handled
		# BEFORE unit / building hit checks so a turret shooting at an
		# enemy building can't sneak its round through a defending wall,
		# and (per the bug report) so enemies can't shoot through the
		# diagonal gap between two corner-touching walls. Damages the
		# wall it stops on; bullets self-destruct on impact.
		var move_pos: Vector2 = proj["pos"] + direction * step
		var wall_hit: Vector2i = _check_bullet_hit_wall(move_pos, proj["pos"], int(proj.get("source_faction", -1)))
		if wall_hit != Vector2i(-1, -1):
			main.damage_building(wall_hit, _shot_damage(proj, wall_hit, proj["damage"]))
			to_remove.append(i)
			continue

		# --- Direct-fire bullets (drone, controlled unit/turret): hit enemies and buildings along path ---
		if proj["target_type"] == "none" and unit_mgr:
			var hit_enemy = _check_bullet_hit_enemy(move_pos, proj["pos"], unit_mgr)
			if hit_enemy:
				hit_enemy.take_damage(_shot_damage(proj, hit_enemy.get_instance_id(), proj["damage"]))
				to_remove.append(i)
				continue
			# Check if the bullet hits an opposing-faction building
			var source_faction: int = proj.get("source_faction", 0)
			var hit_bldg: Vector2i = _check_bullet_hit_building(move_pos, proj["pos"], source_faction)
			if hit_bldg != Vector2i(-1, -1):
				main.damage_building(hit_bldg, _shot_damage(proj, hit_bldg, proj["damage"]))
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
		var dead_proj: Dictionary = projectiles[to_remove[i]]
		_release_shot_id(int(dead_proj.get("shot_id", 0)))
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
					enemy.take_damage(_shot_damage(proj, enemy.get_instance_id(), proj["damage"]))
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
					main.damage_building(grid_pos, _shot_damage(proj, grid_pos, proj["damage"]))

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


## Returns the anchor cell of the nearest hostile (non-LUMINA, non-DERELICT)
## building within `range_px` of `from_pos`, or Vector2i(-9999, -9999) if
## none. Used by the drone auto-shooter so the drone helps tear down FEROX
## bases when no enemy units are around.
func _find_nearest_enemy_building(from_pos: Vector2, range_px: float) -> Vector2i:
	var best_anchor: Vector2i = Vector2i(-9999, -9999)
	var best_dist_sq: float = range_px * range_px
	var seen := {}
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if seen.has(anchor):
			continue
		seen[anchor] = true
		var faction: int = main.get_building_faction(anchor) if main.has_method("get_building_faction") else main.Faction.LUMINA
		# Friendly buildings and abandoned (DERELICT) ones are off-limits.
		if faction == main.Faction.LUMINA or faction == main.Faction.DERELICT:
			continue
		# Skip under-construction / being-deconstructed blocks so the
		# drone doesn't waste shots on a half-built target ghost.
		if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
			continue
		# Skip platforms — invulnerable terrain, no point shooting them.
		var bd_n = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if bd_n and bd_n.tags.has("platform"):
			continue
		var w: Vector2 = main.grid_to_world(anchor) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		var d2: float = from_pos.distance_squared_to(w)
		if d2 < best_dist_sq:
			best_dist_sq = d2
			best_anchor = anchor
	return best_anchor

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
## Returns the grid_pos (anchor) of a wall block intercepting this
## bullet's flight segment — or (-1, -1) if the path is clear. Handles
## the diagonally-placed-walls corner case: when the segment steps
## diagonally between two grid cells whose perpendicular neighbours are
## both walls, the bullet is treated as hitting one of those walls
## instead of squeezing through the gap. Walls are identified by the
## "wall" tag on their BlockData.
## Returns the anchor of a wall cell that intercepts the bullet path, or
## (-1, -1) if none. `source_faction` lets a shot pass *through* its own
## faction's walls — without this, the player drone (LUMINA) shooting
## past a friendly wall would damage that wall, and FEROX turrets would
## chip their own wall line.
func _check_bullet_hit_wall(bullet_pos: Vector2, bullet_prev: Vector2, source_faction: int = -1) -> Vector2i:
	var seg: Vector2 = bullet_pos - bullet_prev
	var dist: float = seg.length()
	if dist < 0.5:
		var gp: Vector2i = main.world_to_grid(bullet_pos)
		if _is_wall_cell(gp) and not _is_friendly_wall(gp, source_faction):
			return main.building_origins.get(gp, gp)
		return Vector2i(-1, -1)
	# Step a little finer than half a tile so the path can't skip over a
	# 1-tile wall on a fast-moving bullet.
	var step_size: float = main.GRID_SIZE * 0.4
	var steps: int = int(ceil(dist / step_size)) + 1
	var prev_cell: Vector2i = main.world_to_grid(bullet_prev)
	for s in range(steps):
		var t: float = float(s) / float(maxi(steps - 1, 1))
		var sample_pos: Vector2 = bullet_prev.lerp(bullet_pos, t)
		var cell: Vector2i = main.world_to_grid(sample_pos)
		if _is_wall_cell(cell) and not _is_friendly_wall(cell, source_faction):
			return main.building_origins.get(cell, cell)
		# Diagonal-gap detection: when the bullet just stepped from
		# `prev_cell` to a diagonal neighbour without entering one of
		# the two perpendicular cells, those cells form a corner that a
		# bullet shouldn't be able to slip through if both are walls.
		if cell != prev_cell:
			var dx: int = cell.x - prev_cell.x
			var dy: int = cell.y - prev_cell.y
			if absi(dx) == 1 and absi(dy) == 1:
				var c1: Vector2i = Vector2i(prev_cell.x + dx, prev_cell.y)
				var c2: Vector2i = Vector2i(prev_cell.x, prev_cell.y + dy)
				var c1_blocks: bool = _is_wall_cell(c1) and not _is_friendly_wall(c1, source_faction)
				var c2_blocks: bool = _is_wall_cell(c2) and not _is_friendly_wall(c2, source_faction)
				if c1_blocks and c2_blocks:
					# Take the wall on the side closer to the segment's
					# end so damage routes consistently per shot.
					return main.building_origins.get(c1, c1)
			prev_cell = cell
	return Vector2i(-1, -1)


func _is_wall_cell(grid_pos: Vector2i) -> bool:
	if not main.placed_buildings.has(grid_pos):
		return false
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	return data != null and data.tags.has("wall")


## True if the wall at `grid_pos` belongs to the same faction as the
## shooter — used by `_check_bullet_hit_wall` so a friendly wall doesn't
## intercept a friendly shot. Returns false when source_faction is < 0
## (i.e. the caller didn't supply one), so legacy callers keep their
## original blocks-everything behaviour.
func _is_friendly_wall(grid_pos: Vector2i, source_faction: int) -> bool:
	if source_faction < 0:
		return false
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	if main.has_method("get_building_faction"):
		return int(main.get_building_faction(anchor)) == source_faction
	return false


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
		# Seed the turret's chassis aim from the rotation it was placed
		# at, so a player who pre-rotates with Q sees the heads point
		# that way the moment the build finishes (instead of always
		# snapping to 0° = right and slowly tracking the first target).
		# Rotation values: 0=Right, 1=Down, 2=Left, 3=Up — same convention
		# the placement preview and direction-arrow code use.
		var rot: int = int(main.building_rotation.get(grid_pos, 0))
		turret_angles[grid_pos] = float(rot) * (PI / 2.0)


func _on_building_destroyed(grid_pos: Vector2i) -> void:
	turret_cooldowns.erase(grid_pos)
	turret_angles.erase(grid_pos)
	turret_barrel_cooldowns.erase(grid_pos)
	turret_barrel_fire_flash.erase(grid_pos)
	turret_barrel_recoil.erase(grid_pos)
	turret_barrel_angles.erase(grid_pos)


# =========================
# DRAWING
# =========================

func _draw() -> void:
	_draw_turret_heads()
	# Projectiles render on `_projectile_overlay` (z_index 4095) so
	# they always sit above the chassis / buildings / terrain overlay,
	# regardless of how those siblings configure their own z_indices.
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
		# stretching to the block's tile size. Multi-barrel turrets draw N
		# copies offset perpendicular to the aim axis so each head sits at
		# its own muzzle position.
		if data.turret_head_sprite:
			var tex: Texture2D = data.turret_head_sprite
			var tex_size: Vector2 = tex.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
			var bcount: int = maxi(data.barrel_count, 1)
			var brc_d: Array = turret_barrel_recoil.get(grid_pos, [])
			var bang_d: Array = turret_barrel_angles.get(grid_pos, [])
			# Chassis basis: barrel pivots are mounted perpendicular to the
			# chassis aim, NOT to the per-barrel toed-in aim, so the muzzle
			# mounts stay rigid even when the heads converge.
			var chassis_dir := Vector2.from_angle(angle)
			var chassis_perp := Vector2(-chassis_dir.y, chassis_dir.x)
			# Multi-barrel chassis plate: drawn UNDER the heads, rotated
			# by the shared chassis angle only so the heads read as
			# mounted on a common base while still toeing in
			# independently. Prefers the block's authored chassis
			# sprite; falls back to a procedural gray rectangle sized
			# to span the barrel mounts.
			if bcount > 1:
				draw_set_transform(center, angle + PI / 2.0)
				if data.turret_chassis_sprite:
					var chassis_tex: Texture2D = data.turret_chassis_sprite
					var chassis_size: Vector2 = chassis_tex.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
					var chassis_rect := Rect2(
						Vector2(-chassis_size.x * 0.5, -chassis_size.y * 0.5),
						chassis_size,
					)
					draw_texture_rect(chassis_tex, chassis_rect, false)
				else:
					var plate_w: float = (float(bcount) - 1.0) * data.barrel_spacing + tex_size.x * 0.9
					var plate_h: float = tex_size.y * 0.35
					draw_rect(
						Rect2(Vector2(-plate_w * 0.5, -plate_h * 0.5), Vector2(plate_w, plate_h)),
						Color(0.32, 0.32, 0.34, 1.0),
					)
				draw_set_transform(Vector2.ZERO, 0.0)
			for i in range(bcount):
				var lateral: float = 0.0
				if bcount > 1:
					lateral = (float(i) - (float(bcount) - 1.0) * 0.5) * data.barrel_spacing
				var pivot_world: Vector2 = center + chassis_perp * lateral
				var barrel_a: float = float(bang_d[i]) if i < bang_d.size() else angle
				var draw_angle: float = barrel_a + PI / 2.0
				# Recoil pushes the head back along the barrel (local +Y in
				# head space, since the rect's tip is at -tex_size.y + 14).
				var recoil_amt: float = float(brc_d[i]) if i < brc_d.size() else 0.0
				var recoil_kick: float = recoil_amt * RECOIL_PIXELS
				draw_set_transform(pivot_world, draw_angle)
				# Rect centred on this barrel's pivot — lateral offset is
				# baked into pivot_world, so x is just -tex/2.
				var head_rect := Rect2(
					Vector2(-tex_size.x * 0.5, -tex_size.y + 14.0 * main.SPRITE_SCALE_FACTOR + recoil_kick),
					tex_size
				)
				draw_texture_rect(tex, head_rect, false)
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

## Draws every active projectile onto `canvas`. The canvas is passed
## in (instead of using `self`) so the dedicated `ProjectileOverlay`
## child node can host the draw on its own high-z layer — the draw
## primitives operate on whatever CanvasItem they're called on, and
## a bare `draw_circle(...)` here would always target this node.
func _draw_projectiles(canvas: CanvasItem) -> void:
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
				canvas.draw_line(trail[t], trail[t + 1], trail_color, width)

		# Draw trail line from last trail point to current pos
		if trail.size() > 0:
			var trail_color = Color(color.r, color.g, color.b, 0.5)
			canvas.draw_line(trail[trail.size() - 1], pos, trail_color, radius * 0.8)

		# Draw the projectile itself — bright glowing circle
		canvas.draw_circle(pos, radius + 1.0, Color(color.r, color.g, color.b, 0.3))
		canvas.draw_circle(pos, radius, color)
		canvas.draw_circle(pos, radius * 0.5, color.lightened(0.5))

		if main and main.show_hitboxes:
			canvas.draw_arc(pos, radius, 0, TAU, 24, Color(1.0, 0.2, 0.9, 0.9), 1.5)
			var aoe_r: float = float(proj.get("aoe_radius", 0.0))
			if aoe_r > 0.0:
				canvas.draw_arc(pos, aoe_r, 0, TAU, 48, Color(1.0, 0.5, 0.0, 0.7), 1.0)


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
