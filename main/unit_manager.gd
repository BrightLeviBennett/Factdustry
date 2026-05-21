extends Node2D

# ============================================================
# UNIT_MANAGER.GD - Coordinates All Units
# ============================================================
# Uses Registry to look up unit data. Spawning an enemy now
# takes a UnitData ID, and the enemy loads its own stats.
# ============================================================

@onready var main: Node2D = get_node("/root/Main")

# Cached sibling references (populated in _ready). Avoids scene-tree
# lookups from the hot _process loop and its unit-iteration sub-calls.
var _combat_sys: Node
var _building_sys: Node
var _drone: Node2D
var _logistics: Node2D
var _terrain: Node2D
var _sector_script: Node

var enemy_script = preload("res://main/enemy_unit.gd")

# --- PATHFINDING ---
var astar: AStarGrid2D              # GROUND layer pathfinding (main thread — WASD only)
var astar_crawler: AStarGrid2D      # CRAWLER layer pathfinding (main thread — WASD only)
var astar_hover: AStarGrid2D        # HOVER layer pathfinding (blocked only by large terrain walls)
var _crawler_passable_walls: Dictionary = {}  # Vector2i -> true (small wall segments, < 4)
var _hover_passable_walls: Dictionary = {}    # Vector2i -> true (wall segments <= 8)
var _path_worker: PathfindingWorker  # Background thread for enemy/unit pathfinding

# --- WATER-PLATFORM RESERVATIONS ---
# Vector2i (grid cell) -> int (unit instance ID).
# A ground / crawler unit reserves the next platform cell it intends to
# step onto when that cell is over water. Other ground units treat
# reserved cells as temporarily impassable, so platform crossings happen
# strictly single-file and one unit can't shove another off the planks
# into deep water.
var _water_platform_reservation: Dictionary = {}

# --- TRACKING ---
var enemies: Array[Node2D] = []
var player_units: Array[Node2D] = []
# Kept as an always-empty stub so SectorDefenseSim's `for nest in nests`
# loop still compiles. The nest-based continuous spawner was removed in
# favour of the scripted wave system; defense-sim degrades to "no
# threats" when there are no nests, which is the desired behaviour.
var nests: Array[Node2D] = []

# --- SETTINGS ---
@export var path_update_interval := 2.0
var path_update_timer := 0.0

# --- FEROX FABRICATOR SQUAD SYSTEM ---
# Each FEROX fabricator builds a "squad" of newly-spawned units that
# wait at a rally point a few tiles in front of the fabricator instead
# of marching off the moment they roll off the line. Periodically the
# squad scans the player's defenses; once the squad's combined offense
# is enough to plausibly punch through, or the squad has been waiting
# too long, it releases — every unit picks a high-value target and
# paths off in a coordinated push.
#
# Schema:
#   enemy_squads[fab_anchor] = {
#     "units":        Array[Node2D]   # rallying units (alive, not yet released)
#     "rally_pos":    Vector2         # world-space hold point
#     "release_at":   int             # member count required to dispatch
#     "first_spawn":  float           # seconds since first member joined
#     "released":     bool            # once true, squad just sits empty
#                                     # until cleared on next fabricator tick
#   }
var enemy_squads: Dictionary = {}
var _squad_scan_timer: float = 0.0
const _SQUAD_SCAN_INTERVAL := 1.5         # seconds between threat reassessments
const _SQUAD_RALLY_TILES := 2.0           # rally point distance in front of fabricator
const _SQUAD_TIMEOUT_SECONDS := 30.0      # release no matter what after this long
const _SQUAD_MIN_SIZE := 1                # squad never holds below this
const _SQUAD_MAX_SIZE := 8                # …and never above this
## Approximate "DPS" of an average FEROX unit used to translate the
## player's measured threat into a target squad size. The squad scales
## release_at = ceil(player_threat / _SQUAD_AVG_UNIT_DPS) clamped to
## [MIN, MAX]. Bigger = squads stay smaller.
const _SQUAD_AVG_UNIT_DPS := 8.0

# --- FLOW FIELDS ---
# When a squad releases (or a multi-target push from RtsAI fires), we
# build a single flow field per (target, movement_layer) instead of
# running A* per unit. Each unit traces the field by gradient descent.
# Fields are cached for a short window so a second push at the same
# target reuses the same compute.
# Key: PackedInt32Array([target.x, target.y, movement_layer]) packed
# into an int via `_flow_key`. Value: { "field": FlowField, "age": float }.
var _flow_field_cache: Dictionary = {}
const _FLOW_FIELD_TTL: float = 4.0
var _flow_field_age_timer: float = 0.0

# --- RTSAI BASE CLUSTERS ---
# FEROX bases are clusters of nearby fabricators/cores. Each cluster
# gets a single RtsAI controller that:
#   • Aggregates all member fabricators' squads into one pool.
#   • Picks ONE attack target per push.
#   • Holds back `defender_ratio` of newly-produced units near home.
#   • Recalls attackers when home buildings take damage.
# Clusters are recomputed lazily when fabricators are added/removed.
# Schema: ferox_bases[base_id] = {
#   "anchor":         Vector2i  — representative tile (centroid-ish)
#   "members":        Array[Vector2i] — fabricator anchors in this base
#   "attack_target":  Variant — Vector2i or null
#   "next_attack_at": float — seconds until next push
#   "pressure_acc":   float — accumulated pressure for this base
# }
var ferox_bases: Dictionary = {}
var _base_dirty: bool = true
var _base_tick_timer: float = 0.0
const _BASE_TICK_INTERVAL: float = 2.0
## Two fabricators within this many tiles of each other are in the same
## base cluster (transitively).
const _BASE_CLUSTER_RADIUS: int = 18
## Fraction of a base's produced units kept home as defenders.
const _BASE_DEFENDER_RATIO: float = 0.25
## Base seconds between consecutive attacks from a single cluster.
const _BASE_ATTACK_COOLDOWN: float = 22.0

# --- PRESSURE ---
# Global FEROX aggression float. Ramps slowly with time and with the
# player's expansion (turret count, fabricator count, unit count).
# Higher pressure → bigger required squads, shorter cooldown between
# pushes, more aggressive (deeper) target picks.
var ferox_pressure: float = 0.0
var _pressure_tick_timer: float = 0.0
const _PRESSURE_TICK_INTERVAL: float = 5.0
## Pressure passive gain per second.
const _PRESSURE_PASSIVE_RAMP: float = 0.012
## Per-LUMINA-turret pressure contribution per tick.
const _PRESSURE_PER_TURRET: float = 0.05
## Per-LUMINA-fabricator pressure contribution per tick.
const _PRESSURE_PER_FAB: float = 0.08
## Soft cap. Above this we still grow but slower.
const _PRESSURE_SOFT_CAP: float = 10.0

# --- COLLISION ---
## Separation strength — how hard units push apart per frame
## Separation strength — how hard units push apart per frame
const SEPARATION_STRENGTH := 150.0
## Minimum distance to avoid division-by-zero; units closer than this get a random nudge
const MIN_SEPARATION_DIST := 0.5

# --- SELECTION ---
var selected_units: Array[Node2D] = []

## True when the player is in "unit mode" (toggled with the unit_mode key).
## While true, left-click box-select and right-click unit commands are active,
## and selection rings are drawn. While false, those inputs are ignored and
## selection rings are hidden, but previously-selected units keep their orders.
var unit_mode_active := false
## True when unit_manager handled a right-click this frame (prevents demolish)
var handled_right_click := false
## True when we consumed the right-click press (so we also consume release)
var _consumed_right_press := false
## Box-select drag state
var _box_selecting := false
var _box_start := Vector2.ZERO
var _box_end := Vector2.ZERO

# --- DIRECT CONTROL (Ctrl+click) ---
## The entity being directly controlled — Node2D (unit) or Vector2i (turret grid pos).
var controlled_entity: Variant = null
## "unit", "turret", or "crane"
var controlled_type: String = ""
var _crane_e_held := false
var _crane_q_held := false
## Attack cooldown for the controlled entity
var _control_attack_timer := 0.0
# Round-robin barrel index for manually-controlled multi-barrel turrets.
# Keyed on the turret's grid anchor so switching between two controlled
# turrets keeps their sequences independent.
var _control_barrel_idx := {}
## Last world-space position of the controlled entity. Updated each tick so
## that if a controlled unit dies we still know where to respawn the drone.
var _last_control_pos: Vector2 = Vector2.ZERO



func _combat_sys_ref() -> Node:
	if _combat_sys == null:
		_combat_sys = get_node_or_null("/root/Main/CombatSystem")
	return _combat_sys

func _building_sys_ref() -> Node:
	if _building_sys == null:
		_building_sys = get_node_or_null("/root/Main/BuildingSystem")
	return _building_sys

func _drone_ref() -> Node2D:
	if _drone == null:
		_drone = get_node_or_null("/root/Main/PlayerDrone")
	return _drone

func _logistics_ref() -> Node2D:
	if _logistics == null:
		_logistics = get_node_or_null("/root/Main/LogisticsSystem")
	return _logistics

func _terrain_ref() -> Node2D:
	if _terrain == null:
		_terrain = get_node_or_null("/root/Main/TerrainSystem")
	return _terrain

func _sector_script_ref() -> Node:
	if _sector_script == null:
		_sector_script = get_node_or_null("/root/Main/SectorScript")
	return _sector_script


func _ready() -> void:
	# Wait for Registry and main to initialize
	await get_tree().process_frame

	_combat_sys = get_node_or_null("/root/Main/CombatSystem")
	_building_sys = get_node_or_null("/root/Main/BuildingSystem")
	_drone = get_node_or_null("/root/Main/PlayerDrone")
	_logistics = get_node_or_null("/root/Main/LogisticsSystem")
	_terrain = get_node_or_null("/root/Main/TerrainSystem")
	_sector_script = get_node_or_null("/root/Main/SectorScript")

	_setup_astar()
	_setup_path_worker()
	_target_icon_tex = load("res://textures/mouse heads/TargetMouse.png") as Texture2D
	main.building_placed.connect(_on_building_placed)
	call_deferred("_spawn_test_nests")

	# Ctrl-hover overlay: dedicated child so the yellow tint sits above
	# unit / turret-head canvases (z=4099). z_as_relative=false locks
	# the absolute z so it survives even if UnitManager's z changes.
	_ctrl_hover_overlay = Node2D.new()
	_ctrl_hover_overlay.name = "CtrlHoverOverlay"
	_ctrl_hover_overlay.z_index = 4099
	_ctrl_hover_overlay.z_as_relative = false
	_ctrl_hover_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_ctrl_hover_overlay)
	_ctrl_hover_overlay.draw.connect(_draw_ctrl_hover_on_overlay)


func _exit_tree() -> void:
	if _path_worker:
		_path_worker.stop()
		_path_worker = null


var _ctrl_hover_phase: float = 0.0
# Dedicated high-z overlay so the yellow tint paints OVER unit sprites
# and turret heads. The main UnitManager draws at default z=0; units
# and turret-head canvases sit higher, which previously buried the
# control-hover fill. Built in `_ready`.
var _ctrl_hover_overlay: Node2D = null

# --- COMMAND INDICATORS ---
# The most recent right-click command. When a group is told to move,
# we keep the *original click point* here (not each unit's spread-out
# formation slot) so the on-screen indicator is a single dot + N lines
# instead of N scattered dots. Set in _command_move; cleared when no
# selected unit is still pursuing the order.
var _move_command_point: Vector2 = Vector2.INF
# When the most recent right-click was an attack-building command we
# show the TargetMouse.png at the block's center + lines from each
# selected unit to that icon (mirrors the move indicator).
var _attack_command_anchor: Vector2i = Vector2i(-9999, -9999)
# Cached target-icon texture loaded once (same asset the cursor uses).
var _target_icon_tex: Texture2D = null


func _process(delta: float) -> void:
	# Use deferred reset so the flag survives through all _process calls this frame
	call_deferred("_clear_handled_flag")

	# Spin the Ctrl-hover arrow ring CCW regardless of paused state.
	_ctrl_hover_phase += delta * 1.5
	if _ctrl_hover_overlay:
		_ctrl_hover_overlay.queue_redraw()

	# Skip unit updates when world is paused (camera/drone still move)
	if main.world_paused:
		queue_redraw()
		return

	# Poll threaded pathfinding results and apply to units
	_poll_path_results()

	path_update_timer -= delta
	if path_update_timer <= 0:
		path_update_timer = path_update_interval
		_update_all_enemy_paths()
	_tick_enemy_squads(delta)
	_resolve_unit_collisions(delta)
	_update_controlled_entity(delta)
	queue_redraw()


func _clear_handled_flag() -> void:
	handled_right_click = false


func _input(event: InputEvent) -> void:
	if main.is_ui_blocking():
		return
	# --- Ctrl + Click: take direct control of LUMINA unit or turret ---
	# On macOS, ctrl+click sends MOUSE_BUTTON_RIGHT with ctrl_pressed
	var is_ctrl_click: bool = event is InputEventMouseButton and event.pressed and event.ctrl_pressed and (event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT)
	if is_ctrl_click:
		var mouse_world := get_global_mouse_position()
		# Check for player unit at click position
		var clicked_unit := _get_player_unit_at(mouse_world)
		if clicked_unit:
			_take_control_of_unit(clicked_unit)
			get_viewport().set_input_as_handled()
			return
		# Check for LUMINA turret at click position
		var grid_pos: Vector2i = main.world_to_grid(mouse_world)
		if main.placed_buildings.has(grid_pos):
			var block_id = main.placed_buildings[grid_pos]
			var bdata = Registry.get_block(block_id)
			if bdata and bdata.is_turret() and main.get_building_faction(grid_pos) == main.Faction.LUMINA:
				_take_control_of_turret(grid_pos)
				get_viewport().set_input_as_handled()
				return
			# Check for LUMINA crane at click position
			if bdata and bdata.tags.has("crane") and main.get_building_faction(grid_pos) == main.Faction.LUMINA:
				var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
				_take_control_of_crane(anchor)
				get_viewport().set_input_as_handled()
				return
		# Ctrl+clicked empty space — release control
		_release_control()
		get_viewport().set_input_as_handled()
		return

	# --- Release direct control ---
	if event.is_action_pressed("release_control"):
		if controlled_entity != null:
			_release_control()
			get_viewport().set_input_as_handled()
			return

	# --- Toggle unit mode (U key) ---
	if event.is_action_pressed("unit_mode"):
		unit_mode_active = not unit_mode_active
		# If any box-select drag was in progress, cancel it when leaving unit mode.
		if not unit_mode_active and _box_selecting:
			_box_selecting = false
		queue_redraw()
		# Force every selected player unit to redraw so its selection ring updates.
		for u in selected_units:
			if is_instance_valid(u):
				u.queue_redraw()
		get_viewport().set_input_as_handled()
		return

	# --- LEFT-CLICK: box-select drag (only in unit mode, no building queued) ---
	if unit_mode_active and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# Clicks landing on a HUD Control (the unit-mode command buttons,
		# the build / portrait panels, etc.) shouldn't start a box-select.
		# Without this guard, pressing the Cancel Orders / Hold Fire /
		# Mine / … buttons would start a zero-width drag on press, finish
		# it on release, and `_finish_box_select` would treat the tiny
		# rect as a "click on empty space" and deselect everything.
		var hovered_ctrl: Control = get_viewport().gui_get_hovered_control()
		if hovered_ctrl != null:
			# On press, drop the event so we don't seed a drag. On
			# release, only consume it if we WEREN'T already mid-drag —
			# a drag that started in the world but ended over the HUD
			# should still finalize the selection.
			if event.pressed:
				return
			elif not _box_selecting:
				return
		var lm_world := get_global_mouse_position()
		if event.pressed:
			if controlled_entity == null and main.selected_building == &"":
				_box_selecting = true
				_box_start = lm_world
				_box_end = lm_world
				get_viewport().set_input_as_handled()
				return
		else:
			if _box_selecting:
				_box_selecting = false
				_finish_box_select()
				get_viewport().set_input_as_handled()
				return

	if unit_mode_active and event is InputEventMouseMotion and _box_selecting:
		_box_end = get_global_mouse_position()

	# --- RIGHT-CLICK: command selected units (move / attack) — unit mode only ---
	if unit_mode_active and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if selected_units.size() > 0:
			_issue_right_click_command(get_global_mouse_position())
			_consumed_right_press = true
			handled_right_click = true
			get_viewport().set_input_as_handled()
			return


func _get_player_unit_at(world_pos: Vector2) -> Node2D:
	var best: Node2D = null
	var best_dist := INF
	for unit in player_units:
		if not is_instance_valid(unit) or unit.is_dead:
			continue
		var dist := world_pos.distance_to(unit.position)
		# Use generous click radius (at least 16px) so units are easy to click
		var click_radius := maxf(unit.unit_size * 2.0, 16.0)
		if dist <= click_radius and dist < best_dist:
			best_dist = dist
			best = unit
	return best


func _finish_box_select() -> void:
	var rect := Rect2(
		Vector2(min(_box_start.x, _box_end.x), min(_box_start.y, _box_end.y)),
		Vector2(abs(_box_end.x - _box_start.x), abs(_box_end.y - _box_start.y))
	)
	# Tiny drag → treat as a single click: select the unit under the cursor
	# (replacing the current selection), or deselect all if nothing was clicked.
	if rect.size.x < 8.0 and rect.size.y < 8.0:
		var clicked := _get_player_unit_at(_box_end)
		_deselect_all()
		if clicked:
			clicked.is_selected = true
			selected_units.append(clicked)
		return
	# Deselect all first
	for unit in selected_units:
		if is_instance_valid(unit):
			unit.is_selected = false
	selected_units.clear()
	# Select units inside the box
	for unit in player_units:
		if not is_instance_valid(unit) or unit.is_dead:
			continue
		if rect.has_point(unit.position):
			unit.is_selected = true
			selected_units.append(unit)


## Dispatches a right-click command from the user based on what's under the cursor:
##   - enemy unit  → command selected units to attack it
##   - ferox building → command selected units to attack it
##   - empty ground → command selected units to move there
func _issue_right_click_command(world_pos: Vector2) -> void:
	if selected_units.is_empty():
		return
	# 1. Enemy unit under cursor?
	var clicked_enemy: Node2D = null
	var best_dist := INF
	for e in enemies:
		if not is_instance_valid(e) or e.is_dead:
			continue
		if e.team == UnitData.Team.PLAYER:
			continue
		var d: float = world_pos.distance_to(e.position)
		var r: float = maxf(e.unit_size * 2.0, 16.0)
		if d <= r and d < best_dist:
			best_dist = d
			clicked_enemy = e
	if clicked_enemy != null:
		_command_attack_unit(clicked_enemy)
		return

	# 2. Building under cursor? Two sub-cases:
	#    a) LUMINA payload-accepting block + at least one selected unit
	#       has `enter_payload_when_able` on → direct those units to
	#       walk up and feed themselves in (the new behaviour). Other
	#       selected units fall through to the move command below so
	#       a mixed selection still does something sensible.
	#    b) FEROX building → attack as before.
	var grid_pos: Vector2i = main.world_to_grid(world_pos)
	if main.placed_buildings.has(grid_pos):
		var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		var faction: int = main.get_building_faction(anchor)
		if faction == main.Faction.LUMINA and _is_payload_block_anchor(anchor):
			if _command_payload_target(anchor):
				return
		elif faction == main.Faction.FEROX:
			_command_attack_building(anchor)
			return

	# 3. Otherwise move there
	_command_move(world_pos)


## True if the block at `anchor` is one of the four payload-accepting
## kinds: payload conveyor, freight conveyor, mass driver, or
## deconstructor. Matches the eligibility filter `_payload_block_at` in
## enemy_unit.gd.
func _is_payload_block_anchor(anchor: Vector2i) -> bool:
	var bid: StringName = main.placed_buildings.get(anchor, &"")
	if bid == &"":
		return false
	var data = Registry.get_block(bid)
	if data == null:
		return false
	var tags: PackedStringArray = data.tags
	return tags.has("payload") or tags.has("freight") \
			or tags.has("mass_driver") or tags.has("deconstructor")


## Issues a "go feed yourself into this block" order to every selected
## unit whose `enter_payload_when_able` toggle is on. Returns true if at
## least one unit took the order — the caller treats that as the
## right-click being consumed.
func _command_payload_target(anchor: Vector2i) -> bool:
	var data = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if data == null:
		return false
	# Target the geometric center of the building. `assign_path_to_position`
	# clamps to the nearest walkable cell when the target itself is solid,
	# which for a deconstructor means landing right at its edge.
	var target_world: Vector2 = main.grid_to_world(anchor) + Vector2(
		data.grid_size.x * main.GRID_SIZE * 0.5,
		data.grid_size.y * main.GRID_SIZE * 0.5,
	)
	var any: bool = false
	for unit in selected_units:
		if not is_instance_valid(unit) or unit.is_dead:
			continue
		if unit == controlled_entity:
			continue
		if not ("enter_payload_when_able" in unit and unit.enter_payload_when_able):
			continue
		# Clear other manual orders so this becomes the unit's focus.
		unit.manual_target_unit = null
		unit.manual_target_building = null
		unit.manual_target_building_block_id = &""
		unit.target_unit = null
		unit.target_building = null
		unit.payload_target_anchor = anchor
		unit.move_to_position(target_world)
		any = true
	return any


## Assigns an enemy unit as the manual target for all selected units.
func _command_attack_unit(enemy: Node2D) -> void:
	# Live enemy units move every frame — no static indicator to paint.
	_move_command_point = Vector2.INF
	_attack_command_anchor = Vector2i(-9999, -9999)
	for unit in selected_units:
		if not is_instance_valid(unit) or unit.is_dead:
			continue
		if unit == controlled_entity:
			continue
		unit.manual_target_unit = enemy
		unit.manual_target_building = null
		unit.manual_target_building_block_id = &""
		unit.move_target = null
		unit.target_unit = enemy
		unit.target_building = null
		unit.path = PackedVector2Array()
		unit.path_index = 0
		if "payload_target_anchor" in unit:
			unit.payload_target_anchor = Vector2i(-9999, -9999)


## Assigns a building as the manual target for all selected units.
func _command_attack_building(bldg_anchor: Vector2i) -> void:
	# Stamp the indicator anchor so the renderer paints the TargetMouse
	# icon at the block + lines from every selected unit. A subsequent
	# move/attack-unit command clears it again.
	_attack_command_anchor = bldg_anchor
	_move_command_point = Vector2.INF
	for unit in selected_units:
		if not is_instance_valid(unit) or unit.is_dead:
			continue
		if unit == controlled_entity:
			continue
		unit.manual_target_building = bldg_anchor
		unit.manual_target_unit = null
		# Snapshot the block id that was targeted. The unit's per-tick
		# validator compares against this so if the block is destroyed
		# and a different one built on the same tile (or the block is
		# converted to the unit's own faction), the chase stops instead
		# of continuing to attack the wrong thing.
		unit.manual_target_building_block_id = main.placed_buildings.get(bldg_anchor, &"")
		unit.move_target = null
		unit.target_building = bldg_anchor
		unit.target_unit = null
		unit.path = PackedVector2Array()
		unit.path_index = 0
		if "payload_target_anchor" in unit:
			unit.payload_target_anchor = Vector2i(-9999, -9999)


func _command_move(world_pos: Vector2) -> void:
	# Gather living selected units (skip the controlled unit — it uses WASD)
	var living: Array[Node2D] = []
	for unit in selected_units:
		if is_instance_valid(unit) and not unit.is_dead:
			if unit == controlled_entity:
				continue
			# Clear any previous manual target — this is a plain move order.
			unit.manual_target_unit = null
			unit.manual_target_building = null
			unit.manual_target_building_block_id = &""
			if "payload_target_anchor" in unit:
				unit.payload_target_anchor = Vector2i(-9999, -9999)
			living.append(unit)

	if living.size() == 0:
		return

	# Stamp the single command anchor for the indicator. Even though
	# individual units fan out to formation slots around `world_pos`,
	# the on-screen marker is just one dot at the player's actual
	# click point with lines back to each unit.
	_move_command_point = world_pos
	_attack_command_anchor = Vector2i(-9999, -9999)

	# Single unit — move directly to the target
	if living.size() == 1:
		living[0].move_to_position(world_pos)
		return

	# Multiple units — spread into a formation around the target
	var offsets := _compute_formation_offsets(living.size(), living[0].unit_size)
	for i in range(living.size()):
		living[i].move_to_position(world_pos + offsets[i])


## Computes formation offsets for N units arranged in concentric rings.
## Spacing is at least one grid cell so each unit targets a different AStar cell.
func _compute_formation_offsets(count: int, unit_radius: float) -> Array[Vector2]:
	var offsets: Array[Vector2] = []
	# Use grid-cell-sized spacing so units target distinct AStar cells
	var spacing := maxf(unit_radius * 3.0, main.GRID_SIZE * 0.8)
	offsets.append(Vector2.ZERO)      # First unit goes to center

	var ring := 1
	while offsets.size() < count:
		var ring_radius := spacing * ring
		var slots: int = maxi(6 * ring, 1)  # 6 per ring, 12 per ring 2, etc.
		for s in range(slots):
			if offsets.size() >= count:
				break
			var angle: float = (TAU / slots) * s
			offsets.append(Vector2(cos(angle), sin(angle)) * ring_radius)
		ring += 1

	return offsets


func _deselect_all() -> void:
	for unit in selected_units:
		if is_instance_valid(unit):
			unit.is_selected = false
	selected_units.clear()


# =========================
# DIRECT CONTROL (Ctrl+click)
# =========================

func _take_control_of_unit(unit: Node2D) -> void:
	_release_control()
	_deselect_all()
	controlled_entity = unit
	controlled_type = "unit"
	_control_attack_timer = 0.0
	unit.is_selected = true
	unit.is_controlled = true
	selected_units.append(unit)
	# Clear auto-combat targets so the unit waits for manual commands
	unit.target_unit = null
	unit.target_building = null
	unit.path = PackedVector2Array()
	unit.path_index = 0


func _take_control_of_turret(grid_pos: Vector2i) -> void:
	_release_control()
	_deselect_all()
	controlled_entity = grid_pos
	controlled_type = "turret"
	_control_attack_timer = 0.0
	# Tell CombatSystem to skip auto-targeting for this turret
	var combat = _combat_sys_ref()
	if combat:
		combat.manually_controlled_turret = grid_pos


func _take_control_of_crane(anchor: Vector2i) -> void:
	_release_control()
	_deselect_all()
	controlled_entity = anchor
	controlled_type = "crane"
	# Initialize crane state in building system
	var building_sys = _building_sys_ref()
	if building_sys and "crane_states" in building_sys:
		if not building_sys.crane_states.has(anchor):
			building_sys.crane_states[anchor] = {
				"arm_angle": -PI / 2.0,
				"arm_extension": 20.0,
				"grabber_open": true,
				"grabber_angle": 0.0,
				"held_payload": null,
				"target_pos": Vector2.ZERO,
			}


func _release_control() -> void:
	if controlled_entity == null:
		return
	# Capture the world position we should respawn the drone at — the
	# controlled entity's current location (or last known location if the
	# entity was destroyed while under control).
	var respawn_pos: Variant = _get_controlled_world_pos()
	if controlled_type == "unit":
		var unit: Node2D = controlled_entity
		if is_instance_valid(unit):
			unit.is_controlled = false
	elif controlled_type == "turret":
		var combat = _combat_sys_ref()
		if combat:
			combat.manually_controlled_turret = null
	# Crane keeps its state (may be holding a payload)
	controlled_entity = null
	controlled_type = ""
	# Respawn the shardling over whatever you were just controlling. If we
	# couldn't resolve a position (shouldn't happen), fall back to the core.
	var drone = _drone_ref()
	if drone:
		if respawn_pos != null and drone.has_method("respawn_at"):
			drone.respawn_at(respawn_pos)
		elif respawn_pos != null:
			drone.position = respawn_pos
			if drone.has_method("_clear_inventory"):
				drone._clear_inventory()
		else:
			if drone.has_method("_clear_inventory"):
				drone._clear_inventory()
			drone._move_to_core()


## Resolves the current controlled entity's world position. Used so R-release
## respawns the drone where the entity is, even if the entity was destroyed
## mid-control (grid positions for turrets/cranes stay valid regardless).
func _get_controlled_world_pos() -> Variant:
	match controlled_type:
		"unit":
			if is_instance_valid(controlled_entity):
				return (controlled_entity as Node2D).position
			return _last_control_pos
		"turret", "crane":
			var anchor: Vector2i = controlled_entity
			var gs: float = float(main.GRID_SIZE)
			var size := Vector2i(1, 1)
			if main.placed_buildings.has(anchor):
				var bd = Registry.get_block(main.placed_buildings[anchor])
				if bd:
					size = bd.grid_size
			return Vector2(
				(float(anchor.x) + float(size.x) * 0.5) * gs,
				(float(anchor.y) + float(size.y) * 0.5) * gs
			)
	return _last_control_pos


func _update_controlled_entity(delta: float) -> void:
	if controlled_entity == null:
		return

	_control_attack_timer -= delta

	if controlled_type == "unit":
		_update_controlled_unit(delta)
	elif controlled_type == "turret":
		_update_controlled_turret(delta)
	elif controlled_type == "crane":
		_update_controlled_crane(delta)

	# Cache the entity's current world position so _release_control can
	# still respawn the drone in-place even if the entity was destroyed
	# this frame (e.g. controlled unit died).
	var cur: Variant = _get_controlled_world_pos()
	if cur is Vector2:
		_last_control_pos = cur


func _update_controlled_crane(delta: float) -> void:
	var anchor: Vector2i = controlled_entity
	if not main.placed_buildings.has(anchor):
		_release_control()
		return

	var building_sys = _building_sys_ref()
	if not building_sys or not "crane_states" in building_sys:
		return
	if not building_sys.crane_states.has(anchor):
		return

	var data = Registry.get_block(main.placed_buildings[anchor])
	if data == null:
		return

	var state: Dictionary = building_sys.crane_states[anchor]
	var gs: float = main.GRID_SIZE
	var crane_center: Vector2 = main.grid_to_world(anchor) + Vector2(data.grid_size.x * gs / 2.0, data.grid_size.y * gs / 2.0)

	# Center camera on crane (like turret control)
	var drone = _drone_ref()
	if drone:
		drone.position = crane_center

	# Update target position to mouse, clamped to crane range
	var mouse_world: Vector2 = get_global_mouse_position()
	var max_reach: float = data.crane_range * gs
	var to_mouse: Vector2 = mouse_world - crane_center
	if to_mouse.length() > max_reach:
		to_mouse = to_mouse.normalized() * max_reach
	state["target_pos"] = crane_center + to_mouse

	# Update telescoping arm
	if building_sys.has_method("update_crane_telescope"):
		building_sys.update_crane_telescope(anchor, state["target_pos"], delta)

	# Handle E key for pickup/drop
	if Input.is_key_pressed(KEY_E) and not _crane_e_held:
		_crane_e_held = true
		_crane_interact(anchor, state, crane_center, max_reach)
	elif not Input.is_key_pressed(KEY_E):
		_crane_e_held = false

	# Handle Q key to rotate held payload by 90°
	if Input.is_key_pressed(KEY_Q) and not _crane_q_held:
		_crane_q_held = true
		if state["held_payload"] != null and state["held_payload"].get("type", "") == "building":
			var bdata_q = Registry.get_block(StringName(state["held_payload"].get("block_id", "")))
			var building_sys_q = _building_sys_ref()
			var is_dir: bool = building_sys_q != null and bdata_q != null and building_sys_q._is_directional(bdata_q.id)
			if is_dir:
				state["held_payload"]["rotation"] = (int(state["held_payload"].get("rotation", 0)) + 1) % 4
	elif not Input.is_key_pressed(KEY_Q):
		_crane_q_held = false

	# Smoothly lerp grabber angle toward target rotation
	var current_g_angle: float = state.get("grabber_angle", 0.0)
	if state["held_payload"] != null and state["held_payload"].get("type", "") == "building":
		var target_angle: float = int(state["held_payload"].get("rotation", 0)) * PI / 2.0
		state["grabber_angle"] = lerp_angle(current_g_angle, target_angle, delta * 10.0)
	# When not holding, keep current angle as the new default (don't lerp back)


func _crane_interact(anchor: Vector2i, state: Dictionary, crane_center: Vector2, _max_reach: float) -> void:
	# Compute grabber position: slides along the arm to match the mouse distance
	var arm_angle: float = state.get("arm_angle", 0.0)
	var arm_ext: float = state.get("arm_extension", 0.0)
	var arm_dir: Vector2 = Vector2(cos(arm_angle), sin(arm_angle))
	var tp_raw = state.get("target_pos", crane_center)
	var target_pos: Vector2 = tp_raw if tp_raw is Vector2 else crane_center
	var to_target_dist: float = (target_pos - crane_center).length()
	var grabber_t: float = clampf(to_target_dist / arm_ext, 0.0, 1.0) if arm_ext > 1.0 else 1.0
	var grabber_world: Vector2 = crane_center + arm_dir * (grabber_t * arm_ext)
	var grid_target: Vector2i = main.world_to_grid(grabber_world)

	if state["held_payload"] == null:
		# First: check if there's a payload on a conveyor at this position
		var logistics = _logistics_ref()
		if logistics and "payload_items" in logistics:
			var conv_anchor: Vector2i = main.building_origins.get(grid_target, grid_target)
			if logistics.payload_items.has(conv_anchor):
				var entry: Dictionary = logistics.payload_items[conv_anchor]
				state["held_payload"] = entry.get("payload_data", {}).duplicate(true)
				logistics.payload_items.erase(conv_anchor)
				state["grabber_open"] = false
				return

		# Try to pick up a building
		if main.placed_buildings.has(grid_target):
			# Don't pick up the crane itself
			var target_anchor: Vector2i = main.building_origins.get(grid_target, grid_target)
			if target_anchor == anchor:
				return
			var block_id: StringName = main.placed_buildings[grid_target]
			var bdata = Registry.get_block(block_id)
			var faction: int = main.get_building_faction(grid_target)
			if bdata and not bdata.tags.has("core") and faction == main.Faction.LUMINA:
				var payload: Dictionary = main.pickup_building(grid_target)
				if not payload.is_empty():
					# Snap grabber angle to match the block's rotation immediately
					state["grabber_angle"] = int(payload.get("rotation", 0)) * PI / 2.0
					state["held_payload"] = payload
					state["grabber_open"] = false
					return

		# Try to grab a payload from another crane whose head is near
		# our grabber. Lets the player relay payloads between cranes
		# without ever setting them down on a conveyor.
		var building_sys_take = _building_sys_ref()
		if building_sys_take and "crane_states" in building_sys_take:
			var gs_take: float = main.GRID_SIZE
			var pickup_radius: float = gs_take * 0.6
			var best_anchor: Vector2i = anchor
			var best_dist: float = pickup_radius
			var found := false
			for other_anchor in building_sys_take.crane_states:
				if other_anchor == anchor:
					continue
				var other_state: Dictionary = building_sys_take.crane_states[other_anchor]
				if other_state.get("held_payload", null) == null:
					continue
				if not main.placed_buildings.has(other_anchor):
					continue
				var other_data = Registry.get_block(main.placed_buildings[other_anchor])
				if other_data == null:
					continue
				var other_base: Vector2 = main.grid_to_world(other_anchor) + Vector2(other_data.grid_size.x * gs_take / 2.0, other_data.grid_size.y * gs_take / 2.0)
				var other_arm_angle: float = float(other_state.get("arm_angle", 0.0))
				var other_arm_ext: float = float(other_state.get("arm_extension", 0.0))
				var other_arm_dir: Vector2 = Vector2(cos(other_arm_angle), sin(other_arm_angle))
				var ot_raw = other_state.get("target_pos", other_base)
				var other_target: Vector2 = ot_raw if ot_raw is Vector2 else other_base
				var other_to_target: float = (other_target - other_base).length()
				var other_grabber_t: float = clampf(other_to_target / other_arm_ext, 0.0, 1.0) if other_arm_ext > 1.0 else 1.0
				var other_grabber: Vector2 = other_base + other_arm_dir * (other_grabber_t * other_arm_ext)
				var d: float = (other_grabber - grabber_world).length()
				if d < best_dist:
					best_dist = d
					best_anchor = other_anchor
					found = true
			if found:
				var donor_state: Dictionary = building_sys_take.crane_states[best_anchor]
				state["held_payload"] = donor_state["held_payload"]
				donor_state["held_payload"] = null
				donor_state["grabber_open"] = true
				if state["held_payload"] != null and state["held_payload"].get("type", "") == "building":
					state["grabber_angle"] = int(state["held_payload"].get("rotation", 0)) * PI / 2.0
				state["grabber_open"] = false
				return


		# Try to pick up a player unit
		var clicked_unit = _get_player_unit_at(grabber_world)
		if clicked_unit and is_instance_valid(clicked_unit):
			var unit_payload := {
				"type": "unit",
				"unit_id": str(clicked_unit.data.id) if clicked_unit.data else "",
				"health": clicked_unit.health,
				"team": clicked_unit.team if "team" in clicked_unit else 0,
			}
			# Remove unit from scene
			player_units.erase(clicked_unit)
			clicked_unit.queue_free()
			state["held_payload"] = unit_payload
			state["grabber_open"] = false
	else:
		# Try to drop payload
		var payload: Dictionary = state["held_payload"]
		var logistics = _logistics_ref()

		# Check if dropping onto a payload/freight conveyor
		if logistics and logistics.has_method("_is_payload_cell") and logistics._is_payload_cell(grid_target):
			if logistics.has_method("_try_push_payload") and logistics._try_push_payload(grid_target, payload):
				state["held_payload"] = null
				state["grabber_open"] = true
				return

		if payload.get("type", "") == "building":
			if main.has_method("place_payload_building"):
				var block_data = Registry.get_block(StringName(payload.get("block_id", "")))
				var gsx: int = int(payload.get("grid_size_x", 1))
				var gsy: int = int(payload.get("grid_size_y", 1))
				# Try centered on grabber first, then exact grid target
				var center_pos := Vector2i(grid_target.x - gsx / 2, grid_target.y - gsy / 2)
				var try_positions: Array[Vector2i] = [center_pos, grid_target]
				# For extractors, also try all 4 rotations at each position
				var is_extractor: bool = block_data != null and block_data.category == BlockData.BlockCategory.EXTRACTORS
				var placed := false
				for pos in try_positions:
					if is_extractor:
						for rot in [0, 1, 2, 3]:
							payload["rotation"] = rot
							if main.place_payload_building(payload, pos):
								placed = true
								break
						if placed:
							break
					else:
						if main.place_payload_building(payload, pos):
							placed = true
							break
				if placed:
					state["held_payload"] = null
					state["grabber_open"] = true
		elif payload.get("type", "") == "unit":
			# Drop unit at exact position (no grid snap)
			var unit_id := StringName(payload.get("unit_id", ""))
			if unit_id != &"":
				spawn_player_unit(grabber_world, unit_id)
				# Restore health
				if not player_units.is_empty():
					var spawned = player_units[-1]
					if is_instance_valid(spawned):
						spawned.health = float(payload.get("health", spawned.health))
				state["held_payload"] = null
				state["grabber_open"] = true


func _update_controlled_unit(delta: float) -> void:
	var unit: Node2D = controlled_entity
	if not is_instance_valid(unit) or unit.is_dead:
		_release_control()
		return

	# --- WASD movement (like the player drone) ---
	var move_x: float = Input.get_axis("move_left", "move_right")
	var move_y: float = Input.get_axis("move_up", "move_down")
	var velocity := Vector2(move_x, move_y)

	# Tank steering: WASD picks a desired world-direction; the tank's motion
	# is delegated to the unit's shared tank-steer helper so manual driving
	# uses the same arc-around-pivot model as AI path following. We snapshot
	# the position first so we can revert into a wall if the arc pushed the
	# tank into a blocked cell.
	if unit.data and unit.data.tank_steering and velocity.length() > 0:
		var desired_face: float = velocity.normalized().angle()
		var forward_step: float = unit.move_speed * delta
		# Clear auto-targets while the player is actively driving.
		unit.path = PackedVector2Array()
		unit.path_index = 0
		unit.move_target = null
		unit.target_unit = null
		unit.target_building = null

		var pre_pos: Vector2 = unit.position
		unit._tank_steer_step(desired_face, forward_step, unit.position, 0.0)

		if unit.data.movement_layer == UnitData.MovementLayer.FLYING:
			var map_wf: float = main.GRID_SIZE * main.GRID_WIDTH
			var map_hf: float = main.GRID_SIZE * main.GRID_HEIGHT
			unit.position.x = clampf(unit.position.x, 0.0, map_wf)
			unit.position.y = clampf(unit.position.y, 0.0, map_hf)
		else:
			# Revert translation (not rotation) if the new cell is solid.
			var grid_chk: AStarGrid2D = _get_grid_for_unit(unit)
			var cg: Vector2i = main.world_to_grid(unit.position)
			cg.x = clampi(cg.x, 0, main.GRID_WIDTH - 1)
			cg.y = clampi(cg.y, 0, main.GRID_HEIGHT - 1)
			if grid_chk.is_point_solid(cg):
				unit.position = pre_pos
			else:
				var map_wg: float = main.GRID_SIZE * main.GRID_WIDTH
				var map_hg: float = main.GRID_SIZE * main.GRID_HEIGHT
				unit.position.x = clampf(unit.position.x, 0.0, map_wg)
				unit.position.y = clampf(unit.position.y, 0.0, map_hg)
		return

	if velocity.length() > 0:
		velocity = velocity.normalized()
		var new_pos: Vector2 = unit.position + velocity * unit.move_speed * delta

		# Movement layer restrictions
		if unit.data and unit.data.movement_layer == UnitData.MovementLayer.FLYING:
			# Flying: completely free movement
			var map_w: float = main.GRID_SIZE * main.GRID_WIDTH
			var map_h: float = main.GRID_SIZE * main.GRID_HEIGHT
			new_pos.x = clampf(new_pos.x, 0.0, map_w)
			new_pos.y = clampf(new_pos.y, 0.0, map_h)
			unit.position = new_pos
		else:
			# Ground/Crawler/Hover: blocked by solid cells in their respective grid
			var grid: AStarGrid2D = _get_grid_for_unit(unit)

			var map_w: float = main.GRID_SIZE * main.GRID_WIDTH
			var map_h: float = main.GRID_SIZE * main.GRID_HEIGHT
			var gs: float = main.GRID_SIZE

			# Unit radius for collision
			var radius: float = gs * 0.4

			# Check if a position is blocked, testing center + specific edge offsets
			var _check_solid = func(pos: Vector2, offsets: Array) -> bool:
				var cg: Vector2i = main.world_to_grid(pos)
				cg.x = clampi(cg.x, 0, main.GRID_WIDTH - 1)
				cg.y = clampi(cg.y, 0, main.GRID_HEIGHT - 1)
				if grid.is_point_solid(cg):
					return true
				for off in offsets:
					var eg: Vector2i = main.world_to_grid(pos + off)
					eg.x = clampi(eg.x, 0, main.GRID_WIDTH - 1)
					eg.y = clampi(eg.y, 0, main.GRID_HEIGHT - 1)
					if grid.is_point_solid(eg):
						return true
				return false

			var all_edges: Array = [Vector2(radius, 0), Vector2(-radius, 0), Vector2(0, radius), Vector2(0, -radius)]
			var x_edges: Array = [Vector2(radius, 0), Vector2(-radius, 0)]
			var y_edges: Array = [Vector2(0, radius), Vector2(0, -radius)]

			# Try full movement (check all edges)
			if not _check_solid.call(new_pos, all_edges):
				new_pos.x = clampf(new_pos.x, 0.0, map_w)
				new_pos.y = clampf(new_pos.y, 0.0, map_h)
				unit.position = new_pos
			else:
				# Wall-slide: try each axis with only its relevant edges
				var pos_x := Vector2(new_pos.x, unit.position.y)
				if not _check_solid.call(pos_x, x_edges):
					unit.position.x = clampf(new_pos.x, 0.0, map_w)

				var pos_y := Vector2(unit.position.x, new_pos.y)
				if not _check_solid.call(pos_y, y_edges):
					unit.position.y = clampf(new_pos.y, 0.0, map_h)

		# Clear any auto-combat targets while manually moving
		unit.path = PackedVector2Array()
		unit.path_index = 0
		unit.move_target = null
		unit.target_unit = null
		unit.target_building = null

	# --- Fire on left mouse held (like the player drone does) ---
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and main.selected_building == &"":
		if _control_attack_timer <= 0:
			var combat = _combat_sys_ref()
			if combat and unit.data:
				_control_attack_timer = unit.attack_cooldown
				var mouse_pos: Vector2 = get_global_mouse_position()
				var direction: Vector2 = (mouse_pos - unit.position).normalized()
				var fire_range: float = unit.data.detection_range
				var target_pos: Vector2 = unit.position + direction * fire_range
				var proj_speed: float = 300.0
				var proj_color: Color = unit.unit_color.lightened(0.3)
				# Direct-fire "none" type: flies toward mouse, hits enemies along the way
				combat._spawn_projectile(
					unit.position,
					null,
					target_pos,
					"none",
					proj_speed,
					unit.damage,
					proj_color,
					"player_unit",
					unit.data.is_aoe,
					unit.data.aoe_radius,
					main.Faction.LUMINA,
				)


func _update_controlled_turret(_delta: float) -> void:
	var grid_pos: Vector2i = controlled_entity
	if not main.placed_buildings.has(grid_pos):
		_release_control()
		return

	var combat = _combat_sys_ref()
	if not combat:
		return

	# Initialize turret state if needed
	if not combat.turret_angles.has(grid_pos):
		combat.turret_angles[grid_pos] = 0.0
	if not combat.turret_cooldowns.has(grid_pos):
		combat.turret_cooldowns[grid_pos] = 0.0

	# Turret head follows the mouse
	var turret_world: Vector2 = main.grid_to_world(grid_pos) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
	var mouse_pos: Vector2 = get_global_mouse_position()
	var target_angle: float = (mouse_pos - turret_world).angle()
	combat.turret_angles[grid_pos] = target_angle
	# Per-barrel toe-in toward the mouse from each muzzle pivot. Mirrors
	# the auto-fire logic so manually-controlled multi-barrel turrets
	# converge on close targets the same way.
	var bdata_aim = Registry.get_block(main.placed_buildings[grid_pos])
	if bdata_aim and combat.has_method("_update_barrel_toe_in"):
		combat._update_barrel_toe_in(grid_pos, bdata_aim, turret_world, mouse_pos, _delta)

	# Fire on left mouse held
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and main.selected_building == &"":
		if _control_attack_timer <= 0:
			var block_id = main.placed_buildings[grid_pos]
			var bdata = Registry.get_block(block_id)
			if bdata:
				# --- Ammo check (same Mindustry-style rule as auto-firing turrets) ---
				# A turret with ammo_types configured cannot fire without consuming
				# matching ammo from its storage, and a turret with no ammo_types
				# cannot fire at all.
				if bdata.ammo_types.is_empty():
					return
				var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
				var logistics = _logistics_ref()
				# Pull every relevant field off the AmmoType so manual-fire
				# behaves identically to auto-fire — including pellet count,
				# inaccuracy spread, knockback, lifetime, pierce, status, and
				# trail/colour. Otherwise scattershot turrets like the Diffuse
				# only fire a single bullet under manual control.
				# Damage lives on AmmoType — overwritten in the ammo
				# branch below; the no-ammo path returns earlier.
				var fire_damage: float = 0.0
				var fire_color: Color = bdata.color.lightened(0.3)
				var fire_reload_mult: float = 1.0
				var fire_speed: float = combat.default_projectile_speed
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
				var fire_aoe: bool = bdata.is_aoe
				var fire_aoe_radius: float = bdata.aoe_radius
				var fire_splash_mult: float = 1.0
				var ammo_found := false
				for ammo in bdata.ammo_types:
					if ammo == null or not (ammo is AmmoType):
						continue
					var ammo_data: AmmoType = ammo as AmmoType
					if logistics and logistics.has_method("get_stored_item_count"):
						var stored: int = logistics.get_stored_item_count(anchor, ammo_data.item_id)
						var amt: int = maxi(ammo_data.amount_per_shot, 1)
						if stored >= amt:
							logistics.remove_from_storage(anchor, ammo_data.item_id, amt)
							fire_damage = ammo_data.damage
							fire_color = ammo_data.projectile_color
							fire_reload_mult = ammo_data.reload_multiplier
							fire_speed = ammo_data.projectile_speed
							fire_lifetime = ammo_data.projectile_lifetime
							fire_radius = ammo_data.projectile_radius
							fire_pierce = ammo_data.pierce_count
							fire_homing = ammo_data.homing
							fire_knockback = ammo_data.knockback
							fire_inaccuracy = ammo_data.inaccuracy
							fire_pellets = ammo_data.projectiles_per_shot
							fire_range_bonus = ammo_data.range_bonus
							fire_status = ammo_data.status_effect
							fire_trail_color = ammo_data.get_trail_color()
							fire_collides_air = ammo_data.collides_air
							fire_collides_ground = ammo_data.collides_ground
							fire_bldg_mult = ammo_data.building_damage_mult
							fire_unit_mult = ammo_data.unit_damage_mult
							if ammo_data.is_splash:
								fire_aoe = true
								fire_aoe_radius = ammo_data.splash_radius
								fire_splash_mult = ammo_data.splash_damage_mult
							ammo_found = true
							break
				if not ammo_found:
					return  # Out of ammo — can't fire even when manually controlled

				var booster_mult: float = 1.0
				if combat.has_method("_get_active_booster_multiplier"):
					booster_mult = combat._get_active_booster_multiplier(grid_pos, bdata, "Fire Rate")
				_control_attack_timer = (bdata.attack_speed * fire_reload_mult) / maxf(booster_mult, 0.0001)
				# Match the auto-fire math in combat_system: derive barrel
				# length from the head texture so bullets spawn at the
				# visible muzzle, and offset perpendicular to the aim axis
				# for multi-barrel turrets, round-robinning through heads
				# on successive clicks. Keeps manual fire aligned with the
				# alternating auto-fire cadence.
				var barrel_length: float = main.GRID_SIZE * 0.4
				if bdata.turret_head_sprite:
					var head_tex_size: Vector2 = bdata.turret_head_sprite.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
					barrel_length = maxf(head_tex_size.y - 14.0 * main.SPRITE_SCALE_FACTOR, 0.0)
				var bcount: int = maxi(bdata.barrel_count, 1)
				# Round-robin which barrel fires; use that barrel's own
				# (toed-in) angle for the bullet path, while the muzzle
				# pivot still mounts perpendicular to the chassis aim.
				var fire_barrel_idx: int = 0
				if bcount > 1:
					fire_barrel_idx = int(_control_barrel_idx.get(grid_pos, 0)) % bcount
				var chassis_dir_ctrl := Vector2.from_angle(target_angle)
				var aim_perp_ctrl := Vector2(-chassis_dir_ctrl.y, chassis_dir_ctrl.x)
				var aim_dir_ctrl := chassis_dir_ctrl
				if combat.turret_barrel_angles.has(grid_pos):
					var bang: Array = combat.turret_barrel_angles[grid_pos]
					if fire_barrel_idx < bang.size():
						aim_dir_ctrl = Vector2.from_angle(float(bang[fire_barrel_idx]))
				var lateral_ctrl: float = 0.0
				# Recoil: kick the firing barrel back.
				if combat.turret_barrel_recoil.has(grid_pos):
					var brc_m: Array = combat.turret_barrel_recoil[grid_pos]
					if fire_barrel_idx < brc_m.size():
						brc_m[fire_barrel_idx] = 1.0
				if bcount > 1:
					lateral_ctrl = (float(fire_barrel_idx) - (float(bcount) - 1.0) * 0.5) * bdata.barrel_spacing
					# Flash the firing head and reset its per-barrel cooldown
					# (if tracked) so the auto-fire branch stays in sync.
					if combat.turret_barrel_fire_flash.has(grid_pos):
						var bff: Array = combat.turret_barrel_fire_flash[grid_pos]
						if fire_barrel_idx < bff.size():
							bff[fire_barrel_idx] = 0.1
					if combat.turret_barrel_cooldowns.has(grid_pos):
						var bcd: Array = combat.turret_barrel_cooldowns[grid_pos]
						if fire_barrel_idx < bcd.size():
							bcd[fire_barrel_idx] = bdata.attack_speed * fire_reload_mult
					_control_barrel_idx[grid_pos] = (fire_barrel_idx + 1) % bcount
				var fire_pos: Vector2 = turret_world + aim_dir_ctrl * barrel_length + aim_perp_ctrl * lateral_ctrl
				var fire_max_range: float = bdata.attack_range * main.GRID_SIZE + fire_range_bonus
				# Always travel along the head's aim axis so bullets visibly
				# exit the muzzle in the direction the head is pointing,
				# regardless of where the mouse is (especially when the
				# cursor is close to the turret, where mouse-aim from the
				# offset muzzle would skew the shot line).
				var shot_dir: Vector2 = aim_dir_ctrl
				# Projectiles travel toward `target_pos` and detonate when
				# they arrive — so we have to aim PAST the mouse to the
				# turret's full range. Using mouse-distance directly made
				# bullets vanish the moment they crossed the cursor even
				# though their `max_range` was higher.
				var shot_distance: float = maxf(fire_max_range, 1.0)
				# One projectile per pellet, with per-pellet random spread
				# inside the AmmoType's inaccuracy cone. Mirrors the auto-
				# fire loop in CombatSystem (including the even-fan
				# distribution) so multi-pellet turrets behave the same
				# when manually controlled.
				var pellet_total: int = maxi(fire_pellets, 1)
				# Multi-pellet salvos share a shot_id so repeat hits on the
				# same target halve damage per extra pellet (matches the
				# auto-fire diminishing rule in CombatSystem).
				var salvo_shot_id: int = combat._next_shot_id() if pellet_total > 1 else 0
				for pellet_i in range(pellet_total):
					var spread_rad: float = 0.0
					if fire_inaccuracy > 0.0 and pellet_total > 1:
						var t: float = float(pellet_i) / float(pellet_total - 1)
						var slot_w: float = (2.0 * fire_inaccuracy) / float(pellet_total)
						var center_deg: float = lerp(-fire_inaccuracy, fire_inaccuracy, t)
						var jitter_deg: float = randf_range(-slot_w * 0.5, slot_w * 0.5)
						spread_rad = deg_to_rad(center_deg + jitter_deg)
					elif fire_inaccuracy > 0.0:
						spread_rad = deg_to_rad(randf_range(-fire_inaccuracy, fire_inaccuracy))
					var pellet_angle: float = shot_dir.angle() + spread_rad
					var pellet_target: Vector2 = fire_pos + Vector2.from_angle(pellet_angle) * shot_distance
					combat._spawn_projectile(
						fire_pos,
						null,
						pellet_target,
						"none",
						fire_speed,
						fire_damage * fire_unit_mult,
						fire_color,
						"turret",
						fire_aoe,
						fire_aoe_radius,
						main.Faction.LUMINA,
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


# =========================
# PATHFINDING SETUP
# =========================

## Returns true if a unit on movement layer `ml` is allowed to occupy
## `world_pos`. FLYING is always permitted; HOVER uses astar_hover; ground
## uses astar; crawlers use astar_crawler. Out-of-bounds and unset grids
## are treated as walkable to avoid false positives blocking edge nudges.
func is_world_pos_walkable(world_pos: Vector2, ml: int, team: int = -1) -> bool:
	if ml == UnitData.MovementLayer.FLYING:
		return true
	var grid: Vector2i = main.world_to_grid(world_pos)
	if not main.is_within_bounds(grid):
		return false
	var astar_grid: AStarGrid2D = null
	match ml:
		UnitData.MovementLayer.GROUND:
			astar_grid = astar
		UnitData.MovementLayer.CRAWLER:
			astar_grid = astar_crawler
		UnitData.MovementLayer.HOVER:
			astar_grid = astar_hover
	if astar_grid != null and astar_grid.is_point_solid(grid):
		return false
	# Hostile unit-blocking shields count as solid for the asking
	# team. `team == -1` means "no faction filter" (legacy callers
	# that don't care about shields).
	if team != -1:
		var shield_sys = main.get_node_or_null("ShieldSystem")
		if shield_sys and shield_sys.has_method("is_unit_blocked_at"):
			if shield_sys.is_unit_blocked_at(world_pos, team):
				return false
	return true


## True if the cell is a platform sitting over water — the kind that
## should only carry one ground unit at a time.
func _is_water_platform_cell(grid_pos: Vector2i) -> bool:
	return _is_platform_cell(grid_pos) and _is_water_floor(grid_pos)


## Try to reserve a water-platform cell for the given unit. Returns true
## if the unit already holds the reservation or if the cell was free and
## is now reserved. Returns false if a different unit is already on it,
## in which case the caller should pause / re-plan.
func try_reserve_platform(unit: Node2D, grid_pos: Vector2i) -> bool:
	if unit == null:
		return false
	if not _is_water_platform_cell(grid_pos):
		return true  # Not a water platform — no gating.
	var uid: int = unit.get_instance_id()
	if not _water_platform_reservation.has(grid_pos):
		_water_platform_reservation[grid_pos] = uid
		return true
	# Stale reservation (holder despawned)? Take it over.
	var holder_id: int = int(_water_platform_reservation[grid_pos])
	if holder_id == uid:
		return true
	var holder = instance_from_id(holder_id)
	if holder == null or not is_instance_valid(holder):
		_water_platform_reservation[grid_pos] = uid
		return true
	return false


## Releases this unit's reservation on a water-platform cell (no-op if
## someone else holds it). Called by enemy_unit as it leaves the tile.
func release_platform(unit: Node2D, grid_pos: Vector2i) -> void:
	if unit == null:
		return
	if not _water_platform_reservation.has(grid_pos):
		return
	if int(_water_platform_reservation[grid_pos]) == unit.get_instance_id():
		_water_platform_reservation.erase(grid_pos)




## Cached output of `_build_solidity_sets()` — held only across the
## back-to-back `_setup_astar()` → `_setup_path_worker()` call pair so
## the second function doesn't redo the same per-cell scans the first
## one just finished. The pair is always called together (at sector
## load, save load, and unit_manager._ready), so this is exactly the
## window the cache needs to cover. Cleared at the end of
## `_setup_path_worker` to avoid retaining stale data between sectors.
var _cached_solidity: Dictionary = {}


## Single-pass scan of the grid that produces every solid set + the
## water-bias weight list, all three movement layers at once.
##
## Replaces what used to be ~6 independent full-grid loops scattered
## across `_setup_astar` and `_setup_path_worker` (each ~GRID_WIDTH ×
## GRID_HEIGHT, plus separate iterations of `placed_buildings` and
## `wall_tiles`). For a 200×200 map this brings setup-time grid
## traversals down from ~6×40 000 = 240 000 to one 40 000-cell sweep
## + two small dict iterations — most of the visible "hitch" at
## sector transitions came from those redundant scans.
func _build_solidity_sets() -> Dictionary:
	var terrain_sys = _terrain_ref()
	var sector_script = _sector_script_ref()
	var ground_set: Dictionary = {}
	var crawler_set: Dictionary = {}
	var hover_set: Dictionary = {}
	var ground_weights: Dictionary = {}  # grid_pos -> float, deduped
	var floor_dict: Dictionary = terrain_sys.floor_tiles if terrain_sys else {}
	var wall_dict: Dictionary = terrain_sys.wall_tiles if terrain_sys else {}

	# --- Buildings (single pass) ---
	# One iteration over placed_buildings serves all three layers + the
	# is_wall classification crawler needs. The per-cell predicate calls
	# (`_is_ground_passable_building`, `_is_building_wall`) are cheap
	# tag lookups; what was expensive before was iterating the building
	# dict 3-4 separate times.
	for grid_pos in main.placed_buildings:
		var passable: bool = _is_ground_passable_building(grid_pos)
		if not passable:
			ground_set[grid_pos] = true
			hover_set[grid_pos] = true
		if _is_building_wall(grid_pos):
			crawler_set[grid_pos] = true

	# --- Terrain walls (single pass) ---
	# Only walls flagged as `blocks_pathfinding` count as obstacles for
	# any movement layer — decorative walls (low rocks, etc.) without
	# the flag should let units pass through. Match the old behaviour
	# exactly (old code applied this filter to all three layers).
	# `_recompute_crawler_wall_passability` then prunes small wall
	# segments out of the crawler / hover layers in a second pass.
	if terrain_sys:
		for grid_pos in wall_dict:
			var tile_data = Registry.get_tile(wall_dict[grid_pos])
			if tile_data and tile_data.blocks_pathfinding:
				ground_set[grid_pos] = true
				crawler_set[grid_pos] = true
				hover_set[grid_pos] = true

	# --- Whole-grid sweep: void + hidden + water (one walk) ---
	# Was three separate GRID_WIDTH × GRID_HEIGHT loops before. Each
	# cell now pays only a couple dict lookups and (rarely) a
	# water-tile registry hit.
	for x in range(main.GRID_WIDTH):
		for y in range(main.GRID_HEIGHT):
			var gp := Vector2i(x, y)
			var has_floor: bool = floor_dict.has(gp)
			var has_wall: bool = wall_dict.has(gp)
			# VOID — no floor + no wall = nothing to walk / hover on.
			if not has_floor and not has_wall:
				ground_set[gp] = true
				crawler_set[gp] = true
				hover_set[gp] = true
				continue
			# Sector-script hidden tiles are an impassable barrier for
			# every layer.
			if sector_script and sector_script.is_tile_hidden(gp):
				ground_set[gp] = true
				crawler_set[gp] = true
				hover_set[gp] = true
				continue
			# WATER bias — only for cells that have a water floor and
			# no covering building (a platform / floating transport
			# overrides the bias and lands them on dry land).
			if has_floor and not main.placed_buildings.has(gp):
				var td: TerrainTileData = Registry.get_tile(floor_dict[gp])
				if td and td.is_liquid and td.tags.has("water"):
					var w: float = _water_cell_weight(gp)
					if w > 1.0:
						ground_weights[gp] = w

	return {
		"ground": ground_set,
		"crawler": crawler_set,
		"hover": hover_set,
		"ground_weights": ground_weights,
	}


func _setup_astar() -> void:
	# Build the shared solidity sets once and stash them so
	# `_setup_path_worker` (which always runs right after) can reuse
	# them instead of redoing the same scans.
	var sets: Dictionary = _build_solidity_sets()
	_cached_solidity = sets
	var ground_set: Dictionary = sets["ground"]
	var crawler_set: Dictionary = sets["crawler"]
	var hover_set: Dictionary = sets["hover"]
	var ground_weights: Dictionary = sets["ground_weights"]

	# --- GROUND AStar ---
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, main.GRID_WIDTH, main.GRID_HEIGHT)
	astar.cell_size = Vector2(main.GRID_SIZE, main.GRID_SIZE)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.update()
	for gp in ground_set:
		astar.set_point_solid(gp, true)
	for gp in ground_weights:
		astar.set_point_weight_scale(gp, float(ground_weights[gp]))

	# --- CRAWLER AStar ---
	astar_crawler = AStarGrid2D.new()
	astar_crawler.region = Rect2i(0, 0, main.GRID_WIDTH, main.GRID_HEIGHT)
	astar_crawler.cell_size = Vector2(main.GRID_SIZE, main.GRID_SIZE)
	astar_crawler.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar_crawler.update()
	for gp in crawler_set:
		astar_crawler.set_point_solid(gp, true)
	for gp in ground_weights:
		astar_crawler.set_point_weight_scale(gp, float(ground_weights[gp]))

	# --- HOVER AStar ---
	astar_hover = AStarGrid2D.new()
	astar_hover.region = Rect2i(0, 0, main.GRID_WIDTH, main.GRID_HEIGHT)
	astar_hover.cell_size = Vector2(main.GRID_SIZE, main.GRID_SIZE)
	astar_hover.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar_hover.update()
	for gp in hover_set:
		astar_hover.set_point_solid(gp, true)

	# Analyze terrain wall segments for crawler / hover passability.
	# Mutates astar_crawler and astar_hover in place: small wall segments
	# get flipped back to non-solid for crawlers, medium ones for hover.
	_recompute_crawler_wall_passability()


func _setup_path_worker() -> void:
	# Reuse the solidity sets computed by `_setup_astar` (always called
	# right before this). Falling back to a fresh build keeps the
	# function callable standalone in case anything ever calls it
	# without the paired setup.
	var sets: Dictionary = _cached_solidity if not _cached_solidity.is_empty() \
			else _build_solidity_sets()
	_cached_solidity = {}  # don't hold across the next sector load

	var ground_set: Dictionary = sets["ground"]
	var crawler_set: Dictionary = sets["crawler"]
	var hover_set: Dictionary = sets["hover"]
	var ground_weights_dict: Dictionary = sets["ground_weights"]

	# Crawler wall passability already pruned small segments from
	# `astar_crawler`; mirror those exclusions into the worker's set so
	# the background grid agrees with the main-thread grid.
	for gp in _crawler_passable_walls:
		crawler_set.erase(gp)
	for gp in _hover_passable_walls:
		hover_set.erase(gp)

	# Flatten to typed arrays for the worker API.
	var ground_solids: Array[Vector2i] = []
	var crawler_solids: Array[Vector2i] = []
	var hover_solids: Array[Vector2i] = []
	for gp in ground_set: ground_solids.append(gp)
	for gp in crawler_set: crawler_solids.append(gp)
	for gp in hover_set: hover_solids.append(gp)
	var ground_weights: Array = []
	var crawler_weights: Array = []
	for gp in ground_weights_dict:
		var entry := [gp, float(ground_weights_dict[gp])]
		ground_weights.append(entry)
		crawler_weights.append(entry)

	# Tear down any previously-running worker before spawning a new one.
	# Without this the old thread keeps answering pathfind requests with
	# its stale grid and ground units happily walk through walls that
	# WERE in the up-to-date main-thread astar.
	if _path_worker:
		_path_worker.stop()
		_path_worker = null
	_path_worker = PathfindingWorker.new()
	_path_worker.start(main.GRID_WIDTH, main.GRID_HEIGHT, main.GRID_SIZE,
		ground_solids, crawler_solids, hover_solids,
		ground_weights, crawler_weights)


func _poll_path_results() -> void:
	if _path_worker == null:
		return
	var results := _path_worker.poll_results()
	for r in results:
		var unit_id: int = r["unit_id"]
		var obj = instance_from_id(unit_id)
		if obj == null or not is_instance_valid(obj):
			continue
		var unit: Node2D = obj as Node2D
		if unit == null or unit.is_dead:
			continue

		var path: PackedVector2Array = r["path"]
		var target_bldg_id: int = r["target_building_id"]

		# Resolve target building from instance ID
		var target_bldg: Variant = null
		if target_bldg_id > 0:
			# target_building_id encodes a Vector2i packed as (x << 16) | (y & 0xFFFF)
			target_bldg = _unpack_grid_pos(target_bldg_id)
			# Verify building still exists
			if not main.placed_buildings.has(target_bldg):
				target_bldg = null

		# Empty path + valid target = target unreachable (player walled off
		# the base). Without a fallback the enemy parks forever:
		# `_try_attack` rejects the range check, never re-requests a path,
		# and the FEROX wave looks like it gave up. Retarget to the
		# nearest LUMINA structure we CAN actually walk to (typically the
		# closest segment of the wall the player just built) so the unit
		# chews its way in instead of sitting idle.
		if path.is_empty() and target_bldg != null and unit.team == UnitData.Team.ENEMY:
			var reachable = _find_nearest_reachable_building(unit, main.Faction.LUMINA)
			if reachable != null:
				_path_worker.request_path(
					unit.get_instance_id(),
					main.world_to_grid(unit.position),
					reachable as Vector2i,
					unit.data.movement_layer if unit.data else 0,
					_pack_grid_pos(reachable),
				)
				continue

		unit.set_path(path, target_bldg)


## BFS-based fallback target picker. Floods walkable cells outward from
## `unit`'s current grid position on its movement layer's AStarGrid2D
## (capped at REACHABLE_BFS_BUDGET cells so a giant open map doesn't
## stall). For every reached cell, checks the 4 cardinal neighbours for
## a placed building of `target_faction` — first one found is returned
## as a guaranteed-reachable target. Returns null if the unit is
## genuinely walled into a void pocket.
const REACHABLE_BFS_BUDGET := 4000
func _find_nearest_reachable_building(unit: Node2D, target_faction: int) -> Variant:
	var grid: AStarGrid2D = _get_grid_for_unit(unit)
	if grid == null:
		return null
	var start: Vector2i = main.world_to_grid(unit.position)
	start.x = clampi(start.x, 0, main.GRID_WIDTH - 1)
	start.y = clampi(start.y, 0, main.GRID_HEIGHT - 1)
	if grid.is_point_solid(start):
		# Find adjacent walkable so the BFS has somewhere to begin.
		var adj: Variant = _find_adjacent_walkable_on_grid(start, grid)
		if adj == null:
			return null
		start = adj as Vector2i
	var visited: Dictionary = {start: true}
	var queue: Array[Vector2i] = [start]
	var head := 0
	var dirs: Array[Vector2i] = [
		Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0),
	]
	while head < queue.size() and visited.size() < REACHABLE_BFS_BUDGET:
		var cell: Vector2i = queue[head]
		head += 1
		# Check the four neighbours for a hostile building anchor.
		for d in dirs:
			var nb: Vector2i = cell + d
			if not main.is_within_bounds(nb):
				continue
			if main.placed_buildings.has(nb):
				if main.get_building_faction(nb) == target_faction:
					var bdata = Registry.get_block(main.placed_buildings[nb])
					if not (bdata and bdata.tags.has("platform")):
						return main.building_origins.get(nb, nb)
				continue
			if visited.has(nb):
				continue
			if grid.is_point_solid(nb):
				continue
			visited[nb] = true
			queue.append(nb)
	return null


## Pack a Vector2i into an int for thread-safe transfer
func _pack_grid_pos(grid_pos: Vector2i) -> int:
	return (grid_pos.x << 16) | (grid_pos.y & 0xFFFF)


## Unpack a Vector2i from a packed int
func _unpack_grid_pos(packed: int) -> Vector2i:
	var x: int = packed >> 16
	var y: int = packed & 0xFFFF
	# Sign-extend y if it was negative (shouldn't happen with grid coords but safety)
	if y >= 0x8000:
		y -= 0x10000
	return Vector2i(x, y)


func _on_building_placed(_block_id: StringName, grid_pos: Vector2i) -> void:
	# Any structural change invalidates the flow-field cache (a new wall
	# can block a previously-fine route; a destroyed wall can open one).
	# Same for base-cluster topology — recompute lazily next tick.
	_invalidate_flow_fields()
	_base_dirty = true
	var data = Registry.get_block(_block_id)
	# Platforms now count as passable so ground units can cross water
	# bodies via the planks the player laid down.
	var is_passable: bool = data != null and (
		data.transport_speed > 0 or data.transports_fluid or data.tags.has("platform")
	)
	var is_wall: bool = data != null and data.category == BlockData.BlockCategory.WALLS

	if data:
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				var tile_pos = grid_pos + Vector2i(x, y)
				if main.is_within_bounds(tile_pos):
					# GROUND: solid unless this building is passable.
					if is_passable:
						astar.set_point_solid(tile_pos, false)
						# Passable building over water replaces water's
						# pathfinding penalty with a normal weight so
						# A* treats the platform deck as dry land.
						astar.set_point_weight_scale(tile_pos, 1.0)
						if _path_worker:
							_path_worker.queue_set_solid(tile_pos, false, "ground")
							_path_worker.queue_set_weight(tile_pos, 1.0, "ground")
					else:
						astar.set_point_solid(tile_pos, true)
						if _path_worker:
							_path_worker.queue_set_solid(tile_pos, true, "ground")
					# CRAWLER: only walls block.
					if is_wall:
						astar_crawler.set_point_solid(tile_pos, true)
						if _path_worker:
							_path_worker.queue_set_solid(tile_pos, true, "crawler")
					elif is_passable and _is_water_floor(tile_pos):
						astar_crawler.set_point_solid(tile_pos, false)
						astar_crawler.set_point_weight_scale(tile_pos, 1.0)
						if _path_worker:
							_path_worker.queue_set_solid(tile_pos, false, "crawler")
							_path_worker.queue_set_weight(tile_pos, 1.0, "crawler")
					# HOVER: same passability rule as ground. Hover units
					# can't skim over a wall or a factory the way they used
					# to — only over water (handled at setup time).
					if is_passable:
						astar_hover.set_point_solid(tile_pos, false)
						if _path_worker:
							_path_worker.queue_set_solid(tile_pos, false, "hover")
					else:
						astar_hover.set_point_solid(tile_pos, true)
						if _path_worker:
							_path_worker.queue_set_solid(tile_pos, true, "hover")
	else:
		astar.set_point_solid(grid_pos, true)
		if _path_worker:
			_path_worker.queue_set_solid(grid_pos, true, "ground")

	_update_all_enemy_paths()


func on_building_destroyed(grid_pos: Vector2i) -> void:
	_invalidate_flow_fields()
	_base_dirty = true
	# Always non-solid for ground / crawler (water is no longer hard-
	# blocked). Water cells get their pathfinding penalty restored so
	# units once again prefer dry routes around the cell. Hover ignores
	# water — clears to walkable regardless of the floor.
	astar.set_point_solid(grid_pos, false)
	astar_crawler.set_point_solid(grid_pos, false)
	astar_hover.set_point_solid(grid_pos, false)
	var restored_weight: float = _water_cell_weight(grid_pos)
	astar.set_point_weight_scale(grid_pos, restored_weight)
	astar_crawler.set_point_weight_scale(grid_pos, restored_weight)
	if _path_worker:
		_path_worker.queue_set_solid(grid_pos, false, "ground")
		_path_worker.queue_set_solid(grid_pos, false, "crawler")
		_path_worker.queue_set_solid(grid_pos, false, "hover")
		_path_worker.queue_set_weight(grid_pos, restored_weight, "ground")
		_path_worker.queue_set_weight(grid_pos, restored_weight, "crawler")
	# Drop any reservation on a destroyed platform cell.
	_water_platform_reservation.erase(grid_pos)


# =========================
# SPAWNING
# =========================

## Spawns an enemy of the given UnitData ID at the given position AND
## enrolls it in the FEROX fabricator's squad. The unit holds at a
## rally point a few tiles ahead of the fabricator instead of marching
## off on its own — the squad releases as a group once it judges
## itself strong enough to break through, or after a timeout.
##
## Returns the spawned unit, or null on failure.
func spawn_enemy_for_fabricator(spawn_position: Vector2, unit_id: StringName, fab_anchor: Vector2i) -> Node2D:
	var enemy: Node2D = _spawn_enemy_internal(spawn_position, unit_id)
	if enemy == null:
		return null
	if "squad_anchor" in enemy:
		enemy.squad_anchor = fab_anchor
	if "is_rallying" in enemy:
		enemy.is_rallying = true

	# Make sure the squad bucket exists, then enroll this unit and
	# point it at the rally hold position so it doesn't immediately
	# pathfind to the player's base.
	if not enemy_squads.has(fab_anchor):
		enemy_squads[fab_anchor] = {
			"units": [] as Array[Node2D],
			"rally_pos": _compute_rally_point(fab_anchor),
			"release_at": _SQUAD_MIN_SIZE,
			"first_spawn": 0.0,
			"released": false,
		}
		# Seed the release threshold immediately so newly-built fabs
		# don't have to wait for the next scan tick.
		enemy_squads[fab_anchor]["release_at"] = _compute_release_threshold(_assess_player_threat())
	var squad: Dictionary = enemy_squads[fab_anchor]
	# A previous squad cycle marked released — start fresh.
	if squad.get("released", false):
		squad["units"] = [] as Array[Node2D]
		squad["released"] = false
		squad["first_spawn"] = 0.0
		squad["rally_pos"] = _compute_rally_point(fab_anchor)
	if squad["units"].is_empty():
		squad["first_spawn"] = 0.0
	(squad["units"] as Array).append(enemy)
	# Path the new unit to the rally hold position instead of letting
	# it pick its own nearest-LUMINA-building target.
	assign_path_to_position(enemy, squad["rally_pos"])
	return enemy


## Spawns an enemy of the given UnitData ID at the given position.
func spawn_enemy(spawn_position: Vector2, unit_id: StringName = &"basic_cell") -> void:
	var enemy: Node2D = _spawn_enemy_internal(spawn_position, unit_id)
	if enemy != null:
		# Lone-spawn (waves, nests): march straight at the player.
		_assign_path_to_enemy(enemy)


## Shared body of spawn_enemy / spawn_enemy_for_fabricator. Creates the
## node, validates the cell, and adds it to the scene + enemies array.
## Pathing is the caller's responsibility — wave / nest enemies pick the
## standard nearest-LUMINA-building target, fabricator enemies park at
## the squad rally point first.
func _spawn_enemy_internal(spawn_position: Vector2, unit_id: StringName) -> Node2D:
	var unit_data = Registry.get_unit(unit_id)
	if unit_data == null:
		push_warning("UnitManager: Unit '%s' not found in Registry — using fallback stats." % unit_id)

	var ml_e: int = unit_data.movement_layer if unit_data else 0
	var corrected_e: Variant = _validate_spawn_position(spawn_position, ml_e)
	if corrected_e == null:
		push_warning("UnitManager: refused to spawn '%s' — no walkable cell near %s" % [unit_id, str(spawn_position)])
		return null
	var enemy = Node2D.new()
	enemy.set_script(enemy_script)
	enemy.data = unit_data
	enemy.team = UnitData.Team.ENEMY
	enemy.main = main
	enemy.unit_manager = self
	enemy.position = corrected_e

	add_child(enemy)
	enemies.append(enemy)
	return enemy


## Spawns a player unit at the given position (produced by a fabricator).
func spawn_player_unit(spawn_position: Vector2, unit_id: StringName) -> void:
	var unit_data = Registry.get_unit(unit_id)
	if unit_data == null:
		push_warning("UnitManager: Unit '%s' not found in Registry!" % unit_id)
		return

	var ml_p: int = unit_data.movement_layer
	var corrected_p: Variant = _validate_spawn_position(spawn_position, ml_p)
	if corrected_p == null:
		push_warning("UnitManager: refused to spawn '%s' — no walkable cell near %s" % [unit_id, str(spawn_position)])
		return
	var unit = Node2D.new()
	unit.set_script(enemy_script)
	unit.data = unit_data
	unit.team = UnitData.Team.PLAYER
	unit.main = main
	unit.unit_manager = self
	unit.position = corrected_p

	add_child(unit)
	player_units.append(unit)
	# Player units don't pathfind to buildings — they idle at spawn


## Returns the requested position if it's walkable for `ml`, otherwise
## scans a small ring (up to 4 tiles) for the nearest walkable cell and
## snaps to its centre. Returns `null` when nothing nearby is legal —
## caller should bail rather than placing the unit on a wall / void.
## Flying units always pass; their layer has no walkability constraint.
func _validate_spawn_position(world_pos: Vector2, ml: int) -> Variant:
	if ml == UnitData.MovementLayer.FLYING:
		return world_pos
	if is_world_pos_walkable(world_pos, ml):
		return world_pos
	var here: Vector2i = main.world_to_grid(world_pos)
	for radius in range(1, 5):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if absi(dx) != radius and absi(dy) != radius:
					continue
				var probe: Vector2i = here + Vector2i(dx, dy)
				var probe_world: Vector2 = main.grid_to_world(probe) + Vector2(main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5)
				if is_world_pos_walkable(probe_world, ml):
					return probe_world
	return null


func _spawn_test_nests() -> void:
	pass  # No hardcoded test nests — enemies are spawned by sector data


# =========================
# PATHFINDING
# =========================

func _update_all_enemy_paths() -> void:
	for enemy in enemies:
		if is_instance_valid(enemy) and not enemy.is_dead:
			_assign_path_to_enemy(enemy)


func _assign_path_to_enemy(enemy: Node2D) -> void:
	if _path_worker == null:
		return
	# Squad members holding at a rally point shouldn't be repathed to
	# the player's base by the periodic _update_all_enemy_paths sweep —
	# that's exactly the "march independently" behaviour the squad
	# system is trying to suppress.
	if "is_rallying" in enemy and enemy.is_rallying:
		return

	var enemy_grid: Vector2i = main.world_to_grid(enemy.position)
	enemy_grid.x = clampi(enemy_grid.x, 0, main.GRID_WIDTH - 1)
	enemy_grid.y = clampi(enemy_grid.y, 0, main.GRID_HEIGHT - 1)

	# Units should only target opposing-faction buildings. DERELICT is
	# neutral — neither side should chase abandoned blocks.
	var target_faction: int = -1
	if enemy.team == UnitData.Team.ENEMY:
		target_faction = main.Faction.LUMINA
	elif enemy.team == UnitData.Team.PLAYER:
		target_faction = main.Faction.FEROX
	# Released FEROX squad members + FEROX units in general now use the
	# weighted target scorer so a unit walking past walls toward a fat
	# turret no longer wastes time chewing through random outer blocks.
	var nearest_building: Variant
	if enemy.team == UnitData.Team.ENEMY:
		nearest_building = _find_priority_building_target(enemy_grid, target_faction)
		if nearest_building == null:
			nearest_building = _find_nearest_building(enemy_grid, target_faction)
	else:
		nearest_building = _find_nearest_building(enemy_grid, target_faction)
	if nearest_building == null:
		enemy.set_path(PackedVector2Array(), null)
		return

	var ml: int = enemy.data.movement_layer if enemy.data else 0

	var target_bldg_id: int = _pack_grid_pos(nearest_building)

	_path_worker.request_path(
		enemy.get_instance_id(),
		enemy_grid,
		nearest_building as Vector2i,
		ml,
		target_bldg_id,
	)


func _find_nearest_building(from: Vector2i, target_faction: int = -1) -> Variant:
	var nearest: Variant = null
	var nearest_dist := 999999.0

	for grid_pos in main.placed_buildings:
		if target_faction >= 0 and main.get_building_faction(grid_pos) != target_faction:
			continue
		# Platforms are non-targetable terrain — units skip them when
		# scanning for hostile structures so a unit doesn't waste
		# pathing on a platform that can't be damaged anyway.
		var bid: StringName = main.placed_buildings[grid_pos]
		var bdata = Registry.get_block(bid)
		if bdata and bdata.tags.has("platform"):
			continue
		var dx = abs(grid_pos.x - from.x)
		var dy = abs(grid_pos.y - from.y)
		var dist = max(dx, dy) as float
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = grid_pos

	return nearest


## Weighted variant of _find_nearest_building. Score blocks via
## `_score_building_for_attack` (type weight × vulnerability × HP-bonus
## ÷ distance falloff), so an enemy walking past a wall toward an
## exposed turret will hit the turret first. Falls back to nearest
## building when nothing scores. Used for squad target acquisition and
## enemy retargeting on stuck/dead-target.
##
## Pressure pushes target depth: at higher pressure the distance
## divisor is softened so deep-base targets (cores, fabs) outscore
## shallow ones.
func _find_priority_building_target(from: Vector2i, target_faction: int = -1) -> Variant:
	var best: Variant = null
	var best_score := -1.0
	var aggression: float = _pressure_mult()
	for grid_pos in main.placed_buildings:
		if target_faction >= 0 and main.get_building_faction(grid_pos) != target_faction:
			continue
		var bid: StringName = main.placed_buildings[grid_pos]
		var bdata = Registry.get_block(bid)
		if bdata == null or bdata.tags.has("platform"):
			continue
		var score: float = _score_building_for_attack(grid_pos, bdata, from, aggression)
		if score > best_score:
			best_score = score
			best = grid_pos
	return best


## Score a candidate LUMINA building from the attacker's POV. Higher =
## more attractive to push toward. Components:
##   • base type weight (core / turret / fab / drill / etc.)
##   • vulnerability — buildings buried in walls score lower
##   • damage bonus — a building below 50% HP gets a finisher boost
##   • distance falloff — softer at higher pressure
##
## All factors are tunable. Score 0 means "ignore this building entirely."
func _score_building_for_attack(grid_pos: Vector2i, bdata: BlockData, from: Vector2i, aggression: float = 1.0) -> float:
	var w: float = _building_target_weight(bdata)
	if w <= 0.0:
		return 0.0
	# Vulnerability: count solid wall tiles within a 3-tile ring around
	# the building. Lots of walls → lower score (the squad needs to
	# break through before scoring damage). Range 0..1, applied as
	# 0.4..1.0 multiplier so even walled-in cores still attract a push.
	var vuln: float = _building_vulnerability(grid_pos)
	# HP bonus — finish the wounded. Buildings under 50% HP get up to
	# +50% score, scaling linearly.
	var hp_bonus: float = 1.0
	if main.building_health.has(grid_pos) and bdata.max_health > 0.0:
		var hp_frac: float = clampf(float(main.building_health[grid_pos]) / float(bdata.max_health), 0.0, 1.0)
		if hp_frac < 0.5:
			hp_bonus = 1.0 + (0.5 - hp_frac)
	var dx = abs(grid_pos.x - from.x)
	var dy = abs(grid_pos.y - from.y)
	var dist = float(max(dx, dy))
	# Higher aggression flattens distance — pushes will go deeper.
	var divisor_scale: float = 12.0 + (aggression - 1.0) * 18.0
	var score: float = w * vuln * hp_bonus / (1.0 + dist / divisor_scale)
	return score


## Returns a 0.4 .. 1.0 vulnerability factor. 1.0 = no surrounding
## walls. 0.4 = densely walled in. Cheap 8-neighbour scan around the
## building footprint.
func _building_vulnerability(grid_pos: Vector2i) -> float:
	var wall_n: int = 0
	var checked: int = 0
	# 3x3 footprint scan around the anchor is good enough — we don't
	# need to be exact, just approximate.
	for dx in [-2, -1, 0, 1, 2]:
		for dy in [-2, -1, 0, 1, 2]:
			if dx == 0 and dy == 0:
				continue
			var p: Vector2i = grid_pos + Vector2i(dx, dy)
			if not main.is_within_bounds(p):
				continue
			checked += 1
			if not main.placed_buildings.has(p):
				continue
			var nbid: StringName = main.placed_buildings[p]
			var nbd = Registry.get_block(nbid)
			if nbd == null:
				continue
			if nbd.tags.has("wall"):
				wall_n += 1
	if checked == 0:
		return 1.0
	var dense: float = clampf(float(wall_n) / float(checked), 0.0, 1.0)
	return lerpf(1.0, 0.4, dense)


func _building_target_weight(bdata: BlockData) -> float:
	# Hand-tuned weights. Anything not in the list gets the generic 1.0.
	# Cores are the win-condition target; turrets and fabs are the
	# next-most-valuable since killing them shrinks the player's
	# offensive AND defensive output.
	var tags: PackedStringArray = bdata.tags
	if tags.has("core"):
		return 12.0
	if tags.has("turret") or tags.has("defense"):
		return 6.5
	if tags.has("mender"):
		return 5.5
	# Power generation / nodes — destroying these dominoes into
	# unpowering the whole base. Worth more than raw factories.
	if tags.has("power") or tags.has("generator") or tags.has("reactor") or tags.has("solar"):
		return 4.5
	if tags.has("fabricator") or tags.has("factory") or tags.has("constructor"):
		return 4.0
	# Resource production — second-order economic value.
	if tags.has("drill") or tags.has("extractor") or tags.has("crusher") or tags.has("grinder") or tags.has("pump"):
		return 2.8
	# Storage — taking these out denies the player buffer to weather
	# disruptions. Slightly above transports.
	if tags.has("vault") or tags.has("container") or tags.has("storage"):
		return 1.4
	if tags.has("pipe") or tags.has("duct") \
			or tags.has("payload") or tags.has("freight") \
			or bdata.tags.has("belt") or tags.has("cable"):
		return 0.5
	if tags.has("wall"):
		return 0.2
	return 1.0


# =========================
# SQUAD: rally / release helpers
# =========================

func _compute_rally_point(fab_anchor: Vector2i) -> Vector2:
	# Park the squad ~2 tiles in front of the fabricator (the cell the
	# units actually walked out into), so the rally is clearly outside
	# the fabricator's footprint regardless of the building's size.
	if not main.placed_buildings.has(fab_anchor):
		return main.grid_to_world(fab_anchor) + Vector2(main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5)
	var bdata = Registry.get_block(main.placed_buildings[fab_anchor])
	var sx: int = bdata.grid_size.x if bdata else 1
	var sy: int = bdata.grid_size.y if bdata else 1
	var rot: int = main.building_rotation.get(fab_anchor, 0)
	var gs: float = float(main.GRID_SIZE)
	var center := Vector2(
		(fab_anchor.x + sx * 0.5) * gs,
		(fab_anchor.y + sy * 0.5) * gs,
	)
	var dx_t: float = sx * 0.5 + _SQUAD_RALLY_TILES
	var dy_t: float = sy * 0.5 + _SQUAD_RALLY_TILES
	match rot:
		0: return center + Vector2(dx_t * gs, 0)
		1: return center + Vector2(0, dy_t * gs)
		2: return center + Vector2(-dx_t * gs, 0)
		3: return center + Vector2(0, -dy_t * gs)
	return center + Vector2(dx_t * gs, 0)


## Estimated combat "damage per second" the player currently throws at
## a unit walking into the base. Sums every LUMINA turret on the map:
##     turret.attack_damage / max(turret.attack_speed, 0.1)
## Tiny turrets contribute their share; high-DPS turrets dominate. Used
## as the input to `_compute_release_threshold`.
func _assess_player_threat() -> float:
	var total: float = 0.0
	for grid_pos in main.placed_buildings:
		if main.get_building_faction(grid_pos) != main.Faction.LUMINA:
			continue
		var bdata = Registry.get_block(main.placed_buildings[grid_pos])
		if bdata == null:
			continue
		var is_turret: bool = bdata.tags.has("turret")
		if not is_turret and bdata.has_method("is_turret"):
			is_turret = bdata.is_turret()
		if not is_turret:
			continue
		var dmg: float = bdata.attack_damage if "attack_damage" in bdata else 0.0
		var spd: float = bdata.attack_speed if "attack_speed" in bdata else 1.0
		if spd <= 0.0:
			spd = 1.0
		total += dmg / spd
	# Add a small contribution per player unit so a swarm of shardlings
	# also forces the squad to wait for backup.
	for u in player_units:
		if u == null or not is_instance_valid(u) or u.is_dead:
			continue
		var udata = u.data if "data" in u else null
		if udata:
			var udmg: float = udata.attack_damage if "attack_damage" in udata else 0.0
			var uspd: float = udata.attack_speed if "attack_speed" in udata else 1.0
			if uspd <= 0.0:
				uspd = 1.0
			total += udmg / uspd
	return total


func _compute_release_threshold(player_threat: float) -> int:
	# Translate measured DPS into a target squad size, biased toward
	# fewer-but-bigger pushes against heavy defenses. Pressure scales
	# the required squad size up — under high pressure even a low-threat
	# player will face larger pushes.
	var pm: float = _pressure_mult()
	if player_threat <= 0.1 and pm <= 1.05:
		return _SQUAD_MIN_SIZE
	var raw: int = int(ceil(player_threat / _SQUAD_AVG_UNIT_DPS))
	# Pressure bonus: +1 unit per 0.2 above baseline (so 1.0 → +0,
	# 1.4 → +2, 1.6 → +3). Layered on top of DPS-derived raw.
	var pressure_bonus: int = int(round(max(0.0, (pm - 1.0)) * 5.0))
	raw += pressure_bonus
	return clampi(raw, _SQUAD_MIN_SIZE, _SQUAD_MAX_SIZE)


## Releases the squad — every member picks a high-value LUMINA target
## and starts pathing. Members are spread across a few different
## targets so an entire push doesn't suicide-stack on a single wall
## tile when the priority scorer returns the same anchor for everyone.
##
## Flow-field accelerated: when a squad releases, it picks a small
## handful (1-3) of high-value LUMINA targets, builds a flow field per
## (target, movement_layer) pair, and traces each member through the
## field instead of running A* per unit. This scales to large pushes
## almost for free.
func _release_squad(fab_anchor: Vector2i) -> void:
	if not enemy_squads.has(fab_anchor):
		return
	var squad: Dictionary = enemy_squads[fab_anchor]
	var members: Array = squad.get("units", [])

	# Collect a representative spawn point (rally pos or fab center) and
	# pick a few targets to spread the push across.
	var origin_cell: Vector2i = fab_anchor
	var targets: Array[Vector2i] = _pick_push_targets(origin_cell, 3)

	if targets.is_empty():
		# Nothing to attack — fall back to single-unit nearest sweep.
		for unit in members:
			if unit == null or not is_instance_valid(unit) or unit.is_dead:
				continue
			if "is_rallying" in unit:
				unit.is_rallying = false
			_assign_priority_path_to_enemy(unit)
		squad["units"] = [] as Array[Node2D]
		squad["released"] = true
		squad["first_spawn"] = 0.0
		return

	# Distribute units across the chosen targets round-robin. Flow fields
	# are built lazily on first use via _get_flow_field.
	var ti: int = 0
	for unit in members:
		if unit == null or not is_instance_valid(unit) or unit.is_dead:
			continue
		if "is_rallying" in unit:
			unit.is_rallying = false
		var target_cell: Vector2i = targets[ti % targets.size()]
		ti += 1
		_assign_flow_path_to_enemy(unit, target_cell)
	squad["units"] = [] as Array[Node2D]
	squad["released"] = true
	squad["first_spawn"] = 0.0


## Picks up to `count` high-value LUMINA targets to split a push across.
## Targets are well-separated to avoid the squad suicide-stacking on
## one wall tile. Uses the same building-target scoring as the per-unit
## picker (so squad-level and unit-level decisions agree on what's
## worth attacking).
func _pick_push_targets(origin: Vector2i, count: int, faction: int = -1) -> Array[Vector2i]:
	var target_faction: int = main.Faction.LUMINA if faction < 0 else faction
	var scored: Array = []
	var aggression: float = _pressure_mult()
	for grid_pos in main.placed_buildings:
		if main.get_building_faction(grid_pos) != target_faction:
			continue
		var bid: StringName = main.placed_buildings[grid_pos]
		var bdata = Registry.get_block(bid)
		if bdata == null or bdata.tags.has("platform"):
			continue
		var score: float = _score_building_for_attack(grid_pos, bdata, origin, aggression)
		if score <= 0.0:
			continue
		scored.append({"pos": grid_pos, "score": score})
	scored.sort_custom(func(a, b): return a["score"] > b["score"])
	var out: Array[Vector2i] = []
	var min_sep_sq: int = 8 * 8
	for entry in scored:
		var p: Vector2i = entry["pos"]
		var ok: bool = true
		for q in out:
			var dxq = p.x - q.x
			var dyq = p.y - q.y
			if dxq * dxq + dyq * dyq < min_sep_sq:
				ok = false
				break
		if ok:
			out.append(p)
		if out.size() >= count:
			break
	if out.is_empty() and not scored.is_empty():
		out.append(scored[0]["pos"])
	return out


## Pack (target, movement_layer) into a string key for the cache.
func _flow_key(target: Vector2i, ml: int) -> String:
	return "%d,%d,%d" % [target.x, target.y, ml]


## Returns the AStarGrid2D the given movement layer should consult for
## solidity. FLYING returns null (always passable).
func _astar_for_layer(ml: int) -> AStarGrid2D:
	# Layer enum mirrors UnitData.MovementLayer: 0=GROUND, 1=CRAWLER,
	# 2=HOVER, 3=FLYING.
	match ml:
		1: return astar_crawler
		2: return astar_hover
		3: return null
		_: return astar


## Look up a cached flow field for (target, movement_layer) or build a
## new one. Built fields persist for _FLOW_FIELD_TTL seconds after their
## last use; building changes invalidate the entire cache.
func _get_flow_field(target: Vector2i, ml: int) -> FlowField:
	var key: String = _flow_key(target, ml)
	if _flow_field_cache.has(key):
		var entry: Dictionary = _flow_field_cache[key]
		entry["age"] = 0.0
		return entry["field"]
	var grid: AStarGrid2D = _astar_for_layer(ml)
	# FLYING doesn't need a flow field — fall back to direct pathing.
	if grid == null:
		return null
	var field := FlowField.new()
	field.build(target, grid, main.GRID_WIDTH, main.GRID_HEIGHT, float(main.GRID_SIZE), ml)
	_flow_field_cache[key] = {"field": field, "age": 0.0}
	return field


## Clear the flow-field cache. Called whenever a building is placed
## or destroyed because that change may have created or broken a route.
func _invalidate_flow_fields() -> void:
	_flow_field_cache.clear()


## Trace a flow-field path for one enemy toward a target cell. Falls
## back to the threaded A* path worker if the field can't be built
## (e.g. flying units).
func _assign_flow_path_to_enemy(enemy: Node2D, target_cell: Vector2i) -> void:
	var enemy_grid: Vector2i = main.world_to_grid(enemy.position)
	enemy_grid.x = clampi(enemy_grid.x, 0, main.GRID_WIDTH - 1)
	enemy_grid.y = clampi(enemy_grid.y, 0, main.GRID_HEIGHT - 1)
	var ml: int = enemy.data.movement_layer if enemy.data else 0
	# FLYING — straight-line direct path.
	if ml == 3:
		var half: Vector2 = Vector2(main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5)
		var direct := PackedVector2Array([
			Vector2(target_cell.x * main.GRID_SIZE, target_cell.y * main.GRID_SIZE) + half
		])
		enemy.set_path(direct, target_cell)
		return
	var field: FlowField = _get_flow_field(target_cell, ml)
	if field == null or not field.is_reachable(enemy_grid):
		# Field unusable from this start — back-fill with the threaded
		# A* worker so the unit still gets *some* path.
		if _path_worker != null:
			var bldg_id: int = _pack_grid_pos(target_cell)
			_path_worker.request_path(enemy.get_instance_id(), enemy_grid,
				target_cell, ml, bldg_id)
		else:
			enemy.set_path(PackedVector2Array(), null)
		return
	var path: PackedVector2Array = field.trace_path(enemy_grid)
	enemy.set_path(path, target_cell)


# =========================
# PRESSURE / RTSAI BASES
# =========================
# Implementations live further down. These tick stubs are called by
# `_tick_enemy_squads` every frame so the base / pressure systems keep
# pace with the squad logic.

func _tick_pressure(delta: float) -> void:
	_pressure_tick_timer -= delta
	if _pressure_tick_timer > 0.0:
		return
	_pressure_tick_timer = _PRESSURE_TICK_INTERVAL
	# Passive ramp: pressure always trickles up over time so a player who
	# turtles for an hour still eventually gets pushed on.
	ferox_pressure += _PRESSURE_PASSIVE_RAMP * _PRESSURE_TICK_INTERVAL
	# Player expansion contribution. We count LUMINA turrets / fabs
	# rather than DPS so the pressure curve doesn't double-count the
	# same effect already baked into `_assess_player_threat`.
	var turret_n: int = 0
	var fab_n: int = 0
	for gp in main.placed_buildings:
		if main.get_building_faction(gp) != main.Faction.LUMINA:
			continue
		var bdata = Registry.get_block(main.placed_buildings[gp])
		if bdata == null:
			continue
		var tags: PackedStringArray = bdata.tags
		if tags.has("turret"):
			turret_n += 1
		elif tags.has("fabricator") or tags.has("factory"):
			fab_n += 1
	ferox_pressure += turret_n * _PRESSURE_PER_TURRET * _PRESSURE_TICK_INTERVAL * 0.05
	ferox_pressure += fab_n * _PRESSURE_PER_FAB * _PRESSURE_TICK_INTERVAL * 0.05
	# Soft cap — above the cap, growth is halved (still grows, but slow).
	if ferox_pressure > _PRESSURE_SOFT_CAP:
		ferox_pressure = _PRESSURE_SOFT_CAP + (ferox_pressure - _PRESSURE_SOFT_CAP) * 0.5


## Multiplier applied to release thresholds, cooldowns, and target
## aggression. Pressure 0 → 1.0; pressure soft-cap → 1.6; bounded.
func _pressure_mult() -> float:
	return 1.0 + clampf(ferox_pressure / _PRESSURE_SOFT_CAP, 0.0, 1.5) * 0.6


func _tick_ferox_bases(delta: float) -> void:
	_base_tick_timer -= delta
	if _base_tick_timer > 0.0:
		# Even between full ticks, count down per-base cooldowns so the
		# attack timing stays smooth.
		for bid in ferox_bases:
			var b: Dictionary = ferox_bases[bid]
			b["next_attack_at"] = max(0.0, float(b.get("next_attack_at", 0.0)) - delta)
		return
	_base_tick_timer = _BASE_TICK_INTERVAL
	if _base_dirty:
		_rebuild_ferox_bases()
		_base_dirty = false
	# Per-base attack scheduler — see _maybe_launch_base_attack.
	for bid in ferox_bases:
		var b: Dictionary = ferox_bases[bid]
		b["next_attack_at"] = max(0.0, float(b.get("next_attack_at", 0.0)) - _BASE_TICK_INTERVAL)
		_maybe_launch_base_attack(bid)


## Rebuild the ferox_bases dictionary by clustering FEROX fabricators
## by proximity (transitive within _BASE_CLUSTER_RADIUS tiles).
func _rebuild_ferox_bases() -> void:
	var fabs: Array[Vector2i] = []
	for gp in main.placed_buildings:
		if main.get_building_faction(gp) != main.Faction.FEROX:
			continue
		var bdata = Registry.get_block(main.placed_buildings[gp])
		if bdata == null:
			continue
		var tags: PackedStringArray = bdata.tags
		if tags.has("fabricator") or tags.has("factory") or tags.has("core"):
			fabs.append(gp)

	# Union-find over fabs by proximity.
	var parent: Array[int] = []
	for i in range(fabs.size()):
		parent.append(i)
	var find = func(x):
		var v: int = x
		while parent[v] != v:
			parent[v] = parent[parent[v]]
			v = parent[v]
		return v
	var r2: int = _BASE_CLUSTER_RADIUS * _BASE_CLUSTER_RADIUS
	for i in range(fabs.size()):
		for j in range(i + 1, fabs.size()):
			var dx = fabs[i].x - fabs[j].x
			var dy = fabs[i].y - fabs[j].y
			if dx * dx + dy * dy <= r2:
				var ri: int = find.call(i)
				var rj: int = find.call(j)
				if ri != rj:
					parent[ri] = rj

	# Bucket fabs by root → new base entries. Preserve attack_target /
	# cooldowns from old entries with overlapping members so a re-cluster
	# from a single fab being added doesn't reset every base.
	var clusters: Dictionary = {}
	for i in range(fabs.size()):
		var r: int = find.call(i)
		if not clusters.has(r):
			clusters[r] = [] as Array[Vector2i]
		(clusters[r] as Array).append(fabs[i])

	var new_bases: Dictionary = {}
	for r in clusters:
		var members: Array = clusters[r]
		var cx: int = 0
		var cy: int = 0
		for m in members:
			cx += m.x
			cy += m.y
		cx /= members.size()
		cy /= members.size()
		var anchor: Vector2i = Vector2i(cx, cy)
		var key: String = "%d,%d" % [anchor.x, anchor.y]
		var prev: Dictionary = _find_overlapping_old_base(members)
		new_bases[key] = {
			"anchor": anchor,
			"members": members,
			"attack_target": prev.get("attack_target", null),
			"next_attack_at": float(prev.get("next_attack_at", _BASE_ATTACK_COOLDOWN)),
			"pressure_acc": float(prev.get("pressure_acc", 0.0)),
		}
	ferox_bases = new_bases


func _find_overlapping_old_base(members: Array) -> Dictionary:
	for k in ferox_bases:
		var b: Dictionary = ferox_bases[k]
		var existing: Array = b.get("members", [])
		for m in members:
			if existing.has(m):
				return b
	return {}


## Per-base attack scheduler. When cooldown elapses, the base picks a
## single high-value target and orders its squads to push together.
## A `_BASE_DEFENDER_RATIO` share of units stays at home as defenders
## (the existing squad rally point already keeps newly-built units near
## the fabricator, so "stay home" just means we don't release them).
func _maybe_launch_base_attack(base_key: String) -> void:
	var b: Dictionary = ferox_bases[base_key]
	if float(b.get("next_attack_at", 0.0)) > 0.0:
		return
	# Gather all currently-rallying units across this base's squads.
	var pool: Array[Node2D] = [] as Array[Node2D]
	for fab in b.get("members", []):
		if not enemy_squads.has(fab):
			continue
		for u in enemy_squads[fab].get("units", []):
			if u != null and is_instance_valid(u) and not u.is_dead:
				pool.append(u)
	if pool.is_empty():
		return
	# Need at least min_strength to bother attacking. Scales with pressure.
	var min_strength: int = int(ceil(_pressure_mult() * 2.0))
	if pool.size() < min_strength:
		return

	# Hold back defender ratio.
	var defenders_n: int = int(round(pool.size() * _BASE_DEFENDER_RATIO))
	var attackers: Array[Node2D] = [] as Array[Node2D]
	for i in range(pool.size()):
		if i < defenders_n:
			continue
		attackers.append(pool[i])
	if attackers.is_empty():
		return

	# Pick targets to spread across (deeper-into-base picks at higher
	# pressure).
	var origin: Vector2i = b["anchor"]
	var num_targets: int = clampi(int(round(_pressure_mult())), 1, 3)
	var targets: Array[Vector2i] = _pick_push_targets(origin, num_targets)
	if targets.is_empty():
		# No valid LUMINA target — reset cooldown and try again later.
		b["next_attack_at"] = _BASE_ATTACK_COOLDOWN
		return

	var ti: int = 0
	for unit in attackers:
		if "is_rallying" in unit:
			unit.is_rallying = false
		_assign_flow_path_to_enemy(unit, targets[ti % targets.size()])
		ti += 1
	# Pull the released units out of their squads so the next squad tick
	# doesn't re-rally them.
	for fab in b.get("members", []):
		if not enemy_squads.has(fab):
			continue
		var squad: Dictionary = enemy_squads[fab]
		var kept: Array[Node2D] = [] as Array[Node2D]
		for u in squad.get("units", []):
			if attackers.has(u):
				continue
			kept.append(u)
		squad["units"] = kept

	# Cooldown shrinks with pressure (more aggression → faster pushes).
	var pm: float = _pressure_mult()
	b["next_attack_at"] = _BASE_ATTACK_COOLDOWN / pm


func _assign_priority_path_to_enemy(enemy: Node2D) -> void:
	if _path_worker == null:
		return
	var enemy_grid: Vector2i = main.world_to_grid(enemy.position)
	enemy_grid.x = clampi(enemy_grid.x, 0, main.GRID_WIDTH - 1)
	enemy_grid.y = clampi(enemy_grid.y, 0, main.GRID_HEIGHT - 1)
	var target: Variant = _find_priority_building_target(enemy_grid, main.Faction.LUMINA)
	if target == null:
		target = _find_nearest_building(enemy_grid, main.Faction.LUMINA)
	if target == null:
		enemy.set_path(PackedVector2Array(), null)
		return
	# Try the flow-field cache first — if a field for this target already
	# exists (or building it is cheap enough), gradient-descent the path
	# directly. Falls back to threaded A* when the field rejects the
	# start cell (e.g. unreachable due to walls).
	_assign_flow_path_to_enemy(enemy, target as Vector2i)


func _tick_enemy_squads(delta: float) -> void:
	# Age out stale flow fields even when no squads are active so the
	# cache doesn't outlive its accuracy.
	_flow_field_age_timer += delta
	if _flow_field_age_timer >= 1.0:
		_flow_field_age_timer = 0.0
		var expired: Array = []
		for k in _flow_field_cache:
			var e: Dictionary = _flow_field_cache[k]
			e["age"] = float(e.get("age", 0.0)) + 1.0
			if e["age"] >= _FLOW_FIELD_TTL:
				expired.append(k)
		for k in expired:
			_flow_field_cache.erase(k)
	# Pressure & RtsAI base ticks always run, even when no squads are
	# active (so cluster bookkeeping stays current as buildings change).
	_tick_pressure(delta)
	_tick_ferox_bases(delta)
	if enemy_squads.is_empty():
		return
	# Throttled threat reassessment — scanning every frame is wasteful.
	_squad_scan_timer -= delta
	var threat: float = 0.0
	var did_scan: bool = false
	if _squad_scan_timer <= 0.0:
		_squad_scan_timer = _SQUAD_SCAN_INTERVAL
		threat = _assess_player_threat()
		did_scan = true

	# Walk every squad. Bookkeeping first (drop dead members), then
	# decision logic (refresh threshold, age timer, maybe release).
	var dead_keys: Array[Vector2i] = []
	for fab_anchor in enemy_squads.keys():
		var squad: Dictionary = enemy_squads[fab_anchor]
		# If the fabricator itself is gone, dump the squad's units into
		# the standard nearest-target flow and drop the bucket.
		if not main.placed_buildings.has(fab_anchor):
			for u in squad.get("units", []):
				if u != null and is_instance_valid(u) and not u.is_dead:
					if "is_rallying" in u:
						u.is_rallying = false
					_assign_priority_path_to_enemy(u)
			dead_keys.append(fab_anchor)
			continue
		# Prune dead / freed units.
		var alive: Array[Node2D] = [] as Array[Node2D]
		for u in squad.get("units", []):
			if u != null and is_instance_valid(u) and not u.is_dead:
				alive.append(u)
		squad["units"] = alive
		# Refresh release threshold whenever we just rescanned.
		if did_scan:
			squad["release_at"] = _compute_release_threshold(threat)
			squad["rally_pos"] = _compute_rally_point(fab_anchor)
		# Age the squad's "first member spawned" timer for the timeout.
		if not alive.is_empty():
			squad["first_spawn"] = float(squad.get("first_spawn", 0.0)) + delta
		else:
			squad["first_spawn"] = 0.0
		var release_at: int = int(squad.get("release_at", _SQUAD_MIN_SIZE))
		var ready_by_size: bool = alive.size() >= release_at
		var ready_by_time: bool = not alive.is_empty() and float(squad["first_spawn"]) >= _SQUAD_TIMEOUT_SECONDS
		if ready_by_size or ready_by_time:
			_release_squad(fab_anchor)
	for k in dead_keys:
		enemy_squads.erase(k)


func _find_adjacent_walkable_on_grid(grid_pos: Vector2i, grid: AStarGrid2D) -> Variant:
	var neighbors = [
		Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1),
	]
	for offset in neighbors:
		var neighbor = grid_pos + offset
		if main.is_within_bounds(neighbor) and not grid.is_point_solid(neighbor):
			return neighbor
	return null


## Legacy wrapper — uses the ground AStar grid.
func _find_adjacent_walkable(grid_pos: Vector2i) -> Variant:
	return _find_adjacent_walkable_on_grid(grid_pos, astar)


# =========================
# CLEANUP
# =========================

func on_enemy_died(enemy: Node2D) -> void:
	enemies.erase(enemy)
	main.stats_enemy_units_destroyed += 1
	# Notify sector script of FEROX unit death
	if enemy.team == UnitData.Team.ENEMY and enemy.data:
		var sector_script = _sector_script_ref()
		if sector_script:
			sector_script.on_ferox_unit_destroyed(enemy.data.id)


func on_player_unit_died(unit: Node2D) -> void:
	player_units.erase(unit)
	selected_units.erase(unit)
	main.stats_units_destroyed += 1


func request_new_path(enemy: Node2D) -> void:
	_assign_path_to_enemy(enemy)


## Request a threaded path to a specific world position (for player unit auto-combat).
## Results arrive next frame via _poll_path_results.
func request_path_to_position_async(unit: Node2D, world_pos: Vector2) -> void:
	request_path_to_position_async_with_target(unit, world_pos, null)


## Like request_path_to_position_async but preserves target_building through the request.
func request_path_to_position_async_with_target(unit: Node2D, world_pos: Vector2, target_bldg: Variant) -> void:
	if _path_worker == null:
		var saved_bldg = target_bldg
		assign_path_to_position(unit, world_pos)
		unit.target_building = saved_bldg
		return

	var ml: int = unit.data.movement_layer if unit.data else 0

	var unit_grid: Vector2i = main.world_to_grid(unit.position)
	unit_grid.x = clampi(unit_grid.x, 0, main.GRID_WIDTH - 1)
	unit_grid.y = clampi(unit_grid.y, 0, main.GRID_HEIGHT - 1)

	var target_grid: Vector2i = main.world_to_grid(world_pos)
	target_grid.x = clampi(target_grid.x, 0, main.GRID_WIDTH - 1)
	target_grid.y = clampi(target_grid.y, 0, main.GRID_HEIGHT - 1)

	var packed_bldg: int = 0
	if target_bldg != null and target_bldg is Vector2i:
		packed_bldg = _pack_grid_pos(target_bldg)

	_path_worker.request_path(
		unit.get_instance_id(),
		unit_grid,
		target_grid,
		ml,
		packed_bldg,
	)


func get_enemies_in_range(world_pos: Vector2, radius: float) -> Array[Node2D]:
	var result: Array[Node2D] = []
	for enemy in enemies:
		if is_instance_valid(enemy) and not enemy.is_dead:
			if enemy.position.distance_to(world_pos) <= radius:
				result.append(enemy)
	return result


func get_player_units_in_range(world_pos: Vector2, radius: float) -> Array[Node2D]:
	var result: Array[Node2D] = []
	for unit in player_units:
		if is_instance_valid(unit) and not unit.is_dead:
			if unit.position.distance_to(world_pos) <= radius:
				result.append(unit)
	return result


## Pathfind a unit to a specific world position (not to a building).
func assign_path_to_position(unit: Node2D, world_pos: Vector2) -> void:
	# FLYING: direct movement, no AStar needed
	if unit.data and unit.data.movement_layer == UnitData.MovementLayer.FLYING:
		var world_path := PackedVector2Array([world_pos])
		unit.set_path(world_path, null)
		return

	# Select grid based on movement layer
	var grid: AStarGrid2D = _get_grid_for_unit(unit)

	var unit_grid: Vector2i = main.world_to_grid(unit.position)
	unit_grid.x = clampi(unit_grid.x, 0, main.GRID_WIDTH - 1)
	unit_grid.y = clampi(unit_grid.y, 0, main.GRID_HEIGHT - 1)

	var target_grid: Vector2i = main.world_to_grid(world_pos)
	target_grid.x = clampi(target_grid.x, 0, main.GRID_WIDTH - 1)
	target_grid.y = clampi(target_grid.y, 0, main.GRID_HEIGHT - 1)

	# If target cell is solid, find nearest walkable
	if grid.is_point_solid(target_grid):
		var nearby: Variant = _find_adjacent_walkable_on_grid(target_grid, grid)
		if nearby != null:
			target_grid = nearby
		else:
			unit.set_path(PackedVector2Array(), null)
			return

	# If unit is on a solid cell, find nearby open
	if grid.is_point_solid(unit_grid):
		var nearby: Variant = _find_adjacent_walkable_on_grid(unit_grid, grid)
		if nearby != null:
			unit_grid = nearby
		else:
			return

	var id_path := grid.get_point_path(unit_grid, target_grid)
	if id_path.size() > 0:
		var world_path := PackedVector2Array()
		for point in id_path:
			world_path.append(point + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0))
		# Smooth the path — skip waypoints that have line-of-sight to a later one.
		world_path = _smooth_path(world_path, grid)
		unit.set_path(world_path, null)
	else:
		unit.set_path(PackedVector2Array(), null)


## Path smoothing via straight-line visibility. Walks the path and, from each
## waypoint, looks ahead for the furthest waypoint that has clear line-of-sight
## (no solid cell on the segment between them). Returns a compacted path with
## fewer zigzags. This is purely visual/quality-of-life — it doesn't change
## how A* computes the path, just removes redundant intermediate points.
func _smooth_path(path: PackedVector2Array, grid: AStarGrid2D) -> PackedVector2Array:
	if path.size() <= 2:
		return path
	var smoothed := PackedVector2Array()
	smoothed.append(path[0])
	var i := 0
	while i < path.size() - 1:
		# Find the furthest j from i that still has clear LOS from path[i].
		var j := path.size() - 1
		while j > i + 1:
			if _has_line_of_sight(path[i], path[j], grid):
				break
			j -= 1
		smoothed.append(path[j])
		i = j
	return smoothed


## Grid-based line-of-sight check (Bresenham-ish): walks the grid cells under
## the segment from a to b and returns false if any of them is solid.
func _has_line_of_sight(a: Vector2, b: Vector2, grid: AStarGrid2D) -> bool:
	var gs: float = main.GRID_SIZE
	var ax: int = int(a.x / gs)
	var ay: int = int(a.y / gs)
	var bx: int = int(b.x / gs)
	var by: int = int(b.y / gs)
	var dx: int = absi(bx - ax)
	var dy: int = absi(by - ay)
	var sx: int = 1 if ax < bx else -1
	var sy: int = 1 if ay < by else -1
	var err: int = dx - dy
	var x: int = ax
	var y: int = ay
	while true:
		var p := Vector2i(x, y)
		if p.x >= 0 and p.x < main.GRID_WIDTH and p.y >= 0 and p.y < main.GRID_HEIGHT:
			if grid.is_point_solid(p):
				return false
		if x == bx and y == by:
			break
		var e2: int = err * 2
		if e2 > -dy:
			err -= dy
			x += sx
		if e2 < dx:
			err += dx
			y += sy
	return true


# =========================
# UNIT COLLISION
# =========================

func _resolve_unit_collisions(delta: float) -> void:
	# Group units by movement layer — only same-layer units push apart
	var layer_units: Dictionary = {}  # int -> Array of Node2D
	for u in enemies:
		if is_instance_valid(u) and not u.is_dead:
			var layer: int = u.data.movement_layer if u.data else 0
			if not layer_units.has(layer):
				layer_units[layer] = []
			layer_units[layer].append(u)
	for u in player_units:
		if is_instance_valid(u) and not u.is_dead:
			var layer: int = u.data.movement_layer if u.data else 0
			if not layer_units.has(layer):
				layer_units[layer] = []
			layer_units[layer].append(u)

	var map_w: float = main.GRID_SIZE * main.GRID_WIDTH
	var map_h: float = main.GRID_SIZE * main.GRID_HEIGHT

	# Resolve collisions within each layer independently
	for layer in layer_units:
		var units_in_layer: Array = layer_units[layer]
		var count := units_in_layer.size()
		if count < 2:
			continue

		var offsets: Array[Vector2] = []
		offsets.resize(count)
		for i in range(count):
			offsets[i] = Vector2.ZERO

		for i in range(count):
			var a: Node2D = units_in_layer[i]
			# Use 60% of visual size for collision so units don't lock as easily
			var radius_a: float = a.unit_size
			var a_moving: bool = a.path.size() > 0 and a.path_index < a.path.size()
			for j in range(i + 1, count):
				var b: Node2D = units_in_layer[j]
				var radius_b: float = b.unit_size * 0.6
				var b_moving: bool = b.path.size() > 0 and b.path_index < b.path.size()
				var min_dist := radius_a + radius_b
				var diff := a.position - b.position
				var dist := diff.length()

				if dist < min_dist:
					var push_dir: Vector2
					if dist < MIN_SEPARATION_DIST:
						# Nearly perfectly stacked — random nudge direction
						var angle := randf() * TAU
						push_dir = Vector2(cos(angle), sin(angle))
					else:
						push_dir = diff / dist

					var overlap := min_dist - dist

					# Deep overlap (> 70% inside each other): hard snap apart
					# so units can never get permanently stuck inside each other.
					if dist < min_dist * 0.3:
						var snap := push_dir * (overlap * 0.5 + 1.0)
						offsets[i] += snap * 0.5
						offsets[j] -= snap * 0.5
						continue

					var push := push_dir * overlap * SEPARATION_STRENGTH * delta

					# Asymmetric push: moving units shove idle units out of the
					# way; two moving units slip past each other easily.
					var a_share: float
					var b_share: float
					if a_moving and not b_moving:
						# A is moving, B is idle → A barely deflected, B shoved aside
						a_share = 0.05
						b_share = 0.95
					elif b_moving and not a_moving:
						# B is moving, A is idle → B barely deflected, A shoved aside
						a_share = 0.95
						b_share = 0.05
					elif a_moving and b_moving:
						# Both moving → weak push so they slip past each other
						push *= 0.15
						a_share = 0.5
						b_share = 0.5
					else:
						# Both idle → normal symmetric push
						a_share = 0.5
						b_share = 0.5

					offsets[i] += push * a_share
					offsets[j] -= push * b_share

		for i in range(count):
			if offsets[i] != Vector2.ZERO:
				units_in_layer[i].position += offsets[i]
				units_in_layer[i].position.x = clampf(units_in_layer[i].position.x, 0.0, map_w)
				units_in_layer[i].position.y = clampf(units_in_layer[i].position.y, 0.0, map_h)


# =========================
# MOVEMENT LAYER HELPERS
# =========================

## Returns true if the building at grid_pos is passable for GROUND units
## (transport buildings: conveyors, pipes, bridges, junctions, sorters, etc.)
func _is_ground_passable_building(grid_pos: Vector2i) -> bool:
	var block_id = main.placed_buildings.get(grid_pos, &"")
	if block_id == &"":
		return false
	var data = Registry.get_block(block_id)
	if data == null:
		return false
	# Transport buildings are passable (conveyors, pipes, bridges, junctions, sorters, etc.)
	# Platforms are also passable — they're the primary way for ground units
	# to cross water bodies. The per-platform "one unit at a time" gate is
	# enforced separately via _water_platform_reservation.
	if data.transport_speed > 0 or data.transports_fluid:
		return true
	if data.tags.has("platform"):
		return true
	return false


## A* weight-scale used to bias the pathfinder away from a water cell.
## Shallow (depth=1) reads as sand-through-the-surface and is walked
## like dry land. Medium (2) and deep (3) get progressively harsher
## penalties so a 6- or 8-tile detour around the lake "wins" over
## wading straight through — but the unit CAN still cross if there
## isn't a dry route, or if the player orders it in.
## A* weight-scale for water cells. Tuned so the platform / dry-land
## detour wins against a direct swim by a wide margin — even a ~20-tile
## detour around the lake beats a 1-tile deep-water dive.
##
## Depth 1 (shallow / sand-through-the-surface) stays cheap; ground
## units wade through it freely. Depth 2+ snaps the cost up sharply so
## the pathfinder almost always routes around or onto any platform the
## player has laid down.
##
## Old values (depth 2 = 8, depth 3+ = 16) let a 9-tile straight dive
## win against a 10-tile platform detour, so units would clump in the
## water when a clear plank route was right next to them.
func _water_cell_weight(grid_pos: Vector2i) -> float:
	var terrain = _terrain_ref()
	if terrain == null:
		return 1.0
	var depth: int = terrain.get_water_depth_at(grid_pos)
	match depth:
		0: return 1.0
		1: return 2.0    # shallow wading — mild bias toward dry/platform
		2: return 30.0   # medium water — strongly prefer detour up to ~30 tiles
		_: return 60.0   # deep water — almost any dry route beats this


## True if a water (liquid) floor tile sits at `grid_pos`. Used by ground
## pathfinding to bias water cells (so units route around) unless a
## building covers the cell (platform / floating transport).
func _is_water_floor(grid_pos: Vector2i) -> bool:
	var terrain = _terrain_ref()
	if terrain == null:
		return false
	if not terrain.floor_tiles.has(grid_pos):
		return false
	var td: TerrainTileData = Registry.get_tile(terrain.floor_tiles[grid_pos])
	if td == null:
		return false
	return td.is_liquid and td.tags.has("water")


## True if a "platform" building (tag = "platform") sits at `grid_pos`.
## Walking onto a platform cell that's over water is gated through the
## reservation system so only one ground unit crosses each cell at a time.
func _is_platform_cell(grid_pos: Vector2i) -> bool:
	var block_id = main.placed_buildings.get(grid_pos, &"")
	if block_id == &"":
		return false
	var data = Registry.get_block(block_id)
	if data == null:
		return false
	return data.tags.has("platform")


## Returns true if the building at grid_pos is a wall (category WALLS).
func _is_building_wall(grid_pos: Vector2i) -> bool:
	var block_id = main.placed_buildings.get(grid_pos, &"")
	if block_id == &"":
		return false
	var data = Registry.get_block(block_id)
	if data == null:
		return false
	return data.category == BlockData.BlockCategory.WALLS


## Returns the appropriate AStar grid for a unit's movement layer.
func _get_grid_for_unit(unit: Node2D) -> AStarGrid2D:
	if unit.data == null:
		return astar
	match unit.data.movement_layer:
		UnitData.MovementLayer.CRAWLER:
			return astar_crawler
		UnitData.MovementLayer.HOVER:
			return astar_hover
		_:
			return astar


# =========================
# CRAWLER / HOVER WALL ANALYSIS
# =========================

## Recomputes which terrain wall cells are passable for crawlers and hover units.
## BFS flood-fill finds contiguous terrain wall segments.
## Crawlers: segments < 4 cells are passable. Hover: segments <= 8 cells are passable.
## Note: Building blocks never block crawlers — only terrain walls >= 4 cells do.
func _recompute_crawler_wall_passability() -> void:
	# Step 1: Collect terrain wall positions that block pathfinding
	var all_wall_positions: Dictionary = {}

	var terrain_sys = _terrain_ref()
	if terrain_sys:
		for grid_pos in terrain_sys.wall_tiles:
			var tile_data = Registry.get_tile(terrain_sys.wall_tiles[grid_pos])
			if tile_data and tile_data.blocks_pathfinding:
				all_wall_positions[grid_pos] = true

	# Step 2: BFS to find contiguous wall segments
	var visited: Dictionary = {}
	var segments: Array = []  # Array of Array[Vector2i]

	for wall_pos in all_wall_positions:
		if visited.has(wall_pos):
			continue
		var segment: Array[Vector2i] = []
		var queue: Array[Vector2i] = [wall_pos]
		visited[wall_pos] = true
		while queue.size() > 0:
			var current: Vector2i = queue.pop_front()
			segment.append(current)
			for offset in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
				var neighbor: Vector2i = current + offset
				if all_wall_positions.has(neighbor) and not visited.has(neighbor):
					visited[neighbor] = true
					queue.append(neighbor)
		segments.append(segment)

	# Step 3: Update astar_crawler and astar_hover based on segment sizes
	_crawler_passable_walls.clear()
	_hover_passable_walls.clear()

	# Reset all wall positions to solid in crawler and hover grids
	for wall_pos in all_wall_positions:
		astar_crawler.set_point_solid(wall_pos, true)
		if astar_hover:
			astar_hover.set_point_solid(wall_pos, true)

	for segment in segments:
		var seg_size: int = segment.size()
		# Crawlers: segments < 4 cells are passable
		if seg_size < 4:
			for wall_pos in segment:
				astar_crawler.set_point_solid(wall_pos, false)
				_crawler_passable_walls[wall_pos] = true
		# Hover: segments <= 8 cells are passable
		if seg_size <= 8 and astar_hover:
			for wall_pos in segment:
				astar_hover.set_point_solid(wall_pos, false)
				_hover_passable_walls[wall_pos] = true

	# Sync worker thread grids — full rebuild for crawler + hover walls
	if _path_worker:
		var ground_solids: Array[Vector2i] = []
		for grid_pos in main.placed_buildings:
			if not _is_ground_passable_building(grid_pos):
				ground_solids.append(grid_pos)
		for wall_pos in all_wall_positions:
			if not ground_solids.has(wall_pos):
				ground_solids.append(wall_pos)

		var crawler_solids: Array[Vector2i] = []
		for grid_pos in main.placed_buildings:
			if _is_building_wall(grid_pos):
				crawler_solids.append(grid_pos)
		for wall_pos in all_wall_positions:
			if not _crawler_passable_walls.has(wall_pos):
				crawler_solids.append(wall_pos)

		var hover_solids: Array[Vector2i] = []
		for wall_pos in all_wall_positions:
			if not _hover_passable_walls.has(wall_pos):
				hover_solids.append(wall_pos)

		_path_worker.queue_rebuild(ground_solids, crawler_solids, hover_solids)


# =========================
# DRAWING (selection box)
# =========================

func _draw() -> void:
	# Box-select rectangle — only in unit mode
	if unit_mode_active and _box_selecting:
		var rect := Rect2(
			Vector2(min(_box_start.x, _box_end.x), min(_box_start.y, _box_end.y)),
			Vector2(abs(_box_end.x - _box_start.x), abs(_box_end.y - _box_start.y))
		)
		draw_rect(rect, Color(1.0, 0.84, 0.0, 0.12), true)
		draw_rect(rect, Color(1.0, 0.84, 0.0, 0.6), false, 1.5)

	# Ctrl-hover highlight is rendered on the dedicated `_ctrl_hover_overlay`
	# child (z=4099) — drawing it here, at the UnitManager's default
	# z=0, leaves the yellow tint buried under units / turret heads.

	# Draw move-target diamonds and path lines for selected units — unit mode only
	if unit_mode_active:
		_draw_move_targets()


## Draw callback for the dedicated Ctrl-hover overlay (z=4099). Renders
## a translucent yellow tint covering the hovered LUMINA turret / unit /
## crane plus four arrowheads orbiting it CCW. Turret coverage is a
## rect padded outward by 1 tile in every direction so the tint includes
## the turret's heads (multi-barrel layouts have heads sticking past
## the base footprint). Units use a circle scaled to their unit_size.
func _draw_ctrl_hover_on_overlay() -> void:
	if main == null or main.is_ui_blocking():
		return
	if not (Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)):
		return
	var mouse_world: Vector2 = get_global_mouse_position()
	# Allied unit takes priority over a building underneath it.
	var hovered_unit := _get_player_unit_at(mouse_world)
	if hovered_unit and is_instance_valid(hovered_unit) and not hovered_unit.is_dead:
		var u_radius: float = float(hovered_unit.unit_size) if "unit_size" in hovered_unit else 18.0
		_paint_ctrl_hover_circle(hovered_unit.position, u_radius)
		return
	var grid_pos: Vector2i = main.world_to_grid(mouse_world)
	if not main.placed_buildings.has(grid_pos):
		return
	var block_id: StringName = main.placed_buildings[grid_pos]
	var bdata = Registry.get_block(block_id)
	if bdata == null:
		return
	if not (bdata.is_turret() or bdata.tags.has("crane")):
		return
	if main.get_building_faction(grid_pos) != main.Faction.LUMINA:
		return
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var adata = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if adata == null:
		return
	var gs: float = float(main.GRID_SIZE)
	var size_x: float = float(maxi(adata.grid_size.x, 1)) * gs
	var size_y: float = float(maxi(adata.grid_size.y, 1)) * gs
	var base_pos: Vector2 = main.grid_to_world(anchor)
	# Pad the rect by one tile in each direction so the yellow tint
	# fully covers protruding heads on multi-barrel turrets. Cranes
	# get the same treatment so the grabber arm sits inside the tint.
	var pad: float = gs * 1.0
	var rect_pos: Vector2 = base_pos - Vector2(pad, pad)
	var rect_size: Vector2 = Vector2(size_x + pad * 2.0, size_y + pad * 2.0)
	_paint_ctrl_hover_rect(rect_pos, rect_size)


func _paint_ctrl_hover_circle(center: Vector2, radius: float) -> void:
	if _ctrl_hover_overlay == null:
		return
	var fill_color := Color(1.0, 0.85, 0.2, 0.55)
	_ctrl_hover_overlay.draw_circle(center, radius, fill_color)
	_paint_ctrl_hover_arrows(center, radius)


func _paint_ctrl_hover_rect(top_left: Vector2, size: Vector2) -> void:
	if _ctrl_hover_overlay == null:
		return
	var fill_color := Color(1.0, 0.85, 0.2, 0.55)
	_ctrl_hover_overlay.draw_rect(Rect2(top_left, size), fill_color, true)
	var center: Vector2 = top_left + size * 0.5
	# Arrow orbit radius scales with the rect's larger half-axis so the
	# four arrows always sit just outside the tinted region.
	var orbit_r: float = maxf(size.x, size.y) * 0.5 + 6.0
	_paint_ctrl_hover_arrows(center, orbit_r - 8.0)


func _paint_ctrl_hover_arrows(center: Vector2, target_radius: float) -> void:
	if _ctrl_hover_overlay == null:
		return
	var orbit_r: float = target_radius + 14.0
	var arrow_len: float = 12.0
	var arrow_half: float = 7.0
	var arrow_color := Color(1.0, 0.92, 0.25, 1.0)
	for i in range(4):
		var angle: float = -_ctrl_hover_phase + float(i) * TAU * 0.25
		var tip: Vector2 = center + Vector2.from_angle(angle) * orbit_r
		var inward: Vector2 = (center - tip).normalized()
		var perp: Vector2 = Vector2(-inward.y, inward.x)
		var back: Vector2 = tip - inward * arrow_len
		var p_left: Vector2 = back + perp * arrow_half
		var p_right: Vector2 = back - perp * arrow_half
		_ctrl_hover_overlay.draw_colored_polygon(
			PackedVector2Array([tip, p_left, p_right]), arrow_color)


## Draws a small diamond at each selected unit's move target and a line from
## the unit to the diamond, using the same gold color as the selection ring.
## Paints a single command indicator at the player's click point — one
## diamond for a move order or the TargetMouse.png crosshair for an
## attack-building order — with lines from every selected unit that's
## still pursuing the command. Drawing only ONE marker (rather than
## one per unit at each formation slot) matches the player's mental
## model: "I clicked here, send everyone over."
func _draw_move_targets() -> void:
	const LINE_COLOR := Color(1.0, 0.84, 0.0, 0.45)
	const ATTACK_LINE_COLOR := Color(1.0, 0.3, 0.25, 0.55)
	const DIAMOND_COLOR := Color(1.0, 0.84, 0.0, 0.8)
	const DIAMOND_OUTLINE := Color(1.0, 0.84, 0.0, 1.0)
	const DIAMOND_SIZE := 6.0
	const ATTACK_ICON_SIZE := 24.0

	# --- Attack-building indicator (TargetMouse.png + lines) -----------
	if _attack_command_anchor != Vector2i(-9999, -9999) \
			and main.placed_buildings.has(_attack_command_anchor):
		var bdata = Registry.get_block(main.placed_buildings[_attack_command_anchor])
		if bdata != null:
			var gs: float = float(main.GRID_SIZE)
			var center: Vector2 = main.grid_to_world(_attack_command_anchor) + Vector2(
				bdata.grid_size.x * gs * 0.5,
				bdata.grid_size.y * gs * 0.5,
			)
			var any_pursuing: bool = false
			for unit in selected_units:
				if not is_instance_valid(unit) or unit.is_dead:
					continue
				if "manual_target_building" in unit \
						and unit.manual_target_building == _attack_command_anchor:
					draw_line(unit.position, center, ATTACK_LINE_COLOR, 1.5)
					any_pursuing = true
			if any_pursuing:
				if _target_icon_tex:
					var rect := Rect2(
						center - Vector2(ATTACK_ICON_SIZE, ATTACK_ICON_SIZE),
						Vector2(ATTACK_ICON_SIZE * 2.0, ATTACK_ICON_SIZE * 2.0),
					)
					draw_texture_rect(_target_icon_tex, rect, false)
				else:
					# Fallback if the texture didn't load — a red diamond.
					var d := DIAMOND_SIZE
					var pts := PackedVector2Array([
						center + Vector2(0, -d), center + Vector2(d, 0),
						center + Vector2(0, d), center + Vector2(-d, 0),
					])
					draw_colored_polygon(pts, Color(1.0, 0.25, 0.25, 0.85))
			else:
				_attack_command_anchor = Vector2i(-9999, -9999)
		else:
			_attack_command_anchor = Vector2i(-9999, -9999)
	elif _attack_command_anchor != Vector2i(-9999, -9999):
		# Target building destroyed — drop the indicator.
		_attack_command_anchor = Vector2i(-9999, -9999)

	# --- Move-command indicator (one diamond + lines from each unit) ---
	if _move_command_point != Vector2.INF:
		var any_moving: bool = false
		for unit in selected_units:
			if not is_instance_valid(unit) or unit.is_dead:
				continue
			if unit.move_target == null:
				continue
			draw_line(unit.position, _move_command_point, LINE_COLOR, 1.0)
			any_moving = true
		if any_moving:
			var d := DIAMOND_SIZE
			var diamond := PackedVector2Array([
				_move_command_point + Vector2(0, -d),
				_move_command_point + Vector2(d, 0),
				_move_command_point + Vector2(0, d),
				_move_command_point + Vector2(-d, 0),
			])
			draw_colored_polygon(diamond, DIAMOND_COLOR)
			draw_polyline(
				PackedVector2Array([
					_move_command_point + Vector2(0, -d),
					_move_command_point + Vector2(d, 0),
					_move_command_point + Vector2(0, d),
					_move_command_point + Vector2(-d, 0),
					_move_command_point + Vector2(0, -d),
				]),
				DIAMOND_OUTLINE, 1.5
			)
		else:
			_move_command_point = Vector2.INF
