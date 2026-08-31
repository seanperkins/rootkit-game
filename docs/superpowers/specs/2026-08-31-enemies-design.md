# Enemies and behaviour

Five new enemy types, the per-type behaviour system they need, and hostile
projectiles.

Second of four passes. Depends on terrain
([2026-08-31-terrain-design.md](2026-08-31-terrain-design.md)) for the
avoidance steering it extends; depended on by mini-bosses, which draw from the
same behaviour pool.

## Decisions

| Question | Answer |
|---|---|
| Ranged enemies | Yes — a second, hostile projectile population |
| Behaviours | Charger, flanker, support, ambusher (plus the existing chase) |

## The problem this solves

Every enemy in the game moves identically: `(player_pos - pos).normalized() *
speed`, plus a separation force. Type changes HP, speed and contact damage, and
nothing else. There is one tactical question — how close is the swarm — and it
has one answer, kite away.

## Behaviour dispatch

Behaviour is a field on `EnemyType` and a `match` inside the existing
integrate loop. No per-enemy objects, no virtual dispatch: the data-oriented
shape the rest of the combat code already keeps.

```
enum Behaviour { CHASE, CHARGER, FLANKER, SUPPORT, AMBUSHER, RANGED }
```

Behaviours that need memory get packed arrays sized `MAX_ENEMIES`, alongside
the `_worm_id` / `_worm_seg` arrays already there:

```
_ai_phase: PackedInt32Array     # which leg of its cycle
_ai_timer: PackedFloat32Array   # seconds left in that leg
_ai_aim:   PackedVector2Array   # direction locked at commit time
_spawn_hp: PackedFloat32Array   # for SUPPORT, the ceiling on healing
```

All four reset on spawn. `Population.spawn` reuses slots, so a stale phase from
a previous occupant is a live bug, not a cosmetic one — the reset is part of the
spawn path, tested.

### CHASE

Today's behaviour, unchanged, and still the default.

### CHARGER — telegraph, commit, overshoot

Four phases: `APPROACH` until within ~260 units, `WINDUP` 0.7 s stationary with
a visible tell, `DASH` 0.5 s at 3× speed along a direction **locked at the
moment the dash begins**, then `RECOVER` 0.8 s at half speed.

Locking the direction is the whole design. A dash that tracks you during the
dash is undodgeable and reads as unfair; one that commits is a timing puzzle
with a fair answer — sidestep late. The overshoot is the reward for dodging.

### FLANKER — cut off the escape

Steers toward where the player is going rather than where they are:
`player_pos + player_vel * LEAD`, plus a tangential component so it arcs around
the player rather than converging head-on.

Needs the player's velocity, which `run.gd` does not currently keep — it
integrates position directly. Add `player_vel`, derived from the position delta
in `_step2_integrate`, which is also the honest source (it accounts for the
arena clamp and, after the terrain pass, for wall slides).

Flankers are what make terrain bite: they close the lane you were kiting
toward, and a wall behind you turns that into a real mistake.

### SUPPORT — heal the swarm from the back

Holds a standoff distance of ~300 units from the player and each tick heals
enemies within ~180 units, capped at their spawn HP.

Healing, not shielding. A damage-reduction shield would have to be read inside
`HitQueue.drain_pass`, on the hot path, for every enemy whether or not a support
is alive; healing is a bounded write from the support's own behaviour step and
touches nothing else. Both create the same decision — dig for the healer first —
and only one of them costs the drain anything.

The cap is `_spawn_hp`, recorded at spawn, so healing can never take an enemy
above the integrity its type and subnet gave it.

### AMBUSHER — submerge, travel unseen, surface

`SUBMERGED` 2.0 s moving at 2× speed toward the player and **not inserted into
the entity grid**, `SURFACING` 0.6 s stationary with a tell at the destination
and still out of the grid, then `ACTIVE` 4 s of ordinary chase before it
submerges again.

Skipping grid insertion in `_step3_rebuild` is the entire implementation of
"can't be hit and can't hurt you": every hit path, every proximity query and
player contact all read the grid. No new immunity flag threaded through the
drain, no third `Population` state.

The `SURFACING` tell is not decoration. An enemy that appears on top of you
with no warning is the thing players correctly call cheap.

### RANGED — standoff and shoot

Holds ~420 units, fires a hostile projectile on a cooldown, leading the player
by their velocity. Backs away when crowded.

## Hostile projectiles

A second `Population`, `hostiles`, capped at 200.

They are **not inserted into the entity grid**. The only thing they can hit is
the player, so detection is one distance test per projectile per tick against
`player_pos` — cheaper than a grid query, and it keeps the grid's tag space and
rebuild cost untouched. They collide with terrain by the same O(1) occupancy
lookup the player's projectiles use, which is what makes walls read as cover.

Player projectiles are unchanged and cannot shoot them down; that is a
deliberate omission, not an oversight.

## The five enemies

| id | Behaviour | Shape |
|---|---|---|
| `sentinel` | CHARGER | Medium HP, heavy contact damage. The dash is the threat. |
| `tracer` | FLANKER | Fast, fragile, low damage. Dangerous in numbers, closes lanes. |
| `watchdog` | SUPPORT | Slow, tanky, no contact damage worth fearing. Heals the swarm. |
| `rootkit` | AMBUSHER | Medium, high contact damage. Punishes tunnel vision. |
| `probe` | RANGED | Fragile, slow, keeps distance. Makes terrain into cover. |

Names follow the existing fiction — `daemon`, `firewall`, `worm`, `ice` — so a
player reads them as processes on a network rather than as monsters.

They join the wave table in `spawn_director.gd` on the existing interval model,
introduced across the subnet rather than all at once, so each is legible when it
first appears.

## Performance

The dispatch is a `match` in a loop that already runs, so `CHASE` enemies cost
one extra branch. The costs that scale are:

- SUPPORT does one radius query each, so support enemies stay rare — a spawn
  cap, not a wave-rate hope.
- Hostile projectiles cost one distance test each, bounded at 200.
- AMBUSHER *reduces* grid work while submerged.

Gate: `perf_milestone0.gd`, which the terrain pass will already have moved. Both
passes draw on the same headroom, so this one re-runs it and reports the number
rather than assuming terrain left enough.

## Testing

`tests/test_behaviour.gd`, driving behaviours directly on a constructed
population rather than through a played run:

- **Phase sequences** — charger runs APPROACH → WINDUP → DASH → RECOVER with the
  stated durations, and its dash direction does not change once locked.
- **Spawn reset** — a recycled slot never inherits the previous occupant's phase,
  timer or aim.
- **Flanker leads** — against a moving player it steers ahead of them, and
  against a stationary one it degenerates to chase rather than orbiting forever.
- **Support caps** — heals nearby enemies, never above `_spawn_hp`, and never
  heals a dead one.
- **Ambusher is untouchable while submerged** — no grid entry, so no hit lands
  and no contact damage is dealt; both resume on ACTIVE.
- **Ranged** — fires on its cadence, leads a moving player, and its projectile
  damages the player and dies on terrain.

Plus `test_run.gd` and the perf gate.

## Accepted costs

- Behaviours are steering, not planning: a flanker will still walk into a wall
  the terrain pass's avoidance force cannot resolve.
- Support healing can out-pace low damage early, which is a difficulty question
  to settle by playing, not a correctness one.
- Ambushers submerged when a subnet is cleared are despawned like anything else,
  so a surfacing tell can be cut short by the advance.

## Out of scope

Enemies that use terrain deliberately (taking cover, holding chokepoints);
inter-enemy coordination beyond separation; player projectiles intercepting
hostile ones.
