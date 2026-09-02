extends SceneTree

## The pure lockstep ring: readiness, roster masking, immutability, ring wrap
## bounds, checksums, and the recovery window. Everything here runs without a
## viewport or a socket — the ring is a RefCounted, which is the whole point.

var failures := 0
var finished := {}

const CASES := ["live_readiness", "dead_records_ignored", "absent_records_empty",
	"primed_ticks_ready", "immutable_resubmission", "wrap_recycles_cells",
	"exclusive_ring_bound", "records_stored_verbatim",
	"checksum_agreement_and_desync", "snapshot_window_merge",
	"the_record_carries_an_aim_on_the_wire"]

func _initialize() -> void:
	print("ROOTKIT — lockstep ring\n")
	live_readiness()
	dead_records_ignored()
	absent_records_empty()
	primed_ticks_ready()
	immutable_resubmission()
	wrap_recycles_cells()
	exclusive_ring_bound()
	records_stored_verbatim()
	checksum_agreement_and_desync()
	snapshot_window_merge()
	the_record_carries_an_aim_on_the_wire()
	print("")
	for c in CASES:
		if not finished.has(c):
			print("  FAIL  case '%s' never finished — it aborted part way" % c)
			failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _check_true(label: String, got: bool) -> void:
	_check(label, got, true)

func _out() -> Array:
	var m := PackedVector2Array(); m.resize(SessionRules.MAX_PLAYERS)
	var c := PackedInt32Array(); c.resize(SessionRules.MAX_PLAYERS)
	var t := PackedInt32Array(); t.resize(SessionRules.MAX_PLAYERS)
	var o := PackedInt32Array(); o.resize(SessionRules.MAX_PLAYERS)
	return [m, c, t, o]

## Two LIVE slots: a tick is not ready until BOTH records have arrived, and
## consuming it advances executed by one.
func live_readiness() -> void:
	var ls := Lockstep.new(2, 0)
	_check("a fresh ring is at tick zero", ls.executed, 0)
	_check("both slots are required", ls._required, 0b11)
	_check_true("one record is not enough",
		ls.submit(0, 0, Vector2.RIGHT, -1, -1, -1) and not ls.ready(0))
	_check_true("both records make the tick ready",
		ls.submit(1, 0, Vector2.LEFT, -1, -1, -1) and ls.ready(0))
	var o := _out()
	_check_true("take consumes the tick", ls.take(0, o[0], o[1], o[2], o[3]))
	_check("slot zero's move is delivered", o[0][0], Vector2.RIGHT)
	_check("slot one's move is delivered", o[0][1], Vector2.LEFT)
	_check("executed advanced to one", ls.executed, 1)
	finished["live_readiness"] = true

## A DEAD slot is not required: the tick is ready without its record, and take
## delivers a neutral record for it.
func dead_records_ignored() -> void:
	var ls := Lockstep.new(2, 0)
	ls.mark_dead(1)
	_check("only the live slot is required", ls._required, 0b01)
	ls.submit(0, 0, Vector2.RIGHT, -1, -1, -1)
	_check_true("a dead slot does not block readiness", ls.ready(0))
	var o := _out()
	ls.take(0, o[0], o[1], o[2], o[3])
	_check("the dead slot takes a neutral move", o[0][1], Vector2.ZERO)
	finished["dead_records_ignored"] = true

## An ABSENT slot submits nothing and is skipped by readiness; take delivers
## neutral records for it.
func absent_records_empty() -> void:
	var ls := Lockstep.new(2, 0)
	ls.mark_absent(1)
	_check("an absent slot cannot submit",
		ls.submit(1, 0, Vector2.RIGHT, 2, 0, 0), false)
	ls.submit(0, 0, Vector2.LEFT, -1, -1, -1)
	_check_true("the run is ready without the absent slot", ls.ready(0))
	var o := _out()
	ls.take(0, o[0], o[1], o[2], o[3])
	_check("the absent slot's move is zero", o[0][1], Vector2.ZERO)
	_check("and its card is none", o[1][1], -1)
	finished["absent_records_empty"] = true

## The opening `delay` ticks are primed with neutral records, so they are ready
## before any peer has sent input.
func primed_ticks_ready() -> void:
	var ls := Lockstep.new(1, 2)
	ls.prime(0, 1)
	_check_true("primed tick zero is ready", ls.ready(0))
	_check_true("primed tick one is ready", ls.ready(1))
	var o := _out()
	_check_true("tick zero takes", ls.take(0, o[0], o[1], o[2], o[3]))
	_check("a primed record is neutral", o[0][0], Vector2.ZERO)
	_check_true("tick one takes", ls.take(1, o[0], o[1], o[2], o[3]))
	_check("executed is past the primed window", ls.executed, 2)
	finished["primed_ticks_ready"] = true

## A record is immutable once submitted: a second submit for the same slot and
## tick is a no-op that changes nothing.
func immutable_resubmission() -> void:
	var ls := Lockstep.new(1, 0)
	_check_true("the first submit stores",
		ls.submit(0, 0, Vector2.RIGHT, 1, 0, 5))
	_check("a resubmit is refused",
		ls.submit(0, 0, Vector2.LEFT, 2, 1, 9), false)
	var o := _out()
	ls.take(0, o[0], o[1], o[2], o[3])
	_check("the original move survives the resubmit", o[0][0], Vector2.RIGHT)
	_check("the original card survives", o[1][0], 1)
	_check("the original offer survives", o[3][0], 5)
	finished["immutable_resubmission"] = true

## Cells recycle correctly across a full ring wrap: tick RING reuses tick zero's
## cell, and a stale tag is cleared before the newer tick writes.
func wrap_recycles_cells() -> void:
	var ls := Lockstep.new(1, 0)
	var o := _out()
	var ok := true
	for t in Lockstep.RING + 4:
		var m := Vector2(float(t), 0.0)
		if not ls.submit(0, t, m, t % 3, -1, -1):
			ok = false
		if not ls.take(t, o[0], o[1], o[2], o[3]):
			ok = false
		if o[0][0] != m:
			ok = false
	_check_true("every tick across a full wrap round-trips its own record", ok)
	_check("executed reached the last tick", ls.executed, Lockstep.RING + 4)
	finished["wrap_recycles_cells"] = true

## The ring window's upper bound is exclusive: executed + RING aliases the
## current cell and must be rejected without clearing it.
func exclusive_ring_bound() -> void:
	var ls := Lockstep.new(1, 0)
	_check("a stale tick below executed is dropped",
		ls.submit(0, -1, Vector2.RIGHT, -1, -1, -1), false)
	_check_true("the current tick submits", ls.submit(0, 0, Vector2.UP, -1, -1, -1))
	_check("executed + RING aliases the current cell and is rejected",
		ls.submit(0, Lockstep.RING, Vector2.DOWN, -1, -1, -1), false)
	_check_true("and the current cell was not cleared by that attempt",
		ls.ready(0))
	var o := _out()
	ls.take(0, o[0], o[1], o[2], o[3])
	_check("the current record is intact", o[0][0], Vector2.UP)
	finished["exclusive_ring_bound"] = true

## The ring stores field VALUES verbatim — a card, target, or offer out of range
## is the application's problem, not the ring's, so nothing is clamped or
## rewritten in transit. Slot-range validation still rejects a bad slot.
func records_stored_verbatim() -> void:
	var ls := Lockstep.new(1, 0)
	_check("an out-of-range slot is rejected",
		ls.submit(9, 0, Vector2.RIGHT, 0, 0, 0), false)
	_check("a negative slot is rejected",
		ls.submit(-1, 0, Vector2.RIGHT, 0, 0, 0), false)
	ls.submit(0, 0, Vector2(2.0, -3.0), 99, 42, 77)
	var o := _out()
	ls.take(0, o[0], o[1], o[2], o[3])
	_check("an out-of-range card is stored unchanged", o[1][0], 99)
	_check("an out-of-range target is stored unchanged", o[2][0], 42)
	_check("an out-of-range offer is stored unchanged", o[3][0], 77)
	_check("the raw move is stored unchanged", o[0][0], Vector2(2.0, -3.0))
	finished["records_stored_verbatim"] = true

## Peers agree until they don't: matching hashes leave desync_at at -1, the first
## disagreeing tick reports itself, reports are immutable, and pruning drops old
## ticks without losing the disagreement.
func checksum_agreement_and_desync() -> void:
	var ls := Lockstep.new(2, 0)
	ls.submit_checksum(0, 60, 111)
	ls.submit_checksum(1, 60, 111)
	_check("agreeing hashes report no desync", ls.desync_at(), -1)
	_check("a duplicate report for a slot is refused",
		ls.submit_checksum(0, 60, 999), false)
	_check("the original hash still stands", ls.desync_at(), -1)
	ls.submit_checksum(0, 120, 222)
	ls.submit_checksum(1, 120, 333)
	_check("a disagreement reports its tick", ls.desync_at(), 120)
	ls.prune_checksums(60)
	_check("pruning old ticks keeps the later disagreement", ls.desync_at(), 120)
	finished["checksum_agreement_and_desync"] = true

## The recovery window round-trips through snapshot and merge, and merge never
## overwrites a record already present.
func snapshot_window_merge() -> void:
	var src := Lockstep.new(2, 3)
	# Fill the window (0, 3]: ticks 1..3, both slots.
	for t in [1, 2, 3]:
		src.submit(0, t, Vector2(float(t), 0.0), -1, -1, -1)
		src.submit(1, t, Vector2(0.0, float(t)), -1, -1, -1)
	var snap := src.snapshot_window(0)
	_check("the window carries every record in it", snap["ticks"].size(), 6)

	var dst := Lockstep.new(2, 3)
	# Tick zero is outside the window; supply it so the ring can advance to the
	# merged ticks and read them back.
	dst.submit(0, 0, Vector2.ZERO, -1, -1, -1)
	dst.submit(1, 0, Vector2.ZERO, -1, -1, -1)
	# A record that arrived ahead of the snapshot must be kept, not overwritten.
	dst.submit(0, 1, Vector2(999.0, 0.0), 7, 7, 7)
	_check_true("the window merges", dst.merge_window(snap, 0))
	var o := _out()
	dst.take(0, o[0], o[1], o[2], o[3])
	_check_true("the merged tick one is ready", dst.ready(1))
	dst.take(1, o[0], o[1], o[2], o[3])
	_check("the already-present record was kept, not overwritten",
		o[0][0], Vector2(999.0, 0.0))
	_check("the merged record filled the other slot", o[0][1], Vector2(0.0, 1.0))

	_check("a malformed window is refused", dst.merge_window("nope", 0), false)
	finished["snapshot_window_merge"] = true

## The wire record carries the aim beside the move, in both the INPUT body
## and a RELAY record, verbatim.
func the_record_carries_an_aim_on_the_wire() -> void:
	var ctx := {"session_id": 77}
	var aim := Vector2(0.6, -0.8)
	var bytes := Protocol.encode_input(77, 5, Vector2.ONE, 1, 2, 3, aim)
	var env := Protocol.decode_envelope(bytes, ctx)
	_check_true("the envelope decodes", not env.is_empty())
	var rec: Dictionary = Protocol.decode_input(env["body"])
	_check("the body is INPUT_BODY long", (env["body"] as PackedByteArray).size(), Protocol.INPUT_BODY)
	_check("the aim comes back verbatim", rec.get("aim", null), aim)
	_check("and so does the move", rec.get("move", null), Vector2.ONE)
	var plain := Protocol.encode_input(77, 5, Vector2.ONE, 1, 2, 3)
	var plain_rec: Dictionary = Protocol.decode_input(Protocol.decode_envelope(plain, ctx)["body"])
	_check("an omitted aim is zero", plain_rec.get("aim", null), Vector2.ZERO)
	var relay := Protocol.encode_relay(77, 6, [[1, 5, Vector2.RIGHT, -1, -1, -1, aim]], [])
	var rl: Dictionary = Protocol.decode_relay(Protocol.decode_envelope(relay, ctx)["body"])
	_check_true("the relay decodes", not rl.is_empty())
	_check("a relay record is seven fields with the aim last", rl["records"][0], [1, 5, Vector2.RIGHT, -1, -1, -1, aim])
	finished["the_record_carries_an_aim_on_the_wire"] = true
