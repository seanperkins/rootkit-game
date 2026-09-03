extends SceneTree

## The transport, against real ENet on the loopback interface: a host and a
## client in one process. What is pinned is the wire discipline lockstep
## depends on — two user channels, reliable ordered input that survives
## withheld polling, one relay bundle per peer per tick, a full-size snapshot
## that does not hold up the input channel, the three-second park, malformed
## packets counted and eventually cut, and the codec's three distinct tick
## windows.

var failures := 0
var finished := {}

const PORT := 43217
const CASES := ["reliable_input_survives_withheld_polling", "one_relay_bundle_per_tick",
	"a_snapshot_does_not_delay_input", "pings_and_counters", "tick_windows_are_distinct",
	"foreign_envelopes_are_refused", "a_join_after_start_is_refused",
	"malformed_packets_are_counted_then_cut", "silence_parks_after_three_seconds"]

var host_t: Transport
var client_t: Transport
var hs: NetworkSession
var cs: NetworkSession
var client_id := -1
var left_ids: Array = []
var snapshots: Array = []

func _initialize() -> void:
	print("ROOTKIT — transport loopback\n")
	SaveGame.use_fresh_state()
	if not await _connect():
		print("  FAIL  could not establish a loopback connection")
		failures += 1
		quit(1)
		return
	reliable_input_survives_withheld_polling()
	one_relay_bundle_per_tick()
	a_snapshot_does_not_delay_input()
	pings_and_counters()
	tick_windows_are_distinct()
	foreign_envelopes_are_refused()
	a_join_after_start_is_refused()
	malformed_packets_are_counted_then_cut()
	await silence_parks_after_three_seconds()
	host_t.close()
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
		"session_id": 77, "seed": 1, "delay": 2, "choice_timeout": 0, "roster": rows})

func _ring() -> Lockstep:
	var ls := Lockstep.new(SessionRules.MAX_PLAYERS, 2)
	ls.mark_absent(2)
	ls.mark_absent(3)
	ls.prime(0, 1)
	return ls

## Pump both ends for `ms` milliseconds.
func _pump(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		if host_t != null:
			host_t.poll()
		if client_t != null:
			client_t.poll()
		OS.delay_msec(2)

func _new_client() -> Transport:
	cs = NetworkSession.create(_descriptor(), 1, NetworkSession.Role.CLIENT)
	cs.lockstep = _ring()
	var t := Transport.new()
	root.add_child(t)
	t.snapshot_received.connect(func(tick, bytes): snapshots.append([tick, bytes]))
	t.join("127.0.0.1", PORT, cs)
	t.bind_peer(Transport.HOST_PEER, 0)
	return t

func _connect() -> bool:
	hs = NetworkSession.create(_descriptor(), 0, NetworkSession.Role.HOST)
	hs.lockstep = _ring()
	host_t = Transport.new()
	root.add_child(host_t)
	host_t.peer_joined.connect(func(id): client_id = id; host_t.bind_peer(id, 1))
	host_t.peer_left.connect(func(id): left_ids.append(id))
	var err := host_t.host(PORT, hs)
	_check("the host binds its port", err, OK)
	client_t = _new_client()
	var t0 := Time.get_ticks_msec()
	while client_id < 0 and Time.get_ticks_msec() - t0 < 3000:
		_pump(10)
	_check_true("the client connected and was bound to slot one", client_id > 0)
	return client_id > 0

func _has(ls: Lockstep, slot: int, tick: int) -> bool:
	var cell: int = tick & (Lockstep.RING - 1)
	return ls._tick_tag[cell] == tick and (ls._have[cell] & (1 << slot)) != 0

## Three records sent while the host is NOT polling all arrive, in order, once
## it does: reliable ordered delivery, which is what lets the input delay
## absorb a hiccup instead of losing a tick forever.
func reliable_input_survives_withheld_polling() -> void:
	for tick in [2, 3, 4]:
		client_t.send_input(tick, Vector2(0.1 * tick, 0.0), tick, 0, 9)
	OS.delay_msec(60)
	client_t.poll()
	# The host polls only NOW, after three input intervals of silence.
	host_t.poll()
	_pump(50)
	var ok := true
	for tick in [2, 3, 4]:
		if not _has(hs.lockstep, 1, tick):
			ok = false
	_check("all three withheld records arrived", ok, true)
	var o := [PackedVector2Array(), PackedInt32Array(), PackedInt32Array(), PackedInt32Array()]
	for a in o:
		a.resize(SessionRules.MAX_PLAYERS)
	hs.lockstep.submit(0, 2, Vector2.ZERO, -1, -1, -1)
	hs.lockstep.take(0, o[0], o[1], o[2], o[3])
	hs.lockstep.take(1, o[0], o[1], o[2], o[3])
	_check_true("tick two is consumable with the client's record", hs.lockstep.take(2, o[0], o[1], o[2], o[3]))
	_check("the record's fields arrived verbatim", [o[0][1], o[1][1], o[3][1]],
		[Vector2(0.2, 0.0), 2, 9])
	_check("nothing was refused", host_t.malformed_total, 0)
	finished["reliable_input_survives_withheld_polling"] = true

## Whatever the host received and submitted since its last flush goes to each
## client as ONE reliable RELAY, never as a forward per incoming INPUT.
func one_relay_bundle_per_tick() -> void:
	# Two more client records (already sent tick 3 and 4 above are staged) plus
	# the host's own records for ticks 3..5 and a checksum, then one flush.
	for tick in [3, 4, 5]:
		host_t.send_input(tick, Vector2(0.5, 0.5), -1, -1, -1)
	host_t.send_checksum(1, 12345)
	client_t.send_input(5, Vector2(0.0, 0.3), -1, -1, -1)
	_pump(30)                              # the host receives tick 5
	var before := host_t.relays_sent
	var got_before := client_t.relays_received
	host_t.flush_relay(5)
	_pump(40)
	_check("exactly one bundle per flush reached the client",
		client_t.relays_received - got_before, 1)
	_check("the host counted one relay per peer", host_t.relays_sent - before, 1)
	_check_true("the bundle carried the host's records for the client's ring",
		_has(cs.lockstep, 0, 3) and _has(cs.lockstep, 0, 4) and _has(cs.lockstep, 0, 5))
	_check("and the checksum report", cs.lockstep._checksums.has(1), true)
	_check("nothing was refused", client_t.malformed_total, 0)
	finished["one_relay_bundle_per_tick"] = true

## A snapshot at the size cap on channel 1 while a relay goes out on channel 0:
## the relay's records are in the client's ring no later than the snapshot
## lands, because the two channels do not share an order.
func a_snapshot_does_not_delay_input() -> void:
	var big := PackedByteArray()
	big.resize(SessionRules.SNAPSHOT_MAX - 64)
	for k in range(0, big.size(), 4099):
		big[k] = 7
	snapshots.clear()
	host_t.send_snapshot(client_id, 4, big)
	host_t.send_input(6, Vector2(0.9, 0.0), -1, -1, -1)
	host_t.flush_relay(6)
	var input_at := -1
	var snap_at := -1
	var polls := 0
	var t0 := Time.get_ticks_msec()
	while (input_at < 0 or snap_at < 0) and Time.get_ticks_msec() - t0 < 4000:
		host_t.poll()
		client_t.poll()
		polls += 1
		if input_at < 0 and _has(cs.lockstep, 0, 6):
			input_at = polls
		if snap_at < 0 and not snapshots.is_empty():
			snap_at = polls
		OS.delay_msec(1)
	_check_true("the relayed input arrived", input_at > 0)
	_check_true("the snapshot arrived", snap_at > 0)
	_check_true("the input was not held behind the snapshot", input_at <= snap_at)
	if not snapshots.is_empty():
		_check("the snapshot arrived intact", (snapshots[0][1] as PackedByteArray).size(), big.size())
		_check("labelled with its tick", snapshots[0][0], 4)
	finished["a_snapshot_does_not_delay_input"] = true

## The ping heartbeat: each side sends PINGs over channel 0, the peer echoes
## a PONG with the probe's timestamp, and the RTT lands per slot — never in
## the session inbox — while the packet and record counters track the flow.
func pings_and_counters() -> void:
	# The heartbeat only runs once a session is STARTED: before that the
	# host's descriptor is empty and a probe would be refused as foreign.
	hs.started = true
	cs.started = true
	var inbox_before: int = hs.inbox.size() + cs.inbox.size()
	var malformed_total_before: int = host_t.malformed_total + client_t.malformed_total
	client_t.send_input(7, Vector2(0.2, 0.4), 0, 0, 0)
	var t0 := Time.get_ticks_msec()
	var saw_rtt := -1
	# Several PING intervals, so a missed beat cannot fail the case.
	while Time.get_ticks_msec() - t0 < 2500:
		host_t.poll()
		client_t.poll()
		OS.delay_msec(5)
		if saw_rtt < 0 and host_t.ping_ms.has(1):
			saw_rtt = int(host_t.ping_ms[1])
	_check_true("the host measured the client's round trip", saw_rtt >= 0)
	_check("on a loopback it stayed small", saw_rtt >= 0 and saw_rtt <= 100, true)
	_check_true("the client measured the host's round trip",
		client_t.ping_ms.has(0))
	_check("PING/PONG never reached the session inbox",
		hs.inbox.size() + cs.inbox.size(), inbox_before)
	_check("and nothing was refused", host_t.malformed_total + client_t.malformed_total,
		malformed_total_before)
	_check("the host's record counter ran", host_t.input_records_received > 0, true)
	_check("per-slot, too", int(host_t.slot_records_in.get(1, 0)) > 0, true)
	_check("packet counters ran on both sides",
		host_t.packets_in > 0 and client_t.packets_out > 0, true)
	_check("the stats snapshot carries the diagnostics",
		host_t.net_stats().has("ping") and client_t.net_stats().has("packets_out"), true)
	finished["pings_and_counters"] = true

## The codec keeps three separate windows: input records ahead of executed,
## checksum reports behind it, and announced boundaries a delay-plus-margin
## into the future. None accepts a tick another would.
func tick_windows_are_distinct() -> void:
	var ctx := {"executed": 100, "delay": 4, "boundary": -1}
	var M := Protocol.Message
	_check("input at executed is accepted", Protocol.valid_tick(M.INPUT, 100, ctx), true)
	_check("input behind executed is refused", Protocol.valid_tick(M.INPUT, 99, ctx), false)
	_check("input at the ring edge is refused",
		Protocol.valid_tick(M.INPUT, 100 + Lockstep.RING, ctx), false)
	_check("a checksum at executed is accepted", Protocol.valid_tick(M.CHECKSUM, 100, ctx), true)
	_check("a checksum just ahead of executed is kept for a slower peer",
		Protocol.valid_tick(M.CHECKSUM, 101, ctx), true)
	_check("a checksum a ring ahead is refused",
		Protocol.valid_tick(M.CHECKSUM, 100 + Lockstep.RING, ctx), false)
	_check("a checksum a ring behind is accepted",
		Protocol.valid_tick(M.CHECKSUM, 100 - Lockstep.RING, ctx), true)
	_check("but not past the retained window",
		Protocol.valid_tick(M.CHECKSUM, 100 - Lockstep.RING - 1, ctx), false)
	_check("a boundary inside delay + margin is refused",
		Protocol.valid_tick(M.RESYNC, 106, ctx), false)
	_check("a boundary at delay + margin is accepted",
		Protocol.valid_tick(M.RESYNC, 107, ctx), true)
	_check("a boundary past the ring is refused",
		Protocol.valid_tick(M.END_CHECK, 100 + Lockstep.RING + 1, ctx), false)
	var armed := {"executed": 100, "delay": 4, "boundary": 150}
	_check("with a boundary armed, input is judged against it",
		Protocol.valid_tick(M.INPUT, 151, armed), true)
	_check("and input at the old executed is refused",
		Protocol.valid_tick(M.INPUT, 100, armed), false)
	finished["tick_windows_are_distinct"] = true

## A wrong protocol byte or a foreign session id never reaches a body decode;
## only HELLO is exempt from the session check, because a fresh joiner has none.
func foreign_envelopes_are_refused() -> void:
	var ctx := {"session_id": 77}
	var good := Protocol.encode_input(77, 5, Vector2.ONE, 0, 0, 0)
	_check_true("a well-formed envelope decodes", not Protocol.decode_envelope(good, ctx).is_empty())
	var bad_proto := good.duplicate()
	bad_proto[0] = SessionRules.PROTOCOL + 1
	_check("a wrong protocol is refused", Protocol.decode_envelope(bad_proto, ctx).is_empty(), true)
	var other := Protocol.encode_input(78, 5, Vector2.ONE, 0, 0, 0)
	_check("a foreign session is refused", Protocol.decode_envelope(other, ctx).is_empty(), true)
	var hello := Protocol.encode_control(Protocol.Message.HELLO, 0, 0,
		{"protocol": SessionRules.PROTOCOL, "name": "x", "slot": -1})
	_check_true("a HELLO with no session is accepted by the envelope",
		not Protocol.decode_envelope(hello, ctx).is_empty())
	var short := good.slice(0, 10)
	_check("a truncated envelope is refused", Protocol.decode_envelope(short, ctx).is_empty(), true)
	var lied := good.duplicate()
	lied[10] = 99                          # declared body length no longer matches
	_check("a declared length that does not match is refused",
		Protocol.decode_envelope(lied, ctx).is_empty(), true)
	finished["foreign_envelopes_are_refused"] = true

## Once the host has STARTED, a fresh HELLO is refused at the transport and never
## reaches the inbox; a reconnect naming the session and an existing slot does.
func a_join_after_start_is_refused() -> void:
	hs.started = true
	hs.inbox.clear()
	var before := host_t.malformed_total
	client_t.send_control(Protocol.Message.HELLO, 0, {"protocol": SessionRules.PROTOCOL,
		"name": "late", "session_id": 0, "slot": -1, "counters": {}})
	_pump(40)
	_check("a new participant after START is refused", host_t.malformed_total - before, 1)
	_check("and never reaches the inbox", hs.inbox.size(), 0)
	client_t.send_control(Protocol.Message.HELLO, 0, {"protocol": SessionRules.PROTOCOL,
		"name": "back", "session_id": 77, "slot": 1, "counters": {}})
	_pump(40)
	_check("a reconnect to an existing slot is delivered", hs.inbox.size(), 1)
	_check("as a HELLO", int(hs.inbox[0]["kind"]) if not hs.inbox.is_empty() else -1,
		Protocol.Message.HELLO)
	hs.started = false
	hs.inbox.clear()
	finished["a_join_after_start_is_refused"] = true

## Garbage is dropped and counted per peer; at BAD_PACKETS the peer is cut.
func malformed_packets_are_counted_then_cut() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var before := host_t.malformed_total
	var peer_before := int(host_t.bad_packets.get(client_id, 0))
	for k in 5:
		var junk := PackedByteArray()
		for j in 40:
			junk.append(rng.randi_range(0, 255))
		client_t.peer.set_target_peer(Transport.HOST_PEER)
		client_t.peer.set_transfer_channel(0)
		client_t.peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		client_t.peer.put_packet(junk)
	_pump(60)
	_check("five junk packets were counted", host_t.malformed_total - before, 5)
	_check("against the sending peer",
		int(host_t.bad_packets.get(client_id, 0)) - peer_before, 5)
	_check("and the peer is still connected", left_ids.has(client_id), false)
	for k in SessionRules.BAD_PACKETS:
		client_t.peer.set_target_peer(Transport.HOST_PEER)
		client_t.peer.put_packet(PackedByteArray([1, 2, 3]))
	var t0 := Time.get_ticks_msec()
	while not left_ids.has(client_id) and Time.get_ticks_msec() - t0 < 3000:
		_pump(10)
	_check("at BAD_PACKETS the peer was cut", left_ids.has(client_id), true)
	client_t.close()
	client_t.queue_free()
	client_t = null
	finished["malformed_packets_are_counted_then_cut"] = true

## A peer that goes silent is gone after PEER_TIMEOUT_MS — not ENet's longer
## default — so a dropped player is parked in seconds.
func silence_parks_after_three_seconds() -> void:
	left_ids.clear()
	client_id = -1
	client_t = _new_client()
	var t0 := Time.get_ticks_msec()
	while client_id < 0 and Time.get_ticks_msec() - t0 < 3000:
		_pump(10)
	_check_true("a fresh client connected", client_id > 0)
	var cut := client_id
	# Silence: the client is never polled again, so it sends nothing at all.
	var quiet := client_t
	client_t = null
	var t1 := Time.get_ticks_msec()
	while not left_ids.has(cut) and Time.get_ticks_msec() - t1 < 8000:
		host_t.poll()
		OS.delay_msec(5)
	var waited := Time.get_ticks_msec() - t1
	_check("the silent peer was parked", left_ids.has(cut), true)
	_check_true("after about the session timeout, not ENet's default (%d ms)" % waited,
		waited >= SessionRules.PEER_TIMEOUT_MS - 200 and waited < 7000)
	quiet.close()
	quiet.queue_free()
	await process_frame
	finished["silence_parks_after_three_seconds"] = true
