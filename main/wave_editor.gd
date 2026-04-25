extends CanvasLayer

# ============================================================
# WAVE_EDITOR.GD — Map-editor panel for authoring enemy waves.
# ============================================================
# Centered modal over a tinted backdrop. Left half authors the
# wave bundle (global schedule, spawn points, per-unit rules
# or manual waves). Right half plots wave-by-wave unit counts
# on a scrollable graph with a legend underneath.
# ============================================================


var main: Node2D = null

# --- ROOT UI ---
var _backdrop: ColorRect = null
var _root: Control = null
var _panel: PanelContainer = null

# --- LEFT PANEL HOOKS ---
var _general_vbox: VBoxContainer = null
var _spawns_vbox: VBoxContainer = null
var _mode_tab_container: TabContainer = null
var _manual_list: VBoxContainer = null
var _auto_list: VBoxContainer = null

# --- GRAPH HOOKS ---
var _graph: Control = null
var _legend_scroll: ScrollContainer = null
var _legend_hbox: HBoxContainer = null

# --- GRAPH STATE ---
var _graph_offset: Vector2 = Vector2.ZERO  # pan (world pixels)
const GRAPH_CELL_W := 36.0
const GRAPH_CELL_H := 18.0
const GRAPH_PAD := 24.0

const START_MODES := [
	{"id": "landing", "label": "Start on map landing"},
	{"id": "script", "label": "Start when sector script calls start_waves"},
]
const GEN_MODES := [
	{"id": "manual", "label": "Manual — author each wave yourself"},
	{"id": "auto", "label": "Auto — generate waves from per-unit rules"},
]


func _ready() -> void:
	await get_tree().process_frame
	main = get_node_or_null("/root/Main")
	layer = 50
	_build_ui()
	visible = false


func show_panel() -> void:
	visible = true
	_refresh_all()


func hide_panel() -> void:
	visible = false


# =========================
# UI CONSTRUCTION
# =========================

func _build_ui() -> void:
	# Backdrop: tinted black ColorRect covering the viewport. Eats
	# mouse input so clicks outside the panel don't leak through to
	# the map editor underneath.
	_backdrop = ColorRect.new()
	_backdrop.color = Color(0, 0, 0, 0.6)
	_backdrop.anchor_right = 1.0
	_backdrop.anchor_bottom = 1.0
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_backdrop)

	# Root centered container
	_root = Control.new()
	_root.anchor_left = 0.5
	_root.anchor_right = 0.5
	_root.anchor_top = 0.5
	_root.anchor_bottom = 0.5
	_root.offset_left = -520
	_root.offset_right = 520
	_root.offset_top = -320
	_root.offset_bottom = 320
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	_panel = PanelContainer.new()
	_panel.anchor_right = 1.0
	_panel.anchor_bottom = 1.0
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.08, 0.08, 0.1, 0.98)
	st.border_color = Color(0.45, 0.45, 0.55)
	st.set_border_width_all(1)
	st.set_corner_radius_all(8)
	_panel.add_theme_stylebox_override("panel", st)
	_root.add_child(_panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	_panel.add_child(outer)

	# Header row: title + close button
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "Waves"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(1.0, 0.84, 0.0))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size.x = 28
	close_btn.pressed.connect(_on_close)
	header.add_child(close_btn)
	outer.add_child(header)

	# Body: left column (settings) | right column (graph + legend)
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(body)

	var left := _build_left_column()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.0
	body.add_child(left)

	var right := _build_right_column()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.2
	body.add_child(right)


func _build_left_column() -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)

	# --- General section ---
	_add_section_label(vb, "General")
	_general_vbox = VBoxContainer.new()
	_general_vbox.add_theme_constant_override("separation", 4)
	vb.add_child(_general_vbox)

	# --- Spawn points section ---
	_add_section_label(vb, "Spawn Points")
	_spawns_vbox = VBoxContainer.new()
	_spawns_vbox.add_theme_constant_override("separation", 4)
	vb.add_child(_spawns_vbox)
	var add_sp_btn := Button.new()
	add_sp_btn.text = "+ Add Spawn Point"
	add_sp_btn.pressed.connect(_on_add_spawn_point)
	vb.add_child(add_sp_btn)

	# --- Mode tabs (manual vs auto) ---
	_add_section_label(vb, "Waves")
	_mode_tab_container = TabContainer.new()
	_mode_tab_container.custom_minimum_size.y = 260
	vb.add_child(_mode_tab_container)

	var manual_scroll := ScrollContainer.new()
	manual_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	manual_scroll.name = "Manual"
	_manual_list = VBoxContainer.new()
	_manual_list.add_theme_constant_override("separation", 4)
	_manual_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	manual_scroll.add_child(_manual_list)
	_mode_tab_container.add_child(manual_scroll)

	var auto_scroll := ScrollContainer.new()
	auto_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	auto_scroll.name = "Auto"
	_auto_list = VBoxContainer.new()
	_auto_list.add_theme_constant_override("separation", 4)
	_auto_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	auto_scroll.add_child(_auto_list)
	_mode_tab_container.add_child(auto_scroll)

	_mode_tab_container.tab_changed.connect(_on_tab_changed)
	return scroll


func _build_right_column() -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_add_section_label(vb, "Wave Preview")

	# Graph drawing area
	_graph = Control.new()
	_graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph.clip_contents = true
	_graph.draw.connect(_draw_graph)
	_graph.gui_input.connect(_on_graph_input)
	vb.add_child(_graph)

	# Legend (horizontal scroll if many units)
	_legend_scroll = ScrollContainer.new()
	_legend_scroll.custom_minimum_size.y = 32
	_legend_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_legend_hbox = HBoxContainer.new()
	_legend_hbox.add_theme_constant_override("separation", 12)
	_legend_scroll.add_child(_legend_hbox)
	vb.add_child(_legend_scroll)

	return vb


func _add_section_label(parent: Control, txt: String) -> void:
	var l := Label.new()
	l.text = txt
	l.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	l.add_theme_font_size_override("font_size", 13)
	parent.add_child(l)


# =========================
# REFRESH
# =========================

func _refresh_all() -> void:
	_refresh_general()
	_refresh_spawns()
	_refresh_manual_waves()
	_refresh_auto_templates()
	_sync_tab_from_config()
	if _graph:
		_graph.queue_redraw()
	_refresh_legend()


func _sync_tab_from_config() -> void:
	if _mode_tab_container == null or main == null:
		return
	var mode: String = String(main.editor_wave_config.get("generation_mode", "manual"))
	_mode_tab_container.current_tab = 0 if mode == "manual" else 1


func _on_tab_changed(tab: int) -> void:
	if main == null:
		return
	main.editor_wave_config["generation_mode"] = "manual" if tab == 0 else "auto"
	_graph.queue_redraw()
	_refresh_legend()


# --- GENERAL ---

func _refresh_general() -> void:
	for c in _general_vbox.get_children():
		c.queue_free()
	if main == null:
		return
	var cfg: Dictionary = main.editor_wave_config

	# Start mode dropdown
	var sm_row := HBoxContainer.new()
	sm_row.add_theme_constant_override("separation", 6)
	var sm_lbl := Label.new()
	sm_lbl.text = "Start:"
	sm_lbl.custom_minimum_size.x = 120
	sm_row.add_child(sm_lbl)
	var sm_opt := OptionButton.new()
	sm_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cur_sm: String = String(cfg.get("start_mode", "landing"))
	for i in range(START_MODES.size()):
		sm_opt.add_item(START_MODES[i]["label"], i)
		if START_MODES[i]["id"] == cur_sm:
			sm_opt.selected = i
	sm_opt.item_selected.connect(func(i):
		main.editor_wave_config["start_mode"] = START_MODES[i]["id"])
	sm_row.add_child(sm_opt)
	_general_vbox.add_child(sm_row)

	_add_float_field(_general_vbox, cfg, "initial_delay", "Delay before wave 1 (s):", 0.0, 3600.0, 0.5)
	_add_float_field(_general_vbox, cfg, "interval", "Time between waves (s):", 0.0, 3600.0, 0.5)


func _add_float_field(parent: Control, target: Dictionary, key: String,
		label: String, lo: float, hi: float, step: float) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 180
	row.add_child(l)
	var sb := SpinBox.new()
	sb.min_value = lo
	sb.max_value = hi
	sb.step = step
	sb.value = float(target.get(key, 0.0))
	sb.value_changed.connect(func(v): target[key] = float(v))
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(sb)
	parent.add_child(row)


# --- SPAWN POINTS ---

func _refresh_spawns() -> void:
	for c in _spawns_vbox.get_children():
		c.queue_free()
	if main == null:
		return
	for i in range(main.editor_wave_spawns.size()):
		_spawns_vbox.add_child(_build_spawn_row(i))


func _build_spawn_row(idx: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var sp: Dictionary = main.editor_wave_spawns[idx]

	var name_edit := LineEdit.new()
	name_edit.text = String(sp.get("name", ""))
	name_edit.placeholder_text = "name"
	name_edit.custom_minimum_size.x = 100
	name_edit.text_changed.connect(func(t):
		main.editor_wave_spawns[idx]["name"] = t
		_refresh_manual_waves()
		_refresh_auto_templates())
	row.add_child(name_edit)

	var cell: Vector2i = _coerce_cell(sp.get("cell", Vector2i.ZERO))
	var x_spin := SpinBox.new()
	x_spin.min_value = 0
	x_spin.max_value = 9999
	x_spin.step = 1
	x_spin.value = cell.x
	x_spin.custom_minimum_size.x = 70
	x_spin.value_changed.connect(func(v):
		var c = _coerce_cell(main.editor_wave_spawns[idx].get("cell", Vector2i.ZERO))
		c.x = int(v)
		main.editor_wave_spawns[idx]["cell"] = c)
	row.add_child(x_spin)
	var y_spin := SpinBox.new()
	y_spin.min_value = 0
	y_spin.max_value = 9999
	y_spin.step = 1
	y_spin.value = cell.y
	y_spin.custom_minimum_size.x = 70
	y_spin.value_changed.connect(func(v):
		var c = _coerce_cell(main.editor_wave_spawns[idx].get("cell", Vector2i.ZERO))
		c.y = int(v)
		main.editor_wave_spawns[idx]["cell"] = c)
	row.add_child(y_spin)

	var rm := Button.new()
	rm.text = "✕"
	rm.custom_minimum_size.x = 28
	rm.pressed.connect(_on_remove_spawn_point.bind(idx))
	row.add_child(rm)
	return row


func _on_add_spawn_point() -> void:
	if main == null:
		return
	main.editor_wave_spawns.append({
		"name": "spawn_%d" % (main.editor_wave_spawns.size() + 1),
		"cell": Vector2i.ZERO,
	})
	_refresh_spawns()


func _on_remove_spawn_point(idx: int) -> void:
	if main == null or idx < 0 or idx >= main.editor_wave_spawns.size():
		return
	main.editor_wave_spawns.remove_at(idx)
	_refresh_spawns()
	_refresh_manual_waves()
	_refresh_auto_templates()


# --- MANUAL WAVES ---

func _refresh_manual_waves() -> void:
	for c in _manual_list.get_children():
		c.queue_free()
	if main == null:
		return
	for i in range(main.editor_waves.size()):
		_manual_list.add_child(_build_manual_wave_row(i))
	var add_btn := Button.new()
	add_btn.text = "+ Add Wave"
	add_btn.pressed.connect(_on_add_manual_wave)
	_manual_list.add_child(add_btn)


func _build_manual_wave_row(idx: int) -> Control:
	var row := PanelContainer.new()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	row.add_child(vb)
	var header := HBoxContainer.new()
	var l := Label.new()
	l.text = "Wave %d" % (idx + 1)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(l)
	var rm := Button.new()
	rm.text = "✕"
	rm.custom_minimum_size.x = 24
	rm.pressed.connect(_on_remove_manual_wave.bind(idx))
	header.add_child(rm)
	vb.add_child(header)
	var units: Array = main.editor_waves[idx].get("units", [])
	for ui in range(units.size()):
		vb.add_child(_build_manual_unit_row(idx, ui))
	var add_unit := Button.new()
	add_unit.text = "+ Unit"
	add_unit.pressed.connect(_on_add_manual_unit.bind(idx))
	vb.add_child(add_unit)
	return row


func _build_manual_unit_row(wave_idx: int, unit_idx: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var entry: Dictionary = main.editor_waves[wave_idx]["units"][unit_idx]

	var unit_opt := OptionButton.new()
	_populate_unit_option(unit_opt, StringName(entry.get("unit_id", &"")))
	unit_opt.item_selected.connect(func(i):
		main.editor_waves[wave_idx]["units"][unit_idx]["unit_id"] = StringName(unit_opt.get_item_metadata(i))
		_graph.queue_redraw()
		_refresh_legend())
	unit_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(unit_opt)

	var count_spin := SpinBox.new()
	count_spin.min_value = 1
	count_spin.max_value = 999
	count_spin.step = 1
	count_spin.value = int(entry.get("count", 1))
	count_spin.custom_minimum_size.x = 60
	count_spin.value_changed.connect(func(v):
		main.editor_waves[wave_idx]["units"][unit_idx]["count"] = int(v)
		_graph.queue_redraw())
	row.add_child(count_spin)

	var sp_opt := OptionButton.new()
	_populate_spawn_option(sp_opt, String(entry.get("spawn_point", "")))
	sp_opt.item_selected.connect(func(i):
		main.editor_waves[wave_idx]["units"][unit_idx]["spawn_point"] = sp_opt.get_item_text(i))
	sp_opt.custom_minimum_size.x = 90
	row.add_child(sp_opt)

	var rm := Button.new()
	rm.text = "✕"
	rm.custom_minimum_size.x = 24
	rm.pressed.connect(_on_remove_manual_unit.bind(wave_idx, unit_idx))
	row.add_child(rm)
	return row


func _on_add_manual_wave() -> void:
	if main == null:
		return
	main.editor_waves.append({"units": []})
	_refresh_manual_waves()
	_graph.queue_redraw()


func _on_remove_manual_wave(idx: int) -> void:
	if main == null or idx < 0 or idx >= main.editor_waves.size():
		return
	main.editor_waves.remove_at(idx)
	_refresh_manual_waves()
	_graph.queue_redraw()


func _on_add_manual_unit(wave_idx: int) -> void:
	if main == null:
		return
	var first_uid: StringName = &""
	if not Registry.units_list.is_empty():
		first_uid = Registry.units_list[0].id
	main.editor_waves[wave_idx]["units"].append({
		"unit_id": first_uid,
		"count": 1,
		"spawn_point": _default_spawn_name(),
	})
	_refresh_manual_waves()
	_graph.queue_redraw()
	_refresh_legend()


func _on_remove_manual_unit(wave_idx: int, unit_idx: int) -> void:
	if main == null:
		return
	var units: Array = main.editor_waves[wave_idx].get("units", [])
	if unit_idx < 0 or unit_idx >= units.size():
		return
	units.remove_at(unit_idx)
	_refresh_manual_waves()
	_graph.queue_redraw()
	_refresh_legend()


# --- AUTO TEMPLATES ---

func _refresh_auto_templates() -> void:
	for c in _auto_list.get_children():
		c.queue_free()
	if main == null:
		return
	var cfg: Dictionary = main.editor_wave_config

	# Wave count (0 = infinite, only stoppable via sector scripting)
	var wc_row := HBoxContainer.new()
	wc_row.add_theme_constant_override("separation", 6)
	var wc_lbl := Label.new()
	wc_lbl.text = "Number of waves (0 = infinite):"
	wc_lbl.custom_minimum_size.x = 220
	wc_row.add_child(wc_lbl)
	var wc_spin := SpinBox.new()
	wc_spin.min_value = 0
	wc_spin.max_value = 9999
	wc_spin.step = 1
	wc_spin.value = int(cfg.get("auto_wave_count", 10))
	wc_spin.value_changed.connect(func(v):
		main.editor_wave_config["auto_wave_count"] = int(v)
		_graph.queue_redraw())
	wc_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wc_row.add_child(wc_spin)
	_auto_list.add_child(wc_row)

	var templates: Array = cfg.get("auto_unit_templates", [])
	for i in range(templates.size()):
		_auto_list.add_child(_build_auto_template_row(i))
	var add_btn := Button.new()
	add_btn.text = "+ Add Unit Rule"
	add_btn.pressed.connect(_on_add_auto_template)
	_auto_list.add_child(add_btn)


func _build_auto_template_row(idx: int) -> Control:
	var row := PanelContainer.new()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 3)
	row.add_child(vb)

	var t: Dictionary = main.editor_wave_config["auto_unit_templates"][idx]

	# Unit + spawn point + remove button header
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	var unit_opt := OptionButton.new()
	_populate_unit_option(unit_opt, StringName(t.get("unit_id", &"")))
	unit_opt.item_selected.connect(func(i):
		main.editor_wave_config["auto_unit_templates"][idx]["unit_id"] = StringName(unit_opt.get_item_metadata(i))
		_graph.queue_redraw()
		_refresh_legend())
	unit_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(unit_opt)

	var sp_opt := OptionButton.new()
	_populate_spawn_option(sp_opt, String(t.get("spawn_point", "")))
	sp_opt.item_selected.connect(func(i):
		main.editor_wave_config["auto_unit_templates"][idx]["spawn_point"] = sp_opt.get_item_text(i))
	sp_opt.custom_minimum_size.x = 90
	header.add_child(sp_opt)

	var rm := Button.new()
	rm.text = "✕"
	rm.custom_minimum_size.x = 24
	rm.pressed.connect(_on_remove_auto_template.bind(idx))
	header.add_child(rm)
	vb.add_child(header)

	# Wave range: first..last
	vb.add_child(_build_int_range_row("Waves", t, "first_wave", "last_wave", idx))
	# Count range: min..max per wave
	vb.add_child(_build_int_range_row("Per wave", t, "min_per_wave", "max_per_wave", idx))
	# Likelyness multiplier — 0.1..2.0 with 1.0 = neutral.
	vb.add_child(_build_likelyness_row(t, idx))
	# Increase curve — 5 draggable sample points from wave 1 → last_wave.
	vb.add_child(_build_curve_row(t, idx))
	return row


func _build_likelyness_row(target: Dictionary, tpl_idx: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var l := Label.new()
	l.text = "Likelyness:"
	l.custom_minimum_size.x = 80
	row.add_child(l)
	var sb := SpinBox.new()
	sb.min_value = 0.1
	sb.max_value = 2.0
	sb.step = 0.05
	sb.value = float(target.get("likelyness", 1.0))
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb.value_changed.connect(func(v):
		main.editor_wave_config["auto_unit_templates"][tpl_idx]["likelyness"] = float(v)
		_graph.queue_redraw())
	row.add_child(sb)
	return row


const CURVE_POINT_COUNT := 5
const CURVE_MIN_Y := 0.0
const CURVE_MAX_Y := 2.0


func _ensure_curve_points(target: Dictionary) -> Array:
	var pts: Array = target.get("curve_points", [])
	if pts.size() != CURVE_POINT_COUNT:
		pts = []
		for i in range(CURVE_POINT_COUNT):
			pts.append(1.0)
		target["curve_points"] = pts
	return pts


func _build_curve_row(target: Dictionary, tpl_idx: int) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var l := Label.new()
	l.text = "Increase Curve (wave 1 → last):"
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.75, 0.75, 0.85))
	row.add_child(l)

	_ensure_curve_points(target)

	var widget := Control.new()
	widget.custom_minimum_size = Vector2(220, 60)
	widget.set_meta("tpl_idx", tpl_idx)
	widget.set_meta("dragging_index", -1)
	widget.draw.connect(_draw_curve_widget.bind(widget))
	widget.gui_input.connect(_on_curve_widget_input.bind(widget))
	row.add_child(widget)
	return row


func _draw_curve_widget(widget: Control) -> void:
	var tpl_idx: int = int(widget.get_meta("tpl_idx", -1))
	if tpl_idx < 0 or main == null:
		return
	var templates: Array = main.editor_wave_config.get("auto_unit_templates", [])
	if tpl_idx >= templates.size():
		return
	var pts_raw: Array = _ensure_curve_points(templates[tpl_idx])
	var size := widget.size

	widget.draw_rect(Rect2(Vector2.ZERO, size), Color(0.10, 0.10, 0.13, 1.0), true)
	widget.draw_rect(Rect2(Vector2.ZERO, size), Color(0.3, 0.3, 0.4), false, 1.0)

	# Reference line at y = 1.0 (no scaling).
	var y_at_1: float = _curve_y_to_pixel(1.0, size)
	widget.draw_line(Vector2(0, y_at_1), Vector2(size.x, y_at_1),
		Color(0.45, 0.45, 0.55, 0.8), 1.0)

	# Connect points with a polyline and dot each one.
	var screen_pts := PackedVector2Array()
	for i in range(pts_raw.size()):
		var p: Vector2 = _curve_point_to_pixel(i, float(pts_raw[i]), size, pts_raw.size())
		screen_pts.append(p)
	for i in range(screen_pts.size() - 1):
		widget.draw_line(screen_pts[i], screen_pts[i + 1],
			Color(0.4, 0.8, 1.0), 2.0)
	for i in range(screen_pts.size()):
		widget.draw_circle(screen_pts[i], 4.0, Color(0.2, 0.6, 1.0))
		widget.draw_circle(screen_pts[i], 3.0, Color.WHITE)


func _curve_y_to_pixel(y_val: float, size: Vector2) -> float:
	var margin := 6.0
	var h := size.y - margin * 2.0
	var t: float = clampf((y_val - CURVE_MIN_Y) / maxf(CURVE_MAX_Y - CURVE_MIN_Y, 0.001), 0.0, 1.0)
	return margin + (1.0 - t) * h


func _curve_pixel_to_y(py: float, size: Vector2) -> float:
	var margin := 6.0
	var h := size.y - margin * 2.0
	var t: float = clampf((py - margin) / maxf(h, 0.001), 0.0, 1.0)
	return CURVE_MIN_Y + (1.0 - t) * (CURVE_MAX_Y - CURVE_MIN_Y)


func _curve_point_to_pixel(i: int, y_val: float, size: Vector2, count: int) -> Vector2:
	var margin := 6.0
	var w := size.x - margin * 2.0
	var x: float = margin + (float(i) / float(maxi(count - 1, 1))) * w
	return Vector2(x, _curve_y_to_pixel(y_val, size))


func _on_curve_widget_input(ev: InputEvent, widget: Control) -> void:
	var tpl_idx: int = int(widget.get_meta("tpl_idx", -1))
	if tpl_idx < 0 or main == null:
		return
	var templates: Array = main.editor_wave_config.get("auto_unit_templates", [])
	if tpl_idx >= templates.size():
		return
	var pts: Array = _ensure_curve_points(templates[tpl_idx])
	var size := widget.size

	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				# Grab the closest control-point to the click.
				var best := -1
				var best_dist := INF
				for i in range(pts.size()):
					var screen := _curve_point_to_pixel(i, float(pts[i]), size, pts.size())
					var d: float = mb.position.distance_to(screen)
					if d < best_dist:
						best_dist = d
						best = i
				widget.set_meta("dragging_index", best)
			else:
				widget.set_meta("dragging_index", -1)
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		var drag: int = int(widget.get_meta("dragging_index", -1))
		if drag >= 0 and drag < pts.size():
			pts[drag] = _curve_pixel_to_y(mm.position.y, size)
			templates[tpl_idx]["curve_points"] = pts
			widget.queue_redraw()
			_graph.queue_redraw()


func _build_int_range_row(label: String, target: Dictionary,
		lo_key: String, hi_key: String, tpl_idx: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var l := Label.new()
	l.text = label + ":"
	l.custom_minimum_size.x = 80
	row.add_child(l)
	var lo_spin := SpinBox.new()
	lo_spin.min_value = 0
	lo_spin.max_value = 9999
	lo_spin.step = 1
	lo_spin.value = int(target.get(lo_key, 1))
	lo_spin.value_changed.connect(func(v):
		main.editor_wave_config["auto_unit_templates"][tpl_idx][lo_key] = int(v)
		_graph.queue_redraw())
	row.add_child(lo_spin)
	var sep := Label.new()
	sep.text = "→"
	row.add_child(sep)
	var hi_spin := SpinBox.new()
	hi_spin.min_value = 0
	hi_spin.max_value = 9999
	hi_spin.step = 1
	hi_spin.value = int(target.get(hi_key, 1))
	hi_spin.value_changed.connect(func(v):
		main.editor_wave_config["auto_unit_templates"][tpl_idx][hi_key] = int(v)
		_graph.queue_redraw())
	row.add_child(hi_spin)
	return row


func _on_add_auto_template() -> void:
	if main == null:
		return
	var first_uid: StringName = &""
	if not Registry.units_list.is_empty():
		first_uid = Registry.units_list[0].id
	var wave_count: int = int(main.editor_wave_config.get("auto_wave_count", 10))
	main.editor_wave_config["auto_unit_templates"].append({
		"unit_id": first_uid,
		"spawn_point": _default_spawn_name(),
		"first_wave": 1,
		"last_wave": max(1, wave_count),
		"min_per_wave": 1,
		"max_per_wave": 3,
		"likelyness": 1.0,
		"curve_points": [1.0, 1.0, 1.0, 1.0, 1.0],
	})
	_refresh_auto_templates()
	_graph.queue_redraw()
	_refresh_legend()


func _on_remove_auto_template(idx: int) -> void:
	if main == null:
		return
	var templates: Array = main.editor_wave_config.get("auto_unit_templates", [])
	if idx < 0 or idx >= templates.size():
		return
	templates.remove_at(idx)
	_refresh_auto_templates()
	_graph.queue_redraw()
	_refresh_legend()


# =========================
# OPTION-BUTTON HELPERS
# =========================

func _populate_unit_option(opt: OptionButton, current: StringName) -> void:
	opt.clear()
	var sel := -1
	var i := 0
	for u in Registry.units_list:
		opt.add_item(u.display_name, i)
		opt.set_item_metadata(i, u.id)
		if u.id == current:
			sel = i
		i += 1
	if sel >= 0:
		opt.selected = sel


func _populate_spawn_option(opt: OptionButton, current: String) -> void:
	opt.clear()
	var sel := -1
	var i := 0
	if main == null:
		opt.add_item("(no spawns)")
		opt.disabled = true
		return
	opt.disabled = false
	for sp in main.editor_wave_spawns:
		var nm := String(sp.get("name", ""))
		opt.add_item(nm, i)
		if nm == current:
			sel = i
		i += 1
	if i == 0:
		opt.add_item("(no spawns)")
		opt.disabled = true
	elif sel >= 0:
		opt.selected = sel


func _default_spawn_name() -> String:
	if main != null and not main.editor_wave_spawns.is_empty():
		return String(main.editor_wave_spawns[0].get("name", ""))
	return ""


# =========================
# GRAPH
# =========================

## Expands the current config into a preview wave list (capped for
## display) using the same rules as the runtime expander.
func _preview_waves() -> Array:
	if main == null:
		return []
	var mode: String = String(main.editor_wave_config.get("generation_mode", "manual"))
	if mode == "manual":
		return main.editor_waves
	# auto
	var cfg: Dictionary = main.editor_wave_config.duplicate()
	if int(cfg.get("auto_wave_count", 10)) <= 0:
		# Infinite auto — preview first 24 generated waves so the graph
		# stays bounded in the editor. Runtime isn't limited.
		cfg["auto_wave_count"] = 24
	var wm = preload("res://main/wave_manager.gd")
	return wm.build_auto_waves(cfg)


func _unit_colors() -> Dictionary:
	# Deterministic color per unit id — cycles through a preset palette
	# so the same unit keeps the same line color across refreshes.
	var palette: Array[Color] = [
		Color(0.90, 0.32, 0.32),
		Color(0.30, 0.85, 0.45),
		Color(0.30, 0.60, 0.98),
		Color(0.98, 0.75, 0.24),
		Color(0.78, 0.38, 0.98),
		Color(0.25, 0.90, 0.86),
		Color(0.98, 0.52, 0.30),
		Color(0.60, 0.85, 0.30),
	]
	var colors: Dictionary = {}
	var i := 0
	for uid in _collect_unit_ids():
		colors[uid] = palette[i % palette.size()]
		i += 1
	return colors


func _collect_unit_ids() -> Array:
	var seen: Dictionary = {}
	var ids: Array = []
	var waves := _preview_waves()
	for w in waves:
		for u in w.get("units", []):
			var uid: StringName = StringName(u.get("unit_id", &""))
			if uid == &"":
				continue
			if not seen.has(uid):
				seen[uid] = true
				ids.append(uid)
	return ids


func _refresh_legend() -> void:
	for c in _legend_hbox.get_children():
		c.queue_free()
	var colors := _unit_colors()
	for uid in _collect_unit_ids():
		var entry := HBoxContainer.new()
		entry.add_theme_constant_override("separation", 4)
		var swatch := ColorRect.new()
		swatch.color = colors[uid]
		swatch.custom_minimum_size = Vector2(16, 16)
		entry.add_child(swatch)
		var name_lbl := Label.new()
		var ud = Registry.get_unit(uid)
		name_lbl.text = ud.display_name if ud else String(uid)
		entry.add_child(name_lbl)
		_legend_hbox.add_child(entry)


func _draw_graph() -> void:
	if _graph == null:
		return
	var size := _graph.size
	# Background + border
	_graph.draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.05, 0.07, 1.0), true)
	_graph.draw_rect(Rect2(Vector2.ZERO, size), Color(0.3, 0.3, 0.4), false, 1.0)

	var waves := _preview_waves()
	if waves.is_empty():
		var font := ThemeDB.fallback_font
		_graph.draw_string(font, Vector2(12, 24),
			"(configure waves to see a preview)",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.6, 0.6, 0.7))
		return

	# Compute per-unit per-wave counts
	var per_unit: Dictionary = {}   # uid -> Array[int]
	for uid in _collect_unit_ids():
		per_unit[uid] = []
		for _w in waves:
			per_unit[uid].append(0)
	for w_i in range(waves.size()):
		for u in waves[w_i].get("units", []):
			var uid: StringName = StringName(u.get("unit_id", &""))
			if per_unit.has(uid):
				per_unit[uid][w_i] += int(u.get("count", 1))

	# Determine max count for Y scale
	var max_count := 1
	for uid in per_unit:
		for c in per_unit[uid]:
			if c > max_count:
				max_count = c

	# Graph area (padded inside the control)
	var inner_origin := Vector2(GRAPH_PAD, GRAPH_PAD) - _graph_offset
	var inner_size := Vector2(
		maxf(size.x - GRAPH_PAD * 2.0, float(waves.size()) * GRAPH_CELL_W),
		maxf(size.y - GRAPH_PAD * 2.0, float(max_count) * GRAPH_CELL_H),
	)

	# Gridlines (every wave along X, every integer count along Y up to max)
	var gx := inner_origin.x
	for w_i in range(waves.size() + 1):
		var x := inner_origin.x + float(w_i) * GRAPH_CELL_W
		_graph.draw_line(Vector2(x, inner_origin.y),
			Vector2(x, inner_origin.y + inner_size.y),
			Color(0.2, 0.2, 0.3), 1.0)
	for yv in range(max_count + 1):
		var y := inner_origin.y + inner_size.y - float(yv) * GRAPH_CELL_H
		_graph.draw_line(Vector2(inner_origin.x, y),
			Vector2(inner_origin.x + inner_size.x, y),
			Color(0.2, 0.2, 0.3), 1.0)

	# Axis labels (wave numbers along bottom, counts along left)
	var font := ThemeDB.fallback_font
	var font_sz := 10
	for w_i in range(waves.size()):
		var lbl_x := inner_origin.x + float(w_i) * GRAPH_CELL_W + GRAPH_CELL_W * 0.5 - 6.0
		var lbl_y := inner_origin.y + inner_size.y + 14.0
		_graph.draw_string(font, Vector2(lbl_x, lbl_y), str(w_i + 1),
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, Color(0.75, 0.75, 0.85))
	for yv in range(max_count + 1):
		var y := inner_origin.y + inner_size.y - float(yv) * GRAPH_CELL_H
		_graph.draw_string(font, Vector2(4.0, y + 3.0), str(yv),
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz, Color(0.75, 0.75, 0.85))

	# Lines per unit
	var colors := _unit_colors()
	for uid in per_unit:
		var col: Color = colors.get(uid, Color.WHITE)
		var counts: Array = per_unit[uid]
		var pts := PackedVector2Array()
		for w_i in range(counts.size()):
			var x := inner_origin.x + float(w_i) * GRAPH_CELL_W + GRAPH_CELL_W * 0.5
			var y := inner_origin.y + inner_size.y - float(counts[w_i]) * GRAPH_CELL_H
			pts.append(Vector2(x, y))
		for i in range(pts.size() - 1):
			_graph.draw_line(pts[i], pts[i + 1], col, 2.0)
		for p in pts:
			_graph.draw_circle(p, 3.0, col)


func _on_graph_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed:
		var mb := ev as InputEventMouseButton
		# Shift+wheel = horizontal pan; plain wheel = vertical pan.
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.shift_pressed:
					_graph_offset.x = maxf(_graph_offset.x - 40.0, 0.0)
				else:
					_graph_offset.y = maxf(_graph_offset.y - 20.0, 0.0)
				_graph.queue_redraw()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.shift_pressed:
					_graph_offset.x += 40.0
				else:
					# Down only allowed after panning up — mirror the ask.
					if _graph_offset.y > 0.0:
						_graph_offset.y += 20.0
						_graph_offset.y = minf(_graph_offset.y, 400.0)
				_graph.queue_redraw()


# =========================
# UTILITIES
# =========================

func _coerce_cell(raw) -> Vector2i:
	if raw is Vector2i:
		return raw
	if raw is String:
		var parts: PackedStringArray = (raw as String).split(",")
		if parts.size() >= 2:
			return Vector2i(int(parts[0]), int(parts[1]))
	return Vector2i.ZERO


func _on_close() -> void:
	hide_panel()
	# Flip the editor_hud toggle button back off.
	var hud = get_parent()
	if hud and "wave_editor_btn" in hud and hud.wave_editor_btn:
		hud.wave_editor_btn.set_pressed_no_signal(false)
