class_name FlyCamera
extends Camera3D
## Six degree-of-freedom "flying" camera. No collision, no gravity: the whole
## point is to be able to pass straight through the anatomy.
##
##   W / S        forward / back            (fly toward the crosshair)
##   A / D        strafe
##   Q / E        down / up  (or Space / Ctrl)
##   Shift        boost x3.5
##   Alt          slow x0.3
##   mouse        look (click the window to capture, Esc to release)
##   wheel        change cruise speed

signal capture_changed(captured: bool)

@export var base_speed := 30.0
@export var look_sensitivity := 0.0021
@export var boost_factor := 3.5
@export var slow_factor := 0.30
@export var smoothing := 9.0
@export var gamepad_look_speed := 2.2  # radians per second at full stick tilt

var enabled := true
var captured := false
var gamepad_enabled := true

var _yaw := 0.0
var _pitch := 0.0
var _velocity := Vector3.ZERO
var _dragging := false


func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x


func aim_from(pos: Vector3, target: Vector3) -> void:
	position = pos
	look_at(target, Vector3.UP)
	_yaw = rotation.y
	_pitch = rotation.x
	_velocity = Vector3.ZERO


func sync_angles() -> void:
	_yaw = rotation.y
	_pitch = rotation.x


func capture_mouse(on: bool) -> void:
	captured = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE
	capture_changed.emit(on)


func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not captured:
			_dragging = mb.pressed
		elif mb.pressed and captured:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				base_speed = clampf(base_speed * 1.18, 1.0, 400.0)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				base_speed = clampf(base_speed / 1.18, 1.0, 400.0)
	elif event is InputEventMouseMotion and (captured or _dragging):
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * look_sensitivity
		_pitch = clampf(_pitch - mm.relative.y * look_sensitivity, -1.55, 1.55)


func _process(delta: float) -> void:
	if not enabled:
		return
	if gamepad_enabled:
		var look := Input.get_vector("pad_look_left", "pad_look_right", "pad_look_up", "pad_look_down")
		_yaw -= look.x * gamepad_look_speed * delta
		_pitch = clampf(_pitch - look.y * gamepad_look_speed * delta, -1.55, 1.55)
	rotation = Vector3(_pitch, _yaw, 0.0)

	var input := Vector3.ZERO
	if _key(KEY_W) or _key(KEY_UP):
		input.z -= 1.0
	if _key(KEY_S) or _key(KEY_DOWN):
		input.z += 1.0
	if _key(KEY_A) or _key(KEY_LEFT):
		input.x -= 1.0
	if _key(KEY_D) or _key(KEY_RIGHT):
		input.x += 1.0
	if _key(KEY_E) or _key(KEY_SPACE):
		input.y += 1.0
	if _key(KEY_Q) or _key(KEY_CTRL):
		input.y -= 1.0
	if gamepad_enabled:
		var stick := Input.get_vector("pad_move_left", "pad_move_right", "pad_move_forward", "pad_move_back")
		input += Vector3(stick.x, Input.get_axis("pad_down", "pad_up"), stick.y)
	if input.length() > 1.0:
		input = input.normalized()

	var speed := base_speed
	if _key(KEY_SHIFT):
		speed *= boost_factor
	if _key(KEY_ALT):
		speed *= slow_factor
	if gamepad_enabled:
		speed *= lerpf(1.0, boost_factor, Input.get_action_strength("pad_boost"))
		speed *= lerpf(1.0, slow_factor, Input.get_action_strength("pad_slow"))

	var target := basis * input * speed
	_velocity = _velocity.lerp(target, 1.0 - exp(-smoothing * delta))
	position += _velocity * delta


func set_gamepad_enabled(on: bool) -> void:
	gamepad_enabled = on
	if not on:
		_velocity = Vector3.ZERO


func _key(code: int) -> bool:
	return Input.is_physical_key_pressed(code)


func speed_label() -> String:
	var s := base_speed
	if _key(KEY_SHIFT):
		s *= boost_factor
	elif _key(KEY_ALT):
		s *= slow_factor
	return "%.0f cm/s" % s
