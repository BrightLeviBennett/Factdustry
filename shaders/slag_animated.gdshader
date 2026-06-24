shader_type canvas_item;

// ============================================================
// SLAG_ANIMATED.GDSHADER
// ============================================================
// Mindustry-style lava/slag. Same technique as water_animated.gdshader
// (a port of Mindustry's caustic water.frag) but recoloured: the orange
// Slag texture flows + wobbles underneath, and the caustic bands brighten
// into pale MOLTEN BLOBS instead of blue-white water streaks. Two caustic
// scales (one tight, one big + slow) overlap so the highlights read as a
// mix of streaks and patches, like Mindustry's slag.
//
// Mindustry tiles are 32 px; ours are 128 px (`world_tile_size`). The sin
// frequencies were tuned at the smaller scale, so world pixels are divided
// by `mindustry_pixel_ratio` before feeding Mindustry's wave constants.
//
// `anim_time` is the pausable clock ticked by terrain_system.gd (shared with
// water), so slag freezes with the rest of the world on pause.
// ============================================================

uniform float world_tile_size = 128.0;
uniform float mindustry_pixel_ratio = 4.0;
uniform float anim_time = 0.0;

// Slight warm lift on the sampled lava texture so it glows a touch.
uniform vec3 tint : source_color = vec3(1.06, 0.98, 0.85);
// Pale molten highlight the caustic blobs brighten toward.
uniform vec3 blob_color : source_color = vec3(1.0, 0.82, 0.42);
// How strongly a blob overrides the base, and how soft its edge is
// (band half-width in Mindustry px; bigger = wider, softer blobs).
uniform float blob_strength = 0.62;
uniform float blob_softness = 6.0;
uniform float caustic_mod = 40.0;
// Sub-pixel horizontal ripple of the texture sample.
uniform float wobble_amp_px = 1.5;
// Lava is viscous — drift much slower than water (which uses 1.5).
uniform float drift_speed = 0.55;
// Side-to-side breathing of the caustic overlay.
uniform float overlay_wobble_amp = 4.0;
uniform float overlay_wobble_speed = 1.0;
// Gentle global brightness pulse so the whole surface "breathes".
uniform float pulse_amp = 0.05;
uniform float pulse_speed = 0.9;

varying vec2 v_world_uv;   // world-continuous texture UV (one tile per cell)
varying vec2 v_world_px;   // raw world pixel position

void vertex() {
	// VERTEX is world pixel coords (see _build_flat_quad_mesh). Using world
	// coords for the UV makes the lava texture + caustics continuous across
	// cells instead of resetting per tile.
	v_world_uv = VERTEX / world_tile_size;
	v_world_px = VERTEX;
}

// Mindustry's caustic tester, parameterised so we can run it at two scales.
float caustic_tester(vec2 coords, vec2 cc, float stime) {
	return mod(
		(coords.x + coords.y * 1.1
		 + sin(stime / 8.0 + cc.x / 5.0 - cc.y / 100.0) * 2.0)
		+ sin(stime / 20.0 + cc.y / 3.0) * 1.0
		+ sin(stime / 10.0 - cc.y / 2.0) * 2.0
		+ sin(stime /  7.0 + cc.y / 1.0) * 0.5
		+ sin(cc.x / 3.0 + cc.y / 2.0)
		+ sin(stime / 20.0 + cc.x / 4.0) * 1.0,
		caustic_mod
	);
}

// Soft "molten blob" mask: distance to the nearest band centre → smooth
// falloff. 1.0 at the band centre, 0.0 once `softness` px away.
float blob_mask(float tester, float softness) {
	float band = min(tester, caustic_mod - tester);
	return 1.0 - smoothstep(0.0, softness, band);
}

void fragment() {
	float a = COLOR.a;                       // per-tile opacity from the mesh
	float stime = anim_time / 5.0;
	vec2 drift = vec2(anim_time * drift_speed);
	vec2 coords = v_world_px / mindustry_pixel_ratio - drift;

	// --- 1. Sample the slag texture with the water-style wobble + drift.
	float px_in_uv = wobble_amp_px / world_tile_size;
	vec2 drift_uv = drift * mindustry_pixel_ratio / world_tile_size;
	vec2 sample_uv = v_world_uv - drift_uv + vec2(
		sin(stime / 3.0 + coords.y / 0.75) * px_in_uv,
		0.0
	);
	vec3 color = texture(TEXTURE, sample_uv).rgb * tint;

	// Shared lateral wobble so the caustic overlay breathes side to side.
	vec2 c_wobble = vec2(
		sin(anim_time * overlay_wobble_speed)        * overlay_wobble_amp,
		cos(anim_time * overlay_wobble_speed * 0.73) * overlay_wobble_amp * 0.6
	);

	// --- 2. Tight caustic → small bright molten streaks/blobs.
	vec2 cc = coords + c_wobble;
	float t1 = caustic_tester(coords, cc, stime);
	float blob1 = blob_mask(t1, blob_softness);
	color = mix(color, blob_color, blob1 * blob_strength);

	// --- 3. Big, slow caustic → large lazy molten patches. Different scale
	// + speed so it crosses the tight bands and breaks them into patches.
	vec2 coords2 = coords * 0.45;
	vec2 cc2 = coords2 + c_wobble * 0.5;
	float t2 = caustic_tester(coords2, cc2, stime * 0.55);
	float blob2 = blob_mask(t2, blob_softness * 1.7);
	color = mix(color, blob_color, blob2 * blob_strength * 0.5);

	// --- 4. Gentle global breathing pulse.
	color *= 1.0 - pulse_amp + pulse_amp * sin(anim_time * pulse_speed + v_world_px.x * 0.002);

	COLOR = vec4(color, a);
}
