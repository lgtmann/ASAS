shader_type canvas_item;

// "Son of the White Mare" (Jankovics) style probe — a living sun-mandala that
// demonstrates the four motion verbs procedurally, at 60fps with zero frames:
//   * radial ornament   — rotating flame-petals + outward-flowing rings
//   * metamorphosis      — the petal count + core radius breathe between forms
//   * colour-field cycle — the folk palette rotates through the bands over time
//   * flowing contour    — hard dark cel line wherever a colour band changes
// `t` is scrub time in 0..1 (looped) so the viewer's scrubber drives it.

uniform float t : hint_range(0.0, 1.0) = 0.0;

// The Fehérlófia folk palette, sampled by band index.
vec3 palette(int i) {
	if (i <= 0) return vec3(0.96, 0.86, 0.55); // cream / gold
	if (i == 1) return vec3(0.91, 0.49, 0.13); // burnt orange
	if (i == 2) return vec3(0.72, 0.12, 0.15); // deep crimson
	if (i == 3) return vec3(0.13, 0.16, 0.42); // indigo
	return vec3(0.08, 0.05, 0.07);             // near-black
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;            // centre to [-1, 1]
	float r = length(p);
	float a = atan(p.y, p.x);
	float time = t * TAU;

	// Metamorphosis: the sun core pulses, and the ornament morphs between a
	// 6-fold and a 12-fold folk form.
	float pulse = 0.30 + 0.08 * sin(time);
	float petals = mix(6.0, 12.0, 0.5 + 0.5 * sin(time * 0.5));

	// Radial ornament field: rotating flame-petals + rings flowing outward.
	float spokes = cos(a * petals + time * 1.5);
	float rings = cos(r * 13.0 - time * 2.0);
	float field = r * 3.0 + spokes * 0.5 + rings * 0.35;

	// Quantise into flat cel bands; rotate the palette over time (colour cycle).
	float bands = 6.0;
	float scaled = field * bands;
	int idx = int(mod(floor(scaled) + floor(t * 5.0), 5.0));
	vec3 col = palette(idx);

	// Radiant sun core.
	float core = smoothstep(pulse, pulse - 0.05, r);
	col = mix(col, palette(0), core);

	// Flowing contour line: dark band boundaries (fixed weight, no derivatives
	// so it's safe on the GL-compatibility renderer).
	float fr = fract(scaled);
	float d = min(fr, 1.0 - fr);
	float contour = 1.0 - smoothstep(0.0, 0.07, d);
	col = mix(col, vec3(0.05, 0.03, 0.05), contour * 0.85);

	// Cream negative-space halo at the rim.
	col = mix(col, vec3(0.96, 0.90, 0.72), smoothstep(0.98, 1.35, r));

	COLOR = vec4(col, 1.0);
}
