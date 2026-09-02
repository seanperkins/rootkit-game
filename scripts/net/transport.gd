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
	bad_packets[id] = 0
	peer_joined.emit(id)

func _on_peer_disconnected(id: int) -> void:
	# Listeners first, while the binding still says which slot this was.
	peer_left.emit(id)
	if slot_of_peer.has(id):
		peer_of_slot.erase(int(slot_of_peer[id]))
		slot_of_peer.erase(id)

## A client's link is gone: make it again to the same host. The run then
## re-introduces itself with HELLO(session_id, slot) once the peer connects.
func rejoin() -> Error:
	if is_host or _address == "":
		return ERR_UNCONFIGURED
	close()
	return join(_address, _port, session)

## Cut one peer. Parking does this so a link that merely hiccupped cannot keep
## driving a slot nobody applies; so does input from a peer that never said
## HELLO.
func drop_peer(id: int) -> void:
	dropped_peers.append(id)
	if peer != null:
		peer.disconnect_peer(id)
	if slot_of_peer.has(id):
		peer_of_slot.erase(int(slot_of_peer[id]))
		slot_of_peer.erase(id)

func connected() -> bool:
	return peer != null and peer.get_connection_status() \
		== MultiplayerPeer.CONNECTION_CONNECTED

func bind_peer(peer_id: int, slot: int) -> void:
	slot_of_peer[peer_id] = slot
	peer_of_slot[slot] = peer_id

func close() -> void:
	if peer != null:
		peer.close()
	peer = null
	slot_of_peer.clear()
	peer_of_slot.clear()

# ------------------------------------------------------------------ send ---

func _put(target: int, channel: int, mode: int, bytes: PackedByteArray) -> void:
	if peer == null:
		return
	peer.set_target_peer(target)
	peer.set_transfer_channel(channel)
	peer.set_transfer_mode(mode)
	peer.put_packet(bytes)

func _session_id() -> int:
	return int(session.descriptor.get("session_id", 0)) if session != null else 0

## This peer's own record for a tick. A client sends it to the host; the host
## stages it for its next relay and needs no packet.
func send_input(tick: int, move: Vector2, card: int, target: int, offer: int) -> void:
	if is_host:
		_relay_records.append([session.local_slot, tick, move, card, target, offer])
		return
	_put(HOST_PEER, CH_INPUT, MultiplayerPeer.TRANSFER_MODE_RELIABLE,
		Protocol.encode_input(_session_id(), tick, move, card, target, offer))

## This peer's periodic checksum. Unreliable: a lost one is replaced by the
## next, and a stale one is refused by the retained window on arrival. The host
## bundles its own into the relay instead.
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
		_put(int(id), CH_INPUT, MultiplayerPeer.TRANSFER_MODE_RELIABLE, bytes)
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
	peer.poll()
	while peer.get_available_packet_count() > 0:
		var from := peer.get_packet_peer()
		var channel := peer.get_packet_channel()
		var bytes := peer.get_packet()
		_handle(from, channel, bytes)

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
			if rec.is_empty() or not Protocol.valid_tick(kind, tick, ctx):
				_refuse(from)
				return
			var slot := int(slot_of_peer[from])
			_accept_record(slot, tick, rec["move"], rec["card"], rec["target"], rec["offer"])
			if is_host:
				_relay_records.append([slot, tick, rec["move"], rec["card"],
					rec["target"], rec["offer"]])
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
					_accept_record(int(r[0]), int(r[1]), r[2], int(r[3]), int(r[4]), int(r[5]))
			for c in relay["checksums"]:
				if Protocol.valid_tick(Protocol.Message.CHECKSUM, int(c[1]), ctx) \
						and session.lockstep != null:
					session.lockstep.submit_checksum(int(c[0]), int(c[1]), int(c[2]))
		Protocol.Message.CHECKSUM:
			if not slot_of_peer.has(from):
				_refuse(from)
				return
			var cs := Protocol.decode_checksum(body)
			if cs.is_empty() or not Protocol.valid_tick(kind, tick, ctx):
				_refuse(from)
				return
			var slot := int(slot_of_peer[from])
			if session.lockstep != null:
				session.lockstep.submit_checksum(slot, tick, cs["hash"])
			if is_host:
				_relay_checksums.append([slot, tick, cs["hash"]])
		Protocol.Message.SNAPSHOT:
			if channel != CH_SNAPSHOT or body.size() > SessionRules.SNAPSHOT_MAX:
				_refuse(from)
				return
			snapshot_received.emit(tick, body)
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
		offer: int) -> void:
	if session.lockstep != null:
		session.lockstep.submit(slot, tick, move, card, target, offer)
	if boundary >= 0 and tick > boundary and _held.size() < HELD_MAX:
		_held.append([slot, tick, move, card, target, offer])

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
			session.lockstep.submit(int(r[0]), int(r[1]), r[2], int(r[3]), int(r[4]), int(r[5]))
	_held.clear()

func held_count() -> int:
	return _held.size()
