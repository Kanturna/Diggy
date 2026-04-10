extends RefCounted
class_name WorldModel

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

func set_cell(x: int, y: int, material: int, variant: int, cell_flags: int) -> void:
	if not is_in_bounds(x, y):
		return
	var i := index_of(x, y)
	materials[i] = material
	variants[i] = variant
	flags[i] = cell_flags
	mark_dirty_by_cell(x, y)

func set_material(x: int, y: int, material: int) -> void:
	if not is_in_bounds(x, y):
		return
	var i := index_of(x, y)
	if materials[i] == material:
		return
	materials[i] = material
	mark_dirty_by_cell(x, y)

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
