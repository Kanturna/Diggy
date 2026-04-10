extends Camera2D
class_name CameraController

const Config = preload("res://core/Config.gd")

func _ready() -> void:
	make_current()

func _process(delta: float) -> void:
	_handle_movement(delta)
	_handle_zoom()

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

func _handle_zoom() -> void:
	if Input.is_action_just_pressed(Config.ZOOM_IN_ACTION):
		_apply_zoom(-Config.CAMERA_ZOOM_STEP)
	if Input.is_action_just_pressed(Config.ZOOM_OUT_ACTION):
		_apply_zoom(Config.CAMERA_ZOOM_STEP)

func _apply_zoom(delta_zoom: float) -> void:
	var target := zoom.x + delta_zoom
	target = clamp(target, Config.CAMERA_ZOOM_MIN, Config.CAMERA_ZOOM_MAX)
	zoom = Vector2(target, target)
