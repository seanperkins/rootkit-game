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
	"negative_owner_never_decodes_to_slot_zero", "structural_determinism_rules",
	"no_libm_reaches_hashed_state"]

func _initialize() -> void:
	print("ROOTKIT — determinism rules\n")
	SaveGame.use_fresh_state()
	await tick_ignores_dt_below_guard()
	await hitstop_costs_fixed_ticks()
	no_clock_in_tick_graph()
	await tick_rngs_derive_from_descriptor()
	await negative_owner_never_decodes_to_slot_zero()
	structural_determinism_rules()
	no_libm_reaches_hashed_state()
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
	r._fx.append([r.FxKind.RIPPLE, Vector2.ZERO, Vector2.RIGHT, 100.0, 1.0, Color.WHITE])
	var life_before: float = r._fx[0][4]

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
		r._fx[0][4] < life_before)

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

# ------------------------------------------------- the libm guard -----------

## Files whose contents are presentation or infrastructure and may call libm
## freely. Everything NOT listed is scanned: the guard fails CLOSED, so a new
## simulation file is guarded the day it is added rather than the day someone
## remembers to list it.
const LIBM_EXEMPT_FILES := [
	"res://scripts/ui/", "res://scripts/audio/", "res://scripts/meta/",
	"res://scripts/update/", "res://scripts/net/transport.gd",
	"res://scripts/run/feel.gd", "res://scripts/run/props.gd",
	"res://scripts/run/backdrop.gd",
]

## Functions inside a scanned file that are presentation. run.gd holds the
## simulation and its renderer in one 5900-line file, so the boundary has to be
## named. An ALLOWLIST, not a denylist: an unrecognised function is guarded.
const LIBM_EXEMPT_FUNCS := [
	"_draw", "_draw_ring", "_draw_chunk", "_update_renderers", "_make_mm",
	"_build_environment", "_build_renderers", "_prime_constant_instances",
	"_present", "_age_fx", "to_iso", "from_iso", "_visible_world_rect",
	"_void_runs", "_route_points", "_ground_quad", "_depth_sort", "_process",
	"_refresh_view", "_player_draw_list",
]

## Bare calls. Matched only when NOT preceded by `.` or an identifier character,
## so `DetMath.sin(` (the replacement), `dsin(`, `asin(`, `_kernel_sin(` and
## `powi(` do not trip it.
const LIBM_BARE := ["cos", "sin", "tan", "acos", "asin", "atan", "atan2",
	"exp", "log", "pow", "randfn", "ease", "lerp_angle", "deg_to_rad",
	"rad_to_deg"]

## Member and constructor forms, matched literally. There is no DetMath spelling
## that contains these, so any hit is a violation.
const LIBM_MEMBER := [".rotated(", ".angle()", ".angle_to(", ".angle_to_point(",
	".slerp(", "from_angle(", "Transform2D("]

static func _is_ident_char(c: String) -> bool:
	return c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") \
		or (c >= "0" and c <= "9")

## Every libm reference in `src` that lands in a non-exempt function.
static func libm_hits(path: String, src: String) -> Array:
	var out := []
	var owner := ""
	for raw in src.split("\n"):
		var line := raw
		var t := line.strip_edges()
		# `static func` is a boundary too. It was not, and `to_iso` (run.gd, a
		# static func) sat in the presentation allowlist where it could never
		# match — the allowlist entry was dead and two of the three pow sites
		# lived in static hosts attributed to whatever named function preceded
		# them.
		if t.begins_with("func ") or t.begins_with("static func "):
			var head := t.substr(12) if t.begins_with("static func ") else t.substr(5)
			var paren := head.find("(")
			owner = head.substr(0, paren) if paren > 0 else head
			continue
		if t.begins_with("#") or t.is_empty():
			continue
		if owner in LIBM_EXEMPT_FUNCS:
			continue
		for tok in LIBM_MEMBER:
			if line.contains(str(tok)):
				out.append("%s %s: %s" % [path, owner, tok])
		for tok in LIBM_BARE:
			var probe: String = str(tok) + "("
			var at := line.find(probe)
			while at >= 0:
				var before := line[at - 1] if at > 0 else " "
				if before != "." and not _is_ident_char(before):
					out.append("%s %s: %s(" % [path, owner, tok])
					break
				at = line.find(probe, at + 1)
	return out

static func _gd_files(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var full := dir.path_join(n)
		if d.current_is_dir():
			_gd_files(full, out)
		elif n.ends_with(".gd"):
			out.append(full)
		n = d.get_next()
	d.list_dir_end()

## No libm transcendental reaches hashed state, on any platform.
##
## This is the load-bearing artefact, not CI's two-runner diff. glibc
## ifunc-selects __sin_fma by CPU feature, so two x86_64 machines can disagree;
## macOS and Windows use different libms entirely; and the probe only ever
## plays subnet 1, so whole call sites are never executed by it. The diff
## witnesses the bug on one pair of machines. This says the class cannot recur.
func no_libm_reaches_hashed_state() -> void:
	var files: Array = []
	_gd_files("res://scripts", files)
	_gd_files("res://data", files)
	files.append("res://tools/determinism_probe.gd")
	files.append("res://tests/support/perf_fixture.gd")
	var hits := []
	var scanned := 0
	for f in files:
		var path: String = str(f)
		var skip := false
		for ex in LIBM_EXEMPT_FILES:
			if path.begins_with(str(ex)):
				skip = true
		if skip:
			continue
		scanned += 1
		hits.append_array(libm_hits(path, FileAccess.get_file_as_string(path)))
	_check("no libm transcendental below the world guard (%d files scanned)" % scanned,
		hits, [])

	# The guard must actually fire, including inside a `static func` — the
	# defect above would otherwise survive the very test written to catch it.
	var fixture := "static func hp_mult(subnet: int) -> float:\n\treturn pow(1.55, subnet)\n"
	_check("the guard fires on pow() in a static func",
		libm_hits("fixture.gd", fixture).size(), 1)
	var fixture2 := "func _step9_x() -> void:\n\tvar v := d.rotated(0.5)\n"
	_check("the guard fires on .rotated() in a step",
		libm_hits("fixture.gd", fixture2).size(), 1)
	# And must NOT fire on the replacements.
	# The replacements, plus an identifier that merely ENDS in a token name.
	# (`asin(` deliberately absent: it is itself libm and the guard bans it.)
	var ok := "func _step2_integrate() -> void:\n\tvar v := DetMath.unit(a)\n" \
		+ "\tvar w := DetMath.powi(x, 2)\n\tvar u := DetMath.dsin(a) + _kernel_cos(b)\n"
	_check("the guard ignores DetMath calls and identifiers ending in a token",
		libm_hits("fixture.gd", ok), [])
	finished["no_libm_reaches_hashed_state"] = true

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
