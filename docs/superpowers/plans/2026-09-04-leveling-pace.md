# Leveling pace implementation and measurement plan

Date: 2026-09-04. Status: implemented; automated validation and a full campaign win verified. Human playtesting remains. See [implementation and measurements](../../progression-bosses-music.md).

Spec: [Leveling pace](../specs/2026-09-04-leveling-pace-design.md).

## Prerequisites

Weapons and starting-loadout changes must have a settled contract before final joint tuning. A baseline may be measured on the current game first, but label it separately from the revised-weapons baseline. New bosses and modifier cards require an additional final campaign check after integration; they do not block isolated curve measurement.

Use LSP for `_xp_for` references and related definitions before changes. Main integration owner owns `run.gd`; do not let a benchmark worker edit that file concurrently with terrain/boss/music integration. The measurement driver may gather diagnostics but must not add telemetry to shipping simulation or consume its RNG.

## Steps

1. **Capture attributable baselines.** Build a disposable driver using the real `scenes/run.tscn` and existing headless seams. Read `tests/support/perf_fixture.gd` before reusing policy helpers; omit prefilled worst-case builds, immortality and forced boss wins. Isolate SaveGame paths/counters. Drive real staged card choices and transitions. Run the matrix in the spec, recording raw outcomes for all seeds, including deaths and timeouts. Instrument the driver to separate XP-earned rounds, miniboss bonus rounds, blocks, fusion and declined rewards without altering RNG. No attempt to disprove the user's first-level maxing report.
2. **Change the curve only.** In `scripts/run/run.gd:_xp_for`, implement the recommended late-level surcharge or the next candidate justified by baseline data. Keep `_gain_xp` remainder/while-loop and per-slot offer machinery intact. Ensure initial `xp_needed` and later thresholds derive from the same function. Preserve deterministic integer/double operations and avoid `pow`. Annotate chosen tuning and motivation in the source; do not change shard counts, pickup radius, wave rates, player stats or miniboss rewards in this step.
3. **Run paired progression scenarios.** Rerun exactly the same profiles/seeds/policies using the real run. Compare all upgrade sources and player survival, not just final level. When a run dies, retain the failed outcome and last checkpoint. Inspect an actual windowed solo run to assess downtime and choice frequency. If growth still front-loads, identify which reward source contributes before proposing another lever. Do not reduce pickup reach automatically. Record candidate decisions and rejected curves in the maintained specification.
4. **Verify contracts and integrated difficulty.** Update any existing tests whose XP contract actually changes. Keep or add only behavior coverage for remainder/multiple thresholds, queued rounds, and snapshot/peer agreement; avoid pinning a whole guessed level curve as a test. After all source edits settle, run `tools/run_tests.sh` with real UDP support (the runner supports named suites; run all once integrated). This includes the perf gate; investigate coverage movement and INCONCLUSIVE outcomes rather than treating exit 0 alone as proof. Later rerun the campaign driver against the actual teleporter/modifier/boss mechanics; teach its policy to capture spires and damage the real boss, never bypass the encounters to claim campaign viability.
5. **Publish measured decision and clean up after smoke.** Record the selected formula, profile/seed matrix, per-subnet upgrade counts and survival ranges, including limitations. Preserve source rationale and relevant manual/README updates, not stale generated codemaps. After successful measurement and smoke, remove the throwaway driver and generated UID/output files from the project. Do not add a permanent expensive campaign suite merely to preserve one tuning experiment.

## Completion evidence

| Evidence | Must demonstrate |
|---|---|
| Cost arithmetic | Positive monotonic cost, preserved early levels, correct boundary rounding and no practical overflow |
| Real run output | Full paired rows; useful early builds and later meaningful decisions; no omitted failures |
| Multiplayer scenario | Same XP, pending rounds, picks and hashes through pause, parking and snapshot restore |
| Windowed play | Acceptable choice frequency and viable progression with the revised starter and bounce |
| Runner | All required suites pass, no script/parse errors, performance judged rather than silently inconclusive |

No exact target rank count or final multiplier is declared approved here. Implementation must return measured tuning, not a “steeper curve” claim backed only by formula calculations.
