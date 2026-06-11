class_name SpadeActions

# Shared pose math for the operator action animations (dig / swing / throw /
# fish). Offsets are in GAME pixels relative to the unit's feet — the game
# draws them 1:1; the animation viewer multiplies by its stage scale. Keeping
# this in one place means the viewer always previews exactly what ships.

const DUR := {"dig": 0.7, "swing": 0.45, "throw": 0.5, "fish": 1.0}
const THROW_WINDUP := 0.3              # projectile launches at this moment

# Held-spade prop pose at normalised time t (0..1). Returns null when the
# prop is hidden (post-release throw), else {off: Vector2, rot: float,
# flip: bool}.
static func prop_pose(type: String, t: float, dir: Vector2) -> Variant:
	t = clampf(t, 0.0, 1.0)
	var side: float = 1.0 if dir.x >= 0.0 else -1.0
	var flip: bool = side < 0.0
	match type:
		"dig":
			if t < 0.35:
				var k: float = t / 0.35
				return {"off": Vector2(10.0 * side, -12.0 - 7.0 * k),
					"rot": side * lerpf(-0.3, -1.1, k), "flip": flip}
			elif t < 0.6:
				var k2: float = (t - 0.35) / 0.25
				return {"off": Vector2((10.0 + 11.0 * k2) * side, -19.0 + 19.0 * k2),
					"rot": side * lerpf(-1.1, 1.25, k2), "flip": flip}
			else:
				var k3: float = (t - 0.6) / 0.4
				return {"off": Vector2((21.0 - 11.0 * k3) * side, -k3 * 12.0),
					"rot": side * lerpf(1.25, -0.3, k3), "flip": flip}
		"swing":
			if t < 0.6:
				var k4: float = t / 0.6
				return {"off": dir * 9.0 * k4 + Vector2(0, -14.0),
					"rot": side * lerpf(-1.4, 1.2, k4 * k4), "flip": flip}
			else:
				var k5: float = (t - 0.6) / 0.4
				return {"off": dir * 9.0 * (1.0 - k5) + Vector2(0, -14.0),
					"rot": side * lerpf(1.2, -0.3, k5), "flip": flip}
		"throw":
			var rel: float = THROW_WINDUP / float(DUR["throw"])
			if t < rel:
				# Wind up high over the shoulder, not at the hip.
				var k6: float = t / rel
				return {"off": -dir * 13.0 * k6 + Vector2(0, -16.0 - 14.0 * k6),
					"rot": side * lerpf(-0.3, -2.4, k6 * k6), "flip": flip}
			return null      # released — the projectile carries it now
		"fish":
			return {"off": dir * 12.0 + Vector2(0, -10.0 + sin(t * TAU * 2.0) * 2.5),
				"rot": side * 0.95, "flip": flip}
	return null

static func phase_name(type: String, t: float) -> String:
	if t < 0.0:
		return "idle"
	match type:
		"dig":
			if t < 0.35:
				return "windup"
			elif t < 0.6:
				return "PLUNGE"
			return "recover"
		"swing":
			return "SWING" if t < 0.6 else "recover"
		"throw":
			return "windup" if t < THROW_WINDUP / float(DUR["throw"]) else "RELEASED"
		"fish":
			return "bobbing"
	return ""
