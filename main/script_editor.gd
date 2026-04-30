extends CanvasLayer

# ============================================================
# SCRIPT_EDITOR.GD - Sector Script Editor Panel
# ============================================================
# Right-side panel for editing sector script steps.
# Each step has: on_enter actions, a condition to advance, on_exit actions.
# Steps execute linearly during gameplay via sector_script.gd.
# ============================================================

var main: Node2D

# --- SCRIPT DATA ---
## Array of step dictionaries, each with:
## { "name": String, "actions": [...], "conditions": [...], "on_exit": [...] }
## Each condition in conditions is a dict like {"type": "mined", "item_id": "copper", "amount": 10}
## All conditions must be satisfied (AND logic) for the step to advance.
var script_steps: Array = []
var selected_step_index: int = -1

# --- HINT DATA ---
## Array of hint dictionaries, see SectorScript HINT FORMAT for the schema.
var hints: Array = []
var selected_hint_index: int = -1

# --- PREVIEW STATE ---
## When on, every `draw_box` / `draw_text` action across every step is
## pushed into the live SectorScript's highlight/overlay dicts so the
## map editor shows exactly what the scripted boxes and texts will look
## like at runtime. Updates incrementally as you tweak any field value.
var _preview_enabled: bool = false
var _preview_btn: Button = null

# --- UI REFERENCES ---
var panel: PanelContainer
var step_list: VBoxContainer
var step_detail_scroll: ScrollContainer
var step_detail: VBoxContainer
var step_name_input: LineEdit
var actions_list: VBoxContainer
var condition_container: VBoxContainer
var exit_actions_list: VBoxContainer
var no_selection_label: Label

# Hints tab
var hint_list: VBoxContainer
var hint_detail: VBoxContainer
var hint_no_selection_label: Label

# Hint condition / remove-condition vocabulary
const HINT_TRIGGER_TYPES := ["landing", "block_placed", "item_produced", "units_produced", "time_after"]
const HINT_TRIGGER_LABELS := {
	"landing": "On Landing",
	"block_placed": "Block Placed",
	"item_produced": "Item Produced",
	"units_produced": "Units Produced",
	"time_after": "Time After (s)",
}
const HINT_REMOVE_TYPES := ["user_pressed_ok", "block_placed", "block_changed", "item_produced", "units_produced"]
const HINT_REMOVE_LABELS := {
	"user_pressed_ok": "User Pressed OK",
	"block_placed": "Block Placed",
	"block_changed": "Block Changed (at position)",
	"item_produced": "Item Produced",
	"units_produced": "Units Produced",
}

# --- CONDITION TYPE OPTIONS ---
const CONDITION_TYPES := [
	"always", "wait", "mined", "deposited", "produced",
	"placed", "units_produced", "units_destroyed", "ferox_blocks_destroyed",
	"core_unit_mined", "block_has_item", "decoded_archive", "waves_defeated",
]
const CONDITION_LABELS := {
	"always": "Immediately",
	"wait": "Wait (seconds)",
	"mined": "Item Mined",
	"deposited": "Item Deposited in Core",
	"produced": "Item Produced",
	"placed": "Block Placed",
	"units_produced": "Units Produced",
	"units_destroyed": "Ferox Units Destroyed",
	"ferox_blocks_destroyed": "Ferox Blocks Destroyed",
	"core_unit_mined": "Core Unit Mined",
	"block_has_item": "Block Has Item",
	"decoded_archive": "Archive Decoded",
	"waves_defeated": "All Waves Defeated",
}

# --- ACTION TYPE OPTIONS ---
const ACTION_TYPES := [
	"draw_box", 
	"draw_text", 
	"remove_box", 
	"remove_text", 
	"clear_boxes",
	"clear_texts",
	"hide_region", 
	"reveal_region", 
	"disable_block", 
	"enable_block", 
	"pause", 
	"unpause", 
	"focus_camera", 
	"release_camera",
	"spawn_unit",
	"start_waves", 
	"stop_waves",
	"capture_sector",
]
const ACTION_LABELS := {
	"pause": "Pause World",
	"unpause": "Unpause World",
	"focus_camera": "Focus Camera",
	"release_camera": "Release Camera",
	"draw_box": "Draw Box",
	"remove_box": "Remove Box (id)",
	"clear_boxes": "Clear All Boxes",
	"draw_text": "Draw Text Overlay",
	"remove_text": "Remove Text Overlay (id)",
	"clear_texts": "Clear All Text Overlays",
	"disable_block": "Disable Block",
	"enable_block": "Enable Block",
	"spawn_unit": "Spawn Unit",
	"hide_region": "Hide Region",
	"reveal_region": "Reveal Region",
	"capture_sector": "Capture Sector",
	"start_waves": "Start Waves",
	"stop_waves": "Stop Waves",
}

# Colors for the color dropdown
const BOX_COLORS := {
	"yellow": Color.YELLOW,
	"red": Color.RED,
	"green": Color.GREEN,
	"blue": Color.BLUE,
	"cyan": Color.CYAN,
	"orange": Color.ORANGE,
	"white": Color.WHITE,
	"magenta": Color.MAGENTA,
	"black": Color.BLACK,
	"gray": Color.GRAY,
}


func _ready() -> void:
	await get_tree().process_frame
	main = get_node("/root/Main")
	_create_panel()
	visible = false


func show_panel() -> void:
	visible = true
	# Pull the latest global-hints set off disk (in case another tool
	# wrote it) and merge into the editor's working list.
	_merge_globals_into_hints()
	_refresh_step_list()
	_refresh_hint_list()
	_refresh_hint_detail()


## De-duplicates against current `hints` by id and appends any global
## hints that aren't already represented. Called from `show_panel` so
## opening the editor with a partially-loaded sector still surfaces the
## global set.
func _merge_globals_into_hints() -> void:
	var sm = get_node_or_null("/root/SaveManager")
	if sm == null or not (sm.get("global_hints") is Array):
		return
	var existing_ids := {}
	for h in hints:
		if h is Dictionary:
			existing_ids[String(h.get("id", ""))] = true
	for gh in sm.global_hints:
		if not (gh is Dictionary):
			continue
		var gid := String(gh.get("id", ""))
		if existing_ids.has(gid):
			continue
		var entry: Dictionary = gh.duplicate(true)
		entry["global"] = true
		hints.append(entry)


func hide_panel() -> void:
	visible = false
	# Clear any preview overlays so closing the editor doesn't leave
	# scripted boxes/text floating over the runtime scene.
	if _preview_enabled:
		var sector = get_node_or_null("/root/Main/SectorScript")
		if sector:
			sector._highlight_boxes.clear()
			sector._text_overlays.clear()
			sector.queue_redraw()


# =========================
# PANEL CREATION
# =========================

func _create_panel() -> void:
	panel = PanelContainer.new()
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_top = 50
	panel.offset_bottom = -10
	panel.offset_left = -450
	panel.offset_right = -6
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0, 0, 0, 0.8)))
	add_child(panel)

	var root_vbox = VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 4)
	panel.add_child(root_vbox)

	# Title row: label + preview toggle
	var title_hbox = HBoxContainer.new()
	title_hbox.add_theme_constant_override("separation", 6)
	root_vbox.add_child(title_hbox)

	var title = Label.new()
	title.text = "Sector Script"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	title_hbox.add_child(title)

	# Preview toggle: when enabled, every draw_box / draw_text action
	# across every step is rendered live in the editor so the mapper can
	# see sizes, positions, colours, and wording at a glance. Updates in
	# real time (vec2i spinners, text field edits, etc.).
	_preview_btn = Button.new()
	_preview_btn.text = "Preview"
	_preview_btn.tooltip_text = "Toggle live preview of draw_box / draw_text actions"
	_preview_btn.toggle_mode = true
	_preview_btn.add_theme_font_size_override("font_size", 12)
	_preview_btn.toggled.connect(func(pressed: bool):
		_preview_enabled = pressed
		_refresh_preview()
	)
	title_hbox.add_child(_preview_btn)

	var sep = HSeparator.new()
	root_vbox.add_child(sep)

	# Tabs: Steps (existing UI) and Hints (new authoring panel).
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.tabs_visible = true
	root_vbox.add_child(tabs)

	# --- STEPS TAB ---
	var steps_tab := VBoxContainer.new()
	steps_tab.name = "Steps"
	steps_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_child(steps_tab)

	# Horizontal split: step list on left, step detail on right
	var hbox_split = HBoxContainer.new()
	hbox_split.add_theme_constant_override("separation", 8)
	hbox_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	steps_tab.add_child(hbox_split)

	# --- LEFT SIDE: Step list ---
	var left_vbox = VBoxContainer.new()
	left_vbox.add_theme_constant_override("separation", 4)
	left_vbox.custom_minimum_size.x = 100
	hbox_split.add_child(left_vbox)

	var list_label = Label.new()
	list_label.text = "Steps:"
	list_label.add_theme_font_size_override("font_size", 13)
	left_vbox.add_child(list_label)

	var list_scroll = ScrollContainer.new()
	list_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_vbox.add_child(list_scroll)

	step_list = VBoxContainer.new()
	step_list.add_theme_constant_override("separation", 2)
	list_scroll.add_child(step_list)

	# Add step button
	var add_btn = Button.new()
	add_btn.text = "+ Add Step"
	add_btn.pressed.connect(_on_add_step)
	left_vbox.add_child(add_btn)

	# --- Vertical separator ---
	var vsep = VSeparator.new()
	hbox_split.add_child(vsep)

	# --- RIGHT SIDE: Step detail editor ---
	step_detail_scroll = ScrollContainer.new()
	step_detail_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	step_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	step_detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	step_detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox_split.add_child(step_detail_scroll)

	step_detail = VBoxContainer.new()
	step_detail.add_theme_constant_override("separation", 4)
	step_detail_scroll.add_child(step_detail)

	# "No step selected" label
	no_selection_label = Label.new()
	no_selection_label.text = "Select a step to edit"
	no_selection_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	no_selection_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	step_detail.add_child(no_selection_label)

	# --- HINTS TAB ---
	var hints_tab := VBoxContainer.new()
	hints_tab.name = "Hints"
	hints_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_child(hints_tab)

	var h_hbox := HBoxContainer.new()
	h_hbox.add_theme_constant_override("separation", 8)
	h_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hints_tab.add_child(h_hbox)

	# Left column: hint list + add button
	var h_left := VBoxContainer.new()
	h_left.add_theme_constant_override("separation", 4)
	h_left.custom_minimum_size.x = 120
	h_hbox.add_child(h_left)

	var h_label := Label.new()
	h_label.text = "Hints:"
	h_label.add_theme_font_size_override("font_size", 13)
	h_left.add_child(h_label)

	var h_scroll := ScrollContainer.new()
	h_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	h_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	h_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	h_left.add_child(h_scroll)

	hint_list = VBoxContainer.new()
	hint_list.add_theme_constant_override("separation", 2)
	h_scroll.add_child(hint_list)

	var h_add_btn := Button.new()
	h_add_btn.text = "+ Add Hint"
	h_add_btn.pressed.connect(_on_add_hint)
	h_left.add_child(h_add_btn)

	var h_vsep := VSeparator.new()
	h_hbox.add_child(h_vsep)

	# Right column: hint detail editor
	var h_detail_scroll := ScrollContainer.new()
	h_detail_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	h_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	h_detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	h_detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h_hbox.add_child(h_detail_scroll)

	hint_detail = VBoxContainer.new()
	hint_detail.add_theme_constant_override("separation", 6)
	h_detail_scroll.add_child(hint_detail)

	hint_no_selection_label = Label.new()
	hint_no_selection_label.text = "Select a hint to edit"
	hint_no_selection_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_no_selection_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	hint_detail.add_child(hint_no_selection_label)


# =========================
# HINT LIST MANAGEMENT
# =========================

func _on_add_hint() -> void:
	# Compose a unique id by counting existing hints; the user can rename.
	var n: int = hints.size() + 1
	while _hint_id_in_use("h%d" % n):
		n += 1
	hints.append({
		"id": "h%d" % n,
		"text": "New hint",
		"condition": {"type": "landing"},
		"remove_when": {"type": "user_pressed_ok"},
		"can_be_ignored": true,
	})
	selected_hint_index = hints.size() - 1
	_refresh_hint_list()
	_refresh_hint_detail()
	_notify_change()


func _hint_id_in_use(id: String) -> bool:
	for h in hints:
		if String(h.get("id", "")) == id:
			return true
	return false


func _refresh_hint_list() -> void:
	for c in hint_list.get_children():
		c.queue_free()
	for i in hints.size():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		hint_list.add_child(row)
		var btn := Button.new()
		btn.text = String(hints[i].get("id", ""))
		btn.toggle_mode = true
		btn.button_pressed = (i == selected_hint_index)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var idx := i
		btn.pressed.connect(func():
			selected_hint_index = idx
			_refresh_hint_list()
			_refresh_hint_detail()
		)
		row.add_child(btn)
		var del_btn := Button.new()
		del_btn.text = "✕"
		del_btn.tooltip_text = "Delete hint"
		del_btn.add_theme_font_size_override("font_size", 11)
		del_btn.pressed.connect(func():
			hints.remove_at(idx)
			if selected_hint_index == idx:
				selected_hint_index = -1
			elif selected_hint_index > idx:
				selected_hint_index -= 1
			_refresh_hint_list()
			_refresh_hint_detail()
			_notify_change()
		)
		row.add_child(del_btn)


func _refresh_hint_detail() -> void:
	for c in hint_detail.get_children():
		c.queue_free()
	if selected_hint_index < 0 or selected_hint_index >= hints.size():
		hint_no_selection_label = Label.new()
		hint_no_selection_label.text = "Select a hint to edit"
		hint_no_selection_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint_no_selection_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		hint_detail.add_child(hint_no_selection_label)
		return
	var hint: Dictionary = hints[selected_hint_index]
	# id (read-only via LineEdit, editable but uniqueness enforced on text changed)
	_add_string_field(hint_detail, hint, "id", "ID:")
	# text — multiline so authors can write paragraphs
	_add_multiline_field(hint_detail, hint, "text", "Hint Text:")
	# can_be_ignored
	_add_checkbox(hint_detail, hint, "can_be_ignored", "Show OK button (ignorable)")
	# global — when ticked the hint is stored in user://global_hints.json
	# and merged into every sector's hint list at landing. Dismissals
	# carry across sectors via campaign.json.
	_add_checkbox(hint_detail, hint, "global", "Global (cross-sector)")

	# Condition group
	hint_detail.add_child(HSeparator.new())
	var cond_title := Label.new()
	cond_title.text = "Condition (when to show):"
	cond_title.add_theme_font_size_override("font_size", 12)
	cond_title.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	hint_detail.add_child(cond_title)
	if not (hint.get("condition") is Dictionary):
		hint["condition"] = {"type": "landing"}
	_add_hint_trigger_editor(hint_detail, hint["condition"], HINT_TRIGGER_TYPES, HINT_TRIGGER_LABELS)

	# Remove-when group
	hint_detail.add_child(HSeparator.new())
	var rm_title := Label.new()
	rm_title.text = "Remove When (when to hide):"
	rm_title.add_theme_font_size_override("font_size", 12)
	rm_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.7))
	hint_detail.add_child(rm_title)
	if not (hint.get("remove_when") is Dictionary):
		hint["remove_when"] = {"type": "user_pressed_ok"}
	_add_hint_trigger_editor(hint_detail, hint["remove_when"], HINT_REMOVE_TYPES, HINT_REMOVE_LABELS)


## Renders a (type-dropdown + per-type args) editor for a hint condition or
## remove_when dict. Args are stored on the same dict (block_id, item_id,
## unit_id, amount, position, seconds) so a type change leaves stale keys
## in place but harmless — the runtime only reads the keys relevant to
## the current type.
func _add_hint_trigger_editor(parent: Control, data: Dictionary, types: Array, labels: Dictionary) -> void:
	var holder := VBoxContainer.new()
	holder.add_theme_constant_override("separation", 4)
	parent.add_child(holder)
	var row := HBoxContainer.new()
	holder.add_child(row)
	var lbl := Label.new()
	lbl.text = "Type:"
	lbl.custom_minimum_size.x = 60
	row.add_child(lbl)
	var opt := OptionButton.new()
	for t in types:
		opt.add_item(String(labels.get(t, t)))
	var current_type := String(data.get("type", types[0]))
	if not types.has(current_type):
		current_type = types[0]
		data["type"] = current_type
	opt.select(types.find(current_type))
	opt.item_selected.connect(func(i: int):
		data["type"] = types[i]
		# Re-render the entire detail so the args section reflects the new type.
		_refresh_hint_detail()
		_notify_change()
	)
	row.add_child(opt)

	# Per-type args.
	match current_type:
		"block_placed", "block_changed":
			_add_block_dropdown(holder, data)
			if current_type == "block_placed":
				_add_int_field(holder, data, "amount", "Amount:", 1)
			else:
				_add_vec2i_fields(holder, data, "position", "Position (x,y):")
		"item_produced":
			_add_item_dropdown(holder, data)
			_add_int_field(holder, data, "amount", "Amount:", 1)
		"units_produced":
			_add_unit_dropdown(holder, data)
			_add_int_field(holder, data, "amount", "Amount:", 1)
		"time_after":
			_add_float_field(holder, data, "seconds", "Seconds:", 5.0)
		_:
			pass


# =========================
# STEP LIST MANAGEMENT
# =========================

func _on_add_step() -> void:
	var step := {
		"name": "Step %d" % (script_steps.size() + 1),
		"actions": [],
		"conditions": [{"type": "always"}],
		"on_exit": [],
	}
	script_steps.append(step)
	selected_step_index = script_steps.size() - 1
	_refresh_step_list()
	_refresh_step_detail()


func _refresh_step_list() -> void:
	for child in step_list.get_children():
		child.queue_free()

	for i in range(script_steps.size()):
		var step = script_steps[i]
		var idx := i

		# Wrapper: click anywhere to select
		var item_panel = PanelContainer.new()
		var bg_color := Color(0.2, 0.35, 0.5, 0.6) if i == selected_step_index else Color(0.12, 0.12, 0.15, 0.6)
		item_panel.add_theme_stylebox_override("panel", _panel_style(bg_color))
		step_list.add_child(item_panel)

		var vbox = VBoxContainer.new()
		vbox.add_theme_constant_override("separation", 1)
		item_panel.add_child(vbox)

		# Top row: step name (clickable to select)
		var name_btn = Button.new()
		name_btn.text = "%d. %s" % [i + 1, step["name"]]
		name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_btn.add_theme_font_size_override("font_size", 12)
		if i == selected_step_index:
			name_btn.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
		name_btn.pressed.connect(func():
			selected_step_index = idx
			_refresh_step_list()
			_refresh_step_detail()
		)
		vbox.add_child(name_btn)

		# Bottom row: move up/down + delete
		var btn_hbox = HBoxContainer.new()
		btn_hbox.add_theme_constant_override("separation", 2)
		vbox.add_child(btn_hbox)

		var up_btn = Button.new()
		up_btn.text = "▲"
		up_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		up_btn.disabled = (i == 0)
		up_btn.add_theme_font_size_override("font_size", 10)
		up_btn.pressed.connect(func():
			_swap_steps(idx, idx - 1)
		)
		btn_hbox.add_child(up_btn)

		var down_btn = Button.new()
		down_btn.text = "▼"
		down_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		down_btn.disabled = (i == script_steps.size() - 1)
		down_btn.add_theme_font_size_override("font_size", 10)
		down_btn.pressed.connect(func():
			_swap_steps(idx, idx + 1)
		)
		btn_hbox.add_child(down_btn)

		var del_btn = Button.new()
		del_btn.text = "X"
		del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		del_btn.add_theme_font_size_override("font_size", 10)
		del_btn.pressed.connect(func():
			script_steps.remove_at(idx)
			if selected_step_index >= script_steps.size():
				selected_step_index = script_steps.size() - 1
			_refresh_step_list()
			_refresh_step_detail()
		)
		btn_hbox.add_child(del_btn)


func _swap_steps(a: int, b: int) -> void:
	var tmp = script_steps[a]
	script_steps[a] = script_steps[b]
	script_steps[b] = tmp
	if selected_step_index == a:
		selected_step_index = b
	elif selected_step_index == b:
		selected_step_index = a
	_refresh_step_list()
	_refresh_step_detail()


# =========================
# STEP DETAIL EDITOR
# =========================

func _refresh_step_detail() -> void:
	for child in step_detail.get_children():
		child.queue_free()

	# Any structural edit (adding/removing/reordering actions or changing
	# an action's type) lands here, so refresh the live preview alongside
	# the rebuilt UI so added draw_box/draw_text entries appear instantly.
	_notify_change()

	if selected_step_index < 0 or selected_step_index >= script_steps.size():
		no_selection_label = Label.new()
		no_selection_label.text = "Select a step to edit"
		no_selection_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		no_selection_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		step_detail.add_child(no_selection_label)
		return

	var step: Dictionary = script_steps[selected_step_index]

	# Step name
	var name_label = Label.new()
	name_label.text = "Step Name:"
	name_label.add_theme_font_size_override("font_size", 12)
	step_detail.add_child(name_label)

	step_name_input = LineEdit.new()
	step_name_input.text = step["name"]
	step_name_input.text_changed.connect(func(new_text: String):
		step["name"] = new_text
		_refresh_step_list()
	)
	step_detail.add_child(step_name_input)

	# --- ON ENTER ACTIONS ---
	var actions_header = Label.new()
	actions_header.text = "On Enter Actions:"
	actions_header.add_theme_font_size_override("font_size", 13)
	actions_header.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
	step_detail.add_child(actions_header)

	actions_list = VBoxContainer.new()
	actions_list.add_theme_constant_override("separation", 2)
	step_detail.add_child(actions_list)
	_populate_actions_list(step["actions"], actions_list)

	var add_action_btn = Button.new()
	add_action_btn.text = "+ Add Action"
	add_action_btn.add_theme_font_size_override("font_size", 12)
	add_action_btn.pressed.connect(func():
		step["actions"].append({"type": "draw_box"})
		_refresh_step_detail()
	)
	step_detail.add_child(add_action_btn)

	# --- CONDITIONS ---
	var sep = HSeparator.new()
	step_detail.add_child(sep)

	var cond_header = Label.new()
	cond_header.text = "Advance When (ALL must be met):"
	cond_header.add_theme_font_size_override("font_size", 13)
	cond_header.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
	step_detail.add_child(cond_header)

	condition_container = VBoxContainer.new()
	condition_container.add_theme_constant_override("separation", 4)
	step_detail.add_child(condition_container)
	_populate_conditions(step)

	var add_cond_btn = Button.new()
	add_cond_btn.text = "+ Add Condition"
	add_cond_btn.add_theme_font_size_override("font_size", 12)
	add_cond_btn.pressed.connect(func():
		step["conditions"].append({"type": "always"})
		_refresh_step_detail()
	)
	step_detail.add_child(add_cond_btn)

	# --- ON EXIT ACTIONS ---
	var sep2 = HSeparator.new()
	step_detail.add_child(sep2)

	var exit_header = Label.new()
	exit_header.text = "On Exit Actions:"
	exit_header.add_theme_font_size_override("font_size", 13)
	exit_header.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))
	step_detail.add_child(exit_header)

	exit_actions_list = VBoxContainer.new()
	exit_actions_list.add_theme_constant_override("separation", 2)
	step_detail.add_child(exit_actions_list)
	_populate_actions_list(step["on_exit"], exit_actions_list)

	var add_exit_btn = Button.new()
	add_exit_btn.text = "+ Add Exit Action"
	add_exit_btn.add_theme_font_size_override("font_size", 12)
	add_exit_btn.pressed.connect(func():
		step["on_exit"].append({"type": "clear_boxes"})
		_refresh_step_detail()
	)
	step_detail.add_child(add_exit_btn)


# =========================
# ACTION LIST UI
# =========================

func _populate_actions_list(actions: Array, container: VBoxContainer) -> void:
	for i in range(actions.size()):
		var action: Dictionary = actions[i]
		var action_panel = PanelContainer.new()
		action_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.1, 0.1, 0.15, 0.8)))
		container.add_child(action_panel)

		var vbox = VBoxContainer.new()
		vbox.add_theme_constant_override("separation", 2)
		action_panel.add_child(vbox)

		# Top row: type dropdown + delete
		var top_hbox = HBoxContainer.new()
		top_hbox.add_theme_constant_override("separation", 2)
		vbox.add_child(top_hbox)

		var type_option = OptionButton.new()
		type_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		type_option.add_theme_font_size_override("font_size", 11)
		for t in ACTION_TYPES:
			type_option.add_item(ACTION_LABELS[t])
		type_option.selected = ACTION_TYPES.find(action.get("type", "pause"))
		var action_ref := action
		var actions_ref := actions
		var idx := i
		type_option.item_selected.connect(func(sel: int):
			var old_type: String = action_ref.get("type", "")
			action_ref["type"] = ACTION_TYPES[sel]
			# Clear params when type changes
			if old_type != ACTION_TYPES[sel]:
				for key in action_ref.keys():
					if key != "type":
						action_ref.erase(key)
			_refresh_step_detail()
		)
		top_hbox.add_child(type_option)

		var dup_btn = Button.new()
		dup_btn.text = "⧉"
		dup_btn.custom_minimum_size.x = 28
		dup_btn.pressed.connect(func():
			actions_ref.insert(idx + 1, action_ref.duplicate(true))
			_refresh_step_detail()
		)
		top_hbox.add_child(dup_btn)

		var del_btn = Button.new()
		del_btn.text = "X"
		del_btn.custom_minimum_size.x = 28
		del_btn.pressed.connect(func():
			actions_ref.remove_at(idx)
			_refresh_step_detail()
		)
		top_hbox.add_child(del_btn)

		# Parameters based on action type
		var action_type: String = action.get("type", "pause")
		match action_type:
			"focus_camera":
				_add_vec2i_fields(vbox, action, "pos", "Grid X,Y:")
			"draw_box":
				_add_string_field(vbox, action, "id", "Box ID:")
				_add_vec2i_fields(vbox, action, "from", "From (x,y):")
				_add_vec2i_fields(vbox, action, "to", "To (x,y):")
				_add_color_dropdown(vbox, action)
			"remove_box":
				_add_string_field(vbox, action, "id", "Box ID:")
			"draw_text":
				_add_string_field(vbox, action, "id", "Text ID:")
				_add_vec2i_fields(vbox, action, "from", "From (x,y):")
				_add_vec2i_fields(vbox, action, "to", "To (x,y):")
				_add_multiline_field(vbox, action, "text", "Text:")
			"remove_text":
				_add_string_field(vbox, action, "id", "Text ID:")
			"disable_block", "enable_block":
				_add_vec2i_fields(vbox, action, "pos", "Grid X,Y:")
			"spawn_unit":
				_add_vec2i_fields(vbox, action, "pos", "Grid X,Y:")
				_add_faction_dropdown(vbox, action)
				_add_unit_dropdown(vbox, action)
				_add_int_field(vbox, action, "count", "Count:", 1)
			"hide_region":
				_add_vec2i_fields(vbox, action, "from", "From (x,y):")
				_add_vec2i_fields(vbox, action, "to", "To (x,y):")
				_add_checkbox(vbox, action, "include_floors", "Include Floors")
			"reveal_region":
				_add_vec2i_fields(vbox, action, "from", "From (x,y):")
				_add_vec2i_fields(vbox, action, "to", "To (x,y):")
			# capture_sector has no params — auto-detects current sector
			# pause, unpause, release_camera, clear_boxes, clear_texts have no params


# =========================
# CONDITION UI
# =========================

func _populate_conditions(step: Dictionary) -> void:
	# Migrate old singular "condition" key to "conditions" array
	if step.has("condition") and not step.has("conditions"):
		step["conditions"] = [step["condition"]]
		step.erase("condition")
	if not step.has("conditions") or step["conditions"].is_empty():
		step["conditions"] = [{"type": "always"}]

	var conditions: Array = step["conditions"]

	for i in range(conditions.size()):
		var cond: Dictionary = conditions[i]
		var cond_idx := i

		var cond_panel = PanelContainer.new()
		cond_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.15, 0.13, 0.05, 0.8)))
		condition_container.add_child(cond_panel)

		var vbox = VBoxContainer.new()
		vbox.add_theme_constant_override("separation", 2)
		cond_panel.add_child(vbox)

		# Top row: type dropdown + delete button
		var top_hbox = HBoxContainer.new()
		top_hbox.add_theme_constant_override("separation", 2)
		vbox.add_child(top_hbox)

		var type_option = OptionButton.new()
		type_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		type_option.add_theme_font_size_override("font_size", 11)
		for t in CONDITION_TYPES:
			type_option.add_item(CONDITION_LABELS[t])
		type_option.selected = CONDITION_TYPES.find(cond.get("type", "always"))
		type_option.item_selected.connect(func(sel: int):
			conditions[cond_idx] = {"type": CONDITION_TYPES[sel]}
			_refresh_step_detail()
		)
		top_hbox.add_child(type_option)

		var cond_dup_btn = Button.new()
		cond_dup_btn.text = "⧉"
		cond_dup_btn.custom_minimum_size.x = 28
		cond_dup_btn.pressed.connect(func():
			conditions.insert(cond_idx + 1, cond.duplicate(true))
			_refresh_step_detail()
		)
		top_hbox.add_child(cond_dup_btn)

		# Only show delete if there's more than one condition
		if conditions.size() > 1:
			var del_btn = Button.new()
			del_btn.text = "X"
			del_btn.custom_minimum_size.x = 28
			del_btn.pressed.connect(func():
				conditions.remove_at(cond_idx)
				_refresh_step_detail()
			)
			top_hbox.add_child(del_btn)

		# Parameters based on condition type
		var cond_type: String = cond.get("type", "always")
		match cond_type:
			"wait":
				_add_float_field(vbox, cond, "seconds", "Seconds:", 3.0)
			"mined", "deposited", "produced", "core_unit_mined":
				_add_item_dropdown(vbox, cond)
				_add_int_field(vbox, cond, "amount", "Amount:", 1)
			"placed":
				_add_block_dropdown(vbox, cond)
				_add_int_field(vbox, cond, "amount", "Amount:", 1)
			"units_produced", "units_destroyed":
				_add_unit_dropdown(vbox, cond)
				_add_int_field(vbox, cond, "amount", "Amount:", 1)
			"ferox_blocks_destroyed":
				_add_block_dropdown(vbox, cond)
				_add_int_field(vbox, cond, "amount", "Amount:", 1)
			"block_has_item":
				_add_vec2i_fields(vbox, cond, "pos", "Grid X,Y:")
				_add_item_dropdown(vbox, cond)
				_add_int_field(vbox, cond, "amount", "Amount:", 1)
			"decoded_archive":
				# Leave archive_id blank to match ANY archive being decoded;
				# pick a specific archive id to gate on that one alone.
				_add_archive_dropdown(vbox, cond)
				_add_int_field(vbox, cond, "amount", "Amount:", 1)
			# "always" has no params

		# Show "AND" label between conditions (not after the last one)
		if i < conditions.size() - 1:
			var and_label = Label.new()
			and_label.text = "AND"
			and_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			and_label.add_theme_font_size_override("font_size", 11)
			and_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3, 0.7))
			condition_container.add_child(and_label)


# =========================
# FIELD HELPERS
# =========================

func _add_string_field(parent: Control, data: Dictionary, key: String, label_text: String) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	parent.add_child(hbox)

	var lbl = Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.custom_minimum_size.x = 60
	hbox.add_child(lbl)

	var input = LineEdit.new()
	input.text = str(data.get(key, ""))
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.add_theme_font_size_override("font_size", 11)
	input.text_changed.connect(func(t: String):
		data[key] = t
		_notify_change()
	)
	hbox.add_child(input)


func _add_multiline_field(parent: Control, data: Dictionary, key: String, label_text: String) -> void:
	var lbl = Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 11)
	parent.add_child(lbl)

	var text_edit = TextEdit.new()
	text_edit.text = str(data.get(key, ""))
	text_edit.custom_minimum_size.y = 60
	text_edit.add_theme_font_size_override("font_size", 11)
	text_edit.text_changed.connect(func():
		data[key] = text_edit.text
		_notify_change()
	)
	parent.add_child(text_edit)


func _add_vec2i_fields(parent: Control, data: Dictionary, key: String, label_text: String) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	parent.add_child(hbox)

	var lbl = Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.custom_minimum_size.x = 60
	hbox.add_child(lbl)

	# Parse existing value
	var existing: String = str(data.get(key, "0,0"))
	var parts = existing.split(",")
	var x_val := 0
	var y_val := 0
	if parts.size() >= 2:
		x_val = int(parts[0].strip_edges())
		y_val = int(parts[1].strip_edges())

	var x_input = SpinBox.new()
	x_input.min_value = 0
	x_input.max_value = 999
	x_input.value = x_val
	x_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	x_input.add_theme_font_size_override("font_size", 11)
	hbox.add_child(x_input)

	var y_input = SpinBox.new()
	y_input.min_value = 0
	y_input.max_value = 999
	y_input.value = y_val
	y_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	y_input.add_theme_font_size_override("font_size", 11)
	hbox.add_child(y_input)

	var update_fn := func(_val: float = 0.0):
		data[key] = "%d,%d" % [int(x_input.value), int(y_input.value)]
		_notify_change()
	x_input.value_changed.connect(update_fn)
	y_input.value_changed.connect(update_fn)
	# Set initial value
	data[key] = "%d,%d" % [x_val, y_val]


func _add_int_field(parent: Control, data: Dictionary, key: String, label_text: String, default_val: int) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	parent.add_child(hbox)

	var lbl = Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.custom_minimum_size.x = 60
	hbox.add_child(lbl)

	var spin = SpinBox.new()
	spin.min_value = 1
	spin.max_value = 99999
	spin.value = int(data.get(key, default_val))
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.add_theme_font_size_override("font_size", 11)
	spin.value_changed.connect(func(v: float):
		data[key] = int(v)
		_notify_change()
	)
	hbox.add_child(spin)


func _add_float_field(parent: Control, data: Dictionary, key: String, label_text: String, default_val: float) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	parent.add_child(hbox)

	var lbl = Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.custom_minimum_size.x = 60
	hbox.add_child(lbl)

	var spin = SpinBox.new()
	spin.min_value = 0.1
	spin.max_value = 999.0
	spin.step = 0.1
	spin.value = float(data.get(key, default_val))
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.add_theme_font_size_override("font_size", 11)
	spin.value_changed.connect(func(v: float):
		data[key] = v
		_notify_change()
	)
	hbox.add_child(spin)


func _add_color_dropdown(parent: Control, data: Dictionary) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	parent.add_child(hbox)

	var lbl = Label.new()
	lbl.text = "Color:"
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.custom_minimum_size.x = 60
	hbox.add_child(lbl)

	var option = OptionButton.new()
	option.add_theme_font_size_override("font_size", 11)
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var color_names: Array = BOX_COLORS.keys()
	for cn in color_names:
		option.add_item(cn.capitalize())
	var current_color: String = data.get("color", "yellow")
	var sel_idx: int = color_names.find(current_color)
	if sel_idx < 0:
		sel_idx = 0
	option.selected = sel_idx
	option.item_selected.connect(func(idx: int):
		data["color"] = color_names[idx]
		_notify_change()
	)
	hbox.add_child(option)


func _add_item_dropdown(parent: Control, data: Dictionary) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	parent.add_child(hbox)

	var lbl = Label.new()
	lbl.text = "Item:"
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.custom_minimum_size.x = 60
	hbox.add_child(lbl)

	var option = OptionButton.new()
	option.add_theme_font_size_override("font_size", 11)
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var item_ids: Array = []
	for item_id in Registry.items:
		item_ids.append(String(item_id))
	item_ids.sort()
	for id_str in item_ids:
		var item_data = Registry.get_item(StringName(id_str))
		var display: String = item_data.display_name if item_data and item_data.display_name != "" else id_str
		option.add_item(display)
	var current_id: String = str(data.get("item_id", ""))
	var sel_idx: int = item_ids.find(current_id)
	if sel_idx < 0:
		sel_idx = 0
	if item_ids.size() > 0:
		option.selected = sel_idx
		data["item_id"] = item_ids[sel_idx]
	option.item_selected.connect(func(idx: int):
		data["item_id"] = item_ids[idx]
		_notify_change()
	)
	hbox.add_child(option)


func _add_block_dropdown(parent: Control, data: Dictionary) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	parent.add_child(hbox)

	var lbl = Label.new()
	lbl.text = "Block:"
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.custom_minimum_size.x = 60
	hbox.add_child(lbl)

	var option = OptionButton.new()
	option.add_theme_font_size_override("font_size", 11)
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var block_ids: Array = []
	for block_id in Registry.blocks:
		block_ids.append(String(block_id))
	block_ids.sort()
	for id_str in block_ids:
		var block_data = Registry.get_block(StringName(id_str))
		var display: String = block_data.display_name if block_data and block_data.display_name != "" else id_str
		option.add_item(display)
	var current_id: String = str(data.get("block_id", ""))
	var sel_idx: int = block_ids.find(current_id)
	if sel_idx < 0:
		sel_idx = 0
	if block_ids.size() > 0:
		option.selected = sel_idx
		data["block_id"] = block_ids[sel_idx]
	option.item_selected.connect(func(idx: int):
		data["block_id"] = block_ids[idx]
		_notify_change()
	)
	hbox.add_child(option)


func _add_unit_dropdown(parent: Control, data: Dictionary) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	parent.add_child(hbox)

	var lbl = Label.new()
	lbl.text = "Unit:"
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.custom_minimum_size.x = 60
	hbox.add_child(lbl)

	var option = OptionButton.new()
	option.add_theme_font_size_override("font_size", 11)
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var unit_ids: Array = []
	for unit_id in Registry.units:
		unit_ids.append(String(unit_id))
	unit_ids.sort()
	for id_str in unit_ids:
		var unit_data = Registry.get_unit(StringName(id_str))
		var display: String = unit_data.display_name if unit_data and unit_data.display_name != "" else id_str
		option.add_item(display)
	var current_id: String = str(data.get("unit_id", ""))
	var sel_idx: int = unit_ids.find(current_id)
	if sel_idx < 0:
		sel_idx = 0
	if unit_ids.size() > 0:
		option.selected = sel_idx
		data["unit_id"] = unit_ids[sel_idx]
	option.item_selected.connect(func(idx: int):
		data["unit_id"] = unit_ids[idx]
		_notify_change()
	)
	hbox.add_child(option)


## Archive id dropdown for the "decoded_archive" condition. Pulls the list
## from TechTree.archive_ids and prepends an "(Any)" option that stores the
## empty StringName so the condition matches any archive being decoded.
func _add_archive_dropdown(parent: Control, data: Dictionary) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	parent.add_child(hbox)

	var lbl = Label.new()
	lbl.text = "Archive:"
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.custom_minimum_size.x = 60
	hbox.add_child(lbl)

	var option = OptionButton.new()
	option.add_theme_font_size_override("font_size", 11)
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var archive_ids: Array = [""]
	option.add_item("(Any archive)")
	for aid in TechTree.archive_ids:
		archive_ids.append(String(aid))
		var nd = TechTree.get_node_data(aid)
		var aname: String = nd["name"] if nd else String(aid)
		option.add_item(aname)

	var current_id: String = str(data.get("archive_id", ""))
	var sel_idx: int = archive_ids.find(current_id)
	if sel_idx < 0:
		sel_idx = 0
	option.selected = sel_idx
	data["archive_id"] = archive_ids[sel_idx]
	option.item_selected.connect(func(idx: int):
		data["archive_id"] = archive_ids[idx]
		_notify_change()
	)
	hbox.add_child(option)


func _add_faction_dropdown(parent: Control, data: Dictionary) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	parent.add_child(hbox)

	var lbl = Label.new()
	lbl.text = "Faction:"
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.custom_minimum_size.x = 60
	hbox.add_child(lbl)

	var option = OptionButton.new()
	option.add_theme_font_size_override("font_size", 11)
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var factions := ["lumina", "ferox"]
	option.add_item("Lumina")
	option.add_item("Ferox")
	var current: String = data.get("faction", "ferox")
	option.selected = factions.find(current) if factions.has(current) else 1
	data["faction"] = factions[option.selected]
	option.item_selected.connect(func(idx: int):
		data["faction"] = factions[idx]
		_notify_change()
	)
	hbox.add_child(option)


func _add_checkbox(parent: Control, data: Dictionary, key: String, label_text: String) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	parent.add_child(hbox)

	var check = CheckBox.new()
	check.text = label_text
	check.add_theme_font_size_override("font_size", 11)
	check.button_pressed = bool(data.get(key, false))
	check.toggled.connect(func(pressed: bool):
		data[key] = pressed
		_notify_change()
	)
	hbox.add_child(check)


# =========================
# LIVE PREVIEW
# =========================

## Called by every field-edit callback so size/position/color/text tweaks
## show up instantly in the editor. Cheap no-op when preview is off.
func _notify_change() -> void:
	if _preview_enabled:
		_refresh_preview()
	# Hints don't need the script-step runner to be live — push them to
	# SectorScript on every edit so authoring → display works without
	# round-tripping through save/load.
	_push_hints_to_runtime()
	# Always rewrite the global-hints file so a flipped checkbox or text
	# edit on a global hint persists immediately. Cheap — only writes
	# entries flagged `global=true`.
	_persist_global_hints()


## Splits the editor's `hints` list into sector vs global, writing the
## global subset to SaveManager.global_hints_file. Called whenever the
## list / detail changes (add, remove, edit, global-toggle).
func _persist_global_hints() -> void:
	var sm = get_node_or_null("/root/SaveManager")
	if sm == null or not sm.has_method("save_global_hints_file"):
		return
	var globals: Array = []
	for h in hints:
		if h is Dictionary and bool(h.get("global", false)):
			globals.append(h.duplicate(true))
	sm.save_global_hints_file(globals)


## Mirrors the authored hints into the live SectorScript so the HUD's
## fade-in panel triggers as soon as the player meets a condition. The
## runtime preserves prior state for ids that still exist (so editing an
## unrelated hint doesn't re-fire one already in flight).
func _push_hints_to_runtime() -> void:
	var sector = get_node_or_null("/root/Main/SectorScript")
	if sector == null:
		return
	if not sector.has_method("load_hints"):
		return
	# Capture which ids are currently active/dismissed so a benign edit
	# doesn't reset their state.
	var prior: Dictionary = {}
	if sector.get("_hint_runtime") is Dictionary:
		prior = sector._hint_runtime.duplicate(true)
	sector.load_hints(hints)
	# Re-apply prior runtime entries for surviving ids.
	if prior.is_empty():
		return
	for h in hints:
		var id := String(h.get("id", ""))
		if id != "" and prior.has(id):
			sector._hint_runtime[id] = prior[id]
			if String(prior[id].get("state", "")) == "active":
				sector.hint_show.emit(h)


## Walks every step's `actions` (and `on_exit`) looking for `draw_box` and
## `draw_text` entries, and pushes them straight into SectorScript's
## `_highlight_boxes` / `_text_overlays` dicts. When preview is disabled
## the dicts are cleared instead. Uses the same vec/color parsing rules
## as `sector_script._execute_action` so what you see here matches what
## the script will actually draw at runtime.
func _refresh_preview() -> void:
	var sector = _get_or_create_sector_script()
	if sector == null:
		return
	# Always start from a clean slate so removed actions vanish.
	sector._highlight_boxes.clear()
	sector._text_overlays.clear()
	if _preview_enabled:
		for step in script_steps:
			_collect_draw_actions(step.get("actions", []), sector)
			_collect_draw_actions(step.get("on_exit", []), sector)
	sector.queue_redraw()


## Returns the existing /root/Main/SectorScript node, or instantiates one
## into the map editor's main scene. The map-editor scene doesn't ship a
## SectorScript node (only the runtime scene does) so the script-editor
## panel creates one lazily the first time it wants to show a preview.
## SectorScript._ready already guards its signal hookups with has_signal,
## so it boots cleanly against the map editor's trimmed signal set.
func _get_or_create_sector_script() -> Node:
	var main_node = get_node_or_null("/root/Main")
	if main_node == null:
		return null
	var sector = main_node.get_node_or_null("SectorScript")
	if sector != null:
		return sector
	sector = SectorScript.new()
	sector.name = "SectorScript"
	# SectorScript is a Node2D that draws in world space — add it under
	# Main so `main.grid_to_world` / `GRID_SIZE` resolve the same way they
	# do at runtime.
	main_node.add_child(sector)
	return sector


func _collect_draw_actions(actions: Array, sector: Node) -> void:
	for action in actions:
		if not (action is Dictionary):
			continue
		var atype: String = String(action.get("type", ""))
		match atype:
			"draw_box":
				var box_id: String = String(action.get("id", ""))
				if box_id == "":
					continue
				var from_pos: Vector2i = _parse_vec2i(action.get("from", "0,0"))
				var to_pos: Vector2i = _parse_vec2i(action.get("to", "0,0"))
				var color_name: String = String(action.get("color", "yellow"))
				var color: Color = BOX_COLORS.get(color_name, Color.YELLOW)
				sector.draw_box(box_id, from_pos, to_pos, color)
			"draw_text":
				var text_id: String = String(action.get("id", ""))
				if text_id == "":
					continue
				var from_pos: Vector2i = _parse_vec2i(action.get("from", "0,0"))
				var to_pos: Vector2i = _parse_vec2i(action.get("to", "0,0"))
				var text: String = String(action.get("text", ""))
				sector.draw_text_overlay(text_id, from_pos, to_pos, text)


func _parse_vec2i(raw: Variant) -> Vector2i:
	var s: String = str(raw)
	var parts = s.split(",")
	if parts.size() < 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0].strip_edges()), int(parts[1].strip_edges()))


# =========================
# SERIALIZATION
# =========================

## Returns the script steps as a serializable array for JSON.
func get_script_data() -> Array:
	return script_steps.duplicate(true)


## Loads script steps from a parsed JSON array.
func set_script_data(data: Array) -> void:
	script_steps = data.duplicate(true)
	selected_step_index = -1
	if visible:
		_refresh_step_list()
		_refresh_step_detail()


## Returns the authored hints as a serializable array for JSON.
func get_hints_data() -> Array:
	return hints.duplicate(true)


func set_hints_data(data: Array) -> void:
	hints = data.duplicate(true) if data is Array else []
	# Strip any stale globals out of the per-sector list (older saves
	# may have stored them inline) and re-merge from the canonical
	# global-hints file so editing one sector shows the same global set
	# as every other.
	var sector_only: Array = []
	for h in hints:
		if h is Dictionary and bool(h.get("global", false)):
			continue
		sector_only.append(h)
	hints = sector_only
	var sm = get_node_or_null("/root/SaveManager")
	if sm and sm.get("global_hints") is Array:
		var existing_ids := {}
		for h in hints:
			if h is Dictionary:
				existing_ids[String(h.get("id", ""))] = true
		for gh in sm.global_hints:
			if not (gh is Dictionary):
				continue
			var gid := String(gh.get("id", ""))
			# Skip if a sector hint with the same id already lives here
			# (defensive — id collisions shouldn't normally happen).
			if existing_ids.has(gid):
				continue
			var entry: Dictionary = gh.duplicate(true)
			entry["global"] = true
			hints.append(entry)
	selected_hint_index = -1
	if visible and hint_list != null:
		_refresh_hint_list()
		_refresh_hint_detail()
	_push_hints_to_runtime()


# =========================
# STYLE HELPERS
# =========================

func _panel_style(bg_color: Color) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = bg_color
	s.set_corner_radius_all(6)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s
