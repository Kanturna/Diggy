extends RefCounted
class_name WorldGenerator

const MaterialType = preload("res://core/MaterialType.gd")
const CellFlags = preload("res://core/CellFlags.gd")
const Config = preload("res://core/Config.gd")

var last_profile := {}

func generate(world: WorldModel) -> void:
	var generate_begin_ms := Time.get_ticks_msec()
	world.begin_bulk_update()

	var step_begin_ms := Time.get_ticks_msec()
	_fill_with_earth(world)
	last_profile["fill_ms"] = Time.get_ticks_msec() - step_begin_ms

	step_begin_ms = Time.get_ticks_msec()
	_carve_noise_caves(world)
	last_profile["carve_ms"] = Time.get_ticks_msec() - step_begin_ms

	var smooth_total_ms := 0
	for _i in Config.CAVE_SMOOTH_PASSES:
		step_begin_ms = Time.get_ticks_msec()
		_smooth_pass(world)
		smooth_total_ms += Time.get_ticks_msec() - step_begin_ms
	last_profile["smooth_ms"] = smooth_total_ms

	step_begin_ms = Time.get_ticks_msec()
	_apply_variants(world)
	last_profile["variants_ms"] = Time.get_ticks_msec() - step_begin_ms
	world.end_bulk_update()
	last_profile["total_ms"] = Time.get_ticks_msec() - generate_begin_ms

func _fill_with_earth(world: WorldModel) -> void:
	var total_cells := world.width * world.height
	world.materials.fill(MaterialType.Id.EARTH)
	world.variants.fill(0)
	for i in total_cells:
		world.flags[i] = CellFlags.Id.BLOCKING | CellFlags.Id.DIGGABLE

func _carve_noise_caves(world: WorldModel) -> void:
	var noise := FastNoiseLite.new()
	noise.seed = world.seed
	noise.frequency = Config.CAVE_NOISE_FREQUENCY
	var width := world.width
	var materials := world.materials
	var variants := world.variants
	var flags := world.flags

	for y in world.height:
		for x in world.width:
			var n := (noise.get_noise_2d(x, y) + 1.0) * 0.5
			if n < Config.CAVE_EMPTY_THRESHOLD:
				var idx := y * width + x
				materials[idx] = MaterialType.Id.EMPTY
				variants[idx] = 0
				flags[idx] = CellFlags.Id.NONE

func _smooth_pass(world: WorldModel) -> void:
	var width := world.width
	var height := world.height
	var current_materials := world.materials
	var next_materials := PackedByteArray()
	next_materials.resize(width * height)

	for y in height:
		var row_offset := y * width
		var top_row_offset := row_offset - width
		var bottom_row_offset := row_offset + width
		var has_top := y > 0
		var has_bottom := y < height - 1
		for x in width:
			var idx := row_offset + x
			var has_left := x > 0
			var has_right := x < width - 1
			var solid_neighbors := 0

			if has_top:
				if has_left:
					solid_neighbors += int(current_materials[top_row_offset + x - 1] == MaterialType.Id.EARTH)
				else:
					solid_neighbors += 1
				solid_neighbors += int(current_materials[top_row_offset + x] == MaterialType.Id.EARTH)
				if has_right:
					solid_neighbors += int(current_materials[top_row_offset + x + 1] == MaterialType.Id.EARTH)
				else:
					solid_neighbors += 1
			else:
				solid_neighbors += 3

			if has_left:
				solid_neighbors += int(current_materials[row_offset + x - 1] == MaterialType.Id.EARTH)
			else:
				solid_neighbors += 1

			if has_right:
				solid_neighbors += int(current_materials[row_offset + x + 1] == MaterialType.Id.EARTH)
			else:
				solid_neighbors += 1

			if has_bottom:
				if has_left:
					solid_neighbors += int(current_materials[bottom_row_offset + x - 1] == MaterialType.Id.EARTH)
				else:
					solid_neighbors += 1
				solid_neighbors += int(current_materials[bottom_row_offset + x] == MaterialType.Id.EARTH)
				if has_right:
					solid_neighbors += int(current_materials[bottom_row_offset + x + 1] == MaterialType.Id.EARTH)
				else:
					solid_neighbors += 1
			else:
				solid_neighbors += 3

			var current := current_materials[idx]
			if solid_neighbors >= 5:
				next_materials[idx] = MaterialType.Id.EARTH
			elif current == MaterialType.Id.EMPTY:
				next_materials[idx] = MaterialType.Id.EMPTY
			else:
				next_materials[idx] = current

	for i in next_materials.size():
		if next_materials[i] == MaterialType.Id.EARTH:
			world.materials[i] = MaterialType.Id.EARTH
			world.flags[i] = CellFlags.Id.BLOCKING | CellFlags.Id.DIGGABLE
		else:
			world.materials[i] = MaterialType.Id.EMPTY
			world.variants[i] = 0
			world.flags[i] = CellFlags.Id.NONE

func _apply_variants(world: WorldModel) -> void:
	var base_noise := FastNoiseLite.new()
	base_noise.seed = world.seed + 1009
	base_noise.frequency = Config.CAVE_NOISE_FREQUENCY * 0.8

	var detail_noise := FastNoiseLite.new()
	detail_noise.seed = world.seed + 4271
	detail_noise.frequency = Config.CAVE_NOISE_FREQUENCY * 2.4
	var width := world.width
	var materials := world.materials
	var variants := world.variants

	for y in world.height:
		for x in world.width:
			var idx := y * width + x
			if materials[idx] != MaterialType.Id.EARTH:
				variants[idx] = 0
				continue
			var base_sample := (base_noise.get_noise_2d(x, y) + 1.0) * 0.5
			var detail_sample := (detail_noise.get_noise_2d(x, y) + 1.0) * 0.5
			var sample := base_sample * 0.72 + detail_sample * 0.28
			variants[idx] = clampi(int(floor(sample * Config.EARTH_VARIANT_COUNT)), 0, Config.EARTH_VARIANT_COUNT - 1)
