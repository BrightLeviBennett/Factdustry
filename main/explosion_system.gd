extends Node2D
class_name ExplosionSystem

## In-world overlay for the new "shrapnel-burst" explosion effect — used
## by the Nuclear Reactor blast and any other code that wants a chunky,
## non-particle visual. The effect consists of:
##   - A thick yellow RING expanding from the origin to ~3.5 tiles
##     (with per-explosion variation), fading out as it grows.
##   - 16-24 thick STRAIGHT spokes radiating from the origin. Each spoke
##     has a random end length, random colour (black / orange / yellow),
##     and a two-phase life:
##       Phase 1 (0 → 0.5): TIP advances from center to the target end.
##       Phase 2 (0.5 → 1.0): BACK catches up to the same point, so the
##         line visually collapses into a point — reads like a piece of
##         shrapnel flying outward and disappearing.
##
## Public API:
##   explode(world_pos: Vector2, ring_tiles_override := -1.0) -> void
## Call once per blast. The animation auto-expires after EFFECT_LIFE.

const EFFECT_LIFE := 0.8
const RING_RADIUS_TILES := 3.5         # baseline; variation added per call
const RING_RADIUS_VARIANCE := 0.6
const RING_THICKNESS := 6.0
const LINE_MIN_COUNT := 16
const LINE_MAX_COUNT := 24
const LINE_THICKNESS := 4.0
const LINE_MIN_LEN_TILES := 1.5
const LINE_MAX_LEN_TILES := 4.5
const PHASE1_FRACTION := 0.5           # split between "extend" and "shrapnel-collapse"

@onready var main: Node2D = get_node_or_null("/root/Main")

# Each entry:
#   pos:           Vector2  origin in world space
#   age:           float    seconds since spawn
#   ring_radius:   float    final ring radius in pixels
#   spokes:        Array of { angle, len, color }
var _bursts: Array = []


func _ready() -> void:
	z_index = 4100
	z_as_relative = false
	process_mode = Node.PROCESS_MODE_PAUSABLE


func explode(world_pos: Vector2, ring_tiles_override: float = -1.0) -> void:
	var gs: float = float(main.GRID_SIZE) if main else 16.0
	var ring_tiles: float = ring_tiles_override
	if ring_tiles <= 0.0:
		ring_tiles = RING_RADIUS_TILES + randf_range(-RING_RADIUS_VARIANCE, RING_RADIUS_VARIANCE)
	var spoke_count: int = randi_range(LINE_MIN_COUNT, LINE_MAX_COUNT)
	var spokes: Array = []
	for i in range(spoke_count):
		var angle: float = randf() * TAU
		var len_tiles: float = randf_range(LINE_MIN_LEN_TILES, LINE_MAX_LEN_TILES)
		var palette := [Color.BLACK, Color(1.0, 0.5, 0.1), Color(1.0, 0.9, 0.2)]
		spokes.append({
			"angle": angle,
			"len": len_tiles * gs,
			"color": palette[randi() % palette.size()],
		})
	_bursts.append({
		"pos": world_pos,
		"age": 0.0,
		"ring_radius": ring_tiles * gs,
		"spokes": spokes,
	})
	queue_redraw()


func _process(delta: float) -> void:
	if _bursts.is_empty():
		return
	for i in range(_bursts.size() - 1, -1, -1):
		_bursts[i]["age"] += delta
		if _bursts[i]["age"] >= EFFECT_LIFE:
			_bursts.remove_at(i)
	queue_redraw()


func _draw() -> void:
	for b in _bursts:
		var t: float = clampf(float(b["age"]) / EFFECT_LIFE, 0.0, 1.0)
		var origin: Vector2 = b["pos"]
		# --- Yellow ring ---
		var ring_r: float = float(b["ring_radius"]) * ease(t, 1.6)
		var ring_alpha: float = lerpf(1.0, 0.0, t)
		if ring_r > 1.0:
			draw_arc(origin, ring_r, 0.0, TAU, 48,
				Color(1.0, 0.92, 0.2, ring_alpha), RING_THICKNESS, true)
			# Faint outer glow so the ring reads thick at lower zoom.
			draw_arc(origin, ring_r + RING_THICKNESS * 0.5, 0.0, TAU, 48,
				Color(1.0, 0.7, 0.1, ring_alpha * 0.35), RING_THICKNESS * 0.75, true)
		# --- Spokes ---
		# Phase 1: tip travels from origin → target endpoint.
		# Phase 2: back catches up to that endpoint, line collapses.
		var phase: float = t / PHASE1_FRACTION if t < PHASE1_FRACTION \
			else (t - PHASE1_FRACTION) / (1.0 - PHASE1_FRACTION)
		var in_phase1: bool = t < PHASE1_FRACTION
		var alpha: float = lerpf(1.0, 0.2, t) if in_phase1 else lerpf(0.85, 0.0, phase)
		for s in b["spokes"]:
			var dir: Vector2 = Vector2.from_angle(float(s["angle"]))
			var max_len: float = float(s["len"])
			var tip_t: float = 1.0 if not in_phase1 else ease(phase, 1.3)
			var back_t: float = 0.0 if in_phase1 else ease(phase, 1.3)
			var tip: Vector2 = origin + dir * (max_len * tip_t)
			var back: Vector2 = origin + dir * (max_len * back_t)
			var col: Color = s["color"]
			col.a = alpha
			draw_line(back, tip, col, LINE_THICKNESS, true)
