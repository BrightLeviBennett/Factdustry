extends Node
class_name CraneSystem

## Crane autonomous AI + held-payload simulation. Per-anchor state lives
## on BuildingSystem (`crane_states`, `crane_links`) so the dozens of
## external readers (combat_system, main, unit_manager, save_manager) keep
## working unchanged — we mutate those dicts here via reference.
##
## What moved here from BuildingSystem:
##   - `tick_autonomous(delta)` — per-frame state machine that picks up
##     from the next ready input link, traverses the arm to the target,
##     and drops onto the next ready output link.
##   - `tick_held_payload(delta)` — held-block factory + battery sim that
##     keeps a picked-up factory ticking in transit.
##   - All the small AI helpers (input-has-payload, output-ready, payload-
##     matches-filter, midpoint, clamp-to-reach, etc.)
##   - Dynamic power model (`update_dynamic_power`).
##   - Speed multiplier + water-booster drain.
##
## What stays on BuildingSystem:
##   - `crane_states` / `crane_links` state dicts (read all over).
##   - `crane_head_world`, `held_entity_world*`, `get_held_payload_at_depth`,
##     `collect_held_chain`, `damage_held_entity` — the chain-walk public
##     API that combat / save / hud / enemy_unit call.
##   - `update_crane_telescope` — pinned to bsys because it uses the ARM
##     length constants that the draw code also reads, and the draw stack
##     is the only place those need to live.
##   - All `_draw_crane*` helpers (need Node2D draw API).


const CRANE_ROTATE_SPEED := 1
const CRANE_EXTEND_SPEED := 300.0
# Pickup / drop events stash a short burst (CRANE_POWER_BURST_FRAMES) so
# they're visible on the power graph — same model BuildingSystem used.
const CRANE_POWER_BURST_FRAMES := 30
const WATER_BOOST_MULT := 1.5
const WATER_BOOST_DRAIN_PER_SEC := 0.5


@onready var main: Node2D = get_node_or_null("/root/Main")
var _bsys: Node2D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func _process(delta: float) -> void:
	if main == null:
		return
	if "world_paused" in main and main.world_paused:
		return
	# Held-payload tick runs first so a held block's factory state /
	# battery drain is up-to-date before the autonomous AI peeks at it.
	tick_held_payload(delta)
	tick_autonomous(delta)


func _bs() -> Node2D:
	if _bsys == null and main:
		_bsys = main.get_node_or_null("BuildingSystem")
	return _bsys


# =========================
# HELD-PAYLOAD SIMULATION
# =========================

func tick_held_payload(delta: float) -> void:
	if delta <= 0.0:
		return
	var bsys := _bs()
	if bsys == null:
		return
	var power_sys = main.get_node_or_null("PowerSystem")
	for anchor in bsys.crane_states:
		var state: Dictionary = bsys.crane_states[anchor]
		var payload: Variant = state.get("held_payload", null)
		if payload == null or not (payload is Dictionary):
			continue
		var pdict: Dictionary = payload
		if pdict.get("type", "") != "building":
			continue
		tick_held_building(pdict, delta, power_sys)


## Held-payload tick for a single building. Recurses through nested
## crane-in-crane payloads so a chain of grabbed factories all keep
## simulating, each on its own battery.
func tick_held_building(pdict: Dictionary, delta: float, power_sys) -> void:
	var data := Registry.get_block(StringName(pdict.get("block_id", "")))
	if data == null:
		return

	# Head-spin inertia. Eases every captured head's velocity toward 0
	# so the spin-down continues in transit rather than freezing
	# instantly at pickup.
	var spin_snap: Dictionary = pdict.get("head_spin_state", {})
	if not spin_snap.is_empty():
		var heads_sys = main.get_node_or_null("SpinnerHeadSystem")
		if heads_sys:
			heads_sys.tick_held_spin_state(spin_snap, delta)

	# Battery drain. Power-only blocks (no consumption) skip the drain.
	var power_eff: float = 1.0
	if data.electrical_power_use > 0.0:
		var cap: float = 0.0
		if power_sys and power_sys.has_method("resolve_block_battery_capacity"):
			cap = power_sys.resolve_block_battery_capacity(data)
		var charge: float = float(pdict.get("internal_battery_charge", 0.0))
		var needed: float = data.electrical_power_use * delta
		if charge >= needed:
			pdict["internal_battery_charge"] = clampf(charge - needed, 0.0, cap)
		elif charge > 0.0:
			power_eff = charge / maxf(needed, 0.0001)
			pdict["internal_battery_charge"] = 0.0
		else:
			power_eff = 0.0

	# Factory advance.
	if power_eff > 0.0 and data.production_time > 0.0 \
			and (not data.input_items.is_empty() or not data.output_items.is_empty()):
		_held_factory_advance(pdict, data, delta * power_eff)

	# Recurse into nested held cargo.
	if data.tags.has("crane"):
		var inner_state: Dictionary = pdict.get("crane_state", {})
		if not inner_state.is_empty():
			var inner_payload = inner_state.get("held_payload", null)
			if inner_payload is Dictionary:
				var ipd: Dictionary = inner_payload
				if String(ipd.get("type", "")) == "building":
					tick_held_building(ipd, delta, power_sys)


## Minimal off-grid factory advance. Operates on the merged
## `stored_items` buffer the payload carries (factory inputs were
## folded into stored_items at pickup, see main.gd:place_payload_*).
## Outputs land back in stored_items so place_payload_building drops
## them into block_storage on placement.
func _held_factory_advance(pdict: Dictionary, data: BlockData, delta: float) -> void:
	if delta <= 0.0:
		return
	var state: Dictionary = pdict.get("factory_state", {})
	if state.is_empty():
		state = {"phase": "collecting", "timer": 0.0}
		pdict["factory_state"] = state
	var stored: Dictionary = pdict.get("stored_items", {})
	if stored.is_empty() and not data.input_items.is_empty():
		return

	var phase: String = String(state.get("phase", "collecting"))
	if phase == "collecting":
		if _held_factory_has_inputs(stored, data):
			state["phase"] = "processing"
			state["timer"] = data.production_time
			state["timer_total"] = data.production_time
		return

	if phase == "processing":
		var t: float = float(state.get("timer", data.production_time)) - delta
		state["timer"] = t
		if t <= 0.0:
			for item_id in data.input_items:
				var key := String(item_id)
				var have: int = int(stored.get(key, 0))
				stored[key] = maxi(0, have - int(data.input_items[item_id]))
			for out_id in data.output_items:
				var okey := String(out_id)
				stored[okey] = int(stored.get(okey, 0)) + int(data.output_items[out_id])
			state["phase"] = "collecting"
			state["timer"] = 0.0
		pdict["stored_items"] = stored


func _held_factory_has_inputs(stored: Dictionary, data: BlockData) -> bool:
	for item_id in data.input_items:
		var have: int = int(stored.get(String(item_id), 0))
		if have < int(data.input_items[item_id]):
			return false
	return true


# =========================
# AUTONOMOUS AI
# =========================

func tick_autonomous(delta: float) -> void:
	var bsys := _bs()
	if bsys == null or bsys.crane_states.is_empty():
		return
	var unit_mgr = main.get_node_or_null("UnitManager")
	var gs: float = main.GRID_SIZE
	var arrive_radius: float = gs * 0.5

	for anchor in bsys.crane_states.keys():
		if not main.placed_buildings.has(anchor):
			continue
		_drain_crane_water_boost(anchor, delta)
		_update_crane_dynamic_power(anchor)
		# Player-controlled cranes are driven by UnitManager exclusively.
		if unit_mgr and unit_mgr.controlled_type == "crane" and unit_mgr.controlled_entity == anchor:
			continue
		var entry: Dictionary = bsys.crane_links.get(anchor, {"inputs": [], "outputs": []})
		var inputs: Array = entry.get("inputs", [])
		var outputs: Array = entry.get("outputs", [])

		var state: Dictionary = bsys.crane_states[anchor]
		var data = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null:
			continue
		var base: Vector2 = main.grid_to_world(anchor) \
			+ Vector2(data.grid_size.x * gs / 2.0, data.grid_size.y * gs / 2.0)
		var max_reach: float = data.crane_range * gs

		var head_pos: Vector2 = bsys.crane_head_world(anchor)

		if state.get("held_payload", null) == null:
			# Seeking input.
			var picked := false
			for spec in inputs:
				if not _crane_input_has_payload(spec):
					continue
				var t_pos: Vector2 = _crane_ai_target_pos(anchor, spec)
				var t_clamped: Vector2 = _clamp_to_reach(base, t_pos, max_reach)
				state["target_pos"] = t_clamped
				bsys.update_crane_telescope(anchor, t_clamped, delta)
				if (head_pos - t_pos).length() <= arrive_radius:
					_crane_autonomous_pickup(anchor, state, head_pos, spec)
				picked = true
				break
			if not picked:
				# Passive rendezvous with a sender crane targeting us.
				var sender_anchor: Vector2i = _crane_find_incoming_sender(anchor)
				if sender_anchor != Vector2i(-1, -1):
					var meet: Vector2 = _crane_midpoint(anchor, sender_anchor)
					var meet_clamped: Vector2 = _clamp_to_reach(base, meet, max_reach)
					state["target_pos"] = meet_clamped
					bsys.update_crane_telescope(anchor, meet_clamped, delta)
				else:
					# Otherwise park near first ground input (if any).
					for spec in inputs:
						if spec.get("kind", "") == "ground":
							var t_pos2: Vector2 = _crane_ai_target_pos(anchor, spec)
							var t_clamped2: Vector2 = _clamp_to_reach(base, t_pos2, max_reach)
							state["target_pos"] = t_clamped2
							bsys.update_crane_telescope(anchor, t_clamped2, delta)
							break
		else:
			# Seeking output for currently held payload.
			var payload: Dictionary = state["held_payload"]
			var chosen_spec: Dictionary = {}
			for spec in outputs:
				if not _crane_payload_matches_filter(payload, spec):
					continue
				if _crane_output_ready(spec):
					chosen_spec = spec
					break
			if chosen_spec.is_empty():
				for spec in outputs:
					if _crane_payload_matches_filter(payload, spec):
						chosen_spec = spec
						break
			if not chosen_spec.is_empty():
				var t_pos3: Vector2 = _crane_ai_target_pos(anchor, chosen_spec)
				var t_clamped3: Vector2 = _clamp_to_reach(base, t_pos3, max_reach)
				state["target_pos"] = t_clamped3
				bsys.update_crane_telescope(anchor, t_clamped3, delta)
				if (head_pos - t_pos3).length() <= arrive_radius:
					_crane_autonomous_drop(anchor, state, head_pos, chosen_spec)


func _crane_ai_target_pos(my_anchor: Vector2i, spec: Dictionary) -> Vector2:
	var bsys := _bs()
	if spec.get("kind", "") == "block":
		var p: Vector2i = spec.get("pos", Vector2i.ZERO)
		if main.placed_buildings.has(p) and main.placed_buildings.has(my_anchor):
			var bdata = Registry.get_block(main.placed_buildings[p])
			if bdata and bdata.tags.has("crane"):
				var my_data = Registry.get_block(main.placed_buildings[my_anchor])
				if my_data:
					var gs: float = main.GRID_SIZE
					var my_center: Vector2 = main.grid_to_world(my_anchor) \
						+ Vector2(my_data.grid_size.x * gs / 2.0, my_data.grid_size.y * gs / 2.0)
					var other_center: Vector2 = main.grid_to_world(p) \
						+ Vector2(bdata.grid_size.x * gs / 2.0, bdata.grid_size.y * gs / 2.0)
					return (my_center + other_center) / 2.0
	# Diamond-world-pos lives on bsys (used by the link UI input handler)
	# so we pull it from there rather than duplicating.
	if bsys and bsys.has_method("_crane_diamond_world_pos"):
		return bsys._crane_diamond_world_pos(spec)
	return Vector2.ZERO


func _crane_midpoint(a_anchor: Vector2i, b_anchor: Vector2i) -> Vector2:
	var gs: float = main.GRID_SIZE
	var a_data = Registry.get_block(main.placed_buildings.get(a_anchor, &""))
	var b_data = Registry.get_block(main.placed_buildings.get(b_anchor, &""))
	if a_data == null or b_data == null:
		return Vector2.ZERO
	var a_c: Vector2 = main.grid_to_world(a_anchor) \
		+ Vector2(a_data.grid_size.x * gs / 2.0, a_data.grid_size.y * gs / 2.0)
	var b_c: Vector2 = main.grid_to_world(b_anchor) \
		+ Vector2(b_data.grid_size.x * gs / 2.0, b_data.grid_size.y * gs / 2.0)
	return (a_c + b_c) / 2.0


func _crane_find_incoming_sender(me: Vector2i) -> Vector2i:
	var bsys := _bs()
	if bsys == null:
		return Vector2i(-1, -1)
	for other_anchor in bsys.crane_states.keys():
		if other_anchor == me:
			continue
		if not bsys.crane_links.has(other_anchor):
			continue
		var ostate: Dictionary = bsys.crane_states[other_anchor]
		if ostate.get("held_payload", null) == null:
			continue
		var olinks: Dictionary = bsys.crane_links[other_anchor]
		for spec in olinks.get("outputs", []):
			if spec.get("kind", "") != "block":
				continue
			if Vector2i(spec.get("pos", Vector2i.ZERO)) == me:
				return other_anchor
	return Vector2i(-1, -1)


func _clamp_to_reach(base: Vector2, target: Vector2, max_reach: float) -> Vector2:
	var d: Vector2 = target - base
	var L: float = d.length()
	if L <= max_reach:
		return target
	if L < 0.01:
		return base + Vector2(max_reach, 0)
	return base + d / L * max_reach


func _crane_input_has_payload(spec: Dictionary) -> bool:
	var bsys := _bs()
	var kind: String = spec.get("kind", "")
	if kind == "ground":
		var unit_mgr = main.get_node_or_null("UnitManager")
		if unit_mgr == null:
			return false
		var c: Vector2 = bsys._crane_diamond_world_pos(spec) if bsys else Vector2.ZERO
		var r: float = main.GRID_SIZE * 1.5
		for u in unit_mgr.player_units:
			if u == null or not is_instance_valid(u):
				continue
			if (u.position - c).length() <= r:
				if _crane_payload_matches_filter({"type": "unit", "unit_id": str(u.data.id) if u.data else ""}, spec):
					return true
		return false
	# kind == "block"
	var p: Vector2i = spec.get("pos", Vector2i.ZERO)
	if not main.placed_buildings.has(p):
		return false
	var bdata = Registry.get_block(main.placed_buildings[p])
	if bdata == null:
		return false
	if bdata.tags.has("crane"):
		var other_state: Dictionary = bsys.crane_states.get(p, {}) if bsys else {}
		return other_state.get("held_payload", null) != null
	var logistics = main.get_node_or_null("LogisticsSystem")
	if logistics and "payload_items" in logistics:
		if logistics.payload_items.has(p):
			return true
	return false


func _crane_output_ready(spec: Dictionary) -> bool:
	var bsys := _bs()
	var kind: String = spec.get("kind", "")
	if kind == "ground":
		return true
	var p: Vector2i = spec.get("pos", Vector2i.ZERO)
	if not main.placed_buildings.has(p):
		return false
	var bdata = Registry.get_block(main.placed_buildings[p])
	if bdata == null:
		return false
	if bdata.tags.has("crane"):
		return bsys.crane_states.get(p, {}).get("held_payload", null) == null if bsys else false
	var logistics = main.get_node_or_null("LogisticsSystem")
	if logistics and "payload_items" in logistics:
		return not logistics.payload_items.has(p)
	return true


func _crane_payload_matches_filter(payload: Dictionary, spec: Dictionary) -> bool:
	var filter: Array = spec.get("filter", [])
	if filter.is_empty():
		return true
	var t: String = payload.get("type", "")
	var pid: StringName = &""
	if t == "unit":
		pid = StringName(payload.get("unit_id", ""))
	elif t == "building":
		pid = StringName(payload.get("block_id", ""))
	return filter.has(pid)


func _crane_autonomous_pickup(anchor: Vector2i, state: Dictionary, head_pos: Vector2, spec: Dictionary) -> void:
	if _crane_speed_multiplier(anchor) <= 0.0:
		return
	var bsys := _bs()
	var kind: String = spec.get("kind", "")
	var unit_mgr = main.get_node_or_null("UnitManager")
	var logistics = main.get_node_or_null("LogisticsSystem")
	if kind == "ground":
		if unit_mgr == null:
			return
		var c: Vector2 = bsys._crane_diamond_world_pos(spec) if bsys else Vector2.ZERO
		var r: float = main.GRID_SIZE * 1.5
		for u in unit_mgr.player_units.duplicate():
			if u == null or not is_instance_valid(u):
				continue
			if (u.position - c).length() > r:
				continue
			if not _crane_payload_matches_filter({"type": "unit", "unit_id": str(u.data.id) if u.data else ""}, spec):
				continue
			var unit_payload := {
				"type": "unit",
				"unit_id": str(u.data.id) if u.data else "",
				"health": u.health,
				"team": u.team if "team" in u else 0,
				"aim_angle": float(u.aim_angle) if "aim_angle" in u else 0.0,
				"facing_angle": float(u.facing_angle) if "facing_angle" in u else 0.0,
			}
			unit_mgr.player_units.erase(u)
			u.queue_free()
			state["held_payload"] = unit_payload
			state["grabber_open"] = false
			return
		return
	# kind == "block"
	var p: Vector2i = spec.get("pos", Vector2i.ZERO)
	if not main.placed_buildings.has(p):
		return
	var bdata = Registry.get_block(main.placed_buildings[p])
	if bdata == null:
		return
	if bdata.tags.has("crane"):
		# Crane-to-crane handoff: only when both heads are coincident.
		var other_state: Dictionary = bsys.crane_states.get(p, {}) if bsys else {}
		if other_state.get("held_payload", null) == null:
			return
		var other_head: Vector2 = bsys.crane_head_world(p) if bsys else Vector2.ZERO
		if (head_pos - other_head).length() > main.GRID_SIZE * 0.6:
			return
		var p2: Dictionary = other_state["held_payload"]
		if not _crane_payload_matches_filter(p2, spec):
			return
		state["held_payload"] = p2
		other_state["held_payload"] = null
		other_state["grabber_open"] = true
		state["grabber_open"] = false
		return
	# Conveyor / router / mass-driver / constructor with stalled payload
	if logistics and "payload_items" in logistics and logistics.payload_items.has(p):
		var pdata: Dictionary = logistics.payload_items[p].get("payload_data", {})
		if not _crane_payload_matches_filter(pdata, spec):
			return
		state["held_payload"] = pdata.duplicate(true)
		logistics.payload_items.erase(p)
		state["grabber_open"] = false


func _crane_autonomous_drop(anchor: Vector2i, state: Dictionary, head_pos: Vector2, spec: Dictionary) -> void:
	if _crane_speed_multiplier(anchor) <= 0.0:
		return
	var bsys := _bs()
	var kind: String = spec.get("kind", "")
	var payload: Dictionary = state["held_payload"]
	var unit_mgr = main.get_node_or_null("UnitManager")
	var logistics = main.get_node_or_null("LogisticsSystem")
	if kind == "ground":
		var c: Vector2 = bsys._crane_diamond_world_pos(spec) if bsys else Vector2.ZERO
		if payload.get("type", "") == "unit":
			if unit_mgr == null:
				return
			var unit_id := StringName(payload.get("unit_id", ""))
			if unit_id != &"":
				unit_mgr.spawn_player_unit(c, unit_id)
				if not unit_mgr.player_units.is_empty():
					var spawned = unit_mgr.player_units[-1]
					if is_instance_valid(spawned):
						spawned.health = float(payload.get("health", spawned.health))
						if "facing_angle" in spawned and payload.has("facing_angle"):
							spawned.facing_angle = float(payload["facing_angle"])
						if "aim_angle" in spawned and payload.has("aim_angle"):
							spawned.aim_angle = float(payload["aim_angle"])
				state["held_payload"] = null
				state["grabber_open"] = true
		elif payload.get("type", "") == "building":
			var grid_target: Vector2i = main.world_to_grid(c)
			var gsx: int = int(payload.get("grid_size_x", 1))
			var gsy: int = int(payload.get("grid_size_y", 1))
			var center_pos := Vector2i(grid_target.x - gsx / 2, grid_target.y - gsy / 2)
			if main.has_method("place_payload_building") and main.place_payload_building(payload, center_pos):
				state["held_payload"] = null
				state["grabber_open"] = true
		return
	# kind == "block"
	var p: Vector2i = spec.get("pos", Vector2i.ZERO)
	if not main.placed_buildings.has(p):
		return
	var bdata = Registry.get_block(main.placed_buildings[p])
	if bdata == null:
		return
	if bdata.tags.has("crane"):
		var other_state: Dictionary = bsys.crane_states.get(p, {}) if bsys else {}
		if other_state.get("held_payload", null) != null:
			return
		var other_head: Vector2 = bsys.crane_head_world(p) if bsys else Vector2.ZERO
		if (head_pos - other_head).length() > main.GRID_SIZE * 0.6:
			return
		other_state["held_payload"] = state["held_payload"]
		state["held_payload"] = null
		state["grabber_open"] = true
		other_state["grabber_open"] = false
		return
	if logistics and logistics.has_method("_is_payload_cell") and logistics._is_payload_cell(p):
		if logistics.has_method("_try_push_payload") and logistics._try_push_payload(p, payload):
			state["held_payload"] = null
			state["grabber_open"] = true


# =========================
# DYNAMIC POWER + SPEED
# =========================

## Per-payload-crane dynamic power model. Idle 10 W chassis baseline +
## adds for arm rotation (15), extension (10), grabber rotation (5), and
## pickup / drop bursts. Bursts taper to 0 over CRANE_POWER_BURST_FRAMES.
func _update_crane_dynamic_power(anchor: Vector2i) -> void:
	var bsys := _bs()
	if bsys == null:
		return
	var ps = main.get_node_or_null("PowerSystem")
	if ps == null:
		return
	if not bsys.crane_states.has(anchor):
		return
	var state: Dictionary = bsys.crane_states[anchor]
	var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if data == null:
		return
	if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
		if ps.has_method("clear_dynamic_power_use"):
			ps.clear_dynamic_power_use(anchor)
		return

	var draw: float = 10.0

	var cur_arm_angle: float = float(state.get("arm_angle", 0.0))
	var prev_arm_angle: float = float(state.get("_pwr_prev_arm_angle", cur_arm_angle))
	if not is_equal_approx(cur_arm_angle, prev_arm_angle):
		draw += 15.0
	state["_pwr_prev_arm_angle"] = cur_arm_angle

	var cur_ext: float = float(state.get("arm_extension", 0.0))
	var prev_ext: float = float(state.get("_pwr_prev_arm_extension", cur_ext))
	if not is_equal_approx(cur_ext, prev_ext):
		draw += 10.0
	state["_pwr_prev_arm_extension"] = cur_ext

	var cur_g_angle: float = float(state.get("grabber_angle", 0.0))
	var prev_g_angle: float = float(state.get("_pwr_prev_grabber_angle", cur_g_angle))
	if not is_equal_approx(cur_g_angle, prev_g_angle):
		draw += 5.0
	state["_pwr_prev_grabber_angle"] = cur_g_angle

	# Pickup / drop event detection.
	var had_payload: bool = bool(state.get("_pwr_prev_held", false))
	var has_payload_now: bool = state.get("held_payload", null) != null
	if has_payload_now and not had_payload:
		var p_burst: int = _payload_pickup_power(state.get("held_payload"))
		state["_pwr_pickup_burst"] = p_burst
		state["_pwr_pickup_burst_remain"] = CRANE_POWER_BURST_FRAMES
	elif had_payload and not has_payload_now:
		state["_pwr_drop_burst_remain"] = CRANE_POWER_BURST_FRAMES
	state["_pwr_prev_held"] = has_payload_now

	var pickup_remain: int = int(state.get("_pwr_pickup_burst_remain", 0))
	if pickup_remain > 0:
		draw += float(state.get("_pwr_pickup_burst", 0))
		state["_pwr_pickup_burst_remain"] = pickup_remain - 1
	var drop_remain: int = int(state.get("_pwr_drop_burst_remain", 0))
	if drop_remain > 0:
		draw += 10.0
		state["_pwr_drop_burst_remain"] = drop_remain - 1

	if _crane_water_boost_active(anchor):
		draw *= WATER_BOOST_MULT
	if ps.has_method("set_dynamic_power_use"):
		ps.set_dynamic_power_use(anchor, draw)


## Weight-based pickup cost — mirrors `LogisticsSystem._mass_driver_power_for_payload`.
##   tile weight  = 8 per tile (or 8 for a unit)
##   item weight  = 0.5 per stored item
##   fluid weight = 1.0 per stored fluid unit
##   power = floor(weight / 2)
func _payload_pickup_power(payload: Variant) -> int:
	if payload == null or not (payload is Dictionary):
		return 0
	var p: Dictionary = payload
	var weight: float = 0.0
	var ptype: String = String(p.get("type", ""))
	if ptype == "building":
		var sx: int = int(p.get("grid_size_x", 1))
		var sy: int = int(p.get("grid_size_y", 1))
		weight += 8.0 * float(sx) * float(sy)
	elif ptype == "unit":
		weight += 8.0
	var stored_items: Dictionary = p.get("stored_items", {})
	for it_id in stored_items:
		weight += 0.5 * float(int(stored_items[it_id]))
	var stored_fluids: Dictionary = p.get("stored_fluids", {})
	for fl_id in stored_fluids:
		weight += float(stored_fluids[fl_id])
	return int(floor(weight / 2.0))


## Combined motion multiplier — power efficiency × water boost. Used by
## `bsys.update_crane_telescope` to scale arm motion this frame, and by
## the autonomous tick to gate pickups/drops when starved.
func _crane_speed_multiplier(anchor: Vector2i) -> float:
	var ps = main.get_node_or_null("PowerSystem")
	var eff: float = 1.0
	if ps and ps.has_method("get_electrical_efficiency"):
		eff = clampf(float(ps.get_electrical_efficiency(anchor)), 0.0, 1.0)
	if eff <= 0.0:
		return 0.0
	var mult: float = eff
	if _crane_water_boost_active(anchor):
		mult *= WATER_BOOST_MULT
	return mult


func _crane_water_boost_active(anchor: Vector2i) -> bool:
	var logistics = main.get_node_or_null("LogisticsSystem")
	if logistics == null or not "block_storage" in logistics:
		return false
	var storage: Dictionary = logistics.block_storage.get(anchor, {})
	var fluids: Dictionary = storage.get("fluids", {})
	return float(fluids.get(&"mat_water", 0.0)) > 0.0


func _drain_crane_water_boost(anchor: Vector2i, delta: float) -> void:
	var logistics = main.get_node_or_null("LogisticsSystem")
	if logistics == null or not "block_storage" in logistics:
		return
	if not logistics.block_storage.has(anchor):
		return
	var storage: Dictionary = logistics.block_storage[anchor]
	var fluids: Dictionary = storage.get("fluids", {})
	var avail: float = float(fluids.get(&"mat_water", 0.0))
	if avail <= 0.0:
		return
	# Only drain when motion actually consumed boost this frame — i.e.
	# the network has any power at all. A starved crane keeps its water.
	var ps = main.get_node_or_null("PowerSystem")
	if ps and ps.has_method("get_electrical_efficiency") \
			and float(ps.get_electrical_efficiency(anchor)) <= 0.0:
		return
	var consumed: float = WATER_BOOST_DRAIN_PER_SEC * delta
	var remaining: float = maxf(avail - consumed, 0.0)
	if remaining <= 0.0:
		fluids.erase(&"mat_water")
	else:
		fluids[&"mat_water"] = remaining
	storage["fluids"] = fluids
	logistics.block_storage[anchor] = storage


## Public accessor for the speed multiplier — `update_crane_telescope`
## on BuildingSystem queries this when computing this frame's effective
## delta. Same signature as the old internal `_crane_speed_multiplier`.
func crane_speed_multiplier(anchor: Vector2i) -> float:
	return _crane_speed_multiplier(anchor)
