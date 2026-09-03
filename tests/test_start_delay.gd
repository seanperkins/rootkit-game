extends SceneTree

## The roster-aware starting delay: a lobby freezes the mode constant scaled
## to its live roster — one player pays nothing, the constant is only the FULL
## table's value — through the pure helper, through host_lobby/lobby_descriptor/
## start, and onto the client's applied descriptor.

var failures := 0
var finished := {}

const CASES := ["the_formula_table", "a_relay_lobby_scales_to_its_roster",
	"the_preview_matches_the_freeze_on_the_client", "solo_and_the_caps_hold"]

func _initialize() -> void:
	print("ROOTKIT — start delay\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	the_formula_table()
	a_relay_lobby_scales_to_its_roster()
	the_preview_matches_the_freeze_on_the_client()
	solo_and_the_caps_hold()
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

func _hello(name: String) -> Dictionary:
	return {"protocol": SessionRules.PROTOCOL, "name": name, "session_id": 0,
		"slot": -1, "counters": SaveGame.session_counters()}

func _host(delay: int) -> NetworkSession:
	return NetworkSession.host_lobby({"slot": 0, "name": "host",
		"counters": SaveGame.session_counters()}, 4242, 20260830, delay)

## The ramp itself: round(base * (n - 1) / (MAX_PLAYERS - 1)), zero at one
## player, the untouched constant at four. Every base rises monotonically.
func the_formula_table() -> void:
	var full := SessionRules.MAX_PLAYERS
	for base in [SessionRules.RELAY_DELAY, SessionRules.DEFAULT_DELAY,
			SessionRules.LAN_DELAY]:
		var row := []
		for n in full:
			row.append(NetworkSession._starting_delay(base, n + 1))
		_check("base %d ramps %d players as the roster grows" % [base, full],
			row[0], 0)
		_check("base %d keeps its constant at the full table" % base,
			row[full - 1], base)
		_check("base %d never dips as the roster grows" % base,
			row == row.duplicate(), true)
		for n in range(1, full):
			_check("base %d: %d players pay at least what %d do" % [base, n + 1, n],
				row[n] >= row[n - 1], true)
	_check("the relay ramp", [1, 2, 3, 4].map(
		func(n): return NetworkSession._starting_delay(SessionRules.RELAY_DELAY, n)),
		[0, 2, 3, 5])
	_check("the default ramp", [1, 2, 3, 4].map(
		func(n): return NetworkSession._starting_delay(SessionRules.DEFAULT_DELAY, n)),
		[0, 1, 3, 4])
	_check("the LAN ramp", [1, 2, 3, 4].map(
		func(n): return NetworkSession._starting_delay(SessionRules.LAN_DELAY, n)),
		[0, 1, 2, 3])
	_check("the host_lobby ceiling ramps too", [1, 2, 3, 4].map(
		func(n): return NetworkSession._starting_delay(SessionRules.DEFAULT_DELAY + 4, n)),
		[0, 3, 5, 8])
	_check("a roster past the table clamps to the full value",
		NetworkSession._starting_delay(SessionRules.RELAY_DELAY, 9),
		SessionRules.RELAY_DELAY)
	finished["the_formula_table"] = true

## A relayed lobby freezes what its live roster needs, joiner by joiner, and
## START pins the full-roster constant only when the table is full.
func a_relay_lobby_scales_to_its_roster() -> void:
	var s := _host(SessionRules.RELAY_DELAY)
	_check("a relayed host alone pays nothing",
		int(s.lobby_descriptor()["delay"]), 0)
	s.admit(_hello("a"), 5)
	_check("two relayed players pay two ticks",
		int(s.lobby_descriptor()["delay"]), 2)
	s.admit(_hello("b"), 6)
	_check("three pay three", int(s.lobby_descriptor()["delay"]), 3)
	s.admit(_hello("c"), 7)
	_check("the full table pays the relay constant",
		int(s.lobby_descriptor()["delay"]), SessionRules.RELAY_DELAY)
	var desc := s.start()
	_check("START freezes the full-roster value", int(desc["delay"]),
		SessionRules.RELAY_DELAY)
	_check("and the roster it froze", (desc["roster"] as Array).size(), 4)
	finished["a_relay_lobby_scales_to_its_roster"] = true

## The derivation sits in lobby_descriptor, so the WELCOME a client applies
## already names the delay START will freeze — never a value rewritten late.
func the_preview_matches_the_freeze_on_the_client() -> void:
	var host := _host(SessionRules.RELAY_DELAY)
	host.admit(_hello("a"), 5)
	var preview := host.lobby_descriptor()
	var c := NetworkSession.client_lobby()
	_check("WELCOME applies", c.apply_welcome({"descriptor": preview, "slot": 1}), true)
	_check("the preview's delay", int(c.descriptor["delay"]),
		NetworkSession._starting_delay(SessionRules.RELAY_DELAY, 2))
	var frozen := host.start()
	_check("the freeze names the preview's delay", int(frozen["delay"]),
		int(preview["delay"]))
	_check("START applies", c.apply_start({"descriptor": frozen, "slot": -1}), true)
	_check("the client's descriptor equals the host's byte for byte",
		c.descriptor == frozen, true)
	finished["the_preview_matches_the_freeze_on_the_client"] = true

## Solo keeps its zero through solo_descriptor, untouched by the lobby path;
## a one-row networked lobby pays nothing too, and the clamped ceiling still
## validates at the full table.
func solo_and_the_caps_hold() -> void:
	var solo := NetworkSession.validate_descriptor(NetworkSession.solo_descriptor(
		{"slot": 0, "name": "", "counters": SaveGame.session_counters()}, 20260830))
	_check("solo still runs at zero input delay", int(solo["delay"]), 0)
	var lone := _host(SessionRules.RELAY_DELAY).start()
	_check("a relayed host who starts alone freezes zero", int(lone["delay"]), 0)
	var lan := _host(SessionRules.LAN_DELAY)
	lan.admit(_hello("a"), 5)
	lan.admit(_hello("b"), 6)
	lan.admit(_hello("c"), 7)
	_check("the LAN preset keeps its constant at the full table",
		int(lan.start()["delay"]), SessionRules.LAN_DELAY)
	var maxed := _host(SessionRules.DEFAULT_DELAY + 4)
	maxed.admit(_hello("a"), 5)
	maxed.admit(_hello("b"), 6)
	maxed.admit(_hello("c"), 7)
	_check("the clamped ceiling survives validation at the full table",
		int(maxed.start()["delay"]), SessionRules.DEFAULT_DELAY + 4)
	finished["solo_and_the_caps_hold"] = true
