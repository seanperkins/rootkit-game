# Leveling pace across the campaign

Date: 2026-09-04. Status: implemented with a later onset justified by the first paired measurements. See [implementation record](../../progression-bosses-music.md); the original candidate below remains design history.

## Goal

The user's observation is that almost every item can be maxed in the first subnet. Accept that observation; the purpose of measurement is attribution and tuning, not to demand a reproduction from the user. Growth should remain meaningful through subnets 2 and 3 instead of finishing in subnet 1.

Approved approach: change XP cost first, then consider shard/economy changes only if progression still front-loads. Do not reduce pickup reach as a shortcut: collecting rewards is separate from how much progression they buy. No exact end-of-subnet level count has been approved.

## Grounded baseline

Source: `scripts/run/run.gd` (`_xp_for`, `_gain_xp`, `_settle_offers`, `_block_payout`, miniboss death rewards and shard pickup), `scripts/run/spawn_director.gd`, `scripts/build/player_stats.gd`, `tests/perf_milestone0.gd`.

| Current behavior | Consequence |
|---|---|
| `_xp_for(lvl) = round((5 + 3*(lvl-1))*1.8)` | Raising the constant scales every level cost; it does not itself add progressive curvature. |
| The source records an earlier uniform 2.4 multiplier starving the first subnet in an autopilot | A larger uniform multiplier is not the safest default, especially alongside weaker starting weapons. This is historical evidence, not a new experiment. |
| XP and level are run-wide; a pickup calls `_gain_xp(1)` and each earned round goes to every LIVE slot | Solo XP-rate conclusions cannot be assumed to hold for a four-player party. |
| Miniboss kills add `pending_levels` directly; data blocks can award seeded/rank-only offers or fusion | XP is not the only route to a maxed build. Count all upgrade sources separately. |
| The perf gate drives a specialized four-slot fixture with worst-case builds and a bounded run | It is load coverage, not a typical fresh-profile three-subnet progression survey. |

Preserve XP remainder, multiple-level payout in one gain, staged per-player choices, and pending-round behavior. A subnet transition does not reset level or XP. Snapshot state (`level`, `xp`, `xp_needed`, `pending_levels`, offers) must remain mutually consistent.

## Recommended candidate, not a locked balance number

Keep the current early costs, then increase the cost of later levels smoothly using integer arithmetic. For a current level `L >= 1`:

```text
base = round((5 + 3*(L-1))*1.8)
late = max(0, L-6)
candidate_cost = base + floor((late*late + 2)/4)
```

This introduces an approximately quadratic per-level surcharge after level 6 without new libm functions or simulation RNG. The existing positive rounding rule remains. The slope, onset and divisor are tuning candidates, not difficulty options exposed to players.

Arithmetic checked in a standalone calculation on 2026-09-04; these are **costs**, not measured levels at minute five:

| Current level | Current cost of next level | Candidate cost | Current cumulative XP to reach this level | Candidate cumulative XP |
|---|---:|---:|---:|---:|
| 1 | 9 | 9 | 0 | 0 |
| 6 | 36 | 36 | 99 | 99 |
| 10 | 58 | 62 | 275 | 278 |
| 20 | 112 | 161 | 1094 | 1297 |
| 30 | 166 | 310 | 2453 | 3531 |
| 40 | 220 | 509 | 4352 | 7480 |

This is intentionally an XP-curve-first experiment, not a promise that 30 or 40 will be reached. Preserve monotonic positive costs and guard the practical supported level range against integer overflow; no new exception for a particular seed or player's build.

## Measurement contract

Use the actual run scene with `external_drive`, injected movement/aim, staged choices and isolated save profiles. Reuse existing fixture movement/aim helpers where appropriate, but do not install its maxed loadouts or invulnerable support slots into a “normal progression” benchmark. A baseline run and candidate run must use the same policy, profiles and seed set. Changed RNG consumption from fewer offers is expected; report paired outcomes rather than claiming equal combat histories.

| Dimension | Required coverage |
|---|---|
| Profiles | Fresh, moderate shop ranks, fully upgraded/unlocked; exact counters recorded |
| Party | Solo and four LIVE slots, same immutable roster policy; do not multiply earned party XP again |
| Build policy | Breadth-first, rank-first and corruption-oriented choices; same policy before/after |
| Time | Each subnet boundary and fixed fighting-time checkpoints; separate menu/offer time from world time |
| Outcomes | Deaths/timeouts recorded, never omitted from averages; boss-aware navigation when bespoke bosses land |

Use a small fixed seed set (recommend five seeds) and report raw per-run rows plus medians/ranges. Record XP generated/collected/uncollected, level, weapon/trigger/payload ranks, capped slots, first fusion, each upgrade source, seconds between meaningful choices, health/damage taken, survival and boss completion. A rank cap is not the same as the number of unique modules seen.

Recommended comparison target for review: roughly 20–35% fewer XP-earned choices in subnet 1 for a high-progress baseline, retaining the first few choices and leaving substantial rank/fusion decisions in later subnets. Do not declare success solely from this percentage if fresh builds fail before acquiring usable breadth. It is a tuning target, not a user-approved fixed level budget.

Only after this experiment: if direct miniboss/block awards dominate remaining early completion, show that evidence and propose adjustments to those rewards. If XP remains the cause, examine shard value/count before pickup reach. Do not silently change density, HP or salvage together with the curve.

## Interactions and acceptance

1. Early costs remain unchanged in the recommended candidate; later costs increase, XP remainder is conserved, and simultaneous thresholds create exactly the earned number of rounds.
2. The normal run still reaches useful build decisions before first-subnet minibosses. Slower leveling plus a 0.75-second bare starter is measured together, not each declared safe in isolation.
3. A later-subnet XP/reward modifier affects only its declared interval and is applied once; base XP costs never become per-peer or local-save-dependent. Track bonus reward exposure separately from the base-curve experiment.
4. Every peer processes the same pickup/round/snapshot transitions, including a player parking while offers are queued. No presentation or benchmark statistics enter the hash.
5. Actual paired measurements show continued progression later in the campaign without a first-subnet survival collapse. Human play confirms the menu frequency and build choice pacing; bot output alone cannot establish feel.

Existing cost/offer tests and the repository runner provide correctness evidence during implementation. The perf gate must still run: weaker/slower builds can change its enemy, hit and kill coverage even if only XP code changed. Never claim an XP-only edit cannot affect performance coverage.
