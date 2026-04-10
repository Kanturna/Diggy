extends Node2D
class_name CreatureManager

const Config = preload("res://core/Config.gd")
const CreatureAgentScript = preload("res://units/CreatureAgent.gd")
const CreatureGenomeScript = preload("res://units/CreatureGenome.gd")

var world: WorldModel
var rng := RandomNumberGenerator.new()
var creatures: Array[CreatureAgent] = []
var base_genome: CreatureGenome

func setup(world_model: WorldModel) -> void:
	world = world_model
	rng.seed = world.seed + 8192
	base_genome = CreatureGenomeScript.new(
		Config.CREATURE_BODY_WIDTH_CELLS,
		Config.CREATURE_BODY_LENGTH_CELLS,
		Config.CREATURE_TAIL_SEGMENTS,
		Config.CREATURE_SPEED_CELLS_PER_SECOND,
		Config.CREATURE_TURN_INTERVAL_MIN,
		Config.CREATURE_TURN_INTERVAL_MAX
	)
	_spawn_creatures(Config.CREATURE_SPAWN_COUNT)

func _spawn_creatures(count: int) -> void:
	var attempts := 0
	while creatures.size() < count and attempts < Config.CREATURE_SPAWN_ATTEMPTS:
		attempts += 1
		var cell := Vector2i(
			rng.randi_range(Config.CREATURE_SPAWN_PADDING_CELLS, world.width - Config.CREATURE_SPAWN_PADDING_CELLS - 1),
			rng.randi_range(Config.CREATURE_SPAWN_PADDING_CELLS, world.height - Config.CREATURE_SPAWN_PADDING_CELLS - 1)
		)
		if not _is_spawn_valid(cell):
			continue

		var creature := CreatureAgentScript.new()
		add_child(creature)
		creature.setup(world, base_genome, cell, rng.randi())
		creatures.append(creature)

func _is_spawn_valid(cell: Vector2i) -> bool:
	var world_position := CreatureAgentScript.cell_to_world(cell)
	if not CreatureAgentScript.can_occupy_world(
		world,
		world_position,
		Vector2.RIGHT,
		base_genome.body_width_cells,
		base_genome.body_length_cells
	):
		return false

	var minimum_distance := (base_genome.body_length_cells + base_genome.body_width_cells) * Config.CELL_SIZE
	for creature in creatures:
		if creature.global_position.distance_to(world_position) < minimum_distance:
			return false
	return true
