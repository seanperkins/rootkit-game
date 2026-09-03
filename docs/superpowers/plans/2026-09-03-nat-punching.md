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

- `Transport` relay mode: create `_punch: ENetConnection` via
  `create_host_bound("0.0.0.0", PUNCH_PORT, MAX_PLAYERS, CHANNELS)` and, on a
  `punch` op, `connect_to_host` each candidate. Self-report the LAN candidate
  in `create`/`join`. (Feasibility proven — see "Proven approach".)
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

## Proven approach (de-risked 2026-09-03)

The direct link uses the LOW-LEVEL `ENetConnection`, NOT `ENetMultiplayerPeer`.
A probe confirmed simultaneous open works: two `ENetConnection`s, each
`create_host_bound("0.0.0.0", PUNCH_PORT, ...)` and each
`connect_to_host(peer_ip, peer_port, channels)`, both receive
`EVENT_CONNECT` from `service()` within a few hundred ms, and a packet sent
on the returned `ENetPacketPeer` arrives via `EVENT_RECEIVE`. The high-level
`ENetMultiplayerPeer` does NOT surface such a connection through
`peer_connected` (it enforces a server/client role), so it cannot be used
for the punch. The transport already does raw `put_packet`/`get_packet`, so
a second `ENetConnection` carrying `RelayFrame.route`-framed record bytes
drops in alongside the relay socket: `poll()` services it and hands its
packets up through the same `_handle` path, keyed by member id.

## Risks

- **Symmetric NATs** will not punch; they stay relayed. Acceptable.
- **The protocol bump is a hard cut**: the deployed relay and released
  clients must move together, or every link is `refused: bad`. Coordinate
  the relay deploy with the client release.
- **Symmetric NATs** will not punch; they stay relayed. Acceptable.
- **The protocol bump is a hard cut**: the deployed relay and released
  clients must move together, or every link is `refused: bad`. Coordinate
  the relay deploy with the client release.
