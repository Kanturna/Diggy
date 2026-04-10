extends Node2D
class_name UnitManager

const Config       = preload("res://core/Config.gd")
const MaterialType = preload("res://core/MaterialType.gd")
const CreatureGD   = preload("res://units/Creature.gd")

const SPAWN_COUNT := 10

var _creatures: Array[Creature] = []

func setup(world_model: WorldModel) -> void:
	_spawn(world_model)

func _spawn(world: WorldModel) -> void:
	var tries   := 0
	var spawned := 0
	while spawned < SPAWN_COUNT and tries < 50000:
		tries += 1
		var cx := randi_range(2, world.width  - 3)
		var cy := randi_range(2, world.height - 3)
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
