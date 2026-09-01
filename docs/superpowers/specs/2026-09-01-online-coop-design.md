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
runs and across arm64/x86_64 at the 600-enemy cap — the precondition for
lockstep, measured rather than hoped.

## Decisions

| Question | Answer |
|---|---|
| Architecture | Deterministic lockstep; inputs and checksums on the wire, nothing else in steady state |
| Players | Up to 4. Solo is a 1-player session with zero input delay — one code path |
| Connection | Direct IP + port, one host, ENet. No relay, no matchmaking |
| Input delay | 3 ticks (50 ms) default, tunable per session |
| XP | Shared pool; everyone levels at once; each picks from their own cards |
| Level-up | Sim halts; choices are inputs; resumes when every living slot has chosen or 1800 ticks pass |
| Death | Spectate. Run ends when no slot is alive or the campaign is won |
| Desync | Detected by checksum every 60 ticks; recovered by a host state snapshot |
| Disconnect | Slot is parked (untargetable, inert) and can reconnect via the same snapshot; dead after 120 s |
| Host drop | Lowest live slot inherits the host role |
| Player separation | Unlimited. The grid window fits the players; measured +1.75 ms p95 at arena size |
| Cheating | Not defended against. Remote data is sanitised for robustness only |

## Why lockstep, and what it costs

Lockstep sends ~8 bytes per player per tick. A host-authoritative model would
send the host's view of ~600 enemies, ~400 projectiles and ~200 hostiles to
every client — ~32 KB/s each after interest management — and need a snapshot
encoder, interest management and client prediction to do it. That is roughly
twice the work, and it exists to tolerate non-determinism this simulation does
not have.

The cost is the classic one: nobody may execute tick N until every peer's input
for N has arrived. A late packet stalls everyone. The input delay hides normal
jitter; redundancy in every packet (below) hides a lost one; and when a peer
is genuinely gone the parking rule (below) lets the run continue.

What is proven: same-binary determinism, and same-OS cross-architecture
determinism at full load, 3600 ticks each, every hashed field. What is not:
Windows or Linux libm. `sin`, `cos` and `atan2` are the risk. **One probe run
on a Windows build is a precondition for promising cross-platform play.** Until
then the honest claim is "same platform."

## The simulation: slots, not a player

`MAX_PLAYERS := 4`. A session has `players` live slots, `0..players-1`. A slot is
an index into parallel arrays, in the manner of everything else in `run.gd`.

Per slot — `PackedVector2Array` / `PackedFloat32Array` / `PackedByteArray`
sized `MAX_PLAYERS`:

```
player_pos, player_prev_pos, player_render_pos, player_vel
player_health, player_iframe, player_shield
slot_state          # LIVE, DEAD, ABSENT
loadout[slot]       # Loadout, compiled from that player's own meta
sheet[slot]         # PlayerStats sheet
unlocked[slot]      # module ids available to that player's cards
```

Shared — one of each, as today: `level`, `xp`, `xp_needed`, `phase`, `won`,
`terrain`, `director`, all five populations, the hit queue, the grid.

`LOCAL_SLOT` stops being a constant and becomes the slot this client was
assigned in the lobby. Everything that renders "the player" reads it.

### Every "distance from the player" rule, resolved

The single-player build has about fifteen places that mean "the player". Each
gets one explicit rule; none is left to mean slot 0.

| Site | Rule |
|---|---|
| `_step4_steer` target, `_approach_dir` | Nearest LIVE slot. A per-enemy min over ≤4 positions |
| `STEER_RANGE_SQ`, `VIEW_RANGE` gates | Distance to nearest LIVE slot |
| `_step9c_reapproach` | Straggler if beyond `RECYCLE_RADIUS` of **every** LIVE slot; teleports to the ring around the nearest |
| `director.step` spawn origin | Cycles through LIVE slots, one per spawn call |
| Boss flow field source | The boss's target, i.e. the nearest LIVE slot to the boss |
| `_step6_detect` contact, pickup | Per LIVE slot; a shard is picked up by whichever slot reaches it |
| `_step2b_zones` on the player | Per LIVE slot |
| Exploit origin in `_emit_vector` | The owning slot's position |
| `_depth_sort` `lo` | The local slot (presentation only; not in the manifest) |
| Camera | The local slot's render position, or the spectate target |

Dead and absent slots are skipped by every rule above. An absent slot is
additionally inert: no firing, no pickup, no contact damage taken.

### Exploit ownership

`hit_queue.source_exploit` is an `int`. It becomes a global exploit id,
`slot * Loadout.MAX_EXPLOITS + index`. The queue does not change; kills and
flips attribute to `killer_exploit / MAX_EXPLOITS` for banking; `_proj_owner`
holds the same global id. `_step5_fire` loops slots, then that slot's resolved
exploits, with the existing `FIRE_BUDGET` applied per exploit as today.

### The grid window

Measured on the full autopiloted perf gate at 600 enemies, normalised p95:

| Window | Cells | p95 |
|---|---|---|
| 3200 (solo today) | 10,000 | 5.48 ms |
| 4800 | 22,500 | 6.64 ms |
| 7200 (whole arena, square) | 50,625 | 7.24 ms |

Covering the entire arena costs +1.75 ms against an 11 ms budget, so players
are not leashed. The window is the axis-aligned bounding box of LIVE slots
grown by `STEER_RANGE` on every side, clamped to the arena and never smaller
than today's 3200 square. `Grid` allocates `_cell_start` / `_cursor` for the
arena-sized cell count once and uses a `_cols × _rows` subset per tick — no
runtime allocation, the same rebuild code. Solo play pays exactly what it pays
now; the tick pays for spread only when players spread.

The headroom that remains must also carry four slots' exploits and the extra
spawns. The perf gate gains a 4-slot run and stays the arbiter.

### Scaling

Wave count multiplies by `players`, capped at `MAX_ENEMIES` by the pool as
today. Enemy integrity multiplies by `1 + HP_PER_EXTRA_PLAYER * (players - 1)`.
`xp_needed` multiplies by `players`, so a shared pool fed by four collectors
levels at solo pace. The three constants live in `data/` beside the reasoning
that set them, per the balance rule; this spec fixes the shape, not the value.

### Shared level-up

One XP pool. When it crosses `xp_needed` on tick T, the tick offers cards to
every LIVE slot — from that slot's own loadout, unlocks and card RNG — and sets
`paused`. A card choice is an input, not a call (see the input record below).
Ticks keep executing while paused: the guard returns early as it does today,
but each tick still consumes one input record per slot, which is how the
choices arrive. On the tick where the last LIVE slot's choice is applied,
`paused` clears. An ABSENT slot's choice auto-resolves at once to the first
card so its build keeps pace. Any slot that has not chosen by T + 1800 has its
first card applied — counted in ticks, so every machine does it on the same
tick. Fusion offers follow the same path.

`_card_rng` is per slot, seeded from the session seed and the slot, so two
players do not draw the same cards from one stream.

### Death and spectating

`slot_state = DEAD` stops movement, firing, targeting, pickup and spawn-origin
duty. The dead client's camera follows the nearest LIVE slot; a button cycles.
The run ends when no slot is LIVE or the campaign is won. Kills, flips and
salvage bank as below regardless.

### Meta: what each player brings

Each client owns its own `save.json`. In HELLO it sends its `player_sheet()`,
`multipliers()` and `unlocked_modules()`; every client runs all of them through
`PlayerStats.sheet()` / `PlayerStats.mults()` and compiles all `players`
loadouts locally. Given identical inputs the compiler is deterministic, so
every machine holds identical `ResolvedExploit`s for every slot without them
ever being sent.

Remote meta passes through the same `_sanitise` and `_num` path as
`save.json`. This is not anti-cheat — nothing here is designed against a
friend — it is because a corrupt packet has exactly the shape of a hostile
file, and that path already exists and is tested.

Banking: salvage banks in full to every participating slot's own save. Kills
and flips bank to the slot whose exploit did them. Each client writes only its
own save.

## Determinism: the rules the sim now lives under

Every one has been true so far; each is now load-bearing and gets a test.

- **Nothing in the tick reads the wall clock, the frame delta or the display.**
  `Time.get_ticks_msec` and `Engine.get_physics_interpolation_fraction` appear
  only above the guard or in `_draw`. A structural test greps for them.
- **Every RNG in the tick is seeded from the session seed.** `_rng`,
  `_card_rng[slot]`, `_block_rng`, `director.rng`, `Terrain`. The hardcoded
  `20260830` / `20260831` become derivations of `session.seed`. `feel`, `sfx`
  and `music` RNGs are presentation and stay unseeded.
- **The device is read in one place.** Already enforced by `test_input`.
- **Iteration is over packed arrays or insertion-ordered containers.** No
  `Dictionary.keys()` order is relied on in the tick without sorting.
- **The tick is the same function in solo and in a session.** No
  `if networked:` branch in `_physics_process`.

## The state manifest

`run.serialize_state() -> PackedByteArray` and `run.restore_state(bytes)`.
The manifest is every array and scalar the tick reads:

```
five Populations: pos, prev_pos, vel, force, integrity, corruption,
                  type_index, radius, generation, state, count, _next_generation
run.gd per-enemy:  _worm_id, _worm_seg, _spawn_hp, _slow_left, _slow_factor,
                   _knock, _split_gen, _rewarded, _hit_flash, _arriving,
                   _submerged, _ai_phase, _ai_timer, _ai_aim
run.gd per-projectile / botnet / hostile parallel arrays, all of them
worm trails and cursors, next worm id
player arrays (all of the per-slot list above), inputs
level, xp, xp_needed, paused, phase, won, kills, flips, salvage
terrain.current, collapse_left, gate state, temp zones
director: elapsed, spawned, dropped, miniboss_fired, boss_spawned, rng.state
_rng.state, _card_rng[*].state, _block_rng.state
hit_queue counters if any survive a tick boundary
tick number
```

Packed arrays serialise with `var_to_bytes` in one call each. At cap the
manifest is roughly 150–200 KB. It is built for two occasions — desync
recovery and reconnect — and never in steady state.

`run._state_hash() -> int` is computed **over the same manifest**. That
coupling is the point: it turns "is the manifest complete?" into a suite. Serialise
one run, restore into a fresh one, tick both for 600 ticks, and any field the
manifest missed diverges the hashes. The determinism probe's hash moves into the
sim as this method; the probe and the suites call it rather than keeping their
own list.

Not in the manifest, by design: `_alpha`, `player_render_pos`, camera, `feel`,
`_fx_*`, `_falling`, `_order` (rebuilt wholesale each tick), the multimeshes.

## The lockstep core

`scripts/net/lockstep.gd`, `class_name Lockstep extends RefCounted`. Pure: no
scene tree, no ENet, no globals. The fourth pure layer beside `build/`, `feel`
and `synth`, and tested directly like them.

### The input record

```
class_name InputRecord      # a small RefCounted, or packed as 4 floats + 2 ints
var move: Vector2           # WORLD direction, normalised or zero
var card: int = -1          # index into the offered cards, or -1
var target: int = -1        # Loadout.best_target result, or -1
```

Wire form: 16 bytes. `move` quantised to two `int16` in `[-1, 1]` is fine and
deterministic (both ends dequantise identically); floats sent raw are also
fine. Choose the quantised form; it halves the packet.

### The ring

```
const RING := 128           # ticks of history; 2 s at 60 Hz
const DEFAULT_DELAY := 3

var players: int
var delay: int
var _records: Array         # [RING][MAX_PLAYERS] of InputRecord
var _have: PackedInt32Array # [RING] bitmask of slots present
var _live: int              # bitmask of slots that must submit (LIVE or DEAD, not ABSENT)

func submit(slot: int, tick: int, rec: InputRecord) -> void
func ready(tick: int) -> bool          # (_have[tick % RING] & _live) == _live
func take(tick: int) -> Array          # records for every slot; ABSENT slots get an empty record
func mark_absent(slot: int) -> void    # clears the slot's bit in _live
func mark_present(slot: int) -> void
```

Local input for tick `T` is sampled by `_poll_local_input` at tick `T - delay`
and submitted for `T`. `run` executes `T` only when `ready(T)`. Solo is
`players = 1, delay = 0`: `ready` is always true the moment the local record
is submitted, and the tick runs unchanged.

### Checksums

Every `CHECKSUM_EVERY := 60` ticks each peer computes `_state_hash()` and sends
`(tick, hash)`. `Lockstep.checksum(slot, tick, hash)` stores it;
`Lockstep.desync_at() -> int` returns the first tick at which any two stored
hashes for the same tick differ, or −1. Detection lags divergence by at most
60 ticks, which is fine: recovery is a snapshot, not a rewind.

### Stalls

When `ready(next)` is false the sim does not advance. `_present` runs anyway;
`prev == pos` so interpolation holds still; after `STALL_NOTICE := 20` stalled
ticks the HUD names the slots whose records are missing.

## Recovery and reconnect

Both use the manifest. Both are the only times state crosses the wire.

### Desync recovery

On `desync_at() >= 0`, every peer stalls. The host serialises at its current
tick `H` and sends `SNAPSHOT(H, bytes)` reliably to every peer whose hash
disagreed with the host's. Those peers `restore_state`, discard ring entries
older than `H`, and resume; the others were waiting on `ready(H+1)` and resume
when the restored peers' records arrive. The host is authoritative for this one
message and at no other time. Expect one to three seconds of "resyncing…".

If the same session desyncs three times in 60 seconds, end it with the tick
numbers — that is a determinism bug to fix, not a network to tolerate.

### Disconnect and parking

The transport reports a peer gone after `TIMEOUT := 5 s` without packets. The
host announces `ABSENT(slot, tick)` reliably, with `tick` a few ticks ahead so
every machine applies it on the same tick. At that tick: `slot_state = ABSENT`,
`Lockstep.mark_absent(slot)`. The slot is inert per the rules above and the
run continues without it. Level-ups auto-resolve for it.

After `ABSENT_TO_DEAD := 120 s` (7200 ticks, counted), the host announces the
slot DEAD; on return that player spectates.

### Reconnect

The returning client sends `HELLO(session_id, slot)`. The host replies with
`SNAPSHOT(H, bytes)` — the same message as recovery — and announces
`PRESENT(slot, tick)`. The client restores, marks itself present, and its
records begin flowing at `tick`. Everyone applies `PRESENT` on the same tick;
the slot is LIVE again with the health it had when it parked.

### Host migration

If the peer that is host times out, the lowest-numbered slot that is not
ABSENT becomes host. Every client learned every other client's address in
HELLO, so the new host needs no discovery, and under lockstep the host owns
nothing the others lack — it takes over lobby duties, snapshot duty and
`ABSENT`/`PRESENT` announcements. The former host reconnects to the new one
like any other returning peer. This is the last item in the plan and can be
cut without touching anything above.

## Transport

`scripts/net/transport.gd`, a `Node` — the one class that touches ENet.
`ENetMultiplayerPeer`, one host, up to three clients, direct IP and port. Raw
`put_packet` / `get_packet` on `PackedByteArray`. **No RPC, no
`MultiplayerSynchronizer`, no `MultiplayerSpawner`.** Nothing in this game is a
node worth replicating, and the high-level API assumes it is.

### Messages

| Message | Channel | Contents |
|---|---|---|
| `HELLO` | reliable | protocol version, session id, slot request, sanitised meta |
| `WELCOME` | reliable | assigned slot, session seed, players, delay, every peer's meta and address |
| `START` | reliable | the tick at which the run begins |
| `INPUT` | unreliable, sequenced | slot, latest tick, the last 3 ticks' records |
| `CHECKSUM` | unreliable | slot, tick, hash |
| `ABSENT` / `PRESENT` / `DEAD` | reliable | slot, effective tick |
| `SNAPSHOT` | reliable | tick, manifest bytes |
| `LEAVE` | reliable | slot |

Every `INPUT` carries the last three ticks' records, so a single lost packet
costs nothing: the next packet fills the hole. A `CHECKSUM` lost is a
checkpoint skipped, not a desync.

### Direction of dependency

`run` **polls** the transport above the guard — `transport.drain_into(lockstep)`
— exactly as the audio layer is drained and the music layer polls
`run.threat()`. The simulation never holds a node reference and never calls
out; a headless suite drives `Lockstep` directly with no transport at all.

## Presentation

- **Camera** follows `player_render_pos[LOCAL_SLOT]`; a DEAD or spectating
  client follows the nearest LIVE slot and cycles with `confirm`.
- **Every LIVE player is drawn** as today's disc; teammates in a distinct hue
  with a short name tag drawn in `_draw`. ABSENT slots are drawn dimmed and
  static; DEAD slots are not drawn.
- **HUD** (`ui.gd`): the local slot's integrity, level and loadout as today. A
  compact strip for the other slots: name, integrity bar, LIVE/DEAD/ABSENT.
- **Card screen** shows the local slot's cards, plus "waiting for N…" with names
  until every LIVE slot has chosen.
- **Stall and resync notices** in the HUD, text only, in the existing style.
- **Lobby** in `meta_screen`: Host (port) / Join (ip:port), a player list with
  slot and name, Start for the host. Name and last-used address persist in
  `prefs`, through `PREF_RANGES`-style clamping.

## Testing

Every suite runs through `tools/run_tests.sh`, headless, no transport.

| Suite | Asserts |
|---|---|
| `test_lockstep` | pure: `ready` false until every live slot submits; `take` returns empty records for ABSENT; ring wrap at 128; delay applied; `desync_at` finds the first disagreeing tick and −1 otherwise |
| `test_manifest` | serialise → restore into a fresh run → hashes equal → **600 further ticks stay equal**. A missed field fails this |
| `test_multiplayer_sim` | two, then four, `run` instances in one process, one `Lockstep`, same seed, a kite per slot; `_state_hash()` identical every tick for 3600 ticks |
| `test_recovery` | in `test_multiplayer_sim`'s harness: corrupt one instance's state, run the recovery path, assert hashes agree afterward |
| `test_reconnect` | withhold one slot's submissions → it parks on the announced tick, the run continues; resubmit via snapshot → PRESENT → agreement |
| `test_plurality` | nearest-LIVE targeting; DEAD and ABSENT never targeted, never a spawn origin, take no contact; window fits the players and never shrinks below 3200; exploit kills bank to the owning slot; `xp_needed` scales with players |
| `test_determinism_rules` | structural: no `Time.get_`/`get_physics_interpolation_fraction` below the guard; every tick RNG seeded from the session seed; no `Input.` outside `_poll_local_input` (already in `test_input`) |
| `test_transport_loopback` | two ENet peers on localhost in one process; INPUT redundancy recovers a deliberately skipped send; ABSENT fires after the timeout |
| `perf_milestone0` | gains a 4-slot autopiloted run at cap; same budget |

`tools/determinism_probe.gd` stays as a manual cross-architecture tool and
calls `_state_hash()` instead of carrying its own list. Its `PROBE_ELAPSED` /
`PROBE_IMMORTAL` knobs stay.

## Accepted costs

- 50 ms of input delay at the default setting, on top of interpolation's 16 ms.
- The run stalls when a peer's packet is genuinely late, and freezes for one to
  three seconds during a recovery or a reconnect.
- Everyone waits while cards are picked; 30 s worst case.
- Up to four times the exploit fire cost in the tick; the perf gate judges it.
- Two representations of the sim state — the live arrays and the manifest —
  that must be kept in step. `test_manifest` is what makes that affordable.
- Same-platform only until a Windows probe run says otherwise.

## Out of scope

Matchmaking, relay servers and NAT traversal (friends use a VPN or a port
forward). Rollback or prediction of any kind. Cheat resistance. Text or voice
chat. Couch co-op — wanted later, as two controllers or keyboard + controller,
and it will reuse these slots with a per-device `_poll_local_input`. Windows
determinism verification, which is a precondition to be met, not a feature to
be built.
