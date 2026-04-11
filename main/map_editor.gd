extends Node2D

# ============================================================
# MAP_EDITOR.GD - Map Editor Root (Mindustry-style)
# ============================================================
# Root script for the map editor scene. Named "Main" in the scene
# tree so that TerrainSystem, GridRenderer, BuildingSystem, and
# SaveManager can resolve their /root/Main paths without modification.
#
# Exposes the same interface as main.gd that these systems depend on:
#   - GRID_SIZE, GRID_WIDTH, GRID_HEIGHT constants
#   - world_to_grid(), grid_to_world(), is_within_bounds()
#   - placed_buildings, building_origins, building_rotation, etc.
#   - Faction enum, get_building_faction(), is_building_anchor()
# ============================================================

# --- GRID CONSTANTS (must match main.gd) ---
const GRID_SIZE := 64
var GRID_WIDTH := 100
var GRID_HEIGHT := 100

# --- FACTIONS (must match main.gd) ---
enum Faction { LUMINA, FEROX }

# --- BUILDING STATE ---
# Full building state for the editor (same dicts as main.gd).
var placed_buildings := {}
var building_health := {}
var building_rotation := {}
var building_origins := {}
var building_factions := {}

# Compatibility stubs used by BuildingSystem
var selected_building: StringName = &""
var resources := {}
var require_resources := false
var placement_rotation := 0
var core_position := Vector2i(48, 48)

# Signals used by BuildingSystem and TerrainSystem
signal resources_changed(resources: Dictionary)
signal building_selected(block_id: StringName)
signal building_placed(block_id: StringName, grid_pos: Vector2i)
signal building_destroyed(grid_pos: Vector2i)

# --- EDITOR STATE ---
enum Tool { PENCIL, ERASER, RECT_FILL, RECT_ERASE }
enum EditorMode { TERRAIN, BUILDING, TRANSFORM, SCRIPT }

var current_tool: Tool = Tool.PENCIL
var editor_mode: EditorMode = EditorMode.TERRAIN
var selected_tile: StringName = &""
var selected_block: StringName = &""
var selected_faction: int = Faction.LUMINA
var enemies_attack := false  # Stub for compatibility
var fade_enabled := true     # Toggle for floor/wall fade in editor
var grid_enabled := true     # Toggle for editor grid overlay

# Script editor reference
var script_editor: Node = null

# Overlay for drawing on top of terrain and buildings
@onready var _overlay: Node2D = $EditorOverlay

# Painting state
var _painting := false
var _erasing := false

# Rectangle tool state
var _rect_dragging := false
var _rect_start := Vector2i.ZERO
var _rect_end := Vector2i.ZERO

# Transform mode state
enum TransformPhase { SELECTING, SELECTED, DRAGGING }
var _transform_phase: int = TransformPhase.SELECTING
var _transform_start := Vector2i.ZERO
var _transform_end := Vector2i.ZERO
var _transform_dragging := false
# Captured data for the selected region
var _transform_tiles_floor := {}   # Vector2i offset → StringName
var _transform_tiles_wall := {}
var _transform_tiles_ore := {}
var _transform_tile_health := {}
var _transform_multi_origins := {} # Vector2i offset → Vector2i offset (origin)
var _transform_buildings := {}     # Vector2i offset → StringName
var _transform_bld_health := {}
var _transform_bld_rotation := {}
var _transform_bld_origins := {}   # offset → offset (anchor)
var _transform_bld_factions := {}
var _transform_links: Array = []   # Array of [Vector2i offset, Vector2i offset]
var _transform_drag_offset := Vector2i.ZERO  # where the user started dragging
var _transform_current_offset := Vector2i.ZERO  # current mouse offset from drag start

# Linking state
var linking_mode := false
var link_source := Vector2i(-1, -1)
var linked_pairs: Array = []  # Array of [Vector2i, Vector2i]


func _ready() -> void:
	_overlay.draw.connect(_draw_overlay)

	# Disable BuildingSystem's input/process — the editor handles its own
	var bs = get_node_or_null("BuildingSystem")
	if bs:
		bs.set_process_unhandled_input(false)
		bs.set_process_input(false)
		bs.set_process(false)

	await get_tree().process_frame


func _process(_delta: float) -> void:
	# BuildingSystem renders walls, ores, and buildings but has viewport culling,
	# so it must be redrawn every frame as the camera moves.
	var bs = get_node_or_null("BuildingSystem")
	if bs:
		bs.queue_redraw()


# --- COMPATIBILITY HELPERS (same signatures as main.gd) ---

func world_to_grid(world_pos: Vector2) -> Vector2i:
	return Vector2i(
		floori(world_pos.x / GRID_SIZE),
		floori(world_pos.y / GRID_SIZE)
	)


func grid_to_world(grid_pos: Vector2i) -> Vector2:
	return Vector2(grid_pos.x * GRID_SIZE, grid_pos.y * GRID_SIZE)


func is_within_bounds(grid_pos: Vector2i) -> bool:
	return (grid_pos.x >= 0 and grid_pos.x < GRID_WIDTH and
			grid_pos.y >= 0 and grid_pos.y < GRID_HEIGHT)


func is_cell_empty(grid_pos: Vector2i) -> bool:
	return not placed_buildings.has(grid_pos)

func get_building_anchor(grid_pos: Vector2i) -> Variant:
	if building_origins.has(grid_pos):
		return building_origins[grid_pos]
	return null


func is_building_anchor(grid_pos: Vector2i) -> bool:
	if not building_origins.has(grid_pos):
		return false
	return building_origins[grid_pos] == grid_pos


func get_building_faction(grid_pos: Vector2i) -> int:
	return building_factions.get(grid_pos, Faction.LUMINA)


func get_building_health_pct(_grid_pos: Vector2i) -> float:
	return 1.0  # No damage in editor


## No-op: TerrainSystem calls this when exiting paint mode.
func select_building(_id: StringName) -> void:
	pass


## No-op: BuildingSystem may call this
func can_afford(_block_id: StringName) -> bool:
	return true


# --- INPUT HANDLING ---

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		# Rotation key (Q) for building mode
		if event.keycode == KEY_Q and editor_mode == EditorMode.BUILDING:
			placement_rotation = (placement_rotation + 1) % 4
			_overlay.queue_redraw()
			return
		# Set spawn core (C) — hover a core and press C
		if event.keycode == KEY_C:
			var grid_pos := world_to_grid(get_global_mouse_position())
			if placed_buildings.has(grid_pos):
				var block_id = placed_buildings[grid_pos]
				var data = Registry.get_block(block_id)
				if data and data.tags.has("core"):
					var anchor = building_origins.get(grid_pos, grid_pos)
					core_position = anchor
					_overlay.queue_redraw()
			return
		# Toggle linking mode (L)
		if event.keycode == KEY_L:
			if linking_mode:
				linking_mode = false
				link_source = Vector2i(-1, -1)
			else:
				linking_mode = true
				link_source = Vector2i(-1, -1)
			_overlay.queue_redraw()
			return

	if event is InputEventMouseButton:
		# Script mode: no terrain/building interaction
		if editor_mode == EditorMode.SCRIPT:
			return

		var grid_pos := world_to_grid(get_global_mouse_position())

		# Allow transform release even outside bounds, clamp position
		if editor_mode == EditorMode.TRANSFORM and not event.pressed:
			grid_pos = Vector2i(clampi(grid_pos.x, 0, GRID_WIDTH - 1),
								clampi(grid_pos.y, 0, GRID_HEIGHT - 1))
			_handle_transform_click(event, grid_pos)
			return

		if not is_within_bounds(grid_pos):
			return

		# --- Linking mode ---
		if linking_mode:
			if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				_handle_link_click(grid_pos)
			elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
				linking_mode = false
				link_source = Vector2i(-1, -1)
				_overlay.queue_redraw()
			return

		# --- Transform mode ---
		if editor_mode == EditorMode.TRANSFORM:
			_handle_transform_click(event, grid_pos)
			return

		# --- Building mode ---
		if editor_mode == EditorMode.BUILDING:
			if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				# Center multi-tile buildings on the mouse cursor
				var place_pos := grid_pos
				var sel_data = Registry.get_block(selected_block)
				if sel_data and (sel_data.grid_size.x > 1 or sel_data.grid_size.y > 1):
					place_pos -= Vector2i(sel_data.grid_size.x / 2, sel_data.grid_size.y / 2)
				_place_block_at(place_pos)
			elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
				_erase_block_at(grid_pos)
			return

		# --- Rectangle tools (terrain mode) ---
		if current_tool == Tool.RECT_FILL or current_tool == Tool.RECT_ERASE:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					_rect_dragging = true
					_rect_start = grid_pos
					_rect_end = grid_pos
				else:
					if _rect_dragging:
						_rect_dragging = false
						_apply_rect()
						_overlay.queue_redraw()
			elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
				_rect_dragging = false
				_overlay.queue_redraw()
			return

		# --- Pencil / Eraser (terrain mode) ---
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_painting = true
				_paint_at(grid_pos)
			else:
				_painting = false
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_erasing = true
				_erase_at(grid_pos)
			else:
				_erasing = false

	elif event is InputEventMouseMotion:
		if editor_mode == EditorMode.SCRIPT:
			return
		var grid_pos := world_to_grid(get_global_mouse_position())
		if not is_within_bounds(grid_pos):
			return

		if editor_mode == EditorMode.TRANSFORM:
			_handle_transform_motion(grid_pos)
			return
		elif linking_mode:
			_overlay.queue_redraw()  # Update link line to mouse
		elif editor_mode == EditorMode.BUILDING:
			_overlay.queue_redraw()  # Update building preview
		elif _rect_dragging:
			_rect_end = grid_pos
			_overlay.queue_redraw()
		elif _painting:
			_paint_at(grid_pos)
		elif _erasing:
			_erase_at(grid_pos)


# --- TERRAIN PAINTING ---

func _paint_at(grid_pos: Vector2i) -> void:
	if selected_tile == &"":
		return
	var terrain = $TerrainSystem
	if current_tool == Tool.ERASER:
		terrain.remove_tile(grid_pos)
	else:
		terrain.place_tile(grid_pos, selected_tile)


func _erase_at(grid_pos: Vector2i) -> void:
	$TerrainSystem.remove_tile(grid_pos)


func _apply_rect() -> void:
	var terrain = $TerrainSystem
	var min_x := mini(_rect_start.x, _rect_end.x)
	var min_y := mini(_rect_start.y, _rect_end.y)
	var max_x := maxi(_rect_start.x, _rect_end.x)
	var max_y := maxi(_rect_start.y, _rect_end.y)

	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			var cell := Vector2i(x, y)
			if not is_within_bounds(cell):
				continue
			if current_tool == Tool.RECT_FILL and selected_tile != &"":
				terrain.place_tile(cell, selected_tile)
			elif current_tool == Tool.RECT_ERASE:
				terrain.remove_tile(cell)

	terrain.queue_redraw()


# --- TRANSFORM MODE ---

func _handle_transform_click(event: InputEventMouseButton, grid_pos: Vector2i) -> void:
	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		# Cancel / deselect
		_transform_phase = TransformPhase.SELECTING
		_transform_dragging = false
		_overlay.queue_redraw()
		return

	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	match _transform_phase:
		TransformPhase.SELECTING:
			if event.pressed:
				_transform_dragging = true
				_transform_start = grid_pos
				_transform_end = grid_pos
			else:
				if _transform_dragging:
					_transform_dragging = false
					_transform_end = grid_pos
					_capture_transform_region()
					_transform_phase = TransformPhase.SELECTED
			_overlay.queue_redraw()

		TransformPhase.SELECTED:
			if event.pressed:
				# Check if clicking inside the selected rect to start dragging
				var min_pos := _transform_rect_min()
				var max_pos := _transform_rect_max()
				if grid_pos.x >= min_pos.x and grid_pos.x <= max_pos.x \
						and grid_pos.y >= min_pos.y and grid_pos.y <= max_pos.y:
					_transform_phase = TransformPhase.DRAGGING
					_transform_drag_offset = grid_pos
					_transform_current_offset = Vector2i.ZERO
				else:
					# Clicked outside — start new selection
					_transform_dragging = true
					_transform_start = grid_pos
					_transform_end = grid_pos
					_transform_phase = TransformPhase.SELECTING
			_overlay.queue_redraw()

		TransformPhase.DRAGGING:
			if not event.pressed:
				# Release — apply the move
				_apply_transform_move()
				_transform_phase = TransformPhase.SELECTING
			_overlay.queue_redraw()


func _handle_transform_motion(grid_pos: Vector2i) -> void:
	match _transform_phase:
		TransformPhase.SELECTING:
			if _transform_dragging:
				_transform_end = grid_pos
				_overlay.queue_redraw()
		TransformPhase.DRAGGING:
			_transform_current_offset = grid_pos - _transform_drag_offset
			_overlay.queue_redraw()


func _transform_rect_min() -> Vector2i:
	return Vector2i(mini(_transform_start.x, _transform_end.x),
					mini(_transform_start.y, _transform_end.y))


func _transform_rect_max() -> Vector2i:
	return Vector2i(maxi(_transform_start.x, _transform_end.x),
					maxi(_transform_start.y, _transform_end.y))


## Captures all terrain and building data within the selected rectangle.
func _capture_transform_region() -> void:
	_transform_tiles_floor.clear()
	_transform_tiles_wall.clear()
	_transform_tiles_ore.clear()
	_transform_tile_health.clear()
	_transform_multi_origins.clear()
	_transform_buildings.clear()
	_transform_bld_health.clear()
	_transform_bld_rotation.clear()
	_transform_bld_origins.clear()
	_transform_bld_factions.clear()
	_transform_links.clear()

	var terrain = $TerrainSystem
	var min_pos := _transform_rect_min()
	var max_pos := _transform_rect_max()

	# Track which multi-tile origins we've already captured
	var captured_multi_origins := {}

	for x in range(min_pos.x, max_pos.x + 1):
		for y in range(min_pos.y, max_pos.y + 1):
			var cell := Vector2i(x, y)
			var offset := cell - min_pos

			# Floor tiles
			if terrain.floor_tiles.has(cell):
				_transform_tiles_floor[offset] = terrain.floor_tiles[cell]
			# Wall tiles
			if terrain.wall_tiles.has(cell):
				_transform_tiles_wall[offset] = terrain.wall_tiles[cell]
			# Ore tiles
			if terrain.ore_tiles.has(cell):
				_transform_tiles_ore[offset] = terrain.ore_tiles[cell]
			# Tile health
			if terrain.tile_health.has(cell):
				_transform_tile_health[offset] = terrain.tile_health[cell]
			# Multi-tile origins
			if terrain.multi_tile_origins.has(cell):
				var origin = terrain.multi_tile_origins[cell]
				var origin_offset = origin - min_pos
				_transform_multi_origins[offset] = origin_offset

			# Buildings
			if placed_buildings.has(cell):
				_transform_buildings[offset] = placed_buildings[cell]
			if building_health.has(cell):
				_transform_bld_health[offset] = building_health[cell]
			if building_rotation.has(cell):
				_transform_bld_rotation[offset] = building_rotation[cell]
			if building_origins.has(cell):
				_transform_bld_origins[offset] = building_origins[cell] - min_pos
			if building_factions.has(cell):
				_transform_bld_factions[offset] = building_factions[cell]

	# Capture links that have both endpoints inside the rectangle
	for pair in linked_pairs:
		var a: Vector2i = pair[0]
		var b: Vector2i = pair[1]
		if a.x >= min_pos.x and a.x <= max_pos.x and a.y >= min_pos.y and a.y <= max_pos.y \
				and b.x >= min_pos.x and b.x <= max_pos.x and b.y >= min_pos.y and b.y <= max_pos.y:
			_transform_links.append([a - min_pos, b - min_pos])


## Erases the original region content from the map.
func _erase_transform_region() -> void:
	var terrain = $TerrainSystem
	var min_pos := _transform_rect_min()
	var max_pos := _transform_rect_max()

	for x in range(min_pos.x, max_pos.x + 1):
		for y in range(min_pos.y, max_pos.y + 1):
			var cell := Vector2i(x, y)
			terrain.floor_tiles.erase(cell)
			terrain.wall_tiles.erase(cell)
			terrain.ore_tiles.erase(cell)
			terrain.tile_health.erase(cell)
			terrain.multi_tile_origins.erase(cell)
			placed_buildings.erase(cell)
			building_health.erase(cell)
			building_rotation.erase(cell)
			building_origins.erase(cell)
			building_factions.erase(cell)

	# Remove links that were captured
	for link in _transform_links:
		var a = link[0] + min_pos
		var b = link[1] + min_pos
		for i in range(linked_pairs.size() - 1, -1, -1):
			if linked_pairs[i][0] == a and linked_pairs[i][1] == b:
				linked_pairs.remove_at(i)
				break


## Pastes captured data at the new position (min_pos + offset).
func _paste_transform_data(dest_min: Vector2i) -> void:
	var terrain = $TerrainSystem

	# Paste terrain
	for offset in _transform_tiles_floor:
		var cell = dest_min + offset
		if is_within_bounds(cell):
			terrain.floor_tiles[cell] = _transform_tiles_floor[offset]
	for offset in _transform_tiles_wall:
		var cell = dest_min + offset
		if is_within_bounds(cell):
			terrain.wall_tiles[cell] = _transform_tiles_wall[offset]
	for offset in _transform_tiles_ore:
		var cell = dest_min + offset
		if is_within_bounds(cell):
			terrain.ore_tiles[cell] = _transform_tiles_ore[offset]
	for offset in _transform_tile_health:
		var cell = dest_min + offset
		if is_within_bounds(cell):
			terrain.tile_health[cell] = _transform_tile_health[offset]
	for offset in _transform_multi_origins:
		var cell = dest_min + offset
		var origin_cell = dest_min + _transform_multi_origins[offset]
		if is_within_bounds(cell):
			terrain.multi_tile_origins[cell] = origin_cell

	# Paste buildings
	for offset in _transform_buildings:
		var cell = dest_min + offset
		if is_within_bounds(cell):
			placed_buildings[cell] = _transform_buildings[offset]
	for offset in _transform_bld_health:
		var cell = dest_min + offset
		if is_within_bounds(cell):
			building_health[cell] = _transform_bld_health[offset]
	for offset in _transform_bld_rotation:
		var cell = dest_min + offset
		if is_within_bounds(cell):
			building_rotation[cell] = _transform_bld_rotation[offset]
	for offset in _transform_bld_origins:
		var cell = dest_min + offset
		var anchor = dest_min + _transform_bld_origins[offset]
		if is_within_bounds(cell):
			building_origins[cell] = anchor
	for offset in _transform_bld_factions:
		var cell = dest_min + offset
		if is_within_bounds(cell):
			building_factions[cell] = _transform_bld_factions[offset]

	# Paste links
	for link in _transform_links:
		linked_pairs.append([dest_min + link[0], dest_min + link[1]])


func _apply_transform_move() -> void:
	var dest_min := _transform_rect_min() + _transform_current_offset

	# Erase original
	_erase_transform_region()
	# Paste at new location
	_paste_transform_data(dest_min)

	# Update selection rect to new position
	var size := _transform_rect_max() - _transform_rect_min()
	_transform_start = dest_min
	_transform_end = dest_min + size

	$TerrainSystem.queue_redraw()
	var bs = get_node_or_null("BuildingSystem")
	if bs:
		bs.queue_redraw()
	_overlay.queue_redraw()


## Mirrors the captured transform data along the X axis (left-right flip).
func transform_mirror_x() -> void:
	if _transform_phase != TransformPhase.SELECTED:
		return

	var region_w := _transform_rect_max().x - _transform_rect_min().x
	var min_pos := _transform_rect_min()

	# Erase the original region
	_erase_transform_region()

	# Mirror all offset keys: new_x = region_w - old_x
	_transform_tiles_floor = _mirror_dict_x(_transform_tiles_floor, region_w)
	_transform_tiles_wall = _mirror_dict_x(_transform_tiles_wall, region_w)
	_transform_tiles_ore = _mirror_dict_x(_transform_tiles_ore, region_w)
	_transform_tile_health = _mirror_dict_x(_transform_tile_health, region_w)

	# Mirror multi-tile origins (both key and value)
	var new_multi := {}
	for offset in _transform_multi_origins:
		var new_offset := Vector2i(region_w - offset.x, offset.y)
		var old_origin: Vector2i = _transform_multi_origins[offset]
		var new_origin := Vector2i(region_w - old_origin.x, old_origin.y)
		new_multi[new_offset] = new_origin
	_transform_multi_origins = new_multi

	# Mirror buildings
	_transform_buildings = _mirror_dict_x(_transform_buildings, region_w)
	_transform_bld_health = _mirror_dict_x(_transform_bld_health, region_w)
	_transform_bld_factions = _mirror_dict_x(_transform_bld_factions, region_w)

	# Mirror building rotations (flip left/right: 0↔2, 1 and 3 stay)
	var new_rot := {}
	for offset in _transform_bld_rotation:
		var new_offset := Vector2i(region_w - offset.x, offset.y)
		var rot: int = _transform_bld_rotation[offset]
		if rot == 0:
			rot = 2
		elif rot == 2:
			rot = 0
		new_rot[new_offset] = rot
	_transform_bld_rotation = new_rot

	# Mirror building origins (both key and value)
	var new_bld_orig := {}
	for offset in _transform_bld_origins:
		var new_offset := Vector2i(region_w - offset.x, offset.y)
		var old_anchor: Vector2i = _transform_bld_origins[offset]
		# For multi-tile buildings, the anchor is top-left. After X-mirror,
		# we need to find the block size to compute the new anchor.
		var new_anchor := Vector2i(region_w - old_anchor.x, old_anchor.y)
		# Adjust anchor for multi-tile: anchor should be top-left of the mirrored block
		if _transform_buildings.has(new_offset):
			var block_id = _transform_buildings[new_offset]
			var data = Registry.get_block(block_id)
			if data and data.grid_size.x > 1:
				new_anchor.x -= (data.grid_size.x - 1)
		new_bld_orig[new_offset] = new_anchor
	_transform_bld_origins = new_bld_orig

	# Mirror links
	var new_links: Array = []
	for link in _transform_links:
		new_links.append([
			Vector2i(region_w - link[0].x, link[0].y),
			Vector2i(region_w - link[1].x, link[1].y)
		])
	_transform_links = new_links

	# Paste back
	_paste_transform_data(min_pos)

	# Re-capture so internal state is consistent
	_capture_transform_region()

	$TerrainSystem.queue_redraw()
	var bs = get_node_or_null("BuildingSystem")
	if bs:
		bs.queue_redraw()
	_overlay.queue_redraw()


## Mirrors the captured transform data along the Y axis (top-bottom flip).
func transform_mirror_y() -> void:
	if _transform_phase != TransformPhase.SELECTED:
		return

	var region_h := _transform_rect_max().y - _transform_rect_min().y
	var min_pos := _transform_rect_min()

	_erase_transform_region()

	_transform_tiles_floor = _mirror_dict_y(_transform_tiles_floor, region_h)
	_transform_tiles_wall = _mirror_dict_y(_transform_tiles_wall, region_h)
	_transform_tiles_ore = _mirror_dict_y(_transform_tiles_ore, region_h)
	_transform_tile_health = _mirror_dict_y(_transform_tile_health, region_h)

	var new_multi := {}
	for offset in _transform_multi_origins:
		var new_offset := Vector2i(offset.x, region_h - offset.y)
		var old_origin: Vector2i = _transform_multi_origins[offset]
		var new_origin := Vector2i(old_origin.x, region_h - old_origin.y)
		new_multi[new_offset] = new_origin
	_transform_multi_origins = new_multi

	_transform_buildings = _mirror_dict_y(_transform_buildings, region_h)
	_transform_bld_health = _mirror_dict_y(_transform_bld_health, region_h)
	_transform_bld_factions = _mirror_dict_y(_transform_bld_factions, region_h)

	var new_rot := {}
	for offset in _transform_bld_rotation:
		var new_offset := Vector2i(offset.x, region_h - offset.y)
		var rot: int = _transform_bld_rotation[offset]
		if rot == 1:
			rot = 3
		elif rot == 3:
			rot = 1
		new_rot[new_offset] = rot
	_transform_bld_rotation = new_rot

	var new_bld_orig := {}
	for offset in _transform_bld_origins:
		var new_offset := Vector2i(offset.x, region_h - offset.y)
		var old_anchor: Vector2i = _transform_bld_origins[offset]
		var new_anchor := Vector2i(old_anchor.x, region_h - old_anchor.y)
		if _transform_buildings.has(new_offset):
			var block_id = _transform_buildings[new_offset]
			var data = Registry.get_block(block_id)
			if data and data.grid_size.y > 1:
				new_anchor.y -= (data.grid_size.y - 1)
		new_bld_orig[new_offset] = new_anchor
	_transform_bld_origins = new_bld_orig

	var new_links: Array = []
	for link in _transform_links:
		new_links.append([
			Vector2i(link[0].x, region_h - link[0].y),
			Vector2i(link[1].x, region_h - link[1].y)
		])
	_transform_links = new_links

	_paste_transform_data(min_pos)
	_capture_transform_region()

	$TerrainSystem.queue_redraw()
	var bs = get_node_or_null("BuildingSystem")
	if bs:
		bs.queue_redraw()
	_overlay.queue_redraw()


## Converts all buildings in the selected region to the given faction.
func transform_convert_faction(faction: int) -> void:
	if _transform_phase != TransformPhase.SELECTED:
		return

	var min_pos := _transform_rect_min()
	var max_pos := _transform_rect_max()

	for x in range(min_pos.x, max_pos.x + 1):
		for y in range(min_pos.y, max_pos.y + 1):
			var cell := Vector2i(x, y)
			if building_factions.has(cell):
				building_factions[cell] = faction

	# Update the captured transform data too so it stays in sync
	for offset in _transform_bld_factions:
		_transform_bld_factions[offset] = faction

	var bs = get_node_or_null("BuildingSystem")
	if bs:
		bs.queue_redraw()
	_overlay.queue_redraw()


func _mirror_dict_x(dict: Dictionary, region_w: int) -> Dictionary:
	var result := {}
	for offset in dict:
		result[Vector2i(region_w - offset.x, offset.y)] = dict[offset]
	return result


func _mirror_dict_y(dict: Dictionary, region_h: int) -> Dictionary:
	var result := {}
	for offset in dict:
		result[Vector2i(offset.x, region_h - offset.y)] = dict[offset]
	return result


# --- BUILDING PLACEMENT ---

func _place_block_at(grid_pos: Vector2i) -> void:
	if selected_block == &"":
		return
	var data = Registry.get_block(selected_block)
	if data == null:
		return

	# Check bounds and empty for all cells
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var p = grid_pos + Vector2i(x, y)
			if not is_within_bounds(p) or placed_buildings.has(p):
				return

	# Vent-powered buildings must be centered on a vent tile
	if data.tags.has("vent_powered"):
		var terrain = get_node_or_null("TerrainSystem")
		if terrain:
			var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
			var tile_id = terrain.floor_tiles.get(center, &"")
			if tile_id != &"vent":
				return

	# Place all cells
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var p = grid_pos + Vector2i(x, y)
			placed_buildings[p] = selected_block
			building_health[p] = data.max_health
			building_rotation[p] = placement_rotation
			building_origins[p] = grid_pos
			building_factions[p] = selected_faction

	building_placed.emit(selected_block, grid_pos)

	# Auto-set spawn core if this is the first core placed
	if data.tags.has("core") and not _has_spawn_core():
		core_position = grid_pos
	_overlay.queue_redraw()

	var bs = get_node_or_null("BuildingSystem")
	if bs:
		bs.queue_redraw()


func _erase_block_at(grid_pos: Vector2i) -> void:
	if not placed_buildings.has(grid_pos):
		return

	var block_id = placed_buildings[grid_pos]
	var data = Registry.get_block(block_id)
	var erased_anchor: Vector2i = building_origins.get(grid_pos, grid_pos)

	if data and (data.grid_size.x > 1 or data.grid_size.y > 1):
		# Multi-tile: find anchor and remove all cells
		var anchor = building_origins.get(grid_pos, grid_pos)
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				var p = anchor + Vector2i(x, y)
				placed_buildings.erase(p)
				building_health.erase(p)
				building_rotation.erase(p)
				building_origins.erase(p)
				building_factions.erase(p)
	else:
		placed_buildings.erase(grid_pos)
		building_health.erase(grid_pos)
		building_rotation.erase(grid_pos)
		building_origins.erase(grid_pos)
		building_factions.erase(grid_pos)

	# Remove any links involving the erased block
	_remove_links_for(erased_anchor)

	# If we erased the spawn core, pick another core or reset
	if data and data.tags.has("core") and erased_anchor == core_position:
		_pick_next_spawn_core()

	building_destroyed.emit(grid_pos)
	_overlay.queue_redraw()

	var bs = get_node_or_null("BuildingSystem")
	if bs:
		bs.queue_redraw()


## Clears all building state (used by editor "New" button).
func clear_buildings() -> void:
	placed_buildings.clear()
	building_health.clear()
	building_rotation.clear()
	building_origins.clear()
	building_factions.clear()
	linked_pairs.clear()
	core_position = Vector2i(-1, -1)
	var bs = get_node_or_null("BuildingSystem")
	if bs:
		bs.queue_redraw()


## Returns true if the current core_position points to a valid placed core.
func _has_spawn_core() -> bool:
	if not placed_buildings.has(core_position):
		return false
	var data = Registry.get_block(placed_buildings[core_position])
	return data != null and data.tags.has("core")


## Finds any remaining core on the map and sets it as spawn, or resets.
func _pick_next_spawn_core() -> void:
	for pos in placed_buildings:
		var data = Registry.get_block(placed_buildings[pos])
		if data and data.tags.has("core"):
			var anchor = building_origins.get(pos, pos)
			core_position = anchor
			return
	core_position = Vector2i(-1, -1)


# --- LINKING ---

func _handle_link_click(grid_pos: Vector2i) -> void:
	if not placed_buildings.has(grid_pos):
		return
	var block_id = placed_buildings[grid_pos]
	var data = Registry.get_block(block_id)
	if data == null or not data.tags.has("linkable"):
		return

	if link_source == Vector2i(-1, -1):
		# First click — remember source
		link_source = grid_pos
	else:
		# Second click — create the link
		if grid_pos != link_source:
			# Remove existing links for both endpoints (1:1 links)
			_remove_links_for(link_source)
			_remove_links_for(grid_pos)
			linked_pairs.append([link_source, grid_pos])
		# Done linking
		linking_mode = false
		link_source = Vector2i(-1, -1)
	_overlay.queue_redraw()


func _remove_links_for(grid_pos: Vector2i) -> void:
	for i in range(linked_pairs.size() - 1, -1, -1):
		var pair = linked_pairs[i]
		if pair[0] == grid_pos or pair[1] == grid_pos:
			linked_pairs.remove_at(i)


func get_linked_partner(grid_pos: Vector2i) -> Variant:
	for pair in linked_pairs:
		if pair[0] == grid_pos:
			return pair[1]
		if pair[1] == grid_pos:
			return pair[0]
	return null


# --- DRAWING ---

func _draw_overlay() -> void:
	if grid_enabled:
		_draw_grid()
	_draw_core_marker()
	_draw_rect_preview()
	_draw_transform_preview()
	_draw_building_preview()
	_draw_links()


func _draw_grid() -> void:
	var gs: float = GRID_SIZE
	var color := Color(1, 1, 1, 0.06)
	# Only draw grid lines visible on screen for performance
	var cam = get_node_or_null("Camera2D")
	var vp_size := get_viewport().get_visible_rect().size
	var cam_pos: Vector2 = cam.position if cam else Vector2(GRID_WIDTH * gs / 2, GRID_HEIGHT * gs / 2)
	var cam_zoom: float = cam.zoom.x if cam else 1.0
	var half_vp: Vector2 = vp_size / (2.0 * cam_zoom)
	var min_x: int = maxi(0, int((cam_pos.x - half_vp.x) / gs) - 1)
	var max_x: int = mini(GRID_WIDTH, int((cam_pos.x + half_vp.x) / gs) + 2)
	var min_y: int = maxi(0, int((cam_pos.y - half_vp.y) / gs) - 1)
	var max_y: int = mini(GRID_HEIGHT, int((cam_pos.y + half_vp.y) / gs) + 2)
	# Vertical lines
	for x in range(min_x, max_x + 1):
		var px: float = x * gs
		_overlay.draw_line(Vector2(px, min_y * gs), Vector2(px, max_y * gs), color, 1.0)
	# Horizontal lines
	for y in range(min_y, max_y + 1):
		var py: float = y * gs
		_overlay.draw_line(Vector2(min_x * gs, py), Vector2(max_x * gs, py), color, 1.0)

	# Map boundary — thick colored border at the grid limits
	var bound_color := Color(1.0, 0.3, 0.3, 0.5)
	var bound_w := 2.5
	var map_w: float = GRID_WIDTH * gs
	var map_h: float = GRID_HEIGHT * gs
	_overlay.draw_line(Vector2(0, 0), Vector2(map_w, 0), bound_color, bound_w)
	_overlay.draw_line(Vector2(0, map_h), Vector2(map_w, map_h), bound_color, bound_w)
	_overlay.draw_line(Vector2(0, 0), Vector2(0, map_h), bound_color, bound_w)
	_overlay.draw_line(Vector2(map_w, 0), Vector2(map_w, map_h), bound_color, bound_w)


func _draw_core_marker() -> void:
	# Only draw spawn marker if a core is actually placed at core_position
	if not placed_buildings.has(core_position):
		return
	var block_id = placed_buildings[core_position]
	var data = Registry.get_block(block_id)
	if data == null or not data.tags.has("core"):
		return

	var world_pos := grid_to_world(core_position)
	var w := float(GRID_SIZE * data.grid_size.x)
	var h := float(GRID_SIZE * data.grid_size.y)
	# Filled semi-transparent
	_overlay.draw_rect(Rect2(world_pos, Vector2(w, h)), Color(0.2, 0.6, 1.0, 0.15), true)
	# Outline
	_overlay.draw_rect(Rect2(world_pos, Vector2(w, h)), Color(0.2, 0.6, 1.0, 0.7), false, 3.0)
	# Label
	var font := ThemeDB.fallback_font
	var label_pos := world_pos + Vector2(w / 2.0 - 24, h / 2.0 + 5)
	_overlay.draw_string(font, label_pos, "SPAWN", HORIZONTAL_ALIGNMENT_CENTER, -1, 14, Color(0.2, 0.6, 1.0, 0.9))


func _draw_rect_preview() -> void:
	if not _rect_dragging:
		return
	var min_x := mini(_rect_start.x, _rect_end.x)
	var min_y := mini(_rect_start.y, _rect_end.y)
	var max_x := maxi(_rect_start.x, _rect_end.x)
	var max_y := maxi(_rect_start.y, _rect_end.y)

	var top_left := grid_to_world(Vector2i(min_x, min_y))
	var w := float((max_x - min_x + 1) * GRID_SIZE)
	var h := float((max_y - min_y + 1) * GRID_SIZE)

	var color: Color
	if current_tool == Tool.RECT_FILL:
		color = Color(0.2, 0.8, 0.2, 0.2)
	else:
		color = Color(1, 0, 0, 0.2)

	_overlay.draw_rect(Rect2(top_left, Vector2(w, h)), color, true)
	_overlay.draw_rect(Rect2(top_left, Vector2(w, h)), color.lightened(0.3), false, 2.0)


func _draw_transform_preview() -> void:
	if editor_mode != EditorMode.TRANSFORM:
		return

	match _transform_phase:
		TransformPhase.SELECTING:
			if not _transform_dragging:
				return
			# Draw selection rectangle while dragging
			var min_pos := _transform_rect_min()
			var max_pos := _transform_rect_max()
			var top_left := grid_to_world(min_pos)
			var w := float((max_pos.x - min_pos.x + 1) * GRID_SIZE)
			var h := float((max_pos.y - min_pos.y + 1) * GRID_SIZE)
			var color := Color(0.8, 0.6, 0.2, 0.2)
			_overlay.draw_rect(Rect2(top_left, Vector2(w, h)), color, true)
			_overlay.draw_rect(Rect2(top_left, Vector2(w, h)), Color(1.0, 0.8, 0.3, 0.8), false, 2.0)

		TransformPhase.SELECTED:
			# Draw the selected region with a solid outline
			var min_pos := _transform_rect_min()
			var max_pos := _transform_rect_max()
			var top_left := grid_to_world(min_pos)
			var w := float((max_pos.x - min_pos.x + 1) * GRID_SIZE)
			var h := float((max_pos.y - min_pos.y + 1) * GRID_SIZE)
			_overlay.draw_rect(Rect2(top_left, Vector2(w, h)), Color(1.0, 0.8, 0.3, 0.15), true)
			_overlay.draw_rect(Rect2(top_left, Vector2(w, h)), Color(1.0, 0.8, 0.3, 0.9), false, 3.0)
			# Draw "drag to move" hint
			var font := ThemeDB.fallback_font
			var label_pos := top_left + Vector2(4, -4)
			_overlay.draw_string(font, label_pos, "Drag to move | Mirror X/Y", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1.0, 0.9, 0.5, 0.9))

		TransformPhase.DRAGGING:
			# Draw ghost at new position
			var min_pos := _transform_rect_min()
			var max_pos := _transform_rect_max()
			var dest_min := min_pos + _transform_current_offset
			var top_left := grid_to_world(dest_min)
			var w := float((max_pos.x - min_pos.x + 1) * GRID_SIZE)
			var h := float((max_pos.y - min_pos.y + 1) * GRID_SIZE)
			# Ghost rectangle at destination
			_overlay.draw_rect(Rect2(top_left, Vector2(w, h)), Color(0.3, 0.9, 0.3, 0.25), true)
			_overlay.draw_rect(Rect2(top_left, Vector2(w, h)), Color(0.3, 1.0, 0.3, 0.9), false, 3.0)
			# Dim original position
			var orig_top_left := grid_to_world(min_pos)
			_overlay.draw_rect(Rect2(orig_top_left, Vector2(w, h)), Color(1.0, 0.3, 0.3, 0.15), true)
			_overlay.draw_rect(Rect2(orig_top_left, Vector2(w, h)), Color(1.0, 0.3, 0.3, 0.5), false, 2.0)


func _draw_building_preview() -> void:
	if editor_mode != EditorMode.BUILDING or selected_block == &"":
		return

	var data = Registry.get_block(selected_block)
	if data == null:
		return

	var mouse_world = get_global_mouse_position()
	var grid_pos = world_to_grid(mouse_world)

	# Center multi-tile buildings on the mouse cursor
	if data.grid_size.x > 1 or data.grid_size.y > 1:
		grid_pos -= Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)

	var world_pos = grid_to_world(grid_pos)
	var w := float(GRID_SIZE * data.grid_size.x)
	var h := float(GRID_SIZE * data.grid_size.y)

	# Check if placement is valid
	var valid := true
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var p = grid_pos + Vector2i(x, y)
			if not is_within_bounds(p) or placed_buildings.has(p):
				valid = false
				break
		if not valid:
			break

	# Vent-powered buildings must be centered on a vent tile
	if valid and data.tags.has("vent_powered"):
		var terrain = get_node_or_null("TerrainSystem")
		if terrain:
			var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
			if terrain.floor_tiles.get(center, &"") != &"vent":
				valid = false

	var color: Color
	if valid:
		if selected_faction == Faction.FEROX:
			color = Color(1.0, 0.3, 0.3, 0.35)
		else:
			color = Color(0.3, 0.7, 1.0, 0.35)
	else:
		color = Color(1.0, 0.0, 0.0, 0.25)

	_overlay.draw_rect(Rect2(world_pos, Vector2(w, h)), color, true)
	_overlay.draw_rect(Rect2(world_pos, Vector2(w, h)), color.lightened(0.3), false, 2.0)

	# Draw rotation arrow
	var center = world_pos + Vector2(w / 2.0, h / 2.0)
	var arrow_dir = [Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1)][placement_rotation]
	var arrow_end = center + arrow_dir * 16.0
	_overlay.draw_line(center, arrow_end, Color.WHITE, 2.0)


func _draw_links() -> void:
	var link_color := Color(0.3, 0.8, 1.0, 0.7)
	var half := Vector2(GRID_SIZE / 2.0, GRID_SIZE / 2.0)

	# Draw existing links
	for pair in linked_pairs:
		var world_a: Vector2 = grid_to_world(pair[0]) + half
		var world_b: Vector2 = grid_to_world(pair[1]) + half
		_draw_dashed_line(world_a, world_b, link_color, 2.0, 8.0)
		_overlay.draw_circle(world_a, 4.0, link_color)
		_overlay.draw_circle(world_b, 4.0, link_color)

	# Draw linking-mode highlights
	if not linking_mode:
		return

	# Highlight all linkable blocks
	for grid_pos in placed_buildings:
		var block_id = placed_buildings[grid_pos]
		var data = Registry.get_block(block_id)
		if data == null or not data.tags.has("linkable"):
			continue
		var world_pos: Vector2 = grid_to_world(grid_pos)
		var highlight_color := Color(0.3, 0.8, 1.0, 0.3)
		if grid_pos == link_source:
			highlight_color = Color(0.0, 1.0, 0.5, 0.5)
		_overlay.draw_rect(Rect2(world_pos, Vector2(GRID_SIZE, GRID_SIZE)), highlight_color, true)
		_overlay.draw_rect(Rect2(world_pos, Vector2(GRID_SIZE, GRID_SIZE)), highlight_color.lightened(0.3), false, 2.0)

	# Draw line from source to mouse
	if link_source != Vector2i(-1, -1):
		var source_world: Vector2 = grid_to_world(link_source) + half
		var mouse_pos: Vector2 = get_global_mouse_position()
		_draw_dashed_line(source_world, mouse_pos, Color(0.3, 1.0, 0.5, 0.5), 2.0, 6.0)


func _draw_dashed_line(from: Vector2, to: Vector2, color: Color, width: float, dash_length: float) -> void:
	var direction := to - from
	var length := direction.length()
	if length < 1.0:
		return
	var normalized := direction / length
	var drawn := 0.0
	var drawing := true
	while drawn < length:
		var segment := minf(dash_length, length - drawn)
		if drawing:
			_overlay.draw_line(
				from + normalized * drawn,
				from + normalized * (drawn + segment),
				color, width
			)
		drawn += segment
		drawing = not drawing
