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
}

# --- Ruin decals ---
# Each entry: { "pos": Vector2, "size": Vector2, "tex": Texture2D,
#               "born": float (seconds), "lifetime": float }
var _ruins: Array = []
const _UNIT_RUIN_LIFETIME: float = 4.0
const _BLOCK_RUIN_LIFETIME: float = 6.0
var _unit_ruin_tex: Texture2D = preload("res://textures/UnitRuins.png")
var _block_ruin_tex: Texture2D = preload("res://textures/BlockRuins.png")


func _ready() -> void:
	z_index = 51
	z_as_relative = false
	if main and main.has_signal("building_destroyed"):
		main.building_destroyed.connect(_on_building_destroyed)
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
	# both happen inside `_process_ruins`.
	_process_ruins()
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
func _is_block_active(anchor: Vector2i, data: BlockData) -> bool:
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
	# Cores get a bigger ring burst from ExplosionSystem; regular blocks
	# get a small one. Both leave a debris decal afterward.
	var center: Vector2 = main.grid_to_world(anchor) + Vector2(sz.x * gs * 0.5, sz.y * gs * 0.5)
	var expl = main.get_node_or_null("ExplosionSystem")
	if expl and expl.has_method("explode"):
		var ring_tiles: float = -1.0   # use the system's default 3.5 ± variance
		if bdata.tags.has("core"):
			ring_tiles = 6.0   # cores get a bigger burst
		expl.explode(center, ring_tiles)
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
		"born": Time.get_ticks_msec() / 1000.0,
		"lifetime": _UNIT_RUIN_LIFETIME,
	})


## Spawns a ruin decal for a block of `grid_size` at the cell anchor.
## Fades over 6 seconds. The decal is scaled to cover the block's
## footprint exactly.
func spawn_block_ruins(anchor: Vector2i, grid_size: Vector2i) -> void:
	if _block_ruin_tex == null:
		return
	if main == null:
		return
	var gs: float = float(main.GRID_SIZE)
	var size_px := Vector2(grid_size.x * gs, grid_size.y * gs)
	var top_left: Vector2 = main.grid_to_world(anchor)
	_ruins.append({
		"pos": top_left + size_px * 0.5,
		"size": size_px,
		"tex": _block_ruin_tex,
		"born": Time.get_ticks_msec() / 1000.0,
		"lifetime": _BLOCK_RUIN_LIFETIME,
	})


# --- Ruin tick + draw ---
# Ruins draw via the overlay's own _draw, on its z 51 canvas. They sit
# above terrain but below buildings and units, so a freshly-destroyed
# block leaves a flat smear that the player can walk over.
func _process_ruins() -> void:
	if _ruins.is_empty():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var i: int = _ruins.size() - 1
	while i >= 0:
		var entry: Dictionary = _ruins[i]
		if now - float(entry["born"]) >= float(entry["lifetime"]):
			_ruins.remove_at(i)
		i -= 1
	queue_redraw()


func _draw() -> void:
	if _ruins.is_empty():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	for entry in _ruins:
		var lifetime: float = float(entry["lifetime"])
		var age: float = now - float(entry["born"])
		var t: float = clampf(age / lifetime, 0.0, 1.0)
		# Hold full opacity for ~30 % of the lifetime, then fade linearly
		# to 0. Reads as "this is debris that's slowly getting kicked
		# away" instead of "this is a constantly-fading thing".
		var alpha: float = 1.0 if t < 0.3 else lerpf(1.0, 0.0, (t - 0.3) / 0.7)
		var size: Vector2 = entry["size"]
		var rect := Rect2(entry["pos"] - size * 0.5, size)
		draw_texture_rect(entry["tex"], rect, false, Color(1, 1, 1, alpha))


## Public: fire a one-shot particle burst at a world position.
## `kind` selects a profile from `_BURST_PROFILES`. The emitter is a
## throw-away CPUParticles2D set to one_shot mode; it deletes itself
## once its lifetime is up. Use for impact-style "boom" effects that
## a continuous emitter can't represent cleanly.
func spawn_burst(world_pos: Vector2, kind: String) -> void:
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
