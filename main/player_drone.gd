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
# Last ore tile the drone was actively mining before building preempted it.
# Let the drone auto-resume on the same ore once the queued build finishes,
# so pause→queue→build→repause→mine doesn't lose the player's focus.
# Cleared by explicit re-click (user-intended stop), never by auto-stop.
var _resume_mining_target: Variant = null  # Vector2i or null
var _resume_mining_item_id: StringName = &""
var mining_timer: float = 0.0
var mining_item_id: StringName = &""
var mining_speed: float = 2.0       # Loaded from mechanical_drill production_time
var mined_inventory: Dictionary = {} # item_id -> count (held before delivery)
const CORE_DELIVERY_RANGE := 15     # Chebyshev tile distance for auto-delivery
const MINING_RANGE := 7             # Max tile distance before mining stops
const TRANSFER_DURATION := 0.3      # Seconds for item to fly to core
const MAX_INVENTORY := 60           # Max items the drone can carry before mining pauses
var _transfer_items: Array = []     # [{pos:Vector2, target:Vector2, item_id:StringName, icon:Texture2D, t:float}]
var _mining_beam_phase: float = 0.0 # For pulsing animation

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

func _hud_ref() -> Node:
	if _hud == null:
		_hud = get_node_or_null("/root/Main/HUD")
	return _hud


func _ready() -> void:
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
		# Fallbacks in case .tres is missing (1.3 t/s * 64 px/tile = 83.2 px/s)
		push_warning("PlayerDrone: player_drone.tres not found in Registry!")
		move_speed = 1.3 * float(main.GRID_SIZE)
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
		_clear_inventory()
		_move_to_core()




func _unhandled_input(event: InputEvent) -> void:
	if main.is_ui_blocking():
		return

	# --- Drag-drop inventory deposit ---
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# Start drag if clicking near the drone and inventory is non-empty
			if _get_inventory_total() > 0 and main.selected_building == &"":
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
				# Start mining this ore
				var ore_data = terrain.get_ore_at(grid_pos)
				if ore_data and ore_data.minable_resource != &"":
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
	var velocity = Vector2(move_x, move_y)

	# Focus target = whatever we're mining OR currently building. Used for
	# both facing-lock and the away-from-target slowdown.
	var focus_pos = _get_focus_world_pos()

	if velocity.length() > 0:
		velocity = velocity.normalized()
		# Don't override rotation while focused — focus locks rotation toward
		# the ore/building. Only free movement steers the facing.
		if focus_pos == null:
			_target_facing_angle = velocity.angle() + PI / 2.0 + PI  # Tip faces movement direction

	# While focused, lock rotation toward the focus point (non-mining case
	# previously had no lock — now builds behave the same as mining).
	if focus_pos != null:
		var dir_to_focus: Vector2 = (focus_pos as Vector2) - position
		if dir_to_focus.length_squared() > 1.0:
			_target_facing_angle = dir_to_focus.angle() + PI / 2.0 + PI

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
	if focus_pos != null and velocity.length_squared() > 0.01:
		var to_focus: Vector2 = ((focus_pos as Vector2) - position).normalized()
		if velocity.dot(to_focus) < 0.0:
			effective_speed = move_speed * 0.5
	var new_pos: Vector2 = position + velocity * effective_speed * delta
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

	# Validate ore still exists
	var terrain = _terrain_ref()
	if terrain == null or not terrain.ore_tiles.has(mining_target):
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
	_clear_inventory()
	_move_to_core()


## Drops the mined inventory. Called on any respawn path — death, manual
## respawn hotkey, and release-from-controlled-entity — since any of those
## are "start a new session" from the drone's perspective and holding onto
## pre-session mined items is a free teleport-to-core shortcut.
func _clear_inventory() -> void:
	mined_inventory.clear()
	for item in Registry.items_list:
		mined_inventory[item.id] = 0


func _move_to_core() -> void:
	# Prefer the closest LUMINA core to the drone's current position so a
	# respawn from the far side of the map doesn't teleport back to the
	# original spawn core when a nearer one exists. Falls back to the
	# legacy `main.core_position` if no LUMINA core is reachable (e.g.
	# during initial sector load before building_factions is populated).
	var anchor: Vector2i = main.get_nearest_lumina_core_anchor(position)
	var core_pos: Vector2i
	var core_data: BlockData = null
	if anchor != Vector2i(-1, -1):
		core_pos = anchor
		core_data = Registry.get_block(main.placed_buildings[anchor])
	else:
		core_pos = main.core_position
		core_data = Registry.get_block(&"core")
	var core_size: Vector2i = core_data.grid_size if core_data else Vector2i(3, 3)
	position = Vector2(
		(core_pos.x + core_size.x / 2.0) * main.GRID_SIZE,
		(core_pos.y + core_size.y / 2.0) * main.GRID_SIZE
	)


## Respawns the drone at an arbitrary world position. Used when releasing
## direct control — the drone pops back in where the controlled entity was
## (or where it died), not all the way at the core.
func respawn_at(world_pos: Vector2) -> void:
	position = world_pos
	_clear_inventory()


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
	# Hide the drone entirely when controlling a unit/turret
	var unit_mgr = _unit_mgr_ref()
	if unit_mgr and unit_mgr.controlled_entity != null:
		return
	var hud = _hud_ref()
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
		# Pixel-perfect: draw at the texture's native size (with an optional
		# uniform scale multiplier from UnitData.sprite_scale). Preserves the
		# texture's aspect ratio instead of forcing it into a square.
		var scale_mult: float = data.sprite_scale if data else 1.0
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
	var scale_mult: float = data.sprite_scale if data else 1.0
	var tex_h: float = drone_texture.get_size().y * scale_mult if drone_texture else ((data.visual_size if data else 12.0) * 2.0)
	var tip_size: float = tex_h * 0.5
	var tip_dir: Vector2 = Vector2(0, tip_size).rotated(facing_angle)

	# Pulsing animation
	var pulse: float = 0.5 + 0.5 * sin(_mining_beam_phase)

	# Mindustry-style beam (yellow for mining)
	var main_ref = get_node("/root/Main")
	main_ref.draw_beam(self, tip_dir, ore_local, Color.YELLOW, pulse)


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
