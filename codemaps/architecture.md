> Generated: 2026-09-02 | Token-lean format for LLM context

# ROOTKIT — Architecture

Godot 4.7, GDScript only. No image assets, no font files, no `Area2D` anywhere
(including the players). Entities are packed arrays over a uniform spatial
grid. One deterministic simulation, run identically on every peer of a
lockstep session; solo is a one-slot session with delay zero.

| Fact | Value |
|---|---|
| Engine | Godot 4.7, Forward Plus, `hdr_2d=true` |
| Main scene | `res://scenes/main.tscn` → `scripts/meta/meta_screen.gd` (shop + lobby) |
| Run scene | `res://scenes/run.tscn` → `scripts/run/run.gd` (`Node2D`, 5.6k lines) |
| Physics tick | 60 Hz, `SessionRules.TICK_DT`; the tick never reads a clock |
| Viewport | 1280×720, stretch `canvas_items` |
| Players | `SessionRules.MAX_PLAYERS = 4`, every per-player field a slot array |
| Total GDScript | ~13.4k lines across `scripts/` + `data/` |

## Directory map

```
scripts/core/    grid.gd flow_field.gd                      spatial index, boss pathing
scripts/build/   module exploit equipped_module loadout      PURE: no scene tree,
                 compiler resolved_exploit player_stats           no globals
scripts/combat/  population hit_queue                       packed arrays + adjudication
scripts/net/     lockstep network_session protocol          PURE ring, session, codec
                 transport                                  the ONE ENet class (Node)
scripts/run/     run spawn_director terrain blocks ui        the live run
                 backdrop props feel                        (feel is PURE)
scripts/audio/   synth sfx music                             procedural, no files
                                                             (synth is PURE)
scripts/meta/    save_game meta_screen settings_panel       persistence, shop, lobby
data/            module_table enemy_table recipe_table      code-defined registries
                 session_rules                              every shared constant
shaders/         glyph.gdshader                             procedural glyph silhouettes
tests/           52 suites + perf_milestone0, support/      headless `-s` scripts
tools/           run_tests.sh, shot_*.gd, fps_*.gd,
                 determinism_probe.gd, build_manual.py
```

**The pure layers.** `scripts/build/*`, `run/feel.gd`, `audio/synth.gd`,
`net/lockstep.gd`, `net/network_session.gd` and `net/protocol.gd` touch no
scene tree and no engine singleton beyond `Resource`/`RefCounted`. Each is
driven directly by a suite with no viewport. Nothing writes
`Engine.time_scale` any more: hitstop is a tick count.

## Dependency graph

```
 meta_screen ──> save_game (counters, prefs)        meta_screen ──> network_session ──> transport
      │  START descriptor {seed, delay, roster+counters}            (lobby: HELLO/WELCOME/START)
      v                                                                        │ reparented
   run.gd ── configure_session ──> network_session ──> lockstep <── transport <─┘
     │  _derive_roster: player_stats ──> loadout ──> compiler ──> resolved_exploit
     ├──> spawn_director        exploit ──> equipped_module ──> module   module_table
     ├──> terrain (walls, zones, gates, collapse, distance field)         enemy_table
     ├──> population ×5 (enemies, projectiles, shards, botnet, hostiles)
     ├──> grid  <── pos arrays of every population; window = the party's bounds
     ├──> hit_queue ──> population
     ├──> flow_field ×4 (one per slot; bosses only)
     ├──> blocks (the held objective)
     ├──> feel  ──> sfx node / music node  (drained / polled, never called)
     └──> ui / backdrop / props  (draw only)
```

Audio and music POLL or DRAIN; the network is POLLED above the guard; nothing
in the simulation holds a node reference. That direction is what keeps the
tick reachable headless and identical on every peer.

## The tick — `run._physics_process`

Two halves around ONE guard. Above it, every frame: render snapshot, local
input sampling, the network, presentation, roster changes, the ring, input
application. Below it, only when the ring is ready and nothing holds the
world: `_step_world()`.

| Above the guard | Does |
|---|---|
| `_snapshot_render_state` | `prev_pos = pos` for every population and slot |
| `_poll_local_input` | the ONLY `Input.*` site; submits the full record for `executed + delay` to the ring and the wire |
| `transport.poll / _drain_inbox / _reconnect_step / flush_relay` | records → ring, control → session inbox → dispatch; host sends one RELAY per tick |
| `_present` | feel, fx, vignette, falling chunks on the unscaled frame delta |
| `_roster_step` | ABSENT before the tick it names, PRESENT after |
| `_sync_ring_roster / _recovery_step / _ending_step` | ring masks follow `slot_state`; desync boundaries; ending barrier |
| `ready? take → _apply_records → _resolve_deadlines → _settle_offers` | one tick's records applied; card choices land here |
| `hitstop_ticks` then the guard | `paused or (user_paused and solo) or not alive or won or ended` holds the world, not the input stream |

| `_step_world` | Does |
|---|---|
| `_step1_spawn` | director waves + minibosses, **FIGHTING only**, rate × party |
| `_step2_integrate` | every LIVE slot: input, movement, leash, wall slide; projectile/mine/orbit life; cooldowns |
| `_step2c_gate` / `_step2d_collapse` / `_step2e_blocks` / `_step2b_zones` | gate waits for all LIVE; arena then corridor collapse; the block; zones on every LIVE slot |
| `_step3_rebuild` | grid window = party bounds; one O(entities) rebuild; flow fields if a boss is live |
| `_step4_steer` / `_step5_fire` / `_step6_detect` / `_step6b_hostiles` | per-enemy target chosen once per tick by census; fire per owning slot; hits, pickups, iframes per slot |
| `_steps78_drain` | `hit_queue.drain_pass` loop → `_on_death` / `_on_flip` |
| `_step9_recycle` / `_step9c_reapproach` / `_step9b_splits` / `_depth_sort` | swap-remove despawns (relocating every parallel array), stragglers, splits, draw order |

`_present` and the network run above the guard because all hitstop and
ending triggers set a guard flag on the frame they fire; a release below it
would never run. See `codemaps/net.md` for the session, `codemaps/combat.md`
for the world.

## Campaign flow

```
meta_screen ──start (solo or START)──> run.tscn
  subnet 1 ──5 min──> ICE spawns ──kill──> phase=CLEARED
      gate opens, spawns halt, route lit, collapse starts (COLLAPSE_SECONDS=75)
      every LIVE slot through the gate ──> _advance_subnet: +30% integrity,
                            bank salvage, keep builds, gate shuts behind
  subnet 3 cleared (no gate) ──> won (a WIN candidate in a session)
  no slot LIVE ──> lost (a LOSS candidate in a session); kills and flips
                   always bank toward unlocks, per slot, once
```

All three arenas + the two corridors are plotted on **one** grid before the
first frame (`Terrain.plan`). `terrain.current` is the only thing that changes.

## Capacities and budgets (`run.gd:12-76`, `session_rules.gd`)

| Const | Value | Const | Value |
|---|---|---|---|
| `ARENA_SIZE` | 7104 × 4416 | `CELL` | 32.0 |
| `GRID_WINDOW` / `MAX_WINDOW` | 3200 / 7200 | `LEASH` | 4000 |
| `MAX_ENEMIES` | 600 | `MAX_PROJECTILES` | 400 |
| `MAX_SHARDS` | 1500 | `MAX_BOTNET` | 64 |
| `FIRE_BUDGET` | 4/exploit/tick | `EVENT_BUDGET` | 7200 (× `MAX_PLAYERS` queue) |
| `CASCADE_PASSES` | 8 | `HITSTOP_TICKS` | 4 |
| `DEPTH_BANDS` | 192 | `ISO_K` | 0.82 |
| `RECYCLE_RADIUS` | 1150.0 | `RECYCLE_PER_TICK` | 3 |
| `MAX_PRESENT_DT` | 0.1 | `Lockstep.RING` | 128 |

The grid is a **window over the party's bounding box**, not a map-sized
structure; the leash keeps that box within `MAX_WINDOW`.

## Build, run, test

```
godot                       # from project root
tools/run_tests.sh          # 52 suites + perf gate
tools/run_tests.sh --fast   # skip perf gate
godot --headless -s res://tests/<suite>.gd
godot --headless -s res://tools/determinism_probe.gd   # tick hash per tick
```

The runner reads **stderr as well as the exit code**: a runtime error aborts
only the function it happens in, so a suite whose assertions never ran exits 0
saying `PASS`. Any `SCRIPT ERROR`/`Parse Error` fails the suite.
`test_transport_loopback` needs real UDP (run outside the Bash sandbox).

Perf gate (`tests/perf_milestone0.gd`): the real `_physics_process` over a
full autopiloted run with FOUR slots pinned at the full leash and worst-case
builds on all of them — p95 normalised ~9.8 ms against an 11 ms budget.
Load-relative: it times a fixed workload first and scales the budget.

## Per-area detail

| File | Covers |
|---|---|
| `codemaps/build.md` | modules, exploits, the auto-slot rules, the compiler fold |
| `codemaps/combat.md` | run.gd, grid, population, hit queue, terrain, spawning, AI, slots |
| `codemaps/net.md` | session rules, lockstep, protocol, transport, recovery, endings, parking |
| `codemaps/data.md` | enemy table, module table, save schema, session counters, unlock ladder |
| `codemaps/ui.md` | run HUD, cards, lobby, pause + settings, rendering, shader, tools |
| `codemaps/audio.md` | the synth, the sfx pool, the generative music, the feel layer |
