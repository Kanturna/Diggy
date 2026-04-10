extends Node2D
class_name FrontierHeatOverlay

const Config = preload("res://core/Config.gd")

var unit_manager: UnitManager = null
var show_heatmap := false

func _process(_delta: float) -> void:
	if Input.is_action_just_pressed(Config.FRONTIER_DEBUG_TOGGLE_ACTION):
		show_heatmap = not show_heatmap
		visible = show_heatmap
		queue_redraw()

	if not show_heatmap:
		return
	queue_redraw()

func _draw() -> void:
	if not show_heatmap or unit_manager == null:
		return

	var snapshot: Dictionary = unit_manager.frontier_debug_snapshot()
	var entries_variant = snapshot.get("entries", [])
	if entries_variant.is_empty():
		return

	var min_score := float(snapshot.get("min_score", 0.0))
	var max_score := float(snapshot.get("max_score", 1.0))
	var score_span := maxf(max_score - min_score, 0.001)
	var selected_cell: Vector2i = snapshot.get("selected_frontier_cell", Vector2i(-1, -1))
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
		if cell == selected_cell:
			draw_rect(rect.grow(1.0), Color(0.45, 0.95, 1.0, 0.95), false, 2.0)

func _heat_color(t: float) -> Color:
	if t <= 0.5:
		return Color(1.0, lerpf(0.1, 0.95, t * 2.0), 0.08, 0.55)
	return Color(lerpf(1.0, 0.12, (t - 0.5) * 2.0), 0.95, 0.08, 0.55)
