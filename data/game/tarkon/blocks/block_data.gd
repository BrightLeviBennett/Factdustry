@tool
class_name BlockData
extends Resource

# ============================================================
# BLOCK_DATA.GD — Data definition for a placeable block.
# Each .tres file using this script is one building type.
# ============================================================

enum BlockCategory { CORE, EXTRACTORS, FACTORIES, POWER, TURRETS, WALLS, UNITS, ASSIST, ITEMS, FLUIDS, PAYLOAD }


@export_group("Identity")
## Unique ID used in code (e.g. "extractor", "acid_turret").
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var icon: Texture2D
@export var category: BlockCategory = BlockCategory.ITEMS
## Free-form tags for game logic (e.g. ["organic", "membrane", "powered"]).
@export var tags: PackedStringArray = []


@export_group("Appearance")
## Top face color (fallback when no sprite is set).
@export var color: Color = Color.WHITE
## Side face color. Leave BLACK to auto-darken from `color`.
@export var side_color: Color = Color.BLACK
## Size in grid tiles.
@export var grid_size: Vector2i = Vector2i(1, 1)
## Sprite for the top face (replaces colored square).
@export var top_sprite: Texture2D
## Base sprite drawn first (for layered blocks like cores/fabricators).
@export var base_sprite: Texture2D
@export_subgroup("Refabricator Overlays")
## Drawn on top of base_sprite when a payload conveyor sits on the
## building's back side (opposite its front/output edge).
@export var feed_overlay_back: Texture2D
## Drawn when a payload conveyor sits on the building's left side.
@export var feed_overlay_left: Texture2D
## Drawn when a payload conveyor sits on the building's right side.
@export var feed_overlay_right: Texture2D
## Replaces `base_sprite` while a payload conveyor is feeding from the
## back (bottom) side. Falls back to `base_sprite` when unset.
@export var base_sprite_back: Texture2D
## Replaces `base_sprite` while a payload conveyor is feeding from the
## left side.
@export var base_sprite_left: Texture2D
## Replaces `base_sprite` while a payload conveyor is feeding from the
## right side.
@export var base_sprite_right: Texture2D
@export_subgroup("Faction Overlays")
@export var lumina_overlay: Texture2D
@export var ferox_overlay: Texture2D
@export var derelict_overlay: Texture2D
@export_subgroup("Turret")
## Rotating head drawn on top of the base, aimed at the target.
@export var turret_head_sprite: Texture2D
## Optional support plate drawn UNDER the heads, rotated by the chassis
## angle only (so it stays rigid while the heads toe in independently).
## Multi-barrel turrets typically use this for a shared mounting plate
## the barrels visibly sit on.
@export var turret_chassis_sprite: Texture2D
## How many heads (barrels) this turret has. Multi-barrel turrets fire
## their barrels in sequence with staggered cooldowns so total rate
## scales with count: two barrels → double fire rate alternating left/
## right. 1 = normal single-barrel behaviour.
@export var barrel_count: int = 1
## Perpendicular spacing between adjacent barrels, in pixels. Each barrel
## is offset from the turret's aim axis by `barrel_spacing` × (i − (N-1)/2)
## so N=2 with spacing 10 gives barrels at ±5. Only used when
## `barrel_count` > 1.
@export var barrel_spacing: float = 10.0


@export_group("Health")
@export var max_health: float = 100.0
## HP regenerated per second (0 = no regen).
@export var health_regen: float = 0.0


@export_group("Cost")
## item_id -> amount needed to build.
@export var build_cost: Dictionary = {}
## Seconds to construct (0 = instant).
@export var build_time: float = 0.0


@export_group("Production")
## item_id -> amount consumed per cycle.
@export var input_items: Dictionary = {}
## item_id -> amount produced per cycle.
@export var output_items: Dictionary = {}
@export var production_time: float = 1.0
@export var requires_power: bool = false
## ATP consumed per second when active.
@export var power_consumption: float = 0.0


@export_group("Combat")
## Seconds between shots.
@export var attack_speed: float = 1.0
## Range in grid tiles.
@export var attack_range: float = 0.0
@export var is_aoe: bool = false
## AoE radius in pixels.
@export var aoe_radius: float = 0.0
## Ammo types accepted. Empty = fires without consuming resources.
@export var ammo_types: Array[Resource] = []


@export_group("Transport")
## Items moved per second.
@export var transport_speed: float = 0.0
@export var transports_fluid: bool = false
## Max building grid dimension this payload block can transport.
## 3 = payload tier, 5 = freight tier, 0 = not a payload block.
@export var max_payload_size: int = 0
## Crane arm range in tiles (crane blocks only).
@export var crane_range: float = 0.0


@export_group("Power")
@export var electrical_power_gen: float = 0.0
@export var electrical_power_use: float = 0.0


@export_group("Directional IO")
## Relative direction (0=right,1=down,2=left,3=up) -> accepted item_id.
@export var side_inputs: Dictionary = {}
## Relative direction -> produced item_id.
@export var side_outputs: Dictionary = {}


@export_group("Storage")
@export var max_stored_items: int = 6
@export var max_stored_fluids: float = 6.0


@export_group("Special")
## Status effect applied to nearby enemies (StatusEffectData).
@export var applies_status: Resource
## Multiplier applied to neighbors of this category.
@export var adjacency_bonus: float = 0.0
## Unit ID this fabricator produces. Empty = not a unit fabricator.
@export var produced_unit: StringName = &""
## Per-unit recipes for refabricators. Maps tier-2 unit id (StringName) to
## a dictionary of item_id -> amount. If a refab's currently-selected
## tier-2 unit has an entry here, that dict overrides `input_items` for
## the duration of that recipe. Empty fallback = use `input_items` for
## every unit, matching legacy behaviour.
@export var refab_recipes: Dictionary = {}
## +N max of each unit type per copy of this core.
@export var unit_capacity: int = 0
## +N max of each resource type per copy of this core.
@export var storage_capacity: int = 0


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


func is_turret() -> bool:
	# A block is a turret iff it has at least one configured ammo type.
	# `Array.count(value)` was being misused here (passing the array
	# itself as the value), which made every block fall back to "not a
	# turret" once the per-block `damage` field was removed and damage
	# moved onto AmmoType entries.
	return ammo_types.size() > 0 and attack_range > 0


func is_transport() -> bool:
	return transport_speed > 0


func is_producer() -> bool:
	return output_items.size() > 0


func is_electrical_power_block() -> bool:
	return electrical_power_gen > 0 or electrical_power_use > 0 \
		or tags.has("cable_node")
