extends Node
class_name SpinnerHeadSystem

## Per-frame ticks for every "spinning bit" on a placed block:
## crusher heads, scraper heads, impact drill heads, vent turbines, vent
## condensers, and layered-spinner factories (brass mixer, silicon
## refinery, …). All six were inline in BuildingSystem; this node groups
## the tick code and the productivity-gate helpers so building_system.gd
## loses ~600 lines of inertial-spin bookkeeping.
##
## State dicts (`_crusher_head_state`, …) still live on BuildingSystem
## because every layered-block draw site lazy-initialises them at draw
## time. Dicts are reference-type, so we mutate BuildingSystem's dicts
## directly from here — no copy / round-trip needed.


# Spin / accel constants. Same numbers as before; central here so a
# tune-up only touches one file.
const CRUSHER_HEAD_SPIN_A := 3.7
const CRUSHER_HEAD_SPIN_B := -4.2
const CRUSHER_HEAD_ACCEL := 5.0
const SCRAPER_HEAD_SPIN := -4.5
const SCRAPER_HEAD_ACCEL := 5.0
const VENT_TURBINE_SPIN := 7.5
const VENT_TURBINE_ACCEL := 5.0
const VENT_CONDENSER_SPIN := 7.5
const VENT_CONDENSER_ACCEL := 5.0
# Decel rates used while a block is held inside a crane grabber — each
# tracked spin kind eases its velocity toward 0 at this rate so the head
# coasts to a stop instead of teleport-halting the instant the grabber
# closed. Layered-spinner uses a single shared decel (per the original
# rationale — coast-down looks identical on every drum-style head).
const _SPIN_DECEL := {
	"crusher": CRUSHER_HEAD_ACCEL,
	"scraper": SCRAPER_HEAD_ACCEL,
	"vent_turbine": VENT_TURBINE_ACCEL,
	"vent_condenser": VENT_CONDENSER_ACCEL,
	"layered_spinner": 2.0,
}


@onready var main: Node2D = get_node_or_null("/root/Main")
var _bsys: Node2D     # BuildingSystem — state dicts + helper refs live there


func _ready() -> void:
	# Match BuildingSystem's PROCESS_MODE so ticks freeze on pause via the
	# main.world_paused guard inside `tick()`.
	process_mode = Node.PROCESS_MODE_PAUSABLE


func _process(delta: float) -> void:
	if main == null:
		return
	if "world_paused" in main and main.world_paused:
		return
	tick(delta)


func _building_sys() -> Node2D:
	if _bsys == null and main:
		_bsys = main.get_node_or_null("BuildingSystem")
	return _bsys


## Master tick called from `_process`. BuildingSystem also invokes this
## explicitly from its own `_process` (legacy ordering), so the body is
## guarded against re-entry by being effectively idempotent (each sub-
## tick reads `delta` and operates on its own state dict).
func tick(delta: float) -> void:
	tick_crusher_heads(delta)
	tick_scraper_heads(delta)
	tick_impact_heads(delta)
	tick_vent_turbines(delta)
	tick_layered_spinners(delta)
	tick_vent_condensers(delta)


# =========================
# CRUSHER HEADS
# =========================

func tick_crusher_heads(delta: float) -> void:
	var bsys := _building_sys()
	if bsys == null or bsys._crusher_head_state.is_empty():
		return
	var to_erase: Array[Vector2i] = []
	for anchor in bsys._crusher_head_state:
		if not main.placed_buildings.has(anchor):
			to_erase.append(anchor)
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings[anchor])
		if data == null or (not data.tags.has("crusher_heads") and not data.tags.has("grinder_heads")):
			to_erase.append(anchor)
			continue
		var active := is_crusher_spinning(anchor, data)
		var s: Dictionary = bsys._crusher_head_state[anchor]
		var step: float = CRUSHER_HEAD_ACCEL * delta
		for key in s.keys():
			if not (key as String).begins_with("angle_"):
				continue
			var idx: int = int(String(key).substr(6))
			var vkey: String = "vel_%d" % idx
			var base_target: float = CRUSHER_HEAD_SPIN_A if (idx % 2 == 0) else CRUSHER_HEAD_SPIN_B
			var target: float = (base_target * (1.0 + 0.05 * idx)) if active else 0.0
			s[vkey] = move_toward(float(s.get(vkey, 0.0)), target, step)
			s[key] = fposmod(float(s[key]) + float(s[vkey]) * delta, TAU)
	for a in to_erase:
		bsys._crusher_head_state.erase(a)


## True when a crusher should be spinning right now: finished
## construction, powered, not disabled by sector script, AND has at
## least one output it can still produce.
func is_crusher_spinning(anchor: Vector2i, data: BlockData) -> bool:
	if data == null:
		return false
	if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
		return false
	var ss = main.get_node_or_null("SectorScript")
	if ss and ss.has_method("is_building_disabled") and ss.is_building_disabled(anchor):
		return false
	if data.electrical_power_use > 0:
		var ps = main.get_node_or_null("PowerSystem")
		if ps == null or ps.get_electrical_efficiency(anchor) <= 0.0:
			return false
	var logistics = main.get_node_or_null("LogisticsSystem")
	if logistics and logistics.has_method("_is_storage_full_for"):
		var any_room := false
		for raw_id in data.output_items:
			var item_id: StringName = StringName(raw_id)
			if not logistics._is_storage_full_for(anchor, data, item_id):
				any_room = true
				break
		if not any_room:
			return false
	return true


# =========================
# SCRAPER HEADS
# =========================

func is_scraper_spinning(anchor: Vector2i, data: BlockData) -> bool:
	if data == null:
		return false
	if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
		return false
	var ss = main.get_node_or_null("SectorScript")
	if ss and ss.has_method("is_building_disabled") and ss.is_building_disabled(anchor):
		return false
	if data.electrical_power_use > 0:
		var ps = main.get_node_or_null("PowerSystem")
		if ps == null or ps.get_electrical_efficiency(anchor) <= 0.0:
			return false
	var logistics = main.get_node_or_null("LogisticsSystem")
	if logistics and logistics.has_method("_is_storage_full"):
		if logistics._is_storage_full(anchor, data):
			return false
	return true


func tick_scraper_heads(delta: float) -> void:
	var bsys := _building_sys()
	if bsys == null or bsys._scraper_head_state.is_empty():
		return
	var to_erase: Array[Vector2i] = []
	for anchor in bsys._scraper_head_state:
		if not main.placed_buildings.has(anchor):
			to_erase.append(anchor)
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings[anchor])
		if data == null or not data.tags.has("scraper_head"):
			to_erase.append(anchor)
			continue
		var active := is_scraper_spinning(anchor, data)
		var target: float = SCRAPER_HEAD_SPIN if active else 0.0
		var s: Dictionary = bsys._scraper_head_state[anchor]
		var step: float = SCRAPER_HEAD_ACCEL * delta
		s["vel"] = move_toward(float(s["vel"]), target, step)
		s["angle"] = fposmod(float(s["angle"]) + float(s["vel"]) * delta, TAU)
	for a in to_erase:
		bsys._scraper_head_state.erase(a)


# =========================
# IMPACT DRILL HEADS
# =========================

func tick_impact_heads(_delta: float) -> void:
	var bsys := _building_sys()
	if bsys == null:
		return
	var logistics = main.get_node_or_null("LogisticsSystem")
	if logistics == null:
		return
	var to_erase: Array[Vector2i] = []
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if bsys._impact_head_state.has(anchor):
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null or not data.tags.has("impact_head"):
			continue
		bsys._impact_head_state[anchor] = {"slam_progress": 0.0, "prev_progress": 0.0}
	for anchor in bsys._impact_head_state:
		if not main.placed_buildings.has(anchor):
			to_erase.append(anchor)
			continue
		var data2: BlockData = Registry.get_block(main.placed_buildings[anchor])
		if data2 == null or not data2.tags.has("impact_head"):
			to_erase.append(anchor)
			continue
		var s: Dictionary = bsys._impact_head_state[anchor]
		var cycle: float = data2.production_time if data2.production_time > 0.0 else 2.0
		var timer: float = -1.0
		if "drill_timers" in logistics and logistics.drill_timers.has(anchor):
			timer = float(logistics.drill_timers[anchor])
		var prev: float = float(s.get("slam_progress", 0.0))
		var target: float
		if timer < 0.0:
			target = 0.0
		else:
			target = clampf(1.0 - timer / maxf(cycle, 0.0001), 0.0, 1.0)
		var armed: bool = bool(s.get("armed", false))
		if not armed and target >= 0.9:
			armed = true
		if armed and prev - target >= 0.4:
			_spawn_impact_slam_burst(anchor, data2)
			armed = false
		s["armed"] = armed
		s["prev_progress"] = prev
		s["slam_progress"] = target
	for a in to_erase:
		bsys._impact_head_state.erase(a)


func _spawn_impact_slam_burst(anchor: Vector2i, data: BlockData) -> void:
	var overlay = main.get_node_or_null("ParticleOverlay")
	if overlay == null or not overlay.has_method("spawn_burst"):
		return
	var gs: float = float(main.GRID_SIZE)
	var center: Vector2 = main.grid_to_world(anchor) \
		+ Vector2(data.grid_size.x * gs * 0.5, data.grid_size.y * gs * 0.5)
	overlay.spawn_burst(center, "impact_slam")


# =========================
# VENT TURBINES
# =========================

func tick_vent_turbines(delta: float) -> void:
	var bsys := _building_sys()
	if bsys == null or bsys._vent_turbine_state.is_empty():
		return
	var to_erase: Array[Vector2i] = []
	for anchor in bsys._vent_turbine_state:
		if not main.placed_buildings.has(anchor):
			to_erase.append(anchor)
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings[anchor])
		if data == null or data.id != &"vent_turbine":
			to_erase.append(anchor)
			continue
		var active: bool = not (main.has_method("is_building_inactive") \
			and main.is_building_inactive(anchor))
		var target: float = VENT_TURBINE_SPIN if active else 0.0
		var s: Dictionary = bsys._vent_turbine_state[anchor]
		var step: float = VENT_TURBINE_ACCEL * delta
		s["vel"] = move_toward(float(s["vel"]), target, step)
		s["angle"] = fposmod(float(s["angle"]) + float(s["vel"]) * delta, TAU)
	for a in to_erase:
		bsys._vent_turbine_state.erase(a)


# =========================
# VENT CONDENSERS
# =========================

func tick_vent_condensers(delta: float) -> void:
	var bsys := _building_sys()
	if bsys == null or bsys._vent_condenser_state.is_empty():
		return
	var to_erase: Array[Vector2i] = []
	for anchor in bsys._vent_condenser_state:
		if not main.placed_buildings.has(anchor):
			to_erase.append(anchor)
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings[anchor])
		if data == null or data.id != &"vent_condenser":
			to_erase.append(anchor)
			continue
		var active: bool = is_vent_condenser_spinning(anchor, data)
		var target: float = VENT_CONDENSER_SPIN if active else 0.0
		var s: Dictionary = bsys._vent_condenser_state[anchor]
		var step: float = VENT_CONDENSER_ACCEL * delta
		s["vel"] = move_toward(float(s["vel"]), target, step)
		s["angle"] = fposmod(float(s["angle"]) + float(s["vel"]) * delta, TAU)
	for a in to_erase:
		bsys._vent_condenser_state.erase(a)


func is_vent_condenser_spinning(anchor: Vector2i, data: BlockData) -> bool:
	if data == null:
		return false
	if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
		return false
	var ss = main.get_node_or_null("SectorScript")
	if ss and ss.has_method("is_building_disabled") and ss.is_building_disabled(anchor):
		return false
	if data.electrical_power_use > 0:
		var ps = main.get_node_or_null("PowerSystem")
		if ps == null or ps.get_electrical_efficiency(anchor) <= 0.0:
			return false
	return true


# =========================
# LAYERED SPINNERS (brass mixer / silicon refinery / …)
# =========================

func tick_layered_spinners(delta: float) -> void:
	var bsys := _building_sys()
	if bsys == null:
		return
	var spinners: Dictionary = bsys._LAYERED_SPINNERS
	var to_erase: Array[Vector2i] = []
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if bsys._layered_spinner_state.has(anchor):
			continue
		var bid: StringName = main.placed_buildings.get(anchor, &"")
		if not spinners.has(bid):
			continue
		bsys._layered_spinner_state[anchor] = {"angle": 0.0, "vel": 0.0}
	for anchor in bsys._layered_spinner_state:
		if not main.placed_buildings.has(anchor):
			to_erase.append(anchor)
			continue
		var bid2: StringName = main.placed_buildings[anchor]
		if not spinners.has(bid2):
			to_erase.append(anchor)
			continue
		var cfg: Dictionary = spinners[bid2]
		var s: Dictionary = bsys._layered_spinner_state[anchor]
		# Spin steadily for the whole "processing" phase — same as crusher /
		# scraper heads, which gate on a stable boolean. The old code ALSO
		# required the factory's production timer to have advanced *this
		# frame* (`timer_advanced`); but factories tick at ~12 Hz while this
		# head ticks at 60 fps, so the timer only moved ~1 frame in 5. That
		# made the head accelerate for one frame then decelerate for four,
		# netting almost zero velocity — the "barely spins" bug. Gating on
		# the phase alone lets the head reach full speed while producing.
		var active: bool = is_layered_spinner_producing(anchor)
		var target: float = float(cfg["spin"]) if active else 0.0
		var step: float = float(cfg["accel"]) * delta
		s["vel"] = move_toward(float(s["vel"]), target, step)
		s["angle"] = fposmod(float(s["angle"]) + float(s["vel"]) * delta, TAU)
	for a in to_erase:
		bsys._layered_spinner_state.erase(a)


func is_layered_spinner_producing(anchor: Vector2i) -> bool:
	if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
		return false
	var ss = main.get_node_or_null("SectorScript")
	if ss and ss.has_method("is_building_disabled") and ss.is_building_disabled(anchor):
		return false
	var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if data == null:
		return false
	if data.electrical_power_use > 0:
		var ps = main.get_node_or_null("PowerSystem")
		if ps == null or ps.get_electrical_efficiency(anchor) <= 0.0:
			return false
	var logistics = main.get_node_or_null("LogisticsSystem")
	if logistics and "factory_buffers" in logistics and logistics.factory_buffers.has(anchor):
		var phase: String = String(logistics.factory_buffers[anchor].get("phase", ""))
		return phase == "processing"
	return false


# =========================
# HEAD-SPIN STATE PORTABILITY (crane pickup / drop)
# =========================

## Snapshot whatever spin dicts are tracking `anchor`, erasing the live
## entries. Called by Main when a building is picked up by a crane —
## without this the head would teleport-halt the moment the grabber
## closed (the per-frame tick garbage-collects state for absent anchors).
func capture_spin_state(anchor: Vector2i) -> Dictionary:
	var bsys := _building_sys()
	if bsys == null:
		return {}
	var snap: Dictionary = {}
	if bsys._crusher_head_state.has(anchor):
		snap["crusher"] = (bsys._crusher_head_state[anchor] as Dictionary).duplicate(true)
		bsys._crusher_head_state.erase(anchor)
	if bsys._scraper_head_state.has(anchor):
		snap["scraper"] = (bsys._scraper_head_state[anchor] as Dictionary).duplicate(true)
		bsys._scraper_head_state.erase(anchor)
	if bsys._vent_turbine_state.has(anchor):
		snap["vent_turbine"] = (bsys._vent_turbine_state[anchor] as Dictionary).duplicate(true)
		bsys._vent_turbine_state.erase(anchor)
	if bsys._vent_condenser_state.has(anchor):
		snap["vent_condenser"] = (bsys._vent_condenser_state[anchor] as Dictionary).duplicate(true)
		bsys._vent_condenser_state.erase(anchor)
	if bsys._layered_spinner_state.has(anchor):
		snap["layered_spinner"] = (bsys._layered_spinner_state[anchor] as Dictionary).duplicate(true)
		bsys._layered_spinner_state.erase(anchor)
	return snap


## Re-seat a previously-captured snapshot under (possibly new) anchor.
func restore_spin_state(anchor: Vector2i, snap: Dictionary) -> void:
	var bsys := _building_sys()
	if bsys == null or snap.is_empty():
		return
	if snap.has("crusher"):
		bsys._crusher_head_state[anchor] = (snap["crusher"] as Dictionary).duplicate(true)
	if snap.has("scraper"):
		bsys._scraper_head_state[anchor] = (snap["scraper"] as Dictionary).duplicate(true)
	if snap.has("vent_turbine"):
		bsys._vent_turbine_state[anchor] = (snap["vent_turbine"] as Dictionary).duplicate(true)
	if snap.has("vent_condenser"):
		bsys._vent_condenser_state[anchor] = (snap["vent_condenser"] as Dictionary).duplicate(true)
	if snap.has("layered_spinner"):
		bsys._layered_spinner_state[anchor] = (snap["layered_spinner"] as Dictionary).duplicate(true)


## Called once per frame by the held-payload tick to keep snapshotted
## spin state decaying while detached (target velocity is always 0 —
## the held block is producing nothing).
func tick_held_spin_state(snap: Dictionary, delta: float) -> void:
	if snap.is_empty() or delta <= 0.0:
		return
	for kind in snap.keys():
		var sub: Dictionary = snap[kind]
		if not (sub is Dictionary) or sub.is_empty():
			continue
		var decel: float = float(_SPIN_DECEL.get(kind, 5.0))
		var step: float = decel * delta
		var keys: Array = sub.keys()
		var has_indexed: bool = false
		for k in keys:
			if (k as String).begins_with("angle_"):
				has_indexed = true
				break
		if has_indexed:
			for key in keys:
				if not (key as String).begins_with("angle_"):
					continue
				var idx_str: String = String(key).substr(6)
				var vkey: String = "vel_%s" % idx_str
				sub[vkey] = move_toward(float(sub.get(vkey, 0.0)), 0.0, step)
				sub[key] = fposmod(float(sub[key]) + float(sub[vkey]) * delta, TAU)
		else:
			sub["vel"] = move_toward(float(sub.get("vel", 0.0)), 0.0, step)
			sub["angle"] = fposmod(float(sub.get("angle", 0.0)) + float(sub["vel"]) * delta, TAU)
