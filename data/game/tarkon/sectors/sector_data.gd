@tool
class_name SectorData
extends Resource

# ============================================================
# SECTOR_DATA.GD - Defines a Campaign Sector
# ============================================================
# Each sector lives on a planet's surface. Its position is
# specified in latitude/longitude degrees:
#   latitude:  -90 (south pole) to +90 (north pole)
#   longitude: -180 (west) to +180 (east)
#   (0, 0) = front center of planet
# ============================================================

# --- IDENTITY ---
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var icon: Texture2D

# --- PLANET PLACEMENT ---
## Which planet this sector sits on (must match a PlanetData.id)
@export var planet_id: StringName = &""
## Hex grid column (axial Q coordinate).
## Even rows are flush left, odd rows offset right.
##   (0,0) = front center of planet.
##   Q increases rightward (east), R increases downward (south).
@export var hex_q: int = 0
## Hex grid row (axial R coordinate).
@export var hex_r: int = 0

# --- APPEARANCE ---
## Color for the hex marker on the planet surface
@export var color: Color = Color.GRAY

# --- RESOURCES ---
@export var available_resources: PackedStringArray = []

# --- ENEMIES ---
@export var waves: int = 0
@export var wave_units_data: PackedStringArray = []

# --- OBJECTIVES ---
enum Objective {
	DESTROY_ENEMY, SURVIVE_WAVES, DESTROY_BOSS,
}
@export var objective: Objective = Objective.DESTROY_ENEMY

# --- REWARDS ---
@export var unlocks: PackedStringArray = []

# --- PREREQUISITES ---
@export var required_sectors: PackedStringArray = []

# --- MAP ---
## Path to the .sector.json file that loads when this sector is played.
## e.g. "res://data/game/tarkon/maps/SG.sector.json"
@export_file("*.sector.json") var map_path: String = ""

# --- TAGS ---
@export var tags: PackedStringArray = []


# =========================
# HELPER METHODS
# =========================

func get_objective_text() -> String:
	match objective:
		Objective.DESTROY_ENEMY: return "Destroy all enemy bases"
		Objective.SURVIVE_WAVES: return "Survive %d waves" % waves
		Objective.DESTROY_BOSS: return "Defeat the boss"
	return "Unknown"


## Converts hex grid (q, r) to a 3D point on the sphere.
## marker_radius is the hex circumradius — tiling distance is
## calculated from it so hexes sit perfectly edge-to-edge.
func get_surface_position(radius: float, marker_radius: float) -> Vector3:
	# Pointy-top axial → surface arc lengths:
	#   sqrt(3) * marker_radius = exact hex width = horizontal center spacing
	#   1.5 * marker_radius = exact vertical row spacing
	var x = marker_radius * (sqrt(3.0) * hex_q + sqrt(3.0) / 2.0 * hex_r)
	var y = marker_radius * (1.5 * hex_r)

	# Convert y arc to latitude
	var lat = clamp(-rad_to_deg(y / radius), -89.0, 89.0)
	var lat_r = deg_to_rad(lat)

	# Area-preserving longitude: stretch x by 1/cos(lat) so hexes stay
	# the same visual size at all latitudes instead of compressing near poles
	var cos_lat = cos(lat_r)
	var adjusted_x = x / maxf(cos_lat, 0.05)
	var lon = rad_to_deg(adjusted_x / radius)
	var lon_r = deg_to_rad(lon)

	return Vector3(
		radius * cos_lat * sin(lon_r),
		radius * sin(lat_r),
		radius * cos_lat * cos(lon_r)
	)
