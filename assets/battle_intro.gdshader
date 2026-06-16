shader_type canvas_item;

// Battle-intro flourish, fully procedural — Son-of-the-White-Mare poster look:
// jagged blue shard curtains crawl in from the four edges over a grainy black
// field strewn with twinkling stars, a glowing folk sun-emblem blooms at the
// centre, and the leading shard edges glow. `progress` (0..1) is the cover
// amount, driven by the BattleIntro script (slam → hold → withdraw); COLOR.a
// is the cover so the withdrawal reveals the map beneath. TIME drives grain,
// twinkle, and emblem shimmer.

uniform float progress : hint_range(0.0, 1.0) = 1.0;
uniform float aspect = 1.777;

const vec3 BLACK  = vec3(0.030, 0.030, 0.065);
const vec3 INDIGO = vec3(0.13, 0.18, 0.55);
const vec3 BLUE   = vec3(0.22, 0.42, 0.92);
const vec3 CREAM  = vec3(0.96, 0.90, 0.72);
const vec3 GOLD   = vec3(0.96, 0.78, 0.30);
const vec3 ORANGE = vec3(0.95, 0.55, 0.12);

const float MAXD = 0.62;     // deepest a curtain reaches at full cover
const float SOFT = 0.014;    // edge softness (reads as glow, not vector hard-edge)

float hash11(float n) { return fract(sin(n) * 43758.5453123); }
float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float tri(float x) { return abs(fract(x) * 2.0 - 1.0); }

// Jagged 0..1 edge profile with jog-within-jog detail (three triangle octaves).
float jag(float x, float seed) {
	float v = tri(x * 9.0 + hash11(seed) * 10.0) * 0.6;
	v += tri(x * 23.0 + hash11(seed + 5.0) * 10.0) * 0.30;
	v += tri(x * 53.0) * 0.10;
	return v;
}

// One edge's opaque coverage with a jagged leading edge. d = distance from
// edge (0..1), along = coordinate parallel to the edge.
float curtain(float d, float along, float seed) {
	float boundary = progress * MAXD * (0.55 + 0.45 * jag(along, seed));
	return smoothstep(SOFT, 0.0, d - boundary);
}

// Persistent radiating shard pattern (the COLOUR — blue spikes on black, like
// the poster), independent of the opaque cover. 14 irregular spikes of varied
// width and length with a jagged tip; returns 0..1.
float shards(float r, float ang, float tm) {
	float n = 14.0;
	float a = ang / TAU + 0.5;
	float cell = floor(a * n);
	float f = fract(a * n);
	float w = mix(0.16, 0.42, hash11(cell));              // angular half-width
	float spike = smoothstep(w, w * 0.25, abs(f - 0.5));  // 1 at spike centre
	float len = mix(0.52, 0.98, hash11(cell + 3.0));      // radial reach
	len += 0.04 * tri(r * 8.0 + cell);                    // jagged length
	float radial = smoothstep(len, len - 0.16, r) * smoothstep(0.13, 0.24, r);
	return spike * radial;
}

void fragment() {
	vec2 uv = UV;
	vec2 p = (uv - 0.5);
	p.x *= aspect;
	float r = length(p);
	float ang = atan(p.y, p.x);
	float tm = TIME;

	// Opaque cover: four jagged curtains crawling from the edges + a centre
	// core, so the map is fully hidden at full progress and revealed as it
	// retracts. This is the ALPHA only.
	float cover = max(
		max(curtain(uv.y, uv.x, 3.0), curtain(1.0 - uv.y, uv.x, 17.0)),
		max(curtain(uv.x, uv.y, 31.0), curtain(1.0 - uv.x, uv.y, 47.0)));
	cover = max(cover, smoothstep(SOFT, 0.0, r - progress * 0.62));

	// --- colour: black field + blue radiating shards (poster look) ---
	vec3 col = BLACK;
	float sh = shards(r, ang, tm);
	col = mix(col, INDIGO, sh * 0.7);
	col = mix(col, BLUE, smoothstep(0.4, 1.0, sh));          // bright shard cores

	// Stars: sparse twinkling specks in the dark field.
	vec2 sc = floor(uv * vec2(240.0, 135.0));
	float star = step(0.992, hash21(sc));
	float tw = 0.5 + 0.5 * sin(tm * 3.0 + hash21(sc) * 30.0);
	col += CREAM * star * tw * 0.7 * (1.0 - sh);

	// Central folk sun-emblem with a soft white bloom halo.
	float em = smoothstep(0.42, 0.55, progress);
	float halo = smoothstep(0.34, 0.0, r) * 0.55;
	col = mix(col, vec3(0.85, 0.90, 1.0), halo * em);
	float rays = 0.5 + 0.5 * cos(ang * 12.0 - tm * 0.6);
	float ray_lim = 0.20 * (0.72 + 0.28 * rays);
	col = mix(col, GOLD, smoothstep(ray_lim, ray_lim - 0.015, r) * em);
	col = mix(col, CREAM, smoothstep(0.105, 0.085, r) * em);  // sun disc
	col = mix(col, ORANGE, smoothstep(0.06, 0.04, r) * em);   // hot core

	// Film grain — the single biggest "not cheap" lever.
	float g = (hash21(uv * vec2(1920.0, 1080.0) + tm) - 0.5) * 0.06;
	col += vec3(g);

	// Vignette toward the corners.
	col *= 1.0 - smoothstep(0.55, 1.05, r) * 0.45;

	COLOR = vec4(col, clamp(cover, 0.0, 1.0));
}
