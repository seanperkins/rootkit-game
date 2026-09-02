class_name SaveGame extends RefCounted

## Atomic save with a .bak fallback.
##
## Discard-on-unreadable is only safe if a partial file is impossible. A crash
## mid-write leaves truncated JSON, which is unreadable, which would silently
## delete every buff, unlock and milestone. So: write .tmp, rotate the live file
## to .bak, then rename .tmp into place. A newer-version file is preserved to
## .v<N> rather than .bak, which would clobber the fallback.

## Not const: tests redirect these so a suite run cannot destroy a real
## profile's progression. See SaveGame.use_test_paths().
static var PATH := "user://save.json"
static var BAK := "user://save.json.bak"
static var TMP := "user://save.json.tmp"
const VERSION := 3

const BUFF_COST_BASE := 60
const BUFF_COST_STEP := 30
const BUFF_MAX := 10

## Preference key -> [min, max]. One table, consulted on BOTH sides of the file
## — _sanitise on read and set_pref on write — because a clamp that only runs on
## load lets a bad value persist and come back as something worse.
const PREF_RANGES := {
	"volume_master": [0.0, 1.0],
	"volume_sfx": [0.0, 1.0],
	"volume_music": [0.0, 1.0],
	"shake": [0.0, 2.0],
	# Stored as a number so one _num path covers every key; read as a bool.
	"damage_numbers": [0.0, 1.0],
}

## STRING preferences, kept apart from the numeric table on purpose: a string
## has no min/max, it has a length cap and a character whitelist, and pushing
## one through _num would silently turn a name into 0.0. Each row is
## [max_length, whitelist_kind]. Applied on read AND on write, like the numeric
## ranges, because save.json is user-editable and treated as hostile.
const PREF_STRINGS := {
	"display_name": [SessionRules.NAME_MAX, "printable"],
	"last_address": [SessionRules.ADDRESS_MAX, "hostname"],
}


## The v2 split. Two tables, because the two namespaces are read at different
## times by different code. SHEET_EFFECT is additive PLAYER stats, read directly
## by run.gd and never passed to the compiler. MULT_EFFECT is multiplicative
## EXPLOIT scalars, folded by Compiler.build after the flat module fold.
##
## Both hold DELTAS, not absolutes: cpu_cycles at rank 10 yields 0.40, and
## PlayerStats.mults() is what turns that into the x1.40 the compiler wants.
##
## The split is what makes the bandwidth-sold-as-radius bug structurally
## impossible to repeat: a player stat has no landing site in the exploit
## namespace, so it cannot be quietly delivered as something else.
const SHEET_EFFECT := {
	&"memory":     {&"integrity": 8.0},
	&"firewall":   {&"armor": 0.6},
	&"encryption": {&"defense": 6.0},
	&"bus_speed":  {&"clock_speed": 6.0},
	&"bandwidth":  {&"pickup_radius": 6.0},
}

const MULT_EFFECT := {
	&"cpu_cycles": {&"attack": 0.04},
	&"cooling":    {&"haste": -0.03},
	&"addressing": {&"reach": 0.03},
}

static var _cache: Dictionary = {}

static func _default() -> Dictionary:
	return {
		"version": VERSION,
		"salvage": 0,
		"buffs": {
			"cpu_cycles": 0, "cooling": 0, "memory": 0, "firewall": 0,
			"encryption": 0, "bus_speed": 0, "addressing": 0, "bandwidth": 0,
		},
		"unlocked": [],
		"kills": 0,
		"flips": 0,
		"prefs": {
			"volume_master": 0.8,
			"volume_sfx": 0.8,
			"volume_music": 0.5,
			"shake": 1.0,
			"damage_numbers": 1.0,
			"display_name": "",
			"last_address": "127.0.0.1",
		},
	}

## Tests must run against a known save. Progression is persistent by design —
## banked kills cross milestones and unlock modules, which changes the card pool
## and therefore the build — so a test that inherits user://save.json is not
## measuring what it thinks it is.
static func use_fresh_state() -> void:
	_cache = _default()

## Point persistence at throwaway files. Without this the suite writes hostile
## fixtures and a deliberately truncated file straight into the player's save.
static func use_test_paths() -> void:
	PATH = "user://test_save.json"
	BAK = "user://test_save.json.bak"
	TMP = "user://test_save.json.tmp"
	DirAccess.remove_absolute(PATH)
	DirAccess.remove_absolute(BAK)
	DirAccess.remove_absolute(TMP)
	_cache = _default()

static func load_state() -> Dictionary:
	if not _cache.is_empty():
		return _cache
	var d := _read(PATH)
	if d.is_empty():
		d = _read(BAK)
	if d.is_empty():
		d = _default()
	_cache = _sanitise(d)
	return _cache

static func _read(p: String) -> Dictionary:
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	# Both reads guarded, and on FINITE-NUMBER rather than merely non-null:
	# int(null) is "Nonexistent 'int' constructor" and aborts _read, silently
	# discarding the save; int(INF) is 9223372036854775807, which quarantines a
	# live save away under a nonsense suffix.
	var ver := int(_num(parsed.get("version", 0), 0.0))
	if ver > VERSION:
		DirAccess.rename_absolute(p, "user://save.json.v%d" % ver)
		return {}
	return parsed

## A total numeric read. `float(v)` and `int(v)` are NOT total: a Dictionary or
## Array value is an invalid-type error, and `float(null)` is too — and a
## GDScript runtime error aborts the whole function it happens in, so one bad
## value in a hand-edited save takes out _sanitise, leaves _cache unassigned,
## and cascades into every caller that indexes the result.
##
## Non-finite is rejected as well, and `clampf` is not the check: clampf(NAN,
## 0, 2) returns nan. INF does clamp correctly, but it is rejected under the
## same rule because one rule is easier to keep right than two — and because a
## NaN that reaches the dictionary is stringified to `null` by JSON.stringify
## and comes back as the abort above.
static func _num(v, fallback: float) -> float:
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return fallback
	var f := float(v)
	return f if is_finite(f) else fallback

## Godot's JSON parser returns every number as float, so int() coercion is not
## optional — a typeof(v) == TYPE_INT check would reject the file the game just
## wrote. Ranges are clamped because user://save.json is plaintext and is the
## only user-controlled input in the game.
static func _sanitise(d: Dictionary) -> Dictionary:
	var out := _default()
	out["salvage"] = clampi(int(_num(d.get("salvage", 0), 0.0)), 0, 1_000_000_000)
	out["kills"] = maxi(0, int(_num(d.get("kills", 0), 0.0)))
	out["flips"] = maxi(0, int(_num(d.get("flips", 0), 0.0)))
	var b = d.get("buffs", {})
	if typeof(b) == TYPE_DICTIONARY:
		for k in out["buffs"]:
			out["buffs"][k] = clampi(int(_num(b.get(k, 0), 0.0)), 0, BUFF_MAX)
	# The CONTAINER type is guarded before it is indexed, exactly as buffs and
	# unlocked are. Without it {"prefs": "owned"} makes prefs.get(...) a runtime
	# error and takes the whole load path with it.
	var pr = d.get("prefs", {})
	if typeof(pr) == TYPE_DICTIONARY:
		for k in out["prefs"]:
			if PREF_STRINGS.has(k):
				out["prefs"][k] = sanitise_string_pref(k, pr.get(k, out["prefs"][k]))
				continue
			var rng: Array = PREF_RANGES[k]
			out["prefs"][k] = clampf(_num(pr.get(k, out["prefs"][k]),
				out["prefs"][k]), rng[0], rng[1])
	var u = d.get("unlocked", [])
	if typeof(u) == TYPE_ARRAY:
		# Ids resolve against the code table. A save string never reaches a load
		# path; unknown ids are dropped rather than failing the whole load.
		var known := ModuleTable.by_id()
		var keep := []
		for id in u:
			if known.has(StringName(id)):
				keep.append(String(id))
		out["unlocked"] = keep
	return out

static func prefs() -> Dictionary:
	return load_state()["prefs"]

## Clamped on WRITE as well as read. save_state stringifies _cache, which is
## sanitised on load and then mutated freely, so a settings screen assigning
## straight into the dictionary would get no clamp until the next cold load.
## The write side is the sharper one: JSON.stringify turns a NaN into `null`
## and an INF into `1e99999`, both VALID JSON — so the bad value is faithfully
## persisted and detonates on the next read rather than being rejected here.
static func set_pref(key: String, value: float) -> void:
	if not PREF_RANGES.has(key):
		return
	var rng: Array = PREF_RANGES[key]
	var d := load_state()
	d["prefs"][key] = clampf(_num(value, float(_default()["prefs"][key])),
		rng[0], rng[1])

## A string preference, sanitised on write exactly as on read: the container
## type is checked, the length is capped, and every character outside the key's
## whitelist is dropped — never escaped or substituted, because a substituted
## character would still be a string the game did not write.
static func set_string_pref(key: String, value) -> void:
	if not PREF_STRINGS.has(key):
		return
	load_state()["prefs"][key] = sanitise_string_pref(key, value)

static func string_pref(key: String) -> String:
	if not PREF_STRINGS.has(key):
		return ""
	return String(load_state()["prefs"].get(key, _default()["prefs"][key]))

## The only legal shapes: "printable" is ASCII 0x20..0x7E, the characters a
## display name may carry; "hostname" is letters, digits, dot, dash and colon,
## which covers an IPv4, IPv6 or DNS host and nothing that could be a path or a
## shell. A non-string is the default, not an empty string, so a hand-edited
## `null` cannot blank a field the lobby needs.
static func sanitise_string_pref(key: String, value) -> String:
	var row: Array = PREF_STRINGS[key]
	var fallback: String = _default()["prefs"][key]
	if typeof(value) != TYPE_STRING:
		return fallback
	var kind: String = row[1]
	var out := ""
	for ch in String(value):
		var code := ch.unicode_at(0)
		var ok := false
		if kind == "printable":
			ok = code >= 0x20 and code <= 0x7E
		else:
			ok = (code >= 0x30 and code <= 0x39) or (code >= 0x41 and code <= 0x5A) \
				or (code >= 0x61 and code <= 0x7A) or ch == "." or ch == "-" or ch == ":"
		if ok:
			out += ch
		if out.length() >= int(row[0]):
			break
	return out

static func save_state() -> bool:
	var d := load_state()
	var f := FileAccess.open(TMP, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(d))
	f.flush()
	f.close()
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(BAK)
		DirAccess.rename_absolute(PATH, BAK)
	return DirAccess.rename_absolute(TMP, PATH) == OK

static func bank(salvage: int, kills: int, flips: int) -> void:
	var d := load_state()
	d["salvage"] = clampi(d["salvage"] + salvage, 0, 1_000_000_000)
	d["kills"] += kills
	d["flips"] += flips
	for m in ModuleTable.LOCKED:
		if _milestone_met(m, d) and not (String(m) in d["unlocked"]):
			d["unlocked"].append(String(m))
	save_state()

## Unlock state is DERIVED from the milestone counters, never read from the
## stored list. The list is only evaluated inside bank(), so any state reached
## outside that call desyncs — a save with 212 kills displayed as locked against
## a 150-kill requirement. Counters are the single source of truth; the stored
## list is kept for forward compatibility but is not load-bearing.
static func is_unlocked(id: StringName) -> bool:
	return _milestone_met(id, load_state())

## The unlock ladder, in ONE place.
##
## This was a match statement here and a second hardcoded copy of the same
## numbers in meta_screen's requirement text. Two tables of the same facts drift
## the moment one is edited, and the symptom — a shop promising 150 kills for
## something that unlocks at 300 — is invisible until a player counts.
##
## Spread across kills and flips deliberately, so a corruption build and a
## damage build unlock different things rather than walking the same ladder.
const MILESTONES := {
	&"worm":             [&"flips", 50],
	&"beam":             [&"kills", 400],
	&"on_damage_taken":  [&"kills", 150],
	&"landmine":         [&"kills", 550],
	&"mirror":           [&"flips", 25],
	&"checksum":         [&"flips", 80],
	&"on_low_integrity": [&"kills", 300],
	&"on_flip":          [&"flips", 15],
	&"on_level_up":      [&"kills", 450],
	&"heap_spray":       [&"kills", 200],
	&"tarpit":           [&"flips", 40],
}

static func _milestone_met(id: StringName, d: Dictionary) -> bool:
	if not MILESTONES.has(id):
		return false
	var row: Array = MILESTONES[id]
	return int(d[row[0]]) >= int(row[1])

## "250 kills (37/250)", from the same table the check reads.
static func milestone_text(id: StringName, d: Dictionary) -> String:
	if not MILESTONES.has(id):
		return ""
	var row: Array = MILESTONES[id]
	return "%d %s  (%d/%d)" % [int(row[1]), row[0], int(d[row[0]]), int(row[1])]

static func unlocked_modules() -> Array:
	return unlocked_modules_from(session_counters())

static func player_sheet() -> Dictionary:
	return player_sheet_from(session_counters())

static func multipliers() -> Dictionary:
	return multipliers_from(session_counters())

# ----------------------------------------------- explicit session counters ---
#
# Every derived starting fact — the additive player sheet, the multiplicative
# exploit scalars, and the unlocked module set — is a pure function of three
# counters: the eight buff ranks, lifetime kills, and lifetime flips. A co-op
# peer needs those functions to run on ANOTHER player's counters, arriving in a
# packet, without touching its own SaveGame._cache and without trusting the
# stored `unlocked` list. So the derivation is factored into `*_from` functions
# over an explicit counter dictionary, and the no-argument readers above are
# just the local case: `_from(session_counters())`.

## This process's own counters, copied out of the live cache. The buffs dict is
## duplicated so a caller cannot mutate the cache through the returned value.
static func session_counters() -> Dictionary:
	var d := load_state()
	return {
		"buffs": (d["buffs"] as Dictionary).duplicate(),
		"kills": int(d["kills"]),
		"flips": int(d["flips"]),
	}

## A received counter dictionary is HOSTILE. Keep only the eight known buff
## names, each clamped like a stored buff; coerce kills/flips through the same
## total numeric read as the save file; drop every unknown field. The result is
## byte-stable given equal inputs, which is what lets two peers derive an
## identical descriptor.
static func sanitise_session_counters(raw) -> Dictionary:
	var out := {"buffs": {}, "kills": 0, "flips": 0}
	for k in _default()["buffs"]:
		out["buffs"][k] = 0
	if typeof(raw) == TYPE_DICTIONARY:
		var b = raw.get("buffs", {})
		if typeof(b) == TYPE_DICTIONARY:
			for k in out["buffs"]:
				out["buffs"][k] = clampi(int(_num(b.get(k, 0), 0.0)), 0, BUFF_MAX)
		out["kills"] = maxi(0, int(_num(raw.get("kills", 0), 0.0)))
		out["flips"] = maxi(0, int(_num(raw.get("flips", 0), 0.0)))
	return out

static func player_sheet_from(counters: Dictionary) -> Dictionary:
	return _fold_buffs(SHEET_EFFECT, counters.get("buffs", {}))

static func multipliers_from(counters: Dictionary) -> Dictionary:
	return _fold_buffs(MULT_EFFECT, counters.get("buffs", {}))

## Unlocks are DERIVED from the milestone counters, never read from a stored
## list — the same rule the local path keeps, now over supplied counters so a
## remote player's unlock set is computed identically on every peer.
static func unlocked_modules_from(counters: Dictionary) -> Array:
	var out := ModuleTable.starting_unlocked()
	var table := ModuleTable.by_id()
	for id in ModuleTable.LOCKED:
		if _milestone_met_counters(id, counters) and table.has(id) \
				and not (table[id] in out):
			out.append(table[id])
	return out

static func _milestone_met_counters(id: StringName, counters: Dictionary) -> bool:
	if not MILESTONES.has(id):
		return false
	var row: Array = MILESTONES[id]
	return int(counters.get(row[0], 0)) >= int(row[1])

## .get, never a direct index. The supplied buffs dict holds only its own names
## while each effect table holds only its subset, so a direct index throws on the
## first name the table does not know and aborts the whole fold — returning {}
## and discarding everything accumulated before it. That is the shipped bug this
## file carried.
static func _fold_buffs(table: Dictionary, buffs: Dictionary) -> Dictionary:
	var out := {}
	for name in buffs:
		var n: int = int(buffs[name])
		if n <= 0:
			continue
		var eff: Dictionary = table.get(StringName(name), {})
		for k in eff:
			out[k] = out.get(k, 0.0) + eff[k] * n
	return out

static func buff_price(current: int) -> int:
	return BUFF_COST_BASE + BUFF_COST_STEP * current

static func buy(name: StringName) -> bool:
	var d := load_state()
	var cur: int = d["buffs"].get(String(name), 0)
	if cur >= BUFF_MAX:
		return false
	var price := buff_price(cur)
	if d["salvage"] < price:
		return false
	d["salvage"] -= price
	d["buffs"][String(name)] = cur + 1
	save_state()
	return true
