@tool
class_name UnitData
extends Resource

# ============================================================
# UNIT_DATA.GD — Data definition for a unit type.
# Used for both enemy and player units; `team` picks the side.
# ============================================================

enum Team { PLAYER, ENEMY, NEUTRAL }
enum UnitCategory { MELEE, RANGED, TANK, SWARM, FLYING, SUPPORT, BUILDER, BOSS }
enum UnitShape { CIRCLE, DIAMOND, TRIANGLE, HEXAGON }
enum MovementLayer {
	GROUND,   ## Normal pathfinding, blocked by all buildings + terrain walls
	CRAWLER,  ## Ignores buildings; blocked only by terrain wall segments >= 4 cells
	HOVER,    ## Hovers over liquid/rough floors, but terrain walls still block it
	FLYING,   ## Ignores all terrain, direct movement (highest layer)
	NAVAL,    ## Water-only: may ONLY occupy water floor with no platform on
			  ## it. Everything else (land, walls, buildings, platforms) is
			  ## impassable, so a naval unit treats the water's edge the way
			  ## a tank treats a wall. Appended last to keep existing .tres
			  ## integer movement_layer values stable.
}
enum TargetPriority { NEAREST, BUILDINGS, UNITS, WEAKEST, PLAYER_DRONE }


@export_group("Identity")
## Unique ID used in code (e.g. "basic_cell", "phage").
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var icon: Texture2D
@export var team: Team = Team.ENEMY
@export var category: UnitCategory = UnitCategory.MELEE


@export_group("Appearance")
@export var color: Color = Color.RED
## Fallback shape radius (pixels) when no base/head sprite is set.
@export var visual_size: float = 8.0
## Multiplier on the sprite's native pixel size. 1.0 = pixel-perfect.
@export var sprite_scale: float = 1.0
## Primitive shape used when textures aren't set.
@export var shape: UnitShape = UnitShape.CIRCLE
@export_subgroup("Sprites")
## Chassis/body — rotates with movement direction.
@export var base_sprite: Texture2D
## Rotating head — aims at target. Source art should face UP.
@export var head_sprite: Texture2D
@export_subgroup("Rotation")
## Radians/sec the head can swing (crane-style constant rate).
@export var head_turn_speed: float = 3.0
## Radians/sec the chassis rotates to face travel direction.
@export var body_turn_speed: float = 2.0
## Extra rotation (radians) added when drawing the base + head sprites, to
## correct art whose "forward" isn't the default UP. Use PI for art that
## faces DOWN, ±PI/2 for sideways art. 0 = source art already faces up.
@export var sprite_angle_offset: float = 0.0


@export_group("Movement")
@export var movement_layer: MovementLayer = MovementLayer.GROUND
## Tiles/sec (converted to px/sec at load time).
@export var move_speed: float = 1.25
@export_subgroup("Tank Steering")
## Must turn before moving, producing arcing trajectories.
@export var tank_steering: bool = false
@export_subgroup("Naval Wake")
## Number of history points in each side wake-trail ribbon (Mindustry's
## `trailLength`). 0 = no wake. Higher = longer trail.
@export var trail_length: int = 0
## Lateral offset (px) of each wake trail from the unit centre (Mindustry's
## `waveTrailX`). The two trails sit at ±this, rotated by the hull heading.
@export var wave_trail_x: float = 8.0
## Forward/back offset (px) of the wake trails (Mindustry's `waveTrailY`,
## negative = behind the centre).
@export var wave_trail_y: float = -6.0
## Overall width multiplier of the wake ribbons (Mindustry's `trailScl`).
@export var trail_scl: float = 1.0


@export_group("Stats")
@export var max_health: float = 50.0
## HP regenerated per second.
@export var health_regen: float = 0.0
## Flat damage reduction.
@export var armor: float = 0.0
## Unit tier (1-5), set per fabricator-chain position. Drives the number
## of upgrade slots via `upgrade_slots()`.
@export var tier: int = 1


## Number of upgrade modules this unit can hold, by tier:
## t1=1, t2=2, t3=3, t4=5, t5=6 (anything else = tier-1 = 1 slot).
func upgrade_slots() -> int:
	match tier:
		2: return 2
		3: return 3
		4: return 5
		5: return 6
		_: return 1


@export_group("Combat")
@export var attack_damage: float = 10.0
## Seconds between attacks.
@export var attack_speed: float = 1.0
## Attack range in pixels (melee ~32, ranged ~200+).
@export var attack_range: float = 32.0
@export var is_aoe: bool = false
@export var aoe_radius: float = 0.0
## Mindustry-style mounted weapons. Each WeaponData is a stateless weapon
## placed at an offset on the unit; at spawn they expand into live mounts
## (one each, or two if `mirror`). When this list is NON-EMPTY the unit
## fires through the mount system instead of the legacy single-shot
## attack path, so a unit can have multiple weapons at distinct points
## doing distinct things. Empty = legacy behaviour (unchanged).
@export var weapons: Array[WeaponData] = []


@export_group("AI")
## Range (px) to spot enemies/buildings.
@export var detection_range: float = 500.0
@export var target_priority: TargetPriority = TargetPriority.NEAREST
## DEPRECATED: Use movement_layer instead. Kept for .tres back-compat.
@export var can_fly: bool = false:
	get:
		return movement_layer == MovementLayer.FLYING
	set(value):
		if value:
			movement_layer = MovementLayer.FLYING


@export_group("Drops")
## item_id -> amount dropped on death.
@export var drops: Dictionary = {}
## Chance (0.0-1.0) to drop on death.
@export var drop_chance: float = 1.0


@export_group("Status Effects")
## StatusEffectData applied on hit.
@export var on_hit_effect: Resource
## Effect IDs this unit is immune to.
@export var immunities: PackedStringArray = []


@export_group("Spawning")
## Enemies per wave from a nest.
@export var spawn_count: int = 3
## Difficulty value used for wave scaling.
@export var threat_value: float = 1.0


@export_group("Production")
## Seconds a fabricator takes to build this unit.
@export var build_time: float = 5.0
## item_id -> amount a fabricator consumes to produce this unit.
@export var build_cost: Dictionary = {}


# =========================
# HELPER METHODS
# =========================

## Calculates actual damage dealt after armor. `armor_mult` scales the flat
## armor before subtraction (Embrittled passes 0.5 to halve its effectiveness).
func calc_damage_taken(raw_damage: float, armor_mult: float = 1.0) -> float:
	return max(raw_damage - armor * armor_mult, 1.0)
