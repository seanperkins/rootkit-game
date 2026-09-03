class_name RelayServer extends RefCounted

## The ENet shell around RelayRooms: the lines that own a socket. The only
## relay file that touches ENet; every decision is RelayRooms' (pure, tested).

var peer: ENetMultiplayerPeer = null
var rooms := RelayRooms.new()
var _last_report_ms := 0

func start(port: int) -> Error:
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(port, SessionRules.RELAY_MAX_CONNECTIONS, 2)
	if err != OK:
		peer = null
		return err
	peer.peer_connected.connect(_on_connected)
	peer.peer_disconnected.connect(_on_disconnected)
	return OK

func stop() -> void:
	if peer != null:
		peer.close()
	peer = null

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
	_perform(rooms.expire(now_ms))
	if now_ms - _last_report_ms >= 60000:
		_last_report_ms = now_ms
		print("relay: %s" % [rooms.stats()])

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
			peer.disconnect_peer(int(a[1]))
