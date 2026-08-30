class_name Population extends RefCounted

## One packed-array entity population. No nodes, no physics. Despawn is
## swap-remove so live entities stay a dense prefix, which is what keeps
## MultiMesh.visible_instance_count correct.

const ALIVE := 0
const DEAD := 1
const FLIPPED := 2

var pos: PackedVector2Array
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
