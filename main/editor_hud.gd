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

func _ready() -> void:
	await get_tree().process_frame
	main = get_node("/root/Main")
	_create_toolbar()
	_create_palette()
	_create_load_popup()
	_create_faction_popup()
	_create_status_label()
	_create_script_editor()
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

	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	toolbar.add_child(hbox)

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
	_add_tool_btn(hbox, "Eraser", main.Tool.ERASER)
	_add_tool_btn(hbox, "Rect Fill", main.Tool.RECT_FILL)
	_add_tool_btn(hbox, "Rect Erase", main.Tool.RECT_ERASE)

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
	_add_action_btn(hbox, "Save Map", _on_save_map)
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

	_add_action_btn(hbox, "Back to Menu", _on_back_to_menu)

	# Highlight the defaults
	_update_tool_highlight()
	_update_mode_highlight()


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


func _update_mode_visibility() -> void:
	if terrain_palette:
		terrain_palette.visible = (main.editor_mode == main.EditorMode.TERRAIN)
	if building_palette:
		building_palette.visible = (main.editor_mode == main.EditorMode.BUILDING)
	# Show/hide tool buttons based on mode
	var show_tools: bool = (main.editor_mode == main.EditorMode.TERRAIN)
	for tool_enum in tool_buttons:
		tool_buttons[tool_enum].visible = show_tools
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
		if f == main.selected_faction:
			if f == main.Faction.LUMINA:
				btn.add_theme_stylebox_override("normal", _panel_style(Color(0.2, 0.5, 0.8, 0.8)))
			else:
				btn.add_theme_stylebox_override("normal", _panel_style(Color(0.8, 0.2, 0.2, 0.8)))
		else:
			var c = Color(0.3, 0.7, 1.0) if f == main.Faction.LUMINA else Color(1.0, 0.3, 0.3)
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
	btn.tooltip_text = tile.display_name if tile.display_name != "" else String(tile.id)

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

	if main.current_tool == main.Tool.ERASER:
		main.current_tool = main.Tool.PENCIL
		_update_tool_highlight()

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
	var se = load("res://main/script_editor.gd").new()
	add_child(se)
	script_editor_panel = se
	main.script_editor = se


# =========================
# SAVE / LOAD / NEW / MENU
# =========================

func _on_save_map() -> void:
	var save_name := map_name_input.text.strip_edges()
	if save_name == "":
		_show_status("Enter a name first!")
		return
	if SaveManager.save_map(save_name):
		_show_status("Map '%s' saved!" % save_name)
	else:
		_show_status("Failed to save map!")


func _on_save_sector() -> void:
	var save_name := map_name_input.text.strip_edges()
	if save_name == "":
		_show_status("Enter a name first!")
		return
	if SaveManager.save_sector(save_name):
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
	main._overlay.queue_redraw()
	map_name_input.text = "untitled"
	# Clear script steps
	if script_editor_panel:
		script_editor_panel.set_script_data([])
	_show_status("New map created")


func _on_back_to_menu() -> void:
	get_tree().change_scene_to_file("res://main/MainMenu.tscn")


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
	title.text = "Load Map / Sector"
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

	var maps := SaveManager.list_maps()
	var sectors := SaveManager.list_sectors()

	if maps.is_empty() and sectors.is_empty():
		var lbl = Label.new()
		lbl.text = "No saved files"
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		load_list.add_child(lbl)
		return

	# Show maps
	if not maps.is_empty():
		var header = Label.new()
		header.text = "— Maps —"
		header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		header.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
		load_list.add_child(header)

		for map_name in maps:
			_add_load_entry(map_name, "map")

	# Show sectors
	if not sectors.is_empty():
		var header = Label.new()
		header.text = "— Sectors —"
		header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		header.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3))
		load_list.add_child(header)

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
		if captured_type == "map":
			SaveManager.delete_map(captured_name)
		else:
			SaveManager.delete_sector(captured_name)
		_refresh_load_list()
	)
	hbox.add_child(del_btn)


func _load_entry(entry_name: String, file_type: String) -> void:
	var success: bool
	if file_type == "map":
		# Clear buildings when loading a map-only file
		main.clear_buildings()
		success = SaveManager.load_map(entry_name)
	else:
		success = SaveManager.load_sector(entry_name)

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

	# Faction option buttons
	var faction_hbox = HBoxContainer.new()
	faction_hbox.add_theme_constant_override("separation", 6)
	vbox.add_child(faction_hbox)

	var lumina_btn = Button.new()
	lumina_btn.text = "Lumina"
	lumina_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lumina_btn.add_theme_stylebox_override("normal", _panel_style(Color(0.2, 0.5, 0.8, 0.8)))
	faction_hbox.add_child(lumina_btn)

	var ferox_btn = Button.new()
	ferox_btn.text = "Ferox"
	ferox_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var ferox_style = StyleBoxFlat.new()
	ferox_style.bg_color = Color(0.8, 0.2, 0.2).darkened(0.3)
	ferox_style.set_corner_radius_all(4)
	ferox_style.content_margin_left = 8
	ferox_style.content_margin_right = 8
	ferox_style.content_margin_top = 4
	ferox_style.content_margin_bottom = 4
	ferox_style.border_color = Color(1.0, 0.3, 0.3).darkened(0.3)
	ferox_style.set_border_width_all(1)
	ferox_btn.add_theme_stylebox_override("normal", ferox_style)
	faction_hbox.add_child(ferox_btn)

	# Connect signals after both buttons exist so lambdas can capture both
	lumina_btn.pressed.connect(func():
		_convert_faction_choice = main.Faction.LUMINA
		_update_convert_faction_highlight(lumina_btn, ferox_btn)
	)
	ferox_btn.pressed.connect(func():
		_convert_faction_choice = main.Faction.FEROX
		_update_convert_faction_highlight(lumina_btn, ferox_btn)
	)

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


func _update_convert_faction_highlight(lumina_btn: Button, ferox_btn: Button) -> void:
	if _convert_faction_choice == main.Faction.LUMINA:
		lumina_btn.add_theme_stylebox_override("normal", _panel_style(Color(0.2, 0.5, 0.8, 0.8)))
		var style = StyleBoxFlat.new()
		style.bg_color = Color(0.8, 0.2, 0.2).darkened(0.3)
		style.set_corner_radius_all(4)
		style.content_margin_left = 8
		style.content_margin_right = 8
		style.content_margin_top = 4
		style.content_margin_bottom = 4
		style.border_color = Color(1.0, 0.3, 0.3).darkened(0.3)
		style.set_border_width_all(1)
		ferox_btn.add_theme_stylebox_override("normal", style)
	else:
		ferox_btn.add_theme_stylebox_override("normal", _panel_style(Color(0.8, 0.2, 0.2, 0.8)))
		var style = StyleBoxFlat.new()
		style.bg_color = Color(0.2, 0.5, 0.8).darkened(0.3)
		style.set_corner_radius_all(4)
		style.content_margin_left = 8
		style.content_margin_right = 8
		style.content_margin_top = 4
		style.content_margin_bottom = 4
		style.border_color = Color(0.3, 0.7, 1.0).darkened(0.3)
		style.set_border_width_all(1)
		lumina_btn.add_theme_stylebox_override("normal", style)


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
