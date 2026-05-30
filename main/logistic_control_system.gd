extends Node2D
class_name LogisticControlSystem

## Backend for the Logistical Requestor / Logistical Dispatcher pair.
##
## Both blocks are directional and "look at" the cell directly in front
## of them — see `get_faced_block(anchor)`. The system owns three
## related pieces of state:
##
##   `requestor_state[anchor]`:
##     {
##       "condition_kind":  "storage_has" | "units_produced" | "",
##       "resource_id":     StringName     # item / fluid id (for storage_has)
##       "amount":          int / float    # threshold
##       "is_satisfied":    bool           # last evaluated value
##     }
##
##   `dispatcher_state[anchor]`:
##     {
##       "action_kind":    "stop_block" | "manual_toggle" | "",
##       "linked_anchor":  Vector2i        # the requestor it listens to
##       "manual_on":      bool            # for manual_toggle mode
##       "is_acting":      bool            # last evaluated value
##     }
##
##   `_disabled_blocks`: Dictionary[anchor] -> Vector2i (the dispatcher
##     anchor that disabled it). Read by `main.is_building_inactive`
##     and `is_belt_conveyance_blocked` so the disabled block stops
##     ticking across every system (factories, drills, turrets,
##     conveyors, etc.) without each system having to know about
##     this feature.
##
## Public API (called from BuildingSystem world-menu actions, the
## logistics UI, and the per-frame tick):
##   set_requestor_condition(anchor, condition_kind, resource_id, amount)
##   set_dispatcher_action(anchor, action_kind)
##   link_dispatcher_to_requestor(disp_anchor, req_anchor)
##   toggle_dispatcher_manual(disp_anchor)
##   is_block_disabled(anchor) -> bool
##   get_faced_block(anchor) -> Vector2i
##   is_affected_by_dispatcher(block_id) -> bool

@onready var main: Node2D = get_node("/root/Main")

# Directions: 0 = right (+x), 1 = down (+y), 2 = left (-x), 3 = up (-y).
const _DIR_VECTORS := [
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 0),
	Vector2i(0, -1),
]

var requestor_state: Dictionary = {}
var dispatcher_state: Dictionary = {}
# {anchor → Vector2i(disabler dispatcher anchor)}. Wraps a simple set
# but stores the source dispatcher in case we ever want UI feedback
# like "this block is shut off by Dispatcher at (X, Y)".
var _disabled_blocks: Dictionary = {}

# Throttle the evaluation. Re-checking every requestor at 60 Hz is
# overkill — twice a second is fine and keeps the world-paused contract
# clean.
const _EVAL_INTERVAL: float = 0.5
var _eval_timer: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func _process(delta: float) -> void:
	if main == null:
		return
	if "world_paused" in main and main.world_paused:
		return
	_eval_timer -= delta
	if _eval_timer > 0.0:
		return
	_eval_timer = _EVAL_INTERVAL
	_evaluate_all()


# =========================================================================
# PUBLIC API
# =========================================================================

## True if a dispatcher is currently shutting this anchor down. Read by
## `main.is_building_inactive` so every system inherits the effect for free.
func is_block_disabled(anchor: Vector2i) -> bool:
	return _disabled_blocks.has(anchor)


## Returns the anchor of the block this directional logistic block is
## facing. Scans every cell along the block's "front" edge (so a 2×N
## logistic block facing right can see a building offset to either
## tile of its right edge) and returns the first placed building.
## Vector2i(-9999,-9999) if every front cell is empty.
func get_faced_block(anchor: Vector2i) -> Vector2i:
	if main == null or not main.placed_buildings.has(anchor):
		return Vector2i(-9999, -9999)
	var data = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if data == null:
		return Vector2i(-9999, -9999)
	var rot: int = int(main.building_rotation.get(anchor, 0)) % 4
	var sz: Vector2i = data.grid_size
	# Walk along the appropriate edge: right (rot 0) → +X cells along Y span,
	# down (rot 1) → +Y cells along X span, left (rot 2) → -X cells along
	# Y span, up (rot 3) → -Y cells along X span.
	var probes: Array[Vector2i] = []
	match rot:
		0:
			for dy in range(sz.y):
				probes.append(Vector2i(anchor.x + sz.x, anchor.y + dy))
		1:
			for dx in range(sz.x):
				probes.append(Vector2i(anchor.x + dx, anchor.y + sz.y))
		2:
			for dy in range(sz.y):
				probes.append(Vector2i(anchor.x - 1, anchor.y + dy))
		_:
			for dx in range(sz.x):
				probes.append(Vector2i(anchor.x + dx, anchor.y - 1))
	for p in probes:
		if main.placed_buildings.has(p):
			return main.building_origins.get(p, p)
	return Vector2i(-9999, -9999)


## Sets / updates the requestor's evaluation condition. Pass
## `condition_kind == ""` to clear.
func set_requestor_condition(anchor: Vector2i, condition_kind: String,
		resource_id: StringName, amount: float) -> void:
	var st: Dictionary = requestor_state.get(anchor, {})
	st["condition_kind"] = condition_kind
	st["resource_id"] = resource_id
	st["amount"] = amount
	st["is_satisfied"] = bool(st.get("is_satisfied", false))
	requestor_state[anchor] = st


## Sets the dispatcher's action mode. Valid values:
##   "stop_block"    — disable the faced block while the linked
##                     requestor's condition is satisfied.
##   "manual_toggle" — disable the faced block whenever `manual_on` is
##                     true. No requestor needed.
##   "" (empty)      — disabled, the dispatcher does nothing.
func set_dispatcher_action(anchor: Vector2i, action_kind: String) -> void:
	var st: Dictionary = dispatcher_state.get(anchor, {})
	st["action_kind"] = action_kind
	st["linked_anchor"] = st.get("linked_anchor", Vector2i(-9999, -9999))
	st["manual_on"] = bool(st.get("manual_on", false))
	st["is_acting"] = bool(st.get("is_acting", false))
	dispatcher_state[anchor] = st


## Links a dispatcher to its requestor. The dispatcher will consult
## the requestor's `is_satisfied` flag on the next eval.
func link_dispatcher_to_requestor(disp_anchor: Vector2i, req_anchor: Vector2i) -> void:
	var st: Dictionary = dispatcher_state.get(disp_anchor, {})
	st["linked_anchor"] = req_anchor
	dispatcher_state[disp_anchor] = st


## Flips the manual-toggle bit on a dispatcher (used by the
## "toggle block activation" UI action — no requestor needed).
func toggle_dispatcher_manual(disp_anchor: Vector2i) -> void:
	var st: Dictionary = dispatcher_state.get(disp_anchor, {})
	st["manual_on"] = not bool(st.get("manual_on", false))
	dispatcher_state[disp_anchor] = st
	# Immediate apply so the player gets feedback this frame instead
	# of waiting for the next eval tick.
	_evaluate_all()


## Whitelist: only these block kinds may be shut down by a dispatcher.
## Everything else is silently ignored even if a dispatcher is aimed at
## it. Mirrors the list the player asked for in the design.
func is_affected_by_dispatcher(block_id: StringName) -> bool:
	var data = Registry.get_block(block_id)
	if data == null:
		return false
	# Category-level matches.
	if data.category == BlockData.BlockCategory.FACTORIES:
		return true
	if data.category == BlockData.BlockCategory.EXTRACTORS:
		return true
	# Conveyors + ducts + every transport (pipes, shafts) — i.e. anything
	# the engine treats as "transport" for routing.
	if data.is_transport():
		return true
	# Tag-level matches.
	if data.tags.has("cable_node"): return true
	if data.tags.has("cable_tower"): return true
	if data.tags.has("power_distributor"): return true
	if data.tags.has("logistic_dispatcher"): return true
	if data.tags.has("logistic_requestor"): return true
	if data.tags.has("fabricator"): return true            # unit factories
	if data.tags.has("payload_loader"): return true
	if data.tags.has("payload_unloader"): return true
	if data.tags.has("freight_loader"): return true
	if data.tags.has("freight_unloader"): return true
	if data.tags.has("payload_conveyor"): return true
	if data.tags.has("payload_router"): return true
	if data.tags.has("mass_driver"): return true
	if data.tags.has("launchpad"): return true             # launchpad
	if data.tags.has("interplanetary_launchpad"): return true
	if data.tags.has("interplanetary_core_launchpad"): return true
	if data.tags.has("satellite_launchpad"): return true
	if data.tags.has("overdrive"): return true             # t1/t2/t3 overdrivers
	return false


## Called by BuildingSystem when a block is removed so its rows in our
## state dicts don't leak.
func on_block_removed(anchor: Vector2i) -> void:
	requestor_state.erase(anchor)
	dispatcher_state.erase(anchor)
	_disabled_blocks.erase(anchor)
	# Any dispatcher that was linked to this anchor as a requestor
	# should drop the link; any dispatcher whose FACED block was this
	# anchor should clear its disabled assertion.
	for d_anchor in dispatcher_state.keys():
		var ds: Dictionary = dispatcher_state[d_anchor]
		if Vector2i(ds.get("linked_anchor", Vector2i(-9999, -9999))) == anchor:
			ds["linked_anchor"] = Vector2i(-9999, -9999)
			dispatcher_state[d_anchor] = ds
	# Rebuild the disabled set on the next tick — easier than tracking
	# reverse links here.
	_evaluate_all()


# =========================================================================
# INTERNAL: per-tick evaluation
# =========================================================================

func _evaluate_all() -> void:
	if main == null:
		return
	# Phase 1: every requestor evaluates its condition.
	for req_anchor in requestor_state.keys():
		if not main.placed_buildings.has(req_anchor):
			continue
		var st: Dictionary = requestor_state[req_anchor]
		st["is_satisfied"] = _evaluate_requestor(req_anchor, st)
		requestor_state[req_anchor] = st
	# Phase 2: every dispatcher decides whether to disable its faced
	# block. We rebuild the disabled set from scratch each pass — cheap
	# (dispatcher count is low) and avoids stale entries.
	var new_disabled: Dictionary = {}
	for disp_anchor in dispatcher_state.keys():
		if not main.placed_buildings.has(disp_anchor):
			continue
		var ds: Dictionary = dispatcher_state[disp_anchor]
		var target: Vector2i = get_faced_block(disp_anchor)
		if target == Vector2i(-9999, -9999):
			ds["is_acting"] = false
			dispatcher_state[disp_anchor] = ds
			continue
		# Whitelist check — non-affected blocks are silently ignored.
		var target_id: StringName = main.placed_buildings.get(target, &"")
		if not is_affected_by_dispatcher(target_id):
			ds["is_acting"] = false
			dispatcher_state[disp_anchor] = ds
			continue
		var act_kind: String = String(ds.get("action_kind", ""))
		var should_disable: bool = false
		match act_kind:
			"stop_block":
				var req_anchor2: Vector2i = ds.get("linked_anchor", Vector2i(-9999, -9999))
				if requestor_state.has(req_anchor2):
					should_disable = bool(requestor_state[req_anchor2].get("is_satisfied", false))
			"manual_toggle":
				should_disable = bool(ds.get("manual_on", false))
			_:
				should_disable = false
		ds["is_acting"] = should_disable
		dispatcher_state[disp_anchor] = ds
		if should_disable:
			new_disabled[target] = disp_anchor
	_disabled_blocks = new_disabled


func _evaluate_requestor(anchor: Vector2i, st: Dictionary) -> bool:
	var kind: String = String(st.get("condition_kind", ""))
	if kind == "":
		return false
	var faced: Vector2i = get_faced_block(anchor)
	if faced == Vector2i(-9999, -9999):
		return false
	match kind:
		"storage_has":
			return _condition_storage_has(faced,
				StringName(st.get("resource_id", &"")),
				float(st.get("amount", 0.0)))
		"units_produced":
			return _condition_units_produced(faced,
				float(st.get("amount", 0.0)))
		_:
			return false


## "storage has [amount] of [resource]" — checks the faced block's
## block_storage (items + fluids) and faction cores too. `resource_id`
## may be either an item id or a fluid id.
func _condition_storage_has(faced: Vector2i, resource_id: StringName,
		amount: float) -> bool:
	if resource_id == &"":
		return false
	var logistics = main.get_node_or_null("LogisticsSystem")
	var total: float = 0.0
	# Block storage (works for landing pad, containers, factory buffers).
	if logistics and "block_storage" in logistics \
			and logistics.block_storage.has(faced):
		var s: Dictionary = logistics.block_storage[faced]
		total += float(int(s.get("items", {}).get(resource_id, 0)))
		total += float(s.get("fluids", {}).get(resource_id, 0.0))
	# Factory buffers (input + output).
	if logistics and "factory_buffers" in logistics \
			and logistics.factory_buffers.has(faced):
		var fb: Dictionary = logistics.factory_buffers[faced]
		total += float(int(fb.get("inputs", {}).get(resource_id, 0)))
		total += float(int(fb.get("outputs", {}).get(resource_id, 0)))
	# Core pool — works when the requestor faces any LUMINA core.
	var faced_data = Registry.get_block(main.placed_buildings.get(faced, &""))
	if faced_data and faced_data.tags.has("core") \
			and "resources" in main \
			and main.resources.has(resource_id):
		total += float(int(main.resources[resource_id]))
	return total >= amount


## "[amount] of units produced" — checks the unit fabricator at `faced`.
## We track per-anchor produced counts on `logistics.fabricator_state`
## under "units_produced"; if that field isn't present yet we fall back
## to 0 (condition never satisfies, surfacing the missing piece).
func _condition_units_produced(faced: Vector2i, amount: float) -> bool:
	var logistics = main.get_node_or_null("LogisticsSystem")
	if logistics == null:
		return false
	var produced: int = 0
	if "fabricator_state" in logistics and logistics.fabricator_state.has(faced):
		var fs: Dictionary = logistics.fabricator_state[faced]
		produced = int(fs.get("units_produced", 0))
	return float(produced) >= amount
