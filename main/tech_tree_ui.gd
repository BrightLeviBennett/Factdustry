extends CanvasLayer

# ============================================================
# TECH_TREE_UI.GD - Unified Visual Tech Tree Viewer
# ============================================================
# Reads hardcoded grid positions from TechTree node data.
# No auto-layout — positions come from tech_tree.gd.
# Grid coords are multiplied by CELL_W / CELL_H to get pixels.
#
# SETUP: Add as a CanvasLayer child of Main named "TechTreeUI"
# ============================================================

var main: Node2D
var is_open := false
var hovered_node_id: StringName = &""
# Set true while the cursor is physically inside `tooltip_panel`.
# Used to keep the tooltip open even after the cursor leaves the
# tree node, so the "i" info button is actually reachable.
var _mouse_over_tooltip: bool = false

# Shared lock texture rendered over LOCKED nodes (replaces the emoji).
var _lock_icon: Texture2D = preload("res://textures/UI/LockIcon.png")

var root_panel: PanelContainer
var tree_scroll: ScrollContainer
var tree_canvas: Control
var tooltip_panel: PanelContainer
var tooltip_vbox: VBoxContainer
var resource_panel: PanelContainer
var resource_vbox: VBoxContainer

# Pixel positions computed from grid coords
var node_positions: Dictionary = {}  # id → Vector2 (pixel center)
var canvas_size := Vector2.ZERO

var fallback_icon: Texture2D = preload("res://textures/TexNotFound.png")

# Zoom
var zoom_level := 1.0
const ZOOM_MIN := 0.25
const ZOOM_MAX := 2.0
const ZOOM_STEP := 0.1

# Node drawing size
const NODE_W := 45.0
const NODE_H := 45.0
# Grid cell size (pixels per grid unit)
const CELL_W := 65.0
const CELL_H := 65.0
const PADDING := 100.0

# --- COLORS ---
var bg_color := Color(0.04, 0.05, 0.07, 0.96)
var panel_color := Color(0.07, 0.09, 0.12, 0.95)
var text_color := Color(0.82, 0.88, 0.92)
var dim_color := Color(0.45, 0.52, 0.58)
var accent_color := Color(0.3, 0.75, 1.0)

var locked_outline := Color(0.85, 0.2, 0.2)
var unlocked_outline := Color(0.55, 0.58, 0.62)
var researched_outline := Color(0.95, 0.82, 0.2)
var locked_fill := Color(0.12, 0.08, 0.08)
var unlocked_fill := Color(0.1, 0.12, 0.15)
var researched_fill := Color(0.15, 0.14, 0.08)
var line_color := Color(0.3, 0.35, 0.4, 0.6)
var line_color_researched := Color(0.7, 0.65, 0.2, 0.5)


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if main == null:
		main = get_node_or_null("/root/Main")
	# `_show_ui()` may have already built the UI on demand if a caller
	# raced ahead of these awaits — skip the rebuild in that case so we
	# don't end up with two stacked root_panels.
	if root_panel == null:
		_build_ui()
		_hide_ui()
	if main and main.has_signal("resources_changed") \
			and not main.resources_changed.is_connected(_on_resources_changed):
		main.resources_changed.connect(_on_resources_changed)


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("open_tech_tree"):
		if is_open: _hide_ui()
		else: _show_ui()
	# WASD / arrow-key panning. Only ticks while the panel is visible
	# and the WASD-pan setting is on; uses the same `move_*` actions as
	# the in-world camera so the player's keybindings carry over.
	if is_open and wasd_pan and tree_scroll != null:
		var ax: float = Input.get_axis("move_left", "move_right")
		var ay: float = Input.get_axis("move_up", "move_down")
		if ax != 0.0 or ay != 0.0:
			var step: float = WASD_PAN_PIXELS_PER_SEC * delta
			tree_scroll.scroll_horizontal += int(ax * step)
			tree_scroll.scroll_vertical += int(ay * step)


var _tree_dragging := false
var _tree_drag_start := Vector2.ZERO

## Pan mode: false = click-and-drag the tree to move it, true = WASD/
## arrow keys scroll the viewport. Toggled from Settings → General.
## SettingsUI.apply_pending_settings writes this on launch and on
## change, so the tech tree picks the latest value up live.
var wasd_pan: bool = false
const WASD_PAN_PIXELS_PER_SEC: float = 900.0

func _input(event: InputEvent) -> void:
	if not is_open:
		return
	if event.is_action_pressed("ui_cancel"):
		_hide_ui()
		get_viewport().set_input_as_handled()
		return

	# Scroll wheel = zoom toward cursor (consume so game camera doesn't zoom)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			var local = event.position - tree_scroll.global_position + Vector2(tree_scroll.scroll_horizontal, tree_scroll.scroll_vertical)
			_zoom_at(local, ZOOM_STEP)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var local = event.position - tree_scroll.global_position + Vector2(tree_scroll.scroll_horizontal, tree_scroll.scroll_vertical)
			_zoom_at(local, -ZOOM_STEP)
			get_viewport().set_input_as_handled()

	# macOS trackpad pan gesture = zoom
	if event is InputEventPanGesture:
		var local = event.position - tree_scroll.global_position + Vector2(tree_scroll.scroll_horizontal, tree_scroll.scroll_vertical)
		if event.delta.y > 0:
			_zoom_at(local, -ZOOM_STEP * event.delta.y * 0.3)
		elif event.delta.y < 0:
			_zoom_at(local, ZOOM_STEP * absf(event.delta.y) * 0.3)
		get_viewport().set_input_as_handled()

	# Click+drag to pan — only active in drag mode. In WASD mode the
	# left button is left alone for node clicks / future selection.
	if not wasd_pan:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					_tree_dragging = true
					_tree_drag_start = event.position
				else:
					_tree_dragging = false
		if event is InputEventMouseMotion and _tree_dragging:
			tree_scroll.scroll_horizontal -= int(event.relative.x)
			tree_scroll.scroll_vertical -= int(event.relative.y)
			get_viewport().set_input_as_handled()


func _build_ui() -> void:
	root_panel = PanelContainer.new()
	root_panel.anchor_right = 1.0
	root_panel.anchor_bottom = 1.0
	root_panel.offset_left = 20; root_panel.offset_top = 20
	root_panel.offset_right = -20; root_panel.offset_bottom = -20
	root_panel.add_theme_stylebox_override("panel", _make_style(bg_color, 12))
	add_child(root_panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	root_panel.add_child(vbox)

	var tp = PanelContainer.new()
	tp.add_theme_stylebox_override("panel", _make_style(panel_color, 8))
	tp.custom_minimum_size.y = 44
	vbox.add_child(tp)
	var title = Label.new()
	title.text = "⬡  TECH TREE  ⬡"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", accent_color)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tp.add_child(title)

	tree_scroll = ScrollContainer.new()
	tree_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Disable built-in scroll — we handle zoom + click-drag panning manually
	tree_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	tree_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	vbox.add_child(tree_scroll)

	tree_canvas = Control.new()
	tree_canvas.mouse_filter = Control.MOUSE_FILTER_PASS
	tree_scroll.add_child(tree_canvas)
	tree_canvas.draw.connect(_on_tree_draw)
	tree_canvas.gui_input.connect(_on_tree_input)
	tree_canvas.mouse_exited.connect(_on_tree_mouse_exit)

	tooltip_panel = PanelContainer.new()
	tooltip_panel.add_theme_stylebox_override("panel", _make_style(Color(0.06, 0.08, 0.1, 0.97), 8))
	tooltip_panel.visible = false
	# STOP (not IGNORE) so the embedded "i" button can be clicked.
	# `_mouse_over_tooltip` + the hover gating below keeps the panel
	# visible while the cursor is inside it instead of snapping shut
	# the moment the cursor leaves the tree node.
	tooltip_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_panel.z_index = 100
	tooltip_panel.mouse_entered.connect(func():
		_mouse_over_tooltip = true)
	tooltip_panel.mouse_exited.connect(func():
		_mouse_over_tooltip = false
		_maybe_hide_tooltip())
	add_child(tooltip_panel)
	tooltip_vbox = VBoxContainer.new()
	tooltip_vbox.add_theme_constant_override("separation", 6)
	tooltip_panel.add_child(tooltip_vbox)
	
	_build_resource_panel()


# ============================================================
# LAYOUT — Just reads pos from each node and converts to pixels
# ============================================================

func _compute_layout() -> void:
	node_positions.clear()

	# Find grid bounds
	var min_col := 99999.0
	var max_col := -99999.0
	var min_row := 99999.0
	var max_row := -99999.0

	for nid in TechTree.nodes:
		if TechTree.nodes[nid].get("hidden", false):
			continue  # Skip hidden markers (-L-, -C-, -D-)
		var pos: Vector2 = TechTree.nodes[nid]["pos"]
		if pos.x < min_col: min_col = pos.x
		if pos.x > max_col: max_col = pos.x
		if pos.y < min_row: min_row = pos.y
		if pos.y > max_row: max_row = pos.y

	# Convert grid coords to pixel positions
	# x: column → pixel x (left to right)
	# y: row → pixel y (higher row = higher up = lower pixel y)
	for nid in TechTree.nodes:
		if TechTree.nodes[nid].get("hidden", false):
			continue
		var pos: Vector2 = TechTree.nodes[nid]["pos"]
		var px = PADDING + (pos.x - min_col) * CELL_W
		var py = PADDING + (max_row - pos.y) * CELL_H  # flip Y
		node_positions[nid] = Vector2(px, py)

	canvas_size = Vector2(
		PADDING * 2 + (max_col - min_col) * CELL_W,
		PADDING * 2 + (max_row - min_row) * CELL_H
	)
	tree_canvas.custom_minimum_size = canvas_size * zoom_level


# =========================
# DRAWING
# =========================

## Returns true if a node should be visible in the tech tree.
## Researched and unlocked nodes are always visible.
## Locked nodes are visible if at least one parent is unlocked or researched
## (so nodes waiting on dependencies still show next to completed parents).
func _is_node_visible(nid: StringName) -> bool:
	var state = TechTree.get_state(nid)
	if state != TechTree.NodeState.LOCKED:
		return true
	var node = TechTree.get_node_data(nid)
	if node == null:
		return false
	for pid in node["parents"]:
		var pstate = TechTree.get_state(pid)
		if pstate == TechTree.NodeState.UNLOCKED or pstate == TechTree.NodeState.RESEARCHED:
			return true
	return false


## Draws a U-shaped connection between two nodes that sit in the same row.
## The horizontal segment is routed through the gap immediately above or
## below the shared row, picked so it doesn't cross other visible nodes.
func _draw_same_row_connection(pp: Vector2, cp: Vector2, _nw: float, nh: float,
		child_id: StringName, parent_id: StringName, rects: Array, lc: Color) -> void:
	var row_top: float = minf(pp.y, cp.y) - nh / 2.0
	var row_bot: float = maxf(pp.y, cp.y) + nh / 2.0
	var x_lo: float = minf(pp.x, cp.x) - 1.0
	var x_hi: float = maxf(pp.x, cp.x) + 1.0

	# Find the nearest occupied y above and below the row, along the segment x.
	var nearest_above: float = -INF  # bottom edge of the closest node above
	var nearest_below: float = INF   # top edge of the closest node below
	for entry in rects:
		var rid: StringName = entry["id"]
		if rid == child_id or rid == parent_id:
			continue
		var r: Rect2 = entry["rect"]
		if r.position.x + r.size.x < x_lo or r.position.x > x_hi:
			continue
		var r_top: float = r.position.y
		var r_bot: float = r.position.y + r.size.y
		# Skip nodes in the same row as the endpoints (siblings).
		if r_bot >= row_top - 1.0 and r_top <= row_bot + 1.0:
			continue
		if r_bot <= row_top and r_bot > nearest_above:
			nearest_above = r_bot
		if r_top >= row_bot and r_top < nearest_below:
			nearest_below = r_top

	# Available gap height above and below the row.
	var gap_above: float = row_top - nearest_above
	var gap_below: float = nearest_below - row_bot
	# Prefer below if both are clear; otherwise pick whichever has more room.
	var go_below: bool = gap_below >= gap_above
	var mid_y: float
	if go_below:
		# Center of the gap below the row.
		var lo: float = row_bot + 4.0
		var hi: float = row_bot + 16.0 if nearest_below == INF else nearest_below - 4.0
		if hi < lo:
			hi = lo
		mid_y = (lo + hi) / 2.0
	else:
		var lo2: float = row_top - 16.0 if nearest_above == -INF else nearest_above + 4.0
		var hi2: float = row_top - 4.0
		if lo2 > hi2:
			lo2 = hi2
		mid_y = (lo2 + hi2) / 2.0

	# Draw 5 segments: short stub out the side of the row, U-detour to mid_y.
	if go_below:
		# Out the bottom of both nodes.
		tree_canvas.draw_line(Vector2(pp.x, pp.y + nh / 2.0), Vector2(pp.x, mid_y), lc, 2.0)
		tree_canvas.draw_line(Vector2(pp.x, mid_y), Vector2(cp.x, mid_y), lc, 2.0)
		tree_canvas.draw_line(Vector2(cp.x, mid_y), Vector2(cp.x, cp.y + nh / 2.0), lc, 2.0)
	else:
		# Out the top of both nodes.
		tree_canvas.draw_line(Vector2(pp.x, pp.y - nh / 2.0), Vector2(pp.x, mid_y), lc, 2.0)
		tree_canvas.draw_line(Vector2(pp.x, mid_y), Vector2(cp.x, mid_y), lc, 2.0)
		tree_canvas.draw_line(Vector2(cp.x, mid_y), Vector2(cp.x, cp.y - nh / 2.0), lc, 2.0)


func _on_tree_draw() -> void:
	var z = zoom_level
	var nw = NODE_W * z
	var nh = NODE_H * z

	# Build list of visible node rects once, for line routing collision checks.
	var visible_rects: Array = []
	for vid in node_positions:
		if not _is_node_visible(vid): continue
		var vp: Vector2 = node_positions[vid] * z
		visible_rects.append({
			"id": vid,
			"rect": Rect2(vp.x - nw / 2.0, vp.y - nh / 2.0, nw, nh),
		})

	# Connection lines (only between visible nodes). Pure port of
	# Mindustry's ResearchDialog.View.drawChildren:
	#
	#   if |dy| ≈ |dx| (within 1 unit) AND distance <= node.width*3:
	#       draw ONE straight line parent → child
	#   else:
	#       draw a 2-segment L (horizontal at parent.y, then vertical
	#       at child.x)
	#
	# Same-row connections (`|dy| ≈ 0`) naturally fall into one of
	# these two cases:
	#   - Adjacent same-row → diagonal test passes (|dx-dy|≈|dx|, but
	#     manhattan ≤ width*3 only when close), drawn as a straight
	#     horizontal line.
	#   - Far same-row → L-shape collapses to a straight horizontal
	#     since the vertical segment has zero length.
	# Either way, no U-detour — the user wants neighbours to connect
	# with a clean straight line, not arc through the row gap.
	for nid in node_positions:
		if not _is_node_visible(nid): continue
		var node = TechTree.get_node_data(nid)
		if node == null: continue
		var cp = node_positions[nid] * z
		for pid in node["parents"]:
			if not node_positions.has(pid): continue
			if not _is_node_visible(pid): continue
			var pp = node_positions[pid] * z
			var lc = line_color_researched if TechTree.is_researched(pid) else line_color
			var dx_abs: float = absf(cp.x - pp.x)
			var dy_abs: float = absf(cp.y - pp.y)
			var manhattan: float = dx_abs + dy_abs
			# Mindustry test: roughly diagonal AND close enough that
			# a single segment doesn't look like a long stretched
			# slash across the tree. Same-row pairs (dy_abs ≈ 0)
			# pass when they're horizontally close too — drawn as a
			# clean straight horizontal line.
			var diagonal: bool = absf(dx_abs - dy_abs) <= 1.0 \
					and manhattan <= nw * 3.0
			if diagonal:
				tree_canvas.draw_line(pp, cp, lc, 2.0)
			else:
				# L-shape: parent → (child.x, parent.y) → child.
				# For same-row pairs the vertical segment collapses
				# to zero length — net result is just a horizontal
				# line, no U-detour.
				tree_canvas.draw_line(pp,
					Vector2(cp.x, pp.y), lc, 2.0)
				tree_canvas.draw_line(Vector2(cp.x, pp.y), cp,
					lc, 2.0)

	# Nodes (only visible ones)
	for nid in node_positions:
		if not _is_node_visible(nid): continue
		var node = TechTree.get_node_data(nid)
		if node == null: continue
		_draw_node(nid, node, z, nw, nh)


func _draw_node(nid: StringName, _node: Dictionary, z: float, nw: float, nh: float) -> void:
	var pos = node_positions[nid] * z
	var state = TechTree.get_state(nid)
	var oc: Color; var fc: Color; var _lc: Color
	match state:
		TechTree.NodeState.LOCKED:
			oc = locked_outline; fc = locked_fill; _lc = Color(0.5, 0.3, 0.3)
		TechTree.NodeState.UNLOCKED:
			oc = unlocked_outline; fc = unlocked_fill; _lc = text_color
		TechTree.NodeState.RESEARCHED:
			oc = researched_outline; fc = researched_fill; _lc = researched_outline

	var rect = Rect2(pos.x - nw / 2.0, pos.y - nh / 2.0, nw, nh)
	var box = StyleBoxFlat.new()
	box.bg_color = fc
	box.border_color = oc
	var bw = 3.0 if nid == hovered_node_id else 2.0
	box.set_border_width_all(int(bw * z))
	box.set_corner_radius_all(int(6.0 * z))  # Change 6.0 for more/less rounding
	tree_canvas.draw_style_box(box, rect)

	if state == TechTree.NodeState.UNLOCKED:
		var progress = TechTree.get_progress(nid)
		if progress > 0.0:
			tree_canvas.draw_rect(Rect2(rect.position.x + 2, rect.position.y + rect.size.y - 5 * z, (rect.size.x - 4) * progress, 3 * z), accent_color.darkened(0.3), true)

	if state == TechTree.NodeState.LOCKED:
		# Draw the shared LockIcon.png centred on the node, scaled with
		# the tree's current zoom (`z`). The texture's natural aspect
		# (320 × 443) is preserved so it doesn't squish into a square,
		# and we draw with white modulate so the icon renders at its
		# true colours instead of inheriting the locked-node tint.
		if _lock_icon != null:
			var tex_sz: Vector2 = _lock_icon.get_size()
			var lh: float = 24.0 * z
			var lw: float = lh * (tex_sz.x / tex_sz.y)
			var lr := Rect2(Vector2(pos.x - lw * 0.5, pos.y - lh * 0.5), Vector2(lw, lh))
			tree_canvas.draw_texture_rect(_lock_icon, lr, false, Color.WHITE)
	else:
		var icon = _get_node_icon(nid)
		var icon_size = 25.0 * z  # Change 32.0 to whatever pixel size you want
		var icon_rect = Rect2(
			pos.x - icon_size / 2.0,
			pos.y - icon_size / 2.0,
			icon_size,
			icon_size
		)
		# `lc` doubles as the text colour, which is the gold researched tint
		# for finished nodes. Tinting the icon with it washed out the
		# original art, so always draw the icon untinted.
		tree_canvas.draw_texture_rect(icon, icon_rect, false, Color.WHITE)


# =========================
# INTERACTION
# =========================

func _on_tree_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hit = _hit_test(event.position)
		if hit != hovered_node_id:
			# Don't blank the tooltip just because the cursor drifted
			# off the tree node to reach the "i" button. Check both
			# the cached flag AND the actual cursor rect — the flag
			# may not be updated yet if mouse_entered hasn't fired.
			if hit == &"" and _cursor_over_tooltip():
				return
			hovered_node_id = hit
			tree_canvas.queue_redraw()
			_update_tooltip(hit, event.global_position)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_tree_drag_start = event.position
		else:
			# Only register click if we didn't drag significantly
			if _tree_drag_start.distance_to(event.position) > 5.0:
				return  # Was a drag, not a click
			var hit = _hit_test(event.position)
			if hit != &"": _on_node_clicked(hit)


## True if the actual mouse cursor is currently inside the tooltip
## panel's rect. Used as a backstop for the `_mouse_over_tooltip`
## signal-driven flag, which can lag a frame behind a fast cursor.
func _cursor_over_tooltip() -> bool:
	if not tooltip_panel.visible:
		return false
	return tooltip_panel.get_global_rect().has_point(get_viewport().get_mouse_position())

func _on_tree_mouse_exit() -> void:
	if hovered_node_id != &"":
		hovered_node_id = &""
		tree_canvas.queue_redraw()
		# Defer the actual hide so a cursor that's already over the
		# tooltip (very common — the tooltip sits next to the node)
		# doesn't snap the panel shut before it's reachable.
		_maybe_hide_tooltip()


## Hides the tooltip ONLY when the cursor is on neither a tree node
## nor the tooltip itself. Called from both the tree mouse-exit hook
## and the tooltip's own mouse_exited signal so whichever fires last
## wins gracefully.
func _maybe_hide_tooltip() -> void:
	if _mouse_over_tooltip or _cursor_over_tooltip():
		return
	if hovered_node_id != &"":
		return
	tooltip_panel.visible = false


## Zooms in/out centered on the mouse position.
## delta > 0 = zoom in, delta < 0 = zoom out.
func _zoom_at(mouse_pos: Vector2, delta: float) -> void:
	var old_zoom = zoom_level
	zoom_level = clampf(zoom_level + delta, ZOOM_MIN, ZOOM_MAX)
	if zoom_level == old_zoom:
		return

	# The mouse_pos is in canvas-local space (already includes scroll offset).
	# We want the world point under the mouse to stay under the mouse.
	# world_point = (scroll + mouse_in_scroll) / old_zoom
	# After zoom: scroll_new = world_point * new_zoom - mouse_in_scroll

	# mouse_in_scroll is relative to the ScrollContainer's visible area
	var _mouse_in_scroll = Vector2(
		tree_scroll.scroll_horizontal + mouse_pos.x / old_zoom * old_zoom,
		tree_scroll.scroll_vertical + mouse_pos.y / old_zoom * old_zoom
	)
	# Actually simpler: the point in base coords under the mouse
	var base_point = mouse_pos / old_zoom

	# Update canvas size
	tree_canvas.custom_minimum_size = canvas_size * zoom_level
	tree_canvas.queue_redraw()

	# Adjust scroll so base_point stays at same screen position
	# screen_pos_of_point = base_point * zoom_level - scroll
	# We want screen_pos to equal: base_point * old_zoom - old_scroll
	# (which is where the mouse was relative to scroll viewport)
	var mouse_screen = base_point * old_zoom - Vector2(tree_scroll.scroll_horizontal, tree_scroll.scroll_vertical)
	tree_scroll.scroll_horizontal = int(base_point.x * zoom_level - mouse_screen.x)
	tree_scroll.scroll_vertical = int(base_point.y * zoom_level - mouse_screen.y)

func _hit_test(local_pos: Vector2) -> StringName:
	var z = zoom_level
	var nw = NODE_W * z
	var nh = NODE_H * z
	for nid in node_positions:
		if not _is_node_visible(nid): continue
		var pos = node_positions[nid] * z
		if Rect2(pos.x - nw / 2.0, pos.y - nh / 2.0, nw, nh).has_point(local_pos):
			return nid
	return &""

func _on_node_clicked(nid: StringName) -> void:
	var state = TechTree.get_state(nid)
	match state:
		TechTree.NodeState.LOCKED: pass
		TechTree.NodeState.UNLOCKED:
			var spent = TechTree.spend_resources_from_global(nid)
			if spent:
				if main and main.has_signal("resources_changed"):
					main.resources_changed.emit(main.resources)
				tree_canvas.queue_redraw()
				_update_tooltip(nid, tooltip_panel.position)
				_update_resource_panel()
		TechTree.NodeState.RESEARCHED:
			var db_ui = get_node_or_null("/root/Main/DatabaseUI")
			if db_ui and db_ui.has_method("show_entry_detail_only"):
				db_ui.show_entry_detail_only(nid)
			return


# =========================
# TOOLTIP
# =========================

## Returns the description string the database UI would show for this
## tech-tree node, or "" if none is found. Tries each Registry type
## the node could map to — block ids dominate, but sectors / items /
## fluids / units also appear as tech-tree nodes.
func _get_description_for(nid: StringName) -> String:
	var b = Registry.get_block(nid)
	if b and "description" in b and b.description != "":
		return b.description
	var s = Registry.get_sector(nid)
	if s and "description" in s and s.description != "":
		return s.description
	var u = Registry.get_unit(nid)
	if u and "description" in u and u.description != "":
		return u.description
	var item = Registry.get_item(nid)
	if item and "description" in item and item.description != "":
		return item.description
	var fluid = Registry.get_fluid(nid)
	if fluid and "description" in fluid and fluid.description != "":
		return fluid.description
	return ""


func _update_tooltip(nid: StringName, screen_pos: Vector2) -> void:
	if nid == &"":
		tooltip_panel.visible = false
		return
	var nd = TechTree.get_node_data(nid)
	if nd == null:
		tooltip_panel.visible = false
		return
	var state = TechTree.get_state(nid)
	for child in tooltip_vbox.get_children(): child.queue_free()

	# --- HEADER ROW: [i button] [name + cost/state stacked] -----------
	# Mindustry-style block tooltip: small square "i" button on the
	# left opens the database entry for this node, the right side
	# stacks the node name + (either "Researched" in yellow OR the
	# research cost / locked deps).
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	header.alignment = BoxContainer.ALIGNMENT_BEGIN
	tooltip_vbox.add_child(header)

	var i_btn := Button.new()
	i_btn.text = "i"
	i_btn.custom_minimum_size = Vector2(36, 36)
	i_btn.add_theme_font_size_override("font_size", 20)
	i_btn.add_theme_color_override("font_color", Color(0.55, 0.78, 0.95))
	i_btn.add_theme_color_override("font_hover_color", Color(0.8, 0.95, 1.0))
	i_btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var captured_nid: StringName = nid
	# Locked nodes hide their identity, so the database link would
	# spoil that — disable the i button until at least UNLOCKED.
	if state == TechTree.NodeState.LOCKED:
		i_btn.disabled = true
	i_btn.pressed.connect(func():
		var db_ui = get_node_or_null("/root/Main/DatabaseUI")
		if db_ui and db_ui.has_method("show_entry_detail_only"):
			db_ui.show_entry_detail_only(captured_nid))
	header.add_child(i_btn)

	var info_vbox := VBoxContainer.new()
	info_vbox.add_theme_constant_override("separation", 2)
	info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	header.add_child(info_vbox)

	# Node name (top of the right column).
	var nl := Label.new()
	if state == TechTree.NodeState.LOCKED:
		nl.text = "???"
	else:
		nl.text = nd["name"]
	nl.add_theme_font_size_override("font_size", 16)
	match state:
		TechTree.NodeState.LOCKED: nl.add_theme_color_override("font_color", locked_outline)
		TechTree.NodeState.UNLOCKED: nl.add_theme_color_override("font_color", text_color)
		TechTree.NodeState.RESEARCHED: nl.add_theme_color_override("font_color", text_color)
	info_vbox.add_child(nl)

	# State line: "Researched" (yellow) when done, otherwise the
	# research cost list inline under the name.
	if state == TechTree.NodeState.RESEARCHED:
		var rs := Label.new()
		rs.text = "Researched"
		rs.add_theme_font_size_override("font_size", 13)
		rs.add_theme_color_override("font_color", researched_outline)
		info_vbox.add_child(rs)
	elif state == TechTree.NodeState.UNLOCKED:
		var cost = nd["research_cost"]
		for item_id in cost:
			var req = cost[item_id]
			var spt = TechTree.get_spent(nid, item_id)
			var hbox = HBoxContainer.new()
			hbox.add_theme_constant_override("separation", 6)
			var item_data = Registry.get_item_or_fluid(item_id)
			if item_data and item_data.icon:
				var tex_rect = TextureRect.new()
				tex_rect.texture = item_data.icon
				tex_rect.custom_minimum_size = Vector2(14, 14)
				tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				hbox.add_child(tex_rect)
			else:
				var sw = ColorRect.new()
				sw.custom_minimum_size = Vector2(14, 14)
				sw.color = item_data.color if item_data else Color.GRAY
				hbox.add_child(sw)
			var rn = Label.new()
			rn.text = item_data.display_name if item_data else str(item_id)
			rn.add_theme_font_size_override("font_size", 12)
			rn.add_theme_color_override("font_color", dim_color)
			rn.custom_minimum_size.x = 90
			hbox.add_child(rn)
			var al = Label.new()
			al.text = "%s / %s" % [Registry.format_amount(spt), Registry.format_amount(req)]
			al.add_theme_font_size_override("font_size", 12)
			al.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3) if spt >= req else Color(0.9, 0.5, 0.3))
			hbox.add_child(al)
			info_vbox.add_child(hbox)

	# --- DESCRIPTION (below the header, full width) -------------------
	# Pull from whichever Registry entry the tech-tree id corresponds
	# to (block / item / fluid / sector / unit). Skipped for LOCKED
	# nodes so they don't leak content.
	if state != TechTree.NodeState.LOCKED:
		var desc: String = _get_description_for(nid)
		if desc != "":
			var dl := Label.new()
			dl.text = desc
			dl.add_theme_font_size_override("font_size", 13)
			dl.add_theme_color_override("font_color", text_color)
			dl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			dl.custom_minimum_size.x = 260
			tooltip_vbox.add_child(dl)

	var deps: Array = nd.get("dependencies", [])
	if state == TechTree.NodeState.LOCKED and not deps.is_empty():
		var complete_lbl = Label.new()
		complete_lbl.text = "Complete:"
		complete_lbl.add_theme_font_size_override("font_size", 13)
		complete_lbl.add_theme_color_override("font_color", Color.WHITE)
		tooltip_vbox.add_child(complete_lbl)
		for pid in deps:
			var pid_str: String = str(pid)
			var display_name: String
			if pid_str.begins_with("-L-"):
				var sector_id: String = pid_str.substr(3)
				var sector_data = TechTree.get_node_data(StringName(sector_id))
				var sector_name: String = sector_data["name"] if sector_data else sector_id.replace("_", " ").capitalize()
				display_name = "Land on sector %s" % sector_name
			elif pid_str.begins_with("-D-"):
				var archive_id: String = pid_str.substr(3)
				var archive_data = TechTree.get_node_data(StringName(archive_id))
				var archive_name: String = archive_data["name"] if archive_data else archive_id.replace("_", " ").capitalize()
				# Strip a leading "Archive: " (or "Archive ") from the node's display
				# name so the prefix isn't doubled (e.g. "Decode The Archive: Payload Systems"
				# instead of "Decode The Archive Archive: Payload Systems").
				if archive_name.begins_with("Archive: "):
					archive_name = archive_name.substr(9)
				elif archive_name.begins_with("Archive "):
					archive_name = archive_name.substr(8)
				display_name = "Decode The Archive: %s" % archive_name
			elif pid_str.begins_with("-C-"):
				var sector_id: String = pid_str.substr(3)
				var sector_data = TechTree.get_node_data(StringName(sector_id))
				var sector_name: String = sector_data["name"] if sector_data else sector_id.replace("_", " ").capitalize()
				display_name = "Capture sector %s" % sector_name
			else:
				var pd = TechTree.get_node_data(pid)
				if pd and pd.get("event_only", false) and not TechTree.is_researched(pid):
					# Locked resource dependency — show "Mine ???" or "Produce ???"
					const MINABLE_RESOURCES: Array[StringName] = [
						&"mat_copper", &"mat_graphite", &"mat_iron",
						&"mat_silver", &"mat_zinc",
					]
					if pid in MINABLE_RESOURCES:
						display_name = "Mine ???"
					else:
						display_name = "Produce ???"
				else:
					display_name = pd["name"] if pd else pid_str
			var dep_hbox = HBoxContainer.new()
			dep_hbox.add_theme_constant_override("separation", 4)
			if TechTree.is_researched(pid):
				var check_tex = load("res://textures/UI/checkmark.png") as Texture2D
				if check_tex:
					var icon = TextureRect.new()
					icon.texture = check_tex
					icon.custom_minimum_size = Vector2(14, 14)
					icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
					icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
					icon.modulate = Color(0.3, 0.9, 0.3)  # Green tint
					dep_hbox.add_child(icon)
				var pl = Label.new()
				pl.text = display_name
				pl.add_theme_font_size_override("font_size", 12)
				pl.add_theme_color_override("font_color", Color(0.3, 0.8, 0.3))
				dep_hbox.add_child(pl)
			else:
				var pl = Label.new()
				pl.text = "❌ " + display_name
				pl.add_theme_font_size_override("font_size", 12)
				pl.add_theme_color_override("font_color", locked_outline)
				dep_hbox.add_child(pl)
			tooltip_vbox.add_child(dep_hbox)

	tooltip_panel.visible = true
	tooltip_panel.reset_size()
	await get_tree().process_frame
	if not is_open:
		tooltip_panel.visible = false
		return
	var vps = get_viewport().get_visible_rect().size
	var ts = tooltip_panel.size
	var tx = screen_pos.x + 16; var ty = screen_pos.y + 16
	if tx + ts.x > vps.x - 10: tx = screen_pos.x - ts.x - 10
	if ty + ts.y > vps.y - 10: ty = screen_pos.y - ts.y - 10
	tooltip_panel.position = Vector2(tx, ty)

func _build_resource_panel() -> void:
	resource_panel = PanelContainer.new()
	resource_panel.anchor_left = 1.0
	resource_panel.anchor_right = 1.0
	resource_panel.offset_left = -240
	resource_panel.offset_top = 70
	resource_panel.offset_right = -30
	resource_panel.z_index = 50
	resource_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.1, 0.92)
	style.border_color = Color(0.2, 0.25, 0.3, 0.6)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	resource_panel.add_theme_stylebox_override("panel", style)
	add_child(resource_panel)

	var outer = VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	resource_panel.add_child(outer)

	var header = Label.new()
	header.text = "Global Resources"
	header.add_theme_font_size_override("font_size", 14)
	header.add_theme_color_override("font_color", accent_color)
	outer.add_child(header)

	resource_vbox = VBoxContainer.new()
	resource_vbox.add_theme_constant_override("separation", 3)
	outer.add_child(resource_vbox)

	resource_panel.visible = false


func _update_resource_panel() -> void:
	for c in resource_vbox.get_children():
		c.queue_free()

	# Use the global pool (sum of all sectors' resources)
	if main:
		SaveManager.sync_active_sector_resources()
	var global_res: Dictionary = SaveManager.get_global_resources()
	if global_res.is_empty():
		return

	for item in Registry.items_list:
		var amount: int = global_res.get(item.id, 0)
		if amount <= 0:
			continue

		var hbox = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 6)
		hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE

		# Icon (texture or color swatch fallback)
		if item.icon:
			var tex_rect = TextureRect.new()
			tex_rect.texture = item.icon
			tex_rect.custom_minimum_size = Vector2(14, 14)
			tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
			hbox.add_child(tex_rect)
		else:
			var sw = ColorRect.new()
			sw.custom_minimum_size = Vector2(14, 14)
			sw.color = item.color if item.color else Color.GRAY
			sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
			hbox.add_child(sw)

		# Name
		var name_lbl = Label.new()
		name_lbl.text = item.display_name
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.add_theme_color_override("font_color", dim_color)
		name_lbl.custom_minimum_size.x = 100
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(name_lbl)

		# Amount
		var amt_lbl = Label.new()
		amt_lbl.text = Registry.format_amount(amount)
		amt_lbl.add_theme_font_size_override("font_size", 12)
		amt_lbl.add_theme_color_override("font_color", text_color)
		amt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		amt_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		amt_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(amt_lbl)

		resource_vbox.add_child(hbox)

# =========================
# SHOW / HIDE
# =========================

func _show_ui() -> void:
	# `_ready` builds the UI after a couple of awaited frames, so a
	# caller (e.g. planet_select racing to open the tree right after
	# scene change) can hit this before `_build_ui()` ran. Build it
	# on demand and grab `main` so the rest of the function has live
	# refs to `root_panel` / `tree_canvas` / `resource_panel`.
	if root_panel == null:
		if main == null:
			main = get_node_or_null("/root/Main")
		_build_ui()
	is_open = true
	root_panel.visible = true
	get_tree().paused = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Retroactively unlock event-only material nodes (mat_steel, …)
	# against the cross-sector global pool. The per-sector load path
	# only ever syncs against the active sector's stockpile, so steel
	# produced on a different sector would leave dependents (Unit
	# Refabricator, …) locked even though the Global Resources panel
	# visibly showed the stockpile. Push the active sector's live
	# stockpile into `sector_resources` first so the global pool
	# reflects what's actually in the player's bank right now.
	if main:
		SaveManager.sync_active_sector_resources()
	TechTree.sync_event_unlocks_from_resources(SaveManager.get_global_resources())
	_compute_layout()
	tree_canvas.queue_redraw()
	resource_panel.visible = true
	_update_resource_panel()
	await get_tree().process_frame
	# Scroll to core_shard
	if node_positions.has(&"core_shard"):
		var sp = node_positions[&"core_shard"] * zoom_level
		var vs = tree_scroll.size
		tree_scroll.scroll_horizontal = int(sp.x - vs.x / 2.0)
		tree_scroll.scroll_vertical = int(sp.y - vs.y + 100)

func _on_resources_changed(_res: Dictionary) -> void:
	_update_resource_panel()


func _hide_ui() -> void:
	is_open = false
	root_panel.visible = false
	tooltip_panel.visible = false
	resource_panel.visible = false
	process_mode = Node.PROCESS_MODE_INHERIT
	# Only unpause if no other UI is still open
	var db_ui = get_node_or_null("/root/Main/DatabaseUI")
	if db_ui == null or not db_ui.is_open:
		get_tree().paused = false

func _make_style(color: Color, radius: int) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = color
	s.corner_radius_top_left = radius; s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius; s.corner_radius_bottom_right = radius
	s.content_margin_left = 8; s.content_margin_right = 8
	s.content_margin_top = 4; s.content_margin_bottom = 4
	return s

## Tries to find an icon for a tech tree node by checking
## blocks, items, and units in the Registry. Returns the
## fallback texture if nothing has an icon set.
func _get_node_icon(nid: StringName) -> Texture2D:
	if Registry.blocks.has(nid) and Registry.blocks[nid].icon:
		return Registry.blocks[nid].icon
	if Registry.items.has(nid) and Registry.items[nid].icon:
		return Registry.items[nid].icon
	if Registry.units.has(nid) and Registry.units[nid].icon:
		return Registry.units[nid].icon
	if Registry.sectors.has(nid) and Registry.sectors[nid].icon:
		return Registry.sectors[nid].icon
	return fallback_icon
