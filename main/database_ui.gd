extends CanvasLayer

# ============================================================
# DATABASE_UI.GD - Mindustry-Style Core Database
# ============================================================
# A scrollable grid of icon tiles organized by category.
# Hover for name tooltip, click unlocked entry for detail overlay.
# Locked tech tree entries show a lock icon and can't be opened.
# ============================================================

# --- STATE ---
var is_open := false
var search_text := ""
var _detail_open := false
var _hovered_entry: Resource = null
var _current_detail_cat := ""

# --- UI NODES ---
var _bg: ColorRect
var _scroll: ScrollContainer
var _grid_vbox: VBoxContainer
var _search_bar: LineEdit
var _tooltip_panel: PanelContainer
var _tooltip_label: Label
var _detail_overlay: ColorRect
var _detail_panel: PanelContainer
var _detail_container: VBoxContainer
var _detail_scroll: ScrollContainer

# Per-section data: cat_key → { "header": Control, "separator": Control, "grid": HFlowContainer, "tiles": Array[{node, entry}] }
var _sections: Dictionary = {}

# All tile nodes for search filtering
var _all_tiles: Array = []

# --- CATEGORY DEFINITIONS ---
var categories := {}

# --- STYLE ---
var bg_color := Color(0.05, 0.08, 0.05, 0.95)
var panel_color := Color(0.08, 0.12, 0.08, 0.9)
var highlight_color := Color(0.15, 0.3, 0.15, 1.0)
var text_color := Color(0.8, 0.95, 0.8, 1.0)
var dim_text_color := Color(0.5, 0.65, 0.5, 1.0)
var accent_color := Color(0.3, 0.9, 0.5, 1.0)

const TILE_SIZE := 48
const TILE_PADDING := 4
var _fallback_icon: Texture2D


func _ready() -> void:
	await get_tree().process_frame
	_fallback_icon = load("res://textures/TexNotFound.png")
	_setup_categories()
	_build_ui()
	_hide_ui()
	# Refresh tile lock state whenever a tech node flips, so newly-
	# researched entries lose their padlock without the player having to
	# re-open the database. Sections themselves are stable (no add/remove);
	# only the per-tile lock visual changes.
	if TechTree.has_signal("node_state_changed"):
		TechTree.node_state_changed.connect(_on_tech_state_changed_db)


func _on_tech_state_changed_db(_node_id: StringName, _new_state: int) -> void:
	for tile in _all_tiles:
		_refresh_tile_lock(tile)
	# If the detail overlay is open, refresh it too in case its tile flipped.
	if _detail_overlay and _detail_overlay.visible:
		_close_detail()


## Recomputes is_locked for one tile and toggles its visuals. Cheap —
## drops the lock label and replaces it with the entry's icon (or vice
## versa) instead of rebuilding the whole panel hierarchy.
func _refresh_tile_lock(tile: Dictionary) -> void:
	var entry: Resource = tile.get("entry")
	if entry == null:
		return
	var panel: PanelContainer = tile.get("node")
	if panel == null or not is_instance_valid(panel):
		return
	var tech_id := _get_tech_id_for_entry(entry)
	var locked: bool = false
	if tech_id != &"":
		locked = not TechTree.is_researched(tech_id)
	if bool(tile.get("is_locked", false)) == locked:
		return
	tile["is_locked"] = locked
	# Strip current children (lock label or icon) and replace.
	for c in panel.get_children():
		c.queue_free()
	if locked:
		var lock_label = Label.new()
		lock_label.text = "🔒"
		lock_label.add_theme_font_size_override("font_size", 16)
		lock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lock_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lock_label.anchor_right = 1.0
		lock_label.anchor_bottom = 1.0
		lock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(lock_label)
	else:
		var icon_rect = TextureRect.new()
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		icon_rect.custom_minimum_size = Vector2(TILE_SIZE - 8, TILE_SIZE - 8)
		icon_rect.texture = entry.icon if entry.icon else _fallback_icon
		icon_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		panel.add_child(icon_rect)
	# Re-bind input/hover with the fresh is_locked flag.
	for sig in ["mouse_entered", "mouse_exited", "gui_input"]:
		var s: Signal = panel.get(sig)
		for c in s.get_connections():
			s.disconnect(c["callable"])
	panel.mouse_entered.connect(_on_tile_hover.bind(entry, locked))
	panel.mouse_exited.connect(_on_tile_unhover)
	panel.gui_input.connect(_on_tile_input.bind(entry, tile.get("cat_key", ""), locked))


func _input(event: InputEvent) -> void:
	if is_open and event.is_action_pressed("ui_cancel"):
		_hide_ui()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("toggle_database"):
		if is_open:
			_hide_ui()
		else:
			_show_ui()

	# Update tooltip position
	if _tooltip_panel and _tooltip_panel.visible:
		var mpos = get_viewport().get_mouse_position()
		_tooltip_panel.position = mpos + Vector2(16, 16)


# =========================
# CATEGORY SETUP
# =========================

func _setup_categories() -> void:
	categories = {
		"items": {
			"label": "Items",
			"list": Registry.items_list,
			"dict": Registry.items,
			"color": Color(0.4, 1.0, 0.4),
		},
		"blocks": {
			"label": "Blocks",
			"list": Registry.blocks_list,
			"dict": Registry.blocks,
			"color": Color(0.4, 0.7, 1.0),
		},
		"fluids": {
			"label": "Fluids",
			"list": Registry.fluids_list,
			"dict": Registry.fluids,
			"color": Color(0.3, 0.8, 0.9),
		},
		"status_effects": {
			"label": "Status Effects",
			"list": Registry.status_effects_list,
			"dict": Registry.status_effects,
			"color": Color(0.9, 0.6, 1.0),
		},
		"units": {
			"label": "Units",
			"list": Registry.units_list,
			"dict": Registry.units,
			"color": Color(1.0, 0.4, 0.4),
		},
		"sectors": {
			"label": "Sectors",
			"list": Registry.sectors_list,
			"dict": Registry.sectors,
			"color": Color(0.9, 0.7, 0.2),
		},
	}


# =========================
# UI CONSTRUCTION
# =========================

func _build_ui() -> void:
	# --- Fullscreen dark background ---
	_bg = ColorRect.new()
	_bg.color = bg_color
	_bg.anchor_right = 1.0
	_bg.anchor_bottom = 1.0
	add_child(_bg)

	# --- Main scroll container ---
	_scroll = ScrollContainer.new()
	_scroll.anchor_right = 1.0
	_scroll.anchor_bottom = 1.0
	_scroll.offset_left = 40
	_scroll.offset_top = 20
	_scroll.offset_right = -40
	_scroll.offset_bottom = -20
	add_child(_scroll)

	_grid_vbox = VBoxContainer.new()
	_grid_vbox.add_theme_constant_override("separation", 12)
	_grid_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_grid_vbox)

	# Title
	var title = Label.new()
	title.text = "Core Database"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", accent_color)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_grid_vbox.add_child(title)

	# Search bar
	var search_container = PanelContainer.new()
	search_container.add_theme_stylebox_override("panel", _make_style(panel_color, 6))
	search_container.custom_minimum_size.y = 36
	_grid_vbox.add_child(search_container)

	_search_bar = LineEdit.new()
	_search_bar.placeholder_text = "search"
	_search_bar.add_theme_font_size_override("font_size", 14)
	_search_bar.add_theme_color_override("font_color", text_color)
	_search_bar.add_theme_color_override("font_placeholder_color", dim_text_color)
	var search_style = _make_style(panel_color.lightened(0.05), 4)
	search_style.content_margin_left = 10
	search_style.content_margin_right = 10
	_search_bar.add_theme_stylebox_override("normal", search_style)
	_search_bar.add_theme_stylebox_override("focus", search_style)
	_search_bar.text_changed.connect(_on_search_changed)
	search_container.add_child(_search_bar)

	# Build sections for each category
	for cat_key in categories:
		_build_section(cat_key)

	# Back button
	var back_container = HBoxContainer.new()
	back_container.alignment = BoxContainer.ALIGNMENT_CENTER
	_grid_vbox.add_child(back_container)

	var back_btn = Button.new()
	back_btn.text = "Back"
	back_btn.custom_minimum_size = Vector2(120, 40)
	back_btn.add_theme_font_size_override("font_size", 16)
	back_btn.add_theme_stylebox_override("normal", _make_style(panel_color, 8))
	back_btn.add_theme_stylebox_override("hover", _make_style(panel_color.lightened(0.15), 8))
	back_btn.add_theme_color_override("font_color", text_color)
	back_btn.pressed.connect(_hide_ui)
	back_container.add_child(back_btn)

	# --- Tooltip ---
	_tooltip_panel = PanelContainer.new()
	_tooltip_panel.add_theme_stylebox_override("panel", _make_style(Color(0.1, 0.14, 0.1, 0.95), 4))
	_tooltip_panel.visible = false
	_tooltip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_panel.z_index = 100
	add_child(_tooltip_panel)

	_tooltip_label = Label.new()
	_tooltip_label.add_theme_font_size_override("font_size", 13)
	_tooltip_label.add_theme_color_override("font_color", text_color)
	_tooltip_panel.add_child(_tooltip_label)

	# --- Detail overlay (hidden by default) ---
	_build_detail_overlay()


func _build_section(cat_key: String) -> void:
	var cat = categories[cat_key]

	# Section label above separator, left-aligned
	var header = Label.new()
	header.text = cat["label"]
	header.add_theme_font_size_override("font_size", 15)
	header.add_theme_color_override("font_color", cat["color"])
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_grid_vbox.add_child(header)

	# Separator line
	var sep = HSeparator.new()
	var sep_style = StyleBoxLine.new()
	sep_style.color = cat["color"].darkened(0.5)
	sep_style.thickness = 1
	sep.add_theme_stylebox_override("separator", sep_style)
	sep.add_theme_constant_override("separation", 4)
	_grid_vbox.add_child(sep)

	# Grid of icon tiles
	var flow = HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", TILE_PADDING)
	flow.add_theme_constant_override("v_separation", TILE_PADDING)
	_grid_vbox.add_child(flow)

	var section_data = {"header": header, "separator": sep, "grid": flow, "tiles": []}

	# Populate tiles
	for entry in cat["list"]:
		var tile = _build_tile(entry, cat_key)
		flow.add_child(tile["node"])
		section_data["tiles"].append(tile)
		_all_tiles.append(tile)

	_sections[cat_key] = section_data


func _build_tile(entry: Resource, cat_key: String) -> Dictionary:
	var is_locked := false
	var tech_id = _get_tech_id_for_entry(entry)
	if tech_id != &"":
		is_locked = not TechTree.is_researched(tech_id)

	# Outer container
	var panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(TILE_SIZE, TILE_SIZE)
	var cat_color: Color = categories[cat_key]["color"]

	var normal_style = _make_style(panel_color.lightened(0.03), 4)
	normal_style.content_margin_left = 2
	normal_style.content_margin_right = 2
	normal_style.content_margin_top = 2
	normal_style.content_margin_bottom = 2
	normal_style.border_width_left = 1
	normal_style.border_width_right = 1
	normal_style.border_width_top = 1
	normal_style.border_width_bottom = 1
	normal_style.border_color = cat_color.darkened(0.6)
	panel.add_theme_stylebox_override("panel", normal_style)

	# Icon
	if !is_locked:
		var icon_rect = TextureRect.new()
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		icon_rect.custom_minimum_size = Vector2(TILE_SIZE - 8, TILE_SIZE - 8)
		if entry.icon:
			icon_rect.texture = entry.icon
		else:
			icon_rect.texture = _fallback_icon
		icon_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		panel.add_child(icon_rect)

	if is_locked:
		# Lock overlay
		var lock_label = Label.new()
		lock_label.text = "🔒"
		lock_label.add_theme_font_size_override("font_size", 16)
		lock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lock_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lock_label.anchor_right = 1.0
		lock_label.anchor_bottom = 1.0
		lock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(lock_label)

	# Signals
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.mouse_entered.connect(_on_tile_hover.bind(entry, is_locked))
	panel.mouse_exited.connect(_on_tile_unhover)
	panel.gui_input.connect(_on_tile_input.bind(entry, cat_key, is_locked))

	return {"node": panel, "entry": entry, "cat_key": cat_key, "is_locked": is_locked}


func _build_detail_overlay() -> void:
	# Fullscreen dark backdrop
	_detail_overlay = ColorRect.new()
	_detail_overlay.color = Color(0.02, 0.04, 0.02, 0.8)
	_detail_overlay.anchor_right = 1.0
	_detail_overlay.anchor_bottom = 1.0
	_detail_overlay.visible = false
	_detail_overlay.z_index = 50
	add_child(_detail_overlay)

	# Click backdrop to close
	_detail_overlay.gui_input.connect(_on_detail_backdrop_input)

	# Centered detail panel
	_detail_panel = PanelContainer.new()
	_detail_panel.add_theme_stylebox_override("panel", _make_style(Color(0.06, 0.09, 0.06, 0.98), 10))
	_detail_panel.anchor_left = 0.15
	_detail_panel.anchor_right = 0.85
	_detail_panel.anchor_top = 0.05
	_detail_panel.anchor_bottom = 0.95
	_detail_panel.z_index = 51
	_detail_panel.visible = false
	add_child(_detail_panel)

	var outer_vbox = VBoxContainer.new()
	outer_vbox.add_theme_constant_override("separation", 4)
	_detail_panel.add_child(outer_vbox)

	# Close button row
	var close_row = HBoxContainer.new()
	close_row.alignment = BoxContainer.ALIGNMENT_END
	outer_vbox.add_child(close_row)

	var close_btn = Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(36, 36)
	close_btn.add_theme_font_size_override("font_size", 18)
	close_btn.add_theme_stylebox_override("normal", _make_style(Color(0, 0, 0, 0), 4))
	close_btn.add_theme_stylebox_override("hover", _make_style(Color(0.3, 0.1, 0.1, 0.5), 4))
	close_btn.add_theme_color_override("font_color", text_color)
	close_btn.pressed.connect(_close_detail)
	close_row.add_child(close_btn)

	# Scroll area for detail content
	_detail_scroll = ScrollContainer.new()
	_detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer_vbox.add_child(_detail_scroll)

	_detail_container = VBoxContainer.new()
	_detail_container.add_theme_constant_override("separation", 8)
	_detail_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_scroll.add_child(_detail_container)


# =========================
# TILE INTERACTIONS
# =========================

func _on_tile_hover(entry: Resource, is_locked: bool) -> void:
	_hovered_entry = entry
	if is_locked:
		_tooltip_label.text = "🔒 Locked"
	else:
		_tooltip_label.text = entry.display_name
	_tooltip_panel.visible = true


func _on_tile_unhover() -> void:
	_hovered_entry = null
	_tooltip_panel.visible = false


func _on_tile_input(event: InputEvent, entry: Resource, cat_key: String, is_locked: bool) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if is_locked:
			return
		_show_detail(entry, cat_key)


func _on_detail_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_close_detail()


# =========================
# DETAIL OVERLAY
# =========================

func _show_detail(entry: Resource, cat_key: String) -> void:
	_detail_open = true
	_current_detail_cat = cat_key
	_detail_overlay.visible = true
	_detail_panel.visible = true
	_tooltip_panel.visible = false

	_clear_container(_detail_container)

	var cat_color = categories[cat_key]["color"]
	_add_header(entry.display_name, cat_color)

	if "description" in entry and entry.description != "":
		_add_text(entry.description, dim_text_color, 13)

	_add_separator()

	match cat_key:
		"items":
			_show_item_details(entry as ItemData)
		"blocks":
			_show_block_details(entry as BlockData)
		"sectors":
			_show_sector_details(entry as SectorData)
		"units":
			_show_unit_details(entry as UnitData)
		"fluids":
			_show_fluid_details(entry as FluidData)
		"status_effects":
			_show_status_effect_details(entry as StatusEffectData)
		"tiles":
			_show_tile_details(entry as TerrainTileData)

func _close_detail() -> void:
	_detail_open = false
	_detail_overlay.visible = false
	_detail_panel.visible = false


# =========================
# SEARCH
# =========================

func _on_search_changed(new_text: String) -> void:
	search_text = new_text.strip_edges().to_lower()
	_filter_tiles()


func _filter_tiles() -> void:
	for cat_key in _sections:
		var section = _sections[cat_key]
		var visible_count := 0
		for tile_data in section["tiles"]:
			var entry: Resource = tile_data["entry"]
			var matches := true
			if search_text != "":
				matches = entry.display_name.to_lower().find(search_text) != -1
			tile_data["node"].visible = matches
			if matches:
				visible_count += 1

		# Hide entire section if no matches
		section["header"].visible = visible_count > 0
		section["separator"].visible = visible_count > 0
		section["grid"].visible = visible_count > 0


# =========================
# TECH TREE INTEGRATION
# =========================

func _get_tech_id_for_entry(entry: Resource) -> StringName:
	if not entry or not "id" in entry:
		return &""
	var eid: StringName = entry.id
	if TechTree.nodes.has(eid):
		return eid
	return &""


# =========================
# DETAIL PANEL RENDERING
# =========================

func _show_item_details(item: ItemData) -> void:
	_add_section("Properties")
	_add_stat("Category", _item_category_name(item.category), text_color)
	_add_stat("Max Stack", str(item.max_stack), text_color)
	_add_stat("Base Value", str(item.base_value), text_color)
	_add_stat("Conveyable", "Yes" if item.conveyable else "No", text_color)

	_add_separator()
	_add_section("Used In")
	var found_use := false
	for block in Registry.blocks_list:
		if block.build_cost.has(item.id):
			_add_text("• %s (cost: %d)" % [block.display_name, block.build_cost[item.id]], text_color, 13)
			found_use = true
		if block.input_items.has(item.id):
			_add_text("• %s (input: %d/cycle)" % [block.display_name, block.input_items[item.id]], text_color, 13)
			found_use = true
	if not found_use:
		_add_text("Not used in any recipes yet", dim_text_color, 13)

	_add_separator()
	_add_section("Produced By")
	var found_source := false
	for block in Registry.blocks_list:
		if block.output_items.has(item.id):
			_add_text("• %s (output: %d/cycle)" % [block.display_name, block.output_items[item.id]], text_color, 13)
			found_source = true
	if not found_source:
		_add_text("Not produced by any building yet", dim_text_color, 13)


func _show_block_details(block: BlockData) -> void:
	_add_section("General")
	_add_stat("Size", "%dx%d" % [block.grid_size.x, block.grid_size.y], text_color)
	
	_add_stat("Max HP", str(block.max_health), Color(0.4, 1.0, 0.4))
	if block.health_regen > 0:
		_add_stat("Regen", "%s HP/sec" % str(block.health_regen), Color(0.4, 1.0, 0.4))
		
	for item_id in block.build_cost:
		var item = Registry.get_item_or_fluid(item_id)
		var item_name = item.display_name if item else str(item_id)
		var item_color = item.color if item else text_color
		_add_stat(item_name, str(block.build_cost[item_id]), item_color)

	if block.is_producer():
		_add_separator()
		_add_section("Production (every %ss)" % str(block.production_time))
		if block.input_items.size() > 0:
			_add_text("Inputs:", dim_text_color, 12)
			for item_id in block.input_items:
				var item = Registry.get_item_or_fluid(item_id)
				var item_name = item.display_name if item else str(item_id)
				_add_stat("  " + item_name, str(block.input_items[item_id]), Color(1.0, 0.5, 0.5))
		_add_text("Outputs:", dim_text_color, 12)
		for item_id in block.output_items:
			var item = Registry.get_item_or_fluid(item_id)
			var item_name = item.display_name if item else str(item_id)
			_add_stat("  " + item_name, str(block.output_items[item_id]), Color(0.5, 1.0, 0.5))

	if block.is_turret():
		_add_separator()
		_add_section("Combat")
		_add_stat_bar("Damage", block.attack_damage, 50.0, Color(1.0, 0.4, 0.4))
		_add_stat_bar("Attack Speed", block.attack_speed, 3.0, Color(1.0, 0.8, 0.3))
		_add_stat_bar("Range", block.attack_range, 10.0, Color(0.4, 0.7, 1.0))
		if block.is_aoe:
			_add_stat("AoE Radius", "%s px" % str(block.aoe_radius), Color(1.0, 0.6, 0.3))

		# --- Ammo entries (Mindustry-style listing of every accepted ammo type) ---
		if block.ammo_types.size() > 0:
			_add_separator()
			_add_section("Ammo")
			for ammo_res in block.ammo_types:
				if ammo_res == null or not (ammo_res is AmmoType):
					continue
				_add_ammo_entry(block, ammo_res as AmmoType)
		else:
			_add_separator()
			_add_text("Requires ammo to fire — none configured.", Color(1.0, 0.5, 0.4), 12)

	if block.is_transport():
		_add_separator()
		_add_section("Transport")
		_add_stat("Speed", "%s items/sec" % str(block.transport_speed), text_color)
		_add_stat("Fluids", "Yes" if block.transports_fluid else "No", text_color)

	if block.requires_power:
		_add_separator()
		_add_section("Power")
		_add_stat("Consumption", "%s Power/sec" % str(block.power_consumption), Color(1.0, 1.0, 0.3))


func _show_unit_details(unit: UnitData) -> void:
	_add_section("General")
	_add_stat("Team", _team_name(unit.team), text_color)
	_add_stat("Type", _unit_category_name(unit.category), text_color)
	_add_stat("Threat Value", str(unit.threat_value), Color(1.0, 0.5, 0.5))

	_add_separator()
	_add_section("Stats")
	_add_stat_bar("Health", unit.max_health, 200.0, Color(0.4, 1.0, 0.4))
	# move_speed is stored in tiles/sec; max ~3 t/s covers every unit.
	_add_stat_bar("Speed", unit.move_speed, 3.0, Color(0.4, 0.7, 1.0))
	_add_stat_bar("Damage", unit.attack_damage, 50.0, Color(1.0, 0.4, 0.4))
	if unit.armor > 0:
		_add_stat("Armor", str(unit.armor), Color(0.7, 0.7, 0.8))
	if unit.health_regen > 0:
		_add_stat("Regen", "%s HP/sec" % str(unit.health_regen), Color(0.4, 1.0, 0.4))

	_add_separator()
	_add_section("Combat")
	_add_stat("Attack Speed", "%ss" % str(unit.attack_speed), text_color)
	_add_stat("Attack Range", "%s px" % str(unit.attack_range), text_color)
	_add_stat("Detection Range", "%s px" % str(unit.detection_range), text_color)
	_add_stat("Target Priority", _target_priority_name(unit.target_priority), text_color)
	match unit.movement_layer:
		UnitData.MovementLayer.CRAWLER:
			_add_text("✦ Crawls over blocks and small walls", Color(0.6, 0.9, 0.4), 13)
		UnitData.MovementLayer.HOVER:
			_add_text("✦ Hovers over terrain", Color(0.3, 0.7, 0.9), 13)
		UnitData.MovementLayer.FLYING:
			_add_text("✦ Flies over all obstacles", Color(0.5, 0.8, 1.0), 13)

	if unit.drops.size() > 0:
		_add_separator()
		_add_section("Drops (%d%% chance)" % int(unit.drop_chance * 100))
		for item_id in unit.drops:
			var item = Registry.get_item_or_fluid(item_id)
			var item_name = item.display_name if item else str(item_id)
			_add_stat(item_name, str(unit.drops[item_id]), text_color)

	if unit.immunities.size() > 0:
		_add_separator()
		_add_section("Immunities")
		_add_text(", ".join(unit.immunities), text_color, 13)


func _show_fluid_details(fluid: FluidData) -> void:
	_add_section("Properties")
	_add_stat("Viscosity", str(fluid.viscosity), text_color)
	_add_stat("Flow Speed", "%.1fx" % fluid.get_flow_speed(), accent_color)
	_add_stat("Units/Segment", str(fluid.units_per_segment), text_color)
	_add_stat("Temperature", "%s°" % str(fluid.temperature), text_color)

	if fluid.is_hazardous:
		_add_separator()
		_add_section("⚠ Hazardous")
		_add_stat("Damage", "%s/sec" % str(fluid.hazard_damage), Color(1.0, 0.3, 0.3))

	if fluid.evaporates:
		_add_separator()
		_add_section("Evaporation")
		_add_stat("Rate", "%s units/sec" % str(fluid.evaporation_rate), dim_text_color)

	if fluid.item_equivalent != &"":
		_add_separator()
		_add_section("Conversion")
		var item = Registry.get_item(fluid.item_equivalent)
		var fname = item.display_name if item else str(fluid.item_equivalent)
		_add_stat("Item Form", fname, text_color)
		_add_stat("Ratio", "%s units = 1 item" % str(fluid.units_per_item), text_color)


func _show_status_effect_details(effect: StatusEffectData) -> void:
	_add_section("Properties")
	_add_stat("Type", _effect_type_name(effect.effect_type), text_color)
	_add_stat("Duration", "%ss" % str(effect.duration) if effect.duration > 0 else "Permanent", text_color)
	_add_stat("Stackable", "Yes (max %d)" % effect.max_stacks if effect.stackable else "No", text_color)
	_add_stat("Refreshes", "Yes" if effect.refresh_on_reapply else "No", text_color)

	if effect.speed_modifier != 1.0 or effect.damage_modifier != 1.0 or \
	   effect.defense_modifier != 1.0 or effect.attack_speed_modifier != 1.0 or \
	   effect.production_modifier != 1.0:
		_add_separator()
		_add_section("Stat Modifiers")

	if effect.speed_modifier != 1.0:
		_add_modifier_stat("Move Speed", effect.speed_modifier)
	if effect.damage_modifier != 1.0:
		_add_modifier_stat("Damage", effect.damage_modifier)
	if effect.defense_modifier != 1.0:
		_add_modifier_stat("Defense", effect.defense_modifier)
	if effect.attack_speed_modifier != 1.0:
		_add_modifier_stat("Attack Speed", effect.attack_speed_modifier)
	if effect.production_modifier != 1.0:
		_add_modifier_stat("Production", effect.production_modifier)

	if effect.has_dot():
		_add_separator()
		_add_section("Damage Over Time")
		_add_stat("Tick Damage", str(effect.tick_damage), Color(1.0, 0.4, 0.4))
		_add_stat("Tick Interval", "%ss" % str(effect.tick_interval), text_color)
		_add_stat("Total Damage", str(effect.get_total_damage()), Color(1.0, 0.3, 0.3))
	elif effect.has_hot():
		_add_separator()
		_add_section("Heal Over Time")
		_add_stat("Tick Heal", str(abs(effect.tick_damage)), Color(0.4, 1.0, 0.4))
		_add_stat("Tick Interval", "%ss" % str(effect.tick_interval), text_color)

	if effect.stuns or effect.roots or effect.silences:
		_add_separator()
		_add_section("Crowd Control")
		if effect.stuns:
			_add_text("✦ Stuns target (can't move or attack)", Color(1.0, 0.8, 0.3), 13)
		if effect.roots:
			_add_text("✦ Roots target (can't move)", Color(1.0, 0.8, 0.3), 13)
		if effect.silences:
			_add_text("✦ Silences target (can't use abilities)", Color(1.0, 0.8, 0.3), 13)

	if effect.spreads:
		_add_separator()
		_add_section("⚠ Spreads")
		_add_stat("Radius", "%s px" % str(effect.spread_radius), Color(1.0, 0.5, 0.5))
		_add_stat("Chance", "%d%%/sec" % int(effect.spread_chance * 100), Color(1.0, 0.5, 0.5))


func _show_sector_details(sector: SectorData) -> void:
	_add_section("Objective")
	_add_text(sector.get_objective_text(), Color(1.0, 0.85, 0.3), 14)

	if sector.description != "":
		_add_separator()
		_add_section("Description")
		_add_text(sector.description, text_color, 13)

	if sector.available_resources.size() > 0:
		_add_separator()
		_add_section("Available Resources")
		for item_id in sector.available_resources:
			var item = Registry.get_item_or_fluid(StringName(item_id))
			var iname = item.display_name if item else str(item_id)
			_add_text("• " + iname, Color(0.3, 0.9, 0.3), 13)

	if sector.wave_units_data.size() > 0:
		_add_separator()
		_add_section("Enemy Waves")
		_add_stat("Waves", str(sector.waves), text_color)
		for uid in sector.wave_units_data:
			var unit = Registry.get_unit(StringName(uid))
			var uname = unit.display_name if unit else str(uid)
			_add_text("• " + uname, Color(1.0, 0.5, 0.5), 13)

	if sector.unlocks.size() > 0:
		_add_separator()
		_add_section("Unlocks")
		for uid in sector.unlocks:
			var node_data = TechTree.get_node_data(StringName(uid))
			var uname = node_data["name"] if node_data else str(uid)
			_add_text("• " + uname, Color(0.95, 0.82, 0.2), 13)

	if sector.required_sectors.size() > 0:
		_add_separator()
		_add_section("Prerequisites")
		for sid in sector.required_sectors:
			var sec = Registry.get_sector(StringName(sid))
			var sname = sec.display_name if sec else str(sid)
			_add_text("• " + sname, dim_text_color, 13)

	if sector.tags.size() > 0:
		_add_separator()
		_add_stat("Tags", ", ".join(sector.tags), dim_text_color)


func _show_tile_details(tile: TerrainTileData) -> void:
	_add_section("Properties")
	_add_stat("Category", "Wall" if tile.is_wall() else "Floor", text_color)
	_add_color_swatch("Color", tile.color)

	if tile.draw_border:
		_add_color_swatch("Border", tile.border_color)

	if tile.speed_modifier != 1.0:
		var pct = (tile.speed_modifier - 1.0) * 100.0
		var prefix = "+" if pct > 0 else ""
		var col = Color(0.4, 1.0, 0.4) if pct > 0 else Color(1.0, 0.4, 0.4)
		_add_stat("Speed Modifier", "%s%.0f%%" % [prefix, pct], col)

	if tile.contact_damage > 0:
		_add_stat("Contact Damage", "%s/sec" % str(tile.contact_damage), Color(1.0, 0.4, 0.4))

	if tile.is_wall():
		_add_separator()
		_add_section("Wall Properties")
		_add_stat("Height", str(tile.height), text_color)
		_add_stat("Blocks LOS", "Yes" if tile.blocks_los else "No", text_color)
		_add_stat("Destructible", "Yes" if tile.destructible else "No", text_color)
		if tile.destructible:
			_add_stat("Health", str(tile.max_health), Color(0.4, 1.0, 0.4))

	if tile.tags.size() > 0:
		_add_separator()
		_add_stat("Tags", ", ".join(tile.tags), dim_text_color)


# =========================
# UI HELPER WIDGETS
# =========================

func _add_header(text: String, color: Color) -> void:
	var label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", color)
	_detail_container.add_child(label)


func _add_section(text: String) -> void:
	var label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", accent_color)
	_detail_container.add_child(label)


func _add_text(text: String, color: Color, size: int) -> void:
	var label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_container.add_child(label)


func _add_stat(label_text: String, value_text: String, value_color: Color) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var label = Label.new()
	label.text = label_text + ":"
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", dim_text_color)
	label.custom_minimum_size.x = 140
	hbox.add_child(label)

	var value = Label.new()
	value.text = value_text
	value.add_theme_font_size_override("font_size", 14)
	value.add_theme_color_override("font_color", value_color)
	hbox.add_child(value)

	_detail_container.add_child(hbox)


func _add_stat_bar(label_text: String, value: float, max_value: float, bar_color: Color) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var label = Label.new()
	label.text = label_text + ":"
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", dim_text_color)
	label.custom_minimum_size.x = 140
	hbox.add_child(label)

	var val_label = Label.new()
	val_label.text = str(value)
	val_label.add_theme_font_size_override("font_size", 14)
	val_label.add_theme_color_override("font_color", text_color)
	val_label.custom_minimum_size.x = 50
	hbox.add_child(val_label)

	var bar_container = Control.new()
	bar_container.custom_minimum_size = Vector2(120, 14)
	hbox.add_child(bar_container)

	var bar_bg = ColorRect.new()
	bar_bg.color = Color(0.15, 0.15, 0.15, 1.0)
	bar_bg.size = Vector2(120, 14)
	bar_container.add_child(bar_bg)

	var bar_fill = ColorRect.new()
	bar_fill.color = bar_color
	var fill_pct = clamp(value / max_value, 0.0, 1.0)
	bar_fill.size = Vector2(120 * fill_pct, 14)
	bar_container.add_child(bar_fill)

	_detail_container.add_child(hbox)


## Renders one AmmoType under a turret's database entry — Mindustry-style:
## item icon + name as the header, then a card listing damage / reload / range
## bonus / pellets / lifetime / pierce / homing / knockback / splash / status /
## targeting filters, with anything left at default values omitted.
func _add_ammo_entry(turret: BlockData, ammo: AmmoType) -> void:
	# --- Header: item icon + ammo display name ---
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)

	var item = Registry.get_item_or_fluid(ammo.item_id)
	var icon_tex: Texture2D = null
	if ammo.icon:
		icon_tex = ammo.icon
	elif item and item.icon:
		icon_tex = item.icon

	if icon_tex:
		var tex_rect := TextureRect.new()
		tex_rect.texture = icon_tex
		tex_rect.custom_minimum_size = Vector2(20, 20)
		tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		header.add_child(tex_rect)
	else:
		var sw := ColorRect.new()
		sw.custom_minimum_size = Vector2(20, 20)
		sw.color = ammo.projectile_color
		header.add_child(sw)

	# Cost stub on the right ("x N")
	if ammo.amount_per_shot > 1:
		var cost_lbl := Label.new()
		cost_lbl.text = "× %d" % ammo.amount_per_shot
		cost_lbl.add_theme_font_size_override("font_size", 13)
		cost_lbl.add_theme_color_override("font_color", dim_text_color)
		header.add_child(cost_lbl)

	_detail_container.add_child(header)

	# --- Damage stats ---
	_add_stat("  Damage", str(ammo.damage), Color(1.0, 0.4, 0.4))
	if ammo.building_damage_mult != 1.0:
		_add_stat("  vs Buildings", "×%.2f" % ammo.building_damage_mult, Color(1.0, 0.7, 0.4))
	if ammo.unit_damage_mult != 1.0:
		_add_stat("  vs Units", "×%.2f" % ammo.unit_damage_mult, Color(1.0, 0.7, 0.4))
	if ammo.pierce_armor > 0.0:
		_add_stat("  Armor Pierce", str(ammo.pierce_armor), Color(0.9, 0.6, 0.9))
	if ammo.pierce_count > 0:
		_add_stat("  Pierces", "%d targets" % ammo.pierce_count, Color(0.9, 0.6, 0.9))

	# --- Reload / fire rate ---
	var effective_reload: float = turret.attack_speed * ammo.reload_multiplier
	if ammo.reload_multiplier != 1.0:
		_add_stat("  Reload", "%.2fs (×%.2f)" % [effective_reload, ammo.reload_multiplier], Color(1.0, 0.8, 0.3))
	else:
		_add_stat("  Reload", "%.2fs" % effective_reload, Color(1.0, 0.8, 0.3))
	if ammo.range_bonus != 0.0:
		var effective_range: float = turret.attack_range + ammo.range_bonus
		_add_stat("  Range", "%.0f (+%.0f)" % [effective_range, ammo.range_bonus], Color(0.4, 0.7, 1.0))
	if ammo.projectiles_per_shot > 1:
		_add_stat("  Pellets", "%d /shot" % ammo.projectiles_per_shot, Color(0.7, 0.8, 1.0))
	if ammo.inaccuracy > 0.0:
		_add_stat("  Inaccuracy", "%.1f°" % ammo.inaccuracy, Color(0.7, 0.7, 0.8))

	# --- Ballistics ---
	_add_stat("  Speed", "%.0f px/s" % ammo.projectile_speed, Color(0.6, 0.9, 0.7))
	if ammo.projectile_lifetime > 0.0 and ammo.projectile_lifetime != 4.0:
		_add_stat("  Lifetime", "%.1fs" % ammo.projectile_lifetime, dim_text_color)
	if ammo.homing > 0.0:
		_add_stat("  Homing", "%.0f%%" % (ammo.homing * 100.0), Color(1.0, 0.7, 0.9))
	if ammo.knockback > 0.0:
		_add_stat("  Knockback", "%.0f px" % ammo.knockback, Color(0.9, 0.8, 0.5))

	# --- Splash ---
	if ammo.is_splash and ammo.splash_radius > 0.0:
		_add_stat("  Splash Radius", "%.0f px" % ammo.splash_radius, Color(1.0, 0.6, 0.3))
		if ammo.splash_damage_mult != 1.0:
			_add_stat("  Splash Damage", "×%.2f" % ammo.splash_damage_mult, Color(1.0, 0.6, 0.3))

	# --- DoT / status ---
	if ammo.burn_damage > 0.0:
		_add_stat("  Burn", "%.0f dmg/s × %.1fs" % [ammo.burn_damage, ammo.burn_duration], Color(1.0, 0.5, 0.2))
	if ammo.status_effect != null:
		var status_name: String = "applied"
		if "display_name" in ammo.status_effect and ammo.status_effect.display_name != "":
			status_name = ammo.status_effect.display_name
		var dur_suffix: String = " (%.1fs)" % ammo.status_duration if ammo.status_duration > 0.0 else ""
		_add_stat("  Status", status_name + dur_suffix, Color(0.9, 0.5, 1.0))

	# --- Targeting filters ---
	if not ammo.collides_air or not ammo.collides_ground:
		var filt: String = ""
		if ammo.collides_air and not ammo.collides_ground:
			filt = "Air only"
		elif ammo.collides_ground and not ammo.collides_air:
			filt = "Ground only"
		else:
			filt = "Cannot hit anything!"
		_add_stat("  Targets", filt, Color(0.7, 0.9, 1.0))

	# Spacer between ammo entries
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	_detail_container.add_child(spacer)


func _add_modifier_stat(label_text: String, modifier: float) -> void:
	var pct = (modifier - 1.0) * 100.0
	var prefix = "+" if pct > 0 else ""
	var color = Color(0.4, 1.0, 0.4) if pct > 0 else Color(1.0, 0.4, 0.4)
	if label_text == "Defense":
		color = Color(1.0, 0.4, 0.4) if pct > 0 else Color(0.4, 1.0, 0.4)
	_add_stat(label_text, "%s%.0f%%" % [prefix, pct], color)


func _add_color_swatch(label_text: String, swatch_color: Color) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var label = Label.new()
	label.text = label_text + ":"
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", dim_text_color)
	label.custom_minimum_size.x = 140
	hbox.add_child(label)

	var swatch = ColorRect.new()
	swatch.color = swatch_color
	swatch.custom_minimum_size = Vector2(24, 14)
	hbox.add_child(swatch)

	var hex = Label.new()
	hex.text = swatch_color.to_html(false)
	hex.add_theme_font_size_override("font_size", 12)
	hex.add_theme_color_override("font_color", dim_text_color)
	hbox.add_child(hex)

	_detail_container.add_child(hbox)


func _add_separator() -> void:
	var sep = HSeparator.new()
	sep.add_theme_constant_override("separation", 8)
	sep.add_theme_stylebox_override("separator", StyleBoxLine.new())
	_detail_container.add_child(sep)


# =========================
# ENUM NAME HELPERS
# =========================

func _item_category_name(cat: ItemData.ItemCategory) -> String:
	match cat:
		ItemData.ItemCategory.RAW_RESOURCE: return "Raw Resource"
		ItemData.ItemCategory.REFINED: return "Refined"
		ItemData.ItemCategory.ADVANCED: return "Advanced"
		ItemData.ItemCategory.COMPONENT: return "Component"
		ItemData.ItemCategory.SPECIAL: return "Special"
	return "Unknown"

func _block_category_name(cat: BlockData.BlockCategory) -> String:
	match cat:
		BlockData.BlockCategory.CORE: return "Core"
		BlockData.BlockCategory.EXTRACTORS: return "Extractors"
		BlockData.BlockCategory.FACTORIES: return "Factories"
		BlockData.BlockCategory.POWER: return "Power"
		BlockData.BlockCategory.TURRETS: return "Turrets"
		BlockData.BlockCategory.WALLS: return "Walls"
		BlockData.BlockCategory.UNITS: return "Units"
		BlockData.BlockCategory.ASSIST: return "Assist"
		BlockData.BlockCategory.ITEMS: return "Items"
		BlockData.BlockCategory.FLUIDS: return "Fluids"
	return "Unknown"

func _unit_category_name(cat: UnitData.UnitCategory) -> String:
	match cat:
		UnitData.UnitCategory.MELEE: return "Melee"
		UnitData.UnitCategory.RANGED: return "Ranged"
		UnitData.UnitCategory.TANK: return "Tank"
		UnitData.UnitCategory.SWARM: return "Swarm"
		UnitData.UnitCategory.FLYING: return "Flying"
		UnitData.UnitCategory.SUPPORT: return "Support"
		UnitData.UnitCategory.BUILDER: return "Builder"
		UnitData.UnitCategory.BOSS: return "Boss"
	return "Unknown"

func _team_name(t: UnitData.Team) -> String:
	match t:
		UnitData.Team.PLAYER: return "Player"
		UnitData.Team.ENEMY: return "Enemy"
		UnitData.Team.NEUTRAL: return "Neutral"
	return "Unknown"

func _target_priority_name(tp: UnitData.TargetPriority) -> String:
	match tp:
		UnitData.TargetPriority.NEAREST: return "Nearest"
		UnitData.TargetPriority.BUILDINGS: return "Buildings"
		UnitData.TargetPriority.UNITS: return "Units"
		UnitData.TargetPriority.WEAKEST: return "Weakest"
		UnitData.TargetPriority.PLAYER_DRONE: return "Player Drone"
	return "Unknown"

func _effect_type_name(et: StatusEffectData.EffectType) -> String:
	match et:
		StatusEffectData.EffectType.BUFF: return "Buff"
		StatusEffectData.EffectType.DEBUFF: return "Debuff"
		StatusEffectData.EffectType.DOT: return "Damage Over Time"
		StatusEffectData.EffectType.HOT: return "Heal Over Time"
		StatusEffectData.EffectType.CROWD_CONTROL: return "Crowd Control"
		StatusEffectData.EffectType.TRANSFORM: return "Transform"
	return "Unknown"


# =========================
# STYLE HELPERS
# =========================

func _make_style(color: Color, radius: int) -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	return style


func _clear_container(container: Container) -> void:
	for child in container.get_children():
		child.queue_free()


# =========================
# SHOW / HIDE
# =========================

func _show_ui() -> void:
	is_open = true
	_bg.visible = true
	_scroll.visible = true
	_tooltip_panel.visible = false
	_close_detail()
	# Sync every tile against the current tech state — covers the case
	# where the player researched something while the database was closed
	# and the node_state_changed signal fired but we no longer needed to
	# refresh until reopen.
	for tile in _all_tiles:
		_refresh_tile_lock(tile)
	get_tree().paused = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _search_bar:
		_search_bar.text = ""
		search_text = ""
		_filter_tiles()


func _hide_ui() -> void:
	is_open = false
	_bg.visible = false
	_scroll.visible = false
	_tooltip_panel.visible = false
	_close_detail()
	process_mode = Node.PROCESS_MODE_INHERIT
	var tech_ui = get_node_or_null("/root/Main/TechTreeUI")
	if tech_ui == null or not tech_ui.is_open:
		get_tree().paused = false


# =========================
# EXTERNAL API
# =========================

## Called by TechTreeUI to navigate directly to an entry.
func navigate_to_entry(entry_id: StringName) -> void:
	_show_ui()
	# Find the entry across all categories
	for cat_key in categories:
		var cat = categories[cat_key]
		for entry in cat["list"]:
			if entry.id == entry_id:
				_show_detail(entry, cat_key)
				return
