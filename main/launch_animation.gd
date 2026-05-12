extends Node2D
class_name LaunchAnimation

## Mindustry-style sector launch / land animation.
##
## States (state machine — only one active at a time):
##   IDLE       — nothing on screen; gameplay runs normally.
##   LANDING    — clouds cover the screen, core spins counter-clockwise
##                shrinking from oversized → 1.0× as the camera zooms
##                in. Triggered on sector load.
##   LANDED     — small screen shake + camera-out tween, then we kick
##                the ring sweep.
##   RING_SWEEP — yellow ring expands from the core; pre-built LUMINA
##                blocks light up yellow → white → fade-to-normal as
##                the ring passes over them.
##   LAUNCHING  — reverse of LANDING; clouds fade in, core grows +
##                spins clockwise, camera zooms out. When the timer
##                ends, the animation emits `launch_complete` and the
##                outer sector-launch code does the scene swap.
##
## Wiring:
##   - main._ready() calls `play_landing(core_anchor)` after the sector
##     is loaded. Use the explicit core anchor so multi-tile cores
##     centre properly.
##   - Code that wants to launch a NEW sector calls `play_launch()`
##     and connects `launch_complete` to do the actual scene transition.
##   - BuildingSystem._draw_placed_buildings queries
##     `get_block_reveal_tint(anchor)` AFTER painting each block so the
##     ring-sweep flash composites on top of the final sprite.
##   - Pre-built blocks are captured once via `snapshot_prebuilt()` at
##     the end of sector load — any LUMINA block placed before that
##     call counts as "came with the sector".

signal launch_complete
signal land_complete

enum State { IDLE, LANDING, LANDED_PAUSE, RING_SWEEP, LAUNCHING }

@onready var main: Node2D = get_node_or_null("/root/Main")

# --- Tunables ---
const LAND_DURATION := 1.6           # seconds for the core-shrink+camera-in tween
const LAND_HOVER := 0.0              # after the zoom-in finishes, hover in place this long before the touchdown shake
const LANDED_PAUSE := 0.25           # tiny beat before the ring kicks off
const TOUCHDOWN_SHAKE := 11.0        # screen-shake amplitude on touchdown
const RING_SWEEP_SPEED := 720.0      # pixels/sec for the ring radius
const RING_THICKNESS := 6.0
const RING_COLOR := Color(1.0, 0.85, 0.2, 0.95)
const LAUNCH_DURATION := 1.4
const CLOUD_COUNT := 18
const CORE_SCALE_PEAK := 1.3         # subtle "a little bit" puff during follow, eases back to natural in the release tail
const CORE_ANCHOR_SCALE := 0.5       # fraction of "natural ground size" the on-screen core sits at during the animation (lower = smaller)
const CORE_SPIN_TURNS := 0.25        # how many full rotations the core makes during the descent / ascent
# Camera zoom curve. During LAUNCHING the camera pulls back from the
# player's current zoom to `saved_zoom × ZOOM_OUT_FACTOR` (so it
# scales with whatever zoom the player preferred); LANDING runs the
# reverse. The core sprite stays at constant on-screen size for most
# of the animation by drawing with inverse-zoom scale, then eases out
# of that compensation in the FOLLOW_RELEASE tail so the core visibly
# shrinks "down to the ground" once the camera stops following.
const ZOOM_OUT_FACTOR := 0.05         # multiplier on the saved zoom for the start of landing / end of launch
const ZOOM_IN_FACTOR := 0.38          # multiplier on the saved zoom for the end of landing / start of launch (1.0 = end at the player's preferred zoom; <1 = stop more zoomed-out)
const FOLLOW_RELEASE_T := 0.7         # fraction of phase progress where camera stops following the core
const CLOUD_WORLD_RING_INNER := 600.0
const CLOUD_WORLD_RING_OUTER := 2200.0
const BLOCK_REVEAL_TOTAL := 0.4      # 3 frames yellow + 3 frames white + remaining fade (in seconds, frame-rate-independent)
const BLOCK_REVEAL_YELLOW := 0.05    # ~3 frames at 60fps
const BLOCK_REVEAL_WHITE := 0.05
const CLOUD_COLOR := Color(0.9, 0.92, 0.95, 0.95)

# --- State ---
var state: int = State.IDLE
var _t: float = 0.0                  # phase-local timer
var _core_anchor: Vector2i = Vector2i.ZERO
var _core_world: Vector2 = Vector2.ZERO
var _ring_radius: float = 0.0
# Map of anchor → (time the ring first hit it). Block tint is derived
# from `now - hit_time` so the per-frame draw doesn't need a per-block
# tween node.
var _ring_hits: Dictionary = {}      # Vector2i -> float (game-time seconds)
# Set of LUMINA anchors that existed at snapshot_prebuilt time. Only
# these blocks get the ring-sweep reveal; player-placed blocks are
# invisible to the system.
var _prebuilt: Dictionary = {}       # Vector2i -> true
# Simple cloud particles: PackedArray of {pos, vel, scale, alpha}.
var _clouds: Array = []
# Reference to the core block to draw oversized on top during the
# animation. Loaded lazily from Registry.
var _core_data: BlockData = null

# Wind lines: vertical motion streaks. Each entry:
#   {x: float, y: float, len: float, speed: float, life: float, age: float}
# Spawned every WIND_SPAWN_INTERVAL during LANDING / LAUNCHING.
var _wind_lines: Array = []
var _wind_spawn_timer: float = 0.0
const WIND_SPAWN_INTERVAL := 0.04    # seconds between spawns
const WIND_LIFE := 0.9               # how long each line lives
const WIND_SPEED := 480.0            # px/sec the streak moves
const WIND_LEN_PEAK := 90.0          # max length in px

# Landing dust circles (the "rocket lands and kicks up debris" puff).
# Each entry:
#   {pos: Vector2, color: Color, radius: float, vel: Vector2,
#    life: float, age: float, fade_out: bool, stop_at: float}
# Spawned in a ring around the core during LANDING; once landing
# completes, moving circles stop spawning and static ones gradually
# get marked for fade-out across DUST_FADE_WINDOW seconds.
var _dust: Array = []
var _dust_spawn_timer: float = 0.0
var _dust_spawn_done: bool = false   # set true on LANDED_PAUSE entry
var _dust_fade_kick: float = -1.0    # game-time when fade-out starts (=LANDED_PAUSE entry)
const DUST_SPAWN_INTERVAL := 0.003  # ~4× the spawn rate for a denser plume
const DUST_RADIUS_MIN := 14.0
const DUST_RADIUS_MAX := 36.0
const DUST_RING_INNER := 0.5         # tiles from core where the dust ring starts
const DUST_RING_OUTER := 5.0         # tiles from core where the ring ends
const DUST_MOVING_FRACTION := 0.65   # ~55 % of spawned dust drifts outward, rest is static
const DUST_DRIFT_SPEED := 120.0
const DUST_FADE_WINDOW := 4.0        # seconds for static dust to randomly clear after landing
const DUST_STOP_DURATION := 0.6      # seconds for moving dust to decelerate to ~zero after touchdown

# Core thruster flaps — four texture instances around the core that
# extend outward when launching (snap out fast) and retract during the
# ring sweep (slow). Texture's "up" is its default outward direction.
var _flap_tex: Texture2D = preload("res://textures/blocks/cores/CoreShard/CoreShardThrusterFlap.png")
const FLAP_EXTEND_DURATION := 0.5   # launch start: 0 → 1 quickly
const LAUNCH_HOLD := FLAP_EXTEND_DURATION   # pre-liftoff hold — flaps fully extend and thrusters spin up before the core / camera start moving
const FLAP_RETRACT_DURATION := 5.0   # ring-sweep retraction: 1 → 0 slowly
# Texture is 512×160 (3.2 : 1). The flap spans the full core width
# (3 tiles for the core_shard) along the tangent and ~1 tile outward.
const FLAP_WIDTH_FRACTION := 1.0     # flap width (tangent to outward axis) = full core width
const FLAP_SIZE_FRACTION := 0.3125   # flap height (along outward axis) = 160/512 of width
# Divot positions inside the flap rect (normalized 0..1, origin top-left).
# Two thruster ports near the outward edge, symmetric about the centre.
const FLAP_THRUSTER_X := 0.33        # left port at 33 % across, right port mirrors at 67 %
const FLAP_THRUSTER_Y := 0.30        # vertical position from outward (top) edge
const FLAP_THRUSTER_RADIUS_FRAC := 0.18  # outer-glow radius as fraction of flap height

# Phase driver for the pulsing thruster glow (matches the shardling /
# drone back-thruster animation in player_drone.gd).
var _flap_thruster_phase: float = 0.0

# Two child Node2Ds, both `z_as_relative = false` so their z_index
# values are absolute (NOT added to this node's z=4090).
#   _underlay (z=30)     — dust circles drawn UNDER walls / blocks.
#   _flap_overlay (dyn)  — thruster flaps. The z flips per phase:
#       above walls (60) during LANDING / LAUNCHING / LANDED_PAUSE
#       so flaps render on top of adjacent wall tiles; below the
#       placed core (49) during RING_SWEEP / IDLE so the core
#       naturally hides retracting flaps. No separate mask overlay
#       needed — and no need to fight unit z layering.
var _underlay: Node2D = null
var _flap_overlay: Node2D = null

# Cached per-floor-tile-id Image used to sample dust colors from the
# terrain underneath. ImageTexture → Image conversion is a one-time
# cost we lazy-cache.
var _floor_color_cache: Dictionary = {}  # StringName -> Image

# Set of pre-built anchors NOT yet hit by the ring. BuildingSystem
# reads `is_block_hidden(anchor)` and skips drawing while present so
# the sector visually "spawns into existence" as the ring sweeps.
var _hidden_until_hit: Dictionary = {}   # Vector2i -> true

# Camera state snapshotted on play_landing/play_launch so we can
# restore the player's preferred zoom / focus when the animation ends.
var _cam_saved_zoom: float = 1.0
var _cam_saved_focus: Variant = null
var _cam: Camera2D = null


func _ready() -> void:
	# CanvasLayer-equivalent stacking — sit above every in-world layer.
	z_index = 4090
	z_as_relative = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Underlay: dust circles draw on this child at z=30 (under walls /
	# blocks) so they read as ground debris.
	_underlay = Node2D.new()
	_underlay.z_index = 30
	_underlay.z_as_relative = false
	_underlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_underlay)
	_underlay.draw.connect(_paint_underlay.bind(_underlay))
	# Flap overlay. z is reassigned per phase by `_update_flap_z()`:
	# above walls (60) while landing / launching, below the placed
	# core (49) during retraction so the core hides it naturally.
	# `z_as_relative=false` keeps z absolute regardless of this
	# node's own z=4090.
	_flap_overlay = Node2D.new()
	_flap_overlay.z_index = 49
	_flap_overlay.z_as_relative = false
	_flap_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_flap_overlay)
	_flap_overlay.draw.connect(_paint_flaps.bind(_flap_overlay))


func _process(delta: float) -> void:
	if state == State.IDLE and _dust.is_empty() and _wind_lines.is_empty():
		return
	# Freeze the entire animation pipeline while the world is paused:
	# the flap retraction, ring expansion, block reveals, dust drift,
	# wind streaks, and zoom curve all halt so the player can pause
	# the landing visuals mid-sweep. Visuals stay rendered at their
	# current state since we don't queue_redraw either.
	if main != null and "world_paused" in main and main.world_paused:
		return
	_t += delta
	# Thruster pulse — same shape as the shardling's back thrusters.
	_flap_thruster_phase += delta * 4.0
	# Cloud drift — keeps the sky alive while landing / launching.
	for c in _clouds:
		c["pos"] += c["vel"] * delta
	# Wind lines: spawn on a timer during LANDING/LAUNCHING, age out
	# regardless of state so a finished phase doesn't leave streaks
	# frozen in mid-air.
	_tick_wind_lines(delta)
	_tick_dust(delta)
	_drive_camera_zoom()
	match state:
		State.LANDING:
			_tick_landing(delta)
		State.LANDED_PAUSE:
			if _t >= LANDED_PAUSE:
				_t = 0.0
				_ring_radius = 0.0
				# Unhide the placed core so the ring sweep takes over
				# the visual; the animation stops drawing its own core
				# this same frame, no size pop.
				_hidden_until_hit.erase(_core_anchor)
				# Release focus_override now — camera_controller's
				# follow-lerp slides smoothly from the core to the drone
				# during RING_SWEEP. (Snapping at touchdown would jump.)
				if _cam != null and "focus_override" in _cam:
					_cam.focus_override = _cam_saved_focus
				state = State.RING_SWEEP
		State.RING_SWEEP:
			_tick_ring_sweep(delta)
		State.LAUNCHING:
			_tick_launching(delta)
	queue_redraw()
	if _underlay != null:
		_underlay.queue_redraw()
	if _flap_overlay != null:
		_update_flap_z()
		_flap_overlay.queue_redraw()


# ----- Wind lines -----

func _tick_wind_lines(delta: float) -> void:
	# Spawn during landing or launching only. New streaks always travel
	# UP (negative y on screen) but during launch they "grow" (small →
	# large) while during landing they "shrink" (large → small) so the
	# illusion reads correctly for both directions of travel.
	# Wind streaks: spawn during landing always; during launch only AFTER
	# the pre-liftoff hold (when the core is actually moving up).
	var wind_active: bool = state == State.LANDING \
		or (state == State.LAUNCHING and _t >= LAUNCH_HOLD)
	if wind_active:
		_wind_spawn_timer -= delta
		while _wind_spawn_timer <= 0.0:
			_wind_spawn_timer += WIND_SPAWN_INTERVAL
			_spawn_wind_line()
	# Age every line. Dead ones get pruned in reverse order so
	# remove_at() doesn't shift the cursor.
	for i in range(_wind_lines.size() - 1, -1, -1):
		var wl: Dictionary = _wind_lines[i]
		wl["age"] += delta
		wl["y"] -= wl["speed"] * delta
		if wl["age"] >= wl["life"]:
			_wind_lines.remove_at(i)


func _spawn_wind_line() -> void:
	var vp: Vector2 = get_viewport_rect().size
	_wind_lines.append({
		"x": randf() * vp.x,
		"y": vp.y * randf_range(0.6, 1.05),  # start in lower half of screen
		"len": randf_range(WIND_LEN_PEAK * 0.5, WIND_LEN_PEAK),
		"speed": randf_range(WIND_SPEED * 0.7, WIND_SPEED * 1.3),
		"life": WIND_LIFE,
		"age": 0.0,
	})


# ----- Landing dust -----

func _tick_dust(delta: float) -> void:
	if state == State.LANDING:
		_dust_spawn_timer -= delta
		while _dust_spawn_timer <= 0.0:
			_dust_spawn_timer += DUST_SPAWN_INTERVAL
			_spawn_dust()
	var now: float = Time.get_ticks_msec() / 1000.0
	for i in range(_dust.size() - 1, -1, -1):
		var d: Dictionary = _dust[i]
		d["age"] += delta
		# Touchdown: every existing particle (moving OR static) gets
		# scheduled for a smooth fade-out within DUST_FADE_WINDOW, and
		# moving particles decelerate to ~zero across DUST_STOP_DURATION
		# instead of being culled instantly at life-end.
		if _dust_spawn_done:
			if not bool(d.get("fade_out", false)):
				d["fade_out"] = true
				d["stop_at"] = now + randf_range(0.4, DUST_FADE_WINDOW)
			if d["vel"].length_squared() > 0.0001:
				var decay: float = 1.0 - clampf(delta / DUST_STOP_DURATION, 0.0, 1.0)
				d["vel"] *= decay
				if d["vel"].length_squared() < 4.0:
					d["vel"] = Vector2.ZERO
		d["pos"] += d["vel"] * delta
		# Cull rules:
		#   - fade_out scheduled: drop the particle once stop_at passes.
		#   - pre-touchdown moving particle: keep current life-end cull.
		if bool(d.get("fade_out", false)):
			if now >= float(d.get("stop_at", now)):
				_dust.remove_at(i)
				continue
		else:
			if d["age"] >= d["life"]:
				_dust.remove_at(i)


func _spawn_dust() -> void:
	if main == null:
		return
	var gs: float = float(main.GRID_SIZE)
	# Random point in the ring around the core. Reject cells with a wall.
	for _attempt in range(8):
		var angle: float = randf() * TAU
		var r_tiles: float = randf_range(DUST_RING_INNER, DUST_RING_OUTER)
		var offset: Vector2 = Vector2.from_angle(angle) * r_tiles * gs
		var world: Vector2 = _core_world + offset
		var cell: Vector2i = main.world_to_grid(world)
		var terrain = main.get_node_or_null("TerrainSystem")
		if terrain and terrain.has_method("has_wall") and terrain.has_wall(cell):
			continue
		# Sample colour from the floor underneath; fallback grey.
		var color: Color = _sample_floor_color(cell, terrain)
		var moving: bool = randf() < DUST_MOVING_FRACTION
		var vel: Vector2 = Vector2.ZERO
		if moving:
			vel = Vector2.from_angle(angle) * DUST_DRIFT_SPEED * randf_range(0.6, 1.2)
		_dust.append({
			"pos": world,
			"color": color,
			"radius": randf_range(DUST_RADIUS_MIN, DUST_RADIUS_MAX),
			"vel": vel,
			"life": randf_range(0.8, 1.5) if moving else 999.0,
			"age": 0.0,
			"fade_out": false,
			"stop_at": 0.0,
		})
		return


const DUST_DARKEN := 0.65   # multiplier on the sampled floor RGB — lower = darker / more visible against the floor

func _sample_floor_color(cell: Vector2i, terrain) -> Color:
	if terrain == null or not terrain.has_method("get_floor_at"):
		return Color(0.6 * DUST_DARKEN, 0.55 * DUST_DARKEN, 0.5 * DUST_DARKEN, 0.85)
	var tile_data = terrain.get_floor_at(cell)
	if tile_data == null or tile_data.icon == null:
		return Color(0.6 * DUST_DARKEN, 0.55 * DUST_DARKEN, 0.5 * DUST_DARKEN, 0.85)
	var tid: StringName = tile_data.id
	var img: Image = _floor_color_cache.get(tid, null)
	if img == null:
		img = tile_data.icon.get_image()
		if img == null:
			return Color(0.6 * DUST_DARKEN, 0.55 * DUST_DARKEN, 0.5 * DUST_DARKEN, 0.85)
		_floor_color_cache[tid] = img
	var sample_x: int = randi() % img.get_width()
	var sample_y: int = randi() % img.get_height()
	var c: Color = img.get_pixel(sample_x, sample_y)
	# Darken RGB so the dust reads as a deeper-toned puff of the same
	# material — same hue as the floor, but visibly distinct against it.
	c.r *= DUST_DARKEN
	c.g *= DUST_DARKEN
	c.b *= DUST_DARKEN
	c.a = 0.85
	return c


# ----- Public API -----

func snapshot_prebuilt() -> void:
	_prebuilt.clear()
	if main == null:
		return
	for cell in main.placed_buildings:
		var anchor: Vector2i = main.building_origins.get(cell, cell)
		if _prebuilt.has(anchor):
			continue
		if main.get_building_faction(anchor) != main.Faction.LUMINA:
			continue
		_prebuilt[anchor] = true


func play_landing(core_anchor: Vector2i) -> void:
	_core_anchor = core_anchor
	_resolve_core()
	_init_clouds()
	_ring_hits.clear()
	_wind_lines.clear()
	_dust.clear()
	_dust_spawn_timer = 0.0
	_dust_spawn_done = false
	_dust_fade_kick = -1.0
	# Every pre-built LUMINA block stays hidden until the ring crosses
	# it. Skip the core itself so the player sees what they're landing
	# on; everything else "spawns" as the ring passes.
	_hidden_until_hit.clear()
	for a in _prebuilt:
		_hidden_until_hit[a] = true
	# The core itself stays hidden through LANDING + LANDED_PAUSE so
	# the animation's spinning core sprite (drawn at CORE_ANCHOR_SCALE)
	# isn't undercut by the larger world-sized placed building peeking
	# out around its edges. It's revealed at RING_SWEEP entry below.
	_capture_camera()
	state = State.LANDING
	_t = 0.0


func play_launch() -> void:
	# Capture core from current placed_buildings if not already set.
	if _core_data == null and main:
		for cell in main.placed_buildings:
			var anchor: Vector2i = main.building_origins.get(cell, cell)
			var d = Registry.get_block(main.placed_buildings.get(anchor, &""))
			if d and d.tags.has("core") and main.get_building_faction(anchor) == main.Faction.LUMINA:
				_core_anchor = anchor
				_core_data = d
				_core_world = main.grid_to_world(anchor) + Vector2(d.grid_size.x * main.GRID_SIZE * 0.5, d.grid_size.y * main.GRID_SIZE * 0.5)
				break
	_init_clouds()
	_capture_camera()
	state = State.LAUNCHING
	_t = 0.0


## True while the ring hasn't passed `anchor` yet. BuildingSystem and
## the fog system both check this and skip emitting visuals for hidden
## blocks so the sector visually spawns into existence.
func is_block_hidden(anchor: Vector2i) -> bool:
	return _hidden_until_hit.has(anchor)



const INPUT_UNLOCK_SHAKE := 0.5    # max shake amplitude (px) considered "settled"

## True while the player should NOT be able to drive the shardling or
## interact with the world: the entire descent + ascent, and the brief
## settling window after touchdown while the screen shake is still
## rattling the view. The camera is snapped onto its follow target at
## touchdown, so we don't gate on camera proximity — that check
## flickered as the camera's steady-state lerp lag oscillated around
## the threshold, freezing drone movement every other frame.
func is_input_locked() -> bool:
	match state:
		State.IDLE:
			return false
		State.LANDING, State.LAUNCHING:
			return true
	if main == null:
		return true
	var fb = main.get_node_or_null("FeedbackSystem")
	if fb and "_shake_amp" in fb and float(fb._shake_amp) > INPUT_UNLOCK_SHAKE:
		return true
	return false


func _resolve_follow_target() -> Vector2:
	# Mirrors camera_controller's follow priority: controlled entity,
	# then PlayerDrone. Returns Vector2.INF when there's nothing valid
	# to follow yet.
	var unit_mgr = main.get_node_or_null("UnitManager")
	if unit_mgr and "controlled_entity" in unit_mgr and unit_mgr.controlled_entity != null:
		if "controlled_type" in unit_mgr:
			if unit_mgr.controlled_type == "unit":
				var u = unit_mgr.controlled_entity
				if is_instance_valid(u):
					return u.position
			elif unit_mgr.controlled_type == "turret":
				var grid_pos: Vector2i = unit_mgr.controlled_entity
				return main.grid_to_world(grid_pos) + Vector2(main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5)
	var drone = main.get_node_or_null("PlayerDrone")
	if drone and is_instance_valid(drone):
		return drone.position
	return Vector2.INF


# ----- Camera control -----

func _capture_camera() -> void:
	_cam = get_viewport().get_camera_2d()
	if _cam == null:
		return
	_cam_saved_zoom = _cam.zoom.x
	# `focus_override` is the camera controller's "lock onto this
	# world position" knob; remember it so we can restore.
	if "focus_override" in _cam:
		_cam_saved_focus = _cam.focus_override
		_cam.focus_override = _core_world


func _restore_camera() -> void:
	if _cam == null:
		return
	if "focus_override" in _cam:
		_cam.focus_override = _cam_saved_focus
	# Deliberately do NOT restore `target_zoom`: during RING_SWEEP the
	# player can scroll to adjust zoom, and writing `_cam_saved_zoom`
	# back here would yank them to whatever zoom they had at landing
	# start (a perceived "zoom in" if they had pulled out).


func _drive_camera_zoom() -> void:
	# During LANDING zoom goes `saved × ZOOM_OUT_FACTOR` → saved zoom
	# (the map rushes up to meet us); during LAUNCHING the reverse
	# runs. The core sprite is drawn with inverse-zoom compensation
	# during the FOLLOW phase so it stays constant on screen while
	# the map scales around it; in the FOLLOW_RELEASE tail the camera
	# stops following the core and the inverse-zoom compensation eases
	# out, so the core visibly shrinks the last little bit "down to
	# the ground" (LAND) or "lifting off" (LAUNCH).
	# Re-resolve the camera every frame if capture missed it — at
	# play_landing time the Camera2D may not yet be the viewport's
	# current camera, leaving _cam null forever.
	if _cam == null:
		_cam = get_viewport().get_camera_2d()
		if _cam != null:
			_cam_saved_zoom = _cam.zoom.x
			if "focus_override" in _cam:
				_cam_saved_focus = _cam.focus_override
		else:
			return
	var z: float
	var t: float
	var follow: bool
	if state == State.LANDING:
		t = clampf(_t / LAND_DURATION, 0.0, 1.0)
		# Landing uses the literal ZOOM factors so the player's saved
		# zoom doesn't drag the animation endpoints around — the
		# descent always reads at the same on-screen scale.
		z = lerpf(ZOOM_OUT_FACTOR, ZOOM_IN_FACTOR, ease(t, 1.6))
		# Keep the camera glued to the core the entire descent + hover
		# so it doesn't "snap" toward the drone as we touch down.
		follow = true
	elif state == State.LAUNCHING:
		# Hold the camera still for LAUNCH_HOLD seconds so the flaps can
		# extend and the thrusters can light up before any lift-off motion.
		t = clampf((_t - LAUNCH_HOLD) / LAUNCH_DURATION, 0.0, 1.0)
		# Launch starts from the literal ZOOM_IN_FACTOR (the zoom the
		# landing animation ends at) — independent of whatever zoom the
		# camera happened to have when the launch was queued.
		# Launch endpoints are also literal — independent of whatever
		# zoom the player happened to leave the camera at.
		z = lerpf(ZOOM_IN_FACTOR, ZOOM_OUT_FACTOR, ease(t, 1.6))
		follow = true
	else:
		return
	_cam.zoom = Vector2(z, z)
	if "target_zoom" in _cam:
		# Pin the controller's target while the animation owns zoom
		# so its smoothing doesn't fight us frame to frame.
		_cam.target_zoom = z
	# Release / restore focus_override based on the phase progress.
	if "focus_override" in _cam:
		if follow:
			_cam.focus_override = _core_world
		else:
			_cam.focus_override = null


## Returns a tint for `anchor` if the ring sweep has crossed it.
## RGB picks the tint colour, alpha is the strength (0 = no overlay,
## 1 = fully saturated). Building draw composites this on top of the
## block's sprite as a `draw_rect` with the returned colour.
func get_block_reveal_tint(anchor: Vector2i) -> Color:
	if not _ring_hits.has(anchor):
		return Color(0, 0, 0, 0)
	var now: float = Time.get_ticks_msec() / 1000.0
	var dt: float = now - float(_ring_hits[anchor])
	if dt < BLOCK_REVEAL_YELLOW:
		return Color(1.0, 0.85, 0.2, 0.85)
	if dt < BLOCK_REVEAL_YELLOW + BLOCK_REVEAL_WHITE:
		return Color(1.0, 1.0, 1.0, 0.9)
	var fade_t: float = (dt - BLOCK_REVEAL_YELLOW - BLOCK_REVEAL_WHITE) / maxf(BLOCK_REVEAL_TOTAL - BLOCK_REVEAL_YELLOW - BLOCK_REVEAL_WHITE, 0.001)
	if fade_t >= 1.0:
		return Color(0, 0, 0, 0)
	return Color(1.0, 1.0, 1.0, lerpf(0.9, 0.0, fade_t))


# ----- Internal: landing -----

func _tick_landing(_delta: float) -> void:
	# Phase: descend until LAND_DURATION, then hover in place for
	# LAND_HOVER seconds (camera still locked to the core, zoom pinned
	# at ZOOM_IN_FACTOR), THEN do the touchdown shake + zoom-punch.
	if _t >= LAND_DURATION + LAND_HOVER:
		var fb = main.get_node_or_null("FeedbackSystem")
		if fb:
			fb.add_shake(TOUCHDOWN_SHAKE)
		var cam = get_viewport().get_camera_2d()
		if cam:
			# Land at exactly ZOOM_IN_FACTOR — the descent's final zoom
			# — and stop. Don't auto-zoom-in further to the player's
			# saved zoom; that would feel like the camera "keeps going"
			# after landing. Player can scroll to zoom in/out from here.
			var final_zoom: float = ZOOM_IN_FACTOR
			cam.zoom = Vector2(final_zoom, final_zoom)
			if "target_zoom" in cam:
				cam.target_zoom = final_zoom
			# Keep focus_override on _core_world through LANDED_PAUSE so
			# the camera stays parked on the core during the pause.
			# Releasing it here (then snapping cam.position to the drone)
			# made the still-drawn animation core appear to teleport
			# off-centre. Release happens at the LANDED_PAUSE → RING_SWEEP
			# edge below; camera_controller's follow-lerp then slides
			# from the core over to the drone smoothly.
		_dust_spawn_done = true
		_dust_fade_kick = Time.get_ticks_msec() / 1000.0
		state = State.LANDED_PAUSE
		_t = 0.0


var _sweep_done_at: float = -1.0    # _t value when all prebuilt blocks were hit

func _tick_ring_sweep(_delta: float) -> void:
	_ring_radius += RING_SWEEP_SPEED * _delta
	# Mark any pre-built block the ring just crossed AND unhide it
	# so BuildingSystem starts drawing it on this frame. This is the
	# "spawn the block as the ring reaches it" effect — blocks
	# further than the ring's current radius stay hidden.
	var now: float = Time.get_ticks_msec() / 1000.0
	for anchor in _prebuilt:
		if _ring_hits.has(anchor):
			continue
		var bldg_world: Vector2 = main.grid_to_world(anchor) + Vector2(main.GRID_SIZE * 0.5, main.GRID_SIZE * 0.5)
		var d: float = _core_world.distance_to(bldg_world)
		if d <= _ring_radius:
			_ring_hits[anchor] = now
			_hidden_until_hit.erase(anchor)
	if _sweep_done_at < 0.0 and (_ring_hits.size() >= _prebuilt.size() or _ring_radius > 6000.0):
		_sweep_done_at = _t
	# Linger for one full reveal cycle past the last hit so the last
	# block's flash gets to finish before the system goes IDLE.
	if _sweep_done_at >= 0.0 and _t - _sweep_done_at >= BLOCK_REVEAL_TOTAL + 0.1:
		state = State.IDLE
		_sweep_done_at = -1.0
		# Safety: anything that somehow didn't get reached by the ring
		# (degenerate cases — block far off-map, ring cap reached) is
		# unhidden so we don't leave permanent ghosts.
		_hidden_until_hit.clear()
		_restore_camera()
		land_complete.emit()


func _tick_launching(_delta: float) -> void:
	if _t >= LAUNCH_DURATION + LAUNCH_HOLD:
		_restore_camera()
		state = State.IDLE
		launch_complete.emit()


# ----- Internal: setup -----

func _resolve_core() -> void:
	if main == null:
		return
	_core_data = Registry.get_block(main.placed_buildings.get(_core_anchor, &""))
	if _core_data:
		_core_world = main.grid_to_world(_core_anchor) + Vector2(_core_data.grid_size.x * main.GRID_SIZE * 0.5, _core_data.grid_size.y * main.GRID_SIZE * 0.5)
	else:
		_core_world = main.grid_to_world(_core_anchor)


func _init_clouds() -> void:
	# World-space clouds in a ring around the core. Because they live
	# in world coordinates, they scale with camera zoom naturally —
	# "clouds above the map scaling with it". As LAUNCH zooms out
	# (map shrinks), the clouds shrink alongside it.
	_clouds.clear()
	for i in range(CLOUD_COUNT):
		var angle: float = randf() * TAU
		var radius: float = randf_range(CLOUD_WORLD_RING_INNER, CLOUD_WORLD_RING_OUTER)
		var pos: Vector2 = _core_world + Vector2.from_angle(angle) * radius
		_clouds.append({
			"pos": pos,
			"vel": Vector2(randf_range(-25.0, 25.0), randf_range(-15.0, 15.0)),
			"scale": randf_range(0.8, 1.8),
		})


# ----- Render -----

func _draw() -> void:
	if state == State.IDLE and _dust.is_empty() and _wind_lines.is_empty():
		return
	# Phase progress 0..1
	var land_p: float = clampf(_t / LAND_DURATION, 0.0, 1.0) if state == State.LANDING else 0.0
	# Motion progress lags the launch start by LAUNCH_HOLD so flaps /
	# thrusters get a full beat before the core scales, rotates, and
	# the camera pulls back.
	var launch_p: float = clampf((_t - LAUNCH_HOLD) / LAUNCH_DURATION, 0.0, 1.0) if state == State.LAUNCHING else 0.0
	# Cloud opacity: 1 → 0 across landing (fade out as we touch down),
	# 0 → 1 across launching (fade in as we lift off), 0 elsewhere.
	var cloud_alpha: float = 0.0
	if state == State.LANDING:
		cloud_alpha = lerpf(1.0, 0.0, ease(land_p, 1.6))
	elif state == State.LAUNCHING:
		cloud_alpha = lerpf(0.0, 1.0, ease(launch_p, 1.6))
	elif state == State.LANDED_PAUSE:
		cloud_alpha = 0.0
	_draw_sky(cloud_alpha)
	# Dust + retracting flaps paint on _underlay at z=30 (under blocks)
	# so the placed core building covers them as flaps slide in.
	# Spinning oversized core: shrinks during landing, grows during
	# launching. Spin direction is opposite between the two phases.
	if state == State.LANDING or state == State.LAUNCHING or state == State.LANDED_PAUSE:
		_draw_core(land_p, launch_p)
	# During RING_SWEEP the placed core building (z=50) is unhidden and
	# naturally covers the retracting flaps (z=49) — no overlay needed.
	# Wind streaks paint OVER the core for the speed-line feel.
	_draw_wind_lines()
	# Ring during sweep.
	if state == State.RING_SWEEP:
		_draw_ring()


func _draw_wind_lines() -> void:
	if _wind_lines.is_empty():
		return
	# Wind streaks are in screen space, so we project them through the
	# camera transform every frame (matching the cloud projection).
	var camera := get_viewport().get_camera_2d()
	if camera == null:
		return
	var vp_size: Vector2 = get_viewport_rect().size
	var cam_center: Vector2 = camera.get_screen_center_position()
	var zoom: Vector2 = camera.zoom if camera.zoom != Vector2.ZERO else Vector2.ONE
	var half: Vector2 = vp_size / (2.0 * zoom)
	var tl: Vector2 = cam_center - half
	for wl in _wind_lines:
		var t: float = clampf(wl["age"] / wl["life"], 0.0, 1.0)
		# Length curve depends on phase:
		#   LAUNCHING: line GROWS (small → big) — sells the upward rush.
		#   LANDING:   line SHRINKS (big → small) — descending slowdown.
		var len_scale: float
		if state == State.LAUNCHING:
			len_scale = t
		else:
			len_scale = 1.0 - t
		var draw_len: float = wl["len"] * len_scale
		# Alpha rises from 0 then fades out at the tail of life.
		var alpha: float = sin(t * PI) * 0.55
		var screen_pos: Vector2 = Vector2(wl["x"], wl["y"])
		var world_pos: Vector2 = tl + screen_pos / zoom
		var top: Vector2 = world_pos + Vector2(0, -draw_len / zoom.y)
		draw_line(world_pos, top, Color(1, 1, 1, alpha), 2.0 / zoom.x, true)


func _paint_underlay(canvas: Node2D) -> void:
	_paint_dust(canvas)


func _paint_dust(canvas: Node2D) -> void:
	if _dust.is_empty():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	for d in _dust:
		var alpha: float = d["color"].a
		# Soft fade-in at spawn so circles don't pop.
		var spawn_t: float = clampf(d["age"] / 0.15, 0.0, 1.0)
		alpha *= spawn_t
		if bool(d.get("fade_out", false)):
			var remaining: float = float(d.get("stop_at", now)) - now
			var fade_t: float = clampf(remaining / DUST_FADE_WINDOW, 0.0, 1.0)
			alpha *= fade_t
		else:
			# Pre-touchdown: moving particles tail-fade over the last
			# 0.3 s of their life.
			if d["vel"].length_squared() > 0.01:
				var life_left: float = d["life"] - d["age"]
				alpha *= clampf(life_left / 0.3, 0.0, 1.0)
		if alpha <= 0.0:
			continue
		var c: Color = d["color"]
		canvas.draw_circle(d["pos"], d["radius"], Color(c.r, c.g, c.b, alpha))


func _compute_thruster_intensity() -> float:
	# Glow strength 0..1 for the two ports on each flap.
	# LANDING: full thrust during descent, fades during the hover beat
	# so the touchdown reads as "engines cutting off".
	# LAUNCHING: ramps up alongside the flaps extending.
	# Other states: off.
	match state:
		State.LANDING:
			if _t <= LAND_DURATION:
				return 1.0
			var hover_t: float = clampf((_t - LAND_DURATION) / 0.5, 0.0, 1.0)
			return 1.0 - hover_t
		State.LAUNCHING:
			return clampf(_t / FLAP_EXTEND_DURATION, 0.0, 1.0)
		_:
			return 0.0


func _compute_flap_t() -> float:
	# Flap extension 0..1 based on the current animation phase.
	# LANDING / LANDED_PAUSE: fully deployed (came down with the core).
	# RING_SWEEP: retract slowly across FLAP_RETRACT_DURATION.
	# LAUNCHING: snap from 0 → 1 quickly at the very start.
	# IDLE: retracted.
	match state:
		State.LANDING, State.LANDED_PAUSE:
			return 1.0
		State.RING_SWEEP:
			return clampf(1.0 - _t / FLAP_RETRACT_DURATION, 0.0, 1.0)
		State.LAUNCHING:
			return clampf(_t / FLAP_EXTEND_DURATION, 0.0, 1.0)
		_:
			return 0.0


func _paint_flaps(canvas: Node2D) -> void:
	if _core_data == null or _flap_tex == null or main == null:
		return
	var flap_t: float = _compute_flap_t()
	if flap_t <= 0.001:
		return
	var gs: float = float(main.GRID_SIZE)
	var core_size: float = gs * float(_core_data.grid_size.x)
	# Anchor flaps to match the core sprite. While the animation is
	# driving the zoom (LANDING/LANDED_PAUSE/LAUNCHING), use the same
	# `(saved/cur) * CORE_ANCHOR_SCALE` the core sprite uses, so the
	# flaps line up with the artistically-shrunk core. During
	# RING_SWEEP the zoom is already back at the player's preference
	# and the placed building draws at its real world size, so use
	# 1.0 there.
	var camera := get_viewport().get_camera_2d()
	var cur_zoom: float = camera.zoom.x if (camera and camera.zoom.x > 0.0) else 1.0
	# Anchor strategy:
	#   - LANDING / LAUNCHING: inverse-zoom compensation keeps the flaps
	#     at a fixed on-screen size matching the artistically-scaled
	#     animation core, easing from CORE_ANCHOR_SCALE → 1.0.
	#   - RING_SWEEP / IDLE: flaps live in world space so they're glued
	#     to the placed building. Player zooming changes their on-screen
	#     size naturally, just like every other block.
	var flap_anchor: float = 1.0
	if state == State.LANDING:
		var land_p: float = clampf(_t / LAND_DURATION, 0.0, 1.0)
		var flap_scale: float = lerpf(CORE_ANCHOR_SCALE, 1.0, ease(land_p, 1.6))
		flap_anchor = (_cam_saved_zoom / maxf(cur_zoom, 0.0001)) * flap_scale
	elif state == State.LAUNCHING:
		var launch_p: float = clampf((_t - LAUNCH_HOLD) / LAUNCH_DURATION, 0.0, 1.0)
		var flap_scale: float = lerpf(1.0, CORE_ANCHOR_SCALE, ease(launch_p, 1.6))
		flap_anchor = (_cam_saved_zoom / maxf(cur_zoom, 0.0001)) * flap_scale
	elif state == State.LANDED_PAUSE:
		# Match the core sprite's ease from natural on-screen size →
		# the placed building's eventual size, so flaps shrink in sync
		# with the core instead of popping at the RING_SWEEP boundary.
		var pause_t: float = clampf(_t / maxf(LANDED_PAUSE, 0.0001), 0.0, 1.0)
		var target_scale: float = cur_zoom / maxf(_cam_saved_zoom, 0.0001)
		var flap_scale: float = lerpf(1.0, target_scale, ease(pause_t, 1.6))
		flap_anchor = (_cam_saved_zoom / maxf(cur_zoom, 0.0001)) * flap_scale
	var flap_w: float = core_size * FLAP_WIDTH_FRACTION * flap_anchor
	var flap_h: float = core_size * FLAP_SIZE_FRACTION * flap_anchor
	var anchored_core_size: float = core_size * flap_anchor
	var max_ext: float = anchored_core_size * 0.5 + flap_h * 0.5
	var ext: float = lerpf(0.0, max_ext, flap_t)
	var sides := [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]
	var rots := [0.0, PI * 0.5, PI, -PI * 0.5]
	var rect := Rect2(-flap_w * 0.5, -flap_h * 0.5, flap_w, flap_h)
	# Match the core sprite's spin so the flaps rotate with it.
	var core_rot: float = 0.0
	if state == State.LANDING:
		var land_p: float = clampf(_t / LAND_DURATION, 0.0, 1.0)
		core_rot = lerpf(-CORE_SPIN_TURNS * TAU, 0.0, ease(land_p, 1.6))
	elif state == State.LAUNCHING:
		var launch_p: float = clampf((_t - LAUNCH_HOLD) / LAUNCH_DURATION, 0.0, 1.0)
		core_rot = lerpf(0.0, CORE_SPIN_TURNS * TAU, ease(launch_p, 1.6))
	# Thruster glow geometry, computed once. Local space matches the
	# flap rect: -Y is outward (texture "up"), so divots near the
	# outward edge live at -flap_h * (0.5 - FLAP_THRUSTER_Y).
	var thrust_i: float = _compute_thruster_intensity()
	var port_y: float = -flap_h * (0.5 - FLAP_THRUSTER_Y)
	var port_dx: float = flap_w * (0.5 - FLAP_THRUSTER_X)
	var port_r: float = flap_h * FLAP_THRUSTER_RADIUS_FRAC
	var pulse: float = 0.5 + 0.5 * sin(_flap_thruster_phase)
	var thrust_alpha: float = thrust_i * (0.6 + 0.3 * pulse)
	for i in range(4):
		var center: Vector2 = _core_world + sides[i].rotated(core_rot) * ext
		canvas.draw_set_transform(center, rots[i] + core_rot, Vector2.ONE)
		canvas.draw_texture_rect(_flap_tex, rect, false, Color(1, 1, 1, 1))
		if thrust_alpha > 0.001:
			var outer := Color(1.0, 0.92, 0.25, thrust_alpha)
			var inner := Color(1.0, 1.0, 1.0, thrust_alpha)
			canvas.draw_circle(Vector2(-port_dx, port_y), port_r, outer)
			canvas.draw_circle(Vector2(-port_dx, port_y), port_r * 0.5, inner)
			canvas.draw_circle(Vector2(port_dx, port_y), port_r, outer)
			canvas.draw_circle(Vector2(port_dx, port_y), port_r * 0.5, inner)
	canvas.draw_set_transform(Vector2.ZERO, 0.0)


func _draw_sky(alpha: float) -> void:
	if alpha <= 0.001:
		return
	var camera := get_viewport().get_camera_2d()
	var cam_center: Vector2 = camera.get_screen_center_position() if camera else _core_world
	var vp_size: Vector2 = get_viewport_rect().size
	var zoom: Vector2 = camera.zoom if (camera and camera.zoom != Vector2.ZERO) else Vector2.ONE
	var half: Vector2 = vp_size / (2.0 * zoom)
	var tl: Vector2 = cam_center - half
	var br: Vector2 = cam_center + half
	# Dim sky background covering the visible world rect.
	draw_rect(Rect2(tl, br - tl), Color(0.05, 0.07, 0.12, alpha), true)
	# Clouds — world-space soft blobs in a ring around the core. They
	# scale with zoom naturally because they're drawn in world coords.
	for c in _clouds:
		var r: float = 140.0 * c["scale"]
		var col: Color = CLOUD_COLOR
		col.a *= alpha
		# Soft circle — three nested for fake glow.
		var pos: Vector2 = c["pos"]
		draw_circle(pos, r, Color(col.r, col.g, col.b, col.a * 0.25))
		draw_circle(pos, r * 0.7, Color(col.r, col.g, col.b, col.a * 0.45))
		draw_circle(pos, r * 0.4, Color(col.r, col.g, col.b, col.a * 0.65))


## Re-stacks the flap overlay's z per animation phase:
##   - LANDING / LAUNCHING / LANDED_PAUSE: 60 (above walls 52, above
##     the placed core 50, but below units / drone).
##   - RING_SWEEP / IDLE / anything else: 49 (below the placed core
##     at 50 so the core sprite naturally hides retracting flaps).
## Called each frame from _process before redrawing the overlay.
func _update_flap_z() -> void:
	if _flap_overlay == null:
		return
	var lifted: bool = state == State.LANDING \
		or state == State.LAUNCHING \
		or state == State.LANDED_PAUSE
	_flap_overlay.z_index = 60 if lifted else 49


func _draw_core(land_p: float, launch_p: float) -> void:
	if _core_data == null:
		return
	# Mirror BuildingSystem's faction-layered render: base sprite + LUMINA
	# overlay (scaled to 0.7 of the base). Fall back to icon / top_sprite
	# if base_sprite is missing.
	var base_tex: Texture2D = _core_data.base_sprite if _core_data.base_sprite else (_core_data.icon if _core_data.icon else _core_data.top_sprite)
	if base_tex == null:
		return
	var overlay_tex: Texture2D = _core_data.lumina_overlay
	var gs: float = float(main.GRID_SIZE)
	var size: float = gs * float(_core_data.grid_size.x)
	# Scale: peak → 1.0 across landing; 1.0 → peak across launching.
	var s: float = 1.0
	var rot: float = 0.0
	if state == State.LANDING:
		s = lerpf(CORE_SCALE_PEAK, 1.0, ease(land_p, 1.6))
		rot = lerpf(-CORE_SPIN_TURNS * TAU, 0.0, ease(land_p, 1.6))
	elif state == State.LAUNCHING:
		s = lerpf(1.0, CORE_SCALE_PEAK, ease(launch_p, 1.6))
		rot = lerpf(0.0, CORE_SPIN_TURNS * TAU, ease(launch_p, 1.6))
	elif state == State.LANDED_PAUSE:
		s = 1.0
	# The core "rides the camera down" — it should stay at a fixed
	# on-screen size matching what it'd look like at the player's
	# saved zoom (its real ground size on screen), NOT scale with the
	# current animation zoom (otherwise the map shrinks the core too
	# and there's nothing to anchor on) and NOT compensate by 1/zoom
	# (which made it cover ~70 % of the screen at extreme zoom-out).
	# Multiplying world size by `saved_zoom / current_zoom` puts the
	# on-screen size at `world_size * saved_zoom` regardless of how
	# zoomed-out the camera currently is.
	var camera := get_viewport().get_camera_2d()
	var cur_zoom: float = camera.zoom.x if (camera and camera.zoom.x > 0.0) else 1.0
	# Anchor scale: starts at CORE_ANCHOR_SCALE (the player-tunable
	# "smaller while falling" factor) and eases toward 1.0 across the
	# descent so by touchdown the animation core matches the placed
	# building's natural size — eliminating the size pop at the
	# LANDED_PAUSE → RING_SWEEP handoff. LAUNCHING reverses it.
	var scale_factor: float = CORE_ANCHOR_SCALE
	if state == State.LANDING:
		scale_factor = lerpf(CORE_ANCHOR_SCALE, 1.0, ease(land_p, 1.6))
	elif state == State.LAUNCHING:
		scale_factor = lerpf(1.0, CORE_ANCHOR_SCALE, ease(launch_p, 1.6))
	elif state == State.LANDED_PAUSE:
		# Across the pause, ease from natural on-screen size (1.0) down
		# to the size the placed building will take over at during
		# RING_SWEEP (= cur_zoom / saved_zoom, i.e. ZOOM_IN_FACTOR after
		# the touchdown snap). Without this ease the core appears to
		# "teleport" shrink at the LANDED_PAUSE → RING_SWEEP boundary.
		var pause_t: float = clampf(_t / maxf(LANDED_PAUSE, 0.0001), 0.0, 1.0)
		var target_scale: float = cur_zoom / maxf(_cam_saved_zoom, 0.0001)
		scale_factor = lerpf(1.0, target_scale, ease(pause_t, 1.6))
	elif state == State.RING_SWEEP:
		# RING_SWEEP: animation core draws on top of the flap overlay so
		# the placed core visually sits on top of retracting flaps.
		# Use a scale that makes the on-screen size equal the placed
		# building's natural world size (i.e. no inverse-zoom comp).
		scale_factor = cur_zoom / maxf(_cam_saved_zoom, 0.0001)
	var anchor_factor: float = (_cam_saved_zoom / maxf(cur_zoom, 0.0001)) * scale_factor
	var draw_size: float = size * s * anchor_factor
	draw_set_transform(_core_world, rot, Vector2.ONE)
	draw_texture_rect(base_tex, Rect2(-draw_size * 0.5, -draw_size * 0.5, draw_size, draw_size), false, Color(1, 1, 1, 1))
	if overlay_tex != null:
		var overlay_size: float = draw_size * 0.7
		draw_texture_rect(overlay_tex, Rect2(-overlay_size * 0.5, -overlay_size * 0.5, overlay_size, overlay_size), false, Color(1, 1, 1, 1))
	draw_set_transform(Vector2.ZERO, 0.0)


func _draw_ring() -> void:
	# Soft expanding annulus. Two arcs of different radii blended for
	# the glow read.
	draw_arc(_core_world, _ring_radius, 0, TAU, 96, RING_COLOR, RING_THICKNESS, true)
	var glow: Color = Color(RING_COLOR.r, RING_COLOR.g, RING_COLOR.b, RING_COLOR.a * 0.35)
	draw_arc(_core_world, _ring_radius - 6.0, 0, TAU, 96, glow, RING_THICKNESS * 2.0, true)
	draw_arc(_core_world, _ring_radius + 6.0, 0, TAU, 96, glow, RING_THICKNESS * 2.0, true)
