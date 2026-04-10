extends RefCounted
class_name CaveRegionAnalysis

const MaterialType = preload("res://core/MaterialType.gd")

const CARDINAL_DIRS: Array[Vector2i] = [
	Vector2i.RIGHT,
	Vector2i.DOWN,
	Vector2i.LEFT,
	Vector2i.UP,
]
const FRONTIER_DEPTH_FORWARD_MAX := 7
const FRONTIER_DEPTH_LATERAL_RANGE := 1
const FRONTIER_SENSOR_DISTANCE_MAX := 6
const FRONTIER_SENSOR_LATERAL_MAX := 2
const FRONTIER_PARALLEL_FORWARD_MAX := 5

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

	var frontier_metrics_by_cell: Dictionary = _build_frontier_metrics(region_lookup, frontier_staging_by_cell)
	var frontier_clusters: Array[Dictionary] = _build_frontier_clusters(frontier_staging_by_cell, frontier_metrics_by_cell)
	var boundary_cells: Array[Vector2i] = _sorted_cells_from_lookup(boundary_lookup)

	return {
		"region_id_anchor": region_anchor,
		"revision": world.revision,
		"region_cells": region_cells,
		"region_lookup": region_lookup,
		"region_size": region_cells.size(),
		"boundary_cells": boundary_cells,
		"boundary_lookup": boundary_lookup,
		"frontier_metrics_by_cell": frontier_metrics_by_cell,
		"frontier_clusters": frontier_clusters,
	}

func _build_frontier_clusters(frontier_staging_by_cell: Dictionary, frontier_metrics_by_cell: Dictionary) -> Array[Dictionary]:
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
		var best_depth_score := 0.0
		var best_sensor_score := 0.0

		visited[frontier_cell] = true
		cluster_lookup[frontier_cell] = true

		while queue_index < queue.size():
			var current: Vector2i = queue[queue_index]
			queue_index += 1
			centroid_acc += Vector2(float(current.x), float(current.y))
			if _is_cell_before(current, cluster_anchor):
				cluster_anchor = current

			var metrics_variant = frontier_metrics_by_cell.get(current, [])
			for metric_variant in metrics_variant:
				var metric: Dictionary = metric_variant
				best_depth_score = maxf(best_depth_score, float(metric.get("depth_score", 0.0)))
				best_sensor_score = maxf(
					best_sensor_score,
					float(metric.get("sensor_hollow_score", 0.0)) + float(metric.get("sensor_open_span_score", 0.0))
				)

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
			"best_depth_score": best_depth_score,
			"best_sensor_score": best_sensor_score,
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

func _build_frontier_metrics(region_lookup: Dictionary, frontier_staging_by_cell: Dictionary) -> Dictionary:
	var metrics_by_cell: Dictionary = {}
	for frontier_cell_variant in frontier_staging_by_cell.keys():
		var frontier_cell: Vector2i = frontier_cell_variant
		var metrics: Array[Dictionary] = []
		var staging_lookup: Dictionary = frontier_staging_by_cell.get(frontier_cell, {})
		for staging_cell_variant in staging_lookup.keys():
			var staging_cell: Vector2i = staging_cell_variant
			var dig_direction: Vector2i = frontier_cell - staging_cell
			if dig_direction == Vector2i.ZERO:
				continue
			var metric := _evaluate_frontier_direction(frontier_cell, staging_cell, dig_direction, region_lookup)
			metric["frontier_cell"] = frontier_cell
			metric["staging_cell"] = staging_cell
			metric["dig_direction"] = dig_direction
			metrics.append(metric)
		metrics_by_cell[frontier_cell] = metrics
	return metrics_by_cell

func _evaluate_frontier_direction(
	frontier_cell: Vector2i,
	staging_cell: Vector2i,
	dig_direction: Vector2i,
	region_lookup: Dictionary
) -> Dictionary:
	var sensor_metrics := _scan_external_sensor(frontier_cell, dig_direction, region_lookup)
	var depth_score := _scan_depth_corridor(frontier_cell, dig_direction)
	var scrape_penalty := _scrape_penalty(frontier_cell, region_lookup)
	var parallel_risk := _scan_parallel_tunnel(frontier_cell, dig_direction)
	var continuation_count := _count_forward_earth_options(frontier_cell, staging_cell)
	var sensor_hollow_score := float(sensor_metrics.get("sensor_hollow_score", 0.0))
	var sensor_open_span_score := float(sensor_metrics.get("sensor_open_span_score", 0.0))
	var niche_risk := _niche_risk(continuation_count, depth_score, sensor_hollow_score, sensor_open_span_score)

	return {
		"depth_score": depth_score,
		"sensor_hollow_score": sensor_hollow_score,
		"sensor_open_span_score": sensor_open_span_score,
		"parallel_risk": parallel_risk,
		"niche_risk": niche_risk,
		"scrape_penalty": scrape_penalty,
		"continuation_count": continuation_count,
	}

func _scan_depth_corridor(frontier_cell: Vector2i, dig_direction: Vector2i) -> float:
	var perpendicular := Vector2i(dig_direction.y, -dig_direction.x)
	var weighted_earth := 0.0
	var max_weight := 0.0
	for step in range(1, FRONTIER_DEPTH_FORWARD_MAX + 1):
		var base_cell := frontier_cell + dig_direction * step
		if not world.is_in_bounds(base_cell.x, base_cell.y):
			break
		var forward_weight := 1.0 - (float(step - 1) / float(FRONTIER_DEPTH_FORWARD_MAX))
		max_weight += forward_weight
		if world.get_material(base_cell.x, base_cell.y) != MaterialType.Id.EARTH:
			break
		weighted_earth += forward_weight
		for lateral in range(1, FRONTIER_DEPTH_LATERAL_RANGE + 1):
			var lateral_weight := forward_weight * (0.55 - float(lateral - 1) * 0.15)
			for sign in [-1, 1]:
				var sample_cell := base_cell + perpendicular * lateral * sign
				max_weight += lateral_weight
				if not world.is_in_bounds(sample_cell.x, sample_cell.y):
					continue
				if world.get_material(sample_cell.x, sample_cell.y) == MaterialType.Id.EARTH:
					weighted_earth += lateral_weight
	return clampf(weighted_earth / maxf(max_weight, 0.001), 0.0, 1.0)

func _scan_external_sensor(frontier_cell: Vector2i, dig_direction: Vector2i, region_lookup: Dictionary) -> Dictionary:
	var perpendicular := Vector2i(dig_direction.y, -dig_direction.x)
	var nearest_distance := FRONTIER_SENSOR_DISTANCE_MAX + 1
	var open_hit_count := 0
	var max_samples := 0
	var lateral_buckets: Dictionary = {}
	for step in range(1, FRONTIER_SENSOR_DISTANCE_MAX + 1):
		var base_cell := frontier_cell + dig_direction * step
		var lateral_limit := mini(FRONTIER_SENSOR_LATERAL_MAX, 1 + int((step - 1) / 2))
		for lateral in range(-lateral_limit, lateral_limit + 1):
			max_samples += 1
			var sample_cell := base_cell + perpendicular * lateral
			if not _is_external_empty_cell(sample_cell, region_lookup):
				continue
			open_hit_count += 1
			nearest_distance = mini(nearest_distance, step)
			lateral_buckets[_lateral_bucket(lateral)] = true
	var sensor_hollow_score := _distance_to_score(nearest_distance, FRONTIER_SENSOR_DISTANCE_MAX)
	var sensor_open_span_score := 0.0
	if open_hit_count > 0:
		var density := clampf(float(open_hit_count) / float(maxi(max_samples, 1)), 0.0, 1.0)
		var span := clampf(float(lateral_buckets.size() - 1) / 2.0, 0.0, 1.0)
		sensor_open_span_score = clampf(0.60 * density + 0.40 * span, 0.0, 1.0)
	return {
		"sensor_hollow_score": sensor_hollow_score,
		"sensor_open_span_score": sensor_open_span_score,
	}

func _scan_parallel_tunnel(frontier_cell: Vector2i, dig_direction: Vector2i) -> float:
	var perpendicular := Vector2i(dig_direction.y, -dig_direction.x)
	var weighted_hits := 0.0
	var max_weight := 0.0
	for step in range(FRONTIER_PARALLEL_FORWARD_MAX):
		var corridor_cell := frontier_cell + dig_direction * step
		var forward_weight := 1.0 - (float(step) / float(FRONTIER_PARALLEL_FORWARD_MAX))
		for sign in [-1, 1]:
			max_weight += forward_weight
			var wall_cell := corridor_cell + perpendicular * sign
			var open_cell := corridor_cell + perpendicular * sign * 2
			if not world.is_in_bounds(wall_cell.x, wall_cell.y):
				continue
			if not world.is_in_bounds(open_cell.x, open_cell.y):
				continue
			if world.get_material(wall_cell.x, wall_cell.y) != MaterialType.Id.EARTH:
				continue
			if world.get_material(open_cell.x, open_cell.y) != MaterialType.Id.EMPTY:
				continue
			weighted_hits += forward_weight
	return clampf(weighted_hits / maxf(max_weight, 0.001), 0.0, 1.0)

func _scrape_penalty(frontier_cell: Vector2i, region_lookup: Dictionary) -> float:
	var region_open_neighbors := 0
	for direction in CARDINAL_DIRS:
		var neighbor: Vector2i = frontier_cell + direction
		if region_lookup.has(neighbor):
			region_open_neighbors += 1
	return clampf(float(region_open_neighbors - 1) / 2.0, 0.0, 1.0)

func _count_forward_earth_options(frontier_cell: Vector2i, staging_cell: Vector2i) -> int:
	var count := 0
	for direction in CARDINAL_DIRS:
		var neighbor: Vector2i = frontier_cell + direction
		if neighbor == staging_cell:
			continue
		if not world.is_in_bounds(neighbor.x, neighbor.y):
			continue
		if world.get_material(neighbor.x, neighbor.y) == MaterialType.Id.EARTH:
			count += 1
	return count

func _niche_risk(
	continuation_count: int,
	depth_score: float,
	sensor_hollow_score: float,
	sensor_open_span_score: float
) -> float:
	var sensor_strength := maxf(sensor_hollow_score, sensor_open_span_score)
	if continuation_count <= 0:
		if sensor_strength <= 0.05:
			return 1.0
		return 0.35
	if continuation_count == 1 and depth_score < 0.25 and sensor_strength < 0.08:
		return 0.55
	return 0.0

func _distance_to_score(distance: int, max_distance: int) -> float:
	if distance > max_distance:
		return 0.0
	return 1.0 - (float(distance - 1) / float(max_distance))

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
