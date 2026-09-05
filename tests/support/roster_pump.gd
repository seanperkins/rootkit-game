class_name RosterPump extends RefCounted

## The control wire, by hand, for the parking, reconnect and ending suites:
## after every harness step, forward what each peer would have sent. ABSENT
## and PRESENT ticks host -> clients, RESYNC host -> clients, END_CHECK host
## -> clients, reports and candidates clients -> host, snapshots host ->
## targets, END host -> clients. A peer the host sees ABSENT, or one that is
## reconnecting, is off the wire.

var h: MultiplayerHarness
var _forwarded_reports: Dictionary = {}
var _forwarded_candidates: Dictionary = {}
var _delivered_snapshot := -1
## boundary tick -> the slots the host named as targets when it announced.
var _targets: Dictionary = {}
## Snapshots delivered as [slot, tick], in order.
var deliveries: Array = []

func _init(harness: MultiplayerHarness) -> void:
	h = harness

func relay() -> void:
	var host: Node2D = h.runs[0]
	var es: NetworkSession = host._session
	if es.resync_tick >= 0:
		_targets[es.resync_tick] = es.resync_targets
	for k in range(1, h.runs.size()):
		var c: Node2D = h.runs[k]
		var cs: NetworkSession = c._session
		if cs.reconnecting or host.slot_state[c.local_slot] == host.SlotState.ABSENT:
			continue
		# An ABSENT names a tick this peer has not consumed yet; one for a tick
		# behind it was never on its wire (a returnee restored past it).
		for slot in es.absent_ticks.keys():
			var t := int(es.absent_ticks[slot])
			if t >= c.lockstep.executed and c.slot_state[slot] != c.SlotState.ABSENT \
					and not c._pending_absent.has(slot) \
					and int(cs.absent_ticks.get(slot, -1)) != t:
				c._pending_absent[slot] = t
		if es.resync_tick >= 0 and cs.resync_tick != es.resync_tick:
			c.announce_resync(es.resync_tick)
		if es.end_check_tick >= 0 and cs.end_check_tick != es.end_check_tick:
			c.receive_end_check(es.end_check_tick)
		# _terminal sends on the transition, not once per tick. Fabricating a
		# candidate at the check tick would be mistaken for a zero-hash report
		# before the client's real report can arrive.
		var previous: int = _forwarded_candidates.get(k, NetworkSession.Outcome.NONE)
		_forwarded_candidates[k] = cs.end_outcome
		if cs.end_outcome != NetworkSession.Outcome.NONE and cs.end_outcome != previous:
			host.receive_end_candidate(c.local_slot, c.tick, cs.end_outcome, 0)
		if cs.end_reported and not _forwarded_reports.has([k, cs.end_report[0]]):
			_forwarded_reports[[k, cs.end_report[0]]] = true
			host.receive_end_candidate(c.local_slot, cs.end_report[0], cs.end_report[2], cs.end_report[1])
		if es.ended and not cs.ended:
			c.receive_end(0, es.end_outcome)
	if host.last_snapshot_tick >= 0 and host.last_snapshot_tick != _delivered_snapshot:
		_delivered_snapshot = host.last_snapshot_tick
		var targets: PackedInt32Array = _targets.get(host.last_snapshot_tick, PackedInt32Array())
		for k in range(1, h.runs.size()):
			var c: Node2D = h.runs[k]
			if c._session.resync_tick == host.last_snapshot_tick and targets.has(c.local_slot):
				c.apply_snapshot(host.last_snapshot, host.last_snapshot_tick)
				deliveries.append([c.local_slot, host.last_snapshot_tick])

## Step everyone `n` times with checksums on the cadence and the wire pumped.
func run(n: int, fn: Callable) -> void:
	for _i in n:
		h.step(fn)
		if h.runs[0].tick % SessionRules.CHECKSUM_INTERVAL == 0:
			h.distribute_checksums()
		relay()
		h.catch_up(fn, 8)
