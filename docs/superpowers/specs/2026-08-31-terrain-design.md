# Terrain

Static obstacles and field effects in the subnet arena, generated per subnet
from the run seed.

This is the first of four passes agreed together: terrain, then enemies with
per-type behaviour, then mini-bosses, then the new module set. Terrain goes
first so the enemy pass can be designed against an arena that already has
walls in it, rather than retrofitted for them.

## Decisions

| Question | Answer |
|---|---|
| What terrain does | Blocking walls **and** non-blocking zones, two kinds on one layer |
| Layout source | Procedural, seeded per subnet |
| Wall density | ~8% of cells at subnet 01, rising with subnet number |
| Destructible | No — fixed for the life of the subnet |

## Data model

`scripts/run/terrain.gd`, pure and testable in the manner of
`spawn_director.gd` — it holds no node references and touches no tree.

```
class_name Terrain

enum Kind { WALL, HAZARD, SLOW, CORRUPTION }

var rects: Array          # Rect2 in WORLD space, plus a Kind, for render + gen
var solid: PackedByteArray  # one byte per cell: 1 where a wall stands
var zone:  PackedByteArray  # one byte per cell: Kind + 1, or 0 for none
```

Both grids use the arena's existing geometry — `ARENA_ORIGIN`, `ARENA_SIZE`,
`CELL` 32 — giving 100 × 63 = 6,300 cells, about 12 KB for the pair. Cell
lookup is `(y * w + x)`: one array index, no allocation, no search.

The rects are the authoring and rendering representation; the byte grids are
the query representation, baked once from the rects when a subnet begins. Two
representations of one fact is a real cost, and it buys the thing that matters:
nothing on the hot path ever iterates a rect list.

## Generation

Seeded from the run seed combined with the subnet number, so a subnet's arena
reproduces exactly from a bug report — the discipline `SpawnDirector` already
follows.

1. **Place walls.** Axis-aligned rects, 2–6 cells a side, until the solid cell
   count reaches the density target. Rects landing within 260 world units of
   the player's start (the arena centre) are rejected and redrawn — enough that
   the opening seconds are never spent wedged against rock.
2. **Bake `solid`.**
3. **Guarantee connectivity.** Flood-fill the open cells 4-connected from the
   player's start cell. Any open cell the fill does not reach is **marked
   solid** — an unreachable pocket becomes rock. Filling rather than carving
   keeps the invariant total and needs no corridor-cutting pass: after this
   step, every open cell is reachable from every other, by construction.
4. **Place zones** in open cells only, 2–4 per subnet, never overlapping a wall.
5. **Bake `zone`.**

Density is one named constant scaled by subnet number: ~8% at subnet 01 to
~18% at subnet 03. It is expected to be tuned by playing, so it is a constant
with a comment, not a derived quantity.

### Why fill pockets rather than carve corridors

A sealed region is an unwinnable run: ICE, or the player, spawned inside one
cannot be reached or escaped. Carving a corridor fixes that but needs its own
pathfinding and can itself fail. Filling cannot fail and cannot produce a
second region. The cost is that a pathological seed could shrink the playfield,
which is why the reachable area has a floor asserted in test (below).

## Runtime integration

**Player** — after `player_pos` is integrated, resolve collision by axis: try
the x step, then the y step, keeping whichever does not land in a solid cell.
Running into a wall diagonally then slides along it instead of sticking.

**Enemies** — sample the occupancy grid a short distance ahead of each enemy
and add an avoidance force alongside the separation force already computed in
`_step4_steer`, which is time-sliced across `STEER_SLICES` ticks. A hard
rejection after integration guarantees no enemy ends a tick inside a wall, so
avoidance may be imperfect without ever producing an enemy embedded in rock.

This is deliberately steering, not pathfinding. A* around obstacles is the
enemy-behaviour pass, not this one; the goal here is that walls are respected,
not that enemies are clever about them yet.

**Projectiles** — a projectile entering a solid cell is marked `DEAD`, in the
same step that already retires them on spent travel distance.

**Worms phase through.** Their segments are sampled from a trail rather than
integrated, so collision would need a second mechanism for one enemy type. A
worm in the wires ignoring walls is cheaper and reads correctly.

**Zones** apply by sampling `zone` at the entity's own cell, once per tick:

- `HAZARD` — damages the player and enemies standing in it, so kiting a swarm
  through one is a real play.
- `SLOW` — cuts clock speed for the player, speed for enemies.
- `CORRUPTION` — adds corruption to enemies inside, giving a corruption build
  terrain to fight over rather than only enemies.

Each effect's magnitude is a named constant on `Terrain`, expressed per second
so it is frame-rate independent. Starting values are a guess to be replaced by
play, in the same spirit as the density constant: hazard 12/s, slow x0.6,
corruption 8/s.

**Spawn rejection.** `SpawnDirector.step` returns points on the 720-unit ring
around the player; a point landing in rock is nudged to the nearest open cell
by a bounded search. The ICE spawn at 420 units takes the same treatment. A
bounded search, not a loop until success — an unbounded retry is a hang on a
dense seed.

## Rendering

Walls draw in `_draw` beneath the entities. A world-space AABB under `to_iso`
is a sheared parallelogram, so each wall is its four projected corners through
`draw_colored_polygon`, with an outline in the existing palette. Zones draw the
same way, translucent, tinted per kind.

Drawing from `rects` rather than per-cell keeps the draw call count at the
number of obstacles — a few dozen — rather than the number of solid cells.

## Performance

The bake happens once per subnet. Per tick the additions are all O(1) array
indexing with no allocation:

- one zone sample per enemy, per projectile, and for the player
- one or two occupancy samples per enemy inside the existing steer slice
- one occupancy sample per projectile

The gate is `perf_milestone0.gd`, currently passing at p95 3.291 ms against a
9.981 ms scaled budget. This work spends some of that 6.7 ms of headroom and
the gate is re-run as part of it.

## Testing

`tests/test_terrain.gd`, driving the generator directly rather than through a
run:

- **Determinism** — the same seed and subnet produce an identical field.
- **Connectivity** — across several hundred seeds, every open cell is reachable
  from the player's start cell.
- **Playfield floor** — the reachable open area is at least 70% of the arena, so
  a pathological seed cannot shrink the arena to a closet.
- **Spawn safety** — the player's start cell and the spawn ring are never solid.
- **Density** — the solid fraction tracks the target, and rises with subnet.
- **Collision** — an entity stepped into a wall ends outside it; a diagonal step
  into a wall slides rather than stopping dead.
- **Zones** — an entity inside a zone receives its effect and stops receiving it
  on leaving.

Plus a re-run of `perf_milestone0.gd` and `test_run.gd`.

## Accepted costs

Named here so they are choices rather than oversights:

- The shard magnet pulls shards through walls.
- Enemy avoidance is steering, not pathing: an enemy can still be held against
  a wall by the swarm behind it.
- Worms ignore terrain entirely.

## Out of scope

Destructible walls; A* or flow-field pathfinding; terrain-aware line-of-sight
for beams; terrain that varies within a subnet.

Two of these are taken up by later passes rather than abandoned. The mini-boss
pass adds a bounded **dynamic zone overlay** for timed effects like `null_ptr`'s
afterimages — the baked grid here stays static and immutable, with the overlay
checked separately — and a **line-of-sight** walk over the occupancy grid for
`kernel_panic`'s pulse, run once per pulse rather than per tick.
