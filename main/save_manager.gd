extends Node

# ============================================================
# SAVE_MANAGER.GD - Map Save/Load System (Autoload)
# ============================================================
# Sector maps live in user://maps/, save games + the campaign roster
# live in user://saves/. The two used to share user://maps/, but a
# launch-time migration moves any leftover .save.json / campaign.json
# into user://saves/ on first run after the split.
#
# Two save modes:
#   1. "Map only" — Just tiles (the terrain layout). Like a
#      reusable map template you can start fresh games on.
#   2. "Full save" — Tiles + buildings + resources + drone
#      position. A complete game state snapshot.
#   3. "Sector" — Tiles + pre-placed buildings with factions.
#      A blank slate map template with enemy/player structures.
#
# Files are stored in Godot's user data directory:
#   - Windows: %APPDATA%\Godot\app_userdata\Bacteriums\{maps,saves}\
#   - macOS:   ~/Library/Application Support/Godot/app_userdata/Bacteriums/{maps,saves}/
#   - Linux:   ~/.local/share/godot/app_userdata/Bacteriums/{maps,saves}/
#
# HOW TO SET UP:
# 1. Go to Project → Project Settings → Autoload
# 2. Add this script with the name "SaveManager"
# ============================================================

# `SAVE_DIR` (kept under the historical name for back-compat with
# external callers like PlanetSelect) holds sector map files only —
# `<sector_id>.sector.json`. Full-game saves and the campaign roster
# live separately under `SAVES_DIR`.
const SAVE_DIR := "user://maps/"
const SAVES_DIR := "user://saves/"
const SCHEMATIC_DIR := "user://schematics/"
## Global hints are authored once and active in every sector — stored
## here so any sector landing can pull the same list. Bundled fallback
## at `res://data/game/global_hints.json` is consulted when the user
## file doesn't exist yet.
const GLOBAL_HINTS_USER_PATH := "user://global_hints.json"
const GLOBAL_HINTS_BUNDLED_PATH := "res://data/game/global_hints.json"

## Set to true when navigating to PlanetSelect from an active game.
## PlanetSelect checks this to show a "Back to Map" button.
var return_to_game := false

## Holds the Main scene while the player is browsing the planet
## select overlay. Detached from /root and parented under us (an
## autoload, which `change_scene_to_file` won't free) so the round
## trip game → planet select → back to game is instant — the original
## Main tree is just re-attached, with all live state intact.
var _parked_main: Node = null

## Preloaded once at boot so `change_scene_to_file` round-trips can be
## bypassed: launching a sector instantiates this PackedScene and adds
## it straight to `/root`, eliminating the one-frame black gap that
## the deferred scene swap leaves behind.
const _MAIN_PACKED_SCENE: PackedScene = preload("res://main/Main.tscn")


## Replaces the current scene with a freshly instantiated Main, all
## within the current frame so there's no render gap between the old
## scene tearing down and the new one's first frame. Caller should
## set `pending_map_path` / `pending_sector_id` first; Main._ready
## reads those during the add_child below.
##
## If the outgoing scene is a PlanetSelect (identified by the marker
## `refresh_for_reentry` method), it is PARKED under us instead of
## freed so the next visit reuses the live instance.
func swap_scene_to_main() -> void:
	var tree := get_tree()
	var old: Node = tree.current_scene
	var park_outgoing: bool = old != null and is_instance_valid(old) \
		and old.has_method("refresh_for_reentry")
	if old != null:
		if old is CanvasItem:
			(old as CanvasItem).visible = false
		elif old is Node3D:
			(old as Node3D).visible = false
		old.process_mode = Node.PROCESS_MODE_DISABLED
		# Rename + remove the outgoing Main out of /root BEFORE the
		# new one is added — otherwise both nodes share the name
		# "Main" for a frame and `/root/Main` resolves to the OLD
		# (now-freeing) instance.
		if old.name == "Main":
			old.name = "MainOld"
		var old_parent := old.get_parent()
		if old_parent:
			old_parent.remove_child(old)
	var fresh: Node = _MAIN_PACKED_SCENE.instantiate()
	tree.root.add_child(fresh)
	tree.current_scene = fresh
	if old != null:
		if park_outgoing:
			# park_planet_select expects a detached or attached node —
			# either way it ends up reparented under us. queue_free
			# does NOT run.
			park_planet_select(old)
		else:
			old.queue_free()


## Same idea as `swap_scene_to_main`, but the destination is
## PlanetSelect — uses the parked instance if one exists (instant
## revisit, no rebuild) and falls back to instantiating from the
## PackedScene resource. Outgoing scene is freed.
func swap_scene_to_planet_select() -> bool:
	var tree := get_tree()
	var old: Node = tree.current_scene
	if old != null:
		if old is CanvasItem:
			(old as CanvasItem).visible = false
		elif old is Node3D:
			(old as Node3D).visible = false
		old.process_mode = Node.PROCESS_MODE_DISABLED
		# Rename outgoing Main so /root/Main resolves to the new scene
		# if it ever lands at the same name slot.
		if old.name == "Main":
			old.name = "MainOld"
		var old_parent := old.get_parent()
		if old_parent:
			old_parent.remove_child(old)
	var fresh: Node = null
	if has_parked_planet_select():
		fresh = unpark_planet_select_to_tree()
		if fresh and fresh.has_method("refresh_for_reentry"):
			fresh.refresh_for_reentry()
	else:
		var packed: PackedScene = load("res://main/PlanetSelect.tscn") as PackedScene
		if packed != null:
			fresh = packed.instantiate()
			tree.root.add_child(fresh)
			tree.current_scene = fresh
	if fresh == null:
		# Last-resort fallback to the deferred scene swap.
		if old != null and old.get_parent() == null:
			tree.root.add_child(old)
		tree.change_scene_to_file("res://main/PlanetSelect.tscn")
		return false
	if old != null and is_instance_valid(old):
		old.queue_free()
	return true


func park_main_for_planet_view(main_node: Node) -> bool:
	if main_node == null:
		return false
	if _parked_main != null and _parked_main != main_node:
		# Stale park (player jumped to planet view from a different
		# sector without coming back). Release the previous tree so we
		# don't leak it.
		if is_instance_valid(_parked_main):
			_parked_main.queue_free()
		_parked_main = null
	# Persist while Main is still at /root/Main so any code path that
	# closes the window from the planet view (Quit, OS close, crash)
	# has a complete on-disk snapshot to restore from. Skipping disk
	# round-trip is only an optimization for the common Back-to-Game
	# case; we don't want to lose progress to an exit out of the parked
	# state.
	if active_sector_id != &"" and active_sector_id != &"_default":
		sync_active_sector_resources()
		save_sector(String(active_sector_id))
	save_campaign()
	_parked_main = main_node
	# Stop ticks + drawing while parked. CanvasLayers are independent
	# of Node2D visibility so HUD / TechTreeUI / DatabaseUI need their
	# own toggle.
	main_node.process_mode = Node.PROCESS_MODE_DISABLED
	if main_node is CanvasItem:
		(main_node as CanvasItem).visible = false
	for c in main_node.get_children():
		if c is CanvasLayer:
			(c as CanvasLayer).visible = false
	var parent := main_node.get_parent()
	if parent:
		parent.remove_child(main_node)
	add_child(main_node)
	# The caller (e.g. HUD's planet-map button) will immediately swap
	# to a new scene. If we leave `tree.current_scene` pointing at the
	# parked Main, any downstream `var old = tree.current_scene` (in
	# swap_scene_to_planet_select, change_scene_to_file's deferred
	# free, etc.) will treat the parked node as the outgoing scene and
	# queue_free it — destroying the park and leaving a dangling
	# `_parked_main` reference. Clear the pointer so the next swap
	# operates on a clean slate.
	get_tree().current_scene = null
	return true


func has_parked_main() -> bool:
	# Self-heal a dangling reference (the parked instance was freed
	# elsewhere). Without this, every subsequent has_parked_main()
	# call returns false but `_parked_main` keeps the freed pointer,
	# masking the bug from the discard path.
	if _parked_main != null and not is_instance_valid(_parked_main):
		_parked_main = null
	return _parked_main != null


## Plays the launch animation in the parked Main (sector A) before
## swapping to a fresh Main for the target sector. Falls back to a
## direct swap when no parked Main exists (player came from the main
## menu).
##
## Call from PlanetSelect's launch handler instead of
## `swap_scene_to_main()`. PlanetSelect frees itself; the parked Main
## becomes current_scene, plays its `LaunchAnimation.play_launch()`,
## and on `launch_complete` performs the swap with `pending_map_path`
## already set to the target sector.
func queue_launch_with_animation() -> void:
	# Same gate as the landing animation: only play the launch
	# animation when the player committed to a launch via the resource
	# cost overlay. Continue / direct PLAY / starting_grounds bypass
	# the overlay AND skip both animations — they hand straight to
	# the swap so resuming a sector doesn't replay launch every time.
	if not pending_landing_animation:
		swap_scene_to_main()
		return
	if not has_parked_main():
		swap_scene_to_main()
		return
	# Remember the outgoing scene (PlanetSelect) — `unpark_main_to_tree`
	# will steal current_scene away from it, but the node itself stays
	# parented to /root until we explicitly free it.
	var tree := get_tree()
	var outgoing: Node = tree.current_scene
	if not unpark_main_to_tree():
		swap_scene_to_main()
		return
	# ONLY release the outgoing scene — NOT every other root child.
	# Autoloads live as root children and freeing them detonates the
	# next time any system tries to call Registry.get_block().
	# PlanetSelect is parked (marker: `refresh_for_reentry`) instead
	# of freed so the next visit reuses the live instance.
	if outgoing != null and is_instance_valid(outgoing) and outgoing != tree.current_scene:
		if outgoing.has_method("refresh_for_reentry"):
			park_planet_select(outgoing)
		else:
			outgoing.queue_free()
	# Kick the launch animation on Main's LaunchAnimation node, then
	# swap to the new Main when it finishes.
	var main_node = tree.current_scene
	if main_node == null:
		swap_scene_to_main()
		return
	var la = main_node.get_node_or_null("LaunchAnimation")
	if la == null or not la.has_method("play_launch"):
		swap_scene_to_main()
		return
	if not la.is_connected("launch_complete", swap_scene_to_main):
		la.launch_complete.connect(swap_scene_to_main, CONNECT_ONE_SHOT)
	la.play_launch()


## Re-attaches the parked Main back into /root as the current scene.
## Returns true on success. Caller is responsible for freeing whatever
## scene was previously current (e.g. PlanetSelect).
func unpark_main_to_tree() -> bool:
	if not has_parked_main():
		return false
	var m: Node = _parked_main
	_parked_main = null
	remove_child(m)
	get_tree().root.add_child(m)
	get_tree().current_scene = m
	m.process_mode = Node.PROCESS_MODE_INHERIT
	if m is CanvasItem:
		(m as CanvasItem).visible = true
	for c in m.get_children():
		if c is CanvasLayer:
			(c as CanvasLayer).visible = true
	return true


## Drops the parked tree entirely (used when the player picks a new
## sector — the cached one is stale and must be rebuilt fresh).
func discard_parked_main() -> void:
	if has_parked_main():
		_parked_main.queue_free()
	_parked_main = null


## Holds the live PlanetSelect scene while the player is in a sector
## (or anywhere else). Same idea as `_parked_main`: parking saves the
## ~second-or-two it costs to instantiate the 3D planet grid + UI on
## every revisit. The instance lives under us (an autoload) so
## scene-change calls don't free it.
var _parked_planet_select: Node = null


## Parks a PlanetSelect instance under us instead of letting it free.
## Caller should remove the node from the tree (or let
## `change_scene_to_file` swap it out) AFTER this returns. Returns
## true on success.
func park_planet_select(ps_node: Node) -> bool:
	if ps_node == null:
		return false
	if _parked_planet_select != null and _parked_planet_select != ps_node:
		# Stale park — release the previous one so we don't leak it.
		if is_instance_valid(_parked_planet_select):
			_parked_planet_select.queue_free()
		_parked_planet_select = null
	_parked_planet_select = ps_node
	# Hide the Node3D subtree pre-emptively so any pre-_ready paint
	# doesn't leak through.
	if ps_node is Node3D:
		(ps_node as Node3D).visible = false
	var parent := ps_node.get_parent()
	if parent:
		parent.remove_child(ps_node)
	# add_child triggers `_ready` on a fresh instance (boot-time
	# pre-park path). During _ready PlanetSelect builds a CanvasLayer
	# HUD with the planet tabs, tech-tree button, etc.; those would
	# render on top of the main menu unless we hide them AFTER they
	# exist. The full disable + visibility sweep therefore runs AFTER
	# add_child, not before.
	add_child(ps_node)
	ps_node.process_mode = Node.PROCESS_MODE_DISABLED
	if ps_node is Node3D:
		(ps_node as Node3D).visible = false
	_hide_planet_select_canvas_layers(ps_node)
	return true


## Walks every direct + nested child of a PlanetSelect tree and flips
## any CanvasLayer it finds to `visible = false`. CanvasLayers render
## independently of their parent's visibility, so a plain
## `Node3D.visible = false` on PlanetSelect doesn't hide the HUD.
func _hide_planet_select_canvas_layers(root: Node) -> void:
	for c in root.get_children():
		if c is CanvasLayer:
			(c as CanvasLayer).visible = false
		# Nested CanvasLayers (rare but possible — e.g. database UI
		# popup inside the planet-select HUD) need the same treatment.
		_hide_planet_select_canvas_layers(c)


func has_parked_planet_select() -> bool:
	# Self-heal a dangling reference if the parked instance was freed
	# elsewhere — same pattern as `has_parked_main` above.
	if _parked_planet_select != null and not is_instance_valid(_parked_planet_select):
		_parked_planet_select = null
	return _parked_planet_select != null


## Re-attaches the parked PlanetSelect back into /root as the current
## scene. Returns the node on success (so the caller can immediately
## invoke any refresh-on-reentry method), null on failure.
func unpark_planet_select_to_tree() -> Node:
	if not has_parked_planet_select():
		return null
	var ps: Node = _parked_planet_select
	_parked_planet_select = null
	remove_child(ps)
	get_tree().root.add_child(ps)
	get_tree().current_scene = ps
	ps.process_mode = Node.PROCESS_MODE_INHERIT
	if ps is Node3D:
		(ps as Node3D).visible = true
	_show_planet_select_canvas_layers(ps)
	return ps


## Mirror of `_hide_planet_select_canvas_layers` — restores every
## CanvasLayer that was hidden by parking.
func _show_planet_select_canvas_layers(root: Node) -> void:
	for c in root.get_children():
		if c is CanvasLayer:
			(c as CanvasLayer).visible = true
		_show_planet_select_canvas_layers(c)


func discard_parked_planet_select() -> void:
	if has_parked_planet_select():
		_parked_planet_select.queue_free()
	_parked_planet_select = null

## Set to true when navigating to PlanetSelect from the main menu.
## PlanetSelect checks this to show a "Back to Menu" button.
var return_to_menu := false

## If set, the game scene loads this map file on startup, then clears it.
## Used by PlanetSelect to pass sector map paths across scene transitions.
var pending_map_path := ""

## Sector ID that was launched (set by PlanetSelect, consumed by Main).
var pending_sector_id: StringName = &""

## Set true by PlanetSelect when the player commits to a launch via
## the resource-cost overlay (first launch into a sector, or
## post-abandon re-launch). Consumed by Main on the next sector load
## to gate the landing animation — "continue" returns and direct
## scene loads (CONTINUE / PLAY / starting_grounds) skip it.
var pending_landing_animation: bool = false

## Per-resource starter amounts the player dialed in on the launch
## overlay. Keyed by mat_* item id, value = integer amount. The cost
## was already deducted from the source sector by PlanetSelect; Main
## consumes this dict once on landing, adds each entry to its
## stockpile, and clears it so subsequent loads don't accidentally
## re-seed.
var pending_seed_pack: Dictionary = {}

## The sector currently being played (set by Main, cleared on exit).
var active_sector_id: StringName = &""

## Cross-sector cargo dispatched by the Launchpad. Keyed by destination
## sector id (StringName), value is an Array of pod descriptors:
##   { items: Dict<StringName,int>, fluids: Dict<StringName,float>,
##     from_sector: StringName }
## Drained at sector-load time by the destination's logistics: each pod
## is funneled into the Landing Pad's block_storage so the player picks
## up the cargo when they return.
var pending_pod_deliveries: Dictionary = {}
# Per-landing-pad delivery counter for v8-style fairness across multi-
# pad sectors. Without this, two pads with identical filters always
# see the FIRST one in the routing list win — the second never lands a
# pod. v8 uses a priority swap; we use the same idea via a counter,
# picking the live matching pad with the fewest deliveries.
# StringName(sector_id) → Dictionary["x,y" → int].
var landing_pad_delivery_count: Dictionary = {}

## Snapshot of every saved sector's Landing Pad filters so a Launchpad
## on sector A can validate that sector B has a matching pad BEFORE
## queuing the delivery. Keyed by sector id:
##   landing_pad_filters_by_sector[sector_id] = {
##       <anchor "x,y"> : [item_id, ...]   // 0-2 entries
##   }
## Refreshed every time a sector is saved (see `save_sector`).
var landing_pad_filters_by_sector: Dictionary = {}

## Set by Launchpad when the player clicks its "Select sector" button.
## planet_select.gd reads this on _ready, locks the view to Tarkon,
## switches to "pick a sector for the launchpad" UI, and on pick reloads
## the source sector with `pending_launchpad_pick_result` populated so
## main.gd can write the selection back to the launchpad anchor.
##   { source_sector: StringName, anchor: Vector2i }
var launchpad_pick_request: Dictionary = {}
## Result handed back to the source sector after the player picks a
## destination via the planet-select scene. Drained in main._ready after
## loading the source sector. Format:
##   { anchor: Vector2i, sector_id: StringName }
var pending_launchpad_pick_result: Dictionary = {}

## Per-sector resource storage for the global tech tree pool.
## Maps sector_id (StringName) → resources Dictionary (item_id → amount).
var sector_resources: Dictionary = {}

## Per-sector offline production rates (items per second).
## Maps sector_id → {item_id: float rate}. Captured when the sector is saved
## via SectorProductionSim, then applied to sector_resources across elapsed
## real-time via advance_offline_production().
var sector_production_rates: Dictionary = {}

## Per-sector unix timestamp of the last accrual tick. When a sector is
## re-entered or accrual is requested, (now - timestamp) * rate is added to
## that sector's sector_resources, then the timestamp resets to now.
var sector_production_timestamps: Dictionary = {}

## Fractional carryover so slow producers don't lose sub-integer production
## between accrual calls. Maps sector_id → {item_id: float fractional}.
var _sector_production_fractions: Dictionary = {}

## Per-sector storage cap (per resource) captured at snapshot time. Offline
## accrual clamps against this so a sector with a 4K-capacity shard can't
## keep filling up past 4K while the player is away. Maps sector_id → int.
var sector_storage_caps: Dictionary = {}

## Global hint definitions (cross-sector). Loaded from disk on `_ready`,
## merged into every sector's `_hints` on landing. Authored via the
## script editor's hint tab — flipping a hint's `global` flag moves it
## into this list.
var global_hints: Array = []
## Per-id runtime state for global hints. Same shape as SectorScript's
## per-sector `_hint_runtime`, but lives at the campaign level so a hint
## dismissed in sector A doesn't reactivate in sector B. Saved as part
## of campaign.json.
var global_hints_runtime: Dictionary = {}


## Wipes every player save while leaving the editor's `/maps` directory
## untouched. Removes `campaign.json`, every `.save.json`, and every
## sector autosave (`.sector.json`) under `user://saves/`. Editor sector
## templates live in `user://maps/` and are never touched.
func reset_campaign() -> void:
	# Clear in-memory campaign state so the next save round-trip writes
	# a clean slate.
	sector_resources.clear()
	sector_production_rates.clear()
	sector_production_timestamps.clear()
	_sector_production_fractions.clear()
	sector_storage_caps.clear()
	active_sector_id = &""
	pending_sector_id = &""
	pending_map_path = ""
	pending_seed_pack.clear()
	# Hints dismissed in a previous campaign would otherwise carry into
	# the new one and stay hidden forever. Same dict that gets saved /
	# loaded with `campaign.json`, so wipe it alongside the on-disk file.
	global_hints_runtime.clear()
	# Drop any parked-Main left over from a planet-map round-trip.
	# Without this the parked tree's `main.resources` survives the wipe
	# and the next `sync_active_sector_resources` (e.g. from opening
	# the tech tree) re-seeds `sector_resources` from it, which then
	# shows up in the tech tree's Global Resources panel as "magic"
	# resources after a wipe. Same applies for any battery reserves
	# the parked PowerSystem was carrying.
	discard_parked_main()
	# Zero live game state too — if Main is still in /root (player
	# wiped while in-game) `main.resources`, `main.ferox_resources`,
	# and the power network's persistent battery reserves all need
	# to go to zero so the next save round-trip can't write them
	# back into the campaign pool.
	var live_main = get_node_or_null("/root/Main")
	if live_main:
		if "resources" in live_main and live_main.resources is Dictionary:
			for k in live_main.resources.keys():
				live_main.resources[k] = 0
			if live_main.has_signal("resources_changed"):
				live_main.resources_changed.emit(live_main.resources)
		if "ferox_resources" in live_main and live_main.ferox_resources is Dictionary:
			for k in live_main.ferox_resources.keys():
				live_main.ferox_resources[k] = 0
			if live_main.has_signal("ferox_resources_changed"):
				live_main.ferox_resources_changed.emit(live_main.ferox_resources)
		var power_sys = live_main.get_node_or_null("PowerSystem")
		if power_sys and "_battery_stored" in power_sys \
				and power_sys._battery_stored is Dictionary:
			power_sys._battery_stored.clear()
		if power_sys and "_block_internal_battery" in power_sys \
				and power_sys._block_internal_battery is Dictionary:
			power_sys._block_internal_battery.clear()
	# Wipe everything under /saves.
	var dir = DirAccess.open(SAVES_DIR)
	if dir != null:
		dir.list_dir_begin()
		var fname = dir.get_next()
		while fname != "":
			if fname.ends_with(".save.json") \
					or fname.ends_with(".sector.json") \
					or fname == "campaign.json":
				DirAccess.remove_absolute(SAVES_DIR + fname)
			fname = dir.get_next()
		dir.list_dir_end()
	# If a live Main is still standing the player's terrain / placed
	# buildings / build queue / drone / etc. all survived the in-memory
	# clear above. Just zeroing `main.resources` isn't enough — every
	# pre-placed FEROX wall the player tore down stays torn down, the
	# autosave's gone but the live tree still shows the post-tear state.
	# Boot to the main menu so the player gets a fresh scene-tree on
	# their next sector launch.
	var live_main_after = get_node_or_null("/root/Main")
	if live_main_after:
		get_tree().change_scene_to_file("res://main/MainMenu.tscn")
	print("SaveManager: Campaign reset — /saves wiped, /maps preserved.")


func _migrate_legacy_saves() -> void:
	var dir = DirAccess.open(SAVE_DIR)
	if dir == null:
		return
	# Build a lookup of known sector ids. `*.sector.json` filenames
	# whose stem matches one of these are gameplay autosaves and should
	# move to /saves; anything else (e.g. WFR.sector.json, the editor's
	# short-name template) stays in /maps.
	var known_sector_ids: Dictionary = {}
	if Registry != null and "sectors" in Registry:
		for sid in Registry.sectors.keys():
			known_sector_ids[String(sid)] = true
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		var legacy_path: String = SAVE_DIR + fname
		# Wipe the legacy `_default` placeholder file outright — it was
		# never a real sector, just leakage from the old
		# sync_active_sector_resources fallback.
		if fname == "_default.sector.json":
			DirAccess.remove_absolute(legacy_path)
			print("SaveManager: removed legacy _default.sector.json placeholder")
			fname = dir.get_next()
			continue
		var should_move := false
		if fname.ends_with(".save.json"):
			should_move = true
		elif fname == "campaign.json":
			should_move = true
		elif fname.ends_with(".sector.json"):
			# Only move sector autosaves (file stem matches a known
			# sector id). Editor templates with arbitrary names stay
			# behind in /maps.
			var stem: String = fname.replace(".sector.json", "")
			if known_sector_ids.has(stem):
				should_move = true
		if should_move:
			var dest_path: String = SAVES_DIR + fname
			# `rename_absolute` is atomic on the same filesystem, which
			# user:// always is. Don't clobber a file that already exists
			# in the new location — assume the new one is authoritative.
			if not FileAccess.file_exists(dest_path):
				DirAccess.rename_absolute(legacy_path, dest_path)
				print("SaveManager: migrated %s → %s" % [legacy_path, dest_path])
			else:
				DirAccess.remove_absolute(legacy_path)
		fname = dir.get_next()
	dir.list_dir_end()


## Removes any `_default.sector.json` left over from the old fallback
## key. Runs on launch as a one-time cleanup; safe to call repeatedly.
func _purge_default_sector_files() -> void:
	for d in [SAVE_DIR, SAVES_DIR]:
		var p: String = d + "_default.sector.json"
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
			print("SaveManager: purged %s" % p)


## Auto-wiper cadence: every N seconds, _process re-runs the per-sector
## storage cap clamp so the global resource pool can never drift over
## cap regardless of when (or whether) UIs poll it. Mirrors the live
## `clamp_resources_to_cap` sweep that Main does on the active sector's
## stockpile.
const _AUTO_WIPE_INTERVAL: float = 1.0
var _auto_wipe_timer: float = 0.0


func _ready() -> void:
	# Create the maps + saves directories if they don't exist.
	# DirAccess is Godot's file system API.
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	DirAccess.make_dir_recursive_absolute(SAVES_DIR)
	DirAccess.make_dir_recursive_absolute(SCHEMATIC_DIR)
	# One-time migration: older builds wrote save games + campaign.json
	# into `user://maps/`. Move them into `user://saves/` so the maps dir
	# only contains sector files going forward. Skips silently if there's
	# nothing to move (i.e. fresh install or already migrated).
	_migrate_legacy_saves()
	# Purge any leftover `_default.sector.json` files from the legacy
	# fallback path that's been removed.
	_purge_default_sector_files()
	# Pull global hint definitions off disk so any sector landing can
	# merge them into its hint list synchronously.
	load_global_hints_file()
	# Wait for TechTree to finish threaded loading before loading campaign save
	if TechTree.is_loaded:
		call_deferred("load_campaign")
	else:
		TechTree.tech_tree_ready.connect(_on_tech_tree_ready, CONNECT_ONE_SHOT)


## Autoload-level close-request handler so pressing the X button works from
## ANY scene (main menu, planet select, in-game). The project has
## application/config/auto_accept_quit disabled so in-game saves fire before
## quit — without this handler, closing the window from any non-Main scene
## would silently do nothing, forcing the player to kill the process.
## Main.gd additionally handles its own NOTIFICATION_WM_CLOSE_REQUEST for
## save-on-close; both handlers ultimately call get_tree().quit().
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# If an in-game sector is active, persist it before exiting.
		if active_sector_id != &"" and active_sector_id != &"_default":
			sync_active_sector_resources()
			save_sector(active_sector_id)
		save_campaign()
		get_tree().quit()


func _on_tech_tree_ready() -> void:
	load_campaign()


## Auto-wiper. Ticks every _AUTO_WIPE_INTERVAL seconds and clamps every
## sector's stockpile back to its recorded core-storage cap. Cheap (one
## dict scan) so a small interval is fine. Caches with no recorded cap
## are skipped — see `_clamp_sector_resources_to_caps` for the rule.
func _process(delta: float) -> void:
	_auto_wipe_timer += delta
	if _auto_wipe_timer < _AUTO_WIPE_INTERVAL:
		return
	_auto_wipe_timer = 0.0
	# Refresh the active sector's cache FROM main.resources first.
	# Without this the cache lags whatever the player accumulated since
	# the last autosave/sector-switch, so the clamper trims a stale
	# snapshot and the sync-back below either does nothing or worse,
	# trims main DOWN to the stale (lower) cache value. Re-sync first
	# guarantees the clamp sees the live numbers.
	sync_active_sector_resources()
	_clamp_sector_resources_to_caps()
	# Push the cap-trimmed totals back into main.resources so the live
	# HUD reflects them immediately. Also catches saves/legacy values
	# that ended up over-cap mid-session.
	if active_sector_id != &"" and sector_resources.has(active_sector_id):
		var main = get_node_or_null("/root/Main")
		if main and main.get("resources"):
			var bucket: Dictionary = sector_resources[active_sector_id]
			var changed := false
			for key in bucket:
				if main.resources.has(key) \
						and int(main.resources[key]) > int(bucket[key]):
					main.resources[key] = int(bucket[key])
					changed = true
			# Scrub incinerated items (coal, sand) out of the live
			# stockpile too — legacy saves recorded under the old
			# "coal counts as a resource" rule keep showing it in the
			# HUD until cleared. The cache scrub above already
			# handles the global pool.
			if main.has_method("is_incinerated_at_core"):
				for key in main.resources.keys():
					if main.is_incinerated_at_core(key) and int(main.resources[key]) > 0:
						main.resources[key] = 0
						changed = true
			if changed and main.has_signal("resources_changed"):
				main.resources_changed.emit(main.resources)




# =========================
# SAVE: FULL GAME STATE
# =========================



# =========================
# LOAD: FULL GAME STATE
# =========================



# =========================
# LIST SAVES
# =========================



## Returns an array of available sector names.
func list_sectors() -> PackedStringArray:
	return _list_files(SAVE_DIR, ".sector.json")


func _list_files(dir_path: String, suffix: String) -> PackedStringArray:
	var result = PackedStringArray()
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return result

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name.ends_with(suffix):
			# Strip the suffix to get just the name
			result.append(file_name.replace(suffix, ""))
		file_name = dir.get_next()
	dir.list_dir_end()
	return result


# =========================
# DELETE
# =========================



## Deletes a sector file.
func delete_sector(sector_name: String) -> bool:
	# Wipe campaign-level pools for this sector too — otherwise an abandon
	# leaves the on-disk file gone but the accrued offline-production
	# stockpile (and rates / timestamps / fractions / caps) lingers in the
	# campaign save, and a relaunch hands it back to the player on landing.
	var sid: StringName = StringName(sector_name)
	# If this sector was captured, leave a breadcrumb so planet-select can
	# render its outline in white ("abandoned") instead of gold ("captured")
	# or green ("unlocked, never captured"). Re-capturing clears the flag.
	if TechTree.is_sector_captured(sid):
		TechTree.mark_sector_abandoned(sid)
	sector_resources.erase(sid)
	sector_production_rates.erase(sid)
	sector_production_timestamps.erase(sid)
	_sector_production_fractions.erase(sid)
	sector_storage_caps.erase(sid)
	# Persist the cleared pools so a crash before the next save doesn't
	# resurrect them from the previous campaign.json.
	save_campaign()
	# Only delete the player's autosave — never touch the editor
	# template under `user://maps/`, which is treated as read-only by
	# gameplay code.
	var path = SAVES_DIR + sector_name + ".sector.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		return true
	return false


# =========================
# SAVE: SECTOR (tiles + buildings + factions)
# =========================

## Saves terrain + pre-placed buildings with factions (no resources/drone/health).
## Saves a sector. By default this writes a *gameplay autosave* into
## `user://saves/` — the file the player's progress lives in. The map
## editor's "Save Sector" button passes `as_template=true` so its
## output goes to `user://maps/` instead, where editor-authored
## templates live alongside the bundled ones.
func save_sector(sector_name: String, as_template: bool = false) -> bool:
	var main = get_node_or_null("/root/Main")
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	if main == null or terrain == null:
		push_warning("SaveManager: Can't find Main or TerrainSystem!")
		return false

	# Links live on main.linked_pairs in the editor, PowerSystem.linked_pairs in gameplay
	var links: Array = []
	if main.get("linked_pairs") != null:
		links = main.linked_pairs
	else:
		var power_sys = get_node_or_null("/root/Main/PowerSystem")
		if power_sys and power_sys.get("linked_pairs") != null:
			links = power_sys.linked_pairs

	# Save drone position
	var drone = get_node_or_null("/root/Main/PlayerDrone")
	var drone_pos := ""
	if drone:
		drone_pos = "%d,%d" % [int(drone.position.x), int(drone.position.y)]

	# Save resources
	var res_save := {}
	for item_id in main.resources:
		if main.resources[item_id] > 0:
			res_save[str(item_id)] = main.resources[item_id]

	# Save build progress & order (only in gameplay, not map editor)
	var build_progress_save := {}
	var build_order_save: Array = []
	var work_order_save: Array = []
	var resources_consumed_save := {}
	var resources_refunded_save := {}
	if "building_build_progress" in main:
		for anchor in main.building_build_progress:
			build_progress_save[_vec2i_to_str(anchor)] = main.building_build_progress[anchor]
	if "build_order" in main:
		for anchor in main.build_order:
			build_order_save.append(_vec2i_to_str(anchor))
	if "work_order" in main:
		for anchor in main.work_order:
			work_order_save.append(_vec2i_to_str(anchor))
	if "building_resources_consumed" in main:
		for anchor in main.building_resources_consumed:
			var inner := {}
			for rk in main.building_resources_consumed[anchor]:
				inner[str(rk)] = int(main.building_resources_consumed[anchor][rk])
			resources_consumed_save[_vec2i_to_str(anchor)] = inner
	if "building_resources_refunded" in main:
		for anchor in main.building_resources_refunded:
			var inner := {}
			for rk in main.building_resources_refunded[anchor]:
				inner[str(rk)] = int(main.building_resources_refunded[anchor][rk])
			resources_refunded_save[_vec2i_to_str(anchor)] = inner

	# Save player units
	var units_save: Array = []
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if unit_mgr:
		for unit in unit_mgr.player_units:
			if unit and is_instance_valid(unit) and unit.data:
				# Base fields + full runtime pose/command state via the shared
				# capture (facing/aim, turret-mount rotations, move/build
				# targets, hold-fire, mining/assist, upgrades) so a saved unit
				# reloads exactly as it was, not at a default heading.
				var u_entry := {
					"unit_id": str(unit.data.id),
					"x": unit.position.x,
					"y": unit.position.y,
					"health": unit.health,
				}
				if unit.has_method("capture_payload_state"):
					unit.capture_payload_state(u_entry)
				units_save.append(u_entry)

	# Save enemy (Ferox) units too. Wave-spawned enemies used to be left to
	# respawn on load, but fabricator-made enemies (e.g. a Ferox naval
	# fabricator's units) are NOT driven by the wave schedule, so without this
	# they'd vanish permanently after a save/load. The wave manager resumes
	# from its restored wave index and only spawns FUTURE waves, so persisting
	# the current live enemies here doesn't double them up.
	var enemies_save: Array = []
	if unit_mgr:
		for enemy in unit_mgr.enemies:
			if enemy and is_instance_valid(enemy) and not enemy.is_dead and enemy.data:
				var e_entry := {
					"unit_id": str(enemy.data.id),
					"x": enemy.position.x,
					"y": enemy.position.y,
					"health": enemy.health,
				}
				if enemy.has_method("capture_payload_state"):
					enemy.capture_payload_state(e_entry)
				enemies_save.append(e_entry)

	# Save logistics state (block storage, conveyor items, factory buffers)
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	var block_storage_save := {}
	var conveyor_items_save := {}
	var factory_buffers_save := {}
	if logistics:
		for origin in logistics.block_storage:
			var storage = logistics.block_storage[origin]
			var items_dict := {}
			for k in storage["items"]:
				items_dict[str(k)] = storage["items"][k]
			var fluids_dict := {}
			for k in storage["fluids"]:
				fluids_dict[str(k)] = storage["fluids"][k]
			if not items_dict.is_empty() or not fluids_dict.is_empty():
				block_storage_save[_vec2i_to_str(origin)] = {"items": items_dict, "fluids": fluids_dict}
		for pos in logistics.conveyor_items:
			var entry = logistics.conveyor_items[pos]
			conveyor_items_save[_vec2i_to_str(pos)] = {
				"item_id": str(entry["item_id"]),
				"progress": entry["progress"],
				"entry_dir": entry.get("entry_dir", -1),
			}
		for origin in logistics.factory_buffers:
			var state = logistics.factory_buffers[origin]
			var inputs_dict := {}
			for k in state["inputs"]:
				inputs_dict[str(k)] = state["inputs"][k]
			var save_entry := {
				"inputs": inputs_dict,
				"phase": state["phase"],
				"timer": state["timer"],
			}
			# Persist ejection/holding bookkeeping so a unit fabricator
			# that was mid-eject or waiting on a blocked output resumes
			# cleanly after a reload instead of stalling with no payload.
			if state.has("eject_progress"):
				save_entry["eject_progress"] = state["eject_progress"]
			if state.get("held_payload") != null:
				var hp: Dictionary = state["held_payload"]
				var hp_save := {}
				for k in hp:
					hp_save[str(k)] = hp[k]
				save_entry["held_payload"] = hp_save
			factory_buffers_save[_vec2i_to_str(origin)] = save_entry

	# Save payload transport state
	var payload_items_save := {}
	var constructor_state_save := {}
	var deconstructor_state_save := {}
	var loader_state_save := {}
	var unloader_state_save := {}
	var refabricator_state_save := {}
	if logistics:
		if "payload_items" in logistics:
			for pos in logistics.payload_items:
				var entry = logistics.payload_items[pos]
				var pd = entry.get("payload_data", {})
				payload_items_save[_vec2i_to_str(pos)] = {
					"payload_data": _ser_payload(pd),
					"progress": entry.get("progress", 0.0),
					"entry_dir": entry.get("entry_dir", -1),
				}
		# Refabricator state: phase + in/out unit ids + processing timer.
		# Without this the refab resets to idle on every reload, losing any
		# unit that was mid-process, and a refab that was stuck in
		# "outputting" (output blocked downstream) wouldn't be recoverable
		# without re-feeding it from scratch.
		if "refabricator_state" in logistics:
			for pos in logistics.refabricator_state:
				var rs: Dictionary = logistics.refabricator_state[pos]
				refabricator_state_save[_vec2i_to_str(pos)] = {
					"phase": String(rs.get("phase", "idle")),
					"in_unit_id": String(rs.get("in_unit_id", &"")),
					"out_unit_id": String(rs.get("out_unit_id", &"")),
					"timer": float(rs.get("timer", 0.0)),
					"selected_t2": String(rs.get("selected_t2", &"")),
				}
		if "constructor_state" in logistics:
			for pos in logistics.constructor_state:
				var state = logistics.constructor_state[pos]
				var collected_save := {}
				for k in state.get("collected", {}):
					collected_save[str(k)] = state["collected"][k]
				# `paid` accumulates while the constructor is in the
				# "building" phase — drains items from `collected` as the
				# build timer advances. Without persisting it, a save in
				# mid-build would re-pay items the player had already
				# spent on the in-progress block on next load.
				var paid_save := {}
				for k in state.get("paid", {}):
					paid_save[str(k)] = state["paid"][k]
				constructor_state_save[_vec2i_to_str(pos)] = {
					"selected_block": str(state.get("selected_block", &"")),
					"collected": collected_save,
					"paid": paid_save,
					"phase": str(state.get("phase", "idle")),
					"timer": state.get("timer", 0.0),
				}
	# Editor mode (no LogisticsSystem): fall back to BuildingSystem's
	# authored-selection dicts so selections made in the map editor
	# survive into the sector .json.
	if building_sys:
		if refabricator_state_save.is_empty() and "editor_refabricator_state" in building_sys:
			for pos in building_sys.editor_refabricator_state:
				var rs_e: Dictionary = building_sys.editor_refabricator_state[pos]
				refabricator_state_save[_vec2i_to_str(pos)] = {
					"phase": "idle",
					"in_unit_id": "",
					"out_unit_id": "",
					"timer": 0.0,
					"selected_t2": String(rs_e.get("selected_t2", &"")),
				}
		if constructor_state_save.is_empty() and "editor_constructor_state" in building_sys:
			for pos in building_sys.editor_constructor_state:
				var cs_e: Dictionary = building_sys.editor_constructor_state[pos]
				constructor_state_save[_vec2i_to_str(pos)] = {
					"selected_block": str(cs_e.get("selected_block", &"")),
					"collected": {},
					"phase": "idle",
					"timer": 0.0,
				}
	if logistics:
		if "deconstructor_state" in logistics:
			for pos in logistics.deconstructor_state:
				var state = logistics.deconstructor_state[pos]
				var pending_save := {}
				for k in state.get("pending_items", {}):
					pending_save[str(k)] = state["pending_items"][k]
				deconstructor_state_save[_vec2i_to_str(pos)] = {
					"payload": _ser_payload(state.get("payload")),
					"phase": str(state.get("phase", "idle")),
					"timer": state.get("timer", 0.0),
					"pending_items": pending_save,
				}
		if "loader_state" in logistics:
			for pos in logistics.loader_state:
				var state = logistics.loader_state[pos]
				loader_state_save[_vec2i_to_str(pos)] = {
					"payload": _ser_payload(state.get("payload")),
					"phase": str(state.get("phase", "idle")),
				}
		if "unloader_state" in logistics:
			for pos in logistics.unloader_state:
				var state = logistics.unloader_state[pos]
				unloader_state_save[_vec2i_to_str(pos)] = {
					"payload": _ser_payload(state.get("payload")),
					"phase": str(state.get("phase", "idle")),
				}

	# --- Save mass driver state (per-anchor) + in-flight projectiles ---
	# Without this, a launcher mid-cycle resets to idle on load: held
	# payloads vanish, the head snaps back to 0°, and projectiles in
	# the air disappear with whatever they were carrying.
	var mass_driver_state_save := {}
	var mass_driver_projectiles_save: Array = []
	if logistics:
		if "mass_driver_state" in logistics:
			for pos in logistics.mass_driver_state:
				var ms: Dictionary = logistics.mass_driver_state[pos]
				mass_driver_state_save[_vec2i_to_str(pos)] = {
					"payload": _ser_payload(ms.get("payload")),
					"head_angle": float(ms.get("head_angle", 0.0)),
					"target_angle": float(ms.get("target_angle", 0.0)),
					"recoil": float(ms.get("recoil", 0.0)),
					"phase": str(ms.get("phase", "idle")),
					"cooldown": float(ms.get("cooldown", 0.0)),
					"input_pos": _vec2i_to_str(ms.get("input_pos", Vector2i.ZERO)),
				}
		if "mass_driver_projectiles" in logistics:
			for proj in logistics.mass_driver_projectiles:
				var pd_raw: Dictionary = proj.get("payload_data", {})
				mass_driver_projectiles_save.append({
					"from_x": float(proj.get("from", Vector2.ZERO).x),
					"from_y": float(proj.get("from", Vector2.ZERO).y),
					"to_x": float(proj.get("to", Vector2.ZERO).x),
					"to_y": float(proj.get("to", Vector2.ZERO).y),
					"payload_data": _ser_payload(pd_raw),
					"progress": float(proj.get("progress", 0.0)),
					"source_origin": _vec2i_to_str(proj.get("source_origin", Vector2i.ZERO)),
					"target_origin": _vec2i_to_str(proj.get("target_origin", Vector2i.ZERO)),
				})

	# --- Pipe contents (fluid amounts per cell) ---
	var pipe_contents_save := {}
	if logistics and "pipe_contents" in logistics:
		for pos in logistics.pipe_contents:
			var pipe: Dictionary = logistics.pipe_contents[pos]
			pipe_contents_save[_vec2i_to_str(pos)] = {
				"fluid_id": str(pipe.get("fluid_id", &"")),
				"amount": float(pipe.get("amount", 0.0)),
			}

	# --- Pipe junction state (per-axis fluid compartments) ---
	# Two independent fluid channels per junction so the cross-without-
	# mixing behaviour survives a save/reload.
	var pipe_junction_state_save := {}
	if logistics and "pipe_junction_state" in logistics:
		for pos in logistics.pipe_junction_state:
			var s: Dictionary = logistics.pipe_junction_state[pos]
			pipe_junction_state_save[_vec2i_to_str(pos)] = {
				"v_fluid": str(s.get("v_fluid", &"")),
				"v_amount": float(s.get("v_amount", 0.0)),
				"h_fluid": str(s.get("h_fluid", &"")),
				"h_amount": float(s.get("h_amount", 0.0)),
			}

	# --- Junction items (items routing through 2-axis junctions) ---
	var junction_items_save := {}
	if logistics and "junction_items" in logistics:
		for pos in logistics.junction_items:
			var entry: Dictionary = logistics.junction_items[pos]
			junction_items_save[_vec2i_to_str(pos)] = {
				"item_id": str(entry.get("item_id", &"")),
				"progress": float(entry.get("progress", 0.0)),
				"entry_dir": int(entry.get("entry_dir", -1)),
			}

	# --- Belt unloader timer / round-robin pointer ---
	var belt_unloader_state_save := {}
	if logistics and "belt_unloader_state" in logistics:
		for pos in logistics.belt_unloader_state:
			var st: Dictionary = logistics.belt_unloader_state[pos]
			belt_unloader_state_save[_vec2i_to_str(pos)] = {
				"timer": float(st.get("timer", 0.0)),
				"round_robin": int(st.get("round_robin", 0)),
			}

	# Save crane links (input/output diamonds + filters per crane).
	var crane_links_save := {}
	if building_sys and "crane_links" in building_sys:
		for pos in building_sys.crane_links:
			var ce: Dictionary = building_sys.crane_links[pos]
			var serialized := {"inputs": [], "outputs": []}
			for arr_key in ["inputs", "outputs"]:
				for spec in ce.get(arr_key, []):
					var filter_strs: Array = []
					for fid in spec.get("filter", []):
						filter_strs.append(str(fid))
					serialized[arr_key].append({
						"kind": spec.get("kind", "ground"),
						"pos": _vec2i_to_str(spec.get("pos", Vector2i.ZERO)),
						"filter": filter_strs,
					})
			crane_links_save[_vec2i_to_str(pos)] = serialized

	# Save crane states from BuildingSystem
	var crane_states_save := {}
	if building_sys and "crane_states" in building_sys:
		for pos in building_sys.crane_states:
			var cs = building_sys.crane_states[pos]
			crane_states_save[_vec2i_to_str(pos)] = {
				"arm_angle": cs.get("arm_angle", 0.0),
				"arm_extension": cs.get("arm_extension", 20.0),
				"grabber_open": cs.get("grabber_open", true),
				"held_payload": _ser_payload(cs.get("held_payload")),
			}

	# --- Battery charge (power network stored energy) ---
	var power_sys_s = get_node_or_null("/root/Main/PowerSystem")
	var battery_stored_save := {}
	var block_internal_battery_save := {}
	if power_sys_s:
		if "_battery_stored" in power_sys_s:
			battery_stored_save = _ser_pos_map(power_sys_s._battery_stored)
		if "_block_internal_battery" in power_sys_s:
			block_internal_battery_save = _ser_pos_map(power_sys_s._block_internal_battery)

	# --- Shield projector HP / cooldown ---
	var shield_sys_s = get_node_or_null("/root/Main/ShieldSystem")
	var shield_states_save := {}
	if shield_sys_s and "states" in shield_sys_s:
		for a in shield_sys_s.states:
			var st = shield_sys_s.states[a]
			shield_states_save[_vec2i_to_str(a)] = {
				"current_health": float(st.get("current_health", 0.0)),
				"is_broken": bool(st.get("is_broken", false)),
				"cooldown_remaining": float(st.get("cooldown_remaining", 0.0)),
			}

	# --- Building fires ---
	var fire_sys_s = get_node_or_null("/root/Main/FireSystem")
	var building_fires_save := {}
	if fire_sys_s and "building_fires" in fire_sys_s:
		for a in fire_sys_s.building_fires:
			var f = fire_sys_s.building_fires[a]
			var contact_save := {}
			for ck in f.get("contact", {}):
				if ck is Vector2i:
					contact_save[_vec2i_to_str(ck)] = float(f["contact"][ck])
			building_fires_save[_vec2i_to_str(a)] = {
				"normal_burn": float(f.get("normal_burn", 0.0)),
				"dmg_acc": float(f.get("dmg_acc", 0.0)),
				"emit_acc": float(f.get("emit_acc", 0.0)),
				"gone": bool(f.get("gone", false)),
				"gone_timer": float(f.get("gone_timer", 0.0)),
				"contact": contact_save,
			}

	# --- Drone carried inventory + heal/shoot mode ---
	var drone_s = get_node_or_null("/root/Main/PlayerDrone")
	var drone_inventory_save := {}
	var drone_heal_mode_save := false
	if drone_s:
		if "mined_inventory" in drone_s:
			for ik in drone_s.mined_inventory:
				drone_inventory_save[str(ik)] = int(drone_s.mined_inventory[ik])
		if "heal_mode" in drone_s:
			drone_heal_mode_save = bool(drone_s.heal_mode)

	# --- Unit upgrader / refit bay in-progress state (held units!) ---
	var upgrader_state_save := {}
	var refit_state_save := {}
	if logistics:
		if "upgrader_state" in logistics:
			for pos in logistics.upgrader_state:
				var us = logistics.upgrader_state[pos]
				var uq := []
				for qi in us.get("queue", []):
					uq.append(str(qi))
				upgrader_state_save[_vec2i_to_str(pos)] = {
					"unit": _ser_payload(us.get("unit")),
					"queue": uq,
					"applying": str(us.get("applying", &"")),
					"timer": float(us.get("timer", 0.0)),
					"applied_session": int(us.get("applied_session", 0)),
				}
		if "refit_state" in logistics:
			for pos in logistics.refit_state:
				var rfs = logistics.refit_state[pos]
				var rp := []
				for pi in rfs.get("pending", []):
					rp.append(str(pi))
				refit_state_save[_vec2i_to_str(pos)] = {
					"unit": _ser_payload(rfs.get("unit")),
					"pending": rp,
					"timer": float(rfs.get("timer", 0.0)),
					"ejecting": bool(rfs.get("ejecting", false)),
				}

	# --- Round-robin indices + extractor timers / efficiency ---
	var router_idx_save := {}
	var sorter_idx_save := {}
	var payload_router_idx_save := {}
	var bridge_rr_save := {}
	var drill_timers_save := {}
	var pump_timers_save := {}
	var extractor_eff_save := {}
	if logistics:
		if "router_output_index" in logistics:
			router_idx_save = _ser_pos_map(logistics.router_output_index)
		if "sorter_side_index" in logistics:
			sorter_idx_save = _ser_pos_map(logistics.sorter_side_index)
		if "payload_router_idx" in logistics:
			payload_router_idx_save = _ser_pos_map(logistics.payload_router_idx)
		if "bridge_output_rr" in logistics:
			bridge_rr_save = _ser_pos_map(logistics.bridge_output_rr)
		if "drill_timers" in logistics:
			drill_timers_save = _ser_pos_map(logistics.drill_timers)
		if "pump_timers" in logistics:
			pump_timers_save = _ser_pos_map(logistics.pump_timers)
		if "extractor_efficiency" in logistics:
			extractor_eff_save = _ser_pos_map(logistics.extractor_efficiency)

	# --- Arc turret charge wind-up ---
	var combat_s = get_node_or_null("/root/Main/CombatSystem")
	var arc_charge_save := {}
	if combat_s and "arc_charge" in combat_s:
		arc_charge_save = _ser_pos_map(combat_s.arc_charge)

	var landing_pad_filters_serialized := _serialize_landing_pad_filters()
	# Push the freshly-serialised filter map into the cross-sector
	# snapshot so other sectors' launchpads can read it without loading
	# this map. Keyed by the sector being saved.
	_refresh_landing_pad_snapshot(StringName(sector_name), landing_pad_filters_serialized)
	var data := {
		"version": 3,
		"type": "sector",
		"sector_name": sector_name,
		"grid_width": main.GRID_WIDTH,
		"grid_height": main.GRID_HEIGHT,
		"floor_tiles": _serialize_tiles(terrain.floor_tiles),
		"wall_tiles": _serialize_tiles(terrain.wall_tiles),
		"ore_tiles": _serialize_tiles(terrain.ore_tiles),
		"core_position": _vec2i_to_str(main.core_position),
		"buildings": _serialize_buildings(main.placed_buildings),
		"building_rotation": _serialize_rotation(main.building_rotation),
		"building_factions": _serialize_factions(main.building_factions),
		"building_health": _serialize_health(main.building_health),
		"building_home_core": _serialize_home_core(main.building_home_core if "building_home_core" in main else {}),
		"linked_pairs": _serialize_links(links),
		"sorter_filters": _serialize_sorter_filters(),
		"factory_recipe_state": _serialize_factory_recipe_state(),
		"landing_pad_filters": landing_pad_filters_serialized,
		"launchpad_state": _serialize_launchpad_state(),
		"duct_bridge_filters": _serialize_duct_bridge_filters(),
		"script_steps": _serialize_script_steps(),
		"hints": _serialize_hints(),
		"resources": res_save,
		"drone_position": drone_pos,
		"build_progress": build_progress_save,
		"build_order": build_order_save,
		"work_order": work_order_save,
		# Destroyed FEROX blocks awaiting a shardling rebuild — persisted so
		# the enemy base resumes self-repairing after a close/reopen.
		"ferox_rebuild_queue": _serialize_ferox_rebuild_queue(
			main.ferox_rebuild_queue if "ferox_rebuild_queue" in main else []),
		"building_resources_consumed": resources_consumed_save,
		"building_resources_refunded": resources_refunded_save,
		"player_units": units_save,
		"enemy_units": enemies_save,
		"block_storage": block_storage_save,
		"conveyor_items": conveyor_items_save,
		"factory_buffers": factory_buffers_save,
		"payload_items": payload_items_save,
		"constructor_state": constructor_state_save,
		"refabricator_state": refabricator_state_save,
		"deconstructor_state": deconstructor_state_save,
		"loader_state": loader_state_save,
		"unloader_state": unloader_state_save,
		"crane_states": crane_states_save,
		"crane_links": crane_links_save,
		"archive_holdings": _serialize_archive_holdings(),
		"archive_decoder_state": _serialize_archive_decoder_state(),
		"mass_driver_state": mass_driver_state_save,
		"mass_driver_projectiles": mass_driver_projectiles_save,
		"pipe_contents": pipe_contents_save,
		"pipe_junction_state": pipe_junction_state_save,
		"junction_items": junction_items_save,
		"belt_unloader_state": belt_unloader_state_save,
		"battery_stored": battery_stored_save,
		"block_internal_battery": block_internal_battery_save,
		"shield_states": shield_states_save,
		"building_fires": building_fires_save,
		"drone_inventory": drone_inventory_save,
		"drone_heal_mode": drone_heal_mode_save,
		"upgrader_state": upgrader_state_save,
		"refit_state": refit_state_save,
		"router_output_index": router_idx_save,
		"sorter_side_index": sorter_idx_save,
		"payload_router_idx": payload_router_idx_save,
		"bridge_output_rr": bridge_rr_save,
		"drill_timers": drill_timers_save,
		"pump_timers": pump_timers_save,
		"extractor_efficiency": extractor_eff_save,
		"arc_charge": arc_charge_save,
		# Session stats — persisted per-sector so the loss-screen totals
		# survive scene reloads (e.g. planet menu → back). The map
		# editor doesn't define these fields, so fall back to 0 via
		# `get()` instead of crashing on a missing property.
		"stats_blocks_placed": main.get("stats_blocks_placed") if main.get("stats_blocks_placed") != null else 0,
		"stats_blocks_removed": main.get("stats_blocks_removed") if main.get("stats_blocks_removed") != null else 0,
		"stats_enemy_blocks_destroyed": main.get("stats_enemy_blocks_destroyed") if main.get("stats_enemy_blocks_destroyed") != null else 0,
		"stats_units_produced": main.get("stats_units_produced") if main.get("stats_units_produced") != null else 0,
		"stats_units_destroyed": main.get("stats_units_destroyed") if main.get("stats_units_destroyed") != null else 0,
		"stats_enemy_units_destroyed": main.get("stats_enemy_units_destroyed") if main.get("stats_enemy_units_destroyed") != null else 0,
		"stats_play_time": main.get("stats_play_time") if main.get("stats_play_time") != null else 0.0,
	}

	# Fog-of-war: persist the explored cell set so revealed memory
	# survives save/load. Visibility is recomputed from live LUMINA
	# sources on load, so only `_explored` needs serializing.
	var fog_node = get_node_or_null("/root/Main/FogSystem")
	if fog_node and fog_node.has_method("save_state"):
		data["fog"] = fog_node.save_state()
	# Author-time fog settings (toggle + darkness multiplier) live on
	# `main` regardless of which scene wrote them — the editor sets
	# them via Map Settings, the playtest scene reads them through
	# FogSystem. Default to enabled / 1.0 when absent so older saves
	# behave like before.
	if "fog_enabled" in main:
		data["fog_enabled"] = bool(main.fog_enabled)
	if "fog_darkness_mult" in main:
		data["fog_darkness_mult"] = float(main.fog_darkness_mult)

	# Save script runtime state if sector script exists
	var sector_script = get_node_or_null("/root/Main/SectorScript")
	if sector_script and sector_script.has_method("get_runtime_state"):
		data["script_runtime"] = sector_script.get_runtime_state()
	if sector_script and sector_script.has_method("get_hints_runtime_state"):
		data["hints_runtime"] = sector_script.get_hints_runtime_state()

	# Authored enemy-wave bundle: global config + spawn points + either
	# manual waves or an auto-generation template set. Pull from the
	# live WaveManager in-game, or from the editor's staging fields in
	# map-editor mode.
	var wm_script = preload("res://main/wave_manager.gd")
	var wm_live = get_node_or_null("/root/Main/WaveManager")
	var cfg_src: Dictionary = {}
	var spawns_src: Array = []
	var waves_src: Array = []
	if wm_live and wm_live.get("config") != null:
		cfg_src = wm_live.config
		spawns_src = wm_live.spawn_points
		waves_src = wm_live.waves
	elif main.get("editor_wave_config") != null:
		cfg_src = main.editor_wave_config
		spawns_src = main.editor_wave_spawns
		waves_src = main.editor_waves
	if not cfg_src.is_empty() or not spawns_src.is_empty() or not waves_src.is_empty():
		data["waves_bundle"] = wm_script.serialize_all(cfg_src, spawns_src, waves_src)
	# Persist the WaveManager runtime (`_running`, `_idx`, `_timer`,
	# the baked `_expanded_waves`) so script-mode sectors keep ticking
	# their wave timer across save/load — without this, returning to a
	# sector that was mid-wave came up cold and the HUD wave panel
	# never re-armed.
	if wm_live and wm_live.has_method("serialize_runtime"):
		data["waves_runtime"] = wm_live.serialize_runtime()

	# Compute offline defense simulation (time before sector falls)
	var sim_result = SectorDefenseSim.calculate_time_to_fall(main)
	data["defense_sim"] = {
		"time_to_fall": sim_result.time_to_fall if sim_result.time_to_fall != INF else -1.0,
		"is_stable": sim_result.is_stable,
		"summary": sim_result.summary,
		"timestamp": Time.get_unix_time_from_system(),
	}

	# Capture production rate so the sector keeps earning items while the
	# player is on the planet menu / in another sector / the game is closed.
	capture_production_snapshot(StringName(sector_name), main)

	var dir: String = SAVE_DIR if as_template else SAVES_DIR
	return _write_json(dir + sector_name + ".sector.json", data)


# =========================
# LOAD: SECTOR FROM PATH
# =========================

## Loads a sector from an arbitrary file path. Loads terrain + pre-placed buildings
## with factions. Health is rebuilt from BlockData, building_origins from grid_size.
func load_sector_from_path(path: String) -> bool:
	var main = get_node_or_null("/root/Main")
	var terrain = get_node_or_null("/root/Main/TerrainSystem")
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	var unit_mgr = get_node_or_null("/root/Main/UnitManager")
	if main == null or terrain == null:
		push_warning("SaveManager: Can't find Main or TerrainSystem!")
		return false

	var data = _read_json(path)
	if data == null:
		return false

	# --- Clear everything ---
	terrain.floor_tiles.clear()
	terrain.wall_tiles.clear()
	terrain.ore_tiles.clear()
	terrain.tile_health.clear()
	terrain.multi_tile_origins.clear()
	main.placed_buildings.clear()
	main.building_health.clear()
	main.building_rotation.clear()
	main.building_origins.clear()
	main.building_factions.clear()
	var power_sys = get_node_or_null("/root/Main/PowerSystem")
	if main.get("linked_pairs") != null:
		main.linked_pairs.clear()
	if power_sys and power_sys.get("linked_pairs") != null:
		power_sys.linked_pairs.clear()

	# --- Restore map size ---
	if data.has("grid_width"):
		main.GRID_WIDTH = int(data["grid_width"])
	if data.has("grid_height"):
		main.GRID_HEIGHT = int(data["grid_height"])

	# --- Load terrain ---
	_deserialize_layer(terrain.floor_tiles, data.get("floor_tiles", {}))
	_deserialize_layer(terrain.wall_tiles, data.get("wall_tiles", {}))
	_deserialize_layer(terrain.ore_tiles, data.get("ore_tiles", {}))
	_rebuild_multi_tile_origins(terrain)

	if data.has("core_position"):
		main.core_position = _str_to_vec2i(data["core_position"])

	# --- Load buildings ---
	_deserialize_buildings(main, data.get("buildings", {}))
	_deserialize_building_rotation(main, data.get("building_rotation", {}))
	_deserialize_building_factions(main, data.get("building_factions", {}))
	_deserialize_home_core(main, data.get("building_home_core", {}))

	# --- Load links ---
	var links_data = data.get("linked_pairs", [])
	if links_data.size() > 0:
		if main.get("linked_pairs") != null:
			_deserialize_links(main, links_data)
		elif power_sys and power_sys.get("linked_pairs") != null:
			_deserialize_links_to(power_sys.linked_pairs, links_data)
			power_sys._networks_dirty = true

	# --- Load sorter filters ---
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	var building_sys_early = get_node_or_null("/root/Main/BuildingSystem")
	var sf_data = data.get("sorter_filters", {})
	if logistics:
		logistics.sorter_filters.clear()
		for key in sf_data:
			logistics.sorter_filters[_str_to_vec2i(key)] = StringName(sf_data[key])
	elif building_sys_early and "editor_sorter_filters" in building_sys_early:
		building_sys_early.editor_sorter_filters.clear()
		for key in sf_data:
			building_sys_early.editor_sorter_filters[_str_to_vec2i(key)] = StringName(sf_data[key])

	# --- Load recipe-select factory selections ---
	# Recipe-select factories (Rod Shapper / Compound Mixer / etc.) stay idle
	# until a recipe is picked, so this must round-trip or they reset to idle
	# on load.
	var frs_data = data.get("factory_recipe_state", {})
	if logistics and "factory_recipe_state" in logistics:
		logistics.factory_recipe_state.clear()
		for key in frs_data:
			logistics.factory_recipe_state[_str_to_vec2i(key)] = StringName(frs_data[key])

	# --- Load Landing Pad filters ---
	_deserialize_landing_pad_filters(data.get("landing_pad_filters", {}))
	# --- Load Launchpad selection / cooldown state ---
	_deserialize_launchpad_state(data.get("launchpad_state", {}))

	# --- Load duct bridge output filters ---
	var dbf_data = data.get("duct_bridge_filters", {})
	if logistics and "duct_bridge_filters" in logistics:
		logistics.duct_bridge_filters.clear()
		for key in dbf_data:
			var filt: StringName = StringName(dbf_data[key])
			if filt != &"":
				logistics.duct_bridge_filters[_str_to_vec2i(key)] = filt
	# Editor-mode constructor/refab state. In-game these are restored
	# later in this function from the same data dict into the live
	# LogisticsSystem; for the editor we mirror them into BuildingSystem
	# so menus show the right selection on re-open.
	if logistics == null and building_sys_early:
		if "editor_constructor_state" in building_sys_early:
			building_sys_early.editor_constructor_state.clear()
			var cs_data = data.get("constructor_state", {})
			for key in cs_data:
				var raw = cs_data[key]
				var sel: StringName = StringName(raw.get("selected_block", "")) if raw is Dictionary else &""
				building_sys_early.editor_constructor_state[_str_to_vec2i(key)] = {"selected_block": sel}
		if "editor_refabricator_state" in building_sys_early:
			building_sys_early.editor_refabricator_state.clear()
			var rs_data = data.get("refabricator_state", {})
			for key in rs_data:
				var raw = rs_data[key]
				var sel2: StringName = StringName(raw.get("selected_t2", "")) if raw is Dictionary else &""
				building_sys_early.editor_refabricator_state[_str_to_vec2i(key)] = {"selected_t2": sel2}

	# --- Load hints ---
	var hints_data = data.get("hints", [])
	print("SaveManager: loading %d hint(s) from %s" % [hints_data.size() if hints_data is Array else -1, path])
	if hints_data is Array:
		var se_h = main.get("script_editor")
		if se_h and se_h.has_method("set_hints_data"):
			se_h.set_hints_data(hints_data)
		var sector_script_h = get_node_or_null("/root/Main/SectorScript")
		if sector_script_h and sector_script_h.has_method("load_hints"):
			sector_script_h.load_hints(hints_data)
			print("SaveManager: SectorScript now has %d hints" % sector_script_h._hints.size())
			var is_user_save_h: bool = path.begins_with(SAVE_DIR) or path.begins_with("user://")
			if is_user_save_h and data.has("hints_runtime") and data["hints_runtime"] is Dictionary \
					and sector_script_h.has_method("load_hints_runtime_state"):
				sector_script_h.call_deferred("load_hints_runtime_state", data["hints_runtime"])

	# --- Load script steps ---
	var script_steps_data = data.get("script_steps", [])
	if script_steps_data.size() > 0:
		# In the editor: load into script_editor
		_deserialize_script_steps(main, script_steps_data)
		# In gameplay: load into SectorScript
		var sector_script = get_node_or_null("/root/Main/SectorScript")
		if sector_script and sector_script.has_method("load_script_steps"):
			sector_script.load_script_steps(script_steps_data)
			# Only restore runtime state when loading a USER autosave
			# (under user://maps/). Bundled map_paths (res://…) can ship
			# with a `script_runtime` block baked in from whatever state
			# the map editor was in at save-time — restoring that on a
			# fresh launch would make the script think it had already
			# run, so an abandoned-and-re-launched sector never re-arms
			# its steps. Treat bundled loads as always-fresh.
			var is_user_autosave: bool = path.begins_with(SAVE_DIR) \
				or path.begins_with("user://")
			if is_user_autosave \
					and data.has("script_runtime") \
					and data["script_runtime"] is Dictionary:
				sector_script.call_deferred("load_runtime_state", data["script_runtime"])
			else:
				sector_script.call_deferred("start_script")

	# --- Load authored wave bundle into WaveManager (gameplay) or onto
	# the editor's staging fields (map editor). Fresh/empty bundle
	# clears any inherited wave data.
	var wm_script_l = preload("res://main/wave_manager.gd")
	var bundle_raw = data.get("waves_bundle", {})
	var bundle: Dictionary = wm_script_l.deserialize_all(bundle_raw)
	var wave_mgr_l = get_node_or_null("/root/Main/WaveManager")
	if wave_mgr_l:
		wave_mgr_l.config = bundle.get("config", {})
		wave_mgr_l.spawn_points = bundle.get("spawn_points", [])
		wave_mgr_l.waves = bundle.get("waves", [])
		# Only auto-start when the authored config says "on landing";
		# script-triggered runs wait for a sector-script start_waves
		# action. `start()` itself also honors the start_mode flag so
		# calling it is always safe — included for backwards compat
		# with the previous call site.
		if String(wave_mgr_l.config.get("start_mode", "landing")) == "landing":
			if wave_mgr_l.has_method("start"):
				wave_mgr_l.call_deferred("start")
		# Restore the live WaveManager runtime (running flag, current
		# wave index, countdown, baked-out wave list) when loading from
		# a USER autosave. Bundled res:// sectors ship with config but
		# never with runtime state, so this only fires on user://maps/
		# loads — same gate the script_runtime / hints_runtime paths use.
		var is_user_save_w: bool = path.begins_with(SAVE_DIR) or path.begins_with("user://")
		if is_user_save_w and data.has("waves_runtime") and data["waves_runtime"] is Dictionary \
				and wave_mgr_l.has_method("load_runtime"):
			wave_mgr_l.call_deferred("load_runtime", data["waves_runtime"])
	elif main.get("editor_wave_config") != null:
		main.editor_wave_config = bundle.get("config", {})
		main.editor_wave_spawns = bundle.get("spawn_points", [])
		main.editor_waves = bundle.get("waves", [])

	# --- Rebuild building_origins from grid_size FIRST so health restore
	# can normalise per-anchor (one HP entry per building, not per tile).
	_rebuild_building_origins(main)

	# --- Restore building health (use saved values if present, else max_health) ---
	if data.has("building_health") and data["building_health"] is Dictionary:
		_deserialize_building_health(main, data["building_health"])
	else:
		var seen_anchors: Dictionary = {}
		for grid_pos in main.placed_buildings:
			var anchor: Vector2i = main.building_origins.get(grid_pos, grid_pos)
			if seen_anchors.has(anchor):
				continue
			seen_anchors[anchor] = true
			var block_data = Registry.get_block(main.placed_buildings[anchor])
			if block_data:
				main.building_health[anchor] = block_data.max_health

	# --- Restore resources (if saved, e.g. from autosave) ---
	# Bundled res:// sectors can ship with a `resources` block baked in
	# from playtest/authoring; applying it on a fresh landing would gift
	# the player a stockpile they didn't earn. Only user autosaves under
	# user://maps/ restore the saved stockpile — bundled loads start clean.
	var is_user_save_res: bool = path.begins_with(SAVE_DIR) or path.begins_with("user://")
	if is_user_save_res and data.has("resources") and data["resources"] is Dictionary:
		for item_id in data["resources"]:
			main.resources[StringName(item_id)] = int(data["resources"][item_id])
		# Sync event-only material unlocks (mat_steel, mat_iron, …) so a
		# loaded save with a stockpile retroactively unlocks tech that
		# depends on those materials. Without this, the original
		# `item_produced` signal fired before load and the dependent
		# nodes (Unit Refabricator, etc.) stay locked on a dep the
		# player visibly satisfies.
		TechTree.sync_event_unlocks_from_resources(main.resources)

	# --- Restore session stats so the loss screen survives scene reloads ---
	# Map editor's `main` is map_editor.gd, which doesn't define any of
	# the `stats_*` fields — guard with `main.get(field) != null` so a
	# load through the editor doesn't crash on the assignment.
	if is_user_save_res:
		if data.has("stats_blocks_placed") and main.get("stats_blocks_placed") != null:
			main.stats_blocks_placed = int(data["stats_blocks_placed"])
		if data.has("stats_blocks_removed") and main.get("stats_blocks_removed") != null:
			main.stats_blocks_removed = int(data["stats_blocks_removed"])
		if data.has("stats_enemy_blocks_destroyed") and main.get("stats_enemy_blocks_destroyed") != null:
			main.stats_enemy_blocks_destroyed = int(data["stats_enemy_blocks_destroyed"])
		if data.has("stats_units_produced") and main.get("stats_units_produced") != null:
			main.stats_units_produced = int(data["stats_units_produced"])
		if data.has("stats_units_destroyed") and main.get("stats_units_destroyed") != null:
			main.stats_units_destroyed = int(data["stats_units_destroyed"])
		if data.has("stats_enemy_units_destroyed") and main.get("stats_enemy_units_destroyed") != null:
			main.stats_enemy_units_destroyed = int(data["stats_enemy_units_destroyed"])
		if data.has("stats_play_time") and main.get("stats_play_time") != null:
			main.stats_play_time = float(data["stats_play_time"])

	# --- Restore drone position ---
	if data.has("drone_position") and data["drone_position"] != "":
		var drone = get_node_or_null("/root/Main/PlayerDrone")
		if drone:
			var parts = str(data["drone_position"]).split(",")
			if parts.size() >= 2:
				drone.position = Vector2(float(parts[0].strip_edges()), float(parts[1].strip_edges()))
				if "_drone_position_restored" in main:
					main._drone_position_restored = true

	# --- Restore build progress & order ---
	if "building_build_progress" in main:
		main.building_build_progress.clear()
		if data.has("build_progress") and data["build_progress"] is Dictionary:
			for key in data["build_progress"]:
				main.building_build_progress[_str_to_vec2i(key)] = float(data["build_progress"][key])
	if "build_order" in main:
		main.build_order.clear()
		if data.has("build_order") and data["build_order"] is Array:
			for entry in data["build_order"]:
				main.build_order.append(_str_to_vec2i(str(entry)))

	# --- Restore unified work queue (new format) ---
	if "work_order" in main:
		main.work_order.clear()
		if data.has("work_order") and data["work_order"] is Array:
			for entry in data["work_order"]:
				main.work_order.append(_str_to_vec2i(str(entry)))
		elif not main.build_order.is_empty():
			# Migrate old build_order into work_order
			for anchor in main.build_order:
				main.work_order.append(anchor)

	# --- Restore FEROX rebuild queue ---
	# Runs after buildings are deserialized so the stale-cell check (drop
	# entries whose crater was already re-occupied) sees the live grid.
	_deserialize_ferox_rebuild_queue(main, data.get("ferox_rebuild_queue", []))

	if "building_resources_consumed" in main:
		main.building_resources_consumed.clear()
		if data.has("building_resources_consumed") and data["building_resources_consumed"] is Dictionary:
			for key in data["building_resources_consumed"]:
				var inner := {}
				for rk in data["building_resources_consumed"][key]:
					inner[StringName(rk)] = int(data["building_resources_consumed"][key][rk])
				main.building_resources_consumed[_str_to_vec2i(key)] = inner
		else:
			# Old save: assume all resources were consumed (old system deducted up front)
			for anchor in main.building_build_progress:
				var block_id = main.placed_buildings.get(anchor, &"")
				var bdata = Registry.get_block(block_id)
				if bdata:
					var consumed := {}
					for item_id in bdata.build_cost:
						var rk: StringName = main._resolve_resource_key(str(item_id))
						consumed[rk] = int(bdata.build_cost[item_id])
					main.building_resources_consumed[anchor] = consumed
	if "building_resources_refunded" in main:
		main.building_resources_refunded.clear()
		if data.has("building_resources_refunded") and data["building_resources_refunded"] is Dictionary:
			for key in data["building_resources_refunded"]:
				var inner := {}
				for rk in data["building_resources_refunded"][key]:
					inner[StringName(rk)] = int(data["building_resources_refunded"][key][rk])
				main.building_resources_refunded[_str_to_vec2i(key)] = inner

	# --- Rebuild pathfinding ---
	# Both the main-thread astar AND the threaded path_worker need a
	# fresh solids list — the worker was started at unit_manager._ready
	# with whatever terrain existed at that moment (often empty, before
	# the sector load populated walls / floor tiles), so leaving it
	# stale causes async paths to walk right across walls into void.
	if unit_mgr:
		unit_mgr._setup_astar()
		unit_mgr._setup_path_worker()

	# --- Restore player units ---
	if unit_mgr and data.has("player_units") and data["player_units"] is Array:
		for unit_entry in data["player_units"]:
			var uid: StringName = StringName(unit_entry.get("unit_id", ""))
			var ux: float = float(unit_entry.get("x", 0))
			var uy: float = float(unit_entry.get("y", 0))
			var uhp: float = float(unit_entry.get("health", -1))
			if uid != &"":
				unit_mgr.spawn_player_unit(Vector2(ux, uy), uid)
				if not unit_mgr.player_units.is_empty():
					var spawned = unit_mgr.player_units[-1]
					if spawned and is_instance_valid(spawned):
						if uhp >= 0:
							spawned.health = uhp
						# Restore the full saved runtime state (pose, turret
						# rotations, commands) so units reload exactly as left.
						if spawned.has_method("apply_payload_state"):
							spawned.apply_payload_state(unit_entry)

	# --- Restore enemy (Ferox) units ---
	# Mirrors the player-unit restore. spawn_enemy appends to unit_mgr.enemies
	# and assigns a fresh path toward the base, so fabricator-made enemies
	# (which the wave system never respawns) survive a save/load.
	if unit_mgr and data.has("enemy_units") and data["enemy_units"] is Array:
		for enemy_entry in data["enemy_units"]:
			var eid: StringName = StringName(enemy_entry.get("unit_id", ""))
			var ex: float = float(enemy_entry.get("x", 0))
			var ey: float = float(enemy_entry.get("y", 0))
			var ehp: float = float(enemy_entry.get("health", -1))
			if eid != &"":
				unit_mgr.spawn_enemy(Vector2(ex, ey), eid)
				if not unit_mgr.enemies.is_empty():
					var e_spawned = unit_mgr.enemies[-1]
					if e_spawned and is_instance_valid(e_spawned):
						if ehp >= 0:
							e_spawned.health = ehp
						if e_spawned.has_method("apply_payload_state"):
							e_spawned.apply_payload_state(enemy_entry)

	# --- Restore logistics state (block storage, conveyor items, factory buffers) ---
	var load_logistics = get_node_or_null("/root/Main/LogisticsSystem")
	if load_logistics:
		if data.has("block_storage") and data["block_storage"] is Dictionary:
			load_logistics.block_storage.clear()
			for key in data["block_storage"]:
				var origin: Vector2i = _str_to_vec2i(key)
				var saved = data["block_storage"][key]
				var items_dict := {}
				for k in saved.get("items", {}):
					items_dict[StringName(k)] = int(saved["items"][k])
				var fluids_dict := {}
				for k in saved.get("fluids", {}):
					fluids_dict[StringName(k)] = float(saved["fluids"][k])
				load_logistics.block_storage[origin] = {"items": items_dict, "fluids": fluids_dict}
		if data.has("conveyor_items") and data["conveyor_items"] is Dictionary:
			load_logistics.conveyor_items.clear()
			for key in data["conveyor_items"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["conveyor_items"][key]
				load_logistics.conveyor_items[pos] = {
					"item_id": StringName(saved.get("item_id", "")),
					"progress": float(saved.get("progress", 0.0)),
					"entry_dir": int(saved.get("entry_dir", -1)),
				}
		if data.has("factory_buffers") and data["factory_buffers"] is Dictionary:
			load_logistics.factory_buffers.clear()
			for key in data["factory_buffers"]:
				var origin: Vector2i = _str_to_vec2i(key)
				var saved = data["factory_buffers"][key]
				var inputs_dict := {}
				for k in saved.get("inputs", {}):
					inputs_dict[StringName(k)] = int(saved["inputs"][k])
				var entry: Dictionary = {
					"inputs": inputs_dict,
					"phase": str(saved.get("phase", "collecting")),
					"timer": float(saved.get("timer", 0.0)),
					"pending_outputs": {},
				}
				if saved.has("eject_progress"):
					entry["eject_progress"] = float(saved["eject_progress"])
				if saved.has("held_payload") and saved["held_payload"] is Dictionary:
					entry["held_payload"] = _deser_payload(saved["held_payload"])
				load_logistics.factory_buffers[origin] = entry

		# --- Restore payload transport state ---
		if "payload_items" in load_logistics and data.has("payload_items") and data["payload_items"] is Dictionary:
			load_logistics.payload_items.clear()
			for key in data["payload_items"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["payload_items"][key]
				load_logistics.payload_items[pos] = {
					"payload_data": _deser_payload(saved.get("payload_data", {})),
					"progress": float(saved.get("progress", 0.0)),
					"entry_dir": int(saved.get("entry_dir", -1)),
				}
		if "refabricator_state" in load_logistics and data.has("refabricator_state") and data["refabricator_state"] is Dictionary:
			load_logistics.refabricator_state.clear()
			for key in data["refabricator_state"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["refabricator_state"][key]
				load_logistics.refabricator_state[pos] = {
					"phase": String(saved.get("phase", "idle")),
					"in_unit_id": StringName(saved.get("in_unit_id", "")),
					"out_unit_id": StringName(saved.get("out_unit_id", "")),
					"timer": float(saved.get("timer", 0.0)),
					"selected_t2": StringName(saved.get("selected_t2", "")),
				}
		if "constructor_state" in load_logistics and data.has("constructor_state") and data["constructor_state"] is Dictionary:
			load_logistics.constructor_state.clear()
			for key in data["constructor_state"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["constructor_state"][key]
				var collected := {}
				for k in saved.get("collected", {}):
					collected[StringName(k)] = int(saved["collected"][k])
				var paid := {}
				for k in saved.get("paid", {}):
					paid[StringName(k)] = int(saved["paid"][k])
				load_logistics.constructor_state[pos] = {
					"selected_block": StringName(saved.get("selected_block", "")),
					"collected": collected,
					"paid": paid,
					"phase": str(saved.get("phase", "idle")),
					"timer": float(saved.get("timer", 0.0)),
				}
		if "deconstructor_state" in load_logistics and data.has("deconstructor_state") and data["deconstructor_state"] is Dictionary:
			load_logistics.deconstructor_state.clear()
			for key in data["deconstructor_state"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["deconstructor_state"][key]
				var pending := {}
				for k in saved.get("pending_items", {}):
					pending[StringName(k)] = int(saved["pending_items"][k])
				load_logistics.deconstructor_state[pos] = {
					"payload": _deser_payload(saved.get("payload")),
					"phase": str(saved.get("phase", "idle")),
					"timer": float(saved.get("timer", 0.0)),
					"pending_items": pending,
				}
		if "loader_state" in load_logistics and data.has("loader_state") and data["loader_state"] is Dictionary:
			load_logistics.loader_state.clear()
			for key in data["loader_state"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["loader_state"][key]
				load_logistics.loader_state[pos] = {
					"payload": _deser_payload(saved.get("payload")),
					"phase": str(saved.get("phase", "idle")),
				}
		if "unloader_state" in load_logistics and data.has("unloader_state") and data["unloader_state"] is Dictionary:
			load_logistics.unloader_state.clear()
			for key in data["unloader_state"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["unloader_state"][key]
				load_logistics.unloader_state[pos] = {
					"payload": _deser_payload(saved.get("payload")),
					"phase": str(saved.get("phase", "idle")),
				}
		# --- Mass driver state ---
		if "mass_driver_state" in load_logistics and data.has("mass_driver_state") and data["mass_driver_state"] is Dictionary:
			load_logistics.mass_driver_state.clear()
			for key in data["mass_driver_state"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["mass_driver_state"][key]
				load_logistics.mass_driver_state[pos] = {
					"payload": _deser_payload(saved.get("payload")),
					"head_angle": float(saved.get("head_angle", 0.0)),
					"target_angle": float(saved.get("target_angle", 0.0)),
					"recoil": float(saved.get("recoil", 0.0)),
					"phase": str(saved.get("phase", "idle")),
					"cooldown": float(saved.get("cooldown", 0.0)),
					"input_pos": _str_to_vec2i(str(saved.get("input_pos", "0,0"))),
				}
		if "mass_driver_projectiles" in load_logistics and data.has("mass_driver_projectiles") and data["mass_driver_projectiles"] is Array:
			load_logistics.mass_driver_projectiles.clear()
			for proj_raw in data["mass_driver_projectiles"]:
				if not (proj_raw is Dictionary):
					continue
				var saved: Dictionary = proj_raw
				load_logistics.mass_driver_projectiles.append({
					"from": Vector2(float(saved.get("from_x", 0.0)), float(saved.get("from_y", 0.0))),
					"to": Vector2(float(saved.get("to_x", 0.0)), float(saved.get("to_y", 0.0))),
					"payload_data": _deser_payload(saved.get("payload_data", {})),
					"progress": float(saved.get("progress", 0.0)),
					"source_origin": _str_to_vec2i(str(saved.get("source_origin", "0,0"))),
					"target_origin": _str_to_vec2i(str(saved.get("target_origin", "0,0"))),
				})
		# --- Pipe fluid contents ---
		if "pipe_contents" in load_logistics and data.has("pipe_contents") and data["pipe_contents"] is Dictionary:
			load_logistics.pipe_contents.clear()
			for key in data["pipe_contents"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["pipe_contents"][key]
				load_logistics.pipe_contents[pos] = {
					"fluid_id": StringName(saved.get("fluid_id", "")),
					"amount": float(saved.get("amount", 0.0)),
				}
		# --- Pipe junction state ---
		if "pipe_junction_state" in load_logistics and data.has("pipe_junction_state") and data["pipe_junction_state"] is Dictionary:
			load_logistics.pipe_junction_state.clear()
			for key in data["pipe_junction_state"]:
				var jp: Vector2i = _str_to_vec2i(key)
				var s = data["pipe_junction_state"][key]
				load_logistics.pipe_junction_state[jp] = {
					"v_fluid": StringName(s.get("v_fluid", "")),
					"v_amount": float(s.get("v_amount", 0.0)),
					"h_fluid": StringName(s.get("h_fluid", "")),
					"h_amount": float(s.get("h_amount", 0.0)),
				}
		# --- Junction-routed items ---
		if "junction_items" in load_logistics and data.has("junction_items") and data["junction_items"] is Dictionary:
			load_logistics.junction_items.clear()
			for key in data["junction_items"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["junction_items"][key]
				load_logistics.junction_items[pos] = {
					"item_id": StringName(saved.get("item_id", "")),
					"progress": float(saved.get("progress", 0.0)),
					"entry_dir": int(saved.get("entry_dir", -1)),
				}
		# --- Belt unloader timer / round-robin pointer ---
		if "belt_unloader_state" in load_logistics and data.has("belt_unloader_state") and data["belt_unloader_state"] is Dictionary:
			load_logistics.belt_unloader_state.clear()
			for key in data["belt_unloader_state"]:
				var pos: Vector2i = _str_to_vec2i(key)
				var saved = data["belt_unloader_state"][key]
				load_logistics.belt_unloader_state[pos] = {
					"timer": float(saved.get("timer", 0.0)),
					"round_robin": int(saved.get("round_robin", 0)),
				}

		# --- Restore unit upgrader / refit bay in-progress state ---
		if "upgrader_state" in load_logistics and data.has("upgrader_state") and data["upgrader_state"] is Dictionary:
			load_logistics.upgrader_state.clear()
			for key in data["upgrader_state"]:
				var saved = data["upgrader_state"][key]
				var uq: Array = []
				for qi in saved.get("queue", []):
					uq.append(StringName(qi))
				load_logistics.upgrader_state[_str_to_vec2i(key)] = {
					"unit": _deser_payload(saved.get("unit")),
					"queue": uq,
					"applying": StringName(saved.get("applying", "")),
					"timer": float(saved.get("timer", 0.0)),
					"applied_session": int(saved.get("applied_session", 0)),
				}
		if "refit_state" in load_logistics and data.has("refit_state") and data["refit_state"] is Dictionary:
			load_logistics.refit_state.clear()
			for key in data["refit_state"]:
				var saved = data["refit_state"][key]
				var rp: Array = []
				for pi in saved.get("pending", []):
					rp.append(StringName(pi))
				load_logistics.refit_state[_str_to_vec2i(key)] = {
					"unit": _deser_payload(saved.get("unit")),
					"pending": rp,
					"timer": float(saved.get("timer", 0.0)),
					"ejecting": bool(saved.get("ejecting", false)),
				}

		# --- Restore round-robin indices + extractor timers / efficiency ---
		if "router_output_index" in load_logistics and data.has("router_output_index"):
			load_logistics.router_output_index = _deser_pos_int(data["router_output_index"])
		if "sorter_side_index" in load_logistics and data.has("sorter_side_index"):
			load_logistics.sorter_side_index = _deser_pos_int(data["sorter_side_index"])
		if "payload_router_idx" in load_logistics and data.has("payload_router_idx"):
			load_logistics.payload_router_idx = _deser_pos_int(data["payload_router_idx"])
		if "bridge_output_rr" in load_logistics and data.has("bridge_output_rr"):
			load_logistics.bridge_output_rr = _deser_pos_int(data["bridge_output_rr"])
		if "drill_timers" in load_logistics and data.has("drill_timers"):
			load_logistics.drill_timers = _deser_pos_float(data["drill_timers"])
		if "pump_timers" in load_logistics and data.has("pump_timers"):
			load_logistics.pump_timers = _deser_pos_float(data["pump_timers"])
		if "extractor_efficiency" in load_logistics and data.has("extractor_efficiency"):
			load_logistics.extractor_efficiency = _deser_pos_float(data["extractor_efficiency"])

	# --- Restore power battery charge ---
	var power_sys_l = get_node_or_null("/root/Main/PowerSystem")
	if power_sys_l:
		if "_battery_stored" in power_sys_l and data.has("battery_stored"):
			power_sys_l._battery_stored = _deser_pos_float(data["battery_stored"])
		if "_block_internal_battery" in power_sys_l and data.has("block_internal_battery"):
			power_sys_l._block_internal_battery = _deser_pos_float(data["block_internal_battery"])
		if "_networks_dirty" in power_sys_l:
			power_sys_l._networks_dirty = true

	# --- Restore shield projector HP / cooldown ---
	var shield_sys_l = get_node_or_null("/root/Main/ShieldSystem")
	if shield_sys_l and "states" in shield_sys_l and data.has("shield_states") and data["shield_states"] is Dictionary:
		for key in data["shield_states"]:
			var ss = data["shield_states"][key]
			shield_sys_l.states[_str_to_vec2i(key)] = {
				"current_health": float(ss.get("current_health", 0.0)),
				"is_broken": bool(ss.get("is_broken", false)),
				"cooldown_remaining": float(ss.get("cooldown_remaining", 0.0)),
				# Visual scale lerps back up from the saved logical state.
				"visual_scale": 0.0 if bool(ss.get("is_broken", false)) else 1.0,
				"target_scale": 0.0 if bool(ss.get("is_broken", false)) else 1.0,
			}

	# --- Restore building fires ---
	var fire_sys_l = get_node_or_null("/root/Main/FireSystem")
	if fire_sys_l and "building_fires" in fire_sys_l and data.has("building_fires") and data["building_fires"] is Dictionary:
		fire_sys_l.building_fires.clear()
		for key in data["building_fires"]:
			var fanchor: Vector2i = _str_to_vec2i(key)
			# Only restore fires on buildings that still exist (skip "gone"
			# fires whose block was already destroyed).
			if not main.placed_buildings.has(fanchor):
				continue
			var fs = data["building_fires"][key]
			var contact: Dictionary = {}
			for ck in fs.get("contact", {}):
				contact[_str_to_vec2i(str(ck))] = float(fs["contact"][ck])
			var fbd = Registry.get_block(main.placed_buildings[fanchor])
			fire_sys_l.building_fires[fanchor] = {
				"normal_burn": float(fs.get("normal_burn", 0.0)),
				"dmg_acc": float(fs.get("dmg_acc", 0.0)),
				"emit_acc": float(fs.get("emit_acc", 0.0)),
				"gone": false,
				"gone_timer": 0.0,
				"contact": contact,
				"last_top_left": main.grid_to_world(fanchor),
				"last_gsz": fbd.grid_size if fbd else Vector2i.ONE,
			}

	# --- Restore drone carried inventory + heal/shoot mode ---
	var drone_l = get_node_or_null("/root/Main/PlayerDrone")
	if drone_l:
		if "mined_inventory" in drone_l and data.has("drone_inventory") and data["drone_inventory"] is Dictionary:
			drone_l.mined_inventory.clear()
			for ik in data["drone_inventory"]:
				drone_l.mined_inventory[StringName(ik)] = int(data["drone_inventory"][ik])
		if "heal_mode" in drone_l and data.has("drone_heal_mode"):
			drone_l.heal_mode = bool(data["drone_heal_mode"])

	# --- Restore Arc turret charge wind-up ---
	var combat_l = get_node_or_null("/root/Main/CombatSystem")
	if combat_l and "arc_charge" in combat_l and data.has("arc_charge"):
		combat_l.arc_charge = _deser_pos_float(data["arc_charge"])

	# --- Restore fog-of-war explored set ---
	var fog_node = get_node_or_null("/root/Main/FogSystem")
	if fog_node and fog_node.has_method("load_state") and data.has("fog") and data["fog"] is Dictionary:
		fog_node.load_state(data["fog"])
	# Author-time fog settings — FogSystem reads these from `main`.
	if "fog_enabled" in main and data.has("fog_enabled"):
		main.fog_enabled = bool(data["fog_enabled"])
	if "fog_darkness_mult" in main and data.has("fog_darkness_mult"):
		main.fog_darkness_mult = float(data["fog_darkness_mult"])

	# --- Restore crane states ---
	if building_sys and "crane_states" in building_sys and data.has("crane_states") and data["crane_states"] is Dictionary:
		building_sys.crane_states.clear()
		for key in data["crane_states"]:
			var pos: Vector2i = _str_to_vec2i(key)
			var saved = data["crane_states"][key]
			building_sys.crane_states[pos] = {
				"arm_angle": float(saved.get("arm_angle", -PI / 2.0)),
				"arm_extension": float(saved.get("arm_extension", 20.0)),
				"grabber_open": bool(saved.get("grabber_open", true)),
				"held_payload": _deser_payload(saved.get("held_payload")),
				"target_pos": Vector2.ZERO,
			}

	# --- Restore crane links ---
	if building_sys and "crane_links" in building_sys and data.has("crane_links") and data["crane_links"] is Dictionary:
		building_sys.crane_links.clear()
		for key in data["crane_links"]:
			var pos: Vector2i = _str_to_vec2i(key)
			var saved = data["crane_links"][key]
			var entry := {"inputs": [], "outputs": []}
			for arr_key in ["inputs", "outputs"]:
				for s in saved.get(arr_key, []):
					var filter_arr: Array = []
					for fid in s.get("filter", []):
						filter_arr.append(StringName(fid))
					entry[arr_key].append({
						"kind": s.get("kind", "ground"),
						"pos": _str_to_vec2i(s.get("pos", "0,0")),
						"filter": filter_arr,
					})
			building_sys.crane_links[pos] = entry

	# --- Restore archive holdings ---
	if building_sys and "archive_holdings" in building_sys and data.has("archive_holdings") and data["archive_holdings"] is Dictionary:
		building_sys.archive_holdings.clear()
		for key in data["archive_holdings"]:
			building_sys.archive_holdings[_str_to_vec2i(key)] = StringName(data["archive_holdings"][key])

	# --- Restore archive decoder state ---
	# State now lives on the ArchiveDecoderSystem sibling node.
	var ad_sys_load = get_node_or_null("/root/Main/ArchiveDecoderSystem")
	if ad_sys_load and "states" in ad_sys_load and data.has("archive_decoder_state") and data["archive_decoder_state"] is Dictionary:
		ad_sys_load.states.clear()
		for key in data["archive_decoder_state"]:
			var saved_a = data["archive_decoder_state"][key]
			ad_sys_load.states[_str_to_vec2i(key)] = {
				"progress": float(saved_a.get("progress", 0.0)),
				"archive_id": StringName(saved_a.get("archive_id", "")),
				"scanner": Vector2i(-9999, -9999),
			}

	# --- Redraw ---
	# Bulk-loaded terrain bypassed the `place_tile` dirty hooks, so any
	# rebuild triggered between map-clear and now ran against an empty
	# floor_tiles set and latched _water_depth_dirty / _floor_edge_dirty
	# to false. Re-arm them so the next draw pass actually bakes the
	# gradient meshes against the real tile set.
	terrain._water_depth_dirty = true
	terrain._floor_edge_dirty = true
	# Also re-arm the floor-geometry mesh flag — it's a separate dirty bit
	# from the edge-fade pass, and a bulk load bypasses the place_tile hook
	# that normally sets it, so without this the floor tiles wouldn't render
	# until the first manual placement.
	if "_floor_geom_dirty" in terrain:
		terrain._floor_geom_dirty = true
	terrain.walls_changed.emit()
	terrain.queue_redraw()
	if building_sys:
		building_sys.queue_redraw()

	var total_tiles: int = terrain.floor_tiles.size() + terrain.wall_tiles.size() + terrain.ore_tiles.size()
	print("SaveManager: Sector loaded from '%s' (%d tiles, %d building cells, %d player units)" % [
		path, total_tiles, main.placed_buildings.size(),
		data.get("player_units", []).size() if data.has("player_units") else 0
	])
	return true


## Loads a sector by name. Prefers the player's autosave under
## `user://saves/` so an in-progress run resumes; falls back to the
## editor template under `user://maps/` if no autosave exists.
func load_sector(sector_name: String) -> bool:
	var save_path: String = SAVES_DIR + sector_name + ".sector.json"
	if FileAccess.file_exists(save_path):
		return load_sector_from_path(save_path)
	return load_sector_from_path(SAVE_DIR + sector_name + ".sector.json")


## Rebuilds multi_tile_origins for floor tiles (vents, geysers) after loading.
## Scans floor_tiles for any tile that TerrainSystem considers multi-tile (3x3),
## then populates multi_tile_origins so all 9 cells point back to the origin.
func _rebuild_multi_tile_origins(terrain: Node2D) -> void:
	terrain.multi_tile_origins.clear()
	var processed := {}
	# Cache _is_multi_tile(tile_id) per id so we stop re-entering Registry
	# for every floor cell (100x100 map × N floor types).
	var is_mt_cache := {}
	for grid_pos in terrain.floor_tiles:
		if processed.has(grid_pos):
			continue
		var tile_id: StringName = terrain.floor_tiles[grid_pos]
		var is_mt: bool
		if is_mt_cache.has(tile_id):
			is_mt = is_mt_cache[tile_id]
		else:
			is_mt = terrain._is_multi_tile(tile_id)
			is_mt_cache[tile_id] = is_mt
		if not is_mt:
			continue
		# This cell is the origin of a 3x3 multi-tile
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var cell: Vector2i = grid_pos + Vector2i(dx, dy)
				terrain.multi_tile_origins[cell] = grid_pos
				processed[cell] = true


## Rebuilds building_origins for all placed buildings by finding anchors.
## For 1x1 buildings, origin = self. For multi-tile, scans for the top-left cell.
func _rebuild_building_origins(main: Node2D) -> void:
	main.building_origins.clear()
	var processed := {}  # Track which cells we've already assigned origins

	for grid_pos in main.placed_buildings:
		if processed.has(grid_pos):
			continue

		var block_id = main.placed_buildings[grid_pos]
		var block_data = Registry.get_block(block_id)
		if block_data == null:
			main.building_origins[grid_pos] = grid_pos
			processed[grid_pos] = true
			continue

		if block_data.grid_size == Vector2i(1, 1):
			main.building_origins[grid_pos] = grid_pos
			processed[grid_pos] = true
			continue

		# Multi-tile: find origin by checking if grid_pos could be the anchor
		var origin := _find_anchor_for_cell(main, grid_pos, block_id, block_data)
		for x in range(block_data.grid_size.x):
			for y in range(block_data.grid_size.y):
				var cell = origin + Vector2i(x, y)
				main.building_origins[cell] = origin
				processed[cell] = true


## Finds the anchor (top-left cell) for a multi-tile building that includes grid_pos.
func _find_anchor_for_cell(main: Node2D, grid_pos: Vector2i, block_id: StringName, block_data: BlockData) -> Vector2i:
	for ox in range(block_data.grid_size.x):
		for oy in range(block_data.grid_size.y):
			var candidate = grid_pos - Vector2i(ox, oy)
			var valid = true
			for dx in range(block_data.grid_size.x):
				for dy in range(block_data.grid_size.y):
					if main.placed_buildings.get(candidate + Vector2i(dx, dy), &"") != block_id:
						valid = false
						break
				if not valid:
					break
			if valid:
				return candidate
	return grid_pos


# =========================
# SERIALIZATION HELPERS
# =========================

# Converts Vector2i dictionary keys to strings for JSON.
# JSON only supports string keys, so Vector2i(5,10) becomes "5,10".

func _vec2i_to_str(v: Vector2i) -> String:
	return "%d,%d" % [v.x, v.y]

func _str_to_vec2i(s: String) -> Vector2i:
	var parts = s.split(",")
	return Vector2i(int(parts[0]), int(parts[1]))


## Serialise a {Vector2i -> scalar} dict to {"x,y" -> scalar}. For the simple
## per-cell maps (round-robin indices, drill/pump timers, battery charge, …).
func _ser_pos_map(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d:
		if k is Vector2i:
			out[_vec2i_to_str(k)] = d[k]
	return out

func _deser_pos_float(src) -> Dictionary:
	var out := {}
	if src is Dictionary:
		for k in src:
			out[_str_to_vec2i(str(k))] = float(src[k])
	return out

func _deser_pos_int(src) -> Dictionary:
	var out := {}
	if src is Dictionary:
		for k in src:
			out[_str_to_vec2i(str(k))] = int(src[k])
	return out


## Serialise / restore a carried building-or-unit payload to a JSON-safe form.
## Payloads nest arbitrarily deep (a crane held as a payload carries its own
## crane_state — incl. a `target_pos` Vector2 — and its own held_payload, which
## may be yet another crane). Plain JSON.stringify turns Vector2/Vector2i VALUES
## into lossy strings ("(1.0, 2.0)"), so a carried crane reloads with a String
## where a Vector2 is expected and breaks. These walk the whole tree and tag
## vector values so they round-trip. Returns null for a null payload.
func _ser_payload(pd):
	if pd == null:
		return null
	return _payload_to_json(pd)

func _deser_payload(src):
	if src == null:
		return null
	return _payload_from_json(src)


## Recursively converts a payload tree into JSON-safe data, tagging vectors.
func _payload_to_json(v):
	match typeof(v):
		TYPE_DICTIONARY:
			var out := {}
			for k in v:
				out[str(k)] = _payload_to_json(v[k])
			return out
		TYPE_ARRAY:
			var arr := []
			for e in v:
				arr.append(_payload_to_json(e))
			return arr
		TYPE_VECTOR2I:
			return {"__v2i": [v.x, v.y]}
		TYPE_VECTOR2:
			return {"__v2": [v.x, v.y]}
		TYPE_STRING_NAME:
			return str(v)
		_:
			return v


## Inverse of `_payload_to_json` — rebuilds Vector2/Vector2i from their tags.
func _payload_from_json(v):
	match typeof(v):
		TYPE_DICTIONARY:
			if v.has("__v2i") and v["__v2i"] is Array and v["__v2i"].size() == 2:
				return Vector2i(int(v["__v2i"][0]), int(v["__v2i"][1]))
			if v.has("__v2") and v["__v2"] is Array and v["__v2"].size() == 2:
				return Vector2(float(v["__v2"][0]), float(v["__v2"][1]))
			var out := {}
			for k in v:
				out[k] = _payload_from_json(v[k])
			return out
		TYPE_ARRAY:
			var arr := []
			for e in v:
				arr.append(_payload_from_json(e))
			return arr
		_:
			return v



func _serialize_tiles(tiles: Dictionary) -> Dictionary:
	var result := {}
	for grid_pos in tiles:
		result[_vec2i_to_str(grid_pos)] = String(tiles[grid_pos])
	return result


func _serialize_buildings(buildings: Dictionary) -> Dictionary:
	var result := {}
	for grid_pos in buildings:
		result[_vec2i_to_str(grid_pos)] = String(buildings[grid_pos])
	return result


func _serialize_health(health_dict: Dictionary) -> Dictionary:
	var result := {}
	for grid_pos in health_dict:
		result[_vec2i_to_str(grid_pos)] = health_dict[grid_pos]
	return result










## Deserializes a single tile layer dictionary from save data.
func _deserialize_layer(layer_dict: Dictionary, data: Dictionary) -> void:
	for pos_str in data:
		layer_dict[_str_to_vec2i(pos_str)] = StringName(data[pos_str])






func _deserialize_buildings(main: Node2D, buildings_data: Dictionary) -> void:
	for pos_str in buildings_data:
		var grid_pos = _str_to_vec2i(pos_str)
		var block_id = StringName(buildings_data[pos_str])
		main.placed_buildings[grid_pos] = block_id


func _deserialize_building_health(main: Node2D, health_data: Dictionary) -> void:
	# Health is now per-building (anchor only). Modern saves only store
	# the anchor entry; legacy saves stored one per tile, but they were
	# all written together at placement so any divergence is small. We
	# load every entry as-is; anchors get their saved value, non-anchor
	# tile entries become harmless orphans (reads always look up the
	# anchor via building_origins).
	for pos_str in health_data:
		var grid_pos: Vector2i = _str_to_vec2i(pos_str)
		main.building_health[grid_pos] = float(health_data[pos_str])


func _serialize_rotation(rotation_dict: Dictionary) -> Dictionary:
	var result := {}
	for grid_pos in rotation_dict:
		result[_vec2i_to_str(grid_pos)] = rotation_dict[grid_pos]
	return result


func _deserialize_building_rotation(main: Node2D, rotation_data: Dictionary) -> void:
	for pos_str in rotation_data:
		var grid_pos = _str_to_vec2i(pos_str)
		main.building_rotation[grid_pos] = int(rotation_data[pos_str])


func _serialize_factions(factions: Dictionary) -> Dictionary:
	var result := {}
	for grid_pos in factions:
		result[_vec2i_to_str(grid_pos)] = factions[grid_pos]
	return result


func _deserialize_building_factions(main: Node2D, factions_data: Dictionary) -> void:
	for pos_str in factions_data:
		var grid_pos = _str_to_vec2i(pos_str)
		main.building_factions[grid_pos] = int(factions_data[pos_str])


## Home-core links: anchor "x,y" → "cx,cy". Loaded by callers (the
## sector load path) into `main.building_home_core` so a saved game
## remembers which core each block was bound to.
func _serialize_home_core(home_core: Dictionary) -> Dictionary:
	var result := {}
	for anchor in home_core:
		result[_vec2i_to_str(anchor)] = _vec2i_to_str(home_core[anchor])
	return result


func _deserialize_home_core(main: Node2D, data: Dictionary) -> void:
	if not "building_home_core" in main:
		return
	main.building_home_core.clear()
	for k in data:
		var anchor: Vector2i = _str_to_vec2i(k)
		var core: Vector2i = _str_to_vec2i(String(data[k]))
		main.building_home_core[anchor] = core


func _serialize_archive_holdings() -> Dictionary:
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	if building_sys == null or not "archive_holdings" in building_sys:
		return {}
	var result := {}
	for grid_pos in building_sys.archive_holdings:
		result[_vec2i_to_str(grid_pos)] = String(building_sys.archive_holdings[grid_pos])
	return result


func _serialize_archive_decoder_state() -> Dictionary:
	# State moved to the ArchiveDecoderSystem sibling node.
	var ad_sys = get_node_or_null("/root/Main/ArchiveDecoderSystem")
	if ad_sys == null or not "states" in ad_sys:
		return {}
	var result := {}
	for grid_pos in ad_sys.states:
		var s = ad_sys.states[grid_pos]
		result[_vec2i_to_str(grid_pos)] = {
			"progress": float(s.get("progress", 0.0)),
			"archive_id": String(s.get("archive_id", "")),
		}
	return result


## Per-output duct bridge filter (output anchor → allowed item id).
## Empty filters are dropped so the on-disk shape stays compact.
func _serialize_duct_bridge_filters() -> Dictionary:
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	var result := {}
	if logistics == null or not ("duct_bridge_filters" in logistics):
		return result
	for grid_pos in logistics.duct_bridge_filters:
		var filter_id = logistics.duct_bridge_filters[grid_pos]
		if filter_id != &"":
			result[_vec2i_to_str(grid_pos)] = String(filter_id)
	return result


## Updates the cross-sector landing-pad filter snapshot for `sector_id`
## with the serialized dict from the most recent save. Lets a Launchpad
## on another sector validate cargo routing before queuing a delivery.
## Per-sector serialization of every Launchpad's state — currently the
## selected destination sector + last-launch timestamp so the cooldown
## carries across saves. Cargo lives in the standard block_storage
## serialization, not here.
func _serialize_launchpad_state() -> Dictionary:
	var lp_sys = get_node_or_null("/root/Main/LaunchpadSystem")
	var out := {}
	if lp_sys == null or not ("launchpad_state" in lp_sys):
		return out
	for anchor in lp_sys.launchpad_state:
		var st: Dictionary = lp_sys.launchpad_state[anchor]
		out[_vec2i_to_str(anchor)] = {
			"selected_sector": String(st.get("selected_sector", &"")),
			"cooldown_remaining": float(st.get("cooldown_remaining", 0.0)),
			"build_timer": float(st.get("build_timer", 0.0)),
		}
	return out


func _deserialize_launchpad_state(raw: Dictionary) -> void:
	var lp_sys = get_node_or_null("/root/Main/LaunchpadSystem")
	if lp_sys == null or not ("launchpad_state" in lp_sys):
		return
	lp_sys.launchpad_state.clear()
	for k in raw:
		var entry: Dictionary = raw[k]
		lp_sys.launchpad_state[_str_to_vec2i(k)] = {
			"selected_sector": StringName(entry.get("selected_sector", "")),
			"cooldown_remaining": float(entry.get("cooldown_remaining", 0.0)),
			"build_timer": float(entry.get("build_timer", 0.0)),
			"pod_buffer": {},
			"pod_fluids": {},
		}


func _refresh_landing_pad_snapshot(sector_id: StringName, serialized: Dictionary) -> void:
	if serialized.is_empty():
		landing_pad_filters_by_sector.erase(sector_id)
	else:
		landing_pad_filters_by_sector[sector_id] = serialized.duplicate(true)


## Per-sector serialization of every Landing Pad's filter. Stored as a
## map of "x,y" → Array[String item id]. Cross-sector launch code reads
## the resulting dict via SaveManager.landing_pad_filters_by_sector so
## the source side can match a pod's cargo before queuing the delivery.
func _serialize_landing_pad_filters() -> Dictionary:
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	var out := {}
	if logistics == null or not ("landing_pad_filters" in logistics):
		return out
	for anchor in logistics.landing_pad_filters:
		var arr: Array = logistics.landing_pad_filters[anchor]
		var serialized: Array = []
		for sn in arr:
			serialized.append(String(sn))
		out[_vec2i_to_str(anchor)] = serialized
	return out


func _deserialize_landing_pad_filters(raw: Dictionary) -> void:
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	if logistics == null or not ("landing_pad_filters" in logistics):
		return
	logistics.landing_pad_filters.clear()
	for k in raw:
		var arr_in: Array = raw[k]
		var arr_out: Array = []
		for s in arr_in:
			arr_out.append(StringName(s))
		logistics.landing_pad_filters[_str_to_vec2i(k)] = arr_out


func _serialize_sorter_filters() -> Dictionary:
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	var result := {}
	if logistics != null:
		for grid_pos in logistics.sorter_filters:
			var filter_id = logistics.sorter_filters[grid_pos]
			if filter_id != &"":
				result[_vec2i_to_str(grid_pos)] = String(filter_id)
		return result
	# Editor fallback: BuildingSystem.editor_sorter_filters
	var building_sys = get_node_or_null("/root/Main/BuildingSystem")
	if building_sys and "editor_sorter_filters" in building_sys:
		for grid_pos in building_sys.editor_sorter_filters:
			var filter_id = building_sys.editor_sorter_filters[grid_pos]
			if filter_id != &"":
				result[_vec2i_to_str(grid_pos)] = String(filter_id)
	return result


## Serializes the per-anchor recipe selection for recipe-select factories
## (Rod Shapper / Compound Mixer / etc.) so a factory remembers which recipe
## it was set to across save/load. Anchor → recipe id (StringName as String).
func _serialize_factory_recipe_state() -> Dictionary:
	var logistics = get_node_or_null("/root/Main/LogisticsSystem")
	var result := {}
	if logistics != null and "factory_recipe_state" in logistics:
		for grid_pos in logistics.factory_recipe_state:
			var recipe_id = logistics.factory_recipe_state[grid_pos]
			if recipe_id != &"":
				result[_vec2i_to_str(grid_pos)] = String(recipe_id)
	return result


func _serialize_links(linked_pairs: Array) -> Array:
	var result := []
	for pair in linked_pairs:
		result.append([_vec2i_to_str(pair[0]), _vec2i_to_str(pair[1])])
	return result


func _deserialize_links(main: Node2D, links_data: Array) -> void:
	for pair in links_data:
		if pair is Array and pair.size() == 2:
			main.linked_pairs.append([_str_to_vec2i(pair[0]), _str_to_vec2i(pair[1])])


## FEROX rebuild queue: destroyed FEROX blocks awaiting a shardling
## rebuild. Each entry is {block_id: StringName, grid_pos: Vector2i,
## rotation: int}; serialize to JSON-safe primitives so the queue survives
## a close/reopen and the base keeps self-repairing on the next session.
func _serialize_ferox_rebuild_queue(queue: Array) -> Array:
	var result := []
	for entry in queue:
		if entry is Dictionary and entry.has("block_id") and entry.has("grid_pos"):
			var lo: Array = []
			for p in entry.get("links_out", []):
				lo.append(_vec2i_to_str(p))
			var li: Array = []
			for p in entry.get("links_in", []):
				li.append(_vec2i_to_str(p))
			result.append({
				"block_id": str(entry["block_id"]),
				"grid_pos": _vec2i_to_str(entry["grid_pos"]),
				"rotation": int(entry.get("rotation", 0)),
				"links_out": lo,
				"links_in": li,
			})
	return result


func _deserialize_ferox_rebuild_queue(main: Node2D, raw) -> void:
	if not ("ferox_rebuild_queue" in main):
		return
	main.ferox_rebuild_queue.clear()
	if not (raw is Array):
		return
	for entry in raw:
		if not (entry is Dictionary) or not entry.has("block_id") or not entry.has("grid_pos"):
			continue
		var bid := StringName(str(entry["block_id"]))
		# Drop stale entries whose cell got re-occupied (e.g. the player
		# built over the crater) — a rebuild there would silently fail.
		var gp: Vector2i = _str_to_vec2i(str(entry["grid_pos"]))
		if main.placed_buildings.has(gp):
			continue
		var lo: Array = []
		for p in entry.get("links_out", []):
			lo.append(_str_to_vec2i(str(p)))
		var li: Array = []
		for p in entry.get("links_in", []):
			li.append(_str_to_vec2i(str(p)))
		main.ferox_rebuild_queue.append({
			"block_id": bid,
			"grid_pos": gp,
			"rotation": int(entry.get("rotation", 0)),
			"links_out": lo,
			"links_in": li,
		})


func _deserialize_links_to(target_array: Array, links_data: Array) -> void:
	for pair in links_data:
		if pair is Array and pair.size() == 2:
			target_array.append([_str_to_vec2i(pair[0]), _str_to_vec2i(pair[1])])


func _serialize_script_steps() -> Array:
	# In gameplay: get steps from SectorScript
	var sector_script = get_node_or_null("/root/Main/SectorScript")
	if sector_script and sector_script.get("_script_steps") != null and not sector_script._script_steps.is_empty():
		return sector_script._script_steps.duplicate(true)
	# In editor: get steps from script_editor
	var main_node = get_node_or_null("/root/Main")
	if main_node == null:
		return []
	var se = main_node.get("script_editor")
	if se == null or not se.has_method("get_script_data"):
		return []
	return se.get_script_data()


func _deserialize_script_steps(main_node: Node2D, steps_data: Array) -> void:
	var se = main_node.get("script_editor")
	if se and se.has_method("set_script_data"):
		se.set_script_data(steps_data)


# =========================
# GLOBAL HINTS
# =========================

## Reads global hint definitions from `user://global_hints.json`, falling
## back to the bundled `res://data/game/global_hints.json` (which lets a
## fresh install ship with a default global-hints set, no save required).
## Result lives in `global_hints` and is merged into every sector's hint
## list at landing time.
func load_global_hints_file() -> void:
	global_hints.clear()
	var path: String = ""
	if FileAccess.file_exists(GLOBAL_HINTS_USER_PATH):
		path = GLOBAL_HINTS_USER_PATH
	elif FileAccess.file_exists(GLOBAL_HINTS_BUNDLED_PATH):
		path = GLOBAL_HINTS_BUNDLED_PATH
	if path == "":
		return
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var txt: String = f.get_as_text()
	f.close()
	var d = JSON.parse_string(txt)
	if d is Array:
		for h in d:
			if h is Dictionary:
				# Force the global flag on every entry — defensive in case
				# a file was hand-edited and forgot to set it.
				h["global"] = true
				global_hints.append(h)


## Writes the given hints array to the user-side global file. Called by
## the script editor whenever the global-hints set changes; replaces the
## in-memory `global_hints` so subsequent merges pick up the latest list.
func save_global_hints_file(hints: Array) -> bool:
	global_hints = hints.duplicate(true)
	for h in global_hints:
		if h is Dictionary:
			h["global"] = true
	var f = FileAccess.open(GLOBAL_HINTS_USER_PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(global_hints, "\t"))
	f.close()
	return true




## Records a global hint's runtime state. Persists to disk via
## `save_campaign` so the dismissal carries across sectors / sessions.
func set_global_hint_runtime(id: String, runtime: Dictionary) -> void:
	global_hints_runtime[id] = runtime.duplicate(true)
	save_campaign()


## Returns the runtime entry for a global hint, or an empty Dictionary if
## none exists yet. Used by SectorScript when seeding `_hint_runtime` for
## merged-in globals so a previously-active hint resumes mid-flight.
func get_global_hint_runtime(id: String) -> Dictionary:
	var v = global_hints_runtime.get(id, {})
	if v is Dictionary:
		return v.duplicate(true)
	return {}


func _serialize_hints() -> Array:
	# Prefer in-game hints (live SectorScript) over editor staging.
	# Global hints are stored in the global file — strip them out of the
	# per-sector save so we don't double-persist (and so stale copies can't
	# resurrect a deleted/edited global hint).
	var raw: Array = []
	var sector_script = get_node_or_null("/root/Main/SectorScript")
	if sector_script and sector_script.has_method("get_hints"):
		var live: Array = sector_script.get_hints()
		if live.size() > 0:
			raw = live
	if raw.is_empty():
		var main_node = get_node_or_null("/root/Main")
		if main_node != null:
			var se = main_node.get("script_editor")
			if se and se.has_method("get_hints_data"):
				raw = se.get_hints_data()
	var sector_only: Array = []
	for h in raw:
		if h is Dictionary and bool(h.get("global", false)):
			continue
		sector_only.append(h)
	return sector_only


# =========================
# FILE I/O
# =========================

func _write_json(path: String, data: Dictionary) -> bool:
	# FileAccess.open() opens a file for reading or writing.
	# WRITE mode creates the file if it doesn't exist.
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("SaveManager: Could not open file for writing: " + path)
		return false

	# JSON.stringify() converts a Dictionary to a JSON string.
	# The second argument "\t" adds tab indentation for readability.
	var json_string = JSON.stringify(data, "\t")
	file.store_string(json_string)
	file.close()

	print("SaveManager: Saved to " + path)
	return true


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_warning("SaveManager: File not found: " + path)
		return null

	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("SaveManager: Could not open file: " + path)
		return null

	var json_string = file.get_as_text()
	file.close()

	# JSON.new() creates a parser, .parse() reads the string.
	var json = JSON.new()
	var error = json.parse(json_string)
	if error != OK:
		push_warning("SaveManager: JSON parse error: " + json.get_error_message())
		return null

	return json.data


# =========================
# GLOBAL RESOURCE POOL
# =========================

## Syncs the currently active sector's resources from Main.
## Call this before spending from the global pool while in-game.
func sync_active_sector_resources() -> void:
	var main = get_node_or_null("/root/Main")
	if main == null or not main.get("resources"):
		return
	if active_sector_id == &"":
		# No sector is active (map editor, planet select, pre-landing).
		# Don't invent a `_default` placeholder — the legacy fallback
		# leaked an `_default.sector.json` file every time an autosave
		# fired without a real sector id, and downstream code already
		# defends against that key. Just bail.
		return
	# Refresh the live cap every sync so placing/losing cores while
	# playing keeps the offline accrual ceiling accurate.
	if main.has_method("get_storage_cap_per_resource"):
		sector_storage_caps[active_sector_id] = int(main.get_storage_cap_per_resource())
	sector_resources[active_sector_id] = main.resources.duplicate()


## Returns the global resource pool: sum of all captured sectors' resources.
func get_global_resources() -> Dictionary:
	# Apply offline accrual so UIs that poll this see live-updating totals
	# while the player is on the planet menu.
	advance_offline_production()
	# Push the live active sector's stockpile + cap into the cache before
	# the clamp so the panel sees the actual `main.resources` rather than
	# a stale snapshot from the last autosave / sync tick. Without this
	# the tech tree could lag the world by up to `_AUTO_WIPE_INTERVAL`.
	sync_active_sector_resources()
	# Defensive: re-clamp every sector against its recorded cap on each
	# poll. The accrual loop already clamps as it adds, but in-place
	# values can drift over cap from legacy saves, save-format changes,
	# or a core being destroyed — and previously the clamp only ran at
	# campaign-load time, so stale over-cap totals leaked into the pool
	# for the rest of the session.
	_clamp_sector_resources_to_caps()
	var pool: Dictionary = {}
	for sector_id in sector_resources:
		# Always read the active sector straight from `main.resources` so
		# the tech tree's Global Resources panel mirrors the in-world HUD
		# exactly, even between auto-sync ticks. Other sectors keep
		# pulling from the cached snapshot + offline accrual.
		var bucket: Dictionary = sector_resources[sector_id]
		if sector_id == active_sector_id:
			var live_main_g = get_node_or_null("/root/Main")
			if live_main_g and live_main_g.get("resources") is Dictionary:
				bucket = live_main_g.resources
		for item_id in bucket:
			pool[item_id] = pool.get(item_id, 0) + int(bucket[item_id])
	return pool


## Takes up to `amount` of `item_id` from the global pool.
## Deducts from the sector with the most of that resource first.
## Returns the amount actually taken.
func take_from_global_pool(item_id: StringName, amount: int) -> int:
	if amount <= 0:
		return 0
	var remaining = amount

	# Collect sectors that have this item, sorted by amount descending
	var sectors_with_item: Array = []
	for sid in sector_resources:
		var amt: int = sector_resources[sid].get(item_id, 0)
		if amt > 0:
			sectors_with_item.append(sid)
	sectors_with_item.sort_custom(func(a, b):
		return sector_resources[a].get(item_id, 0) > sector_resources[b].get(item_id, 0)
	)

	for sid in sectors_with_item:
		if remaining <= 0:
			break
		var available: int = sector_resources[sid].get(item_id, 0)
		var to_take: int = mini(remaining, available)
		sector_resources[sid][item_id] -= to_take
		remaining -= to_take

	# If we deducted from the active sector, push changes back to Main
	if active_sector_id != &"" and sector_resources.has(active_sector_id):
		var main = get_node_or_null("/root/Main")
		if main and main.get("resources"):
			for key in sector_resources[active_sector_id]:
				main.resources[key] = sector_resources[active_sector_id][key]

	return amount - remaining


# =========================
# CAMPAIGN SAVE / LOAD
# =========================

## Saves campaign-level state: tech tree progress + per-sector resources.
func save_campaign() -> bool:
	# Trim before serialising so the on-disk pool can never persist an
	# over-cap value. Pairs with the auto-wiper / get_global_resources
	# clamps so every read AND write path enforces the cap.
	_clamp_sector_resources_to_caps()
	var data := {
		"version": 1,
		"type": "campaign",
		"tech_tree": TechTree.get_save_data(),
		"sector_resources": _serialize_sector_resources(),
		"sector_production_rates": _serialize_production_rates(),
		"sector_production_timestamps": _serialize_production_timestamps(),
		"sector_storage_caps": _serialize_storage_caps(),
		"global_hints_runtime": global_hints_runtime.duplicate(true),
		"pending_pod_deliveries": _serialize_pending_pod_deliveries(),
		"landing_pad_filters_by_sector": _serialize_landing_pad_filters_by_sector(),
		"landing_pad_delivery_count": _serialize_landing_pad_delivery_count(),
	}
	return _write_json(SAVES_DIR + "campaign.json", data)


func _serialize_landing_pad_filters_by_sector() -> Dictionary:
	var out := {}
	for sid in landing_pad_filters_by_sector:
		out[String(sid)] = landing_pad_filters_by_sector[sid].duplicate(true)
	return out


func _deserialize_landing_pad_filters_by_sector(raw: Dictionary) -> void:
	landing_pad_filters_by_sector.clear()
	for sid_str in raw:
		landing_pad_filters_by_sector[StringName(sid_str)] = (raw[sid_str] as Dictionary).duplicate(true)


func _serialize_pending_pod_deliveries() -> Dictionary:
	# JSON dicts can't have Vector2i / StringName keys/values. Flatten
	# every per-sector queue so the file round-trips cleanly.
	var out := {}
	for dest_sid in pending_pod_deliveries:
		var arr: Array = pending_pod_deliveries[dest_sid]
		var flat: Array = []
		for pod in arr:
			var items_in: Dictionary = pod.get("items", {})
			var items_out := {}
			for k in items_in:
				items_out[String(k)] = int(items_in[k])
			var fluids_in: Dictionary = pod.get("fluids", {})
			var fluids_out := {}
			for k in fluids_in:
				fluids_out[String(k)] = float(fluids_in[k])
			var routing_in: Array = pod.get("routing", [])
			var routing_out: Array = []
			for r in routing_in:
				routing_out.append(String(r))
			flat.append({
				"items": items_out,
				"fluids": fluids_out,
				"from_sector": String(pod.get("from_sector", &"")),
				"routing": routing_out,
			})
		out[String(dest_sid)] = flat
	return out


func _deserialize_pending_pod_deliveries(raw: Dictionary) -> void:
	pending_pod_deliveries.clear()
	for dest_str in raw:
		var arr: Array = raw[dest_str]
		var rebuilt: Array = []
		for pod in arr:
			var items_in: Dictionary = pod.get("items", {})
			var items_out := {}
			for k in items_in:
				items_out[StringName(k)] = int(items_in[k])
			var fluids_in: Dictionary = pod.get("fluids", {})
			var fluids_out := {}
			for k in fluids_in:
				fluids_out[StringName(k)] = float(fluids_in[k])
			var routing_in: Array = pod.get("routing", [])
			var routing_out: Array = []
			for r in routing_in:
				routing_out.append(String(r))
			rebuilt.append({
				"items": items_out,
				"fluids": fluids_out,
				"from_sector": StringName(pod.get("from_sector", "")),
				"routing": routing_out,
			})
		pending_pod_deliveries[StringName(dest_str)] = rebuilt


func _serialize_storage_caps() -> Dictionary:
	var result := {}
	for sid in sector_storage_caps:
		result[String(sid)] = int(sector_storage_caps[sid])
	return result


func _serialize_landing_pad_delivery_count() -> Dictionary:
	var result := {}
	for sid in landing_pad_delivery_count:
		var per_sector: Dictionary = landing_pad_delivery_count[sid]
		var copy := {}
		for k in per_sector:
			copy[String(k)] = int(per_sector[k])
		result[String(sid)] = copy
	return result


func _deserialize_landing_pad_delivery_count(data: Dictionary) -> void:
	landing_pad_delivery_count.clear()
	for sid_str in data:
		var raw = data[sid_str]
		if not (raw is Dictionary):
			continue
		var per_sector := {}
		for k in (raw as Dictionary):
			per_sector[String(k)] = int(raw[k])
		landing_pad_delivery_count[StringName(sid_str)] = per_sector


func _deserialize_storage_caps(data: Dictionary) -> void:
	sector_storage_caps.clear()
	for sid_str in data:
		sector_storage_caps[StringName(sid_str)] = int(data[sid_str])


## Trims every sector's stockpile down to its saved per-resource cap.
## No-op for sectors that never had a cap recorded (old saves / sectors
## that were never actually saved) so we don't zero out legit progress.
func _clamp_sector_resources_to_caps() -> void:
	# Pick up the incinerate rule from main. Centralized here so legacy
	# saves that wrote coal/sand into sector_resources before the rule
	# existed get scrubbed on the next tick rather than persisting in
	# the global pool forever.
	var main_for_check = get_node_or_null("/root/Main")
	var has_incin_check: bool = main_for_check != null and main_for_check.has_method("is_incinerated_at_core")
	for sid in sector_resources.keys():
		var bucket: Dictionary = sector_resources[sid]
		if has_incin_check:
			for item_id in bucket.keys():
				if main_for_check.is_incinerated_at_core(item_id):
					bucket.erase(item_id)
		var cap: int = int(sector_storage_caps.get(sid, 0))
		if cap <= 0:
			continue
		for item_id in bucket.keys():
			if int(bucket[item_id]) > cap:
				bucket[item_id] = cap
	# Clamp the LIVE active stockpile against its own cap too. Without
	# this, `main.resources` happily piles past the cap and the next
	# `sync_active_sector_resources` re-uploads the over-cap totals into
	# `sector_resources[active_sector_id]`, defeating the per-sector
	# clamp above. Same incinerate scrub applies — coal/sand in
	# `main.resources` from a legacy save shouldn't linger in the HUD.
	if main_for_check and active_sector_id != &"" \
			and main_for_check.get("resources") and main_for_check.has_method("get_storage_cap_per_resource"):
		var live_cap: int = int(main_for_check.get_storage_cap_per_resource())
		var live_changed: bool = false
		for key in main_for_check.resources.keys():
			if has_incin_check and main_for_check.is_incinerated_at_core(key) \
					and int(main_for_check.resources[key]) > 0:
				main_for_check.resources[key] = 0
				live_changed = true
				continue
			if live_cap > 0 and int(main_for_check.resources[key]) > live_cap:
				main_for_check.resources[key] = live_cap
				live_changed = true
		if live_changed and main_for_check.has_signal("resources_changed"):
			main_for_check.resources_changed.emit(main_for_check.resources)


## Captures the live sector's resource production rate and stamps "now".
## Called when the active sector is about to go idle (player returns to
## planet menu, quits, or switches sectors) so its rates are locked in
## for offline accrual. The caller must ensure `main` is the live scene
## for the sector identified by `sector_id`.
func capture_production_snapshot(sector_id: StringName, main: Node2D) -> void:
	if sector_id == &"":
		return
	var rates: Dictionary = SectorProductionSim.calculate_rates(main)
	sector_production_rates[sector_id] = rates
	sector_production_timestamps[sector_id] = Time.get_unix_time_from_system()
	# Snapshot storage cap at the same moment so offline accrual knows
	# when to stop producing for this sector even though the sector
	# isn't simulated in full.
	if main.has_method("get_storage_cap_per_resource"):
		sector_storage_caps[sector_id] = int(main.get_storage_cap_per_resource())


## Advances offline production for every non-active sector: for each one,
## adds `rate * elapsed` of each item_id into its sector_resources dict
## and resets its timestamp to `now`. Fractional leftovers are preserved
## so slow producers still accrue integer items over multiple calls.
func advance_offline_production() -> void:
	var now: float = Time.get_unix_time_from_system()
	for sid in sector_production_rates:
		if sid == active_sector_id:
			# Live sector is simulated by the running game — skip.
			sector_production_timestamps[sid] = now
			continue
		var rates: Dictionary = sector_production_rates[sid]
		if rates.is_empty():
			sector_production_timestamps[sid] = now
			continue
		var last: float = float(sector_production_timestamps.get(sid, now))
		var elapsed: float = now - last
		if elapsed <= 0.0:
			continue
		var cap: int = int(sector_storage_caps.get(sid, 0))
		# No recorded storage cap for this sector means we have no idea
		# what its core stockpile can actually hold — usually a legacy
		# save written before the cap was tracked. Refusing to accrue
		# (instead of accruing unbounded) prevents stale timestamps × a
		# non-zero rate from generating millions of items on first load.
		# The next save of this sector will record a cap and accrual
		# resumes normally.
		if cap <= 0:
			sector_production_timestamps[sid] = now
			continue
		if not sector_resources.has(sid):
			sector_resources[sid] = {}
		if not _sector_production_fractions.has(sid):
			_sector_production_fractions[sid] = {}
		var bucket: Dictionary = sector_resources[sid]
		var fracs: Dictionary = _sector_production_fractions[sid]
		# Items the core incinerates (coal, sand) shouldn't accrue into
		# the offline pool either — they'd disappear on the next belt
		# tick if the sector were live, so the global resource readout
		# would be lying. Look up the rule via main when available so
		# the list stays canonical in one place.
		var main_for_check = get_node_or_null("/root/Main")
		var has_incin_check: bool = main_for_check != null and main_for_check.has_method("is_incinerated_at_core")
		for item_id in rates:
			var rate: float = float(rates[item_id])
			if rate == 0.0:
				continue
			if has_incin_check and main_for_check.is_incinerated_at_core(item_id):
				# Wipe any stale carry-over fraction so toggling the
				# blacklist later doesn't release a hidden spike.
				fracs.erase(item_id)
				bucket.erase(item_id)
				continue
			var added: float = rate * elapsed + float(fracs.get(item_id, 0.0))
			var whole: int = int(floor(added))
			fracs[item_id] = added - float(whole)
			if whole == 0:
				continue
			var current: int = int(bucket.get(item_id, 0))
			var new_amt: int = current + whole
			# Net-negative rates (under-fed factories) can't drive a
			# stockpile below zero — clamp and drop the fractional
			# carryover so the factory doesn't keep "owing" items.
			if new_amt < 0:
				new_amt = 0
				fracs[item_id] = 0.0
			# Storage cap: a sector can't accrue past what its cores
			# could actually hold if it were live. Clamp AND stop
			# carrying fractional overflow so it doesn't just leak out
			# next tick.
			if cap > 0 and new_amt > cap:
				new_amt = cap
				fracs[item_id] = 0.0
			bucket[item_id] = new_amt
		# Defensive sweep: if the bucket has pre-existing items that
		# already exceed the cap (destroyed core, data migration, etc.)
		# clamp them too. Zero-rate items were never visited by the loop.
		if cap > 0:
			for item_id in bucket.keys():
				if int(bucket[item_id]) > cap:
					bucket[item_id] = cap
		sector_production_timestamps[sid] = now


func _serialize_production_rates() -> Dictionary:
	var result := {}
	for sid in sector_production_rates:
		var inner := {}
		for item_id in sector_production_rates[sid]:
			inner[String(item_id)] = float(sector_production_rates[sid][item_id])
		result[String(sid)] = inner
	return result


func _serialize_production_timestamps() -> Dictionary:
	var result := {}
	for sid in sector_production_timestamps:
		result[String(sid)] = float(sector_production_timestamps[sid])
	return result


func _deserialize_production_rates(data: Dictionary) -> void:
	sector_production_rates.clear()
	for sid_str in data:
		var sid := StringName(sid_str)
		var inner := {}
		for item_id_str in data[sid_str]:
			inner[StringName(item_id_str)] = float(data[sid_str][item_id_str])
		sector_production_rates[sid] = inner


func _deserialize_production_timestamps(data: Dictionary) -> void:
	sector_production_timestamps.clear()
	for sid_str in data:
		sector_production_timestamps[StringName(sid_str)] = float(data[sid_str])


## Loads campaign-level state. Called automatically on startup.
func load_campaign() -> bool:
	var path = SAVES_DIR + "campaign.json"
	if not FileAccess.file_exists(path):
		return false
	var data = _read_json(path)
	if data == null:
		return false
	if data.has("tech_tree"):
		var td: Dictionary = {}
		for key in data["tech_tree"]:
			var spent_data: Dictionary = {}
			for item_key in data["tech_tree"][key]:
				spent_data[StringName(item_key)] = int(data["tech_tree"][key][item_key])
			td[StringName(key)] = spent_data
		TechTree.load_save_data(td)
	if data.has("sector_resources"):
		_deserialize_sector_resources(data["sector_resources"])
	if data.has("sector_production_rates"):
		_deserialize_production_rates(data["sector_production_rates"])
	if data.has("sector_production_timestamps"):
		_deserialize_production_timestamps(data["sector_production_timestamps"])
	if data.has("sector_storage_caps"):
		_deserialize_storage_caps(data["sector_storage_caps"])
	if data.has("global_hints_runtime") and data["global_hints_runtime"] is Dictionary:
		global_hints_runtime = (data["global_hints_runtime"] as Dictionary).duplicate(true)
	if data.has("pending_pod_deliveries") and data["pending_pod_deliveries"] is Dictionary:
		_deserialize_pending_pod_deliveries(data["pending_pod_deliveries"])
	if data.has("landing_pad_filters_by_sector") and data["landing_pad_filters_by_sector"] is Dictionary:
		_deserialize_landing_pad_filters_by_sector(data["landing_pad_filters_by_sector"])
	if data.has("landing_pad_delivery_count") and data["landing_pad_delivery_count"] is Dictionary:
		_deserialize_landing_pad_delivery_count(data["landing_pad_delivery_count"])
	# Clamp any existing stockpile against its saved cap before the
	# accrual pass — handles the "a core was destroyed last session"
	# case, old saves that pre-date the cap, and any other over-cap
	# state that somehow got persisted.
	_clamp_sector_resources_to_caps()
	# Apply any resources produced while the game was closed. Uses the
	# saved per-sector rates + timestamps captured at last snapshot.
	advance_offline_production()
	# Sync event-only material unlocks against the GLOBAL pool (sum of
	# all sectors). The per-sector load path only sees the active
	# sector's stockpile, so steel produced on a different sector would
	# leave `mat_steel` and its dependents (Unit Refabricator, …) locked
	# even though the tech-tree's Global Resources panel visibly showed
	# the stockpile.
	TechTree.sync_event_unlocks_from_resources(get_global_resources())
	print("SaveManager: Campaign loaded (%d sectors with resources)" % sector_resources.size())
	return true


func _serialize_sector_resources() -> Dictionary:
	var result := {}
	for sector_id in sector_resources:
		var res_data := {}
		for item_id in sector_resources[sector_id]:
			res_data[String(item_id)] = sector_resources[sector_id][item_id]
		result[String(sector_id)] = res_data
	return result


func _deserialize_sector_resources(data: Dictionary) -> void:
	sector_resources.clear()
	for sector_id_str in data:
		var sid = StringName(sector_id_str)
		sector_resources[sid] = {}
		for item_id_str in data[sector_id_str]:
			sector_resources[sid][StringName(item_id_str)] = int(data[sector_id_str][item_id_str])


# =========================
# SCHEMATICS
# =========================

## Save a schematic to disk. blocks/rotation are Dictionaries with "x,y" string keys.
func save_schematic(schem_name: String, blocks: Dictionary, rotation: Dictionary, width: int, height: int) -> bool:
	# Compute total cost
	var total_cost: Dictionary = {}
	for pos_str in blocks:
		var block_id: StringName = StringName(blocks[pos_str])
		var data = Registry.get_block(block_id)
		if data:
			for item_id in data.build_cost:
				total_cost[String(item_id)] = total_cost.get(String(item_id), 0) + data.build_cost[item_id]

	var save_data: Dictionary = {
		"version": 1,
		"type": "schematic",
		"name": schem_name,
		"width": width,
		"height": height,
		"blocks": blocks,
		"rotation": rotation,
		"total_cost": total_cost,
	}
	var safe_name: String = schem_name.replace("/", "_").replace("\\", "_").replace(":", "_").strip_edges()
	if safe_name == "":
		safe_name = "unnamed"
	return _write_json(SCHEMATIC_DIR + safe_name + ".schematic.json", save_data)


## Load a schematic from disk. Returns the parsed Dictionary or null.
func load_schematic(schem_name: String) -> Variant:
	var safe_name: String = schem_name.replace("/", "_").replace("\\", "_").replace(":", "_").strip_edges()
	return _read_json(SCHEMATIC_DIR + safe_name + ".schematic.json")


## List all saved schematic names (without extension).
func list_schematics() -> PackedStringArray:
	var result: PackedStringArray = []
	var dir = DirAccess.open(SCHEMATIC_DIR)
	if dir == null:
		return result
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if file_name.ends_with(".schematic.json"):
			result.append(file_name.replace(".schematic.json", ""))
		file_name = dir.get_next()
	dir.list_dir_end()
	result.sort()
	return result


## Delete a schematic file.
func delete_schematic(schem_name: String) -> bool:
	var safe_name: String = schem_name.replace("/", "_").replace("\\", "_").replace(":", "_").strip_edges()
	var path: String = SCHEMATIC_DIR + safe_name + ".schematic.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		return true
	return false
