class_name FlowField extends RefCounted

## A breadth-first distance field flooding out from the player, over a window
## that follows them — the same shape as `Grid`, and for the same reason: the
## campaign is one map five arenas wide and almost none of it matters to
## something standing next to you.
##
## This exists for BOSSES. Ordinary enemies chase the straight line and shove
## through each other, and a hundred of them snagging on a wall reads as a
## swarm behaving like a swarm. A mini-boss doing it reads as broken — it is one
## object, the player is watching it, and a set-piece stuck on a corner for
## fifteen seconds is the fight not happening.
##
## Pure: it takes a Terrain and reads it, and holds no node reference.

## Half-width in cells. 24 each way at CELL 32 covers 1536px, comfortably past
## the 620px a mini-boss spawns at and the ~1150 a straggler is recycled from.
const RADIUS := 24
const SIDE := RADIUS * 2 + 1
## Anything at or above this never had a path — walls, and cells the flood could
## not reach.
const UNREACHED := 1 << 28

const DX4 := [1, -1, 0, 0]
const DY4 := [0, 0, 1, -1]

var _dist: PackedInt32Array = PackedInt32Array()
## Window origin, in cells.
var _ox := 0
var _oy := 0
var _centre := Vector2i(-99999, -99999)
var _ready := false

## Rebuilt only when the player crosses into a new CELL, not every tick. At
## walking speed that is every few frames, and the flood is 2401 cells.
func needs_rebuild(terrain, at: Vector2) -> bool:
	return not _ready or terrain.cell_xy(at) != _centre

func rebuild(terrain, at: Vector2) -> void:
	var c: Vector2i = terrain.cell_xy(at)
	_centre = c
	_ox = c.x - RADIUS
	_oy = c.y - RADIUS
	if _dist.size() != SIDE * SIDE:
		_dist.resize(SIDE * SIDE)
	_dist.fill(UNREACHED)

	# The player's own cell may be solid — they can be pushed into geometry —
	# so the flood seeds from it regardless of walkability, and only its
	# NEIGHBOURS are filtered. Seeding nothing there would leave every boss
	# without a gradient exactly when it matters.
	# Hoisted: `voided` is empty until a collapse starts, and checking that per
	# cell inside the flood is 2401 redundant property reads.
	var voided: PackedByteArray = terrain.voided
	var start := (c.y - _oy) * SIDE + (c.x - _ox)
	_dist[start] = 0
	var queue := PackedInt32Array()
	queue.append(start)
	var head := 0
	while head < queue.size():
		var idx := queue[head]
		head += 1
		var lx := idx % SIDE
		var ly := idx / SIDE
		var nd := _dist[idx] + 1
		# Four-way. Eight-way would cut diagonal corners through walls that
		# terrain.slide would then refuse, and a boss shoving at a corner it was
		# told to walk through is the bug this class exists to remove.
		for k in 4:
			var nx: int = lx + DX4[k]
			var ny: int = ly + DY4[k]
			if nx < 0 or ny < 0 or nx >= SIDE or ny >= SIDE:
				continue
			var gx: int = nx + _ox
			var gy: int = ny + _oy
			if gx < 0 or gy < 0 or gx >= terrain.w or gy >= terrain.h:
				continue
			var ni := ny * SIDE + nx
			if _dist[ni] <= nd:
				continue
			# The cell arrays, indexed directly. terrain.is_solid takes a WORLD
			# point, converts it back to the cell we already have, and first
			# walks every dynamic blocker — O(blocks) per cell, 2401 times per
			# rebuild, which took the tick's p95 from 2.8ms to 6.9ms. Those
			# blockers are transient props and have no business steering a boss
			# across the arena anyway.
			var ci: int = gy * terrain.w + gx
			if terrain.solid[ci] != 0:
				continue
			if not voided.is_empty() and voided[ci] != 0:
				continue
			_dist[ni] = nd
			queue.append(ni)
	_ready = true

func _at(lx: int, ly: int) -> int:
	if lx < 0 or ly < 0 or lx >= SIDE or ly >= SIDE:
		return UNREACHED
	return _dist[ly * SIDE + lx]

## Downhill, as a unit world direction. Vector2.ZERO when there is no gradient
## to follow — outside the window, or walled in — and the caller falls back to
## the straight line, which is what the game did before this existed.
func dir_at(terrain, p: Vector2) -> Vector2:
	if not _ready:
		return Vector2.ZERO
	var c: Vector2i = terrain.cell_xy(p)
	var lx := c.x - _ox
	var ly := c.y - _oy
	if lx < 0 or ly < 0 or lx >= SIDE or ly >= SIDE:
		return Vector2.ZERO
	var here := _at(lx, ly)
	var best := here
	var bx := 0
	var by := 0
	# Eight-way for the READ, four-way for the flood: the gradient is already
	# guaranteed to run through open ground, so a diagonal step between two
	# open cells is safe and looks far less like tile-following.
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			var d := _at(lx + dx, ly + dy)
			if d < best:
				best = d
				bx = dx
				by = dy
	if best >= here or (bx == 0 and by == 0):
		return Vector2.ZERO
	return Vector2(float(bx), float(by)).normalized()
