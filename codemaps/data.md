> Generated: 2026-09-04 | Token-lean format for LLM context

# Data tables and persistence

Both registries are **defined in code, not scanned from `.tres`**: scanning
`data/modules/` works in the editor and in CI but not in an exported build
(Godot converts text resources to binary by default), so every player would
get an empty card pool.

## `data/enemy_table.gd` — `EnemyTable`

`enum Behaviour { CHASE, CHARGER, FLANKER, SUPPORT, AMBUSHER, RANGED }`.
`EnemyType`: id, glyph, color, integrity, speed, corruption_threshold,
contact_damage, shard_value, behaviour(=CHASE).

| # | id | glyph | HP | speed | corrupt | dmg | shard | behaviour |
|---|---|---|---|---|---|---|---|---|
| 0 | daemon | 0 | 10 | 74 | 10 | 7 | 1 | CHASE |
| 1 | firewall | 1 | 34 | 50 | 20 | 12 | 4 | CHASE |
| 2 | worm | 2 | 6 | 118 | 6 | 5 | 2 | CHASE |
| 3 | sentinel | 5 | 46 | 78 | 26 | 16 | 3 | CHARGER |
| 4 | tracer | 6 | 14 | 124 | 12 | 6 | 2 | FLANKER |
| 5 | watchdog | 7 | 70 | 44 | 34 | 4 | 5 | SUPPORT |
| 6 | rootkit | 8 | 34 | 96 | 22 | 18 | 3 | AMBUSHER |
| 7 | probe | 9 | 16 | 52 | 14 | 3 | 2 | RANGED |
| 8 | fork_bomb | 10 | 170 | 82 | 90 | 20 | 12 | CHARGER |
| 9 | packet_filter | 11 | 260 | 40 | 120 | 14 | 14 | SUPPORT |
| 10 | null_ptr | 12 | 190 | 104 | 100 | 22 | 13 | AMBUSHER |
| 11 | kernel_panic | 13 | 240 | 48 | 110 | 18 | 16 | RANGED |
| 12 | **ice** | 3 | 550 | 46 | 1e18 | 22 | 0 | CHASE |

Rows 8–11 are the mini-bosses (between firewall and ICE: set-pieces, not
bosses). ICE's corruption threshold is effectively infinite — flipping it
would bypass the kill-to-win condition — and `EnemyTable.ICE := 12` is an
index, so ICE must stay last. Integrity is 550, not the round 700 an earlier
pass used: the boss arrives at `SUBNET_SECONDS`, where the ramp is already at
its ceiling, so 700 read as a wall on subnet 1 and a formality on subnet 3.

## `data/module_table.gd` — `ModuleTable`

30 modules (8 VECTOR / 7 TRIGGER / 15 PAYLOAD); 11 ship locked, 19 unlocked at
start (5 / 3 / 11). `all()`, `by_id()`, `starting_unlocked()`.

```gdscript
LOCKED = [beam, on_damage_taken, worm, landmine, mirror, checksum,
          on_low_integrity, on_flip, on_level_up, heap_spray, tarpit]
```

Roughly half the breadth ships locked because a level-up still shows three
cards: going 18 → 30 modules halves the odds of drawing what a build wants.

### VECTOR (8) — one module per `VectorKind`

| id | kind | stats | pattern |
|---|---|---|---|
| broadcast | BROADCAST | dmg 3.5, radius 90, cd 0.85 | ring around the owner |
| packet | PACKET | dmg 6, speed 420, cd 0.5, travel 640 | straight shot along `player_facing`; no target pick unless `homing` |
| chain | CHAIN | dmg 5, chain 2, radius 170, cd 0.9 | `_pick_target` then hops |
| beam (locked) | BEAM | dmg 3.5, pierce 3, radius 240, cd 0.6 | capsule along facing, half-width 22, fires whether or not anything is in it |
| spike | CONE | dmg 9, radius 150, cd 0.75 | 90° wedge along facing |
| landmine (locked) | MINE | dmg 16, radius 130, cd 1.9 · `aoe` | drops `MINE_DROP 86` behind the owner |
| bounce | PULSE | dmg 1.4, radius 150, cd 1.5, knockback 320 | ring with knockback |
| mirror (locked) | ORBIT | dmg 4, radius 90, cd 2.2, orbit 3 | orbiters, one cadence |

`bounce`'s radius came down from 190 to 150: `VECTOR_RADIUS_RANK` grows a
vector's radius as a fraction of its own base, so the widest vector also grew
fastest in absolute terms (47.5px/rank against spike's 37.5px). Damage came
down with it (2.0 → 1.4) and cooldown went UP (1.1s → 1.5s), so the vector
now pays a real defensive-vector price for its payoff — knockback, not
damage, is what the module is for. Base damage overall sits ~30% below its
first pass (payloads ~20%) — a rank buys damage linearly, and
`SpawnDirector.hp_mult` is the load-bearing half of that fix.

### TRIGGER (7) — paid on the axis its frequency suits

| id | cadence_mult | burst | other |
|---|---|---|---|
| interval | **1.00** | — | the baseline, not a bonus; never idles |
| on_kill | 0.70 | — | dmg 3 |
| on_hit | 0.62 | — | dmg 1 |
| on_damage_taken (locked) | 0.90 | 3 | dmg 8, radius 40 |
| on_low_integrity (locked) | 1.00 | 5 | dmg 6 |
| on_flip (locked) | 0.74 | — | corruption 2 · `corruption` |
| on_level_up (locked) | 1.00 | 8 | — |

Frequent triggers are paid in cadence, rare in burst; `on_flip` is paid in
corruption, the resource its own build runs on. `cadence_mult` is legal
**only on a TRIGGER** (`Compiler.validate` rejects it elsewhere); a bare row
with no trigger fires on a built-in `Compiler.BARE_CADENCE` (1.50) penalty.

### PAYLOAD (15)

| id | stats |
|---|---|
| buffer_overflow | dmg 5.5 |
| fork_bomb | dmg 4, radius 60 · `aoe` |
| corrupt | corruption 4 · `corruption` |
| keylog | lifesteal 0.4 |
| worm (locked) | corruption 2, chain 1 · `corruption` |
| botnet_expand (`fork()`) | botnet_cap 2 |
| overclock | dmg 2, shield 12, shield_rearm 1.6 |
| harden | ward_armor 1.2 / 2.0s |
| sandbox | ward_defense 10 / 3.0s |
| nice | ward_clock_speed 12 / 1.5s |
| bitmask | pierce 1 |
| race_condition | shield 10, shield_rearm 2.0 |
| heap_spray (locked) | chain 1, radius 30 |
| tarpit (locked) | slow 0.35 / 1.5s · `slow` |
| checksum (locked) | shield 26, shield_rearm 2.6 |

`overclock` and `race_condition` are self-contained fast-shield payloads, like
`checksum` but with a smaller pool for a faster rearm — one payload slot means
none of the three can borrow another's shield. `shield_rearm` is **unranked**
on all three (rank buys magnitude, never cadence); neither carries
`cadence_mult` any more — that axis belongs to the TRIGGER column alone.
Defensive payloads contribute no damage, a real cost against the one payload
slot. Magnitudes come from worked worst cases — `nice` matches the whole
maxed `bus_speed` shop line (+60), so one module never outvalues 1,950
salvage of upgrades.

## `data/session_rules.gd` — `SessionRules`

Every constant two peers must agree on — tick, players, delay, timeouts,
windows, the leash, packet/snapshot bounds, the port — plus, since the
relay+punch cycle, the relay and NAT-punch protocol. Full table in
`codemaps/net.md`. `SessionRules.PROTOCOL := 4`'s own comment gives the wire
history: 2 — input record carries an aim; 3 — five exploit rows; 4 — the
session also tracks the game BUILD version (HELLO/WELCOME/REFUSED), so a
skew refuses cleanly instead of desyncing. `RELAY_PROTOCOL := 2` adds the
punch op set; a relay and client on different values refuse each other cleanly.

| Relay/punch const | Value | Relay/punch const | Value |
|---|---|---|---|
| `RELAY_PORT` | 43211 | `RELAY_DELAY` | 5 (extra input-delay tick) |
| `PUNCH_DISCOVERY_PORT` | 43212 | `PUNCH_TIMEOUT_MS` | 3000 |
| `RELAY_OP_MAX` | 512 bytes/op | `RELAY_MAX_CONNECTIONS` | 64 |
| `ROOM_IDLE_MS` | 600000 (10 min) | `CODE_LENGTH` | 6 |
| `CODE_ALPHABET` | 32 chars, no 0/O/1/I | | |

**Data-security note:** the punch key and room-join tokens are minted by
`RelayRooms._mint_secret()` — 16 bytes of `Crypto.generate_random_bytes`,
hex-encoded — deliberately NOT `_rng`, the seedable RNG that draws room
codes, so auth material can never be predicted from a leaked code sequence.

## `scripts/meta/save_game.gd` — `SaveGame`

`VERSION = 3`. Static, cached in `_cache`. `use_fresh_state()` / `use_test_paths()`
exist for the suites.

```json
{ "version": 3, "salvage": 0, "kills": 0, "flips": 0, "unlocked": [],
  "buffs": { "cpu_cycles": 0, "cooling": 0, "memory": 0, "firewall": 0,
             "encryption": 0, "bus_speed": 0, "addressing": 0, "bandwidth": 0 },
  "prefs": { "volume_master": 0.8, "volume_sfx": 0.8, "volume_music": 0.5,
             "shake": 1.0, "damage_numbers": 1.0,
             "display_name": "", "last_address": "127.0.0.1" } }
```

An older-version file needs **no migration**: `_sanitise` rebuilds from
`_default()` and overlays what it can read, so any missing key simply arrives
at its default — pinned against a real v2 payload by
`test_prefs.gd:a_v2_file_loads_with_default_prefs`.
`load_state`, `save_state`, `prefs()`, `set_pref(key, value)`,
`set_string_pref / string_pref / sanitise_string_pref` (`PREF_STRINGS`:
`display_name` printable ≤ `NAME_MAX` 24, `last_address` hostname characters ≤
`ADDRESS_MAX` 64 — clamped on write AND read), `bank(salvage, kills, flips)`
**accumulates**.

### Session counters — what crosses the wire instead of a save

`session_counters()` = `{buffs, kills, flips}`. `sanitise_session_counters(raw)`
treats a received counter dict as hostile: it clamps each buff to a known name
and `0..BUFF_MAX`, coerces kills/flips through the same total numeric read as
the save file, and drops unknown fields — shape and range validation, not
authentication; it does not verify the counters came from that peer's real
save, only that the result is byte-stable given equal inputs, which is what
lets two peers derive an identical descriptor.
`player_sheet_from / multipliers_from / unlocked_modules_from(counters)` are
the pure per-slot derivations every peer runs, so no process reads another
player's save and no two peers can disagree about a starting build;
`player_sheet()` / `multipliers()` / `unlocked_modules()` are the local-save
conveniences over the same folds.

### `save.json` is hostile input, and the guards are specific

| Guard | Why |
|---|---|
| `typeof(prefs) == TYPE_DICTIONARY` before indexing | `{"prefs": "x"}` makes `.get` a runtime error, which aborts `_sanitise`, leaves `_cache` unassigned, and cascades into every caller that indexes the result |
| `_num(v, fallback)` on **every** numeric read | `float()`/`int()` are not total. Rejects Dictionary, Array, **`TYPE_NIL`**, `NAN`, `±INF` |
| `is_finite`, not `clampf` | measured: `clampf(NAN, 0, 2)` returns `nan` |
| `_num` on `salvage`/`kills`/`flips` too | worse blast radius than `buffs`: `_read` succeeds, so `load_state()` returns `{}` rather than a default profile, and that sticks in the cache |
| finite-number guard on **both** version reads | `int(null)` aborts `_read` and silently discards the save; `int(INF)` is 9223372036854775807 and quarantines a live save under a nonsense suffix |
| `set_pref` clamps on WRITE | measured: `JSON.stringify` emits `null` for NaN and `1e99999` for INF — **both valid JSON**, so the bad value is faithfully persisted and detonates on the next read. A load-side clamp alone does not close this |

`PREF_RANGES` is the single clamp table, consulted on both sides of the file.
Covered by `tests/test_prefs.gd`, which drives the real load path against real
written files and resets `_cache` per case — without that reset every case after
the first short-circuits and asserts nothing while reporting PASS.

### The split — two namespaces, read at different times

```gdscript
SHEET_EFFECT (additive, read by run.gd, never by the compiler)
  memory→integrity +8.0   firewall→armor +0.6   encryption→defense +6.0
  bus_speed→clock_speed +6.0   bandwidth→pickup_radius +6.0
  cooling→clock_speed +6.0

MULT_EFFECT (multiplicative, folded by Compiler.build after the flat fold)
  cpu_cycles→attack +0.04   addressing→reach +0.03
```

Both hold **deltas**; `PlayerStats.mults()` / `PlayerStats.sheet()` convert.
`cooling` used to feed a global `haste` multiplier on every vector's cooldown;
that key is gone from `Compiler.MULT_KEYS` and the multiplier namespace —
`cooling` now buys sheet `clock_speed` instead, the same stat `bus_speed` buys
at the same step (a deliberate open item, not an oversight). The split keeps
"bandwidth sold as radius" structurally impossible: a player stat has no
landing site in the exploit namespace.

### Shop pricing
`BUFF_COST_BASE 60`, `BUFF_COST_STEP 30`, `BUFF_MAX 10`.
`buff_price(current)`, `buy(name)`.

### Unlock ladder — `MILESTONES`, the single source

| module | requirement | module | requirement |
|---|---|---|---|
| on_damage_taken | 150 kills | on_flip | 15 flips |
| heap_spray | 200 kills | mirror | 25 flips |
| on_low_integrity | 300 kills | tarpit | 40 flips |
| beam | 400 kills | worm | 50 flips |
| on_level_up | 450 kills | checksum | 80 flips |
| landmine | 550 kills | | |

Spread across kills and flips deliberately, so a corruption build and a
damage build walk different ladders — `is_unlocked(id)`, `_milestone_met`,
`milestone_text(id, d)` and `unlocked_modules()` all read this one table.
