extends Node2D
class_name SectorScript

# ============================================================
# SECTOR_SCRIPT.GD - Sector Walkthrough / Tutorial Helpers
# ============================================================
# Provides helper functions for scripting sector behavior:
#   - Pause/unpause the world
#   - Detect resource mining/production/core deposit thresholds
#   - Detect block placement counts
#   - Draw/remove highlight boxes around tiles
#   - Detect unit production/destruction counts
#   - Detect FEROX block destruction
#
# Each "detect" function works as a one-shot check per step.
# The sector script is driven by a list of steps (loaded from
# sector JSON or created in the map editor).
# ============================================================

@onready var main: Node2D = get_node("/root/Main")

# --- HIGHLIGHT BOXES ---
## id -> {rect: Rect2i, color: Color}
var _highlight_boxes: Dictionary = {}

# --- TEXT OVERLAYS ---
## id -> {rect: Rect2i, text: String}
var _text_overlays: Dictionary = {}

# --- CACHED IMAGES ---
## path -> Texture2D (loaded on first use)
var _image_cache: Dictionary = {}

# --- TRACKING COUNTERS ---
## Incremented by signals from main systems
var _mined_counts: Dictionary = {}      # item_id -> int
var _core_counts: Dictionary = {}       # item_id -> int
var _produced_counts: Dictionary = {}   # item_id -> int
var _placed_counts: Dictionary = {}     # block_id -> int
var _units_produced_counts: Dictionary = {}   # unit_id -> int
var _units_destroyed_counts: Dictionary = {}  # unit_id -> int
var _ferox_blocks_destroyed_counts: Dictionary = {} # block_id -> int
var _ferox_specific_destroyed: Dictionary = {} # "block_id:x:y" -> bool
var _core_unit_mined_counts: Dictionary = {}   # item_id -> int
var _decoded_archive_counts: Dictionary = {}   # archive_id -> int

# --- STEP BASELINE SNAPSHOTS ---
## Snapshots at step entry, so conditions check relative increase.
var _step_deposited_baselines: Dictionary = {}  # item_id -> int
var _step_placed_baselines: Dictionary = {}     # block_id -> int

# --- DISABLED BUILDINGS ---
## Set of building anchor positions that are disabled by script actions.
var _disabled_buildings: Dictionary = {}  # Vector2i -> true

# --- HIDDEN TILES ---
## Tiles manually hidden by script actions. Overrides the automatic wall fade.
## Can hide both wall and floor tiles.
var _hidden_tiles: Dictionary = {}  # Vector2i -> true

# --- SCRIPT STEP RUNNER ---
var _script_steps: Array = []
var _current_step: int = -1  # -1 = not running
var _step_wait_timer: float = 0.0
var _script_running := false

# --- HINTS ---
## Authored hint definitions, see HINT FORMAT comment below.
var _hints: Array = []
## Per-hint runtime: id -> {state, baselines, activated_at, sentinel}.
##   state ∈ {"pending", "active", "dismissed"}
##   baselines = snapshot of relevant counters at activation
##   activated_at = seconds since sector load
##   sentinel = block_id at the watched cell when remove_when=block_changed
var _hint_runtime: Dictionary = {}
var _hint_clock: float = 0.0
var _hint_landing_fired: bool = false

# HINT FORMAT (Dictionary):
#   {
#     "id": String — unique within the sector,
#     "text": String — what to show in the panel,
#     "condition": { "type": "landing" | "block_placed" | "item_produced"
#                                | "units_produced" | "time_after",
#                    "block_id": StringName, "item_id": StringName,
#                    "unit_id": StringName, "amount": int, "seconds": float },
#     "remove_when": { "type": "user_pressed_ok" | "block_placed"
#                              | "block_changed" | "item_produced"
#                              | "units_produced",
#                      ...same arg shape... },
#     "can_be_ignored": bool — when true the panel renders an "OK" button
#                              the player can click to dismiss it manually,
#   }
signal hint_show(hint: Dictionary)
signal hint_hide(hint_id: String)
signal hints_cleared()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Connect signals for tracking. Some environments (the map editor)
	# reuse SectorScript just for its rendering and don't emit the full
	# set of gameplay signals, so guard each hookup with `has_signal`
	# instead of assuming the main scene has every one.
	if main:
		if main.has_signal("item_mined"):
			main.item_mined.connect(_on_item_mined)
		if main.has_signal("item_absorbed_in_core"):
			main.item_absorbed_in_core.connect(_on_item_absorbed_in_core)
		if main.has_signal("item_produced"):
			main.item_produced.connect(_on_item_produced)
		# `_placed_counts` only counts blocks the player actually finished
		# building, so a tutorial step asking for N drills doesn't tick
		# off the moment a ghost queue is enqueued. Pre-placed sector
		# blocks emit building_placed but never reach building_completed,
		# which matches the intent here — "block up and running by player
		# action", not "block exists at all".
		if main.has_signal("building_completed"):
			main.building_completed.connect(_on_building_placed)
		if main.has_signal("building_destroyed"):
			main.building_destroyed.connect(_on_building_destroyed)
		if main.has_signal("core_unit_item_mined"):
			main.core_unit_item_mined.connect(_on_core_unit_item_mined)
		if main.has_signal("archive_decoded"):
			main.archive_decoded.connect(_on_archive_decoded)


func _process(delta: float) -> void:
	_hint_clock += delta
	_tick_hints()
	if not _script_running or _current_step < 0 or _current_step >= _script_steps.size():
		return

	var step: Dictionary = _script_steps[_current_step]

	# Support both old "condition" (single dict) and new "conditions" (array) format
	var conditions: Array = _get_step_conditions(step)

	# ALL conditions must be met (AND logic)
	var advance := true
	for cond in conditions:
		if not _check_condition(cond, delta):
			advance = false

	if advance:
		_exit_step(_current_step)
		_current_step += 1
		if _current_step < _script_steps.size():
			_enter_step(_current_step)
		else:
			_script_running = false
			print("SectorScript: All steps complete.")


## Get the conditions array from a step, handling both old and new formats.
func _get_step_conditions(step: Dictionary) -> Array:
	if step.has("conditions") and step["conditions"] is Array and not step["conditions"].is_empty():
		return step["conditions"]
	if step.has("condition") and step["condition"] is Dictionary:
		return [step["condition"]]
	return [{"type": "always"}]


## Check whether a single condition is met. Returns true if satisfied.
func _check_condition(cond: Dictionary, delta: float) -> bool:
	var cond_type: String = cond.get("type", "always")
	match cond_type:
		"always":
			return true
		"wait":
			_step_wait_timer -= delta
			return _step_wait_timer <= 0.0
		"mined":
			return has_mined(StringName(cond.get("item_id", "")), int(cond.get("amount", 1)))
		"deposited":
			var dep_item := StringName(cond.get("item_id", ""))
			var dep_amount := int(cond.get("amount", 1))
			var baseline := int(_step_deposited_baselines.get(dep_item, 0))
			return main.resources.get(dep_item, 0) >= baseline + dep_amount
		"produced":
			return has_produced(StringName(cond.get("item_id", "")), int(cond.get("amount", 1)))
		"placed":
			var pl_block := StringName(cond.get("block_id", ""))
			var pl_amount := int(cond.get("amount", 1))
			var pl_baseline := int(_step_placed_baselines.get(pl_block, 0))
			return _placed_counts.get(pl_block, 0) >= pl_baseline + pl_amount
		"units_produced":
			return has_produced_units(StringName(cond.get("unit_id", "")), int(cond.get("amount", 1)))
		"units_destroyed":
			return has_destroyed_ferox_units(StringName(cond.get("unit_id", "")), int(cond.get("amount", 1)))
		"ferox_blocks_destroyed":
			return has_destroyed_ferox_blocks(StringName(cond.get("block_id", "")), int(cond.get("amount", 1)))
		"core_unit_mined":
			return has_core_unit_mined(StringName(cond.get("item_id", "")), int(cond.get("amount", 1)))
		"decoded_archive":
			# Archive scripting uses the `-D-<archive_id>` tech-tree marker,
			# but we track decoded events in a local counter so the
			# condition only fires for decodes that happened DURING this
			# step (keeps semantics consistent with placed/produced). A
			# bare amount = 1 is the common case: "wait until one of
			# archive X is decoded here".
			return has_decoded_archive(StringName(cond.get("archive_id", "")), int(cond.get("amount", 1)))
		"block_has_item":
			var pos_str: String = str(cond.get("pos", "0,0"))
			var parts = pos_str.split(",")
			if parts.size() >= 2:
				var gpos := Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))
				return block_has_item(gpos, StringName(cond.get("item_id", "")), int(cond.get("amount", 1)))
			return false
		"waves_defeated":
			# Fires once the last scheduled wave has been spawned AND
			# every unit from every wave is dead. Infinite-auto runs
			# never satisfy this unless stop_waves has been called and
			# the currently-spawned units have all died.
			var wm = get_node_or_null("/root/Main/WaveManager")
			return wm != null and bool(wm.get("waves_all_defeated"))
	return true


func _draw() -> void:
	# Draw highlight boxes
	for box_id in _highlight_boxes:
		var box: Dictionary = _highlight_boxes[box_id]
		var rect: Rect2i = box["rect"]
		var color: Color = box["color"]
		var gs: float = main.GRID_SIZE
		var world_rect := Rect2(
			main.grid_to_world(rect.position),
			Vector2(rect.size.x * gs, rect.size.y * gs),
		)
		var fill_color := Color(color.r, color.g, color.b, 0.12)
		draw_rect(world_rect, fill_color, true)
		draw_rect(world_rect, color, false, 2.0)

	# Draw text overlays
	for text_id in _text_overlays:
		var overlay: Dictionary = _text_overlays[text_id]
		var rect: Rect2i = overlay["rect"]
		var text: String = overlay["text"]
		var gs: float = main.GRID_SIZE
		var world_pos: Vector2 = main.grid_to_world(rect.position)
		var area_size := Vector2(rect.size.x * gs, rect.size.y * gs)

		# Dark background
		var bg_rect := Rect2(world_pos, area_size)
		draw_rect(bg_rect, Color(0.05, 0.05, 0.08, 0.85), true)
		draw_rect(bg_rect, Color(0.4, 0.4, 0.5, 0.5), false, 1.0)

		# Parse and draw rich text content
		_draw_rich_text(text, world_pos + Vector2(8, 8), area_size - Vector2(16, 16))


# =========================
# WORLD CONTROL
# =========================

## Pause the game world (partial pause: camera moves, no building/units/logistics).
func pause_world() -> void:
	main.world_paused = true


## Unpause the game world.
func unpause_world() -> void:
	main.world_paused = false


## Returns true if the world is currently paused.
func is_paused() -> bool:
	return main.world_paused


# =========================
# CAMERA CONTROL
# =========================

## Move the camera to focus on a world position (independent of drone/unit).
func focus_camera(world_pos: Vector2) -> void:
	var camera = get_node_or_null("/root/Main/Camera2D")
	if camera:
		camera.focus_override = world_pos


## Move the camera to focus on a grid position.
func focus_camera_grid(grid_pos: Vector2i) -> void:
	var world_pos: Vector2 = main.grid_to_world(grid_pos) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
	focus_camera(world_pos)


## Release camera focus, returning it to normal drone/unit following.
func release_camera() -> void:
	var camera = get_node_or_null("/root/Main/Camera2D")
	if camera:
		camera.focus_override = null


# =========================
# HIGHLIGHT BOXES
# =========================

## Draw a colored box around tiles from grid_from to grid_to.
## box_id: unique string to identify this box for later removal.
func draw_box(box_id: String, grid_from: Vector2i, grid_to: Vector2i, color: Color = Color.YELLOW) -> void:
	var min_pos := Vector2i(mini(grid_from.x, grid_to.x), mini(grid_from.y, grid_to.y))
	var max_pos := Vector2i(maxi(grid_from.x, grid_to.x), maxi(grid_from.y, grid_to.y))
	var size := max_pos - min_pos + Vector2i(1, 1)
	_highlight_boxes[box_id] = {"rect": Rect2i(min_pos, size), "color": color}
	queue_redraw()


## Remove a highlight box by its id.
func remove_box(box_id: String) -> void:
	_highlight_boxes.erase(box_id)
	queue_redraw()


## Remove all highlight boxes.
func clear_boxes() -> void:
	_highlight_boxes.clear()
	queue_redraw()


# =========================
# TEXT OVERLAYS
# =========================

## Draw a text overlay in a grid rectangle.
## text_id: unique string for later removal.
## grid_from, grid_to: rectangle corners (snapped to grid).
## text: rich text with color tags (-red), (-yellow) etc and image tags [path.png].
func draw_text_overlay(text_id: String, grid_from: Vector2i, grid_to: Vector2i, text: String) -> void:
	var min_pos := Vector2i(mini(grid_from.x, grid_to.x), mini(grid_from.y, grid_to.y))
	var max_pos := Vector2i(maxi(grid_from.x, grid_to.x), maxi(grid_from.y, grid_to.y))
	var size := max_pos - min_pos + Vector2i(1, 1)
	_text_overlays[text_id] = {"rect": Rect2i(min_pos, size), "text": text}
	queue_redraw()


## Remove a text overlay by id.
func remove_text_overlay(text_id: String) -> void:
	_text_overlays.erase(text_id)
	queue_redraw()


## Remove all text overlays.
func clear_text_overlays() -> void:
	_text_overlays.clear()
	queue_redraw()


# =========================
# RICH TEXT RENDERER
# =========================

## Named colors for (-color) tags.
const NAMED_COLORS := {
	"red": Color.RED, "green": Color.GREEN, "blue": Color.BLUE,
	"yellow": Color.YELLOW, "orange": Color.ORANGE, "white": Color.WHITE,
	"cyan": Color.CYAN, "magenta": Color.MAGENTA, "pink": Color.HOT_PINK,
	"gray": Color.GRAY, "grey": Color.GRAY, "black": Color.WEB_GRAY, 
	"brown": Color.SADDLE_BROWN, "purple": Color.DARK_ORCHID
}


## Parse and draw rich text with (-color) tags and [image.png] tags.
func _draw_rich_text(text: String, origin: Vector2, area: Vector2) -> void:
	var font: Font = ThemeDB.fallback_font
	var font_size: int = 14
	var line_height: float = font_size + 4.0
	var x: float = 0.0
	var y: float = font_size  # baseline offset
	var current_color := Color.WHITE
	var max_width: float = area.x
	var i: int = 0

	while i < text.length():
		# Check for newline
		if text[i] == "\n":
			x = 0.0
			y += line_height
			i += 1
			continue

		# Check for color tag: (-color)
		if text[i] == "(" and i + 1 < text.length() and text[i + 1] == "-":
			var close := text.find(")", i + 2)
			if close != -1:
				var color_name := text.substr(i + 2, close - i - 2).strip_edges().to_lower()
				if NAMED_COLORS.has(color_name):
					current_color = NAMED_COLORS[color_name]
				elif color_name == "reset" or color_name == "default":
					current_color = Color.WHITE
				i = close + 1
				continue

		# Check for image tag: [path/to/image.png]
		if text[i] == "[":
			var close := text.find("]", i + 1)
			if close != -1:
				var img_path := text.substr(i + 1, close - i - 1).strip_edges()
				if img_path.ends_with(".png") or img_path.ends_with(".jpg") or img_path.ends_with(".svg") or img_path.ends_with(".tres"):
					var tex := _load_image(img_path)
					if tex:
						var img_size := Vector2(line_height, line_height)
						# Wrap if needed
						if x + img_size.x > max_width and x > 0:
							x = 0.0
							y += line_height
						draw_texture_rect(tex, Rect2(origin + Vector2(x, y - font_size), img_size), false)
						x += img_size.x + 2.0
					i = close + 1
					continue

		# Regular character — accumulate word for wrapping
		var word_end := i
		while word_end < text.length() and text[word_end] != " " and text[word_end] != "\n" and text[word_end] != "(" and text[word_end] != "[":
			word_end += 1
		var word := text.substr(i, word_end - i)
		if word.length() == 0:
			# Space or delimiter
			if text[i] == " ":
				x += font.get_string_size(" ", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			i += 1
			continue

		var word_width: float = font.get_string_size(word, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		# Wrap if needed
		if x + word_width > max_width and x > 0:
			x = 0.0
			y += line_height

		# Stop if we overflow vertically
		if y > area.y:
			break

		draw_string(font, origin + Vector2(x, y), word, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, current_color)
		x += word_width + font.get_string_size(" ", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		i = word_end
		# Consume trailing space
		if i < text.length() and text[i] == " ":
			i += 1


## Load and cache a texture from a resource path.
func _load_image(path: String) -> Texture2D:
	if _image_cache.has(path):
		return _image_cache[path]
	if ResourceLoader.exists(path):
		var tex = load(path) as Texture2D
		if tex:
			_image_cache[path] = tex
			return tex
	_image_cache[path] = null
	return null


# =========================
# DETECTION: RESOURCES MINED
# =========================

## Returns true once the specified amount of item_id has been mined since tracking started.
func has_mined(item_id: StringName, amount: int) -> bool:
	return _mined_counts.get(item_id, 0) >= amount


## Returns current mined count for item_id.
func get_mined_count(item_id: StringName) -> int:
	return _mined_counts.get(item_id, 0)


## Reset the mined counter for an item (or all items if item_id is empty).
func reset_mined(item_id: StringName = &"") -> void:
	if item_id == &"":
		_mined_counts.clear()
	else:
		_mined_counts.erase(item_id)


# =========================
# DETECTION: CORE UNIT MINED
# =========================

## Returns true once the specified amount of item_id has been mined by the core unit.
func has_core_unit_mined(item_id: StringName, amount: int) -> bool:
	return _core_unit_mined_counts.get(item_id, 0) >= amount


## Returns current core-unit-mined count for item_id.
func get_core_unit_mined_count(item_id: StringName) -> int:
	return _core_unit_mined_counts.get(item_id, 0)


## Reset the core unit mined counter.
func reset_core_unit_mined(item_id: StringName = &"") -> void:
	if item_id == &"":
		_core_unit_mined_counts.clear()
	else:
		_core_unit_mined_counts.erase(item_id)


## Returns true if `archive_id` has been decoded at least `amount` times
## since the last reset. An empty archive_id matches ANY archive decode
## (useful for "decode any archive" gates).
func has_decoded_archive(archive_id: StringName, amount: int) -> bool:
	return _decoded_archive_counts.get(archive_id, 0) >= amount


func get_decoded_archive_count(archive_id: StringName) -> int:
	return _decoded_archive_counts.get(archive_id, 0)


func reset_decoded_archive(archive_id: StringName = &"") -> void:
	if archive_id == &"":
		_decoded_archive_counts.clear()
	else:
		_decoded_archive_counts.erase(archive_id)


# =========================
# DETECTION: RESOURCES IN CORE
# =========================

## Returns true once the specified amount of item_id has been deposited in the core.
func has_deposited_in_core(item_id: StringName, amount: int) -> bool:
	return _core_counts.get(item_id, 0) >= amount


## Returns current core deposit count for item_id.
func get_core_deposit_count(item_id: StringName) -> int:
	return _core_counts.get(item_id, 0)


## Reset the core deposit counter.
func reset_core_deposits(item_id: StringName = &"") -> void:
	if item_id == &"":
		_core_counts.clear()
	else:
		_core_counts.erase(item_id)


# =========================
# DETECTION: RESOURCES PRODUCED
# =========================

## Returns true once the specified amount of item_id has been produced (by factories).
func has_produced(item_id: StringName, amount: int) -> bool:
	return _produced_counts.get(item_id, 0) >= amount


func get_produced_count(item_id: StringName) -> int:
	return _produced_counts.get(item_id, 0)


func reset_produced(item_id: StringName = &"") -> void:
	if item_id == &"":
		_produced_counts.clear()
	else:
		_produced_counts.erase(item_id)


# =========================
# DETECTION: BLOCKS PLACED
# =========================

## Returns true once the specified number of block_id has been placed.
func has_placed_blocks(block_id: StringName, amount: int) -> bool:
	return _placed_counts.get(block_id, 0) >= amount


func get_placed_count(block_id: StringName) -> int:
	return _placed_counts.get(block_id, 0)


func reset_placed(block_id: StringName = &"") -> void:
	if block_id == &"":
		_placed_counts.clear()
	else:
		_placed_counts.erase(block_id)


# =========================
# DETECTION: UNITS PRODUCED
# =========================

## Returns true once the specified number of units with unit_id have been produced.
func has_produced_units(unit_id: StringName, amount: int) -> bool:
	return _units_produced_counts.get(unit_id, 0) >= amount


func get_units_produced_count(unit_id: StringName) -> int:
	return _units_produced_counts.get(unit_id, 0)


func reset_units_produced(unit_id: StringName = &"") -> void:
	if unit_id == &"":
		_units_produced_counts.clear()
	else:
		_units_produced_counts.erase(unit_id)


# =========================
# DETECTION: FEROX UNITS DESTROYED
# =========================

## Returns true once the specified number of ferox units with unit_id have been destroyed.
func has_destroyed_ferox_units(unit_id: StringName, amount: int) -> bool:
	return _units_destroyed_counts.get(unit_id, 0) >= amount


func get_ferox_units_destroyed_count(unit_id: StringName) -> int:
	return _units_destroyed_counts.get(unit_id, 0)


func reset_ferox_units_destroyed(unit_id: StringName = &"") -> void:
	if unit_id == &"":
		_units_destroyed_counts.clear()
	else:
		_units_destroyed_counts.erase(unit_id)


# =========================
# DETECTION: FEROX BLOCKS DESTROYED
# =========================

## Returns true once the specified number of FEROX blocks with block_id have been destroyed.
func has_destroyed_ferox_blocks(block_id: StringName, amount: int) -> bool:
	return _ferox_blocks_destroyed_counts.get(block_id, 0) >= amount


func get_ferox_blocks_destroyed_count(block_id: StringName) -> int:
	return _ferox_blocks_destroyed_counts.get(block_id, 0)


func reset_ferox_blocks_destroyed(block_id: StringName = &"") -> void:
	if block_id == &"":
		_ferox_blocks_destroyed_counts.clear()
	else:
		_ferox_blocks_destroyed_counts.erase(block_id)


## Returns true if a specific FEROX block at a specific position has been destroyed.
## block_id: the block type, grid_pos: its grid position.
func has_specific_ferox_block_been_destroyed(block_id: StringName, grid_pos: Vector2i) -> bool:
	var key := "%s:%d:%d" % [block_id, grid_pos.x, grid_pos.y]
	return _ferox_specific_destroyed.has(key)


# =========================
# BLOCK STORAGE QUERIES
# =========================

## Returns how many of item_id are stored in the block at grid_pos.
## Resolves multi-tile buildings to their anchor automatically.
## Checks both items and fluids in the block's internal storage.
func get_block_stored_amount(grid_pos: Vector2i, item_id: StringName) -> int:
	var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	if logistics == null:
		return 0
	if not logistics.block_storage.has(anchor):
		return 0
	var storage: Dictionary = logistics.block_storage[anchor]
	var count := 0
	count += int(storage.get("items", {}).get(item_id, 0))
	count += int(storage.get("fluids", {}).get(item_id, 0))
	return count


## Returns true if the block at grid_pos has at least `amount` of item_id in storage.
func block_has_item(grid_pos: Vector2i, item_id: StringName, amount: int) -> bool:
	return get_block_stored_amount(grid_pos, item_id) >= amount


# =========================
# TILE HIDE/REVEAL
# =========================

## Hide all tiles in a rectangular region (from_pos to to_pos inclusive).
## Hides both walls and floors. include_floors controls whether floor tiles are hidden.
func hide_region(from_pos: Vector2i, to_pos: Vector2i, include_floors: bool = true) -> void:
	var min_pos := Vector2i(mini(from_pos.x, to_pos.x), mini(from_pos.y, to_pos.y))
	var max_pos := Vector2i(maxi(from_pos.x, to_pos.x), maxi(from_pos.y, to_pos.y))
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	for x in range(min_pos.x, max_pos.x + 1):
		for y in range(min_pos.y, max_pos.y + 1):
			var pos := Vector2i(x, y)
			if include_floors:
				_hidden_tiles[pos] = true
			elif terrain and terrain.wall_tiles.has(pos):
				_hidden_tiles[pos] = true
	_invalidate_caches()
	print("SectorScript: Hidden region %s to %s (floors=%s)" % [min_pos, max_pos, include_floors])


## Reveal all tiles in a rectangular region (undo hide).
## After removing the manual hiding, rebuilds natural fade caches so
## the wall/floor fade system recalculates naturally.
func reveal_region(from_pos: Vector2i, to_pos: Vector2i) -> void:
	var min_pos := Vector2i(mini(from_pos.x, to_pos.x), mini(from_pos.y, to_pos.y))
	var max_pos := Vector2i(maxi(from_pos.x, to_pos.x), maxi(from_pos.y, to_pos.y))
	var revealed: Array[Vector2i] = []
	for x in range(min_pos.x, max_pos.x + 1):
		for y in range(min_pos.y, max_pos.y + 1):
			var gp := Vector2i(x, y)
			if _hidden_tiles.has(gp):
				_hidden_tiles.erase(gp)
				revealed.append(gp)
	_invalidate_caches()
	# Mark revealed tiles as passable in pathfinding
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if unit_mgr:
		var terrain = get_node_or_null("/root/Main/TerrainSystem")
		for gp in revealed:
			# Only make passable if it's a floor tile (not a wall)
			var is_wall: bool = terrain and terrain.wall_tiles.has(gp)
			var is_solid: bool = is_wall or (main.placed_buildings.has(gp) and not _is_walkable_building(gp))
			if unit_mgr.astar:
				unit_mgr.astar.set_point_solid(gp, is_solid)
			if unit_mgr.astar_crawler:
				unit_mgr.astar_crawler.set_point_solid(gp, is_solid)
			if unit_mgr.astar_hover:
				unit_mgr.astar_hover.set_point_solid(gp, is_wall)
	print("SectorScript: Revealed region %s to %s (%d tiles)" % [min_pos, max_pos, revealed.size()])


func _is_walkable_building(gp: Vector2i) -> bool:
	var block_id = main.placed_buildings.get(gp, &"")
	if block_id == &"":
		return true
	var data = Registry.get_block(block_id)
	if data == null:
		return false
	return data.is_transport()


## Returns true if a tile is manually hidden by script.
func is_tile_hidden(grid_pos: Vector2i) -> bool:
	return _hidden_tiles.has(grid_pos)


## Force building system and terrain system to recompute fade caches.
func _invalidate_caches() -> void:
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	if building_sys:
		building_sys._walls_dirty = true
		building_sys.queue_redraw()
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	if terrain:
		terrain._floor_edge_dirty = true
		# Water meshes skip hidden cells, so toggling visibility also
		# invalidates the water bake.
		terrain._water_depth_dirty = true
		terrain.queue_redraw()
	# Update pathfinding grids so hidden tiles become impassable
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if unit_mgr:
		for gp in _hidden_tiles:
			if unit_mgr.astar:
				unit_mgr.astar.set_point_solid(gp, true)
			if unit_mgr.astar_crawler:
				unit_mgr.astar_crawler.set_point_solid(gp, true)
			if unit_mgr.astar_hover:
				unit_mgr.astar_hover.set_point_solid(gp, true)


# =========================
# BUILDING ENABLE/DISABLE
# =========================

## Resolve a grid position to the building anchor (handles multi-tile).
func _resolve_building_anchor(grid_pos: Vector2i) -> Vector2i:
	return main.building_origins.get(grid_pos, grid_pos)


## Disable a building at grid_pos (resolves multi-tile to anchor).
func disable_building(grid_pos: Vector2i) -> void:
	var anchor := _resolve_building_anchor(grid_pos)
	_disabled_buildings[anchor] = true
	print("SectorScript: Disabled building at %s (anchor %s)" % [grid_pos, anchor])


## Enable a previously disabled building at grid_pos.
func enable_building(grid_pos: Vector2i) -> void:
	var anchor := _resolve_building_anchor(grid_pos)
	_disabled_buildings.erase(anchor)
	print("SectorScript: Enabled building at %s (anchor %s)" % [grid_pos, anchor])


## Returns true if the building at grid_pos (or its anchor) is disabled by script.
func is_building_disabled(grid_pos: Vector2i) -> bool:
	var anchor := _resolve_building_anchor(grid_pos)
	return _disabled_buildings.has(anchor)


# =========================
# SCRIPT STEP RUNNER
# =========================

## Load script steps from data (called by save_manager after sector load).
## Also resets every piece of runtime state, so a re-launch after abandon
## starts from the same blank slate a fresh install would. Callers that
## need to preserve state (save-load) invoke `load_runtime_state`
## immediately after and explicitly overwrite the fields they care about.
func load_script_steps(steps: Array) -> void:
	_script_steps = steps.duplicate(true)
	reset_runtime_state()


## Wipes every piece of per-sector runtime state: step counters, visual
## overlays (boxes / text), hidden-tile list, disabled-building list,
## baselines, timers. Leaves `_script_steps` alone so the caller can
## re-run `start_script` on the same data. Cheap to call — this is how
## we guarantee a clean state when a sector is re-entered after abandon.
func reset_runtime_state() -> void:
	_current_step = -1
	_script_running = false
	_step_wait_timer = 0.0
	_mined_counts.clear()
	_core_counts.clear()
	_produced_counts.clear()
	_placed_counts.clear()
	_units_produced_counts.clear()
	_units_destroyed_counts.clear()
	_ferox_blocks_destroyed_counts.clear()
	_ferox_specific_destroyed.clear()
	_core_unit_mined_counts.clear()
	_decoded_archive_counts.clear()
	_step_deposited_baselines.clear()
	_step_placed_baselines.clear()
	_highlight_boxes.clear()
	_text_overlays.clear()
	# Before clearing hidden tiles / disabled buildings we need to tell
	# downstream systems the visibility/power state changed, else the
	# tile fade cache and power network keep the old masking.
	var had_hidden := not _hidden_tiles.is_empty()
	_hidden_tiles.clear()
	_disabled_buildings.clear()
	# Hints reset to "pending" so a re-launch fires their conditions afresh.
	_hint_runtime.clear()
	_hint_landing_fired = false
	_hint_clock = 0.0
	hints_cleared.emit()
	if had_hidden:
		_invalidate_caches()
	queue_redraw()


## Start executing the script from step 0.
func start_script() -> void:
	if _script_steps.is_empty():
		return
	_current_step = 0
	_script_running = true
	_enter_step(0)


## Returns the script runtime state as a serializable dictionary.
func get_runtime_state() -> Dictionary:
	var hidden_arr: Array = []
	for pos in _hidden_tiles:
		hidden_arr.append("%d,%d" % [pos.x, pos.y])
	var disabled_arr: Array = []
	for pos in _disabled_buildings:
		disabled_arr.append("%d,%d" % [pos.x, pos.y])
	return {
		"current_step": _current_step,
		"script_running": _script_running,
		"step_wait_timer": _step_wait_timer,
		"mined_counts": _dict_sname_to_str(_mined_counts),
		"core_counts": _dict_sname_to_str(_core_counts),
		"produced_counts": _dict_sname_to_str(_produced_counts),
		"placed_counts": _dict_sname_to_str(_placed_counts),
		"units_produced_counts": _dict_sname_to_str(_units_produced_counts),
		"units_destroyed_counts": _dict_sname_to_str(_units_destroyed_counts),
		"ferox_blocks_destroyed_counts": _dict_sname_to_str(_ferox_blocks_destroyed_counts),
		"core_unit_mined_counts": _dict_sname_to_str(_core_unit_mined_counts),
		"decoded_archive_counts": _dict_sname_to_str(_decoded_archive_counts),
		"deposited_baselines": _dict_sname_to_str(_step_deposited_baselines),
		"placed_baselines": _dict_sname_to_str(_step_placed_baselines),
		"hidden_tiles": hidden_arr,
		"disabled_buildings": disabled_arr,
	}


## Restores script runtime state from a dictionary. Skips start_script().
func load_runtime_state(state: Dictionary) -> void:
	_current_step = int(state.get("current_step", -1))
	_script_running = bool(state.get("script_running", false))
	_step_wait_timer = float(state.get("step_wait_timer", 0.0))
	_mined_counts = _dict_str_to_sname(state.get("mined_counts", {}))
	_core_counts = _dict_str_to_sname(state.get("core_counts", {}))
	_produced_counts = _dict_str_to_sname(state.get("produced_counts", {}))
	_placed_counts = _dict_str_to_sname(state.get("placed_counts", {}))
	_units_produced_counts = _dict_str_to_sname(state.get("units_produced_counts", {}))
	_units_destroyed_counts = _dict_str_to_sname(state.get("units_destroyed_counts", {}))
	_ferox_blocks_destroyed_counts = _dict_str_to_sname(state.get("ferox_blocks_destroyed_counts", {}))
	_core_unit_mined_counts = _dict_str_to_sname(state.get("core_unit_mined_counts", {}))
	_decoded_archive_counts = _dict_str_to_sname(state.get("decoded_archive_counts", {}))
	_hidden_tiles.clear()
	for pos_str in state.get("hidden_tiles", []):
		var parts = str(pos_str).split(",")
		if parts.size() >= 2:
			_hidden_tiles[Vector2i(int(parts[0]), int(parts[1]))] = true
	_disabled_buildings.clear()
	for pos_str in state.get("disabled_buildings", []):
		var parts = str(pos_str).split(",")
		if parts.size() >= 2:
			_disabled_buildings[Vector2i(int(parts[0]), int(parts[1]))] = true
	# Restore baselines directly (not re-computed)
	_step_deposited_baselines = _dict_str_to_sname(state.get("deposited_baselines", {}))
	_step_placed_baselines = _dict_str_to_sname(state.get("placed_baselines", {}))
	# Replay on_enter actions for current step to restore visual state (draw_box, draw_text, pause, etc.)
	# Side-effect actions like start_waves/stop_waves must NOT be replayed
	# here — the WaveManager runtime has already been restored from the
	# save by this point, and re-running start_waves calls `wm.start()`
	# which resets _idx, _timer, and _expanded_waves. Same logic for
	# stop_waves: it'd halt a wave run that the save said was running.
	if _script_running and _current_step >= 0 and _current_step < _script_steps.size():
		var step: Dictionary = _script_steps[_current_step]
		var actions: Array = step.get("actions", [])
		for action in actions:
			var atype: String = String(action.get("type", ""))
			if atype == "start_waves" or atype == "stop_waves":
				continue
			_execute_action(action)
	# Invalidate rendering caches for hidden tiles
	_invalidate_caches()
	print("SectorScript: Restored runtime state at step %d, running=%s" % [_current_step, _script_running])
	# Rescue path for legacy saves that don't carry waves_runtime: if a
	# past step contained a `start_waves` action, kick the WaveManager
	# now (script-mode sectors otherwise come up cold because the
	# script has already advanced past the trigger). Defer one frame so
	# the WaveManager's own deferred `load_runtime` (queued from
	# SaveManager) lands first — otherwise we'd kick start() on a
	# WaveManager that hasn't yet had its saved state restored, and
	# wm.start() would clobber the restore.
	call_deferred("_rescue_wave_manager_after_load")


func _rescue_wave_manager_after_load() -> void:
	var wm = get_node_or_null("/root/Main/WaveManager")
	if wm == null:
		return
	# If runtime restore already armed it (or it never auto-stopped),
	# leave it alone. The `_runtime_loaded` flag covers legitimate
	# "running = false" states from the save (e.g. a sector saved AFTER
	# all waves were defeated) — without this gate, rescue would re-arm
	# wave 1 on every reload and the user would see a fresh countdown.
	if bool(wm.get("_runtime_loaded")):
		return
	if bool(wm.get("_running")):
		return
	# Sectors that haven't reached the start_waves step yet should keep
	# waves dormant — only retroactively start once we're past it.
	var trigger_passed := false
	var stop_after_trigger := false
	var upper: int = _current_step
	if upper > _script_steps.size():
		upper = _script_steps.size()
	for i in range(0, upper):
		var step: Dictionary = _script_steps[i]
		for action in step.get("actions", []):
			match String(action.get("type", "")):
				"start_waves":
					trigger_passed = true
					stop_after_trigger = false
				"stop_waves":
					stop_after_trigger = true
	if trigger_passed and not stop_after_trigger and wm.has_method("start"):
		wm.call_deferred("start")
		print("SectorScript: Re-armed WaveManager (legacy save without waves_runtime).")


## Helper: convert StringName-keyed dict to String-keyed for JSON.
static func _dict_sname_to_str(d: Dictionary) -> Dictionary:
	var result := {}
	for k in d:
		result[str(k)] = d[k]
	return result


## Helper: convert String-keyed dict back to StringName-keyed.
static func _dict_str_to_sname(d: Dictionary) -> Dictionary:
	var result := {}
	for k in d:
		result[StringName(k)] = int(d[k])
	return result


## Returns an array of objective dicts for the current step's conditions.
## Each dict: {"text": String, "current": int, "target": int, "done": bool}
## Returns empty array if no script is running or step has no trackable conditions.
func get_current_objectives() -> Array:
	if not _script_running or _current_step < 0 or _current_step >= _script_steps.size():
		return []
	var step: Dictionary = _script_steps[_current_step]
	var conditions: Array = _get_step_conditions(step)
	var objectives: Array = []
	for cond in conditions:
		var obj: Dictionary = _get_objective_for_condition(cond)
		if not obj.is_empty():
			objectives.append(obj)
	return objectives


## Converts a single condition dict into an objective dict with progress info.
func _get_objective_for_condition(cond: Dictionary) -> Dictionary:
	var cond_type: String = cond.get("type", "always")
	match cond_type:
		"always":
			return {}  # No objective for instant advance
		"wait":
			return {}
		"mined":
			var item_id := StringName(cond.get("item_id", ""))
			var amount := int(cond.get("amount", 1))
			var current := get_mined_count(item_id)
			var name: String = _get_display_name_item(item_id)
			return {"text": "Mine %s" % name, "current": mini(current, amount), "target": amount, "done": current >= amount}
		"deposited":
			var item_id := StringName(cond.get("item_id", ""))
			var amount := int(cond.get("amount", 1))
			var baseline := int(_step_deposited_baselines.get(item_id, 0))
			var current := int(main.resources.get(item_id, 0)) - baseline
			var name: String = _get_display_name_item(item_id)
			return {"text": "Deposit %s" % name, "current": clampi(current, 0, amount), "target": amount, "done": current >= amount}
		"produced":
			var item_id := StringName(cond.get("item_id", ""))
			var amount := int(cond.get("amount", 1))
			var current := get_produced_count(item_id)
			var name: String = _get_display_name_item(item_id)
			return {"text": "Produce %s" % name, "current": mini(current, amount), "target": amount, "done": current >= amount}
		"placed":
			var block_id := StringName(cond.get("block_id", ""))
			var amount := int(cond.get("amount", 1))
			var baseline := int(_step_placed_baselines.get(block_id, 0))
			var current := int(_placed_counts.get(block_id, 0)) - baseline
			var name: String = _get_display_name_block(block_id)
			return {"text": "Place %s" % name, "current": clampi(current, 0, amount), "target": amount, "done": current >= amount}
		"units_produced":
			var unit_id := StringName(cond.get("unit_id", ""))
			var amount := int(cond.get("amount", 1))
			var current := get_units_produced_count(unit_id)
			var name: String = _get_display_name_unit(unit_id)
			return {"text": "Produce %s" % name, "current": mini(current, amount), "target": amount, "done": current >= amount}
		"units_destroyed":
			var unit_id := StringName(cond.get("unit_id", ""))
			var amount := int(cond.get("amount", 1))
			var current := get_ferox_units_destroyed_count(unit_id)
			var name: String = _get_display_name_unit(unit_id)
			return {"text": "Destroy %s" % name, "current": mini(current, amount), "target": amount, "done": current >= amount}
		"ferox_blocks_destroyed":
			var block_id := StringName(cond.get("block_id", ""))
			var amount := int(cond.get("amount", 1))
			var current := get_ferox_blocks_destroyed_count(block_id)
			var name: String = _get_display_name_block(block_id)
			return {"text": "Destroy FEROX %s" % name, "current": mini(current, amount), "target": amount, "done": current >= amount}
		"core_unit_mined":
			var item_id := StringName(cond.get("item_id", ""))
			var amount := int(cond.get("amount", 1))
			var current := get_core_unit_mined_count(item_id)
			var name: String = _get_display_name_item(item_id)
			return {"text": "Mine %s (Core Unit)" % name, "current": mini(current, amount), "target": amount, "done": current >= amount}
		"block_has_item":
			var item_id := StringName(cond.get("item_id", ""))
			var amount := int(cond.get("amount", 1))
			var name: String = _get_display_name_item(item_id)
			return {"text": "%s in block storage" % name, "current": 0, "target": amount, "done": false}
	return {}


func _get_display_name_item(item_id: StringName) -> String:
	var data = Registry.get_item_or_fluid(item_id)
	return data.display_name if data and data.display_name != "" else str(item_id)


func _get_display_name_block(block_id: StringName) -> String:
	var data = Registry.get_block(block_id)
	return data.display_name if data and data.display_name != "" else str(block_id)


func _get_display_name_unit(unit_id: StringName) -> String:
	var data = Registry.get_unit(unit_id)
	return data.display_name if data and data.display_name != "" else str(unit_id)


## Execute on_enter actions for a step.
func _enter_step(idx: int) -> void:
	var step: Dictionary = _script_steps[idx]
	var actions: Array = step.get("actions", [])
	for action in actions:
		_execute_action(action)

	# Set up per-condition state
	var conditions: Array = _get_step_conditions(step)
	_step_deposited_baselines.clear()
	_step_placed_baselines.clear()
	for cond in conditions:
		match cond.get("type", ""):
			"wait":
				_step_wait_timer = float(cond.get("seconds", 3.0))
			"deposited":
				# Snapshot current inventory so we measure relative increase
				var item_id := StringName(cond.get("item_id", ""))
				_step_deposited_baselines[item_id] = main.resources.get(item_id, 0)
			"placed":
				# Snapshot current placed count so we measure relative increase
				var block_id := StringName(cond.get("block_id", ""))
				_step_placed_baselines[block_id] = _placed_counts.get(block_id, 0)

	print("SectorScript: Entered step %d: %s" % [idx, step.get("name", "?")])


## Execute on_exit actions for a step.
func _exit_step(idx: int) -> void:
	var step: Dictionary = _script_steps[idx]
	var exit_actions: Array = step.get("on_exit", [])
	for action in exit_actions:
		_execute_action(action)


## Execute a single action dictionary.
func _execute_action(action: Dictionary) -> void:
	var action_type: String = action.get("type", "")
	match action_type:
		"pause":
			pause_world()
		"unpause":
			unpause_world()
		"focus_camera":
			var pos_str: String = str(action.get("pos", "50,50"))
			var parts = pos_str.split(",")
			if parts.size() >= 2:
				focus_camera_grid(Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges())))
		"release_camera":
			release_camera()
		"draw_box":
			var box_id: String = action.get("id", "box")
			var from_str: String = str(action.get("from", "0,0"))
			var to_str: String = str(action.get("to", "0,0"))
			var from_parts = from_str.split(",")
			var to_parts = to_str.split(",")
			var from_pos := Vector2i(int(from_parts[0].strip_edges()), int(from_parts[1].strip_edges())) if from_parts.size() >= 2 else Vector2i.ZERO
			var to_pos := Vector2i(int(to_parts[0].strip_edges()), int(to_parts[1].strip_edges())) if to_parts.size() >= 2 else Vector2i.ZERO
			var color_name: String = action.get("color", "yellow")
			var color: Color = NAMED_COLORS.get(color_name, Color.YELLOW)
			draw_box(box_id, from_pos, to_pos, color)
		"remove_box":
			remove_box(action.get("id", ""))
		"clear_boxes":
			clear_boxes()
		"draw_text":
			var text_id: String = action.get("id", "text")
			var from_str: String = str(action.get("from", "0,0"))
			var to_str: String = str(action.get("to", "0,0"))
			var from_parts = from_str.split(",")
			var to_parts = to_str.split(",")
			var from_pos := Vector2i(int(from_parts[0].strip_edges()), int(from_parts[1].strip_edges())) if from_parts.size() >= 2 else Vector2i.ZERO
			var to_pos := Vector2i(int(to_parts[0].strip_edges()), int(to_parts[1].strip_edges())) if to_parts.size() >= 2 else Vector2i.ZERO
			var text: String = action.get("text", "")
			draw_text_overlay(text_id, from_pos, to_pos, text)
		"remove_text":
			remove_text_overlay(action.get("id", ""))
		"clear_texts":
			clear_text_overlays()
		"disable_block":
			var pos_str: String = str(action.get("pos", "0,0"))
			var parts = pos_str.split(",")
			if parts.size() >= 2:
				disable_building(Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges())))
		"enable_block":
			var pos_str: String = str(action.get("pos", "0,0"))
			var parts = pos_str.split(",")
			if parts.size() >= 2:
				enable_building(Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges())))
		"spawn_unit":
			var pos_str: String = str(action.get("pos", "50,50"))
			var parts = pos_str.split(",")
			if parts.size() >= 2:
				var grid_pos := Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))
				var world_pos: Vector2 = main.grid_to_world(grid_pos) + Vector2(main.GRID_SIZE / 2.0, main.GRID_SIZE / 2.0)
				var unit_id := StringName(action.get("unit_id", ""))
				var faction_str: String = action.get("faction", "ferox")
				var count := int(action.get("count", 1))
				var unit_mgr = get_node_or_null("/root/Main/UnitManager")
				if unit_mgr:
					for _i in range(count):
						if faction_str == "lumina":
							unit_mgr.spawn_player_unit(world_pos, unit_id)
						else:
							unit_mgr.spawn_enemy(world_pos, unit_id)
					print("SectorScript: Spawned %d %s unit(s) '%s' at %s" % [count, faction_str, unit_id, grid_pos])
		"hide_region":
			var from_str: String = str(action.get("from", "0,0"))
			var to_str: String = str(action.get("to", "0,0"))
			var from_parts = from_str.split(",")
			var to_parts = to_str.split(",")
			var from_pos := Vector2i(int(from_parts[0].strip_edges()), int(from_parts[1].strip_edges())) if from_parts.size() >= 2 else Vector2i.ZERO
			var to_pos := Vector2i(int(to_parts[0].strip_edges()), int(to_parts[1].strip_edges())) if to_parts.size() >= 2 else Vector2i.ZERO
			var inc_floors: bool = action.get("include_floors", true)
			hide_region(from_pos, to_pos, inc_floors)
		"reveal_region":
			var from_str: String = str(action.get("from", "0,0"))
			var to_str: String = str(action.get("to", "0,0"))
			var from_parts = from_str.split(",")
			var to_parts = to_str.split(",")
			var from_pos := Vector2i(int(from_parts[0].strip_edges()), int(from_parts[1].strip_edges())) if from_parts.size() >= 2 else Vector2i.ZERO
			var to_pos := Vector2i(int(to_parts[0].strip_edges()), int(to_parts[1].strip_edges())) if to_parts.size() >= 2 else Vector2i.ZERO
			reveal_region(from_pos, to_pos)
		"capture_sector":
			var sector_id: StringName = SaveManager.active_sector_id
			if sector_id != &"":
				main.sector_captured.emit(sector_id)
				SaveManager.save_campaign()
				print("SectorScript: Sector '%s' captured!" % sector_id)
			else:
				print("SectorScript: capture_sector — no active sector ID set.")
		"start_waves":
			# Fires off the WaveManager from whatever wave is currently
			# armed. Useful as a sector-script trigger so designers can
			# gate the first wave behind a step rather than an absolute
			# map-start timer.
			var wm_s = get_node_or_null("/root/Main/WaveManager")
			if wm_s and wm_s.has_method("start"):
				wm_s.start()
				print("SectorScript: Waves started.")
		"stop_waves":
			# Halts wave scheduling. Any currently-alive enemies stay
			# alive — this only prevents FUTURE waves from spawning.
			var wm_x = get_node_or_null("/root/Main/WaveManager")
			if wm_x and wm_x.has_method("stop"):
				wm_x.stop()
				print("SectorScript: Waves stopped.")


# =========================
# UNIT EVENT TRACKING (called externally by UnitManager)
# =========================

## Called when a unit is spawned by a fabricator.
func on_unit_produced(unit_id: StringName) -> void:
	_units_produced_counts[unit_id] = _units_produced_counts.get(unit_id, 0) + 1


## Called when a FEROX unit dies.
func on_ferox_unit_destroyed(unit_id: StringName) -> void:
	_units_destroyed_counts[unit_id] = _units_destroyed_counts.get(unit_id, 0) + 1


# =========================
# RESET ALL TRACKING
# =========================

func reset_all() -> void:
	_mined_counts.clear()
	_core_counts.clear()
	_produced_counts.clear()
	_placed_counts.clear()
	_units_produced_counts.clear()
	_units_destroyed_counts.clear()
	_ferox_blocks_destroyed_counts.clear()
	_ferox_specific_destroyed.clear()
	_core_unit_mined_counts.clear()
	_decoded_archive_counts.clear()
	_step_deposited_baselines.clear()
	_step_placed_baselines.clear()
	_disabled_buildings.clear()
	_hidden_tiles.clear()
	clear_boxes()


# =========================
# SIGNAL HANDLERS (private)
# =========================

func _on_item_mined(item_id: StringName) -> void:
	_mined_counts[item_id] = _mined_counts.get(item_id, 0) + 1


func _on_item_absorbed_in_core(item_id: StringName) -> void:
	_core_counts[item_id] = _core_counts.get(item_id, 0) + 1


func _on_core_unit_item_mined(item_id: StringName) -> void:
	_core_unit_mined_counts[item_id] = _core_unit_mined_counts.get(item_id, 0) + 1


## Fired by Main.archive_decoded once an archive_decoder building finishes
## its cycle. Increments both the specific-archive counter AND an
## "any archive" bucket keyed by &"" so sector authors can write either
## "wait until archive X is decoded" or "wait until any archive is
## decoded" without needing two separate signals.
func _on_archive_decoded(archive_id: StringName) -> void:
	_decoded_archive_counts[archive_id] = _decoded_archive_counts.get(archive_id, 0) + 1
	_decoded_archive_counts[&""] = _decoded_archive_counts.get(&"", 0) + 1


func _on_item_produced(item_id: StringName) -> void:
	_produced_counts[item_id] = _produced_counts.get(item_id, 0) + 1


func _on_building_placed(block_id: StringName, _grid_pos: Vector2i) -> void:
	_placed_counts[block_id] = _placed_counts.get(block_id, 0) + 1


func _on_building_destroyed(grid_pos: Vector2i) -> void:
	# Check if this was a FEROX building
	if main.get_building_faction(grid_pos) == main.Faction.FEROX:
		var block_id: StringName = main.placed_buildings.get(grid_pos, &"")
		if block_id != &"":
			_ferox_blocks_destroyed_counts[block_id] = _ferox_blocks_destroyed_counts.get(block_id, 0) + 1
			var key := "%s:%d:%d" % [block_id, grid_pos.x, grid_pos.y]
			_ferox_specific_destroyed[key] = true


# =========================
# HINTS
# =========================

## Replaces the current hint set. Resets per-hint runtime so a re-launch
## starts every pending hint waiting for its trigger again.
##
## Sector hints come from the per-sector save / editor; global hints are
## merged in from SaveManager so a hint authored once activates on every
## sector. Dismissed-state for globals is seeded from
## SaveManager.global_hints_runtime so a global hint that was already
## acknowledged in another sector / session stays dismissed here.
func load_hints(hints: Array) -> void:
	_hints = hints.duplicate(true)
	_hint_runtime.clear()
	_hint_landing_fired = false
	_hint_clock = 0.0

	# Strip any stale globals that may have leaked into the sector save
	# (older builds didn't filter them out on serialize), then re-merge
	# the canonical list from SaveManager.
	var filtered: Array = []
	for h in _hints:
		if h is Dictionary and bool(h.get("global", false)):
			continue
		filtered.append(h)
	_hints = filtered

	var sm = get_node_or_null("/root/SaveManager")
	if sm and sm.get("global_hints") is Array:
		for gh in sm.global_hints:
			if not (gh is Dictionary):
				continue
			var entry: Dictionary = gh.duplicate(true)
			entry["global"] = true
			_hints.append(entry)
			# Seed dismissed state from the campaign-level runtime so a
			# previously-acknowledged global stays acknowledged here.
			var gid := String(entry.get("id", ""))
			if gid != "":
				var rt: Dictionary = sm.get_global_hint_runtime(gid)
				if not rt.is_empty():
					_hint_runtime[gid] = rt

	hints_cleared.emit()


func get_hints() -> Array:
	return _hints.duplicate(true)


## Called by the HUD when the player clicks the hint's OK button. Only
## dismisses hints whose `remove_when` is `user_pressed_ok` — for any
## other remove condition the click is ignored, mirroring how the panel
## hides its OK button when `can_be_ignored` is false.
func acknowledge_hint(hint_id: String) -> void:
	for h in _hints:
		if String(h.get("id", "")) != hint_id:
			continue
		var rw_type: String = String(h.get("remove_when", {}).get("type", "user_pressed_ok"))
		if rw_type != "user_pressed_ok":
			return
		_finish_hint(h)
		return


func _hint_state(id: String) -> String:
	return String(_hint_runtime.get(id, {}).get("state", "pending"))


func _set_hint_state(id: String, st: String) -> void:
	if not _hint_runtime.has(id):
		_hint_runtime[id] = {}
	_hint_runtime[id]["state"] = st


func _activate_hint(h: Dictionary) -> void:
	var id := String(h.get("id", ""))
	print("SectorScript: activating hint '%s' (text=%s)" % [id, String(h.get("text", "")).left(40)])
	# Snapshot the relevant counters so the remove condition only fires
	# for events that happen *after* the hint became visible.
	var rw: Dictionary = h.get("remove_when", {})
	var baselines: Dictionary = {}
	var sentinel = null
	match String(rw.get("type", "")):
		"block_placed":
			var bid := StringName(rw.get("block_id", ""))
			baselines[bid] = int(_placed_counts.get(bid, 0))
		"item_produced":
			var iid := StringName(rw.get("item_id", ""))
			baselines[iid] = int(_produced_counts.get(iid, 0))
		"units_produced":
			var uid := StringName(rw.get("unit_id", ""))
			baselines[uid] = int(_units_produced_counts.get(uid, 0))
		"block_changed":
			var pos: Vector2i = _parse_vec2i_arg(rw.get("position", Vector2i.ZERO))
			sentinel = main.placed_buildings.get(pos, &"") if main else &""
	_hint_runtime[id] = {
		"state": "active",
		"baselines": baselines,
		"activated_at": _hint_clock,
		"sentinel": sentinel,
	}
	# Mirror runtime to SaveManager for global hints so re-landing this
	# (or any other) sector picks up where the activation left off.
	if bool(h.get("global", false)):
		var sm = get_node_or_null("/root/SaveManager")
		if sm and sm.has_method("set_global_hint_runtime"):
			sm.set_global_hint_runtime(id, _hint_runtime[id])
	hint_show.emit(h)


func _finish_hint(h: Dictionary) -> void:
	var id := String(h.get("id", ""))
	_set_hint_state(id, "dismissed")
	# Globals: persist the dismissal at campaign level so this hint won't
	# reactivate when the player lands on a different sector.
	if bool(h.get("global", false)):
		var sm = get_node_or_null("/root/SaveManager")
		if sm and sm.has_method("set_global_hint_runtime"):
			sm.set_global_hint_runtime(id, _hint_runtime.get(id, {"state": "dismissed"}))
	hint_hide.emit(id)


func _check_hint_condition(c: Dictionary) -> bool:
	match String(c.get("type", "")):
		"landing":
			return _hint_landing_fired
		"time_after":
			return _hint_clock >= float(c.get("seconds", 0.0))
		"block_placed":
			return int(_placed_counts.get(StringName(c.get("block_id", "")), 0)) \
				>= int(c.get("amount", 1))
		"item_produced":
			return int(_produced_counts.get(StringName(c.get("item_id", "")), 0)) \
				>= int(c.get("amount", 1))
		"units_produced":
			return int(_units_produced_counts.get(StringName(c.get("unit_id", "")), 0)) \
				>= int(c.get("amount", 1))
	return false


func _check_hint_remove(h: Dictionary, runtime: Dictionary) -> bool:
	var rw: Dictionary = h.get("remove_when", {})
	match String(rw.get("type", "")):
		"user_pressed_ok":
			# Only the HUD dismisses these (via acknowledge_hint).
			return false
		"block_placed":
			var bid := StringName(rw.get("block_id", ""))
			var base: int = int(runtime.get("baselines", {}).get(bid, 0))
			return int(_placed_counts.get(bid, 0)) >= base + int(rw.get("amount", 1))
		"item_produced":
			var iid := StringName(rw.get("item_id", ""))
			var base_i: int = int(runtime.get("baselines", {}).get(iid, 0))
			return int(_produced_counts.get(iid, 0)) >= base_i + int(rw.get("amount", 1))
		"units_produced":
			var uid := StringName(rw.get("unit_id", ""))
			var base_u: int = int(runtime.get("baselines", {}).get(uid, 0))
			return int(_units_produced_counts.get(uid, 0)) >= base_u + int(rw.get("amount", 1))
		"block_changed":
			var pos: Vector2i = _parse_vec2i_arg(rw.get("position", Vector2i.ZERO))
			var current: StringName = main.placed_buildings.get(pos, &"") if main else &""
			return current != runtime.get("sentinel", &"")
	return false


func _tick_hints() -> void:
	if not _hint_landing_fired:
		_hint_landing_fired = true
	if _hints.is_empty():
		return
	for h in _hints:
		var id := String(h.get("id", ""))
		if id == "":
			continue
		var st := _hint_state(id)
		if st == "dismissed":
			continue
		if st == "pending":
			if _check_hint_condition(h.get("condition", {})):
				_activate_hint(h)
			continue
		# active
		if _check_hint_remove(h, _hint_runtime.get(id, {})):
			_finish_hint(h)


func _parse_vec2i_arg(raw: Variant) -> Vector2i:
	if raw is Vector2i:
		return raw
	if raw is Array and raw.size() >= 2:
		return Vector2i(int(raw[0]), int(raw[1]))
	if raw is Dictionary:
		return Vector2i(int(raw.get("x", 0)), int(raw.get("y", 0)))
	if raw is String:
		var parts = raw.split(",")
		if parts.size() >= 2:
			return Vector2i(int(parts[0]), int(parts[1]))
	return Vector2i.ZERO


## Returns hint runtime for save/load.
func get_hints_runtime_state() -> Dictionary:
	return {
		"runtime": _hint_runtime.duplicate(true),
		"clock": _hint_clock,
		"landing_fired": _hint_landing_fired,
	}


func load_hints_runtime_state(state: Dictionary) -> void:
	_hint_runtime = state.get("runtime", {}).duplicate(true) if state.get("runtime") is Dictionary else {}
	_hint_clock = float(state.get("clock", 0.0))
	_hint_landing_fired = bool(state.get("landing_fired", false))
	# Re-emit show events for any active hints so the HUD re-displays them.
	for h in _hints:
		var id := String(h.get("id", ""))
		if _hint_state(id) == "active":
			hint_show.emit(h)
