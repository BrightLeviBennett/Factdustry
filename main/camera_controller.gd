extends Camera2D

# ============================================================
# CAMERA_CONTROLLER.GD - Camera That Follows The Drone
# ============================================================

@export var zoom_speed := 0.1
## Drop the floor a long way so the player can pull back far enough to
## survey a whole sector at once. The renderer already culls offscreen
## tiles so the cost is bounded.
@export var min_zoom := 0.08
@export var max_zoom := 3.0
@export var zoom_smoothing := 8.0
@export var follow_smoothing := 6.0
@export var pan_speed := 500.0

var target_zoom := 1.0

## When set, the camera focuses on this world position instead of the drone/unit.
## Set to null to return to normal following.
var focus_override: Variant = null  # Vector2 or null

# Cached sibling references (populated in _ready after one process frame).
var _main: Node
var _unit_mgr: Node
var _drone: Node2D



func _main_ref() -> Node:
	if _main == null:
		_main = get_node_or_null("/root/Main")
	return _main

func _unit_mgr_ref() -> Node:
	if _unit_mgr == null:
		_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	return _unit_mgr

func _drone_ref() -> Node2D:
	if _drone == null:
		_drone = get_node_or_null("/root/Main/PlayerDrone")
	return _drone


func _ready() -> void:
	make_current()
	target_zoom = zoom.x
	await get_tree().process_frame
	_main = get_node_or_null("/root/Main")
	_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	_drone = get_node_or_null("/root/Main/PlayerDrone")


## Throttle trackpad rotation to avoid spinning too fast
var _pan_rotate_accum := 0.0
## How much trackpad scroll delta is needed to trigger one rotation step.
## Lower = more sensitive. Adjustable via settings.
var pan_rotate_threshold := 1.5


func _input(event: InputEvent) -> void:
	var main_node = _main_ref()
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
			if _pan_rotate_accum <= -pan_rotate_threshold:
				_rotate_selected_block(1)  # Scroll up = clockwise
				_pan_rotate_accum = 0.0
			elif _pan_rotate_accum >= pan_rotate_threshold:
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
	var main_node = _main_ref()
	if not main_node:
		return
	if direction > 0:
		main_node.placement_rotation = (main_node.placement_rotation + 1) % 4
	else:
		main_node.placement_rotation = (main_node.placement_rotation + 3) % 4


func _process(delta: float) -> void:
	var main_node = _main_ref()
	var unit_mgr = _unit_mgr_ref()
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
			var drone = _drone_ref()
			if drone:
				follow_target = drone.position
				has_target = true

		if has_target:
			position = position.lerp(follow_target, delta * follow_smoothing)

	# Polish: drive the Camera2D's `offset` from FeedbackSystem so any
	# damage / explosion can shake the view without fighting `position`
	# (which is the smoothed follow target). offset = 0 when the system
	# isn't around or no shake is active.
	var fb = get_node_or_null("/root/Main/FeedbackSystem")
	if fb and fb.has_method("shake_offset"):
		offset = fb.shake_offset()
	else:
		offset = Vector2.ZERO

	# Zoom-punch (one-shot tween from LaunchAnimation.land): override
	# `target_zoom` for `_zoom_punch_total` seconds, easing back to
	# the player's preferred zoom. Camera shake handles the shake half
	# of the "landed" feel; this handles the wider-FoV reveal of the
	# new map.
	if _zoom_punch_time > 0.0:
		_zoom_punch_time -= delta
		var t: float = clampf(1.0 - _zoom_punch_time / _zoom_punch_total, 0.0, 1.0)
		var current_target: float = lerpf(_zoom_punch_value, _zoom_punch_return, ease(t, 2.0))
		var new_zoom_p = lerp(zoom.x, current_target, delta * zoom_smoothing)
		zoom = Vector2(new_zoom_p, new_zoom_p)
	else:
		# Skip our smoothing while the launch animation is actively
		# driving the camera — it writes `zoom` directly each frame, and
		# our lerp would otherwise drag it back toward `target_zoom`
		# at smoothing-speed, muting the dramatic zoom curve.
		# Only the LANDING (1) and LAUNCHING (4) phases drive zoom — the
		# ring-sweep / paused states should let the player zoom normally.
		var la = get_node_or_null("/root/Main/LaunchAnimation")
		var la_owns_zoom: bool = false
		if la != null and "state" in la:
			var s := int(la.state)
			la_owns_zoom = (s == 1 or s == 4)
		if not la_owns_zoom:
			var new_zoom = lerp(zoom.x, target_zoom, delta * zoom_smoothing)
			zoom = Vector2(new_zoom, new_zoom)

	# Redraw building system for parallax. During scene swaps the
	# BuildingSystem may have already been freed by the time _process
	# fires, so resolve defensively rather than crashing on a null
	# deref.
	var bs := get_node_or_null("/root/Main/BuildingSystem")
	if bs:
		bs.queue_redraw()


# Zoom-punch state (set by `kick_zoom_punch`).
var _zoom_punch_time: float = 0.0
var _zoom_punch_total: float = 1.0
var _zoom_punch_value: float = 1.0
var _zoom_punch_return: float = 1.0


## One-shot zoom override for a sector landing / dramatic moment.
## `start` = zoom value at t=0, `end` = zoom value at t=duration.
## After the punch ends, normal zoom smoothing resumes toward
## `target_zoom`.
func kick_zoom_punch(start: float, end: float, duration: float) -> void:
	_zoom_punch_total = maxf(duration, 0.01)
	_zoom_punch_time = _zoom_punch_total
	_zoom_punch_value = start
	_zoom_punch_return = end
	zoom = Vector2(start, start)
