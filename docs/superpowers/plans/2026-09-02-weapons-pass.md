# Weapons Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every player slot a facing derived from its movement, cut the vector pool to one module per `VectorKind`, make spike, beam and packet fire forward and landmine drop behind, and give every kind its own shape on screen.

**Architecture:** `player_facing` is a per-slot `PackedVector2Array` written in `_step2_integrate` from the applied movement record, carried in the state manifest, and read by `_emit_vector`. The module and recipe tables shrink to eight vectors, `checksum` becomes a payload gated by a new unranked `shield_rearm` stat, and seven fused damages are re-derived. One presentation list `_fx` with an `FxKind` enum replaces `_fx_line`/`_fx_ring`; the projectile renderer writes glyph and colour per frame.

**Tech Stack:** Godot 4.7, GDScript. Suites are `SceneTree` scripts run with `godot --headless -s res://tests/<suite>.gd`; the runner is `tools/run_tests.sh`.

**Spec:** `docs/superpowers/specs/2026-09-02-weapons-pass-design.md` — read it first and keep it open; every number below comes from it.

## Global Constraints

- The simulation tick reads no device, clock or connection; `test_determinism_rules` greps for `Input.`, `Time.get_`, `Engine.time_scale`, `randf()` outside seeded streams. Facing is derived from `inputs[s]` only.
- Every `var` in `scripts/run/run.gd` must be in `STATE_FIELDS` or `NOT_IN_MANIFEST` (`test_manifest` fails otherwise). New simulation state: `player_facing`, `_shield_left` (both `SH`). New presentation/scratch: `_fx`, `_beam_hits`, `_beam_keys`.
- `Module.VectorKind` is append-only and does not change. `Synth.fire_id(kind)` does not change.
- `Module.STAT_KEYS` is the only legal stat key set; every key must be a field on `ResolvedExploit`.
- Defensive stats fold by MAX (`Compiler.MAX_FOLD_KEYS`); `shield_rearm` joins that list and is UNRANKED in `_fold` like `ward_duration`.
- No image assets, no font files, no `Area2D`.
- Always run suites through `tools/run_tests.sh` at the end; a single suite run by hand can print PASS after a `SCRIPT ERROR`. The loopback suite needs the Bash sandbox off.
- Commit after every task. Work on branch `weapons-pass` (the spec is already committed there as f3cfa10).

---

### Task 1: Facing state

**Files:**
- Modify: `scripts/run/run.gd` (`_allocate_slots` ~line 1434; `_return` ~845; `_step2_integrate` ~2228; `STATE_FIELDS` per-slot block ~4968)
- Create: `tests/test_facing.gd`
- Modify: `tools/run_tests.sh:27`, `CLAUDE.md:12`

**Interfaces:**
- Produces: `run.player_facing: PackedVector2Array` (unit world vector per slot, default `Vector2.RIGHT`), used by Tasks 4, 5, 8, 10.

- [ ] **Step 1: Write the failing suite skeleton with the facing cases**

Create `tests/test_facing.gd`:

```gdscript
extends SceneTree

## Facing, the forward vectors, the mine drop, the shield rearm and the fx
## structural checks. Every case builds its own run; the harness cases build
## two.

var failures := 0
var finished := {}
const DT := 1.0 / 60.0

const CASES := ["facing_follows_the_applied_record_and_holds",
	"facing_survives_a_restore", "two_peers_agree_while_turning",
	"a_return_resets_facing"]

func _initialize() -> void:
	print("ROOTKIT — facing\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	await facing_follows_the_applied_record_and_holds()
	await facing_survives_a_restore()
	await two_peers_agree_while_turning()
	await a_return_resets_facing()
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

func _fresh_run() -> Node2D:
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	r.external_drive = true
	root.add_child(r)
	await process_frame
	r.input_override = Vector2.ZERO
	return r

func facing_follows_the_applied_record_and_holds() -> void:
	var r := await _fresh_run()
	_check("facing starts right", r.player_facing[r.local_slot], Vector2.RIGHT)
	r.input_override = Vector2(3.0, 4.0)     # not unit: the poll normalises once
	r._physics_process(DT)
	var f: Vector2 = r.player_facing[r.local_slot]
	_check_true("a diagonal record sets a unit facing", absf(f.length() - 1.0) < 1e-5)
	_check_true("pointing the way it moved", f.dot(Vector2(3.0, 4.0).normalized()) > 0.999)
	r.input_override = Vector2.ZERO
	for _i in 5:
		r._physics_process(DT)
	_check("a zero record keeps it", r.player_facing[r.local_slot], f)
	r.free()
	await process_frame
	finished["facing_follows_the_applied_record_and_holds"] = true

func facing_survives_a_restore() -> void:
	var a := await _fresh_run()
	var b := await _fresh_run()
	a.input_override = Vector2(-1.0, 0.0)
	a._physics_process(DT)
	var bytes: PackedByteArray = a.serialize_state(a.tick)
	_check_true("restore accepts it", b.restore_state(bytes, a.tick))
	_check("facing came through the snapshot", b.player_facing[0], a.player_facing[0])
	_check("and the hashes agree", b._state_hash(), a._state_hash())
	a.free(); b.free()
	await process_frame
	finished["facing_survives_a_restore"] = true

func two_peers_agree_while_turning() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, 2, 20260830)
	var fn := func(t: int) -> Array:
		var a := float(t) * 0.05
		return [Vector2(cos(a), sin(a)), Vector2(-sin(a), cos(a))]
	for _i in 600:
		h.step(fn)
	_check("two turning peers agree", h.all_agree(), true)
	if not h.all_agree():
		print("    diff ", h.first_difference(h.runs[0], h.runs[1]))
	h.teardown()
	await process_frame
	finished["two_peers_agree_while_turning"] = true

func a_return_resets_facing() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, 0, 20260830)
	var fn := func(_t: int) -> Array: return [Vector2.ZERO, Vector2(-1.0, 0.0)]
	for _i in 5:
		h.step(fn)
	for r in h.runs:
		_check("slot one faces left before parking", r.player_facing[1], Vector2.LEFT)
		r._park(1)
		r._return(1, r.lockstep.executed - 1)
		_check("a return faces right again", r.player_facing[1], Vector2.RIGHT)
	h.teardown()
	await process_frame
	finished["a_return_resets_facing"] = true
```

- [ ] **Step 2: Run it and watch it fail**

Run: `godot --headless -s res://tests/test_facing.gd 2>&1 | grep -E 'SCRIPT ERROR|FAIL|PASS'`
Expected: `SCRIPT ERROR` about `player_facing` not found.

- [ ] **Step 3: Add the field, its allocation, the update and the reset**

In `scripts/run/run.gd`, next to `var player_vel: PackedVector2Array` (~line 211):

```gdscript
## Where each slot faces, in WORLD space: the last non-zero applied movement,
## held while it stands still. Forward vectors fire along it. Simulation
## state — hashed and snapshotted — derived from records alone, so every peer
## holds the same value. The local player's facing lags the stick by the
## lockstep delay on purpose: a tick that led the simulation would point where
## the wedge does not fire.
var player_facing: PackedVector2Array
```

In `_allocate_slots`, after `player_vel = PackedVector2Array(); player_vel.resize(n)`:

```gdscript
	player_facing = PackedVector2Array(); player_facing.resize(n)
	player_facing.fill(Vector2.RIGHT)
```

In `_step2_integrate`, inside the LIVE-slot loop right after `var world_dir: Vector2 = inputs[s]`:

```gdscript
		if world_dir.length_squared() > 0.0:
			player_facing[s] = world_dir.normalized()
```

In `_return`, immediately after the `if slot_state[slot] != SlotState.ABSENT: return` guard and before `var h := _parked_health[slot]`:

```gdscript
	# A return faces right, whether it comes back LIVE or DEAD, so a slot
	# revived later never carries the facing it parked with.
	player_facing[slot] = Vector2.RIGHT
```

In `_build_manifest`, add `"player_facing"` to the per-slot `SH` list right after `"player_vel"`:

```gdscript
	for prop in ["slot_state", "player_pos", "player_prev_pos", "player_vel",
			"player_facing", "player_health", "player_iframe", "player_shield",
			"_parked_health", "_low_armed", "_zone_slow_player", "kills", "flips",
			"inputs", "_offer_seq"]:
```

- [ ] **Step 4: Register the suite and run it**

In `tools/run_tests.sh`, append `test_facing` to the `SUITES` array line that ends `test_parking test_reconnect`. In `CLAUDE.md` change `52 suites + the perf gate` to `53 suites + the perf gate`.

Run: `godot --headless -s res://tests/test_facing.gd 2>&1 | grep -E 'SCRIPT ERROR|FAIL|PASS'`
Expected: `PASS — all cases`.

Run: `godot --headless -s res://tests/test_manifest.gd 2>&1 | grep -E 'SCRIPT ERROR|FAIL|PASS'` and `godot --headless -s res://tests/test_determinism_rules.gd 2>&1 | grep -E 'SCRIPT ERROR|FAIL|PASS'`
Expected: both `PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/run/run.gd tests/test_facing.gd tools/run_tests.sh CLAUDE.md
git commit -m "feat: derive a per-slot facing from the applied movement record"
```

---

### Task 2: The table cut, checksum as a payload, and the shield_rearm stat

**Files:**
- Modify: `data/module_table.gd` (header lines 8-14, `LOCKED` 30-34, vector rows 44-112)
- Modify: `scripts/build/module.gd:20-27` (`STAT_KEYS`), `scripts/build/module.gd:10-16` (targeting comment)
- Modify: `scripts/build/resolved_exploit.gd` (field near `shield` ~58; `equals()` 106-122)
- Modify: `scripts/build/compiler.gd:43-51` (`MAX_FOLD_KEYS`), `:184-186` (unranked carve-out)
- Modify: `scripts/meta/save_game.gd:294-309` (`MILESTONES`)
- Modify: `tests/test_build.gd:70-71, :308, :318-330, :395-402`, `tests/test_meta.gd:90`
- Modify: `tools/build_manual.py` (`MODULE_NOTES` 147-162, `STAT_LABEL` 217-226), `README.md:73, :87-88`

**Interfaces:**
- Produces: `ResolvedExploit.shield_rearm: float` (seconds, 0 = no rearm), `checksum` as a PAYLOAD `{shield: 26.0, shield_rearm: 2.6}`; the table has 30 modules, 8 vectors.

- [ ] **Step 1: Update the build suite's pins first (they fail until the table changes)**

In `tests/test_build.gd`:
- line 70: `_check("data sweep: 30 modules, 0 errors", errs.size(), 0)`
- line 71: `_check("data sweep: module count", ModuleTable.all().size(), 30)`
- line 308: `_check("unlocked total", ModuleTable.starting_unlocked().size(), 19)`
- lines 318-321 comment: append `, and the weapons pass adds shield_rearm` before `Pinned because`.
- line 322: `_check("STAT_KEYS is 28", Module.STAT_KEYS.size(), 28)`
- line 330: `_check("every OTHER stat key defaults to zero", zero_defaults, 27)`
- lines 395-396: remove `&"flood", &"snipe", &"cascade", &"throttle", &"airgap"` from the list; line 401: `_check("all twelve new modules are in the table", missing, 0)`; line 402: `_check("the table is 30 modules", all.size(), 30)`.

Add a new case to `test_build.gd` (register it in its `CASES`/`_initialize` the same way the existing cases are):

```gdscript
## equals() enumerates fields by hand; a stat it skips is a stat the meta
## derivation checks cannot see.
func equals_sees_shield_and_shield_rearm() -> void:
	var a := ResolvedExploit.new()
	var b := ResolvedExploit.new()
	_check("equal when blank", a.equals(b), true)
	b.shield = 26.0
	_check("equals distinguishes shield", a.equals(b), false)
	b.shield = 0.0
	b.shield_rearm = 2.6
	_check("equals distinguishes shield_rearm", a.equals(b), false)

## Rank buys shield magnitude, never uptime: the rearm is unranked.
func shield_rearm_is_unranked() -> void:
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"packet"]); ex.place(t[&"interval"]); ex.place(t[&"checksum"])
	ex.payloads[0].rank = 5
	var r := Compiler.build(ex)
	_check("shield scales with rank", r.shield, 26.0 * 5.0)
	_check("the rearm does not", r.shield_rearm, 2.6)
	_check("checksum is a payload", t[&"checksum"].slot, Module.Slot.PAYLOAD)
```

In `tests/test_meta.gd:90`: `_check("fresh save starts with 19 modules", SaveGame.unlocked_modules().size(), 19)`.

- [ ] **Step 2: Run the build suite and see the pins fail**

Run: `godot --headless -s res://tests/test_build.gd 2>&1 | grep -E 'SCRIPT ERROR|FAIL|PASS' | head`
Expected: FAIL on the count and STAT_KEYS pins, SCRIPT ERROR on `shield_rearm`.

- [ ] **Step 3: Change the tables and the build layer**

`data/module_table.gd`:
- Header comment lines 11-12: `## Split: 8 VECTOR / 7 TRIGGER / 15 PAYLOAD = 30.` and `## Unlocked at start: 5 / 3 / 11 = 19; see LOCKED below for why the rest is`.
- `LOCKED`: remove `&"snipe"`, `&"cascade"`, `&"airgap"`.
- Delete the `flood`, `snipe`, `cascade`, `throttle` and `airgap` `Module.make` rows.
- Replace the `checksum` row (a VECTOR) with a PAYLOAD row placed among the payloads:

```gdscript
		# Shield is a magnitude bought once; the rearm keeps it off the host
		# vector's cadence (a packet at the floor would refill it forty times
		# faster than the 2.6 s the old vector had). Unranked in Compiler._fold.
		Module.make(&"checksum", "checksum()", S.PAYLOAD,
			{&"shield": 26.0, &"shield_rearm": 2.6}),
```
(Use the same `Module.make` arity the neighbouring payload rows use.)

`scripts/build/module.gd`: append `&"shield_rearm"` to `STAT_KEYS` after `&"homing"`. Rewrite the targeting comment (lines 10-16):

```gdscript
## How a vector chooses among the enemies in range. Only CHAIN and the homing
## re-acquire consult it now — BEAM, CONE and PACKET fire along the owner's
## facing, and BROADCAST, PULSE, MINE and ORBIT resolve from the player's
## position. Three modes, not four; the enum is append-safe.
```

`scripts/build/resolved_exploit.gd`: after `var shield: float = 0.0` add

```gdscript
## Seconds between shield grants on this exploit; 0 grants on every fire.
## MAX-folded and unranked like ward_duration.
var shield_rearm: float = 0.0
```
and in `equals()` add `and shield == o.shield and shield_rearm == o.shield_rearm \` before the `and tags.keys()` line.

`scripts/build/compiler.gd`: add `&"shield_rearm",` to `MAX_FOLD_KEYS` after `&"shield"`; change the carve-out to

```gdscript
		elif key == &"ward_duration" or key == &"shield_rearm":
			# Rank buys ward and shield magnitude, never uptime.
			scale = 1.0
```

`scripts/meta/save_game.gd` `MILESTONES`: delete the `snipe`, `cascade` and `airgap` rows. Nothing else changes.

- [ ] **Step 4: Docs that carry the old table**

`tools/build_manual.py`: delete the `MODULE_NOTES` entries for `flood`, `snipe`, `cascade`, `throttle`, `airgap`; rewrite these:

```python
    "packet": "A straight shot along your facing. Your starting weapon: aim by moving.",
    "beam": "A line along your facing through several enemies.",
    "spike": "A 90&deg; wedge along your facing. Heavy damage, demands facing.",
    "landmine": "Drops a charge a step behind you that waits until something comes within 46 units. Running lays a trail.",
    "checksum": "A payload: the row grants a shield on fire, absorbed before integrity, rearming every 2.6 s. On a head that already shields it only slows the refill.",
```
and add `"shield_rearm": "rearm s",` to `STAT_LABEL`.

`README.md:73`: the VECTOR row becomes `broadcast, packet, chain, beam, spike, landmine, bounce, mirror`; the PAYLOAD row gains `checksum`; line 87-88: `packet + on_kill + bitmask` is `zero_day()`.

- [ ] **Step 5: Run the suites that read the table**

Run each: `godot --headless -s res://tests/test_build.gd`, `test_meta.gd`, `test_player_sheet.gd`, `test_multipliers.gd`, piping through `grep -E 'SCRIPT ERROR|FAIL|PASS'`.
Expected: `test_build` and `test_meta` PASS. (`test_fusion` and the four keep-row suites still fail until Task 3 — expected.)

Run: `python3 tools/build_manual.py` — Expected: exits 0 (no missing note).

- [ ] **Step 6: Commit**

```bash
git add data/module_table.gd scripts/build scripts/meta/save_game.gd tests/test_build.gd tests/test_meta.gd tools/build_manual.py README.md
git commit -m "feat: cut the vector pool to one per kind and make checksum a rearming payload"
```

---

### Task 3: Rehome the recipes and re-derive fused damage

**Files:**
- Modify: `data/recipe_table.gd` (rows for hollow_point, dragnet, zero_day, botnet_cascade, tar_siphon, panic_room, redundancy, last_resort, railgun, core_dump)
- Modify: `tests/test_fusion.gd:5, :266-268, :271-279, :292-293, :311-313`
- Modify: `tests/test_blocks.gd:5, :137-138, :154-157, :178-179`, `tests/test_cards_keyboard.gd:358-359, :386-387`, `tests/test_offers.gd:214-220`

**Interfaces:**
- Consumes: the 30-module table from Task 2.
- Produces: twenty recipes covering 8 vectors, 7 triggers, 15 payloads, all triples distinct.

- [ ] **Step 1: Change the fusion suite to the new contract**

`tests/test_fusion.gd` lines 266-268 become set comparisons:

```gdscript
	var want_v := {}; var want_t := {}; var want_p := {}
	for m in ModuleTable.all():
		match m.slot:
			Module.Slot.VECTOR: want_v[m.id] = true
			Module.Slot.TRIGGER: want_t[m.id] = true
			Module.Slot.PAYLOAD: want_p[m.id] = true
	_check("every trigger has a fusion path", ts.keys().size() == want_t.size() and ts.keys().all(func(k): return want_t.has(k)), true)
	_check("every payload has one too", ps.keys().size() == want_p.size() and ps.keys().all(func(k): return want_p.has(k)), true)
	_check("every vector has one too", vs.keys().size() == want_v.size() and vs.keys().all(func(k): return want_v.has(k)), true)
```

Lines 271-279: the exact triple is `packet + on_kill + bitmask`; the negative control becomes `packet + on_kill + overclock` (no recipe names it); the partial row is `packet + on_kill`.

Lines 292-293 (the keep row): `_mk(&"broadcast", &"interval", [])`; the fused row `_mk(&"packet", &"on_kill", [&"bitmask"])`.

Lines 311-313: the freed id must be placeable into an EMPTY slot:

```gdscript
	var empty_home := false
	for tgt in lo.legal_targets(T[&"packet"]):
		if tgt.rule == Loadout.Rule.EMPTY_SLOT:
			empty_home = true
	_check("packet is placeable again, into an empty slot", empty_home, true)
```
(Check the `Rule` enum name in `scripts/build/loadout.gd`; use the member the "empty slot" target carries.)

Add a near-miss order case:

```gdscript
## near_miss returns the FIRST single-miss recipe in table order, so the
## table's order is load-bearing; pin it.
func near_miss_walks_table_order() -> void:
	var ex := Exploit.new()
	ex.place(T[&"broadcast"]); ex.place(T[&"interval"])
	_check("broadcast + interval misses pulse_train first", RecipeTable.near_miss(ex), &"overclock")
```
Register it; then bump `EXPECTED_CHECKS` at line 5 to the new total (run the suite once and read the count it reports).

- [ ] **Step 2: Fix the four keep-row fixtures and the near-miss expectation**

`tests/test_blocks.gd:137-138` and `:178-179`, `tests/test_cards_keyboard.gd:358-359` and `:386-387`: the fusion row becomes `_row(run, &"packet", &"on_kill", &"bitmask")` and the keep row `_row(run, &"broadcast", &"interval", &"")`. `tests/test_offers.gd:214`: `ex.place(mods[&"packet"])`; line 220: `keep.place(mods[&"broadcast"])`.

`tests/test_blocks.gd:154-157`:

```gdscript
	# One module short of pulse_train (broadcast + interval + overclock), the
	# first single-miss recipe in table order: the targeted card is what makes
	# an exact triple reachable at all.
	_check("the targeted module completes the near-miss row",
		run._targeted_module(run.local_slot).id, &"overclock")
```
Bump `EXPECTED_CHECKS` in `tests/test_blocks.gd:5` only if the count changed.

- [ ] **Step 3: Run the fusion suite and see it fail on the recipes**

Run: `godot --headless -s res://tests/test_fusion.gd 2>&1 | grep -E 'SCRIPT ERROR|FAIL|PASS' | head`
Expected: FAIL on triple/coverage and the no-downgrade check.

- [ ] **Step 4: Rehome and re-derive**

In `data/recipe_table.gd` change the seven `Recipe.new` triples and their fused `damage`:

| Recipe | `Recipe.new(` args | fused damage |
|---|---|---|
| dragnet | `&"broadcast", &"interval", &"tarpit"` | 21.0 |
| zero_day | `&"packet", &"on_kill", &"bitmask"` | 94.5 |
| botnet_cascade | `&"chain", &"on_flip", &"worm"` | 13.0 (corruption 14.5 unchanged) |
| tar_siphon | `&"broadcast", &"interval", &"keylog"` | 19.0 |
| panic_room | `&"bounce", &"on_damage_taken", &"sandbox"` | 41.0 |
| redundancy | `&"broadcast", &"on_kill", &"checksum"` | 32.5 (shield 60.0 unchanged) |
| last_resort | `&"broadcast", &"on_low_integrity", &"sandbox"` | 67.5 |

Every other stat on those rows stays. Remove the `G.STRONGEST` argument from `hollow_point`, `railgun` and `core_dump` (they aim by facing now); `zero_day` keeps it (homing), `arp_storm` keeps `G.FARTHEST`. Add above the table:

```gdscript
## The weapons pass rehomed seven recipes onto stronger base vectors and
## re-derived their damage under the rule above; five recipes now sit on
## broadcast, so five fused modules each out-fire a rank-5 broadcast-plus-
## trigger. That is the intended cost of one vector per kind.
```

- [ ] **Step 5: Run the affected suites**

Run each through `grep -E 'SCRIPT ERROR|FAIL|PASS'`: `test_fusion`, `test_blocks`, `test_cards_keyboard`, `test_offers`, `test_fusion_run`, `test_build`.
Expected: all PASS. If `fusing_is_never_a_downgrade` lists a name, recompute that one with the scratch derivation (rank-5 triple DPS × fused cooldown, corruption held, snapped up to 0.5).

- [ ] **Step 6: Commit**

```bash
git add data/recipe_table.gd tests/test_fusion.gd tests/test_blocks.gd tests/test_cards_keyboard.gd tests/test_offers.gd
git commit -m "feat: rehome the seven recipes and re-derive their fused damage"
```

---

### Task 4: Forward vectors — packet, beam, spike

**Files:**
- Modify: `scripts/run/run.gd` (`_emit_vector` BEAM ~2615-2628, CONE ~2630-2647, default PACKET arm ~2733-2762; the comment above the match ~2598-2601; constants near `CONE_HALF_ANGLE` ~147; `_buf` ~556; `NOT_IN_MANIFEST` ~5040)
- Modify: `tests/test_facing.gd`, `tests/test_wards.gd:77-80`

**Interfaces:**
- Consumes: `player_facing[owner]` (Task 1).
- Produces: `BEAM_HALF_WIDTH := 22.0`, `_beam_hits: PackedInt32Array`, `_beam_keys: PackedFloat32Array` (scratch, sized `_buf.size()`).

- [ ] **Step 1: Add the failing cases to `tests/test_facing.gd`**

Add to `CASES` and `_initialize`: `packet_flies_along_facing`, `a_homing_packet_still_binds`, `beam_hits_its_capsule_only`, `spike_hits_its_wedge_only`, `beam_radius_floor_holds_in_the_tables`. Add helpers and cases:

```gdscript
## A run with one exploit on the local slot: vector + interval (+ payloads).
func _with(r: Node2D, vector_id: StringName, payloads: Array = [], fused: Module = null) -> int:
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	if fused != null:
		ex.vector = EquippedModule.new(fused, 1)
	else:
		ex.place(t[vector_id])
	ex.place(t[&"interval"])
	for p in payloads:
		ex.place(t[p])
	r.loadouts[r.local_slot].exploits = [ex]
	r._recompile()
	return r._gid(r.local_slot, 0)

func _face(r: Node2D, dir: Vector2) -> void:
	r.input_override = dir
	r._physics_process(DT)
	r.input_override = Vector2.ZERO

func _spawn(r: Node2D, offset: Vector2) -> int:
	return r.enemies.spawn(r.player_pos[r.local_slot] + offset, Vector2.ZERO, 9999.0, r.ENEMY_RADIUS, 0)

## Which enemies the queue holds DAMAGE events for after one emit.
func _targets_hit(r: Node2D, gid: int) -> Array:
	r.queue.begin_tick()
	r._step3_rebuild()
	r._emit_vector(gid, r.resolved[gid])
	var out := []
	for k in r.queue.count:
		if r.queue.source_exploit[k] == gid and not (r.queue.target[k] in out):
			out.append(r.queue.target[k])
	return out

func packet_flies_along_facing() -> void:
	var r := await _fresh_run()
	var gid := _with(r, &"packet")
	_spawn(r, Vector2(0.0, -300.0))            # an enemy up, off the facing axis
	_face(r, Vector2.LEFT)
	r.queue.begin_tick()
	r._step3_rebuild()
	var before: int = r.projectiles.count
	r._emit_vector(gid, r.resolved[gid])
	_check("a packet spawned", r.projectiles.count, before + 1)
	var i: int = r.projectiles.count - 1
	_check_true("it flies along facing, not at the enemy", r.projectiles.vel[i].normalized().dot(Vector2.LEFT) > 0.999)
	_check("and binds no target", r._proj_target[i], -1)
	r.free(); await process_frame
	finished["packet_flies_along_facing"] = true

func a_homing_packet_still_binds() -> void:
	var r := await _fresh_run()
	var homer := Module.make(&"test_homer", "test_homer()", Module.Slot.VECTOR,
		{&"damage": 5.0, &"projectile_speed": 400.0, &"cooldown": 0.5,
		 &"travel": 900.0, &"homing": 2.6}, [], Module.VectorKind.PACKET, Module.TriggerKind.INTERVAL)
	homer.is_fused = true
	var gid := _with(r, &"", [], homer)
	var e := _spawn(r, Vector2(0.0, -300.0))
	_face(r, Vector2.LEFT)
	r.queue.begin_tick()
	r._step3_rebuild()
	r._emit_vector(gid, r.resolved[gid])
	var i: int = r.projectiles.count - 1
	_check("a homing packet binds its target", r._proj_target[i], e)
	_check_true("and launches toward it", r.projectiles.vel[i].normalized().dot(Vector2.UP) > 0.99)
	r.free(); await process_frame
	finished["a_homing_packet_still_binds"] = true

func beam_hits_its_capsule_only() -> void:
	var r := await _fresh_run()
	var gid := _with(r, &"beam")
	var radius: float = r.resolved[gid].radius
	_face(r, Vector2.RIGHT)
	var far_end := _spawn(r, Vector2(radius - 1.0, 0.0))
	var corner := _spawn(r, Vector2(radius, r.BEAM_HALF_WIDTH + r.ENEMY_RADIUS - 1.0))
	var beside := _spawn(r, Vector2(radius * 0.5, r.BEAM_HALF_WIDTH + r.ENEMY_RADIUS + 20.0))
	var behind := _spawn(r, Vector2(-60.0, 0.0))
	var hit := _targets_hit(r, gid)
	_check("the far end is hit", far_end in hit, true)
	_check("the far-end corner at full offset is hit", corner in hit, true)
	_check("beside the beam is not", beside in hit, false)
	_check("behind is not", behind in hit, false)
	r.free(); await process_frame
	finished["beam_hits_its_capsule_only"] = true

func spike_hits_its_wedge_only() -> void:
	var r := await _fresh_run()
	var gid := _with(r, &"spike")
	_face(r, Vector2.DOWN)
	var ahead := _spawn(r, Vector2(0.0, 80.0))
	var behind := _spawn(r, Vector2(0.0, -80.0))
	var hit := _targets_hit(r, gid)
	_check("inside the wedge is hit", ahead in hit, true)
	_check("behind is not", behind in hit, false)
	r.free(); await process_frame
	finished["spike_hits_its_wedge_only"] = true

func beam_radius_floor_holds_in_the_tables() -> void:
	var bad := []
	for m in ModuleTable.all():
		if m.slot == Module.Slot.VECTOR and m.vector_kind == Module.VectorKind.BEAM \
				and float(m.stats.get(&"radius", 0.0)) < 31.0:
			bad.append(m.id)
	for rec in RecipeTable.all():
		if rec.fused.vector_kind == Module.VectorKind.BEAM \
				and float(rec.fused.stats.get(&"radius", 0.0)) < 31.0:
			bad.append(rec.fused.id)
	_check("every beam radius clears the query-cover floor of 31", bad, [])
	finished["beam_radius_floor_holds_in_the_tables"] = true
```
(If `Module` stores the kind under another property name than `vector_kind`, use that name; grep `scripts/build/module.gd`.)

- [ ] **Step 2: Run and watch them fail**

Run: `godot --headless -s res://tests/test_facing.gd 2>&1 | grep -E 'SCRIPT ERROR|FAIL|PASS'`
Expected: FAIL on packet direction/target, beam and spike cases; `BEAM_HALF_WIDTH` missing.

- [ ] **Step 3: Implement the forward arms**

Constants, next to `CONE_HALF_ANGLE`:

```gdscript
## Half-width of the beam capsule. The grid query around the capsule midpoint
## uses radius / 2 + BEAM_HALF_WIDTH and filters on centre distance; the
## farthest centre the keep test accepts is a far corner at perpendicular
## offset BEAM_HALF_WIDTH + ENEMY_RADIUS = 34, so the circle covers it iff
## radius / 2 + 22 >= sqrt((radius / 2)^2 + 34^2), i.e. radius >= 30.55.
## test_facing asserts every beam in the tables clears 31.
const BEAM_HALF_WIDTH := 22.0
```

Scratch, next to `var _buf: PackedInt32Array`:

```gdscript
## Beam selection scratch: the kept candidates and their projections, sized
## like _buf so the tick allocates nothing. Not simulation state.
var _beam_hits: PackedInt32Array
var _beam_keys: PackedFloat32Array
```
and where `_buf` is resized (grep `_buf.resize`), add `_beam_hits.resize(_buf.size()); _beam_keys.resize(_buf.size())`.

Rewrite the comment above the match (~2598-2601):

```gdscript
	# Before the match, deliberately. CHAIN returns early when it has no
	# target, and a defensive build on it must still ward — it has already spent
	# its cooldown by the time it reaches here, because _try_event_fire sets
	# _fire_cd before calling this. (BEAM and CONE no longer return early: they
	# fire along facing whether or not anything is there.)
```

BEAM arm:

```gdscript
		Module.VectorKind.BEAM:
			var dir: Vector2 = player_facing[owner]
			var mid := at + dir * r.radius * 0.5
			_fx.append([FxKind.BEAM, at, dir, r.radius, FX_LIFE, Color(2.2, 1.4, 2.6)])
			var n2 := grid.query_radius_into(mid, r.radius * 0.5 + BEAM_HALF_WIDTH, _buf, Grid.M_ENEMY)
			var kept := 0
			var band := BEAM_HALF_WIDTH + ENEMY_RADIUS
			for k in mini(n2, _buf.size()):
				var j := Grid.index_of(_buf[k])
				var rel := enemies.pos[j] - at
				var along := rel.dot(dir)
				if along < 0.0 or along > r.radius:
					continue
				if absf(rel.cross(dir)) > band:
					continue
				_beam_hits[kept] = j
				_beam_keys[kept] = along
				kept += 1
			# Select the pierce + 1 nearest by (projection, index): a total order,
			# so equal projections resolve the same on every peer. O(n x k).
			var want := mini(int(r.pierce) + 1, kept)
			for s2 in want:
				var best := s2
				for c in range(s2 + 1, kept):
					if _beam_keys[c] < _beam_keys[best] \
							or (_beam_keys[c] == _beam_keys[best] and _beam_hits[c] < _beam_hits[best]):
						best = c
				if best != s2:
					var tj := _beam_hits[s2]; _beam_hits[s2] = _beam_hits[best]; _beam_hits[best] = tj
					var tk := _beam_keys[s2]; _beam_keys[s2] = _beam_keys[best]; _beam_keys[best] = tk
				_hit(ei, r, _beam_hits[s2])
```

CONE arm:

```gdscript
		Module.VectorKind.CONE:
			# A broadcast query filtered by ANGLE around the owner's facing.
			var cdir: Vector2 = player_facing[owner]
			_fx.append([FxKind.WEDGE, at, cdir, r.radius, FX_LIFE, Color(2.0, 1.6, 0.8)])
			var cn := grid.query_radius_into(at, r.radius, _buf, Grid.M_ENEMY)
			for k in mini(cn, _buf.size()):
				var cj := Grid.index_of(_buf[k])
				var to_e := enemies.pos[cj] - at
				if to_e.length_squared() < 0.01:
					_hit(ei, r, cj)
					continue
				if absf(to_e.normalized().angle_to(cdir)) <= CONE_HALF_ANGLE:
					_hit(ei, r, cj)
```

Default (PACKET) arm: replace the target pick with

```gdscript
		_:
			# Along the owner's facing, no target pick — except a homing fused
			# module, which binds a target at spawn and launches TOWARD it: a
			# seeker launched away would spend most of its travel coming about.
			var t3 := -1
			var dir2: Vector2 = player_facing[owner]
			if r.homing > 0.0:
				t3 = _pick_target(VIEW_RANGE, r.targeting, at)
				if t3 >= 0:
					dir2 = (enemies.pos[t3] - at).normalized()
			_fx.append([FxKind.DASH, at, dir2, 26.0, FX_LIFE, Color(1.1, 1.7, 1.4)])
			var shots: int = maxi(int(r.split_count), 1)
```
and keep the rest of the arm as it is (`_proj_target[pi] = t3`, `_proj_target_gen[pi] = enemies.generation[t3] if t3 >= 0 else -1`). Until Task 7 lands, write the three `_fx.append` lines as the old `_fx_line.append([at, at + dir * r.radius, FX_LIFE, colour])` calls so the suite compiles; Task 7 converts them.

`tests/test_wards.gd:77-80` comment becomes: `## Wards apply at the TOP of _emit_vector, before the match, so a BEAM fired into empty ground still hardens. It spends its cooldown either way ...`.

- [ ] **Step 4: Run the suites**

Run `test_facing`, `test_wards`, `test_travel`, `test_dispatch`, `test_drain`, `test_run`, `test_plurality`, `test_manifest` through `grep -E 'SCRIPT ERROR|FAIL|PASS'`.
Expected: all PASS. If `test_manifest` reports `_beam_hits`/`_beam_keys` "in neither list", add to `NOT_IN_MANIFEST["run"]`: `"_beam_hits": "beam selection scratch, presentation-free but never carried", "_beam_keys": "beam selection scratch"`.

- [ ] **Step 5: Commit**

```bash
git add scripts/run/run.gd tests/test_facing.gd tests/test_wards.gd
git commit -m "feat: fire packet, beam and spike along the owner's facing"
```

---

### Task 5: Mines drop behind

**Files:**
- Modify: `scripts/run/run.gd` (MINE arm ~2657-2684, constants near `MINE_SPREAD` ~161)
- Modify: `tests/test_facing.gd`

- [ ] **Step 1: Add the failing cases**

```gdscript
func _mine_positions(r: Node2D, gid: int) -> Array:
	var before: int = r.projectiles.count
	r._emit_vector(gid, r.resolved[gid])
	var out := []
	for i in range(before, r.projectiles.count):
		out.append(r.projectiles.pos[i])
	return out

func mines_drop_behind_on_open_ground() -> void:
	var r := await _fresh_run()
	var gid := _with(r, &"landmine")
	var p: Vector2 = r.player_pos[r.local_slot]
	_face(r, Vector2.RIGHT)
	var one := _mine_positions(r, gid)
	_check("one mine lands MINE_DROP behind", one[0], p - Vector2.RIGHT * r.MINE_DROP)
	var ring := _with(r, &"landmine", [&"fork_bomb"])   # fork_bomb carries split_count on a mine? if not, set r.resolved[gid].split_count = 3.0 directly
	r.resolved[ring].split_count = 3.0
	var three := _mine_positions(r, ring)
	var nearest := INF
	for q in three:
		nearest = minf(nearest, (q - p).length())
	_check("a three-mine ring's nearest vertex is MINE_DROP - MINE_SPREAD behind",
		absf(nearest - (r.MINE_DROP - r.MINE_SPREAD)) < 0.5, true)
	for q in three:
		_check_true("every mine is behind the owner", (q - p).dot(Vector2.RIGHT) < 0.0)
	r.free(); await process_frame
	finished["mines_drop_behind_on_open_ground"] = true

func mines_avoid_a_wall() -> void:
	var r := await _fresh_run()
	var gid := _with(r, &"landmine")
	r.resolved[gid].split_count = 3.0
	var p: Vector2 = r.player_pos[r.local_slot]
	_face(r, Vector2.RIGHT)
	# Wall the ring's centre cell.
	var c: int = r.terrain.cell_index(p - Vector2.RIGHT * r.MINE_DROP)
	r.terrain.solid[c] = 1
	for q in _mine_positions(r, gid):
		_check("every mine lands on open ground", r.terrain.is_solid(q), false)
	r.free(); await process_frame
	finished["mines_avoid_a_wall"] = true
```
(Check `Terrain.solid`'s element type — PackedByteArray of 0/1 — and `cell_index` from `scripts/run/terrain.gd`.)

- [ ] **Step 2: Run and see them fail** — `MINE_DROP` undefined.

- [ ] **Step 3: Implement**

Constant next to `MINE_SPREAD`:

```gdscript
## How far behind the owner a mine drop is centred: MINE_SPREAD + 40, so a
## three-mine ring's nearest vertex sits exactly 40 behind. Running lays a
## trail behind you.
const MINE_DROP := 86.0
```

MINE arm:

```gdscript
		Module.VectorKind.MINE:
			var mines: int = maxi(int(r.split_count), 1)
			var back: Vector2 = player_facing[owner]
			var centre := at - back * MINE_DROP
			for sm in mines:
				var mat := centre
				if mines > 1:
					# The ring is rotated so one vertex lies on the facing axis
					# (nearest the owner), by complex multiply — no new
					# transcendental enters the tick.
					var v := Vector2(MINE_SPREAD, 0.0).rotated(TAU * float(sm) / float(mines))
					mat = centre + Vector2(v.x * back.x - v.y * back.y, v.x * back.y + v.y * back.x)
				# Behind the owner may be rock: every mine, single or ring,
				# goes through nearest_open.
				mat = terrain.nearest_open(mat)
				var mi := projectiles.spawn(mat, Vector2.ZERO, 1.0, PROJECTILE_RADIUS, 0)
				# ... the rest of the arm unchanged ...
```
Update the old comment ("the owner's position is always walkable, so a single mine never needed this") to say why every mine now does.

- [ ] **Step 4: Run `test_facing` and `test_effects`** — Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat: drop mines behind the owner"` (add `tests/test_facing.gd`).

---

### Task 6: The shield rearm at runtime

**Files:**
- Modify: `scripts/run/run.gd` (`_ward_left` declaration ~479 and its `resize` site; `_step2_integrate` aging ~2252; `_emit_vector` shield grant ~2605-2608; `STATE_FIELDS` line with `_ward_left` ~4976)
- Modify: `tests/test_facing.gd`

**Interfaces:**
- Consumes: `ResolvedExploit.shield_rearm` (Task 2).
- Produces: `_shield_left: PackedFloat32Array` per exploit gid, `SH` in the manifest.

- [ ] **Step 1: Add the failing cases**

```gdscript
func _fire_n(r: Node2D, gid: int, n: int) -> void:
	for _i in n:
		r.queue.begin_tick()
		r._emit_vector(gid, r.resolved[gid])

func the_checksum_payload_rearms_not_refires() -> void:
	var r := await _fresh_run()
	var gid := _with(r, &"packet", [&"checksum"])
	_fire_n(r, gid, 1)
	_check("the first fire grants the pool", r.player_shield[r.local_slot], 26.0)
	r.player_shield[r.local_slot] = 5.0          # spent under damage
	_fire_n(r, gid, 3)
	_check("further fires inside the rearm grant nothing", r.player_shield[r.local_slot], 5.0)
	r._shield_left[gid] = 0.0                    # the rearm elapsed
	_fire_n(r, gid, 1)
	_check("after the rearm it refills", r.player_shield[r.local_slot], 26.0)
	r.loadouts[r.local_slot].exploits[0].payloads[0].rank = 5
	r._recompile()
	_check("rank scales the pool", r.resolved[gid].shield, 130.0)
	_check("but not the rearm", r.resolved[gid].shield_rearm, 2.6)
	r.free(); await process_frame
	finished["the_checksum_payload_rearms_not_refires"] = true

func redundancy_grants_every_fire_unless_it_carries_checksum() -> void:
	var r := await _fresh_run()
	var rec: RecipeTable.Recipe = null
	for x in RecipeTable.all():
		if x.fused.id == &"redundancy":
			rec = x
	var gid := _with(r, &"", [], rec.fused)
	_fire_n(r, gid, 1)
	r.player_shield[r.local_slot] = 5.0
	_fire_n(r, gid, 1)
	_check("a bare redundancy row refills on every fire", r.player_shield[r.local_slot], 60.0)
	var t := ModuleTable.by_id()
	r.loadouts[r.local_slot].exploits[0].place(t[&"checksum"])
	r._recompile()
	_fire_n(r, gid, 1)
	r.player_shield[r.local_slot] = 5.0
	_fire_n(r, gid, 1)
	_check("with checksum on it, the row refills on the rearm instead", r.player_shield[r.local_slot], 5.0)
	r.free(); await process_frame
	finished["redundancy_grants_every_fire_unless_it_carries_checksum"] = true
```

- [ ] **Step 2: Run and see them fail** — `_shield_left` missing, second fire refills.

- [ ] **Step 3: Implement**

Declaration next to `_ward_left`: `var _shield_left: PackedFloat32Array` with the comment `## Seconds until this exploit may grant its shield pool again; 0 means now.` Resize it wherever `_ward_left` is resized (grep `_ward_left.resize`), to the same length.

Aging, right after the `_ward_left` loop in `_step2_integrate`:

```gdscript
	for si in _shield_left.size():
		if _shield_left[si] > 0.0 and _is_live(_owner_slot(si)):
			_shield_left[si] -= dt
```

Grant in `_emit_vector`:

```gdscript
	# A shielding exploit grants its pool on fire, capped rather than stacked
	# (shield folds by MAX). A pool with a rearm grants only when the rearm has
	# elapsed: it keeps a payload's shield off the host vector's cadence.
	if r.shield > 0.0 and (r.shield_rearm <= 0.0 or _shield_left[ei] <= 0.0):
		player_shield[owner] = maxf(player_shield[owner], r.shield)
		if r.shield_rearm > 0.0:
			_shield_left[ei] = r.shield_rearm
```

Manifest: `for prop in ["_fire_acc", "_fire_cd", "_ward_left", "_shield_left"]:`.

- [ ] **Step 4: Run `test_facing`, `test_manifest`, `test_wards`, `test_multiplayer_sim`** — Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat: gate the checksum shield on a per-exploit rearm"`.

---

### Task 7: One fx list, seven shapes

**Files:**
- Modify: `scripts/run/run.gd` (declarations ~479-511; `_age_fx` ~2444-2461; emit sites 2272, 2611, 2620, 2637, 2649, 2709, 2728, 2792, 3162; `_draw` fx loops ~4799-4812 and the orbiter/mine loop ~4689-4700; `NOT_IN_MANIFEST` ~5042-5043)
- Modify: `tests/test_run.gd:193-194, :204`, `tests/test_determinism_rules.gd:86-87, :99`, `tests/test_facing.gd`

**Interfaces:**
- Produces: `enum FxKind { RIPPLE, DASH, BOLT, BEAM, WEDGE, PULSE, BLAST }`, `_fx: Array` of `[kind, at, dir, radius, life, colour]`.

- [ ] **Step 1: Fix the two suites that seed the old list, and add the structural case**

`tests/test_run.gd:193-194` and `:204`, `tests/test_determinism_rules.gd:86-87` and `:99`: replace `r._fx_ring.append([Vector2.ZERO, 100.0, 1.0, Color.WHITE])` with `r._fx.append([r.FxKind.RIPPLE, Vector2.ZERO, Vector2.RIGHT, 100.0, 1.0, Color.WHITE])` and every `_fx_ring[0][2]` read with `_fx[0][4]`.

In `tests/test_facing.gd`:

```gdscript
## Every kind an emit site appends has a draw arm, and the emit-site counts
## per kind are pinned so a non-fire emitter (the arrival flash, the
## kernel_panic telegraph) cannot be dropped silently.
func every_emitted_fx_kind_is_drawn() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/run/run.gd")
	var draw_start := src.find("func _draw()")
	var draw_body := src.substr(draw_start, src.find("\nfunc ", draw_start + 10) - draw_start)
	var counts := {}
	var re := RegEx.new()
	re.compile("_fx\\.append\\(\\[FxKind\\.([A-Z]+)")
	for m in re.search_all(src):
		var k: String = m.get_string(1)
		counts[k] = counts.get(k, 0) + 1
		_check_true("FxKind.%s has a draw arm" % k, draw_body.contains("FxKind.%s:" % k))
	_check("emit sites per kind are as pinned",
		counts, {"RIPPLE": 2, "DASH": 1, "BOLT": 2, "BEAM": 1, "WEDGE": 1, "PULSE": 2, "BLAST": 1})
	finished["every_emitted_fx_kind_is_drawn"] = true
```

- [ ] **Step 2: Run `test_run` and see the SCRIPT ERROR on `_fx`.**

- [ ] **Step 3: Implement the list, the ageing and the emitters**

Replace the two declarations at ~510-511 with:

```gdscript
## Transient fire visuals, one list, one entry per fire — except CHAIN, which
## appends one BOLT per resolved link, and the two non-fire rings (an arrival
## flash, kernel_panic's telegraph). MINE and ORBIT fires append nothing: they
## show through the glyphs and the orbiter trail. An estimate for the reader,
## not a capacity (the Array is unbounded, aged by life): per LIVE slot about
## 3 exploits x max(FIRE_BUDGET, BURST_MAX) x (max chain_count + 1) entries.
## Entry: [kind, at, dir, radius, life, colour]. `dir` is a unit facing with
## `radius` the length for DASH, BEAM and WEDGE, and the full link OFFSET
## (to - from) for BOLT.
enum FxKind { RIPPLE, DASH, BOLT, BEAM, WEDGE, PULSE, BLAST }
var _fx: Array = []
```

`_age_fx`: one loop over `_fx` decrementing index 4 and removing at `<= 0.0`.

Emit sites:
- 2272 arrival: `_fx.append([FxKind.RIPPLE, enemies.pos[i], Vector2.RIGHT, 40.0, FX_LIFE * 5.0, Color(2.4, 2.2, 2.0)])`
- 2611 broadcast: `_fx.append([FxKind.RIPPLE, at, Vector2.RIGHT, r.radius, FX_LIFE, Color(0.5, 1.7, 1.1)])`
- 2620/2637 beam/cone and the packet DASH: as written in Task 4.
- 2649 bounce: `_fx.append([FxKind.PULSE, at, Vector2.RIGHT, r.radius, FX_LIFE * 1.6, Color(0.9, 1.4, 2.2)])`
- 2709 / 2728 chain: `_fx.append([FxKind.BOLT, at, enemies.pos[t2] - at, 0.0, FX_LIFE, Color(1.0, 2.2, 1.6)])` and `_fx.append([FxKind.BOLT, from, enemies.pos[picked] - from, 0.0, FX_LIFE, Color(1.0, 2.2, 1.6)])`
- 2792 detonate: `_fx.append([FxKind.BLAST, projectiles.pos[i], Vector2.RIGHT, radius, FX_LIFE * 1.5, Color(2.2, 1.2, 0.5)])`
- 3162 pulse: `_fx.append([FxKind.PULSE, enemies.pos[i], Vector2.RIGHT, 700.0, FX_LIFE * 8.0, Color(2.2, 0.5, 0.4)])`

`NOT_IN_MANIFEST["run"]`: replace the `_fx_line`/`_fx_ring` entries with `"_fx": "presentation"`.

- [ ] **Step 4: Draw the seven shapes**

Replace the two loops in `_draw` (~4799-4812) with one dispatch. Use `var f: float = fx[4] / FX_LIFE` clamped to `[0, 1]` for fade where the entry's life started at FX_LIFE, and `fx[4] / (FX_LIFE * n)` for the longer-lived rings (store the initial life as a 7th element if you prefer; simplest: compute `f = clampf(fx[4] / FX_LIFE, 0.0, 1.0)`).

```gdscript
	for fx in _fx:
		var kind: int = fx[0]
		var at: Vector2 = fx[1]
		var dir: Vector2 = fx[2]
		var rad: float = fx[3]
		var f: float = clampf(fx[4] / FX_LIFE, 0.0, 1.0)
		var c: Color = fx[5]
		match kind:
			FxKind.RIPPLE:
				_draw_ring(at, rad * (1.0 - f * 0.25), Color(c.r, c.g, c.b, f * 0.85), 1.0 + 2.0 * f)
				_draw_ring(at, rad * (0.7 - f * 0.25), Color(c.r, c.g, c.b, f * 0.45), 1.0)
			FxKind.DASH:
				draw_line(to_iso(at + dir * 8.0), to_iso(at + dir * rad), Color(c.r, c.g, c.b, f), 1.0 + 3.0 * f)
			FxKind.BOLT:
				var pts := PackedVector2Array()
				var seg := 6
				var n := Vector2(-dir.y, dir.x).normalized()
				for k in seg + 1:
					var t := float(k) / float(seg)
					var jitter := sin(t * 11.0 + float(k) * 2.3) * 7.0 * (1.0 if k > 0 and k < seg else 0.0)
					pts.append(to_iso(at + dir * t + n * jitter))
				draw_polyline(pts, Color(c.r, c.g, c.b, f), 1.0 + 2.0 * f)
			FxKind.BEAM:
				var n2 := Vector2(-dir.y, dir.x)
				var w := BEAM_HALF_WIDTH * f
				var quad := PackedVector2Array([to_iso(at + n2 * w), to_iso(at + dir * rad + n2 * w),
					to_iso(at + dir * rad - n2 * w), to_iso(at - n2 * w)])
				draw_colored_polygon(quad, Color(c.r, c.g, c.b, 0.18 * f))
				draw_line(to_iso(at), to_iso(at + dir * rad), Color(c.r, c.g, c.b, f), 1.0 + 1.5 * f)
			FxKind.WEDGE:
				var pts2 := PackedVector2Array([to_iso(at)])
				for k in 13:
					var a := dir.angle() - CONE_HALF_ANGLE + 2.0 * CONE_HALF_ANGLE * float(k) / 12.0
					pts2.append(to_iso(at + Vector2(cos(a), sin(a)) * rad))
				draw_colored_polygon(pts2, Color(c.r, c.g, c.b, 0.22 * f))
			FxKind.PULSE:
				_draw_ring(at, rad * (1.0 - f * 0.25), Color(c.r, c.g, c.b, f * 0.85), 1.0 + 2.0 * f)
				for k in 8:
					var a2 := TAU * float(k) / 8.0
					var sp := Vector2(cos(a2), sin(a2))
					draw_line(to_iso(at + sp * rad * (0.55 - 0.3 * f)), to_iso(at + sp * rad * (0.85 - 0.3 * f)),
						Color(c.r, c.g, c.b, f * 0.7), 1.0)
			FxKind.BLAST:
				_draw_ring(at, rad * (1.0 - f * 0.25), Color(c.r, c.g, c.b, f * 0.85), 1.0 + 2.0 * f)
				for k in 10:
					var a3 := TAU * float(k) / 10.0 + 0.3
					var sp2 := Vector2(cos(a3), sin(a3))
					draw_line(to_iso(at + sp2 * rad * 0.3), to_iso(at + sp2 * rad * (0.5 + 0.5 * (1.0 - f))),
						Color(c.r, c.g, c.b, f * 0.6), 1.0)
```
with a helper:

```gdscript
func _draw_ring(centre: Vector2, radius: float, colour: Color, width: float) -> void:
	var pts := PackedVector2Array()
	for k in 33:
		var a := TAU * k / 32.0
		pts.append(to_iso(centre + Vector2(cos(a), sin(a)) * radius))
	draw_polyline(pts, colour, width)
```

Orbiter trails and the legacy loop: delete the `for i in projectiles.count: if _orbit_left[i] > 0.0 ... elif _mine_left[i] > 0.0 ...` loop (glyphs carry mines and orbiters after Task 8) and replace it with the trail:

```gdscript
	# Orbiter trails, drawn from RENDER positions so the arc and the glyph
	# agree at every frame fraction.
	for i in projectiles.count:
		if _orbit_left[i] <= 0.0:
			continue
		var owner_slot := _owner_slot(_proj_owner[i])
		if owner_slot < 0:
			continue
		var centre := player_render_pos[owner_slot]
		var here := _rp(projectiles, i)
		var arm := here - centre
		var pts := PackedVector2Array()
		for k in 7:
			pts.append(to_iso(centre + arm.rotated(-0.09 * float(k))))
		draw_polyline(pts, Color(0.5, 1.6, 1.2, 0.35), 1.5)
```

- [ ] **Step 5: Run `test_facing`, `test_run`, `test_determinism_rules`, `test_manifest`, `test_audio_events`** — Expected: PASS.

- [ ] **Step 6: Commit** — `git commit -am "feat: one fx list with a shape per vector kind"` (add the test files).

---

### Task 8: Projectile glyphs and the facing tick

**Files:**
- Modify: `shaders/glyph.gdshader` (add arms for `g == 14` and `g == 15` before the final `else`; fix the comment at line 66)
- Modify: `scripts/run/run.gd` (`_prime_constant_instances` comment and the `_mm_proj` prime call ~4385-4405; `_update_renderers` projectile loop ~4455-4459; player draw ~4878-4900)
- Modify: `tests/test_draw_order.gd` (the player draw list case, if it asserts glyph or tick details — read it first)

- [ ] **Step 1: Shader arms**

Before the final `} else {` add:

```glsl
	} else if (g == 14) {
		// packet — a period
		a = 1.0 - smoothstep(0.14, 0.22, length(p));
	} else if (g == 15) {
		// orbiter — a small ring
		a = ring(length(p), 0.26, 0.09);
```
Line 66 comment: `// probe — a boxed sight, distinct from the mine plus and the packet dot`.

- [ ] **Step 2: Renderer**

Comment on `_prime_constant_instances`: `## Only enemies and projectiles need per-frame colour and glyph ... Shards and botnet nodes are one colour and one glyph for the life of the pool ...`. Delete the `_prime_constant_instances(_mm_proj, 4.0, Color(1.1, 1.7, 1.4))` call.

Projectile loop in `_update_renderers`:

```gdscript
	mm = _mm_proj.multimesh
	mm.visible_instance_count = projectiles.count
	# Glyph and colour per frame: spawn happens inside the tick, which may not
	# touch a renderer node, and slots recycle, so a once-only stamp would need
	# per-instance memory. Bounded by MAX_PROJECTILES.
	var beat := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006)
	for i in projectiles.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0,
			to_iso(_rp(projectiles, i))))
		var glyph := 14.0
		var col := Color(1.1, 1.7, 1.4)
		if _mine_left[i] > 0.0:
			glyph = 4.0
			col = Color(2.0, 1.1, 0.4).lerp(Color(2.2, 1.3, 0.5), beat)
		elif _orbit_left[i] > 0.0:
			glyph = 15.0
			col = Color(0.7, 2.0, 1.5)
		mm.set_instance_custom_data(i, Color(glyph, 0.0, 0.0, 0.0))
		mm.set_instance_color(i, col)
```
(Check that `_make_mm` sets `use_colors = true` and `use_custom_data = true`; it does for enemies.)

- [ ] **Step 3: The facing tick**

In the player draw loop after `draw_arc(...)`:

```gdscript
		var tip := to_iso(player_render_pos[ps] + player_facing[ps] * (PLAYER_RADIUS + 9.0))
		var rim := to_iso(player_render_pos[ps] + player_facing[ps] * PLAYER_RADIUS)
		draw_line(rim, tip, Color(c.r, c.g, c.b, a), 2.0)
```
Rewrite the comment above ("the movement has no facing") to: `# The facing tick on the rim shows where forward weapons fire — facing follows the last non-zero movement.`

- [ ] **Step 4: Run `test_draw_order`, `test_hud`, `test_input`, `test_interpolation`** — Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat: packet dot, mine plus and orbiter ring glyphs, and the facing tick"`.

---

### Task 9: The stationary-player sweep

**Files:**
- Modify: `tests/test_triggers.gd:44-52, :84-92`, `tests/test_corruption.gd:25-29`; possibly `tests/test_drain.gd`, `tests/test_manifest.gd`, `tests/test_plurality.gd`, `tests/test_run.gd`

- [ ] **Step 1: Run the nine class-(b) suites**

Run each through `grep -E 'SCRIPT ERROR|FAIL|PASS'`: `test_arrivals test_corruption test_dispatch test_drain test_manifest test_plurality test_run test_travel test_triggers`.

- [ ] **Step 2: Judge by assertion polarity, not by pass/fail**

For each POSITIVE assertion that depended on the default packet connecting (a kill, a hit, a fire, a flip), either face the fixture's enemies for one tick before the assertion or move them to +X. Known:

`tests/test_triggers.gd` (both ring fixtures): before the loop that asserts fires, add
```gdscript
	run.input_override = Vector2(1.0, 0.0)
	run._physics_process(DT)
	run.input_override = Vector2.ZERO
```
The ring has an enemy at +X, so facing right connects.

`tests/test_corruption.gd:25-29`:
```gdscript
	run.input_override = Vector2.ZERO
	var t := 0
	while run.enemies.count == 0 and t < 600:       # warm up until the director has spawned
		run._physics_process(DT); t += 1
	var nearest := -1
	var best := INF
	for i in run.enemies.count:
		var d: float = run.enemies.pos[i].distance_squared_to(run.player_pos[run.local_slot])
		if d < best:
			best = d; nearest = i
	if nearest >= 0:
		run.input_override = (run.enemies.pos[nearest] - run.player_pos[run.local_slot]).normalized()
		run._physics_process(DT); t += 1
		run.input_override = Vector2.ZERO
	while t < 3600 and run.alive:
```
If `flips` still reads 0 after the run, replace the director's spawns with a deterministic ring at +X (spawn twelve daemons at `player_pos + Vector2(120, 0) + small offsets`) and re-run.

- [ ] **Step 3: Run all nine again** — Expected: PASS with positive assertions still meaningful (read each changed assertion once more).

- [ ] **Step 4: Commit** — `git commit -am "test: face the swarm in stationary fixtures the default packet must connect in"`.

---

### Task 10: The perf gate

**Files:**
- Modify: `tests/perf_milestone0.gd` (header 10-18; `_real_run` 187-250; `_kite` 254-299)

- [ ] **Step 1: Record the baselines BEFORE the game changes — three measurements**

The pin's baseline is the NEW fixture on the OLD tree, so fixture changes and game changes are attributed separately. Do this task's fixture edits (Steps 1 and 2) on a scratch checkout of `main` (or `git stash` the game changes), run the gate there for the pin's baseline, and also note today's unchanged-fixture numbers for the header; then run the new fixture on this branch in Step 3.

First make the gate print what the pin needs. Today the loop runs while `g.alive`, which is true whenever ANY slot is LIVE; slots 1-3 are force-LIVE every tick, so a dead slot 0 never ends the run. Change the loop condition to end on slot 0 and replace the `print("    %s at %.0fs, peak enemies %d" ...)` line in `_real_run` with

```gdscript
	while t < 24000 and g.slot_state[0] == g.SlotState.LIVE and not g.won:
```
(replacing `while t < 24000 and g.alive and not g.won`), and after the loop:
```gdscript
	var outcome := "won" if g.won else ("died" if g.slot_state[0] != g.SlotState.LIVE else "timeout")
	var ticks := maxf(float(t), 1.0)
	var total_kills := 0
	for s in SessionRules.MAX_PLAYERS:
		total_kills += g.kills[s]
	print("    %s at tick %d (%.0fs), mean live enemies %.1f, mean hits/tick %.2f, kills/tick %.3f, at cap %.0f%% of ticks" % [
		outcome, t, t * DT, _enemy_sum / ticks, _hit_sum / ticks, float(total_kills) / ticks, 100.0 * _cap_ticks / ticks])
```
and inside the loop, after `g._physics_process(DT)`, add
```gdscript
		_enemy_sum += float(g.enemies.count)
		_hit_sum += float(g.queue.count)          # hits adjudicated this tick
		if g.enemies.count >= g.MAX_ENEMIES:
			_cap_ticks += 1.0
```
with `var _enemy_sum := 0.0`, `var _hit_sum := 0.0`, `var _cap_ticks := 0.0` at file scope, zeroed at the top of `_real_run`. Three load statistics because they move in different directions: a lighter field lowers the enemy mean; a weaker or blind-aimed build lowers the hit and kill means while raising the enemy mean; a dead slot 0 lowers kills.

Run: `godot --headless -s res://tests/perf_milestone0.gd 2>&1 | grep -E 'at tick|PASS|FAIL|INCONCLUSIVE'`
On this branch the baseline is a TIMEOUT at tick 24000 (measured during review: p95 9.09 ms against a 9.61 ms budget, about five percent headroom). Write the outcome, the tick, the mean live enemies, the mean hits per tick and the kills per tick from the NEW-fixture-on-OLD-tree run into the constants below (the at-cap fraction and today's old-fixture numbers go in the comment only).

- [ ] **Step 2: Rows, pinned facing, the kite and the pin**

Loadout rows in `_real_run`: after the loop that builds the three rows, replace the broadcast row on slots 2 and 3 with beam:

```gdscript
	for s in [2, 3]:
		var lo2: Loadout = g.loadouts[s]
		var exb := Exploit.new()
		exb.place(tbl[&"beam"])
		exb.place(tbl[&"on_hit"])
		exb.vector.rank = 5
		lo2.exploits[1] = exb          # the broadcast row; the homer on row 2 stays
```

Pinned records: replace `g.lockstep.submit(s, g.lockstep.executed, Vector2.ZERO, c.x, c.y, c.z)` with a rotating unit vector so pinned facing sweeps on all three pinned slots (positions are force-written each tick, so the drift is erased; `player_vel` becomes non-zero on those slots, which `_flank` and `_fire_hostile` read, and they take the movement branch inside the timed region — accepted, and said in the fixture comment):

```gdscript
			var spin := TAU * float(t) / 600.0
			g.lockstep.submit(s, g.lockstep.executed, Vector2(cos(spin), sin(spin)), c.x, c.y, c.z)
```

Party geometry — slot 0 sits at a corner of the leash box today and cannot flee toward negative x or y. Change `PARTY_OFFSETS` to put it in the centre while keeping the full 4000 span on both axes:

```gdscript
const PARTY_OFFSETS := [Vector2.ZERO, Vector2(2000.0, 2000.0),
	Vector2(-2000.0, 2000.0), Vector2(2000.0, -2000.0)]
```

Kite state and hysteresis — add fixture vars and reset them at the top of `_real_run`:

```gdscript
var _kite_fleeing := false
var _kite_hold := 0
const KITE_FLEE_IN := 120.0
const KITE_FLEE_OUT := 190.0
const KITE_NUDGE_EVERY := 37
```

`_kite`:

```gdscript
func _kite(g: Node2D) -> Vector2:
	# The CLEARED branch stays FIRST and unconditional: a cleared subnet has
	# nothing inside 120, and a kite that held there would never reach the gate.
	if g.phase == g.Phase.CLEARED:
		var gate = g.terrain.gate()
		if gate != null and gate.open:
			return _around_walls(g, (gate.end - g.player_pos[g.local_slot]).normalized())
	var me: Vector2 = g.player_pos[g.local_slot]
	var nearest := -1
	var nd := INF
	for i in g.enemies.count:
		var d: float = me.distance_to(g.enemies.pos[i])
		if d < nd:
			nd = d; nearest = i
	# Hysteresis: flee while inside KITE_FLEE_IN until back out past
	# KITE_FLEE_OUT, then nudge toward the swarm once and HOLD facing with zero
	# records. Facing is the last non-zero record, so the hold is what keeps
	# slot 0's forward weapons pointed at the swarm between bursts.
	# The flee sum over everything within KITE_FLEE_OUT; its negative is the
	# swarm's mass, which is where a nudge should face (the nearest single
	# enemy can be a straggler off to one side at cap).
	var flee := Vector2.ZERO
	var k := 0
	for i in g.enemies.count:
		var d: Vector2 = me - g.enemies.pos[i]
		var dl := d.length()
		if dl < KITE_FLEE_OUT and dl > 0.01:
			flee += d / dl * (KITE_FLEE_OUT - dl)
			k += 1
	if _kite_fleeing and nd > KITE_FLEE_OUT:
		_kite_fleeing = false
		_kite_hold = 0
		return _nudge(g, flee, k, nearest)
	if not _kite_fleeing and nd < KITE_FLEE_IN:
		_kite_fleeing = true
	if _kite_fleeing:
		var dir := flee.normalized() if k > 0 else Vector2.ZERO
		var c: Vector2 = g.terrain.arena().get_center() - me
		if c.length() > 1100.0:
			dir = (dir + c.normalized() * 1.6).normalized()
		return _around_walls(g, dir)
	_kite_hold += 1
	if _kite_hold >= KITE_NUDGE_EVERY:
		_kite_hold = 0
		return _nudge(g, flee, k, nearest)
	return Vector2.ZERO

## One tick toward the swarm's mass (the negative flee sum), else toward the
## nearest enemy, else nothing. NOT through _around_walls: this is a facing
## intent, its step is rejected by terrain.slide against rock anyway, and a
## wall-deflected nudge would face away from the swarm.
func _nudge(g: Node2D, flee: Vector2, k: int, nearest: int) -> Vector2:
	if k > 0 and flee.length_squared() > 0.000001:
		return (-flee).normalized()
	if nearest < 0:
		return Vector2.ZERO
	return (g.enemies.pos[nearest] - g.player_pos[g.local_slot]).normalized()
```

The pin — constants from Step 1 and an assertion after the loop:

```gdscript
## The fixture's end and load before the weapons pass, recorded so the gate
## cannot get lighter by dying sooner OR by surviving a thinner field: a
## baseline WIN requires a win; a baseline death at tick N requires surviving
## at least 90% of N (declared slack: the run is deterministic but chaotic);
## a baseline TIMEOUT (the 24000-tick cap, which is what this branch measured)
## requires the cap or a win; and BOTH load means — live enemies and hits
## per tick — must reach 97% of the baseline's. The run is seeded with no
## run-to-run variance, so 3% is not noise: it is the allowance for this
## pass's behavioural drift, kept below the gate's 5.4% p95 headroom. Order:
## pin from the pre-change run, pass the post-change fixture against it, only
## then move the constants — outcome upward only; each load baseline upward,
## or downward with a written reason here. A fall below any floor needs a
## stated reason, never a re-pin. Both values stay in this comment so the
## delta is visible. If the gate comes back HEAVIER (blind-aimed pinned slots
## mean a fuller field), profile and optimise; never thin the fixture or
## lower the budget.
##   pre-pass  (2026-09-02): timeout at 24000, mean live enemies <from Step 1>
##   post-pass:              (written in Step 3 of this task, after the gate runs)
const BASELINE_OUTCOME := "timeout"   # "won", "died" or "timeout" — from Step 1
const BASELINE_END_TICK := 24000      # from Step 1
const BASELINE_MEAN_ENEMIES := 0.0    # from Step 1
const BASELINE_MEAN_HITS := 0.0       # from Step 1
const BASELINE_KILLS_PER_TICK := 0.0  # from Step 1
```
and after the loop (replacing the print added in Step 1's edit):
```gdscript
	var outcome := "won" if g.won else ("died" if g.slot_state[0] != g.SlotState.LIVE else "timeout")
	var ticks := maxf(float(t), 1.0)
	var mean_enemies := _enemy_sum / ticks
	var mean_hits := _hit_sum / ticks
	var total_kills := 0
	for s in SessionRules.MAX_PLAYERS:
		total_kills += g.kills[s]
	var kills_per_tick := float(total_kills) / ticks
	print("    %s at tick %d (%.0fs), mean live enemies %.1f, mean hits/tick %.2f, kills/tick %.3f, at cap %.0f%% of ticks" % [
		outcome, t, t * DT, mean_enemies, mean_hits, kills_per_tick, 100.0 * _cap_ticks / ticks])
	var covered := true
	if BASELINE_OUTCOME == "won":
		covered = outcome == "won"
	elif BASELINE_OUTCOME == "died":
		covered = outcome != "died" or t >= int(float(BASELINE_END_TICK) * 0.9)
	elif BASELINE_OUTCOME == "timeout":
		covered = outcome != "died"
	if mean_enemies < BASELINE_MEAN_ENEMIES * 0.97 or mean_hits < BASELINE_MEAN_HITS * 0.97 \
			or kills_per_tick < BASELINE_KILLS_PER_TICK * 0.97:
		covered = false
	_gate_covered = covered
```
with `var _gate_covered := true` at file scope, and in `_initialize`, right after the `_gate_drops > 0` check and BEFORE the `scale > MAX_CONTENTION` branch (a loaded machine must not turn a coverage regression into PASS-by-INCONCLUSIVE). The gate also refuses an unpopulated baseline, so the pin cannot be vacuous by omission — put this first:
```gdscript
	if BASELINE_MEAN_ENEMIES <= 0.0 or BASELINE_MEAN_HITS <= 0.0 or BASELINE_KILLS_PER_TICK <= 0.0 or BASELINE_END_TICK <= 0:
		print("  FAIL — the coverage baseline is not pinned; run the gate on the pre-change tree and record it (Task 10, Step 1).")
		quit(1)
		return
	if not _gate_covered:
		print("  FAIL — the fixture measured less than its baseline (%s at %d, mean enemies %.1f, mean hits %.2f, kills/tick %.3f): a coverage regression, not a speedup." % [BASELINE_OUTCOME, BASELINE_END_TICK, BASELINE_MEAN_ENEMIES, BASELINE_MEAN_HITS, BASELINE_KILLS_PER_TICK])
		quit(1)
		return
```
If the hysteresis kite dies before the cap (standing still lets ranged shots connect that the always-moving kite dodged, and a ring closing from every bearing can cancel the flee sum), widen the band — `KITE_FLEE_IN` 150 first, then toward 190 — and if that is not enough also enter the flee state whenever an enemy within 300 units is in `CH_WINDUP` or `CH_DASH` (read `_ai_phase` for CHARGER enemies; a sentinel's dash lands 21 units short of a stationary target), until the run reaches the cap again, and record the values in the constants' comment. If p95 comes back OVER budget on a fuller field, that is coverage: profile the beam selection (k up to 56) and optimise; do not thin the fixture or touch `BUDGET_MS`.
(If `quit` inside `_real_run` is awkward, return an empty array and let the caller fail on it.) Rewrite the header's packet-query sentence to name the beam capsule and the homing rows as the load.

- [ ] **Step 3: Run the gate** — `godot --headless -s res://tests/perf_milestone0.gd 2>&1 | tail -12`. Expected: PASS within budget and the coverage assertion holding. If INCONCLUSIVE, rerun on a quiet machine. Write the post-pass outcome, tick and mean enemies into the constants' comment beside the pre-pass values. Headroom is about five percent, so if p95 is over budget, profile the beam selection first (k up to 56) before touching anything else.

- [ ] **Step 4: Commit** — `git commit -am "test: measure turning beams on the perf gate and pin its coverage"`.

---

### Task 11: The shot tool, docs, codemaps and the full gate

**Files:**
- Modify: `tools/shot_fx.gd`, `codemaps/*.md` (regenerate), `CLAUDE.md`, `site/` (regenerate)

- [ ] **Step 1: Rewrite `tools/shot_fx.gd` on a three-slot session**

Build a three-slot descriptor the way `tests/support/multiplayer_harness.gd` does, instantiate one run with `configure_session(NetworkSession.create(desc, 0, NetworkSession.Role.HOST))`, give slot 0 `packet/broadcast/chain`, slot 1 `beam/spike/bounce`, slot 2 `landmine/mirror` (each row with `interval`), spread the slots 260 units apart along +X, submit neutral records for slots 1 and 2 every frame (as the perf gate does), spawn the tough ring around each slot, and capture the first frame after frame 60 where `run._fx.size() > 0`. Keep the headless guard at the top. Print `fx=%d` instead of lines/rings.

- [ ] **Step 2: Regenerate docs**

Run `python3 tools/build_manual.py`. Regenerate `codemaps/` with the `cc-codemaps:update-codemaps` skill (do not hand-edit them); `data.md` names the removed rows today.

- [ ] **Step 3: Full gate**

Run `tools/run_tests.sh` with the Bash sandbox disabled (the loopback suite needs UDP). Expected: `ALL GREEN — 53 suites` and the perf gate PASS. Then `godot --headless -s res://tools/determinism_probe.gd -- --ticks 120 | md5` twice; the two digests must match.

- [ ] **Step 4: Commit and hand the windowed checks to the user**

```bash
git add -A
git commit -m "docs: record the weapons pass"
```
Windowed, for the user: `godot -s res://tools/shot_fx.gd` and a real run to judge the eight shapes, the three glyphs and the facing tick.

---

## Self-review notes

Spec coverage: §1 facing → Task 1 and Task 8 (tick); §2 vectors → Tasks 4, 5, 2 (cut, checksum, rearm stat), 6 (rearm runtime); §3 recipes → Task 3; §4 animations → Tasks 7 and 8; §5 testing and sweep → Tasks 1, 4-7 (test_facing), 9 (stationary sweep), 10 (perf gate), 11 (shot tool, codemaps, gate). Every `_fx.append` site count in Task 7's pinned table matches the spec's emitter mapping (RIPPLE: arrival + broadcast; PULSE: bounce + kernel_panic; BLAST: detonate; BOLT: two chain sites; DASH, BEAM, WEDGE one each).
