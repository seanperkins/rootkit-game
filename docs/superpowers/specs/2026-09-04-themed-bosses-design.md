# Themed per-subnet bosses

Three bespoke bosses, one per subnet, replacing `EnemyTable.ICE`'s generic
role (ideas review item 6). Corrects that review's Sentinel Array mechanic:
it was written as **destruction** ("4 spires... destroyed"); the approved
intent is **capture** (hold-radius progress, like `Blocks`, not a second HP
bar). Nothing else in the review's mapping is re-opened. Coordinates with
[Spawner points](2026-09-04-spawner-points-design.md) and
[Teleporter vote](2026-09-04-teleporter-vote-design.md): modifiers can scale
a boss's stats, never reassign the subnet's boss identity.

## Decisions

| Question | Answer |
|---|---|
| Subnet mapping | 1 Sentinel Array (perimeter), 2 Worm.exe (malware), 3 Root Cause (kernel) |
| Sentinel mechanic | Capture: 4 fixed, non-combat spires; hold-radius progress; core shielded until all 4 captured |
| Worm mechanic | Real head + body segments, distinct HP; bounded regeneration suppressed by landed damage (recommended detailed rule) |
| Root Cause mechanic | One HP pool, 3 HP-fraction phases (AMBUSH -> RANGED -> CHARGE), computed from current HP, never stepped |
| Boss identity | Subnet -> boss-id table resolved once to a type index, never a "last N rows" rule |
| What clears a subnet | Only `_is_boss_kill`. Spires, segments, phase transitions never do |
| Clocks | Collapse starts only after `_is_boss_kill`; ordinary boss attack/capture/regen timers still run |

## Boss identity

`EnemyTable.ICE` is a raw index (`const ICE := 12`) that every reader
treats as "the last row" — the same fragility CLAUDE.md flags for
`VectorKind`/`TriggerKind`, misapplied here since `type_index` is
live-run-only and never persisted across a build boundary.

| Row id | Relation to `ice` | Glyph | Base integrity |
|---|---|---|---|
| `root_cause` | Is the renamed `ice` row: same glyph, colour `Color(1.00,0.25,0.85)`, same 550 base | 3 (unchanged) | 550 |
| `sentinel_array` | New row | 4 (unused gap in `glyph.gdshader`) | 550 (core) |
| `worm_exe_segment` | New row, shared by head + body | 14 (new branch) | differs by position — see Worm.exe |

`EnemyTable` gains a `subnet -> id` table and a shared name->index lookup.
Migrate `SpawnDirector` callers rather than retain a redundant wrapper.
Unknown required boss IDs fail initialization, never fall back to daemon.
Resolve boss indices once during run initialization
(`NOT_IN_MANIFEST`, constant per build, same status as `_fork_bomb_index`
today) behind two helpers: "is this entity's type the current subnet's boss
row" (replaces every `ti == EnemyTable.ICE` check), and "does killing
entity `i` end the subnet" (same, further restricted to `_worm_seg[i]==0`
for the worm, since one row covers head and body).

Every `EnemyTable.ICE` site migrates: `run.gd` lines 2269-2273 (spawn),
2318 (`boss_present`), 2464 (arrival flash), 3290 (`_approach_dir`), 3701
(`_on_death` win check), 3804 (straggler skip), 4659/5011/5016/5131 (draw
scale, integrity ring, arrival tint). `EnemyTable.ICE`, its "must stay
last" comment, and CLAUDE.md's matching invariant line are deleted
(doc follow-up, not performed here). Eleven test files that spawn
`EnemyTable.ICE` directly migrate to spawning the current subnet's row;
`test_behaviour.gd`/`test_minibosses.gd`'s "ICE is last" assertions are
replaced by "the subnet->id table resolves a real row for every subnet."

## Shared invariants

- **Flip-immune**: `corruption_threshold = 1e18` on all three rows, as
  `ice` is today. Spires have no corruption channel at all (not `Population`
  members).
- **Only `_is_boss_kill` clears the subnet** — same `_on_death` branch shape
  as today's ICE check.
- **No collapse before the kill** — preserve existing collapse/Blocks
  phase guards; do not imply that all simulation clocks stop during bosses.
- **No libm** in any new simulation code (`+ - * /`, comparisons,
  `distance_to`/`length_squared` only); `test_determinism_rules.gd`'s
  allowlist guards new functions by default.
- **Spawn/relocate**: `worm_exe_segment` reuses the existing
  `_worm_id`/`_worm_seg`/`_spawn_hp`/`_arriving`/`_ai_*` arrays unchanged.
  Spires are not `Population` members, so that discipline does not apply
  to them.
- **Execute-immunity unchanged**: `ice` is not execute-immune today; none
  of the three rows are added to `_execute_immune_type`.

## Sentinel Array (subnet 1)

**Core**: one `sentinel_array` entity, spawned like `ice` today (board
wipe, standard arrival), 550 base integrity, contact damage 22.0, table
speed 50.0. Shielded while `_sentinel_spires_left > 0`, via **two**
required guards:

1. Grid exclusion (`_no_grid`) — covers weapon hits, targeting, contact.
2. An explicit skip in `_step2b_zones` (run.gd:3566-3599), which applies
   hazard damage and corruption by walking `enemies.count` directly and
   never queries the grid — it already carries this exact shape of guard
   for arriving entities (`if _arriving[i] > 0.0: continue`, line 3574,
   precisely because an ungated boss on a hazard/corruption tile takes
  damage or flips despite being grid-excluded). During implementation,
  inspect every direct damage/corruption admission path as well: invulnerability
  is the contract, not an assumption that grid exclusion guards every future hit.

Recommend a stationary, non-attacking core while shielded; this is a fairness
default, not an additional approved attack. Captured spires stay captured.
The fourth capture removes the shield once, with an activation telegraph;
make grid membership and direct-damage admission agree at the chosen tick
boundary. In the proposed step order, exposure begins on the next world
tick, consistently on every peer. Travel/survival still require player action:
the encounter is not guaranteed to clear merely because it has no timer.

**Spires**: 4 fixed points, not `Population` members — no HP, no
`HitQueue`, no corruption channel, drawn with bespoke `_draw` code as
`Blocks`' point already is. Positions are a **generation-time, seed-
invariant** artifact: arena 0's centre and size are fixed constants (world
origin, `ARENA_SIZE`), so the 4 anchors are the same absolute world points
on every seed — no RNG, no runtime search, no runtime fallback. Placed at
fixed angles (recommend 45/135/225/315 degrees via `DetMath.unit` on
constant radians, never `.rotated()`) at a fixed radius (recommend 0.65 x
half the smaller arena dimension). A new generation step,
`_place_spires(arena 0 only)`, runs after `_place_zones`/`_place_spawners`
and clears a safe pad (recommend 3x3 cells) plus a player-width spoke
back toward the connected center region at each anchor. Clear collision and
zones coherently and rebuild affected render rectangles/zone indices; changing
only collision cells would leave invisible walls or a visually stale hazard.
After all generation steps, validate full-player clearance and connectivity
from the entry pad to all anchors. Assertions are development backstops only;
exported builds must explicitly reject a failed layout, never silently ship an
unreachable capture point. `terrain.spire_points` is generation-derived and
classified in `NOT_IN_MANIFEST`. Arena 0 is never vote-targeted, so these
anchors do not need per-variant duplication.

**Capture tick**: run state `_spire_progress` (float x4), `_spire_captured`
(byte x4), `_sentinel_spires_left` (int). New step `_step2f_boss`, called
after `_step2e_blocks` and before `_step2b_zones`, gated on
`director.boss_spawned` and Sentinel being the active boss. Per spire:
each uncaptured spire fills while **any** LIVE slot is within
`SENTINEL_CAPTURE_RADIUS` (recommend 90.0), drains at
`SENTINEL_DRAIN_RATE` (1.5) otherwise, and clamps progress into
[0, `SENTINEL_CAPTURE_TIME`] (7.0s). Reaching the threshold captures it
permanently and decrements the counter exactly once. Several occupants do
not accelerate one spire; co-op can instead capture separate spires concurrently.

**Conservative recommendation:** spires do not shoot. Defense fire was not
part of the approved capture mechanic; adding it is a separate design choice,
not a hidden helper refactor or enabled-by-default toggle.

**Fairness:** capturing does not require damage output. Capture time is
independent of build DPS, but travel and surviving other threats still matter.

## Worm.exe (subnet 2)

**Head and body are not the same HP — load-bearing, not cosmetic.** One
row, `worm_exe_segment`, shared by the head (`_worm_seg[i]==0`) and every
body segment, spawned with different HP by position: head at
`WORM_HEAD_INTEGRITY_BASE` (550.0, matching the other bosses — killing it
is a real fight on its own), body at `WORM_SEGMENT_INTEGRITY_BASE` (80.0).
Both scaled by `_hp_mult()`. Without this split, focusing only the head —
already the sole kill condition via the existing head-death cascade
(`_step9_recycle`, run.gd:3831-3845: any segment sharing a dead head's
`_worm_id` is marked DEAD the same tick, cited here because it needed zero
new code to be correct) — would end the fight at 80 integrity, contradicting
"sustained damage across many segments." The row's own `EnemyType.integrity`
carries the body value (used for `_hit_weight`'s bucket, which 80.0 already
clears into heavy); the head's spawn call passes its own explicit HP, the
same shape `ice`'s spawn call already uses.

Segments are real `Population` entities (own HP, own `HitQueue`
participation) via the existing `_spawn_worm`-style spawn; `_worm_trail`/
`_worm_cursor`/`_worm_sample` supply **position only** for non-head
segments and carry no HP or aliveness — conflating "lengthen the trail"
with "add HP" is the mistake this spec heads off. Boss spawn: 8 starting
segments (indices 0-7), one worm id; only the head gets the arrival
flash/sfx (every segment is still `_arriving`-excluded during the charge).

**Regeneration.** Trigger is damage **landed**, not a kill, and this is
honestly a low DPS floor, not a DPS-free mechanic: the existing per-pass
hit-flash loop (already reading `queue.hit_target[k]` for every landed hit)
sets `_worm_boss_hit_this_interval = true` only when the boss's head or body
takes positive adjudicated damage. Do not count
mere queued, blocked, zero-damage or corruption-only hits. Every
`WORM_REGEN_INTERVAL` (recommend 12.0s), if no such damage landed and budget
remains, spend one event from `WORM_REGEN_BUDGET` (4): regrow a body if
the **total live segment count, including head**, is below
`WORM_MAX_SEGMENTS_BOSS` (recommend 10); otherwise heal the head by
`WORM_HEAD_REGEN_FRAC` (0.15) of scaled max, clamped. Reset the damage flag
each interval. A full-health head at the cap may consume an ineffective event;
never promise positive healing when it is already full. At zero budget,
regeneration stops permanently.

*New segment index, precisely*: the highest `_worm_seg` alive for this id,
**plus one — never the current alive count**, which under-reports the
instant an earlier segment has died and would collide with a survivor.
Bound: start max index 7; each body-regrow raises the max by exactly 1
(head-heal raises it by 0); budget caps regrows at 4; highest reachable
index is 7+4=11, whose trail lookup (`steps_back=88`) stays inside the
96-slot buffer regardless of death order, since the bound depends only on
starting max index and total regrow-spend, never on live count.

*Conservative total-health bound*: eight starting segments means **one
550-HP head plus seven 80-HP bodies**, totaling 1110 before scaling.
Four events add at most `4 × max(80, 0.15 × 550) = 330`, so cumulative
health supplied is at most 1440 before the same integrity multiplier.
This is an upper bound, not required damage: killing the head ends the fight
without requiring every body to die. All magnitudes are playtest defaults;
the user approved the growing/regenerating boss, not an exact fight duration.

**Fairness, stated honestly**: the floor is "land one hit every 12s" — a
real, low, but nonzero requirement. `hp_mult` scales enemy integrity only,
never player damage, so there is no analytic proof this floor is
comfortable for a low-DPS build; the finite regen budget bounds only the
worst case, not the experience. Flagged below.

## Root Cause (subnet 3)

`root_cause` **is** the renamed `ice` row (same glyph/colour/550 base).
One entity, one HP pool, three phases.

| Phase | HP fraction | Primitive |
|---|---|---|
| 0 | > 66% | AMBUSH (`_ambush`, unchanged 2.0/0.6/4.0s cycle) |
| 1 | 33-66% | RANGED barrage |
| 2 | <= 33% | CHARGE pattern, with a Root-Cause-specific locked windup direction |

**Phase is computed, never stepped**: derived fresh from current HP
fraction each check, so a single hit crossing both thresholds in one tick
lands directly in phase 2 — exactly one transition recognized/telegraphed,
never a phantom pass through phase 1. `_behave`'s dispatch is bypassed for
`root_cause` (a preamble calls `_ambush`/`_ranged`/`_charge` directly by
computed phase); the static row keeps `behaviour = AMBUSHER` purely so
`_spawn_enemy_state`'s existing branch primes phase 0's timer for free.

**On every transition, unconditionally**: reset `_ai_phase`/`_ai_timer` to
the new phase's initial state, **and** clear `_submerged = 0` and
`enemies.vel = ZERO`. Both are required: a transition mid-dive must not
leave the entity permanently grid-excluded (`_submerged` gates `_no_grid`
like `_arriving` does), and phase 2 must not inherit stray velocity from
phase 1's positioning.

**Root Cause's windup must predict its actual dash.** The current `_charge`
stamps `_ai_aim` at `CH_WINDUP -> CH_DASH`, too late for a locked-direction
warning. For Root Cause only, capture the direction on entering windup and
retain that same direction through launch. Reuse the existing charge machinery
with an explicit caller-selected aim-lock policy if suitable; ordinary
chargers retain their existing late targeting. Do not overwrite the early
direction at launch or change every ordinary CHARGER as an incidental boss
improvement. Draw the warning from the direction the boss will actually use.
The ensemble's CHARGER note still occurs at dash launch, not warning start.

**Barrage (phase 1)**: 0.35s WEDGE pre-volley telegraph, then a 3-shot fan
through `_fire_hostile` offset by `DetMath.rotate` at +/-18 degrees from
the lead direction, on a 2.0s cooldown (slowed from `RANGED_COOLDOWN`'s
1.6s for the 3x shot count).

**Fairness**: no new invulnerability window beyond the existing, already-
bounded ambush submerge cycle every AMBUSHER shares.

## Multiplayer and recovery

Sentinel: every LIVE slot tested independently per spire, so co-op
parallelizes; shield state is shared, derived identically on every peer.
Worm.exe: the damage-landed flag comes from the same adjudicated
`HitQueue` drain every peer runs identically. Root Cause: phase is a pure
HP-fraction function of shared state. Every field below is
`SNAPSHOT`-flagged, so a resyncing peer reconstructs spire progress, worm
regen state, and Root Cause's phase exactly mid-fight.

## Manifest / snapshot / hash

Plain run scalars or fixed-size-4 arrays (spires are never sliced to a
population count), `SH` flag. Every entry has a real check:

| Field | Shape | Validation |
|---|---|---|
| `_sentinel_spires_left` | int | 0..4, **and** must equal `4 - count(_spire_captured==1)` — cross-field: a mismatch could leave the core wrongly shielded or exposed after restore |
| `_spire_progress` | float[4] | finite, within [0.0, `SENTINEL_CAPTURE_TIME`] |
| `_spire_captured` | byte[4] | each byte 0 or 1 |
| `_worm_regens_left` | int | 0..`WORM_REGEN_BUDGET` |
| `_worm_regen_timer` | float | finite, within [0.0, `WORM_REGEN_INTERVAL`] |
| `_worm_boss_hit_this_interval` | bool | boolean, not an arbitrary numeric truthy value |
| `_root_cause_phase` | int | 0..2; inactive sentinel/reset values explicitly handled if used |

Cross-field validation reads the complete incoming snapshot before any writes,
not a mixture of incoming and live fields in `_valid_value`. Captured flags,
progress and remaining count must agree; worm IDs/segment indices must be
unique and within the trail-safe bound, with exactly one live head while the
encounter is active. Inactive and completed boss states need explicit valid
reset shapes. A Root Cause phase may lag HP until its next ordered phase step;
do not reject a valid between-step snapshot merely because it crosses a threshold.

`_boss_row` (resolved lookup) and `terrain.spire_points` (generation
artifact) are `NOT_IN_MANIFEST`. **`_worm_boss_regen_flash` (the HUD
"REGENERATES" cue) is presentation-only, decayed by frame delta under
`_present` exactly like `_hit_flash`, and is `NOT_IN_MANIFEST` too** —
it affects no gameplay outcome, so it is not added to the hash even though
it is tick-set (from the deterministic tick) at the moment a regen fires;
only its decay is wall-clock. `type_index`'s existing range check already
covers the three new rows as `enemy_types.size()` grows.

## UI, telegraphs, audio

HUD Centre banner generalizes from mini-boss-only to name the active boss
and its objective state (spire count / segment count + regen cue / phase
number) — a real gap today, since ICE gets no banner at all. Boss
integrity ring generalizes to any boss-row entity; Worm.exe keeps one ring
per live segment plus the HUD's aggregate count. New sfx ids (per-boss
charge/arrive/kill, a capture chime, a regrow cue, a phase-transition cue)
are literal `feel.emit(...)` strings at every site — no lookup table, so
`test_audio_events`' grep coverage needs no indirect-table entry, provided
they stay literal.

## What this does not do

The teleporter/level-vote mechanism and arena-density geometry variants
(owned by `TerrainDesign`, already spec'd); the spawner-points feature
itself; retuning `SpawnDirector.hp_mult`/`HP_ROWS`; a fourth boss
archetype; CLAUDE.md's invariant-list edit (follow-up).

## Testing scenarios

Identity lookup resolves a real row for every subnet 1..3. Only
`_is_boss_kill` clears the subnet (capturing all 4 spires / killing a
non-head segment / crossing a phase threshold each leave `FIGHTING`).
Sentinel: core is unqueryable AND takes no zone damage/corruption while
shielded (both guards tested independently); solo can always eventually
capture all 4; 4 LIVE slots on 4 spires finish in one `CAPTURE_TIME`;
spire anchors have player-sized open, safe, connected routes in exported layouts.
Worm.exe: killing only the head (all bodies alive) ends the fight at 550
scaled integrity, not 80 (the regression this spec exists to prevent);
killing a body segment first does not end it; landing one hit per
interval prevents regen; a no-hit period spends at most the finite regen
budget, and subsequent sustained damage can finish the fight; no live segment
index exceeds 11; both regrow and at-cap healing paths are reachable and checked.
Root Cause: a hit crossing both thresholds fires exactly one transition;
`_submerged`/velocity clear on every transition; Root Cause's dash follows
its full-windup warning while ordinary charger timing is unchanged. Manifest:
the cross-field spire check
rejects a corrupted payload before any write; snapshots mid-capture,
mid-regen-timer, mid-phase restore exactly; one solo/co-op/recovery suite
per boss via `multiplayer_harness.gd`.

## Recommended defaults to validate

1. Inert capture spires and a stationary shielded core keep capture independent
   of build damage. Defense fire is not included without a separate decision.
2. Worm.exe's interval, HP, cap and budget need low-DPS solo/co-op measurement;
   the finite health bound does not establish a comfortable fight.
3. Phase colors are cosmetic defaults. Pair every essential cue with shape/
   motion/text; the actual dash direction and target remain simulation state.

These documents claim no runtime, playtest, multiplayer or visual verification.
