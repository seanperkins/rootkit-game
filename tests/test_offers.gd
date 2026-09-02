extends SceneTree

## Card and fusion offers as deterministic, per-slot INPUT state. A choice is a
## record in the lockstep ring naming an offer sequence; a stale or malformed
## record is no choice; deadlines resolve to the first option; a level-up is a
## ROUND every LIVE slot answers before the world resumes; and the movement in
## the same record is sanitised at application, never in the ring.

var failures := 0
var finished := {}
const DT := 1.0 / 60.0

const CASES := ["a_stale_sequence_is_no_choice", "the_deadline_takes_the_first_card",
	"two_rounds_open_from_one_tick", "a_payout_queues_behind_the_round",
	"slot_exit_resolves_to_the_first_card", "fusion_rides_the_same_record",
	"the_world_waits_for_every_live_slot", "movement_is_sanitised_on_application"]

func _initialize() -> void:
	print("ROOTKIT — offers as input\n")
	SaveGame.use_fresh_state()
	await a_stale_sequence_is_no_choice()
	await the_deadline_takes_the_first_card()
	await two_rounds_open_from_one_tick()
	await a_payout_queues_behind_the_round()
	await slot_exit_resolves_to_the_first_card()
	await fusion_rides_the_same_record()
	await the_world_waits_for_every_live_slot()
	await movement_is_sanitised_on_application()
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

## A run whose session names `players` slots, with a choice timeout of
## `timeout` ticks (zero for none), this process at slot zero.
func _run(players: int, timeout: int = 0) -> Node2D:
	var rows := []
	for s in players:
		rows.append({"slot": s, "name": "p%d" % s,
			"counters": SaveGame.session_counters()})
	var desc := NetworkSession.validate_descriptor({
		"protocol": SessionRules.PROTOCOL, "session_id": 1, "seed": 20260830,
		"delay": 0, "choice_timeout": timeout, "roster": rows})
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	r.configure_session(NetworkSession.create(desc, 0, NetworkSession.Role.HOST))
	root.add_child(r)
	await process_frame
	r.input_override = Vector2.ZERO
	# This suite injects the LOCAL slot's records directly, so the engine must
	# not tick the run on its own: an automatic poll submits a neutral record
	# for the current tick first, and the ring — correctly — refuses the
	# duplicate. Godot re-enables _physics_process at ready, so the flag is
	# cleared AFTER the first frame, and the neutral record that frame already
	# submitted is consumed by one explicit tick so every later record is fresh.
	r.set_physics_process(false)
	_tick(r)
	return r

func _done(r: Node2D, name: String) -> void:
	r.free()
	await process_frame
	finished[name] = true

func _seq(r: Node2D, s: int) -> int:
	var open: Dictionary = r._offer_open[s]
	return int(open["seq"]) if not open.is_empty() else -1

func _is_open(r: Node2D, s: int) -> bool:
	return not (r._offer_open[s] as Dictionary).is_empty()

## Submit one slot's record for the tick about to execute.
func _record(r: Node2D, s: int, move: Vector2, card: int, target: int,
		offer: int) -> void:
	r.lockstep.submit(s, r.lockstep.executed, move, card, target, offer)

## Every LIVE slot but the local one sends a neutral record, then the tick runs.
## The local slot's record comes from the run's own poll.
func _tick(r: Node2D) -> void:
	for s in range(1, SessionRules.MAX_PLAYERS):
		if r.slot_state[s] == r.SlotState.LIVE:
			r.lockstep.submit(s, r.lockstep.executed, Vector2.ZERO, -1, -1, -1)
	r._physics_process(DT)

## A record naming any sequence but the open one is consumed and changes
## nothing; the right sequence resolves the offer.
func a_stale_sequence_is_no_choice() -> void:
	var r: Node2D = await _run(1)
	r._offer_cards(0)
	var seq := _seq(r, 0)
	_check_true("an offer is open", seq >= 1)
	_check("and the world is held", r.paused, true)
	var salvage_before: int = r.salvage
	_record(r, 0, Vector2.ZERO, -2, -1, seq - 1)     # a decline, one round stale
	_tick(r)
	_check("a stale decline left the offer open", _is_open(r, 0), true)
	_check("and paid nothing", r.salvage, salvage_before)
	_record(r, 0, Vector2.ZERO, -2, -1, seq)
	_tick(r)
	_check("the current sequence resolves it", _is_open(r, 0), false)
	_check("the decline paid out", r.salvage, salvage_before + 25)
	_check("and the world resumed", r.paused, false)
	await _done(r, "a_stale_sequence_is_no_choice")

## Unresolved at its deadline, an offer takes its first card — and a pick that
## was still in flight against the old sequence lands nowhere.
func the_deadline_takes_the_first_card() -> void:
	var r: Node2D = await _run(1, 3)
	r._offer_cards(0)
	var seq := _seq(r, 0)
	var first: Module = r._decode_card((r._offer_open[0]["contents"] as PackedInt32Array)[0])
	var salvage_before: int = r.salvage
	_tick(r)
	_tick(r)
	_check("before the deadline the offer stands", _is_open(r, 0), true)
	_tick(r)
	_check("at the deadline it resolved", _is_open(r, 0), false)
	if first != null:
		_check("to its first card", r.loadouts[0].holds(first.id) >= 0, true)
	else:
		_check("to the salvage card", r.salvage, salvage_before + 50)
	# A pick against the now-closed sequence is dropped, not applied late.
	_record(r, 0, Vector2.ZERO, -2, -1, seq)
	var after: int = r.salvage
	_tick(r)
	_check("a late pick against the closed offer pays nothing", r.salvage, after)
	await _done(r, "the_deadline_takes_the_first_card")

## Two thresholds crossed on one tick owe two rounds: the second opens the tick
## the first is fully resolved, with fresh sequence numbers.
func two_rounds_open_from_one_tick() -> void:
	var r: Node2D = await _run(2)
	r.pending_levels = 2
	r._settle_offers()
	_check("two rounds are owed while the first is open", r.pending_levels, 2)
	_check_true("both slots hold a LEVEL offer",
		_is_open(r, 0) and _is_open(r, 1)
		and int(r._offer_open[0]["kind"]) == r.OfferKind.LEVEL)
	var s0 := _seq(r, 0)
	var s1 := _seq(r, 1)
	_record(r, 0, Vector2.ZERO, -2, -1, s0)
	_record(r, 1, Vector2.ZERO, -2, -1, s1)
	r._physics_process(DT)
	_check("the first round closed and the second opened on that tick",
		r.pending_levels, 1)
	_check_true("both slots were re-offered with new sequences",
		_seq(r, 0) == s0 + 1 and _seq(r, 1) == s1 + 1)
	_check("the world is still held", r.paused, true)
	_record(r, 0, Vector2.ZERO, -2, -1, _seq(r, 0))
	_record(r, 1, Vector2.ZERO, -2, -1, _seq(r, 1))
	r._physics_process(DT)
	_check("resolving the second round clears the debt", r.pending_levels, 0)
	_check("and resumes the world", r.paused, false)
	await _done(r, "two_rounds_open_from_one_tick")

## A block payout landing during a round queues behind the slot's open level
## offer and opens when it resolves.
func a_payout_queues_behind_the_round() -> void:
	var r: Node2D = await _run(2)
	r.pending_levels = 1
	r._settle_offers()
	var level_seq := _seq(r, 0)
	r._offer_cards(0, r.CardMode.RANK_ONLY)
	_check("the level offer is still the open one", _seq(r, 0), level_seq)
	_check("the payout queued behind it", (r._offer_queue[0] as Array).size(), 1)
	_record(r, 0, Vector2.ZERO, -2, -1, level_seq)
	_tick(r)
	_check("resolving the level offer opened the queued payout",
		int(r._offer_open[0]["kind"]), r.OfferKind.RANK_ONLY)
	_check("with the next sequence", _seq(r, 0), level_seq + 1)
	await _done(r, "a_payout_queues_behind_the_round")

## A slot that dies or parks with offers pending resolves them all to their
## first option at once, so it can never hold the round open.
func slot_exit_resolves_to_the_first_card() -> void:
	var r: Node2D = await _run(2)
	r.pending_levels = 1
	r._settle_offers()
	r._offer_cards(1, r.CardMode.RANK_ONLY)         # queued behind the level offer
	var salvage_before: int = r.salvage
	var mods_before: int = r.loadouts[1].exploits.size()
	r._die(1)
	_check("a dead slot holds no open offer", _is_open(r, 1), false)
	_check("and no queue", (r._offer_queue[1] as Array).size(), 0)
	_check_true("its offers were taken, not discarded",
		r.salvage > salvage_before or r.loadouts[1].exploits.size() >= mods_before)
	_check("the round still waits on the live slot", r.paused, true)

	r._offer_cards(0, r.CardMode.RANK_ONLY)
	r.slot_state[0] = r.SlotState.ABSENT
	r._resolve_offer_on_slot_exit(0)
	_check("an absent slot's offers resolve the same way", _is_open(r, 0), false)
	_check("with nothing left queued", (r._offer_queue[0] as Array).size(), 0)
	await _done(r, "slot_exit_resolves_to_the_first_card")

## A fusion offer is answered by the same record: `card` names the match.
func fusion_rides_the_same_record() -> void:
	var r: Node2D = await _run(1)
	var mods := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(mods[&"snipe"]); ex.place(mods[&"on_kill"]); ex.place(mods[&"bitmask"])
	for em in ex.equipped():
		em.rank = em.module.max_rank          # fusion needs all three maxed
	# A second row keeps an INTERVAL trigger in the build: fusing the only one
	# away is refused, exactly as the loadout rules say.
	var keep := Exploit.new()
	keep.place(mods[&"packet"]); keep.place(mods[&"interval"])
	r.loadouts[0].exploits = [ex, keep]
	r._recompile()
	r._block_payout(0)
	_check("the payout opened a fusion offer",
		int(r._offer_open[0]["kind"]), r.OfferKind.FUSION)
	_check("the local notice carries the match", r._pending_fusions.size(), 1)
	_record(r, 0, Vector2.ZERO, 0, -1, _seq(r, 0))
	_tick(r)
	_check("the record fused the row", r.loadouts[0].exploits[0].head_is_fused(), true)
	_check("and the offer closed", _is_open(r, 0), false)
	_check("and the world resumed", r.paused, false)
	await _done(r, "fusion_rides_the_same_record")

## The world resumes only when EVERY LIVE slot has answered; the local slot,
## done early, is told how many it is waiting for.
func the_world_waits_for_every_live_slot() -> void:
	var r: Node2D = await _run(2)
	var waits := []
	r.offer_waiting.connect(func(n): waits.append(n))
	r.pending_levels = 1
	r._settle_offers()
	_record(r, 0, Vector2.ZERO, -2, -1, _seq(r, 0))
	_tick(r)
	_check("one answer does not resume the world", r.paused, true)
	_check("the local slot is waiting on one teammate", r._unresolved_count(), 1)
	_check("and was told so", waits.back() if not waits.is_empty() else -1, 1)
	_record(r, 1, Vector2.ZERO, -2, -1, _seq(r, 1))
	_tick(r)
	_check("the last answer resumes it", r.paused, false)
	await _done(r, "the_world_waits_for_every_live_slot")

## Movement is preserved exactly up to MOVE_COMPONENT_MAX and becomes zero one
## thousandth past it or with a non-finite component — at APPLICATION, from an
## unaltered record.
func movement_is_sanitised_on_application() -> void:
	var r: Node2D = await _run(1)
	var cap := SessionRules.MOVE_COMPONENT_MAX
	_check("a component at the cap is preserved",
		r._sanitise_move(Vector2(cap, -cap)), Vector2(cap, -cap))
	_check("a component past the cap zeroes the move",
		r._sanitise_move(Vector2(cap + 0.001, 0.0)), Vector2.ZERO)
	_check("a non-finite component zeroes the move",
		r._sanitise_move(Vector2(NAN, 0.0)), Vector2.ZERO)
	_check("a huge finite component zeroes the move",
		r._sanitise_move(Vector2(1e30, 0.0)), Vector2.ZERO)
	# Through the ring: the stored record is untouched, the applied input is not.
	r.input_override = null
	_record(r, 0, Vector2(cap + 0.001, 0.0), -1, -1, -1)
	r._physics_process(DT)
	_check("an oversized record applies as zero movement", r.inputs[0], Vector2.ZERO)
	await _done(r, "movement_is_sanitised_on_application")
