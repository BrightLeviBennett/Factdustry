@tool
class_name StatusEffectData
extends Resource

# ============================================================
# STATUS_EFFECT_DATA.GD - Defines what a "Status Effect" is
# ============================================================
# Status effects are temporary buffs/debuffs applied to units
# or buildings. They modify stats, deal damage over time,
# or trigger special behaviors.
#
# Examples: antibiotic exposure (weakens), mutation (random
# stat change), quorum boost (adjacency buff), acid burn (DoT).
# ============================================================

# --- IDENTITY ---
## Unique ID (e.g., "acid_burn", "antibiotic_exposure")
@export var id: StringName = &""
## Display name
@export var display_name: String = ""
## Description
@export_multiline var description: String = ""
## Icon texture for the HUD status bar
@export var icon: Texture2D

# --- TIMING ---
## Duration in seconds (0 = permanent until removed)
@export var duration: float = 5.0
## Can this effect stack multiple times?
@export var stackable: bool = false
## Maximum number of stacks
@export var max_stacks: int = 1
## Does applying again refresh the duration?
@export var refresh_on_reapply: bool = true

# --- CATEGORIZATION ---
enum EffectType {
	BUFF,       # Positive effect on friendly targets
	DEBUFF,     # Negative effect on enemy targets
	DOT,        # Damage over time
	HOT,        # Heal over time
	CROWD_CONTROL,  # Slows, stuns, roots
	TRANSFORM,  # Changes the target in some way
}
@export var effect_type: EffectType = EffectType.DEBUFF

# --- APPEARANCE ---
## Color tint applied to the affected unit/building
@export var tint_color: Color = Color.WHITE
## Particle color for visual effect
@export var particle_color: Color = Color.WHITE
## Show a visual indicator on the target?
@export var show_indicator: bool = true

# --- STAT MODIFIERS ---
# These are MULTIPLIERS applied to the target's base stats.
# 1.0 = no change, 0.5 = halved, 2.0 = doubled, 0.0 = disabled.
## Move speed multiplier (units only)
@export var speed_modifier: float = 1.0
## Damage dealt multiplier
@export var damage_modifier: float = 1.0
## Damage received multiplier (>1.0 = takes more damage)
@export var defense_modifier: float = 1.0
## Attack speed multiplier
@export var attack_speed_modifier: float = 1.0
## Production speed multiplier (buildings only)
@export var production_modifier: float = 1.0

# --- DAMAGE/HEALING OVER TIME ---
## Damage dealt per tick (negative = healing)
@export var tick_damage: float = 0.0
## Seconds between each tick
@export var tick_interval: float = 1.0

# --- CROWD CONTROL ---
## Is the target stunned (can't move or attack)?
@export var stuns: bool = false
## Is the target rooted (can't move but can attack)?
@export var roots: bool = false
## Is the target silenced (can't use special abilities)?
@export var silences: bool = false

# --- SPECIAL ---
## Can this effect spread to nearby units? (like an infection)
@export var spreads: bool = false
## Spread radius in pixels
@export var spread_radius: float = 0.0
## Chance to spread per second (0.0-1.0)
@export var spread_chance: float = 0.0
## Effect applied when this effect expires
@export var on_expire_effect: Resource
## Tags for checking immunities
@export var tags: PackedStringArray = []


# =========================
# HELPER METHODS
# =========================

## Returns true if this is a harmful effect.
func is_negative() -> bool:
	return effect_type in [EffectType.DEBUFF, EffectType.DOT, EffectType.CROWD_CONTROL]

## Returns true if this effect deals damage over time.
func has_dot() -> bool:
	return tick_damage > 0

## Returns true if this effect heals over time.
func has_hot() -> bool:
	return tick_damage < 0

## Returns total damage dealt over the full duration.
func get_total_damage() -> float:
	if duration <= 0 or tick_interval <= 0:
		return 0.0
	return tick_damage * (duration / tick_interval)
