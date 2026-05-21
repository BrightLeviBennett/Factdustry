extends RefCounted
class_name FlowField

# ============================================================
# FLOW_FIELD.GD - Multi-agent gradient pathfinding
# ============================================================
# Given a target grid cell and an AStarGrid2D (for solidity), this
# computes a Chebyshev-distance flow field rooted at the target via
# BFS. Once built, any cell can cheaply trace a path back to the
# target by gradient descent — O(path_length) per agent, no priority
# queue.
#
# The grid uses DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES, so we mirror that
# here: diagonal steps require both orthogonal neighbours to be open.
#
# Usage:
#   var f = FlowField.new()
#   f.build(target, astar_grid, grid_width, grid_height, grid_size)
#   var next = f.next_cell(from_grid)       # one-step lookup
#   var path = f.trace_path(from_grid)      # PackedVector2Array
# ============================================================

static var _DIRS_X: PackedInt32Array = PackedInt32Array([ 1, -1,  0,  0,  1,  1, -1, -1])
static var _DIRS_Y: PackedInt32Array = PackedInt32Array([ 0,  0,  1, -1,  1, -1,  1, -1])
const _UNREACHABLE: int = 0x7FFFFFFF

var target: Vector2i = Vector2i(-1, -1)
var grid_width: int = 0
var grid_height: int = 0
var grid_size: float = 32.0
## Movement layer the field was built for (matches UnitData.MovementLayer).
var movement_layer: int = 0

## Flat width*height. _dist[y*w+x] = Chebyshev distance to target, or
## _UNREACHABLE.
var _dist: PackedInt32Array = PackedInt32Array()
## Flat width*height. _next_dir[i] = index into _DIRS_*, or 255 (none).
var _next_dir: PackedByteArray = PackedByteArray()


func _idx(x: int, y: int) -> int:
	return y * grid_width + x


## Build the field. `astar` is used purely for solidity (`is_point_solid`).
## Returns true if the target itself is walkable.
func build(target_cell: Vector2i, astar: AStarGrid2D, w: int, h: int, cell_size: float, move_layer: int = 0) -> bool:
	target = target_cell
	grid_width = w
	grid_height = h
	grid_size = cell_size
	movement_layer = move_layer

	var total: int = w * h
	_dist = PackedInt32Array()
	_dist.resize(total)
	_next_dir = PackedByteArray()
	_next_dir.resize(total)
	for i in range(total):
		_dist[i] = _UNREACHABLE
		_next_dir[i] = 255

	if target_cell.x < 0 or target_cell.y < 0 or target_cell.x >= w or target_cell.y >= h:
		return false

	# Seed: BFS root. If the actual target is solid, seed from each open
	# 8-neighbour so units still get a usable field (they path AROUND the
	# target). This matches the A* "find adjacent walkable" fallback.
	var queue: PackedInt32Array = PackedInt32Array()
	var qhead: int = 0
	var seed_cells: Array[Vector2i] = []
	if astar != null and astar.is_point_solid(target_cell):
		for d in range(8):
			var nx: int = target_cell.x + _DIRS_X[d]
			var ny: int = target_cell.y + _DIRS_Y[d]
			if nx < 0 or ny < 0 or nx >= w or ny >= h:
				continue
			if astar.is_point_solid(Vector2i(nx, ny)):
				continue
			seed_cells.append(Vector2i(nx, ny))
	else:
		seed_cells.append(target_cell)

	for seed in seed_cells:
		var si: int = _idx(seed.x, seed.y)
		if _dist[si] == 0:
			continue
		_dist[si] = 0
		_next_dir[si] = 255
		queue.append(si)

	if queue.is_empty():
		return false

	# Flood fill. Diagonal neighbours require both orthogonal openings
	# to mirror DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES.
	while qhead < queue.size():
		var idx: int = queue[qhead]
		qhead += 1
		var cy: int = idx / grid_width
		var cx: int = idx - cy * grid_width
		var cd: int = _dist[idx]
		var nd: int = cd + 1
		for d in range(8):
			var nx2: int = cx + _DIRS_X[d]
			var ny2: int = cy + _DIRS_Y[d]
			if nx2 < 0 or ny2 < 0 or nx2 >= grid_width or ny2 >= grid_height:
				continue
			var nidx: int = _idx(nx2, ny2)
			if _dist[nidx] <= nd:
				continue
			var npos: Vector2i = Vector2i(nx2, ny2)
			if astar != null and astar.is_point_solid(npos):
				continue
			# Diagonal: require both orthogonal openings.
			if d >= 4:
				var ox: Vector2i = Vector2i(cx + _DIRS_X[d], cy)
				var oy: Vector2i = Vector2i(cx, cy + _DIRS_Y[d])
				if astar != null and (astar.is_point_solid(ox) or astar.is_point_solid(oy)):
					continue
			_dist[nidx] = nd
			# Record direction FROM the neighbour back toward `cx,cy` —
			# i.e. the OPPOSITE of d.
			_next_dir[nidx] = _opposite(d)
			queue.append(nidx)

	return true


static func _opposite(d: int) -> int:
	# DIRS pairs: 0/1 (E/W), 2/3 (S/N), 4/7 (SE/NW), 5/6 (NE/SW)
	match d:
		0: return 1
		1: return 0
		2: return 3
		3: return 2
		4: return 7
		5: return 6
		6: return 5
		7: return 4
	return 255


func is_reachable(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= grid_width or cell.y >= grid_height:
		return false
	return _dist[_idx(cell.x, cell.y)] != _UNREACHABLE


func distance(cell: Vector2i) -> int:
	if cell.x < 0 or cell.y < 0 or cell.x >= grid_width or cell.y >= grid_height:
		return _UNREACHABLE
	return _dist[_idx(cell.x, cell.y)]


## Returns the next cell on the way to the target, or `cell` itself if
## the cell IS the target / unreachable.
func next_cell(cell: Vector2i) -> Vector2i:
	if cell.x < 0 or cell.y < 0 or cell.x >= grid_width or cell.y >= grid_height:
		return cell
	var i: int = _idx(cell.x, cell.y)
	var dir: int = _next_dir[i]
	if dir >= 8:
		return cell
	return Vector2i(cell.x + _DIRS_X[dir], cell.y + _DIRS_Y[dir])


## Trace a path from `from` to the field's target by gradient descent.
## Result is in world coordinates (cell centres). Empty when unreachable.
## `max_len` caps the trace to avoid pathological infinite loops if the
## field is malformed.
func trace_path(from: Vector2i, max_len: int = 512) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	if from.x < 0 or from.y < 0 or from.x >= grid_width or from.y >= grid_height:
		return out
	if _dist[_idx(from.x, from.y)] == _UNREACHABLE:
		return out
	var half: Vector2 = Vector2(grid_size * 0.5, grid_size * 0.5)
	var cur: Vector2i = from
	var steps: int = 0
	while steps < max_len:
		var i: int = _idx(cur.x, cur.y)
		var dir: int = _next_dir[i]
		if dir >= 8:
			# Reached the seed cell.
			out.append(Vector2(cur.x * grid_size, cur.y * grid_size) + half)
			break
		var nx: int = cur.x + _DIRS_X[dir]
		var ny: int = cur.y + _DIRS_Y[dir]
		out.append(Vector2(nx * grid_size, ny * grid_size) + half)
		cur = Vector2i(nx, ny)
		steps += 1
	return out
