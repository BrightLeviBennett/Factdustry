extends Node
class_name WorldUiSystem

## In-world UI popups: the radial-ish "world menu" (sorter / constructor
## / archive / refabricator / recipe-select / launchpad / landing-pad /
## landing-pad-slot / duct_filter / storage) and the secondary "storage
## panel" that opens beside any UI-type menu when its block has stored
## items.
##
## Drawing happens on BuildingSystem's `_popup_overlay` (z_index 4096) —
## this node owns the state + logic, but the draw helpers take an
## explicit CanvasItem so the popup overlay's `_draw` can call straight
## into them.


# --- WORLD MENU STATE (sorter filter / constructor selection) ---
var world_menu_open: bool = false
var world_menu_pos: Vector2i = Vector2i.ZERO
var world_menu_type: String = ""
var world_menu_items: Array = []
var world_menu_columns: int = 8
var world_menu_cell_size: float = 44.0
var world_menu_hovered: int = -1

# --- SECONDARY RESOURCE PANEL ---
# Opens alongside a UI world menu (sorter / constructor / refabricator /
# archive) whenever the underlying block also has stored items.
var storage_panel_open: bool = false
var storage_panel_pos: Vector2i = Vector2i.ZERO
var storage_panel_items: Array = []
var storage_panel_hovered: int = -1

# Logistical Requestor / Dispatcher sub-flow state. The requestor's
# condition is configured in three steps (kind → resource → amount);
# the dispatcher likewise: action_kind → link-to-requestor (if applicable).
# These two persist the in-progress picks across the chained menus.
var requestor_pending_kind: String = ""        # "storage_has" / "units_produced"
var requestor_pending_resource: StringName = &""
var requestor_pending_anchor: Vector2i = Vector2i.ZERO
var dispatcher_pending_action: String = ""     # "stop_block" / "manual_toggle"
var dispatcher_pending_anchor: Vector2i = Vector2i.ZERO

# Landing-pad filter pick: which slot the next world-menu item-pick is
# filling. Set by `open("landing_pad", ...)` then read back when the
# sub-picker (`landing_pad_slot`) confirms.
var landing_pad_pick_slot: int = -1

# Payload Source: the unit id chosen in the first menu, awaiting a faction
# pick in the "payload_source_faction" sub-menu.
var payload_source_pending_id: StringName = &""
var payload_source_pending_anchor: Vector2i = Vector2i.ZERO


@onready var main: Node2D = get_node_or_null("/root/Main")
var _bsys: Node2D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Scale the icon-cell size to whatever sprite scale Main is using.
	if main and "SPRITE_SCALE_FACTOR" in main:
		world_menu_cell_size *= main.SPRITE_SCALE_FACTOR


func _bs() -> Node2D:
	if _bsys == null and main:
		_bsys = main.get_node_or_null("BuildingSystem")
	return _bsys


func _logistics() -> Node:
	if main == null:
		return null
	return main.get_node_or_null("LogisticsSystem")


# Build the displayed item list for a menu of the given `type`. Pulled
# out of the old `_open_world_menu` so the same construction logic can
# run on initial open without splaying 200 lines of if/elif chain.
func _build_menu_items(type: String, grid_pos: Vector2i) -> void:
	world_menu_items.clear()
	var bsys := _bs()
	var logistics := _logistics()

	if type == "storage":
		# Read-only inventory display. Items come from any of the places a
		# block can stash things: LogisticsSystem.block_storage, factory
		# input/output buffers, and the refabricator's loose buffers — all
		# merged via BuildingSystem._collect_block_stored_items.
		var merged: Dictionary = bsys._collect_block_stored_items(grid_pos) if bsys else {}
		for item_id in merged:
			var count: int = int(merged[item_id])
			if count <= 0:
				continue
			# Fluids are tracked separately — keep them out of the item display.
			if Registry.get_fluid(item_id) != null:
				continue
			var it = Registry.get_item(item_id)
			world_menu_items.append({
				"id": item_id,
				"icon": it.icon if it else null,
				"name": it.display_name if it else String(item_id),
				"count": count,
			})
	elif type == "sorter" or type == "duct_filter":
		world_menu_items.append({"id": &"", "icon": null, "name": "Clear"})
		for item in Registry.items_list:
			if not item.conveyable:
				continue
			world_menu_items.append({"id": item.id, "icon": item.icon, "name": item.display_name})
	elif type == "constructor":
		var block_id = main.placed_buildings.get(grid_pos, &"")
		var block_data = Registry.get_block(block_id)
		var max_ps: int = block_data.max_payload_size if block_data else 0
		var gate_on_research: bool = "require_research" in main and main.require_research
		for block in Registry.blocks_list:
			if block.tags.has("core"):
				continue
			if block.grid_size.x > max_ps or block.grid_size.y > max_ps:
				continue
			if gate_on_research and not TechTree.is_researched(block.id):
				continue
			world_menu_items.append({"id": block.id, "icon": block.icon, "name": block.display_name})
	elif type == "resource_source":
		# Dev source: every item AND every fluid.
		world_menu_items.append({"id": &"", "icon": null, "name": "Clear"})
		for item in Registry.items_list:
			world_menu_items.append({"id": item.id, "icon": item.icon, "name": item.display_name})
		for fluid in Registry.fluids_list:
			world_menu_items.append({"id": fluid.id, "icon": fluid.icon, "name": fluid.display_name})
	elif type == "payload_source":
		# Dev source: every block up to 5x5, plus every unit. Units carry a
		# "kind" flag so apply_selection knows to ask for a faction.
		world_menu_items.append({"id": &"", "icon": null, "name": "Clear"})
		for block in Registry.blocks_list:
			if block.id == &"resource_source" or block.id == &"payload_source":
				continue
			if block.grid_size.x > 5 or block.grid_size.y > 5:
				continue
			world_menu_items.append({"id": block.id, "icon": block.icon, "name": block.display_name, "kind": "block"})
		for unit in Registry.units_list:
			world_menu_items.append({"id": unit.id, "icon": unit.icon, "name": unit.display_name, "kind": "unit"})
	elif type == "payload_source_faction":
		world_menu_items.append({"id": &"__lumina", "icon": null, "name": "Lumina"})
		world_menu_items.append({"id": &"__ferox", "icon": null, "name": "Ferox"})
	elif type == "archive":
		world_menu_items.append({"id": &"", "icon": null, "name": "Clear"})
		for aid in TechTree.archive_ids:
			var nd = TechTree.get_node_data(aid)
			var aname: String = nd["name"] if nd else String(aid)
			world_menu_items.append({"id": aid, "icon": null, "name": aname})
	elif type == "refabricator":
		world_menu_items.append({"id": &"", "icon": null, "name": "Clear"})
		var is_unit_node := func(nid: StringName) -> bool:
			return Registry.get_unit(nid) != null
		var is_tier1_unit := func(nid: StringName) -> bool:
			if not is_unit_node.call(nid):
				return false
			var pts: Array = TechTree.nodes.get(nid, {}).get("parents", [])
			for pid in pts:
				if is_unit_node.call(pid):
					return false
			return true
		var seen := {}
		for node_id in TechTree.nodes:
			var unit_res = Registry.get_unit(node_id)
			if unit_res == null:
				continue
			var parents: Array = TechTree.nodes[node_id].get("parents", [])
			var has_t1_unit_parent := false
			for parent_id in parents:
				if is_tier1_unit.call(parent_id):
					has_t1_unit_parent = true
					break
			if not has_t1_unit_parent:
				continue
			# Editor mode (no LogisticsSystem running) lists every tier-2
			# unit unconditionally so authors can pick pre-researched
			# recipes into sector saves.
			if logistics != null and not TechTree.is_researched(node_id):
				continue
			if seen.has(node_id):
				continue
			seen[node_id] = true
			world_menu_items.append({
				"id": node_id,
				"icon": unit_res.icon,
				"name": unit_res.display_name,
			})
	elif type == "launchpad":
		world_menu_items.append({"id": &"__pick", "icon": null, "name": "Set Sector"})
		world_menu_items.append({"id": &"__launch", "icon": null, "name": "Launch"})
	elif type == "landing_pad":
		world_menu_items.append({"id": &"__slot_0", "icon": null, "name": "Slot 1"})
		world_menu_items.append({"id": &"__slot_1", "icon": null, "name": "Slot 2"})
	elif type == "requestor":
		# Top-level requestor menu — pick which condition kind to set.
		# `__clear` wipes the requestor's condition. The other entries
		# walk the player into a sub-picker (`requestor_resource` →
		# `requestor_amount`).
		world_menu_items.append({"id": &"__clear", "icon": null, "name": "Clear Condition"})
		world_menu_items.append({"id": &"__storage_has", "icon": null, "name": "Storage Has [X] of …"})
		# Only show units_produced when the faced block is a fabricator,
		# to mirror the design's "list varies slightly depending on what
		# block it is facing".
		var lc = main.get_node_or_null("LogisticControlSystem") if main else null
		var faced_anchor: Vector2i = Vector2i(-9999, -9999)
		if lc and lc.has_method("get_faced_block"):
			faced_anchor = lc.get_faced_block(grid_pos)
		var faced_bid: StringName = &""
		if main and main.placed_buildings.has(faced_anchor):
			faced_bid = main.placed_buildings[faced_anchor]
		var faced_data = Registry.get_block(faced_bid) if faced_bid != &"" else null
		if faced_data and faced_data.tags.has("fabricator"):
			world_menu_items.append({"id": &"__units_produced", "icon": null, "name": "[X] Units Produced"})
	elif type == "requestor_resource":
		# Resource picker for "storage_has". Item / fluid list filtered to
		# whatever's currently unlocked in the tech tree.
		var gate_on_research: bool = "require_research" in main and main.require_research
		for item in Registry.items_list:
			if gate_on_research and TechTree.nodes.has(item.id) \
					and not TechTree.is_researched(item.id):
				continue
			world_menu_items.append({"id": item.id, "icon": item.icon, "name": item.display_name})
		for fluid in Registry.fluids_list:
			if gate_on_research and TechTree.nodes.has(fluid.id) \
					and not TechTree.is_researched(fluid.id):
				continue
			world_menu_items.append({"id": fluid.id, "icon": fluid.icon, "name": fluid.display_name})
	elif type == "requestor_amount":
		# Quantised amount tiers. Player picks one — full freeform is out
		# of scope for the world-menu picker (no text input here).
		for amt in [10, 50, 100, 250, 500, 1000, 5000]:
			world_menu_items.append({
				"id": StringName("__amt_%d" % amt),
				"icon": null,
				"name": "%d" % amt,
			})
	elif type == "dispatcher":
		# Action picker for a Logistical Dispatcher. The Manual Toggle
		# entry doesn't need a requestor — it flips the disable bit
		# directly. Stop Block walks the player into a link-picker (the
		# requestor anchor is then chosen by clicking a requestor block
		# in the world).
		world_menu_items.append({"id": &"__clear", "icon": null, "name": "Clear Action"})
		world_menu_items.append({"id": &"__manual_toggle", "icon": null, "name": "Toggle Block Activation"})
		world_menu_items.append({"id": &"__stop_block", "icon": null, "name": "Make Block Stop Working"})
	elif type == "landing_pad_slot":
		world_menu_items.append({"id": &"", "icon": null, "name": "Clear"})
		var gate_on_research: bool = "require_research" in main and main.require_research
		for item in Registry.items_list:
			if not item.conveyable:
				continue
			if gate_on_research and TechTree.nodes.has(item.id) \
					and not TechTree.is_researched(item.id):
				continue
			world_menu_items.append({"id": item.id, "icon": item.icon, "name": item.display_name})
		for fluid in Registry.fluids_list:
			if gate_on_research and TechTree.nodes.has(fluid.id) \
					and not TechTree.is_researched(fluid.id):
				continue
			world_menu_items.append({"id": fluid.id, "icon": fluid.icon, "name": fluid.display_name})
	elif type == "recipe_select":
		var bid: StringName = main.placed_buildings.get(grid_pos, &"")
		var bdata = Registry.get_block(bid)
		world_menu_items.append({"id": &"", "icon": null, "name": "Clear"})
		if bdata and bdata.factory_recipes != null:
			for entry in bdata.factory_recipes:
				if typeof(entry) != TYPE_DICTIONARY:
					continue
				var rid: StringName = StringName(entry.get("id", &""))
				var rname: String = String(entry.get("display_name", String(rid)))
				var icon_tex: Texture2D = null
				var out_dict: Dictionary = entry.get("output", {})
				for out_id in out_dict:
					var it = Registry.get_item_or_fluid(StringName(out_id))
					if it and it.icon:
						icon_tex = it.icon
						break
				world_menu_items.append({"id": rid, "icon": icon_tex, "name": rname})


func open(type: String, grid_pos: Vector2i) -> void:
	world_menu_type = type
	world_menu_pos = grid_pos
	world_menu_hovered = -1
	_build_menu_items(type, grid_pos)
	world_menu_open = true
	# Open the secondary panel for non-storage menus that have stored
	# items; the standalone storage popup shows it itself.
	if type != "storage":
		open_storage_panel(grid_pos)
	else:
		close_storage_panel()
	var bsys := _bs()
	if bsys:
		bsys.queue_redraw()
		if "_popup_overlay" in bsys and bsys._popup_overlay:
			bsys._popup_overlay.queue_redraw()


func open_storage_panel(grid_pos: Vector2i) -> void:
	storage_panel_items.clear()
	storage_panel_hovered = -1
	var bsys := _bs()
	if bsys == null:
		return
	var merged: Dictionary = bsys._collect_block_stored_items(grid_pos)
	for item_id in merged:
		var count: int = int(merged[item_id])
		if count <= 0:
			continue
		# Fluids are tracked separately — keep them out of the item display.
		if Registry.get_fluid(item_id) != null:
			continue
		var it = Registry.get_item(item_id)
		storage_panel_items.append({
			"id": item_id,
			"icon": it.icon if it else null,
			"name": it.display_name if it else String(item_id),
			"count": count,
		})
	if storage_panel_items.is_empty():
		storage_panel_open = false
		return
	storage_panel_pos = grid_pos
	storage_panel_open = true


func close_storage_panel() -> void:
	storage_panel_open = false
	storage_panel_hovered = -1
	storage_panel_items.clear()


func close() -> void:
	world_menu_open = false
	world_menu_hovered = -1
	close_storage_panel()
	var bsys := _bs()
	if bsys:
		bsys.queue_redraw()
		if "_popup_overlay" in bsys and bsys._popup_overlay:
			bsys._popup_overlay.queue_redraw()


## Called by BuildingSystem on a world click when a dispatcher's
## "Stop Block Working" mode has parked its anchor — interprets the
## click as the chosen requestor to link. Returns true if a link was
## made, so the caller can swallow the click.
func try_complete_dispatcher_link(clicked_anchor: Vector2i) -> bool:
	if dispatcher_pending_action != "stop_block":
		return false
	if dispatcher_pending_anchor == Vector2i.ZERO:
		return false
	if main == null or not main.placed_buildings.has(clicked_anchor):
		return false
	var data = Registry.get_block(main.placed_buildings[clicked_anchor])
	if data == null or not data.tags.has("logistic_requestor"):
		return false
	var lc = main.get_node_or_null("LogisticControlSystem")
	if lc == null:
		return false
	lc.link_dispatcher_to_requestor(dispatcher_pending_anchor, clicked_anchor)
	dispatcher_pending_anchor = Vector2i.ZERO
	dispatcher_pending_action = ""
	return true


## Applies the user's click selection on cell `index`. Writes through
## to LogisticsSystem (sorter / duct / constructor / refab / recipe /
## landing-pad slot), to BuildingSystem (archive_holdings + editor-only
## state when no LogisticsSystem is running), or kicks off the
## launchpad / landing-pad sub-flow as appropriate.
func apply_selection(index: int) -> void:
	if index < 0 or index >= world_menu_items.size():
		close()
		return

	var selected_id: StringName = world_menu_items[index]["id"]
	var bsys := _bs()
	var logistics := _logistics()

	if world_menu_type == "storage":
		var item_id: StringName = StringName(world_menu_items[index].get("id", &""))
		if item_id != &"" and bsys:
			bsys._withdraw_block_to_drone(world_menu_pos, item_id)
		return
	if world_menu_type == "sorter":
		if logistics:
			logistics.sorter_filters[world_menu_pos] = selected_id
		elif bsys:
			bsys.editor_sorter_filters[world_menu_pos] = selected_id
	elif world_menu_type == "duct_filter":
		if logistics:
			if selected_id == &"":
				logistics.duct_bridge_filters.erase(world_menu_pos)
			else:
				logistics.duct_bridge_filters[world_menu_pos] = selected_id
	elif world_menu_type == "constructor":
		if logistics:
			if logistics.constructor_state.has(world_menu_pos):
				logistics.constructor_state[world_menu_pos]["selected_block"] = selected_id
				if selected_id != &"":
					logistics.constructor_state[world_menu_pos]["phase"] = "collecting"
		elif bsys:
			bsys.editor_constructor_state[world_menu_pos] = {"selected_block": selected_id}
	elif world_menu_type == "resource_source":
		# Store the chosen item/fluid; the logistics tick emits it forever.
		if logistics:
			logistics.source_resource[world_menu_pos] = selected_id
	elif world_menu_type == "payload_source":
		var kind: String = world_menu_items[index].get("kind", "")
		if selected_id == &"":
			if logistics:
				logistics.source_payload.erase(world_menu_pos)
		elif kind == "unit":
			# Units need a faction — chain into the faction sub-menu.
			payload_source_pending_id = selected_id
			payload_source_pending_anchor = world_menu_pos
			close()
			open("payload_source_faction", payload_source_pending_anchor)
			return
		elif logistics:
			logistics.source_payload[world_menu_pos] = {"id": selected_id, "kind": "block", "team": 0}
	elif world_menu_type == "payload_source_faction":
		# 0 = PLAYER/Lumina, 1 = ENEMY/Ferox (UnitData.Team).
		var team: int = 1 if selected_id == &"__ferox" else 0
		if logistics and payload_source_pending_id != &"":
			logistics.source_payload[payload_source_pending_anchor] = {
				"id": payload_source_pending_id, "kind": "unit", "team": team,
			}
		payload_source_pending_id = &""
		payload_source_pending_anchor = Vector2i.ZERO
		close()
		return
	elif world_menu_type == "archive":
		if bsys:
			bsys.archive_holdings[world_menu_pos] = selected_id
	elif world_menu_type == "refabricator":
		if logistics:
			if not logistics.refabricator_state.has(world_menu_pos):
				logistics.refabricator_state[world_menu_pos] = {
					"phase": "idle",
					"in_unit_id": &"",
					"timer": 0.0,
					"out_unit_id": &"",
					"selected_t2": &"",
				}
			var rs: Dictionary = logistics.refabricator_state[world_menu_pos]
			rs["selected_t2"] = selected_id
			rs["in_unit_id"] = &""
			rs["out_unit_id"] = &""
			rs["timer"] = 0.0
			rs["phase"] = "idle"
		elif bsys:
			bsys.editor_refabricator_state[world_menu_pos] = {"selected_t2": selected_id}
	elif world_menu_type == "recipe_select":
		if logistics:
			logistics.set_factory_recipe(world_menu_pos, selected_id)
	elif world_menu_type == "launchpad":
		var anchor: Vector2i = world_menu_pos
		close()
		if selected_id == &"__pick":
			SaveManager.launchpad_pick_request = {
				"source_sector": SaveManager.active_sector_id,
				"anchor": anchor,
			}
			if SaveManager.active_sector_id != &"":
				SaveManager.save_sector(SaveManager.active_sector_id)
			# Defer the swap so this frame's input processing completes
			# before the tree shifts under us. Uses the parked
			# PlanetSelect instance if one exists.
			SaveManager.call_deferred("swap_scene_to_planet_select")
		elif selected_id == &"__launch":
			var lp_sys = main.get_node_or_null("LaunchpadSystem") if main else null
			if lp_sys and lp_sys.has_method("manual_launch"):
				lp_sys.manual_launch(anchor)
		return

	elif world_menu_type == "landing_pad":
		var anchor_lp: Vector2i = world_menu_pos
		close()
		var slot: int = -1
		if selected_id == &"__slot_0":
			slot = 0
		elif selected_id == &"__slot_1":
			slot = 1
		if slot >= 0:
			landing_pad_pick_slot = slot
			open("landing_pad_slot", anchor_lp)
		return

	elif world_menu_type == "landing_pad_slot":
		if logistics and landing_pad_pick_slot >= 0:
			logistics.set_landing_pad_filter_slot(world_menu_pos, landing_pad_pick_slot, selected_id)
		var slot_anchor: Vector2i = world_menu_pos
		landing_pad_pick_slot = -1
		close()
		open("landing_pad", slot_anchor)
		return

	elif world_menu_type == "requestor":
		# Pick condition kind. Walks the player into a resource picker
		# (storage_has) or amount picker (units_produced).
		var lc = main.get_node_or_null("LogisticControlSystem") if main else null
		var anchor_rq: Vector2i = world_menu_pos
		if selected_id == &"__clear":
			if lc:
				lc.set_requestor_condition(anchor_rq, "", &"", 0.0)
			close()
			return
		if selected_id == &"__storage_has":
			requestor_pending_kind = "storage_has"
			requestor_pending_anchor = anchor_rq
			close()
			open("requestor_resource", anchor_rq)
			return
		if selected_id == &"__units_produced":
			requestor_pending_kind = "units_produced"
			requestor_pending_anchor = anchor_rq
			requestor_pending_resource = &""  # no resource needed
			close()
			open("requestor_amount", anchor_rq)
			return
		close()
		return

	elif world_menu_type == "requestor_resource":
		requestor_pending_resource = selected_id
		var anchor_rr: Vector2i = world_menu_pos
		close()
		open("requestor_amount", anchor_rr)
		return

	elif world_menu_type == "requestor_amount":
		# Decode "__amt_<N>" → integer N. Commit the full condition to
		# the control system and close the chain.
		var lc2 = main.get_node_or_null("LogisticControlSystem") if main else null
		var amount: float = 0.0
		var sid_str: String = String(selected_id)
		if sid_str.begins_with("__amt_"):
			amount = float(sid_str.substr(6).to_int())
		if lc2 and requestor_pending_anchor != Vector2i.ZERO:
			lc2.set_requestor_condition(
				requestor_pending_anchor,
				requestor_pending_kind,
				requestor_pending_resource,
				amount)
		requestor_pending_kind = ""
		requestor_pending_resource = &""
		requestor_pending_anchor = Vector2i.ZERO
		close()
		return

	elif world_menu_type == "dispatcher":
		var lc3 = main.get_node_or_null("LogisticControlSystem") if main else null
		var anchor_dp: Vector2i = world_menu_pos
		if lc3 == null:
			close()
			return
		if selected_id == &"__clear":
			lc3.set_dispatcher_action(anchor_dp, "")
		elif selected_id == &"__manual_toggle":
			lc3.set_dispatcher_action(anchor_dp, "manual_toggle")
			# Flip the bit immediately so the player gets feedback —
			# the menu acts as a toggle button rather than just a mode
			# selector. Re-opening the menu and clicking again flips
			# back.
			lc3.toggle_dispatcher_manual(anchor_dp)
		elif selected_id == &"__stop_block":
			lc3.set_dispatcher_action(anchor_dp, "stop_block")
			# Park the anchor for the link-picker. Player's next world
			# click on a requestor will resolve to a link via
			# `try_complete_dispatcher_link`.
			dispatcher_pending_anchor = anchor_dp
			dispatcher_pending_action = "stop_block"
		close()
		return

	close()


func cell_dim() -> Vector2:
	var ssf: float = main.SPRITE_SCALE_FACTOR if main else 1.0
	if world_menu_type == "archive":
		return Vector2(160.0, 26.0) * ssf
	if world_menu_type == "recipe_select":
		return Vector2(140.0, 36.0) * ssf
	if world_menu_type == "landing_pad_slot":
		return Vector2(140.0, 32.0) * ssf
	if world_menu_type == "launchpad" or world_menu_type == "landing_pad":
		return Vector2(220.0, 32.0) * ssf
	return Vector2(world_menu_cell_size, world_menu_cell_size)


func col_count() -> int:
	if world_menu_type == "archive":
		return 1
	if world_menu_type == "recipe_select":
		return 1
	if world_menu_type == "landing_pad_slot":
		return 1
	if world_menu_type == "launchpad" or world_menu_type == "landing_pad":
		return 1
	return world_menu_columns


func get_resource_panel_rect_for(grid_pos: Vector2i, items: Array) -> Rect2:
	if items.is_empty() or main == null:
		return Rect2()
	var dim: Vector2 = Vector2(world_menu_cell_size, world_menu_cell_size)
	var cols: int = mini(world_menu_columns, items.size())
	var rows: int = ceili(float(items.size()) / float(cols))
	var padding := 6.0
	var menu_w: float = cols * dim.x + padding * 2.0
	var menu_h: float = rows * dim.y + padding * 2.0
	var data = Registry.get_block(main.placed_buildings.get(grid_pos, &""))
	var gs: Vector2i = data.grid_size if data else Vector2i(1, 1)
	var anchor_world: Vector2 = main.grid_to_world(Vector2i(grid_pos.x + gs.x, grid_pos.y))
	return Rect2(anchor_world, Vector2(menu_w, menu_h))


func get_storage_panel_rect() -> Rect2:
	if not storage_panel_open:
		return Rect2()
	var rect := get_resource_panel_rect_for(storage_panel_pos, storage_panel_items)
	if world_menu_open:
		var top := get_world_menu_rect()
		if top.size != Vector2.ZERO:
			rect.position.y = top.position.y + top.size.y + 6.0
	return rect


func get_world_menu_rect() -> Rect2:
	if not world_menu_open or world_menu_items.is_empty() or main == null:
		return Rect2()
	if world_menu_type == "storage":
		return get_resource_panel_rect_for(world_menu_pos, world_menu_items)
	var dim: Vector2 = cell_dim()
	var col_max: int = col_count()
	var cols := mini(col_max, world_menu_items.size())
	var rows := ceili(float(world_menu_items.size()) / float(cols))
	var padding := 6.0
	var menu_w: float = cols * dim.x + padding * 2.0
	var menu_h: float = rows * dim.y + padding * 2.0
	var block_id = main.placed_buildings.get(world_menu_pos, &"")
	var data = Registry.get_block(block_id)
	var gs := Vector2i(1, 1)
	if data:
		gs = data.grid_size
	var block_world: Vector2 = main.grid_to_world(world_menu_pos)
	var block_center_x: float = block_world.x + float(gs.x) * main.GRID_SIZE * 0.5
	var block_top_y: float = block_world.y - 8.0
	var menu_x: float = block_center_x - menu_w * 0.5
	var menu_y: float = block_top_y - menu_h
	return Rect2(menu_x, menu_y, menu_w, menu_h)


func hit_test(world_pos: Vector2) -> int:
	var menu_rect := get_world_menu_rect()
	if not menu_rect.has_point(world_pos):
		return -1
	var padding := 6.0
	var local_x: float = world_pos.x - menu_rect.position.x - padding
	var local_y: float = world_pos.y - menu_rect.position.y - padding
	if local_x < 0.0 or local_y < 0.0:
		return -1
	var dim: Vector2 = cell_dim()
	var col := int(local_x / dim.x)
	var row := int(local_y / dim.y)
	var cols := mini(col_count(), world_menu_items.size())
	if col < 0 or col >= cols:
		return -1
	var idx := row * cols + col
	if idx < 0 or idx >= world_menu_items.size():
		return -1
	return idx


func storage_hit_test(world_pos: Vector2) -> int:
	if not storage_panel_open:
		return -1
	var rect := get_storage_panel_rect()
	if not rect.has_point(world_pos):
		return -1
	var padding := 6.0
	var local_x: float = world_pos.x - rect.position.x - padding
	var local_y: float = world_pos.y - rect.position.y - padding
	if local_x < 0.0 or local_y < 0.0:
		return -1
	var dim: float = world_menu_cell_size
	var col := int(local_x / dim)
	var row := int(local_y / dim)
	var cols: int = mini(world_menu_columns, storage_panel_items.size())
	if col < 0 or col >= cols:
		return -1
	var idx := row * cols + col
	if idx < 0 or idx >= storage_panel_items.size():
		return -1
	return idx


func draw_storage_panel(ci: CanvasItem) -> void:
	if not storage_panel_open:
		return
	var bsys := _bs()
	if bsys == null:
		return
	# Re-pull counts each frame so the display animates live.
	storage_panel_items.clear()
	var merged: Dictionary = bsys._collect_block_stored_items(storage_panel_pos)
	for item_id in merged:
		var count: int = int(merged[item_id])
		if count <= 0:
			continue
		# Fluids are tracked separately — keep them out of the item display.
		if Registry.get_fluid(item_id) != null:
			continue
		var it = Registry.get_item(item_id)
		storage_panel_items.append({
			"id": item_id,
			"icon": it.icon if it else null,
			"name": it.display_name if it else String(item_id),
			"count": count,
		})
	if storage_panel_items.is_empty():
		storage_panel_open = false
		return
	var rect := get_storage_panel_rect()
	var padding := 6.0
	var dim: float = world_menu_cell_size
	var cols: int = mini(world_menu_columns, storage_panel_items.size())

	ci.draw_rect(rect, Color(0.08, 0.08, 0.1, 0.92), true)
	ci.draw_rect(rect, Color(0.4, 0.4, 0.5, 0.8), false, 1.5)

	var origin := rect.position + Vector2(padding, padding)
	for i in storage_panel_items.size():
		var col := i % cols
		var row := i / cols
		var cell_pos := origin + Vector2(col * dim, row * dim)
		var cell_rect := Rect2(cell_pos, Vector2(dim, dim))
		if i == storage_panel_hovered:
			ci.draw_rect(cell_rect, Color(0.3, 0.5, 0.8, 0.5), true)
		ci.draw_rect(cell_rect, Color(0.25, 0.25, 0.3, 0.6), false, 1.0)
		var entry: Dictionary = storage_panel_items[i]
		var icon_tex: Texture2D = entry.get("icon")
		if icon_tex:
			var icon_margin := 4.0
			var icon_rect := Rect2(
				cell_pos + Vector2(icon_margin, icon_margin),
				Vector2(dim - icon_margin * 2.0, dim - icon_margin * 2.0)
			)
			ci.draw_texture_rect(icon_tex, icon_rect, false)
		var font_c := ThemeDB.fallback_font
		var font_sz_c := 11
		var count_str: String = str(int(entry.get("count", 0)))
		var tsz: Vector2 = font_c.get_string_size(count_str, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_c)
		var pad := 2.0
		var tx := cell_pos.x + dim - tsz.x - pad
		var ty := cell_pos.y + dim - pad
		ci.draw_string(font_c, Vector2(tx + 1, ty + 1), count_str,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_c, Color(0, 0, 0, 0.85))
		ci.draw_string(font_c, Vector2(tx, ty), count_str,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_c, Color.WHITE)


func draw_world_menu(ci: CanvasItem) -> void:
	if not world_menu_open:
		return
	var bsys := _bs()
	if bsys == null:
		return
	var logistics := _logistics()
	# Auto-open the storage side-panel if the block has stored items and
	# the side panel isn't already up.
	if world_menu_type != "storage" and not storage_panel_open:
		var has_stored: bool = bsys.has_method("_block_has_any_stored") and bsys._block_has_any_stored(world_menu_pos)
		if has_stored:
			open_storage_panel(world_menu_pos)
	# Launchpad: refresh both row labels every frame so the player sees
	# the live destination + the launch-readiness diagnostic / cooldown.
	if world_menu_type == "launchpad":
		var lp_sys = main.get_node_or_null("LaunchpadSystem") if main else null
		if lp_sys and world_menu_items.size() >= 2:
			var sel: StringName = &""
			if lp_sys.has_method("get_selected_sector"):
				sel = lp_sys.get_selected_sector(world_menu_pos)
			if sel == &"":
				world_menu_items[0]["name"] = "<no sector selected>"
			else:
				var sec = Registry.get_sector(sel)
				var sector_text: String = sec.display_name if sec else String(sel)
				world_menu_items[0]["name"] = "Launching To: %s" % sector_text
			var diag: String = ""
			if lp_sys.has_method("diagnose_launch"):
				diag = lp_sys.diagnose_launch(world_menu_pos, 20, 10.0)
			if diag == "":
				world_menu_items[1]["name"] = "Launch — ready"
			else:
				world_menu_items[1]["name"] = "Launch — %s" % diag
	elif world_menu_type == "landing_pad":
		var filter: Array = []
		if logistics and logistics.has_method("get_landing_pad_filter"):
			filter = logistics.get_landing_pad_filter(world_menu_pos)
		for i in range(world_menu_items.size()):
			var sn: StringName = filter[i] if i < filter.size() else &""
			var label: String = "Empty"
			if sn != &"":
				var res = Registry.get_item_or_fluid(sn)
				label = res.display_name if res else String(sn)
			world_menu_items[i]["name"] = "Slot %d: %s" % [i + 1, label]
	# Storage popup is read-only and lives — rebuild item list each frame
	# so counts animate.
	if world_menu_type == "storage":
		world_menu_items.clear()
		var merged: Dictionary = bsys._collect_block_stored_items(world_menu_pos)
		for item_id in merged:
			var count: int = int(merged[item_id])
			if count <= 0:
				continue
			# Fluids are tracked separately — keep them out of the item display.
			if Registry.get_fluid(item_id) != null:
				continue
			var it = Registry.get_item(item_id)
			world_menu_items.append({
				"id": item_id,
				"icon": it.icon if it else null,
				"name": it.display_name if it else String(item_id),
				"count": count,
			})
		if world_menu_items.is_empty():
			close()
			return
	if world_menu_items.is_empty():
		return
	var menu_rect := get_world_menu_rect()
	var padding := 6.0
	var dim: Vector2 = cell_dim()
	var cols := mini(col_count(), world_menu_items.size())

	# Resolve the currently-selected id (for highlight) once.
	var selected_archive: StringName = &""
	if world_menu_type == "archive":
		selected_archive = StringName(bsys.archive_holdings.get(world_menu_pos, &""))
	var selected_sorter: StringName = &""
	if world_menu_type == "sorter" and logistics:
		selected_sorter = StringName(logistics.sorter_filters.get(world_menu_pos, &""))
	var selected_duct_filter: StringName = &""
	if world_menu_type == "duct_filter" and logistics:
		selected_duct_filter = StringName(logistics.duct_bridge_filters.get(world_menu_pos, &""))
	var selected_recipe: StringName = &""
	if world_menu_type == "recipe_select" and logistics:
		selected_recipe = StringName(logistics.factory_recipe_state.get(world_menu_pos, &""))

	var bg_fill: Color = Color(0.08, 0.08, 0.1, 0.92)
	var bg_border: Color = Color(0.4, 0.4, 0.5, 0.8)
	var border_width: float = 1.5
	if world_menu_type == "launchpad" or world_menu_type == "landing_pad":
		bg_fill = Color(0.06, 0.08, 0.12, 0.92)
		bg_border = Color(1.0, 0.85, 0.2, 0.6)
		border_width = 1.0
	ci.draw_rect(menu_rect, bg_fill, true)
	ci.draw_rect(menu_rect, bg_border, false, border_width)

	var origin := menu_rect.position + Vector2(padding, padding)
	for i in world_menu_items.size():
		var col := i % cols
		var row := i / cols
		var cell_pos := origin + Vector2(col * dim.x, row * dim.y)
		var cell_rect := Rect2(cell_pos, dim)

		if i == world_menu_hovered:
			var hover_color: Color = Color(0.3, 0.5, 0.8, 0.5)
			if world_menu_type == "launchpad" or world_menu_type == "landing_pad":
				hover_color = Color(1.0, 0.85, 0.2, 0.2)
			ci.draw_rect(cell_rect, hover_color, true)

		var entry_id: StringName = StringName(world_menu_items[i].get("id", &""))
		var is_selected: bool = false
		if world_menu_type == "archive":
			is_selected = entry_id == selected_archive and entry_id != &""
		elif world_menu_type == "sorter":
			is_selected = entry_id == selected_sorter and entry_id != &""
		elif world_menu_type == "duct_filter":
			is_selected = entry_id == selected_duct_filter and entry_id != &""
		elif world_menu_type == "recipe_select":
			is_selected = entry_id == selected_recipe and entry_id != &""
		if is_selected:
			# Fill the selected recipe row with a blue background so the
			# active recipe reads at a glance (other pickers use just a
			# border, but recipe rows are wide text rows that benefit from
			# a solid highlight).
			if world_menu_type == "recipe_select":
				ci.draw_rect(cell_rect, Color(0.3, 0.5, 0.8, 0.55), true)
			ci.draw_rect(cell_rect, Color(0.35, 0.65, 1.0, 1.0), false, 2.0)
		elif world_menu_type == "launchpad" or world_menu_type == "landing_pad":
			pass
		else:
			ci.draw_rect(cell_rect, Color(0.25, 0.25, 0.3, 0.6), false, 1.0)

		var entry: Dictionary = world_menu_items[i]

		if (world_menu_type == "sorter" or world_menu_type == "archive" or world_menu_type == "duct_filter") and i == 0:
			var cx := cell_pos.x + dim.x * 0.5
			var cy := cell_pos.y + dim.y * 0.5
			var hs: float = minf(dim.x, dim.y) * 0.25
			ci.draw_line(Vector2(cx - hs, cy - hs), Vector2(cx + hs, cy + hs), Color(1.0, 0.3, 0.3), 2.0)
			ci.draw_line(Vector2(cx + hs, cy - hs), Vector2(cx - hs, cy + hs), Color(1.0, 0.3, 0.3), 2.0)
			continue

		var icon_tex: Texture2D = entry.get("icon")
		if icon_tex:
			var icon_margin := 4.0
			var icon_rect := Rect2(
				cell_pos + Vector2(icon_margin, icon_margin),
				Vector2(dim.x - icon_margin * 2.0, dim.y - icon_margin * 2.0)
			)
			ci.draw_texture_rect(icon_tex, icon_rect, false)
		else:
			var font := ThemeDB.fallback_font
			var font_size := 11
			var full_name: String = entry.get("name", "?")
			var side_pad := 6.0
			var avail_w: float = dim.x - side_pad * 2.0
			if world_menu_type == "archive":
				var text_pos := cell_pos + Vector2(side_pad, dim.y * 0.5 + font_size * 0.35)
				ci.draw_string(font, text_pos, full_name, HORIZONTAL_ALIGNMENT_LEFT, avail_w, font_size, Color.WHITE)
			elif world_menu_type == "launchpad" or world_menu_type == "landing_pad" \
					or world_menu_type == "recipe_select" or world_menu_type == "landing_pad_slot":
				var lp_font_size := 13
				var text_pos := cell_pos + Vector2(side_pad, dim.y * 0.5 + lp_font_size * 0.35)
				ci.draw_string(font, text_pos, full_name, HORIZONTAL_ALIGNMENT_CENTER, avail_w, lp_font_size, Color.WHITE)
			else:
				var short_name: String = full_name.left(4)
				var text_pos := cell_pos + Vector2(4.0, dim.y * 0.65)
				ci.draw_string(font, text_pos, short_name, HORIZONTAL_ALIGNMENT_LEFT, avail_w, 10, Color.WHITE)

		if world_menu_type == "storage" and entry.has("count"):
			var font_c := ThemeDB.fallback_font
			var font_sz_c := 11
			var count_str: String = str(entry["count"])
			var tsz: Vector2 = font_c.get_string_size(count_str, HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_c)
			var pad := 2.0
			var tx := cell_pos.x + dim.x - tsz.x - pad
			var ty := cell_pos.y + dim.y - pad
			ci.draw_string(font_c, Vector2(tx + 1, ty + 1), count_str,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_c, Color(0, 0, 0, 0.85))
			ci.draw_string(font_c, Vector2(tx, ty), count_str,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_sz_c, Color.WHITE)
