extends Control

# ============================================================
# MINIMAP.GD - Mindustry-style minimap renderer
# ============================================================
# One backing Image/ImageTexture at 1 pixel per tile, shared by the corner
# widget and the full-screen view. The corner widget draws a camera-centered
# crop, while the full-screen overlay draws the whole texture.
# ============================================================

const VIEW_PX := 196.0
const MARGIN := 12.0
const BASE_VIEW_TILES := 16.0
const MIN_CORNER_ZOOM := 1.0
const MAX_CORNER_ZOOM := 64.0
const DIRTY_FLUSH_INTERVAL := 2.0 / 60.0
const DOT_RADIUS := 2.5
const TERRAIN_DIRTY_RADIUS := 9
const EDGE_FADE_START := 9.0
const EDGE_FADE_STRENGTH := 0.72
## How long after the last hit a block keeps pulsing its red damage outline.
const DAMAGE_FLASH_MS := 750
## Damage-pulse colour + cadence (Hz).
const DAMAGE_FLASH_COLOR := Color(1.0, 0.18, 0.18)
const DAMAGE_FLASH_HZ := 3.0

var main: Node2D
var _terrain: Node2D
var _unit_mgr: Node
var _camera: Camera2D
var _fog: Node
var _fullscreen: Control

var _img: Image
var _tex: ImageTexture
var _map_w := 0
var _map_h := 0
var _tile_color_cache := {}
var _silhouette_cache := {}

var _dirty_cells := {}
var _dirty_accum := 0.0
var _needs_full_rebuild := true
var _corner_zoom := 4.0

## Anchor (Vector2i) → expiry tick (msec). A block in here pulses a red
## outline until `Time.get_ticks_msec()` passes its expiry. Shared with the
## full-screen overlay via `get_damage_flash()`.
var _damage_flash := {}

var _dragging := false
var _owns_focus := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	main = get_node_or_null("/root/Main")
	_terrain = get_node_or_null("/root/Main/TerrainSystem")
	_unit_mgr = get_node_or_null("/root/Main/UnitManager")
	_camera = get_node_or_null("/root/Main/Camera2D")
	_fog = get_node_or_null("/root/Main/FogSystem")
	_connect_change_signals()
	var fs_script: Script = load("res://main/minimap_fullscreen.gd")
	if fs_script != null:
		_fullscreen = fs_script.new()
		_fullscreen.name = "MinimapFullscreen"
		_fullscreen.corner = self
		get_parent().add_child.call_deferred(_fullscreen)
	_rebuild_all()


func _connect_change_signals() -> void:
	if main != null:
		if main.has_signal("building_placed") and not main.building_placed.is_connected(_on_building_placed):
			main.building_placed.connect(_on_building_placed)
		if main.has_signal("building_destroyed") and not main.building_destroyed.is_connected(_on_building_destroyed):
			main.building_destroyed.connect(_on_building_destroyed)
		if main.has_signal("building_faction_changed") and not main.building_faction_changed.is_connected(_on_building_faction_changed):
			main.building_faction_changed.connect(_on_building_faction_changed)
		if main.has_signal("building_damaged") and not main.building_damaged.is_connected(_on_building_damaged):
			main.building_damaged.connect(_on_building_damaged)
	if _terrain != null:
		if _terrain.has_signal("terrain_changed") and not _terrain.terrain_changed.is_connected(_mark_terrain_dirty):
			_terrain.terrain_changed.connect(_mark_terrain_dirty)
		if _terrain.has_signal("walls_changed") and not _terrain.walls_changed.is_connected(_mark_full_rebuild):
			_terrain.walls_changed.connect(_mark_full_rebuild)


func _process(delta: float) -> void:
	if main == null or _terrain == null:
		return
	_layout()
	if int(main.GRID_WIDTH) != _map_w or int(main.GRID_HEIGHT) != _map_h:
		_needs_full_rebuild = true
	if _needs_full_rebuild:
		_rebuild_all()
	else:
		_dirty_accum += delta
		if _dirty_accum >= DIRTY_FLUSH_INTERVAL:
			_dirty_accum = 0.0
			_flush_dirty()

	if _dragging:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_dragging = false
			_owns_focus = false
			if _camera != null and is_instance_valid(_camera):
				_camera.focus_override = null
		elif _camera != null and is_instance_valid(_camera):
			_camera.focus_override = _local_to_world(get_local_mouse_position())
	elif _owns_focus and _player_took_control():
		_owns_focus = false
		if _camera != null and is_instance_valid(_camera):
			_camera.focus_override = null

	queue_redraw()


func _player_took_control() -> bool:
	return Input.is_action_pressed("move_up") or Input.is_action_pressed("move_down") \
			or Input.is_action_pressed("move_left") or Input.is_action_pressed("move_right")


func request_camera_jump(world: Vector2) -> void:
	if _camera != null and is_instance_valid(_camera):
		_camera.focus_override = world
		_owns_focus = true


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_M:
		var focused = get_viewport().gui_get_focus_owner()
		if focused is LineEdit or focused is TextEdit:
			return
		if _fullscreen != null:
			_fullscreen.toggle()
			get_viewport().set_input_as_handled()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if _fullscreen != null:
				_fullscreen.open()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = true
			if _camera != null and is_instance_valid(_camera):
				_camera.focus_override = _local_to_world(get_local_mouse_position())
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_by(-0.5)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_by(0.5)
			accept_event()


func zoom_by(amount: float) -> void:
	set_corner_zoom(_corner_zoom + amount)


func set_corner_zoom(value: float) -> void:
	_corner_zoom = clampf(value, MIN_CORNER_ZOOM, _max_corner_zoom())


func get_corner_zoom() -> float:
	return _corner_zoom


func get_map_texture() -> Texture2D:
	return _tex


func get_map_size_tiles() -> Vector2i:
	return Vector2i(_map_w, _map_h)


func get_silhouette_texture(tex: Texture2D) -> Texture2D:
	if tex == null:
		return null
	var key := tex.get_rid()
	if _silhouette_cache.has(key):
		return _silhouette_cache[key]
	var src: Image = tex.get_image()
	if src == null:
		return null
	var img := Image.create(src.get_width(), src.get_height(), false, Image.FORMAT_RGBA8)
	for y in range(src.get_height()):
		for x in range(src.get_width()):
			var p: Color = src.get_pixel(x, y)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, p.a))
	var mask := ImageTexture.create_from_image(img)
	_silhouette_cache[key] = mask
	return mask


func _max_corner_zoom() -> float:
	var smallest: float = float(maxi(1, mini(_map_w, _map_h)))
	return maxf(MIN_CORNER_ZOOM, minf(MAX_CORNER_ZOOM, smallest / BASE_VIEW_TILES / 2.0))


# =========================
# BASE IMAGE
# =========================

func _rebuild_all() -> void:
	if main == null or _terrain == null:
		return
	var w: int = int(main.GRID_WIDTH)
	var h: int = int(main.GRID_HEIGHT)
	if w <= 0 or h <= 0:
		return
	var resized := _img == null or _map_w != w or _map_h != h
	if resized:
		_map_w = w
		_map_h = h
		_img = Image.create(w, h, false, Image.FORMAT_RGBA8)
		_tex = null
		_layout()
		set_corner_zoom(_corner_zoom)
	for y in range(_map_h):
		for x in range(_map_w):
			_write_cell(Vector2i(x, y))
	if _tex == null:
		_tex = ImageTexture.create_from_image(_img)
	else:
		_tex.update(_img)
	_dirty_cells.clear()
	_needs_full_rebuild = false


func _flush_dirty() -> void:
	if _dirty_cells.is_empty() or _img == null:
		return
	for cell in _dirty_cells.keys():
		if _in_bounds(cell):
			_write_cell(cell)
	_dirty_cells.clear()
	if _tex == null:
		_tex = ImageTexture.create_from_image(_img)
	else:
		_tex.update(_img)


func _write_cell(cell: Vector2i) -> void:
	var col := _color_for_cell(cell)
	_img.set_pixel(cell.x, cell.y, col)


func _color_for_cell(cell: Vector2i) -> Color:
	if main == null or _terrain == null:
		return Color(0, 0, 0, 0)
	var col := Color(0, 0, 0, 0)
	if _terrain.floor_tiles.has(cell):
		col = _tile_map_color(StringName(_terrain.floor_tiles[cell]))
	if _terrain.wall_tiles.has(cell):
		col = _wall_map_color(StringName(_terrain.wall_tiles[cell]))
	elif cell.y < _map_h - 1 and _terrain.wall_tiles.has(cell + Vector2i(0, 1)):
		col = col.darkened(0.3)
	if _terrain.ore_tiles.has(cell):
		col = _tile_map_color(StringName(_terrain.ore_tiles[cell]))
	if _terrain.floor_tiles.has(cell):
		var td = Registry.get_tile(StringName(_terrain.floor_tiles[cell]))
		if td != null and td.is_liquid:
			var north := cell + Vector2i(0, 1)
			var north_liquid := false
			if north.y < _map_h and _terrain.floor_tiles.has(north):
				var ndata = Registry.get_tile(StringName(_terrain.floor_tiles[north]))
				north_liquid = ndata != null and ndata.is_liquid
			if not north_liquid:
				col = Color(col.r * 0.84, col.g * 0.84, col.b * 0.9, col.a)
	col = _apply_edge_fade(cell, col)
	if main.placed_buildings.has(cell):
		col = main.faction_color(main.get_building_faction(cell))
	return col


func _mark_terrain_dirty(cell: Vector2i) -> void:
	for oy in range(-TERRAIN_DIRTY_RADIUS, TERRAIN_DIRTY_RADIUS + 1):
		for ox in range(-TERRAIN_DIRTY_RADIUS, TERRAIN_DIRTY_RADIUS + 1):
			if absi(ox) + absi(oy) > TERRAIN_DIRTY_RADIUS:
				continue
			var c := cell + Vector2i(ox, oy)
			if _in_bounds(c):
				_dirty_cells[c] = true


func _mark_dirty(cell: Vector2i) -> void:
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			var c := cell + Vector2i(ox, oy)
			if _in_bounds(c):
				_dirty_cells[c] = true


func _mark_area_dirty(origin: Vector2i, size: Vector2i) -> void:
	for y in range(-1, size.y + 1):
		for x in range(-1, size.x + 1):
			_mark_dirty(origin + Vector2i(x, y))


func _mark_full_rebuild() -> void:
	_needs_full_rebuild = true


func _on_building_placed(block_id: StringName, grid_pos: Vector2i) -> void:
	var data = Registry.get_block(block_id)
	_mark_area_dirty(grid_pos, data.grid_size if data != null else Vector2i(1, 1))


func _on_building_destroyed(grid_pos: Vector2i) -> void:
	_mark_area_dirty(grid_pos, Vector2i(5, 5))
	# A destroyed block can't keep pulsing — drop any pending flash on it.
	var anchor: Vector2i = grid_pos
	if main != null:
		anchor = main.building_origins.get(grid_pos, grid_pos)
	_damage_flash.erase(anchor)


## A block took (non-fatal) combat damage — (re)arm its red pulse outline.
func _on_building_damaged(anchor: Vector2i) -> void:
	_damage_flash[anchor] = Time.get_ticks_msec() + DAMAGE_FLASH_MS


## Shared with the full-screen overlay so it can draw the same pulses.
func get_damage_flash() -> Dictionary:
	return _damage_flash


## Current pulse alpha [0..1] for a flash expiring at `expiry_ms`, or -1.0 if
## it has already expired. Combines a sine pulse with a fade-out near expiry.
func damage_flash_alpha(expiry_ms: int, now_ms: int) -> float:
	var remaining: int = expiry_ms - now_ms
	if remaining <= 0:
		return -1.0
	var pulse: float = 0.55 + 0.45 * sin(float(now_ms) / 1000.0 * TAU * DAMAGE_FLASH_HZ)
	var fade: float = clampf(float(remaining) / float(DAMAGE_FLASH_MS), 0.0, 1.0)
	return clampf(pulse * fade, 0.0, 1.0)


## A building changed faction in place (DERELICT flip / capture). Recolour
## its whole footprint — the cell colours are read live from
## `get_building_faction`, so a dirty mark is all that's needed.
func _on_building_faction_changed(anchor: Vector2i) -> void:
	var data = Registry.get_block(main.placed_buildings.get(anchor, &"")) if main != null else null
	_mark_area_dirty(anchor, data.grid_size if data != null else Vector2i(1, 1))


func _in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.x < _map_w and c.y >= 0 and c.y < _map_h


func _tile_map_color(tile_id: StringName) -> Color:
	if _tile_color_cache.has(tile_id):
		return _tile_color_cache[tile_id]
	var col := Color(0.32, 0.34, 0.38)
	var td = Registry.get_tile(tile_id)
	if td != null:
		if td.color.a > 0.0:
			col = Color(td.color.r, td.color.g, td.color.b, 1.0)
		else:
			var avg = _average_texture_color(td.icon)
			col = avg if avg != null else _category_fallback(td.category)
	_tile_color_cache[tile_id] = col
	return col


func _wall_map_color(tile_id: StringName) -> Color:
	var col := _tile_map_color(tile_id)
	if tile_id == &"blackstone_wall" or tile_id == &"purple_wall":
		return col.darkened(0.34)
	return col.darkened(0.15)


func _apply_edge_fade(cell: Vector2i, col: Color) -> Color:
	if col.a <= 0.0 or not (_terrain.floor_tiles.has(cell) or _terrain.wall_tiles.has(cell)):
		return col
	var dist := _nearest_void_distance(cell, int(EDGE_FADE_START))
	if dist >= EDGE_FADE_START:
		return col
	var darkness: float = (1.0 - float(dist) / EDGE_FADE_START) * EDGE_FADE_STRENGTH
	return col.lerp(Color(0, 0, 0, col.a), clampf(darkness, 0.0, 1.0))


func _nearest_void_distance(cell: Vector2i, max_dist: int) -> int:
	for r in range(1, max_dist + 1):
		for dx in range(-r, r + 1):
			var dy_abs: int = r - absi(dx)
			if _is_void_for_fade(cell + Vector2i(dx, dy_abs)):
				return r
			if dy_abs != 0 and _is_void_for_fade(cell + Vector2i(dx, -dy_abs)):
				return r
	return max_dist


func _is_void_for_fade(cell: Vector2i) -> bool:
	if not _in_bounds(cell):
		return true
	return not _terrain.floor_tiles.has(cell) and not _terrain.wall_tiles.has(cell)


func _category_fallback(category: int) -> Color:
	match category:
		TerrainTileData.TileCategory.WALL:
			return Color(0.22, 0.22, 0.26)
		TerrainTileData.TileCategory.ORE:
			return Color(0.5, 0.45, 0.3)
		_:
			return Color(0.32, 0.34, 0.38)


func _average_texture_color(tex: Texture2D) -> Variant:
	if tex == null:
		return null
	var img: Image = tex.get_image()
	if img == null:
		return null
	var iw: int = img.get_width()
	var ih: int = img.get_height()
	if iw <= 0 or ih <= 0:
		return null
	var step: int = maxi(1, int(maxf(iw, ih) / 16.0))
	var rs := 0.0
	var gs := 0.0
	var bs := 0.0
	var wsum := 0.0
	for y in range(0, ih, step):
		for x in range(0, iw, step):
			var p: Color = img.get_pixel(x, y)
			if p.a <= 0.05:
				continue
			rs += p.r * p.a
			gs += p.g * p.a
			bs += p.b * p.a
			wsum += p.a
	if wsum <= 0.0:
		return null
	return Color(rs / wsum, gs / wsum, bs / wsum, 1.0)


# =========================
# LAYOUT / TRANSFORMS
# =========================

func _layout() -> void:
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	offset_left = -VIEW_PX - MARGIN
	offset_right = -MARGIN
	offset_top = MARGIN
	offset_bottom = MARGIN + VIEW_PX
	custom_minimum_size = Vector2(VIEW_PX, VIEW_PX)


func _visible_tile_rect() -> Rect2:
	if _camera == null or not is_instance_valid(_camera):
		return Rect2(0, 0, _map_w, _map_h)
	var sz: float = clampf(BASE_VIEW_TILES * _corner_zoom, BASE_VIEW_TILES, float(mini(_map_w, _map_h)))
	var gs: float = float(main.GRID_SIZE)
	var center: Vector2 = _camera.get_screen_center_position() / gs
	var cx: float = clampf(center.x, sz, float(_map_w) - sz)
	var cy: float = clampf(center.y, sz, float(_map_h) - sz)
	var x0: float = clampf(cx - sz, 0.0, float(_map_w))
	var y0: float = clampf(cy - sz, 0.0, float(_map_h))
	var x1: float = clampf(cx + sz, 0.0, float(_map_w))
	var y1: float = clampf(cy + sz, 0.0, float(_map_h))
	return Rect2(x0, y0, maxf(1.0, x1 - x0), maxf(1.0, y1 - y0))


func _local_to_world(local: Vector2) -> Vector2:
	if main == null or size.x <= 0.0 or size.y <= 0.0:
		return Vector2.ZERO
	var r := _visible_tile_rect()
	var tx: float = r.position.x + clampf(local.x / size.x, 0.0, 1.0) * r.size.x
	var ty: float = r.position.y + clampf(local.y / size.y, 0.0, 1.0) * r.size.y
	return Vector2(tx, ty) * float(main.GRID_SIZE)


func _world_to_box(world: Vector2, crop: Rect2) -> Vector2:
	var gs: float = float(main.GRID_SIZE)
	var tile_pos := world / gs
	return Vector2(
		(tile_pos.x - crop.position.x) / crop.size.x * size.x,
		(tile_pos.y - crop.position.y) / crop.size.y * size.y
	)


# =========================
# DRAW
# =========================

func _draw() -> void:
	if _tex == null or _map_w <= 0 or _map_h <= 0 or main == null:
		return
	var box := Rect2(Vector2.ZERO, size)
	draw_rect(box, Color(0.05, 0.06, 0.08, 0.85), true)
	var crop := _visible_tile_rect()
	var src := crop
	draw_texture_rect_region(_tex, box, src, Color.WHITE, false)
	_draw_fog_overlay(crop, box)
	draw_rect(box, Color(0.4, 0.45, 0.55, 0.9), false, 1.5)

	if _unit_mgr != null:
		_draw_unit_cutouts(_unit_mgr.player_units, main.faction_color(main.Faction.LUMINA).lightened(0.35), crop, box)
		_draw_unit_cutouts(_unit_mgr.enemies, main.faction_color(main.Faction.FEROX).lightened(0.35), crop, box)

	var drone = get_node_or_null("/root/Main/PlayerDrone")
	if _should_draw_primary_drone() and drone != null and is_instance_valid(drone) and "position" in drone \
			and (not ("is_dead" in drone) or not drone.is_dead):
		var dp: Vector2 = _world_to_box(drone.position, crop)
		if box.has_point(dp):
			if not _draw_single_unit_cutout(drone, dp, Color(1.0, 0.95, 0.4), box.size.x / crop.size.x):
				draw_circle(dp, DOT_RADIUS + 0.5, Color(1.0, 0.95, 0.4))

	_draw_damage_flashes(crop, box)
	_draw_camera_rect(crop, box)


## Pulsing red outline around every block that recently took damage. Drawn as
## an overlay (not baked into the texture) so it can animate. Prunes expired
## entries as it goes.
func _draw_damage_flashes(crop: Rect2, box: Rect2) -> void:
	if _damage_flash.is_empty():
		return
	var gs: float = float(main.GRID_SIZE)
	var now: int = Time.get_ticks_msec()
	var expired: Array = []
	for anchor in _damage_flash.keys():
		var alpha: float = damage_flash_alpha(int(_damage_flash[anchor]), now)
		if alpha < 0.0:
			expired.append(anchor)
			continue
		# Block may have been removed between the hit and now.
		if main == null or not main.placed_buildings.has(anchor):
			expired.append(anchor)
			continue
		var gsize := Vector2i.ONE
		var data = Registry.get_block(main.placed_buildings[anchor])
		if data != null:
			gsize = data.grid_size
		var b0: Vector2 = _world_to_box(Vector2(anchor) * gs, crop)
		var b1: Vector2 = _world_to_box(Vector2(anchor + gsize) * gs, crop)
		var r := Rect2(b0, b1 - b0).intersection(box)
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		# Grow by a pixel so the outline hugs the OUTSIDE of the footprint.
		r = r.grow(1.0).intersection(box)
		var col := DAMAGE_FLASH_COLOR
		col.a = alpha
		draw_rect(r, col, false, 1.5)
	for anchor in expired:
		_damage_flash.erase(anchor)


func _draw_unit_cutouts(units: Array, color: Color, crop: Rect2, box: Rect2) -> void:
	var px_per_tile: float = box.size.x / crop.size.x
	for u in units:
		if not is_instance_valid(u) or u.is_dead:
			continue
		if u is CanvasItem and not (u as CanvasItem).visible:
			continue
		var p: Vector2 = _world_to_box(u.position, crop)
		if not box.has_point(p):
			continue
		if not _draw_single_unit_cutout(u, p, color, px_per_tile):
			draw_circle(p, DOT_RADIUS, color)


func _draw_single_unit_cutout(unit: Node, center: Vector2, color: Color, px_per_tile: float) -> bool:
	var udata = unit.data if "data" in unit else null
	var face_angle: float = float(unit.facing_angle) if "facing_angle" in unit else 0.0
	var aim_angle: float = float(unit.aim_angle) if "aim_angle" in unit else face_angle
	if "drone_texture" in unit and unit.drone_texture != null:
		var dscale: float = _texture_cutout_scale(unit.drone_texture, px_per_tile, 1.0)
		_draw_drone_cutout_texture(unit.drone_texture, center, face_angle, dscale, color)
		return true
	if udata != null and (udata.base_sprite != null or udata.head_sprite != null):
		var scale_f: float = _unit_cutout_scale(udata, px_per_tile)
		var spr_off: float = udata.sprite_angle_offset if "sprite_angle_offset" in udata else 0.0
		if udata.base_sprite:
			_draw_cutout_texture(udata.base_sprite, center, face_angle + PI * 0.5 + spr_off, scale_f, color)
		if udata.head_sprite:
			_draw_cutout_texture(udata.head_sprite, center, aim_angle + PI * 0.5 + spr_off, scale_f, color)
		return true
	return false


func _should_draw_primary_drone() -> bool:
	return _unit_mgr == null or not ("controlled_entity" in _unit_mgr) or _unit_mgr.controlled_entity == null


func _unit_cutout_scale(udata, px_per_tile: float) -> float:
	var base_scale: float = (udata.sprite_scale if udata.sprite_scale > 0.0 else 1.0) * main.SPRITE_SCALE_FACTOR
	return base_scale * px_per_tile / float(main.GRID_SIZE)


func _texture_cutout_scale(_tex: Texture2D, px_per_tile: float, base_scale: float) -> float:
	return base_scale * px_per_tile / float(main.GRID_SIZE)


func _draw_cutout_texture(tex: Texture2D, center: Vector2, angle: float, scale_f: float, color: Color) -> void:
	var mask := get_silhouette_texture(tex)
	if mask == null:
		return
	var sz := tex.get_size() * scale_f
	draw_set_transform(center, angle, Vector2.ONE)
	draw_texture_rect(mask, Rect2(-sz * 0.5, sz), false, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_drone_cutout_texture(tex: Texture2D, center: Vector2, angle: float, scale_f: float, color: Color) -> void:
	var mask := get_silhouette_texture(tex)
	if mask == null:
		return
	var sz := tex.get_size() * scale_f
	var offset_y: float = sz.y * 0.05
	draw_set_transform(center, angle, Vector2.ONE)
	draw_texture_rect(mask, Rect2(Vector2(-sz.x * 0.5, -sz.y * 0.5 + offset_y), sz), false, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_fog_overlay(crop: Rect2, box: Rect2) -> void:
	if _fog == null or main == null:
		return
	if "fog_enabled" in main and not bool(main.fog_enabled):
		return
	var x0: int = clampi(floori(crop.position.x), 0, _map_w - 1)
	var y0: int = clampi(floori(crop.position.y), 0, _map_h - 1)
	var x1: int = clampi(ceili(crop.position.x + crop.size.x), 0, _map_w)
	var y1: int = clampi(ceili(crop.position.y + crop.size.y), 0, _map_h)
	for y in range(y0, y1):
		for x in range(x0, x1):
			var cell := Vector2i(x, y)
			if _fog.is_cell_visible(cell):
				continue
			var alpha: float = 0.78
			if _fog.is_cell_explored(cell):
				alpha = 0.35
			var p0 := Vector2(
				(float(x) - crop.position.x) / crop.size.x * box.size.x,
				(float(y) - crop.position.y) / crop.size.y * box.size.y
			)
			var p1 := Vector2(
				(float(x + 1) - crop.position.x) / crop.size.x * box.size.x,
				(float(y + 1) - crop.position.y) / crop.size.y * box.size.y
			)
			draw_rect(Rect2(p0, p1 - p0), Color(0, 0, 0, alpha), true)


func _draw_camera_rect(crop: Rect2, box: Rect2) -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var zoom: Vector2 = _camera.zoom
	if zoom.x <= 0.0 or zoom.y <= 0.0:
		return
	var center: Vector2 = _camera.get_screen_center_position()
	var half: Vector2 = Vector2(vp.x / (2.0 * zoom.x), vp.y / (2.0 * zoom.y))
	var tl: Vector2 = _world_to_box(center - half, crop)
	var br: Vector2 = _world_to_box(center + half, crop)
	var r := Rect2(tl, br - tl).intersection(box)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	draw_rect(r, Color(1.0, 0.85, 0.2, 0.9), false, 1.0)
