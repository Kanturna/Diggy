extends Node2D
class_name Creature

const MaterialType = preload("res://core/MaterialType.gd")
const Config       = preload("res://core/Config.gd")

# ── Body dimensions (world-pixels; 1 cell = 3 px) ──────────────────────────
const BODY_HALF_LEN  := 4.5   # half-length of body ellipse
const BODY_HALF_H    := 2.3   # half-height  (fits in 2-cell corridor, 2×3=6 px)
const HEAD_R         := 2.8   # head radius
const MANDIBLE_LEN   := 4.2   # spike length
const MANDIBLE_BASE  := 1.1   # half-height of mandible base (wide → pointed)

# ── Tail ribbon ─────────────────────────────────────────────────────────────
const TAIL_SEGS := 5          # number of ribbon segments
const TAIL_STEP := 6          # history frames per segment
const TAIL_W0   := 2.1        # ribbon half-width at body
const TAIL_W1   := 0.2        # ribbon half-width at tip

# ── Palette ─────────────────────────────────────────────────────────────────
const C_BODY     := Color(0.87, 0.93, 0.79)
const C_HEAD     := Color(0.82, 0.89, 0.73)
const C_MANDIBLE := Color(0.52, 0.65, 0.42)
const C_TAIL_A   := Color(0.84, 0.91, 0.76)
const C_TAIL_B   := Color(0.65, 0.76, 0.60, 0.0)   # fades to transparent

# ── Movement ────────────────────────────────────────────────────────────────
const SPEED  := 22.0
var velocity := Vector2.ZERO
var _timer   := 0.0
var world: WorldModel = null

# ── Position history for tail spine ─────────────────────────────────────────
var _history: Array[Vector2] = []
const HIST := 80

# ────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	for _i in HIST:
		_history.append(global_position)
	_new_dir()

func setup(world_model: WorldModel) -> void:
	world = world_model

# ── Update ───────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_new_dir()

	var nxt := global_position + velocity * delta
	if _passable(nxt):
		global_position = nxt
	else:
		_new_dir()

	_history.push_front(global_position)
	if _history.size() > HIST:
		_history.resize(HIST)

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
	velocity = Vector2.from_angle(randf() * TAU) * SPEED
	_timer   = randf_range(1.0, 3.5)

# ── Drawing ──────────────────────────────────────────────────────────────────
# All parts are drawn in "facing-right" local space, then rotated once via
# draw_set_transform so the creature always faces its velocity direction.
# The tail spine is built from world-space history positions, inverse-rotated
# into facing-right space; draw_set_transform then rotates them back, so they
# appear at their correct world positions (the creature's actual path).

func _draw() -> void:
	if velocity.is_zero_approx():
		return
	var angle := velocity.angle()
	draw_set_transform(Vector2.ZERO, angle)
	_draw_tail(angle)      # drawn first so body overlaps the attachment point
	_draw_body()
	_draw_head()
	_draw_mandibles()
	draw_set_transform(Vector2.ZERO, 0.0)

# ── Tail ─────────────────────────────────────────────────────────────────────

func _draw_tail(facing: float) -> void:
	# spine[0] = body-back in facing-right space
	var spine: Array[Vector2] = []
	spine.append(Vector2(-BODY_HALF_LEN, 0.0))

	var i := TAIL_STEP
	while i < _history.size() and spine.size() <= TAIL_SEGS:
		var off := (_history[i] - global_position).rotated(-facing)
		spine.append(off)
		i += TAIL_STEP

	for s in range(spine.size() - 1):
		var t0 := float(s)     / float(spine.size() - 1)
		var t1 := float(s + 1) / float(spine.size() - 1)
		var w0 := lerpf(TAIL_W0, TAIL_W1, t0)
		var w1 := lerpf(TAIL_W0, TAIL_W1, t1)
		var a  := spine[s]
		var b  := spine[s + 1]
		if a.distance_squared_to(b) < 0.01:
			continue
		var n := (b - a).normalized().rotated(PI * 0.5)
		draw_colored_polygon(
			PackedVector2Array([a + n * w0, a - n * w0, b - n * w1, b + n * w1]),
			C_TAIL_A.lerp(C_TAIL_B, (t0 + t1) * 0.5)
		)

# ── Body ──────────────────────────────────────────────────────────────────────

func _draw_body() -> void:
	const N := 20
	var pts := PackedVector2Array()
	for i in N:
		var a := TAU * i / float(N)
		pts.append(Vector2(cos(a) * BODY_HALF_LEN, sin(a) * BODY_HALF_H))
	draw_colored_polygon(pts, C_BODY)

# ── Head ─────────────────────────────────────────────────────────────────────

func _draw_head() -> void:
	const N := 14
	var cx := BODY_HALF_LEN + HEAD_R * 0.5
	var pts := PackedVector2Array()
	for i in N:
		var a := TAU * i / float(N)
		pts.append(Vector2(cx + cos(a) * HEAD_R, sin(a) * HEAD_R))
	draw_colored_polygon(pts, C_HEAD)

# ── Mandibles ────────────────────────────────────────────────────────────────
# Two pointed triangles extending from the front of the head.
# Each triangle: wide base at head-front, narrow tip far forward.

func _draw_mandibles() -> void:
	var bx := BODY_HALF_LEN + HEAD_R * 0.5 + HEAD_R * 0.75

	# Upper mandible – base near head, tip forward-up
	draw_colored_polygon(PackedVector2Array([
		Vector2(bx,                 -MANDIBLE_BASE),
		Vector2(bx,                  0.0),
		Vector2(bx + MANDIBLE_LEN,  -MANDIBLE_BASE * 0.18),
	]), C_MANDIBLE)

	# Lower mandible – mirror
	draw_colored_polygon(PackedVector2Array([
		Vector2(bx,                  MANDIBLE_BASE),
		Vector2(bx,                  0.0),
		Vector2(bx + MANDIBLE_LEN,   MANDIBLE_BASE * 0.18),
	]), C_MANDIBLE)
