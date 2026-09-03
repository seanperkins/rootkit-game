class_name Transport extends Node

## The ONE class that touches ENet. Everything it receives goes through the
## pure Protocol codec first; what survives is submitted to the session's
## lockstep ring (INPUT, RELAY), reported as a checksum, delivered to the
## session's inbox (control), or handed back as a snapshot. It counts every
## refused packet per peer and disconnects a peer at BAD_PACKETS. It applies
## the session timeout to every packet peer. The simulation never sees it: the
## run polls it above the world guard and reads records from the ring.
##
## One host, up to three clients, created with two user channels on both ends
## (a transfer_channel the peer was not created with is not a channel):
##   channel 0, reliable ordered   control, INPUT, RELAY
##   channel 0, unreliable         periodic CHECKSUM (a lost one is replaced)
##   channel 1, reliable           SNAPSHOT, so a large transfer never delays
##                                 the input stream on channel 0
## Raw put_packet / get_packet; no RPC, synchroniser or spawner.

const MAX_CLIENTS := SessionRules.MAX_PLAYERS - 1
const CHANNELS := 2
const CH_INPUT := 0
const CH_SNAPSHOT := 1
const HOST_PEER := 1
## Raw punch discovery is retried because it is deliberately one-way UDP.
## Direct ENet's connect packet is queued until service(), so raw probes are
## sent before the first service and alongside it until the handshake lands.
const DISCOVERY_RETRY_MS := 250
const PUNCH_RETRY_MS := 100
## One PING per second to every bound peer, both directions. A PONG echoes
## the probe's timestamp, so the round trip is measured on whatever path the
## probes take — channel 0, direct once punched — which is the path INPUT
## traffic actually uses, not some side channel.
const PING_INTERVAL_MS := 1000
## A peer cannot advance more than one lockstep ring ahead of a missing record.
## Retain that bounded window so one-sided direct failure can replay the seam
## over the still-live relay; duplicates are rejected by slot and absolute tick.
const DIRECT_REPLAY_MAX := Lockstep.RING

## One connection per host-client pair. Godot permits one outgoing
## connect_to_host per ENetConnection; the host therefore owns up to three of
## these (one per client) and a client owns exactly one (to member 1). This is
## the existing record-flow star, not a client-to-client mesh.
class DirectLink extends RefCounted:
	var target := -1
	var token := ""
	var key := ""
	var conn: ENetConnection = null
	var packet: ENetPacketPeer = null
	var remote_host := ""
	var remote_port := 0
	var local_host := ""
	var local_port := 0
	var deadline_ms := 0
	var next_discovery_ms := 0
	var next_punch_ms := 0
	var dialed := false
	var inbound_ready := false
	var direct := false
	var reported := false
	var replay: Array = [] # [channel, transfer_mode, immutable bytes]
	var replay_cursor := 0

signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
## A validated snapshot arrived: (tick, bytes). The run decides whether and
## when to restore it.
signal snapshot_received(tick: int, bytes: PackedByteArray)

var peer: ENetMultiplayerPeer = null
var session: NetworkSession = null
var is_host := false

## Peer id <-> slot, for peers past the handshake. The host binds them from the
## roster; a client binds only the host.
var slot_of_peer: Dictionary = {}
var peer_of_slot: Dictionary = {}

## Refused-packet counts per peer, and the running total.
var bad_packets: Dictionary = {}
var malformed_total := 0

## Always-on diagnostics, cheap integers: the HUD panel and --netlog read
## them, nothing in the simulation ever does. Packets and bytes are counted
## where they touch ENet; record counters are the logical INPUT records.
var packets_in := 0
var packets_out := 0
var bytes_in := 0
var bytes_out := 0
var input_records_sent := 0
var input_records_received := 0
## slot -> records newly stored from the wire, cumulative. The panel's
## per-slot arrival rate is the delta of this over a second.
var slot_records_in: Dictionary = {}
## slot -> last measured round trip in ms. Erased when the slot's peer goes,
## so a stale value can never outlive the link that produced it.
var ping_ms: Dictionary = {}
var _next_ping_ms := 0

## The host's outbound relay staging: records received or submitted since the
## last flush, as [slot, tick, move, card, target, offer], and checksum reports
## as [slot, tick, hash]. One RELAY per peer per flush carries all of it.
var _relay_records: Array = []
var _relay_checksums: Array = []
var relays_sent := 0
var relays_received := 0

## While a restore is pending (a RESYNC or HELLO boundary is announced), input
## records are held here keyed by absolute tick instead of being submitted to
## a ring that is about to be replaced. Task 13 arms this; it is drained after
## the transactional restore establishes the snapshot ring.
var boundary := -1
var _held: Array = []

## Where a client joined, so a dropped link can be re-made to the same host.
var _address := ""
var _port := 0
## Peers this transport cut itself: an unbound peer that sent input, or a
## parked one. Diagnostic; tests read it.
var dropped_peers: Array = []

## Relay mode: every peer, host included, is an ENet CLIENT of the relay,
## and the relay routes on a one-byte member id (relay/relay_frame.gd). The
## member id is what this class hands up as the peer id, so HOST_PEER, the
## bindings and every message path are the same as direct mode.
signal room_ready(code: String)
var relayed := false
var code := ""
var member := -1
## The last relay refusal reason, or "closed" (host gone) or "lost" (relay
## gone); "" while fine.
var relay_error := ""
var _relay_address := ""
var _relay_port := 0
var _relay_up := false           # the ENet link to the relay
var _polling := false            # inside poll(): listeners must not replace the peer
var _rejoin_pending := false     # a rejoin asked for from inside poll(), dialed after the drain
var _room_up := false            # the room answered
## Punching stays beside the relay, never in NetworkSession: address selection
## is local transport state and cannot enter the deterministic descriptor.
var _punch_discovery_port := 0
var _punch_token := ""
var _links: Dictionary = {}      # target member -> DirectLink
var direct_sent := 0
var direct_received := 0
var direct_fallbacks := 0

func host(port: int, p_session: NetworkSession) -> Error:
	session = p_session
	is_host = true
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_CLIENTS, CHANNELS)
	if err != OK:
		peer = null
		return err
	_wire()
	return OK

func join(address: String, port: int, p_session: NetworkSession) -> Error:
	if address.length() > SessionRules.ADDRESS_MAX:
		return ERR_INVALID_PARAMETER
	session = p_session
	is_host = false
	_address = address
	_port = port
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port, CHANNELS)
	if err != OK:
		peer = null
		return err
	_wire()
	return OK

## Host through the relay. `address`/`port` default to SessionRules and are
## overridable so the relay suite can stand a relay up on loopback.
func host_relayed(p_session: NetworkSession, address: String = SessionRules.RELAY_ADDRESS,
		port: int = SessionRules.RELAY_PORT,
		punch_port: int = SessionRules.PUNCH_DISCOVERY_PORT) -> Error:
	return _dial_relay(p_session, true, "", address, port, punch_port)

func join_relayed(room_code: String, p_session: NetworkSession,
		address: String = SessionRules.RELAY_ADDRESS, port: int = SessionRules.RELAY_PORT,
		punch_port: int = SessionRules.PUNCH_DISCOVERY_PORT) -> Error:
	if not RelayFrame.is_code(room_code):
		return ERR_INVALID_PARAMETER
	return _dial_relay(p_session, false, RelayFrame.normalise_code(room_code), address,
		port, punch_port)

func _dial_relay(p_session: NetworkSession, as_host: bool, room_code: String,
		address: String, port: int, punch_port: int) -> Error:
	if address == "" or address.length() > SessionRules.ADDRESS_MAX:
		return ERR_UNCONFIGURED
	session = p_session
	is_host = as_host
	relayed = true
	code = room_code
	member = -1
	relay_error = ""
	_relay_up = false
	_room_up = false
	_relay_address = address
	_relay_port = port
	_punch_discovery_port = punch_port
	_punch_token = ""
	_destroy_links()
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port, CHANNELS)
	if err != OK:
		peer = null
		return err
	_wire()
	return OK

func _wire() -> void:
	peer.peer_connected.connect(_on_peer_connected)
	peer.peer_disconnected.connect(_on_peer_disconnected)

func _on_peer_connected(id: int) -> void:
	# ENet's own timeout is longer than the session tolerates; three seconds
	# of silence parks a slot.
	var pp := peer.get_peer(id)
	if pp != null:
		pp.set_timeout(SessionRules.PEER_TIMEOUT_MS, SessionRules.PEER_TIMEOUT_MS,
			SessionRules.PEER_TIMEOUT_MS)
	if relayed:
		# The link to the relay is up: ask for a room. peer_joined waits for
		# the relay's answer, because a room is what "connected" means here.
		_relay_up = true
		var op := {"op": "create", "protocol": SessionRules.RELAY_PROTOCOL} if is_host \
			else {"op": "join", "code": code, "protocol": SessionRules.RELAY_PROTOCOL}
		_put_raw(HOST_PEER, CH_INPUT, MultiplayerPeer.TRANSFER_MODE_RELIABLE, RelayFrame.encode_op(op))
		return
	bad_packets[id] = 0
	peer_joined.emit(id)

func _on_peer_disconnected(id: int) -> void:
	if relayed:
		# The relay itself is gone: every member this end knew is gone with it.
		_relay_up = false
		_room_up = false
		_destroy_links()
		if relay_error == "":
			relay_error = "lost"
		for m in slot_of_peer.keys():
			peer_left.emit(int(m))
		slot_of_peer.clear()
		peer_of_slot.clear()
		return
	# Listeners first, while the binding still says which slot this was.
	peer_left.emit(id)
	if slot_of_peer.has(id):
		ping_ms.erase(int(slot_of_peer[id]))
		peer_of_slot.erase(int(slot_of_peer[id]))
		slot_of_peer.erase(id)

## A client's link is gone: make it again to the same host — or, relayed,
## the same room. The run then re-introduces itself with HELLO(session_id,
## slot) once the peer connects.
func rejoin() -> Error:
	if is_host:
		return ERR_UNCONFIGURED
	if relayed:
		if code == "":
			return ERR_UNCONFIGURED
		if relay_error == "closed":
			# The host closed the room. A rejoin with that code can only be
			# refused, and there is no host migration.
			return ERR_UNAVAILABLE
		if _polling:
			# Called from a listener inside poll() — the run's reconnect fires
			# from peer_left, which peer_disconnected raises from inside
			# peer.poll(). Replacing the peer there throws away every packet
			# it had queued but not yet handed over, and the relay's "closed"
			# op arrives exactly that way: just ahead of the disconnect it
			# announces. Dial after the drain instead.
			_rejoin_pending = true
			return OK
		return _rejoin_relay_now()
	if _address == "":
		return ERR_UNCONFIGURED
	close()
	return join(_address, _port, session)

func _rejoin_relay_now() -> Error:
	var saved := code
	close()
	return _dial_relay(session, false, saved, _relay_address, _relay_port,
		_punch_discovery_port)

## Cut one peer. Parking does this so a link that merely hiccupped cannot keep
## driving a slot nobody applies; so does input from a peer that never said
## HELLO. Relayed, the cut is a kick op: the id is a member, not a socket.
func drop_peer(id: int) -> void:
	dropped_peers.append(id)
	_destroy_link(id)
	if relayed:
		if is_host and _room_up:
			_put_raw(HOST_PEER, CH_INPUT, MultiplayerPeer.TRANSFER_MODE_RELIABLE,
				RelayFrame.encode_op({"op": "kick", "member": id}))
	elif peer != null:
		peer.disconnect_peer(id)
	if slot_of_peer.has(id):
		ping_ms.erase(int(slot_of_peer[id]))
		peer_of_slot.erase(int(slot_of_peer[id]))
		slot_of_peer.erase(id)

func connected() -> bool:
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	return _room_up if relayed else true

func bind_peer(peer_id: int, slot: int) -> void:
	slot_of_peer[peer_id] = slot
	peer_of_slot[slot] = peer_id

func close() -> void:
	_destroy_links()
	_punch_token = ""
	if peer != null:
		peer.close()
	peer = null
	slot_of_peer.clear()
	peer_of_slot.clear()
	ping_ms.clear()
	_relay_up = false
	_room_up = false

# ------------------------------------------------------------------ send ---

func _put(target: int, channel: int, mode: int, bytes: PackedByteArray,
		replayable: bool = false) -> void:
	if not relayed:
		_put_raw(target, channel, mode, bytes)
		return
	if target == MultiplayerPeer.TARGET_PEER_BROADCAST:
		# A relay broadcast cannot be mixed with direct sends: peers reached
		# directly would also receive the relay broadcast, and control messages
		# are not all duplicate-idempotent. Expand it into one path per bound
		# client, the same shape flush_relay already uses.
		if is_host:
			for id in slot_of_peer.keys():
				_put_member(int(id), channel, mode, bytes, replayable)
		else:
			_put_member(HOST_PEER, channel, mode, bytes, replayable)
		return
	_put_member(target, channel, mode, bytes, replayable)

func _put_member(target: int, channel: int, mode: int,
		bytes: PackedByteArray, replayable: bool) -> void:
	var link: DirectLink = _links.get(target)
	if link != null and link.direct and link.packet != null:
		var flags := ENetPacketPeer.FLAG_RELIABLE \
			if mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE else 0
		if link.packet.send(channel, bytes, flags) == OK:
			direct_sent += 1
			packets_out += 1
			bytes_out += bytes.size()
			if replayable:
				_remember_direct(link, channel, mode, bytes)
			return
		# The current bytes have not been retained yet, so replay the preceding
		# window and let this send fall through with the same bytes.
		direct_fallbacks += 1
		_destroy_link(target, true)
	_put_raw(HOST_PEER, channel, mode, RelayFrame.route(target, bytes))

func _put_raw(target: int, channel: int, mode: int, bytes: PackedByteArray) -> void:
	if peer == null:
		return
	packets_out += 1
	bytes_out += bytes.size()
	peer.set_target_peer(target)
	peer.set_transfer_channel(channel)
	peer.set_transfer_mode(mode)
	peer.put_packet(bytes)

func _session_id() -> int:
	return int(session.descriptor.get("session_id", 0)) if session != null else 0

## This peer's own record for a tick. A client sends it to the host; the host
## stages it for its next relay and needs no packet.
func send_input(tick: int, move: Vector2, card: int, target: int, offer: int,
		aim: Vector2 = Vector2.ZERO) -> void:
	input_records_sent += 1
	if is_host:
		_relay_records.append([session.local_slot, tick, move, card, target, offer, aim])
		return
	_put(HOST_PEER, CH_INPUT, MultiplayerPeer.TRANSFER_MODE_RELIABLE,
		Protocol.encode_input(_session_id(), tick, move, card, target, offer, aim), true)

## This peer's periodic checksum. Unreliable: a lost one is replaced by the
## next, and a stale one is refused by the retained window on arrival. The host
## bundles its own into the relay instead. NOT replayable: it self-heals, and
## keeping it in the bounded direct window would evict an INPUT record that
## cannot be recovered at the path seam.
func send_checksum(tick: int, hash_value: int) -> void:
	if is_host:
		_relay_checksums.append([session.local_slot, tick, hash_value])
		return
	_put(HOST_PEER, CH_INPUT, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE,
		Protocol.encode_checksum(_session_id(), tick, hash_value))

## The host's once-per-tick relay: ONE reliable bundle to every client carrying
## every record and checksum staged since the last flush. Never a forward per
## incoming INPUT.
func flush_relay(tick: int) -> void:
	if not is_host or peer == null:
		return
	if _relay_records.is_empty() and _relay_checksums.is_empty():
		return
	var bytes := Protocol.encode_relay(_session_id(), tick, _relay_records, _relay_checksums)
	for id in slot_of_peer.keys():
		_put(int(id), CH_INPUT, MultiplayerPeer.TRANSFER_MODE_RELIABLE, bytes, true)
		relays_sent += 1
	_relay_records.clear()
	_relay_checksums.clear()

## A control message, reliable on channel 0. `to` is a peer id; 0 broadcasts
## from the host, and a client always addresses the host.
func send_control(kind: int, tick: int, body: Dictionary, to: int = 0) -> void:
	var bytes := Protocol.encode_control(kind, _session_id(), tick, body)
	var target := to
	if not is_host:
		target = HOST_PEER
	elif to == 0:
		target = MultiplayerPeer.TARGET_PEER_BROADCAST
	_put(target, CH_INPUT, MultiplayerPeer.TRANSFER_MODE_RELIABLE, bytes)

## A snapshot to one peer, reliable on channel 1 so its fragments never queue
## ahead of channel 0's input.
func send_snapshot(to: int, tick: int, bytes: PackedByteArray) -> void:
	if bytes.size() > SessionRules.SNAPSHOT_MAX:
		return
	_put(to, CH_SNAPSHOT, MultiplayerPeer.TRANSFER_MODE_RELIABLE,
		Protocol.encode_snapshot(_session_id(), tick, bytes))

# --------------------------------------------------------------- receive ---

## Pump ENet and dispatch every packet that arrived. Called by the run above
## the world guard, and by the lobby.
func poll() -> void:
	if peer == null:
		return
	if peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		# A link that never connected — a refused rejoin, a dead address —
		# raises no signal and errors on every poll. The run's retry frames
		# make the next attempt; there is nothing to pump here.
		return
	_polling = true
	peer.poll()
	while peer != null and peer.get_available_packet_count() > 0:
		var from := peer.get_packet_peer()
		var channel := peer.get_packet_channel()
		var bytes := peer.get_packet()
		packets_in += 1
		bytes_in += bytes.size()
		if relayed:
			if RelayFrame.is_op(bytes):
				_relay_op(RelayFrame.decode_op(bytes))
				continue
			var parts := RelayFrame.unroute(bytes)
			if parts.is_empty():
				continue
			_handle(int(parts[0]), channel, parts[1])
		else:
			_handle(from, channel, bytes)
	_polling = false
	if relayed and _room_up:
		_poll_punch()
	_ping_step()
	if _rejoin_pending:
		_rejoin_pending = false
		# The drain may have delivered the relay's "closed": then the room
		# is gone and the rejoin the disconnect asked for has no target.
		if relay_error != "closed":
			_rejoin_relay_now()

## One PING to every bound peer per PING_INTERVAL_MS, over the same channel 0
## path game records use. Never called while the link is down; never touches
## the simulation. Gated on `started`: before START the host's descriptor is
## still empty (its session id is 0) while a client's already holds the id, so
## a probe sent in the lobby would be refused as a foreign session, counted,
## and — after BAD_PACKETS worth of one-per-second probes — cut the peer.
func _ping_step() -> void:
	if session == null or not session.started or not connected() \
			or slot_of_peer.is_empty():
		return
	var now := Time.get_ticks_msec()
	if now < _next_ping_ms:
		return
	_next_ping_ms = now + PING_INTERVAL_MS
	for id in slot_of_peer.keys():
		_put(int(id), CH_INPUT, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE,
			Protocol.encode_control(Protocol.Message.PING, _session_id(), 0, {"t": now}))

## One primitive snapshot of the always-on counters and the measured round
## trips, for the HUD panel and the netlog. Display only; nothing in the
## simulation reads it.
func net_stats() -> Dictionary:
	return {
		"packets_in": packets_in, "packets_out": packets_out,
		"bytes_in": bytes_in, "bytes_out": bytes_out,
		"records_in": input_records_received,
		"records_out": input_records_sent,
		"slot_records_in": slot_records_in.duplicate(),
		"ping": ping_ms.duplicate(),
		"relayed": relayed, "relay_error": relay_error,
		"direct_fallbacks": direct_fallbacks,
		"malformed": malformed_total,
		"relays_sent": relays_sent, "relays_received": relays_received,
	}

## The relay talking to this end: the room answer, roster changes, refusals.
func _relay_op(op: Dictionary) -> void:
	match str(op.get("op", "")):
		"room":
			_room_up = true
			member = int(op.get("member", -1))
			code = str(op.get("code", code))
			_punch_token = str(op.get("token", ""))
			if is_host:
				room_ready.emit(code)
			else:
				bad_packets[HOST_PEER] = 0
				peer_joined.emit(HOST_PEER)
				_begin_punch(HOST_PEER)
		"joined":
			var m := int(op.get("member", -1))
			if is_host and m >= 2 and m <= SessionRules.MAX_PLAYERS:
				bad_packets[m] = 0
				peer_joined.emit(m)
				_begin_punch(m)
		"punch":
			_receive_punch(op)
		"left":
			var m2 := int(op.get("member", -1))
			_destroy_link(m2)
			peer_left.emit(m2)
			if slot_of_peer.has(m2):
				ping_ms.erase(int(slot_of_peer[m2]))
				peer_of_slot.erase(int(slot_of_peer[m2]))
				slot_of_peer.erase(m2)
		"closed":
			relay_error = "closed"
			_room_up = false
			_destroy_links()
			ping_ms.clear()
			peer_left.emit(HOST_PEER)
			if slot_of_peer.has(HOST_PEER):
				peer_of_slot.erase(int(slot_of_peer[HOST_PEER]))
				slot_of_peer.erase(HOST_PEER)
		"refused":
			relay_error = str(op.get("reason", "bad"))
			_room_up = false
			_destroy_links()
			ping_ms.clear()

## Start one star leg. The relay room token authenticates this member; `target`
## makes the same token usable for the host's several dedicated sockets.
func _begin_punch(target: int) -> void:
	if not relayed or _punch_token == "" or _punch_discovery_port <= 0:
		return
	if (is_host and (target < 2 or target > SessionRules.MAX_PLAYERS)) \
			or (not is_host and target != HOST_PEER):
		return
	_destroy_link(target)
	var link := DirectLink.new()
	link.target = target
	link.token = _punch_token
	link.conn = ENetConnection.new()
	# Simultaneous open allocates this side's outgoing peer AND admits the
	# reciprocal connect while both are handshaking. One slot refuses the
	# incoming half; two is capacity for one logical link, not two targets.
	if link.conn.create_host_bound("0.0.0.0", 0, 2, CHANNELS) != OK:
		return
	link.local_port = link.conn.get_local_port()
	link.local_host = _local_candidate()
	var now := Time.get_ticks_msec()
	link.deadline_ms = now + SessionRules.PUNCH_TIMEOUT_MS
	_links[target] = link
	_send_discovery(link, now)

func _local_candidate() -> String:
	if _relay_address == "127.0.0.1" or _relay_address == "::1" \
			or _relay_address == "localhost":
		return "127.0.0.1"
	for address in IP.get_local_addresses():
		var host := str(address)
		if host.contains(":") or host.begins_with("127."):
			continue
		if host.is_valid_ip_address():
			return host
	return ""

## One-way on purpose: ENetConnection.socket_send emits from the SAME socket
## that will dial the peer, but ENet's service loop cannot surface an arbitrary
## raw UDP reply. The pair candidate comes back over the reliable relay link.
func _send_discovery(link: DirectLink, now_ms: int) -> void:
	if link.conn == null or link.dialed:
		return
	var op := {"op": "discover", "token": link.token, "target": link.target,
		"local_host": link.local_host, "local_port": link.local_port}
	link.conn.socket_send(_relay_address, _punch_discovery_port,
		RelayFrame.encode_op(op))
	link.next_discovery_ms = now_ms + DISCOVERY_RETRY_MS

func _receive_punch(op: Dictionary) -> void:
	var target := int(op.get("member", -1))
	var link: DirectLink = _links.get(target)
	if link == null or link.dialed:
		return
	var host := str(op.get("host", ""))
	var port := int(op.get("port", 0))
	var key := str(op.get("key", ""))
	if host == "" or host.length() > SessionRules.ADDRESS_MAX \
			or port <= 0 or port > 65535 or key.length() < 16 \
			or key.length() > SessionRules.RELAY_OP_MAX:
		_destroy_link(target)
		return
	link.key = key
	link.remote_host = host
	link.remote_port = port
	link.dialed = true
	var now := Time.get_ticks_msec()
	link.deadline_ms = now + SessionRules.PUNCH_TIMEOUT_MS
	link.next_punch_ms = now + PUNCH_RETRY_MS
	# Open the mapping before connect_to_host queues ENet's SYN. service() below
	# is what actually transmits the SYN.
	link.conn.socket_send(host, port, PackedByteArray([0]))
	link.packet = link.conn.connect_to_host(host, port, CHANNELS, member)
	if link.packet == null:
		_destroy_link(target)
	else:
		link.packet.set_timeout(SessionRules.PEER_TIMEOUT_MS,
			SessionRules.PEER_TIMEOUT_MS, SessionRules.PEER_TIMEOUT_MS)

func _poll_punch() -> void:
	var now := Time.get_ticks_msec()
	for raw_target in _links.keys():
		var target := int(raw_target)
		var link: DirectLink = _links.get(target)
		if link == null:
			continue
		if not link.dialed and now >= link.next_discovery_ms:
			_send_discovery(link, now)
		elif link.dialed and not link.direct and now >= link.next_punch_ms:
			link.conn.socket_send(link.remote_host, link.remote_port,
				PackedByteArray([0]))
			link.next_punch_ms = now + PUNCH_RETRY_MS
		var gone := false
		while link.conn != null:
			var event := link.conn.service(0)
			var kind := int(event[0])
			if kind == ENetConnection.EVENT_NONE:
				break
			if kind == ENetConnection.EVENT_ERROR \
					or kind == ENetConnection.EVENT_DISCONNECT:
				gone = true
				break
			var packet: ENetPacketPeer = event[1]
			if kind == ENetConnection.EVENT_CONNECT:
				link.packet = packet
				packet.set_timeout(SessionRules.PEER_TIMEOUT_MS,
					SessionRules.PEER_TIMEOUT_MS, SessionRules.PEER_TIMEOUT_MS)
				if not _send_direct_op(link, "direct_hello"):
					gone = true
					break
			elif kind == ENetConnection.EVENT_RECEIVE:
				_direct_packet(link, packet, int(event[3]))
				if not _links.has(target):
					gone = true
					break
		if gone:
			_destroy_link(target, true)
		elif not link.direct and now >= link.deadline_ms:
			_destroy_link(target)

func _send_direct_op(link: DirectLink, kind: String) -> bool:
	if link.packet == null:
		return false
	var bytes := RelayFrame.encode_op(
		{"op": kind, "member": member, "key": link.key})
	return link.packet.send(CH_INPUT, bytes, ENetPacketPeer.FLAG_RELIABLE) == OK

func _direct_packet(link: DirectLink, packet: ENetPacketPeer,
		channel: int) -> void:
	var bytes := packet.get_packet()
	if RelayFrame.is_op(bytes):
		var op := RelayFrame.decode_op(bytes)
		var kind := str(op.get("op", ""))
		if int(op.get("member", -1)) != link.target \
				or str(op.get("key", "")) != link.key:
			_destroy_link(link.target)
			return
		if kind == "direct_hello":
			link.inbound_ready = true
			if not _send_direct_op(link, "direct_ack"):
				_destroy_link(link.target)
		elif kind == "direct_ack":
			link.direct = true
			if not link.reported:
				link.reported = true
				_put_raw(HOST_PEER, CH_INPUT,
					MultiplayerPeer.TRANSFER_MODE_RELIABLE,
					RelayFrame.encode_op(
						{"op": "punched", "member": link.target}))
		else:
			_destroy_link(link.target)
		return
	if not link.inbound_ready:
		_destroy_link(link.target)
		return
	direct_received += 1
	_handle(link.target, channel, bytes)

func direct_to(member_id: int) -> bool:
	var link: DirectLink = _links.get(member_id)
	return link != null and link.direct

## Diagnostics and the live probe use this to prove the relay fallback. It does
## not drop the logical peer or its slot binding.
func disconnect_direct(member_id: int) -> void:
	if _links.has(member_id):
		direct_fallbacks += 1
	_destroy_link(member_id, true)

func _remember_direct(link: DirectLink, channel: int, mode: int,
		bytes: PackedByteArray) -> void:
	var entry := [channel, mode, bytes]
	if link.replay.size() < DIRECT_REPLAY_MAX:
		link.replay.append(entry)
		return
	link.replay[link.replay_cursor] = entry
	link.replay_cursor = (link.replay_cursor + 1) & (DIRECT_REPLAY_MAX - 1)

func _replay_direct(link: DirectLink) -> void:
	if peer == null or not relayed or not _room_up:
		return
	var n := link.replay.size()
	for off in n:
		var idx := (link.replay_cursor + off) % n \
			if n == DIRECT_REPLAY_MAX else off
		var entry: Array = link.replay[idx]
		_put_raw(HOST_PEER, int(entry[0]), int(entry[1]),
			RelayFrame.route(link.target, entry[2]))
	link.replay.clear()
	link.replay_cursor = 0

func _destroy_link(target: int, replay_records: bool = false) -> void:
	var link: DirectLink = _links.get(target)
	if link == null:
		return
	if replay_records:
		_replay_direct(link)
	if link.conn != null:
		link.conn.destroy()
	_links.erase(target)

func _destroy_links() -> void:
	for target in _links.keys():
		_destroy_link(int(target))

func _context() -> Dictionary:
	var ls: Lockstep = session.lockstep if session != null else null
	return {"session_id": _session_id(),
		"executed": ls.executed if ls != null else 0,
		"delay": ls.delay if ls != null else 0,
		"boundary": boundary}

func _refuse(from: int) -> void:
	malformed_total += 1
	bad_packets[from] = int(bad_packets.get(from, 0)) + 1
	if int(bad_packets[from]) >= SessionRules.BAD_PACKETS and peer != null:
		if relayed:
			drop_peer(from)
		else:
			peer.disconnect_peer(from)

func _handle(from: int, channel: int, bytes: PackedByteArray) -> void:
	var ctx := _context()
	var env := Protocol.decode_envelope(bytes, ctx)
	if env.is_empty():
		_refuse(from)
		return
	var kind: int = env["kind"]
	var tick: int = env["tick"]
	var body: PackedByteArray = env["body"]
	match kind:
		Protocol.Message.INPUT:
			if not slot_of_peer.has(from):
				# Raw traffic from a peer that holds no slot — a parked link
				# still sending, or a stranger. Not a malformed packet: a cut.
				drop_peer(from)
				return
			if channel != CH_INPUT:
				_refuse(from)
				return
			var rec := Protocol.decode_input(body)
			if rec.is_empty():
				_refuse(from)
				return
			if not Protocol.valid_tick(kind, tick, ctx):
				if _input_stale(tick, ctx):
					return # authenticated replay-window duplicate
				_refuse(from)
				return
			var slot := int(slot_of_peer[from])
			var stored := _accept_record(slot, tick, rec["move"], rec["card"],
				rec["target"], rec["offer"], rec["aim"])
			if is_host and stored:
				_relay_records.append([slot, tick, rec["move"], rec["card"],
					rec["target"], rec["offer"], rec["aim"]])
		Protocol.Message.RELAY:
			if channel != CH_INPUT or is_host or from != HOST_PEER:
				_refuse(from)
				return
			var relay := Protocol.decode_relay(body)
			if relay.is_empty():
				_refuse(from)
				return
			relays_received += 1
			for r in relay["records"]:
				if Protocol.valid_tick(Protocol.Message.INPUT, int(r[1]), ctx):
					_accept_record(int(r[0]), int(r[1]), r[2], int(r[3]), int(r[4]), int(r[5]), r[6])
			for c in relay["checksums"]:
				if Protocol.valid_tick(Protocol.Message.CHECKSUM, int(c[1]), ctx) \
						and session.lockstep != null:
					session.lockstep.submit_checksum(int(c[0]), int(c[1]), int(c[2]))
		Protocol.Message.CHECKSUM:
			if not slot_of_peer.has(from):
				_refuse(from)
				return
			var cs := Protocol.decode_checksum(body)
			if cs.is_empty():
				_refuse(from)
				return
			if not Protocol.valid_tick(kind, tick, ctx):
				if tick < int(ctx.get("executed", 0)) - Lockstep.RING:
					return # authenticated replay-window duplicate
				_refuse(from)
				return
			var slot := int(slot_of_peer[from])
			var stored := session.lockstep != null \
				and session.lockstep.submit_checksum(slot, tick, cs["hash"])
			if is_host and stored:
				_relay_checksums.append([slot, tick, cs["hash"]])
		Protocol.Message.SNAPSHOT:
			if channel != CH_SNAPSHOT or body.size() > SessionRules.SNAPSHOT_MAX:
				_refuse(from)
				return
			snapshot_received.emit(tick, body)
		Protocol.Message.PING:
			# Transport-level, never session state: the reply echoes the probe
			# timestamp so the sender measures the round trip on this path.
			# UNRELIABLE like CHECKSUM: channel 0 is reliable ordered, so a
			# retransmitted probe would both block the records behind it and
			# report retransmit time as latency; a lost probe just costs the
			# sample.
			if channel != CH_INPUT:
				_refuse(from)
				return
			var pong := Protocol.decode_control(kind, tick, body)
			if pong.is_empty():
				_refuse(from)
				return
			if not slot_of_peer.has(from):
				# A bound-less peer's probe is not its fault: a client binds
				# the host the moment it connects, while the host binds it
				# only when its HELLO is admitted. Never counted against it.
				return
			_put(from, CH_INPUT, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE,
				Protocol.encode_control(Protocol.Message.PONG, _session_id(), 0,
					{"t": int(pong.get("t", 0))}))
		Protocol.Message.PONG:
			if channel != CH_INPUT:
				_refuse(from)
				return
			var pong := Protocol.decode_control(kind, tick, body)
			if pong.is_empty():
				_refuse(from)
				return
			if not slot_of_peer.has(from):
				return
			var t := int(pong.get("t", 0))
			var now := Time.get_ticks_msec()
			# A stale or future timestamp is not a measurement this path made.
			if t > 0 and now >= t and now - t < 60000:
				ping_ms[int(slot_of_peer[from])] = now - t
		_:
			var ctl := Protocol.decode_control(kind, tick, body)
			if ctl.is_empty():
				_refuse(from)
				return
			if kind == Protocol.Message.HELLO and not session.accepts_hello(ctl):
				_refuse(from)
				return
			# A reconnecting client's executed cursor is stale by however long
			# it was away; the boundary the host names is measured against the
			# host's cursor, not this one, so the window does not apply.
			if (kind == Protocol.Message.RESYNC or kind == Protocol.Message.END_CHECK) \
					and not session.reconnecting \
					and not Protocol.valid_tick(kind, tick, ctx):
				_refuse(from)
				return
			session.receive(kind, ctl, from)

## Submit a record to the ring — and, while a restore boundary is announced,
## ALSO retain it by absolute tick. A correct peer keeps executing on the
## submitted copy; a peer that then restores has its executed cursor moved by
## the snapshot, and the retained copies are re-submitted against the new
## cursor so nothing delivered during the transfer is lost. Boundary-valid
## traffic is never counted against a peer.
const HELD_MAX := Lockstep.RING * SessionRules.MAX_PLAYERS

func _accept_record(slot: int, tick: int, move: Vector2, card: int, target: int,
		offer: int, aim: Vector2 = Vector2.ZERO) -> bool:
	var stored := session.lockstep != null \
		and session.lockstep.submit(slot, tick, move, card, target, offer, aim)
	if stored:
		input_records_received += 1
		slot_records_in[slot] = int(slot_records_in.get(slot, 0)) + 1
	if boundary >= 0 and tick > boundary and _held.size() < HELD_MAX \
			and not _held_has(slot, tick):
		_held.append([slot, tick, move, card, target, offer, aim])
	return stored

func _input_stale(tick: int, ctx: Dictionary) -> bool:
	var boundary_tick := int(ctx.get("boundary", -1))
	var lo := boundary_tick + 1 if boundary_tick >= 0 \
		else int(ctx.get("executed", 0))
	return tick < lo

func _held_has(slot: int, tick: int) -> bool:
	for record in _held:
		if int(record[0]) == slot and int(record[1]) == tick:
			return true
	return false

## Announce a restore boundary: records past it are retained as they arrive.
func arm_boundary(tick: int) -> void:
	boundary = tick
	_held.clear()

## The boundary is done — a restore committed, or the window passed with no
## snapshot for this peer. Re-offer every retained record to the ring (a record
## already there is refused, never overwritten) and stop retaining.
func release_boundary() -> void:
	boundary = -1
	if session.lockstep != null:
		for r in _held:
			session.lockstep.submit(int(r[0]), int(r[1]), r[2], int(r[3]), int(r[4]), int(r[5]), r[6])
	_held.clear()

func held_count() -> int:
	return _held.size()
