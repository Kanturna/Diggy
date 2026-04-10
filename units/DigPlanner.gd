extends RefCounted
class_name DigPlanner

const Config = preload("res://core/Config.gd")

const TOP_K := 5

const SENSOR_SCORE_WEIGHT := 0.55
const PERCEPTION_BOOST_WEIGHT := 0.85
const CONTINUITY_WEIGHT := 1.15
const DEPTH_WEIGHT := 1.45
const PARALLEL_WEIGHT := 1.25
const NICHE_WEIGHT := 1.10
const SCRAPE_WEIGHT := 0.65
const PATH_COST_WEIGHT := 0.08
const SENSOR_HOLLOW_WEIGHT := 0.65
const SENSOR_OPEN_SPAN_WEIGHT := 0.45
const TOP_K_MIN_WEIGHT := 0.10

const HARD_PARALLEL_RISK := 0.92
const HARD_NICHE_RISK := 0.95
const HARD_LOW_VALUE_DEPTH := 0.10
const HARD_LOW_VALUE_SENSOR := 0.05
const SOFT_SENSOR_FLOOR := 0.08

func choose_candidate(
	snapshot: Dictionary,
	reachability: Dictionary,
	origin_cell: Vector2i,
	last_dig_direction: Vector2i,
	selected_cluster_id: String,
	crowding_provider: Callable,
	rng: RandomNumberGenerator,
	max_path_cost: int = -1
) -> Dictionary:
	var distance_map: Dictionary = reachability.get("distance", {})
	if snapshot.is_empty() or distance_map.is_empty():
		return _empty_result()
	if not distance_map.has(origin_cell):
		return _empty_result()

	var entries_by_cell: Dictionary = {}
	var candidates: Array[Dictionary] = []
	var cluster_ids_by_frontier := _cluster_ids_by_frontier(snapshot)
	var metrics_by_cell: Dictionary = snapshot.get("frontier_metrics_by_cell", {})
	for frontier_cell_variant in metrics_by_cell.keys():
		var frontier_cell: Vector2i = frontier_cell_variant
		var metrics_variant = metrics_by_cell[frontier_cell]
		for metric_variant in metrics_variant:
			var metric: Dictionary = metric_variant
			var staging_cell: Vector2i = metric.get("staging_cell", Vector2i(-1, -1))
			if staging_cell.x < 0 or not distance_map.has(staging_cell):
				continue

			var path_cost := int(distance_map.get(staging_cell, 0))
			if max_path_cost >= 0 and path_cost > max_path_cost:
				continue

			var dig_direction: Vector2i = metric.get("dig_direction", Vector2i.ZERO)
			var cluster_id := str(metric.get("cluster_id", cluster_ids_by_frontier.get(frontier_cell, "")))
			var continuity_score := _continuity_score(last_dig_direction, dig_direction)
			var depth_score := float(metric.get("depth_score", 0.0))
			var sensor_hollow_score := float(metric.get("sensor_hollow_score", 0.0))
			var sensor_open_span_score := float(metric.get("sensor_open_span_score", 0.0))
			var parallel_risk := float(metric.get("parallel_risk", 0.0))
			var niche_risk := float(metric.get("niche_risk", 0.0))
			var scrape_penalty := float(metric.get("scrape_penalty", 0.0))
			var perception_score := _perception_radius_score(origin_cell, frontier_cell)
			var perception_interest := maxf(sensor_hollow_score, sensor_open_span_score)
			var perception_boost := perception_interest * perception_score * PERCEPTION_BOOST_WEIGHT
			var sensor_score := sensor_hollow_score * SENSOR_HOLLOW_WEIGHT \
				+ sensor_open_span_score * SENSOR_OPEN_SPAN_WEIGHT \
				+ perception_boost
			# Build score is the backbone; sensors only steer plausible tunnel moves.
			var build_score := continuity_score * CONTINUITY_WEIGHT \
				+ depth_score * DEPTH_WEIGHT \
				- parallel_risk * PARALLEL_WEIGHT \
				- niche_risk * NICHE_WEIGHT \
				- scrape_penalty * SCRAPE_WEIGHT
			var path_cost_penalty := float(path_cost) * PATH_COST_WEIGHT
			var crowding_penalty := 0.0
			if not crowding_provider.is_null() and not cluster_id.is_empty():
				crowding_penalty = float(crowding_provider.call(cluster_id))
			# Path cost is intentionally just a light comfort tie-break.
			var total_score := build_score + sensor_score * SENSOR_SCORE_WEIGHT - path_cost_penalty - crowding_penalty
			var filter_reason := _filter_reason(metric, sensor_score)
			var candidate := {
				"frontier_cell": frontier_cell,
				"staging_cell": staging_cell,
				"dig_direction": dig_direction,
				"cluster_id": cluster_id,
				"path_cost": path_cost,
				"path_cost_penalty": path_cost_penalty,
				"continuity_score": continuity_score,
				"depth_score": depth_score,
				"sensor_hollow_score": sensor_hollow_score,
				"sensor_open_span_score": sensor_open_span_score,
				"perception_score": perception_score,
				"perception_boost": perception_boost,
				"parallel_risk": parallel_risk,
				"niche_risk": niche_risk,
				"scrape_penalty": scrape_penalty,
				"build_score": build_score,
				"sensor_score": sensor_score,
				"crowding_penalty": crowding_penalty,
				"total_score": total_score,
				"filter_reason": filter_reason,
				"selection_weight": 0.0,
				"is_same_cluster": cluster_id == selected_cluster_id and not cluster_id.is_empty(),
			}
			_record_entry(entries_by_cell, candidate)
			if filter_reason.is_empty():
				candidates.append(candidate)

	if candidates.is_empty():
		return _build_result(entries_by_cell, {})

	candidates.sort_custom(_sort_candidates)
	var top_candidates: Array[Dictionary] = []
	for i in mini(TOP_K, candidates.size()):
		top_candidates.append(candidates[i])
	_assign_selection_weights(top_candidates)
	var selected_candidate := _select_weighted_candidate(top_candidates, rng)
	for candidate in top_candidates:
		_record_entry(entries_by_cell, candidate)
	if not selected_candidate.is_empty():
		_record_entry(entries_by_cell, selected_candidate, true)

	return _build_result(entries_by_cell, selected_candidate)

func _build_result(entries_by_cell: Dictionary, selected_candidate: Dictionary) -> Dictionary:
	var entries: Array[Dictionary] = []
	var min_score := INF
	var max_score := -INF
	for entry_variant in entries_by_cell.values():
		var entry: Dictionary = entry_variant
		var score := float(entry.get("score", 0.0))
		min_score = minf(min_score, score)
		max_score = maxf(max_score, score)
		entries.append(entry)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _is_cell_before(
			a.get("cell", Vector2i.ZERO),
			b.get("cell", Vector2i.ZERO)
		)
	)
	if entries.is_empty():
		min_score = 0.0
		max_score = 1.0
	return {
		"selected_candidate": selected_candidate,
		"entries": entries,
		"min_score": min_score,
		"max_score": max_score,
	}

func _record_entry(entries_by_cell: Dictionary, candidate: Dictionary, is_selected: bool = false) -> void:
	var frontier_cell: Vector2i = candidate.get("frontier_cell", Vector2i(-1, -1))
	if frontier_cell.x < 0:
		return

	var entry: Dictionary = entries_by_cell.get(frontier_cell, {
		"cell": frontier_cell,
		"score": float(candidate.get("total_score", 0.0)),
		"cluster_id": str(candidate.get("cluster_id", "")),
		"filter_reason": str(candidate.get("filter_reason", "")),
		"selection_weight": float(candidate.get("selection_weight", 0.0)),
		"is_selected": false,
	})
	if not entries_by_cell.has(frontier_cell) or float(candidate.get("total_score", -INF)) > float(entry.get("score", -INF)):
		entry["score"] = float(candidate.get("total_score", 0.0))
		entry["cluster_id"] = str(candidate.get("cluster_id", ""))
		entry["filter_reason"] = str(candidate.get("filter_reason", ""))
	if float(candidate.get("selection_weight", 0.0)) > float(entry.get("selection_weight", 0.0)):
		entry["selection_weight"] = float(candidate.get("selection_weight", 0.0))
	if is_selected:
		entry["is_selected"] = true
	elif not entry.has("is_selected"):
		entry["is_selected"] = false
	entries_by_cell[frontier_cell] = entry

func _filter_reason(metric: Dictionary, sensor_score: float) -> String:
	if float(metric.get("parallel_risk", 0.0)) >= HARD_PARALLEL_RISK:
		return "parallel_wall"
	if float(metric.get("niche_risk", 0.0)) >= HARD_NICHE_RISK and sensor_score <= SOFT_SENSOR_FLOOR:
		return "niche"
	if float(metric.get("depth_score", 0.0)) <= HARD_LOW_VALUE_DEPTH and sensor_score <= HARD_LOW_VALUE_SENSOR:
		return "low_value"
	return ""

func _assign_selection_weights(candidates: Array[Dictionary]) -> void:
	if candidates.is_empty():
		return
	var floor_score := float(candidates[candidates.size() - 1].get("total_score", 0.0))
	for candidate in candidates:
		var score := float(candidate.get("total_score", 0.0))
		candidate["selection_weight"] = maxf(score - floor_score, 0.0) + TOP_K_MIN_WEIGHT

func _select_weighted_candidate(candidates: Array[Dictionary], rng: RandomNumberGenerator) -> Dictionary:
	if candidates.is_empty():
		return {}
	if candidates.size() == 1:
		return candidates[0]

	var total_weight := 0.0
	for candidate in candidates:
		total_weight += float(candidate.get("selection_weight", 0.0))
	if total_weight <= 0.0:
		return candidates[0]

	var roll := 0.0
	if rng != null:
		roll = rng.randf() * total_weight
	var acc := 0.0
	for candidate in candidates:
		acc += float(candidate.get("selection_weight", 0.0))
		if roll <= acc:
			return candidate
	return candidates[candidates.size() - 1]

func _cluster_ids_by_frontier(snapshot: Dictionary) -> Dictionary:
	var cluster_ids: Dictionary = {}
	var clusters_variant = snapshot.get("frontier_clusters", [])
	for cluster_variant in clusters_variant:
		var cluster: Dictionary = cluster_variant
		var cluster_id := str(cluster.get("cluster_id", ""))
		var frontier_cells_variant = cluster.get("frontier_cells", [])
		for frontier_cell_variant in frontier_cells_variant:
			var frontier_cell: Vector2i = frontier_cell_variant
			cluster_ids[frontier_cell] = cluster_id
	return cluster_ids

func _continuity_score(last_dig_direction: Vector2i, candidate_direction: Vector2i) -> float:
	if candidate_direction == Vector2i.ZERO:
		return -1.0
	if last_dig_direction == Vector2i.ZERO:
		return 0.0
	var current := _normalize_cardinal(last_dig_direction)
	var candidate := _normalize_cardinal(candidate_direction)
	return float(current.x * candidate.x + current.y * candidate.y)

func _perception_radius_score(origin_cell: Vector2i, frontier_cell: Vector2i) -> float:
	var radius := float(Config.CREATURE_PERCEPTION_RADIUS_CELLS)
	if radius <= 0.0:
		return 0.0
	var distance := origin_cell.distance_to(frontier_cell)
	if distance > radius:
		return 0.0
	return clampf(1.0 - (distance / radius), 0.0, 1.0)

func _normalize_cardinal(direction: Vector2i) -> Vector2i:
	if abs(direction.x) >= abs(direction.y):
		return Vector2i(1 if direction.x >= 0 else -1, 0)
	return Vector2i(0, 1 if direction.y >= 0 else -1)

func _sort_candidates(a: Dictionary, b: Dictionary) -> bool:
	var a_score := float(a.get("total_score", -INF))
	var b_score := float(b.get("total_score", -INF))
	if not is_equal_approx(a_score, b_score):
		return a_score > b_score

	var a_path_cost := int(a.get("path_cost", 0))
	var b_path_cost := int(b.get("path_cost", 0))
	if a_path_cost != b_path_cost:
		return a_path_cost < b_path_cost

	var a_frontier: Vector2i = a.get("frontier_cell", Vector2i(-1, -1))
	var b_frontier: Vector2i = b.get("frontier_cell", Vector2i(-1, -1))
	if a_frontier != b_frontier:
		return _is_cell_before(a_frontier, b_frontier)

	var a_staging: Vector2i = a.get("staging_cell", Vector2i(-1, -1))
	var b_staging: Vector2i = b.get("staging_cell", Vector2i(-1, -1))
	return _is_cell_before(a_staging, b_staging)

func _empty_result() -> Dictionary:
	return {
		"selected_candidate": {},
		"entries": [],
		"min_score": 0.0,
		"max_score": 1.0,
	}

static func _is_cell_before(a: Vector2i, b: Vector2i) -> bool:
	if b.x < 0 or b.y < 0:
		return true
	if a.y == b.y:
		return a.x < b.x
	return a.y < b.y
