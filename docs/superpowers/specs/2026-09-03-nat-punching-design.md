# NAT hole punching — design

Phase two of the relay work. The relay ships and works, but every packet
takes two hops through a New York droplet: a joiner's record reaches the
host via the relay and back, so the round trip that lockstep waits on is
client → relay → host and the answer host → relay → client. `RELAY_DELAY`
is 5 ticks precisely to hide that hop, and it is felt as lag. Hole punching
lets a host and a client behind consumer NATs exchange packets directly,
cutting the hop out for the links it works on, while the relay stays as the
fallback and the signalling channel.

This is the corrected design (2026-09-03), authoritative over the mechanism
first drafted for this feature. The original draft specified one shared
`_punch` socket per peer and left client–client punching implied by "full
mesh"; both are infeasible or out of scope, for the reasons in
**History** at the bottom. Nothing below builds either.

## Topology: a star, not a mesh

Punching only ever builds direct links on the edges that already carry
records: **host (member 1) to each client (member 2..4)**. A client never
punches another client. This is not a restriction added on top of an
otherwise general mechanism — it is what makes one `ENetConnection` per
link sufficient (see below) and it matches how records already flow: a
client sends its record only to the host, and the host's `flush_relay`
fans every record out to every client. Punching changes only WHICH socket
carries that host↔client traffic, never who talks to whom.

The relay enforces this: a directed candidate registration is accepted only
for `(1, target)` where `target` is an existing client member, or
`(member, 1)` where `member` is an existing client registering against the
host. A client registering a target other than 1 is refused.

## What stays

- **The relay stays.** It is the rendezvous, the room registry and the
  fallback path. Nothing about room codes, `create`/`join`/`room`, the
  member ids (host 1, joiners 2..4) or the one-byte route changes.
- **The simulation never learns any of this.** Punching lives entirely in
  `transport.gd` and the relay; the run still polls the transport above the
  guard and reads records from the ring. `lockstep`, `network_session` and
  `protocol` stay pure and untouched, except for the new relay ops and the
  constants below.
- **Direct connect by address stays** for LAN and the loopback suites — a
  wholly separate, non-relayed mode.
- **The record flow is unchanged.** The host still relays every member's
  record to every other member over the relay link, or the direct link
  where one exists for that host↔client leg; a record is a record to
  `lockstep.submit`, which one socket carried it.

## The mechanism

Each peer already holds one ENet client socket, to the relay
(`ENetMultiplayerPeer`, used for the room and the record traffic). Punching
adds, per host↔client link, a **second, dedicated `ENetConnection`** bound
to an OS-assigned local port. Godot's `ENetConnection` permits exactly ONE
outgoing `connect_to_host` for its whole life — confirmed by probe, see
History — so a peer that needs K direct links holds K such sockets. In this
star, K is at most 3 for the host and always exactly 1 for a client.

### Candidates and reflexive discovery

The address the relay sees for a peer's ROOM connection is not the address
the other side of a punch can reach: the punch uses a separate socket with
its own NAT mapping, and that mapping must be observed independently, once
per link.

- The relay opens a second endpoint, a **`PacketPeerUDP`**, on
  `PUNCH_DISCOVERY_PORT`. This is a raw datagram socket, not an
  `ENetConnection` and not an ENet peer of anything — it never spends
  either side's one outgoing connect.
- Each host↔client link's `ENetConnection` (the same socket that will later
  dial the peer) sends ONE raw UDP datagram — `socket_send`, not
  `connect_to_host` — to `PUNCH_DISCOVERY_PORT`, carrying
  `{op:"discover", token:String, target:int, local_host:String,
  local_port:int}`. `token` is the member's per-session relay-issued
  secret (proves which member is asking); `target` says which link's
  candidate this is (the host has up to three sockets, one per client, and
  the token alone cannot tell them apart). This is ONE-WAY: the relay never
  answers on the discovery socket. The relay reads the datagram's source
  `host:port` — that link's socket's own reflexive mapping — from the OS,
  the same way a STUN server would.
- The relay authenticates `token → member`, accepts the registration only
  for a star-legal `(member, target)` pair (see **Topology**), and stores
  the candidate keyed by that DIRECTED pair. It emits nothing back to
  either side until BOTH directions of the pair are registered — i.e. until
  it holds both `(host, client)`'s and `(client, host)`'s candidates.
- The **local** candidate (the peer's LAN `ip` and its own bound port)
  rides in the same `discover` datagram and is sanitised exactly like
  `last_address` (the hostname whitelist, length cap), but is **explicitly
  deferred**: it is carried and reserved, never dialed by this release.
  One `ENetConnection` permits exactly one outgoing `connect_to_host`, so
  a socket cannot try reflexive first and then retry the local address —
  and a second socket per link (a distinct registration kind per
  candidate, so both directions of each kind settle separately) is not
  warranted before field evidence that same-LAN-no-hairpin co-op is
  common. Such a pair rides the relay, which is always available. The
  reflexive candidate is therefore THE candidate this feature dials:
  the link socket raw-punches the remote reflexive mapping and spends its
  sole connect on it.
- Once both directions are known, the relay mints ONE shared, unguessable
  `key` for the pair and sends each side, over the EXISTING relay link (not
  the discovery socket), `{op:"punch", member:<the other member>,
  host:String, port:int, local_host:String, local_port:int, key:String}`.
  Tokens and keys come from `Crypto.generate_random_bytes` (one 128-bit
  hex string each) — never from the seedable, observable room-code
  `RandomNumberGenerator`, whose stream is not authentication-grade.
  Both sides receive the SAME `key`; it authenticates the direct handshake
  below, so a socket that merely completes an ENet connect to the right
  port — which anyone on the LAN or a guessing attacker could attempt — is
  not yet trusted as the real peer.
- Re-registering a candidate for a pair that has already been sent its
  `punch` op is a no-op: no duplicate `punch`, no new key. A member's
  candidates, sent-pairs and key are purged when it disconnects, so a
  reused member id (a new joiner taking a freed slot) can punch again from
  a clean state.
- The diagnostic `punched` op (`member → relay, {op:"punched", member}`)
  is unchanged: a member may report a completed direct link for the relay's
  logs. The relay's own pairing state does not depend on it — it already
  knows a pair is settled from its directed registrations.

### The direct link, the handshake, and path selection

`transport.gd` in relay mode gains, per registered target member:

- One `ENetConnection`, bound to an OS-assigned port, that both sends the
  `discover` datagram above and later spends its single outgoing connect on
  `connect_to_host` to the remote reflexive mapping named by the punch op
  — the standard simultaneous-open punch: both ends dial each other at
  once, and the first packet from each opens its NAT's mapping for the
  other's reply. The op's `local_host`/`local_port` fields are inert on
  this socket (see **Candidates and reflexive discovery**): one socket,
  one connect, one candidate — the reflexive one.
- **Authentication over the raw connect.** A completed ENet handshake alone
  only proves a UDP path exists to *something* listening on that port — not
  that it is the intended peer. Each side sends `direct_hello` carrying the
  `key` the relay handed it as soon as the connection completes, and
  answers a hello whose key matches with `direct_ack`. A link is trusted —
  `direct_to(member)` becomes `true` — only once this side has SEEN a
  `key` match, from either the peer's `direct_hello` or its `direct_ack`.
  `direct_hello`/`direct_ack` travel ONLY on the direct socket and are
  never sent to, or parsed by, the relay.
- Path selection in `_put`/`flush_relay`: for a destination member with
  `direct_to(member)` true, send on that member's direct socket; otherwise
  the relay, exactly as today. **The receive side accepts a record from
  either path** — a record is a record; `_handle` already keys everything
  by the member id (the route byte, or the direct socket's bound target),
  not by which socket it arrived on.

Because path is chosen per destination and records are idempotent by
`(slot, tick)` in the ring, a link can migrate from relayed to direct
mid-session with zero seam: a record that crosses both ways during the
switch is submitted once and the duplicate refused, which `lockstep.submit`
already does.

### Fallback and liveness

- A punch that does not complete its authenticated handshake within
  `PUNCH_TIMEOUT_MS` (default 3000, the peer timeout) is abandoned; that
  link stays relayed. No user-visible failure — the relay path was already
  working.
- A direct link that later goes silent past `PEER_TIMEOUT_MS` is dropped:
  `disconnect_direct(member)` tears the socket down and clears
  `direct_to(member)`, and traffic to that member falls back to the relay.
  The relay link is held open for the whole session precisely so this is
  always available. `disconnect_direct` is also how a link is deliberately
  forced down for testing (see `tools/probe_punch.gd`).
- **One-sided failure keeps no seam.** Worse than a fully silent link, a
  NAT rebinding can make the sender's direct `send()` return OK while the
  receiver's mapping is already gone — the packet is delivered nowhere and
  ENet's timeout outlives the record's usefulness. The transport therefore
  retains a bounded window (`DIRECT_REPLAY_MAX = Lockstep.RING`, one
  record ring per link) of tick-addressed INPUT/CHECKSUM/RELAY packets sent
  direct, and replays it over the still-live relay before the socket is
  destroyed. The lockstep ring refuses the duplicate by `(slot, tick)`, so
  the replay is lossless at the seam; control, snapshot and broadcast
  messages are never replayed, because they are not duplicate-idempotent.
  Replayed stale ticks are treated as benign (not malformed, not restaged),
  since a legitimate replay flood must not trip the bad-packet cutoff.
- The host's END, parking, reconnect and snapshot paths are unchanged: they
  ride whatever path is current for the member, and all of them are already
  keyed by member/slot, not socket.

## Constants (`data/session_rules.gd`)

| Const | Value | Why |
|---|---|---|
| `PUNCH_DISCOVERY_PORT` | 43212 | the relay's `PacketPeerUDP` reflexive-discovery endpoint; each link's punch socket binds an OS-assigned port |
| `PUNCH_TIMEOUT_MS` | 3000 | give up a punch's handshake and stay relayed; matches `PEER_TIMEOUT_MS` |
| `RELAY_PROTOCOL` | → 2 | the op set grows (`discover`/`punch`), so the relay protocol bumps; a mismatch is `refused: bad` |

`RELAY_DELAY` stays 5 for now: the delay is set at lobby time, before any
punch has completed, and lowering it per-link mid-session would desync the
input schedule. A later pass can negotiate a lower delay once every link is
direct; out of scope here.

`Transport.host_relayed`/`join_relayed` take the discovery port as an
optional trailing argument (default `SessionRules.PUNCH_DISCOVERY_PORT`),
so the relay suite can stand a relay up on loopback with a private port the
same way it already does for the room port.

## Determinism

Punching cannot change a single hash. The evidence: records are keyed by
`(slot, tick)` and folded identically whatever socket carried them; the
delay is fixed for the session; path selection is local to each sender and
invisible below the guard. `tools/determinism_probe.gd` must still print
byte-identical tick hashes across a relayed run and a punched run of the
same seed — that is the acceptance gate.

## Testing

- **`test_punch_rooms`** (pure, loopback): the relay pairs a directed
  `(member, target)` registration with its reverse and emits `punch` with a
  shared key only once both sides are known; a star-illegal target (a
  client registering another client) is refused; re-registration after a
  settled pair is a no-op; a disconnect purges the member's candidates,
  sent-pairs and key.
- **`test_transport_punch`** (real UDP on loopback): a host-shaped and a
  client-shaped transport punch on OS-assigned ports, complete the
  `direct_hello`/`direct_ack` handshake, and a record crosses the direct
  socket; path selection prefers direct once `direct_to` is true and falls
  back cleanly after `disconnect_direct`.
- **A three-process manual probe** (`tools/probe_punch.gd`, not a suite):
  host + two joiners through the live relay, asserting each host↔client
  link reports direct, that records still cross that link, and that
  forcing one link down with `disconnect_direct` still delivers records for
  it over the relay fallback. This is the same shape as the host-quit probe
  used to find the start bug.
- **Determinism**: a relayed run and a punched run of one seed produce
  identical tick hashes.

## Transport security limits — documented, not claimed away

ENet carries **plaintext with no integrity protection**, and this feature
does not change that. The relay-issued key authenticates only the
`direct_hello`/`direct_ack` handshake; the records, checksums, control
messages and snapshots that follow are unmodified and unauthenticated on
both the relay and direct paths. The direct path additionally exposes the
peers' public endpoints to each other (the relay already saw them, so
confidentiality is unchanged; observability of host IPs by co-players is
new). Recent practitioner guidance — WebRTC stacks with DTLS-SRTP and
ICE, Tailscale's WireGuard tunnels — assumes encrypted authenticated
payloads, so "the design follows best practices" is true of the
*traversal mechanics* only, never of transport confidentiality or
integrity. Adding E2E encryption is out of scope here and would be a
separate design; until then the whole session is as authenticatable as
the plaintext protocol was before this feature.

## Out of scope

TURN/relay-of-last-resort beyond the existing relay, symmetric-NAT
prediction, more than one relay, IPv6 candidates, per-link delay
renegotiation, and any client–client direct link — the star is the whole
topology this feature builds — and E2E encryption of the transport. A
same-LAN candidate socket (a distinct registration kind per candidate so
both directions of each kind settle separately) is also deferred: the
relay is the working same-network path, and no field evidence yet shows
same-LAN-no-hairpin co-op common enough to double the per-link socket
count. Symmetric NATs that rewrite the port per
destination will simply fail to punch and stay relayed; that is acceptable
for a co-op game with a working relay fallback.

## History

The first draft of this mechanism (2026-09-03, superseded) specified a
single `ENetConnection`, shared by every link a peer needed, that would
both `connect_to_host` the relay's discovery endpoint and `connect_to_host`
each candidate peer in turn. A feasibility probe for that draft confirmed
simultaneous open works at all — two low-level `ENetConnection`s, each
`create_host_bound` and each `connect_to_host`ing the other, both raise
`EVENT_CONNECT` from `service()` within a few hundred ms, and the
high-level `ENetMultiplayerPeer` cannot be used for the punch because it
does not surface such a connection through `peer_connected` (it enforces a
server/client role).

Building the single-socket draft then hit a hard blocker: Godot's
`ENetConnection` allows only ONE outgoing `connect_to_host` for the
connection's whole life — a second call fails with "The ENetConnection is
already connected to a peer" (`modules/enet/enet_connection.cpp:87`,
confirmed by probe). It accepts many incoming connections, but dials out
only once, so a single socket cannot dial both the relay's discovery
endpoint and a peer, and for three or four players a peer could not dial
several others from one socket. The client punch code written against the
single-socket draft was reverted; the relay candidate-exchange logic
(`RelayRooms`, tested) and the constants stood and were carried forward.

That draft also left client–client punching implied ("a peer punching K
others holds K such sockets") without ever being in scope for the actual
session shape: records already reach every peer via the host's relay fan-out,
so a client only ever needs a direct link to the host. Restricting to the
star (this document's **Topology**) both sidesteps the one-connect-per-socket
ceiling — the host needs at most three sockets, a client exactly one — and
matches what the transport already does.

The corrected design in this document — one `ENetConnection` per
host↔client link, discovery as a one-way raw datagram to a `PacketPeerUDP`
endpoint that never spends a link's one connect, directed `(member,
target)` registration, and a relay-issued shared key authenticating the
direct handshake before either side trusts it — is what the plan below
builds. Nothing here is provisional.
