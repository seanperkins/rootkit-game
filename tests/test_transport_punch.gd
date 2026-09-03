extends SceneTree

## One host-client star leg through an in-process relay. The room and discovery
## sockets are real UDP: both transports register the exact bound direct socket,
## simultaneous-open it, move records over it, then tear it down and keep moving
## records through the relay without changing the logical peer or ring.

const RELAY_PORT := 43220
const PUNCH_PORT := 43221
## One-sided loss is only detected by ENet's own 3 s peer timeout; the
## seam wait must comfortably outlive it.
const WAIT_MS := 7000

var failures := 0
var relay := RelayServer.new()
var host_t: Transport
var client_t: Transport
var hs: NetworkSession
var cs: NetworkSession
var room_code := ""

func _initialize() -> void:
	print("ROOTKIT — punched transport\n")
	SaveGame.use_fresh_state()
	if relay.start(RELAY_PORT, PUNCH_PORT) != OK:
		print("  FAIL  could not bind relay/punch ports")
		quit(1)
		return
	await direct_path_and_fallback()
	relay.stop()
	print("")
	if failures == 0: print("  PASS — direct link and relay fallback")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _descriptor() -> Dictionary:
	var rows := []
	for slot in 2:
		rows.append({"slot": slot, "name": "p%d" % slot,
			"counters": SaveGame.session_counters()})
	return NetworkSession.validate_descriptor({"protocol": SessionRules.PROTOCOL,
		"session_id": 91, "seed": 1, "delay": 2, "choice_timeout": 0,
		"roster": rows})

func _ring() -> Lockstep:
	var ring := Lockstep.new(SessionRules.MAX_PLAYERS, 2)
	ring.mark_absent(2)
	ring.mark_absent(3)
	ring.prime(0, 1)
	return ring

func _pump(ms: int) -> void:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < ms:
		relay.poll(Time.get_ticks_msec())
		if host_t != null: host_t.poll()
		if client_t != null: client_t.poll()
		OS.delay_msec(2)

func _wait_until(predicate: Callable, timeout_ms: int = WAIT_MS) -> bool:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < timeout_ms:
		_pump(10)
		if predicate.call():
			return true
	return false

func _has(ring: Lockstep, slot: int, tick: int) -> bool:
	var cell: int = tick & (Lockstep.RING - 1)
	return ring._tick_tag[cell] == tick and (ring._have[cell] & (1 << slot)) != 0

func direct_path_and_fallback() -> void:
	hs = NetworkSession.create(_descriptor(), 0, NetworkSession.Role.HOST)
	hs.lockstep = _ring()
	host_t = Transport.new()
	root.add_child(host_t)
	host_t.room_ready.connect(func(c): room_code = c)
	host_t.peer_joined.connect(func(id): host_t.bind_peer(id, 1))
	_check("host starts through relay",
		host_t.host_relayed(hs, "127.0.0.1", RELAY_PORT, PUNCH_PORT), OK)
	_check("host receives a room",
		await _wait_until(func(): return room_code != ""), true)

	cs = NetworkSession.create(_descriptor(), 1, NetworkSession.Role.CLIENT)
	cs.lockstep = _ring()
	client_t = Transport.new()
	root.add_child(client_t)
	client_t.peer_joined.connect(func(_id): client_t.bind_peer(Transport.HOST_PEER, 0))
	_check("client starts through relay",
		client_t.join_relayed(room_code, cs, "127.0.0.1", RELAY_PORT, PUNCH_PORT), OK)
	_check("both ends authenticate one direct star leg", await _wait_until(func():
		return host_t.direct_to(2) and client_t.direct_to(Transport.HOST_PEER)), true)
	_check("the host has no client-client link", host_t.direct_to(3), false)

	client_t.send_input(2, Vector2(0.25, 0.0), 3, 0, 9, Vector2(0.0, -1.0))
	_check("client input crosses direct", await _wait_until(func():
		return _has(hs.lockstep, 1, 2)), true)
	_check("client counted a direct send", client_t.direct_sent > 0, true)
	_check("host counted a direct receive", host_t.direct_received > 0, true)

	host_t.send_input(2, Vector2(-0.5, 0.0), -1, -1, -1)
	host_t.flush_relay(2)
	_check("host bundle crosses direct", await _wait_until(func():
		return _has(cs.lockstep, 0, 2)), true)
	_check("host counted a direct send", host_t.direct_sent > 0, true)
	_check("client counted a direct receive", client_t.direct_received > 0, true)

	# Fill the replay window with more duplicates than the malformed-packet
	# cutoff, then kill only the receiver's half. The sender's next reliable
	# send can still return OK before ENet reports the loss.
	for _i in SessionRules.BAD_PACKETS + 5:
		client_t.send_input(2, Vector2(0.25, 0.0), 3, 0, 9, Vector2(0.0, -1.0))
	_pump(100)
	_check("direct duplicates are not restaged", host_t._relay_records.size(), 0)
	host_t.disconnect_direct(2)
	_check("one-sided loss keeps the sender direct briefly",
		[host_t.direct_to(2), client_t.direct_to(Transport.HOST_PEER),
			host_t.connected(), client_t.connected()], [false, true, true, true])
	client_t.send_input(3, Vector2.RIGHT, -1, -1, -1)
	_check("the exact seam record replays through the relay",
		await _wait_until(func(): return _has(hs.lockstep, 1, 3) and not client_t.direct_to(Transport.HOST_PEER)), true)
	_check("the replay flood stages only the new record",
		host_t._relay_records.size(), 1)
	_check("replay duplicates count as no malformed packets",
		host_t.malformed_total + client_t.malformed_total, 0)
	host_t.send_input(3, Vector2.LEFT, -1, -1, -1)
	host_t.flush_relay(3)
	_check("host bundle crosses relay after fallback", await _wait_until(func():
		return _has(cs.lockstep, 0, 3)), true)

	# Candidate selection: one socket, one connect, the reflexive endpoint
	# named by the punch op. The op's local fields are carried and inert —
	# the socket never dials them, because a single ENetConnection cannot
	# retry after its one outgoing connect.
	host_t._begin_punch(2)
	var link: Transport.DirectLink = host_t._links[2]
	host_t._receive_punch({"member": 2, "host": "127.0.0.2", "port": 59999,
		"local_host": "127.0.0.1", "local_port": 59998, "key": "0123456789abcdef0123456789abcdef"})
	_check("the socket dials exactly the op's reflexive endpoint",
		[link.dialed, link.remote_host, link.remote_port], [true, "127.0.0.2", 59999])
	host_t.disconnect_direct(2)

	client_t.close()
	host_t.close()
	client_t.queue_free()
	host_t.queue_free()
	await process_frame
