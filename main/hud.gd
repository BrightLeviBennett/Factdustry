extends CanvasLayer

const SchematicPreviewScript = preload("res://main/schematic_preview.gd")

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
var block_menu_outer_vbox: VBoxContainer
var block_menu_info_separator: HSeparator
var block_grid: GridContainer
var category_vbox: Container
var misc_hbox: HBoxContainer
# Unit mode panel: icon grid + command buttons
var unit_mode_icon_grid: HFlowContainer
var unit_mode_buttons_vbox: VBoxContainer
var unit_mode_btn_cancel: Button
var unit_mode_btn_hold_fire: Button
var unit_mode_btn_payload: Button
var unit_mode_btn_rebuild: Button
var unit_mode_btn_mine: Button
var unit_mode_btn_assist: Button
# Dummy test-unit commands (shown only when a dummy enemy is selected).
var unit_mode_btn_attack_player: Button
var unit_mode_btn_attack_block: Button
var _mine_picker_popup: PopupPanel = null
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
# --- CUSTOM CURSORS ---
# We draw the cursor ourselves (TextureRect on a top-of-stack
# CanvasLayer) instead of using Input.set_custom_mouse_cursor.
# Godot 4's `set_custom_mouse_cursor` has a long-standing macOS bug
# where the OS-level texture doesn't refresh until the window loses
# and regains focus — every workaround (set_default_cursor_shape
# cycle, MOUSE_MODE toggle, warp_mouse) either flickers, fails to
# clear, or moves the cursor. Mindustry sidesteps the whole issue
# because libGDX talks to the platform API directly; for us, the
# robust equivalent is "hide the system cursor, paint our own sprite
# at the mouse position".
const _CURSOR_DRILL_PATH := "res://textures/mouse heads/DrillMouse.png"
const _CURSOR_TARGET_PATH := "res://textures/mouse heads/TargetMouse.png"
const _CURSOR_DEFAULT_PATH := "res://textures/mouse heads/DefualtMouse.png"
const _CURSOR_WRENCH_PATH := "res://textures/mouse heads/WrenchMouse.png"
var _cursor_drill_tex: Texture2D = null
var _cursor_target_tex: Texture2D = null
var _cursor_default_tex: Texture2D = null
var _cursor_wrench_tex: Texture2D = null
var _cursor_layer: CanvasLayer = null
var _cursor_sprite: TextureRect = null
# Current custom texture (or null = show system cursor)
var _cursor_active_tex: Texture2D = null
# Target on-screen size for the custom cursor in pixels. Source PNGs
# are authored at a much higher resolution so they stay crisp when
# scaled — we resize them down to roughly system-cursor scale here.
const _CURSOR_DISPLAY_SIZE := 64.0
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

	_cursor_drill_tex = load(_CURSOR_DRILL_PATH) as Texture2D
	_cursor_target_tex = load(_CURSOR_TARGET_PATH) as Texture2D
	_cursor_default_tex = load(_CURSOR_DEFAULT_PATH) as Texture2D
	_cursor_wrench_tex = load(_CURSOR_WRENCH_PATH) as Texture2D
	_create_custom_cursor()

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
	elif event.is_action_pressed("toggle_network_info") \
			and not event.shift_pressed and not event.ctrl_pressed and not event.meta_pressed and not event.alt_pressed:
		# Don't steal P from text inputs (rename fields, etc.).
		var fc := get_viewport().gui_get_focus_owner()
		if fc is LineEdit or fc is TextEdit:
			return
		network_info_open = not network_info_open
		network_info_panel.visible = network_info_open
		_network_info_last_net = -2  # force refresh on next process tick
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("network_info_lock") \
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

## Adds or refreshes a transient hazard alert displayed beneath the
## resource panel. `id` is the unique key for this alert (so re-pushing the
## same id just refreshes the text instead of stacking duplicates). Call
## `clear_alert(id)` when the condition resolves. Pass `auto_expire_sec`
## for self-clearing alerts (e.g. a core-damage notice that should fade if
## damage stops landing).
func push_alert(id: StringName, text: String, auto_expire_sec: float = 0.0) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	var expires_at: float = -1.0
	if auto_expire_sec > 0.0:
		expires_at = now + auto_expire_sec
	for entry in _active_alerts:
		if StringName(entry.get("id", &"")) == id:
			entry["text"] = text
			entry["expires_at"] = expires_at
			return
	_active_alerts.append({"id": id, "text": text, "expires_at": expires_at})


func clear_alert(id: StringName) -> void:
	for i in range(_active_alerts.size() - 1, -1, -1):
		if StringName(_active_alerts[i].get("id", &"")) == id:
			_active_alerts.remove_at(i)


func _tick_alert_banner(delta: float) -> void:
	if alert_panel == null or alert_label == null:
		return
	# Auto-expire alerts whose expires_at has passed (negative = persistent).
	var now: float = Time.get_ticks_msec() / 1000.0
	for i in range(_active_alerts.size() - 1, -1, -1):
		var exp: float = float(_active_alerts[i].get("expires_at", -1.0))
		if exp >= 0.0 and now >= exp:
			_active_alerts.remove_at(i)
	if _active_alerts.is_empty():
		alert_panel.visible = false
		return
	_alert_phase += delta * TAU * 1.0   # ~1 Hz colour cycle
	# Cycle the label colour between red and yellow on a sine. Stays high
	# saturation so the eye catches it in peripheral vision.
	var t: float = 0.5 + 0.5 * sin(_alert_phase)
	var col := Color(1.0, lerpf(0.15, 0.85, t), 0.15)
	alert_label.add_theme_color_override("font_color", col)
	# Show all active alerts stacked on newlines — gives a single banner
	# for "multiple things on fire" without spawning duplicate panels.
	var lines: Array[String] = []
	for entry in _active_alerts:
		lines.append(String(entry.get("text", "")))
	alert_label.text = "\n".join(lines)
	alert_panel.visible = true


## Sets up the CanvasLayer + TextureRect we use to paint our custom
## cursor sprite. Top-of-stack layer so the sprite renders over every
## other HUD element. `mouse_filter = IGNORE` so the sprite never eats
## clicks meant for the world below.
func _create_custom_cursor() -> void:
	_cursor_layer = CanvasLayer.new()
	_cursor_layer.layer = 1000
	add_child(_cursor_layer)
	_cursor_sprite = TextureRect.new()
	_cursor_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_sprite.visible = false
	_cursor_sprite.z_as_relative = false
	_cursor_sprite.z_index = 4096
	# Scale the (high-res) source texture down to cursor size, keeping
	# aspect ratio so non-square sprites don't squash.
	_cursor_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cursor_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_cursor_layer.add_child(_cursor_sprite)


## Picks a custom mouse cursor based on what the cursor is hovering over.
## TargetMouse: in unit mode with units selected, over a FEROX building.
## DrillMouse: over any tile that has an ore overlay.
## Default arrow otherwise — we show the system cursor for that case.
##
## The cursor sprite is repositioned every frame (no caching needed)
## because we're drawing it ourselves; only the system cursor's hidden /
## visible state has any latency, and we toggle that only when the
## custom texture changes (or clears).
func _update_mouse_cursor(hovered_grid: Vector2i, in_unit_mode: bool, unit_mgr) -> void:
	var desired_tex: Texture2D = null
	# TARGET cursor — enemy under cursor + unit-mode + selection.
	if in_unit_mode and unit_mgr != null and "selected_units" in unit_mgr \
			and (unit_mgr.selected_units as Array).size() > 0 \
			and _cursor_target_tex != null \
			and main.placed_buildings.has(hovered_grid) \
			and main.get_building_faction(hovered_grid) == main.Faction.FEROX:
		desired_tex = _cursor_target_tex
	# WRENCH cursor — any derelict building under the cursor. Reads as
	# "this can be reclaimed / repaired" the same way the drill cursor
	# reads as "this can be mined".
	elif _cursor_wrench_tex != null \
			and main.placed_buildings.has(hovered_grid) \
			and main.get_building_faction(hovered_grid) == main.Faction.DERELICT:
		desired_tex = _cursor_wrench_tex
	# DRILL cursor — any ore overlay on the hovered cell.
	elif _cursor_drill_tex != null:
		var terrain = main.get_node_or_null("TerrainSystem")
		if terrain != null and "ore_tiles" in terrain and terrain.ore_tiles.has(hovered_grid):
			desired_tex = _cursor_drill_tex
	# The DEFAULT cursor is owned by the GlobalCursor autoload — see
	# main/global_cursor.gd. That one paints across every scene (main
	# menu, planet select, sectors). Here we only override it when HUD
	# wants Drill or Target; otherwise we delegate by leaving the
	# override clear, and GlobalCursor falls back to DefualtMouse.png.
	var gc = get_node_or_null("/root/GlobalCursor")
	if gc != null:
		if desired_tex != null:
			gc.set_override(desired_tex)
		else:
			gc.clear_override()
	# Suppress HUD's own cursor sprite — GlobalCursor renders the cursor
	# project-wide, so painting a second copy here would stack two
	# cursors on top of each other.
	if _cursor_sprite != null and _cursor_sprite.visible:
		_cursor_sprite.visible = false
	# Track the active texture for any per-frame consumers that still
	# read `_cursor_active_tex` (build-cost panel placement, etc.).
	if desired_tex != _cursor_active_tex:
		_cursor_active_tex = desired_tex
		# Preserved legacy branch: if GlobalCursor isn't available
		# (someone removed the autoload), fall back to painting
		# HUD's own sprite so cursors still work in sectors.
		if gc == null and _cursor_sprite != null:
			_cursor_sprite.texture = desired_tex
			_cursor_sprite.visible = desired_tex != null
			if desired_tex != null:
				_cursor_sprite.size = Vector2(_CURSOR_DISPLAY_SIZE, _CURSOR_DISPLAY_SIZE)
		# Mouse-mode handling: GlobalCursor (when present) hides the
		# system cursor project-wide in its `_ready`, so HUD should
		# NOT touch the mouse mode — otherwise the else-branch would
		# un-hide it the moment HUD has no Drill/Target override.
		if gc == null:
			if desired_tex != null:
				if Input.get_mouse_mode() != Input.MOUSE_MODE_HIDDEN:
					Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
			else:
				if Input.get_mouse_mode() != Input.MOUSE_MODE_VISIBLE:
					Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	# Reposition every frame so the sprite tracks the pointer.
	if _cursor_sprite != null and _cursor_sprite.visible:
		var vp := get_viewport()
		if vp != null:
			var m: Vector2 = vp.get_mouse_position()
			# Anchor on the hotspot (sprite center) so the click point
			# lines up with the center of the crosshair / drill icon.
			_cursor_sprite.position = m - _cursor_sprite.size * 0.5


func _process(delta: float) -> void:
	_tick_alert_banner(delta)
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

	# Custom mouse cursor:
	#   - TargetMouse when in unit mode with units selected AND hovering
	#     an enemy (FEROX) building — the right-click here orders an
	#     attack.
	#   - DrillMouse when hovering a tile that has ore on it (regardless
	#     of unit mode), as a hint that the cell is a mining target.
	#   - Default arrow otherwise.
	_update_mouse_cursor(hovered_grid, in_unit_mode, unit_mgr)

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
	elif _is_extractable_tile(hovered_grid):
		# No placed building, but the hovered cell is an extractable
		# terrain tile (ore, wall ore, liquid floor). Show the same
		# tooltip panel populated with the tile's info instead.
		build_cost_panel.visible = false
		_last_cost_building = &""
		_tooltip_refresh_timer -= delta
		if hovered_grid != _last_hovered_grid or _tooltip_refresh_timer <= 0:
			_last_hovered_grid = hovered_grid
			_tooltip_refresh_timer = TOOLTIP_REFRESH_INTERVAL
			_update_tile_tooltip(hovered_grid)
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

	# Info-section separator: only show when one of tooltip / build-cost is
	# visible, so the block grid sits flush against the panel chrome when
	# there's nothing above it.
	if block_menu_info_separator:
		block_menu_info_separator.visible = block_tooltip.visible or build_cost_panel.visible

	# Show unit mode panel when shift is held
	# Unit mode panel — visible whenever the UnitManager is in unit mode.
	unit_mode_panel.visible = in_unit_mode
	if in_unit_mode:
		_update_unit_mode_icons()
		_update_unit_mode_buttons()

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
	# Flush against the top-left corner — no offset, no rounded
	# outer corners, no top/left border. The right + bottom edges
	# still get the rounded corner / soft border so the panel reads
	# as anchored rather than free-floating.
	portrait_panel.offset_left = 0
	portrait_panel.offset_top = 0
	portrait_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.03, 0.06, 0.8)
	# Only round the inward (bottom-right) corner so the panel reads
	# as flush against the top-left edge of the window.
	style.corner_radius_top_left = 0
	style.corner_radius_top_right = 0
	style.corner_radius_bottom_left = 0
	style.corner_radius_bottom_right = 6
	style.border_color = Color(0.2, 0.3, 0.4, 0.5)
	# Drop the top + left border (touching the window edge) so the
	# panel doesn't show a hairline gap against the viewport.
	style.border_width_left = 0
	style.border_width_top = 0
	style.border_width_right = 1
	style.border_width_bottom = 1
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

	# Name label — kept as a hidden sink so the existing
	# `portrait_name_label.text = ...` write sites in _process don't
	# need a null check; the player just doesn't see it. The icon +
	# health bars are clear enough on their own.
	portrait_name_label = Label.new()
	portrait_name_label.add_theme_font_size_override("font_size", 11)
	portrait_name_label.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
	portrait_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	portrait_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait_name_label.visible = false
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
			# Solid red — health bar reads at a glance instead of the
			# old red→green gradient that obscured the actual fill.
			var hp_color: Color = Color(0.9, 0.15, 0.15)
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
			var hp_color: Color = Color(0.9, 0.15, 0.15)
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
			# Right bar 3: booster fuel. Shown whenever the turret
			# declares at least one booster entry. Fill = the booster
			# resource's stored amount over its container cap. Picks
			# the first booster entry's `item_id` — multi-booster
			# turrets are rare; this still gives a useful "is the
			# booster fed?" read.
			var booster_visible: bool = false
			var booster_pct: float = 0.0
			if bdata and not bdata.boosters.is_empty() and _logistics:
				var first: Dictionary = {}
				for entry in bdata.boosters:
					if typeof(entry) == TYPE_DICTIONARY:
						first = entry
						break
				if not first.is_empty():
					var b_id: StringName = StringName(first.get("item_id", &""))
					var b_anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
					var b_is_fluid: bool = Registry.get_fluid(b_id) != null
					var b_storage: Dictionary = _logistics.block_storage.get(b_anchor, {})
					var b_bucket: Dictionary = b_storage.get("fluids" if b_is_fluid else "items", {})
					var b_have: float = float(b_bucket.get(b_id, 0.0))
					var b_cap: float = float(bdata.liquid_capacity) if b_is_fluid else float(bdata.max_stored_items)
					if b_cap > 0.0:
						booster_pct = clampf(b_have / b_cap, 0.0, 1.0)
						booster_visible = true
			portrait_right_bar_3_container.visible = booster_visible
			if booster_visible:
				portrait_right_bar_3_fill.color = Color(0.3, 0.6, 1.0)
				_set_portrait_bar(portrait_right_bar_3_fill, booster_pct)

	else:
		# --- Default: Core Unit (Player Drone) ---
		if drone:
			# Icon — prefer the UnitData "complete" icon (e.g.
			# ShardlingComplete.png, which includes the heads) over the
			# in-world chassis sprite, which is just the body half of
			# the layered drawing path.
			var drone_icon_tex: Texture2D = null
			if drone.data and drone.data.icon:
				drone_icon_tex = drone.data.icon
			elif "drone_texture" in drone:
				drone_icon_tex = drone.drone_texture
			if drone_icon_tex:
				portrait_icon_rect.texture = drone_icon_tex
				portrait_icon_rect.visible = true
				portrait_color_rect.visible = false
			else:
				portrait_icon_rect.visible = false
				portrait_color_rect.color = drone.drone_color
				portrait_color_rect.visible = true
			# Health on both sides
			var pct: float = drone.health / drone.max_health if drone.max_health > 0 else 0.0
			# Solid red — health bar reads at a glance instead of the
			# old red→green gradient that obscured the actual fill.
			var hp_color: Color = Color(0.9, 0.15, 0.15)
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

var alert_panel: PanelContainer = null
var alert_label: Label = null
var _active_alerts: Array = []   # Array of {id: StringName, text: String}
var _alert_phase: float = 0.0

func _create_resource_panel() -> void:
	var margin = MarginContainer.new()
	margin.anchor_left = 0.5
	margin.anchor_right = 0.5
	margin.grow_horizontal = Control.GROW_DIRECTION_BOTH
	margin.add_theme_constant_override("margin_top", 10)
	add_child(margin)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 6)
	margin.add_child(col)

	resource_panel = PanelContainer.new()
	col.add_child(resource_panel)

	# Alert banner — sits directly below the resource panel, hidden until
	# `push_alert(id, text)` is called. Flashes between red and yellow at
	# ~2 Hz so it reads as a hazard from peripheral vision.
	alert_panel = PanelContainer.new()
	alert_panel.visible = false
	var alert_style := StyleBoxFlat.new()
	alert_style.bg_color = Color(0, 0, 0, 0.7)
	alert_style.set_corner_radius_all(8)
	alert_style.content_margin_left = 14
	alert_style.content_margin_right = 14
	alert_style.content_margin_top = 6
	alert_style.content_margin_bottom = 6
	alert_panel.add_theme_stylebox_override("panel", alert_style)
	col.add_child(alert_panel)
	alert_label = Label.new()
	alert_label.add_theme_font_size_override("font_size", 16)
	alert_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))
	alert_panel.add_child(alert_label)

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
	# Outer anchor: bottom-right corner, flush to the window edge
	# (no offset_right / offset_bottom gap) — matches the portrait /
	# wave / objective panel in the top-left. Height is content-driven so
	# the panel grows upward when the info / placement sections appear.
	block_menu = PanelContainer.new()
	block_menu.anchor_left = 1.0
	block_menu.anchor_right = 1.0
	block_menu.anchor_top = 1.0
	block_menu.anchor_bottom = 1.0
	block_menu.offset_left = -350
	block_menu.offset_right = 0
	block_menu.offset_bottom = 0
	block_menu.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	block_menu.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.7)
	# Only round the inward (top-left) corner — the right + bottom edges
	# touch the window so they stay square, same convention as the
	# portrait panel.
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 0
	style.corner_radius_bottom_left = 0
	style.corner_radius_bottom_right = 0
	style.border_color = Color(0.2, 0.3, 0.4, 0.5)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 0
	style.border_width_bottom = 0
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	block_menu.add_theme_stylebox_override("panel", style)
	add_child(block_menu)

	# Outer vbox: [info (block tooltip / build cost)] [separator] [blocks + categories]
	block_menu_outer_vbox = VBoxContainer.new()
	block_menu_outer_vbox.add_theme_constant_override("separation", 6)
	block_menu.add_child(block_menu_outer_vbox)

	# Separator between info section and the block / category grid. Hidden
	# until either the hover tooltip or the build-cost section is shown.
	block_menu_info_separator = HSeparator.new()
	block_menu_info_separator.visible = false
	block_menu_outer_vbox.add_child(block_menu_info_separator)

	# Main HBox: [left column (blocks + misc)] [right column (category tabs)]
	var main_hbox = HBoxContainer.new()
	main_hbox.add_theme_constant_override("separation", 4)
	block_menu_outer_vbox.add_child(main_hbox)

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
	# Height is content-driven now (no fixed offset_top on block_menu),
	# so reserve enough room for a few rows of blocks before scrolling.
	grid_panel.custom_minimum_size.y = 260
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
	# Apply current affordability dim immediately so freshly-rebuilt
	# buttons don't flash full-bright for a frame before the next
	# resource tick.
	_apply_block_button_affordability(btn, block)


## True when the player has at least `required` of every item in the
## block's `build_cost`. Free-build blocks return true.
func _can_afford_block(block: BlockData) -> bool:
	if block == null:
		return false
	if block.build_cost.is_empty():
		return true
	for item_id in block.build_cost:
		var needed: int = int(block.build_cost[item_id])
		if needed <= 0:
			continue
		var rk: StringName = main._resolve_resource_key(str(item_id))
		var have: int = int(main.resources.get(rk, 0))
		if have < needed:
			return false
	return true


## Tints a single block button based on whether the player can afford
## its build cost. Unaffordable blocks get a slight black overlay
## (modulate) to match the "you can't place this right now" cue.
func _apply_block_button_affordability(btn: Button, block: BlockData) -> void:
	if btn == null or block == null:
		return
	if _can_afford_block(block):
		btn.modulate = Color.WHITE
	else:
		# Tint pulls all three channels down — straight modulate works
		# for both textured icons and color-swatch buttons.
		btn.modulate = Color(0.45, 0.45, 0.45, 1.0)


## Walks every active block button and re-applies affordability tint.
## Called from `_on_resources_changed` so the menu updates whenever
## the resource pool changes.
func _update_block_affordability_tint() -> void:
	for bid in building_buttons:
		var btn = building_buttons[bid] as Button
		var block: BlockData = Registry.get_block(bid)
		_apply_block_button_affordability(btn, block)


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
	# Now lives inside the block menu so the hover info reads as the top
	# section of the same panel (with an HSeparator below it before the
	# block grid). No own anchors / background — block_menu provides both.
	block_tooltip = PanelContainer.new()
	block_tooltip.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	block_tooltip.visible = false
	block_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Insert at the top of block_menu_outer_vbox (above the separator + main_hbox).
	block_menu_outer_vbox.add_child(block_tooltip)
	block_menu_outer_vbox.move_child(block_tooltip, 0)

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

	# --- Fluid Storage Bar ---
	# Pumps, condensers, fluid-boosted turrets / cranes — anything
	# with non-zero `liquid_capacity` gets a blue bar showing
	# stored/max. Value is read from BuildingSystem's eased display
	# dict so the bar slides smoothly per-frame instead of snapping.
	if data.liquid_capacity > 0.0:
		var bs = main.get_node_or_null("BuildingSystem")
		var disp_fl: float = 0.0
		if bs and "_fluid_bar_display" in bs:
			disp_fl = float(bs._fluid_bar_display.get(origin, 0.0))
		_add_tooltip_fluid_bar(disp_fl, data.liquid_capacity)

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
	# Pipes show a fluid bar coloured by the carried fluid instead of a
	# "Fluid: X (NN%)" text line — matches how tanks / pumps / vent
	# condensers display their stored fluid via `_add_tooltip_fluid_bar`.
	if _logistics and data.transports_fluid:
		if _logistics.pipe_contents.has(grid_pos):
			var pipe = _logistics.pipe_contents[grid_pos]
			var fluid = Registry.get_fluid(pipe["fluid_id"])
			if fluid:
				_add_tooltip_fluid_bar(
					float(pipe["amount"]),
					float(fluid.units_per_segment),
					fluid.color,
					fluid.display_name
				)

	# --- Extractor Efficiency ---
	if data.category == BlockData.BlockCategory.EXTRACTORS:
		var terrain = get_node_or_null("/root/Main/TerrainSystem")
		var rot: int = main.building_rotation.get(origin, 0)
		var front_cells: Array[Vector2i] = []
		if _logistics:
			front_cells = _logistics._get_front_edge(origin, data.grid_size, rot)
		var front_count: int = front_cells.size()
		# Sum of per-cell efficiency multipliers (1.0 for a regular ore
		# hit, e.g. 0.75 for a purple_wall hit). Divided by front_count
		# below to land in [0, 1]. Float so wall-eff fractions survive.
		var eff_sum_outer: float = 0.0
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
			# Per-wall efficiency multiplier so the tooltip reads the
			# same value the runtime tick will produce (purple_wall
			# under a wall_crusher counts as 0.75 instead of 1.0).
			for cell in front_cells:
				var hit_mult: float = 0.0
				if is_wall_miner:
					var hit_wall_hud: StringName = &""
					var wid_h: StringName = StringName(terrain.wall_tiles.get(cell, &""))
					if terrain.get_ore_at(cell) == null and accepted_walls_hud.has(wid_h):
						hit_wall_hud = wid_h
					else:
						for step in range(1, max_extend + 1):
							var scan: Vector2i = cell + dir * step
							var wid_hs: StringName = StringName(terrain.wall_tiles.get(scan, &""))
							if terrain.get_ore_at(scan) == null and accepted_walls_hud.has(wid_hs):
								hit_wall_hud = wid_hs
								break
					if hit_wall_hud != &"":
						hit_mult = float(data.wall_efficiency.get(hit_wall_hud, 1.0))
				else:
					if terrain.get_ore_at(cell) != null:
						hit_mult = 1.0
					else:
						for step in range(1, max_extend + 1):
							if terrain.get_ore_at(cell + dir * step) != null:
								hit_mult = 1.0
								break
				eff_sum_outer += hit_mult
		var ore_eff: float
		if is_geyser_miner:
			ore_eff = 1.0
		elif is_floor_miner:
			ore_eff = _logistics._floor_miner_efficiency(origin, data.grid_size) if _logistics else 0.0
		else:
			ore_eff = eff_sum_outer / float(front_count) if front_count > 0 else 1.0
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
		if is_loader and "loader_state" in _logistics and _logistics.loader_state.has(origin):
			var ls: Dictionary = _logistics.loader_state[origin]
			if ls.get("payload") != null and ls["payload"] is Dictionary:
				lpayload = ls["payload"]
		elif is_unloader and "unloader_state" in _logistics and _logistics.unloader_state.has(origin):
			var us: Dictionary = _logistics.unloader_state[origin]
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
		else:
			# Show the chosen tier-2 unit and how many of them are alive
			# on the map. Counts ENEMY/PLAYER-team variants by ID.
			var udata = Registry.get_unit(sel_t2)
			var uname: String = udata.display_name if udata and udata.display_name != "" else String(sel_t2)
			var alive_n: int = 0
			var unit_mgr = main.get_node_or_null("UnitManager")
			if unit_mgr:
				var pools: Array = []
				if "player_units" in unit_mgr:
					pools.append(unit_mgr.player_units)
				if "enemies" in unit_mgr:
					pools.append(unit_mgr.enemies)
				for pool in pools:
					for u in pool:
						if u == null or not is_instance_valid(u):
							continue
						if "is_dead" in u and u.is_dead:
							continue
						if "data" in u and u.data and StringName(u.data.id) == sel_t2:
							alive_n += 1
			_add_tooltip_line("Selected Unit: %s · %d alive" % [uname, alive_n], Color(0.9, 0.9, 0.6))

	# --- Shield: live HP bar (or recharge countdown when broken) ---
	# Only shown once the building is BOTH built and powered — i.e. once
	# ShieldSystem has actually initialized state for it. A ghost / cold
	# barrier projector contributes nothing to the panel.
	if data.shield_shape != "" and data.shield_health > 0.0:
		var ss = main.get_node_or_null("ShieldSystem")
		if ss and "states" in ss and ss.states.has(origin):
			var sstate: Dictionary = ss.states[origin]
			if bool(sstate.get("is_broken", false)):
				# Broken — show recharge time remaining as a fill-up bar.
				var cd_total: float = data.shield_cooldown if data.shield_cooldown > 0.0 else 10.0
				var cd_left: float = float(sstate.get("cooldown_remaining", 0.0))
				var charge_pct: int = int(clampf(1.0 - cd_left / cd_total, 0.0, 1.0) * 100.0)
				_add_tooltip_progress_bar(charge_pct, 100, "Shield Recharging", Color(0.5, 0.5, 0.85))
			else:
				var cur_hp: float = float(sstate.get("current_health", data.shield_health))
				var max_hp: float = float(data.shield_health)
				_add_tooltip_progress_bar(int(cur_hp), int(max_hp), "Shield", Color(0.4, 0.7, 1.0))

	# --- Launchpad: pod build progress / cargo readout ---
	# While the pad is still gathering its 60 copper + 15 steel mandatory
	# cost we show a progress bar. Once the cost is fully present, the
	# pod is "built"; switch the panel to a "Pod Resources" list of the
	# extras + fluids that will ship with the pod.
	if data.id == &"launchpad":
		_add_launchpad_tooltip_section(origin)

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
	# State now lives on the ArchiveDecoderSystem sibling; query it via
	# `get_state(anchor)` instead of reaching into BuildingSystem.
	if data.tags.has("archive_decoder"):
		var ad_sys = main.get_node_or_null("ArchiveDecoderSystem")
		if ad_sys and ad_sys.has_method("get_state"):
			var dstate: Dictionary = ad_sys.get_state(origin)
			if not dstate.is_empty():
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


## Renders the launchpad-specific tooltip section. While the mandatory
## cost isn't yet collected the section shows a single yellow progress
## bar (% built). Once collected, the bar disappears and the section
## becomes a "Pod Resources" list of the extra items / fluids that will
## ship with the pod — i.e. everything in the launchpad's storage minus
## the 60 copper + 15 steel that get burnt on launch.
func _add_launchpad_tooltip_section(anchor: Vector2i) -> void:
	var lp_sys = main.get_node_or_null("LaunchpadSystem")
	if lp_sys == null or _logistics == null:
		return
	var pct: float = 0.0
	if lp_sys.has_method("get_pod_build_progress"):
		pct = clampf(lp_sys.get_pod_build_progress(anchor), 0.0, 1.0)
	_add_tooltip_separator()
	if pct < 1.0:
		# Pod still under construction — single progress bar.
		var pct_int: int = int(pct * 100.0)
		_add_tooltip_progress_bar(pct_int, 100, "Pod Build", Color(1.0, 0.9, 0.2))
		return
	# Pod fully built — list every passenger item / fluid that'll ride
	# along. The pod itself is built over time on power alone, so
	# block_storage holds nothing but the pod's pure cargo.
	var storage: Dictionary = _logistics.block_storage.get(anchor, {})
	var items: Dictionary = storage.get("items", {})
	var fluids: Dictionary = storage.get("fluids", {})
	_add_tooltip_line("Pod Resources:", Color(1.0, 0.92, 0.4))
	var any_listed: bool = false
	for k in items:
		var amt: int = int(items[k])
		if amt <= 0:
			continue
		any_listed = true
		var it = Registry.get_item_or_fluid(StringName(k))
		var disp: String = it.display_name if it else String(k)
		_add_tooltip_line("- %s: %d" % [disp, amt], Color(0.85, 0.9, 1.0))
	for k in fluids:
		var amtf: float = float(fluids[k])
		if amtf <= 0.0:
			continue
		any_listed = true
		var fl = Registry.get_item_or_fluid(StringName(k))
		var dispf: String = fl.display_name if fl else String(k)
		_add_tooltip_line("- %s: %.1f" % [dispf, amtf], Color(0.7, 0.85, 1.0))
	if not any_listed:
		_add_tooltip_line("- (empty)", Color(0.6, 0.6, 0.7))




# =========================
# EXTRACTABLE-TILE TOOLTIP
# =========================
# Shown when the player hovers a non-built cell that yields something
# under a drill / pump (floor ore, wall ore, liquid floor like water).
# Same panel chrome as the block tooltip — just sourced from
# TerrainTileData instead of BlockData.

## True when the cell at `grid_pos` is an extractable terrain tile.
## Skips cells that already have a placed building (handled by the
## block tooltip) and cells with no minable / extracted resource.
func _is_extractable_tile(grid_pos: Vector2i) -> bool:
	if main == null:
		return false
	if main.placed_buildings.has(grid_pos):
		return false
	var terrain = main.get_node_or_null("TerrainSystem")
	if terrain == null:
		return false
	# Ore overlay (floor or wall-embedded) — checked first since it's
	# the most common drillable surface.
	if "ore_tiles" in terrain and terrain.ore_tiles.has(grid_pos):
		var ore = Registry.get_tile(terrain.ore_tiles[grid_pos])
		if ore and ore.minable_resource != &"":
			return true
	# Wall tile with a minable_resource (blackstone, bauxite walls, etc.)
	if "wall_tiles" in terrain and terrain.wall_tiles.has(grid_pos):
		var wd = Registry.get_tile(terrain.wall_tiles[grid_pos])
		if wd and wd.minable_resource != &"":
			return true
	# Liquid floor (water etc.) — pumpable.
	if "floor_tiles" in terrain and terrain.floor_tiles.has(grid_pos):
		var fd = Registry.get_tile(terrain.floor_tiles[grid_pos])
		if fd and (fd.is_liquid or fd.extracted_liquid != &""):
			return true
	return false


## Returns the TerrainTileData that yields a resource at `grid_pos`,
## or `null` if nothing is extractable. Priority matches what a drill
## would actually mine: ore > wall ore > liquid floor.
func _extractable_tile_for(grid_pos: Vector2i) -> TerrainTileData:
	var terrain = main.get_node_or_null("TerrainSystem") if main else null
	if terrain == null:
		return null
	if "ore_tiles" in terrain and terrain.ore_tiles.has(grid_pos):
		var ore = Registry.get_tile(terrain.ore_tiles[grid_pos])
		if ore and ore.minable_resource != &"":
			return ore
	if "wall_tiles" in terrain and terrain.wall_tiles.has(grid_pos):
		var wd = Registry.get_tile(terrain.wall_tiles[grid_pos])
		if wd and wd.minable_resource != &"":
			return wd
	if "floor_tiles" in terrain and terrain.floor_tiles.has(grid_pos):
		var fd = Registry.get_tile(terrain.floor_tiles[grid_pos])
		if fd and (fd.is_liquid or fd.extracted_liquid != &""):
			return fd
	return null


## Populates the block tooltip panel for a hovered extractable tile.
## Uses the tile's own icon by default, but if the tile yields a
## liquid (water etc.) the icon is the LIQUID resource's icon so the
## panel reads as "this is water" rather than "this is the water
## tile floor".
func _update_tile_tooltip(grid_pos: Vector2i) -> void:
	for c in tooltip_vbox.get_children():
		c.queue_free()
	_power_bar_panel = null
	_power_bar_fill = null
	_power_bar_label = null
	var tile: TerrainTileData = _extractable_tile_for(grid_pos)
	if tile == null:
		block_tooltip.visible = false
		return
	# Resolve the item / fluid the tile yields, prefer the liquid for
	# liquid floors so the icon swaps to the water resource icon.
	var yield_id: StringName = &""
	if tile.is_liquid or tile.extracted_liquid != &"":
		yield_id = tile.extracted_liquid if tile.extracted_liquid != &"" else tile.minable_resource
	else:
		yield_id = tile.minable_resource
	var yield_data = Registry.get_item_or_fluid(yield_id) if yield_id != &"" else null

	# --- Header: icon + name ---
	var header_hbox = HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 8)
	header_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Icon: liquid → resource icon, otherwise the tile texture itself.
	var icon_tex: Texture2D = null
	if yield_data and (tile.is_liquid or tile.extracted_liquid != &""):
		icon_tex = yield_data.icon
	elif tile.icon:
		icon_tex = tile.icon
	elif yield_data:
		icon_tex = yield_data.icon
	if icon_tex:
		var icon_rect = TextureRect.new()
		icon_rect.texture = icon_tex
		icon_rect.custom_minimum_size = Vector2(24, 24)
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		header_hbox.add_child(icon_rect)
	var name_lbl = Label.new()
	# Display name resolution: prefer the tile's own name, fall back
	# to the resource's name (so an un-named water floor still reads
	# as "Water" rather than blank).
	var disp_name: String = tile.get_display_name() if tile.has_method("get_display_name") else tile.display_name
	if disp_name == "" and yield_data:
		disp_name = yield_data.display_name
	if disp_name == "":
		disp_name = String(tile.id)
	# Strip trailing " Ore" / " ore" — tile info shows just the resource.
	if disp_name.to_lower().ends_with(" ore"):
		disp_name = disp_name.substr(0, disp_name.length() - 4)
	name_lbl.text = disp_name
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_hbox.add_child(name_lbl)
	tooltip_vbox.add_child(header_hbox)
	# Extractable-tile tooltip is intentionally minimal — just the
	# icon + name. Yields / wall HP / etc. live in the database UI.


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


## Adds a "Fluid Storage" bar to the hover tooltip. Mirrors the
## health-bar layout but in blue, with a "stored/max" text label.
## Values are floats so partial units (e.g. 2.5/10) display cleanly.
## Tooltip fluid bar. Optional `fluid_color_override` paints the fill in
## the specific fluid's tint (used by pipes so the bar reads as the
## actual fluid being carried instead of a generic blue). Optional
## `label_prefix` prepends a name to the readout — e.g. "Water 7 / 10".
func _add_tooltip_fluid_bar(stored: float, max_amount: float,
		fluid_color_override: Variant = null, label_prefix: String = "") -> void:
	if max_amount <= 0.0:
		return
	var pct: float = clampf(stored / max_amount, 0.0, 1.0)
	var bar_container := HBoxContainer.new()
	bar_container.add_theme_constant_override("separation", 6)
	bar_container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bar_bg := ColorRect.new()
	bar_bg.custom_minimum_size = Vector2(180, 10)
	bar_bg.color = Color(0.05, 0.12, 0.2, 0.85)
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bar_fill := ColorRect.new()
	# Default fill is the generic blue used by the per-block fluid
	# storage bars. Pipes pass in the fluid's own colour via override.
	var fill_color: Color = Color(0.3, 0.6, 1.0)
	if fluid_color_override is Color:
		fill_color = fluid_color_override
		fill_color.a = 1.0
	bar_fill.color = fill_color
	bar_fill.custom_minimum_size = Vector2(180 * pct, 10)
	bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bar_panel := Control.new()
	bar_panel.custom_minimum_size = Vector2(180, 10)
	bar_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_panel.add_child(bar_bg)
	bar_bg.position = Vector2.ZERO
	bar_bg.size = Vector2(180, 10)
	bar_panel.add_child(bar_fill)
	bar_fill.position = Vector2.ZERO
	bar_fill.size = Vector2(180 * pct, 10)

	bar_container.add_child(bar_panel)

	var fl_lbl := Label.new()
	# Show one decimal place when the stored amount isn't a whole
	# number — so a brand-new 0.5-unit drip reads as "0.5/10" instead
	# of rounding to 1.
	var stored_str: String = "%.1f" % stored if absf(stored - round(stored)) > 0.05 else "%.0f" % stored
	if label_prefix != "":
		fl_lbl.text = "%s %s / %.0f" % [label_prefix, stored_str, max_amount]
	else:
		fl_lbl.text = "%s / %.0f" % [stored_str, max_amount]
	fl_lbl.add_theme_font_size_override("font_size", 11)
	# Light tint of the fill colour so the label reads against the
	# tooltip background without being a hard primary colour.
	var lbl_color: Color = Color(0.7, 0.85, 1.0)
	if fluid_color_override is Color:
		lbl_color = (fluid_color_override as Color).lightened(0.5)
	fl_lbl.add_theme_color_override("font_color", lbl_color)
	fl_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_container.add_child(fl_lbl)

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
	# Lives inside the block menu, in the same slot as block_tooltip
	# (one of the two — or neither — is visible at a time). No own
	# anchors / background; block_menu provides both.
	build_cost_panel = PanelContainer.new()
	build_cost_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	build_cost_panel.visible = false
	build_cost_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	block_menu_outer_vbox.add_child(build_cost_panel)
	# Sit just under the tooltip (which is at index 0) but above the
	# separator + main_hbox.
	block_menu_outer_vbox.move_child(build_cost_panel, 1)

	build_cost_vbox = VBoxContainer.new()
	build_cost_vbox.add_theme_constant_override("separation", 4)
	build_cost_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	build_cost_panel.add_child(build_cost_vbox)


func _create_unit_mode_panel() -> void:
	# Flush to the bottom-right corner of the window — same convention as
	# the portrait panel in the top-left and the new block menu. The panel
	# is just an icon grid of currently-selected units; each cell has a
	# small count badge in the bottom-right when more than one of that
	# unit type is selected.
	unit_mode_panel = PanelContainer.new()
	unit_mode_panel.anchor_left = 1.0
	unit_mode_panel.anchor_right = 1.0
	unit_mode_panel.anchor_top = 1.0
	unit_mode_panel.anchor_bottom = 1.0
	unit_mode_panel.offset_left = -350
	unit_mode_panel.offset_right = 0
	unit_mode_panel.offset_bottom = 0
	unit_mode_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	unit_mode_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.04, 0.0, 0.85)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 0
	style.corner_radius_bottom_left = 0
	style.corner_radius_bottom_right = 0
	style.border_color = Color(0.7, 0.56, 0.0, 0.6)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 0
	style.border_width_bottom = 0
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	unit_mode_panel.add_theme_stylebox_override("panel", style)
	unit_mode_panel.visible = false
	unit_mode_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(unit_mode_panel)

	var outer_vbox := VBoxContainer.new()
	outer_vbox.add_theme_constant_override("separation", 6)
	unit_mode_panel.add_child(outer_vbox)

	unit_mode_icon_grid = HFlowContainer.new()
	unit_mode_icon_grid.add_theme_constant_override("h_separation", 4)
	unit_mode_icon_grid.add_theme_constant_override("v_separation", 4)
	unit_mode_icon_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer_vbox.add_child(unit_mode_icon_grid)

	var sep := HSeparator.new()
	outer_vbox.add_child(sep)

	unit_mode_buttons_vbox = VBoxContainer.new()
	unit_mode_buttons_vbox.add_theme_constant_override("separation", 3)
	outer_vbox.add_child(unit_mode_buttons_vbox)

	unit_mode_btn_cancel = _make_unit_cmd_button("Cancel Orders", _on_unit_cmd_cancel_orders)
	unit_mode_btn_hold_fire = _make_unit_cmd_button("Hold Fire", _on_unit_cmd_hold_fire)
	unit_mode_btn_hold_fire.toggle_mode = true
	unit_mode_btn_payload = _make_unit_cmd_button("Enter Payload Block", _on_unit_cmd_payload)
	unit_mode_btn_payload.toggle_mode = true
	unit_mode_btn_rebuild = _make_unit_cmd_button("Rebuild", _on_unit_cmd_rebuild)
	unit_mode_btn_mine = _make_unit_cmd_button("Mine", _on_unit_cmd_mine)
	unit_mode_btn_mine.toggle_mode = true
	unit_mode_btn_assist = _make_unit_cmd_button("Assist Player", _on_unit_cmd_assist)
	unit_mode_btn_assist.toggle_mode = true
	unit_mode_btn_attack_player = _make_unit_cmd_button("Attack Player", _on_unit_cmd_attack_player)
	unit_mode_btn_attack_block = _make_unit_cmd_button("Attack Nearest Block", _on_unit_cmd_attack_block)


func _make_unit_cmd_button(label: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.add_theme_font_size_override("font_size", 12)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.pressed.connect(cb)
	unit_mode_buttons_vbox.add_child(b)
	return b


# --- Command-button state helpers ---

func _selected_player_units() -> Array:
	var unit_mgr = _unit_mgr_ref()
	if unit_mgr == null:
		return []
	var out: Array = []
	for u in unit_mgr.selected_units:
		if u != null and is_instance_valid(u):
			out.append(u)
	return out


func _selection_can_build() -> bool:
	for u in _selected_player_units():
		var d = u.data if "data" in u else null
		if d and d.category == UnitData.UnitCategory.BUILDER:
			return true
	return false


func _selection_can_mine() -> bool:
	# No dedicated capability flag yet — we treat BUILDER units as
	# multi-role workers that can also mine. Easy to swap for a
	# dedicated `can_mine` flag on UnitData later.
	for u in _selected_player_units():
		var d = u.data if "data" in u else null
		if d and d.category == UnitData.UnitCategory.BUILDER:
			return true
	return false


func _update_unit_mode_buttons() -> void:
	var units: Array = _selected_player_units()
	# Dummy test-unit commands — visible only when a dummy enemy is selected.
	var has_dummy := false
	for u in units:
		if "is_dummy" in u and u.is_dummy:
			has_dummy = true
			break
	if unit_mode_btn_attack_player:
		unit_mode_btn_attack_player.visible = has_dummy
	if unit_mode_btn_attack_block:
		unit_mode_btn_attack_block.visible = has_dummy
	if unit_mode_btn_rebuild:
		unit_mode_btn_rebuild.visible = _selection_can_build()
	if unit_mode_btn_assist:
		unit_mode_btn_assist.visible = _selection_can_build()
		var any_assist := false
		for u in units:
			if "assist_player_build" in u and u.assist_player_build:
				any_assist = true
				break
		unit_mode_btn_assist.set_pressed_no_signal(any_assist)
	if unit_mode_btn_mine:
		unit_mode_btn_mine.visible = _selection_can_mine()
		var any_mine := false
		for u in units:
			if "mining_request_id" in u and u.mining_request_id != &"":
				any_mine = true
				break
		unit_mode_btn_mine.set_pressed_no_signal(any_mine)
	if unit_mode_btn_hold_fire:
		var any_hold := false
		for u in units:
			if "hold_fire" in u and u.hold_fire:
				any_hold = true
				break
		unit_mode_btn_hold_fire.set_pressed_no_signal(any_hold)
	if unit_mode_btn_payload:
		var any_payload := false
		for u in units:
			if "enter_payload_when_able" in u and u.enter_payload_when_able:
				any_payload = true
				break
		unit_mode_btn_payload.set_pressed_no_signal(any_payload)


# --- Button callbacks ---

func _on_unit_cmd_cancel_orders() -> void:
	for u in _selected_player_units():
		if u.has_method("clear_all_orders"):
			u.clear_all_orders()
		if "hold_fire" in u:
			u.hold_fire = false
		if "mining_request_id" in u:
			u.mining_request_id = &""
		if "assist_player_build" in u:
			u.assist_player_build = false
		if "enter_payload_when_able" in u:
			u.enter_payload_when_able = false
	_unit_mode_icons_signature = ""  # force a refresh next tick


func _on_unit_cmd_hold_fire() -> void:
	var on: bool = unit_mode_btn_hold_fire.button_pressed
	for u in _selected_player_units():
		if "hold_fire" in u:
			u.hold_fire = on


func _on_unit_cmd_payload() -> void:
	var on: bool = unit_mode_btn_payload.button_pressed
	for u in _selected_player_units():
		if "enter_payload_when_able" in u:
			u.enter_payload_when_able = on


func _on_unit_cmd_rebuild() -> void:
	# Wholesale rebuild — convert any DERELICT player buildings back to
	# LUMINA and queue every destroyed-ghost anchor for the active
	# build pipeline (drone or assisting selected units).
	if not main:
		return
	if not main.has_method("queue_rebuild_in_rect"):
		return
	# Compute the bounding box of every destroyed-player-building anchor
	# and feed it to the existing rect API. Fallback to a giant box if
	# nothing is recorded so the call is a no-op rather than an early
	# crash. The rect function does its own per-anchor work-range gate.
	var has_any := false
	var min_p := Vector2i(0, 0)
	var max_p := Vector2i(0, 0)
	if "destroyed_player_buildings" in main:
		for anchor in main.destroyed_player_buildings.keys():
			if not has_any:
				min_p = anchor
				max_p = anchor
				has_any = true
			else:
				min_p.x = mini(min_p.x, anchor.x)
				min_p.y = mini(min_p.y, anchor.y)
				max_p.x = maxi(max_p.x, anchor.x)
				max_p.y = maxi(max_p.y, anchor.y)
	if not has_any:
		return
	if main.has_method("convert_derelict_in_rect"):
		main.convert_derelict_in_rect(min_p, max_p)
	main.queue_rebuild_in_rect(min_p, max_p)


func _on_unit_cmd_assist() -> void:
	var on: bool = unit_mode_btn_assist.button_pressed
	for u in _selected_player_units():
		if "assist_player_build" in u:
			u.assist_player_build = on


func _on_unit_cmd_attack_player() -> void:
	var um = _unit_mgr_ref()
	if um and um.has_method("command_dummy_attack"):
		um.command_dummy_attack("attack_player")


func _on_unit_cmd_attack_block() -> void:
	var um = _unit_mgr_ref()
	if um and um.has_method("command_dummy_attack"):
		um.command_dummy_attack("attack_block")


func _on_unit_cmd_mine() -> void:
	if unit_mode_btn_mine.button_pressed:
		_open_mine_picker()
	else:
		for u in _selected_player_units():
			if "mining_request_id" in u:
				u.mining_request_id = &""


func _open_mine_picker() -> void:
	if _mine_picker_popup and is_instance_valid(_mine_picker_popup):
		_mine_picker_popup.queue_free()

	# Collect mineable ore types from the live terrain so we only show
	# what's actually reachable on this sector.
	var terrain = main.get_node_or_null("TerrainSystem")
	var ore_ids: Array[StringName] = []
	var seen: Dictionary = {}
	if terrain and "ore_tiles" in terrain:
		for cell in terrain.ore_tiles.keys():
			var tile_id = terrain.ore_tiles[cell]
			var tile_data = Registry.get_tile(tile_id)
			if tile_data == null:
				continue
			var rid := StringName(tile_data.minable_resource)
			if rid == &"" or seen.has(rid):
				continue
			seen[rid] = true
			ore_ids.append(rid)
	if ore_ids.is_empty():
		# Nothing to mine on this map — silently un-toggle.
		unit_mode_btn_mine.set_pressed_no_signal(false)
		return

	_mine_picker_popup = PopupPanel.new()
	add_child(_mine_picker_popup)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	_mine_picker_popup.add_child(v)
	var t := Label.new()
	t.text = "Mine what?"
	t.add_theme_font_size_override("font_size", 13)
	v.add_child(t)
	for rid in ore_ids:
		var item = Registry.get_item_or_fluid(rid)
		var b := Button.new()
		b.text = (item.display_name if item else String(rid))
		if item and item.icon:
			b.icon = item.icon
			b.expand_icon = true
			b.add_theme_constant_override("icon_max_width", 18)
		b.pressed.connect(_apply_mine_choice.bind(rid))
		v.add_child(b)
	_mine_picker_popup.popup_centered()


func _apply_mine_choice(item_id: StringName) -> void:
	for u in _selected_player_units():
		if "mining_request_id" in u:
			u.mining_request_id = item_id
	if _mine_picker_popup and is_instance_valid(_mine_picker_popup):
		_mine_picker_popup.queue_free()
		_mine_picker_popup = null


# Tracks the last rendered selection so we don't rebuild the icon grid every
# frame — keyed by an ordered list of "unit_id:count" pairs.
var _unit_mode_icons_signature: String = ""


func _update_unit_mode_icons() -> void:
	if unit_mode_icon_grid == null:
		return
	var unit_mgr = _unit_mgr_ref()
	if unit_mgr == null:
		return

	# Group selected units by unit-data id and count them.
	var counts: Dictionary = {}
	var order: Array[StringName] = []
	for unit in unit_mgr.selected_units:
		if unit == null or not is_instance_valid(unit):
			continue
		var data = unit.data if "data" in unit else null
		if data == null:
			continue
		var uid: StringName = data.id
		if not counts.has(uid):
			counts[uid] = {"count": 0, "icon": data.icon, "color": data.color}
			order.append(uid)
		counts[uid]["count"] += 1

	# Cheap diff: signature is order + count tuple. Skip the rebuild when
	# nothing observable changed.
	var sig := ""
	for uid in order:
		sig += String(uid) + ":" + str(counts[uid]["count"]) + ","
	# Distinguish "no units selected" from the empty-string signature
	# we'd produce on the first ever update, so the placeholder label
	# rebuilds when transitioning out of a real selection.
	if order.is_empty():
		sig = "<empty>"
	if sig == _unit_mode_icons_signature:
		return
	_unit_mode_icons_signature = sig

	for c in unit_mode_icon_grid.get_children():
		c.queue_free()

	if order.is_empty():
		# Placeholder when no units are selected — reads as "[no units
		# selected]" in the space where icons would normally live.
		var hint := Label.new()
		hint.text = "[no units selected]"
		hint.add_theme_font_size_override("font_size", 12)
		hint.add_theme_color_override("font_color", Color(0.8, 0.75, 0.55, 0.85))
		hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		unit_mode_icon_grid.add_child(hint)
		return

	for uid in order:
		var entry: Dictionary = counts[uid]
		unit_mode_icon_grid.add_child(_build_unit_mode_icon(entry["icon"], entry["color"], int(entry["count"])))


func _build_unit_mode_icon(icon: Texture2D, fallback_color: Color, count: int) -> Control:
	const CELL := 44

	# Free-form Control so we can absolutely-position the count badge in
	# the bottom-right corner on top of the icon. PanelContainer would
	# stretch children to fill, breaking the badge placement.
	var cell := Control.new()
	cell.custom_minimum_size = Vector2(CELL, CELL)
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bg := Panel.new()
	var cell_style := StyleBoxFlat.new()
	cell_style.bg_color = Color(0.1, 0.07, 0.0, 0.7)
	cell_style.set_corner_radius_all(4)
	cell_style.border_color = Color(0.7, 0.56, 0.0, 0.5)
	cell_style.set_border_width_all(1)
	bg.add_theme_stylebox_override("panel", cell_style)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(bg)

	if icon:
		var tex := TextureRect.new()
		tex.texture = icon
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex.anchor_right = 1.0
		tex.anchor_bottom = 1.0
		tex.offset_left = 4
		tex.offset_top = 4
		tex.offset_right = -4
		tex.offset_bottom = -4
		cell.add_child(tex)
	else:
		var sw := ColorRect.new()
		sw.color = fallback_color
		sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sw.anchor_right = 1.0
		sw.anchor_bottom = 1.0
		sw.offset_left = 6
		sw.offset_top = 6
		sw.offset_right = -6
		sw.offset_bottom = -6
		cell.add_child(sw)

	if count > 1:
		var count_label := Label.new()
		count_label.text = str(count)
		count_label.add_theme_font_size_override("font_size", 11)
		count_label.add_theme_color_override("font_color", Color(1, 1, 1))
		count_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		count_label.add_theme_constant_override("outline_size", 3)
		count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		count_label.anchor_left = 1.0
		count_label.anchor_right = 1.0
		count_label.anchor_top = 1.0
		count_label.anchor_bottom = 1.0
		count_label.offset_left = -22
		count_label.offset_top = -16
		count_label.offset_right = -2
		count_label.offset_bottom = -1
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		cell.add_child(count_label)

	return cell


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

			# Two-state colouring:
			#   • enough — white (neutral, "you have everything you need")
			#   • not enough — yellow (call-out, "this is the one missing")
			# The whole block icon dimming separately (in the block-select
			# menu) already conveys the "you can't afford ANY of this" state,
			# so we don't need a third red tier here.
			var have_color: Color
			if have >= required:
				have_color = Color(0.95, 0.95, 0.95)
			else:
				have_color = Color(0.95, 0.85, 0.2)

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
	# Also refresh the build-menu tinting (affordable vs not).
	_update_block_affordability_tint()

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
var _schematic_grid: GridContainer = null
var _schematic_search: LineEdit = null
var _selected_schematic_name: String = ""

const _SCHEMATIC_CARD_SIZE := 184.0
const _SCHEMATIC_PREVIEW_SIZE := 168.0

func _show_schematic_viewer() -> void:
	if _schematic_viewer and is_instance_valid(_schematic_viewer):
		_schematic_viewer.queue_free()

	# --- Mindustry-style schematics dialog: grid of preview cards. ---
	_schematic_viewer = PanelContainer.new()
	_schematic_viewer.anchor_left = 0.5
	_schematic_viewer.anchor_right = 0.5
	_schematic_viewer.anchor_top = 0.5
	_schematic_viewer.anchor_bottom = 0.5
	_schematic_viewer.offset_left = -440
	_schematic_viewer.offset_right = 440
	_schematic_viewer.offset_top = -300
	_schematic_viewer.offset_bottom = 300
	_schematic_viewer.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_schematic_viewer.grow_vertical = Control.GROW_DIRECTION_BOTH

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.11, 0.98)
	style.set_corner_radius_all(6)
	style.set_border_width_all(2)
	style.border_color = Color(0.32, 0.36, 0.42, 1.0)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	_schematic_viewer.add_theme_stylebox_override("panel", style)
	add_child(_schematic_viewer)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 8)
	_schematic_viewer.add_child(root_vbox)

	# Title bar
	var title_hbox := HBoxContainer.new()
	root_vbox.add_child(title_hbox)
	var title_lbl := Label.new()
	title_lbl.text = "Schematics"
	title_lbl.add_theme_font_size_override("font_size", 18)
	title_lbl.add_theme_color_override("font_color", Color(1, 0.85, 0.35))
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_hbox.add_child(title_lbl)
	var close_btn := Button.new()
	close_btn.text = "X"
	close_btn.pressed.connect(func(): _schematic_viewer.queue_free())
	title_hbox.add_child(close_btn)

	# Search row
	var search_row := HBoxContainer.new()
	search_row.add_theme_constant_override("separation", 6)
	root_vbox.add_child(search_row)
	var search_lbl := Label.new()
	search_lbl.text = "Search"
	search_lbl.add_theme_font_size_override("font_size", 13)
	search_lbl.add_theme_color_override("font_color", Color(0.75, 0.78, 0.84))
	search_row.add_child(search_lbl)
	_schematic_search = LineEdit.new()
	_schematic_search.placeholder_text = "Filter by name…"
	_schematic_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_schematic_search.text_changed.connect(func(_t): _refresh_schematic_list())
	search_row.add_child(_schematic_search)

	root_vbox.add_child(HSeparator.new())

	# Scrollable card grid.
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_vbox.add_child(scroll)

	_schematic_grid = GridContainer.new()
	_schematic_grid.columns = 4
	_schematic_grid.add_theme_constant_override("h_separation", 10)
	_schematic_grid.add_theme_constant_override("v_separation", 10)
	_schematic_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_schematic_grid)

	_refresh_schematic_list()


func _refresh_schematic_list() -> void:
	if _schematic_grid == null:
		return
	for c in _schematic_grid.get_children():
		c.queue_free()

	var filter: String = _schematic_search.text.strip_edges().to_lower() if _schematic_search else ""
	var names: PackedStringArray = SaveManager.list_schematics()
	var any: bool = false
	for sname in names:
		if filter != "" and not sname.to_lower().contains(filter):
			continue
		any = true
		_schematic_grid.add_child(_make_schematic_card(sname))

	if not any:
		var lbl := Label.new()
		lbl.text = "No schematics." if filter == "" else "No schematics match \"%s\"." % filter
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", Color(0.55, 0.58, 0.62))
		_schematic_grid.add_child(lbl)


## Builds one schematic card: tiled-background preview + name footer +
## hover border. Clicking opens the info dialog.
func _make_schematic_card(sname: String) -> Control:
	var data: Variant = SaveManager.load_schematic(sname)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(_SCHEMATIC_CARD_SIZE, _SCHEMATIC_CARD_SIZE + 36)
	var card_style := StyleBoxFlat.new()
	card_style.bg_color = Color(0.05, 0.06, 0.08, 1.0)
	card_style.set_corner_radius_all(4)
	card_style.set_border_width_all(2)
	card_style.border_color = Color(0.32, 0.36, 0.42, 1.0)
	card.add_theme_stylebox_override("panel", card_style)
	var hover_style := card_style.duplicate() as StyleBoxFlat
	hover_style.border_color = Color(1.0, 0.85, 0.35, 1.0)
	card.mouse_entered.connect(func(): card.add_theme_stylebox_override("panel", hover_style))
	card.mouse_exited.connect(func(): card.add_theme_stylebox_override("panel", card_style))

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	card.add_child(col)

	# --- Preview ---
	var preview_panel := PanelContainer.new()
	var preview_style := StyleBoxFlat.new()
	preview_style.bg_color = Color(0, 0, 0, 1)
	preview_panel.add_theme_stylebox_override("panel", preview_style)
	col.add_child(preview_panel)
	var preview := SchematicPreviewScript.new()
	preview.custom_minimum_size = Vector2(_SCHEMATIC_PREVIEW_SIZE, _SCHEMATIC_PREVIEW_SIZE)
	if data != null:
		preview.schematic = data
	preview_panel.add_child(preview)

	# --- Footer: name strip ---
	var footer := PanelContainer.new()
	var footer_style := StyleBoxFlat.new()
	footer_style.bg_color = Color(0.02, 0.03, 0.05, 1.0)
	footer_style.content_margin_left = 6
	footer_style.content_margin_right = 6
	footer_style.content_margin_top = 4
	footer_style.content_margin_bottom = 4
	footer.add_theme_stylebox_override("panel", footer_style)
	col.add_child(footer)
	var name_lbl := Label.new()
	name_lbl.text = sname
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.clip_text = true
	footer.add_child(name_lbl)

	# Make the whole card clickable. PanelContainer defaults to
	# MOUSE_FILTER_STOP so it already catches input; just wire
	# gui_input → open the info dialog on left-click.
	var captured_name: String = sname
	card.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_show_schematic_info(captured_name))
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	return card


## Mindustry-style info dialog: large preview + name + dims + block list
## + requirements + Place / Delete buttons.
func _show_schematic_info(sname: String) -> void:
	var data: Variant = SaveManager.load_schematic(sname)
	if data == null:
		return
	_selected_schematic_name = sname

	var popup := PopupPanel.new()
	popup.size = Vector2(540, 640)
	var pstyle := StyleBoxFlat.new()
	pstyle.bg_color = Color(0.08, 0.09, 0.12, 0.98)
	pstyle.set_border_width_all(2)
	pstyle.border_color = Color(0.32, 0.36, 0.42, 1.0)
	pstyle.set_corner_radius_all(6)
	pstyle.content_margin_left = 14
	pstyle.content_margin_right = 14
	pstyle.content_margin_top = 12
	pstyle.content_margin_bottom = 12
	popup.add_theme_stylebox_override("panel", pstyle)
	add_child(popup)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	popup.add_child(vbox)

	var title_lbl := Label.new()
	title_lbl.text = str(data.get("name", sname))
	title_lbl.add_theme_font_size_override("font_size", 18)
	title_lbl.add_theme_color_override("font_color", Color(1, 0.85, 0.35))
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title_lbl)

	var dim_lbl := Label.new()
	dim_lbl.text = "%d × %d tiles" % [int(data.get("width", 0)), int(data.get("height", 0))]
	dim_lbl.add_theme_font_size_override("font_size", 12)
	dim_lbl.add_theme_color_override("font_color", Color(0.65, 0.68, 0.72))
	dim_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(dim_lbl)

	# Big preview with tiled background.
	var preview_panel := PanelContainer.new()
	var preview_style := StyleBoxFlat.new()
	preview_style.bg_color = Color(0, 0, 0, 1)
	preview_style.set_border_width_all(2)
	preview_style.border_color = Color(0.42, 0.46, 0.52, 1.0)
	preview_panel.add_theme_stylebox_override("panel", preview_style)
	preview_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(preview_panel)
	var preview := SchematicPreviewScript.new()
	preview.custom_minimum_size = Vector2(360, 360)
	preview.schematic = data
	preview_panel.add_child(preview)

	# Requirements (icon + count pills).
	var total_cost: Dictionary = data.get("total_cost", {})
	if total_cost.is_empty():
		# Fall back to summing build costs ourselves if the schematic
		# was saved without a `total_cost` field.
		var blocks_data: Dictionary = data.get("blocks", {})
		for key in blocks_data:
			var bd = Registry.get_block(StringName(blocks_data[key]))
			if bd:
				for item_id in bd.build_cost:
					total_cost[item_id] = total_cost.get(item_id, 0) + bd.build_cost[item_id]
	if not total_cost.is_empty():
		var req_lbl := Label.new()
		req_lbl.text = "Requirements"
		req_lbl.add_theme_font_size_override("font_size", 12)
		req_lbl.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
		vbox.add_child(req_lbl)
		var req_wrap := HFlowContainer.new()
		req_wrap.add_theme_constant_override("h_separation", 10)
		req_wrap.add_theme_constant_override("v_separation", 4)
		vbox.add_child(req_wrap)
		for item_id in total_cost:
			# build_cost stores SHORT keys ("copper", "graphite") that
			# need to be resolved to canonical resource ids
			# ("mat_copper", …) via Main._resolve_resource_key before
			# the Registry lookup — otherwise the icon is null and the
			# requirements pills render as bare numbers.
			var lookup_id: StringName = StringName(item_id)
			if main and main.has_method("_resolve_resource_key"):
				lookup_id = main._resolve_resource_key(str(item_id))
			var item_data = Registry.get_item_or_fluid(lookup_id)
			if item_data == null:
				item_data = Registry.get_item_or_fluid(StringName(item_id))
			var pill := HBoxContainer.new()
			pill.add_theme_constant_override("separation", 3)
			if item_data and item_data.icon:
				var tex := TextureRect.new()
				tex.texture = item_data.icon
				tex.custom_minimum_size = Vector2(18, 18)
				tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				pill.add_child(tex)
			var clbl := Label.new()
			clbl.text = str(int(total_cost[item_id]))
			clbl.add_theme_font_size_override("font_size", 12)
			pill.add_child(clbl)
			req_wrap.add_child(pill)

	vbox.add_child(HSeparator.new())

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)
	var place_btn := Button.new()
	place_btn.text = "Place"
	place_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var data_ref: Dictionary = data
	place_btn.pressed.connect(func():
		var bsys = _building_sys_ref()
		if bsys:
			bsys.start_schematic_placement(data_ref)
		popup.queue_free()
		if _schematic_viewer and is_instance_valid(_schematic_viewer):
			_schematic_viewer.queue_free()
	)
	btn_row.add_child(place_btn)
	var del_btn := Button.new()
	del_btn.text = "Delete"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var del_name: String = sname
	del_btn.pressed.connect(func():
		SaveManager.delete_schematic(del_name)
		popup.queue_free()
		_refresh_schematic_list()
	)
	btn_row.add_child(del_btn)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_btn.pressed.connect(func(): popup.queue_free())
	btn_row.add_child(close_btn)

	popup.popup_centered()


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
	SaveManager.swap_scene_to_planet_select()


# =========================
# HELPERS
# =========================

## Returns all blocks belonging to a category, sorted by display name.
func _get_blocks_for_category(cat: int) -> Array[BlockData]:
	var result: Array[BlockData] = []
	var show_sources: bool = "show_sources" in main and main.show_sources
	for block in Registry.blocks_list:
		if block.category == cat:
			# Hide debug-only / map-editor-only blocks from the in-game palette.
			if block.id == &"power_source" or block.id == &"archive":
				continue
			# Developer source blocks only show when "Show Sources" is on.
			if (block.id == &"resource_source" or block.id == &"payload_source") and not show_sources:
				continue
			# Unit modules are constructor/payload-only — never shown in the
			# build palette (you can't place them directly).
			if block.tags.has("module"):
				continue
			# Only show blocks that are researched in the tech tree
			if main.require_research and TechTree.nodes.has(block.id) and not TechTree.is_researched(block.id):
				continue
			result.append(block)
	# Resource Source is dual-category: it also appears in the Fluids tab
	# (its base category is Items) when sources are shown.
	if cat == BlockData.BlockCategory.FLUIDS and show_sources:
		var rs := Registry.get_block(&"resource_source")
		if rs != null and not result.has(rs):
			result.append(rs)
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
	# The project defaults canvas texture filtering to NEAREST so the
	# block art reads as pixel art. Font glyphs get rendered into the
	# same canvas atlas though, so without an override the hint text
	# samples nearest and looks aliased at non-1× DPI. Force LINEAR
	# here for crisp readable text.
	hint_text_label.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
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
			elif ev.is_action_pressed("ui_cancel"):
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
	# Drop any cached scenes — the player committed to leaving the
	# session. A dangling parked Main reference (from a prior
	# sector-to-planet-map → planet-to-sector round trip) would
	# otherwise linger across the menu transition; the parked
	# PlanetSelect is also stale once MainMenu boots its own fresh
	# pre-park.
	SaveManager.discard_parked_main()
	SaveManager.discard_parked_planet_select()
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
	SaveManager.swap_scene_to_planet_select()


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
