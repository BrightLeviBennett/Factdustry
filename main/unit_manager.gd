extends Node2D

# ============================================================
# UNIT_MANAGER.GD - Coordinates All Units
# ============================================================
# Uses Registry to look up unit data. Spawning an enemy now
# takes a UnitData ID, and the enemy loads its own stats.
# ============================================================

@onready var main: Node2D = get_node("/root/Main")

var enemy_script = preload("res://main/enemy_unit.gd")
var nest_script = preload("res://main/enemy_nest.gd")

# --- PATHFINDING ---
var astar: AStarGrid2D              # GROUND layer pathfinding (main thread — WASD only)
var astar_crawler: AStarGrid2D      # CRAWLER layer pathfinding (main thread — WASD only)
var astar_hover: AStarGrid2D        # HOVER layer pathfinding (blocked only by large terrain walls)
var _crawler_passable_walls: Dictionary = {}  # Vector2i -> true (small wall segments, < 4)
var _hover_passable_walls: Dictionary = {}    # Vector2i -> true (wall segments <= 8)
var _path_worker: PathfindingWorker  # Background thread for enemy/unit pathfinding

# --- TRACKING ---
var enemies: Array[Node2D] = []
var player_units: Array[Node2D] = []
var nests: Array[Node2D] = []

# --- SETTINGS ---
@export var path_update_interval := 2.0
var path_update_timer := 0.0

# --- COLLISION ---
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


func _ready() -> void:
	# Wait for Registry and main to initialize
	await get_tree().process_frame

	_setup_astar()
	_setup_path_worker()
	main.building_placed.connect(_on_building_placed)
	call_deferred("_spawn_test_nests")


func _exit_tree() -> void:
	if _path_worker:
		_path_worker.stop()
		_path_worker = null


func _process(delta: float) -> void:
	# Use deferred reset so the flag survives through all _process calls this frame
	call_deferred("_clear_handled_flag")

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

	# 2. Ferox building under cursor?
	var grid_pos: Vector2i = main.world_to_grid(world_pos)
	if main.placed_buildings.has(grid_pos):
		var faction: int = main.get_building_faction(grid_pos)
		if faction == main.Faction.FEROX:
			var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
			_command_attack_building(anchor)
			return

	# 3. Otherwise move there
	_command_move(world_pos)


## Assigns an enemy unit as the manual target for all selected units.
func _command_attack_unit(enemy: Node2D) -> void:
	for unit in selected_units:
		if not is_instance_valid(unit) or unit.is_dead:
			continue
		if unit == controlled_entity:
			continue
		unit.manual_target_unit = enemy
		unit.manual_target_building = null
		unit.move_target = null
		unit.target_unit = enemy
		unit.target_building = null
		unit.path = PackedVector2Array()
		unit.path_index = 0


## Assigns a building as the manual target for all selected units.
func _command_attack_building(bldg_anchor: Vector2i) -> void:
	for unit in selected_units:
		if not is_instance_valid(unit) or unit.is_dead:
			continue
		if unit == controlled_entity:
			continue
		unit.manual_target_building = bldg_anchor
		unit.manual_target_unit = null
		unit.move_target = null
		unit.target_building = bldg_anchor
		unit.target_unit = null
		unit.path = PackedVector2Array()
		unit.path_index = 0


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
			living.append(unit)

	if living.size() == 0:
		return

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
	var combat = get_node_or_null("/root/Main/CombatSystem")
	if combat:
		combat.manually_controlled_turret = grid_pos


func _take_control_of_crane(anchor: Vector2i) -> void:
	_release_control()
	_deselect_all()
	controlled_entity = anchor
	controlled_type = "crane"
	# Initialize crane state in building system
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
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
	if controlled_type == "unit":
		var unit: Node2D = controlled_entity
		if is_instance_valid(unit):
			unit.is_controlled = false
	elif controlled_type == "turret":
		var combat = get_node_or_null("/root/Main/CombatSystem")
		if combat:
			combat.manually_controlled_turret = null
	# Crane keeps its state (may be holding a payload)
	controlled_entity = null
	controlled_type = ""
	# Respawn the shardling at the core
	var drone = get_node_or_null("/root/Main/PlayerDrone")
	if drone:
		drone._move_to_core()


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


func _update_controlled_crane(delta: float) -> void:
	var anchor: Vector2i = controlled_entity
	if not main.placed_buildings.has(anchor):
		_release_control()
		return

	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
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
	var drone = get_node_or_null("/root/Main/PlayerDrone")
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
			var building_sys_q = get_node_or_null("/root/Main/BuildingSystem")
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


func _crane_interact(anchor: Vector2i, state: Dictionary, crane_center: Vector2, max_reach: float) -> void:
	# Compute grabber position: slides along the arm to match the mouse distance
	var arm_angle: float = state.get("arm_angle", 0.0)
	var arm_ext: float = state.get("arm_extension", 0.0)
	var arm_dir: Vector2 = Vector2(cos(arm_angle), sin(arm_angle))
	var target_pos: Vector2 = state.get("target_pos", crane_center)
	var to_target_dist: float = (target_pos - crane_center).length()
	var grabber_t: float = clampf(to_target_dist / arm_ext, 0.0, 1.0) if arm_ext > 1.0 else 1.0
	var grabber_world: Vector2 = crane_center + arm_dir * (grabber_t * arm_ext)
	var grid_target: Vector2i = main.world_to_grid(grabber_world)

	if state["held_payload"] == null:
		# First: check if there's a payload on a conveyor at this position
		var logistics = get_node_or_null("/root/Main/LogisticsSystem")
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
		var logistics = get_node_or_null("/root/Main/LogisticsSystem")

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
			var combat = get_node_or_null("/root/Main/CombatSystem")
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


func _update_controlled_turret(delta: float) -> void:
	var grid_pos: Vector2i = controlled_entity
	if not main.placed_buildings.has(grid_pos):
		_release_control()
		return

	var combat = get_node_or_null("/root/Main/CombatSystem")
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
				var logistics = get_node_or_null("/root/Main/LogisticsSystem")
				var fire_damage: float = bdata.attack_damage
				var fire_color: Color = bdata.color.lightened(0.3)
				var fire_reload_mult: float = 1.0
				var fire_speed: float = combat.default_projectile_speed
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
							ammo_found = true
							break
				if not ammo_found:
					return  # Out of ammo — can't fire even when manually controlled

				_control_attack_timer = bdata.attack_speed * fire_reload_mult
				var barrel_length: float = main.GRID_SIZE * 0.4
				var fire_pos: Vector2 = turret_world + Vector2.from_angle(target_angle) * barrel_length
				var direction: Vector2 = (mouse_pos - fire_pos).normalized()
				var fire_range: float = bdata.attack_range * main.GRID_SIZE
				var target_pos: Vector2 = fire_pos + direction * fire_range
				combat._spawn_projectile(
					fire_pos,
					null,
					target_pos,
					"none",
					fire_speed,
					fire_damage,
					fire_color,
					"turret",
					bdata.is_aoe,
					bdata.aoe_radius,
					main.Faction.LUMINA,
				)


# =========================
# PATHFINDING SETUP
# =========================

func _setup_astar() -> void:
	# --- GROUND AStar (blocked by all buildings + terrain walls) ---
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, main.GRID_WIDTH, main.GRID_HEIGHT)
	astar.cell_size = Vector2(main.GRID_SIZE, main.GRID_SIZE)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.update()

	# --- CRAWLER AStar (small wall segments passable) ---
	astar_crawler = AStarGrid2D.new()
	astar_crawler.region = Rect2i(0, 0, main.GRID_WIDTH, main.GRID_HEIGHT)
	astar_crawler.cell_size = Vector2(main.GRID_SIZE, main.GRID_SIZE)
	astar_crawler.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar_crawler.update()

	# Mark terrain walls as solid in GROUND grid
	var terrain_sys = get_node_or_null("/root/Main/TerrainSystem")
	if terrain_sys:
		for grid_pos in terrain_sys.wall_tiles:
			var tile_data = Registry.get_tile(terrain_sys.wall_tiles[grid_pos])
			if tile_data and tile_data.blocks_pathfinding:
				astar.set_point_solid(grid_pos, true)

	# Mark existing buildings as solid in GROUND grid
	# Transport buildings (conveyors, pipes, bridges, etc.) are passable for ground units
	for grid_pos in main.placed_buildings:
		if not _is_ground_passable_building(grid_pos):
			astar.set_point_solid(grid_pos, true)

	# Mark building walls as solid in CRAWLER grid
	for grid_pos in main.placed_buildings:
		if _is_building_wall(grid_pos):
			astar_crawler.set_point_solid(grid_pos, true)

	# --- HOVER AStar (blocked only by large terrain wall segments) ---
	astar_hover = AStarGrid2D.new()
	astar_hover.region = Rect2i(0, 0, main.GRID_WIDTH, main.GRID_HEIGHT)
	astar_hover.cell_size = Vector2(main.GRID_SIZE, main.GRID_SIZE)
	astar_hover.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar_hover.update()

	# Analyze terrain wall segments for crawler passability
	_recompute_crawler_wall_passability()

	# Mark hidden tiles as solid in ALL grids (impassable barrier)
	var sector_script = get_node_or_null("/root/Main/SectorScript")
	if sector_script:
		for x in range(main.GRID_WIDTH):
			for y in range(main.GRID_HEIGHT):
				var gp := Vector2i(x, y)
				if sector_script.is_tile_hidden(gp):
					astar.set_point_solid(gp, true)
					astar_crawler.set_point_solid(gp, true)
					astar_hover.set_point_solid(gp, true)


func _setup_path_worker() -> void:
	var terrain_sys = get_node_or_null("/root/Main/TerrainSystem")

	# GROUND solids: non-transport buildings + terrain walls that block pathfinding
	var ground_solids: Array[Vector2i] = []
	for grid_pos in main.placed_buildings:
		if not _is_ground_passable_building(grid_pos):
			ground_solids.append(grid_pos)
	if terrain_sys:
		for grid_pos in terrain_sys.wall_tiles:
			var tile_data = Registry.get_tile(terrain_sys.wall_tiles[grid_pos])
			if tile_data and tile_data.blocks_pathfinding and not ground_solids.has(grid_pos):
				ground_solids.append(grid_pos)

	# CRAWLER solids: building walls + large terrain wall segments (>= 4 cells)
	var crawler_solids: Array[Vector2i] = []
	for grid_pos in main.placed_buildings:
		if _is_building_wall(grid_pos):
			crawler_solids.append(grid_pos)
	if terrain_sys:
		for grid_pos in terrain_sys.wall_tiles:
			if not _crawler_passable_walls.has(grid_pos):
				crawler_solids.append(grid_pos)

	# HOVER solids: only large terrain wall segments (> 8 cells)
	var hover_solids: Array[Vector2i] = []
	if terrain_sys:
		for grid_pos in terrain_sys.wall_tiles:
			if not _hover_passable_walls.has(grid_pos):
				hover_solids.append(grid_pos)

	# Add hidden tiles to all solid lists (impassable barrier)
	var sector_script = get_node_or_null("/root/Main/SectorScript")
	if sector_script:
		for x in range(main.GRID_WIDTH):
			for y in range(main.GRID_HEIGHT):
				var gp := Vector2i(x, y)
				if sector_script.is_tile_hidden(gp):
					if not ground_solids.has(gp):
						ground_solids.append(gp)
					if not crawler_solids.has(gp):
						crawler_solids.append(gp)
					if not hover_solids.has(gp):
						hover_solids.append(gp)

	_path_worker = PathfindingWorker.new()
	_path_worker.start(main.GRID_WIDTH, main.GRID_HEIGHT, main.GRID_SIZE,
		ground_solids, crawler_solids, hover_solids)


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

		unit.set_path(path, target_bldg)


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
	var data = Registry.get_block(_block_id)
	var is_passable: bool = data != null and (data.transport_speed > 0 or data.transports_fluid)
	var is_wall: bool = data != null and data.category == BlockData.BlockCategory.WALLS

	if data:
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				var tile_pos = grid_pos + Vector2i(x, y)
				if main.is_within_bounds(tile_pos):
					# GROUND: solid unless transport building
					if not is_passable:
						astar.set_point_solid(tile_pos, true)
					if _path_worker and not is_passable:
						_path_worker.queue_set_solid(tile_pos, true, "ground")
					# CRAWLER: only walls block
					if is_wall:
						astar_crawler.set_point_solid(tile_pos, true)
						if _path_worker:
							_path_worker.queue_set_solid(tile_pos, true, "crawler")
					# HOVER: buildings never block hover
	else:
		astar.set_point_solid(grid_pos, true)
		if _path_worker:
			_path_worker.queue_set_solid(grid_pos, true, "ground")

	_update_all_enemy_paths()


func on_building_destroyed(grid_pos: Vector2i) -> void:
	# Clear from all grids (safe even if it wasn't solid in some)
	astar.set_point_solid(grid_pos, false)
	astar_crawler.set_point_solid(grid_pos, false)
	# Don't clear hover — buildings never blocked hover
	if _path_worker:
		_path_worker.queue_set_solid(grid_pos, false, "ground")
		_path_worker.queue_set_solid(grid_pos, false, "crawler")


# =========================
# SPAWNING
# =========================

## Spawns an enemy of the given UnitData ID at the given position.
func spawn_enemy(spawn_position: Vector2, unit_id: StringName = &"basic_cell") -> void:
	var unit_data = Registry.get_unit(unit_id)
	if unit_data == null:
		push_warning("UnitManager: Unit '%s' not found in Registry — using fallback stats." % unit_id)

	var enemy = Node2D.new()
	enemy.set_script(enemy_script)
	enemy.data = unit_data  # Pass the UnitData resource (may be null — enemy uses fallbacks)
	enemy.team = UnitData.Team.ENEMY
	enemy.main = main
	enemy.unit_manager = self
	enemy.position = spawn_position

	add_child(enemy)
	enemies.append(enemy)
	_assign_path_to_enemy(enemy)


## Spawns a player unit at the given position (produced by a fabricator).
func spawn_player_unit(spawn_position: Vector2, unit_id: StringName) -> void:
	var unit_data = Registry.get_unit(unit_id)
	if unit_data == null:
		push_warning("UnitManager: Unit '%s' not found in Registry!" % unit_id)
		return

	var unit = Node2D.new()
	unit.set_script(enemy_script)
	unit.data = unit_data
	unit.team = UnitData.Team.PLAYER
	unit.main = main
	unit.unit_manager = self
	unit.position = spawn_position

	add_child(unit)
	player_units.append(unit)
	# Player units don't pathfind to buildings — they idle at spawn


func spawn_nest(nest_position: Vector2) -> void:
	var nest = Node2D.new()
	nest.set_script(nest_script)
	nest.main = main
	nest.unit_manager = self
	nest.position = nest_position
	add_child(nest)
	nests.append(nest)


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

	var enemy_grid: Vector2i = main.world_to_grid(enemy.position)
	enemy_grid.x = clampi(enemy_grid.x, 0, main.GRID_WIDTH - 1)
	enemy_grid.y = clampi(enemy_grid.y, 0, main.GRID_HEIGHT - 1)

	# Units should only target opposing-faction buildings, not their own
	var exclude_faction: int = -1
	if enemy.team == UnitData.Team.ENEMY:
		exclude_faction = main.Faction.FEROX
	elif enemy.team == UnitData.Team.PLAYER:
		exclude_faction = main.Faction.LUMINA
	var nearest_building = _find_nearest_building(enemy_grid, exclude_faction)
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


func _find_nearest_building(from: Vector2i, exclude_faction: int = -1) -> Variant:
	var nearest: Variant = null
	var nearest_dist := 999999.0

	for grid_pos in main.placed_buildings:
		if exclude_faction >= 0 and main.get_building_faction(grid_pos) == exclude_faction:
			continue
		var dx = abs(grid_pos.x - from.x)
		var dy = abs(grid_pos.y - from.y)
		var dist = max(dx, dy) as float
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = grid_pos

	return nearest


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
		var sector_script = get_node_or_null("/root/Main/SectorScript")
		if sector_script:
			sector_script.on_ferox_unit_destroyed(enemy.data.id)


func on_player_unit_died(unit: Node2D) -> void:
	player_units.erase(unit)
	selected_units.erase(unit)
	main.stats_units_destroyed += 1


func on_nest_destroyed(nest: Node2D) -> void:
	nests.erase(nest)


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
	return data.transport_speed > 0 or data.transports_fluid


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

	var terrain_sys = get_node_or_null("/root/Main/TerrainSystem")
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

	# Draw control indicator for manually controlled turret
	if controlled_entity != null and controlled_type == "turret":
		var grid_pos: Vector2i = controlled_entity
		var center: Vector2 = main.grid_to_world(grid_pos) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
		var ring_radius: float = main.GRID_SIZE * 0.55
		draw_arc(center, ring_radius, 0, TAU, 24, Color(0.3, 0.8, 1.0, 0.8), 2.0)
		draw_arc(center, ring_radius + 1.5, 0, TAU, 24, Color(0.3, 0.8, 1.0, 0.3), 1.0)

	# Draw move-target diamonds and path lines for selected units — unit mode only
	if unit_mode_active:
		_draw_move_targets()


## Draws a small diamond at each selected unit's move target and a line from
## the unit to the diamond, using the same gold color as the selection ring.
func _draw_move_targets() -> void:
	const LINE_COLOR := Color(1.0, 0.84, 0.0, 0.45)
	const DIAMOND_COLOR := Color(1.0, 0.84, 0.0, 0.8)
	const DIAMOND_SIZE := 5.0

	# Collect unique move targets so we only draw each diamond once
	var drawn_diamonds: Dictionary = {}  # Vector2 → true

	for unit in selected_units:
		if not is_instance_valid(unit) or unit.is_dead:
			continue
		if unit.move_target == null:
			continue

		var target: Vector2 = unit.move_target

		# Draw line from unit to its move target
		draw_line(unit.position, target, LINE_COLOR, 1.0)

		# Draw diamond at the target (only once per unique position)
		var key := Vector2(snapped(target.x, 0.5), snapped(target.y, 0.5))
		if not drawn_diamonds.has(key):
			drawn_diamonds[key] = true
			var d := DIAMOND_SIZE
			var diamond := PackedVector2Array([
				target + Vector2(0, -d),
				target + Vector2(d, 0),
				target + Vector2(0, d),
				target + Vector2(-d, 0),
			])
			draw_colored_polygon(diamond, DIAMOND_COLOR)
			draw_polyline(
				PackedVector2Array([
					target + Vector2(0, -d),
					target + Vector2(d, 0),
					target + Vector2(0, d),
					target + Vector2(-d, 0),
					target + Vector2(0, -d),
				]),
				Color(1.0, 0.84, 0.0, 1.0), 1.5
			)
