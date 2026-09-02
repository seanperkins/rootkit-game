extends SceneTree

## Future-boundary desync recovery, with three peers pumped by hand: corrupt
## one, let the periodic checksums disagree, and prove the host's announced
## boundary is reachable, the host serialises only with the window in hand and
## exactly at state-after-R, correct peers never rewind, the corrupt peer
## restores and resumes at R + 1 with everything it already broadcast intact,
## and the party agrees again at R + delay + 1. Then diverge three times and
## prove the third ends the session with every offending tick named.

var failures := 0
var finished := {}
const DELAY := 3

const CASES := ["one_divergence_is_repaired_at_a_future_boundary",
	"the_host_holds_until_the_window_is_in_hand",
	"the_third_divergence_ends_the_session"]

func _initialize() -> void:
	print("ROOTKIT — desync recovery\n")
	SaveGame.use_fresh_state()
	await one_divergence_is_repaired_at_a_future_boundary()
	await the_host_holds_until_the_window_is_in_hand()
	await the_third_divergence_ends_the_session()
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

func _moves(t: int, players: int) -> Array:
	var out := []
	for s in players:
		var a := float(t) * 0.01 + float(s) * 1.7
		out.append(Vector2(cos(a), sin(a)))
	return out

func _fn(h: MultiplayerHarness) -> Callable:
	var players := h.players
	return func(t: int) -> Array: return _moves(t, players)

## Step everyone `n` ticks, distributing checksums on the cadence, and let the
## host detect and announce. Returns the boundary if one was announced.
func _run_ticks(h: MultiplayerHarness, n: int) -> int:
	var announced := -1
	var fn := _fn(h)
	for _i in n:
		h.step(fn)
		if h.runs[0].tick % SessionRules.CHECKSUM_INTERVAL == 0:
			h.distribute_checksums()
		var r: int = h.runs[0].host_detect_desync()
		if r >= 0:
			announced = r
			for k in range(1, h.runs.size()):
				h.runs[k].announce_resync(r)
	return announced

func one_divergence_is_repaired_at_a_future_boundary() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 3, DELAY, 20260830)
	var fn := _fn(h)
	_check("three peers start in agreement", _run_ticks(h, 120) < 0 and h.all_agree(), true)

	# Corrupt peer two in a hashed field the world does not overwrite.
	var bad: Node2D = h.runs[2]
	bad.salvage += 777
	_check("the corruption breaks agreement", h.all_agree(), false)

	# Run until the next checksum tick catches it.
	var announced := -1
	var host_tick_at_detect := -1
	for _i in 70:
		h.step(fn)
		if h.runs[0].tick % SessionRules.CHECKSUM_INTERVAL == 0:
			h.distribute_checksums()
		var r: int = h.runs[0].host_detect_desync()
		if r >= 0:
			announced = r
			host_tick_at_detect = h.runs[0].lockstep.executed
			for k in range(1, h.runs.size()):
				h.runs[k].announce_resync(r)
			break
	_check_true("the host announced a boundary", announced >= 0)
	_check_true("at least delay + 3 ticks ahead of its own tick",
		announced >= host_tick_at_detect + DELAY + Protocol.BOUNDARY_MARGIN)
	_check("only the corrupt slot is a snapshot target",
		h.runs[0]._session.resync_targets, PackedInt32Array([2]))
	_check("one desync is on record", h.runs[0]._session.desync_ticks.size(), 1)

	# Everyone executes through R; the host serialises exactly at R + 1.
	var bytes := PackedByteArray()
	var host_exec_at_snapshot := -1
	var correct_before: int = h.runs[1].lockstep.executed
	for _i in 40:
		h.step(fn)
		var b: PackedByteArray = h.runs[0].host_try_snapshot()
		if not b.is_empty():
			bytes = b
			host_exec_at_snapshot = h.runs[0].lockstep.executed
			break
	_check_true("the host produced a snapshot", not bytes.is_empty())
	_check("serialised with the host having executed exactly through R",
		host_exec_at_snapshot, announced + 1)
	var label = bytes_to_var(bytes)
	_check("the snapshot describes state after R", int(label["tick"]), announced)
	_check_true("the correct peer executed through R and kept going",
		h.runs[1].lockstep.executed > correct_before and h.runs[1].lockstep.executed >= announced + 1)

	# Deliver the snapshot to the corrupt peer only.
	var own_before: Array = []
	for t in range(announced + 1, announced + 1 + DELAY):
		var cell: int = t & (Lockstep.RING - 1)
		var ls: Lockstep = bad.lockstep
		if ls._tick_tag[cell] == t and (ls._have[cell] & (1 << 2)) != 0:
			own_before.append([t, ls._moves[cell * SessionRules.MAX_PLAYERS + 2]])
	var correct_hash_before: int = h.runs[1]._state_hash()
	_check_true("the corrupt peer restores", bad.apply_snapshot(bytes, announced))
	_check("and resumes at R + 1", bad.lockstep.executed, announced + 1)
	_check("its boundary is cleared", bad._session.recovering(), false)
	_check("a correct peer was never touched", h.runs[1]._state_hash(), correct_hash_before)
	var own_after := true
	for e in own_before:
		var cell: int = int(e[0]) & (Lockstep.RING - 1)
		if bad.lockstep._moves[cell * SessionRules.MAX_PLAYERS + 2] != e[1]:
			own_after = false
	_check("the records it had already broadcast survive the merge", own_after, true)

	# Catch the restored peer up, walk the party past R + delay, and prove
	# agreement there and beyond.
	h.catch_up(fn)
	for _i in DELAY + 1:
		h.step(fn)
	h.catch_up(fn)
	_check_true("every peer reached R + delay + 1",
		h.runs[0].lockstep.executed >= announced + DELAY + 1
		and h.runs[2].lockstep.executed == h.runs[0].lockstep.executed)
	_check("hashes agree after recovery", h.all_agree(), true)
	_check("and stay in agreement for another minute", _run_ticks(h, 60) < 0 and h.all_agree(), true)
	_check("the host's boundary is cleared", h.runs[0]._session.recovering(), false)
	h.teardown()
	await process_frame
	finished["one_divergence_is_repaired_at_a_future_boundary"] = true

## The host does not serialise at R + 1 until every LIVE slot's records for
## (R, R + delay] are in its ring — and it holds its own execution there rather
## than describing a state past R.
func the_host_holds_until_the_window_is_in_hand() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, DELAY, 20260830)
	var host: Node2D = h.runs[0]
	_run_ticks(h, 30)
	var r: int = host.lockstep.executed + DELAY + Protocol.BOUNDARY_MARGIN
	host._session.announce_resync(r, PackedInt32Array([1]))
	# Step ONLY the host to R + 1, feeding just enough records for that.
	var fn := _fn(h)
	while host.lockstep.executed < r + 1:
		h.step_one(0, fn)
	_check("the host executed through R", host.lockstep.executed, r + 1)
	# Withhold the client's record for R + delay from the host's ring: the
	# window is incomplete, so no snapshot and the host holds.
	var cell: int = (r + DELAY) & (Lockstep.RING - 1)
	var had: int = host.lockstep._have[cell]
	host.lockstep._have[cell] = had & ~(1 << 1)
	_check("with the window incomplete, no snapshot", host.host_try_snapshot().is_empty(), true)
	_check("and the host holds its own tick", host._holding_for_snapshot(), true)
	host.lockstep._have[cell] = had
	_check_true("once the window is in hand it serialises", not host.host_try_snapshot().is_empty())
	_check("and stops holding", host._holding_for_snapshot(), false)
	h.teardown()
	await process_frame
	finished["the_host_holds_until_the_window_is_in_hand"] = true

func the_third_divergence_ends_the_session() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, DELAY, 20260830)
	var ended := []
	h.runs[0].run_ended.connect(func(w, s): ended.append(w))
	var fn := _fn(h)
	var seen := []
	for round in 3:
		h.runs[1].salvage += 100 * (round + 1)
		var announced := -1
		for _i in 130:
			h.step(fn)
			if h.runs[0].tick % SessionRules.CHECKSUM_INTERVAL == 0:
				h.distribute_checksums()
			var rr: int = h.runs[0].host_detect_desync()
			if rr >= 0 or h.runs[0]._session.terminated:
				announced = rr
				break
		if h.runs[0]._session.terminated:
			break
		h.runs[1].announce_resync(announced)
		var bytes := PackedByteArray()
		for _i in 40:
			h.step(fn)
			var b: PackedByteArray = h.runs[0].host_try_snapshot()
			if not b.is_empty():
				bytes = b
				break
		h.runs[1].apply_snapshot(bytes, announced)
		h.catch_up(fn)
		seen.append(h.all_agree())
	_check("the first two divergences were repaired", seen, [true, true])
	_check("the third terminated the session", h.runs[0]._session.terminated, true)
	_check("with three offending ticks on record", h.runs[0]._session.desync_ticks.size(), 3)
	_check("the run ended, as a loss", ended, [false])
	var exec_before: int = h.runs[0].lockstep.executed
	h.step(fn)
	_check("and the world stopped", h.runs[0].lockstep.executed, exec_before)
	h.teardown()
	await process_frame
	finished["the_third_divergence_ends_the_session"] = true
