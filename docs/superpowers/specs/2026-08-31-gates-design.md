# Gates between subnets

The advance stops being a teleport and becomes a walk you can see coming.

Slots between terrain (built) and enemies (next). Depends on terrain for
generation, the occupancy grid and rendering; changes `_advance_subnet` from the
campaign pass.

## The shape

A gate stands at the edge of every subnet's arena **from the moment it
generates**, closed. You see it early, while you are still fighting. Clearing
ICE opens it: the backdrop grid lights toward it, the gate reads as inviting
rather than as scenery, and spawning stops. Walk in and you are in a corridor.
After a way, you come out on a new map and the gate shuts behind you.

## Decisions

| Question | Answer |
|---|---|
| Gate visible before the boss dies | Yes — closed, from generation |
| After the boss dies | Spawning stops; stragglers remain |
| Refusing to leave | Allowed indefinitely; the gate waits |
| Last subnet | No gate. Clearing ICE on subnet 03 wins, as today |

## Why it earns its cost

The current advance swaps the arena under the player mid-stride. It is the
biggest moment in a run and it reads as a glitch. A gate spends that moment
instead of skipping it: the walk is the reward, the corridor is a breather, and
the close behind you is what makes the next arena feel like somewhere else
rather than the same field reshuffled.

Foreshadowing does the other half. A gate you have been walking past for five
minutes is a promise; the same gate appearing on the boss kill is a prompt.

## Run phases

`run.gd` gains an explicit phase, replacing the implicit "paused / alive / won"
triple that currently encodes this badly:

```
enum Phase { FIGHTING, CLEARED, TRANSIT }
```

- **FIGHTING** — today's behaviour.
- **CLEARED** — ICE is dead, the gate is open, the wave table is halted.
  Stragglers still fight. Entering the gate moves to TRANSIT.
- **TRANSIT** — the corridor. No spawns, no wave clock. Reaching the far end
  generates the next subnet's arena and returns to FIGHTING.

The phase is the single source of truth for "is the director stepping" and "does
the tick spawn", both of which are currently spread across `paused`, `won` and
`_advance_pending`. `_advance_pending` disappears into it.

## The gate as terrain

`Terrain` gains a gate: a position on one arena edge, a facing, and an open
flag. It is generated with the walls and is subject to the same guarantee — you
must be able to reach it.

Ordering matters and is the one subtle part:

1. Place walls.
2. Flood-fill from the player start; fill unreachable pockets. (Unchanged.)
3. Place the gate on a random edge, in a cell forced open.
4. If the gate's cell is not in the reachable set, carve a straight line from
   the gate toward the player's start until it meets reachable ground.

Step 4 is carving, which the terrain spec argued against for pockets — and the
argument does not apply here. A straight line toward a point known to be
reachable always terminates and cannot leave a second region behind; the general
pocket case had neither property. Doing it after the fill rather than before is
what keeps that true.

## The corridor

A separate small `Terrain` instance, not part of either arena: a narrow strip
roughly 1200 units long, walled on both sides, empty of everything. It is
generated when the player enters the gate and discarded when they leave it.

No spawns, no wave clock, no ICE. Walking its length takes a few seconds, which
is the entire point — it is the beat between two arenas that the current advance
does not have.

Reusing `Terrain` rather than inventing a corridor type means collision,
rendering and the occupancy grid all work there for free.

## Wayfinding

On the boss kill the backdrop grid lights toward the gate. Deliberately **not**
a path: it is a directional wash — grid cells brighten with their alignment to
the gate's bearing from the player, strongest near it, animated as a slow pulse
travelling that way.

A literal route would need pathfinding the game does not have and does not need
here. Arenas are 8–18% walls and fully connected, so a bearing is enough to
navigate by, and a wash cannot be wrong the way a stale path can.

## What carries through

Everything the campaign pass already carries: loadout, level, XP, integrity, and
the 30% clear heal, which now lands on entering the gate rather than on the ICE
kill. Salvage banks on the ICE kill, unchanged — the reward is for the boss, not
for walking.

## Testing

`tests/test_gates.gd`:

- **The gate is reachable** — across many seeds and every subnet, a flood fill
  from the player's start reaches the gate cell.
- **Closed until cleared** — the gate is shut in FIGHTING and open in CLEARED,
  and entering a closed gate does nothing.
- **Phase transitions** — ICE kill moves FIGHTING → CLEARED; entering the gate
  moves CLEARED → TRANSIT; the corridor's end moves TRANSIT → FIGHTING with the
  subnet incremented.
- **Spawning halts in CLEARED and TRANSIT** — the director does not step, and no
  enemy appears in the corridor.
- **Lingering is free** — a thousand ticks in CLEARED changes nothing but the
  clock; the gate stays open.
- **The build survives the walk** — loadout, level and XP are identical on the
  far side; the heal applies once, on entry, not per tick.
- **Last subnet has no gate** — subnet 03's ICE kill wins immediately.
- **The corridor is escapable** — its far end is always reachable from its
  entrance, on every seed.

Plus `test_campaign.gd`, `test_run.gd` and the perf gate. `test_campaign`'s
advance assertions will need rewriting: `_advance_subnet` stops being a single
call and becomes a phase walk.

## Accepted costs

- A run's wall-clock time grows by a few seconds per subnet.
- The corridor is a second live `Terrain`; rendering must draw the right one.
- Both autopilots need to walk to the gate, or they will sit in CLEARED forever
  and every campaign test will time out instead of failing. This is the same
  class of problem as the terrain-blind kiting that shrank the perf gate, and it
  is called out here rather than discovered again.

## Out of scope

Gates as a fast-travel network; going back through a gate; corridors with
content in them; a gate that costs salvage to open.
