# Programs, network jobs, routes and co-op

Implemented on `codex/entity-designs`, on top of the entity and HUD redesign.

## Starting programs

Choose a program in the main menu before hosting or joining. The lobby shows
teammates' choices and freezes selection while connected. Selection persists
as a sanitised preference; the immutable session descriptor carries the actual
choice into a run. Remote builds never read this machine's preferences.

| Program | Starting build | Tradeoff |
| --- | --- | --- |
| Operator | packet() | Original balanced stats |
| Ghost | spike() | 20% faster movement, 20% less integrity |
| Bulwark | broadcast() | 25% more integrity, 15% slower movement |
| Virus | chain() + corrupt | 20% less weapon damage, 15% less integrity |

These are starting configurations, not restrictions on future cards. Sheet
modifiers apply after permanent upgrades. Every starting vector fires without
requiring a trigger card. Operator preserves the original opening balance.

## Optional network jobs

Each subnet offers one job after 20 seconds. Placement retries once per second
until it finds a clear approach with space for the player's body. Uploads also
require a clear path to their destination. The HUD shows the job, direction,
distance, progress and reward; the world shows its capture footprint and console.

- **Subnet 1 — Vault breach:** hold the zone for 12 seconds. Pays 75 shared
  salvage and a rank offer for each LIVE player.
- **Subnet 2 — Relay hijack:** hold for 12 seconds. Pays 75 shared salvage and
  activates a shield charger and automated pulse for the rest of the fight.
- **Subnet 3 — Upload escort:** stay with the moving node along its 240-unit
  upload path. Pays 75 shared salvage, a rank offer for each LIVE player and
  20% integrity recovery.

Jobs are optional and never gate the boss. Leaving pauses progress. A completed
job pays once; unfinished jobs are abandoned when leaving a subnet. They shut
down for the boss and collapse so they do not compete with either encounter.
A reinforcement arrives every four seconds of active hacking. Normal waves
continue throughout the job. Rank offers use the existing maxed-build fallback.

## Co-op interactions

Additional LIVE players within the 90-unit capture area add 40% hack speed each:
1 / 1.4 / 1.8 / 2.2 times solo speed. Walls block uplinks; DEAD and ABSENT slots
never contribute. The escort uses the same rule.

A captured relay links players within 210 units, with line of sight. Every
second it restores 2 shield per linked player to **each** linked teammate,
up to an 18-point relay shield. Existing stronger weapon shields are preserved.
It also deals 6 damage per linked player to enemies in range through the normal
combat event queue. Solo remains useful; grouping strengthens both effects.
Leaving range stops recharge and pulse support. Green tethers identify links.

## Route votes and teleporters

See [Teleporter and subnet generation](teleporter-subnets.md) for the completed
transition, expanded seven-route pool, larger arenas and hidden archives.
All LIVE players gather on the pad after boss death. Three distinct routes are
sampled from the shared seeded stream. Each player stages a normal input choice;
plurality wins and only tied leaders enter a draw. Eligibility freezes when the
vote opens: departures keep a cast ballot or take option zero; returning players
do not receive a second ballot. Multiplayer retains the configured deadline;
solo remains deadline-free.

The transfer charges for 54 consumed ticks, builds the selected destination,
and materializes the party for 36 ticks. Only one subnet's terrain is loaded.
The next route replaces the previous route's effects; the final boss wins directly.
Completing each network job also reveals its subnet's hidden archive.

## Verification

`test_network_expansion` covers program derivation and HELLO sanitisation,
objective placement, co-op capture, one-time payouts, relay pulse/shield scaling,
upload completion, unfinished-job recovery, mixed-program snapshots, ballot
recovery, invalid inputs, hostile vote snapshots, unanimous and tied votes,
modifier application, departure/return handling, and timeout auto-votes.

Gate, campaign and plurality tests now include the route choice at the arena
boundary. All new mutable gameplay state and the independent route RNG are in
the hash/snapshot manifest. Gameplay protocol is 5 and snapshot format is 2;
the standalone relay protocol is unchanged.

Review captures: run `godot -s res://tools/shot_network_expansion.gd` windowed.
Images are written to `.tmp/expansion-{programs,relay,routes}.png`.

Validation on September 4, 2026: all 62 functional suites passed across the full
runner and focused reruns. The full run first found the old immediate-advance
assertion in `test_gates`; that test was updated for voting and passed on rerun.
The final focused run passed network expansion, gates, card navigation and menu
layout with no script errors. The performance gate passed at **9.418 ms p95**
against a **9.815 ms** calibrated budget. Windowed captures were inspected at
1280 × 720. Balance numbers are an initial tuning pass, not a multiplayer
playtest verdict.

### Main integration — September 5, 2026

Merged with reserved player spawns, world visuals and menu navigation.
The windowed controller-event smoke found that manually emitting `pressed`
bypassed the starting-program OptionButton's native popup behavior. Activation
now uses Godot's native `ui_accept`, mapped to keyboard and controller A;
`ui_cancel` includes controller B.

Verified in a real window using engine-dispatched joypad events: D-pad reaches
the selector, A opens it, D-pad/A selects Ghost, the preference persists, B
cancels without changing Ghost, and starting a run equips Ghost's spike weapon.
`test_input` retains popup selection/cancellation regression coverage. The
throwaway end-to-end driver was removed after verification.

All 32 selected integration suites passed through `tools/run_tests.sh`, followed
by five controller/menu/network-expansion suites after the input fix; no script
errors. The final separate perf run passed at **9.566 ms p95 / 9.972 ms scaled
budget**. Windowed entity and route/relay captures were inspected. This is focused
integration verification, not a new full-suite or physical-controller playtest.
