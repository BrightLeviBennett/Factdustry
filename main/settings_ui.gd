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

const TABS := ["Game", "Graphics", "Sound", "Controls", "Game Data"]
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
		btn.custom_minimum_size = Vector2(100, 30)
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


# =========================
# GAME TAB
# =========================

func _build_game_tab() -> void:
	_add_section("General")
	_add_toggle("Show FPS", _get_show_fps(), func(v): _set_show_fps(v))
	_add_toggle("Autosave", true, func(_v): pass)  # Placeholder
	_add_toggle("Require Research to Place Blocks",
		main.require_research if main else true,
		func(v):
			if main:
				main.require_research = v
				var hud = get_node_or_null("/root/Main/HUD")
				if hud and hud.has_method("_refresh_block_menu"):
					hud._refresh_block_menu()
			_save_settings()
	)
	_add_toggle("Enemies Attack",
		main.enemies_attack if main else true,
		func(v):
			if main:
				main.enemies_attack = v
			_save_settings()
	)
	_add_toggle("Unlock All Tech (sandbox)",
		TechTree.unlock_all,
		func(v):
			TechTree.unlock_all = v
			# Notify listeners that node states have effectively changed so
			# the HUD block menu and any open tech tree UI refresh immediately.
			for nid in TechTree.nodes:
				TechTree.node_state_changed.emit(nid, TechTree.get_state(nid))
			var hud = get_node_or_null("/root/Main/HUD")
			if hud and hud.has_method("_refresh_block_menu"):
				hud._refresh_block_menu()
			# The tech tree renders into its internal tree_canvas Control.
			# queue_redraw on the CanvasLayer doesn't propagate to a Control
			# child, so redraw the canvas directly. Any open tooltip is
			# refreshed too so ??? names update instantly.
			var tree_ui = get_node_or_null("/root/Main/TechTreeUI")
			if tree_ui:
				if "tree_canvas" in tree_ui and tree_ui.tree_canvas:
					tree_ui.tree_canvas.queue_redraw()
				if tree_ui.has_method("_update_resource_panel"):
					tree_ui._update_resource_panel()
			_save_settings()
	)
	_add_toggle("Parallax Effect",
		true,
		func(v):
			var building_sys = get_node_or_null("/root/Main/BuildingSystem")
			if building_sys and "parallax_enabled" in building_sys:
				building_sys.parallax_enabled = v
			_save_settings()
	)
	var cam = get_node_or_null("/root/Main/Camera2D")
	var current_sens: float = cam.pan_rotate_threshold if cam and "pan_rotate_threshold" in cam else 1.5
	_add_slider("Trackpad Rotation Sensitivity", clampf(1.0 / current_sens, 0.1, 2.0),
		func(v):
			var c = get_node_or_null("/root/Main/Camera2D")
			if c and "pan_rotate_threshold" in c:
				# Higher slider = more sensitive = lower threshold
				c.pan_rotate_threshold = clampf(1.0 / maxf(v, 0.1), 0.5, 10.0)
			_save_settings()
	)

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
		_get_window_mode_index(), func(idx):
			match idx:
				0: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
				1: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
				2: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
			_save_settings()
	)
	_add_toggle("VSync", DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED, func(v):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if v else DisplayServer.VSYNC_DISABLED)
		_save_settings()
	)

func _get_window_mode_index() -> int:
	match DisplayServer.window_get_mode():
		DisplayServer.WINDOW_MODE_FULLSCREEN: return 1
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN: return 2
		_: return 0


# =========================
# SOUND TAB
# =========================

func _build_sound_tab() -> void:
	_add_section("Volume")
	_add_slider("Master Volume", _get_bus_volume("Master"), func(v):
		_set_bus_volume("Master", v)
		_save_settings()
	)
	_add_slider("Music Volume", _get_bus_volume("Music"), func(v):
		_set_bus_volume("Music", v)
		_save_settings()
	)
	_add_slider("SFX Volume", _get_bus_volume("SFX"), func(v):
		_set_bus_volume("SFX", v)
		_save_settings()
	)

func _get_bus_volume(bus_name: String) -> float:
	var idx = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return 1.0
	return db_to_linear(AudioServer.get_bus_volume_db(idx))

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
## (audio bus volumes, graphics mode, a handful of game/UX toggles). Called
## from every change callback so the on-disk file stays in sync with the
## running settings. Separate file from keybindings so a bad schema in one
## can't corrupt the other.
const _SETTINGS_PATH := "user://settings.json"

func _save_settings() -> void:
	var data: Dictionary = {}
	# Audio.
	data["volume_master"] = _get_bus_volume("Master")
	data["volume_music"] = _get_bus_volume("Music")
	data["volume_sfx"] = _get_bus_volume("SFX")
	# Graphics.
	data["window_mode"] = _get_window_mode_index()
	data["vsync"] = DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED
	# Game / UX.
	if main and "require_research" in main:
		data["require_research"] = bool(main.require_research)
	if main and "enemies_attack" in main:
		data["enemies_attack"] = bool(main.enemies_attack)
	data["unlock_all_tech"] = bool(TechTree.unlock_all)
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	if building_sys and "parallax_enabled" in building_sys:
		data["parallax_enabled"] = bool(building_sys.parallax_enabled)
	var cam = get_node_or_null("/root/Main/Camera2D")
	if cam and "pan_rotate_threshold" in cam:
		data["pan_rotate_threshold"] = float(cam.pan_rotate_threshold)

	var file = FileAccess.open(_SETTINGS_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()


## Loads settings saved by `_save_settings`. Called from the main menu at
## launch so the running instance reflects the on-disk settings before the
## settings UI is opened (which otherwise builds its controls against the
## engine defaults). Silent no-op when the file doesn't exist.
static func load_settings() -> void:
	if not FileAccess.file_exists(_SETTINGS_PATH):
		return
	var file = FileAccess.open(_SETTINGS_PATH, FileAccess.READ)
	if not file:
		return
	var json = JSON.parse_string(file.get_as_text())
	file.close()
	if json == null or not json is Dictionary:
		return
	var data: Dictionary = json
	# Audio.
	for bus_entry in [["Master", "volume_master"], ["Music", "volume_music"], ["SFX", "volume_sfx"]]:
		var bus_name: String = bus_entry[0]
		var key: String = bus_entry[1]
		if data.has(key):
			var idx: int = AudioServer.get_bus_index(bus_name)
			if idx >= 0:
				AudioServer.set_bus_volume_db(idx, linear_to_db(float(data[key])))
	# Graphics.
	if data.has("window_mode"):
		match int(data["window_mode"]):
			1: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			2: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
			_: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if data.has("vsync"):
		DisplayServer.window_set_vsync_mode(
			DisplayServer.VSYNC_ENABLED if bool(data["vsync"]) else DisplayServer.VSYNC_DISABLED
		)
	# Game / UX — scene graph nodes may not exist yet when this runs from
	# the main menu; defer the ones that depend on `/root/Main/*` so they
	# apply once the game scene is loaded.
	if data.has("unlock_all_tech"):
		TechTree.unlock_all = bool(data["unlock_all_tech"])
	# Stash the rest on the engine singleton metadata for the game scene
	# to pick up on load.
	Engine.set_meta(&"_pending_settings", data)
	print("SettingsUI: Loaded settings from %s" % _SETTINGS_PATH)


## Applies settings that depend on scene-graph nodes (require_research on
## Main, parallax_enabled on BuildingSystem, camera sensitivity). Called
## from Main._ready() once those nodes exist.
static func apply_pending_settings() -> void:
	if not Engine.has_meta(&"_pending_settings"):
		return
	var data: Dictionary = Engine.get_meta(&"_pending_settings")
	Engine.remove_meta(&"_pending_settings")
	var main_node = Engine.get_main_loop().root.get_node_or_null("Main") if Engine.get_main_loop() else null
	if main_node and data.has("require_research") and "require_research" in main_node:
		main_node.require_research = bool(data["require_research"])
	if main_node and data.has("enemies_attack") and "enemies_attack" in main_node:
		main_node.enemies_attack = bool(data["enemies_attack"])
	var building_sys = main_node.get_node_or_null("BuildingSystem") if main_node else null
	if building_sys and data.has("parallax_enabled") and "parallax_enabled" in building_sys:
		building_sys.parallax_enabled = bool(data["parallax_enabled"])
	var cam = main_node.get_node_or_null("Camera2D") if main_node else null
	if cam and data.has("pan_rotate_threshold") and "pan_rotate_threshold" in cam:
		cam.pan_rotate_threshold = float(data["pan_rotate_threshold"])


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
# WIDGET HELPERS
# =========================

func _add_section(title: String) -> void:
	var lbl = Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color(0.3, 0.75, 1.0))
	content_vbox.add_child(lbl)
	content_vbox.add_child(HSeparator.new())


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
