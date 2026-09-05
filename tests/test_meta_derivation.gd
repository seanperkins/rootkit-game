extends SceneTree

## The session descriptor and its derivations, the way lockstep needs them: a
## descriptor validates to the same bytes on every peer regardless of roster
## order, and each player's starting build is a pure, peer-independent function
## of their counters. If two peers disagreed on either, the run would desync on
## frame one.

var failures := 0
var finished := {}

const CASES := ["descriptor_is_peer_independent", "derivation_follows_counters",
	"validation_rejects_the_hostile", "counters_are_sanitised",
	"solo_descriptor_is_offline"]

func _initialize() -> void:
	print("ROOTKIT — session descriptor derivation\n")
	SaveGame.use_fresh_state()
	descriptor_is_peer_independent()
	derivation_follows_counters()
	validation_rejects_the_hostile()
	counters_are_sanitised()
	solo_descriptor_is_offline()
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

func _profile(slot: int, name: String, buffs: Dictionary, kills: int,
		flips: int) -> Dictionary:
	return {"slot": slot, "name": name,
		"counters": {"buffs": buffs, "kills": kills, "flips": flips}}

## The two builds this suite exchanges: a damage-heavy veteran and a fresh
## corruption player, with different buffs, kills, and flips.
func _row_a() -> Dictionary:
	return _profile(0, "veteran", {"cpu_cycles": 4, "memory": 3, "bus_speed": 2},
		500, 20)

func _row_b() -> Dictionary:
	return _profile(1, "rookie", {"cooling": 2, "addressing": 5}, 60, 55)

func _raw(roster: Array) -> Dictionary:
	return {"protocol": SessionRules.PROTOCOL, "session_id": 7, "seed": 20260830,
		"delay": SessionRules.DEFAULT_DELAY,
		"choice_timeout": SessionRules.CHOICE_TIMEOUT_TICKS, "roster": roster}

## Two peers receive the roster in opposite orders and still validate to byte-
## identical descriptors — the ordering the wire happened to use cannot change a
## single byte, or the seed and every build would diverge.
func descriptor_is_peer_independent() -> void:
	var host := NetworkSession.validate_descriptor(_raw([_row_a(), _row_b()]))
	var client := NetworkSession.validate_descriptor(_raw([_row_b(), _row_a()]))
	_check_true("both descriptors validate", not host.is_empty()
		and not client.is_empty())
	_check("descriptors are byte-identical regardless of roster order",
		host == client, true)
	_check("the roster is in stable slot order",
		host["roster"][0]["slot"] < host["roster"][1]["slot"], true)
	# The two peers, each bound to their own slot, hold the same descriptor.
	var s0 := NetworkSession.create(host, 0, NetworkSession.Role.HOST)
	var s1 := NetworkSession.create(client, 1, NetworkSession.Role.CLIENT)
	_check("peer zero sees the veteran at its slot",
		s0.profile(0)["name"], "veteran")
	_check("peer one sees the same veteran at slot zero",
		s1.profile(0)["name"], "veteran")
	finished["descriptor_is_peer_independent"] = true

## Every derived starting fact is a pure function of a slot's counters, so both
## peers compute the same sheet, multipliers, unlocks, and compiled build for a
## given slot — and the two slots, with different counters, differ.
func derivation_follows_counters() -> void:
	var desc := NetworkSession.validate_descriptor(_raw([_row_a(), _row_b()]))
	var c0: Dictionary = desc["roster"][0]["counters"]
	var c1: Dictionary = desc["roster"][1]["counters"]

	_check("slot zero sheet derives identically twice",
		SaveGame.player_sheet_from(c0) == SaveGame.player_sheet_from(c0), true)
	_check("the two slots derive different sheets",
		SaveGame.player_sheet_from(c0) == SaveGame.player_sheet_from(c1), false)
	_check("slot zero multipliers are deterministic",
		SaveGame.multipliers_from(c0) == SaveGame.multipliers_from(c0), true)

	# The veteran's 500 kills / 20 flips unlock a different module set than the
	# rookie's 60 / 55, and both derive by id so the comparison is order-safe.
	var u0 := _unlock_ids(SaveGame.unlocked_modules_from(c0))
	var u1 := _unlock_ids(SaveGame.unlocked_modules_from(c1))
	_check("unlock ids derive identically twice",
		u0 == _unlock_ids(SaveGame.unlocked_modules_from(c0)), true)
	_check("the two slots unlock different modules", u0 == u1, false)

	_check_true("compiled starting builds match for slot zero",
		_loadouts_equal(_compile_start(c0), _compile_start(c0)))
	_check_true("compiled starting builds match for slot one",
		_loadouts_equal(_compile_start(c1), _compile_start(c1)))
	_check("the two slots compile to different builds",
		_loadouts_equal(_compile_start(c0), _compile_start(c1)), false)
	finished["derivation_follows_counters"] = true

func _unlock_ids(mods: Array) -> Array:
	var ids := []
	for m in mods:
		ids.append(String(m.id))
	ids.sort()
	return ids

func _compile_start(counters: Dictionary) -> Array:
	var table := ModuleTable.by_id()
	var lo := Loadout.new()
	lo.start(table[&"packet"])
	lo.mult = PlayerStats.mults(SaveGame.multipliers_from(counters))
	return lo.compile_all()

func _loadouts_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if not a[i].equals(b[i]):
			return false
	return true

## Everything a hostile peer could send is refused, not clamped: a descriptor
## that differs by one byte between peers desyncs the whole run, so the safe
## outcome for malformed input is an empty descriptor.
func validation_rejects_the_hostile() -> void:
	_check("a non-dictionary is rejected",
		NetworkSession.validate_descriptor("nope").is_empty(), true)
	var bad_proto := _raw([_row_a()]); bad_proto["protocol"] = 99
	_check("a wrong protocol is rejected",
		NetworkSession.validate_descriptor(bad_proto).is_empty(), true)
	var bad_seed := _raw([_row_a()]); bad_seed["seed"] = INF
	_check("a non-finite seed is rejected",
		NetworkSession.validate_descriptor(bad_seed).is_empty(), true)
	var dup := _raw([_row_a(), _profile(0, "clash", {}, 0, 0)])
	_check("duplicate slots are rejected",
		NetworkSession.validate_descriptor(dup).is_empty(), true)
	var over := _raw([_profile(0, "", {}, 0, 0), _profile(1, "", {}, 0, 0),
		_profile(2, "", {}, 0, 0), _profile(3, "", {}, 0, 0),
		_profile(0, "fifth", {}, 0, 0)])
	over["roster"] = over["roster"]  # five rows, one over the cap
	_check("a roster over the player cap is rejected",
		NetworkSession.validate_descriptor(over).is_empty(), true)
	var long_name := _raw([_profile(0, "x".repeat(SessionRules.NAME_MAX + 1),
		{}, 0, 0)])
	_check("an overlong name is rejected",
		NetworkSession.validate_descriptor(long_name).is_empty(), true)
	var bad_slot := _raw([_profile(9, "oob", {}, 0, 0)])
	_check("an out-of-range slot is rejected",
		NetworkSession.validate_descriptor(bad_slot).is_empty(), true)

	# An unknown top-level field does not fail the handshake, but must not enter
	# the canonical descriptor — otherwise one peer's junk would break the byte
	# comparison against a peer that never sent it.
	var junky := _raw([_row_a()]); junky["evil"] = 123
	var cleaned := NetworkSession.validate_descriptor(junky)
	_check_true("an unknown field does not reject", not cleaned.is_empty())
	_check("the unknown field is dropped", cleaned.has("evil"), false)
	finished["validation_rejects_the_hostile"] = true

## Received counters are sanitised the way the save file is: unknown buff names
## dropped, ranks and totals clamped, non-finite refused.
func counters_are_sanitised() -> void:
	var raw := {"buffs": {"cpu_cycles": 999, "not_a_buff": 5}, "kills": -40,
		"flips": 3, "extra": "junk"}
	var c := SaveGame.sanitise_session_counters(raw)
	_check("an over-cap buff clamps to the max",
		c["buffs"]["cpu_cycles"], SaveGame.BUFF_MAX)
	_check("an unknown buff name is dropped",
		c["buffs"].has("not_a_buff"), false)
	_check("negative kills clamp to zero", c["kills"], 0)
	_check("a legal flip total survives", c["flips"], 3)
	_check("an unknown field is dropped", c.has("extra"), false)
	var nonsense := SaveGame.sanitise_session_counters("not even a dict")
	_check("non-dictionary counters become the empty baseline",
		int(nonsense["kills"]), 0)
	finished["counters_are_sanitised"] = true

## The offline descriptor is a valid one-slot session with no delay and no
## timeout — this peer's own record is always present, and no one else can stall
## an offer.
func solo_descriptor_is_offline() -> void:
	var desc := NetworkSession.validate_descriptor(
		NetworkSession.solo_descriptor(_profile(0, "me", {"memory": 2}, 10, 1),
			20260830))
	_check_true("the solo descriptor validates", not desc.is_empty())
	_check("it has exactly one roster row", desc["roster"].size(), 1)
	_check("solo runs at zero input delay", desc["delay"], 0)
	_check("solo offers never time out", desc["choice_timeout"], 0)
	finished["solo_descriptor_is_offline"] = true
