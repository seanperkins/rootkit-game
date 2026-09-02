> Generated: 2026-09-02 | Token-lean format for LLM context

# Combat, terrain and the run loop

## `scripts/core/flow_field.gd` (130) — `FlowField`, boss pathing

BFS flooded from ONE slot over a window that follows it — same shape as
`Grid`, same reason. The run holds four (`_flow[slot]`), one per LIVE slot. `RADIUS 24` cells (1536 px), `SIDE 49`, `UNREACHED 1<<28`.

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

## `scripts/core/grid.gd` (242) — `Grid`

Uniform spatial grid, counting-sort into flat packed arrays; the rebuild is
O(entities) (`_cell_count` + a `_touched` list, prefix over touched cells only)
and allocates nothing after warm-up. **A window over the party's bounding
box**, not a map-sized structure — `GRID_WINDOW = 3200.0` solo, up to
`SessionRules.MAX_WINDOW = 7200` for a party held by the 4000 leash.

```gdscript
enum Pop { ENEMY, PROJECTILE, BOTNET, SHARD, PLAYER, MAX }
TAG_BITS = 3   TAG_SHIFT = 28   INDEX_MASK = (1 << 28) - 1
M_ENEMY M_PROJECTILE M_BOTNET M_SHARD M_ALL(0x7FFFFFFF)
```

3 tag bits, not 2: four packed populations plus the player is five values.
`tag_of(t)` / `index_of(t)` unpack a query result.

| API | Note |
|---|---|
| `_init(origin, max_size, cell_size, capacity)` | sized for `MAX_WINDOW` once |
| `set_window(rect)` / `set_centre(c)` / `in_window(p)` / `live_cell_count()` | the party window, set once per tick before rebuild |
| `rebuild(pos_arrays, counts, …)` | one counting sort over every population |
| `query_radius_into(point, r, buf, mask=M_ALL)` | filters **during** the cell walk, so a 24 px steering query does not wade through every shard |

Trade, stated in-file: an entity outside the window is not in the grid, so a
projectile out there passes through enemies.

## `scripts/combat/population.gd` (118) — `Population`

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

## `scripts/combat/hit_queue.gd` (210) — `HitQueue`

```gdscript
enum Kind { DAMAGE, CORRUPTION }        enum Outcome { NONE, DEAD, FLIPPED }
OPEN = 0   MARKED = 1   CLOSED = 2
```

Event arrays: `kind source_exploit target target_generation amount`, `count`.
Adjudication arrays: `adjudication outcome killer_exploit flipper_exploit`.
`dropped` counts appends refused at capacity — the queue is sized
`EVENT_BUDGET * MAX_PLAYERS` and the perf gate requires zero.
`drained_events` counts events drained this TICK across every pass (reset in
`begin_tick`); `count` and `hit_count` are zeroed by the drain, so it is the
only per-tick hit figure the perf gate's load pin can read.
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

## `scripts/run/terrain.gd` (949) — `Terrain`

One grid for the **whole campaign**: all arenas end to end plus a corridor per gap.

```gdscript
enum Kind { WALL, HAZARD, SLOW, CORRUPTION }
CELL 32.0   TILE CELL*3   MARGIN TILE*4
CORRIDOR_LENGTH TILE*12   CORRIDOR_HALF_CELLS 3   GATE_RADIUS 48.0
HAZARD_DPS 12.0   SLOW_FACTOR 0.6   CORRUPTION_PER_SEC 8.0
ZONE_FLIP_BUDGET 6   ZONE_RECHARGE 40.0   # per corruption rect; run holds _zone_flips/_zone_recharge (SH)
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
| queries | `cell_xy`, `cell_index`, `in_bounds`, `is_solid`, `zone_at`, `zone_rect_at`, `gate_blocks`, `has_line_of_sight`, `nearest_open` |
| zones | `paint_zone(rect, kind) -> rect index` (generation and suites; bakes `zone` and `zone_rect` per cell) |
| movement | `slide(from, delta)`, `avoid(at, heading)` (`LOOK_AHEAD 46`, `AVOID_FORCE 90`) |
| gate | `gate()`, `has_gate()`, `open_gate()`, `_rebuild_blocks`, `gate_open_flags()` / `set_gate_open_flags()` (snapshot) |
| collapse | `build_distance_field()`, `_build_collapse_order()` (farthest from the gate first), `collapse_to(threshold)`, `is_void(p)`, `route_from(p, limit=400)`; corridor phase `corridor_collapse_len`, `CORRIDOR_COLLAPSE_TICKS 600`, `_clear_collapse_state`, `restore_collapse(idx)` (snapshot) |
| temp zones | `add_temp_zone`, `step_temp_zones`, `temp_zone_at`, `clear_temp_zones`, `temp_zone_count` |

## `scripts/run/spawn_director.gd` (192) — `SpawnDirector`

```gdscript
enum Formation { RING, STREAM, FLANK, BURST }
SUBNET_SECONDS 300.0   CAMPAIGN_SUBNETS 3
HP_PER_SUBNET 1.55     HP_OVER_SUBNET 0.45   HP_PER_EXTRA_PLAYER 0.50
MINIBOSS_TIMES [60, 120, 180, 240]
MINIBOSS_IDS   [fork_bomb, packet_filter, null_ptr, kernel_panic]
```

`hp_mult(subnet, elapsed)` scales enemy integrity on **both** axes — a rank buys
damage linearly, so constant HP meant everything one-shot forever past 34 damage.
`threshold_mult(subnet)` does the same for corruption thresholds;
`party_hp_mult(live)` adds 0.5 per extra LIVE slot and `rate_mult` scales the
wave rate with the party. Seeded from the session descriptor, never
`randomize()`.
Also: `step(dt, origin, radius) -> Array`, `due_minibosses(dt)`,
`should_spawn_boss()`, `reset()` (zeroes `spawned`, hence run.gd's
`_spawned_before`), `_place(formation, origin, radius)`.

## `scripts/run/run.gd` (5723) — the run

Signals: `level_up_offered(cards)`, `fusion_offered(matches)`,
`offer_waiting(unresolved)`, `run_ended(won, salvage)`, `stats_changed()`.
`enum Phase { FIGHTING, CLEARED }`. The director steps in FIGHTING only. The
tick order and the session half (ring, recovery, endings, parking) are in
`codemaps/architecture.md` and `codemaps/net.md`; this section is the world.

### Slots — every player field is a `MAX_PLAYERS` array

`enum SlotState { LIVE, DEAD, ABSENT }`, `slot_state`, `local_slot`.
`player_pos player_prev_pos player_render_pos player_vel player_facing
player_health player_iframe player_shield _parked_health pickup_radius kills
flips inputs _low_armed _banked _sheet _unlocked loadouts`, allocated in `_allocate_slots`,
brought LIVE from the descriptor in `_derive_roster`. `resolved` is
slot-strided (`GID_STRIDE`): `_gid(slot, ei)`, `_owner_slot(gid)`,
`_resolved(gid)`, `_slot_exploits(slot)`, `_decode_exploit`. A reader that
wants "the player" must say which: `_eff_*(slot)`, `_damage_player(slot, amt)`,
`_die(slot)`, `_offer_cards(slot, …)`, `_block_payout(holder)`.

**Plurality census** (`test_plurality`): DEAD and ABSENT slots are skipped by
every rule. `_live_slots`, `_nearest_live(p)`, `_party_bounds`,
`_party_centroid`, `_next_live_cycle` (`_cycle_cursor`), `_leash(slot, p)`
(`SessionRules.LEASH` per axis against every other LIVE slot). Each enemy
picks `_enemy_target[i]` ONCE per tick in `_behave` from the per-tick
`_live_pos/_live_of` cache; spawn rings, the block anchor and stragglers use
the nearest LIVE slot; wards, ON_KILL/ON_FLIP/ON_HIT and lifesteal credit the
OWNING slot; the gate waits for every LIVE slot; `_botnet_cap()` is shared.
`view_slot` is presentation only (camera, culling, depth bands, spectating).

### Rendering / projection
`to_iso(p)` / `from_iso(s)` with `ISO_K = 0.82`; `_depth_sort` over
`DEPTH_BANDS = 192`; four `MultiMeshInstance2D` (enemy, proj, shard, botnet)
built by `_build_renderers` / `_make_mm`, refreshed by `_update_renderers`.
`_draw` adds ground quads, `_void_runs`, `_route_points`, orbiter trails, the
transient fx list and a facing tick on every drawn player's rim. Fx is ONE
list, `_fx` of `[kind, at, dir, radius, life, colour]` with
`enum FxKind { RIPPLE, DASH, BOLT, BEAM, WEDGE, PULSE, BLAST }` and
`FX_LIFE = 0.13`; `test_facing` pins the emit sites per kind. Projectiles get
glyph and colour per frame in `_update_renderers` (14 packet dot, 4 mine
plus, 15 orbiter ring); shards and botnet nodes are primed once.

### Player state per slot
`IFRAMES 0.5`; run-wide `alive won subnet level xp salvage pending_levels paused
user_paused hitstop_ticks`. `_sheet[slot]` derives from the descriptor's
counters, never from another peer's save. Effective stats:
`_eff_integrity(slot) _eff_armor _eff_defense _eff_clock_speed`,
each taking `_ward_max(key)` — wards fold as **MAX across exploits, never a sum**.
`player_shield` is absorb, not integrity: spent before armour and defence.
`_low_armed` latches ON_LOW_INTEGRITY to the **crossing** (`LOW_INTEGRITY_FRACTION
0.4`), not the state.

### Facing and firing
`player_facing[slot]` (world space, unit, default RIGHT) is set in
`_step2_integrate` from the APPLIED record: `aims[s]` when non-zero (the
right stick while deflected, or the mouse for `MOUSE_AIM_HOLD` 1.5 s after
it moved, sampled in `_poll_local_input`, sanitised and normalised by
`_sanitise_aim` on apply), else the movement when non-zero, held while the
slot stands still, reset to RIGHT by `_return`; simulation state (`SH`), so
the local slot's facing lags the device by the lockstep delay on purpose.
`aim_override` is the headless seam beside `input_override`. Players draw as
arrows along their facing.
`_step5_fire` → `_emit_vector(ei, r)` dispatches on `VectorKind`:
BROADCAST ring; PACKET along facing (a `homing` fused module binds a target
via `_pick_target(VIEW_RANGE)` and launches toward it); CHAIN `_pick_target`
then hops; BEAM a capsule along facing (`BEAM_HALF_WIDTH 22`, nearest
`pierce + 1` by (projection, index) selected into the `_beam_hits/_beam_keys`
scratch); CONE a wedge along facing (`CONE_HALF_ANGLE 0.785`); PULSE; MINE
centred `MINE_DROP 86` behind the owner, ring rotated by the facing vector,
every mine through `terrain.nearest_open` (`MINE_SPREAD 46`, `MINE_TRIGGER
46`, `MINE_LIFE 12`); ORBIT `ORBIT_RATE 2.4`. BEAM and CONE never return
early. Wards arm and the shield pool is granted at the TOP of `_emit_vector`;
a pool with `shield_rearm` grants only when `_shield_left[ei] <= 0`, then
re-arms it (per exploit, `SH`, aged with `_ward_left`).
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
`_gain_xp` / `_xp_for(lvl)` (`XP_SLOWDOWN 1.8`); offers are per-slot lockstep
INPUT state (`OfferKind {LEVEL, SEEDED, RANK_ONLY, FUSION}`, `_offer_seq/
_offer_open/_offer_queue`, rounds via `_round_open`/`pending_levels`,
`CHOICE_TIMEOUT_TICKS` deadlines); `choose_card / decline_card / choose_fusion /
decline_fusion` only STAGE `_local_choice`, applied when the tick consumes it.
`_recompile(slot=-1)`, `_bank_slot(slot, with_salvage)` (the `_banked`
watermark moves on every peer; only the local slot writes the save),
`_advance_subnet` (`SUBNET_CLEAR_HEAL 0.30`), `_hp_mult`, `_refresh_thresholds`,
`time_left`, `spawned_total`, `_die(slot)` → `_terminal(LOSS)` when none LIVE.
Collapse has an arena phase then a corridor phase
(`Terrain.CORRIDOR_COLLAPSE_TICKS`, `_corridor_collapse_ticks`).
Botnet defaults: `BOTNET_BASE_CAP 8`, `BOTNET_BASE_LIFETIME 12.0`,
`BOTNET_BASE_RATIO 0.6`.
`input_override` lets headless drivers steer the local slot through the same
poll a device uses; `external_drive` disables the engine physics callback so a
harness owns the tick.
