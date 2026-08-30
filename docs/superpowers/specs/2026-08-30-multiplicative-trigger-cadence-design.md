# ROOTKIT — Multiplicative Trigger Cadence

**Date:** 2026-08-30
**Status:** design, not yet reviewed
**Builds on:** `2026-08-30-player-stats-and-defense-design.md`
**Blocks:** healing / the health economy — see §7

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

**Rank makes it worse, and eventually erases the vector.** `interval` is
−0.10/rank, so at rank 5 it is −0.50:

| Vector | base | rank-5 `interval` |
|---|---|---|
| packet | 0.50 | 0.00 → **clamped to `MIN_COOLDOWN` 0.05** |
| beam | 0.60 | **0.10** |
| broadcast | 0.85 | 0.35 |
| chain | 0.90 | 0.40 |

Packet does not merely get fast — it hits the floor and stops being packet.
Add rank-5 `overclock` (−0.12/rank) and *every* vector lands on 0.05: a
maxed broadcast build and a maxed packet build fire at an identical 20 shots per
second. The thing that distinguishes a vector is erased precisely when the build
matures, and `MIN_COOLDOWN` — a safety clamp — ends up doing the balancing.

## 2. Decision

`cadence_mult` becomes a new stat key, folded by **multiplication**.

- **VECTORs** keep `cooldown` and remain the only slot that sets it. It is the
  weapon's base cadence, already exempt from rank scaling (`compiler.gd`).
- **TRIGGERs and cooldown-modifying PAYLOADs** contribute `cadence_mult`
  instead. Rank is repetition: rank 3 applies the factor three times.

```
resolved.cooldown = vector.cooldown × Π(cadence_mult) × haste
```

`haste` already multiplies `cooldown` (`Compiler.MULT_KEYS`), so it composes
without special-casing.

**Ratios survive by construction.** Whatever is bolted on, broadcast stays
1.7× packet's cadence, because both are the same product applied to different
bases. That is the property the flat model cannot have at any set of numbers.

## 3. The numbers

Each multiplier is the mean of that module's *current* effect across the four
vectors, so rank-1 feel barely moves:

| Module | today | derivation (broadcast / packet / chain / beam) | `cadence_mult` |
|---|---|---|---|
| `interval` | −0.10 | 0.882 / 0.800 / 0.889 / 0.833 → 0.851 | **0.85** |
| `on_hit` | +0.20 | 1.235 / 1.400 / 1.222 / 1.333 → 1.298 | **1.30** |
| `on_kill` | +0.35 | 1.412 / 1.700 / 1.389 / 1.583 → 1.521 | **1.50** |
| `overclock` | −0.12 | 0.859 / 0.760 / 0.867 / 0.800 → 0.821 | **0.82** |
| `on_damage_taken` | — | contributes no cooldown today | omitted (×1.0) |

`overclock` stays slightly stronger than `interval`, preserving their current
ordering. They never compete for a slot — one is a PAYLOAD, one a TRIGGER — so
the difference is flavour, not a choice.

### 3.1 What rank-5 `interval` becomes

| Vector | base | today | new (× 0.85⁵ = 0.4437) |
|---|---|---|---|
| packet | 0.50 | **0.05** (floored) | **0.222** |
| beam | 0.60 | **0.10** | 0.266 |
| broadcast | 0.85 | 0.35 | 0.377 |
| chain | 0.90 | 0.40 | 0.399 |

Today packet and chain are 8× apart with packet pinned to the clamp. New, they
are 1.8× apart — **exactly their 0.50 : 0.90 base ratio**.

Ranking `interval` goes from a 10× speed-up (0.50 → 0.05) to **2.3×**
(0.50 → 0.222). That is a deliberate nerf: the 10× only exists because the
subtraction drove the value through zero into the clamp.

## 4. The ceiling barely moves — stated, not buried

Multiplication compounds. The most extreme legal build —
packet + `interval` r5 + `overclock` r5 + maxed `cooling` (`haste` ×0.70):

```
0.50 × 0.4437 × 0.3707 × 0.70 = 0.0576 s  →  17.4 shots/sec
```

against today's clamped 0.05 → 20 shots/sec. So this change buys
**proportionality, not a lower ceiling.**

The difference is what happens to a *different* vector on that same build:

| Build | today | new |
|---|---|---|
| packet + interval r5 + overclock r5 + cooling r10 | 0.05 (20/s) | 0.058 (17.4/s) |
| broadcast, same modules | 0.05 (20/s) | 0.098 (10.2/s) |

Today the two are **identical**. New, they differ by 1.7× — their base ratio.
That is the entire point of the change, and it is worth more than the ceiling.

If fast builds should also be capped harder, that is a **separate lever** — a
weaker `overclock`, or a floor on the product — and it should be applied
deliberately rather than smuggled in here.

`MIN_COOLDOWN` stays at 0.05 as a safety net against a pathological module
table. It is no longer where balance happens, and no legal build reaches it.

## 5. Implementation

### 5.1 `module.gd`

`cadence_mult` joins `STAT_KEYS` (16 → 17).

### 5.2 `resolved_exploit.gd`

```gdscript
## Multiplicative, so it initialises to 1.0 rather than 0.0. A stat that
## accumulates by product cannot share the additive default.
var cadence_mult: float = 1.0
```

It joins `equals()`. Note `base_cooldown` already exists and keeps its meaning:
the folded cooldown before `haste` and before `MIN_COOLDOWN`.

### 5.3 `compiler.gd`

`_fold` currently has two accumulation modes — `+` and `maxf`
(`MAX_FOLD_KEYS`). This adds a third:

```gdscript
## Multiplicative stats. Rank is repetition, not a coefficient: rank 3 applies
## the factor three times, so a ranked cadence trigger compounds the way stacking
## three copies of it would.
const MUL_FOLD_KEYS := [&"cadence_mult"]
```

```gdscript
		if key in MUL_FOLD_KEYS:
			r.set(key, r.get(key) * pow(float(m.stats[key]), em.rank))
		elif key in MAX_FOLD_KEYS:
			r.set(key, maxf(r.get(key), v))
		else:
			r.set(key, r.get(key) + v)
```

`pow(x, rank)` rather than a loop: `em.rank` is bounded by `max_rank` 5 and the
intent — "the factor applied rank times" — reads directly.

The `scale` carve-out above it does not apply to `cadence_mult`: rank enters
through the exponent, so the multiplicand must stay the raw stat value. This is
a real trap — computing `v` first and then exponentiating it would raise
`value × rank` to the power `rank`.

Applying it, immediately before the existing multiplier pass:

```gdscript
	r.cooldown = r.cooldown * r.cadence_mult
```

Order is load-bearing and already correct: `base_cooldown` is captured *before*
this, `haste` multiplies *after* it, and `MIN_COOLDOWN` clamps last.

### 5.4 `module_table.gd`

Five modules retuned per §3. `interval`, `on_kill`, `on_hit` and `overclock`
swap `cooldown` for `cadence_mult`; `on_damage_taken` is untouched.

**No `run.gd` changes.** Combat reads `r.cooldown` exactly as it does now.

## 6. Tests

**New — `test_cadence.gd`:**

- **Ratio preservation, the headline property.** For every trigger, and again at
  rank 5, the ratio between any two vectors' resolved cooldowns equals the ratio
  of their base cooldowns. This is the assertion the flat model cannot pass at
  any set of numbers.
- **Rank is repetition.** Rank 3 `interval` resolves to `base × 0.85³`, and
  rank 3 equals three separate rank-1 applications.
- **No legal build reaches `MIN_COOLDOWN`.** Sweep every vector × trigger, both
  cooldown payloads at rank 5, and `haste` ×0.70; assert every result is
  strictly greater than `MIN_COOLDOWN`. If this ever fails, the clamp is
  silently balancing the game again.
- **`cadence_mult` never reaches zero or goes negative**, for any rank.
- **Assertion-count guard** (`EXPECTED_CHECKS`), because a GDScript runtime error
  aborts its enclosing function without failing the suite — a file whose checks
  never run reports PASS while testing nothing.

**Updated:** `test_build.gd`'s `cooldown_clamp` case is built on
`broadcast + interval r5 + overclock r5` folding to −0.25 and clamping. Under
multiplication that build resolves to 0.85 × 0.4437 × 0.3707 = **0.1398**, which
never approaches the clamp. Rewrite it to assert the clamp still guards a
*pathological* table (a directly-injected tiny `cadence_mult`) rather than a
legal build. `vector_cadence_does_not_scale` should still pass unchanged and is
worth re-running deliberately.

**Perf:** no change to the tick, but `perf_milestone0.gd` is the standing gate
and fire rate moved, so run it.

## 7. Why this comes before healing

Flat per-fire healing — the shape the design calls for — is bounded by
`heal × fires_per_second`. Under the current model that denominator collapses to
the `MIN_COOLDOWN` floor at 20/sec regardless of vector, so every attempt to
bound healing had to invent a cap by hand. Four such designs failed review in
four different ways (see the review record of the player-stats spec).

Healing is not the unstable part. **The denominator is.** With cadence
proportional and its real ceiling known — 17.4 shots/sec for the most extreme
build — flat per-fire healing has a number to be tuned against, and lands around
0.3–0.5 HP per fire.

## 8. Out of scope

Healing and the health-cost module (`sudo`) — the work this unblocks, deferred
so a cadence regression cannot be mistaken for a healing one. A harder cap on
fast builds (§4). Any change to `run.gd`, to `MIN_COOLDOWN`'s value, or to the
vectors' base cooldowns.

## 9. Risk

1. **Every existing build's fire rate changes.** Anything ranked into `interval`
   or `overclock` gets meaningfully slower. That is the fix working, but it is
   the largest behavioural change in this spec and the one most likely to want a
   second tuning pass after play.
2. **The `pow(value, rank)` trap** in §5.3 — exponentiating the rank-scaled `v`
   instead of the raw stat is an easy misread with a wrong-but-plausible result.
   Called out in the code comment and covered by the rank-is-repetition test.
3. **`cadence_mult` defaults to 1.0, not 0.0.** Any future code that resets a
   `ResolvedExploit` field-by-field, or any serialisation that assumes zero
   defaults, breaks quietly. It is the only stat key on the struct that does not
   default to zero.
