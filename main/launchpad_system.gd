extends Node
class_name LaunchpadSystem

## Per-launchpad state for cross-sector cargo dispatch. Tracks each
## placed launchpad's currently-selected destination sector, its launch
## cooldown, and the contents of the next pod.
##
## Selection flow (high level):
##   1. Player clicks an idle Launchpad → BuildingSystem opens a custom
##      world menu listing the destination ("<no sector selected>" by
##      default) plus a "Select sector" button.
##   2. "Select sector" → SaveManager.launchpad_pick_request is set
##      with the source sector + anchor, and the planet-select scene is
##      opened. The scene runs in pick-mode: only Tarkon is selectable,
##      sector cards show the name + a "Select sector" button.
##   3. The picked sector id is written back via
##      `set_selected_sector(anchor, sector_id)` once the scene reloads
##      the source sector. The world menu then reads "Launching To: …".
##
## Launch flow:
##   - `can_launch(anchor)` returns true if cooldown is clear, the
##     destination has a Landing Pad somewhere in its saved map, and the
##     pod's buffer covers the 60 copper + 15 steel mandatory cost.
##   - `start_launch(anchor)` snapshots the pod buffer, starts the
##     cooldown, and (placeholder) deposits the buffer into the
##     destination sector's landing-pad payload queue via SaveManager.
##   - The pod animation reuses launch_animation's pipeline with a
##     pod-specific texture (see launch_animation.gd `play_pod_launch`).

const COOLDOWN := 17.5
# Pod build is a power-only recipe — no item cost. While the launchpad
# is fully powered (20 power draw, set in the .tres), `build_timer`
# ticks up to BUILD_TIME seconds; when it hits BUILD_TIME the pod is
# "built" and the launchpad is ready to ship cargo. After a successful
# launch, the timer resets and the cooldown (pause-aware) starts.
const BUILD_TIME := 10.0
# Seconds the pod is "in transit" before it can land. Matches the
# combined launch + land animation life (POD_LIFE 2.0 + POD_LANDING_LIFE
# 2.5) so the player watches the full sequence — pod climbs out of the
# launch pad, then descends onto the landing pad. Cross-sector launches
# bypass this since the player wasn't there to see the takeoff.
const POD_TRAVEL_TIME := 4.5
const PASSENGER_ITEM_CAP := 80
const PASSENGER_FLUID_CAP := 50.0
# Auto-launch thresholds: fires when EITHER the passenger item cap or
# the passenger fluid cap is full. Lets the player commit to either
# kind of cargo without needing both.
const AUTO_LAUNCH_ITEM_THRESHOLD := PASSENGER_ITEM_CAP   # 80
const AUTO_LAUNCH_FLUID_THRESHOLD := PASSENGER_FLUID_CAP # 50.0
# Manual-launch thresholds: the Launch button enables once the pod has
# accumulated EITHER this many items or this much fluid. A pod of pure
# fluid is a valid shipment.
const MANUAL_MIN_ITEMS := 20
const MANUAL_MIN_FLUIDS := 10.0

@onready var main: Node2D = get_node_or_null("/root/Main")

## Vector2i (launchpad anchor) → Dictionary:
##   "selected_sector":   StringName destination sector id (empty = none)
##   "last_launch_at":    float game-time seconds of last successful launch
##   "pod_buffer":        Dictionary item_id → int   pending cargo
##   "pod_fluids":        Dictionary fluid_id → float pending fluid units
var launchpad_state: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func _process(delta: float) -> void:
	# Drives both the pod build timer (advances while the launchpad is
	# fully powered) and the cooldown timer (decrements every tick).
	# Both freeze with the game because LaunchpadSystem runs under
	# PROCESS_MODE_PAUSABLE.
	if main == null:
		return
	if "world_paused" in main and main.world_paused:
		return
	var power_sys = main.get_node_or_null("PowerSystem")
	for cell in main.placed_buildings.keys():
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if anchor != cell:
			continue   # only tick anchor cells of multi-tile launchpads
		if main.placed_buildings.get(anchor, &"") != &"launchpad":
			continue
		if main.get_building_faction(anchor) != main.Faction.LUMINA:
			continue
		var st: Dictionary = get_state(anchor)
		# Cooldown ticks down each frame (pause-aware via PAUSABLE).
		var cd: float = float(st.get("cooldown_remaining", 0.0))
		if cd > 0.0:
			st["cooldown_remaining"] = maxf(0.0, cd - delta)
		# Pod build: ticks up while powered AND the launchpad itself is
		# fully constructed. A half-built pad shouldn't be fabricating
		# a pod — main.building_build_progress holds the entry only
		# while the block is still under construction (the dict entry
		# is erased on completion).
		var bt: float = float(st.get("build_timer", 0.0))
		var pad_fully_built: bool = true
		if "building_build_progress" in main and main.building_build_progress.has(anchor):
			pad_fully_built = false
		if bt < BUILD_TIME and pad_fully_built:
			var eff: float = 1.0
			if power_sys and power_sys.has_method("get_electrical_efficiency"):
				eff = clampf(power_sys.get_electrical_efficiency(anchor), 0.0, 1.0)
			# Only advance with usable power. Zero efficiency (no power
			# at all) leaves the pod stalled rather than crawling at 0×.
			if eff > 0.0:
				# Build progresses proportionally to power efficiency, so
				# a brownout half-power network builds the pod at half speed.
				st["build_timer"] = minf(BUILD_TIME, bt + delta * eff)
		launchpad_state[anchor] = st
		# Auto-launch the moment cargo + power gates AND the auto-launch
		# threshold are met. Manual launches still go through the popup
		# button at the lower thresholds.
		if can_launch(anchor, AUTO_LAUNCH_ITEM_THRESHOLD, AUTO_LAUNCH_FLUID_THRESHOLD):
			start_launch(anchor)
	# Poll the pending-pod queue every tick so same-sector pods (whose
	# `arrival_at` was stamped a few seconds into the future) get drained
	# automatically once their travel time elapses. Cross-sector pods
	# stamp arrival_at=0 and are drained at sector-load by main._ready;
	# this poll is the same-sector equivalent. Function exits cheaply
	# when the queue is empty.
	if main.has_method("_drain_pending_pod_deliveries"):
		main._drain_pending_pod_deliveries()


## Manual-launch trigger fired by the popup's Launch button. Same gate
## as auto-launch except the passenger threshold is the MANUAL minimum
## (20 items + 10.0 fluids of extras) instead of the full passenger cap.
func manual_launch(anchor: Vector2i) -> bool:
	if not can_launch(anchor, MANUAL_MIN_ITEMS, MANUAL_MIN_FLUIDS):
		return false
	return start_launch(anchor)


func get_state(anchor: Vector2i) -> Dictionary:
	if not launchpad_state.has(anchor):
		launchpad_state[anchor] = {
			"selected_sector": &"",
			"cooldown_remaining": 0.0,
			"build_timer": 0.0,
			"pod_buffer": {},
			"pod_fluids": {},
		}
	# Migrate older state dicts that pre-date the build-timer / cooldown
	# refactor. `last_launch_at` (real-time wallclock) is replaced by a
	# `cooldown_remaining` float decremented in `_process` so the
	# cooldown freezes when the game is paused. `mandatory_consumed`
	# (item-based pod cost) is gone — the pod is now power-built.
	var st: Dictionary = launchpad_state[anchor]
	if not st.has("cooldown_remaining"):
		st["cooldown_remaining"] = 0.0
	if not st.has("build_timer"):
		st["build_timer"] = 0.0
	st.erase("mandatory_consumed")
	st.erase("last_launch_at")
	return st


func get_selected_sector(anchor: Vector2i) -> StringName:
	return StringName(get_state(anchor).get("selected_sector", &""))


func set_selected_sector(anchor: Vector2i, sector_id: StringName) -> void:
	var st: Dictionary = get_state(anchor)
	st["selected_sector"] = sector_id
	launchpad_state[anchor] = st


## Returns the pod-build progress 0..1 for the given launchpad. Driven
## by the power-only `build_timer`: 0 when freshly built / launched,
## climbs to BUILD_TIME (10 s) while the launchpad is powered. The
## build-fill animation reads this directly.
func get_pod_build_progress(anchor: Vector2i) -> float:
	var st: Dictionary = get_state(anchor)
	var t: float = float(st.get("build_timer", 0.0))
	if BUILD_TIME <= 0.0:
		return 1.0
	return clampf(t / BUILD_TIME, 0.0, 1.0)


## Pause-aware remaining cooldown in seconds. The state's
## `cooldown_remaining` float is decremented in `_process`, which runs
## under PROCESS_MODE_PAUSABLE — so the cooldown naturally freezes
## while the game is paused.
func cooldown_remaining(anchor: Vector2i) -> float:
	var st: Dictionary = get_state(anchor)
	return maxf(0.0, float(st.get("cooldown_remaining", 0.0)))


## Returns a short human-readable reason the launch is blocked, or the
## empty string if `can_launch(anchor, min_extras, min_fluids)` would
## return true. The launchpad popup surfaces this so the player knows
## which gate to fix.
func diagnose_launch(anchor: Vector2i, min_extras: int = 0, min_fluids: float = 0.0) -> String:
	if main == null:
		return "World not ready"
	var st: Dictionary = get_state(anchor)
	var dest_sn: StringName = StringName(st.get("selected_sector", &""))
	if dest_sn == &"":
		return "Pick a destination sector"
	var cd: float = cooldown_remaining(anchor)
	if cd > 0.0:
		return "Cooldown: %.1f s" % cd
	var logistics = main.get_node_or_null("LogisticsSystem")
	if logistics == null:
		return "Logistics unavailable"
	var storage: Dictionary = logistics.block_storage.get(anchor, {})
	var items: Dictionary = storage.get("items", {})
	var fluids: Dictionary = storage.get("fluids", {})
	# Pod is built over time on power alone; require the build to be
	# complete before a launch is allowed.
	var bt: float = float(st.get("build_timer", 0.0))
	if bt < BUILD_TIME:
		return "Pod building (%d%%)" % int(bt / BUILD_TIME * 100.0)
	if min_extras > 0 or min_fluids > 0.0:
		var extras_count: int = 0
		for k in items:
			extras_count += int(items[k])
		var fluid_total: float = 0.0
		for k in fluids:
			fluid_total += float(fluids[k])
		# EITHER threshold suffices — a pod of pure items or pure fluid
		# is a valid shipment. Only fail when both buckets are below
		# their respective minimums.
		var items_ok: bool = min_extras <= 0 or extras_count >= min_extras
		var fluids_ok: bool = min_fluids <= 0.0 or fluid_total >= min_fluids
		if not items_ok and not fluids_ok:
			return "Need %d items or %.1f fluid units" % [min_extras, min_fluids]
	# Power gate — the build timer already requires a fully-powered
	# launchpad to fill, so by the time a launch is attempted the pad
	# is by definition powered. Just refuse to fire if the network's
	# in a brownout the moment the player presses Launch (e.g. another
	# block came online and pulled too much).
	var power_sys = main.get_node_or_null("PowerSystem")
	if power_sys == null:
		return "No power network"
	if power_sys.has_method("get_electrical_efficiency"):
		var eff: float = power_sys.get_electrical_efficiency(anchor)
		if eff < 0.5:
			return "Brownout — launchpad under-powered"
	# Destination landing pad check.
	if not _destination_has_landing_pad(dest_sn):
		return "No Landing Pad on destination"
	# Filter routing.
	var pod_types: Dictionary = _compute_pod_types(items, fluids)
	var routing: Array = _routing_priority(dest_sn, pod_types)
	if routing.is_empty():
		return "Pod cargo doesn't match any Landing Pad filter"
	return ""


## Conditions that must be true for ANY launch (auto or manual): valid
## selection, cooldown clear, mandatory cost in storage, fully powered,
## destination has a Landing Pad. `min_extras` / `min_fluids` gate the
## passenger cargo so the player can't waste a cooldown shipping an
## empty pod via the Launch button. Implemented as a thin wrapper around
## `diagnose_launch` so the same gate logic drives both pathways.
func can_launch(anchor: Vector2i, min_extras: int = 0, min_fluids: float = 0.0) -> bool:
	return diagnose_launch(anchor, min_extras, min_fluids) == ""


## Distinct item / fluid ids currently in the pod's storage. Returned
## as a Dictionary used as a set (values true). Drives the destination
## filter routing.
func _compute_pod_types(items: Dictionary, fluids: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in items:
		if int(items[k]) > 0:
			out[StringName(k)] = true
	for k in fluids:
		if float(fluids[k]) > 0.0:
			out[StringName(k)] = true
	return out


func start_launch(anchor: Vector2i) -> bool:
	if not can_launch(anchor):
		return false
	var st: Dictionary = get_state(anchor)
	var dest: StringName = StringName(st.get("selected_sector", &""))
	var logistics = main.get_node_or_null("LogisticsSystem")
	if logistics == null:
		return false
	var storage: Dictionary = logistics.block_storage.get(anchor, {})
	var items: Dictionary = storage.get("items", {})
	var fluids: Dictionary = storage.get("fluids", {})
	# Pod is rebuilt over time, so reset the build timer — the next
	# pod won't be ready until BUILD_TIME seconds of powered runtime
	# have elapsed.
	st["build_timer"] = 0.0
	# Compute the pod payload (everything in storage, capped by the
	# passenger limits).
	var pod_items: Dictionary = {}
	var item_total: int = 0
	for k in items.keys():
		var stored_amount: int = int(items[k])
		if stored_amount <= 0:
			continue
		var deliverable: int = mini(stored_amount, PASSENGER_ITEM_CAP - item_total)
		if deliverable <= 0:
			break
		pod_items[k] = deliverable
		items[k] = stored_amount - deliverable
		item_total += deliverable
		if int(items[k]) <= 0:
			items.erase(k)
	var pod_fluids: Dictionary = {}
	var fluid_total: float = 0.0
	for k in fluids.keys():
		var amt_f: float = float(fluids[k])
		if amt_f <= 0.0:
			continue
		var deliverable_f: float = minf(amt_f, PASSENGER_FLUID_CAP - fluid_total)
		if deliverable_f <= 0.0:
			break
		pod_fluids[k] = deliverable_f
		fluids[k] = amt_f - deliverable_f
		fluid_total += deliverable_f
		if float(fluids[k]) <= 0.0:
			fluids.erase(k)
	storage["items"] = items
	storage["fluids"] = fluids
	logistics.block_storage[anchor] = storage
	# Stamp the pause-aware cooldown — _process decrements this.
	st["cooldown_remaining"] = COOLDOWN
	launchpad_state[anchor] = st
	# Compute the routing priority (exact-match pads first, then no-
	# filter pads) and bake it into the pod descriptor. The destination
	# sector's drain walks this list to pick which pad receives the
	# cargo. We freeze the priority at launch time so a stale filter
	# edit on the destination after the pod is in flight doesn't
	# silently redirect it.
	# Compute the routing priority against the actual pod payload (items
	# AFTER mandatory cost was deducted + fluids). Frozen at launch
	# time so a stale filter edit on the destination after the pod is
	# in flight doesn't silently redirect it.
	var pod_types_for_route: Dictionary = {}
	for k in pod_items:
		pod_types_for_route[StringName(k)] = true
	for k in pod_fluids:
		pod_types_for_route[StringName(k)] = true
	var routing: Array = _routing_priority(dest, pod_types_for_route)
	# Queue the pod in SaveManager. The destination sector's logistics
	# picks the queue up at sector-load time and deposits the cargo into
	# the destination Landing Pad's storage / outputs.
	if "pending_pod_deliveries" in SaveManager:
		var queue: Array = SaveManager.pending_pod_deliveries.get(dest, [])
		# `arrival_at` is wall-clock game time (seconds) when the pod
		# should be allowed to land. For cross-sector launches we stamp
		# 0 (already arrived by the time the player re-enters the
		# destination). For same-sector launches we add a short travel
		# time so the player sees the launch + land animations as
		# distinct events instead of the pod magically appearing on
		# the receiving pad in the same frame.
		var now_t: float = Time.get_ticks_msec() / 1000.0
		var same_sector: bool = (dest == SaveManager.active_sector_id)
		var arrival_at: float = (now_t + POD_TRAVEL_TIME) if same_sector else 0.0
		queue.append({
			"items": pod_items,
			"fluids": pod_fluids,
			"from_sector": SaveManager.active_sector_id,
			"routing": routing,
			"arrival_at": arrival_at,
		})
		SaveManager.pending_pod_deliveries[dest] = queue
	# Pod animation: tell launch_animation to play the pod variant for
	# this launchpad. The camera stays on the shardling (vs. core launch
	# which captures the camera onto the core).
	var anim = main.get_node_or_null("LaunchAnimation")
	if anim and anim.has_method("play_pod_launch"):
		anim.play_pod_launch(anchor)
	return true


## Computes the prioritised list of landing-pad anchor strings on the
## destination sector that can receive a pod carrying `pod_types`
## (a Dictionary used as a set — keys are item/fluid ids, values
## ignored). Priority:
##   1. Pads whose filter exactly matches `pod_types` (set equality).
##   2. Pads whose filter is empty (accept any pod).
## Returns an empty array if no pad would accept — the source-side
## launchpad uses this to reject the launch outright.
func _routing_priority(sector_id: StringName, pod_types: Dictionary) -> Array:
	var snap: Dictionary = {}
	if "landing_pad_filters_by_sector" in SaveManager:
		snap = SaveManager.landing_pad_filters_by_sector.get(sector_id, {})
	# Live sector: also consult the in-memory filter dict so newly-edited
	# pads route correctly even before the next save flush.
	if SaveManager.active_sector_id == sector_id and main != null:
		var logistics = main.get_node_or_null("LogisticsSystem")
		if logistics != null and "landing_pad_filters" in logistics:
			snap = {}   # in-memory takes precedence
			for anchor in logistics.landing_pad_filters:
				snap[_anchor_to_key(anchor)] = _ids_to_strings(logistics.landing_pad_filters[anchor])
	# Also enumerate landing pads in the saved sector that have NO
	# filter entry yet (they default to "accept any") so the player can
	# launch to a freshly-placed pad. For cross-sector, parse the saved
	# JSON; for the live sector, walk placed_buildings.
	var all_pad_anchors: Array = _enumerate_landing_pad_anchors(sector_id)
	var exact: Array = []
	var fallback: Array = []
	for anchor_key in all_pad_anchors:
		var filt: Array = snap.get(anchor_key, [])
		var filt_set: Dictionary = {}
		for s in filt:
			if String(s) != "":
				filt_set[StringName(s)] = true
		if filt_set.is_empty():
			fallback.append(anchor_key)
		else:
			# Exact set equality vs pod's type set.
			var equal: bool = filt_set.size() == pod_types.size()
			if equal:
				for k in pod_types:
					if not filt_set.has(k):
						equal = false
						break
			if equal:
				exact.append(anchor_key)
	var out: Array = []
	out.append_array(exact)
	out.append_array(fallback)
	return out


## All landing-pad anchors on `sector_id` as "x,y" strings. Reads the
## live placed_buildings dict for the active sector, otherwise peeks at
## the saved .sector.json (cheap substring scan for the block id).
func _enumerate_landing_pad_anchors(sector_id: StringName) -> Array:
	var out: Array = []
	if SaveManager.active_sector_id == sector_id and main != null:
		for cell in main.placed_buildings:
			if main.building_origins.get(cell, cell) != cell:
				continue
			if main.placed_buildings.get(cell, &"") == &"landing_pad":
				out.append("%d,%d" % [cell.x, cell.y])
		return out
	var path: String = SaveManager.sector_save_path(sector_id)
	if not FileAccess.file_exists(path):
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var raw: String = f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(raw)
	if parsed is Dictionary:
		var blds: Dictionary = parsed.get("buildings", {})
		for key in blds:
			if String(blds[key]) == "landing_pad":
				out.append(String(key))
	return out


func _anchor_to_key(a: Vector2i) -> String:
	return "%d,%d" % [a.x, a.y]




func _ids_to_strings(arr: Array) -> Array:
	var out: Array = []
	for sn in arr:
		out.append(String(sn))
	return out


## True if `sector_id` has at least one Landing Pad block in its saved
## .sector.json. Source-side gate so the player can't queue a launch to
## an unlanded-pad destination. Falls back to checking the active sector
## (if same as dest) via main.placed_buildings.
func _destination_has_landing_pad(sector_id: StringName) -> bool:
	if sector_id == &"":
		return false
	# Active sector: the live placed_buildings dict is authoritative.
	if SaveManager.active_sector_id == sector_id:
		for cell in main.placed_buildings:
			if main.placed_buildings[cell] == &"landing_pad":
				return true
		return false
	# Cross-sector: peek at the saved JSON. SaveManager exposes the path.
	var path: String = SaveManager.sector_save_path(sector_id)
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var raw: String = f.get_as_text()
	f.close()
	# Cheap substring check — full JSON parse for one boolean would burn
	# a lot of memory on a 100k-building save. The block id is unique
	# enough that a false positive is essentially zero.
	return raw.find("\"landing_pad\"") != -1
