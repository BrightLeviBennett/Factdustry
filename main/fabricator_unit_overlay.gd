extends Node2D

## Companion node for BuildingSystem. Draws fabricated units above the
## placed-building layer so unit sprites that overhang a fabricator are not
## partially covered by neighboring blocks drawn later in the building pass.

var building_sys: Node = null


func _ready() -> void:
	if building_sys:
		set_process(true)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if building_sys and building_sys.has_method("_draw_fabricator_unit_overlays"):
		building_sys._draw_fabricator_unit_overlays(self)
