extends SceneTree

## The block: when it spawns, how it fills, and what stops it.

const EXPECTED_CHECKS := 16
const DT := 1.0 / 60.0

var failures := 0
var checks := 0

## _initialize, not _init: one case stands up a real run and awaits a frame.
func _initialize() -> void:
	SaveGame.use_test_paths()
	print("ROOTKIT — blocks\n")
	await process_frame
	the_schedule()
	the_hold()
	await a_live_block_stands_on_open_ground()
	print("")
	if checks != EXPECTED_CHECKS:
		print("  FAIL — ran %d checks, expected %d (a function aborted early)"
			% [checks, EXPECTED_CHECKS])
		failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	checks += 1
	if got == want or (got is float and want is float and abs(got - want) < 1e-5):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 12345
	return r

## The identity placer: no terrain in this suite, so a candidate point is used
## as-is. run.gd passes terrain.nearest_open instead.
func _here(p: Vector2) -> Vector2:
	return p

func _advance(b: Blocks, seconds: float, at: Vector2,
		allowed: bool, rng: RandomNumberGenerator) -> int:
	var fired := 0
	var steps := int(seconds / DT)
	for i in steps:
		if b.tick(DT, at, allowed, _here, rng):
			fired += 1
	return fired

func the_schedule() -> void:
	var b := Blocks.new()
	var rng := _rng()
	_advance(b, 39.0, Vector2.ZERO, true, rng)
	_check("nothing before the first spawn", b.alive, false)
	_advance(b, 2.0, Vector2.ZERO, true, rng)
	_check("one is live after 40 s", b.alive, true)
	_check("and it stands away from the player",
		b.pos.length() >= Blocks.MIN_DIST, true)
	_check("but inside what the player can see",
		b.pos.length() <= Blocks.MAX_DIST, true)

	# Not allowed — the collapse — takes it away and banks nothing.
	var was := b.pos
	_advance(b, 1.0, was, false, rng)
	_check("a disallowed tick despawns it", b.alive, false)
	_check("and keeps no progress", b.progress, 0.0)
	# And does not immediately hand one back: `elapsed` advanced the whole time
	# it was disallowed, so a stale next_at would spawn on the very next tick.
	_advance(b, 1.0, was, true, rng)
	_check("nor does one return on the next allowed tick", b.alive, false)

func the_hold() -> void:
	var b := Blocks.new()
	var rng := _rng()
	_advance(b, 41.0, Vector2.ZERO, true, rng)
	var at := b.pos

	# Four seconds inside, then out: the drain is 2x, so one second away costs
	# two, and two more seconds away wipes the rest.
	_advance(b, 4.0, at, true, rng)
	_check("half filled after four seconds inside", b.progress, 4.0)
	_advance(b, 1.0, at + Vector2(4000, 0), true, rng)
	_check("and drains at twice the rate outside", b.progress, 2.0)
	_advance(b, 2.0, at + Vector2(4000, 0), true, rng)
	_check("down to nothing, not below", b.progress, 0.0)

	var fired := _advance(b, 8.5, at, true, rng)
	_check("eight seconds inside completes it once", fired, 1)
	_check("and it is gone afterwards", b.alive, false)


## Placement goes through terrain.nearest_open, so a block never stands in a
## wall — an unreachable objective is an objective that cannot be taken.
func a_live_block_stands_on_open_ground() -> void:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	_check("the run owns a Blocks", run.blocks != null, true)

	run.blocks.elapsed = Blocks.FIRST_SPAWN
	run.blocks.next_at = 0.0
	run._step2e_blocks(DT)
	_check("it spawned", run.blocks.alive, true)
	_check("on ground you can stand on",
		run.terrain.is_solid(run.blocks.pos), false)

	# The collapse takes it away: the walk to the gate is the objective then.
	run.phase = run.Phase.CLEARED
	run._step2e_blocks(DT)
	_check("and the collapse despawns it", run.blocks.alive, false)
	run.queue_free()
	await process_frame
