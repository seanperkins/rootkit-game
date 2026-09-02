class_name MultiplayerHarness extends RefCounted

## Deterministic multi-instance stepping with an in-memory message pump. NOT a
## suite: a support object the multiplayer suites drive.
##
## It stands up N `Run` nodes from ONE descriptor, each believing it is a
## different slot, and feeds every peer the same slot records — in a different
## arrival order per peer — stepping each only when its own ring is ready. No
## ENet: the transport is tested separately, and this proves the SIMULATION is
## the same on every machine given the same records, which is the claim
## lockstep rests on.

const DT := 1.0 / 60.0

var runs: Array = []
var players := 1
var delay := 0
## slot -> [from, until]: that slot's records for ticks in the range are
## withheld from every peer — the wire after its controller dropped. Its own
## run is not stepped while its next record falls in the range. `until` is
## the last primed tick of a return; before one it is unbounded.
var withheld: Dictionary = {}

## Stand up `count` peers on one session. Each is driven only by explicit
## ticks: the engine's own physics callback is disabled after ready, or the
## peers would drift out of step with each other and with the pump.
func setup(tree: SceneTree, count: int, delay_value: int, seed_value: int,
		timeout: int = 0) -> void:
	players = count
	delay = delay_value
	var rows := []
	for s in count:
		rows.append({"slot": s, "name": "p%d" % s,
			"counters": SaveGame.session_counters()})
	var desc := NetworkSession.validate_descriptor({
		"protocol": SessionRules.PROTOCOL, "session_id": 1, "seed": seed_value,
		"delay": delay_value, "choice_timeout": timeout, "roster": rows})
	for s in count:
		var r: Node2D = load("res://scenes/run.tscn").instantiate()
		var role := NetworkSession.Role.HOST if s == 0 else NetworkSession.Role.CLIENT
		r.configure_session(NetworkSession.create(desc, s, role))
		r.external_drive = true
		r.input_override = Vector2.ZERO
		tree.root.add_child(r)
		runs.append(r)
	await tree.process_frame

func teardown() -> void:
	for r in runs:
		r.free()
	runs = []

## The choice slot `s` makes for its open offer, as every peer sees it: the
## first option, always. Identical on every peer because the offer state is.
func _choice_for(r: Node2D, s: int) -> Vector3i:
	var open: Dictionary = r._offer_open[s]
	if open.is_empty():
		return Vector3i(-1, -1, -1)
	return Vector3i(0, 0, int(open["seq"]))

## The record every slot sends for tick `t`: the caller's movement function,
## with a peer whose local overlay is up, whose slot is not LIVE, or whose
## world is in a terminal hold sending neutral movement — and every other peer
## receiving that same neutral record, exactly as the wire would.
func _records_for(t: int, moves_fn: Callable) -> Array:
	var m: Array = moves_fn.call(t)
	for r in runs:
		if r.user_paused or r.slot_state[r.local_slot] != r.SlotState.LIVE \
				or not r.alive or r.won:
			m[r.local_slot] = Vector2.ZERO
	return m

## The aims every slot sends for tick `t`, or zeros when the driver gave none.
func _aims_for(t: int, aims_fn: Callable) -> Array:
	if not aims_fn.is_valid():
		var z := []
		for _s in players:
			z.append(Vector2.ZERO)
		return z
	return aims_fn.call(t)

## Whether slot `s` is off the wire for tick `t`.
func _withheld(s: int, t: int) -> bool:
	if not withheld.has(s):
		return false
	var w: Array = withheld[s]
	return t >= int(w[0]) and t <= int(w[1])

## Submit every remote slot's record for every tick this peer could still
## need, [executed, t], in a per-peer rotated order. A record already held
## is refused, so resubmission is free; a tick skipped while a peer was away
## is filled in, as the host's relay would.
func _submit_remotes(r: Node2D, k: int, t: int, moves_fn: Callable,
		aims_fn: Callable = Callable()) -> void:
	for t2 in range(r.lockstep.executed, t + 1):
		var m := _records_for(t2, moves_fn)
		var a := _aims_for(t2, aims_fn)
		for j in players:
			var s := (j + k) % players
			if s == r.local_slot or _withheld(s, t2):
				continue
			var c := _choice_for(r, s)
			r.lockstep.submit(s, t2, (m[s] as Vector2).normalized(), c.x, c.y, c.z, a[s])

func _dropped(r: Node2D) -> bool:
	return _withheld(r.local_slot, r.lockstep.executed + r.lockstep.delay)

## One pump-and-step. Records are keyed by TICK, not by step: each peer's
## record for the tick it is running ahead of (executed + delay) is injected —
## remote slots directly, in a per-peer rotated arrival order; its own slot
## through its real poll — and the peer steps if its ring is ready. A stalled
## peer resubmits the same tick next time and the ring refuses the duplicate,
## so no tick is ever skipped or double-fed.
func step(moves_fn: Callable, aims_fn: Callable = Callable()) -> void:
	for k in runs.size():
		var r: Node2D = runs[k]
		if _dropped(r) or r._session.reconnecting:
			continue
		var t: int = r.lockstep.executed + r.lockstep.delay
		var m := _records_for(t, moves_fn)
		# The RAW vector to the poll, which normalises it exactly once; the same
		# raw vector normalised exactly once for every remote. Normalising an
		# already-normalised vector can move its last bit, and one bit is a
		# desync.
		r.input_override = m[r.local_slot]
		r.aim_override = _aims_for(t, aims_fn)[r.local_slot]
		_submit_remotes(r, k, t, moves_fn, aims_fn)
		var lc := _choice_for(r, r.local_slot)
		if lc.x != -1:
			r._local_choice = lc
		# The callback runs whether or not the tick is ready, as the engine's
		# does: a stalled peer still drains its wire and applies roster
		# changes above the guard; only the take is gated, by the ring.
		r._physics_process(DT)

## Step one peer alone, if its ring is ready — the movement function supplies
## its record for the tick it runs ahead, exactly as step() would.
func step_one(k: int, moves_fn: Callable, aims_fn: Callable = Callable()) -> bool:
	var r: Node2D = runs[k]
	if _dropped(r) or r._session.reconnecting:
		return false
	var t: int = r.lockstep.executed + r.lockstep.delay
	var m := _records_for(t, moves_fn)
	r.input_override = m[r.local_slot]
	r.aim_override = _aims_for(t, aims_fn)[r.local_slot]
	_submit_remotes(r, k, t, moves_fn, aims_fn)
	var lc := _choice_for(r, r.local_slot)
	if lc.x != -1:
		r._local_choice = lc
	var was_ready: bool = r.lockstep.ready(r.lockstep.executed)
	r._physics_process(DT)
	return was_ready

## Bring every peer up to the furthest peer's tick, one tick at a time. A peer
## that restored to an earlier tick catches up on records it already holds.
func catch_up(moves_fn: Callable, limit: int = 64) -> void:
	for _i in limit:
		var top := 0
		for r in runs:
			top = maxi(top, r.lockstep.executed)
		var behind := false
		for k in runs.size():
			if runs[k].lockstep.executed < top:
				behind = true
				step_one(k, moves_fn)
		if not behind:
			return

## Every peer reports its checksum for its current tick to every peer, as the
## wire would: CHECKSUM from clients, and the host's own in its relay.
func distribute_checksums() -> void:
	for r in runs:
		var h: int = r._state_hash()
		for other in runs:
			other.lockstep.submit_checksum(r.local_slot, r.tick, h)

func hashes() -> PackedInt64Array:
	var out := PackedInt64Array()
	for r in runs:
		out.append(r._state_hash())
	return out

func all_agree() -> bool:
	var h := hashes()
	for k in range(1, h.size()):
		if h[k] != h[0]:
			return false
	return true

## The first manifest field on which peer `b` differs from peer `a`, or "".
func first_difference(a: Node2D, b: Node2D) -> String:
	for entry in a.STATE_FIELDS:
		if (int(entry[2]) & a.HASH) == 0:
			continue
		if a._manifest_get(entry) != b._manifest_get(entry):
			return "%s.%s" % [entry[0], entry[1]]
	return ""

func total_drops() -> int:
	var n := 0
	for r in runs:
		n += r.queue.dropped
	return n
