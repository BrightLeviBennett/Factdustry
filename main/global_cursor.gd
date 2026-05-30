extends Node

## Project-wide custom mouse cursor. Autoloaded as `GlobalCursor` so it
## paints across every scene — main menu, planet select, sectors,
## anywhere — without each scene having to rebuild its own cursor
## pipeline.
##
## Why not `Input.set_custom_mouse_cursor`?
## That API uses the texture at its native size on most platforms (no
## auto-scaling), so a high-resolution source PNG comes out enormous.
## We bypass it entirely — hide the OS cursor via CSS-style trickery
## (`Input.MOUSE_MODE_HIDDEN` only while the window has focus AND the
## pointer is inside, never on bare hover-of-unfocused) and paint our
## own sprite on a top-of-stack CanvasLayer at a fixed display size.
##
## Auto-focus avoidance:
## On some platforms `Input.set_mouse_mode(MOUSE_MODE_HIDDEN)` raises
## the window when called on a hover-but-unfocused window. To prevent
## that we ONLY swap mouse mode after `focus_entered` fires — i.e.
## the player has explicitly clicked or alt-tabbed to focus the
## game. Bare hover does NOT change mouse_mode.
##
## API:
##   set_override(tex)   — temporarily replace the default cursor with
##                         this texture (used by HUD when Drill /
##                         Target / Wrench should show instead).
##   clear_override()    — restore the default.

const _CURSOR_DEFAULT_PATH := "res://textures/mouse heads/DefualtMouse.png"
const _CURSOR_DISPLAY_SIZE := 40.0     # on-screen size in viewport px

var _layer: CanvasLayer = null
var _sprite: TextureRect = null
var _default_tex: Texture2D = null
var _override_tex: Texture2D = null
# True when the player has actually focused the game window (clicked
# in, alt-tabbed in). False while the window is merely hovered without
# focus — in which case we leave mouse_mode VISIBLE so the OS arrow
# shows and we don't accidentally trigger the auto-focus side-effect.
var _window_focused: bool = false
# True while the pointer is currently inside the window's client area.
# Tracked separately from focus so we can restore the OS cursor when
# the pointer leaves the window (e.g. moves onto the title bar or
# another monitor) even while the window still has focus.
var _mouse_inside: bool = true


func _ready() -> void:
	print("global_cursor ready")
	process_mode = Node.PROCESS_MODE_ALWAYS
	_default_tex = load(_CURSOR_DEFAULT_PATH) as Texture2D
	# Top-of-stack CanvasLayer so the sprite paints above EVERY HUD
	# panel — including the pause menu (200), settings dialogs, and
	# the clean-save dialog (300). A previous value of 127 worked
	# against the bog-standard HUD chrome but ended up *underneath*
	# modal overlays, so the OS cursor was hidden, our painted cursor
	# was occluded, and the player couldn't see what they were
	# clicking. 9999 is well above anything the project assigns and
	# stays within Godot 4's int32 layer range.
	_layer = CanvasLayer.new()
	_layer.name = "GlobalCursorLayer"
	_layer.layer = 9999
	add_child(_layer)
	_sprite = TextureRect.new()
	_sprite.name = "Cursor"
	_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_sprite.size = Vector2(_CURSOR_DISPLAY_SIZE, _CURSOR_DISPLAY_SIZE)
	# Force smooth bilinear filtering on the cursor specifically — the
	# project default is nearest-neighbour (pixel-art friendly), which
	# makes the upscaled cursor PNG look stair-steppy. Mipmaps on top
	# kill the residual shimmer from sub-pixel cursor motion.
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_sprite.texture = _default_tex
	_sprite.visible = false  # start invisible until focus_entered fires
	_layer.add_child(_sprite)
	# Focus + mouse-enter/exit signals. The combined state
	# (focused AND mouse-inside) decides whether to hide the OS
	# cursor and paint our sprite. mouse_exited always restores the
	# OS cursor — safe regardless of focus, no auto-focus side-effect.
	var win := get_window()
	if win != null:
		win.focus_entered.connect(_on_focus_entered)
		win.focus_exited.connect(_on_focus_exited)
		win.mouse_entered.connect(_on_mouse_entered)
		win.mouse_exited.connect(_on_mouse_exited)
	# Best-effort initial state: if the window already has focus at
	# load time, light up the custom cursor.
	if win != null and win.has_focus():
		_on_focus_entered()


func _on_focus_entered() -> void:
	_window_focused = true
	# Mouse-mode handling tied to FOCUS, not mouse-enter. Focus fires
	# well before the player starts moving the mouse around, so the
	# OS cursor is already hidden by the time the pointer crosses
	# into the client area — no brief flash on entry.
	if Input.get_mouse_mode() != Input.MOUSE_MODE_HIDDEN:
		Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
	_refresh_sprite()


func _on_focus_exited() -> void:
	_window_focused = false
	# Restore the OS cursor on focus loss so the player sees the
	# system arrow over title bar / other apps. Most platforms also
	# show the native cursor over title bar / borders even while
	# MOUSE_MODE_HIDDEN, but explicitly setting VISIBLE here makes
	# the "alt-tab away" path unambiguous.
	if Input.get_mouse_mode() != Input.MOUSE_MODE_VISIBLE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_refresh_sprite()


func _on_mouse_entered() -> void:
	_mouse_inside = true
	# Re-hide the OS cursor when the pointer comes back into the
	# client area (e.g. moving down from the title bar). There can
	# be a 1-frame flash here on some platforms because the OS
	# cursor crosses the boundary before Godot's signal fires —
	# accept it as the trade for getting the OS arrow over the
	# title bar / other apps when the mouse is outside.
	if _window_focused and Input.get_mouse_mode() != Input.MOUSE_MODE_HIDDEN:
		Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
	_refresh_sprite()


func _on_mouse_exited() -> void:
	_mouse_inside = false
	# Mouse left the window's client area — restore the OS arrow
	# so the player sees a normal cursor on the title bar, window
	# borders, and any other apps the cursor is now over.
	if Input.get_mouse_mode() != Input.MOUSE_MODE_VISIBLE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_refresh_sprite()


## Sprite visibility evaluator. Custom cursor sprite shows only when
## both the window has focus AND the pointer is inside the window.
func _refresh_sprite() -> void:
	if _sprite != null:
		_sprite.visible = _window_focused and _mouse_inside


func _process(_delta: float) -> void:
	if _sprite == null or not _sprite.visible:
		return
	var mp: Vector2 = _layer.get_viewport().get_mouse_position()
	# Hotspot at the center so UI hit-test (which uses the OS-reported
	# mouse position) lines up with where the player visually clicks.
	_sprite.position = mp - _sprite.size * 0.5


## Replace the default cursor with `tex` until `clear_override` runs.
func set_override(tex: Texture2D) -> void:
	_override_tex = tex
	if _sprite != null:
		_sprite.texture = tex if tex != null else _default_tex


## Restore the project-wide default cursor.
func clear_override() -> void:
	set_override(null)
