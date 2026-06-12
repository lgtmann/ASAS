extends Node

# Controller support (Steam Deck native). The left stick drives a virtual
# mouse cursor and A/B synthesize real mouse clicks, so every existing
# click / hover / drag path — cards, modals, tiles, right-click attacks —
# works unmodified on gamepad.
#
#   Left stick   move cursor          A      left click (select / act)
#   Right stick  pan camera           B      right click (attack / cancel)
#   LB / RB      zoom out / in        Y      End Turn
#   X            Build menu           Start  back to title
#
# A painted cursor appears whenever the pad is in use and hides the moment
# a real mouse moves.

const CURSOR_SPEED := 1100.0
const DEADZONE := 0.18

var pad_active: bool = false
var _cursor: Control

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_cursor = Control.new()
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cursor.draw.connect(_draw_cursor)
	layer.add_child(_cursor)

func _process(delta: float) -> void:
	var v := Vector2(
		Input.get_joy_axis(0, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(0, JOY_AXIS_LEFT_Y))
	if v.length() < DEADZONE:
		v = Vector2.ZERO
	else:
		v = v * (v.length() - DEADZONE) / (1.0 - DEADZONE)   # smooth ramp
	if v != Vector2.ZERO:
		pad_active = true
		var vp := get_viewport()
		var pos: Vector2 = vp.get_mouse_position() + v * CURSOR_SPEED * delta
		pos = pos.clamp(Vector2.ZERO, vp.get_visible_rect().size)
		vp.warp_mouse(pos)
	if pad_active:
		_cursor.queue_redraw()

func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		pad_active = true
		# A / B become real mouse clicks at the cursor.
		if event.button_index == JOY_BUTTON_A or event.button_index == JOY_BUTTON_B:
			var mb := InputEventMouseButton.new()
			mb.button_index = MOUSE_BUTTON_LEFT if event.button_index == JOY_BUTTON_A \
					else MOUSE_BUTTON_RIGHT
			mb.pressed = event.pressed
			mb.position = get_viewport().get_mouse_position()
			mb.global_position = mb.position
			Input.parse_input_event(mb)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.relative.length() > 2.0 and mm.velocity != Vector2.ZERO:
			pad_active = false       # a real mouse took over
			_cursor.queue_redraw()

func _draw_cursor() -> void:
	if not pad_active:
		return
	var p: Vector2 = get_viewport().get_mouse_position()
	var pts := PackedVector2Array([p, p + Vector2(0, 22), p + Vector2(6, 17),
		p + Vector2(10, 26), p + Vector2(14, 24), p + Vector2(10, 15),
		p + Vector2(17, 14)])
	_cursor.draw_colored_polygon(pts, Color(0.97, 0.94, 0.85))
	var outline := pts.duplicate()
	outline.append(p)
	_cursor.draw_polyline(outline, Color(0.16, 0.10, 0.05), 2.0, true)
