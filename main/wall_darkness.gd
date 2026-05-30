extends Node2D
class_name WallDarkness

## Mindustry-style "wall fade" overlay. Replicates the algorithm in
##   core/src/mindustry/core/World.java     (getDarkness, addDarkness)
##   core/src/mindustry/graphics/BlockRenderer.java   (drawDarkness)
##   core/assets/shaders/darkness.frag
##
## Recipe:
##   1. Build a per-tile darkness grid. Wall tiles and out-of-bounds
##      get max darkness; non-wall tiles start at 0.
##   2. Erode the grid for N iterations (4-directional). Each pass,
##      any cell adjacent to a LOWER neighbour is reduced by 1, so
##      the darkness "softens" outward from solid wall clusters into
##      smooth gradients.
##   3. Bake into an Image (one pixel per tile) where
##      `red = (darkness == 0) ? 1.0 : 1 - min((darkness + 0.5) / 4, 1)`.
##   4. Draw the image stretched across the world with linear filter
##      through a 1-line shader: `COLOR = vec4(0, 0, 0, 1 - tex.r)`.
##
## Rebuilds on `terrain.walls_changed`; cheap (only on wall edits).

const _MAX_DARKNESS: float = 4.0
const _DARK_ITERATIONS: int = 4
# Border-darkness fade matches Mindustry's `borderDarkness` rule
# (edgeBlend = 2 → first two tiles in from the map edge are darkened).
const _EDGE_BLEND: int = 2

@onready var main: Node2D = get_node("/root/Main")
var _terrain: Node = null
var _shader_material: ShaderMaterial = null
var _texture: ImageTexture = null
var _dirty: bool = true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Lower z so the player drone (z=4095) and any other unit / HUD
	# layer renders cleanly on top. Above floor (z<50) and below
	# placed-building art is fine — the darkness reads as edge-of-
	# vision, so it can paint over walls + floor without occluding
	# the things the player is controlling.
	z_index = 51
	z_as_relative = false
	# Wait one frame so Main/TerrainSystem are guaranteed loaded.
	await get_tree().process_frame
	_terrain = main.get_node_or_null("TerrainSystem")
	if _terrain == null:
		return
	if _terrain.has_signal("walls_changed"):
		_terrain.walls_changed.connect(_on_walls_changed)
	# Build the shader material once.
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	// Mindustry's darkness shader, verbatim: black wherever the
	// baked darkness texture is dark, transparent wherever it's
	// bright. Linear filtering on the texture turns the per-tile
	// values into a smooth gradient across screen-space.
	COLOR = vec4(0.0, 0.0, 0.0, 1.0 - c.r);
}
"""
	_shader_material = ShaderMaterial.new()
	_shader_material.shader = shader
	material = _shader_material
	_rebuild_texture()


func _on_walls_changed() -> void:
	_dirty = true
	call_deferred("_rebuild_texture")


## Rebuilds the per-tile darkness grid + texture from the current
## wall_tiles set. Called on _ready and whenever walls change.
## Direct port of Mindustry's addDarkness erosion loop.
func _rebuild_texture() -> void:
	if not _dirty:
		return
	_dirty = false
	if main == null or _terrain == null:
		return
	var w: int = int(main.GRID_WIDTH)
	var h: int = int(main.GRID_HEIGHT)
	if w <= 0 or h <= 0:
		return
	# Seed: walls + map edges at max darkness, everything else 0.
	var dark: PackedFloat32Array = PackedFloat32Array()
	dark.resize(w * h)
	var wall_tiles: Dictionary = _terrain.wall_tiles
	for x in range(w):
		for y in range(h):
			var idx: int = y * w + x
			var edge_dst: int = mini(mini(x, w - 1 - x), mini(y, h - 1 - y))
			var d: float = 0.0
			if edge_dst <= _EDGE_BLEND:
				d = float(_EDGE_BLEND - edge_dst) * (_MAX_DARKNESS / float(_EDGE_BLEND))
			if wall_tiles.has(Vector2i(x, y)):
				d = _MAX_DARKNESS
			dark[idx] = d
	# Erosion pass — 4-directional. Each tile with a strictly lower
	# 4-neighbour gets `darkness -= 1`. Iterating N times propagates
	# the gradient outward from wall clusters. Direct port of
	# Mindustry's addDarkness loop.
	var dirs: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for _i in range(_DARK_ITERATIONS):
		var next: PackedFloat32Array = dark.duplicate()
		for x in range(w):
			for y in range(h):
				var idx: int = y * w + x
				var cur: float = dark[idx]
				if cur <= 0.0:
					continue
				var min_neighbor: bool = false
				for d in dirs:
					var nx: int = x + d.x
					var ny: int = y + d.y
					if nx < 0 or nx >= w or ny < 0 or ny >= h:
						continue
					if dark[ny * w + nx] < cur:
						min_neighbor = true
						break
				if min_neighbor:
					next[idx] = maxf(0.0, cur - 1.0)
		dark = next
	# Bake to image — formula matches Mindustry's drawDarkness:
	#   red = 1 if darkness == 0
	#       = 1 - min((d + 0.5) / 4, 1) otherwise
	var img: Image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	for x in range(w):
		for y in range(h):
			var d_v: float = dark[y * w + x]
			var r: float
			if d_v <= 0.0:
				r = 1.0
			else:
				r = 1.0 - minf((d_v + 0.5) / _MAX_DARKNESS, 1.0)
			img.set_pixel(x, y, Color(r, r, r, 1.0))
	if _texture == null:
		_texture = ImageTexture.create_from_image(img)
	else:
		_texture.update(img)
	queue_redraw()


func _draw() -> void:
	if _texture == null or main == null:
		return
	var gs: float = float(main.GRID_SIZE)
	var w_px: float = float(main.GRID_WIDTH) * gs
	var h_px: float = float(main.GRID_HEIGHT) * gs
	draw_texture_rect(_texture, Rect2(Vector2.ZERO, Vector2(w_px, h_px)),
		false, Color.WHITE)


func _enter_tree() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
