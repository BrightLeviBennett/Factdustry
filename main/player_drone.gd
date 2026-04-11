extends Node2D

# ============================================================
# PLAYER_DRONE.GD - The Player's Builder Drone
# ============================================================
# Stats (health, speed, etc.) are loaded from the
# player_drone.tres UnitData resource via the Registry.
# ============================================================

@onready var main: Node2D = get_node("/root/Main")

# --- TEXTURE ---
var drone_texture: Texture2D = preload("res://textures/units/Shardling.png")

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

# --- FACING ---
var facing_angle := PI             # Current visual rotation (radians)
var _target_facing_angle := PI     # Target rotation (persists when input stops)
const ROTATION_SPEED := 6.0      # How fast the drone turns (radians/sec)
## How far (in pixels) to shift the sprite along its local "up" axis
## so the body center sits at the pivot. Positive = shift body toward pivot.
const SPRITE_PIVOT_OFFSET := 0.05  # Fraction of tex_size to shift

# Visual settings (loaded from .tres)
var drone_color: Color
var range_color: Color
var range_border_color: Color

# --- MINING ---
var mining_target: Variant = null   # Vector2i ore grid pos, or null
var mining_timer: float = 0.0
var mining_item_id: StringName = &""
var mining_speed: float = 2.0       # Loaded from mechanical_drill production_time
var mined_inventory: Dictionary = {} # item_id -> count (held before delivery)
const CORE_DELIVERY_RANGE := 15     # Chebyshev tile distance for auto-delivery
const MINING_RANGE := 7             # Max tile distance before mining stops
const TRANSFER_DURATION := 0.3      # Seconds for item to fly to core
var _transfer_items: Array = []     # [{pos:Vector2, target:Vector2, item_id:StringName, icon:Texture2D, t:float}]
var _mining_beam_phase: float = 0.0 # For pulsing animation


func _ready() -> void:
	# Wait for Registry to finish loading (threaded in exported builds).
	if not Registry.essentials_loaded:
		await Registry.all_resources_loaded
	else:
		await get_tree().process_frame

	# Load stats from the .tres file
	data = Registry.get_unit(&"player_drone")
	if data:
		move_speed = data.move_speed
		max_health = data.max_health
		health_regen = data.health_regen
		drone_color = data.color
	else:
		# Fallbacks in case .tres is missing
		push_warning("PlayerDrone: player_drone.tres not found in Registry!")
		move_speed = 300.0
		max_health = 100.0
		health_regen = 5.0
		drone_color = Color(0.3, 0.9, 1.0)

	range_color = Color(drone_color.r, drone_color.g, drone_color.b, 0.08)
	range_border_color = Color(drone_color.r, drone_color.g, drone_color.b, 0.2)

	# Load mining speed from mechanical drill data (drone mines 2x faster)
	var drill_data = Registry.get_block(&"mechanical_drill")
	if drill_data:
		mining_speed = 0.5
	# Init mined_inventory slots
	for item in Registry.items_list:
		if not mined_inventory.has(item.id):
			mined_inventory[item.id] = 0

	health = max_health
	_move_to_core()


func _process(delta: float) -> void:
	_handle_movement(delta)
	_handle_regen(delta)
	_handle_destroy()
	_handle_mining(delta)
	_update_transfers(delta)
	queue_redraw()

func _input(event: InputEvent) -> void:
	if main.is_ui_blocking():
		return
	if event.is_action_pressed("respawn"):
		health = max_health
		_move_to_core()




func _unhandled_input(event: InputEvent) -> void:
	if main.is_ui_blocking():
		return
	# Left-click: check if clicking on ore to start mining
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# Don't mine if a building is selected or controlling a unit
		if main.selected_building != &"":
			return
		var unit_mgr = get_node_or_null("/root/Main/UnitManager")
		if unit_mgr and unit_mgr.controlled_entity != null:
			return
		var terrain = get_node_or_null("/root/Main/TerrainSystem")
		if terrain == null:
			return

		var mouse_world = get_global_mouse_position()
		var grid_pos: Vector2i = main.world_to_grid(mouse_world)

		if terrain.ore_tiles.has(grid_pos):
			if mining_target == grid_pos:
				# Re-click same ore — stop mining
				mining_target = null
				mining_item_id = &""
			else:
				# Start mining this ore
				var ore_data = terrain.get_ore_at(grid_pos)
				if ore_data and ore_data.minable_resource != &"":
					mining_target = grid_pos
					mining_item_id = ore_data.minable_resource
					mining_timer = mining_speed
			get_viewport().set_input_as_handled()
		elif mining_target != null:
			# Currently mining — ignore non-ore clicks (don't shoot or stop mining)
			get_viewport().set_input_as_handled()
		# If not mining and clicked non-ore, let the event pass through (combat can handle it)

func _handle_movement(delta: float) -> void:
	# Skip movement when a blocking UI is open
	if main.is_ui_blocking():
		return
	# Skip drone movement when world is paused (camera pans independently)
	if main.world_paused:
		return
	# Skip drone movement when manually controlling a unit/turret
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if unit_mgr and unit_mgr.controlled_entity != null:
		return

	var move_x = Input.get_axis("move_left", "move_right")
	var move_y = Input.get_axis("move_up", "move_down")
	var velocity = Vector2(move_x, move_y)

	if velocity.length() > 0:
		velocity = velocity.normalized()
		# Set target rotation (persists even after input stops)
		# Don't override rotation while mining — mining locks rotation toward ore
		if mining_target == null:
			_target_facing_angle = velocity.angle() + PI / 2.0 + PI  # Tip faces movement direction

	# Always rotate toward target at constant speed (continues after input stops)
	var angle_diff: float = wrapf(_target_facing_angle - facing_angle, -PI, PI)
	if absf(angle_diff) > 0.01:
		var rotate_amount: float = signf(angle_diff) * ROTATION_SPEED * delta
		if absf(rotate_amount) > absf(angle_diff):
			facing_angle = _target_facing_angle
		else:
			facing_angle = wrapf(facing_angle + rotate_amount, -PI, PI)

	var effective_speed: float = move_speed * 0.5 if mining_target != null else move_speed
	var new_pos: Vector2 = position + velocity * effective_speed * delta
	new_pos.x = clamp(new_pos.x, 0.0, main.GRID_SIZE * main.GRID_WIDTH)
	new_pos.y = clamp(new_pos.y, 0.0, main.GRID_SIZE * main.GRID_HEIGHT)

	# Block drone from entering hidden tiles
	var sector_script = get_node_or_null("/root/Main/SectorScript")
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
	if mining_target == null:
		return

	# Validate ore still exists
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if terrain == null or not terrain.ore_tiles.has(mining_target):
		mining_target = null
		mining_item_id = &""
		return

	# Stop mining if drone moves too far from the ore
	var drone_grid: Vector2i = main.world_to_grid(position)
	var dx: int = absi(drone_grid.x - mining_target.x)
	var dy: int = absi(drone_grid.y - mining_target.y)
	if maxi(dx, dy) > MINING_RANGE:
		mining_target = null
		mining_item_id = &""
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


func _mine_item() -> void:
	if mining_item_id == &"":
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
			# Arrived at core — deposit if storage has room
			var item_id: StringName = _transfer_items[i]["item_id"]
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
	health = max_health
	_move_to_core()


func _move_to_core() -> void:
	var core_data = Registry.get_block(&"core")
	var core_size = core_data.grid_size if core_data else Vector2i(3, 3)
	var core_pos = main.core_position
	position = Vector2(
		(core_pos.x + core_size.x / 2.0) * main.GRID_SIZE,
		(core_pos.y + core_size.y / 2.0) * main.GRID_SIZE
	)


func is_in_build_range(grid_pos: Vector2i) -> bool:
	var drone_grid = main.world_to_grid(position)
	var dx = abs(grid_pos.x - drone_grid.x)
	var dy = abs(grid_pos.y - drone_grid.y)
	return max(dx, dy) <= build_range


# --- DRAWING ---
func _draw() -> void:
	# Hide the drone entirely when controlling a unit/turret
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if unit_mgr and unit_mgr.controlled_entity != null:
		return
	var hud = get_node_or_null("/root/Main/HUD")
	if not hud or hud.visible:
		_draw_range_circle()
	_draw_mining_beam()
	_draw_drone()
	_draw_mined_inventory()
	_draw_transfer_items()
	_draw_health_bar()


func _draw_range_circle() -> void:
	var range_size = build_range * 2 + 1
	var range_pixels = range_size * main.GRID_SIZE
	var drone_grid = main.world_to_grid(position)
	var top_left = main.grid_to_world(drone_grid - Vector2i(build_range, build_range))
	var local_top_left = top_left - position

	draw_rect(
		Rect2(local_top_left, Vector2(range_pixels, range_pixels)),
		range_color,
		true
	)
	draw_rect(
		Rect2(local_top_left, Vector2(range_pixels, range_pixels)),
		range_border_color,
		false,
		1.5
	)


func _draw_drone() -> void:
	var size = data.visual_size if data else 12.0

	# Apply rotation around the drone's center
	draw_set_transform(Vector2.ZERO, facing_angle)

	if drone_texture:
		var tex_size = size * 20.5
		# Shift sprite so the body center (not the tip) sits at the rotation pivot
		var offset_y = tex_size * SPRITE_PIVOT_OFFSET
		var rect = Rect2(Vector2(-tex_size / 2.0, -tex_size / 2.0 + offset_y), Vector2(tex_size, tex_size))
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


func _draw_mining_beam() -> void:
	if mining_target == null:
		return

	var ore_world: Vector2 = main.grid_to_world(mining_target) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
	var ore_local: Vector2 = ore_world - position

	# Compute tip position: the drone sprite's top edge in rotated local space
	# facing_angle rotates the sprite; the tip is at -Y in rotated space
	# facing_angle = velocity.angle() + PI/2 + PI, so the sprite's -Y points forward
	var tip_size: float = (data.visual_size if data else 12.0) * 20.5 * 0.5
	var tip_dir: Vector2 = Vector2(0, tip_size).rotated(facing_angle)

	# Pulsing animation
	var pulse: float = 0.5 + 0.5 * sin(_mining_beam_phase)

	# Mindustry-style beam (yellow for mining)
	var main_ref = get_node("/root/Main")
	main_ref.draw_beam(self, tip_dir, ore_local, Color.YELLOW, pulse)


func _draw_mined_inventory() -> void:
	# Show the first non-zero item icon on the drone with a count badge
	var display_id: StringName = &""
	var display_count: int = 0
	for item_id in mined_inventory:
		if mined_inventory[item_id] > 0:
			display_id = item_id
			display_count = mined_inventory[item_id]
			break

	if display_count <= 0:
		return

	var item_data = Registry.get_item(display_id)
	if item_data == null:
		return

	# Draw icon above drone
	var icon_size := 16.0
	var icon_pos := Vector2(-icon_size / 2.0, -icon_size - 16.0)

	if item_data.icon:
		draw_texture_rect(item_data.icon, Rect2(icon_pos, Vector2(icon_size, icon_size)), false)
	else:
		draw_rect(Rect2(icon_pos, Vector2(icon_size, icon_size)), item_data.color, true)

	# Count badge (bottom-right of icon)
	if display_count > 1:
		var badge_pos := icon_pos + Vector2(icon_size - 2.0, icon_size - 4.0)
		var font := ThemeDB.fallback_font
		var font_size := 10
		var text := str(display_count)
		# Background
		var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		draw_rect(
			Rect2(badge_pos - Vector2(1, text_size.y - 1), text_size + Vector2(2, 2)),
			Color(0, 0, 0, 0.7), true
		)
		draw_string(font, badge_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


func _draw_transfer_items() -> void:
	for entry in _transfer_items:
		var t: float = entry["t"]
		var start: Vector2 = entry["start"]
		var target: Vector2 = entry["target"]
		var current: Vector2 = start.lerp(target, t)
		var local_pos: Vector2 = current - position
		var icon: Texture2D = entry["icon"]

		if icon:
			var s := 12.0
			draw_texture_rect(icon, Rect2(local_pos - Vector2(s / 2.0, s / 2.0), Vector2(s, s)), false)
		else:
			draw_circle(local_pos, 4.0, Color(0.3, 0.9, 1.0, 0.8))


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
