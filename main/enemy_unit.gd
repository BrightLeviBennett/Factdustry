extends Node2D
class_name EnemyUnit

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
## Ground/crawler Thruster command toggle. Hover/flying units get their
## Thruster speed passively in `recompute_module_stats`; ground units use
## this explicit boost command instead.
var thruster_boost_enabled: bool = false
## When the player right-clicks a payload-accepting block (typically a
## deconstructor) with `enter_payload_when_able` enabled, this anchor
## is latched so the unit will path adjacent to that specific block
## and hand itself off as soon as it's touching the footprint — even
## if the unit is too large to physically stand on the block. Cleared
## on successful ingestion, on death, on a new move/attack order, or
## when the building disappears.
var payload_target_anchor: Vector2i = Vector2i(-9999, -9999)
## Upgrade modules applied to this unit instance (block ids). Slot capacity
## comes from `data.upgrade_slots()`; free slots = capacity - this size.
## Carried through unit payloads (crane / refit / upgrader) and restored on
## re-spawn. A Payload Refit Bay strips these back out; the Deconstructor
## refunds each one's build cost on top of the unit's.
var applied_upgrades: Array[StringName] = []
var unit_shield_health: float = 0.0
var unit_shield_max_health: float = 0.0
var unit_shield_cooldown: float = 0.0
var unit_shield_visual_scale: float = 0.0
## Dummy test unit (spawned ENEMY/Ferox by a Payload Source). Runs NO
## autonomous AI — it sits inert until the player selects it and issues a
## command. `dummy_mode`: "idle" (obey move orders only), "attack_block"
## (path to + attack the nearest Lumina building), or "attack_player"
## (path to + attack the Lumina core). Attacks use the normal Ferox
## projectile path so they actually damage Lumina blocks.
var is_dummy := false
var dummy_mode := "idle"
var _dummy_repath_accum := 0.0
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

# --- BOTTLENECK YIELD / OSCILLATION BREAK (legacy; no longer set since
# separation moved to the Mindustry penetration model in `_apply_separation`) ---
# Was set when this unit lost a same-direction
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

# --- WEAPON MOUNTS (Mindustry-style) ---
# Per-instance live state for each mounted weapon, built from
# `data.weapons` at spawn (see `_setup_weapon_mounts`). Each entry is a
# Dictionary:
#   weapon: WeaponData    the stateless definition
#   offset: Vector2       local mount offset (mirror copies have x negated)
#   muzzle: Vector2       local muzzle offset (mirror copies have x negated)
#   flip:   bool          sprite drawn mirrored
#   side:   bool          fire-alternation side flag
#   other:  int           index of the mirror partner (or -1)
#   reload: float         seconds until ready (counts down)
#   rotation: float       current mount aim angle (radians, world space)
#   recoil: float         current recoil amount (px, decays to 0)
# Empty when the unit's .tres lists no weapons → legacy attack path.
var _weapon_mounts: Array = []

# --- FACING ANGLE (body/chassis rotation) ---
# Smoothly tracks the unit's movement direction, mirroring how the shardling
# rotates its sprite to face where it's going. Used to rotate base_sprite.
var facing_angle: float = 0.0
var _prev_position: Vector2 = Vector2.ZERO
var _facing_initialized: bool = false
# Smoothed world velocity (px/sec), updated each frame from displacement. Read
# by CombatSystem to lead this unit when aiming projectile turrets.
var velocity: Vector2 = Vector2.ZERO
var _vel_prev_pos: Vector2 = Vector2.ZERO
var _vel_initialised: bool = false

# --- WATER SUBMERSION ---
# Tracks how long a ground/crawler unit has been standing in water. Used for
# visual tint and the drowning damage-over-time. Reset to 0 while out of water.
var _water_time: float = 0.0
## Seconds a ground/crawler unit can spend in water before it drowns and dies.
const WATER_DROWN_TIME := 8.0

# --- NAVAL WATER WAKE (faithful port of Mindustry's WaterMoveComp + Trail) ---
# Two tapering trail ribbons, one per side. Each ribbon is a flat history
# buffer of (x, y, w) triples — w is 1 while that side is over liquid and the
# unit is on the water, 0 otherwise (a 0-width point makes that segment
# invisible, so a hull half on land gets an asymmetric wake, exactly like
# Mindustry). New points are spawned at ±waveTrailX (rotated by the hull
# heading) so the ribbon BENDS as the unit turns. Drawn on a low-z child
# canvas so the wake sits in the water UNDER the hull (Mindustry: Layer.debris).
# Trail math mirrors mindustry/graphics/Trail.java verbatim (update + draw).
var _wake_left: PackedFloat32Array = PackedFloat32Array()   # [x,y,w, x,y,w, ...]
var _wake_right: PackedFloat32Array = PackedFloat32Array()
# Per-trail "last" state used by the counter-based point insertion + the
# end-cap segment, matching Trail.java's lastX/lastY/lastW/lastAngle/counter.
var _wl_last := Vector3(-1.0, -1.0, 0.0)   # (lastX, lastY, lastW)
var _wr_last := Vector3(-1.0, -1.0, 0.0)
var _wl_lastangle: float = -1.0
var _wr_lastangle: float = -1.0
var _wl_counter: float = 0.0
var _wr_counter: float = 0.0
# Wake colour. Mindustry's WaterMoveComp eases this toward the current water
# tile's map colour ×1.5 every frame (so the wake reads blue on water, yellow-
# green over sulfur water, etc.). Starts at, and falls back to, the default
# water tint (HEX 7b91ad = water.tres colour ×1.5) when a tile has no map colour.
# Only RGB is eased; alpha (0.65) is left fixed for the foam translucency.
var _wake_color := Color("7b91ad", 0.65)
const _WAKE_FALLBACK_RGB := Color("7b91ad")
const _WAKE_COLOR_MUL := 1.5
var _wake_enabled: bool = false
# Foam ring puffs trailing the stern (drawn as expanding circle OUTLINES).
# Each: {pos: Vector2, age: float, r: float}. Stored in world space.
var _wake_foam: Array = []
var _wake_foam_accum: float = 0.0
# Smoothed heading used for the wake origin, so a jittery chassis facing
# doesn't carve a zig-zag trail. -999 = uninitialised (seed to live facing).
var _wake_angle: float = -999.0
const _WAKE_FOAM_LIFE := 0.7        # seconds a foam ring lives
const _WAKE_FOAM_INTERVAL := 0.10   # seconds between foam rings while moving
## Mindustry advances the trail counter by Time.delta (ticks at 60 fps), so a
## point is added roughly once per 60 fps frame. We feed delta×60 to match.
const _MINDUSTRY_TPS := 60.0

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
# --- Unit separation (Mindustry PhysicsProcess `scl`) ---
## Under-relaxation divisor for overlap correction. Each frame a pair only
## resolves penetration ÷ SEP_RELAX of its overlap, so they ease apart and
## settle instead of overshooting. Mindustry uses 1.25; raise for gentler/
## floatier, lower (toward 1.0) for snappier.
const SEP_RELAX := 1.25
const REPATH_COOLDOWN := 1.0 # Per-unit floor on repath spam
# Throttle for the wall-overlap rescue. Cheap enough we could do it
# every tick but no need — a unit "phasing" into a wall via a building
# placement is a rare event.
var _wall_check_timer: float = 0.0
const WALL_CHECK_INTERVAL := 0.5
# Sub-cell "wedge" rescue. A crane can drop a unit so its CENTRE sits on a
# legal cell but its BODY overlaps an adjacent solid (a water edge for a naval
# unit, a wall face for a ground unit). The centre-point walkability test
# passes, so the normal wall-overlap rescue never fires — yet `resolve_move`
# blocks every step that would push the overlapping face deeper, so the unit
# can't walk out. We detect this with the radius-aware circle test and, once
# the unit has been wedged (and stationary) for WEDGE_RESCUE_TIME, snap it back
# into open space. The short delay avoids yanking a unit that's merely grazing
# a wall corner for a frame mid-move.
var _wedge_timer: float = 0.0
const WEDGE_RESCUE_TIME := 0.5

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
	# `no_pathfinding` blocks (sources, archive, …) are never targeted by
	# any unit — they're invisible to combat/target selection.
	var bdata = Registry.get_block(main.placed_buildings[grid_pos])
	if bdata != null and bdata.tags.has("no_pathfinding"):
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
	# Fold in any module upgrades this unit was spawned with (no-op when the
	# list is empty; re-run by the spawn/restore paths after upgrades load).
	recompute_module_stats()
	# Build the live weapon mounts from the unit's weapon list (no-op when
	# the .tres lists none — those units use the legacy single-shot path).
	_setup_weapon_mounts()
	# Naval wake: enabled flag only — the trail is painted directly in the
	# unit's own `_draw()` (the proven path the flying shadow uses), so no
	# separate canvas node is needed.
	if data and data.movement_layer == UnitData.MovementLayer.NAVAL and data.trail_length > 0:
		_wake_enabled = true


## Recomputes the cached, per-instance stats (move speed, fire-rate cooldown,
## max health) from the base UnitData plus `applied_upgrades`. Idempotent —
## always derives from `data`, so it can be re-run whenever the upgrade list
## changes. Stats that the game reads straight off the shared `data` resource
## (attack_range, armor, turn speeds, knockback) and most behaviour-based
## modules (afterburner boost, healing drones, cloaking, missiles, siege
## lock) are wired separately. Shield Emitter refreshes its derived HP here.
func recompute_module_stats() -> void:
	if data == null:
		return
	var spd_mult := 1.0
	var fire_rate_mult := 1.0
	var hp_mult := 1.0
	var ml: int = data.movement_layer
	var has_armor_plate := false
	for up in applied_upgrades:
		match up:
			&"thruster":
				# +125% speed for hover/flying units (ground "boost" is a
				# behaviour handled elsewhere).
				if ml == UnitData.MovementLayer.HOVER or ml == UnitData.MovementLayer.FLYING:
					spd_mult *= 2.25
			&"lift_engine":
				spd_mult *= 0.75            # -25% speed
			&"command_beacon":
				spd_mult *= 0.75            # -25% speed while providing command aura behavior
			&"healing_turret_head":
				spd_mult *= 0.5             # 2× slower
			&"cooling_system":
				fire_rate_mult += 1.25      # +125% fire rate per apply
			&"resistant_plating":
				hp_mult *= 0.9              # -10% max HP per apply
			&"armor_plate":
				has_armor_plate = true
	if has_armor_plate:
		hp_mult *= 1.25                     # +25% max HP (first apply only)
	move_speed = data.move_speed * float(main.GRID_SIZE) * spd_mult
	attack_cooldown = data.attack_speed / maxf(0.01, fire_rate_mult)
	var new_max: float = data.max_health * hp_mult
	if not is_equal_approx(new_max, max_health):
		max_health = new_max
		if health > max_health:
			health = max_health
	_recompute_unit_shield_stats()


func can_thruster_boost() -> bool:
	if data == null:
		return false
	var ml: int = data.movement_layer
	if ml != UnitData.MovementLayer.GROUND and ml != UnitData.MovementLayer.CRAWLER:
		return false
	return applied_upgrades.has(&"thruster")


## Applies a status effect to this unit, honouring opposites
## (canceling both effects) and affinities (boosting both effects'
## modifier magnitudes). If neither relation applies, the effect is
## just added/refreshed.
func apply_status_effect(effect: StatusEffectData, duration_override: float = -1.0) -> void:
	if effect == null or effect.id == &"":
		return
	# Source-specific duration (e.g. corroding lasts 8s from an acid blob but
	# 6s from a fume cloud). Falls back to the resource's own `duration`.
	var dur: float = duration_override if duration_override > 0.0 else effect.duration
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
		active_statuses[effect.id]["time_left"] = dur
		if effect.stackable:
			active_statuses[effect.id]["stacks"] = mini(int(active_statuses[effect.id]["stacks"]) + 1, effect.max_stacks)
	else:
		active_statuses[effect.id] = {
			"effect": effect,
			"time_left": dur,
			"stacks": 1,
			"boost": boost_new,
			"dot_acc": 0.0,
		}


## Puts out this unit's fire — clears the Burning status. Used by the Spritz
## turret's water firefighting. Returns true if the unit was burning.
func douse() -> bool:
	if active_statuses.has(&"burning"):
		active_statuses.erase(&"burning")
		return true
	return false


## True if this unit is currently on fire (has the Burning status).
func is_burning() -> bool:
	return active_statuses.has(&"burning")


## Aggregate multiplier for a status-effect stat field across every active
## status (e.g. &"aim_speed_modifier", &"attack_speed_modifier"). Mirrors the
## move-speed stacking in _follow_path: each status amplifies its deviation
## from 1.0 by its affinity `boost`, and the product is floored so a stack of
## debuffs can't drop a stat to zero.
func _status_stat_mult(field: StringName) -> float:
	if active_statuses.is_empty():
		return 1.0
	var m: float = 1.0
	for sid in active_statuses:
		var ent: Dictionary = active_statuses[sid]
		var se: StatusEffectData = ent["effect"]
		if se == null:
			continue
		var base_mod: float = float(se.get(field))
		if base_mod != 1.0:
			var boost: float = float(ent.get("boost", 1.0))
			m *= maxf(1.0 + (base_mod - 1.0) * boost, 0.05)
	return m


func _tick_status_effects(delta: float) -> void:
	if active_statuses.is_empty():
		return
	var expire: Array = []
	var dot_total: float = 0.0
	for sid in active_statuses:
		var ent: Dictionary = active_statuses[sid]
		ent["time_left"] = float(ent["time_left"]) - delta
		if float(ent["time_left"]) <= 0.0:
			expire.append(sid)
			continue
		var se: StatusEffectData = ent["effect"]
		# DoT tick — `tick_damage` dealt once every `tick_interval` seconds.
		# Per-status accumulator so arbitrary intervals work (a shared 0.5s
		# accumulator silently dropped any interval longer than 0.5s).
		if se != null and se.tick_damage > 0.0 and se.tick_interval > 0.0:
			var acc: float = float(ent.get("dot_acc", 0.0)) + delta
			while acc >= se.tick_interval:
				acc -= se.tick_interval
				dot_total += se.tick_damage * float(ent.get("stacks", 1)) * float(ent.get("boost", 1.0))
			ent["dot_acc"] = acc
	for sid in expire:
		active_statuses.erase(sid)
	# DoT bypasses armor (it's already inside the unit) but must still kill.
	if dot_total > 0.0 and not is_dead:
		health -= dot_total
		if health <= 0.0:
			is_dead = true
			var asys = main.get_node_or_null("AudioSystem")
			if asys:
				asys.play("unit_die", position)
			_on_death()


func _has_module(module_id: StringName) -> bool:
	if applied_upgrades.has(module_id):
		return true
	if module_id == &"shield_emitter":
		return applied_upgrades.has(&"shield_emmiter")
	if module_id == &"shield_emmiter":
		return applied_upgrades.has(&"shield_emitter")
	return false


func _recompute_unit_shield_stats() -> void:
	var old_max: float = unit_shield_max_health
	if not _has_module(&"shield_emitter"):
		unit_shield_max_health = 0.0
		unit_shield_health = 0.0
		unit_shield_cooldown = 0.0
		unit_shield_visual_scale = 0.0
		return
	unit_shield_max_health = float(_unit_shield_stats_for_tier()["health"])
	if unit_shield_health <= 0.0 or old_max <= 0.0:
		unit_shield_health = unit_shield_max_health
	else:
		unit_shield_health = minf(unit_shield_health, unit_shield_max_health)


func _unit_shield_stats_for_tier() -> Dictionary:
	var tier: int = clampi(int(data.tier) if data != null else 1, 1, 5)
	match tier:
		1:
			return {"range_tiles": 3.5, "health": 400.0}
		2:
			return {"range_tiles": 4.5, "health": 500.0}
		3:
			return {"range_tiles": 6.0, "health": 650.0}
		4:
			return {"range_tiles": 8.0, "health": 950.0}
		_:
			return {"range_tiles": 11.0, "health": 1300.0}


func _unit_shield_radius() -> float:
	return float(main.GRID_SIZE) * float(_unit_shield_stats_for_tier()["range_tiles"])


func _unit_shield_is_stationary() -> bool:
	return velocity.length() <= float(main.GRID_SIZE) * 0.12


func has_active_unit_shield() -> bool:
	return _has_module(&"shield_emitter") \
		and unit_shield_health > 0.0 \
		and unit_shield_cooldown <= 0.0 \
		and _unit_shield_is_stationary()


func unit_shield_intercept(prev_pos: Vector2, next_pos: Vector2, source_team: int) -> Dictionary:
	if source_team == team:
		return {}
	if not has_active_unit_shield():
		return {}
	var radius: float = _unit_shield_radius()
	if prev_pos.distance_to(position) <= radius:
		return {}
	var closest: Vector2 = Geometry2D.get_closest_point_to_segment(position, prev_pos, next_pos)
	if closest.distance_to(position) <= radius:
		return {"unit": self, "hit_pos": closest}
	return {}


func apply_unit_shield_damage(amount: float) -> void:
	if unit_shield_health <= 0.0:
		return
	unit_shield_health = maxf(0.0, unit_shield_health - amount)
	if unit_shield_health <= 0.0:
		unit_shield_cooldown = 8.0
		unit_shield_visual_scale = 0.0


func _tick_unit_shield(delta: float) -> void:
	if not _has_module(&"shield_emitter"):
		return
	if unit_shield_max_health <= 0.0:
		_recompute_unit_shield_stats()
	if unit_shield_health <= 0.0:
		if unit_shield_cooldown > 0.0:
			unit_shield_cooldown = maxf(0.0, unit_shield_cooldown - delta)
		if unit_shield_cooldown <= 0.0:
			unit_shield_health = unit_shield_max_health
	var target: float = 1.0 if has_active_unit_shield() else 0.0
	unit_shield_visual_scale = move_toward(unit_shield_visual_scale, target, delta * 8.0)


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
	# Track a smoothed world velocity (last frame's displacement) so turrets can
	# lead this unit when aiming — see CombatSystem._intercept_point.
	if not _vel_initialised:
		_vel_prev_pos = position
		_vel_initialised = true
	velocity = (position - _vel_prev_pos) / maxf(delta, 0.0001)
	_vel_prev_pos = position
	_tick_status_effects(delta)
	_tick_unit_shield(delta)
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
		# Wake BEFORE facing tick (which consumes the movement delta via
		# `_prev_position`).
		_tick_water_wake(delta)
		_tick_facing_angle(delta)
		# Mounted weapons track the mouse cursor while the player drives the
		# unit (that's where its shots will land). aim_only = true: the heads
		# rotate + reload but DON'T auto-fire — the player's fire input
		# (handled in unit_manager._update_controlled_unit) pulls the trigger.
		if has_weapon_mounts():
			_tick_weapon_mounts(delta, get_global_mouse_position(), true)
		queue_redraw()
		return
	if data and team == UnitData.Team.PLAYER:
		_player_update(delta)
	elif is_dummy:
		# Inert test unit — only acts on explicit player commands.
		_dummy_update(delta)
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
	# Wake BEFORE facing tick (which consumes the movement delta via
	# `_prev_position`).
	_tick_water_wake(delta)
	_tick_facing_angle(delta)
	# Mount-driven combat: units with weapons fire through their mounts
	# each frame, aiming at whatever target the AI above already resolved.
	# (The legacy single-shot path is suppressed for these units — see
	# `_try_attack` / `_try_player_combat`.)
	if has_weapon_mounts():
		_tick_weapon_mounts(delta, _current_aim_world())
	queue_redraw()


## The world-space point the weapon mounts should aim at this frame, or null
## when the unit has nothing to shoot. Prefers a live unit target, then a
## targeted building. Reuses the same target fields the AI / targeting
## worker already populate, so mounts shoot whatever the unit is engaging.
func _current_aim_world() -> Variant:
	if target_unit != null and is_instance_valid(target_unit) and not target_unit.is_dead:
		return target_unit.position
	if target_building != null and main.placed_buildings.has(target_building):
		return main.grid_to_world(target_building) + Vector2(main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5)
	# Repair / point-defense weapons act on their own scan, not a combat
	# target — give them a sentinel aim (the unit's own position) so their
	# fire gate (reload only) still triggers. Pure-turret units return null
	# and simply hold fire.
	for m in _weapon_mounts:
		var w: WeaponData = m["weapon"]
		if w.behavior != WeaponData.Behavior.TURRET:
			return position
	return null


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
	# Aim-speed status effects (Crystallized / Tarred) slow how fast the head
	# swings onto a target.
	var turn_speed: float = (data.head_turn_speed if data else 3.0) * _status_stat_mult(&"aim_speed_modifier")
	aim_angle = _rotate_toward(aim_angle, desired, turn_speed * delta)


## Rotates `from` toward `to` by at most `max_step` radians. Unlike lerp_angle
## this moves at a constant speed (matching the crane arm), so heavy units
## feel mechanical rather than magnetized to their target.
func _rotate_toward(from: float, to: float, max_step: float) -> float:
	var diff: float = wrapf(to - from, -PI, PI)
	if absf(diff) <= max_step:
		return to
	return wrapf(from + signf(diff) * max_step, -PI, PI)


## One step of tank-style locomotion (Mindustry `rotateMove` model).
##
## `desired_face` is the world-space angle we want to drive toward.
## `forward_step` is the distance the tank can cover this frame (pixels).
## `waypoint` / `dist_to_waypoint` are optional: when dist_to_waypoint > 0,
## the helper honors path-waypoint snapping/advancement. Pass 0 when there
## is no path (manual control).
##
## Behaviour — copied from Mindustry's `UnitComp.rotateMove`:
##   The tank ALWAYS thrusts along its CURRENT facing (never the target
##   direction), while simultaneously rotating its facing toward
##   `desired_face` at `body_turn_speed`. Because thrust points along the
##   body and the body sweeps toward the goal, the path is a smooth ARC —
##   the unit never stops to pivot in place. When the heading error is
##   large the forward thrust is scaled down (so a tank facing ~backwards
##   barely creeps while it swings around) but never fully stops, matching
##   the emergent `cos(error)`-ish slowdown Mindustry gets from drag.
##   `turn_radius` is no longer used (the arc emerges from the turn rate vs
##   forward speed); it's kept on the data model for authoring back-compat.
func _tank_steer_step(desired_face: float, forward_step: float, waypoint: Vector2, dist_to_waypoint: float) -> void:
	var turn_speed: float = data.body_turn_speed if data and data.body_turn_speed > 0.0 else 2.0
	var ml_walk: int = data.movement_layer if data else 0
	# Radius-aware face test (matches the omni resolver) so a tank's flank
	# can't clip into a wall. Tanks are locked to their facing axis (no free
	# slide), so a blocked step is simply rejected while rotation continues.
	var step_walkable := func(p: Vector2) -> bool:
		return unit_manager == null \
			or unit_manager.is_circle_walkable(p, unit_size, ml_walk, team)

	# 1) Rotate the chassis toward the desired heading (always, every frame).
	facing_angle = _rotate_toward(facing_angle, desired_face, turn_speed * get_process_delta_time())

	# 2) Thrust at FULL speed along the current (post-rotation) facing — NOT
	#    scaled by how aligned we are. This is the load-bearing line from
	#    Mindustry's `rotateMove`: the tank always drives forward, and the
	#    arc emerges because the heading sweeps toward the goal while the
	#    body keeps rolling. The radius of that arc is `speed / turn_rate`,
	#    so a WIDER arc comes from a LOWER `body_turn_speed` (a higher turn
	#    speed pins the tank into a tight spin — the bug you saw). The old
	#    cos(err) scaling zeroed thrust past 90°, which is exactly the
	#    "one side pinned, spinning in place" feel; removed.
	var err: float = absf(wrapf(desired_face - facing_angle, -PI, PI))
	var moved: bool = false

	if forward_step <= 0.0:
		# No forward budget this frame (e.g. paused movement) — rotation only.
		_tank_track_blocked(false)
		return

	# Anti-orbit waypoint advance. A tank thrusting at full speed while
	# turning at `turn_speed` has a minimum turning-circle radius of
	# `move_speed / turn_speed`. If a waypoint is closer than that, the tank
	# physically CAN'T curve tight enough to land on it and would orbit it
	# forever (the "spins in circles for ages" bug). So once we're within a
	# generous proximity (≈ the turning radius), consider the waypoint
	# reached and advance to the next — the tank then re-aims further down
	# the path and gets pulled along instead of circling. This is normal
	# path-following lookahead; corner-cutting on open water is fine.
	if dist_to_waypoint > 0.0:
		var arc_radius: float = move_speed / maxf(turn_speed, 0.05)
		var advance_tol: float = maxf(unit_size, arc_radius * 0.85)
		# Don't skip the FINAL waypoint by proximity — the arrival check in
		# `_follow_path` handles stopping there; skipping it would leave the
		# unit drifting past its destination.
		var is_final: bool = path_index >= path.size() - 1
		if not is_final and dist_to_waypoint <= advance_tol:
			path_index += 1
			moved = true   # progress — re-aim next frame
		elif forward_step >= dist_to_waypoint and step_walkable.call(waypoint):
			# Swept hop to the waypoint (no raw snap → no tunnelling).
			if unit_manager != null:
				position = unit_manager.resolve_move(position, waypoint - position, unit_size, ml_walk, team)
			else:
				position = waypoint
			path_index += 1
			moved = true

	if not moved:
		var fwd: Vector2 = Vector2.RIGHT.rotated(facing_angle)
		# Swept forward thrust — stops at a wall so a fast tank can't tunnel.
		var newp: Vector2 = position
		if unit_manager != null:
			newp = unit_manager.resolve_move(position, fwd * forward_step, unit_size, ml_walk, team)
		else:
			var cand: Vector2 = position + fwd * forward_step
			if step_walkable.call(cand):
				newp = cand
		if newp.distance_squared_to(position) > 0.0001:
			position = newp
			moved = true

	# Rotating-toward-goal still counts as progress (not stuck) so a tank
	# swinging around a corner doesn't trigger the repath timer.
	if not moved and err > deg_to_rad(8.0):
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
	# Hover (2) and Flying (3) ignore water entirely. Naval (4) LIVES in
	# water — it never drowns (and can't leave the water anyway).
	var ml: int = data.movement_layer
	if ml == UnitData.MovementLayer.HOVER or ml == UnitData.MovementLayer.FLYING \
			or ml == UnitData.MovementLayer.NAVAL:
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


## Per-frame naval wake update — faithful port of Mindustry's
## `WaterMoveComp.update`. For each side: compute the spawn point at
## (±waveTrailX, waveTrailY) rotated by the hull heading (so the ribbon
## curves on turns), and feed it to that side's trail with width 1 when
## that exact point is over navigable water (else 0). No-op for non-naval.
## True when the unit (plus a generous trail-length margin) is within the
## camera view — used to skip the expensive wake DRAW for off-screen units.
## The tick keeps running regardless so the ribbon stays continuous when the
## unit scrolls back into view.
func _wake_on_screen() -> bool:
	var cam := get_viewport().get_camera_2d() if is_inside_tree() else null
	if cam == null:
		return true
	var vp: Vector2 = get_viewport_rect().size
	var zoom: Vector2 = cam.zoom if cam.zoom != Vector2.ZERO else Vector2.ONE
	var half: Vector2 = vp / (2.0 * zoom)
	var c: Vector2 = cam.get_screen_center_position()
	# Margin = trail span + a tile, so a long wake trailing onto screen from
	# an off-screen unit still draws.
	var margin: float = float(data.trail_length) * 4.0 + main.GRID_SIZE
	var d: Vector2 = (position - c).abs()
	return d.x <= half.x + margin and d.y <= half.y + margin


func _tick_water_wake(delta: float) -> void:
	if not _wake_enabled or data == null or data.trail_length <= 0:
		return
	var wtx: float = data.wave_trail_x
	var wty: float = data.wave_trail_y
	# Smooth the heading used for the trail origin so a jittery (tank-steered)
	# chassis that rapidly wobbles its facing doesn't carve a zig-zag wake.
	# Ease the wake's reference angle toward the live facing.
	if _wake_angle == -999.0:
		_wake_angle = facing_angle
	_wake_angle = _rotate_toward(_wake_angle, facing_angle, 6.0 * delta)
	var rot_off: float = _wake_angle - PI / 2.0   # local +y = forward
	for side in range(2):
		var sgn: float = -1.0 if side == 0 else 1.0
		var p: Vector2 = position + Vector2(wtx * sgn, wty).rotated(rot_off)
		# Naval units are always on water, so the trail is always live
		# (width 1). No per-point water gate — that's only meaningful for
		# amphibious units that leave the water, which these can't.
		_trail_update(side, p.x, p.y, 1.0, delta)
	# Stern foam rings — expanding circle OUTLINES emitted on a timer while the
	# unit is actually moving. Sized to the unit.
	var moving: bool = position.distance_to(_prev_position) > 0.5
	if moving:
		_wake_foam_accum += delta
		while _wake_foam_accum >= _WAKE_FOAM_INTERVAL:
			_wake_foam_accum -= _WAKE_FOAM_INTERVAL
			var stern: Vector2 = position + Vector2(0.0, wty).rotated(rot_off)
			_wake_foam.push_back({
				"pos": stern + Vector2(randf_range(-unit_size * 0.4, unit_size * 0.4),
					randf_range(-unit_size * 0.3, unit_size * 0.3)).rotated(rot_off),
				"age": 0.0,
				"r": unit_size * randf_range(0.25, 0.45),
			})
	else:
		_wake_foam_accum = 0.0
	for fi in range(_wake_foam.size() - 1, -1, -1):
		_wake_foam[fi]["age"] += delta
		if float(_wake_foam[fi]["age"]) >= _WAKE_FOAM_LIFE:
			_wake_foam.remove_at(fi)
	# Floor-adaptive wake colour (port of Mindustry WaterMoveComp.draw): ease
	# the wake toward the current floor tile's map colour ×1.5. Lerp rate
	# matches Mindustry's `clamp(Time.delta * 0.04)` (≈ 2.4/sec at 60 fps).
	var target_rgb: Color = _WAKE_FALLBACK_RGB
	var terrain = _terrain_ref()
	if terrain != null:
		var grid: Vector2i = main.world_to_grid(position)
		var fid: StringName = StringName(terrain.floor_tiles.get(grid, &""))
		if fid != &"":
			var fdata = Registry.get_tile(fid)
			if fdata != null and fdata.color.a > 0.0:
				target_rgb = Color(
					minf(fdata.color.r * _WAKE_COLOR_MUL, 1.0),
					minf(fdata.color.g * _WAKE_COLOR_MUL, 1.0),
					minf(fdata.color.b * _WAKE_COLOR_MUL, 1.0))
	var ease: float = clampf(delta * 2.4, 0.0, 1.0)
	_wake_color.r = lerpf(_wake_color.r, target_rgb.r, ease)
	_wake_color.g = lerpf(_wake_color.g, target_rgb.g, ease)
	_wake_color.b = lerpf(_wake_color.b, target_rgb.b, ease)
	queue_redraw()


## Port of Mindustry `Trail.update(x, y, width)`: appends points to the
## side's flat (x,y,w) history on a Time.delta counter, trimming to
## `trail_length`, interpolating intermediate points across skipped frames.
func _trail_update(side: int, x: float, y: float, w: float, delta: float) -> void:
	var length: int = data.trail_length
	var pts: PackedFloat32Array = _wake_left if side == 0 else _wake_right
	var last: Vector3 = _wl_last if side == 0 else _wr_last
	var counter: float = _wl_counter if side == 0 else _wr_counter

	counter += delta * _MINDUSTRY_TPS
	var count: int = int(counter)
	counter -= float(count)

	if count > 0:
		# Trim old points so the buffer holds at most `length` triples.
		var to_remove: int = pts.size() + (count - 1 - length) * 3
		if to_remove > 0 and pts.size() > 0:
			var rm: int = mini(to_remove, pts.size())
			pts = pts.slice(rm)
		if count == 1 or last.x == -1.0:
			pts.append_array(PackedFloat32Array([x, y, w]))
		else:
			for i in range(count):
				var f: float = float(i + 1) / float(count)
				pts.append_array(PackedFloat32Array([
					lerpf(last.x, x, f), lerpf(last.y, y, f), lerpf(last.z, w, f),
				]))

	# Update last-state regardless (so the end-cap joins at the live point).
	var new_lastangle: float = -_angle_rad(x, y, last.x, last.y)
	if side == 0:
		_wake_left = pts
		_wl_last = Vector3(x, y, w)
		_wl_lastangle = new_lastangle
		_wl_counter = counter
	else:
		_wake_right = pts
		_wr_last = Vector3(x, y, w)
		_wr_lastangle = new_lastangle
		_wr_counter = counter


## atan2(y2-y1, x2-x1) — matches Arc's `Angles.angleRad(x,y,x2,y2)`.
func _angle_rad(x1: float, y1: float, x2: float, y2: float) -> float:
	return atan2(y2 - y1, x2 - x1)


## Paints both side ribbons + stern foam rings on the unit's own canvas
## (called from `_draw`). Foam rings draw under the ribbons.
func _draw_water_wake() -> void:
	if not _wake_enabled or data == null:
		return
	# Stern foam — small circle OUTLINES (rings) that grow only slightly as
	# they age out, so they read as little dissipating ripples rather than
	# big expanding bubbles.
	var o: Vector2 = position
	var ring_w: float = maxf(1.0, unit_size * 0.08)
	for f in _wake_foam:
		var t: float = clampf(float(f["age"]) / _WAKE_FOAM_LIFE, 0.0, 1.0)
		var r: float = float(f["r"]) * (1.0 + t * 0.5)   # gentle growth
		var a: float = (1.0 - t) * _wake_color.a * 0.8
		if a > 0.01 and r > 1.0:
			draw_arc((f["pos"] as Vector2) - o, r, 0.0, TAU, 20,
				Color(_wake_color.r, _wake_color.g, _wake_color.b, a), ring_w, true)
	var width: float = data.trail_scl
	_trail_draw(0, _wake_color, width)
	_trail_draw(1, _wake_color, width)


## Draws one side ribbon. Builds a centreline of history points (tail →
## hull), gives each point a BISECTOR normal (averaged from its adjacent
## segment directions) so consecutive quads share their edge vertices —
## this is what kills the bow-tie / disconnected-segment artefact on sharp
## turns that a per-segment perpendicular produces. Width is MONOTONIC:
## widest at the hull (newest point), tapering smoothly to a point at the
## tail, so the ribbon never bulges wider than where it leaves the unit.
func _trail_draw(side: int, color: Color, width: float) -> void:
	var pts: PackedFloat32Array = _wake_left if side == 0 else _wake_right
	var last: Vector3 = _wl_last if side == 0 else _wr_last
	var counter: float = _wl_counter if side == 0 else _wr_counter
	var length: int = data.trail_length
	var n: int = pts.size()
	if n < 6:
		return
	var o: Vector2 = position

	# 1) Build the local-space centreline (tail → hull), appending the live
	#    `last` head point so the ribbon reaches the unit.
	var cl: PackedVector2Array = PackedVector2Array()
	var m: int = n / 3
	for j in range(m):
		var px: float = pts[j * 3]
		var py: float = pts[j * 3 + 1]
		# Slide the tail point forward by `counter` so it doesn't pop a whole
		# point each frame (matches Mindustry's end-cap lerp).
		if j == 0 and m >= length - 1 and m >= 2:
			px = lerpf(px, pts[3], counter)
			py = lerpf(py, pts[4], counter)
		cl.append(Vector2(px, py) - o)
	cl.append(Vector2(last.x, last.y) - o)
	var c: int = cl.size()
	if c < 2:
		return

	# 2) Build a single interleaved vertex strip (left0, right0, left1, ...)
	#    with per-point bisector normals (shared edges = no gaps on turns)
	#    and monotonic half-width (0 at tail → max at hull). The WHOLE ribbon
	#    is then submitted as ONE triangle array — a single draw call per side
	#    instead of one per segment (the old ~140-calls-per-side was the lag).
	var verts: PackedVector2Array = PackedVector2Array()
	verts.resize(c * 2)
	for k in range(c):
		var frac: float = float(k) / float(c - 1)   # 0 tail → 1 hull
		var hw: float = width * frac
		var tdir: Vector2 = Vector2.ZERO
		if k > 0:
			tdir += (cl[k] - cl[k - 1]).normalized()
		if k < c - 1:
			tdir += (cl[k + 1] - cl[k]).normalized()
		if tdir.length_squared() < 0.0001:
			tdir = Vector2.RIGHT
		tdir = tdir.normalized()
		var nrm: Vector2 = Vector2(-tdir.y, tdir.x) * hw
		verts[k * 2] = cl[k] + nrm
		verts[k * 2 + 1] = cl[k] - nrm

	# 3) Index the strip as two triangles per segment, one batched submission.
	var idx: PackedInt32Array = PackedInt32Array()
	idx.resize((c - 1) * 6)
	var ii: int = 0
	for k in range(c - 1):
		var b: int = k * 2
		idx[ii] = b;       idx[ii + 1] = b + 1; idx[ii + 2] = b + 2
		idx[ii + 3] = b + 1; idx[ii + 4] = b + 3; idx[ii + 5] = b + 2
		ii += 6
	var cols: PackedColorArray = PackedColorArray()
	cols.resize(verts.size())
	cols.fill(color)
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), idx, verts, cols)


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

	# Decrement the shared attack timer so both path-following and auto-combat can
	# fire. Attack-speed status effects (Crystallized → 0.8×) tick it slower, so a
	# debuffed unit fires less often.
	attack_timer = maxf(attack_timer - delta * _status_stat_mult(&"attack_speed_modifier"), -1.0)

	# 1. Pursue a manual target if we have one
	if manual_target_unit != null or manual_target_building != null:
		_pursue_manual_target(delta)
	# 2. Otherwise, if the player issued a pure move order, just travel
	elif move_target != null and path.size() > 0 and path_index < path.size():
		_follow_path(delta)
	# 3. Otherwise, fall through to auto-combat (acquire + pursue a nearby
	#    target). EXCEPTION: a passive (non-controlled) Lumina shardling stands
	#    down — it only fights when the player drives it directly.
	else:
		# Clear a completed move_target so auto-combat can re-engage.
		if move_target != null and (path.size() == 0 or path_index >= path.size()):
			move_target = null
		if _is_passive_shardling():
			# Drop any auto-acquired combat target so weapon mounts hold fire too.
			target_unit = null
			target_building = null
		else:
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


## True for a Lumina Shardling that the player ISN'T currently driving. These
## stand down completely — no defending, no hunting — so a parked shardling
## doesn't wander off to fight; every other player unit auto-engages normally.
func _is_passive_shardling() -> bool:
	return not is_controlled and team == UnitData.Team.PLAYER \
		and data != null and data.id == &"player_drone"


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

	# Prefer the explicitly-ordered target if it's in range.
	if manual_target_unit != null and is_instance_valid(manual_target_unit) and not manual_target_unit.is_dead:
		if position.distance_squared_to(manual_target_unit.position) <= range_sq:
			attack_timer = attack_cooldown
			target_unit = manual_target_unit
			_attack_enemy_unit()
			return

	# Auto-fire at any in-range enemy unit (defensive — no move/pursue here).
	# Skipped for passive (non-controlled) Lumina shardlings, which stand down
	# entirely unless the player drives them.
	if not _is_passive_shardling():
		for e in unit_manager.enemies:
			if not is_instance_valid(e) or e.is_dead:
				continue
			if e.team == team:
				continue
			if position.distance_squared_to(e.position) <= range_sq:
				attack_timer = attack_cooldown
				target_unit = e
				_attack_enemy_unit()
				return

	# Then the ordered FEROX building target. Skip if the manual
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
	if thruster_boost_enabled and can_thruster_boost():
		speed_mult *= 2.25
	var step = move_speed * speed_mult * delta

	# --- Tank-style steering -----------------------------------------------
	# Moves the tank along its current facing; when the desired direction
	# diverges from that facing, the motion arcs around a pivot point
	# perpendicular to the chassis (turn_radius) instead of pivoting in place.
	if data and data.tank_steering:
		_tank_steer_step(direction.angle(), step, target_pos, distance)
		return
	# -----------------------------------------------------------------------

	# Mindustry-style soft-body separation: nudge out of overlapping neighbours
	# by the exact penetration (mass-weighted, under-relaxed) so a clump eases
	# apart instead of being flung. Applied directly to position; movement below
	# follows the path tangent unmodified.
	_apply_separation()
	var move_dir: Vector2 = direction

	if step >= distance:
		# Reaching the waypoint — sweep-collide the hop (don't raw-snap) so a
		# fast unit can't jump across a wall corner between cells.
		if unit_manager != null:
			position = unit_manager.resolve_move(position, target_pos - position, unit_size, (data.movement_layer if data else 0), team)
		else:
			position = target_pos
		path_index += 1
		_blocked_frames = 0
	else:
		var ml_walk: int = data.movement_layer if data else 0
		# Mindustry-style radius-aware, axis-separated collision. We hand
		# the desired step (separation-modified) to `resolve_move`, which
		# tries the X displacement then the Y displacement against the
		# unit's bounding-box faces — so a diagonal move into a wall keeps
		# only the unblocked axis and the unit SLIDES along the wall face
		# instead of snagging its corner on the cell edge or freezing nose-
		# first. `unit_size` is the collision half-extent. The separate
		# perpendicular-slide hack is no longer needed — sliding is now
		# intrinsic to the resolver.
		var desired: Vector2 = move_dir * step
		var resolved: Vector2 = position
		if unit_manager != null:
			resolved = unit_manager.resolve_move(position, desired, unit_size, ml_walk, team)
		else:
			resolved = position + desired
		var moved_this_frame: bool = resolved.distance_squared_to(position) > 0.0001
		position = resolved
		# Track the "actually got nowhere this frame" run for fast
		# repath escalation, separate from the spatial stuck timer.
		if moved_this_frame:
			_blocked_frames = 0
		else:
			_blocked_frames += 1
			if _blocked_frames >= _BLOCKED_FRAMES_REPATH:
				_request_repath()
				_blocked_frames = 0


## Soft-body separation — a faithful port of Mindustry's PhysicsProcess. For
## every overlapping same-layer neighbour, push THIS unit out by the EXACT
## penetration depth (sum of radii − centre distance), weighted by the
## neighbour's mass fraction and under-relaxed by SEP_RELAX. Because each push
## only ever resolves the real overlap — not a quadratic force that grows the
## closer two units get — a dense pile (e.g. a squad move-ordered to one point)
## eases apart and SETTLES instead of being flung. The neighbour pushes itself
## out symmetrically in its own update, so the pair separates by penetration ÷
## SEP_RELAX per frame total, exactly like Mindustry. Applied straight to
## position, validated against the layer's walkability so it never shoves a unit
## into a wall.
func _apply_separation() -> void:
	if data == null or unit_manager == null:
		return
	var ml: int = data.movement_layer
	var my_r: float = unit_size
	if my_r <= 0.0:
		return
	var my_mass: float = my_r * my_r  # ∝ circle area; only the RATIO matters
	var disp: Vector2 = Vector2.ZERO
	var neighbours: Array
	if unit_manager.has_method("get_nearby_units"):
		neighbours = unit_manager.get_nearby_units(position, ml)
	else:
		neighbours = unit_manager.enemies + unit_manager.player_units
	for other in neighbours:
		if other == self or not is_instance_valid(other) or other.is_dead:
			continue
		if other.data == null or other.data.movement_layer != ml:
			continue
		var other_r: float = other.unit_size
		var rs: float = my_r + other_r
		if rs <= 0.0:
			continue
		var to: Vector2 = position - other.position
		var dst: float = to.length()
		if dst >= rs:
			continue
		var pen: float = rs - dst
		var push: Vector2
		if dst < 0.001:
			# Exactly stacked — shove out at a random angle (Mindustry does this).
			var ang: float = randf() * TAU
			push = Vector2(cos(ang), sin(ang)) * pen
		else:
			push = (to / dst) * pen
		var other_mass: float = other_r * other_r
		# Heavier neighbour → we move more of the way (its mass fraction).
		var m1: float = other_mass / (my_mass + other_mass)
		disp += push * (m1 / SEP_RELAX)
	if disp.length_squared() <= 0.0001:
		return
	var target: Vector2 = position + disp
	# Never let separation push us into a wall / off navigable terrain.
	if unit_manager.is_world_pos_walkable(target, ml, team):
		position = target


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


## Public read of the intent direction this unit is using right now.
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


# =========================
# DUMMY TEST UNIT
# =========================

## Per-frame update for a dummy (Payload-Source enemy). Does nothing unless
## commanded. "idle" obeys r-click move orders only; "attack_block" /
## "attack_player" path to a target and fire Ferox projectiles via the
## normal `_try_attack` path.
func _dummy_update(delta: float) -> void:
	if dummy_mode != "attack_block" and dummy_mode != "attack_player":
		# Idle: follow an active move order, otherwise stand still.
		if move_target != null and path.size() > 0 and path_index < path.size():
			_follow_path(delta)
		elif move_target != null:
			move_target = null
		return
	move_target = null
	# (Re)acquire a target when we have none / it's gone or no longer hostile.
	if target_building == null or not main.placed_buildings.has(target_building) \
			or not _is_valid_attack_target(target_building):
		target_building = _dummy_pick_target()
		path = PackedVector2Array()
		path_index = 0
		_dummy_repath_accum = 1.0
	if target_building == null:
		return
	var bworld: Vector2 = main.grid_to_world(target_building) \
		+ Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
	var atk_range: float = maxf(data.attack_range if data else main.GRID_SIZE * 0.5, main.GRID_SIZE * 1.5)
	if position.distance_to(bworld) > atk_range:
		_dummy_repath_accum += delta
		if (path.size() == 0 or path_index >= path.size()) and _dummy_repath_accum >= 0.5:
			_dummy_repath_accum = 0.0
			unit_manager.request_path_to_position_async_with_target(self, bworld, target_building)
		if path.size() > 0 and path_index < path.size():
			_follow_path(delta)
	else:
		if path.size() > 0:
			path = PackedVector2Array()
			path_index = 0
		# In range — fire FEROX-faction projectiles on the attack cooldown.
		# Bypasses the global `enemies_attack` gate (this is a commanded test
		# unit) and never re-targets, unlike `_try_attack`.
		attack_timer -= delta
		if attack_timer <= 0.0:
			attack_timer = attack_cooldown
			var combat = _combat_sys_ref()
			if data and data.attack_range > 0 and combat:
				combat.enemy_ranged_attack(self, target_building, damage, 300.0, unit_color.lightened(0.3))
			else:
				main.damage_building(target_building, damage)


## Picks the dummy's attack target: the nearest Lumina core for
## "attack_player", otherwise the nearest Lumina building of any kind.
func _dummy_pick_target() -> Variant:
	if dummy_mode == "attack_player" and main.has_method("get_lumina_core_anchors"):
		var best_core: Variant = null
		var best_cd := INF
		for c in main.get_lumina_core_anchors():
			var cw: Vector2 = main.grid_to_world(c)
			var d := position.distance_to(cw)
			if d < best_cd:
				best_cd = d
				best_core = c
		if best_core != null:
			return best_core
	# Nearest Lumina building fallback / "attack_block".
	var best: Variant = null
	var best_d := INF
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if anchor != cell:
			continue
		if not _is_valid_attack_target(anchor):
			continue
		var d := position.distance_to(main.grid_to_world(anchor))
		if d < best_d:
			best_d = d
			best = anchor
	return best


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

	# Mount-equipped units fire through their weapon mounts (ticked in
	# _process) — skip the legacy single-shot here so we don't double-fire.
	# The target gate above still runs so the unit stops + holds at range.
	if has_weapon_mounts():
		return

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
# WEAPON MOUNTS (Mindustry-style multi-weapon system)
# =========================

## True if this unit drives its combat through the mount system rather than
## the legacy single-shot attack path. Set when the .tres lists weapons.
func has_weapon_mounts() -> bool:
	return not _weapon_mounts.is_empty()


## Builds `_weapon_mounts` from `data.weapons`. Each weapon yields one mount,
## or two cross-linked mirror mounts (offset.x negated, sprite flipped, reload
## doubled so the pair keeps the single-weapon cadence) — exactly Mindustry's
## data-time mirror expansion. Live state starts ready-to-fire.
func _setup_weapon_mounts() -> void:
	_weapon_mounts.clear()
	if data == null or data.weapons.is_empty():
		return
	for w in data.weapons:
		if w == null:
			continue
		var base_reload: float = w.effective_reload(attack_cooldown)
		var barrels: int = maxi(1, w.barrel_count)
		if w.mirror:
			# Two mounts. Each runs on a DOUBLED reload, but the second
			# starts half a cycle ahead — so they fire on alternating beats
			# and the pair's combined cadence equals the single-weapon
			# `base_reload`. This needs no runtime "whose turn" bookkeeping:
			# each mount just fires whenever its own reload hits zero.
			_weapon_mounts.append({
				"weapon": w, "offset": w.offset, "muzzle": w.muzzle_offset,
				"flip": false, "rotation": facing_angle, "recoil": 0.0,
				"reload": 0.0, "reload_max": base_reload * 2.0,
				"barrels": barrels, "barrel_spacing": w.barrel_spacing, "barrel_idx": 0,
			})
			_weapon_mounts.append({
				"weapon": w,
				"offset": Vector2(-w.offset.x, w.offset.y),
				"muzzle": Vector2(-w.muzzle_offset.x, w.muzzle_offset.y),
				"flip": true, "rotation": facing_angle, "recoil": 0.0,
				"reload": base_reload, "reload_max": base_reload * 2.0,
				"barrels": barrels, "barrel_spacing": w.barrel_spacing, "barrel_idx": 0,
			})
		else:
			_weapon_mounts.append({
				"weapon": w, "offset": w.offset, "muzzle": w.muzzle_offset,
				"flip": false, "rotation": facing_angle, "recoil": 0.0,
				"reload": 0.0, "reload_max": base_reload,
				"barrels": barrels, "barrel_spacing": w.barrel_spacing, "barrel_idx": 0,
			})


## World position of a mount given its local offset and the unit's facing.
## `facing_angle` is the chassis "up" direction; local +y points forward
## (toward the sprite top), local +x is the chassis's right, matching the
## authoring convention. We rotate by (facing_angle - PI/2) so local +y maps
## onto the chassis forward vector.
func _mount_world_pos(local: Vector2) -> Vector2:
	return position + local.rotated(facing_angle - PI / 2.0)


# =========================
# PAYLOAD STATE CAPTURE / RESTORE
# =========================
# A unit that becomes a payload (entered a fabricator / refabricator /
# upgrader / reconstructor / assembler / mass driver / picked up by a crane)
# must round-trip ALL of its runtime pose + command state so it (a) renders
# in-building exactly as it would in the world and (b) resumes its orders
# when redeployed — and survives a save/load while held. These two helpers
# are the single source of truth for that; every capture/restore site calls
# them instead of hand-building partial dicts.

## Serialises this unit's full runtime state into the given payload dict
## (creating the JSON-safe fields). Stores pose (facing/aim), per-mount
## turret rotations, and command/target state. Vector/grid targets are
## stored as plain arrays so they survive JSON save.
func capture_payload_state(payload: Dictionary) -> void:
	payload["type"] = "unit"
	payload["unit_id"] = String(data.id) if data else ""
	payload["health"] = health
	payload["team"] = int(team)
	payload["applied_upgrades"] = applied_upgrades.duplicate()
	payload["facing_angle"] = facing_angle
	payload["aim_angle"] = aim_angle
	payload["hold_fire"] = hold_fire
	payload["is_rallying"] = is_rallying
	payload["assist_player_build"] = assist_player_build
	payload["thruster_boost_enabled"] = thruster_boost_enabled
	payload["unit_shield_health"] = unit_shield_health
	payload["unit_shield_cooldown"] = unit_shield_cooldown
	payload["mining_request_id"] = String(mining_request_id)
	payload["manual_target_building_block_id"] = String(manual_target_building_block_id)
	# Per-mount turret rotations (and recoil) so the heads keep their aim.
	var mr: Array = []
	for m in _weapon_mounts:
		mr.append({"rotation": float(m.get("rotation", facing_angle)),
			"recoil": float(m.get("recoil", 0.0))})
	payload["mount_rotations"] = mr
	# Command / target state. Live-unit refs can't serialise, so store the
	# stable handles: a building target as its grid cell, a move target as
	# [x, y]. Unit refs are dropped (they may not exist on redeploy) — the
	# unit re-acquires via auto-combat.
	if move_target is Vector2:
		payload["move_target"] = [move_target.x, move_target.y]
	if target_building is Vector2i:
		payload["target_building"] = [target_building.x, target_building.y]
	if manual_target_building is Vector2i:
		payload["manual_target_building"] = [manual_target_building.x, manual_target_building.y]
	# Active status effects (Burning / Embrittled / slowed / corroding …). The
	# `effect` Resource itself can't serialise, so store its id + the live timing
	# and re-resolve via Registry on load.
	var statuses: Array = []
	for sid in active_statuses:
		var ent: Dictionary = active_statuses[sid]
		statuses.append({
			"id": String(sid),
			"time_left": float(ent.get("time_left", 0.0)),
			"stacks": int(ent.get("stacks", 1)),
			"boost": float(ent.get("boost", 1.0)),
			"dot_acc": float(ent.get("dot_acc", 0.0)),
		})
	payload["active_statuses"] = statuses
	# Mining progress + carried ore (so a miner doesn't restart from scratch).
	payload["mine_timer"] = _mine_timer
	var mined: Dictionary = {}
	for mk in mined_inventory:
		mined[String(mk)] = int(mined_inventory[mk])
	payload["mined_inventory"] = mined
	# Squad membership + payload-entry intent + Ferox rebuild task.
	payload["squad_anchor"] = [squad_anchor.x, squad_anchor.y]
	payload["enter_payload_when_able"] = enter_payload_when_able
	payload["payload_target_anchor"] = [payload_target_anchor.x, payload_target_anchor.y]
	payload["rebuild_timer"] = rebuild_timer
	if rebuild_target is Dictionary:
		payload["rebuild_target"] = rebuild_target


## Restores runtime state previously captured by `capture_payload_state`
## onto this (freshly-spawned) unit. Safe against missing keys (older saves
## / partial payloads). Call AFTER the unit's `_ready` + `_setup_weapon_mounts`.
func apply_payload_state(payload: Dictionary) -> void:
	if payload.has("health"):
		health = float(payload["health"])
	if payload.has("applied_upgrades"):
		applied_upgrades.clear()
		for up in payload["applied_upgrades"]:
			applied_upgrades.append(StringName(up))
		if has_method("recompute_module_stats"):
			recompute_module_stats()
	if payload.has("facing_angle"):
		facing_angle = float(payload["facing_angle"])
		# Mark facing as already seeded so `_tick_facing_angle` doesn't
		# reset it to a default on the unit's first frame.
		_facing_initialized = true
	if payload.has("aim_angle"):
		aim_angle = float(payload["aim_angle"])
	hold_fire = bool(payload.get("hold_fire", false))
	is_rallying = bool(payload.get("is_rallying", false))
	assist_player_build = bool(payload.get("assist_player_build", false))
	thruster_boost_enabled = bool(payload.get("thruster_boost_enabled", false)) and can_thruster_boost()
	if payload.has("unit_shield_health"):
		unit_shield_health = clampf(float(payload["unit_shield_health"]), 0.0, unit_shield_max_health)
	unit_shield_cooldown = maxf(0.0, float(payload.get("unit_shield_cooldown", 0.0)))
	mining_request_id = StringName(payload.get("mining_request_id", ""))
	manual_target_building_block_id = StringName(payload.get("manual_target_building_block_id", ""))
	# Restore per-mount turret rotations onto the rebuilt mounts (index-matched).
	var mr: Array = payload.get("mount_rotations", [])
	for i in range(mini(mr.size(), _weapon_mounts.size())):
		var e: Dictionary = mr[i]
		_weapon_mounts[i]["rotation"] = float(e.get("rotation", facing_angle))
		_weapon_mounts[i]["recoil"] = float(e.get("recoil", 0.0))
	# Command / target state.
	if payload.has("move_target"):
		var mv: Array = payload["move_target"]
		if mv.size() == 2:
			move_target = Vector2(float(mv[0]), float(mv[1]))
	if payload.has("target_building"):
		var tb: Array = payload["target_building"]
		if tb.size() == 2:
			target_building = Vector2i(int(tb[0]), int(tb[1]))
	if payload.has("manual_target_building"):
		var mtb: Array = payload["manual_target_building"]
		if mtb.size() == 2:
			manual_target_building = Vector2i(int(mtb[0]), int(mtb[1]))
	# Status effects — re-resolve each effect Resource by id, keeping the saved
	# timing so a burning unit keeps burning for the right remaining duration.
	if payload.has("active_statuses"):
		active_statuses.clear()
		for s in payload["active_statuses"]:
			var sid: StringName = StringName(s.get("id", ""))
			if sid == &"":
				continue
			var eff = Registry.get_status_effect(sid)
			if eff == null:
				continue
			active_statuses[sid] = {
				"effect": eff,
				"time_left": float(s.get("time_left", eff.duration)),
				"stacks": int(s.get("stacks", 1)),
				"boost": float(s.get("boost", 1.0)),
				"dot_acc": float(s.get("dot_acc", 0.0)),
			}
	# Mining progress + carried ore.
	if payload.has("mine_timer"):
		_mine_timer = float(payload["mine_timer"])
	if payload.has("mined_inventory"):
		mined_inventory.clear()
		for mk in payload["mined_inventory"]:
			mined_inventory[StringName(mk)] = int(payload["mined_inventory"][mk])
	# Squad membership + payload-entry intent + Ferox rebuild task.
	if payload.has("squad_anchor"):
		var sa: Array = payload["squad_anchor"]
		if sa.size() == 2:
			squad_anchor = Vector2i(int(sa[0]), int(sa[1]))
	enter_payload_when_able = bool(payload.get("enter_payload_when_able", false))
	if payload.has("payload_target_anchor"):
		var pta: Array = payload["payload_target_anchor"]
		if pta.size() == 2:
			payload_target_anchor = Vector2i(int(pta[0]), int(pta[1]))
	rebuild_timer = float(payload.get("rebuild_timer", 0.0))
	if payload.has("rebuild_target") and payload["rebuild_target"] is Dictionary:
		rebuild_target = payload["rebuild_target"]


## Per-frame mount tick: aim, decay reload/recoil, and fire when ready and
## on-target. Called from `_process` for units that have mounts (replacing
## the legacy attack call for those units). `aim_world` is the current
## combat target point (or null when there's nothing to shoot).
## `aim_only` keeps the heads tracking + reloading WITHOUT auto-firing —
## used under manual control, where the player's fire button drives shots
## (see `fire_weapon_mounts_at`).
func _tick_weapon_mounts(delta: float, aim_world: Variant, aim_only: bool = false) -> void:
	if _weapon_mounts.is_empty():
		return
	var rot_step: float = deg_to_rad(0.0)
	for i in range(_weapon_mounts.size()):
		var m: Dictionary = _weapon_mounts[i]
		var w: WeaponData = m["weapon"]
		# Decay reload + recoil.
		m["reload"] = maxf(0.0, float(m["reload"]) - delta)
		if float(m["recoil"]) > 0.0:
			m["recoil"] = maxf(0.0, float(m["recoil"]) - delta * (w.recoil * 6.0))
		var mount_world: Vector2 = _mount_world_pos(m["offset"])
		# Desired aim angle for this mount.
		var has_target: bool = aim_world is Vector2
		var desired: float = float(m["rotation"])
		if w.rotate and has_target:
			desired = (aim_world - mount_world).angle()
		elif not w.rotate:
			# Locked to chassis: forward + base_rotation.
			desired = (facing_angle - PI / 2.0) + w.base_rotation
		# Rotate the mount toward the desired angle at rotate_speed.
		if w.rotate:
			rot_step = deg_to_rad(w.rotate_speed) * delta
			m["rotation"] = _rotate_toward(float(m["rotation"]), desired, rot_step)
		else:
			m["rotation"] = desired
		_weapon_mounts[i] = m
		# Fire?  (Manual control aims only — the player's input fires.)
		if aim_only:
			continue
		if not has_target:
			continue
		if float(m["reload"]) > 0.0001:
			continue
		# On-target gate.
		var aim_err: float = absf(wrapf(desired - float(m["rotation"]), -PI, PI))
		if aim_err > deg_to_rad(w.shoot_cone):
			continue
		# Range gate.
		var rng: float = w.effective_range(data.attack_range if data else 0.0)
		if mount_world.distance_to(aim_world) > rng:
			continue
		_fire_weapon_mount(i, mount_world, aim_world)


## Player-driven fire: fires every ready mount toward `aim_world` (the mouse
## under manual control). Honors each mount's own reload + aim cone, so the
## mirrored pair still alternates and the heads must be roughly on-target.
## Returns true if at least one mount fired. The mounts must already have
## been aimed this frame via `_tick_weapon_mounts(..., aim_only=true)`.
func fire_weapon_mounts_at(aim_world: Vector2) -> bool:
	if _weapon_mounts.is_empty():
		return false
	var fired := false
	for i in range(_weapon_mounts.size()):
		var m: Dictionary = _weapon_mounts[i]
		var w: WeaponData = m["weapon"]
		if float(m["reload"]) > 0.0001:
			continue
		var mount_world: Vector2 = _mount_world_pos(m["offset"])
		var desired: float = (aim_world - mount_world).angle()
		var aim_err: float = absf(wrapf(desired - float(m["rotation"]), -PI, PI))
		if aim_err > deg_to_rad(w.shoot_cone):
			continue
		_fire_weapon_mount(i, mount_world, aim_world)
		fired = true
	return fired


## Executes one mount's behavior and resets its reload + recoil. Mirror
## alternation is handled purely by the staggered reloads set at spawn, so
## there's no per-shot side bookkeeping here.
func _fire_weapon_mount(idx: int, mount_world: Vector2, aim_world: Vector2) -> void:
	var m: Dictionary = _weapon_mounts[idx]
	var w: WeaponData = m["weapon"]
	# Multi-barrel mounts (double-barrel head, etc.): fire ONE barrel per shot,
	# cycling through them, with the mount's reload split evenly so N barrels
	# fire N× as often and visibly alternate between the divots. The barrel's
	# perpendicular offset rides on the sprite-local x, so it rotates with the
	# head and lands on the correct divot.
	var barrels: int = maxi(1, int(m.get("barrels", 1)))
	var b_idx: int = int(m.get("barrel_idx", 0)) % barrels
	var perp: float = 0.0
	if barrels > 1:
		perp = (float(b_idx) - float(barrels - 1) * 0.5) * float(m.get("barrel_spacing", 0.0))
	# Muzzle offset is sprite-local (+Y = out the barrel, +X = across the divots);
	# convert with (rot - PI/2) to match the mount/recoil convention so bullets
	# spawn at the barrel tip, not 90° off to the side.
	var muzzle_local: Vector2 = (m["muzzle"] as Vector2) + Vector2(perp, 0.0)
	var muzzle: Vector2 = mount_world + muzzle_local.rotated(float(m["rotation"]) - PI / 2.0)
	match w.behavior:
		WeaponData.Behavior.TURRET:
			_fire_turret_weapon(w, muzzle, aim_world)
		WeaponData.Behavior.REPAIR_BEAM:
			_fire_repair_weapon(w, mount_world)
		WeaponData.Behavior.POINT_DEFENSE:
			_fire_point_defense_weapon(w, mount_world)
	m["barrel_idx"] = (b_idx + 1) % barrels
	m["reload"] = float(m["reload_max"]) / float(barrels)
	m["recoil"] = w.recoil
	_weapon_mounts[idx] = m


## TURRET behavior: spawn a projectile from the muzzle toward the target,
## using the unit's faction. Reuses CombatSystem's projectile pipeline so
## ammo / pierce / status all flow through the existing path.
func _fire_turret_weapon(w: WeaponData, muzzle: Vector2, aim_world: Vector2) -> void:
	var combat = _combat_sys_ref()
	if combat == null:
		return
	var dmg: float = w.effective_damage(damage)
	var spd: float = w.ammo.projectile_speed if w.ammo != null else w.projectile_speed
	var col: Color = w.ammo.projectile_color if w.ammo != null else unit_color.lightened(0.3)
	var is_enemy: bool = team == UnitData.Team.ENEMY
	var src_faction: int = main.Faction.FEROX if is_enemy else main.Faction.LUMINA
	var source_str: String = "enemy" if is_enemy else "player_unit"
	# Bullets fly out to the weapon's full range along the aim direction and
	# despawn there if they hit nothing — like turrets/the drone. `aim_world`
	# is only a DIRECTION hint (the target or the mouse): we extend it to the
	# end-of-range point so the shot doesn't stop short at the cursor/target.
	var rng: float = w.effective_range(data.attack_range if data else 0.0)
	var aim_dir: Vector2 = (aim_world - muzzle)
	if aim_dir.length_squared() < 0.0001:
		aim_dir = Vector2.RIGHT.rotated(facing_angle - PI / 2.0)  # fallback: forward
	aim_dir = aim_dir.normalized()
	var end_pos: Vector2 = muzzle + aim_dir * rng
	var extras: Dictionary = {"max_range": rng}
	if w.ammo != null:
		extras = {
			"max_range": rng,
			"lifetime": w.ammo.projectile_lifetime,
			"radius": w.ammo.projectile_radius,
			"pierce": w.ammo.pierce_count,
			"knockback": w.ammo.knockback,
			"homing": w.ammo.homing,
			"trail_color": w.ammo.get_trail_color(),
			"collides_air": w.ammo.collides_air,
			"collides_ground": w.ammo.collides_ground,
		}
	combat._spawn_projectile(
		muzzle, null, end_pos, "none", spd, dmg, col, source_str,
		(w.ammo.is_splash if w.ammo != null else (data.is_aoe if data else false)),
		(w.ammo.splash_radius if w.ammo != null else (data.aoe_radius if data else 0.0)),
		src_faction, extras,
	)


## REPAIR_BEAM behavior: heal the nearest same-team damaged building in
## range. Lightweight per-fire pulse (not a sustained beam) so it reuses the
## reload cadence; the heal amount scales by reload so DPS stays consistent.
func _fire_repair_weapon(w: WeaponData, mount_world: Vector2) -> void:
	if team != UnitData.Team.PLAYER:
		return  # repair is a friendly-only behaviour for now
	var rng: float = w.effective_range(data.attack_range if data else 0.0)
	var best: Vector2i = Vector2i(-99999, -99999)
	var best_d: float = rng
	for gp in main.placed_buildings:
		if main.get_building_faction(gp) != main.Faction.LUMINA:
			continue
		if not main.is_building_anchor(gp):
			continue
		var bw: Vector2 = main.grid_to_world(gp) + Vector2(main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5)
		var d: float = mount_world.distance_to(bw)
		if d <= best_d:
			var bd = Registry.get_block(main.placed_buildings[gp])
			var maxh: float = bd.max_health if bd else 0.0
			if maxh > 0.0 and float(main.building_health.get(gp, maxh)) < maxh:
				best_d = d
				best = gp
	if best.x == -99999:
		return
	# Heal per fire = rate × reload interval, so HP/sec stays at
	# `repair_per_second` regardless of how fast the mount cycles.
	var interval: float = w.reload if w.reload > 0.0 else maxf(0.05, attack_cooldown)
	var heal: float = w.repair_per_second * interval
	var bd2 = Registry.get_block(main.placed_buildings[best])
	var maxh2: float = bd2.max_health if bd2 else 0.0
	main.building_health[best] = minf(float(main.building_health.get(best, maxh2)) + heal, maxh2)


## POINT_DEFENSE behavior: damage / remove the nearest hostile projectile in
## range. Consults CombatSystem's live projectile list.
func _fire_point_defense_weapon(w: WeaponData, mount_world: Vector2) -> void:
	var combat = _combat_sys_ref()
	if combat == null or not ("projectiles" in combat):
		return
	var rng: float = w.effective_range(data.attack_range if data else 0.0)
	var my_faction: int = main.Faction.FEROX if team == UnitData.Team.ENEMY else main.Faction.LUMINA
	for proj in combat.projectiles:
		if not (proj is Dictionary):
			continue
		if int(proj.get("source_faction", 0)) == my_faction:
			continue
		var pp: Vector2 = proj.get("pos", mount_world)
		if mount_world.distance_to(pp) <= rng:
			proj["damage"] = float(proj.get("damage", 0.0)) - w.point_defense_damage
			if float(proj["damage"]) <= 0.0:
				proj["dead"] = true
			return


## Draws every weapon mount sprite at its transformed world position,
## rotated to the mount's aim and pulled back by recoil. Called from `_draw`
## (which is unit-local space, so positions are converted back to local).
func _draw_weapon_mounts() -> void:
	if _weapon_mounts.is_empty():
		return
	for m in _weapon_mounts:
		var w: WeaponData = m["weapon"]
		if w.sprite == null:
			continue
		var mount_world: Vector2 = _mount_world_pos(m["offset"])
		# Recoil pulls the sprite straight BACK along the barrel (away from
		# the target). `m["rotation"]` is a standard angle (0 = +X) while the
		# offset is in sprite-local space (+Y = forward / out the barrel), so
		# convert with (rot - PI/2) — the same convention as `_mount_world_pos`.
		# Using bare `.rotated(rot)` here was the bug: it pushed the head 90°
		# off, i.e. sideways instead of backward.
		var rot: float = float(m["rotation"])
		var recoil_off: Vector2 = Vector2(0.0, -float(m["recoil"])).rotated(rot - PI / 2.0)
		var local: Vector2 = (mount_world + recoil_off) - position
		var scale_f: float = (w.sprite_scale if w.sprite_scale > 0.0 else 1.0) * main.SPRITE_SCALE_FACTOR
		var sz: Vector2 = w.sprite.get_size() * scale_f
		draw_set_transform(local, rot + PI / 2.0 + w.sprite_angle_offset, Vector2(-1.0 if m["flip"] else 1.0, 1.0))
		draw_texture_rect(w.sprite, Rect2(-sz * 0.5, sz), false)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# =========================
# PLAYER UNIT COMBAT
# =========================

## Player units auto-target nearby FEROX enemies and buildings when idle, then
## pursue + attack. Called from _player_update's idle branch for every player
## unit EXCEPT passive (non-controlled) Lumina shardlings.
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
		var bd_pt = Registry.get_block(main.placed_buildings[grid_pos])
		if bd_pt != null and bd_pt.tags.has("no_pathfinding"):
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
	# Mount-equipped units fire through their mounts (ticked in _process);
	# suppress the legacy single-shot so they don't double-fire.
	if has_weapon_mounts():
		return
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
	# Mount-equipped units fire through their mounts (ticked in _process).
	if has_weapon_mounts():
		return
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
		# Not enough ferox resources yet — DON'T abandon the plan. Re-queuing it
		# and clearing the target makes _try_rebuild pop a different site next
		# frame and path to it, so the unit bounces between build sites. Instead
		# hold position at this site and keep "building", retrying every frame so
		# it finishes the instant the resources arrive. Timer is clamped at the
		# completion threshold so the retry fires each frame without overflowing.
		rebuild_timer = REBUILD_TIME
		_rebuild_arrived = true
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

	# Re-establish any links this block carried before destruction, to
	# whichever captured partners exist again (the other end re-links from
	# its own rebuild if still pending).
	if main.has_method("ferox_relink_after_rebuild"):
		main.ferox_relink_after_rebuild(rebuild_target)

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
		# Centre is on a legal cell — but the unit may still be WEDGED, with
		# its body straddling a cell boundary into an adjacent solid (the
		# crane-drop-on-an-edge case). The radius-aware test catches that;
		# `is_circle_walkable` clamps the half-extent below GRID_SIZE/2 so a
		# unit travelling down a legal 1-tile lane never reads as wedged.
		# Skip under manual control (the player owns the unit's position).
		if not is_controlled and not unit_manager.is_circle_walkable(position, unit_size, data.movement_layer):
			_wedge_timer += WALL_CHECK_INTERVAL
			if _wedge_timer >= WEDGE_RESCUE_TIME:
				_wedge_timer = 0.0
				var safe: Vector2 = _find_nearest_circle_walkable(position, unit_size, data.movement_layer)
				if safe != Vector2.INF:
					position = safe
					if not _skip_repath_on_unstick:
						_request_repath()
		else:
			_wedge_timer = 0.0
		return
	_wedge_timer = 0.0
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


## Like `_find_nearest_walkable`, but every candidate must clear the unit's
## full body (centre + cardinal faces) via `is_circle_walkable`, so a wedged
## unit isn't rescued into another boundary it can't move off of. Prefers the
## current cell's centre first — the smallest, most natural nudge that pulls a
## boundary-straddling unit back into open space.
func _find_nearest_circle_walkable(from: Vector2, radius: float, ml: int) -> Vector2:
	if unit_manager == null:
		return Vector2.INF
	var gs: float = float(main.GRID_SIZE)
	var cell_center: Vector2 = main.grid_to_world(main.world_to_grid(from)) + Vector2(gs * 0.5, gs * 0.5)
	if unit_manager.is_circle_walkable(cell_center, radius, ml):
		return cell_center
	for r in range(1, _RESCUE_MAX_TILES + 1):
		var step: float = float(r) * gs * 0.75
		for i in range(_RESCUE_ANGLE_STEPS):
			var ang: float = float(i) * TAU / float(_RESCUE_ANGLE_STEPS)
			var c: Vector2 = from + Vector2(cos(ang), sin(ang)) * step
			if unit_manager.is_circle_walkable(c, radius, ml):
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
	# Apply armor from .tres data, scaled by any armor-effectiveness debuff
	# (Embrittled halves it). Multiple such statuses multiply.
	var actual_damage = amount
	if data:
		var armor_mult: float = 1.0
		if not active_statuses.is_empty():
			for sid in active_statuses:
				var ase: StatusEffectData = active_statuses[sid]["effect"]
				if ase != null and ase.armor_effectiveness_modifier != 1.0:
					armor_mult *= ase.armor_effectiveness_modifier
		actual_damage = data.calc_damage_taken(amount, armor_mult)
	# Status-effect vulnerability: a status's `defense_modifier` scales ALL
	# incoming damage (corroding = 1.3× more, freezing = 1.4×, etc.). Modifiers
	# from multiple active statuses multiply together.
	if not active_statuses.is_empty():
		var dmg_mult: float = 1.0
		for sid in active_statuses:
			var se: StatusEffectData = active_statuses[sid]["effect"]
			if se != null and se.defense_modifier != 1.0:
				dmg_mult *= se.defense_modifier
		actual_damage *= dmg_mult
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

	# Mindustry-style unit death blast (Fx.dynamicExplosion port), sized
	# off the unit's visual radius, plus a ruin decal afterward.
	var vis_size: float = data.visual_size if data else 12.0
	var expl_u = main.get_node_or_null("ExplosionSystem") if main else null
	if expl_u and expl_u.has_method("unit_death"):
		expl_u.unit_death(position, vis_size * 0.5)
	var overlay = main.get_node_or_null("ParticleOverlay") if main else null
	if overlay and overlay.has_method("spawn_unit_ruins"):
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
	# A plain move order cancels a dummy's attack command.
	if is_dummy:
		dummy_mode = "idle"
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
	# A dummy goes back to inert when its orders are cancelled.
	if is_dummy:
		dummy_mode = "idle"


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
	var ok := tags.has("payload") or tags.has("freight") or tags.has("mass_driver") \
		or tags.has("deconstructor") or tags.has("upgrader") or tags.has("refit_bay")
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
	var payload := {}
	capture_payload_state(payload)
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

	# Naval wake — two tapering trail ribbons, painted FIRST so the hull
	# covers their origin. Drawn on the unit's OWN canvas (the proven path
	# the flying shadow uses) rather than a separate node. Skipped when the
	# unit is off-screen (the batched ribbon is still hundreds of verts).
	if _wake_enabled and _wake_on_screen():
		_draw_water_wake()

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

	# Mounted weapon sprites render over the chassis at their transformed
	# positions (no-op for units without weapons / without sprites).
	_draw_weapon_mounts()

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

	# Per-unit art-orientation correction (PI for down-facing art, etc).
	var spr_off: float = data.sprite_angle_offset if data else 0.0

	if data.base_sprite:
		var b_size: Vector2 = data.base_sprite.get_size() * scale_f
		# Base rotates to face the unit's current movement direction (the
		# shardling-style chassis rotation). Source art faces UP, so the
		# usual +PI/2 offset converts facing_angle into a texture angle;
		# `sprite_angle_offset` corrects art that faces a different way.
		draw_set_transform(Vector2.ZERO, facing_angle + PI / 2.0 + spr_off)
		draw_texture_rect(
			data.base_sprite,
			Rect2(-b_size * 0.5, b_size),
			false,
			base_tint
		)
		draw_set_transform(Vector2.ZERO, 0.0)

	if data.head_sprite:
		var h_size: Vector2 = data.head_sprite.get_size() * scale_f
		var h_angle: float = aim_angle + PI / 2.0 + spr_off
		draw_set_transform(Vector2.ZERO, h_angle)
		draw_texture_rect(
			data.head_sprite,
			Rect2(-h_size * 0.5, h_size),
			false,
			base_tint
		)
		draw_set_transform(Vector2.ZERO, 0.0)


## Renders a UNIT PAYLOAD exactly like a live in-world unit — chassis sprite
## + rotating head + weapon-mount turret heads — at the rotations stored in
## the payload dict (facing_angle / aim_angle / mount_rotations). Shared by
## every place a held/in-building unit is drawn (fabricators, refabricators,
## upgraders, reconstructors, assemblers, payload conveyors, cranes) so they
## all match the world render instead of drawing a static icon.
##
##   canvas         — CanvasItem to draw onto.
##   udata        — UnitData of the payload unit.
##   payload      — the payload dict (reads facing_angle/aim_angle/mount_rotations).
##   center       — world/canvas position to centre the unit on.
##   render_scale — multiplier RELATIVE to the unit's true in-world size.
##                  1.0 = identical to in-world (use this for fabricators /
##                  payload belts / cranes so size + mount geometry match
##                  exactly). <1 shrinks the whole unit uniformly.
##   extra_rot    — added to every layer's rotation (crane carry spin); 0 normally.
##   alpha        — overall opacity (e.g. dimmed while under construction).
##
## CRITICAL: every quantity scales by the SAME factor `s` (the unit's live
## world scale × render_scale) — chassis size, head size, mount OFFSET, and
## mount sprite size — exactly as `_draw_textured_unit` + `_draw_weapon_mounts`
## do. The earlier bug scaled the mount offset by a different factor than the
## sprites, so turret heads landed in the wrong spot at non-1× draw scales.
static func draw_unit_payload(canvas: CanvasItem, udata: UnitData, payload: Dictionary,
		center: Vector2, render_scale: float = 1.0, extra_rot: float = 0.0, alpha: float = 1.0) -> void:
	if canvas == null or udata == null:
		return
	# The single scale used for EVERYTHING — matches enemy_unit's live draw
	# (`sprite_scale * SPRITE_SCALE_FACTOR`), then × render_scale.
	var ssf: float = 2.0
	var mref = Engine.get_main_loop()
	if mref is SceneTree and (mref as SceneTree).root.has_node("Main"):
		var mn = (mref as SceneTree).root.get_node("Main")
		if "SPRITE_SCALE_FACTOR" in mn:
			ssf = float(mn.SPRITE_SCALE_FACTOR)
	var base_scale: float = (udata.sprite_scale if udata.sprite_scale > 0.0 else 1.0) * ssf
	var s: float = base_scale * render_scale
	var spr_off: float = udata.sprite_angle_offset
	var facing: float = float(payload.get("facing_angle", 0.0)) + extra_rot
	var aim: float = float(payload.get("aim_angle", facing)) + extra_rot
	var tint := Color(1, 1, 1, alpha)
	# Chassis.
	if udata.base_sprite:
		var b_size: Vector2 = udata.base_sprite.get_size() * s
		canvas.draw_set_transform(center, facing + PI / 2.0 + spr_off)
		canvas.draw_texture_rect(udata.base_sprite, Rect2(-b_size * 0.5, b_size), false, tint)
		canvas.draw_set_transform(Vector2.ZERO, 0.0)
	# Rotating head.
	if udata.head_sprite:
		var h_size: Vector2 = udata.head_sprite.get_size() * s
		canvas.draw_set_transform(center, aim + PI / 2.0 + spr_off)
		canvas.draw_texture_rect(udata.head_sprite, Rect2(-h_size * 0.5, h_size), false, tint)
		canvas.draw_set_transform(Vector2.ZERO, 0.0)
	# Weapon-mount turret heads — mirror `_draw_weapon_mounts` exactly. The
	# mount OFFSET and the mount SPRITE both use the SAME scale `s`, and the
	# offset rotates by (facing - PI/2) like `_mount_world_pos`.
	var mount_rot: Array = payload.get("mount_rotations", [])
	var mi: int = 0
	for w in udata.weapons:
		if w == null:
			continue
		var sides: Array = [false]
		if w.mirror:
			sides = [false, true]
		for flip in sides:
			# Live setup: first mount uses +offset, mirror uses -offset.x.
			var local_off: Vector2 = w.offset if not flip else Vector2(-w.offset.x, w.offset.y)
			var rot: float = facing
			if mi < mount_rot.size():
				rot = float((mount_rot[mi] as Dictionary).get("rotation", facing)) + extra_rot
			mi += 1
			if w.sprite == null:
				continue
			var mount_pos: Vector2 = center + (local_off * s).rotated(facing - PI / 2.0)
			var msz: Vector2 = w.sprite.get_size() * (w.sprite_scale if w.sprite_scale > 0.0 else 1.0) * ssf * render_scale
			canvas.draw_set_transform(mount_pos, rot + PI / 2.0 + w.sprite_angle_offset,
				Vector2(-1.0 if flip else 1.0, 1.0))
			canvas.draw_texture_rect(w.sprite, Rect2(-msz * 0.5, msz), false, tint)
			canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


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
