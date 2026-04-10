extends RefCounted
class_name WorldGenerator

const MaterialType = preload("res://core/MaterialType.gd")
const CellFlags = preload("res://core/CellFlags.gd")
const Config = preload("res://core/Config.gd")

func generate(world: WorldModel) -> void:
	_fill_with_earth(world)
	_carve_noise_caves(world)
	for _i in Config.CAVE_SMOOTH_PASSES:
		_smooth_pass(world)
	_apply_variants(world)
	world.mark_world_dirty()

func _fill_with_earth(world: WorldModel) -> void:
	for y in world.height:
		for x in world.width:
			world.set_cell(
				x,
				y,
				MaterialType.Id.EARTH,
				0,
				CellFlags.Id.BLOCKING | CellFlags.Id.DIGGABLE
			)

func _carve_noise_caves(world: WorldModel) -> void:
	var noise := FastNoiseLite.new()
	noise.seed = world.seed
	noise.frequency = Config.CAVE_NOISE_FREQUENCY

	for y in world.height:
		for x in world.width:
			var n := (noise.get_noise_2d(x, y) + 1.0) * 0.5
			if n < Config.CAVE_EMPTY_THRESHOLD:
				world.set_cell(x, y, MaterialType.Id.EMPTY, 0, CellFlags.Id.NONE)

func _smooth_pass(world: WorldModel) -> void:
	var next_materials := PackedByteArray()
	next_materials.resize(world.width * world.height)

	for y in world.height:
		for x in world.width:
			var solid_neighbors := _count_earth_neighbors(world, x, y)
			var idx := world.index_of(x, y)
			var current := world.materials[idx]
			if solid_neighbors >= 5:
				next_materials[idx] = MaterialType.Id.EARTH
			else:
				next_materials[idx] = MaterialType.Id.EMPTY if current == MaterialType.Id.EMPTY else current

	for y in world.height:
		for x in world.width:
			var idx := world.index_of(x, y)
			if next_materials[idx] == MaterialType.Id.EARTH:
				world.set_cell(x, y, MaterialType.Id.EARTH, world.variants[idx], CellFlags.Id.BLOCKING | CellFlags.Id.DIGGABLE)
			else:
				world.set_cell(x, y, MaterialType.Id.EMPTY, 0, CellFlags.Id.NONE)

func _count_earth_neighbors(world: WorldModel, x: int, y: int) -> int:
	var count := 0
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			if ox == 0 and oy == 0:
				continue
			var nx := x + ox
			var ny := y + oy
			if not world.is_in_bounds(nx, ny):
				count += 1
				continue
			if world.get_material(nx, ny) == MaterialType.Id.EARTH:
				count += 1
	return count

func _apply_variants(world: WorldModel) -> void:
	var base_noise := FastNoiseLite.new()
	base_noise.seed = world.seed + 1009
	base_noise.frequency = Config.CAVE_NOISE_FREQUENCY * 0.8

	var detail_noise := FastNoiseLite.new()
	detail_noise.seed = world.seed + 4271
	detail_noise.frequency = Config.CAVE_NOISE_FREQUENCY * 2.4

	for y in world.height:
		for x in world.width:
			var idx := world.index_of(x, y)
			if world.materials[idx] != MaterialType.Id.EARTH:
				world.variants[idx] = 0
				continue
			var base_sample := (base_noise.get_noise_2d(x, y) + 1.0) * 0.5
			var detail_sample := (detail_noise.get_noise_2d(x, y) + 1.0) * 0.5
			var sample := base_sample * 0.82 + detail_sample * 0.18
			world.variants[idx] = clampi(int(floor(sample * 6.0)), 0, 5)
