class_name RelayRooms extends RefCounted

## The relay's rooms, PURE: fed peer ids, channels, modes and bytes, it answers
## with a list of actions — ["send", to_peer, channel, mode, bytes],
## ["drop", peer] or ["drop_later", peer] (after a short grace, so a final
## op sent just before it is delivered) — and the ENet shell performs them. Nothing here reads a
## packet past its first byte, so the relay cannot be made to decode the game.

const MAX_MEMBERS := 4
## A creator that never sends anything is cut after this; a room with no
## members at all after SessionRules.ROOM_IDLE_MS. The same ten minutes as
## the idle rule, NOT a short grace: a host waiting alone in the lobby sends
## nothing at all until a friend joins — flush_relay has no records to carry —
## and at 30 s this cut every host whose friend took longer than that to type
## the code. It read in the shell as "lost the relay", over and over.
const CREATE_GRACE_MS := SessionRules.ROOM_IDLE_MS
## Refusal reasons, as the wire carries them.
const UNKNOWN := "unknown"
const FULL := "full"
const CLOSED := "closed"
const BAD := "bad"

var rooms: Dictionary = {}          # code -> {host, members: {id: peer}, created_ms, last_ms}
var room_of_peer: Dictionary = {}   # peer -> code
var member_of_peer: Dictionary = {} # peer -> member id
var _connected: Dictionary = {}     # peer -> true
var token_peer: Dictionary = {}     # punch token -> relay peer id (reflexive discovery)
var _rng := RandomNumberGenerator.new()
var _crypto := Crypto.new()
var forwarded := 0
var refused := 0

func _init(rng_seed: int = -1) -> void:
	if rng_seed < 0:
		_rng.randomize()
	else:
		_rng.seed = rng_seed

func connect_peer(peer: int, _now_ms: int) -> void:
	_connected[peer] = true

## Still on the socket, as far as this side has been told.
func is_connected_peer(peer: int) -> bool:
	return _connected.has(peer)

func disconnect_peer(peer: int) -> Array:
	var actions := []
	_connected.erase(peer)
	if not room_of_peer.has(peer):
		return actions
	var code: String = room_of_peer[peer]
	var member := int(member_of_peer[peer])
	room_of_peer.erase(peer)
	member_of_peer.erase(peer)
	# Drop this member's punch bookkeeping.
	for tok in token_peer.keys():
		if int(token_peer[tok]) == peer:
			token_peer.erase(tok)
	if rooms.has(code):
		_clear_punch_state(rooms[code], member)
	if not rooms.has(code):
		return actions
	var room: Dictionary = rooms[code]
	(room["members"] as Dictionary).erase(member)
	if member == 1:
		# The host is gone: every joiner is told and cut, and the room dies.
		for m in (room["members"] as Dictionary).keys():
			var p := int(room["members"][m])
			actions.append(["send", p, 0, MultiplayerPeer.TRANSFER_MODE_RELIABLE,
				RelayFrame.encode_op({"op": "closed"})])
			actions.append(["drop_later", p])
			room_of_peer.erase(p)
			member_of_peer.erase(p)
		rooms.erase(code)
		print("relay: room %s closed — host peer %d left" % [code, peer])
	else:
		actions.append(["send", int(room["host"]), 0, MultiplayerPeer.TRANSFER_MODE_RELIABLE,
			RelayFrame.encode_op({"op": "left", "member": member})])
	return actions

func handle(peer: int, channel: int, mode: int, bytes: PackedByteArray, now_ms: int) -> Array:
	if RelayFrame.is_op(bytes):
		return _op(peer, RelayFrame.decode_op(bytes), now_ms)
	if not room_of_peer.has(peer):
		refused += 1
		return [["drop", peer]]
	if bytes.size() > SessionRules.SNAPSHOT_MAX + 1 + Protocol.ENVELOPE:
		refused += 1
		return _cut(peer)
	var parts := RelayFrame.unroute(bytes)
	if parts.is_empty():
		refused += 1
		return _cut(peer)
	var to := int(parts[0])
	var code: String = room_of_peer[peer]
	var room: Dictionary = rooms[code]
	var me := int(member_of_peer[peer])
	room["last_ms"] = now_ms
	var out := RelayFrame.route(me, parts[1])
	var actions := []
	if to == RelayFrame.BROADCAST:
		if me != 1:
			refused += 1
			return _cut(peer)
		for m in (room["members"] as Dictionary).keys():
			if int(m) != 1:
				actions.append(["send", int(room["members"][m]), channel, mode, out])
				forwarded += 1
		return actions
	if not (room["members"] as Dictionary).has(to):
		return []           # a member that just left: silent
	actions.append(["send", int(room["members"][to]), channel, mode, out])
	forwarded += 1
	return actions

func expire(now_ms: int) -> Array:
	var actions := []
	for code in rooms.keys():
		var room: Dictionary = rooms[code]
		var members: Dictionary = room["members"]
		var idle := now_ms - int(room["last_ms"])
		if members.size() <= 1 and int(room["last_ms"]) == int(room["created_ms"]) \
				and idle > CREATE_GRACE_MS:
			# A creator that never sent anything: cut it, which closes the room.
			print("relay: room %s cut — its creator sent nothing for %d ms" % [code, idle])
			actions.append_array(_cut(int(room["host"])))
		elif members.is_empty() and idle > SessionRules.ROOM_IDLE_MS:
			rooms.erase(code)
	return actions

func stats() -> Dictionary:
	var members := 0
	for code in rooms:
		members += (rooms[code]["members"] as Dictionary).size()
	return {"rooms": rooms.size(), "members": members, "forwarded": forwarded, "refused": refused}

func _op(peer: int, op: Dictionary, now_ms: int) -> Array:
	if op.is_empty():
		refused += 1
		return _cut(peer)
	var kind: String = str(op.get("op", ""))
	match kind:
		"create":
			if room_of_peer.has(peer) or int(op.get("protocol", -1)) != SessionRules.RELAY_PROTOCOL:
				return _refuse(peer, BAD)
			var code := _fresh_code()
			rooms[code] = {"host": peer, "members": {1: peer}, "created_ms": now_ms,
				"last_ms": now_ms, "tokens": {}, "cands": {}, "keys": {}}
			room_of_peer[peer] = code
			member_of_peer[peer] = 1
			var tok := _mint_token(code, 1, peer)
			print("relay: room %s opened by peer %d" % [code, peer])
			return [["send", peer, 0, MultiplayerPeer.TRANSFER_MODE_RELIABLE,
				RelayFrame.encode_op({"op": "room", "code": code, "member": 1,
					"members": [1], "token": tok})]]
		"join":
			if room_of_peer.has(peer) or int(op.get("protocol", -1)) != SessionRules.RELAY_PROTOCOL:
				return _refuse(peer, BAD)
			var code := RelayFrame.normalise_code(str(op.get("code", "")))
			if not rooms.has(code):
				return _refuse(peer, UNKNOWN)
			var room: Dictionary = rooms[code]
			var members: Dictionary = room["members"]
			var id := -1
			for cand in range(2, MAX_MEMBERS + 1):
				if not members.has(cand):
					id = cand
					break
			if id < 0:
				return _refuse(peer, FULL)
			members[id] = peer
			room_of_peer[peer] = code
			member_of_peer[peer] = id
			room["last_ms"] = now_ms
			var tok := _mint_token(code, id, peer)
			var ids := members.keys()
			ids.sort()
			return [["send", peer, 0, MultiplayerPeer.TRANSFER_MODE_RELIABLE,
					RelayFrame.encode_op({"op": "room", "code": code, "member": id,
						"members": ids, "token": tok})],
				["send", int(room["host"]), 0, MultiplayerPeer.TRANSFER_MODE_RELIABLE,
					RelayFrame.encode_op({"op": "joined", "member": id})]]
		"punched":
			# Diagnostics only: a member reports a direct link to another.
			if room_of_peer.has(peer):
				print("relay: member %d reports a direct link to %d" % [int(member_of_peer[peer]), int(op.get("member", -1))])
			return []
		"kick":
			if not room_of_peer.has(peer) or int(member_of_peer[peer]) != 1:
				refused += 1
				return _cut(peer)
			var room: Dictionary = rooms[room_of_peer[peer]]
			var target := int(op.get("member", -1))
			if target <= 1 or not (room["members"] as Dictionary).has(target):
				return []
			return _cut(int(room["members"][target]))
	refused += 1
	return _cut(peer)

## A per-member punch token, unguessable, that the member's punch socket
## presents to the discovery endpoint so its reflexive mapping can be tied to
## the right member without trusting a claimed member id. Candidates are no
## longer seeded here: each direct socket is dedicated to one target and
## self-reports its LAN address in the discovery datagram, not in `create`/`join`.
func _mint_token(code: String, member: int, peer: int) -> String:
	var tok := _mint_secret()
	var room: Dictionary = rooms[code]
	(room["tokens"] as Dictionary)[tok] = member
	token_peer[tok] = peer
	return tok

func _clean_host(h: String) -> String:
	if h.length() > SessionRules.ADDRESS_MAX:
		return ""
	for ch in h:
		if not (ch.is_valid_identifier() or ch == "." or ch == ":" or ch == "-" or ch.is_valid_int()):
			return ""
	return h

func _clean_port(p) -> int:
	var n := int(p)
	return n if n > 0 and n <= 65535 else 0

## A direct socket registered its reflexive host:port (observed by the
## discovery endpoint) and self-reported local host:port, for the leg it
## dials toward `target`. Star topology only: one of (member, target) must be
## the host (member 1) and the other an existing client member — anything else
## (an unknown token, an absent target, a client naming another client, self)
## is ignored quietly. Candidates are stored by the DIRECTED (member, target)
## pair; once both directions of a host↔client leg are known, a shared
## per-pair handshake secret is minted and a `punch` op naming the other side
## goes to both members over the existing relay link. Re-registering after a
## pair has settled is a no-op — idempotent, no duplicate `punch`.
func register_reflexive(token: String, target: int, host: String, port: int,
		local_host: String = "", local_port: int = 0) -> Array:
	if not token_peer.has(token):
		return []
	var peer := int(token_peer[token])
	if not room_of_peer.has(peer):
		return []
	var code: String = room_of_peer[peer]
	if not rooms.has(code):
		return []
	var room: Dictionary = rooms[code]
	var member := int((room["tokens"] as Dictionary).get(token, -1))
	var members: Dictionary = room["members"]
	if member < 0 or not members.has(member):
		return []
	var client_id := -1
	if member == 1:
		if target == 1 or not members.has(target):
			return []
		client_id = target
	elif target == 1:
		client_id = member
	else:
		return []   # no client-client candidates
	var keys: Dictionary = room["keys"]
	if keys.has(client_id):
		return []   # settled: idempotent re-registration
	var cands: Dictionary = room["cands"]
	cands["%d>%d" % [member, target]] = {
		"host": _clean_host(host), "port": _clean_port(port),
		"local_host": _clean_host(local_host), "local_port": _clean_port(local_port),
	}
	if not cands.has("%d>%d" % [target, member]):
		return []   # only one direction of this leg so far
	var key := _mint_key()
	keys[client_id] = key
	var host_cand: Dictionary = cands["%d>%d" % [1, client_id]]
	var client_cand: Dictionary = cands["%d>%d" % [client_id, 1]]
	return [
		["send", int(members[1]), 0, MultiplayerPeer.TRANSFER_MODE_RELIABLE,
			RelayFrame.encode_op({"op": "punch", "member": client_id,
				"host": str(client_cand["host"]), "port": int(client_cand["port"]),
				"local_host": str(client_cand["local_host"]), "local_port": int(client_cand["local_port"]),
				"key": key})],
		["send", int(members[client_id]), 0, MultiplayerPeer.TRANSFER_MODE_RELIABLE,
			RelayFrame.encode_op({"op": "punch", "member": 1,
				"host": str(host_cand["host"]), "port": int(host_cand["port"]),
				"local_host": str(host_cand["local_host"]), "local_port": int(host_cand["local_port"]),
				"key": key})],
	]

func _mint_key() -> String:
	return _mint_secret()

## Authentication material must not share the observable, seedable room-code
## RNG. Sixteen CSPRNG bytes encoded as hex give each token 128 bits without
## alphabet modulo bias.
func _mint_secret() -> String:
	return _crypto.generate_random_bytes(16).hex_encode()

## Drop every directed candidate and settled pairing that involves `member`,
## so a member id freed by disconnect and reused by a later joiner starts
## clean and can punch anew rather than inheriting a stale settled pair.
func _clear_punch_state(room: Dictionary, member: int) -> void:
	var cands: Dictionary = room["cands"]
	for k in cands.keys().duplicate():
		var parts: PackedStringArray = (k as String).split(">")
		if int(parts[0]) == member or int(parts[1]) == member:
			cands.erase(k)
	var keys: Dictionary = room["keys"]
	if member == 1:
		keys.clear()
	else:
		keys.erase(member)

func _refuse(peer: int, reason: String) -> Array:
	refused += 1
	print("relay: refused peer %d — %s" % [peer, reason])
	return [["send", peer, 0, MultiplayerPeer.TRANSFER_MODE_RELIABLE,
		RelayFrame.encode_op({"op": "refused", "reason": reason})], ["drop", peer]]

## Drop a peer, performing what its disconnect would.
func _cut(peer: int) -> Array:
	var actions := disconnect_peer(peer)
	actions.append(["drop", peer])
	return actions

func _fresh_code() -> String:
	while true:
		var code := ""
		for _i in SessionRules.CODE_LENGTH:
			code += SessionRules.CODE_ALPHABET[_rng.randi_range(0, SessionRules.CODE_ALPHABET.length() - 1)]
		if not rooms.has(code):
			return code
	return ""
