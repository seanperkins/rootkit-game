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
a **second ENet socket** (an `ENetConnection` bound to an OS-assigned local
port) that both listens and dials. The
relay tells each member the others' candidate addresses (discovered as
below). Both ends then send to each other at once; the first packet from
each opens its NAT's mapping for the other's reply. This is the standard
simultaneous-open punch, with the relay's discovery endpoint acting as the
STUN server.

### Candidates and reflexive discovery (corrected 2026-09-03)

The address the relay sees for a peer's RELAY connection is NOT the address
other peers can punch to: the punch uses a SEPARATE socket with its own NAT
mapping. So each peer's punch socket must have its own public mapping
observed. Two sound ways:

1. **Discovery endpoint (chosen, lower risk).** The relay opens a SECOND
   `ENetConnection` host on `PUNCH_DISCOVERY_PORT`. Each peer's punch socket
   `connect_to_host`s it and the relay replies with the `host:port` it
   observed — that peer's reflexive punch mapping. The relay hands that to
   the others. This leaves the working relay client (`ENetMultiplayerPeer`)
   untouched. It is correct for endpoint-independent (full-cone / restricted
   / port-restricted) NATs, which is most home routers; symmetric NATs give a
   different mapping per destination and simply fail to punch, staying
   relayed — acceptable.
2. Unify relay + punch on one `ENetConnection` so the relay sees the punch
   mapping directly. Cleaner but a full rewrite of the just-shipped relay
   client; rejected for risk.

The **local** candidate (the peer's LAN `ip` and its actual punch port) is
also carried, for two peers on the same network. The punch port is
OS-ASSIGNED (bind 0), not a fixed constant: three processes on one machine
must coexist for local testing, and the mapping is discovered, not assumed.
The punch tries every candidate for a peer in parallel and keeps the first
that completes an ENet handshake.

### Signalling ops (relay → member, member → relay)

Added to the op table, same envelope and `RELAY_OP_MAX` bound as the rest:

| op | direction | body | meaning |
|---|---|---|---|
| `punch` | relay → member | `{op, peers: [[member, host, port, local_host, local_port], …]}` | every other member's candidates; sent once the room has ≥2 members and again on each join |
| `punched` | member → relay | `{op, member}` | this end has a direct link to that member; relay notes it (diagnostics only) |

The relay learns a member's reflexive `host:port` from its punch socket's
connection to `PUNCH_DISCOVERY_PORT` (see above), not from the relay
connection. `local_host`/`local_port` are the optional self-report,
sanitised exactly like `last_address` (the `hostname` whitelist, length
cap) and dropped if malformed — never trusted as a route without a
completed handshake.

### The second socket and path selection

`transport.gd` in relay mode gains:

- `_punch: ENetConnection` — `create_host_bound("0.0.0.0", 0, …)` (an
  OS-assigned port) that both accepts and `connect_to_host`s each candidate.
  Proven to do simultaneous open (see the plan's "Proven approach").
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
| `PUNCH_DISCOVERY_PORT` | 43212 | relay's reflexive-discovery endpoint; the punch socket binds an OS-assigned port |
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
  on OS-assigned ports, a record crosses the direct socket, and path selection
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
