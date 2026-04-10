extends Camera2D
class_name CameraController

const Config = preload("res://core/Config.gd")

var _target_zoom: float = 1.0

func _ready() -> void:
	make_current()
	_target_zoom = zoom.x

func _process(delta: float) -> void:
	_handle_movement(delta)
	_handle_zoom_keys()
	_update_zoom(delta)

func _handle_movement(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_action_pressed(Config.MOVE_RIGHT_ACTION):
		dir.x += 1
	if Input.is_action_pressed(Config.MOVE_LEFT_ACTION):
		dir.x -= 1
	if Input.is_action_pressed(Config.MOVE_DOWN_ACTION):
		dir.y += 1
	if Input.is_action_pressed(Config.MOVE_UP_ACTION):
		dir.y -= 1

	if dir == Vector2.ZERO:
		return

	var speed := Config.CAMERA_BASE_SPEED
	if Input.is_action_pressed(Config.SPEED_ACTION):
		speed *= Config.CAMERA_SHIFT_MULTIPLIER

	position += dir.normalized() * speed * delta

func _handle_zoom_keys() -> void:
	if Input.is_action_just_pressed(Config.ZOOM_IN_ACTION):
		_apply_zoom(-Config.CAMERA_ZOOM_STEP)
	if Input.is_action_just_pressed(Config.ZOOM_OUT_ACTION):
		_apply_zoom(Config.CAMERA_ZOOM_STEP)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_apply_zoom(-Config.CAMERA_MOUSE_WHEEL_ZOOM_STEP)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_apply_zoom(Config.CAMERA_MOUSE_WHEEL_ZOOM_STEP)

func _apply_zoom(delta_zoom: float) -> void:
	_target_zoom = clampf(
		_target_zoom + delta_zoom,
		Config.CAMERA_ZOOM_MIN,
		Config.CAMERA_ZOOM_MAX
	)

func _update_zoom(delta: float) -> void:
	var current_zoom: float = zoom.x
	var zoom_step: float = Config.CAMERA_ZOOM_SMOOTH_SPEED * delta
	var next_zoom: float = move_toward(current_zoom, _target_zoom, zoom_step)
	zoom = Vector2(next_zoom, next_zoom)
