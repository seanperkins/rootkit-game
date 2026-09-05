# Teleporters, routes and subnet exploration

September 5, 2026. The user chose both larger arenas and hidden side rooms,
replacing the earlier connected, pre-generated three-arena campaign.

## Transition

Boss death powers the in-arena transfer apparatus, banks the clear and starts
the existing 75-second arena-collapse clock. The lit floor route leads to the
pad. Every LIVE player's full footprint must fit within its 72-unit radius.
Boss death alone never opens a ballot; the final boss still wins immediately.

Three distinct route IDs are drawn from the dedicated route RNG. Each eligible
player submits one tick-addressed ballot using the ordinary offer/input flow.
The voter roster freezes at open. Departures preserve a cast ballot or take
option zero; returns do not receive another vote. Multiplayer uses the existing
configured deadline and first-option timeout; solo has no deadline. A unique
plurality winner consumes no tie RNG. Only tied leaders can win a tie. The ballot
board stays visible after voting, with disabled buttons and live tallies.

Voting pauses the world and collapse while input and roster processing continue.
A committed result starts a 90-tick transfer: 54 ticks of charging/upload,
then destination generation and 36 ticks of materialization. The simulation
holds during the animation. All LIVE players arrive at distinct reserved
positions, with previous/render positions reset and no old velocity. Builds,
XP and level carry; integrity receives the existing 30% clear heal. Transient
populations and old terrain are released. Last-LIVE loss cancels advancement.

## One loaded subnet

The default main arena is 8256 × 4992, up from 7104 × 4416: about 31% more area.
The grid allocates that arena, its hidden-room footprint and its border, with
no inactive subnets or inter-arena bridges. Arena collision, zones, spawns and
room geometry derive from descriptor seed, subnet number and chosen route.
Terrain's local `current` index is zero; `subnet_number` selects its visual theme.

NORMAL is the baseline. HOT adds twelve disjoint 160 × 160 panels on clear
terrain, four each of hazard, slow and corruption, away from arrival/transfer
pads. COMPACT closes the outer eighth on each side, leaving a smaller central
region and an east service lane. Disconnected pockets are sealed and collision
cells are merged into exact visible wall rectangles. Compact layouts retain
at least half the allocation as reachable ground, and all open main-arena cells
must remain connected. HOT generation refuses a layout that cannot place all
advertised panels. Effects persist through the boss encounter.

| Route | Next-subnet changes |
| --- | --- |
| Swarm Exchange | +25% wave rate, −15% ordinary enemy integrity, +1 XP shard per enemy |
| Armored Archive | +25% ordinary enemy integrity, −15% wave rate, +150 boss salvage |
| Corrupted Relay | −25% corruption thresholds, +15% wave rate, +4 shared botnet capacity |
| Thermal Overflow | 12 extra terrain panels; +150 boss salvage |
| Hunter Protocol | Every third attempted wave spawn becomes a tracer, same wave count; +150 boss salvage |
| Early Interrupt | First miniboss at 55s instead of 80s, other arrivals unchanged; +150 boss salvage |
| Compressed Core | About 40% less open ground than NORMAL; +150 boss salvage |

These are initial balance values, not the result of a campaign balance study.
Boss/miniboss identities and their integrity are unaffected by ordinary-enemy
HP modifiers. The extra shard is integer-valued and collected through shared
XP once; there is no fractional rounding or multiplication per teammate.

## Hidden archive

Each subnet has a concealed 960 × 768 archive behind the east service port.
Completing that subnet's vault, relay or upload job reveals and opens its floor
and a 192-unit connecting passage. The entry approach is reserved at generation.
The chamber and link are solid and undrawn until revealed; opening them never
changes existing rectangle/zone indices. Its terminal pays 100 shared salvage
and a rank offer for every LIVE player once. The room participates in collapse;
exploration never gates the boss or teleporter.

## Presentation and recovery

The teleporter is procedural hardware: a raised octagonal circuit platform,
four animated emitters, counter-rotating segmented rings, a suspended holographic
crown and bounded rising data fragments. Power-up raises the emitters; upload
accelerates the rings and grows a cyan column while craft fade out. Arrival
uses individual columns and expanding rings as craft fade back in. Synthesized
charge/arrival sounds follow simulation events. All drawing clocks live in the
presentation node and never enter a checksum.

Gameplay protocol is 6; snapshot version is 3. Candidate IDs, voter mask,
ballots, chosen route, transfer tick count, room unlock and reward flags are
hashed and snapshotted. Restore validates related ballot fields and actual zone
array lengths before any write, reconstructs the destination before dynamic
state, then rebuilds collapse and presentation caches. The seed-derived terrain
cells are not duplicated in snapshot bytes.

## Review

`godot -s res://tools/shot_teleporter.gd` produces windowed review captures for
inactive, active, voting, charging, arrival and archive states in `.tmp/`.
`test_teleporter` covers four-player input-driven gathering/voting/transfers,
mid-vote and post-transfer recovery, all seven real destination effects, room
unlock/reward recovery and last-LIVE loss. Existing campaign, gate, collapse,
terrain and network tests retain their substantive behavior checks with the
new transition contract. Runner logs are retained in `.tmp/test-logs/`.


## Validation results

The 24 affected functional suites passed through `tools/run_tests.sh`, including
campaign, collapse, terrain, offers, snapshots, recovery/reconnect, multiplayer
simulation, input, HUD, audio IDs and the new teleporter suite. Both four-player
transfers and the final win were driven by scripted inputs. The windowed capture
driver dispatched keyboard, joypad and mouse events through Godot, checked their
staged choices, consumed a ballot through lockstep, and verified the submitted
ballot remains visible and disabled. This is engine-event input smoke, not a
physical-controller or internet multiplayer playtest. Review images were
inspected at 1280 × 720.

A five-seed generation survey (20260830, 1, 42, 12345, 987654) tested all three
layouts on all three subnets: 45 combinations, no generation/spawn failures,
and every revealed archive reachable. It used a conservative 12-unit player
footprint (the shipped player radius is 11). Measured headless on this Mac:

| Allocation | Grid cells | Generation median | Range |
| --- | --- | --- | --- |
| Previous connected campaign | 123,444–169,344 | 92.30 ms | 73.12–96.76 ms |
| Single NORMAL subnet | 57,240 | 24.33 ms | 24.03–27.13 ms |
| Single HOT subnet | 57,240 | 24.43 ms | 24.26–26.09 ms |
| Single COMPACT subnet | 57,240 | 45.09 ms | 44.28–48.68 ms |

These are generation-only timings, excluding spawn validation and presentation
cache rebuilding. Destination generation is synchronous during the transfer.

The previous build (`357a277`) was measured in a detached checkout and reproduced
its pinned workload: died at tick 22194, mean enemies 236.1, hits/tick 0.98,
kills/tick 0.281; normalized p95 10.113 ms. The first new measurement exposed an
existing fixture omission: bots did not submit valid route ballots. That paused
measurement was discarded and the shared fixture was corrected.

With valid ballots, the new fixture reached subnet 2, 78.6 world seconds into
its fight, at the 24,000-tick cap with no pending vote: mean enemies 211.5,
hits/tick 1.16 and kills/tick 0.286. The coverage baseline records this changed
world/path/averaging span, including the fresh destination's opening waves;
its lower enemy mean is not presented as an isolated speedup. The original
11 ms reference timing budget and coverage tolerance bands remain unchanged,
and the gate now also requires a completed transfer and no pending ballot.

Final runner result: **PASS, 8.849 ms p95 / 11.278 ms calibrated budget**.
The completed-transfer coverage checks passed with the documented workload.
The standalone manual was regenerated successfully.
