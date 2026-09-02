extends SceneTree

## The lockstep claim itself: N peers on one descriptor, fed the same records
## in different arrival orders, hash identically on every one of 3600 ticks —
## through spawning, fighting, level-up rounds and a local pause. Any
## divergence is a source bug, never a tolerance problem; the first tick and
## the first differing manifest field are printed so it can be found.

var failures := 0
var finished := {}

const TICKS := 3600
const CASES := ["two_peers_agree_for_a_minute", "four_peers_agree_for_a_minute",
	"a_local_pause_does_not_diverge"]

func _initialize() -> void:
	print("ROOTKIT — multiplayer simulation\n")
	SaveGame.use_fresh_state()
	await two_peers_agree_for_a_minute()
	await four_peers_agree_for_a_minute()
	await a_local_pause_does_not_diverge()
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

## A little motion per slot so the party actually plays: each walks a slow
## circle offset from the others.
func _moves(t: int, players: int) -> Array:
	var out := []
	for s in players:
		var a := float(t) * 0.01 + float(s) * 1.7
		out.append(Vector2(cos(a), sin(a)) * 0.9)
	return out

## Run the pump for TICKS ticks, asserting agreement every tick. Returns the
## first divergent tick or -1. Movement is a function of the TICK, so every
## peer's record for a tick is the same whichever step first reaches it.
func _agree_for(h: MultiplayerHarness, ticks: int) -> int:
	var players := h.players
	var moves_fn := func(t: int) -> Array: return _moves(t, players)
	for t in ticks:
		h.step(moves_fn)
		if not h.all_agree():
			var field := h.first_difference(h.runs[0], h.runs[1])
			print("  diverged at tick %d, first differing field: %s" % [t, field])
			return t
	return -1

func two_peers_agree_for_a_minute() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, 2, 20260830)
	var d := _agree_for(h, TICKS)
	_check("two peers agree on every tick (first divergent tick, -1 = none)", d, -1)
	_check("no event queue dropped anything", h.total_drops(), 0)
	print("  final: tick %d, enemies %d, level %d" % [h.runs[0].tick,
		h.runs[0].enemies.count, h.runs[0].level])
	h.teardown()
	await process_frame
	finished["two_peers_agree_for_a_minute"] = true

func four_peers_agree_for_a_minute() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 4, 3, 20260830)
	var d := _agree_for(h, TICKS)
	_check("four peers agree on every tick (first divergent tick, -1 = none)", d, -1)
	_check("no event queue dropped anything", h.total_drops(), 0)
	print("  final: tick %d, enemies %d, level %d" % [h.runs[0].tick,
		h.runs[0].enemies.count, h.runs[0].level])
	h.teardown()
	await process_frame
	finished["four_peers_agree_for_a_minute"] = true

## One peer opens its local pause overlay mid-run: in a session that is
## presentation only — its record goes neutral, everyone else applies that same
## neutral record, and the simulations never disagree.
func a_local_pause_does_not_diverge() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, 2, 20260830)
	var d := _agree_for(h, 300)
	h.runs[1].user_paused = true
	var d2 := _agree_for(h, 300)
	h.runs[1].user_paused = false
	var d3 := _agree_for(h, 300)
	_check("agreement before the pause", d, -1)
	_check("agreement during the pause", d2, -1)
	_check("agreement after the pause", d3, -1)
	_check("the paused peer's world kept ticking", h.runs[1].tick > 600, true)
	h.teardown()
	await process_frame
	finished["a_local_pause_does_not_diverge"] = true
