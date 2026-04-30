extends Node

# ============================================================
# WAVE_MANAGER.GD — Scripted enemy-wave spawner
# ============================================================
# Global config + named spawn points + either hand-authored
# waves or an auto-generator that fills waves in from per-unit
# rules (spawn_between, min/max per wave).
#
# Authoring-side state lives on two dicts + one array:
#   `config`        — global wave schedule + generation mode
#   `spawn_points`  — Array[{name: String, cell: Vector2i}]
#   `waves`         — Array of manually-authored waves
#                     (only used when config.generation_mode == "manual")
#
# Runtime expands those into a flat list of waves and ticks
# them with a single cadence timer, firing `waves_defeated`
# when the final wave's units all die.
# ============================================================


signal waves_defeated

var main: Node2D = null
var unit_mgr: Node2D = null

## Authoring state (SaveManager rebuilds these on sector load).
var config: Dictionary = {
	"start_mode": "landing",      # "landing" | "script"
	"initial_delay": 30.0,        # seconds before wave 1 (once armed)
	"interval": 30.0,             # seconds between subsequent waves
	"generation_mode": "manual",  # "manual" | "auto"
	"auto_wave_count": 10,        # used when generation_mode == "auto"
	"auto_unit_templates": [],    # Array[{unit_id, spawn_point,
								  #         first_wave, last_wave,
								  #         min_per_wave, max_per_wave}]
}
var spawn_points: Array = []    # Array[{name: String, cell: Vector2i}]
var waves: Array = []           # Manual-mode waves. Each wave:
								# {units: [{unit_id, count, spawn_point}]}

# --- RUNTIME STATE ---
var _expanded_waves: Array = []
var _idx: int = 0
var _timer: float = 0.0
var _running: bool = false
var _last_wave_units: Array = []
var _all_waves_units: Array = []   # WeakRefs across every spawned wave
var waves_all_defeated: bool = false
## Set by load_runtime so the deferred auto-arm in `_ready` doesn't
## re-run start() and clobber the restored wave index/timer/expansion.
var _runtime_loaded: bool = false


func _ready() -> void:
	await get_tree().process_frame
	main = get_node_or_null("/root/Main")
	unit_mgr = get_node_or_null("/root/Main/UnitManager")
	print("WaveManager._ready: start_mode=%s waves=%d auto_templates=%d" \
		% [String(config.get("start_mode", "landing")), waves.size(), \
		(config.get("auto_unit_templates", []) as Array).size()])
	# Auto-arm if the config says "landing". Script mode waits for an
	# explicit start() call from the sector script. Skip when a save
	# has already restored the runtime — start() would reset _idx and
	# _timer and re-expand the wave list from scratch.
	if _runtime_loaded:
		print("WaveManager._ready: skipping auto-arm — runtime restored from save")
	elif String(config.get("start_mode", "landing")) == "landing":
		start()


## Expands the authored config into a concrete wave list and begins
## the countdown for wave 1. Auto-mode with wave_count <= 0 arms as
## infinite — waves keep generating on the fly until `stop()` is
## called (typically by a sector-script stop_waves step).
func start() -> void:
	_expand_waves()
	_idx = 0
	_last_wave_units.clear()
	_all_waves_units.clear()
	waves_all_defeated = false
	_timer = float(config.get("initial_delay", 0.0))
	# Running as long as we either have an expanded list ready OR are
	# in an infinite auto loop (which generates waves lazily).
	_running = not _expanded_waves.is_empty() or _is_infinite_auto()
	print("WaveManager.start(): running=%s expanded=%d infinite_auto=%s start_mode=%s initial_delay=%.1f" \
		% [str(_running), _expanded_waves.size(), str(_is_infinite_auto()), \
		String(config.get("start_mode", "?")), _timer])


func _is_infinite_auto() -> bool:
	return String(config.get("generation_mode", "manual")) == "auto" \
		and int(config.get("auto_wave_count", 10)) <= 0 \
		and not (config.get("auto_unit_templates", []) as Array).is_empty()


func stop() -> void:
	_running = false


## Returns a dict the SaveManager can stash alongside the sector save.
## Captures only the runtime fields — the authored config / waves /
## spawn_points are saved separately via the waves_bundle path.
##
## `_last_wave_units` and `_all_waves_units` are intentionally omitted:
## they're WeakRefs into UnitManager.enemies, which will be re-spawned
## fresh on load anyway, so the references would all dangle.
func serialize_runtime() -> Dictionary:
	var expanded_copy: Array = []
	for w in _expanded_waves:
		var units_copy: Array = []
		for u in w.get("units", []):
			units_copy.append({
				"unit_id": String(u.get("unit_id", &"")),
				"count": int(u.get("count", 1)),
				"spawn_point": String(u.get("spawn_point", "")),
			})
		expanded_copy.append({"units": units_copy})
	return {
		"running": _running,
		"idx": _idx,
		"timer": _timer,
		"waves_all_defeated": waves_all_defeated,
		"expanded_waves": expanded_copy,
	}


## Restores the runtime fields produced by `serialize_runtime`. Safe to
## call before or after _ready — `start()`-style auto-arm runs from
## _ready first, and a subsequent load_runtime overrides whatever
## `start()` set.
func load_runtime(data: Dictionary) -> void:
	if data == null or data.is_empty():
		return
	_runtime_loaded = true
	_running = bool(data.get("running", false))
	_idx = int(data.get("idx", 0))
	_timer = float(data.get("timer", 0.0))
	waves_all_defeated = bool(data.get("waves_all_defeated", false))
	_expanded_waves.clear()
	for w in data.get("expanded_waves", []):
		var units_copy: Array = []
		for u in (w as Dictionary).get("units", []):
			units_copy.append({
				"unit_id": StringName(u.get("unit_id", "")),
				"count": int(u.get("count", 1)),
				"spawn_point": String(u.get("spawn_point", "")),
			})
		_expanded_waves.append({"units": units_copy})
	# Drop dangling WeakRefs from the previous run; UnitManager rebuilds
	# its enemy list from the sector save on its own.
	_last_wave_units.clear()
	_all_waves_units.clear()
	print("WaveManager.load_runtime: running=%s idx=%d expanded=%d timer=%.1f" \
		% [str(_running), _idx, _expanded_waves.size(), _timer])


func _process(delta: float) -> void:
	if not _running or main == null:
		return
	if "world_paused" in main and main.world_paused:
		return

	# Infinite auto mode: lazily append another generated wave to the
	# list whenever the timer is about to run out of scheduled waves.
	# Stop only when sector scripting calls stop().
	if _is_infinite_auto() and _idx >= _expanded_waves.size():
		_append_one_auto_wave(_expanded_waves.size() + 1)

	# Post-all-waves (finite runs only): watch the collected unit refs;
	# once they all die, fire the `waves_defeated` signal exactly once.
	if _idx >= _expanded_waves.size():
		if not waves_all_defeated and _any_alive(_all_waves_units) == false:
			waves_all_defeated = true
			waves_defeated.emit()
		return

	_timer -= delta
	if _timer > 0.0:
		return
	_spawn_wave(_idx)
	_idx += 1
	_timer = float(config.get("interval", 0.0))


## Generates and appends a single auto-mode wave using the template
## rules. Used by the infinite-auto loop so memory doesn't balloon
## building out a giant preview of future waves.
func _append_one_auto_wave(wave_num: int) -> void:
	var units: Array = _roll_wave_units(config, wave_num)
	_expanded_waves.append({"units": units})


## Shared roll function: takes a wave number and the full config, and
## returns an `Array[{unit_id, count, spawn_point}]` for that wave by
## evaluating every template's range / count / likelyness / curve.
## Factored out so the in-flight infinite loop, the one-shot `build_auto_waves`,
## and the editor's preview all use the same math.
static func _roll_wave_units(cfg: Dictionary, wave_num: int) -> Array:
	var templates: Array = cfg.get("auto_unit_templates", [])
	var units: Array = []
	for tpl_i in range(templates.size()):
		var t: Dictionary = templates[tpl_i]
		var first_w: int = int(t.get("first_wave", 1))
		var last_w: int = int(t.get("last_wave", 1))
		if wave_num < first_w or wave_num > last_w:
			continue
		var lo: int = int(t.get("min_per_wave", 1))
		var hi: int = int(t.get("max_per_wave", 1))
		if hi < lo:
			hi = lo
		# Per-template RNG seeded on the template's own identity +
		# wave number. Without this, every template shares the global
		# RNG sequence, so tweaking any knob on rule A re-shuffles the
		# rolls for rules B/C/D too — which reads to the author as
		# "editing one rule changed all of them".
		var rng: RandomNumberGenerator = RandomNumberGenerator.new()
		rng.seed = int(_rng_seed_for(t, tpl_i, wave_num))
		var base_count: int = lo + (rng.randi() % maxi(hi - lo + 1, 1))
		# Curve lookup: t_norm is 0 at first_wave, 1 at last_wave. The
		# curve y-value is a count multiplier (defaults to 1.0 across
		# the whole range when the author hasn't dragged anything).
		var span: int = maxi(last_w - first_w, 1)
		var t_norm: float = clampf(float(wave_num - first_w) / float(span), 0.0, 1.0)
		var curve_mul: float = sample_curve_points(t.get("curve_points", []), t_norm)
		# Likelyness scales both the expected count and the chance-to-
		# spawn-at-all. Clamped to the authoring range [0.1, 2.0].
		var likelyness: float = clampf(float(t.get("likelyness", 1.0)), 0.1, 2.0)
		var scaled: float = float(base_count) * curve_mul * likelyness
		var whole: int = int(floor(scaled))
		var frac: float = scaled - float(whole)
		if frac > 0.0 and rng.randf() < frac:
			whole += 1
		# Max is a hard ceiling — curve/likelyness can reduce the count
		# (down to zero to suppress the spawn entirely) but can't push
		# it past the authored max_per_wave bound.
		whole = clampi(whole, 0, hi)
		if whole <= 0:
			continue
		units.append({
			"unit_id": StringName(t.get("unit_id", &"")),
			"count": whole,
			"spawn_point": String(t.get("spawn_point", "")),
		})
	return units


## Deterministic per-(template, wave) seed. Derived from the rule's
## unit id / spawn point / index so editing a completely different
## rule can't perturb this one's rolls. Wave number is mixed in so
## each wave still rolls its own count.
static func _rng_seed_for(t: Dictionary, tpl_i: int, wave_num: int) -> int:
	var parts: String = "%s|%s|%d|%d" % [
		String(t.get("unit_id", "")),
		String(t.get("spawn_point", "")),
		tpl_i,
		wave_num,
	]
	return hash(parts)


## Linearly interpolates a y-value from an array of curve control
## points. Points are `Array[float]` of equally-spaced y-samples from
## t=0 to t=1 (we keep them flat for easy JSON storage). Empty/invalid
## input returns 1.0, which means "no scaling".
static func sample_curve_points(points_raw, t: float) -> float:
	if not (points_raw is Array) or (points_raw as Array).is_empty():
		return 1.0
	var pts: Array = points_raw
	if pts.size() == 1:
		return float(pts[0])
	var seg_count: int = pts.size() - 1
	var scaled_t: float = clampf(t, 0.0, 1.0) * float(seg_count)
	var lo_idx: int = int(floor(scaled_t))
	var hi_idx: int = mini(lo_idx + 1, seg_count)
	var local_t: float = scaled_t - float(lo_idx)
	var lo_y: float = float(pts[lo_idx])
	var hi_y: float = float(pts[hi_idx])
	return lerp(lo_y, hi_y, local_t)


func _any_alive(refs: Array) -> bool:
	for wref in refs:
		var u = wref.get_ref()
		if u != null and is_instance_valid(u) and not u.is_dead:
			return true
	return false


func _spawn_wave(idx: int) -> void:
	if unit_mgr == null:
		unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if unit_mgr == null or main == null:
		return
	var wave: Dictionary = _expanded_waves[idx]
	var units: Array = wave.get("units", [])
	_last_wave_units.clear()
	for entry in units:
		var uid: StringName = StringName(entry.get("unit_id", &""))
		if uid == &"":
			continue
		var count: int = int(entry.get("count", 1))
		var sp_name: String = String(entry.get("spawn_point", ""))
		var cell: Vector2i = _resolve_spawn_point(sp_name)
		var world_pos: Vector2 = main.grid_to_world(cell) + Vector2(
			main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5
		)
		for _i in range(count):
			unit_mgr.spawn_enemy(world_pos, uid)
			if not unit_mgr.enemies.is_empty():
				var wref: Variant = weakref(unit_mgr.enemies[-1])
				_last_wave_units.append(wref)
				_all_waves_units.append(wref)


func _resolve_spawn_point(sp_name: String) -> Vector2i:
	for sp in spawn_points:
		if String(sp.get("name", "")) == sp_name:
			return _coerce_cell(sp.get("cell", Vector2i.ZERO))
	# Fallback: first defined spawn point, then (0,0).
	if not spawn_points.is_empty():
		return _coerce_cell(spawn_points[0].get("cell", Vector2i.ZERO))
	return Vector2i.ZERO


func _coerce_cell(raw) -> Vector2i:
	if raw is Vector2i:
		return raw
	if raw is String:
		var parts: PackedStringArray = (raw as String).split(",")
		if parts.size() >= 2:
			return Vector2i(int(parts[0]), int(parts[1]))
	return Vector2i.ZERO


# =========================
# EXPANSION
# =========================

## Concretizes the authored config into `_expanded_waves`. For manual
## mode this is a straight copy of `waves`; for auto mode each unit
## template emits a randomized count in every wave inside its range.
func _expand_waves() -> void:
	var mode: String = String(config.get("generation_mode", "manual"))
	if mode == "auto":
		_expanded_waves = build_auto_waves(config)
	else:
		_expanded_waves = []
		for w in waves:
			var units_copy: Array = []
			for u in w.get("units", []):
				units_copy.append({
					"unit_id": StringName(u.get("unit_id", &"")),
					"count": int(u.get("count", 1)),
					"spawn_point": String(u.get("spawn_point", "")),
				})
			_expanded_waves.append({"units": units_copy})


## Deterministic(ish) auto-generator. Walks 1..wave_count, asks every
## template whether this wave is within its [first_wave, last_wave]
## band, and if so adds a random count in [min, max] of that unit at
## the template's spawn point. Exposed as `static` so the editor can
## preview the graph without needing a running manager.
static func build_auto_waves(cfg: Dictionary) -> Array:
	var wave_count: int = int(cfg.get("auto_wave_count", 10))
	var out: Array = []
	for w_i in range(wave_count):
		out.append({"units": _roll_wave_units(cfg, w_i + 1)})
	return out


# =========================
# SERIALIZATION
# =========================

## Dumps authoring state to JSON-safe primitives.
static func serialize_all(cfg: Dictionary, spawns: Array, manual_waves: Array) -> Dictionary:
	var spawns_out: Array = []
	for sp in spawns:
		var c = sp.get("cell", Vector2i.ZERO)
		var cell_str: String = ("%d,%d" % [c.x, c.y]) if c is Vector2i else String(c)
		spawns_out.append({"name": String(sp.get("name", "")), "cell": cell_str})

	var templates_out: Array = []
	for t in cfg.get("auto_unit_templates", []):
		var curve_raw: Array = t.get("curve_points", [])
		var curve_out: Array = []
		for p in curve_raw:
			curve_out.append(float(p))
		templates_out.append({
			"unit_id": String(t.get("unit_id", "")),
			"spawn_point": String(t.get("spawn_point", "")),
			"first_wave": int(t.get("first_wave", 1)),
			"last_wave": int(t.get("last_wave", 1)),
			"min_per_wave": int(t.get("min_per_wave", 1)),
			"max_per_wave": int(t.get("max_per_wave", 1)),
			"likelyness": float(t.get("likelyness", 1.0)),
			"curve_points": curve_out,
		})

	var waves_out: Array = []
	for w in manual_waves:
		var units_out: Array = []
		for u in w.get("units", []):
			units_out.append({
				"unit_id": String(u.get("unit_id", "")),
				"count": int(u.get("count", 1)),
				"spawn_point": String(u.get("spawn_point", "")),
			})
		waves_out.append({"units": units_out})

	return {
		"config": {
			"start_mode": String(cfg.get("start_mode", "landing")),
			"initial_delay": float(cfg.get("initial_delay", 30.0)),
			"interval": float(cfg.get("interval", 30.0)),
			"generation_mode": String(cfg.get("generation_mode", "manual")),
			"auto_wave_count": int(cfg.get("auto_wave_count", 10)),
			"auto_unit_templates": templates_out,
		},
		"spawn_points": spawns_out,
		"waves": waves_out,
	}


## Restores authoring state from a serialized dict. Returns the full
## set as a single dict with `config`, `spawn_points`, `waves` keys so
## the caller can splat it onto either WaveManager or the editor's
## staging fields.
static func deserialize_all(data: Dictionary) -> Dictionary:
	var cfg_raw: Dictionary = data.get("config", {})
	var templates_in: Array = cfg_raw.get("auto_unit_templates", [])
	var templates_out: Array = []
	for t in templates_in:
		var curve_raw: Array = t.get("curve_points", [])
		var curve_out: Array = []
		for p in curve_raw:
			curve_out.append(float(p))
		templates_out.append({
			"unit_id": StringName(t.get("unit_id", "")),
			"spawn_point": String(t.get("spawn_point", "")),
			"first_wave": int(t.get("first_wave", 1)),
			"last_wave": int(t.get("last_wave", 1)),
			"min_per_wave": int(t.get("min_per_wave", 1)),
			"max_per_wave": int(t.get("max_per_wave", 1)),
			"likelyness": float(t.get("likelyness", 1.0)),
			"curve_points": curve_out,
		})
	var cfg: Dictionary = {
		"start_mode": String(cfg_raw.get("start_mode", "landing")),
		"initial_delay": float(cfg_raw.get("initial_delay", 30.0)),
		"interval": float(cfg_raw.get("interval", 30.0)),
		"generation_mode": String(cfg_raw.get("generation_mode", "manual")),
		"auto_wave_count": int(cfg_raw.get("auto_wave_count", 10)),
		"auto_unit_templates": templates_out,
	}

	var spawns_in: Array = data.get("spawn_points", [])
	var spawns_out: Array = []
	for sp in spawns_in:
		var cell: Vector2i = Vector2i.ZERO
		var cell_raw = sp.get("cell", "0,0")
		if cell_raw is String:
			var parts: PackedStringArray = (cell_raw as String).split(",")
			if parts.size() >= 2:
				cell = Vector2i(int(parts[0]), int(parts[1]))
		spawns_out.append({"name": String(sp.get("name", "")), "cell": cell})

	var waves_in: Array = data.get("waves", [])
	var waves_out: Array = []
	for w in waves_in:
		var units_out: Array = []
		for u in w.get("units", []):
			units_out.append({
				"unit_id": StringName(u.get("unit_id", "")),
				"count": int(u.get("count", 1)),
				"spawn_point": String(u.get("spawn_point", "")),
			})
		waves_out.append({"units": units_out})

	return {"config": cfg, "spawn_points": spawns_out, "waves": waves_out}
