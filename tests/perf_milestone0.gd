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
## requires the cap or a win; and the load means — live enemies, hits per
## tick and kills per tick — must each reach 97% of the baseline's. The run is
## seeded with no run-to-run variance, so 3% is not noise: it is the allowance
## for this pass's behavioural drift, kept below the gate's 5.4% p95 headroom.
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
## are pinned at the post-pass figures. The hit and kill means are pinned
## BELOW the pre-pass figures, with the reason the rule demands: the
## pre-pass means cover a run truncated at tick 10908, a different span, and
## the pass moved packet, beam and spike onto facing, so the three pinned
## slots' forward rows fire blind by design (a rotating record sweeps them)
## and land fewer hits per tick than the old auto-aimed packets did. That
## is the coverage this fixture now has; it is pinned so it cannot fall
## further unnoticed.
const BASELINE_OUTCOME := "timeout"   # "won", "died" or "timeout"
const BASELINE_END_TICK := 24000
const BASELINE_MEAN_ENEMIES := 286.0
const BASELINE_MEAN_HITS := 2.70
const BASELINE_KILLS_PER_TICK := 0.240

## The autopilot's hysteresis band and nudge cadence — see _kite. Measured
## on the pre-pass tree: a 120/190 band died at tick 10182 and 150/190 at
## 13518; on this tree 150/190 died at 15256 and 190/190 reaches the cap
## (with or without the dash flee; with it the hit mean is higher, 2.70
## against 1.95), so the band is 190/190: flee inside 190 as the old kite
## did, and HOLD facing with zero records once nothing is inside it.
var _kite_fleeing := false
var _kite_hold := 0
const KITE_FLEE_IN := 190.0
const KITE_FLEE_OUT := 190.0
const KITE_NUDGE_EVERY := 37
## A stationary kite is what a sentinel's dash and a probe's lead are aimed
## at, so a charger winding up or dashing inside KITE_DASH_RANGE also opens
## the flee state.
const KITE_DASH_FLEE := true
const KITE_DASH_RANGE := 300.0

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
	# MAX_EXPLOITS is 3, so this SWAPS chain out rather than adding a fourth row:
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

## The party the gate plays: four slots, three of them pinned at offsets from
## the autopiloted slot zero that hold the LIVE bounding box at the full 4000
## leash on both axes — the 7200 grid window, four flow fields rebuilding as
## the party crosses cells, four builds firing. This is the worst case the
## design leashes the party TO, so it is the load the budget is judged on.
## Slot 0 sits at the CENTRE of the box, so the leash lets it flee in every
## direction; the pinned offsets still span the full 4000 on both axes.
const PARTY_OFFSETS := [Vector2.ZERO, Vector2(2000.0, 2000.0),
	Vector2(-2000.0, 2000.0), Vector2(2000.0, -2000.0)]

## A run configured with a four-slot session, this process at slot zero.
func _party_run() -> Node2D:
	var rows := []
	for s in SessionRules.MAX_PLAYERS:
		rows.append({"slot": s, "name": "p%d" % s,
			"counters": SaveGame.session_counters()})
	var desc := NetworkSession.validate_descriptor({
		"protocol": SessionRules.PROTOCOL, "session_id": 1, "seed": 20260830,
		"delay": 0, "choice_timeout": 0, "roster": rows})
	var g: Node2D = load("res://scenes/run.tscn").instantiate()
	g.configure_session(NetworkSession.create(desc, 0, NetworkSession.Role.HOST))
	root.add_child(g)
	await process_frame
	return g

## Plays an actual subnet with a four-slot party and returns its per-tick times.
## The stress block above measures a ceiling; this measures the game. Review
## rightly killed the previous gate for modelling a lighter tick than shipped —
## the correction is to measure the real one, not to invent a heavier one.
func _real_run() -> PackedFloat64Array:
	var g: Node2D = await _party_run()
	# Every slot carries the worst-case loadout the stress block uses — packet,
	# broadcast aura and a homing fused vector, all maxed — so four builds' worth
	# of the heaviest fire paths run every tick.
	var tbl := ModuleTable.by_id()
	for s in SessionRules.MAX_PLAYERS:
		var lo: Loadout = g.loadouts[s]
		lo.exploits[0].vector.rank = 5
		var ex2 := Exploit.new()
		ex2.place(tbl[&"broadcast"])
		ex2.place(tbl[&"on_hit"])
		ex2.vector.rank = 5
		lo.exploits.append(ex2)
		var homer := Module.make(&"perf_homer", "perf_homer()", Module.Slot.VECTOR,
			{&"damage": 20.0, &"projectile_speed": 700.0, &"cooldown": 0.45,
			 &"travel": 1200.0, &"pierce": 4.0, &"homing": 2.6}, [],
			Module.VectorKind.PACKET, Module.TriggerKind.INTERVAL)
		homer.is_fused = true
		homer.targeting = Module.Targeting.STRONGEST
		var ex3 := Exploit.new()
		ex3.vector = EquippedModule.new(homer, 5)
		lo.exploits.append(ex3)
	# Slots 2 and 3 carry a rank-5 beam in place of the aura: the capsule
	# query and its pierce + 1 selection are the heaviest forward path, and
	# the rotating records below sweep it. The row inherits on_hit, which
	# keeps firing because the same slot's homer lands reliable hits. The
	# homers stay on every slot — the header argues they are what lets the
	# gate fail at all.
	for s in [2, 3]:
		var lo2: Loadout = g.loadouts[s]
		var exb := Exploit.new()
		exb.place(tbl[&"beam"])
		exb.place(tbl[&"on_hit"])
		exb.vector.rank = 5
		lo2.exploits[1] = exb          # the broadcast row; the homer on row 2 stays
	g._recompile()
	_kite_fleeing = false
	_kite_hold = 0
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
		g.input_override = _kite(g)
		# Hold the party at the full leash for the whole run, and keep the pinned
		# slots alive: a teammate that dies shrinks the window and lightens the
		# tick, and a gate that gets easier as the fixture takes damage is not
		# measuring the worst case it claims to.
		for s in range(1, SessionRules.MAX_PLAYERS):
			g.player_pos[s] = g.player_pos[0] + PARTY_OFFSETS[s]
			g.player_health[s] = g._eff_integrity(s)
			g.slot_state[s] = g.SlotState.LIVE
			# Lockstep waits on every LIVE slot's record; the pinned slots send
			# neutral movement — and answer any offer they hold with its first
			# option, or a level-up round would wait on them forever and the
			# gate would time a world that never steps.
			var c := Vector3i(-1, -1, -1)
			var open: Dictionary = g._offer_open[s]
			if not open.is_empty():
				c = Vector3i(0, 0, int(open["seq"]))
			# A slowly rotating unit vector, one turn per 600 ticks, so the
			# pinned slots' facing sweeps and their forward rows fire in every
			# direction. The drift it would cause is erased by the force-write
			# above; facing is set from the RECORD, not the realised step, so
			# the leash clamping the outward half is harmless. Side effects,
			# accepted: player_vel on these slots is non-zero (read by _flank
			# and _fire_hostile) and they take the movement branch inside the
			# timed region.
			var spin := TAU * float(t) / 600.0
			g.lockstep.submit(s, g.lockstep.executed, Vector2(cos(spin), sin(spin)), c.x, c.y, c.z)
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
	if mean_enemies < BASELINE_MEAN_ENEMIES * 0.97 or mean_hits < BASELINE_MEAN_HITS * 0.97 \
			or kills_per_tick < BASELINE_KILLS_PER_TICK * 0.97:
		covered = false
	_gate_covered = covered
	# Determinism, not speed: an event queue that overflowed at cap dropped work
	# one peer would keep, so the gate refuses a run that dropped anything.
	_gate_drops = g.queue.dropped
	g.queue_free()
	return out

## The autopilot. Facing is the last non-zero record, so a kite that only
## ever FLED would point every forward weapon away from the swarm, die early
## and shrink the gate — the trap the header names. So: hysteresis. Flee while
## the nearest enemy is inside KITE_FLEE_IN until it is back out past
## KITE_FLEE_OUT, then nudge one tick toward the swarm and HOLD facing with
## zero records, nudging again every KITE_NUDGE_EVERY ticks. Duty cycle:
## facing points at the swarm from each nudge until the next burst begins,
## and away for the burst itself (roughly two-fifths to two-thirds of each
## cycle at the swarm, against a tracer or a daemon respectively). Slot 0's
## survival rests on its aura and its homing row; the forward packet is drain
## coverage, which the load pin measures.
func _kite(g: Node2D) -> Vector2:
	# The CLEARED branch stays FIRST and unconditional: a cleared subnet has
	# nothing inside 120, and a kite that held there would never reach the
	# gate. Standing still in CLEARED would shrink the gate's coverage the same
	# way terrain-blindness already did once.
	if g.phase == g.Phase.CLEARED:
		var gate = g.terrain.gate()
		if gate != null and gate.open:
			return _around_walls(g, (gate.end - g.player_pos[g.local_slot]).normalized())
	var me: Vector2 = g.player_pos[g.local_slot]
	var nearest := -1
	var nd := INF
	for i in g.enemies.count:
		var d: float = me.distance_to(g.enemies.pos[i])
		if d < nd:
			nd = d; nearest = i
	# The flee sum over everything within KITE_FLEE_OUT; its negative is the
	# swarm's mass, which is where a nudge should face (the nearest single
	# enemy can be a straggler off to one side at cap).
	var flee := Vector2.ZERO
	var k := 0
	for i in g.enemies.count:
		var d: Vector2 = me - g.enemies.pos[i]
		var dl := d.length()
		if dl < KITE_FLEE_OUT and dl > 0.01:
			flee += d / dl * (KITE_FLEE_OUT - dl)
			k += 1
	if _kite_fleeing and nd > KITE_FLEE_OUT:
		_kite_fleeing = false
		_kite_hold = 0
		return _nudge(g, flee, k, nearest)
	if not _kite_fleeing and nd < KITE_FLEE_IN:
		_kite_fleeing = true
	if not _kite_fleeing and KITE_DASH_FLEE:
		for i in g.enemies.count:
			if g.enemy_types[g.enemies.type_index[i]].behaviour != EnemyTable.Behaviour.CHARGER:
				continue
			if g._ai_phase[i] != g.CH_WINDUP and g._ai_phase[i] != g.CH_DASH:
				continue
			if me.distance_to(g.enemies.pos[i]) < KITE_DASH_RANGE:
				_kite_fleeing = true
				break
	if _kite_fleeing:
		var dir := flee.normalized() if k > 0 else Vector2.ZERO
		# The CURRENT arena's centre, not the world origin: the campaign is
		# three arenas laid out end to end, and only the first is centred on
		# zero.
		var c: Vector2 = g.terrain.arena().get_center() - me
		if c.length() > 1100.0:
			dir = (dir + c.normalized() * 1.6).normalized()
		return _around_walls(g, dir)
	_kite_hold += 1
	if _kite_hold >= KITE_NUDGE_EVERY:
		_kite_hold = 0
		return _nudge(g, flee, k, nearest)
	return Vector2.ZERO

## One tick toward the swarm's mass (the negative flee sum), else toward the
## nearest enemy, else nothing. NOT through _around_walls: this is a facing
## intent, its step is rejected by terrain.slide against rock anyway, and a
## wall-deflected nudge would face away from the swarm.
func _nudge(g: Node2D, flee: Vector2, k: int, nearest: int) -> Vector2:
	if k > 0 and flee.length_squared() > 0.000001:
		return (-flee).normalized()
	if nearest < 0:
		return Vector2.ZERO
	return (g.enemies.pos[nearest] - g.player_pos[g.local_slot]).normalized()

## Terrain awareness, added when walls arrived.
##
## Without it this kite walks into rock and dies early, and the GATE SHRINKS
## WITH IT: measured at 43 s survived against the 317 s it used to reach, which
## dropped the reported p95 from 3.3 ms to 0.9 ms. That reads as a speedup and
## is nothing of the kind — it is the same architecture measured over a quarter
## of the load. A perf gate that gets easier whenever the game gets harder is
## not gating anything.
func _around_walls(g: Node2D, dir: Vector2) -> Vector2:
	if dir.length_squared() < 0.000001:
		return dir
	var ahead: float = Terrain.CELL * 2.0
	if not g.terrain.is_solid(g.player_pos[g.local_slot] + dir * ahead):
		return dir
	var left := Vector2(-dir.y, dir.x)
	if not g.terrain.is_solid(g.player_pos[g.local_slot] + left * ahead):
		return left
	var right := -left
	if not g.terrain.is_solid(g.player_pos[g.local_slot] + right * ahead):
		return right
	return -dir

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
