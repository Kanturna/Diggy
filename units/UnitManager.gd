extends Node2D
class_name UnitManager

const Config       = preload("res://core/Config.gd")
const MaterialType = preload("res://core/MaterialType.gd")
const CreatureGD   = preload("res://units/Creature.gd")
const CaveRegionAnalysisScript = preload("res://core/world/CaveRegionAnalysis.gd")

var _creatures: Array[Creature] = []
var _cave_region_analysis: CaveRegionAnalysis = null
var _spawn_count_by_region: Dictionary = {}

func setup(world_model: WorldModel) -> void:
	_cave_region_analysis = CaveRegionAnalysisScript.new()
	_cave_region_analysis.setup(world_model)
	_spawn_count_by_region.clear()
	_spawn(world_model)

func _spawn(world: WorldModel) -> void:
	var tries   := 0
	var spawned := 0
	var pad     := Config.CREATURE_SPAWN_PADDING_CELLS
	while spawned < Config.CREATURE_SPAWN_COUNT and tries < Config.CREATURE_SPAWN_ATTEMPTS:
		tries += 1
		var cx := randi_range(pad, world.width  - pad - 1)
		var cy := randi_range(pad, world.height - pad - 1)
		var spawn_cell := Vector2i(cx, cy)
		var snapshot := _spawn_snapshot_for_cell(world, spawn_cell)
		if snapshot.is_empty():
			continue
		var c: Creature = CreatureGD.new()
		c.global_position = Vector2(
			(cx + 0.5) * Config.CELL_SIZE,
			(cy + 0.5) * Config.CELL_SIZE,
		)
		add_child(c)
		c.setup(world, _cave_region_analysis, self)
		_creatures.append(c)
		_register_spawn_region(snapshot)
		spawned += 1

func _spawn_snapshot_for_cell(world: WorldModel, cell: Vector2i) -> Dictionary:
	if world.get_material(cell.x, cell.y) != MaterialType.Id.EMPTY:
		return {}
	var spawn_world_pos := Vector2(
		(cell.x + 0.5) * Config.CELL_SIZE,
		(cell.y + 0.5) * Config.CELL_SIZE
	)
	if not CreatureGD.can_occupy_world(world, spawn_world_pos):
		return {}
	if not _is_far_enough_from_existing_creatures(cell):
		return {}

	var snapshot: Dictionary = _cave_region_analysis.get_region_snapshot(cell)
	if snapshot.is_empty():
		return {}
	if int(snapshot.get("region_size", 0)) < Config.CREATURE_SPAWN_MIN_REGION_SIZE:
		return {}

	var boundary_lookup: Dictionary = snapshot.get("boundary_lookup", {})
	if boundary_lookup.has(cell):
		return {}

	var region_anchor: Vector2i = snapshot.get("region_id_anchor", Vector2i(-1, -1))
	var existing_region_count := int(_spawn_count_by_region.get(region_anchor, 0))
	if existing_region_count >= Config.CREATURE_SPAWN_MAX_PER_REGION:
		return {}
	return snapshot

func _is_far_enough_from_existing_creatures(cell: Vector2i) -> bool:
	var world_pos := Vector2(
		(cell.x + 0.5) * Config.CELL_SIZE,
		(cell.y + 0.5) * Config.CELL_SIZE
	)
	var min_distance := Config.CREATURE_SPAWN_MIN_CREATURE_DISTANCE_CELLS * Config.CELL_SIZE
	for creature in _creatures:
		if creature.global_position.distance_to(world_pos) < min_distance:
			return false
	return true

func _register_spawn_region(snapshot: Dictionary) -> void:
	var region_anchor: Vector2i = snapshot.get("region_id_anchor", Vector2i(-1, -1))
	_spawn_count_by_region[region_anchor] = int(_spawn_count_by_region.get(region_anchor, 0)) + 1

func creature_count() -> int:
	return _creatures.size()

func cluster_claim_count(cluster_id: String, excluding: Creature = null) -> int:
	if cluster_id.is_empty():
		return 0
	var count := 0
	for creature in _creatures:
		if creature == excluding:
			continue
		var creature_debug := creature.get_debug_snapshot()
		if str(creature_debug.get("selected_cluster_id", "")) == cluster_id:
			count += 1
	return count

func debug_snapshot() -> Dictionary:
	if _creatures.is_empty():
		return {}
	return _creatures[0].get_debug_snapshot()

func frontier_debug_snapshot() -> Dictionary:
	if _creatures.is_empty():
		return {}
	var entries_by_cell: Dictionary = {}
	var selected_lookup: Dictionary = {}
	var min_score := INF
	var max_score := -INF
	for creature in _creatures:
		var snapshot: Dictionary = creature.get_frontier_debug_snapshot()
		var entries_variant = snapshot.get("entries", [])
		for entry_variant in entries_variant:
			var entry: Dictionary = entry_variant
			var cell: Vector2i = entry.get("cell", Vector2i(-1, -1))
			var score := float(entry.get("score", 0.0))
			if not entries_by_cell.has(cell) or score > float(entries_by_cell[cell].get("score", -INF)):
				entries_by_cell[cell] = entry
			min_score = minf(min_score, score)
			max_score = maxf(max_score, score)
		var selected_cell: Vector2i = snapshot.get("selected_frontier_cell", Vector2i(-1, -1))
		if selected_cell.x >= 0:
			selected_lookup[selected_cell] = true

	var entries: Array[Dictionary] = []
	for entry in entries_by_cell.values():
		entries.append(entry)
	if entries.is_empty():
		return {}
	return {
		"entries": entries,
		"min_score": min_score,
		"max_score": max_score,
		"selected_cells": selected_lookup.keys(),
	}
