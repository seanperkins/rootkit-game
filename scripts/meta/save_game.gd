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
const VERSION := 2

const BUFF_COST_BASE := 60
const BUFF_COST_STEP := 30
const BUFF_MAX := 10


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
	if int(parsed.get("version", 0)) > VERSION:
		DirAccess.rename_absolute(p, "user://save.json.v%d" % int(parsed["version"]))
		return {}
	return parsed

## Godot's JSON parser returns every number as float, so int() coercion is not
## optional — a typeof(v) == TYPE_INT check would reject the file the game just
## wrote. Ranges are clamped because user://save.json is plaintext and is the
## only user-controlled input in the game.
static func _sanitise(d: Dictionary) -> Dictionary:
	var out := _default()
	out["salvage"] = clampi(int(d.get("salvage", 0)), 0, 1_000_000_000)
	out["kills"] = maxi(0, int(d.get("kills", 0)))
	out["flips"] = maxi(0, int(d.get("flips", 0)))
	var b = d.get("buffs", {})
	if typeof(b) == TYPE_DICTIONARY:
		for k in out["buffs"]:
			out["buffs"][k] = clampi(int(b.get(k, 0)), 0, BUFF_MAX)
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
	&"snipe":            [&"kills", 250],
	&"landmine":         [&"kills", 550],
	&"cascade":          [&"kills", 700],
	&"mirror":           [&"flips", 25],
	&"airgap":           [&"kills", 900],
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
	var out := ModuleTable.starting_unlocked()
	var table := ModuleTable.by_id()
	for id in ModuleTable.LOCKED:
		if is_unlocked(id) and table.has(id) and not (table[id] in out):
			out.append(table[id])
	return out

static func player_sheet() -> Dictionary:
	return _fold(SHEET_EFFECT)

static func multipliers() -> Dictionary:
	return _fold(MULT_EFFECT)

## .get, never a direct index. d["buffs"] holds all eight names while each table
## holds only its own subset, so a direct index throws on the first name the
## table does not know and aborts the whole fold — returning {} and discarding
## everything accumulated before it. That is the shipped bug this file carried.
static func _fold(table: Dictionary) -> Dictionary:
	var d := load_state()
	var out := {}
	for name in d["buffs"]:
		var n: int = d["buffs"][name]
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
