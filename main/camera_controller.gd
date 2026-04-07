extends Camera2D

# ============================================================
# CAMERA_CONTROLLER.GD - Camera That Follows The Drone
# ============================================================

@export var zoom_speed := 0.1
@export var min_zoom := 0.3
@export var max_zoom := 3.0
@export var zoom_smoothing := 8.0
@export var follow_smoothing := 6.0
@export var pan_speed := 500.0

var target_zoom := 1.0

## When set, the camera focuses on this world position instead of the drone/unit.
## Set to null to return to normal following.
var focus_override: Variant = null  # Vector2 or null


func _ready() -> void:
	make_current()
	target_zoom = zoom.x


## Throttle trackpad rotation to avoid spinning too fast
var _pan_rotate_accum := 0.0
const PAN_ROTATE_THRESHOLD := 1.5


func _input(event: InputEvent) -> void:
	var main_node = get_node_or_null("/root/Main")
	# Don't handle zoom/rotate when any blocking UI is open
	if main_node and main_node.is_ui_blocking():
		return
	# Don't consume scroll events if the mouse is over a GUI control (block menu, etc.)
	if (event is InputEventMouseButton or event is InputEventPanGesture) and get_viewport().gui_get_hovered_control() != null:
		return
	var has_block_selected: bool = main_node and main_node.selected_building != &""

	# Standard mouse wheel
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if has_block_selected:
				_rotate_selected_block(1)  # Clockwise
			else:
				target_zoom = min(target_zoom + zoom_speed, max_zoom)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if has_block_selected:
				_rotate_selected_block(-1)  # Counter-clockwise
			else:
				target_zoom = max(target_zoom - zoom_speed, min_zoom)
			get_viewport().set_input_as_handled()
	# macOS trackpad two-finger scroll (pan gesture)
	elif event is InputEventPanGesture:
		if has_block_selected:
			# Accumulate scroll delta and rotate when threshold is reached
			_pan_rotate_accum += event.delta.y
			if _pan_rotate_accum <= -PAN_ROTATE_THRESHOLD:
				_rotate_selected_block(1)  # Scroll up = clockwise
				_pan_rotate_accum = 0.0
			elif _pan_rotate_accum >= PAN_ROTATE_THRESHOLD:
				_rotate_selected_block(-1)  # Scroll down = counter-clockwise
				_pan_rotate_accum = 0.0
		else:
			if event.delta.y < 0:
				target_zoom = min(target_zoom + zoom_speed * absf(event.delta.y) * 0.5, max_zoom)
			elif event.delta.y > 0:
				target_zoom = max(target_zoom - zoom_speed * absf(event.delta.y) * 0.5, min_zoom)
		get_viewport().set_input_as_handled()
	# macOS trackpad pinch-to-zoom (always zoom, even with block selected)
	elif event is InputEventMagnifyGesture:
		if event.factor > 1.0:
			target_zoom = min(target_zoom + zoom_speed * (event.factor - 1.0) * 5.0, max_zoom)
		elif event.factor < 1.0:
			target_zoom = max(target_zoom - zoom_speed * (1.0 - event.factor) * 5.0, min_zoom)
		get_viewport().set_input_as_handled()


func _rotate_selected_block(direction: int) -> void:
	var main_node = get_node_or_null("/root/Main")
	if not main_node:
		return
	if direction > 0:
		main_node.placement_rotation = (main_node.placement_rotation + 1) % 4
	else:
		main_node.placement_rotation = (main_node.placement_rotation + 3) % 4


func _process(delta: float) -> void:
	var main_node = get_node_or_null("/root/Main")
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	var is_paused: bool = main_node.world_paused if main_node else false

	# When paused: free camera pan with WASD, nothing follows
	# But not when a blocking UI is open
	var ui_blocking: bool = main_node.is_ui_blocking() if main_node else false
	if is_paused and focus_override == null and not ui_blocking:
		var move_x: float = Input.get_axis("move_left", "move_right")
		var move_y: float = Input.get_axis("move_up", "move_down")
		var pan_velocity := Vector2(move_x, move_y)
		if pan_velocity.length() > 0:
			pan_velocity = pan_velocity.normalized()
			position += pan_velocity * pan_speed * delta / zoom.x
	else:
		# Priority: focus_override > controlled entity > drone
		var follow_target := Vector2.ZERO
		var has_target := false

		if focus_override != null and focus_override is Vector2:
			follow_target = focus_override as Vector2
			has_target = true
		elif unit_mgr and unit_mgr.controlled_entity != null:
			if unit_mgr.controlled_type == "unit":
				var unit: Node2D = unit_mgr.controlled_entity
				if is_instance_valid(unit):
					follow_target = unit.position
					has_target = true
			elif unit_mgr.controlled_type == "turret" and main_node:
				var grid_pos: Vector2i = unit_mgr.controlled_entity
				follow_target = main_node.grid_to_world(grid_pos) + Vector2(main_node.GRID_SIZE / 2.0, main_node.GRID_SIZE / 2.0)
				has_target = true

		if not has_target:
			var drone = get_node_or_null("/root/Main/PlayerDrone")
			if drone:
				follow_target = drone.position
				has_target = true

		if has_target:
			position = position.lerp(follow_target, delta * follow_smoothing)

	# Smoothly animate zoom
	var new_zoom = lerp(zoom.x, target_zoom, delta * zoom_smoothing)
	zoom = Vector2(new_zoom, new_zoom)

	# Redraw building system for parallax
	get_node("/root/Main/BuildingSystem").queue_redraw()
