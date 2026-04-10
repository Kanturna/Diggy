extends RefCounted
class_name CaveRegionAnalysis

const MaterialType = preload("res://core/MaterialType.gd")

const CARDINAL_DIRS: Array[Vector2i] = [
	Vector2i.RIGHT,
	Vector2i.DOWN,
	Vector2i.LEFT,
	Vector2i.UP,
]
const FRONTIER_CAVITY_DISTANCE_MAX := 18
const FRONTIER_DIRECTION_SCAN_LATERAL_MAX := 3
const FRONTIER_BREAKTHROUGH_DEPTH := 3
const FRONTIER_BREAKTHROUGH_LOOKAHEAD := 4
const FRONTIER_BREAKTHROUGH_LATERAL_RANGE := 2
const FRONTIER_CAVITY_WEIGHT := 0.45
const FRONTIER_BREAKTHROUGH_WEIGHT := 0.95
const FRONTIER_CONNECTION_WEIGHT := 0.70
const FRONTIER_DEAD_END_WEIGHT := 0.85

var world: WorldModel = null
var _cached_revision := -1
var _snapshot_by_anchor: Dictionary = {}
var _region_anchor_by_cell: Dictionary = {}

func setup(world_model: WorldModel) -> void:
	world = world_model
	_reset_cache()

func get_region_snapshot(origin_cell: Vector2i) -> Dictionary:
	if world == null:
		return {}
	_ensure_revision_cache()
	if not world.is_in_bounds(origin_cell.x, origin_cell.y):
		return {}
	if world.get_material(origin_cell.x, origin_cell.y) != MaterialType.Id.EMPTY:
		return {}

	if _region_anchor_by_cell.has(origin_cell):
		var region_anchor: Vector2i = _region_anchor_by_cell[origin_cell]
		return _snapshot_by_anchor.get(region_anchor, {})

	var snapshot: Dictionary = _build_snapshot(origin_cell)
	if snapshot.is_empty():
		return {}

	var snapshot_anchor: Vector2i = snapshot.get("region_id_anchor", Vector2i(-1, -1))
	_snapshot_by_anchor[snapshot_anchor] = snapshot
	var region_lookup: Dictionary = snapshot.get("region_lookup", {})
	for cell_variant in region_lookup.keys():
		var cell: Vector2i = cell_variant
		_region_anchor_by_cell[cell] = snapshot_anchor
	return snapshot

func build_reachability(snapshot: Dictionary, start_cell: Vector2i) -> Dictionary:
	var reachability: Dictionary = {
		"distance": {},
		"came_from": {},
	}
	if snapshot.is_empty():
		return reachability

	var region_lookup: Dictionary = snapshot.get("region_lookup", {})
	if not region_lookup.has(start_cell):
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
			distance[next_cell] = int(distance[cell]) + 1
			came_from[next_cell] = cell
			queue.append(next_cell)
	return reachability

func reconstruct_path(reachability: Dictionary, start_cell: Vector2i, goal_cell: Vector2i) -> Array[Vector2i]:
	var distance: Dictionary = reachability.get("distance", {})
	var came_from: Dictionary = reachability.get("came_from", {})
	if not distance.has(goal_cell):
		return []

	var reversed_path: Array[Vector2i] = []
	var current: Vector2i = goal_cell
	reversed_path.append(current)
	while current != start_cell:
		if not came_from.has(current):
			return []
		current = came_from[current]
		reversed_path.append(current)

	reversed_path.reverse()
	return reversed_path

func _ensure_revision_cache() -> void:
	if world == null:
		return
	if _cached_revision == world.revision:
		return
	_reset_cache()
	_cached_revision = world.revision

func _reset_cache() -> void:
	_snapshot_by_anchor.clear()
	_region_anchor_by_cell.clear()

func _build_snapshot(origin_cell: Vector2i) -> Dictionary:
	var queue: Array[Vector2i] = [origin_cell]
	var queue_index := 0
	var region_lookup: Dictionary = {}
	var region_cells: Array[Vector2i] = []
	var region_anchor: Vector2i = origin_cell
	region_lookup[origin_cell] = true
	region_cells.append(origin_cell)

	while queue_index < queue.size():
		var cell: Vector2i = queue[queue_index]
		queue_index += 1
		if _is_cell_before(cell, region_anchor):
			region_anchor = cell
		for direction in CARDINAL_DIRS:
			var next_cell: Vector2i = cell + direction
			if not world.is_in_bounds(next_cell.x, next_cell.y):
				continue
			if region_lookup.has(next_cell):
				continue
			if world.get_material(next_cell.x, next_cell.y) != MaterialType.Id.EMPTY:
				continue
			region_lookup[next_cell] = true
			region_cells.append(next_cell)
			queue.append(next_cell)

	var boundary_lookup: Dictionary = {}
	var frontier_staging_by_cell: Dictionary = {}
	for cell in region_cells:
		for direction in CARDINAL_DIRS:
			var neighbor: Vector2i = cell + direction
			if not world.is_in_bounds(neighbor.x, neighbor.y):
				continue
			if world.get_material(neighbor.x, neighbor.y) != MaterialType.Id.EARTH:
				continue
			boundary_lookup[cell] = true
			if not frontier_staging_by_cell.has(neighbor):
				frontier_staging_by_cell[neighbor] = {}
			var staging_lookup: Dictionary = frontier_staging_by_cell[neighbor]
			staging_lookup[cell] = true

	var frontier_utility_by_cell: Dictionary = _build_frontier_utility(region_lookup, frontier_staging_by_cell)
	var frontier_clusters: Array[Dictionary] = _build_frontier_clusters(frontier_staging_by_cell, frontier_utility_by_cell)
	var boundary_cells: Array[Vector2i] = _sorted_cells_from_lookup(boundary_lookup)

	return {
		"region_id_anchor": region_anchor,
		"revision": world.revision,
		"region_cells": region_cells,
		"region_lookup": region_lookup,
		"region_size": region_cells.size(),
		"boundary_cells": boundary_cells,
		"boundary_lookup": boundary_lookup,
		"frontier_utility_by_cell": frontier_utility_by_cell,
		"frontier_clusters": frontier_clusters,
	}

func _build_frontier_clusters(frontier_staging_by_cell: Dictionary, frontier_utility_by_cell: Dictionary) -> Array[Dictionary]:
	var frontier_lookup: Dictionary = {}
	for frontier_cell_variant in frontier_staging_by_cell.keys():
		var frontier_cell: Vector2i = frontier_cell_variant
		frontier_lookup[frontier_cell] = true

	var visited: Dictionary = {}
	var clusters: Array[Dictionary] = []
	for frontier_cell_variant in frontier_lookup.keys():
		var frontier_cell: Vector2i = frontier_cell_variant
		if visited.has(frontier_cell):
			continue

		var queue: Array[Vector2i] = [frontier_cell]
		var queue_index := 0
		var cluster_lookup: Dictionary = {}
		var staging_lookup: Dictionary = {}
		var cluster_anchor: Vector2i = frontier_cell
		var centroid_acc: Vector2 = Vector2.ZERO
		var best_frontier_utility := 0.0
		var best_external_distance := FRONTIER_CAVITY_DISTANCE_MAX + 1

		visited[frontier_cell] = true
		cluster_lookup[frontier_cell] = true

		while queue_index < queue.size():
			var current: Vector2i = queue[queue_index]
			queue_index += 1
			centroid_acc += Vector2(float(current.x), float(current.y))
			if _is_cell_before(current, cluster_anchor):
				cluster_anchor = current
			var utility_data: Dictionary = frontier_utility_by_cell.get(current, {})
			var frontier_utility := float(utility_data.get("frontier_utility", 0.0))
			var external_distance := int(utility_data.get("external_distance", FRONTIER_CAVITY_DISTANCE_MAX + 1))
			best_frontier_utility = maxf(best_frontier_utility, frontier_utility)
			best_external_distance = mini(best_external_distance, external_distance)

			var local_staging_lookup: Dictionary = frontier_staging_by_cell.get(current, {})
			for staging_cell_variant in local_staging_lookup.keys():
				var staging_cell: Vector2i = staging_cell_variant
				staging_lookup[staging_cell] = true

			for direction in CARDINAL_DIRS:
				var neighbor: Vector2i = current + direction
				if not frontier_lookup.has(neighbor):
					continue
				if visited.has(neighbor):
					continue
				visited[neighbor] = true
				cluster_lookup[neighbor] = true
				queue.append(neighbor)

		var frontier_cells: Array[Vector2i] = _sorted_cells_from_lookup(cluster_lookup)
		var staging_cells: Array[Vector2i] = _sorted_cells_from_lookup(staging_lookup)
		var centroid: Vector2 = centroid_acc / maxf(float(frontier_cells.size()), 1.0)
		clusters.append({
			"cluster_id": "cluster_%d_%d" % [cluster_anchor.x, cluster_anchor.y],
			"cluster_anchor": cluster_anchor,
			"frontier_cells": frontier_cells,
			"frontier_lookup": cluster_lookup,
			"staging_cells": staging_cells,
			"staging_lookup": staging_lookup,
			"centroid": centroid,
			"size": frontier_cells.size(),
			"best_frontier_utility": best_frontier_utility,
			"best_external_distance": best_external_distance,
		})

	clusters.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _is_cell_before(
			a.get("cluster_anchor", Vector2i.ZERO),
			b.get("cluster_anchor", Vector2i.ZERO)
		)
	)
	return clusters

func _sorted_cells_from_lookup(lookup: Dictionary) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for cell_variant in lookup.keys():
		var cell: Vector2i = cell_variant
		cells.append(cell)
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return _is_cell_before(a, b)
	)
	return cells

func _build_frontier_utility(region_lookup: Dictionary, frontier_staging_by_cell: Dictionary) -> Dictionary:
	var utility_by_cell: Dictionary = {}
	for frontier_cell_variant in frontier_staging_by_cell.keys():
		var frontier_cell: Vector2i = frontier_cell_variant
		var best_metrics := {
			"external_distance": FRONTIER_CAVITY_DISTANCE_MAX + 1,
			"cavity_proximity_score": 0.0,
			"breakthrough_value": 0.0,
			"connection_value": 0.0,
			"dead_end_risk": 1.0,
			"frontier_utility": -INF,
		}
		var staging_lookup: Dictionary = frontier_staging_by_cell.get(frontier_cell, {})
		for staging_cell_variant in staging_lookup.keys():
			var staging_cell: Vector2i = staging_cell_variant
			var dig_direction: Vector2i = frontier_cell - staging_cell
			if dig_direction == Vector2i.ZERO:
				continue
			var metrics := _evaluate_frontier_direction(frontier_cell, dig_direction, region_lookup)
			if float(metrics.get("frontier_utility", -INF)) > float(best_metrics.get("frontier_utility", -INF)):
				best_metrics = metrics
		if float(best_metrics.get("frontier_utility", -INF)) == -INF:
			best_metrics["frontier_utility"] = 0.0
		utility_by_cell[frontier_cell] = best_metrics
	return utility_by_cell

func _evaluate_frontier_direction(frontier_cell: Vector2i, dig_direction: Vector2i, region_lookup: Dictionary) -> Dictionary:
	var cavity_scan := _scan_external_space(frontier_cell, dig_direction, region_lookup, FRONTIER_CAVITY_DISTANCE_MAX)
	var external_distance := int(cavity_scan.get("nearest_distance", FRONTIER_CAVITY_DISTANCE_MAX + 1))
	var cavity_proximity_score := _distance_to_proximity_score(external_distance)

	var breakthrough_value := 0.0
	var connection_value := 0.0
	var dead_end_risk := 1.0
	for depth in range(1, FRONTIER_BREAKTHROUGH_DEPTH + 1):
		var probe_head: Vector2i = frontier_cell + dig_direction * depth
		var probe_metrics := _probe_breakthrough_window(probe_head, dig_direction, region_lookup)
		breakthrough_value = maxf(breakthrough_value, float(probe_metrics.get("breakthrough_value", 0.0)))
		connection_value = maxf(connection_value, float(probe_metrics.get("connection_value", 0.0)))
		dead_end_risk = minf(dead_end_risk, float(probe_metrics.get("dead_end_risk", 1.0)))

	var frontier_utility := \
		cavity_proximity_score * FRONTIER_CAVITY_WEIGHT \
		+ breakthrough_value * FRONTIER_BREAKTHROUGH_WEIGHT \
		+ connection_value * FRONTIER_CONNECTION_WEIGHT \
		- dead_end_risk * FRONTIER_DEAD_END_WEIGHT
	frontier_utility = clampf(frontier_utility, 0.0, 1.0)

	return {
		"external_distance": external_distance,
		"cavity_proximity_score": cavity_proximity_score,
		"breakthrough_value": breakthrough_value,
		"connection_value": connection_value,
		"dead_end_risk": dead_end_risk,
		"frontier_utility": frontier_utility,
	}

func _scan_external_space(frontier_cell: Vector2i, dig_direction: Vector2i, region_lookup: Dictionary, max_distance: int) -> Dictionary:
	var perpendicular := Vector2i(dig_direction.y, -dig_direction.x)
	var nearest_distance := max_distance + 1
	var weighted_hits := 0.0
	var side_hits: Dictionary = {}
	for step in range(1, max_distance + 1):
		var base_cell := frontier_cell + dig_direction * step
		var lateral_limit := mini(FRONTIER_DIRECTION_SCAN_LATERAL_MAX, 1 + int(step / 5))
		for lateral in range(-lateral_limit, lateral_limit + 1):
			var sample_cell := base_cell + perpendicular * lateral
			if not _is_external_empty_cell(sample_cell, region_lookup):
				continue
			nearest_distance = mini(nearest_distance, step)
			var distance_weight := 1.0 - (float(step - 1) / float(max_distance))
			var lateral_weight := 1.0 - (absf(float(lateral)) / float(lateral_limit + 1))
			weighted_hits += distance_weight * (0.3 + 0.7 * lateral_weight)
			side_hits[_lateral_bucket(lateral)] = true
	return {
		"nearest_distance": nearest_distance,
		"weighted_hits": weighted_hits,
		"side_count": side_hits.size(),
	}

func _probe_breakthrough_window(probe_head: Vector2i, dig_direction: Vector2i, region_lookup: Dictionary) -> Dictionary:
	var perpendicular := Vector2i(dig_direction.y, -dig_direction.x)
	var weighted_hits := 0.0
	var hit_count := 0
	var side_hits: Dictionary = {}
	var max_samples := 0
	for forward in range(FRONTIER_BREAKTHROUGH_LOOKAHEAD + 1):
		var base_cell := probe_head + dig_direction * forward
		for lateral in range(-FRONTIER_BREAKTHROUGH_LATERAL_RANGE, FRONTIER_BREAKTHROUGH_LATERAL_RANGE + 1):
			max_samples += 1
			var sample_cell := base_cell + perpendicular * lateral
			if not _is_external_empty_cell(sample_cell, region_lookup):
				continue
			hit_count += 1
			var forward_weight := 1.0 - (float(forward) / float(FRONTIER_BREAKTHROUGH_LOOKAHEAD + 1))
			var lateral_weight := 1.0 - (absf(float(lateral)) / float(FRONTIER_BREAKTHROUGH_LATERAL_RANGE + 1))
			weighted_hits += forward_weight * (0.35 + 0.65 * lateral_weight)
			side_hits[_lateral_bucket(lateral)] = true

	var breakthrough_value := clampf(weighted_hits / 8.5, 0.0, 1.0)
	var connection_value := 0.0
	if hit_count > 0:
		var side_factor := clampf(float(side_hits.size() - 1) / 2.0, 0.0, 1.0)
		var density := clampf(float(hit_count) / float(maxi(max_samples, 1)), 0.0, 1.0)
		connection_value = clampf(0.55 * side_factor + 0.45 * density, 0.0, 1.0) * breakthrough_value

	var dead_end_risk := 1.0
	if hit_count > 0:
		var openness := clampf(0.75 * breakthrough_value + 0.25 * connection_value, 0.0, 1.0)
		dead_end_risk = clampf(1.0 - openness, 0.0, 1.0)

	return {
		"breakthrough_value": breakthrough_value,
		"connection_value": connection_value,
		"dead_end_risk": dead_end_risk,
	}

func _distance_to_proximity_score(external_distance: int) -> float:
	if external_distance > FRONTIER_CAVITY_DISTANCE_MAX:
		return 0.0
	return 1.0 - (float(external_distance - 1) / float(FRONTIER_CAVITY_DISTANCE_MAX))

func _is_external_empty_cell(cell: Vector2i, region_lookup: Dictionary) -> bool:
	if not world.is_in_bounds(cell.x, cell.y):
		return false
	if world.get_material(cell.x, cell.y) != MaterialType.Id.EMPTY:
		return false
	return not region_lookup.has(cell)

func _lateral_bucket(lateral: int) -> int:
	if lateral < 0:
		return -1
	if lateral > 0:
		return 1
	return 0

static func _is_cell_before(a: Vector2i, b: Vector2i) -> bool:
	if a.y == b.y:
		return a.x < b.x
	return a.y < b.y
