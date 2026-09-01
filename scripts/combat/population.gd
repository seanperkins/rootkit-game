class_name Population extends RefCounted

## One packed-array entity population. No nodes, no physics. Despawn is
## swap-remove so live entities stay a dense prefix, which is what keeps
## MultiMesh.visible_instance_count correct.

const ALIVE := 0
const DEAD := 1
const FLIPPED := 2

var pos: PackedVector2Array
## Where this entity was at the END of the previous tick — the render layer's
## other known state. Rendering lerps between this and `pos`, so it draws one
## tick in the past and NEVER extrapolates: every frame it shows is a point
## between two positions the simulation actually occupied.
##
## It lives HERE rather than as a parallel array in run.gd on purpose. `despawn`
## swap-removes it with everything else and `spawn` initialises it, so it cannot
## fall out of step with `pos` the way a hand-relocated array can.
var prev_pos: PackedVector2Array
var vel: PackedVector2Array
var force: PackedVector2Array      # steering, computed one tick ahead
var integrity: PackedFloat32Array
var corruption: PackedFloat32Array
var type_index: PackedInt32Array
var radius: PackedFloat32Array
var generation: PackedInt32Array
var state: PackedByteArray

var capacity: int
var count: int = 0
var _next_generation: int = 1

func _init(p_capacity: int) -> void:
	capacity = p_capacity
	pos.resize(capacity)
	prev_pos.resize(capacity)
	vel.resize(capacity)
	force.resize(capacity)
	integrity.resize(capacity)
	corruption.resize(capacity)
	type_index.resize(capacity)
	radius.resize(capacity)
	generation.resize(capacity)
	state.resize(capacity)

## Returns the new index, or -1 when the pool is full. A full pool drops the
## spawn and the caller counts it; buffers are never resized at runtime.
func spawn(p: Vector2, v: Vector2, hp: float, r: float, ti: int) -> int:
	if count >= capacity:
		return -1
	var i := count
	pos[i] = p
	# NOT the previous occupant's position. Without this a recycled slot draws
	# the new entity streaking in from wherever the dead one fell.
	prev_pos[i] = p
	vel[i] = v
	force[i] = Vector2.ZERO      # never inherit the previous occupant's force
	integrity[i] = hp
	corruption[i] = 0.0
	type_index[i] = ti
	radius[i] = r
	generation[i] = _next_generation
	state[i] = ALIVE
	_next_generation += 1
	count = i + 1
	return i

## Swap-remove. `force` moves with the entity, or the tail entity relocated
## into this slot would integrate using the dead entity's steering force.
func despawn(i: int) -> void:
	var last := count - 1
	if i != last:
		pos[i] = pos[last]
		prev_pos[i] = prev_pos[last]
		vel[i] = vel[last]
		force[i] = force[last]
		integrity[i] = integrity[last]
		corruption[i] = corruption[last]
		type_index[i] = type_index[last]
		radius[i] = radius[last]
		generation[i] = generation[last]
		state[i] = state[last]
	count = last

func integrate(dt: float) -> void:
	for i in count:
		vel[i] += force[i] * dt
		pos[i] += vel[i] * dt

## Open a new tick: what `pos` holds now becomes the render layer's PAST.
##
## Called once per tick before anything moves, and ABOVE the tick guard — a
## paused run must keep prev_pos == pos, or every entity oscillates between two
## positions for the length of the pause while the frame fraction cycles.
##
## `duplicate()`, NOT `prev_pos = pos`. A plain assignment aliases the same
## buffer: writing `pos[i]` later in the tick writes prev_pos[i] with it and
## there is nothing left to interpolate between. duplicate() is one memcpy in
## C++, which is far cheaper than the per-entity GDScript loop it replaces.
func snapshot() -> void:
	prev_pos = pos.duplicate()

## Move an entity DISCONTINUOUSLY — a recycle, a warp, anything that is not the
## continuation of the path it was already on.
##
## Interpolation is what makes this necessary: setting `pos` alone leaves
## `prev_pos` on the far side of the arena and the entity draws a streak across
## the whole screen for one tick. Every non-integrating write to `pos` must come
## through here.
func teleport(i: int, p: Vector2) -> void:
	pos[i] = p
	prev_pos[i] = p

## Where to DRAW entity `i` this frame. `alpha` is the fraction through the
## current physics tick; 0 is last tick's position, 1 is this tick's.
func render_pos(i: int, alpha: float) -> Vector2:
	return prev_pos[i].lerp(pos[i], alpha)
