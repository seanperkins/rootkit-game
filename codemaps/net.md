> Generated: 2026-09-02 | Token-lean format for LLM context

# Networking — `scripts/net/` and the session parts of `run.gd`

Deterministic lockstep, direct connect, up to four players. Every peer runs
the whole simulation; only INPUT RECORDS cross the wire. Three pure classes
(`lockstep`, `network_session`, `protocol`) and ONE class that touches ENet
(`transport`). The simulation never holds a node reference: the run polls
the transport above the world guard and reads records from the ring.

```
lobby (meta_screen) ──HELLO/WELCOME/START──> immutable descriptor
                                                  │  seed, delay, roster+counters
run._ready: _derive_roster ─> every RNG, sheet, build derived from it
tick (above the guard):  poll transport ─> ring ─> take(tick) ─> _apply_records
                         checksum every 60 ticks ─> host compares ─> RESYNC/SNAPSHOT
                         terminal state ─> END_CANDIDATE ─> END_CHECK ─> END
                         peer gone ─> ABSENT(slot, tick)  · HELLO back ─> PRESENT(slot, R)
```

## `data/session_rules.gd` — `SessionRules`, every shared constant

| Const | Value | Const | Value |
|---|---|---|---|
| `PROTOCOL` | 1 | `NAME_MAX` | 24 |
| `TICK_DT` | 1/60 | `HITSTOP_TICKS` | 4 |
| `MAX_PLAYERS` | 4 | `DEFAULT_DELAY` / `LAN_DELAY` | 4 / 3 |
| `CHOICE_TIMEOUT_TICKS` | 1800 | `CHECKSUM_INTERVAL` | 60 |
| `STALL_NOTICE` | 20 ticks | `MOVE_COMPONENT_MAX` | 1.3635 |
| `MAX_WINDOW` | 7200 | `LEASH` | 4000 (`MAX_WINDOW - 3200`) |
| `SNAPSHOT_MAX` | 1 MiB | `SNAPSHOT_VERSION` | 1 |
| `BAD_PACKETS` | 20 | `PEER_TIMEOUT_MS` | 3000 |
| `CONTROL_MAX` | 16384 | `ADDRESS_MAX` | 64 |
| `DEFAULT_PORT` | 43210 | | |

## `scripts/net/lockstep.gd` (361) — `Lockstep`, PURE

A ring of `RING = 128` ticks × `MAX_PLAYERS` records `{move, card, target,
offer}`, tagged by absolute tick (`_tick_tag`, `_have` bitmask per cell).
`_required = _present_mask & _live_mask`: `ready(tick)` waits on LIVE slots
only; DEAD records are stored and ignored; ABSENT slots are not stored.

| API | Note |
|---|---|
| `submit(slot, tick, move, card, target, offer) -> bool` | immutable once stored; duplicate/stale/far-future refused; values verbatim (sanitation is the run's) |
| `ready(tick)` / `take(tick, moves, cards, targets, offers)` | take is allocation-free and advances `executed` |
| `mark_live / mark_dead / mark_absent / mark_present` | the run mirrors `slot_state` every tick (`_sync_ring_roster`) |
| `prime(first, last)` / `prime_slot(slot, first, last)` | neutral records: the opening `delay` ticks, and a returnee's `(R, R+delay]` |
| `missing(tick)` / `has_record(slot, tick)` / `has_window(after)` | stall notice; first-missing-tick parking; snapshot readiness |
| `submit_checksum / desync_at / prune_checksums` | sparse `tick -> {mask, hashes}` |
| `snapshot_window(after)` / `merge_window(raw, after)` | the `(after, after+delay]` cells a snapshot carries; merge keeps NEWER cells |

## `scripts/net/protocol.gd` (275) — `Protocol`, PURE codec

14-byte little-endian envelope: `u8 proto, u8 kind, i32 session, i32 tick,
i32 body_len`. Body per kind: INPUT 20 bytes (2×f32 + 3×i32); RELAY `u8 n`
records of 25 bytes + `u8 m` checksums of 13; CHECKSUM i64; SNAPSHOT raw
bytes; control kinds `var_to_bytes` of a primitive Dictionary, decoded with
`bytes_to_var` (never `_with_objects`), bounded by `CONTROL_MAX`,
shape-checked per kind — unknown fields dropped, bad values refuse the body.

```gdscript
enum Message { HELLO, WELCOME, START, INPUT, RELAY, CHECKSUM, RESYNC, SNAPSHOT,
               ABSENT, PRESENT, LEAVE, END_CANDIDATE, END_CHECK, END }
BOUNDARY_MARGIN = 3     # a boundary sits at executed + delay + 3
```

`valid_tick(kind, tick, ctx)` — three DISTINCT windows: input
`[executed, +RING)` or `[boundary+1, …)` while one is armed; checksum
`[executed-RING, executed+RING)`; boundary (RESYNC, END_CHECK)
`[executed+delay+3, executed+RING]`. A reconnecting client skips the boundary
window (its cursor is stale by design).

## `scripts/net/transport.gd` (351) — `Transport`, `Node`, the ENet class

`create_server(port, 3, 2)` / `create_client(addr, port, 2)`: two user
channels on both ends. Channel 0 reliable-ordered: control, INPUT, RELAY;
channel 0 unreliable: periodic CHECKSUM; channel 1 reliable: SNAPSHOT.
Raw `put_packet`/`get_packet`; no RPC, synchroniser or spawner.

| API | Note |
|---|---|
| `host / join / rejoin / close / connected` | `rejoin` re-dials the stored address after a drop |
| `bind_peer(peer, slot)`, `slot_of_peer`, `peer_of_slot` | the relay set; a returnee is bound in the frame the host serialises |
| `send_input / send_checksum` | the host stages its own into the relay |
| `flush_relay(tick)` | ONE bundle per client per tick, never a forward per INPUT |
| `send_control(kind, tick, body, to=0)`, `send_snapshot(to, tick, bytes)` | |
| `poll()` → `_handle` | envelope → per-kind validation → ring / inbox / `snapshot_received` |
| `_refuse(from)`, `bad_packets`, `malformed_total` | a peer is cut at `BAD_PACKETS` |
| `drop_peer(id)`, `dropped_peers` | INPUT from an unbound peer is a cut, not a count |
| `arm_boundary(tick) / release_boundary / held_count` | records past an announced boundary are submitted AND retained (`HELD_MAX`), re-offered after a restore |

Signals: `peer_joined`, `peer_left` (emitted BEFORE the binding is erased),
`snapshot_received(tick, bytes)`. Per-peer `set_timeout(3000)` on connect.

## `scripts/net/network_session.gd` (434) — `NetworkSession`, PURE

`enum Role { SOLO, HOST, CLIENT }`. The immutable `descriptor`
`{protocol, session_id, seed, delay, choice_timeout, roster[{slot, name,
counters}]}` — `validate_descriptor(raw)` returns a clean copy or `{}` on ANY
violation, because one differing byte desyncs the run. `local_slot`, `role`,
`lockstep`, `inbox` (validated control messages, drained by lobby or run),
`started`, `accepts_hello`.

| Group | State / API |
|---|---|
| lobby | `host_lobby / client_lobby / admit / remove_peer / free_slot / lobby_descriptor / start / apply_welcome / apply_start`, `lobby_rows`, `peer_slots` |
| recovery | `resync_tick / resync_targets / resync_sent / queued_resync`, `announce_resync / clear_resync / recovering`, `record_desync` (3 → `terminated`), `desync_ticks` |
| ending | `enum Outcome { NONE, LOSS, WIN, TERMINATED }`, `end_check_tick / end_reports / end_outcome / end_candidate_pending / end_reported / ended`, `open_end_check / clear_end_check / cancel_no_live_check` |
| parking, return | `reconnecting` (client), `reconnect {slot, peer, tick}` (host), `pending_live_return` latch, `last_present_tick`, `absent_ticks`, `latched / clear_latch` |
| solo | `solo_descriptor(profile, seed)`: one slot, delay 0, no timeout — the same shape |

## The session in `run.gd`

| Concern | Where |
|---|---|
| bind | `configure_session(s)` before `_ready`; `attach_transport(t)`; `_default_solo_session()` (seed `DEFAULT_SEED`) |
| roster | `_allocate_slots` (every per-player field a `MAX_PLAYERS` array; `SlotState {LIVE, DEAD, ABSENT}`), `_derive_roster` (build, sheet, unlocks from counters; `started = true`) |
| input | `_poll_local_input` — the ONLY `Input.*` site; submits the full record for `executed + delay`; neutral while paused, DEAD or held |
| tick (above guard) | `_snapshot_render_state → _poll_local_input → poll/_drain_inbox/_reconnect_step/flush_relay → _present → [reconnecting? return] → _roster_step → _sync_ring_roster → _recovery_step → _ending_step → ready? take → _apply_records → _resolve_deadlines → _settle_offers → hitstop / guard → _step_world → _report_checksum` |
| offers | per-slot primitive input state: `_offer_seq/_offer_open/_offer_queue`, `OfferKind`, rounds; UI calls only STAGE `_local_choice` |
| manifest | `STATE_FIELDS` `[obj, prop|@derived, SNAPSHOT/HASH/VARLEN, slice, covers]`, `NOT_IN_MANIFEST`; `_state_hash()`, `serialize_state(after)`, transactional `restore_state(bytes, after)`, `_after_restore` |
| recovery | `host_detect_desync → announce_resync(R) → host_try_snapshot` (only at `executed == R+1` with the window; `_holding_for_snapshot`) `→ apply_snapshot`; `_terminate` at three desyncs |
| ending | `_terminal(outcome)` — the ONLY path from `_die`/win; solo emits at once; `receive_end_candidate / receive_end_check / receive_end / evaluate_end_check / _confirm_end / _ending_step`; a mismatch is a fresh future RESYNC |
| parking | `request_park → _host_park_step` (first tick with no record) `→ _park` (health remembered in `_parked_health`, offers resolved, banked once, last LIVE → LOSS candidate) |
| return | `accept_reconnect` (R = executed+delay+3, latch when no LIVE, WELCOME/RESYNC/PRESENT) `→ _return(slot, R)` after R (LIVE beside the party via `terrain.nearest_open`, primed; or DEAD) · `abort_reconnect` · client `_begin_reconnect` (10 attempts) |
| notices | `missing_slots()`, `_stalled_ticks`, `_session.recovering()/reconnecting` read by `ui.gd` |

## Rules the layer depends on

- **Every peer applies a roster change at the TICK it names**, never on
  arrival: ABSENT before consuming T, PRESENT after consuming R.
- **The host is the authority.** If it diverged, the others are brought to it.
- **Only END ends a session.** A local terminal state is a candidate.
- **A snapshot is primitives only**, validated field by field before one write.
- **Nothing in the tick graph reads a clock, the device, or `Engine.*`**;
  `test_determinism_rules` greps for it.

## Suites

`test_determinism_rules test_meta_derivation test_lockstep test_plurality
test_offers test_manifest test_snapshot_hostile test_multiplayer_sim
test_transport_loopback test_lobby test_recovery test_ending test_parking
test_reconnect`. Support: `tests/support/multiplayer_harness.gd`
(N runs on one descriptor, records keyed by tick, `withheld` ranges,
`step/step_one/catch_up/distribute_checksums/all_agree/first_difference`) and
`tests/support/roster_pump.gd` (the control wire by hand). The loopback suite
needs real UDP: run it with the Bash sandbox disabled.
`tools/determinism_probe.gd` prints `tick hash` per tick for the cross-arch diff.
