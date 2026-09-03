class_name RelayServer extends RefCounted

## The ENet shell around RelayRooms: the lines that own a socket. The only
## relay file that touches ENet; every decision is RelayRooms' (pure, tested).

var peer: ENetMultiplayerPeer = null
## The punch reflexive-discovery endpoint: a peer's punch socket connects here
## so the relay observes that socket's public host:port and hands it to the
## other members. A SEPARATE socket from the game relay above; low-level
## ENetConnection because that is what does simultaneous open on the client
## side (see docs/superpowers/plans/2026-09-03-nat-punching.md).
var discovery: ENetConnection = null
var rooms := RelayRooms.new()
var _last_report_ms := 0
## Peers to cut once a final op has had time to leave: [peer, at_ms].
var _drop_later: Array = []
const DROP_GRACE_MS := 250

func start(port: int) -> Error:
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(port, SessionRules.RELAY_MAX_CONNECTIONS, 2)
	if err != OK:
		peer = null
		return err
	peer.peer_connected.connect(_on_connected)
	peer.peer_disconnected.connect(_on_disconnected)
	discovery = ENetConnection.new()
	var derr := discovery.create_host_bound("*", SessionRules.PUNCH_DISCOVERY_PORT,
		SessionRules.RELAY_MAX_CONNECTIONS, RelayServer.PUNCH_CHANNELS)
	if derr != OK:
		push_warning("relay: punch discovery could not bind UDP %d (%s); punching off"
			% [SessionRules.PUNCH_DISCOVERY_PORT, error_string(derr)])
		discovery = null
	else:
		print("relay: punch discovery on UDP %d" % SessionRules.PUNCH_DISCOVERY_PORT)
	return OK

const PUNCH_CHANNELS := 2

func stop() -> void:
	if peer != null:
		peer.close()
	peer = null
	if discovery != null:
		discovery.destroy()
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

## Service the discovery endpoint: every "discover" packet carries a punch
## token and arrives FROM the peer's punch socket, so its source host:port is
## exactly the reflexive mapping the other members must punch to. Registering
## it may complete a pair, whose punch ops go over the GAME relay (peer), not
## here — _perform handles those. The peer is also told its own mapping.
func _poll_discovery() -> void:
	if discovery == null:
		return
	while true:
		var ev := discovery.service(0)
		var type: int = ev[0]
		if type == ENetConnection.EVENT_NONE:
			break
		if type != ENetConnection.EVENT_RECEIVE:
			continue
		var dpeer: ENetPacketPeer = ev[1]
		var bytes: PackedByteArray = dpeer.get_packet()
		if not RelayFrame.is_op(bytes):
			continue
		var op := RelayFrame.decode_op(bytes)
		if str(op.get("op", "")) != "discover":
			continue
		var token := str(op.get("token", ""))
		var host := dpeer.get_remote_address()
		var port := dpeer.get_remote_port()
		_perform(rooms.register_reflexive(token, host, port))
		dpeer.send(0, RelayFrame.encode_op({"op": "reflexive", "host": host, "port": port}),
			ENetPacketPeer.FLAG_RELIABLE)

func _perform(actions: Array) -> void:
	if peer == null:
		return
	for a in actions:
		if a[0] == "send":
			peer.set_target_peer(int(a[1]))
			peer.set_transfer_channel(int(a[2]))
			peer.set_transfer_mode(int(a[3]))
			peer.put_packet(a[4])
		elif a[0] == "drop":
			if rooms.is_connected_peer(int(a[1])):
				peer.disconnect_peer(int(a[1]))
		elif a[0] == "drop_later":
			_drop_later.append([int(a[1]), Time.get_ticks_msec() + DROP_GRACE_MS])
