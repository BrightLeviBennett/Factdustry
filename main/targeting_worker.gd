extends RefCounted
class_name TargetingWorker

# ============================================================
# TARGETING_WORKER.GD - Background Thread for Target Scanning
# ============================================================
# Handles two expensive scans off the main thread:
#   1. Turret auto-target: find nearest opposing unit/building
#   2. Player unit auto-target: find nearest enemy/FEROX building
#
# Main thread pushes a snapshot each frame; worker processes it
# and stores results for polling next frame.
# ============================================================

# --- THREAD ---
var _thread: Thread
var _semaphore: Semaphore
var _mutex: Mutex
var _running: bool = true

# --- SNAPSHOT (pushed by main thread) ---
var _snapshot: Dictionary = {}
var _has_snapshot: bool = false

# --- RESULTS (polled by main thread) ---
var _turret_results: Array[Dictionary] = []
var _unit_results: Array[Dictionary] = []


func start() -> void:
	_mutex = Mutex.new()
	_semaphore = Semaphore.new()
	_thread = Thread.new()
	_thread.start(_worker_loop)


func stop() -> void:
	_mutex.lock()
	_running = false
	_mutex.unlock()
	_semaphore.post()
	_thread.wait_to_finish()


# --- MAIN THREAD: push snapshot ---

## Call once per frame with current game state.
## snapshot keys:
##   "enemies": Array[Dict] - {id, pos, is_dead, unit_size}
##   "player_units": Array[Dict] - {id, pos, is_dead, unit_size}
##   "buildings": Dict[Vector2i, StringName] - placed_buildings copy
##   "factions": Dict[Vector2i, int] - building_factions copy
##   "origins": Dict[Vector2i, Vector2i] - building_origins copy
##   "turrets": Array[Dict] - {grid_pos, faction, range_pixels, block_id}
##   "idle_player_units": Array[Dict] - {id, pos, detect_range}
##   "grid_size": float
func push_snapshot(snapshot: Dictionary) -> void:
	_mutex.lock()
	_snapshot = snapshot
	_has_snapshot = true
	_mutex.unlock()
	_semaphore.post()


# --- MAIN THREAD: poll results ---

func poll_turret_results() -> Array[Dictionary]:
	_mutex.lock()
	var out: Array[Dictionary] = _turret_results.duplicate()
	_turret_results.clear()
	_mutex.unlock()
	return out


func poll_unit_results() -> Array[Dictionary]:
	_mutex.lock()
	var out: Array[Dictionary] = _unit_results.duplicate()
	_unit_results.clear()
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

		if not _has_snapshot:
			_mutex.unlock()
			continue

		var snap: Dictionary = _snapshot.duplicate(true)
		_has_snapshot = false
		_mutex.unlock()

		var t_results: Array[Dictionary] = _scan_turret_targets(snap)
		var u_results: Array[Dictionary] = _scan_unit_targets(snap)

		_mutex.lock()
		_turret_results = t_results
		_unit_results = u_results
		_mutex.unlock()


func _scan_turret_targets(snap: Dictionary) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var grid_size: float = snap["grid_size"]
	var half := Vector2(grid_size / 2.0, grid_size / 2.0)
	var buildings: Dictionary = snap["buildings"]
	var factions: Dictionary = snap["factions"]
	var origins: Dictionary = snap["origins"]
	var enemies: Array = snap["enemies"]
	var player_units: Array = snap["player_units"]
	var held_targets: Array = snap.get("held_targets", [])

	for turret_info in snap["turrets"]:
		var grid_pos: Vector2i = turret_info["grid_pos"]
		var turret_faction: int = turret_info["faction"]
		var range_pixels: float = turret_info["range_pixels"]
		var turret_world: Vector2 = Vector2(grid_pos.x * grid_size, grid_pos.y * grid_size) + half
		var range_sq: float = range_pixels * range_pixels

		var opposing_faction: int = 0 if turret_faction == 1 else 1

		# Find nearest opposing unit
		var opposing_units: Array = player_units if turret_faction == 1 else enemies
		var nearest_unit_id: int = -1
		var nearest_unit_pos := Vector2.ZERO
		var nearest_unit_dist_sq := INF

		for u in opposing_units:
			if u["is_dead"]:
				continue
			var d: float = turret_world.distance_squared_to(u["pos"])
			if d <= range_sq and d < nearest_unit_dist_sq:
				nearest_unit_dist_sq = d
				nearest_unit_id = u["id"]
				nearest_unit_pos = u["pos"]

		# Find nearest opposing building
		var nearest_bldg := Vector2i(-1, -1)
		var nearest_bldg_world := Vector2.ZERO
		var nearest_bldg_dist_sq := INF

		for bldg_pos in buildings:
			if bldg_pos == grid_pos:
				continue
			var bfaction: int = factions.get(bldg_pos, 0)
			if bfaction != opposing_faction:
				continue
			var anchor: Vector2i = origins.get(bldg_pos, bldg_pos)
			if anchor != bldg_pos:
				continue
			var bldg_world: Vector2 = Vector2(bldg_pos.x * grid_size, bldg_pos.y * grid_size) + half
			var d: float = turret_world.distance_squared_to(bldg_world)
			if d <= range_sq and d < nearest_bldg_dist_sq:
				nearest_bldg_dist_sq = d
				nearest_bldg = bldg_pos
				nearest_bldg_world = bldg_world

		# Find nearest opposing held entity (held buildings/units in
		# transit are valid targets — `target_type: "held"`).
		var nearest_held_anchor := Vector2i(-9999, -9999)
		var nearest_held_depth: int = 0
		var nearest_held_pos := Vector2.ZERO
		var nearest_held_dist_sq := INF
		for ht in held_targets:
			if int(ht["faction"]) != opposing_faction:
				continue
			var hp: Vector2 = ht["pos"]
			var dh: float = turret_world.distance_squared_to(hp)
			if dh <= range_sq and dh < nearest_held_dist_sq:
				nearest_held_dist_sq = dh
				nearest_held_anchor = ht["anchor"]
				nearest_held_depth = int(ht.get("depth", 0))
				nearest_held_pos = hp

		# Pick closest overall across units / buildings / held entities.
		var has_unit := nearest_unit_id != -1
		var has_bldg := nearest_bldg != Vector2i(-1, -1)
		var has_held := nearest_held_anchor != Vector2i(-9999, -9999)
		if not has_unit and not has_bldg and not has_held:
			continue

		var best_dist := INF
		var best_kind := ""
		if has_unit and nearest_unit_dist_sq < best_dist:
			best_dist = nearest_unit_dist_sq
			best_kind = "unit"
		if has_bldg and nearest_bldg_dist_sq < best_dist:
			best_dist = nearest_bldg_dist_sq
			best_kind = "building"
		if has_held and nearest_held_dist_sq < best_dist:
			best_dist = nearest_held_dist_sq
			best_kind = "held"

		if best_kind == "unit":
			results.append({
				"grid_pos": grid_pos,
				"target_type": "unit",
				"target_id": nearest_unit_id,
				"target_pos": nearest_unit_pos,
			})
		elif best_kind == "building":
			results.append({
				"grid_pos": grid_pos,
				"target_type": "building",
				"target_bldg": nearest_bldg,
				"target_pos": nearest_bldg_world,
			})
		else:
			results.append({
				"grid_pos": grid_pos,
				"target_type": "held",
				"target_anchor": nearest_held_anchor,
				"target_depth": nearest_held_depth,
				"target_pos": nearest_held_pos,
			})

	return results


func _scan_unit_targets(snap: Dictionary) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var grid_size: float = snap["grid_size"]
	var half := Vector2(grid_size / 2.0, grid_size / 2.0)
	var buildings: Dictionary = snap["buildings"]
	var factions: Dictionary = snap["factions"]
	var origins: Dictionary = snap["origins"]
	var enemies: Array = snap["enemies"]

	for unit_info in snap["idle_player_units"]:
		var unit_id: int = unit_info["id"]
		var unit_pos: Vector2 = unit_info["pos"]
		var detect_range: float = unit_info["detect_range"]

		# Find nearest enemy unit (we only need id + dist — pos was dead).
		var nearest_enemy_id: int = -1
		var nearest_enemy_dist := INF

		for e in enemies:
			if e["is_dead"]:
				continue
			var dist: float = unit_pos.distance_to(e["pos"])
			if dist <= detect_range and dist < nearest_enemy_dist:
				nearest_enemy_dist = dist
				nearest_enemy_id = e["id"]

		# Find nearest FEROX building
		var nearest_bldg := Vector2i(-1, -1)
		var nearest_bldg_dist := INF

		for grid_pos in buildings:
			var bfaction: int = factions.get(grid_pos, 0)
			if bfaction != 1:  # FEROX = 1
				continue
			var anchor: Vector2i = origins.get(grid_pos, grid_pos)
			if anchor != grid_pos:
				continue
			var bldg_world: Vector2 = Vector2(grid_pos.x * grid_size, grid_pos.y * grid_size) + half
			var dist: float = unit_pos.distance_to(bldg_world)
			if dist <= detect_range and dist < nearest_bldg_dist:
				nearest_bldg_dist = dist
				nearest_bldg = grid_pos

		# Pick closest
		var has_enemy := nearest_enemy_id != -1
		var has_bldg := nearest_bldg != Vector2i(-1, -1)
		if not has_enemy and not has_bldg:
			continue

		if has_enemy and has_bldg:
			if nearest_enemy_dist <= nearest_bldg_dist:
				results.append({"unit_id": unit_id, "target_type": "enemy", "target_id": nearest_enemy_id})
			else:
				results.append({"unit_id": unit_id, "target_type": "building", "target_bldg": nearest_bldg})
		elif has_enemy:
			results.append({"unit_id": unit_id, "target_type": "enemy", "target_id": nearest_enemy_id})
		else:
			results.append({"unit_id": unit_id, "target_type": "building", "target_bldg": nearest_bldg})

	return results
