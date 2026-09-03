# Design Spec: Relay Mesh Record Distribution

Deterministic lockstep over the room-code relay currently routes all records through the host:
`Client A -> Relay -> Host -> Relay -> Client B`.
This document specifies cutting the path to 2 legs:
`Client A -> Relay -> Client B`,
using the existing room-code relay without changing its protocol or deploying a server update.

---

## 1. Context & Motivation

### The 4-Leg Latency Tax
In relayed rooms, input latency is hardcoded to `SessionRules.RELAY_DELAY = 5` ticks (83.3 ms at 60 Hz).
Records travel 4 legs because `transport.gd:flush_relay` requires the host to gather all inputs and re-bundle them into a single `Protocol.Message.RELAY` packet sent to each client:
1. Client A sends `INPUT` to Relay (Leg 1).
2. Relay forwards to Host (Leg 2).
3. Host batches records and encodes bundle at `transport.gd:280`, broadcasting at `transport.gd:281-283` (Leg 3).
4. Relay delivers bundle to Client B (Leg 4).

At an observed ~18 ms RTT from client to relay (DigitalOcean Clifton, NJ), a 2-leg trip is ~18–25 ms. Four legs plus host tick-batching consumes the entire 83 ms budget, leaving zero headroom for packet jitter.

### Bandwidth vs. Latency Framing (Julio's Measurement)
Re-bundling is **not** a bandwidth problem:
- Host outbound traffic at 60 Hz with 4 players is 444 B/tick (~34 kB/s / 0.27 Mbps).
- A bundled packet (148 B) is actually ~12% smaller than 3 separate forwarded 42 B packets (504 B total) and halves the packet count (6 vs 12 packets/tick across the room).
- Therefore, meshing is justified strictly by **latency** (halving transit legs from 4 to 2, dropping link budget from 83 ms to 33–50 ms) and **resilience** (eliminating the host's upload connection as a single point of failure for peer-to-peer data).

---

## 2. Relay Architecture: Zero Server Changes

`relay/relay_rooms.gd:77-97` already routes member-to-member:
- Packet byte 0 is the destination member ID (`1..4`).
- Relay re-stamps byte 0 with the sender's member ID and forwards directly to the destination peer.
- Departed destination members are silently dropped.
- Only member `0` (room broadcast) is restricted to the host (`room["host"] == peer`).

Because member-addressed forwarding is already fully implemented on the relay server, **no relay server deploy or `RELAY_PROTOCOL` bump is required**.

---

## 3. Wire Protocol & Record Flow

### Direct Mode vs. Relayed Mode
- **Direct / LAN mode**: Unchanged. Clients only have a UDP socket to the host; the host continues to re-bundle and broadcast.
- **Relayed mode**:
  - Each peer dials the relay as an ENet client.
  - Member IDs are assigned by `RelayRooms` upon joining (`HOST_MEMBER = 1`, joiners `2..4`).
  - Peer bindings (`slot <-> member_id`) are distributed in `Protocol.Message.WELCOME`.

### Message Path
Instead of sending `INPUT` to host only:
1. Every peer submits its own local record to its local `Lockstep` ring at `executed + delay`.
2. Every peer emits its `INPUT` packet directly to every other connected room member via member-addressed routing (`_put(target_member, packet)`).
3. Periodic `CHECKSUM` packets continue to be sent to the host (member 1) over channel 0 (unreliable) at `tick % 60 == 0`.

### Changes by File & Symbol
- `scripts/net/protocol.gd`:
  - Bump `PROTOCOL` version (e.g. 3 -> 4) to ensure incompatible peers cleanly refuse connection.
  - In relayed mode, `RELAY` bundle packets are obsolete for input distribution; peers parse incoming raw `INPUT` messages directly from any bound member.
- `scripts/net/transport.gd`:
  - `bind_peer(peer, slot, member_id)`: Track member IDs for all slots in relayed mode.
  - `send_input(tick, move, card, target, offer)`: In relayed mode, loop over all known remote member IDs and call `_put(member, packet)`.
  - `flush_relay(tick)`: Bypassed/no-op in relayed mode. Host only stages its own input for direct/LAN sessions.
  - `_handle(...)`: When receiving `INPUT` on channel 0, decode and pass directly to `lockstep.submit(slot, tick, ...)`.
- `scripts/net/network_session.gd`:
  - Populate member ID mapping inside `descriptor["roster"]` so all peers know the destination member ID for each slot.

---

## 4. Invariants, Ordering, & Failure Modes

### Per-Peer FIFO Ordering
- ENet Channel 0 is reliable-ordered.
- Messages between any `(src_member, dst_member)` pair arrive in strict FIFO order.
- `Lockstep.submit(slot, tick, ...)` enforces first-store-wins immutability (`lockstep.gd:118-119`). Because each slot is authored by exactly one peer and arrives over a single FIFO channel, reordering is physically impossible.
- Interleaving across different slots is order-independent: the simulation tick does not step until all live slots have records for `executed` (`lockstep.gd:133-137`).

### Resync & Boundaries
- Host authority is preserved: host monitors checksums and detects desyncs at `tick % 60 == 0`.
- On desync, host issues `RESYNC` with boundary `R = executed + delay + 3`.
- `arm_boundary(R)` and `merge_window` operate on absolute tick numbers, identical to the current architecture.

### Audit Findings Addressed (Ricky & Joao)
- **Stall cascades impossible**: As verified by Joao, a late record delays ticks linearly and does not compound. The mesh reduces the arrival time of late records by 2 legs.
- **Snapshot hold transparency**: `_stalled_ticks` increments during snapshot recovery (`_holding_for_snapshot`) as well as input starvation. The soak harness must distinguish true input stalls from resync pauses.
- **Audit gaps acknowledged**: Discarded submit refusal booleans (`transport.gd:470, 486`) and checksum pruning (`lockstep.gd:290`) remain diagnostic gaps in the engine, but are neither exacerbated nor masked by 2-leg routing.

---

## 5. Soak Evidence Gate (Acceptance Gate)

Before landing the relay mesh changes in production, the soak harness (`tools/soak_net.gd`) must measure:

1. **Stall Duration Reduction**:
   - `stall_max` must strictly decrease at `peers = 4` compared to the 4-leg baseline.
   - `stall_p95` must drop by at least 30%.
2. **Determinism & Stability**:
   - `desyncs = 0` in healthy mode over 3600 ticks.
   - Fault injection mode must continue to reliably catch desyncs.
3. **Throughput & Frame Budget**:
   - Per-peer tick processing time must remain well within the 16.6 ms frame budget.

---

## 6. Future Work: Relay as DERP & Direct P2P

Direct peer-to-peer UDP connections (using the relay solely for DERP-style signaling and STUN/TURN fallback) would cut latency by an additional ~10–15 ms:
- Floor latency: ~17–33 ms (1–2 ticks) vs. ~33–50 ms (2–3 ticks) with relay mesh.
- Tradeoff: Direct connections require ICE/STUN hole punching, port mapping, and complex symmetric NAT fallbacks.
- **Decision**: Relay mesh is the mandatory prerequisite architecture for any future P2P mesh anyway, and captures >60% of the possible latency improvement with zero NAT risk and zero infrastructure changes. Direct P2P is deferred until relay mesh is proven in production.
