extends SceneTree

## Parking: a slot whose controller drops is parked by the host at its first
## tick with no record, on every peer at that same tick; its open offer
## resolves, its progress banks once, and the run goes on. A DEAD slot parks
## the same way with zero health remembered; the last LIVE slot parking is a
## loss candidate. Raw traffic from a peer holding no slot is cut. A leave
## before START is a lobby removal, not a park. A client that loses the host
## stops and re-introduces itself; a host never migrates.

var failures := 0
var finished := {}
const DELAY := 3

const CASES := ["a_dropped_slot_parks_at_the_hosts_first_missing_tick",
	"a_dead_slot_parks_and_the_last_live_park_is_a_loss_candidate",
	"a_pre_start_leave_is_a_lobby_removal", "raw_input_from_an_unbound_peer_is_cut",
	"a_client_treats_host_loss_as_stop_and_hello"]

func _initialize() -> void:
	print("ROOTKIT — parking\n")
	SaveGame.use_fresh_state()
	await a_dropped_slot_parks_at_the_hosts_first_missing_tick()
	await a_dead_slot_parks_and_the_last_live_park_is_a_loss_candidate()
	a_pre_start_leave_is_a_lobby_removal()
	raw_input_from_an_unbound_peer_is_cut()
	await a_client_treats_host_loss_as_stop_and_hello()
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

func _setup(players: int) -> MultiplayerHarness:
	var h := MultiplayerHarness.new()
	await h.setup(self, players, DELAY, 20260830)
	return h

func a_dropped_slot_parks_at_the_hosts_first_missing_tick() -> void:
	var h := await _setup(3)
	var pump := RosterPump.new(h)
	var fn := _fn(h)
	pump.run(30, fn)
	var host: Node2D = h.runs[0]
	var client: Node2D = h.runs[1]
	for r in h.runs:
		r.kills[2] = 7
		r.pending_levels = 1          # a round opens: every LIVE slot holds an offer
	pump.run(1, fn)
	_check_true("slot two holds an offer before it drops", not (host._offer_open[2] as Dictionary).is_empty())
	var health_before: float = host.player_health[2]
	# The controller drops: its records stop from W on, and the host learns it
	# is gone.
	var w: int = host.lockstep.executed + DELAY + 2
	h.withheld[2] = [w, 1 << 30]
	host.request_park(2)
	var checks_pending := 0
	pump.run(24, fn)
	_check("the host parked the slot at its first missing tick", int(host._session.absent_ticks.get(2, -1)), w)
	_check("the client parked it at that same tick", int(client._session.absent_ticks.get(2, -1)), w)
	_check("the slot is ABSENT on both", [host.slot_state[2], client.slot_state[2]],
		[host.SlotState.ABSENT, client.SlotState.ABSENT])
	_check("its health is remembered", host._parked_health[2], health_before)
	_check("its open offer resolved", (host._offer_open[2] as Dictionary).is_empty(), true)
	_check("its progress banked once", int(host._banked[2][&"kills"]), 7)
	_check_true("the run went on past the park", host.lockstep.executed > w + 10)
	_check("the run is still alive", host.alive, true)
	_check("host and client agree", h.first_difference(host, client), "")
	_check("no ending was proposed", host._session.end_outcome, NetworkSession.Outcome.NONE)
	h.teardown()
	await process_frame
	finished["a_dropped_slot_parks_at_the_hosts_first_missing_tick"] = true

func a_dead_slot_parks_and_the_last_live_park_is_a_loss_candidate() -> void:
	var h := await _setup(3)
	var pump := RosterPump.new(h)
	var fn := _fn(h)
	pump.run(20, fn)
	var host: Node2D = h.runs[0]
	for r in h.runs:
		r._die(2)
		r.hitstop_ticks = 0
	pump.run(2, fn)
	var w: int = host.lockstep.executed + DELAY + 1
	h.withheld[2] = [w, 1 << 30]
	host.request_park(2)
	pump.run(16, fn)
	_check("a DEAD slot parks", host.slot_state[2], host.SlotState.ABSENT)
	_check("with zero health remembered", host._parked_health[2], 0.0)
	_check("and no loss proposed while others live", host._session.end_outcome, NetworkSession.Outcome.NONE)
	# The host dies; slot one is the last LIVE slot, and it drops.
	for r in h.runs:
		if r.slot_state[2] == r.SlotState.ABSENT:
			r._die(0)
			r.hitstop_ticks = 0
	pump.run(2, fn)
	var w2: int = host.lockstep.executed + DELAY + 1
	h.withheld[1] = [w2, 1 << 30]
	host.request_park(1)
	pump.run(16, fn)
	_check("the last LIVE slot parked", host.slot_state[1], host.SlotState.ABSENT)
	_check("nobody is LIVE", host.alive, false)
	_check("the host holds a loss candidate", host._session.end_outcome, NetworkSession.Outcome.LOSS)
	h.teardown()
	await process_frame
	finished["a_dead_slot_parks_and_the_last_live_park_is_a_loss_candidate"] = true

func a_pre_start_leave_is_a_lobby_removal() -> void:
	var s := NetworkSession.host_lobby({"slot": 0, "name": "host",
		"counters": SaveGame.session_counters()}, 7, 1)
	var hello := {"name": "a", "counters": SaveGame.session_counters(), "slot": -1, "session_id": 0}
	_check("a joiner takes slot one", s.admit(hello, 5), 1)
	s.remove_peer(5)
	_check("leaving before START frees the slot", s.free_slot(), 1)
	s.admit(hello, 6)
	s.start()
	s.remove_peer(6)
	_check("leaving after START keeps the roster row", s.profile(1).is_empty(), false)
	finished["a_pre_start_leave_is_a_lobby_removal"] = true

func raw_input_from_an_unbound_peer_is_cut() -> void:
	var desc := NetworkSession.validate_descriptor({
		"protocol": SessionRules.PROTOCOL, "session_id": 1, "seed": 1, "delay": DELAY,
		"choice_timeout": 0, "roster": [{"slot": 0, "name": "h", "counters": SaveGame.session_counters()},
			{"slot": 1, "name": "c", "counters": SaveGame.session_counters()}]})
	var t := Transport.new()
	t.session = NetworkSession.create(desc, 0, NetworkSession.Role.HOST)
	t.session.started = true
	t.is_host = true
	t._handle(9, Transport.CH_INPUT, Protocol.encode_input(1, 5, Vector2.ZERO, -1, -1, -1))
	_check("input from a peer holding no slot cuts that peer", t.dropped_peers, [9])
	_check("and is not counted as a malformed packet", t.malformed_total, 0)
	t.free()
	finished["raw_input_from_an_unbound_peer_is_cut"] = true

func a_client_treats_host_loss_as_stop_and_hello() -> void:
	var h := await _setup(2)
	var pump := RosterPump.new(h)
	var fn := _fn(h)
	pump.run(20, fn)
	var host: Node2D = h.runs[0]
	var client: Node2D = h.runs[1]
	var ended := []
	client.run_ended.connect(func(w, _s): ended.append(w))
	var t := Transport.new()
	client.add_child(t)
	client.attach_transport(t)
	t.session = client._session
	var exec_before: int = client.lockstep.executed
	# The host goes silent: the transport reports it gone.
	t.peer_left.emit(Transport.HOST_PEER)
	_check("the client stops and reconnects", client._session.reconnecting, true)
	_check("one attempt is on record", client._reconnect_attempts, 1)
	for _i in 5:
		client._physics_process(MultiplayerHarness.DT)
	_check("the world holds while reconnecting", client.lockstep.executed, exec_before)
	_check("the harness leaves a reconnecting peer alone", h.step_one(1, fn), false)
	# The host never enters that state: there is no migration.
	host._on_peer_left(99)
	_check("a host never reconnects", host._session.reconnecting, false)
	# Attempts run out.
	for _i in client.RECONNECT_ATTEMPTS:
		client._begin_reconnect()
	_check("after the attempts the run ends as a loss, once", ended, [false])
	t.close()
	h.teardown()
	await process_frame
	finished["a_client_treats_host_loss_as_stop_and_hello"] = true
