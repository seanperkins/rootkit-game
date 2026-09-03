# NAT hole punching — implementation plan

Spec: `docs/superpowers/specs/2026-09-03-nat-punching-design.md`. This is
the corrected plan (2026-09-03), authoritative over the single-socket draft
first written under this filename — see **History** at the bottom for why
that draft could not be built. Each task below is a commit with its own
tests; the runner (`tools/run_tests.sh`, sandbox off for the UDP suites)
stays green throughout. Determinism is the gate at the end.

Topology is a star for the whole feature: host (member 1) punches each
client (member 2..4); a client punches only the host. No task below builds
a client–client link.

## Task 1 — constants and the protocol bump

- `SessionRules`: `PUNCH_DISCOVERY_PORT = 43212`, `PUNCH_TIMEOUT_MS = 3000`.
- Bump `RELAY_PROTOCOL` 1 → 2.
- Add the op shapes to the shared understanding of the op set (they are
  just dictionaries; no enum): `discover` (raw UDP, member → relay),
  `punch` (relay → member, over the relay link), `punched` (diagnostic,
  member → relay, unchanged from the original draft). Update `codemaps`
  after, do not hand-edit.
- Test: `test_relay_rooms` still passes; a `create`/`join` with protocol 1
  is now `refused: bad`.

## Task 2 — the relay pairs directed candidates (pure)

- `RelayRooms.register_reflexive(token, target, host, port, local_host="",
  local_port=0) -> Array`: authenticate `token → member` (the relay-issued
  per-member secret); accept the registration only for a star-legal
  `(member, target)` — `(1, client)` or `(client, 1)` for an existing
  client member — refusing anything else (a client naming another client,
  or a target that is not in the room); store the candidate keyed by the
  DIRECTED pair `(member, target)`.
- Once BOTH directions of a pair are registered — `(host, client)` and
  `(client, host)` both known — mint one shared, unguessable `key` for the
  pair and emit `punch` actions (over the relay link) to both members,
  each carrying the other's `host/port/local_host/local_port` and the SAME
  `key`. Nothing is emitted while only one direction is known.
- Re-registering a candidate for an already-settled pair is a no-op: no
  second `punch`, no new key.
- `disconnect_peer`: purge every candidate, sent-pair marker and key that
  involves the leaving member, in either direction, so a reused member id
  (a new joiner taking the freed slot) starts from a clean pairing state.
- `RelayServer.start(port, punch_port=SessionRules.PUNCH_DISCOVERY_PORT)`
  binds a `PacketPeerUDP` on `punch_port` — a raw datagram socket, not an
  `ENetConnection` — and services it every `poll`: a `discover` datagram's
  source `host:port` (read straight off the socket) is that link's
  reflexive mapping, handed to `register_reflexive` with the token and
  target the datagram carried. The relay sends NO reply on this socket;
  `discover` is one-way.
- Test: `test_punch_rooms` — a pair's `punch` fires only once both
  directions are registered, the shapes are exact including the shared
  key, a star-illegal target is refused, a malformed `local_host` is
  dropped, re-registration after settlement is a no-op, and disconnect
  purges a member's pairing state.

## Task 3 — the per-link socket and the authenticated handshake

- `Transport` relay mode: `host_relayed`/`join_relayed` take a trailing
  optional `punch_port` (default `SessionRules.PUNCH_DISCOVERY_PORT`).
- For each candidate the transport is told about (via its own `punch` op
  from the relay, received on the existing relay link), create ONE
  dedicated `ENetConnection` for that member, `create_host_bound("0.0.0.0",
  0, …)` (OS-assigned port). That same socket sent the `discover` datagram
  that produced the candidate exchange (raw `socket_send`, spending no
  connect); it now spends its single outgoing `connect_to_host` on the
  peer's reflexive address — the ONE candidate a socket may dial, since
  the same socket cannot try local afterward (simultaneous open, proven
  in the original feasibility probe, see History). The punch op's
  `local_host`/`local_port` fields are carried and inert; a same-LAN
  candidate is deferred to a separate per-link socket (distinct
  registration kind) or left to the relay.
- On `EVENT_CONNECT`, send `direct_hello` carrying the `key` the relay's
  `punch` op handed this side. On receiving a `direct_hello` or
  `direct_ack` whose key matches, mark the link authenticated
  (`direct_to(member)` becomes `true`) and, if it was a `direct_hello`,
  answer `direct_ack`. `direct_hello`/`direct_ack` travel only on the
  direct socket; the relay never sees or parses them.
- Poll every per-link socket in `poll()` alongside the relay socket and
  hand its packets up through the SAME `_handle` path once authenticated
  (a direct peer is bound to its member id exactly as the relay source
  byte is).
- `direct_to(member_id: int) -> bool` and `disconnect_direct(member_id:
  int) -> void` are the public API: the former reports an authenticated
  live link, the latter tears the per-link socket down and clears it
  (used by fallback below and by `tools/probe_punch.gd` to force a link
  down).
- Test: `test_transport_punch` (real UDP, loopback) — a host-shaped and a
  client-shaped transport punch, complete the `direct_hello`/`direct_ack`
  handshake, and a record crosses the direct socket.

## Task 4 — path selection and fallback

- `_put`/`flush_relay`: choose a member's direct socket when
  `direct_to(member)` is true, else the relay. Tick-addressed INPUT and
  relay records are marked replayable; control, snapshot and broadcast
  messages are not, so an accelerator never duplicates a non-idempotent
  message.
- Abandon a punch's handshake after `PUNCH_TIMEOUT_MS`, tearing the socket
  down the same way `disconnect_direct` does. Drop a direct link back to
  the relay via `disconnect_direct(member)` when it goes silent past
  `PEER_TIMEOUT_MS`; before the socket dies, replay the bounded
  `DIRECT_REPLAY_MAX = Lockstep.RING` window of tick-addressed records that
  were accepted by the direct socket, over the still-live relay. The ring
  refuses the duplicate; the host restages only newly stored records so a
  replay flood cannot exceed `RELAY_MAX_RECORDS` or drop the newest/lost
  record.
- Test: extend `test_transport_punch` — path prefers direct once
  `direct_to` is true, and a wider-than-`BAD_PACKETS` flood of the same
  direct record, replayed over the relay after one-sided loss, is not
  staged again and counts as no malformed packet. Far-future/invalid-shape
  packets still refuse.

## Task 5 — the manual probe and the determinism gate

- `tools/probe_punch.gd`: host + two joiners through the live relay (three
  `SceneTree` processes, the shape `tools/probe_relay.gd` already uses for
  two). Assert both host↔client links report `direct_to` true, pass a
  record over each direct link, force one link down with
  `disconnect_direct`, and assert its records still cross — over the relay
  fallback, with no change to the session above the transport.
- Determinism: a relayed run and a punched run of one seed produce
  byte-identical tick hashes from `tools/determinism_probe.gd`. This is the
  acceptance gate for the whole feature.
- Deploy the relay (`relay/deploy.sh`), bump nothing in the game client
  that is not already covered, and note the `RELAY_PROTOCOL` bump means old
  clients and the new relay refuse each other — ship the relay and the
  client together.

## History

**Proven approach (de-risked 2026-09-03, still true).** The direct link
uses the LOW-LEVEL `ENetConnection`, NOT `ENetMultiplayerPeer`. A probe
confirmed simultaneous open works: two `ENetConnection`s, each
`create_host_bound("0.0.0.0", 0, ...)` and each `connect_to_host(peer_ip,
peer_port, channels)`, both receive `EVENT_CONNECT` from `service()` within
a few hundred ms, and a packet sent on the returned `ENetPacketPeer`
arrives via `EVENT_RECEIVE`. The high-level `ENetMultiplayerPeer` does NOT
surface such a connection through `peer_connected` (it enforces a
server/client role), so it cannot be used for the punch. This is why Task 3
above uses a raw `ENetConnection` per link.

**BLOCKER found in the first Task 3 attempt (2026-09-03).** That attempt
gave each peer a SINGLE shared punch socket, meant to both
`connect_to_host` the relay's discovery endpoint and `connect_to_host` each
candidate peer. Godot's `ENetConnection` allows only ONE outgoing
`connect_to_host` for its whole life: the second call fails with "The
ENetConnection is already connected to a peer"
(`modules/enet/enet_connection.cpp:87`, confirmed by probe). It accepts
many incoming connections but dials out only once, so one socket cannot
dial both the discovery endpoint and a peer — and for 3-4 players a peer
could not dial several others from one socket either. The client punch code
written against that draft was reverted; the relay candidate-exchange logic
(`RelayRooms`, tested) and the constants stood and were carried into the
redo. The corrected shape — one `ENetConnection` PER LINK, discovery as a
one-way raw datagram that spends no connection's one connect, directed
`(member, target)` registration, and a relay-issued key authenticating the
handshake — is Tasks 2-4 above, not an addendum to the reverted draft.

## Risks

- **Symmetric NATs** will not punch; they stay relayed. Acceptable.
- **The protocol bump is a hard cut**: the deployed relay and released
  clients must move together, or every link is `refused: bad`. Coordinate
  the relay deploy with the client release.
