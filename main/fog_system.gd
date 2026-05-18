extends Node2D
class_name FogSystem

## Mindustry-style fog of war. Three-tier visibility per cell:
##   - UNSEEN    — never revealed. Painted full black.
##   - EXPLORED  — revealed once but no LUMINA source currently sees
##                 it. Painted with a darker, ~70% black overlay so
##                 the terrain reads as a faded memory.
##   - VISIBLE   — currently inside the sight radius of a LUMINA
##                 source. No overlay; full clarity.
##
## Sources:
##   - Every LUMINA placed building. Sight radius:
##       data.sight_range > 0      → use that
##       data.is_turret()          → max(attack_range, 5)
##       data.tags.has("core")     → 16 (large)
##       otherwise                 → 4
##   - Every LUMINA unit. Sight radius = data.detection_range / GRID_SIZE.
##   - The player drone. Fixed radius (DRONE_SIGHT).
##
## Performance: static (buildings) visibility is cached and only
## refreshed when a building event fires; dynamic (units + drone)
## visibility recomputes every frame so a moving unit's unfade tracks
## it smoothly. The mesh bake is bounded by viewport, not map size.
##
## Save/load: `_explored` serializes to the sector file under key
## "fog_explored" (Vector2i list). Visibility itself isn't saved — it's
## recomputed from current sources on load.

@onready var main: Node2D = get_node_or_null("/root/Main")

# --- Tunables ---
const DRONE_SIGHT := 12             # tiles
const DEFAULT_BUILDING_SIGHT := 8   # tiles when a block has no sight_range / not a turret / not a core
const CORE_SIGHT := 32              # tiles
# How many tiles of soft falloff at the edge of every sight bubble.
# Mirrors wall_fade: an inner "core" ring is fully clear, then a linear
# ramp fades out to the radius. Same value the wall system uses (~3).
const SIGHT_FADE_RANGE := 3.0
const FOG_ALPHA_UNSEEN := 1.0
const FOG_ALPHA_EXPLORED := 0.62

# --- State ---
# Visibility maps stored as flat packed arrays indexed by `gy * w + gx`.
# Dictionary[Vector2i, float] looked clean but cost a Vector2i
# allocation + hash on every access; punch_circle and the per-frame
# bake do hundreds of thousands of those, which was the source of the
# frame-y motion. PackedFloat32Array indexing is ~10-20x faster.
var _visible: PackedFloat32Array = PackedFloat32Array()
var _static_visible: PackedFloat32Array = PackedFloat32Array()
# Explored (ever-seen). One byte per cell — 0 or 1, packed.
var _explored_bytes: PackedByteArray = PackedByteArray()
var _grid_w: int = 0
var _grid_h: int = 0
var _static_dirty: bool = true

# Baked fog quad mesh — single PRIMITIVE_TRIANGLES surface with
# per-vertex alpha, redrawn each frame from the current visibility
# state. Bake is bounded by viewport size, not map size.
var _fog_mesh: ArrayMesh = null
const FOG_BAKE_MARGIN := 16         # extra tiles around viewport so small camera nudges don't reveal a seam

# Throttle: rebuild dynamic visibility + bake the mesh at this cadence
# rather than every frame. Player units move slowly enough that 10 Hz
# fog updates are invisible to the eye but cut a 60 fps frame budget's
# fog cost by 6×. A change in the static cache (block placed/destroyed)
# bypasses the timer so the player gets immediate feedback when they
# place a building.
const _FOG_REBUILD_INTERVAL: float = 0.1
var _fog_rebuild_accum: float = 0.0
# Cached "is anything meaningfully different from last bake?" signals.
# Avoids the per-frame allocation + memcpy on a fully-static map.
var _last_cam_pos: Vector2 = Vector2(NAN, NAN)
var _last_cam_zoom: Vector2 = Vector2(NAN, NAN)
var _last_unit_sig: int = 0

# Set to true to disable fog entirely (debug / sandbox / map editor).
var disabled: bool = false


func _ready() -> void:
	# Above buildings (50), walls (52), units (70), but BELOW projectiles
	# (4095), popups (4096), and the crane overlay (4096). Player's own
	# bullets still read clearly through the fog this way.
	z_index = 80
	z_as_relative = false
	# Process while paused so the overlay doesn't pop off when the world
	# pauses for a build menu.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Mark the static cache dirty whenever a building changes hands —
	# placed, destroyed, or faction-converted. Recompute happens lazily
	# on the next frame.
	if main:
		if main.has_signal("building_placed"):
			main.building_placed.connect(func(_b, _g): _static_dirty = true)
		if main.has_signal("building_destroyed"):
			main.building_destroyed.connect(func(_g): _static_dirty = true)
		if main.has_signal("building_completed"):
			main.building_completed.connect(func(_b, _g): _static_dirty = true)


func _process(_delta: float) -> void:
	# Author-time toggle wins over the runtime debug switch. The map
	# editor's Map Settings dialog sets `main.fog_enabled`; respect it
	# without forcing the user to also flip `disabled`.
	var author_enabled: bool = bool(main.get("fog_enabled")) if main and "fog_enabled" in main else true
	if disabled or not author_enabled:
		# Drop any previously-baked mesh so toggling off mid-session
		# doesn't leave a stale fog layer painted over the world.
		if _fog_mesh != null:
			_fog_mesh = null
			queue_redraw()
		return
	_ensure_grid_arrays()
	# Static (buildings) vision is cached and only recomputed when a
	# building is placed / destroyed / completes. Dynamic vision (drone
	# + units) and the per-frame mesh bake are throttled to ~10 Hz so
	# a large map / zoomed-out view doesn't eat the frame budget on
	# every tick. The interval is short enough to feel smooth on a
	# moving shardling but cheap enough to disappear on a static
	# screen.
	var force_rebake: bool = false
	if _static_dirty:
		_rebuild_static_visible()
		_static_dirty = false
		force_rebake = true  # bypass timer + change-detection
	_fog_rebuild_accum += _delta
	if not force_rebake and _fog_rebuild_accum < _FOG_REBUILD_INTERVAL:
		return
	# Cheap change-detection: skip the dynamic-rebuild + mesh-bake when
	# nothing's actually moved this interval. A perfectly static screen
	# (no unit motion, no camera nudge) keeps reusing the previous
	# baked mesh. Static-dirty (block placed / destroyed) bypasses this
	# so the player gets immediate visual feedback.
	if not force_rebake and _state_unchanged_since_last_bake():
		_fog_rebuild_accum = 0.0
		return
	_fog_rebuild_accum = 0.0
	_rebuild_dynamic_visible()
	_rebuild_fog_mesh()
	queue_redraw()


## True when neither the camera nor any vision-emitting unit has moved
## meaningfully since the last bake. Cheap O(player_unit_count) hash;
## skips the expensive dynamic rebuild + mesh bake on idle frames.
## Tolerates sub-tile camera drift so micro-pans don't force a rebake
## every frame.
func _state_unchanged_since_last_bake() -> bool:
	if main == null:
		return false
	var camera := get_viewport().get_camera_2d() if get_viewport() else null
	var cam_pos: Vector2 = camera.get_screen_center_position() if camera else Vector2.ZERO
	var cam_zoom: Vector2 = camera.zoom if camera else Vector2.ONE
	# Threshold ≈ 1/4 tile so jitter inside a single grid cell doesn't
	# force a rebake. The fog mesh has per-cell granularity anyway, so
	# nothing visible changes until the camera crosses a tile boundary.
	var gs_quarter: float = float(main.GRID_SIZE) * 0.25
	if not is_finite(_last_cam_pos.x) or _last_cam_pos.distance_to(cam_pos) > gs_quarter \
			or _last_cam_zoom != cam_zoom:
		_last_cam_pos = cam_pos
		_last_cam_zoom = cam_zoom
		return false
	# Hash unit + drone grid positions. A position change of >= 1 tile
	# in any source flips the hash.
	var sig: int = 0
	var drone = main.get_node_or_null("PlayerDrone")
	if drone:
		var dg: Vector2i = main.world_to_grid(drone.position)
		sig = hash(sig + dg.x * 73856093 + dg.y * 19349663)
	var unit_mgr = main.get_node_or_null("UnitManager")
	if unit_mgr and "player_units" in unit_mgr:
		for u in unit_mgr.player_units:
			if u == null or not is_instance_valid(u) or u.is_dead:
				continue
			var ug: Vector2i = main.world_to_grid(u.position)
			sig = hash(sig + ug.x * 73856093 + ug.y * 19349663)
	if sig != _last_unit_sig:
		_last_unit_sig = sig
		return false
	return true


# ----- Rebuild -----

## Resizes the flat arrays to match the current map dimensions. Called
## lazily before any per-frame work so we don't lock the system to the
## map size at _ready time.
func _ensure_grid_arrays() -> void:
	if main == null:
		return
	var w: int = main.GRID_WIDTH
	var h: int = main.GRID_HEIGHT
	if w == _grid_w and h == _grid_h and _visible.size() == w * h:
		return
	_grid_w = w
	_grid_h = h
	var n: int = w * h
	_visible.resize(n)
	_static_visible.resize(n)
	_explored_bytes.resize(n)
	# Initial values are zero on resize; fine since "no fog data" = 0.
	_static_dirty = true


## Recomputes static (buildings only) visibility — invoked when a
## building event fires (place / destroy / completion / faction
## conversion via the dirty flag). Buildings don't move, so this is
## the expensive, infrequent half of the visibility pass.
func _rebuild_static_visible() -> void:
	if main == null or _grid_w <= 0:
		return
	# Wipe the cache.
	for i in range(_static_visible.size()):
		_static_visible[i] = 0.0
	var seen_anchors: Dictionary = {}
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if seen_anchors.has(anchor):
			continue
		seen_anchors[anchor] = true
		if main.get_building_faction(anchor) != main.Faction.LUMINA:
			continue
		var data: BlockData = Registry.get_block(main.placed_buildings.get(anchor, &""))
		if data == null:
			continue
		var radius: int = _building_sight_tiles(data)
		# Centre the circle on the building's footprint centre, not its
		# anchor cell, so a 3x3 core "sees" symmetrically.
		var cx: int = anchor.x + int(data.grid_size.x * 0.5)
		var cy: int = anchor.y + int(data.grid_size.y * 0.5)
		_punch_circle_into_array(_static_visible, cx, cy, radius)


## Cheap per-frame pass: copy the static cache, then layer drone +
## unit vision on top so moving sources update visibility every frame.
func _rebuild_dynamic_visible() -> void:
	if main == null or _grid_w <= 0:
		return
	# Flat-array copy via packed-array assignment is essentially a
	# memcpy — way cheaper than dict iteration.
	_visible = _static_visible.duplicate()
	var drone = main.get_node_or_null("PlayerDrone")
	if drone:
		var dg: Vector2i = main.world_to_grid(drone.position)
		_punch_circle_into_array(_visible, dg.x, dg.y, DRONE_SIGHT)
	var unit_mgr = main.get_node_or_null("UnitManager")
	if unit_mgr and "player_units" in unit_mgr:
		for u in unit_mgr.player_units:
			if u == null or not is_instance_valid(u) or u.is_dead:
				continue
			var det: float = float(u.data.detection_range) if u.data else float(main.GRID_SIZE) * 6.0
			var r: int = maxi(int(round(det / float(main.GRID_SIZE))), 3)
			var ug: Vector2i = main.world_to_grid(u.position)
			_punch_circle_into_array(_visible, ug.x, ug.y, r)


func _building_sight_tiles(data: BlockData) -> int:
	if data.sight_range > 0.0:
		return int(round(data.sight_range))
	if data.tags.has("core"):
		return CORE_SIGHT
	if data.is_turret() and data.attack_range > 0.0:
		return maxi(int(round(data.attack_range)), 5)
	return DEFAULT_BUILDING_SIGHT


## Punches a sight circle into a flat float array (visibility map),
## writing the max intensity per cell and updating _explored_bytes
## along the way. All math is integer/float — no Vector2i allocations,
## no Dictionary lookups in the inner loop.
func _punch_circle_into_array(target: PackedFloat32Array, ccx: int, ccy: int, radius: int) -> void:
	if main == null or _grid_w <= 0:
		return
	var w: int = _grid_w
	var h: int = _grid_h
	# Smooth falloff: cells within (radius - SIGHT_FADE_RANGE) are full
	# intensity; cells in the outer ring linearly ramp to 0. Mirrors
	# `_get_wall_fade_alpha`'s shape.
	var radius_f: float = float(radius)
	var inner: float = maxf(radius_f - SIGHT_FADE_RANGE, 0.0)
	var r2: float = radius_f * radius_f
	# Clip the iterated rect to the map bounds up front so the inner
	# loop has no per-cell `is_within_bounds` check.
	var min_x: int = maxi(ccx - radius, 0)
	var max_x: int = mini(ccx + radius, w - 1)
	var min_y: int = maxi(ccy - radius, 0)
	var max_y: int = mini(ccy + radius, h - 1)
	for gy in range(min_y, max_y + 1):
		var dy: int = gy - ccy
		var dy2: int = dy * dy
		var row_off: int = gy * w
		for gx in range(min_x, max_x + 1):
			var dx: int = gx - ccx
			var d2: float = float(dx * dx + dy2)
			if d2 > r2:
				continue
			var d: float = sqrt(d2)
			var intensity: float
			if d <= inner:
				intensity = 1.0
			else:
				intensity = 1.0 - (d - inner) / SIGHT_FADE_RANGE
				if intensity <= 0.0:
					continue
				if intensity > 1.0:
					intensity = 1.0
			var idx: int = row_off + gx
			if intensity > target[idx]:
				target[idx] = intensity
			# Explored only fires inside the inner ring so the soft
			# outer ring doesn't permanently fog cells the unit walked
			# past once.
			if intensity >= 0.6:
				_explored_bytes[idx] = 1


# ----- Render -----

func _draw() -> void:
	if disabled or _fog_mesh == null:
		return
	# Single GPU call regardless of map size. The mesh already encodes
	# the per-corner gradient, so there's no per-cell work in _draw.
	draw_mesh(_fog_mesh, null)


## Bakes the fog overlay into a quad mesh covering the current viewport
## plus a generous margin. Cost is bound by viewport size, not map size,
## so this stays cheap even on a fully-explored 200x200 map.
##
## Internals: a flat PackedFloat32Array indexed by `gy * stride + gx`
## stores per-cell alpha for the bake region. Corner sampling reads
## that array directly — no Dictionary[Vector2i] lookups, no lambda
## call overhead.
func _rebuild_fog_mesh() -> void:
	if main == null:
		return
	var w: int = main.GRID_WIDTH
	var h: int = main.GRID_HEIGHT
	if w <= 0 or h <= 0:
		_fog_mesh = null
		return
	var gs: float = float(main.GRID_SIZE)

	# Compute viewport-aligned grid bounds + margin.
	var camera := get_viewport().get_camera_2d()
	var grid_min := Vector2i(0, 0)
	var grid_max := Vector2i(w - 1, h - 1)
	if camera != null and gs > 0.0:
		var cam_center: Vector2 = camera.get_screen_center_position()
		var viewport_size: Vector2 = get_viewport_rect().size
		var cam_zoom: Vector2 = camera.zoom if camera.zoom != Vector2.ZERO else Vector2.ONE
		var half_view: Vector2 = viewport_size / (2.0 * cam_zoom)
		var view_min: Vector2 = cam_center - half_view
		var view_max: Vector2 = cam_center + half_view
		grid_min = main.world_to_grid(view_min) - Vector2i(FOG_BAKE_MARGIN, FOG_BAKE_MARGIN)
		grid_max = main.world_to_grid(view_max) + Vector2i(FOG_BAKE_MARGIN, FOG_BAKE_MARGIN)
		grid_min.x = clampi(grid_min.x, 0, w - 1)
		grid_min.y = clampi(grid_min.y, 0, h - 1)
		grid_max.x = clampi(grid_max.x, 0, w - 1)
		grid_max.y = clampi(grid_max.y, 0, h - 1)

	# Bake region stores cells from grid_min..=grid_max plus one extra
	# ring (so corner sampling at the edge can read off-region neighbours
	# without an `is_within_bounds` check per access). Cell alpha lives
	# in a flat float array — Dictionary[Vector2i] was the bottleneck.
	var rmin_x: int = grid_min.x - 1
	var rmin_y: int = grid_min.y - 1
	var rmax_x: int = grid_max.x + 1
	var rmax_y: int = grid_max.y + 1
	var stride: int = rmax_x - rmin_x + 1
	var rows: int = rmax_y - rmin_y + 1
	var cell_alpha: PackedFloat32Array = PackedFloat32Array()
	cell_alpha.resize(stride * rows)
	# Author-time darkness multiplier from Map Settings. Clamped so the
	# explored layer can't go fully opaque (defeats "explored memory")
	# and the slider can't brighten the unseen layer past full clear.
	var dark_mult: float = clampf(float(main.get("fog_darkness_mult")) if main and "fog_darkness_mult" in main else 1.0, 0.0, 2.0)
	var alpha_unseen: float = clampf(FOG_ALPHA_UNSEEN * dark_mult, 0.0, 1.0)
	var alpha_explored: float = clampf(FOG_ALPHA_EXPLORED * dark_mult, 0.0, 1.0)
	cell_alpha.fill(alpha_unseen)
	# Walk the bake region directly off the flat arrays. No
	# Dictionary[Vector2i] lookups, no per-cell allocation.
	var bake_min_y: int = maxi(rmin_y, 0)
	var bake_max_y: int = mini(rmax_y, h - 1)
	var bake_min_x: int = maxi(rmin_x, 0)
	var bake_max_x: int = mini(rmax_x, w - 1)
	for gy in range(bake_min_y, bake_max_y + 1):
		var grid_row: int = gy * w
		var local_row: int = (gy - rmin_y) * stride
		for gx in range(bake_min_x, bake_max_x + 1):
			var grid_idx: int = grid_row + gx
			var local_idx: int = local_row + (gx - rmin_x)
			var intensity: float = _visible[grid_idx]
			if intensity > 0.0:
				var base: float = alpha_explored if _explored_bytes[grid_idx] != 0 else alpha_unseen
				cell_alpha[local_idx] = base - base * intensity  # lerpf(base, 0, intensity)
			elif _explored_bytes[grid_idx] != 0:
				cell_alpha[local_idx] = alpha_explored

	# Walk only the bake region. Inline corner sampling — four direct
	# array reads per corner instead of a Callable invocation.
	var region_w: int = grid_max.x - grid_min.x + 1
	var region_h: int = grid_max.y - grid_min.y + 1
	var cap_cells: int = region_w * region_h
	if cap_cells <= 0:
		_fog_mesh = null
		return
	var verts: PackedVector3Array = PackedVector3Array()
	verts.resize(cap_cells * 4)
	var cols: PackedColorArray = PackedColorArray()
	cols.resize(cap_cells * 4)
	var idxs: PackedInt32Array = PackedInt32Array()
	idxs.resize(cap_cells * 6)
	var vi: int = 0
	var ii: int = 0
	# Pre-resolve the top-left local row offset to dodge a multiply
	# inside the hot loop.
	for gy in range(grid_min.y, grid_max.y + 1):
		var row_top: int = (gy - 1 - rmin_y) * stride
		var row_mid: int = (gy - rmin_y) * stride
		for gx in range(grid_min.x, grid_max.x + 1):
			var col_l: int = gx - 1 - rmin_x
			var col_r: int = gx - rmin_x
			# Each corner samples its 4 surrounding cells.
			var a_tl: float = (cell_alpha[row_top + col_l] + cell_alpha[row_top + col_r] + cell_alpha[row_mid + col_l] + cell_alpha[row_mid + col_r]) * 0.25
			var col_rr: int = gx + 1 - rmin_x
			var a_tr: float = (cell_alpha[row_top + col_r] + cell_alpha[row_top + col_rr] + cell_alpha[row_mid + col_r] + cell_alpha[row_mid + col_rr]) * 0.25
			var row_btm: int = (gy + 1 - rmin_y) * stride
			var a_br: float = (cell_alpha[row_mid + col_r] + cell_alpha[row_mid + col_rr] + cell_alpha[row_btm + col_r] + cell_alpha[row_btm + col_rr]) * 0.25
			var a_bl: float = (cell_alpha[row_mid + col_l] + cell_alpha[row_mid + col_r] + cell_alpha[row_btm + col_l] + cell_alpha[row_btm + col_r]) * 0.25
			if a_tl <= 0.001 and a_tr <= 0.001 and a_br <= 0.001 and a_bl <= 0.001:
				continue
			var x0: float = float(gx) * gs
			var y0: float = float(gy) * gs
			verts[vi + 0] = Vector3(x0, y0, 0.0)
			verts[vi + 1] = Vector3(x0 + gs, y0, 0.0)
			verts[vi + 2] = Vector3(x0 + gs, y0 + gs, 0.0)
			verts[vi + 3] = Vector3(x0, y0 + gs, 0.0)
			cols[vi + 0] = Color(0, 0, 0, a_tl)
			cols[vi + 1] = Color(0, 0, 0, a_tr)
			cols[vi + 2] = Color(0, 0, 0, a_br)
			cols[vi + 3] = Color(0, 0, 0, a_bl)
			idxs[ii + 0] = vi + 0
			idxs[ii + 1] = vi + 1
			idxs[ii + 2] = vi + 2
			idxs[ii + 3] = vi + 0
			idxs[ii + 4] = vi + 2
			idxs[ii + 5] = vi + 3
			vi += 4
			ii += 6
	if vi == 0:
		_fog_mesh = null
		return
	verts.resize(vi)
	cols.resize(vi)
	idxs.resize(ii)
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idxs
	_fog_mesh = ArrayMesh.new()
	_fog_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)


# ----- Public API -----

func is_visible_cell(cell: Vector2i) -> bool:
	if _grid_w <= 0 or cell.x < 0 or cell.y < 0 or cell.x >= _grid_w or cell.y >= _grid_h:
		return false
	return _visible[cell.y * _grid_w + cell.x] > 0.0


func is_explored_cell(cell: Vector2i) -> bool:
	if _grid_w <= 0 or cell.x < 0 or cell.y < 0 or cell.x >= _grid_w or cell.y >= _grid_h:
		return false
	return _explored_bytes[cell.y * _grid_w + cell.x] != 0


## Reveal a region permanently. Used by SaveManager on sector load and
## by gameplay events (e.g. archive scans, sector-wide reveal pickups).
func reveal_region(center: Vector2i, radius: int) -> void:
	_ensure_grid_arrays()
	_punch_circle_into_array(_visible, center.x, center.y, radius)


# ----- Save / load -----

func save_state() -> Dictionary:
	# Run-length encode the explored byte map: long stretches of "all
	# unseen" or "all explored" are common, so RLE shrinks the JSON
	# significantly compared to a per-cell coordinate list.
	var rle: Array = []
	if _grid_w > 0 and _grid_h > 0:
		var n: int = _grid_w * _grid_h
		var i: int = 0
		while i < n:
			var v: int = _explored_bytes[i]
			var j: int = i + 1
			while j < n and _explored_bytes[j] == v:
				j += 1
			rle.append([v, j - i])
			i = j
	return {"rle": rle, "w": _grid_w, "h": _grid_h}


func load_state(state: Dictionary) -> void:
	_ensure_grid_arrays()
	for i in range(_explored_bytes.size()):
		_explored_bytes[i] = 0
	# Back-compat with the old "explored": [[x, y], …] format.
	if state.has("explored"):
		var arr: Array = state.get("explored", [])
		for p in arr:
			if p is Array and p.size() >= 2:
				var x: int = int(p[0])
				var y: int = int(p[1])
				if x >= 0 and y >= 0 and x < _grid_w and y < _grid_h:
					_explored_bytes[y * _grid_w + x] = 1
	# New RLE format.
	if state.has("rle"):
		var saved_w: int = int(state.get("w", _grid_w))
		var saved_h: int = int(state.get("h", _grid_h))
		# Only restore when the saved grid matches; otherwise the index
		# math is meaningless. Mismatched maps just start fully unseen.
		if saved_w == _grid_w and saved_h == _grid_h:
			var idx: int = 0
			for entry in state["rle"]:
				if entry is Array and entry.size() >= 2:
					var v: int = int(entry[0])
					var run: int = int(entry[1])
					for _r in range(run):
						if idx >= _explored_bytes.size():
							break
						_explored_bytes[idx] = v
						idx += 1
	# Force a static rebuild on the next process tick — buildings just
	# got restored, so the cache from before the load is stale.
	_static_dirty = true
