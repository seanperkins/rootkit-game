extends SceneTree

## MILESTONE 0 — the perf gate.
##
## The architecture replaced C++ broadphase in the physics server with a
## hand-rolled uniform grid in interpreted GDScript. This is the only thing that
## tests that bet.
##
## It drives the REAL run._physics_process against the shipped run.tscn. The
## previous version measured a hand-written model of the tick, and review showed
## the model had drifted from the game: a 2560x1440 arena against the real
## 3200x2000 (3600 grid cells against 6300), MAX_BOTNET 8 against 64, and it
## omitted the heavy fire paths — today the beam capsule query and selection
## (slots 2 and 3, rank 5, k up to 16) and the four homing rows, which steer
## and re-acquire per live projectile — plus the drain and the renderer
## writes. It reported PASS while the real tick's p95 exceeded its own scaled
## budget. A gate that measures a model of the code establishes nothing about
## the code.
##
## Run: godot --headless -s res://tests/perf_milestone0.gd

const DT := 1.0 / 60.0
const TICKS := 600
const WARMUP := 60
## DERIVED, not guessed. The frame budget at 60 Hz is 16.67 ms and the tick must
## share it with rendering and present. Measured with tools/fps_probe.gd against
## the real engine loop at absolute cap (600 enemies, 400 projectiles, 1500
## shards, 64 botnet, three max-rank exploits, everything on screen): the game
## sustains 60 fps — mean frame 16.65 ms, p99 17.63 ms — with the tick at ~8 ms
## mean / ~9.8 ms p99. That leaves render+present comfortably inside the frame,
## so 11 ms of tick (66% of the frame) is the supported ceiling. The previous
## 8.0 was an arbitrary number I picked before anything had been measured.
const BUDGET_MS := 11.0

## Gated on p95, not p99. With 600 samples p99 is six data points and on a
## contended machine those six are OS scheduling stalls, not code: back-to-back
## runs gave p99 9.9 / 11.1 / 12.4 ms while the median held at 7.9-8.5 and p95
## at 9.4-10.2. The normalisation also inverts at the tail — the more loaded run
## normalised BETTER — so the calibration loop and the tick do not scale
## together there. p95 (30 samples) is the tightest statistic this machine can
## actually measure.
##
## Load-relative, not absolute: identical code measures 5.2 ms median on a quiet
## machine and 8.5 ms under load. Above MAX_CONTENTION the tail is the OS
## scheduler rather than the code, so the gate declines to judge.
const REFERENCE_CALIBRATION_MS := 14.97
const CALIBRATION_ITERS := 400000
const MAX_CONTENTION := 1.8

## The four-slot party, its autopilot and the worst-case builds, shared
## with tools/fps_probe.gd so the tick gate and the frame probe cannot
## drift onto different games. See tests/support/perf_fixture.gd.
var _fx := PerfFixture.new()

var run: Node2D
## Events the gated real run dropped, captured before its node is freed.
var _gate_drops: int = 0
## Whether the real run reached its pinned coverage — see the BASELINE_*
## constants below.
var _gate_covered := true

## Load statistics over the real run's ticks. Three, because they move in
## different directions: a lighter field lowers the enemy mean; a weaker or
## blind-aimed build lowers the hit and kill means while raising the enemy
## mean; a dead slot 0 lowers kills. A tick that does not step the world (an
## offer the fixture has not yet answered) leaves all three unchanged, so it
## dilutes every mean equally and a ratio pin is unaffected.
var _enemy_sum := 0.0
var _hit_sum := 0.0
var _cap_ticks := 0.0

## The fixture's end and load before the weapons pass, recorded so the gate
## cannot get lighter by dying sooner OR by surviving a thinner field: a
## baseline WIN requires a win; a baseline death at tick N requires surviving
## at least 90% of N (declared slack: the run is deterministic but chaotic);
## a baseline TIMEOUT (the 24000-tick cap, which is what this branch measured)
## requires the cap or a win; the live-enemy mean must reach 97% of the
## baseline's, and hits per tick and kills per tick 75% (they are chaotic;
## see the check). The run is seeded with no run-to-run variance, so the
## enemy band is not noise: it is the allowance for behavioural drift, kept
## below the gate's p95 headroom.
## Order: pin from the pre-change run, pass the post-change fixture against
## it, only then move the constants — outcome upward only; each load baseline
## upward, or downward with a written reason here. A fall below any floor
## needs a stated reason, never a re-pin. Both values stay in this comment so
## the delta is visible. If the gate comes back HEAVIER (blind-aimed pinned
## slots mean a fuller field), profile and optimise; never thin the fixture
## or lower the budget.
##
## Measured 2026-09-02, three points so fixture and game changes are
## attributed separately:
##   old fixture, pre-pass tree: "died at 400s" — the old loop ran while ANY
##     slot was LIVE, so this was the 24000 cap with slot 0's fate unknown;
##     p95 9.571 ms.
##   new fixture, pre-pass tree (the pin's baseline): died at tick 10908
##     (182 s), mean live enemies 252.4, mean hits/tick 3.90, kills/tick
##     0.293, at cap 3% of ticks. The OLD always-moving kite under the same
##     slot-0 loop also died there (tick 10461 with the centre offsets, tick
##     20700 with the old corner offsets — which is what the shipped fixture
##     was actually measuring), so the pre-pass "timeout" was three immortal
##     teammates propping up a dead slot 0, not a kite that survived; the
##     hysteresis kite is not what changed the outcome.
##   new fixture, post-pass tree: timeout at tick 24000 (400 s), mean live
##     enemies 286.0, mean hits/tick 2.70, kills/tick 0.240, at cap 11%.
## The outcome moved UP (died -> the cap) and the enemy mean up, so those
## were pinned at the post-pass figures. The hit and kill means were pinned
## BELOW the pre-pass figures, with the reason the rule demands: the
## pre-pass means cover a run truncated at tick 10908, a different span, and
## the pass moved packet, beam and spike onto facing, so the three pinned
## slots' forward rows fire blind by design (a rotating record sweeps them)
## and land fewer hits per tick than the old auto-aimed packets did.
##
## Re-pinned 2026-09-02 with the corruption-zone flip budget (6 flips, 40 s
## recharge). With the budget the old kite died at tick 15552 in subnet 1:
## it had been farming zone flips for botnet allies. The kite gained
## threat-aware fleeing (_threats: telegraphed dashes, surfacing ambushers,
## near shots) and a gap finder when surrounded (_gap), and the CLEARED walk
## now goes to the gate mouth first with the party riding on slot 0 through
## the corridor (it used to idle 5400 ticks against the arena edge). The
## tuned fixture on the tree BEFORE the budget: died at tick 17218, mean
## live enemies 404.7, mean hits/tick 1.82, kills/tick 0.306 — a run
## truncated in its densest phase. On this tree: timeout at 24000, mean live
## enemies 333.1, mean hits/tick 1.24, kills/tick 0.276, at cap 11%. The
## load floors sit BELOW that baseline with this reason: the baseline's
## means cover only its first 17218 ticks, and the budget removed the botnet
## allies that landed a large share of the hits and kills — a balance change
## the game wanted, not a lighter tick.
##
## Re-pinned 2026-09-02 with FIVE exploit rows and the board HP axis
## (SpawnDirector.HP_ROWS 1.40). Five rows alone thinned the field to 308.6
## enemies / 1.01 hits / 0.289 kills per tick — the party out-fired the
## spawns — so enemy integrity was retuned by the gate: 1.25 gave 316.5 /
## 1.16 / 0.238, 1.40 gives 353.0 / 3.42 / 0.235 at the cap, 1.55 killed the
## autopilot at tick 23481. The enemy and hit floors moved UP. The kill floor
## moves DOWN with this reason: tougher enemies die slower, while damage
## throughput (kills x integrity, 0.235 x 1.40 = 0.33 against 0.276) rose —
## a fuller field is heavier coverage, not lighter.
##
## Re-measured after the one-flow-rebuild-per-tick change (a few ticks of
## boss pathing re-roll the whole run): timeout at 24000, mean live enemies
## 352.7, mean hits/tick 2.53, kills/tick 0.211, at cap 19%. The hit and
## kill bands widened to 25% at the same time (see the check below); the
## enemy band stays at 3%.
##
## Re-pinned 2026-09-02 with the first-subnet difficulty retune. Five levers
## moved at once, all of them the game's balance rather than this gate's
## workload: the four overlapping wave rows cut (peak concurrent solo spawn
## rate 9.4 -> 6.6/s, 1690 -> 1288 spawns a subnet), `HP_ROWS` 1.40 -> 1.15,
## `PlayerStats.BASE` integrity 100 -> 128 with defense 0 -> 15 and pickup
## radius 30 -> 80, `MINIBOSS_TIMES` opened at 80 s instead of 60, and ICE
## 700 -> 550 integrity. Measured on this tree: DIED at tick 21957 (366 s),
## mean live enemies 304.1, mean hits/tick 1.65, kills/tick 0.241, at cap 5%.
##
## Every floor moves DOWN, with the reason the rule demands. The field is
## thinner BY DESIGN — thinning it was the point, and a solo player met 9.4
## spawns a second against a board that clears a handful. The outcome moves
## from the 24000 cap to a death at 21957 for the opposite reason: the party
## now clears subnet 01 fast enough to spend most of the run in subnet 02,
## where `HP_PER_SUBNET` 1.55 compounds, so the fixture dies further into the
## CAMPAIGN than it used to get. It is not a lighter game measured as a
## faster one: p95 8.439 ms against the 9.833 ms scaled budget on the same
## machine, and the stress block above is unchanged by any of this.
##
## Re-pinned 2026-09-03 with the packet weapon's closest-enemy retarget
## (run.gd's _emit_vector PACKET case: it now picks the nearest live enemy
## at fire time instead of firing along the owner's facing — the change the
## game wanted, so a new player's first shots land instead of sailing past
## whatever they happened to be moving away from). This is the packet-based
## fire path every slot in this fixture uses: slot 0's forward packet row,
## and each pinned slot's rotating-facing forward row (the fused homers'
## own aim is unaffected — they already targeted before this change).
##
## Measured on this tree: TIMEOUT at tick 24000 (400s) — up from a death at
## 21957 — mean live enemies 264.5, mean hits/tick 1.94, kills/tick 0.257.
## The outcome moved UP (died -> the full timeout): a packet that lands
## kills more of what it fires at, so the party survives the run instead of
## going down partway through subnet 02's HP-scaled field. Both rate floors
## moved UP with it (hits 1.65 -> 1.94, kills/tick 0.241 -> 0.257). Only the
## enemy-mean floor moves DOWN, with the reason the rule demands: a party
## that kills more of what it hits keeps fewer enemies on screen at once —
## the field is thinner because the party is winning it faster, the same
## "out-fired the spawns" shape the five-exploit-row and corruption-budget
## re-pins above already established, not a lighter tick.
##
## Re-pinned 2026-09-04 with the fixture raised from THREE exploit rows to
## FIVE — the shipped `Loadout.MAX_EXPLOITS`. The three-row fixture was
## deliberate once: the pin was set when MAX_EXPLOITS was 3, and the stress
## block's comment kept it at 3 so the pin would hold. MAX_EXPLOITS became 5
## and nobody moved the fixture, so for as long as five rows have shipped,
## both perf instruments have measured a build two rows short of the game —
## and the gate cannot see a regression in a row it never fires. Measured
## with tools/fps_probe.gd on the same party at fullscreen: three rows
## median 9.18 ms per FRAME with 3% of frames over 16.67, five rows 12.35 ms
## and 26% over. The added rows are chain (CHAIN: chain_count + 1 target
## selections per fire) and mirror (ORBIT: orbiters maintained every tick),
## the two heavy paths the other three rows leave untouched.
##
## Measured on this tree: TIMEOUT at tick 24000 (400s) — unchanged — mean
## live enemies 264.5 -> 252.2, mean hits/tick 1.94 -> 2.50, kills/tick
## 0.257 -> 0.273.
##
## Both RATE floors move UP, and hits/tick by 29%: two more rows firing is
## straightforwardly more work per tick, which is the whole reason to pin
## them. The enemy-mean floor moves DOWN 5%, with the reason the rule
## demands, and it is the same shape as the two re-pins above: a party
## carrying five maxed rows kills what it meets faster, so fewer enemies are
## alive at any instant. The field is thinner because the party is winning
## it harder — the tick is doing MORE work on FEWER live entities, which the
## hit and kill floors are exactly what record. A gate that refused this
## re-pin would be demanding the fixture stay weaker than the game.
##
## A "timeout" pin needs no death-tick slack: covered requires only that the
## outcome stay off "died" (see the covered branch below), so a future
## change is free to reach TIMEOUT by a different tick, or WIN outright,
## without re-pinning on tick alone — the enemy/hit/kill floors are what
## actually gate a lighter run.
const BASELINE_OUTCOME := "timeout"   # "won", "died" or "timeout"
const BASELINE_END_TICK := 24000
const BASELINE_MEAN_ENEMIES := 252.2
const BASELINE_MEAN_HITS := 2.50
const BASELINE_KILLS_PER_TICK := 0.273


func _initialize() -> void:
	SaveGame.use_test_paths()
	run = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame

	run.input_override = Vector2.ZERO
	run.director.elapsed = 999.0          # hold the field at cap manually
	run.director.boss_spawned = true

	# Worst-case loadout: packet (full-grid _pick_target), broadcast (aura over
	# the enemy cap), and a HOMING fused vector, all at max rank.
	#
	# The third row is a fused module rather than `chain` on purpose. Homing
	# steers per live projectile per tick and re-acquires when a bound target
	# dies, and homing exists ONLY on fused modules — with an ordinary loadout
	# `resolved[ei].homing > 0.0` is false for every projectile the gate
	# simulates, the whole steering path executes zero times, and the gate can
	# only ever pass. A gate that cannot fail is not evidence.
	#
	# This SWAPS chain out rather than adding a row (MAX_EXPLOITS was 3 when the
	# fixture was pinned; its three rows stay so the pin holds):
	# a fourth pass through _emit_vector would move the figure whether or not
	# homing costs anything, and the point is attribution.
	var t := ModuleTable.by_id()
	run.loadouts[run.local_slot].exploits[0].vector.rank = 5
	var ex2 := Exploit.new()
	ex2.place(t[&"broadcast"])
	ex2.place(t[&"on_hit"])
	ex2.vector.rank = 5
	run.loadouts[run.local_slot].exploits.append(ex2)

	var homer := Module.make(&"perf_homer", "perf_homer()", Module.Slot.VECTOR,
		{&"damage": 20.0, &"projectile_speed": 700.0, &"cooldown": 0.45,
		 &"travel": 1200.0, &"pierce": 4.0, &"homing": 2.6}, [],
		Module.VectorKind.PACKET, Module.TriggerKind.INTERVAL)
	homer.is_fused = true
	homer.targeting = Module.Targeting.STRONGEST
	var ex3 := Exploit.new()
	ex3.vector = EquippedModule.new(homer, 5)
	run.loadouts[run.local_slot].exploits.append(ex3)
	run._recompile()

	_fill()
	print("ROOTKIT — milestone 0 perf gate (real tick)")
	print("  %d enemies, %d projectiles, %d shards, %d botnet" % [
		run.enemies.count, run.projectiles.count, run.shards.count, run.botnet.count])
	print("  arena %.0fx%.0f, %.0f px cells, %d exploits" % [
		run.ARENA_SIZE.x, run.ARENA_SIZE.y, run.CELL,
		run._slot_exploits(run.local_slot).size()])

	var cal := _calibrate()
	var scale: float = cal / REFERENCE_CALIBRATION_MS
	var budget: float = BUDGET_MS * scale
	print("  calibration %.3f ms -> machine is %.2fx; scaled budget %.3f ms" % [
		cal, scale, budget])
	print("")

	for w in WARMUP:
		_fill()
		run._physics_process(DT)
		run._update_renderers()

	var samples := PackedFloat64Array()
	samples.resize(TICKS)
	for i in TICKS:
		_fill()                            # top up so every sample is at cap
		var t0 := Time.get_ticks_usec()
		run._physics_process(DT)
		# Measured WITH the render pass. It used to run inside _physics_process;
		# it now runs in _process, and a gate that stopped timing it would report
		# a free improvement for work that merely moved.
		run._update_renderers()
		samples[i] = float(Time.get_ticks_usec() - t0) / 1000.0

	print("  STRESS (all pools at simultaneous cap — a load real play never reaches):")
	_report(samples, budget, scale)
	if run.queue.dropped > 0:
		print("  FAIL — the event queue dropped %d events at cap; determinism needs zero."
			% run.queue.dropped)
		quit(1)
		return

	# The gate itself: a real winning run, which is the load that actually exists.
	print("")
	print("  GATE (a full run, autopiloted, four slots at the full leash):")
	var live := await _real_run()
	var p95 := _pct(live, 0.95)
	print("    mean   %7.3f ms" % _mean(live))
	print("    p95    %7.3f ms  <- gated" % p95)
	print("    worst  %7.3f ms" % _pct(live, 1.0))
	print("    normalised p95: %.3f ms" % (p95 / scale))
	print("")
	if _gate_drops > 0:
		print("  FAIL — the real run dropped %d events; determinism needs zero." % _gate_drops)
		quit(1)
	# Coverage before contention: a loaded machine must not turn a coverage
	# regression into PASS-by-INCONCLUSIVE. An unpinned baseline is refused
	# too, so the pin cannot be vacuous by omission.
	elif BASELINE_MEAN_ENEMIES <= 0.0 or BASELINE_MEAN_HITS <= 0.0 \
			or BASELINE_KILLS_PER_TICK <= 0.0 or BASELINE_END_TICK <= 0:
		print("  FAIL — the coverage baseline is not pinned; run the gate on the pre-change tree and record it.")
		quit(1)
	elif not _gate_covered:
		print("  FAIL — the fixture measured less than its baseline (%s at %d, mean enemies %.1f, mean hits %.2f, kills/tick %.3f): a coverage regression, not a speedup." % [
			BASELINE_OUTCOME, BASELINE_END_TICK, BASELINE_MEAN_ENEMIES, BASELINE_MEAN_HITS, BASELINE_KILLS_PER_TICK])
		quit(1)
	elif scale > MAX_CONTENTION:
		print("  INCONCLUSIVE — machine %.2fx the reference, too contended." % scale)
		quit(0)
	elif p95 <= budget:
		print("  PASS — real-run p95 %.3f ms within the %.3f ms scaled budget." % [p95, budget])
		print("  GDScript holds. No C# port needed.")
		quit(0)
	else:
		print("  FAIL — real-run p95 %.3f ms exceeds %.3f ms." % [p95, budget])
		print("  Escape hatch: port grid.gd and population.gd to C#.")
		quit(1)



## Plays an actual subnet with a four-slot party and returns its per-tick times.
## The stress block above measures a ceiling; this measures the game. Review
## rightly killed the previous gate for modelling a lighter tick than shipped —
## the correction is to measure the real one, not to invent a heavier one.
func _real_run() -> PackedFloat64Array:
	var g: Node2D = await _fx.party_run(self)
	_fx.equip_party(g)
	_fx.reset()
	_enemy_sum = 0.0
	_hit_sum = 0.0
	_cap_ticks = 0.0
	g.level_up_offered.connect(func(c): g.choose_card(c[0][0], Loadout.best_target(c[0][1])))
	# Without a handler _block_payout refuses to offer a fusion at all (it
	# would pause with nobody to unpause it); with one, an autopiloted run
	# actually exercises a fused row.
	g.fusion_offered.connect(func(_m): g.choose_fusion(0))
	var out := PackedFloat64Array()
	var t := 0
	# The loop ends on SLOT 0: `alive` is true while any slot is LIVE, and the
	# pinned slots are force-LIVE below, so a dead kite would otherwise be
	# propped up by three immortal teammates for the rest of the run.
	while t < 24000 and g.slot_state[0] == g.SlotState.LIVE and not g.won:
		_fx.drive(g, t)
		var t0 := Time.get_ticks_usec()
		g._physics_process(DT)
		# The periodic checksum is part of the tick's cost in a session, so it
		# is timed here on the same cadence a peer reports it.
		if t % SessionRules.CHECKSUM_INTERVAL == 0:
			g._state_hash()
		g._update_renderers()      # see the stress loop — moved, not removed
		out.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		_enemy_sum += float(g.enemies.count)
		_hit_sum += float(g.queue.drained_events)   # hit events drained this tick
		if g.enemies.count >= g.MAX_ENEMIES:
			_cap_ticks += 1.0
		t += 1
	var outcome := "won" if g.won else ("died" if g.slot_state[0] != g.SlotState.LIVE else "timeout")
	var ticks := maxf(float(t), 1.0)
	var mean_enemies := _enemy_sum / ticks
	var mean_hits := _hit_sum / ticks
	var total_kills := 0
	for s in SessionRules.MAX_PLAYERS:
		total_kills += g.kills[s]
	var kills_per_tick := float(total_kills) / ticks
	print("    %s at tick %d (%.0fs), mean live enemies %.1f, mean hits/tick %.2f, kills/tick %.3f, at cap %.0f%% of ticks" % [
		outcome, t, t * DT, mean_enemies, mean_hits, kills_per_tick, 100.0 * _cap_ticks / ticks])
	var covered := true
	if BASELINE_OUTCOME == "won":
		covered = outcome == "won"
	elif BASELINE_OUTCOME == "died":
		covered = outcome != "died" or t >= int(float(BASELINE_END_TICK) * 0.9)
	elif BASELINE_OUTCOME == "timeout":
		covered = outcome != "died"
	# The enemy mean holds a 3% band; hits and kills hold 25%. Measured: those
	# two swing by a third between runs that differ only in a few ticks of
	# boss pathing (hits 1.16 -> 3.42 -> 2.53 across three such runs), so a
	# 3% band there would trip on every sim change and force a re-pin, which
	# is the opposite of a pin. The field mean and the outcome are the load.
	if mean_enemies < BASELINE_MEAN_ENEMIES * 0.97 or mean_hits < BASELINE_MEAN_HITS * 0.75 \
			or kills_per_tick < BASELINE_KILLS_PER_TICK * 0.75:
		covered = false
	_gate_covered = covered
	# Determinism, not speed: an event queue that overflowed at cap dropped work
	# one peer would keep, so the gate refuses a run that dropped anything.
	_gate_drops = g.queue.dropped
	g.queue_free()
	return out




func _mean(s: PackedFloat64Array) -> float:
	var m := 0.0
	for x in s: m += x
	return m / s.size()

## Refill to cap. Measuring a tick whose pools have drained measures a lighter
## game than the one that ships.
func _fill() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242 + run.enemies.count
	while run.enemies.count < run.MAX_ENEMIES:
		var a := rng.randf() * TAU
		var d := rng.randf_range(60.0, 620.0)
		run.enemies.spawn(run.player_pos[run.local_slot] + Vector2(cos(a), sin(a)) * d,
			Vector2.ZERO, 999999.0, run.ENEMY_RADIUS, rng.randi_range(0, 2))
	while run.projectiles.count < run.MAX_PROJECTILES:
		var a2 := rng.randf() * TAU
		var pi: int = run.projectiles.spawn(run.player_pos[run.local_slot] + Vector2(cos(a2), sin(a2)) * 200.0,
			Vector2(cos(a2), sin(a2)) * 300.0, 1.0, run.PROJECTILE_RADIUS, 0)
		if pi >= 0:
			run._proj_owner[pi] = 0
			run._proj_pierce[pi] = 9999
			run._proj_last[pi] = -1
			# A resized PackedFloat32Array gives 0.0, which would expire every
			# stress projectile on its first integration pass and silently make
			# this gate measure a much lighter workload.
			run._proj_dist_left[pi] = 99999.0
	while run.shards.count < run.MAX_SHARDS:
		var a3 := rng.randf() * TAU
		run.shards.spawn(run.player_pos[run.local_slot] + Vector2(cos(a3), sin(a3)) * rng.randf_range(300.0, 900.0),
			Vector2.ZERO, 1.0, 4.0, 0)
	while run.botnet.count < run.MAX_BOTNET:
		var a4 := rng.randf() * TAU
		var bi: int = run.botnet.spawn(run.player_pos[run.local_slot] + Vector2(cos(a4), sin(a4)) * 150.0,
			Vector2.ZERO, 1.0, run.ENEMY_RADIUS, 0)
		if bi >= 0:
			run._botnet_ratio[bi] = 1.0
			run._botnet_life[bi] = 9999.0

func _calibrate() -> float:
	var a := Vector2(1.0, 2.0)
	var b := Vector2(3.0, 4.0)
	var acc := 0.0
	var t0 := Time.get_ticks_usec()
	for i in CALIBRATION_ITERS:
		acc += a.distance_squared_to(b)
		a.x += 0.000001
	if acc < 0.0:
		print("")
	return float(Time.get_ticks_usec() - t0) / 1000.0

func _pct(samples: PackedFloat64Array, q: float) -> float:
	var s := samples.duplicate()
	s.sort()
	return s[mini(int(s.size() * q), s.size() - 1)]

func _report(samples: PackedFloat64Array, budget: float, scale: float) -> void:
	var mean := 0.0
	for x in samples:
		mean += x
	mean /= samples.size()
	var p95 := _pct(samples, 0.95)
	print("  mean   %7.3f ms" % mean)
	print("  median %7.3f ms" % _pct(samples, 0.5))
	print("  p95    %7.3f ms  <- gated" % p95)
	print("  p99    %7.3f ms  (six samples; informational)" % _pct(samples, 0.99))
	print("  max    %7.3f ms" % _pct(samples, 1.0))
	print("  normalised p95: %.3f ms" % (p95 / scale))
	print("")
	if scale > MAX_CONTENTION:
		print("  INCONCLUSIVE — machine is %.2fx the reference, too contended to" % scale)
		print("  measure a tail. Re-run on a quiet machine.")
	else:
		print("    (informational; the gate is the real run below)")


