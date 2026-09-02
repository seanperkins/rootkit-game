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
