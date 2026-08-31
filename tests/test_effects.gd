extends SceneTree

## The runtime mechanics the new modules need: knockback, the player shield, and
## the new vector kinds.

var failures := 0
var finished := {}
const CASES := ["knockback_pushes_then_fades", "the_shield_absorbs_before_integrity"]

func _initialize() -> void:
	print("ROOTKIT — module effects\n")
	await knockback_pushes_then_fades()
	await the_shield_absorbs_before_integrity()
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
