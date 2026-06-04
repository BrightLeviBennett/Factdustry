@tool
class_name WeaponData
extends Resource

# ============================================================
# WEAPON_DATA.GD — A single weapon mounted at a point on a unit.
# ============================================================
# Mirrors Mindustry's `Weapon` data model: a STATELESS definition shared
# by every unit of a type. Live per-instance state (reload countdown,
# current rotation, recoil) lives in the runtime `WeaponMount` dictionary
# built per unit in enemy_unit.gd — never store live state here.
#
# A unit lists these in `UnitData.weapons`. At spawn each weapon expands
# into one mount (or two, if `mirror`), and a per-frame tick transforms the
# mount's local `offset` into world space by the unit's facing, aims it,
# and fires its behavior when reloaded + on-target.
# ============================================================


# =========================
# IDENTITY / VISUAL
# =========================

## Optional weapon sprite drawn at the mount (rotates with the weapon).
## Source art should face UP (−Y), matching the unit head convention.
@export var sprite: Texture2D
## Multiplier on the sprite's native pixel size.
@export var sprite_scale: float = 1.0
## Extra rotation (radians) added when drawing the weapon sprite, to correct
## art whose "forward" (barrel) isn't the default UP. PI = down-facing art.
@export var sprite_angle_offset: float = 0.0
## Draw the weapon sprite ABOVE the unit body (true) or beneath it.
@export var top: bool = true


# =========================
# MOUNT PLACEMENT
# =========================

## Local mount offset on the unit, in pixels, BEFORE the unit's facing
## rotation is applied. +x = unit's right, +y = unit's forward (toward the
## sprite's "up"). The world mount point is
##   unit.position + offset.rotated(unit_facing).
@export var offset: Vector2 = Vector2(10.0, 0.0)

## Extra muzzle offset from the mount, along the weapon's own rotation,
## in pixels. Projectiles spawn here. +y = out the barrel.
@export var muzzle_offset: Vector2 = Vector2(0.0, 8.0)

## If true, a flipped copy of this weapon is auto-created on the opposite
## side (offset.x negated, sprite flipped) at spawn. The pair alternate
## fire so a 2-gun unit keeps the same total cadence (each mount's reload
## is doubled). Mirrors Mindustry's data-time mirror expansion.
@export var mirror: bool = true

## If true the mount turret-rotates to aim independently of the chassis,
## turning toward the target at `rotate_speed`. If false it's locked to
## `base_rotation` relative to the chassis (fires straight ahead).
@export var rotate: bool = true

## Fixed mount angle (radians) relative to the chassis when `rotate` is
## false; also the rest angle a rotating mount returns to with no target.
@export var base_rotation: float = 0.0

## Degrees/sec the mount swings toward its aim target (when `rotate`).
@export var rotate_speed: float = 600.0


# =========================
# BEHAVIOR
# =========================

enum Behavior {
	TURRET,        ## Fires projectiles at the unit's combat target.
	REPAIR_BEAM,   ## Heals the nearest friendly building/unit in range.
	POINT_DEFENSE, ## Shoots down incoming enemy projectiles in range.
}
## What this weapon does when it fires. TURRET reuses the unit's existing
## damage/ammo; REPAIR_BEAM / POINT_DEFENSE run their own per-tick logic.
@export var behavior: Behavior = Behavior.TURRET


# =========================
# FIRING
# =========================

## Seconds between shots for THIS mount (before mirror-doubling). When
## <= 0 the unit's own `attack_speed` is used as a fallback.
@export var reload: float = 0.0

## Max angle (degrees) between the mount's aim and the target before it's
## allowed to fire. Keeps a still-rotating mount from shooting sideways.
@export var shoot_cone: float = 8.0

## How far recoil kicks the sprite back along the barrel on each shot (px).
@export var recoil: float = 3.0

## Range (px) for this weapon. <= 0 falls back to the unit's attack_range.
@export var range_px: float = 0.0

## How many barrels this single mount fires from. Mirrors the block turret's
## `barrel_count`: the barrels fire in SEQUENCE with the mount's reload split
## evenly between them, so N barrels fire N× as often, alternating — a
## double-barrel head at N=2 fires twice per `reload`, one shot from each
## divot. 1 = ordinary single-muzzle behaviour. The head sprite is unchanged
## (one sprite per mount); only the muzzle point cycles between barrels.
@export var barrel_count: int = 1

## Perpendicular spacing (px, in drawn world space) between adjacent barrels.
## Barrel b sits at (b − (N−1)/2) × barrel_spacing along the mount's local x,
## so N=2 with spacing 48 puts the two muzzles at ±24 — lined up with the two
## divots in the head art. Only used when `barrel_count` > 1.
@export var barrel_spacing: float = 0.0

## Damage per shot. <= 0 falls back to the unit's `damage`.
@export var damage: float = 0.0

## Projectile travel speed (px/sec) for TURRET behavior.
@export var projectile_speed: float = 300.0

## Optional ammo definition. When set, its ballistics / damage / status
## override the simple damage+speed fields for TURRET behavior.
@export var ammo: AmmoType

## REPAIR_BEAM only: HP/sec restored to the beam's target.
@export var repair_per_second: float = 30.0

## POINT_DEFENSE only: damage applied to an intercepted enemy projectile.
@export var point_defense_damage: float = 20.0


# =========================
# HELPERS
# =========================

## Effective reload for one mount, honoring the unit fallback.
func effective_reload(unit_attack_speed: float) -> float:
	return reload if reload > 0.0 else maxf(0.05, unit_attack_speed)

## Effective range, honoring the unit fallback.
func effective_range(unit_attack_range: float) -> float:
	if range_px > 0.0:
		return range_px
	if ammo != null:
		return unit_attack_range + ammo.range_bonus
	return unit_attack_range

## Effective per-shot damage, honoring ammo + unit fallback.
func effective_damage(unit_damage: float) -> float:
	if ammo != null:
		return ammo.damage
	return damage if damage > 0.0 else unit_damage
