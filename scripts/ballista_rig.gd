class_name BallistaRig
extends RefCounted

# Cutout rig for the ballista: body + bow sprites (generated full-frame and
# in-situ, so they overlay 1:1) plus a CODE-DRAWN string. Transforms tween at
# render rate, so the fire animation is perfectly smooth — the approach frame
# generation couldn't deliver.
#
# All geometry lives in FRACTIONS of the square art frame, so the same rig
# draws at any size (in-game cell or viewer stage).

const MOUNT := Vector2(0.45, 0.42)        # bow mount point on the rail
const TIP_L := Vector2(0.10, 0.24)        # upper-left bow tip (string anchor)
const TIP_R := Vector2(0.815, 0.585)      # lower-right bow tip (string anchor)
const FIRE_DIR := Vector2(-0.967, 0.253)  # screen-space firing direction
const RAIL_SPADE := Vector2(0.40, 0.42)   # where the loaded spade lies
const DRAW_LEN := 0.16                    # nock travel as a frame fraction

const T_RELEASE := 0.55                   # phase splits within t 0..1
const T_SNAP_END := 0.62
const DUR := 1.05                         # seconds per fire cycle

# String/bow draw amount over the cycle: smooth anticipation, violent snap to
# a slight overshoot, then decaying wobble. t < 0 = idle.
static func draw_amount(t: float) -> float:
	if t < 0.0:
		return 0.0
	if t < T_RELEASE:
		var k: float = t / T_RELEASE
		return k * k * (3.0 - 2.0 * k)
	if t < T_SNAP_END:
		var k2: float = (t - T_RELEASE) / (T_SNAP_END - T_RELEASE)
		return 1.0 - 1.15 * k2
	var k3: float = (t - T_SNAP_END) / maxf(0.001, 1.0 - T_SNAP_END)
	return -0.15 * exp(-4.0 * k3) * cos(k3 * 18.0)

static func phase_name(t: float) -> String:
	if t < 0.0:
		return "idle (loaded)"
	if t < T_RELEASE:
		return "drawing %d%%" % int(draw_amount(t) * 100.0)
	if t < T_SNAP_END:
		return "RELEASE"
	return "wobble"

# Draw the rig into `rect` (square) at cycle time `t` (seconds 0..DUR scaled
# to 0..1 by the caller; pass t < 0 for the idle loaded pose).
static func draw(canvas: CanvasItem, rect: Rect2, t: float, tex: Dictionary) -> void:
	var body: Texture2D = tex.get("body")
	var bow: Texture2D = tex.get("bow")
	var spade: Texture2D = tex.get("spade")
	if body == null or bow == null:
		return
	var amt: float = draw_amount(t)
	var s: float = rect.size.x
	var fire: Vector2 = FIRE_DIR

	# Recoil kick rearward just after release, springing back.
	var recoil := Vector2.ZERO
	if t >= T_RELEASE and t <= 1.0:
		var rk: float = (t - T_RELEASE) / (1.0 - T_RELEASE)
		recoil = -fire * s * 0.014 * exp(-5.0 * rk)
	var origin: Vector2 = rect.position + recoil

	canvas.draw_texture_rect(body, Rect2(origin, rect.size), false)

	# Bow: compresses along the fire axis while drawn (limbs pulling back).
	var mount_px: Vector2 = origin + MOUNT * s
	var squash := Vector2(1.0 - 0.055 * amt, 1.0)
	var slide: Vector2 = -fire * s * 0.012 * amt
	canvas.draw_set_transform_matrix(
		Transform2D(0.0, squash, 0.0, mount_px + slide))
	canvas.draw_texture_rect(bow, Rect2(-MOUNT * s, rect.size), false)
	canvas.draw_set_transform_matrix(Transform2D())

	# String: WW-style rope — dark outline under a tan core, antialiased, with
	# a slight sag at rest and a sharp V when drawn. Nock knot sells the detail.
	var tipl: Vector2 = mount_px + slide + (TIP_L - MOUNT) * s * squash
	var tipr: Vector2 = mount_px + slide + (TIP_R - MOUNT) * s * squash
	var pull: Vector2 = -fire * (s * DRAW_LEN) * amt
	var nock: Vector2 = (tipl + tipr) * 0.5 + pull
	var pts: PackedVector2Array
	if absf(amt) < 0.04:
		# Near-rest: gentle catenary sag instead of a kinked V.
		pts = PackedVector2Array()
		for i in 9:
			var k: float = float(i) / 8.0
			var pos: Vector2 = tipl.lerp(tipr, k)
			pos += Vector2(0, s * 0.006) * sin(k * PI)
			pts.append(pos)
	else:
		pts = PackedVector2Array([tipl, nock, tipr])
	var rope_out := Color(0.20, 0.13, 0.08)
	var rope_core := Color(0.78, 0.66, 0.45)
	canvas.draw_polyline(pts, rope_out, maxf(2.5, s * 0.017), true)
	canvas.draw_polyline(pts, rope_core, maxf(1.2, s * 0.009), true)
	# Nock knot.
	canvas.draw_circle(nock, maxf(2.0, s * 0.013), rope_out)
	canvas.draw_circle(nock, maxf(1.0, s * 0.008), rope_core)

	# The loaded spade: an in-situ full-frame overlay (extracted from an edit
	# of the base art), so its perspective matches the rail exactly. It rides
	# the nock rearward during the draw and vanishes at release.
	if spade != null and t < T_RELEASE:
		canvas.draw_texture_rect(spade, Rect2(origin + pull * 0.8, rect.size), false)
