extends Control
class_name SchematicPreview

## Mindustry-style schematic thumbnail: a square panel with the
## `ScematicBackground.png` texture tiled behind the block icons. Used
## by both the save dialog and the schematics viewer.
##
## The schematic dict matches what `SchematicSystem.capture_rect`
## emits: { blocks: { "x,y": "block_id" }, rotation: { … }, width, height }.

const BG_PATH := "res://textures/UI/ScematicBackground.png"

static var _bg_tex: Texture2D = null

var schematic: Dictionary = {}:
	set(value):
		schematic = value
		queue_redraw()


func _init() -> void:
	if _bg_tex == null:
		_bg_tex = load(BG_PATH) as Texture2D
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)

	# Solid backstop so the preview reads as a panel even before the
	# tiled background paints. The tiled bg replaces this for cells
	# inside the schematic footprint; cells outside fall back to here.
	draw_rect(rect, Color(0.05, 0.06, 0.08, 1.0), true)

	# Schematic dims first — the tile sizing below feeds both the
	# block draws AND the background tiling, since the user spec is
	# "one ScematicBackground tile == one schematic cell".
	var w: int = int(schematic.get("width", 0))
	var h: int = int(schematic.get("height", 0))
	var blocks: Dictionary = schematic.get("blocks", {})
	if w <= 0 or h <= 0 or blocks.is_empty():
		return

	# Fit the schematic's tile grid inside our rect with a small inset.
	var inset: float = 6.0
	var avail_w: float = size.x - inset * 2.0
	var avail_h: float = size.y - inset * 2.0
	if avail_w <= 0.0 or avail_h <= 0.0:
		return
	var tile_size: float = minf(avail_w / float(w), avail_h / float(h))
	var grid_px_w: float = tile_size * float(w)
	var grid_px_h: float = tile_size * float(h)
	var origin := Vector2(
		(size.x - grid_px_w) * 0.5,
		(size.y - grid_px_h) * 0.5,
	)

	# 1. Tiled background — one full ScematicBackground.png tile per
	# schematic cell (i.e. `tile_size` px per copy). Drawn only over
	# the schematic footprint so the panel chrome shows around the
	# edges.
	if _bg_tex:
		for ty in range(h):
			for tx in range(w):
				var bg_pos := origin + Vector2(float(tx) * tile_size, float(ty) * tile_size)
				draw_texture_rect(_bg_tex, Rect2(bg_pos, Vector2(tile_size, tile_size)), false)

	for key in blocks:
		var parts: PackedStringArray = String(key).split(",")
		if parts.size() < 2:
			continue
		var gx: int = int(parts[0])
		var gy: int = int(parts[1])
		var bid: StringName = StringName(blocks[key])
		var data = Registry.get_block(bid)
		if data == null:
			continue
		var gw: int = int(data.grid_size.x)
		var gh: int = int(data.grid_size.y)
		var tex: Texture2D = data.top_sprite
		if tex == null:
			tex = data.icon
		var pos := origin + Vector2(float(gx) * tile_size, float(gy) * tile_size)
		var block_rect := Rect2(pos, Vector2(tile_size * float(gw), tile_size * float(gh)))
		if tex:
			draw_texture_rect(tex, block_rect, false)
		else:
			draw_rect(block_rect, Color(0.4, 0.45, 0.5, 0.9), true)
			draw_rect(block_rect, Color(0.7, 0.75, 0.8, 1.0), false, 1.0)
