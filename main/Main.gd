extends Node2D

const Config = preload("res://core/Config.gd")
const WorldModelScript = preload("res://core/world/WorldModel.gd")
const WorldGeneratorScript = preload("res://core/world/WorldGenerator.gd")
const RendererScript = preload("res://render/WorldMaterialRenderer.gd")
const CameraControllerScript = preload("res://camera/CameraController.gd")
const DebugOverlayScene = preload("res://debug/DebugOverlay.tscn")

var world_model: WorldModel
var world_generator: WorldGenerator
var renderer: WorldMaterialRenderer
var camera_controller: CameraController
var debug_overlay: DebugOverlay

func _ready() -> void:
	_setup_input_map()
	_setup_world_core()
	_generate_world()
	_setup_renderer()
	_setup_camera()
	_setup_debug()
	_connect_signals()

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
