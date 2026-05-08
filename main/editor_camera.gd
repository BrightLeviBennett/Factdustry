extends Camera2D

# ============================================================
# EDITOR_CAMERA.GD - Free-Roaming Camera for Map Editor
# ============================================================
# WASD to pan, scroll to zoom, middle-mouse drag to pan.
# No drone dependency — camera moves freely.
# ============================================================

@export var pan_speed := 600.0
## Multiplicative zoom step — each scroll-tick / hotkey press
## multiplies (or divides) the target zoom by `1 + zoom_step`. With
## additive steps the same scroll tick felt huge near `min_zoom` and
## invisible near `max_zoom`; multiplicative keeps it uniform across
## the whole range.
@export var zoom_step := 0.15
@export var min_zoom := 0.05
@export var max_zoom := 12.0
@export var zoom_smoothing := 8.0

var target_zoom := 0.5
var _mid_dragging := false
var _mid_drag_start := Vector2.ZERO


func _ready() -> void:
	make_current()
	zoom = Vector2(target_zoom, target_zoom)
	# Center on the grid
	var main = get_node("/root/Main")
	position = Vector2(
		main.GRID_WIDTH * main.GRID_SIZE / 2.0,
		main.GRID_HEIGHT * main.GRID_SIZE / 2.0
	)


func _process(delta: float) -> void:
	# WASD panning (faster when zoomed out)
	var move := Vector2.ZERO
	if Input.is_action_pressed("move_left"):
		move.x -= 1
	if Input.is_action_pressed("move_right"):
		move.x += 1
	if Input.is_action_pressed("move_up"):
		move.y -= 1
	if Input.is_action_pressed("move_down"):
		move.y += 1
	if move != Vector2.ZERO:
		position += move.normalized() * pan_speed * delta / zoom.x

	# Zoom input
	if Input.is_action_just_pressed("zoom_in"):
		target_zoom = clampf(target_zoom * (1.0 + zoom_step), min_zoom, max_zoom)
	if Input.is_action_just_pressed("zoom_out"):
		target_zoom = clampf(target_zoom / (1.0 + zoom_step), min_zoom, max_zoom)

	# Smooth zoom interpolation
	var new_zoom := lerpf(zoom.x, target_zoom, delta * zoom_smoothing)
	zoom = Vector2(new_zoom, new_zoom)

	# Redraw terrain for any zoom-dependent rendering
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if terrain:
		terrain.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	# Scroll wheel zoom
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			target_zoom = clampf(target_zoom * (1.0 + zoom_step), min_zoom, max_zoom)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			target_zoom = clampf(target_zoom / (1.0 + zoom_step), min_zoom, max_zoom)
		# Middle-mouse drag to pan
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				_mid_dragging = true
				_mid_drag_start = event.position
			else:
				_mid_dragging = false
	# Trackpad pinch/pan gesture zoom — convert the delta to a
	# multiplicative factor so trackpad and wheel feel the same.
	elif event is InputEventPanGesture:
		var factor: float = pow(1.0 + zoom_step, -event.delta.y * 0.3)
		target_zoom = clampf(target_zoom * factor, min_zoom, max_zoom)
	elif event is InputEventMouseMotion and _mid_dragging:
		# Move camera opposite to mouse delta, scaled by zoom
		position -= event.relative / zoom.x
