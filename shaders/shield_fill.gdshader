shader_type canvas_item;
// Mindustry's shield.frag approach, adapted for Godot 4.
//
// All shield fills are drawn by ShieldSystem._draw() as low-alpha solid
// colors (alpha ~0.12) and all rims as high-alpha (~0.60). This shader
// runs once on the entire ShieldSystem node's canvas item — covering the
// MERGED fills and rims produced by the CPU-side scanline algorithm —
// and adds the old v1.5.0 shield visuals back onto the merged surface:
// slow sin-warped diagonal stripes, a stronger translucent fill, and a
// saturated yellow rim.
//
// This matches Mindustry's effectBuffer pass: all shield polys are drawn
// opaque into one buffer, then the shader handles rim-edge detection and
// interior stripe animation. Because the CPU scanline pass already merged
// overlapping shields into one shape, the shader sees only the outer
// boundary — no inner seam lines appear between adjacent shields.

uniform float anim_time = 0.0;
uniform bool animate = true;

varying vec2 canvas_pos;

const float ALPHA = 0.36;
const float STRIPE_PERIOD = 16.0;
const float STRIPE_BAND   = 4.5;
const float STRIPE_BOOST  = 1.65;
const float WOBBLE_PERIOD_PX = 32.0;
const float WOBBLE_AMP_INTERIOR_PX = 1.0;
const float DRIFT_SPEED = 0.25;
const float WOBBLE_SPEED = 0.75;
// Fill alpha threshold: below → fill pixel (add stripes); at or above → rim pixel (pass through)
const float RIM_THRESHOLD = 0.4;

void vertex() {
	canvas_pos = VERTEX;
}

void fragment() {
	// COLOR is inout and starts as texture(TEXTURE, UV) × vertex_color.
	// For ShieldSystem's draw_rect / draw_arc calls the TEXTURE is a
	// solid 1×1 white pixel, so COLOR == the draw-call color (fill or rim).
	if (COLOR.a < 0.001) {
		discard;
	}

	if (COLOR.a < RIM_THRESHOLD) {
		// Interior fill pixel. Use canvas/world coordinates rather than
		// FRAGCOORD so the pattern keeps the same apparent size as the
		// camera zooms in and out.
		COLOR.a = max(COLOR.a, ALPHA);
		if (animate) {
			float wf = WOBBLE_PERIOD_PX / TAU;
			float t = anim_time;
			vec2 wobble_unit = vec2(
				sin(canvas_pos.y / wf + t * WOBBLE_SPEED),
				sin(canvas_pos.x / wf + t * WOBBLE_SPEED)
			);
			vec2 coords = canvas_pos + wobble_unit * WOBBLE_AMP_INTERIOR_PX;
			float warp_freq = STRIPE_PERIOD * 0.5;
			float warp_amp = STRIPE_PERIOD * 0.3;
			float stripe_term =
				coords.x +
				coords.y +
				sin(coords.x / warp_freq) * warp_amp +
				sin(coords.y / warp_freq) * warp_amp -
				t * DRIFT_SPEED * STRIPE_PERIOD;
			float stripe = mod(stripe_term, STRIPE_PERIOD);
			if (stripe < STRIPE_BAND) {
				COLOR.rgb *= STRIPE_BOOST;
			}
		}
	} else {
		// Rim pixels: keep the merged outer boundary, but restore the
		// older saturated yellow rim strength.
		vec3 rim_col = min(COLOR.rgb * 1.4, vec3(1.0));
		COLOR.rgb = rim_col;
		COLOR.a = max(COLOR.a, 0.95);
	}
}
