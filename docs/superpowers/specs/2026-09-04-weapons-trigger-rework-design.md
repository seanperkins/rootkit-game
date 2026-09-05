# Weapons and triggers: readable upgrades, explicit cadence

Date: 2026-09-04. Status: implemented; windowed smoke and 13 affected suites plus the perf gate passed. The user approved self-contained fast shields after the recovery-only prototype proved unreachable. The full suite is deferred until the remaining features are integrated.

## Goal and approved decisions

| Concern | Contract |
|---|---|
| Upgrade wording | Explain the actual change to the selected exploit, with units and before/after values. Do not display raw module contributions as if they were the resulting build. |
| Weapon ranks | Improve damage, reach or other weapon properties, never firing frequency. |
| Cadence ownership | Triggers control firing frequency; shop `cooling` no longer changes weapon cooldown. |
| Shop `cooling` | Adds sheet `clock_speed` (move speed), not exploit `haste`. Same saved rank; retarget `SaveGame` tables and shop text. |
| Payload cadence | `overclock` and `race_condition` drop `cadence_mult`; each supplies its own smaller, faster-rearming shield. |
| Start | One packet weapon, no equipped trigger. The weapon works immediately. |
| Bare weapon | Cooldown is base cooldown times 1.5 while no trigger is equipped. Equipping a trigger removes that penalty; its own condition and cadence then apply. |
| Bounce | Base damage 1.4, radius 150, cooldown 1.5 seconds; base knockback stays 320. |

“1.5 times slower” means 50% longer between emissions, or two-thirds the emission rate, not 50% of the rate. An event-triggered weapon is not guaranteed to fire faster than a bare weapon: it also needs a qualifying event.

## Pre-change behavior and corrections

Source: `scripts/build/compiler.gd` (`_fold`, `build`, `validate`), `scripts/build/loadout.gd` (`start`, `legal_targets`, `resolve`, `can_fuse`, `_interval_count`), `data/module_table.gd`, `data/recipe_table.gd`, `scripts/run/ui.gd` (`_stats_line`, `_row_button`, `_make_card`).

- `_fold` already freezes VECTOR cooldown and travel at scale 1.0. The interview's earlier claim that vector rank currently reduces base cooldown was incorrect; preserve this existing behavior rather than implement a redundant fix.
- The global `haste` multiplier scales cooldown today. In addition, PAYLOAD modules `overclock` and `race_condition` contribute ranked `cadence_mult`. Removing global haste alone does not satisfy trigger-only cadence.
- Bare rows already work at `BARE_CADENCE = 1.30`; fused heads deliberately bypass the bare penalty because their trigger is embedded.
- `Loadout.start(packet, interval)` places both modules. `_interval_count` counts equipped and fused interval triggers, not bare vectors. Simply deleting the initial trigger lets a first event card replace the only unconditional firing path through an empty-slot placement.
- The upgrade UI shows raw `stats` and placement/rank labels. It does not currently show the resolved before/after result for each target row.

## Cadence and loadout contract

A normal vector contributes a fixed base cooldown. Only its equipped trigger contributes the firing cadence factor; a bare row instead contributes 1.5. Apply the existing proportional/absolute safety floors. No new cadence arithmetic depends on frame time or music timing.

A fused vector is a self-contained weapon with an embedded trigger and authored base cadence. Ranking its vector still never changes cooldown. Do not apply the bare penalty merely because the absorbed trigger slot is null. Preserve event cooldown/burst budgets and accumulated interval remainder in `run.gd`.

Change the starting API to `Loadout.start(packet)` and migrate every active-worktree caller; do not retain an unused compatibility argument. LSP currently locates runtime `_derive_roster` and fixtures in `test_build`, `test_slots`, and `test_meta_derivation`. Its results also include `.claude/worktrees/online-coop`: that is a separate worktree, not a migration target.

The safety rule is about the *resulting build*: every playable board retains at least one vector that fires unconditionally, whether bare, interval-triggered or fused-interval. Evaluate that rule for filling an empty trigger slot, replacing a trigger or vector, automatic placement, and fusion. Do not count empty vectorless rows as a firing source. Another bare vector makes an event trigger legal; an inert placeholder does not. Show the refusal as “Keep one automatically firing weapon,” not “last interval module” when the source is bare.

## Approved non-firing replacements (2026-09-04)

### Shop `cooling` → move speed

Move the `cooling` buff from `SaveGame.MULT_EFFECT` (`haste` delta) to `SaveGame.SHEET_EFFECT` as additive **`clock_speed`**, read by `run.gd` like `bus_speed`. Remove `haste` from `Compiler.MULT_KEYS` cooldown scaling entirely so no shop line touches exploit cooldown.

- **Saved ranks:** unchanged; only the effect namespace moves.
- **Recommended starting magnitude:** `+6.0 clock_speed` per rank (same step as `bus_speed`), subject to playtest; do not silently reuse the old `-0.03 haste` delta on a different stat without measuring feel.
- **Shop copy:** replace “attack speed” wording in `meta_screen.BUFFS` and any runtime comments that claim cooling controls fire rate.
- **Preview cards:** show resulting move speed where a cooling rank is relevant; cooling no longer appears in exploit cooldown previews.

`PlayerStats.BASE_MULT[&"haste"]` is removed. Old or hostile haste deltas are dropped.

### Payloads → self-contained fast shields

The recovery-only prototype could not work: each row has one payload slot, so
neither payload can sit beside `checksum`. The user selected **own fast shield,
no new stat** instead. No `rearm_mult` or post-MAX transform remains.

| Module | Damage | Shield at rank 1 | Rearm |
|---|---|---|---|
| `overclock` | +2.0 | 12 | 1.6 s |
| `race_condition` | — | 10 | 2.0 s |
| `checksum` (unchanged reference) | — | 26 | 2.6 s |

These magnitudes are implementation tuning, not separately user-picked numbers.
Ranks increase shield capacity but not rearm or firing cadence. Existing MAX
folding remains unchanged. Fused recipes retain their authored stats; neither
input payload's former cadence multiplier was inherited dynamically.

Rearm gates weapon **emissions**: after the timer elapses, the next emission
refills the shield. Neither payload provides autonomous regeneration.

## Bounce: worked comparison

The approved base-radius reduction retains the shared `VECTOR_RADIUS_RANK = 0.25` rule. Per-rank radius growth falls from 47.5 to 37.5 world units; fractional growth stays 25% of base. Avoid a bounce-id special case in the compiler. Radius at rank 5 changes from 380 to 300, before other modules or shop reach. Base knockback remains 320 and its existing rank behavior remains unchanged.

All numbers below assume no payload, no shop buffs and no bonus trigger damage. “Interval” means rank-1 `interval`; “bare” includes the current/proposed bare penalty. DPS is single-target theoretical throughput with every pulse landing, not observed run damage.

| Rank / condition | Current damage | Proposed damage | Current period | Proposed period | Current DPS | Proposed DPS |
|---|---:|---:|---:|---:|---:|---:|
| 1 / interval | 2 | 1.4 | 1.10 s | 1.50 s | 1.818 | 0.933 |
| 1 / bare | 2 | 1.4 | 1.43 s | 2.25 s | 1.399 | 0.622 |
| 5 / interval | 10 | 7 | 1.10 s | 1.50 s | 9.091 | 4.667 |
| 5 / bare | 10 | 7 | 1.43 s | 2.25 s | 6.993 | 3.111 |

The earlier proposal mislabeled the interval DPS as “no trigger.” It also cited a prior 30% balance pass as if that justified another identical cut. These are approved candidate numbers, not a derived optimum or measured guarantee. Bare throughput falls about 55.5%; interval throughput falls about 48.7%. Circular area falls about 37.7%, not just the 21.1% radius reduction. Crowd damage and knockback uptime require an actual scenario measurement.

Rank-1 `on_hit` recovery changes from 1.1 × 0.62 = 0.682 s to 1.5 × 0.62 = 0.930 s before floors. This is a cooldown ceiling on qualifying events, not a periodic fire promise. Higher trigger ranks can still reach the existing floor; that is allowed trigger progression.

## Upgrade language and presentation

Use an existing-file implementation in `ui.gd`, not a parallel compiler. On highlighted row, construct an isolated prospective exploit using the same placement semantics and compile it through the build layer. Never mutate the live loadout, consume RNG or stage a pick while previewing. Cache the comparison for the displayed offer/target; do not clone/compile each draw frame.

Display the module identity and a short action sentence, then the affected resolved values for the selected exploit. Examples are illustrative, not literal string-test contracts:

| Change | Required meaning |
|---|---|
| Bare packet receives interval | “Fires automatically: every 0.75 s → 0.50 s.” |
| Bounce rank 1 → 2 with interval | “Damage 1.4 → 2.8; pulse radius 150 → 187.5; firing interval unchanged at 1.50 s.” Include other actually changed stats, such as knockback. |
| Event trigger | Name the event plus minimum recovery, rather than claiming an attack every N seconds. |
| Replacement | Show the full resulting effect, including lost payload/trigger contributions and a changed firing condition. |
| Defensive effect | State pool/mitigation, duration and rearm separately. Do not call a shield pool health or rearm an automatic refill. |

Keep the hacking-themed names. Use plain-language labels and units instead of `cadence_mult +...`. Precision must preserve meaningful 1.4 damage and 0.75-second differences without excessive decimals. Long comparisons must remain readable with five rows, keyboard, mouse and controller at 1280×720.

## Acceptance and risks

1. A fresh solo and four-slot run begin firing packets without trigger modules; the first event-trigger choice cannot strand the last firing source. Legal placement and fusion stay possible when another unconditional source exists.
2. Rank-1 and rank-5 copies of every vector retain the same base cooldown. Bare/equipped/fused conditions, global haste and payload replacements obey the revised contract, including cooldown floors and burst semantics.
3. The player-visible preview equals the actual result of applying the staged choice, including replacement losses; previewing alone changes neither simulation state nor RNG.
4. Bounce's new per-target damage, radius and emission timings match the table in a live scenario. Shield recovery, if chosen, demonstrably changes a supported build and is explicitly conditional elsewhere.
5. `tools/run_tests.sh` passes after integration; measure changed performance coverage rather than quietly lowering pins. Windowed card/shop checks and real combat playback are required before claiming the feature verified.

Slower starter fire, weaker bounce and slower leveling all reduce early power. Measure weapons independently, then together with the leveling proposal. Do not change enemy density or player survivability merely to make an old performance fixture pass.
