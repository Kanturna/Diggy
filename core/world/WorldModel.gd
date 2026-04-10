extends RefCounted
class_name WorldModel

const MaterialType = preload("res://core/MaterialType.gd")
const CellFlags = preload("res://core/CellFlags.gd")

signal world_reset

var width: int
var height: int
var chunk_size: int
var seed: int

var materials := PackedByteArray()
var variants := PackedByteArray()
var flags := PackedInt32Array()

var _dirty_chunk_keys: Dictionary = {}

func setup(new_width: int, new_height: int, new_chunk_size: int, new_seed: int) -> void:
	width = new_width
	height = new_height
	chunk_size = new_chunk_size
	seed = new_seed

	var total_cells := width * height
	materials.resize(total_cells)
	variants.resize(total_cells)
	flags.resize(total_cells)
	clear_dirty_chunks()

func index_of(x: int, y: int) -> int:
	return y * width + x

func is_in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < width and y < height

func get_cell(x: int, y: int) -> Dictionary:
	if not is_in_bounds(x, y):
		return {}
	var i := index_of(x, y)
	return {
		"material": materials[i],
		"variant": variants[i],
		"flags": flags[i],
	}

func get_material(x: int, y: int) -> int:
	if not is_in_bounds(x, y):
		return MaterialType.Id.EMPTY
	return materials[index_of(x, y)]

func get_variant(x: int, y: int) -> int:
	if not is_in_bounds(x, y):
		return 0
	return variants[index_of(x, y)]

func get_flags(x: int, y: int) -> int:
	if not is_in_bounds(x, y):
		return CellFlags.Id.NONE
	return flags[index_of(x, y)]

func set_cell(x: int, y: int, material: int, variant: int, cell_flags: int) -> void:
	if not is_in_bounds(x, y):
		return
	var i := index_of(x, y)
	materials[i] = material
	variants[i] = variant
	flags[i] = cell_flags
	mark_dirty_by_cell(x, y)

func set_material(x: int, y: int, material: int, variant_override: int = -1) -> void:
	if not is_in_bounds(x, y):
		return
	var i := index_of(x, y)
	var next_flags := _default_flags_for_material(material)
	var next_variant := _default_variant_for_material(i, material)
	if variant_override >= 0:
		next_variant = variant_override
	if materials[i] == material and flags[i] == next_flags and variants[i] == next_variant:
		return
	materials[i] = material
	flags[i] = next_flags
	variants[i] = next_variant
	mark_dirty_by_cell(x, y)

func is_blocking(x: int, y: int) -> bool:
	return (get_flags(x, y) & CellFlags.Id.BLOCKING) != 0

func mark_dirty_by_cell(x: int, y: int) -> void:
	var chunk := Vector2i(x / chunk_size, y / chunk_size)
	_dirty_chunk_keys[chunk] = true

func get_and_clear_dirty_chunks() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for chunk_key in _dirty_chunk_keys.keys():
		out.append(chunk_key)
	_dirty_chunk_keys.clear()
	return out

func clear_dirty_chunks() -> void:
	_dirty_chunk_keys.clear()

func mark_world_dirty() -> void:
	var chunks_x := int(ceil(float(width) / float(chunk_size)))
	var chunks_y := int(ceil(float(height) / float(chunk_size)))
	for cy in chunks_y:
		for cx in chunks_x:
			_dirty_chunk_keys[Vector2i(cx, cy)] = true
	world_reset.emit()

func chunk_rect(chunk: Vector2i) -> Rect2i:
	var x := chunk.x * chunk_size
	var y := chunk.y * chunk_size
	var w := min(chunk_size, width - x)
	var h := min(chunk_size, height - y)
	return Rect2i(x, y, w, h)

func _default_flags_for_material(material: int) -> int:
	if material == MaterialType.Id.EARTH:
		return CellFlags.Id.BLOCKING | CellFlags.Id.DIGGABLE
	return CellFlags.Id.NONE

func _default_variant_for_material(index: int, material: int) -> int:
	if material == MaterialType.Id.EARTH:
		return clamp(variants[index], 0, 2)
	return 0
