extends RefCounted
class_name Config

const WORLD_WIDTH := 768
const WORLD_HEIGHT := 576
const CELL_SIZE := 3
const CHUNK_SIZE := 32

const DEFAULT_SEED := 1337
const CAVE_NOISE_FREQUENCY := 0.045
const CAVE_EMPTY_THRESHOLD := 0.33
const CAVE_SMOOTH_PASSES := 2

const CAMERA_BASE_SPEED := 550.0
const CAMERA_SHIFT_MULTIPLIER := 2.2
const CAMERA_ZOOM_LEVELS := [
	0.25,
	0.5,
	1.0,
	2.0,
	3.0,
	4.0,
]
const CAMERA_DEFAULT_ZOOM_INDEX := 2

const DEBUG_TOGGLE_ACTION := "debug_toggle"
const MOVE_UP_ACTION := "camera_up"
const MOVE_DOWN_ACTION := "camera_down"
const MOVE_LEFT_ACTION := "camera_left"
const MOVE_RIGHT_ACTION := "camera_right"
const SPEED_ACTION := "camera_speed"
const ZOOM_IN_ACTION := "camera_zoom_in"
const ZOOM_OUT_ACTION := "camera_zoom_out"
