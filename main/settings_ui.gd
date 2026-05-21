extends CanvasLayer

# ============================================================
# SETTINGS_UI.GD - Settings Menu (opened from pause menu)
# ============================================================
# Tabbed interface: Game, Graphics, Sound, Controls, Game Data
# ============================================================

var is_open := false
var main: Node2D

var root_panel: PanelContainer
var tab_container: HBoxContainer
var content_panel: PanelContainer
var content_vbox: VBoxContainer
var current_tab := "Game"

const TABS := ["Game", "Graphics", "Sound", "Controls", "Game Data", "Developer"]
var tab_buttons: Dictionary = {}

# Controls tab: stores action → button mapping for rebinding
var _rebind_buttons: Dictionary = {}  # action_name → Button
var _awaiting_rebind: StringName = &""

# Rebindable actions with display names
const REBINDABLE_ACTIONS := {
	"move_up": "Move Up",
	"move_down": "Move Down",
	"move_left": "Move Left",
	"move_right": "Move Right",
	"pause_world": "Pause World",
	"rotate_clockwise": "Rotate Clockwise",
	"rotate_counter_clockwise": "Rotate Counter-Clockwise",
	"toggle_build_pause": "Toggle Build Pause",
	"toggle_link_mode": "Toggle Link Mode",
	"schematic_capture": "Schematic Capture",
	"rebuild_mode": "Rebuild Mode",
	"release_control": "Release Control",
	"respawn": "Respawn / Reset Drone",
	"open_tech_tree": "Open Tech Tree",
	"toggle_database": "Toggle Database",
}


func _ready() -> void:
	layer = 150
	process_mode = Node.PROCESS_MODE_ALWAYS
	main = get_node_or_null("/root/Main")
	_build_ui()
	visible = false


func show_settings() -> void:
	is_open = true
	visible = true
	_select_tab("Game")


func hide_settings() -> void:
	is_open = false
	visible = false
	_awaiting_rebind = &""


func _input(event: InputEvent) -> void:
	if not is_open:
		return

	# Rebinding mode: capture next key press
	if _awaiting_rebind != &"":
		if event is InputEventKey and event.pressed:
			_apply_rebind(_awaiting_rebind, event)
			get_viewport().set_input_as_handled()
			return
		if event is InputEventMouseButton and event.pressed:
			if event.button_index != MOUSE_BUTTON_LEFT:
				_apply_rebind(_awaiting_rebind, event)
				get_viewport().set_input_as_handled()
				return
		return

	if event.is_action_pressed("ui_cancel"):
		hide_settings()
		get_viewport().set_input_as_handled()


# =========================
# UI BUILDING
# =========================

func _build_ui() -> void:
	# Darken background
	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	# Main panel
	root_panel = PanelContainer.new()
	root_panel.anchor_left = 0.5
	root_panel.anchor_right = 0.5
	root_panel.anchor_top = 0.5
	root_panel.anchor_bottom = 0.5
	root_panel.offset_left = -320
	root_panel.offset_right = 320
	root_panel.offset_top = -250
	root_panel.offset_bottom = 250
	root_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	root_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.1, 0.97)
	style.border_color = Color(0.2, 0.3, 0.4, 0.6)
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	root_panel.add_theme_stylebox_override("panel", style)
	add_child(root_panel)

	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 8)
	root_panel.add_child(main_vbox)

	# Title
	var title = Label.new()
	title.text = "Settings"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.3, 0.75, 1.0))
	main_vbox.add_child(title)

	# Tab bar
	tab_container = HBoxContainer.new()
	tab_container.add_theme_constant_override("separation", 4)
	tab_container.alignment = BoxContainer.ALIGNMENT_CENTER
	main_vbox.add_child(tab_container)

	for tab_name in TABS:
		var btn = Button.new()
		btn.text = tab_name
		btn.add_theme_font_size_override("font_size", 13)
		btn.custom_minimum_size = Vector2(90, 30)
		btn.pressed.connect(_select_tab.bind(tab_name))
		tab_container.add_child(btn)
		tab_buttons[tab_name] = btn

	main_vbox.add_child(HSeparator.new())

	# Content area (scrollable)
	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	main_vbox.add_child(scroll)

	content_vbox = VBoxContainer.new()
	content_vbox.add_theme_constant_override("separation", 6)
	content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content_vbox)

	# Close button
	var close_btn = Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(0, 36)
	close_btn.add_theme_font_size_override("font_size", 14)
	close_btn.pressed.connect(hide_settings)
	main_vbox.add_child(close_btn)


func _select_tab(tab_name: String) -> void:
	current_tab = tab_name

	# Update tab button styles
	for tn in tab_buttons:
		var btn: Button = tab_buttons[tn]
		var active: bool = (tn == tab_name)
		var s = StyleBoxFlat.new()
		s.bg_color = Color(0.15, 0.25, 0.35, 0.9) if active else Color(0.08, 0.1, 0.14, 0.7)
		s.set_corner_radius_all(4)
		s.content_margin_left = 8
		s.content_margin_right = 8
		s.content_margin_top = 4
		s.content_margin_bottom = 4
		btn.add_theme_stylebox_override("normal", s)
		btn.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0) if active else Color(0.5, 0.55, 0.6))

	# Clear and rebuild content
	for c in content_vbox.get_children():
		c.queue_free()

	match tab_name:
		"Game":
			_build_game_tab()
		"Graphics":
			_build_graphics_tab()
		"Sound":
			_build_sound_tab()
		"Controls":
			_build_controls_tab()
		"Game Data":
			_build_game_data_tab()
		"Developer":
			_build_developer_tab()


# =========================
# GAME TAB
# =========================

func _build_game_tab() -> void:
	_add_section("General")
	_add_toggle("Show FPS", _get_show_fps(), func(v): _set_show_fps(v))
	# Autosave cadence: 5s..120s. HUD reads this every frame, so a change
	# takes effect on the next tick without restarting the sector.
	_add_range_slider("Autosave Interval",
		float(_get_setting("autosave_interval")), 5.0, 120.0, 1.0,
		func(v: float) -> String:
			if v >= 60.0:
				var m: int = int(v) / 60
				var s: int = int(v) % 60
				return "%dm %ds" % [m, s] if s > 0 else "%dm" % m
			return "%ds" % int(v),
		func(v):
			_set_setting("autosave_interval", float(v))
			var hud = get_node_or_null("/root/Main/HUD")
			if hud and "autosave_interval" in hud:
				hud.autosave_interval = float(v)
	)
	# Auto-pause the world when the game window loses focus (alt-tab,
	# minimise, click another app). Doesn't auto-unpause on return —
	# the player presses space when they're ready.
	_add_toggle("Pause When Window Loses Focus",
		bool(_get_setting("pause_on_unfocus")),
		func(v):
			_set_setting("pause_on_unfocus", bool(v))
			var main_node = get_node_or_null("/root/Main")
			if main_node and "pause_on_unfocus" in main_node:
				main_node.pause_on_unfocus = bool(v)
	)
	# Tech tree pan: ON = WASD scrolls the canvas; OFF = click-and-drag
	# pans it. The tech tree UI reads this every frame so a toggle takes
	# effect immediately while the panel is open.
	_add_toggle("Tech Tree: WASD to Move (off = drag)",
		bool(_get_setting("tech_tree_wasd")),
		func(v):
			_set_setting("tech_tree_wasd", bool(v))
			var tt_ui = get_node_or_null("/root/Main/TechTreeUI")
			if tt_ui and "wasd_pan" in tt_ui:
				tt_ui.wasd_pan = bool(v)
	)
	# Slider value = user-facing 0.1–2.0 sensitivity. Threshold (what the
	# camera actually consumes) is its inverse, clamped to 0.5–10.0.
	var saved_threshold: float = float(_get_setting("pan_rotate_threshold"))
	_add_slider("Trackpad Rotation Sensitivity", clampf(1.0 / saved_threshold, 0.1, 2.0),
		func(v):
			var threshold: float = clampf(1.0 / maxf(v, 0.1), 0.5, 10.0)
			_set_setting("pan_rotate_threshold", threshold)
			var c = get_node_or_null("/root/Main/Camera2D")
			if c and "pan_rotate_threshold" in c:
				c.pan_rotate_threshold = threshold
	)
	# Debug/replay buttons: fire the landing or launch animations on
	# the currently-loaded sector. Useful while iterating on the
	# launch_animation tunables — no need to relaunch the sector.
	_add_button_row("Play Land", _on_play_land_pressed,
		"Play Launch", _on_play_launch_pressed)
	_add_button("Play Explosion", _on_play_explosion_pressed)

func _get_show_fps() -> bool:
	return Engine.is_printing_error_messages()

func _set_show_fps(_v: bool) -> void:
	pass  # TODO: implement FPS counter


# =========================
# GRAPHICS TAB
# =========================

func _build_graphics_tab() -> void:
	_add_section("Display")
	_add_dropdown("Window Mode", ["Windowed", "Fullscreen", "Borderless Fullscreen"],
		int(_get_setting("window_mode")), func(idx):
			_set_setting("window_mode", int(idx))
			match idx:
				0: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
				1: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
				2: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
	)
	_add_toggle("VSync", bool(_get_setting("vsync")), func(v):
		_set_setting("vsync", bool(v))
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if v else DisplayServer.VSYNC_DISABLED)
	)
	_add_section("Effects")
	# Parallax: gives blocks the illusion of depth via a small camera-driven
	# side offset. Off by default — purely cosmetic and some players find it
	# distracting.
	_add_toggle("Parallax Effect",
		bool(_get_setting("parallax_enabled")),
		func(v):
			_set_setting("parallax_enabled", v)
			var building_sys = get_node_or_null("/root/Main/BuildingSystem")
			if building_sys and "parallax_enabled" in building_sys:
				building_sys.parallax_enabled = v
	)
	# Conveyor scroll: animates straight belt textures (and corner pieces
	# diagonally) so the surface visibly flows. Off by default — the
	# per-frame redraw it forces is wasted on machines with lots of belts
	# but no other moving overlay.
	_add_toggle("Animated Conveyor Belts",
		bool(_get_setting("belt_scroll_enabled")),
		func(v):
			_set_setting("belt_scroll_enabled", bool(v))
			var building_sys = get_node_or_null("/root/Main/BuildingSystem")
			if building_sys and "belt_scroll_enabled" in building_sys:
				building_sys.belt_scroll_enabled = bool(v)
	)


func _build_sound_tab() -> void:
	_add_section("Volume")
	_add_slider("Master Volume", float(_get_setting("volume_master")), func(v):
		_set_setting("volume_master", float(v))
		_set_bus_volume("Master", v)
	)
	_add_slider("Music Volume", float(_get_setting("volume_music")), func(v):
		_set_setting("volume_music", float(v))
		_set_bus_volume("Music", v)
	)
	_add_slider("SFX Volume", float(_get_setting("volume_sfx")), func(v):
		_set_setting("volume_sfx", float(v))
		_set_bus_volume("SFX", v)
	)


func _set_bus_volume(bus_name: String, linear: float) -> void:
	var idx = AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(linear))


# =========================
# CONTROLS TAB
# =========================

func _build_controls_tab() -> void:
	_add_section("Keybindings")
	_add_label("Click a binding, then press a key to rebind it.")

	_rebind_buttons.clear()
	for action in REBINDABLE_ACTIONS:
		var display_name: String = REBINDABLE_ACTIONS[action]
		var current_key: String = _get_action_key_name(action)

		var hbox = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 8)

		var name_lbl = Label.new()
		name_lbl.text = display_name
		name_lbl.add_theme_font_size_override("font_size", 13)
		name_lbl.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
		name_lbl.custom_minimum_size.x = 200
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(name_lbl)

		var key_btn = Button.new()
		key_btn.text = current_key
		key_btn.custom_minimum_size = Vector2(150, 28)
		key_btn.add_theme_font_size_override("font_size", 12)
		var action_id: StringName = StringName(action)
		key_btn.pressed.connect(func(): _start_rebind(action_id, key_btn))
		hbox.add_child(key_btn)

		var reset_btn = Button.new()
		reset_btn.text = "Reset"
		reset_btn.custom_minimum_size = Vector2(50, 28)
		reset_btn.add_theme_font_size_override("font_size", 11)
		reset_btn.pressed.connect(func(): _reset_binding(action_id))
		hbox.add_child(reset_btn)

		content_vbox.add_child(hbox)
		_rebind_buttons[action] = key_btn


func _get_action_key_name(action: String) -> String:
	var events = InputMap.action_get_events(StringName(action))
	if events.is_empty():
		return "[unbound]"
	var ev = events[0]
	if ev is InputEventKey:
		var kc: int = ev.physical_keycode if ev.physical_keycode != 0 else ev.keycode
		return OS.get_keycode_string(kc)
	if ev is InputEventMouseButton:
		match ev.button_index:
			MOUSE_BUTTON_LEFT: return "Left Click"
			MOUSE_BUTTON_RIGHT: return "Right Click"
			MOUSE_BUTTON_MIDDLE: return "Middle Click"
			MOUSE_BUTTON_WHEEL_UP: return "Scroll Up"
			MOUSE_BUTTON_WHEEL_DOWN: return "Scroll Down"
			_: return "Mouse %d" % ev.button_index
	return str(ev)


func _start_rebind(action: StringName, btn: Button) -> void:
	_awaiting_rebind = action
	btn.text = "Press a key..."
	btn.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))


func _apply_rebind(action: StringName, event: InputEvent) -> void:
	# Remove old events and add the new one
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, event)
	_awaiting_rebind = &""
	# Refresh display
	if _rebind_buttons.has(String(action)):
		var btn: Button = _rebind_buttons[String(action)]
		btn.text = _get_action_key_name(String(action))
		btn.remove_theme_color_override("font_color")
	# Save bindings
	_save_keybindings()


func _reset_binding(action: StringName) -> void:
	InputMap.action_erase_events(action)
	# Re-add the project default
	var _defaults = ProjectSettings.get_property_list()
	# Reload from ProjectSettings
	var key: String = "input/" + String(action)
	if ProjectSettings.has_setting(key):
		var setting = ProjectSettings.get_setting(key)
		if setting is Dictionary and setting.has("events"):
			for ev in setting["events"]:
				InputMap.action_add_event(action, ev)
	if _rebind_buttons.has(String(action)):
		_rebind_buttons[String(action)].text = _get_action_key_name(String(action))
	_save_keybindings()


func _save_keybindings() -> void:
	var data: Dictionary = {}
	for action in REBINDABLE_ACTIONS:
		var events = InputMap.action_get_events(StringName(action))
		if events.size() > 0:
			var ev = events[0]
			if ev is InputEventKey:
				data[action] = {"type": "key", "physical_keycode": ev.physical_keycode, "keycode": ev.keycode}
			elif ev is InputEventMouseButton:
				data[action] = {"type": "mouse", "button_index": ev.button_index}
	var file = FileAccess.open("user://keybindings.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()


## Persists the non-keybinding settings tweakable from the Settings UI
## (audio bus volumes, graphics mode, a handful of game/UX toggles).
## Separate file from keybindings so a bad schema in one can't corrupt
## the other.
##
## A single class-level cache `_cache` is the source of truth. The UI
## reads initial values from it, change callbacks write back into it
## (and apply to live scene-graph nodes when those exist), and disk
## writes serialise the cache directly. This means a setting toggled
## from the main menu — where Main / BuildingSystem / Camera2D don't
## exist yet — still persists, because the cache write doesn't depend
## on any node being live.
const _SETTINGS_PATH := "user://settings.json"

const _DEFAULTS := {
	"volume_master": 1.0,
	"volume_music": 1.0,
	"volume_sfx": 1.0,
	"window_mode": 0,
	"vsync": true,
	"require_research": true,
	"enemies_attack": true,
	"unlock_all_tech": false,
	"parallax_enabled": false,
	"belt_scroll_enabled": false,
	"pan_rotate_threshold": 1.5,
	"autosave_interval": 60.0,
	"tech_tree_wasd": false,
	"pause_on_unfocus": true,
	"show_hitboxes": false,
}

static var _cache: Dictionary = {}
static var _cache_loaded: bool = false


static func _ensure_cache_loaded() -> void:
	if _cache_loaded:
		return
	_cache_loaded = true
	if not FileAccess.file_exists(_SETTINGS_PATH):
		return
	var file = FileAccess.open(_SETTINGS_PATH, FileAccess.READ)
	if not file:
		return
	var json = JSON.parse_string(file.get_as_text())
	file.close()
	if json == null or not json is Dictionary:
		return
	# Only carry across keys we recognise — skips junk and old schema
	# leftovers without nuking the file.
	for k in json:
		if _DEFAULTS.has(k):
			_cache[k] = json[k]


static func _get_setting(key: String, fallback = null):
	_ensure_cache_loaded()
	if _cache.has(key):
		return _cache[key]
	if _DEFAULTS.has(key):
		return _DEFAULTS[key]
	return fallback


static func _set_setting(key: String, value) -> void:
	_ensure_cache_loaded()
	_cache[key] = value
	_write_cache_to_disk()


static func _write_cache_to_disk() -> void:
	var file = FileAccess.open(_SETTINGS_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(_cache, "\t"))
		file.close()


## Back-compat shim: callers that used to call `_save_settings()` after
## poking live nodes now go through `_set_setting` directly. We keep the
## method as a no-op so any leftover call site (or future autosave)
## doesn't break.
func _save_settings() -> void:
	_write_cache_to_disk()


## Loads settings from disk and applies them everywhere we can right
## now. Audio buses + window mode + vsync apply unconditionally. Game /
## UX entries that depend on `/root/Main/*` nodes are applied here too
## if those nodes exist, otherwise `apply_pending_settings` will pick
## them up once Main is ready.
static func load_settings() -> void:
	_ensure_cache_loaded()
	# Audio — apply to bus volumes immediately so the main menu reflects
	# the saved volume.
	for bus_entry in [["Master", "volume_master"], ["Music", "volume_music"], ["SFX", "volume_sfx"]]:
		var bus_name: String = bus_entry[0]
		var key: String = bus_entry[1]
		var idx: int = AudioServer.get_bus_index(bus_name)
		if idx >= 0:
			AudioServer.set_bus_volume_db(idx, linear_to_db(float(_get_setting(key))))
	# Graphics.
	match int(_get_setting("window_mode")):
		1: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		2: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		_: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if bool(_get_setting("vsync")) else DisplayServer.VSYNC_DISABLED
	)
	# Game / UX. TechTree.unlock_all is an autoload — always reachable.
	TechTree.unlock_all = bool(_get_setting("unlock_all_tech"))
	# The rest depend on the gameplay scene graph; apply now if it's up,
	# otherwise leave it for apply_pending_settings.
	apply_pending_settings()
	print("SettingsUI: Loaded settings from %s" % _SETTINGS_PATH)


## Applies settings that depend on scene-graph nodes (require_research
## on Main, parallax_enabled on BuildingSystem, camera sensitivity).
## Called from Main._ready() once those nodes exist; safe to call any
## time — silently skips nodes that aren't live yet.
static func apply_pending_settings() -> void:
	_ensure_cache_loaded()
	var tree = Engine.get_main_loop()
	var main_node = null
	if tree and tree.root:
		main_node = tree.root.get_node_or_null("Main")
	if main_node and "require_research" in main_node:
		main_node.require_research = bool(_get_setting("require_research"))
	if main_node and "enemies_attack" in main_node:
		main_node.enemies_attack = bool(_get_setting("enemies_attack"))
	if main_node and "show_hitboxes" in main_node:
		main_node.show_hitboxes = bool(_get_setting("show_hitboxes"))
	if main_node and "pause_on_unfocus" in main_node:
		main_node.pause_on_unfocus = bool(_get_setting("pause_on_unfocus"))
	var building_sys = main_node.get_node_or_null("BuildingSystem") if main_node else null
	if building_sys and "parallax_enabled" in building_sys:
		building_sys.parallax_enabled = bool(_get_setting("parallax_enabled"))
	if building_sys and "belt_scroll_enabled" in building_sys:
		building_sys.belt_scroll_enabled = bool(_get_setting("belt_scroll_enabled"))
	var cam = main_node.get_node_or_null("Camera2D") if main_node else null
	if cam and "pan_rotate_threshold" in cam:
		cam.pan_rotate_threshold = float(_get_setting("pan_rotate_threshold"))
	var hud = main_node.get_node_or_null("HUD") if main_node else null
	if hud and "autosave_interval" in hud:
		hud.autosave_interval = clampf(float(_get_setting("autosave_interval")), 5.0, 120.0)
	var tt_ui = main_node.get_node_or_null("TechTreeUI") if main_node else null
	if tt_ui and "wasd_pan" in tt_ui:
		tt_ui.wasd_pan = bool(_get_setting("tech_tree_wasd"))


static func load_keybindings() -> void:
	if not FileAccess.file_exists("user://keybindings.json"):
		return
	var file = FileAccess.open("user://keybindings.json", FileAccess.READ)
	if not file:
		return
	var json = JSON.parse_string(file.get_as_text())
	file.close()
	if json == null or not json is Dictionary:
		return
	for action in json:
		var entry: Dictionary = json[action]
		if not InputMap.has_action(StringName(action)):
			continue
		InputMap.action_erase_events(StringName(action))
		if entry.get("type", "") == "key":
			var ev = InputEventKey.new()
			ev.physical_keycode = int(entry.get("physical_keycode", 0))
			ev.keycode = int(entry.get("keycode", 0))
			InputMap.action_add_event(StringName(action), ev)
		elif entry.get("type", "") == "mouse":
			var ev = InputEventMouseButton.new()
			ev.button_index = int(entry.get("button_index", 0))
			InputMap.action_add_event(StringName(action), ev)
	print("SettingsUI: Loaded keybindings from user://keybindings.json")


# =========================
# GAME DATA TAB
# =========================

func _build_game_data_tab() -> void:
	_add_section("Save Data")
	_add_label("Manage your save data. Be careful — these actions cannot be undone!")

	var reset_campaign_btn = Button.new()
	reset_campaign_btn.text = "Reset Campaign Progress"
	reset_campaign_btn.custom_minimum_size = Vector2(0, 36)
	reset_campaign_btn.add_theme_font_size_override("font_size", 13)
	var rs = StyleBoxFlat.new()
	rs.bg_color = Color(0.3, 0.1, 0.1, 0.8)
	rs.set_corner_radius_all(4)
	rs.content_margin_left = 12
	rs.content_margin_right = 12
	reset_campaign_btn.add_theme_stylebox_override("normal", rs)
	reset_campaign_btn.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))
	reset_campaign_btn.pressed.connect(func():
		SaveManager.reset_campaign()
		TechTree.load_save_data({})
		reset_campaign_btn.text = "Campaign Reset!"
		reset_campaign_btn.disabled = true
	)
	content_vbox.add_child(reset_campaign_btn)

	var reset_keys_btn = Button.new()
	reset_keys_btn.text = "Reset Keybindings"
	reset_keys_btn.custom_minimum_size = Vector2(0, 36)
	reset_keys_btn.add_theme_font_size_override("font_size", 13)
	var ks = StyleBoxFlat.new()
	ks.bg_color = Color(0.15, 0.15, 0.2, 0.8)
	ks.set_corner_radius_all(4)
	ks.content_margin_left = 12
	ks.content_margin_right = 12
	reset_keys_btn.add_theme_stylebox_override("normal", ks)
	reset_keys_btn.pressed.connect(func():
		DirAccess.remove_absolute("user://keybindings.json")
		# Reload defaults from project settings
		InputMap.load_from_project_settings()
		reset_keys_btn.text = "Keybindings Reset!"
		reset_keys_btn.disabled = true
	)
	content_vbox.add_child(reset_keys_btn)


# =========================
# DEVELOPER TAB
# =========================

func _build_developer_tab() -> void:
	_add_section("Cheats")
	_add_toggle("Require Research to Place Blocks",
		bool(_get_setting("require_research")),
		func(v):
			_set_setting("require_research", bool(v))
			if main:
				main.require_research = v
				var hud = get_node_or_null("/root/Main/HUD")
				if hud and hud.has_method("_refresh_block_menu"):
					hud._refresh_block_menu()
	)
	_add_toggle("Enemies Attack",
		bool(_get_setting("enemies_attack")),
		func(v):
			_set_setting("enemies_attack", bool(v))
			if main:
				main.enemies_attack = v
	)
	_add_toggle("Show Hitboxes",
		bool(_get_setting("show_hitboxes")),
		func(v):
			_set_setting("show_hitboxes", bool(v))
			if main:
				main.show_hitboxes = v
				main.queue_redraw()
				for unit in get_tree().get_nodes_in_group("enemy_units"):
					if unit and is_instance_valid(unit):
						unit.queue_redraw()
				var drone = get_node_or_null("/root/Main/PlayerDrone")
				if drone:
					drone.queue_redraw()
	)
	_add_toggle("Unlock All Tech (sandbox)",
		bool(_get_setting("unlock_all_tech")),
		func(v):
			_set_setting("unlock_all_tech", bool(v))
			TechTree.unlock_all = v
			for nid in TechTree.nodes:
				TechTree.node_state_changed.emit(nid, TechTree.get_state(nid))
			var hud = get_node_or_null("/root/Main/HUD")
			if hud and hud.has_method("_refresh_block_menu"):
				hud._refresh_block_menu()
			var tree_ui = get_node_or_null("/root/Main/TechTreeUI")
			if tree_ui:
				if "tree_canvas" in tree_ui and tree_ui.tree_canvas:
					tree_ui.tree_canvas.queue_redraw()
				if tree_ui.has_method("_update_resource_panel"):
					tree_ui._update_resource_panel()
	)

	_add_section("Debug Actions")
	var reset_archive_btn = Button.new()
	reset_archive_btn.text = "Reset Archive Research"
	reset_archive_btn.custom_minimum_size = Vector2(0, 36)
	reset_archive_btn.add_theme_font_size_override("font_size", 13)
	var ars = StyleBoxFlat.new()
	ars.bg_color = Color(0.3, 0.1, 0.1, 0.8)
	ars.set_corner_radius_all(4)
	ars.content_margin_left = 12
	ars.content_margin_right = 12
	reset_archive_btn.add_theme_stylebox_override("normal", ars)
	reset_archive_btn.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))
	reset_archive_btn.pressed.connect(func():
		# Wipe amount_spent on every archive node so the -D-archive_id
		# markers go LOCKED again and any tech gated on them re-locks.
		for aid in TechTree.archive_ids:
			if TechTree.nodes.has(aid):
				TechTree.nodes[aid]["amount_spent"] = {}
				TechTree.node_state_changed.emit(aid, TechTree.get_state(aid))
		# Clear in-world decoder progress so the player has to decode again.
		var ad_sys_reset = get_node_or_null("/root/Main/ArchiveDecoderSystem")
		if ad_sys_reset and "states" in ad_sys_reset:
			ad_sys_reset.states.clear()
		# Refresh any open UI that depends on archive state.
		for nid in TechTree.nodes:
			TechTree.node_state_changed.emit(nid, TechTree.get_state(nid))
		var hud = get_node_or_null("/root/Main/HUD")
		if hud and hud.has_method("_refresh_block_menu"):
			hud._refresh_block_menu()
		var tree_ui = get_node_or_null("/root/Main/TechTreeUI")
		if tree_ui and "tree_canvas" in tree_ui and tree_ui.tree_canvas:
			tree_ui.tree_canvas.queue_redraw()
		reset_archive_btn.text = "Archive Research Reset!"
		reset_archive_btn.disabled = true
	)
	content_vbox.add_child(reset_archive_btn)


# =========================
# WIDGET HELPERS
# =========================

func _add_section(title: String) -> void:
	var lbl = Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color(0.3, 0.75, 1.0))
	content_vbox.add_child(lbl)
	content_vbox.add_child(HSeparator.new())


## Adds a horizontal row with two buttons. Used by the General tab
## "Play Land / Play Launch" debug controls.
func _add_button_row(label_a: String, on_a: Callable, label_b: String, on_b: Callable) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var btn_a = Button.new()
	btn_a.text = label_a
	btn_a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_a.pressed.connect(on_a)
	hbox.add_child(btn_a)
	var btn_b = Button.new()
	btn_b.text = label_b
	btn_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_b.pressed.connect(on_b)
	hbox.add_child(btn_b)
	content_vbox.add_child(hbox)


## Adds a single full-width button. Used for the "Play Explosion"
## debug control which has no natural sibling.
func _add_button(label: String, on_pressed: Callable) -> void:
	var btn = Button.new()
	btn.text = label
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(on_pressed)
	content_vbox.add_child(btn)


## Plays the explosion animation centered on the player's core.
## No-op if Main / ExplosionSystem / core anchor aren't available.
func _on_play_explosion_pressed() -> void:
	var main_node = get_node_or_null("/root/Main")
	if main_node == null:
		push_warning("Play Explosion: no Main scene — open a sector first.")
		return
	var expl = main_node.get_node_or_null("ExplosionSystem")
	if expl == null or not expl.has_method("explode"):
		push_warning("Play Explosion: ExplosionSystem not found.")
		return
	var core_pos: Vector2i = main_node.core_position if "core_position" in main_node else Vector2i(-1, -1)
	if core_pos == Vector2i(-1, -1):
		push_warning("Play Explosion: no core_position on Main.")
		return
	var gs: float = float(main_node.GRID_SIZE)
	var core_size := Vector2(3.0, 3.0)
	var core_id: StringName = main_node.placed_buildings.get(core_pos, &"") if "placed_buildings" in main_node else &""
	if core_id != &"":
		var core_data = Registry.get_block(core_id)
		if core_data:
			core_size = Vector2(core_data.grid_size.x, core_data.grid_size.y)
	var core_world: Vector2 = main_node.grid_to_world(core_pos) + Vector2(core_size.x * gs * 0.5, core_size.y * gs * 0.5)
	expl.explode(core_world)
	_close_settings_and_pause_menu()


## Plays the landing animation on the currently-loaded sector. No-op
## if Main / LaunchAnimation / core anchor aren't available.
func _on_play_land_pressed() -> void:
	var main_node = get_node_or_null("/root/Main")
	if main_node == null:
		push_warning("Play Land: no Main scene — open a sector first.")
		return
	var la = main_node.get_node_or_null("LaunchAnimation")
	if la == null or not la.has_method("play_landing"):
		push_warning("Play Land: LaunchAnimation not found.")
		return
	var core_pos: Vector2i = main_node.core_position if "core_position" in main_node else Vector2i(-1, -1)
	if core_pos == Vector2i(-1, -1):
		push_warning("Play Land: no core_position on Main.")
		return
	if la.has_method("snapshot_prebuilt"):
		la.snapshot_prebuilt()
	la.play_landing(core_pos)
	_close_settings_and_pause_menu()


## Plays the launching animation on the currently-loaded sector.
func _on_play_launch_pressed() -> void:
	var main_node = get_node_or_null("/root/Main")
	if main_node == null:
		push_warning("Play Launch: no Main scene — open a sector first.")
		return
	var la = main_node.get_node_or_null("LaunchAnimation")
	if la == null or not la.has_method("play_launch"):
		push_warning("Play Launch: LaunchAnimation not found.")
		return
	la.play_launch()
	_close_settings_and_pause_menu()


## Closes the settings overlay AND the underlying pause/escape menu so
## the player sees the animation play unobstructed.
func _close_settings_and_pause_menu() -> void:
	hide_settings()
	var hud = get_node_or_null("/root/Main/HUD")
	if hud and hud.has_method("_close_escape_menu") and hud.escape_menu_open:
		hud._close_escape_menu()


func _add_label(text: String) -> void:
	var lbl = Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.5, 0.55, 0.6))
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content_vbox.add_child(lbl)


func _add_toggle(label_text: String, initial: bool, callback: Callable) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var lbl = Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(lbl)
	var toggle = CheckButton.new()
	toggle.button_pressed = initial
	toggle.toggled.connect(callback)
	hbox.add_child(toggle)
	content_vbox.add_child(hbox)


func _add_slider(label_text: String, initial: float, callback: Callable) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var lbl = Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	lbl.custom_minimum_size.x = 140
	hbox.add_child(lbl)
	var slider = HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.x = 200
	slider.value_changed.connect(callback)
	hbox.add_child(slider)
	var val_lbl = Label.new()
	val_lbl.text = "%d%%" % int(initial * 100)
	val_lbl.add_theme_font_size_override("font_size", 12)
	val_lbl.custom_minimum_size.x = 40
	slider.value_changed.connect(func(v): val_lbl.text = "%d%%" % int(v * 100))
	hbox.add_child(val_lbl)
	content_vbox.add_child(hbox)


func _add_range_slider(label_text: String, initial: float, min_v: float, max_v: float, step: float, format_cb: Callable, callback: Callable) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var lbl = Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	lbl.custom_minimum_size.x = 140
	hbox.add_child(lbl)
	var slider = HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.value = clampf(initial, min_v, max_v)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.x = 200
	slider.value_changed.connect(callback)
	hbox.add_child(slider)
	var val_lbl = Label.new()
	val_lbl.text = format_cb.call(slider.value)
	val_lbl.add_theme_font_size_override("font_size", 12)
	val_lbl.custom_minimum_size.x = 60
	slider.value_changed.connect(func(v): val_lbl.text = format_cb.call(v))
	hbox.add_child(val_lbl)
	content_vbox.add_child(hbox)


func _add_dropdown(label_text: String, options: Array, initial_idx: int, callback: Callable) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var lbl = Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(lbl)
	var opt = OptionButton.new()
	for o in options:
		opt.add_item(o)
	opt.selected = initial_idx
	opt.item_selected.connect(callback)
	hbox.add_child(opt)
	content_vbox.add_child(hbox)
