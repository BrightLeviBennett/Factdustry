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
const ZOOM_OUT_FACTOR := 0.03         # multiplier on the saved zoom for the start of landing / end of launch
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
# Cloud sprite — replaces the previous nested-circles fake-glow look.
var _cloud_tex: Texture2D = preload("res://textures/terrain/Clouds.png")
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
# Dedicated low-z child for pods that have already touched down on a
# landing pad. Draws at z=50 (block layer) so units render OVER it,
# matching how units walk over other ground blocks. Launch + descent
# pods still draw on the parent LaunchAnimation at z=4090 because
# they're visibly in the air.
var _landed_pod_overlay: Node2D = null

# Lightweight pod-effect list. Each entry:
#   pos:    Vector2  launchpad / landing-pad world center
#   age:    float    seconds since spawn
#   phase:  String   "launching" → scale up + fade out / "landing" → reverse
# Lives outside the main LAND/LAUNCH state machine because the player can
# trigger pod launches at any time and the camera should not be captured.
# Pod-life durations modelled on Mindustry v8:
#   LaunchPayload.lifetime(120f) → 2.0 s at 60 fps.
#   LandingPad.arrivalDuration   = 150f → 2.5 s at 60 fps.
const POD_LIFE := 2.0
const POD_LANDING_LIFE := 2.5
# Vertical travel of the pod sprite during launch/land, in world px.
# v8 uses 100 + small randomized range; we keep it deterministic per pod
# (start_y for landings is computed in play_pod_landing).
const POD_TRAVEL_PX := 100.0
# Pal.engine in Mindustry — a warm cream/yellow used for the glow + tris.
const POD_ENGINE_COLOR := Color(1.0, 0.92, 0.55, 1.0)
# Dust during descent: per-tile spawn chance once landParticleTimer
# accumulates one unit. Matches `Mathf.chance(0.1f)` in v8's
# updateTile() loop.
const POD_LAND_DUST_TILE_CHANCE := 0.10
# Touchdown impact: a one-shot burst on top of the descent dust so the
# floor reads as kicked-up the moment the pod hits.
const POD_LANDING_DUST_COUNT := 28
const POD_LANDING_DUST_RADIUS_PX := 90.0
# How long the post-unload deconstruct sweep takes. Mirrors the
# launchpad's build animation but quick — the pod fully disassembles
# in half a second once the pad has drained, matching the "swept
# away in pieces" read.
const POD_DECONSTRUCT_LIFE := 0.5
var _pods: Array = []
var _pod_tex: Texture2D = preload("res://textures/blocks/assist/LaunchPod.png")

# Sector-info banner shown during RING_SWEEP. CanvasLayer so it draws in
# screen space above every world layer. Built once in `_ready`,
# repopulated each `play_landing` from the active sector's SectorData,
# and faded in/out as the ring sweep starts / ends.
const BANNER_FADE_IN := 0.25
const BANNER_HOLD := 3.0
const BANNER_FADE_OUT := 0.6
var _banner_layer: CanvasLayer = null
var _banner_root: PanelContainer = null
var _banner_name: RichTextLabel = null
var _banner_resources_row: HBoxContainer = null
var _banner_alpha: float = 0.0
var _banner_elapsed: float = 0.0   # seconds since RING_SWEEP first ticked the banner

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
	# Landed-pod underlay. Once a pod touches down on a landing pad it
	# stops being a flying object — it's resting on the pad like any
	# other building. Drawing it at z=50 (same band as placed blocks)
	# instead of the parent LaunchAnimation's z=4090 keeps units (which
	# sit higher in the z-stack) painting on top of the pod sprite,
	# matching how units pass over other ground blocks.
	_landed_pod_overlay = Node2D.new()
	_landed_pod_overlay.name = "LandedPodOverlay"
	_landed_pod_overlay.z_index = 50
	_landed_pod_overlay.z_as_relative = false
	_landed_pod_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_landed_pod_overlay)
	_landed_pod_overlay.draw.connect(_draw_landed_pods_on_overlay)
	_flap_overlay.draw.connect(_paint_flaps.bind(_flap_overlay))
	_build_banner()


func _process(delta: float) -> void:
	# Pod effects tick even when the main state machine is IDLE — the
	# player can trigger pod launches mid-gameplay independent of the
	# core land / launch cinematics.
	if not _pods.is_empty():
		for i in range(_pods.size() - 1, -1, -1):
			var pd: Dictionary = _pods[i]
			pd["age"] += delta
			var phase_pd: String = String(pd.get("phase", ""))
			var life: float = POD_LANDING_LIFE if phase_pd == "landing" else POD_LIFE
			var t: float = clampf(float(pd["age"]) / life, 0.0, 1.0)
			# v8 descent dust — tick `landParticleTimer` and roll the
			# per-tile chance every time it crosses 1.0. Matches
			# `landParticleTimer += pow5Out(fin) * Time.delta / 2`.
			if phase_pd == "landing":
				var lpt: float = float(pd.get("land_particle_timer", 0.0)) \
						+ _pow5_out(t) * delta * 30.0  # Time.delta in v8 = frames; scale to 60 Hz
				if lpt >= 1.0:
					_spawn_pod_land_dust_ring(pd["pos"])
					lpt = 0.0
				pd["land_particle_timer"] = lpt
			# Touchdown impact: at the moment the pod hits (90 % of
			# life), kick the bigger one-shot ring + screen shake.
			if phase_pd == "landing" \
					and not bool(pd.get("dust_kicked", false)) \
					and pd["age"] >= life * 0.9:
				pd["dust_kicked"] = true
				_kick_pod_landing_dust(pd["pos"])
				var fb2 = main.get_node_or_null("FeedbackSystem") if main else null
				if fb2 and fb2.has_method("add_shake"):
					fb2.add_shake(6.0)
			# State machine for landing pods:
			#   "landing"        → descent + touchdown
			#   "landed_idle"    → pod sits at the pad while cargo
			#                      unloads onto belts / pipes. Stays
			#                      indefinitely until the pad's
			#                      block_storage drains to zero.
			#   "deconstructing" → quick build-front sweep right→left,
			#                      then removal.
			# Launches use the old single-phase lifecycle (climb +
			# fade) and expire normally.
			if phase_pd == "landing" and pd["age"] >= life:
				# Hand off to the post-landing pipeline instead of
				# removing. Reset the age timer so phase 2 measures
				# from "moment of touchdown" rather than spawn.
				pd["phase"] = "landed_idle"
				pd["age"] = 0.0
			elif phase_pd == "landed_idle":
				if _pod_target_is_empty(pd):
					pd["phase"] = "deconstructing"
					pd["age"] = 0.0
			elif phase_pd == "deconstructing":
				pd["deconstruct_t"] = clampf(
					pd["age"] / POD_DECONSTRUCT_LIFE, 0.0, 1.0)
				if pd["age"] >= POD_DECONSTRUCT_LIFE:
					_pods.remove_at(i)
					continue
			elif phase_pd == "launching" and pd["age"] >= life:
				_pods.remove_at(i)
		queue_redraw()
		# Re-paint the landed-pod overlay too — its draws live on a
		# separate child canvas at z=50 so units render OVER them.
		if _landed_pod_overlay:
			_landed_pod_overlay.queue_redraw()
	if state == State.IDLE and _dust.is_empty() and _wind_lines.is_empty() and _banner_alpha <= 0.0 and _pods.is_empty():
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
	_tick_banner(delta)
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


## Returns true when the landing pad anchor recorded on this pod has
## fully drained its block_storage — used as the trigger to roll from
## "landed_idle" into "deconstructing". A missing/destroyed anchor or
## a missing LogisticsSystem is treated as "empty" so the pod doesn't
## sit forever in pathological cases.
func _pod_target_is_empty(pod: Dictionary) -> bool:
	if main == null:
		return true
	var anchor: Vector2i = pod.get("target_anchor", Vector2i(-9999, -9999))
	if anchor == Vector2i(-9999, -9999):
		return true
	if not main.placed_buildings.has(anchor):
		return true
	var logistics = main.get_node_or_null("LogisticsSystem")
	if logistics == null or not ("block_storage" in logistics):
		return true
	if not logistics.block_storage.has(anchor):
		return true
	var storage: Dictionary = logistics.block_storage[anchor]
	for k in storage.get("items", {}):
		if int(storage["items"][k]) > 0:
			return false
	for k in storage.get("fluids", {}):
		if float(storage["fluids"][k]) > 0.0:
			return false
	return true


# --- Easing helpers (port of libgdx Interp.* used by Mindustry v8) ---
func _pow5_out(t: float) -> float:
	var u: float = 1.0 - t
	return 1.0 - u * u * u * u * u

func _pow5_in(t: float) -> float:
	return t * t * t * t * t

func _pow4_in(t: float) -> float:
	return t * t * t * t

func _pow3_in(t: float) -> float:
	return t * t * t

func _pow2_in(t: float) -> float:
	return t * t

# Mathf.slope(t) in libgdx ≡ 1 - |2t - 1|, i.e. a tent peaking at 0.5.
func _slope(t: float) -> float:
	return 1.0 - absf(2.0 * t - 1.0)

# Mathf.randomSeedRange(seed, range) returns a deterministic value in
# [-range, range] from a seed. We just use Godot's seeded RNG to mirror
# the contract.
func _seeded_range(seed_v: int, rng: float) -> float:
	var s := RandomNumberGenerator.new()
	s.seed = int(seed_v) * 2654435761  # Knuth multiplicative hash
	return s.randf_range(-rng, rng)


## v8 per-frame descent dust. Mirrors LandingPadBuild.updateTile() which
## does `tile.getLinkedTiles(t -> if Mathf.chance(0.1) podLandDust.at(t,
## angleAway, floorColor))`. We sample the 3×3 cell ring around `center`
## (matching the typical landing-pad footprint) and probabilistically
## spawn a single drifting dust mote per tile, oriented away from the
## pad. Colour comes from the floor under that tile.
func _spawn_pod_land_dust_ring(center: Vector2) -> void:
	if main == null:
		return
	var terrain = main.get_node_or_null("TerrainSystem")
	var gs: float = float(main.GRID_SIZE)
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			if randf() > POD_LAND_DUST_TILE_CHANCE:
				continue
			var tile_world: Vector2 = center + Vector2(float(dx) * gs, float(dy) * gs)
			var cell: Vector2i = main.world_to_grid(tile_world)
			if terrain and terrain.has_method("has_wall") and terrain.has_wall(cell):
				continue
			# Direction the dust shoots away from the pad center, with a
			# small ±30° spread (matches `+ Mathf.range(30f)` in v8).
			var dir_v: Vector2 = (tile_world - center)
			if dir_v.length_squared() < 0.01:
				dir_v = Vector2.from_angle(randf() * TAU)
			else:
				dir_v = dir_v.normalized()
			var spread: float = deg_to_rad(randf_range(-30.0, 30.0))
			dir_v = dir_v.rotated(spread)
			var color: Color = _sample_floor_color(cell, terrain)
			_dust.append({
				"pos": tile_world,
				"color": color,
				"radius": randf_range(DUST_RADIUS_MIN, DUST_RADIUS_MAX) * 0.6,
				"vel": dir_v * DUST_DRIFT_SPEED * randf_range(0.4, 0.9),
				"life": randf_range(0.5, 1.0),
				"age": 0.0,
				"fade_out": true,
				"stop_at": (Time.get_ticks_msec() / 1000.0) + randf_range(0.5, 1.2),
			})


## One-shot dust burst around a pod-landing point. Reuses the same
## `_dust` array (and therefore the same draw + fade-out pipeline) the
## core-landing cinematic uses, so the puffs match the existing
## "Mindustry-style" look. Each particle picks its colour from the
## floor under it, drifts outward, and decays naturally.
func _kick_pod_landing_dust(center: Vector2) -> void:
	if main == null:
		return
	var terrain = main.get_node_or_null("TerrainSystem")
	for _i in range(POD_LANDING_DUST_COUNT):
		var angle: float = randf() * TAU
		var dist: float = randf_range(0.0, POD_LANDING_DUST_RADIUS_PX)
		var world: Vector2 = center + Vector2.from_angle(angle) * dist
		var cell: Vector2i = main.world_to_grid(world)
		if terrain and terrain.has_method("has_wall") and terrain.has_wall(cell):
			continue
		var color: Color = _sample_floor_color(cell, terrain)
		# All puffs drift outward — a still pod-landing dust ring would
		# read as a static stain rather than a kick-up.
		var vel: Vector2 = Vector2.from_angle(angle) * DUST_DRIFT_SPEED * randf_range(0.8, 1.4)
		_dust.append({
			"pos": world,
			"color": color,
			"radius": randf_range(DUST_RADIUS_MIN, DUST_RADIUS_MAX),
			"vel": vel,
			"life": randf_range(0.7, 1.3),
			"age": 0.0,
			# Pre-schedule the fade so these particles disappear on the
			# same window the main landing pipeline uses, instead of
			# lingering after the pod is gone.
			"fade_out": true,
			"stop_at": (Time.get_ticks_msec() / 1000.0) + randf_range(0.8, 1.6),
		})


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
	_populate_banner()
	_banner_alpha = 0.0
	_banner_elapsed = 0.0
	if _banner_root != null:
		_banner_root.modulate.a = 0.0
		_banner_root.visible = false
	state = State.LANDING
	_t = 0.0


## Lightweight pod launch effect for the Launchpad — a "pod" sprite
## scales upward from the launchpad position with a brief thruster glow
## and fades out. The camera is NOT captured (the player keeps driving
## the shardling), and no clouds / wind streaks spawn. The actual cargo
## transfer is handled by LaunchpadSystem before this is called.
func play_pod_launch(launchpad_anchor: Vector2i) -> void:
	if main == null:
		return
	var data = Registry.get_block(main.placed_buildings.get(launchpad_anchor, &""))
	if data == null:
		return
	var gs: float = float(main.GRID_SIZE)
	var world: Vector2 = main.grid_to_world(launchpad_anchor) + Vector2(
		float(data.grid_size.x) * gs * 0.5,
		float(data.grid_size.y) * gs * 0.5)
	# Push a transient pod effect into the in-world pod array. Drawn from
	# `_draw` each frame; entries auto-expire after PROC_POD_LIFE.
	# Match the in-pad pod sprite size (BuildingSystem draws the pod
	# preview at min(w,h) * 0.7 of the launchpad footprint). Without
	# this, the launching pod was always GRID_SIZE * 0.9 and would
	# visibly shrink when it lifted off a 3×3 pad.
	var gs_x: float = float(data.grid_size.x) * gs
	var gs_y: float = float(data.grid_size.y) * gs
	var pod_base: float = minf(gs_x, gs_y) * 0.7
	_pods.append({
		"pos": world,
		"age": 0.0,
		"phase": "launching",   # vs. "landing"
		"seed_id": randi(),
		"base_size": pod_base,
	})
	var fb = main.get_node_or_null("FeedbackSystem")
	if fb and fb.has_method("add_shake"):
		fb.add_shake(4.0)


## Symmetric of play_pod_launch — plays the "pod lands" effect at the
## given world position. The pod descends from above the top of the
## viewport down onto the pad, then kicks up a burst of "core landing"
## dust around the touchdown point. Called from main._ready when a
## queued pod delivery resolves to a pad in this sector.
func play_pod_landing(world_pos: Vector2, pod_base: float = 0.0,
		target_anchor: Vector2i = Vector2i(-9999, -9999)) -> void:
	# Compute the world-space start Y as "just above the top of the
	# camera viewport" so the pod always looks like it falls in from
	# off-screen regardless of the current zoom.
	var start_offset_y: float = -1500.0
	var cam: Camera2D = get_viewport().get_camera_2d() if get_viewport() else null
	if cam:
		var vp_size: Vector2 = get_viewport_rect().size
		var zoom_y: float = cam.zoom.y if cam.zoom.y > 0.0 else 1.0
		var screen_top_y: float = cam.global_position.y - (vp_size.y * 0.5) / zoom_y
		# Land the pod ~120 px above the visible top edge so it's already
		# moving by the time it enters the frame.
		start_offset_y = (screen_top_y - world_pos.y) - 120.0
		if start_offset_y > -400.0:
			start_offset_y = -400.0
	# Caller passes the landing pad's `min(w,h) * 0.7` so the descending
	# pod matches the in-pad preview size; fall back to GRID_SIZE * 0.9
	# only when no size was provided (legacy callers).
	var base_size_v: float = pod_base if pod_base > 0.0 \
			else float(main.GRID_SIZE) * 0.9
	_pods.append({
		"pos": world_pos,
		"age": 0.0,
		"phase": "landing",
		"start_y": start_offset_y,
		"dust_kicked": false,
		"seed_id": randi(),
		"target_anchor": target_anchor,
		# Tracks the deconstruct sweep once unloading completes (0..1).
		"deconstruct_t": 0.0,
		"base_size": base_size_v,
		# v8: `landParticleTimer += pow5Out(fin) * Time.delta / 2`. When
		# it crosses 1.0 we sample each linked tile of the pad footprint
		# at chance 0.1 to spawn a podLandDust puff oriented away from
		# the pad center.
		"land_particle_timer": 0.0,
	})
	var fb = main.get_node_or_null("FeedbackSystem") if main else null
	if fb and fb.has_method("add_shake"):
		fb.add_shake(4.0)


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
	# Only the actual lift / descent locks input — once the camera
	# hits the ground the player can move during the touchdown shake,
	# ring sweep, etc. (Previously the shake-amp gate held input
	# until the screen settled, which felt like a lag spike.)
	match state:
		State.LANDING, State.LAUNCHING:
			return true
		_:
			return false



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


## Exponential interpolation between two positive values. At t=0
## returns `a`, at t=1 returns `b`, and intermediate values follow
## `a * (b/a)^t`. Used for camera zoom so the PERCEIVED motion is
## constant — linear-lerping zoom values feels exponential to the
## eye because visible world area = 1/zoom.
##
## Both `a` and `b` must be positive; the function clamps to a tiny
## floor to avoid log(0) / divide-by-zero.
func _exp_lerp(a: float, b: float, t: float) -> float:
	a = maxf(a, 0.0001)
	b = maxf(b, 0.0001)
	return a * pow(b / a, clampf(t, 0.0, 1.0))


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
		#
		# Linear-interpolating zoom values made the descent feel
		# "fast at start, slow at end" because visible world area =
		# 1/zoom, so small zoom changes near zoom=ZOOM_OUT looked
		# huge on screen while equal changes near ZOOM_IN looked
		# tiny. Exponential interpolation gives CONSTANT perceived
		# motion: `z = a * (b/a)^t` makes `log(z)` linear, which
		# matches the way the eye reads camera distance.
		z = _exp_lerp(ZOOM_OUT_FACTOR, ZOOM_IN_FACTOR, t)
		# Keep the camera glued to the core the entire descent + hover
		# so it doesn't "snap" toward the drone as we touch down.
		follow = true
	elif state == State.LAUNCHING:
		# Hold the camera still for LAUNCH_HOLD seconds so the flaps can
		# extend and the thrusters can light up before any lift-off motion.
		t = clampf((_t - LAUNCH_HOLD) / LAUNCH_DURATION, 0.0, 1.0)
		# Launch endpoints are also literal — independent of whatever
		# zoom the player happened to leave the camera at. Same
		# exponential curve as landing so the perceived motion stays
		# constant regardless of how extreme ZOOM_OUT_FACTOR is.
		z = _exp_lerp(ZOOM_IN_FACTOR, ZOOM_OUT_FACTOR, t)
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
	# Tile the Clouds.png texture 10 times around the core in a 5×2
	# grid so the cloud cover reads as a continuous layer instead of
	# a single big sprite. Each tile keeps the previous `size_px`
	# (12000) so the total covered area is 5*12000 wide × 2*12000
	# tall — plenty to fill the visible viewport at the zoomed-out
	# end of the launch animation. Each tile drifts on its own
	# slow velocity so the layer feels alive instead of stamped.
	_clouds.clear()
	const TILE_SIZE_PX := 6000.0
	const COLS := 7
	const ROWS := 7
	var origin: Vector2 = _core_world \
			- Vector2(TILE_SIZE_PX * (COLS - 1) * 0.5,
				TILE_SIZE_PX * (ROWS - 1) * 0.5)
	for row in range(ROWS):
		for col in range(COLS):
			var pos: Vector2 = origin + Vector2(
				col * TILE_SIZE_PX,
				row * TILE_SIZE_PX)
			_clouds.append({
				"pos": pos,
				"vel": Vector2(randf_range(-12.0, 12.0), randf_range(-6.0, 6.0)),
				"size_px": TILE_SIZE_PX,
				# Back-compat field — meaningless for textured clouds;
				# `_draw_sky` uses `size_px` when present.
				"scale": 1.0,
			})


# ----- Render -----

## Paints every active pod. Drawn here (not on the underlay) so the pod
## appears above world buildings while it ascends / descends.
func _draw_pods() -> void:
	# Faithful port of Mindustry v8's LaunchPayload.draw() and
	# LandingPadBuild.draw() — same interpolation curves, same engine
	# glow, same 4 rotating triangles, same shadow drift along 225°.
	# Values like the 100 px Y travel, 130/90° rotation max, 250 px
	# shadow offset, and 12 px x-jitter are copied straight from the
	# Java source (see launchpad/LaunchPad.java + LandingPad.java).
	for pod in _pods:
		var phase: String = String(pod.get("phase", "launching"))
		# Post-touchdown phases are painted on `_landed_pod_overlay`
		# (z=50, block layer) instead of this canvas (z=4090) so units
		# walking past the pad render OVER the pod. The overlay is
		# kicked to redraw below; here we just skip the in-line draw.
		if phase == "landed_idle" or phase == "deconstructing":
			continue
		var life_t: float = POD_LANDING_LIFE if phase == "landing" else POD_LIFE
		var raw_t: float = clampf(float(pod["age"]) / life_t, 0.0, 1.0)
		# v8 uses two factors that are SYMMETRIC between launch and land:
		#   launch:  fin = age/life      → climbs, alpha=pow5Out(fout)
		#   land:    fin = arrivingTimer → descends, alpha=pow5Out(fin)
		# Mapping into one variable below: `fin` is "fraction toward
		# touchdown" for landings, "fraction toward sky" for launches.
		var fin_v: float = raw_t
		var fout_v: float = 1.0 - fin_v
		# Per-pod seeded jitter so two simultaneous pods don't move in
		# lockstep. Stored at spawn time as a small int (`seed_id`).
		var sid: int = int(pod.get("seed_id", 0))
		var x_range: float = _seeded_range(sid + 3, 4.0)
		var y_range: float = _seeded_range(sid + 2, 30.0)
		var rot_range: float = _seeded_range(sid, 50.0)
		var base_size: float = float(pod.get("base_size", float(main.GRID_SIZE) * 0.9))
		var alpha: float
		var scale: float
		var cx_off: float
		var cy_off: float
		var rotation: float
		var shadow_off_t: float   # 0..1 along the 225° vector
		if phase == "launching":
			# fout in v8 is `1 - fin`; alpha = pow5Out(fout).
			alpha = _pow5_out(fout_v)
			scale = (1.0 - alpha) * 1.3 + 1.0
			cx_off = _pow2_in(fin_v) * (12.0 + x_range)
			cy_off = -_pow5_in(fin_v) * (POD_TRAVEL_PX + y_range)  # negative = up
			rotation = fin_v * (130.0 + rot_range)
			shadow_off_t = _pow3_in(fin_v)
		else:
			alpha = _pow5_out(fin_v)
			scale = (1.0 - alpha) * 1.3 + 1.0
			cx_off = 0.0
			# v8: `cy = y + pow4In(fout) * 100`. Their Y is up, so the
			# pod starts above the pad at fout=1 and touches down at
			# fout=0. In Godot Y is down → negate to keep "above pad".
			cy_off = -_pow4_in(fout_v) * (POD_TRAVEL_PX + y_range)
			rotation = fout_v * (90.0 + rot_range)
			shadow_off_t = _pow3_in(fout_v)
		var size: float = base_size * scale
		var center: Vector2 = pod["pos"] + Vector2(cx_off, cy_off)
		# --- v8 shadow: drifts down-left by pow3In(t)*250 ---
		# v8 uses 225° in libgdx (Y-up) which is visually down-left. In
		# Godot's Y-down system the same visual direction is 135°.
		# Shadow paints UNDER the sprite at low alpha.
		var shadow_vec: Vector2 = Vector2.from_angle(deg_to_rad(135.0)) \
				* (shadow_off_t * 250.0)
		var shadow_color := Color(0.0, 0.0, 0.0, 0.22 * alpha)
		if _pod_tex:
			var srect := Rect2(center + shadow_vec - Vector2(size * 0.5, size * 0.5),
				Vector2(size, size))
			# Rotated draw via a transform — Godot has no rotation arg on
			# draw_texture_rect, so set a transform around the shadow's
			# center, draw, then reset.
			draw_set_transform(center + shadow_vec, deg_to_rad(rotation), Vector2.ONE)
			draw_texture_rect(_pod_tex,
				Rect2(-Vector2(size * 0.5, size * 0.5), Vector2(size, size)),
				false, shadow_color)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		# --- Engine glow + 4 rotating triangles ---
		# v8: `Fill.light(cx,cy,10, 25*(rad+scale-1), engine alpha→transparent)`
		# Approximated with a radial circle of decreasing alpha + a hard
		# inner disc — radius scales with `rad + scale-1` like the source.
		var rad: float = 0.2 + _pow5_out(_slope(fin_v))
		var glow_r: float = 25.0 * (rad + scale - 1.0)
		if glow_r > 0.0:
			var glow_color := POD_ENGINE_COLOR
			glow_color.a *= alpha
			draw_circle(center, glow_r, glow_color)
		# Four equally-spaced triangles, rotating with the pod. v8 uses
		# `Drawf.tri(cx,cy,6, 40*(rad+scale-1), i*90 + rot)` which paints
		# a long thin tri pointing outward from center.
		var tri_len: float = 40.0 * (rad + scale - 1.0)
		var tri_w: float = 6.0
		if tri_len > 0.0:
			for i in range(4):
				var ang_deg: float = float(i) * 90.0 + rotation
				var ang: float = deg_to_rad(ang_deg)
				var dir_v: Vector2 = Vector2.from_angle(ang)
				var perp: Vector2 = Vector2(-dir_v.y, dir_v.x)
				var tip: Vector2 = center + dir_v * tri_len
				var l: Vector2 = center + perp * (tri_w * 0.5)
				var r: Vector2 = center - perp * (tri_w * 0.5)
				draw_colored_polygon(
					PackedVector2Array([tip, l, r]),
					Color(POD_ENGINE_COLOR.r, POD_ENGINE_COLOR.g,
						POD_ENGINE_COLOR.b, alpha))
		# --- Pod sprite ---
		if _pod_tex:
			draw_set_transform(center, deg_to_rad(rotation), Vector2.ONE)
			draw_texture_rect(_pod_tex,
				Rect2(-Vector2(size * 0.5, size * 0.5), Vector2(size, size)),
				false, Color(1.0, 1.0, 1.0, alpha))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		else:
			# Visible fallback when the pod texture is missing.
			draw_rect(Rect2(center - Vector2(size * 0.35, size * 0.5),
				Vector2(size * 0.7, size)),
				Color(1.0, 0.85, 0.2, alpha), true)


## Drawn each frame on `_landed_pod_overlay`. Iterates `_pods` and
## renders only the post-touchdown phases — launch / descent pods
## stay on the parent canvas at z=4090. Walking units (default z) end
## up painting on top of these pads, which is what the player wants
## visually.
func _draw_landed_pods_on_overlay() -> void:
	if _landed_pod_overlay == null:
		return
	for pod in _pods:
		var phase: String = String(pod.get("phase", "launching"))
		if phase != "landed_idle" and phase != "deconstructing":
			continue
		_draw_landed_pod_on(_landed_pod_overlay, pod, phase)


## Static render for landed pods. While "landed_idle" the pod sits
## at the pad at full size, no rotation, no engine glow. While
## "deconstructing" the build-front line sweeps right→left and only
## the not-yet-deconstructed portion of the source texture is drawn —
## mirroring BuildingSystem._draw_launchpad_pod_previews but in reverse.
func _draw_landed_pod_on(canvas: CanvasItem, pod: Dictionary, phase: String) -> void:
	if _pod_tex == null or canvas == null:
		return
	var center: Vector2 = pod["pos"]
	var base_size: float = float(pod.get("base_size", float(main.GRID_SIZE) * 0.9))
	var rect := Rect2(center - Vector2(base_size * 0.5, base_size * 0.5),
		Vector2(base_size, base_size))
	if phase == "landed_idle":
		canvas.draw_texture_rect(_pod_tex, rect, false, Color(1.0, 1.0, 1.0, 1.0))
		return
	# Deconstructing: 0 → 1 sweeps the build-front from right to left.
	# `kept` is the LEFT fraction of the source still visible.
	var t: float = clampf(float(pod.get("deconstruct_t", 0.0)), 0.0, 1.0)
	var kept: float = 1.0 - t
	if kept <= 0.0:
		return
	var src_w: float = _pod_tex.get_width() * kept
	var src_rect := Rect2(0.0, 0.0, src_w, _pod_tex.get_height())
	var dst_rect := Rect2(rect.position,
		Vector2(rect.size.x * kept, rect.size.y))
	canvas.draw_texture_rect_region(_pod_tex, dst_rect, src_rect,
		Color(1.0, 1.0, 1.0, 1.0))
	# Yellow build-front line at the construction edge — same colour
	# the launchpad uses while building so the visual reads as the
	# inverse of construction.
	var line_x: float = rect.position.x + rect.size.x * kept
	canvas.draw_line(
		Vector2(line_x, rect.position.y),
		Vector2(line_x, rect.position.y + rect.size.y),
		Color(1.0, 0.9, 0.2, 0.9), 2.0)


func _draw() -> void:
	# Pod effects render every frame regardless of land/launch state.
	if not _pods.is_empty():
		_draw_pods()
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
	# Anchor every animation-phase scale against the literal
	# ZOOM_IN_FACTOR (the landing-end / launch-start camera zoom),
	# NOT the player's saved zoom. This keeps the on-screen size of
	# the flaps + core sprite fixed across animations regardless of
	# whatever zoom the player was at when the sector loaded.
	var flap_anchor: float = 1.0
	if state == State.LANDING:
		var land_p: float = clampf(_t / LAND_DURATION, 0.0, 1.0)
		var flap_scale: float = lerpf(CORE_ANCHOR_SCALE, 1.0, ease(land_p, 1.6))
		flap_anchor = (ZOOM_IN_FACTOR / maxf(cur_zoom, 0.0001)) * flap_scale
	elif state == State.LAUNCHING:
		var launch_p: float = clampf((_t - LAUNCH_HOLD) / LAUNCH_DURATION, 0.0, 1.0)
		var flap_scale: float = lerpf(1.0, CORE_ANCHOR_SCALE, ease(launch_p, 1.6))
		flap_anchor = (ZOOM_IN_FACTOR / maxf(cur_zoom, 0.0001)) * flap_scale
	elif state == State.LANDED_PAUSE:
		# Match the core sprite's ease from natural on-screen size →
		# the placed building's eventual size, so flaps shrink in sync
		# with the core instead of popping at the RING_SWEEP boundary.
		var pause_t: float = clampf(_t / maxf(LANDED_PAUSE, 0.0001), 0.0, 1.0)
		var target_scale: float = cur_zoom / maxf(ZOOM_IN_FACTOR, 0.0001)
		var flap_scale: float = lerpf(1.0, target_scale, ease(pause_t, 1.6))
		flap_anchor = (ZOOM_IN_FACTOR / maxf(cur_zoom, 0.0001)) * flap_scale
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
	# Clouds — world-space sprite(s) drawn from Clouds.png.
	for c in _clouds:
		var col: Color = CLOUD_COLOR
		col.a *= alpha
		var pos: Vector2 = c["pos"]
		if c.has("size_px") and _cloud_tex != null:
			var sz_px: float = float(c["size_px"])
			var sz: Vector2 = Vector2(sz_px, sz_px)
			var rect := Rect2(pos - sz * 0.5, sz)
			draw_texture_rect(_cloud_tex, rect, false, col)
		else:
			var r: float = 140.0 * float(c.get("scale", 1.0))
			if _cloud_tex != null:
				var sz2: Vector2 = Vector2(r * 2.0, r * 2.0)
				var rect2 := Rect2(pos - sz2 * 0.5, sz2)
				draw_texture_rect(_cloud_tex, rect2, false, col)
			else:
				draw_circle(pos, r, Color(col.r, col.g, col.b, col.a * 0.25))
				draw_circle(pos, r * 0.7, Color(col.r, col.g, col.b, col.a * 0.45))
				draw_circle(pos, r * 0.4, Color(col.r, col.g, col.b, col.a * 0.65))


## Re-stacks the flap overlay's z per animation phase:
##   - LANDING / LAUNCHING / LANDED_PAUSE: 4091 — ABOVE the cloud
##     overlay (z=4090) so the flaps extend through the cloud layer,
##     and still below the drone (z=4095).
##   - RING_SWEEP / IDLE / anything else: 49 (below the placed core
##     at 50 so the core sprite naturally hides retracting flaps).
## Called each frame from _process before redrawing the overlay.
func _update_flap_z() -> void:
	if _flap_overlay == null:
		return
	var lifted: bool = state == State.LANDING \
		or state == State.LAUNCHING \
		or state == State.LANDED_PAUSE
	# Lifted z = 4091, ABOVE the cloud overlay (z=4090) but still below
	# the drone (4095). Non-lifted = 49 so the placed core (z=50)
	# hides retracting flaps.
	_flap_overlay.z_index = 4091 if lifted else 49


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
		var target_scale: float = cur_zoom / maxf(ZOOM_IN_FACTOR, 0.0001)
		scale_factor = lerpf(1.0, target_scale, ease(pause_t, 1.6))
	elif state == State.RING_SWEEP:
		# RING_SWEEP: animation core draws on top of the flap overlay so
		# the placed core visually sits on top of retracting flaps.
		# Use a scale that makes the on-screen size equal the placed
		# building's natural world size (i.e. no inverse-zoom comp).
		scale_factor = cur_zoom / maxf(ZOOM_IN_FACTOR, 0.0001)
	# Use the literal ZOOM_IN_FACTOR as the size anchor so the
	# animation core renders at the same on-screen size regardless of
	# the player's saved zoom (which only kicks in after _restore_camera).
	var anchor_factor: float = (ZOOM_IN_FACTOR / maxf(cur_zoom, 0.0001)) * scale_factor
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


# ----- Sector-info banner -----

func _build_banner() -> void:
	_banner_layer = CanvasLayer.new()
	_banner_layer.layer = 100
	_banner_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_banner_layer)

	var anchor: Control = Control.new()
	anchor.anchor_left = 0.0
	anchor.anchor_right = 1.0
	anchor.anchor_top = 0.0
	anchor.anchor_bottom = 1.0
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner_layer.add_child(anchor)

	var center := CenterContainer.new()
	center.anchor_left = 0.0
	center.anchor_right = 1.0
	center.anchor_top = 0.0
	center.anchor_bottom = 1.0
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor.add_child(center)

	_banner_root = PanelContainer.new()
	_banner_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.11, 0.7)
	sb.border_color = Color(1.0, 0.85, 0.2, 0.55)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	_banner_root.add_theme_stylebox_override("panel", sb)
	_banner_root.visible = false
	_banner_root.modulate = Color(1, 1, 1, 0)
	center.add_child(_banner_root)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner_root.add_child(vbox)

	_banner_name = RichTextLabel.new()
	_banner_name.bbcode_enabled = true
	_banner_name.fit_content = true
	_banner_name.scroll_active = false
	_banner_name.autowrap_mode = TextServer.AUTOWRAP_OFF
	_banner_name.add_theme_font_size_override("normal_font_size", 22)
	_banner_name.add_theme_font_size_override("bold_font_size", 22)
	_banner_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_banner_name)

	var bottom_row := HBoxContainer.new()
	bottom_row.add_theme_constant_override("separation", 6)
	bottom_row.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(bottom_row)

	var res_label := Label.new()
	res_label.text = "Resources:"
	res_label.add_theme_font_size_override("font_size", 14)
	res_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	bottom_row.add_child(res_label)

	_banner_resources_row = HBoxContainer.new()
	_banner_resources_row.add_theme_constant_override("separation", 4)
	_banner_resources_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom_row.add_child(_banner_resources_row)


func _populate_banner() -> void:
	if _banner_root == null:
		return
	var sid: StringName = SaveManager.active_sector_id if "active_sector_id" in SaveManager else &""
	var sector: SectorData = Registry.get_sector(sid) if sid != &"" else null
	var display: String = sector.display_name if sector and sector.display_name != "" else String(sid).replace("_", " ").capitalize()
	if display == "":
		display = "Unknown Sector"
	_banner_name.text = "[center][color=#ffffff][[/color][color=#ffd633]%s[/color][color=#ffffff]][/color][/center]" % display
	for c in _banner_resources_row.get_children():
		c.queue_free()
	var resources: PackedStringArray = sector.available_resources if sector else PackedStringArray()
	for item_id in resources:
		var item = Registry.get_item_or_fluid(StringName(item_id))
		var icon_rect := TextureRect.new()
		icon_rect.custom_minimum_size = Vector2(20, 20)
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		if item and item.icon:
			icon_rect.texture = item.icon
		icon_rect.tooltip_text = item.display_name if item else String(item_id)
		icon_rect.mouse_filter = Control.MOUSE_FILTER_PASS
		_banner_resources_row.add_child(icon_rect)


func _tick_banner(delta: float) -> void:
	if _banner_root == null:
		return
	# Banner kicks in at RING_SWEEP start: fade in over BANNER_FADE_IN,
	# hold fully visible for BANNER_HOLD seconds (3 s), then fade out
	# over BANNER_FADE_OUT. The hold is fixed and independent of how
	# long the actual ring sweep takes — by the time the animation
	# finishes the banner is either still mid-fade or already gone.
	if state == State.RING_SWEEP:
		_banner_elapsed += delta
	else:
		_banner_elapsed = 0.0
	var want_visible: bool = state == State.RING_SWEEP \
		and _banner_elapsed < BANNER_FADE_IN + BANNER_HOLD
	var target: float = 1.0 if want_visible else 0.0
	var rate: float = (1.0 / BANNER_FADE_IN) if want_visible else (1.0 / BANNER_FADE_OUT)
	_banner_alpha = move_toward(_banner_alpha, target, rate * delta)
	_banner_root.modulate.a = _banner_alpha
	_banner_root.visible = _banner_alpha > 0.001
