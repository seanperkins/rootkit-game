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

## Walls are kept clear of the player's start by this much, so the opening
## seconds are never spent wedged against rock.
const WALL_MARGIN := 260.0

const DENSITY_BASE := 0.08
const DENSITY_PER_SUBNET := 0.05

## The floor the generator's own output is held to in test. Filling unreachable
## pockets cannot fail, but it CAN eat the arena on a pathological seed, and a
## closet is as unplayable as a sealed pocket.
const REACHABLE_FLOOR := 0.70

## Bounded, not "until the target is met". An unbounded placement loop on a
## dense subnet with an unlucky seed is a hang, and a hang in generation is a
## hang before the first frame of the subnet.
const PLACE_ATTEMPTS := 4000

const ZONES_MIN := 2
const ZONES_MAX := 4

## WALL is deliberately absent: it is the blocking kind and lives in `solid`.
## The zone layer holds only the non-blocking effects.
const ZONE_KINDS := [Kind.HAZARD, Kind.SLOW, Kind.CORRUPTION]

static func density_for(subnet: int) -> float:
	return DENSITY_BASE + DENSITY_PER_SUBNET * float(maxi(subnet, 1) - 1)

func generate(seed_value: int, subnet: int, player_start: Vector2) -> void:
	var rng := RandomNumberGenerator.new()
	# The subnet is mixed in, not added, so subnet 2 of one run is not subnet 1
	# of the run seeded one higher.
	rng.seed = hash(str(seed_value, ":", subnet))
	solid.fill(0)
	zone.fill(0)
	rects.clear()

	var target := int(float(w * h) * density_for(subnet))
	var placed := 0
	var attempts := 0
	while placed < target and attempts < PLACE_ATTEMPTS:
		attempts += 1
		var rw := rng.randi_range(2, 6)
		var rh := rng.randi_range(2, 6)
		var cx := rng.randi_range(0, w - rw)
		var cy := rng.randi_range(0, h - rh)
		var r := Rect2(origin + Vector2(cx, cy) * CELL, Vector2(rw, rh) * CELL)
		# grow() by the margin and ask whether the start is inside: that is
		# exactly "this rect comes within WALL_MARGIN of the player".
		if r.grow(WALL_MARGIN).has_point(player_start):
			continue
		for y in range(cy, cy + rh):
			for x in range(cx, cx + rw):
				var i := y * w + x
				if solid[i] == 0:
					solid[i] = 1
					placed += 1
		rects.append([r, Kind.WALL])

	_fill_unreachable(player_start)
	_place_zones(rng, player_start)

## Flood-fill the open cells from the player's start; anything the fill does not
## reach becomes rock.
##
## Filling rather than carving, because filling CANNOT FAIL. Carving a corridor
## to a stranded pocket needs its own pathfinding and can itself leave a second
## pocket; filling terminates in one pass and leaves exactly one open region by
## construction. The cost is that a bad seed could eat the arena, which is why
## reachable_fraction has a floor asserted in test.
func _fill_unreachable(player_start: Vector2) -> void:
	var start := cell_index(player_start)
	if start < 0 or solid[start] != 0:
		return
	var seen := _reach(start)
	for i in solid.size():
		if solid[i] == 0 and seen[i] == 0:
			solid[i] = 1

func _reach(start: int) -> PackedByteArray:
	var seen := PackedByteArray()
	seen.resize(w * h)
	var stack := PackedInt32Array([start])
	while stack.size() > 0:
		var i := stack[stack.size() - 1]
		stack.remove_at(stack.size() - 1)
		if seen[i] != 0 or solid[i] != 0:
			continue
		seen[i] = 1
		var x := i % w
		var y := i / w
		if x > 0: stack.append(i - 1)
		if x < w - 1: stack.append(i + 1)
		if y > 0: stack.append(i - w)
		if y < h - 1: stack.append(i + w)
	return seen

func reachable_fraction(player_start: Vector2) -> float:
	var start := cell_index(player_start)
	if start < 0 or solid[start] != 0:
		return 0.0
	var seen := _reach(start)
	var n := 0
	for i in seen.size():
		if seen[i] != 0:
			n += 1
	return float(n) / float(w * h)

## Zones go down AFTER walls and after the connectivity fill, so a zone can
## never be sealed behind rock or overwritten by a pocket being filled in.
func _place_zones(rng: RandomNumberGenerator, player_start: Vector2) -> void:
	var n := rng.randi_range(ZONES_MIN, ZONES_MAX)
	var attempts := 0
	var made := 0
	while made < n and attempts < PLACE_ATTEMPTS:
		attempts += 1
		var rw := rng.randi_range(3, 7)
		var rh := rng.randi_range(3, 7)
		var cx := rng.randi_range(0, w - rw)
		var cy := rng.randi_range(0, h - rh)
		var r := Rect2(origin + Vector2(cx, cy) * CELL, Vector2(rw, rh) * CELL)
		if r.grow(WALL_MARGIN).has_point(player_start):
			continue
		var kind: int = ZONE_KINDS[rng.randi_range(0, ZONE_KINDS.size() - 1)]
		var wrote := false
		for y in range(cy, cy + rh):
			for x in range(cx, cx + rw):
				var i := y * w + x
				# Open cells only. Painting a zone under rock produces an effect
				# nothing can ever stand in.
				if solid[i] == 0:
					zone[i] = kind + 1
					wrote = true
		if wrote:
			rects.append([r, kind])
			made += 1

## Resolve a step per AXIS rather than all at once.
##
## Rejecting the whole step on any collision makes a wall sticky: running into
## one diagonally stops you dead instead of sliding along it, which reads as the
## controls failing rather than as terrain. Taking each axis on its own merit
## costs one extra lookup and is the difference between the two.
func slide(from: Vector2, delta: Vector2) -> Vector2:
	var p := from
	var try_x := Vector2(p.x + delta.x, p.y)
	if not is_solid(try_x):
		p = try_x
	var try_y := Vector2(p.x, p.y + delta.y)
	if not is_solid(try_y):
		p = try_y
	return p

## How far ahead an enemy looks for rock, and how hard it turns from it.
const LOOK_AHEAD := 46.0
const AVOID_FORCE := 90.0

## A steering force away from a wall directly ahead, or zero in the open.
##
## Steering, NOT pathfinding. An enemy pushed off a wall it is walking into will
## slide along it and go around small obstacles; it will not solve a concave
## one. That is the enemy-behaviour pass's problem, and until then the hard
## rejection in the integrate step is what keeps the invariant — an enemy may
## look stupid against a wall, but it can never end a tick inside one.
func avoid(at: Vector2, heading: Vector2) -> Vector2:
	if heading.length_squared() < 0.000001:
		return Vector2.ZERO
	var dir := heading.normalized()
	if not is_solid(at + dir * LOOK_AHEAD):
		return Vector2.ZERO
	# Probe both perpendiculars and turn toward whichever is clear. Turning a
	# fixed way makes every enemy hitting the same wall pile into one corner.
	var left := Vector2(-dir.y, dir.x)
	var right := -left
	var left_clear := not is_solid(at + left * LOOK_AHEAD)
	var right_clear := not is_solid(at + right * LOOK_AHEAD)
	if left_clear and not right_clear:
		return left * AVOID_FORCE
	if right_clear and not left_clear:
		return right * AVOID_FORCE
	# Both clear or both blocked: back off along the reverse heading, which is
	# always the way it came and therefore always was passable.
	return -dir * AVOID_FORCE

## How far out nearest_open will look, in cells.
const OPEN_SEARCH_RINGS := 8

## The nearest open point to `p`, or `p` itself if none is found within the bound.
##
## Bounded on purpose. "Loop until you find open ground" is a hang the moment a
## seed produces a field dense enough not to have any nearby, and a hang in the
## spawn path freezes the subnet before its first frame. Returning the input is
## the honest failure: one enemy spawns in rock, walks out under the slide rule,
## and the game runs.
func nearest_open(p: Vector2) -> Vector2:
	if not is_solid(p):
		return p
	for ring in range(1, OPEN_SEARCH_RINGS + 1):
		var step := float(ring) * CELL
		for k in 8:
			var a := TAU * k / 8.0
			var q := p + Vector2(cos(a), sin(a)) * step
			if not is_solid(q):
				return q
	return p
