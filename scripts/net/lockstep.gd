class_name Lockstep extends RefCounted

## The pure lockstep input ring. PURE, like the build layer: no scene tree, no
## engine singleton beyond RefCounted, no clock, no connection.
##
## It holds one input record per player slot for each of the last RING ticks, a
## LIVE-slot required mask, per-tick checksum reports, and the executed cursor.
## The simulation never advances a tick until every LIVE slot's record for it has
## arrived; that gate is the whole of lockstep, and it lives here so a headless
## suite can drive it with no viewport and no network.
##
## Tick convention (shared with transport, recovery, reconnect): `executed` is
## the first tick not yet consumed. Consuming record T advances it to T + 1; a
## checksum or snapshot labelled T describes state AFTER record T was applied, so
## a snapshot at T carries the next records (T, T + delay] and restoring it
## resumes at T + 1.

const RING := 128
const _MASK := RING - 1        # RING is a power of two, so tick & _MASK is tick % RING

var executed: int = 0
var delay: int = 0
var _required: int = 0         # bitmask of LIVE slots — the records ready() waits on

## A slot is PRESENT when its controller is connected (LIVE or DEAD), LIVE when
## it is also alive. `_required = _present_mask & _live_mask`. ABSENT is simply
## not present.
var _present_mask: int = 0
var _live_mask: int = 0

var _players: int = 1

# One ring cell per tick, holding all slots. Flat arrays indexed by
# cell * MAX_PLAYERS + slot: allocation-free, cache-coherent.
var _moves: PackedVector2Array
var _cards: PackedInt32Array
var _targets: PackedInt32Array
var _offers: PackedInt32Array
## Absolute tick each cell currently holds, or -1 when empty.
var _tick_tag: PackedInt32Array
## Bitmask of slots whose record is present in each cell.
var _have: PackedInt32Array

## Per-tick checksum reports: tick -> {mask, hashes}. Reports are sparse (one per
## CHECKSUM_INTERVAL) so a dictionary is cheap; recovery prunes old ticks.
var _checksums: Dictionary = {}

func _init(players: int = 1, delay_value: int = 0) -> void:
	_players = clampi(players, 1, SessionRules.MAX_PLAYERS)
	delay = maxi(0, delay_value)
	var cells := RING * SessionRules.MAX_PLAYERS
	_moves = PackedVector2Array(); _moves.resize(cells)
	_cards = PackedInt32Array(); _cards.resize(cells)
	_targets = PackedInt32Array(); _targets.resize(cells)
	_offers = PackedInt32Array(); _offers.resize(cells)
	_tick_tag = PackedInt32Array(); _tick_tag.resize(RING); _tick_tag.fill(-1)
	_have = PackedInt32Array(); _have.resize(RING)
	# Every roster slot starts LIVE and PRESENT; the run marks deaths, parks, and
	# returns as they happen.
	for slot in _players:
		_present_mask |= 1 << slot
		_live_mask |= 1 << slot
	_recompute_required()

func _recompute_required() -> void:
	_required = _present_mask & _live_mask

# ----------------------------------------------------------- slot roster ---

func mark_live(slot: int) -> void:
	if _valid_slot(slot):
		_live_mask |= 1 << slot
		_present_mask |= 1 << slot
		_recompute_required()

func mark_dead(slot: int) -> void:
	if _valid_slot(slot):
		_live_mask &= ~(1 << slot)      # still present: DEAD contributes to endings
		_recompute_required()

func mark_absent(slot: int) -> void:
	if _valid_slot(slot):
		_present_mask &= ~(1 << slot)
		_recompute_required()

func mark_present(slot: int) -> void:
	if _valid_slot(slot):
		_present_mask |= 1 << slot
		_recompute_required()

func _valid_slot(slot: int) -> bool:
	return slot >= 0 and slot < SessionRules.MAX_PLAYERS

# --------------------------------------------------------------- records ---

## Store one slot's immutable record for a tick. Returns true only when it is
## newly stored: a duplicate for a tick already held is a no-op returning false,
## an ABSENT slot returns false, and a tick outside (executed, executed + RING)
## is dropped. The record's field VALUES are stored verbatim — sanitation is the
## application's job, not the ring's.
func submit(slot: int, tick: int, move: Vector2, card: int, target: int,
		offer: int) -> bool:
	if not _valid_slot(slot):
		return false
	if (_present_mask & (1 << slot)) == 0:
		return false                    # ABSENT slots submit nothing
	if tick < executed or tick >= executed + RING:
		return false                    # stale, or beyond the ring (exclusive)
	var cell := tick & _MASK
	if _tick_tag[cell] != tick:
		# A newer absolute tick aliases this cell: clear the stale content first.
		_tick_tag[cell] = tick
		_have[cell] = 0
	if (_have[cell] & (1 << slot)) != 0:
		return false                    # immutable: the record already stands
	var idx := cell * SessionRules.MAX_PLAYERS + slot
	_moves[idx] = move
	_cards[idx] = card
	_targets[idx] = target
	_offers[idx] = offer
	_have[cell] |= 1 << slot
	return true

## True when tick T can be consumed: its cell holds T, and every LIVE slot's
## record is present. With no LIVE slot required (all DEAD/ABSENT) a tick is ready
## immediately, so a no-LIVE terminal hold keeps lockstep and the ending barrier
## progressing rather than stalling.
func ready(tick: int) -> bool:
	var cell := tick & _MASK
	if _tick_tag[cell] != tick:
		return _required == 0
	return (_have[cell] & _required) == _required

## Fill four caller-owned, MAX_PLAYERS-sized arrays with tick T's records in slot
## order and advance executed to T + 1. Allocation-free on the hot path. Returns
## false without touching executed if T is not the next tick or is not ready. The
## consumed cell is left tagged so the retained-report window and recovery can
## still read it; it recycles naturally when tick T + RING reuses it.
func take(tick: int, out_moves: PackedVector2Array, out_cards: PackedInt32Array,
		out_targets: PackedInt32Array, out_offers: PackedInt32Array) -> bool:
	if tick != executed:
		return false
	if not ready(tick):
		return false
	var cell := tick & _MASK
	var tagged := _tick_tag[cell] == tick
	var have := _have[cell] if tagged else 0
	for slot in SessionRules.MAX_PLAYERS:
		if tagged and (have & (1 << slot)) != 0:
			var idx := cell * SessionRules.MAX_PLAYERS + slot
			out_moves[slot] = _moves[idx]
			out_cards[slot] = _cards[idx]
			out_targets[slot] = _targets[idx]
			out_offers[slot] = _offers[idx]
		else:
			out_moves[slot] = Vector2.ZERO
			out_cards[slot] = -1
			out_targets[slot] = -1
			out_offers[slot] = -1
	executed = tick + 1
	return true

## Prime ticks [first, last] with neutral records for every PRESENT slot, so the
## opening `delay` ticks of a session are immediately ready without any peer
## having sent input yet. Ticks outside the ring window are skipped.
func prime(first: int, last: int) -> void:
	for t in range(first, last + 1):
		if t < executed or t >= executed + RING:
			continue
		var cell := t & _MASK
		_tick_tag[cell] = t
		_have[cell] = _present_mask
		for slot in SessionRules.MAX_PLAYERS:
			var idx := cell * SessionRules.MAX_PLAYERS + slot
			_moves[idx] = Vector2.ZERO
			_cards[idx] = -1
			_targets[idx] = -1
			_offers[idx] = -1

# ------------------------------------------------------------- checksums ---

## Record a peer's state hash for a tick. Immutable per slot: a second report for
## the same slot and tick is a no-op returning false.
func submit_checksum(slot: int, tick: int, hash_value: int) -> bool:
	if not _valid_slot(slot):
		return false
	if not _checksums.has(tick):
		var hashes := PackedInt64Array()
		hashes.resize(SessionRules.MAX_PLAYERS)
		_checksums[tick] = {"mask": 0, "hashes": hashes}
	var rec: Dictionary = _checksums[tick]
	var bit := 1 << slot
	if (int(rec["mask"]) & bit) != 0:
		return false
	rec["hashes"][slot] = hash_value
	rec["mask"] = int(rec["mask"]) | bit
	return true

## The first tick (ascending) at which two reporting slots disagree, or -1. Only
## slots that actually reported are compared; a tick with one report cannot
## disagree yet.
func desync_at() -> int:
	var ticks := _checksums.keys()
	ticks.sort()
	for t in ticks:
		var rec: Dictionary = _checksums[t]
		var mask := int(rec["mask"])
		var hashes: PackedInt64Array = rec["hashes"]
		var ref := 0
		var have_ref := false
		for slot in SessionRules.MAX_PLAYERS:
			if (mask & (1 << slot)) == 0:
				continue
			if not have_ref:
				ref = hashes[slot]
				have_ref = true
			elif hashes[slot] != ref:
				return t
	return -1

## Drop checksum reports for ticks at or before `tick`. Recovery calls this after
## a boundary so the report window does not grow without bound.
func prune_checksums(tick: int) -> void:
	for t in _checksums.keys():
		if t <= tick:
			_checksums.erase(t)

# ------------------------------------------------- recovery ring window ---

## The ring's records for (after_tick, after_tick + delay] as flat primitive
## arrays, for a recovery snapshot to carry. Only slots that submitted a record
## appear; empty cells contribute nothing.
func snapshot_window(after_tick: int) -> Dictionary:
	var ticks := PackedInt32Array()
	var slots := PackedInt32Array()
	var moves := PackedVector2Array()
	var cards := PackedInt32Array()
	var targets := PackedInt32Array()
	var offers := PackedInt32Array()
	for t in range(after_tick + 1, after_tick + delay + 1):
		var cell := t & _MASK
		if _tick_tag[cell] != t:
			continue
		for slot in SessionRules.MAX_PLAYERS:
			if (_have[cell] & (1 << slot)) == 0:
				continue
			var idx := cell * SessionRules.MAX_PLAYERS + slot
			ticks.append(t)
			slots.append(slot)
			moves.append(_moves[idx])
			cards.append(_cards[idx])
			targets.append(_targets[idx])
			offers.append(_offers[idx])
	return {"after": after_tick, "delay": delay, "ticks": ticks, "slots": slots,
		"moves": moves, "cards": cards, "targets": targets, "offers": offers}

## Merge a snapshot window into the ring WITHOUT overwriting any record already
## present — a cell whose record arrived on channel 0 while the snapshot was in
## flight on channel 1 is kept, because a record delivered once is never lost.
## Records outside (after_tick, after_tick + delay] or the ring window are
## ignored. Returns false on a malformed window rather than mutating partially.
func merge_window(raw, after_tick: int) -> bool:
	if typeof(raw) != TYPE_DICTIONARY:
		return false
	var raw_ticks = raw.get("ticks", null)
	var raw_slots = raw.get("slots", null)
	var raw_moves = raw.get("moves", null)
	var raw_cards = raw.get("cards", null)
	var raw_targets = raw.get("targets", null)
	var raw_offers = raw.get("offers", null)
	if typeof(raw_ticks) != TYPE_PACKED_INT32_ARRAY \
			or typeof(raw_slots) != TYPE_PACKED_INT32_ARRAY \
			or typeof(raw_moves) != TYPE_PACKED_VECTOR2_ARRAY \
			or typeof(raw_cards) != TYPE_PACKED_INT32_ARRAY \
			or typeof(raw_targets) != TYPE_PACKED_INT32_ARRAY \
			or typeof(raw_offers) != TYPE_PACKED_INT32_ARRAY:
		return false
	var ticks: PackedInt32Array = raw_ticks
	var slots: PackedInt32Array = raw_slots
	var moves: PackedVector2Array = raw_moves
	var cards: PackedInt32Array = raw_cards
	var targets: PackedInt32Array = raw_targets
	var offers: PackedInt32Array = raw_offers
	var n: int = ticks.size()
	if slots.size() != n or moves.size() != n or cards.size() != n \
			or targets.size() != n or offers.size() != n:
		return false
	for k in n:
		var t: int = ticks[k]
		var slot: int = slots[k]
		if t <= after_tick or t > after_tick + delay:
			continue
		if not _valid_slot(slot):
			continue
		if t < executed or t >= executed + RING:
			continue
		var cell := t & _MASK
		if _tick_tag[cell] != t:
			_tick_tag[cell] = t
			_have[cell] = 0
		if (_have[cell] & (1 << slot)) != 0:
			continue                    # keep the record already delivered
		var idx := cell * SessionRules.MAX_PLAYERS + slot
		_moves[idx] = moves[k]
		_cards[idx] = cards[k]
		_targets[idx] = targets[k]
		_offers[idx] = offers[k]
		_have[cell] |= 1 << slot
	return true
