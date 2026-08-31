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
	return pow(HP_PER_SUBNET, maxi(subnet, 1) - 1) * within

## Corruption thresholds step per SUBNET only, never with elapsed. They are held
## per TYPE in one array shared by every live enemy, so a continuous ramp would
## retroactively move the goalposts on an enemy already half-corrupted.
static func threshold_mult(subnet: int) -> float:
	return pow(HP_PER_SUBNET, maxi(subnet, 1) - 1)

var waves: Array = []
var elapsed: float = 0.0
var _milli: Array = []
var rng := RandomNumberGenerator.new()

var spawned: int = 0
var dropped: int = 0        # pool was full; counted, never silently ignored
var boss_spawned: bool = false

## One a minute, and never in the last: ICE arrives at SUBNET_SECONDS and the
## subnet's ending is not a stage to share.
const MINIBOSS_TIMES := [60.0, 120.0, 180.0, 240.0]
const MINIBOSS_IDS := [&"fork_bomb", &"packet_filter", &"null_ptr", &"kernel_panic"]

var miniboss_fired: PackedByteArray

## Wave rows address enemy TYPES BY INDEX, so a bare number breaks silently the
## moment a type is inserted above it. Resolved from the table by id instead.
static func _idx(id: StringName) -> int:
	var all := EnemyTable.all()
	for i in all.size():
		if all[i].id == id:
			return i
	return 0

func _init(seed_value: int = 20260829) -> void:
	rng.seed = seed_value
	waves = [
		Wave.new(0.0,   45.0,  0, 1.8, Formation.RING),
		Wave.new(20.0,  90.0,  2, 1.2, Formation.STREAM),
		Wave.new(60.0, 150.0,  0, 3.0, Formation.RING),
		Wave.new(90.0, 180.0,  1, 0.6, Formation.FLANK),
		Wave.new(150.0, 240.0, 2, 3.4, Formation.BURST),
		Wave.new(180.0, 300.0, 0, 4.2, Formation.RING),
		Wave.new(240.0, 300.0, 1, 1.4, Formation.FLANK),
		# The new types, introduced one at a time so each is legible when it
		# first appears rather than arriving in a crowd.
		Wave.new(70.0,  160.0, _idx(&"tracer"),   1.1,  Formation.FLANK),
		Wave.new(110.0, 210.0, _idx(&"sentinel"), 0.5,  Formation.RING),
		Wave.new(150.0, 250.0, _idx(&"probe"),    0.7,  Formation.STREAM),
		Wave.new(190.0, 300.0, _idx(&"rootkit"),  0.6,  Formation.BURST),
		# Kept rare deliberately: each watchdog runs a radius query every tick,
		# and it is meant to be a target you dig for, not a crowd.
		Wave.new(210.0, 300.0, _idx(&"watchdog"), 0.25, Formation.FLANK),
	]
	miniboss_fired = PackedByteArray()
	miniboss_fired.resize(MINIBOSS_TIMES.size())
	_milli.resize(waves.size())
	for i in _milli.size():
		_milli[i] = 0

## Which mini-bosses this step crosses.
##
## Records each as fired, because a step is a RANGE: testing `elapsed > time`
## alone fires every tick after the boundary rather than once at it.
func due_minibosses(dt: float) -> Array:
	var out := []
	for k in MINIBOSS_TIMES.size():
		if miniboss_fired[k] != 0:
			continue
		if elapsed + dt >= MINIBOSS_TIMES[k]:
			miniboss_fired[k] = 1
			out.append(_idx(MINIBOSS_IDS[k]))
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
		var due := int(floor(w.rate * active))
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
			return origin + Vector2(cos(a), sin(a)) * radius
		Formation.STREAM:
			var a2 := rng.randf() * TAU
			return origin + Vector2(cos(a2), sin(a2)) * (radius * 1.15)
		Formation.FLANK:
			var side := 1.0 if rng.randf() < 0.5 else -1.0
			return origin + Vector2(side * radius, rng.randf_range(-radius, radius) * 0.6)
		_:
			var a3 := rng.randf() * TAU
			var burst := origin + Vector2(cos(a3), sin(a3)) * radius
			return burst + Vector2(rng.randf_range(-40, 40), rng.randf_range(-40, 40))
	return origin
