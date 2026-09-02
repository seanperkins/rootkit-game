extends SceneTree

## The ending barrier, with peers pumped by hand: in a session only the host's
## END emits run_ended; a terminal state anywhere is a candidate the host
## checks through every PRESENT peer's report at a future tick; DEAD
## spectators count and ABSENT peers do not; disagreement is repaired at a
## fresh future boundary and checked again; a host with nobody present
## confirms at once; and a campaign win confirms the same way.

var failures := 0
var finished := {}
const DELAY := 3
const O := NetworkSession.Outcome

const CASES := ["a_last_death_ends_only_through_end",
	"a_dead_spectator_reports_and_an_absent_peer_does_not",
	"a_false_client_ending_is_repaired_not_announced",
	"a_terminal_host_repairs_then_checks_again", "a_campaign_win_confirms",
	"a_lone_host_confirms_at_once"]

func _initialize() -> void:
	print("ROOTKIT — endings\n")
	SaveGame.use_fresh_state()
	await a_last_death_ends_only_through_end()
	await a_dead_spectator_reports_and_an_absent_peer_does_not()
	await a_false_client_ending_is_repaired_not_announced()
	await a_terminal_host_repairs_then_checks_again()
	await a_campaign_win_confirms()
	await a_lone_host_confirms_at_once()
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

## The wire, by hand: after each step, forward what each peer would have sent.
## END_CHECK host->clients, reports and candidates clients->host, RESYNC and
## snapshots host->targets, END host->clients.
var _forwarded_reports: Dictionary = {}
var _forwarded_candidates: Dictionary = {}

func _relay(h: MultiplayerHarness) -> void:
	var host: Node2D = h.runs[0]
	var es: NetworkSession = host._session
	for k in range(1, h.runs.size()):
		var c: Node2D = h.runs[k]
		var cs: NetworkSession = c._session
		if host.slot_state[c.local_slot] == host.SlotState.ABSENT:
			continue                       # a parked peer is off the wire
		if es.end_check_tick >= 0 and cs.end_check_tick != es.end_check_tick:
			c.receive_end_check(es.end_check_tick)
		if cs.end_outcome != O.NONE and not _forwarded_candidates.has([k, cs.end_outcome]):
			_forwarded_candidates[[k, cs.end_outcome]] = true
			host.receive_end_candidate(c.local_slot, c.tick, cs.end_outcome, 0)
		if cs.end_reported and not _forwarded_reports.has([k, cs.end_report[0]]):
			_forwarded_reports[[k, cs.end_report[0]]] = true
			host.receive_end_candidate(c.local_slot, cs.end_report[0], cs.end_report[2], cs.end_report[1])
		if es.resync_tick >= 0 and cs.resync_tick != es.resync_tick:
			c.announce_resync(es.resync_tick)
		if es.ended and not cs.ended:
			c.receive_end(0, es.end_outcome)
	var snap: PackedByteArray = host.host_try_snapshot()
	if not snap.is_empty():
		var label = bytes_to_var(snap)
		for k in range(1, h.runs.size()):
			var c: Node2D = h.runs[k]
			if c._session.resync_tick == int(label["tick"]) or c._session.resync_tick >= 0:
				c.apply_snapshot(snap, int(label["tick"]))
		h.catch_up(_fn(h))

func _run(h: MultiplayerHarness, n: int) -> void:
	var fn := _fn(h)
	for _i in n:
		h.step(fn)
		if h.runs[0].tick % SessionRules.CHECKSUM_INTERVAL == 0:
			h.distribute_checksums()
		_relay(h)

func _setup(players: int) -> MultiplayerHarness:
	_forwarded_reports = {}
	_forwarded_candidates = {}
	var h := MultiplayerHarness.new()
	await h.setup(self, players, DELAY, 20260830)
	_run(h, 30)
	return h

func _endings(h: MultiplayerHarness) -> Array:
	var out := []
	for r in h.runs:
		out.append([])
	for k in h.runs.size():
		var list: Array = out[k]
		h.runs[k].run_ended.connect(func(w, _s): list.append(w))
	return out

## Kill every slot on every peer on a tick that is not a checksum tick.
func _everyone_dies(h: MultiplayerHarness) -> void:
	for r in h.runs:
		for s in h.players:
			r._die(s)

func a_last_death_ends_only_through_end() -> void:
	var h := await _setup(2)
	var ends := _endings(h)
	_check_true("not on a checksum cadence tick", h.runs[0].tick % SessionRules.CHECKSUM_INTERVAL != 0)
	_everyone_dies(h)
	_check("a local death emits nothing in a session", ends[0].size() + ends[1].size(), 0)
	_check("but each peer holds a LOSS candidate", [h.runs[0]._session.end_outcome,
		h.runs[1]._session.end_outcome], [O.LOSS, O.LOSS])
	var exec_before: int = h.runs[0].lockstep.executed
	_run(h, 2)
	_check_true("lockstep keeps consuming ticks through the hold",
		h.runs[0].lockstep.executed > exec_before)
	var c: int = h.runs[0]._session.end_check_tick
	_check_true("the host opened a check ahead of its tick", c >= exec_before + DELAY + Protocol.BOUNDARY_MARGIN)
	_run(h, DELAY + 6)
	_check("the host confirmed with END", h.runs[0]._session.ended, true)
	_check("the host emitted run_ended once, as a loss", ends[0], [false])
	_check("the client emitted run_ended once, from END", ends[1], [false])
	_check("nothing ended twice", ends[0].size() + ends[1].size(), 2)
	h.teardown()
	await process_frame
	finished["a_last_death_ends_only_through_end"] = true

func a_dead_spectator_reports_and_an_absent_peer_does_not() -> void:
	var h := await _setup(3)
	var ends := _endings(h)
	# Slot 2 dies early and spectates; slot 1 goes ABSENT (parked).
	for r in h.runs:
		r._die(2)
	_run(h, 5)
	_check("one dead slot keeps the run alive", h.runs[0].alive, true)
	for r in h.runs:
		r.slot_state[1] = r.SlotState.ABSENT
	_run(h, 5)
	# Now the last LIVE slot dies everywhere.
	for r in h.runs:
		r._die(0)
	_run(h, 2)
	var es: NetworkSession = h.runs[0]._session
	_check_true("a check opened", es.end_check_tick >= 0)
	_run(h, DELAY + 8)
	_check("the DEAD spectator reported", es.end_reports.has(2) or es.ended, true)
	_check("the ABSENT slot was not waited on", es.end_reports.has(1), false)
	_check("the host confirmed", es.ended, true)
	_check("the spectator received END", h.runs[2]._session.ended, true)
	_check("everyone present ended exactly once", [ends[0], ends[2]], [[false], [false]])
	h.teardown()
	await process_frame
	finished["a_dead_spectator_reports_and_an_absent_peer_does_not"] = true

## A client alone believes everybody died. Its records go neutral, the host
## never stalls, the check disagrees, a fresh boundary restores the client, and
## no END is ever sent.
func a_false_client_ending_is_repaired_not_announced() -> void:
	var h := await _setup(2)
	var ends := _endings(h)
	var client: Node2D = h.runs[1]
	client._die(0)
	client._die(1)
	_check("the client holds a false LOSS candidate", client._session.end_outcome, O.LOSS)
	_check("its world is held", client.alive, false)
	var exec_before: int = h.runs[0].lockstep.executed
	_run(h, 3)
	_check_true("the host never stalled on the dead client's records",
		h.runs[0].lockstep.executed >= exec_before + 3)
	_check_true("a check opened", h.runs[0]._session.end_check_tick >= 0)
	_run(h, DELAY + 4)
	_check_true("the disagreement scheduled a resync", h.runs[0]._session.desync_ticks.size() == 1)
	_run(h, DELAY + 8)
	_check("the client was restored to a live world", client.alive, true)
	_check("and its false candidate is gone", client._session.end_outcome, O.NONE)
	_check("hashes agree again", h.all_agree(), true)
	if not h.all_agree():
		print("    diff ", h.first_difference(h.runs[0], client), " desyncs ", h.runs[0]._session.desync_ticks, " resync ", h.runs[0]._session.resync_tick, " exec ", h.runs[0].lockstep.executed, " ", client.lockstep.executed)
	_check("no END was ever sent", h.runs[0]._session.ended, false)
	_check("no run_ended anywhere", ends[0].size() + ends[1].size(), 0)
	h.teardown()
	await process_frame
	finished["a_false_client_ending_is_repaired_not_announced"] = true

## The host alone reaches a terminal state: the first check disagrees, the
## client is repaired to the host's terminal state, a second check agrees, END.
func a_terminal_host_repairs_then_checks_again() -> void:
	var h := await _setup(2)
	var ends := _endings(h)
	var host: Node2D = h.runs[0]
	host._die(0)
	host._die(1)
	_check("the host holds a LOSS candidate", host._session.end_outcome, O.LOSS)
	_run(h, DELAY + 6)
	_check("the first check disagreed and scheduled a repair", host._session.desync_ticks.size(), 1)
	_check("no END after the first check", host._session.ended, false)
	_run(h, DELAY + 8)
	_check("the client was brought to the host's terminal state", h.runs[1].alive, false)
	_run(h, DELAY + 8)
	_check("a second check agreed and the host confirmed", host._session.ended, true)
	if not host._session.ended:
		print("    reports ", host._session.end_reports, " check ", host._session.end_check_tick, " desyncs ", host._session.desync_ticks, " client alive ", h.runs[1].alive, " diff ", h.first_difference(host, h.runs[1]))
	_check("both ended once, as a loss", [ends[0], ends[1]], [[false], [false]])
	h.teardown()
	await process_frame
	finished["a_terminal_host_repairs_then_checks_again"] = true

func a_campaign_win_confirms() -> void:
	var h := await _setup(2)
	var ends := _endings(h)
	for r in h.runs:
		r.subnet = SpawnDirector.CAMPAIGN_SUBNETS
		var b = r.enemy_types[EnemyTable.ICE]
		var i: int = r.enemies.spawn(Vector2(200, 0), Vector2.ZERO, b.integrity, 48.0, EnemyTable.ICE)
		r._on_death(i)
		r.hitstop_ticks = 0
	_check("both peers hold a WIN candidate", [h.runs[0]._session.end_outcome,
		h.runs[1]._session.end_outcome], [O.WIN, O.WIN])
	_check("a win emits nothing locally in a session", ends[0].size() + ends[1].size(), 0)
	_run(h, DELAY + 8)
	_check("the host confirmed the win", h.runs[0]._session.ended, true)
	if not h.runs[0]._session.ended:
		print("    reports ", h.runs[0]._session.end_reports, " check ", h.runs[0]._session.end_check_tick, " desyncs ", h.runs[0]._session.desync_ticks, " diff ", h.first_difference(h.runs[0], h.runs[1]))
	_check("both peers ended once, as a win", [ends[0], ends[1]], [[true], [true]])
	_check("a win barrier cannot be cancelled as no-LIVE",
		h.runs[0]._session.cancel_no_live_check(), false)
	h.teardown()
	await process_frame
	finished["a_campaign_win_confirms"] = true

func a_lone_host_confirms_at_once() -> void:
	var h := await _setup(2)
	var ends := _endings(h)
	var host: Node2D = h.runs[0]
	host.slot_state[1] = host.SlotState.ABSENT
	host._die(0)
	var fn := _fn(h)
	h.step_one(0, fn)
	_check("with no remote PRESENT peer the host confirms immediately", host._session.ended, true)
	_check("and emitted run_ended once", ends[0], [false])
	h.teardown()
	await process_frame
	finished["a_lone_host_confirms_at_once"] = true
