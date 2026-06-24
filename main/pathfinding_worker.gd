extends RefCounted
class_name PathfindingWorker

# ============================================================
# PATHFINDING_WORKER.GD - Background Thread for A* Pathfinding
# ============================================================
# Owns duplicate AStarGrid2D instances (ground + crawler).
# Main thread pushes path requests and grid mutations;
# worker thread processes them and stores results for polling.
# ============================================================

# --- THREAD ---
var _thread: Thread
var _semaphore: Semaphore
var _mutex: Mutex
var _running: bool = true

# --- DUPLICATE GRIDS (owned by worker thread) ---
var _astar: AStarGrid2D
var _astar_crawler: AStarGrid2D
var _astar_hover: AStarGrid2D
var _astar_naval: AStarGrid2D

# --- GRID CONFIG (set once at init) ---
var _grid_width: int
var _grid_height: int
var _grid_size: float

# --- QUEUES (protected by _mutex) ---
var _requests: Array[Dictionary] = []       # {unit_id, start, end, movement_layer, target_building_id}
var _results: Array[Dictionary] = []        # {unit_id, path, target_building_id}
var _flow_requests: Array[Dictionary] = []  # {target, ml, key, generation}
var _flow_results: Array[Dictionary] = []   # {key, field, generation}
var _mutations: Array[Dictionary] = []      # {type, pos, solid} or {type: "rebuild", solids, crawler_passable}
var _rebuild_pending: bool = false
var _rebuild_data: Dictionary = {}


func start(grid_width: int, grid_height: int, grid_size: float,
		ground_solids: Array[Vector2i], crawler_solids: Array[Vector2i],
		hover_solids: Array[Vector2i] = [],
		ground_weights: Array = [], crawler_weights: Array = [],
		naval_solids: Array[Vector2i] = []) -> void:
	_grid_width = grid_width
	_grid_height = grid_height
	_grid_size = grid_size

	_mutex = Mutex.new()
	_semaphore = Semaphore.new()

	# Build initial grids on main thread (before worker starts)
	_astar = AStarGrid2D.new()
	_astar.region = Rect2i(0, 0, grid_width, grid_height)
	_astar.cell_size = Vector2(grid_size, grid_size)
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar.update()

	_astar_crawler = AStarGrid2D.new()
	_astar_crawler.region = Rect2i(0, 0, grid_width, grid_height)
	_astar_crawler.cell_size = Vector2(grid_size, grid_size)
	_astar_crawler.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar_crawler.update()

	_astar_hover = AStarGrid2D.new()
	_astar_hover.region = Rect2i(0, 0, grid_width, grid_height)
	_astar_hover.cell_size = Vector2(grid_size, grid_size)
	_astar_hover.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar_hover.update()

	_astar_naval = AStarGrid2D.new()
	_astar_naval.region = Rect2i(0, 0, grid_width, grid_height)
	_astar_naval.cell_size = Vector2(grid_size, grid_size)
	_astar_naval.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar_naval.update()

	for pos in ground_solids:
		_astar.set_point_solid(pos, true)
	for pos in crawler_solids:
		_astar_crawler.set_point_solid(pos, true)
	for pos in hover_solids:
		_astar_hover.set_point_solid(pos, true)
	for pos in naval_solids:
		_astar_naval.set_point_solid(pos, true)
	# Per-cell weight scales (water bias). Each entry: [Vector2i, float].
	for w in ground_weights:
		_astar.set_point_weight_scale(w[0], float(w[1]))
	for w in crawler_weights:
		_astar_crawler.set_point_weight_scale(w[0], float(w[1]))

	_thread = Thread.new()
	_thread.start(_worker_loop)


func stop() -> void:
	_mutex.lock()
	_running = false
	_mutex.unlock()
	_semaphore.post()
	_thread.wait_to_finish()


# --- MAIN THREAD: push requests ---

func request_path(unit_id: int, start: Vector2i, end: Vector2i,
		movement_layer: int, target_building_id: int) -> void:
	_mutex.lock()
	_requests.append({
		"unit_id": unit_id,
		"start": start,
		"end": end,
		"movement_layer": movement_layer,
		"target_building_id": target_building_id,
	})
	_mutex.unlock()
	_semaphore.post()


## Queue a flow-field build on the worker thread. `key`/`generation` are echoed
## back in the result so the main thread can match it to its cache and discard
## stale fields (built against a since-changed grid).
func request_flow_field(target: Vector2i, ml: int, key: String, generation: int) -> void:
	_mutex.lock()
	_flow_requests.append({"target": target, "ml": ml, "key": key, "generation": generation})
	_mutex.unlock()
	_semaphore.post()


func poll_flow_results() -> Array[Dictionary]:
	_mutex.lock()
	var out: Array[Dictionary] = _flow_results.duplicate()
	_flow_results.clear()
	_mutex.unlock()
	return out


func _astar_for_layer(ml: int) -> AStarGrid2D:
	match ml:
		1: return _astar_crawler
		2: return _astar_hover
		4: return _astar_naval
		3: return null    # flying — no field needed
		_: return _astar


func queue_set_solid(pos: Vector2i, solid: bool, grid_name: String = "ground") -> void:
	_mutex.lock()
	_mutations.append({"type": "point", "pos": pos, "solid": solid, "grid": grid_name})
	_mutex.unlock()


## Queue a per-cell weight scale change. Used by the water-bias system
## to make A* prefer longer dry routes over wading straight through a
## lake while still allowing the crossing when no dry route exists.
func queue_set_weight(pos: Vector2i, weight: float, grid_name: String = "ground") -> void:
	_mutex.lock()
	_mutations.append({"type": "weight", "pos": pos, "weight": weight, "grid": grid_name})
	_mutex.unlock()


func queue_rebuild(ground_solids: Array[Vector2i], crawler_solids: Array[Vector2i],
		hover_solids: Array[Vector2i] = [], naval_solids: Array[Vector2i] = []) -> void:
	_mutex.lock()
	_rebuild_pending = true
	_rebuild_data = {"ground": ground_solids, "crawler": crawler_solids, "hover": hover_solids, "naval": naval_solids}
	_mutex.unlock()


# --- MAIN THREAD: poll results ---

func poll_results() -> Array[Dictionary]:
	_mutex.lock()
	var out: Array[Dictionary] = _results.duplicate()
	_results.clear()
	_mutex.unlock()
	return out


# --- WORKER THREAD ---

func _worker_loop() -> void:
	while true:
		_semaphore.wait()

		_mutex.lock()
		if not _running:
			_mutex.unlock()
			return

		# Apply grid mutations first
		var muts: Array[Dictionary] = _mutations.duplicate()
		_mutations.clear()
		var do_rebuild: bool = _rebuild_pending
		var rb_data: Dictionary = _rebuild_data.duplicate(true)
		_rebuild_pending = false

		# Grab all pending requests
		var reqs: Array[Dictionary] = _requests.duplicate()
		_requests.clear()
		var flow_reqs: Array[Dictionary] = _flow_requests.duplicate()
		_flow_requests.clear()
		_mutex.unlock()

		# Apply mutations
		if do_rebuild:
			_do_rebuild(rb_data)
		else:
			for m in muts:
				var grid_name: String = m.get("grid", "ground")
				var grid: AStarGrid2D
				match grid_name:
					"crawler":
						grid = _astar_crawler
					"hover":
						grid = _astar_hover
					_:
						grid = _astar
				match m.get("type", "point"):
					"weight":
						grid.set_point_weight_scale(m["pos"], float(m["weight"]))
					_:
						grid.set_point_solid(m["pos"], m["solid"])

		# Process path requests
		var batch_results: Array[Dictionary] = []
		for req in reqs:
			var result := _compute_path(req)
			batch_results.append(result)

		if batch_results.size() > 0:
			_mutex.lock()
			_results.append_array(batch_results)
			_mutex.unlock()

		# Build flow fields (off the main thread). Grids were just mutated above,
		# so fields reflect the current map. Dedupe by key within the batch.
		if flow_reqs.size() > 0:
			var flow_batch: Array[Dictionary] = []
			var built_keys: Dictionary = {}
			for fr in flow_reqs:
				var fkey: String = fr["key"]
				if built_keys.has(fkey):
					continue
				built_keys[fkey] = true
				var grid: AStarGrid2D = _astar_for_layer(int(fr["ml"]))
				if grid == null:
					continue
				var field := FlowField.new()
				field.build(fr["target"], grid, _grid_width, _grid_height, _grid_size, int(fr["ml"]))
				flow_batch.append({"key": fkey, "field": field, "generation": int(fr["generation"])})
			if flow_batch.size() > 0:
				_mutex.lock()
				_flow_results.append_array(flow_batch)
				_mutex.unlock()


func _do_rebuild(rb_data: Dictionary) -> void:
	# Reset all points to non-solid, then re-mark
	_astar.fill_solid_region(Rect2i(0, 0, _grid_width, _grid_height), false)
	_astar_crawler.fill_solid_region(Rect2i(0, 0, _grid_width, _grid_height), false)
	_astar_hover.fill_solid_region(Rect2i(0, 0, _grid_width, _grid_height), false)
	_astar_naval.fill_solid_region(Rect2i(0, 0, _grid_width, _grid_height), false)

	for pos in rb_data["ground"]:
		_astar.set_point_solid(pos, true)
	for pos in rb_data["crawler"]:
		_astar_crawler.set_point_solid(pos, true)
	for pos in rb_data.get("hover", []):
		_astar_hover.set_point_solid(pos, true)
	for pos in rb_data.get("naval", []):
		_astar_naval.set_point_solid(pos, true)

	# Water bias: per-cell weight overrides so A* prefers dry routes
	# but still treats water as crossable. Keyed by grid → array of
	# [pos, weight] pairs. Hover doesn't participate (water is free
	# for hover).
	var ground_weights: Array = rb_data.get("ground_weights", [])
	for w in ground_weights:
		_astar.set_point_weight_scale(w[0], float(w[1]))
	var crawler_weights: Array = rb_data.get("crawler_weights", [])
	for w in crawler_weights:
		_astar_crawler.set_point_weight_scale(w[0], float(w[1]))


func _compute_path(req: Dictionary) -> Dictionary:
	var unit_id: int = req["unit_id"]
	var start: Vector2i = req["start"]
	var end: Vector2i = req["end"]
	var movement_layer: int = req["movement_layer"]
	var target_bldg_id: int = req["target_building_id"]

	# Select grid based on movement layer
	# 0 = GROUND, 1 = CRAWLER, 2 = HOVER, 3 = FLYING, 4 = NAVAL
	var grid: AStarGrid2D
	match movement_layer:
		1:
			grid = _astar_crawler
		2:
			grid = _astar_hover
		4:
			grid = _astar_naval
		_:
			grid = _astar
	var half := Vector2(_grid_size / 2.0, _grid_size / 2.0)

	# Flying: direct path, no obstacles
	if movement_layer == 3:
		var target_world: Vector2 = Vector2(end.x * _grid_size, end.y * _grid_size) + half
		return {
			"unit_id": unit_id,
			"path": PackedVector2Array([target_world]),
			"target_building_id": target_bldg_id,
		}

	# Clamp positions
	start.x = clampi(start.x, 0, _grid_width - 1)
	start.y = clampi(start.y, 0, _grid_height - 1)
	end.x = clampi(end.x, 0, _grid_width - 1)
	end.y = clampi(end.y, 0, _grid_height - 1)

	# If start cell is solid, find adjacent walkable
	if grid.is_point_solid(start):
		var adj := _find_adjacent_walkable(start, grid)
		if adj != Vector2i(-1, -1):
			start = adj
		else:
			return {"unit_id": unit_id, "path": PackedVector2Array(), "target_building_id": target_bldg_id}

	# If target cell is solid, pick a nearby open cell that is reachable
	# from this start. A sealed base can have open cells on the inside of
	# the wall; choosing one of those makes A* return an empty path and the
	# attacker appears to give up instead of chewing through the wall.
	if grid.is_point_solid(end):
		var adj := _find_reachable_walkable_near(end, start, grid)
		if adj != Vector2i(-1, -1):
			end = adj
		else:
			return {"unit_id": unit_id, "path": PackedVector2Array(), "target_building_id": target_bldg_id}

	var id_path := grid.get_point_path(start, end)
	var world_path := PackedVector2Array()
	for point in id_path:
		world_path.append(point + half)

	return {
		"unit_id": unit_id,
		"path": world_path,
		"target_building_id": target_bldg_id,
	}


## Finds the nearest non-solid cell to `grid_pos` by scanning outward in
## Chebyshev rings. Ground/crawler/hover units almost always hit on ring 1 (a
## building has walkable land right next to it), so their behaviour is unchanged.
## NAVAL units attacking an inland base have NO navigable water in the immediate
## ring — without searching outward they'd get an empty path and never move — so
## this walks out to the nearest water cell, which their long-range weapons can
## bombard the target from. Bounded by `max_radius` so a target with no walkable
## cell anywhere nearby still returns quickly.
func _find_adjacent_walkable(grid_pos: Vector2i, grid: AStarGrid2D, max_radius: int = 48) -> Vector2i:
	for r: int in range(1, max_radius + 1):
		var best := Vector2i(-1, -1)
		var best_d: float = 1.0e20
		for dx: int in range(-r, r + 1):
			for dy: int in range(-r, r + 1):
				# Only the cells on the current ring's perimeter.
				if maxi(abs(dx), abs(dy)) != r:
					continue
				var n: Vector2i = grid_pos + Vector2i(dx, dy)
				if n.x < 0 or n.x >= _grid_width or n.y < 0 or n.y >= _grid_height:
					continue
				if grid.is_point_solid(n):
					continue
				var d: float = float(dx * dx + dy * dy)
				if d < best_d:
					best_d = d
					best = n
		if best != Vector2i(-1, -1):
			return best
	return Vector2i(-1, -1)


func _find_reachable_walkable_near(grid_pos: Vector2i, start: Vector2i,
		grid: AStarGrid2D, max_radius: int = 48) -> Vector2i:
	for r: int in range(1, max_radius + 1):
		var candidates: Array[Vector2i] = []
		for dx: int in range(-r, r + 1):
			for dy: int in range(-r, r + 1):
				if maxi(abs(dx), abs(dy)) != r:
					continue
				var n: Vector2i = grid_pos + Vector2i(dx, dy)
				if n.x < 0 or n.x >= _grid_width or n.y < 0 or n.y >= _grid_height:
					continue
				if grid.is_point_solid(n):
					continue
				candidates.append(n)
		candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return start.distance_squared_to(a) < start.distance_squared_to(b)
		)
		for n in candidates:
			if n == start:
				return n
			if grid.get_point_path(start, n).size() > 0:
				return n
	return Vector2i(-1, -1)
