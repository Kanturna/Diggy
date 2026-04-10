extends CanvasLayer
class_name DebugOverlay

const MaterialType = preload("res://core/MaterialType.gd")
const Config = preload("res://core/Config.gd")

@onready var _label: Label = $Panel/MarginContainer/DebugLabel

var world: WorldModel
var renderer: WorldMaterialRenderer
var is_visible_overlay := true

func setup(world_model: WorldModel, world_renderer: WorldMaterialRenderer) -> void:
	world = world_model
	renderer = world_renderer
	visible = is_visible_overlay

func _process(_delta: float) -> void:
	if Input.is_action_just_pressed(Config.DEBUG_TOGGLE_ACTION):
		is_visible_overlay = not is_visible_overlay
		visible = is_visible_overlay

	if not visible or world == null or renderer == null:
		return

	var world_mouse := get_viewport().get_camera_2d().get_global_mouse_position()
	var cell := renderer.world_to_cell(world_mouse)
	var text := _build_debug_text(cell)
	_label.text = text

func _build_debug_text(cell: Vector2i) -> String:
	var lines: Array[String] = []
	var camera := get_viewport().get_camera_2d()
	lines.append("FPS: %d" % Engine.get_frames_per_second())
	lines.append("Seed: %d" % world.seed)
	if camera != null:
		var zoom_levels := Config.CAMERA_ZOOM_LEVELS
		var zoom_level_index := zoom_levels.find(camera.zoom.x)
		if zoom_level_index >= 0:
			lines.append("Zoom: %.3f (%d/%d)" % [camera.zoom.x, zoom_level_index + 1, zoom_levels.size()])
		else:
			lines.append("Zoom: %.3f" % camera.zoom.x)
	lines.append("Cell: (%d, %d)" % [cell.x, cell.y])

	if not world.is_in_bounds(cell.x, cell.y):
		lines.append("Material: OUT_OF_BOUNDS")
		return "\n".join(lines)

	var data := world.get_cell(cell.x, cell.y)
	var material := int(data.get("material", MaterialType.Id.EMPTY))
	var variant := int(data.get("variant", 0))
	var cell_flags := int(data.get("flags", 0))

	var material_name := "EMPTY"
	if material == MaterialType.Id.EARTH:
		material_name = "EARTH"

	var chunk := Vector2i(cell.x / world.chunk_size, cell.y / world.chunk_size)

	lines.append("Material: %s" % material_name)
	lines.append("Variant: %d" % variant)
	lines.append("Flags: %d" % cell_flags)
	lines.append("Chunk: (%d, %d)" % [chunk.x, chunk.y])

	return "\n".join(lines)
