extends Node2D

## Tiny companion node for BuildingSystem. Sits at z_index 52 (above
## the LogisticsSystem layer at 51, same as the vent / geyser steam
## overlay) so the copper cable wires drawn between cable nodes /
## towers render OVER the items running on conveyors underneath them.
## BuildingSystem still owns all cable state and the wire texture; we
## just host the _draw call on a higher render layer.

var building_sys: Node = null


func _ready() -> void:
	if building_sys:
		set_process(true)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if building_sys and building_sys.has_method("_draw_cable_links"):
		building_sys._draw_cable_links(self)
	# Bridge link strips draw AFTER (on top of) the cables, on the same
	# z=52 canvas, so a belt/duct bridge visualizer sits over any copper
	# cable it crosses.
	if building_sys and building_sys.has_method("_draw_bridge_links"):
		building_sys._draw_bridge_links(self)
