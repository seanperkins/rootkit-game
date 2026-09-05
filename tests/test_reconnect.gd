extends SceneTree

## Reconnect: a parked slot's original controller comes back with HELLO. The
## host names a boundary R, tells everyone RESYNC(R) and PRESENT(slot, R),
## serialises at R + 1 with the return applied and binds the returnee to its
## relay set in that frame. Records and the PRESENT that arrive ahead of the
## snapshot are buffered, survive the restore, and apply only after it. A
## positive-health return is placed beside the party, LIVE, required from
## R + 1 with neutral records primed; a zero-health return is DEAD and never
## required. A LIVE return latches the host against no-LIVE endings, voids an
## existing no-LIVE barrier through a flagged RESYNC, and never suppresses a
## campaign win; an aborted return clears the latch and judges no-LIVE again.

var failures := 0
var finished := {}
const DELAY := 3
const O := NetworkSession.Outcome

const CASES := ["a_live_return_restores_beside_the_party_and_resumes",
	"a_dead_return_stays_a_spectator_and_reports",
	"a_latched_live_return_suppresses_no_live_endings",
	"an_existing_no_live_barrier_is_cleared_by_the_flagged_resync",
	"an_aborted_return_judges_no_live_again",
	"a_closed_room_ends_the_run_instead_of_reconnecting",
	"same_tick_multiple_present_events_land_identically_regardless_of_order",
	"a_no_live_unsafe_reserved_pad_stays_dead_and_the_ending_policy_still_applies",
	"a_live_anchor_return_with_no_safe_ground_dies_instead_of_reviving_into_the_void"]

func _initialize() -> void:
	print("ROOTKIT — reconnect\n")
	SaveGame.use_fresh_state()
	await a_live_return_restores_beside_the_party_and_resumes()
	await a_dead_return_stays_a_spectator_and_reports()
	await a_latched_live_return_suppresses_no_live_endings()
	await an_existing_no_live_barrier_is_cleared_by_the_flagged_resync()
	await an_aborted_return_judges_no_live_again()
	await a_closed_room_ends_the_run_instead_of_reconnecting()
	await same_tick_multiple_present_events_land_identically_regardless_of_order()
	await a_no_live_unsafe_reserved_pad_stays_dead_and_the_ending_policy_still_applies()
	await a_live_anchor_return_with_no_safe_ground_dies_instead_of_reviving_into_the_void()
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

func _moves(t: int, players: int) -> Array:
	var out := []
	for s in players:
		var a := float(t) * 0.01 + float(s) * 1.7
		out.append(Vector2(cos(a), sin(a)))
	return out

func _fn(h: MultiplayerHarness) -> Callable:
	var players := h.players
	return func(t: int) -> Array: return _moves(t, players)

func _hello(slot: int) -> Dictionary:
	return {"protocol": SessionRules.PROTOCOL, "name": "p%d" % slot,
		"counters": SaveGame.session_counters(), "session_id": 1, "slot": slot}

## Three peers, running; slot two's controller drops and is parked on every
## peer, then the run goes on for a while so the returnee's state is stale.
func _parked_party(kill_two: bool) -> Array:
	var h := MultiplayerHarness.new()
	await h.setup(self, 3, DELAY, 20260830)
	var pump := RosterPump.new(h)
	var fn := _fn(h)
	pump.run(30, fn)
	var host: Node2D = h.runs[0]
	if kill_two:
		for r in h.runs:
			r._die(2)
			r.hitstop_ticks = 0
		pump.run(2, fn)
	var w: int = host.lockstep.executed + DELAY + 2
	h.withheld[2] = [w, 1 << 30]
	host.request_park(2)
	pump.run(20, fn)
	# The returnee's own view: its link broke; it stops and asks to come back.
	h.runs[2]._begin_reconnect()
	pump.run(40, fn)
	return [h, pump, fn]

## The host accepts the HELLO; the wire carries RESYNC and PRESENT to everyone,
## the returnee included (its transport arms the boundary). Returns R.
func _accept(h: MultiplayerHarness, peer: int = 42) -> int:
	var host: Node2D = h.runs[0]
	var had_check: bool = host._session.end_check_tick >= 0
	var slot: int = host.accept_reconnect(_hello(2), peer)
	if slot < 0:
		return -1
	var r := int(host._session.reconnect["tick"])
	var clears: bool = had_check and host._session.end_check_tick < 0
	for k in range(1, h.runs.size()):
		var c: Node2D = h.runs[k]
		if clears:
			c._session.cancel_no_live_check()
		c.announce_resync(r)
		c._pending_present[2] = r
	# The primed window is the last of the withheld range: the returnee's own
	# sampling begins after it.
	h.withheld[2] = [int(h.withheld[2][0]), r + DELAY]
	return r

func a_live_return_restores_beside_the_party_and_resumes() -> void:
	var parts := await _parked_party(false)
	var h: MultiplayerHarness = parts[0]
	var pump: RosterPump = parts[1]
	var fn: Callable = parts[2]
	var host: Node2D = h.runs[0]
	var client: Node2D = h.runs[1]
	var back: Node2D = h.runs[2]
	var ends := []
	for r in h.runs:
		r.run_ended.connect(func(w, _s): ends.append(w))
	var parked_health: float = host._parked_health[2]
	_check_true("slot two parked with health", parked_health > 0.0)
	# The returnee has a transport that buffers what arrives ahead of the
	# snapshot; no ENet behind it.
	var t := Transport.new()
	back.add_child(t)
	back.attach_transport(t)
	t.session = back._session
	var r := _accept(h)
	_check_true("the host accepted the return at a future boundary",
		r >= host.lockstep.executed + DELAY + Protocol.BOUNDARY_MARGIN)
	_check("only the returnee is a snapshot target", host._session.resync_targets, PackedInt32Array([2]))
	_check("no latch: somebody is LIVE", host._session.latched(), false)
	_check("the returnee armed its boundary", t.boundary, r)
	# The host's relayed record for a tick past R arrives before the snapshot.
	t._accept_record(0, r + 2, (_moves(r + 2, 3)[0] as Vector2).normalized(), -1, -1, -1)
	_check("it is retained past the boundary", t.held_count(), 1)
	_check("PRESENT arrived ahead of the snapshot and waits", back._pending_present.has(2), true)
	var stale_exec: int = back.lockstep.executed
	pump.run(DELAY + 6, fn)
	_check("the host serialised at R", host.last_snapshot_tick, r)
	_check("the snapshot went to the returnee alone", pump.deliveries, [[2, r]])
	_check("the returnee's world held until then", back.lockstep.executed >= r + 1 and stale_exec < r, true)
	_check("the returnee is back in the session", back._session.reconnecting, false)
	_check("and resumed at R + 1 or later", back.lockstep.executed >= r + 1, true)
	_check("the held record survived the restore", back.lockstep.has_record(0, r + 2), true)
	_check("the buffered PRESENT was consumed only after the restore", back._pending_present.has(2), false)
	_check("slot two is LIVE on every peer", [host.slot_state[2], client.slot_state[2], back.slot_state[2]],
		[host.SlotState.LIVE, host.SlotState.LIVE, host.SlotState.LIVE])
	_check("with the health it parked with", back.player_health[2], parked_health)
	_check("the host primed its records through R + delay",
		[host.lockstep.has_record(2, r + 1), host.lockstep.has_record(2, r + DELAY)], [true, true])
	_check_true("its own sampling began at R + delay + 1",
		back.lockstep.has_record(2, r + DELAY + 1) or back.lockstep.executed + DELAY < r + DELAY + 1)
	_check("nothing ended", ends.size(), 0)
	pump.run(20, fn)
	_check("the party agrees after the return", h.all_agree(), true)
	if not h.all_agree():
		print("    diff host/client ", h.first_difference(host, client), "  host/back ", h.first_difference(host, back))
	_check("it was placed on open ground", host.terrain.is_solid(host.player_pos[2]), false)
	t.close()
	h.teardown()
	await process_frame
	finished["a_live_return_restores_beside_the_party_and_resumes"] = true

func a_dead_return_stays_a_spectator_and_reports() -> void:
	var parts := await _parked_party(true)
	var h: MultiplayerHarness = parts[0]
	var pump: RosterPump = parts[1]
	var fn: Callable = parts[2]
	var host: Node2D = h.runs[0]
	var back: Node2D = h.runs[2]
	var ends := []
	for r in h.runs:
		r.run_ended.connect(func(w, _s): ends.append(w))
	_check("slot two parked dead", host._parked_health[2], 0.0)
	# Everyone else dies: a no-LIVE barrier opens over the two present peers.
	for k in 2:
		h.runs[k]._die(0)
		h.runs[k]._die(1)
		h.runs[k].hitstop_ticks = 0
	pump.run(3, fn)
	var c0: int = host._session.end_check_tick
	_check_true("a no-LIVE check opened", c0 >= 0)
	var r := _accept(h)
	_check_true("the dead return was accepted", r > 0)
	_check("a dead return sets no latch", host._session.latched(), false)
	_check("and leaves the no-LIVE check standing", host._session.end_check_tick, c0)
	pump.run(DELAY + 8, fn)
	_check("the returnee is back, DEAD", [back._session.reconnecting, back.slot_state[2]],
		[false, back.SlotState.DEAD])
	_check("a DEAD slot is never required", host.lockstep.missing(host.lockstep.executed).has(2), false)
	_check("but it is in the PRESENT roster", host._present_remote_count(), 2)
	pump.run(DELAY + 12, fn)
	_check_true("a check the returnee could report for was issued",
		host._session.ended or host._session.end_reports.has(2))
	pump.run(DELAY + 8, fn)
	_check("the host confirmed the loss through all three", host._session.ended, true)
	_check("every present peer ended once", ends, [false, false, false])
	h.teardown()
	await process_frame
	finished["a_dead_return_stays_a_spectator_and_reports"] = true

func a_latched_live_return_suppresses_no_live_endings() -> void:
	var parts := await _parked_party(false)
	var h: MultiplayerHarness = parts[0]
	var pump: RosterPump = parts[1]
	var fn: Callable = parts[2]
	var host: Node2D = h.runs[0]
	var ends := []
	for r in h.runs:
		r.run_ended.connect(func(w, _s): ends.append(w))
	# Everyone LIVE dies, and in the same breath slot two asks to come back.
	for k in 2:
		h.runs[k]._die(0)
		h.runs[k]._die(1)
		h.runs[k].hitstop_ticks = 0
	_check("the host has a loss candidate", host._session.end_candidate_pending, true)
	var r := _accept(h)
	_check("a live return with nobody LIVE latches", host._session.pending_live_return, [2, r])
	pump.run(3, fn)
	_check("no no-LIVE check opens while latched", host._session.end_check_tick, -1)
	host.receive_end_candidate(1, host.tick, O.LOSS, 0)
	pump.run(2, fn)
	_check("a client's no-LIVE candidate is refused while latched", host._session.end_check_tick, -1)
	host.receive_end_candidate(1, host.tick, O.WIN, 0)
	_check("a campaign-win candidate is not", host._session.end_candidate_pending, true)
	host._session.end_candidate_pending = false
	pump.run(DELAY + 8, fn)
	_check("the slot returned LIVE", host.slot_state[2], host.SlotState.LIVE)
	_check("somebody is LIVE again", host.alive, true)
	_check("the latch cleared at PRESENT", host._session.latched(), false)
	_check("the loss verdict is void", host._session.end_outcome, O.NONE)
	_check("PRESENT's tick is remembered", host._session.last_present_tick, r)
	host._session.end_candidate_pending = false
	host.receive_end_candidate(1, r - 1, O.LOSS, 0)
	host.receive_end_candidate(1, r, O.LOSS, 0)
	_check("no-LIVE candidates at R - 1 and R are stale", host._session.end_candidate_pending, false)
	host.receive_end_candidate(1, r + 1, O.LOSS, 0)
	_check("one at R + 1 is not", host._session.end_candidate_pending, true)
	host._session.end_candidate_pending = false
	pump.run(10, fn)
	_check("no END during a successful LIVE return", ends.size(), 0)
	_check("the party agrees", h.all_agree(), true)
	h.teardown()
	await process_frame
	finished["a_latched_live_return_suppresses_no_live_endings"] = true

func an_existing_no_live_barrier_is_cleared_by_the_flagged_resync() -> void:
	var parts := await _parked_party(false)
	var h: MultiplayerHarness = parts[0]
	var pump: RosterPump = parts[1]
	var fn: Callable = parts[2]
	var host: Node2D = h.runs[0]
	var client: Node2D = h.runs[1]
	var ends := []
	for r in h.runs:
		r.run_ended.connect(func(w, _s): ends.append(w))
	for k in 2:
		h.runs[k]._die(0)
		h.runs[k]._die(1)
		h.runs[k].hitstop_ticks = 0
	pump.run(3, fn)
	_check_true("a no-LIVE check is open on host and client",
		host._session.end_check_tick >= 0 and client._session.end_check_tick == host._session.end_check_tick)
	var r := _accept(h)
	_check_true("the return was accepted", r > 0)
	_check("the flagged RESYNC cleared the host's check", host._session.end_check_tick, -1)
	_check("and the client's", client._session.end_check_tick, -1)
	_check("no candidate is pending", host._session.end_candidate_pending, false)
	pump.run(DELAY + 10, fn)
	_check("the run went on with the returnee LIVE", [host.alive, host.slot_state[2]], [true, host.SlotState.LIVE])
	_check("no END", ends.size(), 0)
	h.teardown()
	await process_frame
	finished["an_existing_no_live_barrier_is_cleared_by_the_flagged_resync"] = true

func an_aborted_return_judges_no_live_again() -> void:
	var parts := await _parked_party(false)
	var h: MultiplayerHarness = parts[0]
	var pump: RosterPump = parts[1]
	var fn: Callable = parts[2]
	var host: Node2D = h.runs[0]
	for k in 2:
		h.runs[k]._die(0)
		h.runs[k]._die(1)
		h.runs[k].hitstop_ticks = 0
	var r := _accept(h)
	_check("latched", host._session.latched(), true)
	# The returnee vanishes before its boundary. Its records never come: the
	# withheld range is unbounded again.
	h.withheld[2] = [int(h.withheld[2][0]), 1 << 30]
	host.abort_reconnect()
	_check("the latch cleared", host._session.latched(), false)
	_check("and no-LIVE was judged again at once", host._session.end_candidate_pending, true)
	pump.run(DELAY + 4, fn)
	_check("the announced return still applied at R + 1, unmanned", host.slot_state[2] == host.SlotState.LIVE or host.slot_state[2] == host.SlotState.ABSENT, true)
	pump.run(DELAY + 12, fn)
	_check("the unmanned slot parked again at its first missing tick", int(host._session.absent_ticks.get(2, -1)), r + DELAY + 1)
	_check("and the run holds a loss candidate", host._session.end_outcome, O.LOSS)
	h.teardown()
	await process_frame
	finished["an_aborted_return_judges_no_live_again"] = true

## Relayed, the host closing the room reaches a client as the relay's
## "closed" op. There is nothing to rejoin and no host migration, so the run
## ends there — not after ten refused rejoins and half a minute of
## "reconnecting…".
func a_closed_room_ends_the_run_instead_of_reconnecting() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, DELAY, 20260902)
	var client: Node2D = h.runs[1]
	var t := Transport.new()
	root.add_child(t)
	t.relayed = true
	t.relay_error = "closed"
	client.attach_transport(t)
	var endings := []
	client.run_ended.connect(func(won, salvage): endings.append([won, salvage]))
	client._on_peer_left(Transport.HOST_PEER)
	_check("the run ended", client._session.ended, true)
	_check("as a loss with nothing banked", endings, [[false, 0]])
	_check("without entering reconnect", client._session.reconnecting, false)
	_check("and without a rejoin attempt", client._reconnect_attempts, 0)
	t.queue_free()
	h.teardown()
	await process_frame
	finished["a_closed_room_ends_the_run_instead_of_reconnecting"] = true

## Two slots return at the SAME boundary tick, with their PRESENT events
## enqueued in DELIBERATELY opposite dictionary insertion order on different
## peers — exactly what real network arrival order would produce. _roster_step
## now walks slots numerically rather than in dictionary order, so every peer
## must still resolve both returns identically: the same LIVE/DEAD outcome, the
## same position for each slot, and the two returnees never colliding with
## each other or with the surviving party.
func same_tick_multiple_present_events_land_identically_regardless_of_order() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 4, DELAY, 20260906)
	var pump := RosterPump.new(h)
	var fn := func(_t: int) -> Array:
		return [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
	pump.run(10, fn)
	for r in h.runs:
		r._park(2)
		r._park(3)
	pump.run(2, fn)
	var host: Node2D = h.runs[0]
	var client: Node2D = h.runs[1]
	_check("both parked slots kept positive health",
		[host._parked_health[2] > 0.0, host._parked_health[3] > 0.0], [true, true])
	var r_tick: int = host.lockstep.executed + DELAY + 5
	# The continuing peers consume opposite arrival orders.
	host._pending_present[3] = r_tick
	host._pending_present[2] = r_tick
	client._pending_present[2] = r_tick
	client._pending_present[3] = r_tick
	# Returnees resume from the boundary snapshot and its primed input window,
	# not by continuing to simulate their stale state through the absence.
	host._session.announce_resync(r_tick, PackedInt32Array([2, 3]))
	for peer in range(2, h.runs.size()):
		h.runs[peer]._session.reconnecting = true
		h.runs[peer].announce_resync(r_tick)
	pump.run(r_tick - host.lockstep.executed + 6, fn)
	_check("slot two returned LIVE", host.slot_state[2], host.SlotState.LIVE)
	_check("slot three returned LIVE", host.slot_state[3], host.SlotState.LIVE)
	_check("every peer agrees on slot two's state",
		[client.slot_state[2], h.runs[2].slot_state[2], h.runs[3].slot_state[2]],
		[host.slot_state[2], host.slot_state[2], host.slot_state[2]])
	_check("every peer agrees on slot three's state",
		[client.slot_state[3], h.runs[2].slot_state[3], h.runs[3].slot_state[3]],
		[host.slot_state[3], host.slot_state[3], host.slot_state[3]])
	_check("slot two lands on the identical position on every peer",
		[client.player_pos[2], h.runs[2].player_pos[2], h.runs[3].player_pos[2]],
		[host.player_pos[2], host.player_pos[2], host.player_pos[2]])
	_check("slot three lands on the identical position on every peer",
		[client.player_pos[3], h.runs[2].player_pos[3], h.runs[3].player_pos[3]],
		[host.player_pos[3], host.player_pos[3], host.player_pos[3]])
	_check("the two returnees did not land on each other",
		host.player_pos[2].distance_to(host.player_pos[3]) >= Terrain.SPAWN_SEPARATION, true)
	_check("neither returnee landed on the surviving party",
		[host.player_pos[2].distance_to(host.player_pos[0]) >= Terrain.SPAWN_SEPARATION,
			host.player_pos[3].distance_to(host.player_pos[1]) >= Terrain.SPAWN_SEPARATION],
		[true, true])
	_check("the party agrees after both returns", h.all_agree(), true)
	h.teardown()
	await process_frame
	finished["same_tick_multiple_present_events_land_identically_regardless_of_order"] = true

## A positive-health return with NOBODY live still tries its own reserved
## point first — and when that point itself is unsafe, it stays DEAD rather
## than reviving into rock. The existing no-LIVE ending policy still runs to
## confirmation.
func a_no_live_unsafe_reserved_pad_stays_dead_and_the_ending_policy_still_applies() -> void:
	var parts := await _parked_party(false)
	var h: MultiplayerHarness = parts[0]
	var pump: RosterPump = parts[1]
	var fn: Callable = parts[2]
	var host: Node2D = h.runs[0]
	var client: Node2D = h.runs[1]
	var back: Node2D = h.runs[2]
	var ends := []
	for r in h.runs:
		r.run_ended.connect(func(w, _s): ends.append(w))
	_check("slot two parked with positive health", host._parked_health[2] > 0.0, true)
	var reserved: Vector2 = host.terrain.spawner_pos(host.terrain.current, 2)
	for r in h.runs:
		r.terrain.solid[r.terrain.cell_index(reserved)] = 1
	for peer in 2:
		h.runs[peer]._die(0)
		h.runs[peer]._die(1)
		h.runs[peer].hitstop_ticks = 0
	var return_tick := _accept(h)
	_check_true("the live return was accepted", return_tick > 0)
	pump.run(DELAY + 10, fn)
	_check("the unsafe return never revived on any peer",
		[host.slot_state[2], client.slot_state[2], back.slot_state[2]],
		[host.SlotState.DEAD, host.SlotState.DEAD, host.SlotState.DEAD])
	_check("the returnee received its boundary snapshot", back._session.reconnecting, false)
	_check("health was not restored", host.player_health[2], 0.0)
	_check("a DEAD slot is never required",
		host.lockstep.missing(host.lockstep.executed).has(2), false)
	pump.run(DELAY + 12, fn)
	_check_true("a check the returnee could report for was issued",
		host._session.ended or host._session.end_reports.has(2))
	pump.run(DELAY + 8, fn)
	_check("the no-LIVE ending policy still confirms the loss", host._session.ended, true)
	_check("the loss was confirmed, not terminated as a desync", host._session.terminated, false)
	_check("every present peer ended once", ends, [false, false, false])
	h.teardown()
	await process_frame
	finished["a_no_live_unsafe_reserved_pad_stays_dead_and_the_ending_policy_still_applies"] = true

## Even with a LIVE party to return beside, a return that finds no safe ground
## anywhere in its bounded search stays DEAD rather than reviving into voided
## ground — the search failing is not license to place it in the void anyway.
func a_live_anchor_return_with_no_safe_ground_dies_instead_of_reviving_into_the_void() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, DELAY, 20260905)
	var pump := RosterPump.new(h)
	# Frozen movement: the live anchor must stay exactly where the void
	# clearance disc below was measured from.
	var still := func(_t: int) -> Array: return [Vector2.ZERO, Vector2.ZERO]
	pump.run(5, still)
	var host: Node2D = h.runs[0]
	var client: Node2D = h.runs[1]
	for r in h.runs:
		r._park(1)
	_check("slot one parked with positive health", host._parked_health[1] > 0.0, true)
	_check("slot zero is still LIVE — a real anchor exists",
		host.slot_state[0], host.SlotState.LIVE)
	# Void the whole map except a small disc around the anchor — smaller than
	# SPAWN_SEPARATION, so no candidate the search could ever accept (which
	# must sit at least that far from a LIVE slot) is left un-voided.
	for r in h.runs:
		r.terrain.build_distance_field()
		r.terrain.voided.fill(1)
		var anchor: Vector2 = r.player_pos[0]
		for i in r.terrain.voided.size():
			var cx: int = i % r.terrain.w
			var cy: int = i / r.terrain.w
			var wp: Vector2 = r.terrain.origin \
				+ (Vector2(cx, cy) + Vector2(0.5, 0.5)) * Terrain.CELL
			if wp.distance_to(anchor) <= 60.0:
				r.terrain.voided[i] = 0
	var r_tick: int = host.lockstep.executed + DELAY + 3
	for r in h.runs:
		r._pending_present[1] = r_tick
	pump.run(r_tick - host.lockstep.executed + 6, still)
	_check("the exhausted search left it DEAD on the host",
		host.slot_state[1], host.SlotState.DEAD)
	_check("DEAD on the client too", client.slot_state[1], client.SlotState.DEAD)
	_check("health was not restored", host.player_health[1], 0.0)
	_check("the live party is unaffected", host.slot_state[0], host.SlotState.LIVE)
	_check("the run goes on: somebody is still LIVE", host.alive, true)
	h.teardown()
	await process_frame
	finished["a_live_anchor_return_with_no_safe_ground_dies_instead_of_reviving_into_the_void"] = true
