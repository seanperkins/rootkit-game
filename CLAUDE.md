# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

ROOTKIT — a Godot 4.7 / GDScript bullet heaven where the build system is the
hacking. No image assets, no font files, no `Area2D` anywhere.

## Commands

```bash
godot                          # play, from the project root
tools/run_tests.sh             # 56 suites + the perf gate
tools/run_tests.sh --fast      # skip the perf gate
godot --headless -s res://tests/test_build.gd     # one suite
godot -s res://tools/shot_cards.gd                # one screenshot -> /tmp/*.png (needs a window; see below)
python3 tools/build_manual.py  # regenerate site/ (gitignored)
```

**Screenshots cannot be taken `--headless`.** That flag selects the dummy
rendering driver: `get_texture()` is null and every `tools/shot_*.gd` now exits 1
saying so. Run them windowed; from a sandboxed shell that also needs
window-server access, which the Bash sandbox denies.

**`test_transport_loopback` and `test_relay` need real UDP on 127.0.0.1**, which the Bash
sandbox denies (`enet_socket_send` errors). Run it, and the full runner, with
the sandbox disabled. `tools/determinism_probe.gd` prints one `tick hash` per
tick; its output must be byte-identical across arm64 and x86_64.

**Always use `tools/run_tests.sh`, never call a suite by hand and trust it.** A
GDScript runtime error aborts only the function it happens in: the engine prints
`SCRIPT ERROR`, `_initialize` carries on, and a suite whose assertions never ran
exits 0 saying `PASS`. That has hidden two real breakages here. The runner reads
stderr and fails a suite on any `SCRIPT ERROR` or `Parse Error` whatever the
suite claims about itself.

**Live network diagnostics.** In a co-op session, `F1` toggles the HUD net
panel: per-slot RTT (measured by PING/PONG on channel 0, i.e. the path game
records use), relay-vs-punched path, per-slot receive rates, packet/record
counters, stalled % and the live tick rate — the number that reports "the game
runs at half speed". `-- --netlog` (after the binary/`--`) writes `net …`
lines — stall start/end, beats, desyncs, snapshots, and peer/park/return/
reconnect events — to the Godot log instead of only on screen.

## Architecture

`codemaps/` describes the shape — `architecture.md`, `audio.md`, `build.md`,
`combat.md`, `data.md`, `net.md`, `ui.md`. **Read those before a change that spans files.**
They are generated; do not hand-edit them, and put anything worth keeping here
instead.

What follows is not a description of the architecture. It is the set of rules
that architecture depends on, each of which has been broken at least once:

- **The pure layers stay pure.** `scripts/build/`, `scripts/run/feel.gd`,
  `scripts/audio/synth.gd`, `scripts/net/lockstep.gd`,
  `scripts/net/network_session.gd` and `scripts/net/protocol.gd` touch no scene
  tree, no globals and no engine singleton beyond `Resource`/`RefCounted`. Every
  one of them is driven directly by a suite with no viewport, and that is the
  only reason those suites can exist. `scripts/net/transport.gd` is the ONLY
  class that touches ENet; nothing below the world guard inspects it.
- **The simulation never holds a node reference.** Audio and music are reached
  by DRAINING (`feel.sfx`) or POLLING (`run.threat()`), never by calling out.
  Reverse that direction and the tick stops being reachable headless.
- **All combat resolves in one ordered tick in `run.gd:_physics_process`, never
  inside a callback.** Adding a step means adding a call there, in the right
  place — not a signal.
- **Below the world guard the WORLD steps; above it run presentation, input
  intake and input application — in that order.** `_present` must survive
  `paused`/`user_paused`/`not alive`/`won`, because the hitstop triggers set one
  of those flags on the frame they fire. The lockstep ring is consumed above the
  guard too: one tick's records are taken and applied — movement and aim into `inputs` and `aims`,
  choices into the per-slot offers, deadlines resolved — whether or not the
  world then steps, so an open card screen holds the world, never the input
  stream. The tick reads no device, clock or connection; it reads records. A
  card or fusion pick is a STAGED input record, not a callback: `choose_card`
  and friends stage it, the next submit carries it, and the tick that consumes
  that record applies it. The hitstop is a tick count above the guard, and no
  code writes `Engine.time_scale`.
- **Entities are packed arrays over a spatial grid**, not nodes, and
  `Population.despawn` swap-removes the tail into the freed slot. See the
  parallel-array invariant below; it is the one that keeps costing money.
- **The whole 3-subnet campaign is one terrain grid**, plotted before the first
  frame. `terrain.current` is the only thing that changes; nothing is generated
  under the player and nothing teleports.
- **Solo is a one-slot session.** Every per-player field is a `MAX_PLAYERS`
  array indexed by slot; `slot_state` says LIVE/DEAD/ABSENT; a reader that
  wants "the player" must say which slot by a census rule (nearest LIVE,
  owner, every LIVE, block holder) — `local_slot` and `view_slot` are for
  presentation only. Every RNG, sheet and starting build derives from the
  session descriptor, never from a save; `save.json` is read only to build
  the local slot's counters and to bank the local slot's own deltas.
- **Roster changes apply at the tick they name, never on arrival.** ABSENT
  before consuming T, PRESENT after consuming R, on every peer alike. Only the
  host's END ends a session; a local death or win is a CANDIDATE that holds the
  world below the guard while the ring keeps consuming above it. The host is
  the authority in a desync, and a snapshot is primitives only, validated
  field by field before a single write. Simulation state lives in the
  manifest (`STATE_FIELDS`) or is classified in `NOT_IN_MANIFEST`;
  `test_manifest` fails on a var in neither.
- **Presentation aged above the guard must NEVER be in the HASH manifest.**
  `_present` runs on the VARIABLE frame delta, which differs across peers, so
  anything `_age_fx` (or any presentation code) decays by wall-clock time
  diverges peer to peer. If such a field is hashed, the checksum compare reads
  a false desync and every co-op session breaks the moment two peers' frame
  timing drifts — the divergence wanders tick to tick, so it looks like a
  transport bug, not a manifest one. `_hit_flash` was hashed and did exactly
  this. A presentation field belongs in `NOT_IN_MANIFEST`, even a per-entity
  parallel array that `_relocate_enemy`/`_spawn_enemy_state` still maintain for
  rendering. `test_manifest` pins it: aging a busy run's whole presentation
  layer must not move `_state_hash`.

## Invariants that break quietly

These are load-bearing and their failure modes are silent. Most are documented at
the site; this is the index.

- **`Module.VectorKind` / `TriggerKind` are append-only.** Values are stored on
  modules; inserting in the middle repoints every module defined above it.
- **`EnemyTable.ICE` is an index into `all()`, so `ice` must stay the last row.**
  The boss spawn, the win condition and the flip guard all read it.
- **`Module.STAT_KEYS` is the only legal stat-key set.** Validate against it, not
  against "fields of `ResolvedExploit`".
- **`ResolvedExploit.cadence_mult` defaults to `1.0`**, alone among its fields.
  Anything that resets fields generically breaks on it. `pierce`, `chain_count`,
  `botnet_cap`, `orbit_count` and `burst` are untyped on purpose — they
  accumulate as float and `Compiler.build` floors them once at the end.
- **Defensive stats fold by MAX, offensive by SUM.** A module id may occupy any
  number of slots, so summing `ward_*` / `lifesteal` / `slow_*` / `shield` would
  buy magnitude at zero uptime cost. See `Compiler.MAX_FOLD_KEYS`.
- **`SaveGame` holds deltas; the compiler wants absolutes.** Everything must pass
  through `PlayerStats.mults()`, or a +0.40 rank scales damage *down* by 60%.
  Player-sheet stats (`SHEET_EFFECT`) go straight to `run.gd` and must never
  reach the compiler — that separation is what stops a shop upgrade being
  silently delivered as an exploit stat.
- **`Loadout.compile_all` is the only runtime caller of `Compiler.build`.** A
  multiplier that does not go through `Loadout.mult` reaches no exploit at all.
- **The last INTERVAL trigger cannot be displaced** — an all-event loadout could
  never fire.
- **Per-enemy arrays need BOTH halves of the slot invariant.** *Reset on spawn*:
  `Population.spawn` recycles slots, so a stale phase means an enemy commits to a
  dash it never wound up for — use `_clear_ai` / `_spawn_enemy_state`. *Relocate
  on despawn*: `Population.despawn` swap-removes the tail into the freed slot for
  its OWN arrays only, so every parallel array must follow, via
  `_relocate_enemy(i, last)`. There are **two** despawn sites — `_step9_recycle`
  and `_step2d_collapse`, whose `is_void` predicate is conditional and therefore
  not tail-only — and `_step2d_collapse` relocated nothing at all until the
  polish pass. `test_arrivals` asserts the rule structurally: every
  middle-of-pool `enemies.despawn` must relocate first. `_order` is the one
  deliberate exception, because `_depth_sort` refills it wholesale each tick.
- **An entity is adjudicated exactly once per tick, then CLOSED**, from the
  totals of the pass it was first marked in. Flip beats death. `ON_HIT`,
  `ON_KILL` and `ON_DAMAGE_TAKEN` are three different conditions — do not fire
  them from one loop.
- **Every id in `meta_screen.BUFFS` must exist in `SaveGame._default()["buffs"]`.**
  `_refresh` indexes it with no `.get`, so a missing name crashes the shop on open.
- **Every id passed to `feel.emit` must exist in `Synth.build_bank()`.** The same
  shape as the line above, with a worse failure: `sfx.play` returns silently on an
  unknown id, so the result is a sound that never plays rather than a crash.
  Fire ids are derived from `Module.VectorKind` precisely so a new vector kind
  cannot mint one the bank has never heard of. `test_audio_events` greps `run.gd`
  for emit sites rather than keeping a list — **an id reached through a lookup
  table is invisible to that grep**, so a new table of ids must be added to the
  suite's indirect-site scan the way `HIT_SOUNDS` was.
- **A lockstep session runs one build.** `SessionRules.PROTOCOL` refuses a
  differently-built *protocol* at the envelope, but two builds on the same
  protocol can still diverge in game logic — so the handshake also carries the
  build version: HELLO/WELCOME/REFUSED plus the descriptor's `version` (the
  tag stamped into `application/config/version`, "dev" in editor builds).
  A same-protocol skew is refused at `admit` (`ADMIT_VERSION_MISMATCH`,
  distinct from a plain -1) and at `apply_welcome`/`apply_start`
  (`reject_reason = "version"`), so the lobby says "update" instead of the
  run finding a desync later. Any HELLO/WELCOME/REFUSED path must carry the
  version — a reconnect HELLO without it is refused by the updated host.
- **The update channel is HTTPS + RSA-4096, never a plain hash.** The feed is
  `latest.json` on the GitHub Release; `tools/update_feed.sh` signs each
  archive's SHA-256 with the private key (`~/.config/rootkit/update_sign.key`
  locally, Actions secret `UPDATE_SIGN_KEY` as base64 PEM) and the game
  verifies with the public key embedded in `UpdateFeed.PUBKEY` before it will
  touch a file. The private key never ships; rotate only in a release whose
  clients still verify with the old key. The macOS bundle is replaced whole by
  the platform helper (`ditto -x -k` — never `ZIPReader`, which loses mode bits
  and AppleDouble metadata and invalidates a signed bundle), and a build that
  cannot write its own location (App Translocation) is told to move to
  /Applications first. Install now or apply-on-quit only — never mid-session.
- **The relay and client ship the same `RELAY_PROTOCOL`.** A punched leg is a
  per-host↔client direct socket with the relay as the always-live fallback.
  The path seam replays a bounded one-ring window of tick-addressed records:
  client INPUT and host RELAY bundles — never CONTROL/SNAPSHOT, which are
  not duplicate-idempotent, and never CHECKSUM, which self-heals and would
  evict an unrecoverable INPUT from the shared window. Duplicate Lockstep
  submissions are benign wherever a record arrives twice, and the host
  re-forwards (stages) only newly stored INPUT. `transport.gd` is still
  the only ENet-touching class; the tick still reads records only.
- **`SaveGame.MILESTONES` is the single source for the unlock ladder.** The shop's
  requirement text reads it via `milestone_text`; do not hardcode a second copy.
- **`save.json` is user-editable and treated as hostile.** The `maxf(0.0, …)`
  guards in `PlayerStats.mitigate` and the key-dropping in `sheet()`/`mults()`
  are there for that reason, not habit. So is `SaveGame._num`, which every
  numeric read goes through: `float()`/`int()` are not total, and a Dictionary,
  Array or `null` value aborts `_sanitise` — which leaves `_cache` unassigned and
  cascades into every caller that indexes the result. `clampf` is not a
  finiteness check (`clampf(NAN, 0, 2)` is `nan`), and both `version` reads sit
  in `_read`, outside `_sanitise` and therefore outside `_num`'s reach.
  `PREF_RANGES` is clamped on write as well as read, because `JSON.stringify`
  turns a NaN into `null` and an INF into `1e99999` — both valid JSON, so a bad
  value is persisted intact and detonates on the next load. See
  `codemaps/data.md` for the full guard table.

## Balance rationale

Numbers in `data/` carry the reasoning that set them in comments beside them.
Two that drive the rest:

- Enemy integrity scales on both axes (`SpawnDirector.hp_mult`) because a rank
  buys damage linearly — with constant HP everything one-shot forever past 34.
- Five exploit rows fire up to two-thirds more than the three they replaced,
  so `SpawnDirector.HP_ROWS` (1.15) scales every enemy's integrity. It was
  originally 1.40, set by the perf gate's coverage pin rather than by feel —
  a LOAD instrument choosing a balance number that is paid from the first
  tick, when the board holds one rank-1 row and none of the five it prices.
  The first-subnet retune halved that tax and re-pinned the gate.
- **Difficulty is retuned on five axes at once, and they are coupled.** The
  wave rates are the density axis (peak concurrent solo spawn 6.6/s, 1288
  spawns a subnet), `HP_ROWS` and `EnemyTable`'s ICE row are the per-enemy
  axis, `PlayerStats.BASE` integrity/defense is the attrition budget, and
  `BASE.pickup_radius` decides whether the XP a subnet drops is ever
  collected — a fighting subnet holds no regeneration, so the pool the player
  starts with is very nearly the pool they finish with. Moving any one of
  them moves the perf gate's coverage pin; re-measure and re-pin with a
  written reason rather than lowering a floor quietly.
- Terrain density is **flat** across subnets. A cramped late arena reads as
  cramped, not hard; escalation lives in enemy HP and the wave table.

Design specs and implementation plans are in `docs/superpowers/`, one pair per
feature. The original spec — including the architecture reversal from pooled
`Area2D` to packed arrays — is
`docs/superpowers/specs/2026-08-29-rootkit-bullet-heaven-design.md`.
