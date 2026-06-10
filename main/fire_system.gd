extends Node2D
class_name FireSystem

# ============================================================
# FIRE_SYSTEM.GD — Block-on-fire mechanic (Mindustry's Fire)
# ============================================================
# A building can be set alight via `ignite_building(anchor)`. While burning it
# loses HP over time and spits flame particles (delegated to ParticleOverlay).
#
# Lifecycle rules:
#   • A fire on a NORMAL block burns for `NORMAL_LIFETIME` (4s) then dies.
#   • A fire on a block holding a BURNABLE resource (a flammable item/fluid in
#     its storage or factory buffers) burns FOREVER — until the block is gone,
#     whether the fire's own damage destroys it or it's deconstructed.
#   • Fire does NOT spread by default. It only spreads to a block that (a) is
#     TOUCHING the burning block and (b) holds a burnable resource — and only
#     after 2s of continuous contact.
#   • When the burning block is destroyed/deconstructed, the fire lingers for
#     `GONE_PERSIST` (2.5s) — still able to spread — then goes out.
# Logic-only node; the flame visual comes from ParticleOverlay.spawn_fire().
# ============================================================

@onready var main: Node2D = get_node_or_null("/root/Main")
var _particle_overlay: Node = null
var _logistics: Node = null

## anchor (Vector2i) -> fire state dict (see ignite_building for the shape).
var building_fires: Dictionary = {}

const NORMAL_LIFETIME := 4.0       # fire on a non-burnable block (s)
const GONE_PERSIST := 2.5          # how long fire lingers after the block is gone (s)
const SPREAD_CONTACT := 2.0        # contact time before fire jumps to a burnable neighbour (s)
const FIRE_DMG_INTERVAL := 0.5     # damage tick cadence (s)
const FIRE_DMG_PER_TICK := 8.0     # building HP lost per damage tick
const FIRE_EMIT_INTERVAL := 0.06   # flame-particle emission cadence (s)

const _DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


func _ready() -> void:
	_particle_overlay = get_node_or_null("/root/Main/ParticleOverlay")
	_logistics = get_node_or_null("/root/Main/LogisticsSystem")


func _logistics_ref() -> Node:
	if _logistics == null:
		_logistics = get_node_or_null("/root/Main/LogisticsSystem")
	return _logistics


## Sets the building at `grid_pos` alight (resolving to its anchor). Refreshes
## the timer if it's already burning. No-op for empty cells / non-flammable
## structural blocks (walls, fireproof). Pass `force = true` for a direct flame
## source (the Flarecaster's jet) so it can set walls alight too — `fireproof`
## blocks still shrug it off, and ambient fire spread never reaches walls
## because it only jumps to neighbours holding burnable cargo.
func ignite_building(grid_pos: Vector2i, force: bool = false) -> void:
	if main == null:
		return
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	if not main.placed_buildings.has(anchor):
		return
	if not _can_catch(anchor, force):
		return
	if building_fires.has(anchor):
		# Refresh the normal-block burn timer; burnable blocks ignore it anyway.
		building_fires[anchor]["normal_burn"] = 0.0
		return
	var bd = Registry.get_block(main.placed_buildings[anchor])
	var gsz: Vector2i = bd.grid_size if bd else Vector2i.ONE
	building_fires[anchor] = {
		"normal_burn": 0.0, "dmg_acc": 0.0, "emit_acc": 0.0,
		"gone": false, "gone_timer": 0.0,
		"contact": {},                                # neighbour anchor -> contact seconds
		"last_top_left": main.grid_to_world(anchor),  # cached for emit after the block is gone
		"last_gsz": gsz,
	}


## True if this block can structurally catch fire at all. `fireproof` blocks
## always shrug it off; `wall` blocks resist ambient fire but a direct flame
## source (`force`) can still set them alight.
func _can_catch(anchor: Vector2i, force: bool = false) -> bool:
	var bd = Registry.get_block(main.placed_buildings[anchor])
	if bd == null:
		return false
	if bd.tags.has("fireproof"):
		return false
	if bd.tags.has("wall") and not force:
		return false
	return true


## True if the block at `anchor` is currently holding a burnable resource —
## any flammable item or fluid in its storage or factory input buffer.
func _block_has_burnable(anchor: Vector2i) -> bool:
	var log_ref: Node = _logistics_ref()
	if log_ref == null:
		return false
	if "block_storage" in log_ref and log_ref.block_storage.has(anchor):
		var st: Dictionary = log_ref.block_storage[anchor]
		for iid in st.get("items", {}):
			if int(st["items"][iid]) > 0 and _resource_flammable(StringName(iid)):
				return true
		for fid in st.get("fluids", {}):
			if float(st["fluids"][fid]) > 0.0 and _resource_flammable(StringName(fid)):
				return true
	if "factory_buffers" in log_ref and log_ref.factory_buffers.has(anchor):
		var inputs: Dictionary = log_ref.factory_buffers[anchor].get("inputs", {})
		for iid2 in inputs:
			if int(inputs[iid2]) > 0 and _resource_flammable(StringName(iid2)):
				return true
	# Items riding a conveyor / junction across this block's footprint count
	# too — a belt carrying coal or fuel feeds the fire just like stored cargo.
	var bd = Registry.get_block(main.placed_buildings.get(anchor, &""))
	var gsz: Vector2i = bd.grid_size if bd else Vector2i.ONE
	for x in range(maxi(gsz.x, 1)):
		for y in range(maxi(gsz.y, 1)):
			var cell: Vector2i = anchor + Vector2i(x, y)
			if "conveyor_items" in log_ref and log_ref.conveyor_items.has(cell):
				if _resource_flammable(StringName(log_ref.conveyor_items[cell].get("item_id", &""))):
					return true
			if "junction_items" in log_ref and log_ref.junction_items.has(cell):
				if _resource_flammable(StringName(log_ref.junction_items[cell].get("item_id", &""))):
					return true
	return false


func _resource_flammable(id: StringName) -> bool:
	var it = Registry.get_item(id)
	if it != null and "flammable" in it and it.flammable:
		return true
	var fl = Registry.get_fluid(id)
	if fl != null and "flammable" in fl and fl.flammable:
		return true
	return false


func _process(delta: float) -> void:
	if main == null or building_fires.is_empty():
		return
	if "world_paused" in main and main.world_paused:
		return
	var to_remove: Array = []
	# Snapshot keys so spreading (which inserts new fires) is safe.
	for anchor in building_fires.keys():
		var f: Dictionary = building_fires[anchor]
		var present: bool = main.placed_buildings.has(anchor)

		if not present:
			# Block destroyed / deconstructed — linger a bit, can still spread.
			f["gone"] = true
			f["gone_timer"] = float(f["gone_timer"]) + delta
			_emit_flames(f["last_top_left"], f["last_gsz"], f, delta)
			_spread(f, anchor, f["last_gsz"], delta)
			if float(f["gone_timer"]) >= GONE_PERSIST:
				to_remove.append(anchor)
			continue

		var bd = Registry.get_block(main.placed_buildings[anchor])
		var gsz: Vector2i = bd.grid_size if bd else Vector2i.ONE
		var top_left: Vector2 = main.grid_to_world(anchor)
		f["last_gsz"] = gsz
		f["last_top_left"] = top_left

		var burnable: bool = _block_has_burnable(anchor)
		# A burnable block burns until it's gone; a non-burnable one burns out
		# after NORMAL_LIFETIME. The timer ONLY advances while not burnable (and
		# resets the moment burnable cargo is present) so a belt that flickers
		# between flammable / empty cargo isn't killed the instant it empties.
		if burnable:
			f["normal_burn"] = 0.0
		else:
			f["normal_burn"] = float(f["normal_burn"]) + delta
			if float(f["normal_burn"]) >= NORMAL_LIFETIME:
				to_remove.append(anchor)
				continue

		# Damage tick. If our own fire destroys the block, fall into the
		# gone-persist path next frame.
		f["dmg_acc"] = float(f["dmg_acc"]) + delta
		if float(f["dmg_acc"]) >= FIRE_DMG_INTERVAL:
			f["dmg_acc"] = float(f["dmg_acc"]) - FIRE_DMG_INTERVAL
			main.damage_building(anchor, FIRE_DMG_PER_TICK)
			if not main.placed_buildings.has(anchor):
				f["gone"] = true
				f["gone_timer"] = 0.0
				continue

		_emit_flames(top_left, gsz, f, delta)
		_spread(f, anchor, gsz, delta)

	for a in to_remove:
		building_fires.erase(a)


## Emits flame particles from random points over a footprint, metered by the
## fire's own emit accumulator.
func _emit_flames(top_left: Vector2, gsz: Vector2i, f: Dictionary, delta: float) -> void:
	var po: Node = _particle_overlay
	if po == null or not po.has_method("spawn_fire"):
		return
	f["emit_acc"] = float(f["emit_acc"]) + delta
	if float(f["emit_acc"]) < FIRE_EMIT_INTERVAL:
		return
	f["emit_acc"] = float(f["emit_acc"]) - FIRE_EMIT_INTERVAL
	var gs: float = float(main.GRID_SIZE)
	var px: Vector2 = top_left + Vector2(randf() * float(gsz.x) * gs, randf() * float(gsz.y) * gs)
	po.spawn_fire(px, Vector2(0.0, -1.0), 2, 55.0, 0.65, gs * 0.18, 110.0)


## Spreads only to TOUCHING neighbour blocks that hold a burnable resource,
## and only after SPREAD_CONTACT seconds of continuous contact.
func _spread(f: Dictionary, anchor: Vector2i, gsz: Vector2i, delta: float) -> void:
	var contact: Dictionary = f["contact"]
	var neighbours: Dictionary = _footprint_neighbour_anchors(anchor, gsz)
	# Tick contact for touching burnable neighbours; reset the rest.
	for nb in neighbours:
		if nb == anchor or building_fires.has(nb):
			continue
		if not _block_has_burnable(nb):
			contact.erase(nb)
			continue
		contact[nb] = float(contact.get(nb, 0.0)) + delta
		if float(contact[nb]) >= SPREAD_CONTACT:
			ignite_building(nb)
			contact.erase(nb)
	# Drop contact timers for neighbours we're no longer touching.
	for k in contact.keys():
		if not neighbours.has(k):
			contact.erase(k)


## Distinct building anchors orthogonally adjacent to `anchor`'s footprint
## (excluding the footprint itself), returned as a set (anchor -> true).
func _footprint_neighbour_anchors(anchor: Vector2i, gsz: Vector2i) -> Dictionary:
	var out: Dictionary = {}
	for x in range(maxi(gsz.x, 1)):
		for y in range(maxi(gsz.y, 1)):
			var cell: Vector2i = anchor + Vector2i(x, y)
			for d in _DIRS:
				var nc: Vector2i = cell + d
				# Skip cells inside our own footprint.
				if nc.x >= anchor.x and nc.x < anchor.x + gsz.x \
						and nc.y >= anchor.y and nc.y < anchor.y + gsz.y:
					continue
				if main.placed_buildings.has(nc):
					out[main.building_origins.get(nc, nc)] = true
	out.erase(anchor)
	return out


## True if the building at `grid_pos` (or its anchor) is currently on fire.
func is_burning(grid_pos: Vector2i) -> bool:
	if main == null:
		return false
	return building_fires.has(main.building_origins.get(grid_pos, grid_pos))


## Puts out the fire on the building at `grid_pos` (or its anchor). Used by the
## Spritz turret's water firefighting. Returns true if a fire was extinguished.
func extinguish_building(grid_pos: Vector2i) -> bool:
	if main == null:
		return false
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	if building_fires.has(anchor):
		building_fires.erase(anchor)
		return true
	return false


## Anchors of every building currently on fire (snapshot copy — safe to iterate
## while extinguishing). Used by the Spritz to find friendly fires to douse.
func burning_anchors() -> Array:
	return building_fires.keys()
