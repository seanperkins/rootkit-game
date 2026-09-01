> Generated: 2026-09-01 | Token-lean format for LLM context

# Combat, terrain and the run loop

## `scripts/core/flow_field.gd` (130) — `FlowField`, boss pathing

BFS flooded from the player over a window that follows them — same shape as
`Grid`, same reason. `RADIUS 24` cells (1536 px), `SIDE 49`, `UNREACHED 1<<28`.

**Bosses only.** A hundred grunts shouldering round a corner is what a swarm
looks like; one large object stuck on a wall while the player circles it is the
failure anybody notices. `run._approach_dir(i, to_player)` returns the field for
ICE and mini-bosses and the straight line for everything else, and the field
returns `Vector2.ZERO` rather than guessing when it has no gradient — so a boss
can never path worse than before.

Four-way for the flood, eight-way for the read: an eight-way flood cuts diagonal
corners through walls that `terrain.slide` then refuses.

Two measured perf constraints live here. It indexes `terrain.solid` / `voided`
DIRECTLY — `terrain.is_solid` takes a world point, reconverts it to the cell it
already had, and walks every dynamic blocker first, which cost 2.8 → 6.9 ms p95.
And `run.gd` gates `rebuild` on `boss_present()`, removing it from the tick
entirely for the part of a subnet with no boss in it.

`needs_rebuild(terrain, at)` is true only on a player CELL crossing.
Covered by `tests/test_flow.gd`.

## `scripts/core/grid.gd` (172) — `Grid`

Uniform spatial grid, counting-sort (CSR) into flat packed arrays; rebuild
allocates nothing after warm-up. **A window that follows the player**, not a
map-sized structure — `GRID_WINDOW = 3200.0`.

```gdscript
enum Pop { ENEMY, PROJECTILE, BOTNET, SHARD, PLAYER, MAX }
TAG_BITS = 3   TAG_SHIFT = 28   INDEX_MASK = (1 << 28) - 1
M_ENEMY M_PROJECTILE M_BOTNET M_SHARD M_ALL(0x7FFFFFFF)
```

3 tag bits, not 2: four packed populations plus the player is five values.
`tag_of(t)` / `index_of(t)` unpack a query result.

| API | Note |
|---|---|
| `_init(origin, size, cell_size, capacity)` | |
| `set_centre(c)` / `in_window(p)` | called once per tick before rebuild |
| `rebuild(pos_arrays, counts, …)` | one counting sort over every population |
| `query_radius_into(point, r, buf, mask=M_ALL)` | filters **during** the cell walk, so a 24 px steering query does not wade through every shard |

Trade, stated in-file: an entity further than ½ window from the player is not in
the grid, so a projectile out there passes through enemies.

## `scripts/combat/population.gd` (75) — `Population`

One packed-array entity population; no nodes, no physics.
`ALIVE=0 DEAD=1 FLIPPED=2`.

Parallel arrays: `pos vel force integrity corruption type_index radius
generation state`, plus `capacity`, `count`, `_next_generation`.

- `spawn(p, v, hp, r, ti) -> int` — `-1` when full (spawn dropped, never resized).
  Resets `force` to zero so a recycled slot never inherits steering.
- `despawn(i)` — **swap-remove**, keeping live entities a dense prefix, which is
  what keeps `MultiMesh.visible_instance_count` correct. `force` moves with the
  entity.
- `integrate(dt)` — `vel += force*dt; pos += vel*dt`.

## `scripts/combat/hit_queue.gd` (196) — `HitQueue`

```gdscript
enum Kind { DAMAGE, CORRUPTION }        enum Outcome { NONE, DEAD, FLIPPED }
OPEN = 0   MARKED = 1   CLOSED = 2
```

Event arrays: `kind source_exploit target target_generation amount`, `count`.
Adjudication arrays: `adjudication outcome killer_exploit flipper_exploit`.
Hit log for ON_HIT: `hit_exploit hit_target hit_count`.

| API | Note |
|---|---|
| `begin_tick()` | clears event + hit log |
| `append(kind, exploit, target, gen, amount) -> bool` | `generation` guards a recycled slot |
| `drain_pass(pop, thresholds) -> int` | one pass; run.gd loops until it returns 0 |

**Rule 1 — single adjudication.** An entity is adjudicated once per tick, at the
end of the pass in which it first becomes marked, from every event drained in
that pass, then CLOSED; later events are discarded. Without it an enemy can
resolve dead in pass 1 (drops emitted, ON_KILL fired) and flip in pass 2.

**Rule 2 — the three trigger conditions are not the same condition.**
ON_HIT = per hit landed on an open target regardless of survival;
ON_KILL = per adjudicated DEAD; ON_DAMAGE_TAKEN = per damage the player takes.

## `scripts/run/terrain.gd` (862) — `Terrain`

One grid for the **whole campaign**: all arenas end to end plus a corridor per gap.

```gdscript
enum Kind { WALL, HAZARD, SLOW, CORRUPTION }
CELL 32.0   TILE CELL*3   MARGIN TILE*4
CORRIDOR_LENGTH TILE*12   CORRIDOR_HALF_CELLS 3   GATE_RADIUS 48.0
HAZARD_DPS 12.0   SLOW_FACTOR 0.6   CORRUPTION_PER_SEC 8.0
DENSITY_BASE 0.03   DENSITY_PER_SUBNET 0.0   REACHABLE_FLOOR 0.70
PLACE_ATTEMPTS 4000   ZONES_MIN 2   ZONES_MAX 4   WALL_MARGIN 260.0
MAX_TEMP_ZONES 24
```

Density is **flat across subnets** — a cramped late arena reads as cramped, not
hard; escalation lives in enemy HP and the wave table instead.

`class Gate`: `pos, dir (axis-aligned, outward), open, corridor: Rect2,
end: Vector2, block: Rect2`. `block` is a bounded rect, not a half-plane —
outward of the gate plane is the *next arena*.

State: `origin size w h solid zone rects arenas gates current _blocks
dist_from_gate max_dist voided _collapse_order _collapse_idx`.
`gates.size() == arenas.size() - 1`; the last arena has no gate and wins outright.

| Group | Functions |
|---|---|
| layout | `plan(arena_size, count, seed)` (static, axis-aligned links, never the reverse of the last), `_init`, `arena()`, `arena_cells(i)`, `enter_next()` |
| generation | `generate(seed, player_start)`, `_place_gates`, `_place_walls`, `_place_zones`, `_cut_corridor`, `_clear_cells`, `density_for(subnet)` |
| connectivity | `_fill_unreachable` (fills sealed regions rather than carving), `_reach`, `reachable_fraction`, `_carve_to` |
| queries | `cell_xy`, `cell_index`, `in_bounds`, `is_solid`, `zone_at`, `gate_blocks`, `has_line_of_sight`, `nearest_open` |
| movement | `slide(from, delta)`, `avoid(at, heading)` (`LOOK_AHEAD 46`, `AVOID_FORCE 90`) |
| gate | `gate()`, `has_gate()`, `open_gate()`, `_rebuild_blocks` |
| collapse | `build_distance_field()`, `_build_collapse_order()` (farthest from the gate first), `collapse_to(threshold)`, `is_void(p)`, `route_from(p, limit=400)` |
| temp zones | `add_temp_zone`, `step_temp_zones`, `temp_zone_at`, `clear_temp_zones`, `temp_zone_count` |

## `scripts/run/spawn_director.gd` (176) — `SpawnDirector`

```gdscript
enum Formation { RING, STREAM, FLANK, BURST }
SUBNET_SECONDS 300.0   CAMPAIGN_SUBNETS 3
HP_PER_SUBNET 1.55     HP_OVER_SUBNET 0.45
MINIBOSS_TIMES [60, 120, 180, 240]
MINIBOSS_IDS   [fork_bomb, packet_filter, null_ptr, kernel_panic]
```

`hp_mult(subnet, elapsed)` scales enemy integrity on **both** axes — a rank buys
damage linearly, so constant HP meant everything one-shot forever past 34 damage.
`threshold_mult(subnet)` does the same for corruption thresholds.
Also: `step(dt, origin, radius) -> Array`, `due_minibosses(dt)`,
`should_spawn_boss()`, `reset()` (zeroes `spawned`, hence run.gd's
`_spawned_before`), `_place(formation, origin, radius)`.

## `scripts/run/run.gd` (3057) — the run

Signals: `level_up_offered(cards)`, `run_ended(won, salvage)`, `stats_changed()`.
`enum Phase { FIGHTING, CLEARED }` — one fact replacing the old
`paused`/`won`/`_advance_pending` triple. The director steps in FIGHTING only.

### Rendering / projection
`to_iso(p)` / `from_iso(s)` with `ISO_K = 0.82`; `_depth_sort` over
`DEPTH_BANDS = 192`; four `MultiMeshInstance2D` (enemy, proj, shard, botnet)
built by `_build_renderers` / `_make_mm`, refreshed by `_update_renderers`.
`_draw` adds ground quads, `_void_runs`, `_route_points`, fx lines and rings
(`_fx_line`, `_fx_ring`, `FX_LIFE = 0.13`).

### Player
`player_pos player_vel player_health player_shield player_iframe (IFRAMES 0.5)
alive won subnet level xp salvage kills flips pending_levels paused`.
`_sheet` is seeded in `_ready` (a declaration initialiser runs before the save is
read). Effective stats: `_eff_integrity _eff_armor _eff_defense _eff_clock_speed`,
each taking `_ward_max(key)` — wards fold as **MAX across exploits, never a sum**.
`player_shield` is absorb, not integrity: spent before armour and defence.
`_low_armed` latches ON_LOW_INTEGRITY to the **crossing** (`LOW_INTEGRITY_FRACTION
0.4`), not the state.

### Firing
`_step5_fire` → `_emit_vector(ei, r)` dispatches on `VectorKind`
(BROADCAST, PACKET, CHAIN, BEAM, CONE `CONE_HALF_ANGLE 0.785`, PULSE, MINE
`MINE_TRIGGER 46 / MINE_LIFE 12`, ORBIT `ORBIT_RATE 2.4`).
`_fire_trigger(kind)`, `_try_event_fire`, `_hit`, `_detonate_mine`,
`apply_knockback` (`KNOCK_DECAY 6.0`), `apply_slow`, `_facing_scale`
(`FILTER_FRONT_SCALE 0.10`), `_nearest_enemy`.
Per-exploit `_fire_cd` rate-limits event triggers; `_fire_acc` is the INTERVAL
accumulator. Projectile life is bounded **only** by `_proj_dist_left` — the old
player-relative cull made reach silently inert when you ran away.

### Per-enemy arrays — BOTH halves of the slot invariant

Reset on spawn in `_spawn_enemy_state`, AND relocated tail-into-slot on despawn
by `_relocate_enemy(i, last)`. There are **two** despawn sites: `_step9_recycle`
and `_step2d_collapse`, whose `is_void` predicate is conditional and therefore
not tail-only. `_order` is the deliberate exception — `_depth_sort` refills it
wholesale each tick. `tests/test_arrivals.gd` asserts the RULE structurally:
every middle-of-pool `enemies.despawn` must relocate first.

### Arrivals — `_arriving`, and the three direct walks

Mini-bosses and ICE materialise over `ARRIVAL_TOTAL` (0.9 charge + 0.25 pop),
out of the grid and untouchable. Kept separate from `_submerged` because
`kernel_panic` is both a mini-boss and an AMBUSHER, and one flag would have the
two states clobbering each other.

Grid exclusion covers hits, targeting and contact damage (a grid query). It does
NOT cover the three passes that walk `enemies.count` directly, which each need an
explicit `_arriving` skip: **`_step2_integrate`'s enemy loop** (`_behave` chases,
`_ranged` spawns shots, `_pulse` calls `_damage_player` on a line-of-sight check
with no grid at all), **`_step2b_zones`** (hazard damage and corruption by index
— corruption is the flip channel, so a boss could flip mid-entrance), and
**`_step4_steer`** (garnish once the first is gated). `_step6b_hostiles` is NOT
one of them: it iterates `hostiles`, not enemies.

### Enemy AI — `_behave(i, t, dt)` dispatches on `EnemyTable.Behaviour`

| Behaviour | Handler | Key constants |
|---|---|---|
| CHASE | inline | separation via grid, `SEPARATION_RADIUS 26` |
| CHARGER | `_charge` | `CH_APPROACH/WINDUP/DASH/RECOVER`, `CHARGE_RANGE 260`, windup 0.7, dash 0.5, recover 0.8, speed ×3 |
| FLANKER | `_flank` | `FLANK_LEAD 0.9`, `FLANK_TANGENT 0.55` — aims at `player_vel`, the step actually taken |
| SUPPORT | `_support` | `SUPPORT_STANDOFF 300`, `SUPPORT_RADIUS 180`, `SUPPORT_HEAL 6/s`, capped by `_spawn_hp` |
| AMBUSHER | `_ambush` | `AM_SUBMERGED/SURFACING/ACTIVE`, 2.0 / 0.6 / 4.0 s, speed ×2; submerged = out of the grid, untouchable and harmless |
| RANGED | `_ranged` | `RANGED_STANDOFF 420`, `RANGED_COOLDOWN 1.6` → `_fire_hostile` |

Per-enemy AI memory (`_ai_phase _ai_timer _ai_aim _spawn_hp _submerged _knock
_split_gen _rewarded`) is sized `MAX_ENEMIES` and **reset on every spawn**
(`_clear_ai`, `_spawn_enemy_state`) — `Population.spawn` recycles slots.

Mini-boss mechanics: `_step9b_splits` (`SPLIT_GENERATIONS 3`),
`_leave_afterimage` (`AFTERIMAGE_RADIUS 70`, `AFTERIMAGE_SECONDS 5`),
`_pulse` (`PULSE_PERIOD 7.0`, `PULSE_DAMAGE 26`, line-of-sight gated),
`_spawn_miniboss`, `MINIBOSS_SALVAGE 120`.

Worms: `WORM_TYPE 2`, `WORM_TRAIL_LEN 96`, `WORM_SEG_STEPS 8`,
`WORM_BASE_SEGMENTS 2 → WORM_MAX_SEGMENTS 6` over `WORM_GROWTH_SECONDS 70`;
`_worm_trail`/`_worm_cursor` ring buffers, `_worm_sample(id, steps_back)`.

Enemy fire lives in its own `Population hostiles` (`MAX_HOSTILES 200`,
`HOSTILE_SPEED 260`, `HOSTILE_DAMAGE 6`, `HOSTILE_RADIUS 5`), deliberately **not**
in the entity grid: the only thing it can hit is the player, so detection is one
distance test per shot.

### Progression and campaign
`_gain_xp` / `_xp_for(lvl)` (`XP_SLOWDOWN 1.8`), `_offer_cards`, `choose_card`,
`decline_card`, `_recompile`, `_bank_progress(with_salvage)` (incremental — the
save *accumulates*, so handing it running totals would triple-count),
`_advance_subnet` (`SUBNET_CLEAR_HEAL 0.30`), `_hp_mult`, `_refresh_thresholds`,
`time_left`, `spawned_total`, `_die`.
Botnet defaults: `BOTNET_BASE_CAP 8`, `BOTNET_BASE_LIFETIME 12.0`,
`BOTNET_BASE_RATIO 0.6`.
`input_override` lets headless tests drive the player instead of the keyboard.
