# Progression, bosses and the action ensemble

Implementation record, 2026-09-05. All three features are implemented. Automated campaign, functional and performance checks have passed. Follow-up coverage includes eighteen first-boss balance cases, cross-architecture determinism and live internet relay delivery. Human listening, physical-controller feel and full internet co-op playtesting remain unverified. This record supersedes the candidate numbers in the September 4 plans.

## What changed

- **Progression:** costs through level 20 retain the existing 1.8 multiplier. Later costs add `floor((max(0, L-20)^2 + 1)/2)`. XP remains shared, preserves its remainder and pays every crossed threshold. Shard value/count, pickup reach, enemy density/HP, shop stats and direct miniboss/block rewards were not retuned alongside the curve.
- **Sentinel Array:** four safe, connected capture spires; hold within 90 units for seven seconds each. Unoccupied progress drains at 1.5 seconds per second; completed captures persist. Multiple players can capture different spires together. The shielded core is stationary and excluded from targeting, contact, direct damage, zones and corruption. All four captures expose it on the next world tick.
- **Worm.exe:** one 550-base-HP head and seven 80-base-HP bodies. Only head death clears the encounter. A 12-second interval without positive landed damage can spend one of four regeneration events, adding a segment up to ten total or healing the head by 15% of scaled maximum at the cap. Segment indices remain unique and trail-safe; the budget never refills.
- **Root Cause:** ambush above 66% HP, a telegraphed three-shot fan between 66% and 33%, then charges. Large hits skip phases directly. Its charge direction locks at the warning; ordinary chargers retain their existing launch-time targeting.
- **Music:** ten logical voices (six enemy roles plus four player slots) consume a bounded event mask on eighth-note beats. Seven synthesized buffer families share the existing scale/chords. Notes come from actual actions and successful emissions. Chase/flank accents use rising edges rather than enemy counts. Dedicated players protect ensemble notes from ambient voice stealing; pending notes clear across pause, mute, recovery, transfer and end transitions.

Boss identity now resolves by stable ID rather than table position. Boss simulation fields participate in snapshot validation/checksums; music masks, edge latches and visual flashes do not. Protocol 7 refuses older simulation peers; snapshot format is 4.

## XP experiment

The initial approved formula was explicitly experimental. Actual normal-run bots rejected its onset-at-6/divisor-4 version: all three fresh four-player policies died before the first boss. Halving that surcharge still lost two policies. Moving the onset to 20 preserves more early build development.

Paired **pre-boss-implementation** comparison, seed 20260830, fresh counters, four ordinary players, one bare packet initially. Movement and staged-card policy are identical across versions; no immortal teammates or performance loadouts. Changed choice counts change RNG consumption, so combat histories are not identical.

| Policy | Old curve | Onset 6 / divisor 4 | Onset 6 / divisor 8 | Selected onset 20 / divisor 2 |
|---|---|---|---|---|
| Breadth | Reaches first boss at level 63; eventually wins campaign | Dies at 223 s, level 37 | Dies at 238 s, level 38 | Dies at 262 s, level 44 |
| Rank | Dies at 250 s, level 57 | Dies at 299 s, level 40 | Dies at 282 s, level 48 | Reaches first boss, level 48 |
| Corruption | Reaches first boss at level 66 | Dies at 255 s, level 39 | Reaches first boss, level 51 | Reaches first boss, level 50 |

This supports a later onset but does not establish human feel or prove every build is equally viable. The selected corruption run earns 49 versus 65 XP rounds at the first boss (25% fewer); rank-capped equipped slots fall from 41 of 52 to 21 of 52 in that paired comparison. Both old and selected curves reach that boss with two of three policies; the identities of the surviving policies differ. Fresh solo baseline bots die around 203–240 seconds at levels 6–7, unchanged in the tested early-preserving candidates.

Raw observations are in [measurements/2026-09-05](measurements/2026-09-05). They include deaths, timeouts and partial runs, not just successes. Baseline coverage includes fresh/moderate/full profiles and solo/four-player parties; candidate coverage is narrower. This is **not** the full recommended five-seed, eighteen-profile/policy campaign matrix. Moderate profiles use rank 4 for every shop buff, 1,000 kills and 100 flips; full profiles use rank 10, 100,000 kills/flips. The baseline ran up to 72,000 input ticks; gentle/late comparisons stop at 19,000. Compare first-subnet checkpoints, not their unequal total play limits.

The temporary instruments are archived as text in the measurement folder, outside the permanent test runner. Copy `progression_survey.gd.txt` to `tools/progression_survey.gd` to rerun; filters include `label=`, `seeds=`, `profiles=`, `parties=`, `policies=` and `limit=` after Godot's `--`. It drives real movement/aim and staged choices, including spire navigation and route votes. Its newer records add total stepped world time and first observed fusion time. Earlier records use director time, which stops at 300 seconds during a boss: those values must not be described as boss fight durations. Damage observations count `_damage_player` losses, not every direct zone-health adjustment. Raw `uncollected` is live shard count, not a lifetime XP deficit.

## Verification

- All **66 functional suites** passed after feature integration, including real UDP loopback/relay, deterministic multiplayer, recovery, hostile snapshots, boss mechanics, progression and ensemble lifecycle. All eight affected suites also passed after selecting the final curve and simplifying rendering: progression, bosses, ensemble, interpolation, draw order, arrivals, manifest and determinism rules.
- Windowed boss screenshots checked capture progress/core shielding, Worm.exe head/body distinction, Root Cause's fan warning and locked charge warning.
- Windowed engine-event smoke passed keyboard, joypad-button and mouse route selection, lockstep submission and disabled submitted ballots. This verifies Godot input handling; it is not a physical-controller test.
- The actual Music bus was recorded to `.tmp/ensemble-review.wav`. Structural tests verify all ten voices, diatonic pitch mapping and buffer duration at the fastest beat. Cold full-bank generation measured 3,021 ms; synthesizing the seven voice families with initialized wave tables measured 149 ms, and a cached bank call took 0.002 ms. These are local measurements, not a hardware-independent startup promise. Twenty-four sampled pre-existing SFX buffers remain byte-identical after adding optional vibrato; zero-vibrato defaults are omitted from the deterministic noise seed.
- Human listening, physical-controller feel and full internet co-op remain unverified. Godot reported no connected controllers. The desktop computer-use connector still could not start because cmux onboarding was in progress; engine-event and windowed rendering checks remained available. Cross-architecture and internet transport probes are recorded below.

### Follow-up: circuitry, cadence and wider coverage

Floor circuits now use uneven clusters, open areas, varied dimensions, quarter turns, mirrored layouts and optional branches/pins. The three subnet motifs remain distinct. Placement uses a local visual RNG; it does not consume simulation randomness. Geometry still uses two cached multiline commands per patch. The windowed screenshot tool now advances runtime subnets instead of indexing three simultaneously loaded arenas. All three subnet screenshots were inspected after the change.

The busy four-player mixer probe exposed an almost continuous chase accent at the old separation-force threshold of 15: 226/234 beats, with a longest streak of 166. Candidate force crossings measured simultaneously in the same field supported raising the presentation-only threshold to 210 (95/225 beats, longest streak 16). A final run with the shipping threshold recorded **74/236 beats, longest streak 8**. Runs vary with frame timing, so these are cadence observations rather than a fixed acceptance percentage. The roughly 61-second final recording peaked at 0.775 on Master and 0.444 on Music, with no samples at or above 0.99 full scale. This checks digital headroom, not human judgments of timbre or musical balance. The fixture did not emit flanker notes; those remain covered by structural tests rather than this recording.

The expanded balance survey used seed 42, real movement/choices and the final bosses/curve, stopping at first-boss arrival, death or 21,000 input ticks. It reached the boss in 15/18 cases:

| Profile / party | Breadth | Rank | Corruption |
|---|---|---|---|
| Fresh solo | Death, L26, 274.52 s | Death, L22, 194.67 s | Death, L25, 268.77 s |
| Fresh four | Boss, L50 | Boss, L50 | Boss, L51 |
| Moderate solo | Boss, L29 | Boss, L29 | Boss, L26 |
| Moderate four | Boss, L51 | Boss, L52 | Boss, L51 |
| Full solo | Boss, L31 | Boss, L33 | Boss, L30 |
| Full four | Boss, L53 | Boss, L53 | Boss, L52 |

Every boss arrival is at 300 stepped world seconds. Matched fresh-solo runs with only the late XP surcharge removed also died: breadth L27 at 278.57 s, rank L22 at 194.67 s, corruption L25 at 268.78 s. These failures therefore do not establish a new solo regression caused by the curve. This is one seed and first-boss coverage, not eighteen full campaign wins or the five-seed matrix. Fusion pacing and human balance remain open.

The Linux arm64 and x86_64 Godot 4.7 determinism probe produced byte-identical output: **1,801 lines over 1,800 ticks**. That finite workload does not exercise every boss or subnet transition. Live internet relay probes delivered input records in both directions, including after the five-second direct-punch timeout (137 ms joiner-to-host, 21 ms host-to-joiner in that sample). Three clients received punch candidates, but no direct links formed on this Mac/network. Relay fallback works here; direct NAT punching and full play across separate machines/networks remain unverified. No relay deployment was changed.

[Follow-up evidence and rerun instructions](measurements/2026-09-05-followup/README.md) preserve raw observations and temporary instruments. Draw order, ensemble and determinism-rule suites passed after the circuit/cadence changes. Windowed probes reported two ObjectDB instances leaked at exit; their logs retain that warning. Their frame timing is observational, not a replacement for the serial performance gate.

The final serial gate also passed: **7.952 ms real-run p95 against a 9.719 ms machine-scaled budget**, with the same workload pin and completed-transfer requirement. [Raw output](measurements/2026-09-05-followup/performance.txt) preserves calibration and coverage. Temporary probes were removed from `tools/` after archiving.

### Integrated campaign

The final curve and all three bosses were played through with actual inputs, earned upgrades and route choices: seed 20260830, fresh four-player roster, corruption-oriented policy. Three players survived; no health/build writes were used after session setup. The campaign won at level 70 after 1,429.15 stepped world seconds. No fusion occurred under this policy, so this run does not verify fusion pacing.

| Milestone | Total stepped world seconds | Level | XP collected | Rank-capped equipped slots, players 0–3 |
|---|---:|---:|---:|---|
| First boss arrives | 300.00 | 50 | 11,195 | 5, 7, 4, 5 |
| Subnet 2 arrival | 447.55 | 50 | 11,737 | 5, 7, 4, 5 |
| Second boss arrives | 747.55 | 61 | 21,726 | 11, 9, 10, 5 |
| Subnet 3 arrival | 888.65 | 62 | 22,930 | 11, 9, 11, 5 |
| Third boss arrives | 1,188.65 | 69 | 33,296 | 12, 12, 12, 5 |
| Campaign won | 1,429.15 | 70 | 34,235 | 12, 12, 12, 5 |

Each player held thirteen equipped slots; player 3 died before the first boss and remained at five capped slots. Thus the surviving players continued gaining ranks in subnets 2 and 3. This one successful run demonstrates campaign viability under its recorded policy, not a population-level balance conclusion.

Separate low-DPS encounters started directly at each boss with one rank-1 bare packet per player and declined every offer. They are encounter probes, **not campaign completions**:

| Party | Sentinel | Worm.exe | Root Cause |
|---|---|---|---|
| Solo | Clear, 195.32 s, no damage | Clear, 216.27 s, 86.4 damage | Death, 123.18 s, ambush phase |
| Four | Clear, 111.32 s, no damage | Clear, 205.77 s, no damage | Death, 250.33 s, barrage phase |

These retain the expected distinction between a minimally equipped build and the earned late-campaign build. The Worm probes and focused tests exercise bounded recovery without an endless regeneration loop. They do not replace human judgments about encounter length.

### Performance

The benchmark now allows 30,000 input ticks (500 seconds), retaining a bounded run while accommodating capture holds and cross-arena travel. The earlier tree was remeasured immediately before the final curve/render tree: normalized p95 10.031 ms, reproducing the old workload. The final curve/render build measured **9.475 ms normalized p95**, within the unchanged 11 ms budget. Calibration differed between these serial measurements, so this is budget evidence, not a controlled speedup percentage. It still failed workload/transfer coverage at the old cutoff. The fixture's cleared walk now uses connected-cell navigation to reach the teleporter instead of local wall avoidance, which can stall after the capture circuit.

The first integrated gate completed the first transfer but failed the prior workload pin: mean enemies 182.4 versus 211.5, hits/tick 1.47 versus 1.16, kills/tick 0.254 versus 0.286. The capture/travel encounter adds time without a normal wave field. Its normalized p95 was 13.548 ms against the unchanged 11 ms budget, so changing coverage alone would not make it pass. Profiling found rendering, movement and grid rebuild dominate; the boss bookkeeping itself is small. Final rendering caches packed arrays and avoids redundant identity rotation/scale construction.

With the corrected 500-second horizon, the fixture completed its transfer and reached subnet 2 at 95.0 world seconds: 156.4 mean enemies, 0.99 hits/tick, 0.248 kills/tick, zero queue drops, normalized p95 8.657 ms. The workload baseline was updated to these measured values with the old/new results and the capture/travel/averaging reason retained in `tests/perf_milestone0.gd`. The timing budget, tolerance bands and completed-transfer requirement remain unchanged.

Final acceptance rerun: `test_run`, `test_campaign`, `test_collapse` and `perf_milestone0` all passed with no script errors. Real-run p95 was 7.812 ms against a 10.348 ms machine-scaled budget. [Raw performance output](measurements/2026-09-05/final-perf.txt) records calibration and unchanged workload coverage; the measurement folder also preserves the earlier full functional run and final affected-suite runs. The manual was regenerated, the editor imported the final scripts, local document links and `git diff --check` passed, and disposable probes were removed after archiving their source. Generated codemaps were left untouched because no regeneration command was available in the repository.
