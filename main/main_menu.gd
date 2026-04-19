extends Control

# ============================================================
# MAIN_MENU.GD - Title Screen / Main Menu
# ============================================================
# Builds the entire title screen in code:
#   - Full-screen background image (or dark fallback)
#   - Title logo centered near the top
#   - 3x2 grid of image-backed menu buttons
#
# SCENE TREE (built in _ready):
#   MainMenu (Control)
#   ├── Background (TextureRect)
#   ├── VBoxContainer (centers everything vertically)
#   │   ├── TitleImage (TextureRect)
#   │   ├── Spacer
#   │   └── GridContainer (2 columns)
#   │       ├── Campaign button
#   │       ├── Editor button
#   │       ├── Mods button
#   │       ├── Core Database button
#   │       ├── Settings button
#   │       └── Multiplayer button
# ============================================================


# =========================
# CONSTANTS
# =========================

const BUTTON_LABELS := [
	"Campaign",
	"Editor",
	"Mods",
	"Core Database",
	"Settings",
	"Multiplayer",
]

const BUTTON_SCALE := 2.5
const TITLE_SCALE := 5.0
const GRID_COLUMNS := 2
const GRID_H_SEP := 14
const GRID_V_SEP := 12
const BUTTON_FONT_SIZE := 16


# =========================
# STATE
# =========================

var bg_texture: Texture2D
var _planet_select_scene: PackedScene
var title_texture: Texture2D
var button_texture: Texture2D
var database_ui: CanvasLayer

# --- LOADING SCREEN ---
var _loading_screen: Control
var _loading_bar: ColorRect
var _loading_label: Label
var _loading_done := false


# =========================
# INITIALIZATION
# =========================

func _ready() -> void:
	_build_loading_screen()
	# Don't build the real UI until loading is done
	if Registry.essentials_loaded and TechTree.is_loaded:
		_finish_loading()
	# Otherwise _process will poll


func _process(_delta: float) -> void:
	if _loading_done:
		return
	# Update loading bar
	var registry_progress: float = Registry.load_progress
	var tech_progress: float = 1.0 if TechTree.is_loaded else 0.5
	var total_progress: float = registry_progress * 0.8 + tech_progress * 0.2
	if _loading_bar:
		_loading_bar.size.x = _loading_screen.size.x * 0.6 * total_progress
	if _loading_label:
		_loading_label.text = "Loading... %d%%" % int(total_progress * 100)

	# Check if essentials are ready
	if Registry.essentials_loaded and TechTree.is_loaded:
		_finish_loading()


func _finish_loading() -> void:
	_loading_done = true
	if _loading_screen:
		_loading_screen.queue_free()
		_loading_screen = null
	# Load saved keybindings
	var settings_script = load("res://main/settings_ui.gd")
	if settings_script:
		settings_script.load_keybindings()
	_load_textures()
	_build_background()
	_build_ui()
	_build_database_ui()
	# Pre-build PlanetSelect in background so Campaign loads instantly
	_prebuild_planet_select()
	# Pre-load sector maps
	_preload_sector_maps()


func _prebuild_planet_select() -> void:
	# Pre-load the scene resource so it's cached (faster instantiation later)
	_planet_select_scene = load("res://main/PlanetSelect.tscn") as PackedScene
	print("MainMenu: PlanetSelect pre-built (hidden)")


func _preload_sector_maps() -> void:
	# Pre-load all sector map files via threaded requests so they're cached
	for sector in Registry.sectors_list:
		if sector.map_path != "":
			ResourceLoader.load_threaded_request(sector.map_path)
	print("MainMenu: Sector maps queued for pre-load")


func _build_loading_screen() -> void:
	_loading_screen = Control.new()
	_loading_screen.anchor_right = 1.0
	_loading_screen.anchor_bottom = 1.0
	add_child(_loading_screen)

	# Dark background
	var bg = ColorRect.new()
	bg.color = Color(0.02, 0.03, 0.05)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	_loading_screen.add_child(bg)

	# Title text
	var title_lbl = Label.new()
	title_lbl.text = "FACTDUSTRY"
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.anchor_left = 0.5
	title_lbl.anchor_right = 0.5
	title_lbl.anchor_top = 0.35
	title_lbl.offset_left = -200
	title_lbl.offset_right = 200
	title_lbl.add_theme_font_size_override("font_size", 36)
	title_lbl.add_theme_color_override("font_color", Color(0.9, 0.85, 0.5))
	_loading_screen.add_child(title_lbl)

	# Loading label
	_loading_label = Label.new()
	_loading_label.text = "Loading... 0%"
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.anchor_left = 0.5
	_loading_label.anchor_right = 0.5
	_loading_label.anchor_top = 0.55
	_loading_label.offset_left = -100
	_loading_label.offset_right = 100
	_loading_label.add_theme_font_size_override("font_size", 14)
	_loading_label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))
	_loading_screen.add_child(_loading_label)

	# Loading bar background
	var bar_bg = ColorRect.new()
	bar_bg.color = Color(0.1, 0.12, 0.15)
	bar_bg.anchor_left = 0.2
	bar_bg.anchor_right = 0.8
	bar_bg.anchor_top = 0.6
	bar_bg.offset_top = 0
	bar_bg.offset_bottom = 8
	_loading_screen.add_child(bar_bg)

	# Loading bar fill
	_loading_bar = ColorRect.new()
	_loading_bar.color = Color(0.9, 0.8, 0.3)
	_loading_bar.position = bar_bg.position
	_loading_bar.anchor_left = 0.2
	_loading_bar.anchor_top = 0.6
	_loading_bar.offset_top = 0
	_loading_bar.offset_bottom = 8
	_loading_bar.size.x = 0
	_loading_screen.add_child(_loading_bar)


func _load_textures() -> void:
	# Background: prefer MMB.jpeg, fall back to the old MainScreenBackground.png
	if ResourceLoader.exists("res://textures/UI/MMB.jpeg"):
		bg_texture = load("res://textures/UI/MMB.jpeg")
	elif ResourceLoader.exists("res://textures/UI/MainScreenBackground.png"):
		bg_texture = load("res://textures/UI/MainScreenBackground.png")

	title_texture = load("res://textures/UI/Title.png")
	button_texture = load("res://textures/UI/Button.png")


# =========================
# BACKGROUND
# =========================

func _build_background() -> void:
	# Dark fallback color behind everything
	var bg_color = ColorRect.new()
	bg_color.color = Color(0.201, 0.473, 0.294, 1.0)
	bg_color.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg_color)

	if bg_texture:
		var bg_rect = TextureRect.new()
		bg_rect.texture = bg_texture
		bg_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		add_child(bg_rect)


# =========================
# DATABASE UI
# =========================

func _build_database_ui() -> void:
	var db_script = load("res://main/database_ui.gd")
	database_ui = CanvasLayer.new()
	database_ui.set_script(db_script)
	database_ui.name = "DatabaseUI"
	add_child(database_ui)


# =========================
# UI LAYOUT
# =========================

func _build_ui() -> void:
	# Main vertical container — centered on screen
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_CENTER)
	vbox.grow_horizontal = Control.GROW_DIRECTION_BOTH
	vbox.grow_vertical = Control.GROW_DIRECTION_BOTH
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 228)
	vbox.anchor_top = 0.4
	vbox.anchor_bottom = 0.35
	vbox.anchor_left = 0.5
	vbox.anchor_right = 0.5

	add_child(vbox)

	# --- Title Image ---
	_build_title(vbox)

	# --- Button Grid ---
	_build_button_grid(vbox)


func _build_title(parent: VBoxContainer) -> void:
	if not title_texture:
		return

	var title_rect = TextureRect.new()
	title_rect.texture = title_texture
	title_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	title_rect.expand_mode = TextureRect.EXPAND_KEEP_SIZE
	title_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

	# Scale up the pixel-art title
	var tex_size = title_texture.get_size()
	var scaled_size = tex_size * TITLE_SCALE
	title_rect.custom_minimum_size = scaled_size
	title_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	title_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	title_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	parent.add_child(title_rect)


func _build_button_grid(parent: VBoxContainer) -> void:
	var grid = GridContainer.new()
	grid.columns = GRID_COLUMNS
	grid.add_theme_constant_override("h_separation", GRID_H_SEP)
	grid.add_theme_constant_override("v_separation", GRID_V_SEP)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	parent.add_child(grid)

	for i in range(BUTTON_LABELS.size()):
		var btn = _make_menu_button(BUTTON_LABELS[i])
		btn.pressed.connect(_on_button_pressed.bind(BUTTON_LABELS[i]))
		grid.add_child(btn)


# =========================
# BUTTON FACTORY
# =========================

func _make_menu_button(text: String) -> TextureButton:
	var btn = TextureButton.new()
	btn.texture_normal = button_texture
	btn.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED

	# Scale up the pixel-art button
	var tex_size = button_texture.get_size() if button_texture else Vector2(80, 24)
	btn.custom_minimum_size = tex_size * BUTTON_SCALE

	# Hover/press modulation
	btn.modulate = Color(1, 1, 1, 1)
	btn.mouse_entered.connect(_on_btn_hover.bind(btn))
	btn.mouse_exited.connect(_on_btn_unhover.bind(btn))

	# Label centered on the button
	var label = Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.add_theme_font_size_override("font_size", BUTTON_FONT_SIZE)
	label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.85))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(label)

	return btn


# =========================
# HOVER EFFECTS
# =========================

func _on_btn_hover(btn: TextureButton) -> void:
	btn.modulate = Color(1.3, 1.3, 1.3, 1)


func _on_btn_unhover(btn: TextureButton) -> void:
	btn.modulate = Color(1, 1, 1, 1)


# =========================
# BUTTON ACTIONS
# =========================

func _on_button_pressed(label: String) -> void:
	match label:
		"Campaign":
			SaveManager.return_to_menu = true
			if _planet_select_scene:
				# Use cached scene resource for faster instantiation
				var instance = _planet_select_scene.instantiate()
				get_tree().root.add_child(instance)
				get_tree().current_scene.queue_free()
				get_tree().current_scene = instance
			else:
				get_tree().change_scene_to_file("res://main/PlanetSelect.tscn")
		"Core Database":
			if database_ui:
				database_ui._show_ui()
		"Editor":
			get_tree().change_scene_to_file("res://main/MapEditor.tscn")
		"Mods":
			print("MainMenu: Mods — not yet implemented")
		"Settings":
			print("MainMenu: Settings — not yet implemented")
		"Multiplayer":
			print("MainMenu: Multiplayer — not yet implemented")
