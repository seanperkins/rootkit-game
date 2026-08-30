# ROOTKIT — Multiplicative Trigger Cadence

**Date:** 2026-08-30
**Status:** revision 2 — after a six-reviewer panel. See §10.
**Builds on:** `2026-08-30-player-stats-and-defense-design.md`
**Blocks:** healing / the health economy — see §8

---

## 1. Problem

Triggers contribute a **flat** cooldown, so the same card means something
different on every vector. From `data/module_table.gd`, at rank 1:

| Vector | base | `+ interval` (−0.10) | `+ on_hit` (+0.20) | `+ on_kill` (+0.35) |
|---|---|---|---|---|
| packet | 0.50 | 0.40 (**−20%**) | 0.70 (+40%) | 0.85 (**+70%**) |
| beam | 0.60 | 0.50 (−17%) | 0.80 (+33%) | 0.95 (+58%) |
| broadcast | 0.85 | 0.75 (−12%) | 1.05 (+24%) | 1.20 (+41%) |
| chain | 0.90 | 0.80 (−11%) | 1.10 (+22%) | 1.25 (+39%) |

`on_kill` costs packet 70% of its cadence and broadcast 41% — the same card is
nearly twice as punishing on the fastest weapon, which is backwards: packet is
the vector that most wants an event trigger.

**Rank makes it worse, and eventually erases the vector.** `interval` at rank 5
is −0.50:

| Vector | base | rank-5 `interval` | + rank-5 `overclock` |
|---|---|---|---|
| packet | 0.50 | 0.00 → **clamped 0.05** | **clamped 0.05** |
| beam | 0.60 | **0.10** | **clamped 0.05** |
| broadcast | 0.85 | 0.35 | **clamped 0.05** |
| chain | 0.90 | 0.40 | **clamped 0.05** |

All four land on 0.05: a maxed broadcast build and a maxed packet build fire at
an identical 20 shots per second. What distinguishes a vector is erased exactly
when a build matures, and `MIN_COOLDOWN` — a safety clamp — ends up doing the
balancing.

## 2. Decision

`cadence_mult` becomes a new stat key, folded by **multiplication**, and the
cooldown floor becomes **proportional to the vector's own base**.

- **VECTORs** keep `cooldown` and become its *only* source. It is the weapon's
  base cadence, already exempt from rank scaling.
- **TRIGGERs and cooldown-modifying PAYLOADs** contribute `cadence_mult`.
- **The floor is `vector.cooldown × MIN_CADENCE_FRACTION`**, not an absolute.

```
resolved.cooldown = max(
    vector.cooldown × MIN_CADENCE_FRACTION,      # proportional floor
    MIN_COOLDOWN,                                # absolute hang guard
    vector.cooldown × Π(cadence_mult) × haste)
```

**Ratios survive even at the floor.** This is the whole point, and revision 1
got it wrong: it used an absolute floor and claimed no legal build would reach
it. A panel swept the space through the real `Loadout` API and found **71 legal
builds clamping**, at which point broadcast:packet collapsed from 1.70 to
**1.0368** — the disease reproduced one card later. A proportional floor cannot
do that: every vector's most extreme build lands at exactly the same fraction of
its own base (0.0427, verified across all four), so one fraction binds them all
and the ratio at the floor is exactly the base ratio.

Reaching the floor is therefore no longer a failure, and the spec no longer
depends on a claim about build legality that a reviewer can falsify.

## 3. The numbers

Each multiplier is the mean of that module's *current* effect across the four
vectors, rounded to two decimals:

| Module | today | derivation (broadcast / packet / chain / beam) | mean | `cadence_mult` |
|---|---|---|---|---|
| `interval` | −0.10 | 0.882 / 0.800 / 0.889 / 0.833 | 0.851144 | **0.85** |
| `on_hit` | +0.20 | 1.235 / 1.400 / 1.222 / 1.333 | 1.297712 | **1.30** |
| `on_kill` | +0.35 | 1.412 / 1.700 / 1.389 / 1.583 | 1.520997 | **1.52** |
| `overclock` | −0.12 | 0.859 / 0.760 / 0.867 / 0.800 | 0.821373 | **0.82** |
| `on_damage_taken` | — | contributes no cooldown today | — | omitted (×1.0) |

`on_kill` is **1.52**, the honest rounding of 1.520997. Revision 1 wrote 1.50
while the other three rows rounded faithfully, in a column whose whole authority
is that the values are derived.

**Rank-1 feel moves by up to −10.6%,** not "barely". The full spread:
`packet + on_kill` −10.6%, `chain + on_kill` +8.0%, `packet + overclock` +7.9%,
`packet + interval` +6.3%, `packet + on_hit` −7.1%, `beam + on_kill` −5.3%. Every
move is in the direction §1 argues for, but the magnitude should be stated
rather than waved at.

### 3.1 Rank scales the two directions differently

A factor below 1.0 **compounds**; a factor above 1.0 **accumulates linearly**:

```
rank_factor(f, rank) = pow(f, rank)          if f < 1.0
                     = 1 + (f - 1) * rank    if f >= 1.0
```

This is two rules, and the reason is that **each is the rule the other direction
breaks under.** Measured, both ways:

| build | today r1 → r5 | compounding cost | linear cost |
|---|---|---|---|
| packet + `on_kill` | 14.12 → 10.67 DPS (−24%) | 5.92 (**−63%**) | 13.33 (−16%) |
| chain + `on_kill` | 8.00 → 8.30 (+4%) | 3.01 (**−59%**) | 6.79 (−7%) |
| broadcast + `on_kill` | 6.67 → 7.69 (+15%) | 2.90 (**−53%**) | 6.54 (+6%) |
| beam + `on_kill` | 8.42 → 8.51 (+1%) | 4.11 (**−53%**) | 9.26 (+6%) |

Compounding a cost multiplier turns ranking `on_kill` into a **−53% to −63% DPS
trap** — on the option `Loadout.best_target` scores highest, so the level-up
screen would recommend it. Linear accumulation tracks today's roughly-neutral
behaviour within a few points.

And the converse: linear accumulation applied to a *reduction* goes **negative**.
`interval` at rank 7 would be `1 + (−0.15 × 7) = −0.05`, a negative cooldown.
`max_rank` is 5 today so it would not bite — which is exactly what makes it the
kind of latent trap this design keeps producing. Compounding converges toward
zero and can never cross it.

### 3.2 What rank-5 `interval` becomes

| Vector | base | today | new (× 0.85⁵ = 0.4437) |
|---|---|---|---|
| packet | 0.50 | **0.05** (floored) | **0.222** |
| beam | 0.60 | **0.10** | 0.266 |
| broadcast | 0.85 | 0.35 | 0.377 |
| chain | 0.90 | 0.40 | 0.399 |

Today packet and chain are 8× apart with packet pinned to the clamp. New, they
are 1.8× apart — exactly their 0.50 : 0.90 base ratio. Ranking `interval` goes
from a 10× speed-up to **2.25×**.

## 4. The floor, and what the real ceiling is

`MIN_CADENCE_FRACTION = 0.12`. The resulting per-vector ceilings:

| Vector | base | floor | ceiling |
|---|---|---|---|
| packet | 0.50 | 0.060 | **16.7/s** |
| beam | 0.60 | 0.072 | 13.9/s |
| broadcast | 0.85 | 0.102 | 9.8/s |
| chain | 0.90 | 0.108 | 9.3/s |

broadcast : packet at the floor = **1.7000**, identical to the base ratio.

The most extreme legal build — `interval` r5 + `overclock` r5 in **both** payload
slots (legal: `loadout.gd:5` "A module may occupy any number of slots") + maxed
`cooling` — computes to 0.0427 × base before flooring, so every vector floors.
That build is 16.7/s on packet and 9.8/s on broadcast, where today both are 20/s.

`MIN_COOLDOWN` 0.05 stays as an **absolute** guard: for a normal vector the
proportional floor is larger (packet's 0.060 > 0.05) so it never binds, but a
pathological table entry with a tiny base cooldown would still be caught, and
`run.gd`'s `while _fire_acc >= r.cooldown` loop stays bounded regardless.

## 5. Implementation

### 5.1 `module.gd`

`cadence_mult` joins `STAT_KEYS` (16 → 17).

### 5.2 `resolved_exploit.gd`

```gdscript
## Multiplicative, so it initialises to 1.0 rather than 0.0. It is the only stat
## key on this struct that does not default to zero.
var cadence_mult: float = 1.0
```

It joins `equals()`.

**`base_cooldown`'s docstring must be rewritten.** It currently claims *"May be
NEGATIVE: broadcast + interval r5 + overclock r5 folds to −0.25"* — impossible
once cooldown is a product of positives, and a comment warning against a case
that cannot occur is worse than no comment. Its meaning is preserved (§5.3), so
the rest of the docstring stands.

### 5.3 `compiler.gd`

Three accumulation modes now: `+`, `maxf` (`MAX_FOLD_KEYS`), and product.

```gdscript
## Multiplicative stats. Rank scales the two directions differently, because
## each is the rule the other breaks under: compounding a COST (a factor above
## 1.0) makes ranking a -53%..-63% DPS trap, while applying a REDUCTION linearly
## goes negative past rank 6. Reductions converge toward zero; costs accumulate.
const MUL_FOLD_KEYS := [&"cadence_mult"]

static func _rank_factor(f: float, rank: int) -> float:
	return pow(f, rank) if f < 1.0 else 1.0 + (f - 1.0) * rank
```

In `_fold`, branching before `v` is computed:

```gdscript
		if key in MUL_FOLD_KEYS:
			# The RAW stat, never `v`. `v` is already rank-scaled, so
			# pow(v, rank) raises (value x rank) to the power rank —
			# pow(0.85*3, 3) = 16.58, turning interval r3 into a 27x SLOWDOWN.
			r.set(key, r.get(key) * _rank_factor(float(m.stats[key]), em.rank))
		elif key in MAX_FOLD_KEYS:
			r.set(key, maxf(r.get(key), v))
		else:
			r.set(key, r.get(key) + v)
```

The vector rank carve-out gains `cadence_mult`, so a VECTOR carrying it cannot
rank-scale — the same bug class the carve-out was written for. Nothing carries it
today; §2's "vectors are the only source of `cooldown`" is a convention, and this
makes the converse enforced rather than assumed.

Application, replacing the current clamp:

```gdscript
	# cooldown is contributed ONLY by vectors now, so at this point r.cooldown
	# IS the vector's raw base — which is what the proportional floor needs, with
	# no extra field to carry it.
	var vector_base := r.cooldown
	r.cooldown *= r.cadence_mult
	r.base_cooldown = r.cooldown      # folded, pre-haste, pre-clamp: unchanged meaning

	... existing MULT_KEYS pass (haste) ...

	r.cooldown = maxf(r.cooldown,
		maxf(MIN_COOLDOWN, vector_base * MIN_CADENCE_FRACTION))
```

`base_cooldown` is captured **after** the cadence multiply. Revision 1 put it
before while simultaneously claiming the meaning was preserved; three reviewers
caught the contradiction, and implemented as written the field silently became
"the vector's raw base."

`compiler.gd:29-34`'s clamp comment — *"Cooldown reached −1.70s at max rank and
hung a `while accumulator >= cooldown` loop"* — no longer describes a reachable
case from the trigger side and must be updated to say what the two floors now
guard.

### 5.4 `Compiler.validate`

```gdscript
	if m.stats.has(&"cadence_mult") and float(m.stats[&"cadence_mult"]) <= 0.0:
		errs.append("module '%s': cadence_mult must be > 0" % m.id)
```

This repo puts data invariants in `validate()` — it already has one for the
corruption tag/stat pairing. A module shipping `cadence_mult: 0.0` or a negative
would otherwise pass both `validate()` and `data_sweep`.

### 5.5 `module_table.gd`

Four modules swap `cooldown` for `cadence_mult` per §3. `on_damage_taken` is
untouched.

### 5.6 `ui.gd` — a required change, not an omission

`ui.gd:261-264` renders every module stat as `"%s %+.2f"`. After the swap,
`interval`'s card reads `cadence_mult +0.85` and `on_kill`'s `cadence_mult
+1.52` — the sign stops carrying direction, and **a 52% slowdown displays as the
largest-looking bonus on the card**. Combined with §3.1 (where ranking a cost
trigger is now a real decision) the card would actively misinform the choice it
is asking the player to make.

`_stats_line` needs a per-key formatter rendering `cadence_mult` as a rate
change — `interval ×0.85` or `−15% cadence` — not a signed addend.

**No `run.gd` changes.** Every consumer of `r.cooldown` (`_try_event_fire`,
`_step5_fire`'s accumulator and its while-loop bound, the HUD) reads the resolved
float and none assumes additivity.

## 6. Tests

**New — `test_cadence.gd`, with an `EXPECTED_CHECKS` guard:**

- **Ratio preservation, including the payload dimension.** For every vector pair,
  across triggers *and* payload combinations *and* ranks *and* `haste`, the ratio
  of resolved cooldowns equals the ratio of base cooldowns. Revision 1's version
  was scoped to vector × trigger only — it would have passed on the exact
  configuration where the claim held and never run on the one where it failed.
- **The floor preserves ratios.** Drive the most extreme legal build (both
  payload slots `overclock` r5, `interval` r5, `haste` 0.70), assert every vector
  is at its own `base × MIN_CADENCE_FRACTION`, and that the ratios still hold.
- **Rank asymmetry.** `interval` r3 = `base × 0.85³`; `on_kill` r3 =
  `base × (1 + 0.52×3)`; and ranking `on_kill` never *reduces* DPS relative to
  rank 1.
- **`_rank_factor` boundaries**: `f` exactly 1.0, rank 1, and a reduction at
  rank 10 (above `max_rank`, to pin that it stays positive).
- **`validate()` rejects** `cadence_mult` of 0.0 and of −1.0.

**Updated — `test_build.gd`, which has TWO broken tests and needs the guard:**

- `cooldown_clamp` (`:91-97`) asserts `broadcast + interval r5 + overclock r5`
  clamps. It now resolves to 0.1398 and does not. Rewrite it against the
  proportional floor.
- `vector_cadence_does_not_scale` (`:79-88`) reads
  `T[&"interval"].stats[&"cooldown"]` at `:87`. That key is removed, so it
  **throws**, aborts the function, and silently swallows the assertion at `:88`
  while the suite still reports one failure instead of two. Rewrite to
  `base × T[&"interval"].stats[&"cadence_mult"]`.
- **`test_build.gd` gets `EXPECTED_CHECKS`.** Revision 1 proposed the guard only
  for the new file, then walked into the hazard in the file it certified as
  untouched.

**Stale comments to fix:** `test_multipliers.gd:111` (`# 0.50 - 0.10 = 0.40` →
`0.50 × 0.85 = 0.425`) and `test_build.gd:77-78` ("reductions from payloads and
triggers still scale with rank" → "factors", and the rank rule now differs by
direction).

**Perf:** no tick change, but fire rate moved; `perf_milestone0.gd` is the gate.

## 7. What a reviewer verified and I should not re-litigate

Recorded so revision 3 does not spend effort here. A panel implemented §5 on a
scratch copy and ran the real compiler and full suite: every figure in §1, §3,
§3.2 and §6 reproduces exactly; all 16 existing stat keys do default to zero, so
§5.2's "only non-zero default" is precise; the `pow` trap is real; and "no
`run.gd` changes" holds for `run.gd` itself. Of the 15 test files, only
`test_build.gd` fails.

## 8. Why this comes before healing

Flat per-fire healing is bounded by `heal × fires_per_second`. Under the current
model that denominator collapses to the `MIN_COOLDOWN` floor at 20/sec for
*every* vector, so any bound on healing had to be invented by hand — and four
such designs failed review in four different ways.

Healing was never the unstable part. **The denominator was.** With a proportional
floor the denominator is per-vector and known: **16.7/s on packet**, the fastest
vector, down to 9.3/s on chain. Flat per-fire healing tuned against 16.7 lands
around 0.3–0.5 HP per fire, and — unlike revision 1's 17.4/s — that number is a
floor the design guarantees rather than a claim about which builds are legal.

## 9. Risk

1. **Ranking a cost trigger changes character.** `on_kill` goes from roughly
   DPS-neutral to −16%..+6% depending on vector (§3.1). Smaller than the −57%
   trap compounding would have produced, but it is a real change to how a shipped
   trigger ranks, and the direction differs by vector.
2. **Every existing ranked build gets slower.** Anything into `interval` or
   `overclock` loses the clamp's free speed.
3. **`MIN_CADENCE_FRACTION` 0.12 is the one number here chosen by judgement**
   rather than derived. It sets every vector's ceiling simultaneously. Too low
   and the floor never binds and fast builds run away; too high and it binds on
   ordinary builds and flattens the curve.
4. **Two rank rules is more machinery than one.** §3.1 justifies it with measured
   failures in both directions, but it is a complexity cost and a future
   multiplicative stat inherits the branch.
5. **`cadence_mult` defaults to 1.0**, the only stat key that does not default to
   zero. Any future code that resets fields generically or assumes zero defaults
   breaks quietly.

## 10. Review record

One round, six reviewers (GPT-5.6 Luna, GPT-5.6 Terra, GLM-5.2, Gemini 3.1 Pro,
and two Claude skeptics). Six REVISE, no contradictions.

Two findings were proved by **running code** rather than argued:

- **The absolute floor did not hold.** 71 legal builds clamped, worst 0.0213s,
  confirmed through the real `Loadout` API. At the clamp broadcast:packet fell to
  1.0368 — revision 1's headline property, false in exactly the region its own
  test was not scoped to reach.
- **Cost multipliers diverge under rank.** Chain + `on_kill` r5 measured at
  6.83s and −57% DPS, on the option the level-up screen scores highest.

Revision 1 also repeated a mistake this codebase had already fixed once: `maxf`
folding exists precisely because the same module is legal in both payload slots,
and `cadence_mult` shipped with no equivalent guard against the identical case.

And it walked into its own documented hazard — §6 warned that a GDScript runtime
error aborts a function without failing the suite, then certified as "passes
unchanged" a test that throws on a key the spec removes.
