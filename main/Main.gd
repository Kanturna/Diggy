extends Node2D

const Config = preload("res://core/Config.gd")
const WorldModelScript = preload("res://core/world/WorldModel.gd")
const WorldGeneratorScript = preload("res://core/world/WorldGenerator.gd")
const RendererScript = preload("res://render/WorldMaterialRenderer.gd")
const CameraControllerScript = preload("res://camera/CameraController.gd")
const DebugOverlayScene  = preload("res://debug/DebugOverlay.tscn")
const UnitManagerScript  = preload("res://units/UnitManager.gd")

var world_model: WorldModel
var world_generator: WorldGenerator
var renderer: WorldMaterialRenderer
var camera_controller: CameraController
var debug_overlay: DebugOverlay
var unit_manager: UnitManager
var _startup_timings := {}

func _ready() -> void:
	var startup_begin_ms := Time.get_ticks_msec()
	_setup_input_map()
	var step_begin_ms := Time.get_ticks_msec()
	_setup_world_core()
	_startup_timings["world_core_ms"] = Time.get_ticks_msec() - step_begin_ms

	step_begin_ms = Time.get_ticks_msec()
	_generate_world()
	_startup_timings["world_generate_ms"] = Time.get_ticks_msec() - step_begin_ms
	_startup_timings["world_generate_fill_ms"] = int(world_generator.last_profile.get("fill_ms", 0))
	_startup_timings["world_generate_carve_ms"] = int(world_generator.last_profile.get("carve_ms", 0))
	_startup_timings["world_generate_smooth_ms"] = int(world_generator.last_profile.get("smooth_ms", 0))
	_startup_timings["world_generate_variants_ms"] = int(world_generator.last_profile.get("variants_ms", 0))

	step_begin_ms = Time.get_ticks_msec()
	_setup_renderer()
	_startup_timings["renderer_setup_ms"] = Time.get_ticks_msec() - step_begin_ms

	step_begin_ms = Time.get_ticks_msec()
	_setup_camera()
	_startup_timings["camera_setup_ms"] = Time.get_ticks_msec() - step_begin_ms

	step_begin_ms = Time.get_ticks_msec()
	_setup_units()
	_startup_timings["unit_setup_ms"] = Time.get_ticks_msec() - step_begin_ms

	step_begin_ms = Time.get_ticks_msec()
	_setup_debug()
	_startup_timings["debug_setup_ms"] = Time.get_ticks_msec() - step_begin_ms

	step_begin_ms = Time.get_ticks_msec()
	_connect_signals()
	_startup_timings["signal_connect_ms"] = Time.get_ticks_msec() - step_begin_ms
	_startup_timings["ready_total_ms"] = Time.get_ticks_msec() - startup_begin_ms
	if debug_overlay != null:
		debug_overlay.set_startup_timings(_startup_timings)
		debug_overlay.unit_manager = unit_manager

func _process(_delta: float) -> void:
	_on_chunks_dirtied()

func _setup_input_map() -> void:
	_ensure_action(Config.MOVE_UP_ACTION, KEY_W)
	_ensure_action(Config.MOVE_DOWN_ACTION, KEY_S)
	_ensure_action(Config.MOVE_LEFT_ACTION, KEY_A)
	_ensure_action(Config.MOVE_RIGHT_ACTION, KEY_D)
	_ensure_action(Config.SPEED_ACTION, KEY_SHIFT)
	_ensure_action(Config.ZOOM_IN_ACTION, KEY_Q)
	_ensure_action(Config.ZOOM_OUT_ACTION, KEY_E)
	_ensure_action(Config.DEBUG_TOGGLE_ACTION, KEY_F3)

func _ensure_action(action_name: String, keycode: Key) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	for event in InputMap.action_get_events(action_name):
		if event is InputEventKey and event.keycode == keycode:
			return
	var key_event := InputEventKey.new()
	key_event.keycode = keycode
	InputMap.action_add_event(action_name, key_event)

func _setup_world_core() -> void:
	world_model = WorldModelScript.new()
	world_model.setup(
		Config.WORLD_WIDTH,
		Config.WORLD_HEIGHT,
		Config.CHUNK_SIZE,
		Config.DEFAULT_SEED
	)
	world_generator = WorldGeneratorScript.new()

func _setup_renderer() -> void:
	renderer = RendererScript.new()
	add_child(renderer)
	renderer.setup(world_model)

func _setup_camera() -> void:
	camera_controller = CameraControllerScript.new()
	add_child(camera_controller)
	camera_controller.position = Vector2(
		Config.WORLD_WIDTH * Config.CELL_SIZE * 0.5,
		Config.WORLD_HEIGHT * Config.CELL_SIZE * 0.5
	)

func _setup_units() -> void:
	unit_manager = UnitManagerScript.new()
	add_child(unit_manager)
	unit_manager.setup(world_model)

func _setup_debug() -> void:
	debug_overlay = DebugOverlayScene.instantiate()
	add_child(debug_overlay)
	debug_overlay.setup(world_model, renderer)

func _connect_signals() -> void:
	world_model.world_reset.connect(_on_world_reset)

func _generate_world() -> void:
	world_generator.generate(world_model)

func _on_world_reset() -> void:
	renderer.redraw_full()
	world_model.clear_dirty_chunks()

func _on_chunks_dirtied() -> void:
	var dirty := world_model.get_and_clear_dirty_chunks()
	renderer.redraw_dirty_chunks(dirty)
