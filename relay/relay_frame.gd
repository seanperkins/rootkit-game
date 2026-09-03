class_name RelayFrame extends RefCounted

## The relay's wire format, shared by the relay server and Transport's relay
## mode. PURE: no ENet, no tree.
##
## Routed packet: u8 member + the game's bytes verbatim. Towards the relay
## the byte is the DESTINATION (1 host, 2..4 joiners, 0 broadcast); from the
## relay it is the SOURCE. The relay never reads past that byte.
##
## Relay op: u8 RELAY_PEER + var_to_bytes of a primitive Dictionary, bounded
## by RELAY_OP_MAX and decoded with bytes_to_var — never the object variant.

const RELAY_PEER := 255
const BROADCAST := 0

static func route(member: int, bytes: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([member & 0xFF])
	out.append_array(bytes)
	return out

## [member, bytes], or [] for an empty packet.
static func unroute(bytes: PackedByteArray) -> Array:
	if bytes.is_empty():
		return []
	return [int(bytes[0]), bytes.slice(1)]

static func is_op(bytes: PackedByteArray) -> bool:
	return not bytes.is_empty() and int(bytes[0]) == RELAY_PEER

static func encode_op(op: Dictionary) -> PackedByteArray:
	var out := PackedByteArray([RELAY_PEER])
	out.append_array(var_to_bytes(op))
	return out

## The op, or {} when the bytes are not an op, are oversize, or hold anything
## but a flat Dictionary of String, int, float, bool or Array of those.
static func decode_op(bytes: PackedByteArray) -> Dictionary:
	if not is_op(bytes) or bytes.size() < 2 or bytes.size() > SessionRules.RELAY_OP_MAX + 1:
		return {}
	var v = bytes_to_var(bytes.slice(1))
	if typeof(v) != TYPE_DICTIONARY:
		return {}
	for k in v.keys():
		if typeof(k) != TYPE_STRING or not _primitive(v[k]):
			return {}
	return v

static func _primitive(x) -> bool:
	match typeof(x):
		TYPE_STRING, TYPE_INT, TYPE_FLOAT, TYPE_BOOL:
			return true
		TYPE_ARRAY:
			for e in x:
				if typeof(e) != TYPE_INT and typeof(e) != TYPE_STRING:
					return false
			return true
	return false

static func is_code(s: String) -> bool:
	var c := normalise_code(s)
	if c.length() != SessionRules.CODE_LENGTH:
		return false
	for ch in c:
		if not SessionRules.CODE_ALPHABET.contains(ch):
			return false
	return true

static func normalise_code(s: String) -> String:
	return s.strip_edges().to_upper()
