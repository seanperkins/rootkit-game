extends SceneTree

## The runtime mechanics the new modules need: knockback, the player shield, and
## the new vector kinds.

var failures := 0
var finished := {}
const CASES := ["knockback_pushes_then_fades", "the_shield_absorbs_before_integrity",
	"burst_emits_more_than_once"]

func _initialize() -> void:
	print("ROOTKIT — module effects\n")
	await knockback_pushes_then_fades()
	await the_shield_absorbs_before_integrity()
	await burst_emits_more_than_once()
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

func knockback_pushes_then_fades() -> void:
	var r := await _fresh_run()
	r.player_pos = Vector2.ZERO
	var i: int = r.enemies.spawn(Vector2(300, 0), Vector2.ZERO, 100.0, 12.0, 0)
	r._spawn_enemy_state(i, 100.0)
	r.apply_knockback(i, Vector2(900, 0))
	_check("an impulse is stored", r._knock[i].x > 0.0, true)
	var before: Vector2 = r.enemies.pos[i]
	r._step2_integrate(1.0 / 60.0)
	# Outward, against a chase that would otherwise close on the player.
	_check("and moves it outward", r.enemies.pos[i].x > before.x, true)
	for k in 180:
		r._step2_integrate(1.0 / 60.0)
	_check("the impulse decays away", r._knock[i].length() < 1.0, true)

	# A recycled slot must not inherit a live impulse.
	r.apply_knockback(i, Vector2(500, 0))
	r._spawn_enemy_state(i, 100.0)
	_check("spawning clears it", r._knock[i], Vector2.ZERO)
	r.free()
	finished["knockback_pushes_then_fades"] = true

func the_shield_absorbs_before_integrity() -> void:
	var r := await _fresh_run()
	r.player_shield = 20.0
	var hp: float = r.player_health
	r.player_iframe = 0.0
	r._damage_player(8.0)
	_check("integrity is untouched while shielded", r.player_health, hp)
	_check("and the shield paid for it", r.player_shield, 12.0)

	# Overflow spills through rather than being swallowed.
	r.player_shield = 3.0
	r.player_iframe = 0.0
	r._damage_player(20.0)
	_check("a shield smaller than the hit spills over", r.player_health < hp, true)
	_check("and is spent", r.player_shield, 0.0)

	# With no shield the hit lands as it always did.
	r.player_iframe = 0.0
	var hp2: float = r.player_health
	r._damage_player(5.0)
	_check("with no shield the hit lands in full", r.player_health < hp2, true)
	r.free()
	finished["the_shield_absorbs_before_integrity"] = true

## A trigger's burst is how many times the vector emits for one event, so the
## observable is the number of shots produced, not a number on the struct.
func burst_emits_more_than_once() -> void:
	var r := await _fresh_run()
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"packet"])
	ex.place(t[&"on_level_up"])          # burst 8
	r.loadout.exploits.append(ex)
	r._recompile()
	var ei: int = r.loadout.exploits.size() - 1
	var res: ResolvedExploit = r.resolved[ei]
	_check("the exploit resolved a burst", res.burst, 8)

	var before: int = r.projectiles.count
	r._fire_cd[ei] = 0.0
	r._try_event_fire(ei, res)
	_check("one event produced eight shots", r.projectiles.count - before, 8)

	# And it is still gated: a second event inside the cooldown fires nothing.
	var after: int = r.projectiles.count
	_check("a second event inside the cooldown is refused",
		r._try_event_fire(ei, res), false)
	_check("and produced no shots", r.projectiles.count, after)

	# A trigger with no burst stat emits exactly once — zero must read as one.
	var ex2 := Exploit.new()
	ex2.place(t[&"packet"])
	ex2.place(t[&"on_kill"])
	r.loadout.exploits.append(ex2)
	r._recompile()
	var ei2: int = r.loadout.exploits.size() - 1
	var res2: ResolvedExploit = r.resolved[ei2]
	_check("a burstless trigger resolves zero", res2.burst, 0)
	var b2: int = r.projectiles.count
	r._fire_cd[ei2] = 0.0
	r._try_event_fire(ei2, res2)
	_check("and still emits exactly once", r.projectiles.count - b2, 1)
	r.free()
	finished["burst_emits_more_than_once"] = true
