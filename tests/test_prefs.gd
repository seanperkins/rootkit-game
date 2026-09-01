extends SceneTree

## save.json is plaintext, user-editable, and treated as hostile.
##
## Every case here drives the REAL load path against a REAL written file. The
## failure mode is a script error inside _sanitise — which aborts the function,
## leaves _cache unassigned, and cascades into every caller that indexes the
## result — and only the real path reaches it. A constructed dictionary would
## assert nothing.

var failures := 0
var finished := {}

const CASES := ["defaults_are_sane", "out_of_range_clamps",
	"a_non_dictionary_prefs_yields_defaults", "hostile_per_key_values",
	"a_hostile_version_does_not_discard_the_save",
	"scalars_survive_hostile_values", "a_v2_file_loads_with_default_prefs",
	"set_pref_rejects_non_finite", "a_round_trip_preserves_what_was_set"]

func _initialize() -> void:
	print("ROOTKIT — prefs\n")
	SaveGame.use_test_paths()
	defaults_are_sane()
	out_of_range_clamps()
	a_non_dictionary_prefs_yields_defaults()
	hostile_per_key_values()
	a_hostile_version_does_not_discard_the_save()
	scalars_survive_hostile_values()
	a_v2_file_loads_with_default_prefs()
	set_pref_rejects_non_finite()
	a_round_trip_preserves_what_was_set()
	print("")
	for c in CASES:
		if not finished.has(c):
			print("  FAIL  case '%s' never finished — it aborted part way" % c)
			failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want or (got is float and want is float and abs(got - want) < 1e-5):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

## Write a raw save and force a cold load.
##
## The cache reset is load-bearing: load_state() returns _cache whenever it is
## non-empty, so without this every case after the first short-circuits and the
## suite asserts nothing at all while reporting PASS — the exact failure class
## the runner exists to catch, arriving by a route it cannot see.
func _load_raw(text: String) -> Dictionary:
	var f := FileAccess.open(SaveGame.PATH, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	SaveGame._cache = {}
	return SaveGame.load_state()

func defaults_are_sane() -> void:
	SaveGame.use_fresh_state()
	var p := SaveGame.prefs()
	_check("master volume default", p["volume_master"], 0.8)
	_check("sfx volume default", p["volume_sfx"], 0.8)
	_check("shake default", p["shake"], 1.0)
	_check("damage numbers default on", p["damage_numbers"], 1.0)
	finished["defaults_are_sane"] = true

func out_of_range_clamps() -> void:
	var d := _load_raw('{"version":3,"prefs":{"shake":9999.0,' +
		'"volume_sfx":-40.0}}')
	_check("shake clamps to its ceiling", d["prefs"]["shake"], 2.0)
	_check("volume clamps to its floor", d["prefs"]["volume_sfx"], 0.0)
	finished["out_of_range_clamps"] = true

## The container guard buffs and unlocked both have. Without it,
## prefs.get(key, default) is a runtime error on a String or an Array.
func a_non_dictionary_prefs_yields_defaults() -> void:
	for hostile in ['"owned"', '[1,2,3]', '42']:
		var d := _load_raw('{"version":3,"prefs":%s,"salvage":77}' % hostile)
		_check("prefs=%s still loads" % hostile, d.is_empty(), false)
		_check("  and yields default shake", d["prefs"]["shake"], 1.0)
		_check("  and the rest of the save survived", d["salvage"], 77)
	finished["a_non_dictionary_prefs_yields_defaults"] = true

## float(v) is not total. null is the one that is reachable without hand-editing
## — JSON.stringify writes a NaN as `null`, so a bad value round-trips into it.
func hostile_per_key_values() -> void:
	for hostile in ['null', '{"a":1}', '[1]', '"loud"']:
		var d := _load_raw('{"version":3,"prefs":{"shake":%s}}' % hostile)
		_check("shake=%s does not abort the load" % hostile, d.is_empty(), false)
		_check("  and falls back to the default", d["prefs"]["shake"], 1.0)
	# JSON cannot spell NAN or INF directly, but 1e999 parses to inf.
	var e := _load_raw('{"version":3,"prefs":{"shake":1e999}}')
	_check("an infinite shake falls back", e["prefs"]["shake"], 1.0)
	finished["hostile_per_key_values"] = true

## int(parsed.get("version", 0)) sits in _read, outside _sanitise and therefore
## outside _num's reach. int(null) is "Nonexistent 'int' constructor", which
## aborts _read and silently discards the save; int(INF) is 9223372036854775807,
## which quarantines a live save under a nonsense suffix.
func a_hostile_version_does_not_discard_the_save() -> void:
	var d := _load_raw('{"version":null,"salvage":123}')
	_check("a null version still loads the file", d["salvage"], 123)
	var e := _load_raw('{"version":1e999,"salvage":456}')
	_check("an infinite version still loads the file", e["salvage"], 456)
	_check("and the live save was not quarantined",
		FileAccess.file_exists(SaveGame.PATH), true)
	finished["a_hostile_version_does_not_discard_the_save"] = true

## _num covers salvage/kills/flips too. Their blast radius is worse than buffs:
## _read succeeds, so _sanitise aborts and load_state returns {} rather than a
## default profile, which then sticks in the cache.
func scalars_survive_hostile_values() -> void:
	var d := _load_raw('{"version":3,"salvage":null,"kills":{"a":1},' +
		'"flips":"many"}')
	_check("a hostile save still returns a profile", d.is_empty(), false)
	_check("salvage falls back", d["salvage"], 0)
	_check("kills falls back", d["kills"], 0)
	_check("flips falls back", d["flips"], 0)
	_check("and buffs are still readable", d["buffs"].has("memory"), true)
	finished["scalars_survive_hostile_values"] = true

## _sanitise rebuilds from _default() and overlays, so a v2 file needs no
## migration — it simply has no prefs to overlay.
func a_v2_file_loads_with_default_prefs() -> void:
	var d := _load_raw('{"version":2,"salvage":500,"kills":40,' +
		'"buffs":{"memory":3}}')
	_check("the v2 payload survives", d["salvage"], 500)
	_check("its buffs survive", d["buffs"]["memory"], 3)
	_check("and prefs arrive at their defaults", d["prefs"]["shake"], 1.0)
	finished["a_v2_file_loads_with_default_prefs"] = true

## clampf(NAN, 0, 2) is nan, so a clamp is not a finiteness check. A NaN that
## reaches the dictionary is stringified as `null` and detonates on the NEXT
## read, which is why the write side needs the same rule as the read side.
func set_pref_rejects_non_finite() -> void:
	SaveGame.use_fresh_state()
	SaveGame.set_pref("shake", NAN)
	_check("NAN does not reach the dictionary",
		is_finite(SaveGame.prefs()["shake"]), true)
	_check("it falls back to the default", SaveGame.prefs()["shake"], 1.0)
	SaveGame.set_pref("shake", INF)
	_check("INF does not reach the dictionary either",
		is_finite(SaveGame.prefs()["shake"]), true)
	SaveGame.set_pref("volume_sfx", 9.0)
	_check("and an in-type overshoot still clamps",
		SaveGame.prefs()["volume_sfx"], 1.0)
	SaveGame.set_pref("not_a_pref", 1.0)
	_check("an unknown key is a no-op",
		SaveGame.prefs().has("not_a_pref"), false)
	finished["set_pref_rejects_non_finite"] = true

func a_round_trip_preserves_what_was_set() -> void:
	SaveGame.use_fresh_state()
	SaveGame.set_pref("shake", 0.0)
	SaveGame.set_pref("volume_master", 0.25)
	SaveGame.save_state()
	SaveGame._cache = {}
	var p := SaveGame.prefs()
	_check("shake zero survives a round trip", p["shake"], 0.0)
	_check("and so does a fractional volume", p["volume_master"], 0.25)
	finished["a_round_trip_preserves_what_was_set"] = true
