extends Node2D
class_name WorldMaterialRenderer

const MaterialType = preload("res://core/MaterialType.gd")
const Config = preload("res://core/Config.gd")

var world: WorldModel

var _image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
var _texture := ImageTexture.create_from_image(_image)
var _sprite := Sprite2D.new()

var _earth_palette := [
	Color8(94, 61, 34),
	Color8(110, 74, 45),
	Color8(125, 84, 51),
]

func _ready() -> void:
	add_child(_sprite)
	_sprite.texture = _texture
	_sprite.centered = false
	_sprite.scale = Vector2(Config.CELL_SIZE, Config.CELL_SIZE)

func setup(world_model: WorldModel) -> void:
	world = world_model
	_image = Image.create(world.width, world.height, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	_sprite.texture = _texture
	redraw_full()

func redraw_full() -> void:
	if world == null:
		return
	for y in world.height:
		for x in world.width:
			_paint_cell(x, y)
	_texture.update(_image)

func redraw_dirty_chunks(chunks: Array[Vector2i]) -> void:
	if world == null or chunks.is_empty():
		return
	for chunk in chunks:
		var rect := world.chunk_rect(chunk)
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				_paint_cell(x, y)
	_texture.update(_image)

func world_to_cell(world_pos: Vector2) -> Vector2i:
	return Vector2i(floor(world_pos.x / Config.CELL_SIZE), floor(world_pos.y / Config.CELL_SIZE))

func _paint_cell(x: int, y: int) -> void:
	var i := world.index_of(x, y)
	var material := world.materials[i]
	var variant := world.variants[i]
	if material == MaterialType.Id.EARTH:
		var palette_idx := clamp(variant, 0, _earth_palette.size() - 1)
		_image.set_pixel(x, y, _earth_palette[palette_idx])
	else:
		_image.set_pixel(x, y, Color(0, 0, 0, 0))
