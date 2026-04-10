extends Node2D
class_name FrontierHeatOverlay

const Config = preload("res://core/Config.gd")
const HEATMAP_REDRAW_INTERVAL := 0.15

var unit_manager: UnitManager = null
var show_heatmap := false
var _redraw_accum := 0.0
var _snapshot_cache: Dictionary = {}

func _process(delta: float) -> void:
	if Input.is_action_just_pressed(Config.FRONTIER_DEBUG_TOGGLE_ACTION):
		show_heatmap = not show_heatmap
		visible = show_heatmap
		_redraw_accum = HEATMAP_REDRAW_INTERVAL
		if show_heatmap and unit_manager != null:
			_snapshot_cache = unit_manager.frontier_debug_snapshot()
		queue_redraw()

	if not show_heatmap:
		return
	_redraw_accum += delta
	if _redraw_accum < HEATMAP_REDRAW_INTERVAL:
		return
	_redraw_accum = 0.0
	if unit_manager != null:
		_snapshot_cache = unit_manager.frontier_debug_snapshot()
	queue_redraw()

func _draw() -> void:
	if not show_heatmap or unit_manager == null:
		return

	var entries_variant = _snapshot_cache.get("entries", [])
	if entries_variant.is_empty():
		return

	var min_score := float(_snapshot_cache.get("min_score", 0.0))
	var max_score := float(_snapshot_cache.get("max_score", 1.0))
	var score_span := maxf(max_score - min_score, 0.001)
	var selected_cells_lookup: Dictionary = {}
	var selected_cells_variant = _snapshot_cache.get("selected_cells", [])
	for selected_cell_variant in selected_cells_variant:
		var selected_cell: Vector2i = selected_cell_variant
		if selected_cell.x < 0 or selected_cell.y < 0:
			continue
		selected_cells_lookup[selected_cell] = true
	var cell_size := float(Config.CELL_SIZE)

	for entry_variant in entries_variant:
		var entry: Dictionary = entry_variant
		var cell: Vector2i = entry.get("cell", Vector2i(-1, -1))
		var score := float(entry.get("score", 0.0))
		var normalized := clampf((score - min_score) / score_span, 0.0, 1.0)
		var color := _heat_color(normalized)
		var rect := Rect2(
			Vector2(float(cell.x) * cell_size, float(cell.y) * cell_size),
			Vector2.ONE * cell_size
		)
		draw_rect(rect, color)
		if selected_cells_lookup.has(cell):
			draw_rect(rect.grow(1.0), Color(0.45, 0.95, 1.0, 0.95), false, 2.0)

	var selected_world_pos: Vector2 = _snapshot_cache.get("selected_creature_world_position", Vector2.ZERO)
	var selected_radius_cells := float(_snapshot_cache.get("selected_creature_radius_cells", 0.0))
	if selected_radius_cells > 0.0:
		draw_arc(
			selected_world_pos,
			selected_radius_cells * cell_size,
			0.0,
			TAU,
			64,
			Color(0.45, 0.95, 1.0, 0.75),
			2.0
		)

func _heat_color(t: float) -> Color:
	if t <= 0.5:
		return Color(1.0, lerpf(0.1, 0.95, t * 2.0), 0.08, 0.55)
	return Color(lerpf(1.0, 0.12, (t - 0.5) * 2.0), 0.95, 0.08, 0.55)
