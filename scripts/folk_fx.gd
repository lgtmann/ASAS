class_name FolkFX

# Procedural FX toolkit for the Son-of-the-White-Mare look — the shared home
# for the folk palette and the jagged/lightning primitives used by the battle
# intro, card backs, spell effects, and anything else psychedelic. Pure
# functions + canvas draw helpers; no state.

# The folk palette (single source of truth — keep the .gdshader copies in sync).
const CREAM := Color(0.96, 0.86, 0.55)
const ORANGE := Color(0.91, 0.49, 0.13)
const CRIMSON := Color(0.72, 0.12, 0.15)
const INDIGO := Color(0.13, 0.16, 0.46)
const BLACK := Color(0.05, 0.04, 0.08)
const PALETTE := [CREAM, ORANGE, CRIMSON, INDIGO, BLACK]

static func _rand(state: int) -> int:
	return (state * 1103515245 + 12345) & 0x7FFFFFFF

# Recursive midpoint-displacement lightning between a and b. Each pass
# subdivides every segment and kicks the new midpoint perpendicular by a
# random amount that halves each pass — giving the self-similar jog-within-jog
# silhouette real lightning has (vs a single triangle). `seed` makes it
# deterministic; step the seed per-frame for a flickering bolt.
static func lightning(a: Vector2, b: Vector2, passes: int, amp: float, seed: int) -> PackedVector2Array:
	var pts := PackedVector2Array([a, b])
	var s := seed | 1
	var cur_amp := amp
	for _p in passes:
		var nxt := PackedVector2Array()
		for i in pts.size() - 1:
			var p0: Vector2 = pts[i]
			var p1: Vector2 = pts[i + 1]
			var seg: Vector2 = p1 - p0
			var perp: Vector2 = Vector2(-seg.y, seg.x).normalized()
			s = _rand(s)
			var off: float = (float(s % 1000) / 1000.0 - 0.5) * 2.0 * cur_amp
			nxt.append(p0)
			nxt.append((p0 + p1) * 0.5 + perp * off)
		nxt.append(pts[pts.size() - 1])
		pts = nxt
		cur_amp *= 0.5
	return pts

# Lightning-ify an existing polyline: insert jog-within-jog detail into every
# segment so a clean chain (e.g. curtain teeth) reads as crackling edge.
static func jag_chain(points: PackedVector2Array, passes: int, amp: float, seed: int) -> PackedVector2Array:
	if points.size() < 2:
		return points
	var out := PackedVector2Array()
	var s := seed | 1
	for i in points.size() - 1:
		s = _rand(s)
		var bolt := lightning(points[i], points[i + 1], passes, amp, s)
		for j in bolt.size():
			if i > 0 and j == 0:
				continue                 # avoid duplicating shared endpoints
			out.append(bolt[j])
	return out

# Two-pass bolt draw: soft wide glow under a bright thin core — the classic
# "expensive" lightning read. `flicker` (0..1) jitters brightness.
static func draw_bolt(canvas: CanvasItem, pts: PackedVector2Array,
		core: Color = CREAM, glow: Color = INDIGO,
		core_w: float = 2.2, glow_w: float = 7.0, flicker: float = 1.0) -> void:
	if pts.size() < 2:
		return
	var g := glow
	g.a *= 0.45 * flicker
	canvas.draw_polyline(pts, g, glow_w, true)
	var c := core
	c.a *= flicker
	canvas.draw_polyline(pts, c, core_w, true)

# Palette colour by band index (wraps), for cel-banded fields.
static func band(i: int) -> Color:
	return PALETTE[((i % PALETTE.size()) + PALETTE.size()) % PALETTE.size()]
