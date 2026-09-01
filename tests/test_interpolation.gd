extends SceneTree

## Render interpolation: the draw layer reads a point BETWEEN the last two
## simulated positions, never an extrapolated one.
##
## The whole feature is two facts held together — `prev_pos` is the position at
## the end of the previous tick, and every DISCONTINUOUS move resets it. The
## second is the one that breaks quietly: a recycled slot or a teleported
## straggler whose prev_pos was left behind draws a streak clean across the
## arena for exactly one frame, which is far too brief to catch by eye and
## perfectly visible as a wrong-looking flicker.
##
## Cases here assert positions, not that a particular function was called, so a
## later refactor that moves the reset elsewhere still passes.

const DT := 1.0 / 60.0
var failures := 0
var finished := {}

const CASES := ["a_snapshot_makes_this_tick_the_past",
	"a_recycled_slot_does_not_streak",
	"despawn_relocates_prev_pos",
	"a_reapproached_straggler_does_not_streak",
	"a_paused_run_renders_static",
	"a_running_tick_leaves_something_to_interpolate",
	"the_seam_between_ticks_is_continuous",
	"nothing_streaks_across_a_whole_run"]

## Largest per-tick displacement any entity may legitimately make. DERIVED:
## the fastest thing in the game is a packet at Compiler.MAX_PROJECTILE_SPEED
## (960 u/s = 16 u/tick); a charger's dash and a stack of knockback impulses
## both land under 30. The smallest DISCONTINUOUS move — _step9c_reapproach,
## spawn ring to recycle radius — is 400+. Three cells sits 4-6x above every
## real move and 4x below the smallest jump, so it cannot misfire either way.
const STREAK := 3.0 * 32.0
## Enough ticks that the run has fought, kited, and had stragglers recycled. A
## run that dies on tick 30 has proven nothing — the same lesson the perf gate
## learned when its kite walked into a wall.
const MIN_TICKS := 600
const MAX_TICKS := 3600

func _initialize() -> void:
	print("ROOTKIT — render interpolation\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	a_snapshot_makes_this_tick_the_past()
	a_recycled_slot_does_not_streak()
	despawn_relocates_prev_pos()
	await a_reapproached_straggler_does_not_streak()
	await a_paused_run_renders_static()
	await a_running_tick_leaves_something_to_interpolate()
	await the_seam_between_ticks_is_continuous()
	await nothing_streaks_across_a_whole_run()
	print("")
	for c in CASES:
		if not finished.has(c):
			print("  FAIL  case '%s' never finished — it aborted part way" % c)
			failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want or (got is float and want is float and abs(got - want) < 1e-4):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _bare_run() -> Node2D:
	SaveGame.use_fresh_state()
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(r)
	await process_frame
	r.input_override = Vector2.ZERO
	r.director.elapsed = 999.0
	r.director.boss_spawned = true
	while r.enemies.count > 0:
		r.enemies.despawn(r.enemies.count - 1)
	return r

## alpha 0 is where it was, alpha 1 is where it is. Nothing in between leaves
## the segment, which is what "never extrapolate" means in one assertion.
func a_snapshot_makes_this_tick_the_past() -> void:
	var p := Population.new(8)
	var i := p.spawn(Vector2(10, 10), Vector2.ZERO, 1.0, 4.0, 0)
	p.snapshot()
	p.pos[i] = Vector2(20, 30)
	_check("render at 0 is last tick", p.render_pos(i, 0.0), Vector2(10, 10))
	_check("render at 1 is this tick", p.render_pos(i, 1.0), Vector2(20, 30))
	_check("render at 0.5 is the midpoint", p.render_pos(i, 0.5), Vector2(15, 20))
	finished["a_snapshot_makes_this_tick_the_past"] = true

## The slot-reuse half of the invariant, at the render layer. A fresh entity
## inherits nothing from the corpse whose slot it took.
func a_recycled_slot_does_not_streak() -> void:
	var p := Population.new(8)
	var a := p.spawn(Vector2(-900, -900), Vector2.ZERO, 1.0, 4.0, 0)
	p.snapshot()
	p.pos[a] = Vector2(-880, -880)
	p.despawn(a)
	var b := p.spawn(Vector2(500, 500), Vector2.ZERO, 1.0, 4.0, 0)
	_check("recycled slot starts where it spawned", p.prev_pos[b], Vector2(500, 500))
	_check("recycled slot draws no streak", p.render_pos(b, 0.0), p.render_pos(b, 1.0))
	finished["a_recycled_slot_does_not_streak"] = true

## The swap-remove half. prev_pos must ride along with the tail entity or the
## survivor renders from the dead entity's history.
func despawn_relocates_prev_pos() -> void:
	var p := Population.new(8)
	p.spawn(Vector2(0, 0), Vector2.ZERO, 1.0, 4.0, 0)
	p.spawn(Vector2(100, 0), Vector2.ZERO, 1.0, 4.0, 0)
	var tail := p.spawn(Vector2(200, 0), Vector2.ZERO, 1.0, 4.0, 0)
	p.snapshot()
	p.pos[tail] = Vector2(200, 50)
	# Middle of the pool, so the tail is swapped down into slot 1.
	p.despawn(1)
	_check("relocated entity keeps its own past", p.prev_pos[1], Vector2(200, 0))
	_check("relocated entity keeps its own present", p.pos[1], Vector2(200, 50))
	finished["despawn_relocates_prev_pos"] = true

## _step9c_reapproach MOVES a straggler back to the spawn ring. It is the one
## discontinuous move in the tick, and the one that would streak the width of
## the arena.
func a_reapproached_straggler_does_not_streak() -> void:
	var r := await _bare_run()
	r.phase = r.Phase.FIGHTING
	var i: int = r.enemies.spawn(r.player_pos + Vector2(0, 40),
		Vector2.ZERO, 10.0, r.ENEMY_RADIUS, 0)
	r._spawn_enemy_state(i, 10.0)
	# Well past RECYCLE_RADIUS, so this tick's reapproach picks it up.
	r.enemies.pos[i] = r.player_pos + Vector2(r.RECYCLE_RADIUS + 400.0, 0.0)
	r.enemies.prev_pos[i] = r.enemies.pos[i]
	var before: Vector2 = r.enemies.pos[i]
	r._step9c_reapproach()
	var moved: bool = r.enemies.pos[i] != before
	_check("the straggler was actually moved", moved, true)
	_check("and its past moved with it", r.enemies.prev_pos[i], r.enemies.pos[i])
	r.queue_free()
	finished["a_reapproached_straggler_does_not_streak"] = true

## Paused, the fraction keeps cycling 0..1 because physics keeps ticking. If
## prev_pos still held the last moving tick's value, every entity would
## oscillate between two positions for the whole pause. Snapshotting ABOVE the
## guard is what makes prev == pos here.
func a_paused_run_renders_static() -> void:
	var r := await _bare_run()
	r.phase = r.Phase.FIGHTING
	r.input_override = Vector2(1, 0)
	var i: int = r.enemies.spawn(r.player_pos + Vector2(300, 0),
		Vector2.ZERO, 10.0, r.ENEMY_RADIUS, 0)
	r._spawn_enemy_state(i, 10.0)
	for n in 4:
		r._physics_process(DT)
	r.user_paused = true
	for n in 3:
		r._physics_process(DT)
	_check("paused: the enemy has no motion to interpolate",
		r.enemies.prev_pos[i], r.enemies.pos[i])
	_check("paused: the player has no motion to interpolate",
		r.player_prev_pos, r.player_pos)
	r.queue_free()
	finished["a_paused_run_renders_static"] = true

## The positive case: a running tick must leave the two states DIFFERENT, or
## the whole thing is an expensive way to render exactly what it rendered
## before.
func a_running_tick_leaves_something_to_interpolate() -> void:
	var r := await _bare_run()
	r.phase = r.Phase.FIGHTING
	r.input_override = Vector2(1, 0)
	r._physics_process(DT)
	r._physics_process(DT)
	var same: bool = r.player_prev_pos == r.player_pos
	_check("a moving player has two distinct states", same, false)
	_check("and the midpoint sits between them",
		r.player_prev_pos.lerp(r.player_pos, 0.5).distance_to(r.player_pos)
			< r.player_prev_pos.distance_to(r.player_pos), true)
	r.queue_free()
	finished["a_running_tick_leaves_something_to_interpolate"] = true

## The one assertion that MEANS "no judder". Frame fraction 1.0 of tick N and
## fraction 0.0 of tick N+1 are the same instant, so they must draw the same
## point. If they did not, the seam between ticks would show a step — which is
## exactly what extrapolating past the newest state produces.
func the_seam_between_ticks_is_continuous() -> void:
	var r := await _bare_run()
	r.phase = r.Phase.FIGHTING
	r.input_override = Vector2(1, 0)
	var i: int = r.enemies.spawn(r.player_pos + Vector2(400, 0),
		Vector2.ZERO, 10.0, r.ENEMY_RADIUS, 0)
	r._spawn_enemy_state(i, 10.0)
	r._physics_process(DT)
	r._physics_process(DT)
	var enemy_end: Vector2 = r.enemies.render_pos(i, 1.0)
	var player_end: Vector2 = r.player_prev_pos.lerp(r.player_pos, 1.0)
	r._physics_process(DT)
	_check("enemy: end of tick N == start of tick N+1",
		r.enemies.render_pos(i, 0.0), enemy_end)
	_check("player: end of tick N == start of tick N+1",
		r.player_prev_pos.lerp(r.player_pos, 0.0), player_end)
	r.queue_free()
	finished["the_seam_between_ticks_is_continuous"] = true

## The audit, as a runtime invariant over a real game. Every non-integrating
## write to `pos` was found by grep and routed through teleport(); this is the
## proof that the grep was complete, and it stays true for whoever adds the next
## warp. Autopiloted with the perf gate's kite, so the run fights at cap, moves
## far enough for stragglers to be recycled, and clears a gate.
func nothing_streaks_across_a_whole_run() -> void:
	SaveGame.use_fresh_state()
	var g: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(g)
	await process_frame
	g.level_up_offered.connect(func(c): g.choose_card(c[0][0], Loadout.best_target(c[0][1])))
	g.fusion_offered.connect(func(_m): g.choose_fusion(0))
	var pops := {"enemies": g.enemies, "projectiles": g.projectiles,
		"shards": g.shards, "botnet": g.botnet, "hostiles": g.hostiles}
	var limit := STREAK * STREAK
	var offences := 0
	var first := ""
	var t := 0
	while t < MAX_TICKS and g.alive and not g.won:
		g.input_override = _kite(g)
		g._physics_process(DT)
		if g.player_pos.distance_squared_to(g.player_prev_pos) > limit:
			offences += 1
			if first == "":
				first = "player moved %.0f on tick %d" % [
					g.player_pos.distance_to(g.player_prev_pos), t]
		for name in pops:
			var p: Population = pops[name]
			for i in p.count:
				if p.pos[i].distance_squared_to(p.prev_pos[i]) > limit:
					offences += 1
					if first == "":
						first = "%s[%d] type %d moved %.0f on tick %d" % [name, i,
							p.type_index[i], p.pos[i].distance_to(p.prev_pos[i]), t]
		t += 1
	var how := "won" if g.won else ("died" if not g.alive else "stopped")
	print("        %s at %.0fs" % [how, t * DT])
	_check("the run lasted long enough to mean something", t >= MIN_TICKS, true)
	_check("no entity moved more than %.0f in one tick%s" % [STREAK,
		"" if first == "" else " (first: " + first + ")"], offences, 0)
	g.queue_free()
	finished["nothing_streaks_across_a_whole_run"] = true

## The perf gate's autopilot, verbatim in spirit: flee what is close, drift to
## the arena centre, head for an open gate, and do not walk into rock.
func _kite(g: Node2D) -> Vector2:
	if g.phase == g.Phase.CLEARED:
		var gate = g.terrain.gate()
		if gate != null and gate.open:
			return _around_walls(g, (gate.end - g.player_pos).normalized())
	var flee := Vector2.ZERO
	var k := 0
	for i in g.enemies.count:
		var d: Vector2 = g.player_pos - g.enemies.pos[i]
		var dl := d.length()
		if dl < 190.0 and dl > 0.01:
			flee += d / dl * (190.0 - dl)
			k += 1
	var dir := flee.normalized() if k > 0 else Vector2.ZERO
	var c: Vector2 = g.terrain.arena().get_center() - g.player_pos
	if c.length() > 1100.0:
		dir = (dir + c.normalized() * 1.6).normalized()
	return _around_walls(g, dir)

func _around_walls(g: Node2D, dir: Vector2) -> Vector2:
	if dir.length_squared() < 0.000001:
		return dir
	var ahead: float = Terrain.CELL * 2.0
	if not g.terrain.is_solid(g.player_pos + dir * ahead):
		return dir
	var left := Vector2(-dir.y, dir.x)
	if not g.terrain.is_solid(g.player_pos + left * ahead):
		return left
	var right := -left
	if not g.terrain.is_solid(g.player_pos + right * ahead):
		return right
	return -dir
