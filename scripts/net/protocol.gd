class_name Protocol extends RefCounted

## The wire codec, PURE: bytes in, validated primitives out, and nothing else.
## No socket, no peer, no counters — the transport owns those. Every decode
## validates the envelope before it reads a body byte, and every body field is
## bounds-checked here so the simulation never sees a value it must clamp.
##
## Envelope, little-endian, 14 bytes:
##   u8  protocol version     refused unless == SessionRules.PROTOCOL
##   u8  message kind         refused unless a Message value
##   i32 session id           refused unless it matches the context (HELLO exempt)
##   i32 tick                 message-specific window, see valid_tick
##   i32 body length          refused unless it equals the bytes that follow
##
## INPUT body, 20 bytes fixed: move (two f32), card, target, offer (three i32).
## RELAY body: u8 count, then count records of slot u8 + tick i32 + the 20-byte
## input, then u8 count and that many checksum reports of slot u8 + tick i32 +
## hash i64. CHECKSUM body: hash i64. SNAPSHOT body: the snapshot bytes.
## Control bodies are var_to_bytes of a primitive Dictionary, decoded with
## bytes_to_var — never the object-constructing variant — and shape-checked
## per kind.

enum Message { HELLO, WELCOME, START, INPUT, RELAY, CHECKSUM, RESYNC, SNAPSHOT,
	ABSENT, PRESENT, LEAVE, END_CANDIDATE, END_CHECK, END }

const ENVELOPE := 14
const INPUT_BODY := 28            # move f32 x2, aim f32 x2, card, target, offer i32
const RELAY_RECORD := 33          # slot u8 + tick i32 + INPUT_BODY
const RELAY_CHECKSUM := 13        # slot u8 + tick i32 + hash i64
const RELAY_MAX_RECORDS := 255

## How far past the last announced tick a boundary must sit: delay plus a
## margin so every correct peer can still reach it in order.
const BOUNDARY_MARGIN := 3

# ------------------------------------------------------------- envelope ---

static func encode(kind: int, session_id: int, tick: int,
		body: PackedByteArray) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.put_u8(SessionRules.PROTOCOL)
	b.put_u8(kind)
	b.put_32(session_id)
	b.put_32(tick)
	b.put_32(body.size())
	b.put_data(body)
	return b.data_array

## The envelope of `bytes`, or {} when it is malformed or foreign. `context` is
## {session_id}; a HELLO is exempt from the session check because a fresh
## joiner has no session yet.
static func decode_envelope(bytes: PackedByteArray, context: Dictionary) -> Dictionary:
	if bytes.size() < ENVELOPE:
		return {}
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = bytes
	var proto := b.get_u8()
	var kind := b.get_u8()
	var session_id := b.get_32()
	var tick := b.get_32()
	var body_len := b.get_32()
	if proto != SessionRules.PROTOCOL:
		return {}
	if kind < 0 or kind >= Message.size():
		return {}
	if body_len < 0 or body_len != bytes.size() - ENVELOPE:
		return {}
	if kind != Message.HELLO and session_id != int(context.get("session_id", -1)):
		return {}
	return {"kind": kind, "session_id": session_id, "tick": tick,
		"body": bytes.slice(ENVELOPE)}

## Three DISTINCT tick windows, by message. `context` carries executed, delay
## and the announced boundary (-1 when none):
##   input     INPUT, RELAY records   — [executed, executed + RING), or, while a
##             boundary is announced, [boundary + 1, boundary + 1 + RING)
##   retained  CHECKSUM               — [executed - RING, executed + RING): a
##             report for a tick this peer has not reached yet is kept and
##             compared once it has, so a slightly-behind peer drops nothing
##   boundary  RESYNC, END_CHECK      — [executed + delay + margin, executed + RING]
## Everything else carries its tick for information and is not windowed here.
static func valid_tick(kind: int, tick: int, context: Dictionary) -> bool:
	var executed := int(context.get("executed", 0))
	var delay := int(context.get("delay", 0))
	var boundary := int(context.get("boundary", -1))
	match kind:
		Message.INPUT, Message.RELAY:
			var lo := boundary + 1 if boundary >= 0 else executed
			return tick >= lo and tick < lo + Lockstep.RING
		Message.CHECKSUM:
			return tick >= executed - Lockstep.RING and tick < executed + Lockstep.RING
		Message.RESYNC, Message.END_CHECK:
			return tick >= executed + delay + BOUNDARY_MARGIN \
				and tick <= executed + Lockstep.RING
	return true

# ---------------------------------------------------------------- input ---

static func encode_input(session_id: int, tick: int, move: Vector2, card: int,
		target: int, offer: int, aim: Vector2 = Vector2.ZERO) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	_put_record(b, move, card, target, offer, aim)
	return encode(Message.INPUT, session_id, tick, b.data_array)

static func _put_record(b: StreamPeerBuffer, move: Vector2, card: int, target: int,
		offer: int, aim: Vector2) -> void:
	b.put_float(move.x)
	b.put_float(move.y)
	b.put_float(aim.x)
	b.put_float(aim.y)
	b.put_32(card)
	b.put_32(target)
	b.put_32(offer)

static func _get_record(b: StreamPeerBuffer) -> Dictionary:
	var x := b.get_float()
	var y := b.get_float()
	var ax := b.get_float()
	var ay := b.get_float()
	return {"move": Vector2(x, y), "aim": Vector2(ax, ay), "card": b.get_32(),
		"target": b.get_32(), "offer": b.get_32()}

## The record in an INPUT body, or {} for a wrong-sized body. Field VALUES are
## returned verbatim — sanitation is the run's job at application.
static func decode_input(body: PackedByteArray) -> Dictionary:
	if body.size() != INPUT_BODY:
		return {}
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = body
	return _get_record(b)

# ---------------------------------------------------------------- relay ---

## records: Array of [slot, tick, move, card, target, offer, aim];
## checksums: Array of [slot, tick, hash].
static func encode_relay(session_id: int, tick: int, records: Array,
		checksums: Array) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	var n := mini(records.size(), RELAY_MAX_RECORDS)
	b.put_u8(n)
	for k in n:
		var r: Array = records[k]
		b.put_u8(int(r[0]))
		b.put_32(int(r[1]))
		_put_record(b, r[2], int(r[3]), int(r[4]), int(r[5]), r[6] if r.size() > 6 else Vector2.ZERO)
	var m := mini(checksums.size(), RELAY_MAX_RECORDS)
	b.put_u8(m)
	for k in m:
		var c: Array = checksums[k]
		b.put_u8(int(c[0]))
		b.put_32(int(c[1]))
		b.put_64(int(c[2]))
	return encode(Message.RELAY, session_id, tick, b.data_array)

## {records: [...], checksums: [...]} or {} when the body's declared counts do
## not match its length or a slot is out of range.
static func decode_relay(body: PackedByteArray) -> Dictionary:
	if body.size() < 2:
		return {}
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = body
	var n := b.get_u8()
	if body.size() < 1 + n * RELAY_RECORD + 1:
		return {}
	var records := []
	for k in n:
		var slot := b.get_u8()
		var tick := b.get_32()
		var rec := _get_record(b)
		if slot >= SessionRules.MAX_PLAYERS:
			return {}
		records.append([slot, tick, rec["move"], rec["card"], rec["target"], rec["offer"], rec["aim"]])
	var m := b.get_u8()
	if body.size() != 1 + n * RELAY_RECORD + 1 + m * RELAY_CHECKSUM:
		return {}
	var checksums := []
	for k in m:
		var slot := b.get_u8()
		var tick := b.get_32()
		var h := b.get_64()
		if slot >= SessionRules.MAX_PLAYERS:
			return {}
		checksums.append([slot, tick, h])
	return {"records": records, "checksums": checksums}

# ------------------------------------------------------------- checksum ---

static func encode_checksum(session_id: int, tick: int, hash_value: int) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.put_64(hash_value)
	return encode(Message.CHECKSUM, session_id, tick, b.data_array)

static func decode_checksum(body: PackedByteArray) -> Dictionary:
	if body.size() != 8:
		return {}
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = body
	return {"hash": b.get_64()}

# ------------------------------------------------------------- snapshot ---

static func encode_snapshot(session_id: int, tick: int, bytes: PackedByteArray) -> PackedByteArray:
	return encode(Message.SNAPSHOT, session_id, tick, bytes)

# -------------------------------------------------------------- control ---

static func encode_control(kind: int, session_id: int, tick: int,
		body: Dictionary) -> PackedByteArray:
	return encode(kind, session_id, tick, var_to_bytes(body))

## The validated body of a control message, with "kind" and "tick" added, or
## {} on any violation. Bodies are decoded with bytes_to_var only, bounded by
## CONTROL_MAX, and shape-checked per kind; a field the shape does not name is
## dropped rather than passed through.
static func decode_control(kind: int, tick: int, body: PackedByteArray) -> Dictionary:
	if body.size() > SessionRules.CONTROL_MAX:
		return {}
	var raw = bytes_to_var(body)
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var out := {}
	match kind:
		Message.HELLO:
			if int(_num(raw.get("protocol", -1))) != SessionRules.PROTOCOL:
				return {}
			var name = raw.get("name", "")
			if typeof(name) != TYPE_STRING or name.length() > SessionRules.NAME_MAX:
				return {}
			var slot := int(_num(raw.get("slot", -1)))
			if slot < -1 or slot >= SessionRules.MAX_PLAYERS:
				return {}
			out = {"protocol": SessionRules.PROTOCOL, "name": name,
				"session_id": int(_num(raw.get("session_id", 0))), "slot": slot,
				"counters": SaveGame.sanitise_session_counters(raw.get("counters", null))}
		Message.WELCOME, Message.START:
			var desc := NetworkSession.validate_descriptor(raw.get("descriptor", null))
			if desc.is_empty():
				return {}
			var slot := int(_num(raw.get("slot", -1)))
			if slot < -1 or slot >= SessionRules.MAX_PLAYERS:
				return {}
			out = {"descriptor": desc, "slot": slot}
		Message.RESYNC:
			out = {"clears_end": bool(raw.get("clears_end", false))}
		Message.ABSENT, Message.PRESENT, Message.LEAVE:
			var slot := int(_num(raw.get("slot", -1)))
			if slot < 0 or slot >= SessionRules.MAX_PLAYERS:
				return {}
			out = {"slot": slot}
		Message.END_CANDIDATE, Message.END:
			var outcome := int(_num(raw.get("outcome", -1)))
			if outcome < 0 or outcome >= NetworkSession.Outcome.size():
				return {}
			out = {"outcome": outcome, "hash": int(_num(raw.get("hash", 0)))}
		Message.END_CHECK:
			out = {}
		_:
			return {}
	out["kind"] = kind
	out["tick"] = tick
	return out

static func is_control(kind: int) -> bool:
	return kind != Message.INPUT and kind != Message.RELAY \
		and kind != Message.CHECKSUM and kind != Message.SNAPSHOT

static func _num(v) -> float:
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return -1.0
	var f := float(v)
	return f if is_finite(f) else -1.0
