extends SceneTree

## Facing, the forward vectors, the mine drop, the shield rearm and the fx
## structural checks. Every case builds its own run; the harness cases build
## two.

var failures := 0
var finished := {}
const DT := 1.0 / 60.0

const CASES := ["facing_follows_the_applied_record_and_holds",
	"facing_survives_a_restore", "two_peers_agree_while_turning",
	"a_return_resets_facing"]

func _initialize() -> void:
	print("ROOTKIT — facing\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	await facing_follows_the_applied_record_and_holds()
	await facing_survives_a_restore()
	await two_peers_agree_while_turning()
	await a_return_resets_facing()
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

func _check_true(label: String, got: bool) -> void:
	_check(label, got, true)

func _fresh_run() -> Node2D:
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	r.external_drive = true
	root.add_child(r)
	await process_frame
	r.input_override = Vector2.ZERO
	return r

func facing_follows_the_applied_record_and_holds() -> void:
	var r := await _fresh_run()
	_check("facing starts right", r.player_facing[r.local_slot], Vector2.RIGHT)
	r.input_override = Vector2(3.0, 4.0)     # not unit: the poll normalises once
	r._physics_process(DT)
	var f: Vector2 = r.player_facing[r.local_slot]
	_check_true("a diagonal record sets a unit facing", absf(f.length() - 1.0) < 1e-5)
	_check_true("pointing the way it moved", f.dot(Vector2(3.0, 4.0).normalized()) > 0.999)
	r.input_override = Vector2.ZERO
	for _i in 5:
		r._physics_process(DT)
	_check("a zero record keeps it", r.player_facing[r.local_slot], f)
	r.free()
	await process_frame
	finished["facing_follows_the_applied_record_and_holds"] = true

func facing_survives_a_restore() -> void:
	var a := await _fresh_run()
	var b := await _fresh_run()
	a.input_override = Vector2(-1.0, 0.0)
	a._physics_process(DT)
	var bytes: PackedByteArray = a.serialize_state(a.tick)
	_check_true("restore accepts it", b.restore_state(bytes, a.tick))
	_check("facing came through the snapshot", b.player_facing[0], a.player_facing[0])
	_check("and the hashes agree", b._state_hash(), a._state_hash())
	a.free(); b.free()
	await process_frame
	finished["facing_survives_a_restore"] = true

func two_peers_agree_while_turning() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, 2, 20260830)
	var fn := func(t: int) -> Array:
		var a := float(t) * 0.05
		return [Vector2(cos(a), sin(a)), Vector2(-sin(a), cos(a))]
	for _i in 600:
		h.step(fn)
	_check("two turning peers agree", h.all_agree(), true)
	if not h.all_agree():
		print("    diff ", h.first_difference(h.runs[0], h.runs[1]))
	h.teardown()
	await process_frame
	finished["two_peers_agree_while_turning"] = true

func a_return_resets_facing() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, 0, 20260830)
	var fn := func(_t: int) -> Array: return [Vector2.ZERO, Vector2(-1.0, 0.0)]
	for _i in 5:
		h.step(fn)
	for r in h.runs:
		_check("slot one faces left before parking", r.player_facing[1], Vector2.LEFT)
		r._park(1)
		r._return(1, r.lockstep.executed - 1)
		_check("a return faces right again", r.player_facing[1], Vector2.RIGHT)
	h.teardown()
	await process_frame
	finished["a_return_resets_facing"] = true
