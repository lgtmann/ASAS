class_name BattleIntro
extends Control

# Step 1 of the rebuilt battle intro: a single dynamically-drawn lightning
# bolt that strikes down from the top of the screen to the centre. Pure _draw
# (a few glowing polylines) — no shader, no full-screen fill, so it's cheap.
# Regenerates its jag each frame for a live flicker, then frees itself.

signal revealed

const DUR := 1.1                 # how long the strike lingers before reveal
const PASSES := 6                # recursive subdivisions of the main bolt
const FORKS := 2                 # short branches off the main bolt

const GLOW := Color(0.13, 0.18, 0.55)   # indigo outer glow
const MID := Color(0.22, 0.42, 0.92)    # blue mid
const CORE := Color(0.97, 0.97, 1.0)    # near-white hot core

var _t := 0.0
var _frozen := false
var _seed := 1

func freeze_at(tv: float) -> void:
	_frozen = true
	_t = tv
	_seed = int(tv * 1000.0) | 1

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not _frozen:
		Sfx.play("quake", 0.0, 0.0)
	queue_redraw()

func _process(delta: float) -> void:
	if _frozen:
		return
	_t += delta
	_seed = int(_t * 90.0) | 1          # steps a few times per frame → flicker
	queue_redraw()
	if _t >= DUR:
		revealed.emit()
		queue_free()

# Brightness envelope: bright flash on impact, easing off over the duration,
# with a little per-frame flicker.
func _intensity() -> float:
	if _frozen:
		return 1.0
	var env: float = 1.0 - smoothstep(0.0, DUR, _t) * 0.7
	var flick: float = 0.7 + 0.3 * float(_seed % 5) / 4.0
	return clampf(env * flick, 0.0, 1.0)

# Three stacked polylines (wide soft glow → blue mid → hot core) make the bolt
# read as glowing rather than a flat line.
func _draw_bolt(pts: PackedVector2Array, scale: float, a: float) -> void:
	if pts.size() < 2:
		return
	draw_polyline(pts, Color(GLOW.r, GLOW.g, GLOW.b, 0.30 * a), 13.0 * scale, true)
	draw_polyline(pts, Color(MID.r, MID.g, MID.b, 0.55 * a), 6.0 * scale, true)
	draw_polyline(pts, Color(CORE.r, CORE.g, CORE.b, 0.95 * a), 2.4 * scale, true)

func _draw() -> void:
	var a := _intensity()
	if a <= 0.01:
		return
	var top := Vector2(size.x * 0.5, 0.0)
	var centre := Vector2(size.x * 0.5, size.y * 0.5)
	var amp: float = (centre.y - top.y) * 0.11
	var main: PackedVector2Array = FolkFX.lightning(top, centre, PASSES, amp, _seed)
	# Short forks branching off points partway down the main bolt.
	for i in FORKS:
		var idx: int = int(main.size() * (0.4 + 0.22 * float(i)))
		idx = clampi(idx, 1, main.size() - 1)
		var base: Vector2 = main[idx]
		var dir: float = -1.0 if i % 2 == 0 else 1.0
		var tip: Vector2 = base + Vector2(dir * size.y * 0.16, size.y * 0.13)
		var fork: PackedVector2Array = FolkFX.lightning(base, tip, 4, amp * 0.7, _seed + 53 + i * 17)
		_draw_bolt(fork, 0.6, a * 0.85)
	_draw_bolt(main, 1.0, a)
