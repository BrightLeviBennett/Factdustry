@tool
class_name FluidData
extends Resource

# ============================================================
# FLUID_DATA.GD - Defines what a "Fluid" is
# ============================================================
# Fluids are transported through pipes (not conveyors).
# They have properties like viscosity, temperature effects,
# and can be mixed or used as fuel/coolant.
#
# Think of these as the "liquid logistics" layer — cytoplasm
# flowing through membrane tubes, acid being pumped to turrets,
# nutrients being piped to production buildings.
# ============================================================

# --- IDENTITY ---
## Unique ID (e.g., "water", "salt_water")
@export var id: StringName = &""
## Display name
@export var display_name: String = ""
## Description
@export_multiline var description: String = ""
## Icon texture
@export var icon: Texture2D

# --- APPEARANCE ---
## Primary color for rendering in pipes and tanks
@export var color: Color = Color.BLUE
## Secondary color for flow animation highlights
@export var highlight_color: Color = Color.WHITE
## Opacity when rendered (0.0-1.0)
@export var opacity: float = 0.8

# --- PHYSICS ---
## Viscosity affects flow speed through pipes.
## 1.0 = normal (water-like), <1.0 = fast/thin, >1.0 = slow/thick
@export var viscosity: float = 1.0
## Units stored per pipe segment (higher viscosity = less per segment)
@export var units_per_segment: float = 100.0

# --- PROPERTIES ---
## Whether this fluid is hazardous (damages buildings if leaked)
@export var is_hazardous: bool = false
## Damage per second if leaked onto buildings/units
@export var hazard_damage: float = 0.0
## Can this fluid be mixed with others?
@export var mixable: bool = false
## Temperature in arbitrary units (affects reactions)
@export var temperature: float = 20.0
## Does this fluid evaporate over time in open containers?
@export var evaporates: bool = false
## Evaporation rate (units lost per second in open storage)
@export var evaporation_rate: float = 0.0

# --- CONVERSION ---
## Can this fluid be converted to/from an item? (e.g., solidified)
@export var item_equivalent: StringName = &""
## How many fluid units = 1 item
@export var units_per_item: float = 10.0

# --- STATUS EFFECTS ---
## Status effect applied when units walk through this fluid
@export var contact_effect: Resource

# --- FIRE ---
## Whether this is a burnable fluid — a block holding it keeps burning
## indefinitely and lets fire spread to it.
@export var flammable: bool = false


# =========================
# HELPER METHODS
# =========================
