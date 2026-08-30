# ROOTKIT — Player Stats & Defensive Modules

**Date:** 2026-08-30
**Status:** revision 4 — after three rounds of a six-reviewer panel.
**Revision 4 has NOT been reviewed.** See §12 for what that means.
**Builds on:** `2026-08-29-rootkit-bullet-heaven-design.md`

---

## 1. Problem

The game has two stat namespaces that cannot talk to each other.

Exploit stats live on `ResolvedExploit` and are folded from modules by
`Compiler.build`. Player stats do not exist: `PLAYER_MAX_HEALTH`,
`PLAYER_SPEED`, `PICKUP_RADIUS` and `IFRAMES` are `const` in `run.gd:56-60`.

Three consequences:

1. There is no damage mitigation of any kind. `_damage_player` subtracts the
   raw contact damage; only `IFRAMES` limits incoming damage rate.
2. Nothing can adjust movement speed, health, or pickup range — the meta shop
   sells `bandwidth` for pickup radius and, until recently, delivered exploit
   radius instead (`save_game.gd:25`).
3. Every payload is offensive. `keylog` (lifesteal) is the sole exception and
   reads as an anomaly rather than a category.

**The bug class this spec is written against** — a stat that is legal to buy
and either silently inert or unbounded — is the class all three earlier drafts
reproduced, every time inside the machinery written to prevent it. §12 records
the pattern, because it is the most useful output of the review.

## 2. Decisions

| Question | Decision |
|---|---|
| Scope | One player stat sheet now; a "character" is later a named set of starting values dropped into it. |
| Layering | Player sheet holds survivability/mobility outright, plus three global multipliers applied to every exploit after the flat module fold. |
| Mitigation | `armor` (flat subtract, floored) and `defense` (percentage, diminishing returns). They answer different threats. |
| Defensive modules | No new slot. Defensive modules are legal in PAYLOAD slots and compete with offensive payloads. |
| Ward magnitude | **Max, never sum — at every level**: within an exploit (`maxf` in `_fold`) and across exploits (§6.3). |
| Sustain | **All sustain is a continuous rate under one shared ceiling** (§6.6). This replaces three failed per-fire designs. |
| `reach` vs packet | PACKET gains a `travel` stat that does not rank-scale and stays under the existing 1600-unit cull. |
| `on_damage_taken` ordering | Triggers fire *before* damage so a ward absorbs its own triggering hit. Sustain is not involved — it is continuous. |
| Knockback | **Cut.** See §11. |

## 3. The stat sheet

`scripts/build/player_stats.gd` — pure, no scene tree.

| Stat | Base | Group | Replaces |
|---|---|---|---|
| `integrity` | 100.0 | survival | `run.gd:56 PLAYER_MAX_HEALTH` |
| `armor` | 0.0 | survival | — new |
| `defense` | 0.0 | survival | — new |
| `clock_speed` | 220.0 | mobility | `run.gd:57 PLAYER_SPEED` |
| `pickup_radius` | 30.0 | mobility | `run.gd:59 PICKUP_RADIUS` |
| `attack` | 1.0 | multiplier | — new |
| `haste` | 1.0 | multiplier | — new |
| `reach` | 1.0 | multiplier | — new |

`IFRAMES` stays a constant — a timing guarantee, not a stat.

### 3.1 The three constants have six consumers

Two of the six are hardcoded literals that no compiler will catch:

| Site | Today | Becomes |
|---|---|---|
| `run.gd:83` | `var player_health := PLAYER_MAX_HEALTH` | A declaration initialiser, evaluated **before** `_ready()` reads the save. `_ready` must re-seed from the sheet near `run.gd:182-183`, or every run starts at 100 regardless of `memory` rank. Tested. |
| `run.gd:670` | `minf(PLAYER_MAX_HEALTH, player_health + lifesteal)` | Cap against effective `integrity`. This raises `keylog`'s ceiling to 180, which is why `lifesteal` is in scope for §6.6's bound. |
| `run.gd:330` | `PLAYER_SPEED` | Effective `clock_speed`. Tested through **both** sources — `bus_speed` (meta) and `nice` (ward). |
| `run.gd:96` | `var pickup_radius := PICKUP_RADIUS` | Seeded from the sheet. |
| `run.gd:183` | `PICKUP_RADIUS + SaveGame.pickup_bonus()` | Effective `pickup_radius`; `pickup_bonus()` subsumed by `player_sheet()`. |
| `ui.gd:123`, `ui.gd:127` | `"integrity %3d/100"` and `WARN if hp < 30 else FG` | Both read effective max integrity. Otherwise the HUD reads `180/100` and warns at 16.7% instead of 30%. |

## 4. Mitigation

```gdscript
const ARMOR_FLOOR := 0.2
const DEFENSE_K := 60.0

static func mitigate(incoming: float, armor: float, defense: float) -> float:
	var a := maxf(0.0, armor)
	var d := maxf(0.0, defense)
	return maxf(incoming * ARMOR_FLOOR, incoming - a) * (1.0 - d / (d + DEFENSE_K))
```

The `maxf(0.0, …)` guards are load-bearing: at `defense == -60` the denominator
is 0.0 and GDScript float division yields ±INF, not an error. They are defence
in depth behind `_sanitise`'s rank clamp, which is the right way round.

At armor 0 / defense 0 this is the **identity**, so an unbuffed run is
unchanged. Against `enemy_table.gd:22-25`, at armor 4 / defense 60:

| Enemy | Raw | After armor | After defense | Armor cut |
|---|---|---|---|---|
| worm | 5 | **1.0** | **0.5** | 80% (floor engages) |
| daemon | 7 | 3.0 | 1.5 | 57% |
| firewall | 12 | 8.0 | 4.0 | 33% |
| ICE | 22 | 18.0 | 9.0 | 18% |

Armor is a swarm answer, defense a boss answer.

## 5. Global multipliers in the compiler

```gdscript
static func build(ex: Exploit, mult: Dictionary = {}) -> ResolvedExploit
```

The additive `buffs` parameter and its fold (`compiler.gd:43-45`) are deleted;
after §8 no shop upgrade feeds additive exploit stats. (`test_meta.gd:61,64`
currently pass a non-empty `buffs`; `:59` passes an empty one. §9 rewrites all
three.)

### 5.1 The table is total over all 17 keys

| Multiplier | Scales | Count |
|---|---|---|
| `attack` | `damage`, `corruption` | 2 |
| `haste` | `cooldown` | 1 |
| `reach` | `radius`, `travel` | 2 |
| — not scaled | `pierce`, `chain_count`, `projectile_speed`, `botnet_cap`, `botnet_lifetime`, `botnet_damage_ratio`, `ward_armor`, `ward_defense`, `ward_clock_speed`, `ward_heal`, `ward_duration`, `lifesteal` | 12 |

5 + 12 = 17.

- **`attack` scales `corruption`** because corruption is a damage type. `_hit`
  gates it on `r.corruption > 0.0` **and** the tag (`run.gd:529-530`), so ×N on
  a zero stays zero.
- **`lifesteal` and `ward_heal` are excluded** so `attack` is not also the best
  defensive stat.
- **`projectile_speed` is excluded** because its cap prevents tunnelling.
- **`haste` is a defensive throughput stat too**, accepted rather than
  corrected: ward uptime is already ~100% (§6.4) and sustain is a rate (§6.6),
  so throughput multiplies neither. `haste` is also inert for a build already
  at the cooldown floor (packet + `interval` r5 folds to 0.0 → 0.05); flat
  `cooling` had the same dead zone and `test_meta.gd:65` already pins it.

### 5.2 `base_cooldown` is preserved pre-clamp

`ResolvedExploit` keeps `base_cooldown` — the folded cooldown before `haste`
and `MIN_COOLDOWN`. `MIN_COOLDOWN` is the one clamp that destroys information.
`damage` and `radius` are unclamped and reversible by division.

**`base_cooldown` may be negative** (`broadcast` + `interval` r5 + `overclock`
r5 = −0.25, which is `test_build.gd:88-93`'s build). Any future consumer must
clamp before multiplying. Nothing in this spec reads it — §6.6's rate mechanism
deliberately does not, because a negative cooldown there would invert sustain
into self-damage.

## 6. Wards and sustain

### 6.1 New stat keys

Six keys join `Module.STAT_KEYS` (11 → 17) and `ResolvedExploit`:

```
ward_armor  ward_defense  ward_clock_speed  ward_heal  ward_duration  travel
```

`equals` must cover these six plus `base_cooldown` — seven new fields. Its only
caller is `test_build.gd:124`; `_recompile` (`run.gd:200-202`) rebuilds
unconditionally and dedupes nothing.

`travel` is separate from `radius` because `radius` already means "effect
radius" to BROADCAST, CHAIN and BEAM and `fork_bomb` contributes 60.0 of it.

### 6.2 Two stats are exempt from rank scaling

`_fold` scales every stat by `em.rank`, exempting only a vector's `cooldown`
(`compiler.gd:62-67`). Two new stats join the carve-out:

- **`travel` on a VECTOR** — see §7.2. This one is load-bearing.
- **`ward_duration`** — rank buys magnitude, never uptime. Note this is
  *hygiene, not a bound*: §6.4's table shows uptime is already saturated at
  rank 1, so rank-scaling duration would buy almost nothing anyway. It is kept
  so the stat means one thing, not because it holds a line.

### 6.3 Magnitude is a max at every level

Wards and `lifesteal` are **never summed**, at two enforcement points:

1. **Within an exploit** — `_fold` accumulates with `+` (`compiler.gd:68`), and
   the *same* module in both payload slots of one exploit is legal:
   `legal_targets` appends `EMPTY_SLOT` whenever the occupant is null
   (`loadout.gd:76-79`), and `:81-83` states "Ranks are per SLOT, not per
   module." So `_fold` must use `maxf` for the four `ward_*` keys and
   `lifesteal`. (The doc comment at `loadout.gd:63-64` claiming "a module id
   appears at most once in the loadout" contradicts the code three lines below
   it and is stale — §9 fixes it.)
2. **Across exploits** — effective `armor` / `defense` / `clock_speed` = base +
   meta + the **max** of `ward_*` over exploits whose ward timer is live.

**One consequence to price:** `maxf`-folding `ward_duration` makes duration
per-*exploit*, not per-stat. `harden` (2.0) + `sandbox` (3.0) in one exploit
gives both a 3.0 s window, so pairing a long ward with a short one upgrades the
short one's uptime for free. Accepted — uptime is saturated regardless (§6.4) —
but tested, because it is a real interaction.

### 6.4 Uptime: wards are conditional passives

`_fire_cd` gates only *event* triggers (`run.gd:432-437`); an INTERVAL exploit
fires from the accumulator at `run.gd:445-459`, which never consults it. And
uptime is bounded only when `ward_duration < cooldown`, which is false
everywhere:

| Vector | cooldown | `harden` 2.0 | `sandbox` 3.0 | `nice` 1.5 |
|---|---|---|---|---|
| packet | 0.50 | 4.0× | 6.0× | 3.0× |
| beam | 0.60 | 3.3× | 5.0× | 2.5× |
| broadcast | 0.85 | 2.4× | 3.5× | 1.8× |
| chain | 0.90 | 2.2× | 3.3× | 1.7× |

Every cell exceeds 1. **Wards are high-uptime conditional passives** — up
whenever the exploit fires, including on an empty field, because §6.5 applies
them before any target check. The levers that bound them are magnitude and
max-at-every-level, not uptime.

### 6.5 Wards apply before the vector branch

`_try_event_fire` sets the cooldown *before* calling `_emit_vector`
(`run.gd:432-437`), and `_emit_vector` has two genuine early returns before any
effect lands: BEAM at `run.gd:470-472` and CHAIN at `run.gd:485-487`. (PACKET's
`if pi >= 0` at `run.gd:520` is **not** an early return — it is a guard around
three array writes at the end of the branch. That distinction is what §6.6
exists to handle.)

Wards are vector-independent and apply at the **top** of `_emit_vector`, before
the `match`, so a defensive BEAM or CHAIN build does not burn its cooldown and
ward nothing.

### 6.6 Sustain: one continuous rate under one ceiling

**This replaces three designs that each failed review.** Per-fire healing was
unbounded by `FIRE_BUDGET`; gating it on "landed a hit" was unevaluable for
PACKET, whose hits resolve a phase later in `_step6_detect` (`run.gd:548-562`),
leaving `gc` either permanently inert on the *starting* vector
(`loadout.gd:39-43` is packet + interval) or healing on an empty field; and a
per-fire "max across exploits" had no read point at which a max could be taken,
so rates summed. All three are the same root cause: sustain was punctual.

Sustain is now **continuous, ward-shaped, and capped as a category**:

```gdscript
const SUSTAIN_CAP := 2.5           # HP/s, the whole category's ceiling

var _ward_left: PackedFloat32Array   # armed by EVERY fire
var _heal_left: PackedFloat32Array   # armed only by a fire that ACQUIRED a target
```

- A fire arms `_ward_left[ei] = r.ward_duration` unconditionally, and
  `_heal_left[ei] = r.ward_duration` **only if that fire acquired a target** —
  BROADCAST's query returned ≥1, BEAM/CHAIN's `_nearest_enemy` ≥ 0, or PACKET's
  `t3 >= 0` (`run.gd:516`). All four are synchronous and knowable at emit time,
  which is what the old hit-gate was not.
- `_step2_integrate` decrements both timers and applies
  `player_health = minf(effective_integrity, player_health + rate * dt)`, where
  `rate = min(SUSTAIN_CAP, max(ward_heal over live _heal_left))`.
- **`lifesteal` draws from the same cap.** `run.gd:666-670` applies the killer
  exploit's lifesteal per adjudicated death with no cooldown and no per-tick
  limit; a broadcast build in a swarm clears many kills per second. Lifesteal
  healing is accumulated into the same per-second budget and clipped to
  `SUSTAIN_CAP` in `_step2_integrate`. `keylog` is the fifth defensive module
  and gets the same bound as the other four.

Because sustain is continuous, `_pending_heal`, `_in_damage_event`, the
carried-heal, and the clamp-to-realized-damage all **disappear**, along with
the ordering question of whether a reactive heal runs before the death check at
`run.gd:597`. It cannot, because it is not reactive.

`gc` is `ward_heal: 0.5` → 0.5 HP/s at rank 1, 2.5 HP/s at rank 5 = the cap.

### 6.7 The worked worst case

Every defensive stat gets this. Six payload slots, `max_rank` 5, shop rank 10,
max-not-sum throughout:

- **armor** = 6.0 (`firewall` r10) + 6.0 (`harden` r5) = **12.0**
- **defense** = 60.0 (`encryption` r10) + 50.0 (`sandbox` r5) = **110.0**
  → 110/170 = **64.7% cut**
- ICE 22 → `maxf(4.4, 10.0)` = 10.0 → × 0.353 = **3.53 per hit**
- ÷ `IFRAMES` 0.5 = **7.06 dps incoming**
- **sustain** = `SUSTAIN_CAP` **2.5 HP/s**, whatever combination of `gc` and
  `keylog` is equipped, at any rank, in any number of slots
- net **4.56 dps** against 180 integrity = **39 s of continuous boss contact**

The cap is what makes this a *bound* rather than an example: no arrangement of
sustain modules changes the 2.5, so the 39 s does not depend on which vector
hosts `gc` or how many slots carry sustain.

- **`nice`** at r5 = +60 `clock_speed` → 220 + 60 + 60 = **340** against a
  fastest enemy of 118. Set to parity with the whole `bus_speed` shop line
  (+60 for 1,950 salvage) so one module in one slot is not worth more than a
  maxed shop upgrade.

### 6.8 The modules

Four new PAYLOAD modules. None contributes `damage`.

| id | Stats | Reads as |
|---|---|---|
| `harden` | `ward_armor` 1.2, `ward_duration` 2.0 | flat-damage plate |
| `sandbox` | `ward_defense` 10.0, `ward_duration` 3.0 | percentage soak |
| `gc` | `ward_heal` 0.5, `ward_duration` 2.0 | sustain |
| `nice` | `ward_clock_speed` 12.0, `ward_duration` 1.5 | escape speed |

`keylog` is the fifth member of the category and is now bound by §6.6.

Module count 15 → 19, unlocked 12 → 16.

**Dilution is 31%, not 50%.** Earlier drafts claimed the offer pool is narrower
than the unlocked list because "payloads are legal far more often than vectors,
which need a free exploit." That is false: `legal_targets` offers `REPLACE` for
any occupied slot whose occupant is not `_is_last_interval`
(`loadout.gd:67-87`), and `_is_last_interval` returns `false` for anything that
is not an INTERVAL **TRIGGER** (`loadout.gd:195-199`), so a vector is always
displaceable. Executed against a full three-exploit board, **12 of 12 modules
have a legal target**, so `run.gd:776`'s `is_empty()` filter removes nothing and
the offer pool *is* the unlocked list. Defensive share = **5 of 16 = 31%**.

## 7. Trigger ordering and `reach`

### 7.1 `_damage_player` restructure

Triggers move ahead of the damage subtraction so a ward absorbs its own
triggering hit. Sustain is not involved — §6.6 made it continuous — so this is
the whole change:

```gdscript
func _damage_player(amount: float) -> void:
	for ei in resolved.size():                    # 1. triggers -> wards apply
		var r: ResolvedExploit = resolved[ei]
		if not r.inert and r.trigger_kind == Module.TriggerKind.ON_DAMAGE_TAKEN:
			_try_event_fire(ei, r)
	player_health -= _mitigated(amount)           # 2. damage, now warded
	player_iframe = IFRAMES
	...                                           # 3. death check, unchanged
```

`test_triggers.gd` is a behavioral harness — it instantiates runs and asserts
every trigger kind fires (`:66-101`) and that `on_kill` respects its cooldown
(`:24-61`) — but both read `_trigger_fires`, never `player_health`, and a grep
over `tests/` finds no test reading `player_health` at all. So the reorder
breaks no shipped assertion; the suite must still be re-run.

No recursion: `_try_event_fire` → `_emit_vector` → `_hit` → `queue.append`, and
nothing re-enters `_damage_player`, which has exactly one call site
(`run.gd:579`).

### 7.2 PACKET travel distance

`packet` gains `travel: 700.0`, carried by `_proj_dist_left: PackedFloat32Array`.

1. **`travel` must not rank-scale.** Projectiles are already culled at 1600
   units from the player (`run.gd:726-727`). Rank 3 unscaled is 2100 > 1600;
   with `addressing` r10 the cull binds from rank 2 (700 × 2 × 1.30 = 1820).
   Held flat, the worst case is 700 × 1.30 = **910 < 1600**. The cull measures
   distance *from the player*, so a fleeing player adds up to
   220 × (910/420) = 477 px → 1387 px worst case, still inside.
2. **Swap-move on despawn** at `run.gd:733`, beside the three existing copies
   and the comment that already warns about exactly this.
3. **Two manual seeding sites**: `perf_milestone0.gd:178-183` **and**
   `tools/fps_probe.gd:70` (grep confirms these are the only two). A resized
   `PackedFloat32Array` gives 0.0, expiring every seeded projectile on its first
   integration pass and silently lightening the perf gate.
4. **The decrement** is `_proj_dist_left[i] -= projectiles.vel[i].length() * dt`
   — `Population` stores no scalar speed.

`_step6_detect` iterates to `projectiles.count` at `run.gd:548` without checking
`projectiles.state[i]`; the guard is newly required, since travel expiry is the
first thing to mark a projectile dead in step 2.

## 8. Meta shop v2

| Buff | Stat | Per rank | At rank 10 |
|---|---|---|---|
| `cpu_cycles` | `attack` | +0.04 | ×1.40 |
| `cooling` | `haste` | −0.03 | ×0.70 |
| `memory` | `integrity` | +8.0 | 180 |
| `firewall` | `armor` | +0.6 | 6.0 |
| `encryption` | `defense` | +6.0 | 60.0 |
| `bus_speed` | `clock_speed` | +6.0 | 280 |
| `addressing` | `reach` | +0.03 | ×1.30 |
| `bandwidth` | `pickup_radius` | +6.0 | 90 |

`SaveGame.VERSION` 1 → 2; `_read` (`save_game.gd:85-87`) quarantines only newer
versions and `_sanitise` (`:94-113`) carries old ranks through, so a v1 save
loads. `buff_stats()` splits into `player_sheet()` and `multipliers()`.

### 8.1 One partial-table shape in three places — one is a live bug

`save_game.gd:168` is `for k in BUFF_EFFECT[StringName(name)]:` — a direct
index into a table holding two names, iterated over `d["buffs"]`'s three.
Reproduced:

```
SCRIPT ERROR: Invalid access to property or key 'bandwidth' ...
          at: buff_stats (res://scripts/meta/save_game.gd:168)
  PASS — all cases
```

It fires **once `bandwidth` has been bought**, not on every call — `:166-167`
skips rank-0 buffs. The consequence is worse than an abort: the function
returns the typed default `{}`, discarding the `cpu_cycles` and `cooling`
contributions it had already accumulated. **Any player who buys one rank of
bandwidth silently loses every rank of cpu_cycles and cooling** at `run.gd:182`.
Fix it as part of this work with `.get(name, {})` (Godot 4.7 treats StringName
and String keys as equal, so the existing `StringName(name)` cast is safe).

The suite hides it because `test_meta.gd:71` asserts a *negative* —
`buff_stats().has(&"radius") == false` — which an aborted function satisfies
for free, and which is vacuous for a second reason: `BUFF_EFFECT` has no
`radius` key at all. §9 **replaces** that assertion rather than adding beside it.

The same shape appears twice more: `_default()["buffs"]` (`save_game.gd:40`)
must gain all eight names or `_sanitise` drops them every round-trip, and
`meta_screen.gd:90` direct-indexes without `.get`, crashing the shop on open.

### 8.2 Layout: a ScrollContainer, not two columns

Five new rows add 5 × (30 + 10) = **200 px** to a column starting at y=52 in a
720 px viewport, against roughly **164 px** of headroom. The `./intrude` button
clips.

Two columns do **not** fit: one row's minimum width is
230 + 12 + 240 + 12 + 150 = **644 px** (`meta_screen.gd:44-50`), and two
columns from x=64 need ≥1352 px against `viewport_width=1280`
(`project.godot:18`) — overflowing by ≥72 px, and what clips is the second
column's buy button. (An earlier draft also claimed two columns "cost 0 px of
height"; three rows become four, so they cost +40 px.)

**Wrap the rows in a `ScrollContainer` and pin `./intrude` outside it**, so the
start button can never scroll away. Two columns remain possible only with
narrowed minimum sizes (≈180 / 150 / 150 = 504 per column), which requires
re-authoring the description strings and is not proposed here.

Full clear is 1,950 × 8 = 15,600.

## 9. Files and tests

**Modified:** `module.gd` (STAT_KEYS 11→17), `resolved_exploit.gd` (six stat
fields + `base_cooldown` + `equals`), `compiler.gd` (`buffs` deleted, `mult`
added, the `travel`/`ward_duration` rank carve-out, `maxf` folding for
`ward_*` and `lifesteal`), `loadout.gd` (`mult` field replacing `buffs`; **the
stale `:63-64` uniqueness comment**), `module_table.gd` (four modules,
`packet.travel`, **the `:11-12` counts**), `run.gd` (**`:182` →
`loadout.mult = SaveGame.multipliers()`**, `_ward_left` + `_heal_left`,
continuous sustain and the `SUSTAIN_CAP` clip incl. `lifesteal` at `:666-670`,
mitigation, effective stats, `_damage_player` order, `_proj_dist_left` incl.
the `:733` swap-move, `_step6_detect` state guard, `_ready` re-seed of
`player_health`), `save_game.gd` (**the `:168` bug**, eight buffs, `_default()`
keys, VERSION 2, `player_sheet()` / `multipliers()`, **the `:22-27` comment**),
`meta_screen.gd` (eight rows in a ScrollContainer, **the `:11-13` BUFFS
description strings** — "damage +1.5 per rank" and "cooldown -0.02 per rank"
are both false under multipliers — **and the `:39` "applied at compile time"
label**), `ui.gd` (`:123`, `:127`, armor/defense readout, ward indicator),
`tools/fps_probe.gd:70`, `tests/perf_milestone0.gd` (`_fill()`),
**`README.md:27`** (payload list) and **`README.md:81`** ("Not in this build:
… in-run stat changes" — wards are in-run stat changes).

**New:** `scripts/build/player_stats.gd`.

**New tests:**

- `test_player_stats.gd` — `mitigate` at the worm tie point (5, armor 4 → 1.0);
  armor ≫ incoming floors at 20%; defense at 0, `DEFENSE_K`, 10× `DEFENSE_K`,
  and **negative**; the identity at 0/0.
- `test_wards.gd` — set/decay/expiry; two exploits with the same ward take the
  max; **the same module in both payload slots of one exploit** takes the max;
  **two different wards in one exploit** share the longer duration (§6.3);
  a BEAM ward with no target still applies; `ward_clock_speed` actually moves
  the player at `run.gd:330`.
- `test_sustain.gd` — **`gc` on a PACKET exploit heals** (the case three
  designs got wrong); `gc` does not heal on a fire that acquired no target,
  on **each** of the four vectors; sustain is rate-invariant across cooldowns;
  three exploits carrying `gc` heal `SUSTAIN_CAP`, not 3×; `keylog` at a high
  kill rate is clipped to `SUSTAIN_CAP`; `gc` + `keylog` together are clipped
  to `SUSTAIN_CAP`.
- `test_multipliers.gd` — **through `run._recompile()`, not `Compiler.build`**:
  set an `attack` rank, recompile, assert `resolved[0].damage` moved. Also
  `attack` scales `corruption`; `haste` before `MIN_COOLDOWN` (use a mid-range
  cooldown, e.g. 0.20 × 0.70 = 0.14); the 12 excluded keys untouched; `travel` ×
  max `reach` under the 1600 cull **with the player held stationary**;
  `_proj_dist_left` survives swap-remove; an expired projectile does not hit.
- `test_player_sheet.gd` — a run with `memory` r10 starts at 180, not 100; a
  run with `bus_speed` r10 moves farther per tick (the meta path into
  `run.gd:330`, distinct from the ward path).

**Updated:** `test_build.gd:48` 15 → **19** (and the `:47` label);
`test_meta.gd:76` 12 → **16**; `test_meta.gd:39` `5850` → `15600` (`:38`'s 1950
is unchanged); `test_meta.gd:59,61,64,69-72` rewritten against `player_sheet()`
/ `multipliers()` asserting **positively** on all eight names, with `:71`'s
vacuous negative **deleted**. `test_build.gd` also gains: new keys fold and
rank-scale, `travel`/`ward_duration` do not, `ward_*` and `lifesteal` fold by
max, and `equals` distinguishes ward-only differences.

**Manual gate:** `tools/shot_meta.gd` already drives the shop screen; use it to
confirm the eight rows and `./intrude` fit the 720 px viewport. There is no
automated check for this.

**Perf gate:** `perf_milestone0.gd` must still pass.

## 10. Known risks

1. **`attack` triple-dips on corruption builds**: flip rate, flip payoff, and
   botnet aura damage — `_on_flip` computes `corr` at `run.gd:683-685` and
   assigns `_botnet_ratio[bi]` at `:688`.
2. **Defensive modules are 31% of the offer pool.** The lever is a draw weight.
3. **Wards are conditional passives**, so defense is weakest when the screen is
   empty and strongest under pressure. A shape, not a neutrality.
4. **`SUSTAIN_CAP` makes `gc` and `keylog` partly redundant** at high rank —
   two modules competing for one ceiling. Deliberate: it is the only structure
   that bounds sustain regardless of build. If it makes both feel bad, the fix
   is separate ceilings, not removing the cap.
5. **The magnitudes are the least-tested numbers here.** They come from worked
   worst cases, not from play. Expect to move them; the structure should not
   have to move.

## 11. Explicitly out of scope

- **Knockback / `throttle`.** It wrote into `enemies.force[i]`, which
  `_step4_steer` *assigns* rather than accumulates (`run.gd:414,427`) on a
  2-tick slice and which is consumed as a velocity offset (`run.gd:343`), so a
  260.0 knockback displaces an enemy 4–9 px against a 12 px radius — and worm
  segments skip the force path entirely (`run.gd:409-411`). Doing it properly
  needs a decaying `PackedVector2Array(MAX_ENEMIES)` in the integrate step.
- Character select; in-run stat pickups outside the module system; armor as a
  regenerating second bar; any change to `IFRAMES`; dynamic offensive
  multipliers.

## 12. Review record — and what revision 4's status is

Three rounds, six reviewers (GPT-5.6 Luna, GPT-5.6 Terra, GLM-5.2, Gemini 3.1
Pro, and two Claude skeptics). Round 1: six REVISE. Round 2: one APPROVED, five
REVISE. Round 3: six REVISE. No contradictions between reviewers in any round.

**Revision 4 has not been reviewed.** It was written after the three-round
budget was spent, so every change in it — most importantly §6.6's continuous
sustain and `SUSTAIN_CAP` — carries exactly the risk the record below
describes: new machinery is where the defect lands.

**The pattern, which is the useful output.** Every round found the same class
of defect in a *new* place, and every time the new place was the machinery
written to fix the previous round:

- **Round 1** — the three multipliers would have shipped dead.
  `Loadout.compile_all` is the only runtime caller of `Compiler.build`,
  `loadout.gd` was missing from the file list, and the new parameter defaulted
  to `{}`; every planned test called `Compiler.build` directly, so nothing
  would have noticed. Also: the stated ward-uptime lever was arithmetically
  inert, and `travel` and `ward_duration` re-created the inert-stat bug through
  rank scaling.
- **Round 2** — the rebalance stopped two modules short. `gc` reached 3,600
  HP/s against a worst-case incoming of 7.06 dps, and revision 1's own fix for
  wards (applying them before `_emit_vector`'s early returns) is what made `gc`
  an out-of-combat regen. Max-not-sum had a hole one exploit wide because
  `_fold` sums within an exploit.
- **Round 3** — the heal gate was unevaluable on PACKET, the *starting* vector,
  leaving `gc` inert or leaky; the cross-exploit heal "max" had no read point,
  so rates summed to immortality; and `keylog` — the fifth defensive module —
  was exempt from every bound the document introduced.

Sustain specifically failed **three consecutive times, in three different
ways.** §6.6 is the fourth design and the first that is structural rather than
numeric: a category-wide cap that no arrangement of modules or ranks can
exceed. If a fourth round finds a defect there too, the honest conclusion is
that sustain does not belong in this scope at all.

Across the three rounds the drafts made **fourteen** false statements about the
codebase — a mischaracterised test file, a fabricated `equals` mechanism, a
mitigation row that contradicted its own function, a quoted source line that
did not exist, a dilution figure resting on a false claim about
`legal_targets`, and nine citations pointing at the wrong lines. Every one was
caught by a reviewer opening the file instead of trusting the claim. Two were
settled only by *executing* the code. That is the argument for grounding every
citation before building on it, and it applies to this revision too.
