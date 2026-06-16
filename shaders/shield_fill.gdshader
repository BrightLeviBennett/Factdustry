shader_type canvas_item;
// Mindustry's shield.frag approach, adapted for Godot 4.
//
// All shield fills are drawn by ShieldSystem._draw() as low-alpha solid
// colors (alpha ~0.12) and all rims as high-alpha (~0.60). This shader
// runs once on the entire ShieldSystem node's canvas item — covering the
// MERGED fills and rims produced by the CPU-side scanline algorithm —
// and adds Mindustry's animated diagonal stripe pattern to interior fill
// pixels while leaving rim pixels untouched.
//
// This matches Mindustry's effectBuffer pass: all shield polys are drawn
// opaque into one buffer, then the shader handles rim-edge detection and
// interior stripe animation. Because the CPU scanline pass already merged
// overlapping shields into one shape, the shader sees only the outer
// boundary — no inner seam lines appear between adjacent shields.

uniform float anim_time = 0.0;
uniform bool animate = true;

// Stripe constants (tuned to match Mindustry's shield.frag feel)
const float STRIPE_PERIOD = 10.0;
const float STRIPE_BAND   = 2.0;
const float STRIPE_BOOST  = 1.65;
// Pixels per second the stripe pattern drifts along x+y (down-right)
const float DRIFT_SPEED   = 40.0;
// Fill alpha threshold: below → fill pixel (add stripes); at or above → rim pixel (pass through)
const float RIM_THRESHOLD = 0.4;

void fragment() {
	// COLOR is inout and starts as texture(TEXTURE, UV) × vertex_color.
	// For ShieldSystem's draw_rect / draw_arc calls the TEXTURE is a
	// solid 1×1 white pixel, so COLOR == the draw-call color (fill or rim).
	if (COLOR.a < 0.001) {
		discard;
	}

	if (animate && COLOR.a < RIM_THRESHOLD) {
		// Interior fill pixel.  Use FRAGCOORD (screen pixels) for a
		// world-stable stripe pattern — the same world pixel always maps
		// to the same stripe phase, so the pattern doesn't slide when the
		// camera pans.  anim_time drifts the stripes down-right over time.
		float stripe = mod(FRAGCOORD.x + FRAGCOORD.y + anim_time * DRIFT_SPEED, STRIPE_PERIOD);
		if (stripe < STRIPE_BAND) {
			COLOR.rgb *= STRIPE_BOOST;
		}
	}
	// Rim pixels (high alpha): pass through unchanged.
	// The pulsing alpha is already baked into their draw color by _draw().
}
