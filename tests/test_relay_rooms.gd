extends SceneTree

## The room registry the relay runs on, driven with no ENet at all: every
## decision the relay makes is a list of sends and drops.

var failures := 0
const CH := 0
const MODE := 2   # MultiplayerPeer.TRANSFER_MODE_RELIABLE

func _init() -> void:
	print("ROOTKIT — relay rooms\n")
	create_join_and_route()
	refusals()
	leaving_and_closing()
	expiry_and_hygiene()
	print("")
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _op(d: Dictionary) -> PackedByteArray:
	return RelayFrame.encode_op(d)

## The first "send" action's decoded op, or {}.
func _first_op(actions: Array) -> Dictionary:
	for a in actions:
		if a[0] == "send":
			return RelayFrame.decode_op(a[4])
	return {}

func _sends_to(actions: Array, peer: int) -> Array:
	var out := []
	for a in actions:
		if a[0] == "send" and int(a[1]) == peer:
			out.append(a)
	return out

func _drops(actions: Array) -> Array:
	var out := []
	for a in actions:
		if a[0] == "drop" or a[0] == "drop_later":
			out.append(int(a[1]))
	return out

## A host at peer 10 with a room, and a joiner at peer 20 in it.
func _room(r: RelayRooms) -> String:
	r.connect_peer(10, 0)
	var made := r.handle(10, CH, MODE, _op({"op": "create", "protocol": SessionRules.RELAY_PROTOCOL}), 0)
	var code: String = _first_op(made).get("code", "")
	r.connect_peer(20, 0)
	r.handle(20, CH, MODE, _op({"op": "join", "code": code, "protocol": SessionRules.RELAY_PROTOCOL}), 0)
	return code

func create_join_and_route() -> void:
	var r := RelayRooms.new(1)
	r.connect_peer(10, 0)
	var made := r.handle(10, CH, MODE, _op({"op": "create", "protocol": SessionRules.RELAY_PROTOCOL}), 0)
	var room := _first_op(made)
	_check("create answers with a room op", room.get("op", ""), "room")
	_check("the creator is member 1", int(room.get("member", -1)), 1)
	var code: String = room.get("code", "")
	_check("the code is six from the alphabet", RelayFrame.is_code(code), true)
	var other := RelayRooms.new(2)
	other.connect_peer(1, 0)
	var made2 := other.handle(1, CH, MODE, _op({"op": "create", "protocol": SessionRules.RELAY_PROTOCOL}), 0)
	_check("codes differ across seeds", _first_op(made2).get("code", "") != code, true)

	r.connect_peer(20, 0)
	var joined := r.handle(20, CH, MODE, _op({"op": "join", "code": code.to_lower(), "protocol": SessionRules.RELAY_PROTOCOL}), 0)
	var ans := _first_op(_sends_to(joined, 20))
	_check("join answers the joiner with the room", ans.get("op", ""), "room")
	_check("as member 2", int(ans.get("member", -1)), 2)
	_check("listing the members", ans.get("members", []), [1, 2])
	var told := _first_op(_sends_to(joined, 10))
	_check("and tells the host", told.get("op", ""), "joined")
	_check("who arrived", int(told.get("member", -1)), 2)

	var payload := PackedByteArray([1, 2, 3])
	var routed := r.handle(20, CH, MODE, RelayFrame.route(1, payload), 0)
	_check("a joiner's packet to member 1 reaches the host's peer", routed.size(), 1)
	_check("on the same channel", int(routed[0][2]), CH)
	_check("with the source byte", RelayFrame.unroute(routed[0][4]), [2, payload])
	var down := r.handle(10, CH, MODE, RelayFrame.route(2, payload), 0)
	_check("the host reaches member 2's peer", int(down[0][1]), 20)
	r.connect_peer(30, 0)
	r.handle(30, CH, MODE, _op({"op": "join", "code": code, "protocol": SessionRules.RELAY_PROTOCOL}), 0)
	var bc := r.handle(10, CH, MODE, RelayFrame.route(RelayFrame.BROADCAST, payload), 0)
	_check("a host broadcast reaches every joiner", bc.size(), 2)
	var gone := r.handle(10, CH, MODE, RelayFrame.route(4, payload), 0)
	_check("a packet to an absent member is dropped silently", gone, [])
	_check("stats count the forwards", int(r.stats()["forwarded"]) >= 4, true)

func refusals() -> void:
	var r := RelayRooms.new(3)
	var code := _room(r)
	r.connect_peer(99, 0)
	var unknown := r.handle(99, CH, MODE, _op({"op": "join", "code": "ZZZZZZ", "protocol": SessionRules.RELAY_PROTOCOL}), 0)
	_check("an unknown code is refused", _first_op(unknown).get("reason", ""), "unknown")
	_check("and the peer dropped", _drops(unknown), [99])
	r.connect_peer(98, 0)
	var proto := r.handle(98, CH, MODE, _op({"op": "join", "code": code, "protocol": 99}), 0)
	_check("a protocol mismatch is refused bad", _first_op(proto).get("reason", ""), "bad")
	for p in [30, 40]:
		r.connect_peer(p, 0)
		r.handle(p, CH, MODE, _op({"op": "join", "code": code, "protocol": SessionRules.RELAY_PROTOCOL}), 0)
	r.connect_peer(50, 0)
	var full := r.handle(50, CH, MODE, _op({"op": "join", "code": code, "protocol": SessionRules.RELAY_PROTOCOL}), 0)
	_check("a fifth member is refused full", _first_op(full).get("reason", ""), "full")
	r.connect_peer(60, 0)
	var early := r.handle(60, CH, MODE, RelayFrame.route(1, PackedByteArray([1])), 0)
	_check("a routed packet before a room drops the sender", _drops(early), [60])
	var jb := r.handle(20, CH, MODE, RelayFrame.route(RelayFrame.BROADCAST, PackedByteArray([1])), 0)
	_check("a joiner's broadcast is dropped and the joiner cut", _drops(jb), [20])
	var big := PackedByteArray()
	big.resize(SessionRules.SNAPSHOT_MAX + 1 + Protocol.ENVELOPE + 1)
	var over := r.handle(30, CH, MODE, RelayFrame.route(1, big), 0)
	_check("an oversize packet cuts the sender", _drops(over), [30])
	_check("refusals are counted", int(r.stats()["refused"]) >= 3, true)

func leaving_and_closing() -> void:
	var r := RelayRooms.new(4)
	var code := _room(r)
	var left := r.disconnect_peer(20)
	_check("a member leaving tells the host", _first_op(_sends_to(left, 10)).get("op", ""), "left")
	_check("which member", int(_first_op(_sends_to(left, 10)).get("member", -1)), 2)
	r.connect_peer(21, 0)
	var re := r.handle(21, CH, MODE, _op({"op": "join", "code": code, "protocol": SessionRules.RELAY_PROTOCOL}), 0)
	_check("the freed id is reused", int(_first_op(_sends_to(re, 21)).get("member", -1)), 2)
	var kick := r.handle(10, CH, MODE, _op({"op": "kick", "member": 2}), 0)
	_check("a kick drops the member", _drops(kick), [21])
	r.connect_peer(22, 0)
	r.handle(22, CH, MODE, _op({"op": "join", "code": code, "protocol": SessionRules.RELAY_PROTOCOL}), 0)
	var closed := r.disconnect_peer(10)
	_check("the host leaving closes the room for the joiner", _first_op(_sends_to(closed, 22)).get("op", ""), "closed")
	_check("and drops it", _drops(closed), [22])
	_check("the room is gone", r.rooms.has(code), false)
	r.connect_peer(23, 0)
	var late := r.handle(23, CH, MODE, _op({"op": "join", "code": code, "protocol": SessionRules.RELAY_PROTOCOL}), 0)
	_check("a join after close is unknown", _first_op(late).get("reason", ""), "unknown")

func expiry_and_hygiene() -> void:
	var r := RelayRooms.new(5)
	r.connect_peer(10, 0)
	var made := r.handle(10, CH, MODE, _op({"op": "create", "protocol": SessionRules.RELAY_PROTOCOL}), 0)
	var code: String = _first_op(made).get("code", "")
	r.disconnect_peer(10)
	_check("a room dies with its host", r.rooms.has(code), false)
	r.connect_peer(11, 0)
	r.handle(11, CH, MODE, _op({"op": "create", "protocol": SessionRules.RELAY_PROTOCOL}), 1000)
	# A host alone in the lobby sends nothing until someone joins, so a short
	# grace cut every host whose friend was slow to type the code.
	var waiting := r.expire(1000 + 120000)
	_check("a creator still waiting alone after two minutes is kept", _drops(waiting), [])
	var silent := r.expire(1000 + RelayRooms.CREATE_GRACE_MS + 1)
	_check("a creator silent past the idle limit is dropped", _drops(silent), [11])
	r.connect_peer(12, 0)
	var junk := r.handle(12, CH, MODE, _op({"op": "kick", "member": 1}), 0)
	_check("an op before create/join drops the sender", _drops(junk), [12])
	r.connect_peer(13, 0)
	var garbage := r.handle(13, CH, MODE, PackedByteArray([RelayFrame.RELAY_PEER, 1, 2]), 0)
	_check("undecodable bytes drop the sender", _drops(garbage), [13])
