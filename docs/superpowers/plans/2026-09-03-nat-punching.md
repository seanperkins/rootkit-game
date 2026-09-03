# NAT hole punching — implementation plan

Spec: `docs/superpowers/specs/2026-09-03-nat-punching-design.md`. Each task
is a commit with its own tests; the runner (`tools/run_tests.sh`, sandbox
off for the UDP suites) stays green throughout. Determinism is the gate at
the end.

## Task 1 — constants and the protocol bump

- Add `PUNCH_PORT = 43212`, `PUNCH_TIMEOUT_MS = 3000` to `SessionRules`.
- Bump `RELAY_PROTOCOL` 1 → 2.
- Add the two op kinds to the shared understanding of the op set (they are
  just dictionaries; no enum). Update `codemaps` after, do not hand-edit.
- Test: `test_relay_rooms` still passes; a `create` with protocol 1 is now
  `refused: bad`.

## Task 2 — the relay learns and hands out candidates (pure)

- `RelayRooms`: on `create`/`join`, record the member's reflexive
  `host:port`. The reflexive address comes from the ENet layer, so
  `RelayServer` passes it into `handle`/`connect_peer` (the pure class does
  not read a socket). Store the optional self-reported `local_host/port`,
  sanitised.
- When a room reaches ≥2 members, and on every later join, emit `punch`
  ops to each member carrying the others' candidates.
- Accept and record `punched`.
- Test: `test_punch_rooms` — candidates are handed out on the second join,
  the shapes are exact, a malformed `local_host` is dropped, `punched` is
  recorded.

## Task 3 — the second socket in the transport

- `Transport` relay mode: create `_punch_peer` bound to `PUNCH_PORT`,
  able to both accept and dial. Self-report the LAN candidate in
  `create`/`join`.
- On a `punch` op, start a simultaneous-open attempt to every candidate of
  every listed member; mark `_direct[member]` when a handshake completes;
  send `punched`.
- Poll the second socket in `poll()` alongside the relay socket; hand its
  packets up through the SAME `_handle` path (a direct peer is bound to its
  member id exactly as the relay source byte is).
- Test: `test_transport_punch` (real UDP, loopback) — two transports punch
  and a record crosses the direct socket.

## Task 4 — path selection and fallback

- `_put`/`flush_relay`: choose the direct socket for a member with
  `_direct[member]`, else the relay.
- Abandon a punch after `PUNCH_TIMEOUT_MS`; drop `_direct[member]` back to
  the relay when a direct link goes silent past `PEER_TIMEOUT_MS`.
- Test: extend `test_transport_punch` — path prefers direct once set, falls
  back cleanly when cleared, and no record is lost across the switch (the
  ring refuses the duplicate).

## Task 5 — the manual probe and the determinism gate

- `tools/probe_punch.gd`: host + two joiners through the live relay; assert
  each pair reports direct and that records still cross when a direct link
  is forced down.
- Determinism: a relayed run and a punched run of one seed produce
  byte-identical tick hashes from `tools/determinism_probe.gd`. This is the
  acceptance gate for the whole feature.
- Deploy the relay (`relay/deploy.sh`), bump nothing in the game client
  that is not already covered, and note the `RELAY_PROTOCOL` bump means old
  clients and the new relay refuse each other — ship the relay and the
  client together.

## Risks

- **Godot's ENet wrapper and one bound socket doing both listen and dial.**
  If `ENetMultiplayerPeer` will not, drop to `ENetConnection` on a single
  bound `PacketPeerUDP`/socket via the lower-level API. Prove this in Task
  3 before building on it.
- **Symmetric NATs** will not punch; they stay relayed. Acceptable.
- **The protocol bump is a hard cut**: the deployed relay and released
  clients must move together, or every link is `refused: bad`. Coordinate
  the relay deploy with the client release.
