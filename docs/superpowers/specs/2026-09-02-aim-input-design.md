# Aim input: stick and mouse facing, and the arrow

## Why

The weapons pass made packet, beam and spike fire along `player_facing`, and
facing follows the last non-zero movement. Playtesting found that steering a
single packet by movement alone is too hard: to aim you must move, and moving
is also how you dodge. Players with a right stick or a mouse should aim with
it, and the player glyph should show the direction, because direction now
matters.

## Decisions

- Facing stays SIMULATION state derived from the lockstep record. An aim that
  lived only on the local machine would desync the wedge from peer to peer.
- The record gains an `aim` vector. Movement still sets facing when the aim is
  zero, so keyboard-only play is unchanged.
- The mouse aims while it has moved recently; the right stick aims while it is
  deflected. Both are sampled in `_poll_local_input`, the one place the device
  is read.
- The player is drawn as an arrow along its facing. The disc goes.

## 1. The record

`Protocol` record body becomes `move.x move.y aim.x aim.y card target offer`:
two more floats, `INPUT_BODY` 20 → 28, `RELAY_RECORD` 25 → 33. `encode_input`,
`decode_input`, `_put_record`, `_get_record` and the relay encode/decode all
carry it. A body of the old size is a malformed packet and is refused like any
other wrong-sized body; `SessionRules.PROTOCOL` goes 1 → 2 so a peer on the
old build cannot join.

`Lockstep` stores `_aims: PackedVector2Array` beside `_moves`, sized the same,
written by `submit(slot, tick, move, aim, card, target, offer)`, read by
`take(tick, out_moves, out_aims, out_cards, out_targets, out_offers)`, zeroed
wherever `_moves` is zeroed, and carried in the ring snapshot as `"aims"`
beside `"moves"`, validated the same way (a `PackedVector2Array` of the right
length or the snapshot is refused).

The run keeps `aims: PackedVector2Array` per slot beside `inputs`, filled in
`_apply_records` through `_sanitise_aim` (finite, both components within
`MOVE_COMPONENT_MAX`, else zero; a non-zero result is normalised so a hostile
record cannot set a facing of length 40). `aims` joins the manifest beside
`inputs` (same flags), and `_rec_aims` is a take buffer classified with the
other take buffers.

Every caller of `submit` and `take` gains the argument: `_poll_local_input`,
the harness in `tests/support/multiplayer_harness.gd`, `roster_pump.gd`, the
perf gate, the shot tools and the lockstep, parking, reconnect and loopback
suites.

## 2. Facing

In `_step2_integrate`, per LIVE slot, before the movement facing line:

```
if aims[s].length_squared() > 0.0: player_facing[s] = aims[s]
elif inputs[s].length_squared() > 0.0: player_facing[s] = inputs[s].normalized()
```

`aims[s]` is already unit (sanitised on apply). Standing still with no aim
keeps the last facing, as now. DEAD and ABSENT slots are not touched. The
facing lags the device by the lockstep delay exactly as movement does.

## 3. The poll

`_poll_local_input` samples, in order, and takes the first non-zero:

1. The right stick, through four new actions `aim_left aim_right aim_up
   aim_down` bound to joypad axes 2 and 3 with deadzone 0.25, read with one
   `Input.get_vector` and unprojected with `from_iso` like movement, so a
   stick pushed up on screen aims up on screen.
2. The mouse, when it has moved within `MOUSE_AIM_HOLD := 1.5` seconds.
   A new `_unhandled_input` on the run (presentation side, above the world
   guard like the poll) stamps `_mouse_moved_at` from `InputEventMouseMotion`
   using the engine's ticks clock; the poll compares it with the same clock.
   Both reads live in presentation, not in the tick, and `_mouse_moved_at`
   is classified `NOT_IN_MANIFEST` as local presentation. The aim is
   the world direction from the local slot to the cursor:
   `from_iso(get_global_mouse_position() - to_iso(player_render_pos[local_slot]))`,
   normalised. The camera follows `view_slot`, so when the local slot is being
   spectated from elsewhere the cursor still resolves against the local
   slot's own render position.
3. Otherwise `Vector2.ZERO`.

A session pause, a DEAD slot and a held terminal state send a zero aim with
the zero move, as today. `input_override` drives movement only; a second test
seam `aim_override` (null or `Vector2`) drives the aim so headless suites can
aim without a device. `test_input`'s one-place rule (`Input.` appears in
exactly one function) still holds: the mouse position read is a viewport call
made in the same function, and `test_determinism_rules` greps the tick, not
the poll.

## 4. The arrow

`_draw`'s player loop replaces the disc and rim tick with an arrow: a
world-space isoceles triangle of length `PLAYER_RADIUS * 2.2` and half-width
`PLAYER_RADIUS * 0.9`, tip at `player_render_pos + facing * PLAYER_RADIUS *
1.3`, projected point by point with `to_iso` so it leans with the ground, in
the slot's hue with the slot's alpha, filled dim and outlined bright. An
ABSENT slot's parked marker keeps the arrow at its parked facing, dimmed as
now. The name tag stays above it. `test_draw_order` is unaffected (it reads
the draw list, not the shape).

## 5. Testing

- `test_facing`: `aim_overrides_movement_facing` (move left, aim up, facing is
  up), `zero_aim_falls_back_to_movement`, `a_hostile_aim_is_normalised`
  (submit an aim of length 40 through the ring; facing is unit), the two-peer
  turning case gains an aim per tick and still agrees, the restore case
  carries `aims`.
- `test_lockstep`: the record round trip includes `aim`; a snapshot with a
  wrong-length `aims` is refused.
- `test_parking` and `test_transport_loopback` compile against the new
  signatures; the loopback case asserts the received aim.
- `test_input`: the right stick sets the aim through the actions (an
  `InputEventJoypadMotion` on axis 2), the mouse aims within the hold and not
  after it, `every_referenced_action_exists` picks up the four new actions,
  and the one-place rule still passes.
- `test_manifest`: `aims` and `_rec_aims` classified.
- The perf gate changes only in signature: every slot submits a zero aim, so
  the fixture's behaviour and its coverage pin are untouched.

## Out of scope

Aim assist, aim-relative movement, a visible cursor reticle, and remapping
the aim actions in a settings screen.
