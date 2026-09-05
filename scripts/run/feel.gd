class_name Feel extends RefCounted

## The presentation state nothing simulated depends on: screen-shake trauma, the
## hitstop deadline, the floating damage numbers, and the outbound audio-event
## list.
##
## PURE, in the sense `scripts/build/` is pure — no scene tree, no engine calls
## beyond RefCounted. That is what lets a suite assert the numbers that decide
## whether this feels good without standing up a viewport.
##
## The hitstop no longer lives here. It became a fixed tick count on run.gd,
## above the world-step guard, so a freeze costs the same whole ticks on every
## peer instead of a wall-clock interval and a process-global time scale.

## Peak camera displacement, in world units, at trauma 1.0.
const MAX_OFFSET := 26.0

## Trauma per second of decay. A hit reads for roughly half a second.
const TRAUMA_DECAY := 1.6

## Live damage numbers. Hard cap, oldest evicted: a working build at the enemy
## cap produces thousands of these a second, which costs more than the rest of
## the frame and communicates nothing — a number nobody can read is noise.
const NUMBER_CAP := 24
const NUMBER_LIFE := 0.75
const NUMBER_RISE := 42.0

const IMPACT_CAP := 24
const IMPACT_LIFE := 0.24
## [origin, incoming direction, hue, life, destruction]. No per-entity state.
var impacts: Array = []
var recoil := PackedFloat32Array()
var trauma := 0.0

## [pos, text, colour, life] rows, oldest first.
var numbers: Array = []

## Event ids emitted this tick, drained by the Sfx node. The simulation never
## holds a reference to that node; it appends strings here and forgets.
var sfx: PackedStringArray = PackedStringArray()

var _noise: Callable = Callable()
var _rng := RandomNumberGenerator.new()

func _init() -> void:
	_rng.randomize()
	recoil.resize(SessionRules.MAX_PLAYERS)

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

func add_number(pos: Vector2, text: String, colour: Color) -> void:
	numbers.append([pos, text, colour, NUMBER_LIFE])
	# Evict rather than refuse: the most recent hits are the ones the player is
	# looking at.
	while numbers.size() > NUMBER_CAP:
		numbers.remove_at(0)

func add_impact(at: Vector2, incoming: Vector2, colour: Color, destruction: bool = false) -> void:
	var dir := incoming.normalized() if incoming.length_squared() > 0.01 else Vector2.RIGHT
	impacts.append([at, dir, colour, IMPACT_LIFE, destruction])
	while impacts.size() > IMPACT_CAP:
		impacts.remove_at(0)

func kick(slot: int) -> void:
	if slot >= 0 and slot < recoil.size():
		recoil[slot] = 1.0

func emit(id: String) -> void:
	sfx.append(id)

func drain_sfx() -> PackedStringArray:
	var out := sfx
	sfx = PackedStringArray()
	return out

## Fed the frame delta by run.gd's presentation half, which runs above the
## world-step guard every frame. Everything here is presentation, so it keeps
## aging while the world is frozen by a hitstop, paused, or ended.
func step(dt: float) -> void:
	trauma = maxf(0.0, trauma - TRAUMA_DECAY * dt)
	for slot in recoil.size():
		recoil[slot] = maxf(0.0, recoil[slot] - dt * 9.0)
	for impact in impacts:
		impact[3] -= dt
	while not impacts.is_empty() and impacts[0][3] <= 0.0:
		impacts.remove_at(0)
	var i := 0
	while i < numbers.size():
		numbers[i][3] -= dt
		if numbers[i][3] <= 0.0:
			numbers.remove_at(i)
		else:
			numbers[i][0].y -= NUMBER_RISE * dt
			i += 1

# Producer-side aggregation: bounded even when there is no audio consumer.
const VOICE_COUNT := 10
const VOICE_CHASE := 0
const VOICE_CHARGER := 1
const VOICE_FLANKER := 2
const VOICE_SUPPORT := 3
const VOICE_AMBUSHER := 4
const VOICE_RANGED := 5
const VOICE_PLAYER0 := 6
const VOICE_PLAYER1 := 7
const VOICE_PLAYER2 := 8
const VOICE_PLAYER3 := 9
const VOICE_IDS := ["voice_chase", "voice_charger", "voice_flanker", "voice_support",
	"voice_ambusher", "voice_ranged", "voice_player", "voice_player", "voice_player", "voice_player"]
var voice_pending := 0

func emit_voice(index: int) -> void:
	if index >= 0 and index < VOICE_COUNT: voice_pending |= 1 << index

func drain_voice() -> int:
	var pending := voice_pending
	voice_pending = 0
	return pending
