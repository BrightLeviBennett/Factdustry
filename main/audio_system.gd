extends Node
class_name AudioSystem

## One-shot SFX bus. Pools AudioStreamPlayer2D nodes so a salvo of
## sounds firing the same frame doesn't churn instances. Sound files
## are loaded lazily from `res://audio/sfx/<name>.<ext>`; a missing
## file turns the call into a no-op so authoring can lag the code.
##
## Hookups (subscribed in _ready):
##   - main.building_placed     → "place"
##   - main.building_destroyed  → "destroy"
##   - main.building_completed  → "build_complete"
##
## Other systems can call `AudioSystem.play("turret_shoot", world_pos)`
## directly. Pitch/volume are optional; default 0 dB / 1× pitch.

const POOL_SIZE := 24
const SFX_DIR := "res://audio/sfx/"
const EXTS: Array[String] = [".ogg", ".wav", ".mp3"]

var _pool: Array = []  # AudioStreamPlayer2D
var _next_idx: int = 0
var _cache: Dictionary = {}  # sound_id String -> AudioStream | null

@onready var main: Node2D = get_node_or_null("/root/Main")


func _ready() -> void:
	for i in range(POOL_SIZE):
		var p := AudioStreamPlayer2D.new()
		# Honour the "SFX" bus the settings_ui slider already drives; if
		# the project's audio bus layout doesn't have that bus the call
		# silently falls back to Master, so this is safe to set blindly.
		p.bus = "SFX"
		add_child(p)
		_pool.append(p)
	if main == null:
		return
	if main.has_signal("building_placed"):
		main.building_placed.connect(_on_building_placed)
	if main.has_signal("building_destroyed"):
		main.building_destroyed.connect(_on_building_destroyed)
	if main.has_signal("building_completed"):
		main.building_completed.connect(_on_building_completed)


## Plays `sound_id` (no extension) once at `world_pos`. Pitch jitter
## ±5% by default keeps repeated triggers from sounding mechanically
## identical — pass `pitch_jitter = 0.0` to disable for tuned sounds.
func play(sound_id: String, world_pos: Vector2 = Vector2.ZERO, volume_db: float = 0.0, pitch: float = 1.0, pitch_jitter: float = 0.05) -> void:
	var stream = _resolve(sound_id)
	if stream == null:
		return
	var p: AudioStreamPlayer2D = _pool[_next_idx]
	_next_idx = (_next_idx + 1) % POOL_SIZE
	p.stream = stream
	p.position = world_pos
	p.volume_db = volume_db
	p.pitch_scale = pitch + (randf() - 0.5) * 2.0 * pitch_jitter if pitch_jitter > 0.0 else pitch
	p.play()




func _resolve(sound_id: String):
	if _cache.has(sound_id):
		return _cache[sound_id]
	for ext in EXTS:
		var path := SFX_DIR + sound_id + ext
		if ResourceLoader.exists(path):
			var s = load(path)
			_cache[sound_id] = s
			return s
	_cache[sound_id] = null
	return null


# ----- signal hooks -----

func _on_building_placed(_block_id: StringName, grid_pos: Vector2i) -> void:
	play("place", main.grid_to_world(grid_pos))


func _on_building_destroyed(grid_pos: Vector2i) -> void:
	play("destroy", main.grid_to_world(grid_pos), 0.0, 1.0, 0.08)


func _on_building_completed(_block_id: StringName, grid_pos: Vector2i) -> void:
	play("build_complete", main.grid_to_world(grid_pos))
