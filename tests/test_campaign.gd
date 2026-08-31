extends SceneTree

## The campaign loop: a run is three subnets, and what survives the advance
## between them. Deterministic on purpose — it drives the transitions directly
## rather than playing well enough to reach them, so the win path stays covered
## whatever the damage numbers are tuned to next.

var failures := 0
var finished := {}

## Every case marks itself on its last line. A runtime error aborts only its own
## function, so without this a suite whose asserts never ran still exits 0 — as
## this one did when it kept a reference to a deleted field.
const CASES := [
	"hp_ramp_shape", "threshold_steps_per_subnet_only",
	"advance_preserves_the_build", "advance_clears_the_field",
	"banking_is_incremental", "last_subnet_wins",
]

func _initialize() -> void:
	print("ROOTKIT — campaign loop\n")
	hp_ramp_shape()
	threshold_steps_per_subnet_only()
	await advance_preserves_the_build()
	await advance_clears_the_field()
	await banking_is_incremental()
	await last_subnet_wins()
	print("")
	for c in CASES:
		if not finished.has(c):
			print("  FAIL  case '%s' never finished — it aborted part way" % c)
			failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _fresh_run() -> Node2D:
	SaveGame.use_fresh_state()
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(r)
	await process_frame
	return r

## Both axes multiply, and neither may ever reduce an enemy below its table HP —
## a mult under 1.0 would make subnet 01 EASIER than the numbers in enemy_table.
func hp_ramp_shape() -> void:
	_check("subnet 1 opens at exactly the table value",
		SpawnDirector.hp_mult(1, 0.0), 1.0)
	_check("subnet 1 ends at the within-subnet cap",
		is_equal_approx(SpawnDirector.hp_mult(1, SpawnDirector.SUBNET_SECONDS),
			1.0 + SpawnDirector.HP_OVER_SUBNET), true)
	_check("a later subnet opens above an earlier one's close",
		SpawnDirector.hp_mult(3, 0.0) > SpawnDirector.hp_mult(2, 0.0), true)
	_check("elapsed past the subnet length does not keep climbing",
		SpawnDirector.hp_mult(2, 9999.0),
		SpawnDirector.hp_mult(2, SpawnDirector.SUBNET_SECONDS))
	for sn in [0, 1]:
		_check("subnet %d never scales below the table" % sn,
			SpawnDirector.hp_mult(sn, 0.0), 1.0)

	finished["hp_ramp_shape"] = true
## Thresholds are held per TYPE in one array every live enemy reads, so they may
## step per subnet but must NOT drift with elapsed — that would move the target
## under an enemy already part-corrupted.
func threshold_steps_per_subnet_only() -> void:
	_check("subnet 1 thresholds are the table values",
		SpawnDirector.threshold_mult(1), 1.0)
	_check("subnet 2 steps up", SpawnDirector.threshold_mult(2) > 1.0, true)
	_check("the step matches the HP step per subnet",
		SpawnDirector.threshold_mult(2), SpawnDirector.hp_mult(2, 0.0))

	finished["threshold_steps_per_subnet_only"] = true
func advance_preserves_the_build() -> void:
	var r := await _fresh_run()
	r.loadout.place_at(ModuleTable.by_id()[&"corrupt"], 0, 2)
	r._recompile()
	r.level = 7
	r.xp = 3
	var before: int = r.loadout.exploits[0].equipped().size()
	r._advance_subnet()
	_check("subnet incremented", r.subnet, 2)
	_check("the loadout came with it", r.loadout.exploits[0].equipped().size(), before)
	_check("corrupt is still slotted",
		r.loadout.exploits[0].payloads[0].module.id, &"corrupt")
	_check("level carried", r.level, 7)
	_check("xp carried", r.xp, 3)
	_check("thresholds rescaled with the subnet",
		is_equal_approx(r.thresholds[0],
			EnemyTable.all()[0].corruption_threshold * SpawnDirector.threshold_mult(2)), true)
	r.free()

	finished["advance_preserves_the_build"] = true
## The clear-down and the heal moved to GATE ENTRY when gates arrived: the
## advance itself is now only the arena swap, so asserting them against a bare
## _advance_subnet() call would be testing the wrong half of the transition.
func advance_clears_the_field() -> void:
	var r := await _fresh_run()
	for i in 20:
		r.enemies.spawn(Vector2(i * 30, 0), Vector2.ZERO, 10.0, 12.0, 0)
	r.director.elapsed = 120.0
	r.director.boss_spawned = true
	var maxhp: float = r._eff_integrity()
	r.player_health = maxhp * 0.25

	_walk_the_gate(r)
	_check("live enemies cleared", r.enemies.count, 0)
	_check("the clock restarted", r.director.elapsed, 0.0)
	_check("the boss flag cleared", r.director.boss_spawned, false)
	_check("partial heal applied", is_equal_approx(r.player_health,
		maxhp * (0.25 + r.SUBNET_CLEAR_HEAL)), true)

	# The heal tops out at the maximum rather than overshooting it.
	r.player_health = maxhp
	_walk_the_gate(r)
	_check("heal never exceeds max integrity", r.player_health, maxhp)
	r.free()

	finished["advance_clears_the_field"] = true
## Clear the subnet, step into the gate, cross the corridor, come out the far
## side — the whole transition, driven the way a player drives it.
func _walk_the_gate(r: Node2D) -> void:
	r.phase = r.Phase.CLEARED
	r.terrain.gate_open = true
	# One step now: the corridor is part of the arena, so reaching its far end is
	# the whole transition.
	r.player_pos = r.terrain.corridor_end
	r._physics_process(1.0 / 60.0)


## SaveGame.bank() ACCUMULATES. A run that banks at every subnet clear must hand
## it deltas — totals would count subnet 01's kills once per subnet and hand out
## unlock milestones nobody earned.
func banking_is_incremental() -> void:
	var r := await _fresh_run()
	r.kills = 100
	r.flips = 10
	r.salvage = 200
	r._bank_progress(true)
	_check("first bank writes the total", SaveGame.load_state()["kills"], 100)
	r.kills = 175
	r.salvage = 260
	r._bank_progress(true)
	_check("second bank writes only the delta", SaveGame.load_state()["kills"], 175)
	_check("salvage banks the delta too", SaveGame.load_state()["salvage"], 260)
	_check("flips did not double", SaveGame.load_state()["flips"], 10)

	# A death after a mid-campaign clear keeps the banked salvage and still
	# counts the kills since.
	r.kills = 200
	r._bank_progress(false)
	_check("death banks kills but no salvage", SaveGame.load_state()["kills"], 200)
	_check("banked salvage survives the death", SaveGame.load_state()["salvage"], 260)
	r.free()

	finished["banking_is_incremental"] = true
## Killing ICE advances, until the last subnet, where it wins.
func last_subnet_wins() -> void:
	var r := await _fresh_run()
	_check("mid-campaign ICE flags an advance rather than a win",
		_kill_ice(r), false)
	_check("and the subnet is cleared, not advanced", r.phase, r.Phase.CLEARED)
	_check("the gate is what opens instead", r.terrain.gate_open, true)

	var r2 := await _fresh_run()
	r2.subnet = SpawnDirector.CAMPAIGN_SUBNETS
	_check("ICE on the last subnet wins the run", _kill_ice(r2), true)
	_check("the last subnet never enters transit", r2.phase, r2.Phase.FIGHTING)
	r.free()
	r2.free()

	finished["last_subnet_wins"] = true
func _kill_ice(r: Node2D) -> bool:
	var b = r.enemy_types[EnemyTable.ICE]
	var i: int = r.enemies.spawn(Vector2(200, 0), Vector2.ZERO, b.integrity, 48.0, EnemyTable.ICE)
	r._on_death(i)
	return r.won
