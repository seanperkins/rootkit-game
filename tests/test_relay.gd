extends SceneTree

## Two transports through an in-process relay: the room handshake, the
## lobby's HELLO/WELCOME through NetworkSession, inputs and a relay bundle
## into both rings, a joiner leaving, and the host closing the room.
## Needs real UDP on 127.0.0.1, like the loopback suite.

var failures := 0
var finished := {}
const PORT := 43218
const CASES := ["a_room_is_created_and_joined", "the_lobby_handshake_crosses_the_relay",
	"records_cross_both_ways", "a_leaving_joiner_is_reported", "closing_the_host_closes_the_room",
	"a_rejoin_asked_for_inside_the_close_still_reads_closed"]

var relay := RelayServer.new()
var host_t: Transport
var client_t: Transport
var hs: NetworkSession
var cs: NetworkSession
var host_code := ""
var joined_ids: Array = []
var left_host: Array = []
var left_client: Array = []

func _initialize() -> void:
	print("ROOTKIT — relay end to end\n")
	SaveGame.use_fresh_state()
	if relay.start(PORT) != OK:
		print("  FAIL  could not bind the relay port")
		quit(1)
		return
	await a_room_is_created_and_joined()
	the_lobby_handshake_crosses_the_relay()
	records_cross_both_ways()
	a_leaving_joiner_is_reported()
	closing_the_host_closes_the_room()
	a_rejoin_asked_for_inside_the_close_still_reads_closed()
	relay.stop()
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

func _descriptor() -> Dictionary:
	var rows := []
	for s in 2:
		rows.append({"slot": s, "name": "p%d" % s, "counters": SaveGame.session_counters()})
	return NetworkSession.validate_descriptor({"protocol": SessionRules.PROTOCOL,
		"session_id": 78, "seed": 1, "delay": 2, "choice_timeout": 0, "roster": rows})

func _ring() -> Lockstep:
	var ls := Lockstep.new(SessionRules.MAX_PLAYERS, 2)
	ls.mark_absent(2)
	ls.mark_absent(3)
	ls.prime(0, 1)
	return ls

func _pump(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		relay.poll(Time.get_ticks_msec())
		if host_t != null:
			host_t.poll()
		if client_t != null:
			client_t.poll()
		OS.delay_msec(2)

func _has(ls: Lockstep, slot: int, tick: int) -> bool:
	var cell: int = tick & (Lockstep.RING - 1)
	return ls._tick_tag[cell] == tick and (ls._have[cell] & (1 << slot)) != 0

func a_room_is_created_and_joined() -> void:
	hs = NetworkSession.create(_descriptor(), 0, NetworkSession.Role.HOST)
	hs.lockstep = _ring()
	host_t = Transport.new()
	root.add_child(host_t)
	host_t.room_ready.connect(func(c): host_code = c)
	host_t.peer_joined.connect(func(id): joined_ids.append(id); host_t.bind_peer(id, 1))
	host_t.peer_left.connect(func(id): left_host.append(id))
	# The suite's relay, not the baked address: the transport takes an
	# address override so the loopback relay can stand in.
	_check("hosting through the relay starts", host_t.host_relayed(hs, "127.0.0.1", PORT), OK)
	var t0 := Time.get_ticks_msec()
	while host_code == "" and Time.get_ticks_msec() - t0 < 3000:
		_pump(10)
	_check_true("the host received a room code", RelayFrame.is_code(host_code))
	_check("the host is member 1", host_t.member, 1)
	_check("and is connected", host_t.connected(), true)

	cs = NetworkSession.create(_descriptor(), 1, NetworkSession.Role.CLIENT)
	cs.lockstep = _ring()
	client_t = Transport.new()
	root.add_child(client_t)
	var client_saw_host := []
	client_t.peer_joined.connect(func(id): client_saw_host.append(id); client_t.bind_peer(Transport.HOST_PEER, 0))
	client_t.peer_left.connect(func(id): left_client.append(id))
	_check("joining with the code starts", client_t.join_relayed(host_code.to_lower(), cs, "127.0.0.1", PORT), OK)
	t0 = Time.get_ticks_msec()
	while (joined_ids.is_empty() or client_saw_host.is_empty()) and Time.get_ticks_msec() - t0 < 3000:
		_pump(10)
	_check("the host saw member 2 join", joined_ids, [2])
	_check("the joiner sees the host as peer 1", client_saw_host, [Transport.HOST_PEER])
	_check("the joiner is member 2", client_t.member, 2)
	finished["a_room_is_created_and_joined"] = true

func the_lobby_handshake_crosses_the_relay() -> void:
	# A HELLO from the joiner lands in the host session's inbox with the
	# joiner's member id as its peer — exactly what the lobby's admit needs.
	client_t.send_control(Protocol.Message.HELLO, 0, {"protocol": SessionRules.PROTOCOL,
		"name": "p1", "counters": SaveGame.session_counters(), "session_id": 0, "slot": -1})
	_pump(80)
	var got := {}
	while not hs.inbox.is_empty():
		got = hs.inbox.pop_front()
	_check("the host's inbox holds the HELLO", int(got.get("kind", -1)), Protocol.Message.HELLO)
	_check("from member 2", int(got.get("peer", -1)), 2)
	host_t.send_control(Protocol.Message.WELCOME, 0, {"descriptor": _descriptor(), "slot": 1}, 2)
	_pump(80)
	var back := {}
	while not cs.inbox.is_empty():
		back = cs.inbox.pop_front()
	_check("the joiner's inbox holds the WELCOME", int(back.get("kind", -1)), Protocol.Message.WELCOME)
	finished["the_lobby_handshake_crosses_the_relay"] = true

func records_cross_both_ways() -> void:
	client_t.send_input(2, Vector2(0.25, 0.0), 3, 0, 9, Vector2(0.0, -1.0))
	_pump(80)
	_check("the joiner's record reached the host ring", _has(hs.lockstep, 1, 2), true)
	host_t.send_input(2, Vector2(-0.5, 0.0), -1, -1, -1)
	host_t.flush_relay(2)
	_pump(80)
	_check("the host's bundle reached the joiner ring", _has(cs.lockstep, 0, 2), true)
	_check("nothing was refused", host_t.malformed_total + client_t.malformed_total, 0)
	finished["records_cross_both_ways"] = true

func a_leaving_joiner_is_reported() -> void:
	client_t.close()
	var t0 := Time.get_ticks_msec()
	while left_host.is_empty() and Time.get_ticks_msec() - t0 < 5000:
		_pump(10)
	_check("the host saw member 2 leave", left_host, [2])
	finished["a_leaving_joiner_is_reported"] = true

func closing_the_host_closes_the_room() -> void:
	cs = NetworkSession.create(_descriptor(), 1, NetworkSession.Role.CLIENT)
	cs.lockstep = _ring()
	client_t = Transport.new()
	root.add_child(client_t)
	var saw := []
	client_t.peer_joined.connect(func(id): saw.append(id))
	client_t.peer_left.connect(func(id): left_client.append(id))
	client_t.join_relayed(host_code, cs, "127.0.0.1", PORT)
	var t0 := Time.get_ticks_msec()
	while saw.is_empty() and Time.get_ticks_msec() - t0 < 3000:
		_pump(10)
	_check("a rejoin with the same code works", saw, [Transport.HOST_PEER])
	host_t.close()
	t0 = Time.get_ticks_msec()
	while left_client.is_empty() and Time.get_ticks_msec() - t0 < 5000:
		_pump(10)
	_check("the joiner saw the host go", left_client, [Transport.HOST_PEER])
	_check("and knows why", client_t.relay_error, "closed")
	client_t.close()
	finished["closing_the_host_closes_the_room"] = true

## The run reconnects from peer_left, which the transport raises from inside
## peer.poll() when the link drops. Re-dialing right there replaced the peer
## before its queued packets were read, and the relay's "closed" op is queued
## exactly then — just ahead of the disconnect it announces — so the run read
## "lost", rejoined a dead room ten times and ended half a minute later.
func a_rejoin_asked_for_inside_the_close_still_reads_closed() -> void:
	hs = NetworkSession.create(_descriptor(), 0, NetworkSession.Role.HOST)
	hs.lockstep = _ring()
	host_t = Transport.new()
	root.add_child(host_t)
	# A member, not a local: a lambda captures a local by value.
	host_code = ""
	host_t.room_ready.connect(func(c): host_code = c)
	host_t.peer_joined.connect(func(id): host_t.bind_peer(id, 1))
	host_t.host_relayed(hs, "127.0.0.1", PORT)
	var t0 := Time.get_ticks_msec()
	while host_code == "" and Time.get_ticks_msec() - t0 < 3000:
		_pump(10)
	cs = NetworkSession.create(_descriptor(), 1, NetworkSession.Role.CLIENT)
	cs.lockstep = _ring()
	client_t = Transport.new()
	root.add_child(client_t)
	var saw := []
	var errs := []
	client_t.peer_joined.connect(func(id): saw.append(id))
	# What the run does: rejoin at once, from inside the signal.
	client_t.peer_left.connect(func(_id): errs.append(client_t.rejoin()))
	client_t.join_relayed(host_code, cs, "127.0.0.1", PORT)
	t0 = Time.get_ticks_msec()
	while saw.is_empty() and Time.get_ticks_msec() - t0 < 3000:
		_pump(10)
	_check("the joiner is in the new room", saw, [Transport.HOST_PEER])
	var refused_before: int = relay.rooms.refused
	host_t.close()
	_pump(1500)
	_check("the joiner read the relay's closed, not a lost link", client_t.relay_error, "closed")
	_check_true("the rejoin asked for inside the signal was accepted quietly", not errs.is_empty())
	_check("and no rejoin was dialed at a dead room", relay.rooms.refused - refused_before, 0)
	_check("a rejoin after a close is refused locally", client_t.rejoin(), ERR_UNAVAILABLE)
	client_t.close()
	finished["a_rejoin_asked_for_inside_the_close_still_reads_closed"] = true
