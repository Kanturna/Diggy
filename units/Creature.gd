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
const CARDINAL_DIRS: Array[Vector2i] = [
	Vector2i.RIGHT,
	Vector2i.DOWN,
	Vector2i.LEFT,
	Vector2i.UP,
]

enum Intent {
	WANDER,
	CHOOSE_FRONTIER,
	MOVE_TO_FRONTIER,
	DIG_BLOCK,
	SEEK_FOOD,
}

var velocity := Vector2.ZERO
var world: WorldModel = null
var cave_analysis: CaveRegionAnalysis = null

var _chain_pos: Array[Vector2] = []
var _chain_lag := [0.0, 0.18, 0.12, 0.22, 0.18]
var _facing_dir := Vector2.RIGHT
var _swim_phase := 0.0
var _polys: Array[PackedVector2Array] = []

var _intent := Intent.WANDER
var _current_action := "idle"
var _last_position := Vector2.ZERO
var _stuck_timer := 0.0
var _intent_timer := 0.0

var _current_snapshot: Dictionary = {}
var _traversal_plan: Dictionary = {}
var _current_path_index := 0
var _move_target_cell := Vector2i(-1, -1)
var _current_dig_cell := Vector2i(-1, -1)
var _dig_head_cell := Vector2i(-1, -1)
var _dig_direction := Vector2i.RIGHT
var _dig_progress := 0.0
var _replan_reason := "startup"
var _frontier_debug_entries: Array[Dictionary] = []
var _frontier_debug_min_score := 0.0
var _frontier_debug_max_score := 1.0

func _ready() -> void:
	_chain_pos.resize(5)
	_polys.resize(6)
	for i in 5:
		_chain_pos[i] = global_position
	for i in 6:
		_polys[i] = PackedVector2Array()
	_last_position = global_position
	_set_random_wander_target("startup")

func setup(world_model: WorldModel, analysis: CaveRegionAnalysis) -> void:
	world = world_model
	cave_analysis = analysis
	_last_position = global_position
	_request_frontier_plan("startup")

func _process(delta: float) -> void:
	_intent_timer -= delta
	if world != null and cave_analysis != null:
		match _intent:
			Intent.WANDER:
				_tick_wander(delta)
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
	var region_anchor: Vector2i = _current_snapshot.get("region_id_anchor", Vector2i(-1, -1))
	var staging_cell: Vector2i = _traversal_plan.get("staging_cell", Vector2i(-1, -1))
	var first_frontier_cell: Vector2i = _traversal_plan.get("first_frontier_cell", Vector2i(-1, -1))
	return {
		"intent": _intent_name(_intent),
		"action": _current_action,
		"target_cell": _move_target_cell,
		"frontier_cell": first_frontier_cell,
		"dig_cell": _current_dig_cell,
		"target_direction": _frontier_direction_vector(),
		"replan_in": maxf(_intent_timer, 0.0),
		"dig_progress": _dig_progress,
		"region_id_anchor": region_anchor,
		"region_size": int(_current_snapshot.get("region_size", 0)),
		"frontier_cluster_count": _snapshot_frontier_clusters().size(),
		"selected_cluster_id": str(_traversal_plan.get("cluster_id", "")),
		"staging_cell": staging_cell,
		"path_len": _plan_path_cells().size(),
		"path_index": _current_path_index,
		"first_frontier_cell": first_frontier_cell,
		"frontier_score": float(_traversal_plan.get("total_score", 0.0)),
		"frontier_prospect": float(_traversal_plan.get("prospect_score", 0.0)),
		"path_cost": int(_traversal_plan.get("path_cost", 0)),
		"replan_reason": _replan_reason,
	}

func get_frontier_debug_snapshot() -> Dictionary:
	return {
		"entries": _frontier_debug_entries,
		"min_score": _frontier_debug_min_score,
		"max_score": _frontier_debug_max_score,
		"selected_frontier_cell": _traversal_plan.get("first_frontier_cell", Vector2i(-1, -1)),
	}

func _tick_wander(delta: float) -> void:
	if _intent_timer <= 0.0:
		_request_frontier_plan("wander_retry")
		return

	var move_dir: Vector2 = _best_open_direction((_cell_center(_move_target_cell) - global_position).normalized())
	if move_dir == Vector2.ZERO:
		_set_random_wander_target("wander_blocked")
		return
	_move_along(move_dir, delta)
	_current_action = "move"

func _tick_choose_frontier() -> void:
	var origin_cell: Vector2i = _world_to_cell(global_position)
	if not _can_analyze_from_cell(origin_cell):
		_clear_frontier_debug_scores()
		_set_random_wander_target("choose_invalid_origin")
		return

	var snapshot := cave_analysis.get_region_snapshot(origin_cell)
	if snapshot.is_empty():
		_clear_frontier_debug_scores()
		_set_random_wander_target("choose_no_snapshot")
		return

	_current_snapshot = snapshot
	var reachability := cave_analysis.build_reachability(snapshot, origin_cell)
	var traversal_plan := _choose_best_traversal_plan(snapshot, reachability, origin_cell)
	if traversal_plan.is_empty():
		_set_random_wander_target("choose_no_reachable_frontier")
		return

	_adopt_traversal_plan(traversal_plan)
	if _plan_path_cells().size() <= 1:
		_start_dig_from_current_plan()

func _tick_move_to_frontier(delta: float) -> void:
	var replan_reason := _move_replan_reason()
	if not replan_reason.is_empty():
		_request_frontier_plan(replan_reason)
		return

	var path_cells := _plan_path_cells()
	if path_cells.is_empty():
		_request_frontier_plan("path_missing")
		return

	_advance_path_index(path_cells)
	if _is_at_staging_cell():
		_start_dig_from_current_plan()
		return

	if _current_path_index >= path_cells.size():
		_move_target_cell = _traversal_plan.get("staging_cell", Vector2i(-1, -1))
	else:
		_move_target_cell = path_cells[_current_path_index]

	var move_dir: Vector2 = _best_open_direction((_cell_center(_move_target_cell) - global_position).normalized())
	if move_dir == Vector2.ZERO:
		velocity = Vector2.ZERO
		return

	_move_along(move_dir, delta)
	_current_action = "move"
	_advance_path_index(path_cells)
	if _is_at_staging_cell():
		_start_dig_from_current_plan()

func _tick_dig_block(delta: float) -> void:
	if _traversal_plan.is_empty():
		_request_frontier_plan("dig_missing_plan")
		return

	if _current_dig_cell.x < 0:
		_current_dig_cell = _choose_next_dig_cell()
		_dig_progress = 0.0
		if _current_dig_cell.x < 0:
			_request_frontier_plan("dig_no_frontier")
			return

	if not world.is_frontier_earth_block(_current_dig_cell):
		_current_dig_cell = _choose_next_dig_cell()
		_dig_progress = 0.0
		if _current_dig_cell.x < 0:
			_request_frontier_plan("dig_invalid_frontier")
			return

	var dig_facing := (_cell_center(_current_dig_cell) - global_position).normalized()
	if dig_facing.length_squared() > 0.0001:
		_facing_dir = _facing_dir.slerp(dig_facing, clampf(16.0 * delta, 0.0, 1.0))
	velocity = Vector2.ZERO
	_current_action = "dig"
	_dig_progress += delta
	if _dig_progress < Config.CREATURE_DIG_BLOCK_SECONDS:
		return

	if world.carve_earth_cell(_current_dig_cell):
		_dig_head_cell = _current_dig_cell
		global_position = _cell_center(_dig_head_cell)
		_dig_progress = 0.0
		_current_dig_cell = Vector2i(-1, -1)
		if _has_broken_through():
			_request_frontier_plan("dig_breakthrough")
			return
	else:
		_dig_progress = 0.0
		_current_dig_cell = Vector2i(-1, -1)

func _choose_best_traversal_plan(snapshot: Dictionary, reachability: Dictionary, origin_cell: Vector2i) -> Dictionary:
	var best_plan: Dictionary = {}
	var best_zero_step_plan: Dictionary = {}
	var frontier_scores: Dictionary = {}
	for cluster in _snapshot_frontier_clusters():
		var staging_cells: Array[Vector2i] = _cluster_staging_cells(cluster)
		for staging_cell in staging_cells:
			var distance_map: Dictionary = reachability.get("distance", {})
			if not distance_map.has(staging_cell):
				continue

			var path_cells := cave_analysis.reconstruct_path(reachability, origin_cell, staging_cell)
			if path_cells.is_empty():
				continue

			var first_frontier_cell := _select_first_frontier_cell(cluster, staging_cell, path_cells)
			if first_frontier_cell.x < 0:
				continue

			var dig_direction: Vector2i = first_frontier_cell - staging_cell
			var path_cost := path_cells.size() - 1
			var alignment_score := _path_alignment_score(path_cells, dig_direction)
			var prospect_score := _prospect_frontier_score(first_frontier_cell, dig_direction, snapshot)
			var total_score := _frontier_total_score(path_cost, int(cluster.get("size", 0)), alignment_score, prospect_score)
			var candidate := {
				"revision": world.revision,
				"region_id_anchor": snapshot.get("region_id_anchor", Vector2i(-1, -1)),
				"cluster_id": str(cluster.get("cluster_id", "")),
				"cluster_size": int(cluster.get("size", 0)),
				"staging_cell": staging_cell,
				"path_cells": path_cells,
				"path_index": 1 if path_cells.size() > 1 else 0,
				"first_frontier_cell": first_frontier_cell,
				"dig_direction": dig_direction,
				"path_cost": path_cost,
				"alignment_score": alignment_score,
				"prospect_score": prospect_score,
				"total_score": total_score,
				"origin_region_lookup": snapshot.get("region_lookup", {}),
			}
			_record_frontier_score(frontier_scores, candidate)
			if path_cost == 0:
				if _is_better_traversal_candidate(candidate, best_zero_step_plan):
					best_zero_step_plan = candidate
				continue
			if _is_better_traversal_candidate(candidate, best_plan):
				best_plan = candidate
	_update_frontier_debug_scores(frontier_scores, best_plan if not best_plan.is_empty() else best_zero_step_plan)
	if not best_plan.is_empty():
		return best_plan
	return best_zero_step_plan

func _is_better_traversal_candidate(candidate: Dictionary, incumbent: Dictionary) -> bool:
	if incumbent.is_empty():
		return true

	var candidate_score := float(candidate.get("total_score", -INF))
	var incumbent_score := float(incumbent.get("total_score", -INF))
	if not is_equal_approx(candidate_score, incumbent_score):
		return candidate_score > incumbent_score

	var candidate_cluster_size := int(candidate.get("cluster_size", 0))
	var incumbent_cluster_size := int(incumbent.get("cluster_size", 0))
	if candidate_cluster_size != incumbent_cluster_size:
		return candidate_cluster_size > incumbent_cluster_size

	var candidate_alignment := float(candidate.get("alignment_score", -INF))
	var incumbent_alignment := float(incumbent.get("alignment_score", -INF))
	if not is_equal_approx(candidate_alignment, incumbent_alignment):
		return candidate_alignment > incumbent_alignment

	var candidate_staging: Vector2i = candidate.get("staging_cell", Vector2i(-1, -1))
	var incumbent_staging: Vector2i = incumbent.get("staging_cell", Vector2i(-1, -1))
	if candidate_staging != incumbent_staging:
		return _is_cell_before(candidate_staging, incumbent_staging)

	var candidate_frontier: Vector2i = candidate.get("first_frontier_cell", Vector2i(-1, -1))
	var incumbent_frontier: Vector2i = incumbent.get("first_frontier_cell", Vector2i(-1, -1))
	return _is_cell_before(candidate_frontier, incumbent_frontier)

func _select_first_frontier_cell(cluster: Dictionary, staging_cell: Vector2i, path_cells: Array[Vector2i]) -> Vector2i:
	var frontier_cells := _cluster_frontier_cells(cluster)
	var preferred_dir := _preferred_frontier_direction(path_cells)
	var best_cell := Vector2i(-1, -1)
	var best_alignment := -INF
	for frontier_cell in frontier_cells:
		if not _are_cells_adjacent(frontier_cell, staging_cell):
			continue
		var candidate_dir: Vector2i = frontier_cell - staging_cell
		var alignment := float(candidate_dir.x * preferred_dir.x + candidate_dir.y * preferred_dir.y)
		if alignment > best_alignment:
			best_alignment = alignment
			best_cell = frontier_cell
			continue
		if is_equal_approx(alignment, best_alignment) and _is_cell_before(frontier_cell, best_cell):
			best_cell = frontier_cell
	return best_cell

func _preferred_frontier_direction(path_cells: Array[Vector2i]) -> Vector2i:
	if path_cells.size() >= 2:
		var last_cell: Vector2i = path_cells[path_cells.size() - 1]
		var previous_cell: Vector2i = path_cells[path_cells.size() - 2]
		var path_dir := last_cell - previous_cell
		if path_dir != Vector2i.ZERO:
			return path_dir
	return _vector_to_cardinal(_facing_dir)

func _path_alignment_score(path_cells: Array[Vector2i], dig_direction: Vector2i) -> float:
	if path_cells.size() >= 2:
		var path_dir: Vector2i = path_cells[1] - path_cells[0]
		return float(path_dir.x * dig_direction.x + path_dir.y * dig_direction.y)
	var facing_cardinal := _vector_to_cardinal(_facing_dir)
	return float(facing_cardinal.x * dig_direction.x + facing_cardinal.y * dig_direction.y)

func _frontier_total_score(path_cost: int, cluster_size: int, alignment_score: float, prospect_score: float) -> float:
	return \
		prospect_score * Config.CREATURE_FRONTIER_PROSPECT_WEIGHT \
		- float(path_cost) * Config.CREATURE_FRONTIER_PATH_COST_WEIGHT \
		+ float(cluster_size) * Config.CREATURE_FRONTIER_CLUSTER_SIZE_WEIGHT \
		+ alignment_score * Config.CREATURE_FRONTIER_ALIGNMENT_WEIGHT

func _prospect_frontier_score(frontier_cell: Vector2i, dig_direction: Vector2i, snapshot: Dictionary) -> float:
	var origin_region_lookup: Dictionary = snapshot.get("region_lookup", {})
	var perpendicular := Vector2i(dig_direction.y, -dig_direction.x)
	var total_score := 0.0
	for step in range(1, Config.CREATURE_FRONTIER_PROSPECT_DEPTH + 1):
		var base_cell := frontier_cell + dig_direction * step
		var distance_weight := 1.0 - (float(step - 1) / float(Config.CREATURE_FRONTIER_PROSPECT_DEPTH))
		for lateral in range(-Config.CREATURE_FRONTIER_PROSPECT_LATERAL_RANGE, Config.CREATURE_FRONTIER_PROSPECT_LATERAL_RANGE + 1):
			var sample_cell := base_cell + perpendicular * lateral
			if not world.is_in_bounds(sample_cell.x, sample_cell.y):
				continue
			if world.get_material(sample_cell.x, sample_cell.y) != MaterialType.Id.EMPTY:
				continue
			if origin_region_lookup.has(sample_cell):
				continue

			var lateral_weight := 1.0 - (absf(float(lateral)) / float(Config.CREATURE_FRONTIER_PROSPECT_LATERAL_RANGE + 1))
			total_score += distance_weight * lateral_weight
			if lateral == 0:
				total_score += 0.35 * distance_weight
	}
	return total_score

func _record_frontier_score(frontier_scores: Dictionary, candidate: Dictionary) -> void:
	var frontier_cell: Vector2i = candidate.get("first_frontier_cell", Vector2i(-1, -1))
	if frontier_cell.x < 0:
		return
	if not frontier_scores.has(frontier_cell):
		frontier_scores[frontier_cell] = candidate
		return
	var incumbent: Dictionary = frontier_scores[frontier_cell]
	if float(candidate.get("total_score", -INF)) > float(incumbent.get("total_score", -INF)):
		frontier_scores[frontier_cell] = candidate

func _update_frontier_debug_scores(frontier_scores: Dictionary, selected_plan: Dictionary) -> void:
	_frontier_debug_entries.clear()
	_frontier_debug_min_score = 0.0
	_frontier_debug_max_score = 1.0
	if frontier_scores.is_empty():
		return

	var min_score := INF
	var max_score := -INF
	var selected_frontier_cell: Vector2i = selected_plan.get("first_frontier_cell", Vector2i(-1, -1))
	for frontier_cell_variant in frontier_scores.keys():
		var frontier_cell: Vector2i = frontier_cell_variant
		var candidate: Dictionary = frontier_scores[frontier_cell]
		var score := float(candidate.get("total_score", 0.0))
		min_score = minf(min_score, score)
		max_score = maxf(max_score, score)
		_frontier_debug_entries.append({
			"cell": frontier_cell,
			"score": score,
			"cluster_id": str(candidate.get("cluster_id", "")),
			"is_selected": frontier_cell == selected_frontier_cell,
		})

	_frontier_debug_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _is_cell_before(
			a.get("cell", Vector2i.ZERO),
			b.get("cell", Vector2i.ZERO)
		)
	)
	_frontier_debug_min_score = min_score
	_frontier_debug_max_score = max_score

func _clear_frontier_debug_scores() -> void:
	_frontier_debug_entries.clear()
	_frontier_debug_min_score = 0.0
	_frontier_debug_max_score = 1.0

func _adopt_traversal_plan(traversal_plan: Dictionary) -> void:
	_traversal_plan = traversal_plan
	_current_path_index = int(traversal_plan.get("path_index", 0))
	_move_target_cell = traversal_plan.get("staging_cell", Vector2i(-1, -1))
	_current_dig_cell = Vector2i(-1, -1)
	_dig_head_cell = Vector2i(-1, -1)
	_dig_direction = traversal_plan.get("dig_direction", Vector2i.RIGHT)
	_dig_progress = 0.0
	_intent = Intent.MOVE_TO_FRONTIER
	_current_action = "move"
	_stuck_timer = 0.0
	_replan_reason = "plan_committed"

func _request_frontier_plan(reason: String) -> void:
	_replan_reason = reason
	_traversal_plan.clear()
	_current_path_index = 0
	_move_target_cell = Vector2i(-1, -1)
	_current_dig_cell = Vector2i(-1, -1)
	_dig_head_cell = Vector2i(-1, -1)
	_dig_progress = 0.0
	_intent = Intent.CHOOSE_FRONTIER
	_current_action = "choose"
	_intent_timer = 0.0

func _set_random_wander_target(reason: String) -> void:
	_replan_reason = reason
	_intent = Intent.WANDER
	_current_action = "move"
	_intent_timer = randf_range(Config.CREATURE_TURN_INTERVAL_MIN, Config.CREATURE_TURN_INTERVAL_MAX)
	_move_target_cell = _world_to_cell(global_position + Vector2.from_angle(randf() * TAU) * Config.CELL_SIZE * 6.0)

func _move_replan_reason() -> String:
	if _traversal_plan.is_empty():
		return "no_plan"
	if int(_traversal_plan.get("revision", -1)) != world.revision:
		return "world_revision"
	if _stuck_timer >= Config.CREATURE_STUCK_REPLAN_SECONDS:
		return "stuck"

	var staging_cell: Vector2i = _traversal_plan.get("staging_cell", Vector2i(-1, -1))
	if not _is_empty_cell(staging_cell):
		return "staging_invalid"

	var path_cells := _plan_path_cells()
	if path_cells.is_empty():
		return "path_empty"

	for i in range(_current_path_index, path_cells.size()):
		if not _is_empty_cell(path_cells[i]):
			return "path_invalid"
	return ""

func _advance_path_index(path_cells: Array[Vector2i]) -> void:
	while _current_path_index < path_cells.size():
		if _distance_to_cell(path_cells[_current_path_index]) > Config.CREATURE_PATH_NODE_REACHED_CELLS:
			return
		_current_path_index += 1

func _is_at_staging_cell() -> bool:
	if _traversal_plan.is_empty():
		return false
	var staging_cell: Vector2i = _traversal_plan.get("staging_cell", Vector2i(-1, -1))
	if staging_cell.x < 0:
		return false
	return _distance_to_cell(staging_cell) <= Config.CREATURE_STAGING_REACHED_CELLS

func _start_dig_from_current_plan() -> void:
	if _traversal_plan.is_empty():
		_request_frontier_plan("dig_missing_plan")
		return
	if not _is_at_staging_cell():
		return

	var staging_cell: Vector2i = _traversal_plan.get("staging_cell", Vector2i(-1, -1))
	global_position = _cell_center(staging_cell)
	velocity = Vector2.ZERO
	_dig_head_cell = staging_cell
	_dig_direction = _traversal_plan.get("dig_direction", Vector2i.RIGHT)
	_current_dig_cell = _traversal_plan.get("first_frontier_cell", Vector2i(-1, -1))
	_dig_progress = 0.0
	_intent = Intent.DIG_BLOCK
	_current_action = "dig"

func _choose_next_dig_cell() -> Vector2i:
	var head_cell := _dig_head_cell
	if head_cell.x < 0:
		head_cell = _traversal_plan.get("staging_cell", Vector2i(-1, -1))
	if head_cell.x < 0:
		return Vector2i(-1, -1)

	var best_cell := Vector2i(-1, -1)
	var best_alignment := -INF
	for direction in CARDINAL_DIRS:
		var candidate: Vector2i = head_cell + direction
		if not world.is_frontier_earth_block(candidate):
			continue
		var alignment := float(direction.x * _dig_direction.x + direction.y * _dig_direction.y)
		if alignment > best_alignment:
			best_alignment = alignment
			best_cell = candidate
			continue
		if is_equal_approx(alignment, best_alignment) and _is_cell_before(candidate, best_cell):
			best_cell = candidate
	return best_cell

func _has_broken_through() -> bool:
	var origin_region_lookup: Dictionary = _traversal_plan.get("origin_region_lookup", {})
	for direction in CARDINAL_DIRS:
		var neighbor: Vector2i = _dig_head_cell + direction
		if not world.is_in_bounds(neighbor.x, neighbor.y):
			continue
		if world.get_material(neighbor.x, neighbor.y) != MaterialType.Id.EMPTY:
			continue
		if origin_region_lookup.has(neighbor):
			continue
		return true
	return false

func _snapshot_frontier_clusters() -> Array[Dictionary]:
	var clusters: Array[Dictionary] = []
	var clusters_variant = _current_snapshot.get("frontier_clusters", [])
	for cluster in clusters_variant:
		clusters.append(cluster)
	return clusters

func _cluster_frontier_cells(cluster: Dictionary) -> Array[Vector2i]:
	var frontier_cells: Array[Vector2i] = []
	var cells_variant = cluster.get("frontier_cells", [])
	for cell in cells_variant:
		frontier_cells.append(cell)
	return frontier_cells

func _cluster_staging_cells(cluster: Dictionary) -> Array[Vector2i]:
	var staging_cells: Array[Vector2i] = []
	var cells_variant = cluster.get("staging_cells", [])
	for cell in cells_variant:
		staging_cells.append(cell)
	return staging_cells

func _plan_path_cells() -> Array[Vector2i]:
	var path_cells: Array[Vector2i] = []
	var path_variant = _traversal_plan.get("path_cells", [])
	for cell in path_variant:
		path_cells.append(cell)
	return path_cells

func _can_analyze_from_cell(cell: Vector2i) -> bool:
	return world != null \
		and world.is_in_bounds(cell.x, cell.y) \
		and world.get_material(cell.x, cell.y) == MaterialType.Id.EMPTY

func _is_empty_cell(cell: Vector2i) -> bool:
	return world.is_in_bounds(cell.x, cell.y) and world.get_material(cell.x, cell.y) == MaterialType.Id.EMPTY

func _are_cells_adjacent(a: Vector2i, b: Vector2i) -> bool:
	return abs(a.x - b.x) + abs(a.y - b.y) == 1

func _vector_to_cardinal(direction: Vector2) -> Vector2i:
	if abs(direction.x) >= abs(direction.y):
		return Vector2i(1 if direction.x >= 0.0 else -1, 0)
	return Vector2i(0, 1 if direction.y >= 0.0 else -1)

static func _is_cell_before(a: Vector2i, b: Vector2i) -> bool:
	if b.x < 0 or b.y < 0:
		return true
	if a.y == b.y:
		return a.x < b.x
	return a.y < b.y

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

func _update_stuck_state(delta: float) -> void:
	var moved_distance := global_position.distance_to(_last_position)
	if moved_distance <= 0.05 and _intent == Intent.MOVE_TO_FRONTIER:
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
	return Vector2(float(_dig_direction.x), float(_dig_direction.y))

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
		Intent.CHOOSE_FRONTIER:
			return "choose_frontier"
		Intent.MOVE_TO_FRONTIER:
			return "move_to_frontier"
		Intent.DIG_BLOCK:
			return "dig_block"
		Intent.SEEK_FOOD:
			return "seek_food"
	return "unknown"
