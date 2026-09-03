class_name RelayServer extends RefCounted

## The ENet shell around RelayRooms: the lines that own a socket. The only
## relay file that touches ENet; every decision is RelayRooms' (pure, tested).

var peer: ENetMultiplayerPeer = null
## The punch reflexive-discovery endpoint: a direct socket sends ONE-WAY raw
## UDP `discover` datagrams here so the relay observes that socket's public
## host:port and hands it to the paired member. PacketPeerUDP, not an
## ENetConnection: each direct socket permits exactly one outgoing ENet
## connect (its handshake to the OTHER member), so discovery cannot ride an
## ENetConnection of its own on that socket's port — it is a plain datagram,
## and the relay never replies over it.
var discovery: PacketPeerUDP = null
var rooms := RelayRooms.new()
var _last_report_ms := 0
## Peers to cut once a final op has had time to leave: [peer, at_ms].
var _drop_later: Array = []
const DROP_GRACE_MS := 250

func start(port: int, punch_port: int = SessionRules.PUNCH_DISCOVERY_PORT) -> Error:
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(port, SessionRules.RELAY_MAX_CONNECTIONS, 2)
	if err != OK:
		peer = null
		return err
	peer.peer_connected.connect(_on_connected)
	peer.peer_disconnected.connect(_on_disconnected)
	discovery = PacketPeerUDP.new()
	var derr := discovery.bind(punch_port)
	if derr != OK:
		push_warning("relay: punch discovery could not bind UDP %d (%s); punching off"
			% [punch_port, error_string(derr)])
		discovery = null
	else:
		print("relay: punch discovery on UDP %d" % punch_port)
	return OK

func stop() -> void:
	if peer != null:
		peer.close()
	peer = null
	if discovery != null:
		discovery.close()
	discovery = null

func _on_connected(id: int) -> void:
	# The same silence tolerance the game gives a peer, so a member that
	# vanishes is reported to its host within a few seconds.
	var pp := peer.get_peer(id)
	if pp != null:
		pp.set_timeout(SessionRules.PEER_TIMEOUT_MS, SessionRules.PEER_TIMEOUT_MS,
			SessionRules.PEER_TIMEOUT_MS)
	rooms.connect_peer(id, Time.get_ticks_msec())

func _on_disconnected(id: int) -> void:
	_perform(rooms.disconnect_peer(id))

func poll(now_ms: int) -> void:
	if peer == null:
		return
	peer.poll()
	while peer.get_available_packet_count() > 0:
		var from := peer.get_packet_peer()
		var channel := peer.get_packet_channel()
		var mode := peer.get_packet_mode()
		var bytes := peer.get_packet()
		_perform(rooms.handle(from, channel, mode, bytes, now_ms))
	_poll_discovery()
	_perform(rooms.expire(now_ms))
	var i := 0
	while i < _drop_later.size():
		if now_ms >= int(_drop_later[i][1]):
			# A joiner told "closed" usually hangs up first; ENet errors on
			# disconnecting a peer it no longer has.
			if rooms.is_connected_peer(int(_drop_later[i][0])):
				peer.disconnect_peer(int(_drop_later[i][0]))
			_drop_later.remove_at(i)
		else:
			i += 1
	if now_ms - _last_report_ms >= 60000:
		_last_report_ms = now_ms
		print("relay: %s" % [rooms.stats()])

## Service the discovery endpoint: a "discover" datagram is ONE-WAY, sent by a
## direct socket dedicated to one target member, so its source host:port
## (observed here, not self-reported) is exactly that leg's reflexive mapping.
## Registering it may complete a pair, whose "punch" op goes over the GAME
## relay (peer), not here — _perform handles that. No reply is sent on this
## socket: the discovery channel is receive-only.
func _poll_discovery() -> void:
	if discovery == null:
		return
	while discovery.get_available_packet_count() > 0:
		var bytes: PackedByteArray = discovery.get_packet()
		var host := discovery.get_packet_ip()
		var port := discovery.get_packet_port()
		if not RelayFrame.is_op(bytes):
			continue
		var op := RelayFrame.decode_op(bytes)
		if str(op.get("op", "")) != "discover":
			continue
		var token := str(op.get("token", ""))
		var target := int(op.get("target", -1))
		var local_host := str(op.get("local_host", ""))
		var local_port := int(op.get("local_port", 0))
		_perform(rooms.register_reflexive(token, target, host, port, local_host, local_port))

func _perform(actions: Array) -> void:
	if peer == null:
		return
	for a in actions:
		if a[0] == "send":
			# The disconnected peer's callback ran first in a near-simultaneous
			# teardown; ENet errors on put_packet to a peer it already dropped.
			if not rooms.is_connected_peer(int(a[1])):
				continue
			peer.set_target_peer(int(a[1]))
			peer.set_transfer_channel(int(a[2]))
			peer.set_transfer_mode(int(a[3]))
			peer.put_packet(a[4])
		elif a[0] == "drop":
			if rooms.is_connected_peer(int(a[1])):
				peer.disconnect_peer(int(a[1]))
		elif a[0] == "drop_later":
			_drop_later.append([int(a[1]), Time.get_ticks_msec() + DROP_GRACE_MS])
