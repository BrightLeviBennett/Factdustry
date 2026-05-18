extends Node2D

## Companion node for BuildingSystem. Sits at z_index 4096 (Godot's
## documented max — values above silently fall back to 0) so crane
## arms, grabbers, and held cargo render OVER every in-world layer:
## units, turret heads, projectiles. Same tier as popup_overlay; we
## sit later in the child list so we win the tie. BuildingSystem owns
## all the crane state + draw logic; we just host the _draw call on a
## higher render layer and pipe `self` through `_crane_draw_canvas`
## so every internal draw_* call lands on us.

var building_sys: Node = null


func _ready() -> void:
	if building_sys:
		set_process(true)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if building_sys == null or not building_sys.has_method("_draw_cranes"):
		return
	building_sys._crane_draw_canvas = self
	building_sys._draw_cranes()
	# Build / decon beam diamonds piggy-back on this overlay so the
	# pulsing emitter renders above the drone (z 4095) instead of
	# being clipped by it at the building_system's default z.
	if building_sys.has_method("_draw_active_work_diamonds"):
		building_sys._draw_active_work_diamonds()
	building_sys._crane_draw_canvas = null
