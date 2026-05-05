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
## Unique ID (e.g., "blackstone_floor", "grassy_wall")
@export var id: StringName = &""

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
## Opacity (0.0-1.0), useful for semi-transparent overlays
@export var opacity: float = 1.0

# --- WALL PROPERTIES ---
## Height for parallax rendering (walls only, 0 = uses default wall height)
@export var height: float = 0.0
## Whether this wall blocks unit pathfinding. If false, all unit types can walk through.
@export var blocks_pathfinding: bool = true
## Can enemies see through this? (walls block LOS by default)
@export var blocks_los: bool = false
## Can this wall be destroyed?
@export var destructible: bool = false
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
## Water depth for liquid tiles. 0 = not water / safe ground.
##   1 = shallow (ankle-deep). Ground/crawler units can cross at half speed,
##       accumulate submersion damage, take a blue tint. Pumps placeable.
##       Any non-platform block is blocked from placement.
##   2 = waist-deep. Same as depth 1 for units. Pumps placeable.
##       Only platforms are placeable; other blocks require a platform on top.
##   3 = deep water. Units still traverse (same rules) but no blocks of any
##       kind can be placed directly; platforms are required first.
@export_range(0, 3) var water_depth: int = 0


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
