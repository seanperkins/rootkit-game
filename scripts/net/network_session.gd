class_name NetworkSession extends RefCounted

## The immutable session descriptor and this peer's place in it.
##
## PURE, like the build layer: no scene tree, no engine singleton beyond
## RefCounted. It holds the frozen facts every peer must agree on — protocol,
## session id, seed, input delay, choice timeout, and the roster of players with
## their derived-from counters — plus which slot this process drives.
##
## The descriptor is the SINGLE source the simulation derives itself from. Two
## peers that validate the same raw descriptor to the same bytes will seed every
## RNG the same way and compile every player's starting build the same way. That
## is the whole basis of lockstep: identical starting state, then identical
## inputs, then identical simulation.
##
## Later tasks add the roster machinery, recovery boundaries, and ending
## barriers. This task establishes the descriptor and its hostile-safe
## validation.

enum Role { SOLO, HOST, CLIENT }

## protocol, session_id, seed, delay, choice_timeout, roster. Frozen after START;
## never mutated in place by the simulation.
var descriptor: Dictionary = {}

## Which roster slot this process's local input drives.
var local_slot: int = 0

var role: int = Role.SOLO

## The session's input ring. The run constructs it and binds it here so the
## transport can submit records and checksum reports without holding a node.
var lockstep: Lockstep = null

## True once START has been sent or received: the roster is frozen and a new
## participant is refused; only a reconnect to an existing slot is accepted.
var started := false

## Control messages the transport has decoded and validated, oldest first, as
## {kind, body, peer}. The lobby and the run drain this; the transport never
## calls into either — it delivers here and stops.
var inbox: Array = []

## Deliver one validated control message. Pure: no branching on the transport,
## no callbacks out.
func receive(kind: int, body: Dictionary, peer: int) -> void:
	inbox.append({"kind": kind, "body": body, "peer": peer})

## Whether a HELLO may be accepted: any HELLO before START; after START only a
## reconnect naming this session and a slot the roster already holds. The
## transport asks this before the message reaches the inbox, so a refused
## joiner never gets a slot.
func accepts_hello(body: Dictionary) -> bool:
	if not started:
		return true
	if int(body.get("session_id", -1)) != int(descriptor.get("session_id", -2)):
		return false
	return not profile(int(body.get("slot", -1))).is_empty()

# ------------------------------------------------------------------- lobby ---
#
# Before START the roster is MUTABLE and lives here as `lobby_rows`, ordered by
# slot. The host assigns slots and freezes the descriptor at START; a client
# holds whatever WELCOME last told it. All of it is pure: the transport
# delivers messages to `inbox`, the lobby screen drains them and calls these.

## Mutable roster rows {slot, name, counters}, slot-ordered, valid before START.
var lobby_rows: Array = []
## peer id -> slot, for the host's bookkeeping of who holds what.
var peer_slots: Dictionary = {}
## The session parameters the host will freeze into the descriptor.
var lobby_session_id := 0
var lobby_seed := 0
var lobby_delay := SessionRules.DEFAULT_DELAY
var lobby_timeout := SessionRules.CHOICE_TIMEOUT_TICKS

## Open a lobby as host: this profile takes slot 0.
static func host_lobby(profile: Dictionary, session_id: int, seed_value: int,
		delay: int = SessionRules.DEFAULT_DELAY,
		timeout: int = SessionRules.CHOICE_TIMEOUT_TICKS) -> NetworkSession:
	var s := NetworkSession.new()
	s.role = Role.HOST
	s.local_slot = 0
	s.lobby_session_id = session_id
	s.lobby_seed = int(seed_value)
	s.lobby_delay = clampi(delay, 0, SessionRules.DEFAULT_DELAY + 4)
	s.lobby_timeout = maxi(0, timeout)
	s.lobby_rows = [_sanitise_profile(profile, 0)]
	return s

## Open a lobby as a client: no slot until WELCOME assigns one.
static func client_lobby() -> NetworkSession:
	var s := NetworkSession.new()
	s.role = Role.CLIENT
	s.local_slot = -1
	return s

## The lowest free slot, or -1 when the lobby is full or START has passed.
func free_slot() -> int:
	if started:
		return -1
	for s in SessionRules.MAX_PLAYERS:
		if profile_row(s).is_empty():
			return s
	return -1

func profile_row(slot: int) -> Dictionary:
	for row in lobby_rows:
		if int(row["slot"]) == slot:
			return row
	return {}

## Host: admit a HELLO from `peer`. A fresh joiner before START takes the
## lowest free slot; after START only a reconnect naming this session and an
## existing slot is admitted, and it does not replace that slot's name or
## counters. Returns the slot, or -1 when refused.
func admit(hello: Dictionary, peer: int) -> int:
	if started:
		if int(hello.get("session_id", -1)) != int(descriptor.get("session_id", -2)):
			return -1
		var want := int(hello.get("slot", -1))
		if profile(want).is_empty():
			return -1
		peer_slots[peer] = want
		return want
	var slot := free_slot()
	if slot < 0:
		return -1
	lobby_rows.append(_sanitise_profile(hello, slot))
	lobby_rows.sort_custom(func(a, b): return a["slot"] < b["slot"])
	peer_slots[peer] = slot
	return slot

## Host: a peer left before START — its slot is freed. After START the slot
## stays in the frozen roster (parking is the run's business).
func remove_peer(peer: int) -> void:
	if not peer_slots.has(peer):
		return
	var slot := int(peer_slots[peer])
	peer_slots.erase(peer)
	if started:
		return
	for k in lobby_rows.size():
		if int(lobby_rows[k]["slot"]) == slot:
			lobby_rows.remove_at(k)
			break

## The descriptor the current lobby would freeze into.
func lobby_descriptor() -> Dictionary:
	return validate_descriptor({
		"protocol": SessionRules.PROTOCOL, "session_id": lobby_session_id,
		"seed": lobby_seed, "delay": lobby_delay, "choice_timeout": lobby_timeout,
		"roster": lobby_rows.duplicate(true)})

## Host: freeze. From here the roster is immutable and new joiners are refused.
func start() -> Dictionary:
	descriptor = lobby_descriptor()
	started = not descriptor.is_empty()
	return descriptor

## Client: a WELCOME carries the host's current roster and this peer's slot
## (or -1 for a refresh that keeps the slot already assigned).
func apply_welcome(body: Dictionary) -> bool:
	var desc: Dictionary = body.get("descriptor", {})
	if desc.is_empty():
		return false
	descriptor = desc
	lobby_rows = (desc["roster"] as Array).duplicate(true)
	lobby_session_id = int(desc["session_id"])
	var slot := int(body.get("slot", -1))
	if slot >= 0:
		local_slot = slot
	return true

## Client: START freezes the descriptor. Refused when it names another session
## than the one WELCOME announced, or does not hold this peer's slot.
func apply_start(body: Dictionary) -> bool:
	var desc: Dictionary = body.get("descriptor", {})
	if desc.is_empty():
		return false
	if lobby_session_id != 0 and int(desc["session_id"]) != lobby_session_id:
		return false
	descriptor = desc
	if profile(local_slot).is_empty():
		return false
	started = true
	return true

## Bind a validated descriptor to this peer's slot and role.
static func create(desc: Dictionary, slot: int, role_value: int) -> NetworkSession:
	var s := NetworkSession.new()
	s.descriptor = desc
	s.local_slot = slot
	s.role = role_value
	return s

## A one-slot descriptor for offline play: this peer is the only player, input
## has no delay (its own record is always present), and offers never time out
## because there is no one else to wait on.
static func solo_descriptor(profile: Dictionary, seed: int) -> Dictionary:
	return {
		"protocol": SessionRules.PROTOCOL,
		"session_id": 0,
		"seed": int(seed),
		"delay": 0,
		"choice_timeout": 0,
		"roster": [_sanitise_profile(profile, 0)],
	}

## Validate a raw descriptor received off the wire or built locally, returning a
## clean copy or an EMPTY dictionary on any violation. Everything is treated as
## hostile: wrong protocol, non-finite numbers, an oversized or malformed roster,
## duplicate or out-of-range slots, and overlong names are all rejected rather
## than clamped, because a descriptor that differs between peers by even one byte
## desyncs the whole run.
static func validate_descriptor(raw) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	if int(_num(raw.get("protocol", -1), -1.0)) != SessionRules.PROTOCOL:
		return {}
	if not _is_number(raw.get("seed", null)):
		return {}
	if not _is_number(raw.get("session_id", 0)):
		return {}
	var delay := int(_num(raw.get("delay", -1), -1.0))
	if delay < 0 or delay > SessionRules.DEFAULT_DELAY + 4:
		return {}
	var timeout := int(_num(raw.get("choice_timeout", -1), -1.0))
	if timeout < 0:
		return {}
	var roster = raw.get("roster", null)
	if typeof(roster) != TYPE_ARRAY:
		return {}
	if roster.is_empty() or roster.size() > SessionRules.MAX_PLAYERS:
		return {}
	var clean_roster: Array = []
	var seen_slots := {}
	for row in roster:
		if typeof(row) != TYPE_DICTIONARY:
			return {}
		var slot := int(_num(row.get("slot", -1), -1.0))
		if slot < 0 or slot >= SessionRules.MAX_PLAYERS:
			return {}
		if seen_slots.has(slot):
			return {}
		seen_slots[slot] = true
		var name_raw = row.get("name", "")
		if typeof(name_raw) != TYPE_STRING:
			return {}
		if (name_raw as String).length() > SessionRules.NAME_MAX:
			return {}
		clean_roster.append(_sanitise_profile(row, slot))
	# Stable slot order, so two peers that received the rows in different orders
	# still hash to the same descriptor.
	clean_roster.sort_custom(func(a, b): return a["slot"] < b["slot"])
	return {
		"protocol": SessionRules.PROTOCOL,
		"session_id": int(_num(raw.get("session_id", 0), 0.0)),
		"seed": int(_num(raw.get("seed", 0), 0.0)),
		"delay": delay,
		"choice_timeout": timeout,
		"roster": clean_roster,
	}

## The roster row for a slot, or an empty dictionary if that slot is unmanned.
func profile(slot: int) -> Dictionary:
	for row in descriptor.get("roster", []):
		if int(row.get("slot", -1)) == slot:
			return row
	return {}

## A canonical profile row: slot, a length-checked name, and hostile-sanitised
## counters. Names are trimmed to the cap here as a last resort; validation
## rejects an overlong one before it ever reaches this point.
static func _sanitise_profile(raw, slot: int) -> Dictionary:
	var name := ""
	var counters = null
	if typeof(raw) == TYPE_DICTIONARY:
		var n = raw.get("name", "")
		if typeof(n) == TYPE_STRING:
			name = (n as String).substr(0, SessionRules.NAME_MAX)
		counters = raw.get("counters", null)
	return {
		"slot": slot,
		"name": name,
		"counters": SaveGame.sanitise_session_counters(counters),
	}

static func _is_number(v) -> bool:
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return false
	return is_finite(float(v))

static func _num(v, fallback: float) -> float:
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return fallback
	var f := float(v)
	return f if is_finite(f) else fallback
