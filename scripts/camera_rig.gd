extends Node3D

# Orbit camera: this Node3D sits at the look-at pivot; the Camera3D child orbits
# around it. Right-mouse drag rotates, wheel zooms.

var cam: Camera3D
var dist: float = 18.0
var yaw: float = 0.7
var pitch: float = 0.85
var _dragging: bool = false

func _ready() -> void:
	cam = Camera3D.new()
	add_child(cam)
	_update()

func _update() -> void:
	var offset := Vector3(0, 0, dist)
	offset = offset.rotated(Vector3(1, 0, 0), -pitch)
	offset = offset.rotated(Vector3(0, 1, 0), yaw)
	cam.position = offset
	cam.look_at(global_position, Vector3.UP)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = max(6.0, dist - 1.5)
			_update()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = min(42.0, dist + 1.5)
			_update()
	elif event is InputEventMouseMotion and _dragging:
		yaw -= event.relative.x * 0.01
		pitch = clamp(pitch + event.relative.y * 0.01, 0.15, 1.45)
		_update()
