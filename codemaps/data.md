> Generated: 2026-09-01 | Token-lean format for LLM context

# Data tables and persistence

Both registries are **defined in code, not scanned from `.tres`**: `DirAccess`
scanning `data/modules/` works in the editor and in CI but not in an exported
build (Godot converts text resources to binary by default), so every player
would get an empty card pool.

## `data/enemy_table.gd` — `EnemyTable`

```gdscript
enum Behaviour { CHASE, CHARGER, FLANKER, SUPPORT, AMBUSHER, RANGED }
const ICE := 12    # index into all(); ICE must stay LAST
class EnemyType: id glyph color integrity speed corruption_threshold
                 contact_damage shard_value behaviour(=CHASE)
```

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
| 12 | **ice** | 3 | 700 | 46 | 1e18 | 22 | 0 | CHASE |

Rows 8–11 are the mini-bosses (between firewall and ICE: set-pieces, not bosses).
ICE's corruption threshold is effectively infinite — flipping it would bypass the
kill-to-win condition. `EnemyTable.ICE` is an index, so ICE must stay last.

## `data/module_table.gd` — `ModuleTable`

35 modules; 14 ship locked. `all()`, `by_id()`, `starting_unlocked()`.

```gdscript
LOCKED = [beam, on_damage_taken, worm, snipe, landmine, cascade, mirror,
          airgap, checksum, on_low_integrity, on_flip, on_level_up,
          heap_spray, tarpit]
```

Roughly half the breadth ships locked because a level-up still shows three cards:
going 18 → 35 modules halves the odds of drawing what a build wants.

### VECTOR (14)

| id | kind | stats |
|---|---|---|
| broadcast | BROADCAST | dmg 3.5, radius 90, cd 0.85 |
| packet | PACKET | dmg 6, speed 420, cd 0.5, travel 640 |
| chain | CHAIN | dmg 5, chain 2, radius 170, cd 0.9 |
| beam 🔒 | BEAM | dmg 3.5, pierce 3, radius 240, cd 0.6 |
| spike | CONE | dmg 9, radius 150, cd 0.75 |
| flood | BROADCAST | dmg 2, radius 300, cd 1.6 |
| snipe 🔒 | PACKET | dmg 14, speed 900, cd 1.5, travel 1200, pierce 2 |
| landmine 🔒 | MINE | dmg 16, radius 130, cd 1.9 · `aoe` |
| cascade 🔒 | CHAIN | dmg 3, chain 4, radius 150, cd 0.8 |
| bounce | PULSE | dmg 2, radius 190, cd 1.1, knockback 320 |
| mirror 🔒 | ORBIT | dmg 4, radius 90, cd 2.2, orbit 3 |
| throttle | BROADCAST | dmg 0.5, radius 260, cd 1.4, slow 0.55/2.0s · `slow` |
| airgap 🔒 | PULSE | radius 210, cd 1.6, knockback 520, ward_armor 1.4/2.0s |
| checksum 🔒 | BROADCAST | dmg 1, radius 70, cd 2.6, shield 26 |

Base damage sits ~30% below its first pass (payloads ~20%) because a rank buys
damage linearly; `SpawnDirector.hp_mult` is the load-bearing half of that fix.

### TRIGGER (7) — paid on the axis its frequency suits

| id | cadence_mult | burst | other |
|---|---|---|---|
| interval | **1.00** | — | the baseline, not a bonus; never idles |
| on_kill | 0.70 | — | dmg 3 |
| on_hit | 0.62 | — | dmg 1 |
| on_damage_taken 🔒 | 0.90 | 3 | dmg 8, radius 40 |
| on_low_integrity 🔒 | 1.00 | 5 | dmg 6 |
| on_flip 🔒 | 0.74 | — | corruption 2 · `corruption` |
| on_level_up 🔒 | 1.00 | 8 | — |

Frequent triggers are paid in cadence, rare ones in burst; `on_flip` is paid in
corruption, the resource its own build runs on. `interval` was 0.85 — both faster
*and* unconditional, so an event trigger could never win in any build.

### PAYLOAD (14)

| id | stats |
|---|---|
| buffer_overflow | dmg 5.5 |
| fork_bomb | dmg 4, radius 60 · `aoe` |
| corrupt | corruption 4 · `corruption` |
| keylog | lifesteal 0.4 |
| worm 🔒 | corruption 2, chain 1 · `corruption` |
| botnet_expand (`fork()`) | botnet_cap 2 |
| overclock | dmg 2, cadence_mult 0.82 |
| harden | ward_armor 1.2 / 2.0s |
| sandbox | ward_defense 10 / 3.0s |
| nice | ward_clock_speed 12 / 1.5s |
| bitmask | pierce 1 |
| race_condition | cadence_mult 0.88 |
| heap_spray 🔒 | chain 1, radius 30 |
| tarpit 🔒 | slow 0.35 / 1.5s · `slow` |

Defensive payloads contribute no damage, so equipping one is a real cost against
the single payload slot. Magnitudes come from worked worst cases — `nice` matches
the whole maxed `bus_speed` shop line (+60), so one module is never worth more
than 1,950 salvage of upgrades.

## `scripts/meta/save_game.gd` (313) — `SaveGame`

`VERSION = 3`. Static, cached in `_cache`. `use_fresh_state()` / `use_test_paths()`
exist for the suites.

```json
{ "version": 3, "salvage": 0, "kills": 0, "flips": 0, "unlocked": [],
  "buffs": { "cpu_cycles": 0, "cooling": 0, "memory": 0, "firewall": 0,
             "encryption": 0, "bus_speed": 0, "addressing": 0, "bandwidth": 0 },
  "prefs": { "volume_master": 0.8, "volume_sfx": 0.8, "volume_music": 0.5,
             "shake": 1.0, "damage_numbers": 1.0 } }
```

v2 files need **no migration**: `_sanitise` rebuilds from `_default()` and
overlays what it can read, so an absent `prefs` simply arrives at its defaults.

`load_state`, `save_state`, `prefs()`, `set_pref(key, value)`,
`bank(salvage, kills, flips)` **accumulates**.

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

### The v2 split — two namespaces, read at different times

```gdscript
SHEET_EFFECT (additive, read by run.gd, never by the compiler)
  memory→integrity +8.0   firewall→armor +0.6   encryption→defense +6.0
  bus_speed→clock_speed +6.0   bandwidth→pickup_radius +6.0

MULT_EFFECT (multiplicative, folded by Compiler.build after the flat fold)
  cpu_cycles→attack +0.04   cooling→haste -0.03   addressing→reach +0.03
```

Both hold **deltas**; `PlayerStats.mults()` converts. The split is what makes the
"bandwidth sold as radius" bug structurally impossible to repeat.
`player_sheet()` and `multipliers()` are the two readers; `_fold(table)` is shared.

### Shop pricing
`BUFF_COST_BASE 60`, `BUFF_COST_STEP 30`, `BUFF_MAX 10`.
`buff_price(current)`, `buy(name)`.

### Unlock ladder — `MILESTONES`, the single source

| module | requirement | module | requirement |
|---|---|---|---|
| on_damage_taken | 150 kills | on_flip | 15 flips |
| heap_spray | 200 kills | mirror | 25 flips |
| snipe | 250 kills | tarpit | 40 flips |
| on_low_integrity | 300 kills | worm | 50 flips |
| beam | 400 kills | checksum | 80 flips |
| on_level_up | 450 kills | | |
| landmine | 550 kills | | |
| cascade | 700 kills | | |
| airgap | 900 kills | | |

Spread across kills and flips deliberately, so a corruption build and a damage
build walk different ladders. `is_unlocked(id)`, `_milestone_met`,
`milestone_text(id, d)` ("250 kills (37/250)") and `unlocked_modules()` all read
this one table — the shop text used to be a second hardcoded copy that drifted.
