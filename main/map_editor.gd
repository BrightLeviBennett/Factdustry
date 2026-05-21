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
const GRID_SIZE := 128
## Mirrors `main.gd` so BuildingSystem's `_ready` can scale sprite-pixel
## constants through `main.SPRITE_SCALE_FACTOR` regardless of which scene
## owns it (Main vs MapEditor).
const SPRITE_SCALE_FACTOR := float(GRID_SIZE) / 64.0
## Fog-of-war switches authored in the editor's Map Settings dialog.
## Serialized into the sector .json so the playtest scene's FogSystem
## picks them up on load.
var fog_enabled := true
var fog_darkness_mult := 1.0
var GRID_WIDTH := 100
var GRID_HEIGHT := 100

# --- FACTIONS (must match main.gd) ---
enum Faction { LUMINA, FEROX, DERELICT }

# --- BUILDING STATE ---
# Full building state for the editor (same dicts as main.gd).
var placed_buildings := {}
var building_health := {}
var building_rotation := {}
var building_origins := {}
var building_factions := {}
## Authored wave bundle — staged here in the editor, serialized into
## the sector .json by SaveManager, and consumed by WaveManager at
## runtime. Three pieces:
##   * editor_wave_config — global schedule + generation mode
##   * editor_wave_spawns — named spawn points
##   * editor_waves       — manual-mode wave list
var editor_wave_config: Dictionary = {
	"start_mode": "landing",
	"initial_delay": 30.0,
	"interval": 30.0,
	"generation_mode": "manual",
	"auto_wave_count": 10,
	"auto_unit_templates": [],
}
var editor_wave_spawns: Array = []
var editor_waves: Array = []

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
enum Tool { PENCIL, LINE, CIRCLE, RECT_FILL, RECT_ERASE, BUCKET }
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
# Last cell touched by paint/erase. Used to interpolate when the mouse
# moves fast enough that consecutive InputEventMouseMotion events skip
# over intermediate cells — we walk a Bresenham line from the last cell
# to the current one so the brush fills every cell on the cursor's
# path. Sentinel `_has_last_paint` distinguishes "no prior cell" from
# the legitimate cell (0, 0).
var _last_paint_cell := Vector2i.ZERO
var _has_last_paint := false

# Block drag-place / drag-erase state — mirrors the terrain stroke pattern
# so dragging the cursor across the map fills/erases every cell on the
# path (using Bresenham interpolation for fast cursor moves).
var _block_drag_placing := false
var _block_drag_erasing := false
var _block_drag_last_cell := Vector2i.ZERO
var _block_drag_has_last := false

# Rectangle tool state. `_rect_erasing` is set when the drag was started
# with the right mouse button — the rect tool then performs a rect erase
# on commit instead of a fill, so the player gets both behaviors out of
# the single Rect tool (left = fill, right = erase) without juggling two
# toolbar buttons.
var _rect_dragging := false
var _rect_erasing := false
var _rect_start := Vector2i.ZERO
var _rect_end := Vector2i.ZERO

# Line tool state. Drag from `_line_start` to `_line_end`; on release
# the cells along the Bresenham line get painted, optionally inflated
# by `line_size` so the brush stamps an N×N square at every line cell
# (size 1 = single-cell line). `_line_erasing` is set when the drag
# was started with the right mouse button so the commit erases instead
# of paints — same drag-button-distinguishes-action pattern as the
# rect tool.
var _line_dragging := false
var _line_erasing := false
var _line_start := Vector2i.ZERO
var _line_end := Vector2i.ZERO
var line_size: int = 1
## Circle tool: when true the disk is filled, when false only the
## ring (an outline `line_size` cells thick) is stamped. Toggled by
## the "Fill Circle" checkbox on the editor HUD top bar.
var circle_fill: bool = true

# Circle tool state. Drag from `_circle_center` outward; the radius
# follows the cursor and the commit stamps every cell whose euclidean
# distance from the center is ≤ radius. Right-drag erases instead of
# paints, mirroring the rect/line convention.
var _circle_dragging := false
var _circle_erasing := false
var _circle_center := Vector2i.ZERO
var _circle_edge := Vector2i.ZERO

# Undo / redo. Each stack entry is an Array of {cell, before, after}
# triples capturing the per-cell terrain state before and after a
# single user-visible operation (one stroke, one rect, one fill, one
# circle, …). Capturing is gated by `_undoing` so the act of applying
# an undo step doesn't itself enqueue a new step. `_undo_pending` is
# the open transaction — populated as cells are mutated and committed
# at the end of the operation.
const UNDO_LIMIT := 64
var _undo_stack: Array = []
var _redo_stack: Array = []
var _undo_pending: Dictionary = {}  # Vector2i → captured "before" state
var _undo_active := false  # True between _undo_begin / _undo_commit
var _undoing := false      # Suppresses capture while applying undo/redo

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
# `linking_mode` was a toggle entered/exited via the L key; replaced by
# Mindustry-style click-to-link (the source is implicit in `link_source`).
# Variable kept around for any save-format compatibility but is unused.
var linking_mode := false
var link_source := Vector2i(-1, -1)
var linked_pairs: Array = []  # Array of [Vector2i, Vector2i]


func _ready() -> void:
	_overlay.draw.connect(_draw_overlay)
	# BuildingSystem._ready sets its own z_index to 50 (so previews and
	# placed buildings paint over ground units in the main game), which
	# would bury the editor's overlay-drawn UI: grid lines, ghost block
	# preview, transform handles, rect/line/circle previews, link lines,
	# bucket/cable-range overlays, etc. Lift the overlay well above the
	# building layer so every editor cue stays visible.
	_overlay.z_index = 100
	_overlay.z_as_relative = false

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
		# Undo / redo. Cmd on macOS, Ctrl elsewhere — accept either so a
		# laptop docked to an external keyboard works the same as the
		# native one. Shift+Cmd+Z is redo (the macOS convention); Ctrl+Y
		# is also accepted for Windows/Linux muscle memory.
		if event.keycode == KEY_Z and (event.meta_pressed or event.ctrl_pressed):
			if event.shift_pressed:
				redo()
			else:
				undo()
			return
		if event.keycode == KEY_Y and event.ctrl_pressed:
			redo()
			return
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
		# Esc: close crane filter menu / exit crane link mode (mirrors the
		# in-game ui_cancel chain in BuildingSystem._input). This runs
		# before any other Esc-bound action so the editor's overall flow
		# isn't disturbed.
		if event.is_action_pressed("ui_cancel"):
			var bs_esc = get_node_or_null("BuildingSystem")
			if bs_esc:
				if bs_esc._crane_filter_menu_open:
					bs_esc._close_crane_filter_menu()
					return
				if bs_esc._crane_link_anchor != Vector2i(-1, -1):
					bs_esc._crane_link_anchor = Vector2i(-1, -1)
					bs_esc._crane_link_next_kind = "input"
					bs_esc.queue_redraw()
					return
			if link_source != Vector2i(-1, -1):
				link_source = Vector2i(-1, -1)
				_overlay.queue_redraw()
				return
		# Linking is now click-to-link (Mindustry-style): clicking a
		# `linkable` block in BUILDING mode selects it as the source, the
		# next click on another linkable block creates the pair. The L key
		# is kept only as a quick "cancel any in-flight link source" so a
		# muscle-memory press doesn't break anything.
		if event.keycode == KEY_L:
			if link_source != Vector2i(-1, -1):
				link_source = Vector2i(-1, -1)
				_overlay.queue_redraw()
			return

	if event is InputEventMouseButton:
		# Mouse-up: always release any block drag, regardless of mode.
		# (User may have switched modes mid-drag.)
		if not event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				_block_drag_placing = false
				if not _block_drag_erasing:
					_block_drag_has_last = false
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				_block_drag_erasing = false
				if not _block_drag_placing:
					_block_drag_has_last = false
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

		# (Click-to-link is handled inside the BUILDING-mode branch below;
		# the standalone "linking_mode" toggle is no longer required.)

		# --- Transform mode ---
		if editor_mode == EditorMode.TRANSFORM:
			_handle_transform_click(event, grid_pos)
			return

		# --- Building mode ---
		if editor_mode == EditorMode.BUILDING:
			# Crane link clicks (left + right) take priority over normal
			# building-mode clicks. Filter menu, link mode toggling, diamond
			# placement, and right-click delete all flow through the same
			# helpers used in-game.
			var bs_link = get_node_or_null("BuildingSystem")
			if bs_link and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				if bs_link._handle_crane_link_click(event):
					return
			if bs_link and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed \
					and bs_link._crane_link_anchor != Vector2i(-1, -1):
				if bs_link._handle_crane_link_right_click():
					return
			if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				# World-menu handling: if the world menu is already open,
				# resolve the click against it first. Then, with no block
				# selected from the palette, left-clicking on a sorter /
				# constructor / refabricator / archive opens its menu so
				# authors can bake selections into the sector.
				var bs = get_node_or_null("BuildingSystem")
				if bs and bs.get("_world_menu_open"):
					var mouse_world = get_global_mouse_position()
					var hit: int = bs._world_menu_hit_test(mouse_world)
					if hit >= 0:
						bs._apply_world_menu_selection(hit)
					else:
						bs._close_world_menu()
					return
				# Clicking on an already-placed block opens its in-world UI
				# (sorter / constructor / refabricator / archive) or starts
				# a link click if the block is `linkable`. The editor
				# always has *something* selected in the palette, so we
				# can't gate this on `selected_block == &""` like the
				# campaign does — instead we hijack the click whenever the
				# clicked cell is already occupied (placement would fail
				# there anyway, since `_place_block_at` refuses to overlap).
				if placed_buildings.has(grid_pos):
					var click_block_id = placed_buildings[grid_pos]
					var click_data = Registry.get_block(click_block_id)
					var click_anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
					if click_data and bs:
						if click_data.tags.has("sorter") \
								or click_data.tags.has("inverted_sorter") \
								or click_data.tags.has("unloader"):
							bs._open_world_menu("sorter", click_anchor)
							return
						if click_data.tags.has("constructor"):
							bs._open_world_menu("constructor", click_anchor)
							return
						if click_data.tags.has("refabricator"):
							bs._open_world_menu("refabricator", click_anchor)
							return
						if click_data.id == &"archive":
							bs._open_world_menu("archive", click_anchor)
							return
					# Click-to-link (Mindustry-style): clicking a `linkable`
					# block picks/chains a link.
					if click_data and click_data.tags.has("linkable"):
						_handle_link_click(click_anchor)
						return
					# Clicking a non-linkable block clears any pending source.
					if link_source != Vector2i(-1, -1):
						link_source = Vector2i(-1, -1)
						_overlay.queue_redraw()
				# Center multi-tile buildings on the mouse cursor
				_place_block_centered(grid_pos)
				# Begin a drag: subsequent mouse motion fills cells along
				# the cursor's path.
				if selected_block != &"":
					_block_drag_placing = true
					_block_drag_last_cell = grid_pos
					_block_drag_has_last = true
			elif event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
				_block_drag_placing = false
				_block_drag_has_last = false
			elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
				# Close an open world menu without erasing the block beneath.
				var bs_r = get_node_or_null("BuildingSystem")
				if bs_r and bs_r.get("_world_menu_open"):
					bs_r._close_world_menu()
					return
				_erase_block_at(grid_pos)
				_block_drag_erasing = true
				_block_drag_last_cell = grid_pos
				_block_drag_has_last = true
			elif event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed:
				_block_drag_erasing = false
				_block_drag_has_last = false
			return

		# --- Bucket flood-fill (terrain mode) ---
		# One click = fill all 4-connected cells whose current floor matches
		# the clicked cell's.
		if current_tool == Tool.BUCKET:
			if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				_undo_begin()
				_flood_fill_at(grid_pos)
				_undo_commit()
				_overlay.queue_redraw()
			return

		# --- Line tool (terrain mode) ---
		# Left-drag stamps the line with the selected tile. Right-drag
		# erases instead — same convention as the rect tool. `line_size`
		# thickens the brush into an N×N square at every cell along the
		# line.
		if current_tool == Tool.LINE:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					_line_dragging = true
					_line_erasing = false
					_line_start = grid_pos
					_line_end = grid_pos
					_overlay.queue_redraw()
				elif _line_dragging and not _line_erasing:
					_line_dragging = false
					_undo_begin()
					_apply_line()
					_undo_commit()
					_overlay.queue_redraw()
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				if event.pressed:
					_line_dragging = true
					_line_erasing = true
					_line_start = grid_pos
					_line_end = grid_pos
					_overlay.queue_redraw()
				elif _line_dragging and _line_erasing:
					_line_dragging = false
					_undo_begin()
					_apply_line()
					_undo_commit()
					_overlay.queue_redraw()
			return

		# --- Circle tool (terrain mode) ---
		# Left-drag from center to edge stamps a filled disk; right-drag
		# erases the same shape. `line_size` controls brush thickness so
		# you can fatten the result without redoing the gesture.
		if current_tool == Tool.CIRCLE:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					_circle_dragging = true
					_circle_erasing = false
					_circle_center = grid_pos
					_circle_edge = grid_pos
					_overlay.queue_redraw()
				elif _circle_dragging and not _circle_erasing:
					_circle_dragging = false
					_undo_begin()
					_apply_circle()
					_undo_commit()
					_overlay.queue_redraw()
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				if event.pressed:
					_circle_dragging = true
					_circle_erasing = true
					_circle_center = grid_pos
					_circle_edge = grid_pos
					_overlay.queue_redraw()
				elif _circle_dragging and _circle_erasing:
					_circle_dragging = false
					_undo_begin()
					_apply_circle()
					_undo_commit()
					_overlay.queue_redraw()
			return

		# --- Rectangle tool (terrain mode) ---
		# Left-drag fills the rect with the selected tile; right-drag
		# erases the rect. `RECT_ERASE` is kept as a separate tool for
		# players who prefer the explicit affordance, but the same
		# functionality is available off the right button in RECT_FILL
		# mode so they don't have to swap tools to clean up a misclick.
		if current_tool == Tool.RECT_FILL or current_tool == Tool.RECT_ERASE:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					_rect_dragging = true
					_rect_erasing = (current_tool == Tool.RECT_ERASE)
					_rect_start = grid_pos
					_rect_end = grid_pos
				else:
					if _rect_dragging:
						_rect_dragging = false
						_undo_begin()
						_apply_rect()
						_undo_commit()
						_overlay.queue_redraw()
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				if event.pressed and current_tool == Tool.RECT_FILL:
					# Right-drag in RECT_FILL = erase rect.
					_rect_dragging = true
					_rect_erasing = true
					_rect_start = grid_pos
					_rect_end = grid_pos
				elif not event.pressed and _rect_dragging and _rect_erasing and current_tool == Tool.RECT_FILL:
					_rect_dragging = false
					_undo_begin()
					_apply_rect()
					_undo_commit()
					_overlay.queue_redraw()
				elif event.pressed:
					# Right-press in RECT_ERASE: cancel any in-progress drag.
					_rect_dragging = false
					_overlay.queue_redraw()
			return

		# --- Pencil / Eraser (terrain mode) ---
		# Each press-to-release stroke wraps a single undo transaction
		# so a long zigzag undoes in one step rather than cell-by-cell.
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_painting = true
				_has_last_paint = false  # Fresh stroke — no interpolation source yet.
				_undo_begin()
				_paint_at(grid_pos)
				_last_paint_cell = grid_pos
				_has_last_paint = true
			else:
				_painting = false
				_has_last_paint = false
				_undo_commit()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_erasing = true
				_has_last_paint = false
				_undo_begin()
				_erase_at(grid_pos)
				_last_paint_cell = grid_pos
				_has_last_paint = true
			else:
				_erasing = false
				_has_last_paint = false
				_undo_commit()

	elif event is InputEventMouseMotion:
		if editor_mode == EditorMode.SCRIPT:
			return
		var grid_pos := world_to_grid(get_global_mouse_position())
		if not is_within_bounds(grid_pos):
			return

		if editor_mode == EditorMode.TRANSFORM:
			_handle_transform_motion(grid_pos)
			return
		elif link_source != Vector2i(-1, -1):
			_overlay.queue_redraw()  # Update dashed link line to mouse
		elif editor_mode == EditorMode.BUILDING:
			_overlay.queue_redraw()  # Update building preview
			# Drag-place / drag-erase fills cells along the cursor path so a
			# fast drag doesn't skip tiles.
			if _block_drag_placing:
				_block_drag_stroke_to(grid_pos, false)
			elif _block_drag_erasing:
				_block_drag_stroke_to(grid_pos, true)
		elif _rect_dragging:
			_rect_end = grid_pos
			_overlay.queue_redraw()
		elif _line_dragging:
			_line_end = grid_pos
			_overlay.queue_redraw()
		elif _circle_dragging:
			_circle_edge = grid_pos
			_overlay.queue_redraw()
		elif _painting:
			_paint_stroke_to(grid_pos, false)
		elif _erasing:
			_paint_stroke_to(grid_pos, true)


# --- TERRAIN PAINTING ---

func _paint_at(grid_pos: Vector2i) -> void:
	if selected_tile == &"":
		return
	_undo_capture(grid_pos)
	$TerrainSystem.place_tile(grid_pos, selected_tile)


func _erase_at(grid_pos: Vector2i) -> void:
	_undo_capture(grid_pos)
	$TerrainSystem.remove_tile(grid_pos)


# =========================
# UNDO / REDO
# =========================

## Snapshots the current floor/wall/ore state of `cell` so a later
## `_undo_commit` can record what changed. Cheap to call repeatedly —
## only the FIRST capture for a given cell within an open transaction
## is kept (subsequent calls are noops), so a stroke that paints the
## same cell three times still gets undone in one step.
func _undo_capture(cell: Vector2i) -> void:
	if _undoing or not _undo_active:
		return
	if _undo_pending.has(cell):
		return
	_undo_pending[cell] = _capture_cell_state(cell)


func _capture_cell_state(cell: Vector2i) -> Dictionary:
	var t = $TerrainSystem
	return {
		"floor": t.floor_tiles.get(cell, null),
		"wall": t.wall_tiles.get(cell, null),
		"ore": t.ore_tiles.get(cell, null),
	}


## Begin a new undo transaction. Subsequent terrain mutations within
## the same operation will accumulate into a single undoable step.
func _undo_begin() -> void:
	_undo_pending = {}
	_undo_active = true


## Close the current undo transaction. If anything actually changed,
## push it onto the undo stack and clear the redo stack (any new edit
## invalidates redo, same as every other editor in the world).
func _undo_commit() -> void:
	_undo_active = false
	if _undo_pending.is_empty():
		return
	var step: Array = []
	for cell in _undo_pending:
		var before: Dictionary = _undo_pending[cell]
		var after: Dictionary = _capture_cell_state(cell)
		if before["floor"] == after["floor"] \
				and before["wall"] == after["wall"] \
				and before["ore"] == after["ore"]:
			continue
		step.append({"cell": cell, "before": before, "after": after})
	_undo_pending = {}
	if step.is_empty():
		return
	_undo_stack.append(step)
	if _undo_stack.size() > UNDO_LIMIT:
		_undo_stack.pop_front()
	_redo_stack.clear()


## Pops the most recent undo step and rolls every cell back to its
## pre-operation state. Suppresses re-capture during the rollback so
## the operation itself doesn't get re-recorded as a new step.
func undo() -> void:
	if _undo_stack.is_empty():
		return
	var step: Array = _undo_stack.pop_back()
	_undoing = true
	for entry in step:
		_restore_cell_state(entry["cell"], entry["before"])
	_undoing = false
	$TerrainSystem.queue_redraw()
	_redo_stack.append(step)


## Replays the most recently undone step.
func redo() -> void:
	if _redo_stack.is_empty():
		return
	var step: Array = _redo_stack.pop_back()
	_undoing = true
	for entry in step:
		_restore_cell_state(entry["cell"], entry["after"])
	_undoing = false
	$TerrainSystem.queue_redraw()
	_undo_stack.append(step)
	if _undo_stack.size() > UNDO_LIMIT:
		_undo_stack.pop_front()


## Sets a cell's floor/wall/ore dictionaries directly to the captured
## snapshot. Bypasses TerrainSystem.place_tile/remove_tile so we
## restore the EXACT prior state (including ore-on-wall combinations
## that the normal placement path won't reproduce in a single call).
func _restore_cell_state(cell: Vector2i, state: Dictionary) -> void:
	var t = $TerrainSystem
	if state["floor"] == null:
		t.floor_tiles.erase(cell)
	else:
		t.floor_tiles[cell] = state["floor"]
	if state["wall"] == null:
		t.wall_tiles.erase(cell)
	else:
		t.wall_tiles[cell] = state["wall"]
	if state["ore"] == null:
		t.ore_tiles.erase(cell)
	else:
		t.ore_tiles[cell] = state["ore"]
	t._floor_edge_dirty = true
	t._water_depth_dirty = true


## Continues an in-progress paint/erase stroke to `grid_pos`. Walks a
## Bresenham line from the previous cell so a fast mouse swipe — where
## the OS only delivers motion events every few cells — still fills
## every cell along the cursor's path instead of leaving a dotted
## trail. `erase` chooses between erase and paint behavior; the start
## cell is skipped because it was already painted by the previous call.
func _paint_stroke_to(grid_pos: Vector2i, erase: bool) -> void:
	if not _has_last_paint or _last_paint_cell == grid_pos:
		if erase:
			_erase_at(grid_pos)
		else:
			_paint_at(grid_pos)
		_last_paint_cell = grid_pos
		_has_last_paint = true
		return
	for cell in _line_cells(_last_paint_cell, grid_pos):
		if cell == _last_paint_cell:
			continue  # Already painted by the previous step.
		if not is_within_bounds(cell):
			continue
		if erase:
			_erase_at(cell)
		else:
			_paint_at(cell)
	_last_paint_cell = grid_pos


## Bresenham line between two grid cells, inclusive of both endpoints.
## Used by stroke interpolation so a fast brush stroke covers every
## cell on the cursor's path.
func _line_cells(a: Vector2i, b: Vector2i) -> Array:
	var cells: Array = []
	var x0: int = a.x
	var y0: int = a.y
	var x1: int = b.x
	var y1: int = b.y
	var dx: int = absi(x1 - x0)
	var dy: int = -absi(y1 - y0)
	var sx: int = 1 if x0 < x1 else -1
	var sy: int = 1 if y0 < y1 else -1
	var err: int = dx + dy
	while true:
		cells.append(Vector2i(x0, y0))
		if x0 == x1 and y0 == y1:
			break
		var e2: int = 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
	return cells


func _apply_rect() -> void:
	var terrain = $TerrainSystem
	var min_x := mini(_rect_start.x, _rect_end.x)
	var min_y := mini(_rect_start.y, _rect_end.y)
	var max_x := maxi(_rect_start.x, _rect_end.x)
	var max_y := maxi(_rect_start.y, _rect_end.y)

	# `_rect_erasing` distinguishes a fill from an erase regardless of
	# which tool started the drag — left-drag in RECT_FILL fills,
	# right-drag in RECT_FILL or any drag in RECT_ERASE erases.
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			var cell := Vector2i(x, y)
			if not is_within_bounds(cell):
				continue
			_undo_capture(cell)
			if _rect_erasing:
				terrain.remove_tile(cell)
			elif selected_tile != &"":
				terrain.place_tile(cell, selected_tile)

	terrain.queue_redraw()


## Stamps the line tool's drag onto the terrain. Walks a Bresenham line
## from `_line_start` to `_line_end` and, for each cell, paints an
## `line_size`×`line_size` square centered on it (size 1 = single
## cell). Skips cells outside the world bounds. `_line_erasing`
## flips the operation from paint to erase — same drag-button-decides
## convention as the rect tool.
func _apply_line() -> void:
	if not _line_erasing and selected_tile == &"":
		return
	var terrain = $TerrainSystem
	var thickness: int = maxi(1, line_size)
	var half: int = thickness / 2
	var painted: Dictionary = {}
	for cell in _line_cells(_line_start, _line_end):
		for dx in range(-half, -half + thickness):
			for dy in range(-half, -half + thickness):
				var p := Vector2i(cell.x + dx, cell.y + dy)
				if painted.has(p):
					continue
				if not is_within_bounds(p):
					continue
				painted[p] = true
				_undo_capture(p)
				if _line_erasing:
					terrain.remove_tile(p)
				else:
					terrain.place_tile(p, selected_tile)
	terrain.queue_redraw()


## Stamps the circle tool's drag. Treats `_circle_center` as the
## center and `_circle_edge` as a point on the ring; every cell whose
## euclidean distance from the center is ≤ that radius gets painted
## (or erased, depending on `_circle_erasing`). `line_size` reuses the
## line tool's thickness control: when > 1 the brush stamps an N×N
## square at every disk cell, fattening the result without changing
## the overall shape.
func _apply_circle() -> void:
	if not _circle_erasing and selected_tile == &"":
		return
	var terrain = $TerrainSystem
	var thickness: int = maxi(1, line_size)
	var half: int = thickness / 2
	var painted: Dictionary = {}
	# +0.5 so a click that ends exactly on a cell edge still includes
	# that cell — without it, drag-distance just under 1 produces
	# nothing.
	var radius: float = Vector2(_circle_edge - _circle_center).length() + 0.5
	var rceil: int = int(ceil(radius))
	var r2: float = radius * radius
	# Outline mode: only paint cells inside the disk that have at
	# least one cardinal neighbour OUTSIDE the disk — i.e. the
	# perimeter band. The brush thickness still fattens it via the
	# inner tx/ty loop, so `line_size` controls the ring width.
	var outline_only: bool = not circle_fill
	for dx in range(-rceil, rceil + 1):
		for dy in range(-rceil, rceil + 1):
			var d2: float = float(dx * dx + dy * dy)
			if d2 > r2:
				continue
			if outline_only:
				var on_edge: bool = \
					float((dx + 1) * (dx + 1) + dy * dy) > r2 \
					or float((dx - 1) * (dx - 1) + dy * dy) > r2 \
					or float(dx * dx + (dy + 1) * (dy + 1)) > r2 \
					or float(dx * dx + (dy - 1) * (dy - 1)) > r2
				if not on_edge:
					continue
			var center_cell := _circle_center + Vector2i(dx, dy)
			for tx in range(-half, -half + thickness):
				for ty in range(-half, -half + thickness):
					var p := Vector2i(center_cell.x + tx, center_cell.y + ty)
					if painted.has(p):
						continue
					if not is_within_bounds(p):
						continue
					painted[p] = true
					_undo_capture(p)
					if _circle_erasing:
						terrain.remove_tile(p)
					else:
						terrain.place_tile(p, selected_tile)
	terrain.queue_redraw()


## 4-connected flood fill starting at `start`. Replaces every cell whose
## current floor tile id matches the start cell's with `selected_tile`.
## When `selected_tile` is empty, the fill erases instead — useful for
## carving out a void region without painting it cell-by-cell.
##
## "Source tile" includes the empty/void state, so clicking on a void cell
## with grass selected fills the whole connected void region with grass.
## Walls block the spread (you can't fill across a wall) so a closed pen
## fills only its interior.
func _flood_fill_at(start: Vector2i) -> void:
	if not is_within_bounds(start):
		return
	var terrain = $TerrainSystem
	var source_tile: StringName = StringName(terrain.floor_tiles.get(start, &""))
	var target_tile: StringName = selected_tile
	# No-op if clicking on a cell that already matches the brush — a fill
	# that paints what's already there has nothing to do.
	if source_tile == target_tile:
		return
	var stack: Array[Vector2i] = [start]
	var visited: Dictionary = {start: true}
	# Hard cap so a fill on a pathologically large connected region can't
	# stall the editor.
	var max_cells: int = 200000
	var filled := 0
	while not stack.is_empty() and filled < max_cells:
		var cell: Vector2i = stack.pop_back()
		var here: StringName = StringName(terrain.floor_tiles.get(cell, &""))
		if here != source_tile:
			continue
		# Walls form a hard boundary — fills don't bleed across them.
		if terrain.has_method("has_wall") and terrain.has_wall(cell):
			continue
		_undo_capture(cell)
		if target_tile == &"":
			terrain.remove_tile(cell)
		else:
			terrain.place_tile(cell, target_tile)
		filled += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nb: Vector2i = cell + d
			if not is_within_bounds(nb):
				continue
			if visited.has(nb):
				continue
			visited[nb] = true
			stack.append(nb)
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
	var _captured_multi_origins := {}

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

## Helper: place `selected_block` centered on the cursor's grid cell.
## Multi-tile blocks shift the anchor by half their footprint so the cell
## under the cursor sits in the middle of the placed block.
func _place_block_centered(grid_pos: Vector2i) -> void:
	if selected_block == &"":
		return
	var place_pos := grid_pos
	var sel_data = Registry.get_block(selected_block)
	if sel_data and (sel_data.grid_size.x > 1 or sel_data.grid_size.y > 1):
		place_pos -= Vector2i(sel_data.grid_size.x / 2, sel_data.grid_size.y / 2)
	_place_block_at(place_pos)


## Drag-stroke for block placement / erasure. Walks a Bresenham line from
## the previous drag cell to `grid_pos` so the operation lands on every
## cell the cursor swept over (motion events can skip tiles when the
## cursor moves quickly).
func _block_drag_stroke_to(grid_pos: Vector2i, erase: bool) -> void:
	if not _block_drag_has_last or _block_drag_last_cell == grid_pos:
		if erase:
			_erase_block_at(grid_pos)
		else:
			_place_block_centered(grid_pos)
		_block_drag_last_cell = grid_pos
		_block_drag_has_last = true
		return
	for cell in _line_cells(_block_drag_last_cell, grid_pos):
		if cell == _block_drag_last_cell:
			continue
		if not is_within_bounds(cell):
			continue
		if erase:
			_erase_block_at(cell)
		else:
			_place_block_centered(cell)
	_block_drag_last_cell = grid_pos


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

## Click-to-link click handler. Always called with a building anchor (so
## `linked_pairs` stays normalized — without this, clicking a sub-cell of a
## multi-tile block would store a stale cell that never matches the anchor
## passed to `_remove_links_for` on erase, leaving dashed lines pointing at
## empty space).
func _handle_link_click(grid_pos: Vector2i) -> void:
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	if not placed_buildings.has(anchor):
		return
	var data = Registry.get_block(placed_buildings[anchor])
	if data == null or not data.tags.has("linkable"):
		return

	# Click on the current source — deselect.
	if anchor == link_source:
		link_source = Vector2i(-1, -1)
		_overlay.queue_redraw()
		return

	if link_source == Vector2i(-1, -1):
		# First click — remember source.
		link_source = anchor
		_overlay.queue_redraw()
		return

	# Source already set: validate compatibility (bridge↔bridge, MD↔MD)
	# before linking. Mismatched pairs reset the source instead of
	# silently failing.
	var source_data = Registry.get_block(placed_buildings.get(link_source, &""))
	if source_data == null:
		link_source = anchor
		_overlay.queue_redraw()
		return
	var src_bridge: bool = source_data.tags.has("bridge")
	var tgt_bridge: bool = data.tags.has("bridge")
	var src_md: bool = source_data.tags.has("mass_driver")
	var tgt_md: bool = data.tags.has("mass_driver")
	if src_bridge != tgt_bridge or src_md != tgt_md:
		link_source = anchor
		_overlay.queue_redraw()
		return

	# Range gate (mirrors BuildingSystem._handle_link_click_on_anchor).
	var max_range: float = maxf(source_data.link_range, data.link_range)
	if max_range > 0.0:
		var dx: float = float(anchor.x - link_source.x)
		var dy: float = float(anchor.y - link_source.y)
		if sqrt(dx * dx + dy * dy) > max_range:
			link_source = anchor
			_overlay.queue_redraw()
			return

	# 1:1 link — drop any existing partner on either endpoint first.
	_remove_links_for(link_source)
	_remove_links_for(anchor)
	linked_pairs.append([link_source, anchor])
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
	_draw_line_preview()
	_draw_circle_preview()
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

	# Color reflects what the drag will commit: red for an erase
	# (right-drag in RECT_FILL or any drag in RECT_ERASE), green for
	# a fill — `_rect_erasing` is set at drag-start.
	var color: Color
	if _rect_erasing:
		color = Color(1, 0, 0, 0.2)
	else:
		color = Color(0.2, 0.8, 0.2, 0.2)

	_overlay.draw_rect(Rect2(top_left, Vector2(w, h)), color, true)
	_overlay.draw_rect(Rect2(top_left, Vector2(w, h)), color.lightened(0.3), false, 2.0)


func _draw_line_preview() -> void:
	if not _line_dragging:
		return
	var thickness: int = maxi(1, line_size)
	var half: int = thickness / 2
	var color := Color(1, 0, 0, 0.2) if _line_erasing else Color(0.2, 0.8, 0.2, 0.2)
	var border := color.lightened(0.3)
	var seen: Dictionary = {}
	var gs: float = float(GRID_SIZE)
	for cell in _line_cells(_line_start, _line_end):
		for dx in range(-half, -half + thickness):
			for dy in range(-half, -half + thickness):
				var p := Vector2i(cell.x + dx, cell.y + dy)
				if seen.has(p):
					continue
				if not is_within_bounds(p):
					continue
				seen[p] = true
				var wp := grid_to_world(p)
				_overlay.draw_rect(Rect2(wp, Vector2(gs, gs)), color, true)
				_overlay.draw_rect(Rect2(wp, Vector2(gs, gs)), border, false, 1.0)


func _draw_circle_preview() -> void:
	if not _circle_dragging:
		return
	var thickness: int = maxi(1, line_size)
	var half: int = thickness / 2
	var color := Color(1, 0, 0, 0.2) if _circle_erasing else Color(0.2, 0.8, 0.2, 0.2)
	var border := color.lightened(0.3)
	var seen: Dictionary = {}
	var gs: float = float(GRID_SIZE)
	var radius: float = Vector2(_circle_edge - _circle_center).length() + 0.5
	var rceil: int = int(ceil(radius))
	var r2: float = radius * radius
	var outline_only: bool = not circle_fill
	for dx in range(-rceil, rceil + 1):
		for dy in range(-rceil, rceil + 1):
			if float(dx * dx + dy * dy) > r2:
				continue
			if outline_only:
				var on_edge: bool = \
					float((dx + 1) * (dx + 1) + dy * dy) > r2 \
					or float((dx - 1) * (dx - 1) + dy * dy) > r2 \
					or float(dx * dx + (dy + 1) * (dy + 1)) > r2 \
					or float(dx * dx + (dy - 1) * (dy - 1)) > r2
				if not on_edge:
					continue
			var center_cell := _circle_center + Vector2i(dx, dy)
			for tx in range(-half, -half + thickness):
				for ty in range(-half, -half + thickness):
					var p := Vector2i(center_cell.x + tx, center_cell.y + ty)
					if seen.has(p):
						continue
					if not is_within_bounds(p):
						continue
					seen[p] = true
					var wp := grid_to_world(p)
					_overlay.draw_rect(Rect2(wp, Vector2(gs, gs)), color, true)
					_overlay.draw_rect(Rect2(wp, Vector2(gs, gs)), border, false, 1.0)


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
		match selected_faction:
			Faction.FEROX:    color = Color(1.0, 0.3, 0.3, 0.35)
			Faction.DERELICT: color = Color(0.55, 0.55, 0.55, 0.35)
			_:                color = Color(0.3, 0.7, 1.0, 0.35)
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

	# Draw existing links — lazily prune stale pairs whose endpoints no
	# longer have a placed block (e.g. erase didn't catch them when the
	# pair was stored against a non-anchor cell pre-fix).
	for i in range(linked_pairs.size() - 1, -1, -1):
		var pair = linked_pairs[i]
		if not placed_buildings.has(pair[0]) or not placed_buildings.has(pair[1]):
			linked_pairs.remove_at(i)
			continue
		var world_a: Vector2 = grid_to_world(pair[0]) + half
		var world_b: Vector2 = grid_to_world(pair[1]) + half
		_draw_dashed_line(world_a, world_b, link_color, 2.0, 8.0)
		_overlay.draw_circle(world_a, 4.0, link_color)
		_overlay.draw_circle(world_b, 4.0, link_color)

	# No source selected → no linking-mode UI to draw.
	if link_source == Vector2i(-1, -1):
		return

	# Highlight all linkable blocks (and the chosen source in green).
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

	# Draw line from source to mouse.
	var source_world: Vector2 = grid_to_world(link_source) + half
	var mouse_pos: Vector2 = get_global_mouse_position()
	_draw_dashed_line(source_world, mouse_pos, Color(0.3, 1.0, 0.5, 0.5), 2.0, 6.0)

	# Range circle (when the source block has a non-zero link_range).
	var src_block_id: StringName = placed_buildings.get(link_source, &"")
	var src_data2 = Registry.get_block(src_block_id)
	if src_data2 and src_data2.link_range > 0.0:
		_overlay.draw_arc(source_world, src_data2.link_range * GRID_SIZE,
			0.0, TAU, 96, Color(0.3, 1.0, 0.5, 0.5), 1.5)


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
