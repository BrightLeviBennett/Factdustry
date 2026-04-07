@tool
class_name ItemData
extends Resource

# ============================================================
# ITEM_DATA.GD - Defines what an "Item" is
# ============================================================
# This is a custom Resource class. Think of it like a template.
# Each .tres file that uses this script becomes one item definition
# (glucose, amino acids, etc.)
#
# "@tool" makes this run in the Godot editor too, so you can
# see property changes live in the Inspector.
#
# "class_name ItemData" registers this as a global type.
# You can then use "ItemData" anywhere in code.
#
# "extends Resource" means this is pure data — no scene tree
# presence, no _process(), just properties.
# ============================================================

# --- IDENTITY ---
## Unique ID used in code (e.g., "glucose", "amino_acids")
@export var id: StringName = &""
## Display name shown to the player
@export var display_name: String = ""
## Description shown in tooltips
@export_multiline var description: String = ""
## Icon texture (assign a sprite in the editor)
@export var icon: Texture2D

# --- STACKING ---
## Max stack size in inventories/conveyors (0 = not stackable)
@export var max_stack: int = 100

# --- CATEGORIZATION ---
## What kind of item this is, for filtering/sorting
enum ItemCategory {
	RAW_RESOURCE,     # Mined/harvested directly (glucose, amino acids)
	REFINED,          # Processed from raw resources (enzymes, ATP)
	ADVANCED,         # Late-game materials (nucleotides, plasmids)
	COMPONENT,        # Used in crafting buildings
	SPECIAL,          # Unique drops, quest items
}
@export var category: ItemCategory = ItemCategory.RAW_RESOURCE

# --- APPEARANCE ---
## Color used when drawing the item on conveyors or as particles
@export var color: Color = Color.WHITE

# --- PROPERTIES ---
## Value per unit for scoring/trading
@export var base_value: float = 1.0
## Whether this item can be placed on conveyors
@export var conveyable: bool = true
