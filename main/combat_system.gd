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
var _launch_anim: Node
var _logistics: Node2D
var _watchtower_sys: Node

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

# --- GAS CLOUDS (Fume turret + sulfur vents + Spritz oxygen/hydrogen) ---
# key -> {center: Vector2, radius: float, target_radius: float, t_last: float,
#         type: "fume"|"vent"|"oxygen"|"hydrogen", ...}. A cloud grows toward
# target_radius and applies a per-type effect to enemies inside. Fume turrets key
# by "fume:x,y" and refresh each frame they have fumes; sulfur vents by
# "vent:x,y"; Spritz oxygen/hydrogen clouds get a unique "oxygen:N"/"hydrogen:N"
# key (see _feed_gas_cloud) and grow as more is sprayed in, shrinking when not.
# Oxygen clouds also carry { ignited, fire_t, fire_origin } for the Flarecaster
# detonation.
var gas_clouds: Dictionary = {}
var _cloud_time: float = 0.0
var _vent_cloud_scan_timer: float = 0.0
var _cloud_damage_timer: float = 0.0
var _gas_seq: int = 0  # monotonic id for Spritz-sprayed clouds
var _particle_overlay: Node = null  # cached ref for block-on-fire particles
# Spritz gas-cloud tuning (in tiles / seconds).
const GAS_FEED_PER_SHOT := 0.55     # radius added per shot
const GAS_MAX_RADIUS := 3.0         # cap on a cloud's radius
const GAS_MERGE_DIST := 2.5         # a shot within this of a same-kind cloud feeds it
const GAS_DECAY_RATE := 1.2         # radius/sec a cloud shrinks once it stops being fed
# Oxygen detonation timing (seconds).
const OXY_FIRE_SPREAD := 0.5        # fire grows from the entry point to cover the cloud
const OXY_FIRE_DURATION := 4.0      # full-strength burn
const OXY_FIRE_FADE := 1.5          # then shrinks to nothing

# --- MUZZLE FLAME (Flarecaster) ---
# Replicates Mindustry's Fx.shootSmallFlame: each shot spits a short cone of
# fire particles that fan out, shrink, and fade lightFlame→darkFlame→gray.
# Each entry: {pos0: Vector2, ang: float, reach: float, age: float, life: float}.
# Liquid-bullet puddle splats (Corrosion). Each: {pos, color, radius, age, life}.
var _liquid_splashes: Array = []

# Mindustry-style bullet FX, all short-lived and drawn on the projectile
# overlay above the bullets. Shoot (muzzle), hit and despawn effects all feed
# these shared pools, pruned by age like the flame particles below.
var _muzzle_flashes: Array = []   # {pos, ang, age, life, scale, color}
var _bullet_sparks: Array = []    # {pos, ang, len, age, life, color}
var _bullet_smoke: Array = []     # {pos0, ang, reach, age, life, size}
var _despawn_rings: Array = []    # {pos, age, life, scale, color}

var _flame_particles: Array = []
const _FLAME_LIGHT := Color(1.0, 0.867, 0.333)   # Pal.lightFlame
const _FLAME_DARK := Color(1.0, 0.408, 0.251)    # Pal.darkFlame
const _FLAME_GRAY := Color(0.5, 0.5, 0.5)
const _FLAME_COUNT := 8
const _FLAME_SPREAD_DEG := 12.0
# Half-angle of the Flarecaster's damaging flame cone.
const _FLAME_CONE_DEG := 14.0
# Per-flame-turret fuel meter: anchor -> seconds since last fuel was burned.
var _flame_fuel_acc: Dictionary = {}
# Per-flame-turret paid fuel type, kept active between fuel burn ticks.
var _flame_active_ammo: Dictionary = {}

# --- Eclipse continuous cutting beam state ---
# anchor -> { phase:int, timer:float, start:Vector2, end:Vector2, active:bool }.
# phase 0 = idle (waiting for a target + ammo), 1 = firing the beam, 2 = cooling
# down. Each activation pays 2 oxygen + 2 hydrogen, fires for BEAM_FIRE_TIME,
# then locks out for BEAM_COOLDOWN_TIME. `active` is set true only on frames the
# beam actually renders + damages, so _draw_beams skips idle/cooldown turrets.
var beam_states: Dictionary = {}
const BEAM_FIRE_TIME := 7.0       # seconds of continuous beam per activation
const BEAM_COOLDOWN_TIME := 9.0   # lockout after a beam burst finishes
const BEAM_HALF_WIDTH := 6.0      # px — beam thickness for unit collision

# --- Blaster (charge + quarter-circle shockwave) state ---
# anchor -> { phase:int, charge:float, cooldown:float, draw_charge:float,
#            muzzle:Vector2 }. phase 0 = charging (winds up while it has a
#            target), 1 = cooldown. On a full charge it pays 3 hydrogen, emits
# one shockwave, and locks out for `attack_speed` seconds. `draw_charge`/`muzzle` feed
# the charge-glow visual.
var blaster_states: Dictionary = {}
# Charge (wind-up) and post-shot cooldown are data-driven — see BlockData's
# `charge_time` and `attack_speed`.
# Active expanding shockwaves (one per shot). Each: { origin:Vector2, aim:float,
# radius:float, max_radius:float, speed:float, faction:int, dps:float,
# hit:Dictionary }. Knockback lands once per unit (tracked in `hit`); contact
# damage applies each frame the ring front overlaps the unit.
var shockwaves: Array = []
const SHOCKWAVE_EXPAND_TIME := 0.6                  # seconds to reach max radius
const SHOCKWAVE_HALF_ANGLE: float = deg_to_rad(45.0)  # quarter-circle = ±45°
const SHOCKWAVE_BAND := 12.0                        # px ring thickness for contact
const SHOCKWAVE_KNOCKBACK_TILES := 2.0              # tiles of shove per unit

# --- TURRET STATE ---
# Key = Vector2i grid pos of a turret, Value = float (cooldown remaining)
var turret_cooldowns := {}

# --- Arc (lightning) turret state ---
# Per-anchor continuous-fire "charge" in [0, 1]. Ramps UP while the turret has
# a live target (firing) and decays toward 0 when idle. The reload between
# bolts is lerped from ARC_MAX_RELOAD (slow) at charge 0 to ARC_MIN_RELOAD
# (fast) at charge 1, so the Arc visibly winds up the longer it runs.
var arc_charge := {}
# Active lightning bolt visuals: { "points": PackedVector2Array, "age": float,
# "lifetime": float, "color": Color }. Drawn on the projectile overlay.
var _lightning_bolts: Array = []
const ARC_MAX_RELOAD := 2.0      # seconds between shots when cold (charge 0)
const ARC_MIN_RELOAD := 0.3      # seconds between shots when fully wound (charge 1)
const ARC_RAMP_UP_TIME := 15.0   # seconds of continuous fire to reach full speed
const ARC_RAMP_DOWN_TIME := 8.0  # seconds idle to fully spin back down
const ARC_SEGMENTS := 12         # vertices in a bolt (≈ Mindustry lightningLength/2)
const ARC_MAX_CHAIN := 5         # how many enemies one bolt may chain through
const ARC_BOLT_LIFETIME := 0.12  # how long a bolt stays on screen
const ARC_BLDG_DAMAGE_MULT := 0.25  # Mindustry's buildingDamageMultiplier
const ARC_BOLTS_PER_SHOT := 3    # bolts loosed per shot (Mindustry arc fans several)
const ARC_BOLT_FAN_DEG := 18.0   # angular spread between those bolts
const ARC_COLOR := Color(0.6, 0.85, 1.0, 1.0)

# --- Spritz turret state ---
# Per-unit recent-hit marks for the slag + petroleum combo. unit_id ->
# { &"mat_slag": secs_left, &"mat_petroleum": secs_left }. When a unit has both
# marks live, the slag's effects are doubled (see _spritz_on_hit).
var _spritz_marks: Dictionary = {}
const SPRITZ_MARK_WINDOW := 4.0    # how long a slag/petroleum mark lingers (s)
const SPRITZ_SLAG_DAMAGE := 16.0   # bonus damage applied when the pairing completes

# --- Structural combat caches (perf) ---
# The targeting snapshot + turret update used to scan ALL placed_buildings
# (with a Registry.get_block per cell) every frame. Both the turret-anchor
# list and the "targetable buildings" set depend only on which block sits
# where (structural), so we rebuild them once per place/destroy instead.
# Rebuilt lazily when `_combat_cache_dirty` or the building count drifts.
var _turret_anchors: Array = []          # Array[Vector2i] — anchor cells of turrets
var _filtered_buildings_cache: Dictionary = {}  # cell -> block_id, minus platforms / no_pathfinding
var _combat_cache_dirty := true
var _combat_cache_count := -1

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

## Looks up the additive attack-range bonus (in tiles) granted by any
## active LUMINA Watchtower whose 10-tile aura covers `turret_anchor`.
## Returns 0 if no watchtower system is mounted (editor / loading) or
## the turret is outside every aura.
func _watchtower_range_bonus(turret_anchor: Vector2i) -> float:
	# Reuse cached `_watchtower_sys` ref — the previous per-call
	# `get_node_or_null` was walking the scene tree once per turret per
	# combat tick (commonly 3-4× per frame per turret).
	if _watchtower_sys and _watchtower_sys.has_method("get_turret_range_bonus_tiles"):
		return float(_watchtower_sys.get_turret_range_bonus_tiles(turret_anchor))
	return 0.0


func _flame_range_bonus_for_targeting(data: BlockData, turret_anchor: Vector2i) -> float:
	if data == null or not data.tags.has("flame_emitter"):
		return 0.0
	var ammo: AmmoType = _flame_active_ammo.get(turret_anchor, null) as AmmoType
	if ammo == null:
		ammo = _select_affordable_flame_ammo(data, turret_anchor)
	if ammo == null:
		return 0.0
	return ammo.flame_range_bonus_tiles


## Checks whether a turret currently has the required booster fluid /
## item in its block storage and, if so, consumes one tick's worth and
## returns the boost multiplier (e.g. 2.5 for +150 % fire rate). Falls
## back to 1.0 when nothing is configured / available.
func _get_active_booster_multiplier(anchor: Vector2i, data: BlockData, stat: String) -> float:
	if data == null or data.boosters.is_empty():
		return 1.0
	# Cached `_logistics` instead of re-querying the scene tree every
	# turret tick.
	var logistics = _logistics
	if logistics == null or not "block_storage" in logistics:
		return 1.0
	var storage: Dictionary = logistics.block_storage.get(anchor, {})
	# block_storage is a 2-bucket structure ({items: {...}, fluids: {...}}),
	# so a flat `storage.get(iid)` always misses fluids. Pick the right
	# bucket based on whether the booster id is a registered fluid.
	for entry in data.boosters:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if String(entry.get("stat", "")) != stat:
			continue
		var iid: StringName = StringName(entry.get("item_id", &""))
		var per_shot: float = float(entry.get("per_sec", 0.0)) * maxf(data.attack_speed, 0.01)
		var is_fluid: bool = Registry.get_fluid(iid) != null
		var bucket_key: String = "fluids" if is_fluid else "items"
		var bucket: Dictionary = storage.get(bucket_key, {})
		var avail: float = float(bucket.get(iid, 0.0))
		if avail >= per_shot and per_shot > 0.0:
			bucket[iid] = avail - per_shot
			storage[bucket_key] = bucket
			logistics.block_storage[anchor] = storage
			return float(entry.get("multiplier", 1.0))
	return 1.0


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

# Per-crane-anchor cooldown for held LUMINA turrets that fire at
# enemies while in transit. Anchor → seconds remaining; entries decay
# each frame and are dropped on payload drop / pickup.
var held_turret_cooldowns: Dictionary = {}
# Same idea, for held LUMINA units that fire at enemies in transit.
var held_unit_cooldowns: Dictionary = {}
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

var _fire_sys: Node = null
func _fire_sys_ref() -> Node:
	if _fire_sys == null:
		_fire_sys = get_node_or_null("/root/Main/FireSystem")
	return _fire_sys

func _building_sys_ref() -> Node:
	if _building_sys == null:
		_building_sys = get_node_or_null("/root/Main/BuildingSystem")
	return _building_sys

func _sector_script_ref() -> Node:
	if _sector_script == null:
		_sector_script = get_node_or_null("/root/Main/SectorScript")
	return _sector_script

func _launch_anim_ref() -> Node:
	if _launch_anim == null or not is_instance_valid(_launch_anim):
		_launch_anim = get_node_or_null("/root/Main/LaunchAnimation")
	return _launch_anim

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
	_watchtower_sys = get_node_or_null("/root/Main/WatchtowerSystem")
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
	_update_gas_clouds(delta)
	_update_liquid_splashes(delta)
	_update_flame_particles(delta)
	_update_bullet_fx(delta)
	_update_held_turrets(delta)
	_update_held_units(delta)
	_update_drone_combat(delta)
	_update_projectiles(delta)
	_update_lightning_bolts(delta)
	_update_shockwaves(delta)
	_tick_spritz_marks(delta)
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


## Rebuilds the turret-anchor list and the targetable-buildings set in one
## pass. Cheap to call (guarded), runs only when structure changes.
func _ensure_combat_cache() -> void:
	if not _combat_cache_dirty and main.placed_buildings.size() == _combat_cache_count:
		return
	_combat_cache_dirty = false
	_combat_cache_count = main.placed_buildings.size()
	var turrets: Array = []
	var seen: Dictionary = {}
	var filtered: Dictionary = {}
	for cell in main.placed_buildings:
		var bid: StringName = main.placed_buildings[cell]
		var data = Registry.get_block(bid)
		if data == null:
			continue
		# Targetable-buildings set (platforms / no_pathfinding excluded).
		if not (data.tags.has("platform") or data.tags.has("no_pathfinding")):
			filtered[cell] = bid
		# Turret anchor list (deduped to the anchor cell).
		if data.is_turret():
			var anchor: Vector2i = main.building_origins.get(cell, cell)
			if not seen.has(anchor):
				seen[anchor] = true
				turrets.append(anchor)
	_turret_anchors = turrets
	_filtered_buildings_cache = filtered


func _push_targeting_snapshot() -> void:
	if _targeting_worker == null:
		return

	var unit_mgr = _unit_mgr_ref()
	if unit_mgr == null:
		return

	# Build enemy snapshot. `movement_layer` lets the targeting worker
	# filter by turret.targets_air / targets_ground.
	var enemies_snap: Array = []
	for e in unit_mgr.enemies:
		if is_instance_valid(e):
			enemies_snap.append({
				"id": e.get_instance_id(),
				"pos": e.position,
				"is_dead": e.is_dead,
				"unit_size": e.unit_size,
				"movement_layer": int(e.data.movement_layer) if e.data else 0,
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
				"movement_layer": int(u.data.movement_layer) if u.data else 0,
			})

	# Build turret list. Only anchor cells generate snapshot entries —
	# otherwise a 2×2 turret would be simulated four times (quadrupling
	# its fire rate), and non-anchor cells can hold stale/default
	# faction values after a conversion pass, flipping a captured turret
	# back to acting Lumina for a frame.
	_ensure_combat_cache()
	var turrets_snap: Array = []
	var sector_script = _sector_script_ref()
	for anchor in _turret_anchors:
		if not main.placed_buildings.has(anchor):
			continue
		var data = Registry.get_block(main.placed_buildings[anchor])
		if data == null or not data.is_turret():
			continue
		if anchor == manually_controlled_turret:
			continue
		# Skip disabled or under-construction buildings
		if sector_script and sector_script.is_building_disabled(anchor):
			continue
		if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
			continue
		var turret_faction: int = main.get_building_faction(anchor)
		var range_tiles: float = data.attack_range + _watchtower_range_bonus(anchor) + _flame_range_bonus_for_targeting(data, anchor)
		turrets_snap.append({
			"grid_pos": anchor,
			"faction": turret_faction,
			"range_pixels": range_tiles * main.GRID_SIZE,
			"block_id": main.placed_buildings[anchor],
			"targets_air": data.targets_air,
			"targets_ground": data.targets_ground,
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
	# Cached set (rebuilt only on structural change) — platforms and
	# `no_pathfinding` blocks are already excluded.
	var filtered_buildings: Dictionary = _filtered_buildings_cache
	# Held entities: every crane state with a held payload contributes a
	# world-positioned target. Held LUMINA pieces sit in the player_units-
	# equivalent slot (FEROX turrets shoot at them); held FEROX pieces
	# (rare/unsupported in current setup) sit in the enemies slot. Each
	# entry uses the holding crane's anchor as a stable id, plus the
	# grabber's live world position.
	# Each crane contributes ONE entry per layer of its nested cargo.
	# A bullet can target a specific layer (the crane being held vs.
	# the block at the tip), so destroying a crane mid-chain doesn't
	# happen accidentally just because the projectile reached the tip.
	var held_targets_snap: Array = []
	var building_sys_snap = get_node_or_null("/root/Main/BuildingSystem")
	if building_sys_snap and building_sys_snap.has_method("collect_held_chain"):
		for ca in building_sys_snap.crane_states:
			var chain: Array = building_sys_snap.collect_held_chain(ca)
			for entry in chain:
				var pdict: Dictionary = entry["payload"]
				var ckind: String = String(pdict.get("type", ""))
				if ckind != "building" and ckind != "unit":
					continue
				var faction_h: int
				if ckind == "building":
					faction_h = int(pdict.get("faction", main.Faction.LUMINA))
				else:
					faction_h = main.get_building_faction(ca)
				held_targets_snap.append({
					"anchor": ca,
					"depth": int(entry["depth"]),
					"pos": entry["pos"],
					"faction": faction_h,
					"kind": ckind,
					"size": float(main.GRID_SIZE),
				})
	_targeting_worker.push_snapshot({
		"enemies": enemies_snap,
		"held_targets": held_targets_snap,
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

	_ensure_combat_cache()
	# Iterate only turret anchors (cached). Turret state, targeting, and head
	# drawing are all keyed by anchor, so per-cell iteration only ever did
	# real work at the anchor anyway.
	for grid_pos in _turret_anchors:
		if not main.placed_buildings.has(grid_pos):
			continue
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

		# Special "emitter" weapons (fume / flame / lightning) route through the
		# shared dispatch — the SAME helper the manual-control loop uses, so a
		# new emitter type is registered in exactly one place. Run every frame
		# (even at zero power) so the Arc's charge keeps decaying when idle.
		# `firing` = a valid in-range opposing target exists and there's power.
		if data.tags.has("fume_emitter") or data.tags.has("flame_emitter") or data.tags.has("lightning_emitter") or data.tags.has("beam_emitter") or data.tags.has("shockwave_emitter"):
			var em_world: Vector2 = main.grid_to_world(grid_pos) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
			var em_faction: int = main.get_building_faction(main.building_origins.get(grid_pos, grid_pos))
			var em_range: float = (data.attack_range + _watchtower_range_bonus(grid_pos)) * main.GRID_SIZE
			var em_firing: bool = false
			if turret_power_eff > 0.0:
				var em_tw = _emitter_target_world(grid_pos, data, em_world)
				if em_tw != null:
					em_firing = true
					var ta: float = (em_tw - em_world).angle()
					turret_angles[grid_pos] = lerp_angle(float(turret_angles.get(grid_pos, ta)), ta, delta * 8.0)
					_update_barrel_toe_in(grid_pos, data, em_world, em_tw, delta)
			try_fire_special_weapon(grid_pos, data, em_world, float(turret_angles.get(grid_pos, 0.0)), em_faction, turret_power_eff, em_range, em_firing, delta)
			continue

		if turret_power_eff <= 0.0:
			continue

		# Spritz water firefighting: when loaded with water it prioritises
		# dousing friendly fires over shooting enemies. If a friendly fire is in
		# range it handles aiming/spraying here and skips normal targeting.
		if block_id == &"spritz" and _spritz_firefight(grid_pos, data, delta):
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
		var target_type_str: String = String(target_info["target_type"])
		var shoot_at_unit: bool = target_type_str == "unit"
		var shoot_at_held: bool = target_type_str == "held"

		# Resolve live target references
		var nearest_unit: Node2D = null
		var nearest_bldg := Vector2i(-1, -1)
		var held_target_anchor := Vector2i(-9999, -9999)
		var held_target_depth: int = 0
		if shoot_at_unit:
			var target_id: int = target_info["target_id"]
			var obj = instance_from_id(target_id)
			if obj != null and is_instance_valid(obj) and not obj.is_dead:
				nearest_unit = obj
				target_world = nearest_unit.position  # Use live position
			else:
				continue  # Target died since scan
		elif shoot_at_held:
			held_target_anchor = target_info.get("target_anchor", Vector2i(-9999, -9999))
			held_target_depth = int(target_info.get("target_depth", 0))
			# Confirm the layer the worker tagged is still in the chain
			# — payload may have been dropped or destroyed since.
			var bsys_h = get_node_or_null("/root/Main/BuildingSystem")
			if bsys_h == null or not bsys_h.has_method("get_held_payload_at_depth"):
				continue
			var live_layer: Dictionary = bsys_h.get_held_payload_at_depth(held_target_anchor, held_target_depth)
			if live_layer.is_empty():
				continue
			# Track the layer's live world position (each level walks
			# the crane chain through `held_entity_world_at_depth`).
			target_world = bsys_h.held_entity_world_at_depth(held_target_anchor, held_target_depth)
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
		elif shoot_at_held:
			# Held entity faction = its holder's faction (the cargo
			# inherits side from the crane carrying it).
			target_faction = main.get_building_faction(held_target_anchor)
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
		# Includes any active watchtower bonus.
		var live_range_tiles: float = data.attack_range + _watchtower_range_bonus(grid_pos)
		var live_range_px: float = live_range_tiles * main.GRID_SIZE
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

		# (fume / flame / lightning emitters are handled earlier via the shared
		# try_fire_special_weapon dispatch — they never reach the projectile path.)

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

		# --- Ammo: read + consume one shot's worth via the shared profile helper
		# (the same path the manual-control fire uses, so ballistics stay in one
		# place). No ammo_types or can't afford → can't fire.
		var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		var profile: Dictionary = read_ammo_profile(data, _logistics, anchor)
		if not profile["found"]:
			continue
		var fire_reload_mult: float = float(profile["reload_mult"])

		# Fire! Apply any active booster (Fire Rate boost from consumed
		# fluid/item) by dividing the cooldown — 250% fire rate cuts
		# reload to 40% of the base value.
		var booster_mult: float = _get_active_booster_multiplier(grid_pos, data, "Fire Rate")
		var full_cooldown: float = (data.attack_speed * fire_reload_mult) / maxf(booster_mult, 0.0001)
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

		# Apply turret `inaccuracy` (miss-target angle) as a one-time rotation on
		# the aim direction for THIS shot — independent of the per-pellet
		# bullet_spread cone the emitter applies. 0 = always hits where aimed.
		# Bullets travel along the aim axis (not fire_pos→target) so a laterally
		# offset multi-barrel muzzle doesn't veer its rounds back to centre.
		var base_shot_dir: Vector2 = aim_dir
		# Lead a MOVING unit target so non-homing bullets connect (port of
		# Mindustry's Predict.intercept). Skipped for homing/liquid ammo and for
		# building / held targets (they don't move) and stationary units.
		if shoot_at_unit and nearest_unit != null \
				and float(profile["homing"]) <= 0.0 and not bool(profile.get("liquid", false)) \
				and float(profile["speed"]) > 0.0 and "velocity" in nearest_unit:
			var tvel: Vector2 = nearest_unit.velocity
			if tvel.length_squared() > 1.0:
				var aim_pt: Vector2 = _intercept_point(fire_pos, nearest_unit.position, tvel, float(profile["speed"]))
				var lead_dir: Vector2 = aim_pt - fire_pos
				if lead_dir.length_squared() > 0.0001:
					base_shot_dir = lead_dir.normalized()
		if data.inaccuracy > 0.0:
			var miss_deg: float = randf_range(-data.inaccuracy, data.inaccuracy)
			base_shot_dir = base_shot_dir.rotated(deg_to_rad(miss_deg))
		# Bullets fly to the end of the turret's range; ammo `range_bonus` is
		# intentionally ignored so the visible travel matches the turret stat.
		var effective_range_tiles: float = data.attack_range + _watchtower_range_bonus(grid_pos)
		var shot_distance: float = effective_range_tiles * main.GRID_SIZE
		# Pick this shot's target ref / type / damage modifier, then hand off to
		# the shared pellet emitter — the same path the manual-control fire uses,
		# so spread, liquid ballistics and projectile extras live in one place.
		var tgt_ref: Variant = nearest_bldg
		var tgt_type: String = "building"
		var tgt_damage: float = float(profile["damage"]) * float(profile["bldg_mult"])
		if shoot_at_unit:
			tgt_ref = nearest_unit
			tgt_type = "enemy"
			tgt_damage = float(profile["damage"]) * float(profile["unit_mult"])
		elif shoot_at_held:
			# Held entity at a SPECIFIC layer of the cargo chain — target_ref
			# carries the holding crane's anchor + depth so damage routes only
			# to that layer.
			tgt_ref = {"anchor": held_target_anchor, "depth": held_target_depth}
			tgt_type = "held"
			tgt_damage = float(profile["damage"]) * float(profile["unit_mult"])
		emit_fire_pellets(fire_pos, base_shot_dir.angle(), shot_distance, shot_distance, profile, tgt_ref, tgt_type, tgt_damage, turret_faction)
		# Muzzle flame cone (Flarecaster) — emitted once per shot along the aim axis.
		# (The Mindustry shoot flash now lives INSIDE emit_fire_pellets.)
		if bool(profile["muzzle_flame"]):
			spawn_muzzle_flame(fire_pos, base_shot_dir.angle(), -1.0, _FLAME_COUNT, 1.0, float(profile["flame_cone_width_bonus_degrees"]) * 0.5)


## Unified dispatch for the special "emitter" weapons (fume / flame / lightning)
## that don't fire standard projectiles. BOTH the auto-fire loop and the manual-
## control loop route through this, so registering a new emitter type is a
## one-line change here instead of two divergent copies (the bug that left the
## Arc dead under manual control). `firing` = whether the weapon should actively
## shoot this frame (auto: a valid in-range target exists; manual: the fire
## button is held). `aim_angle` is where to point, `range_px` the reach. Returns
## true when `data` is a special weapon (handled); false → caller falls back to
## the projectile path.
## Records a Spritz slag/petroleum hit on a unit and, when BOTH fluids have
## struck it within the mark window, doubles the slag's effects — an extra
## slag-damage hit plus another Burning stack.
func _spritz_on_hit(unit, proj) -> void:
	var aid: StringName = StringName(proj.get("ammo_id", &""))
	if aid != &"mat_slag" and aid != &"mat_petroleum":
		return
	if unit == null or not is_instance_valid(unit):
		return
	var uid: int = unit.get_instance_id()
	var m: Dictionary = _spritz_marks.get(uid, {})
	m[aid] = SPRITZ_MARK_WINDOW
	var other: StringName = &"mat_petroleum" if aid == &"mat_slag" else &"mat_slag"
	if float(m.get(other, 0.0)) > 0.0:
		# Pairing complete — double the slag's effects on this unit.
		if unit.has_method("take_damage"):
			unit.take_damage(SPRITZ_SLAG_DAMAGE)
		var burn = Registry.get_status_effect(&"burning")
		if burn != null and unit.has_method("apply_status_effect"):
			unit.apply_status_effect(burn)
		# Consume the pairing so it only re-fires on fresh hits of both fluids.
		m.erase(&"mat_slag")
		m.erase(&"mat_petroleum")
	if m.is_empty():
		_spritz_marks.erase(uid)
	else:
		_spritz_marks[uid] = m


## Ages out the slag/petroleum combo marks and drops dead units.
func _tick_spritz_marks(delta: float) -> void:
	if _spritz_marks.is_empty():
		return
	var dead: Array = []
	for uid in _spritz_marks:
		var m: Dictionary = _spritz_marks[uid]
		for k in m.keys():
			m[k] = float(m[k]) - delta
			if float(m[k]) <= 0.0:
				m.erase(k)
		if m.is_empty():
			dead.append(uid)
	for uid in dead:
		_spritz_marks.erase(uid)


## Water-Spritz firefighting. While loaded with water, the turret prioritises
## dousing fires of its OWN faction (a LUMINA Spritz puts out LUMINA fires and
## ignores enemy ones; an enemy Spritz does the opposite). Covers both burning
## buildings (FireSystem) and burning units. Returns true if a friendly fire is
## in range — the caller then skips normal enemy targeting this frame.
func _spritz_firefight(grid_pos: Vector2i, data, delta: float) -> bool:
	if _logistics == null:
		return false
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	# Only fights fires while it actually has water loaded.
	var st: Dictionary = _logistics.block_storage.get(anchor, {})
	var fluids: Dictionary = st.get("fluids", {})
	if float(fluids.get(&"mat_water", 0.0)) < 1.0:
		return false
	var my_faction: int = main.get_building_faction(anchor)
	var gs: float = float(main.GRID_SIZE)
	var gsz: Vector2i = data.grid_size
	var turret_world: Vector2 = main.grid_to_world(anchor) + Vector2(float(gsz.x), float(gsz.y)) * gs * 0.5
	var range_px: float = (data.attack_range + _watchtower_range_bonus(grid_pos)) * gs

	var best_pos := Vector2.ZERO
	var best_d := INF
	var best: Dictionary = {}
	# Burning buildings of my faction.
	var fire_sys = _fire_sys_ref()
	if fire_sys != null and fire_sys.has_method("burning_anchors"):
		for fa in fire_sys.burning_anchors():
			if main.get_building_faction(fa) != my_faction:
				continue
			var fbd = Registry.get_block(main.placed_buildings.get(fa, &""))
			var fgsz: Vector2i = fbd.grid_size if fbd else Vector2i.ONE
			var fpos: Vector2 = main.grid_to_world(fa) + Vector2(float(fgsz.x), float(fgsz.y)) * gs * 0.5
			var d: float = turret_world.distance_to(fpos)
			if d <= range_px and d < best_d:
				best_d = d
				best_pos = fpos
				best = {"type": "building", "anchor": fa}
	# Burning units of my faction.
	var um = _unit_mgr_ref()
	if um != null:
		var near: Array = um.get_player_units_in_range(turret_world, range_px) if my_faction == main.Faction.LUMINA else um.get_enemies_in_range(turret_world, range_px)
		for u in near:
			if u == null or not is_instance_valid(u) or u.is_dead:
				continue
			if not (u.has_method("is_burning") and u.is_burning()):
				continue
			var d2: float = turret_world.distance_to(u.position)
			if d2 < best_d:
				best_d = d2
				best_pos = u.position
				best = {"type": "unit", "unit": u}

	if best.is_empty():
		return false

	# Aim at the fire.
	var cur: float = float(turret_angles.get(grid_pos, 0.0))
	var ta: float = (best_pos - turret_world).angle()
	turret_angles[grid_pos] = lerp_angle(cur, ta, delta * 8.0)

	# Spray when the cooldown is ready and water is available.
	if float(turret_cooldowns.get(grid_pos, 0.0)) <= 0.0:
		var profile: Dictionary = read_ammo_profile(data, _logistics, anchor)
		if profile["found"] and StringName(profile.get("ammo_id", &"")) == &"mat_water":
			turret_cooldowns[grid_pos] = data.attack_speed * float(profile["reload_mult"])
			var aim_dir := Vector2.from_angle(turret_angles[grid_pos])
			var barrel_len: float = gs * 0.4
			if data.turret_head_sprite:
				var hts: Vector2 = data.turret_head_sprite.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
				barrel_len = maxf(hts.y - 14.0 * main.SPRITE_SCALE_FACTOR, 0.0)
			# Visual douse spray with ZERO damage — it never harms the friendly
			# building / unit it's putting out.
			# Firefighter water spray: no muzzle flash (with_shoot_fx = false).
			emit_fire_pellets(turret_world + aim_dir * barrel_len, turret_angles[grid_pos], best_d, range_px, profile, null, "none", 0.0, my_faction, false)
			# Put the fire out.
			if best.get("type") == "building":
				if fire_sys != null:
					fire_sys.extinguish_building(best["anchor"])
			else:
				var u2 = best.get("unit")
				if u2 != null and is_instance_valid(u2) and u2.has_method("douse"):
					u2.douse()
	return true


func try_fire_special_weapon(grid_pos: Vector2i, data, turret_world: Vector2, aim_angle: float, faction: int, power_eff: float, range_px: float, firing: bool, delta: float) -> bool:
	if data.tags.has("fume_emitter"):
		if firing:
			_update_fume_emitter(grid_pos, data, turret_world, power_eff, delta)
		return true
	if data.tags.has("flame_emitter"):
		if firing:
			_update_flame_emitter(grid_pos, data, turret_world, aim_angle, range_px, faction, power_eff, delta)
		return true
	if data.tags.has("lightning_emitter"):
		_tick_arc(grid_pos, data, turret_world, aim_angle, faction, range_px, firing, delta)
		return true
	if data.tags.has("beam_emitter"):
		_update_beam_emitter(grid_pos, data, turret_world, aim_angle, range_px, faction, power_eff, firing, delta)
		return true
	if data.tags.has("shockwave_emitter"):
		_update_blaster(grid_pos, data, turret_world, aim_angle, range_px, faction, power_eff, firing, delta)
		return true
	return false


## Lightweight target resolution for emitter weapons: returns the live world
## position of the turret's current opposing target (from the worker snapshot),
## or null if none is valid / in range. The worker already filtered by faction,
## so this only re-checks liveness + range — enough to aim, without duplicating
## the projectile path's full faction-guard gauntlet.
## Port of Mindustry's Predict.intercept: the point a shooter at `src` should aim
## at to hit a target at `dst` moving at `dst_vel` (px/sec) with a projectile of
## speed `v` (px/sec). Solves a*t² + b*t + c = 0 for the smallest positive time
## of flight, then returns the target's position at that time. Falls back to
## `dst` (no lead) when there's no real positive solution (target outrunning the
## bullet, etc.).
func _intercept_point(src: Vector2, dst: Vector2, dst_vel: Vector2, v: float) -> Vector2:
	if v <= 0.0:
		return dst
	var tx: float = dst.x - src.x
	var ty: float = dst.y - src.y
	var a: float = dst_vel.x * dst_vel.x + dst_vel.y * dst_vel.y - v * v
	var b: float = 2.0 * (dst_vel.x * tx + dst_vel.y * ty)
	var c: float = tx * tx + ty * ty
	var t: float = -1.0
	if absf(a) < 0.0001:
		if absf(b) > 0.0001:
			t = -c / b
	else:
		var disc: float = b * b - 4.0 * a * c
		if disc >= 0.0:
			var sq: float = sqrt(disc)
			var t1: float = (-b - sq) / (2.0 * a)
			var t2: float = (-b + sq) / (2.0 * a)
			if t1 > 0.0 and t2 > 0.0:
				t = minf(t1, t2)
			elif t1 > 0.0:
				t = t1
			elif t2 > 0.0:
				t = t2
	if t <= 0.0:
		return dst
	return dst + dst_vel * t


func _emitter_target_world(grid_pos: Vector2i, data, turret_world: Vector2):
	if not _turret_targets.has(grid_pos):
		return null
	var ti: Dictionary = _turret_targets[grid_pos]
	var ttype: String = String(ti.get("target_type", ""))
	var tw = ti.get("target_pos", null)
	if ttype == "unit":
		var obj = instance_from_id(int(ti.get("target_id", 0)))
		if obj == null or not is_instance_valid(obj) or obj.is_dead:
			return null
		tw = obj.position
	elif ttype == "building":
		# `units_only` emitters (the Blaster) ignore building targets entirely —
		# they only ever aim at / fire on units.
		if data.tags.has("units_only"):
			return null
		var b: Vector2i = ti.get("target_bldg", Vector2i(-1, -1))
		if not main.placed_buildings.has(b):
			return null
		tw = main.grid_to_world(b) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
	if tw == null:
		return null
	var rng: float = (data.attack_range + _watchtower_range_bonus(grid_pos) + _flame_range_bonus_for_targeting(data, grid_pos)) * main.GRID_SIZE
	if turret_world.distance_to(tw) > rng:
		return null
	return tw


## Arc per-frame tick: ramps the continuous-fire charge up while firing / down
## while idle, then looses a burst of chaining bolts once the charge-scaled
## reload elapses. The cooldown is decremented by the caller (auto loop / manual
## loop each tick it), so this only reads + resets it.
func _tick_arc(grid_pos: Vector2i, data, turret_world: Vector2, aim_angle: float, faction: int, range_px: float, firing: bool, delta: float) -> void:
	var charge: float = float(arc_charge.get(grid_pos, 0.0))
	if firing:
		charge = minf(charge + delta / ARC_RAMP_UP_TIME, 1.0)
	else:
		charge = maxf(charge - delta / ARC_RAMP_DOWN_TIME, 0.0)
	arc_charge[grid_pos] = charge

	if not firing or float(turret_cooldowns.get(grid_pos, 0.0)) > 0.0:
		return
	# Powered ammo gate — the Arc's ammo draws electricity, so this only
	# succeeds while the network is supplying power. Damage from the profile.
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var profile: Dictionary = read_ammo_profile(data, _logistics, anchor)
	if not profile["found"]:
		return
	turret_cooldowns[grid_pos] = lerpf(ARC_MAX_RELOAD, ARC_MIN_RELOAD, charge)

	if turret_barrel_recoil.has(grid_pos):
		var brc: Array = turret_barrel_recoil[grid_pos]
		if brc.size() > 0:
			brc[0] = 1.0

	var aim_dir := Vector2.from_angle(aim_angle)
	var barrel_length: float = main.GRID_SIZE * 0.4
	if data.turret_head_sprite:
		var head_tex_size: Vector2 = data.turret_head_sprite.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
		barrel_length = maxf(head_tex_size.y - 14.0 * main.SPRITE_SCALE_FACTOR, 0.0)
	var muzzle: Vector2 = turret_world + aim_dir * barrel_length
	# Loose several bolts per shot, fanned around the aim (Mindustry arc look).
	var dmg: float = float(profile["damage"])
	for i in range(ARC_BOLTS_PER_SHOT):
		var fan: float = 0.0
		if ARC_BOLTS_PER_SHOT > 1:
			fan = deg_to_rad((float(i) - float(ARC_BOLTS_PER_SHOT - 1) * 0.5) * ARC_BOLT_FAN_DEG)
		_fire_arc_lightning(muzzle, aim_angle + fan, dmg, range_px, faction)


## Spawns one chaining lightning bolt — a port of Mindustry's Lightning.create
## (entities/Lightning.java). Steps along ARC_SEGMENTS vertices but never strays
## past `range_px` from the muzzle (the bolt only reaches the turret's range):
## at each vertex it damages nearby ground enemies (flying units are immune —
## collidesAir=false) and any opposing building on the cell, then chains to the
## furthest un-hit enemy within reach (and within range) or wanders forward with
## slight random deviation. Builds the jagged polyline used for the visual.
func _fire_arc_lightning(start: Vector2, angle: float, dmg: float, range_px: float, faction: int) -> void:
	var unit_mgr = _unit_mgr_ref()
	var hit_range: float = float(main.GRID_SIZE) * 1.2
	var step: float = hit_range * 0.65
	var max_reach: float = maxf(range_px, hit_range)  # bolt never extends past the turret's range
	var enemy_faction: int = main.Faction.FEROX if faction == main.Faction.LUMINA else main.Faction.LUMINA
	var x: float = start.x
	var y: float = start.y
	var rot: float = angle
	var points := PackedVector2Array()
	points.append(start)
	var hit_units := {}
	var hit_bldgs := {}
	var chain_count: int = 0

	for _i in range(ARC_SEGMENTS):
		var p := Vector2(x, y)
		# Stop once the bolt has reached the edge of the turret's range.
		if start.distance_to(p) >= max_reach:
			break
		# Damage ground enemies clustered at this vertex.
		var near: Array = []
		if unit_mgr:
			near = unit_mgr.get_player_units_in_range(p, hit_range * 0.5) if faction == main.Faction.FEROX else unit_mgr.get_enemies_in_range(p, hit_range * 0.5)
		for u in near:
			if not is_instance_valid(u) or u.is_dead:
				continue
			var uid: int = u.get_instance_id()
			if hit_units.has(uid):
				continue
			var ml: int = u.data.movement_layer if ("data" in u and u.data) else 0
			if ml == 3:  # flying — immune (collidesAir = false)
				continue
			hit_units[uid] = true
			u.take_damage(dmg)
		# Damage an opposing building sitting on this vertex (reduced, ×0.25).
		var g: Vector2i = main.world_to_grid(p)
		if main.placed_buildings.has(g):
			var anc: Vector2i = main.building_origins.get(g, g)
			if not hit_bldgs.has(anc) and main.get_building_faction(anc) == enemy_faction:
				hit_bldgs[anc] = true
				main.damage_building(anc, dmg * ARC_BLDG_DAMAGE_MULT)
		# Pick the next vertex: chain to the furthest un-hit enemy within reach
		# (and within range), else wander forward with a little random deviation.
		var chain_to: Node2D = null
		if chain_count < ARC_MAX_CHAIN and unit_mgr:
			var cand: Array = unit_mgr.get_player_units_in_range(p, hit_range) if faction == main.Faction.FEROX else unit_mgr.get_enemies_in_range(p, hit_range)
			var best_d: float = -1.0
			for u in cand:
				if not is_instance_valid(u) or u.is_dead:
					continue
				if hit_units.has(u.get_instance_id()):
					continue
				var ml2: int = u.data.movement_layer if ("data" in u and u.data) else 0
				if ml2 == 3:
					continue
				if start.distance_to(u.position) > max_reach:
					continue
				var d: float = p.distance_to(u.position)
				if d > best_d:
					best_d = d
					chain_to = u
		if chain_to != null:
			chain_count += 1
			x = chain_to.position.x + randf_range(-3.0, 3.0)
			y = chain_to.position.y + randf_range(-3.0, 3.0)
		else:
			rot += deg_to_rad(randf_range(-20.0, 20.0))
			x += cos(rot) * step + randf_range(-3.0, 3.0)
			y += sin(rot) * step + randf_range(-3.0, 3.0)
		# Clamp the new vertex onto the range circle so the bolt can't overshoot.
		var npos := Vector2(x, y)
		if start.distance_to(npos) > max_reach:
			npos = start + (npos - start).normalized() * max_reach
			x = npos.x
			y = npos.y
		points.append(npos)

	_lightning_bolts.append({
		"points": points,
		"age": 0.0,
		"lifetime": ARC_BOLT_LIFETIME,
		"color": ARC_COLOR,
	})


## Ages out finished lightning bolts. Visual only — damage was already applied
## at spawn time in _fire_arc_lightning.
func _update_lightning_bolts(delta: float) -> void:
	if _lightning_bolts.is_empty():
		return
	var keep: Array = []
	for bolt in _lightning_bolts:
		bolt["age"] = float(bolt["age"]) + delta
		if float(bolt["age"]) < float(bolt["lifetime"]):
			keep.append(bolt)
	_lightning_bolts = keep


## Returns the first AmmoType resource configured on `data`, or null.
func _first_ammo(data) -> AmmoType:
	for a in data.ammo_types:
		if a is AmmoType:
			return a
	return null


## Eclipse beam tick. Drives a 3-phase per-anchor state machine: idle →
## (pay 2 oxygen + 2 hydrogen, on a live target) → firing the beam for
## BEAM_FIRE_TIME → cooldown for BEAM_COOLDOWN_TIME → idle. While firing it
## carves a straight beam from the muzzle out to range, damaging the first
## opposing building it meets (and stopping there) plus every opposing unit the
## beam line passes through. Damage is dps × delta so it's frame-rate stable.
## Brownout (power_eff 0) pauses the burst — the timer only advances with power.
func _update_beam_emitter(grid_pos: Vector2i, data, turret_world: Vector2, aim: float, range_px: float, faction: int, power_eff: float, firing: bool, delta: float) -> void:
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var st: Dictionary = beam_states.get(anchor, {
		"phase": 0, "timer": 0.0, "start": Vector2.ZERO, "end": Vector2.ZERO, "active": false,
	})
	var phase: int = int(st["phase"])
	var timer: float = float(st["timer"])
	st["active"] = false
	match phase:
		0:  # idle — kick off a new burst when a target is in range and ammo is paid
			if firing and power_eff > 0.0:
				var ammo: AmmoType = _first_ammo(data)
				if ammo != null and _consume_ammo_with_extras(_logistics, anchor, ammo):
					phase = 1
					timer = BEAM_FIRE_TIME
		1:  # firing — beam runs the full duration regardless of target presence
			timer -= delta * maxf(power_eff, 0.0)
			if power_eff > 0.0:
				var ammo2: AmmoType = _first_ammo(data)
				var dps: float = ammo2.damage if ammo2 != null else 0.0
				var muzzle: Vector2 = turret_world + Vector2.from_angle(aim) * (float(main.GRID_SIZE) * 0.5)
				st["start"] = muzzle
				st["end"] = _beam_hit(muzzle, aim, range_px, faction, dps * delta)
				st["active"] = true
			if timer <= 0.0:
				phase = 2
				timer = BEAM_COOLDOWN_TIME
		2:  # cooldown — locked out, ticks down even with no target
			timer -= delta
			if timer <= 0.0:
				phase = 0
				timer = 0.0
	st["phase"] = phase
	st["timer"] = timer
	beam_states[anchor] = st


## Applies one frame of beam damage from `muzzle` along `aim` out to the full
## `range_px` (the beam never stops short — it carves all the way out) and returns
## the range-end point. `dmg` is the per-frame damage (dps × delta). Damages every
## opposing building under the beam line plus every opposing unit it overlaps.
func _beam_hit(muzzle: Vector2, aim: float, range_px: float, faction: int, dmg: float) -> Vector2:
	var dir := Vector2.from_angle(aim)
	var gs: float = float(main.GRID_SIZE)
	var enemy_faction: int = main.Faction.FEROX if faction == main.Faction.LUMINA else main.Faction.LUMINA
	var endp: Vector2 = muzzle + dir * range_px
	# Walk the full beam and damage EVERY opposing building it passes over (the
	# beam punches straight through to max range — blocks just take damage).
	var dist: float = gs * 0.5
	var seen: Dictionary = {}
	while dist <= range_px:
		var p: Vector2 = muzzle + dir * dist
		var cell: Vector2i = main.world_to_grid(p)
		if main.placed_buildings.has(cell):
			var anc: Vector2i = main.building_origins.get(cell, cell)
			if not seen.has(anc) and main.get_building_faction(anc) == enemy_faction:
				seen[anc] = true
				main.damage_building(anc, dmg)
		dist += gs * 0.5
	# Damage every opposing unit whose body overlaps the muzzle→endp segment.
	var unit_mgr := _unit_mgr_ref()
	if unit_mgr != null:
		var src_team: int = UnitData.Team.PLAYER if faction == main.Faction.LUMINA else UnitData.Team.ENEMY
		for lst in [unit_mgr.enemies, unit_mgr.player_units]:
			for u in lst:
				if not is_instance_valid(u) or u.is_dead:
					continue
				if "team" in u and u.team == src_team:
					continue
				var cp: Vector2 = Geometry2D.get_closest_point_to_segment(u.position, muzzle, endp)
				if u.position.distance_to(cp) <= BEAM_HALF_WIDTH + u.unit_size:
					u.take_damage(dmg)
	return endp


## Blaster tick. A 2-phase per-anchor state machine: charging (winds up while it
## has a live target + power) → on a full charge, pays 3 hydrogen and emits one
## quarter-circle shockwave → cooldown (`attack_speed`) → charging. Charge
## holds (doesn't decay) when the target is briefly lost, and parks at full if
## the turret is charged but can't afford ammo, so it looses the instant fuel
## arrives. The actual sweep + knockback live in _update_shockwaves.
func _update_blaster(grid_pos: Vector2i, data, turret_world: Vector2, aim: float, range_px: float, faction: int, power_eff: float, firing: bool, delta: float) -> void:
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var st: Dictionary = blaster_states.get(anchor, {
		"phase": 0, "charge": 0.0, "cooldown": 0.0, "draw_charge": 0.0, "muzzle": Vector2.ZERO,
	})
	var phase: int = int(st["phase"])
	var charge: float = float(st["charge"])
	var cooldown: float = float(st["cooldown"])
	# Timing is data-driven: `charge_time` = wind-up, `attack_speed` = the
	# post-shot cooldown. Both tunable from the block's .tres.
	var charge_time: float = maxf(data.charge_time, 0.0)
	var cd_time: float = maxf(data.attack_speed, 0.0)
	# Use the head's ACTUAL drawn angle (the per-barrel toe-in angle the head
	# sprite is rotated to), not the chassis aim — otherwise the glow/wave lag
	# the head while it's rotating onto a target.
	var head_angle: float = aim
	var bangs: Array = turret_barrel_angles.get(grid_pos, [])
	if bangs.size() > 0:
		head_angle = float(bangs[0])
	# Charge glow sits at the muzzle TIP — derive the barrel length from the head
	# sprite the same way the projectile path does, so it's at the end of the
	# head rather than the turret centre.
	var barrel_length: float = float(main.GRID_SIZE) * 0.4
	if data.turret_head_sprite:
		var head_tex_size: Vector2 = data.turret_head_sprite.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
		barrel_length = maxf(head_tex_size.y - 14.0 * main.SPRITE_SCALE_FACTOR, 0.0)
	var muzzle: Vector2 = turret_world + Vector2.from_angle(head_angle) * barrel_length
	match phase:
		0:  # charging — only winds up with a live target and power
			if firing and power_eff > 0.0:
				charge = minf(charge + delta * power_eff, charge_time)
				if charge >= charge_time:
					var ammo: AmmoType = _first_ammo(data)
					if ammo != null and _consume_ammo_with_extras(_logistics, anchor, ammo):
						var dps: float = ammo.damage
						_spawn_shockwave(muzzle, head_angle, range_px, faction, dps)
						charge = 0.0
						cooldown = cd_time
						phase = 1
		1:  # cooldown — locked out regardless of target
			cooldown -= delta
			if cooldown <= 0.0:
				cooldown = 0.0
				phase = 0
	st["phase"] = phase
	st["charge"] = charge
	st["cooldown"] = cooldown
	st["draw_charge"] = (charge / charge_time if charge_time > 0.0 else 0.0) if phase == 0 else 0.0
	st["muzzle"] = muzzle
	blaster_states[anchor] = st


## Spawns one expanding quarter-circle shockwave from `origin`, facing `aim`, that
## sweeps out to `range_px`. `dps` is its contact damage per second.
func _spawn_shockwave(origin: Vector2, aim: float, range_px: float, faction: int, dps: float) -> void:
	shockwaves.append({
		"origin": origin,
		"aim": aim,
		"radius": 0.0,
		"max_radius": range_px,
		"speed": range_px / maxf(SHOCKWAVE_EXPAND_TIME, 0.0001),
		"faction": faction,
		"dps": dps,
		"hit": {},
	})


## Expands every active shockwave, applies contact damage + a one-time radial
## knockback to opposing units the ring front sweeps over (within its ±45° arc),
## and culls waves that have reached full radius. Knockback reuses _apply_knockback
## from the wave origin so units are shoved straight outward.
func _update_shockwaves(delta: float) -> void:
	if shockwaves.is_empty():
		return
	var unit_mgr := _unit_mgr_ref()
	var knock: float = float(main.GRID_SIZE) * SHOCKWAVE_KNOCKBACK_TILES
	for i in range(shockwaves.size() - 1, -1, -1):
		var sw: Dictionary = shockwaves[i]
		sw["radius"] = float(sw["radius"]) + float(sw["speed"]) * delta
		var radius: float = float(sw["radius"])
		if unit_mgr != null:
			var origin: Vector2 = sw["origin"]
			var aim: float = float(sw["aim"])
			var src_team: int = UnitData.Team.PLAYER if int(sw["faction"]) == main.Faction.LUMINA else UnitData.Team.ENEMY
			var hit: Dictionary = sw["hit"]
			for lst in [unit_mgr.enemies, unit_mgr.player_units]:
				for u in lst:
					if not is_instance_valid(u) or u.is_dead:
						continue
					if "team" in u and u.team == src_team:
						continue
					var to: Vector2 = u.position - origin
					var d: float = to.length()
					# Inside the quarter-circle arc?
					if d > 1.0 and absf(wrapf(to.angle() - aim, -PI, PI)) > SHOCKWAVE_HALF_ANGLE:
						continue
					# In contact when the expanding ring front overlaps the body.
					if absf(d - radius) > SHOCKWAVE_BAND + u.unit_size:
						continue
					u.take_damage(float(sw["dps"]) * delta)
					var uid: int = u.get_instance_id()
					if not hit.has(uid):
						hit[uid] = true
						_apply_knockback(u, origin, knock)
		if radius >= float(sw["max_radius"]):
			shockwaves.remove_at(i)


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

## True when the player is doing something that should NOT also fire
## the drone's manual shoot / heal beam — even though LMB is held.
## Covers the cases the spec lists:
##   1. Unit-select mode (UnitManager.unit_mode_active)
##   2. Drag-to-deposit from the drone's own inventory (drone._dragging_inventory)
##   3. A pending block link (BuildingSystem.link_source set)
##   3b. Crane link (BuildingSystem._crane_link_anchor set)
##   4. A world menu / storage panel open (WorldUISystem flags)
##   5. Cursor over a DERELICT block (single-click capture)
func _player_action_blocks_drone(drone: Node) -> bool:
	# (2) inventory drag held on the drone itself.
	if drone and "_dragging_inventory" in drone and bool(drone._dragging_inventory):
		return true
	# (1) Unit mode.
	var unit_mgr = _unit_mgr_ref()
	if unit_mgr and "unit_mode_active" in unit_mgr and bool(unit_mgr.unit_mode_active):
		return true
	var bs = _building_sys_ref()
	if bs != null:
		# (3) Block link pending.
		if "link_source" in bs and bs.link_source != Vector2i(-1, -1):
			return true
		# (3b) Crane link pending.
		if "_crane_link_anchor" in bs and bs._crane_link_anchor != Vector2i(-1, -1):
			return true
		# (4) Crane-filter / sorter / etc. world menus that the
		# BuildingSystem caches a flag for.
		if "_crane_filter_menu_open" in bs and bool(bs._crane_filter_menu_open):
			return true
	# (4) World menu / specialised block menu open.
	var world_ui = get_node_or_null("/root/Main/WorldUISystem")
	if world_ui != null:
		if "world_menu_open" in world_ui and bool(world_ui.world_menu_open):
			return true
		if "storage_panel_open" in world_ui and bool(world_ui.storage_panel_open):
			return true
	# (5) Hovering a derelict block — a single click captures it, and
	# we don't want the same click to also kick off a tracer at the
	# block / past it.
	if main != null and drone != null:
		var mouse_world: Vector2 = drone.get_global_mouse_position()
		var grid_pos: Vector2i = main.world_to_grid(mouse_world)
		if main.placed_buildings.has(grid_pos):
			var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
			if main.has_method("get_building_faction") \
					and main.get_building_faction(anchor) == main.Faction.DERELICT:
				return true
	return false


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
	# (with no GUI hover / no building selected). Outside that window —
	# AND only while we're in HEAL mode — the drone falls through to AI
	# auto-shoot. The two modes complement each other: in heal mode the
	# player drives the heal beam and the AI handles shooting; in shoot
	# mode the player drives the gun and the AI handles healing.
	var heal_active: bool = "heal_mode" in drone and bool(drone.heal_mode)
	var manual_shoot_active: bool = false
	if not heal_active:
		var lmb: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		if main.selected_building != &"":
			lmb = false
		if get_viewport().gui_get_hovered_control() != null:
			lmb = false
		if _player_action_blocks_drone(drone):
			lmb = false
		manual_shoot_active = lmb
	drone_is_shooting = manual_shoot_active

	# Branch:
	#  - Manual shoot active (always shoot mode + LMB) → fire from cursor
	#    aim at the bottom of this function.
	#  - Otherwise, AI auto-shoot only runs in heal mode (player is busy
	#    healing, AI handles enemies). In shoot mode without LMB held the
	#    drone simply holds fire — no auto-shoot, since manual shoot is
	#    the player's job in this mode.
	if not manual_shoot_active and not heal_active:
		return

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


## Called by enemy_unit.gd when a FEROX unit wants to shoot a LUMINA
## unit (in-flight engagement, not the building-targeting path).
func enemy_attack_unit(enemy: Node2D, target_unit: Node2D, damage: float, proj_speed: float, proj_color: Color) -> bool:
	if target_unit == null or not is_instance_valid(target_unit):
		return false
	_spawn_projectile(
		enemy.position,
		target_unit,
		target_unit.position,
		"enemy",
		proj_speed,
		damage,
		proj_color,
		"enemy",
		false,
		0.0,
		main.Faction.FEROX,
	)
	return true


## Called by enemy_unit.gd when a ranged enemy wants to shoot.
## Returns true if a projectile was spawned.
func enemy_ranged_attack(enemy: Node2D, target_grid_pos: Vector2i, damage: float, proj_speed: float, proj_color: Color) -> bool:
	var target_world = main.grid_to_world(target_grid_pos) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)

	# IMPORTANT: pass source_faction = FEROX. Without this the spawn
	# defaults to LUMINA, which makes every other FEROX unit along
	# the bullet's flight path an "opposing-team" target — so the
	# shooter chips its own squad — and the bullet would even hit
	# FEROX walls on the way out. The bullet must be tagged as
	# enemy-sourced for the in-path collision + wall friendly-fire
	# guard to skip same-faction stuff.
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
		main.Faction.FEROX,
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
		"front_color": extras.get("front_color", color),
		"back_color": extras.get("back_color", color.darkened(0.35)),
		"visual_width": float(extras.get("visual_width", 0.0)),
		"visual_height": float(extras.get("visual_height", 0.0)),
		"shrink_y": float(extras.get("shrink_y", 0.5)),
		"projectile_sprite": extras.get("projectile_sprite", null),
		"collides_air": bool(extras.get("collides_air", true)),
		"collides_ground": bool(extras.get("collides_ground", true)),
		"status": extras.get("status", null),
		"ammo_id": StringName(extras.get("ammo_id", &"")),
		"splash_mult": float(extras.get("splash_mult", 1.0)),
		"shot_id": int(extras.get("shot_id", 0)),
		# Fragmentation: on impact spawn N child orbs (Detonater). Frags
		# themselves carry frag_count 0 so they never chain.
		"frag_count": int(extras.get("frag_count", 0)),
		"frag_damage": float(extras.get("frag_damage", 0.0)),
		"frag_speed": float(extras.get("frag_speed", 250.0)),
		"frag_radius": float(extras.get("frag_radius", 4.0)),
		"frag_range": float(extras.get("frag_range", 160.0)),
		"is_frag": bool(extras.get("is_frag", false)),
		# Liquid bullet (Corrosion): rendered as a fluid orb, decelerates via
		# `drag`, and leaves a puddle splat on despawn.
		"liquid": bool(extras.get("liquid", false)),
		"drag": float(extras.get("drag", 0.0)),
		# Scales the Mindustry-style hit / despawn FX when this bullet ends.
		"impact_scale": float(extras.get("impact_scale", 1.0)),
	}
	var sid: int = int(proj["shot_id"])
	if sid != 0:
		_shot_active[sid] = int(_shot_active.get(sid, 0)) + 1
	projectiles.append(proj)
	# Polish: shoot SFX. Multi-pellet salvos collapse onto a single
	# shot_id so we only play once per salvo (instead of N pellets ×
	# N barrels). Source-keyed so turret / unit / drone shots can use
	# different sounds — `shoot_<source>` falls back to plain `shoot`.
	var asys = main.get_node_or_null("AudioSystem")
	if asys and asys.has_method("play"):
		var play_now: bool = sid == 0 or int(_shot_active.get(sid, 0)) <= 1
		if play_now:
			asys.play("shoot_" + source, start_pos, -2.0)
			asys.play("shoot", start_pos, -6.0, 1.0, 0.05)


## Initial launch speed for a drag-decelerated liquid bullet so that, summed
## over its `lifetime` at ~60 fps, it travels `range_px` before expiring.
## _update_projectiles multiplies speed by (1 - drag) each frame and then
## advances speed/60 px, so the travelled distance is a geometric series:
##   range = v0 * (1/60) * (1 - (1-drag)^N) / drag,   N = lifetime * 60
## Solving for v0 yields the launch speed that lands the blob at max range
## right as its lifetime runs out.
func _liquid_launch_speed(range_px: float, drag: float, lifetime: float) -> float:
	var d: float = clampf(drag, 0.0001, 0.9999)
	var n: float = maxf(lifetime * 60.0, 1.0)
	var reach_factor: float = (1.0 / 60.0) * (1.0 - pow(1.0 - d, n)) / d
	if reach_factor <= 0.0001:
		return range_px / maxf(lifetime, 0.0001)
	return range_px / reach_factor


## Reads the first affordable AmmoType off `bdata`, consuming one shot's worth
## of its resource from `log_ref` at `anchor`, and returns a "fire profile"
## dictionary describing the resulting projectile. Shared by the auto-fire
## (CombatSystem) and manual-control (UnitManager) paths so both behave
## identically — add a new AmmoType-driven field here once and both inherit it.
## Returns a profile with "found" = false when the turret has no ammo_types or
## can't afford any of them (the caller should then skip firing).
func read_ammo_profile(bdata, log_ref, anchor: Vector2i) -> Dictionary:
	var p: Dictionary = {
		"found": false,
		"damage": 0.0,
		"color": bdata.color.lightened(0.3),
		"reload_mult": 1.0,
		"speed": default_projectile_speed,
		"lifetime": 2.0,
		"radius": 4.0,
		"pierce": 0,
		"homing": 0.0,
		"knockback": 0.0,
		"inaccuracy": 0.0,
		"pellets": 1,
		"range_bonus": 0.0,
		"status": null,
		"trail_color": bdata.color.lightened(0.3),
		"front_color": bdata.color.lightened(0.45),
		"back_color": bdata.color.darkened(0.25),
		"visual_width": 0.0,
		"visual_height": 0.0,
		"shrink_y": 0.5,
		"collides_air": true,
		"collides_ground": true,
		"bldg_mult": 1.0,
		"unit_mult": 1.0,
		"aoe": bdata.is_aoe,
		"aoe_radius": bdata.aoe_radius,
		"splash_mult": 1.0,
		"frag_count": 0,
		"frag_damage": 0.0,
		"frag_speed": 250.0,
		"frag_radius": 4.0,
		"frag_range": 160.0,
		"liquid": false,
		"drag": 0.0,
		"velocity_rnd": 0.0,
		"muzzle_flame": false,
		"flame_range_bonus_tiles": 0.0,
		"flame_cone_width_bonus_degrees": 0.0,
		"muzzle_flash_scale": 1.0,
		"muzzle_flash_circles": false,
		"impact_effect_scale": 1.0,
		"ammo_id": &"",
	}
	# A turret with NO ammo_types configured cannot fire (Mindustry-style: every
	# turret must be loaded).
	if bdata.ammo_types.is_empty():
		return p
	for ammo in bdata.ammo_types:
		if ammo == null or not (ammo is AmmoType):
			continue
		var ammo_data: AmmoType = ammo as AmmoType
		# Powered ammo (the Arc) draws electricity instead of an item: it's
		# "loaded" whenever the turret's network is supplying power.
		if ammo_data.is_powered():
			if not _consume_power_ammo(anchor, ammo_data.power_per_shot):
				continue
		elif not _consume_ammo_with_extras(log_ref, anchor, ammo_data):
			continue
		p["damage"] = ammo_data.damage
		p["reload_mult"] = ammo_data.reload_multiplier
		p["color"] = ammo_data.projectile_color
		p["front_color"] = ammo_data.get_projectile_front_color()
		p["back_color"] = ammo_data.get_projectile_back_color()
		p["visual_width"] = ammo_data.projectile_width
		p["visual_height"] = ammo_data.projectile_height
		p["shrink_y"] = ammo_data.projectile_shrink_y
		p["projectile_sprite"] = ammo_data.projectile_sprite
		p["status"] = ammo_data.status_effect
		p["ammo_id"] = ammo_data.item_id
		p["speed"] = ammo_data.projectile_speed
		p["lifetime"] = ammo_data.projectile_lifetime
		p["radius"] = ammo_data.projectile_radius
		p["pierce"] = ammo_data.pierce_count
		p["homing"] = ammo_data.homing
		p["knockback"] = ammo_data.knockback
		# Turret bullet_spread + ammo bullet_spread = visible cone.
		p["inaccuracy"] = ammo_data.bullet_spread + bdata.bullet_spread
		p["pellets"] = ammo_data.projectiles_per_shot
		p["range_bonus"] = ammo_data.range_bonus
		p["trail_color"] = ammo_data.get_trail_color()
		p["collides_air"] = ammo_data.collides_air
		p["collides_ground"] = ammo_data.collides_ground
		p["bldg_mult"] = ammo_data.building_damage_mult
		p["unit_mult"] = ammo_data.unit_damage_mult
		# Splash overrides the block-level AoE if the ammo opts in.
		if ammo_data.is_splash:
			p["aoe"] = true
			p["aoe_radius"] = ammo_data.splash_radius
			p["splash_mult"] = ammo_data.splash_damage_mult
		p["frag_count"] = ammo_data.frag_count
		p["frag_damage"] = ammo_data.frag_damage
		p["frag_speed"] = ammo_data.frag_speed
		p["frag_radius"] = ammo_data.frag_radius
		p["frag_range"] = ammo_data.frag_range
		p["liquid"] = ammo_data.liquid_bullet
		p["drag"] = ammo_data.drag
		p["velocity_rnd"] = ammo_data.velocity_rnd
		p["muzzle_flame"] = ammo_data.muzzle_flame
		p["flame_range_bonus_tiles"] = ammo_data.flame_range_bonus_tiles
		p["flame_cone_width_bonus_degrees"] = ammo_data.flame_cone_width_bonus_degrees
		p["muzzle_flash_scale"] = ammo_data.muzzle_flash_scale
		p["muzzle_flash_circles"] = ammo_data.muzzle_flash_circles
		p["impact_effect_scale"] = ammo_data.impact_effect_scale
		p["found"] = true
		break
	return p


## Spawns one projectile per pellet for a turret shot: applies the AmmoType's
## inaccuracy cone (even-fan distribution), derives the liquid-bullet launch
## speed, and builds the projectile extras from `profile`. Shared by auto-fire
## and manual control so the ballistics stay identical. `aim_angle` is the base
## shot direction (radians), `shot_distance` how far each pellet aims, and
## `max_range` the despawn cap. `damage` is the final per-hit damage (already
## multiplied by the unit/building modifier the caller chose).
func emit_fire_pellets(fire_pos: Vector2, aim_angle: float, shot_distance: float, max_range: float, profile: Dictionary, target_ref, target_type: String, damage: float, source_faction: int, with_shoot_fx: bool = true) -> void:
	var speed: float = float(profile["speed"])
	var drag: float = float(profile["drag"])
	var lifetime: float = float(profile["lifetime"])
	# Liquid bullets decelerate via `drag`; derive the launch speed so the blob
	# lobs the full range and expires at the end of its arc instead of stalling.
	if bool(profile["liquid"]) and drag > 0.0 and lifetime > 0.0:
		speed = _liquid_launch_speed(max_range, drag, lifetime)
	var inaccuracy: float = float(profile["inaccuracy"])
	var velocity_rnd: float = float(profile["velocity_rnd"])
	var pellet_total: int = maxi(int(profile["pellets"]), 1)
	# Multi-pellet salvos share a shot_id so repeat hits on the same target
	# halve damage per extra pellet.
	var salvo_shot_id: int = _next_shot_id() if pellet_total > 1 else 0
	for pellet_i in range(pellet_total):
		# Evenly distribute pellets across the inaccuracy cone — each gets its
		# own 1/N slot and we only jitter inside it, so the salvo fans out
		# instead of clustering near the centre by chance.
		var spread_rad: float = 0.0
		if inaccuracy > 0.0 and pellet_total > 1:
			var t: float = float(pellet_i) / float(pellet_total - 1)
			var slot_w: float = (2.0 * inaccuracy) / float(pellet_total)
			var center_deg: float = lerp(-inaccuracy, inaccuracy, t)
			var jitter_deg: float = randf_range(-slot_w * 0.5, slot_w * 0.5)
			spread_rad = deg_to_rad(center_deg + jitter_deg)
		elif inaccuracy > 0.0:
			spread_rad = deg_to_rad(randf_range(-inaccuracy, inaccuracy))
		var pellet_angle: float = aim_angle + spread_rad
		var pellet_target: Vector2 = fire_pos + Vector2.from_angle(pellet_angle) * shot_distance
		# Per-glob launch-speed jitter (velocityRnd): each shot leaves at
		# speed × (1 ± velocity_rnd) so a liquid spray's globs scatter to
		# different distances instead of all landing on the same spot.
		var pellet_speed: float = speed
		if velocity_rnd > 0.0:
			pellet_speed *= 1.0 + randf_range(-velocity_rnd, velocity_rnd)
		_spawn_projectile(
			fire_pos,
			target_ref,
			pellet_target,
			target_type,
			pellet_speed,
			damage,
			profile["color"],
			"turret",
			bool(profile["aoe"]),
			float(profile["aoe_radius"]),
			source_faction,
			{
				"lifetime": lifetime,
				"radius": float(profile["radius"]),
				"pierce": int(profile["pierce"]),
				"homing": float(profile["homing"]),
				"knockback": float(profile["knockback"]),
				"trail_color": profile["trail_color"],
				"front_color": profile["front_color"],
				"back_color": profile["back_color"],
				"visual_width": float(profile["visual_width"]),
				"visual_height": float(profile["visual_height"]),
				"shrink_y": float(profile["shrink_y"]),
				"projectile_sprite": profile.get("projectile_sprite", null),
				"collides_air": bool(profile["collides_air"]),
				"collides_ground": bool(profile["collides_ground"]),
				"status": profile["status"],
				"ammo_id": profile.get("ammo_id", &""),
				"splash_mult": float(profile["splash_mult"]),
				"max_range": max_range,
				"shot_id": salvo_shot_id,
				"frag_count": int(profile["frag_count"]),
				"frag_damage": float(profile["frag_damage"]),
				"frag_speed": float(profile["frag_speed"]),
				"frag_radius": float(profile["frag_radius"]),
				"frag_range": float(profile["frag_range"]),
				"liquid": bool(profile["liquid"]),
				"drag": drag,
				"impact_scale": float(profile.get("impact_effect_scale", 1.0)),
			},
		)
	# Shoot FX (Mindustry-style muzzle flash + smoke cone) — emitted once per
	# shot from INSIDE the shared emitter so EVERY caller (auto-fire, manual
	# control, any future path) gets it without re-adding the call. Callers
	# that shouldn't flash (e.g. the firefighter water spray) pass
	# `with_shoot_fx = false`.
	if with_shoot_fx:
		spawn_shoot_fx(fire_pos, aim_angle, float(profile.get("muzzle_flash_scale", 1.0)), profile["color"], bool(profile.get("muzzle_flash_circles", false)))


func _update_projectiles(delta: float) -> void:
	var unit_mgr = _unit_mgr_ref()
	var to_remove: Array[int] = []

	for i in range(projectiles.size()):
		var proj = projectiles[i]

		# Externally-killed projectiles (e.g. shot down by a unit's
		# POINT_DEFENSE weapon mount) are flagged `dead` and despawned here.
		if proj.get("dead", false):
			to_remove.append(i)
			continue

		# Lifetime is no longer the despawn driver — bullets always
		# fly the turret's `attack_range` and die there (or sooner on
		# wall / direct-fire collision). Age still advances so any
		# downstream visual effect that reads it (trail fade, etc.)
		# keeps working.
		proj["age"] = proj.get("age", 0.0) + delta

		var is_liquid: bool = bool(proj.get("liquid", false))

		# Liquid bullets (Corrosion / Tsunami) despawn on their lifetime, like
		# Mindustry. A drag-decelerated blob bleeds off speed and converges on a
		# fixed maximum reach, so it can crawl to a near-stop well before it ever
		# travels `max_range` — the distance check below would then never fire and
		# the orb would hang frozen in mid-air forever. Lifetime expiry ends it;
		# splash ammo detonates at the landing point and the removal loop drops
		# the fading puddle splat.
		if is_liquid:
			var life: float = float(proj.get("lifetime", 0.0))
			if life > 0.0 and proj["age"] >= life:
				if bool(proj.get("aoe", false)):
					proj["target_pos"] = proj["pos"]
					_on_projectile_hit(proj, unit_mgr)
				to_remove.append(i)
				continue

		# Max-range despawn — stop the projectile once it has travelled further
		# than the turret's effective range from where it was fired.
		var max_range: float = float(proj.get("max_range", 0.0))
		if max_range > 0.0:
			var spawn_pos: Vector2 = proj.get("spawn_pos", proj["pos"])
			if proj["pos"].distance_to(spawn_pos) >= max_range:
				# Liquid splash ammo detonates where it lands at the end of its arc.
				if is_liquid and bool(proj.get("aoe", false)):
					proj["target_pos"] = proj["pos"]
					_on_projectile_hit(proj, unit_mgr)
				# Expired at max range without hitting → despawn puff, not a hit spark.
				proj["fx_despawn"] = true
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
		# Liquid drag: bleed off `drag` of the speed per 1/60s so a fluid blob
		# decelerates into a lobbed arc instead of flying flat.
		var pdrag: float = float(proj.get("drag", 0.0))
		if pdrag > 0.0:
			proj["speed"] = float(proj["speed"]) * pow(maxf(1.0 - pdrag, 0.0), delta * 60.0)
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
			_spawn_frags(proj, proj["pos"])
			to_remove.append(i)
			continue

		# --- Shield collision ---
		# Hostile shields swallow bullets that cross their boundary
		# from OUTSIDE → INSIDE. Each hit subtracts `proj.damage` from
		# the shield's HP pool; the shield breaks at 0 and respawns
		# after its cooldown. Friendly bullets and bullets travelling
		# from inside outward are not intercepted.
		var shield_sys = get_node_or_null("/root/Main/ShieldSystem")
		if shield_sys and shield_sys.has_method("intercept_bullet"):
			var src_faction_s: int = int(proj.get("source_faction", -1))
			var hit_info: Dictionary = shield_sys.intercept_bullet(proj["pos"], move_pos, src_faction_s)
			if not hit_info.is_empty():
				var anchor_h: Vector2i = hit_info.get("anchor", Vector2i.ZERO)
				shield_sys.apply_bullet_damage(anchor_h, float(proj.get("damage", 0.0)))
				# Spawn the impact at the actual boundary crossing so
				# the muzzle flash / spark reads as hitting the shield.
				proj["pos"] = hit_info.get("hit_pos", move_pos)
				to_remove.append(i)
				continue

		# --- In-path collision (any projectile type) ---
		# Every bullet now dies on first contact with an opposing-faction
		# unit / building, regardless of whether it was direct-fire or
		# locked onto a specific target. Previously, only `target_type ==
		# "none"` (drone / controlled-unit shots) checked for in-path
		# hits — a turret aimed at enemy A would happily fly straight
		# through enemy B if B walked into the line. Now B intercepts
		# and the bullet despawns there.
		#
		# AoE / status / knockback are preserved for the case where the
		# intercepted entity IS the bullet's originally-intended target:
		# we route through `_on_projectile_hit` so splash etc. still
		# fires at that position. Incidental in-path intercepts get
		# direct damage + knockback + status only.
		if unit_mgr:
			var src_faction: int = proj.get("source_faction", main.Faction.LUMINA)
			var src_team: int = UnitData.Team.PLAYER if src_faction == main.Faction.LUMINA \
					else UnitData.Team.ENEMY
			var hit_unit: Node2D = _find_opposing_unit_on_segment(
					proj["pos"], move_pos, src_team, unit_mgr)
			if hit_unit:
				if hit_unit.has_method("unit_shield_intercept"):
					var shield_hit: Dictionary = hit_unit.unit_shield_intercept(
							proj["pos"], move_pos, src_team)
					if not shield_hit.is_empty():
						if hit_unit.has_method("apply_unit_shield_damage"):
							hit_unit.apply_unit_shield_damage(float(proj.get("damage", 0.0)))
						proj["pos"] = shield_hit.get("hit_pos", move_pos)
						to_remove.append(i)
						continue
				var orig_target = proj.get("target_ref")
				var hit_is_target: bool = (proj.get("target_type", "") == "enemy" \
						and orig_target == hit_unit)
				if hit_is_target and bool(proj.get("aoe", false)):
					proj["target_pos"] = hit_unit.position
					_on_projectile_hit(proj, unit_mgr)
				else:
					hit_unit.take_damage(_shot_damage(proj, hit_unit.get_instance_id(), proj["damage"]))
					_apply_knockback(hit_unit, proj["pos"], float(proj.get("knockback", 0.0)))
					_apply_status(hit_unit, proj.get("status"))
					_spritz_on_hit(hit_unit, proj)
					# Burst on a unit struck mid-flight (Detonater) — spawn from
					# the shot's own position so the orbs fan out from where the
					# shell was, letting the rear-facing ones fly clear instead
					# of all re-detonating inside the struck unit. The aoe-target
					# case above already frags via _on_projectile_hit.
					_spawn_frags(proj, proj["pos"])
				to_remove.append(i)
				continue
			var hit_bldg: Vector2i = _check_bullet_hit_building(move_pos, proj["pos"], src_faction)
			if hit_bldg != Vector2i(-1, -1):
				main.damage_building(hit_bldg, _shot_damage(proj, hit_bldg, proj["damage"]))
				_spawn_frags(proj, proj["pos"])
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
		# Liquid bullets leave a fading puddle splat wherever they land.
		if bool(dead_proj.get("liquid", false)):
			var dc: Color = dead_proj["color"]
			_liquid_splashes.append({
				"pos": dead_proj["pos"],
				"color": Color(dc.r, dc.g, dc.b, 0.45),
				"radius": float(dead_proj.get("radius", 6.0)) * 1.7,
				"age": 0.0, "life": 0.55,
			})
		# Spritz oxygen/hydrogen shots deposit into a growing gas cloud where they
		# land (the cloud, not the bullet, does the work).
		var dead_ammo: StringName = StringName(dead_proj.get("ammo_id", &""))
		if dead_ammo == &"mat_oxygen":
			_feed_gas_cloud(dead_proj["pos"], "oxygen")
		elif dead_ammo == &"mat_hydrogen":
			_feed_gas_cloud(dead_proj["pos"], "hydrogen")
		# Mindustry bullet end FX (skip liquids — they leave a puddle above):
		# a spark + smoke burst on a hit, or a small fading puff when the
		# round expired at max range without striking anything.
		if not bool(dead_proj.get("liquid", false)):
			var iscale: float = float(dead_proj.get("impact_scale", 1.0))
			if bool(dead_proj.get("fx_despawn", false)):
				spawn_despawn_fx(dead_proj["pos"], iscale, dead_proj["color"])
			else:
				spawn_impact_fx(dead_proj["pos"], iscale, dead_proj["color"])
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

		"held":
			# target_ref = {anchor: Vector2i, depth: int}. Track the
			# layer's live world position so the projectile follows it
			# through the chain.
			var ref_h = proj["target_ref"]
			if ref_h is Dictionary:
				var anchor_h = (ref_h as Dictionary).get("anchor", Vector2i(-9999, -9999))
				var depth_h: int = int((ref_h as Dictionary).get("depth", 0))
				if anchor_h is Vector2i:
					var bsys_p = get_node_or_null("/root/Main/BuildingSystem")
					if bsys_p and bsys_p.has_method("held_entity_world_at_depth") \
							and bsys_p.has_method("get_held_payload_at_depth"):
						var live_p: Dictionary = bsys_p.get_held_payload_at_depth(anchor_h, depth_h)
						if not live_p.is_empty():
							proj["target_pos"] = bsys_p.held_entity_world_at_depth(anchor_h, depth_h)


## Scatters a projectile's `frag_count` child orbs from `impact` (Detonater).
## Frags carry frag_count 0 so they never chain. No-op for ordinary shots.
## Called from EVERY impact path (target arrival, in-path unit/building, wall)
## so the burst fires the instant the shell hits anything, not only when it
## reaches the end of its range.
func _spawn_frags(proj: Dictionary, impact: Vector2) -> void:
	var fcount: int = int(proj.get("frag_count", 0))
	if fcount <= 0:
		return
	var fdmg: float = float(proj.get("frag_damage", 0.0))
	var fspd: float = float(proj.get("frag_speed", 250.0))
	var frad: float = float(proj.get("frag_radius", 4.0))
	var frng: float = float(proj.get("frag_range", 160.0))
	var fcol: Color = proj.get("color", Color.WHITE)
	var ffac: int = int(proj.get("source_faction", 0))
	var base_ang: float = randf() * TAU
	for fi in range(fcount):
		var ang: float = base_ang + (TAU / float(fcount)) * float(fi) + randf_range(-0.25, 0.25)
		var fdir: Vector2 = Vector2.from_angle(ang)
		_spawn_projectile(impact, null, impact + fdir * frng, "enemy", fspd, fdmg,
			fcol, "turret", false, 0.0, ffac,
			{"radius": frad, "max_range": frng,
			"lifetime": frng / maxf(fspd, 1.0) + 0.15, "is_frag": true})


func _on_projectile_hit(proj: Dictionary, unit_mgr: Node2D) -> void:
	var splash_mult: float = float(proj.get("splash_mult", 1.0))
	var knockback: float = float(proj.get("knockback", 0.0))
	var status: Resource = proj.get("status")

	_spawn_frags(proj, proj["pos"])

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
					_spritz_on_hit(unit, proj)
			else:
				# Single target
				var enemy = proj["target_ref"]
				if is_instance_valid(enemy) and not enemy.is_dead and _can_hit_unit(proj, enemy):
					enemy.take_damage(_shot_damage(proj, enemy.get_instance_id(), proj["damage"]))
					_apply_knockback(enemy, proj["pos"], knockback)
					_apply_status(enemy, status)
					_spritz_on_hit(enemy, proj)

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

		"held":
			# Damage routes only to the layer the projectile was aimed
			# at — a bullet at the tip damages the tip, not the crane
			# carrying it.
			var ref_hit = proj["target_ref"]
			if ref_hit is Dictionary:
				var anchor_hit = (ref_hit as Dictionary).get("anchor", Vector2i(-9999, -9999))
				var depth_hit: int = int((ref_hit as Dictionary).get("depth", 0))
				if anchor_hit is Vector2i:
					var bsys_h2 = get_node_or_null("/root/Main/BuildingSystem")
					if bsys_h2 and bsys_h2.has_method("damage_held_entity"):
						bsys_h2.damage_held_entity(anchor_hit, proj["damage"], depth_hit)


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


## Applies knockback to a unit by nudging its world position away from
## origin. Raycasts the displacement against the unit's pathing grid so
## the unit can't be yeeted across the map (when many diffuse pellets
## hit at once) or land inside a wall. Also caps the per-call distance
## to a sane fraction of a tile so even a degenerate `amount` stays
## reasonable.
func _apply_knockback(unit: Node2D, origin: Vector2, amount: float) -> void:
	if amount <= 0.0 or unit == null:
		return
	var dir: Vector2 = (unit.position - origin)
	if dir.length_squared() < 0.01:
		return
	dir = dir.normalized()
	# Hard cap per call — 6 tiles is already a strong shove and stops
	# pathological pile-ups (e.g. 15 diffuse pellets hitting in one
	# frame) from teleporting the unit halfway across the map.
	var gs: float = float(main.GRID_SIZE) if main else 32.0
	if "knockback_taken_mult" in unit:
		amount *= float(unit.knockback_taken_mult)
	var travel: float = clampf(amount, 0.0, gs * 6.0)
	# Pick the astar grid for the unit's movement layer so wall checks
	# match how the unit actually pathfinds. Flying units skip the
	# raycast entirely (no obstacles).
	var unit_mgr = _unit_mgr_ref()
	var astar: AStarGrid2D = null
	var ml: int = 0
	if unit and "data" in unit and unit.data:
		ml = unit.data.movement_layer
	if unit_mgr:
		match ml:
			0: astar = unit_mgr.astar if "astar" in unit_mgr else null
			1: astar = unit_mgr.astar_crawler if "astar_crawler" in unit_mgr else null
			2: astar = unit_mgr.astar_hover if "astar_hover" in unit_mgr else null
			4: astar = unit_mgr.astar_naval if "astar_naval" in unit_mgr else null
			_: astar = null  # FLYING
	if astar == null or main == null:
		unit.position += dir * travel
		return
	# Step the displacement in cell-sized chunks. Stop just before
	# entering a solid cell so the unit can't end up clipped inside.
	var step: float = gs * 0.5
	var travelled: float = 0.0
	var cur: Vector2 = unit.position
	while travelled < travel:
		var next_dist: float = minf(step, travel - travelled)
		var next_pos: Vector2 = cur + dir * next_dist
		var next_cell: Vector2i = main.world_to_grid(next_pos)
		# Out-of-bounds → treat as solid (clamp to map edge).
		if next_cell.x < 0 or next_cell.y < 0 \
				or next_cell.x >= main.GRID_WIDTH or next_cell.y >= main.GRID_HEIGHT:
			break
		if astar.is_point_solid(next_cell):
			break
		cur = next_pos
		travelled += next_dist
	unit.position = cur


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

## Walks every crane state with a LUMINA building turret as held
## payload and lets it fire at nearby enemy units (and enemy buildings
## when no units are nearby). Held turrets fire from the grabber's
## current world position with their saved aim offset, drain their
## payload `internal_battery_charge` per shot, and use a per-anchor
## cooldown stored in `held_cooldowns` so they don't spam.
func _update_held_turrets(delta: float) -> void:
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	if building_sys == null or not ("crane_states" in building_sys):
		return
	var unit_mgr = _unit_mgr_ref()
	if unit_mgr == null:
		return
	var crane_states: Dictionary = building_sys.crane_states
	# Tick down cooldowns + drop stale entries (anchor no longer holding
	# a building, or anchor itself was destroyed).
	for k in held_turret_cooldowns.keys():
		var still_holding: bool = false
		if crane_states.has(k):
			var stk: Dictionary = crane_states[k]
			var pk = stk.get("held_payload", null)
			if pk is Dictionary and (pk as Dictionary).get("type", "") == "building":
				still_holding = true
		if not still_holding:
			held_turret_cooldowns.erase(k)
			continue
		held_turret_cooldowns[k] = maxf(0.0, float(held_turret_cooldowns[k]) - delta)
	for anchor in crane_states:
		var state: Dictionary = crane_states[anchor]
		var payload: Variant = state.get("held_payload", null)
		if payload == null or not (payload is Dictionary):
			continue
		var p: Dictionary = payload
		if p.get("type", "") != "building":
			continue
		if int(p.get("faction", main.Faction.LUMINA)) != main.Faction.LUMINA:
			continue
		var data := Registry.get_block(StringName(p.get("block_id", "")))
		if data == null or not data.is_turret() or data.turret_head_sprite == null:
			continue
		# Resolve world muzzle position from the crane's live grabber.
		if not building_sys.has_method("held_entity_world"):
			continue
		var muzzle_pos: Vector2 = building_sys.held_entity_world(anchor)
		var range_px: float = data.attack_range * main.GRID_SIZE
		# Find a target — nearest enemy unit, then nearest enemy building.
		var target_ref: Node2D = null
		var target_world: Vector2 = Vector2.ZERO
		var target_kind: String = ""
		var nearest: Node2D = _find_nearest_enemy(muzzle_pos, unit_mgr.enemies)
		if nearest != null and muzzle_pos.distance_to(nearest.position) <= range_px:
			target_ref = nearest
			target_world = nearest.position
			target_kind = "enemy"
		else:
			var hb: Vector2i = _find_nearest_enemy_building(muzzle_pos, range_px)
			if hb != Vector2i(-9999, -9999):
				target_world = main.grid_to_world(hb) + Vector2(main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5)
				target_kind = "building"
		if target_kind == "":
			continue
		# Track the target with the heads even if the turret can't fire
		# this frame (cooldown / no battery / no ammo). The held draw
		# math reverses outer-grabber rotation, so we have to compensate
		# when writing the saved aim back: held_aim_world = grabber_angle
		# + (saved_aim - chassis_at_pickup) → invert for saved_aim.
		var grabber_angle: float = float(state.get("grabber_angle", 0.0))
		var rot_at_pickup: int = int(p.get("rotation", 0))
		var chassis_at_pickup: float = float(rot_at_pickup) * (PI / 2.0)
		var desired_world: float = (target_world - muzzle_pos).angle()
		var new_saved_aim: float = wrapf(desired_world - grabber_angle + chassis_at_pickup, -PI, PI)
		p["turret_aim_angle"] = new_saved_aim
		# Per-barrel snap to the same heading — held turrets skip toe-in
		# (no live `turret_world` reference) so every barrel just points
		# at the target alongside the chassis.
		var bcount: int = maxi(data.barrel_count, 1)
		var per_barrel: Array = []
		for _bi in range(bcount):
			per_barrel.append(new_saved_aim)
		p["turret_barrel_angles"] = per_barrel
		# Battery gate — held turrets only fire while the 10B reservoir
		# has power left to spend on this shot.
		if data.electrical_power_use > 0.0 and float(p.get("internal_battery_charge", 0.0)) <= 0.0:
			continue
		# Cooldown gate.
		if held_turret_cooldowns.get(anchor, 0.0) > 0.0:
			continue
		# Drain battery for this shot.
		if data.electrical_power_use > 0.0:
			# One full second of consumption per shot is a reasonable
			# proxy for "ammo cost" — the held turret pays the same
			# energy a placed one would pay over `attack_speed` of work.
			var draw_cost: float = data.electrical_power_use * maxf(data.attack_speed, 0.1)
			p["internal_battery_charge"] = maxf(0.0, float(p.get("internal_battery_charge", 0.0)) - draw_cost)
		# Ammo: held turrets pull from `payload.stored_items` (the
		# block's frozen inventory at pickup, plus anything its held
		# factory has produced since). No ammo → can't fire.
		var stored_items: Dictionary = p.get("stored_items", {})
		var ammo_data: AmmoType = null
		if data.ammo_types.size() == 0:
			continue
		for ammo in data.ammo_types:
			if ammo == null or not (ammo is AmmoType):
				continue
			var atype: AmmoType = ammo as AmmoType
			var key := String(atype.item_id)
			var amt: int = maxi(atype.amount_per_shot, 1)
			if int(stored_items.get(key, 0)) >= amt:
				stored_items[key] = int(stored_items[key]) - amt
				ammo_data = atype
				break
		if ammo_data == null:
			continue
		p["stored_items"] = stored_items
		# Drain battery for this shot.
		if data.electrical_power_use > 0.0:
			var draw_cost: float = data.electrical_power_use * maxf(data.attack_speed, 0.1)
			p["internal_battery_charge"] = maxf(0.0, float(p.get("internal_battery_charge", 0.0)) - draw_cost)
		# Spawn projectile — always aimed at the end of the turret's
		# range along the muzzle's aim axis. Damage to `target_ref`
		# resolves on arrival via `_on_projectile_hit`.
		var proj_dir: Vector2 = (target_world - muzzle_pos)
		if proj_dir.length() < 0.01:
			continue
		proj_dir = proj_dir.normalized()
		var end_pos: Vector2 = muzzle_pos + proj_dir * range_px
		if target_kind == "enemy":
			_spawn_projectile(muzzle_pos, target_ref, end_pos, "enemy",
				ammo_data.projectile_speed, ammo_data.damage * ammo_data.unit_damage_mult,
				ammo_data.projectile_color, "turret", ammo_data.is_splash,
				ammo_data.splash_radius if ammo_data.is_splash else 0.0,
				main.Faction.LUMINA, {"max_range": range_px})
		else:
			_spawn_projectile(muzzle_pos, null, end_pos, "none",
				ammo_data.projectile_speed, ammo_data.damage * ammo_data.building_damage_mult,
				ammo_data.projectile_color, "turret", ammo_data.is_splash,
				ammo_data.splash_radius if ammo_data.is_splash else 0.0,
				main.Faction.LUMINA, {"max_range": range_px})
		held_turret_cooldowns[anchor] = data.attack_speed * ammo_data.reload_multiplier


## Held LUMINA units fire at enemies. Mirrors `_update_held_turrets`
## but uses unit attack stats (no ammo, no battery — units don't have
## a battery field), and aims from the live grabber position.
func _update_held_units(delta: float) -> void:
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	if building_sys == null or not ("crane_states" in building_sys):
		return
	var unit_mgr = _unit_mgr_ref()
	if unit_mgr == null:
		return
	var crane_states: Dictionary = building_sys.crane_states
	for k in held_unit_cooldowns.keys():
		var still: bool = false
		if crane_states.has(k):
			var sk: Dictionary = crane_states[k]
			var pk = sk.get("held_payload", null)
			if pk is Dictionary and (pk as Dictionary).get("type", "") == "unit":
				still = true
		if not still:
			held_unit_cooldowns.erase(k)
			continue
		held_unit_cooldowns[k] = maxf(0.0, float(held_unit_cooldowns[k]) - delta)
	for anchor in crane_states:
		var state: Dictionary = crane_states[anchor]
		var payload = state.get("held_payload", null)
		if not (payload is Dictionary):
			continue
		var p: Dictionary = payload
		if p.get("type", "") != "unit":
			continue
		var unit_data: UnitData = Registry.get_unit(StringName(p.get("unit_id", "")))
		if unit_data == null:
			continue
		# Units with no attack stats can't shoot — skip the worker, the
		# medic, etc. (anything carrier-only).
		if unit_data.attack_damage <= 0.0 or unit_data.attack_range <= 0.0:
			continue
		# Faction inherits from the holding crane.
		var holder_faction: int = main.get_building_faction(anchor)
		if holder_faction != main.Faction.LUMINA:
			continue
		if held_unit_cooldowns.get(anchor, 0.0) > 0.0:
			continue
		var muzzle_pos: Vector2 = building_sys.held_entity_world(anchor) if building_sys.has_method("held_entity_world") else Vector2.ZERO
		var range_px: float = unit_data.attack_range
		var nearest: Node2D = _find_nearest_enemy(muzzle_pos, unit_mgr.enemies)
		if nearest == null or muzzle_pos.distance_to(nearest.position) > range_px:
			continue
		var dir: Vector2 = (nearest.position - muzzle_pos)
		if dir.length() < 0.01:
			continue
		var aim_dir: Vector2 = dir.normalized()
		var end_pos_u: Vector2 = muzzle_pos + aim_dir * range_px
		_spawn_projectile(
			muzzle_pos,
			nearest,
			end_pos_u,
			"enemy",
			500.0,
			unit_data.attack_damage,
			Color(0.6, 1.0, 0.6, 1.0),
			"unit",
			false, 0.0,
			main.Faction.LUMINA,
			{"max_range": range_px})
		held_unit_cooldowns[anchor] = unit_data.attack_speed


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



## Faction-aware in-path collision check. Walks both `enemies` and
## `player_units` (since a FEROX bullet can hit player units and a
## LUMINA bullet can hit enemy units), skipping anything whose `team`
## matches the shooter. Returns the first unit whose hitbox intersects
## the segment, or null.
func _find_opposing_unit_on_segment(bullet_prev: Vector2, bullet_pos: Vector2,
		source_team: int, unit_mgr: Node2D) -> Node2D:
	var best_shield_unit: Node2D = null
	var best_shield_dist := INF
	for lst in [unit_mgr.enemies, unit_mgr.player_units]:
		for u in lst:
			if not is_instance_valid(u) or u.is_dead:
				continue
			if "team" in u and u.team == source_team:
				continue
			if u.has_method("unit_shield_intercept"):
				var shield_hit: Dictionary = u.unit_shield_intercept(bullet_prev, bullet_pos, source_team)
				if not shield_hit.is_empty():
					var hit_pos: Vector2 = shield_hit.get("hit_pos", bullet_pos)
					var shield_dist: float = bullet_prev.distance_squared_to(hit_pos)
					if shield_dist < best_shield_dist:
						best_shield_dist = shield_dist
						best_shield_unit = u
			var closest: Vector2 = Geometry2D.get_closest_point_to_segment(u.position, bullet_prev, bullet_pos)
			if closest.distance_to(u.position) < hit_radius + u.unit_size:
				if best_shield_unit != null:
					var body_dist: float = bullet_prev.distance_squared_to(closest)
					if best_shield_dist <= body_dist:
						return best_shield_unit
				return u
	if best_shield_unit != null:
		return best_shield_unit
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


# =========================
# TURRET AMMO (items + fluids)
# =========================

## Consumes `amount` of a turret's ammo from its buffer. Items pull from
## block_storage items via logistics; fluids pull from the block_storage fluids
## bucket (fed by an adjacent pipe — see logistics _try_accept_booster_fluid).
## Returns true only if the full amount was available and removed.
## "Consumes" a powered ammo's per-shot cost. The Arc's per-shot energy is
## already drawn continuously from the grid via `electrical_power_use`, so this
## doesn't double-drain — it just reports whether the turret's network is
## currently supplying power (efficiency > 0). No PowerSystem (e.g. map editor)
## → treated as available so the weapon still demos.
func _consume_power_ammo(anchor: Vector2i, _power_per_shot: float) -> bool:
	var power_sys = get_node_or_null("/root/Main/PowerSystem")
	if power_sys == null:
		return true
	return power_sys.get_electrical_efficiency(anchor) > 0.0


## Peek: does the block at `anchor` currently hold `amount` of `item_id`
## (item or fluid)? Read-only — used to check multi-resource affordability
## before committing any consumption.
func _has_turret_ammo(log_ref: Node2D, anchor: Vector2i, item_id: StringName, amount: float) -> bool:
	if log_ref == null:
		return false
	if Registry.get_fluid(item_id) != null:
		var st: Dictionary = log_ref.block_storage.get(anchor, {})
		return float(st.get("fluids", {}).get(item_id, 0.0)) >= amount
	if not log_ref.has_method("get_stored_item_count"):
		return false
	return float(log_ref.get_stored_item_count(anchor, item_id)) >= amount


## Consumes one shot's primary ammo PLUS any `extra_costs` for `ammo_data`,
## but only if ALL of them are affordable (all-or-nothing). Returns false
## without consuming anything if the block can't pay the full cost.
func _consume_ammo_with_extras(log_ref: Node2D, anchor: Vector2i, ammo_data: AmmoType) -> bool:
	if log_ref == null:
		return false
	var amt: int = maxi(ammo_data.amount_per_shot, 1)
	# Affordability pass (no mutation yet).
	if not _has_turret_ammo(log_ref, anchor, ammo_data.item_id, float(amt)):
		return false
	for k in ammo_data.extra_costs:
		if not _has_turret_ammo(log_ref, anchor, StringName(k), float(ammo_data.extra_costs[k])):
			return false
	# Commit.
	_consume_turret_ammo(log_ref, anchor, ammo_data.item_id, amt)
	for k in ammo_data.extra_costs:
		_consume_turret_ammo(log_ref, anchor, StringName(k), int(ammo_data.extra_costs[k]))
	return true


func _consume_turret_ammo(log_ref: Node2D, anchor: Vector2i, item_id: StringName, amount: int) -> bool:
	if Registry.get_fluid(item_id) != null:
		var st: Dictionary = log_ref.block_storage.get(anchor, {})
		var fl: Dictionary = st.get("fluids", {})
		if float(fl.get(item_id, 0.0)) >= float(amount):
			fl[item_id] = float(fl[item_id]) - float(amount)
			if fl[item_id] <= 0.0001:
				fl.erase(item_id)
			return true
		return false
	# Item ammo.
	if not log_ref.has_method("get_stored_item_count"):
		return false
	if log_ref.get_stored_item_count(anchor, item_id) >= amount:
		log_ref.remove_from_storage(anchor, item_id, amount)
		return true
	return false


# =========================
# GAS CLOUDS (Fume turret + sulfur vents)
# =========================

## Per-frame update for a single fume turret: consumes sulfur fumes from its
## fluid buffer and grows a corroding cloud in front of it, sized by throughput
## (full supply → 7-tile cloud, none → fades away).
const _FUME_MAX_RATE := 6.0   # sulfur fumes/sec for a full-size cloud
func _update_fume_emitter(grid_pos: Vector2i, data: BlockData, turret_world: Vector2, power_eff: float, delta: float) -> void:
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var key: String = "fume:%d,%d" % [anchor.x, anchor.y]
	var log_ref: Node2D = _logistics
	var avail: float = 0.0
	var st: Dictionary = {}
	if log_ref != null:
		st = log_ref.block_storage.get(anchor, {})
		avail = float(st.get("fluids", {}).get(&"mat_sulfur_fumes", 0.0))
	var desired: float = _FUME_MAX_RATE * delta * maxf(power_eff, 0.0)
	var consumed: float = minf(avail, desired)
	if consumed <= 0.0001 or desired <= 0.0:
		# Starved — let any existing cloud decay.
		if gas_clouds.has(key):
			gas_clouds[key]["target_radius"] = 0.0
			gas_clouds[key]["t_last"] = _cloud_time
		return
	# Burn the fumes.
	var fl: Dictionary = st.get("fluids", {})
	fl[&"mat_sulfur_fumes"] = avail - consumed
	st["fluids"] = fl
	log_ref.block_storage[anchor] = st
	# Cloud sits in front along the turret's current facing; radius scales with
	# how close we are to max throughput (7-tile diameter → 3.5-tile radius).
	var ratio: float = clampf(consumed / desired, 0.0, 1.0)
	var ang: float = float(turret_angles.get(grid_pos, 0.0))
	var reach: float = (data.attack_range * 0.5) * float(main.GRID_SIZE)
	var center: Vector2 = turret_world + Vector2.from_angle(ang) * reach
	var target_r: float = lerpf(1.5, 3.5, ratio) * float(main.GRID_SIZE)
	_assert_cloud(key, center, target_r, "fume")


## Asserts (creates or refreshes) a gas cloud entry.
func _assert_cloud(key: String, center: Vector2, target_radius: float, kind: String) -> void:
	if gas_clouds.has(key):
		var c: Dictionary = gas_clouds[key]
		c["center"] = center
		c["target_radius"] = target_radius
		c["t_last"] = _cloud_time
	else:
		gas_clouds[key] = {
			"center": center, "radius": 0.0, "target_radius": target_radius,
			"t_last": _cloud_time, "type": kind,
		}


## Deposits one Spritz oxygen/hydrogen shot into a gas cloud at `pos`. Merges
## into the nearest same-kind cloud within GAS_MERGE_DIST (growing it toward the
## cap and refreshing its feed time), otherwise spawns a new one. Clouds shrink
## on their own once they stop being fed (see _update_gas_clouds).
func _feed_gas_cloud(pos: Vector2, kind: String) -> void:
	var gs: float = float(main.GRID_SIZE)
	var merge_px: float = GAS_MERGE_DIST * gs
	var feed_px: float = GAS_FEED_PER_SHOT * gs
	var max_px: float = GAS_MAX_RADIUS * gs
	var best_key: String = ""
	var best_d: float = merge_px
	for key in gas_clouds:
		var c: Dictionary = gas_clouds[key]
		if String(c["type"]) != kind:
			continue
		# A burning oxygen cloud CAN still be fed — more oxygen keeps it big and
		# lit (the fire is held on its plateau while supply continues).
		var d: float = pos.distance_to(c["center"])
		if d < best_d:
			best_d = d
			best_key = key
	if best_key != "":
		var c: Dictionary = gas_clouds[best_key]
		c["target_radius"] = minf(float(c["target_radius"]) + feed_px, max_px)
		c["t_last"] = _cloud_time
		# Drift the centre slightly toward the new impact so the cloud follows
		# where the player is spraying.
		c["center"] = (c["center"] as Vector2).lerp(pos, 0.15)
	else:
		_gas_seq += 1
		gas_clouds["%s:%d" % [kind, _gas_seq]] = {
			"center": pos, "radius": 0.0, "target_radius": minf(feed_px, max_px),
			"t_last": _cloud_time, "type": kind,
			"ignited": false, "fire_t": 0.0, "fire_origin": pos,
		}


## Current fire radius (in px) of an ignited oxygen cloud, 0 if not burning. The
## fire grows from the entry point to cover the cloud over OXY_FIRE_SPREAD, holds
## for OXY_FIRE_DURATION, then fades over OXY_FIRE_FADE.
func _oxy_fire_radius(c: Dictionary) -> float:
	if not bool(c.get("ignited", false)):
		return 0.0
	var ft: float = float(c.get("fire_t", 0.0))
	var full: float = float(c["radius"])
	if ft < OXY_FIRE_SPREAD:
		return full * (ft / OXY_FIRE_SPREAD)
	if ft < OXY_FIRE_SPREAD + OXY_FIRE_DURATION:
		return full
	var fade: float = (ft - OXY_FIRE_SPREAD - OXY_FIRE_DURATION) / OXY_FIRE_FADE
	return full * maxf(0.0, 1.0 - fade)


## Emits the standard block-on-fire particles across a burning oxygen cloud's
## fire area, so it reads as the exact same flame overlay buildings use. Density
## scales with the fire radius; throttled by a per-cloud emit accumulator.
func _emit_cloud_fire(c: Dictionary, delta: float) -> void:
	if _particle_overlay == null:
		_particle_overlay = get_node_or_null("/root/Main/ParticleOverlay")
	var po: Node = _particle_overlay
	if po == null or not po.has_method("spawn_fire"):
		return
	var fr: float = _oxy_fire_radius(c)
	if fr < 4.0:
		return
	var gs: float = float(main.GRID_SIZE)
	const EMIT_INTERVAL := 0.06
	c["fire_emit_acc"] = float(c.get("fire_emit_acc", 0.0)) + delta
	while float(c["fire_emit_acc"]) >= EMIT_INTERVAL:
		c["fire_emit_acc"] = float(c["fire_emit_acc"]) - EMIT_INTERVAL
		var cells: float = fr / gs
		var emits: int = clampi(int(cells * 1.5) + 1, 1, 10)
		var fo: Vector2 = c.get("fire_origin", c["center"])
		for i in range(emits):
			var a: float = randf() * TAU
			var rr: float = sqrt(randf()) * fr  # uniform over the disc
			var px: Vector2 = fo + Vector2(cos(a), sin(a)) * rr
			po.spawn_fire(px, Vector2(0.0, -1.0), 2, 55.0, 0.65, gs * 0.18, 110.0)


func _update_gas_clouds(delta: float) -> void:
	_cloud_time += delta
	# Re-assert sulfur-vent clouds (always-on, 4-tile) once a second.
	_vent_cloud_scan_timer -= delta
	if _vent_cloud_scan_timer <= 0.0:
		_vent_cloud_scan_timer = 1.0
		_refresh_vent_clouds()
	# Grow/shrink toward target; cull faded clouds.
	var to_erase: Array = []
	for key in gas_clouds:
		var c: Dictionary = gas_clouds[key]
		var ctype: String = String(c["type"])
		var fed_recently: bool = (_cloud_time - float(c["t_last"])) <= 0.3
		# Fume clouds decay if their turret stopped refreshing them.
		if ctype == "fume" and not fed_recently:
			c["target_radius"] = 0.0
		# Spritz oxygen/hydrogen clouds shrink once they STOP being fed. A burning
		# oxygen cloud kept supplied with more oxygen stays big and lit.
		elif ctype == "oxygen" or ctype == "hydrogen":
			if not fed_recently:
				c["target_radius"] = maxf(0.0, float(c["target_radius"]) - GAS_DECAY_RATE * float(main.GRID_SIZE) * delta)
		var tr: float = float(c["target_radius"])
		var r: float = float(c["radius"])
		r += (tr - r) * minf(1.0, delta * 4.0)
		c["radius"] = r
		# Advance an oxygen cloud's fire. While it's still being fed, hold the
		# fire on the full-strength plateau so it never starts fading; only once
		# the supply stops does fire_t run on into the fade and the cloud is
		# removed. Meanwhile emit the block-on-fire particles over the burn area.
		if bool(c.get("ignited", false)):
			c["fire_t"] = float(c.get("fire_t", 0.0)) + delta
			if fed_recently:
				c["fire_t"] = minf(float(c["fire_t"]), OXY_FIRE_SPREAD + OXY_FIRE_DURATION * 0.5)
			if float(c["fire_t"]) >= OXY_FIRE_SPREAD + OXY_FIRE_DURATION + OXY_FIRE_FADE:
				to_erase.append(key)
				continue
			_emit_cloud_fire(c, delta)
		if r < 3.0 and tr <= 0.0:
			to_erase.append(key)
	for k in to_erase:
		gas_clouds.erase(k)
	# Apply the corroding status to enemies inside any cloud, a few times/sec.
	_cloud_damage_timer -= delta
	if _cloud_damage_timer <= 0.0:
		_cloud_damage_timer = 0.4
		_apply_cloud_effects()


func _refresh_vent_clouds() -> void:
	var terrain := _terrain_ref()
	if terrain == null or not ("floor_tiles" in terrain):
		return
	var gs: float = float(main.GRID_SIZE)
	var seen: Dictionary = {}
	for cell in terrain.floor_tiles:
		if StringName(terrain.floor_tiles[cell]) != &"sulfur_vent":
			continue
		var key: String = "vent:%d,%d" % [cell.x, cell.y]
		var center: Vector2 = main.grid_to_world(cell) + Vector2(gs * 0.5, gs * 0.5)
		_assert_cloud(key, center, 2.0 * gs, "vent")  # 4-tile diameter
		seen[key] = true
	# Vent gone (tile repainted) → let its cloud fade out.
	for key in gas_clouds:
		if gas_clouds[key]["type"] == "vent" and not seen.has(key):
			gas_clouds[key]["target_radius"] = 0.0


func _apply_cloud_effects() -> void:
	if gas_clouds.is_empty():
		return
	var unit_mgr := _unit_mgr_ref()
	if unit_mgr == null:
		return
	var corr: StatusEffectData = Registry.get_status_effect(&"corroding")
	var hydro: StatusEffectData = Registry.get_status_effect(&"hydrogen_slowed")
	var burn: StatusEffectData = Registry.get_status_effect(&"burning")
	for key in gas_clouds:
		var c: Dictionary = gas_clouds[key]
		var ctype: String = String(c["type"])
		var r: float = float(c["radius"])
		match ctype:
			"oxygen":
				# Only an ignited oxygen cloud hurts anyone — its fire burns every
				# enemy inside the growing/shrinking fire radius.
				if not bool(c.get("ignited", false)) or burn == null:
					continue
				var fr: float = _oxy_fire_radius(c)
				if fr < 6.0:
					continue
				for u in unit_mgr.get_enemies_in_range(c["center"], fr):
					if is_instance_valid(u) and not u.is_dead and u.has_method("apply_status_effect"):
						u.apply_status_effect(burn)
			"hydrogen":
				# Poison + slow every enemy inside. The status carries both the
				# 5-dmg/2s DoT and the ×0.8 move-speed; re-applied each tick with a
				# short duration so it lapses shortly after leaving the cloud.
				if r < 6.0 or hydro == null:
					continue
				for u in unit_mgr.get_enemies_in_range(c["center"], r):
					if is_instance_valid(u) and not u.is_dead and u.has_method("apply_status_effect"):
						u.apply_status_effect(hydro)
			_:
				# Fume / vent → corroding.
				if r < 6.0 or corr == null:
					continue
				for u in unit_mgr.get_enemies_in_range(c["center"], r):
					if is_instance_valid(u) and not u.is_dead and u.has_method("apply_status_effect"):
						u.apply_status_effect(corr, 6.0)


func _update_liquid_splashes(delta: float) -> void:
	if _liquid_splashes.is_empty():
		return
	if "world_paused" in main and main.world_paused:
		return
	for i in range(_liquid_splashes.size() - 1, -1, -1):
		var sp: Dictionary = _liquid_splashes[i]
		sp["age"] = float(sp["age"]) + delta
		if float(sp["age"]) >= float(sp["life"]):
			_liquid_splashes.remove_at(i)


func _draw_liquid_splashes() -> void:
	for sp in _liquid_splashes:
		var t: float = clampf(float(sp["age"]) / maxf(float(sp["life"]), 0.0001), 0.0, 1.0)
		# Splat spreads out a touch and fades — a quick wet puddle.
		var r: float = float(sp["radius"]) * (0.6 + 0.4 * t)
		var base: Color = sp["color"]
		var col := Color(base.r, base.g, base.b, base.a * (1.0 - t))
		draw_circle(sp["pos"], r, col)


func _draw_gas_clouds() -> void:
	for key in gas_clouds:
		var c: Dictionary = gas_clouds[key]
		var r: float = float(c["radius"])
		if r < 2.0:
			continue
		var center: Vector2 = c["center"]
		# Per-type tint: yellow-green fume/vent, rose oxygen, blue hydrogen.
		var tint: Color
		match String(c["type"]):
			"oxygen":   tint = Color(0.997, 0.766, 1.0)
			"hydrogen": tint = Color(0.6, 0.8, 1.0)
			_:          tint = Color(0.8, 0.88, 0.3)
		# Layered translucent puff. A burning oxygen cloud's flames are drawn by
		# the ParticleOverlay (the same block-on-fire particles) via
		# _emit_cloud_fire, so here we only fade the gas tint as it's consumed.
		var puff_a: float = 0.08 if bool(c.get("ignited", false)) else 0.15
		draw_circle(center, r, Color(tint.r, tint.g, tint.b, puff_a))
		draw_circle(center, r * 0.72, Color(tint.r, tint.g, tint.b, puff_a * 0.87))
		draw_circle(center, r * 0.42, Color(tint.r, tint.g, tint.b, puff_a * 0.8))


## Draws each active Eclipse beam as a layered line: a soft wide glow,
## a brighter mid stripe, and a hot white core, capped with a glow at the
## impact point. Only turrets whose state machine is mid-burst are `active`.
func _draw_beams() -> void:
	for anchor in beam_states:
		var st: Dictionary = beam_states[anchor]
		if not bool(st.get("active", false)):
			continue
		var a: Vector2 = st["start"]
		var b: Vector2 = st["end"]
		var beam_vec: Vector2 = b - a
		var beam_len: float = beam_vec.length()
		if beam_len <= 0.001:
			continue
		var beam_dir: Vector2 = beam_vec / beam_len
		var cap_radius: float = 6.0
		var line_end: Vector2 = b - beam_dir * maxf(cap_radius - 0.75, 0.0)
		if a.distance_squared_to(line_end) < 1.0:
			line_end = b
		draw_line(a, line_end, Color(0.6, 0.9, 1.0, 0.22), 11.0)
		draw_line(a, line_end, Color(0.8, 0.95, 1.0, 0.55), 5.0)
		draw_line(a, line_end, Color(1.0, 1.0, 1.0, 0.95), 2.0)
		draw_circle(b, cap_radius * 1.28, Color(0.6, 0.9, 1.0, 0.22))
		draw_circle(b, cap_radius, Color(0.8, 0.95, 1.0, 0.55))
		draw_circle(b, cap_radius * 0.72, Color(1.0, 1.0, 1.0, 0.95))


## Draws each active Blaster shockwave as an expanding, fading quarter-circle of
## translucent white — a soft wide arc behind a brighter leading edge.
func _draw_shockwaves() -> void:
	for sw in shockwaves:
		var radius: float = float(sw["radius"])
		if radius < 2.0:
			continue
		var origin: Vector2 = sw["origin"]
		var aim: float = float(sw["aim"])
		var a0: float = aim - SHOCKWAVE_HALF_ANGLE
		var a1: float = aim + SHOCKWAVE_HALF_ANGLE
		var fade: float = clampf(1.0 - radius / maxf(float(sw["max_radius"]), 0.0001), 0.0, 1.0)
		draw_arc(origin, radius, a0, a1, 48, Color(1.0, 1.0, 1.0, 0.22 * fade), 12.0, true)
		draw_arc(origin, radius, a0, a1, 48, Color(1.0, 1.0, 1.0, 0.8 * fade), 4.0, true)


## Draws the charge-up glow on Blasters that are winding up: a hydrogen-blue orb
## at the muzzle that swells as the charge approaches full.
func _draw_blaster_charges() -> void:
	for anchor in blaster_states:
		var st: Dictionary = blaster_states[anchor]
		var c: float = float(st.get("draw_charge", 0.0))
		if c <= 0.01:
			continue
		var muzzle: Vector2 = st.get("muzzle", Vector2.ZERO)
		var r: float = lerpf(1.5, 9.0, c)
		draw_circle(muzzle, r * 1.6, Color(0.6, 0.85, 1.0, 0.18 * c))
		draw_circle(muzzle, r, Color(0.85, 0.96, 1.0, 0.55 * c))


# =========================
# MUZZLE FLAME (Flarecaster — Mindustry Fx.shootSmallFlame)
# =========================

## Spits a short cone of flame particles out the muzzle at `pos`, fanning
## within ±_FLAME_SPREAD_DEG of `aim`. Mirrors Scorch's shootSmallFlame:
## 8 particles, random reach, that fan out, shrink, and recolour over ~0.5s.
func spawn_muzzle_flame(pos: Vector2, aim: float, reach: float = -1.0,
		count: int = _FLAME_COUNT, size_mult: float = 1.0,
		spread_bonus_deg: float = 0.0) -> void:
	var max_reach: float = reach if reach > 0.0 else float(main.GRID_SIZE) * 1.2
	var spread_deg: float = maxf(_FLAME_SPREAD_DEG + spread_bonus_deg, 0.0)
	for i in range(count):
		var ang: float = aim + deg_to_rad(randf_range(-spread_deg, spread_deg))
		_flame_particles.append({
			"pos0": pos,
			"ang": ang,
			"reach": max_reach * randf(),   # randLenVectors: random length per particle
			"age": 0.0,
			"life": 0.5 * randf_range(0.85, 1.15),
			"size": size_mult,
		})


# =========================
# MINDUSTRY BULLET FX (shoot / hit / despawn)
# =========================

## Shoot effect. Every turret gets the tapered flash cone (the "triangle").
## `full = true` adds the round bits — a hot core circle, drifting smoke
## puffs, spark lines and a flame burst — reserved for shotgun-style turrets
## like the Diffuse (driven by the ammo's `muzzle_flash_circles` flag).
## `scale` is the ammo's muzzle_flash_scale; 0 disables the effect entirely.
func spawn_shoot_fx(pos: Vector2, aim: float, scale: float, color: Color, full: bool = false) -> void:
	if scale <= 0.0 or main == null:
		return
	var gs: float = float(main.GRID_SIZE)
	# The flash cone is always drawn; `full` flags the core circle in the draw.
	_muzzle_flashes.append({
		"pos": pos, "ang": aim, "age": 0.0, "life": 0.16, "scale": scale, "color": color, "full": full,
	})
	if not full:
		return
	# Round extras — Diffuse only. Flame burst (proven render path) + smoke +
	# sparks.
	spawn_muzzle_flame(pos, aim, gs * 0.85 * scale, 7, scale * 1.15)
	var cone: float = deg_to_rad(16.0)
	for i in range(6):
		_bullet_smoke.append({
			"pos0": pos,
			"ang": aim + randf_range(-cone, cone),
			"reach": gs * 0.55 * scale * randf_range(0.45, 1.0),
			"age": 0.0, "life": randf_range(0.3, 0.5), "size": 0.95 * scale,
		})
	for i in range(5):
		_bullet_sparks.append({
			"pos": pos,
			"ang": aim + randf_range(-cone * 0.8, cone * 0.8),
			"len": gs * 0.28 * scale * randf_range(0.7, 1.3),
			"age": 0.0, "life": randf_range(0.16, 0.24), "color": color.lerp(Color(1, 0.9, 0.6, 1), 0.5),
		})


## Hit effect: short spark lines radiating from the impact point + a small
## smoke puff (Mindustry's Fx.hitBulletSmall). `scale` = impact_effect_scale.
func spawn_impact_fx(pos: Vector2, scale: float, color: Color) -> void:
	if scale <= 0.0 or main == null:
		return
	var gs: float = float(main.GRID_SIZE)
	for i in range(5):
		_bullet_sparks.append({
			"pos": pos,
			"ang": randf() * TAU,
			"len": gs * 0.17 * scale * randf_range(0.6, 1.2),
			"age": 0.0, "life": randf_range(0.13, 0.22), "color": color,
		})
	for i in range(2):
		_bullet_smoke.append({
			"pos0": pos,
			"ang": randf() * TAU,
			"reach": gs * 0.13 * scale * randf(),
			"age": 0.0, "life": randf_range(0.2, 0.32), "size": 0.7 * scale,
		})


## Despawn effect: a small fading expanding ring where a bullet expired at max
## range without hitting anything.
func spawn_despawn_fx(pos: Vector2, scale: float, color: Color) -> void:
	if scale <= 0.0:
		return
	_despawn_rings.append({
		"pos": pos, "age": 0.0, "life": 0.22, "scale": scale, "color": color,
	})


## Advance + prune the bullet-FX pools (age-based, like the flame particles).
func _update_bullet_fx(delta: float) -> void:
	for arr in [_muzzle_flashes, _bullet_sparks, _bullet_smoke, _despawn_rings]:
		var write := 0
		for read in range(arr.size()):
			var p: Dictionary = arr[read]
			p["age"] = float(p["age"]) + delta
			if float(p["age"]) < float(p["life"]):
				if write != read:
					arr[write] = p
				write += 1
		if write != arr.size():
			arr.resize(write)


## Draws all bullet FX on the projectile overlay `canvas` (above the bullets).
func _draw_bullet_fx(canvas: CanvasItem) -> void:
	var gs: float = float(main.GRID_SIZE) if main else 32.0
	# Smoke puffs: gray, drift outward, shrink + fade.
	for p in _bullet_smoke:
		var t: float = clampf(float(p["age"]) / maxf(float(p["life"]), 0.0001), 0.0, 1.0)
		var dist: float = float(p["reach"]) * sqrt(t)
		var spos: Vector2 = p["pos0"] + Vector2.from_angle(float(p["ang"])) * dist
		var fout: float = 1.0 - t
		var r: float = (0.55 + fout * 1.15) * gs * 0.03 * float(p.get("size", 1.0))
		var sc := _FLAME_GRAY
		sc.a = fout * 0.7
		canvas.draw_circle(spos, r, sc)
	# Muzzle flash: a hot white-yellow core + a bright tapered cone. Uses a
	# fixed warm flash colour (not the bullet colour) so it always reads as a
	# muzzle blast regardless of ammo tint.
	for p in _muzzle_flashes:
		var t: float = clampf(float(p["age"]) / maxf(float(p["life"]), 0.0001), 0.0, 1.0)
		var fout: float = 1.0 - t
		var msc: float = float(p["scale"])
		var fwd := Vector2.from_angle(float(p["ang"]))
		var side := Vector2(-fwd.y, fwd.x)
		var base: Vector2 = p["pos"]
		# Tapered flash cone (warm orange).
		var length: float = gs * 0.7 * msc * fout
		var width: float = gs * 0.2 * msc * fout
		canvas.draw_colored_polygon(PackedVector2Array([
			base + fwd * length, base + side * width, base - side * width,
		]), Color(1.0, 0.82, 0.4, fout * 0.9))
		# Hot near-white core right at the muzzle — only the "full" flash
		# (Diffuse) gets the round core; other turrets show just the cone.
		if bool(p.get("full", false)):
			canvas.draw_circle(base + fwd * gs * 0.12 * msc, gs * 0.13 * msc * fout, Color(1.0, 0.96, 0.78, fout))
	# Spark lines: short bright lines that extend then fade.
	for p in _bullet_sparks:
		var t: float = clampf(float(p["age"]) / maxf(float(p["life"]), 0.0001), 0.0, 1.0)
		var fout: float = 1.0 - t
		var dir := Vector2.from_angle(float(p["ang"]))
		var ln: float = float(p["len"]) * (0.4 + 0.6 * t)
		var spk: Color = (p["color"] as Color).lerp(_FLAME_GRAY, t).lerp(Color(1, 1, 1, 1), 0.3)
		spk.a = fout
		canvas.draw_line(p["pos"] + dir * (ln * 0.5), p["pos"] + dir * ln, spk, maxf(1.0, gs * 0.02 * fout), true)
	# Despawn rings: a faint expanding circle that fades out.
	for p in _despawn_rings:
		var t: float = clampf(float(p["age"]) / maxf(float(p["life"]), 0.0001), 0.0, 1.0)
		var fout: float = 1.0 - t
		var r: float = gs * 0.06 * float(p["scale"]) * (0.5 + t)
		var rc: Color = p["color"]
		rc.a = fout * 0.5
		canvas.draw_arc(p["pos"], r, 0.0, TAU, 16, rc, maxf(1.0, gs * 0.015 * fout), true)


## Flarecaster weapon tick: burns metered fuel and, while fuelled, sprays a
## flame jet out to `range_px` that damages + ignites every opposing unit
## inside the cone. The flame itself is the damage — no projectiles are fired.
func _select_affordable_flame_ammo(data: BlockData, anchor: Vector2i) -> AmmoType:
	for a in data.ammo_types:
		if not (a is AmmoType):
			continue
		var ammo := a as AmmoType
		if _has_turret_ammo(_logistics, anchor, ammo.item_id, float(maxi(ammo.amount_per_shot, 1))):
			return ammo
	return null


func _update_flame_emitter(grid_pos: Vector2i, data: BlockData, turret_world: Vector2,
		aim: float, range_px: float, faction: int, power_eff: float, delta: float) -> void:
	if power_eff <= 0.0 or range_px <= 0.0:
		return
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var ammo: AmmoType = _flame_active_ammo.get(grid_pos, null) as AmmoType
	# Fuel meter: burn `amount_per_shot` fuel every `attack_speed` seconds of
	# sustained firing. Between burns the flame runs on the already-paid tick.
	var interval: float = maxf(data.attack_speed, 0.05)
	var acc: float = float(_flame_fuel_acc.get(grid_pos, interval)) + delta * power_eff
	if acc >= interval:
		ammo = _select_affordable_flame_ammo(data, anchor)
		if ammo != null and _logistics and _consume_turret_ammo(_logistics, anchor, ammo.item_id, maxi(ammo.amount_per_shot, 1)):
			acc -= interval
			_flame_active_ammo[grid_pos] = ammo
		else:
			# Out of fuel — no flame this frame; stay "due" so it relights the
			# instant fuel arrives.
			_flame_fuel_acc[grid_pos] = interval
			_flame_active_ammo.erase(grid_pos)
			return
	if ammo == null:
		return
	_flame_fuel_acc[grid_pos] = acc

	# Spray the visible jet from the muzzle out to full range.
	var muzzle: Vector2 = turret_world + Vector2.from_angle(aim) * (float(main.GRID_SIZE) * 0.5)
	var range_bonus_px: float = ammo.flame_range_bonus_tiles * float(main.GRID_SIZE)
	var effective_range_px: float = range_px + range_bonus_px
	var cone_half_bonus_deg: float = ammo.flame_cone_width_bonus_degrees * 0.5
	spawn_muzzle_flame(muzzle, aim, effective_range_px, 6, 2.4, cone_half_bonus_deg)

	# The flame deals the damage: hit every opposing unit within range + cone.
	var unit_mgr := _unit_mgr_ref()
	if unit_mgr == null:
		return
	var src_team: int = UnitData.Team.PLAYER if faction == main.Faction.LUMINA else UnitData.Team.ENEMY
	var cone: float = deg_to_rad(_FLAME_CONE_DEG + cone_half_bonus_deg)
	var dps: float = ammo.damage
	var burn: Resource = ammo.status_effect
	for lst in [unit_mgr.enemies, unit_mgr.player_units]:
		for u in lst:
			if not is_instance_valid(u) or u.is_dead:
				continue
			if "team" in u and u.team == src_team:
				continue
			var to: Vector2 = u.position - muzzle
			var d: float = to.length()
			if d > effective_range_px + u.unit_size:
				continue
			if d > 1.0 and absf(wrapf(to.angle() - aim, -PI, PI)) > cone:
				continue
			u.take_damage(dps * delta)
			if burn != null and u.has_method("apply_status_effect"):
				u.apply_status_effect(burn)

	# Set opposing buildings the flame sweeps over alight (block-on-fire). We
	# sample a few rays through the cone rather than scanning every building.
	var fire_sys := _fire_sys_ref()
	if fire_sys != null and fire_sys.has_method("ignite_building"):
		var gs: float = float(main.GRID_SIZE)
		var seen: Dictionary = {}
		for ray_off in [-cone * 0.7, 0.0, cone * 0.7]:
			var rdir: Vector2 = Vector2.from_angle(aim + ray_off)
			var dist: float = gs * 0.5
			while dist <= effective_range_px:
				var cell: Vector2i = main.world_to_grid(muzzle + rdir * dist)
				if main.placed_buildings.has(cell):
					var b_anchor: Vector2i = main.building_origins.get(cell, cell)
					if not seen.has(b_anchor):
						seen[b_anchor] = true
						if main.get_building_faction(b_anchor) != faction:
							# force = true so the flame jet ignites walls too (a
							# flamethrower vs a wall); fireproof blocks still resist.
							fire_sys.ignite_building(b_anchor, true)
				dist += gs * 0.5

	# Detonate any oxygen cloud the flame cone sweeps through. The fire ignites
	# at the point where the cone enters the cloud and spreads from there.
	if not gas_clouds.is_empty():
		var aim_dir: Vector2 = Vector2.from_angle(aim)
		for key in gas_clouds:
			var oc: Dictionary = gas_clouds[key]
			if String(oc["type"]) != "oxygen" or bool(oc.get("ignited", false)):
				continue
			var ocr: float = float(oc["radius"])
			if ocr < 4.0:
				continue
			var to_c: Vector2 = (oc["center"] as Vector2) - muzzle
			var along: float = to_c.dot(aim_dir)          # distance along the cone axis
			if along < 0.0 or along > effective_range_px + ocr:
				continue
			if absf(to_c.cross(aim_dir)) > ocr:           # perpendicular distance to axis
				continue
			oc["ignited"] = true
			oc["fire_t"] = 0.0
			# Entry point: where the cone axis first reaches the cloud's near edge.
			oc["fire_origin"] = muzzle + aim_dir * maxf(along - ocr, 0.0)


func _update_flame_particles(delta: float) -> void:
	if _flame_particles.is_empty():
		return
	var write := 0
	for read in range(_flame_particles.size()):
		var p: Dictionary = _flame_particles[read]
		p["age"] = float(p["age"]) + delta
		if float(p["age"]) < float(p["life"]):
			if write != read:
				_flame_particles[write] = p
			write += 1
	if write != _flame_particles.size():
		_flame_particles.resize(write)


func _draw_flame_particles() -> void:
	if _flame_particles.is_empty():
		return
	var sz_scale: float = float(main.GRID_SIZE) * 0.035
	for p in _flame_particles:
		var t: float = clampf(float(p["age"]) / maxf(float(p["life"]), 0.0001), 0.0, 1.0)
		# Outward motion eases out (fast then slow), like finpow().
		var dist: float = float(p["reach"]) * sqrt(t)
		var pos: Vector2 = p["pos0"] + Vector2.from_angle(float(p["ang"])) * dist
		var fout: float = 1.0 - t
		var radius: float = (0.65 + fout * 1.6) * sz_scale * float(p.get("size", 1.0))
		# lightFlame → darkFlame → gray over the particle's life.
		var col: Color
		if t < 0.5:
			col = _FLAME_LIGHT.lerp(_FLAME_DARK, t * 2.0)
		else:
			col = _FLAME_DARK.lerp(_FLAME_GRAY, (t - 0.5) * 2.0)
		col.a = fout
		draw_circle(pos, radius, col)


func _on_building_placed(block_id: StringName, grid_pos: Vector2i) -> void:
	_combat_cache_dirty = true
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
	_combat_cache_dirty = true
	turret_cooldowns.erase(grid_pos)
	turret_angles.erase(grid_pos)
	turret_barrel_cooldowns.erase(grid_pos)
	turret_barrel_fire_flash.erase(grid_pos)
	turret_barrel_recoil.erase(grid_pos)
	turret_barrel_angles.erase(grid_pos)
	beam_states.erase(grid_pos)
	blaster_states.erase(grid_pos)


# =========================
# DRAWING
# =========================

func _draw() -> void:
	_draw_liquid_splashes()
	_draw_gas_clouds()
	_draw_beams()
	_draw_shockwaves()
	_draw_blaster_charges()
	_draw_turret_heads()
	_draw_flame_particles()
	# Projectiles render on `_projectile_overlay` (z_index 4095) so
	# they always sit above the chassis / buildings / terrain overlay,
	# regardless of how those siblings configure their own z_indices.
	# (The faint-red turret-range circle this used to call has been
	# replaced by BuildingSystem's dashed white indicator — kept the
	# function below for any external callers, but no longer drive it
	# from here.)

func _draw_turret_heads() -> void:
	var building_sys = _building_sys_ref()

	var _ss_turret = _sector_script_ref()
	# Launch-animation reveal: turrets the landing ring hasn't "built" yet
	# are hidden (their base isn't drawn either), so their heads must not
	# show floating over empty ground until the sweep reaches them.
	var _la_turret = _launch_anim_ref()
	# Iterate the cached turret-anchor list instead of scanning every placed
	# building each frame — on a large base that scan was O(all buildings)
	# with a Registry lookup per cell purely to discard non-turrets. The
	# cache already dedupes to anchors (derelict / under-construction
	# turrets included), and turret state + drawing are all anchor-keyed.
	_ensure_combat_cache()
	# Viewport cull: only heads near the camera can be seen. Mirrors the
	# building/item draw culling so off-screen turrets cost nothing.
	var vp_min: Vector2i = Vector2i(-2147483648, -2147483648)
	var vp_max: Vector2i = Vector2i(2147483647, 2147483647)
	var cam := get_viewport().get_camera_2d() if is_inside_tree() else null
	if cam != null:
		var cam_center: Vector2 = cam.get_screen_center_position()
		var vp_size: Vector2 = get_viewport_rect().size
		var cam_zoom: Vector2 = cam.zoom if cam.zoom != Vector2.ZERO else Vector2.ONE
		var half_view: Vector2 = vp_size / (2.0 * cam_zoom)
		# Generous margin so a large multi-tile turret whose anchor is just
		# off-screen still draws its head.
		vp_min = main.world_to_grid(cam_center - half_view) - Vector2i(4, 4)
		vp_max = main.world_to_grid(cam_center + half_view) + Vector2i(4, 4)

	for grid_pos in _turret_anchors:
		if grid_pos.x < vp_min.x or grid_pos.x > vp_max.x \
				or grid_pos.y < vp_min.y or grid_pos.y > vp_max.y:
			continue
		if _ss_turret and _ss_turret.is_tile_hidden(grid_pos):
			continue
		if _la_turret and _la_turret.has_method("is_block_hidden") and _la_turret.is_block_hidden(grid_pos):
			continue

		var block_id = main.placed_buildings.get(grid_pos, &"")
		var data = Registry.get_block(block_id)
		if data == null or not data.is_turret():
			continue

		var world_pos = main.grid_to_world(grid_pos)
		var center = world_pos + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)

		# Apply the same parallax offset as buildings
		var offset = Vector2.ZERO
		if building_sys:
			offset = building_sys._get_top_offset(world_pos)
		center += offset

		# Default static angle = placement rotation, so inactive
		# turrets read as facing whichever direction they were placed.
		var angle: float = float(turret_angles.get(
			grid_pos,
			float(main.building_rotation.get(grid_pos, 0)) * (PI / 2.0),
		))

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

		# Draw trail — Mindustry-style tapered fade in the ammo's trail colour
		# (falls back to the bullet colour). Width + alpha both ramp from the
		# tail toward the head so it reads as a comet streak.
		var tc: Color = proj.get("trail_color", color)
		var trail = proj["trail"] as Array
		if trail.size() > 1:
			for t in range(trail.size() - 1):
				var f: float = float(t + 1) / float(trail.size())
				var seg_col := Color(tc.r, tc.g, tc.b, f * 0.55)
				canvas.draw_line(trail[t], trail[t + 1], seg_col, maxf(0.75, radius * f), true)

		# Bridge the last trail point to the live position (brightest segment).
		if trail.size() > 0:
			canvas.draw_line(trail[trail.size() - 1], pos, Color(tc.r, tc.g, tc.b, 0.6), radius * 0.85, true)

		var sprite: Texture2D = proj.get("projectile_sprite", null)
		if sprite != null:
			# Sprite-based projectile (Protium missile): draw the texture
			# rotated to face its travel direction. Use the trail's last
			# segment for heading, falling back to the vector toward target.
			var heading: Vector2 = pos - trail[trail.size() - 1] if trail.size() > 0 else proj["target_pos"] - pos
			var ang: float = heading.angle() if heading.length_squared() > 0.0001 else 0.0
			var tex_size: Vector2 = sprite.get_size()
			# Scale the sprite so its length matches ~16x the projectile radius.
			var scale: float = (radius * 16.0) / maxf(tex_size.x, 1.0)
			canvas.draw_set_transform(pos, ang + PI / 2.0, Vector2(scale, scale))
			canvas.draw_texture(sprite, -tex_size / 2.0)
			canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		elif bool(proj.get("liquid", false)):
			# Liquid-bullet orb: a flat fluid blob, the liquid's colour blended
			# a touch toward white over its life (no energy-glow core). A soft
			# translucent rim sells the wet, rounded look.
			var fout: float = clampf(1.0 - float(proj.get("age", 0.0)) / maxf(float(proj.get("lifetime", 1.0)), 0.0001), 0.0, 1.0)
			var orb: Color = color.lerp(Color.WHITE, fout * 0.18)
			canvas.draw_circle(pos, radius + 1.5, Color(color.r, color.g, color.b, 0.25))
			canvas.draw_circle(pos, radius, orb)
		else:
			# Mindustry BasicBulletType feel: a darker stretched back layer with
			# a smaller bright front layer, both oriented along travel and
			# shrinking lengthwise as the bullet nears the end of its life.
			var heading: Vector2 = Vector2.ZERO
			if trail.size() > 0:
				heading = pos - trail[trail.size() - 1]
			if heading.length_squared() < 0.01:
				heading = proj["target_pos"] - pos
			var bdir: Vector2 = heading.normalized() if heading.length_squared() > 0.0001 else Vector2.RIGHT
			var bperp: Vector2 = Vector2(-bdir.y, bdir.x)
			var front_col: Color = proj.get("front_color", color)
			var back_col: Color = proj.get("back_color", color.darkened(0.35))
			var life: float = maxf(float(proj.get("lifetime", 1.0)), 0.0001)
			var fout: float = clampf(1.0 - float(proj.get("age", 0.0)) / life, 0.0, 1.0)
			var shrink_y: float = clampf(float(proj.get("shrink_y", 0.5)), 0.0, 1.0)
			var width: float = float(proj.get("visual_width", 0.0))
			var height: float = float(proj.get("visual_height", 0.0))
			if width <= 0.0:
				width = radius * 1.9
			if height <= 0.0:
				height = radius * 4.2
			height *= (1.0 - shrink_y) + shrink_y * fout
			width = maxf(width, 1.0)
			height = maxf(height, width * 1.25)
			var half_w: float = width * 0.5
			var half_h: float = height * 0.5
			var tip: Vector2 = pos + bdir * half_h
			var tail: Vector2 = pos - bdir * half_h
			var side_a: Vector2 = pos + bperp * half_w
			var side_b: Vector2 = pos - bperp * half_w
			canvas.draw_circle(pos, width * 0.85, Color(back_col.r, back_col.g, back_col.b, 0.16))
			canvas.draw_colored_polygon(PackedVector2Array([tip, side_a, tail, side_b]), back_col)

			var front_half_w: float = half_w * 0.62
			var front_half_h: float = half_h * 0.72
			var front_center: Vector2 = pos + bdir * (half_h * 0.05)
			canvas.draw_colored_polygon(PackedVector2Array([
				front_center + bdir * front_half_h,
				front_center + bperp * front_half_w,
				front_center - bdir * front_half_h,
				front_center - bperp * front_half_w,
			]), front_col)

		if main and main.show_hitboxes:
			canvas.draw_arc(pos, radius, 0, TAU, 24, Color(1.0, 0.2, 0.9, 0.9), 1.5)
			var aoe_r: float = float(proj.get("aoe_radius", 0.0))
			if aoe_r > 0.0:
				canvas.draw_arc(pos, aoe_r, 0, TAU, 48, Color(1.0, 0.5, 0.0, 0.7), 1.0)

	# Shoot / hit / despawn FX on the same overlay, above the bullets.
	_draw_bullet_fx(canvas)

	# Arc lightning bolts — jagged polyline, fading over its short lifetime.
	# Drawn as a wide soft glow, a mid stroke, and a thin white core.
	for bolt in _lightning_bolts:
		var pts: PackedVector2Array = bolt["points"]
		if pts.size() < 2:
			continue
		var fade: float = clampf(1.0 - float(bolt["age"]) / maxf(float(bolt["lifetime"]), 0.0001), 0.0, 1.0)
		var bc: Color = bolt["color"]
		canvas.draw_polyline(pts, Color(bc.r, bc.g, bc.b, fade * 0.25), 6.0)
		canvas.draw_polyline(pts, Color(bc.r, bc.g, bc.b, fade * 0.7), 2.5)
		canvas.draw_polyline(pts, Color(1.0, 1.0, 1.0, fade), 1.0)
