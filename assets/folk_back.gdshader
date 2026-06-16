shader_type canvas_item;

// Living psychedelic card-back in the folk palette — a slow spiral of cel
// bands with a flowing colour cycle and a central emblem. Self-animating via
// the built-in TIME, so it can be dropped on any Control (draw pile, card
// reverse, menus) with no script feeding it. Keep palette in sync with
// FolkFX.PALETTE.

vec3 palette(int i) {
	if (i <= 0) return vec3(0.96, 0.86, 0.55); // cream / gold
	if (i == 1) return vec3(0.91, 0.49, 0.13); // burnt orange
	if (i == 2) return vec3(0.72, 0.12, 0.15); // deep crimson
	if (i == 3) return vec3(0.13, 0.16, 0.46); // indigo
	return vec3(0.05, 0.04, 0.08);             // near-black
}

void fragment() {
	vec2 p = UV - 0.5;
	float r = length(p);
	float a = atan(p.y, p.x);
	float t = TIME * 0.45;

	// Spiral + rings flowing outward, morphing arm count over time.
	float arms = mix(3.0, 6.0, 0.5 + 0.5 * sin(t * 0.5));
	float spiral = sin(a * arms + r * 26.0 - t * 3.0);
	float rings = sin(r * 30.0 - t * 2.0);
	float field = r * 4.0 + spiral * 0.5 + rings * 0.4;

	float bands = 5.0;
	float scaled = field * bands;
	int idx = int(mod(floor(scaled) + floor(t * 2.0), 5.0));
	vec3 col = palette(idx);

	// Flat dark contour lines between bands (no derivatives — GL-compat safe).
	float fr = fract(scaled);
	float d = min(fr, 1.0 - fr);
	col = mix(col, vec3(0.05, 0.03, 0.05), 1.0 - smoothstep(0.0, 0.08, d));

	// Central sun emblem.
	float emblem = smoothstep(0.16, 0.13, r);
	col = mix(col, palette(0), emblem);
	float pip = smoothstep(0.05, 0.03, r);
	col = mix(col, palette(2), pip);

	// Dark vignette frame so it reads as a card.
	col *= 1.0 - smoothstep(0.40, 0.62, r) * 0.6;

	COLOR = vec4(col, 1.0);
}
