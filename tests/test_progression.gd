extends SceneTree
var failures := 0
var completed := false
const Run = preload("res://scripts/run/run.gd")

func check(label: String, ok: bool) -> void:
	if not ok:
		print("  FAIL  ", label)
		failures += 1

func _initialize() -> void:
	SaveGame.use_test_paths()
	await process_frame
	for level in range(1, 21):
		check("early choice costs preserved", Run._xp_for(level) == int(round(float(5 + 3 * (level - 1)) * Run.XP_SLOWDOWN)))
	var previous := 0
	for level in range(1, 1001):
		var cost := Run._xp_for(level)
		check("supported costs stay positive and monotonic", cost > previous)
		previous = cost
	check("hostile arithmetic cannot overflow", Run._xp_for(9223372036854775807) > 0 and Run._xp_for(-9223372036854775807) > 0)
	await shared_rounds()
	check("shared progression case completed", completed)
	print("  PASS — progression costs, remainder and shared recovery" if failures == 0 else "  FAIL — %d assertions" % failures)
	quit(0 if failures == 0 else 1)

func shared_rounds() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, 0, 42)
	var grant := 3
	for level in range(1, 10): grant += Run._xp_for(level)
	for g in h.runs: g._gain_xp(grant)
	var host: Node2D = h.runs[0]
	var peer: Node2D = h.runs[1]
	check("multi-threshold gain preserves remainder", host.level == 10 and host.xp == 3)
	check("shared grant is counted once", peer.level == 10 and peer.xp == 3)
	for t in 30: h.step(func(_tick): return [Vector2.ZERO, Vector2.ZERO])
	check("all earned rounds eventually settle", not host.paused and host.pending_levels == 0)
	check("peers share every staged choice", host._state_hash() == peer._state_hash())
	var snapshot: PackedByteArray = host.serialize_state(host.tick)
	peer.xp = 0
	check("progression restore succeeds", peer.restore_state(snapshot, host.tick))
	check("restore retains exact remainder and peers agree", peer.xp == 3 and host._state_hash() == peer._state_hash())
	h.teardown()
	completed = true
