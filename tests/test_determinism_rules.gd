extends SceneTree

## The rules the deterministic tick depends on, driven against the real run.
##
## Lockstep needs a tick that steps the same amount of world per call no matter
## what frame delta the engine hands it, a hitstop that costs a fixed number of
## ticks rather than a wall-clock interval, presentation that keeps running while
## the world is frozen, and no clock or engine-global anywhere the simulation can
## reach. These are the properties every later networking task assumes.

var failures := 0
var finished := {}

const DT := 1.0 / 60.0

const CASES := ["tick_ignores_dt_below_guard", "hitstop_costs_fixed_ticks",
	"no_clock_in_tick_graph", "tick_rngs_derive_from_descriptor"]

func _initialize() -> void:
	print("ROOTKIT — determinism rules\n")
	SaveGame.use_fresh_state()
	await tick_ignores_dt_below_guard()
	await hitstop_costs_fixed_ticks()
	no_clock_in_tick_graph()
	await tick_rngs_derive_from_descriptor()
	print("")
	for c in CASES:
		if not finished.has(c):
			print("  FAIL  case '%s' never finished — it aborted part way" % c)
			failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want or (got is float and want is float and abs(got - want) < 1e-5):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _check_true(label: String, got: bool) -> void:
	_check(label, got, true)

func _fresh_run() -> Node2D:
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(r)
	await process_frame
	return r

## Below the guard every simulation step ages by SessionRules.TICK_DT, never by
## the frame delta. Two fresh runs given the same input for one tick must move
## the player by the same displacement even when one is stepped with a delta 50x
## larger — proof the world does not read `dt`.
func tick_ignores_dt_below_guard() -> void:
	var a: Node2D = await _fresh_run()
	var b: Node2D = await _fresh_run()
	a.input_override = Vector2.RIGHT
	b.input_override = Vector2.RIGHT
	var a0: Vector2 = a.player_pos
	var b0: Vector2 = b.player_pos
	a._physics_process(DT)
	b._physics_process(DT * 50.0)
	var da: Vector2 = a.player_pos - a0
	var db: Vector2 = b.player_pos - b0
	_check_true("player moved at all", da.length() > 0.0)
	_check_true("displacement is independent of the frame delta",
		da.distance_to(db) < 1e-4)
	a.free()
	b.free()
	await process_frame
	finished["tick_ignores_dt_below_guard"] = true

## A hitstop freezes the world for exactly HITSTOP_TICKS ticks. During those
## ticks the player does not move (world frozen) but effects still age
## (presentation runs above the guard). The tick after, the world steps again.
func hitstop_costs_fixed_ticks() -> void:
	var r: Node2D = await _fresh_run()
	r.input_override = Vector2.RIGHT
	# A live, unpaused, unfinished run: the hitstop gate is the only thing that
	# can stop the world.
	_check("run is alive", r.alive, true)
	r._fx_ring.append([Vector2.ZERO, 100.0, 1.0, Color.WHITE])
	var life_before: float = r._fx_ring[0][2]

	r._hitstop()
	_check("a hitstop is HITSTOP_TICKS long", r.hitstop_ticks,
		SessionRules.HITSTOP_TICKS)
	var frozen_at: Vector2 = r.player_pos
	for i in SessionRules.HITSTOP_TICKS:
		r._physics_process(DT)
		_check_true("world frozen on hitstop tick %d" % i,
			r.player_pos.distance_to(frozen_at) < 1e-6)
	_check("the hitstop drained to zero", r.hitstop_ticks, 0)
	_check_true("effects aged while the world was frozen",
		r._fx_ring[0][2] < life_before)

	r._physics_process(DT)
	_check_true("the world steps again after the hitstop",
		r.player_pos.distance_to(frozen_at) > 0.0)
	r.free()
	await process_frame
	finished["hitstop_costs_fixed_ticks"] = true

## No wall clock and no engine-global time scale anywhere the tick can reach. A
## call to Time.get_* would read a real clock the simulation cannot share across
## peers; Engine.time_scale is process-global and cannot be part of a
## deterministic sim. The two `_draw`-only pulses run at display rate outside the
## tick call graph, so this scans only the simulation-side functions.
func no_clock_in_tick_graph() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/run/run.gd")
	_check("no Engine.time_scale remains in run.gd",
		src.contains("Engine.time_scale"), false)

	var tick_funcs := ["_physics_process", "_present", "_hitstop", "_die",
		"_damage_player"]
	for name in tick_funcs:
		var body := _func_body(src, name)
		_check_true("function %s exists" % name, body != "")
		_check("no Time.get_ in %s" % name, body.contains("Time.get_"), false)
		_check("no Engine.time_scale in %s" % name,
			body.contains("Engine.time_scale"), false)
	finished["no_clock_in_tick_graph"] = true

## A run configured with a chosen session seed, so the derivation of every
## stream from that one seed can be inspected.
func _run_with_seed(seed_value: int) -> Node2D:
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	var profile := {"slot": 0, "name": "",
		"counters": SaveGame.session_counters()}
	var desc := NetworkSession.validate_descriptor(
		NetworkSession.solo_descriptor(profile, seed_value))
	r.configure_session(NetworkSession.create(desc, 0,
		NetworkSession.Role.SOLO))
	root.add_child(r)
	await process_frame
	return r

## Every RNG the tick can draw from is seeded as a pure function of the
## descriptor seed and nothing else — no randomize(), no clock. Two peers on the
## same seed seed every stream identically; a different seed reseeds all of them
## and regenerates the terrain. Per-slot card streams are distinct.
func tick_rngs_derive_from_descriptor() -> void:
	var base := 111
	var a: Node2D = await _run_with_seed(base)
	var b: Node2D = await _run_with_seed(base)
	var c: Node2D = await _run_with_seed(222)

	_check("the sim rng seed derives from the descriptor", a._rng.seed,
		base + a._SEED_SIM)
	_check("the block rng seed derives", a._block_rng.seed,
		base + a._SEED_BLOCK)
	_check("the director rng seed derives", a.director.rng.seed,
		base + a._SEED_DIRECTOR)
	for s in SessionRules.MAX_PLAYERS:
		_check("card stream %d derives from the descriptor" % s,
			a._card_rng[s].seed, base + s * a._SEED_CARD_STEP)
	_check_true("per-slot card streams are distinct",
		a._card_rng[0].seed != a._card_rng[1].seed)

	_check("two peers on one seed seed the sim rng identically",
		a._rng.seed, b._rng.seed)
	_check_true("and generate identical terrain",
		a.terrain.solid == b.terrain.solid)
	_check_true("a different seed reseeds the sim rng",
		a._rng.seed != c._rng.seed)
	_check_true("and regenerates the terrain",
		a.terrain.solid != c.terrain.solid)

	a.free()
	b.free()
	c.free()
	await process_frame
	finished["tick_rngs_derive_from_descriptor"] = true

## The source text of a top-level GDScript function, from its `func NAME(` line
## up to the next line that begins a new top-level `func ` at column zero.
func _func_body(src: String, name: String) -> String:
	var lines := src.split("\n")
	var out := ""
	var inside := false
	for line in lines:
		if line.begins_with("func %s(" % name):
			inside = true
			out = line + "\n"
			continue
		if inside:
			if line.begins_with("func "):
				break
			out += line + "\n"
	return out
