extends Node2D
class_name Creature

const MaterialType = preload("res://core/MaterialType.gd")
const Config = preload("res://core/Config.gd")

const LOWER_R := 1.15
const UPPER_R := 1.00
const TAIL_R1 := 0.75
const TAIL_R2 := 0.50
const JAW_R := 0.42

const HEAD_FORWARD := 0.90
const TAIL_BASE_OFF := 0.90
const TAIL1_EXTRA := 0.25
const SEG_GAP1 := 1.50
const SEG_GAP2 := 1.80
const JAW_FORWARD_MUL := 0.95
const JAW_SPREAD_MUL := 0.65

const TAIL1_ATTACH := 0.55
const TAIL2_ATTACH := 0.55
const TAIL1_AXIS := 0.50
const TAIL2_AXIS := 0.60

const SWIM_MIN := 2.5
const SWIM_MAX := 5.5
const SWAY1_MULT := 0.9
const SWAY2_MULT := 1.4
const PHASE_OFF := PI * 0.45
const MIN_SWIM_SPEED := 3.0

const SPEED := Config.CREATURE_SPEED_CELLS_PER_SECOND * Config.CELL_SIZE
const BASE_COLOR := Color(0.87, 0.93, 0.79)
const STEER_ANGLES := [
	0.0,
	PI * 0.125,
	-PI * 0.125,
	PI * 0.25,
	-PI * 0.25,
	PI * 0.375,
	-PI * 0.375,
]

enum Intent {
	WANDER,
	CONNECT_CAVE,
	DIG,
	SEEK_FOOD,
}

var velocity := Vector2.ZERO
var world: WorldModel = null

var _chain_pos: Array[Vector2] = []
var _chain_lag := [0.0, 0.18, 0.12, 0.22, 0.18]
var _facing_dir := Vector2.RIGHT
var _swim_phase := 0.0
var _polys: Array[PackedVector2Array] = []

var _intent := Intent.WANDER
var _intent_timer := 0.0
var _target_direction := Vector2.RIGHT
var _target_cell := Vector2i(-1, -1)
var _target_world := Vector2.ZERO
var _current_action := "move"
var _dig_cooldown := 0.0
var _stuck_timer := 0.0
var _last_position := Vector2.ZERO
var _region_revision := -1
var _region_anchor := Vector2i(-1, -1)
var _region_members: Dictionary = {}

func _ready() -> void:
	_chain_pos.resize(5)
	_polys.resize(6)
	for i in 5:
		_chain_pos[i] = global_position
	for i in 6:
		_polys[i] = PackedVector2Array()
	_last_position = global_position
	_set_random_wander_target()

func setup(world_model: WorldModel) -> void:
	world = world_model
	_last_position = global_position
	_plan_next_intent(true)

func _process(delta: float) -> void:
	_dig_cooldown = maxf(0.0, _dig_cooldown - delta)
	_intent_timer -= delta

	if _needs_replan():
		_plan_next_intent(false)

	match _intent:
		Intent.WANDER:
			_tick_wander(delta)
		Intent.CONNECT_CAVE:
			_tick_connect(delta)
		Intent.DIG:
			_tick_dig(delta)
		Intent.SEEK_FOOD:
			_tick_wander(delta)

	_update_stuck_state(delta)
	_update_chain(delta)
	_rebuild_polys()
	queue_redraw()

func get_debug_snapshot() -> Dictionary:
	return {
		"intent": _intent_name(_intent),
		"action": _current_action,
		"target_cell": _target_cell,
		"target_direction": _target_direction,
		"replan_in": maxf(_intent_timer, 0.0),
	}

func _needs_replan() -> bool:
	if world == null:
		return false
	if _intent_timer <= 0.0:
		return true
	if _stuck_timer >= Config.CREATURE_STUCK_REPLAN_SECONDS:
		return true
	if _intent == Intent.CONNECT_CAVE or _intent == Intent.DIG:
		if _target_cell.x < 0:
			return true
		if _distance_to_cell(_target_cell) <= Config.CREATURE_TARGET_REACHED_CELLS:
			return true
		if _intent == Intent.CONNECT_CAVE and not _has_external_target():
			return true
	return false

func _plan_next_intent(force_wander: bool) -> void:
	_stuck_timer = 0.0
	if world == null or force_wander:
		_set_random_wander_target()
		return

	var candidate: Dictionary = _find_external_cave_target()
	if candidate.is_empty():
		_set_random_wander_target()
		return

	_intent = Intent.CONNECT_CAVE
	_target_cell = candidate.get("cell", Vector2i(-1, -1))
	_target_world = _cell_center(_target_cell)
	_target_direction = candidate.get("direction", Vector2.RIGHT)
	_intent_timer = randf_range(Config.CREATURE_TARGET_HOLD_MIN, Config.CREATURE_TARGET_HOLD_MAX)
	_current_action = "move"

func _set_random_wander_target() -> void:
	_intent = Intent.WANDER
	_target_direction = Vector2.from_angle(randf() * TAU).normalized()
	_target_world = global_position + _target_direction * Config.CELL_SIZE * 6.0
	_target_cell = _world_to_cell(_target_world)
	_intent_timer = randf_range(Config.CREATURE_TURN_INTERVAL_MIN, Config.CREATURE_TURN_INTERVAL_MAX)
	_current_action = "move"

func _tick_wander(delta: float) -> void:
	var move_dir: Vector2 = _best_open_direction(_target_direction)
	if move_dir == Vector2.ZERO:
		_set_random_wander_target()
		return
	_move_along(move_dir, delta)
	_current_action = "move"

func _tick_connect(delta: float) -> void:
	if _target_cell.x < 0:
		_plan_next_intent(false)
		return
	var desired_dir: Vector2 = (_target_world - global_position).normalized()
	if desired_dir.length_squared() <= 0.0001:
		_plan_next_intent(false)
		return
	_target_direction = desired_dir
	var move_dir: Vector2 = _best_open_direction(desired_dir)
	if move_dir != Vector2.ZERO:
		_move_along(move_dir, delta)
		_current_action = "move"
		return
	velocity = Vector2.ZERO
	_intent = Intent.DIG
	_current_action = "dig"

func _tick_dig(delta: float) -> void:
	var desired_dir: Vector2 = _target_direction
	if _target_cell.x >= 0:
		var target_delta: Vector2 = _target_world - global_position
		if target_delta.length_squared() > 0.0001:
			desired_dir = target_delta.normalized()
			_target_direction = desired_dir
	if _dig_cooldown > 0.0:
		velocity = Vector2.ZERO
		_current_action = "dig"
		return
	var carved: int = _dig_toward(desired_dir)
	_dig_cooldown = Config.CREATURE_DIG_INTERVAL
	if carved > 0:
		_current_action = "dig"
		_invalidate_region_cache()
	var move_dir: Vector2 = _best_open_direction(desired_dir)
	if move_dir != Vector2.ZERO:
		_intent = Intent.CONNECT_CAVE
		_move_along(move_dir, delta)
		_current_action = "move"
		return
	velocity = Vector2.ZERO

func _move_along(direction: Vector2, delta: float) -> void:
	if direction.length_squared() <= 0.0001:
		velocity = Vector2.ZERO
		return
	velocity = direction.normalized() * SPEED
	var next_position: Vector2 = global_position + velocity * delta
	if _passable(next_position):
		global_position = next_position
	else:
		velocity = Vector2.ZERO

func _best_open_direction(desired_dir: Vector2) -> Vector2:
	if desired_dir.length_squared() <= 0.0001:
		return Vector2.ZERO
	var best_dir := Vector2.ZERO
	var best_score := -INF
	for angle in STEER_ANGLES:
		var candidate_dir: Vector2 = desired_dir.rotated(angle).normalized()
		var candidate_pos: Vector2 = global_position + candidate_dir * Config.CELL_SIZE
		if not _passable(candidate_pos):
			continue
		var score := candidate_dir.dot(desired_dir)
		if score > best_score:
			best_score = score
			best_dir = candidate_dir
	return best_dir

func _find_external_cave_target() -> Dictionary:
	var origin_cell: Vector2i = _world_to_cell(global_position)
	if not world.is_in_bounds(origin_cell.x, origin_cell.y):
		return {}
	var region: Dictionary = _get_current_region(origin_cell)
	if region.is_empty():
		return {}

	var radius := Config.CREATURE_PERCEPTION_RADIUS_CELLS
	var current_dir := _facing_dir.normalized() if _facing_dir.length_squared() > 0.0001 else _target_direction
	var best_score := -INF
	var best_cell := Vector2i(-1, -1)
	var best_dir := Vector2.ZERO

	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx == 0 and dy == 0:
				continue
			var candidate: Vector2i = origin_cell + Vector2i(dx, dy)
			if not world.is_in_bounds(candidate.x, candidate.y):
				continue
			if dx * dx + dy * dy > radius * radius:
				continue
			if world.get_material(candidate.x, candidate.y) != MaterialType.Id.EMPTY:
				continue
			if region.has(candidate):
				continue
			var to_candidate := Vector2(dx, dy)
			var distance_score := 1.0 - clampf(to_candidate.length() / float(radius), 0.0, 1.0)
			var direction_score := 0.0
			if current_dir.length_squared() > 0.0001:
				direction_score = (current_dir.dot(to_candidate.normalized()) + 1.0) * 0.5
			var score := distance_score * Config.CREATURE_CONNECT_DISTANCE_WEIGHT
			score += direction_score * Config.CREATURE_CONNECT_ALIGNMENT_WEIGHT
			if score > best_score:
				best_score = score
				best_cell = candidate
				best_dir = to_candidate.normalized()

	if best_cell.x < 0:
		return {}
	return {
		"cell": best_cell,
		"direction": best_dir,
	}

func _get_current_region(origin_cell: Vector2i) -> Dictionary:
	if _region_revision == world.revision and _region_anchor == origin_cell and not _region_members.is_empty():
		return _region_members
	if _region_revision == world.revision and _region_members.has(origin_cell):
		return _region_members

	var bounds_radius := Config.CREATURE_PERCEPTION_RADIUS_CELLS + Config.CREATURE_REGION_MARGIN_CELLS
	var min_x := maxi(0, origin_cell.x - bounds_radius)
	var max_x := mini(world.width - 1, origin_cell.x + bounds_radius)
	var min_y := maxi(0, origin_cell.y - bounds_radius)
	var max_y := mini(world.height - 1, origin_cell.y + bounds_radius)

	var visited: Dictionary = {}
	if world.get_material(origin_cell.x, origin_cell.y) != MaterialType.Id.EMPTY:
		_region_members = visited
		_region_anchor = origin_cell
		_region_revision = world.revision
		return visited

	var queue: Array[Vector2i] = [origin_cell]
	var queue_index: int = 0
	visited[origin_cell] = true

	while queue_index < queue.size():
		var cell: Vector2i = queue[queue_index]
		queue_index += 1
		for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var next_cell: Vector2i = cell + offset
			if next_cell.x < min_x or next_cell.x > max_x or next_cell.y < min_y or next_cell.y > max_y:
				continue
			if visited.has(next_cell):
				continue
			if world.get_material(next_cell.x, next_cell.y) != MaterialType.Id.EMPTY:
				continue
			visited[next_cell] = true
			queue.append(next_cell)

	_region_members = visited
	_region_anchor = origin_cell
	_region_revision = world.revision
	return visited

func _invalidate_region_cache() -> void:
	_region_revision = -1
	_region_anchor = Vector2i(-1, -1)
	_region_members.clear()

func _has_external_target() -> bool:
	if _target_cell.x < 0:
		return false
	var origin_cell: Vector2i = _world_to_cell(global_position)
	var region: Dictionary = _get_current_region(origin_cell)
	return not region.has(_target_cell)

func _dig_toward(direction: Vector2) -> int:
	if world == null or direction.length_squared() <= 0.0001:
		return 0
	var forward: Vector2 = direction.normalized()
	var side: Vector2 = forward.orthogonal()
	var front_world: Vector2 = global_position + forward * (LOWER_R + Config.CELL_SIZE * 0.75)
	var half_width: float = Config.CREATURE_BODY_WIDTH_CELLS * 0.5
	var offsets: Array = [
		-half_width * 0.5,
		half_width * 0.5,
	]
	var cells_to_carve: Array[Vector2i] = []
	for row in 2:
		var row_forward: Vector2 = front_world + forward * (float(row) * Config.CELL_SIZE * 0.75)
		for offset_scale in offsets:
			var sample_world: Vector2 = row_forward + side * float(offset_scale) * Config.CELL_SIZE
			var sample_cell: Vector2i = _world_to_cell(sample_world)
			if not cells_to_carve.has(sample_cell):
				cells_to_carve.append(sample_cell)
	return world.carve_earth_cells(cells_to_carve)

func _update_stuck_state(delta: float) -> void:
	var moved_distance := global_position.distance_to(_last_position)
	if moved_distance <= 0.05 and (_intent == Intent.CONNECT_CAVE or _intent == Intent.DIG):
		_stuck_timer += delta
	else:
		_stuck_timer = 0.0
	_last_position = global_position

func _distance_to_cell(cell: Vector2i) -> float:
	return _cell_center(cell).distance_to(global_position) / float(Config.CELL_SIZE)

func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2(
		(cell.x + 0.5) * Config.CELL_SIZE,
		(cell.y + 0.5) * Config.CELL_SIZE
	)

func _world_to_cell(pos: Vector2) -> Vector2i:
	return Vector2i(
		int(floor(pos.x / Config.CELL_SIZE)),
		int(floor(pos.y / Config.CELL_SIZE))
	)

func _passable(pos: Vector2) -> bool:
	if world == null:
		return true
	var r := LOWER_R
	var x0 := int(floor((pos.x - r) / Config.CELL_SIZE))
	var x1 := int(floor((pos.x + r) / Config.CELL_SIZE))
	var y0 := int(floor((pos.y - r) / Config.CELL_SIZE))
	var y1 := int(floor((pos.y + r) / Config.CELL_SIZE))
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			if not world.is_in_bounds(cx, cy):
				return false
			if world.get_material(cx, cy) != MaterialType.Id.EMPTY:
				return false
	return true

func _update_chain(delta: float) -> void:
	_chain_pos[0] = global_position
	for i in range(1, 3):
		var blend := clampf(_chain_lag[i] * delta * 60.0, 0.0, 1.0)
		_chain_pos[i] = _chain_pos[i].lerp(_chain_pos[i - 1], blend)

	if velocity.length_squared() > 100.0:
		var target := velocity.normalized()
		_facing_dir = _facing_dir.slerp(target, clampf(8.0 * delta, 0.0, 1.0))
		if _facing_dir.length_squared() > 0.0001:
			_facing_dir = _facing_dir.normalized()

	var facing := _facing_dir.normalized() if _facing_dir.length_squared() > 0.0001 else Vector2.RIGHT
	var back := -facing
	var side := facing.orthogonal()
	var speed_ratio := clampf(velocity.length() / SPEED, 0.0, 1.0)

	if velocity.length() > MIN_SWIM_SPEED:
		_swim_phase += delta * lerpf(SWIM_MIN, SWIM_MAX, speed_ratio)

	var sway1 := sin(_swim_phase) * TAIL_R1 * SWAY1_MULT * speed_ratio
	var sway2 := sin(_swim_phase - PHASE_OFF) * TAIL_R1 * SWAY2_MULT * speed_ratio

	var ideal1 := _chain_pos[2] + back * (TAIL_BASE_OFF + TAIL_R1 * TAIL1_EXTRA) + side * sway1
	var ideal2 := ideal1 + back * (TAIL_R1 * SEG_GAP1 + TAIL_R2 * SEG_GAP2) + side * sway2

	_chain_pos[3] = _chain_pos[3].lerp(ideal1, clampf(_chain_lag[3] * delta * 60.0, 0.0, 1.0))
	_chain_pos[4] = _chain_pos[4].lerp(ideal2, clampf(_chain_lag[4] * delta * 60.0, 0.0, 1.0))

func _rebuild_polys() -> void:
	var facing := _facing_dir.normalized() if _facing_dir.length_squared() > 0.0001 else Vector2.RIGHT
	var back := -facing
	var side := facing.orthogonal()

	var lc2 := to_local(_chain_pos[2])
	var lc3 := to_local(_chain_pos[3])
	var lc4 := to_local(_chain_pos[4])

	var head_center := lc2 + facing * (LOWER_R * HEAD_FORWARD)
	var tail_base := lc2 + back * TAIL_BASE_OFF

	var tail1_center := tail_base.lerp(lc3, TAIL1_ATTACH)
	var tail2_center := tail1_center.lerp(lc4, TAIL2_ATTACH)

	var t1_raw := (tail1_center - tail_base).normalized()
	if t1_raw.length_squared() < 0.0001:
		t1_raw = back
	var t1_axis := back.slerp(t1_raw, TAIL1_AXIS).normalized()

	var t2_raw := (tail2_center - tail1_center).normalized()
	if t2_raw.length_squared() < 0.0001:
		t2_raw = t1_axis
	var t2_axis := t1_axis.slerp(t2_raw, TAIL2_AXIS).normalized()

	var jaw_base := head_center + facing * (UPPER_R * JAW_FORWARD_MUL)
	var jaw_spread := UPPER_R * JAW_SPREAD_MUL

	_polys[0] = _oval(tail2_center, TAIL_R2 * 1.20, TAIL_R2, t2_axis)
	_polys[1] = _oval(tail1_center, TAIL_R1 * 1.20, TAIL_R1, t1_axis)
	_polys[2] = _oval(lc2, LOWER_R * 1.30, LOWER_R, facing)
	_polys[3] = _oval(head_center, UPPER_R * 1.15, UPPER_R, facing)
	_polys[4] = _oval(jaw_base + side * jaw_spread, JAW_R * 1.2, JAW_R, facing)
	_polys[5] = _oval(jaw_base - side * jaw_spread, JAW_R * 1.2, JAW_R, facing)

static func _oval(center: Vector2, rx: float, ry: float, facing: Vector2, n: int = 12) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var side := facing.orthogonal()
	for i in n:
		var a := TAU * i / float(n)
		pts.append(center + facing * (cos(a) * rx) + side * (sin(a) * ry))
	return pts

func _draw() -> void:
	if _polys.is_empty() or _polys[0].is_empty():
		return
	draw_colored_polygon(_polys[0], BASE_COLOR.darkened(0.28))
	draw_colored_polygon(_polys[1], BASE_COLOR.darkened(0.18))
	draw_colored_polygon(_polys[2], BASE_COLOR)
	draw_colored_polygon(_polys[3], BASE_COLOR.darkened(0.10))
	draw_colored_polygon(_polys[4], BASE_COLOR.darkened(0.32))
	draw_colored_polygon(_polys[5], BASE_COLOR.darkened(0.32))

func _intent_name(intent: int) -> String:
	match intent:
		Intent.WANDER:
			return "wander"
		Intent.CONNECT_CAVE:
			return "connect_cave"
		Intent.DIG:
			return "dig"
		Intent.SEEK_FOOD:
			return "seek_food"
	return "unknown"
