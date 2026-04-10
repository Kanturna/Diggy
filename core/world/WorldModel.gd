extends RefCounted
class_name WorldModel

const MaterialType = preload("res://core/MaterialType.gd")
const CellFlags = preload("res://core/CellFlags.gd")
const Config = preload("res://core/Config.gd")

signal world_reset

var width: int
var height: int
var chunk_size: int
var seed: int

var materials := PackedByteArray()
var variants := PackedByteArray()
var flags := PackedInt32Array()
var revision := 0

var _dirty_chunk_keys: Dictionary = {}
var _bulk_update_depth := 0

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
	if materials[i] == material and variants[i] == variant and flags[i] == cell_flags:
		return
	materials[i] = material
	variants[i] = variant
	flags[i] = cell_flags
	revision += 1
	if _bulk_update_depth == 0:
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
	revision += 1
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

func begin_bulk_update() -> void:
	_bulk_update_depth += 1

func end_bulk_update(mark_dirty: bool = true) -> void:
	if _bulk_update_depth == 0:
		return
	_bulk_update_depth -= 1
	if _bulk_update_depth == 0 and mark_dirty:
		mark_world_dirty()

func mark_world_dirty() -> void:
	var chunks_x := int(ceil(float(width) / float(chunk_size)))
	var chunks_y := int(ceil(float(height) / float(chunk_size)))
	for cy in chunks_y:
		for cx in chunks_x:
			_dirty_chunk_keys[Vector2i(cx, cy)] = true
	world_reset.emit()

func chunk_rect(chunk: Vector2i) -> Rect2i:
	var x: int = chunk.x * chunk_size
	var y: int = chunk.y * chunk_size
	var w: int = mini(chunk_size, width - x)
	var h: int = mini(chunk_size, height - y)
	return Rect2i(x, y, w, h)

func carve_earth_cells(cells: Array[Vector2i]) -> int:
	var carved := 0
	for cell in cells:
		if not is_in_bounds(cell.x, cell.y):
			continue
		if get_material(cell.x, cell.y) != MaterialType.Id.EARTH:
			continue
		set_material(cell.x, cell.y, MaterialType.Id.EMPTY)
		carved += 1
	return carved

func carve_earth_cell(cell: Vector2i) -> bool:
	if not is_in_bounds(cell.x, cell.y):
		return false
	if get_material(cell.x, cell.y) != MaterialType.Id.EARTH:
		return false
	set_material(cell.x, cell.y, MaterialType.Id.EMPTY)
	return true

func is_frontier_earth_block(cell: Vector2i) -> bool:
	if not is_in_bounds(cell.x, cell.y):
		return false
	if get_material(cell.x, cell.y) != MaterialType.Id.EARTH:
		return false
	for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var neighbor := cell + offset
		if not is_in_bounds(neighbor.x, neighbor.y):
			continue
		if get_material(neighbor.x, neighbor.y) == MaterialType.Id.EMPTY:
			return true
	return false

func _default_flags_for_material(material: int) -> int:
	if material == MaterialType.Id.EARTH:
		return CellFlags.Id.BLOCKING | CellFlags.Id.DIGGABLE
	return CellFlags.Id.NONE

func _default_variant_for_material(index: int, material: int) -> int:
	if material == MaterialType.Id.EARTH:
		return clampi(variants[index], 0, Config.EARTH_VARIANT_COUNT - 1)
	return 0
