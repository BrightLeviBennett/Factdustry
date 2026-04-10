@tool
class_name UnitData
extends Resource

# ============================================================
# UNIT_DATA.GD - Defines what a "Unit" is
# ============================================================
# Both enemy AND player units use this same data format.
# The "team" property determines which side they're on.
# Each .tres file becomes one unit type.
# ============================================================

# --- IDENTITY ---
## Unique ID used in code (e.g., "basic_cell", "phage")
@export var id: StringName = &""
## Display name
@export var display_name: String = ""
## Description
@export_multiline var description: String = ""
## Icon texture
@export var icon: Texture2D

# --- TEAM ---
enum Team {
	PLAYER,    # Friendly units
	ENEMY,     # Hostile units
	NEUTRAL,   # Environmental/passive
}
@export var team: Team = Team.ENEMY

# --- CATEGORIZATION ---
enum UnitCategory {
	MELEE,      # Gets close and attacks
	RANGED,     # Shoots from a distance
	TANK,       # High HP, slow, draws aggro
	SWARM,      # Weak individually, spawns in groups
	FLYING,     # Ignores walls/pathfinding
	SUPPORT,    # Heals/buffs other units
	BUILDER,    # Player's building drone
	BOSS,       # Powerful, unique abilities
}
@export var category: UnitCategory = UnitCategory.MELEE

# --- APPEARANCE ---
## Body color
@export var color: Color = Color.RED
## Visual size in pixels (radius)
@export var visual_size: float = 8.0
## Shape for drawing (circle, diamond, triangle, hexagon)
enum UnitShape { CIRCLE, DIAMOND, TRIANGLE, HEXAGON }
@export var shape: UnitShape = UnitShape.CIRCLE

# --- MOVEMENT LAYER ---
## Determines how this unit interacts with terrain and other units.
enum MovementLayer {
	GROUND,    ## Normal pathfinding, blocked by all buildings + terrain walls
	CRAWLER,   ## Ignores buildings; blocked only by terrain wall segments >= 4 cells
	HOVER,     ## Ignores all terrain, direct movement
	FLYING,    ## Ignores all terrain, direct movement (highest layer)
}
@export var movement_layer: MovementLayer = MovementLayer.GROUND

# --- STATS ---
@export var max_health: float = 50.0
@export var health_regen: float = 0.0        # HP/sec
@export var move_speed: float = 80.0         # Pixels/sec
@export var armor: float = 0.0              # Flat damage reduction

# --- COMBAT ---
@export var attack_damage: float = 10.0
@export var attack_speed: float = 1.0        # Seconds between attacks
@export var attack_range: float = 32.0       # Pixels (melee ~32, ranged ~200+)
@export var is_aoe: bool = false
@export var aoe_radius: float = 0.0

# --- AI BEHAVIOR ---
## DEPRECATED: Use movement_layer instead. Kept for .tres backward compatibility.
@export var can_fly: bool = false:
	get:
		return movement_layer == MovementLayer.FLYING
	set(value):
		if value:
			movement_layer = MovementLayer.FLYING
## How far this unit can "see" enemies/buildings to target (in pixels)
@export var detection_range: float = 500.0
## Priority target: what this unit prefers to attack
enum TargetPriority {
	NEAREST,         # Attacks whatever is closest
	BUILDINGS,       # Prefers buildings over units
	UNITS,           # Prefers units over buildings
	WEAKEST,         # Attacks lowest HP target
	PLAYER_DRONE,    # Bee-lines for the player
}
@export var target_priority: TargetPriority = TargetPriority.NEAREST

# --- DROPS ---
## Dictionary of item_id -> amount dropped on death.
## Example: {"plasmids": 1}
@export var drops: Dictionary = {}
## Chance (0.0-1.0) to drop items on death
@export var drop_chance: float = 1.0

# --- STATUS EFFECTS ---
## Status effect applied on hit (reference a StatusEffectData .tres)
@export var on_hit_effect: Resource
## Status effects this unit is immune to (array of effect IDs)
@export var immunities: PackedStringArray = []

# --- SPAWNING ---
## For enemy units: how many spawn per wave from a nest
@export var spawn_count: int = 3
## Score/difficulty value — used for wave scaling
@export var threat_value: float = 1.0

# --- PRODUCTION ---
## Time in seconds for a fabricator to build this unit
@export var build_time: float = 5.0
## Items a fabricator must consume to produce this unit.
## Keys are short item ids (e.g. "copper", "silicon") matching BlockData.build_cost.
## Example: { "copper": 100, "silicon": 40 }
@export var build_cost: Dictionary = {}


# =========================
# HELPER METHODS
# =========================

## Calculates actual damage dealt after armor.
func calc_damage_taken(raw_damage: float) -> float:
	return max(raw_damage - armor, 1.0)

## Returns true if this unit skips AStar pathfinding (direct movement).
func ignores_pathfinding() -> bool:
	return movement_layer >= MovementLayer.HOVER

## Returns true if this unit uses the crawler AStar grid.
func uses_crawler_pathfinding() -> bool:
	return movement_layer == MovementLayer.CRAWLER
