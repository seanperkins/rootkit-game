class_name Feel extends RefCounted

## The presentation state nothing simulated depends on: screen-shake trauma, the
## hitstop deadline, the floating damage numbers, and the outbound audio-event
## list.
##
## PURE, in the sense `scripts/build/` is pure — no scene tree, no engine calls
## beyond RefCounted. That is what lets a suite assert the numbers that decide
## whether this feels good without standing up a viewport.
##
## In particular this class NEVER writes `Engine.time_scale`. It reports the
## scale it wants and run.gd applies it. A RefCounted that touched an engine
## singleton would not be pure, and the split is load-bearing for testing: the
## deadline arithmetic is assertable here, but only a test driving run.gd can
## catch a time scale left stranded at 0.05 — which is the failure that actually
## bricks the process.

## Peak camera displacement, in world units, at trauma 1.0.
const MAX_OFFSET := 26.0

## Trauma per second of decay. A hit reads for roughly half a second.
const TRAUMA_DECAY := 1.6

## How far time slows during a hitstop, and for how long in WALL-CLOCK ms.
## Wall clock rather than dt, because `Engine.time_scale` scales the delta the
## engine hands us: a dt-fed 60ms timer would run 20x long at this scale.
const HITSTOP_SCALE := 0.05
const HITSTOP_MS := 60

## Live damage numbers. Hard cap, oldest evicted: a working build at the enemy
## cap produces thousands of these a second, which costs more than the rest of
## the frame and communicates nothing — a number nobody can read is noise.
const NUMBER_CAP := 24
const NUMBER_LIFE := 0.75
const NUMBER_RISE := 42.0

var trauma := 0.0

## Absolute Time.get_ticks_msec() value, or 0 when no hitstop is live.
var hitstop_until_ms := 0

## [pos, text, colour, life] rows, oldest first.
var numbers: Array = []

## Event ids emitted this tick, drained by the Sfx node. The simulation never
## holds a reference to that node; it appends strings here and forgets.
var sfx: PackedStringArray = PackedStringArray()

var _noise: Callable = Callable()
var _rng := RandomNumberGenerator.new()

func _init() -> void:
	_rng.randomize()

## Injectable so a suite can assert more than a magnitude bound — an unseeded
## source cannot catch a sign flip or an axis-correlation bug.
func set_noise(fn: Callable) -> void:
	_noise = fn

## MAGNITUDE <= 1, not two independent axes in [-1, 1]: independent axes put the
## diagonal at sqrt(2) and the offset outside MAX_OFFSET, which is the bound the
## suite asserts and the name promises.
func _sample_noise() -> Vector2:
	if _noise.is_valid():
		return _noise.call()
	var a := _rng.randf() * TAU
	return Vector2(cos(a), sin(a)) * _rng.randf()

## Events ADD trauma and it saturates. Without the clamp the squaring below
## turns twelve detonations into 3.24x MAX_OFFSET and the constant stops being a
## maximum.
func add_trauma(v: float) -> void:
	trauma = clampf(trauma + v, 0.0, 1.0)

## Squared on purpose: at trauma 0.3 this is 9% of maximum and reads as a nudge,
## at 1.0 it is violent. One tunable covers the whole range, and overlapping
## events saturate rather than stacking into nausea.
##
## The `shake` preference multiplies this result in run.gd, OUTSIDE the square.
## Folded into trauma instead, a legal shake of 2.0 would yield 4x rather than
## 2x and this function would stop being bounded by MAX_OFFSET.
func shake_offset() -> Vector2:
	if trauma <= 0.0:
		return Vector2.ZERO
	return _sample_noise() * (MAX_OFFSET * trauma * trauma)

func start_hitstop(now_ms: int, ms: int = HITSTOP_MS) -> void:
	hitstop_until_ms = now_ms + ms

func time_scale() -> float:
	return HITSTOP_SCALE if hitstop_until_ms > 0 else 1.0

## True when this call ENDED a hitstop, so the caller knows to write the engine
## back to 1.0 exactly once.
func release_hitstop(now_ms: int) -> bool:
	if hitstop_until_ms > 0 and now_ms >= hitstop_until_ms:
		hitstop_until_ms = 0
		return true
	return false

func add_number(pos: Vector2, text: String, colour: Color) -> void:
	numbers.append([pos, text, colour, NUMBER_LIFE])
	# Evict rather than refuse: the most recent hits are the ones the player is
	# looking at.
	while numbers.size() > NUMBER_CAP:
		numbers.remove_at(0)

func emit(id: String) -> void:
	sfx.append(id)

func drain_sfx() -> PackedStringArray:
	var out := sfx
	sfx = PackedStringArray()
	return out

## Fed an UNSCALED delta by run.gd's presentation half. Everything here is
## presentation, so none of it may run on the simulation clock — during a
## hitstop that clock is 20x slow, and after death it has stopped entirely.
func step(dt: float) -> void:
	trauma = maxf(0.0, trauma - TRAUMA_DECAY * dt)
	var i := 0
	while i < numbers.size():
		numbers[i][3] -= dt
		if numbers[i][3] <= 0.0:
			numbers.remove_at(i)
		else:
			numbers[i][0].y -= NUMBER_RISE * dt
			i += 1
