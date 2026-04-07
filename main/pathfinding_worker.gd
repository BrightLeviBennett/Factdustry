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

# --- GRID CONFIG (set once at init) ---
var _grid_width: int
var _grid_height: int
var _grid_size: float

# --- QUEUES (protected by _mutex) ---
var _requests: Array[Dictionary] = []       # {unit_id, start, end, movement_layer, target_building_id}
var _results: Array[Dictionary] = []        # {unit_id, path, target_building_id}
var _mutations: Array[Dictionary] = []      # {type, pos, solid} or {type: "rebuild", solids, crawler_passable}
var _rebuild_pending: bool = false
var _rebuild_data: Dictionary = {}


func start(grid_width: int, grid_height: int, grid_size: float,
		ground_solids: Array[Vector2i], crawler_solids: Array[Vector2i],
		hover_solids: Array[Vector2i] = []) -> void:
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

	for pos in ground_solids:
		_astar.set_point_solid(pos, true)
	for pos in crawler_solids:
		_astar_crawler.set_point_solid(pos, true)
	for pos in hover_solids:
		_astar_hover.set_point_solid(pos, true)

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


func queue_set_solid(pos: Vector2i, solid: bool, grid_name: String = "ground") -> void:
	_mutex.lock()
	_mutations.append({"type": "point", "pos": pos, "solid": solid, "grid": grid_name})
	_mutex.unlock()


func queue_rebuild(ground_solids: Array[Vector2i], crawler_solids: Array[Vector2i],
		hover_solids: Array[Vector2i] = []) -> void:
	_mutex.lock()
	_rebuild_pending = true
	_rebuild_data = {"ground": ground_solids, "crawler": crawler_solids, "hover": hover_solids}
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


func _do_rebuild(rb_data: Dictionary) -> void:
	# Reset all points to non-solid, then re-mark
	_astar.fill_solid_region(Rect2i(0, 0, _grid_width, _grid_height), false)
	_astar_crawler.fill_solid_region(Rect2i(0, 0, _grid_width, _grid_height), false)
	_astar_hover.fill_solid_region(Rect2i(0, 0, _grid_width, _grid_height), false)

	for pos in rb_data["ground"]:
		_astar.set_point_solid(pos, true)
	for pos in rb_data["crawler"]:
		_astar_crawler.set_point_solid(pos, true)
	for pos in rb_data.get("hover", []):
		_astar_hover.set_point_solid(pos, true)


func _compute_path(req: Dictionary) -> Dictionary:
	var unit_id: int = req["unit_id"]
	var start: Vector2i = req["start"]
	var end: Vector2i = req["end"]
	var movement_layer: int = req["movement_layer"]
	var target_bldg_id: int = req["target_building_id"]

	# Select grid based on movement layer
	# 0 = GROUND, 1 = CRAWLER, 2 = HOVER, 3 = FLYING
	var grid: AStarGrid2D
	match movement_layer:
		1:
			grid = _astar_crawler
		2:
			grid = _astar_hover
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

	# If target cell is solid, find adjacent walkable
	if grid.is_point_solid(end):
		var adj := _find_adjacent_walkable(end, grid)
		if adj != Vector2i(-1, -1):
			end = adj
		else:
			return {"unit_id": unit_id, "path": PackedVector2Array(), "target_building_id": target_bldg_id}

	# If start cell is solid, find adjacent walkable
	if grid.is_point_solid(start):
		var adj := _find_adjacent_walkable(start, grid)
		if adj != Vector2i(-1, -1):
			start = adj
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


func _find_adjacent_walkable(grid_pos: Vector2i, grid: AStarGrid2D) -> Vector2i:
	var neighbors: Array[Vector2i] = [
		Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1),
	]
	for offset: Vector2i in neighbors:
		var neighbor: Vector2i = grid_pos + offset
		if neighbor.x >= 0 and neighbor.x < _grid_width and neighbor.y >= 0 and neighbor.y < _grid_height:
			if not grid.is_point_solid(neighbor):
				return neighbor
	return Vector2i(-1, -1)
