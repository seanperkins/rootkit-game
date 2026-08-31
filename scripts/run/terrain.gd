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

## The way out. Present from generation and shut; opened by clearing ICE.
var has_gate := false
var gate_pos := Vector2.ZERO
var gate_open := false
## Outward from the arena, so the corridor and the gate's posts know which way
## "through" is.
var gate_dir := Vector2.ZERO
var corridor_end := Vector2.ZERO
## The walkway beyond the gate, as a rect, so it can be drawn as floor. It is
## carved into the margin rather than placed as a rect, so nothing else records
## where it went.
var corridor_rect := Rect2()

## The playable arena, which is now SMALLER than the grid. Collapse and wall
## placement work in here; the corridor lives outside it.
var arena_rect: Rect2

## Distance in cells from the gate over open ground, -1 where unreachable.
## Built once on the boss kill; drives both the collapse order and the route.
var dist_from_gate: PackedInt32Array
var max_dist := 0
var voided: PackedByteArray
## Arena cells ordered by distance from the gate, farthest FIRST, plus how far
## down that order the collapse has already eaten.
var _collapse_order: PackedInt32Array
var _collapse_idx := 0

func _init(p_origin: Vector2, p_size: Vector2) -> void:
	arena_rect = Rect2(p_origin, p_size)
	origin = p_origin - Vector2(MARGIN, MARGIN)
	size = p_size + Vector2(MARGIN, MARGIN) * 2.0
	w = int(ceil(size.x / CELL))
	h = int(ceil(size.y / CELL))
	solid = PackedByteArray()
	solid.resize(w * h)
	zone = PackedByteArray()
	zone.resize(w * h)

## The arena's own cell bounds inside the enlarged grid.
var _ax0: int
var _ay0: int
var _ax1: int
var _ay1: int

func _arena_cells() -> void:
	var a := cell_xy(arena_rect.position)
	var b := cell_xy(arena_rect.position + arena_rect.size)
	_ax0 = a.x + 1
	_ay0 = a.y + 1
	_ax1 = b.x - 1
	_ay1 = b.y - 1

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
	if gate_blocks(p):
		return true
	var i := cell_index(p)
	if i < 0:
		return false
	return solid[i] != 0

## A CLOSED gate still has to stop you.
##
## The mouth and the corridor beyond it are carved open at generation — that is
## what makes them visible from the first second and walkable the moment the
## gate opens. Without this, they were walkable from the first second too, and
## the whole subnet could be skipped by strolling out.
##
## Tested geometrically rather than baked into `solid`, because `solid` is
## static by design: baking would mean mutating the grid when the gate opens,
## and the distance field and collapse order are both built off it.
func gate_blocks(p: Vector2) -> bool:
	if not has_gate or gate_open:
		return false
	var d := p - gate_pos
	# Only from the gate plane OUTWARD, so the arena side is unaffected.
	if d.dot(gate_dir) < -CELL * 1.5:
		return false
	return absf(d.dot(Vector2(-gate_dir.y, gate_dir.x))) < CORRIDOR_HALF_WIDTH + CELL * 2.0

func zone_at(p: Vector2) -> int:
	var i := cell_index(p)
	if i < 0:
		return -1
	return int(zone[i]) - 1

## Walls are kept clear of the player's start by this much, so the opening
## seconds are never spent wedged against rock.
const WALL_MARGIN := 260.0

## Flat across subnets. This was 8% rising to 18%, and the ramp was the wrong
## lever: a late subnet with less room to kite reads as cramped, not as hard.
## Difficulty escalates through enemy HP and the wave table instead.
const DENSITY_BASE := 0.03
const DENSITY_PER_SUBNET := 0.0

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

func generate(seed_value: int, subnet: int, player_start: Vector2,
		with_gate: bool = true) -> void:
	var rng := RandomNumberGenerator.new()
	# The subnet is mixed in, not added, so subnet 2 of one run is not subnet 1
	# of the run seeded one higher.
	rng.seed = hash(str(seed_value, ":", subnet))
	solid.fill(0)
	zone.fill(0)
	rects.clear()
	dist_from_gate = PackedInt32Array()
	voided = PackedByteArray()
	max_dist = 0

	# Everything outside the arena is rock. The corridor is the ONLY way out,
	# and the player is now allowed to leave the arena rect, so the margin has to
	# actually stop them.
	for y in h:
		for x in w:
			var p := origin + Vector2(float(x) + 0.5, float(y) + 0.5) * CELL
			if not arena_rect.has_point(p):
				solid[y * w + x] = 1

	_arena_cells()
	# Density is a fraction of the ARENA, not of the enlarged grid — the margin
	# is solid by construction and counting it would quietly halve the walls.
	var arena_cells := (_ax1 - _ax0) * (_ay1 - _ay0)
	var target := int(float(arena_cells) * density_for(subnet))
	var placed := 0
	var attempts := 0
	while placed < target and attempts < PLACE_ATTEMPTS:
		attempts += 1
		# Small. At 2-6 cells these read as slabs you route around; at 1-3 they
		# read as scattered cover you weave through, which is what the arena
		# wants at 3% coverage.
		var rw := rng.randi_range(1, 3)
		var rh := rng.randi_range(1, 3)
		var cx := rng.randi_range(_ax0, _ax1 - rw)
		var cy := rng.randi_range(_ay0, _ay1 - rh)
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
	has_gate = with_gate
	gate_open = false
	if with_gate:
		_place_gate(rng, player_start)

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

## As a fraction of the ARENA, not of the grid. The grid now extends a margin
## past the arena on every side and that margin is solid by construction, so
## dividing by w * h would report a healthy arena as a closet.
func reachable_fraction(player_start: Vector2) -> float:
	var start := cell_index(player_start)
	if start < 0 or solid[start] != 0:
		return 0.0
	var seen := _reach(start)
	var n := 0
	for i in seen.size():
		if seen[i] != 0:
			n += 1
	_arena_cells()
	var arena_cells := (_ax1 - _ax0) * (_ay1 - _ay0)
	return float(n) / float(maxi(arena_cells, 1))

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
		var cx := rng.randi_range(_ax0, _ax1 - rw)
		var cy := rng.randi_range(_ay0, _ay1 - rh)
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

## How close you must be to step through.
const GATE_RADIUS := 48.0

const CORRIDOR_LENGTH := 1100.0
const CORRIDOR_HALF_WIDTH := 70.0

## The grid extends past the arena on every side, so the corridor beyond a gate
## is ordinary ground on the SAME grid. That is what makes walking out
## continuous instead of a teleport into a second Terrain — and it means
## collision, zones and rendering need no idea the corridor exists.
const MARGIN := 1400.0

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

## The gate goes down AFTER the connectivity fill, and is joined to the
## reachable region by carving a straight line toward the player's start.
##
## Carving, which _fill_unreachable deliberately refuses to do for pockets — and
## that objection does not carry here. A straight line toward a point already
## known to be reachable always terminates and cannot leave a second region
## behind; the general pocket case had neither property. Running after the fill
## rather than before is what makes that true: the reachable set already exists
## to aim at.
func _place_gate(rng: RandomNumberGenerator, player_start: Vector2) -> void:
	var edge := rng.randi_range(0, 3)
	var cx := 0
	var cy := 0
	match edge:
		0: cx = rng.randi_range(_ax0 + 2, _ax1 - 2); cy = _ay0; gate_dir = Vector2(0, -1)
		1: cx = rng.randi_range(_ax0 + 2, _ax1 - 2); cy = _ay1 - 1; gate_dir = Vector2(0, 1)
		2: cx = _ax0; cy = rng.randi_range(_ay0 + 2, _ay1 - 2); gate_dir = Vector2(-1, 0)
		_: cx = _ax1 - 1; cy = rng.randi_range(_ay0 + 2, _ay1 - 2); gate_dir = Vector2(1, 0)
	gate_pos = origin + Vector2(float(cx) + 0.5, float(cy) + 0.5) * CELL

	# Clear the gate's own cell and its neighbours, so it is a mouth rather than
	# a pinhole you have to hit exactly.
	for y in range(cy - 1, cy + 2):
		for x in range(cx - 1, cx + 2):
			if x >= 0 and y >= 0 and x < w and y < h:
				solid[y * w + x] = 0

	corridor_end = gate_pos + gate_dir * CORRIDOR_LENGTH
	_cut_corridor()
	_carve_to(gate_pos, player_start)

## Open ground from the gate outward, walled by the solid margin either side.
## This is the whole of "no teleport": the corridor is cells on this grid, so
## walking into it is walking.
func _cut_corridor() -> void:
	var side := Vector2(-gate_dir.y, gate_dir.x)
	var far := gate_pos + gate_dir * CORRIDOR_LENGTH
	corridor_rect = Rect2(gate_pos, Vector2.ZERO) \
		.expand(gate_pos + side * CORRIDOR_HALF_WIDTH) \
		.expand(gate_pos - side * CORRIDOR_HALF_WIDTH) \
		.expand(far + side * CORRIDOR_HALF_WIDTH) \
		.expand(far - side * CORRIDOR_HALF_WIDTH)
	var steps := int(CORRIDOR_LENGTH / (CELL * 0.5))
	var across := int(CORRIDOR_HALF_WIDTH / (CELL * 0.5))
	for k in range(steps + 1):
		var along := gate_pos + gate_dir * (CELL * 0.5 * k)
		for j in range(-across, across + 1):
			var c := cell_xy(along + side * (CELL * 0.5 * j))
			if in_bounds(c):
				solid[c.y * w + c.x] = 0

func _carve_to(from: Vector2, to: Vector2) -> void:
	var start := cell_index(to)
	if start < 0:
		return
	var seen := _reach(start)
	var i := cell_index(from)
	if i >= 0 and seen[i] != 0:
		return          # already connected; nothing to carve
	var steps := int(from.distance_to(to) / (CELL * 0.5)) + 1
	for k in range(steps + 1):
		var p := from.lerp(to, float(k) / float(steps))
		var c := cell_xy(p)
		if not in_bounds(c):
			continue
		var j := c.y * w + c.x
		solid[j] = 0
		if seen[j] != 0:
			return      # met the reachable region; stop carving


## Distance in cells from the gate, over open ground. -1 where unreachable.
##
## Computed ONCE, on the boss kill, and it earns its keep twice over: the
## largest distances are exactly "farthest from the gate", which is the order the
## arena falls apart in, and the descending gradient from any cell is a route
## home that follows walkable space rather than pointing through a wall.
func build_distance_field() -> void:
	dist_from_gate = PackedInt32Array()
	dist_from_gate.resize(w * h)
	for i in dist_from_gate.size():
		dist_from_gate[i] = -1
	voided = PackedByteArray()
	voided.resize(w * h)
	max_dist = 0
	_collapse_order = PackedInt32Array()
	_collapse_idx = 0
	var start := cell_index(gate_pos)
	if start < 0 or solid[start] != 0:
		return
	# A queue with a read head rather than pop_front on an Array: pop_front is
	# O(n) and this walks six thousand cells.
	var queue := PackedInt32Array([start])
	var head := 0
	dist_from_gate[start] = 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		var d := dist_from_gate[i] + 1
		var x := i % w
		var y := i / w
		for nb in [
				(i - 1) if x > 0 else -1,
				(i + 1) if x < w - 1 else -1,
				(i - w) if y > 0 else -1,
				(i + w) if y < h - 1 else -1]:
			if nb < 0 or solid[nb] != 0 or dist_from_gate[nb] >= 0:
				continue
			dist_from_gate[nb] = d
			if d > max_dist:
				max_dist = d
			queue.append(nb)
	_build_collapse_order()

## Arena cells by distance, farthest first. A counting sort on distance: O(n),
## where a comparison sort of thirty thousand cells would not be.
func _build_collapse_order() -> void:
	var counts := PackedInt32Array()
	counts.resize(max_dist + 2)
	var total := 0
	for i in dist_from_gate.size():
		if not _collapsible(i):
			continue
		counts[dist_from_gate[i]] += 1
		total += 1
	# Prefix sums, descending: distance max_dist lands first.
	var starts := PackedInt32Array()
	starts.resize(max_dist + 2)
	var acc := 0
	for d in range(max_dist, -1, -1):
		starts[d] = acc
		acc += counts[d]
	_collapse_order = PackedInt32Array()
	_collapse_order.resize(total)
	for i in dist_from_gate.size():
		if not _collapsible(i):
			continue
		var d := dist_from_gate[i]
		_collapse_order[starts[d]] = i
		starts[d] += 1

func _collapsible(i: int) -> bool:
	if solid[i] != 0 or dist_from_gate[i] < 0:
		return false
	var p := origin + Vector2(float(i % w) + 0.5, float(i / w) + 0.5) * CELL
	return arena_rect.has_point(p)

## Void every open ARENA cell farther from the gate than `threshold`.
##
## Walks a PRE-SORTED order rather than scanning the grid. The scan was O(cells)
## every tick, which was tolerable at 28,000 cells and is not at five times the
## arena; this is O(cells newly voided), so the whole collapse costs one pass in
## total rather than one pass per tick.
##
## The corridor is exempt because it lies outside the arena rect. Voiding the
## way out would make the deadline unwinnable rather than tense.
func collapse_to(threshold: int) -> void:
	if _collapse_order.is_empty():
		return
	# Thresholds only fall during a collapse, but a caller may reset one; rewind
	# rather than silently leaving voided ground behind.
	if _collapse_idx > 0 and threshold >= dist_from_gate[_collapse_order[_collapse_idx - 1]]:
		for i in voided.size():
			voided[i] = 0
		_collapse_idx = 0
	while _collapse_idx < _collapse_order.size():
		var c := _collapse_order[_collapse_idx]
		if dist_from_gate[c] <= threshold:
			break
		voided[c] = 1
		_collapse_idx += 1

func is_void(p: Vector2) -> bool:
	if voided.is_empty():
		return false
	var i := cell_index(p)
	if i < 0:
		return false
	return voided[i] != 0

## Walk downhill on the distance field, from `p` to the gate.
##
## Lit as TILES rather than drawn as a line, because a line from you to the gate
## is a claim the geometry does not support — it points through walls. Following
## the gradient can only ever tread on ground you can actually walk, which
## matters a great deal more now that failing to reach the gate kills you.
func route_from(p: Vector2, limit: int = 400) -> PackedInt32Array:
	var out := PackedInt32Array()
	var i := cell_index(p)
	if i < 0 or dist_from_gate.is_empty() or dist_from_gate[i] < 0:
		return out
	out.append(i)
	var guard := 0
	while dist_from_gate[i] > 0 and guard < limit:
		guard += 1
		var x := i % w
		var y := i / w
		var best := -1
		for nb in [
				(i - 1) if x > 0 else -1,
				(i + 1) if x < w - 1 else -1,
				(i - w) if y > 0 else -1,
				(i + w) if y < h - 1 else -1]:
			if nb < 0 or dist_from_gate[nb] < 0:
				continue
			if best < 0 or dist_from_gate[nb] < dist_from_gate[best]:
				best = nb
		if best < 0 or dist_from_gate[best] >= dist_from_gate[i]:
			break
		i = best
		out.append(i)
	return out


## A bounded overlay of TIMED zones, checked after the baked lookup.
##
## The baked zone grid is written once per subnet and never mutated — that
## immutability is what makes it a bare array index with no bookkeeping. Timed
## effects like null_ptr's afterimages cannot live there, so they live here: a
## short parallel-array list with a hard cap, so a long fight stops producing
## new ones rather than growing without limit.
const MAX_TEMP_ZONES := 24

var _tz_pos: PackedVector2Array
var _tz_r2: PackedFloat32Array
var _tz_kind: PackedInt32Array
var _tz_left: PackedFloat32Array

func temp_zone_count() -> int:
	return _tz_pos.size()

func add_temp_zone(p: Vector2, radius: float, kind: int, seconds: float) -> void:
	if _tz_pos.size() >= MAX_TEMP_ZONES:
		return          # capped: drop the request rather than grow the list
	_tz_pos.append(p)
	_tz_r2.append(radius * radius)
	_tz_kind.append(kind)
	_tz_left.append(seconds)

func step_temp_zones(dt: float) -> void:
	var i := 0
	while i < _tz_left.size():
		_tz_left[i] -= dt
		if _tz_left[i] <= 0.0:
			var last := _tz_left.size() - 1
			_tz_pos[i] = _tz_pos[last]; _tz_pos.resize(last)
			_tz_r2[i] = _tz_r2[last]; _tz_r2.resize(last)
			_tz_kind[i] = _tz_kind[last]; _tz_kind.resize(last)
			_tz_left[i] = _tz_left[last]; _tz_left.resize(last)
			continue    # a swapped-in entry occupies i; do NOT advance
		i += 1

func temp_zone_at(p: Vector2) -> int:
	for i in _tz_pos.size():
		if p.distance_squared_to(_tz_pos[i]) <= _tz_r2[i]:
			return _tz_kind[i]
	return -1

func clear_temp_zones() -> void:
	_tz_pos = PackedVector2Array()
	_tz_r2 = PackedFloat32Array()
	_tz_kind = PackedInt32Array()
	_tz_left = PackedFloat32Array()

## Can `a` see `b`, or is there rock between them?
##
## A DDA walk over the occupancy grid, run once per pulse rather than per tick.
## Bounded by the cell distance, so it terminates on any geometry.
func has_line_of_sight(a: Vector2, b: Vector2) -> bool:
	var d := b - a
	var steps := int(d.length() / (CELL * 0.5)) + 1
	if steps <= 1:
		return true
	for k in range(1, steps):
		var p := a + d * (float(k) / float(steps))
		var i := cell_index(p)
		if i >= 0 and solid[i] != 0:
			return false
	return true
