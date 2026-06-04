shader_type canvas_item;

// ============================================================
// WATER_ANIMATED.GDSHADER
// ============================================================
// Port of Mindustry's core/assets/shaders/water.frag.
//
// Pipeline (each step matches a line of the original .frag):
//   1. Sample the water texture with a sub-pixel HORIZONTAL wobble
//      whose phase varies along world Y → visible row-by-row ripple.
//   2. Tint the sample slightly blue (vec3(0.9, 0.9, 1.0)).
//   3. Build a complex "caustic" tester by summing several sin waves
//      keyed on world position + time, then `mod(tester, 40) < 7`
//      brightens those bands by 1.2× → the bright wandering streaks
//      you see on Mindustry's deep water.
//   4. Alpha: clamp(sampled.a * 100, 1) — any non-zero pixel becomes
//      fully opaque. We multiply by per-vertex depth so the shore
//      gradient + foam from `_build_water_quad_mesh` still works.
//
// Mindustry tiles are 32 px; ours are 128 px (`world_tile_size`). The
// sin frequencies (`coords.x / 5.0` etc.) were tuned at the smaller
// scale, so before feeding world pixels into Mindustry's math we
// divide by `mindustry_pixel_ratio` so a wave that looked like 1 tile
// in Mindustry still looks like ~1 tile here.
// ============================================================

// One texture-tile spans this many world pixels. Set from
// terrain_system.gd to match GRID_SIZE so a single tile of the water
// atlas covers exactly one cell footprint.
uniform float world_tile_size = 128.0;
// Our world is 4× the resolution of Mindustry's (128 vs 32 px per
// tile). Divide world pixel coords by this before plugging them into
// Mindustry's hard-coded wave constants so the caustic pattern reads
// at the same tile-relative scale.
uniform float mindustry_pixel_ratio = 4.0;
// Slight blue tint applied to every sample.
uniform vec3 tint : source_color = vec3(0.9, 0.9, 1.0);
// Caustic stripe params — Mindustry uses `mod(tester, 40) < 7`.
uniform float caustic_mod = 40.0;
uniform float caustic_threshold = 7.0;
uniform float caustic_boost = 1.2;
// Sub-pixel horizontal wobble amplitude. Mindustry uses exactly
// 1 pixel; bump slightly here because our larger tiles can absorb a
// touch more ripple before it looks blurry.
uniform float wobble_amp_px = 1.5;
// Shore foam strength — kept from the previous version. Brightens
// shallow / shore vertices (low vertex COLOR.a) so the band of land
// → water transition reads.
uniform float foam_strength = 0.35;
// Slow down-right drift of the whole pattern, in Mindustry-equivalent
// pixels per second. Both the caustic stripes AND the texture sample
// shift by the same offset so the surface looks like it's gently
// flowing toward the lower-right.
uniform float drift_speed = 1.5;
// Side-to-side wobble of the caustic stripe overlay (the brightened
// "1.2×" band). Mindustry's stripes don't just drift — they also
// breathe / wobble back and forth as the sin-warp terms phase. We
// strengthen that with an explicit lateral oscillation applied to
// the coords fed into the caustic formula.
uniform float overlay_wobble_amp = 4.0;   // Mindustry pixels of swing
uniform float overlay_wobble_speed = 1.4; // oscillations per second × 2π
// Pausable clock, ticked by terrain_system.gd and FROZEN when the
// game is paused. Driven separately from Godot's built-in TIME so
// the water stops animating when the rest of the world stops.
uniform float anim_time = 0.0;

varying vec2 v_world_uv;   // texture UV (one tile per cell)
varying vec2 v_world_px;   // raw world pixel position

void vertex() {
	// VERTEX comes in as world pixel coordinates (see
	// `_build_water_quad_mesh` — corners are anchored at world coords).
	v_world_uv = VERTEX / world_tile_size;
	v_world_px = VERTEX;
}

void fragment() {
	float stime = anim_time / 5.0;
	// `coords` is the Mindustry-equivalent pixel position. We
	// subtract `anim_time * drift_speed` on BOTH axes so the wave
	// pattern (which is computed in these coords) appears to flow
	// toward increasing x + y — i.e. down-right in Godot's screen
	// space — at `drift_speed` Mindustry-pixels per second.
	vec2 drift = vec2(anim_time * drift_speed);
	vec2 coords = v_world_px / mindustry_pixel_ratio - drift;

	// --- 1. Horizontal wobble. Mindustry's `vec2(sin(...) * v.x, 0)`
	// shifts the texture-sample x by ~1 pixel based on world y, so
	// every horizontal row of pixels drifts left/right at a slightly
	// different phase → looks like surface ripple. We also slide the
	// UV by the same `drift` so the sampled texture flows along
	// with the wave pattern.
	float px_in_uv = wobble_amp_px / world_tile_size;
	vec2 drift_uv = drift * mindustry_pixel_ratio / world_tile_size;
	vec2 sample_uv = v_world_uv - drift_uv + vec2(
		sin(stime / 3.0 + coords.y / 0.75) * px_in_uv,
		0.0
	);
	vec4 sampled = texture(TEXTURE, sample_uv);

	// --- 2. Slight blue tint.
	vec3 color = sampled.rgb * tint;

	// --- 3. Caustic stripe test. Port of Mindustry's .frag.
	//
	// The LINEAR base term (`coords.x + coords.y*1.1`) is left UN-
	// wobbled so the overall stripe pattern drifts cleanly down-right
	// with no lateral sway. The lateral wobble is applied ONLY to the
	// coords fed into the sin-warp terms, so each individual stripe
	// ripples / breathes side-to-side without the whole band swaying
	// off-axis. Matches the user spec: pattern goes straight down-
	// right; the white bits jiggle.
	// Use `anim_time` (not Godot's built-in TIME) so this overlay wobble
	// freezes on pause like the rest of the water animation.
	vec2 c_wobble = vec2(
		sin(anim_time * overlay_wobble_speed)            * overlay_wobble_amp,
		cos(anim_time * overlay_wobble_speed * 0.73)     * overlay_wobble_amp * 0.6
	);
	vec2 cc = coords + c_wobble;
	float tester = mod(
		(coords.x + coords.y * 1.1
		 + sin(stime / 8.0 + cc.x / 5.0 - cc.y / 100.0) * 2.0)
		+ sin(stime / 20.0 + cc.y / 3.0) * 1.0
		+ sin(stime / 10.0 - cc.y / 2.0) * 2.0
		+ sin(stime /  7.0 + cc.y / 1.0) * 0.5
		+ sin(cc.x / 3.0 + cc.y / 2.0)
		+ sin(stime / 20.0 + cc.x / 4.0) * 1.0,
		caustic_mod
	);
	if (tester < caustic_threshold) {
		color *= caustic_boost;
	}

	// --- 4. Shore foam (kept from the previous shader). Vertex
	// COLOR.a carries 0=shore, 1=deep so the shore band gets a
	// brightness lift.
	float depth = COLOR.a;
	float shore = clamp(1.0 - depth, 0.0, 1.0);
	color += vec3(foam_strength) * shore * shore;

	// Final alpha = texture_alpha × vertex_depth. Mindustry's
	// `min(sampled.a * 100, 1)` boost is meant for their offscreen
	// water buffer (anti-aliased shore edges where sampled.a < 1);
	// our water texture is uniformly opaque, with the shore fade
	// living entirely in the vertex COLOR.a gradient (0.5 at shore
	// → 1.0 in deep). Applying the `* 100` boost here would force
	// every pixel opaque and erase that gradient — so we just
	// preserve `sampled.a` straight, exactly like the previous
	// shader did.
	COLOR = vec4(color, sampled.a * depth);
}
