# ROOTKIT

A bullet heaven where the build system is the hacking. You are a rogue process
in a corporate network; you move, everything else fires itself, and your power
comes from compiling exploits out of typed modules.

Godot 4.7, GDScript, no image assets.

## Run it

```
godot                      # from the project root
```

**WASD or arrows.** All weapons auto-fire. Survive five minutes, kill ICE, win.
Clearing the subnet banks salvage; dying loses it but still counts kills and
flips toward unlocks.

## The build

An **exploit** is one weapon with three slot types:

| Slot | Count | Decides | Modules |
|---|---|---|---|
| `VECTOR` | 1 | how it reaches enemies | broadcast, packet, chain, beam |
| `TRIGGER` | 1 | when it fires | interval, on_kill, on_hit, on_damage_taken |
| `PAYLOAD` | 0–2 | what it does on contact | buffer_overflow, fork_bomb, corrupt, keylog, worm, fork, overclock |

You hold three exploits. Level-ups offer three module cards, each naming where
it will land — a rank-up, an empty slot, a new exploit, or a replacement. Any
card can be declined for salvage.

Damage tagged `corruption` fills a second bar. An enemy that fills it **flips**
into a botnet node that fights for you, and drops the same shards a kill does,
so a corruption build doesn't starve its own levelling.

## Architecture

Enemies, projectiles, shards, and botnet nodes are **packed arrays over a
uniform grid** — no `Area2D` anywhere, including the player. Hit detection,
proximity queries, and separation steering all read one grid rebuilt once per
tick.

All combat resolves in one ordered nine-step tick (`scripts/run/run.gd`), never
inside a callback. Each entity is **adjudicated exactly once per tick**, from
the totals of the pass it was first marked in, and flip beats death.

```
scripts/core/    grid.gd  object_pool  event_bus
scripts/build/   module  exploit  compiler  loadout        (pure, no scene tree)
scripts/combat/  population  hit_queue
scripts/run/     run  spawn_director  ui  backdrop
scripts/meta/    save_game  meta_screen
data/            module_table  enemy_table
shaders/         glyph.gdshader
```

## Tests

```
godot --headless -s res://tests/test_build.gd        # compiler + auto-slot rules
godot --headless -s res://tests/test_drain.gd        # adjudication, both orders
godot --headless -s res://tests/test_corruption.gd   # flip -> botnet
godot --headless -s res://tests/test_meta.gd         # shop, unlocks, save durability
godot --headless -s res://tests/test_run.gd          # a full winning subnet
godot --headless -s res://tests/perf_milestone0.gd   # the architecture gate
```

The perf gate is **load-relative**: it times a fixed workload first and scales
its budget, because identical code measures 5.2 ms median on a quiet machine and
8.5 ms under load. Above 1.8x contention it declines to judge rather than
false-fail.

## Not in this build

Audio, additional subnets (the node map is scaffolded but unreachable),
controller support, and in-run stat changes.

## Design

`docs/superpowers/specs/2026-08-29-rootkit-bullet-heaven-design.md` — the spec,
plus a record of the three review rounds that reshaped it, including the
architecture reversal from pooled `Area2D` to packed arrays.
