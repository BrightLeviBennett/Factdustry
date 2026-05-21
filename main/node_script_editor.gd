extends CanvasLayer
class_name NodeScriptEditor

# ============================================================
# NODE_SCRIPT_EDITOR.GD - Full-screen DAG editor
# ============================================================
# Mind-map / Unity-shader-graph style editor for sector scripts.
#
# Layout:
#   • Full-screen overlay; toggled via show_panel / hide_panel.
#   • LEFT: large GraphEdit canvas for node-and-wire authoring.
#   • RIGHT: palette sidebar grouped by category (condition /
#     action / marker / flow). Click a palette button to spawn
#     that node at the centre of the canvas.
#   • Each node = one DAG step. Edges = "do after" (target depends
#     on source). Click a node's "expand" arrow to show parameters.
#
# At save time the graph compiles to the same `script_steps` array
# the runtime already consumes, with explicit `dependencies` and,
# for marker nodes, a `descendants_done` condition so the marker
# stays alive until its downstream chain completes.
# ============================================================

# --- NODE TYPE METADATA ---
# Each entry: {category, label, params: {name: type}, kind}
#   category: "condition" | "action" | "marker" | "flow"
#   kind:     "condition" | "action" | "marker"
#   params:   ordered dict of param name → field type (see PARAM_TYPES)
const NODE_TYPES: Dictionary = {
	# --- Conditions (step completes when satisfied) ---
	"wait":                  {"category": "condition", "label": "Wait",                 "kind": "condition", "params": {"seconds": "float"}},
	"mined":                 {"category": "condition", "label": "Mined",                "kind": "condition", "params": {"item_id": "string", "amount": "int"}},
	"deposited":             {"category": "condition", "label": "Deposited in Core",    "kind": "condition", "params": {"item_id": "string", "amount": "int"}},
	"produced":              {"category": "condition", "label": "Produced",             "kind": "condition", "params": {"item_id": "string", "amount": "int"}},
	"placed":                {"category": "condition", "label": "Block Placed",         "kind": "condition", "params": {"block_id": "string", "amount": "int"}},
	"units_produced":        {"category": "condition", "label": "Units Produced",       "kind": "condition", "params": {"unit_id": "string", "amount": "int"}},
	"units_destroyed":       {"category": "condition", "label": "Ferox Units Destroyed","kind": "condition", "params": {"unit_id": "string", "amount": "int"}},
	"ferox_blocks_destroyed":{"category": "condition", "label": "Ferox Blocks Destroyed","kind": "condition", "params": {"block_id": "string", "amount": "int"}},
	"core_unit_mined":       {"category": "condition", "label": "Core Unit Mined",      "kind": "condition", "params": {"item_id": "string", "amount": "int"}},
	"block_has_item":        {"category": "condition", "label": "Block Has Item",       "kind": "condition", "params": {"pos": "vec2i", "item_id": "string", "amount": "int"}},
	"decoded_archive":       {"category": "condition", "label": "Archive Decoded",      "kind": "condition", "params": {"archive_id": "string", "amount": "int"}},
	"waves_defeated":        {"category": "condition", "label": "All Waves Defeated",   "kind": "condition", "params": {}},
	"flag":                  {"category": "flow",      "label": "Flag",                 "kind": "condition", "params": {"name": "string", "value": "bool"}},
	# --- Actions (instant on step entry) ---
	"pause":                 {"category": "action",    "label": "Pause World",          "kind": "action",    "params": {}},
	"unpause":               {"category": "action",    "label": "Unpause World",        "kind": "action",    "params": {}},
	"focus_camera":          {"category": "action",    "label": "Focus Camera",         "kind": "action",    "params": {"pos": "vec2i"}},
	"release_camera":        {"category": "action",    "label": "Release Camera",       "kind": "action",    "params": {}},
	"disable_block":         {"category": "action",    "label": "Disable Block",        "kind": "action",    "params": {"pos": "vec2i"}},
	"enable_block":          {"category": "action",    "label": "Enable Block",         "kind": "action",    "params": {"pos": "vec2i"}},
	"spawn_unit":            {"category": "action",    "label": "Spawn Unit",           "kind": "action",    "params": {"pos": "vec2i", "unit_id": "string", "faction": "faction", "count": "int"}},
	"hide_region":           {"category": "action",    "label": "Hide Region",          "kind": "action",    "params": {"from": "vec2i", "to": "vec2i", "include_floors": "bool"}},
	"reveal_region":         {"category": "action",    "label": "Reveal Region",        "kind": "action",    "params": {"from": "vec2i", "to": "vec2i"}},
	"start_waves":           {"category": "action",    "label": "Start Waves",          "kind": "action",    "params": {}},
	"stop_waves":            {"category": "action",    "label": "Stop Waves",           "kind": "action",    "params": {}},
	"capture_sector":        {"category": "action",    "label": "Capture Sector",       "kind": "action",    "params": {}},
	"set_flag":              {"category": "flow",      "label": "Set Flag",             "kind": "action",    "params": {"name": "string"}},
	"clear_flag":            {"category": "flow",      "label": "Clear Flag",           "kind": "action",    "params": {"name": "string"}},
	# --- Markers (visible until descendants complete) ---
	"draw_box":              {"category": "marker",    "label": "Draw Box",             "kind": "marker",    "params": {"from": "vec2i", "to": "vec2i", "color": "color"}},
	"draw_text":             {"category": "marker",    "label": "Draw Text",            "kind": "marker",    "params": {"from": "vec2i", "to": "vec2i", "text": "multiline"}},
}

static var CATEGORY_ORDER: PackedStringArray = PackedStringArray(["condition", "action", "marker", "flow"])
const CATEGORY_LABELS: Dictionary = {
	"condition": "Conditions",
	"action": "Actions",
	"marker": "Markers",
	"flow": "Flow (Flags)",
}
static var CATEGORY_COLORS: Dictionary = {
	"condition": Color(0.45, 0.65, 0.95),
	"action": Color(0.55, 0.85, 0.5),
	"marker": Color(0.95, 0.75, 0.35),
	"flow": Color(0.9, 0.5, 0.85),
}

static var NAMED_COLOR_LIST: PackedStringArray = PackedStringArray([
	"yellow", "red", "green", "blue", "cyan", "orange", "white", "magenta", "pink", "gray",
])


# --- STATE ---
var main: Node2D
var _root: Control
var _graph: GraphEdit
var _palette_vbox: VBoxContainer
var _toolbar: HBoxContainer
## Per-node: { "type": String, "params": Dictionary, "section": String }.
## Keyed by GraphNode.name (auto-generated unique string).
var _nodes_data: Dictionary = {}
var _next_node_id: int = 0
var _suspend_signals: bool = false
## Hints aren't authored in the graph (yet) but the runtime still uses
## them, so we hold the array intact and pass it through save/load.
var _hints_passthrough: Array = []
## section name → GraphFrame node name. Built lazily as nodes claim a
## section.
var _frames: Dictionary = {}
## section name → Color. Generated randomly the first time a section
## is created, then persisted on every step that belongs to it (via
## the `_section_color` field) so reloads keep the same tint and
## renaming a section doesn't reshuffle colours.
var _section_colors: Dictionary = {}

# --- CLIPBOARD / UNDO ---
## Last clipboard payload from copy/cut. Format mirrors `_serialize`
## entries but with relative positions so paste can drop the cluster
## near the mouse.
var _clipboard: Dictionary = {}
## Stack of full graph snapshots for undo. Each entry is the same
## shape as `_serialize()` returns plus the section-color table.
var _undo_stack: Array = []
var _redo_stack: Array = []
const _UNDO_DEPTH: int = 64
var _undo_debounce_timer: Timer = null

# --- CONTEXT MENU ---
var _ctx_menu: PopupMenu = null
const _CTX_COPY: int = 1
const _CTX_CUT: int = 2
const _CTX_SET_SECTION: int = 3
var _section_picker_root: Control = null
var _section_picker_line: LineEdit = null
var _section_picker_list: ItemList = null


# --- HINT PASSTHROUGH (called by save_manager) ---

func get_hints_data() -> Array:
	return _hints_passthrough.duplicate(true)


func set_hints_data(data: Array) -> void:
	_hints_passthrough = data.duplicate(true)


func _ready() -> void:
	await get_tree().process_frame
	main = get_node("/root/Main")
	layer = 80   # above the regular HUD, below modal dialogs
	_create_ui()
	# Debounce timer collapses bursts of edits (param typing, slider
	# spam) into a single undo entry. Starts when an edit fires; on
	# timeout the snapshot is committed.
	_undo_debounce_timer = Timer.new()
	_undo_debounce_timer.one_shot = true
	_undo_debounce_timer.wait_time = 0.5
	_undo_debounce_timer.timeout.connect(_commit_pending_snapshot)
	add_child(_undo_debounce_timer)
	hide_panel()
	# Seed the undo stack with the empty baseline so the very first
	# Cmd+Z after the first edit lands somewhere safe.
	_undo_stack.append(_take_snapshot())


# =========================
# PUBLIC API
# =========================

func show_panel() -> void:
	if _root:
		_root.visible = true


func hide_panel() -> void:
	if _root:
		_root.visible = false


## Returns the current graph as the steps array consumed by
## SectorScript. Each node becomes a step with explicit dependencies.
func get_script_data() -> Array:
	return _serialize()


## Loads a steps array into the graph. Layout is reconstructed if the
## steps carry an `_editor_pos` field; otherwise nodes are auto-laid
## out in topological order.
func set_script_data(steps: Array) -> void:
	_deserialize(steps)
	# Seed the undo stack with the loaded state so the first undo has
	# somewhere safe to land (otherwise an early Cmd+Z would silently
	# do nothing).
	_undo_stack.clear()
	_redo_stack.clear()
	_undo_stack.append(_take_snapshot())


# =========================
# UI CONSTRUCTION
# =========================

func _create_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	# Full-screen dim background so the editor reads as "modal mode".
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.08, 0.93)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(bg)

	# Toolbar across the top — title, save, close.
	_toolbar = HBoxContainer.new()
	_toolbar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE, Control.PRESET_MODE_KEEP_SIZE, 8)
	_toolbar.offset_top = 8
	_toolbar.offset_left = 12
	_toolbar.offset_right = -12
	_toolbar.custom_minimum_size.y = 32
	_root.add_child(_toolbar)

	var title := Label.new()
	title.text = "Sector Script — Node Graph"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.95, 0.95, 0.97))
	_toolbar.add_child(title)

	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toolbar.add_child(sp)

	var clear_btn := Button.new()
	clear_btn.text = "Clear Graph"
	clear_btn.pressed.connect(_on_clear_pressed)
	_toolbar.add_child(clear_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(hide_panel)
	_toolbar.add_child(close_btn)

	# Main split: graph on the left, palette on the right.
	var split := HSplitContainer.new()
	split.split_offset = -260
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	split.offset_top = 48
	split.offset_left = 8
	split.offset_right = -8
	split.offset_bottom = -8
	_root.add_child(split)

	# --- Graph canvas ---
	_graph = GraphEdit.new()
	_graph.minimap_enabled = true
	_graph.right_disconnects = true
	_graph.show_grid = true
	_graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph.connection_request.connect(_on_connection_request)
	_graph.disconnection_request.connect(_on_disconnection_request)
	_graph.delete_nodes_request.connect(_on_delete_nodes_request)
	_graph.gui_input.connect(_on_graph_gui_input)
	split.add_child(_graph)

	# --- Right palette ---
	var palette_scroll := ScrollContainer.new()
	palette_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	palette_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	palette_scroll.custom_minimum_size.x = 240
	split.add_child(palette_scroll)

	_palette_vbox = VBoxContainer.new()
	_palette_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	palette_scroll.add_child(_palette_vbox)

	_populate_palette()


func _populate_palette() -> void:
	# Header.
	var hdr := Label.new()
	hdr.text = "Palette"
	hdr.add_theme_font_size_override("font_size", 16)
	hdr.add_theme_color_override("font_color", Color(0.95, 0.95, 0.97))
	_palette_vbox.add_child(hdr)

	# Group by category, in CATEGORY_ORDER.
	var grouped: Dictionary = {}
	for type_id in NODE_TYPES:
		var meta: Dictionary = NODE_TYPES[type_id]
		var cat: String = String(meta["category"])
		if not grouped.has(cat):
			grouped[cat] = []
		grouped[cat].append(type_id)

	for cat in CATEGORY_ORDER:
		if not grouped.has(cat):
			continue
		var sep := HSeparator.new()
		_palette_vbox.add_child(sep)
		var cat_label := Label.new()
		cat_label.text = String(CATEGORY_LABELS.get(cat, cat))
		cat_label.add_theme_font_size_override("font_size", 13)
		cat_label.add_theme_color_override("font_color", CATEGORY_COLORS.get(cat, Color.WHITE))
		_palette_vbox.add_child(cat_label)
		var types: Array = grouped[cat]
		types.sort()
		for type_id in types:
			var meta: Dictionary = NODE_TYPES[type_id]
			var btn := Button.new()
			btn.text = "+ %s" % String(meta["label"])
			btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.pressed.connect(_on_palette_pressed.bind(String(type_id)))
			_palette_vbox.add_child(btn)


# =========================
# NODE CREATION
# =========================

func _on_palette_pressed(type_id: String) -> void:
	# Spawn at the centre of the visible graph area.
	var spawn_pos: Vector2 = _graph.scroll_offset + _graph.size * 0.5 - Vector2(120, 80)
	_add_node(type_id, spawn_pos)
	_request_snapshot()


func _add_node(type_id: String, pos: Vector2, init_params: Dictionary = {}, section: String = "") -> GraphNode:
	var meta: Dictionary = NODE_TYPES.get(type_id, {})
	if meta.is_empty():
		push_warning("NodeScriptEditor: unknown node type %s" % type_id)
		return null
	var name_id: String = "node_%d" % _next_node_id
	_next_node_id += 1

	var gn := GraphNode.new()
	gn.name = name_id
	# Plain title: just the type label. Section grouping is now shown
	# via the surrounding GraphFrame (colour + title), not by prefixing
	# the node title.
	gn.title = String(meta["label"])
	gn.position_offset = pos
	gn.resizable = false
	_graph.add_child(gn)

	# Title color tint to match the category.
	var cat_color: Color = CATEGORY_COLORS.get(String(meta["category"]), Color.WHITE)
	gn.add_theme_color_override("title_color", cat_color)

	# Compact header row — has the input/output slot anchors. Every
	# node gets one input (left) and one output (right) on row 0.
	var header := Control.new()
	header.custom_minimum_size.y = 8
	gn.add_child(header)
	gn.set_slot(0, true, 0, cat_color, true, 0, cat_color)

	# Drop-down arrow row. Flat button serves as the expand/collapse
	# toggle — its label shows "▶" when collapsed and "▼" when open.
	# Replaces the old "Params" CheckButton; nothing in the node body
	# is visible until the arrow is clicked.
	var arrow_btn := Button.new()
	arrow_btn.flat = true
	arrow_btn.text = "▶"
	arrow_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	arrow_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gn.add_child(arrow_btn)

	# Body container — everything below the arrow lives here and is
	# shown/hidden together.
	var body := VBoxContainer.new()
	body.visible = false
	gn.add_child(body)

	# Section editor with 50-char cap.
	var section_row := HBoxContainer.new()
	body.add_child(section_row)
	var sec_lbl := Label.new()
	sec_lbl.text = "Section:"
	sec_lbl.add_theme_font_size_override("font_size", 10)
	section_row.add_child(sec_lbl)
	var sec_le := LineEdit.new()
	sec_le.placeholder_text = "(none)"
	sec_le.text = section
	sec_le.max_length = _SECTION_NAME_MAX
	sec_le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section_row.add_child(sec_le)

	# Parameter editor lives in the same collapsible body.
	var params_box := VBoxContainer.new()
	body.add_child(params_box)

	var data: Dictionary = {
		"type": type_id,
		"params": init_params.duplicate(true),
		"params_box": params_box,
		"section": section,
		"label": String(meta["label"]),
		"arrow_btn": arrow_btn,
		"body": body,
		"section_line_edit": sec_le,
	}
	data["params"].erase("_expanded")
	_nodes_data[name_id] = data

	# Connect section editor (after `data` is stored so the handler can
	# read the previous section to detach from the right frame).
	sec_le.text_changed.connect(func(new_section: String):
		_on_section_changed(name_id, new_section)
		_request_snapshot()
	)

	arrow_btn.pressed.connect(func():
		var open: bool = not body.visible
		body.visible = open
		arrow_btn.text = "▼" if open else "▶"
		if open and params_box.get_child_count() == 0:
			_build_params_panel(name_id)
	)

	# Attach to a frame if a section was given. The frame is created on
	# demand and shared by every node with the same section name.
	if section != "":
		_attach_to_section(gn, section)

	return gn


const _SECTION_NAME_MAX: int = 50


# =========================
# SECTIONS / GRAPH FRAMES
# =========================

## Returns the colour assigned to `section`. Allocates a new random
## colour the FIRST time the section is referenced, then never
## changes — survives renames (because the rename moves the node
## between sections, but each section's own colour is locked in).
## Persistence happens via `_section_color` stamped on each step
## that belongs to the section.
func _ensure_section_color(section: String) -> Color:
	if section == "":
		return Color(0.3, 0.3, 0.3, 0.18)
	if _section_colors.has(section):
		return _section_colors[section]
	# Random hue, toned saturation/value so the frame doesn't drown
	# out the nodes inside it.
	var hue: float = randf()
	var c := Color.from_hsv(hue, 0.55, 0.85, 0.22)
	_section_colors[section] = c
	return c


## Returns the frame node-name for `section`, creating one if needed.
## Empty section → empty StringName (caller should skip attaching).
func _ensure_frame(section: String) -> StringName:
	if section == "":
		return &""
	if _frames.has(section):
		var existing: String = String(_frames[section])
		if _graph.has_node(existing):
			return StringName(existing)
		_frames.erase(section)
	var safe: String = "frame_" + section.replace(" ", "_").replace("/", "_").replace(".", "_")
	# Disambiguate against another section sanitizing to the same name.
	var nm: String = safe
	var n: int = 1
	while _graph.has_node(nm):
		nm = "%s_%d" % [safe, n]
		n += 1
	var f := GraphFrame.new()
	f.name = nm
	f.title = section
	f.tint_color = _ensure_section_color(section)
	f.tint_color_enabled = true
	f.autoshrink_enabled = true
	_graph.add_child(f)
	_frames[section] = nm
	return StringName(nm)


func _attach_to_section(gn: GraphNode, section: String) -> void:
	var fname: StringName = _ensure_frame(section)
	if fname == &"":
		return
	_graph.attach_graph_element_to_frame(gn.name, fname)


func _detach_from_section(gn: GraphNode) -> void:
	# GraphEdit drops the element from whatever frame currently holds it.
	# Safe to call even when the element is already free-floating.
	_graph.detach_graph_element_from_frame(gn.name)


## Handler for the in-node "Section" LineEdit. Re-attaches the node
## to the right frame and prunes any frame that just lost its last
## member. Title is NOT changed — section grouping is shown via the
## surrounding GraphFrame only.
func _on_section_changed(node_id: String, new_section: String) -> void:
	if not _nodes_data.has(node_id):
		return
	# Enforce the 50-char cap defensively (LineEdit.max_length already
	# blocks user input but external mutations can still overshoot).
	if new_section.length() > _SECTION_NAME_MAX:
		new_section = new_section.substr(0, _SECTION_NAME_MAX)
	var data: Dictionary = _nodes_data[node_id]
	var old_section: String = String(data.get("section", ""))
	if old_section == new_section:
		return
	data["section"] = new_section
	var gn: GraphNode = _graph.get_node_or_null(node_id)
	if gn == null:
		return
	_detach_from_section(gn)
	if new_section != "":
		_attach_to_section(gn, new_section)
	_cleanup_unused_frames()


## Drop frames that no node references anymore. Called after section
## edits and on node deletions so abandoned frames don't pile up.
func _cleanup_unused_frames() -> void:
	var in_use: Dictionary = {}
	for nid in _nodes_data:
		var s: String = String(_nodes_data[nid].get("section", ""))
		if s != "":
			in_use[s] = true
	var dead: Array = []
	for section in _frames.keys():
		if not in_use.has(section):
			dead.append(section)
	for section in dead:
		var fname: String = String(_frames[section])
		var node: Node = _graph.get_node_or_null(fname)
		if node:
			node.queue_free()
		_frames.erase(section)


# =========================
# PARAMETER EDITORS
# =========================

func _build_params_panel(node_id: String) -> void:
	var data: Dictionary = _nodes_data[node_id]
	var box: VBoxContainer = data["params_box"]
	# Clear any previous children (e.g. on rebuild after deserialize).
	for c in box.get_children():
		c.queue_free()
	var type_id: String = data["type"]
	var meta: Dictionary = NODE_TYPES.get(type_id, {})
	var params: Dictionary = meta.get("params", {})
	for key in params:
		var ptype: String = String(params[key])
		_add_param_field(box, data["params"], key, ptype)


func _add_param_field(parent: VBoxContainer, params: Dictionary, key: String, ptype: String) -> void:
	var row := VBoxContainer.new()
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = key
	row.add_child(lbl)
	match ptype:
		"string":
			var le := LineEdit.new()
			le.text = String(params.get(key, ""))
			le.text_changed.connect(func(t: String):
				params[key] = t
				_request_snapshot()
			)
			row.add_child(le)
		"multiline":
			var te := TextEdit.new()
			te.text = String(params.get(key, ""))
			te.custom_minimum_size.y = 80
			te.text_changed.connect(func():
				params[key] = te.text
				_request_snapshot()
			)
			row.add_child(te)
		"int":
			var sb := SpinBox.new()
			sb.min_value = -999999
			sb.max_value = 999999
			sb.step = 1
			sb.value = float(params.get(key, 1))
			sb.value_changed.connect(func(v: float):
				params[key] = int(v)
				_request_snapshot()
			)
			row.add_child(sb)
		"float":
			var sbf := SpinBox.new()
			sbf.min_value = -999999.0
			sbf.max_value = 999999.0
			sbf.step = 0.1
			sbf.value = float(params.get(key, 1.0))
			sbf.value_changed.connect(func(v: float):
				params[key] = v
				_request_snapshot()
			)
			row.add_child(sbf)
		"bool":
			var cb := CheckBox.new()
			cb.button_pressed = bool(params.get(key, false))
			cb.toggled.connect(func(on: bool):
				params[key] = on
				_request_snapshot()
			)
			row.add_child(cb)
		"vec2i":
			var hb := HBoxContainer.new()
			row.add_child(hb)
			var raw: String = String(params.get(key, "0,0"))
			var parts: PackedStringArray = raw.split(",")
			var xv: int = int(parts[0]) if parts.size() >= 1 else 0
			var yv: int = int(parts[1]) if parts.size() >= 2 else 0
			var sx := SpinBox.new()
			sx.min_value = -9999
			sx.max_value = 9999
			sx.value = xv
			var sy := SpinBox.new()
			sy.min_value = -9999
			sy.max_value = 9999
			sy.value = yv
			var update_pos = func():
				params[key] = "%d,%d" % [int(sx.value), int(sy.value)]
				_request_snapshot()
			sx.value_changed.connect(func(_v): update_pos.call())
			sy.value_changed.connect(func(_v): update_pos.call())
			hb.add_child(sx)
			hb.add_child(sy)
		"color":
			var opt := OptionButton.new()
			var cur: String = String(params.get(key, "yellow"))
			var sel: int = 0
			for i in range(NAMED_COLOR_LIST.size()):
				opt.add_item(NAMED_COLOR_LIST[i], i)
				if NAMED_COLOR_LIST[i] == cur:
					sel = i
			opt.select(sel)
			opt.item_selected.connect(func(idx: int):
				params[key] = NAMED_COLOR_LIST[idx]
				_request_snapshot()
			)
			row.add_child(opt)
		"faction":
			var opt := OptionButton.new()
			var factions: PackedStringArray = PackedStringArray(["ferox", "lumina"])
			var cur: String = String(params.get(key, "ferox"))
			var sel: int = 0
			for i in range(factions.size()):
				opt.add_item(factions[i], i)
				if factions[i] == cur:
					sel = i
			opt.select(sel)
			opt.item_selected.connect(func(idx: int):
				params[key] = factions[idx]
				_request_snapshot()
			)
			row.add_child(opt)
		_:
			var le2 := LineEdit.new()
			le2.text = str(params.get(key, ""))
			le2.text_changed.connect(func(t: String):
				params[key] = t
				_request_snapshot()
			)
			row.add_child(le2)


# =========================
# CONNECTIONS
# =========================

func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	if _suspend_signals:
		return
	if String(from_node) == String(to_node):
		return
	if _creates_cycle(String(from_node), String(to_node)):
		print("[node_script_editor] refused connection — would create cycle.")
		return
	_graph.connect_node(from_node, from_port, to_node, to_port)
	_request_snapshot()


func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	if _suspend_signals:
		return
	_graph.disconnect_node(from_node, from_port, to_node, to_port)
	_request_snapshot()


func _on_delete_nodes_request(node_names: Array) -> void:
	for n in node_names:
		var key: String = String(n)
		# Strip its connections first.
		for c in _graph.get_connection_list():
			if String(c["from_node"]) == key or String(c["to_node"]) == key:
				_graph.disconnect_node(c["from_node"], int(c["from_port"]), c["to_node"], int(c["to_port"]))
		var node: Node = _graph.get_node_or_null(key)
		if node:
			node.queue_free()
		_nodes_data.erase(key)
	_cleanup_unused_frames()
	_request_snapshot()


func _creates_cycle(from_id: String, to_id: String) -> bool:
	# BFS from `to_id` along existing edges; if we hit from_id, adding
	# from_id → to_id would close a loop.
	var seen: Dictionary = {}
	var queue: Array = [to_id]
	while not queue.is_empty():
		var cur: String = String(queue.pop_back())
		if seen.has(cur):
			continue
		seen[cur] = true
		for c in _graph.get_connection_list():
			if String(c["from_node"]) == cur:
				var nxt: String = String(c["to_node"])
				if nxt == from_id:
					return true
				queue.append(nxt)
	return false


func _on_clear_pressed() -> void:
	# Tear down every node + its connections, then reset id counter.
	for c in _graph.get_connection_list():
		_graph.disconnect_node(c["from_node"], int(c["from_port"]), c["to_node"], int(c["to_port"]))
	for key in _nodes_data.keys():
		var n: Node = _graph.get_node_or_null(key)
		if n:
			n.queue_free()
	_nodes_data.clear()
	_next_node_id = 0
	# Drop any frames left behind.
	for section in _frames.keys():
		var fname: String = String(_frames[section])
		var node: Node = _graph.get_node_or_null(fname)
		if node:
			node.queue_free()
	_frames.clear()
	# A full clear resets section colours too — colours travel with
	# the saved data, so a fresh load starts cold.
	_section_colors.clear()
	_undo_stack.clear()
	_redo_stack.clear()


# =========================
# CONTEXT MENU / CLIPBOARD / UNDO
# =========================

## GraphEdit catches its own input, so we hook gui_input on the inner
## canvas to detect a right-click while ≥1 node is selected. On right
## click we pop up the context menu at the global mouse position.
func _on_graph_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		var sel: Array = _selected_node_ids()
		if sel.is_empty():
			return
		_show_context_menu(sel, event.global_position)
		_graph.accept_event()


func _selected_node_ids() -> Array:
	var out: Array = []
	for nid in _nodes_data.keys():
		var gn: GraphNode = _graph.get_node_or_null(nid)
		if gn and gn.selected:
			out.append(String(nid))
	return out


func _ensure_context_menu() -> void:
	if _ctx_menu != null:
		return
	_ctx_menu = PopupMenu.new()
	_ctx_menu.add_item("Copy", _CTX_COPY)
	_ctx_menu.add_item("Cut", _CTX_CUT)
	_ctx_menu.add_separator()
	_ctx_menu.add_item("Set Section…", _CTX_SET_SECTION)
	_root.add_child(_ctx_menu)
	_ctx_menu.id_pressed.connect(_on_ctx_menu_id_pressed)


var _ctx_target_ids: Array = []

func _show_context_menu(sel: Array, gpos: Vector2) -> void:
	_ensure_context_menu()
	_ctx_target_ids = sel.duplicate()
	_ctx_menu.position = Vector2i(int(gpos.x), int(gpos.y))
	_ctx_menu.popup()


func _on_ctx_menu_id_pressed(id: int) -> void:
	match id:
		_CTX_COPY:
			_clipboard_copy(_ctx_target_ids)
		_CTX_CUT:
			_clipboard_copy(_ctx_target_ids)
			_on_delete_nodes_request(_ctx_target_ids.duplicate())
			_request_snapshot()
		_CTX_SET_SECTION:
			_open_section_picker(_ctx_target_ids)


# --- Clipboard ---

## Snapshots the selection (type, params, section, connections among
## them, relative positions) into `_clipboard`. Paste reads from here.
func _clipboard_copy(ids: Array) -> void:
	if ids.is_empty():
		return
	# Anchor positions to the topmost-leftmost selected node so paste
	# can drop the cluster at the cursor without dragging it across
	# the canvas.
	var anchor := Vector2(INF, INF)
	for nid in ids:
		var gn: GraphNode = _graph.get_node_or_null(nid)
		if gn:
			anchor.x = min(anchor.x, gn.position_offset.x)
			anchor.y = min(anchor.y, gn.position_offset.y)
	if anchor.x == INF:
		return
	var entries: Array = []
	var id_set: Dictionary = {}
	for nid in ids:
		id_set[nid] = true
		var data: Dictionary = _nodes_data.get(nid, {})
		if data.is_empty():
			continue
		var gn: GraphNode = _graph.get_node_or_null(nid)
		var rel: Vector2 = Vector2.ZERO
		if gn:
			rel = gn.position_offset - anchor
		entries.append({
			"local_id": nid,
			"type": String(data["type"]),
			"params": (data["params"] as Dictionary).duplicate(true),
			"section": String(data.get("section", "")),
			"rel_pos": rel,
		})
	var conns: Array = []
	for c in _graph.get_connection_list():
		var f: String = String(c["from_node"])
		var t: String = String(c["to_node"])
		if id_set.has(f) and id_set.has(t):
			conns.append({"from": f, "to": t})
	_clipboard = {"entries": entries, "conns": conns}


## Paste from `_clipboard` near the current mouse position. New nodes
## get fresh ids; internal connections are reproduced via the local
## id → new id remap.
func _clipboard_paste() -> void:
	if _clipboard.is_empty() or _clipboard.get("entries", []).is_empty():
		return
	var mouse: Vector2 = _graph.get_local_mouse_position() + _graph.scroll_offset
	var id_remap: Dictionary = {}
	for entry in _clipboard["entries"]:
		var rel: Vector2 = entry.get("rel_pos", Vector2.ZERO)
		var pos: Vector2 = mouse + rel
		var gn := _add_node(String(entry["type"]), pos,
			(entry["params"] as Dictionary).duplicate(true),
			String(entry.get("section", "")))
		id_remap[String(entry["local_id"])] = gn.name
	for c in _clipboard.get("conns", []):
		var f: String = id_remap.get(String(c["from"]), "")
		var t: String = id_remap.get(String(c["to"]), "")
		if f == "" or t == "":
			continue
		_graph.connect_node(f, 0, t, 0)
	_request_snapshot()


# --- Section picker dialog ---

func _open_section_picker(ids: Array) -> void:
	if ids.is_empty():
		return
	# Build a fresh dialog every time so the list reflects current
	# section names and previous entries don't leak in.
	if _section_picker_root != null:
		_section_picker_root.queue_free()
	_section_picker_root = ColorRect.new()
	_section_picker_root.color = Color(0, 0, 0, 0.55)
	_section_picker_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_section_picker_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_section_picker_root)

	var dialog := PanelContainer.new()
	dialog.set_anchors_preset(Control.PRESET_CENTER)
	dialog.custom_minimum_size = Vector2(360, 360)
	dialog.position = (_section_picker_root.size - dialog.custom_minimum_size) * 0.5
	_section_picker_root.add_child(dialog)
	var vb := VBoxContainer.new()
	dialog.add_child(vb)
	var hdr := Label.new()
	hdr.text = "Set Section"
	hdr.add_theme_font_size_override("font_size", 16)
	vb.add_child(hdr)

	var info := Label.new()
	info.text = "Type a section name or pick an existing one. Empty = no section."
	info.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(info)

	_section_picker_line = LineEdit.new()
	_section_picker_line.placeholder_text = "Section name"
	_section_picker_line.max_length = _SECTION_NAME_MAX
	vb.add_child(_section_picker_line)

	_section_picker_list = ItemList.new()
	_section_picker_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_section_picker_list.custom_minimum_size.y = 180
	# Existing sections, alphabetised so the picker is predictable.
	var existing: Array = _section_colors.keys()
	existing.sort()
	for sect in existing:
		_section_picker_list.add_item(sect)
	_section_picker_list.item_activated.connect(func(idx: int):
		_section_picker_line.text = _section_picker_list.get_item_text(idx)
	)
	_section_picker_list.item_selected.connect(func(idx: int):
		_section_picker_line.text = _section_picker_list.get_item_text(idx)
	)
	vb.add_child(_section_picker_list)

	var row := HBoxContainer.new()
	vb.add_child(row)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func():
		_section_picker_root.queue_free()
		_section_picker_root = null
	)
	row.add_child(cancel)
	var apply := Button.new()
	apply.text = "Apply"
	apply.pressed.connect(func():
		var sect: String = _section_picker_line.text.strip_edges()
		if sect.length() > _SECTION_NAME_MAX:
			sect = sect.substr(0, _SECTION_NAME_MAX)
		for nid in ids:
			if not _nodes_data.has(nid):
				continue
			_nodes_data[nid]["section"] = sect
			# Reflect change in the per-node LineEdit so the user
			# sees a consistent state.
			var le: LineEdit = _nodes_data[nid].get("section_line_edit")
			if le:
				le.text = sect
			var gn: GraphNode = _graph.get_node_or_null(nid)
			if gn:
				_detach_from_section(gn)
				if sect != "":
					_attach_to_section(gn, sect)
		_cleanup_unused_frames()
		_request_snapshot()
		_section_picker_root.queue_free()
		_section_picker_root = null
	)
	row.add_child(apply)


# --- Undo / Redo ---

## Schedule a snapshot at the next idle frame. Debounced through the
## 0.5 s timer so a burst of edits collapses into one undo entry.
func _request_snapshot() -> void:
	if _undo_debounce_timer:
		_undo_debounce_timer.start()


func _commit_pending_snapshot() -> void:
	var snap: Dictionary = _take_snapshot()
	if not _undo_stack.is_empty():
		var last: Dictionary = _undo_stack[_undo_stack.size() - 1]
		if _snapshots_equal(last, snap):
			return
	_undo_stack.append(snap)
	while _undo_stack.size() > _UNDO_DEPTH:
		_undo_stack.pop_front()
	_redo_stack.clear()


func _take_snapshot() -> Dictionary:
	var colors_dict: Dictionary = {}
	for k in _section_colors:
		colors_dict[k] = (_section_colors[k] as Color).to_html(true)
	return {
		"steps": _serialize(),
		"colors": colors_dict,
	}


func _snapshots_equal(a: Dictionary, b: Dictionary) -> bool:
	return JSON.stringify(a) == JSON.stringify(b)


func _apply_snapshot(snap: Dictionary) -> void:
	_section_colors.clear()
	for k in snap.get("colors", {}):
		_section_colors[String(k)] = Color(String(snap["colors"][k]))
	_deserialize(snap.get("steps", []))


func _undo() -> void:
	if _undo_stack.size() < 2:
		return
	# Top of undo stack is the CURRENT state. Pop it, push to redo,
	# then apply the new top (the previous state).
	var cur: Dictionary = _undo_stack.pop_back()
	_redo_stack.append(cur)
	var target: Dictionary = _undo_stack[_undo_stack.size() - 1]
	_apply_snapshot(target)


func _redo() -> void:
	if _redo_stack.is_empty():
		return
	var snap: Dictionary = _redo_stack.pop_back()
	_undo_stack.append(snap)
	_apply_snapshot(snap)


# --- Keyboard shortcuts ---

## Cmd/Ctrl + C / X / V / Z and Shift+Z. We hook _unhandled_input on
## the editor's root Control so shortcuts only fire while the editor
## is visible AND nothing else has consumed the event.
func _unhandled_input(event: InputEvent) -> void:
	if _root == null or not _root.visible:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k: InputEventKey = event
	# `command_or_control` resolves Cmd on macOS, Ctrl elsewhere.
	if not (k.is_command_or_control_pressed()):
		return
	match k.keycode:
		KEY_C:
			_clipboard_copy(_selected_node_ids())
			get_viewport().set_input_as_handled()
		KEY_X:
			var sel: Array = _selected_node_ids()
			if not sel.is_empty():
				_clipboard_copy(sel)
				_on_delete_nodes_request(sel.duplicate())
				_request_snapshot()
			get_viewport().set_input_as_handled()
		KEY_V:
			_clipboard_paste()
			get_viewport().set_input_as_handled()
		KEY_Z:
			if k.shift_pressed:
				_redo()
			else:
				_undo()
			get_viewport().set_input_as_handled()


# =========================
# SERIALIZE / DESERIALIZE
# =========================

## Walks the graph and emits a steps array compatible with the
## SectorScript runtime. The order of steps is a stable topological
## sort so step 0 is always a root and dependencies always point
## backward — which matches both the runtime's expectations and the
## human-readable JSON.
func _serialize() -> Array:
	# Collect node ids in topological order.
	var node_ids: Array = _nodes_data.keys()
	var topo: Array = _topo_sort(node_ids)
	# Map node-id → step index for dependency wiring.
	var idx_of: Dictionary = {}
	for i in range(topo.size()):
		idx_of[topo[i]] = i

	var steps: Array = []
	for i in range(topo.size()):
		var nid: String = topo[i]
		var data: Dictionary = _nodes_data[nid]
		var type_id: String = data["type"]
		var meta: Dictionary = NODE_TYPES.get(type_id, {})
		var params: Dictionary = data["params"]
		var deps: Array = []
		for c in _graph.get_connection_list():
			if String(c["to_node"]) == nid:
				var src_idx = idx_of.get(String(c["from_node"]), null)
				if src_idx != null:
					deps.append(int(src_idx))
		# Record editor position so reopening the file restores layout.
		var pos: Vector2 = Vector2.ZERO
		var node: GraphNode = _graph.get_node_or_null(nid)
		if node:
			pos = node.position_offset
		var section: String = String(data.get("section", ""))
		var label: String = String(meta.get("label", type_id))
		var step_name: String = label if section == "" else "%s (%s)" % [section, label]
		var step: Dictionary = {
			"name": step_name,
			"dependencies": deps,
			"_editor_pos": "%d,%d" % [int(pos.x), int(pos.y)],
		}
		# Persist the section's colour on every member step so reloads
		# keep the same tint instead of rolling a fresh random hue.
		if section != "" and _section_colors.has(section):
			step["_section_color"] = (_section_colors[section] as Color).to_html(true)
		match String(meta.get("kind", "")):
			"condition":
				step["conditions"] = [_condition_dict_for(type_id, params)]
				step["actions"] = []
			"action":
				step["conditions"] = [{"type": "always"}]
				step["actions"] = [_action_dict_for(type_id, params)]
			"marker":
				step["conditions"] = [{"type": "descendants_done"}]
				step["actions"] = []
				step["markers"] = [_marker_dict_for(type_id, params)]
		steps.append(step)
	return steps


func _condition_dict_for(type_id: String, params: Dictionary) -> Dictionary:
	var out: Dictionary = {"type": type_id}
	for k in params:
		out[k] = params[k]
	return out


func _action_dict_for(type_id: String, params: Dictionary) -> Dictionary:
	var out: Dictionary = {"type": type_id}
	for k in params:
		out[k] = params[k]
	return out


func _marker_dict_for(type_id: String, params: Dictionary) -> Dictionary:
	# Marker types in the runtime are "box" / "text" rather than the
	# node-type names "draw_box" / "draw_text".
	var mtype: String = "box" if type_id == "draw_box" else "text"
	var out: Dictionary = {"type": mtype}
	for k in params:
		out[k] = params[k]
	return out


## Topological sort by Kahn's algorithm. Nodes with no incoming edge
## come first. Cycles shouldn't exist (we refuse cyclic connections),
## but any leftover nodes are appended in their iteration order.
func _topo_sort(node_ids: Array) -> Array:
	var in_count: Dictionary = {}
	for nid in node_ids:
		in_count[nid] = 0
	for c in _graph.get_connection_list():
		var t: String = String(c["to_node"])
		if in_count.has(t):
			in_count[t] = int(in_count[t]) + 1
	var ready: Array = []
	for nid in node_ids:
		if int(in_count[nid]) == 0:
			ready.append(nid)
	var out: Array = []
	while not ready.is_empty():
		var cur: String = String(ready.pop_front())
		out.append(cur)
		for c in _graph.get_connection_list():
			if String(c["from_node"]) == cur:
				var t: String = String(c["to_node"])
				in_count[t] = int(in_count.get(t, 1)) - 1
				if int(in_count[t]) == 0:
					ready.append(t)
	# Any nodes left (cycle remnants) — append in iteration order.
	for nid in node_ids:
		if not out.has(nid):
			out.append(nid)
	return out


func _deserialize(steps: Array) -> void:
	_on_clear_pressed()
	_suspend_signals = true
	# Preload persisted section colours BEFORE spawning nodes, so
	# `_ensure_frame` picks up the saved hue instead of rolling a
	# fresh random one. We walk every step and adopt the first colour
	# seen per section; later collisions are ignored.
	for s in steps:
		var step: Dictionary = s
		var sect: String = _parse_section_from_name(String(step.get("name", "")))
		if sect == "" or _section_colors.has(sect):
			continue
		var raw: String = String(step.get("_section_color", ""))
		if raw == "":
			continue
		_section_colors[sect] = Color(raw)
	# First pass: spawn a node for each step.
	var step_to_node: Dictionary = {}
	for i in range(steps.size()):
		var step: Dictionary = steps[i]
		var type_id: String = _detect_step_type(step)
		if type_id == "":
			# Skip unconvertible step (no clean 1:1 mapping). Logged
			# rather than dropped silently.
			print("[node_script_editor] step %d had no editor-compatible single type — skipped." % i)
			continue
		var params: Dictionary = _extract_params(step, type_id)
		var pos: Vector2 = _parse_editor_pos(step.get("_editor_pos", ""), i)
		var section: String = _parse_section_from_name(String(step.get("name", "")))
		var gn := _add_node(type_id, pos, params, section)
		step_to_node[i] = gn.name

	# Second pass: wire edges. Each step's `dependencies` becomes an
	# incoming connection from the corresponding source node.
	for i in range(steps.size()):
		if not step_to_node.has(i):
			continue
		var step: Dictionary = steps[i]
		for dep_idx in step.get("dependencies", []):
			var src = step_to_node.get(int(dep_idx), null)
			if src == null:
				continue
			_graph.connect_node(String(src), 0, String(step_to_node[i]), 0)
	_suspend_signals = false


func _detect_step_type(step: Dictionary) -> String:
	# A "marker" step in the new format carries a `markers` array. We
	# expect one marker per node — multi-marker authored-in-bulk steps
	# get split or dropped (we report-only the first here).
	var markers: Array = step.get("markers", [])
	if not markers.is_empty():
		var m: Dictionary = markers[0]
		match String(m.get("type", "")):
			"box": return "draw_box"
			"text": return "draw_text"
	# Otherwise it's either an action step (one action) or a condition
	# step (one condition). Prefer the action when both exist.
	var actions: Array = step.get("actions", [])
	if actions.size() == 1:
		return String(actions[0].get("type", ""))
	if actions.size() > 1:
		# Multi-action steps don't round-trip cleanly. Pick the first.
		return String(actions[0].get("type", ""))
	var conditions: Array = step.get("conditions", [])
	if conditions.size() == 1:
		return String(conditions[0].get("type", ""))
	if conditions.size() > 1:
		return String(conditions[0].get("type", ""))
	return ""


func _extract_params(step: Dictionary, type_id: String) -> Dictionary:
	# Fish the source dict for the node-type's params from the step.
	var meta: Dictionary = NODE_TYPES.get(type_id, {})
	var spec: Dictionary = meta.get("params", {})
	var source: Dictionary = {}
	# Marker step: pull from the markers array.
	if step.get("markers", []).size() > 0 and meta.get("kind") == "marker":
		source = (step["markers"][0] as Dictionary).duplicate(true)
	elif step.get("actions", []).size() > 0 and meta.get("kind") == "action":
		source = (step["actions"][0] as Dictionary).duplicate(true)
	elif step.get("conditions", []).size() > 0 and meta.get("kind") == "condition":
		source = (step["conditions"][0] as Dictionary).duplicate(true)
	source.erase("type")
	# Preserve only spec keys; everything else is editor-noise.
	var out: Dictionary = {}
	for k in spec:
		if source.has(k):
			out[String(k)] = source[k]
	return out


## Extracts the section from a step's display name. The migration
## writes names as "<section> (<descriptor>)", so the section is
## everything before the first " (". A name with no parenthesised
## descriptor (e.g. a freshly-spawned single node) is treated as
## section-less rather than as a one-word section.
func _parse_section_from_name(raw: String) -> String:
	var idx: int = raw.find(" (")
	if idx <= 0:
		return ""
	return raw.substr(0, idx)


func _parse_editor_pos(raw: Variant, fallback_idx: int) -> Vector2:
	var s: String = String(raw)
	var parts: PackedStringArray = s.split(",")
	if parts.size() >= 2:
		return Vector2(int(parts[0]), int(parts[1]))
	# Default layout: cascade diagonally so newly-loaded scripts are
	# at least readable before the user rearranges them.
	return Vector2(120 + (fallback_idx % 5) * 260, 80 + int(fallback_idx / 5) * 180)
