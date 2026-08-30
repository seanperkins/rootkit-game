# Player Stats & Defensive Modules — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the player a real stat sheet — health, armor, defense, movement, pickup range, plus three global combat multipliers — and add three defensive PAYLOAD modules that feed it through a ward mechanism.

**Architecture:** A pure `PlayerStats` holds base values and the mitigation formula. The meta shop splits into additive player stats (`player_sheet()`, read directly by `run.gd`) and multiplicative exploit scalars (`multipliers()`, folded by `Compiler.build` after the flat module fold). Defensive modules contribute `ward_*` stats that arm a per-exploit timer on fire; effective armor/defense/clock_speed are base + meta + the **max** live ward. Ward magnitudes are never summed, at any level.

**Tech Stack:** Godot 4.7 stable, GDScript, no image assets. Tests are `SceneTree` scripts run headless.

**Spec:** `docs/superpowers/specs/2026-08-30-player-stats-and-defense-design.md` (revision 5)

## Global Constraints

- **Godot 4.7 stable, GDScript only.** No new dependencies, no image assets.
- **No `Area2D` anywhere.** Entities are packed arrays over a uniform grid.
- **All combat resolves in the ordered nine-step tick** in `scripts/run/run.gd`, never inside a callback.
- **`scripts/build/` is pure** — no scene tree, no globals, no `Engine` access.
- **Ward and `lifesteal` magnitudes are MAX, never sum** — within an exploit (`maxf` in `Compiler._fold`) and across exploits (max over live timers).
- **Sustain/healing is OUT OF SCOPE.** No new healing. `keylog` is unchanged. Four heal designs failed review; see spec §11.
- Test command form: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/<name>.gd`
- **Baseline (verified before this plan):** all nine suites PASS — `test_build`, `test_drain`, `test_corruption`, `test_meta`, `test_run`, `test_slots`, `test_triggers`, `test_worms`, `test_dispatch`.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `scripts/build/player_stats.gd` | **New.** Base sheet values, `mitigate()`, sheet merge. Pure. | 2 |
| `scripts/meta/save_game.gd` | Eight buffs; `player_sheet()` / `multipliers()` split; VERSION 2 | 1, 3 |
| `scripts/build/module.gd` | `STAT_KEYS` 11 → 16 | 5 |
| `scripts/build/resolved_exploit.gd` | Five ward/travel fields + `base_cooldown` + `equals` | 5 |
| `scripts/build/compiler.gd` | `mult` param, `buffs` deleted, `maxf` fold, rank carve-outs | 4, 5 |
| `scripts/build/loadout.gd` | `mult` field replacing `buffs` | 4 |
| `data/module_table.gd` | Three defensive modules, `packet.travel` | 8, 9 |
| `scripts/run/run.gd` | Sheet consumers, ward timers, `_damage_player` order, `_proj_dist_left` | 4, 6, 7, 9 |
| `scripts/meta/meta_screen.gd` | Eight rows in a bounded ScrollContainer | 10 |
| `scripts/run/ui.gd` | Effective max integrity, warn threshold, armor/defense readout | 11 |

---

### Task 1: Fix the live `buff_stats()` partial-table bug

This is a **shipped bug, not new work**. `buff_stats()` iterates `d["buffs"]` (three names) and direct-indexes `BUFF_EFFECT` (two names), so it throws on `bandwidth` and returns `{}` — silently discarding the `cpu_cycles` and `cooling` contributions it had already accumulated. Any player who has bought one rank of `bandwidth` is playing with no damage or cooldown upgrades. `test_meta` still reports PASS because the assertion after it is a negative that an aborted function satisfies for free.

Fix it first so every later task builds on a working save path.

**Files:**
- Modify: `scripts/meta/save_game.gd:168`
- Modify: `tests/test_meta.gd:69-72`

**Interfaces:**
- Consumes: nothing
- Produces: `SaveGame.buff_stats()` returns a complete Dictionary for any buff combination (still the old two-key shape; Task 3 replaces it)

- [ ] **Step 1: Write the failing test**

Replace the vacuous negative at `tests/test_meta.gd:69-72`. Find the block ending with the `has(&"radius")` assertion and replace that assertion with:

```gdscript
	# bandwidth is a player stat and must not reach the compile path — but the
	# other two buffs must survive being in the same dictionary as it. A direct
	# index into the partial BUFF_EFFECT table used to throw here and return {},
	# silently wiping cpu_cycles and cooling for anyone who owned bandwidth.
	SaveGame.load_state()["buffs"]["bandwidth"] = 3
	var with_bw := SaveGame.buff_stats()
	_check("bandwidth does not wipe cpu_cycles", with_bw.get(&"damage", 0.0) > 0.0, true)
	_check("bandwidth does not wipe cooling", with_bw.get(&"cooldown", 0.0) < 0.0, true)
	_check("bandwidth contributes no exploit stat", with_bw.has(&"pickup_radius"), false)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_meta.gd`

Expected: `FAIL` on "bandwidth does not wipe cpu_cycles" and "bandwidth does not wipe cooling", preceded by `SCRIPT ERROR: Invalid access to property or key 'bandwidth' ... at: buff_stats (res://scripts/meta/save_game.gd:168)`.

- [ ] **Step 3: Fix the direct index**

In `scripts/meta/save_game.gd`, change the body of `buff_stats()`:

```gdscript
static func buff_stats() -> Dictionary:
	var d := load_state()
	var out := {}
	for name in d["buffs"]:
		var n: int = d["buffs"][name]
		if n <= 0:
			continue
		# .get, not a direct index: d["buffs"] is seeded from _default() and can
		# legitimately hold names BUFF_EFFECT has no entry for (every player
		# stat). A direct index threw and aborted the whole fold.
		var eff: Dictionary = BUFF_EFFECT.get(name, {})
		for k in eff:
			out[k] = out.get(k, 0.0) + eff[k] * n
	return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_meta.gd`

Expected: `PASS — all cases`, and **no** `SCRIPT ERROR` line in the output.

- [ ] **Step 5: Commit**

```bash
git add scripts/meta/save_game.gd tests/test_meta.gd
git commit -m "fix: buff_stats aborted on any buff missing from BUFF_EFFECT

Iterating d[\"buffs\"] while direct-indexing the partial BUFF_EFFECT table
threw on 'bandwidth' and returned {}, discarding the cpu_cycles and cooling
contributions already accumulated. The suite passed because the assertion
after it was a negative an aborted function satisfies for free."
```

---

### Task 2: `PlayerStats` — the sheet and the mitigation formula

**Files:**
- Create: `scripts/build/player_stats.gd`
- Create: `tests/test_player_stats.gd`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `PlayerStats.BASE: Dictionary` — `integrity` 100.0, `armor` 0.0, `defense` 0.0, `clock_speed` 220.0, `pickup_radius` 30.0
  - `PlayerStats.BASE_MULT: Dictionary` — `attack` 1.0, `haste` 1.0, `reach` 1.0
  - `PlayerStats.mitigate(incoming: float, armor: float, defense: float) -> float`
  - `PlayerStats.sheet(deltas: Dictionary) -> Dictionary`
  - `PlayerStats.mults(deltas: Dictionary) -> Dictionary`

- [ ] **Step 1: Write the failing test**

Create `tests/test_player_stats.gd`:

```gdscript
extends SceneTree

var failures := 0

func _init() -> void:
	print("ROOTKIT — player stats\n")
	identity()
	armor_floor()
	defense_curve()
	composed()
	hostile_inputs()
	sheet_merge()
	print("")
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want or (got is float and want is float and abs(got - want) < 1e-5):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

## An unbuffed run must behave exactly as it does today.
func identity() -> void:
	for raw in [5.0, 7.0, 12.0, 22.0]:
		_check("identity at 0/0 for %.0f" % raw, PlayerStats.mitigate(raw, 0.0, 0.0), raw)

## The worm row is the tie point: 5 - 4 == 5 * 0.2 == 1.0. It is the first
## place ARMOR_FLOOR engages, and the row an earlier spec draft got wrong.
func armor_floor() -> void:
	_check("worm 5 at armor 4", PlayerStats.mitigate(5.0, 4.0, 0.0), 1.0)
	_check("daemon 7 at armor 4", PlayerStats.mitigate(7.0, 4.0, 0.0), 3.0)
	_check("firewall 12 at armor 4", PlayerStats.mitigate(12.0, 4.0, 0.0), 8.0)
	_check("ICE 22 at armor 4", PlayerStats.mitigate(22.0, 4.0, 0.0), 18.0)
	# Armor far exceeding the hit floors at 20%, never zero.
	_check("armor 999 floors at 20%", PlayerStats.mitigate(22.0, 999.0, 0.0), 4.4)

## d/(d+K) is asymptotic to 1 and never reaches it.
func defense_curve() -> void:
	_check("defense 0 = no cut", PlayerStats.mitigate(100.0, 0.0, 0.0), 100.0)
	_check("defense K = 50% cut", PlayerStats.mitigate(100.0, 0.0, 60.0), 50.0)
	_check("defense 10K = 90.9% cut", PlayerStats.mitigate(100.0, 0.0, 600.0), 9.090909)
	_check("defense never reaches 0 damage",
		PlayerStats.mitigate(100.0, 0.0, 1.0e9) > 0.0, true)

## Armor first, then defense — the documented order.
func composed() -> void:
	_check("worm 5 at armor 4 / defense 60", PlayerStats.mitigate(5.0, 4.0, 60.0), 0.5)
	_check("ICE 22 at armor 12 / defense 110",
		PlayerStats.mitigate(22.0, 12.0, 110.0), 3.529412)

## user://save.json is user-editable. At defense == -60 the denominator is 0.0
## and GDScript float division yields INF rather than erroring.
func hostile_inputs() -> void:
	_check("negative defense clamps to identity",
		PlayerStats.mitigate(10.0, 0.0, -60.0), 10.0)
	_check("very negative defense clamps to identity",
		PlayerStats.mitigate(10.0, 0.0, -1000.0), 10.0)
	_check("negative armor clamps to identity",
		PlayerStats.mitigate(10.0, -50.0, 0.0), 10.0)

func sheet_merge() -> void:
	var s := PlayerStats.sheet({&"integrity": 80.0, &"armor": 6.0})
	_check("sheet adds integrity", s[&"integrity"], 180.0)
	_check("sheet adds armor", s[&"armor"], 6.0)
	_check("sheet keeps untouched base", s[&"clock_speed"], 220.0)
	_check("sheet ignores unknown keys",
		PlayerStats.sheet({&"nonsense": 5.0}).has(&"nonsense"), false)
	var m := PlayerStats.mults({&"attack": 0.4, &"haste": -0.3})
	_check("mults add attack", m[&"attack"], 1.4)
	_check("mults add haste", m[&"haste"], 0.7)
	_check("mults keep untouched base", m[&"reach"], 1.0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_player_stats.gd`

Expected: a parse error — `Identifier "PlayerStats" not declared in the current scope`.

- [ ] **Step 3: Write the implementation**

Create `scripts/build/player_stats.gd`:

```gdscript
class_name PlayerStats extends RefCounted

## The player's own stats, kept separate from ResolvedExploit's weapon stats.
## Pure: no scene tree, no globals — same discipline as the rest of scripts/build.
##
## Two groups. The additive sheet (integrity/armor/defense/clock_speed/
## pickup_radius) is read directly by run.gd and never reaches the compiler.
## The multipliers (attack/haste/reach) are folded into every exploit by
## Compiler.build AFTER the flat module fold, so a module's "+7 damage" stays a
## flat number and the player layer is the percentage layer.

const BASE := {
	&"integrity": 100.0,
	&"armor": 0.0,
	&"defense": 0.0,
	&"clock_speed": 220.0,
	&"pickup_radius": 30.0,
}

const BASE_MULT := {
	&"attack": 1.0,
	&"haste": 1.0,
	&"reach": 1.0,
}

## armor never blocks more than 80% of a hit, so no stack makes a hit free.
const ARMOR_FLOOR := 0.2
## the defense value at which reduction is exactly 50%.
const DEFENSE_K := 60.0

## Armor subtracts flat (floored), then defense cuts a percentage with
## diminishing returns. Bounded by shape rather than by clamp: the floor stops
## armor zeroing a hit, and d/(d+K) is asymptotic to 1 and never reaches it.
##
## The two maxf(0.0, ...) guards are load-bearing, not habit. save.json is
## user-editable, and at defense == -60 the denominator is 0.0 — GDScript float
## division yields INF rather than erroring, so a hostile file would silently
## produce nonsense instead of failing loudly.
static func mitigate(incoming: float, armor: float, defense: float) -> float:
	var a := maxf(0.0, armor)
	var d := maxf(0.0, defense)
	return maxf(incoming * ARMOR_FLOOR, incoming - a) * (1.0 - d / (d + DEFENSE_K))

## BASE plus meta deltas. Unknown keys are dropped rather than added, so a stale
## save cannot invent a stat.
static func sheet(deltas: Dictionary = {}) -> Dictionary:
	var out := BASE.duplicate()
	for k in deltas:
		if out.has(k):
			out[k] = float(out[k]) + float(deltas[k])
	return out

static func mults(deltas: Dictionary = {}) -> Dictionary:
	var out := BASE_MULT.duplicate()
	for k in deltas:
		if out.has(k):
			out[k] = float(out[k]) + float(deltas[k])
	return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_player_stats.gd`

Expected: `PASS — all cases`.

- [ ] **Step 5: Commit**

```bash
git add scripts/build/player_stats.gd tests/test_player_stats.gd
git commit -m "feat: PlayerStats — base sheet and the mitigation formula"
```

---

### Task 3: `save_game.gd` v2 — eight buffs, `player_sheet()` / `multipliers()`

**Files:**
- Modify: `scripts/meta/save_game.gd` (`VERSION`, `_default`, `BUFF_EFFECT` → two tables, doc comment at `:22-27`)
- Modify: `tests/test_meta.gd` (`:38-39` cost total, `:76` unlocked count stays for now, buff assertions)

**Interfaces:**
- Consumes: `PlayerStats.BASE` key names (Task 2)
- Produces:
  - `SaveGame.player_sheet() -> Dictionary` — additive **deltas** keyed by `integrity`/`armor`/`defense`/`clock_speed`/`pickup_radius`
  - `SaveGame.multipliers() -> Dictionary` — additive **deltas** keyed by `attack`/`haste`/`reach` (rank 10 `cpu_cycles` yields `0.40`, **not** `1.40`)

> **Contract:** both functions return deltas, never absolutes. `PlayerStats.sheet()` and `PlayerStats.mults()` are the converters — `Compiler` multiplies by what it is handed, so passing a raw `0.40` would scale damage *down* by 60%. Always wrap: `PlayerStats.mults(SaveGame.multipliers())`.
  - `SaveGame.VERSION == 2`
  - `buff_stats()` and `pickup_bonus()` are **removed**

- [ ] **Step 1: Write the failing test**

In `tests/test_meta.gd`, replace the whole `buffs_fold_into_compile` function (the block spanning roughly `:57-72`, which calls `Compiler.build(ex, SaveGame.buff_stats())`) with:

```gdscript
## Every one of the eight shop lines must produce a value, positively asserted.
## The previous version of this test asserted only that a key was ABSENT, which
## an aborted function satisfies for free — that is how the save_game.gd:168
## bug survived.
func buffs_split_into_sheet_and_mults() -> void:
	for name in ["cpu_cycles", "cooling", "memory", "firewall",
			"encryption", "bus_speed", "addressing", "bandwidth"]:
		SaveGame.load_state()["buffs"][name] = 0

	SaveGame.load_state()["buffs"]["cpu_cycles"] = 10
	SaveGame.load_state()["buffs"]["cooling"] = 10
	SaveGame.load_state()["buffs"]["memory"] = 10
	SaveGame.load_state()["buffs"]["firewall"] = 10
	SaveGame.load_state()["buffs"]["encryption"] = 10
	SaveGame.load_state()["buffs"]["bus_speed"] = 10
	SaveGame.load_state()["buffs"]["addressing"] = 10
	SaveGame.load_state()["buffs"]["bandwidth"] = 10

	var sheet := SaveGame.player_sheet()
	_check("memory     -> integrity +80",     sheet.get(&"integrity", 0.0), 80.0)
	_check("firewall   -> armor +6",          sheet.get(&"armor", 0.0), 6.0)
	_check("encryption -> defense +60",       sheet.get(&"defense", 0.0), 60.0)
	_check("bus_speed  -> clock_speed +60",   sheet.get(&"clock_speed", 0.0), 60.0)
	_check("bandwidth  -> pickup_radius +60", sheet.get(&"pickup_radius", 0.0), 60.0)

	var mult := SaveGame.multipliers()
	_check("cpu_cycles -> attack +0.40", mult.get(&"attack", 0.0), 0.40)
	_check("cooling    -> haste -0.30",  mult.get(&"haste", 0.0), -0.30)
	_check("addressing -> reach +0.30",  mult.get(&"reach", 0.0), 0.30)

	# The two namespaces never leak into each other.
	_check("sheet carries no multiplier", sheet.has(&"attack"), false)
	_check("mults carry no player stat",  mult.has(&"integrity"), false)

	for name in ["cpu_cycles", "cooling", "memory", "firewall",
			"encryption", "bus_speed", "addressing", "bandwidth"]:
		SaveGame.load_state()["buffs"][name] = 0
```

Register it in `_init()` in place of the old `buffs_fold_into_compile()` call, and change the shop-cost assertion at `:39` from `total * 3` / `5850` to:

```gdscript
	_check("all eight lines cost 15600", total * 8, 15600)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_meta.gd`

Expected: parse or runtime failure — `Invalid call. Nonexistent function 'player_sheet' in base 'SaveGame'`.

- [ ] **Step 3: Write the implementation**

In `scripts/meta/save_game.gd`:

Bump the version and replace the effect table and the doc comment above it:

```gdscript
const VERSION := 2

## Two tables, because the two namespaces are read at different times and by
## different code. SHEET_EFFECT is additive player stats, read directly by
## run.gd and never passed to the compiler. MULT_EFFECT is multiplicative
## exploit scalars, folded by Compiler.build after the flat module fold.
##
## An earlier version mapped "bandwidth" to &"radius" — the exploit's effect
## radius — so the shop sold pickup range for up to 1950 salvage and delivered
## something else entirely, and delivered nothing at all to a packet build,
## whose vector ignores r.radius. That bug is what the split prevents
## structurally: a player stat has nowhere to land in the exploit namespace.
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
```

Delete the old `BUFF_EFFECT` const and the `PICKUP_PER_RANK` const.

Extend `_default()` so its `buffs` dictionary holds all eight names — `_sanitise` iterates `out["buffs"]`, so any name missing here is silently dropped on every load/save round-trip:

```gdscript
		"buffs": {
			"cpu_cycles": 0, "cooling": 0, "memory": 0, "firewall": 0,
			"encryption": 0, "bus_speed": 0, "addressing": 0, "bandwidth": 0,
		},
```

Replace `buff_stats()` (kept working by Task 1) and `pickup_bonus()` with the split pair:

```gdscript
static func player_sheet() -> Dictionary:
	return _fold(SHEET_EFFECT)

static func multipliers() -> Dictionary:
	return _fold(MULT_EFFECT)

## .get, not a direct index: d["buffs"] holds all eight names while each table
## holds only its own subset. A direct index threw and aborted the fold, which
## is exactly the shipped bug this file carried until recently.
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_meta.gd`

Expected: `PASS — all cases`.

Then confirm a v1 save still loads (the migration path). `_read` quarantines only files *newer* than `VERSION`, and `_sanitise` starts from `_default()` and pulls old ranks through `.get(k, 0)`:

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_meta.gd`
Expected: the existing durability/migration cases still print `ok`.

- [ ] **Step 5: Commit**

```bash
git add scripts/meta/save_game.gd tests/test_meta.gd
git commit -m "feat: split the shop into player_sheet() and multipliers(), VERSION 2

cpu_cycles and cooling change meaning from flat damage/cooldown to
multipliers; five new lines cover the player stat sheet. All eight names go
into _default()['buffs'] or _sanitise drops them on every round-trip."
```

---

### Task 4: Multipliers reach combat — `Compiler`, `Loadout`, `run.gd:182`

**This is the task the review panel caught three times.** `Loadout.compile_all` is the only runtime caller of `Compiler.build`. If `loadout.gd` is not changed, the multipliers compile to nothing and three shop lines sell for up to 5,850 salvage and do nothing — and every test that calls `Compiler.build` **directly** still passes. The wiring test in Step 1 goes through `run._recompile()` for exactly that reason. Do not replace it with a direct-compiler test.

**Files:**
- Modify: `scripts/build/compiler.gd` (signature, `buffs` fold deleted, `mult` applied, `base_cooldown`)
- Modify: `scripts/build/resolved_exploit.gd` (`base_cooldown` field + `equals`)
- Modify: `scripts/build/loadout.gd:34` (`buffs` → `mult`), `:217-221` (`compile_all`)
- Modify: `scripts/run/run.gd:182`
- Create: `tests/test_multipliers.gd`
- Modify: `tests/test_build.gd` (any `Compiler.build(ex, <dict>)` call sites)

**Interfaces:**
- Consumes: `SaveGame.multipliers()` (Task 3)
- Produces:
  - `Compiler.build(ex: Exploit, mult: Dictionary = {}) -> ResolvedExploit`
  - `Compiler.MULT_KEYS: Dictionary` — multiplier name → array of scaled stat keys
  - `Loadout.mult: Dictionary`
  - `ResolvedExploit.base_cooldown: float`

- [ ] **Step 1: Write the failing test**

Create `tests/test_multipliers.gd`:

```gdscript
extends SceneTree

## Every assertion here that matters goes through run._recompile(), not
## Compiler.build directly. Loadout.compile_all is the only runtime caller of
## the compiler, and a plan that changed the compiler without changing the
## loadout would leave three shop lines inert while every direct-compiler test
## stayed green. That failure mode is the reason this file exists.

const DT := 1.0 / 60.0
var failures := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	print("ROOTKIT — global multipliers\n")
	await process_frame
	await attack_reaches_combat()
	await haste_reaches_combat()
	corruption_scales()
	exclusions_hold()
	haste_before_clamp()
	print("")
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want or (got is float and want is float and abs(got - want) < 1e-5):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _clear_buffs() -> void:
	for name in ["cpu_cycles", "cooling", "memory", "firewall",
			"encryption", "bus_speed", "addressing", "bandwidth"]:
		SaveGame.load_state()["buffs"][name] = 0

## THE wiring test: set a rank, build a run, recompile, and assert the compiled
## damage actually moved. Fails loudly if loadout.gd never learned about mult.
func attack_reaches_combat() -> void:
	_clear_buffs()
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	var before: float = run.resolved[0].damage

	SaveGame.load_state()["buffs"]["cpu_cycles"] = 10
	run.loadout.mult = PlayerStats.mults(SaveGame.multipliers())
	run._recompile()
	var after: float = run.resolved[0].damage

	_check("attack x1.40 reaches the compiled exploit", after, before * 1.40)
	_clear_buffs()
	run.queue_free()
	await process_frame

func haste_reaches_combat() -> void:
	_clear_buffs()
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	var before: float = run.resolved[0].cooldown

	SaveGame.load_state()["buffs"]["cooling"] = 10
	run.loadout.mult = PlayerStats.mults(SaveGame.multipliers())
	run._recompile()
	var after: float = run.resolved[0].cooldown

	_check("haste x0.70 reaches the compiled exploit", after, before * 0.70)
	_clear_buffs()
	run.queue_free()
	await process_frame

## corruption is a damage type. If attack scaled only damage, the game's
## headline offensive stat would be dead weight to a corruption build — the
## same "legal to buy, silently inert" failure the bandwidth bug was.
func corruption_scales() -> void:
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"broadcast"]); ex.place(t[&"interval"]); ex.place(t[&"corrupt"])
	var base := Compiler.build(ex)
	var buffed := Compiler.build(ex, {&"attack": 2.0})
	_check("attack scales damage", buffed.damage, base.damage * 2.0)
	_check("attack scales corruption", buffed.corruption, base.corruption * 2.0)

## The exclusion list is an invariant, not a comment. A future refactor that
## loops over STAT_KEYS would silently scale projectile_speed past its cap.
func exclusions_hold() -> void:
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"packet"]); ex.place(t[&"interval"]); ex.place(t[&"botnet_expand"])
	var base := Compiler.build(ex)
	var buffed := Compiler.build(ex, {&"attack": 3.0, &"haste": 3.0, &"reach": 3.0})
	_check("pierce untouched", buffed.pierce, base.pierce)
	_check("chain_count untouched", buffed.chain_count, base.chain_count)
	_check("projectile_speed untouched", buffed.projectile_speed, base.projectile_speed)
	_check("botnet_cap untouched", buffed.botnet_cap, base.botnet_cap)
	_check("lifesteal untouched", buffed.lifesteal, base.lifesteal)

## haste multiplies BEFORE MIN_COOLDOWN. At the extremes the clamp hides the
## ordering entirely, so this uses a mid-range cooldown where it is observable.
func haste_before_clamp() -> void:
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"packet"]); ex.place(t[&"interval"])   # 0.50 - 0.10 = 0.40
	var base := Compiler.build(ex)
	_check("mid-range cooldown is above the clamp", base.cooldown > Compiler.MIN_COOLDOWN, true)
	var fast := Compiler.build(ex, {&"haste": 0.5})
	_check("haste halves a mid-range cooldown", fast.cooldown, base.cooldown * 0.5)
	_check("haste never breaches MIN_COOLDOWN",
		Compiler.build(ex, {&"haste": 0.001}).cooldown, Compiler.MIN_COOLDOWN)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_multipliers.gd`

Expected: `FAIL` on "attack x1.40 reaches the compiled exploit" (the value does not move), or a runtime error on `run.loadout.mult` not existing.

- [ ] **Step 3: Write the implementation**

In `scripts/build/resolved_exploit.gd`, add the field beside `cooldown`:

```gdscript
## The folded cooldown BEFORE haste and before MIN_COOLDOWN. MIN_COOLDOWN is the
## one clamp that destroys information — a cooldown clamped to 0.05 cannot be
## reconstructed — so a future runtime modifier would otherwise have to dismantle
## "compile once, combat reads flat values". damage and radius are unclamped and
## reversible by division, so they need no equivalent.
## May be NEGATIVE: broadcast + interval r5 + overclock r5 folds to -0.25. Any
## consumer must clamp before multiplying, or a multiplier makes it LESS negative.
var base_cooldown: float = 0.0
```

and add `base_cooldown` to the `equals()` comparison chain.

In `scripts/build/compiler.gd`, change the signature and body:

```gdscript
## Which multiplier scales which stats. Total and non-overlapping over the stat
## keys: everything not named here is deliberately excluded.
##   - lifesteal is excluded so attack is not also the best defensive stat.
##   - projectile_speed is excluded because its cap prevents tunnelling through
##     the smallest combined radius; a multiplier before the cap would silently
##     do nothing at high values.
const MULT_KEYS := {
	&"attack": [&"damage", &"corruption"],
	&"haste":  [&"cooldown"],
	&"reach":  [&"radius", &"travel"],
}

static func build(ex: Exploit, mult: Dictionary = {}) -> ResolvedExploit:
```

Delete the `for k in buffs:` additive fold block. After the last `_fold` call and **before** the clamps, insert:

```gdscript
	# Captured pre-multiplier, pre-clamp. See ResolvedExploit.base_cooldown.
	r.base_cooldown = r.cooldown

	for mk in MULT_KEYS:
		var f := float(mult.get(mk, 1.0))
		if f == 1.0:
			continue
		for sk in MULT_KEYS[mk]:
			r.set(sk, r.get(sk) * f)
```

In `scripts/build/loadout.gd`, rename the field at `:34` and update `compile_all`:

```gdscript
var mult: Dictionary = {}
```

```gdscript
func compile_all() -> Array:
	var out := []
	for ex in exploits:
		out.append(Compiler.build(ex, mult))
	return out
```

In `scripts/run/run.gd:182`, change the assignment:

```gdscript
	loadout.mult = PlayerStats.mults(SaveGame.multipliers())
```

In `tests/test_build.gd`, update any `Compiler.build(ex, <something>)` call that passed a buffs dictionary — the second argument is now `mult`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_multipliers.gd`
Expected: `PASS — all cases`.

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_build.gd`
Expected: `PASS — all cases`.

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_meta.gd`
Expected: `PASS — all cases`.

- [ ] **Step 5: Commit**

```bash
git add scripts/build/compiler.gd scripts/build/resolved_exploit.gd \
        scripts/build/loadout.gd scripts/run/run.gd \
        tests/test_multipliers.gd tests/test_build.gd
git commit -m "feat: global attack/haste/reach multipliers, wired through Loadout

Compiler.build's buffs parameter is deleted and replaced by mult, applied
after the flat fold and before the clamps. loadout.gd carries it; run.gd:182
feeds it from SaveGame.multipliers(). test_multipliers.gd asserts through
run._recompile() rather than Compiler.build, because a compiler-only test
passes even when the loadout never learned about the parameter."
```

---

### Task 5: Ward stat keys, the `maxf` fold, and the rank carve-outs

**Files:**
- Modify: `scripts/build/module.gd` (`STAT_KEYS` 11 → 16)
- Modify: `scripts/build/resolved_exploit.gd` (five fields + `equals`)
- Modify: `scripts/build/compiler.gd` (`_fold` scale rules and `maxf` accumulation)
- Modify: `tests/test_build.gd`

**Interfaces:**
- Consumes: `Compiler.MULT_KEYS` (Task 4)
- Produces:
  - `ResolvedExploit.ward_armor`, `.ward_defense`, `.ward_clock_speed`, `.ward_duration`, `.travel` — all `float`
  - `Compiler.MAX_FOLD_KEYS: Array[StringName]`

- [ ] **Step 1: Write the failing test**

Add to `tests/test_build.gd` and register both in `_init()`:

```gdscript
## Ward magnitudes are MAX, never sum — including within a single exploit.
## Compiler._fold accumulates with +, and legal_targets offers an EMPTY_SLOT for
## payload slot 1 regardless of what slot 0 holds (loadout.gd:76-79, and
## loadout.gd:81-83 states ranks are per SLOT, not per module). So the same ward
## module in both payload slots of one exploit is a legal build, and summing it
## would double the magnitude at zero uptime cost.
func ward_folds_by_max() -> void:
	var one := _mk(&"broadcast", &"interval", [&"sandbox"])
	var two := _mk(&"broadcast", &"interval", [&"sandbox", &"sandbox"])
	var mag: float = T[&"sandbox"].stats[&"ward_defense"]
	_check("one sandbox folds to its magnitude", Compiler.build(one).ward_defense, mag)
	_check("two sandbox in one exploit take the max",
		Compiler.build(two).ward_defense, mag)

	# Two DIFFERENT wards in one exploit share the longer duration, because
	# ward_duration is maxf-folded too and the timer is per-exploit.
	var mixed := _mk(&"broadcast", &"interval", [&"harden", &"sandbox"])
	var r := Compiler.build(mixed)
	_check("mixed wards keep both magnitudes",
		r.ward_armor > 0.0 and r.ward_defense > 0.0, true)
	_check("mixed wards share the longer duration", r.ward_duration,
		maxf(T[&"harden"].stats[&"ward_duration"], T[&"sandbox"].stats[&"ward_duration"]))

	# lifesteal joins the same rule: keylog is the fifth defensive module.
	var ks := _mk(&"broadcast", &"interval", [&"keylog", &"keylog"])
	_check("two keylog take the max", Compiler.build(ks).lifesteal,
		float(T[&"keylog"].stats[&"lifesteal"]))

## Rank buys ward MAGNITUDE, never uptime, and never packet range. A vector's
## cadence already has this carve-out (compiler.gd) on the same principle.
func rank_carve_outs() -> void:
	var ex := _mk(&"broadcast", &"interval", [&"sandbox"])
	ex.payloads[0].rank = 5
	var r := Compiler.build(ex)
	_check("ward magnitude rank-scales", r.ward_defense,
		float(T[&"sandbox"].stats[&"ward_defense"]) * 5.0)
	_check("ward_duration does NOT rank-scale", r.ward_duration,
		float(T[&"sandbox"].stats[&"ward_duration"]))

	var pk := _mk(&"packet", &"interval")
	pk.vector.rank = 5
	_check("vector travel does NOT rank-scale", Compiler.build(pk).travel,
		float(T[&"packet"].stats[&"travel"]))

## equals must cover the new fields or the permutation test passes on builds
## that differ only in a ward.
func ward_equality() -> void:
	var a := Compiler.build(_mk(&"broadcast", &"interval", [&"harden"]))
	var b := Compiler.build(_mk(&"broadcast", &"interval", [&"sandbox"]))
	_check("equals distinguishes ward-only differences", a.equals(b), false)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_build.gd`

Expected: failures referencing `ward_defense` / `travel` not existing on `ResolvedExploit`, and `T[&"sandbox"]` being null (the modules land in Task 8 — that is expected; this task delivers the machinery and Task 8 delivers the data).

To keep this task independently testable, add the three modules' **stat entries only** as part of Step 3 below; Task 8 adds their unlock/count/doc bookkeeping.

- [ ] **Step 3: Write the implementation**

In `scripts/build/module.gd`, extend `STAT_KEYS`:

```gdscript
const STAT_KEYS := [
	&"damage", &"corruption", &"lifesteal", &"cooldown", &"radius",
	&"pierce", &"chain_count", &"projectile_speed",
	&"botnet_cap", &"botnet_lifetime", &"botnet_damage_ratio",
	&"ward_armor", &"ward_defense", &"ward_clock_speed", &"ward_duration",
	&"travel",
]
```

In `scripts/build/resolved_exploit.gd`, add the five fields and extend `equals()` to compare all of them:

```gdscript
## Defensive contributions. A ward arms a per-exploit timer on fire; while that
## timer is live these add to the player's effective stats, taken as a MAX
## across exploits rather than a sum.
var ward_armor: float = 0.0
var ward_defense: float = 0.0
var ward_clock_speed: float = 0.0
var ward_duration: float = 0.0

## PACKET only: how far a projectile flies before it expires. Separate from
## radius, which already means "effect radius" to BROADCAST/CHAIN/BEAM and which
## fork_bomb contributes 60.0 of — overloading it would let an unrelated payload
## silently change a packet's flight distance.
var travel: float = 0.0
```

In `scripts/build/compiler.gd`, add the max-fold list and rewrite the accumulation inside `_fold`:

```gdscript
## Defensive magnitudes accumulate by MAX, not by +. The same module is legal in
## both payload slots of one exploit (loadout.gd:76-79), so summing would buy
## double magnitude at zero uptime cost — the opposite of what a second copy
## should be worth.
const MAX_FOLD_KEYS := [
	&"ward_armor", &"ward_defense", &"ward_clock_speed", &"ward_duration",
	&"lifesteal",
]
```

```gdscript
		var scale: int = em.rank
		if is_vector and (key == &"cooldown" or key == &"travel"):
			# A vector's cadence and its range are base properties, not scaling
			# stats. travel especially: at em.rank a rank-3 packet would fly
			# 1920px, and the stat would stop meaning anything bounded.
			scale = 1
		elif key == &"ward_duration":
			# Rank buys ward magnitude, never uptime.
			scale = 1
		var v := float(m.stats[key]) * scale
		if key in MAX_FOLD_KEYS:
			r.set(key, maxf(r.get(key), v))
		else:
			r.set(key, r.get(key) + v)
```

In `data/module_table.gd`, add the three module rows to `all()` (Task 8 handles counts, unlocks and the doc comment):

```gdscript
		Module.make(&"harden", "harden", S.PAYLOAD,
			{&"ward_armor": 1.2, &"ward_duration": 2.0}),
		Module.make(&"sandbox", "sandbox", S.PAYLOAD,
			{&"ward_defense": 10.0, &"ward_duration": 3.0}),
		Module.make(&"nice", "nice()", S.PAYLOAD,
			{&"ward_clock_speed": 12.0, &"ward_duration": 1.5}),
```

and add `travel` to the packet vector:

```gdscript
		Module.make(&"packet", "packet()", S.VECTOR,
			{&"damage": 9.0, &"projectile_speed": 420.0, &"cooldown": 0.5,
			 &"travel": 640.0}, [], V.PACKET),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_build.gd`

Expected: the three new cases print `ok`. The two hardcoded count assertions at `:47-48` now FAIL (15 vs 18) — that is expected and Task 8 fixes them. Every other case passes.

- [ ] **Step 5: Commit**

```bash
git add scripts/build/module.gd scripts/build/resolved_exploit.gd \
        scripts/build/compiler.gd data/module_table.gd tests/test_build.gd
git commit -m "feat: ward stat keys, maxf folding, and the rank carve-outs

ward_* and lifesteal accumulate by max rather than +, because the same module
is legal in both payload slots of one exploit. ward_duration and a vector's
travel do not rank-scale, on the same principle as a vector's cooldown."
```

---

### Task 6: The stat sheet reaches `run.gd`

**Files:**
- Modify: `scripts/run/run.gd:56-59` (delete three constants), `:83`, `:96`, `:182-183`, `:330`, `:670`
- Create: `tests/test_player_sheet.gd`

**Interfaces:**
- Consumes: `PlayerStats.sheet()` (Task 2), `SaveGame.player_sheet()` (Task 3)
- Produces:
  - `run._sheet: Dictionary` — the merged base + meta sheet, seeded in `_ready`
  - `run._eff_integrity() -> float`

- [ ] **Step 1: Write the failing test**

Create `tests/test_player_sheet.gd`:

```gdscript
extends SceneTree

## run.gd:83 seeds player_health from a CONSTANT at declaration time, which is
## evaluated before _ready() reads the save. Miss the re-seed and every run
## starts at 100 regardless of how much memory the player bought — 1,950 salvage
## that silently does nothing.

const DT := 1.0 / 60.0
var failures := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	print("ROOTKIT — player sheet\n")
	await process_frame
	await integrity_seeded()
	await clock_speed_from_meta()
	print("")
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want or (got is float and want is float and abs(got - want) < 1e-5):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _clear_buffs() -> void:
	for name in ["cpu_cycles", "cooling", "memory", "firewall",
			"encryption", "bus_speed", "addressing", "bandwidth"]:
		SaveGame.load_state()["buffs"][name] = 0

func integrity_seeded() -> void:
	_clear_buffs()
	SaveGame.load_state()["buffs"]["memory"] = 10
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	_check("memory r10 starts the run at 180", run.player_health, 180.0)
	_check("effective max integrity is 180", run._eff_integrity(), 180.0)
	_clear_buffs()
	run.queue_free()
	await process_frame

## bus_speed feeds clock_speed through player_sheet(), a DIFFERENT source from
## the ward path. Both terminate at run.gd:330 and both need an assertion.
func clock_speed_from_meta() -> void:
	_clear_buffs()
	var slow := await _distance_travelled()
	SaveGame.load_state()["buffs"]["bus_speed"] = 10
	var fast := await _distance_travelled()
	_check("bus_speed r10 moves the player farther", fast > slow * 1.2, true)
	_clear_buffs()

func _distance_travelled() -> float:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.director.elapsed = 999.0
	run.director.boss_spawned = true
	while run.enemies.count > 0:
		run.enemies.despawn(run.enemies.count - 1)
	run.input_override = Vector2.RIGHT
	var start: Vector2 = run.player_pos
	for tick in 60:
		run._physics_process(DT)
	var moved: float = run.player_pos.distance_to(start)
	run.queue_free()
	await process_frame
	return moved
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_player_sheet.gd`

Expected: `FAIL  memory r10 starts the run at 180 — got 100, want 180`, or a runtime error on `run._eff_integrity()` not existing.

- [ ] **Step 3: Write the implementation**

In `scripts/run/run.gd`, delete the three constants `PLAYER_MAX_HEALTH`, `PLAYER_SPEED` and `PICKUP_RADIUS` (leave `IFRAMES` and `PLAYER_RADIUS` alone), then:

Declare the sheet beside `player_health`:

```gdscript
var _sheet: Dictionary = PlayerStats.BASE.duplicate()
var player_pos := Vector2.ZERO
var player_health := 0.0      # seeded from _sheet in _ready
```

and change `var pickup_radius := PICKUP_RADIUS` to `var pickup_radius := 0.0`.

In `_ready`, replace the two save-reading lines (`:182-183`) with:

```gdscript
	loadout.mult = PlayerStats.mults(SaveGame.multipliers())
	# The sheet must be merged and player_health re-seeded HERE. Both are
	# declaration initialisers, evaluated before _ready runs, so a player with
	# memory ranks would otherwise start every run at the base 100.
	_sheet = PlayerStats.sheet(SaveGame.player_sheet())
	player_health = _sheet[&"integrity"]
	pickup_radius = _sheet[&"pickup_radius"]
```

Add the accessor (ward terms arrive in Task 7):

```gdscript
func _eff_integrity() -> float:
	return _sheet[&"integrity"]
```

At `:330`, replace `PLAYER_SPEED` with the sheet value:

```gdscript
		player_pos += world_dir * _sheet[&"clock_speed"] * dt
```

At `:670`, cap lifesteal against the effective maximum rather than the deleted constant:

```gdscript
			player_health = minf(_eff_integrity(), player_health + lifesteal)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_player_sheet.gd`
Expected: `PASS — all cases`.

Run each of `test_run`, `test_triggers`, `test_corruption`, `test_drain`, `test_worms`, `test_dispatch` with the same command form.
Expected: each prints its own PASS line. These all instantiate runs and are the regression surface for this change.

- [ ] **Step 5: Commit**

```bash
git add scripts/run/run.gd tests/test_player_sheet.gd
git commit -m "feat: run.gd reads the player stat sheet instead of three constants

player_health and pickup_radius are declaration initialisers evaluated before
_ready reads the save, so both are re-seeded in _ready. Lifesteal now caps at
effective integrity rather than a hardcoded 100."
```

---

### Task 7: Ward runtime — timers, effective stats, `_damage_player` order

**Files:**
- Modify: `scripts/run/run.gd` (`_ward_left`, `_emit_vector` top, `_step2_integrate`, `_damage_player`)
- Create: `tests/test_wards.gd`

**Interfaces:**
- Consumes: `ResolvedExploit.ward_*` (Task 5), `run._sheet` (Task 6)
- Produces: `run._ward_left: PackedFloat32Array`, `run._eff_armor()`, `run._eff_defense()`, `run._eff_clock_speed()`, `run._mitigated(amount: float) -> float`

- [ ] **Step 1: Write the failing test**

Create `tests/test_wards.gd`:

```gdscript
extends SceneTree

const DT := 1.0 / 60.0
var failures := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	print("ROOTKIT — wards\n")
	await process_frame
	await arms_and_decays()
	await beam_with_no_target_still_wards()
	await max_across_exploits()
	await ward_moves_the_player()
	await absorbs_its_own_hit()
	print("")
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want or (got is float and want is float and abs(got - want) < 1e-5):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _bare_run() -> Node2D:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	run.director.elapsed = 999.0
	run.director.boss_spawned = true
	while run.enemies.count > 0:
		run.enemies.despawn(run.enemies.count - 1)
	return run

func _with(run: Node2D, vector_id: StringName, payloads: Array) -> int:
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[vector_id]); ex.place(t[&"interval"])
	for p in payloads: ex.place(t[p])
	run.loadout.exploits.append(ex)
	run._recompile()
	return run.resolved.size() - 1

func arms_and_decays() -> void:
	var run := await _bare_run()
	var idx := _with(run, &"broadcast", [&"sandbox"])
	var mag: float = run.resolved[idx].ward_defense
	for tick in 120:
		run._physics_process(DT)
	_check("firing arms the ward", run._eff_defense() >= mag, true)
	# Stop it firing and let the timer run out.
	run.resolved[idx].inert = true
	for tick in int(4.0 / DT):
		run._physics_process(DT)
	_check("an expired ward contributes nothing", run._eff_defense(), 0.0)
	run.queue_free()
	await process_frame

## Wards apply at the TOP of _emit_vector, before the match and its early
## returns, so a BEAM with nothing to shoot still hardens. (It spends its
## cooldown either way — _try_event_fire sets _fire_cd before calling
## _emit_vector — so the placement buys the ward, not the cadence.)
func beam_with_no_target_still_wards() -> void:
	var run := await _bare_run()
	# Placed directly from the table, not via unlocked_modules(): unlock state is
	# derived from milestone counters (beam needs 400 kills) and only gates the
	# card OFFER pool, never what a test may construct. test_triggers.gd:13 does
	# the same with on_damage_taken.
	var idx := _with(run, &"beam", [&"harden"])
	for tick in 120:
		run._physics_process(DT)
	_check("targetless beam still wards", run._eff_armor() > 0.0, true)
	run.queue_free()
	await process_frame

## Two exploits carrying the same ward take the MAX, never the sum.
func max_across_exploits() -> void:
	var run := await _bare_run()
	var a := _with(run, &"broadcast", [&"sandbox"])
	var b := _with(run, &"chain", [&"sandbox"])
	var mag: float = run.resolved[a].ward_defense
	for tick in 120:
		run._physics_process(DT)
	_check("two exploits take the max, not the sum", run._eff_defense(), mag)
	run.queue_free()
	await process_frame

## ward_clock_speed must actually reach run.gd:330. bus_speed (Task 6) and nice
## are two different sources into the same read; both need an assertion.
func ward_moves_the_player() -> void:
	var run := await _bare_run()
	_with(run, &"broadcast", [&"nice"])
	run.input_override = Vector2.RIGHT
	var start: Vector2 = run.player_pos
	for tick in 60:
		run._physics_process(DT)
	var warded: float = run.player_pos.distance_to(start)
	var base: float = run._sheet[&"clock_speed"] * 1.0
	_check("nice makes the player faster than base", warded > base * 1.05, true)
	run.queue_free()
	await process_frame

## The reorder's whole point: triggers fire BEFORE damage is applied, so the
## ward is up for the hit that summoned it.
func absorbs_its_own_hit() -> void:
	var run := await _bare_run()
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"broadcast"]); ex.place(t[&"on_damage_taken"]); ex.place(t[&"harden"])
	run.loadout.exploits.append(ex)
	run._recompile()

	var before: float = run.player_health
	run._damage_player(10.0)
	var warded_loss: float = before - run.player_health
	_check("a ward reduces its own triggering hit", warded_loss < 10.0, true)
	_check("the hit is not fully negated", warded_loss > 0.0, true)
	run.queue_free()
	await process_frame
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_wards.gd`

Expected: a runtime error on `run._eff_defense()` not existing.

- [ ] **Step 3: Write the implementation**

In `scripts/run/run.gd`, declare the timer array beside `_fire_cd`:

```gdscript
## One float per exploit. A fire arms it; _step2_integrate decays it. While it is
## live, that exploit's ward_* values count toward the player's effective stats —
## as a MAX across exploits, never a sum.
var _ward_left: PackedFloat32Array
```

and size it in `_ready` alongside `_fire_cd`:

```gdscript
	_ward_left = PackedFloat32Array(); _ward_left.resize(Loadout.MAX_EXPLOITS)
```

At the **top** of `_emit_vector`, before the `match`:

```gdscript
func _emit_vector(ei: int, r: ResolvedExploit) -> void:
	_trigger_fires[ei] = _trigger_fires.get(ei, 0) + 1
	# Before the match, deliberately. BEAM and CHAIN return early when they have
	# no target, and a defensive build on those vectors must still ward — it has
	# already spent its cooldown by the time it gets here.
	if r.ward_duration > 0.0:
		_ward_left[ei] = r.ward_duration
	match r.vector_kind:
```

In `_step2_integrate`, beside the `player_iframe` decay:

```gdscript
	for wi in _ward_left.size():
		if _ward_left[wi] > 0.0:
			_ward_left[wi] -= dt
```

Add the effective-stat accessors next to `_eff_integrity()`:

```gdscript
## Max over live wards, never a sum. The same module is legal in several slots,
## so summing would let a build stack magnitude at no uptime cost.
func _ward_max(key: StringName) -> float:
	var best := 0.0
	for ei in mini(_ward_left.size(), resolved.size()):
		if _ward_left[ei] > 0.0:
			best = maxf(best, float(resolved[ei].get(key)))
	return best

func _eff_armor() -> float:
	return _sheet[&"armor"] + _ward_max(&"ward_armor")

func _eff_defense() -> float:
	return _sheet[&"defense"] + _ward_max(&"ward_defense")

func _eff_clock_speed() -> float:
	return _sheet[&"clock_speed"] + _ward_max(&"ward_clock_speed")

func _mitigated(amount: float) -> float:
	return PlayerStats.mitigate(amount, _eff_armor(), _eff_defense())
```

Change `:330` to read the warded speed:

```gdscript
		player_pos += world_dir * _eff_clock_speed() * dt
```

Rewrite the head of `_damage_player` so triggers run first:

```gdscript
func _damage_player(amount: float) -> void:
	# Triggers BEFORE the subtraction, so an on_damage_taken ward is up for the
	# hit that summoned it rather than the next one. No recursion: the path is
	# _try_event_fire -> _emit_vector -> _hit -> queue.append, and nothing
	# re-enters here.
	for ei in resolved.size():
		var r: ResolvedExploit = resolved[ei]
		if not r.inert and r.trigger_kind == Module.TriggerKind.ON_DAMAGE_TAKEN:
			_try_event_fire(ei, r)
	player_health -= _mitigated(amount)
	player_iframe = IFRAMES
```

and delete the old trigger loop that followed the subtraction. Leave the death check and `emit_signal("stats_changed")` exactly as they are.

- [ ] **Step 4: Run tests to verify they pass**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_wards.gd`
Expected: `PASS — all cases`.

Run `test_triggers`, `test_run`, `test_drain`, `test_corruption` with the same command form.
Expected: each prints its own PASS line. `test_triggers` is the direct regression surface for the `_damage_player` reorder — it asserts every trigger kind fires, including ON_DAMAGE_TAKEN.

- [ ] **Step 5: Commit**

```bash
git add scripts/run/run.gd tests/test_wards.gd
git commit -m "feat: ward timers, effective player stats, and mitigation

Wards arm at the top of _emit_vector so a targetless BEAM/CHAIN still wards.
Effective armor/defense/clock_speed are base + meta + the max live ward.
_damage_player now fires ON_DAMAGE_TAKEN triggers before applying damage, so
a reactive ward absorbs its own triggering hit."
```

---

### Task 8: The three defensive modules become real cards

**Files:**
- Modify: `data/module_table.gd` (doc comment `:11-12`, module ordering)
- Modify: `tests/test_build.gd:47-48` (count 15 → 18)
- Modify: `tests/test_meta.gd:76` (unlocked 12 → 15)

**Interfaces:**
- Consumes: the module rows added in Task 5
- Produces: `ModuleTable.all().size() == 18`, `SaveGame.unlocked_modules().size() == 15`

- [ ] **Step 1: Write the failing test**

Update the two count assertions in `tests/test_build.gd`:

```gdscript
	_check("data sweep: 18 modules, 0 errors", errs.size(), 0)
	_check("data sweep: module count", ModuleTable.all().size(), 18)
```

and the one in `tests/test_meta.gd`:

```gdscript
	_check("fresh save starts with 15 modules", SaveGame.unlocked_modules().size(), 15)
```

Add a defensive-category assertion to `tests/test_build.gd`, registered in `_init()`:

```gdscript
## Four of the fifteen unlocked modules are defensive — the three new wards plus
## keylog, which was always defensive and merely read as an anomaly. The offer
## pool IS the unlocked list: legal_targets offers REPLACE for any occupied slot
## whose occupant is not the last INTERVAL trigger, so a vector is always
## displaceable and nothing is filtered out.
func defensive_share() -> void:
	var defensive := 0
	for m in ModuleTable.starting_unlocked():
		if m.id in [&"harden", &"sandbox", &"nice", &"keylog"]:
			defensive += 1
	_check("four defensive modules unlocked", defensive, 4)
	_check("unlocked total", ModuleTable.starting_unlocked().size(), 15)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_build.gd`

Expected: `FAIL  data sweep: module count — got 18, want 18` passes, but before the doc/ordering fix the `defensive_share` count assertion and the `test_meta` unlocked count fail. Confirm the actual numbers printed rather than assuming.

- [ ] **Step 3: Update the table's own bookkeeping**

In `data/module_table.gd`, update the stale doc comment at `:11-12` — it is the source the test counts mirror:

```gdscript
## Split: 4 VECTOR / 4 TRIGGER / 10 PAYLOAD = 18.
## Unlocked at start: 3 / 3 / 9 = 15. A 3-exploit board needs 3 distinct
## VECTORs and 3 distinct TRIGGERs, so anything less is not fillable.
```

`LOCKED` is unchanged at three (`beam`, `on_damage_taken`, `worm`) — all three new modules start unlocked.

- [ ] **Step 4: Run tests to verify they pass**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_build.gd`
Expected: `PASS — all cases`.

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_meta.gd`
Expected: `PASS — all cases`.

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_slots.gd`
Expected: `PASS — all cases`. This is the card-targeting suite and the surface most likely to notice three new payload modules.

- [ ] **Step 5: Commit**

```bash
git add data/module_table.gd tests/test_build.gd tests/test_meta.gd
git commit -m "feat: harden, sandbox and nice enter the card pool

18 modules, 15 unlocked. Four of the fifteen are defensive (the three new
wards plus keylog), so roughly one card in four."
```

---

### Task 9: PACKET travel replaces the player-relative projectile cull

Keeping both bounds is what broke an earlier revision: the 1600-unit cull is measured **from the player**, so a player fleeing at the `clock_speed` this same work raises to 340 pushes a max-`reach` packet past it, making `reach` silently inert exactly when you run away. Deleting the player-relative test removes the interaction instead of tuning around it, and is strictly safer for the pool — max travel is 640 × 1.30 = **832 px**, so projectiles now live *shorter*, not longer.

**Files:**
- Modify: `scripts/run/run.gd` (`_proj_dist_left` declaration and sizing, `:361-362` decay, `:518` spawn, `:548` state guard, `:724-736` recycle)
- Modify: `tests/perf_milestone0.gd` (`_fill()`)
- Modify: `tools/fps_probe.gd:70`
- Modify: `tests/test_multipliers.gd` (travel cases)

**Interfaces:**
- Consumes: `ResolvedExploit.travel` (Task 5)
- Produces: `run._proj_dist_left: PackedFloat32Array`

- [ ] **Step 1: Write the failing test**

Add to `tests/test_multipliers.gd`, registered in `_initialize()` with `await`:

```gdscript
## travel must exceed VIEW_RANGE 620, or packets fall short of targets they are
## allowed to acquire — the inert-stat bug in a new place.
func travel_exceeds_acquisition_range() -> void:
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"packet"]); ex.place(t[&"interval"])
	_check("base travel outranges target acquisition",
		Compiler.build(ex).travel > 620.0, true)

## reach scales travel, and the maximum stays inside the pool's assumptions.
func reach_scales_travel() -> void:
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"packet"]); ex.place(t[&"interval"])
	var base := Compiler.build(ex)
	var far := Compiler.build(ex, {&"reach": 1.30})
	_check("reach scales travel", far.travel, base.travel * 1.30)
	_check("max travel stays under 1600", far.travel < 1600.0, true)

## A packet must expire at its travel distance and NOT at a player-relative
## distance. Fire, then flee: the projectile keeps flying, because the cull it
## used to hit was measured from the player.
func packet_expires_at_travel_not_at_player_distance() -> void:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.director.elapsed = 999.0
	run.director.boss_spawned = true
	while run.enemies.count > 0:
		run.enemies.despawn(run.enemies.count - 1)
	run.input_override = Vector2.ZERO

	# One enemy to shoot at, far enough that the packet is still flying.
	run.enemies.spawn(run.player_pos + Vector2(600.0, 0.0), Vector2.ZERO,
		99999.0, run.ENEMY_RADIUS, 0)
	for tick in 60:
		run._physics_process(DT)
		if run.projectiles.count > 0:
			break
	_check("a packet was spawned", run.projectiles.count > 0, true)

	# Now run the other way and keep running.
	run.input_override = Vector2.LEFT
	var alive_while_fleeing := false
	for tick in 30:
		run._physics_process(DT)
		if run.projectiles.count > 0:
			alive_while_fleeing = true
	_check("fleeing does not cull the packet", alive_while_fleeing, true)
	run.queue_free()
	await process_frame

## Travel expiry is the first thing that marks a projectile dead in step 2, so a
## dead projectile can now reach _step6_detect for the first time. Without the
## state guard it still lands a hit on its expiry tick.
func expired_projectile_does_not_hit() -> void:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.director.elapsed = 999.0
	run.director.boss_spawned = true
	while run.enemies.count > 0:
		run.enemies.despawn(run.enemies.count - 1)
	run.input_override = Vector2.ZERO

	var target := run.enemies.spawn(run.player_pos + Vector2(300.0, 0.0),
		Vector2.ZERO, 99999.0, run.ENEMY_RADIUS, 0)
	for tick in 60:
		run._physics_process(DT)
		if run.projectiles.count > 0:
			break
	_check("a packet was spawned to expire", run.projectiles.count > 0, true)

	# Strand it: no distance left, sitting exactly on top of the enemy.
	run.projectiles.pos[0] = run.enemies.pos[target]
	run._proj_dist_left[0] = 0.0
	var hp_before: float = run.enemies.integrity[target]
	run._physics_process(DT)
	_check("an expired projectile lands no hit",
		run.enemies.integrity[target] >= hp_before, true)
	run.queue_free()
	await process_frame
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_multipliers.gd`

Expected: `FAIL` on the travel cases — `travel` is 0.0 at runtime because nothing reads it yet, and the fleeing case fails because the 1600 cull is still player-relative.

- [ ] **Step 3: Write the implementation**

In `scripts/run/run.gd`, declare the array beside `_proj_owner` / `_proj_pierce`:

```gdscript
## Remaining flight distance. This is the ONLY lifetime bound on a projectile:
## the old player-relative 1600-unit cull is gone, because it was measured from
## the player and a fleeing player could push a legal max-reach packet past it,
## making reach silently inert exactly when you run away.
var _proj_dist_left: PackedFloat32Array
```

and size it in `_ready` wherever `_proj_owner` is sized.

At `:361-362`, decay it alongside the position integration and mark expired projectiles dead:

```gdscript
	for i in projectiles.count:
		projectiles.pos[i] += projectiles.vel[i] * dt
		# Population stores no scalar speed, so the step is the velocity's
		# length. One sqrt per live projectile per tick, bounded by
		# MAX_PROJECTILES 400.
		_proj_dist_left[i] -= projectiles.vel[i].length() * dt
		if _proj_dist_left[i] <= 0.0:
			projectiles.state[i] = Population.DEAD
```

At the PACKET spawn (`:518`), seed it from the compiled stat:

```gdscript
			if pi >= 0:
				_proj_owner[pi] = ei
				_proj_pierce[pi] = r.pierce
				_proj_last[pi] = -1
				_proj_dist_left[pi] = maxf(r.travel, 1.0)
```

At `:548`, guard the detection loop — travel expiry is the first thing that marks a projectile dead in step 2, so a dead projectile can now reach step 6:

```gdscript
	for i in projectiles.count:
		if projectiles.state[i] != Population.ALIVE:
			continue
```

In the recycle block (`:724-736`), drop the player-distance term and carry the new array through the swap-remove:

```gdscript
	i = 0
	while i < projectiles.count:
		if projectiles.state[i] != Population.ALIVE:
			# Population.despawn swap-removes the tail into slot i, so every
			# parallel array must move with it. Omitting this let a surviving
			# projectile inherit a dead one's owner exploit (wrong damage and
			# wrong lifesteal attribution) and its exhausted pierce.
			var last := projectiles.count - 1
			_proj_owner[i] = _proj_owner[last]
			_proj_pierce[i] = _proj_pierce[last]
			_proj_last[i] = _proj_last[last]
			_proj_dist_left[i] = _proj_dist_left[last]
			projectiles.despawn(i)
		else:
			i += 1
```

In `tests/perf_milestone0.gd`, seed the new array in `_fill()` beside the existing three — a resized `PackedFloat32Array` gives 0.0, which would expire every stress projectile on its first integration pass and silently make the gate measure a lighter workload:

```gdscript
			run._proj_owner[pi] = 0
			run._proj_pierce[pi] = 9999
			run._proj_last[pi] = -1
			run._proj_dist_left[pi] = 99999.0
```

Apply the identical addition in `tools/fps_probe.gd:70`:

```gdscript
		if pi >= 0: run._proj_owner[pi]=0; run._proj_pierce[pi]=9999; run._proj_last[pi]=-1; run._proj_dist_left[pi]=99999.0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_multipliers.gd`
Expected: `PASS — all cases`.

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_run.gd`
Expected: `PASS — all checks`. This drives a full winning subnet and is the regression surface for projectile lifetime.

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/perf_milestone0.gd`
Expected: the gate passes. Compare the reported mean and p95 against the README's figures (mean 1.13 ms, p95 2.40 ms against an 11 ms budget; stress mean 7.5 ms, p95 9.7 ms). A stress figure that *improved* sharply is a red flag — it means projectiles are expiring early and the gate got easier, which is exactly the failure the `_fill()` seeding prevents.

- [ ] **Step 5: Commit**

```bash
git add scripts/run/run.gd tests/perf_milestone0.gd tools/fps_probe.gd tests/test_multipliers.gd
git commit -m "feat: packet travel distance replaces the player-relative cull

_proj_dist_left is now the only lifetime bound on a projectile. The old
1600-unit test was measured from the player, so fleeing at a legal buffed
clock_speed could cull a max-reach packet early and make reach inert exactly
when you run away. Max travel is 832px, so projectiles live shorter than
before. Both manual seeding sites initialise the new array."
```

---

### Task 10: The shop screen shows eight rows without clipping

Two columns do **not** fit: one row is 230 + 12 + 240 + 12 + 150 = **644 px**, and two from x=64 need ≥1352 px against a 1280 viewport. A bounded `ScrollContainer` is the fix, and the bound is required — an unbounded one inherits its content's minimum height and pushes the button down exactly as the bare `VBoxContainer` does today.

**Files:**
- Modify: `scripts/meta/meta_screen.gd` (`BUFFS` at `:10-14`, the label at `:39`, the container at `:27-30`)

**Interfaces:**
- Consumes: `SaveGame.SHEET_EFFECT` / `MULT_EFFECT` names (Task 3)
- Produces: nothing consumed by later tasks

- [ ] **Step 1: Replace the BUFFS table**

The two existing description strings are now false — `cpu_cycles` and `cooling` are multipliers, not flat values:

```gdscript
const BUFFS := [
	[&"cpu_cycles", "+CPU cycles", "attack x1.04 per rank"],
	[&"cooling",    "+cooling",    "attack speed x0.97 per rank"],
	[&"memory",     "+memory",     "integrity +8 per rank"],
	[&"firewall",   "+firewall",   "armor +0.6 per rank"],
	[&"encryption", "+encryption", "defense +6 per rank"],
	[&"bus_speed",  "+bus speed",  "move speed +6 per rank"],
	[&"addressing", "+addressing", "range x1.03 per rank"],
	[&"bandwidth",  "+bandwidth",  "pickup radius +6 per rank"],
]
```

Every id here must exist in `SaveGame._default()["buffs"]`, because `meta_screen.gd:90` does `d["buffs"][String(r["id"])]` — a direct index with no `.get`, which crashes the shop on open for any missing name.

- [ ] **Step 2: Fix the now-false section label**

At `:39`, five of the eight are applied at run time, not compile time:

```gdscript
	col.add_child(_label("UPGRADES  ::  permanent, applied at run start", 13, DIM))
```

- [ ] **Step 3: Wrap the rows in a bounded ScrollContainer**

Restructure so the rows scroll and `./intrude` cannot: build a `ScrollContainer` with an explicit height, put the per-buff rows inside it, and add the start button to the outer column *after* it.

```gdscript
	var scroll := ScrollContainer.new()
	# The bound is load-bearing: without an explicit height a ScrollContainer
	# adopts its content's minimum height and pushes ./intrude off a 720px
	# viewport exactly as the bare VBoxContainer does. Eight rows at 40px is
	# 320; 300 shows seven and a half, which reads as scrollable.
	scroll.custom_minimum_size = Vector2(680, 300)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 10)
	scroll.add_child(rows)
```

Then change the `for b in BUFFS:` loop to `rows.add_child(row)` instead of `col.add_child(row)`, leaving every later `col.add_child(...)` — the spacer, the status label and the start button — untouched.

- [ ] **Step 4: Verify visually**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tools/shot_meta.gd`

Then open the screenshot it writes and confirm: eight rows are reachable, and the `./intrude` button is fully visible inside 720 px. There is no automated check for layout — this is the manual gate.

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_meta.gd`
Expected: `PASS — all cases`.

- [ ] **Step 5: Commit**

```bash
git add scripts/meta/meta_screen.gd
git commit -m "feat: eight shop rows in a bounded ScrollContainer

Two columns needed 1352px against a 1280 viewport. The scroll container needs
an explicit height or it adopts its content's minimum and clips ./intrude
anyway; the start button now lives outside it."
```

---

### Task 11: HUD reads the sheet, and the stale docs go

**Files:**
- Modify: `scripts/run/ui.gd:123` and `:127`
- Modify: `README.md:27` and `:81`
- Modify: `scripts/build/loadout.gd:63-64` (stale comment)
- Modify: `scripts/meta/save_game.gd:22-27` if the doc comment was not already replaced in Task 3

**Interfaces:**
- Consumes: `run._eff_integrity()` (Task 6), `run._eff_armor()` / `_eff_defense()` (Task 7)
- Produces: nothing

- [ ] **Step 1: Read the maximum from the sheet**

`ui.gd:123` hardcodes the max in the **format string**, so no compiler catches it — a `memory` r10 player reads `integrity 180/100`. Replace the line and its argument list:

```gdscript
	var maxhp := int(run._eff_integrity())
	top.text = "integrity %3d/%d   armor %.0f  def %.0f   %s   lvl %d  [%s]   salvage %d   botnet %d   kills %d  flips %d" % [
		hp, maxhp, run._eff_armor(), run._eff_defense(),
		"%d:%02d" % [int(t) / 60, int(t) % 60], run.level,
		_bar(float(run.xp) / maxf(run.xp_needed, 1), 14), run.salvage,
		run.botnet.count, run.kills, run.flips]
```

- [ ] **Step 2: Make the low-health warning proportional**

`:127` uses an absolute threshold, so at 180 integrity it fires at 16.7% instead of 30%:

```gdscript
	top.add_theme_color_override("font_color",
		WARN if float(hp) < maxhp * 0.3 else FG)
```

- [ ] **Step 3: Update the stale documentation**

`README.md:27` — add the three modules to the PAYLOAD row:

```markdown
| `PAYLOAD` | 0–2 | what it does on contact | buffer_overflow, fork_bomb, corrupt, keylog, worm, fork, overclock, harden, sandbox, nice |
```

`README.md:81` — wards *are* in-run stat changes, so that line is now false. Remove the phrase and leave the rest of the list:

```markdown
controller support, and healing beyond keylog's lifesteal.
```

`scripts/build/loadout.gd:63-64` — the comment claims a uniqueness rule the code three lines below contradicts (`:81-83`: "Ranks are per SLOT, not per module"). The whole `maxf` fold exists because the comment is wrong:

```gdscript
##   - a module id may appear in any number of slots; ranks are per SLOT, so the
##     same module in two slots is two independent copies, and an already-filled
##     slot offers only a rank-up;
```

- [ ] **Step 4: Verify**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tools/screenshot.gd`

Open the screenshot and confirm the HUD reads `integrity 100/100  armor 0  def 0` on a fresh run.

Then run the full suite:

```bash
for t in test_build test_drain test_corruption test_meta test_run test_slots \
         test_triggers test_worms test_dispatch test_player_stats \
         test_player_sheet test_wards test_multipliers; do
  echo "--- $t"
  godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s "res://tests/$t.gd" 2>&1 | tail -2
done
```

Expected: every suite prints its PASS line, and **no** `SCRIPT ERROR` appears anywhere in the output.

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/perf_milestone0.gd`
Expected: the gate passes.

- [ ] **Step 5: Commit**

```bash
git add scripts/run/ui.gd scripts/build/loadout.gd README.md
git commit -m "feat: HUD reads effective integrity, armor and defense

The maximum was hardcoded in the format string and the low-health warning used
an absolute threshold, so a 180-integrity player read 180/100 and warned at
16.7%. Also drops three doc claims this work made false."
```

---

## Notes for the executor

**Unverified reports about existing `run.gd` bugs.** Another review session reported three CRITICALs in code this plan touches — enemies paid twice in the outcome rescan around `run.gd:416-420`, a `hit_queue` out-of-bounds at population cap, and ON_HIT events enqueued then discarded around `run.gd:408-415`. **These were not verified during planning and are not in scope here.** If a task's tests fail in a way that looks like double-counted kills or missing ON_HIT damage, suspect those rather than the task, and stop to confirm before working around it.

**Task order matters in two places.** Task 3 must precede Task 4 (the compiler needs `SaveGame.multipliers()` to exist), and Task 5 must precede Tasks 7 and 9 (the ward and travel fields must exist before anything reads them). Everything else can move.

**A new `class_name` file needs an import pass before any test can see it.**
`player_stats.gd` is the only new `class_name` in this plan. Godot registers
`class_name` in `.godot/global_script_class_cache.cfg` during a project scan, and
`godot --headless -s <script>` does not trigger one — the test fails with
`Parse Error: Identifier "PlayerStats" not declared in the current scope` no
matter how correct the file is. Run this once after creating it:

```bash
godot --headless --path /Users/sean/sites/hacking-bullet-heaven --import
```

**Task 5 leaves `test_build.gd` red on purpose.** Its two hardcoded count assertions fail between Task 5 and Task 8. That is the only point in the plan where a task ends with a known-failing assertion, and Task 8 is what closes it.
