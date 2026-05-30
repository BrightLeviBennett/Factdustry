shader_type canvas_item;
// Port of Mindustry's core/assets/shaders/shield.frag.
//
// Behaviour:
//   - Whole pattern WOBBLES — coordinates are sin-warped so the
//     stripes ripple sideways and the rim itself breathes in/out
//     around the perimeter like a wave.
//   - Diagonal stripes drift slowly DOWN-RIGHT (positive x + y
//     direction in Godot's screen-space coords).
//   - Bright white rim where the (wobbled) shape mask is near the
//     edge — replaces Mindustry's offscreen-buffer alpha edge
//     detection. Since we render the shape procedurally, distance
//     to the edge is exact.

uniform vec4 shield_color : source_color = vec4(1.0, 0.88, 0.18, 1.0);
// 0 = circle (UV inscribes a disc), 1 = axis-aligned rect.
uniform int shape_type = 0;
// Pixel dimensions of the SHIELD MASK (the actual hit area). The
// sprite quad is rendered larger than this (`sprite_size_px`) so the
// wobble + rim have room to breathe outward without clipping at
// the quad's edge.
uniform vec2 shield_size_px = vec2(64.0, 64.0);
// Pixel dimensions of the SPRITE QUAD (≥ shield_size_px). UV is 0..1
// across this, so it's what we multiply by to recover pixel coords.
uniform vec2 sprite_size_px = vec2(80.0, 80.0);
// Phase shift per shield so neighbouring shields don't sweep in
// lock-step — set from the cell anchor in shield_system.gd.
uniform float time_offset = 0.0;
// Pausable clock, ticked by ShieldSystem._process and FROZEN when
// the game is paused. We deliberately do NOT use the shader's
// built-in TIME, because TIME keeps advancing during pause and the
// shield would keep wobbling while the rest of the world is stopped.
uniform float anim_time = 0.0;

const float dp = 1.0;
const float ALPHA = 0.36;
const float STRIPE_PERIOD = 16.0;
const float STRIPE_BAND = 4.5;
const float STRIPE_BOOST = 1.7;
// Wobble — a single sin-wave field, but applied at different
// amplitudes to the rim vs. the interior stripes:
//   - the RIM wobbles strongly so the silhouette reads as wavy
//   - the INTERIOR stripes get only a gentle nudge so they don't
//     turn into a chaotic mess.
const float WOBBLE_PERIOD_PX = 32.0; // wavelength → spacing between rim peaks
const float WOBBLE_AMP_RIM_PX = 6.0;
const float WOBBLE_AMP_INTERIOR_PX = 1.0;
// Pattern drift speed along the down-right diagonal. Smaller = slower.
const float DRIFT_SPEED = 0.25;
// Wobble speed — visibly moving but not jittery.
const float WOBBLE_SPEED = 0.5;

void fragment() {
	// UV is 0..1 across the PADDED sprite quad — convert to centred
	// pixel coords. The mask math then clips against shield_size_px
	// (the real shield extent), leaving sprite_size_px - shield_size_px
	// of slack around the rim for the wobble to swing into.
	vec2 centred = UV - vec2(0.5);
	vec2 coords = centred * sprite_size_px;

	float t = anim_time + time_offset;

	// --- 1. Sin-warp wobble field. Wavelength = WOBBLE_PERIOD_PX,
	// so adjacent rim peaks sit ~WOBBLE_PERIOD_PX apart. The same
	// field gets reused for the interior at a much lower amplitude
	// so the stripes don't turn into noise.
	float wf = WOBBLE_PERIOD_PX / TAU;     // sin(x / wf) has period WOBBLE_PERIOD_PX
	vec2 wobble_unit = vec2(
		sin(coords.y / wf + t * WOBBLE_SPEED),
		sin(coords.x / wf + t * WOBBLE_SPEED)
	);
	vec2 w_rim = coords + wobble_unit * WOBBLE_AMP_RIM_PX;
	vec2 w_int = coords + wobble_unit * WOBBLE_AMP_INTERIOR_PX;

	// --- 2. Shape mask from STRONGLY wobbled coords → breathing edge
	// with clearly-spaced peaks.
	float edge_dist;
	if (shape_type == 0) {
		float r = shield_size_px.x * 0.5;
		edge_dist = r - length(w_rim);
	} else {
		vec2 half_size = shield_size_px * 0.5;
		vec2 dxy = half_size - abs(w_rim);
		edge_dist = min(dxy.x, dxy.y);
	}
	float mask = smoothstep(0.0, 1.5, edge_dist);
	if (mask < 0.001) {
		discard;
	}

	// --- 3. Diagonal stripes. The `- t * DRIFT_SPEED` term makes the
	// pattern drift toward LARGER x+y over time, which in Godot's
	// screen-space (y down, x right) reads as a steady down-right
	// flow. Sin terms warp the stripes so they undulate instead of
	// running perfectly straight.
	// Stripe sin-warp scales with STRIPE_PERIOD so the curvature
	// stays proportional as the pattern gets bigger.
	float warp_freq = STRIPE_PERIOD * 0.5;   // wavelength of the warp itself
	float warp_amp  = STRIPE_PERIOD * 0.3;   // depth of the warp
	float stripe_term =
		w_int.x / dp +
		w_int.y / dp +
		sin(w_int.x / dp / warp_freq) * warp_amp +
		sin(w_int.y / dp / warp_freq) * warp_amp
		- t * DRIFT_SPEED * STRIPE_PERIOD;
	bool lit = mod(stripe_term, STRIPE_PERIOD) < STRIPE_BAND;

	vec3 rgb = shield_color.rgb;
	if (lit) {
		rgb *= STRIPE_BOOST;
	}
	float a = ALPHA * mask;

	// --- 4. Bright rim — pixels close to the (wobbled) edge get
	// pushed toward a saturated shield colour (yellow, NOT white)
	// and full alpha. Brightened slightly for visibility against
	// the translucent interior.
	float rim_band = 2.0;
	float rim_strength = smoothstep(rim_band, 0.0, edge_dist);
	if (rim_strength > 0.0) {
		vec3 rim_col = min(shield_color.rgb * 1.4, vec3(1.0));
		rgb = mix(rgb, rim_col, rim_strength);
		a = max(a, rim_strength * 0.95);
	}

	COLOR = vec4(rgb, a);
}
