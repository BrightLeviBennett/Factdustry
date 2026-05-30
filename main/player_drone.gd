extends Node2D

# ============================================================
# PLAYER_DRONE.GD - The Player's Builder Drone
# ============================================================
# Stats (health, speed, etc.) are loaded from the
# player_drone.tres UnitData resource via the Registry.
# ============================================================

@onready var main: Node2D = get_node("/root/Main")

# Cached sibling references (populated in _ready).
var _terrain: Node2D
var _unit_mgr: Node
var _sector_script: Node
var _hud: Node

# --- TEXTURE ---
var drone_texture: Texture2D = preload("res://textures/units/shardling/Shardling.png")
## Mid-mounted healing emitter. Sits at the chassis center, rotates
## independently to track the heal target, and the green beam exits
## from the bottom edge of the rotated sprite.
var heal_head_texture: Texture2D = preload("res://textures/units/shardling/ShardlingHealingHead.png")
## Two of these flank the chassis (mid-left + mid-right, inset slightly
## from the body edges). Each rotates to aim at the current shoot
## target; bullets spawn from their muzzles, alternating sides per
## shot for a Mindustry-style two-barrel cadence.
var turret_head_texture: Texture2D = preload("res://textures/units/shardling/ShardlingTurretHead.png")

## How far inward (along the chassis local +X / -X) the turret heads
## sit from the chassis sprite's left/right edges.
const TURRET_HEAD_INSET_PX := 8.0
## Rad/sec rate at which the heads rotate toward their aim target.
## High enough that they snap quickly without looking instant.
const HEAD_ROTATION_SPEED := 10.0
## Heads are drawn at a fraction of the source-texture size so they
## sit proportionally on the chassis rather than dwarfing it. Tweak
## here if the source art changes resolution.
const HEAD_SCALE := 0.35
## Aim is stored as an offset from the chassis `facing_angle` (so 0 =
## head pointing the same direction as the body). Storing relative
## means the heads naturally rotate WITH the chassis when the body
## yaws — and they hold their last orientation when no target is
## acquired, instead of snapping back to forward.
var _healer_aim_offset: float = 0.0
# Shadow pipeline. CanvasGroup composites its CHILDREN to a private
# off-screen buffer and alpha-blends that buffer with the world below
# using the group's modulate. We need that "draw silhouettes opaque,
# then blend the whole composite at 22 % once" behaviour so overlapping
# turret-head shadows don't compound to darker patches under the chassis.
# `_shadow_canvas` is the group (it doesn't draw its own visuals);
# `_shadow_drawer` is a Node2D child whose `draw` signal emits the
# silhouettes — CanvasGroup only buffers child draws, not its own.
var _shadow_canvas: CanvasGroup = null
var _shadow_drawer: Node2D = null
## Each turret head tracks the target from its own world-space pivot,
## so a close target makes the two heads visibly toe in instead of
## staying perfect mirrors. Left / right are independent.
var _turret_aim_offset_left: float = 0.0
var _turret_aim_offset_right: float = 0.0
## True when the chassis has a live combat aim this frame (manual
## fire or auto-acquired enemy/building). When false, the turret aim
## offset is held steady so the heads keep their last pose.
var _has_turret_aim: bool = false
var _turret_aim_pos: Vector2 = Vector2.ZERO
## Toggles per shot so combat_system alternates left/right barrels.
var _next_muzzle_is_right: bool = false
## Drives the back-thruster pulse animation. Same shape as the heal /
## mining beam phases so the engine glow breathes at the same cadence
## as the lasers do.
var _thruster_phase: float = 0.0

# Anchors of cores already used as respawn targets in the current cycle.
# `_move_to_core` walks cores in nearest-first order, skipping anything
# in this list; once every existing core has been visited the list is
# reset so the cycle starts again at the nearest.
var _used_respawn_cores: Array[Vector2i] = []

# --- AI SHARDLING ---
# When a sector has multiple LUMINA cores, main.gd spawns one extra
# PlayerDrone instance per non-primary core with ai_controlled = true.
# Those AI shardlings skip player input + mining and instead run a
# priority loop: assist with builds → shoot enemies → heal damaged
# blocks → return to their spawn core when idle.
var ai_controlled: bool = false
## True when this shardling belongs to a FEROX core. Flips every
## faction-sensitive lookup in the AI tick: heal targets become FEROX
## buildings, enemy targets become LUMINA/PLAYER units, the rebuild
## queue is consulted instead of the player's build work_order. Only
## meaningful when `ai_controlled` is also true.
var ferox_controlled: bool = false
var spawn_core_anchor: Vector2i = Vector2i(-1, -1)
# Per-AI-drone fire cooldown. Mirrors combat_system.drone_attack_speed
# for the primary drone; tracked here so each AI shardling has its
# own clock instead of fighting over the singleton in combat_system.
var _ai_fire_cooldown: float = 0.0
const _AI_BUILD_REACH_TILES := 8
const _AI_FIRE_REACH_TILES := 10
const _AI_HEAL_REACH_TILES := HEAL_RANGE_TILES
const _AI_IDLE_REACH_TILES := 0

# Per-shardling caches so the AI tick doesn't walk every placed
# building / every unit list every physics frame. Refreshed when
# their respective cooldowns hit zero.
var _cached_heal_anchor: Vector2i = Vector2i(-1, -1)
var _cached_heal_age: float = 999.0
var _cached_enemy: Node2D = null
var _cached_enemy_age: float = 999.0
var _cached_build_anchor: Vector2i = Vector2i(-1, -1)
var _cached_build_age: float = 999.0
const _AI_HEAL_CACHE_REFRESH: float = 0.5
const _AI_ENEMY_CACHE_REFRESH: float = 0.2
const _AI_BUILD_CACHE_REFRESH: float = 0.4

# --- FEROX SHARDLING REBUILD TIMER ---
# When a FEROX shardling is in build_range of its current rebuild
# target, it spends FEROX_REBUILD_TIME seconds before the building
# actually pops into existence — same pacing the rebuilder unit uses.
var _ferox_rebuild_target: Variant = null   # Dictionary from main.ferox_rebuild_queue
var _ferox_rebuild_timer: float = 0.0
const FEROX_REBUILD_TIME: float = 1.5

# --- DATA ---
# The UnitData resource loaded from player_drone.tres
var data: UnitData

# --- SETTINGS (loaded from .tres) ---
var move_speed: float
var max_health: float
var health_regen: float

# --- SETTINGS (not in .tres, specific to drone behavior) ---
@export var build_range := 10

# --- STATE ---
var health: float
var damage_cooldown := 0.0
const REGEN_DELAY := 3.0

# Smoothed velocity for drift. The drone's actual movement uses
# `_velocity_smooth` which lerps toward the input direction × speed at
# `MOVE_ACCEL` while keys are held, and decays toward zero at the slower
# `DRIFT_DECEL` when input drops, giving the shardling a brief glide
# instead of stopping cold. Both rates feed an exp-decay smoothing
# (frame-rate independent).
const MOVE_ACCEL: float = 30.0
const DRIFT_DECEL: float = 5.0
var _velocity_smooth: Vector2 = Vector2.ZERO

# --- FACING ---
var facing_angle := PI             # Current visual rotation (radians)
var _target_facing_angle := PI     # Target rotation (persists when input stops)
const ROTATION_SPEED := 8.0      # How fast the drone turns (radians/sec)
## Max angular gap (radians) between chassis facing and the requested
## movement direction before the drone is allowed to start moving.
## ~12° — small enough to feel responsive once the chassis is mostly
## pointed at the input, large enough that the drone doesn't lock up
## on tiny float drift in the rotation.
const _MOVE_FACING_THRESHOLD: float = 0.21
## How far (in pixels) to shift the sprite along its local "up" axis
## so the body center sits at the pivot. Positive = shift body toward pivot.
const SPRITE_PIVOT_OFFSET := 0.05  # Fraction of tex_size to shift

# Visual settings (loaded from .tres)
var drone_color: Color
var range_color: Color
var range_border_color: Color

# --- MINING ---
var mining_target: Variant = null   # Vector2i ore grid pos, or null
# Last ore tile the drone was actively mining before building preempted it.
# Let the drone auto-resume on the same ore once the queued build finishes,
# so pause→queue→build→repause→mine doesn't lose the player's focus.
# Cleared by explicit re-click (user-intended stop), never by auto-stop.
var _resume_mining_target: Variant = null  # Vector2i or null
var _resume_mining_item_id: StringName = &""
var mining_timer: float = 0.0
var mining_item_id: StringName = &""
var mining_speed: float = 1.0       # Loaded from mechanical_drill production_time
var mined_inventory: Dictionary = {} # item_id -> count (held before delivery)
const CORE_DELIVERY_RANGE := 15     # Chebyshev tile distance for auto-delivery
const MINING_RANGE := 7             # Max tile distance before mining stops
const TRANSFER_DURATION := 0.3      # Seconds for item to fly to core
const MAX_INVENTORY := 60           # Max items the drone can carry before mining pauses
var _transfer_items: Array = []     # [{pos:Vector2, target:Vector2, item_id:StringName, icon:Texture2D, t:float}]
var _mining_beam_phase: float = 0.0 # For pulsing animation

# --- HEAL LASER ---
# Default: drag-shoot drives combat, AI auto-heals nearby damage.
# Press X to swap: drag-heal drives the laser, AI auto-shoots.
const HEAL_RANGE_TILES := 6
const HEAL_RATE := 30.0              # HP / second applied while a target is locked
const HEAL_SNAP_ACQUIRE_DEG := 25.0  # Aim must be within this angle to grab a target
const HEAL_SNAP_RELEASE_DEG := 40.0  # …and within this to keep it (hysteresis)
var heal_mode: bool = false
var heal_target: Variant = null      # Vector2i grid anchor of the locked target, or null
var _heal_beam_endpoint: Vector2 = Vector2.ZERO
var _heal_beam_active: bool = false
var _heal_beam_phase: float = 0.0

# --- DRAG-DROP DEPOSIT ---
var _dragging_inventory := false     # True while left-click held on inventory display



func _terrain_ref() -> Node2D:
	if _terrain == null:
		_terrain = get_node_or_null("/root/Main/TerrainSystem")
	return _terrain

func _unit_mgr_ref() -> Node:
	if _unit_mgr == null:
		_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	return _unit_mgr

func _sector_script_ref() -> Node:
	if _sector_script == null:
		_sector_script = get_node_or_null("/root/Main/SectorScript")
	return _sector_script


## True if the drone's beam can reach the ore at `cell`. Wall ores live
## inside walls and are always reachable from outside. Floor ores sit
## on the surface, so any block placed at the cell — including a
## platform — buries them and the drone can't beam through.
func _drone_can_reach_ore(cell: Vector2i, ore_data) -> bool:
	if ore_data == null:
		return false
	# Wall-embedded ores keep the original "always mineable" rule.
	if not ore_data.tags.has("floor_ore"):
		return true
	return not main.placed_buildings.has(cell)

func _hud_ref() -> Node:
	if _hud == null:
		_hud = get_node_or_null("/root/Main/HUD")
	return _hud


func _ready() -> void:
	# Sit above the launch-animation overlays (main canvas z=4090,
	# core overlay z=86, flap overlay z=85), the cable overlay (52),
	# and fog (80). z_index max in Godot 4 is 4096, so 4095 is the
	# highest we can go without clipping. The shardling stays visible
	# above every animation layer.
	z_index = 4095
	z_as_relative = false
	# Shadow render pipeline. CanvasGroup composites its CHILDREN to
	# a private off-screen buffer and then alpha-blends that buffer
	# with the world below using the group's modulate — exactly the
	# "draw silhouettes opaque, blend the whole thing once at 22 %"
	# behaviour we need so overlapping chassis + turret-head shadows
	# don't compound to darker patches.
	#
	# Z setup: z_as_relative = false and z_index = 4094 so the
	# composite is locked one z-tier below the drone (4095) regardless
	# of how the parent hierarchy is configured. This puts the
	# shadow definitively above ground units (z=0) and placed blocks
	# (z=50).
	_shadow_canvas = CanvasGroup.new()
	_shadow_canvas.name = "FlyingShadow"
	_shadow_canvas.modulate = Color(1.0, 1.0, 1.0, 0.22)
	_shadow_canvas.z_index = 4094
	_shadow_canvas.z_as_relative = false
	# Shadow offset is hundreds of px below+left of the drone origin;
	# the default fit_margin (10 px) would clip everything outside that
	# tiny window. 1024 covers any reasonable zoom / drone scale.
	_shadow_canvas.fit_margin = 1024.0
	_shadow_canvas.clear_margin = 256.0
	# Drawer child — CanvasGroup buffers only CHILD draws, not its own,
	# so the silhouettes live on a Node2D inside the group.
	_shadow_drawer = Node2D.new()
	_shadow_drawer.name = "ShadowDrawer"
	_shadow_drawer.draw.connect(_draw_flying_shadow_on_canvas)
	_shadow_canvas.add_child(_shadow_drawer)
	add_child(_shadow_canvas)
	# Wait for Registry essentials (units + blocks) — drone doesn't need the
	# non-essential planet/sector data, so don't block on those.
	while not Registry.essentials_loaded:
		await get_tree().process_frame
	await get_tree().process_frame

	_terrain = get_node_or_null("/root/Main/TerrainSystem")
	_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	_sector_script = get_node_or_null("/root/Main/SectorScript")
	_hud = get_node_or_null("/root/Main/HUD")

	# Load stats from the .tres file. UnitData.move_speed is stored in
	# tiles/sec; convert once here into the pixels/sec value the movement
	# code integrates against.
	data = Registry.get_unit(&"player_drone")
	if data:
		move_speed = data.move_speed * float(main.GRID_SIZE)
		max_health = data.max_health
		health_regen = data.health_regen
		drone_color = data.color
	else:
		# Fallbacks in case .tres is missing (1.3 t/s * GRID_SIZE px/tile)
		push_warning("PlayerDrone: player_drone.tres not found in Registry!")
		move_speed = 1.3 * float(main.GRID_SIZE)
		max_health = 100.0
		health_regen = 5.0
		drone_color = Color(0.3, 0.9, 1.0)

	range_color = Color(drone_color.r, drone_color.g, drone_color.b, 0.08)
	range_border_color = Color(drone_color.r, drone_color.g, drone_color.b, 0.2)

	mining_speed = 0.2
	# Init mined_inventory slots
	for item in Registry.items_list:
		if not mined_inventory.has(item.id):
			mined_inventory[item.id] = 0

	health = max_health
	if ai_controlled:
		# AI shardlings don't accept input and start parked on their
		# assigned home core (not whatever the respawn cycle picks).
		set_process_input(false)
		set_process_unhandled_input(false)
		_park_on_spawn_core()
	else:
		_move_to_core()


func _process(delta: float) -> void:
	_handle_movement(delta)
	_handle_regen(delta)
	_handle_destroy()
	_handle_mining(delta)
	_handle_healing(delta)
	if ai_controlled:
		_ai_fire_tick(delta)
	# Pulse phases freeze with the world — keeps the beams / thrusters
	# visually still during pause instead of shimmering on a frozen scene.
	var paused: bool = "world_paused" in main and main.world_paused
	if not paused:
		_heal_beam_phase += delta * 3.0
		_thruster_phase += delta * 4.0
	_update_transfers(delta)
	_update_head_aim(delta)
	# Shadow visibility tracks the controlled state. The shadow lives
	# on its own CanvasGroup with an independent draw signal, so it
	# doesn't ride along with _draw's early-return. Toggle the canvas
	# directly each frame.
	if _shadow_canvas != null:
		var um = _unit_mgr_ref()
		_shadow_canvas.visible = not (um != null and um.controlled_entity != null)
	queue_redraw()


## Drives both head rotations independently of the chassis. Healer
## tracks `_heal_beam_endpoint` whenever the beam is live; the two
## turret heads share an angle that tracks the same target the
## combat system would shoot at this frame (mouse cursor under
## manual fire, otherwise the nearest enemy unit/building inside
## drone range). Falls back to the chassis facing when no aim is
## available so idle heads don't lock to a stale direction.
func _update_head_aim(delta: float) -> void:
	# Pause freezes head rotation in place — combat is gated on
	# `world_paused` already, so the heads were aiming at a target
	# they couldn't actually shoot. Holding the offset keeps the
	# pose stable while the world is frozen.
	if "world_paused" in main and main.world_paused:
		return

	# Whichever head the player is currently driving with the cursor
	# tracks the mouse continuously; the OTHER head runs on AI auto-aim
	# (only updates when an actual target is acquired, otherwise holds
	# its last pose). Default mode → turret heads on cursor, healer on
	# heal AI. Heal mode → healer on cursor, turret heads on shoot AI.
	var healer_aim_pos: Variant = _pick_healer_aim_pos()
	if healer_aim_pos != null:
		var d: Vector2 = (healer_aim_pos as Vector2) - position
		if d.length_squared() > 1.0:
			var world_angle: float = d.angle() + PI / 2.0 + PI
			var target_offset: float = wrapf(world_angle - facing_angle, -PI, PI)
			_healer_aim_offset = _smooth_angle(_healer_aim_offset, target_offset, delta)

	# Turret aim — each head tracks the target from its own world-space
	# pivot, so they aim at the SAME target but the angles differ when
	# the target is close (the two heads visibly toe in instead of
	# being perfect mirrors). With no target both offsets are held
	# steady, naturally rotating WITH the body via `facing_angle + offset`.
	_has_turret_aim = false
	var aim_pos: Variant = _pick_turret_aim_pos()
	if aim_pos != null:
		_has_turret_aim = true
		_turret_aim_pos = aim_pos as Vector2
		for right_side in [false, true]:
			var head_world: Vector2 = _turret_world_center(right_side)
			var dt: Vector2 = _turret_aim_pos - head_world
			if dt.length_squared() <= 1.0:
				continue
			var world_angle_t: float = dt.angle() + PI / 2.0 + PI
			var target_offset_t: float = wrapf(world_angle_t - facing_angle, -PI, PI)
			if right_side:
				_turret_aim_offset_right = _smooth_angle(_turret_aim_offset_right, target_offset_t, delta)
			else:
				_turret_aim_offset_left = _smooth_angle(_turret_aim_offset_left, target_offset_t, delta)


func _smooth_angle(current: float, target: float, delta: float) -> float:
	var diff: float = wrapf(target - current, -PI, PI)
	if absf(diff) < 0.01:
		return target
	var step: float = signf(diff) * HEAD_ROTATION_SPEED * delta
	if absf(step) > absf(diff):
		return target
	return wrapf(current + step, -PI, PI)


## Picks the world position the turret heads should aim at this frame.
## Default mode → mouse cursor (continuous tracking, even when not
## firing). Heal mode → AI auto-shoot target (nearest enemy unit, then
## nearest enemy building inside drone range). Returns null when the
## drone isn't allowed to point its turrets (controlling a unit /
## mining / terrain paint), so the heads hold their last pose.
func _pick_turret_aim_pos() -> Variant:
	if not _drone_in_control():
		return null
	# AI shardlings don't have a player at the wheel — their turret
	# heads should track the AI auto-fire target, never the cursor.
	if ai_controlled:
		return _ai_shoot_target_pos()
	if not heal_mode:
		# Default mode: heads follow the cursor unconditionally so the
		# player can read where the next bullet will go without having
		# to drag-fire first. GUI hovers / selected blocks don't matter
		# for *aim* — only for actually firing — so we don't gate them.
		return get_global_mouse_position()
	# Heal mode: turret heads auto-aim at the nearest combat target.
	return _ai_shoot_target_pos()


## Picks the world position the healer head should aim at this frame.
## Heal mode → mouse cursor (continuous tracking). Default mode → the
## active heal-beam endpoint (the AI heal target, when one is locked).
## Returns null when no heal aim is available so the head holds its
## last pose instead of snapping back to chassis forward.
func _pick_healer_aim_pos() -> Variant:
	if not _drone_in_control():
		return null
	# AI shardlings ignore the cursor; their healer head follows
	# whatever target the AI auto-heal locked onto, falling back to
	# null so the head holds its last pose instead of tracking the
	# player's mouse on a different drone.
	if ai_controlled:
		if _heal_beam_active:
			return _heal_beam_endpoint
		return null
	if heal_mode:
		return get_global_mouse_position()
	if _heal_beam_active:
		return _heal_beam_endpoint
	return null


## Drone is "in control" when no overriding mode is taking the
## controls (controlling a unit/turret directly, mining the ground,
## terrain paint mode in the editor). Used to gate cursor-tracking on
## the heads so they don't try to follow the mouse while the player
## is doing something else with it.
func _drone_in_control() -> bool:
	var unit_mgr = _unit_mgr_ref()
	if unit_mgr and unit_mgr.controlled_entity != null:
		return false
	if mining_target != null:
		return false
	var terrain = _terrain_ref()
	if terrain and "paint_mode" in terrain and terrain.paint_mode:
		return false
	return true


## Shared AI auto-target pick used by combat + the heads when one or
## the other side is on AI duty. Returns the world position of the
## nearest enemy unit in range, falling back to the nearest enemy
## building, or null if neither exists in range.
##
## AI shardlings (`ai_controlled` = true) skip the building fallback
## entirely — only the primary player-controlled drone takes on
## hostile buildings when no enemy units are around.
func _ai_shoot_target_pos() -> Variant:
	var unit_mgr = _unit_mgr_ref()
	var combat = main.get_node_or_null("CombatSystem")
	var range_px: float = 4.0 * main.GRID_SIZE
	if combat and "drone_range" in combat:
		range_px = float(combat.drone_range) * main.GRID_SIZE
	var enemies: Array[Node2D] = unit_mgr.enemies if unit_mgr else [] as Array[Node2D]
	var nearest: Node2D = null
	var best_d2: float = range_px * range_px
	for e in enemies:
		if e == null or not is_instance_valid(e):
			continue
		var d2: float = position.distance_squared_to(e.position)
		if d2 <= best_d2:
			best_d2 = d2
			nearest = e
	if nearest != null:
		return nearest.position
	if ai_controlled:
		return null
	if combat and combat.has_method("_find_nearest_enemy_building"):
		var nb: Vector2i = combat._find_nearest_enemy_building(position, range_px)
		if nb != Vector2i(-9999, -9999):
			return main.grid_to_world(nb) + Vector2(main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5)
	return null

func _input(event: InputEvent) -> void:
	# Defensive: during a scene swap the drone can receive one more
	# input event after its `main` reference (resolved via @onready)
	# has been freed. Bail out instead of dereferencing null.
	if main == null or not is_instance_valid(main):
		return
	if main.is_ui_blocking():
		return
	if event.is_action_pressed("respawn"):
		health = max_health
		_clear_inventory()
		_move_to_core()
	# X swaps the drone between drag-shoot (default) and drag-heal modes.
	# When healing is on the player drives the laser with the mouse and an
	# auto-shooter handles enemies; when healing is off the player drags to
	# shoot and an auto-healer mends damaged blocks in range.
	if event.is_action_pressed("toggle_heal_mode"):
		heal_mode = not heal_mode
		heal_target = null
		_heal_beam_active = false
		get_viewport().set_input_as_handled()




func _unhandled_input(event: InputEvent) -> void:
	if main.is_ui_blocking():
		return

	# Inventory drag (deposit drone storage onto a block / trash on bare
	# terrain) is locked while the world is paused — moving items in or
	# out of the drone during a freeze would smuggle resources around the
	# pause-aware production / consumption ticks.
	var paused_world: bool = "world_paused" in main and main.world_paused
	# --- Drag-drop inventory deposit ---
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# Start drag if clicking near the drone and inventory is non-empty
			if _get_inventory_total() > 0 and main.selected_building == &"" and not paused_world:
				var mouse_world = get_global_mouse_position()
				if mouse_world.distance_to(position) < 40.0:
					var terrain = _terrain_ref()
					var grid_pos: Vector2i = main.world_to_grid(mouse_world)
					# Only start drag if NOT clicking on ore (ore click = mining)
					if terrain == null or not terrain.ore_tiles.has(grid_pos):
						_dragging_inventory = true
						get_viewport().set_input_as_handled()
						return
		else:
			if _dragging_inventory:
				_dragging_inventory = false
				# Resolve the drop cell + block once, then branch:
				#   (1) over a LUMINA core → deposit everything into
				#       main.resources (subject to core capacity)
				#   (2) over a storage-tagged block or factory-input block
				#       → fill each slot item-by-item until the block's
				#       cap is hit, keep the rest
				#   (3) over bare terrain (no block or a non-accepting
				#       block) → delete the held inventory
				var mouse_world = get_global_mouse_position()
				var drop_cell: Vector2i = main.world_to_grid(mouse_world)
				var handled := false
				if main.placed_buildings.has(drop_cell):
					var drop_anchor: Vector2i = main.building_origins.get(drop_cell, drop_cell)
					var drop_data = Registry.get_block(main.placed_buildings[drop_anchor])
					var bs = get_node_or_null("/root/Main/BuildingSystem")
					# Core branch (shared resource pool).
					if drop_data and drop_data.tags.has("core") \
							and main.get_building_faction(drop_anchor) == main.Faction.LUMINA:
						for item_id in mined_inventory.keys():
							var have: int = int(mined_inventory[item_id])
							# Coal / sand are incinerated at the core —
							# the held stack just vanishes (no add to
							# main.resources, no overflow).
							if main.has_method("is_incinerated_at_core") and main.is_incinerated_at_core(item_id):
								mined_inventory[item_id] = 0
								continue
							while have > 0:
								if main.has_method("can_accept_resource") \
										and not main.can_accept_resource(item_id):
									break
								main.resources[item_id] = int(main.resources.get(item_id, 0)) + 1
								have -= 1
							mined_inventory[item_id] = have
						main.resources_changed.emit(main.resources)
						handled = true
					# Non-core block that can accept items.
					elif bs and bs.has_method("_block_accepts_item"):
						for item_id in mined_inventory.keys():
							var held: int = int(mined_inventory[item_id])
							if held <= 0:
								continue
							if not bs._block_accepts_item(drop_anchor, item_id):
								continue
							var accepted: int = bs._deposit_items_into_block(drop_anchor, item_id, held)
							if accepted > 0:
								mined_inventory[item_id] = held - accepted
								handled = true
				# Drop onto bare terrain (nothing placed at drop_cell) is
				# the explicit "trash everything" gesture. Dropping on a
				# block that exists but doesn't accept the held items
				# keeps the inventory — it'd be mean to vaporize a
				# stockpile because the player missed the intended block.
				if not handled and not main.placed_buildings.has(drop_cell):
					_clear_inventory()
				get_viewport().set_input_as_handled()
				return

	# Left-click: check if clicking on ore to start mining
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if _dragging_inventory:
			return
		# Don't mine if a building is selected or controlling a unit
		if main.selected_building != &"":
			return
		var unit_mgr = _unit_mgr_ref()
		if unit_mgr and unit_mgr.controlled_entity != null:
			return
		var terrain = _terrain_ref()
		if terrain == null:
			return

		var mouse_world = get_global_mouse_position()
		var grid_pos: Vector2i = main.world_to_grid(mouse_world)

		if terrain.ore_tiles.has(grid_pos):
			if mining_target == grid_pos:
				# Re-click same ore — stop mining. Explicit user stop
				# should also cancel any pending auto-resume.
				mining_target = null
				mining_item_id = &""
				_resume_mining_target = null
				_resume_mining_item_id = &""
			else:
				# Start mining this ore — but if it's a floor ore that's
				# currently buried under a block, the drone can't reach it.
				# Wall ores stay mineable through the wall as before.
				var ore_data = terrain.get_ore_at(grid_pos)
				if ore_data and ore_data.minable_resource != &"" \
						and _drone_can_reach_ore(grid_pos, ore_data):
					mining_target = grid_pos
					mining_item_id = ore_data.minable_resource
					mining_timer = mining_speed
					_resume_mining_target = grid_pos
					_resume_mining_item_id = mining_item_id
			get_viewport().set_input_as_handled()
		elif mining_target != null:
			# Currently mining — ignore non-ore clicks (don't shoot or stop mining)
			get_viewport().set_input_as_handled()
		# If not mining and clicked non-ore, let the event pass through (combat can handle it)

func _handle_movement(delta: float) -> void:
	# Skip movement when a blocking UI is open
	# AI shardlings ignore player input + UI gates and run their own
	# priority loop. Pause + controlled-entity still freeze the AI to
	# keep the world-paused contract clean.
	if ai_controlled:
		if main.world_paused:
			return
		_ai_movement_tick(delta)
		return

	if main.is_ui_blocking():
		return
	# Skip drone movement when world is paused (camera pans independently)
	if main.world_paused:
		return
	# Skip drone movement when manually controlling a unit/turret
	var unit_mgr = _unit_mgr_ref()
	if unit_mgr and unit_mgr.controlled_entity != null:
		return

	var move_x = Input.get_axis("move_left", "move_right")
	var move_y = Input.get_axis("move_up", "move_down")
	var input_dir = Vector2(move_x, move_y)
	var has_input: bool = input_dir.length() > 0

	# Focus target = whatever we're mining OR currently building. Used for
	# both facing-lock and the away-from-target slowdown.
	var focus_pos = _get_focus_world_pos()

	if has_input:
		input_dir = input_dir.normalized()
		# Don't override rotation while focused — focus locks rotation toward
		# the ore/building. Only free movement steers the facing.
		if focus_pos == null:
			_target_facing_angle = input_dir.angle() + PI / 2.0 + PI  # Tip faces movement direction

	# While focused, lock rotation toward the focus point (non-mining case
	# previously had no lock — now builds behave the same as mining).
	if focus_pos != null:
		var dir_to_focus: Vector2 = (focus_pos as Vector2) - position
		if dir_to_focus.length_squared() > 1.0:
			_target_facing_angle = dir_to_focus.angle() + PI / 2.0 + PI
	elif not has_input:
		# Free movement, no input held. While the drone is still drifting
		# (smoothed velocity hasn't decayed), aim the facing along the
		# drift direction so the body doesn't slide sideways/backwards
		# pointing the wrong way. Once the drift effectively stops, lock
		# the rotation target at the current facing so the drone holds
		# whatever angle it ended up at instead of continuing to swing
		# toward the last cardinal input direction.
		if _velocity_smooth.length_squared() > 100.0:
			_target_facing_angle = _velocity_smooth.angle() + PI / 2.0 + PI
		else:
			_target_facing_angle = facing_angle

	# Always rotate toward target at constant speed (continues after input stops)
	var angle_diff: float = wrapf(_target_facing_angle - facing_angle, -PI, PI)
	if absf(angle_diff) > 0.01:
		var rotate_amount: float = signf(angle_diff) * ROTATION_SPEED * delta
		if absf(rotate_amount) > absf(angle_diff):
			facing_angle = _target_facing_angle
		else:
			facing_angle = wrapf(facing_angle + rotate_amount, -PI, PI)

	# Speed is halved when moving AWAY from the current focus (ore OR build
	# target). Toward the focus — or with no focus — run at full speed.
	var effective_speed: float = move_speed
	if focus_pos != null and has_input:
		var to_focus: Vector2 = ((focus_pos as Vector2) - position).normalized()
		if input_dir.dot(to_focus) < 0.0:
			effective_speed = move_speed * 0.5

	# Movement happens immediately in the input direction — the chassis
	# rotates toward that direction on its own (see the rotation block
	# above), but the player doesn't have to wait for it to line up.
	# Strafing / circle-strafing reads naturally this way.
	var target_velocity: Vector2 = Vector2.ZERO
	if has_input:
		target_velocity = input_dir * effective_speed
	var rate: float = MOVE_ACCEL if has_input else DRIFT_DECEL
	var smoothing: float = 1.0 - exp(-rate * delta)
	_velocity_smooth = _velocity_smooth.lerp(target_velocity, smoothing)
	# Snap to zero once the drift gets imperceptible so the drone isn't
	# perpetually sub-pixel-sliding.
	if not has_input and _velocity_smooth.length_squared() < 1.0:
		_velocity_smooth = Vector2.ZERO

	var new_pos: Vector2 = position + _velocity_smooth * delta
	new_pos.x = clamp(new_pos.x, 0.0, main.GRID_SIZE * main.GRID_WIDTH)
	new_pos.y = clamp(new_pos.y, 0.0, main.GRID_SIZE * main.GRID_HEIGHT)

	# Block drone from entering hidden tiles
	var sector_script = _sector_script_ref()
	if sector_script:
		var target_grid: Vector2i = main.world_to_grid(new_pos)
		target_grid.x = clampi(target_grid.x, 0, main.GRID_WIDTH - 1)
		target_grid.y = clampi(target_grid.y, 0, main.GRID_HEIGHT - 1)
		if sector_script.is_tile_hidden(target_grid):
			# Try each axis independently (wall-slide)
			var pos_x := Vector2(new_pos.x, position.y)
			var gx: Vector2i = main.world_to_grid(pos_x)
			gx.x = clampi(gx.x, 0, main.GRID_WIDTH - 1)
			gx.y = clampi(gx.y, 0, main.GRID_HEIGHT - 1)
			if not sector_script.is_tile_hidden(gx):
				position.x = new_pos.x
			var pos_y := Vector2(position.x, new_pos.y)
			var gy: Vector2i = main.world_to_grid(pos_y)
			gy.x = clampi(gy.x, 0, main.GRID_WIDTH - 1)
			gy.y = clampi(gy.y, 0, main.GRID_HEIGHT - 1)
			if not sector_script.is_tile_hidden(gy):
				position.y = new_pos.y
		else:
			position = new_pos
	else:
		position = new_pos


func _handle_regen(delta: float) -> void:
	if damage_cooldown > 0:
		damage_cooldown -= delta
	elif health < max_health:
		health = min(health + health_regen * delta, max_health)


func _handle_destroy() -> void:
	# Destruction is now handled by building_system's demolish drag system
	# (queues deconstruction with animation instead of instant destroy)
	pass


# --- MINING LOGIC ---

func _handle_mining(delta: float) -> void:
	# AI shardlings don't mine — mining is the primary drone's job.
	if ai_controlled:
		return
	# Pause mining when the game is paused
	if main.world_paused:
		return

	# Building/deconstructing fully CLEARS the mining target so the laser and
	# the "move-away slowdown" both stop. Only pause mining when there's an
	# in-range work item the drone could actually be building this frame —
	# distant queued work no longer holds the drone off its ore. The current
	# mining target is stashed so we can auto-resume once the build is done.
	if _has_in_range_work():
		if mining_target != null:
			_resume_mining_target = mining_target
			_resume_mining_item_id = mining_item_id
			mining_target = null
			mining_item_id = &""
		return

	# No active work and no active mining: if we had one stashed from before
	# the build, pick it back up (still valid ore, still in range).
	if mining_target == null and _resume_mining_target != null:
		var t = _terrain_ref()
		var rg: Vector2i = _resume_mining_target
		var in_range := false
		if t:
			var dg: Vector2i = main.world_to_grid(position)
			in_range = maxi(absi(dg.x - rg.x), absi(dg.y - rg.y)) <= MINING_RANGE
		if t and t.ore_tiles.has(rg) and in_range:
			mining_target = rg
			mining_item_id = _resume_mining_item_id
			mining_timer = mining_speed
		else:
			# Resume condition no longer satisfied — drop the memory
			# so we don't spuriously re-arm later.
			_resume_mining_target = null
			_resume_mining_item_id = &""

	if mining_target == null:
		return

	# Validate ore still exists AND that the drone can still reach it —
	# a floor ore that just got covered by a placement mid-mining stops
	# the drone immediately.
	var terrain = _terrain_ref()
	if terrain == null or not terrain.ore_tiles.has(mining_target):
		mining_target = null
		mining_item_id = &""
		_resume_mining_target = null
		_resume_mining_item_id = &""
		return
	var live_ore = terrain.get_ore_at(mining_target)
	if not _drone_can_reach_ore(mining_target, live_ore):
		mining_target = null
		mining_item_id = &""
		_resume_mining_target = null
		_resume_mining_item_id = &""
		return

	# Stop mining if drone moves too far from the ore
	var drone_grid: Vector2i = main.world_to_grid(position)
	var dx: int = absi(drone_grid.x - mining_target.x)
	var dy: int = absi(drone_grid.y - mining_target.y)
	if maxi(dx, dy) > MINING_RANGE:
		mining_target = null
		mining_item_id = &""
		_resume_mining_target = null
		_resume_mining_item_id = &""
		return

	# Lock rotation toward the ore while mining
	var ore_world: Vector2 = main.grid_to_world(mining_target) + Vector2(main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5)
	var dir_to_ore: Vector2 = (ore_world - position)
	if dir_to_ore.length() > 1.0:
		_target_facing_angle = dir_to_ore.angle() + PI / 2.0 + PI

	_mining_beam_phase += delta * 3.0  # For pulsing animation

	mining_timer -= delta
	if mining_timer <= 0.0:
		mining_timer += mining_speed
		_mine_item()


## Returns the total number of items in the drone's mined inventory.
func _get_inventory_total() -> int:
	var total := 0
	for item_id in mined_inventory:
		total += int(mined_inventory[item_id])
	return total


func _mine_item() -> void:
	if mining_item_id == &"":
		return

	# Inventory full — stop collecting
	if _get_inventory_total() >= MAX_INVENTORY:
		return

	# Add to inventory
	mined_inventory[mining_item_id] = mined_inventory.get(mining_item_id, 0) + 1

	# Emit signals
	main.core_unit_item_mined.emit(mining_item_id)
	main.item_mined.emit(mining_item_id)

	# If close to core, auto-deliver
	_try_deliver_to_core(mining_item_id)


func _try_deliver_to_core(item_id: StringName) -> void:
	var drone_grid: Vector2i = main.world_to_grid(position)
	var core_center := Vector2i(
		main.core_position.x + 1,  # Approximate center of 3x3 core
		main.core_position.y + 1
	)
	var dist := maxi(absi(drone_grid.x - core_center.x), absi(drone_grid.y - core_center.y))
	if dist > CORE_DELIVERY_RANGE:
		return

	# Only deliver if we have this item
	if mined_inventory.get(item_id, 0) <= 0:
		return

	# Skip the auto-deliver entirely when the core can't accept this
	# resource (storage cap hit). Without this gate the drone would
	# decrement the inventory, spawn a transfer animation, and then
	# `_update_transfers` would refund the item on arrival — visually
	# noisy for a no-op. The mined item just stays in the drone's bag
	# until something frees up space.
	if main.has_method("can_accept_resource") and not main.can_accept_resource(item_id):
		return

	mined_inventory[item_id] -= 1

	# Spawn transfer animation
	var core_world: Vector2 = main.grid_to_world(core_center) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
	var item_data = Registry.get_item(item_id)
	var icon: Texture2D = item_data.icon if item_data else null

	_transfer_items.append({
		"start": position,
		"target": core_world,
		"item_id": item_id,
		"icon": icon,
		"t": 0.0,
	})


func _update_transfers(delta: float) -> void:
	var to_remove: Array[int] = []
	for i in range(_transfer_items.size()):
		_transfer_items[i]["t"] += delta / TRANSFER_DURATION
		if _transfer_items[i]["t"] >= 1.0:
			# Arrived at core — incinerate or deposit.
			var item_id: StringName = _transfer_items[i]["item_id"]
			# Coal / sand vanish at the core (fuel + waste). Still emit
			# `item_absorbed_in_core` so tech-tree progression unlocks
			# fire on the first delivery.
			if main.has_method("is_incinerated_at_core") and main.is_incinerated_at_core(item_id):
				main.item_absorbed_in_core.emit(item_id)
				to_remove.append(i)
				continue
			if not main.can_accept_resource(item_id):
				# Storage full — return item to mined inventory
				mined_inventory[item_id] = mined_inventory.get(item_id, 0) + 1
				to_remove.append(i)
				continue
			if main.resources.has(item_id):
				main.resources[item_id] += 1
			else:
				main.resources[item_id] = 1
			main.resources_changed.emit(main.resources)
			main.item_absorbed_in_core.emit(item_id)
			to_remove.append(i)

	# Remove completed transfers (reverse order)
	for i in range(to_remove.size() - 1, -1, -1):
		_transfer_items.remove_at(to_remove[i])


# --- PUBLIC FUNCTIONS ---

func take_damage(amount: float) -> void:
	# Apply armor from .tres data
	var actual_damage = amount
	if data:
		actual_damage = data.calc_damage_taken(amount)
	health -= actual_damage
	damage_cooldown = REGEN_DELAY
	if health <= 0:
		health = 0
		_on_death()


func _on_death() -> void:
	# Boom + ruin decal at the death spot before we teleport home.
	var overlay = main.get_node_or_null("ParticleOverlay") if main else null
	if overlay:
		if overlay.has_method("spawn_burst"):
			overlay.spawn_burst(position, "explosion_unit")
		if overlay.has_method("spawn_unit_ruins"):
			var vis_size: float = data.visual_size if data else 14.0
			overlay.spawn_unit_ruins(position, vis_size)
	health = max_health
	_clear_inventory()
	if ai_controlled:
		# AI shardlings respawn on their assigned home core, not the
		# shared respawn cycle the primary drone uses.
		_park_on_spawn_core()
	else:
		_move_to_core()


## Drops the mined inventory. Called on any respawn path — death, manual
## respawn hotkey, and release-from-controlled-entity — since any of those
## are "start a new session" from the drone's perspective and holding onto
## pre-session mined items is a free teleport-to-core shortcut.
func _clear_inventory() -> void:
	mined_inventory.clear()
	for item in Registry.items_list:
		mined_inventory[item.id] = 0


## Respawns the drone at a specific LUMINA core anchor (used by Ctrl+click
## on a core). Heals, clears mined inventory, teleports onto the core's
## footprint, and registers the anchor in the cycle so the auto-cycle
## picks a different one next time.
func respawn_at_core(anchor: Vector2i) -> void:
	if not main.placed_buildings.has(anchor):
		return
	var core_data: BlockData = Registry.get_block(main.placed_buildings[anchor])
	if core_data == null or not core_data.tags.has("core"):
		return
	health = max_health
	_clear_inventory()
	var core_size: Vector2i = core_data.grid_size
	position = Vector2(
		(anchor.x + core_size.x / 2.0) * main.GRID_SIZE,
		(anchor.y + core_size.y / 2.0) * main.GRID_SIZE
	)
	_velocity_smooth = Vector2.ZERO
	_reset_orientation()
	if not _used_respawn_cores.has(anchor):
		_used_respawn_cores.append(anchor)


func _move_to_core() -> void:
	# Cycle through cores across consecutive respawns: first respawn picks
	# the nearest core, subsequent ones step to the next-nearest core that
	# hasn't been used yet, and once every core has been used the cycle
	# resets and starts again at the nearest. Falls back to the legacy
	# `main.core_position` if no LUMINA core is reachable.
	var anchor: Vector2i = _next_respawn_core_anchor(position)
	var core_pos: Vector2i
	var core_data: BlockData = null
	if anchor != Vector2i(-1, -1):
		core_pos = anchor
		core_data = Registry.get_block(main.placed_buildings[anchor])
		_used_respawn_cores.append(anchor)
	else:
		core_pos = main.core_position
		core_data = Registry.get_block(&"core")
	var core_size: Vector2i = core_data.grid_size if core_data else Vector2i(3, 3)
	position = Vector2(
		(core_pos.x + core_size.x / 2.0) * main.GRID_SIZE,
		(core_pos.y + core_size.y / 2.0) * main.GRID_SIZE
	)
	_velocity_smooth = Vector2.ZERO
	_reset_orientation()


## Picks the next respawn-target core: nearest LUMINA core not already
## used in the current cycle. If every existing core has been used (or
## the used list contains stale anchors that no longer exist), the
## cycle resets and the nearest core is picked. Returns Vector2i(-1,-1)
## if no LUMINA cores exist.
func _next_respawn_core_anchor(world_pos: Vector2) -> Vector2i:
	var anchors: Array = main.get_lumina_core_anchors()
	if anchors.is_empty():
		_used_respawn_cores.clear()
		return Vector2i(-1, -1)

	# Drop tracked anchors whose cores were destroyed/deconstructed so a
	# vanished core doesn't permanently shrink the active rotation.
	var live: Dictionary = {}
	for a in anchors:
		live[a] = true
	var pruned: Array[Vector2i] = []
	for a in _used_respawn_cores:
		if live.has(a):
			pruned.append(a)
	_used_respawn_cores = pruned

	# Cycle complete: every live core has been visited. Reset.
	if _used_respawn_cores.size() >= anchors.size():
		_used_respawn_cores.clear()

	var used: Dictionary = {}
	for a in _used_respawn_cores:
		used[a] = true

	var best := Vector2i(-1, -1)
	var best_dist_sq := INF
	for anchor in anchors:
		if used.has(anchor):
			continue
		var data = Registry.get_block(main.placed_buildings[anchor])
		var sz: Vector2i = data.grid_size if data else Vector2i(3, 3)
		var center := Vector2(
			(anchor.x + sz.x / 2.0) * main.GRID_SIZE,
			(anchor.y + sz.y / 2.0) * main.GRID_SIZE
		)
		var d_sq: float = world_pos.distance_squared_to(center)
		if d_sq < best_dist_sq:
			best_dist_sq = d_sq
			best = anchor
	return best


# =========================
# AI SHARDLING BEHAVIOUR
# =========================
#
# An AI-controlled PlayerDrone is one of the secondary shardlings
# spawned for non-primary cores on a sector. It runs the priority
# loop:
#   1. Assist with builds  — sit within range of a queued work_order
#      anchor so _is_in_build_range counts the AI drone toward the
#      build tick.
#   2. Shoot enemy units   — move into firing range of the nearest
#      hostile and fire via _ai_fire_tick.
#   3. Heal blocks         — move into HEAL_RANGE_TILES of the most-
#      damaged friendly block. The existing _handle_healing flow
#      handles the laser + HP application; the AI drone just provides
#      proximity.
#   4. Idle                — drift back to the spawn core and park.
# At each step the AI tries to take a single step toward the priority
# target this frame, so the behaviour reads as smooth motion rather
# than a state machine click.

func _park_on_spawn_core() -> void:
	# Place the drone at the centre of its assigned home core. Falls
	# back to the legacy `main.core_position` if the anchor is missing
	# or its block has been destroyed since the AI was spawned.
	# FEROX shardlings fall back to the nearest remaining FEROX core
	# instead of the LUMINA primary so a deferred respawn never lands
	# inside the player's base.
	var core_pos: Vector2i = spawn_core_anchor
	var data_core: BlockData = null
	if core_pos != Vector2i(-1, -1) and main.placed_buildings.has(core_pos):
		data_core = Registry.get_block(main.placed_buildings[core_pos])
	elif ferox_controlled:
		var ferox_anchors: Array = main.get_ferox_core_anchors()
		if not ferox_anchors.is_empty():
			core_pos = ferox_anchors[0]
			data_core = Registry.get_block(main.placed_buildings[core_pos])
		else:
			# No FEROX cores left — silently free the shardling.
			queue_free()
			return
	else:
		core_pos = main.core_position
		data_core = Registry.get_block(&"core")
	var sz: Vector2i = data_core.grid_size if data_core else Vector2i(3, 3)
	position = Vector2(
		(core_pos.x + sz.x / 2.0) * main.GRID_SIZE,
		(core_pos.y + sz.y / 2.0) * main.GRID_SIZE,
	)
	_velocity_smooth = Vector2.ZERO
	_reset_orientation()


func _ai_movement_tick(delta: float) -> void:
	# Age out the per-shardling AI caches. The heavy scans
	# (heal-target, build-target, enemy-in-world) only refresh when
	# their cooldown hits zero — the rest of the time we reuse the
	# previous answer, which is fine because both buildings and units
	# move slowly relative to a 60 Hz tick.
	_cached_heal_age += delta
	_cached_enemy_age += delta
	_cached_build_age += delta

	# FEROX shardlings run a different priority loop: rebuild first
	# (the user's directive), then heal damaged FEROX buildings, and
	# only as a fallback drift toward their home core. They are NOT
	# combat-focused — fire still happens via _ai_fire_tick if a
	# LUMINA unit wanders into range, but pursuit isn't a priority.
	if ferox_controlled:
		# Pause rebuild + heal while LUMINA units are pressing the base.
		# The shardling falls back to "park on home core" so it doesn't
		# wander into the fight or finish a rebuild mid-attack.
		var threat: Node2D = _ai_find_enemy_in_world()
		var threat_close: bool = false
		if threat != null:
			# 18 tiles is wide enough to cover a typical squad approach
			# without making the shardling freeze for every distant scout.
			var threat_dist: float = position.distance_to(threat.position) / float(main.GRID_SIZE)
			threat_close = threat_dist <= 18.0
		if not threat_close:
			var rebuild_anchor: Vector2i = _ferox_step_rebuild(delta)
			if rebuild_anchor != Vector2i(-1, -1):
				return
			var heal_anchor_f: Vector2i = _ai_find_heal_anchor()
			if heal_anchor_f != Vector2i(-1, -1):
				_ai_step_toward_grid(heal_anchor_f, _AI_HEAL_REACH_TILES, delta)
				return
		# Idle on home FEROX core. If the home core is gone the shardling
		# self-destructs — FEROX shardlings are bound to their spawn
		# core, they don't migrate to another one.
		if spawn_core_anchor != Vector2i(-1, -1) and main.placed_buildings.has(spawn_core_anchor):
			_ai_step_toward_grid(spawn_core_anchor, _AI_IDLE_REACH_TILES, delta)
			return
		queue_free()
		return

	# Priority 1: in-flight builds.
	var build_anchor: Vector2i = _ai_find_build_target()
	if build_anchor != Vector2i(-1, -1):
		_ai_step_toward_grid(build_anchor, _AI_BUILD_REACH_TILES, delta)
		return
	# Priority 2: hostile units (the auto-fire tick handles the trigger).
	var enemy: Node2D = _ai_find_enemy_in_world()
	if enemy != null:
		_ai_step_toward_world(enemy.position, _AI_FIRE_REACH_TILES, delta)
		return
	# Priority 3: damaged friendlies — the heal handler does the rest.
	var heal_anchor: Vector2i = _ai_find_heal_anchor()
	if heal_anchor != Vector2i(-1, -1):
		_ai_step_toward_grid(heal_anchor, _AI_HEAL_REACH_TILES, delta)
		return
	# Priority 4: drift back to spawn core and idle there.
	if spawn_core_anchor != Vector2i(-1, -1) and main.placed_buildings.has(spawn_core_anchor):
		_ai_step_toward_grid(spawn_core_anchor, _AI_IDLE_REACH_TILES, delta)
		return
	# Spawn core gone — pick a fresh LUMINA core as the fallback home.
	var anchors: Array = main.get_lumina_core_anchors()
	if not anchors.is_empty():
		spawn_core_anchor = anchors[0]


# =========================
# FEROX SHARDLING REBUILD
# =========================
# Step the FEROX shardling toward an active rebuild target, picking one
# from `main.ferox_rebuild_queue` if it doesn't have one yet. Returns
# the grid anchor it's heading toward, or (-1,-1) when there's nothing
# to rebuild this tick.

func _ferox_step_rebuild(delta: float) -> Vector2i:
	# Drop a stale target that another rebuilder already finished.
	if _ferox_rebuild_target != null:
		var gp: Vector2i = _ferox_rebuild_target["grid_pos"]
		if main.placed_buildings.has(gp):
			_ferox_rebuild_target = null
			_ferox_rebuild_timer = 0.0
	# Acquire a new target if we don't have one.
	if _ferox_rebuild_target == null:
		if main.ferox_rebuild_queue.is_empty():
			return Vector2i(-1, -1)
		_ferox_rebuild_target = main.ferox_rebuild_queue.pop_front()
		_ferox_rebuild_timer = 0.0
	var target_gp: Vector2i = _ferox_rebuild_target["grid_pos"]
	var target_world: Vector2 = main.grid_to_world(target_gp) + Vector2(
		main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5)
	var dist: float = position.distance_to(target_world)
	var build_range_px: float = float(main.GRID_SIZE) * 2.5
	if dist > build_range_px:
		_ai_step_toward_world(target_world, 2, delta)
		_ferox_rebuild_timer = 0.0
		return target_gp
	# In range — start (or continue) the build timer.
	_ferox_rebuild_timer += delta
	if _ferox_rebuild_timer >= FEROX_REBUILD_TIME:
		_ferox_finish_rebuild()
	return target_gp


func _ferox_finish_rebuild() -> void:
	if _ferox_rebuild_target == null:
		return
	var block_id: StringName = _ferox_rebuild_target["block_id"]
	var grid_pos: Vector2i = _ferox_rebuild_target["grid_pos"]
	var rot: int = _ferox_rebuild_target["rotation"]
	var bdata = Registry.get_block(block_id)
	if bdata == null:
		_ferox_rebuild_target = null
		_ferox_rebuild_timer = 0.0
		return
	# Space-clear check first so we don't bail out on resources only to
	# discover the cell is occupied.
	for x in range(bdata.grid_size.x):
		for y in range(bdata.grid_size.y):
			var tile_pos: Vector2i = grid_pos + Vector2i(x, y)
			if main.placed_buildings.has(tile_pos):
				_ferox_rebuild_target = null
				_ferox_rebuild_timer = 0.0
				return
	# FEROX core shardlings rebuild for free — the enemy faction's
	# "resource pool" is abstract (we don't simulate FEROX mining), so
	# enforcing the same item-cost gate the player faces would stall
	# every rebuild forever since `ferox_resources` is always 0. The
	# enemy rebuilder UNIT (the tier-2 `rebuild` unit) still pays from
	# the queue's affordability check; the shardling is meant to be
	# the persistent "the base self-repairs" mechanic.
	# Mirror enemy_unit._finish_rebuild's direct placement so the new
	# block goes in with the correct faction tags and the building_placed
	# signal fires for downstream bookkeeping (logistics, tech tree, etc).
	for x in range(bdata.grid_size.x):
		for y in range(bdata.grid_size.y):
			var tile_pos: Vector2i = grid_pos + Vector2i(x, y)
			main.placed_buildings[tile_pos] = block_id
			main.building_health[tile_pos] = bdata.max_health
			main.building_rotation[tile_pos] = rot
			main.building_origins[tile_pos] = grid_pos
			main.building_factions[tile_pos] = main.Faction.FEROX
	main.building_placed.emit(block_id, grid_pos)
	_ferox_rebuild_target = null
	_ferox_rebuild_timer = 0.0


func _ai_find_build_target() -> Vector2i:
	# Cached: only re-scan the work_order every _AI_BUILD_CACHE_REFRESH
	# seconds. The cache validates that the cached anchor is still
	# queued and not paused — if it isn't, force a fresh scan.
	if _cached_build_age < _AI_BUILD_CACHE_REFRESH and _cached_build_anchor != Vector2i(-1, -1):
		if "work_order" in main and main.work_order.has(_cached_build_anchor):
			var paused_c: Dictionary = main.work_paused if "work_paused" in main else {}
			if not paused_c.has(_cached_build_anchor):
				return _cached_build_anchor
	_cached_build_age = 0.0
	if not ("work_order" in main) or main.work_order.is_empty():
		_cached_build_anchor = Vector2i(-1, -1)
		return _cached_build_anchor
	var paused: Dictionary = main.work_paused if "work_paused" in main else {}
	var best := Vector2i(-1, -1)
	var best_d2: float = INF
	for a in main.work_order:
		if paused.has(a):
			continue
		var c: Vector2 = main.grid_to_world(a) + Vector2(main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5)
		var d2: float = position.distance_squared_to(c)
		if d2 < best_d2:
			best_d2 = d2
			best = a
	_cached_build_anchor = best
	return best


func _ai_find_enemy_in_world() -> Node2D:
	# Cached: reuse last scan's enemy for up to _AI_ENEMY_CACHE_REFRESH
	# seconds. Cleared on stale (dead / freed) cached target so a kill
	# triggers an immediate rescan instead of staying empty until the
	# next refresh.
	if _cached_enemy_age < _AI_ENEMY_CACHE_REFRESH and _cached_enemy != null:
		if is_instance_valid(_cached_enemy) and not (("is_dead" in _cached_enemy) and _cached_enemy.is_dead):
			return _cached_enemy
	_cached_enemy_age = 0.0
	_cached_enemy = null
	var unit_mgr = _unit_mgr_ref()
	if unit_mgr == null:
		return null
	var best: Node2D = null
	var best_d2: float = INF
	if ferox_controlled:
		# FEROX shardling: PLAYER-team units are hostile. They live in
		# unit_mgr.player_units (mirroring how the player's primary
		# drone enumerates `enemies`).
		var pool = unit_mgr.player_units if "player_units" in unit_mgr else []
		for e in pool:
			if e == null or not is_instance_valid(e):
				continue
			if "is_dead" in e and e.is_dead:
				continue
			var d2: float = position.distance_squared_to(e.position)
			if d2 < best_d2:
				best_d2 = d2
				best = e
		_cached_enemy = best
		return best
	if not ("enemies" in unit_mgr):
		return null
	for e in unit_mgr.enemies:
		if e == null or not is_instance_valid(e):
			continue
		if "is_dead" in e and e.is_dead:
			continue
		if "team" in e and e.team == UnitData.Team.PLAYER:
			continue
		var d2: float = position.distance_squared_to(e.position)
		if d2 < best_d2:
			best_d2 = d2
			best = e
	_cached_enemy = best
	return best


func _ai_find_heal_anchor() -> Vector2i:
	# Motion-search radius is intentionally unbounded: the AI drone
	# should travel anywhere on the map to reach the most-damaged
	# friendly block, then `_handle_healing` enforces the actual
	# HEAL_RANGE_TILES beam range once it arrives. Result cached for
	# _AI_HEAL_CACHE_REFRESH so we don't iterate every placed building
	# on every physics frame.
	if _cached_heal_age < _AI_HEAL_CACHE_REFRESH and _cached_heal_anchor != Vector2i(-1, -1):
		# Validate: the cached anchor must still be a damaged friendly
		# building. If it's been fully healed or destroyed, force a
		# rescan now so the drone doesn't fly to an obsolete target.
		if main.placed_buildings.has(_cached_heal_anchor):
			var bid: StringName = main.placed_buildings[_cached_heal_anchor]
			var bd = Registry.get_block(bid)
			if bd:
				var cur: float = float(main.building_health.get(_cached_heal_anchor, bd.max_health))
				if cur < bd.max_health:
					return _cached_heal_anchor
	_cached_heal_age = 0.0
	var nearby = _find_ai_heal_target(INF)
	if nearby == null:
		_cached_heal_anchor = Vector2i(-1, -1)
		return Vector2i(-1, -1)
	if nearby is Vector2i:
		_cached_heal_anchor = nearby
		return nearby
	_cached_heal_anchor = Vector2i(-1, -1)
	return Vector2i(-1, -1)


func _ai_step_toward_world(target_world: Vector2, reach_tiles: int, delta: float) -> void:
	var to: Vector2 = target_world - position
	var dist: float = to.length()
	var reach_px: float = reach_tiles * float(main.GRID_SIZE)
	# Always settle when very close, even when `reach_tiles == 0` —
	# without this floor a zero-reach idle target (e.g. parking on a
	# core's centre) would never satisfy `dist <= reach_px` due to
	# float jitter and the drone would oscillate around the centre
	# forever.
	var settle_px: float = maxf(reach_px, 4.0)
	if dist <= settle_px:
		# Snap to the exact centre when we're inside the settle ring,
		# so cores read as "drone parked on the bullseye" instead of
		# "drone wobbling near the bullseye".
		if dist < 4.0:
			position = target_world
		_velocity_smooth = Vector2.ZERO
		if to.length_squared() > 1.0:
			_target_facing_angle = to.angle() + PI / 2.0 + PI
		_ai_apply_facing(delta)
		return
	# Walk in toward the target. Use the same smoothing rates as the
	# input-driven path so the drone feels consistent.
	var dir: Vector2 = to.normalized()
	_target_facing_angle = dir.angle() + PI / 2.0 + PI
	var target_velocity: Vector2 = dir * move_speed
	var smoothing: float = 1.0 - exp(-MOVE_ACCEL * delta)
	_velocity_smooth = _velocity_smooth.lerp(target_velocity, smoothing)
	var new_pos: Vector2 = position + _velocity_smooth * delta
	new_pos.x = clamp(new_pos.x, 0.0, main.GRID_SIZE * main.GRID_WIDTH)
	new_pos.y = clamp(new_pos.y, 0.0, main.GRID_SIZE * main.GRID_HEIGHT)
	position = new_pos
	_ai_apply_facing(delta)


func _ai_step_toward_grid(anchor: Vector2i, reach_tiles: int, delta: float) -> void:
	var bdata: BlockData = null
	if main.placed_buildings.has(anchor):
		bdata = Registry.get_block(main.placed_buildings[anchor])
	var sz: Vector2i = bdata.grid_size if bdata else Vector2i.ONE
	var target_world: Vector2 = main.grid_to_world(anchor) + Vector2(
		sz.x * main.GRID_SIZE * 0.5,
		sz.y * main.GRID_SIZE * 0.5,
	)
	_ai_step_toward_world(target_world, reach_tiles, delta)


func _ai_apply_facing(delta: float) -> void:
	var angle_diff: float = wrapf(_target_facing_angle - facing_angle, -PI, PI)
	if absf(angle_diff) > 0.01:
		var rotate_amount: float = signf(angle_diff) * ROTATION_SPEED * delta
		if absf(rotate_amount) > absf(angle_diff):
			facing_angle = _target_facing_angle
		else:
			facing_angle = wrapf(facing_angle + rotate_amount, -PI, PI)


func _ai_fire_tick(delta: float) -> void:
	if main.world_paused:
		return
	_ai_fire_cooldown -= delta
	if _ai_fire_cooldown > 0.0:
		return
	var enemy: Node2D = _ai_find_enemy_in_world()
	if enemy == null:
		return
	var range_px: float = _AI_FIRE_REACH_TILES * float(main.GRID_SIZE)
	if position.distance_to(enemy.position) > range_px:
		return
	var combat = get_node_or_null("/root/Main/CombatSystem")
	if combat == null or not combat.has_method("_drone_muzzle_info") \
			or not combat.has_method("_spawn_projectile"):
		return
	var attack_speed: float = combat.drone_attack_speed if "drone_attack_speed" in combat else 0.6
	var dmg: float = combat.drone_damage if "drone_damage" in combat else 8.0
	var proj_speed: float = combat.drone_projectile_speed if "drone_projectile_speed" in combat else 600.0
	_ai_fire_cooldown = attack_speed
	var muzzle: Dictionary = combat._drone_muzzle_info(self, enemy.position)
	combat._spawn_projectile(
		muzzle["pos"],
		enemy,
		muzzle["pos"] + muzzle["dir"] * range_px,
		"enemy",
		proj_speed,
		dmg,
		Color(0.3, 0.9, 1.0, 1.0),
		"drone",
		false,
		0.0,
	)


## Restores the chassis + head rotations to neutral. Called on any
## respawn path so a drone that died facing a wall doesn't reappear
## with a stale aim pose.
func _reset_orientation() -> void:
	facing_angle = PI
	_target_facing_angle = PI
	_turret_aim_offset_left = 0.0
	_turret_aim_offset_right = 0.0
	_healer_aim_offset = 0.0
	_has_turret_aim = false
	_heal_beam_active = false
	heal_target = null


## Respawns the drone at an arbitrary world position. Used when releasing
## direct control — the drone pops back in where the controlled entity was
## (or where it died), not all the way at the core.
func respawn_at(world_pos: Vector2) -> void:
	position = world_pos
	_velocity_smooth = Vector2.ZERO
	_clear_inventory()
	_reset_orientation()


func is_in_build_range(grid_pos: Vector2i) -> bool:
	var drone_grid = main.world_to_grid(position)
	var dx = abs(grid_pos.x - drone_grid.x)
	var dy = abs(grid_pos.y - drone_grid.y)
	return max(dx, dy) <= build_range


## Returns the world-space center of whatever the drone is currently "focused"
## on — either the ore it's mining or the first in-range block in the work
## queue. Used by _handle_movement to lock facing + apply the away-penalty.
## Returns null when no focus target exists.
func _get_focus_world_pos() -> Variant:
	# In-range work-queue entry takes priority over mining; distant queued
	# work doesn't steal focus away (matches _handle_mining's behavior).
	if _has_in_range_work():
		for a in main.work_order:
			if is_in_build_range(a):
				var bid: StringName = main.placed_buildings.get(a, &"")
				var bdata = Registry.get_block(bid)
				var sz: Vector2i = bdata.grid_size if bdata else Vector2i.ONE
				return main.grid_to_world(a) + Vector2(
					float(sz.x) * main.GRID_SIZE * 0.5,
					float(sz.y) * main.GRID_SIZE * 0.5
				)
	if mining_target != null:
		return main.grid_to_world(mining_target) + Vector2(
			main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5
		)
	# Heal beam used to count as a focus and pull the chassis to face the
	# beam endpoint. Now that the rotating healer head handles aiming on
	# its own, the chassis stays free to face the player's movement.
	return null


## Returns true when work_order has at least one non-paused entry within the
## drone's build range — i.e. the drone could start building this frame.
## Used to gate mining/focus so queued but distant work doesn't interrupt
## the drone from gathering resources.
func _has_in_range_work() -> bool:
	if not ("work_order" in main):
		return false
	if "build_paused" in main and main.build_paused:
		return false
	if main.work_order.is_empty():
		return false
	var paused: Dictionary = main.work_paused if "work_paused" in main else {}
	for a in main.work_order:
		if paused.has(a):
			continue
		if is_in_build_range(a):
			return true
	return false


# --- DRAWING ---
func _draw() -> void:
	# Hide the drone entirely when controlling a unit/turret. Shadow
	# visibility is enforced in `_process` instead of here, because
	# the shadow lives on a separate canvas and `_draw` running once
	# isn't reliable when the drone is off-camera (the controlled
	# unit's camera may park the drone outside the viewport).
	var unit_mgr = _unit_mgr_ref()
	if unit_mgr and unit_mgr.controlled_entity != null:
		return
	# (Build-range visualizer removed — the blue square around the
	# drone was too noisy for normal play. The range itself still
	# drives placement gating; only the on-screen overlay is gone.)
	# Chassis underneath, then turret + healer heads, then beams on top
	# so the lasers visibly emerge from the rotating heads instead of
	# vanishing behind the body. Mirrors how Mindustry's modular units
	# stack their barrel art over the chassis. Thruster glows draw
	# under the chassis so the body partially clips the inner half of
	# each circle, leaving only the exhaust visibly poking out the back.
	# v8 flying-unit shadow — paints first so the chassis covers it.
	_draw_flying_shadow()
	_draw_thrusters()
	_draw_drone()
	_draw_turret_heads()
	_draw_healer_head()
	_draw_mining_beam()
	_draw_heal_beam()
	_draw_mined_inventory()
	_draw_transfer_items()
	_draw_health_bar()
	if main and main.show_hitboxes:
		var hb_radius: float = (data.visual_size if data else 12.0)
		draw_arc(Vector2.ZERO, hb_radius, 0, TAU, 32, Color(1.0, 0.2, 0.9, 0.9), 1.5)




## Soft drop-shadow under the shardling. Recipe lifted from Mindustry
## v8's UnitType.drawShadow():
##   - WORLD-space offset (shadowTX, shadowTY) = (-12, -13) in libgdx
##     Y-up. Godot Y-down flips Y → (-12, +13).
##   - Pal.shadow tint = rgba(0,0,0,0.22).
##   - Shape = the chassis sprite + whichever turret/heal head is
##     currently shown, rotated to match. Mirrors v8's behaviour of
##     drawing the unit's `fullIcon` (a flattened render of every
##     sprite layer) as one rotated silhouette.
## Drawn before everything else in `_draw` so the chassis paints on
## top of the shadow.
## Trigger — kicks the drawer child to redraw its silhouettes onto
## the CanvasGroup's private buffer. The buffer is then alpha-blended
## with the world once via the group's modulate.a = 0.22, so
## overlapping silhouettes (chassis + turret heads) DON'T compound
## to a darker patch where they overlap.
func _draw_flying_shadow() -> void:
	if _shadow_drawer != null:
		_shadow_drawer.queue_redraw()


## Renders the shadow silhouettes onto the CanvasGroup's drawer child.
## Each silhouette draws at FULLY OPAQUE black; the group composites
## them to its private buffer (no per-draw compounding) and applies
## the final 22 % alpha pass once at world composition time.
## Heal head intentionally skipped — its silhouette has long emitter
## extensions that don't read as part of the drone's outline.
func _draw_flying_shadow_on_canvas() -> void:
	if _shadow_drawer == null or drone_texture == null:
		return
	const SHADOW_TX := -78.0
	const SHADOW_TY := 80.0    # +Y = down in Godot
	var sf: float = main.SPRITE_SCALE_FACTOR if main else 1.0
	var off: Vector2 = Vector2(SHADOW_TX * sf, SHADOW_TY * sf)
	var scale_mult: float = (data.sprite_scale if data else 1.0) * sf
	# Opaque black — the group's modulate.a multiplies down to 0.22 at
	# composition. Overlapping opaque silhouettes inside the group
	# stay opaque (no per-draw compounding).
	var sil := Color(0.0, 0.0, 0.0, 1.0)
	# --- Chassis ---
	var tex_size_v: Vector2 = drone_texture.get_size() * scale_mult
	var offset_y: float = tex_size_v.y * SPRITE_PIVOT_OFFSET
	_shadow_drawer.draw_set_transform(off, facing_angle, Vector2.ONE)
	_shadow_drawer.draw_texture_rect(
		drone_texture,
		Rect2(Vector2(-tex_size_v.x * 0.5, -tex_size_v.y * 0.5 + offset_y), tex_size_v),
		false,
		sil
	)
	_shadow_drawer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# --- Turret heads ---
	if turret_head_texture == null:
		return
	var head_scale: float = (data.sprite_scale if data else 1.0) * sf * HEAD_SCALE
	var ts: Vector2 = turret_head_texture.get_size() * head_scale
	var rect := Rect2(-ts * 0.5, ts)
	for right_side in [false, true]:
		var center_local: Vector2 = _turret_local_offset(right_side).rotated(facing_angle)
		var aim_off: float = _turret_aim_offset_right if right_side \
				else _turret_aim_offset_left
		_shadow_drawer.draw_set_transform(off + center_local,
				facing_angle + aim_off, Vector2.ONE)
		_shadow_drawer.draw_texture_rect(turret_head_texture, rect, false, sil)
	_shadow_drawer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_drone() -> void:
	var size = data.visual_size if data else 12.0

	# Apply rotation around the drone's center
	draw_set_transform(Vector2.ZERO, facing_angle)

	if drone_texture:
		# Pixel-perfect: draw at the texture's native size (with an optional
		# uniform scale multiplier from UnitData.sprite_scale). Preserves the
		# texture's aspect ratio instead of forcing it into a square.
		var scale_mult: float = (data.sprite_scale if data else 1.0) * main.SPRITE_SCALE_FACTOR
		var tex_size_v: Vector2 = drone_texture.get_size() * scale_mult
		# Shift sprite along its local "up" so the body center (not the tip)
		# sits at the rotation pivot.
		var offset_y: float = tex_size_v.y * SPRITE_PIVOT_OFFSET
		var rect = Rect2(
			Vector2(-tex_size_v.x / 2.0, -tex_size_v.y / 2.0 + offset_y),
			tex_size_v
		)
		draw_texture_rect(drone_texture, rect, false)
	else:
		# Fallback: colored diamond if texture is missing
		var points = PackedVector2Array([
			Vector2(0, -size),
			Vector2(size, 0),
			Vector2(0, size),
			Vector2(-size, 0),
		])
		var colors = PackedColorArray([
			drone_color, drone_color, drone_color, drone_color
		])
		draw_polygon(points, colors)
		draw_polyline(
			PackedVector2Array([
				Vector2(0, -size), Vector2(size, 0),
				Vector2(0, size), Vector2(-size, 0),
				Vector2(0, -size)
			]),
			drone_color.lightened(0.4),
			2.0
		)

	# Reset transform so health bar / range circle aren't rotated
	draw_set_transform(Vector2.ZERO, 0.0)


## Three yellow exhaust circles arrayed across the chassis's back
## edge — one larger center port flanked by two smaller ones — that
## carry with the body via `facing_angle`. Drawn under the chassis so
## the body clips the inner half of each circle, leaving the exhaust
## poking out behind.
func _draw_thrusters() -> void:
	var chassis: Vector2 = _chassis_size()
	if chassis.x <= 0.0 or chassis.y <= 0.0:
		return
	# Source faces +Y, so the back is at -Y in chassis-local space.
	var back_y: float = -chassis.y * 0.45
	var side_x: float = chassis.x * 0.28
	var center_r: float = chassis.x * 0.10
	var side_r: float = center_r * 0.5
	# Pulse and color shaping match `Main.draw_beam` so the thrusters
	# breathe in lockstep with the heal / mining lasers.
	var pulse: float = 0.5 + 0.5 * sin(_thruster_phase)
	var alpha: float = 0.6 + 0.3 * pulse
	# LUMINA shardlings (player + AI) push purple plumes; FEROX
	# shardlings push brown. The pulse / shape is identical.
	var outer_color: Color
	var inner_color: Color
	if ferox_controlled:
		outer_color = Color(0.55, 0.35, 0.15, alpha)
		inner_color = Color(0.9, 0.75, 0.5, alpha)
	else:
		outer_color = Color(0.6, 0.3, 0.9, alpha)
		inner_color = Color(0.88, 0.75, 1.0, alpha)
	var ports: Array = [
		[Vector2(-side_x, back_y), side_r],
		[Vector2(0.0, back_y), center_r],
		[Vector2(side_x, back_y), side_r],
	]
	for port in ports:
		var local_pos: Vector2 = (port[0] as Vector2).rotated(facing_angle)
		var r: float = port[1] as float
		draw_circle(local_pos, r, outer_color)
		draw_circle(local_pos, r * 0.5, inner_color)


## Returns the chassis sprite's local size in pixels (post sprite_scale
## and SPRITE_SCALE_FACTOR). Used to position the turret heads at the
## correct mid-left / mid-right offsets regardless of texture resolution.
func _chassis_size() -> Vector2:
	if drone_texture == null:
		var fallback: float = (data.visual_size if data else 12.0) * 2.0
		return Vector2(fallback, fallback)
	var scale_mult: float = (data.sprite_scale if data else 1.0) * main.SPRITE_SCALE_FACTOR
	return drone_texture.get_size() * scale_mult


## Returns the offset (in chassis-local pre-rotation pixels) of the
## left or right turret head's center. Both sit on the chassis Y-axis
## center line, X-offset from the body edges by `TURRET_HEAD_INSET_PX`.
## The chassis sprite source faces +Y (the formula
## `velocity.angle() + PI/2 + PI` aligns +Y to forward), so the body's
## "left" edge is at -X local and "right" at +X local in unrotated space.
func _turret_local_offset(right_side: bool) -> Vector2:
	var w: float = _chassis_size().x
	var sign_x: float = 1.0 if right_side else -1.0
	return Vector2(sign_x * (w * 0.5 - TURRET_HEAD_INSET_PX), 0.0)


## Returns the world-space center of a turret head (left or right),
## accounting for the chassis rotation that carries the heads with the
## body. The chassis is rotated by `facing_angle` so we rotate the
## local offset by the same amount.
func _turret_world_center(right_side: bool) -> Vector2:
	return position + _turret_local_offset(right_side).rotated(facing_angle)


## Returns the world muzzle position of a turret head — the front
## (bottom-of-source-art) edge of the head sprite, projected outward
## by half its texture height in the head's current aim direction.
## Used by combat_system to spawn projectiles from the actual barrel
## tip instead of the chassis center.
func _turret_muzzle_world(right_side: bool) -> Vector2:
	var center: Vector2 = _turret_world_center(right_side)
	if turret_head_texture == null:
		return center
	var scale_mult: float = (data.sprite_scale if data else 1.0) * main.SPRITE_SCALE_FACTOR * HEAD_SCALE
	var head_h: float = turret_head_texture.get_size().y * scale_mult
	var fwd: Vector2 = _turret_muzzle_fwd(right_side)
	return center + fwd * (head_h * 0.5)


## Unit vector pointing out the muzzle of one turret head. Combines
## chassis facing with the per-side aim offset, since each head can
## rotate independently.
func _turret_muzzle_fwd(right_side: bool) -> Vector2:
	var offset: float = _turret_aim_offset_right if right_side else _turret_aim_offset_left
	var world_rot: float = facing_angle + offset
	return Vector2(0.0, 1.0).rotated(world_rot)


## Combat-system entry point: returns the next turret muzzle's world
## position and flips the toggle so the next call uses the other
## barrel. Gives the drone a Mindustry-style alternating two-barrel
## firing cadence without the combat code knowing which side fired.
func next_turret_muzzle_world_pos() -> Vector2:
	var pos: Vector2 = _turret_muzzle_world(_next_muzzle_is_right)
	_next_muzzle_is_right = not _next_muzzle_is_right
	return pos


## Returns both the world position and the unit forward direction of
## the next turret muzzle, then flips the toggle. Combat uses the
## direction to fire bullets along the head's actual aim line — so
## a free-rotating head still throws projectiles out where the player
## sees the barrel pointing, even when the head is rotated past the
## chassis-forward arc (target behind the drone, etc.).
func next_turret_muzzle_world_info() -> Dictionary:
	var right_side: bool = _next_muzzle_is_right
	_next_muzzle_is_right = not _next_muzzle_is_right
	return {
		"pos": _turret_muzzle_world(right_side),
		"dir": _turret_muzzle_fwd(right_side),
	}


func _draw_turret_heads() -> void:
	if turret_head_texture == null:
		return
	var scale_mult: float = (data.sprite_scale if data else 1.0) * main.SPRITE_SCALE_FACTOR * HEAD_SCALE
	var tex_size: Vector2 = turret_head_texture.get_size() * scale_mult
	var rect := Rect2(-tex_size * 0.5, tex_size)
	for right_side in [false, true]:
		var center_local: Vector2 = _turret_local_offset(right_side).rotated(facing_angle)
		var offset: float = _turret_aim_offset_right if right_side else _turret_aim_offset_left
		draw_set_transform(center_local, facing_angle + offset)
		draw_texture_rect(turret_head_texture, rect, false)
	draw_set_transform(Vector2.ZERO, 0.0)


func _draw_healer_head() -> void:
	if heal_head_texture == null:
		return
	var scale_mult: float = (data.sprite_scale if data else 1.0) * main.SPRITE_SCALE_FACTOR * HEAD_SCALE
	var tex_size: Vector2 = heal_head_texture.get_size() * scale_mult
	var rect := Rect2(-tex_size * 0.5, tex_size)
	var world_rot: float = facing_angle + _healer_aim_offset
	draw_set_transform(Vector2.ZERO, world_rot)
	draw_texture_rect(heal_head_texture, rect, false)
	draw_set_transform(Vector2.ZERO, 0.0)


## Drives the green healing laser. Two modes:
##   heal_mode == true  → laser follows the cursor (capped at HEAL_RANGE_TILES)
##                        and snaps onto damaged friendly blocks the aim
##                        sweeps over. Manual control; combat handled by AI.
##   heal_mode == false → AI mode: pick the most-damaged friendly block in
##                        range and lock the laser onto it. Manual shooting
##                        runs as normal.
func _handle_healing(delta: float) -> void:
	if data == null or main == null:
		_heal_beam_active = false
		heal_target = null
		return
	# Mining and manual unit/turret control take precedence.
	if mining_target != null:
		_heal_beam_active = false
		heal_target = null
		return
	# Player-controlled-entity + UI gates only apply to the primary
	# drone — AI shardlings keep mending damaged blocks regardless of
	# what the player is doing.
	if not ai_controlled:
		var unit_mgr = _unit_mgr_ref()
		if unit_mgr and unit_mgr.controlled_entity != null:
			_heal_beam_active = false
			heal_target = null
			return
		if main.has_method("is_ui_blocking") and main.is_ui_blocking():
			_heal_beam_active = false
			return
	# Healing is a live gameplay action — block target acquisition / HP
	# application while the world is paused so the player can't sneak a
	# heal in during the freeze. The visual beam stays put on whatever
	# it was already locked to so the world doesn't pop visually when
	# the player pauses mid-heal.
	if "world_paused" in main and main.world_paused:
		return
	var range_px: float = HEAL_RANGE_TILES * float(main.GRID_SIZE)
	var aim_pos: Vector2
	var have_aim: bool = false
	# Manual heal is active only in heal_mode AND while LMB is held.
	# Outside that window the drone falls through to the AI auto-heal
	# branch so it keeps mending damaged friendlies even while the
	# player is busy manually shooting in default mode.
	var manual_heal_active: bool = false
	if heal_mode:
		var lmb: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		if main.selected_building != &"":
			lmb = false
		if get_viewport().gui_get_hovered_control() != null:
			lmb = false
		# Same suppression list combat_system uses for manual shoot —
		# any pending action that consumes the LMB click for itself
		# (unit-select, inventory drop, link, world menu, derelict
		# repair) should NOT also drive the heal beam.
		var combat = get_node_or_null("/root/Main/CombatSystem")
		if combat and combat.has_method("_player_action_blocks_drone") \
				and combat._player_action_blocks_drone(self):
			lmb = false
		manual_heal_active = lmb
	if manual_heal_active:
		aim_pos = get_global_mouse_position()
		have_aim = true
	else:
		# AI auto-heal only runs in shooting mode — the player is busy
		# manually firing, so the AI takes over healing. In heal mode
		# the laser is driven manually only.
		if heal_mode:
			heal_target = null
			_heal_beam_active = false
			return
		# AI: lock onto the most-damaged friendly block in range.
		var ai_target = _find_ai_heal_target(range_px)
		if ai_target == null:
			heal_target = null
			_heal_beam_active = false
			return
		heal_target = ai_target
		# Anchor the laser to the building's edge nearest the drone so
		# the beam visibly touches the closest tile rather than reaching
		# into the building's centre.
		aim_pos = _closest_perimeter_point_for_anchor(ai_target, position)
		have_aim = true
	if not have_aim:
		return
	# Cap the beam endpoint at HEAL_RANGE_TILES so the laser visibly stops
	# short when the player aims past its reach.
	var to_aim: Vector2 = aim_pos - position
	var aim_dist: float = to_aim.length()
	var aim_dir: Vector2 = to_aim.normalized() if aim_dist > 0.001 else Vector2.RIGHT
	var capped_endpoint: Vector2 = aim_pos if aim_dist <= range_px else position + aim_dir * range_px

	# Manual mode: snap onto a damaged friendly block under the aim. Once
	# locked, keep the lock as long as the aim stays roughly toward it
	# (HEAL_SNAP_RELEASE_DEG hysteresis). Only runs while manual heal is
	# actively driving — when fallen through to AI, heal_target was set
	# above by _find_ai_heal_target and we don't want to clobber it.
	if manual_heal_active:
		var snap = _resolve_heal_snap(aim_dir, range_px)
		if snap != null:
			heal_target = snap
		else:
			heal_target = null
		if heal_target != null and heal_target is Vector2i:
			# Snap to the point on the building's footprint perimeter
			# closest to the player's aim, instead of the anchor center.
			# For a 3x3 block this means the laser sits on the edge of
			# whichever tile the cursor is closest to, not on a fixed
			# point in the middle.
			var t_point: Vector2 = _closest_perimeter_point_for_anchor(heal_target, aim_pos)
			var to_t: Vector2 = t_point - position
			if to_t.length() <= range_px:
				capped_endpoint = t_point
			else:
				# Out of range — drop the lock so the laser still extends
				# along the cursor direction up to its cap.
				heal_target = null

	_heal_beam_endpoint = capped_endpoint
	_heal_beam_active = true

	# Apply healing to the locked target. Health is per-building (anchor
	# only) so a single dict bump fully heals every tile of a multi-tile
	# block at once. The same beam ALSO mends the block's shield (if
	# any) on the same tick — letting the player top up a chipped
	# barrier projector or shielded core without having to manually
	# wait for the in-shield cooldown.
	if heal_target == null or not (heal_target is Vector2i):
		return
	var anchor: Vector2i = main.building_origins.get(heal_target, heal_target)
	var bid: StringName = main.placed_buildings.get(anchor, &"")
	if bid == &"":
		heal_target = null
		return
	var bdata = Registry.get_block(bid)
	if bdata == null:
		return
	var max_hp: float = bdata.max_health
	var cur_hp: float = float(main.building_health.get(anchor, max_hp))
	var block_done: bool = cur_hp >= max_hp
	if not block_done:
		main.building_health[anchor] = minf(cur_hp + HEAL_RATE * delta, max_hp)
	# Shield heal pass.
	var shield_sys = main.get_node_or_null("ShieldSystem")
	var shield_done: bool = true
	if shield_sys and shield_sys.has_method("is_shield_damaged"):
		if shield_sys.is_shield_damaged(anchor):
			shield_sys.heal_shield(anchor, HEAL_RATE * delta)
			shield_done = not shield_sys.is_shield_damaged(anchor)
		elif shield_sys.has_method("has_shield") and shield_sys.has_shield(anchor):
			shield_done = true
	# Release the lock only once BOTH HP pools are topped up — keeps
	# the beam glued to a target with full block HP but a chipped
	# shield (or vice-versa) instead of constantly hopping.
	if block_done and shield_done:
		heal_target = null


## Returns the point on the building's footprint perimeter that's closest
## to `from_world`. Used by the heal laser so its endpoint visibly sits
## on the edge of the tile nearest the cursor (or, in AI mode, nearest
## the drone) instead of always pointing at the anchor's centre.
func _closest_perimeter_point_for_anchor(anchor: Vector2i, from_world: Vector2) -> Vector2:
	# Prefer the visible shield boundary when the locked anchor has a
	# damaged shield — the beam should land on the glowing barrier,
	# not the block chassis hidden inside it. Falls through to the
	# block's tile perimeter when the shield is broken / full / absent.
	var shield_sys = main.get_node_or_null("ShieldSystem")
	if shield_sys and shield_sys.has_method("is_shield_damaged") \
			and shield_sys.is_shield_damaged(anchor):
		if shield_sys.has_method("closest_shield_boundary_point"):
			var pt: Vector2 = shield_sys.closest_shield_boundary_point(anchor, from_world)
			if pt != Vector2.ZERO:
				return pt
	var bid: StringName = main.placed_buildings.get(anchor, &"")
	var bdata = Registry.get_block(bid) if bid != &"" else null
	var gs: float = float(main.GRID_SIZE)
	var bbox_min: Vector2 = main.grid_to_world(anchor)
	var bbox_size: Vector2 = Vector2(gs, gs)
	if bdata != null:
		bbox_size = Vector2(bdata.grid_size.x, bdata.grid_size.y) * gs
	var bbox_max: Vector2 = bbox_min + bbox_size
	# Closest point in the rectangle (inside or on the edge).
	var clamped: Vector2 = Vector2(
		clampf(from_world.x, bbox_min.x, bbox_max.x),
		clampf(from_world.y, bbox_min.y, bbox_max.y),
	)
	# When `from_world` is outside the rect, `clamped` already sits on
	# the perimeter. When it's inside (cursor over the building), pick
	# whichever of the four edges is closest so the beam endpoint stays
	# on a tile boundary rather than burying itself in the centre.
	if clamped == from_world:
		var d_left: float = from_world.x - bbox_min.x
		var d_right: float = bbox_max.x - from_world.x
		var d_top: float = from_world.y - bbox_min.y
		var d_bottom: float = bbox_max.y - from_world.y
		var m: float = minf(minf(d_left, d_right), minf(d_top, d_bottom))
		if m == d_left:
			return Vector2(bbox_min.x, from_world.y)
		elif m == d_right:
			return Vector2(bbox_max.x, from_world.y)
		elif m == d_top:
			return Vector2(from_world.x, bbox_min.y)
		else:
			return Vector2(from_world.x, bbox_max.y)
	return clamped


## Picks the best damaged friendly block under the drone's aim direction.
## Returns the building's anchor cell or null. Honours hysteresis: when a
## target is already locked, allows up to HEAL_SNAP_RELEASE_DEG before
## releasing — otherwise requires HEAL_SNAP_ACQUIRE_DEG to acquire a new
## one. Always validates range and faction.
func _resolve_heal_snap(aim_dir: Vector2, range_px: float):
	if main == null:
		return null
	var lumina: int = main.Faction.LUMINA if "Faction" in main and "LUMINA" in main.Faction else 0
	var shield_sys = main.get_node_or_null("ShieldSystem")
	# "Needs heal" = block HP damaged OR shield HP damaged. Lets the
	# manual snap lock onto a fully-built shield projector / shielded
	# core when only the barrier is chipped — previously the snap
	# bailed at `cur >= max_health` and the player couldn't aim at
	# a damaged shield at all.
	var needs_heal := func(anchor: Vector2i, bd: BlockData) -> bool:
		if bd == null:
			return false
		var maxh_n: float = bd.max_health
		var cur_n: float = float(main.building_health.get(anchor, maxh_n))
		if maxh_n > 0.0 and cur_n < maxh_n:
			return true
		if shield_sys and shield_sys.has_method("is_shield_damaged") \
				and shield_sys.is_shield_damaged(anchor):
			return true
		return false
	# Try to keep the existing lock first.
	if heal_target != null and heal_target is Vector2i:
		var anchor_existing: Vector2i = main.building_origins.get(heal_target, heal_target)
		if main.placed_buildings.has(anchor_existing) \
				and main.get_building_faction(anchor_existing) == lumina:
			var bid_e: StringName = main.placed_buildings[anchor_existing]
			var bd_e = Registry.get_block(bid_e)
			if bd_e != null and needs_heal.call(anchor_existing, bd_e):
				var center_e: Vector2 = main.grid_to_world(anchor_existing) \
					+ Vector2(bd_e.grid_size.x, bd_e.grid_size.y) * (main.GRID_SIZE * 0.5)
				var to_e: Vector2 = center_e - position
				if to_e.length() <= range_px:
					var ang_e: float = abs(rad_to_deg(aim_dir.angle_to(to_e.normalized())))
					if ang_e <= HEAL_SNAP_RELEASE_DEG:
						return anchor_existing
	# Otherwise scan all friendly blocks for the most direct damaged hit.
	var best_anchor: Variant = null
	var best_score: float = INF
	var seen: Dictionary = {}
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if seen.has(anchor):
			continue
		seen[anchor] = true
		if main.get_building_faction(anchor) != lumina:
			continue
		# Stale building_origins entry — anchor may no longer be in
		# placed_buildings (e.g. transient state during a destroy). Skip
		# rather than crash on the missing key.
		if not main.placed_buildings.has(anchor):
			continue
		var bid: StringName = main.placed_buildings[anchor]
		var bd = Registry.get_block(bid)
		if bd == null:
			continue
		if not needs_heal.call(anchor, bd):
			continue
		var center: Vector2 = main.grid_to_world(anchor) \
			+ Vector2(bd.grid_size.x, bd.grid_size.y) * (main.GRID_SIZE * 0.5)
		var to_b: Vector2 = center - position
		var dist: float = to_b.length()
		if dist > range_px or dist < 0.001:
			continue
		var ang: float = abs(rad_to_deg(aim_dir.angle_to(to_b.normalized())))
		if ang > HEAL_SNAP_ACQUIRE_DEG:
			continue
		# Score: tighter angle is better, slight bonus for closer.
		var score: float = ang + dist * 0.02
		if score < best_score:
			best_score = score
			best_anchor = anchor
	return best_anchor


## AI heal-target picker. Returns the most-damaged friendly block within
## range, or null if none. Used when heal_mode is off so the drone passively
## mends nearby buildings while the player handles combat.
func _find_ai_heal_target(range_px: float):
	if main == null:
		return null
	# FEROX shardlings heal the enemy faction's buildings; everything
	# else heals LUMINA. Branch the faction filter on the per-instance
	# `ferox_controlled` flag.
	var home_faction: int = 0
	if ferox_controlled and "Faction" in main and "FEROX" in main.Faction:
		home_faction = main.Faction.FEROX
	elif "Faction" in main and "LUMINA" in main.Faction:
		home_faction = main.Faction.LUMINA
	var shield_sys = main.get_node_or_null("ShieldSystem")
	var best_anchor: Variant = null
	var best_pct: float = 1.0
	var seen: Dictionary = {}
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if seen.has(anchor):
			continue
		seen[anchor] = true
		if main.get_building_faction(anchor) != home_faction:
			continue
		# Stale building_origins entry — anchor may no longer be in
		# placed_buildings (e.g. transient state during a destroy). Skip
		# rather than crash on the missing key.
		if not main.placed_buildings.has(anchor):
			continue
		var bid: StringName = main.placed_buildings[anchor]
		var bd = Registry.get_block(bid)
		if bd == null:
			continue
		var maxh: float = bd.max_health
		var cur: float = float(main.building_health.get(anchor, maxh))
		var block_pct: float = cur / maxh if maxh > 0.0 else 1.0
		# Combine block-HP and shield-HP into one "needs-healing"
		# percentage — whichever pool is more damaged drives target
		# selection, so the AI also auto-locks a fully-built block
		# whose shield is chipped.
		var shield_pct: float = 1.0
		if shield_sys and shield_sys.has_method("is_shield_damaged") \
				and shield_sys.is_shield_damaged(anchor):
			var sh_max: float = float(bd.shield_health)
			var st: Dictionary = shield_sys.states.get(anchor, {})
			if sh_max > 0.0:
				shield_pct = float(st.get("current_health", sh_max)) / sh_max
		var pct: float = minf(block_pct, shield_pct)
		if pct >= 1.0:
			continue
		var center: Vector2 = main.grid_to_world(anchor) \
			+ Vector2(bd.grid_size.x, bd.grid_size.y) * (main.GRID_SIZE * 0.5)
		if center.distance_to(position) > range_px:
			continue
		if pct < best_pct:
			best_pct = pct
			best_anchor = anchor
	return best_anchor


func _draw_heal_beam() -> void:
	if not _heal_beam_active:
		return
	var pulse: float = 0.5 + 0.5 * sin(_heal_beam_phase)
	var endpoint_local: Vector2 = _heal_beam_endpoint - position
	# Beam emerges from the bottom of the rotating healer head — that's
	# half a head-height out from chassis center along the head's
	# forward (+Y local) axis after rotation.
	var start_local: Vector2 = Vector2.ZERO
	if heal_head_texture:
		var scale_mult: float = (data.sprite_scale if data else 1.0) * main.SPRITE_SCALE_FACTOR * HEAD_SCALE
		var head_h: float = heal_head_texture.get_size().y * scale_mult
		var world_rot: float = facing_angle + _healer_aim_offset
		start_local = Vector2(0.0, 1.0).rotated(world_rot) * (head_h * 0.5)
	var main_ref = get_node("/root/Main")
	main_ref.draw_beam(self, start_local, endpoint_local, Color(0.3, 1.0, 0.4), pulse)


func _draw_mining_beam() -> void:
	if mining_target == null:
		return

	var ore_world: Vector2 = main.grid_to_world(mining_target) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
	var ore_local: Vector2 = ore_world - position

	# Compute tip position: the drone sprite's top edge in rotated local space
	# facing_angle rotates the sprite; the tip is at -Y in rotated space
	# facing_angle = velocity.angle() + PI/2 + PI, so the sprite's -Y points forward
	# Match the same native-size + scale math _draw_drone uses so the beam
	# anchors exactly at the sprite's top edge regardless of texture aspect.
	var scale_mult: float = (data.sprite_scale if data else 1.0) * main.SPRITE_SCALE_FACTOR
	var tex_h: float = drone_texture.get_size().y * scale_mult if drone_texture else ((data.visual_size if data else 12.0) * 2.0)
	var tip_size: float = tex_h * 0.5
	var tip_dir: Vector2 = Vector2(0, tip_size).rotated(facing_angle)

	# Pulsing animation
	var pulse: float = 0.5 + 0.5 * sin(_mining_beam_phase)

	# Counter-clockwise orbit of the beam's ore-side endpoint around the
	# ore's centre. In Godot's Y-down 2D space a NEGATIVE angle reads as
	# counter-clockwise on-screen, so we feed -phase into cos/sin.
	# Orbit radius is a small fraction of the tile so the endpoint
	# wobbles snugly inside the ore tile rather than wandering around it.
	var orbit_phase: float = -_mining_beam_phase
	var orbit_radius: float = float(main.GRID_SIZE) * 0.18
	var orbit_offset: Vector2 = Vector2(cos(orbit_phase), sin(orbit_phase)) * orbit_radius
	var endpoint_local: Vector2 = ore_local + orbit_offset

	# Mindustry-style beam (yellow for mining). Endpoint at the orbiting
	# point instead of dead-centre on the ore.
	var main_ref = get_node("/root/Main")
	main_ref.draw_beam(self, tip_dir, endpoint_local, Color.YELLOW, pulse)

	# Small rotating square framing the ore — sells the "this tile is
	# being mined" feel. Rotates counter-clockwise around the ore's
	# centre slightly faster than the beam endpoint orbit.
	var sq_size: float = float(main.GRID_SIZE) * 0.5
	var sq_phase: float = -_mining_beam_phase * 1.3
	var sq_color: Color = Color(1.0, 0.92, 0.35, 0.85)
	draw_set_transform(ore_local, sq_phase, Vector2.ONE)
	var sq_rect: Rect2 = Rect2(Vector2(-sq_size * 0.5, -sq_size * 0.5), Vector2(sq_size, sq_size))
	draw_rect(sq_rect, sq_color, false, 2.0)
	# Reset transform so subsequent draws (other helpers) start fresh.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_mined_inventory() -> void:
	# Collect all non-zero items
	var items: Array = []
	var total := 0
	for item_id in mined_inventory:
		var count: int = int(mined_inventory[item_id])
		if count > 0:
			items.append({"id": item_id, "count": count})
			total += count
	if total <= 0:
		return

	var font := ThemeDB.fallback_font
	var font_size := 9
	var icon_size := 14.0
	var spacing := 2.0

	# If dragging, draw items under the mouse cursor instead of above the drone
	if _dragging_inventory:
		var mouse_local: Vector2 = get_global_mouse_position() - position
		var start_y: float = mouse_local.y + 8.0
		var x_off: float = mouse_local.x - icon_size / 2.0
		for i in range(items.size()):
			var entry: Dictionary = items[i]
			var item_data = Registry.get_item(entry["id"])
			if item_data == null:
				continue
			var y_off: float = start_y + i * (icon_size + spacing)
			if item_data.icon:
				draw_texture_rect(item_data.icon, Rect2(Vector2(x_off, y_off), Vector2(icon_size, icon_size)), false, Color(1, 1, 1, 0.8))
			else:
				draw_rect(Rect2(Vector2(x_off, y_off), Vector2(icon_size, icon_size)), item_data.color.lightened(0.2), true)
			draw_string(font, Vector2(x_off + icon_size + 2, y_off + icon_size - 2), "×%d" % entry["count"], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)
		# Total / cap label
		draw_string(font, Vector2(mouse_local.x - 12, start_y - 2), "%d/%d" % [total, MAX_INVENTORY], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1, 0.84, 0, 0.9))
		return

	# Normal display: icons stacked above the drone
	var start_y: float = -20.0 - items.size() * (icon_size + spacing)
	for i in range(items.size()):
		var entry: Dictionary = items[i]
		var item_data = Registry.get_item(entry["id"])
		if item_data == null:
			continue
		var y_off: float = start_y + i * (icon_size + spacing)
		var x_off: float = -icon_size / 2.0
		if item_data.icon:
			draw_texture_rect(item_data.icon, Rect2(Vector2(x_off, y_off), Vector2(icon_size, icon_size)), false)
		else:
			draw_rect(Rect2(Vector2(x_off, y_off), Vector2(icon_size, icon_size)), item_data.color, true)
		if entry["count"] > 1:
			draw_string(font, Vector2(x_off + icon_size - 1, y_off + icon_size - 1), str(entry["count"]), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)
	# Total / cap
	draw_string(font, Vector2(-12, start_y - 3), "%d/%d" % [total, MAX_INVENTORY], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.8, 0.85, 0.9, 0.7))


func _draw_transfer_items() -> void:
	for entry in _transfer_items:
		var t: float = entry["t"]
		var start: Vector2 = entry["start"]
		var target: Vector2 = entry["target"]
		var current: Vector2 = start.lerp(target, t)
		var local_pos: Vector2 = current - position
		var icon: Texture2D = entry["icon"]

		if icon:
			var s := 24.0
			draw_texture_rect(icon, Rect2(local_pos - Vector2(s / 2.0, s / 2.0), Vector2(s, s)), false)
		else:
			draw_circle(local_pos, 8.0, Color(0.3, 0.9, 1.0, 0.8))


func _draw_health_bar() -> void:
	if health >= max_health:
		return

	var bar_width := 30.0
	var bar_height := 4.0
	var bar_offset := Vector2(-bar_width / 2.0, -20.0)

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
