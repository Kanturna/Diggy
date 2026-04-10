extends Node2D
class_name CreatureAgent

const Config = preload("res://core/Config.gd")
const MaterialType = preload("res://core/MaterialType.gd")

var world: WorldModel
var genome: CreatureGenome
var rng := RandomNumberGenerator.new()

var _move_dir := Vector2.RIGHT
var _heading := Vector2.RIGHT
var _turn_timer := 0.0
var _tail_phase := 0.0

func setup(world_model: WorldModel, creature_genome: CreatureGenome, spawn_cell: Vector2i, seed: int) -> void:
	world = world_model
	genome = creature_genome
	rng.seed = seed
	global_position = cell_to_world(spawn_cell)
	_move_dir = _random_direction()
	_heading = _move_dir
	_turn_timer = _random_turn_interval()
	queue_redraw()

func _process(delta: float) -> void:
	if world == null or genome == null:
		return

	_turn_timer -= delta
	if _turn_timer <= 0.0:
		_pick_new_direction()

	var target_position := global_position + _move_dir * genome.speed_cells_per_second * Config.CELL_SIZE * delta
	if can_occupy_world(world, target_position, _move_dir, genome.body_width_cells, genome.body_length_cells):
		global_position = target_position
	else:
		_pick_new_direction()

	if _move_dir.length_squared() > 0.0:
		_heading = _move_dir
	_tail_phase += delta * (4.5 + genome.speed_cells_per_second * 0.35)
	queue_redraw()

func _draw() -> void:
	if genome == null:
		return

	var half_width := genome.body_width_cells * Config.CELL_SIZE * 0.5
	var body_length := genome.body_length_cells * Config.CELL_SIZE
	var head_radius := half_width * 0.9
	var head_center := Vector2(body_length * 0.32, 0.0)
	var tail_base_x := -body_length * 0.2
	var tail_length := body_length * 0.95

	draw_set_transform(Vector2.ZERO, _heading.angle(), Vector2.ONE)

	for segment_idx in genome.tail_segments:
		var t := float(segment_idx) / maxf(float(genome.tail_segments - 1), 1.0)
		var x := lerpf(tail_base_x, tail_base_x - tail_length, t)
		var sway := sin(_tail_phase - t * 2.2) * half_width * 0.6 * (1.0 - t)
		var radius := lerpf(half_width * 0.55, half_width * 0.18, t)
		draw_circle(Vector2(x, sway), radius, genome.body_color.darkened(0.08 * t))

	draw_circle(Vector2.ZERO, half_width, genome.body_color)
	draw_circle(Vector2(-body_length * 0.16, 0.0), half_width * 0.9, genome.body_color.darkened(0.06))
	draw_circle(head_center, head_radius, genome.head_color)

	var jaw_base_x := head_center.x + head_radius * 0.55
	var jaw_tip_x := jaw_base_x + half_width * 0.95
	var jaw_spread := half_width * 0.68
	var jaw_gap := half_width * 0.22
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(jaw_base_x, -jaw_gap),
			Vector2(jaw_tip_x, -jaw_spread),
			Vector2(jaw_tip_x - half_width * 0.18, -jaw_gap * 0.45),
		]),
		genome.jaw_color
	)
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(jaw_base_x, jaw_gap),
			Vector2(jaw_tip_x, jaw_spread),
			Vector2(jaw_tip_x - half_width * 0.18, jaw_gap * 0.45),
		]),
		genome.jaw_color
	)

func _pick_new_direction() -> void:
	for _attempt in 8:
		var candidate_dir := _random_direction()
		if can_occupy_world(
			world,
			global_position + candidate_dir * Config.CELL_SIZE * 0.75,
			candidate_dir,
			genome.body_width_cells,
			genome.body_length_cells
		):
			_move_dir = candidate_dir
			_turn_timer = _random_turn_interval()
			return
	_move_dir = -_move_dir
	_turn_timer = _random_turn_interval()

func _random_direction() -> Vector2:
	var directions := [
		Vector2.RIGHT,
		Vector2.LEFT,
		Vector2.UP,
		Vector2.DOWN,
		Vector2(1, 1).normalized(),
		Vector2(1, -1).normalized(),
		Vector2(-1, 1).normalized(),
		Vector2(-1, -1).normalized(),
	]
	return directions[rng.randi_range(0, directions.size() - 1)]

func _random_turn_interval() -> float:
	return rng.randf_range(genome.turn_interval_min, genome.turn_interval_max)

static func cell_to_world(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2.ONE * 0.5) * Config.CELL_SIZE

static func can_occupy_world(
	world_model: WorldModel,
	world_position: Vector2,
	forward: Vector2,
	body_width_cells: float,
	body_length_cells: float
) -> bool:
	if world_model == null:
		return false

	var dir := forward.normalized()
	if dir.length_squared() == 0.0:
		dir = Vector2.RIGHT
	var perp := Vector2(-dir.y, dir.x)

	var half_width := body_width_cells * Config.CELL_SIZE * 0.5
	var body_length := body_length_cells * Config.CELL_SIZE
	var longitudinal_offsets: Array[float] = [
		-body_length * 0.45,
		-body_length * 0.15,
		body_length * 0.15,
		body_length * 0.45,
	]
	var lateral_offsets: Array[float] = [
		-half_width * 0.75,
		0.0,
		half_width * 0.75,
	]

	for x_offset in longitudinal_offsets:
		for y_offset in lateral_offsets:
			var sample_world: Vector2 = world_position + dir * x_offset + perp * y_offset
			var sample_cell: Vector2i = Vector2i(
				floor(sample_world.x / Config.CELL_SIZE),
				floor(sample_world.y / Config.CELL_SIZE)
			)
			if not world_model.is_in_bounds(sample_cell.x, sample_cell.y):
				return false
			if world_model.get_material(sample_cell.x, sample_cell.y) != MaterialType.Id.EMPTY:
				return false

	var head_sample: Vector2 = world_position + dir * body_length * 0.6
	var head_cell: Vector2i = Vector2i(
		floor(head_sample.x / Config.CELL_SIZE),
		floor(head_sample.y / Config.CELL_SIZE)
	)
	if not world_model.is_in_bounds(head_cell.x, head_cell.y):
		return false
	if world_model.get_material(head_cell.x, head_cell.y) != MaterialType.Id.EMPTY:
		return false

	return true
