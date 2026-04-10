extends CanvasLayer
class_name DebugOverlay

const MaterialType = preload("res://core/MaterialType.gd")
const Config = preload("res://core/Config.gd")

@onready var _label: Label = $Panel/MarginContainer/DebugLabel

var world: WorldModel
var renderer: WorldMaterialRenderer
var unit_manager: UnitManager = null
var is_visible_overlay := true
var startup_timings := {}
var creature_count := 0

func setup(world_model: WorldModel, world_renderer: WorldMaterialRenderer) -> void:
	world = world_model
	renderer = world_renderer
	visible = is_visible_overlay

func set_startup_timings(timings: Dictionary) -> void:
	startup_timings = timings.duplicate()

func set_creature_count(count: int) -> void:
	creature_count = count

func _process(_delta: float) -> void:
	if Input.is_action_just_pressed(Config.DEBUG_TOGGLE_ACTION):
		is_visible_overlay = not is_visible_overlay
		visible = is_visible_overlay

	if not visible or world == null or renderer == null:
		return

	var world_mouse := get_viewport().get_camera_2d().get_global_mouse_position()
	var cell := renderer.world_to_cell(world_mouse)
	var text := _build_debug_text(cell)
	_label.text = text

func _build_debug_text(cell: Vector2i) -> String:
	var lines: Array[String] = []
	var camera := get_viewport().get_camera_2d()
	lines.append("FPS: %d" % Engine.get_frames_per_second())
	lines.append("Seed: %d" % world.seed)
	if unit_manager != null:
		lines.append("Creatures: %d" % unit_manager.creature_count())
		var creature_debug := unit_manager.debug_snapshot()
		if not creature_debug.is_empty():
			var target_cell: Vector2i = creature_debug.get("target_cell", Vector2i(-1, -1))
			var frontier_cell: Vector2i = creature_debug.get("frontier_cell", Vector2i(-1, -1))
			var dig_cell: Vector2i = creature_debug.get("dig_cell", Vector2i(-1, -1))
			var staging_cell: Vector2i = creature_debug.get("staging_cell", Vector2i(-1, -1))
			var region_anchor: Vector2i = creature_debug.get("region_id_anchor", Vector2i(-1, -1))
			var target_dir: Vector2 = creature_debug.get("target_direction", Vector2.ZERO)
			lines.append(
				"Creature: %s / %s" % [
					str(creature_debug.get("intent", "unknown")),
					str(creature_debug.get("action", "idle")),
				]
			)
			lines.append(
				"Target: cell=(%d,%d) staging=(%d,%d)" % [
					target_cell.x,
					target_cell.y,
					staging_cell.x,
					staging_cell.y,
				]
			)
			lines.append(
				"Frontier: first=(%d,%d) dig=(%d,%d) %.2fs" % [
					frontier_cell.x,
					frontier_cell.y,
					dig_cell.x,
					dig_cell.y,
					float(creature_debug.get("dig_progress", 0.0)),
				]
			)
			lines.append(
				"Dir: (%.2f, %.2f) path=%d/%d cost=%d" % [
					target_dir.x,
					target_dir.y,
					int(creature_debug.get("path_index", 0)),
					int(creature_debug.get("path_len", 0)),
					int(creature_debug.get("path_cost", 0)),
				]
			)
			lines.append(
				"Cluster: %s total=%.2f build=%.2f sensor=%.2f" % [
					str(creature_debug.get("selected_cluster_id", "")),
					float(creature_debug.get("frontier_score", 0.0)),
					float(creature_debug.get("build_score", 0.0)),
					float(creature_debug.get("sensor_score", 0.0)),
				]
			)
			lines.append(
				"Signals: depth=%.2f cont=%.2f hollow=%.2f span=%.2f path=%d" % [
					float(creature_debug.get("depth_score", 0.0)),
					float(creature_debug.get("continuity_score", 0.0)),
					float(creature_debug.get("sensor_hollow_score", 0.0)),
					float(creature_debug.get("sensor_open_span_score", 0.0)),
					int(creature_debug.get("path_cost", 0)),
				]
			)
			lines.append(
				"Penalty: parallel=%.2f niche=%.2f scrape=%.2f crowd=%.2f" % [
					float(creature_debug.get("parallel_risk", 0.0)),
					float(creature_debug.get("niche_risk", 0.0)),
					float(creature_debug.get("scrape_penalty", 0.0)),
					float(creature_debug.get("frontier_crowding_penalty", 0.0)),
				]
			)
			lines.append(
				"Pick: weight=%.2f filter=%s" % [
					float(creature_debug.get("selection_weight", 0.0)),
					str(creature_debug.get("filter_reason", "")),
				]
			)
			lines.append(
				"Region: anchor=(%d,%d) size=%d clusters=%d" % [
					region_anchor.x,
					region_anchor.y,
					int(creature_debug.get("region_size", 0)),
					int(creature_debug.get("frontier_cluster_count", 0)),
				]
			)
			lines.append("Heatmap: V")
			lines.append("Replan: %s" % str(creature_debug.get("replan_reason", "")))
	if not startup_timings.is_empty():
		lines.append(
			"Load ms: total=%d gen=%d render=%d" % [
				int(startup_timings.get("ready_total_ms", 0)),
				int(startup_timings.get("world_generate_ms", 0)),
				int(startup_timings.get("renderer_setup_ms", 0)),
			]
		)
		lines.append(
			"Load detail: core=%d cam=%d unit=%d dbg=%d sig=%d" % [
				int(startup_timings.get("world_core_ms", 0)),
				int(startup_timings.get("camera_setup_ms", 0)),
				int(startup_timings.get("unit_setup_ms", 0)),
				int(startup_timings.get("debug_setup_ms", 0)),
				int(startup_timings.get("signal_connect_ms", 0)),
			]
		)
		lines.append(
			"Gen detail: fill=%d carve=%d smooth=%d var=%d" % [
				int(startup_timings.get("world_generate_fill_ms", 0)),
				int(startup_timings.get("world_generate_carve_ms", 0)),
				int(startup_timings.get("world_generate_smooth_ms", 0)),
				int(startup_timings.get("world_generate_variants_ms", 0)),
			]
		)
	if camera != null:
		var zoom_levels := Config.CAMERA_ZOOM_LEVELS
		var zoom_level_index := zoom_levels.find(camera.zoom.x)
		if zoom_level_index >= 0:
			lines.append("Zoom: %.4f (%d/%d, Q/E or wheel)" % [camera.zoom.x, zoom_level_index + 1, zoom_levels.size()])
		else:
			lines.append("Zoom: %.4f" % camera.zoom.x)
	lines.append("Cell: (%d, %d)" % [cell.x, cell.y])

	if not world.is_in_bounds(cell.x, cell.y):
		lines.append("Material: OUT_OF_BOUNDS")
		return "\n".join(lines)

	var data := world.get_cell(cell.x, cell.y)
	var material := int(data.get("material", MaterialType.Id.EMPTY))
	var variant := int(data.get("variant", 0))
	var cell_flags := int(data.get("flags", 0))

	var material_name := "EMPTY"
	if material == MaterialType.Id.EARTH:
		material_name = "EARTH"

	var chunk := Vector2i(cell.x / world.chunk_size, cell.y / world.chunk_size)

	lines.append("Material: %s" % material_name)
	lines.append("Variant: %d" % variant)
	lines.append("Flags: %d" % cell_flags)
	lines.append("Chunk: (%d, %d)" % [chunk.x, chunk.y])

	return "\n".join(lines)
