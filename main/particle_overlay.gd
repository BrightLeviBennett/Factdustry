extends Node2D
class_name ParticleOverlay

## Per-block particle emitter. Walks every active placed building each
## frame, looks up a particle profile by tag, and parents one cached
## CPUParticles2D to that anchor's world position. Profiles are
## intentionally simple — one Color + one direction + a short lifetime
## — so a block author can lift the look later without needing to wire
## up a per-block scene.
##
## Sits as a child of BuildingSystem at z_index 51 (above logistics
## items at z=51 by tree order, below cables at 52). Adjust if you
## want particles above belts.
##
## Profiles are by tag; first matching tag wins. Add new entries to
## `_PROFILES` to wire a new visual without touching call sites.

@onready var main: Node2D = get_node_or_null("/root/Main")
@onready var building_sys: Node = get_node_or_null("/root/Main/BuildingSystem")

# anchor → CPUParticles2D
var _emitters: Dictionary = {}

# Tag → profile dict. Profile fields:
#   color, count, lifetime, speed, dir (Vector2 — local, e.g. (0,-1) = up),
#   spread_deg, scale, gravity (Vector2)
const _PROFILES := {
	"drill":          {"color": Color(0.8, 0.7, 0.5, 0.7), "count": 6,  "lifetime": 0.6, "speed": 18.0, "dir": Vector2(0, 1),  "spread_deg": 30.0, "scale": 2.0, "gravity": Vector2(0, 30)},
	"floor_miner":    {"color": Color(0.7, 0.55, 0.4, 0.7), "count": 8,  "lifetime": 0.5, "speed": 12.0, "dir": Vector2(0, 1),  "spread_deg": 60.0, "scale": 2.0, "gravity": Vector2(0, 0)},
	"wall_miner":     {"color": Color(0.6, 0.6, 0.65, 0.7), "count": 5,  "lifetime": 0.5, "speed": 14.0, "dir": Vector2(0, 1),  "spread_deg": 30.0, "scale": 2.0, "gravity": Vector2(0, 25)},
	"smelter":        {"color": Color(0.6, 0.55, 0.5, 0.4), "count": 5,  "lifetime": 1.5, "speed": 12.0, "dir": Vector2(0, -1), "spread_deg": 15.0, "scale": 4.0, "gravity": Vector2(0, -8)},
	"refinery":       {"color": Color(0.7, 0.7, 0.75, 0.5), "count": 4,  "lifetime": 1.2, "speed": 10.0, "dir": Vector2(0, -1), "spread_deg": 20.0, "scale": 4.0, "gravity": Vector2(0, -10)},
	"vent_powered":   {"color": Color(1.0, 1.0, 1.0, 0.4),  "count": 6,  "lifetime": 1.0, "speed": 18.0, "dir": Vector2(0, -1), "spread_deg": 25.0, "scale": 3.0, "gravity": Vector2(0, -15)},
	"fuel_powered":   {"color": Color(0.4, 0.4, 0.45, 0.5), "count": 4,  "lifetime": 1.4, "speed": 14.0, "dir": Vector2(0, -1), "spread_deg": 18.0, "scale": 4.0, "gravity": Vector2(0, -12)},
}

# One-shot burst profiles. These don't run continuously — `spawn_burst`
# creates a temporary CPUParticles2D pre-set to `one_shot = true` so it
# fires one cycle's worth of particles then self-destructs. Used by the
# impact drill's slam moment (ore ejecta puff under the head).
const _BURST_PROFILES := {
	"impact_slam": {
		"color": Color(0.75, 0.6, 0.45, 0.85),
		"count": 22,
		"lifetime": 0.5,
		"speed": 95.0,
		# Ring emission: every particle gets a unique angle so the
		# cloud reads as ejecta radiating evenly around the impact
		# point. `ring_emit = true` flips the spawn path to use
		# random-direction-from-center instead of the dir/spread cone.
		"ring_emit": true,
		"scale": 3.5,
		"gravity": Vector2.ZERO,
		# z_index < placed-building layer (50) so the puff renders
		# beneath the drill — the slam reads as dust kicked out from
		# under the head, not particles popping over the chassis.
		"z_index": 45,
	},
	# Unit-death pop: small orange ring, short.
	"explosion_unit": {
		"color": Color(1.0, 0.65, 0.2, 0.9),
		"count": 28,
		"lifetime": 0.55,
		"speed": 160.0,
		"ring_emit": true,
		"scale": 3.0,
		"gravity": Vector2.ZERO,
		"z_index": 4090,
	},
	# Block-death boom: bigger orange/yellow ring.
	"explosion_block": {
		"color": Color(1.0, 0.7, 0.25, 0.9),
		"count": 48,
		"lifetime": 0.75,
		"speed": 240.0,
		"ring_emit": true,
		"scale": 5.0,
		"gravity": Vector2.ZERO,
		"z_index": 4090,
	},
	# Core-death: huge explosion, slower, longer.
	"explosion_core": {
		"color": Color(1.0, 0.85, 0.35, 0.95),
		"count": 90,
		"lifetime": 1.2,
		"speed": 360.0,
		"ring_emit": true,
		"scale": 7.0,
		"gravity": Vector2.ZERO,
		"z_index": 4090,
	},
	# Incinerator burn-off: a small wisp of gray smoke drifting up off the
	# block when it destroys an item. Narrow upward cone, slight upward
	# gravity so it keeps rising, drawn above the building.
	"incinerate_smoke": {
		"color": Color(0.55, 0.55, 0.58, 0.5),
		"count": 6,
		"lifetime": 0.6,
		"speed": 42.0,
		"dir": Vector2(0, -1),
		"spread_deg": 22.0,
		"scale": 2.4,
		"gravity": Vector2(0, -20.0),
		"z_index": 4090,
	},
}

# --- Ruin decals ---
# Each entry: { "pos": Vector2, "size": Vector2, "tex": Texture2D,
#               "age": float (seconds), "lifetime": float }
var _ruins: Array = []
const _UNIT_RUIN_LIFETIME: float = 4.0
const _BLOCK_RUIN_LIFETIME: float = 6.0
var _unit_ruin_tex: Texture2D = preload("res://textures/UnitRuins.png")
# Two block-ruin variants, picked by destroyed footprint size:
#   - 1×1 / 2×2 blocks → BlockRuins2x2.png (smaller debris)
#   - ≥ 3×3 blocks    → BlockRuins3x3.png (larger debris pattern)
# `spawn_block_ruins` selects between them based on the block's
# `grid_size` at destruction time.
var _block_ruin_tex_small: Texture2D = preload("res://textures/BlockRuins2x2.png")
var _block_ruin_tex_large: Texture2D = preload("res://textures/BlockRuins3x3.png")

# --- BUILD / DECON OUTLINE PULSES ---
# A small one-shot effect that runs each time a block finishes being
# constructed / converted-from-derelict (yellow) or fully decon'd
# (red). The rectangle starts a hair LARGER than the footprint and
# grows further outward over the lifetime while fading to 0. Decon
# pulses also kick out a handful of red-white shrapnel squares that
# fly outward then decelerate and shrink before vanishing.
#
# Each pulse entry: {
#   "world_center": Vector2,
#   "footprint": Vector2 (px),
#   "age": float, "lifetime": float,
#   "color": Color,
# }
var _pulses: Array = []
const _PULSE_LIFETIME: float = 0.55
const _PULSE_GROW_PX: float = 18.0          # how far the outline travels outward
const _PULSE_THICKNESS: float = 3.0

# Each shrapnel: {
#   "pos": Vector2, "vel": Vector2,
#   "size_px": float, "color": Color,
#   "age": float, "lifetime": float,
# }
var _shrapnel: Array = []
const _SHRAPNEL_LIFETIME: float = 0.55
const _SHRAPNEL_INITIAL_SPEED: float = 220.0
const _SHRAPNEL_DRAG: float = 6.5             # exponential drag rate
const _SHRAPNEL_SIZE: float = 14.0
const _SHRAPNEL_COUNT_PER_TILE: int = 3

# --- UNIT DEATH EXPLOSION (Mindustry "dynamicExplosion" style) ---
# A custom drawn burst used when a unit dies — replaces the generic
# CPUParticles2D ring for `explosion_unit`. Faithful to Mindustry's
# Fx.dynamicExplosion: an expanding orange→red→gray stroked ring, two
# scattered rings of ember dots, and a handful of large gray smoke
# puffs that bloom + fade. Cores / nuclear reactors keep using the
# CPUParticles2D `explosion_block` / `explosion_core` profiles so their
# bigger boom still reads as a different beast.
#
# Each entry: { pos: Vector2, age: float, lifetime: float, id: int,
#               scale: float } — `scale` lets bigger units throw bigger
# explosions; defaults to 1.0.
var _unit_explosions: Array = []
const _UNIT_EXPLOSION_LIFETIME: float = 0.6
const _UNIT_EXPLOSION_EMBERS: int = 8       # per ring (two rings)
const _UNIT_EXPLOSION_SMOKE: int = 4
const _UNIT_EXPLOSION_RING_R: float = 18.0  # final stroked ring radius (px)
const _UNIT_EXPLOSION_EMBER_R: float = 38.0
const _UNIT_EXPLOSION_SMOKE_R: float = 7.0  # smoke puff radius
var _unit_explosion_seq: int = 0

# --- FIRE PARTICLES ---
# A reusable directional flame burst. `spawn_fire(world_pos, dir)`
# emits a fan of small circles that fly out, decelerate via drag,
# cycle through yellow → orange → red → dark and shrink to nothing.
# Pass Vector2.ZERO as `dir` for an omnidirectional puff.
#
# Each particle: {
#   "pos": Vector2, "vel": Vector2,
#   "size_px": float, "age": float, "lifetime": float,
# }
var _fire_particles: Array = []
const _FIRE_DEFAULT_LIFETIME: float = 0.55
const _FIRE_DEFAULT_SPEED: float = 180.0
const _FIRE_DEFAULT_SPREAD_DEG: float = 22.0    # cone half-width when dir != 0
const _FIRE_DEFAULT_COUNT: int = 14
const _FIRE_DEFAULT_SIZE: float = 7.0           # base radius in px
const _FIRE_DRAG: float = 4.0                   # exponential drag rate


func _ready() -> void:
	z_index = 51
	z_as_relative = false
	if main and main.has_signal("building_destroyed"):
		main.building_destroyed.connect(_on_building_destroyed)
	# Build completion → yellow outline pulse. Fired only when the build
	# actually finishes (not on initial queue placement) so a deferred
	# build doesn't flash the moment the ghost goes down.
	if main and main.has_signal("building_completed"):
		main.building_completed.connect(_on_building_completed_for_pulse)
	# Ruins + boom only paint when an ENEMY actually killed the block.
	# Player deconstructions / swaps fire `building_destroyed` (so
	# emitters still clean up) but skip the enemy-only signal, so the
	# player doesn't leave debris all over their own factory floor
	# every time they remodel.
	if main and main.has_signal("building_destroyed_by_enemy"):
		main.building_destroyed_by_enemy.connect(_on_building_destroyed_by_enemy)


func _process(_delta: float) -> void:
	# Ruin decals tick independent of `main` / `building_sys` so they
	# keep ticking even if some sub-system is missing. Pruning + redraw
	# both happen inside `_process_ruins`. The delta is passed through so
	# ruin ages pause with `main.world_paused`.
	_process_ruins(_delta)
	if main == null or building_sys == null:
		return
	# Pass 1 — for every placed anchor, ensure an emitter exists if the
	# block matches a profile and is currently doing work.
	var seen: Dictionary = {}
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if seen.has(anchor):
			continue
		seen[anchor] = true
		var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null:
			_release(anchor)
			continue
		var profile: Dictionary = _profile_for(data)
		if profile.is_empty():
			_release(anchor)
			continue
		var active: bool = _is_block_active(anchor, data)
		var em: CPUParticles2D = _emitters.get(anchor, null)
		if em == null:
			em = _make_emitter(profile)
			add_child(em)
			_emitters[anchor] = em
		em.position = main.grid_to_world(anchor) + Vector2(data.grid_size.x * main.GRID_SIZE * 0.5, data.grid_size.y * main.GRID_SIZE * 0.5)
		em.emitting = active
	# Pass 2 — drop emitters whose anchors have vanished (destroyed
	# without firing the signal, edge cases on save/load, etc.).
	var to_clear: Array = []
	for a in _emitters:
		if not main.placed_buildings.has(a):
			to_clear.append(a)
	for a in to_clear:
		_release(a)


func _profile_for(data: BlockData) -> Dictionary:
	# Impact drills don't run a continuous particle stream — their
	# "ejecta" comes from the one-shot slam burst (see spawn_burst).
	# Skip the per-tag scan so the matching `floor_miner` profile
	# doesn't double up with the slam puff.
	if data.tags.has("impact_head"):
		return {}
	for tag in data.tags:
		var key := String(tag)
		if _PROFILES.has(key):
			return _PROFILES[key]
	return {}


## Heuristic for "this block is doing work right now". Drills /
## factories check their factory_buffers phase; vent-powered blocks
## just need to be on a vent (the power network handles the rest);
## fall back to "powered" otherwise.
func _is_block_active(anchor: Vector2i, _data: BlockData) -> bool:
	if main.has_method("is_building_inactive") and main.is_building_inactive(anchor):
		return false
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	if logistics and "factory_buffers" in logistics and logistics.factory_buffers.has(anchor):
		var phase: String = String(logistics.factory_buffers[anchor].get("phase", ""))
		return phase == "processing" or phase == "outputting"
	# Pumps / passive generators: emit while powered.
	var ps = get_node_or_null("/root/Main/PowerSystem")
	if ps and ps.has_method("is_powered_or_battery"):
		return ps.is_powered_or_battery(anchor)
	return true


func _make_emitter(profile: Dictionary) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.amount = int(profile.get("count", 6))
	p.lifetime = float(profile.get("lifetime", 0.6))
	p.one_shot = false
	p.explosiveness = 0.0
	p.preprocess = float(profile.get("lifetime", 0.6)) * 0.5
	var dir: Vector2 = profile.get("dir", Vector2(0, -1))
	p.direction = dir
	p.spread = float(profile.get("spread_deg", 20.0))
	p.gravity = profile.get("gravity", Vector2.ZERO)
	p.initial_velocity_min = float(profile.get("speed", 14.0)) * 0.6
	p.initial_velocity_max = float(profile.get("speed", 14.0))
	p.scale_amount_min = 1.0
	p.scale_amount_max = float(profile.get("scale", 2.0))
	p.color = profile.get("color", Color(1, 1, 1, 0.6))
	p.emitting = false
	return p


func _release(anchor: Vector2i) -> void:
	var em: CPUParticles2D = _emitters.get(anchor, null)
	if em == null:
		return
	em.emitting = false
	em.queue_free()
	_emitters.erase(anchor)


func _on_building_completed_for_pulse(block_id: StringName, anchor: Vector2i) -> void:
	# Use the BlockData footprint so multi-tile builds get a pulse the
	# size of the whole block, not just one cell.
	var data: BlockData = Registry.get_block(block_id) if Registry else null
	if data == null:
		return
	spawn_build_pulse(anchor, data.grid_size)


func _on_building_destroyed(grid_pos: Vector2i) -> void:
	# Anchor or any cell of the building can fire — match either by
	# scanning the emitters dict for the destroyed cell as anchor.
	if _emitters.has(grid_pos):
		_release(grid_pos)


## Only invoked when the building was killed by enemy fire (see
## main.destroy_building's `by_enemy` parameter). Spawns the
## block-ruins decal + (for cores) the core explosion. Player
## deconstructs don't reach this path.
func _on_building_destroyed_by_enemy(grid_pos: Vector2i) -> void:
	if main == null:
		return
	# Pull whatever was at this cell BEFORE the destroy completed —
	# main.gd emits this signal BEFORE clearing placed_buildings, so
	# we can still look up the block to size + tag the explosion.
	var bid: StringName = main.placed_buildings.get(grid_pos, &"")
	var bdata: BlockData = Registry.get_block(bid) if bid != &"" else null
	if bdata == null:
		return
	# Only run the visual for the block's anchor cell — multi-tile
	# blocks fire `building_destroyed_by_enemy` for every cell, and
	# we don't want N copies of the explosion + ruin.
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	if grid_pos != anchor:
		return
	var sz: Vector2i = bdata.grid_size
	var gs: float = float(main.GRID_SIZE)
	# Cores and reactors get the big explosion animation; every other
	# block just leaves a debris decal. Saves the explosion sequence
	# (ring sweep + shockwave + shake) for moments that actually matter.
	var center: Vector2 = main.grid_to_world(anchor) + Vector2(sz.x * gs * 0.5, sz.y * gs * 0.5)
	var is_core: bool = bdata.tags.has("core")
	var is_reactor: bool = bdata.tags.has("reactor") or bdata.id == &"nuclear_reactor"
	if is_core:
		# Cores get Mindustry's dynamicExplosion-style core boom, layered
		# OVER the old ring + shrapnel-spoke burst (which draws underneath).
		var expl_c = main.get_node_or_null("ExplosionSystem")
		if expl_c:
			if expl_c.has_method("explode"):
				expl_c.explode(center, float(maxi(sz.x, sz.y)) * 2.5, 1.7, false)
			if expl_c.has_method("core_explosion"):
				expl_c.core_explosion(center, float(maxi(sz.x, sz.y)))
	elif is_reactor:
		var expl = main.get_node_or_null("ExplosionSystem")
		if expl and expl.has_method("explode"):
			expl.explode(center, -1.0)
	spawn_block_ruins(anchor, sz)


## Spawns a ruin decal for a unit at `world_pos`. Fades over 4 seconds.
func spawn_unit_ruins(world_pos: Vector2, visual_size: float = 16.0) -> void:
	if _unit_ruin_tex == null:
		return
	var w: float = maxf(visual_size, 8.0) * 2.0
	_ruins.append({
		"pos": world_pos,
		"size": Vector2(w, w),
		"tex": _unit_ruin_tex,
		"age": 0.0,
		"lifetime": _UNIT_RUIN_LIFETIME,
	})


## Spawns a ruin decal for a block of `grid_size` at the cell anchor.
## Fades over 6 seconds. The decal is scaled to cover the block's
## footprint exactly.
func spawn_block_ruins(anchor: Vector2i, grid_size: Vector2i) -> void:
	if main == null:
		return
	# Pick the ruin texture by footprint size:
	#   1×1 / 2×2 → small variant, 3×3+ → large variant.
	# Uses the larger dimension so a 1×3 conveyor still reads as a
	# wider piece of debris, and 3×N gets the bigger pattern.
	var big_side: int = maxi(grid_size.x, grid_size.y)
	var tex: Texture2D = _block_ruin_tex_large if big_side >= 3 else _block_ruin_tex_small
	if tex == null:
		return
	var gs: float = float(main.GRID_SIZE)
	var size_px := Vector2(grid_size.x * gs, grid_size.y * gs)
	var top_left: Vector2 = main.grid_to_world(anchor)
	_ruins.append({
		"pos": top_left + size_px * 0.5,
		"size": size_px,
		"tex": tex,
		"age": 0.0,
		"lifetime": _BLOCK_RUIN_LIFETIME,
	})


# --- Ruin tick + draw ---
# Ruins draw via the overlay's own _draw, on its z 51 canvas. They sit
# above terrain but below buildings and units, so a freshly-destroyed
# block leaves a flat smear that the player can walk over.
#
# Ages are accumulated in `_process_ruins(delta)` rather than derived
# from a wallclock — that way the fade freezes the moment
# `main.world_paused` flips on, matching the rest of the world. (Wall-
# clock would keep ticking through the pause and the ruin would jump
# straight to its fade-out tail when unpaused.)
func _process_ruins(delta: float) -> void:
	# Pulses and shrapnel tick on the same delta + pause gate as ruins.
	var paused: bool = main and "world_paused" in main and main.world_paused
	var dirty: bool = false
	if not _ruins.is_empty():
		dirty = true
		if not paused:
			var i: int = _ruins.size() - 1
			while i >= 0:
				var entry: Dictionary = _ruins[i]
				entry["age"] = float(entry.get("age", 0.0)) + delta
				if entry["age"] >= float(entry["lifetime"]):
					_ruins.remove_at(i)
				i -= 1
	if not _pulses.is_empty():
		dirty = true
		if not paused:
			var j: int = _pulses.size() - 1
			while j >= 0:
				var p: Dictionary = _pulses[j]
				p["age"] = float(p.get("age", 0.0)) + delta
				if p["age"] >= float(p["lifetime"]):
					_pulses.remove_at(j)
				j -= 1
	if not _shrapnel.is_empty():
		dirty = true
		if not paused:
			var k: int = _shrapnel.size() - 1
			while k >= 0:
				var s: Dictionary = _shrapnel[k]
				s["age"] = float(s.get("age", 0.0)) + delta
				# Exponential drag — slows velocity smoothly to a near-stop
				# in the final ~30 % of life, then the shrink term takes over.
				var vel: Vector2 = s.get("vel", Vector2.ZERO)
				vel *= exp(-_SHRAPNEL_DRAG * delta)
				s["vel"] = vel
				s["pos"] = (s.get("pos", Vector2.ZERO) as Vector2) + vel * delta
				if s["age"] >= float(s["lifetime"]):
					_shrapnel.remove_at(k)
				k -= 1
	if not _fire_particles.is_empty():
		dirty = true
		if not paused:
			var m: int = _fire_particles.size() - 1
			while m >= 0:
				var f: Dictionary = _fire_particles[m]
				f["age"] = float(f.get("age", 0.0)) + delta
				var fvel: Vector2 = f.get("vel", Vector2.ZERO)
				fvel *= exp(-_FIRE_DRAG * delta)
				f["vel"] = fvel
				f["pos"] = (f.get("pos", Vector2.ZERO) as Vector2) + fvel * delta
				if f["age"] >= float(f["lifetime"]):
					_fire_particles.remove_at(m)
				m -= 1
	if not _unit_explosions.is_empty():
		dirty = true
		if not paused:
			var n: int = _unit_explosions.size() - 1
			while n >= 0:
				var e: Dictionary = _unit_explosions[n]
				e["age"] = float(e.get("age", 0.0)) + delta
				if e["age"] >= float(e["lifetime"]):
					_unit_explosions.remove_at(n)
				n -= 1
	if dirty:
		queue_redraw()


# =========================
# BUILD / DECON PULSES
# =========================

## Spawns the yellow "block just constructed" outline. Called from the
## build-completion path (and from the derelict→LUMINA conversion in
## main.gd) so a freshly-owned block gets a brief expanding rectangle.
func spawn_build_pulse(anchor: Vector2i, grid_size: Vector2i) -> void:
	_push_pulse(anchor, grid_size, Color(1.0, 0.85, 0.2, 1.0))


## Spawns the red "block just decon'd" outline + shrapnel shower.
## Shrapnel count scales with the building's footprint so a 3×3 core
## throws roughly nine times the debris of a 1×1 belt.
func spawn_decon_pulse(anchor: Vector2i, grid_size: Vector2i) -> void:
	_push_pulse(anchor, grid_size, Color(1.0, 0.35, 0.25, 1.0))
	_spawn_shrapnel(anchor, grid_size)


func _push_pulse(anchor: Vector2i, grid_size: Vector2i, color: Color) -> void:
	if main == null:
		return
	var gs: float = float(main.GRID_SIZE)
	var size_px: Vector2 = Vector2(grid_size.x * gs, grid_size.y * gs)
	var top_left: Vector2 = main.grid_to_world(anchor)
	_pulses.append({
		"world_center": top_left + size_px * 0.5,
		"footprint": size_px,
		"age": 0.0,
		"lifetime": _PULSE_LIFETIME,
		"color": color,
	})


## Public — emit a fire-effect burst at `world_pos`. Direction is
## optional: pass `Vector2.ZERO` (or omit) for an omnidirectional puff,
## or a non-zero vector for a directional fan biased that way.
##
## Tunables let any caller scale the effect — a flamethrower turret
## might call this every frame with `count = 3, speed = 240`; a
## demolition burst could fire once with `count = 40, speed = 320`.
## Particles cycle hot-yellow → orange → deep-red → dark and fade
## to zero as they decelerate (`_FIRE_DRAG`).
func spawn_fire(
	world_pos: Vector2,
	direction: Vector2 = Vector2.ZERO,
	count: int = _FIRE_DEFAULT_COUNT,
	speed: float = _FIRE_DEFAULT_SPEED,
	lifetime: float = _FIRE_DEFAULT_LIFETIME,
	base_size: float = _FIRE_DEFAULT_SIZE,
	spread_deg: float = _FIRE_DEFAULT_SPREAD_DEG,
) -> void:
	var directional: bool = direction.length_squared() > 0.0001
	var base_angle: float = direction.angle() if directional else 0.0
	var spread_rad: float = deg_to_rad(spread_deg)
	for i in range(count):
		var angle: float
		if directional:
			angle = base_angle + lerp(-spread_rad, spread_rad, randf())
		else:
			# Full ring — every particle gets a uniform random angle.
			angle = randf() * TAU
		# Per-particle speed jitter so the fan doesn't read as a
		# mathematically perfect cone. Bias the slower particles back
		# toward the source so they tail behind the front of the fan.
		var speed_jitter: float = lerpf(0.55, 1.15, randf())
		var vel: Vector2 = Vector2(cos(angle), sin(angle)) * speed * speed_jitter
		# Small spawn-position jitter so a stream of calls doesn't
		# stack into one pixel column.
		var off: Vector2 = Vector2(randf() - 0.5, randf() - 0.5) * base_size * 0.6
		_fire_particles.append({
			"pos": world_pos + off,
			"vel": vel,
			"size_px": base_size * lerpf(0.7, 1.3, randf()),
			"age": 0.0,
			"lifetime": lifetime * lerpf(0.8, 1.15, randf()),
		})


func _spawn_shrapnel(anchor: Vector2i, grid_size: Vector2i) -> void:
	if main == null:
		return
	var gs: float = float(main.GRID_SIZE)
	var size_px: Vector2 = Vector2(grid_size.x * gs, grid_size.y * gs)
	var top_left: Vector2 = main.grid_to_world(anchor)
	var center: Vector2 = top_left + size_px * 0.5
	# Footprint area in tiles → number of shrapnel pieces.
	var n_pieces: int = clampi(int(grid_size.x * grid_size.y) * _SHRAPNEL_COUNT_PER_TILE, 3, 24)
	for i in range(n_pieces):
		var angle: float = randf() * TAU
		var speed: float = lerpf(_SHRAPNEL_INITIAL_SPEED * 0.6, _SHRAPNEL_INITIAL_SPEED, randf())
		var dir: Vector2 = Vector2(cos(angle), sin(angle))
		# Mix red ↔ white per piece so the shower has visual variance.
		var col_mix: float = randf()
		var col: Color = Color(1.0, lerpf(0.4, 0.85, col_mix), lerpf(0.35, 0.8, col_mix), 1.0)
		_shrapnel.append({
			"pos": center,
			"vel": dir * speed,
			"size_px": _SHRAPNEL_SIZE * (0.7 + randf() * 0.6),
			"color": col,
			"age": 0.0,
			"lifetime": _SHRAPNEL_LIFETIME,
		})


func _draw() -> void:
	for entry in _ruins:
		var lifetime: float = float(entry["lifetime"])
		var age: float = float(entry.get("age", 0.0))
		var t: float = clampf(age / lifetime, 0.0, 1.0)
		# Hold full opacity for ~30 % of the lifetime, then fade linearly
		# to 0. Reads as "this is debris that's slowly getting kicked
		# away" instead of "this is a constantly-fading thing".
		var alpha: float = 1.0 if t < 0.3 else lerpf(1.0, 0.0, (t - 0.3) / 0.7)
		var size: Vector2 = entry["size"]
		var rect := Rect2(entry["pos"] - size * 0.5, size)
		draw_texture_rect(entry["tex"], rect, false, Color(1, 1, 1, alpha))

	# Build / decon outline pulses — rectangle expands outward from the
	# block footprint, alpha fades to 0 over `_PULSE_LIFETIME`.
	for p in _pulses:
		var p_life: float = float(p["lifetime"])
		var p_age: float = float(p.get("age", 0.0))
		var t: float = clampf(p_age / p_life, 0.0, 1.0)
		# Ease-out so the outline shoots out quickly then slows down.
		var grow_t: float = 1.0 - pow(1.0 - t, 2.0)
		var center: Vector2 = p["world_center"]
		var foot: Vector2 = p["footprint"]
		var inflate: float = _PULSE_GROW_PX * grow_t
		var inflated: Vector2 = foot + Vector2(inflate, inflate) * 2.0
		var rect: Rect2 = Rect2(center - inflated * 0.5, inflated)
		var col: Color = p["color"]
		# Fade out alpha after a brief full-strength hold.
		var alpha: float = (1.0 - t) if t > 0.0 else 1.0
		col.a *= alpha
		draw_rect(rect, col, false, _PULSE_THICKNESS)

	# Fire particles — small circles whose color cycles hot-yellow →
	# orange → red → dark, with a glow halo behind each. Caller emits
	# them via `spawn_fire(world_pos, dir, ...)`; the per-particle tick
	# already integrated position + drag, so we just paint at `pos`.
	for f in _fire_particles:
		var f_life: float = float(f["lifetime"])
		var f_age: float = float(f.get("age", 0.0))
		var ft: float = clampf(f_age / f_life, 0.0, 1.0)
		# Colour cycle: start pale-yellow, push toward saturated orange
		# in the middle, end deep red turning to dark / smoke.
		var col: Color
		if ft < 0.25:
			col = Color(1.0, 0.95, 0.45, 1.0).lerp(
				Color(1.0, 0.65, 0.18, 1.0), ft / 0.25)
		elif ft < 0.7:
			col = Color(1.0, 0.65, 0.18, 1.0).lerp(
				Color(0.85, 0.25, 0.08, 1.0), (ft - 0.25) / 0.45)
		else:
			col = Color(0.85, 0.25, 0.08, 1.0).lerp(
				Color(0.25, 0.1, 0.08, 0.0), (ft - 0.7) / 0.3)
		var base_size_p: float = float(f["size_px"])
		# Slight shrink over life so the dying particles read as smoke
		# wisps. Multiply by 1.05 early so they bloom briefly before
		# settling.
		var size_t: float
		if ft < 0.2:
			size_t = lerpf(0.75, 1.05, ft / 0.2)
		else:
			size_t = lerpf(1.05, 0.45, (ft - 0.2) / 0.8)
		var radius: float = base_size_p * size_t
		if radius < 0.5:
			continue
		var pos: Vector2 = f["pos"]
		# Soft outer glow + sharper inner core: two circles per
		# particle. Inner is brighter / slightly smaller.
		var outer_col: Color = Color(col.r, col.g, col.b, col.a * 0.5)
		var inner_col: Color = Color(col.r * 1.0, col.g * 1.0, col.b * 1.0, col.a)
		draw_circle(pos, radius * 1.6, outer_col)
		draw_circle(pos, radius * 0.75, inner_col)

	# Mindustry-style unit-death dynamic explosion. Each entry produces:
	#   (a) an expanding stroked ring that shifts orange → red → gray
	#   (b) two scattered rings of small ember dots
	#   (c) a few large gray smoke puffs that bloom + fade
	for e in _unit_explosions:
		var e_life: float = float(e["lifetime"])
		var e_age: float = float(e.get("age", 0.0))
		var t: float = clampf(e_age / e_life, 0.0, 1.0)
		var fin: float = t                                # 0 → 1 (grow)
		var fout: float = 1.0 - t                         # 1 → 0 (fade)
		var finpow: float = fin * fin                     # ease-out-ish
		var center: Vector2 = e["pos"]
		var scl: float = float(e.get("scale", 1.0))
		var id: int = int(e.get("id", 0))

		# Colour cycle — Mindustry: lighterOrange → lightOrange → gray.
		var ring_col: Color
		if t < 0.5:
			ring_col = Color(1.0, 0.85, 0.45, 1.0).lerp(
				Color(1.0, 0.55, 0.18, 1.0), t / 0.5)
		else:
			ring_col = Color(1.0, 0.55, 0.18, 1.0).lerp(
				Color(0.55, 0.55, 0.55, 1.0), (t - 0.5) / 0.5)

		# (a) Shockwave ring — radius grows from 0 to RING_R, stroke
		# fades from full to 0. (`Lines.circle` + `stroke(fout * 2f)`.)
		var ring_r: float = fin * _UNIT_EXPLOSION_RING_R * scl
		if ring_r > 0.5 and fout > 0.02:
			draw_arc(
				center,
				ring_r,
				0.0,
				TAU,
				24,
				Color(ring_col.r, ring_col.g, ring_col.b, fout),
				maxf(1.0, fout * 2.5),
				true,
			)

		# (b) Two rings of ember dots. Position = randLenVectors(id, 8,
		# 2 + 30 * finpow). Mindustry seeds via the effect id; we use a
		# stable per-explosion id with sin/cos hashing for a similar
		# spread without an RNG.
		var emb_max: float = _UNIT_EXPLOSION_EMBER_R * scl
		var emb_len: float = 2.0 + finpow * emb_max
		for ring_i in range(2):
			var seed_off: int = id * 37 + ring_i * 1009
			for k in range(_UNIT_EXPLOSION_EMBERS):
				# Deterministic pseudo-random angle + length jitter.
				var h: float = float(seed_off + k * 73)
				var ang: float = wrapf(sin(h * 12.9898) * 43758.5453, 0.0, TAU)
				var len_jit: float = 0.55 + 0.45 * absf(sin(h * 78.233 + 2.0))
				var off := Vector2(cos(ang), sin(ang)) * (emb_len * len_jit)
				var emb_r: float = fout * 1.5 * scl + 0.6
				if emb_r < 0.4:
					continue
				draw_circle(
					center + off,
					emb_r,
					Color(ring_col.r, ring_col.g, ring_col.b, fout),
				)

		# (c) Large gray smoke puffs — 4 of them at random short
		# offsets, big radius that shrinks with fout.
		for s_i in range(_UNIT_EXPLOSION_SMOKE):
			var sh: float = float(id * 53 + s_i * 211)
			var s_ang: float = wrapf(sin(sh * 12.9898) * 43758.5453, 0.0, TAU)
			var s_dist: float = (0.2 + 0.8 * absf(sin(sh * 4.1))) * fout * 12.0 * scl
			var s_off := Vector2(cos(s_ang), sin(s_ang)) * s_dist
			var s_r: float = fout * _UNIT_EXPLOSION_SMOKE_R * scl * (1.0 - float(s_i) / float(_UNIT_EXPLOSION_SMOKE))
			if s_r < 0.5:
				continue
			draw_circle(
				center + s_off,
				s_r,
				Color(0.55, 0.55, 0.55, 0.85 * fout),
			)

	# Decon shrapnel — solid red-white squares flying out, decelerating,
	# then shrinking to nothing in the tail of their life.
	for s in _shrapnel:
		var s_life: float = float(s["lifetime"])
		var s_age: float = float(s.get("age", 0.0))
		var st: float = clampf(s_age / s_life, 0.0, 1.0)
		var size_px: float = float(s["size_px"])
		# Hold full size for the first ~70 %, then rapidly shrink + fade.
		var shrink: float = 1.0 if st < 0.7 else lerpf(1.0, 0.0, (st - 0.7) / 0.3)
		var cur_sz: float = size_px * shrink
		if cur_sz < 0.5:
			continue
		var s_col: Color = s["color"]
		s_col.a *= shrink
		var pos: Vector2 = s["pos"]
		var srect: Rect2 = Rect2(pos - Vector2(cur_sz, cur_sz) * 0.5, Vector2(cur_sz, cur_sz))
		draw_rect(srect, s_col, true)


## Public: fire a one-shot particle burst at a world position.
## `kind` selects a profile from `_BURST_PROFILES`. The emitter is a
## throw-away CPUParticles2D set to one_shot mode; it deletes itself
## once its lifetime is up. Use for impact-style "boom" effects that
## a continuous emitter can't represent cleanly.
func spawn_burst(world_pos: Vector2, kind: String) -> void:
	# Unit-death explosions use the custom Mindustry "dynamicExplosion"
	# drawer instead of CPUParticles2D — keeps cores / reactors on the
	# big particle ring while letting unit deaths read as the
	# stroked-shockwave + ember + smoke combo from Mindustry.
	if kind == "explosion_unit":
		_unit_explosion_seq += 1
		_unit_explosions.append({
			"pos": world_pos,
			"age": 0.0,
			"lifetime": _UNIT_EXPLOSION_LIFETIME,
			"id": _unit_explosion_seq,
			"scale": 1.0,
		})
		queue_redraw()
		return
	var profile: Dictionary = _BURST_PROFILES.get(kind, {})
	if profile.is_empty():
		return
	var p := CPUParticles2D.new()
	p.amount = int(profile.get("count", 12))
	p.lifetime = float(profile.get("lifetime", 0.5))
	p.one_shot = true
	p.explosiveness = 1.0
	# Ring-style emission: full 360° spread with `dir` = (0,-1)
	# arbitrary (every angle is equally likely because spread = 180).
	# Standard cone path keeps the profile's `dir` / `spread_deg`.
	if bool(profile.get("ring_emit", false)):
		p.direction = Vector2(0, -1)
		p.spread = 180.0
	else:
		p.direction = profile.get("dir", Vector2(0, -1))
		p.spread = float(profile.get("spread_deg", 60.0))
	p.gravity = profile.get("gravity", Vector2.ZERO)
	p.initial_velocity_min = float(profile.get("speed", 60.0)) * 0.5
	p.initial_velocity_max = float(profile.get("speed", 60.0))
	p.scale_amount_min = 1.0
	p.scale_amount_max = float(profile.get("scale", 2.0))
	p.color = profile.get("color", Color(1, 1, 1, 0.8))
	p.position = world_pos
	p.emitting = true
	# Per-burst z override (e.g. impact_slam draws UNDER buildings).
	if profile.has("z_index"):
		p.z_index = int(profile["z_index"])
		p.z_as_relative = false
	add_child(p)
	# Self-clean: lifetime + small safety pad covers the longest particle.
	var t := get_tree().create_timer(float(profile.get("lifetime", 0.5)) + 0.2)
	t.timeout.connect(p.queue_free)
