# Spawner points implementation plan

Date: 2026-09-04. Status: planning only.

Spec: [Spawner points](../specs/2026-09-04-spawner-points-design.md).

## Shared boundary

Terrain owns reserved entry geometry and `spawner_pos`; the teleporter feature owns when the selected next-arena points are consumed. Boss generation owns separate arena-0 capture anchors. One integration owner serializes `terrain.gd` and `run.gd` changes. Use LSP references before changing their exported interfaces. No concurrent builds/tests/formatters while workers edit.

## Steps

1. **Reserve and validate points during generation.** In `scripts/run/terrain.gd`, add the four-point per-arena formation and `spawner_pos`. Derive orientation from incoming gate direction, not random trig. Integrate with existing entry exclusions, explicit pad clearing, corridor carving and the final reachability pass. Validate full player radius, zone clearance and bounds after boss-anchor placement. Preserve pads in every variant. Use an exported-build error path if generation cannot satisfy the contract; do not rely on stripped assertions or a same-entry fallback. Classify derived template fields correctly.
2. **Wire initial and returning slots.** In `scripts/run/run.gd:_derive_roster`, initialize each slot from its reserved point and prime previous/render positions. In `_return`, preserve proximity to a LIVE party, exclude already occupied LIVE footprints in a deterministic bounded search, and handle sequential same-tick returns. No-LIVE returns may use their slot's reserved point only after checking void/hazard/current layout. Do not change ending/revival rules to manufacture a safe return. The companion teleporter plan consumes `spawner_pos` on transitions; its integration must also clear stale movement/interpolation.
3. **Update meaningful existing coverage.** Extend the terrain and multiplayer/return suites already closest to the behavior (`test_terrain`, `test_terrain_run`, `test_plurality`, `test_reconnect`, `test_parking`). Defend pairwise separation, real traversability, slot stability, unsafe-layout refusal and simultaneous return placement. Test boundary cases and a forced-obstruction case, not merely that returned coordinates equal the same accessor. Migrate incidental origin assertions only where needed. New standalone suites are unnecessary for this feature.
4. **Verify after source edits settle.** Run `tools/run_tests.sh` with real UDP permitted; inspect script errors and performance verdicts. Exercise a windowed four-slot session using an isolated save, including first spawn, both teleporter arrivals and simultaneous reconnect. Verify actual positions, wall/hazard clearance and interpolation; use `tools/shot_slots.gd` only after checking that its scenario actually covers the desired state. Run snapshot/recovery against selected terrain variants as part of the companion vote verification.
5. **Finish after successful smoke.** Record formation rationale and the intentional teleporter exception in maintained project documentation. Remove disposable scenario drivers/screenshots/UID files from the project as appropriate. Do not hand-edit generated codemaps or issue commits/pushes merely because an old plan template did so.

Completion means separated valid player positions on the actual supported arrival paths, not simply a new `spawners` array that normal transitions never consume.
