@tool
class_name PlanetData
extends Resource

# ============================================================
# PLANET_DATA.GD - Defines a Campaign Planet
# ============================================================
# Each planet orbits the sun at a configurable distance/angle.
# All planets are visible simultaneously in the solar system.
# Sectors are placed on each planet's surface via lat/lon.
#
# ORBIT: orbit_distance = how far from the sun (3D units).
#        orbit_angle = degrees around the sun (0=front, 90=right).
#
# TEXTURE: Set surface_texture for a hand-made texture, or
#          leave null for procedural noise generation.
# ============================================================

# --- IDENTITY ---
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
## Icon displayed next to the planet name in the planet switcher
@export var icon: Texture2D = null

# --- ORBIT ---
## Distance from the orbit center (sun, or parent planet if set) in 3D units
@export var orbit_distance: float = 12.0
## Angle around the orbit center in degrees (0=front, 90=right, 180=back)
@export_range(0.0, 360.0, 0.1) var orbit_angle: float = 0.0
## If set, this planet orbits another planet (a moon) instead of the sun.
## Use the parent planet's id (e.g. &"Tarkon").
@export var parent_planet_id: StringName = &""

# --- APPEARANCE ---
## Base surface color (dark tones / procedural texture low values)
@export var surface_color: Color = Color(0.08, 0.12, 0.08)
## Grid line color (bright tones / procedural texture high values)
@export var grid_color: Color = Color(0.2, 0.5, 0.3)
## Atmospheric glow color
@export var atmosphere_color: Color = Color(0.3, 0.7, 1.0, 0.3)
## Grid line density (higher = more lines)
@export var grid_density: float = 14.0
## Visual radius of the planet sphere
@export var mesh_radius: float = 3.0
## Degrees between hex grid centers on the planet surface.
## Smaller = tighter grid, larger = more spread out.
@export var hex_spacing: float = 4.0
## Icosphere subdivision level for geodesic sector grid.
## Level 1 = 42 cells, Level 2 = 162 cells, Level 3 = 642 cells.
@export var subdivision_level: int = 2

# --- TEXTURE ---
## Hand-made texture (optional). If null, procedural noise is used.
@export var surface_texture: Texture2D = null
## Noise seed for procedural generation
@export var texture_seed: int = 0
## Noise frequency (lower = bigger continent blobs)
@export var texture_frequency: float = 0.02

# --- CAMERA ---
## How far the camera orbits when zoomed in on this planet
@export var camera_distance: float = 7.5
## Default pitch when viewing this planet (radians)
@export var camera_pitch: float = 0.3


## Returns this planet's 3D position in the solar system.
## Y=0 so all planets sit on the same orbital plane.
func get_orbit_position() -> Vector3:
	var rad = deg_to_rad(orbit_angle)
	return Vector3(
		orbit_distance * sin(rad),
		0.0,
		orbit_distance * cos(rad)
	)
