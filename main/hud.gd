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

# Smoothed-power-display state. Keyed by the displayed building's anchor
# so switching to a different block instantly snaps to that block's
# current values, but staying on the same block animates the gen / use
# numbers toward their targets across frames instead of teleporting
# whenever a network event lands.
var _power_display_anchor: Vector2i = Vector2i(-9999, -9999)
var _power_display_gen: float = 0.0
var _power_display_use: float = 0.0
## Floor count-up rate (units / second). At 60 FPS this works out to
## ~1 unit per frame, so any change <= ~240 units shows every integer
## ticking past in order (… 97, 98, 99, 100). Larger gaps accelerate
## so a 1000-unit swing still finishes in a few seconds — see the
## ceiling-duration constant below.
const _POWER_DISPLAY_FLOOR_PER_SEC := 60.0
## Soft cap on how long the count-up takes for huge gaps. Above this
## the rate scales up so a 10 000 unit change doesn't take 3 minutes.
const _POWER_DISPLAY_MAX_DURATION := 4.0

# Cached widgets from the most recent power-bar build — updated every
# frame in _process so the count-up animates between the 0.25 s tooltip
# refreshes. Cleared / overwritten on the next rebuild.
var _power_bar_panel: Control = null
var _power_bar_fill: ColorRect = null
var _power_bar_label: Label = null
var _power_bar_half_w: float = 0.0
var _power_bar_height: float = 0.0
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
var objective_panel: PanelContainer  # legacy alias = portrait_panel
var objective_vbox: VBoxContainer
# Container wrapping the unit-portrait widgets (icon, bars, name).
# Hidden when nothing is being controlled so the panel collapses to
# just the wave / objective / capture info.
var portrait_widgets_container: VBoxContainer
# Vertical separator between the portrait widgets (left) and the
# info section (right).
var portrait_info_separator: VSeparator
# Wave-preview footer (icons of next-wave units + a "Waves" button).
# Visible only while waves are running.
var wave_footer_container: VBoxContainer  # holds horizontal separator + footer row
var wave_footer_separator: HSeparator
var wave_footer_row: HBoxContainer
var wave_icon_row: HBoxContainer
var wave_list_button: Button
var wave_skip_button: Button
# Fullscreen overlay opened by the "Waves" button.
var wave_list_overlay: CanvasLayer = null

# Hint panel (mid-left of the screen, fade-in/out tutorial bubbles)
var hint_panel: PanelContainer
var hint_text_label: RichTextLabel
var hint_ok_button: Button
var _hint_queue: Array = []  # array of hint dicts not yet shown
var _hint_current: Dictionary = {}
var _hint_alpha: float = 0.0
var _hint_target_alpha: float = 0.0
var _hint_fade_speed: float = 4.0  # seconds⁻¹
# Hint ids the HUD has already accepted into its queue/current/displayed
# pipeline. Lets us poll SectorScript's runtime each frame for newly-active
# hints without re-queueing ones we've already shown or dismissed — sidesteps
# any race between HUD._ready connecting signals and SectorScript ticking.
var _hint_seen: Dictionary = {}

# Network info panel (toggled with P; bottom-centre of the screen)
var network_info_panel: PanelContainer
var network_info_root: HBoxContainer
var network_info_left: VBoxContainer
var network_info_right: ScrollContainer
var network_info_right_vbox: VBoxContainer
var network_info_placeholder: Label
var network_info_open: bool = false
var _network_info_last_net: int = -2  # -2 = uninitialised, -1 = no network
var _network_info_avg_lbl: Label = null
var _network_info_pinned_cell: Vector2i = Vector2i(-9999, -9999)
# Network locked via the "N" key — survives panel close/reopen and hover
# changes until the player presses N again (over a different network to
# repin, or off any network to clear).
var _network_info_locked_cell: Vector2i = Vector2i(-9999, -9999)
# Power-history graph overlay
var network_graph_overlay: CanvasLayer = null
var network_graph_canvas: Control = null
var network_graph_pinned_cell: Vector2i = Vector2i(-9999, -9999)
# Cursor position over the network graph plot, in canvas-local space.
# Updated from the canvas's gui_input — `get_local_mouse_position()` and
# `get_viewport().get_mouse_position() - canvas.global_position` are
# unreliable when the canvas is nested inside two CanvasLayers, so we
# capture it directly from the InputEventMouseMotion the canvas receives.
var _network_graph_hover_pos: Vector2 = Vector2(-1, -1)
# Pause-aware "now" for the network graph. Advances each unpaused frame
# (matches PowerSystem._sample_network_history's gating) so the X-axis
# stops moving when the world is paused. Stored in seconds.
var _network_graph_clock: float = 0.0

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


## "Stored Power: 12 B (20 power for 36 s)" — total internal-battery
## charge across the network, plus the implied discharge rating using
## the user-facing 1B = 20 power × 3s convention.
func _format_stored_power_label(ps: Node, cell: Vector2i) -> String:
	if ps == null or not ps.has_method("get_network_total_internal_battery_units"):
		return "Stored Power: 0 B (20 power for 0 s)"
	var info: Dictionary = ps.get_network_total_internal_battery_units(cell)
	var b: float = float(info.get("charge_b", 0.0))
	return "Stored Power: %.0f B (20 power for %.0f s)" % [b, b * 3.0]


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
	_create_network_info_panel()
	_create_hint_panel()
	_create_escape_menu()

	_create_unlock_notify()

	main.resources_changed.connect(_on_resources_changed)
	main.building_selected.connect(_on_building_selected)
	TechTree.node_state_changed.connect(_on_tech_state_changed)
	# Surface the "Content Unlocked" popup when an archive finishes
	# decoding. The marker node (`-D-archive_id`) is hidden so the
	# normal node_state_changed → unlock-icon path skips it; we hook
	# the explicit archive_decoded signal instead.
	if main.has_signal("archive_decoded") \
			and not main.archive_decoded.is_connected(_on_archive_decoded):
		main.archive_decoded.connect(_on_archive_decoded)

	# Connect hint signals from the sector script. SectorScript lives as a
	# child of Main and is set up before HUD._ready runs in practice, but
	# guard for editor / test contexts where it may be missing.
	var sector_script = get_node_or_null("/root/Main/SectorScript")
	print("HUD._ready: sector_script = %s" % str(sector_script))
	if sector_script:
		if sector_script.has_signal("hint_show"):
			sector_script.hint_show.connect(_on_hint_show)
			print("HUD._ready: connected hint_show")
		if sector_script.has_signal("hint_hide"):
			sector_script.hint_hide.connect(_on_hint_hide)
		if sector_script.has_signal("hints_cleared"):
			sector_script.hints_cleared.connect(_on_hints_cleared)
		# A hint may have already activated before we connected — replay
		# any "active" entries so the HUD catches up.
		var hints_arr = sector_script.get("_hints")
		var rt_dict = sector_script.get("_hint_runtime")
		print("HUD._ready: catch-up _hints.size=%d, _hint_runtime.size=%d" % [
			hints_arr.size() if hints_arr is Array else -1,
			rt_dict.size() if rt_dict is Dictionary else -1
		])
		if hints_arr is Array and rt_dict is Dictionary:
			for h in hints_arr:
				var id := String(h.get("id", ""))
				if id == "":
					continue
				var rt: Dictionary = rt_dict.get(id, {})
				print("HUD._ready: hint %s state=%s" % [id, String(rt.get("state", "?"))])
				if String(rt.get("state", "")) == "active":
					_on_hint_show(h)

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
		# Crane link mode / filter menu owns Esc first — let
		# BuildingSystem._input close those before we open the escape menu.
		var bsys = get_node_or_null("/root/Main/BuildingSystem")
		if bsys and (bsys._crane_filter_menu_open or bsys._crane_link_anchor != Vector2i(-1, -1)):
			return
		# Escape menu
		if escape_menu_open:
			_close_escape_menu()
		else:
			_open_escape_menu()
		get_viewport().set_input_as_handled()
		# Cmd+Shift+\ (or Ctrl+Shift+\) = Clean Save Data
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_P \
			and not event.shift_pressed and not event.ctrl_pressed and not event.meta_pressed and not event.alt_pressed:
		# Don't steal P from text inputs (rename fields, etc.).
		var fc := get_viewport().gui_get_focus_owner()
		if fc is LineEdit or fc is TextEdit:
			return
		network_info_open = not network_info_open
		network_info_panel.visible = network_info_open
		_network_info_last_net = -2  # force refresh on next process tick
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_N \
			and not event.shift_pressed and not event.ctrl_pressed and not event.meta_pressed and not event.alt_pressed \
			and network_info_open:
		var fc2 := get_viewport().gui_get_focus_owner()
		if fc2 is LineEdit or fc2 is TextEdit:
			return
		# Resolve the cell the player is hovering. If it sits in a power
		# network (producer/consumer cell), lock onto it. Otherwise clear
		# the lock so the panel reverts to following hover.
		var camera2 = get_viewport().get_camera_2d()
		var mw2 := Vector2.ZERO
		if camera2:
			mw2 = camera2.get_screen_center_position() + (get_viewport().get_mouse_position() - get_viewport().get_visible_rect().size / 2.0) / camera2.zoom
		else:
			mw2 = get_viewport().get_mouse_position()
		var hg2: Vector2i = main.world_to_grid(mw2)
		if _network_index_for(hg2) >= 0:
			_network_info_locked_cell = hg2
		else:
			_network_info_locked_cell = Vector2i(-9999, -9999)
		_network_info_last_net = -2  # force a panel refresh
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_BACKSLASH and event.shift_pressed and (event.meta_pressed or event.ctrl_pressed):
		_show_clean_save_dialog()
		get_viewport().set_input_as_handled()


var _autosave_timer := 60.0
## Seconds between autosaves. Settable from the Settings → General panel
## (range 5..120). HUD reads it every frame, so changes apply on the
## next tick without needing a sector restart.
var autosave_interval: float = 60.0

func _process(delta: float) -> void:
	# Track play time
	if not main.world_paused and not main.sector_lost:
		main.stats_play_time += delta
	# Pause-aware clock for the network power graph + per-row
	# sparklines. Stays put when paused so the X-axis "now" doesn't
	# slide forward and the existing samples line up against a fixed
	# present.
	if not main.world_paused:
		_network_graph_clock += delta

	# Toggle whole HUD visibility with the "i" key
	if Input.is_action_just_pressed("toggle_ui"):
		visible = not visible
		var drone = _drone_ref()
		if drone:
			drone.queue_redraw()

	# Periodic auto-save
	_autosave_timer -= delta
	if _autosave_timer <= 0.0:
		_autosave_timer = clampf(autosave_interval, 5.0, 120.0)
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

	# Portrait must run before objective so the merged panel knows
	# whether the controlled-unit half is visible — _update_objective_panel
	# uses that to decide separator visibility and final panel visibility.
	_update_portrait_panel()
	_update_objective_panel()

	# Update hover tooltip / build cost panel
	var mouse_world := Vector2.ZERO
	var camera = get_viewport().get_camera_2d()
	if camera:
		mouse_world = camera.get_screen_center_position() + (get_viewport().get_mouse_position() - get_viewport().get_visible_rect().size / 2.0) / camera.zoom
	else:
		mouse_world = get_viewport().get_mouse_position()

	var hovered_grid: Vector2i = main.world_to_grid(mouse_world)

	# Unit mode owns left-click for selection / commands and the build
	# tooltip / cost panel just clutter the screen during it. Hide both
	# while in unit mode (along with the build-block menu) so the
	# player's attention stays on units. The unit-mode flag also gates
	# entering selected_building above, so a stale build-cost panel
	# can't bleed in either.
	var unit_mgr = _unit_mgr_ref()
	var in_unit_mode: bool = unit_mgr != null and "unit_mode_active" in unit_mgr and unit_mgr.unit_mode_active

	if in_unit_mode:
		block_tooltip.visible = false
		build_cost_panel.visible = false
		_last_hovered_grid = Vector2i(-9999, -9999)
		_last_cost_building = &""
	elif main.selected_building != &"":
		# Placing a block — show build cost. Rebuilds when the block changes
		# or when _cost_dirty is set (by the resources_changed signal).
		block_tooltip.visible = false
		_last_hovered_grid = Vector2i(-9999, -9999)
		if _last_cost_building != main.selected_building or _cost_dirty:
			_last_cost_building = main.selected_building
			_cost_dirty = false
			_update_build_cost_panel(main.selected_building)
		build_cost_panel.visible = true
	elif main.placed_buildings.has(hovered_grid) \
			and main.get_building_faction(hovered_grid) == main.Faction.LUMINA:
		# Hovering over one of the player's own placed blocks — show
		# tooltip. Enemy / derelict blocks are excluded here so the
		# empty PanelContainer (whose children _update_block_tooltip
		# would have cleared) doesn't flash as a thin bar on hover.
		build_cost_panel.visible = false
		_last_cost_building = &""
		# Rebuild if hovered cell changed, or periodically for live data
		_tooltip_refresh_timer -= delta
		if hovered_grid != _last_hovered_grid or _tooltip_refresh_timer <= 0:
			_last_hovered_grid = hovered_grid
			_tooltip_refresh_timer = TOOLTIP_REFRESH_INTERVAL
			_update_block_tooltip(hovered_grid)
		# Per-frame power bar smoothing — runs between rebuilds so the
		# count-up animates instead of stepping every 0.25 s.
		_tick_power_bar_display(delta)
		block_tooltip.visible = true
	else:
		# Neither — hide both
		block_tooltip.visible = false
		build_cost_panel.visible = false
		_last_hovered_grid = Vector2i(-9999, -9999)
		_last_cost_building = &""

	# Block-place menu mirrors the unit-mode hide so the right-side build
	# panel collapses while you're commanding units.
	if block_menu:
		block_menu.visible = not in_unit_mode

	# Show unit mode panel when shift is held
	# Unit mode panel — visible whenever the UnitManager is in unit mode.
	unit_mode_panel.visible = in_unit_mode

	# (Portrait + objective are updated together earlier in _process so
	#  the merged panel resolves visibility in a single pass.)

	# Hint panel — fade in/out and rotate the queue.
	_tick_hint_panel(delta)

	# Network info panel (P toggle) — refresh against the hovered cell.
	if network_info_open:
		_update_network_info_panel(hovered_grid)

	# Live-redraw the graph overlay while it's open.
	if network_graph_overlay and is_instance_valid(network_graph_overlay) \
			and network_graph_overlay.visible \
			and network_graph_canvas and is_instance_valid(network_graph_canvas):
		# Poll the cursor each frame too — the canvas's gui_input only
		# fires while the mouse is moving, so a stationary cursor
		# wouldn't update `_network_graph_hover_pos` and the white line
		# never re-rendered after the first move-out. `get_local_mouse_position`
		# was unreliable inside the nested CanvasLayer; using viewport
		# space minus the canvas's screen position works.
		var poll_pos: Vector2 = get_viewport().get_mouse_position() - network_graph_canvas.get_screen_position()
		var canvas_size: Vector2 = network_graph_canvas.size
		if poll_pos.x >= 0.0 and poll_pos.y >= 0.0 \
				and poll_pos.x <= canvas_size.x and poll_pos.y <= canvas_size.y:
			_network_graph_hover_pos = poll_pos
		else:
			_network_graph_hover_pos = Vector2(-1, -1)
		network_graph_canvas.queue_redraw()


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

	# Outer vbox: top row is the merged portrait + info section, bottom
	# row is the wave-preview footer (only visible while waves run).
	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 6)
	root_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait_panel.add_child(root_vbox)

	# The merged top row arranges its two sections horizontally:
	# portrait widgets on the left, wave/objective/capture info on the
	# right.
	var main_hbox = HBoxContainer.new()
	main_hbox.add_theme_constant_override("separation", 8)
	main_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_vbox.add_child(main_hbox)

	# Wrapper for the portrait-specific widgets so we can hide all of
	# them at once when nothing's being controlled (and only render the
	# wave/objective/capture info section beside it).
	portrait_widgets_container = VBoxContainer.new()
	portrait_widgets_container.add_theme_constant_override("separation", 4)
	portrait_widgets_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_hbox.add_child(portrait_widgets_container)

	# --- Content row: [left bar] [icon] [right bars] ---
	var content_hbox = HBoxContainer.new()
	content_hbox.add_theme_constant_override("separation", 4)
	content_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait_widgets_container.add_child(content_hbox)

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
	portrait_widgets_container.add_child(portrait_name_label)

	# Vertical separator between the portrait section (left) and the
	# wave/objective/capture info section (right) — visible only when
	# both halves have content so a panel that's just info doesn't get
	# a stray vertical line.
	var v_sep := VSeparator.new()
	v_sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v_sep.visible = false
	main_hbox.add_child(v_sep)
	portrait_info_separator = v_sep

	objective_vbox = VBoxContainer.new()
	objective_vbox.add_theme_constant_override("separation", 4)
	objective_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_hbox.add_child(objective_vbox)
	# Keep the legacy alias so older code paths that touch
	# `objective_panel` still resolve to a valid Control.
	objective_panel = portrait_panel

	# Wave footer: separator + (next-wave unit icons | Waves button).
	# Wrapped in a VBox so the whole footer can be hidden as a unit when
	# no waves are running, and shown to expand the panel down slightly
	# while they are.
	wave_footer_container = VBoxContainer.new()
	wave_footer_container.add_theme_constant_override("separation", 4)
	wave_footer_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wave_footer_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wave_footer_container.visible = false
	root_vbox.add_child(wave_footer_container)

	wave_footer_separator = HSeparator.new()
	wave_footer_separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wave_footer_container.add_child(wave_footer_separator)

	wave_footer_row = HBoxContainer.new()
	wave_footer_row.add_theme_constant_override("separation", 4)
	wave_footer_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wave_footer_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wave_footer_container.add_child(wave_footer_row)

	# Left side: row of icons of the units in the next wave.
	wave_icon_row = HBoxContainer.new()
	wave_icon_row.add_theme_constant_override("separation", 2)
	wave_icon_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wave_icon_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wave_footer_row.add_child(wave_icon_row)

	# Right side: a small vertical stack of buttons locked to the right
	# edge — Skip on top, Waves below. Skip zeroes the WaveManager's
	# countdown so the next wave spawns this tick; Waves opens the
	# fullscreen overlay.
	var wave_button_stack := VBoxContainer.new()
	wave_button_stack.add_theme_constant_override("separation", 2)
	wave_button_stack.size_flags_horizontal = Control.SIZE_SHRINK_END
	wave_button_stack.mouse_filter = Control.MOUSE_FILTER_PASS
	wave_footer_row.add_child(wave_button_stack)

	wave_skip_button = Button.new()
	wave_skip_button.text = "Skip"
	wave_skip_button.add_theme_font_size_override("font_size", 12)
	wave_skip_button.custom_minimum_size = Vector2(72, 24)
	wave_skip_button.pressed.connect(_on_wave_skip_pressed)
	wave_button_stack.add_child(wave_skip_button)

	wave_list_button = Button.new()
	wave_list_button.text = "Waves"
	wave_list_button.add_theme_font_size_override("font_size", 12)
	wave_list_button.custom_minimum_size = Vector2(72, 24)
	wave_list_button.pressed.connect(_open_wave_list_overlay)
	wave_button_stack.add_child(wave_list_button)


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
	# Portrait section is always visible — the default branch below
	# falls through to drawing the player drone when nothing else is
	# controlled, so there's always *some* entity to portray.
	if portrait_widgets_container != null:
		portrait_widgets_container.visible = true

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
			# Left bar: health (anchor-keyed; one HP pool per building).
			var hp_anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
			var hp: float = main.building_health.get(hp_anchor, bdata.max_health if bdata else 100.0)
			var max_hp: float = bdata.max_health if bdata else 100.0
			var hp_pct: float = hp / max_hp if max_hp > 0 else 0.0
			var hp_color: Color = Color(1.0 - hp_pct, hp_pct, 0.0)
			portrait_left_bar_fill.color = hp_color
			_set_portrait_bar(portrait_left_bar_fill, hp_pct)
			# Right bar 1: cooldown (yellow). _update_turrets skips
			# manually-controlled turrets, so combat.turret_cooldowns
			# is frozen for the duration of control. Read from the
			# unit_manager's live `_control_attack_timer` instead so the
			# bar actually ticks down between manual shots.
			portrait_right_bar_1_fill.color = Color(0.9, 0.85, 0.2)
			portrait_right_bar_1_bg.color = Color(0.12, 0.1, 0.02, 0.8)
			var cd: float = 0.0
			var max_cd: float = bdata.attack_speed if bdata else 1.0
			if unit_mgr and "_control_attack_timer" in unit_mgr:
				cd = float(unit_mgr._control_attack_timer)
			elif combat and combat.turret_cooldowns.has(grid_pos):
				cd = combat.turret_cooldowns[grid_pos]
			var cd_pct: float = 1.0 - (cd / max_cd) if max_cd > 0 and cd > 0 else 1.0
			_set_portrait_bar(portrait_right_bar_1_fill, cd_pct)
			# Right bar 2: ammo (orange) — sums every AmmoType the turret
			# accepts and fills against the block's storage cap so the
			# bar reflects the live magazine.
			var ammo_pct: float = 0.0
			var ammo_visible: bool = false
			if bdata and not bdata.ammo_types.is_empty() and _logistics:
				var ammo_anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
				var ammo_have: int = 0
				for ammo in bdata.ammo_types:
					if ammo is AmmoType:
						ammo_have += _logistics.get_stored_item_count(ammo_anchor, (ammo as AmmoType).item_id)
				var ammo_cap: int = bdata.max_stored_items if bdata.max_stored_items > 0 else 100
				ammo_pct = clampf(float(ammo_have) / float(ammo_cap), 0.0, 1.0)
				ammo_visible = true
			portrait_right_bar_2_container.visible = ammo_visible
			if ammo_visible:
				portrait_right_bar_2_fill.color = Color(0.95, 0.55, 0.15)
				_set_portrait_bar(portrait_right_bar_2_fill, ammo_pct)
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

	_add_misc_button("⬡", "Tech Tree", _on_misc_tech_tree, preload("res://textures/UI/TechTreeIcon.png"))
	_add_misc_button("📋", "Schematics", _on_misc_schematics)
	_add_misc_button("📖", "Database", _on_misc_database, preload("res://textures/UI/CoreDatabaseIcon.png"))
	_add_misc_button("🌍", "Planet Map", _on_misc_planet_map, preload("res://textures/UI/TarkonIcon.png"))

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


func _add_misc_button(icon_text: String, tooltip: String, callback: Callable, icon_tex: Texture2D = null) -> void:
	var btn = Button.new()
	btn.custom_minimum_size = Vector2(BLOCK_BTN_SIZE, BLOCK_BTN_SIZE)

	if icon_tex != null:
		btn.icon = icon_tex
		btn.expand_icon = true
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.add_theme_constant_override("icon_max_width", 22)
	else:
		btn.text = icon_text
		btn.tooltip_text = tooltip
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

	var normal_style: StyleBox
	var hover_style: StyleBox
	var pressed_style: StyleBox
	if block.icon:
		# Icon already reads as the block — drop the swatch backdrop so
		# textured tiles sit on transparent buttons. Hover / pressed
		# darken the cell with a translucent black overlay (instead of
		# brightening, which read as "lit up the empty button").
		var empty := StyleBoxEmpty.new()
		empty.content_margin_left = 2
		empty.content_margin_right = 2
		empty.content_margin_top = 2
		empty.content_margin_bottom = 2
		normal_style = empty
		hover_style = _make_block_style(Color(0, 0, 0, 0.25))
		pressed_style = _make_block_style(Color(0, 0, 0, 0.4))
	else:
		normal_style = _make_block_style(block.color.darkened(0.6))
		hover_style = _make_block_style(block.color.darkened(0.3))
		pressed_style = _make_block_style(block.color.darkened(0.1))
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
	# Stale power-bar widget refs from the previous tooltip — null them
	# out before potentially re-adding so the per-frame tick doesn't
	# write into queue_freed nodes.
	_power_bar_panel = null
	_power_bar_fill = null
	_power_bar_label = null

	if not main.placed_buildings.has(grid_pos):
		block_tooltip.visible = false
		return

	# Tooltip is for the player's own blocks only — keeps enemy /
	# derelict structures from leaking their internal state.
	if main.get_building_faction(grid_pos) != main.Faction.LUMINA:
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
	var hp_anchor_tt: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var current_health: float = main.building_health.get(hp_anchor_tt, data.max_health)
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
					float(info.get("use", 0.0)),
					origin
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

	# (Conveyor "Carrying:" line removed — what's on the belt is
	# already visible in the world.)

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
		# Geyser miners (mineral extractor) sit on a single geyser tile
		# and don't read front-edge ore at all — placement validation
		# already guarantees they're on a geyser, so they're 100% as
		# long as they have power. Reading front-edge ore for these
		# would always hit 0% and report a broken extractor.
		var is_geyser_miner: bool = data.tags.has("geyser_miner")
		# Floor miners (ground scraper) read every ore tile UNDER their
		# footprint — not the front edge. Each extra tile adds 25%, so
		# the tooltip needs the same `_floor_miner_efficiency` math
		# the production tick uses; otherwise the front-edge scan
		# always reports 0% and the player can't tell whether the
		# scraper is even working.
		var is_floor_miner: bool = data.tags.has("floor_miner")
		if terrain and not is_geyser_miner and not is_floor_miner:
			# Walk up to mine_range tiles beyond each front-edge cell —
			# matches the actual mining loop in _update_drills so a
			# plasma bore that reaches ore 4 tiles away shows 100%
			# instead of 0%.
			var max_extend: int = maxi(data.mine_range, 1)
			var accepted_walls_hud: Array = data.accepted_walls if data.accepted_walls.size() > 0 \
					else [&"blackstone_wall"]
			for cell in front_cells:
				var any_hit: bool = false
				if is_wall_miner:
					var wid_h: StringName = StringName(terrain.wall_tiles.get(cell, &""))
					if terrain.get_ore_at(cell) == null and accepted_walls_hud.has(wid_h):
						any_hit = true
					else:
						for step in range(1, max_extend + 1):
							var scan: Vector2i = cell + dir * step
							var wid_hs: StringName = StringName(terrain.wall_tiles.get(scan, &""))
							if terrain.get_ore_at(scan) == null and accepted_walls_hud.has(wid_hs):
								any_hit = true
								break
				else:
					if terrain.get_ore_at(cell) != null:
						any_hit = true
					else:
						for step in range(1, max_extend + 1):
							if terrain.get_ore_at(cell + dir * step) != null:
								any_hit = true
								break
				if any_hit:
					hit_count += 1
		var ore_eff: float
		if is_geyser_miner:
			ore_eff = 1.0
		elif is_floor_miner:
			ore_eff = _logistics._floor_miner_efficiency(origin, data.grid_size) if _logistics else 0.0
		else:
			ore_eff = float(hit_count) / float(front_count) if front_count > 0 else 1.0
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
		var out_per_cycle: float = 0.0
		for _out_id in data.output_items:
			out_per_cycle += float(data.output_items[_out_id])
		if out_per_cycle <= 0.0:
			out_per_cycle = 1.0
		var rate: float = out_per_cycle / effective_cycle if effective_cycle > 0 else 0.0
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

	# (Generator "Generates:" line removed — production reads are in the
	# network info panel.)

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

		# Factory: show input requirements and what's buffered.
		# Unit fabricators consume the produced unit's build_cost rather
		# than the BlockData's input_items (which often only lists one
		# token ingredient). Resolve the effective recipe the same way
		# _update_factories does before rendering the status bars.
		# Refabricators additionally support per-tier-2 overrides via
		# `refab_recipes` — pick up the currently-selected tier-2's recipe
		# when there is one, else fall back to `input_items`.
		elif (not data.input_items.is_empty() or data.produced_unit != &"") and _logistics.factory_buffers.has(origin):
			var fb = _logistics.factory_buffers[origin]
			var inputs: Dictionary = fb.get("inputs", {})
			var effective_recipe: Dictionary = data.input_items
			if data.produced_unit != &"":
				var unit_res = Registry.get_unit(data.produced_unit)
				if unit_res and not unit_res.build_cost.is_empty():
					effective_recipe = unit_res.build_cost
			if data.tags.has("refabricator") and "refabricator_state" in _logistics \
					and _logistics.refabricator_state.has(origin):
				var rst: Dictionary = _logistics.refabricator_state[origin]
				var rsel: StringName = StringName(rst.get("selected_t2", &""))
				if rsel != &"" and data.refab_recipes.has(rsel):
					var custom = data.refab_recipes[rsel]
					if custom is Dictionary and not custom.is_empty():
						effective_recipe = custom
			if _logistics.has_method("_normalize_item_keys"):
				effective_recipe = _logistics._normalize_item_keys(effective_recipe)
			# Omnidirectional factories buffer inputs up to max_stored_items.
			var is_omni_bldg: bool = data.tags.has("omnidirectional")
			# Refabricators are also omni-buffered (they can over-fill past
			# the recipe amount up to max_stored_items, and they hold
			# materials between unit feeds). Show the inputs panel any time
			# a tier-2 is selected so the player can verify what's already
			# stocked before the next tier-1 arrives.
			var rsel_for_panel: StringName = &""
			if data.tags.has("refabricator") and "refabricator_state" in _logistics \
					and _logistics.refabricator_state.has(origin):
				rsel_for_panel = StringName(_logistics.refabricator_state[origin].get("selected_t2", &""))
			var is_refab_with_t2: bool = data.tags.has("refabricator") and rsel_for_panel != &""
			var has_need := false
			for raw_id in effective_recipe:
				var sn_id := StringName(raw_id)
				var needed: int = int(effective_recipe[raw_id])
				var have: int = int(inputs.get(sn_id, 0))
				if have < needed:
					has_need = true
					break
			if has_need or is_omni_bldg or is_refab_with_t2:
				_add_tooltip_separator()
				for raw_id in effective_recipe:
					var sn_id := StringName(raw_id)
					var recipe_amt: int = int(effective_recipe[raw_id])
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

	# (Storage section removed — block menus surface their own
	# storage panel when the player clicks in.)

	# --- Loader / Unloader held payload (and its stored items) ---
	# Loaders / unloaders carry a building payload around. Surface what
	# they're holding (and what's inside it) the same way fabricators
	# surface what they're producing — only in the tooltip, not in-world.
	var is_loader: bool = data.tags.has("payload_loader") or data.tags.has("freight_loader")
	var is_unloader: bool = data.tags.has("payload_unloader") or data.tags.has("freight_unloader")
	if _logistics and (is_loader or is_unloader):
		var lpayload: Dictionary = {}
		var lphase: String = ""
		if is_loader and "loader_state" in _logistics and _logistics.loader_state.has(origin):
			var ls: Dictionary = _logistics.loader_state[origin]
			lphase = String(ls.get("phase", ""))
			if ls.get("payload") != null and ls["payload"] is Dictionary:
				lpayload = ls["payload"]
		elif is_unloader and "unloader_state" in _logistics and _logistics.unloader_state.has(origin):
			var us: Dictionary = _logistics.unloader_state[origin]
			lphase = String(us.get("phase", ""))
			if us.get("payload") != null and us["payload"] is Dictionary:
				lpayload = us["payload"]
		if not lpayload.is_empty():
			_add_tooltip_separator()
			var ptype: String = String(lpayload.get("type", ""))
			if ptype == "building":
				var bd: BlockData = Registry.get_block(StringName(lpayload.get("block_id", "")))
				var bn: String = bd.display_name if bd else String(lpayload.get("block_id", "?"))
				_add_tooltip_line("Holding: %s" % bn, Color(0.7, 0.85, 1.0))
			elif ptype == "unit":
				var ud = Registry.get_unit(StringName(lpayload.get("unit_id", "")))
				var un: String = ud.display_name if ud else String(lpayload.get("unit_id", "?"))
				_add_tooltip_line("Holding: %s" % un, Color(0.7, 0.85, 1.0))

	# Refabricator: keep the "Selected Unit: (none — click to pick)"
	# nudge when nothing's queued (it's a call to action, not status).
	# The "Producing:" / "Phase:" lines + the held / output unit echo
	# are dropped — picking the t2 is in the world menu, and the input
	# bars above already convey progress. Plain factories drop the
	# phase line for the same reason.
	var is_refab: bool = data.tags.has("refabricator")
	if _logistics and is_refab and "refabricator_state" in _logistics and _logistics.refabricator_state.has(origin):
		var rstate: Dictionary = _logistics.refabricator_state[origin]
		var sel_t2: StringName = StringName(rstate.get("selected_t2", &""))
		if sel_t2 == &"":
			_add_tooltip_line("Selected Unit: (none — click to pick)", Color(0.9, 0.7, 0.3))

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
	# Walk the decoder's full footprint perimeter so the diagnostic
	# matches what the actual decoder tick checks (4-DIR-from-anchor was
	# blind to anything next to a non-anchor tile of a multi-tile decoder).
	var building_sys = _building_sys_ref()
	if building_sys == null:
		return "unknown"
	var dec_data = Registry.get_block(main.placed_buildings.get(anchor, &""))
	var dec_size: Vector2i = dec_data.grid_size if dec_data else Vector2i.ONE
	var perimeter: Array[Vector2i] = building_sys._get_block_perimeter_cells(anchor, dec_size)
	var found_scanner := false
	var scanner_powered := false
	var scanner_faces_archive := false
	var archive_id_set := false
	var seen_scanners: Dictionary = {}
	for n in perimeter:
		if not main.placed_buildings.has(n):
			continue
		var n_anchor: Vector2i = main.building_origins.get(n, n)
		if seen_scanners.has(n_anchor):
			continue
		seen_scanners[n_anchor] = true
		var n_data = Registry.get_block(main.placed_buildings.get(n_anchor, &""))
		if n_data == null or not n_data.tags.has("archive_scanner"):
			continue
		found_scanner = true
		if power_sys and not power_sys.is_electrical_powered(n_anchor):
			continue
		scanner_powered = true
		var rot: int = main.building_rotation.get(n_anchor, 0)
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
## Moves `current` toward `target` by at most a per-frame budget. Budget
## is `max(absolute, fraction * gap)` so small gaps tick at a steady
## rate (visible 1-by-1 counting) and huge gaps still close in finite
## time. Snaps when within one unit so the readout settles on the
## target integer cleanly.
func _step_toward_display(current: float, target: float, dt: float) -> float:
	var gap: float = target - current
	var abs_gap: float = absf(gap)
	if abs_gap < 1.0:
		return target
	# Default rate gives ~1 unit per frame at 60 FPS so the integer
	# readout visibly counts up. For big gaps the rate scales so the
	# whole animation still finishes within `_POWER_DISPLAY_MAX_DURATION`.
	var rate: float = maxf(_POWER_DISPLAY_FLOOR_PER_SEC, abs_gap / _POWER_DISPLAY_MAX_DURATION)
	var step: float = rate * dt
	if step >= abs_gap:
		return target
	return current + sign(gap) * step


func _add_tooltip_power_bar(efficiency: float, gen: float, use: float, anchor: Vector2i = Vector2i(-9999, -9999)) -> void:
	# Smoothing target tracking: switching to a different building snaps
	# the smoothed values to the new live numbers. Otherwise the per-
	# frame `_tick_power_bar_display` keeps animating toward whatever
	# the live network reports — so the readout counts up smoothly
	# between the 0.25 s tooltip rebuilds.
	if anchor != _power_display_anchor:
		_power_display_anchor = anchor
		_power_display_gen = gen
		_power_display_use = use
	var smooth_gen: float = _power_display_gen
	var smooth_use: float = _power_display_use

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
	var net_val: float = smooth_gen - smooth_use
	var scale_ref: float = smooth_gen if smooth_gen > 0.0 else maxf(smooth_use, 1.0)
	var frac: float = clampf(net_val / scale_ref, -1.0, 1.0)
	var overdraw: bool = net_val < 0.0

	var fill_color: Color
	if overdraw:
		fill_color = Color(0.95, 0.3, 0.2)
	elif smooth_gen > 0.0 and smooth_use / smooth_gen >= 0.8:
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

	# Always create the fill ColorRect so the per-frame tick can adjust
	# its size / position without rebuilding the node tree. Sized to
	# zero when frac == 0.
	var bar_fill := ColorRect.new()
	bar_fill.color = fill_color
	bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if frac != 0.0:
		var fill_len: float = half_w * absf(frac)
		if frac > 0.0:
			bar_fill.position = Vector2(half_w, 0.0)
		else:
			bar_fill.position = Vector2(half_w - fill_len, 0.0)
		bar_fill.size = Vector2(fill_len, BAR_H)
	else:
		bar_fill.position = Vector2(half_w, 0.0)
		bar_fill.size = Vector2(0.0, BAR_H)
	bar_panel.add_child(bar_fill)

	bar_container.add_child(bar_panel)

	# Label format: "(gen - use) / gen" — the left number is the signed
	# power remaining on the network (negative when overdrawn), the right
	# number is the total generation capacity.
	var power_lbl = Label.new()
	var sign_prefix: String = "+" if net_val > 0.0 else ""
	power_lbl.text = "%s%.0f / %.0f" % [sign_prefix, net_val, smooth_gen]
	power_lbl.add_theme_font_size_override("font_size", 11)
	var lbl_color: Color = Color(0.95, 0.55, 0.5) if overdraw else Color(0.7, 0.8, 1.0)
	power_lbl.add_theme_color_override("font_color", lbl_color)
	power_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_container.add_child(power_lbl)

	tooltip_vbox.add_child(bar_container)
	# Cache widget refs + dimensions so _tick_power_bar_display can
	# update label text and fill size every frame between the (0.25 s)
	# tooltip rebuilds. The _power_display_anchor was already set
	# above and survives the rebuild.
	_power_bar_panel = bar_panel
	_power_bar_fill = bar_fill
	_power_bar_label = power_lbl
	_power_bar_half_w = half_w
	_power_bar_height = BAR_H
	# efficiency is accepted for API symmetry with the in-world bar even
	# though this tooltip derives the fill directly from gen/use. Silence
	# an unused-arg warning without dropping it from the signature.
	var _unused_eff: float = efficiency


## Per-frame updater for the power bar: ticks the smoothed gen / use
## toward whatever the live network reports for the current anchor and
## rewrites the label text + fill rect in place. Keeps the count-up
## animation smooth between the 0.25 s tooltip rebuilds.
func _tick_power_bar_display(delta: float) -> void:
	if _power_bar_panel == null or not is_instance_valid(_power_bar_panel):
		_power_bar_panel = null
		_power_bar_fill = null
		_power_bar_label = null
		return
	if _power_display_anchor == Vector2i(-9999, -9999):
		return
	var ps = _power_sys_ref()
	if ps == null:
		return
	var info: Dictionary = ps.get_electrical_network_info(_power_display_anchor)
	var target_gen: float = float(info.get("gen", 0.0))
	var target_use: float = float(info.get("use", 0.0))
	_power_display_gen = _step_toward_display(_power_display_gen, target_gen, delta)
	_power_display_use = _step_toward_display(_power_display_use, target_use, delta)

	var smooth_gen: float = _power_display_gen
	var smooth_use: float = _power_display_use
	var net_val: float = smooth_gen - smooth_use
	var scale_ref: float = smooth_gen if smooth_gen > 0.0 else maxf(smooth_use, 1.0)
	var frac: float = clampf(net_val / scale_ref, -1.0, 1.0)
	var overdraw: bool = net_val < 0.0

	# Label
	if _power_bar_label and is_instance_valid(_power_bar_label):
		var sign_prefix: String = "+" if net_val > 0.0 else ""
		_power_bar_label.text = "%s%.0f / %.0f" % [sign_prefix, net_val, smooth_gen]
		_power_bar_label.add_theme_color_override("font_color",
			Color(0.95, 0.55, 0.5) if overdraw else Color(0.7, 0.8, 1.0))

	# Fill rect
	if _power_bar_fill and is_instance_valid(_power_bar_fill):
		var fill_color: Color
		if overdraw:
			fill_color = Color(0.95, 0.3, 0.2)
		elif smooth_gen > 0.0 and smooth_use / smooth_gen >= 0.8:
			fill_color = Color(1.0, 0.85, 0.25)
		else:
			fill_color = Color(0.35, 0.7, 1.0)
		_power_bar_fill.color = fill_color
		if frac == 0.0:
			_power_bar_fill.position = Vector2(_power_bar_half_w, 0.0)
			_power_bar_fill.size = Vector2(0.0, _power_bar_height)
		else:
			var fill_len: float = _power_bar_half_w * absf(frac)
			if frac > 0.0:
				_power_bar_fill.position = Vector2(_power_bar_half_w, 0.0)
			else:
				_power_bar_fill.position = Vector2(_power_bar_half_w - fill_len, 0.0)
			_power_bar_fill.size = Vector2(fill_len, _power_bar_height)


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
			if block.icon:
				# Selected textured tile: dark overlay + bright border so
				# the icon reads as picked without lightening the swatch.
				var sel := _make_block_style(Color(0, 0, 0, 0.35))
				sel.border_color = block.color.lightened(0.4)
				sel.set_border_width_all(2)
				btn.add_theme_stylebox_override("normal", sel)
			else:
				btn.add_theme_stylebox_override("normal", _make_block_style(block.color.darkened(0.1)))
		elif block.icon:
			# Textured tiles use a transparent normal so the icon reads
			# without a coloured swatch behind it.
			var empty := StyleBoxEmpty.new()
			empty.content_margin_left = 2
			empty.content_margin_right = 2
			empty.content_margin_top = 2
			empty.content_margin_bottom = 2
			btn.add_theme_stylebox_override("normal", empty)
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
	# Park the live Main scene under SaveManager so coming back to it
	# from PlanetSelect is instant — no save / reload / black frame.
	# We still flush resources to the global pool so the planet view's
	# Global Resources panel reflects what the sector currently holds.
	SaveManager.sync_active_sector_resources()
	SaveManager.return_to_game = true
	var main_scene: Node = get_tree().current_scene
	if not SaveManager.park_main_for_planet_view(main_scene):
		# Park failed — fall back to the disk roundtrip so we don't
		# leave the player stuck in a half-detached state.
		var sector_id: String = str(SaveManager.active_sector_id)
		if sector_id != "" and sector_id != "_default":
			SaveManager.save_sector(sector_id)
		SaveManager.save_campaign()
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
	# In the Units category, push payload-handling blocks to the bottom
	# (after the proper unit-related blocks). Within each group entries
	# stay alphabetical.
	if cat == BlockData.BlockCategory.UNITS:
		result.sort_custom(func(a, b):
			var ap: int = 1 if (a.tags.has("payload") or a.tags.has("freight") \
					or a.tags.has("crane") or a.tags.has("constructor") \
					or a.tags.has("deconstructor")) else 0
			var bp: int = 1 if (b.tags.has("payload") or b.tags.has("freight") \
					or b.tags.has("crane") or b.tags.has("constructor") \
					or b.tags.has("deconstructor")) else 0
			if ap != bp:
				return ap < bp
			return a.display_name < b.display_name)
	else:
		result.sort_custom(func(a, b): return a.display_name < b.display_name)
	return result


# =========================
# OBJECTIVE PANEL
# =========================

func _create_objective_panel() -> void:
	# The objective UI lives inside `portrait_panel` now (see
	# _create_portrait_panel) so the two share one rectangle. This stub
	# is kept for back-compat with the old call site in _ready and is a
	# no-op — `objective_vbox` and the alias `objective_panel` were
	# already wired up in _create_portrait_panel.
	pass


func _update_objective_panel() -> void:
	# Renders the info section beneath the controlled-unit portrait:
	#   1. While waves are running, the current wave + countdown to the
	#      next one ("Wave N/M", "Time Until Next Wave: …").
	#   2. The current sector objective list.
	#   3. If the sector is captured, a gray "Sector Captured" line in
	#      place of the objectives.
	# The whole portrait_panel becomes visible whenever any of those
	# (or the unit portrait) has content to show.
	for child in objective_vbox.get_children():
		child.queue_free()

	var any_info := false

	# --- Wave info ---
	var wave_info: Dictionary = _get_wave_info_for_panel()
	if not wave_info.is_empty():
		any_info = true
		var wave_state: String = String(wave_info.get("state", "countdown"))
		var wave_lbl := Label.new()
		if wave_state == "cleared":
			wave_lbl.text = "Waves Cleared"
			wave_lbl.add_theme_color_override("font_color", Color(0.4, 0.95, 0.4))
		else:
			wave_lbl.text = "Wave %d/%s" % [
				int(wave_info.get("current", 0)),
				"∞" if wave_info.get("infinite", false) else str(int(wave_info.get("total", 0))),
			]
			wave_lbl.add_theme_color_override("font_color", Color(1.0, 0.5, 0.4))
		wave_lbl.add_theme_font_size_override("font_size", 13)
		wave_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		objective_vbox.add_child(wave_lbl)

		# Sub-line: countdown to next wave (default), "Final Wave" once
		# everything's been queued, suppressed entirely once cleared.
		if wave_state != "cleared":
			var time_lbl := Label.new()
			if wave_state == "final":
				time_lbl.text = "Final Wave — defeat remaining enemies"
				time_lbl.add_theme_color_override("font_color", Color(1.0, 0.7, 0.5))
			else:
				time_lbl.text = "Time Until Next Wave: %s" % _format_wave_countdown(float(wave_info.get("time_left", 0.0)))
				time_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.6))
			time_lbl.add_theme_font_size_override("font_size", 11)
			time_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			objective_vbox.add_child(time_lbl)

	# --- Captured? ---
	# A sector that's captured AND not currently abandoned counts as
	# "currently held". Once captured, the -C- marker stays researched
	# forever (so tech gated on it remains unlocked), but the HUD
	# should reflect the *current* state — same way planet-select
	# distinguishes gold (held) from white (abandoned).
	var sid: StringName = SaveManager.active_sector_id if "active_sector_id" in SaveManager else &""
	var captured: bool = sid != &"" \
		and TechTree.is_sector_captured(sid) \
		and not (TechTree.has_method("was_sector_abandoned") and TechTree.was_sector_abandoned(sid))
	if captured:
		any_info = true
		var cap_lbl := Label.new()
		cap_lbl.text = "Sector Captured"
		cap_lbl.add_theme_font_size_override("font_size", 13)
		cap_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		cap_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		objective_vbox.add_child(cap_lbl)
	else:
		# --- Objective list (skipped when captured — the gray
		# "Sector Captured" line replaces it). ---
		var sector_script = get_node_or_null("/root/Main/SectorScript")
		var objectives: Array = []
		if sector_script and sector_script.has_method("get_current_objectives"):
			objectives = sector_script.get_current_objectives()
		if not objectives.is_empty():
			any_info = true
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
				var icon_tex: Texture2D = obj.get("icon", null)
				var hbox = HBoxContainer.new()
				hbox.add_theme_constant_override("separation", 6)
				hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
				objective_vbox.add_child(hbox)
				var bullet = Label.new()
				bullet.text = "✔" if done else "▸"
				bullet.add_theme_font_size_override("font_size", 12)
				bullet.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3) if done else Color(0.8, 0.8, 0.8))
				bullet.mouse_filter = Control.MOUSE_FILTER_IGNORE
				hbox.add_child(bullet)
				# Verb-icon-noun layout: when an icon is present, split the
				# objective text on its first space so the verb ("Place",
				# "Deposit", "Produce", "Destroy", …) sits BEFORE the icon
				# and the noun + counter sit after — easier to scan and
				# more grammatical than "[icon] Place Foo".
				var lbl_color: Color = Color(0.5, 0.8, 0.5) if done else Color(0.85, 0.88, 0.92)
				var counter_suffix: String = ""
				if target > 1 or current > 0:
					counter_suffix = ": %d/%d" % [current, target]
				if icon_tex != null and " " in text:
					var sp: int = text.find(" ")
					var verb: String = text.substr(0, sp)
					var noun: String = text.substr(sp + 1)
					var verb_lbl = Label.new()
					verb_lbl.text = verb
					verb_lbl.add_theme_font_size_override("font_size", 12)
					verb_lbl.add_theme_color_override("font_color", lbl_color)
					verb_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
					hbox.add_child(verb_lbl)
					var icon_rect := TextureRect.new()
					icon_rect.texture = icon_tex
					icon_rect.custom_minimum_size = Vector2(16, 16)
					icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
					icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
					icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
					hbox.add_child(icon_rect)
					var noun_lbl = Label.new()
					noun_lbl.text = noun + counter_suffix
					noun_lbl.add_theme_font_size_override("font_size", 12)
					noun_lbl.add_theme_color_override("font_color", lbl_color)
					noun_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
					hbox.add_child(noun_lbl)
				else:
					if icon_tex != null:
						var icon_rect := TextureRect.new()
						icon_rect.texture = icon_tex
						icon_rect.custom_minimum_size = Vector2(16, 16)
						icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
						icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
						icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
						hbox.add_child(icon_rect)
					var lbl = Label.new()
					lbl.text = text + counter_suffix
					lbl.add_theme_font_size_override("font_size", 12)
					lbl.add_theme_color_override("font_color", lbl_color)
					lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
					hbox.add_child(lbl)

	objective_vbox.visible = any_info
	# Separator only when BOTH halves of the panel have content, so a
	# panel that's just info (no controlled unit) doesn't look like it
	# has a stranded line at its top.
	var portrait_visible: bool = portrait_widgets_container != null and portrait_widgets_container.visible
	portrait_info_separator.visible = any_info and portrait_visible

	# Wave footer: shows when waves are running. Carries a row of icons
	# for whatever the *next* wave will spawn plus a "Waves" button that
	# opens the fullscreen wave-list overlay.
	var waves_running: bool = not wave_info.is_empty()
	wave_footer_container.visible = waves_running
	if waves_running:
		_rebuild_wave_icon_row()

	# Show the merged panel whenever ANY section has something to draw.
	portrait_panel.visible = any_info or portrait_visible or waves_running


## Rebuilds the row of unit icons shown in the wave footer (the next
## wave's roster). Counts are summed by unit_id across spawn points.
func _rebuild_wave_icon_row() -> void:
	if wave_icon_row == null:
		return
	for child in wave_icon_row.get_children():
		child.queue_free()
	var roster: Array = _get_next_wave_roster()
	if roster.is_empty():
		# Stub label so the row keeps a baseline height.
		var lbl := Label.new()
		lbl.text = "(no spawns)"
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wave_icon_row.add_child(lbl)
		return
	for entry in roster:
		var uid: StringName = entry["unit_id"]
		var count: int = entry["count"]
		var udata = Registry.get_unit(uid)
		var slot := HBoxContainer.new()
		slot.add_theme_constant_override("separation", 2)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wave_icon_row.add_child(slot)
		if udata and udata.icon:
			var tex := TextureRect.new()
			tex.texture = udata.icon
			tex.custom_minimum_size = Vector2(20, 20)
			tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
			slot.add_child(tex)
		else:
			var dot := ColorRect.new()
			dot.color = udata.color if udata else Color(0.6, 0.6, 0.6)
			dot.custom_minimum_size = Vector2(20, 20)
			dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
			slot.add_child(dot)
		var num := Label.new()
		num.text = "x%d" % count
		num.add_theme_font_size_override("font_size", 11)
		num.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
		num.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(num)


## Returns the roster (units summed by id) for the *next* wave the
## WaveManager is going to spawn. Empty when nothing is queued.
func _get_next_wave_roster() -> Array:
	var wm = get_node_or_null("/root/Main/WaveManager")
	if wm == null or not ("_running" in wm) or not bool(wm._running):
		return []
	var idx: int = int(wm._idx) if "_idx" in wm else 0
	var expanded: Array = wm._expanded_waves if "_expanded_waves" in wm else []
	if idx >= expanded.size():
		# Infinite-auto: ask the static roller for the next wave that
		# would be generated, so the player still sees the upcoming
		# preview even though it hasn't been baked into _expanded_waves.
		if wm.has_method("_is_infinite_auto") and wm._is_infinite_auto():
			var cfg: Dictionary = wm.config if "config" in wm else {}
			var rolled: Array = wm._roll_wave_units(cfg, idx + 1)
			return _sum_wave_entries(rolled)
		return []
	var wave: Dictionary = expanded[idx]
	return _sum_wave_entries(wave.get("units", []))


func _sum_wave_entries(units: Array) -> Array:
	var totals: Dictionary = {}
	var order: Array = []
	for u in units:
		var uid: StringName = StringName(u.get("unit_id", &""))
		if uid == &"":
			continue
		var c: int = int(u.get("count", 1))
		if c <= 0:
			continue
		if not totals.has(uid):
			order.append(uid)
		totals[uid] = int(totals.get(uid, 0)) + c
	var result: Array = []
	for uid in order:
		result.append({"unit_id": uid, "count": int(totals[uid])})
	return result


## Skip the current wave countdown. Sets WaveManager._timer to 0 so
## the very next process tick spawns the next wave immediately. No-op
## when waves aren't running or there's nothing left to spawn.
func _on_wave_skip_pressed() -> void:
	var wm = get_node_or_null("/root/Main/WaveManager")
	if wm == null:
		return
	if not bool(wm.get("_running")):
		return
	var idx: int = int(wm.get("_idx"))
	var expanded_arr = wm.get("_expanded_waves")
	var expanded: int = (expanded_arr as Array).size() if expanded_arr is Array else 0
	var infinite: bool = wm.has_method("_is_infinite_auto") and wm._is_infinite_auto()
	if not infinite and idx >= expanded:
		return  # Finite run that's already spawned everything.
	wm.set("_timer", 0.0)


## Opens a fullscreen tinted overlay that lists every wave with its
## roster. Format per wave:
##   Wave N:
##     - [icon][Unit Name]: [count]
func _open_wave_list_overlay() -> void:
	if wave_list_overlay != null and is_instance_valid(wave_list_overlay):
		return
	wave_list_overlay = CanvasLayer.new()
	wave_list_overlay.layer = 150
	wave_list_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(wave_list_overlay)
	# Tint
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.7)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_close_wave_list_overlay()
	)
	wave_list_overlay.add_child(bg)
	# Centred panel
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -260
	panel.offset_right = 260
	panel.offset_top = -260
	panel.offset_bottom = 260
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var ps := StyleBoxFlat.new()
	ps.bg_color = Color(0.06, 0.07, 0.1, 0.97)
	ps.border_color = Color(1.0, 0.55, 0.4, 0.5)
	ps.set_border_width_all(1)
	ps.set_corner_radius_all(10)
	ps.content_margin_left = 16
	ps.content_margin_right = 16
	ps.content_margin_top = 14
	ps.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel", ps)
	wave_list_overlay.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)
	# Title + close button row
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 8)
	vbox.add_child(title_row)
	var title := Label.new()
	title.text = "Waves"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(1.0, 0.55, 0.4))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.add_theme_font_size_override("font_size", 12)
	close_btn.custom_minimum_size = Vector2(72, 28)
	close_btn.pressed.connect(_close_wave_list_overlay)
	title_row.add_child(close_btn)
	vbox.add_child(HSeparator.new())
	# Scrolling list
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	_populate_wave_list(list)


func _close_wave_list_overlay() -> void:
	if wave_list_overlay != null and is_instance_valid(wave_list_overlay):
		wave_list_overlay.queue_free()
	wave_list_overlay = null


## Populates the wave-list overlay with every queued wave and its
## roster. Reads off WaveManager._expanded_waves; for infinite-auto runs
## that lazily generate, asks the static roller for the next ~50 waves
## past whatever's already been baked so the list isn't empty.
func _populate_wave_list(list: VBoxContainer) -> void:
	var wm = get_node_or_null("/root/Main/WaveManager")
	if wm == null:
		var empty_lbl := Label.new()
		empty_lbl.text = "(no waves configured)"
		empty_lbl.add_theme_font_size_override("font_size", 13)
		empty_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		list.add_child(empty_lbl)
		return
	var expanded: Array = wm._expanded_waves if "_expanded_waves" in wm else []
	var idx: int = int(wm._idx) if "_idx" in wm else 0
	var waves_to_show: Array = []
	for i in expanded.size():
		waves_to_show.append({"num": i + 1, "units": (expanded[i] as Dictionary).get("units", [])})
	# For infinite-auto, peek the next 50 waves past what's already baked.
	if wm.has_method("_is_infinite_auto") and wm._is_infinite_auto():
		var cfg: Dictionary = wm.config if "config" in wm else {}
		var preview_count: int = 50
		for j in preview_count:
			var wave_num: int = expanded.size() + j + 1
			var rolled: Array = wm._roll_wave_units(cfg, wave_num)
			waves_to_show.append({"num": wave_num, "units": rolled})
	if waves_to_show.is_empty():
		var empty_lbl2 := Label.new()
		empty_lbl2.text = "(no waves configured)"
		empty_lbl2.add_theme_font_size_override("font_size", 13)
		empty_lbl2.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		list.add_child(empty_lbl2)
		return
	for wave_entry in waves_to_show:
		var num: int = int(wave_entry["num"])
		var units: Array = wave_entry["units"]
		var roster: Array = _sum_wave_entries(units)
		var header := Label.new()
		var header_text := "Wave %d:" % num
		# Mark waves the player has already cleared so the list stays
		# readable as the run progresses.
		if num <= idx:
			header_text = "Wave %d: (cleared)" % num
		header.text = header_text
		header.add_theme_font_size_override("font_size", 14)
		var header_color: Color = Color(0.5, 0.5, 0.5) if num <= idx else Color(1.0, 0.55, 0.4)
		header.add_theme_color_override("font_color", header_color)
		list.add_child(header)
		if roster.is_empty():
			var none_lbl := Label.new()
			none_lbl.text = "  (empty)"
			none_lbl.add_theme_font_size_override("font_size", 12)
			none_lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
			list.add_child(none_lbl)
			continue
		for r in roster:
			var uid: StringName = r["unit_id"]
			var count: int = int(r["count"])
			var udata = Registry.get_unit(uid)
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)
			list.add_child(row)
			# Indent + bullet
			var bullet := Label.new()
			bullet.text = "  - "
			bullet.add_theme_font_size_override("font_size", 12)
			bullet.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
			row.add_child(bullet)
			# Icon
			if udata and udata.icon:
				var tex := TextureRect.new()
				tex.texture = udata.icon
				tex.custom_minimum_size = Vector2(18, 18)
				tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				row.add_child(tex)
			else:
				var dot := ColorRect.new()
				dot.color = udata.color if udata else Color(0.6, 0.6, 0.6)
				dot.custom_minimum_size = Vector2(18, 18)
				row.add_child(dot)
			# Name + count
			var name_lbl := Label.new()
			var uname: String = udata.display_name if udata else String(uid)
			name_lbl.text = "%s: %d" % [uname, count]
			name_lbl.add_theme_font_size_override("font_size", 12)
			name_lbl.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
			row.add_child(name_lbl)


## Returns wave HUD info {current:int, total:int, time_left:float, infinite:bool}
## or `{}` if waves aren't relevant for this sector. Reads off the WaveManager
## state directly — there's no signal we can subscribe to that fires on
## every tick.
##
## We treat the panel as "wave-relevant" when EITHER:
##   - WaveManager._running is true (start_mode=landing, or the sector
##     script already fired start_waves), OR
##   - There are queued waves yet to spawn (so the next-wave preview
##     and roster overlay still show even between runs).
## A sector with no wave config at all (empty `_expanded_waves` and not
## an infinite-auto run) returns `{}` so the panel collapses cleanly.
func _get_wave_info_for_panel() -> Dictionary:
	var wm = get_node_or_null("/root/Main/WaveManager")
	if wm == null:
		_debug_wave_panel("no WaveManager node found at /root/Main/WaveManager")
		return {}
	var running: bool = bool(wm.get("_running"))
	var idx: int = int(wm.get("_idx"))
	var expanded_arr = wm.get("_expanded_waves")
	var expanded: int = (expanded_arr as Array).size() if expanded_arr is Array else 0
	var infinite: bool = wm.has_method("_is_infinite_auto") and wm._is_infinite_auto()
	var timer: float = float(wm.get("_timer"))
	var cfg = wm.get("config")
	var start_mode: String = ""
	if cfg is Dictionary:
		start_mode = String((cfg as Dictionary).get("start_mode", "?"))
	_debug_wave_panel("running=%s idx=%d expanded=%d infinite=%s timer=%.1f start_mode=%s" \
		% [str(running), idx, expanded, str(infinite), timer, start_mode])
	# Show only when waves are *running*. start_mode="script" sectors
	# look quiet until the sector script fires its `start_waves` step.
	if not running:
		return {}
	# Finite run with no waves baked in yet → nothing to surface.
	if not infinite and expanded == 0:
		return {}
	# Display "Wave N" where N is 1-based and pinned to the wave that's
	# *about to spawn next* (or just spawned — _idx advances on spawn).
	var current: int = clampi(idx + 1, 1, maxi(expanded, idx + 1))
	# Cap "current" at total when finite and we've blown past the end.
	if not infinite and idx >= expanded and expanded > 0:
		current = expanded
	# State: "countdown" while waves are still queueing, "final" once
	# everything's been spawned but enemies remain alive, "cleared" once
	# the waves_defeated signal has flagged the run finished. The
	# objective-panel renderer uses this to suppress the stale "Time
	# Until Next Wave" countdown after wave N spawned.
	var state: String = "countdown"
	if not infinite and idx >= expanded and expanded > 0:
		if bool(wm.get("waves_all_defeated")):
			state = "cleared"
		else:
			state = "final"
	return {
		"current": current,
		"total": expanded,
		"infinite": infinite,
		"time_left": float(wm.get("_timer")),
		"state": state,
	}


## Throttled debug logger for the wave panel. Prints at most once per
## second per distinct message so the output stays readable while we
## diagnose the "waves not showing" case.
var _wave_debug_last_msg: String = ""
var _wave_debug_last_t: float = -10.0
func _debug_wave_panel(msg: String) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	if msg == _wave_debug_last_msg and now - _wave_debug_last_t < 1.0:
		return
	_wave_debug_last_msg = msg
	_wave_debug_last_t = now


func _format_wave_countdown(seconds: float) -> String:
	if seconds < 0.0:
		seconds = 0.0
	var total: int = int(ceil(seconds))
	var minutes: int = total / 60
	var secs: int = total % 60
	if minutes > 0:
		return "%dm, %ds" % [minutes, secs]
	return "%ds" % secs


# =========================
# HINT PANEL (sector tutorial bubbles)
# =========================

func _create_hint_panel() -> void:
	hint_panel = PanelContainer.new()
	# Anchored on the mid-left edge. Width/height are recomputed in
	# _resize_hint_panel from the current text so short hints stay
	# compact and long hints stretch horizontally up to a cap before
	# wrapping.
	hint_panel.anchor_left = 0.0
	hint_panel.anchor_right = 0.0
	hint_panel.anchor_top = 0.5
	hint_panel.anchor_bottom = 0.5
	hint_panel.offset_left = 16
	hint_panel.offset_right = 16
	hint_panel.offset_top = 0
	hint_panel.offset_bottom = 0
	hint_panel.grow_horizontal = Control.GROW_DIRECTION_END
	hint_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	hint_panel.mouse_filter = Control.MOUSE_FILTER_PASS

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.03, 0.05, 0.88)
	style.border_color = Color(0.55, 0.7, 0.95, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	hint_panel.add_theme_stylebox_override("panel", style)
	hint_panel.visible = false
	hint_panel.modulate = Color(1, 1, 1, 0)
	add_child(hint_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_panel.add_child(vbox)

	hint_text_label = RichTextLabel.new()
	hint_text_label.bbcode_enabled = true
	hint_text_label.fit_content = true
	hint_text_label.scroll_active = false
	hint_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint_text_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint_text_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hint_text_label.add_theme_font_size_override("normal_font_size", 13)
	hint_text_label.add_theme_color_override("default_color", Color(0.92, 0.95, 1.0))
	hint_text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(hint_text_label)

	# OK button row — right-aligned via a spacer.
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn_row.add_child(spacer)
	hint_ok_button = Button.new()
	hint_ok_button.text = "OK"
	hint_ok_button.add_theme_font_size_override("font_size", 12)
	hint_ok_button.pressed.connect(_on_hint_ok_pressed)
	btn_row.add_child(hint_ok_button)
	vbox.add_child(btn_row)


## Sizes the hint panel to fit the current text. Picks the narrowest
## width that doesn't force a wrap (so short hints stay compact) up to
## `max_w`, then lets the height grow with wrapped lines. Anchored at
## mid-left, so the panel grows rightward and expands symmetrically
## up/down around the screen's vertical centre.
func _resize_hint_panel() -> void:
	if hint_text_label == null or hint_panel == null:
		return
	var font := hint_text_label.get_theme_default_font()
	if font == null:
		font = ThemeDB.fallback_font
	var font_size: int = 13
	var raw: String = String(_hint_current.get("text", "")) if not _hint_current.is_empty() else hint_text_label.text
	# Convert sector-script-style markup to BBCode first, then strip the
	# resulting tags so measurement sees only the visible glyph run.
	var plain: String = _strip_bbcode(_hint_to_bbcode(raw))
	var max_w: float = 600.0
	var min_w: float = 200.0
	# Single-line width of the longest run of text without forced breaks.
	var single_w: float = 0.0
	for line in plain.split("\n"):
		single_w = maxf(single_w, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	# Pick the narrowest width that fits the text on one line, capped by
	# max_w. The +24 absorbs the panel/vbox content margins; below max_w
	# the label won't wrap, above it the autowrap kicks in and height
	# grows to accommodate the wrapped lines.
	var w: float = clampf(single_w + 24.0, min_w, max_w)
	hint_text_label.custom_minimum_size = Vector2(w, 0)
	# Force a layout pass before reading the wrapped content height.
	hint_text_label.queue_redraw()
	# RichTextLabel.fit_content sizes height once the layout settles.
	# Defer the panel offset update to next frame so we read the
	# post-wrap height.
	call_deferred("_apply_hint_panel_size")


func _apply_hint_panel_size() -> void:
	if hint_panel == null or hint_text_label == null:
		return
	# Sum content height: label height + button row height (if visible)
	# + margins/separation on the wrapping containers. The constants
	# match the styles configured in _create_hint_panel.
	var label_h: float = hint_text_label.get_minimum_size().y
	var btn_h: float = (hint_ok_button.get_minimum_size().y if hint_ok_button.visible else 0.0)
	var sep: float = 8.0  # vbox separation
	var pad_v: float = 20.0  # 10 top + 10 bottom content margins
	var total_h: float = label_h + btn_h + (sep if btn_h > 0.0 else 0.0) + pad_v
	var label_w: float = hint_text_label.custom_minimum_size.x
	var pad_h: float = 24.0  # 12 left + 12 right content margins
	var total_w: float = label_w + pad_h
	hint_panel.offset_left = 16.0
	hint_panel.offset_right = 16.0 + total_w
	hint_panel.offset_top = -total_h * 0.5
	hint_panel.offset_bottom = total_h * 0.5


## Named colors recognised in `(-name)` markup. Mirrors the sector script's
## NAMED_COLORS table so a hint reads the same as a sector text overlay.
const _HINT_NAMED_COLORS := {
	"red": "red",
	"green": "green",
	"blue": "blue",
	"yellow": "yellow",
	"orange": "orange",
	"white": "white",
	"cyan": "cyan",
	"magenta": "magenta",
	"pink": "hotpink",
	"gray": "gray",
	"grey": "gray",
	"black": "#444",
	"brown": "saddlebrown",
	"purple": "darkorchid",
}


## Translates the sector-script overlay markup into BBCode that
## RichTextLabel understands:
##   `(-red)foo(-reset)`             → `[color=red]foo[/color]`
##   `[res://path/icon.png]`        → `[img]res://path/icon.png[/img]`
## Other characters pass through unchanged. Unknown `(-name)` strings are
## still tried as raw RichTextLabel colour names so authors can use any
## CSS-style colour the engine recognises (e.g. `(-aqua)`).
func _hint_to_bbcode(text: String) -> String:
	var out: String = ""
	var color_open: bool = false
	var i: int = 0
	while i < text.length():
		var c: String = text[i]
		# Color tag: (-name) or (-reset) / (-default).
		if c == "(" and i + 1 < text.length() and text[i + 1] == "-":
			var close: int = text.find(")", i + 2)
			if close != -1:
				var name: String = text.substr(i + 2, close - i - 2).strip_edges().to_lower()
				if color_open:
					out += "[/color]"
					color_open = false
				if name != "reset" and name != "default" and name != "":
					var resolved: String = _HINT_NAMED_COLORS.get(name, name)
					out += "[color=%s]" % resolved
					color_open = true
				i = close + 1
				continue
		# Image tag: [path/to/file.png|.jpg|.svg|.tres].
		if c == "[":
			var close_b: int = text.find("]", i + 1)
			if close_b != -1:
				var path: String = text.substr(i + 1, close_b - i - 1).strip_edges()
				var lower: String = path.to_lower()
				if lower.ends_with(".png") or lower.ends_with(".jpg") \
						or lower.ends_with(".svg") or lower.ends_with(".tres"):
					out += "[img]%s[/img]" % path
					i = close_b + 1
					continue
		out += c
		i += 1
	if color_open:
		out += "[/color]"
	return out


## Returns `text` with BBCode-style `[tag]` and `[/tag]` markers stripped,
## for measurement purposes. Handles `[img]…[/img]` by dropping its body
## entirely so an inline icon doesn't get measured as raw filename pixels.
func _strip_bbcode(text: String) -> String:
	var out: String = text
	# Drop [img] bodies first.
	var rx_img := RegEx.new()
	rx_img.compile("\\[img[^\\]]*\\][^\\[]*\\[/img\\]")
	out = rx_img.sub(out, "  ", true)
	# Then strip every remaining [tag] / [/tag].
	var rx_tag := RegEx.new()
	rx_tag.compile("\\[/?[^\\]]+\\]")
	out = rx_tag.sub(out, "", true)
	return out


func _on_hint_show(hint: Dictionary) -> void:
	# Already showing or already queued? Ignore — the runtime can re-emit
	# when state is restored from a save, and we don't want the same hint
	# to flash twice.
	var hid := String(hint.get("id", ""))
	print("HUD: _on_hint_show id=%s text=%s" % [hid, String(hint.get("text", "")).left(40)])
	if _hint_seen.has(hid):
		return
	_hint_seen[hid] = true
	_hint_queue.append(hint)


func _on_hint_hide(hint_id: String) -> void:
	# If the hidden hint is the one currently displayed, kick the panel
	# into a fade-out. Queued copies of the same id are dropped.
	if not _hint_current.is_empty() and String(_hint_current.get("id", "")) == hint_id:
		_hint_target_alpha = 0.0
	for i in range(_hint_queue.size() - 1, -1, -1):
		if String(_hint_queue[i].get("id", "")) == hint_id:
			_hint_queue.remove_at(i)
	# Keep the seen flag so a hint that flips back to "active" (e.g. its
	# remove condition stops being satisfied) doesn't re-show forever.
	_hint_seen[hint_id] = true


func _on_hints_cleared() -> void:
	_hint_queue.clear()
	_hint_current = {}
	_hint_target_alpha = 0.0
	_hint_seen.clear()


func _on_hint_ok_pressed() -> void:
	if _hint_current.is_empty():
		return
	var sector_script = get_node_or_null("/root/Main/SectorScript")
	if sector_script and sector_script.has_method("acknowledge_hint"):
		sector_script.acknowledge_hint(String(_hint_current.get("id", "")))


func _tick_hint_panel(delta: float) -> void:
	# Belt-and-suspenders: poll SectorScript every frame for hints that
	# became active without our signal listener firing (race during sector
	# load / signal-connect ordering). _hint_seen ensures we never enqueue
	# the same id twice, and dismissed hints are excluded by the state
	# check, so a hint can never visually re-appear after it's been hidden.
	var sector_script_p = get_node_or_null("/root/Main/SectorScript")
	if sector_script_p:
		var hints_arr_p = sector_script_p.get("_hints")
		var rt_p = sector_script_p.get("_hint_runtime")
		if hints_arr_p is Array and rt_p is Dictionary:
			for h in hints_arr_p:
				var hid := String(h.get("id", ""))
				if hid == "" or _hint_seen.has(hid):
					continue
				if String(rt_p.get(hid, {}).get("state", "")) == "active":
					_on_hint_show(h)
			# Mirror dismissal — if the currently-displayed hint flipped to
			# "dismissed" without a signal reaching us, kick the fade-out.
			if not _hint_current.is_empty():
				var cur_id := String(_hint_current.get("id", ""))
				if String(rt_p.get(cur_id, {}).get("state", "")) == "dismissed":
					_hint_target_alpha = 0.0
	# Pull the next hint when nothing is displayed and the panel has
	# fully faded out.
	if _hint_current.is_empty() and not _hint_queue.is_empty() and _hint_alpha <= 0.01:
		_hint_current = _hint_queue.pop_front()
		hint_text_label.text = _hint_to_bbcode(String(_hint_current.get("text", "")))
		hint_ok_button.visible = bool(_hint_current.get("can_be_ignored", true))
		_resize_hint_panel()
		hint_panel.visible = true
		_hint_target_alpha = 1.0
	# Drive the alpha toward the target.
	var step: float = _hint_fade_speed * delta
	if _hint_alpha < _hint_target_alpha:
		_hint_alpha = minf(_hint_alpha + step, _hint_target_alpha)
	elif _hint_alpha > _hint_target_alpha:
		_hint_alpha = maxf(_hint_alpha - step, _hint_target_alpha)
	if hint_panel:
		hint_panel.modulate.a = _hint_alpha
		hint_panel.visible = _hint_alpha > 0.001 or not _hint_current.is_empty()
	# When fully faded out, retire the current hint so the next queued
	# one can take its place on a future tick.
	if _hint_alpha <= 0.001 and _hint_target_alpha <= 0.001 and not _hint_current.is_empty():
		_hint_current = {}


# =========================
# NETWORK INFO PANEL (P toggle)
# =========================

func _create_network_info_panel() -> void:
	network_info_panel = PanelContainer.new()
	# Bottom-centre, fixed minimum size so the layout doesn't jiggle as
	# the icon list grows / shrinks.
	network_info_panel.anchor_left = 0.5
	network_info_panel.anchor_right = 0.5
	network_info_panel.anchor_top = 1.0
	network_info_panel.anchor_bottom = 1.0
	network_info_panel.offset_left = -320
	network_info_panel.offset_right = 320
	network_info_panel.offset_top = -210
	network_info_panel.offset_bottom = -10
	network_info_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	network_info_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	network_info_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.03, 0.06, 0.9)
	style.border_color = Color(0.2, 0.4, 0.6, 0.7)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	network_info_panel.add_theme_stylebox_override("panel", style)
	network_info_panel.visible = false
	add_child(network_info_panel)

	# Placeholder shown when not hovering a powered block.
	network_info_placeholder = Label.new()
	network_info_placeholder.text = "hover over a power network to start"
	network_info_placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	network_info_placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	network_info_placeholder.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	network_info_placeholder.add_theme_font_size_override("font_size", 14)
	network_info_placeholder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	network_info_placeholder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	network_info_placeholder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	network_info_panel.add_child(network_info_placeholder)

	network_info_root = HBoxContainer.new()
	network_info_root.add_theme_constant_override("separation", 12)
	network_info_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	network_info_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	network_info_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	network_info_root.visible = false
	network_info_panel.add_child(network_info_root)

	# Left: gen / use totals.
	network_info_left = VBoxContainer.new()
	network_info_left.add_theme_constant_override("separation", 4)
	network_info_left.custom_minimum_size = Vector2(170, 0)
	network_info_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	network_info_root.add_child(network_info_left)

	var sep := VSeparator.new()
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	network_info_root.add_child(sep)

	# Right: scrollable list of producer/consumer status rows.
	network_info_right = ScrollContainer.new()
	network_info_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	network_info_right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	network_info_right.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	network_info_right.mouse_filter = Control.MOUSE_FILTER_PASS
	network_info_root.add_child(network_info_right)

	network_info_right_vbox = VBoxContainer.new()
	network_info_right_vbox.add_theme_constant_override("separation", 2)
	network_info_right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	network_info_right_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	network_info_right.add_child(network_info_right_vbox)


## Returns the network index of the block at `grid_pos` if it generates,
## consumes, or transports power, else -1. Producers and consumers are
## the obvious case; cable nodes are treated as valid hover targets too
## so a player who hovers a piece of wire (instead of the generator at
## one end) still gets the network info panel for the grid that wire
## belongs to.
func _network_index_for(grid_pos: Vector2i) -> int:
	if not main.placed_buildings.has(grid_pos):
		return -1
	var data = Registry.get_block(main.placed_buildings[grid_pos])
	if data == null:
		return -1
	var participates: bool = data.electrical_power_use > 0.0 \
		or data.electrical_power_gen > 0.0 \
		or data.tags.has("cable_node")
	if not participates:
		return -1
	var ps = _power_sys_ref()
	if ps == null:
		return -1
	if not ps.elec_cell_to_net.has(grid_pos):
		return -1
	return int(ps.elec_cell_to_net[grid_pos])


func _update_network_info_panel(hovered_grid: Vector2i) -> void:
	# A locked cell (set via "N") wins over live hover. If the locked
	# cell's network has since been destroyed, silently fall back to the
	# hovered cell — pressing N again repins or clears.
	var effective_cell: Vector2i = hovered_grid
	if _network_info_locked_cell != Vector2i(-9999, -9999) \
			and _network_index_for(_network_info_locked_cell) >= 0:
		effective_cell = _network_info_locked_cell
	# Network info is only legible for the player's own networks — an
	# enemy / derelict cable cluster shouldn't surface its production /
	# consumption / stored buffer to the player. Hide the panel when
	# the hovered cell is on a non-LUMINA building (or empty terrain).
	if main.placed_buildings.has(effective_cell) \
			and main.get_building_faction(effective_cell) != main.Faction.LUMINA:
		if _network_info_last_net != -1:
			_network_info_last_net = -1
			network_info_root.visible = false
			network_info_placeholder.visible = true
		return
	var net_idx := _network_index_for(effective_cell)
	if net_idx < 0:
		if _network_info_last_net != -1:
			_network_info_last_net = -1
			network_info_root.visible = false
			network_info_placeholder.visible = true
		return
	# Always refresh the totals (they tick) but only rebuild the icon list
	# when the hovered network changes — avoids re-instancing label nodes
	# every frame.
	var ps = _power_sys_ref()
	if ps == null or net_idx >= ps.elec_networks.size():
		return
	var net: Dictionary = ps.elec_networks[net_idx]
	var rebuilding: bool = net_idx != _network_info_last_net
	# Remember the cell we're showing data for so the graph overlay can
	# pin to the same network even if the user hovers away later.
	_network_info_pinned_cell = effective_cell
	if rebuilding:
		_network_info_last_net = net_idx
		network_info_placeholder.visible = false
		network_info_root.visible = true
		# Rebuild left column.
		for c in network_info_left.get_children():
			c.queue_free()
		_network_info_avg_lbl = null
		var gen_lbl := Label.new()
		gen_lbl.add_theme_font_size_override("font_size", 13)
		gen_lbl.add_theme_color_override("font_color", Color(0.5, 0.85, 1.0))
		gen_lbl.text = "Production: %.0f" % float(net.get("gen", 0.0))
		gen_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		network_info_left.add_child(gen_lbl)
		var use_lbl := Label.new()
		use_lbl.add_theme_font_size_override("font_size", 13)
		use_lbl.add_theme_color_override("font_color", Color(1.0, 0.75, 0.4))
		use_lbl.text = "Consumption: %.0f" % float(net.get("use", 0.0))
		use_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		network_info_left.add_child(use_lbl)
		# Sum of every block's internal-battery reservoir in this network.
		# Replaces the old 1-minute average draw — the stored buffer is
		# more actionable (it directly tells the player how long the
		# network can ride out a brownout).
		var avg_lbl := Label.new()
		avg_lbl.add_theme_font_size_override("font_size", 12)
		avg_lbl.add_theme_color_override("font_color", Color(0.85, 0.7, 0.95))
		avg_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		avg_lbl.text = _format_stored_power_label(ps, effective_cell)
		network_info_left.add_child(avg_lbl)
		_network_info_avg_lbl = avg_lbl
		# Graph button.
		var graph_btn := Button.new()
		graph_btn.text = "Power Graph"
		graph_btn.add_theme_font_size_override("font_size", 12)
		graph_btn.mouse_filter = Control.MOUSE_FILTER_STOP
		graph_btn.pressed.connect(_open_network_graph_overlay)
		network_info_left.add_child(graph_btn)
		# Rebuild the icon list.
		for c in network_info_right_vbox.get_children():
			c.queue_free()
		_populate_network_info_rows(net)
	else:
		# Same network — just live-update the totals + per-row status.
		var children := network_info_left.get_children()
		if children.size() >= 2:
			(children[0] as Label).text = "Production: %.0f" % float(net.get("gen", 0.0))
			(children[1] as Label).text = "Consumption: %.0f" % float(net.get("use", 0.0))
		if _network_info_avg_lbl != null and is_instance_valid(_network_info_avg_lbl):
			_network_info_avg_lbl.text = _format_stored_power_label(ps, effective_cell)
		_refresh_network_info_status(net)


## Builds one row per non-cable producer/consumer in the network.
func _populate_network_info_rows(net: Dictionary) -> void:
	var ps = _power_sys_ref()
	var seen_anchors: Dictionary = {}
	var rows: Array = []
	for cell in net.get("cells", []):
		var bid: StringName = main.placed_buildings.get(cell, &"")
		if bid == &"":
			continue
		var d = Registry.get_block(bid)
		if d == null:
			continue
		# Cable nodes / cable towers don't show in the list.
		if d.tags.has("cable_node"):
			continue
		# Only producers / consumers (the spec).
		if d.electrical_power_use <= 0.0 and d.electrical_power_gen <= 0.0:
			continue
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if seen_anchors.has(anchor):
			continue
		seen_anchors[anchor] = true
		rows.append({"anchor": anchor, "data": d})
	# Stable order: producers first, then consumers, alphabetical within each group.
	rows.sort_custom(func(a, b):
		var ag: bool = a["data"].electrical_power_gen > 0.0
		var bg: bool = b["data"].electrical_power_gen > 0.0
		if ag != bg:
			return ag
		return String(a["data"].display_name) < String(b["data"].display_name)
	)
	for r in rows:
		network_info_right_vbox.add_child(_build_network_info_row(r["anchor"], r["data"], ps))


func _build_network_info_row(anchor: Vector2i, d: BlockData, ps: Node) -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.set_meta("anchor", anchor)
	if d.icon:
		var tex := TextureRect.new()
		tex.texture = d.icon
		tex.custom_minimum_size = Vector2(20, 20)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(tex)
	var name_lbl := Label.new()
	name_lbl.text = d.display_name
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(name_lbl)

	var sep1 := VSeparator.new()
	sep1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(sep1)

	var status_lbl := Label.new()
	status_lbl.add_theme_font_size_override("font_size", 12)
	status_lbl.custom_minimum_size = Vector2(54, 0)
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(status_lbl)

	var sep2 := VSeparator.new()
	sep2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(sep2)

	# Power column: red usage for consumers, green generation for producers.
	var power_lbl := Label.new()
	power_lbl.add_theme_font_size_override("font_size", 12)
	power_lbl.custom_minimum_size = Vector2(64, 0)
	power_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	power_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if d.electrical_power_gen > 0.0:
		power_lbl.add_theme_color_override("font_color", Color(0.4, 0.95, 0.4))
	else:
		power_lbl.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45))
	hbox.add_child(power_lbl)

	# Tiny sparkline mirroring `eff_graph` but plotting the block's
	# power-column value (the ±[num] beside it) instead of efficiency.
	# Same 60-sample, 1 Hz cadence so a row that's been visible for ~60 s
	# fills the line; producers are tinted green, consumers red.
	var power_graph := Control.new()
	power_graph.custom_minimum_size = Vector2(50, 14)
	power_graph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	power_graph.draw.connect(_draw_power_graph.bind(power_graph))
	hbox.add_child(power_graph)

	var sep3 := VSeparator.new()
	sep3.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(sep3)

	# Efficiency column: tier-coloured percentage.
	var eff_lbl := Label.new()
	eff_lbl.add_theme_font_size_override("font_size", 12)
	eff_lbl.custom_minimum_size = Vector2(48, 0)
	eff_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	eff_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(eff_lbl)

	# Tiny 60-sample (1 min @ 1 Hz) sparkline showing this block's recent
	# efficiency. Samples are pushed in _apply_network_info_status.
	var eff_graph := Control.new()
	eff_graph.custom_minimum_size = Vector2(50, 14)
	eff_graph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	eff_graph.draw.connect(_draw_eff_graph.bind(eff_graph))
	hbox.add_child(eff_graph)

	hbox.set_meta("status_lbl", status_lbl)
	hbox.set_meta("power_lbl", power_lbl)
	hbox.set_meta("eff_lbl", eff_lbl)
	hbox.set_meta("eff_graph", eff_graph)
	hbox.set_meta("power_graph", power_graph)
	# Per-block efficiency / power history is sampled in PowerSystem
	# (`_block_history`) so it keeps accruing in the background even
	# when this panel is hidden — sparklines below read straight from
	# that store via `ps.get_block_history(anchor)`.
	_apply_network_info_status(hbox, anchor, d, ps)
	return hbox


## Draws the per-row efficiency sparkline. Reads from PowerSystem's
## per-block history (sampled in the background regardless of whether
## the network panel is open) so the graph shows continuity even after
## the panel was closed and reopened.
func _draw_eff_graph(ctrl: Control) -> void:
	var hbox := ctrl.get_parent() as HBoxContainer
	if hbox == null:
		return
	var w: float = ctrl.size.x
	var h: float = ctrl.size.y
	# Frame
	ctrl.draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), Color(0.08, 0.08, 0.1, 0.6), true)
	ctrl.draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), Color(0.3, 0.3, 0.35, 0.5), false, 1.0)
	# 50% reference line
	var mid_y: float = h * 0.5
	ctrl.draw_line(Vector2(0, mid_y), Vector2(w, mid_y), Color(0.4, 0.4, 0.45, 0.35), 1.0)
	var anchor_e: Vector2i = hbox.get_meta("anchor", Vector2i(-9999, -9999))
	if anchor_e == Vector2i(-9999, -9999):
		return
	var ps_e = _power_sys_ref()
	if ps_e == null or not ps_e.has_method("get_block_history"):
		return
	var bs: Array = ps_e.get_block_history(anchor_e)
	const MAX_N: int = 60
	# Pull only the trailing 60 samples (≈ 1 minute) into a flat array.
	var hist: PackedFloat32Array = PackedFloat32Array()
	var start_e: int = maxi(0, bs.size() - MAX_N)
	for i in range(start_e, bs.size()):
		hist.append(float(bs[i].get("e", 0.0)))
	var n: int = hist.size()
	if n < 2:
		return
	# Anchor the most recent sample at the right edge so a row that's only
	# been on screen for 5 s shows 5 ticks of history at the right rather
	# than stretching them across the whole width.
	var step: float = w / float(MAX_N - 1)
	var pts := PackedVector2Array()
	for i in n:
		var v: float = clampf(hist[i], 0.0, 1.0)
		var x: float = w - float(n - 1 - i) * step
		var y: float = h - 1.0 - v * (h - 2.0)
		pts.append(Vector2(x, y))
	# Tier colour matches the % label.
	var last_v: float = clampf(hist[n - 1], 0.0, 1.0)
	var line_col: Color
	if last_v >= 0.75:
		line_col = Color(0.4, 0.95, 0.4)
	elif last_v >= 0.4:
		line_col = Color(0.95, 0.85, 0.35)
	else:
		line_col = Color(1.0, 0.45, 0.45)
	ctrl.draw_polyline(pts, line_col, 1.5, true)


## Per-row power sparkline. Reads from PowerSystem's per-block history
## (sampled in the background) and scales against the block's rated
## gen/use so a generator at full output reads as 100 % full. Producer
## rows are tinted green, consumers red.
func _draw_power_graph(ctrl: Control) -> void:
	var hbox := ctrl.get_parent() as HBoxContainer
	if hbox == null:
		return
	var w: float = ctrl.size.x
	var h: float = ctrl.size.y
	ctrl.draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), Color(0.08, 0.08, 0.1, 0.6), true)
	ctrl.draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), Color(0.3, 0.3, 0.35, 0.5), false, 1.0)
	var mid_y: float = h * 0.5
	ctrl.draw_line(Vector2(0, mid_y), Vector2(w, mid_y), Color(0.4, 0.4, 0.45, 0.35), 1.0)
	var anchor: Vector2i = hbox.get_meta("anchor", Vector2i(-9999, -9999))
	if anchor == Vector2i(-9999, -9999):
		return
	var ps_p = _power_sys_ref()
	if ps_p == null or not ps_p.has_method("get_block_history"):
		return
	var bs_p: Array = ps_p.get_block_history(anchor)
	const MAX_HIST_N: int = 60
	# Trailing 60 samples for the sparkline; PowerSystem keeps the full
	# 600 in `_block_history` for the 10-minute network graph overlay.
	var hist: PackedFloat32Array = PackedFloat32Array()
	var start_p: int = maxi(0, bs_p.size() - MAX_HIST_N)
	for i in range(start_p, bs_p.size()):
		hist.append(float(bs_p[i].get("p", 0.0)))
	var n: int = hist.size()
	if n < 2:
		return
	var d: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
	var rated: float = 0.0
	var is_producer := false
	if d != null:
		if d.electrical_power_gen > 0.0:
			rated = d.electrical_power_gen
			is_producer = true
		elif d.electrical_power_use > 0.0:
			rated = d.electrical_power_use
	if rated <= 0.0:
		for v in hist:
			rated = maxf(rated, float(v))
		if rated <= 0.0:
			rated = 1.0
	const MAX_N: int = 60
	# Show only the last 60 samples (1 minute) on the row sparkline; the
	# rest of `power_history` is reserved for the network-graph hover.
	var n_disp: int = mini(n, MAX_N)
	var step: float = w / float(MAX_N - 1)
	var pts := PackedVector2Array()
	for i in n_disp:
		var sample_idx: int = n - n_disp + i
		var v: float = clampf(float(hist[sample_idx]) / rated, 0.0, 1.0)
		var x: float = w - float(n_disp - 1 - i) * step
		var y: float = h - 1.0 - v * (h - 2.0)
		pts.append(Vector2(x, y))
	var line_col: Color = Color(0.4, 0.95, 0.4) if is_producer else Color(1.0, 0.55, 0.45)
	ctrl.draw_polyline(pts, line_col, 1.5, true)



func _apply_network_info_status(hbox: HBoxContainer, anchor: Vector2i, d: BlockData, ps: Node) -> void:
	var status_lbl: Label = hbox.get_meta("status_lbl")
	var power_lbl: Label = hbox.get_meta("power_lbl")
	var eff_lbl: Label = hbox.get_meta("eff_lbl")
	var active: bool = _is_block_active_for_network(anchor, d, ps)
	if active:
		status_lbl.text = "active"
		status_lbl.add_theme_color_override("font_color", Color(0.4, 0.95, 0.4))
	else:
		status_lbl.text = "inactive"
		status_lbl.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45))

	# Power column — generators show their (effective) generation, consumers
	# show their draw. Both use the rated value when active, 0 when not.
	var is_producer: bool = d.electrical_power_gen > 0.0
	var power_val: float = 0.0
	if is_producer:
		if active and ps and ps.has_method("_get_effective_elec_gen"):
			power_val = float(ps._get_effective_elec_gen(anchor, d))
		elif active:
			power_val = d.electrical_power_gen
		power_lbl.text = "+%.0f" % power_val
	else:
		power_val = d.electrical_power_use if active else 0.0
		power_lbl.text = "-%.0f" % power_val

	# Efficiency column — producers: actual / rated. Consumers: the
	# network's current gen/use ratio (the same time-dilation everything
	# downstream uses).
	var eff_pct: int = 0
	if is_producer:
		if d.electrical_power_gen > 0.0:
			eff_pct = int(round(power_val / d.electrical_power_gen * 100.0))
	else:
		if active and ps and ps.has_method("get_electrical_efficiency"):
			eff_pct = int(round(float(ps.get_electrical_efficiency(anchor)) * 100.0))
		else:
			eff_pct = 0
	eff_pct = clampi(eff_pct, 0, 100)
	eff_lbl.text = "%d%%" % eff_pct
	var eff_col: Color
	if eff_pct >= 75:
		eff_col = Color(0.4, 0.95, 0.4)
	elif eff_pct >= 40:
		eff_col = Color(0.95, 0.85, 0.35)
	else:
		eff_col = Color(1.0, 0.45, 0.45)
	eff_lbl.add_theme_color_override("font_color", eff_col)

	# Sampling pauses while the world is paused so the sparklines /
	# 10-min hover history don't drift forward without any actual
	# gameplay state changing behind them. Repaints still run so the
	# user can scrub the existing data. Use the pause-aware
	# `_network_graph_clock` as the timestamp source so paused samples
	# don't shift the timeline forward — every consumer (per-row
	# sparkline + 10-min overlay) reads the same clock.
	# History sampling is owned by PowerSystem (`_block_history` indexed
	# by anchor) and runs in the background regardless of whether the
	# network panel is open. The per-row sparklines just read from there
	# and queue a redraw — the panel can be closed and reopened without
	# losing graph continuity.
	var graph: Control = hbox.get_meta("eff_graph", null)
	if graph and is_instance_valid(graph):
		graph.queue_redraw()
	var pgraph: Control = hbox.get_meta("power_graph", null)
	if pgraph and is_instance_valid(pgraph):
		pgraph.queue_redraw()


## Live-update only the per-row status labels (network unchanged).
func _refresh_network_info_status(_net: Dictionary) -> void:
	var ps = _power_sys_ref()
	for child in network_info_right_vbox.get_children():
		if child is HBoxContainer and child.has_meta("anchor") and child.has_meta("status_lbl"):
			var anchor: Vector2i = child.get_meta("anchor")
			var bid: StringName = main.placed_buildings.get(anchor, &"")
			var d = Registry.get_block(bid)
			if d == null:
				continue
			_apply_network_info_status(child, anchor, d, ps)


## Producer is "active" if it's actually contributing gen right now (e.g. a
## vent_powered turbine on the right tile). Consumer is "active" if it's
## drawing power right now (delegates to PowerSystem._is_block_drawing_power).
func _is_block_active_for_network(anchor: Vector2i, d: BlockData, ps: Node) -> bool:
	if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
		return false
	if d.electrical_power_gen > 0.0:
		if ps and ps.has_method("_get_effective_elec_gen"):
			return float(ps._get_effective_elec_gen(anchor, d)) > 0.0
		return true
	if d.electrical_power_use > 0.0:
		if ps and ps.has_method("_is_block_drawing_power"):
			return bool(ps._is_block_drawing_power(anchor, d))
		return true
	return false


## Opens a fullscreen overlay that tints the rest of the HUD black and
## draws the pinned network's gen/use over the last 10 minutes.
func _open_network_graph_overlay() -> void:
	if _network_info_pinned_cell == Vector2i(-9999, -9999):
		return
	network_graph_pinned_cell = _network_info_pinned_cell
	if network_graph_overlay == null or not is_instance_valid(network_graph_overlay):
		network_graph_overlay = CanvasLayer.new()
		network_graph_overlay.layer = 150
		add_child(network_graph_overlay)
		var bg := ColorRect.new()
		bg.color = Color(0, 0, 0, 0.78)
		bg.anchor_right = 1.0
		bg.anchor_bottom = 1.0
		bg.mouse_filter = Control.MOUSE_FILTER_STOP
		bg.gui_input.connect(func(ev: InputEvent):
			# Click anywhere outside the chart area to dismiss.
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				_close_network_graph_overlay()
			elif ev is InputEventKey and ev.pressed and ev.keycode == KEY_ESCAPE:
				_close_network_graph_overlay()
		)
		network_graph_overlay.add_child(bg)
		network_graph_canvas = Control.new()
		network_graph_canvas.anchor_left = 0.5
		network_graph_canvas.anchor_top = 0.5
		network_graph_canvas.anchor_right = 0.5
		network_graph_canvas.anchor_bottom = 0.5
		network_graph_canvas.offset_left = -460
		network_graph_canvas.offset_right = 460
		network_graph_canvas.offset_top = -240
		network_graph_canvas.offset_bottom = 240
		# STOP so motion events update `_network_graph_hover_pos` and
		# clicks dismiss without falling through to the bg below. The bg
		# still handles dismissal for clicks OUTSIDE the canvas rect.
		network_graph_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
		network_graph_canvas.gui_input.connect(_on_network_graph_input)
		network_graph_canvas.mouse_exited.connect(func(): _network_graph_hover_pos = Vector2(-1, -1))
		network_graph_canvas.draw.connect(_draw_network_graph)
		network_graph_overlay.add_child(network_graph_canvas)
		var hint := Label.new()
		hint.text = "click anywhere to close"
		hint.add_theme_font_size_override("font_size", 11)
		hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
		hint.anchor_left = 0.5
		hint.anchor_right = 0.5
		hint.anchor_top = 1.0
		hint.anchor_bottom = 1.0
		hint.offset_left = -100
		hint.offset_right = 100
		hint.offset_top = -28
		hint.offset_bottom = -10
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		network_graph_overlay.add_child(hint)
	network_graph_overlay.visible = true
	network_graph_canvas.queue_redraw()


## Captures mouse motion / clicks on the network-graph canvas. Motion
## stamps `_network_graph_hover_pos` (in canvas-local coords, which is
## what the draw routine plots in); clicks close the overlay so the
## existing dismiss-on-click affordance keeps working when the cursor
## is over the chart instead of the bg.
func _on_network_graph_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_network_graph_hover_pos = (event as InputEventMouseMotion).position
		if network_graph_canvas and is_instance_valid(network_graph_canvas):
			network_graph_canvas.queue_redraw()
	elif event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_close_network_graph_overlay()


func _close_network_graph_overlay() -> void:
	if network_graph_overlay and is_instance_valid(network_graph_overlay):
		network_graph_overlay.visible = false


func _draw_network_graph() -> void:
	var canvas := network_graph_canvas
	if canvas == null or not is_instance_valid(canvas):
		return
	var size := canvas.size
	# Frame
	canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(0.04, 0.05, 0.08, 0.95), true)
	canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(0.25, 0.4, 0.55, 0.9), false, 1.5)
	var font := ThemeDB.fallback_font
	canvas.draw_string(font, Vector2(12, 22), "Power — last 10 minutes",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.85, 0.9, 1.0))

	var ps = _power_sys_ref()
	if ps == null or not ps.has_method("get_network_history"):
		canvas.draw_string(font, Vector2(12, 60), "no history available",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.8, 0.4, 0.4))
		return
	var samples: Array = ps.get_network_history(network_graph_pinned_cell)
	# Plot area (leave margins for axes/labels)
	var ml := 56.0
	var mr := 16.0
	var mt := 36.0
	var mb := 28.0
	var plot_rect := Rect2(Vector2(ml, mt), Vector2(size.x - ml - mr, size.y - mt - mb))
	canvas.draw_rect(plot_rect, Color(0.06, 0.08, 0.11, 1.0), true)
	canvas.draw_rect(plot_rect, Color(0.2, 0.3, 0.4, 0.8), false, 1.0)

	if samples.is_empty():
		canvas.draw_string(font, plot_rect.position + Vector2(plot_rect.size.x * 0.5 - 60, plot_rect.size.y * 0.5),
			"collecting data...", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.7, 0.75, 0.8))
		return

	# Axes domain: 10 minutes ending at the pause-aware "now". Using the
	# same clock as PowerSystem.sample_network_history + the per-row
	# sparkline samples means a paused world freezes the whole graph
	# (samples don't get pushed AND the X-axis doesn't slide forward).
	var now: float = _network_graph_clock
	var t_start: float = now - 600.0
	# Find max y for scaling: use whichever of gen/use/stored is largest.
	# Stored is in B units (1B = 60 ps), plotted on the same axis.
	var y_max: float = 1.0
	for s in samples:
		y_max = maxf(y_max, float(s["gen"]))
		y_max = maxf(y_max, float(s["use"]))
		y_max = maxf(y_max, float(s.get("stored", 0.0)))
	# Round up to a nice step.
	var step: float = pow(10.0, floor(log(y_max) / log(10.0)))
	if step < 1.0:
		step = 1.0
	y_max = ceil(y_max / step) * step

	# Gridlines + y labels (4 horizontal divisions)
	for i in range(5):
		var f: float = float(i) / 4.0
		var y: float = plot_rect.position.y + plot_rect.size.y * (1.0 - f)
		canvas.draw_line(Vector2(plot_rect.position.x, y),
			Vector2(plot_rect.position.x + plot_rect.size.x, y),
			Color(0.18, 0.22, 0.28, 0.7), 1.0)
		var v: float = y_max * f
		canvas.draw_string(font, Vector2(8, y + 4), "%.0f" % v,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.7, 0.75, 0.8))
	# X labels (every 2 minutes)
	for i in range(6):
		var f2: float = float(i) / 5.0
		var x: float = plot_rect.position.x + plot_rect.size.x * f2
		canvas.draw_line(Vector2(x, plot_rect.position.y),
			Vector2(x, plot_rect.position.y + plot_rect.size.y),
			Color(0.18, 0.22, 0.28, 0.5), 1.0)
		var minutes_back: float = (1.0 - f2) * 10.0
		var lbl: String = "now" if minutes_back == 0.0 else ("-%dm" % int(round(minutes_back)))
		canvas.draw_string(font, Vector2(x - 12, plot_rect.position.y + plot_rect.size.y + 16),
			lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.7, 0.75, 0.8))

	# Build polylines.
	var gen_pts: PackedVector2Array = []
	var use_pts: PackedVector2Array = []
	var stored_pts: PackedVector2Array = []
	for s in samples:
		var t: float = float(s["t"])
		if t < t_start:
			continue
		var fx: float = clampf((t - t_start) / 600.0, 0.0, 1.0)
		var x: float = plot_rect.position.x + plot_rect.size.x * fx
		var fy_g: float = clampf(float(s["gen"]) / y_max, 0.0, 1.0)
		var fy_u: float = clampf(float(s["use"]) / y_max, 0.0, 1.0)
		var fy_s: float = clampf(float(s.get("stored", 0.0)) / y_max, 0.0, 1.0)
		gen_pts.append(Vector2(x, plot_rect.position.y + plot_rect.size.y * (1.0 - fy_g)))
		use_pts.append(Vector2(x, plot_rect.position.y + plot_rect.size.y * (1.0 - fy_u)))
		stored_pts.append(Vector2(x, plot_rect.position.y + plot_rect.size.y * (1.0 - fy_s)))
	if gen_pts.size() >= 2:
		canvas.draw_polyline(gen_pts, Color(0.5, 0.85, 1.0, 0.95), 2.0, true)
	if use_pts.size() >= 2:
		canvas.draw_polyline(use_pts, Color(1.0, 0.75, 0.4, 0.95), 2.0, true)
	if stored_pts.size() >= 2:
		canvas.draw_polyline(stored_pts, Color(0.85, 0.55, 1.0, 0.95), 2.0, true)

	# Legend
	var lx: float = plot_rect.position.x + plot_rect.size.x - 130
	var ly: float = plot_rect.position.y + 14
	canvas.draw_line(Vector2(lx, ly), Vector2(lx + 18, ly), Color(0.5, 0.85, 1.0), 2.0)
	canvas.draw_string(font, Vector2(lx + 24, ly + 4), "Production",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.85, 0.9, 1.0))
	canvas.draw_line(Vector2(lx, ly + 16), Vector2(lx + 18, ly + 16), Color(1.0, 0.75, 0.4), 2.0)
	canvas.draw_string(font, Vector2(lx + 24, ly + 20), "Consumption",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1.0, 0.85, 0.7))
	canvas.draw_line(Vector2(lx, ly + 32), Vector2(lx + 18, ly + 32), Color(0.85, 0.55, 1.0), 2.0)
	canvas.draw_string(font, Vector2(lx + 24, ly + 36), "Stored (B)",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.92, 0.78, 1.0))

	# --- Hover overlay: horizontal white line at the cursor's Y, with a
	# stack of icons rising from the bottom of the chart at the cursor's
	# X. Each icon represents a block whose power_history sample at the
	# corresponding time was non-zero (i.e. it was active then). ---
	# Position is captured directly off the canvas's gui_input
	# (`_on_network_graph_input`) so the math doesn't have to chase the
	# nested-CanvasLayer transform that broke `get_local_mouse_position`.
	var mp: Vector2 = _network_graph_hover_pos
	if mp.x < 0.0 or not plot_rect.has_point(mp):
		return
	# (Vertical hover guide is drawn below; no horizontal value line.)
	# Map cursor X → time. Walk every block in the pinned network and
	# pick up the icons of those whose PowerSystem-side per-block
	# history was non-zero at that point in time. PowerSystem records
	# samples for every electrical producer/consumer regardless of
	# whether the info panel is open, so the icon stack now has the
	# full 10-minute window available instead of just the time the
	# panel happened to be open.
	var fx: float = clampf((mp.x - plot_rect.position.x) / plot_rect.size.x, 0.0, 1.0)
	var hover_t: float = t_start + fx * 600.0
	var active_icons: Array = []
	var seen_anchors: Dictionary = {}
	if ps != null and ps.has_method("get_block_history"):
		var net_idx: int = _network_index_for(network_graph_pinned_cell)
		if net_idx >= 0 and net_idx < ps.elec_networks.size():
			var net_cells: Array = ps.elec_networks[net_idx].get("cells", [])
			for cell in net_cells:
				var bid_h: StringName = main.placed_buildings.get(cell, &"")
				if bid_h == &"":
					continue
				var d_h: BlockData = Registry.get_block(bid_h)
				if d_h == null:
					continue
				if d_h.electrical_power_gen <= 0.0 and d_h.electrical_power_use <= 0.0:
					continue
				var anch_h: Vector2i = main.building_origins.get(cell, cell)
				if seen_anchors.has(anch_h):
					continue
				seen_anchors[anch_h] = true
				var bs: Array = ps.get_block_history(anch_h)
				if bs.is_empty():
					continue
				# Find the sample whose t is closest to hover_t. Samples
				# are time-ordered ascending, so a linear walk from the
				# back is fine for ~600 entries.
				var best_p: float = 0.0
				var best_dt: float = INF
				for j in range(bs.size() - 1, -1, -1):
					var st: float = float(bs[j]["t"])
					var dt: float = absf(st - hover_t)
					if dt < best_dt:
						best_dt = dt
						best_p = float(bs[j]["p"])
					if st < hover_t - 1.5:
						break
				if best_p <= 0.0 or best_dt > 5.0:
					continue
				if d_h.icon == null:
					continue
				active_icons.append(d_h.icon)
	# Vertical white guide line at the cursor X across the plot (helps
	# the player line the icon stack up with the time axis). Drop
	# shadow + 2 px width matches the horizontal hover line above.
	canvas.draw_line(
		Vector2(mp.x + 1.0, plot_rect.position.y),
		Vector2(mp.x + 1.0, plot_rect.position.y + plot_rect.size.y),
		Color(0, 0, 0, 0.5),
		2.0,
	)
	canvas.draw_line(
		Vector2(mp.x, plot_rect.position.y),
		Vector2(mp.x, plot_rect.position.y + plot_rect.size.y),
		Color(1, 1, 1, 0.85),
		2.0,
	)
	# Stack icons from the BOTTOM up at the cursor X. 18 px square +
	# 2 px separation; clamp to the plot height so very busy networks
	# don't overflow.
	const ICON_SIZE: float = 18.0
	const ICON_GAP: float = 2.0
	var stack_x: float = mp.x - ICON_SIZE * 0.5
	var bottom_y: float = plot_rect.position.y + plot_rect.size.y - ICON_SIZE - 2.0
	var max_stack: int = int(plot_rect.size.y / (ICON_SIZE + ICON_GAP))
	for i in mini(active_icons.size(), max_stack):
		var icon_tex: Texture2D = active_icons[i]
		var icon_y: float = bottom_y - float(i) * (ICON_SIZE + ICON_GAP)
		canvas.draw_texture_rect(
			icon_tex,
			Rect2(Vector2(stack_x, icon_y), Vector2(ICON_SIZE, ICON_SIZE)),
			false,
		)


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
	style.bg_color = Color(0.06, 0.06, 0.07, 0.95)
	style.border_color = Color(0.85, 0.88, 0.92, 0.7)
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
	title.add_theme_color_override("font_color", Color(0.92, 0.94, 0.96))
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
	# Reset the save for this sector so a re-launch goes through the
	# fresh-map path (and SectorScript starts from step 0 with no
	# pre-existing counts / overlays / hidden regions).
	if SaveManager.active_sector_id != &"":
		var sector_id: StringName = SaveManager.active_sector_id
		SaveManager.sector_resources.erase(sector_id)
		# Use SaveManager.delete_sector so we hit the same path
		# save_sector writes to (user://maps/<id>.sector.json). The old
		# hard-coded "user://maps/sectors/<id>.save.json" path was wrong
		# — that file never existed, so a natural loss could leave a
		# stale save in place and replaying the sector would pick up
		# old script progress instead of starting clean.
		SaveManager.delete_sector(str(sector_id))
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


## Fires when an archive_decoder completes a cycle. Stacks the archive
## node onto the unlock popup directly so the player gets the standard
## "content unlocked" banner at the top of the screen — the marker node
## the TechTree rule researches is hidden, so the generic node-state
## listener won't surface it on its own.
func _on_archive_decoded(archive_id: StringName) -> void:
	if archive_id == &"":
		return
	# Skip if a tech-tree window is currently open — the player is
	# already watching the unlock land in the tree itself, no need to
	# also flash a top-of-screen banner.
	var tech_ui = get_node_or_null("/root/Main/TechTreeUI")
	if tech_ui and "is_open" in tech_ui and tech_ui.is_open:
		return
	# Surface the actual content unlocked by decoding this archive, not
	# the archive itself. Each node whose `dependencies` list contains
	# `-D-archive_id` was gated by this archive — those are now eligible
	# for research, so show them.
	var marker := StringName("-D-%s" % archive_id)
	var unlocked: Array[StringName] = []
	for node_id in TechTree.nodes:
		var nd: Dictionary = TechTree.nodes[node_id]
		var deps: Array = nd.get("dependencies", [])
		if deps.has(marker):
			unlocked.append(node_id)
	if unlocked.is_empty():
		# Fallback: at least surface the archive itself so something pops.
		_show_unlock_icon(archive_id)
		return
	# Stack each unlocked node into the popup (the existing helper
	# extends the timer when called repeatedly, so multiple icons end
	# up sharing a single banner).
	for nid in unlocked:
		_show_unlock_icon(nid)


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
