> Generated: 2026-09-01 | Token-lean format for LLM context

# Build layer — `scripts/build/` (pure)

No scene tree, no globals, no engine calls beyond `Resource`/`RefCounted`.
Runs once per module pick, never per frame — combat reads only the flat result.

```
Module ──> EquippedModule (module + rank) ──> Exploit (vector/trigger/payload)
                                                 │
                              Loadout (3 exploits + auto-slot rules)
                                                 │  compile_all()
                                                 v
                              Compiler.build(exploit, mult) ──> ResolvedExploit
```

## `module.gd` (62 lines) — `class_name Module extends Resource`

```gdscript
enum Slot        { VECTOR, TRIGGER, PAYLOAD }
enum VectorKind  { BROADCAST, PACKET, CHAIN, BEAM, CONE, PULSE, MINE, ORBIT }
enum TriggerKind { INTERVAL, ON_KILL, ON_HIT, ON_DAMAGE_TAKEN,
                   ON_LOW_INTEGRITY, ON_FLIP, ON_LEVEL_UP }
```

`VectorKind` is **append-only, never reordered** — values are stored on modules,
so an insert silently repoints everything defined above it.

`STAT_KEYS` (23) is the *only* legal set of stat keys — asserting against
"fields of ResolvedExploit" would admit `stats["tags"] = 1.0`:

```
damage corruption lifesteal cooldown radius pierce chain_count projectile_speed
botnet_cap botnet_lifetime botnet_damage_ratio
ward_armor ward_defense ward_clock_speed ward_duration
travel cadence_mult knockback slow_amount slow_duration shield orbit_count burst
```

Fields: `id, display_name, slot, tags[], max_rank=5, stats{}, vector_kind,
trigger_kind`. Built via `Module.make(id, name, slot, stats, tags, vk, tk, max_rank)`.

## `exploit.gd` (107) — one weapon

| Member | Note |
|---|---|
| `vector`, `trigger` | `EquippedModule` or `null` |
| `payloads: Array` | `PAYLOAD_SLOTS = 1` — one slot, so a level-up card never asks *which* payload slot |
| `SLOT_COUNT = 3` | column indices: 0 VECTOR, 1 TRIGGER, 2 PAYLOAD |
| `is_inert()` | true if vector or trigger is null → does not fire |

`slot_type(i)` / `slot_index_of(slot)` are a bijection: one column per slot type
is what lets a card offer a single button per exploit row.
Also: `equipped()`, `holds(id)`, `at(i)`, `set_at(i, em)`, `place(m)`,
`free_payload_slot()`, `has_free_slot_for(slot)`.

## `loadout.gd` (305) — the board and the auto-slot rules

`MAX_EXPLOITS = 3`. `enum Rule { NONE, RANK_UP, EMPTY_SLOT, NEW_EXPLOIT, REPLACE }`.

| API | Does |
|---|---|
| `start(packet, interval)` | seeds exploit 0; without it the rules are not total on an empty board |
| `legal_targets(m) -> Array[Target]` | every slot `m` may occupy; the player chooses |
| `best_target(targets)` (static) | the default the card highlights |
| `place_at(m, exploit_index, slot_index)` | the player's explicit choice |
| `resolve(m) -> Placement` / `apply(m, p)` | the automatic path |
| `compile_all() -> Array[ResolvedExploit]` | **the only runtime caller of `Compiler.build`** |
| `mult: Dictionary` | absolutes, fed from `PlayerStats.mults(SaveGame.multipliers())` |

Invariants enforced by `legal_targets`:
- A module id may occupy **any number** of slots; ranks are per *slot*, so the
  same module twice is two independent copies. Only the slot already holding it
  offers a rank-up. (This is why `Compiler` folds `ward_*`/`lifesteal` by MAX.)
- The **last INTERVAL trigger cannot be displaced** (`_is_last_interval`) — an
  all-event loadout could otherwise never fire.

## `compiler.gd` (269) — `Compiler.build(ex, mult) -> ResolvedExploit`

Fold order: **flat module fold → cadence product → global multipliers → clamps.**

| Const | Value | Why |
|---|---|---|
| `MIN_COOLDOWN` | 0.05 | absolute floor |
| `MIN_CADENCE_FRACTION` | 0.12 | proportional floor, as a fraction of the vector's own base — an absolute floor makes every fast build converge on one number |
| `MAX_PROJECTILE_SPEED` | 960.0 | `60 × (PROJECTILE_RADIUS 4 + ENEMY_RADIUS 12)`; the smallest combined radius, not the cell size |
| `VECTOR_RADIUS_RANK` | 0.25 | fraction of a rank a VECTOR's radius collects |
| `MUL_FOLD_KEYS` | `[cadence_mult]` | accumulate by product |
| `MAX_FOLD_KEYS` | `ward_armor ward_defense ward_clock_speed ward_duration lifesteal slow_amount slow_duration shield` | magnitudes bought once; summing across slots buys uptime free |
| `MULT_KEYS` | `attack→[damage, corruption]`, `haste→[cooldown]`, `reach→[radius, travel]` | total and non-overlapping; `lifesteal` and `projectile_speed` deliberately excluded |

Everything else sums. `_rank_factor(f, rank)` scales a stat by rank.
`validate(m) -> Array[String]` checks a module against `STAT_KEYS`.

## `resolved_exploit.gd` (122) — the flat struct combat reads

`cadence_mult` is the **only** field defaulting to `1.0`; anything that resets
fields generically breaks quietly on it.
`pierce`, `chain_count`, `botnet_cap`, `orbit_count`, `burst` are **untyped on
purpose** — they accumulate as float so two 0.5 contributions make 1, and
`Compiler.build` applies `floori()` once at the end.
`burst = 0` means one emission. `travel` is separate from `radius` so a payload
contributing `radius` cannot silently change a packet's flight distance.
`tags: Dictionary` is a set (`StringName -> true`), not weights.
`equals(o)` compares every scalar plus `tags.keys()` and `inert`.

## `player_stats.gd` (67) — the player's own sheet, deliberately two groups

```gdscript
BASE      = { integrity:100.0, armor:0.0, defense:0.0, clock_speed:220.0, pickup_radius:30.0 }
BASE_MULT = { attack:1.0, haste:1.0, reach:1.0 }
ARMOR_FLOOR = 0.2     # armor never blocks >80% of a hit
DEFENSE_K   = 60.0    # defense value at which reduction is exactly 50%
```

```gdscript
mitigate(incoming, armor, defense) ->
    maxf(incoming * ARMOR_FLOOR, incoming - a) * (1.0 - d / (d + DEFENSE_K))
```
Both `maxf(0.0, …)` guards are load-bearing: `save.json` is user-editable, and
at `defense == -60` the denominator is 0.0 — GDScript yields INF rather than
erroring.

- `sheet(deltas)` — additive player stats, read **directly by run.gd**, never by
  the compiler. Unknown keys dropped, so a stale save cannot invent a stat.
- `mults(deltas)` — converts `SaveGame.multipliers()` **deltas** (+0.40) into the
  absolutes the compiler wants (×1.40). Every caller must go through it.

Keeping the two groups apart is what makes the "player stat sold in the shop,
silently delivered as an exploit stat" class of bug structurally impossible.
