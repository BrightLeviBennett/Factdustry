@tool
class_name TerrainTileData
extends Resource

# ============================================================
# TILE_DATA.GD - Defines what a "Tile" (wall/floor) is
# ============================================================
# Tiles are passive terrain — they don't produce resources,
# don't attack, and don't have health. They define the map's
# visual look and walkability.
#
# Floors: Decorative ground tiles (always walkable)
# Walls: Block movement (enemies can't walk through)
#
# Tiles are placed on a separate layer from buildings,
# so you can have a floor tile AND a building on the same cell.
# Walls occupy the same layer as buildings for collision.
# ============================================================

# --- IDENTITY ---
## Unique ID (e.g., "organic_floor", "membrane_wall")
@export var id: StringName = &""
## Display name
@export var display_name: String = ""
## Description
@export_multiline var description: String = ""
## Icon texture
@export var icon: Texture2D

# --- CATEGORIZATION ---
enum TileCategory {
	FLOOR,    # Ground decoration, always walkable
	WALL,     # Blocks movement and line of sight
	ORE,      # Must be placed on a wall. Drills face toward it to mine.
}
@export var category: TileCategory = TileCategory.FLOOR

# --- APPEARANCE ---
## Top face color
@export var color: Color = Color(0.15, 0.2, 0.15, 1.0)
## Whether to draw a subtle border between adjacent tiles
@export var draw_border: bool = false
## Border color (if draw_border is true)
@export var border_color: Color = Color(0.1, 0.15, 0.1, 1.0)
## Opacity (0.0-1.0), useful for semi-transparent overlays
@export var opacity: float = 1.0

# --- WALL PROPERTIES ---
## Height for parallax rendering (walls only, 0 = uses default wall height)
@export var height: float = 0.0
## Side color for parallax (auto-darkened if left black)
@export var side_color: Color = Color.BLACK
## Whether this wall blocks unit pathfinding. If false, all unit types can walk through.
@export var blocks_pathfinding: bool = true
## Can enemies see through this? (walls block LOS by default)
@export var blocks_los: bool = false
## Can this wall be destroyed?
@export var destructible: bool = false
## Health (only matters if destructible)
@export var max_health: float = 0.0
## If true, the floor tile underneath this wall is still visible.
@export var render_tile_underneath: bool = false

# --- GAMEPLAY ---
## Does this tile slow units walking over it?
@export var speed_modifier: float = 1.0
## Damage per second to enemies standing on this tile (acid floors, etc.)
@export var contact_damage: float = 0.0
## Tags for game logic
@export var tags: PackedStringArray = []

# --- MINING ---
## What item ID this deposit yields when drilled (empty = not minable)
@export var minable_resource: StringName = &""
## How much resource per drill cycle
@export var mine_amount: int = 1

# --- LIQUID ---
## Whether this tile is a liquid source (fluid pumps can be placed on it)
@export var is_liquid: bool = false
## What item ID this liquid source yields when pumped (empty = no extraction)
@export var extracted_liquid: StringName = &""


# =========================
# HELPER METHODS
# =========================

## Returns true if this is a wall (blocks movement).
func is_wall() -> bool:
	return category == TileCategory.WALL

## Returns true if this is a floor (walkable).
func is_floor() -> bool:
	return category == TileCategory.FLOOR

## Returns true if this is an ore deposit (placed on walls, mined by drills).
func is_ore() -> bool:
	return category == TileCategory.ORE

## Returns true if this is a pumpable liquid source tile.
func is_liquid_source() -> bool:
	return is_liquid and extracted_liquid != &""

## Returns the side color, auto-calculating if not set.
func get_side_color() -> Color:
	if side_color != Color.BLACK:
		return side_color
	return color.darkened(0.4)

## Returns the darker side color for the other axis.
func get_side_color_dark() -> Color:
	if side_color != Color.BLACK:
		return side_color.darkened(0.2)
	return color.darkened(0.55)
