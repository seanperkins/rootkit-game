class_name SessionRules extends RefCounted

## Shared, immutable constants for the deterministic simulation and the co-op
## session protocol. PURE: no scene tree, no engine singleton beyond RefCounted.
## Every peer compiles the same values, so a number here is part of the wire
## contract as much as it is a tuning knob — change one and every peer must.

## Wire-protocol version. Two peers with different values cannot share a
## simulation, so the handshake refuses a mismatch and the descriptor carries it.
const PROTOCOL := 4   # 2: the input record carries an aim; 3: five exploit rows;
                      # 4: the session tracks the game BUILD version
                      # (HELLO/WELCOME/REFUSED), so a skew refuses cleanly
                      # instead of desyncing.

## Longest a player display name may be, in characters. A roster row past this is
## rejected by descriptor validation rather than truncated — a hostile peer does
## not get to smuggle length past the check by padding.
const NAME_MAX := 24

## Longest the game build version string may be, in characters — the value
## `config/version` carries in release builds and "dev" in editor builds. It
## rides the HELLO/WELCOME handshake and the session descriptor; peers at
## different values refuse to share a session.
const VERSION_MAX := 32

## Longest a REFUSED reason string may be, in characters.
const REFUSED_REASON_MAX := 32

## The single simulation step. The tick is 60 Hz and nothing below the world
## guard reads a wall clock, so every simulation step ages by exactly this,
## regardless of the frame delta the engine hands `_physics_process`.
const TICK_DT := 1.0 / 60.0

## A hitstop freezes the world for this many ticks while presentation keeps
## running above the guard. The old wall-clock hitstop was 60 ms; four ticks is
## 66.7 ms, the same beat rounded up to a whole tick so it is deterministic.
const HITSTOP_TICKS := 4

## Fixed party size. Players are four parallel-array slots; unused slots are
## ABSENT. The roster in the session descriptor decides which become LIVE.
const MAX_PLAYERS := 4

## Input delay in ticks: a record submitted for tick T is consumed at T only
## once every peer's record for T has arrived, so each peer runs `delay` ticks
## of local input ahead of the tick it executes. The default tolerates typical
## internet latency; the LAN preset trims a tick.
const DEFAULT_DELAY := 4
const LAN_DELAY := 3

## How long an unresolved card/fusion offer waits before it auto-resolves to the
## first option: 1800 ticks is 30 s, long enough to read, short enough that one
## idle peer cannot stall the party forever.
const CHOICE_TIMEOUT_TICKS := 1800

## Each peer reports a checksum of its executed state this often, in ticks, so a
## divergence is caught within a second of happening.
const CHECKSUM_INTERVAL := 60

## After this many consecutive ticks where lockstep cannot advance — a required
## record has not arrived — the HUD names the slots being waited on.
const STALL_NOTICE := 20

## The largest legal magnitude of a single movement input component. A record
## whose move has a component beyond this (or a non-finite one) is sanitised to
## Vector2.ZERO on application, so a hostile peer cannot teleport by inflating
## its input. sqrt(2)/... — one axis of a unit diagonal plus headroom.
const MOVE_COMPONENT_MAX := 1.3635

## The party grid never spans more than a MAX_WINDOW-unit square, and no two LIVE
## players may separate past LEASH world units. The window floor lives in run.gd.
const MAX_WINDOW := 7200
const LEASH := MAX_WINDOW - 3200

## Hard ceiling on a decoded snapshot, in bytes. A worst-case full-manifest
## snapshot must fit under this; a packet claiming more is rejected before any
## allocation.
const SNAPSHOT_MAX := 1 << 20

## Snapshot payload version. A peer refuses any other value rather than guessing
## at a layout.
const SNAPSHOT_VERSION := 1

## A peer that has sent this many packets the codec refused is disconnected.
## Twenty, not one: a single corrupt datagram is noise, twenty is a bad actor
## or a broken build.
const BAD_PACKETS := 20

## Silence from a peer for this long parks its slot. ENet's own default is
## longer, so the transport applies this to every packet peer on connect.
const PEER_TIMEOUT_MS := 3000

## Largest control-message body a peer may send. Descriptors and rosters are
## small; anything near this is not a control message.
const CONTROL_MAX := 16384

## Longest a host address string may be, in characters.
const ADDRESS_MAX := 64

## The UDP port a host listens on. One port: direct-IP play, no matchmaking.
const DEFAULT_PORT := 43210

## The room-code relay. Every peer, host included, dials RELAY_ADDRESS as an
## ENet client; the relay forwards packets between the members of a room on
## a one-byte route (relay/relay_frame.gd). A raw IP, baked in: replacing
## the droplet means a release. Set from relay/deploy.sh's printed address.
const RELAY_ADDRESS := "68.183.52.156"
const RELAY_PORT := 43211
## One extra tick of input delay for the hop through the relay.
const RELAY_DELAY := 5
const RELAY_PROTOCOL := 2
const RELAY_OP_MAX := 512
const RELAY_MAX_CONNECTIONS := 64
const ROOM_IDLE_MS := 600000
## NAT hole punching (phase two). The relay's reflexive-discovery endpoint;
## a peer's punch socket connects to it so the relay observes that socket's
## public mapping and hands it to the other members. The punch socket itself
## binds an OS-assigned port (three processes on one machine must coexist).
## RELAY_PROTOCOL bumps to 2 only at the coordinated relay+client release, so
## a punch-capable client and a non-punch relay refuse each other cleanly.
const PUNCH_DISCOVERY_PORT := 43212
## A punch that has not completed a handshake by this stays relayed.
const PUNCH_TIMEOUT_MS := 3000
const CODE_LENGTH := 6
## No 0/O/1/I: a code is read aloud and typed by a friend.
const CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
