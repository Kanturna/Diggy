extends RefCounted
class_name CaveRegionAnalysis

const MaterialType = preload("res://core/MaterialType.gd")

const CARDINAL_DIRS: Array[Vector2i] = [
	Vector2i.RIGHT,
	Vector2i.DOWN,
	Vector2i.LEFT,
	Vector2i.UP,
]
const FRONTIER_ATTRACTION_MAX_DISTANCE := 24

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

	var frontier_attraction_by_cell: Dictionary = _build_frontier_attraction(region_lookup, frontier_staging_by_cell)
	var frontier_clusters: Array[Dictionary] = _build_frontier_clusters(frontier_staging_by_cell, frontier_attraction_by_cell)
	var boundary_cells: Array[Vector2i] = _sorted_cells_from_lookup(boundary_lookup)

	return {
		"region_id_anchor": region_anchor,
		"revision": world.revision,
		"region_cells": region_cells,
		"region_lookup": region_lookup,
		"region_size": region_cells.size(),
		"boundary_cells": boundary_cells,
		"boundary_lookup": boundary_lookup,
		"frontier_attraction_by_cell": frontier_attraction_by_cell,
		"frontier_clusters": frontier_clusters,
	}

func _build_frontier_clusters(frontier_staging_by_cell: Dictionary, frontier_attraction_by_cell: Dictionary) -> Array[Dictionary]:
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
		var best_attraction := 0.0
		var best_external_distance := FRONTIER_ATTRACTION_MAX_DISTANCE + 1

		visited[frontier_cell] = true
		cluster_lookup[frontier_cell] = true

		while queue_index < queue.size():
			var current: Vector2i = queue[queue_index]
			queue_index += 1
			centroid_acc += Vector2(float(current.x), float(current.y))
			if _is_cell_before(current, cluster_anchor):
				cluster_anchor = current
			var attraction_data: Dictionary = frontier_attraction_by_cell.get(current, {})
			var attraction_score := float(attraction_data.get("attraction_score", 0.0))
			var external_distance := int(attraction_data.get("external_distance", FRONTIER_ATTRACTION_MAX_DISTANCE + 1))
			best_attraction = maxf(best_attraction, attraction_score)
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
			"best_attraction_score": best_attraction,
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

func _build_frontier_attraction(region_lookup: Dictionary, frontier_staging_by_cell: Dictionary) -> Dictionary:
	var attraction_by_cell: Dictionary = {}
	for frontier_cell_variant in frontier_staging_by_cell.keys():
		var frontier_cell: Vector2i = frontier_cell_variant
		var external_distance := _nearest_external_distance(frontier_cell, region_lookup)
		attraction_by_cell[frontier_cell] = {
			"external_distance": external_distance,
			"attraction_score": _distance_to_attraction(external_distance),
		}
	return attraction_by_cell

func _nearest_external_distance(frontier_cell: Vector2i, region_lookup: Dictionary) -> int:
	for distance in range(1, FRONTIER_ATTRACTION_MAX_DISTANCE + 1):
		var y_min: int = maxi(frontier_cell.y - distance, 0)
		var y_max: int = mini(frontier_cell.y + distance, world.height - 1)
		for y in range(y_min, y_max + 1):
			var dy: int = abs(y - frontier_cell.y)
			var dx: int = distance - dy
			if dx < 0:
				continue
			var left: Vector2i = Vector2i(frontier_cell.x - dx, y)
			if _is_external_empty_cell(left, region_lookup):
				return distance
			if dx == 0:
				continue
			var right: Vector2i = Vector2i(frontier_cell.x + dx, y)
			if _is_external_empty_cell(right, region_lookup):
				return distance
	return FRONTIER_ATTRACTION_MAX_DISTANCE + 1

func _distance_to_attraction(external_distance: int) -> float:
	if external_distance > FRONTIER_ATTRACTION_MAX_DISTANCE:
		return 0.0
	return 1.0 - (float(external_distance - 1) / float(FRONTIER_ATTRACTION_MAX_DISTANCE))

func _is_external_empty_cell(cell: Vector2i, region_lookup: Dictionary) -> bool:
	if not world.is_in_bounds(cell.x, cell.y):
		return false
	if world.get_material(cell.x, cell.y) != MaterialType.Id.EMPTY:
		return false
	return not region_lookup.has(cell)

static func _is_cell_before(a: Vector2i, b: Vector2i) -> bool:
	if a.y == b.y:
		return a.x < b.x
	return a.y < b.y
