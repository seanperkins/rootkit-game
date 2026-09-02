# Weapons pass: facing, eight vectors, distinct patterns

Date: 2026-09-02. Status: approved design, awaiting plan.

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
| Packet glyph | A period, not a plus. |

## 1. Facing

`player_facing: PackedVector2Array`, one unit vector per slot in WORLD space,
allocated in `_allocate_slots`, initialised to `Vector2.RIGHT`, reset to
`Vector2.RIGHT` by `_derive_roster` and by `_return` (a reconnect return).

Updated in `_step2_integrate`, per LIVE slot, from the applied record:
`if inputs[s].length_squared() > 0.0: player_facing[s] = inputs[s].normalized()`.
Standing still keeps the last value. DEAD and ABSENT slots are not touched.

World space, not screen space: every existing angle test (the cone,
`_facing_scale` on enemies) is in world space, and a forward wedge must lean
the way the facing tick points.

Manifest: `player_facing` joins the per-slot `SH` row set (hashed and
snapshotted). `test_manifest`'s structural guard covers it without a new
entry. It is derived from records alone, so `test_determinism_rules` holds.

Presentation: every drawn LIVE player (local and teammates, via
`player_draw_list`) gets a facing tick: a short line from the disc rim in the
facing direction, projected with `to_iso`, in the slot's hue.

## 2. The eight vectors

`Module.VectorKind` is append-only and does not change. `Synth.fire_id(kind)`
therefore does not change and `test_audio_events` is unaffected.

| Module | Kind | Pattern |
|---|---|---|
| broadcast | BROADCAST | radial hit within `radius`, as today |
| packet | PACKET | straight shot along `player_facing[owner]`; no target pick; `split_count` shots fan around facing by `SPLIT_SPREAD`; pierce and travel as today |
| chain | CHAIN | `_pick_target` then hops, as today |
| beam | BEAM | a capsule from the owner along facing, length `radius`, half-width `BEAM_HALF_WIDTH := 22.0`; hits every enemy whose centre is within the capsule, nearest first, up to `pierce + 1` |
| spike | CONE | wedge along facing, `CONE_HALF_ANGLE`, as today but with facing instead of a picked target |
| bounce | PULSE | radial knockback, as today |
| landmine | MINE | dropped at `terrain.nearest_open(at - facing * MINE_DROP)`, `MINE_DROP := 40.0`; a ring of `split_count` mines is centred on that point |
| mirror | ORBIT | orbiters, as today |

**Packet and homing.** A packet picks no target and sets `_proj_target = -1`.
The one exception is a resolved exploit with `homing > 0.0` (only fused
modules have it, e.g. zero_day): it binds a target at spawn exactly as today
and launches along facing, then curves. The existing re-acquire logic is
unchanged.

**Beam hit test.** Query the grid in a circle of radius `radius * 0.5 +
BEAM_HALF_WIDTH` around the capsule midpoint, then keep enemies whose
perpendicular distance to the segment is within `BEAM_HALF_WIDTH + enemy
radius` and whose projection lies within `[0, radius]`. Sort the survivors by
projection so pierce consumes the nearest first. This replaces today's
half-radius circle, which hit enemies beside the beam and missed ones at its
end.

Removed modules: `flood`, `snipe`, `cascade`, `throttle`, `airgap`. Their
riders already exist: throttle's slow is `tarpit`, airgap's ward is `harden`.

`checksum` becomes a PAYLOAD: `{shield: 26.0}`, no tags, still locked, still
`[flips, 80]` in `MILESTONES`. Nothing else grants shield.

`ModuleTable.LOCKED` loses `snipe`, `cascade`, `airgap`. `SaveGame.MILESTONES`
loses the same three rows. Module count: 30 (8 vectors, 7 triggers, 15
payloads).

## 3. Recipes

Seven recipes name a removed module. Each is rehomed on its kind's survivor
with the fused result unchanged:

| Fused | Was | Becomes |
|---|---|---|
| dragnet | flood + interval + tarpit | broadcast + interval + tarpit |
| zero_day | snipe + on_kill + bitmask | packet + on_kill + bitmask |
| botnet_cascade | cascade + on_flip + worm | chain + on_flip + worm |
| tar_siphon | throttle + interval + keylog | broadcast + interval + keylog |
| panic_room | airgap + on_damage_taken + sandbox | bounce + on_damage_taken + sandbox |
| redundancy | checksum + on_kill + botnet_expand | broadcast + on_kill + botnet_expand |
| last_resort | flood + on_low_integrity + sandbox | broadcast + on_low_integrity + sandbox |

No two recipes may share a triple; the recipe validator and `test_fusion`
enforce it. `redundancy` keeps its `shield` stat on the fused module, so the
shield line survives the checksum change.

## 4. Animations

One presentation list replaces `_fx_line` and `_fx_ring`:
`_fx: Array` of `[kind, at, dir, radius, life, colour]` with
`enum FxKind { RING, RIPPLE, DASH, BOLT, BEAM, WEDGE, PULSE, BLAST, TRAIL }`.
`_draw` dispatches on the kind; `_age_fx` ages every entry on the unscaled
frame delta as today. All of it is NOT_IN_MANIFEST presentation. Emit sites
append exactly one entry per fire, so the audio grep is unaffected.

| Kind | Fire | Shape |
|---|---|---|
| RIPPLE | broadcast | the ring, plus a thinner ring lagging it by a third of the life |
| DASH | packet | a short bright dash along facing at the muzzle |
| BOLT | chain, per hop | a polyline from `at` to `at + dir` with sine jitter by segment index, no RNG |
| BEAM | beam | a translucent core `BEAM_HALF_WIDTH` wide with a thin bright edge, narrowing over its life |
| WEDGE | spike | a filled translucent sector of `CONE_HALF_ANGLE` and `radius`, flashing then fading |
| PULSE | bounce | the ring plus eight radial spokes flung outward |
| BLAST | mine detonation | a ring plus a scatter of short lines |
| TRAIL | orbiters, per drawn frame | a short fading arc behind each orbiter along its orbit |
| RING | generic | the plain ring, for sites that only need one |

Armed mines blink: the projectile renderer scales the glyph's brightness on a
slow pulse from the display clock, which `_draw` already uses for the boss
ring.

**Packet glyph.** The projectile multimesh is primed with glyph index 4 in
`shaders/glyph.gdshader`, today a plus. That branch becomes a small filled
dot. No enemy row uses glyph 4, so the enemy table is untouched.

## 5. Testing

New suite `tests/test_facing.gd`:

- a diagonal record sets a unit world-space facing; a zero record keeps it
- `player_facing` is in `STATE_FIELDS` with `SH`; a two-peer harness run of
  600 ticks with turning movement still agrees
- packet spawns along facing with no target; a fused homing packet binds one
- beam hits an enemy inside its capsule at the far end and misses one beside
  it and one behind
- spike hits inside the wedge along facing and misses behind
- landmine lands behind the owner, on open ground
- every `FxKind` has a draw arm (structural grep of `_draw`)

Existing suites: fixtures naming `flood`, `snipe`, `cascade`, `throttle`,
`airgap` (test_build, test_offers, test_fusion, test_cards_keyboard,
test_blocks, test_minibosses, test_dispatch, test_drain) move to survivors.
test_build asserts the count of 30 and that checksum is a payload. The
`grep -w flood` hits in test_terrain and test_flow are the BFS flood and
are not modules.

Gates: `tools/run_tests.sh` (all suites and the perf gate),
`tools/determinism_probe.gd`. The manual regenerates from the tables.

Windowed, for the user: `tools/shot_fx.gd` and a real run to judge the eight
shapes and the facing tick.

## Out of scope

A separate aim input; new vector kinds; rebalancing beyond removing rows;
enemy-facing changes (`_facing_scale` stays as it is).
