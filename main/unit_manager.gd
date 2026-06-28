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
var astar_hover: AStarGrid2D        # HOVER layer pathfinding (blocked by buildings + terrain walls)
var astar_naval: AStarGrid2D        # NAVAL layer pathfinding (ONLY navigable water is non-solid)
var _crawler_passable_walls: Dictionary = {}  # Vector2i -> true (wall groups <= 8 thick)
var _hover_passable_walls: Dictionary = {}    # Deprecated compatibility stub; hover no longer crosses terrain walls.
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
## When true (default), ALL enemy pathing routes through the shared, cached
## FlowField (Mindustry-style) instead of per-unit threaded A*. One field per
## target cell is reused by every enemy heading there and across frames, which
## scales far better than one A* request per unit. Set false to revert to pure
## per-unit A* (the threaded worker is still the fallback when a field can't
## reach a unit's start).
var flow_field_pathing: bool = true
## Keys (target+layer) with an in-flight worker build, so we request each once.
var _flow_pending: Dictionary = {}
## Bumped on every flow-field invalidation; results tagged with an older
## generation are dropped (they were built against a since-changed grid).
var _flow_generation: int = 0
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
## Manager-wide de-stack pass. Individual moving units also apply a local
## separation step, but idle/controlled/special-path units can miss that path;
## this keeps every same-layer unit from remaining overlapped.
const ENABLE_GLOBAL_UNIT_COLLISION_RESOLVE := true
## Minimum distance to avoid division-by-zero; units closer than this get a random nudge
const MIN_SEPARATION_DIST := 0.5

# --- Unit spatial hash (perf) ---
# Both `_resolve_unit_collisions` (here) and `enemy_unit._apply_separation`
# used to scan EVERY same-layer unit per unit — O(n²) every frame, the main
# large-battle cost. This is a uniform-grid spatial hash: units are bucketed
# by (movement_layer, cellX, cellY) once per frame, and a neighbour query
# returns only the units in the 3×3 block of cells around a position. Since
# all separation/collision radii are a small multiple of a tile, a unit only
# ever interacts with units in adjacent cells, so the 3×3 query returns a
# superset of every unit the old full scan would have considered — identical
# results, O(n) instead of O(n²).
#
# `_spatial_cell` is sized to comfortably exceed the largest interaction
# radius (collision min_dist and separation sep_radius are both ~2× a unit's
# size). Rebuilt lazily via `_ensure_spatial_hash()`, frame-stamped on
# Engine.get_process_frames() so it's correct regardless of which node
# (UnitManager vs an individual unit) touches it first this frame.
var _spatial_hash: Dictionary = {}     # Vector3i(layer, cx, cy) -> Array[Node2D]
var _spatial_hash_frame: int = -1
var _spatial_cell_size: float = 0.0    # px; derived from GRID_SIZE on first build

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
	_target_icon_tex = load("res://textures/cursors/Target.png") as Texture2D
	main.building_placed.connect(_on_building_placed)
	call_deferred("_spawn_test_nests")

	# Ctrl-hover overlay: dedicated child so the yellow tint sits above
	# unit / turret-head canvases (z=4099). z_as_relative=false locks
	# the absolute z so it survives even if UnitManager's z changes.
	_ctrl_hover_overlay = Node2D.new()
	_ctrl_hover_overlay.name = "CtrlHoverOverlay"
	_ctrl_hover_overlay.z_index = 4096
	_ctrl_hover_overlay.z_as_relative = false
	_ctrl_hover_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_ctrl_hover_overlay)
	_ctrl_hover_overlay.draw.connect(_draw_ctrl_hover_on_overlay)
	# Build the silhouette shader once. Replaces a sprite's RGB with the
	# overlay color while preserving its alpha — same trick Mindustry
	# uses for the "controlling this unit" outline.
	var sil_shader := Shader.new()
	sil_shader.code = """
shader_type canvas_item;
uniform vec4 silhouette_color : source_color = vec4(1.0, 0.85, 0.2, 1.0);
void fragment() {
	vec4 t = texture(TEXTURE, UV);
	COLOR = vec4(silhouette_color.rgb, t.a * silhouette_color.a);
}
"""
	_silhouette_material = ShaderMaterial.new()
	_silhouette_material.shader = sil_shader
	_silhouette_material.set_shader_parameter("silhouette_color", Color(1.0, 0.85, 0.2, 1.0))
	# Sub-canvas dedicated to silhouette sprite draws (so the shader
	# only applies to those, not to the arrows / block rects).
	_ctrl_hover_silhouette = Node2D.new()
	_ctrl_hover_silhouette.name = "Silhouette"
	_ctrl_hover_silhouette.material = _silhouette_material
	_ctrl_hover_overlay.add_child(_ctrl_hover_silhouette)
	_ctrl_hover_silhouette.draw.connect(_draw_ctrl_hover_silhouette)
	# Godot caps z_index at 4096, and BuildingSystem's crane / popup
	# overlays are already at that cap. Reparent to Main as the LAST
	# child so the tree-order tiebreak puts us on top of them.
	call_deferred("_reparent_ctrl_overlay_to_top")


func _reparent_ctrl_overlay_to_top() -> void:
	if _ctrl_hover_overlay == null or main == null:
		return
	if _ctrl_hover_overlay.get_parent() != main:
		_ctrl_hover_overlay.get_parent().remove_child(_ctrl_hover_overlay)
		main.add_child(_ctrl_hover_overlay)
	main.move_child(_ctrl_hover_overlay, main.get_child_count() - 1)


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
# Sub-canvas under `_ctrl_hover_overlay` whose material is the
# silhouette shader — sprites drawn here come out as solid-color
# alpha-masked silhouettes instead of tinted multiplications.
var _ctrl_hover_silhouette: Node2D = null
var _silhouette_material: ShaderMaterial = null
# Set by `_paint_ctrl_overlay_for_unit` and consumed by the deferred
# `_draw_ctrl_hover_silhouette` callback. Cleared each frame.
var _silhouette_targets: Array = []
const _CONTROL_SELECT_EFFECT_DURATION: float = 0.5
var _control_select_effects: Array = []

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
	_tick_control_select_effects(delta)
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
	_update_controlled_entity(delta)
	if ENABLE_GLOBAL_UNIT_COLLISION_RESOLVE:
		_resolve_unit_collisions(delta)
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
		var grid_pos: Vector2i = main.world_to_grid(mouse_world)
		# --- LUMINA core: spawn / take control of its associated core
		# unit. Runs BEFORE the unit / turret / crane checks so an
		# unowned-but-clickable cell on a core's footprint reads as
		# "go to this core's unit" instead of "release control".
		if main.placed_buildings.has(grid_pos):
			var core_bid: StringName = main.placed_buildings[grid_pos]
			var core_d: BlockData = Registry.get_block(core_bid)
			var core_anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
			if core_d and core_d.tags.has("core") \
					and main.has_method("is_lumina_core_anchor") \
					and main.is_lumina_core_anchor(core_anchor):
				# If currently driving a unit/turret/crane, hand control back to
				# the drone FIRST — otherwise `respawn_at_core` would teleport
				# the (hidden) drone to the core while the player stayed locked
				# to the controlled entity, so nothing appeared to happen.
				if controlled_entity != null:
					_release_control()
				var drone = main.get_node_or_null("PlayerDrone")
				if drone and drone.has_method("respawn_at_core"):
					drone.respawn_at_core(core_anchor)
				get_viewport().set_input_as_handled()
				return
		# Check for player unit at click position
		var clicked_unit := _get_player_unit_at(mouse_world)
		if clicked_unit:
			_take_control_of_unit(clicked_unit)
			get_viewport().set_input_as_handled()
			return
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
		# Ctrl+clicked empty ground. Previously released control + respawned
		# the drone at the click point — that read as "you got teleported
		# for misclicking" any time the player meant to control something
		# but missed. Now it's a no-op while controlling (R still releases
		# cleanly), and a no-op when not controlling.
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
			if main.selected_building == &"":
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
	# Player units, plus dummy test enemies (selectable for testing).
	var pools: Array = [player_units, enemies]
	for pool in pools:
		for unit in pool:
			if not is_instance_valid(unit) or unit.is_dead:
				continue
			# From the enemies pool, only dummy units are selectable.
			if pool == enemies and not ("is_dummy" in unit and unit.is_dummy):
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
	# Select units inside the box (player units + dummy test enemies).
	for unit in player_units:
		if not is_instance_valid(unit) or unit.is_dead:
			continue
		if rect.has_point(unit.position):
			unit.is_selected = true
			selected_units.append(unit)
	for unit in enemies:
		if not is_instance_valid(unit) or unit.is_dead:
			continue
		if not ("is_dummy" in unit and unit.is_dummy):
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
		if _is_controlled_unit_node(unit):
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
		if _is_controlled_unit_node(unit):
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
		if _is_controlled_unit_node(unit):
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


## Sets the attack command on every selected dummy unit. `mode` is
## "attack_block" or "attack_player" (see enemy_unit._dummy_update).
func command_dummy_attack(mode: String) -> void:
	for u in selected_units:
		if is_instance_valid(u) and "is_dummy" in u and u.is_dummy:
			u.dummy_mode = mode
			u.target_building = null
			u.move_target = null
			u.path = PackedVector2Array()
			u.path_index = 0


## True if any currently-selected unit is a dummy test enemy.
func has_selected_dummy() -> bool:
	for u in selected_units:
		if is_instance_valid(u) and "is_dummy" in u and u.is_dummy:
			return true
	return false


func _command_move(world_pos: Vector2) -> void:
	# Gather living selected units (skip the controlled unit — it uses WASD)
	var living: Array[Node2D] = []
	for unit in selected_units:
		if is_instance_valid(unit) and not unit.is_dead:
			if _is_controlled_unit_node(unit):
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

	# Stamp the single command anchor for the indicator: one dot at the player's
	# actual click point with lines back to each unit.
	_move_command_point = world_pos
	_attack_command_anchor = Vector2i(-9999, -9999)

	# Every selected unit heads to the EXACT click point (Mindustry-style) — no
	# pre-assigned formation slots. They converge on the target and the
	# continuous separation force fans them out naturally around it, so they
	# cluster on where you told them to go instead of spacing into a ring.
	for unit in living:
		unit.move_to_position(world_pos)


func _deselect_all() -> void:
	for unit in selected_units:
		if is_instance_valid(unit):
			unit.is_selected = false
	selected_units.clear()


# =========================
# DIRECT CONTROL (Ctrl+click)
# =========================

## Ctrl+click on a LUMINA core. Resolves the core's "core unit"
## (BlockData.spawned_unit, falling back to produced_unit). If a
## friendly instance of that unit is already alive within roughly
## one core footprint of the anchor, we take control of THAT one
## (so repeated ctrl+clicks don't pile up duplicates). Otherwise we
## spawn a fresh instance at the core's centre and control it.
func _take_control_of_core_unit(core_cell: Vector2i, core_data: BlockData, unit_id: StringName) -> void:
	if core_data == null or unit_id == &"":
		return
	var anchor: Vector2i = main.building_origins.get(core_cell, core_cell)
	var gs: float = float(main.GRID_SIZE)
	var sz: Vector2i = core_data.grid_size
	var center: Vector2 = main.grid_to_world(anchor) + Vector2(
		float(sz.x) * gs * 0.5,
		float(sz.y) * gs * 0.5,
	)
	# Look for an existing alive PLAYER unit of the requested type near
	# the core. If we find one we control IT instead of spawning a new
	# copy — keeps the unit roster from growing on every repeat click.
	var radius_px: float = maxf(float(sz.x), float(sz.y)) * gs * 1.5
	var radius_sq: float = radius_px * radius_px
	var nearest: Node2D = null
	var nearest_d2: float = radius_sq
	for u in player_units:
		if u == null or not is_instance_valid(u) or u.is_dead:
			continue
		var ud = u.data if "data" in u else null
		if ud == null or StringName(ud.id) != unit_id:
			continue
		var d2: float = center.distance_squared_to(u.position)
		if d2 < nearest_d2:
			nearest_d2 = d2
			nearest = u
	if nearest != null:
		_take_control_of_unit(nearest)
		return
	# Spawn a new core unit at the core centre and take control. The
	# newly-spawned unit is appended to `player_units` (last index).
	spawn_player_unit(center, unit_id)
	if player_units.is_empty():
		return
	var spawned: Node2D = player_units[player_units.size() - 1]
	if spawned != null and is_instance_valid(spawned):
		_take_control_of_unit(spawned)


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
	_spawn_control_select_effect_for_unit(unit)


func _take_control_of_turret(grid_pos: Vector2i) -> void:
	_release_control()
	_deselect_all()
	controlled_entity = grid_pos
	controlled_type = "turret"
	_control_attack_timer = 0.0
	_spawn_control_select_effect_for_block(grid_pos)
	# Tell CombatSystem to skip auto-targeting for this turret
	var combat = _combat_sys_ref()
	if combat:
		combat.manually_controlled_turret = grid_pos


func _take_control_of_crane(anchor: Vector2i) -> void:
	_release_control()
	_deselect_all()
	controlled_entity = anchor
	controlled_type = "crane"
	_spawn_control_select_effect_for_block(anchor)
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

	# Handle crane-pickup action for pickup/drop
	if Input.is_action_pressed("crane_pickup") and not _crane_e_held:
		_crane_e_held = true
		_crane_interact(anchor, state, crane_center, max_reach)
	elif not Input.is_action_pressed("crane_pickup"):
		_crane_e_held = false

	# Handle crane-drop action to rotate held payload by 90°
	if Input.is_action_pressed("crane_drop") and not _crane_q_held:
		_crane_q_held = true
		if state["held_payload"] != null and state["held_payload"].get("type", "") == "building":
			var bdata_q = Registry.get_block(StringName(state["held_payload"].get("block_id", "")))
			var building_sys_q = _building_sys_ref()
			var is_dir: bool = building_sys_q != null and bdata_q != null and building_sys_q._is_directional(bdata_q.id)
			if is_dir:
				state["held_payload"]["rotation"] = (int(state["held_payload"].get("rotation", 0)) + 1) % 4
	elif not Input.is_action_pressed("crane_drop"):
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
			# Capture the FULL runtime pose (facing/aim/mount rotations +
			# command state) so the carried unit renders at its real
			# rotation and resumes its orders on drop — same path the
			# autonomous crane (crane_system) uses. The old partial dict
			# dropped facing_angle, so a picked-up unit snapped to 0°.
			var unit_payload := {}
			if clicked_unit.has_method("capture_payload_state"):
				clicked_unit.capture_payload_state(unit_payload)
			else:
				unit_payload = {
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
				# Naval units can only be dropped onto navigable water. If the
				# grabber isn't over water, KEEP holding the payload (don't
				# spawn it on land) until the crane is over a valid cell.
				var pud = Registry.get_unit(unit_id)
				var p_ml: int = pud.movement_layer if pud else 0
				if p_ml == UnitData.MovementLayer.NAVAL \
						and not is_world_pos_walkable(grabber_world, p_ml):
					return
				# Honour the payload team (Payload-Source Ferox spawns as enemy).
				var team := int(payload.get("team", 0))
				var spawned = spawn_unit_with_team(grabber_world, unit_id, team)
				if is_instance_valid(spawned):
					# Restore the FULL captured pose (facing/aim/mount rotations +
					# commands) so the redeployed unit faces exactly where it was
					# picked up instead of snapping to 0°.
					if spawned.has_method("apply_payload_state"):
						spawned.apply_payload_state(payload)
					else:
						spawned.health = float(payload.get("health", spawned.health))
						if "applied_upgrades" in spawned:
							spawned.applied_upgrades.clear()
							for _up in payload.get("applied_upgrades", []):
								spawned.applied_upgrades.append(StringName(_up))
							if spawned.has_method("recompute_module_stats"):
								spawned.recompute_module_stats()
					if "is_dummy" in spawned:
						spawned.is_dummy = bool(payload.get("is_dummy", false))
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
	var movement_speed: float = unit.move_speed
	if unit.has_method("_module_rooted") and unit._module_rooted():
		velocity = Vector2.ZERO
	elif unit.has_method("_afterburner_active") and unit._afterburner_active():
		movement_speed *= 3.0

	# Tank steering: WASD picks a desired world-direction; the tank's motion
	# is delegated to the unit's shared tank-steer helper so manual driving
	# uses the same arc-around-pivot model as AI path following. We snapshot
	# the position first so we can revert into a wall if the arc pushed the
	# tank into a blocked cell.
	if unit.data and unit.data.tank_steering and velocity.length() > 0:
		var desired_face: float = velocity.normalized().angle()
		var forward_step: float = movement_speed * delta
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
			var radius_tank: float = unit.unit_size if "unit_size" in unit else main.GRID_SIZE * 0.4
			if not is_circle_walkable(unit.position, radius_tank, unit.data.movement_layer, unit.team):
				unit.position = pre_pos
			else:
				var map_wg: float = main.GRID_SIZE * main.GRID_WIDTH
				var map_hg: float = main.GRID_SIZE * main.GRID_HEIGHT
				unit.position.x = clampf(unit.position.x, 0.0, map_wg)
				unit.position.y = clampf(unit.position.y, 0.0, map_hg)
		return

	if velocity.length() > 0:
		velocity = velocity.normalized()
		var new_pos: Vector2 = unit.position + velocity * movement_speed * delta

		# Movement layer restrictions
		if unit.data and unit.data.movement_layer == UnitData.MovementLayer.FLYING:
			# Flying: completely free movement
			var map_w: float = main.GRID_SIZE * main.GRID_WIDTH
			var map_h: float = main.GRID_SIZE * main.GRID_HEIGHT
			new_pos.x = clampf(new_pos.x, 0.0, map_w)
			new_pos.y = clampf(new_pos.y, 0.0, map_h)
			unit.position = new_pos
		else:
			# Ground/Crawler/Hover/Naval: radius-aware, axis-separated
			# resolution via the shared `resolve_move` (same model the AI
			# path-follower uses), so manual driving slides along walls and
			# can't clip the unit's flank into a solid cell. Uses the unit's
			# real collision half-extent (`unit_size`) rather than a fixed
			# fraction of the tile.
			var map_w: float = main.GRID_SIZE * main.GRID_WIDTH
			var map_h: float = main.GRID_SIZE * main.GRID_HEIGHT
			var ml_ctrl: int = unit.data.movement_layer if unit.data else 0
			var radius_ctrl: float = unit.unit_size if "unit_size" in unit else main.GRID_SIZE * 0.4
			var resolved: Vector2 = resolve_move(unit.position, new_pos - unit.position, radius_ctrl, ml_ctrl, unit.team)
			resolved.x = clampf(resolved.x, 0.0, map_w)
			resolved.y = clampf(resolved.y, 0.0, map_h)
			unit.position = resolved

		# Clear any auto-combat targets while manually moving
		unit.path = PackedVector2Array()
		unit.path_index = 0
		unit.move_target = null
		unit.target_unit = null
		unit.target_building = null

	# --- Fire on left mouse held (like the player drone does) ---
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and main.selected_building == &"" \
			and not unit_mode_active:
		var mouse_pos: Vector2 = get_global_mouse_position()
		# Mount-equipped units (e.g. Wade) fire through their weapon mounts —
		# each ready head shoots from its own muzzle toward the cursor, so the
		# mirrored pair alternates and bullets come out the barrels, not the
		# unit centre. The mounts were already aimed this frame in the unit's
		# `is_controlled` _process branch (aim_only). Per-mount reload paces
		# the fire, so no global `_control_attack_timer` gate is needed here.
		if unit.has_method("has_weapon_mounts") and unit.has_weapon_mounts():
			if unit.has_method("fire_weapon_mounts_at"):
				unit.fire_weapon_mounts_at(mouse_pos)
		elif _control_attack_timer <= 0:
			if unit.has_method("_module_weapons_disabled") and unit._module_weapons_disabled():
				return
			var combat = _combat_sys_ref()
			if combat and unit.data:
				_control_attack_timer = unit._effective_attack_cooldown() if unit.has_method("_effective_attack_cooldown") else unit.attack_cooldown
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

	# Special "emitter" weapons (fume / flame / lightning) go through the SAME
	# shared dispatch the auto-fire loop uses, so the two paths can't drift
	# apart again. Runs every frame so the Arc's charge decays when the trigger
	# is released; `firing` = fire button held. The controlled turret is skipped
	# by _update_turrets, so tick its cooldown here.
	if bdata_aim and (bdata_aim.tags.has("fume_emitter") or bdata_aim.tags.has("flame_emitter") or bdata_aim.tags.has("lightning_emitter") or bdata_aim.tags.has("beam_emitter") or bdata_aim.tags.has("shockwave_emitter")) and combat.has_method("try_fire_special_weapon"):
		var em_firing: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and main.selected_building == &""
		combat.turret_cooldowns[grid_pos] = float(combat.turret_cooldowns.get(grid_pos, 0.0)) - _delta
		var em_range_px: float = bdata_aim.attack_range * float(main.GRID_SIZE)
		combat.try_fire_special_weapon(grid_pos, bdata_aim, turret_world, target_angle, main.Faction.LUMINA, 1.0, em_range_px, em_firing, _delta)
		return

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
				# Read + consume ammo via the shared CombatSystem helper so manual
				# fire matches auto-fire exactly (pellet count, spread, lifetime,
				# liquid ballistics) with no separate field-plumbing to keep in sync.
				# No ammo means it cannot fire.
				var profile: Dictionary = combat.read_ammo_profile(bdata, logistics, anchor)
				if not profile["found"]:
					return  # Out of ammo

				var booster_mult: float = 1.0
				if combat.has_method("_get_active_booster_multiplier"):
					booster_mult = combat._get_active_booster_multiplier(grid_pos, bdata, "Fire Rate")
				_control_attack_timer = (bdata.attack_speed * float(profile["reload_mult"])) / maxf(booster_mult, 0.0001)
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
							bcd[fire_barrel_idx] = bdata.attack_speed * float(profile["reload_mult"])
					_control_barrel_idx[grid_pos] = (fire_barrel_idx + 1) % bcount
				var fire_pos: Vector2 = turret_world + aim_dir_ctrl * barrel_length + aim_perp_ctrl * lateral_ctrl
				# Range cap matches auto-fire: bullets fly the turret range along the
				# aim axis (ammo range_bonus intentionally ignored).
				var fire_max_range: float = bdata.attack_range * main.GRID_SIZE
				# Travel along the head's aim axis so bullets exit the muzzle in the
				# direction the head points, aiming PAST the cursor to full range.
				var shot_dir: Vector2 = aim_dir_ctrl
				# Free-aim manual shot (target_type "none", no locked target). The
				# shared emitter applies spread, liquid launch speed and extras.
				combat.emit_fire_pellets(fire_pos, shot_dir.angle(), fire_max_range, fire_max_range, profile, null, "none", float(profile["damage"]) * float(profile["unit_mult"]), main.Faction.LUMINA)
				# Muzzle flame cone (Flarecaster), aimed where the head points.
				if bool(profile["muzzle_flame"]) and combat.has_method("spawn_muzzle_flame"):
					combat.spawn_muzzle_flame(fire_pos, shot_dir.angle(), -1.0, 8, 1.0, float(profile["flame_cone_width_bonus_degrees"]) * 0.5)


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
		UnitData.MovementLayer.NAVAL:
			astar_grid = astar_naval
	if astar_grid != null and astar_grid.is_point_solid(grid):
		if not _is_projected_bridge_cell(grid, team, ml):
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


func _is_projected_bridge_cell(grid: Vector2i, asking_team: int, ml: int) -> bool:
	if asking_team == -1:
		return false
	if ml != UnitData.MovementLayer.GROUND and ml != UnitData.MovementLayer.CRAWLER:
		return false
	var terrain = _terrain_ref()
	if terrain == null or not terrain.has_method("get_liquid_at"):
		return false
	var liquid = terrain.get_liquid_at(grid)
	if liquid == null or not liquid.is_liquid:
		return false
	var peers: Array = player_units if asking_team == UnitData.Team.PLAYER else enemies
	var cell_center: Vector2 = main.grid_to_world(grid) + Vector2(main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5)
	for u in peers:
		if not is_instance_valid(u) or u.is_dead:
			continue
		if not u.has_method("is_bridge_projecting") or not u.is_bridge_projecting():
			continue
		var forward: Vector2 = Vector2.RIGHT.rotated(u.facing_angle if "facing_angle" in u else 0.0)
		var rel: Vector2 = cell_center - u.position
		var along: float = rel.dot(forward)
		if along < 0.0 or along > float(main.GRID_SIZE) * 8.0:
			continue
		var side: float = absf(rel.dot(Vector2(-forward.y, forward.x)))
		if side <= float(main.GRID_SIZE) * 1.5:
			return true
	return false


## Radius-aware walkability: true only if a unit of half-extent `radius`
## centred at `world_pos` clears solids on every side. Tests the centre
## plus the four cardinal edge points (the unit's bounding-box faces), so a
## unit's flank can't clip into an adjacent solid cell the way a pure
## centre-point test allowed. `edges` lets callers restrict which faces are
## checked (e.g. only the horizontal pair when resolving an X-axis slide),
## mirroring Mindustry's per-axis push-out. Default = all four.
func is_circle_walkable(world_pos: Vector2, radius: float, ml: int, team: int = -1, edges: int = 0xF) -> bool:
	if ml == UnitData.MovementLayer.FLYING:
		return true
	if not is_world_pos_walkable(world_pos, ml, team):
		return false
	# NAVAL uses CENTRE-only collision: water bodies have irregular, stepped
	# shorelines, and the radius-aware edge test made a boat's flank snag on
	# every corner of a wall or non-water tile next to the water (units got
	# stuck on the coast). Boats are allowed to overhang the shore; they only
	# stop when their CENTRE would leave navigable water.
	if ml == UnitData.MovementLayer.NAVAL:
		return true
	# Cap the collision half-extent just under half a tile. A face point at
	# centre ± radius must stay inside the unit's own (open) cell for a
	# 1-tile-wide corridor to remain passable; clamping below GRID_SIZE/2
	# guarantees units never wedge in a legal single-tile gap even when
	# their sprite-derived `unit_size` is large.
	radius = minf(radius, float(main.GRID_SIZE) * 0.45)
	if radius <= 0.0:
		return true
	# 0x1=+X, 0x2=-X, 0x4=+Y, 0x8=-Y
	if (edges & 0x1) and not is_world_pos_walkable(world_pos + Vector2(radius, 0.0), ml, team):
		return false
	if (edges & 0x2) and not is_world_pos_walkable(world_pos + Vector2(-radius, 0.0), ml, team):
		return false
	if (edges & 0x4) and not is_world_pos_walkable(world_pos + Vector2(0.0, radius), ml, team):
		return false
	if (edges & 0x8) and not is_world_pos_walkable(world_pos + Vector2(0.0, -radius), ml, team):
		return false
	return true


## Mindustry-style axis-separated, radius-aware move resolver. Given a unit
## at `from` wanting to reach `from + delta`, returns the furthest position
## it can legally occupy: it resolves the X displacement first (testing only
## the horizontal faces), then Y (vertical faces), so a diagonal move into a
## wall cancels only the blocked component and the unit SLIDES along the wall
## face instead of snagging on the cell corner. `radius` is the unit's
## collision half-extent (≈ unit_size). Pure-axis callers still work since a
## zero component just resolves to itself.
# Segmented (swept) movement — a port of Mindustry's EntityCollisions.move():
# the displacement is walked in small fixed-size steps so a fast unit can't
# TUNNEL through a wall the way the old point-based resolve did (it only tested
# the endpoint). Each step is axis-separated, so the unit still slides along a
# wall face instead of snagging its corner. MOVE_SEG_FRAC must be < 1 tile so a
# single step can never skip over a 1-tile-thick wall.
const MOVE_SEG_FRAC := 0.25          # collision substep ≈ quarter-tile
const MOVE_MAX_DELTA := 6000.0       # hard per-call cap (anti lag-spike teleport)
func resolve_move(from: Vector2, delta: Vector2, radius: float, ml: int, team: int = -1) -> Vector2:
	if ml == UnitData.MovementLayer.FLYING:
		return from + delta
	var dist: float = delta.length()
	if dist <= 0.0001:
		return from
	# Clamp a runaway displacement (lag spike / absurd speed) so we never try to
	# resolve thousands of substeps or fling a unit across the map in one frame.
	if dist > MOVE_MAX_DELTA:
		delta = delta * (MOVE_MAX_DELTA / dist)
		dist = MOVE_MAX_DELTA
	var step_len: float = maxf(float(main.GRID_SIZE) * MOVE_SEG_FRAC, 1.0)
	var dir: Vector2 = delta / dist
	var pos: Vector2 = from
	var travelled: float = 0.0
	while travelled < dist - 0.0001:
		var s: float = minf(step_len, dist - travelled)
		travelled += s
		var seg: Vector2 = dir * s
		# --- X axis: only the leading/trailing horizontal faces matter ---
		if absf(seg.x) > 0.0001:
			var try_x: Vector2 = Vector2(pos.x + seg.x, pos.y)
			if is_circle_walkable(try_x, radius, ml, team, 0x1 | 0x2):
				pos.x = try_x.x
		# --- Y axis: vertical faces, using the maybe-advanced X so we slide
		# along (not through) the corner ---
		if absf(seg.y) > 0.0001:
			var try_y: Vector2 = Vector2(pos.x, pos.y + seg.y)
			if is_circle_walkable(try_y, radius, ml, team, 0x4 | 0x8):
				pos.y = try_y.y
	return pos


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
## water-bias weight list, all movement layers at once.
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
	# NAVAL is the inverse of the others: every cell is solid UNLESS it's
	# navigable water (water floor with no platform / building covering it).
	# We start with nothing solid here and ADD every non-navigable cell in
	# the whole-grid sweep below — water-only movement falls out for free,
	# and the unit's own walkability check makes it treat the shoreline like
	# a wall (no special steering code needed).
	var naval_set: Dictionary = {}
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
		# ANY building over a cell blocks naval movement — including
		# platforms (a platform turns water into "dry boards" the naval
		# unit can't float on) and floating transport. Naval only ever
		# occupies bare water.
		naval_set[grid_pos] = true

	# --- Terrain walls (single pass) ---
	# Only walls flagged as `blocks_pathfinding` count as obstacles for
	# any movement layer — decorative walls (low rocks, etc.) without
	# the flag should let units pass through. Match the old behaviour
	# exactly (old code applied this filter to all three layers).
	# `_recompute_crawler_wall_passability` then prunes small wall
	# segments out of the crawler layer in a second pass. Hover keeps
	# terrain walls solid.
	if terrain_sys:
		for grid_pos in wall_dict:
			var tile_data = Registry.get_tile(wall_dict[grid_pos])
			if tile_data and tile_data.blocks_pathfinding:
				ground_set[grid_pos] = true
				crawler_set[grid_pos] = true
				hover_set[grid_pos] = true
				naval_set[grid_pos] = true

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
				naval_set[gp] = true
				continue
			# Sector-script hidden tiles are an impassable barrier for
			# every layer.
			if sector_script and sector_script.is_tile_hidden(gp):
				ground_set[gp] = true
				crawler_set[gp] = true
				hover_set[gp] = true
				naval_set[gp] = true
				continue
			# Naval navigability + water bias for ground/crawler. A cell is
			# navigable for naval ONLY if it has a water floor and nothing
			# built on it; anything else (dry land, covered water) is solid
			# for naval. The building pass already marked covered cells.
			var is_navigable_water := false
			if has_floor:
				var td: TerrainTileData = Registry.get_tile(floor_dict[gp])
				if td and td.is_liquid and td.tags.has("water"):
					is_navigable_water = not main.placed_buildings.has(gp)
					# Water bias steers ground/crawler around lakes.
					if not main.placed_buildings.has(gp):
						var w: float = _water_cell_weight(gp)
						if w > 1.0:
							ground_weights[gp] = w
			if not is_navigable_water:
				naval_set[gp] = true

	return {
		"ground": ground_set,
		"crawler": crawler_set,
		"hover": hover_set,
		"naval": naval_set,
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
	var naval_set: Dictionary = sets["naval"]
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

	# --- NAVAL AStar ---
	# Only navigable water is non-solid; `naval_set` already holds every
	# other cell, so this is a plain solid-set apply (no wall pruning).
	astar_naval = AStarGrid2D.new()
	astar_naval.region = Rect2i(0, 0, main.GRID_WIDTH, main.GRID_HEIGHT)
	astar_naval.cell_size = Vector2(main.GRID_SIZE, main.GRID_SIZE)
	astar_naval.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar_naval.update()
	for gp in naval_set:
		astar_naval.set_point_solid(gp, true)

	# Analyze terrain wall segments for crawler passability.
	# Mutates astar_crawler in place: small wall segments get flipped
	# back to non-solid for crawlers. Hover keeps terrain walls solid.
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
	var naval_set: Dictionary = sets["naval"]
	var ground_weights_dict: Dictionary = sets["ground_weights"]

	# Crawler wall passability already pruned small segments from
	# `astar_crawler`; mirror those exclusions into the worker's set so
	# the background grid agrees with the main-thread grid. (Naval doesn't
	# participate in wall pruning — walls are always solid for it.)
	for gp in _crawler_passable_walls:
		crawler_set.erase(gp)

	# Flatten to typed arrays for the worker API.
	var ground_solids: Array[Vector2i] = []
	var crawler_solids: Array[Vector2i] = []
	var hover_solids: Array[Vector2i] = []
	var naval_solids: Array[Vector2i] = []
	for gp in ground_set: ground_solids.append(gp)
	for gp in crawler_set: crawler_solids.append(gp)
	for gp in hover_set: hover_solids.append(gp)
	for gp in naval_set: naval_solids.append(gp)
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
		ground_weights, crawler_weights, naval_solids)


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
				if reachable == null:
					reachable = _find_nearest_breach_building(unit, main.Faction.LUMINA)
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

	# Drain finished flow-field builds from the worker into the cache. Discard
	# results whose generation is stale (a building changed since the request,
	# so the field was built against an out-of-date grid).
	if _path_worker.has_method("poll_flow_results"):
		for fr in _path_worker.poll_flow_results():
			var fkey: String = fr["key"]
			_flow_pending.erase(fkey)
			if int(fr["generation"]) != _flow_generation:
				continue
			_flow_field_cache[fkey] = {"field": fr["field"], "age": 0.0}


## BFS-based fallback target picker. Floods walkable cells outward from
## `unit`'s current grid position on its movement layer's AStarGrid2D
## (capped at REACHABLE_BFS_BUDGET cells so a giant open map doesn't
## stall). For every reached cell, checks the 4 cardinal neighbours for
## a placed building of `target_faction` — first one found is returned
## as a guaranteed-reachable target. Returns null if the unit is
## genuinely walled into a void pocket.
const REACHABLE_BFS_BUDGET := 16000
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
	_invalidate_target_caches()
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
					# HOVER: passable buildings are open only when they are
					# not covering a terrain wall. Hover can skim over
					# water/platforms, but terrain walls still block it.
					if is_passable and not _is_blocking_terrain_wall(tile_pos):
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
	_invalidate_target_caches()
	_base_dirty = true
	# Always non-solid for ground / crawler (water is no longer hard-
	# blocked). Water cells get their pathfinding penalty restored so
	# units once again prefer dry routes around the cell. If a pathfinding
	# terrain wall exists underneath, restore its solidity for ground/hover
	# immediately; crawler legality is recomputed by wall-thickness rules.
	var terrain_wall_solid: bool = _is_blocking_terrain_wall(grid_pos)
	astar.set_point_solid(grid_pos, terrain_wall_solid)
	astar_crawler.set_point_solid(grid_pos, terrain_wall_solid and not _crawler_passable_walls.has(grid_pos))
	astar_hover.set_point_solid(grid_pos, terrain_wall_solid)
	var restored_weight: float = _water_cell_weight(grid_pos)
	astar.set_point_weight_scale(grid_pos, restored_weight)
	astar_crawler.set_point_weight_scale(grid_pos, restored_weight)
	if _path_worker:
		_path_worker.queue_set_solid(grid_pos, terrain_wall_solid, "ground")
		_path_worker.queue_set_solid(grid_pos, terrain_wall_solid and not _crawler_passable_walls.has(grid_pos), "crawler")
		_path_worker.queue_set_solid(grid_pos, terrain_wall_solid, "hover")
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
func spawn_enemy_for_fabricator(spawn_position: Vector2, unit_id: StringName, fab_anchor: Vector2i, spawn_facing: Variant = null) -> Node2D:
	var enemy: Node2D = _spawn_enemy_internal(spawn_position, unit_id, spawn_facing)
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


func _find_nearest_breach_building(unit: Node2D, target_faction: int) -> Variant:
	var from: Vector2i = main.world_to_grid(unit.position)
	from.x = clampi(from.x, 0, main.GRID_WIDTH - 1)
	from.y = clampi(from.y, 0, main.GRID_HEIGHT - 1)
	var best: Variant = null
	var best_score: float = 1.0e20
	for grid_pos in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
		if anchor != grid_pos:
			continue
		if main.get_building_faction(anchor) != target_faction:
			continue
		var bdata = Registry.get_block(main.placed_buildings[grid_pos])
		if bdata == null or bdata.tags.has("platform") or bdata.tags.has("no_pathfinding"):
			continue
		var dx: int = absi(grid_pos.x - from.x)
		var dy: int = absi(grid_pos.y - from.y)
		var score: float = float(maxi(dx, dy))
		if bdata.tags.has("wall"):
			score -= 12.0
		elif bdata.tags.has("defense"):
			score -= 4.0
		if score < best_score:
			best_score = score
			best = grid_pos
	return best


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
func _spawn_enemy_internal(spawn_position: Vector2, unit_id: StringName, spawn_facing: Variant = null) -> Node2D:
	var unit_data = Registry.get_unit(unit_id)
	if unit_data == null:
		push_warning("UnitManager: Unit '%s' not found in Registry — using fallback stats." % unit_id)

	var ml_e: int = unit_data.movement_layer if unit_data else 0
	var corrected_e: Variant = _validate_spawn_position(spawn_position, ml_e)
	if corrected_e == null:
		print_verbose("UnitManager: refused to spawn '%s' - no walkable cell near %s" % [unit_id, str(spawn_position)])
		return null
	var enemy = Node2D.new()
	enemy.set_script(enemy_script)
	enemy.data = unit_data
	enemy.team = UnitData.Team.ENEMY
	enemy.main = main
	enemy.unit_manager = self
	enemy.position = corrected_e
	_seed_unit_spawn_motion(enemy, spawn_facing)

	add_child(enemy)
	enemies.append(enemy)
	return enemy


## Spawns a player unit at the given position (produced by a fabricator).
func spawn_player_unit(spawn_position: Vector2, unit_id: StringName, spawn_facing: Variant = null) -> void:
	var unit_data = Registry.get_unit(unit_id)
	if unit_data == null:
		push_warning("UnitManager: Unit '%s' not found in Registry!" % unit_id)
		return

	var ml_p: int = unit_data.movement_layer
	var corrected_p: Variant = _validate_spawn_position(spawn_position, ml_p)
	if corrected_p == null:
		print_verbose("UnitManager: refused to spawn '%s' - no walkable cell near %s" % [unit_id, str(spawn_position)])
		return
	var unit = Node2D.new()
	unit.set_script(enemy_script)
	unit.data = unit_data
	unit.team = UnitData.Team.PLAYER
	unit.main = main
	unit.unit_manager = self
	unit.position = corrected_p
	_seed_unit_spawn_motion(unit, spawn_facing)

	add_child(unit)
	player_units.append(unit)
	# Player units don't pathfind to buildings — they idle at spawn


func _seed_unit_spawn_motion(unit: Node2D, spawn_facing: Variant = null) -> void:
	if unit == null:
		return
	if spawn_facing != null:
		var angle := float(spawn_facing)
		if "facing_angle" in unit:
			unit.facing_angle = angle
		if "aim_angle" in unit:
			unit.aim_angle = angle
		if "_facing_initialized" in unit:
			unit._facing_initialized = true
	if "_prev_position" in unit:
		unit._prev_position = unit.position
	if "_vel_prev_pos" in unit:
		unit._vel_prev_pos = unit.position
	if "_vel_initialised" in unit:
		unit._vel_initialised = true
	if "velocity" in unit:
		unit.velocity = Vector2.ZERO


## Spawns a unit for the given team (UnitData.Team — PLAYER/Lumina or
## ENEMY/Ferox) and returns the node, so payload unpack (crane drop) can
## honour the Payload Source faction choice and then restore per-instance
## state. Falls back to the player path for any non-ENEMY team.
func spawn_unit_with_team(spawn_position: Vector2, unit_id: StringName, team: int) -> Node2D:
	if team == UnitData.Team.ENEMY:
		spawn_enemy(spawn_position, unit_id)
		return enemies[-1] if not enemies.is_empty() else null
	spawn_player_unit(spawn_position, unit_id)
	return player_units[-1] if not player_units.is_empty() else null


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

	# Main pathing now flows through the shared FlowField: one cached field per
	# target cell, reused by every enemy heading there and across frames, rather
	# than a per-unit A* request. _assign_flow_path_to_enemy falls back to the
	# threaded A* worker when the field can't reach this start (or for flyers).
	if flow_field_pathing:
		_assign_flow_path_to_enemy(enemy, nearest_building as Vector2i)
		return

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
		if bdata and (bdata.tags.has("platform") or bdata.tags.has("no_pathfinding")):
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
		if bdata == null or bdata.tags.has("platform") or bdata.tags.has("no_pathfinding"):
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
## walls. 0.4 = densely walled in. Cheap 5×5 scan around the building
## anchor. Results are cached per-anchor and refreshed on building
## placement / destruction (see `_invalidate_target_caches`), so the
## per-frame cost is one dict lookup unless the local terrain changed.
var _vulnerability_cache: Dictionary = {}

func _building_vulnerability(grid_pos: Vector2i) -> float:
	if _vulnerability_cache.has(grid_pos):
		return _vulnerability_cache[grid_pos]
	var wall_n: int = 0
	var checked: int = 0
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
	var result: float = 1.0
	if checked > 0:
		var dense: float = clampf(float(wall_n) / float(checked), 0.0, 1.0)
		result = lerpf(1.0, 0.4, dense)
	_vulnerability_cache[grid_pos] = result
	return result


## Drops cached target-scoring data. Called from `_on_building_placed`
## and `on_building_destroyed`, so any structural change refreshes the
## cache lazily on the next squad scan.
func _invalidate_target_caches() -> void:
	_vulnerability_cache.clear()
	_threat_cache_valid_until = 0.0
	_scored_targets_cache_until = 0.0


## Cached threat assessment — recomputed at most every
## `_SQUAD_SCAN_INTERVAL`. Squad scans share the result so multiple
## bases firing in the same second don't each walk every building.
var _threat_cache_value: float = 0.0
var _threat_cache_valid_until: float = 0.0
## Cached scored-target list keyed by (faction, origin-bucket).
## Bucket = origin / 8 tiles so nearby origins reuse one cached scan.
var _scored_targets_cache: Dictionary = {}
var _scored_targets_cache_until: float = 0.0


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
	# Cached for _SQUAD_SCAN_INTERVAL — multiple squads firing inside
	# the same scan window reuse one walk over placed_buildings.
	var now: float = float(Time.get_ticks_msec()) * 0.001
	if now < _threat_cache_valid_until:
		return _threat_cache_value
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
	_threat_cache_value = total
	_threat_cache_valid_until = now + _SQUAD_SCAN_INTERVAL
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
	# Cache scored lists by (faction, origin-bucket). 8-tile buckets
	# let nearby origins share one scan — perfect for multi-fabricator
	# bases all firing within the same 2 s window.
	var bucket: Vector2i = Vector2i(origin.x / 8, origin.y / 8)
	var key: String = "%d,%d,%d" % [target_faction, bucket.x, bucket.y]
	var now: float = float(Time.get_ticks_msec()) * 0.001
	var scored: Array = []
	if now < _scored_targets_cache_until and _scored_targets_cache.has(key):
		scored = _scored_targets_cache[key]
	else:
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
		_scored_targets_cache[key] = scored
		# Refresh window — keep the cache valid until building churn or
		# the next squad scan interval, whichever comes first.
		_scored_targets_cache_until = now + _SQUAD_SCAN_INTERVAL
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
	# 2=HOVER, 3=FLYING, 4=NAVAL.
	match ml:
		1: return astar_crawler
		2: return astar_hover
		3: return null
		4: return astar_naval
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
	# FLYING doesn't use a flow field.
	if _astar_for_layer(ml) == null:
		return null
	# Not built yet — request a build on the worker thread (once) and return
	# null. The caller (_assign_flow_path_to_enemy) falls back to the threaded
	# A* path meanwhile; once the field arrives in _poll_path_results, the next
	# (re)assignment picks it up. This keeps full-map BFS off the main thread.
	if not _flow_pending.has(key) and _path_worker != null and _path_worker.has_method("request_flow_field"):
		_flow_pending[key] = true
		_path_worker.request_flow_field(target, ml, key, _flow_generation)
	return null


## Clear the flow-field cache. Called whenever a building is placed
## or destroyed because that change may have created or broken a route.
func _invalidate_flow_fields() -> void:
	_flow_field_cache.clear()
	# Bump the generation so any in-flight worker builds (against the old grid)
	# are discarded when they return, and clear the in-flight set so the new
	# grid's fields get re-requested.
	_flow_pending.clear()
	_flow_generation += 1


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

## (Re)builds the per-frame spatial hash if it hasn't been built this frame.
## Buckets every live unit by (movement_layer, cellX, cellY). Cell size is
## chosen to exceed twice the largest unit's size, so any two units close
## enough to interact (collision min_dist or separation sep_radius, both
## ≤ 2× a unit's size) land in the same or an adjacent cell — making a 3×3
## neighbour query a guaranteed superset of the old full same-layer scan.
func _ensure_spatial_hash() -> void:
	var frame: int = Engine.get_process_frames()
	if frame == _spatial_hash_frame:
		return
	_spatial_hash_frame = frame
	_spatial_hash.clear()
	# Largest interaction radius across all live units → cell size. Start
	# from one tile so a map with tiny units still uses sane buckets.
	var max_unit_size: float = float(main.GRID_SIZE) * 0.5
	var both: Array = [enemies, player_units]
	for arr in both:
		for u in arr:
			if u == null or not is_instance_valid(u) or u.is_dead:
				continue
			if "unit_size" in u and float(u.unit_size) > max_unit_size:
				max_unit_size = float(u.unit_size)
	# Cell size must cover the interaction reach (≤ 2× the largest unit's
	# size: sep_radius = size×2, collision min_dist = size×1.6) PLUS the
	# largest per-frame displacement — because units move/shove each other
	# AFTER the hash is built, so a queried unit's bucketed position can be
	# up to one frame's step stale. With cell ≥ reach + step, any two units
	# close enough to interact differ by at most one cell per axis, so the
	# 3×3 neighbour query is guaranteed to find them (identical results to
	# the old full scan). The +64px margin absorbs steps up to ~3840 px/s
	# at 60 fps — well above any unit's speed.
	_spatial_cell_size = maxf(float(main.GRID_SIZE), max_unit_size * 2.0 + 64.0)
	for arr in both:
		for u in arr:
			if u == null or not is_instance_valid(u) or u.is_dead:
				continue
			var layer: int = u.data.movement_layer if u.data else 0
			var key := Vector3i(
				layer,
				int(floor(u.position.x / _spatial_cell_size)),
				int(floor(u.position.y / _spatial_cell_size)),
			)
			if not _spatial_hash.has(key):
				_spatial_hash[key] = []
			_spatial_hash[key].append(u)


## Returns the units on `layer` within the 3×3 block of spatial-hash cells
## around `world_pos` — the candidate set for separation / collision. Builds
## the hash for this frame on first call. The caller still does its own exact
## distance check; this just prunes the n² down to local neighbours.
func get_nearby_units(world_pos: Vector2, layer: int) -> Array:
	_ensure_spatial_hash()
	var out: Array = []
	var cx: int = int(floor(world_pos.x / _spatial_cell_size))
	var cy: int = int(floor(world_pos.y / _spatial_cell_size))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var bucket = _spatial_hash.get(Vector3i(layer, cx + dx, cy + dy), null)
			if bucket != null:
				out.append_array(bucket)
	return out


## Cross-layer neighbour query for the global body collision pass. Movement
## layers decide terrain/path rules, not whether two visible unit bodies should
## be allowed to occupy the same space.
func get_nearby_units_any_layer(world_pos: Vector2) -> Array:
	_ensure_spatial_hash()
	var out: Array = []
	var cx: int = int(floor(world_pos.x / _spatial_cell_size))
	var cy: int = int(floor(world_pos.y / _spatial_cell_size))
	for layer in range(UnitData.MovementLayer.size()):
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var bucket = _spatial_hash.get(Vector3i(layer, cx + dx, cy + dy), null)
				if bucket != null:
					out.append_array(bucket)
	return out


func _is_controlled_unit_node(node: Variant) -> bool:
	return controlled_entity is Node2D and node == controlled_entity


func _unit_is_moving_for_collision(unit: Node2D) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	var has_path: bool = ("path" in unit and unit.path.size() > 0)
	var path_idx: int = int(unit.path_index) if "path_index" in unit else 0
	return (has_path and path_idx < unit.path.size()) or _is_controlled_unit_node(unit)


func _resolve_unit_collisions(_delta: float) -> void:
	# Manual control can move a unit after another unit has already touched
	# the per-frame neighbour cache. Rebuild here so collision uses the
	# current positions, not the pre-control-move snapshot.
	_spatial_hash_frame = -1
	var all_units: Array[Node2D] = []
	for u in enemies:
		if is_instance_valid(u) and not u.is_dead:
			all_units.append(u)
	for u in player_units:
		if is_instance_valid(u) and not u.is_dead:
			all_units.append(u)
	var count := all_units.size()
	if count < 2:
		return

	var map_w: float = main.GRID_SIZE * main.GRID_WIDTH
	var map_h: float = main.GRID_SIZE * main.GRID_HEIGHT

	var offsets: Array[Vector2] = []
	offsets.resize(count)
	for i in range(count):
		offsets[i] = Vector2.ZERO
	var idx_of: Dictionary = {}
	for i in range(count):
		idx_of[all_units[i].get_instance_id()] = i

	for i in range(count):
		var a: Node2D = all_units[i]
		var radius_a: float = a.unit_size
		var a_moving: bool = _unit_is_moving_for_collision(a)
		var neighbours: Array = get_nearby_units_any_layer(a.position)
		for b: Node2D in neighbours:
			var j_v: int = idx_of.get(b.get_instance_id(), -1)
			if j_v <= i:
				continue
			var j: int = j_v
			var radius_b: float = b.unit_size
			var b_moving: bool = _unit_is_moving_for_collision(b)
			var min_dist := radius_a + radius_b
			var diff := a.position - b.position
			var dist := diff.length()

			if dist < min_dist:
				var push_dir: Vector2
				if dist < MIN_SEPARATION_DIST:
					var angle := randf() * TAU
					push_dir = Vector2(cos(angle), sin(angle))
				else:
					push_dir = diff / dist

				var overlap := min_dist - dist
				var pair_has_controlled: bool = _is_controlled_unit_node(a) or _is_controlled_unit_node(b)

				if pair_has_controlled:
					var shove := push_dir * (overlap + 1.0)
					var controlled_share := 0.25
					if _is_controlled_unit_node(a):
						offsets[i] += shove * controlled_share
						offsets[j] -= shove * (1.0 - controlled_share)
					else:
						offsets[i] += shove * (1.0 - controlled_share)
						offsets[j] -= shove * controlled_share
					continue

				if dist < min_dist * 0.3:
					var snap := push_dir * (overlap * 0.5 + 1.0)
					offsets[i] += snap * 0.5
					offsets[j] -= snap * 0.5
					continue

				var push := push_dir * (overlap / 1.5)
				var a_share: float
				var b_share: float
				if a_moving and not b_moving:
					a_share = 0.05
					b_share = 0.95
				elif b_moving and not a_moving:
					a_share = 0.95
					b_share = 0.05
				elif a_moving and b_moving:
					push *= 0.45
					a_share = 0.5
					b_share = 0.5
				else:
					a_share = 0.5
					b_share = 0.5

				offsets[i] += push * a_share
				offsets[j] -= push * b_share

	for i in range(count):
		if offsets[i] != Vector2.ZERO:
			var u_apply: Node2D = all_units[i]
			var ml_apply: int = u_apply.data.movement_layer if u_apply.data else 0
			var team_apply: int = u_apply.team if "team" in u_apply else -1
			u_apply.position = resolve_move(u_apply.position, offsets[i], u_apply.unit_size, ml_apply, team_apply)
			u_apply.position.x = clampf(u_apply.position.x, 0.0, map_w)
			u_apply.position.y = clampf(u_apply.position.y, 0.0, map_h)


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
	if data.transport_speed > 0:
		return true
	var fluid_machine: bool = data.tags.has("pump") or data.tags.has("condenser") \
			or data.tags.has("vent_powered")
	if data.transports_fluid and not fluid_machine:
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


func _is_blocking_terrain_wall(grid_pos: Vector2i) -> bool:
	var terrain = _terrain_ref()
	if terrain == null or not terrain.wall_tiles.has(grid_pos):
		return false
	var td: TerrainTileData = Registry.get_tile(terrain.wall_tiles[grid_pos])
	return td != null and td.blocks_pathfinding


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
		UnitData.MovementLayer.NAVAL:
			return astar_naval
		_:
			return astar


# =========================
# CRAWLER WALL ANALYSIS
# =========================

## Recomputes which terrain wall cells are passable for crawlers.
## Building blocks never block crawlers — only terrain walls do.
## LOCAL thickness of one wall cell = the smallest of its four contiguous
## wall runs through that cell: horizontal, vertical, and both diagonals.
## A unit crosses via the thinnest axis, so including the diagonals lets it
## clip the tip of a convex corner (short diagonal run) even where the H/V
## runs are thick. `wall_set` is the set of all wall cells. Runs are capped
## at 9 so this stays cheap and returns >8 to mean "too thick to cross here".
## Because it's purely local, a thin arm (or a corner notch) reads as thin
## even where it abuts a thick blob — Mindustry's per-tile "crawl over thin
## walls" behaviour.
func _wall_cell_thickness(cell: Vector2i, wall_set: Dictionary) -> int:
	# Horizontal run (← →)
	var h: int = 1
	var x: int = cell.x - 1
	while h <= 8 and wall_set.has(Vector2i(x, cell.y)):
		h += 1
		x -= 1
	x = cell.x + 1
	while h <= 8 and wall_set.has(Vector2i(x, cell.y)):
		h += 1
		x += 1
	var v: int = 1
	var y: int = cell.y - 1
	while v <= 8 and wall_set.has(Vector2i(cell.x, y)):
		v += 1
		y -= 1
	y = cell.y + 1
	while v <= 8 and wall_set.has(Vector2i(cell.x, y)):
		v += 1
		y += 1
	# Diagonal runs (↖↘ and ↗↙). A unit can also cut a wall by crossing it
	# diagonally — e.g. clipping the tip of a convex corner. At such a corner
	# one diagonal run is short even when both H and V runs are thick, so this
	# carves a triangular notch (≤ 8 cells deep) the crawler can slice through.
	var d1: int = 1
	var p := Vector2i(cell.x - 1, cell.y - 1)
	while d1 <= 8 and wall_set.has(p):
		d1 += 1
		p += Vector2i(-1, -1)
	p = Vector2i(cell.x + 1, cell.y + 1)
	while d1 <= 8 and wall_set.has(p):
		d1 += 1
		p += Vector2i(1, 1)
	var d2: int = 1
	p = Vector2i(cell.x + 1, cell.y - 1)
	while d2 <= 8 and wall_set.has(p):
		d2 += 1
		p += Vector2i(1, -1)
	p = Vector2i(cell.x - 1, cell.y + 1)
	while d2 <= 8 and wall_set.has(p):
		d2 += 1
		p += Vector2i(-1, 1)
	return mini(mini(h, v), mini(d1, d2))


func _recompute_crawler_wall_passability() -> void:
	# Step 1: Collect terrain wall positions that block pathfinding
	var all_wall_positions: Dictionary = {}

	var terrain_sys = _terrain_ref()
	if terrain_sys:
		for grid_pos in terrain_sys.wall_tiles:
			var tile_data = Registry.get_tile(terrain_sys.wall_tiles[grid_pos])
			if tile_data and tile_data.blocks_pathfinding:
				all_wall_positions[grid_pos] = true

	# Step 2: per-cell LOCAL thickness. A wall cell is crossable when the
	# wall is <= 8 thick AT THAT CELL — i.e. the smallest of its horizontal,
	# vertical, and two diagonal contiguous runs. This is a local check, NOT
	# a whole-group one: a thin arm stays crossable even where it joins a
	# thick blob, and a convex corner exposes a thin diagonal run so the
	# crawler can slice across the corner tip (you cross the thin slice, you
	# don't care about the blob behind it). Mirrors Mindustry's "crawl over
	# thin walls" rule, which is per-tile. Hover units are intentionally not
	# carved here: terrain walls remain solid for them.
	_crawler_passable_walls.clear()
	_hover_passable_walls.clear()
	for wall_pos in all_wall_positions:
		astar_crawler.set_point_solid(wall_pos, true)
		if astar_hover:
			astar_hover.set_point_solid(wall_pos, true)

	for wall_pos in all_wall_positions:
		if _wall_cell_thickness(wall_pos, all_wall_positions) <= 8:
			astar_crawler.set_point_solid(wall_pos, false)
			_crawler_passable_walls[wall_pos] = true

	# Also recompute the NAVAL grid's solids in lockstep (terrain edits can
	# add/remove water and walls). Naval is the inverse of the others, so
	# rebuild it from the full solidity sets rather than the wall-only delta.
	var naval_sets: Dictionary = _build_solidity_sets()
	var naval_set: Dictionary = naval_sets["naval"]
	if astar_naval:
		astar_naval.fill_solid_region(Rect2i(0, 0, main.GRID_WIDTH, main.GRID_HEIGHT), false)
		for gp in naval_set:
			astar_naval.set_point_solid(gp, true)

	# Sync worker thread grids — full rebuild for terrain-wall changes.
	if _path_worker:
		# Dedup with a Dictionary set — `Array.has()` here is O(n), so the
		# old version was O(n²) over every wall and dominated sector-load
		# time on wall-heavy maps (Sulfur Springs has ~68k walls, making
		# this loop alone billions of comparisons).
		var ground_seen: Dictionary = {}
		var ground_solids: Array[Vector2i] = []
		for grid_pos in main.placed_buildings:
			if not _is_ground_passable_building(grid_pos):
				ground_seen[grid_pos] = true
				ground_solids.append(grid_pos)
		for wall_pos in all_wall_positions:
			if not ground_seen.has(wall_pos):
				ground_seen[wall_pos] = true
				ground_solids.append(wall_pos)

		var crawler_solids: Array[Vector2i] = []
		for grid_pos in main.placed_buildings:
			if _is_building_wall(grid_pos):
				crawler_solids.append(grid_pos)
		for wall_pos in all_wall_positions:
			if not _crawler_passable_walls.has(wall_pos):
				crawler_solids.append(wall_pos)

		var hover_solids: Array[Vector2i] = []
		for grid_pos in main.placed_buildings:
			if not _is_ground_passable_building(grid_pos):
				hover_solids.append(grid_pos)
		for wall_pos in all_wall_positions:
			hover_solids.append(wall_pos)

		var naval_solids: Array[Vector2i] = []
		for gp in naval_set:
			naval_solids.append(gp)

		_path_worker.queue_rebuild(ground_solids, crawler_solids, hover_solids, naval_solids)


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


## Draw callback for the dedicated control overlay (z=4099). Runs every
## frame and renders both:
##   1. A persistent "you are controlling THIS" overlay on the currently-
##      controlled unit / turret / crane.
##   2. A Ctrl-hover preview on whatever the player is hovering over
##      with the `additive_select_modifier` held.
##
## Turret / crane → flat yellow rect at the block's actual footprint
## (matches the in-game style: just the block, no padding).
## Unit → the unit's sprite re-drawn on the overlay tinted yellow so
## the controlled silhouette reads as the dominant element.
## Both styles get the four orbiting arrowheads.
func _draw_ctrl_hover_on_overlay() -> void:
	if main == null:
		return
	# Reset and queue the silhouette sub-canvas every frame so stale
	# sprites from the last frame don't linger when the cursor moves off.
	_silhouette_targets.clear()
	if _ctrl_hover_silhouette:
		_ctrl_hover_silhouette.queue_redraw()
	_draw_control_select_effects()
	# Only show the overlay while the modifier is held and the cursor is
	# over a valid target — controlling an entity no longer paints it.
	if main.is_ui_blocking():
		return
	var ctrl_held: bool = Input.is_action_pressed("additive_select_modifier") \
			or Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)
	if not ctrl_held:
		return
	var mouse_world: Vector2 = get_global_mouse_position()
	var hovered_unit := _get_player_unit_at(mouse_world)
	if hovered_unit and is_instance_valid(hovered_unit) and not hovered_unit.is_dead:
		_paint_ctrl_overlay_for_unit(hovered_unit, 1.0)
		return
	var grid_pos: Vector2i = main.world_to_grid(mouse_world)
	if not main.placed_buildings.has(grid_pos):
		return
	var block_id: StringName = main.placed_buildings[grid_pos]
	var bdata = Registry.get_block(block_id)
	if bdata == null:
		return
	if not (bdata.is_turret() or bdata.tags.has("crane") or bdata.tags.has("core")):
		return
	if main.get_building_faction(grid_pos) != main.Faction.LUMINA:
		return
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	_paint_ctrl_overlay_for_block(anchor, bdata, 0.45)


func _tick_control_select_effects(delta: float) -> void:
	for i in range(_control_select_effects.size() - 1, -1, -1):
		var e: Dictionary = _control_select_effects[i]
		e["age"] = float(e.get("age", 0.0)) + delta
		if float(e["age"]) >= float(e.get("duration", _CONTROL_SELECT_EFFECT_DURATION)):
			_control_select_effects.remove_at(i)
		else:
			_control_select_effects[i] = e


func _spawn_control_select_effect_for_unit(unit: Node2D) -> void:
	if not is_instance_valid(unit):
		return
	var udata = unit.data if "data" in unit else null
	var tex: Texture2D = null
	var size := Vector2.ONE * maxf(float(unit.unit_size) * 2.0 if "unit_size" in unit else 36.0, 24.0)
	var angle: float = float(unit.facing_angle) + PI * 0.5 if "facing_angle" in unit else 0.0
	if udata != null:
		var scale_f: float = (udata.sprite_scale if udata.sprite_scale > 0.0 else 1.0) * main.SPRITE_SCALE_FACTOR
		var spr_off: float = udata.sprite_angle_offset if "sprite_angle_offset" in udata else 0.0
		if udata.base_sprite:
			tex = udata.base_sprite
			size = tex.get_size() * scale_f
			angle += spr_off
		elif udata.head_sprite:
			tex = udata.head_sprite
			size = tex.get_size() * scale_f
			angle += spr_off
	_control_select_effects.append({
		"kind": "unit",
		"target": unit,
		"pos": unit.position,
		"tex": tex,
		"size": size,
		"angle": angle,
		"radius": maxf(maxf(size.x, size.y) * 0.5, float(unit.unit_size) if "unit_size" in unit else 18.0),
		"age": 0.0,
		"duration": _CONTROL_SELECT_EFFECT_DURATION,
	})


func _spawn_control_select_effect_for_block(grid_pos: Vector2i) -> void:
	if main == null or not main.placed_buildings.has(grid_pos):
		return
	var block_id: StringName = main.placed_buildings[grid_pos]
	var bdata = Registry.get_block(block_id)
	if bdata == null:
		return
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var gs: float = float(main.GRID_SIZE)
	var size := Vector2(
		float(maxi(bdata.grid_size.x, 1)) * gs,
		float(maxi(bdata.grid_size.y, 1)) * gs,
	)
	var center: Vector2 = main.grid_to_world(anchor) + size * 0.5
	var tex: Texture2D = bdata.base_sprite
	if tex == null:
		tex = bdata.icon
	_control_select_effects.append({
		"kind": "block",
		"pos": center,
		"tex": tex,
		"size": size,
		"angle": 0.0,
		"radius": maxf(size.x, size.y) * 0.5,
		"age": 0.0,
		"duration": _CONTROL_SELECT_EFFECT_DURATION,
	})


func _draw_control_select_effects() -> void:
	if _ctrl_hover_overlay == null:
		return
	for e in _control_select_effects:
		var duration: float = maxf(float(e.get("duration", _CONTROL_SELECT_EFFECT_DURATION)), 0.001)
		var progress: float = clampf(float(e.get("age", 0.0)) / duration, 0.0, 1.0)
		var fout: float = 1.0 - progress
		var slope: float = sin(progress * PI)
		var pos: Vector2 = e.get("pos", Vector2.ZERO)
		var target = e.get("target", null)
		if target is Node2D and is_instance_valid(target):
			pos = (target as Node2D).position
		var size: Vector2 = e.get("size", Vector2.ONE * 32.0)
		var tex: Texture2D = e.get("tex")
		var icon_alpha: float = 0.85 * fout
		if tex != null:
			var angle: float = float(e.get("angle", 0.0))
			_ctrl_hover_overlay.draw_set_transform(pos, angle, Vector2.ONE)
			_ctrl_hover_overlay.draw_texture_rect(
				tex,
				Rect2(-size * 0.5, size),
				false,
				Color(1.0, 0.86, 0.22, icon_alpha)
			)
			_ctrl_hover_overlay.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		else:
			_ctrl_hover_overlay.draw_circle(pos, maxf(size.x, size.y) * 0.5, Color(1.0, 0.86, 0.22, icon_alpha * 0.45))
		var radius: float = maxf(float(e.get("radius", maxf(size.x, size.y) * 0.5)), 8.0)
		var line_alpha: float = 0.90 * slope
		_draw_control_select_diamond(pos, radius * 2.0 * fout, Color(1.0, 0.92, 0.25, line_alpha), maxf(1.0, slope * 2.0))
		_draw_control_select_diamond(pos, radius * 3.0 * fout, Color(1.0, 0.92, 0.25, line_alpha * 0.85), maxf(1.0, slope * 4.0))


func _draw_control_select_diamond(center: Vector2, radius: float, color: Color, width: float) -> void:
	if _ctrl_hover_overlay == null or radius <= 0.25 or color.a <= 0.0:
		return
	var pts := PackedVector2Array()
	for i in range(5):
		var angle: float = float(i % 4) * PI * 0.5
		pts.append(center + Vector2.from_angle(angle) * radius)
	_ctrl_hover_overlay.draw_polyline(pts, color, width, true)


## Block-style overlay: a flat yellow rect at the block's exact
## footprint (no padding around it — the user only wants the block
## tile area covered) plus the four orbiting arrows.
func _paint_ctrl_overlay_for_block(anchor: Vector2i, bdata: BlockData, alpha: float) -> void:
	if _ctrl_hover_overlay == null:
		return
	var gs: float = float(main.GRID_SIZE)
	var size: Vector2 = Vector2(
		float(maxi(bdata.grid_size.x, 1)) * gs,
		float(maxi(bdata.grid_size.y, 1)) * gs,
	)
	var top_left: Vector2 = main.grid_to_world(anchor)
	var center: Vector2 = top_left + size * 0.5
	var radius: float = maxf(size.x, size.y) * 0.5

	# Turret / crane → silhouette of the base sprite + (turret only)
	# the head sprite(s) at the live aim angle. Falls back to a flat
	# rect for blocks with no base_sprite.
	var did_silhouette: bool = false
	if (bdata.is_turret() or bdata.tags.has("crane")) and bdata.base_sprite:
		_silhouette_targets.append({
			"tex": bdata.base_sprite,
			"pos": center,
			"angle": 0.0,
			"size": size,
		})
		did_silhouette = true
		# Turret heads, one per barrel, oriented by the live aim.
		if bdata.is_turret() and bdata.turret_head_sprite:
			_queue_turret_head_silhouettes(anchor, bdata, center)
	# Core: silhouette its base sprite filled to the footprint.
	elif bdata.tags.has("core") and bdata.base_sprite:
		_silhouette_targets.append({
			"tex": bdata.base_sprite,
			"pos": center,
			"angle": 0.0,
			"size": size,
		})
		did_silhouette = true

	if not did_silhouette:
		var fill := Color(1.0, 0.85, 0.2, alpha)
		_ctrl_hover_overlay.draw_rect(Rect2(top_left, size), fill, true)
	_paint_ctrl_hover_arrows(center, radius + 10.0)


## Queues one silhouette draw per turret barrel head, rotated to match
## the live per-barrel aim from CombatSystem. Falls back to the chassis
## aim if the per-barrel array hasn't been seeded yet.
func _queue_turret_head_silhouettes(anchor: Vector2i, bdata: BlockData, center: Vector2) -> void:
	var head_tex: Texture2D = bdata.turret_head_sprite
	if head_tex == null:
		return
	var combat = main.get_node_or_null("CombatSystem")
	var chassis_aim: float = float(main.building_rotation.get(anchor, 0)) * (PI * 0.5)
	if combat and "turret_angles" in combat and combat.turret_angles.has(anchor):
		chassis_aim = float(combat.turret_angles[anchor])
	var barrels: Array = []
	if combat and "turret_barrel_angles" in combat and combat.turret_barrel_angles.has(anchor):
		barrels = combat.turret_barrel_angles[anchor]
	var bcount: int = maxi(bdata.barrel_count, 1)
	var tex_size: Vector2 = head_tex.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
	var chassis_dir := Vector2.from_angle(chassis_aim)
	var chassis_perp := Vector2(-chassis_dir.y, chassis_dir.x)
	# Multi-barrel chassis plate.
	if bcount > 1 and bdata.turret_chassis_sprite:
		var ctex: Texture2D = bdata.turret_chassis_sprite
		var csize: Vector2 = ctex.get_size() * 0.3 * main.SPRITE_SCALE_FACTOR
		_silhouette_targets.append({
			"tex": ctex,
			"pos": center,
			"angle": chassis_aim + PI * 0.5,
			"size": csize,
		})
	# Each head — the live render rect is offset along the barrel axis
	# by `(-tex_size.y * 0.5 + 14 * sf)`. We bake that offset into the
	# silhouette pose by translating along the barrel direction.
	for i in range(bcount):
		var lateral: float = 0.0
		if bcount > 1:
			lateral = (float(i) - (float(bcount) - 1.0) * 0.5) * bdata.barrel_spacing
		var barrel_aim: float = chassis_aim
		if i < barrels.size():
			barrel_aim = float(barrels[i])
		var pivot: Vector2 = center + chassis_perp * lateral
		var bdir := Vector2.from_angle(barrel_aim)
		var head_offset: float = -tex_size.y * 0.5 + 14.0 * main.SPRITE_SCALE_FACTOR
		# `head_offset` is measured along the barrel "up" axis in the
		# live draw (after the +PI/2 rotation), which maps to forward
		# along bdir. Push the head out by `-head_offset` so it lands
		# in front of the pivot.
		var head_center: Vector2 = pivot + bdir * (-head_offset)
		_silhouette_targets.append({
			"tex": head_tex,
			"pos": head_center,
			"angle": barrel_aim + PI * 0.5,
			"size": tex_size,
		})


## Unit-style overlay: re-draw the unit's sprite onto the overlay
## canvas tinted yellow, so the controlled unit reads as a glowing
## silhouette. Shape-fallback units get a filled yellow disc the size
## of `unit_size` instead.
func _paint_ctrl_overlay_for_unit(unit: Node2D, alpha: float) -> void:
	if _ctrl_hover_overlay == null:
		return
	var udata = unit.data if "data" in unit else null
	var fill := Color(1.0, 0.85, 0.2, alpha)
	var u_radius: float = float(unit.unit_size) if "unit_size" in unit else 18.0
	if udata != null and (udata.base_sprite != null or udata.head_sprite != null):
		var scale_f: float = (udata.sprite_scale if udata.sprite_scale > 0.0 else 1.0) * main.SPRITE_SCALE_FACTOR
		var face_angle: float = float(unit.facing_angle) if "facing_angle" in unit else 0.0
		var aim_angle: float = float(unit.aim_angle) if "aim_angle" in unit else face_angle
		# Match the live draw's per-unit art-orientation correction so the
		# silhouette lines up with the visible chassis / head (was missing,
		# leaving the overlay un-rotated relative to flipped art like Wade's).
		var spr_off: float = udata.sprite_angle_offset if "sprite_angle_offset" in udata else 0.0
		var sprite_max: float = 0.0
		if udata.base_sprite:
			var b_size: Vector2 = udata.base_sprite.get_size() * scale_f
			sprite_max = maxf(sprite_max, maxf(b_size.x, b_size.y))
			_silhouette_targets.append({
				"tex": udata.base_sprite,
				"pos": unit.position,
				"angle": face_angle + PI * 0.5 + spr_off,
				"size": b_size,
			})
		if udata.head_sprite:
			var h_size: Vector2 = udata.head_sprite.get_size() * scale_f
			sprite_max = maxf(sprite_max, maxf(h_size.x, h_size.y))
			_silhouette_targets.append({
				"tex": udata.head_sprite,
				"pos": unit.position,
				"angle": aim_angle + PI * 0.5 + spr_off,
				"size": h_size,
			})
		u_radius = maxf(u_radius, sprite_max * 0.5)
	else:
		# No sprite — fall back to a solid disc on the main overlay.
		_ctrl_hover_overlay.draw_circle(unit.position, u_radius, fill)
	_paint_ctrl_hover_arrows(unit.position, u_radius)


## Draws the queued silhouette sprites on the shader-material'd sub-canvas.
## Receives one entry per sprite (base + head), each with a pre-rotated
## transform — the shader replaces RGB with the silhouette color while
## the texture's alpha mask shapes the silhouette.
func _draw_ctrl_hover_silhouette() -> void:
	if _ctrl_hover_silhouette == null:
		return
	for s in _silhouette_targets:
		var tex: Texture2D = s.get("tex")
		if tex == null:
			continue
		var pos: Vector2 = s.get("pos", Vector2.ZERO)
		var ang: float = s.get("angle", 0.0)
		var sz: Vector2 = s.get("size", Vector2.ZERO)
		_ctrl_hover_silhouette.draw_set_transform(pos, ang, Vector2.ONE)
		_ctrl_hover_silhouette.draw_texture_rect(tex, Rect2(-sz * 0.5, sz), false)
		_ctrl_hover_silhouette.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _paint_ctrl_hover_arrows(center: Vector2, target_radius: float) -> void:
	if _ctrl_hover_overlay == null:
		return
	var orbit_r: float = target_radius + 24.0
	var arrow_len: float = 20.0
	var arrow_half: float = 12.0
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
