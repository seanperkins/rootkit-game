extends SceneTree

## The lobby's pure logic on NetworkSession, and the string preferences it
## reads: slot assignment, the frozen START descriptor, reconnect admission,
## the client's WELCOME/START application, solo's identical shape, and the
## hostile-safe name and address fields.

var failures := 0
var finished := {}

const CASES := ["host_owns_slot_zero_and_assigns_the_lowest_free",
	"start_freezes_the_roster", "a_client_applies_welcome_then_start",
	"solo_builds_the_same_shape", "string_prefs_are_hostile_safe"]

func _initialize() -> void:
	print("ROOTKIT — lobby\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	host_owns_slot_zero_and_assigns_the_lowest_free()
	start_freezes_the_roster()
	a_client_applies_welcome_then_start()
	solo_builds_the_same_shape()
	string_prefs_are_hostile_safe()
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

func _host() -> NetworkSession:
	return NetworkSession.host_lobby({"slot": 0, "name": "host",
		"counters": SaveGame.session_counters()}, 4242, 20260830)

func host_owns_slot_zero_and_assigns_the_lowest_free() -> void:
	var s := _host()
	_check("the host holds slot zero", int(s.lobby_rows[0]["slot"]), 0)
	_check("the first remote HELLO takes slot one", s.admit(_hello("a"), 5), 1)
	_check("the next takes slot two", s.admit(_hello("b"), 6), 2)
	s.remove_peer(5)
	_check("a pre-START leave frees its slot", s.profile_row(1).is_empty(), true)
	_check("and the next joiner takes that lowest free slot", s.admit(_hello("c"), 7), 1)
	var order := []
	for row in s.lobby_descriptor()["roster"]:
		order.append(int(row["slot"]))
	_check("the roster is slot-ordered", order, [0, 1, 2])
	s.admit(_hello("d"), 8)
	_check("a fifth joiner is refused: the lobby is full", s.admit(_hello("e"), 9), -1)
	finished["host_owns_slot_zero_and_assigns_the_lowest_free"] = true

func start_freezes_the_roster() -> void:
	var s := _host()
	s.admit(_hello("a"), 5)
	var desc := s.start()
	_check("START yields a validated descriptor", desc.is_empty(), false)
	_check("with the protocol", int(desc["protocol"]), SessionRules.PROTOCOL)
	_check("the session id", int(desc["session_id"]), 4242)
	_check("the seed", int(desc["seed"]), 20260830)
	_check("the default delay", int(desc["delay"]), SessionRules.DEFAULT_DELAY)
	_check("the choice timeout", int(desc["choice_timeout"]), SessionRules.CHOICE_TIMEOUT_TICKS)
	_check("and both roster rows", (desc["roster"] as Array).size(), 2)
	_check("the session is started", s.started, true)
	_check("a new participant after START is refused", s.admit(_hello("late"), 9), -1)
	_check("no slot is free after START", s.free_slot(), -1)
	var back := {"protocol": SessionRules.PROTOCOL, "name": "other name",
		"session_id": 4242, "slot": 1, "counters": {}}
	_check("a reconnect to an existing slot is admitted", s.admit(back, 10), 1)
	_check("and keeps the slot's original name", s.profile(1)["name"], "a")
	var wrong_session := back.duplicate(); wrong_session["session_id"] = 1
	_check("a reconnect naming another session is refused", s.admit(wrong_session, 11), -1)
	var wrong_slot := back.duplicate(); wrong_slot["slot"] = 3
	_check("a reconnect to a slot the roster lacks is refused", s.admit(wrong_slot, 12), -1)
	s.remove_peer(5)
	_check("a leave after START keeps the frozen roster", s.profile(1).is_empty(), false)
	finished["start_freezes_the_roster"] = true

func a_client_applies_welcome_then_start() -> void:
	var host := _host()
	host.admit(_hello("me"), 5)
	var c := NetworkSession.client_lobby()
	_check("a fresh client has no slot", c.local_slot, -1)
	_check("WELCOME applies", c.apply_welcome({"descriptor": host.lobby_descriptor(), "slot": 1}), true)
	_check("and assigns the slot", c.local_slot, 1)
	_check("a refresh keeps the slot", c.apply_welcome({"descriptor": host.lobby_descriptor(), "slot": -1}) and c.local_slot == 1, true)
	var desc := host.start()
	_check("START applies", c.apply_start({"descriptor": desc, "slot": -1}), true)
	_check("and the client is started", c.started, true)
	_check("its descriptor equals the host's byte for byte", c.descriptor == desc, true)
	var other := _host()
	other.lobby_session_id = 99
	other.admit(_hello("x"), 5)
	var c2 := NetworkSession.client_lobby()
	c2.apply_welcome({"descriptor": host.lobby_descriptor(), "slot": 1})
	_check("a START for another session is refused", c2.apply_start({"descriptor": other.start(), "slot": -1}), false)
	finished["a_client_applies_welcome_then_start"] = true

func solo_builds_the_same_shape() -> void:
	var host := _host()
	var started := host.start()
	var solo := NetworkSession.validate_descriptor(NetworkSession.solo_descriptor(
		{"slot": 0, "name": "", "counters": SaveGame.session_counters()}, 20260830))
	var hk := started.keys(); hk.sort()
	var sk := solo.keys(); sk.sort()
	_check("solo carries exactly the session's keys", sk, hk)
	_check("at delay zero", int(solo["delay"]), 0)
	_check("with no choice timeout", int(solo["choice_timeout"]), 0)
	_check("and one roster row", (solo["roster"] as Array).size(), 1)
	finished["solo_builds_the_same_shape"] = true

func string_prefs_are_hostile_safe() -> void:
	_check("a non-string name is the default", SaveGame.sanitise_string_pref("display_name", 12), "")
	_check("a non-string address is the default",
		SaveGame.sanitise_string_pref("last_address", null), "127.0.0.1")
	_check("control characters are dropped from a name",
		SaveGame.sanitise_string_pref("display_name", "ab\nc"), "abc")
	_check("a name is capped at NAME_MAX",
		SaveGame.sanitise_string_pref("display_name", "x".repeat(200)).length(), SessionRules.NAME_MAX)
	_check("an address keeps only hostname characters",
		SaveGame.sanitise_string_pref("last_address", "127.0.0.1; rm -rf /"), "127.0.0.1rm-rf")
	_check("an IPv6 address survives", SaveGame.sanitise_string_pref("last_address", "::1"), "::1")
	SaveGame.set_string_pref("display_name", "  neo\t")
	_check("write-side sanitation applies", SaveGame.string_pref("display_name"), "  neo")
	var loaded := SaveGame._sanitise({"prefs": {"display_name": 5, "last_address": "h.example:1"}})
	_check("a hostile save's name becomes the default", loaded["prefs"]["display_name"], "")
	_check("and its address is kept when legal", loaded["prefs"]["last_address"], "h.example:1")
	_check("numeric prefs are untouched by the string path",
		SaveGame._sanitise({"prefs": {"shake": 1.5}})["prefs"]["shake"], 1.5)
	finished["string_prefs_are_hostile_safe"] = true
