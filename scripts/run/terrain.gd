class_name Terrain extends RefCounted

## The campaign's ground: EVERY subnet's arena, and the corridors between them,
## on ONE grid, plotted before the first frame.
##
## One grid, and all of it up front, because the transition between subnets is a
## walk. A corridor is only continuous with the arena it leads to if that arena
## already exists and is the same array the player is already standing on;
## anything regenerated under their feet at the far end is a teleport wearing a
## corridor. So the map is planned once, the arenas are laid out end to end with
## a corridor spanning each gap, and `current` is the only thing that moves.
##
## Two representations of one fact, deliberately. `rects` is what the generator
## writes and what the renderer draws — a few dozen entries. The two byte grids
## are what the RUNTIME asks, and they exist so that nothing on the hot path
## ever iterates a rect list: every question is one array index. The grids are
## baked once and never mutated, which is what lets them stay a bare index with
## no bookkeeping.
##
## Pure: no nodes, no tree, no signals. Driven directly by tests.

enum Kind { WALL, HAZARD, SLOW, CORRUPTION }

const CELL := 32.0

## The lattice the backdrop draws, in world units. Every arena edge, every
## corridor and the grid's own origin are whole multiples of it, so the ground
## reads as tiles laid end to end rather than as a texture the world stops part
## way through.
const TILE := CELL * 3.0

## Per second, so they are frame-rate independent. Starting values, expected to
## move once the arena has been played rather than reasoned about.
const HAZARD_DPS := 12.0
const SLOW_FACTOR := 0.6
const CORRUPTION_PER_SEC := 8.0
## A corruption zone converts this many enemies, then lies dormant while it
## recharges. Leading a swarm across one still works; leading the whole match
## across one does not. The tally and the timer are run state (per rect).
const ZONE_FLIP_BUDGET := 6
const ZONE_RECHARGE := 40.0

## The rock border around the whole map. Small on purpose: it is only there to
## stop the player walking off the plotted world, and the corridors no longer
## live in it — they run between arenas, not out into nothing.
const MARGIN := TILE * 4.0

## The gap between one arena's edge and the next one's, spanned by the corridor.
const CORRIDOR_LENGTH := TILE * 12.0
## Half-width in whole cells either side of the gate's own cell, so the walkway
## is an odd number of cells and its rect lands on cell boundaries.
const CORRIDOR_HALF_CELLS := 3
const CORRIDOR_HALF_WIDTH := (float(CORRIDOR_HALF_CELLS) + 0.5) * CELL

## How close to the corridor's far end counts as arriving.
const GATE_RADIUS := 48.0


## The way out of one arena and into the next: one per LINK, so a three-subnet
## campaign has two and clearing the last arena wins outright.
class Gate extends RefCounted:
	var pos: Vector2
	## Outward from the arena it leaves, so the corridor, the posts and the
	## block all know which way "through" is. Always axis-aligned.
	var dir: Vector2
	var open := false
	## The walkway, as a rect, so it can be drawn as floor. It runs from the
	## arena's own edge to the NEXT arena's edge with nothing in between — that
	## flushness is the whole of "no teleport".
	var corridor: Rect2
	## Where the corridor meets the next arena. On its edge, not near it.
	var end: Vector2
	## What a SHUT gate stops. A bounded rect rather than the half-plane this
	## used to be: outward of the gate plane is now the NEXT ARENA, and an
	## unbounded test laid an invisible wall clean across it.
	var block: Rect2


var origin: Vector2
var size: Vector2
var w: int
var h: int
var solid: PackedByteArray
## Kind + 1, so that zero means "no zone" and the array can start zeroed.
var zone: PackedByteArray
var zone_rect: PackedInt32Array   # per cell: index into rects, or -1
var rects: Array = []          # [Rect2, Kind] pairs, for generation and drawing

## Every subnet's arena, in walk order.
var arenas: Array = []
## One per link, so `gates.size() == arenas.size() - 1`.
var gates: Array = []
## Which arena the run is in. Everything that used to be a single fact — the
## gate, the corridor, the collapse — reads through this.
var current := 0

## Four reserved arrival points per arena, indexed [arena][slot]. Derived once
## in generate() from the seed/layout, never mutated afterward — see
## spawner_pos/validate_spawners/spawn_is_safe below.
var _spawners: Array = []

## The block rects of the gates that are currently SHUT, cached because
## `is_solid` asks on every enemy step and every projectile step and the answer
## only changes when a gate does.
var _blocks: Array[Rect2] = []

## Distance in cells from the gate over open ground, -1 where unreachable.
## Built once on the boss kill; drives both the collapse order and the route.
var dist_from_gate: PackedInt32Array
var max_dist := 0
var voided: PackedByteArray
## Cells ordered for the collapse, farthest FIRST, plus how far down that order it
## has already eaten. Arena cells come first, ordered by distance from the gate;
## the current gate's corridor cells are appended after them, ordered from the
## arena end toward g.end, so once the arena is gone the corridor voids too and no
## slot can idle there forever. One order, one index, one write into `voided`.
var _collapse_order: PackedInt32Array
var _collapse_idx := 0
## The collapse key for each entry in `_collapse_order`, descending. Arena entries
## carry their dist_from_gate (0..max_dist); corridor entries carry -1..-N so they
## sort after the whole arena and void from the arena end outward. Kept separate
## from dist_from_gate, which stays arena-only for the route and never goes
## negative.
var _collapse_dist: PackedInt32Array
## How many corridor cells the collapse can eat — the magnitude of the most
## negative _collapse_dist. Zero when the current gate has no corridor.
var corridor_collapse_len := 0

## Ticks the corridor takes to collapse once the arena is fully gone. Long enough
## to cross a leash-length corridor, short enough that idling is fatal.
const CORRIDOR_COLLAPSE_TICKS := 600

## Where each arena is plotted, in walk order.
##
## Axis-aligned links only, and never the reverse of the last one, which for a
## three-arena campaign is exactly enough to guarantee no two arenas overlap: an
## L or a straight line, and nothing else is reachable. A longer campaign would
## need a real placement search; assert rather than let it silently self-collide.
static func plan(arena_size: Vector2, count: int, seed_value: int) -> Array:
	assert(count <= 3, "the no-reverse rule only bounds overlap up to three arenas")
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(seed_value, ":layout"))
	# The first arena is centred on the world-origin entry/layout anchor.
	# Player slots use distinct reserved offsets around that anchor.
	var out: Array = [Rect2(-arena_size * 0.5, arena_size)]
	var last := Vector2.ZERO
	for i in range(1, count):
		var choices: Array[Vector2] = []
		for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
			if d != -last:
				choices.append(d)
		var dir: Vector2 = choices[rng.randi_range(0, choices.size() - 1)]
		var prev: Rect2 = out[out.size() - 1]
		out.append(Rect2(prev.position + dir * (arena_size + Vector2(
			CORRIDOR_LENGTH, CORRIDOR_LENGTH)), arena_size))
		last = dir
	return out

func _init(arena_size: Vector2, count: int = 1, layout_seed: int = 0) -> void:
	assert(is_equal_approx(fposmod(arena_size.x, TILE * 2.0), 0.0)
		and is_equal_approx(fposmod(arena_size.y, TILE * 2.0), 0.0),
		"an arena is a whole EVEN number of tiles, so its half — and therefore "
		+ "the grid origin — lands on a tile boundary too")
	arenas = plan(arena_size, count, layout_seed)
	var bounds: Rect2 = arenas[0]
	for i in range(1, arenas.size()):
		bounds = bounds.merge(arenas[i])
	origin = bounds.position - Vector2(MARGIN, MARGIN)
	size = bounds.size + Vector2(MARGIN, MARGIN) * 2.0
	# round, not ceil: everything is tile-aligned by construction, so a fraction
	# of a cell here would mean the assert above is wrong.
	w = int(round(size.x / CELL))
	h = int(round(size.y / CELL))
	solid = PackedByteArray()
	solid.resize(w * h)
	zone = PackedByteArray()
	zone.resize(w * h)
	zone_rect = PackedInt32Array()
	zone_rect.resize(w * h)
	zone_rect.fill(-1)

# ------------------------------------------------------------- the current ---

func arena() -> Rect2:
	return arenas[current]

## The gate out of the current arena, or null on the last one.
func gate() -> Gate:
	return gates[current] if current < gates.size() else null

func has_gate() -> bool:
	return current < gates.size()

func open_gate() -> void:
	var g := gate()
	if g != null:
		g.open = true
		_rebuild_blocks()

## Walking in. The gate shuts behind, because the ground back there is coming
## apart and a way back is a way to die in it.
func enter_next() -> void:
	var g := gate()
	if g != null:
		g.open = false
	current = mini(current + 1, arenas.size() - 1)
	# The old arena's collapse is over; drop it in one place so a stale voided
	# frontier or order cannot leak into the next subnet.
	_clear_collapse_state()
	_rebuild_blocks()

func _rebuild_blocks() -> void:
	_blocks.clear()
	for g in gates:
		if not g.open:
			_blocks.append(g.block)

# ------------------------------------------------------------------ lookup ---

func cell_xy(p: Vector2) -> Vector2i:
	return Vector2i(int(floor((p.x - origin.x) / CELL)),
		int(floor((p.y - origin.y) / CELL)))

func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < w and c.y < h

## -1 when the point is outside the grid, so callers can tell "no cell" from
## "cell zero" without a second bounds call.
func cell_index(p: Vector2) -> int:
	var c := cell_xy(p)
	if not in_bounds(c):
		return -1
	return c.y * w + c.x

## An arena's own cells: position is its first cell, end is one PAST its last.
##
## Exact, never approximate: every arena edge is a whole number of tiles from
## the grid origin and a tile is three cells, so an arena covers whole cells and
## nothing straddles its boundary.
func arena_cells(i: int) -> Rect2i:
	return _cells_of(arenas[i])

func _cells_of(r: Rect2) -> Rect2i:
	return Rect2i(
		int(round((r.position.x - origin.x) / CELL)),
		int(round((r.position.y - origin.y) / CELL)),
		int(round(r.size.x / CELL)),
		int(round(r.size.y / CELL)))

## Outside the grid is OPEN, never solid. Enemies spawn on a ring around the
## player, which can sit partly outside the bounds; solid-outside would reject
## every one of those spawns and starve the wave.
##
## The shut-gate test is inlined rather than calling gate_blocks: this runs for
## every enemy step and every projectile step, and _blocks holds at most two
## rects, so the call would cost more than the loop it saves.
func is_solid(p: Vector2) -> bool:
	for i in _blocks.size():
		if _blocks[i].has_point(p):
			return true
	var i2 := cell_index(p)
	if i2 < 0:
		return false
	return solid[i2] != 0

## A CLOSED gate still has to stop you.
##
## The mouth and the corridor beyond it are carved open at generation — that is
## what makes them visible from the first second and walkable the moment the
## gate opens. Without this, they were walkable from the first second too, and
## the whole subnet could be skipped by strolling out.
##
## Tested geometrically rather than baked into `solid`, because `solid` is
## static by design: baking would mean mutating the grid when a gate opens, and
## the distance field and collapse order are both built off it.
func gate_blocks(p: Vector2) -> bool:
	for i in _blocks.size():
		if _blocks[i].has_point(p):
			return true
	return false

func zone_at(p: Vector2) -> int:
	var i := cell_index(p)
	if i < 0:
		return -1
	return int(zone[i]) - 1

# -------------------------------------------------------------- generation ---

## Walls are kept clear of wherever the player ENTERS an arena by this much, so
## neither the opening seconds nor an arrival is spent wedged against rock.
const WALL_MARGIN := 260.0

## Flat across subnets. This was 8% rising to 18%, and the ramp was the wrong
## lever: a late subnet with less room to kite reads as cramped, not as hard.
## Difficulty escalates through enemy HP and the wave table instead.
const DENSITY_BASE := 0.03
const DENSITY_PER_SUBNET := 0.0

## The floor the generator's own output is held to in test. Filling unreachable
## pockets cannot fail, but it CAN eat an arena on a pathological seed, and a
## closet is as unplayable as a sealed pocket.
const REACHABLE_FLOOR := 0.70

## Bounded, not "until the target is met". An unbounded placement loop on a
## dense subnet with an unlucky seed is a hang, and a hang in generation is a
## hang before the first frame of the run.
const PLACE_ATTEMPTS := 4000

const ZONES_MIN := 2
const ZONES_MAX := 4

## WALL is deliberately absent: it is the blocking kind and lives in `solid`.
## The zone layer holds only the non-blocking effects.
const ZONE_KINDS := [Kind.HAZARD, Kind.SLOW, Kind.CORRUPTION]

## Minimum pairwise separation between an arena's reserved arrival points,
## also checked against the caller's own player diameter — whichever is
## larger. The offsets below keep every pair at least 100 units apart on
## their own, so this floor only bites if `radius` itself is large.
const SPAWN_SEPARATION := 96.0

## How far a reserved arrival point's footprint is cleared of rock during
## generation, in world units. Comfortably larger than the normal player
## radius (11) so the reservation step is a no-op in the ordinary case and a
## real repair only on a pathological seed or a rigged test fixture.
const PAD_CLEARANCE := 32.0

## FRONT/SIDE offsets from where the player enters an arena, per slot: x
## along FRONT, y along SIDE. Slots 0/1 sit close to the entry, 2/3 farther
## back; the sign of the SIDE component puts each pair on opposite flanks.
## Farthest point is ~201.25 units from entry — inside WALL_MARGIN (260) with
## enough slack (58.75 units) that no wall or zone rect the margin already
## excludes can reach within PAD_CLEARANCE (32) of any of the four.
const SPAWN_OFFSETS := [
	Vector2(80.0, 90.0), Vector2(80.0, -90.0),
	Vector2(180.0, 90.0), Vector2(180.0, -90.0),
]

static func density_for(subnet: int) -> float:
	return DENSITY_BASE + DENSITY_PER_SUBNET * float(maxi(subnet, 1) - 1)

## Plots the whole campaign in one pass.
##
## Order matters and is load-bearing. Gates are sited before the walls so that
## walls can be kept clear of where the player arrives; corridors are carved
## after them so nothing placed can seal the way out; each arena's four
## spawner points are then reserved and carved into it, still before the
## connectivity fill runs, so the fill cannot read one as a sealed pocket; the
## fill runs after that so all three arenas read as ONE reachable region and
## none of them is filled in as a pocket; zones go down last, kept off the
## same margin as the walls, so they can never be sealed behind rock, land on
## a reserved pad, or overwrite one.
func generate(seed_value: int, player_start: Vector2) -> void:
	rects.clear()
	dist_from_gate = PackedInt32Array()
	voided = PackedByteArray()
	max_dist = 0
	current = 0

	# Rock everywhere, then each arena cut back out of it. Filling and clearing
	# whole cell ranges rather than asking `has_point` per cell: the grid spans
	# three arenas and the gaps between them, and the point test was the one
	# part of generation that scaled with the whole map rather than the ground.
	solid.fill(1)
	zone.fill(0)
	zone_rect.fill(-1)
	for i in arenas.size():
		_clear_cells(arena_cells(i))

	# Where the player ENTERS each arena: their start for the first, the mouth
	# they walk out of for the rest. Both the gates and the walls are sited
	# against it — walls because an arena whose mouth was walled off would be
	# flood-filled solid as an unreachable pocket, and gates because a SHUT one
	# bars its own mouth, and a shut gate sited beside the arrival is an
	# invisible wall in the doorway you just came through.
	var entry := _place_gates(hash(str(seed_value, ":gates")), player_start)

	for i in arenas.size():
		_place_walls(hash(str(seed_value, ":w:", i)), i, entry[i])
	for i in gates.size():
		_cut_corridor(gates[i])
		_carve_to(gates[i].pos, arenas[i].get_center(), arena_cells(i))
	_derive_spawners(entry)
	_fill_unreachable(player_start)
	for i in arenas.size():
		_place_zones(hash(str(seed_value, ":z:", i)), i, entry[i])
	_rebuild_blocks()

func _clear_cells(c: Rect2i) -> void:
	for y in range(c.position.y, c.end.y):
		var row := y * w
		for x in range(c.position.x, c.end.x):
			solid[row + x] = 0

## One gate per link, on the edge of the arena that FACES the next one. There is
## no choice of edge any more: the corridor has to arrive somewhere, and the
## somewhere is fixed by the layout — only the position along that edge is
## rolled.
##
## Returns where the player enters each arena, which is the corridor mouths this
## produced with their start in front. Computed here rather than afterwards
## because the roll depends on it: an arena entered near a corner can have its
## exit gate on the adjoining edge, and a SHUT gate bars its own mouth, so
## rolling blind put an invisible wall in the doorway on one seed in twenty.
func _place_gates(rng_seed: int, player_start: Vector2) -> PackedVector2Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	gates.clear()
	var entry := PackedVector2Array([player_start])
	for i in range(arenas.size() - 1):
		var d: Vector2 = arenas[i + 1].get_center() - arenas[i].get_center()
		var g := Gate.new()
		g.dir = Vector2(signf(d.x), 0.0) if absf(d.x) > absf(d.y) \
			else Vector2(0.0, signf(d.y))
		var c := arena_cells(i)
		var across := g.dir.x != 0.0
		var fixed := 0
		var lo := 0
		var hi := 0
		if across:
			fixed = (c.end.x - 1) if g.dir.x > 0.0 else c.position.x
			lo = c.position.y + CORRIDOR_HALF_CELLS + 1
			hi = c.end.y - CORRIDOR_HALF_CELLS - 2
		else:
			fixed = (c.end.y - 1) if g.dir.y > 0.0 else c.position.y
			lo = c.position.x + CORRIDOR_HALF_CELLS + 1
			hi = c.end.x - CORRIDOR_HALF_CELLS - 2
		# Bounded retries, then take what came: the edge is ninety-odd cells and
		# the exclusion is fourteen, so this lands first try almost always — and
		# a loop that ran until it fit would be a hang on a shape that cannot.
		var clearance := WALL_MARGIN + CORRIDOR_HALF_WIDTH + CELL * 2.0
		for _try in 16:
			var k := rng.randi_range(lo, hi)
			var cell := Vector2(float(fixed) + 0.5, float(k) + 0.5) if across \
				else Vector2(float(k) + 0.5, float(fixed) + 0.5)
			g.pos = origin + cell * CELL
			if g.pos.distance_to(entry[i]) >= clearance:
				break
		# The gate cell is the outermost cell INSIDE the arena, so its centre is
		# half a cell short of the edge the corridor starts from.
		g.end = g.pos + g.dir * (CELL * 0.5 + CORRIDOR_LENGTH)
		var mouth := g.pos - g.dir * (CELL * 0.5)
		var side := Vector2(-g.dir.y, g.dir.x)
		g.corridor = Rect2(mouth, Vector2.ZERO) \
			.expand(mouth + side * CORRIDOR_HALF_WIDTH) \
			.expand(mouth - side * CORRIDOR_HALF_WIDTH) \
			.expand(g.end + side * CORRIDOR_HALF_WIDTH) \
			.expand(g.end - side * CORRIDOR_HALF_WIDTH)
		# Two cells back into the arena so the mouth's shoulders are barred too,
		# and NOT one unit past the far end, which is the next arena's floor.
		var back := CELL * 2.0
		var lat := CELL * 2.0
		g.block = g.corridor.grow_individual(
			lat if g.dir.x == 0.0 else (back if g.dir.x > 0.0 else 0.0),
			lat if g.dir.y == 0.0 else (back if g.dir.y > 0.0 else 0.0),
			lat if g.dir.x == 0.0 else (0.0 if g.dir.x > 0.0 else back),
			lat if g.dir.y == 0.0 else (0.0 if g.dir.y > 0.0 else back))
		gates.append(g)
		entry.append(g.end)
	return entry

func _place_walls(rng_seed: int, index: int, entry: Vector2) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var c := arena_cells(index)
	# One cell in from every edge: a gate mouth sits ON the edge, and a wall
	# there is a wall across the only way out.
	var x0 := c.position.x + 1
	var y0 := c.position.y + 1
	var x1 := c.end.x - 1
	var y1 := c.end.y - 1
	var target := int(float((x1 - x0) * (y1 - y0)) * density_for(index + 1))
	var placed := 0
	var attempts := 0
	while placed < target and attempts < PLACE_ATTEMPTS:
		attempts += 1
		# Small. At 2-6 cells these read as slabs you route around; at 1-3 they
		# read as scattered cover you weave through, which is what the arena
		# wants at 3% coverage.
		var rw := rng.randi_range(1, 3)
		var rh := rng.randi_range(1, 3)
		var cx := rng.randi_range(x0, x1 - rw)
		var cy := rng.randi_range(y0, y1 - rh)
		var r := Rect2(origin + Vector2(cx, cy) * CELL, Vector2(rw, rh) * CELL)
		# grow() by the margin and ask whether the entry is inside: that is
		# exactly "this rect comes within WALL_MARGIN of where the player lands".
		if r.grow(WALL_MARGIN).has_point(entry):
			continue
		for y in range(cy, cy + rh):
			for x in range(cx, cx + rw):
				var i := y * w + x
				if solid[i] == 0:
					solid[i] = 1
					placed += 1
		rects.append([r, Kind.WALL])

func _place_zones(rng_seed: int, index: int, entry: Vector2) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var c := arena_cells(index)
	var x0 := c.position.x + 1
	var y0 := c.position.y + 1
	var x1 := c.end.x - 1
	var y1 := c.end.y - 1
	var n := rng.randi_range(ZONES_MIN, ZONES_MAX)
	var attempts := 0
	var made := 0
	while made < n and attempts < PLACE_ATTEMPTS:
		attempts += 1
		var rw := rng.randi_range(3, 7)
		var rh := rng.randi_range(3, 7)
		var cx := rng.randi_range(x0, x1 - rw)
		var cy := rng.randi_range(y0, y1 - rh)
		var r := Rect2(origin + Vector2(cx, cy) * CELL, Vector2(rw, rh) * CELL)
		if r.grow(WALL_MARGIN).has_point(entry):
			continue
		var kind: int = ZONE_KINDS[rng.randi_range(0, ZONE_KINDS.size() - 1)]
		if paint_zone(r, kind) >= 0:
			made += 1

## Paint a zone over the OPEN cells of a cell-aligned rect and register it in
## `rects`. Returns the rect's index, or -1 when every cell was rock: a zone
## under rock is an effect nothing can ever stand in. Generation and the
## suites both go through here, so every painted cell knows its rect.
func paint_zone(r: Rect2, kind: int) -> int:
	var c0 := cell_xy(r.position)
	var c1 := cell_xy(r.end - Vector2.ONE)
	var index := rects.size()
	var wrote := false
	for y in range(c0.y, c1.y + 1):
		for x in range(c0.x, c1.x + 1):
			if not in_bounds(Vector2i(x, y)):
				continue
			var i := y * w + x
			if solid[i] == 0:
				zone[i] = kind + 1
				zone_rect[i] = index
				wrote = true
	if not wrote:
		return -1
	rects.append([r, kind])
	return index

## The zone rect a world point stands in, or -1.
func zone_rect_at(p: Vector2) -> int:
	var c := cell_xy(p)
	if not in_bounds(c):
		return -1
	return zone_rect[c.y * w + c.x]

## Open ground from the arena's edge to the next arena's edge, walled by the
## solid margin either side. This is the whole of "no teleport": the corridor is
## cells on the same grid as both arenas, so walking through is walking.
func _cut_corridor(g: Gate) -> void:
	_clear_cells(_cells_of(g.corridor))

## Flood-fill the open cells from the player's start; anything the fill does not
## reach becomes rock.
##
## Filling rather than carving, because filling CANNOT FAIL. Carving a corridor
## to a stranded pocket needs its own pathfinding and can itself leave a second
## pocket; filling terminates in one pass and leaves exactly one open region by
## construction. The cost is that a bad seed could eat an arena, which is why
## reachable_fraction has a floor asserted in test.
func _fill_unreachable(player_start: Vector2) -> void:
	var start := cell_index(player_start)
	if start < 0 or solid[start] != 0:
		return
	var seen := _reach(start)
	for i in solid.size():
		if solid[i] == 0 and seen[i] == 0:
			solid[i] = 1

## `bounds` in CELLS, or an empty rect for the whole grid. The bounded form is
## what keeps the gate's connectivity check to one arena: the map is one region
## by design, so an unbounded fill from a gate would walk all three of them.
func _reach(start: int, bounds := Rect2i()) -> PackedByteArray:
	var seen := PackedByteArray()
	seen.resize(w * h)
	var limited := bounds.size.x > 0
	var stack := PackedInt32Array([start])
	while stack.size() > 0:
		var i := stack[stack.size() - 1]
		stack.remove_at(stack.size() - 1)
		if seen[i] != 0 or solid[i] != 0:
			continue
		var x := i % w
		var y := i / w
		if limited and (x < bounds.position.x or x >= bounds.end.x
				or y < bounds.position.y or y >= bounds.end.y):
			continue
		seen[i] = 1
		if x > 0: stack.append(i - 1)
		if x < w - 1: stack.append(i + 1)
		if y > 0: stack.append(i - w)
		if y < h - 1: stack.append(i + w)
	return seen

## As a fraction of the ARENAS, not of the grid. The grid spans the corridors
## and a rock margin as well, and dividing by w * h would report a healthy map
## as a closet.
func reachable_fraction(player_start: Vector2) -> float:
	var start := cell_index(player_start)
	if start < 0 or solid[start] != 0:
		return 0.0
	var seen := _reach(start)
	var n := 0
	var total := 0
	for k in arenas.size():
		var c := arena_cells(k)
		for y in range(c.position.y, c.end.y):
			var row := y * w
			for x in range(c.position.x, c.end.x):
				total += 1
				if seen[row + x] != 0:
					n += 1
	return float(n) / float(maxi(total, 1))

## Join the gate to its arena by carving a straight line toward the centre.
##
## Carving, which _fill_unreachable deliberately refuses to do for pockets — and
## that objection does not carry here. A straight line toward a point already
## known to be reachable always terminates and cannot leave a second region
## behind; the general pocket case had neither property.
func _carve_to(from: Vector2, to: Vector2, bounds := Rect2i()) -> void:
	var start := cell_index(to)
	if start < 0:
		return
	var seen := _reach(start, bounds)
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

# -------------------------------------------------------------- collision ---

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
			var q := p + DetMath.unit(a) * step
			if not is_solid(q):
				return q
	return p

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

# --------------------------------------------------------------- collapse ---

## Distance in cells from the CURRENT arena's gate, over open ground. -1
## elsewhere.
##
## Computed ONCE, on the boss kill, and it earns its keep twice over: the
## largest distances are exactly "farthest from the gate", which is the order the
## arena falls apart in, and the descending gradient from any cell is a route
## home that follows walkable space rather than pointing through a wall.
##
## Bounded to the current arena's cells. The whole campaign is one connected
## region by design, so an unbounded fill would measure the subnet already left
## and hand the collapse a max distance from ground nobody can reach.
## Reset everything the collapse derives, in ONE place. Called when a new field is
## built and when the player enters the next arena, so no partial reset is left
## scattered where a later change can forget it.
func _clear_collapse_state() -> void:
	voided = PackedByteArray()
	voided.resize(w * h)
	_collapse_order = PackedInt32Array()
	_collapse_dist = PackedInt32Array()
	_collapse_idx = 0
	corridor_collapse_len = 0

## Re-derive a collapse in progress from ONE number: rebuild the field and the
## order for the current gate, then void exactly the first `idx` cells of that
## order. `voided` is written here and in collapse_to and nowhere else, so a
## restored peer's frontier is bit-identical to the one that serialised it.
func restore_collapse(idx: int) -> void:
	build_distance_field()
	_collapse_idx = clampi(idx, 0, _collapse_order.size())
	for k in _collapse_idx:
		voided[_collapse_order[k]] = 1

## The open flag of every gate, in gate order — the only mutable gate state.
func gate_open_flags() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(gates.size())
	for i in gates.size():
		out[i] = 1 if gates[i].open else 0
	return out

func set_gate_open_flags(flags: PackedByteArray) -> void:
	for i in mini(flags.size(), gates.size()):
		gates[i].open = flags[i] != 0
	_rebuild_blocks()

func build_distance_field() -> void:
	dist_from_gate = PackedInt32Array()
	dist_from_gate.resize(w * h)
	dist_from_gate.fill(-1)
	max_dist = 0
	_clear_collapse_state()
	var g := gate()
	if g == null:
		return
	var start := cell_index(g.pos)
	if start < 0 or solid[start] != 0:
		return
	var c := arena_cells(current)
	# A queue with a read head rather than pop_front on an Array: pop_front is
	# O(n) and this walks thirty thousand cells.
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
				(i - 1) if x > c.position.x else -1,
				(i + 1) if x < c.end.x - 1 else -1,
				(i - w) if y > c.position.y else -1,
				(i + w) if y < c.end.y - 1 else -1]:
			if nb < 0 or solid[nb] != 0 or dist_from_gate[nb] >= 0:
				continue
			dist_from_gate[nb] = d
			if d > max_dist:
				max_dist = d
			queue.append(nb)
	_build_collapse_order()

## Arena cells by distance, farthest first. A counting sort on distance: O(n),
## where a comparison sort of thirty thousand cells would not be.
##
## Walks the arena's own cell range, which is both faster than scanning the grid
## and exactly the collapse's remit — the corridor lies outside it and is
## therefore exempt, and voiding the way out would make the deadline unwinnable
## rather than tense.
func _build_collapse_order() -> void:
	var c := arena_cells(current)
	var counts := PackedInt32Array()
	counts.resize(max_dist + 2)
	var total := 0
	for y in range(c.position.y, c.end.y):
		var row := y * w
		for x in range(c.position.x, c.end.x):
			var i := row + x
			if solid[i] != 0 or dist_from_gate[i] < 0:
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
	_collapse_dist = PackedInt32Array()
	_collapse_dist.resize(total)
	for y in range(c.position.y, c.end.y):
		var row := y * w
		for x in range(c.position.x, c.end.x):
			var i := row + x
			if solid[i] != 0 or dist_from_gate[i] < 0:
				continue
			var d := dist_from_gate[i]
			_collapse_order[starts[d]] = i
			_collapse_dist[starts[d]] = d
			starts[d] += 1
	_append_corridor_collapse()

## Append the current gate's corridor cells to the collapse order, ordered from
## the arena end toward g.end, each with a negative collapse key (-1, -2, …) so
## they sort after the whole arena and void from the mouth outward. The corridor
## is exempt from the arena collapse — the route out must stay open — but once the
## arena is gone it collapses too, so idling in it is no longer safe.
func _append_corridor_collapse() -> void:
	var g := gate()
	if g == null:
		return
	var cells := _cells_of(g.corridor)
	# Corridor cells not already part of the arena field, projected onto the gate
	# direction so the arena end sorts first.
	var found: Array = []          # [projection, cell_index]
	for y in range(cells.position.y, cells.position.y + cells.size.y):
		if y < 0 or y >= h:
			continue
		var row := y * w
		for x in range(cells.position.x, cells.position.x + cells.size.x):
			if x < 0 or x >= w:
				continue
			var i := row + x
			if solid[i] != 0 or dist_from_gate[i] >= 0:
				continue          # solid, or an arena cell already ordered
			var centre := origin + Vector2(float(x) + 0.5, float(y) + 0.5) * CELL
			found.append([(centre - g.pos).dot(g.dir), i])
	found.sort_custom(func(a, b): return a[0] < b[0])
	corridor_collapse_len = found.size()
	for rank in found.size():
		_collapse_order.append(found[rank][1])
		_collapse_dist.append(-(rank + 1))

## Void every open ARENA cell farther from the gate than `threshold`.
##
## Walks a PRE-SORTED order rather than scanning the grid. The scan was O(cells)
## every tick, which was tolerable at 28,000 cells and is not at a whole
## campaign's worth; this is O(cells newly voided), so the collapse costs one
## pass in total rather than one pass per tick.
## Cells voided by the MOST RECENT collapse_to call. run.gd turns these into
## falling chunks; diffing the whole `voided` array every tick would cost a pass
## over the map to learn something this function already knows.
var just_voided: PackedInt32Array = PackedInt32Array()

func collapse_to(threshold: int) -> void:
	just_voided.clear()
	if _collapse_order.is_empty():
		return
	# Thresholds only fall during a collapse, but a caller may reset one; rewind
	# rather than silently leaving voided ground behind. Keyed on _collapse_dist,
	# which continues negative through the corridor, so the threshold can drop past
	# zero to eat the corridor after the arena.
	if _collapse_idx > 0 and threshold >= _collapse_dist[_collapse_idx - 1]:
		voided.fill(0)
		_collapse_idx = 0
	while _collapse_idx < _collapse_order.size():
		if _collapse_dist[_collapse_idx] <= threshold:
			break
		var c := _collapse_order[_collapse_idx]
		voided[c] = 1
		just_voided.append(c)
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

# ------------------------------------------------------------- temp zones ---

## A bounded overlay of TIMED zones, checked after the baked lookup.
##
## The baked zone grid is written once and never mutated — that immutability is
## what makes it a bare array index with no bookkeeping. Timed effects like
## null_ptr's afterimages cannot live there, so they live here: a short
## parallel-array list with a hard cap, so a long fight stops producing new ones
## rather than growing without limit.
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

# -------------------------------------------------------------- spawners ---

## Reserve every arena's four arrival points, right after the corridors are
## carved and before the connectivity fill runs — so a pad the fill would
## otherwise read as a sealed pocket is already merged into the arena's main
## region by the time the fill walks it. `entry` is the same per-arena
## arrival point _place_walls and _place_zones already keep clear by
## WALL_MARGIN; deriving the four points from it, never from a fresh roll, is
## what keeps this a single deterministic pass with no retry loop.
func _derive_spawners(entry: PackedVector2Array) -> void:
	_spawners.clear()
	var repaired := false
	for i in arenas.size():
		var front: Vector2 = Vector2.RIGHT if i == 0 else gates[i - 1].dir
		var side := Vector2(-front.y, front.x)
		var pts := PackedVector2Array()
		var pad := Rect2(entry[i], Vector2.ZERO)
		for off in SPAWN_OFFSETS:
			var p := _clamp_to_arena(entry[i] + front * off.x + side * off.y, arenas[i])
			pts.append(p)
			pad = pad.expand(p)
		# One connected pad includes the entry itself. No per-point flood fills.
		if _reserve_pad(pad.grow(PAD_CLEARANCE), arena_cells(i)):
			repaired = true
		_spawners.append(pts)
	if repaired:
		_reclip_walls()

## Keep a point's whole PAD_CLEARANCE footprint inside its own arena. A gate
## rolled close to a corner can put a raw FRONT/SIDE offset past the arena
## edge; clamping is the bounded, deterministic fix — a degenerate arena that
## clamps two slots onto the same point is caught and refused explicitly by
## validate_spawners, never silently produced as a valid layout.
func _clamp_to_arena(p: Vector2, r: Rect2) -> Vector2:
	var inset := PAD_CLEARANCE + CELL
	return Vector2(
		clampf(p.x, r.position.x + inset, r.end.x - inset),
		clampf(p.y, r.position.y + inset, r.end.y - inset))

## Clear the connected entry pad, clipped to this arena. Report whether any
## rock changed so ordinary generation need not rebuild the drawing geometry.
func _reserve_pad(pad: Rect2, bounds: Rect2i) -> bool:
	var c0 := cell_xy(pad.position)
	var c1 := cell_xy(pad.end)
	var repaired := false
	for y in range(maxi(c0.y, bounds.position.y), mini(c1.y, bounds.end.y - 1) + 1):
		var row := y * w
		for x in range(maxi(c0.x, bounds.position.x), mini(c1.x, bounds.end.x - 1) + 1):
			if solid[row + x] != 0:
				solid[row + x] = 0
				repaired = true
	return repaired

## Keep untouched equipment whole; split a partly cleared wall into surviving
## row spans. A bounding box would redraw rock across holes in the cleared pad.
## Called before zones are painted, when changing rect indices is still safe.
func _reclip_walls() -> void:
	var kept: Array = []
	for entry in rects:
		if int(entry[1]) != Kind.WALL:
			kept.append(entry)
			continue
		var cells := _cells_of(entry[0])
		var count := 0
		for y in range(cells.position.y, cells.end.y):
			for x in range(cells.position.x, cells.end.x):
				count += int(solid[y * w + x] != 0)
		if count == cells.get_area():
			kept.append(entry)
			continue
		for y in range(cells.position.y, cells.end.y):
			var x := cells.position.x
			while x < cells.end.x:
				if solid[y * w + x] == 0:
					x += 1
					continue
				var start := x
				while x < cells.end.x and solid[y * w + x] != 0:
					x += 1
				kept.append([Rect2(origin + Vector2(start, y) * CELL,
					Vector2(x - start, 1) * CELL), Kind.WALL])
	rects = kept

## The reserved arrival point for `slot` in arena `arena_index`, derived once
## in generate(). Both indices are caller-controlled and always in range in
## real use; an out-of-range one is a programmer error and indexes straight
## into the array rather than returning a silent (0, 0) — the design this
## backs explicitly refuses that fallback.
func spawner_pos(arena_index: int, slot: int) -> Vector2:
	assert(arena_index >= 0 and arena_index < _spawners.size(),
		"spawner_pos: arena_index out of range")
	var pts: PackedVector2Array = _spawners[arena_index]
	assert(slot >= 0 and slot < pts.size(), "spawner_pos: slot out of range")
	return pts[slot]

## Nearest point of `rect` to `p`, tested against `radius` — one shape test
## used for both a cell's own square and a gate's block rect.
func _rect_within_radius(rect: Rect2, p: Vector2, radius: float) -> bool:
	var nx := clampf(p.x, rect.position.x, rect.end.x)
	var ny := clampf(p.y, rect.position.y, rect.end.y)
	return p.distance_squared_to(Vector2(nx, ny)) <= radius * radius

func _cell_rect(c: Vector2i) -> Rect2:
	return Rect2(origin + Vector2(c.x, c.y) * CELL, Vector2(CELL, CELL))

## Whether a disc of `radius` centred on `p` is a safe place for a player to
## occupy: no rock, no static zone (hazard, slow or corruption — none of them
## is a safe arrival), no void, no shut gate's block rect, and no temporary
## zone, over the WHOLE footprint rather than just the centre cell. Out of the
## grid is UNSAFE here — the opposite of is_solid's "outside is open", which
## exists for enemy spawns that are allowed to sit on the window's edge; a
## player arrival point never should. `arena_index >= 0` additionally requires
## the entire footprint to stay inside that one arena; -1 permits a safe
## corridor point, for a return that lands a player back on the walk between
## arenas rather than inside either one.
func spawn_is_safe(p: Vector2, radius: float, arena_index: int = -1) -> bool:
	if not p.is_finite() or not is_finite(radius) or radius < 0.0 or arena_index < -1:
		return false
	if p.x - radius < origin.x or p.x + radius >= origin.x + size.x \
			or p.y - radius < origin.y or p.y + radius >= origin.y + size.y:
		return false
	if arena_index >= 0:
		if arena_index >= arenas.size():
			return false
		var r: Rect2 = arenas[arena_index]
		if p.x - radius < r.position.x or p.x + radius > r.end.x \
				or p.y - radius < r.position.y or p.y + radius > r.end.y:
			return false
	var half := Vector2(radius, radius)
	var c0 := cell_xy(p - half)
	var c1 := cell_xy(p + half)
	for y in range(c0.y, c1.y + 1):
		for x in range(c0.x, c1.x + 1):
			var c := Vector2i(x, y)
			if not _rect_within_radius(_cell_rect(c), p, radius):
				continue        # corner of the bounding box, outside the disc
			if not in_bounds(c):
				return false
			var i := c.y * w + c.x
			if solid[i] != 0 or zone[i] != 0:
				return false
			if not voided.is_empty() and voided[i] != 0:
				return false
	for b in _blocks:
		if _rect_within_radius(b, p, radius):
			return false
	for k in _tz_pos.size():
		var reach := radius + sqrt(_tz_r2[k])
		if p.distance_squared_to(_tz_pos[k]) <= reach * reach:
			return false
	return true

## Empty on a valid generation; otherwise names the arena, slot and rule the
## generated layout failed. Called once after generate(), before the roster
## exists, so a bad seed refuses the session visibly instead of an assert an
## exported build would strip. Checks, per arena: every point's whole
## footprint stays inside the arena and is spawn_is_safe; every pair of the
## four is at least SPAWN_SEPARATION apart (or the caller's own diameter, if
## larger — never less than that, on pain of embedding a party inside itself,
## which also rules out any two coinciding); and the pad can reach the arena's
## playable region, not merely the other three points in a sealed pocket.
func validate_spawners(radius: float) -> String:
	if _spawners.size() != arenas.size():
		return "terrain has %d arenas but %d spawner sets" \
			% [arenas.size(), _spawners.size()]
	var min_sep := maxf(SPAWN_SEPARATION, radius * 2.0)
	for i in arenas.size():
		var pts: PackedVector2Array = _spawners[i]
		if pts.size() != SessionRules.MAX_PLAYERS:
			return "arena %d has %d spawner slots, expected %d" \
				% [i, pts.size(), SessionRules.MAX_PLAYERS]
		var r: Rect2 = arenas[i]
		for slot in SessionRules.MAX_PLAYERS:
			var p: Vector2 = pts[slot]
			if p.x - radius < r.position.x or p.x + radius > r.end.x \
					or p.y - radius < r.position.y or p.y + radius > r.end.y:
				return "arena %d slot %d: spawn point %s falls outside the arena" \
					% [i, slot, p]
			if not spawn_is_safe(p, radius, i):
				return "arena %d slot %d: spawn point %s is not safe at radius %.1f" \
					% [i, slot, p, radius]
		for a in SessionRules.MAX_PLAYERS:
			for b in range(a + 1, SessionRules.MAX_PLAYERS):
				var d: float = pts[a].distance_to(pts[b])
				if d < min_sep:
					return ("arena %d: spawn slots %d and %d are %.1f units " +
						"apart, need >= %.1f") % [i, a, b, d, min_sep]
		var bounds := arena_cells(i)
		var seen := _reach(cell_index(pts[0]), bounds)
		var reachable := 0
		for y in range(bounds.position.y, bounds.end.y):
			for x in range(bounds.position.x, bounds.end.x):
				var idx := y * w + x
				reachable += int(seen[idx] != 0)
				if solid[idx] == 0 and seen[idx] == 0:
					return "arena %d: spawn pad is disconnected from the playable region" % i
		if float(reachable) < float(bounds.get_area()) * REACHABLE_FLOOR:
			return "arena %d: spawn pad cannot reach enough playable ground" % i
	return ""
