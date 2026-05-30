extends Node
class_name SchematicSystem

## Owns the schematic capture / paste / save-dialog state. Lifted out of
## BuildingSystem so the 11 K-line file has one less self-contained
## subsystem on its plate.
##
## Drawing (selection rect + paste-mode ghost) still happens on
## BuildingSystem's own Node2D canvas — it reads state from this node
## through the `mode` / `dragging` / `placing` / `place_blocks` fields.
## Everything else (input gating, captures, flips, save dialog, place
## execution) lives here.


# --- SCHEMATIC CAPTURE STATE ---
var mode: bool = false
var dragging: bool = false
var start: Vector2i = Vector2i.ZERO
var end: Vector2i = Vector2i.ZERO
var confirmed: bool = false   # Rect finalized, waiting for Enter

# --- SCHEMATIC PLACEMENT STATE ---
var placing: bool = false
var place_blocks: Dictionary = {}     # Vector2i (relative) -> StringName
var place_rotation: Dictionary = {}   # Vector2i (relative) -> int
var place_width: int = 0
var place_height: int = 0

# --- SCHEMATIC SAVE DIALOG ---
var popup: PopupPanel = null

@onready var main: Node2D = get_node_or_null("/root/Main")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _building_sys() -> Node:
	if main == null:
		return null
	return main.get_node_or_null("BuildingSystem")


## Snapshot every anchor in the rect [from..to] (inclusive) into the
## schematic dictionary format used for both save files and the paste
## buffer.
func capture_rect(from: Vector2i, to: Vector2i) -> Dictionary:
	var min_pos := Vector2i(mini(from.x, to.x), mini(from.y, to.y))
	var max_pos := Vector2i(maxi(from.x, to.x), maxi(from.y, to.y))
	var blocks: Dictionary = {}
	var rotation: Dictionary = {}
	var anchors_seen: Dictionary = {}
	for x in range(min_pos.x, max_pos.x + 1):
		for y in range(min_pos.y, max_pos.y + 1):
			var pos := Vector2i(x, y)
			if not main.placed_buildings.has(pos):
				continue
			var anchor: Vector2i = main.building_origins.get(pos, pos)
			if anchors_seen.has(anchor):
				continue
			anchors_seen[anchor] = true
			if anchor.x < min_pos.x or anchor.x > max_pos.x or anchor.y < min_pos.y or anchor.y > max_pos.y:
				continue
			var block_id: StringName = main.placed_buildings[anchor]
			var rot: int = main.building_rotation.get(anchor, 0)
			var rel: Vector2i = anchor - min_pos
			var key: String = "%d,%d" % [rel.x, rel.y]
			blocks[key] = String(block_id)
			if rot != 0:
				rotation[key] = rot
	var w: int = max_pos.x - min_pos.x + 1
	var h: int = max_pos.y - min_pos.y + 1
	return {"blocks": blocks, "rotation": rotation, "width": w, "height": h}


func enter_paste_mode_from_rect(from: Vector2i, to: Vector2i) -> void:
	var captured: Dictionary = capture_rect(from, to)
	if captured["blocks"].is_empty():
		return
	start_placement(captured)


func _flip_rot_x(rot: int) -> int:
	match rot:
		1: return 3
		3: return 1
		_: return rot


func _flip_rot_y(rot: int) -> int:
	match rot:
		0: return 2
		2: return 0
		_: return rot


func _block_effective_size(block_id: StringName, rot: int) -> Vector2i:
	var data = Registry.get_block(block_id)
	if data == null:
		return Vector2i(1, 1)
	var gw: int = int(data.grid_size.x)
	var gh: int = int(data.grid_size.y)
	if rot == 1 or rot == 3:
		return Vector2i(gh, gw)
	return Vector2i(gw, gh)


func flip_placement_x() -> void:
	if not placing or place_blocks.is_empty():
		return
	var new_blocks: Dictionary = {}
	var new_rot: Dictionary = {}
	var W: int = place_width
	for rel_pos in place_blocks:
		var bid: StringName = place_blocks[rel_pos]
		var rot: int = int(place_rotation.get(rel_pos, 0))
		var eff: Vector2i = _block_effective_size(bid, rot)
		var new_pos := Vector2i(W - rel_pos.x - eff.x, rel_pos.y)
		var new_r := _flip_rot_x(rot)
		new_blocks[new_pos] = bid
		if new_r != 0:
			new_rot[new_pos] = new_r
	place_blocks = new_blocks
	place_rotation = new_rot
	var bsys := _building_sys()
	if bsys:
		bsys.queue_redraw()


func flip_placement_y() -> void:
	if not placing or place_blocks.is_empty():
		return
	var new_blocks: Dictionary = {}
	var new_rot: Dictionary = {}
	var H: int = place_height
	for rel_pos in place_blocks:
		var bid: StringName = place_blocks[rel_pos]
		var rot: int = int(place_rotation.get(rel_pos, 0))
		var eff: Vector2i = _block_effective_size(bid, rot)
		var new_pos := Vector2i(rel_pos.x, H - rel_pos.y - eff.y)
		var new_r := _flip_rot_y(rot)
		new_blocks[new_pos] = bid
		if new_r != 0:
			new_rot[new_pos] = new_r
	place_blocks = new_blocks
	place_rotation = new_rot
	var bsys := _building_sys()
	if bsys:
		bsys.queue_redraw()


func capture_from_placement_buffer() -> Dictionary:
	var blocks: Dictionary = {}
	var rotation: Dictionary = {}
	for rel_pos in place_blocks:
		var bid: StringName = place_blocks[rel_pos]
		var key: String = "%d,%d" % [rel_pos.x, rel_pos.y]
		blocks[key] = String(bid)
		var rot: int = int(place_rotation.get(rel_pos, 0))
		if rot != 0:
			rotation[key] = rot
	return {"blocks": blocks, "rotation": rotation, "width": place_width, "height": place_height}


func show_save_dialog_from_placement() -> void:
	if not placing or place_blocks.is_empty():
		return
	var captured: Dictionary = capture_from_placement_buffer()
	show_save_dialog(captured)


func show_save_dialog(captured_override = null) -> void:
	var bsys := _building_sys()
	if bsys == null:
		return
	if popup and is_instance_valid(popup):
		popup.queue_free()

	var captured: Dictionary
	if captured_override != null:
		captured = captured_override
	else:
		captured = capture_rect(start, end)
	if captured["blocks"].is_empty():
		mode = false
		confirmed = false
		return

	# --- Mindustry-style save dialog ---
	# Big tiled-background preview at top, name field, then collapsible
	# block list + requirement list, then Cancel / Save.
	popup = PopupPanel.new()
	popup.size = Vector2(420, 560)
	# Match the dark Mindustry-ish chrome instead of Godot's default
	# light-gray PopupPanel.
	var popup_style := StyleBoxFlat.new()
	popup_style.bg_color = Color(0.08, 0.09, 0.12, 0.98)
	popup_style.set_border_width_all(2)
	popup_style.border_color = Color(0.32, 0.36, 0.42, 1.0)
	popup_style.set_corner_radius_all(6)
	popup_style.content_margin_left = 14
	popup_style.content_margin_right = 14
	popup_style.content_margin_top = 12
	popup_style.content_margin_bottom = 12
	popup.add_theme_stylebox_override("panel", popup_style)
	bsys.add_child(popup)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	popup.add_child(vbox)

	# --- Title ---
	var title := Label.new()
	title.text = "Save Schematic"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.35))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# --- Large preview with tiled background ---
	var preview_holder := PanelContainer.new()
	var preview_style := StyleBoxFlat.new()
	preview_style.bg_color = Color(0, 0, 0, 1)
	preview_style.set_border_width_all(2)
	preview_style.border_color = Color(0.42, 0.46, 0.52, 1.0)
	preview_holder.add_theme_stylebox_override("panel", preview_style)
	preview_holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(preview_holder)
	var preview := SchematicPreview.new()
	preview.custom_minimum_size = Vector2(280, 280)
	preview.schematic = captured
	preview_holder.add_child(preview)

	# --- Name field ---
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 6)
	vbox.add_child(name_row)
	var name_label := Label.new()
	name_label.text = "Name"
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.add_theme_color_override("font_color", Color(0.8, 0.82, 0.86))
	name_row.add_child(name_label)
	var name_input := LineEdit.new()
	name_input.placeholder_text = "Schematic name..."
	name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_input)

	# --- Requirements (item icons + counts in a wrap row, Mindustry style) ---
	var total_cost: Dictionary = {}
	for key in captured["blocks"]:
		var bid_c: StringName = StringName(captured["blocks"][key])
		var bd_c = Registry.get_block(bid_c)
		if bd_c:
			for item_id in bd_c.build_cost:
				total_cost[item_id] = total_cost.get(item_id, 0) + bd_c.build_cost[item_id]

	if not total_cost.is_empty():
		var req_label := Label.new()
		req_label.text = "Requirements"
		req_label.add_theme_font_size_override("font_size", 12)
		req_label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
		vbox.add_child(req_label)
		var req_wrap := HFlowContainer.new()
		req_wrap.add_theme_constant_override("h_separation", 10)
		req_wrap.add_theme_constant_override("v_separation", 4)
		vbox.add_child(req_wrap)
		for item_id in total_cost:
			# build_cost uses SHORT keys ("copper", "graphite") that have
			# to be resolved to canonical resource ids ("mat_copper", …)
			# via Main._resolve_resource_key before the Registry lookup,
			# or `get_item_or_fluid` returns null and the icon column
			# disappears.
			var lookup_id: StringName = item_id
			if main and main.has_method("_resolve_resource_key"):
				lookup_id = main._resolve_resource_key(str(item_id))
			var item_data = Registry.get_item_or_fluid(lookup_id)
			if item_data == null:
				item_data = Registry.get_item_or_fluid(item_id)
			var pill := HBoxContainer.new()
			pill.add_theme_constant_override("separation", 3)
			if item_data and item_data.icon:
				var tex := TextureRect.new()
				tex.texture = item_data.icon
				tex.custom_minimum_size = Vector2(18, 18)
				tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				pill.add_child(tex)
			var clbl := Label.new()
			clbl.text = str(int(total_cost[item_id]))
			clbl.add_theme_font_size_override("font_size", 12)
			pill.add_child(clbl)
			req_wrap.add_child(pill)

	# --- Buttons ---
	vbox.add_child(HSeparator.new())
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(func():
		popup.queue_free()
		mode = false
		confirmed = false
		bsys.queue_redraw()
	)
	btn_row.add_child(cancel_btn)
	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cap_ref: Dictionary = captured
	save_btn.pressed.connect(func():
		var sname: String = name_input.text.strip_edges()
		if sname == "":
			sname = "Unnamed"
		SaveManager.save_schematic(sname, cap_ref["blocks"], cap_ref["rotation"], cap_ref["width"], cap_ref["height"])
		popup.queue_free()
		mode = false
		confirmed = false
		bsys.queue_redraw()
	)
	btn_row.add_child(save_btn)

	popup.popup_centered()


## Called by HUD (and the C-drag pipeline) to enter schematic placement
## mode with the given captured dictionary.
func start_placement(data: Dictionary) -> void:
	place_blocks.clear()
	place_rotation.clear()
	var blocks_data: Dictionary = data.get("blocks", {})
	var rot_data: Dictionary = data.get("rotation", {})

	# Re-anchor on the actual topmost-leftmost block. Captures stored
	# rels relative to the user's drag-rect corner, so empty rows / cols
	# above or to the left of the schematic's content would shift the
	# cursor off the block and silently break the top-left placement.
	var raw: Array[Vector2i] = []
	for key in blocks_data:
		var parts: PackedStringArray = key.split(",")
		if parts.size() >= 2:
			raw.append(Vector2i(int(parts[0]), int(parts[1])))
	var min_x: int = 0
	var min_y: int = 0
	if not raw.is_empty():
		min_x = raw[0].x
		min_y = raw[0].y
		for p in raw:
			if p.x < min_x: min_x = p.x
			if p.y < min_y: min_y = p.y

	for key in blocks_data:
		var parts2: PackedStringArray = key.split(",")
		if parts2.size() >= 2:
			var pos := Vector2i(int(parts2[0]) - min_x, int(parts2[1]) - min_y)
			place_blocks[pos] = StringName(blocks_data[key])
			if rot_data.has(key):
				place_rotation[pos] = int(rot_data[key])
	place_width = int(data.get("width", 1))
	place_height = int(data.get("height", 1))
	placing = true
	if main:
		main.select_building(&"")   # Exit build mode
	var bsys := _building_sys()
	if bsys:
		bsys.queue_redraw()


func execute_placement(base_grid: Vector2i) -> void:
	var placed := 0
	for rel_pos in place_blocks:
		var grid_pos: Vector2i = base_grid + rel_pos
		var block_id: StringName = place_blocks[rel_pos]
		var rot: int = place_rotation.get(rel_pos, 0)
		if main.place_building_for_schematic(grid_pos, block_id, rot):
			placed += 1
	print("SchematicSystem: Placed %d/%d schematic blocks." % [placed, place_blocks.size()])
	# Keep `placing` true so the player can drop more copies (cmd-c /
	# cmd-v style). Esc exits the paste mode.
	var bsys := _building_sys()
	if bsys:
		bsys.queue_redraw()


## Called by BuildingSystem when a block is selected from the build
## menu — exits paste mode so the player isn't holding a phantom
## schematic on top of their new build cursor.
func on_building_selected(block_id: StringName) -> void:
	if block_id != &"" and placing:
		placing = false
		var bsys := _building_sys()
		if bsys:
			bsys.queue_redraw()
