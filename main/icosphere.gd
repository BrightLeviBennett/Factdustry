class_name Icosphere

# ============================================================
# ICOSPHERE.GD — Goldberg Polyhedron Grid Generator
# ============================================================
# Generates uniformly-spaced points on a sphere by subdividing
# an icosahedron. Can also produce the dual mesh (hex/pentagon
# cells) for Mindustry-style sector grids.
#
# Usage:
#   var ico = Icosphere.generate(2, 3.06)
#   var dual = Icosphere.generate_dual_mesh(ico, 3.06)
# ============================================================


## Result of icosphere generation: vertices, faces, and pentagon indices.
class IcosphereResult:
	var vertices: PackedVector3Array
	var faces: Array  # Array of [int, int, int] — triangle vertex indices
	var pentagon_indices: Array[int]  # The 12 original icosahedron vertex indices


## Result of dual mesh generation: hex/pentagon cells on the sphere.
class DualMeshResult:
	var cell_centers: PackedVector3Array       # One per cell (= icosphere vertex), on sphere surface
	var cell_polygons: Array                   # Array[PackedVector3Array] — corner positions in winding order
	var cell_neighbor_indices: Array           # Array[PackedInt32Array] — adjacent cell indices
	var pentagon_indices: Array[int]           # Which cells are pentagons (degree 5)


## Generate icosphere vertices and faces at the given subdivision level and radius.
static func generate(subdivisions: int, radius: float) -> IcosphereResult:
	# Golden ratio
	var phi: float = (1.0 + sqrt(5.0)) / 2.0

	# 12 vertices of a unit icosahedron
	var verts: PackedVector3Array = PackedVector3Array()
	var raw: Array[Vector3] = [
		Vector3(-1,  phi, 0), Vector3( 1,  phi, 0),
		Vector3(-1, -phi, 0), Vector3( 1, -phi, 0),
		Vector3(0, -1,  phi), Vector3(0,  1,  phi),
		Vector3(0, -1, -phi), Vector3(0,  1, -phi),
		Vector3( phi, 0, -1), Vector3( phi, 0,  1),
		Vector3(-phi, 0, -1), Vector3(-phi, 0,  1),
	]
	for v in raw:
		verts.append(v.normalized() * radius)

	# 20 triangular faces of icosahedron (vertex index triples)
	var faces: Array = [
		[0, 11, 5],  [0, 5, 1],  [0, 1, 7],   [0, 7, 10],  [0, 10, 11],
		[1, 5, 9],   [5, 11, 4], [11, 10, 2],  [10, 7, 6],  [7, 1, 8],
		[3, 9, 4],   [3, 4, 2],  [3, 2, 6],    [3, 6, 8],   [3, 8, 9],
		[4, 9, 5],   [2, 4, 11], [6, 2, 10],   [8, 6, 7],   [9, 8, 1],
	]

	# The first 12 vertices are always the pentagon positions
	var pentagon_indices: Array[int] = []
	for i in range(12):
		pentagon_indices.append(i)

	# Subdivide
	var midpoint_cache: Dictionary = {}
	for _step in range(subdivisions):
		var new_faces: Array = []
		for face in faces:
			var a: int = _get_midpoint(midpoint_cache, verts, face[0], face[1], radius)
			var b: int = _get_midpoint(midpoint_cache, verts, face[1], face[2], radius)
			var c: int = _get_midpoint(midpoint_cache, verts, face[2], face[0], radius)
			new_faces.append([face[0], a, c])
			new_faces.append([face[1], b, a])
			new_faces.append([face[2], c, b])
			new_faces.append([a, b, c])
		faces = new_faces

	var result := IcosphereResult.new()
	result.vertices = verts
	result.faces = faces
	result.pentagon_indices = pentagon_indices
	return result


## Generate the dual mesh (hex/pentagon cells) from an icosphere result.
## Each icosphere vertex becomes a cell center; each triangle face becomes a cell corner.
## relax_iterations: number of Lloyd relaxation passes to even out cell shapes (0 = none).
static func generate_dual_mesh(ico: IcosphereResult, radius: float, relax_iterations: int = 20) -> DualMeshResult:
	var verts := ico.vertices.duplicate()
	var faces := ico.faces
	var vert_count := verts.size()

	# 1. Build neighbor list (needed for relaxation)
	var neighbor_set: Array = []
	neighbor_set.resize(vert_count)
	for i in range(vert_count):
		neighbor_set[i] = {}
	for face in faces:
		var a: int = face[0]
		var b: int = face[1]
		var c: int = face[2]
		neighbor_set[a][b] = true
		neighbor_set[a][c] = true
		neighbor_set[b][a] = true
		neighbor_set[b][c] = true
		neighbor_set[c][a] = true
		neighbor_set[c][b] = true

	var cell_neighbors: Array = []
	cell_neighbors.resize(vert_count)
	for i in range(vert_count):
		var arr := PackedInt32Array()
		for key in neighbor_set[i]:
			arr.append(key)
		cell_neighbors[i] = arr

	# 2. Lloyd relaxation: move each vertex toward the centroid of its neighbors
	for _iter in range(relax_iterations):
		var new_verts := PackedVector3Array()
		new_verts.resize(vert_count)
		for i in range(vert_count):
			var neighbors: PackedInt32Array = cell_neighbors[i]
			if neighbors.is_empty():
				new_verts[i] = verts[i]
				continue
			var centroid := Vector3.ZERO
			for nb in neighbors:
				centroid += verts[nb]
			centroid /= float(neighbors.size())
			# Project back onto sphere
			new_verts[i] = centroid.normalized() * radius
		verts = new_verts

	# 3. Build vertex → face adjacency
	var vert_faces: Array = []
	vert_faces.resize(vert_count)
	for i in range(vert_count):
		vert_faces[i] = PackedInt32Array()
	for fi in range(faces.size()):
		var face = faces[fi]
		vert_faces[face[0]].append(fi)
		vert_faces[face[1]].append(fi)
		vert_faces[face[2]].append(fi)

	# 4. Compute face centroids from relaxed vertices (projected onto sphere)
	var centroids := PackedVector3Array()
	centroids.resize(faces.size())
	for fi in range(faces.size()):
		var face = faces[fi]
		var c: Vector3 = (verts[face[0]] + verts[face[1]] + verts[face[2]]) / 3.0
		centroids[fi] = c.normalized() * radius

	# 5. For each vertex (cell), sort surrounding face centroids in angular winding order
	var cell_polygons: Array = []
	cell_polygons.resize(vert_count)
	for vi in range(vert_count):
		var face_indices: PackedInt32Array = vert_faces[vi]
		var normal: Vector3 = verts[vi].normalized()

		# Build tangent-plane basis
		var up := Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		var tangent_x: Vector3 = normal.cross(up).normalized()
		var tangent_y: Vector3 = tangent_x.cross(normal).normalized()

		# Project centroids onto tangent plane and sort by angle
		var angle_data: Array = []
		for fi in face_indices:
			var rel: Vector3 = centroids[fi] - verts[vi]
			var px: float = rel.dot(tangent_x)
			var py: float = rel.dot(tangent_y)
			angle_data.append([atan2(py, px), fi])
		angle_data.sort_custom(func(a, b): return a[0] < b[0])

		var polygon := PackedVector3Array()
		for entry in angle_data:
			polygon.append(centroids[entry[1]])
		cell_polygons[vi] = polygon

	var result := DualMeshResult.new()
	result.cell_centers = verts
	result.cell_polygons = cell_polygons
	result.cell_neighbor_indices = cell_neighbors
	result.pentagon_indices = ico.pentagon_indices
	return result


## Find or create the midpoint vertex between two existing vertices.
static func _get_midpoint(cache: Dictionary, verts: PackedVector3Array, i1: int, i2: int, radius: float) -> int:
	var key: int = mini(i1, i2) * 100000 + maxi(i1, i2)
	if cache.has(key):
		return cache[key]
	var mid: Vector3 = ((verts[i1] + verts[i2]) / 2.0).normalized() * radius
	var idx: int = verts.size()
	verts.append(mid)
	cache[key] = idx
	return idx


# =========================================================================
# HILLY MESH (Mindustry-style planet surface)
# =========================================================================

## Result of `build_hilly_mesh`: a renderable ArrayMesh plus the per-cell
## elevation buffer (handy for gameplay queries — biome tagging, hover
## elevation readouts, etc.).
class HillyMeshResult:
	var mesh: ArrayMesh
	## Length == dual.cell_centers.size().
	var cell_elevations: PackedFloat32Array


## Builds a renderable mesh from a `DualMeshResult` where each cell is
## displaced outward by 3D-noise-derived elevation. Corners shared by
## multiple cells average the touching cells' elevations, giving the
## soft rolling-hills look (rather than faceted cliffs).
##
## Each cell is drawn as a triangle fan from its (displaced) centre to
## its (displaced) corners. Normals are accumulated per-triangle and
## averaged at shared corners for smooth shading.
##
## Args:
##   dual         — the Goldberg dual already built via generate_dual_mesh
##   radius       — the planet's base radius (must match the dual's radius)
##   noise_seed   — seed for the elevation noise (per-planet so different
##                  worlds look different)
##   noise_freq   — 3D-space frequency. 0.6..1.4 is a reasonable range for
##                  unit-sphere noise. Higher = smaller, more frequent hills.
##   amplitude    — how far the hills extrude from the surface, in world units.
##   octaves      — fractal layers for richer terrain. 3..5 is good.
##   sea_level    — values below this are clamped to 0 (flat ocean).
static func build_hilly_mesh(
	dual: DualMeshResult,
	radius: float,
	noise_seed: int = 0,
	noise_freq: float = 0.9,
	amplitude: float = 0.18,
	octaves: int = 4,
	sea_level: float = 0.42,
) -> HillyMeshResult:
	# Mindustry-style faceted terrain (see Anuken/Mindustry
	# MeshBuilder.buildHex): per-corner heights from continuous 3D
	# noise, each tile filled by triangulating its corners as a fan
	# from corner[0] with ONE flat normal per tile — gives the
	# iconic low-poly hex-cliff look.
	var n_cells: int = dual.cell_centers.size()

	# --- 1. Dedupe corners by position. Identical face centroids
	# from `generate_dual_mesh` are bit-identical Vector3s so a direct
	# Dictionary lookup works without an epsilon search.
	var corner_id: Dictionary = {}
	var corner_pos: PackedVector3Array = PackedVector3Array()
	var cell_corner_ids: Array = []
	cell_corner_ids.resize(n_cells)
	for ci in range(n_cells):
		var poly: PackedVector3Array = dual.cell_polygons[ci]
		var ids: PackedInt32Array = PackedInt32Array()
		for p in poly:
			if not corner_id.has(p):
				corner_id[p] = corner_pos.size()
				corner_pos.append(p)
			ids.append(corner_id[p])
		cell_corner_ids[ci] = ids

	# --- 2. Per-corner heights from fractal 3D simplex noise.
	# Below `sea_level` clamps to 0 (flat oceans/plains); above it
	# ramps to 1 at the noise peak. Multiplied into `amplitude` for
	# the actual radial displacement.
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = noise_freq
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5
	noise.seed = noise_seed
	var n_corners: int = corner_pos.size()
	var corner_height: PackedFloat32Array = PackedFloat32Array()
	corner_height.resize(n_corners)
	var corner_world: PackedVector3Array = PackedVector3Array()
	corner_world.resize(n_corners)
	for cid in range(n_corners):
		var d: Vector3 = corner_pos[cid].normalized()
		var raw: float = noise.get_noise_3d(d.x, d.y, d.z) * 0.5 + 0.5
		var h: float = 0.0
		if raw > sea_level:
			h = (raw - sea_level) / (1.0 - sea_level)
		corner_height[cid] = h
		corner_world[cid] = d * (radius + h * amplitude)

	# --- 3. Per-cell elevation for gameplay queries — mean of
	# corner heights, parallel to dual.cell_centers.
	var elev: PackedFloat32Array = PackedFloat32Array()
	elev.resize(n_cells)
	for ci in range(n_cells):
		var ids: PackedInt32Array = cell_corner_ids[ci]
		var s: float = 0.0
		for cid in ids:
			s += corner_height[cid]
		elev[ci] = s / max(1, ids.size())

	# --- 4. Emit triangles per tile, flat shaded.
	# One flat normal per tile (computed from corners 0, 2, 4 like
	# Mindustry's MeshBuilder.buildHex). Each tile gets its own
	# vertex copies so the normal isn't shared with neighbours —
	# this is what produces the visible cliff edges between cells.
	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var idxs: PackedInt32Array = PackedInt32Array()
	for ci in range(n_cells):
		var ids: PackedInt32Array = cell_corner_ids[ci]
		var nc: int = ids.size()
		if nc < 3:
			continue
		var v0: Vector3 = corner_world[ids[0]]
		var v2: Vector3 = corner_world[ids[2 % nc]]
		var v4: Vector3 = corner_world[ids[4 % nc]]
		var face_n: Vector3 = (v2 - v0).cross(v4 - v0)
		if face_n.length_squared() <= 0.0:
			face_n = dual.cell_centers[ci].normalized()
		else:
			face_n = face_n.normalized()
			if face_n.dot(dual.cell_centers[ci].normalized()) < 0.0:
				face_n = -face_n
		var base_idx: int = verts.size()
		for ki in range(nc):
			verts.append(corner_world[ids[ki]])
			normals.append(face_n)
			uvs.append(_latlon_uv(corner_pos[ids[ki]].normalized()))
		# Fan triangulation from local index 0:
		# (0,1,2), (0,2,3), (0,3,4), (0,4,5)
		for ki in range(1, nc - 1):
			idxs.append(base_idx)
			idxs.append(base_idx + ki)
			idxs.append(base_idx + ki + 1)

	# --- 5. Build the ArrayMesh ---
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idxs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)

	var out := HillyMeshResult.new()
	out.mesh = mesh
	out.cell_elevations = elev
	return out


## Lat/lon equirectangular UV for a unit-sphere direction. Matches the
## convention used by the planet shader's procedural NoiseTexture2D
## sample (lon → U, lat → V).
static func _latlon_uv(dir: Vector3) -> Vector2:
	var lon: float = atan2(dir.x, dir.z)
	var lat: float = asin(clampf(dir.y, -1.0, 1.0))
	return Vector2(lon / TAU + 0.5, lat / PI + 0.5)
