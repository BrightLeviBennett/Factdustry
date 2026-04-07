@tool
class_name BlockData
extends Resource

# ============================================================
# BLOCK_DATA.GD - Defines what a "Block" (Building) is
# ============================================================
# Each .tres file using this script defines one building type
# with all its properties: costs, health, production, appearance.
#
# This replaces the hardcoded dictionaries in main.gd.
# Adding a new building is now as simple as creating a new .tres
# file in the editor — no code changes needed.
# ============================================================

# --- IDENTITY ---
## Unique ID used in code (e.g., "extractor", "acid_turret")
@export var id: StringName = &""
## Display name shown to the player
@export var display_name: String = ""
## Description shown in tooltips/HUD
@export_multiline var description: String = ""
## Icon texture for the HUD button
@export var icon: Texture2D

# --- CATEGORIZATION ---
enum BlockCategory {
	CORE,
	EXTRACTORS,
	FACTORIES,
	POWER,
	TURRETS,
	WALLS,
	UNITS,
	ASSIST,
	ITEMS,
	FLUIDS,
	PAYLOAD,
}
@export var category: BlockCategory = BlockCategory.ITEMS

# --- APPEARANCE ---
## Top face color
@export var color: Color = Color.WHITE
## Side face color (auto-darkened if not set). Leave black to auto-calculate.
@export var side_color: Color = Color.BLACK
## Sprite for the top face (replaces colored square when assigned)
@export var top_sprite: Texture2D
## Base sprite drawn first (for faction-layered blocks like cores)
@export var base_sprite: Texture2D
## Overlay drawn on top of base_sprite when building belongs to Lumina faction
@export var lumina_overlay: Texture2D
## Overlay drawn on top of base_sprite when building belongs to Ferox faction
@export var ferox_overlay: Texture2D
## Overlay drawn on top of base_sprite when building belongs to Derelict faction
@export var derelict_overlay: Texture2D
## Size in grid tiles (most buildings are 1x1)
@export var grid_size: Vector2i = Vector2i(1, 1)

# --- HEALTH ---
@export var max_health: float = 100.0
## HP regenerated per second (0 = no regen)
@export var health_regen: float = 0.0

# --- COST ---
## Dictionary of item_id -> amount needed to build.
## Example: {"glucose": 50, "lipids": 10}
@export var build_cost: Dictionary = {}
## Time in seconds to construct (0 = instant)
@export var build_time: float = 0.0

# --- PRODUCTION ---
## Dictionary of item_id -> amount consumed per cycle.
## Example: {"glucose": 5}
@export var input_items: Dictionary = {}
## Dictionary of item_id -> amount produced per cycle.
## Example: {"atp": 3}
@export var output_items: Dictionary = {}
## Seconds per production cycle
@export var production_time: float = 1.0
## Does this building need power (ATP)?
@export var requires_power: bool = false
## ATP consumed per second when active
@export var power_consumption: float = 0.0

# --- DEFENSE (for turrets) ---
## Damage dealt per shot (base, used when no ammo is loaded)
@export var attack_damage: float = 0.0
## Seconds between shots
@export var attack_speed: float = 1.0
## Range in grid tiles
@export var attack_range: float = 0.0
## Does this turret deal AoE damage?
@export var is_aoe: bool = false
## AoE radius in pixels
@export var aoe_radius: float = 0.0
## Ammo types this turret can use. If empty, turret fires without consuming resources.
## If non-empty, turret requires at least one ammo item in its storage to fire.
@export var ammo_types: Array[Resource] = []

# --- TRANSPORT (for conveyors/pipes) ---
## Items moved per second
@export var transport_speed: float = 0.0
## Can this block transport fluids?
@export var transports_fluid: bool = false

# --- POWER ---
## Rotational power generated per tick (e.g., vent turbine on vent = 20)
@export var rotational_power_gen: float = 0.0
## Rotational power consumed per tick (e.g., mechanical drill = 10)
@export var rotational_power_use: float = 0.0
## Electrical power generated per tick
@export var electrical_power_gen: float = 0.0
## Electrical power consumed per tick
@export var electrical_power_use: float = 0.0

# --- DIRECTIONAL I/O (for factories with side-specific inputs/outputs) ---
## Maps a relative direction (0=right,1=down,2=left,3=up) to the item_id
## accepted on that side. Direction is relative to default rotation (rot=0).
## Example: { 1: &"mat_salt_water" } = input from bottom in default rotation.
@export var side_inputs: Dictionary = {}
## Maps a relative direction to the item_id produced on that side.
## Example: { 3: &"mat_water", 2: &"mat_salt", 0: &"mat_sand" }
@export var side_outputs: Dictionary = {}

# --- STORAGE ---
## Max items this building can hold in internal storage
@export var max_stored_items: int = 6
## Max fluid units this building can hold in internal storage
@export var max_stored_fluids: float = 6.0

# --- SPECIAL ---
## Status effect applied to nearby enemies (reference a StatusEffectData)
@export var applies_status: Resource
## Adjacency bonus: multiplier applied to neighbors of this category
@export var adjacency_bonus: float = 0.0
## Tags for game logic (e.g., ["organic", "membrane", "powered"])
@export var tags: PackedStringArray = []
## Unit ID this fabricator produces (e.g. &"ant"). Empty = not a unit fabricator.
@export var produced_unit: StringName = &""
## Unit capacity added per type when this core is placed.
## e.g. 15 means +15 max of each unit type per copy of this core.
@export var unit_capacity: int = 0
## Per-resource storage capacity added when this core is placed.
## e.g. 4000 means +4000 max of each resource type per copy of this core.
## Unlimited resource types, but each type capped at the total across all cores.
@export var storage_capacity: int = 0
## Max building grid dimension this payload block can transport.
## 3 = payload tier (≤3x3 blocks + all units), 5 = freight tier (≤5x5 blocks + all units), 0 = not a payload block.
@export var max_payload_size: int = 0
## Range of the crane arm in tiles (only for crane blocks).
@export var crane_range: float = 0.0


# =========================
# HELPER METHODS
# =========================

## Returns the side color, auto-calculating if not explicitly set.
func get_side_color() -> Color:
	if side_color != Color.BLACK:
		return side_color
	return color.darkened(0.4)


## Returns the darker side color for the other axis.
func get_side_color_dark() -> Color:
	if side_color != Color.BLACK:
		return side_color.darkened(0.2)
	return color.darkened(0.55)


## Checks if a given dictionary of resources can afford this block.
func can_afford(available_resources: Dictionary) -> bool:
	for item_id in build_cost:
		if not available_resources.has(item_id):
			return false
		if available_resources[item_id] < build_cost[item_id]:
			return false
	return true


## Returns true if this is a turret/defense building.
func is_turret() -> bool:
	return attack_damage > 0 and attack_range > 0


## Returns true if this is a conveyor/transport building.
func is_transport() -> bool:
	return transport_speed > 0


## Returns true if this is a production building.
func is_producer() -> bool:
	return output_items.size() > 0


## Returns true if this block participates in the rotational power network.
func is_rotational_power_block() -> bool:
	return rotational_power_gen > 0 or rotational_power_use > 0 \
		or tags.has("shaft") or tags.has("gearbox") or tags.has("linkable")


## Returns true if this block participates in the electrical power network.
func is_electrical_power_block() -> bool:
	return electrical_power_gen > 0 or electrical_power_use > 0
