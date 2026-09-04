class_name Blocks extends RefCounted

## The capture point that pays out. One live at a time; hold ground inside it
## while the swarm keeps coming, and the payout is either a fusion or a card.
##
## Pure state: no scene tree, no terrain, no run. The caller injects a placer
## Callable and an RNG, which is what makes the schedule and the drain testable
## without standing up an arena.

## Long enough that the first one lands after the build has something to fuse,
## short enough to arrive inside the first subnet.
const FIRST_SPAWN := 40.0
const INTERVAL := 45.0
const HOLD_SECONDS := 8.0
const RADIUS := 70.0

## Leaving drains at twice the fill rate. Standing off it is a decision, not a
## pause: one second away costs two, and four seconds away wipes the eight you
## were most of the way through.
const DRAIN_RATE := 2.0

## Far enough that reaching it is a move, near enough to stay on screen. Bounded
## by VIEW_RANGE (620.0, run.gd) rather than above it: past that the block is off
## the edge of what the player can see, with no indicator pointing at it.
const MIN_DIST := 400.0
const MAX_DIST := 600.0

var alive := false
var pos := Vector2.ZERO
var progress := 0.0
var elapsed := 0.0
var next_at := FIRST_SPAWN

func reset() -> void:
	alive = false
	pos = Vector2.ZERO
	progress = 0.0
	elapsed = 0.0
	next_at = FIRST_SPAWN

func fraction() -> float:
	return progress / HOLD_SECONDS

## Returns true on the tick the hold completes. `allowed` is false during the
## collapse: a block competing with the walk to the gate makes both objectives
## worse. It is NOT false for a paused run — _physics_process returns before any
## step when paused, so this is not called then and a live block simply freezes.
func tick(dt: float, player_pos: Vector2, allowed: bool, place: Callable,
		rng: RandomNumberGenerator) -> bool:
	elapsed += dt
	if not allowed:
		# Banking nothing is deliberate: a block half-held when the collapse
		# starts would otherwise pay out on the next arena, where it was never
		# earned. next_at moves unconditionally, not only when one was live —
		# `elapsed` advances through a disallowed stretch either way, so a block
		# that merely came DUE during it would otherwise spawn on the first
		# allowed tick afterwards.
		next_at = elapsed + INTERVAL
		alive = false
		progress = 0.0
		return false
	if not alive:
		if elapsed >= next_at:
			var ang := rng.randf() * TAU
			var d := rng.randf_range(MIN_DIST, MAX_DIST)
			pos = place.call(player_pos + DetMath.unit(ang) * d)
			alive = true
			progress = 0.0
		return false
	if player_pos.distance_to(pos) <= RADIUS:
		progress = minf(HOLD_SECONDS, progress + dt)
	else:
		progress = maxf(0.0, progress - DRAIN_RATE * dt)
	if progress >= HOLD_SECONDS:
		alive = false
		progress = 0.0
		next_at = elapsed + INTERVAL
		return true
	return false
