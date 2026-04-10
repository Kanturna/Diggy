extends Node2D
class_name UnitManager

const Config       = preload("res://core/Config.gd")
const MaterialType = preload("res://core/MaterialType.gd")
const CreatureGD   = preload("res://units/Creature.gd")

var _creatures: Array[Creature] = []

func setup(world_model: WorldModel) -> void:
	_spawn(world_model)

func _spawn(world: WorldModel) -> void:
	var tries   := 0
	var spawned := 0
	var pad     := Config.CREATURE_SPAWN_PADDING_CELLS
	while spawned < Config.CREATURE_SPAWN_COUNT and tries < Config.CREATURE_SPAWN_ATTEMPTS:
		tries += 1
		var cx := randi_range(pad, world.width  - pad - 1)
		var cy := randi_range(pad, world.height - pad - 1)
		if world.get_material(cx, cy) != MaterialType.Id.EMPTY:
			continue
		var c: Creature = CreatureGD.new()
		c.global_position = Vector2(
			(cx + 0.5) * Config.CELL_SIZE,
			(cy + 0.5) * Config.CELL_SIZE,
		)
		add_child(c)
		c.setup(world)
		_creatures.append(c)
		spawned += 1

func creature_count() -> int:
	return _creatures.size()

func debug_snapshot() -> Dictionary:
	if _creatures.is_empty():
		return {}
	return _creatures[0].get_debug_snapshot()
