extends Node2D

## Tiny companion node for CombatSystem. Sits at z_index 4095 (z_as_relative
## false) so projectile draws are guaranteed to land above every in-world
## Node2D — chassis, building art, terrain overlays — without relying on
## the parent's z_index propagating in the way we'd expect. CombatSystem
## still owns all projectile state; this node just hosts the _draw call
## on a higher render layer.

var combat: Node = null


func _ready() -> void:
	if combat:
		# Trigger redraws every frame the combat system itself redraws.
		# Combat redraws every _process tick, so do the same here.
		set_process(true)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if combat and combat.has_method("_draw_projectiles"):
		combat._draw_projectiles(self)
