# Teleporter vote implementation plan

Date: 2026-09-04. Historical plan. The September 5 user decision supersedes the
preplanned campaign/bridge work with one loaded subnet, larger arenas and hidden
archives. See [implementation record](../../teleporter-subnets.md).

Spec: [Teleporter and vote](../specs/2026-09-04-teleporter-vote-design.md).

## Ownership and prerequisites

Depends on `Terrain.spawner_pos` and shares boss identity/clear logic with the three-boss feature. One integration owner owns changes to `run.gd`, `terrain.gd`, `ui.gd`, manifest helpers and shared fixtures. Independent workers may own modifier data or rendering only under the agreed interface. Use LSP references for changed symbols; do not text-rename across other worktrees. Skip validation while concurrent edits are in flight.

## Steps

1. **Define modifier and layout contracts.** Add the pure `data/level_modifier_table.gd` registry with stable IDs, validated effect kinds, magnitudes, descriptive units and separately named rewards. Cover all seven categories, including early/extra encounters and real playable-size changes. Finalize recommended risk/reward bundles before implementation; no free-form executable effect callbacks in snapshots. Define NORMAL/HOT/COMPACT IDs and the exact active-effect state shared by director/run/terrain. Keep base tables and roster scaling immutable.
2. **Prepare valid unopened-arena templates and spawns.** In `terrain.gd`, precompute templates inside the already reserved campaign footprints, preserving spawner pads, entry/exit and boss navigation. Include `solid`, zone maps/indices, render rectangles and derived metadata coherently. Ensure HOT really changes zone exposure and COMPACT really reduces playable area. Use a deterministic valid construction on failed random placement, never a silent NORMAL copy sold as a different layout. Add active variant selection/reconstruction and relevant cache rebuilds. Integrate the boss's arena-0 capture anchors before final generation validation. Measure generation work during final verification, not during parallel edits.
3. **Implement vote and transition as one ordered state change.** In `run.gd`, append LEVEL_VOTE, create a dedicated seeded RNG, candidates, eligible slots, ballots and one-time resolution state. Extend `_emit_local_offer`, choice staging/application, `_apply_first`, deadline/slot-exit paths and `_settle_offers` with explicit kind handling before module decoding. Guard duplicates/stale offers and recursive settlement. Add the visible corridor-side pad and target-boundary barrier; all LIVE player footprints gather outside the target allocation. On a valid result, clear transition entities, reset old effects/director, apply new effects/template in the correct order, advance terrain, then relocate LIVE players through `spawner_pos` and re-prime movement/interpolation. Preserve clear-heal/salvage banking exactly once. Cancel advancement on session loss/end.
4. **Wire actual effects, UI and recovery.** In `spawn_director.gd` and `run.gd`, apply HP/rate/bias/schedule/reward effects to real spawning, damage budgets and pickup/boss rewards; preserve counted fractional rewards deterministically. HOT geometry/zone effects must use actual hazard/slow/corruption semantics and survive the boss fight. In `ui.gd`/existing world drawing, render a recognizable teleporter, gather counts, three clear modifier cards, selected votes, waiting/deadline/result and spectators; support all existing input methods. Extend `STATE_FIELDS`, `_manifest_object`, snapshot validators and `_after_restore` for ballots, active effects, selected variants and `rng_vote.state`. Reconstruct geometry before restoring dynamic overlays and rebuilding caches. Update protocol/snapshot/build compatibility checks as required by semantic changes.
5. **Verify the integrated feature, then finish.** Migrate existing gate/campaign/collapse tests that intentionally assume continuous no-vote arrival; retain substantive clear/escape/death contracts. Add only worthwhile regression cases to offer/recovery or a focused vote suite: duplicate ballots, tied-winner RNG restore, slot exit, no-LIVE cancellation, transactional rejection, applied-and-expired modifiers and geometry reconstruction. A field-copy/table-count assertion is not evidence of an effect. Run `tools/run_tests.sh` after edits settle with real UDP available; inspect script/parse errors and performance verdicts. Run a windowed solo and co-op campaign with actual staged votes and both arrivals, including one mid-vote restore and one post-variant restore. Exercise controller, keyboard and mouse. Verify all modifier categories with a disposable real-run driver, not fake directors; record outcomes/generation cost/snapshot sizes. After successful smoke, remove disposable probes/UIDs and update maintained docs/manual and the intentional no-teleport invariant exception. Never hand-edit generated codemaps or commit/push without the applicable instruction.

## Required evidence

| Scenario | Observable guarantee |
|---|---|
| Two/three-way tie | Only highest-tally candidates can win; restored peers draw the same winner once |
| Deadline/park/return | Frozen voter-roster policy holds; no duplicate ballots or stalled offer; last-LIVE loss does not advance |
| HOT/COMPACT selection | Real advertised terrain effect, reachable entry/exit and safe arrival; no cell outside the target allocation changes |
| Snapshot after selection | Same collision, visible walls, zones, active modifiers, RNG and subsequent hashes |
| Early/extra miniboss and rewards | No duplicate/past-time spawn; correct shared reward with carried fractions and next-subnet expiry |

Keep a pre-change baseline for generation and performance coverage. A heavier or lighter workload must be explained and measured, not hidden by changing the gate's budget or dropping a selected category.
