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
const RING_THICKNESS := 12.0
const LINE_MIN_COUNT := 16
const LINE_MAX_COUNT := 24
const LINE_THICKNESS := 9.0
const LINE_MIN_LEN_TILES := 1.5
const LINE_MAX_LEN_TILES := 4.5
const PHASE1_FRACTION := 0.5           # split between "extend" and "shrapnel-collapse"

# --- Mindustry Fx.dynamicExplosion port (unit deaths) ------------------
# Faithful reproduction of Anuken/Mindustry's `Fx.dynamicExplosion`
# (content/Fx.java), driven by `Damage.dynamicExplosion`, which calls
# `explosionFx.at(x, y, radius/8f)` — so the effect's `intensity` is
# `radius / 8`, where `radius ≈ hitSize / 2` (i.e. the dying unit's
# radius). Every sub-effect's size is a fixed MULTIPLE of that radius
# (smoke reaches 1.75×r, the ring ~2.1×r, sparks 5×r), so the blast is
# self-similar to the unit regardless of our tile size — we feed the
# unit's pixel radius straight in and `intensity = radius_px / 8`, with
# Mindustry's "8 px tile" treated as our pixel. Frame durations (60 fps)
# convert to seconds via `/ 60`.
const _DX_FPS := 60.0
const _DX_TILE_PX := 8.0               # intensity divisor: intensity = radius_px / 8
const _DX_SMOKE_BURSTS := 4            # gray smoke sub-bursts
# Colours. Pal oranges are verbatim hex from graphics/Pal.java; the grays
# are Arc's built-in `Color.gray` = (0.5, 0.5, 0.5), which the source uses
# for the smoke, the ring, and the final spark-fade endpoint.
const _DX_LIGHTER_ORANGE := Color("f6e096")   # Pal.lighterOrange
const _DX_LIGHT_ORANGE := Color("f68021")     # Pal.lightOrange
const _DX_GRAY := Color(0.5, 0.5, 0.5)        # Color.gray

@onready var main: Node2D = get_node_or_null("/root/Main")

# Each entry:
#   pos:           Vector2  origin in world space
#   age:           float    seconds since spawn
#   ring_radius:   float    final ring radius in pixels
#   spokes:        Array of { angle, len, color }
var _bursts: Array = []

# Active Mindustry-style unit-death explosions. Each entry:
#   pos:       Vector2  origin in world space
#   age:       float    seconds since spawn
#   lifetime:  float    total seconds (43 + intensity*35)/60
#   intensity: float    radius/8 — drives every sub-effect's scale/count
#   scl:       float    px scale factor (GRID_SIZE / 8)
#   smoke:     Array[_DX_SMOKE_BURSTS] of { dur, parts }
#                 parts: Array of { ang, mag, fade }  (fade = rand 0.5..1)
#   sparks:    Array of { ang, mag }
var _unit_bursts: Array = []


func _ready() -> void:
	# Godot caps z_index at 4096 — values above silently fall back to 0,
	# which would drop the explosion UNDER blocks (z 50). Pin to the max
	# so the burst sits above blocks, units (z 4095), and the projectile
	# overlay (z 4095).
	z_index = 4096
	z_as_relative = false
	process_mode = Node.PROCESS_MODE_PAUSABLE


## `effect_scale` grows the spokes + their thickness (the ring is sized by
## `ring_tiles_override`). Cores pass a value > 1 so the ring/spokes punch
## out past the new core boom's smoke; the reactor leaves it at 1.0.
func explode(world_pos: Vector2, ring_tiles_override: float = -1.0, effect_scale: float = 1.0, show_ring: bool = true) -> void:
	var gs: float = float(main.GRID_SIZE) if main else 16.0
	var ring_tiles: float = ring_tiles_override
	if ring_tiles <= 0.0:
		ring_tiles = RING_RADIUS_TILES + randf_range(-RING_RADIUS_VARIANCE, RING_RADIUS_VARIANCE)
	var spoke_count: int = randi_range(LINE_MIN_COUNT, LINE_MAX_COUNT)
	var spokes: Array = []
	for i in range(spoke_count):
		var angle: float = randf() * TAU
		var len_tiles: float = randf_range(LINE_MIN_LEN_TILES, LINE_MAX_LEN_TILES) * effect_scale
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
		"line_scale": effect_scale,
		"show_ring": show_ring,
	})
	queue_redraw()


## Mindustry-faithful unit death blast (port of `Fx.dynamicExplosion`).
## `unit_radius_px` is the dying unit's visual RADIUS in world pixels
## (e.g. `data.visual_size * 0.5`, or its collision half-size). From it we
## derive `intensity = radius/8`-analog that drives every sub-effect's
## count and relative size exactly as the source does, and a single world
## scale that converts Mindustry's 8px-tile space into ours while keeping
## the three layers' proportions identical to the original:
##   1. four gray smoke sub-bursts (filled circles, pow10Out spread)
##   2. one expanding stroked shockwave ring
##   3. orange spark lines that fly out and shrink (lighterOrange→
##      lightOrange→gray over life)
## Spawns a self-similar blast regardless of tile size; bigger units (more
## radius) get a bigger, busier explosion, just like Mindustry.
func unit_death(world_pos: Vector2, unit_radius_px: float) -> void:
	var gs: float = float(main.GRID_SIZE) if main else 16.0
	# Mindustry units span ~2 tiles; ours are sub-tile. Render the blast at
	# GRID_SIZE/16 px per Mindustry-px so it lands at a visible, tile-
	# proportional footprint (sparks reach ~2.5 tiles at intensity 1) while
	# preserving Fx.dynamicExplosion's internal ratios. One uniform factor.
	var scl: float = gs / 16.0
	# intensity ≈ radius/8 in spirit; tuned so a typical small unit (~5 px
	# radius) lands near 1.0. Clamped to Mindustry's natural blast range.
	var intensity: float = clampf(unit_radius_px * 0.2, 0.6, 4.0)
	_spawn_dynamic_explosion(world_pos, intensity, scl)


## Mindustry-style CORE explosion. A core destructs through the SAME
## `Fx.dynamicExplosion` the game uses for every other blast (gray smoke
## puffs → expanding shockwave ring → orange spark lines) — a core is just
## the biggest, longest-lived instance of it, plus a hard screen shake and a
## few scattered satellite blasts so a multi-tile core reads as one big
## chained boom rather than a single point pop. `size_tiles` is the core's
## footprint (e.g. 3 for a Shard); larger cores throw larger blasts.
func core_explosion(world_pos: Vector2, size_tiles: float = 3.0) -> void:
	var gs: float = float(main.GRID_SIZE) if main else 16.0
	var scl: float = gs / 16.0
	# Mindustry's intensity = radius/8 with radius = tilesize*size/2; scaled
	# up here so the core blast is the climactic one, and clamped so an
	# oversized core can't run away.
	var intensity: float = clampf(size_tiles * 1.4, 3.0, 6.0)
	# Central blast.
	_spawn_dynamic_explosion(world_pos, intensity, scl)
	# Scattered satellite blasts across the footprint (Mindustry's big
	# explosions spawn multiple sub-bursts at random points within the
	# radius). Each is weaker; the natural per-burst smoke-timeline jitter
	# keeps them from all peaking on the same frame.
	var spread: float = size_tiles * gs * 0.34
	for _i in range(4):
		var off: Vector2 = Vector2.from_angle(randf() * TAU) * randf_range(0.25, 1.0) * spread
		_spawn_dynamic_explosion(world_pos + off, intensity * randf_range(0.4, 0.65), scl)
	# A modest screen shake — the core dying is a big event, but a softer
	# kick than a max-cap slam so it reads without rattling the screen.
	var fb = main.get_node_or_null("FeedbackSystem") if main else null
	if fb and fb.has_method("add_shake"):
		fb.add_shake(15.0)


## Mindustry-style reactor meltdown: a core-like dynamic explosion, but
## hotter, wider, and messier. The old yellow ring sits underneath as the
## fast pressure wave, while the dynamic bursts provide smoke, shockwave,
## and orange ejecta.
func reactor_explosion(world_pos: Vector2, size_tiles: float = 3.0) -> void:
	var gs: float = float(main.GRID_SIZE) if main else 16.0
	var scl: float = gs / 16.0
	var intensity: float = clampf(size_tiles * 1.85, 5.0, 8.0)
	explode(world_pos, size_tiles * 5.0, 2.4, true)
	_spawn_dynamic_explosion(world_pos, intensity, scl)
	var spread: float = size_tiles * gs * 0.85
	for _i in range(8):
		var off: Vector2 = Vector2.from_angle(randf() * TAU) * randf_range(0.15, 1.0) * spread
		_spawn_dynamic_explosion(world_pos + off, intensity * randf_range(0.35, 0.7), scl)
	var particles = main.get_node_or_null("ParticleOverlay") if main else null
	if particles and particles.has_method("spawn_fire"):
		particles.spawn_fire(world_pos, Vector2.ZERO, 95, 560.0, 1.45, 26.0, 180.0)
		for _i in range(7):
			var dir: Vector2 = Vector2.from_angle(randf() * TAU)
			var off: Vector2 = dir * randf_range(gs * 0.4, spread)
			particles.spawn_fire(world_pos + off, dir, 20, 460.0, 1.2, 19.0, 70.0)
	var fb = main.get_node_or_null("FeedbackSystem") if main else null
	if fb and fb.has_method("add_shake"):
		fb.add_shake(45.0)


## Core of the Fx.dynamicExplosion port: builds the smoke / ring / spark
## timelines for a blast of the given `intensity` (Mindustry radius/8) at
## world scale `scl` (Mindustry-px → our-px) and queues it. Both unit_death
## and core_explosion feed this — the only difference between a unit pop and
## a core boom is the intensity + count handed in here.
func _spawn_dynamic_explosion(world_pos: Vector2, intensity: float, scl: float) -> void:
	# --- Smoke: 4 sub-bursts, each its own timeline (b.scaled(lifetime*lenScl)).
	var lifetime: float = (43.0 + intensity * 35.0) / _DX_FPS
	var smoke_count: int = maxi(1, roundi(3.0 * intensity))
	var smoke: Array = []
	for _i in range(_DX_SMOKE_BURSTS):
		var len_scl: float = randf_range(0.4, 1.0)
		var parts: Array = []
		for _p in range(smoke_count):
			parts.append({
				"ang": randf() * TAU,
				"mag": randf(),                    # randLenVectors length fraction
				"fade": randf_range(0.5, 1.0),     # per-particle rand(0.5,1)
			})
		smoke.append({"dur": lifetime * len_scl, "parts": parts})

	# --- Sparks: 9*intensity radial lines (final randLenVectors).
	var spark_count: int = maxi(3, roundi(9.0 * intensity))
	var sparks: Array = []
	for _s in range(spark_count):
		sparks.append({"ang": randf() * TAU, "mag": randf()})

	_unit_bursts.append({
		"pos": world_pos,
		"age": 0.0,
		"lifetime": lifetime,
		"intensity": intensity,
		"scl": scl,
		"smoke": smoke,
		"sparks": sparks,
	})
	queue_redraw()


## pow-out easing: 1 - (1-a)^p, matching Arc Interp.powNOut (even N).
static func _pow_out(a: float, p: float) -> float:
	var x: float = clampf(a, 0.0, 1.0)
	return 1.0 - pow(1.0 - x, p)


## Two-segment 3-stop gradient, matching Arc Draw.color(a, b, c, f).
static func _lerp3(a: Color, b: Color, c: Color, f: float) -> Color:
	if f <= 0.5:
		return a.lerp(b, f * 2.0)
	return b.lerp(c, (f - 0.5) * 2.0)


func _process(delta: float) -> void:
	if _bursts.is_empty() and _unit_bursts.is_empty():
		return
	# Custom pause flag — `PROCESS_MODE_PAUSABLE` only honours the tree-
	# level `get_tree().paused`, but the game pauses via Main.world_paused.
	# Without this guard the ring + spokes keep animating while everything
	# else holds still.
	if main and "world_paused" in main and main.world_paused:
		return
	for i in range(_bursts.size() - 1, -1, -1):
		_bursts[i]["age"] += delta
		if _bursts[i]["age"] >= EFFECT_LIFE:
			_bursts.remove_at(i)
	for i in range(_unit_bursts.size() - 1, -1, -1):
		_unit_bursts[i]["age"] += delta
		if _unit_bursts[i]["age"] >= float(_unit_bursts[i]["lifetime"]):
			_unit_bursts.remove_at(i)
	queue_redraw()


func _draw() -> void:
	# Old ring + shrapnel-spoke bursts draw FIRST so they sit UNDER the
	# Mindustry-style dynamicExplosion (cores layer both; the new boom reads
	# on top of the old ring).
	_draw_old_bursts()
	_draw_unit_bursts()


func _draw_old_bursts() -> void:
	for b in _bursts:
		var t: float = clampf(float(b["age"]) / EFFECT_LIFE, 0.0, 1.0)
		var origin: Vector2 = b["pos"]
		var line_scale: float = float(b.get("line_scale", 1.0))
		# --- Yellow ring (skipped for core bursts, which layer the new
		# boom's shockwave on top instead) ---
		if bool(b.get("show_ring", true)):
			var ring_w: float = RING_THICKNESS * line_scale
			var ring_r: float = float(b["ring_radius"]) * ease(t, 1.6)
			var ring_alpha: float = lerpf(1.0, 0.0, t)
			if ring_r > 1.0:
				draw_arc(origin, ring_r, 0.0, TAU, 48,
					Color(1.0, 0.92, 0.2, ring_alpha), ring_w, true)
				# Faint outer glow so the ring reads thick at lower zoom.
				draw_arc(origin, ring_r + ring_w * 0.5, 0.0, TAU, 48,
					Color(1.0, 0.7, 0.1, ring_alpha * 0.35), ring_w * 0.75, true)
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
			draw_line(back, tip, col, LINE_THICKNESS * line_scale, true)


## Renders the Mindustry `Fx.dynamicExplosion` ports. Three layers, drawn
## back-to-front: gray smoke puffs, the expanding shockwave ring, then the
## orange spark lines on top. All timing/scale ratios mirror the source;
## see `unit_death()` for the space conversion.
func _draw_unit_bursts() -> void:
	for b in _unit_bursts:
		var origin: Vector2 = b["pos"]
		var age: float = float(b["age"])
		var intensity: float = float(b["intensity"])
		var scl: float = float(b["scl"])

		# --- Layer A: gray smoke (4 sub-bursts, each its own timeline) ---
		# offset = randLenVectors(fin=pow10Out(subfin), len=14*intensity)
		# radius = fout(pow5Out)*rand(0.5,1) * (2+intensity)*1.8
		var smoke_len: float = 14.0 * intensity * scl
		var smoke_rad: float = (2.0 + intensity) * 1.8 * scl
		for burst in b["smoke"]:
			var dur: float = float(burst["dur"])
			if dur <= 0.0:
				continue
			var subfin: float = clampf(age / dur, 0.0, 1.0)
			if subfin >= 1.0:
				continue
			var spread: float = _pow_out(subfin, 10.0)       # pow10Out
			var fout: float = _pow_out(1.0 - subfin, 5.0)     # fout(pow5Out)
			for p in burst["parts"]:
				var off: Vector2 = Vector2.from_angle(float(p["ang"])) \
					* (smoke_len * float(p["mag"]) * spread)
				var r: float = smoke_rad * fout * float(p["fade"])
				if r > 0.25:
					draw_circle(origin + off, r, Color(_DX_GRAY.r, _DX_GRAY.g, _DX_GRAY.b, 0.9))

		# --- Layer B: expanding shockwave ring ---
		# Inner timeline (5 + intensity*2.5) frames; radius (3 + fin*14)*intensity,
		# stroke (3.1 + intensity/5)*fout. Drawn in gray like the source.
		var ring_dur: float = (5.0 + intensity * 2.5) / _DX_FPS
		var ring_fin: float = clampf(age / ring_dur, 0.0, 1.0) if ring_dur > 0.0 else 1.0
		if ring_fin < 1.0:
			var ring_fout: float = 1.0 - ring_fin
			var ring_r: float = (3.0 + ring_fin * 14.0) * intensity * scl
			var ring_w: float = (3.1 + intensity / 5.0) * ring_fout * scl
			if ring_r > 1.0 and ring_w > 0.5:
				draw_arc(origin, ring_r, 0.0, TAU, 48,
					Color(_DX_GRAY.r, _DX_GRAY.g, _DX_GRAY.b, 0.9), ring_w, true)

		# --- Layer C: orange spark lines (on top) ---
		# Lives over baseLifetime = (26 + intensity*15) frames. Distance grows
		# out to 40*intensity; each line shrinks as it ages (length
		# 1 + (1-finpow)*4*(3+intensity)); colour lerps lighterOrange ->
		# lightOrange -> gray over fin; stroke 1.7*fout*(...).
		var base_dur: float = (26.0 + intensity * 15.0) / _DX_FPS
		var base_fin: float = clampf(age / base_dur, 0.0, 1.0) if base_dur > 0.0 else 1.0
		if base_fin < 1.0:
			# Fast-start ease-OUT (was fin^2, an ease-IN that left the sparks
			# hovering at the origin for the first frames). pow2Out gives the
			# sparks immediate outward velocity that decelerates, so they
			# read as ejecta thrown the instant the blast spawns.
			var finpow: float = _pow_out(base_fin, 2.0)
			var base_fout: float = 1.0 - base_fin
			var spark_col: Color = _lerp3(_DX_LIGHTER_ORANGE, _DX_LIGHT_ORANGE, _DX_GRAY, base_fin)
			var spark_w: float = (1.7 * base_fout) * (1.0 + (intensity - 1.0) / 2.0) * scl
			var spark_len_base: float = 40.0 * intensity * scl
			if spark_w > 0.4:
				for s in b["sparks"]:
					var dir: Vector2 = Vector2.from_angle(float(s["ang"]))
					var pos: Vector2 = origin + dir * (spark_len_base * float(s["mag"]) * finpow)
					var line_len: float = (1.0 + base_fout * 4.0 * (3.0 + intensity)) * scl
					draw_line(pos, pos + dir * line_len, spark_col, spark_w, true)
