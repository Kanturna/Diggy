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
const CARDINAL_DIRS: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]

enum Intent {
	WANDER,
	SURVEY_CAVE,
	CHOOSE_FRONTIER,
	MOVE_TO_FRONTIER,
	DIG_BLOCK,
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
var _current_action := "move"
var _last_position := Vector2.ZERO
var _stuck_timer := 0.0
var _intent_timer := 0.0

var _region_revision := -1
var _region_anchor := Vector2i(-1, -1)
var _region_members: Dictionary = {}
var _region_list: Array[Vector2i] = []

var _known_cave_anchor := Vector2i(-1, -1)
var _cave_scanned := false
var _survey_path: Array[Vector2i] = []
var _survey_index := 0
var _frontier_candidates: Array[Dictionary] = []
var _frontier_target: Dictionary = {}
var _move_target_cell := Vector2i(-1, -1)
var _dig_depth := 1
var _dig_row_pending: Array[Vector2i] = []
var _current_dig_cell := Vector2i(-1, -1)
var _dig_progress := 0.0

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
	_refresh_cave_context(true)

func _process(delta: float) -> void:
	_intent_timer -= delta
	if world != null:
		_refresh_cave_context(false)

	match _intent:
		Intent.WANDER:
			_tick_wander(delta)
		Intent.SURVEY_CAVE:
			_tick_survey(delta)
		Intent.CHOOSE_FRONTIER:
			_tick_choose_frontier()
		Intent.MOVE_TO_FRONTIER:
			_tick_move_to_frontier(delta)
		Intent.DIG_BLOCK:
			_tick_dig_block(delta)
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
		"target_cell": _move_target_cell,
		"frontier_cell": _frontier_target.get("entry_cell", Vector2i(-1, -1)),
		"dig_cell": _current_dig_cell,
		"target_direction": _frontier_direction_vector(),
		"replan_in": maxf(_intent_timer, 0.0),
		"cave_scanned": _cave_scanned,
		"survey_progress": "%d/%d" % [_survey_index, _survey_path.size()],
		"dig_progress": _dig_progress,
	}

func _refresh_cave_context(force_reset: bool) -> void:
	var origin_cell: Vector2i = _world_to_cell(global_position)
	if world == null or not world.is_in_bounds(origin_cell.x, origin_cell.y):
		return
	var region: Dictionary = _get_current_region(origin_cell)
	if region.is_empty():
		return

	var cave_changed: bool = force_reset or _known_cave_anchor.x < 0 or not region.has(_known_cave_anchor)
	if not cave_changed:
		return

	_known_cave_anchor = origin_cell
	_cave_scanned = false
	_survey_path = _build_survey_path(region)
	_survey_index = 0
	_frontier_candidates.clear()
	_frontier_target.clear()
	_move_target_cell = Vector2i(-1, -1)
	_current_dig_cell = Vector2i(-1, -1)
	_dig_depth = 1
	_dig_row_pending.clear()
	_dig_progress = 0.0
	_stuck_timer = 0.0

	if _survey_path.is_empty():
		_cave_scanned = true
		_intent = Intent.CHOOSE_FRONTIER
		_current_action = "choose"
	else:
		_intent = Intent.SURVEY_CAVE
		_current_action = "survey"
		_move_target_cell = _survey_path[0]

func _tick_wander(delta: float) -> void:
	if _intent_timer <= 0.0:
		_set_random_wander_target()
	var move_dir: Vector2 = _best_open_direction((_cell_center(_move_target_cell) - global_position).normalized())
	if move_dir == Vector2.ZERO:
		_set_random_wander_target()
		return
	_move_along(move_dir, delta)
	_current_action = "move"

func _tick_survey(delta: float) -> void:
	if _survey_index >= _survey_path.size():
		_cave_scanned = true
		_intent = Intent.CHOOSE_FRONTIER
		_current_action = "choose"
		return

	_move_target_cell = _survey_path[_survey_index]
	var move_dir: Vector2 = _best_open_direction((_cell_center(_move_target_cell) - global_position).normalized())
	if move_dir == Vector2.ZERO:
		_survey_index += 1
		return
	_move_along(move_dir, delta)
	_current_action = "survey"

	if _distance_to_cell(_move_target_cell) <= Config.CREATURE_SURVEY_REACHED_CELLS:
		_survey_index += 1
		if _survey_index >= _survey_path.size():
			_frontier_candidates = _collect_frontier_candidates()
			_cave_scanned = true
			_intent = Intent.CHOOSE_FRONTIER
			_current_action = "choose"

func _tick_choose_frontier() -> void:
	if _frontier_candidates.is_empty():
		_frontier_candidates = _collect_frontier_candidates()
	if _frontier_candidates.is_empty():
		_set_random_wander_target()
		return

	_frontier_target = _choose_best_frontier()
	if _frontier_target.is_empty():
		_set_random_wander_target()
		return

	var mouth_cells_variant = _frontier_target.get("mouth_cells", [])
	var mouth_cells: Array[Vector2i] = []
	for mouth_cell in mouth_cells_variant:
		mouth_cells.append(mouth_cell)
	_move_target_cell = mouth_cells[0] if not mouth_cells.is_empty() else _frontier_target.get("entry_cell", Vector2i(-1, -1))
	if mouth_cells.size() > 1 and _distance_to_cell(mouth_cells[1]) < _distance_to_cell(_move_target_cell):
		_move_target_cell = mouth_cells[1]
	_dig_depth = 1
	_dig_row_pending.clear()
	_current_dig_cell = Vector2i(-1, -1)
	_dig_progress = 0.0
	_intent = Intent.MOVE_TO_FRONTIER
	_intent_timer = Config.CREATURE_FRONTIER_REPLAN_SECONDS
	_current_action = "move"

func _tick_move_to_frontier(delta: float) -> void:
	if _frontier_target.is_empty():
		_intent = Intent.CHOOSE_FRONTIER
		return
	var move_dir: Vector2 = _best_open_direction((_cell_center(_move_target_cell) - global_position).normalized())
	if move_dir == Vector2.ZERO:
		if _stuck_timer >= Config.CREATURE_STUCK_REPLAN_SECONDS:
			_intent = Intent.CHOOSE_FRONTIER
		return
	_move_along(move_dir, delta)
	_current_action = "move"
	if _distance_to_cell(_move_target_cell) <= Config.CREATURE_TARGET_REACHED_CELLS:
		_intent = Intent.DIG_BLOCK
		_current_action = "dig"
		_dig_progress = 0.0
		_current_dig_cell = Vector2i(-1, -1)
		_dig_row_pending.clear()

func _tick_dig_block(delta: float) -> void:
	if _frontier_target.is_empty():
		_intent = Intent.CHOOSE_FRONTIER
		return
	if _external_target_reached():
		_refresh_cave_context(true)
		return

	if _current_dig_cell.x < 0:
		_current_dig_cell = _next_dig_cell()
		_dig_progress = 0.0
		if _current_dig_cell.x < 0:
			_intent = Intent.CHOOSE_FRONTIER
			_current_action = "choose"
			return

	if not world.is_frontier_earth_block(_current_dig_cell):
		_current_dig_cell = Vector2i(-1, -1)
		_dig_progress = 0.0
		return

	velocity = Vector2.ZERO
	_current_action = "dig"
	_dig_progress += delta
	if _dig_progress < Config.CREATURE_DIG_BLOCK_SECONDS:
		return

	var carved := world.carve_earth_cell(_current_dig_cell)
	_dig_progress = 0.0
	if carved:
		_invalidate_region_cache()
		_region_revision = -1
	_current_dig_cell = Vector2i(-1, -1)

	if _external_target_reached():
		_refresh_cave_context(true)
		return

func _collect_frontier_candidates() -> Array[Dictionary]:
	var region_map := _region_members
	var candidates: Array[Dictionary] = []
	var seen: Dictionary = {}
	for cell in _survey_path:
		for direction in CARDINAL_DIRS:
			var front_block: Vector2i = cell + direction
			if not world.is_frontier_earth_block(front_block):
				continue
			var perpendicular: Vector2i = Vector2i(direction.y, -direction.x)
			for side_sign in [-1, 1]:
				var second_mouth: Vector2i = cell + perpendicular * side_sign
				if not region_map.has(second_mouth):
					continue
				var second_front: Vector2i = second_mouth + direction
				if not world.is_frontier_earth_block(second_front):
					continue
				var key := "%s|%s|%s" % [cell, second_mouth, direction]
				if seen.has(key):
					continue
				var external: Vector2i = _find_external_empty_for_frontier(cell, direction, region_map)
				if external.x < 0:
					continue
				seen[key] = true
				candidates.append({
					"entry_cell": cell,
					"mouth_cells": [cell, second_mouth],
					"direction": direction,
					"external_cell": external,
				})
	return candidates

func _choose_best_frontier() -> Dictionary:
	var best: Dictionary = {}
	var best_score := -INF
	for candidate in _frontier_candidates:
		var entry_cell: Vector2i = candidate.get("entry_cell", Vector2i(-1, -1))
		var external_cell: Vector2i = candidate.get("external_cell", Vector2i(-1, -1))
		if entry_cell.x < 0 or external_cell.x < 0:
			continue
		var to_external := Vector2(
			float(external_cell.x - entry_cell.x),
			float(external_cell.y - entry_cell.y)
		)
		var distance_score := 1.0 / maxf(to_external.length(), 1.0)
		var direction_value: Vector2i = candidate.get("direction", Vector2i.RIGHT)
		var direction_vec: Vector2 = Vector2(float(direction_value.x), float(direction_value.y)).normalized()
		var alignment_score := 0.5
		if _facing_dir.length_squared() > 0.0001:
			alignment_score = (_facing_dir.normalized().dot(direction_vec) + 1.0) * 0.5
		var score := distance_score * Config.CREATURE_CONNECT_DISTANCE_WEIGHT
		score += alignment_score * Config.CREATURE_CONNECT_ALIGNMENT_WEIGHT
		if score > best_score:
			best_score = score
			best = candidate
	return best

func _find_external_empty_for_frontier(entry_cell: Vector2i, direction: Vector2i, region_map: Dictionary) -> Vector2i:
	var radius := Config.CREATURE_PERCEPTION_RADIUS_CELLS
	var best_distance := INF
	var best_cell := Vector2i(-1, -1)
	var origin := Vector2(float(entry_cell.x), float(entry_cell.y))
	var desired := Vector2(float(direction.x), float(direction.y))
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx == 0 and dy == 0:
				continue
			if dx * dx + dy * dy > radius * radius:
				continue
			var candidate := entry_cell + Vector2i(dx, dy)
			if not world.is_in_bounds(candidate.x, candidate.y):
				continue
			if world.get_material(candidate.x, candidate.y) != MaterialType.Id.EMPTY:
				continue
			if region_map.has(candidate):
				continue
			var delta := Vector2(float(candidate.x), float(candidate.y)) - origin
			if desired.dot(delta.normalized()) < 0.45:
				continue
			var distance := delta.length()
			if distance < best_distance:
				best_distance = distance
				best_cell = candidate
	return best_cell

func _next_dig_cell() -> Vector2i:
	while true:
		if not _dig_row_pending.is_empty():
			return _dig_row_pending.pop_front()
		var next_row: Array[Vector2i] = _build_dig_row(_dig_depth)
		if next_row.is_empty():
			return Vector2i(-1, -1)
		_dig_depth += 1
		_dig_row_pending = next_row
	return Vector2i(-1, -1)

func _build_dig_row(depth: int) -> Array[Vector2i]:
	if _frontier_target.is_empty():
		return []
	var mouth_cells_variant = _frontier_target.get("mouth_cells", [])
	var mouth_cells: Array[Vector2i] = []
	for mouth_cell in mouth_cells_variant:
		mouth_cells.append(mouth_cell)
	var direction: Vector2i = _frontier_target.get("direction", Vector2i.RIGHT)
	var row: Array[Vector2i] = []
	for mouth in mouth_cells:
		var block := mouth + direction * depth
		if not world.is_in_bounds(block.x, block.y):
			continue
		if world.get_material(block.x, block.y) == MaterialType.Id.EARTH and world.is_frontier_earth_block(block):
			if not row.has(block):
				row.append(block)
	return row

func _external_target_reached() -> bool:
	if _frontier_target.is_empty():
		return false
	var external_cell: Vector2i = _frontier_target.get("external_cell", Vector2i(-1, -1))
	if external_cell.x < 0:
		return false
	var origin_cell: Vector2i = _world_to_cell(global_position)
	var region: Dictionary = _get_current_region(origin_cell)
	return region.has(external_cell)

func _build_survey_path(region: Dictionary) -> Array[Vector2i]:
	var boundary: Array[Vector2i] = []
	for cell in region.keys():
		var current: Vector2i = cell
		for offset in CARDINAL_DIRS:
			var neighbor: Vector2i = current + offset
			if not world.is_in_bounds(neighbor.x, neighbor.y):
				continue
			if world.get_material(neighbor.x, neighbor.y) == MaterialType.Id.EARTH:
				boundary.append(current)
				break
	if boundary.is_empty():
		return boundary

	var ordered: Array[Vector2i] = []
	var remaining: Array[Vector2i] = boundary.duplicate()
	var current_pick: Vector2i = _world_to_cell(global_position)
	while not remaining.is_empty():
		var best_index := 0
		var best_distance := INF
		for i in range(remaining.size()):
			var candidate: Vector2i = remaining[i]
			var distance := current_pick.distance_squared_to(candidate)
			if distance < best_distance:
				best_distance = distance
				best_index = i
		current_pick = remaining[best_index]
		ordered.append(current_pick)
		remaining.remove_at(best_index)
	return ordered

func _set_random_wander_target() -> void:
	_intent = Intent.WANDER
	_current_action = "move"
	_intent_timer = randf_range(Config.CREATURE_TURN_INTERVAL_MIN, Config.CREATURE_TURN_INTERVAL_MAX)
	_move_target_cell = _world_to_cell(global_position + Vector2.from_angle(randf() * TAU) * Config.CELL_SIZE * 6.0)

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
	var members: Array[Vector2i] = []
	if world.get_material(origin_cell.x, origin_cell.y) != MaterialType.Id.EMPTY:
		_region_members = visited
		_region_list = members
		_region_anchor = origin_cell
		_region_revision = world.revision
		return visited

	var queue: Array[Vector2i] = [origin_cell]
	var queue_index := 0
	visited[origin_cell] = true
	members.append(origin_cell)

	while queue_index < queue.size():
		var cell: Vector2i = queue[queue_index]
		queue_index += 1
		for offset in CARDINAL_DIRS:
			var next_cell: Vector2i = cell + offset
			if next_cell.x < min_x or next_cell.x > max_x or next_cell.y < min_y or next_cell.y > max_y:
				continue
			if visited.has(next_cell):
				continue
			if world.get_material(next_cell.x, next_cell.y) != MaterialType.Id.EMPTY:
				continue
			visited[next_cell] = true
			members.append(next_cell)
			queue.append(next_cell)

	_region_members = visited
	_region_list = members
	_region_anchor = origin_cell
	_region_revision = world.revision
	return visited

func _invalidate_region_cache() -> void:
	_region_revision = -1
	_region_anchor = Vector2i(-1, -1)
	_region_members.clear()
	_region_list.clear()

func _update_stuck_state(delta: float) -> void:
	var moved_distance := global_position.distance_to(_last_position)
	if moved_distance <= 0.05 and (_intent == Intent.SURVEY_CAVE or _intent == Intent.MOVE_TO_FRONTIER):
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

func _frontier_direction_vector() -> Vector2:
	if _frontier_target.is_empty():
		return Vector2.ZERO
	var direction: Vector2i = _frontier_target.get("direction", Vector2i.ZERO)
	return Vector2(float(direction.x), float(direction.y))

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
		Intent.SURVEY_CAVE:
			return "survey_cave"
		Intent.CHOOSE_FRONTIER:
			return "choose_frontier"
		Intent.MOVE_TO_FRONTIER:
			return "move_to_frontier"
		Intent.DIG_BLOCK:
			return "dig_block"
		Intent.SEEK_FOOD:
			return "seek_food"
	return "unknown"
