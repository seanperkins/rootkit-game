class_name SpawnDirector extends RefCounted

## Reads a wave table on an INJECTED clock, so a headless test can simulate five
## minutes in milliseconds and assert exact counts.
##
## Intervals are half-open [start, end). Rates accumulate as integer
## milli-spawns: a float accumulator over 300 s lands at 179.99999 and floors to
## 179 instead of 180, which reads as a test bug rather than a spec bug.

class Wave extends RefCounted:
	var t0: float
	var t1: float
	var type_index: int
	var rate: float          # spawns per second
	var formation: int
	func _init(a: float, b: float, ti: int, r: float, f: int) -> void:
		t0 = a; t1 = b; type_index = ti; rate = r; formation = f

enum Formation { RING, STREAM, FLANK, BURST }

const SUBNET_SECONDS := 300.0

## A run is a campaign of subnets, not one of them. Clearing the last is the win.
const CAMPAIGN_SUBNETS := 3

## Enemy integrity scales on two axes and needs both.
##
## WITHIN a subnet: rank buys damage linearly while enemy integrity was a
## constant, so the moment a build passed firewall's 34 HP every enemy died in
## one hit for the rest of the run and never stopped doing so. The wave table
## escalates spawn RATE and enemy TYPE, which cannot answer that on its own —
## more of a thing you one-shot is still a thing you one-shot.
##
## ACROSS subnets: the build now carries forward, so subnet 02 opens against a
## loadout that subnet 01 spent five minutes assembling.
##
## Multiplied rather than summed: a late subnet-03 enemy is 3.8x, not 3.0x, and
## the two axes stay independent — retuning the campaign length does not silently
## retune the within-subnet curve.
const HP_PER_SUBNET := 1.55
const HP_OVER_SUBNET := 0.45

static func hp_mult(subnet: int, elapsed: float) -> float:
	var within := 1.0 + HP_OVER_SUBNET * clampf(elapsed / SUBNET_SECONDS, 0.0, 1.0)
	return DetMath.powi(HP_PER_SUBNET, maxi(subnet, 1) - 1) * within

## A THIRD axis for co-op: extra integrity per extra player. Spawn RATE scales
## linearly with the party (four players face four times the bodies), but four
## builds also deal roughly four times the damage, so rate alone leaves time-to-
## kill per enemy unchanged and the party one-shots everything together. Half
## an enemy's integrity per extra player keeps a full party's time-to-kill
## around 2.5x solo's — pressure that reads as a harder fight rather than the
## same fight with more targets. Reads the IMMUTABLE roster size: a death or a
## park never lowers it, so a party cannot shed difficulty by losing a member.
const HP_PER_EXTRA_PLAYER := 0.50
## The board axis: five exploit rows (from three) fire up to two-thirds more,
## so every enemy carries this much more integrity on top of the subnet,
## elapsed and party axes.
##
## 1.15, down from the 1.40 the perf gate's coverage pin chose. That pin is a
## LOAD instrument — it wants a full field — and it set a number that is paid
## from the first tick, when the board holds one rank-1 row and none of the
## five rows it is pricing. At 1.40 a daemon opened at 14 integrity against a
## 12 dps starting packet and ICE at 980 (1421 by the subnet's end, with the
## elapsed ramp on top); at 1.15 they open at 11.5 and 805. The late-build
## case it exists for still pays it — the multiplier applies at every
## elapsed — and the perf gate's field mean is re-pinned below with the
## reason, because this is a balance change the game wanted rather than a
## lighter tick.
const HP_ROWS := 1.15

static func party_hp_mult(players: int) -> float:
	return 1.0 + HP_PER_EXTRA_PLAYER * float(maxi(players, 1) - 1)

## Corruption thresholds step per SUBNET only, never with elapsed. They are held
## per TYPE in one array shared by every live enemy, so a continuous ramp would
## retroactively move the goalposts on an enemy already half-corrupted.
static func threshold_mult(subnet: int) -> float:
	return DetMath.powi(HP_PER_SUBNET, maxi(subnet, 1) - 1)

var waves: Array = []
var elapsed: float = 0.0
## Spawn-rate multiplier: the party size, set once by the run from the immutable
## roster. Four players face four times the bodies.
var rate_mult: float = 1.0
var _milli: Array = []
var rng := RandomNumberGenerator.new()

var spawned: int = 0
var dropped: int = 0        # pool was full; counted, never silently ignored
var boss_spawned: bool = false

## Never in the last minute: ICE arrives at SUBNET_SECONDS and the subnet's
## ending is not a stage to share. `tests/test_minibosses` asserts that rule,
## so the last time stays at 240.
##
## The gaps CLOSE — 80, 65, 55, 40 — rather than sitting a flat minute apart.
## The first used to land at 60 s, when a first-subnet board is still one
## rank-1 vector: fork_bomb is a CHARGER with 195 integrity at the softened
## board axis and 20 contact damage, which is a wall rather than a set-piece
## that early. Twenty seconds later it meets a board with a second row on it,
## and the compression puts the time it costs back into the crowded half of
## the subnet where the player has something to spend it with.
const MINIBOSS_TIMES := [80.0, 145.0, 200.0, 240.0]
const MINIBOSS_IDS := [&"fork_bomb", &"packet_filter", &"null_ptr", &"kernel_panic"]

var miniboss_fired: PackedByteArray

## Wave rows address enemy TYPES BY INDEX, so a bare number breaks silently the
## moment a type is inserted above it. Resolved from the table by id instead.
func _init(seed_value: int = 20260829) -> void:
	rng.seed = seed_value
	# Rates are the DENSITY axis, and the overlaps are what set it: four rows
	# run at once from 180 s, so the concurrent solo spawn rate used to peak at
	# 9.4/s over 180-240 (daemon 4.2 + worm 3.4 + probe 0.7 + rootkit 0.6 +
	# watchdog 0.25 + firewall 0.6, in their overlapping windows) against a
	# board that kills a handful a second. A subnet is 300 s long and the pool
	# caps at MAX_ENEMIES 600, so nothing here is unbounded — but the field
	# still arrived faster than any first-subnet build clears it, and being
	# surrounded is what ended the run rather than any single enemy.
	#
	# The four rows below are the overlap, cut so the peak concurrent rate is
	# 6.6/s and one subnet schedules 1288 spawns rather than 1690 (-402: 72
	# from daemon 60-150, 108 from worm 150-240, 192 from daemon 180-300, 30
	# from firewall 240-300). The escalation SHAPE is untouched — every window,
	# formation and type ordering is as it was, and the late phase is still the
	# densest part of the subnet.
	waves = [
		Wave.new(0.0,   45.0,  0, 1.8, Formation.RING),
		Wave.new(20.0,  90.0,  2, 1.2, Formation.STREAM),
		Wave.new(60.0, 150.0,  0, 2.2, Formation.RING),
		Wave.new(90.0, 180.0,  1, 0.6, Formation.FLANK),
		Wave.new(150.0, 240.0, 2, 2.2, Formation.BURST),
		Wave.new(180.0, 300.0, 0, 2.6, Formation.RING),
		Wave.new(240.0, 300.0, 1, 0.9, Formation.FLANK),
		# The new types, introduced one at a time so each is legible when it
		# first appears rather than arriving in a crowd.
		Wave.new(70.0,  160.0, EnemyTable.index_of(&"tracer"),   1.1,  Formation.FLANK),
		Wave.new(110.0, 210.0, EnemyTable.index_of(&"sentinel"), 0.5,  Formation.RING),
		Wave.new(150.0, 250.0, EnemyTable.index_of(&"probe"),    0.7,  Formation.STREAM),
		Wave.new(190.0, 300.0, EnemyTable.index_of(&"rootkit"),  0.6,  Formation.BURST),
		# Kept rare deliberately: each watchdog runs a radius query every tick,
		# and it is meant to be a target you dig for, not a crowd.
		Wave.new(210.0, 300.0, EnemyTable.index_of(&"watchdog"), 0.25, Formation.FLANK),
	]
	miniboss_fired = PackedByteArray()
	miniboss_fired.resize(MINIBOSS_TIMES.size())
	_milli.resize(waves.size())
	for i in _milli.size():
		_milli[i] = 0

## Which mini-bosses this step CROSSES.
##
## Both bounds matter. Without the upper test (`elapsed > time`) it fires every
## tick after the boundary rather than once at it; without the lower test
## (`elapsed < time`) any step that begins past the time fires — so a clock
## jumped forward dumps all four mini-bosses on the same tick, which is what a
## long frame or a director resumed mid-subnet does.
##
## The trade: a frame long enough to step over a boundary entirely skips that
## mini-boss. At a 60 Hz tick that is a frame of over a minute, and losing one
## arrival is much cheaper than gaining four at once.
func due_minibosses(dt: float, first_advance: float = 0.0) -> Array:
	var out := []
	for k in MINIBOSS_TIMES.size():
		if miniboss_fired[k] != 0:
			continue
		var at: float = MINIBOSS_TIMES[k] - (first_advance if k == 0 else 0.0)
		if elapsed < at and elapsed + dt >= at:
			miniboss_fired[k] = 1
			out.append(EnemyTable.index_of(MINIBOSS_IDS[k]))
	return out

func reset() -> void:
	elapsed = 0.0
	# Rearmed, or subnet 02 would get no mini-bosses at all.
	for k in miniboss_fired.size():
		miniboss_fired[k] = 0
	spawned = 0
	dropped = 0
	boss_spawned = false
	for i in _milli.size():
		_milli[i] = 0

## Returns an Array of [type_index, position]. The caller spawns them so the
## director stays testable without a Population.
func step(dt: float, origin: Vector2, radius: float) -> Array:
	var out := []
	if elapsed >= SUBNET_SECONDS:
		return out
	var prev := elapsed
	elapsed = minf(elapsed + dt, SUBNET_SECONDS)
	for i in waves.size():
		var w: Wave = waves[i]
		if elapsed < w.t0 or prev >= w.t1:
			continue
		# Derive the running total from elapsed time rather than accumulating a
		# rounded per-tick increment: rounding each tick made the count depend on
		# the tick rate (1382 spawns at 60 Hz against 1383 at 10 Hz).
		var active: float = minf(elapsed, w.t1) - w.t0
		var due := int(floor(w.rate * rate_mult * active))
		while _milli[i] < due:
			_milli[i] += 1
			out.append([w.type_index, _place(w.formation, origin, radius)])
	return out

func should_spawn_boss() -> bool:
	return elapsed >= SUBNET_SECONDS and not boss_spawned

func _place(formation: int, origin: Vector2, radius: float) -> Vector2:
	match formation:
		Formation.RING:
			var a := rng.randf() * TAU
			return origin + DetMath.unit(a) * radius
		Formation.STREAM:
			var a2 := rng.randf() * TAU
			return origin + DetMath.unit(a2) * (radius * 1.15)
		Formation.FLANK:
			var side := 1.0 if rng.randf() < 0.5 else -1.0
			return origin + Vector2(side * radius, rng.randf_range(-radius, radius) * 0.6)
		_:
			var a3 := rng.randf() * TAU
			var burst := origin + DetMath.unit(a3) * radius
			return burst + Vector2(rng.randf_range(-40, 40), rng.randf_range(-40, 40))
	return origin
