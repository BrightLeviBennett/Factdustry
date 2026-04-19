extends Node2D

# ============================================================
# VENT_PARTICLE_OVERLAY.GD
# ============================================================
# Lightweight sibling of TerrainSystem whose only job is to draw vent
# steam puffs at a z_index above the building layer. Particle state and
# spawn logic live in TerrainSystem; this node just reads and renders.
# ============================================================

var terrain: Node


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if terrain == null or not terrain.has_method("draw_vent_particles_to"):
		return
	terrain.draw_vent_particles_to(self)
