extends Node
class_name ArchiveDecoderSystem

## Owns the per-anchor "in-progress decode" state for archive_decoder
## blocks and the per-frame tick that advances them. Lifted out of
## BuildingSystem so the 12 K-line file has one less self-contained
## subsystem on its plate.
##
## States dict shape: Vector2i anchor -> {
##   "archive_id": StringName,  # what we're currently decoding
##   "progress":   float,       # seconds elapsed in this cycle
##   "scanner":    Vector2i,    # which scanner is feeding us
## }


# Per-decoder state. Public so HUD tooltips and save / load can peek
# at it directly — same access pattern BuildingSystem exposed before.
var states: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func _process(delta: float) -> void:
	# Skip while the world is paused so progress doesn't advance while
	# the rest of the simulation is frozen.
	var main_node: Node = get_node_or_null("/root/Main")
	if main_node == null:
		return
	if "world_paused" in main_node and main_node.world_paused:
		return
	_tick(delta)


## Called by BuildingSystem when an archive_decoder block is placed.
## Seeds an empty state entry so the per-frame tick has somewhere to
## write progress.
func register(anchor: Vector2i) -> void:
	if states.has(anchor):
		return
	states[anchor] = {
		"archive_id": &"",
		"progress": 0.0,
		"scanner": Vector2i(-9999, -9999),
	}


## Called by BuildingSystem when the decoder is destroyed / removed.
func unregister(anchor: Vector2i) -> void:
	states.erase(anchor)


## Returns the live state dict for a decoder, or an empty Dictionary if
## the anchor isn't a known decoder. HUD tooltip reads this.
func get_state(anchor: Vector2i) -> Dictionary:
	return states.get(anchor, {})


## Ticks every active archive decoder.
##
## A decoder is active when:
##   - it has electrical power
##   - an archive scanner is in one of its 4 cardinal neighbours (and
##     powered)
##   - that scanner's front edge faces an archive block whose
##     archive_id is set (non-empty) and which isn't already researched
##
## When `progress` reaches the decoder's `production_time`, fires
## `Main.archive_decoded(archive_id)` (TechTree picks it up and
## researches the matching `-D-archive_id` marker + dependents) and
## resets state.
func _tick(delta: float) -> void:
	if states.is_empty():
		return
	var main_node: Node = get_node_or_null("/root/Main")
	if main_node == null:
		return
	var building_sys = main_node.get_node_or_null("BuildingSystem")
	if building_sys == null:
		return
	var power_sys = main_node.get_node_or_null("PowerSystem")
	var archive_holdings: Dictionary = building_sys.archive_holdings if "archive_holdings" in building_sys else {}

	for anchor in states.keys():
		if not main_node.placed_buildings.has(anchor):
			states.erase(anchor)
			continue
		var data = Registry.get_block(main_node.placed_buildings.get(anchor, &""))
		if data == null or not data.tags.has("archive_decoder"):
			continue
		var state: Dictionary = states[anchor]

		# 1. Decoder must be powered electrically.
		if power_sys and not power_sys.is_electrical_powered(anchor):
			state["progress"] = 0.0
			state["archive_id"] = &""
			continue

		# 2. Find a touching, powered archive scanner whose front faces
		#    an archive. Multi-tile decoders need to scan their entire
		#    footprint perimeter — the old 4-dir-from-anchor scan only
		#    saw cells next to the top-left tile, so a scanner adjacent
		#    to any other tile of a 3×3 decoder went unrecognised.
		var scanner_pos: Vector2i = Vector2i(-9999, -9999)
		var archive_id: StringName = &""
		var found := false
		var seen_scanners: Dictionary = {}
		var perimeter: Array[Vector2i] = building_sys._get_block_perimeter_cells(anchor, data.grid_size)
		for n in perimeter:
			if not main_node.placed_buildings.has(n):
				continue
			var n_anchor: Vector2i = main_node.building_origins.get(n, n)
			if seen_scanners.has(n_anchor):
				continue
			seen_scanners[n_anchor] = true
			var n_data = Registry.get_block(main_node.placed_buildings.get(n_anchor, &""))
			if n_data == null or not n_data.tags.has("archive_scanner"):
				continue
			if power_sys and not power_sys.is_electrical_powered(n_anchor):
				continue
			var rot: int = main_node.building_rotation.get(n_anchor, 0)
			var front_cells = building_sys._get_front_edge(n_anchor, n_data.grid_size, rot)
			for cell in front_cells:
				if not main_node.placed_buildings.has(cell):
					continue
				var a_anchor: Vector2i = main_node.building_origins.get(cell, cell)
				var a_data = Registry.get_block(main_node.placed_buildings.get(a_anchor, &""))
				if a_data == null or a_data.id != &"archive":
					continue
				var aid: StringName = archive_holdings.get(a_anchor, &"")
				if aid == &"":
					continue
				if TechTree.is_researched(aid):
					continue
				scanner_pos = n_anchor
				archive_id = aid
				found = true
				break
			if found:
				break

		if not found:
			state["progress"] = 0.0
			state["archive_id"] = &""
			continue

		# 3. Track which archive we're decoding (reset progress if it
		#    changed).
		if state.get("archive_id", &"") != archive_id:
			state["archive_id"] = archive_id
			state["progress"] = 0.0
		state["scanner"] = scanner_pos

		# 4. Tick progress.
		var cycle: float = data.production_time if data.production_time > 0 else 8.0
		state["progress"] += delta
		if state["progress"] >= cycle:
			state["progress"] = 0.0
			state["archive_id"] = &""
			if main_node.has_signal("archive_decoded"):
				main_node.archive_decoded.emit(archive_id)
