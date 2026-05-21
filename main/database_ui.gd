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

# Shared lock icon used by tile overlays + the icon grids in
# Used In / Produced By / Used to Build / etc.
var _lock_icon: Texture2D = preload("res://textures/UI/LockIcon.png")

# --- CATEGORY DEFINITIONS ---
var categories := {}

# --- STYLE ---
# Neutral black/gray theme. Per-stat colors (health green, damage red,
# etc.) are still set inline at their call sites and intentionally stay
# colored — only the chrome (bg / panels / highlights / body text) is
# desaturated here.
var bg_color := Color(0.05, 0.05, 0.06, 0.95)
var panel_color := Color(0.10, 0.10, 0.12, 0.9)
var highlight_color := Color(0.22, 0.22, 0.26, 1.0)
var text_color := Color(0.92, 0.93, 0.95, 1.0)
var dim_text_color := Color(0.60, 0.62, 0.66, 1.0)
var accent_color := Color(0.78, 0.80, 0.84, 1.0)

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
		# PanelContainer stretches direct children to fill, so anchor /
		# offset insets are ignored. Wrap the icon in a CenterContainer
		# and give the TextureRect a fixed custom_minimum_size so it
		# stays small inside the tile.
		var center = CenterContainer.new()
		center.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(center)
		var lock_rect = TextureRect.new()
		lock_rect.texture = _lock_icon
		lock_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		lock_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		lock_rect.custom_minimum_size = Vector2(22, 22)
		lock_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		center.add_child(lock_rect)
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
	elif _detail_open and not is_open and event.is_action_pressed("ui_cancel"):
		# Standalone detail (opened from the tech tree) — Esc closes the
		# overlay without touching the tech tree underneath.
		_close_detail()
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
	_tooltip_panel.add_theme_stylebox_override("panel", _make_style(Color(0.12, 0.12, 0.14, 0.95), 4))
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

	var section_data = {"header": header, "separator": sep, "tiles": [], "subsections": []}

	# For the blocks tab, group entries by BlockCategory and emit a
	# sub-header + sub-separator between groups (same visual language
	# as the top-level category headers, just smaller / dimmer).
	if cat_key == "blocks":
		var grouped: Dictionary = {}
		for entry in cat["list"]:
			if entry is BlockData:
				if entry.id == &"archive" or entry.id == &"power_source":
					continue
				var sub_key: int = entry.category
				if not grouped.has(sub_key):
					grouped[sub_key] = []
				grouped[sub_key].append(entry)
		# Preserve enum order so the layout reads CORE → EXTRACTORS → …
		var ordered: Array = []
		for sub_key in [
			BlockData.BlockCategory.CORE, BlockData.BlockCategory.EXTRACTORS,
			BlockData.BlockCategory.FACTORIES, BlockData.BlockCategory.POWER,
			BlockData.BlockCategory.TURRETS, BlockData.BlockCategory.WALLS,
			BlockData.BlockCategory.UNITS, BlockData.BlockCategory.ASSIST,
			BlockData.BlockCategory.PAYLOAD, BlockData.BlockCategory.ITEMS,
			BlockData.BlockCategory.FLUIDS]:
			if grouped.has(sub_key):
				ordered.append(sub_key)
		# Wrap all sub-sections in a tight inner VBox so the gap between
		# sub-sections is visibly smaller than the gap between top-level
		# categories — they read as part of the same Blocks section
		# instead of as siblings of EXTRACTORS / FACTORIES / etc.
		var sub_wrap = VBoxContainer.new()
		sub_wrap.add_theme_constant_override("separation", 2)
		_grid_vbox.add_child(sub_wrap)
		var first_sub: bool = true
		for sub_key in ordered:
			_add_sub_section_header(_block_category_name(sub_key), cat["color"], not first_sub, sub_wrap)
			first_sub = false
			var sub_flow = HFlowContainer.new()
			sub_flow.add_theme_constant_override("h_separation", TILE_PADDING)
			sub_flow.add_theme_constant_override("v_separation", TILE_PADDING)
			sub_wrap.add_child(sub_flow)
			for entry in grouped[sub_key]:
				var tile = _build_tile(entry, cat_key)
				sub_flow.add_child(tile["node"])
				section_data["tiles"].append(tile)
				_all_tiles.append(tile)
			section_data["subsections"].append({"flow": sub_flow, "key": sub_key})
		# Mirror the original `grid` key so search filtering's
		# `section["grid"]` lookup keeps working — point it at the
		# first sub_flow so hiding it on no-match still works
		# visually. The filter walks per-tile anyway.
		if not section_data["subsections"].is_empty():
			section_data["grid"] = section_data["subsections"][0]["flow"]
		else:
			var empty_flow = HFlowContainer.new()
			_grid_vbox.add_child(empty_flow)
			section_data["grid"] = empty_flow
	else:
		# Non-blocks tabs: single flat grid as before.
		var flow = HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", TILE_PADDING)
		flow.add_theme_constant_override("v_separation", TILE_PADDING)
		_grid_vbox.add_child(flow)
		section_data["grid"] = flow
		for entry in cat["list"]:
			var tile = _build_tile(entry, cat_key)
			flow.add_child(tile["node"])
			section_data["tiles"].append(tile)
			_all_tiles.append(tile)

	_sections[cat_key] = section_data


## Adds a sub-section header inside a top-level category (e.g. the
## "Extractors" header under the "Blocks" section). The text sits
## above a thin line — same visual language as the main section
## header but in a dimmer / smaller style so the hierarchy reads.
## `with_top_pad` inserts a tiny gap before the header for every
## sub-section after the first.
func _add_sub_section_header(text: String, color: Color, with_top_pad: bool, parent: Container = null) -> void:
	var host: Container = parent if parent != null else _grid_vbox
	if with_top_pad:
		var pad = Control.new()
		pad.custom_minimum_size = Vector2(0, 2)
		host.add_child(pad)
	var header = Label.new()
	header.text = text
	header.add_theme_font_size_override("font_size", 13)
	header.add_theme_color_override("font_color", color.lightened(0.1))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	host.add_child(header)
	var sep = HSeparator.new()
	var sep_style = StyleBoxLine.new()
	sep_style.color = color.darkened(0.6)
	sep_style.thickness = 1
	sep.add_theme_stylebox_override("separator", sep_style)
	sep.add_theme_constant_override("separation", 4)
	host.add_child(sep)


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
		# Lock overlay — wrap in a CenterContainer because PanelContainer
		# stretches direct children to fill (anchor/offset are ignored).
		var center = CenterContainer.new()
		center.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(center)
		var lock_rect = TextureRect.new()
		lock_rect.texture = _lock_icon
		lock_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		lock_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		lock_rect.custom_minimum_size = Vector2(28, 28)
		lock_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		center.add_child(lock_rect)

	# Signals
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.mouse_entered.connect(_on_tile_hover.bind(entry, is_locked))
	panel.mouse_exited.connect(_on_tile_unhover)
	panel.gui_input.connect(_on_tile_input.bind(entry, cat_key, is_locked))

	return {"node": panel, "entry": entry, "cat_key": cat_key, "is_locked": is_locked}


func _build_detail_overlay() -> void:
	# Fullscreen dark backdrop
	_detail_overlay = ColorRect.new()
	_detail_overlay.color = Color(0.07, 0.07, 0.07, 0.8)
	_detail_overlay.anchor_right = 1.0
	_detail_overlay.anchor_bottom = 1.0
	_detail_overlay.visible = false
	_detail_overlay.z_index = 50
	add_child(_detail_overlay)

	# Click backdrop to close
	_detail_overlay.gui_input.connect(_on_detail_backdrop_input)

	# Centered detail panel
	_detail_panel = PanelContainer.new()
	_detail_panel.add_theme_stylebox_override("panel", _make_style(Color(0.08, 0.08, 0.10, 0.98), 10))
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
		_tooltip_label.text = "Locked"
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
	_add_header_with_icon(entry, cat_color)

	# Block detail handles its own Purpose section now; for other
	# categories keep the inline description as before so the layout
	# doesn't regress.
	if cat_key != "blocks" and "description" in entry and entry.description != "":
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

func _close_detail() -> void:
	_detail_open = false
	_detail_overlay.visible = false
	_detail_panel.visible = false
	# When the detail was opened standalone (e.g. clicked from the tech
	# tree), the rest of the database UI is hidden — closing the detail
	# means the database is fully gone, so drop our pause hold. Skip if
	# the grid is up (regular flow keeps the pause until _hide_ui).
	if not _bg.visible and not _scroll.visible:
		process_mode = Node.PROCESS_MODE_INHERIT
		var tech_ui = get_node_or_null("/root/Main/TechTreeUI")
		if tech_ui == null or not tech_ui.is_open:
			get_tree().paused = false


## Opens just the detail overlay for `entry_id` without showing the
## main database grid. Used by the tech tree so clicking a researched
## node pops the entry over the tree instead of swapping screens.
func show_entry_detail_only(entry_id: StringName) -> void:
	for cat_key in categories:
		var cat = categories[cat_key]
		for entry in cat["list"]:
			if entry.id == entry_id:
				get_tree().paused = true
				process_mode = Node.PROCESS_MODE_ALWAYS
				_show_detail(entry, cat_key)
				return


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
	var produced_by: Array[BlockData] = []
	var used_in: Array[BlockData] = []
	var used_to_build: Array[BlockData] = []
	# Build a quick check: is this item the `minable_resource` of any
	# ore tile? Drills don't literally list "mat_copper" in their
	# output_items — they output 1 × whatever ore tile they're on — so
	# we have to consult the tile registry instead.
	var minable_from_floor: bool = false
	var minable_from_wall: bool = false
	for t in Registry.tiles_list:
		if t == null or t.minable_resource == &"":
			continue
		if not _key_matches_item(t.minable_resource, item.id):
			continue
		if t.tags.has("floor_ore"):
			minable_from_floor = true
		else:
			minable_from_wall = true
	for b in Registry.blocks_list:
		if b == null:
			continue
		# Direct output_items match (factories / arc furnaces etc.)
		var produces: bool = _dict_has_item(b.output_items, item.id)
		# Drill match — any non-wall-miner / non-geyser-miner extractor
		# whose miner-type lines up with where the ore is found. We
		# also honour the drill's `accepted_ores` whitelist so ground
		# scraper shows up under copper-mined-by-coal? No — under
		# coal/sulfur only; impact / earthquake / eruption show under
		# zinc_ore-derived items only.
		if not produces and b.category == BlockData.BlockCategory.EXTRACTORS:
			var has_whitelist: bool = b.accepted_ores.size() > 0
			var whitelist_match: bool = false
			if has_whitelist:
				for t in Registry.tiles_list:
					if t == null or t.minable_resource == &"":
						continue
					if not b.accepted_ores.has(t.id):
						continue
					if _key_matches_item(t.minable_resource, item.id):
						whitelist_match = true
						break
			if b.tags.has("floor_miner"):
				if has_whitelist:
					produces = whitelist_match
				elif minable_from_floor:
					produces = true
			elif not b.tags.has("wall_miner") and not b.tags.has("geyser_miner") \
					and not b.tags.has("floor_miner") and minable_from_wall:
				produces = true
		if produces:
			produced_by.append(b)
		var uses_input: bool = _dict_has_item(b.input_items, item.id)
		if not uses_input and b.boosters.size() > 0:
			for be in b.boosters:
				if typeof(be) == TYPE_DICTIONARY and _key_matches_item(be.get("item_id", &""), item.id):
					uses_input = true
					break
		if uses_input:
			used_in.append(b)
		if _dict_has_item(b.build_cost, item.id):
			used_to_build.append(b)
	_add_block_icon_grid("Produced By", produced_by)
	_add_block_icon_grid("Used In", used_in)
	_add_block_icon_grid("Used to Build", used_to_build)


## Returns true if `dict` has a key that refers to the given item id,
## allowing the "mat_*" prefix stored on items vs. the bare name used
## in build_cost / input_items / output_items.
func _dict_has_item(dict: Dictionary, item_id: StringName) -> bool:
	for k in dict.keys():
		if _key_matches_item(k, item_id):
			return true
	return false


func _key_matches_item(key, item_id: StringName) -> bool:
	var ks: String = str(key)
	var is_str: String = str(item_id)
	if ks == is_str:
		return true
	if "mat_" + ks == is_str:
		return true
	if ks == "mat_" + is_str:
		return true
	return false


func _show_block_details(block: BlockData) -> void:
	# --- Purpose ---
	if block.description != "":
		_add_section("Purpose")
		_add_text(block.description, text_color, 13)
		_add_separator()

	# --- General ---
	_add_section("General")
	_add_stat("Health", str(block.max_health), Color(0.4, 1.0, 0.4))
	if block.armor > 0.0:
		_add_stat("Armor", str(block.armor), Color(0.8, 0.8, 1.0))
	if block.health_regen > 0:
		_add_stat("Regen", "%s HP/sec" % str(block.health_regen), Color(0.4, 1.0, 0.4))
	_add_stat("Size", "%dx%d" % [block.grid_size.x, block.grid_size.y], text_color)
	if block.build_time > 0.0:
		_add_stat("Build Time", "%s seconds" % _fmt_num(block.build_time), text_color)
	if block.build_cost.size() > 0:
		_add_cost_row("Build Cost", block.build_cost)
	if block.max_active_units > 0:
		_add_stat("Max Active Units", "+%d" % block.max_active_units, Color(0.7, 0.95, 0.7))
	if block.storage_capacity > 0:
		_add_stat("Storage Capacity Bonus", "+%d" % block.storage_capacity, Color(0.7, 0.95, 0.7))

	# --- Liquids ---
	if block.liquid_capacity > 0.0:
		_add_separator()
		_add_section("Liquids")
		_add_stat_with_icon("Liquid Capacity", _DB_FLUID_ICON,
			"%s Fluid Units" % _fmt_num(block.liquid_capacity),
			Color(0.4, 0.7, 1.0))

	# --- Power ---
	var has_power_info: bool = block.electrical_power_use > 0.0 \
		or block.electrical_power_gen > 0.0 \
		or block.electrical_power_storage > 0.0
	if has_power_info:
		_add_separator()
		_add_section("Power")
		if block.electrical_power_use > 0.0:
			_add_stat_with_icon("Power Use", _DB_POWER_ICON,
				"%s power units/second" % _fmt_num(block.electrical_power_use),
				Color(1.0, 0.9, 0.3))
		if block.electrical_power_gen > 0.0:
			_add_stat_with_icon("Power Gen", _DB_POWER_ICON,
				"%s power units/second" % _fmt_num(block.electrical_power_gen),
				Color(0.5, 1.0, 0.5))
		if block.electrical_power_storage > 0.0:
			_add_stat_with_icon("Power Storage", _DB_POWER_ICON,
				"%s power-seconds" % _fmt_num(block.electrical_power_storage),
				Color(0.8, 0.8, 1.0))

	# --- Items section (storage capacity for factories etc.) ---
	if block.max_stored_items > 0 and (block.is_producer() or block.tags.has("core")):
		_add_separator()
		_add_section("Items")
		_add_stat("Item Capacity", "%d items" % block.max_stored_items, text_color)

	# --- Required Tiles (for pumps / wall crushers / condensers / geyser miners) ---
	var req_tiles: Array = _derive_required_tiles(block)
	if req_tiles.size() > 0:
		_add_separator()
		_add_section("Required Tiles")
		_add_required_tiles_row(req_tiles)

	# --- Input / Output ---
	if block.is_producer() or block.produced_unit != &"":
		_add_separator()
		_add_section("Input/Output")
		var cycle: float = block.production_time if block.production_time > 0.0 else 1.0
		# Fabricator with a produced unit: show output as the unit card.
		if block.produced_unit != &"":
			_add_text("Output:", dim_text_color, 13)
			var unit_data = Registry.get_unit(block.produced_unit)
			if unit_data:
				_add_unit_card(unit_data, "%s seconds" % _fmt_num(cycle))
			# Real inputs = the produced unit's build_cost (normalized to
			# "mat_*" runtime ids); falls back to block.input_items only
			# when the unit declares none. Without this, a fabricator's
			# .tres input_items had to be kept in sync with the unit's
			# recipe by hand — and they drift (e.g. tank fabricator listed
			# only copper while Press actually needs copper + silicon).
			var fab_recipe: Dictionary = {}
			if unit_data and not unit_data.build_cost.is_empty():
				fab_recipe = _normalize_mat_keys(unit_data.build_cost)
			else:
				fab_recipe = block.input_items
			if fab_recipe.size() > 0:
				_add_text("Inputs:", dim_text_color, 13)
				for item_id in fab_recipe:
					var amt: int = int(fab_recipe[item_id])
					var rate: float = amt / cycle
					_add_item_card(item_id, amt, "%s/sec" % _fmt_num(rate))
		else:
			if block.input_items.size() > 0:
				_add_text("Input:", dim_text_color, 13)
				for item_id in block.input_items:
					var amt: int = int(block.input_items[item_id])
					var rate: float = amt / cycle
					_add_item_card(item_id, amt, "%s/sec" % _fmt_num(rate))
			# Skip output entries whose id isn't a real item/fluid — old
			# drill .tres files used "ore" as a placeholder key that
			# never resolves to a registered item and would render as a
			# bogus "ore" row in the database.
			var real_outputs: Dictionary = {}
			for raw_id in block.output_items:
				if Registry.get_item_or_fluid(StringName(raw_id)) != null:
					real_outputs[raw_id] = block.output_items[raw_id]
			if real_outputs.size() > 0:
				_add_text("Output:", dim_text_color, 13)
				for item_id in real_outputs:
					var amt: int = int(real_outputs[item_id])
					var rate: float = amt / cycle
					_add_item_card(item_id, amt, "%s/sec" % _fmt_num(rate))
		_add_stat("Production Time", "%s seconds" % _fmt_num(cycle), text_color)

	# --- Function: turret combat info ---
	if block.is_turret():
		_add_separator()
		_add_section("Function")
		_add_stat("Range", "%s blocks" % _fmt_num(block.attack_range), Color(0.4, 0.7, 1.0))
		_add_stat("Inaccuracy", "%s degrees" % _fmt_num(block.inaccuracy), text_color)
		if block.bullet_spread > 0.0:
			_add_stat("Bullet Spread", "%s degrees" % _fmt_num(block.bullet_spread), text_color)
		var rate: float = (1.0 / block.attack_speed) if block.attack_speed > 0.0 else 0.0
		_add_stat("Firing Rate", "%s/sec" % _fmt_num(rate), Color(1.0, 0.8, 0.3))
		_add_stat("Targets Air", "Yes" if block.targets_air else "No",
			Color(0.5, 1.0, 0.5) if block.targets_air else Color(1.0, 0.5, 0.5))
		_add_stat("Targets Ground", "Yes" if block.targets_ground else "No",
			Color(0.5, 1.0, 0.5) if block.targets_ground else Color(1.0, 0.5, 0.5))
		if block.is_aoe and block.aoe_radius > 0.0:
			_add_stat("AoE Radius", "%s px" % _fmt_num(block.aoe_radius), Color(1.0, 0.6, 0.3))

		# Ammo cards
		if block.ammo_types.size() > 0:
			_add_text("Ammo:", dim_text_color, 13)
			for ammo_res in block.ammo_types:
				if ammo_res == null or not (ammo_res is AmmoType):
					continue
				_add_ammo_card(block, ammo_res as AmmoType)
		else:
			_add_text("Requires ammo to fire — none configured.", Color(1.0, 0.5, 0.4), 12)

		if block.ammo_capacity > 0:
			_add_stat("Ammo Capacity", "%d shots" % block.ammo_capacity, text_color)
		var max_ammo_use: int = 1
		for ammo_res2 in block.ammo_types:
			if ammo_res2 is AmmoType:
				max_ammo_use = maxi(max_ammo_use, (ammo_res2 as AmmoType).amount_per_shot)
		if max_ammo_use > 1:
			_add_stat("Ammo Use", "%d/shot" % max_ammo_use, text_color)

	# --- Transport ---
	if block.is_transport():
		_add_separator()
		_add_section("Transport")
		_add_stat("Speed", "%s items/sec" % _fmt_num(block.transport_speed), text_color)
		_add_stat("Fluids", "Yes" if block.transports_fluid else "No", text_color)

	# --- Mining range (for drills) + drillables list ---
	if block.category == BlockData.BlockCategory.EXTRACTORS:
		if block.mine_range > 0:
			_add_separator()
			_add_section("Mining")
			_add_stat("Mine Range", "%d tiles ahead" % block.mine_range, Color(0.7, 0.95, 0.7))
		_add_drillables_section(block)

	# --- Refabricator / upgrader unit-conversion map ---
	# For any block with the `refabricator` tag (or an explicit
	# refab_recipes table), list every supported T1 → T2 conversion.
	# Per-T2 overrides come from refab_recipes; missing entries fall
	# back to block.input_items, matching the runtime
	# `_refab_effective_recipe` helper. Without this fallback the unit
	# refabricator showed nothing because its .tres only set a global
	# input_items and left refab_recipes empty.
	var is_refab: bool = block.tags.has("refabricator") or block.refab_recipes.size() > 0
	if is_refab:
		# T1 = unit with NO unit parent (root of a unit chain). T2 =
		# unit whose first unit-parent is a T1. The Unit Refabricator
		# only handles T1 → T2 conversions, so we explicitly filter to
		# that tier rather than listing every unit-with-a-unit-parent
		# (which would also catch T2 → T3 upgrades that belong to a
		# higher-tier refabricator).
		var is_unit_node := func(nid) -> bool:
			return Registry.get_unit(nid) != null
		var is_tier1_unit := func(nid) -> bool:
			if not is_unit_node.call(nid):
				return false
			var pts: Array = TechTree.nodes.get(nid, {}).get("parents", [])
			for pid in pts:
				if is_unit_node.call(pid):
					return false
			return true
		var t2_targets: Array = []
		for node_id in TechTree.nodes:
			var u = Registry.get_unit(node_id)
			if u == null:
				continue
			var parents_arr: Array = TechTree.nodes[node_id].get("parents", [])
			for parent_id in parents_arr:
				if is_tier1_unit.call(parent_id):
					t2_targets.append({"t2": node_id, "t1": parent_id})
					break
		# Merge in any explicit refab_recipes keys that aren't already
		# represented by the tech-tree walk.
		for out_id in block.refab_recipes.keys():
			var dup := false
			for entry in t2_targets:
				if StringName(entry["t2"]) == StringName(out_id):
					dup = true
					break
			if not dup:
				t2_targets.append({"t2": StringName(out_id), "t1": block.produced_unit})
		if not t2_targets.is_empty():
			_add_separator()
			_add_section("Unit Upgrades")
			var cycle_r: float = block.production_time if block.production_time > 0.0 else 1.0
			for entry in t2_targets:
				var t2_id: StringName = StringName(entry["t2"])
				var t1_id: StringName = StringName(entry["t1"])
				var t2_u = Registry.get_unit(t2_id)
				var t1_u = Registry.get_unit(t1_id) if t1_id != &"" else null
				if t2_u == null:
					continue
				_add_unit_conversion_row(t1_u, t2_u)
				# Materials: per-T2 override, else block.input_items.
				var recipe: Dictionary = {}
				if block.refab_recipes.has(t2_id):
					var r = block.refab_recipes[t2_id]
					if r is Dictionary and not r.is_empty():
						recipe = r
				if recipe.is_empty():
					recipe = block.input_items
				for item_id in recipe:
					var amt: int = int(recipe[item_id])
					var rate: float = amt / cycle_r
					_add_item_card(item_id, amt, "%s/sec" % _fmt_num(rate))

	# --- Core-specific spawned unit ---
	if block.spawned_unit != &"":
		_add_separator()
		_add_section("Unit Type")
		var spawn_data = Registry.get_unit(block.spawned_unit)
		if spawn_data:
			_add_unit_card(spawn_data, "")

	# --- Optional Enhancements (Boosters) ---
	if block.boosters.size() > 0:
		_add_separator()
		_add_section("Optional Enhancements")
		_add_text("Booster:", dim_text_color, 13)
		for entry in block.boosters:
			if typeof(entry) == TYPE_DICTIONARY:
				_add_booster_card(entry)
			elif entry is BlockData:
				_add_block_card(entry)


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

	# Mindustry-style "Produced By" / "Upgraded By" icon grids.
	var produced_by: Array[BlockData] = []
	var upgraded_by: Array[BlockData] = []
	var _upgrades_into: Array[UnitData] = []
	for b in Registry.blocks_list:
		if b == null:
			continue
		if b.produced_unit == unit.id:
			produced_by.append(b)
		if b.refab_recipes.size() > 0 and b.refab_recipes.has(unit.id):
			# This block can upgrade INTO `unit`. The block's
			# produced_unit / parent unit is the "from".
			upgraded_by.append(b)
	_add_block_icon_grid("Produced By", produced_by)
	_add_block_icon_grid("Upgraded By", upgraded_by)


func _show_fluid_details(fluid: FluidData) -> void:
	var produced_by: Array[BlockData] = []
	var used_in: Array[BlockData] = []
	for b in Registry.blocks_list:
		if b == null:
			continue
		if _dict_has_item(b.output_items, fluid.id):
			produced_by.append(b)
		var uses_input: bool = _dict_has_item(b.input_items, fluid.id)
		if not uses_input and b.boosters.size() > 0:
			for be in b.boosters:
				if typeof(be) == TYPE_DICTIONARY and _key_matches_item(be.get("item_id", &""), fluid.id):
					uses_input = true
					break
		if uses_input:
			used_in.append(b)
	_add_block_icon_grid("Produced By", produced_by)
	_add_block_icon_grid("Used In", used_in)


func _show_status_effect_details(effect: StatusEffectData) -> void:
	# --- Multipliers / Damage (Mindustry-style headline stats) ---
	var hm: float = effect.get_health_multiplier() if effect.has_method("get_health_multiplier") else 1.0
	if hm != 1.0:
		var hm_color: Color = Color(1.0, 0.45, 0.45) if hm < 1.0 else Color(0.45, 1.0, 0.55)
		_add_stat("Health Multiplier", "%sx" % _fmt_num(hm), hm_color)
	if effect.speed_modifier != 1.0:
		var sm_color: Color = Color(1.0, 0.45, 0.45) if effect.speed_modifier < 1.0 else Color(0.45, 1.0, 0.55)
		_add_stat("Speed Multiplier", "%sx" % _fmt_num(effect.speed_modifier), sm_color)
	if effect.damage_modifier != 1.0:
		var dm_color: Color = Color(0.45, 1.0, 0.55) if effect.damage_modifier < 1.0 else Color(1.0, 0.45, 0.45)
		_add_stat("Damage Multiplier", "%sx" % _fmt_num(effect.damage_modifier), dm_color)
	if effect.attack_speed_modifier != 1.0:
		var asm_color: Color = Color(1.0, 0.45, 0.45) if effect.attack_speed_modifier < 1.0 else Color(0.45, 1.0, 0.55)
		_add_stat("Attack Speed Mult.", "%sx" % _fmt_num(effect.attack_speed_modifier), asm_color)
	if effect.production_modifier != 1.0:
		var pm_color: Color = Color(1.0, 0.45, 0.45) if effect.production_modifier < 1.0 else Color(0.45, 1.0, 0.55)
		_add_stat("Production Mult.", "%sx" % _fmt_num(effect.production_modifier), pm_color)
	if effect.has_dot() and effect.tick_interval > 0.0:
		var dps: float = effect.tick_damage / effect.tick_interval
		_add_stat("Damage", "%s/sec" % _fmt_num(dps), Color(1.0, 0.45, 0.35))
	elif effect.has_hot() and effect.tick_interval > 0.0:
		var hps: float = absf(effect.tick_damage) / effect.tick_interval
		_add_stat("Heal", "%s/sec" % _fmt_num(hps), Color(0.45, 1.0, 0.55))

	# --- Affinities ---
	if effect.affinities.size() > 0:
		_add_status_id_row("Affinities", effect.affinities, Color(0.7, 0.95, 0.7))
	# --- Opposites ---
	if effect.opposites.size() > 0:
		_add_status_id_row("Opposites", effect.opposites, Color(0.55, 0.8, 1.0))

	_add_separator()
	_add_section("Properties")
	_add_stat("Type", _effect_type_name(effect.effect_type), text_color)
	_add_stat("Duration", "%ss" % str(effect.duration) if effect.duration > 0 else "Permanent", text_color)
	_add_stat("Stackable", "Yes (max %d)" % effect.max_stacks if effect.stackable else "No", text_color)
	_add_stat("Refreshes", "Yes" if effect.refresh_on_reapply else "No", text_color)

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

# =========================
# UI HELPER WIDGETS
# =========================

func _add_header_with_icon(entry: Resource, color: Color) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	if "icon" in entry and entry.icon:
		var ir = TextureRect.new()
		ir.texture = entry.icon
		ir.custom_minimum_size = Vector2(32, 32)
		ir.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		hbox.add_child(ir)
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", -2)
	var name_lbl = Label.new()
	name_lbl.text = entry.display_name if "display_name" in entry else ""
	name_lbl.add_theme_font_size_override("font_size", 20)
	name_lbl.add_theme_color_override("font_color", color)
	vbox.add_child(name_lbl)
	if "id" in entry:
		var id_lbl = Label.new()
		id_lbl.text = str(entry.id).replace("_", "-")
		id_lbl.add_theme_font_size_override("font_size", 12)
		id_lbl.add_theme_color_override("font_color", dim_text_color)
		vbox.add_child(id_lbl)
	hbox.add_child(vbox)
	_detail_container.add_child(hbox)


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


## Like _add_stat, but with a small icon between the label and the
## value text. Used for things like "Power Use: [PowerIcon] 4/sec"
## and "Liquid Capacity: [FluidIcon] 30 Fluid Units" so the player
## can recognise the resource at a glance instead of reading an
## emoji.
func _add_stat_with_icon(label_text: String, icon: Texture2D, value_text: String, value_color: Color) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var label = Label.new()
	label.text = label_text + ":"
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", dim_text_color)
	label.custom_minimum_size.x = 140
	hbox.add_child(label)

	if icon:
		var ir = TextureRect.new()
		ir.texture = icon
		ir.custom_minimum_size = Vector2(18, 18)
		ir.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		hbox.add_child(ir)

	var value = Label.new()
	value.text = value_text
	value.add_theme_font_size_override("font_size", 14)
	value.add_theme_color_override("font_color", value_color)
	hbox.add_child(value)

	_detail_container.add_child(hbox)


const _DB_POWER_ICON: Texture2D = preload("res://textures/UI/PowerIcon.png")
const _DB_FLUID_ICON: Texture2D = preload("res://textures/UI/FluidIcon.png")


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






func _add_separator() -> void:
	var sep = HSeparator.new()
	sep.add_theme_constant_override("separation", 8)
	sep.add_theme_stylebox_override("separator", StyleBoxLine.new())
	_detail_container.add_child(sep)


## Formats a number cleanly: trims trailing zeros and decimal points,
## so 1.250 renders as "1.25", 4.000 as "4", etc. Matches the
## Mindustry-style display in the screenshots.
func _fmt_num(v: float) -> String:
	if absf(v - roundf(v)) < 0.0001:
		return str(int(roundf(v)))
	var s: String = "%.3f" % v
	while s.ends_with("0"):
		s = s.substr(0, s.length() - 1)
	if s.ends_with("."):
		s = s.substr(0, s.length() - 1)
	return s


## Inline build-cost row: "Label: [icon1][num1] [icon2][num2] ...".
## Used by the General section so the cost shows as a single
## horizontal strip of resource icons + amounts.
func _add_cost_row(label_text: String, cost: Dictionary) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var label = Label.new()
	label.text = label_text + ":"
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", dim_text_color)
	label.custom_minimum_size.x = 140
	hbox.add_child(label)
	for item_id in cost:
		var entry = HBoxContainer.new()
		entry.add_theme_constant_override("separation", 2)
		# Block.build_cost stores short keys like "copper" / "graphite",
		# but the Registry uses the runtime item ids ("mat_copper" /
		# "mat_graphite"). Try the raw key first, then fall back to the
		# `mat_`-prefixed name so the icon actually resolves.
		var item = Registry.get_item_or_fluid(item_id)
		if item == null:
			var s := String(item_id)
			if not s.begins_with("mat_"):
				item = Registry.get_item_or_fluid(StringName("mat_" + s))
		if item and item.icon:
			var ir = TextureRect.new()
			ir.texture = item.icon
			ir.custom_minimum_size = Vector2(20, 20)
			ir.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			entry.add_child(ir)
		var amt_lbl = Label.new()
		amt_lbl.text = _fmt_amount(int(cost[item_id]))
		amt_lbl.add_theme_font_size_override("font_size", 14)
		amt_lbl.add_theme_color_override("font_color", item.color if item else text_color)
		entry.add_child(amt_lbl)
		hbox.add_child(entry)
	_detail_container.add_child(hbox)


## Normalises a build-cost-style key ("copper") to the runtime item id
## ("mat_copper") so the produced unit's build_cost dict reads as the
## same item ids the conveyor system uses. Mirrors
## `LogisticsSystem._normalize_item_keys` but lives here so the
## database UI doesn't have to reach into Logistics just for this.
func _normalize_mat_keys(d: Dictionary) -> Dictionary:
	var out := {}
	for raw_id in d:
		var s := String(raw_id)
		var normalized: String = s if s.begins_with("mat_") else "mat_" + s
		# If "mat_<name>" isn't a real item but the raw key is, keep
		# the raw key (lets non-material inputs pass through).
		if Registry.get_item_or_fluid(StringName(normalized)) == null \
				and Registry.get_item_or_fluid(StringName(s)) != null:
			normalized = s
		out[StringName(normalized)] = d[raw_id]
	return out


## "Card" widget: a horizontal panel showing an item icon + name +
## per-cycle amount + rate per second. Used in Input/Output sections.
func _add_item_card(item_id, amount: int, rate_text: String) -> void:
	var card = PanelContainer.new()
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.16, 0.85)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	card.add_theme_stylebox_override("panel", sb)
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	card.add_child(hbox)
	var item = Registry.get_item_or_fluid(item_id)
	if item and item.icon:
		var ir = TextureRect.new()
		ir.texture = item.icon
		ir.custom_minimum_size = Vector2(22, 22)
		ir.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		hbox.add_child(ir)
	var name_lbl = Label.new()
	name_lbl.text = item.display_name if item else str(item_id)
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", item.color if item else text_color)
	hbox.add_child(name_lbl)
	var amt_lbl = Label.new()
	amt_lbl.text = "  %d" % amount
	amt_lbl.add_theme_font_size_override("font_size", 14)
	amt_lbl.add_theme_color_override("font_color", Color(0.95, 0.85, 0.4))
	hbox.add_child(amt_lbl)
	if rate_text != "":
		var rate_lbl = Label.new()
		rate_lbl.text = "  %s" % rate_text
		rate_lbl.add_theme_font_size_override("font_size", 13)
		rate_lbl.add_theme_color_override("font_color", dim_text_color)
		hbox.add_child(rate_lbl)
	_detail_container.add_child(card)


## Card showing a unit (icon + display name + subtitle).
func _add_unit_card(unit: UnitData, subtitle_text: String) -> void:
	var card = PanelContainer.new()
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.16, 0.85)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	card.add_theme_stylebox_override("panel", sb)
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	card.add_child(hbox)
	if "icon" in unit and unit.icon:
		var ir = TextureRect.new()
		ir.texture = unit.icon
		ir.custom_minimum_size = Vector2(24, 24)
		ir.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		hbox.add_child(ir)
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	var name_lbl = Label.new()
	name_lbl.text = unit.display_name
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", text_color)
	vbox.add_child(name_lbl)
	if subtitle_text != "":
		var sub_lbl = Label.new()
		sub_lbl.text = subtitle_text
		sub_lbl.add_theme_font_size_override("font_size", 12)
		sub_lbl.add_theme_color_override("font_color", dim_text_color)
		vbox.add_child(sub_lbl)
	hbox.add_child(vbox)
	_detail_container.add_child(card)


## Card showing another block (icon + display name + ID subtitle).
func _add_block_card(block: BlockData) -> void:
	var card = PanelContainer.new()
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.16, 0.85)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	card.add_theme_stylebox_override("panel", sb)
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	card.add_child(hbox)
	if block.icon:
		var ir = TextureRect.new()
		ir.texture = block.icon
		ir.custom_minimum_size = Vector2(24, 24)
		ir.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		hbox.add_child(ir)
	var vbox = VBoxContainer.new()
	var name_lbl = Label.new()
	name_lbl.text = block.display_name
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", text_color)
	vbox.add_child(name_lbl)
	var id_lbl = Label.new()
	id_lbl.text = str(block.id)
	id_lbl.add_theme_font_size_override("font_size", 12)
	id_lbl.add_theme_color_override("font_color", dim_text_color)
	vbox.add_child(id_lbl)
	hbox.add_child(vbox)
	_detail_container.add_child(card)


## Inline status-effect ID row: "Affinities: [icon Name][icon Name]"
## — used for Affinities / Opposites on a status-effect detail page.
func _add_status_id_row(label_text: String, status_ids: Array, color: Color) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var label = Label.new()
	label.text = label_text + ":"
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", dim_text_color)
	label.custom_minimum_size.x = 140
	hbox.add_child(label)
	for sid in status_ids:
		var entry = HBoxContainer.new()
		entry.add_theme_constant_override("separation", 4)
		var sd: StatusEffectData = null
		if Registry.has_method("get_status_effect"):
			sd = Registry.get_status_effect(StringName(sid))
		if sd and sd.icon:
			var ir = TextureRect.new()
			ir.texture = sd.icon
			ir.custom_minimum_size = Vector2(18, 18)
			ir.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			entry.add_child(ir)
		var name_lbl = Label.new()
		name_lbl.text = sd.display_name if sd else str(sid)
		name_lbl.add_theme_font_size_override("font_size", 14)
		name_lbl.add_theme_color_override("font_color", color)
		entry.add_child(name_lbl)
		hbox.add_child(entry)
	_detail_container.add_child(hbox)


## Returns the implied required-tile list for a block, combining the
## explicit `required_tiles` data field with auto-derivation from tags.
## Each entry is {tile_id, efficiency, label?}.
func _derive_required_tiles(block: BlockData) -> Array:
	var out: Array = []
	for entry in block.required_tiles:
		if typeof(entry) == TYPE_DICTIONARY:
			out.append(entry)
	# Auto-derivation:
	if block.tags.has("condenser"):
		# Vent → 0.5x rate (4/s), Geyser → 1.0x (8/s).
		out.append({"tile_id": &"vent", "efficiency": 0.5})
		out.append({"tile_id": &"geyser", "efficiency": 1.0})
	elif block.tags.has("pump"):
		# Pumps scale rate with water_depth (the block places ON water
		# floors with water_depth > 0). Show the three depth tiers.
		out.append({"tile_id": &"water_shallow", "efficiency": 0.5, "label": "shallow"})
		out.append({"tile_id": &"water_mid", "efficiency": 1.0, "label": "mid"})
		out.append({"tile_id": &"water_deep", "efficiency": 1.5, "label": "deep"})
	elif block.tags.has("geyser_miner"):
		out.append({"tile_id": &"geyser", "efficiency": 1.0})
	elif block.tags.has("vent_powered") or block.tags.has("vent_turbine"):
		out.append({"tile_id": &"vent", "efficiency": 1.0})
	elif block.tags.has("wall_miner"):
		var walls: Array = block.accepted_walls if block.accepted_walls.size() > 0 else [&"blackstone_wall"]
		for w in walls:
			out.append({"tile_id": w, "efficiency": 1.0})
	return out


## Row of tile-icon cards with their efficiency multiplier underneath.
## Per the user's rule: efficiency ≤ 100% renders yellow, > 100% red.
func _add_required_tiles_row(entries: Array) -> void:
	var flow = HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	for entry in entries:
		var tile_id: StringName = StringName(entry.get("tile_id", &""))
		var eff: float = float(entry.get("efficiency", 1.0))
		var tile = null
		if Registry.has_method("get_tile"):
			tile = Registry.get_tile(tile_id)
		var card = PanelContainer.new()
		var sb = StyleBoxFlat.new()
		sb.bg_color = Color(0.12, 0.13, 0.16, 0.85)
		sb.set_corner_radius_all(6)
		sb.content_margin_left = 6
		sb.content_margin_right = 6
		sb.content_margin_top = 4
		sb.content_margin_bottom = 4
		card.add_theme_stylebox_override("panel", sb)
		var vbox = VBoxContainer.new()
		vbox.add_theme_constant_override("separation", 2)
		card.add_child(vbox)
		var top_row = HBoxContainer.new()
		top_row.add_theme_constant_override("separation", 6)
		if tile and tile.icon:
			var tr = TextureRect.new()
			tr.texture = tile.icon
			tr.custom_minimum_size = Vector2(24, 24)
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			top_row.add_child(tr)
		var name_lbl = Label.new()
		var fallback_name: String = String(entry.get("label", ""))
		if fallback_name == "":
			fallback_name = tile.get_display_name() if (tile and tile.has_method("get_display_name")) else str(tile_id).replace("_", " ").capitalize()
		name_lbl.text = fallback_name
		name_lbl.add_theme_font_size_override("font_size", 13)
		name_lbl.add_theme_color_override("font_color", text_color)
		top_row.add_child(name_lbl)
		vbox.add_child(top_row)
		var pct: int = int(round(eff * 100.0))
		# Coloring: ≥100% reads as yellow (baseline / boosted), <100%
		# reads as red (penalty), matching the pump-depth example.
		var pct_color: Color = Color(0.95, 0.82, 0.25) if pct >= 100 else Color(1.0, 0.45, 0.35)
		var pct_lbl = Label.new()
		pct_lbl.text = "%d%%" % pct
		pct_lbl.add_theme_font_size_override("font_size", 13)
		pct_lbl.add_theme_color_override("font_color", pct_color)
		vbox.add_child(pct_lbl)
		flow.add_child(card)
	_detail_container.add_child(flow)


## Lists every ore tile the drill can mine, with its display name and
## the output item icon underneath. Shown as a two-column grid of
## cards. Skips floor miners' floor-ore-only filter / wall miners'
## blackstone-wall filter properly via _ore_is_minable_by-style logic.
func _add_drillables_section(block: BlockData) -> void:
	if block.tags.has("wall_miner") or block.tags.has("geyser_miner"):
		return  # Wall crushers / geyser miners have a different output spec.
	var is_floor_miner: bool = block.tags.has("floor_miner")
	var drillables: Array = []  # of {tile: TerrainTileData, item_id: StringName}
	for tile in Registry.tiles_list:
		if tile == null or tile.minable_resource == &"":
			continue
		var is_floor_ore: bool = tile.tags.has("floor_ore")
		if is_floor_miner and not is_floor_ore:
			continue
		if not is_floor_miner and is_floor_ore:
			continue
		# Honour the block's accepted_ores whitelist so a ground scraper
		# only lists coal + sulfur, not every floor ore.
		if block.accepted_ores.size() > 0 and not block.accepted_ores.has(tile.id):
			continue
		drillables.append({"tile": tile, "item_id": tile.minable_resource})
	if drillables.is_empty():
		return
	_add_separator()
	_add_section("Drillables")
	var rate: float = 1.0 / maxf(block.production_time, 0.0001)
	# Render as a HFlowContainer of cards. Each card shows the tile
	# icon + name + the output item icon underneath.
	var flow = HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	for d in drillables:
		var tile: TerrainTileData = d["tile"]
		var iid: StringName = StringName(d["item_id"])
		var item = Registry.get_item_or_fluid(iid)
		var card = PanelContainer.new()
		var sb = StyleBoxFlat.new()
		sb.bg_color = Color(0.12, 0.13, 0.16, 0.85)
		sb.set_corner_radius_all(6)
		sb.content_margin_left = 6
		sb.content_margin_right = 6
		sb.content_margin_top = 4
		sb.content_margin_bottom = 4
		card.add_theme_stylebox_override("panel", sb)
		card.custom_minimum_size = Vector2(180, 0)
		var row = HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		card.add_child(row)
		if tile.icon:
			var tr = TextureRect.new()
			tr.texture = tile.icon
			tr.custom_minimum_size = Vector2(28, 28)
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			row.add_child(tr)
		var vbox = VBoxContainer.new()
		vbox.add_theme_constant_override("separation", -2)
		var name_lbl = Label.new()
		name_lbl.text = tile.get_display_name() if tile.has_method("get_display_name") else str(tile.id)
		name_lbl.add_theme_font_size_override("font_size", 13)
		name_lbl.add_theme_color_override("font_color", text_color)
		vbox.add_child(name_lbl)
		var out_row = HBoxContainer.new()
		out_row.add_theme_constant_override("separation", 4)
		if item and item.icon:
			var oir = TextureRect.new()
			oir.texture = item.icon
			oir.custom_minimum_size = Vector2(16, 16)
			oir.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			oir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			out_row.add_child(oir)
		var rate_lbl = Label.new()
		rate_lbl.text = "%s/sec" % _fmt_num(rate)
		rate_lbl.add_theme_font_size_override("font_size", 12)
		rate_lbl.add_theme_color_override("font_color", dim_text_color)
		out_row.add_child(rate_lbl)
		vbox.add_child(out_row)
		row.add_child(vbox)
		flow.add_child(card)
	_detail_container.add_child(flow)


## Unit conversion row: shows `input_unit → output_unit` cards.
func _add_unit_conversion_row(in_unit: UnitData, out_unit: UnitData) -> void:
	if in_unit == null and out_unit == null:
		return
	var card = PanelContainer.new()
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.16, 0.85)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	card.add_theme_stylebox_override("panel", sb)
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	card.add_child(row)
	if in_unit and in_unit.icon:
		var ir = TextureRect.new()
		ir.texture = in_unit.icon
		ir.custom_minimum_size = Vector2(24, 24)
		ir.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(ir)
	if in_unit:
		var nl = Label.new()
		nl.text = in_unit.display_name
		nl.add_theme_font_size_override("font_size", 13)
		nl.add_theme_color_override("font_color", text_color)
		row.add_child(nl)
	var arrow = Label.new()
	arrow.text = "→"
	arrow.add_theme_font_size_override("font_size", 16)
	arrow.add_theme_color_override("font_color", accent_color)
	row.add_child(arrow)
	if out_unit and out_unit.icon:
		var ir2 = TextureRect.new()
		ir2.texture = out_unit.icon
		ir2.custom_minimum_size = Vector2(24, 24)
		ir2.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ir2.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(ir2)
	if out_unit:
		var nl2 = Label.new()
		nl2.text = out_unit.display_name
		nl2.add_theme_font_size_override("font_size", 13)
		nl2.add_theme_color_override("font_color", text_color)
		row.add_child(nl2)
	_detail_container.add_child(card)


## Mindustry-style icon grid for "Produced By / Used In / Used to
## Build" sections — wraps a row of clickable block icons under a
## section header. Locked entries show a LockIcon instead of the block
## icon and are non-interactive; unlocked entries open that block's
## detail when clicked.
func _add_block_icon_grid(label_text: String, blocks: Array) -> void:
	if blocks.is_empty():
		return
	_add_separator()
	_add_section(label_text)
	var flow = HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	for b in blocks:
		if b == null:
			continue
		var locked: bool = "id" in b and TechTree.nodes.has(b.id) and not TechTree.is_researched(b.id)
		var btn = Button.new()
		btn.flat = true
		btn.custom_minimum_size = Vector2(32, 32)
		btn.focus_mode = Control.FOCUS_NONE
		btn.tooltip_text = ("Locked" if locked else (b.display_name if "display_name" in b else ""))
		# Render the icon as a child TextureRect so non-square textures
		# (LockIcon is 320×443) keep their aspect instead of being
		# squashed by the button's `expand_icon` stretch.
		var tex: Texture2D = _lock_icon if locked else (b.icon if ("icon" in b and b.icon) else null)
		if tex != null:
			var ir = TextureRect.new()
			ir.texture = tex
			ir.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			ir.anchor_right = 1.0
			ir.anchor_bottom = 1.0
			ir.offset_left = 3
			ir.offset_right = -3
			ir.offset_top = 3
			ir.offset_bottom = -3
			ir.mouse_filter = Control.MOUSE_FILTER_IGNORE
			btn.add_child(ir)
		# Only unlocked entries open the detail panel on click; locked
		# ones swallow the input so nothing happens.
		if not locked:
			btn.pressed.connect(_show_detail.bind(b, "blocks"))
		flow.add_child(btn)
	_detail_container.add_child(flow)


## Booster card: large pill showing the consumed item/fluid + rate on
## the left, and the boost it grants on the right (e.g. "Fire Rate +150%").
## Matches the Mindustry image's "Water 15/sec  250% Fire Rate" layout.
func _add_booster_card(entry: Dictionary) -> void:
	var card = PanelContainer.new()
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.16, 0.92)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	card.add_theme_stylebox_override("panel", sb)
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	card.add_child(hbox)
	# Left: item icon + name + rate
	var left = HBoxContainer.new()
	left.add_theme_constant_override("separation", 6)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var iid = StringName(entry.get("item_id", &""))
	var item = Registry.get_item_or_fluid(iid)
	if item and item.icon:
		var ir = TextureRect.new()
		ir.texture = item.icon
		ir.custom_minimum_size = Vector2(22, 22)
		ir.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		left.add_child(ir)
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", -2)
	var name_lbl = Label.new()
	name_lbl.text = item.display_name if item else str(iid)
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", item.color if item else text_color)
	vbox.add_child(name_lbl)
	var rate_lbl = Label.new()
	rate_lbl.text = "%s/sec" % _fmt_num(float(entry.get("per_sec", 0.0)))
	rate_lbl.add_theme_font_size_override("font_size", 12)
	rate_lbl.add_theme_color_override("font_color", dim_text_color)
	vbox.add_child(rate_lbl)
	left.add_child(vbox)
	hbox.add_child(left)
	# Right: stat + boost percent
	var stat: String = String(entry.get("stat", "Boost"))
	var mult: float = float(entry.get("multiplier", 1.0))
	var pct: int = int(round(mult * 100.0))
	var right_lbl = Label.new()
	right_lbl.text = "%d%% %s" % [pct, stat]
	right_lbl.add_theme_font_size_override("font_size", 14)
	right_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	hbox.add_child(right_lbl)
	_detail_container.add_child(card)


## Compact formatter: 1500 → "1.5k", 1000000 → "1.0M".
func _fmt_amount(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (n / 1000000.0)
	if n >= 1000:
		return "%.1fk" % (n / 1000.0)
	return str(n)


## Mindustry-style ammo card: ammo icon + name as header, then
## damage / vs-buildings / knockback / homing / ammo-per-shot in a
## tidy block. Replaces the older _add_ammo_entry for the new layout.
func _add_ammo_card(_turret: BlockData, ammo: AmmoType) -> void:
	# Outer card panel
	var card = PanelContainer.new()
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.16, 0.92)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	card.add_theme_stylebox_override("panel", sb)
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	card.add_child(vbox)

	# Header: ammo icon + display name
	var item = Registry.get_item_or_fluid(ammo.item_id)
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	if item and item.icon:
		var ir = TextureRect.new()
		ir.texture = item.icon
		ir.custom_minimum_size = Vector2(20, 20)
		ir.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		header.add_child(ir)
	var hname = Label.new()
	hname.text = item.display_name if item else str(ammo.item_id)
	hname.add_theme_font_size_override("font_size", 15)
	hname.add_theme_color_override("font_color", text_color)
	header.add_child(hname)
	vbox.add_child(header)

	# Damage
	var dmg_lbl = Label.new()
	dmg_lbl.text = "%s damage" % _fmt_num(ammo.damage)
	dmg_lbl.add_theme_font_size_override("font_size", 13)
	dmg_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	vbox.add_child(dmg_lbl)
	# vs Buildings — show as "-NN% building damage" if reduction
	if ammo.building_damage_mult != 1.0:
		var bldg_pct: int = int(round((ammo.building_damage_mult - 1.0) * 100.0))
		var sign: String = "+" if bldg_pct > 0 else ""
		var bldg_color: Color = Color(1.0, 0.45, 0.35) if bldg_pct < 0 else Color(0.45, 1.0, 0.55)
		var bdmg = Label.new()
		bdmg.text = "%s%d%% building damage" % [sign, bldg_pct]
		bdmg.add_theme_font_size_override("font_size", 13)
		bdmg.add_theme_color_override("font_color", bldg_color)
		vbox.add_child(bdmg)
	if ammo.unit_damage_mult != 1.0:
		var unit_pct: int = int(round((ammo.unit_damage_mult - 1.0) * 100.0))
		var usign: String = "+" if unit_pct > 0 else ""
		var ucolor: Color = Color(1.0, 0.45, 0.35) if unit_pct < 0 else Color(0.45, 1.0, 0.55)
		var ud = Label.new()
		ud.text = "%s%d%% unit damage" % [usign, unit_pct]
		ud.add_theme_font_size_override("font_size", 13)
		ud.add_theme_color_override("font_color", ucolor)
		vbox.add_child(ud)
	# Knockback
	if ammo.knockback > 0.0:
		var kb = Label.new()
		kb.text = "%s knockback" % _fmt_num(ammo.knockback / 48.0)
		kb.add_theme_font_size_override("font_size", 13)
		kb.add_theme_color_override("font_color", Color(0.9, 0.8, 0.5))
		vbox.add_child(kb)
	# Per-shot ammo cost
	if ammo.amount_per_shot > 1:
		var ap = Label.new()
		ap.text = "%d ammo/item" % ammo.amount_per_shot
		ap.add_theme_font_size_override("font_size", 13)
		ap.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
		vbox.add_child(ap)
	# Pierce
	if ammo.pierce_count > 0:
		var p = Label.new()
		p.text = "pierces %d targets" % ammo.pierce_count
		p.add_theme_font_size_override("font_size", 13)
		p.add_theme_color_override("font_color", Color(0.9, 0.6, 0.9))
		vbox.add_child(p)
	# Homing flag (Mindustry shows literally "homing")
	if ammo.homing > 0.0:
		var hm = Label.new()
		hm.text = "homing"
		hm.add_theme_font_size_override("font_size", 13)
		hm.add_theme_color_override("font_color", Color(1.0, 0.7, 0.9))
		vbox.add_child(hm)
	# Splash
	if ammo.is_splash and ammo.splash_radius > 0.0:
		var sp = Label.new()
		sp.text = "splash %.0f px" % ammo.splash_radius
		sp.add_theme_font_size_override("font_size", 13)
		sp.add_theme_color_override("font_color", Color(1.0, 0.6, 0.3))
		vbox.add_child(sp)
	# Burn (DoT)
	if ammo.burn_damage > 0.0:
		var b = Label.new()
		b.text = "%s burn dmg/s for %ss" % [_fmt_num(ammo.burn_damage), _fmt_num(ammo.burn_duration)]
		b.add_theme_font_size_override("font_size", 13)
		b.add_theme_color_override("font_color", Color(1.0, 0.5, 0.2))
		vbox.add_child(b)
	# Status
	if ammo.status_effect != null:
		var sname: String = "applied"
		if "display_name" in ammo.status_effect and ammo.status_effect.display_name != "":
			sname = ammo.status_effect.display_name
		var st = Label.new()
		st.text = "applies %s%s" % [sname, (" (%ss)" % _fmt_num(ammo.status_duration)) if ammo.status_duration > 0.0 else ""]
		st.add_theme_font_size_override("font_size", 13)
		st.add_theme_color_override("font_color", Color(0.9, 0.5, 1.0))
		vbox.add_child(st)
	# Targeting filter (only show if restricted)
	if not (ammo.collides_air and ammo.collides_ground):
		var tg = Label.new()
		if ammo.collides_air and not ammo.collides_ground:
			tg.text = "air only"
		elif ammo.collides_ground and not ammo.collides_air:
			tg.text = "ground only"
		else:
			tg.text = "cannot hit anything"
		tg.add_theme_font_size_override("font_size", 13)
		tg.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
		vbox.add_child(tg)

	_detail_container.add_child(card)


# =========================
# ENUM NAME HELPERS
# =========================


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
