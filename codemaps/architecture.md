> Generated: 2026-09-01 | Token-lean format for LLM context

# ROOTKIT — Architecture

Godot 4.7, GDScript only. No image assets, no font files, no `Area2D` anywhere
(including the player). Entities are packed arrays over a uniform spatial grid.

| Fact | Value |
|---|---|
| Engine | Godot 4.7, Forward Plus, `hdr_2d=true` |
| Main scene | `res://scenes/main.tscn` → `scripts/meta/meta_screen.gd` |
| Run scene | `res://scenes/run.tscn` → `scripts/run/run.gd` (`Node2D`) |
| Physics tick | 60 Hz (`physics_ticks_per_second=60`) |
| Viewport | 1280×720, stretch `canvas_items` |
| Clear color | `Color(0.016, 0.031, 0.027)` |
| Total GDScript | ~8.7k lines across `scripts/` + `data/` |

## Directory map

```
scripts/core/    grid.gd flow_field.gd                      spatial index, boss pathing
scripts/build/   module exploit equipped_module loadout      PURE: no scene tree,
                 compiler resolved_exploit player_stats           no globals
scripts/combat/  population hit_queue                       packed arrays + adjudication
scripts/run/     run spawn_director terrain ui backdrop      the live run
                 props feel                                 (feel is PURE)
scripts/audio/   synth sfx music                             procedural, no files
                                                             (synth is PURE)
scripts/meta/    save_game meta_screen settings_panel       persistence, shop, prefs
data/            module_table enemy_table recipe_table      code-defined registries
shaders/         glyph.gdshader                             procedural glyph silhouettes
tests/           37 suites + perf_milestone0                headless `-s` scripts
tools/           run_tests.sh, shot_*.gd, fps_*.gd, build_manual.py
```

**Three pure classes, one rule.** `scripts/build/*`, `run/feel.gd` and
`audio/synth.gd` touch no scene tree and no engine singleton — `AudioStreamWAV`
is a `Resource`, which is why the synth qualifies. Each is driven directly by a
suite with no viewport. `feel.gd` in particular REPORTS a desired
`Engine.time_scale` and never writes it; `run.gd` applies it.

## Dependency graph

```
             meta_screen ──> save_game ──┐
                  │                      │  (sheet deltas, mult deltas, unlocks)
                  v                      v
              run.gd ────────────> player_stats ──> loadout ──> compiler ──> resolved_exploit
                │  │  │                                 │            ^
                │  │  │                                 v            │
                │  │  └──> spawn_director          exploit ──> equipped_module ──> module
                │  │                                                              ^
                │  ├──> terrain (walls, zones, gates, collapse, distance field)   │
                │  ├──> population x3 (enemy, botnet-in-enemy-pop, hostiles)      │
                │  ├──> grid  <── pos arrays of every population                  │
                │  ├──> hit_queue ──> population                        module_table
                │  ├──> flow_field  (bosses only, gated on boss_present) enemy_table
                │  ├──> feel  ──> sfx node / music node  (drained, never called)
                │  └──> ui / backdrop / props  (draw only)

Audio and music POLL or DRAIN; nothing in the simulation holds a node
reference. run.gd appends event ids to `feel.sfx` and the Sfx node drains them;
the Music node polls `run.threat()`. That direction is deliberate and is what
keeps the tick reachable headless.
```

`scripts/build/*` has zero engine dependencies beyond `Resource`/`RefCounted` —
it is unit-testable in isolation and every build test drives it directly.

## The tick — `run._physics_process`

Split in two. **`_present(dt)` runs ABOVE the guard, every frame**; the
simulation below it early-returns on `paused or user_paused or not alive or won`.
Nothing resolves inside a callback.

The split is load-bearing: all three hitstop triggers set one of those flags on
the frame they fire, so a release driven from below the guard would never run
and `Engine.time_scale` — a process-global — would stay at 0.05 into the shell.
It also makes the death shake animate and the pause panel render at full speed.

| # | Call | Does |
|---|---|---|
| 0 | `_present` | **above the guard.** unscaled-frame-time ageing of feel, `_age_fx`, falling chunks and vignette; hitstop release on the WALL clock; camera + shake; `queue_redraw` |
| 1 | `_step1_spawn` | director waves + minibosses; **FIGHTING phase only** |
| 2 | `_step2_integrate` | player input, movement, wall slide, projectile/mine/orbit life, ward + fire cooldowns, fx ageing |
| 2c | `_step2c_gate` | shut-gate blocking, gate-crossing → `_advance_subnet` |
| 2d | `_step2d_collapse` | `collapse_left` countdown → `terrain.collapse_to`, void kills |
| 2b | `_step2b_zones` | hazard/slow/corruption zones + temp zones on player and swarm |
| 3 | `_step3_rebuild` | `grid.set_centre(player)`, union `_submerged` OR `_arriving` into the skip mask (rebuilt whole), one counting-sort rebuild; then the flow field if a boss is live |
| 4 | `_step4_steer` | per-behaviour steering, sliced `STEER_SLICES=2`, gated `STEER_RANGE_SQ` |
| 5 | `_step5_fire` | interval accumulators + queued event fires → `_emit_vector` |
| 6 | `_step6_detect` | contact damage, projectile hits, pickup, iframes |
| 6b | `_step6b_hostiles` | enemy projectiles (own `Population`, **not** in the grid) |
| 7/8 | `_steps78_drain` | `hit_queue.drain_pass` loop → `_on_death` / `_on_flip` |
| 9 | `_step9_recycle` | swap-remove despawns (via `_relocate_enemy`), botnet lifetime, shard expiry |
| 9c | `_step9c_reapproach` | stragglers past `RECYCLE_RADIUS` MOVED back to the spawn ring, damage intact; bosses and worms exempt |
| 9b | `_step9b_splits` | deferred fork_bomb splits |
| — | `_update_renderers`, `_depth_sort`, camera, `queue_redraw` | draw |

**Adjudication rules** (`scripts/combat/hit_queue.gd:1`): an entity is
adjudicated exactly once per tick, from the totals of the pass it was first
marked in, then CLOSED. Flip beats death. `ON_HIT` fires per landed hit,
`ON_KILL` per adjudicated DEAD, `ON_DAMAGE_TAKEN` per damage the player takes —
three different conditions, deliberately not one loop.

## Campaign flow

```
meta_screen ──start──> run.tscn
  subnet 1 ──5 min──> ICE spawns ──kill──> phase=CLEARED
      gate opens, spawns halt, route lit, collapse starts (COLLAPSE_SECONDS=75)
      walk the corridor ──> _advance_subnet: +30% integrity, bank salvage,
                            keep build/level/xp, gate shuts behind
  subnet 3 cleared (no gate) ──> won
  death anywhere ──> only salvage since the last clear is lost;
                     kills and flips always bank toward unlocks
```

All three arenas + the two corridors are plotted on **one** grid before the
first frame (`Terrain.plan`). `terrain.current` is the only thing that changes.

## Capacities and budgets (scripts/run/run.gd:12-76)

| Const | Value | Const | Value |
|---|---|---|---|
| `ARENA_SIZE` | 7104 × 4416 | `CELL` | 32.0 |
| `GRID_WINDOW` | 3200.0 | `MAX_ENEMIES` | 600 |
| `MAX_PROJECTILES` | 400 | `MAX_SHARDS` | 1500 |
| `MAX_BOTNET` | 64 | `MAX_HOSTILES` | 200 |
| `FIRE_BUDGET` | 4/exploit/tick | `EVENT_BUDGET` | 7200 (3×4×600) |
| `CASCADE_PASSES` | 8 | `BURST_MAX` | 12 |
| `DEPTH_BANDS` | 192 | `ISO_K` | 0.82 |
| `RECYCLE_RADIUS` | 1150.0 | `RECYCLE_PER_TICK` | 3 |
| `MAX_FALLING` | 220 | `MAX_PRESENT_DT` | 0.1 |
| `ARRIVAL_CHARGE` | 0.9 | `ARRIVAL_POP` | 0.25 |
| `CHARGE_DASH` | 0.85 | `CHARGE_SPEED` | 3.6 |

The grid is a **window that follows the player**, not a map-sized structure:
rebuild is O(cells), so sizing it to the arena would cost 5× per tick to index
ground nobody is near. Trade: entities >½ window away are not in the grid.

## Build, run, test

```
godot                       # from project root
tools/run_tests.sh          # 37 suites + perf gate
tools/run_tests.sh --fast   # skip perf gate
godot --headless -s res://tests/<suite>.gd
```

The runner reads **stderr as well as the exit code**: a GDScript runtime error
aborts only the function it happens in, so a suite whose assertions never ran
exits 0 saying `PASS`. Any `SCRIPT ERROR`/`Parse Error` fails the suite.

Perf gate (`tests/perf_milestone0.gd`) drives the real `_physics_process` over a
full autopiloted run: p95 **~4.9 ms** against a ~9.9 ms scaled budget.
Load-relative — it times a fixed workload first and scales the budget.

The flow field is the largest single cost added since the 2.4 ms era. Two
measured lessons live in `flow_field.gd`: indexing `terrain.solid` directly
rather than calling `terrain.is_solid` (which reconverts the cell and walks every
dynamic blocker) took p95 from 6.9 to 4.9, and gating the rebuild on
`boss_present()` removes it from the tick entirely for most of a subnet.

## Per-area detail

| File | Covers |
|---|---|
| `codemaps/build.md` | modules, exploits, the auto-slot rules, the compiler fold |
| `codemaps/combat.md` | run.gd, grid, population, hit queue, terrain, spawning, AI |
| `codemaps/data.md` | enemy table, module table, save schema, unlock ladder |
| `codemaps/ui.md` | run HUD blocks, level-up cards, pause + settings, rendering, shader |
| `codemaps/audio.md` | the synth, the sfx pool, the generative music, the feel layer |
