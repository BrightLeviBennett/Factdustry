extends Node
class_name FeedbackSystem

## Camera shake + hit-flash bookkeeping. Sister system to `AudioSystem`;
## the two together provide the bulk of the "Mindustry feel" without
## any per-block authoring. Other systems read state from here:
##
##   - `shake_offset()` / `apply_to_camera(cam)` — main.gd ticks this
##     each frame and offsets the Camera2D by the result.
##   - `is_building_flashing(grid_pos)` / `building_flash_alpha(grid_pos)`
##     — BuildingSystem._draw_placed_buildings reads these and tints
##     the sprite white for ~0.08 s after a damage event.
##   - `kick_unit_flash(unit)` — sets `_flash_until` on the unit; the
##     unit's _draw modulates with white while active.
##
## The actual hookups live where damage is dealt:
##   main.damage_building → flash_building + camera shake (proportional)
##   enemy_unit.take_damage → kick_unit_flash + camera shake

@onready var main: Node2D = get_node_or_null("/root/Main")

# --- Camera shake ---
var _shake_amp: float = 0.0           # current trauma magnitude (px)
var _shake_decay: float = 6.0         # per-second decay rate
var _shake_seed: float = 0.0
const SHAKE_MAX := 24.0

# --- Building flash ---
# anchor → end_time (game seconds). Cleaned lazily on read.
var _building_flash_until: Dictionary = {}
const BUILDING_FLASH_DURATION := 0.08


func _process(delta: float) -> void:
	# Freeze the shake while the game is paused — no decay, so it resumes
	# from where it left off on unpause (and `shake_offset` returns zero
	# meanwhile, so the camera sits still rather than jittering).
	if main and "world_paused" in main and main.world_paused:
		return
	if _shake_amp > 0.0:
		_shake_amp = maxf(0.0, _shake_amp - _shake_decay * delta)


## Public: kick a screen shake. `amount` is added to current amplitude
## and clamped to SHAKE_MAX (so a hailstorm of damage doesn't tween
## the camera into orbit). Tunable per call site.
func add_shake(amount: float) -> void:
	_shake_amp = clampf(_shake_amp + amount, 0.0, SHAKE_MAX)


## Returns the offset (px) the camera should add THIS frame. Decays
## over time toward zero. Two pseudorandom octaves so the motion
## reads as a real shake, not a sin wave.
func shake_offset() -> Vector2:
	if _shake_amp <= 0.05:
		return Vector2.ZERO
	# Hold the camera still while paused (the amplitude is preserved by the
	# _process guard, so the shake picks back up on unpause).
	if main and "world_paused" in main and main.world_paused:
		return Vector2.ZERO
	_shake_seed += 17.31
	var t: float = _shake_seed
	var x: float = sin(t * 7.91) + sin(t * 13.7) * 0.5
	var y: float = cos(t * 9.13) + cos(t * 11.3) * 0.5
	return Vector2(x, y) * _shake_amp * 0.5


## Convenience: applies `shake_offset()` directly to the given Camera2D
## (returns the original `position` so the caller can restore it next
## frame before re-applying — the offset is meant to be transient).
func apply_to_camera(cam: Camera2D) -> Vector2:
	if cam == null:
		return Vector2.ZERO
	var off: Vector2 = shake_offset()
	cam.offset = off
	return off


# ----- Building flash -----

## Marks `anchor` as recently damaged. Building draw paints a white
## tint over the sprite for BUILDING_FLASH_DURATION seconds.
func flash_building(anchor: Vector2i) -> void:
	_building_flash_until[anchor] = Time.get_ticks_msec() / 1000.0 + BUILDING_FLASH_DURATION


func is_building_flashing(anchor: Vector2i) -> bool:
	if not _building_flash_until.has(anchor):
		return false
	if (Time.get_ticks_msec() / 1000.0) >= float(_building_flash_until[anchor]):
		_building_flash_until.erase(anchor)
		return false
	return true


## Returns 0..1 alpha for the white tint overlay. Eases from 1 → 0 over
## BUILDING_FLASH_DURATION so the flash visually fades instead of
## popping off.
func building_flash_alpha(anchor: Vector2i) -> float:
	if not _building_flash_until.has(anchor):
		return 0.0
	var now: float = Time.get_ticks_msec() / 1000.0
	var end_t: float = float(_building_flash_until[anchor])
	if now >= end_t:
		_building_flash_until.erase(anchor)
		return 0.0
	return clampf((end_t - now) / BUILDING_FLASH_DURATION, 0.0, 1.0)


# ----- Unit flash -----

## Sets `_flash_until` on the unit (creates the property if missing).
## The unit's _draw should multiply its modulate by `Color.WHITE` lerped
## from white→neutral over the remaining duration, e.g.:
##   var t = clampf((u._flash_until - now) / 0.08, 0.0, 1.0)
##   modulate = Color(1, 1, 1, 1).lerp(Color(2, 2, 2, 1), t)
const UNIT_FLASH_DURATION := 0.08

func kick_unit_flash(unit: Node2D) -> void:
	if unit == null:
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	unit.set("_flash_until", now + UNIT_FLASH_DURATION)
