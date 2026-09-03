extends SceneTree

## The lobby's pure logic on NetworkSession, and the string preferences it
## reads: slot assignment, the frozen START descriptor, reconnect admission,
## the client's WELCOME/START application, solo's identical shape, and the
## hostile-safe name and address fields.

var failures := 0
var finished := {}

const CASES := ["host_owns_slot_zero_and_assigns_the_lowest_free",
	"start_freezes_the_roster", "a_client_applies_welcome_then_start",
	"solo_builds_the_same_shape", "string_prefs_are_hostile_safe",
	"control_bodies_round_trip_and_reject_bad_shapes",
	"the_link_column_offers_relay_and_lan",
	"the_lobby_handshake_survives_a_session_id_it_has_not_learned_yet"]

func _initialize() -> void:
	print("ROOTKIT — lobby\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	host_owns_slot_zero_and_assigns_the_lowest_free()
	start_freezes_the_roster()
	a_client_applies_welcome_then_start()
	solo_builds_the_same_shape()
	string_prefs_are_hostile_safe()
	control_bodies_round_trip_and_reject_bad_shapes()
	the_lobby_handshake_survives_a_session_id_it_has_not_learned_yet()
	await the_link_column_offers_relay_and_lan()
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

## Every control kind the run and lobby send has a codec that keeps its named
## fields and refuses a body outside its shape: a slot past the roster, an
## outcome past the enum, a foreign field.
func control_bodies_round_trip_and_reject_bad_shapes() -> void:
	var M := Protocol.Message
	var body := func(kind: int, tick: int, d: Dictionary) -> Dictionary:
		var bytes := Protocol.encode_control(kind, 7, tick, d)
		var env := Protocol.decode_envelope(bytes, {"session_id": 7})
		return Protocol.decode_control(kind, int(env["tick"]), env["body"])
	for kind in [M.ABSENT, M.PRESENT, M.LEAVE]:
		var out: Dictionary = body.call(kind, 40, {"slot": 2, "extra": "dropped"})
		_check("%s carries its slot and tick" % M.keys()[kind],
			[out.get("slot"), out.get("tick"), out.has("extra")], [2, 40, false])
		_check("%s refuses a slot past the roster" % M.keys()[kind],
			body.call(kind, 40, {"slot": 4}).is_empty(), true)
	var cand: Dictionary = body.call(M.END_CANDIDATE, 90,
		{"outcome": NetworkSession.Outcome.LOSS, "hash": 12345})
	_check("END_CANDIDATE carries outcome and hash",
		[cand.get("outcome"), cand.get("hash")], [NetworkSession.Outcome.LOSS, 12345])
	_check("an outcome past the enum is refused",
		body.call(M.END, 90, {"outcome": NetworkSession.Outcome.size(), "hash": 0}).is_empty(), true)
	_check("END_CHECK is its tick alone", body.call(M.END_CHECK, 96, {})["tick"], 96)
	_check("RESYNC keeps its clears_end flag",
		body.call(M.RESYNC, 96, {"clears_end": true})["clears_end"], true)
	_check("a non-dictionary body is refused",
		Protocol.decode_control(M.ABSENT, 1, var_to_bytes([1, 2])).is_empty(), true)
	finished["control_bodies_round_trip_and_reject_bad_shapes"] = true

## The one text field takes a code or an address: six alphabet characters
## route through the relay, anything else is a direct address. Hosting
## defaults to the relay and shows the code with a copy button; "host LAN"
## keeps the direct server.
func the_link_column_offers_relay_and_lan() -> void:
	var m: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(m)
	await process_frame
	_check("there is a host button", m._host_btn != null, true)
	_check("and a host LAN button", m._host_lan_btn != null, true)
	_check("and a copy button, hidden until a code exists", m._copy_btn.visible, false)
	_check("the field says what it takes", m._addr_edit.placeholder_text, "room code or address")
	_check("a code routes to the relay", m._wants_relay("abc234"), true)
	_check("an address routes direct", m._wants_relay("192.168.1.20"), false)
	_check("the relay lobby uses the relay delay", m._delay_for(true), SessionRules.RELAY_DELAY)
	_check("the LAN lobby keeps the default", m._delay_for(false), SessionRules.DEFAULT_DELAY)
	m.queue_free()
	await process_frame
	finished["the_link_column_offers_relay_and_lan"] = true

## A joiner learns its session id FROM the WELCOME in its inbox and applies it
## a step later. A START that lands in the same poll batch is decoded while the
## joiner's context still reads session id 0 — so the envelope check must
## exempt the lobby handshake, or START is refused and the run never begins.
## This was intermittent: it only bit when WELCOME and START arrived together.
func the_lobby_handshake_survives_a_session_id_it_has_not_learned_yet() -> void:
	var M := Protocol.Message
	var sid := 777
	# The joiner has not applied WELCOME yet: its context session id is 0.
	var ctx := {"session_id": 0}
	for kind in [M.HELLO, M.WELCOME, M.START]:
		var bytes := Protocol.encode_control(kind, sid, 0, {})
		_check("%s is accepted before the joiner knows the session" % M.keys()[kind],
			Protocol.decode_envelope(bytes, ctx).is_empty(), false)
	# An in-game message with the wrong session id is still refused.
	var input := Protocol.encode_input(sid, 0, Vector2.ZERO, -1, -1, -1)
	_check("but a foreign-session INPUT is still refused",
		Protocol.decode_envelope(input, ctx).is_empty(), true)
	# Once the joiner has its session, the handshake still matches normally.
	_check("and START matches once the session is known",
		Protocol.decode_envelope(Protocol.encode_control(M.START, sid, 0, {}),
			{"session_id": sid}).is_empty(), false)
	finished["the_lobby_handshake_survives_a_session_id_it_has_not_learned_yet"] = true
