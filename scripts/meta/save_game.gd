class_name SaveGame extends RefCounted

## Atomic save with a .bak fallback.
##
## Discard-on-unreadable is only safe if a partial file is impossible. A crash
## mid-write leaves truncated JSON, which is unreadable, which would silently
## delete every buff, unlock and milestone. So: write .tmp, rotate the live file
## to .bak, then rename .tmp into place. A newer-version file is preserved to
## .v<N> rather than .bak, which would clobber the fallback.

const PATH := "user://save.json"
const BAK := "user://save.json.bak"
const TMP := "user://save.json.tmp"
const VERSION := 1

const BUFF_COST_BASE := 60
const BUFF_COST_STEP := 30
const BUFF_MAX := 10

const BUFF_EFFECT := {
	&"cpu_cycles": {&"damage": 1.5},
	&"cooling": {&"cooldown": -0.02},
	&"bandwidth": {&"radius": 6.0},
}

static var _cache: Dictionary = {}

static func _default() -> Dictionary:
	return {
		"version": VERSION,
		"salvage": 0,
		"buffs": {"cpu_cycles": 0, "cooling": 0, "bandwidth": 0},
		"unlocked": [],
		"kills": 0,
		"flips": 0,
	}

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

static func _milestone_met(id: StringName, d: Dictionary) -> bool:
	match id:
		&"worm":            return d["flips"] >= 50
		&"beam":            return d["kills"] >= 400
		&"on_damage_taken": return d["kills"] >= 150
	return false

static func unlocked_modules() -> Array:
	var d := load_state()
	var out := ModuleTable.starting_unlocked()
	var table := ModuleTable.by_id()
	for id in d["unlocked"]:
		var sid := StringName(id)
		if table.has(sid) and not (table[sid] in out):
			out.append(table[sid])
	return out

static func buff_stats() -> Dictionary:
	var d := load_state()
	var out := {}
	for name in d["buffs"]:
		var n: int = d["buffs"][name]
		if n <= 0:
			continue
		for k in BUFF_EFFECT[StringName(name)]:
			out[k] = out.get(k, 0.0) + BUFF_EFFECT[StringName(name)][k] * n
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
