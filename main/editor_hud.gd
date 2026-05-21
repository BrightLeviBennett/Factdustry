extends CanvasLayer

# ============================================================
# EDITOR_HUD.GD - Map Editor UI
# ============================================================
# Top toolbar: mode toggle, tool buttons, map name, save/load/new/back
# Left palette: tile/block grid with category tabs + faction selector
# Load popup: list of saved maps and sectors
# ============================================================

var main: Node2D

# Toolbar
var tool_buttons := {}  # Tool enum → Button
var mode_buttons := {}  # EditorMode → Button
var map_name_input: LineEdit

# Tile palette (terrain mode)
var tile_grid: GridContainer
var category_buttons := {}  # TileCategory → Button
var selected_category: int = TerrainTileData.TileCategory.FLOOR
var tile_buttons := {}  # StringName tile_id → Button
var selected_tile_btn: Button = null

# Block palette (building mode)
var block_grid: GridContainer
var block_cat_buttons := {}  # BlockCategory → Button
var selected_block_category: int = BlockData.BlockCategory.EXTRACTORS
var block_buttons := {}  # StringName block_id → Button
var selected_block_btn: Button = null

# Faction selector
var faction_buttons := {}  # Faction int → Button

# Palette containers (swapped based on mode)
# Transform mode buttons
var mirror_x_btn: Button
var mirror_y_btn: Button
var convert_faction_btn: Button
var line_size_label: Label
var line_size_spin: SpinBox
var circle_fill_check: CheckBox

# Faction conversion popup
var faction_popup: PanelContainer
var _convert_faction_choice: int = 0  # Faction enum value

var terrain_palette: Control
var building_palette: Control

# Load popup
var load_popup: PanelContainer
var load_list: VBoxContainer

# Status label
var status_label: Label
var _status_timer := 0.0

# Cursor position label
var cursor_pos_label: Label

const TILE_BTN_SIZE := 48
const GRID_COLS := 4


var script_editor_panel: Node = null
var wave_editor_panel: Node = null
var wave_editor_btn: Button = null
var _toolbar_hbox: HBoxContainer = null

func _ready() -> void:
	await get_tree().process_frame
	main = get_node("/root/Main")
	_create_toolbar()
	_create_palette()
	_create_load_popup()
	_create_faction_popup()
	_create_status_label()
	_create_script_editor()
	_create_wave_editor()
	_populate_tiles(selected_category)
	_update_mode_visibility()


func _process(delta: float) -> void:
	if _status_timer > 0:
		_status_timer -= delta
		if _status_timer <= 0:
			status_label.visible = false

	# Update cursor grid position
	if cursor_pos_label and main:
		var grid_pos: Vector2i = main.world_to_grid(main.get_global_mouse_position())
		cursor_pos_label.text = "x: %d, y: %d" % [grid_pos.x, grid_pos.y]


# =========================
# TOOLBAR (TOP)
# =========================

func _create_toolbar() -> void:
	var toolbar = PanelContainer.new()
	toolbar.anchor_right = 1.0
	toolbar.offset_bottom = 44
	toolbar.add_theme_stylebox_override("panel", _panel_style(Color(0, 0, 0, 0.7)))
	add_child(toolbar)

	# Scroll horizontally when the toolbar can't fit all its widgets.
	# Vertical scroll is disabled — the bar is one row and the content
	# is sized to its natural height.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	toolbar.add_child(scroll)

	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	scroll.add_child(hbox)
	_toolbar_hbox = hbox

	# Mode toggle buttons
	_add_mode_btn(hbox, "Terrain", main.EditorMode.TERRAIN)
	_add_mode_btn(hbox, "Buildings", main.EditorMode.BUILDING)
	_add_mode_btn(hbox, "Transform", main.EditorMode.TRANSFORM)
	_add_mode_btn(hbox, "Script", main.EditorMode.SCRIPT)

	# Separator
	var sep = VSeparator.new()
	sep.custom_minimum_size.x = 12
	hbox.add_child(sep)

	# Tool buttons (terrain mode tools)
	_add_tool_btn(hbox, "Pencil", main.Tool.PENCIL)
	_add_tool_btn(hbox, "Line", main.Tool.LINE)
	_add_tool_btn(hbox, "Circle", main.Tool.CIRCLE)
	_add_tool_btn(hbox, "Bucket", main.Tool.BUCKET)
	_add_tool_btn(hbox, "Rect Fill", main.Tool.RECT_FILL)
	_add_tool_btn(hbox, "Rect Erase", main.Tool.RECT_ERASE)

	# Line-thickness spinner. Visible only while the Line tool is
	# selected (handled in _update_tool_highlight). Drives main.line_size,
	# which the line tool reads when stamping its Bresenham line.
	line_size_label = Label.new()
	line_size_label.text = "Size:"
	line_size_label.add_theme_font_size_override("font_size", 12)
	hbox.add_child(line_size_label)
	line_size_spin = SpinBox.new()
	line_size_spin.min_value = 1
	line_size_spin.max_value = 16
	line_size_spin.step = 1
	line_size_spin.value = main.line_size
	line_size_spin.custom_minimum_size = Vector2(56, 0)
	line_size_spin.value_changed.connect(func(v: float): main.line_size = int(v))
	hbox.add_child(line_size_spin)

	# Circle-fill toggle. Only meaningful while the Circle tool is
	# selected — visibility tracks the same gate as `line_size_spin`.
	# Drives `main.circle_fill`; when off, `_apply_circle` stamps just
	# the ring instead of the filled disk.
	circle_fill_check = CheckBox.new()
	circle_fill_check.text = "Fill Circle"
	circle_fill_check.tooltip_text = "When off, the Circle tool draws an outline ring instead of a filled disk."
	circle_fill_check.button_pressed = main.circle_fill
	circle_fill_check.add_theme_font_size_override("font_size", 12)
	circle_fill_check.toggled.connect(func(v: bool): main.circle_fill = v)
	hbox.add_child(circle_fill_check)

	# Mirror buttons (transform mode only)
	var sep_transform = VSeparator.new()
	sep_transform.custom_minimum_size.x = 6
	hbox.add_child(sep_transform)

	mirror_x_btn = Button.new()
	mirror_x_btn.text = "Mirror X"
	mirror_x_btn.tooltip_text = "Flip selection horizontally"
	mirror_x_btn.pressed.connect(func(): main.transform_mirror_x())
	mirror_x_btn.visible = false
	hbox.add_child(mirror_x_btn)

	mirror_y_btn = Button.new()
	mirror_y_btn.text = "Mirror Y"
	mirror_y_btn.tooltip_text = "Flip selection vertically"
	mirror_y_btn.pressed.connect(func(): main.transform_mirror_y())
	mirror_y_btn.visible = false
	hbox.add_child(mirror_y_btn)

	convert_faction_btn = Button.new()
	convert_faction_btn.text = "Convert Faction"
	convert_faction_btn.tooltip_text = "Convert selected blocks to a different faction"
	convert_faction_btn.pressed.connect(_on_convert_faction)
	convert_faction_btn.visible = false
	hbox.add_child(convert_faction_btn)

	# Separator
	var sep2 = VSeparator.new()
	sep2.custom_minimum_size.x = 20
	hbox.add_child(sep2)

	# Map name
	var name_label = Label.new()
	name_label.text = "Name:"
	hbox.add_child(name_label)

	map_name_input = LineEdit.new()
	map_name_input.text = "untitled"
	map_name_input.custom_minimum_size.x = 120
	hbox.add_child(map_name_input)

	# Action buttons
	_add_action_btn(hbox, "Save Sector", _on_save_sector)
	_add_action_btn(hbox, "Load", _on_load)
	_add_action_btn(hbox, "New", _on_new)

	# View toggles
	var sep_toggles = VSeparator.new()
	sep_toggles.custom_minimum_size.x = 6
	hbox.add_child(sep_toggles)

	var grid_btn = CheckButton.new()
	grid_btn.text = "Grid"
	grid_btn.button_pressed = true
	grid_btn.tooltip_text = "Toggle editor grid overlay"
	grid_btn.toggled.connect(func(pressed: bool):
		main.grid_enabled = pressed
		var overlay = main.get_node_or_null("EditorOverlay")
		if overlay:
			overlay.queue_redraw()
	)
	hbox.add_child(grid_btn)

	# Fade toggle

	var fade_btn = CheckButton.new()
	fade_btn.text = "Fade"
	fade_btn.button_pressed = true
	fade_btn.tooltip_text = "Toggle floor/wall edge fade"
	fade_btn.toggled.connect(func(pressed: bool):
		main.fade_enabled = pressed
		var terrain = get_node_or_null("/root/Main/TerrainSystem")
		if terrain:
			terrain._floor_edge_dirty = true
			terrain.queue_redraw()
		var building_sys = get_node_or_null("/root/Main/BuildingSystem")
		if building_sys:
			building_sys._walls_dirty = true
			building_sys.queue_redraw()
	)
	hbox.add_child(fade_btn)

	# Spacer
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	# Cursor grid position label
	cursor_pos_label = Label.new()
	cursor_pos_label.text = "x: 0, y: 0"
	cursor_pos_label.add_theme_font_size_override("font_size", 12)
	cursor_pos_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	cursor_pos_label.custom_minimum_size.x = 100
	hbox.add_child(cursor_pos_label)

	_add_action_btn(hbox, "Settings", _toggle_settings)
	_add_action_btn(hbox, "Back to Menu", _on_back_to_menu)

	# Highlight the defaults
	_update_tool_highlight()
	_update_mode_highlight()

	# --- Settings panel (map size etc.) ---
	_create_settings_panel()


func _add_mode_btn(parent: HBoxContainer, label: String, mode: int) -> void:
	var btn = Button.new()
	btn.text = label
	btn.pressed.connect(func(): _select_mode(mode))
	parent.add_child(btn)
	mode_buttons[mode] = btn


func _add_tool_btn(parent: HBoxContainer, label: String, tool_enum: int) -> void:
	var btn = Button.new()
	btn.text = label
	btn.pressed.connect(func(): _select_tool(tool_enum))
	parent.add_child(btn)
	tool_buttons[tool_enum] = btn


func _add_action_btn(parent: HBoxContainer, label: String, callback: Callable) -> void:
	var btn = Button.new()
	btn.text = label
	btn.pressed.connect(callback)
	parent.add_child(btn)


func _select_mode(mode: int) -> void:
	# Reset transform state when leaving transform mode
	if main.editor_mode == main.EditorMode.TRANSFORM and mode != main.EditorMode.TRANSFORM:
		main._transform_phase = main.TransformPhase.SELECTING
		main._transform_dragging = false
		main._overlay.queue_redraw()
	main.editor_mode = mode
	_update_mode_highlight()
	_update_mode_visibility()


func _select_tool(tool_enum: int) -> void:
	main.current_tool = tool_enum
	_update_tool_highlight()


func _update_mode_highlight() -> void:
	for mode in mode_buttons:
		var btn: Button = mode_buttons[mode]
		if mode == main.editor_mode:
			btn.add_theme_stylebox_override("normal", _panel_style(Color(0.6, 0.4, 0.1, 0.8)))
		else:
			btn.remove_theme_stylebox_override("normal")


func _update_tool_highlight() -> void:
	for tool_enum in tool_buttons:
		var btn: Button = tool_buttons[tool_enum]
		if tool_enum == main.current_tool:
			btn.add_theme_stylebox_override("normal", _panel_style(Color(0.2, 0.5, 0.8, 0.8)))
		else:
			btn.remove_theme_stylebox_override("normal")
	# Show the brush-size spinner only when a tool that uses thickness
	# is selected — currently the Line and Circle tools share the same
	# `line_size` field. Hidden in every other mode.
	var uses_size: bool = main.current_tool == main.Tool.LINE or main.current_tool == main.Tool.CIRCLE
	var show_line_size: bool = uses_size and (main.editor_mode == main.EditorMode.TERRAIN)
	if line_size_label:
		line_size_label.visible = show_line_size
	if line_size_spin:
		line_size_spin.visible = show_line_size
	# Fill-toggle is Circle-only.
	var show_circle_fill: bool = (main.current_tool == main.Tool.CIRCLE) \
		and (main.editor_mode == main.EditorMode.TERRAIN)
	if circle_fill_check:
		circle_fill_check.visible = show_circle_fill


func _update_mode_visibility() -> void:
	if terrain_palette:
		terrain_palette.visible = (main.editor_mode == main.EditorMode.TERRAIN)
	if building_palette:
		building_palette.visible = (main.editor_mode == main.EditorMode.BUILDING)
	# Show/hide tool buttons based on mode
	var show_tools: bool = (main.editor_mode == main.EditorMode.TERRAIN)
	for tool_enum in tool_buttons:
		tool_buttons[tool_enum].visible = show_tools
	# Recompute size-spinner visibility (depends on both mode and tool).
	_update_tool_highlight()
	# Show mirror/convert buttons only in transform mode
	var show_mirror: bool = (main.editor_mode == main.EditorMode.TRANSFORM)
	if mirror_x_btn:
		mirror_x_btn.visible = show_mirror
	if mirror_y_btn:
		mirror_y_btn.visible = show_mirror
	if convert_faction_btn:
		convert_faction_btn.visible = show_mirror
	# Show/hide script editor panel
	if script_editor_panel:
		if main.editor_mode == main.EditorMode.SCRIPT:
			script_editor_panel.show_panel()
		else:
			script_editor_panel.hide_panel()


# =========================
# LEFT PALETTE (TERRAIN + BUILDING)
# =========================

func _create_palette() -> void:
	_create_terrain_palette()
	_create_building_palette()


# --- TERRAIN PALETTE ---

func _create_terrain_palette() -> void:
	terrain_palette = PanelContainer.new()
	terrain_palette.anchor_top = 0.0
	terrain_palette.anchor_bottom = 1.0
	terrain_palette.offset_top = 50  # Below toolbar
	terrain_palette.offset_left = 6
	terrain_palette.offset_right = 210
	terrain_palette.offset_bottom = -10
	terrain_palette.add_theme_stylebox_override("panel", _panel_style(Color(0, 0, 0, 0.7)))
	add_child(terrain_palette)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	terrain_palette.add_child(vbox)

	# Category tabs
	var cat_hbox = HBoxContainer.new()
	cat_hbox.add_theme_constant_override("separation", 2)
	vbox.add_child(cat_hbox)

	_add_cat_btn(cat_hbox, "Floor", TerrainTileData.TileCategory.FLOOR)
	_add_cat_btn(cat_hbox, "Wall", TerrainTileData.TileCategory.WALL)
	_add_cat_btn(cat_hbox, "Ore", TerrainTileData.TileCategory.ORE)

	# Tile grid (scrollable)
	var grid_panel = PanelContainer.new()
	grid_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.05, 0.05, 0.08, 0.6)))
	grid_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(grid_panel)

	var scroll = ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	grid_panel.add_child(scroll)

	tile_grid = GridContainer.new()
	tile_grid.columns = GRID_COLS
	tile_grid.add_theme_constant_override("h_separation", 3)
	tile_grid.add_theme_constant_override("v_separation", 3)
	scroll.add_child(tile_grid)

	_update_cat_highlight()


# --- BUILDING PALETTE ---

func _create_building_palette() -> void:
	building_palette = PanelContainer.new()
	building_palette.anchor_top = 0.0
	building_palette.anchor_bottom = 1.0
	building_palette.offset_top = 50
	building_palette.offset_left = 6
	building_palette.offset_right = 210
	building_palette.offset_bottom = -10
	building_palette.add_theme_stylebox_override("panel", _panel_style(Color(0, 0, 0, 0.7)))
	building_palette.visible = false  # Hidden initially (terrain mode is default)
	add_child(building_palette)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	building_palette.add_child(vbox)

	# Faction selector
	var faction_label = Label.new()
	faction_label.text = "Faction:"
	vbox.add_child(faction_label)

	var faction_hbox = HBoxContainer.new()
	faction_hbox.add_theme_constant_override("separation", 2)
	vbox.add_child(faction_hbox)

	_add_faction_btn(faction_hbox, "Lumina", main.Faction.LUMINA, Color(0.3, 0.7, 1.0))
	_add_faction_btn(faction_hbox, "Ferox", main.Faction.FEROX, Color(1.0, 0.3, 0.3))
	_add_faction_btn(faction_hbox, "Derelict", main.Faction.DERELICT, Color(0.55, 0.55, 0.55))
	_update_faction_highlight()

	# Separator
	var sep = HSeparator.new()
	vbox.add_child(sep)

	# Block category tabs (three rows for readability)
	var cat_row1 = HBoxContainer.new()
	cat_row1.add_theme_constant_override("separation", 2)
	vbox.add_child(cat_row1)

	_add_block_cat_btn(cat_row1, "Core", BlockData.BlockCategory.CORE)
	_add_block_cat_btn(cat_row1, "Extract", BlockData.BlockCategory.EXTRACTORS)
	_add_block_cat_btn(cat_row1, "Factory", BlockData.BlockCategory.FACTORIES)

	var cat_row2 = HBoxContainer.new()
	cat_row2.add_theme_constant_override("separation", 2)
	vbox.add_child(cat_row2)

	_add_block_cat_btn(cat_row2, "Power", BlockData.BlockCategory.POWER)
	_add_block_cat_btn(cat_row2, "Turret", BlockData.BlockCategory.TURRETS)
	_add_block_cat_btn(cat_row2, "Wall", BlockData.BlockCategory.WALLS)

	var cat_row3 = HBoxContainer.new()
	cat_row3.add_theme_constant_override("separation", 2)
	vbox.add_child(cat_row3)

	_add_block_cat_btn(cat_row3, "Units", BlockData.BlockCategory.UNITS)
	_add_block_cat_btn(cat_row3, "Assist", BlockData.BlockCategory.ASSIST)
	_add_block_cat_btn(cat_row3, "Items", BlockData.BlockCategory.ITEMS)

	# Block grid (scrollable)
	var grid_panel = PanelContainer.new()
	grid_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.05, 0.05, 0.08, 0.6)))
	grid_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(grid_panel)

	var scroll = ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	grid_panel.add_child(scroll)

	block_grid = GridContainer.new()
	block_grid.columns = GRID_COLS
	block_grid.add_theme_constant_override("h_separation", 3)
	block_grid.add_theme_constant_override("v_separation", 3)
	scroll.add_child(block_grid)

	# Rotation hint
	var rot_label = Label.new()
	rot_label.text = "Press Q to rotate"
	rot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rot_label.add_theme_font_size_override("font_size", 11)
	rot_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	vbox.add_child(rot_label)

	_update_block_cat_highlight()
	_populate_blocks(selected_block_category)


# --- FACTION SELECTOR ---

func _add_faction_btn(parent: HBoxContainer, label: String, faction: int, color: Color) -> void:
	var btn = Button.new()
	btn.text = label
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func(): _select_faction(faction))

	# Color indicator
	var style = StyleBoxFlat.new()
	style.bg_color = color.darkened(0.5)
	style.set_corner_radius_all(4)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	style.border_color = color
	style.set_border_width_all(1)
	btn.add_theme_stylebox_override("normal", style)

	parent.add_child(btn)
	faction_buttons[faction] = btn


func _select_faction(faction: int) -> void:
	main.selected_faction = faction
	_update_faction_highlight()


func _update_faction_highlight() -> void:
	for f in faction_buttons:
		var btn: Button = faction_buttons[f]
		var base_color: Color
		match f:
			main.Faction.LUMINA:  base_color = Color(0.3, 0.7, 1.0)
			main.Faction.FEROX:   base_color = Color(1.0, 0.3, 0.3)
			main.Faction.DERELICT: base_color = Color(0.55, 0.55, 0.55)
			_:                    base_color = Color(0.7, 0.7, 0.7)
		if f == main.selected_faction:
			btn.add_theme_stylebox_override("normal", _panel_style(base_color.darkened(0.35)))
		else:
			var style = StyleBoxFlat.new()
			style.bg_color = base_color.darkened(0.6)
			style.set_corner_radius_all(4)
			style.content_margin_left = 8
			style.content_margin_right = 8
			style.content_margin_top = 4
			style.content_margin_bottom = 4
			style.border_color = base_color.darkened(0.3)
			style.set_border_width_all(1)
			btn.add_theme_stylebox_override("normal", style)


# --- TILE PALETTE CALLBACKS ---

func _add_cat_btn(parent: HBoxContainer, label: String, category: int) -> void:
	var btn = Button.new()
	btn.text = label
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func(): _select_category(category))
	parent.add_child(btn)
	category_buttons[category] = btn


func _select_category(category: int) -> void:
	selected_category = category
	_populate_tiles(category)
	_update_cat_highlight()


func _update_cat_highlight() -> void:
	for cat in category_buttons:
		var btn: Button = category_buttons[cat]
		if cat == selected_category:
			btn.add_theme_stylebox_override("normal", _panel_style(Color(0.3, 0.5, 0.3, 0.8)))
		else:
			btn.remove_theme_stylebox_override("normal")


func _populate_tiles(category: int) -> void:
	for child in tile_grid.get_children():
		child.queue_free()
	tile_buttons.clear()
	selected_tile_btn = null

	var tiles = Registry.get_tiles_by_category(category)
	for tile in tiles:
		_add_tile_button(tile)


func _add_tile_button(tile: TerrainTileData) -> void:
	var btn = Button.new()
	btn.custom_minimum_size = Vector2(TILE_BTN_SIZE, TILE_BTN_SIZE)
	btn.tooltip_text = String(tile.id)

	if tile.icon:
		var tex_rect = TextureRect.new()
		tex_rect.texture = tile.icon
		tex_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.custom_minimum_size = Vector2(TILE_BTN_SIZE - 8, TILE_BTN_SIZE - 8)
		btn.add_child(tex_rect)
	else:
		btn.add_theme_stylebox_override("normal", _tile_style(tile.color))

	btn.pressed.connect(func(): _select_tile(tile.id, btn))
	tile_grid.add_child(btn)
	tile_buttons[tile.id] = btn


func _select_tile(tile_id: StringName, btn: Button) -> void:
	main.selected_tile = tile_id

	# (No tool auto-swap on tile pick — Pencil/Line/etc all paint with
	# the selected tile, and the previous Eraser tool no longer exists.)

	if selected_tile_btn:
		selected_tile_btn.remove_theme_stylebox_override("normal")
	selected_tile_btn = btn
	btn.add_theme_stylebox_override("normal", _panel_style(Color(0.2, 0.6, 0.3, 0.8)))


# --- BLOCK PALETTE CALLBACKS ---

func _add_block_cat_btn(parent: HBoxContainer, label: String, category: int) -> void:
	var btn = Button.new()
	btn.text = label
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func(): _select_block_category(category))
	parent.add_child(btn)
	block_cat_buttons[category] = btn


func _select_block_category(category: int) -> void:
	selected_block_category = category
	_populate_blocks(category)
	_update_block_cat_highlight()


func _update_block_cat_highlight() -> void:
	for cat in block_cat_buttons:
		var btn: Button = block_cat_buttons[cat]
		if cat == selected_block_category:
			btn.add_theme_stylebox_override("normal", _panel_style(Color(0.3, 0.5, 0.3, 0.8)))
		else:
			btn.remove_theme_stylebox_override("normal")


func _populate_blocks(category: int) -> void:
	for child in block_grid.get_children():
		child.queue_free()
	block_buttons.clear()
	selected_block_btn = null

	var blocks = Registry.get_blocks_by_category(category)
	for block in blocks:
		_add_block_button(block)


func _add_block_button(block: BlockData) -> void:
	var btn = Button.new()
	btn.custom_minimum_size = Vector2(TILE_BTN_SIZE, TILE_BTN_SIZE)
	btn.tooltip_text = block.display_name if block.display_name != "" else String(block.id)

	if block.icon:
		var tex_rect = TextureRect.new()
		tex_rect.texture = block.icon
		tex_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.custom_minimum_size = Vector2(TILE_BTN_SIZE - 8, TILE_BTN_SIZE - 8)
		btn.add_child(tex_rect)
	else:
		btn.add_theme_stylebox_override("normal", _tile_style(block.color))

	btn.pressed.connect(func(): _select_block(block.id, btn))
	block_grid.add_child(btn)
	block_buttons[block.id] = btn


func _select_block(block_id: StringName, btn: Button) -> void:
	main.selected_block = block_id

	if selected_block_btn:
		selected_block_btn.remove_theme_stylebox_override("normal")
	selected_block_btn = btn
	btn.add_theme_stylebox_override("normal", _panel_style(Color(0.2, 0.6, 0.3, 0.8)))




# =========================
# SCRIPT EDITOR
# =========================

func _create_script_editor() -> void:
	# The new node-graph editor replaces the legacy right-side panel.
	# It still exposes the same `set_script_data` / `get_script_data`
	# / `show_panel` / `hide_panel` API so editor_hud, save_manager,
	# and the rest of the integration points work unmodified.
	var se = load("res://main/node_script_editor.gd").new()
	add_child(se)
	script_editor_panel = se
	main.script_editor = se


# =========================
# WAVE EDITOR
# =========================

func _create_wave_editor() -> void:
	var we = load("res://main/wave_editor.gd").new()
	add_child(we)
	wave_editor_panel = we
	# Toolbar toggle button — keeps the wave editor accessible from any
	# mode rather than hijacking a dedicated EditorMode slot.
	if _toolbar_hbox:
		wave_editor_btn = Button.new()
		wave_editor_btn.text = "Waves"
		wave_editor_btn.toggle_mode = true
		wave_editor_btn.toggled.connect(_on_wave_toggle)
		_toolbar_hbox.add_child(wave_editor_btn)


func _on_wave_toggle(pressed: bool) -> void:
	if wave_editor_panel == null:
		return
	if pressed:
		wave_editor_panel.show_panel()
	else:
		wave_editor_panel.hide_panel()


# =========================
# SAVE / LOAD / NEW / MENU
# =========================

func _on_save_sector() -> void:
	var save_name := map_name_input.text.strip_edges()
	if save_name == "":
		_show_status("Enter a name first!")
		return
	# Editor saves are *templates* — they belong in `user://maps/`
	# alongside the bundled originals, not in the player's `/saves`.
	if SaveManager.save_sector(save_name, true):
		_show_status("Sector '%s' saved!" % save_name)
	else:
		_show_status("Failed to save sector!")


func _on_load() -> void:
	_refresh_load_list()
	load_popup.visible = not load_popup.visible


func _on_new() -> void:
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if terrain:
		terrain.floor_tiles.clear()
		terrain.wall_tiles.clear()
		terrain.ore_tiles.clear()
		terrain.tile_health.clear()
		terrain.multi_tile_origins.clear()
		terrain.queue_redraw()
	main.core_position = Vector2i(48, 48)
	main.clear_buildings()
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	if building_sys:
		if "editor_constructor_state" in building_sys:
			building_sys.editor_constructor_state.clear()
		if "editor_refabricator_state" in building_sys:
			building_sys.editor_refabricator_state.clear()
		if "editor_sorter_filters" in building_sys:
			building_sys.editor_sorter_filters.clear()
		# Archive selections live on BuildingSystem in both editor + game,
		# so clearing them here also resets authored archive contents when
		# the designer starts a fresh map.
		if "archive_holdings" in building_sys:
			building_sys.archive_holdings.clear()
	if main.get("editor_waves") != null:
		main.editor_waves.clear()
	if main.get("editor_wave_spawns") != null:
		main.editor_wave_spawns.clear()
	if main.get("editor_wave_config") != null:
		main.editor_wave_config = {
			"start_mode": "landing",
			"initial_delay": 30.0,
			"interval": 30.0,
			"generation_mode": "manual",
			"auto_wave_count": 10,
			"auto_unit_templates": [],
		}
	if wave_editor_panel and wave_editor_panel.has_method("_refresh_all"):
		wave_editor_panel._refresh_all()
	main._overlay.queue_redraw()
	map_name_input.text = "untitled"
	# Clear script steps
	if script_editor_panel:
		script_editor_panel.set_script_data([])
	_show_status("New map created")


func _on_back_to_menu() -> void:
	get_tree().change_scene_to_file("res://main/MainMenu.tscn")


# =========================
# SETTINGS PANEL
# =========================

var _settings_panel: PanelContainer
var _settings_open := false
var _width_input: SpinBox
var _height_input: SpinBox
var _alignment_input: OptionButton
var _fog_enabled_check: CheckBox
var _fog_dark_slider: HSlider
var _fog_dark_value_label: Label
var _map_alignment := 0  # 0=TL,1=TM,2=TR,3=ML,4=MM,5=MR,6=BL,7=BM,8=BR

func _create_settings_panel() -> void:
	_settings_panel = PanelContainer.new()
	_settings_panel.anchor_left = 0.5
	_settings_panel.anchor_right = 0.5
	_settings_panel.anchor_top = 0.5
	_settings_panel.anchor_bottom = 0.5
	_settings_panel.offset_left = -160
	_settings_panel.offset_right = 160
	_settings_panel.offset_top = -130
	_settings_panel.offset_bottom = 130
	_settings_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.08, 0.08, 0.1, 0.95)))
	_settings_panel.visible = false
	add_child(_settings_panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_settings_panel.add_child(vbox)

	# Title
	var title = Label.new()
	title.text = "Map Settings"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1.0, 0.84, 0.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# Map Width
	var w_hbox = HBoxContainer.new()
	w_hbox.add_theme_constant_override("separation", 8)
	var w_label = Label.new()
	w_label.text = "Map Width:"
	w_label.custom_minimum_size.x = 90
	w_hbox.add_child(w_label)
	_width_input = SpinBox.new()
	_width_input.min_value = 20
	_width_input.max_value = 500
	_width_input.step = 10
	_width_input.value = main.GRID_WIDTH
	_width_input.custom_minimum_size.x = 100
	w_hbox.add_child(_width_input)
	vbox.add_child(w_hbox)

	# Map Height
	var h_hbox = HBoxContainer.new()
	h_hbox.add_theme_constant_override("separation", 8)
	var h_label = Label.new()
	h_label.text = "Map Height:"
	h_label.custom_minimum_size.x = 90
	h_hbox.add_child(h_label)
	_height_input = SpinBox.new()
	_height_input.min_value = 20
	_height_input.max_value = 500
	_height_input.step = 10
	_height_input.value = main.GRID_HEIGHT
	_height_input.custom_minimum_size.x = 100
	h_hbox.add_child(_height_input)
	vbox.add_child(h_hbox)

	# Alignment (anchor of existing content within the resized map)
	var a_hbox = HBoxContainer.new()
	a_hbox.add_theme_constant_override("separation", 8)
	var a_label = Label.new()
	a_label.text = "Alignment:"
	a_label.custom_minimum_size.x = 90
	a_hbox.add_child(a_label)
	_alignment_input = OptionButton.new()
	_alignment_input.add_item("Top Left", 0)
	_alignment_input.add_item("Top Middle", 1)
	_alignment_input.add_item("Top Right", 2)
	_alignment_input.add_item("Middle Left", 3)
	_alignment_input.add_item("Center", 4)
	_alignment_input.add_item("Middle Right", 5)
	_alignment_input.add_item("Bottom Left", 6)
	_alignment_input.add_item("Bottom Middle", 7)
	_alignment_input.add_item("Bottom Right", 8)
	_alignment_input.selected = _map_alignment
	_alignment_input.custom_minimum_size.x = 140
	a_hbox.add_child(_alignment_input)
	vbox.add_child(a_hbox)

	# Fog of War toggle. The actual fog system lives in the playtest
	# scene; here we just stash the value on `main` so save_manager
	# round-trips it.
	var fog_enabled_hbox = HBoxContainer.new()
	fog_enabled_hbox.add_theme_constant_override("separation", 8)
	var fog_enabled_label = Label.new()
	fog_enabled_label.text = "Fog of War:"
	fog_enabled_label.custom_minimum_size.x = 90
	fog_enabled_hbox.add_child(fog_enabled_label)
	_fog_enabled_check = CheckBox.new()
	_fog_enabled_check.button_pressed = bool(main.get("fog_enabled")) if "fog_enabled" in main else true
	fog_enabled_hbox.add_child(_fog_enabled_check)
	vbox.add_child(fog_enabled_hbox)

	# Fog darkness multiplier. 0.5 = half as dark as the default fog;
	# 1.5 = 50 % darker than default. The fog system multiplies both
	# its unseen and explored alphas by this number (clamped at 0..2
	# so the slider can't push the explored layer into pure-opaque
	# territory).
	var fog_dark_hbox = HBoxContainer.new()
	fog_dark_hbox.add_theme_constant_override("separation", 8)
	var fog_dark_label = Label.new()
	fog_dark_label.text = "Fog Darkness:"
	fog_dark_label.custom_minimum_size.x = 90
	fog_dark_hbox.add_child(fog_dark_label)
	_fog_dark_slider = HSlider.new()
	_fog_dark_slider.min_value = 0.2
	_fog_dark_slider.max_value = 2.0
	_fog_dark_slider.step = 0.05
	_fog_dark_slider.value = float(main.get("fog_darkness_mult")) if "fog_darkness_mult" in main else 1.0
	_fog_dark_slider.custom_minimum_size.x = 110
	_fog_dark_value_label = Label.new()
	_fog_dark_value_label.text = "%.2f×" % _fog_dark_slider.value
	_fog_dark_value_label.custom_minimum_size.x = 40
	_fog_dark_slider.value_changed.connect(func(v): _fog_dark_value_label.text = "%.2f×" % v)
	fog_dark_hbox.add_child(_fog_dark_slider)
	fog_dark_hbox.add_child(_fog_dark_value_label)
	vbox.add_child(fog_dark_hbox)

	# Apply + Close buttons
	var btn_hbox = HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 8)
	btn_hbox.alignment = BoxContainer.ALIGNMENT_CENTER

	var apply_btn = Button.new()
	apply_btn.text = "Apply"
	apply_btn.pressed.connect(_on_settings_apply)
	btn_hbox.add_child(apply_btn)

	var close_btn = Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func(): _settings_panel.visible = false; _settings_open = false)
	btn_hbox.add_child(close_btn)

	vbox.add_child(btn_hbox)


func _toggle_settings() -> void:
	_settings_open = not _settings_open
	_settings_panel.visible = _settings_open
	if _settings_open:
		_width_input.value = main.GRID_WIDTH
		_height_input.value = main.GRID_HEIGHT
		_alignment_input.selected = _map_alignment
		if _fog_enabled_check and "fog_enabled" in main:
			_fog_enabled_check.button_pressed = bool(main.fog_enabled)
		if _fog_dark_slider and "fog_darkness_mult" in main:
			_fog_dark_slider.value = float(main.fog_darkness_mult)
			if _fog_dark_value_label:
				_fog_dark_value_label.text = "%.2f×" % _fog_dark_slider.value


func _on_settings_apply() -> void:
	var new_w := int(_width_input.value)
	var new_h := int(_height_input.value)
	_map_alignment = _alignment_input.selected
	# Fog values are author-time settings; just stash them on `main`
	# so save_manager carries them into the .sector.json. The runtime
	# FogSystem doesn't exist in the editor scene.
	if _fog_enabled_check and "fog_enabled" in main:
		main.fog_enabled = _fog_enabled_check.button_pressed
	if _fog_dark_slider and "fog_darkness_mult" in main:
		main.fog_darkness_mult = float(_fog_dark_slider.value)
	if new_w != main.GRID_WIDTH or new_h != main.GRID_HEIGHT:
		var old_w := int(main.GRID_WIDTH)
		var old_h := int(main.GRID_HEIGHT)
		var dw := new_w - old_w
		var dh := new_h - old_h
		var hx := _map_alignment % 3
		var vy := _map_alignment / 3
		var offset := Vector2i(
			int(round(float(dw) * float(hx) * 0.5)),
			int(round(float(dh) * float(vy) * 0.5))
		)
		main.GRID_WIDTH = new_w
		main.GRID_HEIGHT = new_h
		_shift_map_content(offset, new_w, new_h)
		var overlay = main.get_node_or_null("EditorOverlay")
		if overlay:
			overlay.queue_redraw()
		var terrain = get_node_or_null("/root/Main/TerrainSystem")
		if terrain:
			terrain.queue_redraw()
		_show_status("Map size changed to %d × %d" % [new_w, new_h])


func _shift_map_content(offset: Vector2i, new_w: int, new_h: int) -> void:
	# Always walk the dicts — even with a zero offset, a shrink needs to
	# clip content now outside the new bounds, and `main.GRID_WIDTH` has
	# already been updated to `new_w` by the caller so we can't compare
	# against the old size cheaply here.
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if terrain:
		_shift_dict_keys(terrain.floor_tiles, offset, new_w, new_h)
		_shift_dict_keys(terrain.wall_tiles, offset, new_w, new_h)
		_shift_dict_keys(terrain.ore_tiles, offset, new_w, new_h)
		_shift_dict_keys(terrain.tile_health, offset, new_w, new_h)
		_shift_dict_keys_and_values(terrain.multi_tile_origins, offset, new_w, new_h)
		terrain._floor_edge_dirty = true
		terrain._water_depth_dirty = true
	if main.get("placed_buildings") != null:
		_shift_dict_keys(main.placed_buildings, offset, new_w, new_h)
	if main.get("building_rotation") != null:
		_shift_dict_keys(main.building_rotation, offset, new_w, new_h)
	if main.get("building_health") != null:
		_shift_dict_keys(main.building_health, offset, new_w, new_h)
	if main.get("building_factions") != null:
		_shift_dict_keys(main.building_factions, offset, new_w, new_h)
	# building_origins maps every tile of a multi-tile building back to
	# its anchor cell, so both keys AND values need the same offset
	# applied or the anchor-resolver returns positions outside the new
	# placed_buildings set.
	if main.get("building_origins") != null:
		_shift_dict_keys_and_values(main.building_origins, offset, new_w, new_h)
	if main.get("linked_pairs") != null:
		_shift_link_pairs(main.linked_pairs, offset, new_w, new_h)
	if main.get("core_position") != null:
		var cp: Vector2i = main.core_position + offset
		cp.x = clamp(cp.x, 0, max(0, new_w - 1))
		cp.y = clamp(cp.y, 0, max(0, new_h - 1))
		main.core_position = cp


func _shift_dict_keys(d: Dictionary, offset: Vector2i, new_w: int, new_h: int) -> void:
	var replacement := {}
	for k in d.keys():
		if typeof(k) != TYPE_VECTOR2I:
			replacement[k] = d[k]
			continue
		var nk: Vector2i = k + offset
		if nk.x < 0 or nk.y < 0 or nk.x >= new_w or nk.y >= new_h:
			continue
		replacement[nk] = d[k]
	d.clear()
	for k in replacement:
		d[k] = replacement[k]


func _shift_dict_keys_and_values(d: Dictionary, offset: Vector2i, new_w: int, new_h: int) -> void:
	var replacement := {}
	for k in d.keys():
		if typeof(k) != TYPE_VECTOR2I:
			continue
		var nk: Vector2i = k + offset
		if nk.x < 0 or nk.y < 0 or nk.x >= new_w or nk.y >= new_h:
			continue
		var v = d[k]
		if typeof(v) == TYPE_VECTOR2I:
			v = (v as Vector2i) + offset
		replacement[nk] = v
	d.clear()
	for k in replacement:
		d[k] = replacement[k]


func _shift_link_pairs(pairs: Array, offset: Vector2i, new_w: int, new_h: int) -> void:
	for i in range(pairs.size() - 1, -1, -1):
		var p = pairs[i]
		if typeof(p) != TYPE_ARRAY or p.size() < 2:
			continue
		var a: Vector2i = p[0] + offset
		var b: Vector2i = p[1] + offset
		if a.x < 0 or a.y < 0 or a.x >= new_w or a.y >= new_h \
		or b.x < 0 or b.y < 0 or b.x >= new_w or b.y >= new_h:
			pairs.remove_at(i)
			continue
		pairs[i] = [a, b]


# =========================
# LOAD POPUP
# =========================

func _create_load_popup() -> void:
	load_popup = PanelContainer.new()
	load_popup.anchor_left = 0.5
	load_popup.anchor_right = 0.5
	load_popup.anchor_top = 0.5
	load_popup.anchor_bottom = 0.5
	load_popup.offset_left = -150
	load_popup.offset_right = 150
	load_popup.offset_top = -200
	load_popup.offset_bottom = 200
	load_popup.add_theme_stylebox_override("panel", _panel_style(Color(0.05, 0.05, 0.1, 0.95)))
	load_popup.visible = false
	add_child(load_popup)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	load_popup.add_child(vbox)

	var title = Label.new()
	title.text = "Load Sector"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	vbox.add_child(scroll)

	load_list = VBoxContainer.new()
	load_list.add_theme_constant_override("separation", 2)
	scroll.add_child(load_list)

	var close_btn = Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func(): load_popup.visible = false)
	vbox.add_child(close_btn)


func _refresh_load_list() -> void:
	for child in load_list.get_children():
		child.queue_free()

	var sectors := SaveManager.list_sectors()

	if sectors.is_empty():
		var lbl = Label.new()
		lbl.text = "No saved sectors"
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		load_list.add_child(lbl)
		return

	for sector_name in sectors:
		_add_load_entry(sector_name, "sector")


func _add_load_entry(entry_name: String, file_type: String) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	load_list.add_child(hbox)

	var btn = Button.new()
	btn.text = entry_name
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var captured_name := entry_name
	var captured_type := file_type
	btn.pressed.connect(func(): _load_entry(captured_name, captured_type))
	hbox.add_child(btn)

	var del_btn = Button.new()
	del_btn.text = "X"
	del_btn.tooltip_text = "Delete"
	del_btn.pressed.connect(func():
		SaveManager.delete_sector(captured_name)
		_refresh_load_list()
	)
	hbox.add_child(del_btn)


func _load_entry(entry_name: String, file_type: String) -> void:
	var success: bool = SaveManager.load_sector(entry_name)

	if success:
		map_name_input.text = entry_name
		load_popup.visible = false
		main._overlay.queue_redraw()
		var bs = get_node_or_null("/root/Main/BuildingSystem")
		if bs:
			bs.queue_redraw()
		_show_status("%s '%s' loaded!" % [file_type.capitalize(), entry_name])
	else:
		_show_status("Failed to load %s!" % file_type)


# =========================
# STATUS LABEL
# =========================

func _create_status_label() -> void:
	status_label = Label.new()
	status_label.anchor_left = 0.5
	status_label.anchor_right = 0.5
	status_label.anchor_top = 1.0
	status_label.anchor_bottom = 1.0
	status_label.offset_top = -40
	status_label.offset_bottom = -10
	status_label.offset_left = -200
	status_label.offset_right = 200
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.visible = false
	add_child(status_label)


func _show_status(text: String, duration := 3.0) -> void:
	status_label.text = text
	status_label.visible = true
	_status_timer = duration


# =========================
# FACTION CONVERSION POPUP
# =========================

func _create_faction_popup() -> void:
	faction_popup = PanelContainer.new()
	faction_popup.anchor_left = 0.5
	faction_popup.anchor_right = 0.5
	faction_popup.anchor_top = 0.5
	faction_popup.anchor_bottom = 0.5
	faction_popup.offset_left = -120
	faction_popup.offset_right = 120
	faction_popup.offset_top = -80
	faction_popup.offset_bottom = 80
	faction_popup.add_theme_stylebox_override("panel", _panel_style(Color(0.05, 0.05, 0.1, 0.95)))
	faction_popup.visible = false
	add_child(faction_popup)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	faction_popup.add_child(vbox)

	var title = Label.new()
	title.text = "Convert to Faction"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# Faction option buttons — one per Faction enum value.
	var faction_hbox = HBoxContainer.new()
	faction_hbox.add_theme_constant_override("separation", 6)
	vbox.add_child(faction_hbox)

	var convert_faction_buttons: Dictionary = {}
	var faction_specs := [
		{"id": main.Faction.LUMINA, "label": "Lumina", "color": Color(0.3, 0.7, 1.0)},
		{"id": main.Faction.FEROX, "label": "Ferox", "color": Color(1.0, 0.3, 0.3)},
		{"id": main.Faction.DERELICT, "label": "Derelict", "color": Color(0.55, 0.55, 0.55)},
	]
	for spec in faction_specs:
		var btn := Button.new()
		btn.text = spec["label"]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		faction_hbox.add_child(btn)
		convert_faction_buttons[spec["id"]] = {"btn": btn, "color": spec["color"]}
		var captured_id: int = spec["id"]
		btn.pressed.connect(func():
			_convert_faction_choice = captured_id
			_update_convert_faction_highlight(convert_faction_buttons)
		)
	_update_convert_faction_highlight(convert_faction_buttons)

	# OK / Cancel buttons
	var btn_hbox = HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 6)
	vbox.add_child(btn_hbox)

	var ok_btn = Button.new()
	ok_btn.text = "OK"
	ok_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ok_btn.pressed.connect(func():
		faction_popup.visible = false
		main.transform_convert_faction(_convert_faction_choice)
	)
	btn_hbox.add_child(ok_btn)

	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(func(): faction_popup.visible = false)
	btn_hbox.add_child(cancel_btn)


func _update_convert_faction_highlight(buttons: Dictionary) -> void:
	# `buttons` maps Faction int → { "btn": Button, "color": Color }. The
	# selected faction renders with its full colour panel; the others fade
	# to a darkened, bordered style so the active choice stands out.
	for fid in buttons:
		var entry: Dictionary = buttons[fid]
		var btn: Button = entry["btn"]
		var c: Color = entry["color"]
		if fid == _convert_faction_choice:
			btn.add_theme_stylebox_override("normal", _panel_style(c.darkened(0.35)))
		else:
			var style = StyleBoxFlat.new()
			style.bg_color = c.darkened(0.6)
			style.set_corner_radius_all(4)
			style.content_margin_left = 8
			style.content_margin_right = 8
			style.content_margin_top = 4
			style.content_margin_bottom = 4
			style.border_color = c.darkened(0.3)
			style.set_border_width_all(1)
			btn.add_theme_stylebox_override("normal", style)


func _on_convert_faction() -> void:
	if main._transform_phase != main.TransformPhase.SELECTED:
		_show_status("Select a region first!")
		return
	# Check if there are any buildings in the selection
	if main._transform_bld_factions.is_empty():
		_show_status("No buildings in selection!")
		return
	_convert_faction_choice = main.Faction.LUMINA
	faction_popup.visible = true


# =========================
# STYLE HELPERS
# =========================

func _panel_style(bg_color: Color) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = bg_color
	s.set_corner_radius_all(6)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s


func _tile_style(color: Color) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(4)
	s.border_color = color.lightened(0.2)
	s.set_border_width_all(1)
	return s
