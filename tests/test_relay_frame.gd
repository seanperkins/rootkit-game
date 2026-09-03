extends SceneTree

## The relay's wire format: a one-byte route and a bounded primitive op.

var failures := 0

func _init() -> void:
	print("ROOTKIT — relay frame\n")
	route_round_trips()
	ops_round_trip_and_refuse_garbage()
	codes_are_six_from_the_alphabet()
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

func route_round_trips() -> void:
	var body := PackedByteArray([9, 8, 7])
	var framed := RelayFrame.route(3, body)
	_check("the route is one byte", framed.size(), 4)
	_check("the member is first", framed[0], 3)
	var back := RelayFrame.unroute(framed)
	_check("unroute returns the member", back[0], 3)
	_check("and the bytes verbatim", back[1], body)
	_check("broadcast is zero", RelayFrame.route(RelayFrame.BROADCAST, body)[0], 0)
	_check("an empty packet unroutes to nothing", RelayFrame.unroute(PackedByteArray()), [])
	_check("a routed packet is not an op", RelayFrame.is_op(framed), false)

func ops_round_trip_and_refuse_garbage() -> void:
	var bytes := RelayFrame.encode_op({"op": "join", "code": "ABC234", "protocol": 1})
	_check("an op is addressed to the relay", bytes[0], RelayFrame.RELAY_PEER)
	_check("and reads as one", RelayFrame.is_op(bytes), true)
	var op := RelayFrame.decode_op(bytes)
	_check("the op comes back", op.get("op", ""), "join")
	_check("with its code", op.get("code", ""), "ABC234")
	_check("a routed packet decodes to no op", RelayFrame.decode_op(RelayFrame.route(1, PackedByteArray([1]))), {})
	var big := RelayFrame.encode_op({"op": "x", "pad": "y".repeat(SessionRules.RELAY_OP_MAX)})
	_check("an oversize op is refused", RelayFrame.decode_op(big), {})
	var not_dict := PackedByteArray([RelayFrame.RELAY_PEER]) + var_to_bytes([1, 2, 3])
	_check("a non-dictionary op is refused", RelayFrame.decode_op(not_dict), {})
	var nested := PackedByteArray([RelayFrame.RELAY_PEER]) + var_to_bytes({"op": "join", "code": {"a": 1}})
	_check("a nested value is refused", RelayFrame.decode_op(nested), {})
	_check("a bare relay byte is refused", RelayFrame.decode_op(PackedByteArray([RelayFrame.RELAY_PEER])), {})

func codes_are_six_from_the_alphabet() -> void:
	_check("six alphabet characters is a code", RelayFrame.is_code("ABC234"), true)
	_check("lower case is accepted", RelayFrame.is_code("abc234"), true)
	_check("and normalised upper", RelayFrame.normalise_code(" abc234 "), "ABC234")
	_check("five characters is not a code", RelayFrame.is_code("ABC23"), false)
	_check("an ambiguous glyph is not", RelayFrame.is_code("ABC1O0"), false)
	_check("an address is not", RelayFrame.is_code("127.0.0.1"), false)
	_check("empty is not", RelayFrame.is_code(""), false)
