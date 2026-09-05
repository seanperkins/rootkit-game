class_name PerfFixture extends RefCounted

## The four-slot party fixture and its autopilot, shared by the two perf
## instruments so they cannot drift apart:
##
##   tests/perf_milestone0.gd  times the TICK, headless, in its own loop.
##   tools/fps_probe.gd        times the FRAME, windowed, in the engine loop.
##
## They measure different halves of the same budget and must measure the same
## GAME. The kite, the pinned party and the worst-case builds lived only in
## the gate; fps_probe had a solo slot standing still inside a wall of 600
## immortal enemies it respawned every frame, which is not a load any player
## meets and not one the player can even walk through. Moving the fixture here
## is what makes the windowed number comparable to the gated one.
##
## Every heading this fixture generates goes through DetMath, not libm. All
## three sites land in hashed state: the two in drive() are the pinned slots'
## movement records, and _gap's is slot 0's own — kite() returns it and drive()
## assigns it to input_override. Single-binary runs cannot tell the difference,
## but this file is the shared fixture, and a harness that synthesises
## simulation inputs with libm is the shape of the bug the tick just had.
##
## NOT a suite. A support object, like MultiplayerHarness.

## The party the gate plays: four slots, three of them pinned at offsets from
## the autopiloted slot zero that hold the LIVE bounding box at the full 4000
## leash on both axes — the 7200 grid window, four flow fields rebuilding as
## the party crosses cells, four builds firing. This is the worst case the
## design leashes the party TO, so it is the load the budget is judged on.
## Slot 0 sits at the CENTRE of the box, so the leash lets it flee in every
## direction; the pinned offsets still span the full 4000 on both axes.
const PARTY_OFFSETS := [Vector2.ZERO, Vector2(2000.0, 2000.0),
	Vector2(-2000.0, 2000.0), Vector2(2000.0, -2000.0)]

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

## Reset between runs: the kite's hysteresis is stateful.
func reset() -> void:
	_kite_fleeing = false
	_kite_hold = 0
	_next.clear()

## slot -> the first tick not yet submitted for it. Only used when drive() is
## asked to run ahead; see the comment there.
var _next: Dictionary = {}

## A run configured with a four-slot session, this process at slot zero.
func party_run(tree: SceneTree) -> Node2D:
	var rows := []
	for s in SessionRules.MAX_PLAYERS:
		rows.append({"slot": s, "name": "p%d" % s,
			"counters": SaveGame.session_counters()})
	var desc := NetworkSession.validate_descriptor({
		"protocol": SessionRules.PROTOCOL, "session_id": 1, "seed": 20260830,
		"delay": 0, "choice_timeout": 0, "roster": rows})
	var g: Node2D = load("res://scenes/run.tscn").instantiate()
	g.configure_session(NetworkSession.create(desc, 0, NetworkSession.Role.HOST))
	tree.root.add_child(g)
	await tree.process_frame
	return g

## Every slot carries the worst-case loadout the stress block uses — packet,
## broadcast aura and a homing fused vector, all maxed — so four builds' worth
## of the heaviest fire paths run every tick.
func equip_party(g: Node2D) -> void:
	var tbl := ModuleTable.by_id()
	for s in SessionRules.MAX_PLAYERS:
		var lo: Loadout = g.loadouts[s]
		# Measure the equipped late-run party, not the now-bare starter.
		lo.exploits[0].place(tbl[&"interval"])
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
	# Rows four and five. The fixture stopped at THREE because the gate's
	# coverage pin was set when Loadout.MAX_EXPLOITS was 3, and the comment
	# there kept it at 3 so the pin would hold — which quietly left both perf
	# instruments measuring two rows short of the game for as long as
	# MAX_EXPLOITS has been 5. Measured with tools/fps_probe.gd at fullscreen
	# with this party: three rows median 9.18 ms/frame and 3% of frames over
	# 16.67, five rows 12.35 ms and 26% over. A gate blind to a third of the
	# shipped firing cost is not gating the game.
	#
	# CHAIN and ORBIT, because they are the two heavy paths the other three
	# rows leave untouched: chain re-selects a target per hop (chain_count + 1
	# selections per fire, consulting Targeting), and orbit maintains its
	# orbiters every tick rather than at the cadence. Both on interval, so the
	# load is steady and the gate stays deterministic — an event trigger would
	# make the measured tick depend on how the fight happened to go.
	for s in SessionRules.MAX_PLAYERS:
		var lo3: Loadout = g.loadouts[s]
		var exc := Exploit.new()
		exc.place(tbl[&"chain"])
		exc.place(tbl[&"interval"])
		exc.vector.rank = 5
		lo3.exploits.append(exc)
		var exo := Exploit.new()
		exo.place(tbl[&"mirror"])
		exo.place(tbl[&"interval"])
		exo.vector.rank = 5
		lo3.exploits.append(exo)
		assert(lo3.exploits.size() == Loadout.MAX_EXPLOITS,
			"the fixture must fill every shipped row, not the row count of an older build")
	g._recompile()

## One tick's worth of driving: steer slot 0, hold slots 1-3 at the full leash
## and alive, and submit their records. `lead` covers ticks ahead of the ring
## for callers the engine ticks (see inside); 0 is the gate's own loop.
func drive(g: Node2D, t: int, lead: int = 0) -> void:
	g.input_override = kite(g)
	# Hold the party at the full leash for the whole run, and keep the pinned
	# slots alive: a teammate that dies shrinks the window and lightens the
	# tick, and a gate that gets easier as the fixture takes damage is not
	# measuring the worst case it claims to.
	# Through a gate the party RIDES on slot 0: the advance needs every
	# LIVE slot past the corridor's end plane, and a slot pinned 2000
	# units off never gets there. The offsets return with the next fight.
	var walking: bool = g.phase == g.Phase.CLEARED and g.terrain.gate() != null and g.terrain.gate().open
	for s in range(1, SessionRules.MAX_PLAYERS):
		g.player_pos[s] = g.player_pos[0] + (Vector2.ZERO if walking else PARTY_OFFSETS[s])
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
		if lead <= 0:
			g.lockstep.submit(s, g.lockstep.executed, DetMath.unit(spin), c.x, c.y, c.z)
		else:
			# Windowed callers tick from the ENGINE, not from their own loop, so
			# a dropped frame runs _physics_process twice between two drive()
			# calls. A slot with no record for that second tick stalls the ring,
			# the world steps at half rate, and the probe reports a frame time
			# for a world that barely moved — the exact artefact it exists to
			# measure. So cover a few ticks ahead, each tick once: re-submitting
			# an already-stored tick is dropped, which would strand an offer
			# answer forever.
			var from: int = maxi(int(_next.get(s, 0)), g.lockstep.executed)
			for tick in range(from, g.lockstep.executed + lead + 1):
				g.lockstep.submit(s, tick, DetMath.unit(spin), c.x, c.y, c.z)
			_next[s] = g.lockstep.executed + lead + 1

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
func kite(g: Node2D) -> Vector2:
	# The CLEARED branch stays FIRST and unconditional: a cleared subnet has
	# nothing inside 120, and a kite that held there would never reach the
	# gate. Standing still in CLEARED would shrink the gate's coverage the same
	# way terrain-blindness already did once.
	if g.phase == g.Phase.CLEARED:
		var gate = g.terrain.gate()
		if gate != null and gate.open:
			# The mouth first, then the far end: a straight line to the end
			# from anywhere but the mouth's row runs into the arena's edge and
			# oscillates there (measured: 5400 idle ticks in subnet 1).
			var here: Vector2 = g.player_pos[g.local_slot]
			var target: Vector2 = gate.end
			if (here - gate.pos).dot(gate.dir) < 0.0 and here.distance_to(gate.pos) > Terrain.GATE_RADIUS * 0.5:
				target = gate.pos
			return _around_walls(g, (target - here).normalized())
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
	# Telegraphed danger a distance test misses opens the flee state too, and
	# steers it; surrounded (the flee sum cancels), the kite takes the widest
	# gap instead of standing in a cancelled sum.
	var threat := _threats(g, me)
	if not _kite_fleeing and threat.length_squared() > 0.0:
		_kite_fleeing = true
	if _kite_fleeing:
		var dir := (flee + threat).normalized() if (k > 0 or threat.length_squared() > 0.0) else Vector2.ZERO
		if k >= 10 and flee.length() < 0.3 * float(k) * KITE_FLEE_OUT * 0.5:
			dir = _gap(g, me)
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

## Extra flee pressure from telegraphed danger a distance test misses: a
## charger winding up or dashing, an ambusher surfacing, an enemy shot near.
## Measured: without this the kite died at tick 15552 in subnet 1 to rootkits
## surfacing on it and sentinel dashes; with it the run reaches the cap.
func _threats(g: Node2D, me: Vector2) -> Vector2:
	var v := Vector2.ZERO
	for i in g.enemies.count:
		var bh: int = g.enemy_types[g.enemies.type_index[i]].behaviour
		var d: Vector2 = me - g.enemies.pos[i]
		var dl := d.length()
		if dl < 0.01:
			continue
		if bh == EnemyTable.Behaviour.CHARGER and (g._ai_phase[i] == g.CH_WINDUP or g._ai_phase[i] == g.CH_DASH) and dl < 320.0:
			v += d / dl * 400.0
		elif bh == EnemyTable.Behaviour.AMBUSHER and g._ai_phase[i] == g.AM_SURFACING and dl < 220.0:
			v += d / dl * 400.0
	for i in g.hostiles.count:
		var d: Vector2 = me - g.hostiles.pos[i]
		var dl := d.length()
		if dl < 140.0 and dl > 0.01:
			v += d / dl * 150.0
	return v

## The least crowded of sixteen headings, weighted by how close each enemy
## within 300 sits along it; rock two cells out rules a heading out.
func _gap(g: Node2D, me: Vector2) -> Vector2:
	var best := Vector2.ZERO
	var best_score := INF
	for h in 16:
		var a := TAU * float(h) / 16.0
		var dir := DetMath.unit(a)
		var score := 0.0
		for i in g.enemies.count:
			var d: Vector2 = g.enemies.pos[i] - me
			var dl := d.length()
			if dl > 300.0 or dl < 0.01:
				continue
			score += maxf(0.0, d.dot(dir) / dl) * (300.0 - dl)
		if g.terrain.is_solid(me + dir * Terrain.CELL * 2.0):
			score += 10000.0
		if score < best_score:
			best_score = score
			best = dir
	return best
