extends Node2D
class_name Creature

# Redesign based on SocialSim AKM rendering pattern:
# 5-position chain with lag, sinus swim-phase for tail sway,
# 6 oriented ovals (tail2, tail1, body, head, jaw_L, jaw_R).

const MaterialType = preload("res://core/MaterialType.gd")
const Config       = preload("res://core/Config.gd")

# ── Body dimensions (world-pixels; 1 cell = 3 px) ───────────────────────────
const LOWER_R := 2.3    # body oval base radius
const UPPER_R := 2.0    # head oval base radius
const TAIL_R1 := 1.5    # first tail segment radius
const TAIL_R2 := 1.0    # second tail segment radius (tip)
const JAW_R   := 0.85   # jaw oval radius

# ── Positional offsets ───────────────────────────────────────────────────────
const HEAD_FORWARD    := 0.90   # head center = body + facing * LOWER_R * this
const TAIL_BASE_OFF   := 1.80   # tail attachment behind body center
const TAIL1_EXTRA     := 0.25   # extra tail1 gap (in TAIL_R1 units)
const SEG_GAP1        := 1.50   # tail1→tail2 gap (in TAIL_R1 units)
const SEG_GAP2        := 1.80   # tail2 extra gap (in TAIL_R2 units)
const JAW_FORWARD_MUL := 0.95   # jaw base = head_center + facing * UPPER_R * this
const JAW_SPREAD_MUL  := 0.65   # jaw offset sideways = UPPER_R * this

# ── Blend constants for poly construction ────────────────────────────────────
const TAIL1_ATTACH := 0.55   # lerp between tail_base and chain_pos[3]
const TAIL2_ATTACH := 0.55   # lerp between tail1_center and chain_pos[4]
const TAIL1_AXIS   := 0.50   # how much tail1 follows its own direction
const TAIL2_AXIS   := 0.60   # how much tail2 follows its own direction

# ── Swim / sway ──────────────────────────────────────────────────────────────
const SWIM_MIN       := 2.5    # oscillations/s at low speed
const SWIM_MAX       := 5.5    # oscillations/s at full speed
const SWAY1_MULT     := 0.9    # tail1 lateral amplitude (× TAIL_R1 × speed_ratio)
const SWAY2_MULT     := 1.4    # tail2 lateral amplitude
const PHASE_OFF      := PI * 0.45   # phase offset between tail1 and tail2
const MIN_SWIM_SPEED := 3.0    # minimum speed to advance swim_phase

# ── Movement ─────────────────────────────────────────────────────────────────
const SPEED    := 22.0
var velocity   := Vector2.ZERO
var _dir_timer := 0.0
var world: WorldModel = null

# ── Chain (indices: 0=node-pos, 1=upper-body, 2=lower-body, 3=tail1, 4=tail2)
var _chain_pos : Array[Vector2] = []
# lag[i]: blend factor per frame at 60 fps; higher = snappier follow
var _chain_lag  := [0.0, 0.18, 0.12, 0.22, 0.18]
var _facing_dir := Vector2.RIGHT
var _swim_phase := 0.0

# ── Polygon cache ────────────────────────────────────────────────────────────
# [0]=tail2, [1]=tail1, [2]=body, [3]=head, [4]=jaw_L, [5]=jaw_R
var _polys: Array[PackedVector2Array] = []

const BASE_COLOR := Color(0.87, 0.93, 0.79)

# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_chain_pos.resize(5)
	_polys.resize(6)
	for i in 5:
		_chain_pos[i] = global_position
	for i in 6:
		_polys[i] = PackedVector2Array()
	_new_dir()

func setup(world_model: WorldModel) -> void:
	world = world_model

# ── Per-frame update ─────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_dir_timer -= delta
	if _dir_timer <= 0.0:
		_new_dir()

	var nxt := global_position + velocity * delta
	if _passable(nxt):
		global_position = nxt
	else:
		_new_dir()

	_update_chain(delta)
	_rebuild_polys()
	queue_redraw()

func _passable(pos: Vector2) -> bool:
	if world == null:
		return true
	var cx := int(floor(pos.x / Config.CELL_SIZE))
	var cy := int(floor(pos.y / Config.CELL_SIZE))
	if not world.is_in_bounds(cx, cy):
		return false
	return world.get_material(cx, cy) == MaterialType.Id.EMPTY

func _new_dir() -> void:
	velocity    = Vector2.from_angle(randf() * TAU) * SPEED
	_dir_timer  = randf_range(1.0, 3.5)

# ── Chain update (SocialSim AKM pattern) ─────────────────────────────────────

func _update_chain(delta: float) -> void:
	_chain_pos[0] = global_position

	# Body segments lag behind the node position
	for i in range(1, 3):
		var blend := clampf(_chain_lag[i] * delta * 60.0, 0.0, 1.0)
		_chain_pos[i] = _chain_pos[i].lerp(_chain_pos[i - 1], blend)

	# Facing direction smoothly tracks velocity
	if velocity.length_squared() > 100.0:
		var target := velocity.normalized()
		_facing_dir = _facing_dir.slerp(target, clampf(8.0 * delta, 0.0, 1.0))
		if _facing_dir.length_squared() > 0.0001:
			_facing_dir = _facing_dir.normalized()

	var facing     := _facing_dir.normalized() if _facing_dir.length_squared() > 0.0001 else Vector2.RIGHT
	var back       := -facing
	var side       := facing.orthogonal()
	var speed_ratio := clampf(velocity.length() / SPEED, 0.0, 1.0)

	# Advance swim phase only when moving
	if velocity.length() > MIN_SWIM_SPEED:
		_swim_phase += delta * lerpf(SWIM_MIN, SWIM_MAX, speed_ratio)

	# Lateral sway for each tail segment (different phase)
	var sway1 := sin(_swim_phase)           * TAIL_R1 * SWAY1_MULT * speed_ratio
	var sway2 := sin(_swim_phase - PHASE_OFF) * TAIL_R1 * SWAY2_MULT * speed_ratio

	var ideal1 := _chain_pos[2] + back * (TAIL_BASE_OFF + TAIL_R1 * TAIL1_EXTRA) + side * sway1
	var ideal2 := ideal1 + back * (TAIL_R1 * SEG_GAP1 + TAIL_R2 * SEG_GAP2) + side * sway2

	_chain_pos[3] = _chain_pos[3].lerp(ideal1, clampf(_chain_lag[3] * delta * 60.0, 0.0, 1.0))
	_chain_pos[4] = _chain_pos[4].lerp(ideal2, clampf(_chain_lag[4] * delta * 60.0, 0.0, 1.0))

# ── Polygon construction ─────────────────────────────────────────────────────

func _rebuild_polys() -> void:
	var facing := _facing_dir.normalized() if _facing_dir.length_squared() > 0.0001 else Vector2.RIGHT
	var back   := -facing
	var side   := facing.orthogonal()

	# Convert chain positions to local draw-space
	var lc2 := to_local(_chain_pos[2])
	var lc3 := to_local(_chain_pos[3])
	var lc4 := to_local(_chain_pos[4])

	# Key anchor points
	var head_center := lc2 + facing * (LOWER_R * HEAD_FORWARD)
	var tail_base   := lc2 + back   * TAIL_BASE_OFF

	# Tail segment centers (blend between geometric ideal and lagged chain pos)
	var tail1_center := tail_base.lerp(lc3, TAIL1_ATTACH)
	var tail2_center := tail1_center.lerp(lc4, TAIL2_ATTACH)

	# Tail segment axes – interpolated between back direction and actual movement
	var t1_raw  := (tail1_center - tail_base).normalized()
	if t1_raw.length_squared() < 0.0001: t1_raw = back
	var t1_axis := back.slerp(t1_raw, TAIL1_AXIS).normalized()

	var t2_raw  := (tail2_center - tail1_center).normalized()
	if t2_raw.length_squared() < 0.0001: t2_raw = t1_axis
	var t2_axis := t1_axis.slerp(t2_raw, TAIL2_AXIS).normalized()

	# Jaw placement
	var jaw_base   := head_center + facing * (UPPER_R * JAW_FORWARD_MUL)
	var jaw_spread := UPPER_R * JAW_SPREAD_MUL

	# Build all six ovals
	_polys[0] = _oval(tail2_center,            TAIL_R2 * 1.20, TAIL_R2, t2_axis)
	_polys[1] = _oval(tail1_center,            TAIL_R1 * 1.20, TAIL_R1, t1_axis)
	_polys[2] = _oval(lc2,                     LOWER_R * 1.30, LOWER_R, facing)
	_polys[3] = _oval(head_center,             UPPER_R * 1.15, UPPER_R, facing)
	_polys[4] = _oval(jaw_base + side * jaw_spread, JAW_R * 1.2, JAW_R, facing)
	_polys[5] = _oval(jaw_base - side * jaw_spread, JAW_R * 1.2, JAW_R, facing)

# Creates an oriented ellipse polygon.
# rx = half-axis along `facing`, ry = half-axis perpendicular.
static func _oval(center: Vector2, rx: float, ry: float, facing: Vector2, n: int = 12) -> PackedVector2Array:
	var pts  := PackedVector2Array()
	var side := facing.orthogonal()
	for i in n:
		var a := TAU * i / float(n)
		pts.append(center + facing * (cos(a) * rx) + side * (sin(a) * ry))
	return pts

# ── Draw ─────────────────────────────────────────────────────────────────────
# Drawn back-to-front so tail is behind body, body behind head, jaws in front.

func _draw() -> void:
	if _polys.is_empty() or _polys[0].is_empty():
		return
	draw_colored_polygon(_polys[0], BASE_COLOR.darkened(0.28))  # tail2 (darkest)
	draw_colored_polygon(_polys[1], BASE_COLOR.darkened(0.18))  # tail1
	draw_colored_polygon(_polys[2], BASE_COLOR)                  # body
	draw_colored_polygon(_polys[3], BASE_COLOR.darkened(0.10))  # head
	draw_colored_polygon(_polys[4], BASE_COLOR.darkened(0.32))  # jaw L (darkest)
	draw_colored_polygon(_polys[5], BASE_COLOR.darkened(0.32))  # jaw R
