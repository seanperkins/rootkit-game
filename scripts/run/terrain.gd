class_name Terrain extends RefCounted

## The subnet's static arena: blocking walls and non-blocking effect zones,
## generated per subnet from the run seed.
##
## Two representations of one fact, deliberately. `rects` is what the generator
## writes and what the renderer draws — a few dozen entries. The two byte grids
## are what the RUNTIME asks, and they exist so that nothing on the hot path
## ever iterates a rect list: every question is one array index. The grids are
## baked once when a subnet begins and never mutated, which is what lets them
## stay a bare index with no bookkeeping.
##
## Pure: no nodes, no tree, no signals. Driven directly by tests.

enum Kind { WALL, HAZARD, SLOW, CORRUPTION }

const CELL := 32.0

## Per second, so they are frame-rate independent. Starting values, expected to
## move once the arena has been played rather than reasoned about.
const HAZARD_DPS := 12.0
const SLOW_FACTOR := 0.6
const CORRUPTION_PER_SEC := 8.0

var origin: Vector2
var size: Vector2
var w: int
var h: int
var solid: PackedByteArray
## Kind + 1, so that zero means "no zone" and the array can start zeroed.
var zone: PackedByteArray
var rects: Array = []          # [Rect2, Kind] pairs, for generation and drawing

func _init(p_origin: Vector2, p_size: Vector2) -> void:
	origin = p_origin
	size = p_size
	w = int(ceil(size.x / CELL))
	h = int(ceil(size.y / CELL))
	solid = PackedByteArray()
	solid.resize(w * h)
	zone = PackedByteArray()
	zone.resize(w * h)

func cell_xy(p: Vector2) -> Vector2i:
	return Vector2i(int(floor((p.x - origin.x) / CELL)),
		int(floor((p.y - origin.y) / CELL)))

func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < w and c.y < h

## -1 when the point is outside the arena, so callers can tell "no cell" from
## "cell zero" without a second bounds call.
func cell_index(p: Vector2) -> int:
	var c := cell_xy(p)
	if not in_bounds(c):
		return -1
	return c.y * w + c.x

## Outside the arena is OPEN, never solid. Enemies spawn on a 720-unit ring
## around the player, which sits partly outside the bounds whenever the player
## is near an edge; solid-outside would reject every one of those spawns and
## starve the wave.
func is_solid(p: Vector2) -> bool:
	var i := cell_index(p)
	if i < 0:
		return false
	return solid[i] != 0

func zone_at(p: Vector2) -> int:
	var i := cell_index(p)
	if i < 0:
		return -1
	return int(zone[i]) - 1
