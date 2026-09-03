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
		var _r: Dictionary = rooms[code]
		if _r.has("cands"): (_r["cands"] as Dictionary).erase(member)
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
				"last_ms": now_ms, "tokens": {}, "cands": {}, "punch_sent": {}}
			room_of_peer[peer] = code
			member_of_peer[peer] = 1
			var tok := _mint_token(code, 1, peer, op)
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
			var tok := _mint_token(code, id, peer, op)
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
## the right member without trusting a claimed member id. The optional LAN
## candidate the member self-reports rides in `create`/`join` and is stored now.
func _mint_token(code: String, member: int, peer: int, op: Dictionary) -> String:
	var tok := ""
	for _i in 16:
		tok += SessionRules.CODE_ALPHABET[_rng.randi_range(0, SessionRules.CODE_ALPHABET.length() - 1)]
	var room: Dictionary = rooms[code]
	(room["tokens"] as Dictionary)[tok] = member
	token_peer[tok] = peer
	var cand := {"host": "", "port": 0,
		"local_host": _clean_host(str(op.get("local_host", ""))),
		"local_port": _clean_port(op.get("local_port", 0))}
	(room["cands"] as Dictionary)[member] = cand
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

## The discovery endpoint observed a punch socket's public host:port and read
## its token. Tie it to the member, and once two or more members have a
## reflexive mapping, hand each member the others' candidates so both ends can
## punch. Returns the actions (punch ops on the members' relay connections).
func register_reflexive(token: String, host: String, port: int) -> Array:
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
	if member < 0:
		return []
	var cands: Dictionary = room["cands"]
	if not cands.has(member):
		cands[member] = {"host": "", "port": 0, "local_host": "", "local_port": 0}
	cands[member]["host"] = _clean_host(host)
	cands[member]["port"] = _clean_port(port)
	return _emit_punch(code)

## For every member with a known reflexive mapping, send it the candidates of
## every OTHER such member. Idempotent: a member is not re-sent a pairing it
## already has (tracked in room.punch_sent) so a late joiner does not re-punch
## settled pairs.
func _emit_punch(code: String) -> Array:
	var room: Dictionary = rooms[code]
	var members: Dictionary = room["members"]
	var cands: Dictionary = room["cands"]
	var sent: Dictionary = room["punch_sent"]
	var ready := []
	for m in members.keys():
		if cands.has(m) and str(cands[m]["host"]) != "":
			ready.append(int(m))
	var actions := []
	for m in ready:
		# FLAT array, groups of 5: [member, host, port, local_host, local_port, ...].
		# The op codec carries only flat primitives, never nested arrays.
		var flat := []
		for n in ready:
			if n == m:
				continue
			var key := "%d-%d" % [m, n]
			if sent.has(key):
				continue
			var c: Dictionary = cands[n]
			flat.append_array([n, str(c["host"]), int(c["port"]), str(c["local_host"]), int(c["local_port"])])
			sent[key] = true
		if not flat.is_empty():
			actions.append(["send", int(members[m]), 0, MultiplayerPeer.TRANSFER_MODE_RELIABLE,
				RelayFrame.encode_op({"op": "punch", "peers": flat})])
	return actions

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
