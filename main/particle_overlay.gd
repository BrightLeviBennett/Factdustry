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


func _ready() -> void:
	z_index = 51
	z_as_relative = false
	if main and main.has_signal("building_destroyed"):
		main.building_destroyed.connect(_on_building_destroyed)


func _process(_delta: float) -> void:
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
