extends Node2D

# ============================================================
# MAIN.GD - The root game controller
# ============================================================
# All building data now comes from the Registry and .tres files.
# No more hardcoded enums or dictionaries — adding a new building
# is just creating a new .tres file.
#
# placed_buildings stores StringName IDs (like &"drill")
# instead of enum integers. To look up properties:
#     var data = Registry.get_block(placed_buildings[grid_pos])
#
# MULTI-TILE BUILDINGS:
# building_origins maps every cell of a multi-tile building
# to its "anchor" (top-left corner). When drawing, only the
# anchor cell draws the full-size block; child cells are skipped.
# ============================================================

# --- GRID SETTINGS ---
const GRID_SIZE := 128
## Scales sprite-pixel constants (originally tuned for a 64 px grid) to the
## current GRID_SIZE so heads / items / drone / unit sprites render at the
## same relative size after grid changes.
const SPRITE_SCALE_FACTOR := float(GRID_SIZE) / 64.0
var GRID_WIDTH := 100
var GRID_HEIGHT := 100

# --- RESOURCE TRACKING ---
# Starting resources for the player.
var resources := {
	&"mat_copper": 0,
	&"mat_silicon": 0,
}

# Ferox faction resource pool — items deposited into ferox cores go here.
# Used by ferox core units to rebuild destroyed ferox buildings.
var ferox_resources := {}

# Queue of destroyed ferox buildings waiting to be rebuilt.
# Each entry: { "block_id": StringName, "grid_pos": Vector2i, "rotation": int }
var ferox_rebuild_queue: Array = []

# --- FACTIONS ---
enum Faction { LUMINA, FEROX, DERELICT }

# --- STATE ---
# Now a StringName block ID (e.g. &"drill") or empty &"" for nothing.
var selected_building: StringName = &""
var require_resources := true
var require_research := true
var enemies_attack := true
# Fog-of-war switches set by the map editor's Map Settings dialog and
# serialized into the sector .json. FogSystem reads these on every
# rebuild — disable to skip the system entirely, multiplier scales
# both the unseen and explored alphas (1.0 = default, 0.5 = lighter,
# 1.5 = noticeably darker).
var fog_enabled := true
var fog_darkness_mult := 1.0
## Developer toggle: when true, every entity that can be hit (enemies,
## the player drone, in-flight projectiles) overlays a magenta debug
## hitbox so combat geometry is visible. Wired up from the Developer
## settings tab and from apply_pending_settings on scene load.
var show_hitboxes := false

## Tracks player buildings destroyed by enemies for potential rebuild.
## Key = Vector2i (anchor), Value = { "block_id": StringName, "rotation": int }
var destroyed_player_buildings: Dictionary = {}

## Whether all enemy cores have been destroyed (triggers derelict conversion).
var all_enemy_cores_destroyed := false

# Tracks which grid cells have buildings.
# Key = Vector2i, Value = StringName block ID
var placed_buildings := {}
# Tracks building health.
# Key = Vector2i, Value = current HP (float)
var building_health := {}

# Tracks building rotation (direction it faces).
# Key = Vector2i, Value = int (0=right, 1=down, 2=left, 3=up)
var building_rotation := {}

# MULTI-TILE: Maps every occupied cell → anchor (top-left) position.
# For 1x1 buildings, the anchor IS the cell itself.
# For a 3x3 core at (48,48), cells (48,48) through (50,50) all map to (48,48).
#var building_origins := {}
## Maps every cell of a multi-tile building back to its origin (top-left).
## Key = Vector2i (any occupied cell), Value = Vector2i (origin)
var building_origins := {}

## Tracks which faction owns each building cell.
## Key = Vector2i, Value = int (Faction.LUMINA or Faction.FEROX)
## Missing entries default to LUMINA for backward compatibility.
var building_factions := {}

## Tracks buildings currently under construction.
## Key = Vector2i (anchor), Value = float (seconds elapsed since placement).
## Buildings not in this dict are fully built.
var building_build_progress := {}

## FIFO build order — DEPRECATED, kept for save compat. Use work_order instead.
var build_order: Array[Vector2i] = []

## Set by SaveManager when drone position is restored from a save.
var _drone_position_restored := false

## When true, construction/deconstruction is paused (no progress ticks).
var build_paused := false

## Tracks buildings being deconstructed (reverse build animation).
## Key = Vector2i (anchor), Value = Dictionary {"block_id": StringName, "progress": float, "build_time": float, "rotation": int}
var building_deconstruct_progress := {}

## FIFO deconstruct order — DEPRECATED, kept for save compat. Use work_order instead.
var deconstruct_order: Array[Vector2i] = []

## Unified FIFO work queue — interleaves build and deconstruct operations.
## Only the first entry gets progress each frame. Entries are anchors (Vector2i).
## Check building_build_progress / building_deconstruct_progress to determine
## whether a given anchor is a build or a deconstruct.
var work_order: Array[Vector2i] = []

## Pending same-group replacements (belt → junction, pipe → fluid bridge, …).
## Key = Vector2i (the cell), Value = { "new_block_id", "new_rotation" }.
## The original block stays in placed_buildings and keeps functioning until
## the drone begins work on this cell, at which point the real swap happens.
## Lets drag-placed auto-junctions keep the underlying belt flowing during
## the build.
var pending_swaps := {}

## Paused work anchors. A paused entry stays in work_order at its current
## position but is skipped when picking the next tickable work item, so its
## progress freezes in place.
##
## Values distinguish two kinds of pause:
##   • `true`    — explicit user pause (click on actively-working block).
##                 Only clears when the user clicks the block again.
##   • Vector2i  — auto-pause triggered by promoting a different anchor to
##                 the front of the queue. Clears automatically when that
##                 promoting anchor finishes, so work resumes where the
##                 player left off before the detour.
var work_paused: Dictionary = {}


## Clears any entries in `work_paused` whose auto-resume trigger is the
## given anchor. Call this whenever an anchor is removed from work_order
## (build complete, deconstruct complete, or cancelled) so anything that
## was waiting on it can resume.
func resume_auto_paused_by(anchor: Vector2i) -> void:
	var to_erase: Array = []
	for paused in work_paused:
		var v = work_paused[paused]
		if v is Vector2i and v == anchor:
			to_erase.append(paused)
	for p in to_erase:
		work_paused.erase(p)

## Tracks how much of each resource has been consumed so far for a building
## under construction. Key = Vector2i (anchor), Value = { StringName: int }.
var building_resources_consumed := {}

## Tracks how much of each resource has been refunded so far for a building
## being deconstructed. Key = Vector2i (anchor), Value = { StringName: int }.
var building_resources_refunded := {}

# --- CACHED CHILD NODE REFERENCES ---
# Populated by _refresh_child_cache() at the end of _ready(), but because
# SectorScript / HUD / TechTreeUI are added dynamically at various points,
# every read goes through a `_x_ref()` lazy accessor below that auto-populates
# the first time the child actually exists.
var _hud: Node
var _tech_ui: Node
var _db_ui: Node
var _drone: Node2D
var _unit_mgr: Node
var _terrain: Node2D
var _building_sys: Node
var _logistics: Node2D
var _combat_sys: Node
var _power_sys: Node


func _hud_ref() -> Node:
	if _hud == null:
		_hud = get_node_or_null("HUD")
	return _hud
func _tech_ui_ref() -> Node:
	if _tech_ui == null:
		_tech_ui = get_node_or_null("TechTreeUI")
	return _tech_ui
func _db_ui_ref() -> Node:
	if _db_ui == null:
		_db_ui = get_node_or_null("DatabaseUI")
	return _db_ui
func _drone_ref() -> Node2D:
	if _drone == null:
		_drone = get_node_or_null("PlayerDrone")
	return _drone
func _unit_mgr_ref() -> Node:
	if _unit_mgr == null:
		_unit_mgr = get_node_or_null("UnitManager")
	return _unit_mgr
func _terrain_ref() -> Node2D:
	if _terrain == null:
		_terrain = get_node_or_null("TerrainSystem")
	return _terrain
func _building_sys_ref() -> Node:
	if _building_sys == null:
		_building_sys = get_node_or_null("BuildingSystem")
	return _building_sys
func _logistics_ref() -> Node2D:
	if _logistics == null:
		_logistics = get_node_or_null("LogisticsSystem")
	return _logistics
func _combat_sys_ref() -> Node:
	if _combat_sys == null:
		_combat_sys = get_node_or_null("CombatSystem")
	return _combat_sys
func _power_sys_ref() -> Node:
	if _power_sys == null:
		_power_sys = get_node_or_null("PowerSystem")
	return _power_sys


## Returns true if a blocking UI is open (pause menu, tech tree, database, loss screen).
## Game input (building, mining, unit control) should be suppressed.
func is_ui_blocking() -> bool:
	if sector_lost:
		return true
	var hud := _hud_ref()
	if hud and hud.escape_menu_open:
		return true
	var tech_ui := _tech_ui_ref()
	if tech_ui and tech_ui.is_open:
		return true
	var db_ui := _db_ui_ref()
	if db_ui and db_ui.is_open:
		return true
	if hud and hud.settings_ui and hud.settings_ui.is_open:
		return true
	# Suppress gameplay input during the landing/launch animation until
	# the camera has caught up to the shardling.
	var la = get_node_or_null("LaunchAnimation")
	if la and la.has_method("is_input_locked") and la.is_input_locked():
		return true
	return false

# --- SESSION STATS ---
var stats_blocks_placed := 0
var stats_blocks_removed := 0
var stats_enemy_blocks_destroyed := 0
var stats_units_produced := 0
var stats_units_destroyed := 0
var stats_enemy_units_destroyed := 0
var stats_play_time := 0.0
var sector_lost := false


# Current rotation for the NEXT building placement.
# Player presses Q to cycle this.
var placement_rotation := 0

# Core position (top-left tile of the 3x3 core)
var core_position := Vector2i(48, 48)

## Partial world pause: camera/drone still move, preview works, but no placement,
## units don't move, logistics freeze, items don't enter core.
var world_paused := false

## Per-cell stash of a platform that's been "covered" by another block
## placed on top. Each cell of a covered platform footprint has an entry
## with the platform's block_id, anchor, rotation, faction, and health.
## When the covering block is destroyed, the stash is replayed back into
## placed_buildings so the platform reappears underneath. Lets a player
## build turrets / belts on a platform without losing the platform when
## those blocks are removed.
var _platform_under: Dictionary = {}

## When true (settings: "Pause When Window Loses Focus"), the world is
## auto-paused on `NOTIFICATION_APPLICATION_FOCUS_OUT` and auto-unpaused
## on `NOTIFICATION_APPLICATION_FOCUS_IN` — but ONLY if we're the ones
## who paused it. If the player manually paused before tabbing out, we
## leave the pause state alone on return so a deliberate pause survives
## an alt-tab. Toggle lives in Settings → Game.
var pause_on_unfocus := true
## Set true on focus-out when we auto-paused; cleared on focus-in
## after the auto-unpause fires, or whenever the player manually
## toggles pause (so a deliberate unpause + alt-tab + return doesn't
## get re-paused-then-unpaused inappropriately).
var _auto_paused_by_focus := false

# --- SIGNALS ---
# Several of these are emitted from sibling systems (LogisticsSystem,
# PlayerDrone, BuildingSystem, SectorScript) which call main.<signal>.emit(...).
# GDScript's "unused_signal" warning only inspects the declaring class, so we
# suppress it here since the cross-module emits are legitimate.
signal resources_changed(resources: Dictionary)
@warning_ignore("unused_signal") signal ferox_resources_changed(ferox_resources: Dictionary)
signal building_selected(block_id: StringName)
signal building_placed(block_id: StringName, grid_pos: Vector2i)
signal building_destroyed(grid_pos: Vector2i)
## Fires only when a building is destroyed by enemy fire (HP-driven
## destroy_building call with `by_enemy = true`). Player deconstruction
## / swaps don't emit this. Used by particle_overlay so ruin decals
## only mark blocks the enemy actually killed.
@warning_ignore("unused_signal") signal building_destroyed_by_enemy(grid_pos: Vector2i)
## Fires once a queued build reaches 100% (build_progress >= build_time and
## every input resource fully paid). Distinct from building_placed which
## fires the moment the queue accepts the block — sector-script "placed"
## conditions and similar count gates should listen to this instead so a
## ghost queue doesn't satisfy a "build N drills" goal before the drone
## actually finishes them.
signal building_completed(block_id: StringName, grid_pos: Vector2i)
@warning_ignore("unused_signal") signal item_mined(item_id: StringName)
@warning_ignore("unused_signal") signal item_absorbed_in_core(item_id: StringName)
@warning_ignore("unused_signal") signal core_unit_item_mined(item_id: StringName)
@warning_ignore("unused_signal") signal item_produced(item_id: StringName)
signal sector_launched(sector_id: StringName)
@warning_ignore("unused_signal") signal sector_captured(sector_id: StringName)
@warning_ignore("unused_signal") signal archive_decoded(archive_id: StringName)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Auto-save sector and campaign when the game window is closed
		SaveManager.sync_active_sector_resources()
		if SaveManager.active_sector_id != &"":
			SaveManager.save_sector(SaveManager.active_sector_id)
		SaveManager.save_campaign()
		print("Main: Auto-saved on close.")
		get_tree().quit()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		# Auto-pause when the player tabs away. Mark the auto flag so
		# focus-in knows to undo it. If the player had already manually
		# paused before tabbing out, world_paused is already true and
		# we leave the flag at false — focus-in won't auto-unpause and
		# the deliberate pause survives the alt-tab.
		if pause_on_unfocus and not world_paused and not sector_lost:
			world_paused = true
			_auto_paused_by_focus = true
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		# Mirror the pause: if WE paused on focus-out, undo it now.
		# Otherwise leave the pause alone (manual pause stays).
		if _auto_paused_by_focus:
			_auto_paused_by_focus = false
			if world_paused and not sector_lost:
				world_paused = false


func _ready() -> void:
	# Allow Main to process input even while paused (for space to unpause)
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Wait for Registry ESSENTIALS (items, blocks, units, fluids, tiles) only.
	# Non-essential groups (status_effects, sectors, planets) keep loading in the
	# background after the sector is already playable.
	while not Registry.essentials_loaded:
		await get_tree().process_frame
	await get_tree().process_frame

	# Create SectorScript node for walkthrough/tutorial step execution
	var sector_script_node := SectorScript.new()
	sector_script_node.name = "SectorScript"
	add_child(sector_script_node)

	# WaveManager ticks authored enemy waves. Attached before sector load
	# so SaveManager can pass the deserialized waves straight to it.
	var wave_mgr_scene = load("res://main/wave_manager.gd")
	if wave_mgr_scene:
		var wm = Node.new()
		wm.set_script(wave_mgr_scene)
		wm.name = "WaveManager"
		add_child(wm)

	# Polish layer: sound, camera shake / hit flash, particle overlay.
	# Each is a sibling of every other system; the building / unit /
	# combat code only reads from them, so wiring is one-way.
	var audio_script = load("res://main/audio_system.gd")
	if audio_script:
		var asys = Node.new()
		asys.set_script(audio_script)
		asys.name = "AudioSystem"
		add_child(asys)
	var feedback_script = load("res://main/feedback_system.gd")
	if feedback_script:
		var fsys = Node.new()
		fsys.set_script(feedback_script)
		fsys.name = "FeedbackSystem"
		add_child(fsys)
	var particle_script = load("res://main/particle_overlay.gd")
	if particle_script:
		var psys = Node2D.new()
		psys.set_script(particle_script)
		psys.name = "ParticleOverlay"
		add_child(psys)
	var fog_script = load("res://main/fog_system.gd")
	if fog_script:
		var fog = Node2D.new()
		fog.set_script(fog_script)
		fog.name = "FogSystem"
		add_child(fog)
	var launch_script = load("res://main/launch_animation.gd")
	if launch_script:
		var la = Node2D.new()
		la.set_script(launch_script)
		la.name = "LaunchAnimation"
		add_child(la)

	# Initialize resources from item .tres files
	_init_resources()

	# Load a sector map if one was queued by PlanetSelect
	# (must happen before place_core so core_position is set from the map)
	print("Main._ready: pending_map_path = '%s'" % SaveManager.pending_map_path)
	if SaveManager.pending_map_path != "":
		var path := SaveManager.pending_map_path
		SaveManager.pending_map_path = ""
		print("Main._ready: Loading map from '%s'" % path)
		var ok: bool = SaveManager.load_sector_from_path(path)
		print("Main._ready: load returned %s" % ok)
		print("Main._ready: core_position is now %s" % core_position)
	else:
		print("Main._ready: No pending map")

	resources_changed.emit(resources)
	place_core()
	print("Main._ready: Core placed at %s" % core_position)

	# Move drone to core spawn — but only if the sector save didn't restore a position
	var drone = _drone_ref()
	if drone and drone.has_method("_move_to_core"):
		if not _drone_position_restored:
			drone._move_to_core()

	# Snap the camera onto the drone before the first frame is drawn so
	# the player doesn't see the world spawn at (0, 0) and then teleport
	# in. Mirrors how Mindustry just hands you the camera already framed
	# on your core.
	var cam: Camera2D = get_node_or_null("Camera2D") as Camera2D
	if cam and drone:
		cam.position = drone.position
		# `reset_smoothing` flushes any pending lerp so the very first
		# rendered frame is already centered on the drone instead of
		# easing in from (0,0). force_update_scroll then commits the
		# camera transform this frame.
		if cam.has_method("reset_smoothing"):
			cam.reset_smoothing()
		if cam.has_method("force_update_scroll"):
			cam.force_update_scroll()

	# Stats tracking
	building_placed.connect(func(_bid, _pos): stats_blocks_placed += 1)
	building_destroyed.connect(func(_pos): stats_blocks_removed += 1)

	# Multi-core AI shardlings: every LUMINA core that *isn't* the
	# primary drone's spawn point gets its own AI-controlled drone.
	# These run the priority loop (assist build → shoot enemy → heal
	# block → idle on home core) defined in player_drone.gd.
	# Hook `building_completed` (fires when the build reaches 100%)
	# instead of `building_placed` (fires the moment the queue accepts
	# the ghost) so a new core only gets its shardling AFTER it's
	# actually built — the drone shouldn't appear hovering over a
	# half-finished blueprint.
	_sync_ai_shardlings()
	building_completed.connect(_on_building_completed_for_shardlings)
	building_destroyed.connect(_on_building_destroyed_for_shardlings)

	# Sync resources to global pool whenever they change
	resources_changed.connect(_on_resources_changed_sync)

	# Connect tech tree to game events
	TechTree.connect_to_main(self)

	# Emit sector_launched if we came from planet select
	if SaveManager.pending_sector_id != &"":
		var sid := SaveManager.pending_sector_id
		SaveManager.pending_sector_id = &""
		SaveManager.active_sector_id = sid
		# Apply any resources produced while this sector was idle (offline
		# accrual), then prefer the campaign pool over what came from the
		# .sector.json file — the campaign pool is the authoritative total
		# once accrual has been applied.
		SaveManager.advance_offline_production()
		if SaveManager.sector_resources.has(sid):
			for k in SaveManager.sector_resources[sid]:
				resources[k] = int(SaveManager.sector_resources[sid][k])
			resources_changed.emit(resources)
		# Optional starter pack: per-material amounts the player
		# dialed in on the launch overlay's sliders. Cost was already
		# deducted from the source sector, so we just add to the
		# destination's stockpile here. Cleared immediately so a
		# subsequent return to this sector can't re-seed.
		# starting_grounds bypasses the overlay entirely, so this is a
		# no-op for SG.
		if not SaveManager.pending_seed_pack.is_empty():
			var pack: Dictionary = SaveManager.pending_seed_pack
			SaveManager.pending_seed_pack = {}
			for mat in pack:
				resources[mat] = int(resources.get(mat, 0)) + int(pack[mat])
			resources_changed.emit(resources)
		# Legacy saves can ship with stockpiles that exceed the current
		# core cap (made before the cap existed, or after a core was
		# destroyed mid-session). Trim them immediately so the player
		# doesn't land into an over-cap state.
		clamp_resources_to_cap()
		# Sync starting resources into the global pool for this sector
		SaveManager.sector_resources[sid] = resources.duplicate()
		# Reset the timestamp so offline accrual doesn't double-count the
		# time the player just spent loading in.
		SaveManager.sector_production_timestamps[sid] = Time.get_unix_time_from_system()
		SaveManager.save_campaign()
		sector_launched.emit(sid)

	_refresh_child_cache()

	# Apply user settings that depend on Main's children (camera rotation
	# sensitivity, BuildingSystem parallax, require_research). Load-time
	# application happens in the main menu but those nodes don't exist
	# yet there, so the settings loader stashes the dict and we apply it
	# here once the scene graph is ready.
	var settings_script = load("res://main/settings_ui.gd")
	if settings_script and settings_script.has_method("apply_pending_settings"):
		settings_script.apply_pending_settings()

	# Sector landing animation — plays anywhere the player just
	# launched in (overlay confirmed) AND for starting_grounds first
	# entry (which has no source sector to pay resources from, so it
	# skips the overlay but still wants the touchdown beat). Continue
	# / direct PLAY paths leave `pending_landing_animation` false, so
	# resuming an existing sector skips both animations.
	if SaveManager.pending_landing_animation and core_position != Vector2i(-1, -1):
		var la = get_node_or_null("LaunchAnimation")
		if la and la.has_method("play_landing"):
			la.snapshot_prebuilt()
			la.play_landing(core_position)
	# Consume the flag either way so the next time we re-enter Main
	# without a fresh launch doesn't accidentally inherit it.
	SaveManager.pending_landing_animation = false

	# Launchpad pick-mode result: planet_select wrote {anchor, sector_id}
	# back here after the player picked a destination. Forward it to the
	# LaunchpadSystem so the popup picks up the new label next time it
	# refreshes.
	if "pending_launchpad_pick_result" in SaveManager \
			and not SaveManager.pending_launchpad_pick_result.is_empty():
		var pick: Dictionary = SaveManager.pending_launchpad_pick_result
		SaveManager.pending_launchpad_pick_result = {}
		var lp_sys = get_node_or_null("LaunchpadSystem")
		if lp_sys and lp_sys.has_method("set_selected_sector"):
			lp_sys.set_selected_sector(
				pick.get("anchor", Vector2i.ZERO),
				StringName(pick.get("sector_id", &"")))

	# Drain pending pod deliveries that target this sector. Each pod's
	# cargo is appended to the first Landing Pad's block_storage so the
	# player can pick it up when they return.
	_drain_pending_pod_deliveries()


## Looks up the FIRST Landing Pad in the current sector and deposits any
## pod cargo that was destined for this sector. Cargo lands directly in
## the pad's `block_storage` and stays there until the player pulls it
## off via belts (or via the storage popup). Pods stack — multiple
## deliveries between visits accumulate.
func _drain_pending_pod_deliveries() -> void:
	if not "pending_pod_deliveries" in SaveManager:
		return
	var sid: StringName = SaveManager.active_sector_id
	if sid == &"" or not SaveManager.pending_pod_deliveries.has(sid):
		return
	var queue: Array = SaveManager.pending_pod_deliveries.get(sid, [])
	if queue.is_empty():
		return
	var logistics_n = get_node_or_null("LogisticsSystem")
	if logistics_n == null:
		return
	# Collect every live Landing Pad anchor on the current sector. Used
	# both for routing (does the saved priority list still resolve?)
	# and for fallback (any pad if the routing list is now stale).
	var live_pad_anchors: Array = []
	for cell in placed_buildings:
		if building_origins.get(cell, cell) != cell:
			continue
		if placed_buildings.get(cell, &"") == &"landing_pad":
			live_pad_anchors.append(cell)
	if live_pad_anchors.is_empty():
		# Player removed every landing pad after pods were dispatched —
		# leave the queue alone so the cargo arrives once they rebuild.
		return
	# Per-pod resolution: walk the saved routing list and deposit into
	# the first live pad that has space. Falls back to any live pad if
	# nothing in the routing list resolves (handles cases where the
	# destination's pads were rebuilt with different filters mid-flight).
	var remaining: Array = []
	for pod in queue:
		var routing: Array = pod.get("routing", [])
		var pi: Dictionary = pod.get("items", {})
		var pf: Dictionary = pod.get("fluids", {})
		var target_anchor: Vector2i = _resolve_pod_target(routing, live_pad_anchors)
		if target_anchor == Vector2i(-1, -1):
			# No matching live pad — keep the pod queued so it lands
			# next time the player visits with a valid pad set up.
			remaining.append(pod)
			continue
		if not logistics_n.block_storage.has(target_anchor):
			logistics_n.block_storage[target_anchor] = {"items": {}, "fluids": {}}
		var storage: Dictionary = logistics_n.block_storage[target_anchor]
		var items: Dictionary = storage.get("items", {})
		var fluids: Dictionary = storage.get("fluids", {})
		for k in pi:
			items[StringName(k)] = int(items.get(StringName(k), 0)) + int(pi[k])
		for k in pf:
			fluids[StringName(k)] = float(fluids.get(StringName(k), 0.0)) + float(pf[k])
		storage["items"] = items
		storage["fluids"] = fluids
		logistics_n.block_storage[target_anchor] = storage
		# Pod-landing effect at the receiving pad.
		var anim_n = get_node_or_null("LaunchAnimation")
		if anim_n and anim_n.has_method("play_pod_landing"):
			var pdata = Registry.get_block(placed_buildings.get(target_anchor, &""))
			var gs: float = float(GRID_SIZE)
			var pad_world: Vector2 = grid_to_world(target_anchor) + Vector2(
				float(pdata.grid_size.x) * gs * 0.5 if pdata else gs * 0.5,
				float(pdata.grid_size.y) * gs * 0.5 if pdata else gs * 0.5)
			anim_n.play_pod_landing(pad_world)
	# Re-queue any pods we couldn't resolve; clear the slot if everyone
	# delivered.
	if remaining.is_empty():
		SaveManager.pending_pod_deliveries.erase(sid)
	else:
		SaveManager.pending_pod_deliveries[sid] = remaining


## Resolves a pod's saved routing list (priority Array of "x,y" anchor
## keys) against the sector's live Landing Pad anchors. Walks the list
## in order, returning the first anchor that still exists. Returns
## Vector2i(-1,-1) if no entry in the list resolves to a live pad and
## there's no useful fallback.
func _resolve_pod_target(routing: Array, live_anchors: Array) -> Vector2i:
	var live_set: Dictionary = {}
	for a in live_anchors:
		live_set[a] = true
	for key in routing:
		var s := String(key)
		var parts: PackedStringArray = s.split(",")
		if parts.size() != 2:
			continue
		var v := Vector2i(int(parts[0]), int(parts[1]))
		if live_set.has(v):
			return v
	# Fallback: if the saved routing list went completely stale, deposit
	# into the first live pad anyway so the cargo isn't permanently
	# orphaned. The match was already validated source-side at launch
	# time; this just keeps the player's cargo from disappearing.
	if live_anchors.size() > 0:
		return live_anchors[0]
	return Vector2i(-1, -1)


## Populates the _hud / _tech_ui / etc. cache. Call after the main scene tree
## has its expected children (typically at the end of _ready).
func _refresh_child_cache() -> void:
	_hud = get_node_or_null("HUD")
	_tech_ui = get_node_or_null("TechTreeUI")
	_db_ui = get_node_or_null("DatabaseUI")
	_drone = get_node_or_null("PlayerDrone")
	_unit_mgr = get_node_or_null("UnitManager")
	_terrain = get_node_or_null("TerrainSystem")
	_building_sys = get_node_or_null("BuildingSystem")
	_logistics = get_node_or_null("LogisticsSystem")
	_combat_sys = get_node_or_null("CombatSystem")
	_power_sys = get_node_or_null("PowerSystem")


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("pause_world"):
		if not is_ui_blocking():
			world_paused = not world_paused
			# Manual pause toggle invalidates the focus-auto flag —
			# whatever the player just did is now a deliberate state
			# that focus-in shouldn't override.
			_auto_paused_by_focus = false
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		# Block game input when a UI overlay is open
		if is_ui_blocking():
			return

# Sets up the resources dictionary from all registered items.
# This way new items added as .tres files automatically get a resource slot.
func _init_resources() -> void:
	for item in Registry.items_list:
		if not resources.has(item.id):
			resources[item.id] = 0
		if not ferox_resources.has(item.id):
			ferox_resources[item.id] = 0


## Keeps the global resource pool in sync with in-game resource changes.
## Also trims against the per-resource cap as a defensive net — if anything
## ever slips past `can_accept_resource`, this catches it before the
## over-cap value gets mirrored into the campaign pool.
func _on_resources_changed_sync(_res: Dictionary) -> void:
	var cap: int = get_storage_cap_per_resource()
	if cap > 0:
		var trimmed := false
		for item_id in resources.keys():
			if int(resources[item_id]) > cap:
				resources[item_id] = cap
				trimmed = true
		if trimmed:
			# Re-emit so UI reflects the trim. The next trip through this
			# function finds nothing to trim and is a no-op, so this
			# terminates after one round.
			resources_changed.emit(resources)
			return
	if SaveManager.active_sector_id != &"":
		SaveManager.sector_resources[SaveManager.active_sector_id] = resources.duplicate()


# =========================
# BUILDING FUNCTIONS
# =========================

func select_building(block_id: StringName) -> void:
	selected_building = block_id
	building_selected.emit(block_id)


# Checks if the player can afford a block using its .tres data.
## Resolves a build_cost key (like "copper") to the matching resources key
## (like "mat_copper"). Tries the raw key first, then prepends "mat_".
func _resolve_resource_key(cost_key: String) -> StringName:
	var sn := StringName(cost_key)
	if resources.has(sn):
		return sn
	var mat_sn := StringName("mat_" + cost_key)
	if resources.has(mat_sn):
		return mat_sn
	return sn  # Fallback — will miss, but at least doesn't crash


func can_afford(block_id: StringName) -> bool:
	if not require_resources:
		return true
	var data = Registry.get_block(block_id)
	if data == null:
		return false
	for item_id in data.build_cost:
		var rk := _resolve_resource_key(str(item_id))
		if not resources.has(rk) or resources[rk] < int(data.build_cost[item_id]):
			return false
	return true


func is_cell_empty(grid_pos: Vector2i) -> bool:
	if not placed_buildings.has(grid_pos):
		return true
	# Platforms are treated as terrain — buildings can be placed on top.
	# The covering block goes into placed_buildings as usual; the platform's
	# data is stashed in `_platform_under` and restored on destroy.
	return _is_platform_block_id(placed_buildings[grid_pos])


## Returns true if the given block id has the `platform` tag.
func _is_platform_block_id(block_id: StringName) -> bool:
	var d = Registry.get_block(block_id)
	return d != null and d.tags.has("platform")


## Returns true if the terrain under a building's footprint accepts the
## block. Mirrors the rules in `BuildingSystem._can_place_terrain` so the
## preview's red overlay matches what `try_place_building` / `place_building_for_schematic`
## actually enforce — without this, the preview rejection was advisory
## only and the placement still went through.
##
## Rules (per-cell):
##   - Void (no floor, no wall): reject everything except a cell that
##     already has a platform under it.
##   - Water (depth > 0): platforms accept any depth; pumps accept
##     depths 1–2; everything else rejects unless a platform is under.
##   - Platforms additionally reject dry land (depth 0) — they're
##     water-only bridging blocks.
func _terrain_accepts_at(grid_pos: Vector2i, data: BlockData) -> bool:
	if data == null:
		return false
	var terrain = _terrain_ref()
	if terrain == null:
		return true
	var is_platform: bool = data.tags.has("platform")
	var is_pump: bool = data.tags.has("pump")
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var cell: Vector2i = grid_pos + Vector2i(x, y)
			# A live platform at this cell counts as "dry ground" — it
			# bridges whatever's underneath. Don't allow another
			# platform on top of it (platforms don't stack).
			var has_platform_under: bool = false
			if placed_buildings.has(cell):
				var existing_id: StringName = placed_buildings[cell]
				if existing_id != data.id and _is_platform_block_id(existing_id):
					if is_platform:
						return false
					has_platform_under = true
			if has_platform_under:
				continue
			if terrain.has_method("is_void") and terrain.is_void(cell):
				return false
			var depth: int = 0
			if terrain.has_method("get_water_depth_at"):
				depth = int(terrain.get_water_depth_at(cell))
			if is_platform and depth <= 0:
				return false
			if depth > 0:
				if is_platform:
					pass
				elif is_pump and depth <= 2:
					pass
				else:
					return false
	return true


## Captures platform info for every cell in the rect about to be written
## by a placement. Each platform cell gets its block_id / anchor /
## rotation / faction / current health stashed in `_platform_under` so
## the platform can be replayed back into placed_buildings when the
## covering block is destroyed.
func _stash_covered_platforms(origin: Vector2i, size: Vector2i) -> void:
	for x in range(size.x):
		for y in range(size.y):
			var cell: Vector2i = origin + Vector2i(x, y)
			if not placed_buildings.has(cell):
				continue
			var existing_id: StringName = placed_buildings[cell]
			if not _is_platform_block_id(existing_id):
				continue
			var p_anchor: Vector2i = building_origins.get(cell, cell)
			_platform_under[cell] = {
				"block_id": existing_id,
				"anchor": p_anchor,
				"rotation": building_rotation.get(cell, 0),
				"faction": building_factions.get(cell, Faction.LUMINA),
				"health": float(building_health.get(p_anchor, 0.0)),
			}


## After a building is destroyed, replays any stashed-platform info for
## its footprint cells back into placed_buildings / origins / rotations
## / factions / health. The platform reappears as if the cover was
## never there.
func _restore_platforms_at(cells: Array) -> void:
	# A stash is only worth restoring if its platform anchor will still
	# exist after this call — either it's already alive in placed_buildings
	# (the cover sat on a non-anchor cell, so the rest of the platform was
	# never erased) or this same restore will revive it (the cover sat on
	# the anchor cell). Without this guard, destroying a platform that
	# still had a covered cell would re-create a "ghost" platform cell
	# with building_origins pointing at a now-empty anchor — corrupting
	# any iteration like placed_buildings[building_origins[cell]].
	var alive_anchors: Dictionary = {}
	for cell in cells:
		if not _platform_under.has(cell):
			continue
		var p_anchor: Vector2i = _platform_under[cell].get("anchor", cell)
		if placed_buildings.has(p_anchor) and _is_platform_block_id(placed_buildings[p_anchor]):
			alive_anchors[p_anchor] = true
		if cell == p_anchor:
			alive_anchors[p_anchor] = true

	for cell in cells:
		if not _platform_under.has(cell):
			continue
		var stash: Dictionary = _platform_under[cell]
		_platform_under.erase(cell)
		var p_block_id: StringName = StringName(stash.get("block_id", &""))
		if p_block_id == &"":
			continue
		var p_anchor: Vector2i = stash.get("anchor", cell)
		if not alive_anchors.has(p_anchor):
			# Platform is gone — discard the stash rather than leaving an
			# orphan cell whose origin points to nothing.
			continue
		placed_buildings[cell] = p_block_id
		building_origins[cell] = p_anchor
		building_rotation[cell] = int(stash.get("rotation", 0))
		building_factions[cell] = int(stash.get("faction", Faction.LUMINA))
		# Only restore health when no other entry already owns the
		# anchor (e.g. another covering block whose anchor coincides).
		# Saves the platform's last-known HP across cover/uncover.
		if not building_health.has(p_anchor):
			building_health[p_anchor] = float(stash.get("health", 0.0))


## Returns true if the platform anchored at `anchor` has any of its
## footprint cells currently covered by a non-platform block. Used by
## `start_deconstruct` to refuse a platform decon while there's still
## something built on top.
func _platform_has_cover(anchor: Vector2i) -> bool:
	if not placed_buildings.has(anchor):
		return false
	var data = Registry.get_block(placed_buildings[anchor])
	if data == null or not data.tags.has("platform"):
		return false
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var cell: Vector2i = anchor + Vector2i(x, y)
			# A covered cell has a different block_id (the cover), and
			# the platform's data is stashed in `_platform_under`.
			if _platform_under.has(cell):
				return true
	return false


## Returns the anchor (top-left) position for a building at grid_pos.
## Returns null if no building exists there.
func get_building_anchor(grid_pos: Vector2i) -> Variant:
	if building_origins.has(grid_pos):
		return building_origins[grid_pos]
	return null


## Returns true if this cell is the anchor (top-left) of its building.
## For 1x1 buildings this is always true. For multi-tile, only the
## top-left cell returns true.
func is_building_anchor(grid_pos: Vector2i) -> bool:
	if not building_origins.has(grid_pos):
		return false
	return building_origins[grid_pos] == grid_pos


## Returns the faction of the building at grid_pos.
## Defaults to LUMINA if not set (backward compat with old saves).
func get_building_faction(grid_pos: Vector2i) -> int:
	return building_factions.get(grid_pos, Faction.LUMINA)


## Returns every LUMINA core anchor currently on the grid. Used when the
## drone needs to address "any of my cores" rather than the original
## spawn core — e.g. depositing mined items or picking a respawn target.
## Excludes cores that are still under construction or actively being
## deconstructed; depositing into them or respawning on top of them
## would either silently lose resources or strand the drone on an
## inactive block.
func get_lumina_core_anchors() -> Array:
	var anchors: Array = []
	for grid_pos in placed_buildings:
		if building_origins.get(grid_pos, grid_pos) != grid_pos:
			continue
		if get_building_faction(grid_pos) != Faction.LUMINA:
			continue
		var data = Registry.get_block(placed_buildings[grid_pos])
		if data == null or not data.tags.has("core"):
			continue
		if is_building_inactive(grid_pos):
			continue
		anchors.append(grid_pos)
	return anchors


## Returns the LUMINA core anchor closest to `world_pos`, or Vector2i(-1, -1)
## if no LUMINA core exists. Used for drone respawn targeting.
func get_nearest_lumina_core_anchor(world_pos: Vector2) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_dist_sq := INF
	for anchor in get_lumina_core_anchors():
		var data = Registry.get_block(placed_buildings[anchor])
		var sz: Vector2i = data.grid_size if data else Vector2i(3, 3)
		var center := Vector2(
			(anchor.x + sz.x / 2.0) * GRID_SIZE,
			(anchor.y + sz.y / 2.0) * GRID_SIZE
		)
		var d_sq: float = world_pos.distance_squared_to(center)
		if d_sq < best_dist_sq:
			best_dist_sq = d_sq
			best = anchor
	return best


## Returns the production multiplier applied to a block at `grid_pos`
## from nearby active "overdrive"-tagged buildings (overdriver,
## overdrive dome, overdrive projector). Picks the strongest overdrive
## whose radius covers the block. Applies only to drills, fluid pumps,
## condensers, and factories — turrets / conveyors / vent turbines /
## combustion gens are excluded explicitly.
##
## The boost multiplier is `data.overdrive_multiplier` directly (so an
## entry of 2.25 = 225 % of base, i.e. "+125 % additional efficiency").
func get_overdrive_multiplier(grid_pos: Vector2i) -> float:
	var data = Registry.get_block(placed_buildings.get(grid_pos, &""))
	if data == null:
		return 1.0
	# Eligibility gate. Drills + factories + pumps + condensers are in;
	# everything else opts out.
	var eligible: bool = false
	if data.category == BlockData.BlockCategory.EXTRACTORS:
		eligible = true
	elif data.category == BlockData.BlockCategory.FACTORIES:
		eligible = true
	elif data.tags.has("pump") or data.tags.has("condenser"):
		eligible = true
	# Hard excludes for blocks that happen to fall in the categories
	# above but the design says shouldn't be boosted.
	if data.category == BlockData.BlockCategory.TURRETS:
		eligible = false
	if data.tags.has("vent_turbine") or data.tags.has("combustion_generator"):
		eligible = false
	if data.is_transport():
		eligible = false
	if not eligible:
		return 1.0
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	var anchor_world: Vector2 = grid_to_world(anchor) \
		+ Vector2(data.grid_size.x * GRID_SIZE * 0.5, data.grid_size.y * GRID_SIZE * 0.5)
	var best: float = 1.0
	for od_pos in placed_buildings:
		if building_origins.get(od_pos, od_pos) != od_pos:
			continue
		var od_data = Registry.get_block(placed_buildings[od_pos])
		if od_data == null or not od_data.tags.has("overdrive"):
			continue
		if od_data.overdrive_radius <= 0.0 or od_data.overdrive_multiplier <= 1.0:
			continue
		if get_building_faction(od_pos) != Faction.LUMINA:
			continue
		if is_building_inactive(od_pos):
			continue
		var od_world: Vector2 = grid_to_world(od_pos) \
			+ Vector2(od_data.grid_size.x * GRID_SIZE * 0.5, od_data.grid_size.y * GRID_SIZE * 0.5)
		var d: float = anchor_world.distance_to(od_world) / float(GRID_SIZE)
		if d <= od_data.overdrive_radius and od_data.overdrive_multiplier > best:
			best = od_data.overdrive_multiplier
	return best


## Returns the per-type unit capacity based on all placed LUMINA cores.
## Each core's `max_active_units` adds to the total. Under-construction
## cores (or cores actively being deconstructed) don't contribute — a
## core has to be fully built before it lifts the cap.
func get_unit_cap_per_type() -> int:
	var cap := 0
	for grid_pos in placed_buildings:
		var block_id: StringName = placed_buildings[grid_pos]
		# Only count anchor cells (avoid counting multi-tile cores multiple times)
		if building_origins.get(grid_pos, grid_pos) != grid_pos:
			continue
		if get_building_faction(grid_pos) != Faction.LUMINA:
			continue
		if is_building_inactive(grid_pos):
			continue
		var data = Registry.get_block(block_id)
		if data and data.max_active_units > 0:
			cap += data.max_active_units
	return cap


## Returns the count of player units of a specific type currently alive.
func get_player_unit_count(unit_id: StringName) -> int:
	var unit_mgr = _unit_mgr_ref()
	if not unit_mgr:
		return 0
	var count := 0
	for unit in unit_mgr.player_units:
		if is_instance_valid(unit) and unit.data and unit.data.id == unit_id:
			count += 1
	return count


## Returns true if another unit of this type can be spawned.
func can_spawn_unit(unit_id: StringName) -> bool:
	return get_player_unit_count(unit_id) < get_unit_cap_per_type()


## Returns the per-resource storage capacity based on all placed LUMINA cores.
## Each core's storage_capacity adds to the total. Under-construction cores
## (or cores actively being deconstructed) don't count toward the cap — a
## core only contributes once it's fully built and operational.
## 0 = no operational cores placed.
func get_storage_cap_per_resource() -> int:
	var cap := 0
	for grid_pos in placed_buildings:
		var block_id: StringName = placed_buildings[grid_pos]
		if building_origins.get(grid_pos, grid_pos) != grid_pos:
			continue
		if get_building_faction(grid_pos) != Faction.LUMINA:
			continue
		if is_building_inactive(grid_pos):
			continue
		var data = Registry.get_block(block_id)
		if data and data.storage_capacity > 0:
			cap += data.storage_capacity
	return cap


## Returns true if the core storage can accept one more of this resource.
func can_accept_resource(item_id: StringName) -> bool:
	# Incinerated items are "accepted" in the sense that the conveyor /
	# drone shouldn't back up — the deposit just disappears. The actual
	# add-to-pool path (try_add_to_resources / _absorb_item) is the one
	# that drops the item.
	if is_incinerated_at_core(item_id):
		return true
	var cap: int = get_storage_cap_per_resource()
	if cap <= 0:
		return true  # No cores = no limit (shouldn't happen in normal gameplay)
	return resources.get(item_id, 0) < cap


## Items that the core consumes without stockpiling. Sand has no use as
## a stored resource (it's industrial waste). Coal is fuel — it's
## supposed to flow into combustion generators, NOT pile up in the core
## pool where it would inflate the global resource readout and skew
## production-rate UI. Centralized so every "deposit into core" path
## (logistics belts, drone flight delivery, drone drag-drop) checks the
## same list.
func is_incinerated_at_core(_item_id: StringName) -> bool:
	# Sand / coal / iron all deposit into the core stockpile now —
	# they used to be treated as industrial waste / fuel-only and
	# disappear on contact with the core, but the gameplay loop wants
	# them counted in the global pool so the launch-overlay sliders
	# (and any other "spend from stockpile" UIs) can see them.
	return false


## Trims every entry in `main.resources` down to the current per-resource
## storage cap. Cheap to call — returns early when everything already
## fits. Meant for situations where the cap can drop out from under an
## existing stockpile (a core getting destroyed is the obvious one) or
## where something sneaks a deposit past can_accept_resource.
func clamp_resources_to_cap() -> void:
	var cap: int = get_storage_cap_per_resource()
	if cap <= 0:
		# No cores = no cap (pre-placement / transient state). Leave
		# resources alone so the first core's placement doesn't zero
		# out any in-flight stockpile.
		return
	var changed := false
	for item_id in resources.keys():
		var amt: int = int(resources[item_id])
		if amt > cap:
			resources[item_id] = cap
			changed = true
	if changed:
		resources_changed.emit(resources)


## Returns how much room is left for a specific resource.
func get_resource_room(item_id: StringName) -> int:
	var cap: int = get_storage_cap_per_resource()
	if cap <= 0:
		return 999999
	return maxi(0, cap - resources.get(item_id, 0))


## Returns build progress as 0.0–1.0 (1.0 = fully built).
## Buildings not in the progress dict are fully built.
func get_build_progress_pct(grid_pos: Vector2i) -> float:
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	if not building_build_progress.has(anchor):
		return 1.0
	var block_id = placed_buildings.get(anchor, &"")
	var data = Registry.get_block(block_id)
	if data == null or data.build_time <= 0:
		return 1.0
	return clampf(building_build_progress[anchor] / data.build_time, 0.0, 1.0)


## Returns true if the building at grid_pos is still under construction.
func is_building_constructing(grid_pos: Vector2i) -> bool:
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	return building_build_progress.has(anchor)


## Returns true if the building should not function (under construction,
## being deconstructed, or derelict). **Every** block type is inactive while
## its construction progress is advancing — including transport (conveyors,
## pipes). Items already on a half-built belt just sit there until the belt
## finishes; new items can't be pushed in. Systems that tick block behavior
## MUST consult this before doing any work on the cell.
func is_building_inactive(grid_pos: Vector2i) -> bool:
	if get_building_faction(grid_pos) == Faction.DERELICT:
		return true
	# Deconstructing buildings are fully inactive
	var anchor_check: Vector2i = building_origins.get(grid_pos, grid_pos)
	if building_deconstruct_progress.has(anchor_check):
		return true
	if is_building_constructing(grid_pos):
		return true
	# Blocks that the landing animation hasn't revealed yet (the yellow
	# ring hasn't crossed them) are inert — they don't tick logistics,
	# don't draw power, don't fire turrets. They flip to active the
	# instant the ring sweeps past them.
	var la = get_node_or_null("LaunchAnimation")
	if la and la.has_method("is_block_hidden") and la.is_block_hidden(anchor_check):
		return true
	return false


## Looser inactive check for conveyor flow. Returns true in every
## case `is_building_inactive` does EXCEPT when the only reason the
## block is inactive is "queued for deconstruction but the drone
## hasn't actually started yet" (progress == 0). Belts use this so
## the items already on a belt keep moving while it sits in the
## deconstruct queue; the moment the drone touches it and progress
## advances past 0, conveying stops.
func is_belt_conveyance_blocked(grid_pos: Vector2i) -> bool:
	if get_building_faction(grid_pos) == Faction.DERELICT:
		return true
	if is_building_constructing(grid_pos):
		return true
	var anchor_check: Vector2i = building_origins.get(grid_pos, grid_pos)
	var dprog = building_deconstruct_progress.get(anchor_check, null)
	if dprog != null and float(dprog.get("progress", 0.0)) > 0.0:
		return true
	var la = get_node_or_null("LaunchAnimation")
	if la and la.has_method("is_block_hidden") and la.is_block_hidden(anchor_check):
		return true
	return false


## Places a building directly without cost/range checks, assigning a specific faction.
## Used by sector loading and the map editor.
func place_building_with_faction(grid_pos: Vector2i, block_id: StringName, rotation: int, faction: int) -> bool:
	var data = Registry.get_block(block_id)
	if data == null:
		return false

	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var tile_pos = grid_pos + Vector2i(x, y)
			if not is_within_bounds(tile_pos):
				return false

	# Health is tracked per-building (anchor only) — multi-tile buildings
	# share a single HP entry instead of one per tile.
	building_health[grid_pos] = data.max_health
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var tile_pos = grid_pos + Vector2i(x, y)
			placed_buildings[tile_pos] = block_id
			building_rotation[tile_pos] = rotation
			building_origins[tile_pos] = grid_pos
			building_factions[tile_pos] = faction

	building_placed.emit(block_id, grid_pos)
	return true


## Returns a swap-group identifier for a block, or &"" if the block isn't
## part of any swappable family. Blocks in the same group can replace each
## other on placement (costing the new block's build_time), so you can e.g.
## replace a Belt Junction with a Conveyor Belt by just clicking on it.
##
## Groups:
##   &"belt_duct"   — conveyor_belt + duct and all their variants (junctions,
##                    routers, sorters, bridges, overflow/underflow). Belts
##                    and ducts share a group so either can swap onto the
##                    other in place.
##   &"conduit"     — fluid conduits and their variants
##   &"payload"     — payload transport parts
##   &"freight"     — freight transport parts
##   &"shaft_power" — shaft, gearbox, overhead belt (legacy power-line group)
func _get_swap_group(data: BlockData) -> StringName:
	if data == null:
		return &""
	var id_str := String(data.id)
	# Belts and ducts share a single swap family so a duct can be
	# dragged over a belt (or vice versa) and replace it in-place,
	# matching how the same family lets bridges swap with junctions.
	if id_str == "conveyor_belt" or id_str.begins_with("belt_") \
			or id_str == "overflow_belt" or id_str == "underflow_belt" \
			or id_str == "inverted_belt_sorter" \
			or id_str == "duct" or id_str.begins_with("duct_") \
			or id_str == "overflow_duct" or id_str == "underflow_duct" \
			or id_str == "inverted_duct_sorter":
		return &"belt_duct"
	# Fluid conduits
	if id_str == "fluid_conduit" or id_str.begins_with("conduit_") \
			or id_str == "overflow_conduit" or id_str == "underflow_conduit" \
			or id_str == "inverted_conduit_sorter":
		return &"conduit"
	# Payload transport
	if id_str == "payload_conveyor" or id_str == "payload_router" \
			or id_str == "payload_loader" or id_str == "payload_unloader":
		return &"payload"
	# Freight transport
	if id_str == "freight_conveyor" or id_str == "freight_router" \
			or id_str == "freight_loader" or id_str == "freight_unloader":
		return &"freight"
	# Legacy shaft/gearbox/overhead-belt group — kept so any existing
	# placements with these block ids still swap among themselves.
	if id_str == "shaft" or id_str == "gearbox" or id_str == "overhead_belt":
		return &"shaft_power"
	# Vent slot blocks: turbine (power) and condenser (water) both
	# occupy the same 3×3 footprint centered on a vent/geyser tile, so
	# the player can swap one for the other in place without tearing
	# the structure down. Restricted to these two ids so a misclick
	# doesn't accidentally absorb anything else into the group.
	if id_str == "vent_turbine" or id_str == "vent_condenser":
		return &"vent_block"
	# Walls form a single group regardless of material — same-size walls
	# can swap (copper ↔ brass ↔ aluminum, etc.). The same-footprint
	# gate at the call site keeps a 1×1 wall from trying to overlay a
	# 3×3 wall and vice versa.
	if data.tags.has("wall"):
		return &"wall"
	# Platforms also form a swap group so a same-size platform of a
	# different material can replace another, and the size-up path
	# below can absorb smaller platforms into a bigger one.
	if data.tags.has("platform"):
		return &"platform"
	return &""


## Swaps an existing same-footprint building for a different one at the
## same cell. Instead of destroying the old block immediately, this
## creates a `pending_swaps` entry that the build tick advances over
## time — the OLD block stays live and functional in placed_buildings
## while the new one's build cost is paid progressively. Each unit of
## new resource paid in is matched by a proportional refund of the old
## block's build_cost, so swapping a half-built belt back to a junction
## doesn't punish the player for changing their mind.
##
## When build progress hits 100% AND every cost item is fully paid, the
## tick calls `execute_pending_swap` which runs the atomic destroy/replace
## (firing all the normal building_destroyed cleanup so logistics state
## is cleared cleanly).
func _swap_building_in_place(grid_pos: Vector2i, old_data: BlockData, new_data: BlockData) -> bool:
	# Re-clicking the same swap target is a no-op — keeps the existing
	# progress instead of resetting to 0.
	if pending_swaps.has(grid_pos):
		var existing: Dictionary = pending_swaps[grid_pos]
		if StringName(existing.get("new_block_id", &"")) == new_data.id \
				and int(existing.get("new_rotation", 0)) == placement_rotation:
			return true
		# Otherwise the player picked a different swap target — refund
		# everything already paid into the previous one before starting
		# the new one (player-spent resources AND any old-pool refund
		# already given gets undone implicitly via the new entry's own
		# pool, but we hand back consumed since they're abandoned).
		_refund_pending_swap(grid_pos, true)
	# Snapshot the old block's build_cost as the refund pool, normalized
	# to the same StringName keys main.resources uses. Refunds happen in
	# `_tick_pending_swap` proportionally to build progress.
	var refund_pool: Dictionary = {}
	if old_data and not old_data.build_cost.is_empty():
		for raw_id in old_data.build_cost:
			var rk: StringName = _resolve_resource_key(str(raw_id))
			refund_pool[rk] = int(old_data.build_cost[raw_id])
	var build_time: float = new_data.build_time if new_data.build_time > 0.0 else 1.0
	pending_swaps[grid_pos] = {
		"new_block_id": new_data.id,
		"new_rotation": placement_rotation,
		"build_time": build_time,
		"progress": 0.0,
		"consumed": {},
		"refund_pool": refund_pool,
		"refunded": {},
	}
	if not work_order.has(grid_pos):
		work_order.append(grid_pos)
	# `building_placed` is intentionally NOT emitted here — the swap
	# hasn't actually placed anything yet. The signal fires when the
	# swap completes via `_execute_swap_now`, which already emits.
	return true


## Refunds whatever portion of an outstanding pending_swap entry hasn't
## been refunded yet. Used when a swap is abandoned mid-build (player
## queued a different swap on top, or deconstructed the cell). Returns
## the items refunded, mostly for testing.
func _refund_pending_swap(grid_pos: Vector2i, also_consumed: bool = false) -> void:
	if not pending_swaps.has(grid_pos):
		return
	var entry: Dictionary = pending_swaps[grid_pos]
	var pool: Dictionary = entry.get("refund_pool", {})
	var refunded: Dictionary = entry.get("refunded", {})
	for rk in pool:
		var remaining: int = int(pool[rk]) - int(refunded.get(rk, 0))
		if remaining > 0:
			_grant_resource_capped(rk, remaining)
	# Also refund any RESOURCES_CONSUMED for the new block — the player
	# never received the new block, so material spent toward its build
	# is wasted unless we hand it back. Only triggered on "abandoned"
	# (also_consumed=true) — a finalized swap consumed for a real block.
	if also_consumed:
		var consumed: Dictionary = entry.get("consumed", {})
		for rk in consumed:
			var amt: int = int(consumed[rk])
			if amt > 0:
				_grant_resource_capped(rk, amt)


## Adds `amount` of resource `rk` to main.resources, capped at the
## current per-resource storage cap. Excess just disappears (matches
## what mined / produced items do when storage is full).
func _grant_resource_capped(rk: StringName, amount: int) -> void:
	if amount <= 0:
		return
	var cap: int = get_storage_cap_per_resource()
	var current: int = int(resources.get(rk, 0))
	if cap > 0:
		resources[rk] = mini(current + amount, cap)
	else:
		resources[rk] = current + amount
	resources_changed.emit(resources)


## Executes a deferred same-group swap: destroys the old block (firing all
## the normal building_destroyed cleanup) and places the new one with build
## progress starting at 0, so the usual progressive-build flow picks up.
## Called by BuildingSystem when the drone arrives at a pending_swaps cell.
func execute_pending_swap(grid_pos: Vector2i) -> bool:
	if not pending_swaps.has(grid_pos):
		return false
	var entry: Dictionary = pending_swaps[grid_pos]
	pending_swaps.erase(grid_pos)
	var new_id: StringName = StringName(entry.get("new_block_id", &""))
	var new_rot: int = int(entry.get("new_rotation", 0))
	if new_id == &"":
		return false
	var new_data = Registry.get_block(new_id)
	if new_data == null:
		return false
	# Resources were consumed while progress was ticking on the pending
	# entry itself, and progress has hit build_time — commit the swap as
	# fully built. No further drone work needed here.
	return _execute_swap_now(grid_pos, new_id, new_rot, true)


## Immediate swap: destroys the old block and places the new one at the same
## cell. Build progress starts at 0 (the drone will tick it up as usual).
func _execute_swap_now(grid_pos: Vector2i, new_id: StringName, new_rot: int, already_built: bool = false) -> bool:
	var new_data = Registry.get_block(new_id)
	if new_data == null:
		return false
	# Destroy the existing block first — this fires building_destroyed so every
	# system clears its per-anchor state (conveyor_items, sorter_filters,
	# factory_buffers, power networks, etc.) and refunds nothing.
	destroy_building(grid_pos)

	# No immediate cost deduction — progressive consumption during build.

	# Place the new block at the same cell, rotation = new_rot. For
	# multi-tile blocks (e.g. vent turbine / condenser at 3×3) we have
	# to populate every tile of the new footprint, not just the anchor
	# — otherwise systems that look up `placed_buildings[cell]` for the
	# 8 non-anchor tiles will think those cells are empty, and tag-
	# based scans (like the vent turbine's per-tile draw / state init)
	# will only act on the anchor cell.
	building_health[grid_pos] = new_data.max_health
	for x in range(new_data.grid_size.x):
		for y in range(new_data.grid_size.y):
			var tile_pos: Vector2i = grid_pos + Vector2i(x, y)
			placed_buildings[tile_pos] = new_id
			building_rotation[tile_pos] = new_rot
			building_origins[tile_pos] = grid_pos
			building_factions[tile_pos] = Faction.LUMINA

	# Start build with progressive resource consumption — unless the
	# caller already paid the build cost out-of-band (deferred swap path
	# that ticked progress on the pending_swaps entry itself).
	if new_data.build_time > 0 and not already_built:
		building_build_progress[grid_pos] = 0.0
		building_resources_consumed[grid_pos] = {}
		if not work_order.has(grid_pos):
			work_order.append(grid_pos)

	resources_changed.emit(resources)
	building_placed.emit(new_id, grid_pos)
	return true


## True if any live (non-flying — flying units occupy a different layer
## and shouldn't block construction) unit currently overlaps the cell at
## `grid_pos`. Used by placement to refuse dropping a wall on a unit.
func _is_cell_occupied_by_unit(grid_pos: Vector2i) -> bool:
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if unit_mgr == null:
		return false
	var lists: Array = []
	if unit_mgr.get("player_units") is Array:
		lists.append(unit_mgr.player_units)
	if unit_mgr.get("enemies") is Array:
		lists.append(unit_mgr.enemies)
	for arr in lists:
		for u in arr:
			if not is_instance_valid(u) or u.get("is_dead"):
				continue
			var ml: int = u.data.movement_layer if u.get("data") != null else 0
			if ml == UnitData.MovementLayer.FLYING:
				continue
			if world_to_grid(u.position) == grid_pos:
				return true
	return false


func try_place_building(grid_pos: Vector2i) -> bool:
	if selected_building == &"":
		return false

	var data = Registry.get_block(selected_building)
	if data == null:
		return false

	# --- Same-block rotation update ---
	# Rotating an existing block in place preserves every piece of
	# runtime state tied to it (factory buffers, refabricator state,
	# held payloads, constructor selections, conveyor items, etc.). We
	# only update the rotation entries and deliberately do NOT emit
	# `building_placed` — that signal is "a new block was placed", and
	# firing it here would bump stats_blocks_placed / sector_script
	# placed_counts, reset turret cooldowns, and re-init logistics state
	# tables that should persist across a rotation. Subsystems that read
	# rotation (logistics transfer math, building_system draw) already
	# look it up fresh each tick, so no signal is needed.
	if placed_buildings.has(grid_pos) and placed_buildings[grid_pos] == selected_building:
		var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
		if anchor == grid_pos:
			var old_rot: int = building_rotation.get(grid_pos, 0)
			if old_rot != placement_rotation:
				for x in range(data.grid_size.x):
					for y in range(data.grid_size.y):
						building_rotation[grid_pos + Vector2i(x, y)] = placement_rotation
			return true

	# --- Same-group swap: placing a part of one of the swap families
	# (belt / duct / conduit / payload / freight / shaft / wall) on top
	# of another member of the same family replaces the existing block.
	# Footprints must match — a 1×1 belt overlay is fine because every
	# belt part is 1×1, and walls swap as long as the new wall has the
	# same grid_size as the old one (1×1 → 1×1, 2×2 → 2×2, etc.).
	if placed_buildings.has(grid_pos) and building_origins.get(grid_pos, grid_pos) == grid_pos:
		var existing_id: StringName = placed_buildings[grid_pos]
		if existing_id != selected_building:
			var existing_data = Registry.get_block(existing_id)
			if existing_data != null and existing_data.grid_size == data.grid_size:
				var new_group: StringName = _get_swap_group(data)
				var old_group: StringName = _get_swap_group(existing_data)
				if new_group != &"" and new_group == old_group:
					# Only LUMINA can swap its own blocks.
					if get_building_faction(grid_pos) == Faction.LUMINA:
						return _swap_building_in_place(grid_pos, existing_data, data)

	# --- Size-up swap (walls and platforms only): a bigger wall/platform
	# absorbs any smaller same-group blocks whose footprints lie entirely
	# inside the new block's footprint. Walls and platforms qualify
	# because they hold no per-tick logistics state — destroying and
	# replacing them is purely structural. Belts/ducts/etc. are excluded
	# so a misclick doesn't silently incinerate a chain of factories'
	# inputs. The new block must be larger than 1×1 (1×1 → 1×1 already
	# goes through the same-size swap above).
	if (data.tags.has("wall") or data.tags.has("platform")) \
			and (data.grid_size.x > 1 or data.grid_size.y > 1):
		var new_group_up: StringName = _get_swap_group(data)
		if new_group_up != &"":
			var size_up_ok := true
			var anchors_to_absorb: Array = []
			var seen_absorbed: Dictionary = {}
			var absorbed_any := false
			var terrain_up = _terrain_ref()
			var rect_min: Vector2i = grid_pos
			var rect_max: Vector2i = grid_pos + data.grid_size - Vector2i(1, 1)
			for x in range(data.grid_size.x):
				for y in range(data.grid_size.y):
					var cell: Vector2i = grid_pos + Vector2i(x, y)
					if not is_within_bounds(cell):
						size_up_ok = false
						break
					if terrain_up and terrain_up.has_wall(cell):
						size_up_ok = false
						break
					if _is_cell_occupied_by_unit(cell):
						size_up_ok = false
						break
					if not placed_buildings.has(cell):
						continue
					var ex_anchor: Vector2i = building_origins.get(cell, cell)
					if seen_absorbed.has(ex_anchor):
						continue
					var ex_id_up: StringName = placed_buildings[ex_anchor]
					var ex_data_up = Registry.get_block(ex_id_up)
					if ex_data_up == null:
						size_up_ok = false
						break
					if _get_swap_group(ex_data_up) != new_group_up:
						size_up_ok = false
						break
					if get_building_faction(ex_anchor) != Faction.LUMINA:
						size_up_ok = false
						break
					# The absorbed block must lie ENTIRELY inside the
					# new footprint — partial absorption would orphan
					# cells of an unrelated tile.
					var ex_max: Vector2i = ex_anchor + ex_data_up.grid_size - Vector2i(1, 1)
					if ex_anchor.x < rect_min.x or ex_anchor.y < rect_min.y \
							or ex_max.x > rect_max.x or ex_max.y > rect_max.y:
						size_up_ok = false
						break
					seen_absorbed[ex_anchor] = true
					anchors_to_absorb.append(ex_anchor)
					absorbed_any = true
				if not size_up_ok:
					break
			if size_up_ok and absorbed_any:
				# Tear down each absorbed block first so building_destroyed
				# fires and downstream systems clean up; then validate
				# terrain (with the absorbed blocks gone, the
				# "platforms don't stack" rule no longer trips on cells
				# we're swapping out). Fall through to the standard
				# placement code below, which now sees every cell as
				# empty and commits the new block normally.
				for a in anchors_to_absorb:
					destroy_building(a)
				if not _terrain_accepts_at(grid_pos, data):
					# Terrain genuinely rejects this footprint (e.g.
					# void cell that was bridged only by an absorbed
					# platform — but the new platform doesn't span
					# that cell's neighbours). Bail out: the absorbed
					# blocks are already gone, but the player gets
					# refunded by virtue of progressive build never
					# starting.
					return false

	# Check all tiles the building occupies (for multi-tile buildings)
	var terrain = _terrain_ref()
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var check_pos = grid_pos + Vector2i(x, y)
			if not is_within_bounds(check_pos) or not is_cell_empty(check_pos):
				return false
			# Can't place on walls
			if terrain and terrain.has_wall(check_pos):
				return false
			# Can't place on a unit — would phase the unit inside a wall
			# the moment construction completes. Players, enemies, and
			# the player's piloted unit all count.
			if _is_cell_occupied_by_unit(check_pos):
				return false
	# Void / water-depth rules. The preview overlay was the only thing
	# enforcing this before; without an explicit check here, a player
	# whose preview said "no" could still commit the placement.
	if not _terrain_accepts_at(grid_pos, data):
		return false

	# Core zone rule: core blocks MUST be on core_zone floor tiles.
	if terrain and data.tags.has("core"):
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				var check_pos = grid_pos + Vector2i(x, y)
				var floor_data = terrain.get_floor_at(check_pos)
				if floor_data == null or not floor_data.tags.has("core_zone"):
					return false

	# Vent-powered buildings must be centered on a vent tile
	if data.tags.has("vent_powered"):
		if terrain:
			var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
			var tile_id = terrain.floor_tiles.get(center, &"")
			if tile_id != &"vent":
				return false

	# Extractors must face ore — or, for wall miners, a blackstone wall.
	# Geyser miners must be on a geyser (not face ore).
	if data.category == BlockData.BlockCategory.EXTRACTORS:
		if data.tags.has("geyser_miner"):
			if terrain:
				var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
				if terrain.floor_tiles.get(center, &"") != &"geyser":
					return false
		else:
			var building_sys = _building_sys_ref()
			if building_sys:
				if data.tags.has("wall_miner"):
					if not building_sys._is_facing_wall(grid_pos, placement_rotation, selected_building):
						return false
				else:
					if not building_sys._is_facing_ore(grid_pos, placement_rotation):
						return false

	# Pumps must be on liquid
	if data.tags.has("pump"):
		var building_sys = _building_sys_ref()
		# Condensers extract from steam, not liquid — they need a vent or
		# geyser tile centered under their footprint instead of a water
		# source.
		if data.tags.has("condenser"):
			if terrain:
				var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
				var tid = terrain.floor_tiles.get(center, &"")
				if tid != &"vent" and tid != &"geyser":
					return false
		elif building_sys and not building_sys._is_on_liquid(grid_pos):
			return false

	# Check if within drone build range
	var drone = _drone_ref()
	if drone and not drone.is_in_build_range(grid_pos):
		return false

	# No immediate cost deduction — resources are consumed progressively
	# during construction by the build tick in building_system._process.

	# Stash any platform that's about to be covered by this placement so
	# the platform can be restored when the covering block is destroyed.
	# Skipped when the new block IS a platform — platforms don't stack.
	var new_is_platform: bool = data.tags.has("platform")
	if not new_is_platform:
		_stash_covered_platforms(grid_pos, data.grid_size)

	# Place all tiles. Health lives per-building on the anchor, not per
	# tile, so multi-tile buildings have a single HP pool.
	building_health[grid_pos] = data.max_health
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var tile_pos = grid_pos + Vector2i(x, y)
			placed_buildings[tile_pos] = selected_building
			building_rotation[tile_pos] = placement_rotation
			building_origins[tile_pos] = grid_pos
			building_factions[tile_pos] = Faction.LUMINA

	# Start build with progressive resource consumption.
	# build_time 0 → instant (no queue entry needed).
	if data.build_time > 0:
		building_build_progress[grid_pos] = 0.0
		building_resources_consumed[grid_pos] = {}
		work_order.append(grid_pos)

	resources_changed.emit(resources)
	building_placed.emit(selected_building, grid_pos)
	return true


## Places a building by explicit block_id and rotation (for schematics).
## Does NOT require selected_building/placement_rotation to be set.
func place_building_for_schematic(grid_pos: Vector2i, block_id: StringName, rot: int) -> bool:
	var data = Registry.get_block(block_id)
	if data == null:
		return false

	# Validate all tiles
	var terrain = _terrain_ref()
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var check_pos = grid_pos + Vector2i(x, y)
			if not is_within_bounds(check_pos) or not is_cell_empty(check_pos):
				return false
			if terrain and terrain.has_wall(check_pos):
				return false
			if _is_cell_occupied_by_unit(check_pos):
				return false
	# Same void / water-depth gate `try_place_building` uses, so a
	# schematic stamp can't sneak blocks onto the abyss either.
	if not _terrain_accepts_at(grid_pos, data):
		return false

	# Deduct costs
	if require_resources:
		if not can_afford(block_id):
			return false
		for item_id in data.build_cost:
			var rk := _resolve_resource_key(str(item_id))
			resources[rk] -= int(data.build_cost[item_id])

	# Stash any covered platform (mirrors `try_place_building`) so a
	# schematic-placed block on a platform can later be deconstructed
	# back to bare platform.
	if not data.tags.has("platform"):
		_stash_covered_platforms(grid_pos, data.grid_size)

	# Place all tiles. Health is per-anchor (single HP pool per building).
	building_health[grid_pos] = data.max_health
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var tile_pos = grid_pos + Vector2i(x, y)
			placed_buildings[tile_pos] = block_id
			building_rotation[tile_pos] = rot
			building_origins[tile_pos] = grid_pos
			building_factions[tile_pos] = Faction.LUMINA

	# Start build with progressive resource consumption — same path as
	# `try_place_building` so the drone actually picks the schematic
	# blocks up. Without `work_order.append` the queued blocks stayed
	# visible as ghosts forever; only `build_order` (deprecated, kept
	# for save compat) was being seeded.
	if data.build_time > 0:
		building_build_progress[grid_pos] = 0.0
		building_resources_consumed[grid_pos] = {}
		work_order.append(grid_pos)

	resources_changed.emit(resources)
	building_placed.emit(block_id, grid_pos)
	return true


# Deals damage to a building. Destroys it if HP reaches 0.
func damage_building(grid_pos: Vector2i, amount: float) -> void:
	# Damage routes through the building's anchor — multi-tile buildings
	# have one shared HP pool, not a separate value per tile.
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	if not building_health.has(anchor):
		return
	# Platforms are invulnerable to in-combat damage. They're a terrain
	# feature, not a target. Players can still deconstruct them once any
	# blocks built on top are removed.
	var bid: StringName = placed_buildings.get(anchor, &"")
	if bid != &"":
		var bdata = Registry.get_block(bid)
		if bdata and bdata.tags.has("platform"):
			return
		# Armor: subtract from incoming damage, with a 1-damage floor so
		# fully-armored blocks can't be invulnerable. Applied per hit.
		if bdata and bdata.armor > 0.0:
			amount = maxf(amount - bdata.armor, 1.0)
	building_health[anchor] -= amount
	# Surface a flashing HUD alert when one of the player's cores takes
	# damage so the player notices even if they're mid-build away from
	# their base. The alert auto-clears after ~3 s of no further damage
	# via `core_damage_alert_expires_at`.
	if bid != &"":
		var bdata_a = Registry.get_block(bid)
		if bdata_a and bdata_a.tags.has("core") and get_building_faction(anchor) == Faction.LUMINA:
			var hud_a = get_node_or_null("HUD")
			if hud_a and hud_a.has_method("push_alert"):
				# 3 s auto-expire — the HUD ticks it down and clears the
				# banner automatically once damage stops landing.
				hud_a.push_alert(&"core_damage", "<Core Is Taking Damage>", 3.0)
	# Polish: nudge the camera so the player can feel damage land.
	# (The white hit-flash overlay was removed — it tinted enemy
	# blocks gray when they were under sustained fire and read as a
	# weird persistent rectangle. Shake alone gives enough feedback.)
	var fb = get_node_or_null("FeedbackSystem")
	if fb:
		var bldg_data = Registry.get_block(placed_buildings.get(anchor, &""))
		var max_hp: float = bldg_data.max_health if bldg_data else 100.0
		fb.add_shake(clampf(amount / max_hp * 8.0, 0.0, 6.0))
	if building_health[anchor] <= 0:
		# Destruction shake reserved for enemy (FEROX) cores only —
		# every other block / unit going down emits sound via the
		# destroy signal but doesn't rattle the camera. Toppling an
		# enemy core is a tide-turning moment so it gets a small
		# punch of feedback.
		if fb:
			var ddata = Registry.get_block(placed_buildings.get(anchor, &""))
			var ddata_faction: int = get_building_faction(anchor)
			if ddata and ddata.tags.has("core") and ddata_faction == Faction.FEROX:
				fb.add_shake(4.0)
		destroy_building(anchor, true)


# Queues a building for deconstruction. Resources are refunded progressively
# during the deconstruct tick, not instantly.
func destroy_building_with_refund(grid_pos: Vector2i) -> void:
	if not placed_buildings.has(grid_pos):
		return
	var block_id = placed_buildings[grid_pos]
	var data = Registry.get_block(block_id)
	# Don't refund or destroy cores
	if data and data.tags.has("core"):
		return
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	# If already deconstructing, skip
	if building_deconstruct_progress.has(anchor):
		return
	# Cancel any in-flight swap on this cell. The OLD block (still
	# placed) will be properly refunded by the standard deconstruct
	# below; the swap's already-paid OLD-pool refunds are honored,
	# but the player-spent resources for the NEW block need to come
	# back since the NEW block is now being abandoned.
	if pending_swaps.has(anchor):
		var sw_entry: Dictionary = pending_swaps[anchor]
		var consumed: Dictionary = sw_entry.get("consumed", {})
		for rk in consumed:
			_grant_resource_capped(rk, int(consumed[rk]))
		# Subtract the partial OLD-pool refund already given so the
		# upcoming deconstruct refund (which gives back the OLD block's
		# full build_cost) doesn't double up. Each `refunded[rk]` is
		# the amount the swap already handed back from the OLD pool.
		var refunded: Dictionary = sw_entry.get("refunded", {})
		for rk in refunded:
			var dock: int = mini(int(refunded[rk]), int(resources.get(rk, 0)))
			if dock > 0:
				resources[rk] -= dock
		# Clear the entry so the build tick doesn't keep ticking it.
		pending_swaps.erase(anchor)
		var swi: int = work_order.find(anchor)
		if swi >= 0 and not building_build_progress.has(anchor):
			work_order.remove_at(swi)
	# How much was actually paid so far — this is what gets refunded.
	var total_to_refund := {}
	var starting_progress: float = 0.0

	if building_build_progress.has(anchor):
		# Partially built — reverse from where construction got to.
		total_to_refund = building_resources_consumed.get(anchor, {}).duplicate()
		# Deconstruct starts at the current build progress and counts down to 0.
		var build_time_full: float = data.build_time if data else 1.0
		if build_time_full <= 0:
			build_time_full = 1.0
		starting_progress = clampf(building_build_progress[anchor], 0.0, build_time_full)
		# Instant-destroy fast path: anything that hasn't visibly started
		# building yet (< 5 % progress) snaps away without an animation.
		# Covers both:
		#   • the pure-ghost case (block queued, drone never reached it)
		#   • the "placed and immediately changed my mind" case where
		#     one tick has nudged progress to 0.016 and consumed a single
		#     resource unit
		# Any resources already paid are refunded so the player isn't
		# punished for the one-tick edge.
		var pct_built: float = starting_progress / build_time_full
		if pct_built < 0.05:
			for k in total_to_refund:
				var amt: int = int(total_to_refund[k])
				if amt > 0:
					_grant_resource_capped(k, amt)
			building_build_progress.erase(anchor)
			building_resources_consumed.erase(anchor)
			var wi_g := work_order.find(anchor)
			if wi_g >= 0:
				work_order.remove_at(wi_g)
			if "work_paused" in self and work_paused.has(anchor):
				work_paused.erase(anchor)
			destroyed_player_buildings.erase(anchor)
			destroy_building(anchor)
			return
		# Clean up the build entry — it's now a deconstruct.
		building_build_progress.erase(anchor)
		building_resources_consumed.erase(anchor)
		var wi := work_order.find(anchor)
		if wi >= 0:
			work_order.remove_at(wi)
	else:
		# Fully built — refund full build cost over the full build_time.
		if data:
			for item_id in data.build_cost:
				var rk := _resolve_resource_key(str(item_id))
				total_to_refund[rk] = int(data.build_cost[item_id])

	# Deconstruct duration = how far the build got (partially built) or
	# full build_time (fully built). Minimum 0.5s for visual feedback.
	var build_time_full: float = data.build_time if data else 1.0
	if build_time_full <= 0:
		build_time_full = 1.0
	var decon_time: float
	var max_build_pct: float  # How far the build got (0-1); 1.0 = fully built
	if starting_progress > 0.0:
		decon_time = maxf(starting_progress, 0.5)
		max_build_pct = clampf(starting_progress / build_time_full, 0.0, 1.0)
	else:
		decon_time = build_time_full
		if decon_time <= 0:
			decon_time = 0.5
		max_build_pct = 1.0

	building_deconstruct_progress[anchor] = {
		"block_id": block_id,
		"progress": 0.0,
		"build_time": decon_time,
		"rotation": building_rotation.get(grid_pos, 0),
		"total_refund": total_to_refund,
		"max_build_pct": max_build_pct,  # For the visual: line starts here and goes back to 0
	}
	building_resources_refunded[anchor] = {}
	# Deconstruct is more urgent than queued builds — insert at the front
	# of the work queue (after any currently-active item at index 0, unless
	# this anchor WAS the active item, in which case it takes slot 0).
	if work_order.is_empty() or work_order[0] == anchor:
		if not work_order.is_empty():
			work_order.remove_at(0)
		work_order.insert(0, anchor)
	else:
		work_order.insert(1, anchor)

	# Block has just flipped from active → inactive (is_building_inactive
	# returns true whenever a decon entry exists). Invalidate the power
	# network so its contribution is removed from the balance on the next
	# tick, matching the signal-less construction-completion path.
	var ps := _power_sys_ref()
	if ps and "_networks_dirty" in ps:
		ps._networks_dirty = true


## Alias for destroy_building_with_refund — starts deconstruct animation with refund.
func start_deconstruct(grid_pos: Vector2i) -> void:
	# Archives can't be torn down until the data they hold has actually
	# been decoded. Otherwise a player could reclaim the block (and
	# whatever it slots back into the inventory) without ever finishing
	# the research, which sidesteps the entire archive-decoder loop.
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	if placed_buildings.has(anchor):
		var bid: StringName = placed_buildings[anchor]
		var bdata = Registry.get_block(bid)
		if bdata and bdata.id == &"archive":
			var building_sys = _building_sys_ref()
			if building_sys and "archive_holdings" in building_sys:
				var stored_aid: StringName = building_sys.archive_holdings.get(anchor, &"")
				if stored_aid != &"" and not TechTree.is_researched(stored_aid):
					return
		# Platforms with a covering block can't be deconstructed until
		# whatever's on top is removed first. Without this guard the
		# platform would vanish out from under a turret / belt.
		if bdata and bdata.tags.has("platform") and _platform_has_cover(anchor):
			return
	destroy_building_with_refund(grid_pos)


## Picks up a building into a payload dictionary, silently removing it from the grid.
## Returns the payload data, or an empty dict if pickup failed.
## Does NOT emit building_destroyed — the building is just "lifted", not destroyed.
func pickup_building(grid_pos: Vector2i) -> Dictionary:
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	if not placed_buildings.has(anchor):
		return {}
	var block_id: StringName = placed_buildings[anchor]
	var data = Registry.get_block(block_id)
	if data == null:
		return {}
	# Don't pick up cores
	if data.tags.has("core"):
		return {}
	var rot: int = building_rotation.get(anchor, 0)
	var health: float = building_health.get(anchor, data.max_health)
	var faction: int = get_building_faction(anchor)

	# Capture stored items/fluids from logistics
	var stored_items := {}
	var stored_fluids := {}
	var logistics = _logistics_ref()
	if logistics and logistics.block_storage.has(anchor):
		var storage = logistics.block_storage[anchor]
		stored_items = storage.get("items", {}).duplicate()
		stored_fluids = storage.get("fluids", {}).duplicate()
		logistics.block_storage.erase(anchor)
	# Also capture factory buffer inputs
	var factory_state := {}
	if logistics and logistics.factory_buffers.has(anchor):
		factory_state = logistics.factory_buffers[anchor].duplicate(true)
		var fb_inputs = factory_state.get("inputs", {})
		for item_id in fb_inputs:
			stored_items[item_id] = stored_items.get(item_id, 0) + int(fb_inputs[item_id])
		factory_state.erase("inputs")  # Items merged into stored_items
		logistics.factory_buffers.erase(anchor)

	# Capture constructor state
	var constructor_data := {}
	if logistics and "constructor_state" in logistics and logistics.constructor_state.has(anchor):
		constructor_data = logistics.constructor_state[anchor].duplicate(true)
		logistics.constructor_state.erase(anchor)

	# Capture sorter filter
	var sorter_filter: StringName = &""
	if logistics and logistics.sorter_filters.has(anchor):
		sorter_filter = logistics.sorter_filters[anchor]
		logistics.sorter_filters.erase(anchor)

	# Capture drill timer
	var drill_timer: float = -1.0
	if logistics and logistics.drill_timers.has(anchor):
		drill_timer = logistics.drill_timers[anchor]
		logistics.drill_timers.erase(anchor)

	# Capture conveyor items that sit on the picked-up footprint —
	# every cell of the building, since belts are 1×1 but other
	# transport blocks might be larger. Each cell's entry (if any) is
	# copied into the payload and erased from the live map, so the
	# items neither get lost (vanishing into a destroyed cell) nor
	# stay orphaned at the old position. `place_payload_building`
	# restores them to the new cells in the same local layout.
	var conveyor_items_snapshot: Dictionary = {}
	if logistics and "conveyor_items" in logistics:
		for dx in range(data.grid_size.x):
			for dy in range(data.grid_size.y):
				var cell: Vector2i = anchor + Vector2i(dx, dy)
				if logistics.conveyor_items.has(cell):
					var rel_key: String = "%d,%d" % [dx, dy]
					conveyor_items_snapshot[rel_key] = (logistics.conveyor_items[cell] as Dictionary).duplicate(true)
					logistics.conveyor_items.erase(cell)

	# Capture crane state when picking up another crane — without this
	# the picked-up crane forgets whatever it was holding (and the
	# crane that's holding it has no way to display the inner payload).
	# Deep-duplicate so subsequent edits to crane_states can't reach
	# back into the captured snapshot through shared dict references.
	var crane_state_snapshot: Dictionary = {}
	var building_sys = get_node_or_null("BuildingSystem")
	if building_sys and "crane_states" in building_sys \
			and building_sys.crane_states.has(anchor):
		crane_state_snapshot = (building_sys.crane_states[anchor] as Dictionary).duplicate(true)

	# Capture every spinning-head state on this block (wall crusher,
	# wall grinder, ground scraper, vent turbine, vent condenser,
	# brass mixer). The held simulation eases each velocity toward 0
	# so the head visibly spins down in transit instead of teleporting
	# to a halt when grabbed; on drop, the snapshot restores so the
	# placed block resumes from the decayed angle / velocity.
	var spin_state_snapshot: Dictionary = {}
	if building_sys and building_sys.has_method("_capture_spin_state"):
		spin_state_snapshot = building_sys._capture_spin_state(anchor)

	# Capture turret aim angles so the held visual freezes the heads
	# at exactly where they were pointing the moment the crane closed —
	# instead of snapping back to a default rot=0 pose.
	var turret_aim_angle: float = 0.0
	var turret_barrel_angles_snapshot: Array = []
	var combat_sys = get_node_or_null("CombatSystem")
	if combat_sys:
		if "turret_angles" in combat_sys and combat_sys.turret_angles.has(anchor):
			turret_aim_angle = float(combat_sys.turret_angles[anchor])
		if "turret_barrel_angles" in combat_sys and combat_sys.turret_barrel_angles.has(anchor):
			turret_barrel_angles_snapshot = (combat_sys.turret_barrel_angles[anchor] as Array).duplicate()

	# Pull the block's internal-battery charge (10B reservoir) into the
	# payload so the held simulation can drain it while detached, and
	# `place_payload_building` can write it back when dropped.
	var internal_battery_charge: float = 0.0
	var power_sys_pickup = get_node_or_null("PowerSystem")
	if power_sys_pickup and power_sys_pickup.has_method("block_internal_battery_charge"):
		internal_battery_charge = power_sys_pickup.block_internal_battery_charge(anchor)
		if "_block_internal_battery" in power_sys_pickup:
			power_sys_pickup._block_internal_battery.erase(anchor)

	# Build payload data
	var payload := {
		"type": "building",
		"block_id": str(block_id),
		"rotation": rot,
		"health": health,
		"faction": faction,
		"stored_items": stored_items,
		"stored_fluids": stored_fluids,
		"grid_size_x": data.grid_size.x,
		"grid_size_y": data.grid_size.y,
		"factory_state": factory_state,
		"constructor_data": constructor_data,
		"sorter_filter": str(sorter_filter),
		"drill_timer": drill_timer,
		"crane_state": crane_state_snapshot,
		"turret_aim_angle": turret_aim_angle,
		"turret_barrel_angles": turret_barrel_angles_snapshot,
		"internal_battery_charge": internal_battery_charge,
		"head_spin_state": spin_state_snapshot,
		"conveyor_items": conveyor_items_snapshot,
	}

	# Silently remove all tiles of this building
	if data.grid_size.x > 1 or data.grid_size.y > 1:
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				var tile_pos = anchor + Vector2i(x, y)
				placed_buildings.erase(tile_pos)
				building_health.erase(tile_pos)
				building_rotation.erase(tile_pos)
				building_origins.erase(tile_pos)
				building_factions.erase(tile_pos)
	else:
		placed_buildings.erase(anchor)
		building_health.erase(anchor)
		building_rotation.erase(anchor)
		building_origins.erase(anchor)
		building_factions.erase(anchor)

	# Clean up build/deconstruct progress and unified work queue
	building_build_progress.erase(anchor)
	building_deconstruct_progress.erase(anchor)
	building_resources_consumed.erase(anchor)
	building_resources_refunded.erase(anchor)
	var work_idx: int = work_order.find(anchor)
	if work_idx >= 0:
		work_order.remove_at(work_idx)
	# Legacy compat
	var order_idx: int = build_order.find(anchor)
	if order_idx >= 0:
		build_order.remove_at(order_idx)
	var decon_idx: int = deconstruct_order.find(anchor)
	if decon_idx >= 0:
		deconstruct_order.remove_at(decon_idx)

	# Clean up turret angles (combat system)
	var combat = _combat_sys_ref()
	if combat and "turret_angles" in combat:
		combat.turret_angles.erase(anchor)

	# Clean up links (power system)
	var power_sys = _power_sys_ref()
	if power_sys and "linked_pairs" in power_sys:
		var to_remove := []
		for i in range(power_sys.linked_pairs.size()):
			var pair = power_sys.linked_pairs[i]
			if pair[0] == anchor or pair[1] == anchor:
				to_remove.append(i)
		for i in range(to_remove.size() - 1, -1, -1):
			power_sys.linked_pairs.remove_at(to_remove[i])

	# Clean up crane states (building system)
	if building_sys and "crane_states" in building_sys:
		building_sys.crane_states.erase(anchor)
	if building_sys and "archive_holdings" in building_sys:
		building_sys.archive_holdings.erase(anchor)
	if building_sys and "archive_decoder_state" in building_sys:
		building_sys.archive_decoder_state.erase(anchor)

	# Clean up conveyor items on this building's tiles
	if logistics:
		if data.grid_size.x > 1 or data.grid_size.y > 1:
			for x in range(data.grid_size.x):
				for y in range(data.grid_size.y):
					var tile_pos = anchor + Vector2i(x, y)
					logistics.conveyor_items.erase(tile_pos)
					if "payload_items" in logistics:
						logistics.payload_items.erase(tile_pos)
		else:
			logistics.conveyor_items.erase(anchor)
			if "payload_items" in logistics:
				logistics.payload_items.erase(anchor)

	# Clean up remaining per-anchor state via the logistics destroy handler.
	# Pickup does not emit building_destroyed (to avoid stats/rebuild side effects),
	# so we call the cleanup directly to keep state dictionaries in sync.
	if logistics and logistics.has_method("_on_building_destroyed"):
		logistics._on_building_destroyed(anchor)

	return payload


## Places a building from a payload dictionary onto the grid.
## Returns true if placement succeeded.
func place_payload_building(payload: Dictionary, grid_pos: Vector2i) -> bool:
	var block_id := StringName(payload.get("block_id", ""))
	var data = Registry.get_block(block_id)
	if data == null:
		return false

	# Check all tiles are available
	var terrain = _terrain_ref()
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var check_pos = grid_pos + Vector2i(x, y)
			if not is_within_bounds(check_pos) or not is_cell_empty(check_pos):
				return false
			if terrain and terrain.has_wall(check_pos):
				return false

	# Same terrain-accept gate the regular placement path uses — without
	# this, a crane could drop a normal block onto a water tile (because
	# `is_cell_empty` only checks placed_buildings) or drop a platform
	# onto dry ground (platforms require water). Also rejects void cells
	# and stacking platforms on platforms.
	if not _terrain_accepts_at(grid_pos, data):
		return false

	# Extractor placement checks
	if data.category == BlockData.BlockCategory.EXTRACTORS:
		var building_sys = _building_sys_ref()
		if building_sys:
			var pay_rot := int(payload.get("rotation", 0))
			if data.tags.has("wall_miner"):
				if not building_sys._is_facing_wall(grid_pos, pay_rot, block_id):
					return false
			elif data.tags.has("geyser_miner"):
				# Geyser miners (mineral extractor) need a geyser tile
				# centered under the footprint — same gate as fresh
				# placement uses. Without this a crane could drop one
				# anywhere.
				if terrain:
					var gm_center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
					if terrain.floor_tiles.get(gm_center, &"") != &"geyser":
						return false
			else:
				if not building_sys._is_facing_ore(grid_pos, pay_rot, block_id):
					return false

	# Vent-powered check
	if data.tags.has("vent_powered") and terrain:
		var center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
		if terrain.floor_tiles.get(center, &"") != &"vent":
			return false

	# Condenser must be on a vent or geyser tile (same gate as the
	# regular placement flow). Without this a crane could drop the
	# vent condenser anywhere and the placement would silently
	# succeed.
	if data.tags.has("condenser") and terrain:
		var cd_center = grid_pos + Vector2i(data.grid_size.x / 2, data.grid_size.y / 2)
		var cd_tile = terrain.floor_tiles.get(cd_center, &"")
		if cd_tile != &"vent" and cd_tile != &"geyser":
			return false

	var rot: int = int(payload.get("rotation", 0))
	var health: float = float(payload.get("health", data.max_health))
	var faction: int = int(payload.get("faction", Faction.LUMINA))

	# Stash any platform sitting under this footprint so it can be
	# restored when the dropped block is destroyed. Without this the
	# overwrite below permanently erases the platform.
	_stash_covered_platforms(grid_pos, data.grid_size)

	# Place all tiles. Health is per-anchor (one HP pool per building).
	building_health[grid_pos] = health
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var tile_pos = grid_pos + Vector2i(x, y)
			placed_buildings[tile_pos] = block_id
			building_rotation[tile_pos] = rot
			building_origins[tile_pos] = grid_pos
			building_factions[tile_pos] = faction

	# Restore stored items/fluids
	var logistics = _logistics_ref()
	if logistics:
		var stored_items: Dictionary = payload.get("stored_items", {})
		var stored_fluids: Dictionary = payload.get("stored_fluids", {})
		if not stored_items.is_empty() or not stored_fluids.is_empty():
			logistics.block_storage[grid_pos] = {
				"items": stored_items.duplicate(),
				"fluids": stored_fluids.duplicate(),
			}

		# Restore factory state (phase, timer, pending outputs)
		var factory_state: Dictionary = payload.get("factory_state", {})
		if not factory_state.is_empty():
			factory_state["inputs"] = {}  # Items already in block_storage
			logistics.factory_buffers[grid_pos] = factory_state

		# Restore constructor state
		var constructor_data: Dictionary = payload.get("constructor_data", {})
		if not constructor_data.is_empty():
			logistics.constructor_state[grid_pos] = constructor_data

		# Restore sorter filter
		var sorter_filter: String = payload.get("sorter_filter", "")
		if sorter_filter != "":
			logistics.sorter_filters[grid_pos] = StringName(sorter_filter)

		# Restore drill timer
		var drill_timer: float = float(payload.get("drill_timer", -1.0))
		if drill_timer >= 0.0:
			logistics.drill_timers[grid_pos] = drill_timer

	building_placed.emit(block_id, grid_pos)

	# Restore captured crane state (for cranes that were themselves
	# picked up by another crane). `building_placed.emit` above runs
	# `BuildingSystem._on_building_placed` synchronously, which seeds
	# a default `crane_states[grid_pos]` entry — overwrite that with
	# the snapshot we captured during pickup so the placed crane keeps
	# any held_payload / arm_angle / etc. it had when it was grabbed.
	var crane_state_snapshot: Dictionary = payload.get("crane_state", {})
	if not crane_state_snapshot.is_empty() and data.tags.has("crane"):
		var building_sys2 = _building_sys_ref()
		if building_sys2 and "crane_states" in building_sys2:
			var restored: Dictionary = crane_state_snapshot.duplicate(true)
			# Vector2 fields round-trip through JSON as strings if this
			# crane was held in a save. Coerce them back to Vector2 so the
			# draw / AI loops don't trip on a typed assignment.
			if not (restored.get("target_pos", Vector2.ZERO) is Vector2):
				restored["target_pos"] = Vector2.ZERO
			building_sys2.crane_states[grid_pos] = restored

	# Restore turret aim angles so a placed-back turret resumes pointing
	# the way it was when picked up, instead of snapping to angle 0.
	if data.is_turret():
		var combat_sys2 = get_node_or_null("CombatSystem")
		if combat_sys2:
			if "turret_angles" in combat_sys2 and payload.has("turret_aim_angle"):
				combat_sys2.turret_angles[grid_pos] = float(payload["turret_aim_angle"])
			var bsnap: Array = payload.get("turret_barrel_angles", [])
			if "turret_barrel_angles" in combat_sys2 and not bsnap.is_empty():
				combat_sys2.turret_barrel_angles[grid_pos] = bsnap.duplicate()

	# Restore any conveyor items that were on the belt at pickup time.
	# Keys in the snapshot are "dx,dy" offsets from the original
	# anchor; we replay them onto the same offsets from the new
	# anchor so a 1×1 belt with one item lands back exactly where it
	# was relative to the block.
	var conv_snap: Dictionary = payload.get("conveyor_items", {})
	if not conv_snap.is_empty():
		var logistics_drop = _logistics_ref()
		if logistics_drop and "conveyor_items" in logistics_drop:
			for rel_key in conv_snap:
				var parts: PackedStringArray = String(rel_key).split(",")
				if parts.size() != 2:
					continue
				var dx_i: int = int(parts[0])
				var dy_i: int = int(parts[1])
				var dest_cell: Vector2i = grid_pos + Vector2i(dx_i, dy_i)
				# Only restore if the destination cell ended up as a
				# conveyor-style block; otherwise the item would sit
				# stranded on a non-conveyor tile.
				logistics_drop.conveyor_items[dest_cell] = (conv_snap[rel_key] as Dictionary).duplicate(true)

	# Restore head-spin state (angle + velocity for every spinning
	# layer the block had at pickup). The placed block's tick takes
	# it from here — vel keeps easing toward 0 (or back up to the
	# producing spin target) so the player sees a smooth continuation
	# instead of a snap.
	var spin_snap: Dictionary = payload.get("head_spin_state", {})
	if not spin_snap.is_empty():
		var building_sys_spin = _building_sys_ref()
		if building_sys_spin and building_sys_spin.has_method("_restore_spin_state"):
			building_sys_spin._restore_spin_state(grid_pos, spin_snap)

	# Restore the block's internal-battery charge that was draining
	# while the block was carried. Power-only blocks don't ship a
	# `internal_battery_charge` field — defaults to 0 (network charges
	# it back up).
	var power_sys_drop = get_node_or_null("PowerSystem")
	if power_sys_drop and "_block_internal_battery" in power_sys_drop:
		var saved_charge: float = float(payload.get("internal_battery_charge", 0.0))
		var cap_drop: float = 0.0
		if power_sys_drop.has_method("resolve_block_battery_capacity"):
			cap_drop = power_sys_drop.resolve_block_battery_capacity(data)
		if cap_drop > 0.0:
			power_sys_drop._block_internal_battery[grid_pos] = clampf(saved_charge, 0.0, cap_drop)
	return true


## Returns the deconstruct progress (0.0 = just started, 1.0 = done) or -1.0 if not deconstructing.
func get_deconstruct_pct(grid_pos: Vector2i) -> float:
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	if not building_deconstruct_progress.has(anchor):
		return -1.0
	var entry: Dictionary = building_deconstruct_progress[anchor]
	return clampf(entry["progress"] / entry["build_time"], 0.0, 1.0)


# Completely removes a building from the grid.
# `by_enemy` distinguishes a destruction inflicted by combat damage (which
# feeds the Hold-B rebuild preview) from a player-initiated removal like a
# deconstruction or same-tile swap (which shouldn't — the player asked for
# that block to go away, so offering to rebuild it is noise).
func destroy_building(grid_pos: Vector2i, by_enemy: bool = false) -> void:
	if not placed_buildings.has(grid_pos):
		return

	var block_id = placed_buildings[grid_pos]
	var data = Registry.get_block(block_id)
	var faction = get_building_faction(grid_pos)
	var anchor = building_origins.get(grid_pos, grid_pos)
	var rot = building_rotation.get(grid_pos, 0)

	# Track enemy block destroyed stat
	if faction == Faction.FEROX or faction == Faction.DERELICT:
		stats_enemy_blocks_destroyed += 1

	# Queue ferox buildings for rebuild (only anchors, to avoid duplicates)
	if faction == Faction.FEROX and data and anchor == grid_pos:
		# Don't queue cores for rebuild
		if data.category != BlockData.BlockCategory.CORE:
			ferox_rebuild_queue.append({
				"block_id": block_id,
				"grid_pos": anchor,
				"rotation": rot,
			})

	# Track destroyed player buildings for rebuild mode — only when the
	# destruction was inflicted by enemies. Deconstructions / swaps set
	# by_enemy=false so they don't clutter the Hold-B preview.
	if by_enemy and faction == Faction.LUMINA and data and anchor == grid_pos:
		destroyed_player_buildings[anchor] = {
			"block_id": block_id,
			"rotation": rot,
		}

	# Emit BEFORE erasing so signal handlers can still read building data
	building_destroyed.emit(grid_pos)
	if by_enemy:
		building_destroyed_by_enemy.emit(grid_pos)

	# Track the cells we're about to free so we can replay any stashed
	# platforms back onto them once the cover is gone.
	var freed_cells: Array = []
	if data:
		for x in range(data.grid_size.x):
			for y in range(data.grid_size.y):
				freed_cells.append(anchor + Vector2i(x, y))
	else:
		freed_cells.append(grid_pos)

	# For multi-tile buildings, remove all tiles that share this block ID
	# and are adjacent (part of the same structure)
	if data and (data.grid_size.x > 1 or data.grid_size.y > 1):
		_remove_multi_tile_building(grid_pos, block_id, data)
	else:
		placed_buildings.erase(grid_pos)
		building_health.erase(grid_pos)
		building_rotation.erase(grid_pos)
		building_origins.erase(grid_pos)
		building_factions.erase(grid_pos)

	# Replay any stashed platform entries onto the freed cells. Skipped
	# when the destroyed block IS a platform (no platform-under-platform
	# stacking) so this is a no-op for platform decon.
	if data == null or not data.tags.has("platform"):
		_restore_platforms_at(freed_cells)

	# Check AFTER removal so the destroyed core isn't found in the scan
	if faction == Faction.FEROX and data and data.tags.has("core"):
		_check_enemy_cores_remaining()
	if faction == Faction.LUMINA and data and data.tags.has("core"):
		_check_player_cores_remaining()
		# Losing a core shrinks the storage cap, so any resource over
		# the new cap needs trimming right now — otherwise the pool
		# would sit permanently over capacity.
		clamp_resources_to_cap()

	building_build_progress.erase(anchor)
	building_deconstruct_progress.erase(anchor)
	building_resources_consumed.erase(anchor)
	building_resources_refunded.erase(anchor)
	pending_swaps.erase(anchor)
	var work_idx2: int = work_order.find(anchor)
	if work_idx2 >= 0:
		work_order.remove_at(work_idx2)
	var order_idx: int = build_order.find(anchor)
	if order_idx >= 0:
		build_order.remove_at(order_idx)
	# Clean up pause bookkeeping so nothing is left stranded-paused by
	# a destroyed trigger, and any explicit pause on this anchor is gone.
	resume_auto_paused_by(anchor)
	work_paused.erase(anchor)

	var unit_mgr = _unit_mgr_ref()
	if unit_mgr:
		unit_mgr.on_building_destroyed(grid_pos)


# Removes all tiles belonging to a multi-tile building.
func _remove_multi_tile_building(grid_pos: Vector2i, block_id: StringName, data: BlockData) -> void:
	# Find the anchor for this building
	var anchor = building_origins.get(grid_pos, grid_pos)

	# Remove all tiles belonging to this anchor
	for x in range(data.grid_size.x):
		for y in range(data.grid_size.y):
			var check_pos = anchor + Vector2i(x, y)
			if placed_buildings.has(check_pos) and placed_buildings[check_pos] == block_id:
				placed_buildings.erase(check_pos)
				building_health.erase(check_pos)
				building_rotation.erase(check_pos)
				building_origins.erase(check_pos)
				building_factions.erase(check_pos)
				var unit_mgr = _unit_mgr_ref()
				if unit_mgr:
					unit_mgr.on_building_destroyed(check_pos)


# Returns the health percentage (0.0 to 1.0) of a building.
func get_building_health_pct(grid_pos: Vector2i) -> float:
	if not placed_buildings.has(grid_pos):
		return 1.0
	var anchor: Vector2i = building_origins.get(grid_pos, grid_pos)
	if not building_health.has(anchor):
		return 1.0
	var block_id = placed_buildings[anchor]
	var data = Registry.get_block(block_id)
	if data == null:
		return 1.0
	return building_health[anchor] / data.max_health


# =========================
# CORE
# =========================

func place_core() -> void:
	var core_data = Registry.get_block(&"core_shard")
	if core_data == null:
		push_warning("Core block not found in Registry!")
		return

	for x in range(core_data.grid_size.x):
		for y in range(core_data.grid_size.y):
			var grid_pos = core_position + Vector2i(x, y)
			placed_buildings[grid_pos] = &"core_shard"
			building_health[grid_pos] = core_data.max_health
			building_origins[grid_pos] = core_position
			building_factions[grid_pos] = Faction.LUMINA

	building_placed.emit(&"core_shard", core_position)


# =========================
# COORDINATE HELPERS
# =========================

func world_to_grid(world_pos: Vector2) -> Vector2i:
	return Vector2i(
		floori(world_pos.x / GRID_SIZE),
		floori(world_pos.y / GRID_SIZE)
	)

func grid_to_world(grid_pos: Vector2i) -> Vector2:
	return Vector2(grid_pos.x * GRID_SIZE, grid_pos.y * GRID_SIZE)

func is_within_bounds(grid_pos: Vector2i) -> bool:
	return (
		grid_pos.x >= 0 and grid_pos.x < GRID_WIDTH and
		grid_pos.y >= 0 and grid_pos.y < GRID_HEIGHT
	)


## Draws a Mindustry-style beam between two points.
## canvas: the CanvasItem calling draw functions on
## from_pos / to_pos: positions in canvas-local coordinates
## color: the outer beam color (e.g. yellow for mining)
## pulse: 0.0-1.0 animation phase for pulsing alpha
## width: base width of the outer colored lines
## circle_radius: radius of the endpoint circles
static func draw_beam(canvas: CanvasItem, from_pos: Vector2, to_pos: Vector2, color: Color, pulse: float = 1.0, width: float = 5.0 * SPRITE_SCALE_FACTOR, circle_radius: float = 8.0 * SPRITE_SCALE_FACTOR) -> void:
	var alpha: float = 0.6 + 0.3 * pulse
	var outer_color := Color(color.r, color.g, color.b, alpha)
	var inner_color := Color(1.0, 1.0, 1.0, alpha)
	var inner_width: float = width * 0.5
	var inner_radius: float = circle_radius * 0.5

	# Outer colored lines (offset perpendicular to beam direction)
	var dir: Vector2 = (to_pos - from_pos).normalized()
	var perp: Vector2 = Vector2(-dir.y, dir.x)
	var offset: float = width * 0.6

	canvas.draw_line(from_pos + perp * offset, to_pos + perp * offset, outer_color, width, true)
	canvas.draw_line(from_pos - perp * offset, to_pos - perp * offset, outer_color, width, true)

	# Center white line
	canvas.draw_line(from_pos, to_pos, inner_color, inner_width, true)

	# Endpoint circles — outer colored, inner white
	# From
	canvas.draw_circle(from_pos, circle_radius, outer_color)
	canvas.draw_circle(from_pos, inner_radius, inner_color)
	# To
	canvas.draw_circle(to_pos, circle_radius, outer_color)
	canvas.draw_circle(to_pos, inner_radius, inner_color)


# =========================
# DERELICT CONVERSION
# =========================

## Check if any FEROX cores remain. If not, convert all FEROX buildings to DERELICT.
func _check_player_cores_remaining() -> void:
	for pos in placed_buildings:
		if get_building_faction(pos) == Faction.LUMINA:
			var bid = placed_buildings[pos]
			var d = Registry.get_block(bid)
			if d and d.tags.has("core"):
				return  # At least one LUMINA core still exists
	# No LUMINA cores remain — sector lost
	if not sector_lost:
		sector_lost = true
		world_paused = true
		var hud_node = _hud_ref()
		if hud_node and hud_node.has_method("show_sector_loss"):
			hud_node.show_sector_loss()


func _check_enemy_cores_remaining() -> void:
	for pos in placed_buildings:
		if get_building_faction(pos) == Faction.FEROX:
			var bid = placed_buildings[pos]
			var d = Registry.get_block(bid)
			if d and d.tags.has("core"):
				return  # At least one FEROX core still exists
	# No FEROX cores remain — convert all FEROX to DERELICT
	all_enemy_cores_destroyed = true
	_convert_ferox_to_derelict()


## Convert all remaining FEROX buildings to DERELICT faction.
func _convert_ferox_to_derelict() -> void:
	var converted := 0
	for pos in building_factions.keys():
		if building_factions[pos] == Faction.FEROX:
			building_factions[pos] = Faction.DERELICT
			converted += 1
	ferox_rebuild_queue.clear()  # Stop ferox rebuilds
	print("Main: Converted %d FEROX blocks to DERELICT." % converted)
	# Any FEROX units still on the map have nothing to defend or rebuild
	# to anymore — explode every one of them so the player isn't left
	# chasing stragglers across the map. Iterates a copy because
	# take_damage → _on_death → unit_manager.on_enemy_died mutates the
	# live array. We do NOT convert units to a neutral team or to
	# DERELICT — they all just die.
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if unit_mgr and unit_mgr.get("enemies") is Array:
		var ferox_killed := 0
		for u in unit_mgr.enemies.duplicate():
			if not is_instance_valid(u) or u.is_dead:
				continue
			if u.has_method("take_damage"):
				u.take_damage(1.0e9)
				ferox_killed += 1
		if ferox_killed > 0:
			print("Main: Exploded %d remaining FEROX units." % ferox_killed)


## Convert all DERELICT buildings in a rect to LUMINA.
func convert_derelict_in_rect(from: Vector2i, to: Vector2i) -> void:
	var min_pos := Vector2i(mini(from.x, to.x), mini(from.y, to.y))
	var max_pos := Vector2i(maxi(from.x, to.x), maxi(from.y, to.y))
	var building_sys = _building_sys_ref()
	var seen_anchors: Dictionary = {}
	for x in range(min_pos.x, max_pos.x + 1):
		for y in range(min_pos.y, max_pos.y + 1):
			var pos := Vector2i(x, y)
			if building_factions.get(pos, -1) == Faction.DERELICT:
				building_factions[pos] = Faction.LUMINA
				# Trigger the conversion flash on each captured block's
				# anchor exactly once — same yellow flash the launch
				# animation paints on pre-built LUMINA blocks, minus the
				# white kicker.
				if building_sys and building_sys.has_method("register_conversion_flash"):
					var anchor: Vector2i = building_origins.get(pos, pos)
					if not seen_anchors.has(anchor):
						seen_anchors[anchor] = true
						building_sys.register_conversion_flash(anchor)


## Queue destroyed player buildings in a rect for rebuild.
## Returns the number of buildings queued.
func queue_rebuild_in_rect(from: Vector2i, to: Vector2i) -> int:
	var min_pos := Vector2i(mini(from.x, to.x), mini(from.y, to.y))
	var max_pos := Vector2i(maxi(from.x, to.x), maxi(from.y, to.y))
	var count := 0
	var drone = _drone_ref()
	var building_sys = _building_sys_ref()
	for anchor in destroyed_player_buildings.keys():
		if anchor.x >= min_pos.x and anchor.x <= max_pos.x and anchor.y >= min_pos.y and anchor.y <= max_pos.y:
			var info: Dictionary = destroyed_player_buildings[anchor]
			var block_id: StringName = info["block_id"]
			var rot: int = info["rotation"]
			# Cell still empty? If something else got placed there in
			# the meantime we just drop the ghost.
			if not is_cell_empty(anchor):
				destroyed_player_buildings.erase(anchor)
				continue
			var in_range: bool = drone == null or drone.is_in_build_range(anchor)
			if in_range:
				var old_building = selected_building
				var old_rotation = placement_rotation
				selected_building = block_id
				placement_rotation = rot
				try_place_building(anchor)
				selected_building = old_building
				placement_rotation = old_rotation
				count += 1
			else:
				# Out of build range — defer to the placement queue so
				# it gets placed automatically once the drone gets
				# close enough. Mirrors the drag-place path which
				# silently queues distant cells instead of dropping
				# them. Without this, holding B over a far-away wreck
				# silently failed and the destroyed entry was lost.
				if building_sys != null and "_paused_queue" in building_sys:
					var already_queued := false
					for q in building_sys._paused_queue:
						if q.get("grid_pos") == anchor:
							already_queued = true
							break
					if not already_queued and building_sys.has_method("_can_place_ignoring_range") \
							and building_sys._can_place_ignoring_range(anchor, block_id, rot):
						building_sys._paused_queue.append({
							"grid_pos": anchor,
							"block_id": block_id,
							"rotation": rot,
						})
						count += 1
			destroyed_player_buildings.erase(anchor)
	return count


# =========================
# MULTI-CORE AI SHARDLINGS
# =========================
# Naming convention: AI shardlings live as direct children of Main
# with names "AIShardling_<x>_<y>" derived from their spawn-core
# anchor. The primary PlayerDrone keeps its name "PlayerDrone" so
# every existing /root/Main/PlayerDrone lookup still resolves to
# the player-controlled drone. _sync_ai_shardlings walks the live
# LUMINA-core list and spawns / despawns AI siblings so the set
# stays consistent across save/load and mid-game core placement.

var _ai_shardling_script: Script = null


func _shardling_node_name(anchor: Vector2i) -> String:
	return "AIShardling_%d_%d" % [anchor.x, anchor.y]


func _is_primary_core_anchor(anchor: Vector2i) -> bool:
	# The drone the player controls anchors on `core_position` (set
	# by place_core in _ready). Any other LUMINA core is treated as
	# an AI shardling host.
	return anchor == core_position


func _spawn_ai_shardling_for_core(anchor: Vector2i) -> void:
	if _is_primary_core_anchor(anchor):
		return
	var node_name: String = _shardling_node_name(anchor)
	if has_node(node_name):
		return
	if _ai_shardling_script == null:
		_ai_shardling_script = load("res://main/player_drone.gd")
	if _ai_shardling_script == null:
		push_warning("Main: could not load player_drone.gd for AI shardling.")
		return
	var node := Node2D.new()
	node.name = node_name
	node.set_script(_ai_shardling_script)
	# Set the AI flag + home core BEFORE adding to the tree so
	# player_drone._ready (which awaits a frame for the Registry)
	# already sees them when it parks the drone.
	node.set("ai_controlled", true)
	node.set("spawn_core_anchor", anchor)
	add_child(node)


func _despawn_ai_shardling_for_core(anchor: Vector2i) -> void:
	var node_name: String = _shardling_node_name(anchor)
	var node := get_node_or_null(node_name)
	if node:
		node.queue_free()


func _sync_ai_shardlings() -> void:
	# Spawn missing AI siblings for every non-primary core.
	for anchor in get_lumina_core_anchors():
		_spawn_ai_shardling_for_core(anchor)


func _on_building_completed_for_shardlings(block_id: StringName, anchor: Vector2i) -> void:
	var data = Registry.get_block(block_id)
	if data == null or not data.tags.has("core"):
		return
	if get_building_faction(anchor) != Faction.LUMINA:
		return
	_spawn_ai_shardling_for_core(anchor)


func _on_building_destroyed_for_shardlings(anchor: Vector2i) -> void:
	# When a core is removed we don't know its block id any more (the
	# entry has already been cleared from placed_buildings by this
	# point in the signal flow), so just attempt the despawn — the
	# helper is a no-op when no matching child exists.
	_despawn_ai_shardling_for_core(anchor)
