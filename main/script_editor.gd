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

# --- CONDITION TYPE OPTIONS ---
const CONDITION_TYPES := [
	"always", "wait", "mined", "deposited", "produced",
	"placed", "units_produced", "units_destroyed", "ferox_blocks_destroyed",
	"core_unit_mined", "block_has_item"
]
const CONDITION_LABELS := {
	"always": "Immediately",
	"wait": "Wait (seconds)",
	"mined": "Item Mined",
	"deposited": "Item Deposited in Core",
	"produced": "Item Produced",
	"placed": "Block Placed",
	"units_produced": "Units Produced",
	"units_destroyed": "FEROX Units Destroyed",
	"ferox_blocks_destroyed": "FEROX Blocks Destroyed",
	"core_unit_mined": "Core Unit Mined",
	"block_has_item": "Block Has Item (grid x,y)",
}

# --- ACTION TYPE OPTIONS ---
const ACTION_TYPES := [
	"pause", "unpause", "focus_camera", "release_camera",
	"draw_box", "remove_box", "clear_boxes",
	"draw_text", "remove_text", "clear_texts",
	"disable_block", "enable_block", "spawn_unit",
	"hide_region", "reveal_region", "capture_sector"
]
const ACTION_LABELS := {
	"pause": "Pause World",
	"unpause": "Unpause World",
	"focus_camera": "Focus Camera (grid x,y)",
	"release_camera": "Release Camera",
	"draw_box": "Draw Box",
	"remove_box": "Remove Box (id)",
	"clear_boxes": "Clear All Boxes",
	"draw_text": "Draw Text Overlay",
	"remove_text": "Remove Text Overlay (id)",
	"clear_texts": "Clear All Text Overlays",
	"disable_block": "Disable Block (grid x,y)",
	"enable_block": "Enable Block (grid x,y)",
	"spawn_unit": "Spawn Unit",
	"hide_region": "Hide Region",
	"reveal_region": "Reveal Region",
	"capture_sector": "Capture Sector",
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
	_refresh_step_list()


func hide_panel() -> void:
	visible = false


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

	# Title
	var title = Label.new()
	title.text = "Sector Script"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	root_vbox.add_child(title)

	var sep = HSeparator.new()
	root_vbox.add_child(sep)

	# Horizontal split: step list on left, step detail on right
	var hbox_split = HBoxContainer.new()
	hbox_split.add_theme_constant_override("separation", 8)
	hbox_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(hbox_split)

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
		step["actions"].append({"type": "pause"})
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
		step["on_exit"].append({"type": "unpause"})
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
	input.text_changed.connect(func(t: String): data[key] = t)
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
	text_edit.text_changed.connect(func(): data[key] = text_edit.text)
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
	spin.value_changed.connect(func(v: float): data[key] = int(v))
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
	spin.value_changed.connect(func(v: float): data[key] = v)
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
	option.item_selected.connect(func(idx: int): data["color"] = color_names[idx])
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
	option.item_selected.connect(func(idx: int): data["item_id"] = item_ids[idx])
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
	option.item_selected.connect(func(idx: int): data["block_id"] = block_ids[idx])
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
	option.item_selected.connect(func(idx: int): data["unit_id"] = unit_ids[idx])
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
	option.item_selected.connect(func(idx: int): data["faction"] = factions[idx])
	hbox.add_child(option)


func _add_checkbox(parent: Control, data: Dictionary, key: String, label_text: String) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	parent.add_child(hbox)

	var check = CheckBox.new()
	check.text = label_text
	check.add_theme_font_size_override("font_size", 11)
	check.button_pressed = bool(data.get(key, false))
	check.toggled.connect(func(pressed: bool): data[key] = pressed)
	hbox.add_child(check)


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
