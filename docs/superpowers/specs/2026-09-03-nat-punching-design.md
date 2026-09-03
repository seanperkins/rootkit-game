# NAT hole punching — design

Phase two of the relay work. The relay ships and works, but every packet
takes two hops through a New York droplet: a joiner's record reaches the
host via the relay and back, so the round trip that lockstep waits on is
client → relay → host and the answer host → relay → client. `RELAY_DELAY`
is 5 ticks precisely to hide that hop, and it is felt as lag. Hole punching
lets two peers behind consumer NATs exchange packets directly, cutting the
hop out for the pairs it works on, while the relay stays as the fallback
and the signalling channel.

## What stays

- **The relay stays.** It is the rendezvous, the room registry and the
  fallback path. Nothing about room codes, `create`/`join`/`room`, the
  member ids (host 1, joiners 2..4) or the one-byte route changes.
- **The simulation never learns any of this.** Punching lives entirely in
  `transport.gd` and the relay; the run still polls the transport above the
  guard and reads records from the ring. `lockstep`, `network_session` and
  `protocol` stay pure and untouched, except for the new relay ops and the
  constants below.
- **Direct connect by address stays** for LAN and the loopback suites.
- **Lockstep is a full mesh of records already.** The host relays every
  member's record to every other member. Punching changes only WHICH
  socket a given pair uses to carry those bytes, never the record flow, the
  ordering or the hashes.

## The mechanism

Each peer already holds one ENet client socket, to the relay. Punching adds
a **second ENet socket bound to a fixed local port**
(`SessionRules.PUNCH_PORT`, default 43212) that both listens and dials. The
relay, which sees every member's public `address:port` as ENet reports it
on connect, tells each member the others' candidate addresses. Both ends
then send to each other at once; the first packet from each opens its NAT's
mapping for the other's reply. This is the standard simultaneous-open
"STUN-less" punch: the relay is the STUN server because it already sees the
reflexive address.

### Candidates

For each member the relay knows two things: the **reflexive** address (the
`host:port` its relay connection arrived from, i.e. what its NAT presents to
the internet) and, optionally, a **local** address the member self-reports
in its `create`/`join` (its LAN `ip:PUNCH_PORT`, for two peers on the same
network). Both are candidates. The punch tries every candidate for a peer
in parallel and keeps the first that completes an ENet handshake.

### Signalling ops (relay → member, member → relay)

Added to the op table, same envelope and `RELAY_OP_MAX` bound as the rest:

| op | direction | body | meaning |
|---|---|---|---|
| `punch` | relay → member | `{op, peers: [[member, host, port, local_host, local_port], …]}` | every other member's candidates; sent once the room has ≥2 members and again on each join |
| `punched` | member → relay | `{op, member}` | this end has a direct link to that member; relay notes it (diagnostics only) |

The relay learns a member's reflexive `host:port` from
`ENetMultiplayerPeer`/`ENetConnection` on connect (the same place the
per-peer timeout is set). `local_host`/`local_port` are the optional
self-report, sanitised exactly like `last_address` (the `hostname`
whitelist, length cap) and dropped if malformed — never trusted as a route
without a completed handshake.

### The second socket and path selection

`transport.gd` in relay mode gains:

- `_punch_peer: ENetMultiplayerPeer` — a second peer created with
  `create_server` on `PUNCH_PORT` AND used to `create_client` toward each
  candidate. (ENet can both listen and connect on one host; if the Godot
  wrapper resists, two `ENetConnection`s on one bound socket via the
  lower-level API.)
- `_direct: Dictionary` — `member → true` once a direct link to that member
  has completed its handshake.
- Path selection in `_put`/`flush_relay`: for a destination member with a
  direct link, send on the direct socket; otherwise the relay, exactly as
  today. **The receive side accepts a record from either path** — a record
  is a record; `_handle` already keys everything by the member id in the
  route byte / the direct peer binding, not by which socket it arrived on.

Because path is chosen per destination and records are idempotent by
`(slot, tick)` in the ring, a pair can migrate from relayed to direct
mid-session with zero seam: a record that crosses both ways during the
switch is submitted once and the duplicate refused, which `lockstep.submit`
already does.

### Fallback and liveness

- A punch that does not complete within `PUNCH_TIMEOUT_MS` (default 3000,
  the peer timeout) is abandoned; that pair stays relayed. No user-visible
  failure — the relay path was already working.
- A direct link that later goes silent past `PEER_TIMEOUT_MS` is dropped
  back to the relay for that member: clear `_direct[member]`, keep playing.
  The relay link is held open for the whole session precisely so this is
  always available.
- The host's END, parking, reconnect and snapshot paths are unchanged: they
  ride whatever path is current for the member, and all of them are already
  keyed by member/slot, not socket.

## Constants (`data/session_rules.gd`)

| Const | Value | Why |
|---|---|---|
| `PUNCH_PORT` | 43212 | the fixed local port the second socket binds; one above `RELAY_PORT` |
| `PUNCH_TIMEOUT_MS` | 3000 | give up a punch and stay relayed; matches `PEER_TIMEOUT_MS` |
| `RELAY_PROTOCOL` | → 2 | the op set grows, so the relay protocol bumps; a mismatch is `refused: bad` |

`RELAY_DELAY` stays 5 for now: the delay is set at lobby time, before any
punch has completed, and lowering it per-pair mid-session would desync the
input schedule. A later pass can negotiate a lower delay once every pair is
direct; out of scope here.

## Determinism

Punching cannot change a single hash. The evidence: records are keyed by
`(slot, tick)` and folded identically whatever socket carried them; the
delay is fixed for the session; path selection is local to each sender and
invisible below the guard. `tools/determinism_probe.gd` must still print
byte-identical tick hashes across a relayed run and a punched run of the
same seed — that is the acceptance gate.

## Testing

- **`test_punch_rooms`** (pure, loopback): the relay hands each member the
  others' candidates on the second join; `punched` is recorded; a
  malformed `local_host` is dropped.
- **`test_transport_punch`** (real UDP on loopback): two transports punch
  on `PUNCH_PORT`, a record crosses the direct socket, and path selection
  prefers direct once `_direct` is set and falls back when it is cleared.
- **A three-process manual probe** (`tools/probe_punch.gd`, not a suite):
  host + two joiners through the live relay, asserting each pair reports a
  direct link and that records still cross when a direct link is forced
  down. This is the same shape as the host-quit probe used to find the
  start bug.
- **Determinism**: a relayed run and a punched run of one seed produce
  identical tick hashes.

## Out of scope

TURN/relay-of-last-resort beyond the existing relay, symmetric-NAT
prediction, more than one relay, IPv6 candidates, and per-pair delay
renegotiation. Symmetric NATs that rewrite the port per destination will
simply fail to punch and stay relayed; that is acceptable for a co-op game
with a working relay fallback.
