# Room-code relay: online co-op without port forwarding

## Why

Online co-op is a star: the host is the ENet server and relays every
client's input. That needs one machine the others can reach, which behind a
home router means port forwarding, which nobody does. A relay on a small
public server removes the requirement: every peer, host included, dials the
relay, and the relay forwards packets between the members of a room. Friends
join with a six-character code instead of an address.

## Decisions

- The relay is a headless Godot script in this repo, run under systemd on a
  DigitalOcean droplet (nyc3). Same ENet on both ends, so reliability,
  ordering and the two channels survive unchanged.
- The relay never decodes a game packet. It routes on a one-byte header.
- The game's host stays the authority. Nothing about lockstep, checksums,
  recovery, parking or endings changes; only how bytes reach a peer.
- Direct connect by address stays, for LAN play and for the loopback suite.
- The relay's address is a raw IP baked into `SessionRules`; replacing the
  droplet means a new release.

## 1. Wire format

Two kinds of packet cross a relay connection. Both are ENet packets on the
game's existing channels (0 control/input/relay, 1 snapshot) with the
game's existing transfer modes; the relay forwards each on the channel and
mode it arrived on.

**Routed packet** (any member ↔ relay): `u8 member` followed by the game's
bytes verbatim. From a member to the relay, `member` is the DESTINATION:
`1` the host, `2..4` a joiner, `0` broadcast to every other member (host
only; a joiner's broadcast is refused). From the relay to a member,
`member` is the SOURCE. Member ids are assigned by the relay per room:
the creator is `1`, joiners take the lowest free id in `2..4`. A packet
with an unknown destination is dropped silently (a member that just left).

**Relay op** (a member ↔ the relay itself): `u8 RELAY_PEER = 255` followed
by `var_to_bytes` of a primitive Dictionary, decoded with `bytes_to_var`
(never `_with_objects`), at most `RELAY_OP_MAX = 512` bytes, shape-checked:

| op | direction | body | meaning |
|---|---|---|---|
| `create` | member → relay | `{op}` | open a room; the sender becomes member 1 |
| `join` | member → relay | `{op, code}` | attach to the room; refused when unknown, full or closed |
| `room` | relay → member | `{op, code, member, members: [ids]}` | the answer to create/join |
| `refused` | relay → member | `{op, reason}` then disconnect | `unknown`, `full`, `closed`, `bad` |
| `joined` / `left` | relay → host | `{op, member}` | a joiner arrived / dropped |
| `kick` | host → relay | `{op, member}` | disconnect that member |
| `closed` | relay → joiners | `{op}` then disconnect | the host is gone |

A connection's first packet must be `create` or `join`; anything else, or
a routed packet before a `room` answer, disconnects it. A routed packet
larger than `SessionRules.SNAPSHOT_MAX + 1 + Protocol.ENVELOPE` disconnects
the sender. `RELAY_PROTOCOL = 1` rides in `create`/`join`; a mismatch is
`refused: bad`.

Codes: six characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (no 0/O/1/I),
drawn from a `RandomNumberGenerator` the relay randomises at start, unique
among live rooms. Joiners may type lower case; the relay upper-cases.

## 2. The relay process — `relay/relay_server.gd`

A `SceneTree` script: `godot --headless -s relay/relay_server.gd -- --port
43211`. An `ENetMultiplayerPeer` server, `RELAY_MAX_CONNECTIONS = 64`, two
channels, per-peer timeout `SessionRules.PEER_TIMEOUT_MS` like the game.
It polls every frame, reads each packet's peer, channel and bytes, and
hands them to a pure `RelayRooms` (`relay/relay_rooms.gd`, `RefCounted`,
no ENet) that returns a list of `[to_peer, channel, mode, bytes]` sends
and `[peer]` disconnects. The server performs them. Rooms live in
`RelayRooms`:

- `connect(peer)` / `disconnect(peer)`: a member leaving notifies the host
  (`left`); the host leaving sends `closed` to every joiner, disconnects
  them and deletes the room.
- `handle(peer, channel, mode, bytes) -> Array`: op or routed packet.
- `expire(now_ms)`: a room with no members for `ROOM_IDLE_MS = 600000` is
  deleted; a room whose creator never sent anything for 30 s is deleted.
- Diagnostics printed once a minute: rooms, members, packets forwarded,
  refusals.

`RelayRooms` is the tested unit; the server is thirty lines of ENet glue.

## 3. The game side — `Transport` relay mode

`Transport` keeps its API. New:

- `host_relayed(p_session) -> Error` and `join_relayed(code, p_session) ->
  Error` dial `SessionRules.RELAY_ADDRESS:RELAY_PORT` as an ENet client and
  send `create` / `join` when the ENet connection comes up. `relayed: bool`,
  `code: String` (the host's, shown by the lobby; the joiner's, kept for
  rejoin), `member: int`.
- `_put(target, …)` in relay mode prefixes the destination member byte
  (`TARGET_PEER_BROADCAST` → `0`); `poll()` strips the source byte and
  passes it to `_handle` as `from`, so `HOST_PEER = 1`, `bind_peer`,
  `slot_of_peer`, `send_control(to)`, `flush_relay`, `send_snapshot` and
  every validation path are unchanged.
- Relay ops arriving on `RELAY_PEER` drive the signals the lobby and run
  already listen to: `room` → the joiner emits `peer_joined(HOST_PEER)`
  (its "connected to host"); `joined` → the host emits `peer_joined(member)`;
  `left` → `peer_left(member)`; `closed` → `peer_left(HOST_PEER)` and
  `close()`. `drop_peer(member)` sends `kick`. ENet's own
  `peer_disconnected` in relay mode means the relay is gone: every bound
  peer is reported left.
- `rejoin()` in relay mode re-dials the relay and re-sends `join` with the
  stored code; the run's reconnect path (HELLO with session id and slot)
  is unchanged. A returning member may get a different member id; bindings
  are remade on HELLO as they are today.
- `connected()` in relay mode is true once the `room` answer arrived, not
  merely when ENet connected.

`SessionRules` gains `RELAY_ADDRESS` (the droplet's IP), `RELAY_PORT :=
43211`, `RELAY_DELAY := 5` (one tick for the extra hop; `DEFAULT_DELAY`
stays 4 for direct), `RELAY_PROTOCOL := 1`, `CODE_LENGTH := 6`,
`CODE_ALPHABET`. `NetworkSession.host_lobby` takes the delay it is given
today; the lobby passes `RELAY_DELAY` when hosting relayed.

The relay classes are pure and shared: `relay/relay_frame.gd`
(`RelayFrame`: `route(member, bytes)`, `unroute(bytes) -> [member, bytes]`,
`encode_op(dict)`, `decode_op(bytes) -> Dictionary` or `{}`, `is_code(s)`,
`normalise_code(s)`) is used by both the transport and `RelayRooms`.

## 4. The lobby

The link column becomes "LINK :: online co-op". Three buttons: **host**
(relayed; the default), **host LAN** (today's direct server on
`DEFAULT_PORT`), **join**. The single text field is "room code or address":
`RelayFrame.is_code(text)` picks relay, anything else direct. While hosting
relayed the status line shows the code at 22 px with a **copy** button
(`DisplayServer.clipboard_set`). `last_address` keeps storing whatever was
typed. Errors: `refused: unknown` reads "no room with that code";
`full` "that room is full"; a relay that does not answer within 5 s reads
"the relay did not answer" and the link is dropped.

## 5. Deployment

- `relay/install.sh` (run on the droplet as root, Ubuntu 24.04): downloads
  the Godot 4.7 Linux headless binary, creates user `rootkit`, installs the
  relay under `/opt/rootkit-relay`, a systemd unit `rootkit-relay.service`
  (restart always, `--port 43211`), and `ufw allow 43211/udp`.
- `relay/deploy.sh [--key-id N]`: `doctl compute droplet create rootkit-relay
  --region nyc3 --size s-1vcpu-512mb-10gb --image ubuntu-24-04-x64
  --ssh-keys N --wait`, waits for SSH, copies `relay/`, runs `install.sh`,
  prints the IP. Idempotent: an existing `rootkit-relay` droplet is reused
  and only the files and service are refreshed.
- After the first deploy, `RELAY_ADDRESS` is set to the printed IP and a
  release is cut (`v0.2.0`).

## 6. Testing

- `tests/test_relay_frame.gd` (pure): route/unroute round trip, the
  broadcast byte, op encode/decode, oversize and non-dictionary ops refused,
  `is_code` accepts six alphabet characters in either case and nothing else.
- `tests/test_relay_rooms.gd` (pure): create returns a unique code and
  member 1; join attaches with the lowest free id and notifies the host;
  a fifth join is refused `full`; an unknown code is refused; a routed
  packet reaches its destination with the source byte; a joiner's
  broadcast is refused; host disconnect closes the room; member disconnect
  notifies the host; kick disconnects; idle expiry; a routed packet before
  `room` disconnects; oversize disconnects.
- `tests/test_relay.gd` (needs UDP; sandbox off, like the loopback suite):
  starts a relay server on a loopback port in-process, hosts one transport
  relayed and joins another with the code, runs the HELLO/WELCOME lobby
  handshake through `NetworkSession`, sends inputs and a relay bundle, and
  asserts the ring on both ends; then drops the joiner and asserts the
  host saw `peer_left`; then closes the host and asserts the joiner saw
  the room close.
- `tools/run_tests.sh` gains the three suites; `CLAUDE.md`'s count moves.
- The codemap `net.md` gains the relay; the manual gains "play online".

## Out of scope

NAT hole-punching, a browser lobby, accounts or bans, more than one relay,
TLS or packet encryption (the game's packets are input records), and a DNS
name for the relay.
