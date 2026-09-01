# Online co-op

Up to four players in one campaign over a direct connection, by deterministic
lockstep: every machine runs the whole simulation and only inputs cross the
wire. A player who diverges is resynchronised from the host's state; a player
who drops is parked and can come back.

Three things landed first and this design leans on all of them. Render
interpolation (`5cac14e`) draws every entity between its last two simulated
positions, which is what a lockstep client renders through unchanged. Input
injection (`b75e84b`) made the tick read `inputs[slot]` and poll the device in
exactly one place. And a determinism probe showed the tick bit-identical across
runs and across arm64/x86_64 at the 600-enemy cap — with caveats recorded under
*What is measured*.

Revision 3 plus verification passes, after three six-seat review rounds. Changes
are listed at the end.

## Decisions

| Question | Answer |
|---|---|
| Architecture | Deterministic lockstep; inputs and checksums on the wire, nothing else in steady state |
| Players | Up to 4. Solo is a 1-player session with zero input delay — one code path |
| Connection | Direct IP + port, one host, ENet star; the host relays explicitly. No relay server, no matchmaking |
| Input transport | **Reliable, ordered**, on an ENet peer created with two user channels. A lost packet costs one round trip of stall and nothing else. No redundancy, no resend protocol |
| Input delay | 4 ticks (67 ms) default in a session, 3 on LAN, tunable |
| XP | Shared pool; everyone levels at once; each picks from their own cards. `xp_needed` is **not** scaled |
| Level-up, fusion | The world halts; choices are inputs keyed to their offer; rounds repeat until `pending_levels` is zero; per-round timeout `CHOICE_TIMEOUT_TICKS` (1800 in a session, none in solo) |
| Hitstop | A simulation construct, `hitstop_ticks`, not a time-scale write |
| Death | Spectate; open offers resolve at death. Simulation ignores a DEAD slot's record, while its PRESENT controller sends neutral records for transport liveness. Only the host's reliable `END` finishes the run |
| Desync | Checksum every 60 ticks; host announces a `RESYNC` tick; snapshot there. The host is the authority; if the host diverged, the others follow it (accepted) |
| Disconnect | Slot is parked at the host's first-missing tick and the peer is dropped. On re-`HELLO`, positive-health slots return beside a LIVE player or at arena centre; zero-health slots remain DEAD |
| Host drop | Ends the run at the tick number. No host migration |
| Player separation | **Leashed to 4000 units of party spread**, the measured point where the grid window costs 7.24 ms. Unlimited costs 9.61 ms solo and leaves nothing for four |
| Cheating | Not defended against. Remote data is sanitised for robustness; the snapshot is primitives-only because a peer's bytes must never construct an object |

## Why lockstep, and what it costs

Lockstep sends one 20-byte record per player per tick — with framing about
5 KB/s per client and ~17 KB/s upstream for the host, which relays and
**flushes one datagram per peer per tick**; unbatched, the relay would cost as
much as the alternative it replaces. A
host-authoritative model would send the host's view of ~600 enemies, ~400
projectiles and ~200 hostiles to every client — ~32 KB/s each after interest
management — and need a snapshot encoder, interest management and client
prediction. That is roughly twice the work, and it exists to tolerate
non-determinism this simulation does not have.

The cost is the classic one: nobody may execute tick N until every LIVE peer's
input for N has arrived. `INPUT` is reliable, so a lost packet is retransmitted
by ENet and the stall it causes is one round trip; the input delay absorbs
ordinary jitter. Review of an unreliable-plus-redundancy design found that
ENet's throttle *drops unreliable packets by design* under RTT variance, so
three consecutive losses — routine on a congested link — lost a record forever
and froze the session with no timer able to notice. Reliability is what lockstep
actually needs, and it deletes the redundancy and the tail-record machinery that
tried to substitute for it.

The topology is a star. `ENetMultiplayerPeer.create_client` connects to the
host only; a record from B reaches C through the host — two hops for two of the
three pairs — and the host relays raw packets **explicitly**, since Godot's
automatic relay is for the high-level API and is not assumed. The default delay
is 4 ticks in a session because 50 ms is exactly two hops with no jitter
margin; 3 on a LAN.

### Why not Netfox

Netfox is active, MIT-licensed and supports Godot 4.x; the rejection is
architectural, not qualitative. Its core implements server-authoritative
rollback: late input rewinds and resimulates the game, and authoritative state
is sent back to clients. `RollbackSynchronizer` records configured Node
properties every tick, and its diff is property-granular. In this simulation,
one moved enemy changes an entire packed position array; most of the five
populations change every tick. Making that efficient would require either
turning thousands of packed entities back into Nodes or writing an
element-level state codec — more machinery and bandwidth than this lockstep
design.

Rollback also multiplies the measured 5.48–7.24 ms tick cost by the number of
ticks replayed in one frame. Netfox's unreliable redundant input is coherent
with that model because missing input is predicted and repaired later; it is
not coherent with a lockstep tick that must never execute without a required
record. Using only its clock or command wrapper would retain the dependency and
autoload surface while replacing little of the custom work below.

Therefore ROOTKIT owns the reliable input ring, checksums, snapshots and
reconnect protocol. `netfox.noray` remains a separate future option if NAT
traversal or relay connectivity enters scope; neither is part of direct-IP
co-op.

### What is measured, and what is not

The probe hashed player position, enemy positions and integrity, projectile
positions, counts and three RNG states, once per tick:

| Run | Ticks | Enemies | arm64 vs arm64 | arm64 vs x86_64 |
|---|---|---|---|---|
| light | 3600 | ≤81 | identical | identical |
| heavy, kite died | 188 | ~360 | — | identical |
| heavy, immortal (`PROBE_ELAPSED=240`) | 3600 | peak 600, mean 520 | — | identical |

A run at `PROBE_ELAPSED=400` was past `SUBNET_SECONDS`, spawned one enemy, and
is not counted.

Caveats, all real:

- **The probe fed a constant `DT`.** The shipped tick receives
  `_physics_process`'s parameter, which `Engine.time_scale` shrinks to 1/1200 s
  during a hitstop, released on the wall clock — live today on every ICE kill.
  Prerequisite 1 removes the path; the result stands for the tick after it.
- **The hash was narrow.** Health, hostiles, botnet, shards, `_ai_aim` (the
  `atan2` consumer), `force`, `corruption`, terrain collapse state, `phase`,
  `level`, `xp`, `salvage`, and the whole block objective with its `_block_rng`
  were not hashed. Once
  `_state_hash()` exists over the manifest, the cross-architecture pair is
  re-gathered with it. Until then the claim is "positions agree".
- **Windows and Linux libm are unmeasured.** The surface: `sin`, `cos`,
  `atan2`, `Vector2.angle()`, `rotated()`, `angle_to()`, and `pow` in
  `SpawnDirector.hp_mult` and `Compiler`. **One probe run on a Windows build is
  a precondition for promising cross-platform play.** Until then: same platform.

## Prerequisite commits

Each is small and invisible until it is expensive. They ship separately, first.

1. **`TICK_DT`, and hitstop as a simulation construct.** Every step below the
   guard takes `TICK_DT := 1.0 / 60.0`, never the parameter. That alone would
   delete hitstop — it worked *because* the scaled delta slowed the world — so
   hitstop becomes `hitstop_ticks: int` in the manifest: set by the sim events
   that trigger it (a death, a miniboss kill, the ICE kill), decremented above
   the guard, and while nonzero the world does not step, records are still
   consumed, and `_present` still runs. Deterministic for free, and it removes
   the last `Engine.time_scale` write and the wall-clock release from `run.gd`,
   along with `_present`'s now-dead division by the scale.
2. **RNG streams.** `_card_rng` today draws card shuffles, fork-bomb child
   offsets (`_step9b_splits`), the miniboss spawn angle, and the two
   block-payout rolls. Spawn placement moves to `_rng`, shared. `_card_rng`
   becomes per slot and draws that slot's cards and its payout rolls.
3. **`EVENT_BUDGET × MAX_PLAYERS`** — 28,800 — and `HitQueue` counts dropped
   appends. Both `test_multiplayer_sim` and the 4-slot perf run assert the
   counter is zero. The existing comment already disclaims the bound as
   not-tight; the counter, kept permanently, is the mitigation.
4. **Seeds.** `SpawnDirector._init(20260829)`, `_rng`, `_card_rng`,
   `_block_rng` and `Terrain` derive from one `session.seed`. Solo draws one.
5. **No `fusion_offered.get_connections()` in the tick.** A fusion offer is an
   input like a card.
6. **Guarded sentinel division.** `killer_exploit` −1 and `flipper_exploit` −2
   truncate to slot 0 under integer division. Unowned kills bank to nobody.

## The simulation: slots, not a player

`MAX_PLAYERS := 4`. A slot is an index into parallel arrays sized
`MAX_PLAYERS`, in the manner of everything else in `run.gd`.

```
player_pos, player_prev_pos, player_render_pos, player_vel
player_health, player_iframe, player_shield
slot_state                           # LIVE, DEAD, ABSENT
_zone_slow_player, _low_armed
kills, flips, _banked                # per slot; banking is per slot
_fire_acc, _fire_cd, _ward_left      # sized MAX_PLAYERS * MAX_EXPLOITS, indexed by gid
_card_rng
loadout_modules, loadout_ranks, loadout_fused   # primitives; see the manifest
_sheet, pickup_radius, _unlocked     # derived from HELLO counters; constant for the session
```

`_sheet`, `pickup_radius` and `_unlocked` are per player by construction —
every player brings a different save — and every reader of them takes a slot:
`_eff_integrity`, `_eff_armor`, `_eff_defense`, `_eff_clock_speed`, the shard
magnet and pickup query, and the three `_unlocked` walks that build card
offers. They are derived from the counters exchanged in `HELLO`, never carried
in the snapshot, and rebuilt on restore.

Shared: `level`, `xp`, `xp_needed`, `pending_levels`, `salvage`, `phase`,
`won`, `hitstop_ticks`, `terrain`, `director`, `blocks`, the five populations,
the hit queue, the grid.

`alive` becomes `slot_state[slot] == LIVE`. `_die()` is per slot: it sets DEAD,
resolves that slot's open offer (first card), fires the death presentation and
banks. A separate check — no slot LIVE, or the campaign won — is a **terminal
candidate**, not permission to emit `run_ended`.

In a session, every PRESENT controller emits one record for every sampled tick.
It samples gameplay input while its local slot is LIVE and emits neutral
movement/no-choice while that slot is DEAD or its world is in an unconfirmed
terminal hold. Simulation still requires and applies LIVE slots only; peers that
see the slot DEAD ignore the record. This separation keeps a divergent death
from stalling a host that still sees the slot LIVE, without allowing a dead
player's offer choice to land.
The host relays records by the PRESENT roster, not by its local LIVE mask.

A locally terminal peer holds the world below the guard but keeps consuming
lockstep ticks above it.

The peer sends reliable `END_CANDIDATE(tick, outcome)` to the host. On that
message or its own terminal candidate, the host broadcasts reliable
`END_CHECK(C)`, with `C >= host_tick + delay + 3`. Every **PRESENT peer** —
including DEAD spectators — reaches `C` and sends reliable
`(C, _state_hash(), outcome-or-NONE)`. This end roster is not lockstep's LIVE
`_required` mask; ABSENT peers alone are removed. Correct peers may continue
after `C` under the same back-pressure as resync.

If the host is terminal and every PRESENT hash and outcome agrees, it
broadcasts reliable `END(C, outcome)`; only that message emits `run_ended`. On
any mismatch, the host applies the ordinary authority rule at a **new reachable
future `RESYNC(R)` boundary**, because it may already have executed past `C`
and retains no historical snapshot for it. A nonterminal host restores a
false-ending client at `R` and the client resumes. A terminal host restores
clients to its terminal state at `R`, then schedules another `END_CHECK`; it
never sends `END` until a check agrees. Parking removes a missing peer from the
end roster, and the existing three-desync limit still ends a session that
cannot converge.

With no remote PRESENT peer, the host confirms its own candidate immediately;
solo therefore ends on the candidate tick without a synthetic delay.

`LOCAL_SLOT` becomes the slot this client was assigned in the lobby.

### The plurality census

`grep -n 'player_pos' scripts/run/run.gd` returns 45 read sites. Each maps to
exactly one rule; the implementation plan carries the site list.

| Rule | Sites |
|---|---|
| **Nearest LIVE slot** — per-enemy min over ≤4 | steer target and `_approach_dir`; `STEER_RANGE_SQ` and `VIEW_RANGE` gates; `terrain.avoid` direction (must agree with the steer target); ranged line of sight; shard magnet; zone application |
| **Target slot's position and velocity** | hostile shot lead and expiry; charger dash aim |
| **Every LIVE slot, independently** | contact damage and iframes; shard pickup (first to reach); zone slow; void death; `_low_armed` |
| **Owning slot** | exploit origin; orbit re-anchor; mine placement; chain and cascade origins; ward fold (MAX within the slot's own exploits); trigger dispatch and ON_KILL (only the owning slot's exploits) |
| **Sum over LIVE slots** | botnet cap — the botnet is one shared pool |
| **Cycling LIVE slot** | `director.step` origin; ICE and miniboss rings; block placement |
| **Beyond `RECYCLE_RADIUS` of every LIVE slot** | `_step9c_reapproach`, to the ring around the nearest |
| **All LIVE slots past the gate line** | `_step2c_gate`. See *The gate* |
| **Nearest LIVE slot to the block** holds it | `blocks.tick` progress. Payout: fusion or card to the holder; heal to the holder; salvage to the shared pool; both rolls from the holder's `_card_rng` |
| **One flow field per LIVE slot** | a boss reads its nearest LIVE slot's field |
| **Local slot** — presentation only | `_depth_sort` `lo`; camera; `_draw` |

`resolved` is never iterated whole. `_slot_exploits(slot)` yields one slot's
gids; every loop that walked `resolved` today walks that instead.

DEAD and ABSENT slots are skipped by every rule. ABSENT is additionally inert:
no firing, no pickup, no contact taken, cooldowns frozen.

### The leash, and the grid window

Measured on the full autopiloted perf gate at 600 enemies, normalised p95:

| Window | Cells | p95 | headroom under 11 ms |
|---|---|---|---|
| 3200 (solo today) | 10,000 | 5.48 ms | 5.5 ms |
| 4800 | 22,500 | 6.64 ms | 4.4 ms |
| 7200 | 50,625 | 7.24 ms | 3.8 ms |
| 9344 | 85,264 | 9.61 ms | 1.4 ms |

The last row is the window a fully spread party would need, and it is
superlinear against the trend (8.74 ms extrapolated). That headroom is the solo
workload's; four slots' exploits, four flow fields and the hash walk have to fit
in it too. They will not fit in 1.4 ms. So the window is capped at the 7200
point and the party is leashed to it:

- **`MAX_WINDOW := 7200`.** The grid allocates 50,625 cells once — 405 KB for
  `_cell_start` and `_cursor` — and `set_window(rect)` snaps the live rect
  outward to whole cells so cell boundaries never slide under entities.
  `_cols`, `_rows` and `_ncells` track the **live** rect, and `rebuild` loops
  over `_ncells`; a party standing together rebuilds ~10,000 cells, not 50,625.
  That is the difference between the 5.48 ms row and the 7.24 ms row in the
  common case, and `test_plurality` asserts the live cell count at both
  extremes. Players are not grid entities; the `+ 1` in the grid's capacity is
  vestigial and stays so.
- The live window is the bounding box of LIVE slots grown by **1600** on every
  side (today's margin; a maxed-reach packet travels 896), clamped to the
  terrain grid, never smaller than 3200 square.
- **`LEASH := MAX_WINDOW - 3200 = 4000`.** The bounding box of LIVE slots may
  not exceed 4000 on either axis. `_step2_integrate` clamps a slot's move that
  would exceed it, toward the party centroid — a soft wall a little over three
  screens from the farthest teammate. Solo is unaffected.

This is the design the first draft had and the second draft removed; it is
back because the measurement that was asked for came in against it. The leash
also settles two review findings for free: a party can never span two arenas,
so the "one in the old arena, three in the new" worst case cannot occur, and a
reconnecting slot is always placed within reach.

### The gate

The subnet advances on the tick every LIVE slot is past the gate line — past
`g.end`, into the next arena. The corridor is never voided by the arena's
collapse, so the first draft's "wait in the corridor" was a deadlock: a slot
idling there never dies and never crosses. Now the corridor's
cells are **appended to `_collapse_order`** after the arena's, ordered from the
arena end toward `g.end`, so once the arena collapse completes the corridor
voids too over `CORRIDOR_COLLAPSE_TICKS`. One order, one index: `voided` stays
written in one place and the derived restore below stays correct. A LIVE slot that has not crossed by then dies,
becomes DEAD, and no longer gates. With the leash, a slot cannot fall more than
4000 behind in the first place. `_advance_subnet` heals every LIVE slot.

### Flow fields

One `FlowField` per slot with the existing hysteresis; a boss reads the field
of the LIVE slot nearest it. `MAX_PLAYERS × 2401` ints; at most `players`
floods on a tick, only while a boss is present. The 4-slot perf run measures it.

### Exploit ownership

`gid = slot * Loadout.MAX_EXPLOITS + index`. One decoder,
`_decode_exploit(gid) -> [slot, index]`; one lookup, `_resolved(gid)`; one
enumerator, `_slot_exploits(slot)`. Every `resolved[...]` index and every
`for r in resolved` loop today goes through one of the three. `_proj_owner`,
`source_exploit`, `killer_exploit` and `flipper_exploit` carry gids; negative
is unowned.

### Scaling

Wave rate multiplies by `players` (inert at the pool cap, and said so). Enemy
integrity multiplies by `1 + HP_PER_EXTRA_PLAYER * (players - 1)`.
`xp_needed` is **not** scaled — kills are supply-bound at the cap and a ×4
`xp_needed` made a group level four times slower than solo. A group levels
faster; accepted. `MAX_SHARDS` is unchanged and a group can saturate it under
load; lost XP at saturation is accepted and stated. Constants live in `data/`.

### Shared level-up and fusion

One XP pool. Crossing `xp_needed` on tick T opens an **offer round**: every
LIVE slot is offered three cards from its own loadout and unlocks, shuffled by
its `_card_rng`, with `deadline = T + CHOICE_TIMEOUT_TICKS`; `paused` is set.
The offer state is in the manifest per slot: the current `offer_seq`, the open
offer's kind (level card, seeded card, fusion), its contents (three module ids,
or the recipe id) and deadline, and the queued offers behind it with their
sequence numbers. That is what restores stale-choice rejection and same-tick
queued rounds identically on a resynced peer.

Every offer a slot receives carries a per-slot, strictly increasing
`offer_seq`; a slot has at most one open offer, and a second (a block payout
landing during a level round) queues behind it. A choice is an input record
whose `offer` field is that sequence number. A record whose `offer` does not
match the slot's open offer is dropped, so a pick in flight when the timeout
fires, or sampled against a round that has since closed, lands nowhere — and
two rounds opened on the same tick are still told apart. While `paused`, ticks execute: the world does not step,
records are consumed, choices are applied. When every LIVE slot's offer is
resolved, if `pending_levels > 0` the next round opens on that same tick;
otherwise `paused` clears. Any slot unresolved at its deadline gets its first
card. The timeout is a session parameter, absent in solo.

A slot that dies or parks with an open offer has it resolved at once to the
first card. A DEAD slot's controlling peer sends only neutral records, and the
ring ignores them wherever that slot is DEAD, so a dead player's choice can
never arrive on one machine and not another.

Fusion and seeded-card offers from the block objective follow the same path,
to the holding slot, with the same `offer` key.

**This amends a documented invariant.** CLAUDE.md's rule becomes: *below the
guard the world steps; above it run presentation, input intake and input
application.* CLAUDE.md changes in the same commit, along with its stale suite
count and its pure-layer list.

### Death, spectating, local pause

A DEAD slot stops moving, firing, being targeted, picking up and serving as an
origin; its client's camera follows the nearest LIVE slot and `confirm` cycles.
`user_paused` gates the tick in solo as today; in a session it is an overlay
and the local record carries zero movement. `test_input`'s case becomes "in
solo".

### Meta: what each player brings

`HELLO` carries the **sanitised counters** — `buffs`, `kills`, `flips` — not
the folded sheet or the derived unlock list: `_sanitise` validates those
fields (among others), and `unlocked_modules()` derives from the local save and
cannot describe a remote peer. Every client folds and derives locally, so every
machine compiles identical loadouts. A protocol-version mismatch refuses the
join before any of this.

Banking is per slot: `kills[slot]`, `flips[slot]`, `_banked[slot]` are in the
manifest, so a recovery or reconnect cannot double-bank and cannot mis-credit.
Salvage banks in full to every participant; kills and flips to the slot whose
exploit did them; unowned to nobody. Each client writes only its own save. A
peer that banked on a divergent branch and is then resynced may bank a small
delta twice into its own save; cosmetic, accepted.

## Determinism: the rules the sim now lives under

Each gets a structural test in `test_determinism_rules`.

- **The tick consumes `TICK_DT`** and reads no clock: no `Time.get_*`,
  `Engine.time_scale`, or `Engine.get_physics_interpolation_fraction` in any
  step or anything a step calls. After prerequisite 1 there is no such call in
  the tick's call graph, so a plain grep over the step functions and their
  callees is the test.
- **Every RNG in the tick is seeded from `session.seed`.**
- **The device is read in one place.**
- **No branch on connection state** below the guard or in input application.
- **Iteration is over packed arrays or insertion-ordered containers.**
  Dictionaries in the manifest serialise as parallel arrays.

## The state manifest

**One declaration, explicit consumers.** `STATE_FIELDS` entries are
`(object, property, flags)`, where `flags` contains `SNAPSHOT`, `HASH` or both.
`serialize_state()` and `restore_state()` visit `SNAPSHOT`; `_state_hash()`
visits `HASH`. Most executed simulation state carries both. Transport arrival
state can be snapshot-only: it is required to resume but must not make two
otherwise identical simulations disagree. `NOT_IN_MANIFEST` names every
excluded field with its reason. `test_manifest` enumerates every `var` in
`run.gd`, `spawn_director.gd`, `terrain.gd`, `blocks.gd`, `flow_field.gd`,
`population.gd`, `grid.gd`, `hit_queue.gd` and `lockstep.gd` and requires each
to appear in exactly one list.

**Slice shared fields identically.** Populations and per-entity arrays carry
both flags. They are sliced to `count` in the snapshot, and `_state_hash()`
walks `0..count` — never the full capacity. A restored peer's tails hold its
own pre-restore garbage, so hashing full arrays would flag a phantom desync on
every checksum after successful recovery.

In the manifest:

```
five Populations, 0..count: pos, prev_pos, vel, force, integrity, corruption,
    type_index, radius, generation, state; count, _next_generation
per-enemy arrays, 0..count: _worm_id, _worm_seg, _spawn_hp, _slow_left,
    _slow_factor, _knock, _split_gen, _rewarded, _hit_flash, _arriving,
    _submerged, _ai_phase, _ai_timer, _ai_aim, _no_grid
per-projectile / botnet / hostile parallel arrays, 0..count
worm trails and cursors as parallel arrays keyed by id; next worm id
player arrays (the per-slot list above), inputs
loadout_modules, loadout_ranks, loadout_fused   # per slot × MAX_EXPLOITS × SLOT_COUNT, ints
open offers: per slot, offer_seq, kind, contents, deadline, and the queued offers
_fire_acc, _fire_cd, _ward_left, _steer_phase, _trigger_fires
level, xp, xp_needed, pending_levels, paused, hitstop_ticks, phase, won,
    subnet, salvage, _spawned_before, collapse_left, _route, _route_cell
_pending_fusions
terrain: current, gate state, temp zones, _collapse_idx
blocks: alive, pos, progress, elapsed, next_at
flow fields: _dist, _ox, _oy, _centre, _ready per slot
director: elapsed, spawned, dropped, miniboss_fired, boss_spawned, _milli, rng.state
_rng.state, _card_rng[*].state, _block_rng.state
the lockstep ring for (tick, tick + delay] only, as parallel packed arrays   # SNAPSHOT only
tick number
```

Deliberately not in it, with the rule that reconstructs each:

- `terrain.origin`, `size`, `w`, `h`, `solid`, `zone`, `rects`, `arenas`,
  `gates` — immutable for the session; rebuilt from `session.seed` by
  `Terrain.plan` / `generate`.
- `terrain._blocks` — **derived from gate state**, not immutable: `open_gate`
  and `enter_next` both rebuild it. `restore_state` calls `_rebuild_blocks()`
  after restoring gate state, or the restored player collides with a gate
  everyone else walks through.
- `terrain.dist_from_gate`, `max_dist`, `_collapse_order`, `voided` —
  **derived**, and only meaningful while `phase == CLEARED`.
  `build_distance_field()` is a pure function of `solid`, `gates` and
  `current` when called in that phase; `voided` is written in one place, in
  `_collapse_order` order (arena cells then corridor cells). `restore_state`
  rebuilds the field when CLEARED and sets
  `voided[_collapse_order[0.._collapse_idx]]` directly. On subnet advance,
  `Terrain.enter_next()` calls one `_clear_collapse_state()` that empties
  `dist_from_gate`, `_collapse_order`, `voided` and `just_voided`, and resets
  `max_dist` and `_collapse_idx`. Restore calls the same method whenever the
  restored phase is not CLEARED. Rendering reads `voided` during FIGHTING, so
  leaving the prior arena's bits populated would produce a presentation
  desync even though the next tick does not use them.
- `grid.gd` and `hit_queue.gd`, every field — rebuilt before their first read
  each tick (`set_window` + `rebuild`; `begin_tick`).
- `_hit_weight` — a table indexed by enemy type, constant for the session. This removes ~950 KB
  from the snapshot; the first draft's size estimate missed that
  `dist_from_gate` is int32 over the whole grid.
- `terrain.just_voided`, `_pending_splits` — filled and drained within a tick.
- `Population.capacity`, `SpawnDirector.waves` — constants.
- `_alpha`, `player_render_pos`, camera, `feel`, `_fx_*`, `_falling`, `_order`,
  the multimeshes — presentation.

**Loadouts are primitives.** A loadout is module ids, ranks and fused flags per
exploit slot — ints. They are carried directly and `_recompile()` runs on
restore. The second draft rebuilt them from a choice log; the log's indices
could not be replayed without the offers they indexed, and a crashed peer had
no meta to rebuild from. Carrying the arrays deletes both problems.

**Primitives only.** Packed arrays, ints, floats, bools. Decoding uses
`bytes_to_var`, never `bytes_to_var_with_objects` — the latter on a peer's
bytes constructs arbitrary classes and is the standard Godot remote-code path.
`restore_state` clamps every `count` to its pool cap and rejects a payload
whose array lengths disagree with its counts.

Size: ~280 KB realistic worst case (L layout, cap, mid-collapse, ~40 worms)
and ~480 KB absolute ceiling — shards at 79.5 KB and worm trails at 768 bytes
per live worm are the terms that dominate — against a 1 MB cap; ~100 KB typical.
`SNAPSHOT_MAX := 1 MB` stays as the bound on what a peer can make a client
allocate; the snapshot shrank to fit it rather than the cap growing.
`_state_hash()` every 60 ticks walks the live prefixes; the 4-slot perf run
includes it.

## The lockstep core

`scripts/net/lockstep.gd`, `class_name Lockstep extends RefCounted`. Pure.

### Tick convention

`executed` is the first tick not yet consumed. Consuming record `T` advances it
to `T + 1`; a checksum labelled `T` and a snapshot labelled `T` describe state
**after** record `T` was applied. Thus a snapshot at `T` carries the next
records `(T, T + delay]`, and restoring it resumes at `T + 1`. This convention
is shared by the ring, transport validation, recovery and reconnect; none may
use "tick" to mean a frame counter with different before/after semantics.

### The input record

```
move:   Vector2   # WORLD direction as from_iso produces it; components reach ±1.3635; two raw float32
card:   int       # -1 none, -2 decline, 0..2 the offered card
target: int       # index into Loadout.legal_targets(m), fixed iteration order
offer:  int       # the per-slot offer_seq this choice answers; -1 when card is -1
```

20 bytes. Every field is checked at application, not at the transport: `card`,
`target` and `offer` out of range are treated as no choice; `move` with a
non-finite component is treated as zero and each component is clamped to
±1.3635. `clampf` is not a finiteness check — CLAUDE.md records that for
`save.json`, and the same discipline applies to the eight bytes that arrive
sixty times a second.

### The ring

```
const RING := 128
const DEFAULT_DELAY := 4

var _records   # per slot: PackedVector2Array moves, PackedInt32Array cards, targets, offers — [RING]
var _tick_tag: PackedInt32Array    # [RING] absolute tick each cell holds
var _have: PackedInt32Array        # [RING] bitmask of slots present
var _required: int                 # LIVE slots only

func submit(slot, tick, rec), ready(tick), take(tick)
func mark_absent(slot), mark_present(slot), mark_dead(slot)
func prime(delay)                  # empty records for ticks 0..delay-1 at START
```

- Cells are tagged with their absolute tick; a submit for a newer tick clears
  the cell. `ready(T)` requires the tag to be `T`.
- `tick < executed` or `tick >= executed + RING` is dropped. The upper bound is
  exclusive: `executed + RING` aliases the current cell and must not clear it.
- A record once submitted is immutable; re-sampling an existing tick is a no-op.
- Ticks `0..delay-1` are primed at `START`.
- `_required` is LIVE slots. DEAD slots' records are ignored; ABSENT slots
  submit nothing and take empty records.
- The ring's snapshot form is its parallel packed arrays — primitives.

Solo is `players = 1, delay = 0`.

### Checksums and stalls

Every 60 ticks each peer sends `(tick, _state_hash())`; `desync_at()` is the
first disagreeing tick or −1. When `ready(next)` is false the sim does not
advance; `_present` runs; after `STALL_NOTICE := 20` ticks the HUD names the
missing slots.

## Recovery, parking, reconnect

One shape: **the host names a reachable future snapshot boundary; peers that
receive a snapshot restore to the state after that tick, while correct peers
continue until lockstep back-pressure catches them.**

### The resync tick

`RESYNC(tick)`, reliable, `tick ≥ host_tick + delay + 3`. Every peer executes
to `tick`. **The host serialises only once its ring holds every LIVE slot's
records for `(tick, tick + delay]`**, and the snapshot carries the ring for
exactly that window. Three rules keep reliably delivered records from being
destroyed by the recovery itself:

- **Correct peers do not halt.** They continue past `tick`; lockstep's own
  back-pressure bounds them at `tick + delay` until the restoring peer's records
  resume. There is no `RESUME` message because none is needed.
- **The ring is merged, not overwritten.** `restore_state` writes only the
  snapshot's `(tick, tick + delay]` cells; a cell whose tag is newer — a record
  that arrived on channel 0 while the snapshot was in flight on channel 1 — is
  kept. A record delivered once is never lost.
- **Incoming `INPUT` is buffered against the announced tick.** Between
  `RESYNC` (or `HELLO`) and restore, the transport validates ticks against the
  announced resync tick, not the stale `executed`, and none of it counts toward
  `BAD_PACKETS`.

### Desync recovery

On `desync_at() >= 0` the host announces `RESYNC`, snapshots there, and sends
`SNAPSHOT` to every peer whose hash disagreed with its own. The host is the
authority; if the host is the one that diverged, three correct peers are
resynced to its state. That is accepted for a game among friends — consistency
is what lockstep needs, not correctness — and it is stated here rather than
implied. Three desyncs in a session end it with the tick numbers.

### Parking

The transport reports a peer gone after `TIMEOUT := 3 s` without packets —
ENet's own default is longer, so `ENetPacketPeer.set_timeout` is applied to
every peer on connect. The
host announces `ABSENT(slot, tick)`, reliable, with `tick` the host's first tick
with no record from that slot. Because `INPUT` is reliable and relayed in order
by the host, every client holds exactly the records the host holds for that
slot — so at `tick` every machine has the same last record and applies empty
records after it. No tail is needed. **The host also disconnects the ENet
peer**, so a client whose link merely hiccupped cannot keep driving a slot
nobody applies.

An ABSENT slot is inert and stays ABSENT until it returns. Its open offer is
resolved at once.

### Reconnect

The client treats any disconnect, and `TIMEOUT` of silence from the host, as
"stop and `HELLO(session_id, slot)`". A reconnect is accepted only before host
`END`. The host replies with the immutable session descriptor the returning
client may have lost and announces `RESYNC(tick, cancel_no_live_end)` to
everyone. Whenever a positive-health return is accepted while the host has no
LIVE slots, it first sets a host-only
`pending_live_return = (slot, tick)` latch — even if no no-LIVE candidate or
barrier exists yet. While that latch exists, local no-LIVE evaluation is
suppressed and no-LIVE `END_CANDIDATE`s are rejected; campaign-win candidates
remain valid. `cancel_no_live_end` is true only when a no-LIVE barrier already
exists; that flagged reliable `RESYNC` clears the old check and collected
reports on every peer. Same-channel ordering makes this supersession precede
later ending control messages.

At the boundary the host snapshots, sends `SNAPSHOT`, and announces
`PRESENT(slot, tick)`. It adds the returning peer to its relay set in the same
frame it serialises, so no relayed record falls between the snapshot and the
first relay. `PRESENT` is applied **after `tick` is consumed**, on every
machine. If parked health is positive, the placement anchor is the nearest LIVE
slot, or `terrain.arena().get_center()` when none exists; the slot is placed at
`terrain.nearest_open(anchor)`, marked LIVE, and required from `tick + 1`.
Applying it clears `pending_live_return` and records the `PRESENT` tick.
No-LIVE candidates with `candidate_tick <= present_tick` are stale — equality
matters because `PRESENT(slot, T)` applies only after tick T is consumed. If
the reconnect aborts before the boundary, the host clears the latch and
reevaluates no-LIVE, which can schedule a new check. If parked health is zero,
the slot is restored as DEAD, remains a spectator, never enters the LIVE
required mask, and leaves an ending check active. `ABSENT` may overwrite the
sole `slot_state`; parked health is therefore the remembered life-state
discriminator.

The host primes neutral records for `(tick, tick + delay]` in either case and
relays them like any other; the returnee's own sampling begins at
`tick + delay + 1`. For a LIVE returnee, required-from-`tick + 1` and
primed-from-`tick + 1` line up exactly; without the priming,
`ready(tick + 1)` would stall on records that cannot exist yet. Health remains
as parked; reconnect does not heal or revive.

### Host drop

Ends the run at the tick number; progress is banked incrementally as today.

## Session handshake

The roster becomes immutable at `START`; a run in progress accepts reconnects
to its existing slots, never a new participant.

- The host occupies slot 0 from its local profile. A first remote `HELLO`
  carries protocol version, display name and the sanitised `buffs` / `kills` /
  `flips` counters. The host assigns the lowest remaining slot and broadcasts
  `WELCOME(session_id, assigned_slot, roster)` to refresh every lobby peer.
  Every roster is ordered by slot. A pre-`START` leave frees its slot and
  refreshes the roster.
- The host chooses the seed and session parameters. `START` carries the
  protocol version, session id, seed, delay, choice timeout and the complete
  slot-ordered roster. This is the immutable session descriptor. Every peer
  derives `_sheet`, `pickup_radius` and `_unlocked` from it before tick 0.
- Reliable ordering puts `START` before every `RELAY` on channel 0; no wall-clock
  countdown or start acknowledgement is required. Ticks `0..delay-1` are
  already primed, and lockstep stalls naturally if a peer starts late.
- A reconnecting `HELLO(session_id, slot)` does not replace that slot's name or
  counters. `WELCOME` returns the original descriptor. A mismatched protocol,
  session or slot is refused.
- `LEAVE` is the clean form of a timeout: the host parks the slot at its first
  missing tick and disconnects that peer. Solo builds the same descriptor
  locally with one slot, delay zero and no choice timeout.

## Transport

`scripts/net/transport.gd`, a `Node` — the one class that touches ENet.
`ENetMultiplayerPeer`, one host, up to three clients, created with
`create_server(port, 3, 2)` and `create_client(address, port, 2)` — **two user
channels on both ends**, because a `transfer_channel` the peer was not created
with is not a channel. Raw `put_packet` / `get_packet`. **No RPC, no `MultiplayerSynchronizer`, no `MultiplayerSpawner`.**
The host relays explicitly, as one bundled message: each tick it sends every
other client a single `RELAY(tick, records[])` carrying that tick's record from
every slot it has, and any `CHECKSUM`s received since the last flush. One
datagram per peer per tick is a property of that message, not of forwarding
each incoming `INPUT` as it arrives.

| Godot `transfer_channel` | Messages | Mode |
|---|---|---|
| 0 | `HELLO`, `WELCOME`, `START`, `INPUT` (client → host), `RELAY` (host → clients), `RESYNC`, `ABSENT`, `PRESENT`, `LEAVE`, `END_CANDIDATE`, `END_CHECK`, `END`, and every ending-check `CHECKSUM` | reliable |
| 0 | periodic `CHECKSUM` | unreliable |
| 1 | `SNAPSHOT` | reliable, its own channel so it never queues in front of an input |

(Godot maps channel 0's reliable and unreliable traffic to two ENet channels
and a user channel 1 to a third; the transport is written against the Godot
numbering.)

Every message is validated before anything reads it: length against its
declared size, protocol version, enums in range, `slot` in `0..players-1`, and
`SNAPSHOT` under `SNAPSHOT_MAX`. Tick bounds are message-specific: input
records use `[executed, executed + RING)`; checksum and candidate reports may
name the retained past `[executed - RING, executed + RING)`; host boundary
announcements name a reachable tick in the future ring; and `SNAPSHOT`,
`PRESENT` or `END` must match the active announced boundary even if local
execution has passed it. A failed check drops and counts; a peer past
`BAD_PACKETS := 20` is disconnected.

`run` **polls** the transport above the guard — `transport.drain_into(lockstep)`
— as the audio layer is drained. The simulation never holds a node reference.

## Presentation

Camera on `player_render_pos[LOCAL_SLOT]`, or the spectate target. Every LIVE
player drawn; teammates in a distinct hue with a name tag; ABSENT dimmed; DEAD
not drawn. HUD: local as today plus a strip for the others. Card screen: local
cards, "waiting for N…"; on restore mid-offer, `restore_state` re-emits the
offer so the screen appears on the restored peer too. Stall, resync and
leash notices in the existing text style. Lobby in `meta_screen`: Host / Join,
player list, Start; name and last address in `prefs` through a new string path
with a length cap and character whitelist.

## Testing

Every suite is added to `tools/run_tests.sh`'s `SUITES` array.

| Suite | Asserts |
|---|---|
| `test_lockstep` | `ready` gated by LIVE only; DEAD records ignored; ABSENT empty; submitting `executed + RING` is rejected without clearing the current cell; an old cell tag does not satisfy readiness after wrap; stale/far-future rejected; primed `ready(0)`; resubmission no-op; `desync_at` |
| `test_manifest` | structural: every `var` in nine files is in one list with valid consumer flags. Behavioural: two peers with identical executed state but different future-ring arrivals have equal `_state_hash()`; serialise → restore preserves the future ring. From a state with a **corridor** collapse in progress, an offer open, a block held and a mid-pool despawn — serialise → restore → hashes equal → 600 ticks equal; **`voided` bit-identical after derived restore**, corridor included; after advancing into FIGHTING, collapse-derived arrays are empty before and after restore; `_blocks` rebuilt so the restored player crosses the open gate; a level-up forced inside the window; **worst-case snapshot under `SNAPSHOT_MAX`** from an L layout at cap with a worm-heavy field |
| `test_multiplayer_sim` | two, then four, instances; hashes identical for 3600 ticks; one instance sets `user_paused` and hashes still agree; dropped-append counter zero |
| `test_recovery` | corrupt one instance; `RESYNC`; host waits for the ring window; **correct instances execute `delay` ticks past the resync tick before the snapshot is applied**, and the restored peer still reaches `tick + delay + 1`; its own records agree with what it broadcast; hashes agree after |
| `test_parking` | withhold a slot; parks at the host's first-missing tick; run continues; the withheld peer resuming traffic without `HELLO` is disconnected |
| `test_reconnect` | LIVE path: park, **advance a subnet**, return beside the party inside `terrain.arena()`; `WELCOME` re-sent; primed records let `ready(tick + 1)` pass; the returnee crosses the open gate; hashes agree. No-LIVE race: before any candidate exists, accepting the last positive-health ABSENT slot while DEAD spectators are PRESENT sets `pending_live_return`; across multiple ticks before `PRESENT`, local evaluation plus delayed no-LIVE candidates cannot create a check, while a campaign-win candidate still can. When an old no-LIVE barrier exists, flagged `RESYNC` clears it on every peer. `PRESENT(T)` returns the slot at `nearest_open(arena centre)`, clears the latch, rejects candidates at both `T - 1` and `T`, resumes play, and emits no `END`; aborting the reconnect clears the latch and allows a new no-LIVE check. DEAD path: DEAD → ABSENT → PRESENT with zero parked health stays DEAD, remains outside the LIVE required mask, leaves the ending check active, and still contributes to it |
| `test_plurality` | every census row; a slot idling in the corridor dies when the corridor voids; the leash clamps at 4000; the live window is ~10,000 cells with the party together and never exceeds `MAX_WINDOW` apart; ward fold is per slot; ON_KILL fires only the owner's exploits; botnet cap sums LIVE slots; unowned kills bank to nobody; per-slot kills |
| `test_offers` | a choice with a stale `offer_seq` is dropped, including across two rounds opened on one tick; `pending_levels = 2` opens two rounds on the same tick on every machine; a payout offer queues behind an open level offer; death resolves an open offer |
| `test_meta_derivation` | two different saves exchange `HELLO` counters; both machines derive byte-identical `_sheet`, `_unlocked` and `resolved` for both slots |
| `test_ending` | a false local death while a teammate remains LIVE sends neutral records, does not stall the host, and is repaired at the next check. A correct last death on a non-cadence tick reaches `END_CHECK`; every PRESENT peer, including a DEAD spectator, contributes; only host `END` emits `run_ended`. Divergent client terminal / host nonterminal: check mismatch, a fresh future `RESYNC` restores the client, no `END`, run resumes. Host terminal / client nonterminal: mismatch, a fresh future `RESYNC` restores the client to the host, a second check agrees, then `END` |
| `test_determinism_rules` | no clock or delta parameter in the tick's call graph; every tick RNG seeded from the session; no `get_connections()`; `Input.` in one place |
| `test_snapshot_hostile` | truncated buffer, oversized `count`, mismatched lengths, random bytes — rejected, never crash; a `move` of NaN or 1e30 is applied as zero |
| `test_transport_loopback` | peers created with two user channels; `INPUT` and `RELAY` use reliable ordered mode; withholding polling for three input intervals still delivers all three records in order; a full-size `SNAPSHOT` on channel 1 does not delay `INPUT`; `set_timeout` parks at 3 s; malformed packets dropped and counted; input, retained-report and announced-boundary tick windows are distinct; mismatched protocol/session and a new join after `START` are refused |
| `perf_milestone0` | a 4-slot run at cap, party at full leash, four flow fields, `_state_hash` every 60 ticks; same budget |

**Migration surface:** 26 suites, 10 tools and `ui.gd` read scalars that
become per-slot; a mechanical pass indexing slot 0, budgeted at four days. The
shot tools' pass is verified windowed.

## Accepted costs

- 67 ms of input delay by default in a session, on top of interpolation's 16 ms.
- One round trip of stall per lost `INPUT` packet; a few seconds at every
  `RESYNC`; up to 3 s before a dropped peer is parked.
- Everyone waits during offer rounds; 30 s worst case per round.
- Party spread is leashed to 4000 units.
- A group levels faster than solo; shards can saturate under load.
- A diverged host resyncs correct peers to its state.
- A held death screen while the host confirms the terminal state or resynchronises it.
- Up to four times the exploit fire cost, four flow fields and the hash walk
  in the tick; the perf gate judges all of it, with 3.8 ms of headroom measured.
- Two representations of the sim state, kept in step by the derived manifest.
- A host drop ends the run. Same platform only until a Windows probe run.

## Out of scope

Matchmaking, relay servers, NAT traversal. Host migration. Rollback or
prediction. Cheat resistance. Chat. Couch co-op — later, as two controllers or
keyboard + controller, on these slots with a per-device `_poll_local_input`.
Windows determinism verification — a precondition, not a feature.

## Changes in revision 3

- `INPUT` is reliable; redundancy and the `ABSENT` tail are gone; the host
  relays explicitly; default delay 4 in a session.
- Hitstop is a simulation construct, `hitstop_ticks`; `TICK_DT` no longer
  deletes it, and no clock read remains in the tick's call graph.
- Player separation is **leashed to 4000 units** on a measurement: 85k cells
  cost 9.61 ms solo, leaving 1.4 ms; the window is capped at the 7200 point.
- DEAD slots ignore gameplay input; their PRESENT controllers send neutral records so divergent death cannot stall lockstep. Offers resolve at death and parking.
- The host serialises only once the ring covers `(tick, tick + delay]`.
- The corridor voids after the arena; an idling slot dies rather than deadlocks.
- `PRESENT` places a positive-health returnee beside a LIVE slot, or at arena
  centre when none exists; zero-health returnees remain DEAD. The host
  disconnects a parked peer; a client re-`HELLO`s on any disconnect;
  `WELCOME` is re-sent.
- `run_ended` is host-confirmed through `END_CHECK`; terminal mismatches resync.
- Snapshot shrunk (~280 KB realistic, see the verification pass):
  `dist_from_gate`, `_collapse_order`, `voided` derived from `_collapse_idx`; hash and snapshot slice identically; loadouts carried as
  primitives and the choice log removed; ring in primitive form.
- Choices carry an `offer` key; offer rounds repeat until `pending_levels` is
  zero.
- Per-slot `kills`, `flips`, `_banked`; block payout branches assigned;
  `resolved` never iterated whole; two more `_card_rng` sites named.
- `HELLO` carries sanitised counters, folded locally.
- Manifest: `NOT_IN_MANIFEST` lists terrain geometry with its reconstruction
  rule, `just_voided`, `capacity`, `waves`; `_route`, `_route_cell`,
  `collapse_left` placed correctly.
- Bounds checks at input application; Godot channel numbering; explicit relay.
- Migration surface 26 suites and 10 tools; three new suites (`test_offers`,
  `test_snapshot_hostile`, `test_transport_loopback`); CLAUDE.md suite count.

## Verification passes, after round 3

- Recovery no longer destroys delivered records: the ring is merged, not
  overwritten; the snapshot carries only `(tick, tick + delay]`; incoming
  `INPUT` is buffered against the announced tick; correct peers continue under
  back-pressure; the returnee joins the relay set at serialisation and its
  first `delay` records are primed.
- Terminal confirmation is a host-scheduled reliable `END_CHECK`, not a checksum
  emitted only by a peer that happened to end locally. A mismatch takes the
  normal host-authoritative resync path; only reliable host `END` emits
  `run_ended`.
- Corridor cells are appended to `_collapse_order`, so the derived `voided`
  restore covers the corridor collapse; `_blocks` is derived from gate state and
  rebuilt on restore; `max_dist` and the distance field are derived only when
  CLEARED.
- `offer` is a per-slot sequence, one open offer per slot.
- `move` is validated at application; `_sheet`, `pickup_radius` and
  `_unlocked` are named as per-slot derived state; `grid.gd` and `hit_queue.gd`
  join the manifest test's file set; `_hit_weight` is a constant table.
- ENet peers are created with two user channels; `set_timeout` backs the 3 s;
  the host flushes one datagram per peer per tick (~17 KB/s upstream).
- Snapshot size restated: ~280 KB realistic, ~480 KB ceiling. `_present`'s
  dead time-scale division goes with prerequisite 1. The probe caveat lists the
  block objective as unmeasured. Two new suites: `test_meta_derivation`,
  `test_ending`.
- Second verification pass: `PRESENT` applies after `tick` is consumed;
  positive-health returnees are required from `tick + 1`, while zero-health
  returnees stay DEAD; the offer manifest carries `offer_seq`, kind, contents
  and the queue; ending barriers and `END` are reliable; the host's relay is
  one bundled `RELAY(tick, records[])` message per peer per tick.
- Final self-review defines the after-tick snapshot convention, makes the
  ring's upper bound exclusive so a future tag cannot overwrite the current
  cell, and specifies the immutable `START` descriptor. It requires subnet
  advance and non-CLEARED restore to clear collapse-derived terrain, because
  presentation reads `voided` during the next fight. The loopback test now
  tests reliable ordering and delayed delivery rather than pretending an
  application-level packet drop exercises ENet retransmission. Netfox core is
  rejected on its property-state rollback model; Noray remains out of scope
  unless connectivity requirements change. The recovery invariant now names a
  snapshot boundary rather than incorrectly saying correct peers halt there.
  Ending confirmation is likewise a host-scheduled barrier over every PRESENT
  peer: a divergent local terminal state schedules a fresh future resync
  boundary instead of waiting forever for a checksum the host never emitted.
  `STATE_FIELDS` now marks consumers explicitly: the future input ring is
  snapshot/restore state but not checksum state, so packet-arrival jitter cannot
  manufacture a simulation desync.
  Reconnect derives the overwritten life state from parked health, so a DEAD
  spectator cannot return as a zero-health LIVE slot or reopen the ending gate.
  A positive-health return with no LIVE anchor uses the current arena centre.
  Acceptance always creates a host latch, whether or not a no-LIVE candidate
  exists; a flagged reliable `RESYNC` additionally supersedes an existing
  barrier. The latch suppresses new or delayed no-LIVE candidates until
  `PRESENT` applies or the reconnect aborts, without suppressing campaign win.
  Candidate ticks through the `PRESENT` tick are stale. The DEAD path leaves
  the barrier active.
