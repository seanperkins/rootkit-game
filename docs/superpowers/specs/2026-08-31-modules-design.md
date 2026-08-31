# New modules

Ten vectors, three triggers, four payloads — and the three runtime mechanics
they need.

Last of four passes. Depends on enemies
([2026-08-31-enemies-design.md](2026-08-31-enemies-design.md)) for hostile
projectiles, which one defensive vector exists to stop.

## Decisions

| Question | Answer |
|---|---|
| New firing code | Mixed — four new `VectorKind`s, six as variants |
| Defensive vectors | Weapons that fire on a cadence but pay off defensively |

## Three new mechanics

The modules are mostly data. These are not, and they are the real work.

**Knockback.** An impulse array on enemies, decaying over a short window, added
in the integrate step alongside the separation force. Enemies already carry
`vel` and `force`, so this is one more `PackedVector2Array` and one more term.

**Enemy slow.** A per-enemy remaining-duration and factor, multiplying speed in
the integrate step. Refreshing a slow takes the stronger of the two rather than
adding, for the same reason wards fold by max.

**Player shield.** An absorb pool consumed before integrity in the damage
handler. It is not integrity: it does not heal, it does not show in the
integrity ratio, and it is granted in whole chunks on fire.

## Five new stat keys

`STAT_KEYS` is a closed set and every key is a field on `ResolvedExploit`, so
each addition is deliberate:

| Key | Fold | For |
|---|---|---|
| `knockback` | sum | Impulse magnitude |
| `slow_amount` | **max** | Fraction of speed removed, 0–1 |
| `slow_duration` | **max** | Seconds it lasts |
| `shield` | **max** | Absorb granted on fire |
| `orbit_count` | sum, floored | Number of orbiters |

The three defensive keys join `MAX_FOLD_KEYS` beside `ward_*` and `lifesteal`,
on the argument already written there: the same module is legal in many slots,
and summing a defensive magnitude buys it at no uptime cost.

`validate()` gains one rule, mirroring the corruption-tag rule it already has: a
module contributing `slow_amount` must carry the `slow` tag, or the stat and
the tag drift apart silently while the runtime gates on the tag.

## Four new vector kinds

Each is a new branch in `_emit_vector`.

**`PULSE`** — a shockwave from the player: damages and knocks back everything in
`radius`. Reuses the broadcast query; the new part is the impulse.

**`ORBIT`** — persistent shards circling the player, damaging on contact and
destroying hostile projectiles they touch. Implemented as projectiles with a
parametric position rather than a velocity, so they need no new population —
but they do need a lifetime tied to the exploit's cadence, so firing again
replaces rather than accumulates.

**`CONE`** — a 90° arc toward the nearest enemy. A broadcast query filtered by
angle: cheap, and it reads completely differently because it demands facing.

**`MINE`** — drops a stationary charge that detonates on proximity, damaging in
a small radius. Projectiles with zero velocity and a proximity trigger; the
detonation reuses the broadcast query path.

## The ten vectors

Attack:

| id | Kind | Shape |
|---|---|---|
| `spike()` | CONE | Short reach, wide arc, heavy damage |
| `flood()` | BROADCAST variant | Huge radius, low damage, slow cadence |
| `snipe()` | PACKET variant | Very long travel, high damage, pierces, slow |
| `landmine()` | MINE | Area denial; rewards predicting the swarm's path |
| `cascade()` | CHAIN variant | More hops, shorter reach, less per hit |

Defensive — still weapons, still on a cadence, but the payoff protects:

| id | Kind | Shape |
|---|---|---|
| `bounce()` | PULSE | Modest damage, heavy knockback. Buys space. |
| `mirror()` | ORBIT | Orbiters damage contact and eat hostile projectiles |
| `throttle()` | BROADCAST variant | Near-zero damage, strong slow in a wide radius |
| `airgap()` | PULSE variant | No damage, maximum knockback, plus `ward_armor` |
| `checksum()` | BROADCAST variant | Tiny radius; the point is the `shield` on fire |

`mirror()` is the one module that would do nothing before the enemy pass lands,
since it exists to stop hostile projectiles. It ships with that pass, not
before it.

## Three triggers

Each is a new `TriggerKind` and one hook at an event that already exists.

| id | Fires when | Hook |
|---|---|---|
| `on_low_integrity` | Integrity crosses below 40% | The damage handler |
| `on_flip` | An enemy flips to the botnet | `_on_flip` |
| `on_level_up` | A level is gained | `_gain_xp` |

`on_low_integrity` re-arms only after integrity climbs back above the
threshold. Without that it fires every tick spent under 40%, which is both a
DPS cliff and, on a defensive vector, an infinite shield.

Each carries a `cadence_mult` above 1.0, like the event triggers already
shipped: conditional firing is bought with cadence.

## Four payloads

Pure stats, no new runtime:

| id | Gives |
|---|---|
| `bitmask` | `pierce` |
| `race_condition` | `cadence_mult` below 1.0 — faster, at the cost of the slot |
| `heap_spray` | `chain_count` and `radius` |
| `tarpit` | `slow_amount` / `slow_duration`, tagged `slow` |

## The pool dilution problem

The table goes from 18 modules to 35, and a level-up still offers three. The
chance of drawing the module a build actually wants roughly halves, which makes
builds mushier, not richer — the opposite of the point.

So about eight of the new modules ship **locked**, joining `beam`,
`on_damage_taken` and `worm` behind kill and flip milestones in
`SaveGame._milestone_met`. The early pool stays close to today's size and
sharpness; the new breadth arrives as the meta unlocks it. Which eight is a
tuning decision, taken when the modules exist to be judged.

## Testing

Extending `test_build.gd`'s data sweep, which already validates every module in
the table, plus `tests/test_vectors.gd` and `tests/test_effects.gd`:

- **Data sweep** — all 35 modules validate; every `slow_amount` carries the tag.
- **Fold rules** — the three defensive keys take the max across slots, not the
  sum; `orbit_count` sums and floors once at the end.
- **Each new kind fires** — cone hits inside its arc and misses outside it; pulse
  knocks back and the impulse decays; mine detonates on proximity and not on
  spawn; orbit replaces rather than accumulates on refire.
- **Mechanics** — slow multiplies speed and expires; refreshing takes the
  stronger; shield absorbs before integrity and does not heal.
- **`mirror()` eats hostile projectiles** and leaves player projectiles alone.
- **Triggers** — each fires on its event; `on_low_integrity` fires once per
  crossing, not once per tick under the threshold.

Plus `test_run.gd`, the perf gate, and a `test_dispatch.gd` extension covering
the new kinds' targeting.

## Accepted costs

- 35 modules is a lot to hold in one card pool even with unlocks; the level-up
  screen shows three and there is no reroll.
- `ORBIT` and `MINE` both borrow the projectile population, so a build running
  both competes for the 400-projectile cap.
- Knockback can push an enemy into terrain; the terrain pass's hard rejection
  keeps it out of walls, which means heavy knockback against a wall does less.

## Out of scope

Module synergies beyond stat folding; per-module unique visuals beyond colour;
rerolls or card banking; retuning the existing 18.
