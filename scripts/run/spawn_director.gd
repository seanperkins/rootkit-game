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

var waves: Array = []
var elapsed: float = 0.0
var _milli: Array = []
var rng := RandomNumberGenerator.new()

var spawned: int = 0
var dropped: int = 0        # pool was full; counted, never silently ignored
var boss_spawned: bool = false

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
	]
	_milli.resize(waves.size())
	for i in _milli.size():
		_milli[i] = 0

func reset() -> void:
	elapsed = 0.0
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
		var span := minf(elapsed, w.t1) - maxf(prev, w.t0)
		if span <= 0.0:
			continue
		_milli[i] += int(round(w.rate * span * 1000.0))
		while _milli[i] >= 1000:
			_milli[i] -= 1000
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
