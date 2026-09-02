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
	"no_clock_in_tick_graph", "tick_rngs_derive_from_descriptor",
	"negative_owner_never_decodes_to_slot_zero", "structural_determinism_rules"]

func _initialize() -> void:
	print("ROOTKIT — determinism rules\n")
	SaveGame.use_fresh_state()
	await tick_ignores_dt_below_guard()
	await hitstop_costs_fixed_ticks()
	no_clock_in_tick_graph()
	await tick_rngs_derive_from_descriptor()
	await negative_owner_never_decodes_to_slot_zero()
	structural_determinism_rules()
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
	var a0: Vector2 = a.player_pos[a.local_slot]
	var b0: Vector2 = b.player_pos[b.local_slot]
	a._physics_process(DT)
	b._physics_process(DT * 50.0)
	var da: Vector2 = a.player_pos[a.local_slot] - a0
	var db: Vector2 = b.player_pos[b.local_slot] - b0
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
	var frozen_at: Vector2 = r.player_pos[r.local_slot]
	for i in SessionRules.HITSTOP_TICKS:
		r._physics_process(DT)
		_check_true("world frozen on hitstop tick %d" % i,
			r.player_pos[r.local_slot].distance_to(frozen_at) < 1e-6)
	_check("the hitstop drained to zero", r.hitstop_ticks, 0)
	_check_true("effects aged while the world was frozen",
		r._fx_ring[0][2] < life_before)

	r._physics_process(DT)
	_check_true("the world steps again after the hitstop",
		r.player_pos[r.local_slot].distance_to(frozen_at) > 0.0)
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

## An event owner is decoded through one helper, so the plural cutover teaches
## only that helper the slot encoding. The sentinels the hit queue writes — -1
## (unowned / environment) and -2 (unset) — must decode to NO owner, never to
## slot zero, or an unowned kill would silently credit the first player.
func negative_owner_never_decodes_to_slot_zero() -> void:
	var r: Node2D = await _fresh_run()
	_check("the -1 sentinel decodes to no slot", r._decode_exploit(-1).x, -1)
	_check("the -2 sentinel decodes to no slot", r._decode_exploit(-2).x, -1)
	_check("a wildly negative id decodes to no slot",
		r._decode_exploit(-999).x, -1)
	_check("a negative id resolves to no exploit",
		r._resolved(-1) == null, true)
	# A valid id still resolves to a real exploit on the local slot.
	_check("a valid id decodes to the local slot",
		r._decode_exploit(0).x, r.local_slot)
	_check_true("a valid id resolves to an exploit", r._resolved(0) != null)
	r.free()
	await process_frame
	finished["negative_owner_never_decodes_to_slot_zero"] = true

## Every function in run.gd whose name starts with `prefix`.
func _funcs_named(src: String, prefix: String) -> Array:
	var out := []
	for line in src.split("\n"):
		if line.begins_with("func " + prefix):
			var name := line.substr(5, line.find("(") - 5)
			out.append(name)
	return out

## The structural rules a deterministic tick depends on, checked against the
## source so a regression cannot pass by accident:
##   - simulation steps never receive the frame delta;
##   - no clock, device, signal-connection or peer-state read in any step, in
##     input application, or in the hashed collection;
##   - the device is read in exactly one function;
##   - no stream is seeded from randomize();
##   - a dictionary iterated for the hash is sorted first.
func structural_determinism_rules() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/run/run.gd")
	var tick := _func_body(src, "_physics_process")
	# Every _stepN call in the tick takes `sdt`, never the frame delta.
	var bad_dt := false
	for line in tick.split("\n"):
		var s := line.strip_edges()
		if s.begins_with("_step") and s.contains("(_dt"):
			bad_dt = true
	_check("no simulation step receives the frame delta", bad_dt, false)

	var sim_funcs := _funcs_named(src, "_step")
	sim_funcs.append_array(["_apply_records", "_apply_choice", "_resolve_deadlines",
		"_settle_offers", "_open_round", "_on_death", "_on_flip", "_behave",
		"_emit_vector", "_state_hash", "_derived_get", "_manifest_get",
		"_die", "_damage_player", "_steps78_drain"])
	var bad := []
	for name in sim_funcs:
		var body := _func_body(src, name)
		if body == "":
			bad.append("%s missing" % name)
			continue
		for needle in ["Time.get_", "Engine.time_scale", "Input.", "get_connections(",
				"_session.role", "transport", "randomize("]:
			if body.contains(needle):
				bad.append("%s contains %s" % [name, needle])
	_check("no step, application or hash path reads a clock, device, connection or peer state",
		bad, [])

	# The device is read in exactly one function.
	var readers := []
	var current := ""
	for line in src.split("\n"):
		if line.begins_with("func "):
			current = line.substr(5, line.find("(") - 5)
		elif line.contains("Input.") and not line.strip_edges().begins_with("#"):
			if not readers.has(current):
				readers.append(current)
	_check("the device is read in one function only", readers, ["_poll_local_input"])

	# No stream calls randomize(), in run.gd or the classes it seeds.
	var seeded := true
	for path in ["res://scripts/run/run.gd", "res://scripts/run/spawn_director.gd",
			"res://scripts/run/terrain.gd", "res://scripts/run/blocks.gd"]:
		for line in FileAccess.get_file_as_string(path).split("\n"):
			var s := line.strip_edges()
			if s.contains("randomize(") and not s.begins_with("#"):
				seeded = false
	_check("no simulation stream calls randomize()", seeded, true)

	# Dictionaries that feed the hash are iterated in SORTED key order.
	var derived := _func_body(src, "_derived_get")
	var lines := derived.split("\n")
	var unsorted := false
	for i in lines.size():
		if lines[i].contains(".keys()"):
			var sorted_soon := false
			for j in range(i, mini(i + 4, lines.size())):
				if lines[j].contains(".sort()"):
					sorted_soon = true
			if not sorted_soon:
				unsorted = true
	_check("every dictionary the hash walks is sorted first", unsorted, false)
	finished["structural_determinism_rules"] = true

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
