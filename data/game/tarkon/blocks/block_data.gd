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
## Damage absorbed per hit before HP is reduced. A round dealing 30
## damage against 5 armor only chips 25 HP. Cores typically set this.
## Minimum 1 damage always lands so an armored block can't be fully
## invincible.
@export var armor: float = 0.0


@export_group("Shield")
## Shape of the protective shield projected around the block. Empty
## string = no shield. Supported: "rect" or "circle".
@export var shield_shape: String = ""
## Shield dimensions (in tiles). For "rect": (width, height). For
## "circle": x = radius (y ignored).
@export var shield_size: Vector2 = Vector2.ZERO
## World-space offset of the shield centre from the block's footprint
## centre, in tiles. Lets a shield project asymmetrically (e.g. only
## in front of a building).
@export var shield_offset: Vector2 = Vector2.ZERO
## What the shield intercepts at its boundary. "bullets" — only
## stops incoming opposing-faction projectiles (units pass freely).
## "units" — stops both bullets AND opposing-faction units. Friendly
## bullets / units always pass through, both directions.
@export var shield_blocks: String = "bullets"
## Shield hit-points. Each opposing bullet that strikes the boundary
## subtracts its damage from this pool. At 0 the shield breaks and
## enters cooldown.
@export var shield_health: float = 100.0
## Seconds the shield is offline after breaking. Cooldown only ticks
## down while the block is fully powered (see `shield_recharge_power`).
@export var shield_cooldown: float = 10.0
## Constant electrical draw while the shield is up.
@export var shield_idle_power: float = 15.0
## ADDITIONAL draw on top of `shield_idle_power` while the shield is
## broken and recharging its cooldown. Total recharge cost is
## `shield_idle_power + shield_recharge_power` (15 + 20 = 35 by default).
@export var shield_recharge_power: float = 20.0
## When the shield's home block has water in its `block_storage`, the
## cooldown ticks down this much faster (1.5 = 150 %). Water drains at
## the same rate as the cooldown progresses.
@export var shield_water_boost_mult: float = 1.5


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
## Whitelist of ore-tile IDs this extractor is allowed to mine. When
## empty, the standard floor_miner / wall_miner tag rules apply (any
## matching ore). When set, the tile's `id` must appear here — used
## to let multiple drill types share the floor-ore layer without
## overlapping (ground scraper takes coal + sulfur, impact drill /
## earthquake harvester / eruption harvester take the rest).
@export var accepted_ores: Array[StringName] = []
## Whitelist of wall-tile IDs a wall-miner block accepts. When empty,
## defaults to blackstone_wall (the original wall_crusher behaviour).
## Lets specialised crushers — bauxite, etc. — face their own wall
## types without overlapping with the generic wall_crusher.
@export var accepted_walls: Array[StringName] = [&"blackstone_wall"]
## Per-wall efficiency multiplier for wall miners. Wall ids not in this
## dict default to 1.0 (full speed). Used so a wall_crusher can chew
## through purple_wall at 0.75× the speed it tears through plain
## blackstone, without rejecting the placement outright.
@export var wall_efficiency: Dictionary = {}
## Extra tiles BEYOND the front edge that a drill / extractor reaches
## when scanning for ore. 0 = front edge only (no extension), 1 = the
## default mechanical-drill behaviour (front + 1), higher values let
## plasma bores reach further into walls. Used by logistics_system's
## drill update + the placement-preview range visual.
@export var mine_range: int = 1
## Player-selectable factory recipes. When non-empty, this factory ignores
## `input_items` / `output_items` and instead picks an active recipe from
## the list at runtime (selected via the block's world menu, persisted in
## `factory_recipe_state`). Each entry is a Dictionary with keys:
##   "id":            StringName  unique recipe id (e.g. "graphite_rod")
##   "display_name":  String      label shown in the picker
##   "input":         Dictionary  item_id -> amount consumed per cycle
##   "output":        Dictionary  item_id -> amount produced per cycle
## A factory with `factory_recipes` set but no selection stays idle and
## refuses any inputs (matches the Unit Refabricator's "no T2 picked" gate).
@export var factory_recipes: Array = []

## Random one-of-N output table for casting/sorting factories (e.g. the Slag
## Caster: 1 slag → one random grain of sand / copper / iron). When non-empty,
## a finished cycle emits ONE item picked by weight from this list, IN ADDITION
## to any deterministic `output_items`. Each entry is a Dictionary:
##   "item":   StringName  item id to emit
##   "weight": float       relative chance (weights are normalised; equal
##                         weights = equal odds)
@export var random_outputs: Array = []

## Data-driven vent extractor (e.g. Fume Extractor on a sulfur vent). When
## `vent_fluid` is set, a `condenser`-tagged block produces that fluid while
## any cell of its footprint sits on a `vent_tile` floor tile, at `vent_rate`
## units/sec — generalising the built-in vent/geyser → water condenser.
@export var vent_tile: StringName = &""
## Fluid id this vent extractor produces (empty = use the default water
## condenser behaviour).
@export var vent_fluid: StringName = &""
## Production rate (fluid units / second) on a matching vent tile.
@export var vent_rate: float = 4.0


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
## How accurately the turret hits its target (degrees of random aim
## error per shot). 0 = laser-perfect aim; higher values miss more.
## Separate from `bullet_spread` (visual pellet cone).
@export var inaccuracy: float = 0.0
## Visual spread cone for a single shot — pellet count and ammo
## bullet_spread also add to this. 0 = single tight bullet.
@export var bullet_spread: float = 0.0
## Does this turret shoot at flying units (FLYING / HOVER movement layer)?
@export var targets_air: bool = true
## Does this turret shoot at ground units (CRAWLER / WALKER / etc.)?
@export var targets_ground: bool = true
## Max ammo this turret can stockpile (0 = no internal magazine, pulls
## from network on demand). Display-only for now.
@export var ammo_capacity: int = 0
## Maximum amount of fluid this block can buffer (turret fuel, pump
## reservoir, condenser tank, etc.). 0 = no fluid storage. Used by
## logistics for capacity caps and surfaced as "Liquid Capacity" in
## the database UI.
@export var liquid_capacity: float = 0.0
## Required tiles — blocks like pumps / wall crushers / condensers
## need to be placed on or facing specific terrain. Each entry is
## { "tile_id": StringName, "efficiency": float, "label": String? }.
## Display-only; the actual placement validation lives elsewhere.
@export var required_tiles: Array = []
## Booster recipes — fluid / item inputs that grant a stat bonus when
## fed into this block. Each entry is a Dictionary with keys:
##   "item_id":   StringName — the consumed resource
##   "per_sec":   float       — how much is consumed each second when active
##   "stat":      String      — display label, e.g. "Fire Rate", "Mine Speed"
##   "multiplier": float      — value of the boost (e.g. 2.5 = +150%)
## Example: { item_id: "water", per_sec: 0.1, stat: "Fire Rate", multiplier: 2.5 }
@export var boosters: Array = []


@export_group("Transport")
## Items moved per second.
@export var transport_speed: float = 0.0
@export var transports_fluid: bool = false
## Max building grid dimension this payload block can transport.
## 3 = payload tier, 5 = freight tier, 0 = not a payload block.
@export var max_payload_size: int = 0
## Crane arm range in tiles (crane blocks only).
@export var crane_range: float = 0.0
## Maximum link distance (in tiles, anchor-to-anchor euclidean) for
## linkable blocks — bridges, mass drivers. 0 = unlimited.
@export var link_range: float = 0.0


@export_group("Power")
@export var electrical_power_gen: float = 0.0
@export var electrical_power_use: float = 0.0
## Energy buffer (in power-seconds) this block contributes to its
## electrical network. Batteries set this; everything else leaves it 0.
## Surplus generation charges the buffer; deficit drains it before the
## network browns out.
@export var electrical_power_storage: float = 0.0

## Per-block internal battery capacity in "B" units. 1B = 20 power for
## 3 seconds (60 power-seconds); charging 1B from empty also takes 3
## seconds. Used to keep a block running while disconnected (network
## browned out, carried by a crane). When 0, power-consuming blocks
## (electrical_power_use > 0) auto-default to 10B at runtime; set this
## explicitly to override.
@export var internal_battery_units: int = 0

## Fog-of-war sight radius in tiles. Cells within this radius of a
## LUMINA-faction building are revealed as "visible"; once visited
## they stay marked "explored" even if the building is later destroyed.
## When 0, FogSystem auto-defaults to max(attack_range, 5) for turrets
## and a small constant for everything else, so authors only need to
## set this for blocks that should see further than their gun reach
## (radars, observation posts, cores, etc.).
@export var sight_range: float = 0.0


@export_group("Directional IO")
## Relative direction (0=right,1=down,2=left,3=up) -> accepted item_id.
@export var side_inputs: Dictionary = {}
## Relative direction -> produced item_id.
@export var side_outputs: Dictionary = {}


@export_group("Storage")
@export var max_stored_items: int = 6


@export_group("Special")
## For `module`-tagged blocks (unit upgrades): which unit movement layers
## this upgrade may be applied to. Values are UnitData.MovementLayer ints
## (0=GROUND, 1=CRAWLER, 2=HOVER, 3=FLYING). EMPTY = applies to any layer.
## e.g. a Lift Engine sets [2, 3] so it only fits hover / flying units.
@export var module_unit_layers: Array[int] = []
## For `module`-tagged blocks: how many copies of THIS module a single unit
## may hold (independent of the unit's total slot count). e.g. Armor Plate
## = 3, Cooling System = 2, most others = 1.
@export var module_max_applies: int = 1
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
## +N max simultaneous player units this core supports.
@export var max_active_units: int = 0
## +N max of each resource type per copy of this core.
@export var storage_capacity: int = 0
## For unit-fabricator cores (e.g. Core: Bastion), the unit they
## passively spawn / build. Display-only.
@export var spawned_unit: StringName = &""
## Overdrive: blocks of category POWER tagged "overdrive" project a
## production multiplier on every applicable block within
## `overdrive_radius` tiles (Euclidean). Drills, fluid pumps,
## condensers and factories all consult `get_overdrive_multiplier()`
## in main.gd; turrets / conveyors / vent turbines / combustion gens
## are explicitly excluded by tag in main.gd's check.
@export var overdrive_multiplier: float = 1.0
@export var overdrive_radius: float = 0.0

## Mender: blocks tagged "mender" passively heal every friendly
## building within `mend_radius` tiles by `mend_amount` HP per second.
## Driven from main.gd's mender tick.
@export var mend_radius: float = 0.0
@export var mend_amount: float = 0.0


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
