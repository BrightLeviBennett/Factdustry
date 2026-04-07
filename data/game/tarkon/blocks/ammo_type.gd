@tool
class_name AmmoType
extends Resource

# ============================================================
# AMMO_TYPE.GD - Defines a turret ammo variant
# ============================================================
# Each ammo type specifies what resource it uses, the damage
# it deals, and any status effects it applies on hit.
# Turrets consume one unit of the resource per shot.
# ============================================================

## The item/resource consumed per shot (e.g. &"mat_copper")
@export var item_id: StringName = &""

## Damage dealt per shot when using this ammo
@export var damage: float = 10.0

## Multiplier applied to the turret's base attack speed (1.0 = no change)
@export var speed_multiplier: float = 1.0

## Status effect applied on hit (reference a StatusEffectData resource, or null)
@export var status_effect: Resource

## Color of the projectile when using this ammo
@export var projectile_color: Color = Color.YELLOW

## Description shown in the UI
@export var description: String = ""
