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

## BLOCKER found in Task 3 (2026-09-03) — and the corrected design

Godot's `ENetConnection` allows only ONE outgoing `connect_to_host`: the second
fails with "The ENetConnection is already connected to a peer"
(`modules/enet/enet_connection.cpp:87`, confirmed by probe). It accepts many
INCOMING connections, but dials out only once. So a single punch socket CANNOT
dial both the relay's discovery endpoint AND a peer — and for 3-4 players a peer
cannot dial several others from one socket. The single-shared-socket design in
the spec is therefore infeasible. The client punch code written against it was
reverted; the relay candidate-exchange logic (`RelayRooms`, tested) and the
constants stand.

Corrected design (for the redo):

- **One `ENetConnection` per DIRECT LINK.** To punch member M, a peer creates a
  dedicated bound `ENetConnection`, uses its single outgoing connect for the
  simultaneous open to M, and accepts M's incoming connect on it. A peer
  punching K others holds K such sockets. Two-player co-op — the case that
  matters now — needs exactly one.
- **Discovery via raw UDP, not an ENet connection.** Each punch socket learns
  its own public mapping WITHOUT spending its one outgoing connect: send a raw
  datagram with `ENetConnection.socket_send(host, port, bytes)` to the relay's
  discovery endpoint, which is a **`PacketPeerUDP`** (NOT the `ENetConnection`
  the committed `relay_server.gd` currently uses — that must change). The relay
  reads the datagram's source `get_packet_ip()/get_packet_port()` = that
  socket's mapping, ties it to the member by the token, and pairs it. The relay
  discovery endpoint is undeployed, so changing it is free.
- **Pairing.** For the P–Q link, P registers socket S_pq's mapping and Q
  registers S_qp's; the relay tells P "Q at mapping(S_qp)" and Q "P at
  mapping(S_pq)"; each dials the other from its own socket. The `punch` op and
  `register_reflexive` already carry per-member candidates; extend the token to
  identify (member, target) so a peer's several punch sockets are told apart.
- Everything else in the plan (path selection per member in `_put`, fallback to
  the relay, the determinism gate, the coordinated `RELAY_PROTOCOL` bump and
  deploy) is unchanged.

## Risks

- **Symmetric NATs** will not punch; they stay relayed. Acceptable.
- **The protocol bump is a hard cut**: the deployed relay and released
  clients must move together, or every link is `refused: bad`. Coordinate
  the relay deploy with the client release.
