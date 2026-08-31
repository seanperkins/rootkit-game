extends SceneTree

## Per-type enemy behaviour, driven directly rather than through a played run.

var failures := 0
var finished := {}

const CASES := ["chase_is_unchanged_and_state_resets", "spawning_clears_ai_state"]

func _initialize() -> void:
	print("ROOTKIT — enemy behaviour\n")
	await chase_is_unchanged_and_state_resets()
	await spawning_clears_ai_state()
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

func chase_is_unchanged_and_state_resets() -> void:
	var r := await _fresh_run()
	# A plain daemon still walks straight at the player.
	var i: int = r.enemies.spawn(Vector2(400, 0), Vector2.ZERO, 10.0, 12.0, 0)
	r._clear_ai(i)
	var v: Vector2 = r._behave(i, r.enemy_types[0], 1.0 / 60.0)
	_check("chase heads at the player", v.normalized().is_equal_approx(
		(r.player_pos - r.enemies.pos[i]).normalized()), true)
	_check("at the type's speed",
		is_equal_approx(v.length(), r.enemy_types[0].speed), true)

	# A recycled slot must not inherit the previous occupant's AI state. This is
	# the bug class the worm arrays already had to be defended against.
	r._ai_phase[i] = 3
	r._ai_timer[i] = 9.9
	r._ai_aim[i] = Vector2(1, 1)
	r._submerged[i] = 1
	r._clear_ai(i)
	_check("phase resets", r._ai_phase[i], 0)
	_check("timer resets", r._ai_timer[i], 0.0)
	_check("aim resets", r._ai_aim[i], Vector2.ZERO)
	_check("submersion resets", r._submerged[i], 0)
	r.free()
	finished["chase_is_unchanged_and_state_resets"] = true

func spawning_clears_ai_state() -> void:
	var r := await _fresh_run()
	var i: int = r.enemies.spawn(Vector2(300, 0), Vector2.ZERO, 10.0, 12.0, 0)
	r._ai_phase[i] = 2
	r._submerged[i] = 1
	r.enemies.despawn(i)
	var j: int = r.enemies.spawn(Vector2(300, 0), Vector2.ZERO, 10.0, 12.0, 0)
	r._spawn_enemy_state(j, 10.0)
	_check("the recycled slot starts clean", r._ai_phase[j], 0)
	_check("and is not submerged", r._submerged[j], 0)
	_check("and records its spawn HP", r._spawn_hp[j], 10.0)
	r.free()
	finished["spawning_clears_ai_state"] = true
