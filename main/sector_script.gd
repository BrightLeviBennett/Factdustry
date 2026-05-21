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

# --- SCRIPT STEP RUNNER (DAG mode) ---
# Steps form a directed acyclic graph. Each step may declare:
#   "dependencies":   Array[int] — step indices that must be completed.
#                     Missing/empty defaults to LINEAR back-compat:
#                     step i depends on step i-1.
#   "flags_required": Array[String] — global flags that must be set for
#                     the step to be considered eligible to start.
#   "flags_set":      Array[String] — flags set on completion (in
#                     addition to anything `set_flag` actions did).
#   "markers":        Array[Dictionary] — visual annotations spawned on
#                     _enter_step and cleaned automatically on _exit_step.
# Old linear scripts (no dependencies field on any step) still work via
# the back-compat conversion in `load_script_steps`.
var _script_steps: Array = []
## Per-step "wait" timers, keyed by step index. Previously a single
## global timer (only the active step could "wait"); now multiple steps
## can be active simultaneously so each gets its own.
var _step_wait_timers: Dictionary = {}     # int (step idx) -> float
## Set of step indices currently active (eligible & not yet completed).
var _active_steps: Dictionary = {}         # int -> true
## Set of step indices already completed (conditions met + exit fired).
var _completed_steps: Dictionary = {}      # int -> true
var _script_running := false

# --- NAMED FLAGS ---
# Cross-step boolean state for the DAG. Set via `set_flag` action /
# `flags_set` step field, cleared via `clear_flag`. Steps can gate
# eligibility on `flags_required` and conditions can check `flag`.
var _flags: Dictionary = {}                # String -> bool

# Reverse-edge cache for the DAG. step_idx -> Array[int] of dependents
# (steps that have this one as a dependency). Built lazily by
# `_get_dependents` and invalidated by `load_script_steps`.
var _dependents_cache: Dictionary = {}

# Legacy single-step pointer. Now derived from the highest-index active
# or completed step so old HUD bindings that read `_current_step`
# directly still get a sensible answer.
var _current_step: int = -1
# Legacy single-step wait timer. Mirrors _step_wait_timers[_current_step]
# during back-compat reads so save files written by the old runtime
# round-trip cleanly.
var _step_wait_timer: float = 0.0

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
	# Sector-script highlight boxes / scripted text are tutorial / hint
	# overlays — they need to paint above the entire game world so the
	# player actually sees what's being pointed at. Above buildings (50),
	# above conveyor items (51), above steam (52), above units (53) so
	# nothing in the gameplay scene can hide them. HUD popups still win
	# (they live on a CanvasLayer).
	z_index = 60
	z_as_relative = false
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
	if not _script_running or _script_steps.is_empty():
		return

	# DAG tick: every active step is checked independently. A step
	# completes when ALL its conditions are met (AND). Completing a step
	# may unblock other steps via dependencies / flags_set.
	var newly_completed: Array[int] = []
	for idx in _active_steps.keys():
		if _completed_steps.has(idx):
			continue
		var step: Dictionary = _script_steps[idx]
		var conditions: Array = _get_step_conditions(step)
		var advance := true
		for cond in conditions:
			if not _check_condition_for_step(cond, delta, idx):
				advance = false
		if advance:
			newly_completed.append(idx)

	# Resolve completions: fire exit actions, set step-level flags, then
	# scan the script for any new steps whose deps/flags are satisfied.
	for idx in newly_completed:
		_complete_step(idx)
	if not newly_completed.is_empty():
		_activate_eligible_steps()
		_recompute_current_step()

	# Script ends when every step is completed (no more work possible).
	if _active_steps.is_empty():
		_script_running = false
		_current_step = -1
		print("SectorScript: All steps complete.")


## Get the conditions array from a step, handling both old and new formats.
func _get_step_conditions(step: Dictionary) -> Array:
	if step.has("conditions") and step["conditions"] is Array and not step["conditions"].is_empty():
		return step["conditions"]
	if step.has("condition") and step["condition"] is Dictionary:
		return [step["condition"]]
	return [{"type": "always"}]


## Per-step condition check. The DAG runtime ticks several steps in
## parallel so each step's "wait" timer lives in `_step_wait_timers`
## keyed by step index, rather than the singleton it used to be.
func _check_condition_for_step(cond: Dictionary, delta: float, step_idx: int) -> bool:
	var cond_type: String = cond.get("type", "always")
	if cond_type == "wait":
		var t: float = float(_step_wait_timers.get(step_idx, 0.0)) - delta
		_step_wait_timers[step_idx] = t
		# Mirror to the legacy single-timer so save/load round-trip stays
		# meaningful for old consumers.
		if step_idx == _current_step:
			_step_wait_timer = t
		return t <= 0.0
	# Everything else is timer-independent and just defers to the
	# legacy single-condition checker (which now treats "wait" as a
	# no-op fallback).
	return _check_condition(cond, delta)


## Check whether a single condition is met. Returns true if satisfied.
func _check_condition(cond: Dictionary, delta: float) -> bool:
	var cond_type: String = cond.get("type", "always")
	match cond_type:
		"always":
			return true
		"wait":
			_step_wait_timer -= delta
			return _step_wait_timer <= 0.0
		"flag":
			# New flag-based condition. Defaults to checking truthiness of
			# the named flag, but `value: false` lets you require ABSENCE
			# of a flag for OR-style "branch on outcome" graphs.
			var fname: String = String(cond.get("name", ""))
			var want: bool = bool(cond.get("value", true))
			return bool(_flags.get(fname, false)) == want
		"descendants_done":
			# Used by marker-only steps emitted by the node-graph editor.
			# The step lingers (markers stay visible) until every step that
			# transitively depends on it has completed. `step_idx` is
			# stamped onto the condition at build-time so we know which
			# step we're checking.
			var step_idx: int = int(cond.get("step_idx", -1))
			if step_idx < 0:
				# Without a step_idx we can't compute descendants — fall
				# back to "immediately done" so the step doesn't hang.
				return true
			return _all_descendants_completed(step_idx)
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
	"brown": Color.SADDLE_BROWN, "purple": Color.DARK_ORCHID, "gold": Color.PEACH_PUFF
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
	# Stamp `step_idx` onto every descendants_done condition so the
	# runtime knows which step to check dependents for. Authors don't
	# have to set this themselves.
	for i in range(_script_steps.size()):
		var step: Dictionary = _script_steps[i]
		for cond in step.get("conditions", []):
			if String(cond.get("type", "")) == "descendants_done":
				cond["step_idx"] = i
	_dependents_cache.clear()
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
	_step_wait_timers.clear()
	_active_steps.clear()
	_completed_steps.clear()
	_flags.clear()
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


## Start executing the script. In DAG mode, every step whose
## dependencies are empty (or transitively satisfied) AND whose
## `flags_required` is empty is activated immediately. Old linear
## scripts only have step 0 eligible at start because each subsequent
## step depends on the previous via the back-compat rule.
func start_script() -> void:
	if _script_steps.is_empty():
		return
	_script_running = true
	_active_steps.clear()
	_completed_steps.clear()
	_step_wait_timers.clear()
	_activate_eligible_steps()
	_recompute_current_step()


## Returns the script runtime state as a serializable dictionary.
func get_runtime_state() -> Dictionary:
	var hidden_arr: Array = []
	for pos in _hidden_tiles:
		hidden_arr.append("%d,%d" % [pos.x, pos.y])
	var disabled_arr: Array = []
	for pos in _disabled_buildings:
		disabled_arr.append("%d,%d" % [pos.x, pos.y])
	# Serialize DAG state — active set, completed set, per-step wait
	# timers, and the global flag dictionary.
	var active_arr: Array = []
	for k in _active_steps.keys():
		active_arr.append(int(k))
	var completed_arr: Array = []
	for k in _completed_steps.keys():
		completed_arr.append(int(k))
	var wait_timers_dict: Dictionary = {}
	for k in _step_wait_timers.keys():
		wait_timers_dict[str(k)] = float(_step_wait_timers[k])
	var flags_dict: Dictionary = {}
	for k in _flags.keys():
		flags_dict[String(k)] = bool(_flags[k])
	return {
		"current_step": _current_step,
		"script_running": _script_running,
		"step_wait_timer": _step_wait_timer,
		"active_steps": active_arr,
		"completed_steps": completed_arr,
		"step_wait_timers": wait_timers_dict,
		"flags": flags_dict,
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
	# DAG state. Old saves don't have these — fall back to "rebuild
	# from current_step + linear deps".
	_active_steps.clear()
	for k in state.get("active_steps", []):
		_active_steps[int(k)] = true
	_completed_steps.clear()
	for k in state.get("completed_steps", []):
		_completed_steps[int(k)] = true
	_step_wait_timers.clear()
	var wt_dict: Dictionary = state.get("step_wait_timers", {})
	for k in wt_dict:
		_step_wait_timers[int(k)] = float(wt_dict[k])
	_flags.clear()
	var f_dict: Dictionary = state.get("flags", {})
	for k in f_dict:
		_flags[String(k)] = bool(f_dict[k])
	# Legacy rebuild: if active/completed weren't in the save but
	# `current_step` was, treat steps [0 .. current_step-1] as
	# completed and `current_step` as active.
	if _active_steps.is_empty() and _script_running and _current_step >= 0 \
			and _current_step < _script_steps.size():
		for i in range(_current_step):
			_completed_steps[i] = true
		_active_steps[_current_step] = true
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
	# Replay on_enter actions + markers for every currently-active step
	# to restore visual state (draw_box, draw_text, pause, etc.). Side-
	# effect actions like start_waves / stop_waves must NOT be replayed
	# — WaveManager runtime has already been restored by this point,
	# and re-running start_waves would clobber its state.
	if _script_running:
		for idx in _active_steps.keys():
			if int(idx) < 0 or int(idx) >= _script_steps.size():
				continue
			var step: Dictionary = _script_steps[int(idx)]
			var actions: Array = step.get("actions", [])
			for action in actions:
				var atype: String = String(action.get("type", ""))
				if atype == "start_waves" or atype == "stop_waves":
					continue
				_execute_action(action)
			# Markers attached to the step replay too — they're
			# considered visual state, not side effects.
			_spawn_step_markers(int(idx))
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
	# DAG-aware: walk every COMPLETED step rather than a linear prefix
	# so a converted DAG with branching still finds the trigger.
	var trigger_passed := false
	var stop_after_trigger := false
	for idx in _completed_steps.keys():
		var i: int = int(idx)
		if i < 0 or i >= _script_steps.size():
			continue
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
	if not _script_running:
		return []
	var objectives: Array = []
	# Gather objectives from every active step (DAG-aware). When the
	# script is fully linear there's at most one active step, so this
	# stays equivalent to the old behaviour. With a DAG it surfaces
	# every parallel sub-goal the player is currently chasing.
	var indices: Array = _active_steps.keys()
	indices.sort()  # stable rendering order
	for k in indices:
		var idx: int = int(k)
		if idx < 0 or idx >= _script_steps.size():
			continue
		var step: Dictionary = _script_steps[idx]
		var conditions: Array = _get_step_conditions(step)
		for cond in conditions:
			var obj: Dictionary = _get_objective_for_condition(cond)
			if not obj.is_empty():
				objectives.append(obj)
	return objectives


## Converts a single condition dict into an objective dict with progress info.
##
## Each objective dict carries the rendered `text`, the progress fields,
## and an `icon` (Texture2D) when the objective targets a specific item /
## block / unit — the HUD shows that icon between the bullet and the
## label so the player can match the wording to a familiar sprite.
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
			return {"text": "Mine %s" % name, "icon": _get_item_icon(item_id), "current": mini(current, amount), "target": amount, "done": current >= amount}
		"deposited":
			var item_id := StringName(cond.get("item_id", ""))
			var amount := int(cond.get("amount", 1))
			var baseline := int(_step_deposited_baselines.get(item_id, 0))
			var current := int(main.resources.get(item_id, 0)) - baseline
			var name: String = _get_display_name_item(item_id)
			return {"text": "Deposit %s" % name, "icon": _get_item_icon(item_id), "current": clampi(current, 0, amount), "target": amount, "done": current >= amount}
		"produced":
			var item_id := StringName(cond.get("item_id", ""))
			var amount := int(cond.get("amount", 1))
			var current := get_produced_count(item_id)
			var name: String = _get_display_name_item(item_id)
			return {"text": "Produce %s" % name, "icon": _get_item_icon(item_id), "current": mini(current, amount), "target": amount, "done": current >= amount}
		"placed":
			var block_id := StringName(cond.get("block_id", ""))
			var amount := int(cond.get("amount", 1))
			var baseline := int(_step_placed_baselines.get(block_id, 0))
			var current := int(_placed_counts.get(block_id, 0)) - baseline
			var name: String = _get_display_name_block(block_id)
			return {"text": "Place %s" % name, "icon": _get_block_icon(block_id), "current": clampi(current, 0, amount), "target": amount, "done": current >= amount}
		"units_produced":
			var unit_id := StringName(cond.get("unit_id", ""))
			var amount := int(cond.get("amount", 1))
			var current := get_units_produced_count(unit_id)
			var name: String = _get_display_name_unit(unit_id)
			return {"text": "Produce %s" % name, "icon": _get_unit_icon(unit_id), "current": mini(current, amount), "target": amount, "done": current >= amount}
		"units_destroyed":
			var unit_id := StringName(cond.get("unit_id", ""))
			var amount := int(cond.get("amount", 1))
			var current := get_ferox_units_destroyed_count(unit_id)
			var name: String = _get_display_name_unit(unit_id)
			return {"text": "Destroy %s" % name, "icon": _get_unit_icon(unit_id), "current": mini(current, amount), "target": amount, "done": current >= amount}
		"ferox_blocks_destroyed":
			var block_id := StringName(cond.get("block_id", ""))
			var amount := int(cond.get("amount", 1))
			var current := get_ferox_blocks_destroyed_count(block_id)
			var name: String = _get_display_name_block(block_id)
			return {"text": "Destroy FEROX %s" % name, "icon": _get_block_icon(block_id), "current": mini(current, amount), "target": amount, "done": current >= amount}
		"core_unit_mined":
			var item_id := StringName(cond.get("item_id", ""))
			var amount := int(cond.get("amount", 1))
			var current := get_core_unit_mined_count(item_id)
			var name: String = _get_display_name_item(item_id)
			return {"text": "Mine %s (Core Unit)" % name, "icon": _get_item_icon(item_id), "current": mini(current, amount), "target": amount, "done": current >= amount}
		"block_has_item":
			var item_id := StringName(cond.get("item_id", ""))
			var amount := int(cond.get("amount", 1))
			var name: String = _get_display_name_item(item_id)
			return {"text": "%s in block storage" % name, "icon": _get_item_icon(item_id), "current": 0, "target": amount, "done": false}
	return {}


## Icon helpers — return null when the id doesn't resolve so callers can
## just `if icon != null` without crashing on bad authoring.
func _get_item_icon(item_id: StringName) -> Texture2D:
	var data = Registry.get_item_or_fluid(item_id)
	return data.icon if data else null


func _get_block_icon(block_id: StringName) -> Texture2D:
	var data = Registry.get_block(block_id)
	return data.icon if data else null


func _get_unit_icon(unit_id: StringName) -> Texture2D:
	var data = Registry.get_unit(unit_id)
	return data.icon if data else null


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
	# `deposited` / `placed` baselines are global (item_id keyed) because
	# multiple parallel steps requesting the same item should each see
	# their own delta. We snapshot per-step into _step_deposited_baselines
	# keyed by (step_idx, item_id) string to avoid clobbering.
	for cond in conditions:
		match cond.get("type", ""):
			"wait":
				_step_wait_timers[idx] = float(cond.get("seconds", 3.0))
				if idx == _current_step:
					_step_wait_timer = _step_wait_timers[idx]
			"deposited":
				# Snapshot current inventory so we measure relative increase
				var item_id := StringName(cond.get("item_id", ""))
				_step_deposited_baselines[item_id] = main.resources.get(item_id, 0)
			"placed":
				# Snapshot current placed count so we measure relative increase
				var block_id := StringName(cond.get("block_id", ""))
				_step_placed_baselines[block_id] = _placed_counts.get(block_id, 0)

	# Spawn declarative markers attached to this step. IDs are derived
	# from the step index + marker index so `_exit_step` can find and
	# remove them without the author having to maintain matched pairs.
	_spawn_step_markers(idx)

	print("SectorScript: Entered step %d: %s" % [idx, step.get("name", "?")])


## Execute on_exit actions for a step.
func _exit_step(idx: int) -> void:
	var step: Dictionary = _script_steps[idx]
	var exit_actions: Array = step.get("on_exit", [])
	for action in exit_actions:
		_execute_action(action)
	# Tear down anything this step spawned via its `markers` array.
	_despawn_step_markers(idx)


# =========================
# DAG MACHINERY
# =========================

## Returns the list of dependency step indices for a step, with
## linear-script back-compat: a step missing `dependencies` is treated
## as depending on step (idx-1). Step 0 has no implicit dep.
func _step_dependencies(idx: int) -> Array:
	var step: Dictionary = _script_steps[idx]
	if step.has("dependencies"):
		var raw: Array = step["dependencies"]
		# Normalize to ints.
		var out: Array = []
		for d in raw:
			out.append(int(d))
		return out
	# Implicit linear chain.
	if idx == 0:
		return []
	return [idx - 1]


## Returns the flags-required gate for a step, normalized to Array[String].
func _step_flags_required(idx: int) -> Array:
	var step: Dictionary = _script_steps[idx]
	var raw: Array = step.get("flags_required", [])
	var out: Array = []
	for f in raw:
		out.append(String(f))
	return out


## Returns the flags this step sets on completion (in addition to any
## `set_flag` actions in its action list).
func _step_flags_set(idx: int) -> Array:
	var step: Dictionary = _script_steps[idx]
	var raw: Array = step.get("flags_set", [])
	var out: Array = []
	for f in raw:
		out.append(String(f))
	return out


## True when all deps are complete AND all flags_required are set.
func _step_eligible(idx: int) -> bool:
	if _completed_steps.has(idx):
		return false
	if _active_steps.has(idx):
		return false
	for dep in _step_dependencies(idx):
		if not _completed_steps.has(int(dep)):
			return false
	for fname in _step_flags_required(idx):
		if not bool(_flags.get(String(fname), false)):
			return false
	return true


## Scan every step; activate any newly-eligible ones. Called on
## `start_script` and after each step completion.
func _activate_eligible_steps() -> void:
	for i in range(_script_steps.size()):
		if _step_eligible(i):
			_active_steps[i] = true
			_enter_step(i)


## Mark a step complete, fire its exit actions, and set its `flags_set`.
func _complete_step(idx: int) -> void:
	_exit_step(idx)
	_active_steps.erase(idx)
	_completed_steps[idx] = true
	for fname in _step_flags_set(idx):
		_flags[String(fname)] = true
	print("SectorScript: Completed step %d" % idx)


## Re-derive the legacy `_current_step` pointer from the active set.
## Picks the highest-index active step so HUD code that reads it gets
## a stable "most recent" answer. Falls back to -1 when nothing is active.
func _recompute_current_step() -> void:
	var hi: int = -1
	for k in _active_steps.keys():
		if int(k) > hi:
			hi = int(k)
	_current_step = hi
	if hi >= 0:
		_step_wait_timer = float(_step_wait_timers.get(hi, 0.0))
	else:
		_step_wait_timer = 0.0


# =========================
# MARKERS
# =========================

## Spawn every marker declared on this step's `markers` array. Each
## marker becomes a draw_box / draw_text / etc with an auto-generated
## ID so cleanup at exit is automatic.
##
## Supported marker types:
##   {type: "box", from: "x,y", to: "x,y", color: "yellow"}
##   {type: "text", from: "x,y", to: "x,y", text: "..."}
##
## Markers are additive sugar over the existing draw_box/draw_text
## actions — old scripts using explicit draw/remove actions still work.
func _spawn_step_markers(idx: int) -> void:
	var step: Dictionary = _script_steps[idx]
	var markers: Array = step.get("markers", [])
	for i in range(markers.size()):
		var m: Dictionary = markers[i]
		var mtype: String = String(m.get("type", ""))
		var mid: String = _marker_id(idx, i)
		match mtype:
			"box":
				var from_pos: Vector2i = _parse_vec2i_arg(m.get("from", "0,0"))
				var to_pos: Vector2i = _parse_vec2i_arg(m.get("to", "0,0"))
				var color_name: String = String(m.get("color", "yellow"))
				var color: Color = NAMED_COLORS.get(color_name, Color.YELLOW)
				draw_box(mid, from_pos, to_pos, color)
			"text":
				var from_pos: Vector2i = _parse_vec2i_arg(m.get("from", "0,0"))
				var to_pos: Vector2i = _parse_vec2i_arg(m.get("to", "0,0"))
				var text: String = String(m.get("text", ""))
				draw_text_overlay(mid, from_pos, to_pos, text)


## Tear down every marker that `_spawn_step_markers(idx)` may have
## created. Safe to call even when the step has no markers — the
## helpers no-op on missing IDs.
func _despawn_step_markers(idx: int) -> void:
	var step: Dictionary = _script_steps[idx]
	var markers: Array = step.get("markers", [])
	for i in range(markers.size()):
		var m: Dictionary = markers[i]
		var mtype: String = String(m.get("type", ""))
		var mid: String = _marker_id(idx, i)
		match mtype:
			"box":
				remove_box(mid)
			"text":
				remove_text_overlay(mid)


## Stable per-step marker id. Tags the step + ordinal so two steps
## using identical marker definitions don't collide.
func _marker_id(step_idx: int, marker_idx: int) -> String:
	return "step_%d_marker_%d" % [step_idx, marker_idx]


## Returns (cached) the list of step indices that directly depend on
## `step_idx`. Cache is invalidated whenever `load_script_steps` swaps
## the steps array.
func _get_dependents(step_idx: int) -> Array:
	if _dependents_cache.has(step_idx):
		return _dependents_cache[step_idx]
	var out: Array = []
	for i in range(_script_steps.size()):
		if i == step_idx:
			continue
		for dep in _step_dependencies(i):
			if int(dep) == step_idx:
				out.append(i)
				break
	_dependents_cache[step_idx] = out
	return out


## True when every transitive dependent of `step_idx` is in the
## completed set. Used by the `descendants_done` condition so a
## marker-bearing step keeps its markers alive until the downstream
## chain finishes.
func _all_descendants_completed(step_idx: int) -> bool:
	var queue: Array = _get_dependents(step_idx).duplicate()
	var seen: Dictionary = {}
	while not queue.is_empty():
		var n: int = int(queue.pop_back())
		if seen.has(n):
			continue
		seen[n] = true
		if not _completed_steps.has(n):
			return false
		for d in _get_dependents(n):
			if not seen.has(int(d)):
				queue.append(int(d))
	return true


## Execute a single action dictionary.
func _execute_action(action: Dictionary) -> void:
	var action_type: String = action.get("type", "")
	match action_type:
		"set_flag":
			# Set a named flag. Steps gated on `flags_required` containing
			# this name will become eligible once their other deps clear.
			var fname: String = String(action.get("name", ""))
			if fname != "":
				_flags[fname] = bool(action.get("value", true))
		"clear_flag":
			var fname: String = String(action.get("name", ""))
			if fname != "":
				_flags.erase(fname)
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
