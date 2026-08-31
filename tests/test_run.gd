extends SceneTree

## Plays a whole CAMPAIGN headless, auto-picking cards, and asserts the run loop
## actually produces a game: enemies spawn, damage lands, levels happen, each
## subnet's boss arrives, the build survives the advance between subnets, and
## the tick never leaks entities.

const DT := 1.0 / 60.0
var failures := 0
var run: Node2D
var picks := 0

func _initialize() -> void:
	print("ROOTKIT — full subnet smoke test\n")
	SaveGame.use_fresh_state()
	var scene: PackedScene = load("res://scenes/run.tscn")
	run = scene.instantiate()
	root.add_child(run)
	# add_child during _initialize leaves the node outside the tree, so _ready
	# never fires. One frame brings the tree up.
	await process_frame
	run.level_up_offered.connect(_auto_pick)

	# Every subnet is 300 s of wave table plus however long ICE takes; 90 s of
	# boss margin each has been enough at every damage level tried so far.
	var per_subnet := int(SpawnDirector.SUBNET_SECONDS / DT) + 5400
	var ticks := per_subnet * SpawnDirector.CAMPAIGN_SUBNETS
	var t := 0
	var subnets_seen := 1
	var build_at_first_clear := ""
	while t < ticks and run.alive and not run.won:
		run.input_override = _autopilot()
		run._physics_process(DT)
		t += 1
		if run.subnet > subnets_seen:
			# Sampled the tick the advance lands, so the comparison below is
			# against the build as it stood when subnet 01 ended.
			if build_at_first_clear == "":
				build_at_first_clear = _build_signature()
			subnets_seen = run.subnet
	var mins := t * DT

	print("  simulated %.1f s (%d ticks)" % [mins, t])
	print("  spawned %d (campaign), dropped %d" % [run.spawned_total(), run.director.dropped])
	print("  reached subnet %d of %d" % [run.subnet, SpawnDirector.CAMPAIGN_SUBNETS])
	print("  kills %d  flips %d  level %d  salvage %d" % [
		run.kills, run.flips, run.level, run.salvage])
	print("  live: enemies %d  projectiles %d  shards %d  botnet %d" % [
		run.enemies.count, run.projectiles.count, run.shards.count, run.botnet.count])
	print("  card picks %d" % picks)
	print("  boss spawned: %s" % run.director.boss_spawned)
	print("  outcome: %s" % ("WON" if run.won else ("DIED" if not run.alive else "timeout")))
	print("")

	# A RATE, not a count. A raw threshold silently encodes "the autopilot
	# survived long enough to see 200 spawns", so it fails whenever the game gets
	# harder rather than whenever the spawner breaks. The wave table opens at
	# 1.8/s, so anything at or above 1.0/s means the director is producing.
	var spawn_rate := float(run.spawned_total()) / maxf(mins, 1.0)
	print("  spawn rate %.2f/s" % spawn_rate)
	_check("the director is producing spawns", spawn_rate >= 1.0, true)
	_check("damage landed (kills > 0)", run.kills > 0, true)
	_check("player levelled up", run.level > 1, true)
	_check("cards were offered", picks > 0, true)
	_check("enemy pool within cap", run.enemies.count <= run.MAX_ENEMIES, true)
	_check("projectile pool within cap", run.projectiles.count <= run.MAX_PROJECTILES, true)
	_check("shard pool within cap", run.shards.count <= run.MAX_SHARDS, true)
	_check("no flipped enemies left in the swarm", _flipped_left(), 0)
	# Deliberately NOT "the autopilot reached subnet 02". The autopilot is bad
	# play on purpose, and its outcome turned out to be chaotic against small
	# balance moves — a damage INCREASE once moved it from dying at 466 s to
	# dying at 148 s, because the level timings shifted and it drew a different
	# build. Anything asserted here that depends on how far it gets is a test
	# that fails on tuning rather than on breakage. The campaign's own semantics
	# are pinned deterministically in test_campaign.gd instead; what belongs
	# here is that the loop runs and stays within its bounds.
	_check("boss arrives once the wave table is spent",
		run.director.elapsed < SpawnDirector.SUBNET_SECONDS or run.director.boss_spawned,
		true)
	_check("run reached a terminal state", run.won or not run.alive, true)
	_check("a win means the last subnet was cleared",
		not run.won or run.subnet == SpawnDirector.CAMPAIGN_SUBNETS, true)
	# Only if the autopilot actually got there. test_campaign proves the advance
	# preserves the build without needing to survive a subnet to do it.
	if build_at_first_clear != "":
		_check("the build survived the subnet advance",
			_build_signature().begins_with(build_at_first_clear), true)

	print("")
	if failures == 0: print("  PASS — all checks")
	else: print("  FAIL — %d check(s)" % failures)
	quit(1 if failures > 0 else 0)

## Module ids in slot order, per exploit. A prefix comparison, so the build may
## GROW across the advance — it just may not be replaced or emptied.
func _build_signature() -> String:
	var parts := []
	for ex in run.loadout.exploits:
		for em in ex.equipped():
			parts.append(String(em.module.id))
	return "|".join(parts)

## Kite away from the swarm, drift toward loose shards. Not good play — just
## enough that the loop is exercised by a moving player rather than a corpse.
func _autopilot() -> Vector2:
	# In CLEARED there is nothing left to kite and nothing left to farm, so head
	# for the gate. Without this the autopilot stands in a cleared subnet until
	# the tick budget runs out and every campaign assertion times out rather
	# than failing — which reads as a hang, not as a result.
	if run.phase == run.Phase.CLEARED:
		var gate = run.terrain.gate()
		if gate != null and gate.open:
			return _around_walls((gate.end - run.player_pos).normalized())
	var flee := Vector2.ZERO
	var n := 0
	for i in run.enemies.count:
		var d: Vector2 = run.player_pos - run.enemies.pos[i]
		var dl := d.length()
		if dl < 190.0 and dl > 0.01:
			flee += d / dl * (190.0 - dl)
			n += 1
	var dir := flee.normalized() if n > 0 else Vector2.ZERO
	if n == 0 and run.shards.count > 0:
		dir = (run.shards.pos[0] - run.player_pos).normalized()
	# The CURRENT arena's centre, not the world origin: the campaign is three
	# arenas laid out end to end now, and only the first is centred on zero.
	var to_centre: Vector2 = run.terrain.arena().get_center() - run.player_pos
	if to_centre.length() > 1100.0:
		dir = (dir + to_centre.normalized() * 1.6).normalized()
	return _around_walls(dir)

## Terrain awareness, added when walls arrived. Without it this autopilot kites
## in a straight line into rock and gets pinned: measured at 34 s survived with
## walls against 149 s with density forced to zero, on identical code. That is a
## fact about a straight-line policy, not about the game — but it made the smoke
## test cover four times less of the run, which is the opposite of its job.
##
## Deliberately dumb: probe the intended heading, and if it is blocked take
## whichever perpendicular is clear. Enough not to walk into a wall; nowhere
## near enough to make this good play.
func _around_walls(dir: Vector2) -> Vector2:
	if dir.length_squared() < 0.000001:
		return dir
	var ahead: float = Terrain.CELL * 2.0
	if not run.terrain.is_solid(run.player_pos + dir * ahead):
		return dir
	var left := Vector2(-dir.y, dir.x)
	if not run.terrain.is_solid(run.player_pos + left * ahead):
		return left
	var right := -left
	if not run.terrain.is_solid(run.player_pos + right * ahead):
		return right
	return -dir

## A FLIPPED enemy must retire its slot at recycle. Freeing only DEAD leaves
## them in the swarm permanently, filling the 600-pool.
func _flipped_left() -> int:
	var n := 0
	for i in run.enemies.count:
		if run.enemies.state[i] != Population.ALIVE:
			n += 1
	return n

func _auto_pick(cards: Array) -> void:
	picks += 1
	run.choose_card(cards[0][0], Loadout.best_target(cards[0][1]))

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1
