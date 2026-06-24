extends Control
# ============================================================
# MINIMAP_FULLSCREEN.GD — full-screen map overlay
# ============================================================
# A large pannable / zoomable view of the whole sector. Reuses the corner
# Minimap's baked 1px-per-tile texture (no second bake). This is intentionally
# a dedicated black map screen, not a translucent enlarged copy of the corner
# widget.
#
# Open: M, or right-click the corner minimap. Close: M/Esc.
# ============================================================

var corner: Control      ## The corner Minimap — texture + map-dimension source.
var main: Node2D
var _unit_mgr: Node
var _camera: Camera2D
var _fog: Node

var _zoom := 1.0
var _pan := Vector2.ZERO
var _dragging := false
var _drag_moved := false
var _press_pos := Vector2.ZERO

const MIN_ZOOM := 0.5
const MAX_ZOOM := 8.0
const FIT_MARGIN := 0.94
const UNIT_MARKER_MIN := 5.0


func _ready() -> void:
	# Fill the whole viewport. Anchors + offsets preset, plus an explicit size,
	# because a Control parented to a CanvasLayer doesn't always get laid out
	# to full size from anchors alone.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	z_index = 60  # above the rest of the HUD
	visible = false
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)


## Forces the overlay rect to cover the entire viewport.
func _fit_to_viewport() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(_delta: float) -> void:
	if visible:
		queue_redraw()  # live unit dots + camera rect


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and ((event as InputEventKey).keycode == KEY_M \
			or (event as InputEventKey).keycode == KEY_ESCAPE):
		close()
		get_viewport().set_input_as_handled()


func is_open() -> bool:
	return visible


func open() -> void:
	if main == null:
		main = get_node_or_null("/root/Main")
	if _unit_mgr == null:
		_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if _camera == null:
		_camera = get_node_or_null("/root/Main/Camera2D")
	if _fog == null:
		_fog = get_node_or_null("/root/Main/FogSystem")
	_zoom = 1.0
	_pan = Vector2.ZERO
	_fit_to_viewport()
	if corner != null:
		corner.visible = false
	visible = true
	queue_redraw()


func close() -> void:
	visible = false
	if corner != null:
		corner.visible = true


func toggle() -> void:
	if visible:
		close()
	else:
		open()


# =========================
# INPUT
# =========================

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_drag_moved = false
				_press_pos = mb.position
			else:
				_dragging = false
				if not _drag_moved:
					_jump_camera_to(mb.position)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(mb.position, 1.15)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(mb.position, 1.0 / 1.15)
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		if mm.position.distance_to(_press_pos) > 4.0:
			_drag_moved = true
		_pan += mm.relative
		queue_redraw()
		accept_event()


## Recomputes pan so the texel under `screen_pos` stays put as the zoom changes.
func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var info := _map_layout()
	var texel: Vector2 = (screen_pos - info["tl"]) / info["scale"]
	_zoom = clampf(_zoom * factor, MIN_ZOOM, MAX_ZOOM)
	var new_scale: float = _fit_scale() * _zoom
	var new_size := Vector2(_mw(), _mh()) * new_scale
	_pan = screen_pos - texel * new_scale - size * 0.5 + new_size * 0.5
	queue_redraw()


## Left-click → move the game camera to the clicked world point, then close.
func _jump_camera_to(screen_pos: Vector2) -> void:
	if corner == null or main == null:
		return
	var info := _map_layout()
	var texel: Vector2 = (screen_pos - info["tl"]) / info["scale"]
	var world := texel * float(main.GRID_SIZE)
	if corner.has_method("request_camera_jump"):
		corner.request_camera_jump(world)
	close()


# =========================
# LAYOUT HELPERS
# =========================

func _mw() -> int:
	if corner != null and corner.has_method("get_map_size_tiles"):
		return int(corner.get_map_size_tiles().x)
	return 1

func _mh() -> int:
	if corner != null and corner.has_method("get_map_size_tiles"):
		return int(corner.get_map_size_tiles().y)
	return 1

## Scale that fits the whole map in the screen (before per-view zoom).
func _fit_scale() -> float:
	var w := maxi(_mw(), 1)
	var h := maxi(_mh(), 1)
	return minf(size.x / float(w), size.y / float(h)) * FIT_MARGIN

## Current map draw rect: { tl: top-left, scale: px/texel, size: map px size }.
func _map_layout() -> Dictionary:
	var scale := _fit_scale() * _zoom
	var msize := Vector2(_mw(), _mh()) * scale
	var tl := size * 0.5 - msize * 0.5 + _pan
	return {"tl": tl, "scale": scale, "size": msize}


# =========================
# DRAW
# =========================

func _draw() -> void:
	if corner == null or not corner.has_method("get_map_texture") or main == null:
		return
	var map_tex: Texture2D = corner.get_map_texture()
	if map_tex == null:
		return
	# Opaque map screen. This hides the world/HUD/corner minimap behind it,
	# matching Mindustry's full-screen map feel.
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, 1.0), true)

	var info := _map_layout()
	var tl: Vector2 = info["tl"]
	var scale: float = info["scale"]
	var map_rect := Rect2(tl, info["size"])
	draw_texture_rect(map_tex, map_rect, false)
	_draw_fog_overlay(tl, scale)

	var gs: float = float(main.GRID_SIZE)

	# Unit cutouts: same alpha-mask style as the Ctrl-hover overlay, scaled for map readability.
	if _unit_mgr != null:
		var lumina: Color = main.faction_color(main.Faction.LUMINA).lightened(0.35)
		var ferox: Color = main.faction_color(main.Faction.FEROX).lightened(0.35)
		_draw_unit_cutouts(_unit_mgr.player_units, lumina, tl, scale, gs)
		_draw_unit_cutouts(_unit_mgr.enemies, ferox, tl, scale, gs)

	# Player drone.
	var drone = get_node_or_null("/root/Main/PlayerDrone")
	if _should_draw_primary_drone() and drone != null and is_instance_valid(drone) and "position" in drone \
			and (not ("is_dead" in drone) or not drone.is_dead):
		var p: Vector2 = tl + (drone.position / gs) * scale
		if not _draw_single_unit_cutout(drone, p, Color(1.0, 0.95, 0.4), scale, gs):
			_draw_triangle_marker(p, 0.0, UNIT_MARKER_MIN + 1.0, Color(1.0, 0.95, 0.4))

	# Pulsing red outlines around blocks taking damage.
	_draw_damage_flashes(tl, scale, gs, map_rect)

	# Camera viewport rectangle.
	_draw_camera_rect(tl, scale, gs, map_rect)


## Mirrors the corner minimap's damage pulses on the full-screen map. Reuses
## the corner's shared flash dict + alpha curve so both views stay in sync.
func _draw_damage_flashes(tl: Vector2, scale: float, _gs: float, clip: Rect2) -> void:
	if corner == null or not corner.has_method("get_damage_flash"):
		return
	var flash: Dictionary = corner.get_damage_flash()
	if flash.is_empty():
		return
	var now: int = Time.get_ticks_msec()
	var expired: Array = []
	for anchor in flash.keys():
		var alpha: float = corner.damage_flash_alpha(int(flash[anchor]), now)
		if alpha < 0.0:
			expired.append(anchor)
			continue
		if not main.placed_buildings.has(anchor):
			expired.append(anchor)
			continue
		var gsize := Vector2i.ONE
		var data = Registry.get_block(main.placed_buildings[anchor])
		if data != null:
			gsize = data.grid_size
		var s_tl: Vector2 = tl + Vector2(anchor) * scale
		var s_br: Vector2 = tl + Vector2(anchor + gsize) * scale
		var r := Rect2(s_tl, s_br - s_tl).grow(1.0).intersection(clip)
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		# Same red as the corner minimap's DAMAGE_FLASH_COLOR.
		var col := Color(1.0, 0.18, 0.18, alpha)
		draw_rect(r, col, false, 2.0)
	for anchor in expired:
		flash.erase(anchor)


func _draw_unit_cutouts(units: Array, color: Color, tl: Vector2, scale: float, gs: float) -> void:
	for u in units:
		if not is_instance_valid(u) or u.is_dead:
			continue
		if u is CanvasItem and not (u as CanvasItem).visible:
			continue
		var p: Vector2 = tl + (u.position / gs) * scale
		if not _draw_single_unit_cutout(u, p, color, scale, gs):
			var angle: float = float(u.facing_angle) if "facing_angle" in u else 0.0
			_draw_triangle_marker(p, angle, maxf(UNIT_MARKER_MIN, scale * 2.2), color)


func _draw_single_unit_cutout(unit: Node, center: Vector2, color: Color, map_scale: float, gs: float) -> bool:
	var udata = unit.data if "data" in unit else null
	var face_angle: float = float(unit.facing_angle) if "facing_angle" in unit else 0.0
	var aim_angle: float = float(unit.aim_angle) if "aim_angle" in unit else face_angle
	if "drone_texture" in unit and unit.drone_texture != null:
		var dscale: float = _texture_cutout_scale(unit.drone_texture, map_scale, gs, 1.0)
		_draw_drone_cutout_texture(unit.drone_texture, center, face_angle, dscale, color)
		return true
	if udata != null and (udata.base_sprite != null or udata.head_sprite != null):
		var scale_f: float = _unit_cutout_scale(udata, map_scale, gs)
		var spr_off: float = udata.sprite_angle_offset if "sprite_angle_offset" in udata else 0.0
		if udata.base_sprite:
			_draw_cutout_texture(udata.base_sprite, center, face_angle + PI * 0.5 + spr_off, scale_f, color)
		if udata.head_sprite:
			_draw_cutout_texture(udata.head_sprite, center, aim_angle + PI * 0.5 + spr_off, scale_f, color)
		return true
	return false


func _should_draw_primary_drone() -> bool:
	return _unit_mgr == null or not ("controlled_entity" in _unit_mgr) or _unit_mgr.controlled_entity == null


func _unit_cutout_scale(udata, map_scale: float, gs: float) -> float:
	var base_scale: float = (udata.sprite_scale if udata.sprite_scale > 0.0 else 1.0) * main.SPRITE_SCALE_FACTOR
	return base_scale * map_scale / gs


func _texture_cutout_scale(_tex: Texture2D, map_scale: float, gs: float, base_scale: float) -> float:
	return base_scale * map_scale / gs


func _draw_cutout_texture(tex: Texture2D, center: Vector2, angle: float, scale_f: float, color: Color) -> void:
	if corner == null or not corner.has_method("get_silhouette_texture"):
		return
	var mask: Texture2D = corner.get_silhouette_texture(tex)
	if mask == null:
		return
	var sz := tex.get_size() * scale_f
	draw_set_transform(center, angle, Vector2.ONE)
	draw_texture_rect(mask, Rect2(-sz * 0.5, sz), false, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_drone_cutout_texture(tex: Texture2D, center: Vector2, angle: float, scale_f: float, color: Color) -> void:
	if corner == null or not corner.has_method("get_silhouette_texture"):
		return
	var mask: Texture2D = corner.get_silhouette_texture(tex)
	if mask == null:
		return
	var sz := tex.get_size() * scale_f
	var offset_y: float = sz.y * 0.05
	draw_set_transform(center, angle, Vector2.ONE)
	draw_texture_rect(mask, Rect2(Vector2(-sz.x * 0.5, -sz.y * 0.5 + offset_y), sz), false, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_triangle_marker(center: Vector2, angle: float, radius: float, color: Color) -> void:
	var fwd := Vector2.RIGHT.rotated(angle)
	var side := Vector2(-fwd.y, fwd.x)
	var pts := PackedVector2Array([
		center + fwd * radius,
		center - fwd * radius * 0.75 + side * radius * 0.55,
		center - fwd * radius * 0.75 - side * radius * 0.55,
	])
	draw_polygon(pts, PackedColorArray([color, color, color]))


func _draw_fog_overlay(tl: Vector2, scale: float) -> void:
	if _fog == null or main == null or corner == null:
		return
	if "fog_enabled" in main and not bool(main.fog_enabled):
		return
	var map_size := Vector2i.ONE
	if corner.has_method("get_map_size_tiles"):
		map_size = corner.get_map_size_tiles()
	var mw: int = maxi(1, int(map_size.x))
	var mh: int = maxi(1, int(map_size.y))
	for y in range(mh):
		for x in range(mw):
			var cell := Vector2i(x, y)
			if _fog.is_cell_visible(cell):
				continue
			var alpha: float = 0.78
			if _fog.is_cell_explored(cell):
				alpha = 0.35
			draw_rect(Rect2(tl + Vector2(x, y) * scale, Vector2(scale, scale)), Color(0, 0, 0, alpha), true)


func _draw_camera_rect(tl: Vector2, scale: float, gs: float, clip: Rect2) -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var zoom: Vector2 = _camera.zoom
	if zoom.x <= 0.0 or zoom.y <= 0.0:
		return
	var center: Vector2 = _camera.get_screen_center_position()
	var half: Vector2 = Vector2(vp.x / (2.0 * zoom.x), vp.y / (2.0 * zoom.y))
	var s_tl: Vector2 = tl + ((center - half) / gs) * scale
	var s_br: Vector2 = tl + ((center + half) / gs) * scale
	var r := Rect2(s_tl, s_br - s_tl).intersection(clip)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	draw_rect(r, Color(1.0, 0.85, 0.2, 0.95), false, 2.0)
