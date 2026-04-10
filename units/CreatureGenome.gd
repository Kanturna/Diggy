extends RefCounted
class_name CreatureGenome

var body_width_cells: float
var body_length_cells: float
var tail_segments: int
var speed_cells_per_second: float
var turn_interval_min: float
var turn_interval_max: float
var body_color := Color8(208, 224, 206)
var head_color := Color8(228, 238, 226)
var jaw_color := Color8(240, 243, 236)

func _init(
	new_body_width_cells: float,
	new_body_length_cells: float,
	new_tail_segments: int,
	new_speed_cells_per_second: float,
	new_turn_interval_min: float,
	new_turn_interval_max: float
) -> void:
	body_width_cells = new_body_width_cells
	body_length_cells = new_body_length_cells
	tail_segments = new_tail_segments
	speed_cells_per_second = new_speed_cells_per_second
	turn_interval_min = new_turn_interval_min
	turn_interval_max = new_turn_interval_max
