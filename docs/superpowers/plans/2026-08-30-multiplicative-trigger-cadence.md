# Multiplicative Trigger Cadence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a TRIGGER's effect on rate of fire proportional to the weapon it is attached to, so a vector's cadence identity survives whatever is bolted onto it.

**Architecture:** Triggers and cooldown-modifying payloads stop contributing flat seconds and start contributing a `cadence_mult` folded by multiplication. Vectors become the sole source of `cooldown`. The cooldown floor becomes proportional to the vector's own base, so ratios hold even when it binds. Four `validate()` rules enforce the two data preconditions the guarantee rests on.

**Tech Stack:** Godot 4.7 stable, GDScript. Tests are `SceneTree` scripts run headless.

**Spec:** `docs/superpowers/specs/2026-08-30-multiplicative-trigger-cadence-design.md` (revision 4)

## Global Constraints

- **Godot 4.7 stable, GDScript only.** No new dependencies, no image assets.
- **`scripts/build/` stays pure** — no scene tree, no globals.
- **No `run.gd` changes.** Every consumer of `r.cooldown` reads the resolved float; this was verified across the whole suite.
- `MIN_CADENCE_FRACTION = 0.12`, declared in `compiler.gd` beside `MIN_COOLDOWN`.
- The four `cadence_mult` values are **`interval` 0.85, `on_hit` 1.30, `on_kill` 1.52, `overclock` 0.82**. `on_damage_taken` carries none.
- Test command: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/<name>.gd`
- **Baseline: all 16 test files pass on `main` today.** Do not start from a red tree.

---

## The one ordering constraint that matters

**Task 3 cannot be split.** The `validate()` rule "only a VECTOR may carry `cooldown`" errors on the *current* table for exactly the four modules being converted, and `data_sweep` (`tests/test_build.gd:50`) asserts zero errors over `ModuleTable.all()`. Landing the rules before the conversion turns the suite red with four confusing data errors; landing the proportional floor before the conversion computes `vector_base` from a cooldown that triggers are still polluting.

Tasks 1 and 2 are deliberately **inert** — they add machinery nothing carries yet, so each ends green. Task 3 is the switch.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `scripts/build/module.gd` | `cadence_mult` joins `STAT_KEYS` (16 → 17) | 1 |
| `scripts/build/resolved_exploit.gd` | `cadence_mult` field (defaults 1.0), `equals`, `base_cooldown` docstring | 1 |
| `scripts/build/compiler.gd` | `_rank_factor`, `MUL_FOLD_KEYS`, the fold branch, `MIN_CADENCE_FRACTION`, the floor, four `validate()` rules | 2, 3 |
| `data/module_table.gd` | four modules converted to `cadence_mult` | 3 |
| `tests/test_build.gd` | two broken tests rewritten, `EXPECTED_CHECKS` guard | 3 |
| `tests/test_multipliers.gd` | `:117-118` rewritten against the proportional floor | 3 |
| `tests/test_cadence.gd` | **new** — the ratio property, rank asymmetry, all four rules | 4 |
| `scripts/run/ui.gd` | `_stats_line` per-key formatter | 5 |

---

### Task 1: `cadence_mult` exists and is inert

**Files:**
- Modify: `scripts/build/module.gd` (`STAT_KEYS`)
- Modify: `scripts/build/resolved_exploit.gd` (field, `equals`, `base_cooldown` docstring)

**Interfaces:**
- Consumes: nothing
- Produces: `ResolvedExploit.cadence_mult: float = 1.0`; `Module.STAT_KEYS` has 17 entries

- [ ] **Step 1: Write the failing test**

Add to `tests/test_build.gd` and register in `_init()`:

```gdscript
## cadence_mult is the only STAT_KEY that does not default to zero, because it
## accumulates by product. Anything that resets fields generically, or assumes a
## zero default, breaks quietly on it — so the default is pinned by a test.
func cadence_mult_defaults_to_one() -> void:
	var r := ResolvedExploit.new()
	_check("cadence_mult defaults to 1.0", r.cadence_mult, 1.0)
	_check("cadence_mult is a legal stat key", &"cadence_mult" in Module.STAT_KEYS, true)
	_check("STAT_KEYS is 17", Module.STAT_KEYS.size(), 17)
	var zero_defaults := 0
	for k in Module.STAT_KEYS:
		if float(r.get(k)) == 0.0:
			zero_defaults += 1
	_check("every OTHER stat key defaults to zero", zero_defaults, 16)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_build.gd`

Expected: failure. `r.cadence_mult` is a direct access on a property that does not exist yet, so this fails at parse or load rather than as a clean assertion — the exact message is `Invalid access to property or key 'cadence_mult'` or an unresolved-identifier parse error, depending on inference. Either is a valid red; do not spend time making it a tidy assertion failure first.

- [ ] **Step 3: Add the key and the field**

In `scripts/build/module.gd`, append to `STAT_KEYS`:

```gdscript
	&"travel", &"cadence_mult",
```

In `scripts/build/resolved_exploit.gd`, beside `base_cooldown`:

```gdscript
## How much the TRIGGER and cooldown-modifying PAYLOADs scale the vector's base
## cadence. Multiplicative, so it initialises to 1.0 rather than 0.0 — the only
## stat key on this struct that does not default to zero.
var cadence_mult: float = 1.0
```

Add `cadence_mult` to the `equals()` comparison chain.

Rewrite `base_cooldown`'s docstring. Two of its current claims stop being true:

```gdscript
## The folded cooldown AFTER the cadence product but before `haste` and before
## either floor.
##
## It cannot go negative any more: cooldown is now a product of positives, so the
## old "May be NEGATIVE ... folds to -0.25" warning described a case that can no
## longer occur.
##
## The proportional floor IS reconstructible from this struct —
## `vector_base = base_cooldown / cadence_mult`, and validate() bounds that
## divisor away from zero — so the field still serves its original purpose. It
## has no readers today beyond equals(), and deleting it is a reasonable separate
## call; that is an argument from zero usage, not from lost information.
var base_cooldown: float = 0.0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_build.gd`
Expected: `PASS — all cases`. Nothing carries `cadence_mult` yet, so no behaviour changed.

- [ ] **Step 5: Commit**

```bash
git add scripts/build/module.gd scripts/build/resolved_exploit.gd tests/test_build.gd
git commit -m "feat: cadence_mult stat key, inert

The only STAT_KEY that does not default to zero, because it accumulates by
product. Nothing carries it yet. base_cooldown's docstring is corrected: it can
no longer go negative, and the proportional floor IS reconstructible from the
struct via base_cooldown / cadence_mult."
```

---

### Task 2: the fold folds it, still inert

**Files:**
- Modify: `scripts/build/compiler.gd` (`MIN_CADENCE_FRACTION`, `MUL_FOLD_KEYS`, `_rank_factor`, the fold branch)
- Modify: `tests/test_build.gd`

**Interfaces:**
- Consumes: `ResolvedExploit.cadence_mult` (Task 1)
- Produces: `Compiler.MIN_CADENCE_FRACTION`, `Compiler.MUL_FOLD_KEYS`, `Compiler._rank_factor(f: float, rank: int) -> float`

- [ ] **Step 1: Write the failing test**

Add to `tests/test_build.gd` and register in `_init()`:

```gdscript
## Rank scales the two directions differently, because each is the rule the other
## breaks under. Compounding a COST makes ranking on_kill a -53%..-63% DPS trap;
## applying a REDUCTION linearly goes negative (overclock at rank 6: 1-0.18*6).
func rank_factor_is_asymmetric() -> void:
	_check("a reduction compounds", Compiler._rank_factor(0.85, 5), pow(0.85, 5))
	_check("a cost accumulates", Compiler._rank_factor(1.52, 5), 1.0 + 0.52 * 5.0)
	_check("1.0 is fixed under both branches", Compiler._rank_factor(1.0, 5), 1.0)
	_check("rank 0 is neutral", Compiler._rank_factor(0.85, 0), 1.0)
	# max_rank is 5; rank 10 pins that compounding cannot cross zero the way
	# linear accumulation would.
	_check("a reduction stays positive far past max_rank",
		Compiler._rank_factor(0.85, 10) > 0.0, true)

## A synthetic module, because no shipped module carries the key until task 3.
func cadence_mult_folds_by_product() -> void:
	var a := Module.make(&"synth_a", "synth_a", Module.Slot.PAYLOAD, {&"cadence_mult": 0.5})
	var b := Module.make(&"synth_b", "synth_b", Module.Slot.PAYLOAD, {&"cadence_mult": 0.5})
	var ex := _mk(&"broadcast", &"interval")
	ex.place(a); ex.place(b)
	_check("two factors multiply, never add", Compiler.build(ex).cadence_mult, 0.25)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_build.gd`
Expected: parse or runtime failure — `Static function "_rank_factor()" not found in base "Compiler"`.

- [ ] **Step 3: Add the constants, the function and the branch**

In `scripts/build/compiler.gd`, beside `MIN_COOLDOWN`:

```gdscript
## The cooldown floor, as a fraction of the VECTOR's own base cadence. Absolute
## floors erase what distinguishes a vector: every fast build converges on the
## same number. A proportional one cannot, because every vector floors at the
## same fraction of a different base, so the ratio at the floor IS the base ratio.
const MIN_CADENCE_FRACTION := 0.12

## Stats that accumulate by product rather than by sum.
const MUL_FOLD_KEYS := [&"cadence_mult"]

## Rank scales the two directions differently, and each is the rule the other
## direction breaks under. Compounding a COST diverges — 1.52^5 = 8.1 — which
## measured as a -53%..-63% DPS trap on ranking on_kill, the option the level-up
## screen scores highest. Applying a REDUCTION linearly goes NEGATIVE: the
## threshold is rank > 1/(1-f), so overclock (0.82) crosses at rank 6, one above
## max_rank. Compounding converges toward zero and can never cross it.
static func _rank_factor(f: float, rank: int) -> float:
	return pow(f, rank) if f < 1.0 else 1.0 + (f - 1.0) * rank
```

In `_fold`, replace the accumulation block. **`v` is still computed first** — the MUL branch simply ignores it:

```gdscript
		var v := float(m.stats[key]) * scale
		if key in MUL_FOLD_KEYS:
			# The RAW stat and `scale`, never `v` and never em.rank. `v` is
			# already rank-scaled, so pow(v, rank) raises (value x rank) to the
			# power rank — pow(0.85*3, 3) = 16.58 against a correct 0.614, a 27x
			# SLOWDOWN. And `scale` rather than em.rank so any carve-out applies.
			r.set(key, r.get(key) * _rank_factor(float(m.stats[key]), scale))
		elif key in MAX_FOLD_KEYS:
			r.set(key, maxf(r.get(key), v))
		else:
			r.set(key, r.get(key) + v)
```

Do **not** add `cadence_mult` to the vector carve-out's key list. Task 3's rule 4 makes a VECTOR carrying it invalid, so a carve-out there would guard a configuration that cannot exist.

- [ ] **Step 4: Run tests to verify they pass**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_build.gd`
Expected: `PASS — all cases`.

Run the full suite; all 16 files must still pass. Nothing shipped carries `cadence_mult`, so resolved cooldowns are unchanged.

- [ ] **Step 5: Commit**

```bash
git add scripts/build/compiler.gd tests/test_build.gd
git commit -m "feat: multiplicative folding for cadence_mult, still inert

_rank_factor scales the two directions differently: reductions compound and
converge, costs accumulate linearly. Each is the rule the other breaks under —
compounding a cost is a -53%..-63% DPS trap, and linear reduction goes negative
at rank 6 for overclock.

The branch reads the raw stat and `scale`, never `v` (already rank-scaled — the
pow trap is a 27x slowdown) and never em.rank (which would bypass any carve-out)."
```

---

### Task 3: the switch — table, floor, and the four rules together

This is the atomic task. See "The one ordering constraint that matters" above.

**Files:**
- Modify: `data/module_table.gd` (four modules; the `:11-12` doc counts are unchanged — module *count* does not change)
- Modify: `scripts/build/compiler.gd` (the cadence application, `vector_base`, the proportional floor, four `validate()` rules, the clamp comment)
- Modify: `tests/test_build.gd` (two broken tests, `EXPECTED_CHECKS`)
- Modify: `tests/test_multipliers.gd` (`:111` comment, `:117-118` assertion)

**Interfaces:**
- Consumes: `Compiler.MUL_FOLD_KEYS`, `_rank_factor`, `MIN_CADENCE_FRACTION` (Task 2)
- Produces: resolved cooldown = `max(base × MIN_CADENCE_FRACTION, MIN_COOLDOWN, base × Π(cadence_mult) × haste)`

- [ ] **Step 1: Convert the table**

In `data/module_table.gd`, swap `cooldown` for `cadence_mult` on exactly four modules:

```gdscript
		Module.make(&"interval", "interval(t)", S.TRIGGER,
			{&"cadence_mult": 0.85}, [], 0, T.INTERVAL),
		Module.make(&"on_kill", "on_kill()", S.TRIGGER,
			{&"damage": 3.0, &"cadence_mult": 1.52}, [], 0, T.ON_KILL),
		Module.make(&"on_hit", "on_hit()", S.TRIGGER,
			{&"damage": 1.0, &"cadence_mult": 1.30}, [], 0, T.ON_HIT),
```

and

```gdscript
		Module.make(&"overclock", "overclock", S.PAYLOAD,
			{&"damage": 2.0, &"cadence_mult": 0.82}),
```

`on_damage_taken` is untouched — it contributes no cooldown today and none after.

- [ ] **Step 2: Apply the cadence product and the proportional floor**

In `scripts/build/compiler.gd`, replace the block from the `base_cooldown` capture through the `MIN_COOLDOWN` clamp:

```gdscript
	# cooldown is contributed ONLY by vectors now (validate() enforces it), so at
	# this point r.cooldown IS the vector's raw base — which is what the
	# proportional floor needs, with no extra field to carry it.
	var vector_base := r.cooldown
	r.cooldown *= r.cadence_mult
	r.base_cooldown = r.cooldown

	... existing MULT_KEYS pass (haste), unchanged ...

	# Two floors. The proportional one is where balance happens: every vector
	# bottoms out at the same fraction of a DIFFERENT base, so the ratio at the
	# floor is the base ratio and hitting it is not a failure.
	#
	# MIN_COOLDOWN is the absolute guard, and its real load is the NULL-VECTOR
	# path: an exploit founded on a TRIGGER has vector_base 0.0, so the
	# proportional floor collapses to 0.0 and only this stands between
	# _step5_fire's `while _fire_acc >= r.cooldown` and a zero cooldown. That
	# state is reachable (legal_targets offers EMPTY_SLOT on a not-yet-created
	# exploit for any slot type) and harmless (every fire path gates on r.inert),
	# but it is what this constant is for.
	r.cooldown = maxf(r.cooldown,
		maxf(MIN_COOLDOWN, vector_base * MIN_CADENCE_FRACTION))
```

Update the clamp comment above `MIN_COOLDOWN` (currently describing "-1.70s hung a `while accumulator >= cooldown` loop") to describe the two floors instead; the additive-negative mechanism it cites can no longer occur.

- [ ] **Step 3: Add the four `validate()` rules**

Append to `Compiler.validate`, before `return errs`:

```gdscript
	# A factor of zero, negative, or vanishingly small. 1e-9 passes a bare "> 0".
	if m.stats.has(&"cadence_mult") and float(m.stats[&"cadence_mult"]) < 0.01:
		errs.append("module '%s': cadence_mult must be >= 0.01" % m.id)

	# The floor reads r.cooldown as the vector's raw base. A PAYLOAD shipping
	# {cooldown: 0.40} was measured passing validate(), poisoning vector_base and
	# collapsing broadcast:packet from 1.70 to 1.14.
	if m.slot != Module.Slot.VECTOR and m.stats.has(&"cooldown"):
		errs.append("module '%s': only a VECTOR may carry cooldown" % m.id)

	# The ratio guarantee needs the cadence product to be vector-INDEPENDENT. A
	# packet variant carrying cadence_mult 0.60 was measured producing a
	# SOME-floored state with the ratio sliding 2.83 -> 2.43 -> 1.99 -> 1.70. The
	# configuration also has no expressive power: applied once and unranked it is
	# identical to editing the vector's base, except in the floor term — so its
	# only distinct observable behaviour IS the broken-ratio region.
	if m.slot == Module.Slot.VECTOR and m.stats.has(&"cadence_mult"):
		errs.append("module '%s': a VECTOR may not carry cadence_mult" % m.id)

	# The other precondition. Below this the ABSOLUTE floor binds for some vectors
	# and not others and the ratio collapses. Requires the KEY, not merely a value
	# when present: a VECTOR omitting cooldown has vector_base 0.0 and fires at a
	# permanent 20/s, and the inert-path argument does not cover it — such an
	# exploit with a trigger is NOT inert.
	if m.slot == Module.Slot.VECTOR and (not m.stats.has(&"cooldown") \
			or float(m.stats[&"cooldown"]) < MIN_COOLDOWN / MIN_CADENCE_FRACTION):
		errs.append("module '%s': a VECTOR must carry cooldown >= %.4f"
			% [m.id, MIN_COOLDOWN / MIN_CADENCE_FRACTION])
```

Measured margins against the 0.4167 threshold: packet +20.0%, beam +44.0%, broadcast +104.0%, chain +116.0%.

- [ ] **Step 4: Fix the two broken tests and add the guard**

`tests/test_build.gd`, `vector_cadence_does_not_scale` — line 87 reads a key that no longer exists, which **throws and aborts the function**, silently swallowing the assertion after it:

```gdscript
	_check("and that cadence is the module's own", r1.cooldown,
		base * T[&"interval"].stats[&"cadence_mult"])
```

`cooldown_clamp` — the build now resolves to 0.1398, nowhere near `MIN_COOLDOWN`. Rewrite it against the proportional floor:

```gdscript
## Stack every cadence contributor at max rank and the PROPORTIONAL floor holds.
## The absolute MIN_COOLDOWN no longer binds for any legal build.
func cooldown_clamp() -> void:
	var ex := _mk(&"broadcast", &"interval", [&"overclock", &"overclock"])
	ex.trigger.rank = 5
	ex.payloads[0].rank = 5
	ex.payloads[1].rank = 5
	var base: float = T[&"broadcast"].stats[&"cooldown"]
	var r := Compiler.build(ex, {&"haste": 0.70})
	_check("floored at the vector's own fraction", r.cooldown,
		base * Compiler.MIN_CADENCE_FRACTION)
	_check("above the absolute floor", r.cooldown > Compiler.MIN_COOLDOWN, true)
```

Add the `EXPECTED_CHECKS` guard to `tests/test_build.gd`, matching the pattern already in `test_travel.gd` and `test_meta_layout.gd`. A GDScript runtime error aborts its enclosing function **without failing the suite** — verified by running it — so a file whose checks stop executing reports PASS while testing nothing. Count the checks and assert the total.

`tests/test_multipliers.gd`:

```gdscript
	ex.place(t[&"packet"]); ex.place(t[&"interval"])   # 0.50 x 0.85 = 0.425
```

and `:117-118`, which asserts the **retired** guard — packet's binding floor is now `0.50 × 0.12 = 0.060`:

```gdscript
	_check("haste cannot tunnel under the proportional floor",
		Compiler.build(ex, {&"haste": 0.001}).cooldown,
		float(t[&"packet"].stats[&"cooldown"]) * Compiler.MIN_CADENCE_FRACTION)
```

- [ ] **Step 5: Run the full suite**

Run every file. Expected: **all 16 pass.**

Pay particular attention to `data_sweep` in `test_build.gd` — it is the only `Compiler.validate` caller in the repo, and it asserts zero errors over all 18 modules. If it reports errors naming `interval`, `on_kill`, `on_hit` or `overclock`, Step 1 did not land before Step 3.

Then the gate: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/perf_milestone0.gd`. Expected PASS; figures are load-relative (~2 ms p95 against a ~10 ms budget), so compare shape, not digits.

- [ ] **Step 6: Commit**

```bash
git add data/module_table.gd scripts/build/compiler.gd tests/test_build.gd tests/test_multipliers.gd
git commit -m "feat: triggers scale cadence proportionally instead of additively

A flat cooldown meant the same card was worth -20% on packet and -12% on
broadcast, and at rank 5 every vector converged on the MIN_COOLDOWN floor — a
safety clamp doing the balancing, and vector identity erased exactly when a build
matured. cadence_mult multiplies instead, and the floor is proportional to the
vector's own base, so the ratio at the floor IS the base ratio.

Four validate() rules enforce the two data preconditions the guarantee rests on:
only a VECTOR may carry cooldown, no VECTOR may carry cadence_mult, a VECTOR must
carry cooldown at or above 0.4167, and cadence_mult must be at least 0.01. Each
was measured passing validation while breaking something.

The table conversion, the floor and the rules land together by necessity: the
rules error on the pre-conversion table, and the floor needs an unpolluted
vector_base."
```

---

### Task 4: `test_cadence.gd` — pin the properties, not the implementation

**Files:**
- Create: `tests/test_cadence.gd`

**Interfaces:**
- Consumes: everything from Task 3
- Produces: nothing

- [ ] **Step 1: Write the suite**

Create `tests/test_cadence.gd` with an `EXPECTED_CHECKS` guard. It must cover:

1. **Ratio preservation across the payload dimension.** For every vector pair, over triggers **and payload combinations including duplicates** and ranks and `haste`, the resolved ratio equals the base ratio. Compare with a tolerance of 1e-9 — an exhaustive sweep measured the worst real error at 3.33e-16, so anything looser hides nothing and anything tighter is float noise. Scoping this to vector × trigger only is the mistake an earlier draft made: it passes on exactly the configuration where the claim holds and never runs where it failed.

2. **The floor preserves ratios.** Drive the extreme build (`interval` r5 + `overclock` r5 in **both** payload slots + `haste` 0.70), assert each vector sits bit-exactly at `base × MIN_CADENCE_FRACTION`, and that all four floor together — never some.

3. **Rank asymmetry, scoped honestly.** `interval` r3 = `base × 0.85³`; `on_kill` r3 = `base × (1 + 0.52×3)`. For the **bare vector + trigger build**, ranking `on_kill` to 5 leaves DPS at or above `0.80 × ` its rank-1 DPS. Name the scope in the test name: with a flat-damage payload the worst measured ratio is 0.484, so an unscoped 0.80 bound fails.

4. **All four `validate()` rules fire**, each on a synthetic module: a PAYLOAD carrying `cooldown`; a VECTOR carrying `cadence_mult`; a VECTOR with `cooldown` 0.20; a VECTOR **omitting** `cooldown`; and `cadence_mult` at 0.0, −1.0 and 1e-9.

5. **Rule 4's necessity.** Construct the invalid `{cooldown: 0.5, cadence_mult: 0.60}` vector directly, bypassing `validate`, and assert the ratio **does** drift — so the rule is justified by a test rather than by a comment.

- [ ] **Step 2: Run it**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tests/test_cadence.gd`
Expected: `PASS`, and the `EXPECTED_CHECKS` total must match. A mismatch means a function aborted.

- [ ] **Step 3: Commit**

```bash
git add tests/test_cadence.gd
git commit -m "test: pin the cadence ratio property and all four validate rules

The ratio test covers the PAYLOAD dimension, because an earlier draft scoped it
to vector x trigger — passing on exactly the configuration where the claim held
and never running where it failed."
```

---

### Task 5: the card stops lying about direction

**Files:**
- Modify: `scripts/run/ui.gd` (`_stats_line`)

**Interfaces:**
- Consumes: nothing
- Produces: nothing

- [ ] **Step 1: Fix the formatter**

`_stats_line` renders every stat as `"%s %+.2f"`. After Task 3 the `on_kill` card reads `cadence_mult +1.52` — **a 52% slowdown displayed as the largest-looking bonus on the card**, next to `damage +3.00`. The sign stops carrying direction.

```gdscript
func _stats_line(m: Module) -> String:
	var parts := []
	for k in m.stats:
		if k == &"cadence_mult":
			# A multiplier, not an addend: "+1.52" reads as the biggest bonus on
			# the card when it is a 52% slowdown. The multiplication sign carries
			# the direction that +/- cannot.
			parts.append("cadence x%.2f" % m.stats[k])
		else:
			parts.append("%s %+.2f" % [k, m.stats[k]])
	return "\n".join(parts)
```

`ui.gd:263` is the only module-stat renderer in the repo, so this is the whole surface.

- [ ] **Step 2: Verify visually**

Run: `godot --headless --path /Users/sean/sites/hacking-bullet-heaven -s res://tools/shot_slots.gd`

Open the screenshot and confirm a cadence card reads `cadence x0.85` / `cadence x1.52` rather than a signed addend. There is no automated check for card text.

Then run the full suite; expected all 16 pass.

- [ ] **Step 3: Commit**

```bash
git add scripts/run/ui.gd
git commit -m "fix: render cadence_mult as a multiplier, not a signed addend

on_kill's card would have read 'cadence_mult +1.52' — a 52% slowdown displayed
as the largest-looking bonus on the card."
```

---

### Task 6: the documentation sweep

**Files:**
- Modify: `README.md`
- Modify: `data/module_table.gd`, `scripts/build/loadout.gd` (comments only)

**Interfaces:** none.

- [ ] **Step 1: Update anything that describes the old model**

Search for text describing triggers as adding or subtracting seconds:

```bash
grep -rn "cooldown" README.md data/module_table.gd scripts/build/loadout.gd | grep -iv "cadence_mult"
```

At minimum: `README.md`'s TRIGGER row should say triggers *scale* the vector's cadence rather than adjusting it, and `test_build.gd:77-78`'s comment ("reductions from payloads and triggers still scale with rank") needs "factors", plus a note that the rank rule now differs by direction.

- [ ] **Step 2: Verify and commit**

Run the full suite one final time; all 16 must pass, plus the perf gate.

```bash
git add -A README.md data/module_table.gd scripts/build/loadout.gd tests/test_build.gd
git commit -m "docs: describe triggers as scaling cadence, not adding seconds"
```

---

## Notes for the executor

**The spec's own review record is the best guide to where this goes wrong.** Across three rounds every arithmetic claim survived independent re-derivation and almost every claim about a *consequence* did not. If you find yourself about to write "so this means…" in a comment or a commit message, run the thing that would show whether it does.

**Two numbers are judgement, not derivation.** `MIN_CADENCE_FRACTION = 0.12` sets every vector's ceiling simultaneously, and it already binds on 160 packet configurations at maxed `cooling`, 40 at ×0.85, and 21 with no meta progression at all. `on_kill = 1.52` is a derived mean, but the *rank rule* applied to it is a design choice. Both want play-testing before they are considered settled.

**Expect ranked builds to feel different.** Anything into `interval` or `overclock` loses the clamp's free speed; `broadcast + interval` is 3.7% *faster* at rank 1. That is the change working, and it is the largest behavioural shift here.
