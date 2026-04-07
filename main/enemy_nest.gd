extends Node2D

# ============================================================
# ENEMY_NEST.GD - Enemy Spawner
# ============================================================
# Spawns enemies using their StringName IDs from the Registry.
# The spawn_unit_id determines which .tres unit type to spawn.
# ============================================================

# --- SETTINGS ---
@export var max_health := 200.0
@export var spawn_interval := 10.0
@export var nest_color := Color(0.9, 0.2, 0.5)
@export var nest_size := 20.0

# Which unit type to spawn (references a UnitData .tres by ID)
var spawn_unit_id: StringName = &"basic_cell"

# --- STATE ---
var health: float
var spawn_timer: float
var is_dead := false

# --- REFERENCES ---
var main: Node2D
var unit_manager: Node2D


func _ready() -> void:
	health = max_health
	spawn_timer = randf_range(2.0, spawn_interval)

	# Load spawn count from the unit data
	var unit_data = Registry.get_unit(spawn_unit_id)
	if unit_data:
		nest_color = unit_data.color.darkened(0.2)


func _process(delta: float) -> void:
	if is_dead:
		return

	spawn_timer -= delta
	if spawn_timer <= 0:
		spawn_timer = spawn_interval
		_spawn_wave()

	queue_redraw()


func _spawn_wave() -> void:
	var unit_data = Registry.get_unit(spawn_unit_id)
	var count = unit_data.spawn_count if unit_data else 3

	for i in range(count):
		var angle = randf() * TAU
		var dist = randf_range(30.0, 60.0)
		var spawn_pos = position + Vector2(cos(angle), sin(angle)) * dist
		unit_manager.spawn_enemy(spawn_pos, spawn_unit_id)


func take_damage(amount: float) -> void:
	health -= amount
	if health <= 0 and not is_dead:
		is_dead = true
		_on_death()


func _on_death() -> void:
	unit_manager.on_nest_destroyed(self)
	queue_free()


# --- DRAWING ---
func _draw() -> void:
	if is_dead:
		return

	var points = PackedVector2Array()
	var colors = PackedColorArray()
	for i in range(6):
		var angle = i * TAU / 6.0
		points.append(Vector2(cos(angle), sin(angle)) * nest_size)
		colors.append(nest_color)

	draw_polygon(points, colors)

	var outline_points = PackedVector2Array()
	for i in range(7):
		var angle = i * TAU / 6.0
		outline_points.append(Vector2(cos(angle), sin(angle)) * nest_size)
	draw_polyline(outline_points, nest_color.lightened(0.3), 2.0)

	draw_circle(Vector2.ZERO, nest_size * 0.5, nest_color.lightened(0.2))

	_draw_health_bar()


func _draw_health_bar() -> void:
	if health >= max_health:
		return

	var bar_width := 40.0
	var bar_height := 4.0
	var bar_offset := Vector2(-bar_width / 2.0, -nest_size - 10.0)

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
