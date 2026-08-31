# Mini-bosses

Four set-piece enemies, one a minute, with ICE still closing the subnet.

Third of four passes. Depends on enemies
([2026-08-31-enemies-design.md](2026-08-31-enemies-design.md)) for the
behaviour system and hostile projectiles, and on terrain
([2026-08-31-terrain-design.md](2026-08-31-terrain-design.md)) for the one
mechanic that requires cover.

## Decisions

| Question | Answer |
|---|---|
| What a mini-boss is | A designed type with its own signature mechanic |
| Cadence | 60 / 120 / 180 / 240 s, with ICE at 300 s as today |
| Required to progress | No — they can be ignored, at a cost |

## Cadence

`SpawnDirector` gains a mini-boss schedule beside the wave table: a list of
`(time, type)`, fired once each when `elapsed` crosses them. It reuses the
integer-milli accumulator discipline the waves already use, so a mini-boss
cannot be skipped or double-fired by float drift at a boundary.

The last minute stays clear of mini-bosses. ICE arriving at 300 s is the
subnet's ending and does not share the stage.

## Not required, but expensive to ignore

A mini-boss you must kill turns a bullet heaven into a lock-and-key game, and a
player who cannot kill it has no move left. So they can be ignored — and they
stay on the field, so ignoring one means fighting it and everything that spawns
after it at the same time.

The reward for killing one is a **guaranteed card offer** plus salvage. That is
deliberately the strongest reward the game has: it makes the decision to engage
a real one, and it gives a struggling build the thing it actually needs, which
is more build.

## The four

Each has one signature mechanic no ordinary enemy has, on top of a behaviour
from the pool.

### `fork_bomb` — 60 s — splits

CHARGER behaviour. On death it splits into two smaller copies at 50% HP, and
those split once more at 50% again, three generations in total before the
leaves die for good.

Splitting happens **after step 9**, never inside the drain — the same discipline
the subnet advance follows. Spawning into a population mid-adjudication is
exactly the bug the once-per-tick rule exists to prevent.

Generation depth is a packed array, and the leaf generation must not split, or
one death becomes an unbounded cascade that fills the enemy pool. That bound is
a test, not a comment.

### `packet_filter` — 120 s — directional armour

SUPPORT behaviour, healing the swarm around it. Takes **90% reduced damage from
the front**: hits are compared against its facing, and only shots landing behind
its half-plane do full damage.

This is the first enemy whose position relative to you matters more than your
damage. Facing is its movement direction, so it turns as it repositions, and
flanking it is a real manoeuvre rather than a stat check.

The reduction lands in `_hit`, where the hit direction is already known, not in
the drain.

### `null_ptr` — 180 s — blink and afterimage

AMBUSHER behaviour on a much shorter cycle. Each time it submerges it leaves a
damaging afterimage at the point it vanished, which persists a few seconds.

The afterimages accumulate over the fight, so a long engagement progressively
denies you ground.

They cannot go in the terrain zone grid: that grid is baked once per subnet and
never mutated, which is what makes it a plain array index with no bookkeeping.
So this pass adds a small **dynamic zone overlay** to `Terrain` — a bounded list
of timed circles, checked after the baked lookup and capped hard, so a long
`null_ptr` fight cannot grow it without limit. The baked grid stays static and
the overlay stays short; nothing on the hot path gains an unbounded scan.

### `kernel_panic` — 240 s — the pulse that terrain answers

RANGED behaviour with a heavy barrage, plus a periodic arena-wide pulse on a
long, loudly telegraphed cycle. The pulse damages everything **with line of
sight to it**; standing behind a wall when it fires is the only way to avoid it.

This is the payoff for terrain existing. It is also the one mechanic here that
needs something the terrain pass explicitly put out of scope — a line-of-sight
test — so it gets one: a DDA walk over the occupancy grid from the pulse origin
to the player, which is O(cells crossed) and runs once per pulse, not per tick.

## Scaling

Mini-bosses take `SpawnDirector.hp_mult` like everything else, so they harden
across a campaign with the rest of the field. Their base integrity sits between
`firewall` and `ice`.

## Presentation

Each gets its own glyph and colour, an arrival telegraph, and a name in the HUD
while it lives. A set-piece the player does not notice arriving is not a
set-piece.

## Testing

`tests/test_minibosses.gd`:

- **Schedule** — each fires exactly once, at its time, and none fires in the
  last minute; crossing a boundary in one tick does not double-fire.
- **Split bound** — `fork_bomb` produces exactly three generations and the leaves
  do not split; a pool near capacity drops the extras rather than overflowing.
- **Split timing** — splits appear after the tick that killed the parent, never
  during the drain.
- **Directional armour** — a hit from the front is reduced, from behind is not,
  and the boundary is the half-plane rather than an arbitrary cone.
- **Afterimages** — written as zones, expire on their lifetime, and do not
  outlive a subnet advance.
- **Line of sight** — the pulse spares a player behind a wall and hits one in the
  open; the DDA walk terminates on every seed.
- **Reward** — a kill offers a card and banks salvage exactly once.

Plus `test_run.gd` and the perf gate.

## Accepted costs

- Four mini-bosses alive at once (all ignored) is a legal state and will be
  hard. That is the intended cost of ignoring them.
- The `kernel_panic` pulse ignores hostile projectiles and other enemies; it
  only asks about the player.
- The afterimage overlay is hard-capped, so a very long `null_ptr` fight stops
  producing new afterimages rather than growing the list.

## Out of scope

Mini-boss loot tables beyond the card and salvage; unique arenas; enemies that
retreat or flee at low health.
