extends Node
class_name NuclearReactorSystem

## Per-reactor runtime for the Nuclear Reactor block. Drives:
##   - Fuel rod consumption (1 × mat_uranium_rod + 1 × mat_graphite_rod
##     of each per 12 s cycle while running).
##   - Water coolant draw (30 / sec from the block's fluid buffer).
##   - Coolant alerts and the no-water explosion timer (8 s without water
##     while running → catastrophic explosion).
##   - Active/inactive flag the PowerSystem queries to decide whether the
##     reactor's 500 power-gen is online this tick.
##
## State lives in `reactor_state[anchor]`:
##   active:        bool   true while fuel + water present (or grace timer)
##   cycle_t:       float  seconds into the current 12 s burn cycle
##   no_water_t:    float  seconds since last drop of coolant (resets on
##                         any water present that frame)
##   warned_low:    bool   currently raising the "Low On Coolant" alert
##   warned_dry:    bool   currently raising the "Explosion Imminent" alert
##
## The reactor's input items (mat_uranium_rod, mat_graphite_rod) live in
## the LogisticsSystem's `block_storage[anchor]["items"]` bucket — items
## arrive via conveyor through the standard factory-input pipeline.

const LOW_COOLANT_THRESHOLD := 50.0
const EXPLOSION_NO_WATER_TIME := 8.0
const WATER_DRAW_PER_SEC := 30.0
const CYCLE_LENGTH := 12.0
const FUEL_PER_CYCLE := 2     # consumed at the start of each cycle
const EXPLOSION_RADIUS_INNER := 5
const EXPLOSION_RADIUS_MID := 10
const EXPLOSION_RADIUS_OUTER := 15
const EXPLOSION_DMG_INNER := 600.0
const EXPLOSION_DMG_MID := 400.0
const EXPLOSION_DMG_OUTER := 150.0

@onready var main: Node2D = get_node_or_null("/root/Main")

var reactor_state: Dictionary = {}   # Vector2i anchor → state Dictionary


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func _process(delta: float) -> void:
	if main == null:
		return
	if "world_paused" in main and main.world_paused:
		return
	var logistics = main.get_node_or_null("LogisticsSystem")
	var hud = main.get_node_or_null("HUD")
	if logistics == null:
		return
	# Scan placed reactor anchors. Stale state entries (block destroyed,
	# anchor moved) get pruned when the anchor no longer resolves to a
	# nuclear_reactor block.
	var live: Dictionary = {}
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if live.has(anchor):
			continue
		var data = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null or not data.tags.has("nuclear_reactor"):
			continue
		live[anchor] = true
		_tick_reactor(anchor, data, delta, logistics, hud)
	# Prune state for anchors that no longer host a reactor.
	for anchor in reactor_state.keys():
		if not live.has(anchor):
			_clear_alerts(anchor, hud)
			reactor_state.erase(anchor)


func _tick_reactor(anchor: Vector2i, data: BlockData, delta: float, logistics: Node, hud: Node) -> void:
	if not reactor_state.has(anchor):
		reactor_state[anchor] = {
			"active": false,
			"cycle_t": 0.0,
			"no_water_t": 0.0,
			"warned_low": false,
			"warned_dry": false,
		}
	var st: Dictionary = reactor_state[anchor]
	# Pull stored counts.
	var storage: Dictionary = logistics.block_storage.get(anchor, {})
	var items: Dictionary = storage.get("items", {})
	var fluids: Dictionary = storage.get("fluids", {})
	var u_rods: int = int(items.get(&"mat_uranium_rod", 0))
	var g_rods: int = int(items.get(&"mat_graphite_rod", 0))
	var water: float = float(fluids.get(&"mat_water", 0.0))
	var has_fuel: bool = u_rods >= 1 and g_rods >= 1

	# Becoming active: needs a pair of rods to start a cycle. Once active
	# we keep running through the cycle even if rods are pulled mid-cycle,
	# matching the reactor's "rod is consumed at insertion" pacing.
	if not st["active"]:
		if has_fuel:
			# Consume one of each rod up front; the rest is paced by the
			# 12 s cycle timer.
			items[&"mat_uranium_rod"] = u_rods - 1
			items[&"mat_graphite_rod"] = g_rods - 1
			storage["items"] = items
			logistics.block_storage[anchor] = storage
			st["active"] = true
			st["cycle_t"] = 0.0
			st["no_water_t"] = 0.0
	else:
		st["cycle_t"] += delta
		# Drain water at a fixed rate while running.
		if water > 0.0:
			var drained: float = minf(water, WATER_DRAW_PER_SEC * delta)
			water = maxf(0.0, water - drained)
			fluids[&"mat_water"] = water
			storage["fluids"] = fluids
			logistics.block_storage[anchor] = storage
			st["no_water_t"] = 0.0
		else:
			st["no_water_t"] += delta
			if st["no_water_t"] >= EXPLOSION_NO_WATER_TIME:
				_explode(anchor, data)
				return
		# Cycle complete: try to start a fresh cycle by consuming another
		# pair of rods. If none available, shut down.
		if st["cycle_t"] >= CYCLE_LENGTH:
			if u_rods >= 1 and g_rods >= 1:
				items[&"mat_uranium_rod"] = u_rods - 1
				items[&"mat_graphite_rod"] = g_rods - 1
				storage["items"] = items
				logistics.block_storage[anchor] = storage
				st["cycle_t"] = 0.0
			else:
				st["active"] = false
				st["cycle_t"] = 0.0
	# Player-faction reactors raise HUD alerts. Enemy reactors stay silent
	# so the player isn't pestered by FEROX coolant warnings.
	var faction: int = main.get_building_faction(anchor)
	if faction == main.Faction.LUMINA:
		_update_alerts(anchor, st, water, hud)
	reactor_state[anchor] = st


func _update_alerts(anchor: Vector2i, st: Dictionary, water: float, hud: Node) -> void:
	if hud == null:
		return
	var id_low: StringName = StringName("nuclear_low_%s" % anchor)
	var id_dry: StringName = StringName("nuclear_dry_%s" % anchor)
	if not st["active"]:
		if hud.has_method("clear_alert"):
			hud.clear_alert(id_low)
			hud.clear_alert(id_dry)
		st["warned_low"] = false
		st["warned_dry"] = false
		return
	# Imminent explosion message wins over the low-coolant warning.
	if water <= 0.0:
		if hud.has_method("clear_alert"):
			hud.clear_alert(id_low)
		if hud.has_method("push_alert"):
			hud.push_alert(id_dry, "<Reactor Explosion Imminent>")
		st["warned_dry"] = true
		st["warned_low"] = false
	elif water < LOW_COOLANT_THRESHOLD:
		if hud.has_method("clear_alert"):
			hud.clear_alert(id_dry)
		if hud.has_method("push_alert"):
			hud.push_alert(id_low, "<Reactor Low On Coolant>")
		st["warned_low"] = true
		st["warned_dry"] = false
	else:
		if hud.has_method("clear_alert"):
			hud.clear_alert(id_low)
			hud.clear_alert(id_dry)
		st["warned_low"] = false
		st["warned_dry"] = false


func _clear_alerts(anchor: Vector2i, hud: Node) -> void:
	if hud == null or not hud.has_method("clear_alert"):
		return
	hud.clear_alert(StringName("nuclear_low_%s" % anchor))
	hud.clear_alert(StringName("nuclear_dry_%s" % anchor))


## True while this reactor is in an active fuel cycle — PowerSystem
## queries this to decide whether the reactor's 500 power-gen is online.
func is_reactor_active(anchor: Vector2i) -> bool:
	return reactor_state.has(anchor) and bool(reactor_state[anchor].get("active", false))


## Destructive shutdown: damages everything within the explosion radius,
## emits an alert-style notice, plays the existing feedback shake, and
## removes the reactor itself (treated as 100 % damage to the anchor).
func _explode(anchor: Vector2i, data: BlockData) -> void:
	var gs: float = float(main.GRID_SIZE)
	var center_world: Vector2 = main.grid_to_world(anchor) + Vector2(
		float(data.grid_size.x) * gs * 0.5,
		float(data.grid_size.y) * gs * 0.5)
	# Damage every building within the 15-tile blast radius. Distances
	# are measured tile-to-tile from the reactor's footprint center.
	var damaged_anchors: Dictionary = {}
	for cell in main.placed_buildings.keys():
		var target_anchor: Vector2i = main.building_origins.get(cell, cell)
		if damaged_anchors.has(target_anchor):
			continue
		damaged_anchors[target_anchor] = true
		if target_anchor == anchor:
			continue   # the reactor itself is removed below
		var tdata = Registry.get_block(main.placed_buildings.get(target_anchor, &""))
		if tdata == null:
			continue
		var tcenter: Vector2 = main.grid_to_world(target_anchor) + Vector2(
			float(tdata.grid_size.x) * gs * 0.5,
			float(tdata.grid_size.y) * gs * 0.5)
		var d_tiles: float = center_world.distance_to(tcenter) / gs
		var dmg: float = _falloff_damage(d_tiles)
		if dmg <= 0.0:
			continue
		if main.has_method("damage_building"):
			main.damage_building(target_anchor, dmg)
	# Units of any faction (incl. core drones) in range.
	var unit_mgr = main.get_node_or_null("UnitManager")
	if unit_mgr:
		var all_units: Array = []
		if "enemies" in unit_mgr:
			all_units.append_array(unit_mgr.enemies)
		if "player_units" in unit_mgr:
			all_units.append_array(unit_mgr.player_units)
		for u in all_units:
			if not is_instance_valid(u) or u.is_dead:
				continue
			var d_tiles_u: float = center_world.distance_to(u.position) / gs
			var dmg_u: float = _falloff_damage(d_tiles_u)
			if dmg_u <= 0.0:
				continue
			if u.has_method("take_damage"):
				u.take_damage(dmg_u)
	var drone = main.get_node_or_null("PlayerDrone")
	if drone and is_instance_valid(drone) and "position" in drone:
		var d_tiles_d: float = center_world.distance_to(drone.position) / gs
		var dmg_d: float = _falloff_damage(d_tiles_d)
		if dmg_d > 0.0 and drone.has_method("take_damage"):
			drone.take_damage(dmg_d)
	# Big shake + visible blast effect at the reactor centre + remove
	# the reactor anchor entirely. damage_building call at full HP+1
	# guarantees the reactor's block_destroyed path fires.
	var fb = main.get_node_or_null("FeedbackSystem")
	if fb and fb.has_method("add_shake"):
		fb.add_shake(60.0)
	var expl = main.get_node_or_null("ExplosionSystem")
	if expl and expl.has_method("explode"):
		# Reactor blast: bigger ring than a normal block burst — match
		# the inner damage radius (5 tiles) so the player can see it.
		expl.explode(center_world, 5.0)
	if main.has_method("damage_building"):
		main.damage_building(anchor, data.max_health + 1.0)
	# Clear the reactor's HUD alerts so the panel doesn't keep flashing
	# about an exploded reactor.
	var hud = main.get_node_or_null("HUD")
	_clear_alerts(anchor, hud)


func _falloff_damage(d_tiles: float) -> float:
	if d_tiles <= float(EXPLOSION_RADIUS_INNER):
		return EXPLOSION_DMG_INNER
	if d_tiles <= float(EXPLOSION_RADIUS_MID):
		return EXPLOSION_DMG_MID
	if d_tiles <= float(EXPLOSION_RADIUS_OUTER):
		return EXPLOSION_DMG_OUTER
	return 0.0
