@tool
class_name AmmoType
extends Resource

# ============================================================
# AMMO_TYPE.GD - Defines a turret ammo variant
# ============================================================
# Each ammo type specifies the resource consumed per shot, the
# projectile's visual and ballistic properties, and any status
# effects applied on hit. Turrets consume one unit of the
# resource per shot.
# ============================================================


# =========================
# IDENTITY
# =========================

## Icon shown in the ammo selection UI (falls back to item icon)
@export var icon: Texture2D


# =========================
# COST
# =========================

## The item/resource consumed per shot (e.g. &"mat_copper")
@export var item_id: StringName = &""

## How many of that item a single shot consumes
@export var amount_per_shot: int = 1


# =========================
# DAMAGE
# =========================

## Base damage dealt per shot when using this ammo
@export var damage: float = 10.0

## Extra damage multiplier applied when hitting buildings (1.0 = no change)
@export var building_damage_mult: float = 1.0

## Extra damage multiplier applied when hitting units (1.0 = no change)
@export var unit_damage_mult: float = 1.0

## Amount of armor ignored on hit
@export var pierce_armor: float = 0.0

## Number of targets a single projectile can pass through before despawning.
## 0 = stops at the first hit, 1 = passes through one target, etc.
@export var pierce_count: int = 0


# =========================
# RELOAD / FIRE RATE
# =========================

## Multiplier applied to the turret's base attack speed (reload). 1.0 = no change.
## <1.0 = faster reload, >1.0 = slower reload.
@export var reload_multiplier: float = 1.0

## Extra range added to the turret's base attack_range (in pixels)
@export var range_bonus: float = 0.0

## Inaccuracy in degrees — random spread applied to the shot direction
@export_range(0.0, 45.0, 0.1) var inaccuracy: float = 0.0

## Number of projectiles fired per shot (for shotgun-style ammo)
@export_range(1, 1000) var projectiles_per_shot: int = 1


# =========================
# BALLISTICS
# =========================

## Projectile travel speed in pixels / second
@export var projectile_speed: float = 300.0

## Projectile lifetime in seconds before it despawns mid-air
@export var projectile_lifetime: float = 2.0

## Physical radius of the projectile — bigger radius = easier hits
@export var projectile_radius: float = 3.0

## Knockback applied to hit units (pixels of pushback)
@export var knockback: float = 0.0

## Homing strength (0 = none, 1 = perfectly tracks target)
@export_range(0.0, 1.0, 0.01) var homing: float = 0.0


# =========================
# AREA OF EFFECT
# =========================

## If true, the projectile deals splash damage on impact
@export var is_splash: bool = false

## Splash radius in pixels
@export var splash_radius: float = 0.0

## Splash damage multiplier (applied to nearby targets). 1.0 = same as direct hit.
@export var splash_damage_mult: float = 1.0


# =========================
# STATUS / DOT
# =========================

## Status effect applied on hit (reference a StatusEffectData resource, or null)
@export var status_effect: Resource

## Duration of the applied status effect in seconds
@export var status_duration: float = 0.0

## Damage over time dealt per second after a hit (in addition to the direct hit)
@export var burn_damage: float = 0.0

## Duration of the burn DoT in seconds
@export var burn_duration: float = 0.0


# =========================
# TARGETING FILTERS
# =========================

## If false, this ammo cannot hit airborne / flying units
@export var collides_air: bool = true

## If false, this ammo cannot hit ground units / buildings
@export var collides_ground: bool = true


# =========================
# VISUALS
# =========================

## Color of the projectile body
@export var projectile_color: Color = Color.YELLOW

## Color of the projectile's trail (defaults to projectile_color if Color.BLACK)
@export var trail_color: Color = Color.BLACK

## Length of the trail in pixels (0 = no trail)
@export var trail_length: float = 0.0

## Scale of the muzzle flash (0 = no flash)
@export var muzzle_flash_scale: float = 1.0

## Scale of the impact effect (0 = no impact effect)
@export var impact_effect_scale: float = 1.0


# =========================
# HELPERS
# =========================

## Returns the trail color, defaulting to the projectile color if not set.
func get_trail_color() -> Color:
	if trail_color == Color.BLACK:
		return projectile_color
	return trail_color


## Returns the effective reload time given a turret's base attack_speed.
func get_effective_reload(base_reload: float) -> float:
	return base_reload * reload_multiplier


## Returns the effective range given a turret's base attack_range.
func get_effective_range(base_range: float) -> float:
	return base_range + range_bonus


## Returns the damage dealt to a target, factoring in the building/unit multipliers.
func get_damage_vs_building() -> float:
	return damage * building_damage_mult


func get_damage_vs_unit() -> float:
	return damage * unit_damage_mult
