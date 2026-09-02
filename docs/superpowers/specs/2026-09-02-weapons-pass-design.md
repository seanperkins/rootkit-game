# Weapons pass: facing, eight vectors, distinct patterns

Date: 2026-09-02. Status: approved design, revised after panel review, awaiting plan.

## Why

Fourteen vector modules over eight kinds dilute the card pool: four of them
are BROADCAST, and two each are PACKET, CHAIN and PULSE, differing only in a
stat or a rider effect another module already carries. Every one fires at
the nearest target or radially, so nothing the player does with the stick
changes where a weapon goes, and every fire is drawn as either a line or a
ring. This pass gives the player a facing, cuts the pool to one vector per
kind, makes three of them fire forward and one behind, and gives every kind
its own shape on screen.

## Decisions

| Question | Decision |
|---|---|
| Facing model | Last non-zero movement direction. No new input, no wire change. |
| Pool | One vector per kind: eight vectors. |
| Directional set | spike, beam, packet fire forward; landmine drops behind; broadcast, chain, bounce, mirror stay position-based so every build can cover its back. |
| Starting build | Stays `packet + interval`. The opening minute is therefore a forward-only weapon: a player who stands still fires along the initial facing, and a player kiting away fires into open ground. Accepted on purpose — the enemy swarm CHASEs, so facing it is the skill the pass teaches, and the packet's muzzle dash shows where it fires. |
| Packet glyph | A period, not a plus. Mines keep the plus; orbiters get a small ring. |
| Accepted risk | Facing derived from movement is the decision most expensive to reverse: a separate aim input later means a new record field on the wire. Chosen with that known. |

## 1. Facing

`player_facing: PackedVector2Array`, one unit vector per slot in WORLD space,
allocated in `_allocate_slots` and initialised to `Vector2.RIGHT`. `_return`
(a reconnect return) resets it to `Vector2.RIGHT` after its ABSENT guard and
before the LIVE/DEAD branch, so a DEAD return that is later revived does not
carry stale facing. `_derive_roster` needs no reset: `_allocate_slots` has
just run.

Updated in `_step2_integrate`, per LIVE slot, from the applied record:
`if inputs[s].length_squared() > 0.0: player_facing[s] = inputs[s].normalized()`.
Standing still keeps the last value. DEAD and ABSENT slots are not touched.
Because it follows the APPLIED record, the local player's facing lags the
stick by `lockstep.delay` ticks. That is deliberate: a tick that led the
simulation would point where the wedge does not fire.

World space, not screen space: every existing angle test (the cone,
`_facing_scale` on enemies) is in world space, and a forward wedge must lean
the way the facing tick points.

Manifest: `player_facing` joins the per-slot `SH` row set (hashed and
snapshotted). `test_manifest`'s structural guard covers membership; a new
round-trip case (serialise, restore, compare the value) covers the restore.
It is derived from records alone, so `test_determinism_rules` holds.

Reconnect: every peer applies `_return` at the same tick (after consuming
R), and the host serialises its snapshot at R + 1 after its own `_roster_step`
has applied the return, so the returnee restores the post-return value. The
reset is identical on every machine.

Presentation: every drawn LIVE player (local and teammates, via
`player_draw_list`) gets a facing tick: a short line from the disc rim in the
facing direction, projected with `to_iso`, in the slot's hue. The comment
above the player draw ("the movement has no facing") is rewritten.

## 2. The eight vectors

`Module.VectorKind` is append-only and does not change. `Synth.fire_id(kind)`
therefore does not change and `test_audio_events` is unaffected.

| Module | Kind | Pattern |
|---|---|---|
| broadcast | BROADCAST | radial hit within `radius`, as today |
| packet | PACKET | straight shot along `player_facing[owner]`; no target pick; `split_count` shots fan around facing by `SPLIT_SPREAD`; pierce and travel as today |
| chain | CHAIN | `_pick_target` then hops, as today |
| beam | BEAM | a capsule from the owner along facing, length `radius`, half-width `BEAM_HALF_WIDTH := 22.0`; hits enemies inside it nearest first, up to `pierce + 1`; fires (and draws) even with no enemy in reach |
| spike | CONE | wedge along facing, `CONE_HALF_ANGLE`; fires (and draws) even with no enemy in reach |
| bounce | PULSE | radial knockback, as today |
| landmine | MINE | ring centre at `at - facing * MINE_DROP`, `MINE_DROP := 86.0` (`MINE_SPREAD + 40`); the ring is rotated so one vertex lies on the facing axis and the nearest mine sits exactly 40 behind the owner — rotated by the facing VECTOR as a complex multiply, not by `angle()` and `rotated()`, so no new transcendental enters the tick; EVERY mine position, single or ring, passes through `terrain.nearest_open` |
| mirror | ORBIT | orbiters, as today |

**No early returns for forward kinds.** Today BEAM and CONE `return` when
`_pick_target` finds nothing. Under facing they need no target, so the guard
goes; the comment above the match that justifies the ward/shield placement
("BEAM and CHAIN return early") is reworded for CHAIN alone.

**Packet and homing.** An ordinary packet calls no `_pick_target`, sets
`_proj_target = -1` and `_proj_target_gen = -1`. The one exception is a
resolved exploit with `homing > 0.0` (only fused modules have it, e.g.
zero_day): it binds a target at spawn exactly as today and launches TOWARD
that target, not along facing — a homing shot launched away from its target
at 900 units/s would spend 1.2 s and most of its travel coming about, which
is the kiting posture the module exists for. The existing re-acquire logic
is unchanged. This
removes the whole-grid packet query from the starting loadout, which the
perf gate's header comment names as the old worst case; see §5.

**Beam hit test.** Query the grid in a circle of radius `radius * 0.5 +
BEAM_HALF_WIDTH` around the capsule midpoint. The query filters on centre
distance, and the farthest centre the keep test can accept is a capsule end
corner at perpendicular offset `BEAM_HALF_WIDTH + ENEMY_RADIUS = 34`, at
distance `sqrt((radius / 2)^2 + 34^2)` from the midpoint. The circle covers it
whenever `radius / 2 + 22 >= sqrt((radius / 2)^2 + 34^2)`, i.e. `44 ×
(radius / 2) >= 34^2 - 22^2 = 672`, i.e. `radius >= 30.55`. Every beam in the
tables is above 31 (base 240, and rank only grows radius), so the circle is
always at least as large as the exact bound — at rank 5 the base beam's
circle is 262 against an exact requirement of 242.4. A comment beside the
constant records the floor. Keep enemies whose
perpendicular distance to the segment is within `BEAM_HALF_WIDTH +
ENEMY_RADIUS` and whose projection lies within `[0, radius]`. Take the
`pierce + 1` smallest by `(projection, enemy index)` — a total order, so equal
projections cannot depend on sort internals — by selection into two
preallocated packed arrays (`_beam_hits: PackedInt32Array`, `_beam_keys:
PackedFloat32Array`, each sized `_buf.size()` = 1024, NOT_IN_MANIFEST
scratch). Selection is O(n × k); `pierce` is rank-scaled, so k is up to 16
for a rank-5 base beam and 56 for core_dump with bitmask, and a wall pile of
two hundred enemies in the capsule costs about ten thousand comparisons at
the worst k, inside budget, with nothing allocated in the tick. The `radius >= 31` floor is
asserted by `test_facing` over every BEAM module and fused BEAM recipe in the
tables, so a future radius nerf trips a test rather than a comment.

**Targeting.** `Module.Targeting` is consulted today by BEAM, CONE, CHAIN and
PACKET. After the pass only CHAIN and the homing re-acquire read it. The
fused modules `hollow_point`, `railgun` and `core_dump` drop their
`STRONGEST` declaration (they aim by facing now); `zero_day` keeps it through
homing, `arp_storm` keeps `FARTHEST` through CHAIN. The comment in
`module.gd` that lists the consulting kinds is updated.

Removed modules: `flood`, `snipe`, `cascade`, `throttle`, `airgap`. Their
riders already exist: throttle's slow is `tarpit`, airgap's ward is `harden`.

**checksum becomes a PAYLOAD** `{shield: 26.0, shield_rearm: 2.6}`, no
tags, still locked, still `[flips, 80]` in `MILESTONES`. Shield has two
sources: this module and the fused `redundancy` (60.0). As a vector the
checksum shield refreshed once per its own 2.6 s cooldown; as a payload it
would refresh on the host vector's cadence — 0.42 s on the tightest authored
row (syn_flood), and the compiler's cadence floor is 12% of the vector's base
cooldown, 0.06 s on a packet — a refill rate six to forty times higher with
the same number. So a new stat, `shield_rearm`
(appended to `Module.STAT_KEYS`, folded by MAX like every defensive stat,
seconds, and UNRANKED in `Compiler._fold` exactly as `ward_duration` is —
rank buys shield magnitude, never uptime, so a rank-5 checksum rearms in
2.6 s, not 13; `haste` scaled the old vector's cooldown and does not touch
the rearm, accepted), gates the grant: `_emit_vector` grants the pool only when
`r.shield_rearm <= 0.0` or `_shield_left[ei] <= 0.0`, then arms
`_shield_left[ei] = r.shield_rearm`. `_shield_left` is per exploit, `SH` in
the manifest beside `_ward_left`, aged in `_step2_integrate` with it.
`redundancy` declares no `shield_rearm`, so its per-fire grant at 0.85 s is
untouched — the rearm rebalances nothing that ships today. One interaction is
stated rather than hidden: stats fold per row, so a `checksum` payload placed
on a `redundancy` head folds to `shield 60, shield_rearm 2.6` and that row
refills its 60 pool on the rearm instead of every fire. The card adds no
magnitude there and slows the refill; the manual note for checksum says so,
and `test_facing` pins the row's behaviour so it is a known trade, not a
surprise. The magnitude
stays 26 at rank 1. `ResolvedExploit` gains `var shield_rearm: float = 0.0`
(every key has a field, or `_fold` writes into nothing) and its `equals()`
comparator, which enumerates fields by hand and today skips `shield` as
well, compares both `shield` and `shield_rearm` — pinned by an equality case
per field in the build suite so two exploits differing only in one of them
are not reported equal. `test_build.gd:322` / `:330` (the
`STAT_KEYS` size and zero-default pins) move from 27 / 26 to 28 / 27. The rearm earns its state: the grant is `maxf(current,
pool)`, a refill to the cap, and the pool drains only under damage — which is
exactly when a shield matters — so refilling on every 0.42 s fire instead of
every 2.6 s is a sustained-damage absorb rate about six times higher, not a
rounding difference.

`ModuleTable.LOCKED` loses `snipe`, `cascade`, `airgap`. `SaveGame.MILESTONES`
loses the same three rows and changes nothing else: unlocks derive from
counters, so raising a surviving milestone would re-lock it for any profile
between the old and new number. The kills ladder therefore tops out at
landmine's 550 instead of airgap's 900; accepted. Module count: 30 (8
vectors, 7 triggers, 15 payloads); unlocked at start 19 (5 / 3 / 11). The
header comment in `module_table.gd` carries those numbers and is updated.

Old saves: `SaveGame._sanitise` drops unknown ids from `unlocked`, and
`unlocked_modules_from` derives from counters with a table check, so a
profile that had unlocked a removed module loads cleanly. A checked property,
not luck.

## 3. Recipes

Seven recipes name a removed module. Each is rehomed on its kind's survivor;
the fused module keeps its identity, riders and cooldown, and its damage is
re-derived below:

| Fused | Was | Becomes |
|---|---|---|
| dragnet | flood + interval + tarpit | broadcast + interval + tarpit |
| zero_day | snipe + on_kill + bitmask | packet + on_kill + bitmask |
| botnet_cascade | cascade + on_flip + worm | chain + on_flip + worm |
| tar_siphon | throttle + interval + keylog | broadcast + interval + keylog |
| panic_room | airgap + on_damage_taken + sandbox | bounce + on_damage_taken + sandbox |
| redundancy | checksum + on_kill + botnet_expand | broadcast + on_kill + **checksum** |
| last_resort | flood + on_low_integrity + sandbox | broadcast + on_low_integrity + sandbox |

`redundancy` takes `checksum` as its payload so the shield ingredient stays
on the shield recipe and the coverage invariant ("every vector, trigger and
payload appears in at least one recipe") holds with 15 payloads;
`botnet_expand` stays covered by `hivemind`. Fused stats are authored in the
recipe (`_f` takes an explicit stats dictionary), so `redundancy` keeps its
`shield: 60.0` regardless.

**Fused damage is derived, not kept.** The recipe table's rule (and
`test_fusion`'s `fusing_is_never_a_downgrade`) is that a fused module's
rank-1 output must reach at least 98% of the triple it eats, the triple
measured at rank 5 with its cadence floored at the vector's base cooldown.
The removed vectors were the weak ones; their survivors are stronger, so the
seven rehomed triples out-fire the authored fused numbers and every one of
them fails the check as-is. Re-derived with the real `Compiler.build` under
that rule and snapped up to 0.5:

| Fused | Rank-5 triple DPS, new | Rank-1 damage today | Rank-1 damage now |
|---|---|---|---|
| dragnet | 20.59 | 7.0 | 21.0 |
| zero_day | 90.00 | 59.5 | 94.5 |
| botnet_cascade | 50.00 | 9.5 (+14.5 corruption, kept) | 13.0 |
| tar_siphon | 20.59 | 6.0 | 19.0 |
| panic_room | 45.45 | 26.0 | 41.0 |
| redundancy | 38.24 | 10.0 | 32.5 |
| last_resort | 55.88 | 34.0 | 67.5 |

Cooldowns, radii, riders and every other stat stay as authored. With these
numbers the rank-5 fused module still beats its triple about five times
over, so `test_fusion`'s "beats its triple several times over" check holds.
A design consequence, stated: five recipes now sit on `broadcast`, so five
fused modules must each out-fire a rank-5 broadcast-plus-trigger; that
pushes the ring-family fused modules up the `SpawnDirector.hp_mult` curve,
which is the intended cost of one vector per kind. These seven numbers are
the third balance change in scope.

Consequences in `test_fusion`: the three coverage assertions change from
literal counts (7 / 14 / 14) to set comparisons against `ModuleTable.all()`,
so the next table edit cannot orphan a card quietly; the near-miss control
`packet + on_kill + bitmask` is now zero_day's own triple, so the "one module
off matches nothing" case is re-chosen against the new table (e.g.
`packet + on_kill + overclock`, which no recipe names); `near_miss` reporting
with five broadcast recipes gets an assertion that pins the property the run
depends on — `near_miss` on an `X + interval` row returns the payload of the
FIRST single-miss recipe in table order, so a reorder of the table is caught.
`test_fusion.gd:5` pins `EXPECTED_CHECKS`; it moves with the checks added
(`test_blocks.gd:5` and `test_build.gd:7` carry the same pin and are checked
against their final counts). No two recipes may share a triple;
`test_fusion`'s twenty-distinct-triples check enforces it — there is no
recipe validator function, only that suite.

**The keep-row rule.** Five fixtures pair the zero_day triple with a
`packet + interval` keep row (`test_fusion.gd:292`, `test_blocks.gd:137` and
`:178`, `test_cards_keyboard.gd:358` and `:386`, `test_offers.gd:214` with
`:220`). A mechanical `snipe → packet` swap would put `packet` in two vector
slots, which `Loadout.legal_targets` forbids (one id, one slot), and would
turn `test_fusion.gd:312-313` ("snipe is placeable again") into a vacuous
pass through the rank-up branch. So at all five sites the KEEP row becomes
`broadcast + interval`, the fusion row takes `packet`, and the placeability
assertion asks whether `packet` can be placed into an EMPTY slot — not
merely somewhere — with `broadcast` holding the other row. The keep-row
change moves one more expectation: `test_blocks.gd:154-157` asserts the
targeted module on the keep row is `fork_bomb`, one module short of
frag_packet (`packet + interval + fork_bomb`); with the keep row on
`broadcast + interval` the first single-miss recipe is pulse_train and the
answer is `overclock`. The assertion and its comment change to say so.

## 4. Animations

One presentation list replaces `_fx_line` and `_fx_ring`:
`_fx: Array` of `[kind, at, dir, radius, life, colour]` — `dir` is a unit
facing with `radius` the length for DASH, BEAM and WEDGE, and the full link
OFFSET (`to - from`) for BOLT; the declaration comment says so — with
`enum FxKind { RIPPLE, DASH, BOLT, BEAM, WEDGE, PULSE, BLAST }` — seven kinds,
one per shape; there is no generic ring, because every ring emitter maps to
one of these and a kind nothing emits would exist only to satisfy its own
test.
`_draw` dispatches on the kind; `_age_fx` ages every entry on the unscaled
frame delta as today. All of it is NOT_IN_MANIFEST presentation (`_fx`
added, `_fx_line`/`_fx_ring` removed from that list). The invariant: every
kind in the table appends one entry per fire, except CHAIN, which appends one
BOLT per resolved link (the first strike and each hop), exactly as it appends
one line per link today. MINE and ORBIT fires append nothing — they show
through the glyphs and the trail — and BLAST is the detonation, which
`_detonate` also emits for a `blast_radius` packet. The audio grep keys on `feel.emit`, not on `_fx`
appends, so it is unaffected either way. Nothing is ever appended from
`_draw`.

| Kind | Fire | Shape |
|---|---|---|
| RIPPLE | broadcast | the ring, plus a thinner ring lagging it by a third of the life |
| DASH | packet | a short bright dash along facing at the muzzle |
| BOLT | chain, per hop | a polyline from `at` to `at + dir` with sine jitter by segment index, no RNG |
| BEAM | beam | a translucent core `BEAM_HALF_WIDTH` wide with a thin bright edge, narrowing over its life |
| WEDGE | spike | a filled translucent sector of `CONE_HALF_ANGLE` and `radius`, flashing then fading |
| PULSE | bounce | the ring plus eight radial spokes flung outward |
| BLAST | mine detonation | a ring plus a scatter of short lines |

Three ring emitters today are not weapon fires and keep their kinds too: a
mini-boss or ICE arrival flash (the ring at the arrival site) becomes a
RIPPLE, kernel_panic's pulse (the 700-radius ring) a PULSE, and `_detonate`
already is the BLAST. The structural check counts emit SITES per kind against a pinned table (two
RIPPLE sites, two PULSE sites, one BLAST, and so on), so deleting one of
these non-fire emitters fails the check rather than passing it silently.

The fx bound comment on the declaration ("3 exploits x 4 fires") is
rewritten for the new shape and stated as what it is — an estimate for the
reader, not a capacity the list enforces (`_fx` is an unbounded Array aged by
life): per LIVE slot, `3 exploits × max(FIRE_BUDGET, BURST_MAX) × (max
chain_count + 1)` entries live at once, plus the arrival and pulse rings.

**Orbiter trails** are not list entries: `_draw` draws a short fading arc
behind each live orbiter, anchored at the owner's `player_render_pos` and
drawn backwards from the orbiter's interpolated render position (`_rp`), so
the trail and the glyph agree at every frame fraction; the sim-side
`_orbit_phase` and `player_pos` are one tick ahead of what is drawn and
would detach at low frame rates. No per-frame allocation.
The legacy loop in `_draw` that today circles every orbiter and mine with
`draw_circle` ("Orbiters and mines share the projectile pool…") is replaced
by that trail: the glyphs below now carry the mine and orbiter looks, so the
old loop would draw them twice.

**Projectile glyphs.** Today the whole projectile multimesh is primed once
with glyph 4 (the plus) and one colour, and only transforms are written per
frame — so mines and orbiters share the packet's glyph. Now
`_update_renderers` writes `set_instance_custom_data` and
`set_instance_color` for every visible projectile each frame (bounded by
`MAX_PROJECTILES` 400): plain packets get a new glyph index 14, a small
filled dot appended to the shader; mines keep glyph 4, the plus; orbiters
get glyph 15, a small ring. The kind is read from `_mine_left[i] > 0.0` /
`_orbit_left[i] > 0.0`. Armed mines blink through that per-frame colour on a
slow pulse from the display clock, which `_draw` already uses for the boss
ring. The glyph index is rewritten every frame even though it is fixed for a
projectile's life, on purpose: spawn happens inside the tick, which may not
touch a renderer node, and `_update_renderers` in `_process` is the only
legal writer; slots recycle, so a once-only stamp would need its own
per-instance memory to know when to restamp. Up to eight hundred setter
calls a frame is the cheaper carry, and the comment on
`_prime_constant_instances` that says projectiles are written once is
rewritten to say shards and botnet nodes alone are, and the projectile
prime call itself is dropped as dead priming. No enemy row uses 4, 14 or 15. The shader comment on the probe glyph
("distinct from the packet plus") is updated.

## 5. Testing and the sweep

New suite `tests/test_facing.gd` (added to `SUITES` in `tools/run_tests.sh`;
`CLAUDE.md` goes to 53 suites):

- a diagonal record sets a unit world-space facing; a zero record keeps it
- `player_facing` is in `STATE_FIELDS` with `SH`; serialise → restore
  preserves its value; a two-peer harness run of 600 ticks with turning
  movement still agrees
- packet spawns along facing with `_proj_target == -1`; a fused homing
  packet binds one
- beam hits an enemy inside its capsule at the far end and misses one beside
  it and one behind; an enemy at the far END CORNER, at full perpendicular
  offset (34 from the axis at projection `radius`), is hit — the case the
  query circle is sized for; two enemies at equal projection hit in index
  order
- spike hits inside the wedge along facing and misses behind
- two mine cases: on open ground a single mine lands exactly `MINE_DROP`
  behind the owner and a three-mine ring's nearest vertex exactly `MINE_DROP
  - MINE_SPREAD` behind; and with a wall placed where a ring vertex would
  fall, every mine still lands on open ground (`nearest_open` moves that one,
  so the exact distance is not asserted in this case)
- the checksum payload grants once per its `shield_rearm`, not per fire, at
  rank 1 and at rank 5 alike (the rearm does not scale); a bare `redundancy`
  row still grants on every fire; a `redundancy` row carrying `checksum`
  refills its 60 pool on the 2.6 s rearm
- `_return` resets facing: a slot parked while facing left returns facing
  right, on every peer
- every BEAM module and fused BEAM recipe has `radius >= 31` — a TABLE
  invariant; rank and `VECTOR_RADIUS_RANK` only grow radius, and a hostile
  `reach` in `save.json` below `31/240` is outside this pass
- every `FxKind` that an emit site appends has a draw arm (structural grep
  of emit sites against `_draw`; a kind appended but never drawn is an
  invisible fire, and nothing else would catch it because `_fx` appends are
  not `feel.emit` calls)

Existing suites, enumerated (line numbers as of this revision):

| File | Change |
|---|---|
| `tests/test_build.gd:7, :70-71, :308, :318-322, :330, :395-396, :401-402` | the `EXPECTED_CHECKS` pin if the count moves, the stale "18 modules" label and count 35 → 30, unlocked 21 → 19, the `STAT_KEYS` pins 27 / 26 → 28 / 27 with their explanatory comment, the five removed ids leave the id list at `:395-396` and "seventeen" at `:401` becomes twelve |
| `scripts/build/resolved_exploit.gd` | `var shield_rearm: float = 0.0` |
| `tests/test_fusion.gd:5`, `tests/test_blocks.gd:5, :154-157` | `EXPECTED_CHECKS` moves with the added checks; the keep row's near-miss expectation becomes `overclock` |
| `tests/test_meta.gd:90` | fresh save unlocks 21 → 19 |
| `tests/test_fusion.gd:266-268, :272, :276-278, :282, :292, :312` | coverage as set comparisons, zero_day on packet, new near-miss control |
| `tests/test_offers.gd:214`, `tests/test_cards_keyboard.gd:358, :386`, `tests/test_blocks.gd:137, :178` | removed ids move to survivors |
| `tests/test_run.gd:193-194, :204`, `tests/test_determinism_rules.gd:86-87, :99` | seed `_fx` instead of `_fx_ring`, and read the life at index 4, not 2, at both reads in each suite |
| `tools/shot_fx.gd` | rewritten against `_fx`. A loadout holds `MAX_EXPLOITS` = 3 rows, so eight vectors need a THREE-slot session (the multiplayer harness pattern): slot 0 packet/broadcast/chain, slot 1 beam/spike/bounce, slot 2 landmine/mirror, the three players spread across the frame so the shapes do not overlap; one frame then shows every shape, the three glyphs and three facing ticks |
| `tests/perf_milestone0.gd` | no row is removed: packet stays the starter row on every slot (it is still the shipped build, and its whole-grid query going away makes the gate lighter, not heavier — the removed query walked a 620-radius circle; the largest beam query ON THE GATE is the rank-5 base beam's — radius 480 (`240 × (1 + 0.25 × 4)`), so a circle of `480 × 0.5 + 22 = 262` — about five times fewer cells; a rank-5 core_dump in play is larger still, 482). `MAX_EXPLOITS` is 3, so `beam` at rank 5 with pierce SWAPS in on slots 2 and 3 — displacing the BROADCAST aura there (the beam row inherits that row's `on_hit` trigger; an event row fires at most once per cooldown, so the trigger does not multiply fires — and it keeps firing at all because the same slot's HOMING row lands reliable hits, which is the lower bound the event rows rest on, not the blind-aimed packet), not the homing fused packet, because the gate's own header argues the homing rows are what let it fail at all, so all four homers stay. Costed honestly: the beam's 262-radius query resolves at most `pierce + 1` hits, while the rank-5 aura it displaces adjudicated everything inside 180 at the enemy cap, so the swap is probably LIGHTER per slot; the aura stays on slots 0 and 1 and in the solo stress block, whose rows do not change, and the load pin below is what catches a lighter run. All three pinned slots (1, 2 and 3) turn for free: their positions are force-written every tick before the step, so instead of `Vector2.ZERO` each submits a slowly rotating unit vector (one full turn every 600 ticks), which sets facing from the record while the drift it would cause is erased next tick. Side effects, accepted and enumerated in the fixture: `player_vel` on those slots is non-zero, which `_flank` (arc) and `_fire_hostile` (shot lead) both read; those slots now take the movement branch (`_leash` and `terrain.slide`) inside the timed region; and because the pinned slots sit on the edges of the leash box, `_leash` clamps away the outward half of each rotating vector — harmless, since facing is set from the RECORD, not the realised displacement, and the fixture comment says so before someone "fixes" it. The autopilot `_kite` FLEES, and facing is the last non-zero record, so left alone every forward weapon would fire away from the swarm, the run would die early and the gate would shrink — the trap the file's own header names. A one-tick nudge cannot fix that (the next flee record overwrites facing), and a kite that reacts only at contact range dies early, so `_kite` on slot 0 gets HYSTERESIS and holds facing with zero records. Its CLEARED branch (walk to the open gate) stays FIRST and unconditional, or a cleared subnet with nothing inside 120 would hold forever and the run could never advance. Otherwise: while the nearest enemy is inside 120 units it flees exactly as today (the flee sum over enemies within 190, the centre pull, `_around_walls`) until the nearest enemy is beyond 190; on the first tick after that burst, and every 37 ticks while holding, it moves one tick toward the swarm's MASS — the negative of the flee sum it already computes, falling back to the nearest enemy, and zero when there are none — because at cap the nearest single enemy can be a straggler off to one side while the mass sits behind; the nudge does NOT pass through `_around_walls` (it is a facing intent, and its 3.67-unit step is rejected by `terrain.slide` against rock anyway, whereas a wall-deflected nudge would face away from the swarm); every other tick it returns `Vector2.ZERO`, which keeps facing. Slot 0 today sits at a CORNER of the party's leash box (`PARTY_OFFSETS` put every pinned slot at +4000 on an axis), so the leash forbids it any movement toward negative x or y and a flee into that quadrant never ends the burst; the fixture moves slot 0 to the CENTRE of the box — pinned offsets (+2000, +2000), (−2000, +2000), (+2000, −2000) still span the full 4000 on both axes — so it can flee in every direction. The duty cycle, stated in the fixture comment: facing points at the swarm from each nudge until the next flee burst begins, and points away for the burst itself. The kite keeps explicit state across ticks — a `fleeing` flag and a cadence counter, plain fixture variables reset at the start of `_real_run` — since a stateless function cannot tell "inside 120" from "not yet back out past 190", nor the first tick after a burst from the rest. Against the fastest enemy (the tracer, a FLANKER at 124 units a second) the burst opens 70 units in about 44 ticks and the hold lasts about 34; against a CHASE daemon (74) about 29 and 57. So facing points at the swarm for roughly two-fifths to two-thirds of each cycle (34 of 78 ticks against a tracer, 57 of 86 against a daemon) rather than one tick in thirty, and the reaction distance is 120 (a 97-unit buffer above the 23-unit contact distance) against today's 190 — smaller, and still ample, since the player outruns the fastest enemy by 96 units a second. Slot 0's survival rests on its aura and its homing row (ON_HIT fires for any hit the slot lands, so the homer keeps the aura firing); the forward packet is drain coverage, which the load pin measures. And the coverage pin is an ASSERTION, not a print. Today the fixture cannot even SEE slot 0 die: its loop runs while `alive`, `alive` is true whenever any slot is LIVE, and slots 1 to 3 are force-LIVE every tick — so a dead kite is propped up for the rest of the run by three immortal stationary teammates being mobbed, and the measured "timeout at 24000" on this branch is compatible with slot 0 having died at any tick. The outcome is therefore defined on SLOT 0: the loop ends when `slot_state[0]` leaves LIVE (that tick is the death), on a win, or at the 24000-tick cap. The existing print, which says "died at 400s" for a cap reached alive and prints the constant `MAX_ENEMIES` as "peak enemies", is fixed. A timeout baseline makes an outcome pin nearly vacuous, so the pin records THREE things before the change: the terminal state with its end TICK (an integer, not `t * DT` seconds), and three LOAD statistics that move in different directions — the mean of `enemies.count` over the run's ticks (a lighter field lowers it; a weaker build raises it), the mean of hits adjudicated per tick, `queue.count` summed after each tick (a weaker or blind-aimed build lowers it), and total kills across all slots per tick (falls when forward weapons miss and when slot 0 is dead) — plus, recorded but not pinned, the fraction of ticks spent at `MAX_ENEMIES`, so the reader can see whether the enemy mean is saturated. After the change the gate FAILS — checked in `_initialize` before the contention branch, the way `_gate_drops` is, so a loaded machine cannot turn a coverage regression into PASS-by-INCONCLUSIVE — unless the run reaches at least the baseline outcome (a timeout baseline requires the cap or a win; a death baseline at tick N requires surviving at least 90% of N, declared slack for a chaotic but deterministic system; a win baseline requires a win) AND all three load means are at least 97% of the baseline's, a shorter winning run included. The run is seeded and has no run-to-run variance, so that 3% is not a noise band: it is a declared allowance for the behavioural drift this pass causes (a new kite, five modules gone, seven damages re-derived), and it is set below the gate's own 5.4% p95 headroom on purpose — a guardrail must be tighter than the margin it guards. A run that survives the full 400 s with a thinner field, or with fewer hits, is the lighter gate the file's own header warns about, and the outcome pin alone would pass it. Attribution is kept clean by measuring THREE points: the old fixture on the old tree (today's numbers, for the header), the NEW fixture on the old tree (the hysteresis kite and rotating records are movement records only and run unchanged there) — which is the pin's baseline — and the new fixture on the new tree. The order is fixed: pin from the new-fixture-old-tree run first, pass the new tree against that pin, and only then may the constants move — the outcome only upward, and each load baseline only upward or, downward, with a written reason beside it, so no sequence of changes can ratchet the gate down unnoticed; a fall below any floor needs a stated reason in the plan, never a re-pin. Both pre-change and post-change values live in the gate's comment so the delta stays visible. If the hysteresis kite dies before the cap on this branch — standing still lets ranged shots connect that today's always-moving kite dodges, and a ring closing from every bearing can cancel the flee sum and strand it — the implementer widens the band (`KITE_FLEE_IN` toward 190; a 150/190 band first) and, if that is not enough, also enters the flee state whenever an enemy within 300 units is winding up or dashing (a sentinel's 239-unit dash from 260 out lands 21 units short of a stationary target; probes lead a stationary target exactly), until the run reaches the cap again, and records the values used. And if the gate comes back HEAVIER — three blind-aimed slots mean a fuller field, and the headroom is 5.4% — that is coverage, not regression: the response is to profile and optimise (the beam selection at k up to 56 first), never to thin the fixture or lower the 11 ms budget. Measured headroom today: p95 9.09 ms against a 9.61 ms scaled budget, about five percent, which is why the swap is costed above. The header comment about the packet query is rewritten |
| `codemaps/` | regenerated with the codemap skill after the change: `data.md` names the removed rows and milestones today |

**Suites that run the default `packet + interval` build with a stationary
player** (`input_override = Vector2.ZERO`; 23 suites plus the perf gate).
The default facing is `Vector2.RIGHT`, so a fixture whose enemies sit at +X
is unaffected; one whose enemies surround the player or sit elsewhere, and
which asserts kills, hits, fires or shard flow, is at risk. Classified by
whether the suite spawns enemies and asserts on kills/hits:

| Class | Suites | Action |
|---|---|---|
| (a) no enemy spawn, or no kill/hit/fire assertion | `test_behaviour` (spawns at +X, asserts AI phases and velocities), `test_blocks`, `test_flow`, `test_fusion`, `test_fusion_run` (its `:107` enemy is at +X), `test_hud`, `test_input`, `test_interpolation`, `test_multipliers`, `test_offers`, `test_player_sheet`, `test_snapshot_hostile`, `test_wards`, `test_worms` | none; they run in the gate anyway |
| (b) a positive assertion that depends on the default packet connecting | `test_arrivals`, `test_corruption` (3600 stationary ticks with `corrupt` as the only payload and a `flips > 0` verdict), `test_dispatch`, `test_drain`, `test_manifest`, `test_plurality`, `test_run`, `test_travel`, `test_triggers` | judge each by ASSERTION POLARITY, not by whether it passes: a negative assertion (no hit, no proc, integrity untouched) passes vacuously once the packet fires into empty ground. Where a positive assertion depended on the default packet connecting, set a facing toward the fixture's enemies for one tick or move them to +X. Already confirmed safe by reading: `test_dispatch` (+X), `test_travel:129` (+X), `test_arrivals` (calls `_pick_target` directly). Four are judged at implementation time under the polarity rule, and the plan step says so: `test_drain`, `test_manifest`, `test_plurality`, `test_run`. Known to need the fix: `test_triggers:49` and `:88` (a full ring around the player), and `test_corruption`, whose enemies come from the live director at positions that need not lie at +X — it runs warm-up ticks until enemies exist, then one tick of `input_override` toward the nearest one, then its stationary run; whether one fixed ray flips a daemon (threshold 10) within 3600 ticks is settled by running the suite, and if it does not, the fixture places its enemies deterministically at +X instead |

`test_effects` sets no `input_override` and spawns at +X of the origin; it
is unaffected and was wrongly listed before. `test_wards.gd:77-80` has a
comment ("a BEAM with nothing to shoot still hardens" because of the early
return) that goes stale; its assertion at `:86` still holds and the comment
is rewritten.

The `grep -w flood` hits in test_terrain and test_flow, and the word
"cascade" in test_minibosses, test_dispatch and test_drain, are English, not
module ids.

Docs and comments: `README.md` module rows and the zero_day example;
`tools/build_manual.py` `MODULE_NOTES` (five removed entries deleted; packet,
beam, spike, landmine and checksum rewritten — the generator only fails on a
MISSING note, so stale prose would ship silently) and its `STAT_LABEL` table
(a `shield_rearm` label, or the checksum row prints the raw key); `module_table.gd` header
counts; `module.gd` targeting comment; `perf_milestone0.gd` header;
`glyph.gdshader` probe comment; and five run.gd comments: the ward/shield
placement ("BEAM and CHAIN return early"), the player draw ("the movement
has no facing"), the single-mine `nearest_open` note ("the owner's position
is always walkable"), the `_prime_constant_instances` note, and the fx bound.

Manifest bookkeeping, in full: `player_facing` and `_shield_left` join
`STATE_FIELDS` (`SH`); `_fx`, `_beam_hits` and `_beam_keys` join
`NOT_IN_MANIFEST`; `_fx_line` and `_fx_ring` leave it. `test_manifest` fails
on a var in neither list, so all five must land together.

Gates: `tools/run_tests.sh` (all suites and the perf gate),
`tools/determinism_probe.gd`. The manual regenerates after the notes change.

Windowed, for the user: `tools/shot_fx.gd` and a real run to judge the eight
shapes, the three glyphs and the facing tick.

## Out of scope

A separate aim input; new vector kinds; rebalancing beyond removing rows and
the balance changes named here (the checksum rearm, which leaves
`redundancy` alone, and the seven re-derived fused damages); milestone
changes beyond the three deletions; enemy-facing changes (`_facing_scale`
stays as it is).
