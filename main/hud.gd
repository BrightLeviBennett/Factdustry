extends CanvasLayer

# ============================================================
# HUD.GD - User Interface (Mindustry-style Block Menu)
# ============================================================
# Top-left: resource panel (grid of 3 columns, only owned items)
# Bottom-right: block selection menu with category tabs
# Layout:
#   ┌──────────────┬──────┐
#   │              │ cat  │
#   │  block grid  │ tabs │
#   │  (selected   │(vert)│
#   │   category)  │      │
#   ├──────────────┤      │
#   │ misc buttons │      │
#   └──────────────┴──────┘
# ============================================================

var main: Node2D

# Escape menu
var escape_menu: CanvasLayer
var escape_panel: PanelContainer
var escape_menu_open := false
var _clean_save_dialog: CanvasLayer
var settings_ui: Node

# Sector loss screen
var loss_screen: CanvasLayer

# Unlock notification
var _unlock_notify_panel: PanelContainer
var _unlock_notify_hbox: HBoxContainer
var _unlock_notify_timer: float = 0.0
const UNLOCK_NOTIFY_DURATION := 3.0

var resource_labels := {}
var building_buttons := {}
var info_label: Label

# --- Portrait UI (top-left) ---
var portrait_panel: PanelContainer
var portrait_icon_rect: TextureRect
var portrait_color_rect: ColorRect
var portrait_name_label: Label
var portrait_left_bar_fill: ColorRect
var portrait_left_bar_bg: ColorRect
var portrait_right_bar_1_fill: ColorRect  # health (unit) or cooldown (turret)
var portrait_right_bar_1_bg: ColorRect
var portrait_right_bar_2_fill: ColorRect  # ammo (turret only)
var portrait_right_bar_2_bg: ColorRect
var portrait_right_bar_3_fill: ColorRect  # booster (turret only)
var portrait_right_bar_3_bg: ColorRect
var portrait_right_bar_2_container: Control
var portrait_right_bar_3_container: Control
const PORTRAIT_BAR_HEIGHT := 48.0
const PORTRAIT_BAR_WIDTH := 6.0

# Block menu nodes
var block_menu: PanelContainer
var block_grid: GridContainer
var category_vbox: Container
var misc_hbox: HBoxContainer
var category_buttons: Dictionary = {}  # BlockCategory → Button
var selected_category: int = -1

# Resource panel nodes
var resource_grid: GridContainer
var resource_scroll: ScrollContainer
var resource_panel: PanelContainer
var paused_label: Label

# Block info tooltip (shown when hovering over a placed block)
var block_tooltip: PanelContainer
var tooltip_vbox: VBoxContainer
var _last_hovered_grid := Vector2i(-9999, -9999)
var _logistics: Node2D
# Cached sibling refs (populated in _ready). Avoid re-looking-up from _process.
var _unit_mgr: Node
var _drone: Node2D
var _combat_sys: Node
var _building_sys: Node
var _power_sys: Node
var _tooltip_refresh_timer := 0.0
const TOOLTIP_REFRESH_INTERVAL := 0.25  # Refresh tooltip every 0.25 seconds

# Build cost panel (shown when placing a block)
var build_cost_panel: PanelContainer
var _cost_dirty := false
var build_cost_vbox: VBoxContainer
var _last_cost_building := &""

# Unit mode panel (shown when holding shift)
var unit_mode_panel: PanelContainer

# Objective panel (top-right, shows current script step conditions)
var objective_panel: PanelContainer
var objective_vbox: VBoxContainer

# Category display names and icons (emoji fallback)
const CATEGORY_INFO := {
	BlockData.BlockCategory.CORE:       { "name": "Core",       "icon": "⬡" },
	BlockData.BlockCategory.EXTRACTORS: { "name": "Extractors", "icon": "⛏" },
	BlockData.BlockCategory.FACTORIES:  { "name": "Factories",  "icon": "⚙" },
	BlockData.BlockCategory.POWER:      { "name": "Power",      "icon": "⚡" },
	BlockData.BlockCategory.TURRETS:    { "name": "Turrets",    "icon": "⊕" },
	BlockData.BlockCategory.WALLS:      { "name": "Walls",      "icon": "▣" },
	BlockData.BlockCategory.UNITS:      { "name": "Units",      "icon": "♟" },
	BlockData.BlockCategory.ASSIST:     { "name": "Assist",     "icon": "✦" },
	BlockData.BlockCategory.ITEMS:      { "name": "Items",      "icon": "▦" },
	BlockData.BlockCategory.FLUIDS:     { "name": "Fluids",     "icon": "◎" },
}

## How many columns the block grid has
const BLOCK_GRID_COLS := 4
## Size of each block button
const BLOCK_BTN_SIZE := 48.0
## Size of each category tab button
const CAT_BTN_SIZE := 40.0



func _unit_mgr_ref() -> Node:
	if _unit_mgr == null:
		_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	return _unit_mgr

func _drone_ref() -> Node2D:
	if _drone == null:
		_drone = get_node_or_null("/root/Main/PlayerDrone")
	return _drone

func _combat_sys_ref() -> Node:
	if _combat_sys == null:
		_combat_sys = get_node_or_null("/root/Main/CombatSystem")
	return _combat_sys

func _building_sys_ref() -> Node:
	if _building_sys == null:
		_building_sys = get_node_or_null("/root/Main/BuildingSystem")
	return _building_sys

func _power_sys_ref() -> Node:
	if _power_sys == null:
		_power_sys = get_node_or_null("/root/Main/PowerSystem")
	return _power_sys


func _ready() -> void:
	await get_tree().process_frame
	main = get_node("/root/Main")
	_logistics = get_node_or_null("/root/Main/LogisticsSystem")
	_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	_drone = get_node_or_null("/root/Main/PlayerDrone")
	_combat_sys = get_node_or_null("/root/Main/CombatSystem")
	_building_sys = get_node_or_null("/root/Main/BuildingSystem")
	_power_sys = get_node_or_null("/root/Main/PowerSystem")

	_create_portrait_panel()
	_create_resource_panel()
	_create_block_menu()
	_create_info_label()
	_create_block_tooltip()
	_create_build_cost_panel()
	_create_unit_mode_panel()
	_create_objective_panel()
	_create_escape_menu()

	_create_unlock_notify()

	main.resources_changed.connect(_on_resources_changed)
	main.building_selected.connect(_on_building_selected)
	TechTree.node_state_changed.connect(_on_tech_state_changed)

	# Show current resources immediately (signal may have fired before we connected)
	_on_resources_changed(main.resources)

	# Select first category that has blocks
	for cat in CATEGORY_INFO:
		var blocks = _get_blocks_for_category(cat)
		if blocks.size() > 0:
			_select_category(cat)
			break


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# Close UIs in priority order
		var tech_tree_ui = get_node_or_null("/root/Main/TechTreeUI")
		var database_ui = get_node_or_null("/root/Main/DatabaseUI")
		# Settings UI
		if settings_ui and settings_ui.is_open:
			settings_ui.hide_settings()
			get_viewport().set_input_as_handled()
			return
		# Schematic viewer
		if _schematic_viewer and is_instance_valid(_schematic_viewer):
			_schematic_viewer.queue_free()
			get_viewport().set_input_as_handled()
			return
		# Clean save dialog
		if _clean_save_dialog and _clean_save_dialog.visible:
			_clean_save_dialog.visible = false
			get_viewport().set_input_as_handled()
			return
		# Tech tree / database — let them handle it
		var is_other_ui_open: bool = (tech_tree_ui and tech_tree_ui.is_open) or (database_ui and database_ui.is_open)
		if is_other_ui_open:
			return  # Their own _input handles ui_cancel
		# Escape menu
		if escape_menu_open:
			_close_escape_menu()
		else:
			_open_escape_menu()
		get_viewport().set_input_as_handled()
		# Cmd+Shift+\ (or Ctrl+Shift+\) = Clean Save Data
	elif event is InputEventKey and event.pressed and event.keycode == KEY_BACKSLASH and event.shift_pressed and (event.meta_pressed or event.ctrl_pressed):
		_show_clean_save_dialog()
		get_viewport().set_input_as_handled()


var _autosave_timer := 60.0
const AUTOSAVE_INTERVAL := 60.0

func _process(delta: float) -> void:
	# Track play time
	if not main.world_paused and not main.sector_lost:
		main.stats_play_time += delta

	# Toggle whole HUD visibility with the "i" key
	if Input.is_action_just_pressed("toggle_ui"):
		visible = not visible
		var drone = _drone_ref()
		if drone:
			drone.queue_redraw()

	# Periodic auto-save
	_autosave_timer -= delta
	if _autosave_timer <= 0.0:
		_autosave_timer = AUTOSAVE_INTERVAL
		if SaveManager.active_sector_id != &"" and not main.sector_lost:
			SaveManager.sync_active_sector_resources()
			SaveManager.save_sector(SaveManager.active_sector_id)
			SaveManager.save_campaign()

	# Unlock notification fade out
	if _unlock_notify_timer > 0.0:
		_unlock_notify_timer -= delta
		if _unlock_notify_timer <= 0.0:
			_unlock_notify_panel.visible = false
		elif _unlock_notify_timer < 0.5:
			_unlock_notify_panel.modulate.a = _unlock_notify_timer / 0.5
		else:
			_unlock_notify_panel.modulate.a = 1.0

	# Show/hide paused indicator
	if main.world_paused:
		paused_label.text = "World paused, press space to unpause."
		paused_label.visible = true
	elif main.build_paused:
		paused_label.text = "Building paused, press F to unpause."
		paused_label.visible = true
	else:
		paused_label.visible = false

	if main.selected_building != &"":
		_update_info_label(main.selected_building)

	# Update objective panel
	_update_objective_panel()

	# Update hover tooltip / build cost panel
	var mouse_world := Vector2.ZERO
	var camera = get_viewport().get_camera_2d()
	if camera:
		mouse_world = camera.get_screen_center_position() + (get_viewport().get_mouse_position() - get_viewport().get_visible_rect().size / 2.0) / camera.zoom
	else:
		mouse_world = get_viewport().get_mouse_position()

	var hovered_grid: Vector2i = main.world_to_grid(mouse_world)

	if main.selected_building != &"":
		# Placing a block — show build cost. Rebuilds when the block changes
		# or when _cost_dirty is set (by the resources_changed signal).
		block_tooltip.visible = false
		_last_hovered_grid = Vector2i(-9999, -9999)
		if _last_cost_building != main.selected_building or _cost_dirty:
			_last_cost_building = main.selected_building
			_cost_dirty = false
			_update_build_cost_panel(main.selected_building)
		build_cost_panel.visible = true
	elif main.placed_buildings.has(hovered_grid):
		# Hovering over a placed block — show tooltip
		build_cost_panel.visible = false
		_last_cost_building = &""
		# Rebuild if hovered cell changed, or periodically for live data
		_tooltip_refresh_timer -= delta
		if hovered_grid != _last_hovered_grid or _tooltip_refresh_timer <= 0:
			_last_hovered_grid = hovered_grid
			_tooltip_refresh_timer = TOOLTIP_REFRESH_INTERVAL
			_update_block_tooltip(hovered_grid)
		block_tooltip.visible = true
	else:
		# Neither — hide both
		block_tooltip.visible = false
		build_cost_panel.visible = false
		_last_hovered_grid = Vector2i(-9999, -9999)
		_last_cost_building = &""

	# Show unit mode panel when shift is held
	# Unit mode panel — visible whenever the UnitManager is in unit mode.
	var unit_mgr = _unit_mgr_ref()
	unit_mode_panel.visible = unit_mgr != null and "unit_mode_active" in unit_mgr and unit_mgr.unit_mode_active

	# Update portrait UI
	_update_portrait_panel()


# =========================
# PORTRAIT PANEL (TOP LEFT)
# =========================

func _create_portrait_panel() -> void:
	portrait_panel = PanelContainer.new()
	portrait_panel.offset_left = 10
	portrait_panel.offset_top = 10
	portrait_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.03, 0.06, 0.8)
	style.set_corner_radius_all(6)
	style.border_color = Color(0.2, 0.3, 0.4, 0.5)
	style.set_border_width_all(1)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	portrait_panel.add_theme_stylebox_override("panel", style)
	add_child(portrait_panel)

	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 4)
	main_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait_panel.add_child(main_vbox)

	# --- Content row: [left bar] [icon] [right bars] ---
	var content_hbox = HBoxContainer.new()
	content_hbox.add_theme_constant_override("separation", 4)
	content_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_vbox.add_child(content_hbox)

	# Left health bar
	var left_bar = _create_portrait_bar(Color(0.15, 0.05, 0.05, 0.8), Color(0.3, 0.9, 0.3))
	content_hbox.add_child(left_bar["container"])
	portrait_left_bar_bg = left_bar["bg"]
	portrait_left_bar_fill = left_bar["fill"]

	# Icon area
	var icon_panel = PanelContainer.new()
	icon_panel.custom_minimum_size = Vector2(48, 48)
	icon_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon_style = StyleBoxFlat.new()
	icon_style.bg_color = Color(0.06, 0.08, 0.12, 0.7)
	icon_style.set_corner_radius_all(4)
	icon_panel.add_theme_stylebox_override("panel", icon_style)
	content_hbox.add_child(icon_panel)

	# TextureRect for icon (shown when entity has an icon texture)
	portrait_icon_rect = TextureRect.new()
	portrait_icon_rect.custom_minimum_size = Vector2(48, 48)
	portrait_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_panel.add_child(portrait_icon_rect)

	# ColorRect fallback (shown when no icon texture)
	portrait_color_rect = ColorRect.new()
	portrait_color_rect.custom_minimum_size = Vector2(48, 48)
	portrait_color_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait_color_rect.visible = false
	icon_panel.add_child(portrait_color_rect)

	# Right bar 1 (health for units, cooldown for turrets)
	var right_bar_1 = _create_portrait_bar(Color(0.15, 0.05, 0.05, 0.8), Color(0.3, 0.9, 0.3))
	content_hbox.add_child(right_bar_1["container"])
	portrait_right_bar_1_bg = right_bar_1["bg"]
	portrait_right_bar_1_fill = right_bar_1["fill"]

	# Right bar 2 (ammo — turret only)
	var right_bar_2 = _create_portrait_bar(Color(0.1, 0.07, 0.02, 0.8), Color(0.9, 0.6, 0.1))
	content_hbox.add_child(right_bar_2["container"])
	portrait_right_bar_2_bg = right_bar_2["bg"]
	portrait_right_bar_2_fill = right_bar_2["fill"]
	portrait_right_bar_2_container = right_bar_2["container"]
	portrait_right_bar_2_container.visible = false

	# Right bar 3 (booster — turret only, conditional)
	var right_bar_3 = _create_portrait_bar(Color(0.02, 0.05, 0.12, 0.8), Color(0.3, 0.5, 0.9))
	content_hbox.add_child(right_bar_3["container"])
	portrait_right_bar_3_bg = right_bar_3["bg"]
	portrait_right_bar_3_fill = right_bar_3["fill"]
	portrait_right_bar_3_container = right_bar_3["container"]
	portrait_right_bar_3_container.visible = false

	# Name label
	portrait_name_label = Label.new()
	portrait_name_label.add_theme_font_size_override("font_size", 11)
	portrait_name_label.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
	portrait_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	portrait_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_vbox.add_child(portrait_name_label)


## Creates a vertical bar with bg and fill for the portrait panel.
func _create_portrait_bar(bg_color: Color, fill_color: Color) -> Dictionary:
	var container = Control.new()
	container.custom_minimum_size = Vector2(PORTRAIT_BAR_WIDTH, PORTRAIT_BAR_HEIGHT)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bg = ColorRect.new()
	bg.color = bg_color
	bg.position = Vector2.ZERO
	bg.size = Vector2(PORTRAIT_BAR_WIDTH, PORTRAIT_BAR_HEIGHT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(bg)

	var fill = ColorRect.new()
	fill.color = fill_color
	fill.position = Vector2(0, 0)
	fill.size = Vector2(PORTRAIT_BAR_WIDTH, PORTRAIT_BAR_HEIGHT)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(fill)

	return {"container": container, "bg": bg, "fill": fill}


## Sets a portrait bar's fill level (0.0 to 1.0), filling from bottom to top.
func _set_portrait_bar(fill_rect: ColorRect, pct: float) -> void:
	pct = clampf(pct, 0.0, 1.0)
	var h: float = PORTRAIT_BAR_HEIGHT * pct
	fill_rect.position = Vector2(0, PORTRAIT_BAR_HEIGHT - h)
	fill_rect.size = Vector2(PORTRAIT_BAR_WIDTH, h)


func _update_portrait_panel() -> void:
	var unit_mgr = _unit_mgr_ref()
	var drone = _drone_ref()
	var combat = _combat_sys_ref()

	var is_controlling := unit_mgr != null and unit_mgr.controlled_entity != null
	var ctrl_type: String = unit_mgr.controlled_type if unit_mgr else ""

	if is_controlling and ctrl_type == "unit":
		# --- Controlled Unit ---
		var unit: Node2D = unit_mgr.controlled_entity
		if is_instance_valid(unit) and not unit.is_dead:
			# Icon
			if unit.data and unit.data.icon:
				portrait_icon_rect.texture = unit.data.icon
				portrait_icon_rect.visible = true
				portrait_color_rect.visible = false
			else:
				portrait_icon_rect.visible = false
				portrait_color_rect.color = unit.unit_color if unit.data else Color.GRAY
				portrait_color_rect.visible = true
			# Name
			portrait_name_label.text = unit.data.display_name if unit.data else "Unit"
			# Health on both sides
			var pct: float = unit.health / unit.max_health if unit.max_health > 0 else 0.0
			var hp_color: Color = Color(1.0 - pct, pct, 0.0)
			portrait_left_bar_fill.color = hp_color
			portrait_right_bar_1_fill.color = hp_color
			_set_portrait_bar(portrait_left_bar_fill, pct)
			_set_portrait_bar(portrait_right_bar_1_fill, pct)
			# Hide turret-only bars
			portrait_right_bar_2_container.visible = false
			portrait_right_bar_3_container.visible = false

	elif is_controlling and ctrl_type == "turret":
		# --- Controlled Turret ---
		var grid_pos: Vector2i = unit_mgr.controlled_entity
		if main.placed_buildings.has(grid_pos):
			var block_id: StringName = main.placed_buildings[grid_pos]
			var bdata = Registry.get_block(block_id)
			# Icon
			if bdata and bdata.icon:
				portrait_icon_rect.texture = bdata.icon
				portrait_icon_rect.visible = true
				portrait_color_rect.visible = false
			elif bdata:
				portrait_icon_rect.visible = false
				portrait_color_rect.color = bdata.color
				portrait_color_rect.visible = true
			# Name
			portrait_name_label.text = bdata.display_name if bdata else "Turret"
			# Left bar: health
			var hp: float = main.building_health.get(grid_pos, bdata.max_health if bdata else 100.0)
			var max_hp: float = bdata.max_health if bdata else 100.0
			var hp_pct: float = hp / max_hp if max_hp > 0 else 0.0
			var hp_color: Color = Color(1.0 - hp_pct, hp_pct, 0.0)
			portrait_left_bar_fill.color = hp_color
			_set_portrait_bar(portrait_left_bar_fill, hp_pct)
			# Right bar 1: cooldown (yellow)
			portrait_right_bar_1_fill.color = Color(0.9, 0.85, 0.2)
			portrait_right_bar_1_bg.color = Color(0.12, 0.1, 0.02, 0.8)
			var cd: float = 0.0
			var max_cd: float = bdata.attack_speed if bdata else 1.0
			if combat and combat.turret_cooldowns.has(grid_pos):
				cd = combat.turret_cooldowns[grid_pos]
			var cd_pct: float = 1.0 - (cd / max_cd) if max_cd > 0 and cd > 0 else 1.0
			_set_portrait_bar(portrait_right_bar_1_fill, cd_pct)
			# Right bar 2: ammo (orange) — placeholder, always full
			portrait_right_bar_2_container.visible = true
			_set_portrait_bar(portrait_right_bar_2_fill, 1.0)
			# Right bar 3: booster (blue) — hidden unless boosting input exists
			portrait_right_bar_3_container.visible = false

	else:
		# --- Default: Core Unit (Player Drone) ---
		if drone:
			# Icon
			if drone.drone_texture:
				portrait_icon_rect.texture = drone.drone_texture
				portrait_icon_rect.visible = true
				portrait_color_rect.visible = false
			else:
				portrait_icon_rect.visible = false
				portrait_color_rect.color = drone.drone_color
				portrait_color_rect.visible = true
			# Name
			portrait_name_label.text = drone.data.display_name if drone.data else "Drone"
			# Health on both sides
			var pct: float = drone.health / drone.max_health if drone.max_health > 0 else 0.0
			var hp_color: Color = Color(1.0 - pct, pct, 0.0)
			portrait_left_bar_fill.color = hp_color
			portrait_right_bar_1_fill.color = hp_color
			portrait_right_bar_1_bg.color = Color(0.15, 0.05, 0.05, 0.8)
			_set_portrait_bar(portrait_left_bar_fill, pct)
			_set_portrait_bar(portrait_right_bar_1_fill, pct)
			# Hide turret-only bars
			portrait_right_bar_2_container.visible = false
			portrait_right_bar_3_container.visible = false


# =========================
# RESOURCE PANEL (TOP CENTER)
# =========================

func _create_resource_panel() -> void:
	var margin = MarginContainer.new()
	margin.anchor_left = 0.5
	margin.anchor_right = 0.5
	margin.grow_horizontal = Control.GROW_DIRECTION_BOTH
	margin.add_theme_constant_override("margin_top", 10)
	add_child(margin)

	resource_panel = PanelContainer.new()
	margin.add_child(resource_panel)

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)
	style.set_corner_radius_all(8)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	resource_panel.add_theme_stylebox_override("panel", style)

	resource_scroll = ScrollContainer.new()
	resource_scroll.custom_minimum_size.y = 0
	resource_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	resource_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	resource_panel.add_child(resource_scroll)

	resource_grid = GridContainer.new()
	resource_grid.columns = 3
	resource_grid.add_theme_constant_override("h_separation", 20)
	resource_grid.add_theme_constant_override("v_separation", 4)
	resource_scroll.add_child(resource_grid)

	# Paused label (below resource panel, center-top)
	paused_label = Label.new()
	paused_label.text = "World paused, press space to unpause."
	paused_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	paused_label.add_theme_font_size_override("font_size", 14)
	paused_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	paused_label.anchor_left = 0.5
	paused_label.anchor_right = 0.5
	paused_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	paused_label.offset_top = 60
	paused_label.visible = false
	add_child(paused_label)


# =========================
# BLOCK MENU (BOTTOM RIGHT)
# =========================

func _create_block_menu() -> void:
	# Outer anchor: bottom-right corner
	block_menu = PanelContainer.new()
	block_menu.anchor_left = 1.0
	block_menu.anchor_right = 1.0
	block_menu.anchor_top = 1.0
	block_menu.anchor_bottom = 1.0
	block_menu.offset_left = -350
	block_menu.offset_top = -320
	block_menu.offset_right = -10
	block_menu.offset_bottom = -10
	block_menu.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	block_menu.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	style.set_corner_radius_all(8)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	block_menu.add_theme_stylebox_override("panel", style)
	add_child(block_menu)

	# Main HBox: [left column (blocks + misc)] [right column (category tabs)]
	var main_hbox = HBoxContainer.new()
	main_hbox.add_theme_constant_override("separation", 4)
	block_menu.add_child(main_hbox)

	# --- Left Column ---
	var left_vbox = VBoxContainer.new()
	left_vbox.add_theme_constant_override("separation", 4)
	left_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_hbox.add_child(left_vbox)

	# Block grid area (scrollable)
	var grid_panel = PanelContainer.new()
	var grid_style = StyleBoxFlat.new()
	grid_style.bg_color = Color(0.05, 0.05, 0.08, 0.6)
	grid_style.set_corner_radius_all(4)
	grid_style.content_margin_left = 4
	grid_style.content_margin_right = 4
	grid_style.content_margin_top = 4
	grid_style.content_margin_bottom = 4
	grid_panel.add_theme_stylebox_override("panel", grid_style)
	grid_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_vbox.add_child(grid_panel)

	var grid_scroll = ScrollContainer.new()
	grid_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	grid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	grid_panel.add_child(grid_scroll)

	block_grid = GridContainer.new()
	block_grid.columns = BLOCK_GRID_COLS
	block_grid.add_theme_constant_override("h_separation", 3)
	block_grid.add_theme_constant_override("v_separation", 3)
	grid_scroll.add_child(block_grid)

	# Misc buttons row
	var misc_panel = PanelContainer.new()
	var misc_style = StyleBoxFlat.new()
	misc_style.bg_color = Color(0.05, 0.05, 0.08, 0.6)
	misc_style.set_corner_radius_all(4)
	misc_style.content_margin_left = 4
	misc_style.content_margin_right = 4
	misc_style.content_margin_top = 4
	misc_style.content_margin_bottom = 4
	misc_panel.add_theme_stylebox_override("panel", misc_style)
	left_vbox.add_child(misc_panel)

	misc_hbox = HBoxContainer.new()
	misc_hbox.add_theme_constant_override("separation", 3)
	misc_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	misc_panel.add_child(misc_hbox)

	_add_misc_button("⬡", "Tech Tree", _on_misc_tech_tree)
	_add_misc_button("📋", "Schematics", _on_misc_schematics)
	_add_misc_button("📖", "Database", _on_misc_database)
	_add_misc_button("🌍", "Planet Map", _on_misc_planet_map)

	# --- Right Column: Category Tabs ---
	var cat_grid = GridContainer.new()
	cat_grid.columns = 2
	cat_grid.add_theme_constant_override("h_separation", 3)
	cat_grid.add_theme_constant_override("v_separation", 3)
	cat_grid.custom_minimum_size.x = CAT_BTN_SIZE * 2 + 6
	main_hbox.add_child(cat_grid)
	category_vbox = cat_grid  # Reuse the variable so _add_category_button still works

	# Build category buttons — only for categories that have blocks
	for cat in CATEGORY_INFO:
		var blocks = _get_blocks_for_category(cat)
		if blocks.size() == 0:
			continue
		_add_category_button(cat)


func _add_category_button(cat: int) -> void:
	var info = CATEGORY_INFO[cat]
	var btn = Button.new()
	btn.custom_minimum_size = Vector2(CAT_BTN_SIZE, CAT_BTN_SIZE)
	btn.tooltip_text = info["name"]

	btn.text = info["icon"]
	btn.add_theme_font_size_override("font_size", 18)

	var normal_style = _make_cat_style(Color(0.08, 0.1, 0.14, 0.8))
	var hover_style = _make_cat_style(Color(0.12, 0.15, 0.2, 0.9))
	btn.add_theme_stylebox_override("normal", normal_style)
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))

	btn.pressed.connect(_on_category_pressed.bind(cat))
	category_vbox.add_child(btn)
	category_buttons[cat] = btn


func _add_misc_button(icon_text: String, tooltip: String, callback: Callable) -> void:
	var btn = Button.new()
	btn.text = icon_text
	btn.tooltip_text = tooltip
	btn.custom_minimum_size = Vector2(BLOCK_BTN_SIZE, BLOCK_BTN_SIZE)
	btn.add_theme_font_size_override("font_size", 18)

	var style = _make_cat_style(Color(0.06, 0.08, 0.12, 0.8))
	var hover = _make_cat_style(Color(0.1, 0.14, 0.2, 0.9))
	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))
	btn.pressed.connect(callback)
	misc_hbox.add_child(btn)


func _on_tech_state_changed(_node_id: StringName, _new_state: int) -> void:
	_refresh_block_menu()
	# Show unlock notification only for auto-researched nodes (not manually clicked).
	# Skip: the seed node core_shard, hidden dependency markers (-L-/-C-/-D-),
	# and anything researched while the tech tree UI is open (manual clicks).
	# Event-only nodes that ARE visible — materials and sector nodes — do
	# trigger the popup so the player sees "Iron unlocked", "Crevice unlocked",
	# etc. when the underlying event fires.
	if _new_state == TechTree.NodeState.RESEARCHED:
		if _node_id == &"core_shard":
			return
		var tech_ui = get_node_or_null("/root/Main/TechTreeUI")
		if tech_ui and tech_ui.is_open:
			return  # Player is manually researching in the tech tree
		var nd = TechTree.get_node_data(_node_id)
		if nd and not nd.get("hidden", false):
			_show_unlock_icon(_node_id)


## Rebuilds category tabs and refreshes the current block grid when tech unlocks change.
func _refresh_block_menu() -> void:
	# Rebuild category tabs
	for c in category_vbox.get_children():
		c.queue_free()
	category_buttons.clear()
	for cat in CATEGORY_INFO:
		var blocks = _get_blocks_for_category(cat)
		if blocks.size() == 0:
			continue
		_add_category_button(cat)
	# Refresh current category's blocks
	if selected_category >= 0:
		_select_category(selected_category)


## Populates the block grid with buttons for blocks in the selected category.
func _select_category(cat: int) -> void:
	selected_category = cat

	# Clear old block buttons
	for c in block_grid.get_children():
		c.queue_free()
	building_buttons.clear()

	# Highlight selected tab
	_update_category_highlights()

	# Add block buttons
	var blocks = _get_blocks_for_category(cat)
	for block in blocks:
		if block.id == &"core":
			continue
		_add_block_button(block)


func _add_block_button(block: BlockData) -> void:
	var btn = Button.new()
	btn.custom_minimum_size = Vector2(BLOCK_BTN_SIZE, BLOCK_BTN_SIZE)
	btn.tooltip_text = block.display_name

	# Use icon if available, otherwise text
	if block.icon:
		var tex = TextureRect.new()
		tex.texture = block.icon
		tex.custom_minimum_size = Vector2(36, 36)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Center the texture in the button
		tex.anchor_left = 0.5
		tex.anchor_top = 0.5
		tex.anchor_right = 0.5
		tex.anchor_bottom = 0.5
		tex.offset_left = -18
		tex.offset_top = -18
		tex.offset_right = 18
		tex.offset_bottom = 18
		btn.add_child(tex)
		btn.text = ""
	else:
		btn.text = block.display_name.left(3)
		btn.add_theme_font_size_override("font_size", 10)

	var normal_style = _make_block_style(block.color.darkened(0.6))
	var hover_style = _make_block_style(block.color.darkened(0.3))
	var pressed_style = _make_block_style(block.color.darkened(0.1))
	btn.add_theme_stylebox_override("normal", normal_style)
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", pressed_style)
	btn.add_theme_color_override("font_color", block.color.lightened(0.3))

	btn.pressed.connect(_on_building_button_pressed.bind(block.id))
	block_grid.add_child(btn)
	building_buttons[block.id] = btn


func _update_category_highlights() -> void:
	for cat in category_buttons:
		var btn = category_buttons[cat] as Button
		if cat == selected_category:
			btn.add_theme_stylebox_override("normal", _make_cat_style(Color(0.15, 0.2, 0.3, 0.95)))
		else:
			btn.add_theme_stylebox_override("normal", _make_cat_style(Color(0.08, 0.1, 0.14, 0.8)))


# =========================
# INFO LABEL (TOP CENTER)
# =========================

func _create_info_label() -> void:
	info_label = Label.new()
	info_label.visible = false  # Removed — build cost info is in the build cost panel
	add_child(info_label)


# =========================
# STYLE HELPERS
# =========================

func _make_cat_style(color: Color) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(4)
	s.content_margin_left = 4
	s.content_margin_right = 4
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	return s


func _make_block_style(color: Color) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(4)
	s.border_color = color.lightened(0.15)
	s.set_border_width_all(1)
	s.content_margin_left = 2
	s.content_margin_right = 2
	s.content_margin_top = 2
	s.content_margin_bottom = 2
	return s


# =========================
# BLOCK TOOLTIP (hover over placed block)
# =========================

func _create_block_tooltip() -> void:
	block_tooltip = PanelContainer.new()
	# Position above the block menu
	block_tooltip.anchor_left = 1.0
	block_tooltip.anchor_right = 1.0
	block_tooltip.anchor_top = 1.0
	block_tooltip.anchor_bottom = 1.0
	block_tooltip.offset_left = -350
	block_tooltip.offset_right = -10
	block_tooltip.offset_bottom = -330
	block_tooltip.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	block_tooltip.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.03, 0.06, 0.85)
	style.set_corner_radius_all(8)
	style.border_color = Color(0.2, 0.3, 0.4, 0.6)
	style.set_border_width_all(1)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	block_tooltip.add_theme_stylebox_override("panel", style)
	block_tooltip.visible = false
	block_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(block_tooltip)

	tooltip_vbox = VBoxContainer.new()
	tooltip_vbox.add_theme_constant_override("separation", 4)
	tooltip_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	block_tooltip.add_child(tooltip_vbox)


func _update_block_tooltip(grid_pos: Vector2i) -> void:
	# Clear old content
	for c in tooltip_vbox.get_children():
		c.queue_free()

	if not main.placed_buildings.has(grid_pos):
		block_tooltip.visible = false
		return

	var block_id: StringName = main.placed_buildings[grid_pos]
	var data: BlockData = Registry.get_block(block_id)
	if data == null:
		block_tooltip.visible = false
		return

	# Find anchor for multi-tile buildings
	var anchor = main.get_building_anchor(grid_pos)
	var origin: Vector2i = anchor if anchor != null else grid_pos

	# --- Header: Icon + Name ---
	var header_hbox = HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 8)
	header_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE

	if data.icon:
		var icon_rect = TextureRect.new()
		icon_rect.texture = data.icon
		icon_rect.custom_minimum_size = Vector2(24, 24)
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		header_hbox.add_child(icon_rect)
	else:
		var sw = ColorRect.new()
		sw.custom_minimum_size = Vector2(24, 24)
		sw.color = data.color
		sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		header_hbox.add_child(sw)

	var name_lbl = Label.new()
	name_lbl.text = data.display_name
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_hbox.add_child(name_lbl)

	tooltip_vbox.add_child(header_hbox)

	# --- Health Bar ---
	var health_pct: float = main.get_building_health_pct(grid_pos)
	var current_health: float = main.building_health.get(grid_pos, data.max_health)
	_add_tooltip_health_bar(health_pct, current_health, data.max_health)

	# --- Power Bar ---
	# Network-level gen/use efficiency for every electrical block, shown
	# directly under the health bar so you can see at a glance whether the
	# grid this block is on is healthy, brownout'd, or fully starved.
	if data.is_electrical_power_block():
		var ps_tt = _power_sys_ref()
		if ps_tt:
			var info: Dictionary = ps_tt.get_electrical_network_info(origin)
			if float(info.get("gen", 0.0)) > 0.0 or float(info.get("use", 0.0)) > 0.0:
				_add_tooltip_power_bar(
					float(info.get("efficiency", 1.0)),
					float(info.get("gen", 0.0)),
					float(info.get("use", 0.0))
				)

	# --- Unit Fabricator Input Progress + Unit Count ---
	if data.produced_unit != &"":
		if _logistics and _logistics.factory_buffers.has(origin):
			var state = _logistics.factory_buffers[origin]
			# Unit fabricators consume the produced unit's build_cost.
			# Normalize short ids ("copper") to full item ids ("mat_copper")
			# so we look up the runtime buffer with the same key the conveyor
			# pushes items under.
			var ufab_unit = Registry.get_unit(data.produced_unit)
			var ufab_raw: Dictionary = ufab_unit.build_cost if ufab_unit and not ufab_unit.build_cost.is_empty() else data.input_items
			var ufab_inputs: Dictionary = _logistics._normalize_item_keys(ufab_raw) if _logistics.has_method("_normalize_item_keys") else ufab_raw
			for raw_id in ufab_inputs:
				var sn_id := StringName(raw_id)
				var recipe: int = int(ufab_inputs[raw_id])
				var cap: int = data.max_stored_items if data.max_stored_items > 0 else recipe
				var have: int = state["inputs"].get(sn_id, 0)
				var item = Registry.get_item_or_fluid(sn_id)
				var item_name: String = item.display_name if item else str(sn_id)
				_add_tooltip_progress_bar(have, cap, item_name, Color(0.9, 0.6, 0.1))
		# Show current count / max for this unit type
		var unit_data = Registry.get_unit(data.produced_unit)
		var unit_name: String = unit_data.display_name if unit_data else str(data.produced_unit)
		var current_count: int = main.get_player_unit_count(data.produced_unit)
		var max_count: int = main.get_unit_cap_per_type()
		var at_cap: bool = current_count >= max_count
		var count_color := Color(0.9, 0.3, 0.3) if at_cap else Color(0.7, 0.9, 0.7)
		_add_tooltip_line("%s: %d / %d" % [unit_name, current_count, max_count], count_color)

	# --- Conveyor Contents ---
	if _logistics and data.is_transport() and not data.transports_fluid:
		if _logistics.conveyor_items.has(grid_pos):
			var item_entry = _logistics.conveyor_items[grid_pos]
			var item = Registry.get_item_or_fluid(item_entry["item_id"])
			if item:
				_add_tooltip_line("Carrying: %s" % item.display_name, item.color)

	# --- Pipe Contents ---
	if _logistics and data.transports_fluid:
		if _logistics.pipe_contents.has(grid_pos):
			var pipe = _logistics.pipe_contents[grid_pos]
			var fluid = Registry.get_fluid(pipe["fluid_id"])
			if fluid:
				var fill_pct: float = float(pipe["amount"]) / fluid.units_per_segment * 100.0
				_add_tooltip_line("Fluid: %s (%.0f%%)" % [fluid.display_name, fill_pct], fluid.color)

	# --- Extractor Efficiency ---
	if data.category == BlockData.BlockCategory.EXTRACTORS:
		var terrain = get_node_or_null("/root/Main/TerrainSystem")
		var rot: int = main.building_rotation.get(origin, 0)
		var front_cells: Array[Vector2i] = []
		if _logistics:
			front_cells = _logistics._get_front_edge(origin, data.grid_size, rot)
		var front_count: int = front_cells.size()
		var hit_count: int = 0
		var dir: Vector2i
		match rot:
			0: dir = Vector2i(1, 0)
			1: dir = Vector2i(0, 1)
			2: dir = Vector2i(-1, 0)
			3: dir = Vector2i(0, -1)
			_: dir = Vector2i(1, 0)
		# Wall miners (wall crusher) mine blackstone walls, not ore tiles.
		# Mirror _update_drills' hit-check so the tooltip matches actual
		# production rather than always reporting 0%.
		var is_wall_miner: bool = data.tags.has("wall_miner")
		if terrain:
			for cell in front_cells:
				if is_wall_miner:
					var c1_ok: bool = terrain.get_ore_at(cell) == null \
						and StringName(terrain.wall_tiles.get(cell, &"")) == &"blackstone_wall"
					var c2_ok: bool = terrain.get_ore_at(cell + dir) == null \
						and StringName(terrain.wall_tiles.get(cell + dir, &"")) == &"blackstone_wall"
					if c1_ok or c2_ok:
						hit_count += 1
				else:
					if terrain.get_ore_at(cell) != null:
						hit_count += 1
					elif terrain.get_ore_at(cell + dir) != null:
						hit_count += 1
		var ore_eff: float = float(hit_count) / float(front_count) if front_count > 0 else 1.0
		# Power efficiency multiplies ore efficiency so the displayed %/rate
		# matches the actual production speed (network over-draw slows drills).
		var pow_eff: float = 1.0
		if data.electrical_power_use > 0:
			var ps_eff = _power_sys_ref()
			if ps_eff:
				pow_eff = ps_eff.get_electrical_efficiency(origin)
		var efficiency: float = ore_eff * pow_eff
		var cycle = data.production_time if data.production_time > 0 else 2.0
		var effective_cycle: float = cycle / efficiency if efficiency > 0 else 0.0
		var rate: float = 1.0 / effective_cycle if effective_cycle > 0 else 0.0
		var eff_pct: int = int(round(efficiency * 100))
		var eff_color: Color
		if eff_pct >= 100:
			eff_color = Color(0.7, 0.9, 0.7)
		elif eff_pct > 0:
			eff_color = Color(0.9, 0.7, 0.3)
		else:
			eff_color = Color(0.9, 0.4, 0.4)
		_add_tooltip_line("Efficiency: %d%% (%.2f/s)" % [eff_pct, rate], eff_color)
	elif data.tags.has("pump"):
		var cycle = data.production_time if data.production_time > 0 else 2.0
		var rate: float = 1.0 / cycle
		_add_tooltip_line("Efficiency: %.2f/s" % rate, Color(0.7, 0.9, 0.7))

	# --- Power gen generator note ---
	# Consumer status is already shown via the power bar above. Pure
	# generators get a short rating line so you can see their contribution
	# without hovering the network tooltip math.
	if data.electrical_power_gen > 0:
		_add_tooltip_line("Generates: %.0f power" % data.electrical_power_gen, Color(0.5, 0.8, 1.0))

	# --- Needed Resources (for factories/constructors/drills with pending inputs) ---
	if _logistics:
		# Constructor: show selected block's build cost and what's collected
		if data.tags.has("constructor") and _logistics.constructor_state.has(origin):
			var cs = _logistics.constructor_state[origin]
			var selected_id: StringName = cs.get("selected_block", &"")
			if selected_id != &"":
				var target_data = Registry.get_block(selected_id)
				if target_data:
					_add_tooltip_separator()
					_add_tooltip_line("Building: %s" % target_data.display_name, Color(0.9, 0.8, 0.3))
					var collected: Dictionary = cs.get("collected", {})
					for raw_id in target_data.build_cost:
						var sn_id := StringName(raw_id)
						var needed: int = int(target_data.build_cost[raw_id])
						var have: int = int(collected.get(sn_id, 0))
						# Build cost keys may use short names; try with "mat_" prefix for icon lookup
						var item = Registry.get_item_or_fluid(sn_id)
						if item == null:
							item = Registry.get_item_or_fluid(StringName("mat_" + str(raw_id)))
						var hbox = HBoxContainer.new()
						hbox.add_theme_constant_override("separation", 4)
						hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
						if item and item.icon:
							var tex = TextureRect.new()
							tex.texture = item.icon
							tex.custom_minimum_size = Vector2(16, 16)
							tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
							tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
							tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
							hbox.add_child(tex)
						var lbl = Label.new()
						lbl.text = "%d / %d" % [have, needed]
						lbl.add_theme_font_size_override("font_size", 12)
						lbl.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3) if have >= needed else Color(0.9, 0.5, 0.3))
						lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
						hbox.add_child(lbl)
						tooltip_vbox.add_child(hbox)

		# Factory: show input requirements and what's buffered
		elif not data.input_items.is_empty() and _logistics.factory_buffers.has(origin):
			var fb = _logistics.factory_buffers[origin]
			var inputs: Dictionary = fb.get("inputs", {})
			# Omnidirectional factories buffer inputs up to max_stored_items.
			var is_omni_bldg: bool = data.tags.has("omnidirectional")
			var has_need := false
			for raw_id in data.input_items:
				var sn_id := StringName(raw_id)
				var needed: int = int(data.input_items[raw_id])
				var have: int = int(inputs.get(sn_id, 0))
				if have < needed:
					has_need = true
					break
			if has_need or is_omni_bldg:
				_add_tooltip_separator()
				for raw_id in data.input_items:
					var sn_id := StringName(raw_id)
					var recipe_amt: int = int(data.input_items[raw_id])
					var have: int = int(inputs.get(sn_id, 0))
					var needed: int = recipe_amt
					if is_omni_bldg:
						needed = data.max_stored_items if data.max_stored_items > 0 else recipe_amt * 10
					var item = Registry.get_item_or_fluid(sn_id)
					var hbox = HBoxContainer.new()
					hbox.add_theme_constant_override("separation", 4)
					hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
					if item and item.icon:
						var tex = TextureRect.new()
						tex.texture = item.icon
						tex.custom_minimum_size = Vector2(16, 16)
						tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
						tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
						tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
						hbox.add_child(tex)
					var lbl = Label.new()
					lbl.text = "%d / %d" % [have, needed]
					lbl.add_theme_font_size_override("font_size", 12)
					lbl.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3) if have >= recipe_amt else Color(0.9, 0.5, 0.3))
					lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
					hbox.add_child(lbl)
					tooltip_vbox.add_child(hbox)

	# --- Storage Contents ---
	# For omnidirectional factories, also list the input buffer under the
	# Storage section so the player can see sand/graphite/etc. piling up there.
	var is_omni_storage: bool = data.tags.has("omnidirectional")
	var factory_inputs: Dictionary = {}
	if is_omni_storage and _logistics and _logistics.factory_buffers.has(origin):
		factory_inputs = _logistics.factory_buffers[origin].get("inputs", {})
	var has_factory_inputs: bool = false
	for k in factory_inputs:
		if int(factory_inputs[k]) > 0:
			has_factory_inputs = true
			break

	if _logistics and (_logistics.block_storage.has(origin) or has_factory_inputs):
		var storage_items: Dictionary = {}
		var storage_fluids: Dictionary = {}
		if _logistics.block_storage.has(origin):
			var storage = _logistics.block_storage[origin]
			storage_items = storage["items"]
			storage_fluids = storage["fluids"]
		var has_items: bool = not storage_items.is_empty()
		var has_fluids: bool = not storage_fluids.is_empty()
		if has_items or has_fluids or has_factory_inputs:
			_add_tooltip_separator()
			_add_tooltip_line("Storage:", Color(0.7, 0.75, 0.8))
			# Input buffer contents (omnidirectional factories only)
			for sn_id in factory_inputs:
				var in_count: int = int(factory_inputs[sn_id])
				if in_count <= 0:
					continue
				var in_item = Registry.get_item_or_fluid(sn_id)
				var in_name: String = in_item.display_name if in_item else str(sn_id)
				var in_max_str := ""
				if data.max_stored_items > 0:
					in_max_str = "/%d" % data.max_stored_items
				_add_tooltip_line("  %s: %d%s" % [in_name, in_count, in_max_str], Color(0.7, 0.85, 0.7))
			for item_id in storage_items:
				var count: int = int(storage_items[item_id])
				if count <= 0:
					continue
				var item = Registry.get_item_or_fluid(item_id)
				var item_name: String = item.display_name if item else str(item_id)
				var max_str := ""
				if data.max_stored_items > 0:
					max_str = "/%d" % data.max_stored_items
				_add_tooltip_line("  %s: %d%s" % [item_name, count, max_str], Color(0.8, 0.85, 0.8))
			for fluid_id in storage_fluids:
				var amount: float = float(storage_fluids[fluid_id])
				if amount <= 0:
					continue
				var fluid = Registry.get_fluid(fluid_id)
				var fluid_name: String = fluid.display_name if fluid else str(fluid_id)
				var max_str := ""
				if data.max_stored_fluids > 0:
					max_str = "/%.0f" % data.max_stored_fluids
				_add_tooltip_line("  %s: %.0f%s" % [fluid_name, amount, max_str], Color(0.7, 0.8, 0.9))

	# --- Factory Phase ---
	if _logistics and _logistics.factory_buffers.has(origin):
		var state = _logistics.factory_buffers[origin]
		var phase: String = state["phase"]
		var phase_color := Color(0.6, 0.7, 0.8)
		match phase:
			"collecting": phase_color = Color(0.8, 0.8, 0.4)
			"processing": phase_color = Color(0.4, 0.8, 0.4)
			"outputting": phase_color = Color(0.4, 0.6, 0.9)
		_add_tooltip_line("Phase: %s" % phase.capitalize(), phase_color)

	# --- Archive: show contained archive ---
	var building_sys = _building_sys_ref()
	if data.id == &"archive" and building_sys and "archive_holdings" in building_sys:
		var aid: StringName = building_sys.archive_holdings.get(origin, &"")
		if aid == &"":
			_add_tooltip_line("Contains Archive: (none — click to set)", Color(0.7, 0.6, 0.9))
		else:
			var nd = TechTree.get_node_data(aid)
			var aname: String = nd["name"] if nd else String(aid)
			_add_tooltip_line("Contains Archive: %s" % aname, Color(0.85, 0.7, 1.0))

	# --- Archive Decoder: show decoding progress ---
	if data.tags.has("archive_decoder") and building_sys and "archive_decoder_state" in building_sys:
		if building_sys.archive_decoder_state.has(origin):
			var dstate: Dictionary = building_sys.archive_decoder_state[origin]
			var did: StringName = dstate.get("archive_id", &"")
			if did == &"":
				_add_tooltip_line("Decoding Archive: (idle)", Color(0.7, 0.7, 0.7))
				# Diagnose why it's idle
				var diag := _diagnose_archive_decoder(origin)
				_add_tooltip_line("  Reason: %s" % diag, Color(0.9, 0.6, 0.3))
			else:
				var dnd = TechTree.get_node_data(did)
				var dname: String = dnd["name"] if dnd else String(did)
				_add_tooltip_line("Decoding Archive: %s" % dname, Color(0.85, 0.7, 1.0))
				var cycle: float = data.production_time if data.production_time > 0 else 8.0
				var prog: float = float(dstate.get("progress", 0.0))
				var pct: int = int(clampf(prog / cycle, 0.0, 1.0) * 100.0)
				_add_tooltip_progress_bar(pct, 100, "% Complete", Color(0.6, 0.4, 0.9))


## Returns a human-readable description of why an archive decoder is not currently
## decoding (or "ready" if it should be).
func _diagnose_archive_decoder(anchor: Vector2i) -> String:
	var power_sys = _power_sys_ref()
	if power_sys and not power_sys.is_electrical_powered(anchor):
		return "no electrical power"
	const DIRS := [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]
	var found_scanner := false
	var scanner_powered := false
	var scanner_faces_archive := false
	var archive_id_set := false
	for d in DIRS:
		var n: Vector2i = anchor + d
		if not main.placed_buildings.has(n):
			continue
		var n_anchor: Vector2i = main.building_origins.get(n, n)
		var n_data = Registry.get_block(main.placed_buildings.get(n_anchor, &""))
		if n_data == null or not n_data.tags.has("archive_scanner"):
			continue
		found_scanner = true
		if power_sys and not power_sys.is_electrical_powered(n_anchor):
			continue
		scanner_powered = true
		var rot: int = main.building_rotation.get(n_anchor, 0)
		var building_sys = _building_sys_ref()
		if building_sys == null:
			continue
		var front = building_sys._get_front_edge(n_anchor, n_data.grid_size, rot)
		for cell in front:
			if not main.placed_buildings.has(cell):
				continue
			var a_anchor: Vector2i = main.building_origins.get(cell, cell)
			var a_data = Registry.get_block(main.placed_buildings.get(a_anchor, &""))
			if a_data == null or a_data.id != &"archive":
				continue
			scanner_faces_archive = true
			var aid: StringName = building_sys.archive_holdings.get(a_anchor, &"")
			if aid != &"":
				archive_id_set = true
				if TechTree.is_researched(aid):
					return "archive '%s' already decoded" % aid
				return "ready"
	if not found_scanner:
		return "no adjacent scanner"
	if not scanner_powered:
		return "scanner has no power"
	if not scanner_faces_archive:
		return "scanner not facing an archive"
	if not archive_id_set:
		return "facing archive has no archive id set"
	return "unknown"


func _add_tooltip_line(text: String, color: Color) -> void:
	var lbl = Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", color)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tooltip_vbox.add_child(lbl)


func _add_tooltip_separator() -> void:
	var sep = HSeparator.new()
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sep.add_theme_constant_override("separation", 2)
	tooltip_vbox.add_child(sep)


func _add_tooltip_health_bar(pct: float, current: float, max_hp: float) -> void:
	var bar_container = HBoxContainer.new()
	bar_container.add_theme_constant_override("separation", 6)
	bar_container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Health bar background
	var bar_bg = ColorRect.new()
	bar_bg.custom_minimum_size = Vector2(180, 10)
	bar_bg.color = Color(0.15, 0.05, 0.05, 0.8)
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Health bar fill (drawn as child)
	var bar_fill = ColorRect.new()
	bar_fill.color = Color(0.9, 0.15, 0.15)
	bar_fill.custom_minimum_size = Vector2(180 * pct, 10)
	bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Use a panel to overlay fill on bg
	var bar_panel = Control.new()
	bar_panel.custom_minimum_size = Vector2(180, 10)
	bar_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_panel.add_child(bar_bg)
	bar_bg.position = Vector2.ZERO
	bar_bg.size = Vector2(180, 10)
	bar_panel.add_child(bar_fill)
	bar_fill.position = Vector2.ZERO
	bar_fill.size = Vector2(180 * pct, 10)

	bar_container.add_child(bar_panel)

	# Health text
	var hp_lbl = Label.new()
	hp_lbl.text = "%.0f/%.0f" % [current, max_hp]
	hp_lbl.add_theme_font_size_override("font_size", 11)
	hp_lbl.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	hp_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_container.add_child(hp_lbl)

	tooltip_vbox.add_child(bar_container)


## Adds a "Power" bar to the hover tooltip. The bar is centred: zero
## (gen == use) sits in the middle. Positive net (surplus) fills to the
## right in blue; negative net (overdraw) fills to the left in red.
## Half-bar width = one full generator rating, so +gen fills to the right
## edge and -gen fills to the left edge; more extreme values pin.
## A network with zero generators paints the whole left half red.
func _add_tooltip_power_bar(efficiency: float, gen: float, use: float) -> void:
	var bar_container = HBoxContainer.new()
	bar_container.add_theme_constant_override("separation", 6)
	bar_container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	const BAR_W: float = 180.0
	const BAR_H: float = 10.0
	var half_w: float = BAR_W * 0.5

	var bar_bg = ColorRect.new()
	bar_bg.custom_minimum_size = Vector2(BAR_W, BAR_H)
	bar_bg.color = Color(0.05, 0.05, 0.12, 0.8)
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bar_panel = Control.new()
	bar_panel.custom_minimum_size = Vector2(BAR_W, BAR_H)
	bar_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_panel.add_child(bar_bg)
	bar_bg.position = Vector2.ZERO
	bar_bg.size = Vector2(BAR_W, BAR_H)

	# Net power = gen - use. Normalize by gen so one "unit" of deficit or
	# surplus equals one full generator rating worth of travel on the bar.
	var net_val: float = gen - use
	var scale_ref: float = gen if gen > 0.0 else maxf(use, 1.0)
	var frac: float = clampf(net_val / scale_ref, -1.0, 1.0)
	var overdraw: bool = net_val < 0.0

	var fill_color: Color
	if overdraw:
		fill_color = Color(0.95, 0.3, 0.2)
	elif gen > 0.0 and use / gen >= 0.8:
		# Close to capacity — warning yellow so you notice before brownout.
		fill_color = Color(1.0, 0.85, 0.25)
	else:
		fill_color = Color(0.35, 0.7, 1.0)

	# Centre tick so the zero point is visually anchored.
	var centre_tick = ColorRect.new()
	centre_tick.color = Color(0.85, 0.85, 0.95, 0.35)
	centre_tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre_tick.position = Vector2(half_w - 0.5, 0.0)
	centre_tick.size = Vector2(1.0, BAR_H)
	bar_panel.add_child(centre_tick)

	if frac != 0.0:
		var bar_fill = ColorRect.new()
		bar_fill.color = fill_color
		bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var fill_len: float = half_w * absf(frac)
		if frac > 0.0:
			# Surplus: grow right from the midpoint.
			bar_fill.position = Vector2(half_w, 0.0)
		else:
			# Deficit: grow left from the midpoint.
			bar_fill.position = Vector2(half_w - fill_len, 0.0)
		bar_fill.size = Vector2(fill_len, BAR_H)
		bar_panel.add_child(bar_fill)

	bar_container.add_child(bar_panel)

	# Label format: "(gen - use) / gen" — the left number is the signed
	# power remaining on the network (negative when overdrawn), the right
	# number is the total generation capacity.
	var power_lbl = Label.new()
	var sign_prefix: String = "+" if net_val > 0.0 else ""
	power_lbl.text = "%s%.0f / %.0f" % [sign_prefix, net_val, gen]
	power_lbl.add_theme_font_size_override("font_size", 11)
	var lbl_color: Color = Color(0.95, 0.55, 0.5) if overdraw else Color(0.7, 0.8, 1.0)
	power_lbl.add_theme_color_override("font_color", lbl_color)
	power_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_container.add_child(power_lbl)

	tooltip_vbox.add_child(bar_container)
	# efficiency is accepted for API symmetry with the in-world bar even
	# though this tooltip derives the fill directly from gen/use. Silence
	# an unused-arg warning without dropping it from the signature.
	var _unused_eff: float = efficiency


func _add_tooltip_progress_bar(current: int, max_val: int, label_text: String, bar_color: Color) -> void:
	var pct: float = float(current) / float(max_val) if max_val > 0 else 0.0
	pct = clampf(pct, 0.0, 1.0)

	var bar_container = HBoxContainer.new()
	bar_container.add_theme_constant_override("separation", 6)
	bar_container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bar_bg = ColorRect.new()
	bar_bg.custom_minimum_size = Vector2(180, 10)
	bar_bg.color = Color(0.1, 0.07, 0.02, 0.8)
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bar_fill = ColorRect.new()
	bar_fill.color = bar_color
	bar_fill.custom_minimum_size = Vector2(180 * pct, 10)
	bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bar_panel = Control.new()
	bar_panel.custom_minimum_size = Vector2(180, 10)
	bar_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_panel.add_child(bar_bg)
	bar_bg.position = Vector2.ZERO
	bar_bg.size = Vector2(180, 10)
	bar_panel.add_child(bar_fill)
	bar_fill.position = Vector2.ZERO
	bar_fill.size = Vector2(180 * pct, 10)

	bar_container.add_child(bar_panel)

	var lbl = Label.new()
	lbl.text = "%s: %d/%d" % [label_text, current, max_val]
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.75, 0.5))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_container.add_child(lbl)

	tooltip_vbox.add_child(bar_container)


# =========================
# BUILD COST PANEL (when placing a block)
# =========================

func _create_build_cost_panel() -> void:
	build_cost_panel = PanelContainer.new()
	# Position above the block menu
	build_cost_panel.anchor_left = 1.0
	build_cost_panel.anchor_right = 1.0
	build_cost_panel.anchor_top = 1.0
	build_cost_panel.anchor_bottom = 1.0
	build_cost_panel.offset_left = -350
	build_cost_panel.offset_right = -10
	build_cost_panel.offset_bottom = -330
	build_cost_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	build_cost_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.03, 0.06, 0.85)
	style.set_corner_radius_all(8)
	style.border_color = Color(0.2, 0.3, 0.4, 0.6)
	style.set_border_width_all(1)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	build_cost_panel.add_theme_stylebox_override("panel", style)
	build_cost_panel.visible = false
	build_cost_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(build_cost_panel)

	build_cost_vbox = VBoxContainer.new()
	build_cost_vbox.add_theme_constant_override("separation", 4)
	build_cost_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	build_cost_panel.add_child(build_cost_vbox)


func _create_unit_mode_panel() -> void:
	unit_mode_panel = PanelContainer.new()
	unit_mode_panel.anchor_left = 1.0
	unit_mode_panel.anchor_right = 1.0
	unit_mode_panel.anchor_top = 1.0
	unit_mode_panel.anchor_bottom = 1.0
	unit_mode_panel.offset_left = -350
	unit_mode_panel.offset_right = -10
	unit_mode_panel.offset_bottom = -330
	unit_mode_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	unit_mode_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.04, 0.0, 0.85)
	style.set_corner_radius_all(8)
	style.border_color = Color(0.7, 0.56, 0.0, 0.6)
	style.set_border_width_all(1)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	unit_mode_panel.add_theme_stylebox_override("panel", style)
	unit_mode_panel.visible = false
	unit_mode_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(unit_mode_panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	unit_mode_panel.add_child(vbox)

	# Title
	var title = Label.new()
	title.text = "UNIT MODE"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1.0, 0.84, 0.0))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(title)

	# Separator
	var sep = HSeparator.new()
	sep.add_theme_stylebox_override("separator", StyleBoxLine.new())
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(sep)

	# Controls
	var controls := [
		["Right-click + Drag", "Box select units"],
		["Right-click unit", "Toggle select"],
	]
	for entry in controls:
		var hbox = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 8)
		hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var key_label = Label.new()
		key_label.text = entry[0]
		key_label.add_theme_font_size_override("font_size", 12)
		key_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.0, 0.8))
		key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(key_label)

		var desc_label = Label.new()
		desc_label.text = entry[1]
		desc_label.add_theme_font_size_override("font_size", 12)
		desc_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(desc_label)

		vbox.add_child(hbox)

	# Release hint
	var hint = Label.new()
	hint.text = "Release Shift to exit"
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(hint)


func _update_build_cost_panel(block_id: StringName) -> void:
	for c in build_cost_vbox.get_children():
		c.queue_free()

	var data = Registry.get_block(block_id)
	if data == null:
		build_cost_panel.visible = false
		return

	# --- Header: Icon + Name ---
	var header_hbox = HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 8)
	header_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE

	if data.icon:
		var icon_rect = TextureRect.new()
		icon_rect.texture = data.icon
		icon_rect.custom_minimum_size = Vector2(24, 24)
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		header_hbox.add_child(icon_rect)
	else:
		var sw = ColorRect.new()
		sw.custom_minimum_size = Vector2(24, 24)
		sw.color = data.color
		sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		header_hbox.add_child(sw)

	var name_lbl = Label.new()
	name_lbl.text = data.display_name
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_hbox.add_child(name_lbl)

	build_cost_vbox.add_child(header_hbox)

	# --- Build Cost ---
	if data.build_cost.is_empty():
		_add_cost_line_text("Free to build", Color(0.5, 0.8, 0.5))
	else:
		for item_id in data.build_cost:
			var required: int = int(data.build_cost[item_id])
			var rk: StringName = main._resolve_resource_key(str(item_id))
			var have: int = int(main.resources.get(rk, 0))
			var item = Registry.get_item_or_fluid(rk)
			if item == null:
				item = Registry.get_item_or_fluid(item_id)

			var cost_hbox = HBoxContainer.new()
			cost_hbox.add_theme_constant_override("separation", 6)
			cost_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE

			# Dash prefix
			var dash = Label.new()
			dash.text = "-"
			dash.add_theme_font_size_override("font_size", 13)
			dash.add_theme_color_override("font_color", Color(0.5, 0.55, 0.6))
			dash.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cost_hbox.add_child(dash)

			# Resource icon
			if item and item.icon:
				var icon_rect = TextureRect.new()
				icon_rect.texture = item.icon
				icon_rect.custom_minimum_size = Vector2(16, 16)
				icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
				cost_hbox.add_child(icon_rect)
			else:
				var sw = ColorRect.new()
				sw.custom_minimum_size = Vector2(16, 16)
				sw.color = item.color if item else Color.GRAY
				sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
				cost_hbox.add_child(sw)

			# Resource name
			var res_name = Label.new()
			res_name.text = item.display_name if item else str(item_id)
			res_name.add_theme_font_size_override("font_size", 13)
			res_name.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
			res_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			res_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cost_hbox.add_child(res_name)

			# Amount: have/required with color coding
			var have_str := Registry.format_amount(have)
			var req_str := Registry.format_amount(required)

			var have_color: Color
			var ratio := float(have) / float(required) if required > 0 else 1.0
			if ratio >= 1.0:
				have_color = Color(0.3, 0.9, 0.3)  # Green — enough
			elif ratio >= 0.5:
				have_color = Color(0.9, 0.85, 0.2)  # Yellow — at least half
			else:
				have_color = Color(0.9, 0.3, 0.3)   # Red — less than half

			var amt_hbox = HBoxContainer.new()
			amt_hbox.add_theme_constant_override("separation", 0)
			amt_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE

			var have_lbl = Label.new()
			have_lbl.text = have_str
			have_lbl.add_theme_font_size_override("font_size", 13)
			have_lbl.add_theme_color_override("font_color", have_color)
			have_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			amt_hbox.add_child(have_lbl)

			var slash_lbl = Label.new()
			slash_lbl.text = "/"
			slash_lbl.add_theme_font_size_override("font_size", 13)
			slash_lbl.add_theme_color_override("font_color", Color(0.5, 0.55, 0.6))
			slash_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			amt_hbox.add_child(slash_lbl)

			var req_lbl = Label.new()
			req_lbl.text = req_str
			req_lbl.add_theme_font_size_override("font_size", 13)
			req_lbl.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
			req_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			amt_hbox.add_child(req_lbl)

			cost_hbox.add_child(amt_hbox)
			build_cost_vbox.add_child(cost_hbox)


func _add_cost_line_text(text: String, color: Color) -> void:
	var lbl = Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", color)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	build_cost_vbox.add_child(lbl)


# =========================
# CALLBACKS
# =========================

func _on_category_pressed(cat: int) -> void:
	_select_category(cat)


func _on_building_button_pressed(block_id: StringName) -> void:
	main.select_building(block_id)


func _on_building_selected(block_id: StringName) -> void:
	_update_info_label(block_id)
	# Highlight selected block button
	for bid in building_buttons:
		var btn = building_buttons[bid] as Button
		var block = Registry.get_block(bid)
		if not block:
			continue
		if bid == block_id:
			btn.add_theme_stylebox_override("normal", _make_block_style(block.color.darkened(0.1)))
		else:
			btn.add_theme_stylebox_override("normal", _make_block_style(block.color.darkened(0.6)))


func _on_resources_changed(res: Dictionary) -> void:
	# Mark build cost panel dirty so it refreshes this frame with live counts.
	_cost_dirty = true

	for c in resource_grid.get_children():
		c.queue_free()
	resource_labels.clear()

	var count := 0
	for item in Registry.items_list:
		var amount = res.get(item.id, 0)
		if amount <= 0:
			continue

		var hbox = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 5)
		hbox.custom_minimum_size.x = 150

		if item.icon:
			var tex = TextureRect.new()
			tex.texture = item.icon
			tex.custom_minimum_size = Vector2(16, 16)
			tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			hbox.add_child(tex)
		else:
			var sw = ColorRect.new()
			sw.custom_minimum_size = Vector2(16, 16)
			sw.color = item.color if item.color else Color.GRAY
			hbox.add_child(sw)

		var name_lbl = Label.new()
		name_lbl.text = item.display_name
		name_lbl.add_theme_font_size_override("font_size", 13)
		name_lbl.add_theme_color_override("font_color", item.color)
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(name_lbl)

		var amt_lbl = Label.new()
		amt_lbl.text = Registry.format_amount(amount)
		amt_lbl.add_theme_font_size_override("font_size", 13)
		amt_lbl.add_theme_color_override("font_color", Color(0.9, 0.95, 0.9))
		amt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		hbox.add_child(amt_lbl)

		resource_grid.add_child(hbox)
		resource_labels[item.id] = amt_lbl
		count += 1

	var row_height := 24.0
	var visible_rows = min(ceili(float(count) / 3.0), 3)
	resource_scroll.custom_minimum_size.y = visible_rows * row_height
	resource_panel.visible = count > 0


func _update_info_label(block_id: StringName) -> void:
	if block_id == &"":
		info_label.text = ""
		return

	var data = Registry.get_block(block_id)
	if data == null:
		info_label.text = ""
		return

	var cost_text = ""
	for item_id in data.build_cost:
		var item = Registry.get_item_or_fluid(item_id)
		if item == null:
			item = Registry.get_item_or_fluid(StringName("mat_" + str(item_id)))
		var item_name = item.display_name if item else str(item_id)
		cost_text += "%s: %s  " % [item_name, Registry.format_amount(int(data.build_cost[item_id]))]

	if cost_text == "":
		cost_text = "Free"

	var label_text = "%s — Cost: %s" % [data.display_name, cost_text]

	var dir_names = ["Right", "Down", "Left", "Up"]
	if data.is_transport() or data.tags.has("harvester"):
		label_text += "  |  Facing: %s (Q to rotate)" % dir_names[main.placement_rotation]

	info_label.text = label_text


# =========================
# MISC BUTTON CALLBACKS
# =========================

func _on_misc_tech_tree() -> void:
	var tech_ui = get_node_or_null("/root/Main/TechTreeUI")
	if tech_ui and tech_ui.has_method("_show_ui"):
		tech_ui._show_ui()


func _on_misc_schematics() -> void:
	_show_schematic_viewer()


var _schematic_viewer: PanelContainer = null
var _schematic_list_vbox: VBoxContainer = null
var _schematic_detail_vbox: VBoxContainer = null
var _selected_schematic_name: String = ""

func _show_schematic_viewer() -> void:
	if _schematic_viewer and is_instance_valid(_schematic_viewer):
		_schematic_viewer.queue_free()

	_schematic_viewer = PanelContainer.new()
	_schematic_viewer.anchor_left = 0.5
	_schematic_viewer.anchor_right = 0.5
	_schematic_viewer.anchor_top = 0.5
	_schematic_viewer.anchor_bottom = 0.5
	_schematic_viewer.offset_left = -250
	_schematic_viewer.offset_right = 250
	_schematic_viewer.offset_top = -200
	_schematic_viewer.offset_bottom = 200
	_schematic_viewer.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_schematic_viewer.grow_vertical = Control.GROW_DIRECTION_BOTH

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.07, 0.96)
	style.set_corner_radius_all(8)
	style.set_border_width_all(1)
	style.border_color = Color(0.3, 0.35, 0.4, 0.6)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	_schematic_viewer.add_theme_stylebox_override("panel", style)
	add_child(_schematic_viewer)

	var root_vbox = VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 6)
	_schematic_viewer.add_child(root_vbox)

	# Title bar
	var title_hbox = HBoxContainer.new()
	root_vbox.add_child(title_hbox)
	var title_lbl = Label.new()
	title_lbl.text = "📋 Schematics"
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.add_theme_color_override("font_color", Color(1, 0.9, 0.3))
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_hbox.add_child(title_lbl)
	var close_btn = Button.new()
	close_btn.text = "X"
	close_btn.pressed.connect(func(): _schematic_viewer.queue_free())
	title_hbox.add_child(close_btn)

	root_vbox.add_child(HSeparator.new())

	# Content: list + detail
	var content_hbox = HBoxContainer.new()
	content_hbox.add_theme_constant_override("separation", 8)
	content_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(content_hbox)

	# Left: schematic list
	var list_panel = PanelContainer.new()
	var list_style = StyleBoxFlat.new()
	list_style.bg_color = Color(0.06, 0.07, 0.1, 0.8)
	list_style.set_corner_radius_all(4)
	list_style.content_margin_left = 4
	list_style.content_margin_right = 4
	list_style.content_margin_top = 4
	list_style.content_margin_bottom = 4
	list_panel.add_theme_stylebox_override("panel", list_style)
	list_panel.custom_minimum_size.x = 160
	list_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_hbox.add_child(list_panel)

	var list_scroll = ScrollContainer.new()
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list_panel.add_child(list_scroll)

	_schematic_list_vbox = VBoxContainer.new()
	_schematic_list_vbox.add_theme_constant_override("separation", 2)
	list_scroll.add_child(_schematic_list_vbox)

	# Right: detail panel
	_schematic_detail_vbox = VBoxContainer.new()
	_schematic_detail_vbox.add_theme_constant_override("separation", 4)
	_schematic_detail_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_schematic_detail_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_hbox.add_child(_schematic_detail_vbox)

	_refresh_schematic_list()


func _refresh_schematic_list() -> void:
	if _schematic_list_vbox == null:
		return
	for c in _schematic_list_vbox.get_children():
		c.queue_free()
	var names: PackedStringArray = SaveManager.list_schematics()
	for sname in names:
		var btn = Button.new()
		btn.text = sname
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 12)
		var captured_name: String = sname
		btn.pressed.connect(func(): _select_schematic(captured_name))
		_schematic_list_vbox.add_child(btn)

	if names.is_empty():
		var lbl = Label.new()
		lbl.text = "No schematics saved."
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_schematic_list_vbox.add_child(lbl)

	# Clear detail
	if _schematic_detail_vbox:
		for c in _schematic_detail_vbox.get_children():
			c.queue_free()


func _select_schematic(sname: String) -> void:
	_selected_schematic_name = sname
	if _schematic_detail_vbox == null:
		return
	for c in _schematic_detail_vbox.get_children():
		c.queue_free()

	var data: Variant = SaveManager.load_schematic(sname)
	if data == null:
		return

	# Name
	var name_lbl = Label.new()
	name_lbl.text = str(data.get("name", sname))
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", Color(1, 0.9, 0.3))
	_schematic_detail_vbox.add_child(name_lbl)

	# Dimensions
	var dim_lbl = Label.new()
	dim_lbl.text = "%d x %d tiles" % [data.get("width", 0), data.get("height", 0)]
	dim_lbl.add_theme_font_size_override("font_size", 11)
	dim_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_schematic_detail_vbox.add_child(dim_lbl)

	_schematic_detail_vbox.add_child(HSeparator.new())

	# Block summary
	var blocks_data: Dictionary = data.get("blocks", {})
	var block_counts: Dictionary = {}
	for key in blocks_data:
		var bid: String = blocks_data[key]
		block_counts[bid] = block_counts.get(bid, 0) + 1

	var blocks_lbl = Label.new()
	blocks_lbl.text = "Blocks (%d):" % blocks_data.size()
	blocks_lbl.add_theme_font_size_override("font_size", 12)
	_schematic_detail_vbox.add_child(blocks_lbl)

	for bid in block_counts:
		var bd = Registry.get_block(StringName(bid))
		var dn: String = bd.display_name if bd else bid
		var lbl = Label.new()
		lbl.text = "  %dx %s" % [block_counts[bid], dn]
		lbl.add_theme_font_size_override("font_size", 11)
		_schematic_detail_vbox.add_child(lbl)

	_schematic_detail_vbox.add_child(HSeparator.new())

	# Total cost
	var total_cost: Dictionary = data.get("total_cost", {})
	if not total_cost.is_empty():
		var cost_lbl = Label.new()
		cost_lbl.text = "Total Cost:"
		cost_lbl.add_theme_font_size_override("font_size", 12)
		_schematic_detail_vbox.add_child(cost_lbl)
		for item_str in total_cost:
			var item_data = Registry.get_item(StringName(item_str))
			var hbox = HBoxContainer.new()
			hbox.add_theme_constant_override("separation", 4)
			if item_data and item_data.icon:
				var tex = TextureRect.new()
				tex.texture = item_data.icon
				tex.custom_minimum_size = Vector2(14, 14)
				tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				hbox.add_child(tex)
			var clbl = Label.new()
			var dn: String = item_data.display_name if item_data else item_str
			clbl.text = "%s: %d" % [dn, int(total_cost[item_str])]
			clbl.add_theme_font_size_override("font_size", 11)
			hbox.add_child(clbl)
			_schematic_detail_vbox.add_child(hbox)

	_schematic_detail_vbox.add_child(HSeparator.new())

	# Buttons
	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	_schematic_detail_vbox.add_child(btn_row)

	var place_btn = Button.new()
	place_btn.text = "Place"
	place_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var data_ref: Dictionary = data
	place_btn.pressed.connect(func():
		var bsys = _building_sys_ref()
		if bsys:
			bsys.start_schematic_placement(data_ref)
		_schematic_viewer.queue_free()
	)
	btn_row.add_child(place_btn)

	var del_btn = Button.new()
	del_btn.text = "Delete"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var del_name: String = sname
	del_btn.pressed.connect(func():
		SaveManager.delete_schematic(del_name)
		_refresh_schematic_list()
	)
	btn_row.add_child(del_btn)


func _on_misc_database() -> void:
	var db_ui = get_node_or_null("/root/Main/DatabaseUI")
	if db_ui and db_ui.has_method("_show_ui"):
		db_ui._show_ui()


func _on_misc_planet_map() -> void:
	# Save current sector state so we can resume later
	var sector_id: String = str(SaveManager.active_sector_id)
	if sector_id != "" and sector_id != "_default":
		SaveManager.save_sector(sector_id)
	# Sync and save resources to global pool before leaving
	SaveManager.sync_active_sector_resources()
	SaveManager.save_campaign()
	# Keep active_sector_id so "Back to Game" can restore this sector
	SaveManager.return_to_game = true
	get_tree().change_scene_to_file("res://main/PlanetSelect.tscn")


# =========================
# HELPERS
# =========================

## Returns all blocks belonging to a category, sorted by display name.
func _get_blocks_for_category(cat: int) -> Array[BlockData]:
	var result: Array[BlockData] = []
	for block in Registry.blocks_list:
		if block.category == cat:
			# Hide debug-only / map-editor-only blocks from the in-game palette.
			if block.id == &"power_source" or block.id == &"archive":
				continue
			# Only show blocks that are researched in the tech tree
			if main.require_research and TechTree.nodes.has(block.id) and not TechTree.is_researched(block.id):
				continue
			result.append(block)
	result.sort_custom(func(a, b): return a.display_name < b.display_name)
	return result


# =========================
# OBJECTIVE PANEL
# =========================

func _create_objective_panel() -> void:
	objective_panel = PanelContainer.new()
	objective_panel.offset_left = 10
	objective_panel.offset_top = 90

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.08, 0.88)
	style.border_color = Color(1.0, 0.84, 0.0, 0.4)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	objective_panel.add_theme_stylebox_override("panel", style)
	objective_panel.visible = false
	objective_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(objective_panel)

	objective_vbox = VBoxContainer.new()
	objective_vbox.add_theme_constant_override("separation", 4)
	objective_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	objective_panel.add_child(objective_vbox)


func _update_objective_panel() -> void:
	var sector_script = get_node_or_null("/root/Main/SectorScript")
	if sector_script == null or not sector_script.has_method("get_current_objectives"):
		objective_panel.visible = false
		return

	var objectives: Array = sector_script.get_current_objectives()
	if objectives.is_empty():
		objective_panel.visible = false
		return

	objective_panel.visible = true

	# Rebuild content each frame (cheap — usually 1-3 objectives)
	for child in objective_vbox.get_children():
		child.queue_free()

	# Header
	var header = Label.new()
	header.text = "OBJECTIVE"
	header.add_theme_font_size_override("font_size", 13)
	header.add_theme_color_override("font_color", Color(1.0, 0.84, 0.0))
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	objective_vbox.add_child(header)

	for obj in objectives:
		var text: String = obj.get("text", "")
		var current: int = obj.get("current", 0)
		var target: int = obj.get("target", 1)
		var done: bool = obj.get("done", false)

		var hbox = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 6)
		hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		objective_vbox.add_child(hbox)

		# Checkmark or bullet
		var bullet = Label.new()
		bullet.text = "✔" if done else "▸"
		bullet.add_theme_font_size_override("font_size", 12)
		bullet.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3) if done else Color(0.8, 0.8, 0.8))
		bullet.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(bullet)

		# Objective text with progress
		var lbl = Label.new()
		if target > 1 or current > 0:
			lbl.text = "%s: %d/%d" % [text, current, target]
		else:
			lbl.text = text
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", Color(0.5, 0.8, 0.5) if done else Color(0.85, 0.88, 0.92))
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(lbl)


# =========================
# ESCAPE MENU
# =========================

func _create_escape_menu() -> void:
	escape_menu = CanvasLayer.new()
	escape_menu.layer = 200
	escape_menu.visible = false
	add_child(escape_menu)

	# Dark overlay
	var overlay = ColorRect.new()
	overlay.color = Color(0.0, 0.0, 0.0, 0.8)
	overlay.anchor_right = 1.0
	overlay.anchor_bottom = 1.0
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	escape_menu.add_child(overlay)

	# Center panel
	escape_panel = PanelContainer.new()
	escape_panel.anchor_left = 0.5
	escape_panel.anchor_right = 0.5
	escape_panel.anchor_top = 0.5
	escape_panel.anchor_bottom = 0.5
	escape_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	escape_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	style.border_color = Color(0.0, 0.0, 0.0, 0.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.content_margin_left = 24
	style.content_margin_right = 24
	style.content_margin_top = 20
	style.content_margin_bottom = 20
	escape_panel.add_theme_stylebox_override("panel", style)
	escape_menu.add_child(escape_panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	escape_panel.add_child(vbox)

	# Button grid:
	#   [Settings]        [Host Multiplayer]
	#   [Abandon]          [Save & Quit]
	#              [Back]
	var grid = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 8)
	vbox.add_child(grid)

	var btn_settings = _make_esc_button("Settings", Color(0.22, 0.22, 0.23, 1.0))
	btn_settings.pressed.connect(func():
		_close_escape_menu()
		_open_settings()
	)
	grid.add_child(btn_settings)

	var btn_host = _make_esc_button("Host Multiplayer", Color(0.22, 0.22, 0.23, 1.0))
	btn_host.pressed.connect(func(): print("HUD: Host Multiplayer — not yet implemented"))
	grid.add_child(btn_host)

	var btn_abandon = _make_esc_button("Abandon", Color(0.22, 0.22, 0.23, 1.0))
	btn_abandon.pressed.connect(_on_abandon)
	grid.add_child(btn_abandon)

	var btn_save_quit = _make_esc_button("Save & Quit", Color(0.22, 0.22, 0.23, 1.0))
	btn_save_quit.pressed.connect(_on_save_and_quit)
	grid.add_child(btn_save_quit)

	# Center the Back button below the grid
	var back_row = HBoxContainer.new()
	back_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(back_row)

	var btn_back = _make_esc_button("Back", Color(0.179, 0.179, 0.188, 1.0))
	btn_back.pressed.connect(_close_escape_menu)
	btn_back.custom_minimum_size.x = 140
	back_row.add_child(btn_back)


func _make_esc_button(text: String, color: Color) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(160, 40)
	btn.add_theme_font_size_override("font_size", 15)
	btn.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	btn.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	btn.add_theme_color_override("font_pressed_color", Color(0.8, 0.8, 0.8))

	var btn_tex = load("res://textures/UI/Button.png") as Texture2D
	if btn_tex:
		var normal_style = StyleBoxTexture.new()
		normal_style.texture = btn_tex
		normal_style.content_margin_left = 12
		normal_style.content_margin_right = 12
		normal_style.content_margin_top = 8
		normal_style.content_margin_bottom = 8
		normal_style.modulate_color = Color(color.r, color.g, color.b, 0.7)
		btn.add_theme_stylebox_override("normal", normal_style)

		var hover_style = StyleBoxTexture.new()
		hover_style.texture = btn_tex
		hover_style.content_margin_left = 12
		hover_style.content_margin_right = 12
		hover_style.content_margin_top = 8
		hover_style.content_margin_bottom = 8
		hover_style.modulate_color = Color(color.r, color.g, color.b, 0.9)
		btn.add_theme_stylebox_override("hover", hover_style)

		var pressed_style = StyleBoxTexture.new()
		pressed_style.texture = btn_tex
		pressed_style.content_margin_left = 12
		pressed_style.content_margin_right = 12
		pressed_style.content_margin_top = 8
		pressed_style.content_margin_bottom = 8
		pressed_style.modulate_color = Color(color.r * 0.8, color.g * 0.8, color.b * 0.8, 1.0)
		btn.add_theme_stylebox_override("pressed", pressed_style)
	return btn


func _open_settings() -> void:
	if not settings_ui:
		var script = load("res://main/settings_ui.gd")
		settings_ui = CanvasLayer.new()
		settings_ui.set_script(script)
		add_child(settings_ui)
	settings_ui.show_settings()


func _open_escape_menu() -> void:
	if escape_menu == null or main == null:
		return
	escape_menu_open = true
	escape_menu.visible = true
	main.world_paused = true


func _close_escape_menu() -> void:
	escape_menu_open = false
	escape_menu.visible = false
	main.world_paused = false


func _on_save_and_quit() -> void:
	_close_escape_menu()
	# Save current sector
	SaveManager.sync_active_sector_resources()
	if SaveManager.active_sector_id != &"":
		SaveManager.save_sector(SaveManager.active_sector_id)
	SaveManager.save_campaign()
	print("HUD: Saved sector and campaign. Returning to main menu.")
	get_tree().paused = false
	get_tree().change_scene_to_file("res://main/MainMenu.tscn")


func _on_abandon() -> void:
	_close_escape_menu()
	# Destroy all player cores to "lose" the sector
	var cores_to_destroy: Array[Vector2i] = []
	for grid_pos in main.placed_buildings:
		var block_id = main.placed_buildings[grid_pos]
		if block_id == &"core_shard" or block_id == &"core" or block_id.begins_with("core_"):
			var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
			if main.get_building_faction(grid_pos) == main.Faction.LUMINA:
				if not cores_to_destroy.has(anchor):
					cores_to_destroy.append(anchor)
	for anchor in cores_to_destroy:
		main.destroy_building(anchor)

	# Wipe the on-disk sector save so re-launching the sector starts fresh.
	# (main.sector_lost is set by the core-destruction flow, which stops the
	# autosave in _process from re-writing this file.)
	var sid: StringName = SaveManager.active_sector_id
	if sid != &"":
		SaveManager.delete_sector(str(sid))
		print("HUD: Abandoned sector '%s' — cores destroyed and save wiped." % sid)
	else:
		print("HUD: Abandoned sector — all player cores destroyed.")


# =========================
# SECTOR LOSS SCREEN
# =========================

func show_sector_loss() -> void:
	if loss_screen:
		return  # Already showing

	loss_screen = CanvasLayer.new()
	loss_screen.layer = 200
	loss_screen.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(loss_screen)

	# Darken background
	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.75)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	loss_screen.add_child(bg)

	# Center panel
	var panel = PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -200
	panel.offset_right = 200
	panel.offset_top = -180
	panel.offset_bottom = 180
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.04, 0.04, 0.95)
	style.border_color = Color(0.8, 0.2, 0.2, 0.7)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.content_margin_left = 20
	style.content_margin_right = 20
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", style)
	loss_screen.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	# Title
	var sector_name: String = str(SaveManager.active_sector_id).replace("_", " ").capitalize()
	if sector_name == "":
		sector_name = "Unknown"
	var title = Label.new()
	title.text = "Sector %s Lost" % sector_name
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.9, 0.25, 0.25))
	vbox.add_child(title)

	vbox.add_child(HSeparator.new())

	# Stats
	var play_minutes: int = int(main.stats_play_time) / 60
	var play_seconds: int = int(main.stats_play_time) % 60
	var stats: Array = [
		["Blocks Placed", str(main.stats_blocks_placed)],
		["Blocks Removed", str(main.stats_blocks_removed)],
		["Enemy Blocks Destroyed", str(main.stats_enemy_blocks_destroyed)],
		["Units Produced", str(main.stats_units_produced)],
		["Units Lost", str(main.stats_units_destroyed)],
		["Enemy Units Destroyed", str(main.stats_enemy_units_destroyed)],
		["Play Time", "%d:%02d" % [play_minutes, play_seconds]],
	]
	for stat in stats:
		var hbox = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 8)
		var name_lbl = Label.new()
		name_lbl.text = stat[0]
		name_lbl.add_theme_font_size_override("font_size", 14)
		name_lbl.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(name_lbl)
		var val_lbl = Label.new()
		val_lbl.text = stat[1]
		val_lbl.add_theme_font_size_override("font_size", 14)
		val_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
		val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		hbox.add_child(val_lbl)
		vbox.add_child(hbox)

	vbox.add_child(HSeparator.new())

	# OK button
	var ok_btn = Button.new()
	ok_btn.text = "OK"
	ok_btn.add_theme_font_size_override("font_size", 16)
	ok_btn.custom_minimum_size.y = 36
	ok_btn.pressed.connect(_on_sector_loss_ok)
	vbox.add_child(ok_btn)


func _on_sector_loss_ok() -> void:
	# Reset the save for this sector
	if SaveManager.active_sector_id != &"":
		var sector_id: StringName = SaveManager.active_sector_id
		SaveManager.sector_resources.erase(sector_id)
		# Delete the sector save file
		var save_path: String = "user://maps/sectors/%s.save.json" % sector_id
		if FileAccess.file_exists(save_path):
			DirAccess.remove_absolute(save_path)
		SaveManager.save_campaign()
		print("HUD: Sector '%s' save reset after loss." % sector_id)
	# Return to planet select
	get_tree().paused = false
	get_tree().change_scene_to_file("res://main/PlanetSelect.tscn")


# =========================
# CLEAN SAVE DATA DIALOG
# =========================

func _show_clean_save_dialog() -> void:
	if _clean_save_dialog and _clean_save_dialog.visible:
		_clean_save_dialog.visible = false
		return

	if not _clean_save_dialog:
		_clean_save_dialog = CanvasLayer.new()
		_clean_save_dialog.layer = 300
		add_child(_clean_save_dialog)

		# Dark overlay
		var overlay = ColorRect.new()
		overlay.color = Color(0, 0, 0, 0.7)
		overlay.anchor_right = 1.0
		overlay.anchor_bottom = 1.0
		_clean_save_dialog.add_child(overlay)

		# Center panel
		var panel = PanelContainer.new()
		panel.anchor_left = 0.5
		panel.anchor_right = 0.5
		panel.anchor_top = 0.5
		panel.anchor_bottom = 0.5
		panel.offset_left = -160
		panel.offset_right = 160
		panel.offset_top = -60
		panel.offset_bottom = 60
		var style = StyleBoxFlat.new()
		style.bg_color = Color(0.12, 0.05, 0.05, 0.95)
		style.set_corner_radius_all(10)
		style.border_color = Color(0.9, 0.2, 0.2, 0.8)
		style.set_border_width_all(2)
		style.content_margin_left = 20
		style.content_margin_right = 20
		style.content_margin_top = 16
		style.content_margin_bottom = 16
		panel.add_theme_stylebox_override("panel", style)
		_clean_save_dialog.add_child(panel)

		var vbox = VBoxContainer.new()
		vbox.add_theme_constant_override("separation", 12)
		panel.add_child(vbox)

		var title = Label.new()
		title.text = "Clean Save Data?"
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title.add_theme_font_size_override("font_size", 18)
		title.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		vbox.add_child(title)

		var desc = Label.new()
		desc.text = "This will delete ALL save data\nand return to the main menu.\nThis cannot be undone!"
		desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		desc.add_theme_font_size_override("font_size", 12)
		desc.add_theme_color_override("font_color", Color(0.8, 0.7, 0.7))
		vbox.add_child(desc)

		var btn_row = HBoxContainer.new()
		btn_row.add_theme_constant_override("separation", 16)
		btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
		vbox.add_child(btn_row)

		var cancel_btn = Button.new()
		cancel_btn.text = "Cancel"
		cancel_btn.custom_minimum_size.x = 100
		cancel_btn.pressed.connect(func(): _clean_save_dialog.visible = false)
		btn_row.add_child(cancel_btn)

		var confirm_btn = Button.new()
		confirm_btn.text = "DELETE ALL"
		confirm_btn.custom_minimum_size.x = 100
		confirm_btn.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		confirm_btn.pressed.connect(_do_clean_save_data)
		btn_row.add_child(confirm_btn)

	_clean_save_dialog.visible = true


func _do_clean_save_data() -> void:
	_clean_save_dialog.visible = false
	# Delete all files in user://maps/
	var dir = DirAccess.open("user://maps/")
	if dir:
		dir.list_dir_begin()
		var file = dir.get_next()
		while file != "":
			if not dir.current_is_dir():
				dir.remove(file)
			file = dir.get_next()
		dir.list_dir_end()
	# Reset tech tree
	TechTree.load_save_data({})
	# Reset campaign data
	SaveManager.sector_resources.clear()
	SaveManager.active_sector_id = &""
	SaveManager.pending_sector_id = &""
	SaveManager.pending_map_path = ""
	SaveManager.return_to_game = false
	SaveManager.return_to_menu = false
	# Save empty campaign
	SaveManager.save_campaign()
	print("HUD: All save data cleaned.")
	# Go to main menu
	get_tree().paused = false
	get_tree().change_scene_to_file("res://main/MainMenu.tscn")


# =========================
# UNLOCK NOTIFICATION
# =========================

func _create_unlock_notify() -> void:
	_unlock_notify_panel = PanelContainer.new()
	_unlock_notify_panel.anchor_left = 0.5
	_unlock_notify_panel.anchor_right = 0.5
	_unlock_notify_panel.offset_top = 4
	_unlock_notify_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_unlock_notify_panel.visible = false
	_unlock_notify_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_unlock_notify_panel.z_index = 50

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.12, 0.06, 0.9)
	style.border_color = Color(0.4, 0.75, 0.2, 0.6)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	_unlock_notify_panel.add_theme_stylebox_override("panel", style)
	add_child(_unlock_notify_panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_unlock_notify_panel.add_child(vbox)

	var title = Label.new()
	title.text = "Unlocked"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Color(0.4, 0.8, 0.2))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(title)

	_unlock_notify_hbox = HBoxContainer.new()
	_unlock_notify_hbox.add_theme_constant_override("separation", 6)
	_unlock_notify_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_unlock_notify_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_unlock_notify_hbox)


func _show_unlock_icon(node_id: StringName) -> void:
	# If already showing, just add to it (extend timer)
	if _unlock_notify_timer <= 0.0:
		# Clear old icons
		for child in _unlock_notify_hbox.get_children():
			child.queue_free()

	# Add icon for this node
	var icon: Texture2D = null
	if Registry.blocks.has(node_id) and Registry.blocks[node_id].icon:
		icon = Registry.blocks[node_id].icon
	elif Registry.items.has(node_id) and Registry.items[node_id].icon:
		icon = Registry.items[node_id].icon
	elif Registry.units.has(node_id) and Registry.units[node_id].icon:
		icon = Registry.units[node_id].icon

	if icon:
		var tex = TextureRect.new()
		tex.texture = icon
		tex.custom_minimum_size = Vector2(28, 28)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_unlock_notify_hbox.add_child(tex)
	else:
		# Fallback: show name as text
		var nd = TechTree.get_node_data(node_id)
		var lbl = Label.new()
		lbl.text = nd["name"] if nd else str(node_id)
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_unlock_notify_hbox.add_child(lbl)

	_unlock_notify_panel.visible = true
	_unlock_notify_panel.modulate.a = 1.0
	_unlock_notify_timer = UNLOCK_NOTIFY_DURATION
