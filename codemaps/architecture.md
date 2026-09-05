> Generated: 2026-09-05 | Token-lean format for LLM context

# ROOTKIT — Architecture

Godot 4.7 / GDScript bullet heaven. No image assets, font files or `Area2D`.
Entities are packed arrays over a spatial grid, not individual scene nodes.
Solo uses the same record-driven simulation as a multiplayer session.

| Setting | Source/value |
|---|---|
| Main scene | `scenes/main.tscn` → `scripts/meta/meta_screen.gd` |
| Run scene | `scenes/run.tscn` → `scripts/run/run.gd` (`Node2D`) |
| Engine/rendering | Forward Plus, HDR 2D, adaptive VSync (`project.godot`) |
| Viewport | 1280×720, `canvas_items` stretch |
| Simulation | 60 Hz; `SessionRules.TICK_DT = 1.0 / 60.0` |
| Party cap | `SessionRules.MAX_PLAYERS = 4`; per-slot state |
| Autoloads | `Updater` (`scripts/update/updater.gd`), `CRTOverlay` (`scripts/ui/crt_overlay.gd`) |

## Directory map

| Directory | Responsibility |
|---|---|
| `scripts/core/` | `Grid`, `FlowField`, deterministic `DetMath` |
| `scripts/build/` | Pure module/equipped-module/exploit/loadout/compiler/resolved-exploit/player-sheet layer |
| `scripts/combat/` | Packed `Population` and ordered `HitQueue` adjudication |
| `scripts/run/` | Run coordinator, spawning, terrain, held blocks, HUD, backdrop, props and pure `Feel` |
| `scripts/net/` | Lockstep, session state, codec, ENet transport and presentation diagnostics |
| `scripts/audio/` | Synthesized sound bank, SFX drain, threat-driven music |
| `scripts/meta/` | SaveGame, BuildInfo, hub/shop/lobby and settings |
| `scripts/update/` | Signed feed/archive verification and updater lifecycle |
| `scripts/ui/` | Shared terminal theme and global CRT overlay |
| `data/` | Code-defined module/enemy/recipe registries and SessionRules |
| `shaders/` | Procedural rendering |
| `tests/`, `tools/` | Headless suites/perf fixture, windowed probes, manual/release tooling |

Pure build, Feel, Synth, Lockstep, NetworkSession and Protocol code remains
reachable without a scene tree. Transport is the only ENet-touching class.
The simulation publishes events/state; audio and UI read them in the opposite
direction rather than being called from combat.

## Dependency graph

```
meta_screen → SaveGame / BuildInfo
     │ lobby → NetworkSession + Transport
     │ START: configure_session; reparent Transport, attach_transport
     v
run.gd → NetworkSession → Lockstep ← Transport (polled above guard)
  ├─ descriptor roster/counters → PlayerStats → Loadout → Compiler → ResolvedExploit
  ├─ SpawnDirector, Terrain, Blocks
  ├─ Population ×5: enemies, projectiles, shards, botnet, hostiles
  ├─ Grid: window over party bounds; FlowField ×4: boss approach
  ├─ HitQueue → drain → death/flip → recycle
  ├─ Feel.sfx → SFX drains; Music polls threat
  └─ UI / backdrop / props / MultiMeshes: presentation

Updater + CRTOverlay survive menu ↔ run scene changes.
```

`_derive_roster` reads each immutable roster row's `program` through `ProgramTable`:
Operator starts packet, Ghost spike, Bulwark broadcast, Virus chain + corrupt.
All start without an equipped trigger. Program sidegrades apply after counter-derived
`PlayerStats` multipliers/sheet stats; remote builds never read local preferences.
Card previews use a temporary Loadout and `compile_all`, not duplicate math.

## Tick — `run._physics_process`

| Order above the world guard | Responsibility |
|---|---|
| `_snapshot_render_state`, `_poll_local_input` | Snapshot previous transforms, sample/stage the next full input record |
| Transport poll, `_drain_inbox`, `_reconnect_step`, host relay flush | Incoming records and control; never consulted below the guard |
| `_present(_dt)` | FX/feel/vignette/falling chunks; delta capped at `MAX_PRESENT_DT` |
| Reconnect hold, `_roster_step`, `_sync_ring_roster`, recovery/ending | Tick-addressed membership and authority boundaries |
| Ring readiness/snapshot hold | Missing records stall consumption and world advancement |
| `take`, `_apply_records`, `_resolve_deadlines`, `_settle_offers` | Consume one record set, including card/fusion choices, even during modal holds |
| Hitstop or world guard | Decrement hitstop; otherwise step only if not paused, dead, won or ended |
| `_report_checksum` | After the consumed tick, including ticks whose world was held |

`user_paused` gates the world only in solo. Online it is a local overlay;
modal `paused` holds the world while input consumption continues.

| `_step_world` sequence | Work |
|---|---|
| `queue.begin_tick`; `_step1_spawn` if FIGHTING | Open the queue before any producers; spawn only during fighting |
| `_step2_integrate`; gate/collapse/blocks/network jobs/zones | Fixed-delta movement, life, interactions and hazards |
| `_step3_rebuild`; boss flow maintenance | Grid once per tick; at most one needed LIVE-slot flow rebuild, round-robin |
| `_step4_steer`; `_step5_fire`; detect/hostiles | AI, owning-slot weapon emissions, damage/pickups |
| `_steps78_drain` | Ordered hit adjudication and death/flip dispatch |
| recycle/reapproach/splits; `_depth_sort` | Packed-array maintenance and one draw-order sort |

All simulation aging uses `SessionRules.TICK_DT`, not the supplied frame delta.
`STATE_FIELDS` classifies snapshot/hash fields; `NOT_IN_MANIFEST` explains
excluded/reconstructed state. Restore validates primitives before any write.
Presentation-aged `_hit_flash` is excluded from HASH despite its per-enemy array.

`DetMath` supplies simulation transcendentals. It must remain GDScript;
engine builds must disable FP contraction. These build preconditions require
cross-architecture probing on engine changes, not a same-machine unit test.

## Campaign flow

```
hub → solo run or lobby START → run
  subnet 1/2: ICE dies → CLEARED → bank progress, open gate
    collapse begins (75 s arena phase) → all LIVE slots walk through corridor
    OfferKind.ROUTE → tick-addressed plurality vote → next-arena modifiers
    _advance_subnet → clear transient populations, heal LIVE slots,
                      reset director, Terrain.enter_next()
  subnet 3: ICE dies → bank progress → terminal WIN
```

All arenas/corridors are plotted before play on one terrain grid. Transition
changes the current arena; it does not regenerate terrain or teleport players.
Every arena reserves four validated entry positions. `_derive_roster` places each
roster slot at its own arena-0 point and primes interpolation. Unsafe generated
pads stop startup with an explicit error and return-to-menu action. Reconnects
use a bounded, safe search near a LIVE party, excluding occupied footprints;
same-tick returns apply in slot order. No-LIVE returns validate their reserved
point; an unsafe return is DEAD, never revived in rock or void.
Route votes are implemented; teleporters and bespoke bosses remain proposals.
Optional vault/relay/upload jobs run through `_step_network_ops` below the world
guard. Job state, route ballots/modifiers and the dedicated route RNG are hashed
and snapshotted. Gameplay protocol is 5; snapshot version is 2.

## Capacities and budgets

| Constant | Value | Constant | Value |
|---|---|---|---|
| `ARENA_SIZE` | 7104×4416 | `CELL` | 32 |
| `GRID_WINDOW` / `MAX_WINDOW` | 3200 / 7200 | `LEASH` | 4000 |
| `MAX_ENEMIES` | 600 | `MAX_PROJECTILES` | 400 |
| `MAX_SHARDS` | 1500 | `MAX_BOTNET` | 64 |
| `MAX_HOSTILES` | 200 | `FIRE_BUDGET` | 4 per exploit/tick |
| `EVENT_BUDGET` | `Loadout.MAX_EXPLOITS * FIRE_BUDGET * MAX_ENEMIES` | Queue capacity | `EVENT_BUDGET * MAX_PLAYERS` |
| `CASCADE_PASSES` | 8 | `HITSTOP_TICKS` | 4 |
| `DEPTH_BANDS` | 192 | `ISO_K` | 0.82 |
| `RECYCLE_RADIUS` / `RECYCLE_PER_TICK` | 1150 / 3 | `MAX_PRESENT_DT` | 0.1 |
| `Lockstep.RING` | 128 | `PROPS_Z` | 8 |

The live grid follows the party's bounding box rather than allocating work for
the whole campaign. Parallel per-entity arrays must reset on spawn and relocate
with swap-removal; `_order` is rebuilt wholesale by `_depth_sort`.

## Build, run, test

```bash
godot
# Selected suites plus the explicit perf gate.
tools/run_tests.sh test_build test_slots perf_milestone0
# All suites plus perf:
tools/run_tests.sh
# All functional suites without perf:
tools/run_tests.sh --fast
```

Named suites replace the default list; they do not implicitly append perf.
The runner inspects stderr and exit/verdict: any SCRIPT ERROR or Parse Error
fails regardless of PASS text. Real-UDP suites need loopback socket access.
Windowed `tools/shot_*.gd` capture real rendering; headless mode has no texture.

## Online co-op, releases and updates

Menu owns the connection until `_launch_session` reparents it into the run.
Online room-code play and direct-address LAN hosting share the session layer;
wire/recovery/relay details are in `codemaps/net.md`.
`BuildInfo.version()` is the canonical handshake/updater version;
`display_version()` is the human-facing form.

Updater fetches the HTTPS GitHub Release `latest.json` feed, verifies archives
through `UpdateFeed` and exposes menu-controlled install-now/install-on-quit.
Its autoload survives a running session; the HUD reports availability without
opening an install modal mid-run. CI, signed release and feed tools are mapped
in `codemaps/build.md`.

## Per-area detail

| Map | Covers |
|---|---|
| `build.md` | Modules, compilation, auto-slot/fusion rules, release/test tooling |
| `combat.md` | World, AI, terrain, population, spatial index, campaign |
| `net.md` | Session rules, wire, relay/punching, recovery, endings and parking |
| `data.md` | Registries, save schema, hostile-input guards, unlock ladder |
| `ui.md` | HUD, card previews, hub/shop/lobby, theme, rendering and capture tools |
| `audio.md` | Synth, SFX pool, generative music and Feel |
