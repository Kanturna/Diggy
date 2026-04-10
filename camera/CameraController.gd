extends Camera2D
class_name CameraController

const Config = preload("res://core/Config.gd")

var _zoom_index: int = Config.CAMERA_DEFAULT_ZOOM_INDEX

func _ready() -> void:
	make_current()
	_apply_zoom_level()

func _process(delta: float) -> void:
	_handle_movement(delta)
	_handle_zoom_keys()

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
		_step_zoom(1)
	if Input.is_action_just_pressed(Config.ZOOM_OUT_ACTION):
		_step_zoom(-1)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_step_zoom(1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_step_zoom(-1)

func _step_zoom(direction: int) -> void:
	var next_index := clampi(_zoom_index + direction, 0, Config.CAMERA_ZOOM_LEVELS.size() - 1)
	if next_index == _zoom_index:
		return
	_zoom_index = next_index
	_apply_zoom_level()

func _apply_zoom_level() -> void:
	var zoom_level: float = Config.CAMERA_ZOOM_LEVELS[_zoom_index]
	zoom = Vector2(zoom_level, zoom_level)
