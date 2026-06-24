extends Node2D
class_name ShieldSystem

## Per-block protective shields. Any BlockData with a non-empty
## `shield_shape` ("rect" or "circle") projects a hit-pointed barrier
## around it that can intercept incoming opposing-faction bullets
## (and, when configured `shield_blocks = "units"`, opposing units
## too). Friendly bullets / units always pass through both ways.
##
## Lifecycle:
##   - active   : the shield is up, blocking hits at its boundary
##   - broken   : taking the last hit dropped HP to 0; the visual
##                shrinks to 0.1 tiles and disappears; `cooldown_remaining`
##                ticks down ONLY while the block is fully powered
##   - respawn  : when cooldown hits 0 the shield reappears at 0.1 tiles
##                and quickly grows back to full size, HP restored to max
##
## Power model:
##   - shield_idle_power: drawn every second while the shield is up
##     (configured via the block's normal `electrical_power_use` field
##     and through dynamic power below)
##   - shield_recharge_power: ADDITIONAL draw while broken + recharging
##   - Water buffer in the block's storage drains alongside the
##     cooldown to give a `shield_water_boost_mult` recharge bonus.


# Animation tuning: how fast the visual scale lerps toward its target
# size (in units / second of scale, where 1.0 = full size).
const _SCALE_LERP_RATE := 8.0
# The "broken" minimum visual scale where the shield is considered
# vanished. Matches the player-facing "0.1 of a tile" spec when the
# shield is exactly 1 tile across — we don't try to keep that literal
# for larger shields; it's just a small-enough sliver that the
# polygon stops drawing visibly.
const _VANISH_SCALE := 0.05
# Visual scale we re-spawn the shield at after cooldown finishes,
# before it grows back to 1.0. Same value the player-facing spec
# describes for the "0.1 of a tile" pop-in.
const _RESPAWN_SCALE := 0.05
const _WATER_FLUID_ID := &"mat_water"
const _EDGE_WOBBLE_PERIOD_PX := 48.0
const _EDGE_WOBBLE_AMP_PX := 3.0
const _EDGE_WOBBLE_SPEED := 0.75

# Mindustry-parity "animate shields" toggle. When TRUE, idle shields
# get a moving wave pattern (rotating gradient + slow circumference
# shimmer) instead of the static flat fill. Driven from the Settings
# UI "Shield Animation" toggle, which writes both this field and the
# `shield_animation` setting in settings.json.
@export var animate_shields: bool = true


# Per-anchor state. Public so combat / unit-manager can peek directly:
#   "current_health":     float (live HP, 0..max)
#   "is_broken":          bool
#   "cooldown_remaining": float
#   "visual_scale":       float (0..1, lerps toward target)
#   "target_scale":       float (1.0 when active, 0 when broken)
var states: Dictionary = {}

# Pausable animation clock fed into the merged-shield shader.
var _shader_anim_time: float = 0.0


@onready var main: Node2D = get_node_or_null("/root/Main")


func _unit_manager_ref() -> Node:
	return get_node_or_null("/root/Main/UnitManager")


func _ready() -> void:
	z_index = 60
	z_as_relative = false
	process_mode = Node.PROCESS_MODE_PAUSABLE
	# Apply the Mindustry-style merged-shield shader to this node.
	# It runs once over all merged fill/rim draw calls produced by _draw(),
	# adding animated diagonal stripes to fill pixels only.
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/shield_fill.gdshader")
	material = mat


func _process(delta: float) -> void:
	if main == null:
		return
	var paused: bool = "world_paused" in main and bool(main.world_paused)
	if not paused:
		_shader_anim_time += delta
		if material is ShaderMaterial:
			(material as ShaderMaterial).set_shader_parameter("anim_time", _shader_anim_time)
			(material as ShaderMaterial).set_shader_parameter("animate", animate_shields)
	if paused:
		return
	_tick(delta)
	queue_redraw()


# =========================
# PER-FRAME TICK
# =========================

func _tick(delta: float) -> void:
	var power_sys = main.get_node_or_null("PowerSystem")
	var logistics = main.get_node_or_null("LogisticsSystem")
	# Sweep placed buildings for shield-capable anchors; lazy-init state
	# the first time we see each one. Reusing `building_origins` to
	# skip non-anchor cells of multi-tile blocks.
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if anchor != cell:
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null or data.shield_shape == "":
			continue
		# Skip blocks that aren't actually live yet (under construction,
		# under deconstruction, derelict, etc.). No state entry means
		# no HP bar in the HUD and no intercept of bullets/units. The
		# state gets initialized only once the block is "online".
		if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
			states.erase(anchor)
			continue
		var state: Dictionary = states.get(anchor, {})
		# Power gate. Idle draw is baked into the block's electrical
		# power use; this only watches the live efficiency for tick
		# decisions. While broken AND recharging we also stack the
		# `shield_recharge_power` on top via dynamic power.
		var powered: bool = true
		if power_sys and power_sys.has_method("get_electrical_efficiency"):
			powered = power_sys.get_electrical_efficiency(anchor) > 0.0
		if state.is_empty():
			# First-time init only fires when the block is BOTH built
			# and powered — otherwise we hold off so the shield doesn't
			# "pop into existence" before the player has finished wiring
			# up power. Once initialized the state persists across
			# brownouts (HP carries over) and only the visual / intercept
			# gates respond to power.
			if not powered:
				continue
			state = {
				"current_health": float(data.shield_health),
				"is_broken": false,
				"cooldown_remaining": 0.0,
				"visual_scale": _RESPAWN_SCALE,
				"target_scale": 1.0,
			}
		# Stack the recharge bump while broken — drops when active.
		if power_sys and power_sys.has_method("set_dynamic_power_use"):
			var dyn: float = float(data.shield_recharge_power) if state["is_broken"] else 0.0
			power_sys.set_dynamic_power_use(anchor, dyn)
		# State machine.
		if state["is_broken"]:
			# Cooldown only ticks while powered. Water buffer in
			# block_storage accelerates by `shield_water_boost_mult`
			# and drains at the bonus rate.
			if powered:
				var rate: float = 1.0
				var draining_water: bool = false
				if logistics and "block_storage" in logistics \
						and data.shield_water_boost_mult > 1.0:
					var storage: Dictionary = logistics.block_storage.get(anchor, {})
					var fluids: Dictionary = storage.get("fluids", {})
					var water: float = float(fluids.get(_WATER_FLUID_ID, 0.0))
					if water > 0.0:
						rate = data.shield_water_boost_mult
						draining_water = true
				state["cooldown_remaining"] = maxf(0.0, float(state["cooldown_remaining"]) - delta * rate)
				if draining_water:
					var consumed: float = (rate - 1.0) * delta
					var storage_w: Dictionary = logistics.block_storage[anchor]
					var fluids_w: Dictionary = storage_w.get("fluids", {})
					var avail: float = float(fluids_w.get(_WATER_FLUID_ID, 0.0))
					var left: float = maxf(0.0, avail - consumed)
					if left <= 0.0:
						fluids_w.erase(_WATER_FLUID_ID)
					else:
						fluids_w[_WATER_FLUID_ID] = left
					storage_w["fluids"] = fluids_w
					logistics.block_storage[anchor] = storage_w
				if state["cooldown_remaining"] <= 0.0:
					# Pop the shield back in at a tiny size, then let
					# the lerp grow it.
					state["is_broken"] = false
					state["current_health"] = float(data.shield_health)
					state["visual_scale"] = _RESPAWN_SCALE
					state["target_scale"] = 1.0
			# While broken the visual stays small / hidden.
			state["target_scale"] = 0.0 if state["visual_scale"] <= _VANISH_SCALE else state["target_scale"]
		else:
			# Active. While unpowered the shield COLLAPSES (visual + intercept
			# gates both clamp at < 0.5 scale, so bullets and units stop
			# being blocked) but its stored HP carries through so it
			# re-expands at full strength when power returns.
			state["target_scale"] = 1.0 if powered else 0.0
		# Drive visual scale toward its target. Skip the lerp when the
		# scale is below the vanish threshold AND the target is also
		# 0 so we can fully erase a broken shield's draw.
		var ts: float = float(state["target_scale"])
		var vs: float = float(state["visual_scale"])
		if absf(ts - vs) > 0.001:
			var step: float = _SCALE_LERP_RATE * delta
			if ts > vs:
				vs = minf(ts, vs + step)
			else:
				vs = maxf(ts, vs - step)
			state["visual_scale"] = vs
		states[anchor] = state
	# Garbage-collect state for blocks that no longer exist.
	var dead_anchors: Array = []
	for a in states:
		if not main.placed_buildings.has(a):
			dead_anchors.append(a)
	for a in dead_anchors:
		states.erase(a)


# =========================
# QUERY API — bullets
# =========================

## Walks every active shield and returns the first one that would
## block a bullet travelling along the segment (prev_pos → next_pos)
## fired by `source_faction`. Returns a Dictionary:
##   { anchor, hit_pos }     — caller subtracts damage from the
##                              shield's HP and despawns the bullet.
## Returns an empty Dictionary if nothing intercepts.
func intercept_bullet(prev_pos: Vector2, next_pos: Vector2, source_faction: int) -> Dictionary:
	if states.is_empty():
		return {}
	for anchor in states:
		var state: Dictionary = states[anchor]
		if state.get("is_broken", false):
			continue
		# Only fully-active shields intercept — a respawning shield
		# at < 50% visual scale is too small to count yet.
		if float(state.get("visual_scale", 0.0)) < 0.5:
			continue
		# Ignore friendly shields — a shield only blocks bullets that
		# came from a DIFFERENT faction than the block's owner.
		var owner_faction: int = main.get_building_faction(anchor)
		if owner_faction == source_faction:
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null or data.shield_shape == "":
			continue
		# Test the boundary crossing: we only block bullets crossing
		# INTO the shield (so a friendly turret behind the shield can
		# still fire outward), unless the shield is configured to
		# also stop units (then it's solid both ways for opposing
		# bullets too — no point letting an enemy slip a bullet out).
		var prev_inside: bool = _point_inside(prev_pos, anchor, data, state)
		var next_inside: bool = _point_inside(next_pos, anchor, data, state)
		# Edge crossing = block. Both inside / both outside = pass.
		if prev_inside == next_inside:
			continue
		# Bullet was inside the shield travelling out — let it pass
		# (friendly bullets travelling outward shouldn't be stopped;
		# enemies aren't supposed to be inside in the first place).
		if prev_inside and not next_inside:
			continue
		# next_inside && !prev_inside: incoming hit. Return the
		# approximate boundary point so the caller can draw an impact
		# and despawn the bullet there.
		return {
			"anchor": anchor,
			"hit_pos": _segment_boundary(prev_pos, next_pos, anchor, data, state),
		}
	return {}


## Subtracts `damage` from the shield's HP and breaks it if the pool
## empties. Caller is `combat_system` after `intercept_bullet`
## returned a hit.
func apply_bullet_damage(anchor: Vector2i, damage: float) -> void:
	if not states.has(anchor):
		return
	var state: Dictionary = states[anchor]
	if state.get("is_broken", false):
		return
	var hp: float = float(state.get("current_health", 0.0)) - maxf(damage, 0.0)
	if hp <= 0.0:
		state["current_health"] = 0.0
		state["is_broken"] = true
		state["target_scale"] = 0.0
		var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
		state["cooldown_remaining"] = float(data.shield_cooldown) if data else 10.0
	else:
		state["current_health"] = hp
	states[anchor] = state


# =========================
# HEAL API
# =========================

## Adds `amount` HP back to a shield, clamped at the block's
## `shield_health` max. Skips broken shields (those re-fill on their
## own cooldown timer) and missing / non-shield blocks. Called from
## the player drone's heal beam and from `_tick_menders`.
func heal_shield(anchor: Vector2i, amount: float) -> void:
	if amount <= 0.0:
		return
	if not states.has(anchor):
		return
	var state: Dictionary = states[anchor]
	if state.get("is_broken", false):
		return
	var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if data == null or data.shield_shape == "":
		return
	var max_hp: float = float(data.shield_health)
	var cur: float = float(state.get("current_health", 0.0))
	if cur >= max_hp:
		return
	state["current_health"] = minf(cur + amount, max_hp)
	states[anchor] = state


## True if `anchor` has an active (non-broken) shield whose current
## HP is below max — i.e. it's a valid heal target. Used by the AI
## heal-target picker so the drone autonomously locks onto damaged
## shields the same way it locks onto damaged buildings.
func is_shield_damaged(anchor: Vector2i) -> bool:
	if not states.has(anchor):
		return false
	var state: Dictionary = states[anchor]
	if state.get("is_broken", false):
		return false
	var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if data == null or data.shield_shape == "":
		return false
	return float(state.get("current_health", 0.0)) < float(data.shield_health)


## True if a shield exists at `anchor` (regardless of HP / broken
## state). Lets the heal pipeline notice that a block CAN have a
## shield even when the shield is currently 100 % so it can stop
## issuing futile heal ticks once it's full.
func has_shield(anchor: Vector2i) -> bool:
	return states.has(anchor)


## Returns the point on the shield's VISIBLE boundary closest to
## `from_world`. Used by the heal beam so the laser lands on the
## glowing barrier instead of the block's chassis when the shield is
## what's being mended. Returns `Vector2.ZERO` if the shield is
## broken / missing — callers should fall back to the block perimeter.
func closest_shield_boundary_point(anchor: Vector2i, from_world: Vector2) -> Vector2:
	if not states.has(anchor):
		return Vector2.ZERO
	var state: Dictionary = states[anchor]
	if state.get("is_broken", false):
		return Vector2.ZERO
	var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
	if data == null or data.shield_shape == "":
		return Vector2.ZERO
	var centre: Vector2 = _shield_centre(anchor, data)
	var extent: Vector2 = _shield_extent_px(data, state)
	if extent.x <= 0.0:
		return centre
	if data.shield_shape == "circle":
		# Project `from_world` onto the disc of radius `extent.x` around
		# `centre`. Inside-the-disc cursor gets the same nearest-edge
		# treatment as the block-perimeter helper so the beam endpoint
		# stays on the rim.
		var to: Vector2 = from_world - centre
		var d: float = to.length()
		if d <= 0.0001:
			return centre + Vector2(extent.x, 0.0)
		return centre + to / d * extent.x
	# Rect — work in the block's local frame.
	var ang: float = _block_facing_angle(anchor)
	var local: Vector2 = (from_world - centre).rotated(-ang)
	var half_w: float = extent.x * 0.5
	var half_h: float = extent.y * 0.5
	var clamped := Vector2(
		clampf(local.x, -half_w, half_w),
		clampf(local.y, -half_h, half_h),
	)
	if clamped == local:
		# Inside the rect — push out to the nearest edge.
		var d_left: float = local.x + half_w
		var d_right: float = half_w - local.x
		var d_top: float = local.y + half_h
		var d_bottom: float = half_h - local.y
		var m: float = minf(minf(d_left, d_right), minf(d_top, d_bottom))
		if m == d_left:
			clamped = Vector2(-half_w, local.y)
		elif m == d_right:
			clamped = Vector2(half_w, local.y)
		elif m == d_top:
			clamped = Vector2(local.x, -half_h)
		else:
			clamped = Vector2(local.x, half_h)
	return centre + clamped.rotated(ang)


# =========================
# QUERY API — units
# =========================

## True if `world_pos` is inside ANY active unit-blocking shield whose
## owner faction is hostile to `unit_team`. Lets the unit mover refuse
## a step into a shield, same way it refuses a step onto a wall.
func is_unit_blocked_at(world_pos: Vector2, unit_team: int) -> bool:
	if not states.is_empty():
		for anchor in states:
			var state: Dictionary = states[anchor]
			if state.get("is_broken", false):
				continue
			if float(state.get("visual_scale", 0.0)) < 0.5:
				continue
			var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
			if data == null or data.shield_blocks != "units":
				continue
			# Friend / foe: shields belonging to the unit's own faction
			# never block that unit. Map UnitData.Team → main.Faction via
			# the standard mapping (PLAYER ↔ LUMINA, ENEMY ↔ FEROX).
			var owner_faction: int = main.get_building_faction(anchor)
			var unit_faction: int = main.Faction.LUMINA if unit_team == UnitData.Team.PLAYER else main.Faction.FEROX
			if owner_faction == unit_faction:
				continue
			if _point_inside(world_pos, anchor, data, state):
				return true
	var unit_mgr = _unit_manager_ref()
	if unit_mgr == null:
		return false
	var check_units: Array = unit_mgr.player_units if unit_team == UnitData.Team.ENEMY else unit_mgr.enemies
	for unit in check_units:
		if not is_instance_valid(unit) or unit.is_dead:
			continue
		if not unit.has_method("unit_shield_blocks_units") or not unit.unit_shield_blocks_units():
			continue
		if not unit.has_method("_unit_shield_radius"):
			continue
		var scale: float = float(unit.unit_shield_visual_scale) if "unit_shield_visual_scale" in unit else 1.0
		if scale < 0.5:
			continue
		if unit.position.distance_to(world_pos) <= float(unit._unit_shield_radius()) * scale:
			return true
	return false


# =========================
# GEOMETRY HELPERS
# =========================

## Block rotation in radians. rot 0 = facing +x (right),
## 1 = +y (down), 2 = -x (left), 3 = -y (up). Used to rotate the
## shield's local-space offset / extent into world space so a
## directional shield rides on top of the block's facing.
func _block_facing_angle(anchor: Vector2i) -> float:
	var rot: int = main.building_rotation.get(anchor, 0)
	return float(rot) * PI * 0.5


func _shield_centre(anchor: Vector2i, data: BlockData) -> Vector2:
	var gs: float = float(main.GRID_SIZE)
	var origin: Vector2 = main.grid_to_world(anchor) \
		+ Vector2(data.grid_size.x * gs * 0.5, data.grid_size.y * gs * 0.5)
	# `shield_offset` is in local coords: +x = forward (the direction
	# the block is facing), +y = perpendicular-right. Rotating by the
	# block's facing angle lets the same offset value follow rotation.
	var ang: float = _block_facing_angle(anchor)
	var rotated_offset: Vector2 = data.shield_offset.rotated(ang)
	return origin + rotated_offset * gs


func _shield_extent_px(data: BlockData, state: Dictionary) -> Vector2:
	# `shield_size` is also local-space (x = forward length, y =
	# perpendicular). The hit-test + draw code apply the block's
	# rotation themselves; here we just multiply by visual scale.
	var gs: float = float(main.GRID_SIZE)
	var scale_t: float = clampf(float(state.get("visual_scale", 1.0)), 0.0, 1.0)
	return data.shield_size * gs * scale_t


func _point_inside(p: Vector2, anchor: Vector2i, data: BlockData, state: Dictionary) -> bool:
	var centre: Vector2 = _shield_centre(anchor, data)
	var extent: Vector2 = _shield_extent_px(data, state)
	if extent.x <= 0.0:
		return false
	if data.shield_shape == "circle":
		return p.distance_squared_to(centre) <= extent.x * extent.x
	# rect — rotate the test point INTO the block's local frame so a
	# directional shield (e.g. barrier projector facing down) still
	# tests against an axis-aligned local-space rectangle.
	var ang: float = _block_facing_angle(anchor)
	var local: Vector2 = (p - centre).rotated(-ang)
	var half_w: float = extent.x * 0.5
	var half_h: float = extent.y * 0.5
	return absf(local.x) <= half_w and absf(local.y) <= half_h


## Approximate the boundary-crossing point for a bullet segment. Good
## enough for spawning the impact VFX and reporting back to the
## caller. A binary search would be cleaner but for a single-frame
## segment the lerp midpoint is visually indistinguishable.
func _segment_boundary(prev: Vector2, next: Vector2, anchor: Vector2i, data: BlockData, state: Dictionary) -> Vector2:
	var centre: Vector2 = _shield_centre(anchor, data)
	if data.shield_shape == "circle":
		# Solve |prev + t·(next-prev) - centre|² = r²
		var d: Vector2 = next - prev
		var f: Vector2 = prev - centre
		var r: float = _shield_extent_px(data, state).x
		var a: float = d.dot(d)
		var b: float = 2.0 * f.dot(d)
		var c: float = f.dot(f) - r * r
		var disc: float = b * b - 4.0 * a * c
		if disc < 0.0 or a <= 0.0:
			return next
		var t: float = (-b - sqrt(disc)) / (2.0 * a)
		return prev + d * clampf(t, 0.0, 1.0)
	# Rect: take the midpoint between the inside / outside endpoints —
	# accurate enough at projectile sub-pixel step granularity.
	return prev.lerp(next, 0.5)


# =========================
# DRAW
# =========================

func _draw() -> void:
	var pulse: float = 0.5 + 0.5 * sin(float(Time.get_ticks_msec()) * 0.004)
	const _SHIELD_HUE := Color(1.0, 0.92, 0.25)
	var fill: Color = Color(_SHIELD_HUE.r, _SHIELD_HUE.g, _SHIELD_HUE.b, 0.10 + 0.05 * pulse)
	var rim: Color = Color(_SHIELD_HUE.r, _SHIELD_HUE.g, _SHIELD_HUE.b, 0.55 + 0.10 * pulse)
	var merged_rects: Array = _collect_merged_rect_shields()
	var merged_circles: Array = _collect_merged_circle_shields()
	_draw_merged_shield_fill(merged_rects, merged_circles, fill)
	_draw_merged_circle_shields(merged_circles, merged_rects, fill, rim)
	_draw_merged_rect_shields(merged_rects, merged_circles, fill, rim)


func _collect_merged_circle_shields() -> Array:
	var out: Array = []
	for anchor in states:
		var state: Dictionary = states[anchor]
		var vs: float = float(state.get("visual_scale", 0.0))
		if vs <= _VANISH_SCALE:
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null or data.shield_shape != "circle":
			continue
		out.append({
			"key": anchor,
			"centre": _shield_centre(anchor, data),
			"radius": _shield_extent_px(data, state).x,
			"time_offset": float(anchor.x * 13 + anchor.y * 47) * 0.31,
		})

	out.append_array(_collect_unit_circle_shields())
	return out


func _collect_unit_circle_shields() -> Array:
	var out: Array = []
	var unit_mgr = main.get_node_or_null("UnitManager") if main else null
	if unit_mgr == null:
		return out
	for pool_name in ["player_units", "enemies"]:
		if not (pool_name in unit_mgr):
			continue
		for unit in unit_mgr.get(pool_name):
			if unit == null or not is_instance_valid(unit):
				continue
			if "is_dead" in unit and unit.is_dead:
				continue
			if unit is CanvasItem and not (unit as CanvasItem).visible:
				continue
			if not ("unit_shield_visual_scale" in unit) or not ("unit_shield_max_health" in unit):
				continue
			var scale: float = float(unit.unit_shield_visual_scale)
			if scale <= _VANISH_SCALE or float(unit.unit_shield_max_health) <= 0.0:
				continue
			if not unit.has_method("_unit_shield_radius"):
				continue
			var radius: float = float(unit._unit_shield_radius()) * scale
			if radius <= 0.0:
				continue
			var key: int = unit.get_instance_id()
			out.append({
				"key": key,
				"centre": unit.position,
				"radius": radius,
				"time_offset": float(key % 997) * 0.017,
			})
	return out


func _collect_merged_rect_shields() -> Array:
	var rects: Array = []
	for anchor in states:
		var state: Dictionary = states[anchor]
		var vs: float = float(state.get("visual_scale", 0.0))
		if vs <= _VANISH_SCALE:
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null or data.shield_shape != "rect":
			continue
		var extent: Vector2 = _shield_extent_px(data, state)
		if extent.x <= 0.0 or extent.y <= 0.0:
			continue
		rects.append(_world_rect_for_shield(anchor, data, extent))
	return rects


func _world_rect_for_shield(anchor: Vector2i, data: BlockData, extent: Vector2) -> Rect2:
	var centre: Vector2 = _shield_centre(anchor, data)
	var angle: float = _block_facing_angle(anchor)
	var half: Vector2 = extent * 0.5
	var corners := [
		Vector2(-half.x, -half.y).rotated(angle),
		Vector2(half.x, -half.y).rotated(angle),
		Vector2(half.x, half.y).rotated(angle),
		Vector2(-half.x, half.y).rotated(angle),
	]
	var min_p: Vector2 = centre + corners[0]
	var max_p: Vector2 = min_p
	for i in range(1, corners.size()):
		var p: Vector2 = centre + corners[i]
		min_p.x = minf(min_p.x, p.x)
		min_p.y = minf(min_p.y, p.y)
		max_p.x = maxf(max_p.x, p.x)
		max_p.y = maxf(max_p.y, p.y)
	return Rect2(min_p, max_p - min_p)


func _draw_merged_rect_shields(rects: Array, circles: Array, _fill: Color, rim: Color) -> void:
	if rects.is_empty():
		return
	_draw_merged_rect_rim(rects, circles, rim)


func _draw_merged_shield_fill(rects: Array, circles: Array, fill: Color) -> void:
	if rects.is_empty() and circles.is_empty():
		return
	var min_y := INF
	var max_y := -INF
	for rect in rects:
		var r: Rect2 = rect
		min_y = minf(min_y, r.position.y)
		max_y = maxf(max_y, r.position.y + r.size.y)
	for c in circles:
		var centre: Vector2 = c["centre"]
		var radius: float = float(c["radius"])
		min_y = minf(min_y, centre.y - radius)
		max_y = maxf(max_y, centre.y + radius)
	const STEP := 4.0
	var y: float = floor(min_y / STEP) * STEP
	while y <= max_y:
		var intervals: Array = []
		var sample_y: float = y + STEP * 0.5
		for rect in rects:
			var r: Rect2 = rect
			if sample_y < r.position.y or sample_y > r.position.y + r.size.y:
				continue
			intervals.append(Vector2(r.position.x, r.position.x + r.size.x))
		for c in circles:
			var centre: Vector2 = c["centre"]
			var radius: float = float(c["radius"])
			var dy: float = absf(sample_y - centre.y)
			if dy > radius:
				continue
			var half_width: float = sqrt(maxf(radius * radius - dy * dy, 0.0))
			intervals.append(Vector2(centre.x - half_width, centre.x + half_width))
		_draw_merged_intervals_as_rects(intervals, y, STEP, fill)
		y += STEP


func _draw_merged_rect_fill(rects: Array, fill: Color) -> void:
	var min_y := INF
	var max_y := -INF
	for rect in rects:
		var r: Rect2 = rect
		min_y = minf(min_y, r.position.y)
		max_y = maxf(max_y, r.position.y + r.size.y)
	const STEP := 4.0
	var y: float = floor(min_y / STEP) * STEP
	while y <= max_y:
		var intervals: Array = []
		var sample_y: float = y + STEP * 0.5
		for rect in rects:
			var r: Rect2 = rect
			if sample_y < r.position.y or sample_y > r.position.y + r.size.y:
				continue
			intervals.append(Vector2(r.position.x, r.position.x + r.size.x))
		_draw_merged_intervals_as_rects(intervals, y, STEP, fill)
		y += STEP


func _draw_merged_intervals_as_rects(intervals: Array, y: float, height: float, fill: Color) -> void:
	if intervals.is_empty():
		return
	intervals.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var merged: Array = []
	for interval in intervals:
		if merged.is_empty() or interval.x > (merged[-1] as Vector2).y:
			merged.append(interval)
		else:
			var last: Vector2 = merged[-1]
			last.y = maxf(last.y, interval.y)
			merged[-1] = last
	for interval in merged:
		draw_rect(Rect2(Vector2(interval.x, y), Vector2(interval.y - interval.x, height)), fill, true)


func _draw_merged_rect_rim(rects: Array, circles: Array, rim: Color) -> void:
	const SEGMENT := 6.0
	const PROBE := 1.5
	for idx in range(rects.size()):
		var rect = rects[idx]
		var r: Rect2 = rect
		_draw_exposed_rect_edge(rects, circles, r.position, r.position + Vector2(r.size.x, 0.0), Vector2(0, -PROBE), rim, SEGMENT, idx)
		_draw_exposed_rect_edge(rects, circles, r.position + Vector2(r.size.x, 0.0), r.position + r.size, Vector2(PROBE, 0), rim, SEGMENT, idx)
		_draw_exposed_rect_edge(rects, circles, r.position + r.size, r.position + Vector2(0.0, r.size.y), Vector2(0, PROBE), rim, SEGMENT, idx)
		_draw_exposed_rect_edge(rects, circles, r.position + Vector2(0.0, r.size.y), r.position, Vector2(-PROBE, 0), rim, SEGMENT, idx)


func _draw_exposed_rect_edge(rects: Array, circles: Array, start: Vector2, end: Vector2, outward: Vector2,
		rim: Color, segment_len: float, owner_idx: int) -> void:
	var edge: Vector2 = end - start
	var length: float = edge.length()
	if length <= 0.001:
		return
	var dir: Vector2 = edge / length
	var normal: Vector2 = outward.normalized()
	var run_start := -1.0
	var steps: int = maxi(1, ceili(length / segment_len))
	for i in range(steps):
		var a: float = float(i) / float(steps) * length
		var b: float = float(i + 1) / float(steps) * length
		var mid: Vector2 = start + dir * ((a + b) * 0.5) + outward
		var exposed: bool = not _point_covered_by_rect_or_circle(rects, circles, owner_idx, -1, mid)
		if exposed:
			if run_start < 0.0:
				run_start = a
		elif run_start >= 0.0:
			_draw_wobbled_rect_rim_segment(start, dir, normal, run_start, a, rim)
			run_start = -1.0
	if run_start >= 0.0:
		_draw_wobbled_rect_rim_segment(start, dir, normal, run_start, length, rim)


func _draw_wobbled_rect_rim_segment(start: Vector2, dir: Vector2, normal: Vector2,
		from_dist: float, to_dist: float, rim: Color) -> void:
	var length: float = to_dist - from_dist
	if length <= 0.001:
		return
	var steps: int = maxi(2, ceili(length / 6.0) + 1)
	var points := PackedVector2Array()
	points.resize(steps)
	for i in range(steps):
		var t: float = float(i) / float(steps - 1)
		var d: float = lerpf(from_dist, to_dist, t)
		var base: Vector2 = start + dir * d
		var wobble: float = _edge_wobble_amount(base, normal)
		points[i] = base + normal * wobble
	draw_polyline(points, rim, 5.0, true)


func _point_covered_by_rect_or_circle(rects: Array, circles: Array, owner_rect_idx: int, owner_circle_idx: int, p: Vector2) -> bool:
	return _point_in_other_rect(rects, owner_rect_idx, p) or _point_in_other_circle(circles, owner_circle_idx, p)


func _point_in_other_rect(rects: Array, owner_idx: int, p: Vector2) -> bool:
	const EPS := 0.75
	for idx in range(rects.size()):
		if idx == owner_idx:
			continue
		var rect = rects[idx]
		var r: Rect2 = rect
		if p.x >= r.position.x - EPS and p.x <= r.position.x + r.size.x + EPS \
				and p.y >= r.position.y - EPS and p.y <= r.position.y + r.size.y + EPS:
			return true
	return false


func _point_in_other_circle(circles: Array, owner_idx: int, p: Vector2) -> bool:
	const EPS := 0.75
	for idx in range(circles.size()):
		if idx == owner_idx:
			continue
		var c: Dictionary = circles[idx]
		var radius: float = float(c["radius"]) + EPS
		if p.distance_squared_to(c["centre"]) <= radius * radius:
			return true
	return false



func _draw_merged_circle_shields(circles: Array, rects: Array, _fill: Color, rim: Color) -> void:
	if circles.is_empty():
		return
	var segments: int = _circle_rim_segments(circles)
	for i in range(circles.size()):
		var c: Dictionary = circles[i]
		var centre: Vector2 = c["centre"]
		var radius: float = float(c["radius"])
		var run_start: int = -1
		for s in range(segments + 1):
			var idx: int = s % segments
			var angle: float = float(idx) * TAU / float(segments)
			var outside: Vector2 = centre + Vector2(cos(angle), sin(angle)) * (radius + 1.5)
			var covered := _point_covered_by_rect_or_circle(rects, circles, -1, i, outside)
			if not covered:
				if run_start < 0:
					run_start = s
			elif run_start >= 0:
				var start_angle: float = float(run_start) * TAU / float(segments)
				var end_angle: float = float(s) * TAU / float(segments)
				_draw_wobbled_circle_rim_arc(centre, radius, start_angle, end_angle, max(2, s - run_start), rim)
				run_start = -1
		if run_start >= 0 and run_start < segments:
			_draw_wobbled_circle_rim_arc(centre, radius, float(run_start) * TAU / float(segments), TAU, max(2, segments - run_start), rim)


func _circle_rim_segments(circles: Array) -> int:
	var max_radius: float = 0.0
	for c in circles:
		max_radius = maxf(max_radius, float(c["radius"]))
	# Keep each rim segment short enough that the 5 px stroke does not
	# reveal the polyline facets on large unit shields.
	return clampi(ceili(TAU * max_radius / 4.0), 128, 512)


func _draw_wobbled_circle_rim_arc(centre: Vector2, radius: float,
		start_angle: float, end_angle: float, segment_count: int, rim: Color) -> void:
	var steps: int = maxi(2, segment_count + 1)
	var points := PackedVector2Array()
	points.resize(steps)
	for i in range(steps):
		var t: float = float(i) / float(steps - 1)
		var ang: float = lerpf(start_angle, end_angle, t)
		var normal := Vector2(cos(ang), sin(ang))
		var base: Vector2 = centre + normal * radius
		points[i] = base + normal * _edge_wobble_amount(base, normal)
	draw_polyline(points, rim, 5.0, true)


func _edge_wobble_amount(pos: Vector2, normal: Vector2) -> float:
	if not animate_shields:
		return 0.0
	var wf: float = _EDGE_WOBBLE_PERIOD_PX / TAU
	var t: float = _shader_anim_time * _EDGE_WOBBLE_SPEED
	var wobble_vec := Vector2(
		sin(pos.y / wf + t),
		sin(pos.x / wf + t),
	)
	return wobble_vec.dot(normal) * _EDGE_WOBBLE_AMP_PX


func _draw_merged_circle_fill(circles: Array, rects: Array, fill: Color) -> void:
	var min_y := INF
	var max_y := -INF
	for c in circles:
		var centre: Vector2 = c["centre"]
		var radius: float = float(c["radius"])
		min_y = minf(min_y, centre.y - radius)
		max_y = maxf(max_y, centre.y + radius)
	const STEP := 4.0
	var y: float = floor(min_y / STEP) * STEP
	while y <= max_y:
		var intervals: Array = []
		for c in circles:
			var centre: Vector2 = c["centre"]
			var radius: float = float(c["radius"])
			var dy: float = absf(y - centre.y)
			if dy > radius:
				continue
			var half_width: float = sqrt(maxf(radius * radius - dy * dy, 0.0))
			intervals.append(Vector2(centre.x - half_width, centre.x + half_width))
		intervals = _subtract_rect_fill_intervals(intervals, rects, y)
		_draw_merged_intervals_as_rects(intervals, y - STEP * 0.5, STEP, fill)
		y += STEP


func _subtract_rect_fill_intervals(intervals: Array, rects: Array, sample_y: float) -> Array:
	if intervals.is_empty() or rects.is_empty():
		return intervals
	const OVERLAP_PAD := 3.0
	var blockers: Array = []
	for rect in rects:
		var r: Rect2 = rect
		var top: float = r.position.y + OVERLAP_PAD
		var bottom: float = r.position.y + r.size.y - OVERLAP_PAD
		if bottom <= top or sample_y < top or sample_y > bottom:
			continue
		blockers.append(Vector2(r.position.x + OVERLAP_PAD, r.position.x + r.size.x - OVERLAP_PAD))
	if blockers.is_empty():
		return intervals
	blockers.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var out: Array = []
	for interval in intervals:
		var start: float = (interval as Vector2).x
		var stop: float = (interval as Vector2).y
		for blocker in blockers:
			var b: Vector2 = blocker
			if b.y <= start:
				continue
			if b.x >= stop:
				break
			if b.x > start:
				out.append(Vector2(start, minf(b.x, stop)))
			start = maxf(start, b.y)
			if start >= stop:
				break
		if start < stop:
			out.append(Vector2(start, stop))
	return out


# =========================
# CONVENIENCE
# =========================

## Returns true if any active shield (any faction) overlaps `world_pos`.
## Useful for diagnostics / debug overlays.
func is_any_shield_at(world_pos: Vector2) -> bool:
	for anchor in states:
		var state: Dictionary = states[anchor]
		if state.get("is_broken", false):
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null or data.shield_shape == "":
			continue
		if _point_inside(world_pos, anchor, data, state):
			return true
	return false
