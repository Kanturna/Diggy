extends Node2D
class_name Creature

const MaterialType = preload("res://core/MaterialType.gd")
const Config = preload("res://core/Config.gd")
const DigPlannerScript = preload("res://units/DigPlanner.gd")

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
const LOCAL_FRONTIER_SEARCH_STEPS := 3
const LOCAL_DIG_CONTINUE_STEPS := 1
const DIG_REEVAL_BLOCK_INTERVAL := 3
const CLUSTER_CROWDING_PENALTY := 0.55

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
var unit_manager: UnitManager = null
var _dig_planner: DigPlanner = null
var _decision_rng: RandomNumberGenerator = null

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
var _dig_advancing := false
var _dig_advance_target := Vector2.ZERO
var _dig_carved_lookup: Dictionary = {}
var _dig_blocks_since_recheck := 0
var _dig_pending_recheck := false
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

func setup(world_model: WorldModel, analysis: CaveRegionAnalysis, manager: UnitManager = null) -> void:
	world = world_model
	cave_analysis = analysis
	unit_manager = manager
	_dig_planner = DigPlannerScript.new()
	_decision_rng = RandomNumberGenerator.new()
	var spawn_cell := _world_to_cell(global_position)
	_decision_rng.seed = int(world.seed) \
		^ int(spawn_cell.x * 73856093) \
		^ int(spawn_cell.y * 19349663)
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
		"build_score": float(_traversal_plan.get("build_score", 0.0)),
		"sensor_score": float(_traversal_plan.get("sensor_score", 0.0)),
		"depth_score": float(_traversal_plan.get("depth_score", 0.0)),
		"continuity_score": float(_traversal_plan.get("continuity_score", 0.0)),
		"sensor_hollow_score": float(_traversal_plan.get("sensor_hollow_score", 0.0)),
		"sensor_open_span_score": float(_traversal_plan.get("sensor_open_span_score", 0.0)),
		"parallel_risk": float(_traversal_plan.get("parallel_risk", 0.0)),
		"niche_risk": float(_traversal_plan.get("niche_risk", 0.0)),
		"scrape_penalty": float(_traversal_plan.get("scrape_penalty", 0.0)),
		"frontier_crowding_penalty": float(_traversal_plan.get("crowding_penalty", 0.0)),
		"path_cost": int(_traversal_plan.get("path_cost", 0)),
		"selection_weight": float(_traversal_plan.get("selection_weight", 0.0)),
		"filter_reason": str(_traversal_plan.get("filter_reason", "")),
		"replan_reason": _replan_reason,
	}

func get_frontier_debug_snapshot() -> Dictionary:
	return {
		"entries": _frontier_debug_entries,
		"min_score": _frontier_debug_min_score,
		"max_score": _frontier_debug_max_score,
		"selected_frontier_cell": _traversal_plan.get("first_frontier_cell", Vector2i(-1, -1)),
	}

func _refresh_frontier_debug_from_origin(origin_cell: Vector2i) -> void:
	if cave_analysis == null or not _can_analyze_from_cell(origin_cell):
		return
	var snapshot: Dictionary = cave_analysis.get_region_snapshot(origin_cell)
	if snapshot.is_empty():
		return
	_current_snapshot = snapshot
	var reachability: Dictionary = _build_navigation_reachability(snapshot, origin_cell)
	_choose_best_traversal_plan(snapshot, reachability, origin_cell)

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

	var snapshot: Dictionary = cave_analysis.get_region_snapshot(origin_cell)
	if snapshot.is_empty():
		_clear_frontier_debug_scores()
		_set_random_wander_target("choose_no_snapshot")
		return

	_current_snapshot = snapshot
	var reachability: Dictionary = _build_navigation_reachability(snapshot, origin_cell)
	var traversal_plan: Dictionary = _choose_best_traversal_plan(snapshot, reachability, origin_cell)
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
		if _try_entry_fallback_dig():
			return
		if _try_local_frontier_dig_from_position():
			return
		velocity = Vector2.ZERO
		return

	_move_along(move_dir, delta)
	_current_action = "move"
	_advance_path_index(path_cells)
	if _is_at_staging_cell():
		_start_dig_from_current_plan()

func _tick_dig_block(delta: float) -> void:
	if _dig_advancing:
		var to_target := _dig_advance_target - global_position
		var dist := to_target.length()
		if dist <= SPEED * delta:
			global_position = _dig_advance_target
			velocity = Vector2.ZERO
			_dig_advancing = false
			if _dig_pending_recheck:
				_dig_pending_recheck = false
				_request_frontier_plan("dig_periodic_recheck")
				return
		else:
			velocity = to_target.normalized() * SPEED
			global_position += velocity * delta
		return

	if _traversal_plan.is_empty():
		_request_frontier_plan("dig_missing_plan")
		return

	if _current_dig_cell.x < 0:
		_current_dig_cell = _choose_next_dig_cell()
		_dig_progress = 0.0
		if _current_dig_cell.x < 0:
			if _try_continue_local_dig():
				return
			_request_frontier_plan("dig_no_frontier")
			return

	if not world.is_frontier_earth_block(_current_dig_cell):
		_current_dig_cell = _choose_next_dig_cell()
		_dig_progress = 0.0
		if _current_dig_cell.x < 0:
			if _try_continue_local_dig():
				return
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
		var carved_cell := _current_dig_cell
		var actual_dir := carved_cell - _dig_head_cell
		if actual_dir != Vector2i.ZERO:
			_dig_direction = actual_dir
		_dig_head_cell = carved_cell
		_dig_carved_lookup[carved_cell] = true
		_dig_advance_target = _cell_center(_dig_head_cell)
		_dig_advancing = true
		_dig_progress = 0.0
		_current_dig_cell = Vector2i(-1, -1)
		_dig_blocks_since_recheck += 1
		if _has_broken_through():
			_dig_advancing = false
			_request_frontier_plan("dig_breakthrough")
			return
		if _dig_blocks_since_recheck >= DIG_REEVAL_BLOCK_INTERVAL:
			_dig_blocks_since_recheck = 0
			_refresh_frontier_debug_from_origin(_dig_head_cell)
			_dig_pending_recheck = true
	else:
		_dig_progress = 0.0
		_current_dig_cell = Vector2i(-1, -1)

func _choose_best_traversal_plan(snapshot: Dictionary, reachability: Dictionary, origin_cell: Vector2i) -> Dictionary:
	return _choose_best_traversal_plan_with_limit(snapshot, reachability, origin_cell, -1)

func _choose_best_traversal_plan_with_limit(
	snapshot: Dictionary,
	reachability: Dictionary,
	origin_cell: Vector2i,
	max_path_cost: int
) -> Dictionary:
	var planner_result := _planner_result(snapshot, reachability, origin_cell, max_path_cost)
	var selected_candidate: Dictionary = planner_result.get("selected_candidate", {})
	if selected_candidate.is_empty():
		return {}
	return _traversal_plan_from_candidate(snapshot, reachability, origin_cell, selected_candidate)

func _planner_result(
	snapshot: Dictionary,
	reachability: Dictionary,
	origin_cell: Vector2i,
	max_path_cost: int
) -> Dictionary:
	if _dig_planner == null:
		_clear_frontier_debug_scores()
		return {}
	var planner_result := _dig_planner.choose_candidate(
		snapshot,
		reachability,
		origin_cell,
		_planner_reference_direction(),
		str(_traversal_plan.get("cluster_id", "")),
		Callable(self, "_cluster_crowding_penalty"),
		_decision_rng,
		max_path_cost
	)
	_update_frontier_debug_scores(planner_result)
	return planner_result

func _planner_reference_direction() -> Vector2i:
	if _dig_direction != Vector2i.ZERO:
		return _dig_direction
	return _vector_to_cardinal(_facing_dir)

func _traversal_plan_from_candidate(
	snapshot: Dictionary,
	reachability: Dictionary,
	origin_cell: Vector2i,
	candidate: Dictionary
) -> Dictionary:
	var staging_cell: Vector2i = candidate.get("staging_cell", Vector2i(-1, -1))
	if staging_cell.x < 0:
		return {}
	var path_cells := cave_analysis.reconstruct_path(reachability, origin_cell, staging_cell)
	if path_cells.is_empty():
		return {}
	return {
		"revision": world.revision,
		"region_id_anchor": snapshot.get("region_id_anchor", Vector2i(-1, -1)),
		"cluster_id": str(candidate.get("cluster_id", "")),
		"staging_cell": staging_cell,
		"path_cells": path_cells,
		"path_index": 1 if path_cells.size() > 1 else 0,
		"first_frontier_cell": candidate.get("frontier_cell", Vector2i(-1, -1)),
		"dig_direction": candidate.get("dig_direction", Vector2i.RIGHT),
		"path_cost": int(candidate.get("path_cost", 0)),
		"continuity_score": float(candidate.get("continuity_score", 0.0)),
		"depth_score": float(candidate.get("depth_score", 0.0)),
		"sensor_hollow_score": float(candidate.get("sensor_hollow_score", 0.0)),
		"sensor_open_span_score": float(candidate.get("sensor_open_span_score", 0.0)),
		"parallel_risk": float(candidate.get("parallel_risk", 0.0)),
		"niche_risk": float(candidate.get("niche_risk", 0.0)),
		"scrape_penalty": float(candidate.get("scrape_penalty", 0.0)),
		"build_score": float(candidate.get("build_score", 0.0)),
		"sensor_score": float(candidate.get("sensor_score", 0.0)),
		"crowding_penalty": float(candidate.get("crowding_penalty", 0.0)),
		"path_cost_penalty": float(candidate.get("path_cost_penalty", 0.0)),
		"selection_weight": float(candidate.get("selection_weight", 0.0)),
		"filter_reason": str(candidate.get("filter_reason", "")),
		"total_score": float(candidate.get("total_score", 0.0)),
		"origin_region_lookup": snapshot.get("region_lookup", {}),
	}

func _cluster_crowding_penalty(cluster_id: String) -> float:
	if unit_manager == null or cluster_id.is_empty():
		return 0.0
	# v1 keeps the old cluster-level crowding as a coarse soft claim only.
	return float(unit_manager.cluster_claim_count(cluster_id, self)) * CLUSTER_CROWDING_PENALTY

func _update_frontier_debug_scores(planner_result: Dictionary) -> void:
	_frontier_debug_entries.clear()
	_frontier_debug_min_score = 0.0
	_frontier_debug_max_score = 1.0
	if planner_result.is_empty():
		return
	var entries_variant = planner_result.get("entries", [])
	for entry_variant in entries_variant:
		_frontier_debug_entries.append(entry_variant)
	_frontier_debug_min_score = float(planner_result.get("min_score", 0.0))
	_frontier_debug_max_score = float(planner_result.get("max_score", 1.0))

func _clear_frontier_debug_scores() -> void:
	_frontier_debug_entries.clear()
	_frontier_debug_min_score = 0.0
	_frontier_debug_max_score = 1.0

func _build_navigation_reachability(snapshot: Dictionary, start_cell: Vector2i) -> Dictionary:
	var reachability: Dictionary = {
		"distance": {},
		"came_from": {},
	}
	var region_lookup: Dictionary = snapshot.get("region_lookup", {})
	if not region_lookup.has(start_cell):
		return reachability
	if not _is_navigable_cell(start_cell):
		return reachability

	var distance: Dictionary = reachability["distance"]
	var came_from: Dictionary = reachability["came_from"]
	var queue: Array[Vector2i] = [start_cell]
	var queue_index := 0
	distance[start_cell] = 0

	while queue_index < queue.size():
		var cell: Vector2i = queue[queue_index]
		queue_index += 1
		for direction in CARDINAL_DIRS:
			var next_cell: Vector2i = cell + direction
			if not region_lookup.has(next_cell):
				continue
			if distance.has(next_cell):
				continue
			if not _is_navigable_cell(next_cell):
				continue
			distance[next_cell] = int(distance[cell]) + 1
			came_from[next_cell] = cell
			queue.append(next_cell)
	return reachability

func _adopt_traversal_plan(traversal_plan: Dictionary) -> void:
	_traversal_plan = traversal_plan
	_current_path_index = int(traversal_plan.get("path_index", 0))
	_move_target_cell = traversal_plan.get("staging_cell", Vector2i(-1, -1))
	_current_dig_cell = Vector2i(-1, -1)
	_dig_head_cell = Vector2i(-1, -1)
	_dig_direction = traversal_plan.get("dig_direction", Vector2i.RIGHT)
	_dig_progress = 0.0
	_dig_advancing = false
	_dig_carved_lookup.clear()
	_dig_blocks_since_recheck = 0
	_dig_pending_recheck = false
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
	_dig_advancing = false
	_dig_carved_lookup.clear()
	_dig_blocks_since_recheck = 0
	_dig_pending_recheck = false
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
	if _stuck_timer >= Config.CREATURE_STUCK_REPLAN_SECONDS:
		return "stuck"

	var staging_cell: Vector2i = _traversal_plan.get("staging_cell", Vector2i(-1, -1))
	if not _is_navigable_cell(staging_cell):
		return "staging_invalid"

	var path_cells := _plan_path_cells()
	if path_cells.is_empty():
		return "path_empty"

	for i in range(_current_path_index, path_cells.size()):
		if not _is_navigable_cell(path_cells[i]):
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
	if _world_to_cell(global_position) == staging_cell:
		return true
	return _distance_to_cell(staging_cell) <= Config.CREATURE_STAGING_REACHED_CELLS

func _can_begin_dig_from_current_position() -> bool:
	if _traversal_plan.is_empty():
		return false
	var frontier_cell: Vector2i = _traversal_plan.get("first_frontier_cell", Vector2i(-1, -1))
	if frontier_cell.x < 0:
		return false
	if not world.is_frontier_earth_block(frontier_cell):
		return false

	var current_cell := _world_to_cell(global_position)
	if _is_empty_cell(current_cell) and _are_cells_adjacent(current_cell, frontier_cell):
		return true

	var staging_cell: Vector2i = _traversal_plan.get("staging_cell", Vector2i(-1, -1))
	if staging_cell.x < 0:
		return false
	if _distance_to_cell(staging_cell) > maxf(Config.CREATURE_STAGING_REACHED_CELLS, 0.8):
		return false
	return _is_empty_cell(current_cell) and _are_cells_adjacent(current_cell, frontier_cell)

func _effective_dig_head_cell() -> Vector2i:
	if _traversal_plan.is_empty():
		return Vector2i(-1, -1)

	var frontier_cell: Vector2i = _traversal_plan.get("first_frontier_cell", Vector2i(-1, -1))
	var current_cell := _world_to_cell(global_position)
	if frontier_cell.x >= 0 and _is_empty_cell(current_cell) and _are_cells_adjacent(current_cell, frontier_cell):
		return current_cell

	var staging_cell: Vector2i = _traversal_plan.get("staging_cell", Vector2i(-1, -1))
	if staging_cell.x >= 0 and _can_occupy_cell_center(staging_cell):
		return staging_cell

	if frontier_cell.x < 0:
		return Vector2i(-1, -1)

	var origin_region_lookup: Dictionary = _traversal_plan.get("origin_region_lookup", {})
	var best_cell := Vector2i(-1, -1)
	var best_distance := INF
	for direction in CARDINAL_DIRS:
		var candidate: Vector2i = frontier_cell + direction
		if not _can_occupy_cell_center(candidate):
			continue
		if not origin_region_lookup.is_empty() and not origin_region_lookup.has(candidate):
			continue
		var candidate_distance := _cell_center(candidate).distance_to(global_position)
		if candidate_distance < best_distance:
			best_distance = candidate_distance
			best_cell = candidate
	return best_cell

func _start_dig_from_current_plan() -> void:
	if _traversal_plan.is_empty():
		_request_frontier_plan("dig_missing_plan")
		return
	if not _is_at_staging_cell() and not _can_begin_dig_from_current_position():
		return

	var dig_head_cell := _effective_dig_head_cell()
	if dig_head_cell.x < 0:
		_request_frontier_plan("dig_missing_staging")
		return
	_enter_dig_state(dig_head_cell, _traversal_plan.get("first_frontier_cell", Vector2i(-1, -1)))

func _try_entry_fallback_dig() -> bool:
	if _traversal_plan.is_empty():
		return false
	var entry_cell: Vector2i = _traversal_plan.get("first_frontier_cell", Vector2i(-1, -1))
	if entry_cell.x < 0 or not world.is_frontier_earth_block(entry_cell):
		return false
	var current_cell := _world_to_cell(global_position)
	if not _is_empty_cell(current_cell):
		return false
	if not _are_cells_adjacent(current_cell, entry_cell):
		return false
	_enter_dig_state(current_cell, entry_cell)
	return _intent == Intent.DIG_BLOCK

func _try_local_frontier_dig_from_position() -> bool:
	var option := _find_local_frontier_option(_world_to_cell(global_position), LOCAL_FRONTIER_SEARCH_STEPS)
	if option.is_empty():
		return false
	_commit_local_frontier_option(option)
	_enter_dig_state(
		option.get("head_cell", Vector2i(-1, -1)),
		option.get("frontier_cell", Vector2i(-1, -1))
	)
	return _intent == Intent.DIG_BLOCK

func _try_continue_local_dig() -> bool:
	var origin_cell := _dig_head_cell if _dig_head_cell.x >= 0 else _world_to_cell(global_position)
	var option := _find_local_frontier_option(origin_cell, LOCAL_DIG_CONTINUE_STEPS)
	if option.is_empty():
		return false
	_commit_local_frontier_option(option)
	_adopt_local_dig_option(option)
	return _current_dig_cell.x >= 0

func _find_local_frontier_option(origin_cell: Vector2i, max_steps: int) -> Dictionary:
	if cave_analysis == null or not _can_analyze_from_cell(origin_cell):
		return {}

	var snapshot: Dictionary = cave_analysis.get_region_snapshot(origin_cell)
	if snapshot.is_empty():
		return {}
	var reachability: Dictionary = _build_navigation_reachability(snapshot, origin_cell)
	var planner_result := _planner_result(snapshot, reachability, origin_cell, max_steps)
	var selected_candidate: Dictionary = planner_result.get("selected_candidate", {})
	if selected_candidate.is_empty():
		return {}
	var path_cells := cave_analysis.reconstruct_path(
		reachability,
		origin_cell,
		selected_candidate.get("staging_cell", Vector2i(-1, -1))
	)
	if path_cells.is_empty():
		return {}
	var option := selected_candidate.duplicate()
	option["snapshot"] = snapshot
	option["head_cell"] = option.get("staging_cell", Vector2i(-1, -1))
	option["path_cells"] = path_cells
	return option

func _commit_local_frontier_option(option: Dictionary) -> void:
	var snapshot: Dictionary = option.get("snapshot", {})
	if not snapshot.is_empty():
		_current_snapshot = snapshot
		_traversal_plan["revision"] = snapshot.get("revision", world.revision)
		_traversal_plan["region_id_anchor"] = snapshot.get("region_id_anchor", Vector2i(-1, -1))
		_traversal_plan["origin_region_lookup"] = snapshot.get("region_lookup", {})
	var head_cell: Vector2i = option.get("head_cell", Vector2i(-1, -1))
	var frontier_cell: Vector2i = option.get("frontier_cell", Vector2i(-1, -1))
	if head_cell.x >= 0:
		_traversal_plan["staging_cell"] = head_cell
		_move_target_cell = head_cell
		var path_cells = option.get("path_cells", [head_cell])
		_traversal_plan["path_cells"] = path_cells
		_traversal_plan["path_index"] = 1 if path_cells.size() > 1 else 0
		_current_path_index = int(_traversal_plan["path_index"])
	if frontier_cell.x >= 0:
		_traversal_plan["first_frontier_cell"] = frontier_cell
		var dig_direction: Vector2i = frontier_cell - head_cell
		if dig_direction != Vector2i.ZERO:
			_traversal_plan["dig_direction"] = dig_direction
		_traversal_plan["continuity_score"] = float(option.get("continuity_score", 0.0))
		_traversal_plan["depth_score"] = float(option.get("depth_score", 0.0))
		_traversal_plan["sensor_hollow_score"] = float(option.get("sensor_hollow_score", 0.0))
		_traversal_plan["sensor_open_span_score"] = float(option.get("sensor_open_span_score", 0.0))
		_traversal_plan["parallel_risk"] = float(option.get("parallel_risk", 0.0))
		_traversal_plan["niche_risk"] = float(option.get("niche_risk", 0.0))
		_traversal_plan["scrape_penalty"] = float(option.get("scrape_penalty", 0.0))
		_traversal_plan["build_score"] = float(option.get("build_score", 0.0))
		_traversal_plan["sensor_score"] = float(option.get("sensor_score", 0.0))
		_traversal_plan["crowding_penalty"] = float(option.get("crowding_penalty", 0.0))
		_traversal_plan["path_cost_penalty"] = float(option.get("path_cost_penalty", 0.0))
		_traversal_plan["selection_weight"] = float(option.get("selection_weight", 0.0))
		_traversal_plan["filter_reason"] = str(option.get("filter_reason", ""))
		_traversal_plan["total_score"] = float(option.get("total_score", 0.0))
		_traversal_plan["path_cost"] = int(option.get("path_cost", 0))
	_traversal_plan["cluster_id"] = str(option.get("cluster_id", ""))

func _adopt_local_dig_option(option: Dictionary) -> void:
	var head_cell: Vector2i = option.get("head_cell", Vector2i(-1, -1))
	var frontier_cell: Vector2i = option.get("frontier_cell", Vector2i(-1, -1))
	if head_cell.x < 0 or frontier_cell.x < 0:
		return
	_commit_local_frontier_option(option)
	if head_cell != _dig_head_cell and _can_occupy_cell_center(head_cell):
		global_position = _cell_center(head_cell)
	_dig_head_cell = head_cell
	var dig_direction: Vector2i = frontier_cell - head_cell
	if dig_direction != Vector2i.ZERO:
		_dig_direction = dig_direction
	_current_dig_cell = frontier_cell
	_dig_progress = 0.0
	_dig_advancing = false
	_current_action = "dig"

func _enter_dig_state(dig_head_cell: Vector2i, dig_cell: Vector2i) -> void:
	if dig_head_cell.x < 0 or dig_cell.x < 0:
		_request_frontier_plan("dig_head_invalid")
		return
	var current_cell := _world_to_cell(global_position)
	if current_cell != dig_head_cell:
		if not _can_occupy_cell_center(dig_head_cell):
			_request_frontier_plan("dig_head_blocked")
			return
		global_position = _cell_center(dig_head_cell)
	elif not can_occupy_world(world, global_position):
		if not _can_occupy_cell_center(dig_head_cell):
			_request_frontier_plan("dig_head_blocked")
			return
		global_position = _cell_center(dig_head_cell)
	velocity = Vector2.ZERO
	_dig_head_cell = dig_head_cell
	var dig_direction: Vector2i = dig_cell - dig_head_cell
	if dig_direction == Vector2i.ZERO:
		dig_direction = _traversal_plan.get("dig_direction", Vector2i.RIGHT)
	_dig_direction = dig_direction
	_current_dig_cell = dig_cell
	_dig_progress = 0.0
	_dig_advancing = false
	_dig_carved_lookup.clear()
	_intent = Intent.DIG_BLOCK
	_current_action = "dig"

func _choose_next_dig_cell() -> Vector2i:
	var head_cell := _dig_head_cell
	if head_cell.x < 0:
		head_cell = _traversal_plan.get("staging_cell", Vector2i(-1, -1))
	if head_cell.x < 0:
		return Vector2i(-1, -1)
	var option := _find_local_frontier_option(head_cell, 0)
	if option.is_empty():
		return Vector2i(-1, -1)
	_commit_local_frontier_option(option)
	return option.get("frontier_cell", Vector2i(-1, -1))

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
		if _dig_carved_lookup.has(neighbor):
			continue
		return true
	return false

func _snapshot_frontier_clusters_from(snapshot: Dictionary) -> Array[Dictionary]:
	var clusters: Array[Dictionary] = []
	var clusters_variant = snapshot.get("frontier_clusters", [])
	for cluster in clusters_variant:
		clusters.append(cluster)
	return clusters

func _snapshot_frontier_clusters() -> Array[Dictionary]:
	return _snapshot_frontier_clusters_from(_current_snapshot)

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
		if _is_navigable_cell(cell):
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

func _is_navigable_cell(cell: Vector2i) -> bool:
	if not _is_empty_cell(cell):
		return false
	return _can_occupy_cell_center(cell)

func _can_occupy_cell_center(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0:
		return false
	return can_occupy_world(world, _cell_center(cell))

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
	return can_occupy_world(world, pos)

static func can_occupy_world(world_model: WorldModel, pos: Vector2) -> bool:
	if world_model == null:
		return false
	var r := LOWER_R
	var x0 := int(floor((pos.x - r) / Config.CELL_SIZE))
	var x1 := int(floor((pos.x + r) / Config.CELL_SIZE))
	var y0 := int(floor((pos.y - r) / Config.CELL_SIZE))
	var y1 := int(floor((pos.y + r) / Config.CELL_SIZE))
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			if not world_model.is_in_bounds(cx, cy):
				return false
			if world_model.get_material(cx, cy) != MaterialType.Id.EMPTY:
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
	elif _intent == Intent.DIG_BLOCK and not _dig_advancing:
		_swim_phase += delta * (SWIM_MIN * 0.5)

	var sway_ratio := speed_ratio
	if _intent == Intent.DIG_BLOCK and not _dig_advancing:
		sway_ratio = 0.25

	var sway1 := sin(_swim_phase) * TAIL_R1 * SWAY1_MULT * sway_ratio
	var sway2 := sin(_swim_phase - PHASE_OFF) * TAIL_R1 * SWAY2_MULT * sway_ratio

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
