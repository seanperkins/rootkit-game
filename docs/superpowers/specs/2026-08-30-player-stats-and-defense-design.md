# ROOTKIT — Player Stats & Defensive Modules

**Date:** 2026-08-30
**Status:** revision 5 — after three review rounds and a verification pass.
**Revision 5 removes machinery rather than adding it.** See §11.
**Builds on:** `2026-08-29-rootkit-bullet-heaven-design.md`

---

## 1. Problem

Exploit stats live on `ResolvedExploit` and are folded by `Compiler.build`.
Player stats do not exist: `PLAYER_MAX_HEALTH`, `PLAYER_SPEED`,
`PICKUP_RADIUS` and `IFRAMES` are `const` in `run.gd:56-60`. So:

1. There is no damage mitigation of any kind.
2. Nothing can adjust movement speed, health, or pickup range — the shop sells
   `bandwidth` for pickup radius and, until recently, delivered exploit radius
   (`save_game.gd:25`).
3. Every payload is offensive except `keylog`, which reads as an anomaly.

**The bug class this spec is written against** — a stat legal to buy that is
either silently inert or unbounded. Four drafts reproduced it, every time in
the newest machinery. §11 is the record, and it is why revision 5 is smaller
than revision 4 rather than larger.

## 2. Decisions

| Question | Decision |
|---|---|
| Scope | One player stat sheet. A "character" is later a named set of starting values. |
| Layering | Player sheet holds survivability/mobility outright, plus three global multipliers applied after the flat module fold. |
| Mitigation | `armor` (flat subtract, floored) and `defense` (percentage, diminishing returns). |
| Defensive modules | No new slot. They are legal in PAYLOAD slots and compete with offensive payloads. |
| Ward magnitude | **Max, never sum** — within an exploit (`maxf` in `_fold`) and across exploits. |
| **Sustain** | **Out of scope.** Four designs failed review in four different ways (§11). No new healing; `keylog` is unchanged and its cost is stated in §9. |
| PACKET range | `travel`, which does not rank-scale and **replaces** the 1600-unit player-distance cull for projectiles. |
| `on_damage_taken` | Triggers fire before damage, so a ward absorbs its own triggering hit. |
| Knockback | **Cut.** See §10. |

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

| Site | Today | Becomes |
|---|---|---|
| `run.gd:83` | `var player_health := PLAYER_MAX_HEALTH` | A declaration initialiser evaluated **before** `_ready()` reads the save. `_ready` must re-seed from the sheet near `run.gd:182-183`, or every run starts at 100 regardless of `memory` rank. Tested. |
| `run.gd:670` | `minf(PLAYER_MAX_HEALTH, player_health + lifesteal)` | Cap against effective `integrity`. This raises `keylog`'s ceiling to 180 — an accepted consequence, priced in §9. |
| `run.gd:330` | `PLAYER_SPEED` | Effective `clock_speed`. Tested through **both** sources — `bus_speed` (meta) and `nice` (ward). |
| `run.gd:96` | `var pickup_radius := PICKUP_RADIUS` | Seeded from the sheet. |
| `run.gd:183` | `PICKUP_RADIUS + SaveGame.pickup_bonus()` | Effective `pickup_radius`; `pickup_bonus()` subsumed by `player_sheet()`. |
| `ui.gd:123`, `ui.gd:127` | `"integrity %3d/100"` and `WARN if hp < 30 else FG` | Both read effective max integrity, or the HUD reads `180/100` and warns at 16.7%. |

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
is 0.0 and GDScript float division yields ±INF, not an error. At armor 0 /
defense 0 the function is the **identity**, so an unbuffed run is unchanged.

Against `enemy_table.gd:22-25`, at armor 4 / defense 60:

| Enemy | Raw | After armor | After defense | Armor cut |
|---|---|---|---|---|
| worm | 5 | **1.0** | **0.5** | 80% (floor engages) |
| daemon | 7 | 3.0 | 1.5 | 57% |
| firewall | 12 | 8.0 | 4.0 | 33% |
| ICE | 22 | 18.0 | 9.0 | 18% |

Armor is a swarm answer, defense a boss answer.

## 5. Global multipliers

```gdscript
static func build(ex: Exploit, mult: Dictionary = {}) -> ResolvedExploit
```

The additive `buffs` parameter and its fold (`compiler.gd:43-45`) are deleted;
after §8 no shop upgrade feeds additive exploit stats. (`test_meta.gd:61,64`
currently pass a non-empty `buffs`; `:59` passes an empty one. §9 rewrites all
three.)

### 5.1 Total over all 16 keys

| Multiplier | Scales | Count |
|---|---|---|
| `attack` | `damage`, `corruption` | 2 |
| `haste` | `cooldown` | 1 |
| `reach` | `radius`, `travel` | 2 |
| — not scaled | `pierce`, `chain_count`, `projectile_speed`, `botnet_cap`, `botnet_lifetime`, `botnet_damage_ratio`, `ward_armor`, `ward_defense`, `ward_clock_speed`, `ward_duration`, `lifesteal` | 11 |

5 + 11 = 16.

- **`attack` scales `corruption`** because corruption is a damage type. `_hit`
  gates it on `r.corruption > 0.0` **and** the tag (`run.gd:529-530`), so ×N on
  a zero stays zero.
- **`lifesteal` is excluded** so `attack` is not also the best defensive stat.
- **`projectile_speed` is excluded** because its cap prevents tunnelling.
- **`haste` is a defensive throughput stat too**, accepted: ward uptime is
  already ~100% (§6.4), so refresh rate changes nothing. `haste` is also inert
  for a build at the cooldown floor; flat `cooling` had the same dead zone and
  `test_meta.gd:65` already pins it.

### 5.2 `base_cooldown` preserved pre-clamp

`ResolvedExploit` keeps `base_cooldown` — the folded cooldown before `haste`
and `MIN_COOLDOWN`, the one clamp that destroys information. It **may be
negative** (`broadcast` + `interval` r5 + `overclock` r5 = −0.25, which is
`test_build.gd:88-93`'s build), so any future consumer must clamp before
multiplying. Nothing in this spec reads it.

## 6. Wards

### 6.1 New stat keys

Five keys join `Module.STAT_KEYS` (11 → 16) and `ResolvedExploit`:

```
ward_armor  ward_defense  ward_clock_speed  ward_duration  travel
```

`equals` must cover these five plus `base_cooldown` — six new fields. Its only
caller is `test_build.gd:124`; `_recompile` (`run.gd:200-202`) rebuilds
unconditionally and dedupes nothing, so the reason to extend `equals` is the
permutation test, not runtime dedupe.

`travel` is separate from `radius` because `radius` already means "effect
radius" to BROADCAST, CHAIN and BEAM, and `fork_bomb` contributes 60.0 of it.

### 6.2 Two stats are exempt from rank scaling

`_fold` scales every stat by `em.rank`, exempting only a vector's `cooldown`
(`compiler.gd:62-67`). Two join it:

- **`travel` on a VECTOR** — §7.2. Load-bearing.
- **`ward_duration`** — hygiene, not a bound: §6.4 shows uptime is already
  saturated at rank 1, so rank-scaling duration would buy almost nothing. Kept
  so the stat means one thing.

### 6.3 Magnitude is a max at every level

Wards and `lifesteal` are **never summed**:

1. **Within an exploit** — `_fold` accumulates with `+` (`compiler.gd:68`), and
   the same module in both payload slots of one exploit is legal
   (`loadout.gd:76-79` appends `EMPTY_SLOT` whenever the occupant is null;
   `:81-83` states "Ranks are per SLOT, not per module"). So `_fold` uses
   `maxf` for the four `ward_*` keys and `lifesteal`. The doc comment at
   `loadout.gd:63-64` claiming "a module id appears at most once in the
   loadout" contradicts the code three lines below and is stale — §9 fixes it.
2. **Across exploits** — effective `armor` / `defense` / `clock_speed` = base +
   meta + the **max** of `ward_*` over exploits whose timer is live.

`maxf`-folding `ward_duration` makes duration per-*exploit*: `harden` (2.0) +
`sandbox` (3.0) in one exploit gives both a 3.0 s window. Accepted — uptime is
saturated regardless — but tested, because it is a real interaction.

### 6.4 Wards are high-uptime conditional passives

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

Every cell exceeds 1. Wards are up whenever the exploit fires, including on an
empty field. The levers that bound them are magnitude and max-at-every-level,
not uptime.

### 6.5 Wards apply before the vector branch

`_emit_vector` has two genuine early returns before any effect lands: BEAM at
`run.gd:470-472` and CHAIN at `run.gd:485-487`. (PACKET's `if pi >= 0` at
`run.gd:520` is **not** an early return — it is a guard around three array
writes at the end of the branch.)

Wards are vector-independent and apply at the **top** of `_emit_vector`, before
the `match`, so a targetless BEAM or CHAIN build still wards. Note this does
**not** save the cooldown: `_try_event_fire` sets `_fire_cd[ei]` *before*
calling `_emit_vector` (`run.gd:432-437`), so the cooldown is spent either way.
What the placement buys is the ward, not the cadence.

### 6.6 The worked worst case

Six payload slots, `max_rank` 5, shop rank 10, max-not-sum throughout:

- **armor** = 6.0 (`firewall` r10) + 6.0 (`harden` r5) = **12.0**
- **defense** = 60.0 (`encryption` r10) + 50.0 (`sandbox` r5) = **110.0**
  → 110/170 = **64.7% cut**
- ICE 22 → `maxf(4.4, 10.0)` = 10.0 → × 0.353 = **3.53 per hit**
- ÷ `IFRAMES` 0.5 = **7.06 dps**
- against 180 integrity (`memory` r10) = **25.5 s of continuous boss contact**

There is no sustain term because there is no sustain (§2). `keylog` is the one
healing source in the game and is priced separately in §9 as a known risk
rather than folded into this bound, because its rate depends on kill rate
rather than on the sheet.

**`nice`** at r5 = +60 `clock_speed` → 220 + 60 + 60 = **340** against a
fastest enemy of 118. Set to parity with the whole `bus_speed` shop line
(+60 for 1,950 salvage).

### 6.7 The modules

Three new PAYLOAD modules. None contributes `damage`.

| id | Stats | Reads as |
|---|---|---|
| `harden` | `ward_armor` 1.2, `ward_duration` 2.0 | flat-damage plate |
| `sandbox` | `ward_defense` 10.0, `ward_duration` 3.0 | percentage soak |
| `nice` | `ward_clock_speed` 12.0, `ward_duration` 1.5 | escape speed |

Module count 15 → 18, unlocked 12 → 15.

**Dilution: 4 of 15 = 27%** (the three new modules plus `keylog`). Earlier
drafts claimed the offer pool is narrower than the unlocked list because
"vectors need a free exploit." That is false — `legal_targets` offers `REPLACE`
for any occupied slot whose occupant is not `_is_last_interval`
(`loadout.gd:67-87`), and `_is_last_interval` returns `false` for anything that
is not an INTERVAL **TRIGGER** (`loadout.gd:195-199`), so a vector is always
displaceable. Executed against a full board, every unlocked module had a legal
target. The one narrowing that does exist is small: `legal_targets` omits a
`RANK_UP` for a module already at `max_rank`, so a late-game board can offer
slightly fewer than the full catalog. 27% is the nominal figure.

## 7. Trigger ordering and `travel`

### 7.1 `_damage_player` restructure

Triggers move ahead of the damage subtraction so a ward absorbs its own
triggering hit. With sustain out of scope this is the entire change:

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

`test_triggers.gd` is a behavioral harness — it asserts every trigger kind
fires (`:66-101`) and that `on_kill` respects its cooldown (`:24-61`) — but both
read `_trigger_fires`, and a grep over `tests/` finds no test reading
`player_health`. So the reorder breaks no shipped assertion; re-run the suite
anyway.

No recursion: `_try_event_fire` → `_emit_vector` → `_hit` → `queue.append`, and
`_damage_player` has exactly one call site (`run.gd:579`).

### 7.2 `travel` replaces the projectile cull

`packet` gains `travel: 640.0`, carried by
`_proj_dist_left: PackedFloat32Array` and decremented by
`projectiles.vel[i].length() * dt` (`Population` stores no scalar speed).

**`travel` becomes the sole lifetime bound for projectiles, replacing the
1600-unit player-distance test at `run.gd:726-727`.** Keeping both is what broke
revision 4's invariant: the cull is measured *from the player*, so a player
fleeing at the `clock_speed` this same spec raises to 340 adds
340 × (832/420) ≈ 673 px of separation, pushing a max-`reach` packet past 1600
and making `reach` silently inert exactly when you run away. Deleting the
player-relative test removes the interaction rather than tuning around it, and
is strictly safer for the pool: max travel is 640 × 1.30 = **832 px**, well
under 1600, so projectiles now live *shorter*, not longer. At the minimum
cooldown 0.05 s that is ≤ 40 live projectiles against `MAX_PROJECTILES` 400.

Three further requirements:

1. **`travel` must not rank-scale** (§6.2), or rank 3 gives 1920 px and the
   stat stops meaning anything bounded.
2. **640 > `VIEW_RANGE` 620** (`run.gd:25`) is deliberate: packets acquire
   targets within 620, so a shorter travel would make them fall short of
   targets they are allowed to shoot at — the inert-stat bug in a new place.
3. **Swap-move on despawn** at `run.gd:733`, and **two manual seeding sites** —
   `perf_milestone0.gd:178-183` and `tools/fps_probe.gd:70` (grep confirms
   these are the only two). A resized `PackedFloat32Array` gives 0.0, expiring
   every seeded projectile on its first integration pass and silently
   lightening the perf gate.

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
versions and `_sanitise` (`:94-113`) carries old ranks through. `buff_stats()`
splits into `player_sheet()` and `multipliers()`. Full clear 1,950 × 8 = 15,600.

### 8.1 One partial-table shape in three places — one is a live bug

`save_game.gd:168` is `for k in BUFF_EFFECT[StringName(name)]:` — a direct index
into a table of two names, iterated over `d["buffs"]`'s three. Reproduced:

```
SCRIPT ERROR: Invalid access to property or key 'bandwidth' ...
          at: buff_stats (res://scripts/meta/save_game.gd:168)
  PASS — all cases
```

It fires **once `bandwidth` has been bought** (`:166-167` skips rank-0 buffs),
and the consequence is worse than an abort: the function returns the typed
default `{}`, discarding the `cpu_cycles` and `cooling` contributions already
accumulated. **Any player who buys one rank of bandwidth silently loses every
rank of cpu_cycles and cooling** at `run.gd:182`. Fix with `.get(name, {})`
(Godot 4.7 treats StringName and String keys as equal).

The suite hides it because `test_meta.gd:71` asserts a *negative* —
`buff_stats().has(&"radius") == false` — which an aborted function satisfies for
free, and which is vacuous for a second reason: `BUFF_EFFECT` has no `radius`
key at all. §9 **replaces** that assertion.

Same shape twice more: `_default()["buffs"]` (`save_game.gd:40`) must gain all
eight names or `_sanitise` drops them every round-trip, and `meta_screen.gd:90`
direct-indexes without `.get`, crashing the shop on open.

### 8.2 Layout: a bounded ScrollContainer

Five new rows add 5 × (30 + 10) = **200 px** to a column starting at y=52 in a
720 px viewport, against roughly **164 px** of headroom.

Two columns do **not** fit: one row is 230 + 12 + 240 + 12 + 150 = **644 px**
(`meta_screen.gd:44-50`), and two from x=64 need ≥1352 px against
`viewport_width=1280` — overflowing by ≥72 px, and what clips is the second
column's buy button.

**Wrap the rows in a `ScrollContainer` with an explicit
`custom_minimum_size` height and `size_flags_vertical = SIZE_FILL`, and pin
`./intrude` outside it.** The bound is required: a `ScrollContainer` with no
height constraint inherits its content's minimum height and pushes the button
down exactly as the bare `VBoxContainer` does today.

## 9. Files and tests

**Modified:** `module.gd` (STAT_KEYS 11→16), `resolved_exploit.gd` (five stat
fields + `base_cooldown` + `equals`), `compiler.gd` (`buffs` deleted, `mult`
added, the `travel`/`ward_duration` carve-out, `maxf` folding for `ward_*` and
`lifesteal`), `loadout.gd` (`mult` field replacing `buffs`; **the stale
`:63-64` comment**), `module_table.gd` (three modules, `packet.travel`, **the
`:11-12` counts**), `run.gd` (**`:182` → `loadout.mult = SaveGame.multipliers()`**,
`_ward_left`, mitigation, effective stats, `_damage_player` order,
`_proj_dist_left` **replacing** the `:726-727` cull, the `:733` swap-move, the
`_step6_detect` state guard, `_ready` re-seed of `player_health`),
`save_game.gd` (**the `:168` bug**, eight buffs, `_default()` keys, VERSION 2,
`player_sheet()` / `multipliers()`, **the `:22-27` comment**), `meta_screen.gd`
(eight rows in a bounded ScrollContainer, **the `:11-13` BUFFS description
strings** — "damage +1.5 per rank" and "cooldown -0.02 per rank" are false
under multipliers — **and the `:39` label**), `ui.gd` (`:123`, `:127`,
armor/defense readout, ward indicator), `tools/fps_probe.gd:70`,
`tests/perf_milestone0.gd`, **`README.md:27`** (payload list) and
**`README.md:81`** ("Not in this build: … in-run stat changes" — wards are).

**New:** `scripts/build/player_stats.gd`.

**New tests** (none of these exist yet — this is a spec, not an implementation):

- `test_player_stats.gd` — `mitigate` at the worm tie point (5, armor 4 → 1.0);
  armor ≫ incoming floors at 20%; defense at 0, `DEFENSE_K`, 10× `DEFENSE_K`,
  and **negative**; the identity at 0/0.
- `test_wards.gd` — set/decay/expiry; two exploits with the same ward take the
  max; the **same module in both payload slots of one exploit** takes the max;
  **two different wards in one exploit** share the longer duration; a BEAM ward
  with no target still applies; `ward_clock_speed` moves the player at
  `run.gd:330`.
- `test_multipliers.gd` — **through `run._recompile()`, not `Compiler.build`**:
  set an `attack` rank, recompile, assert `resolved[0].damage` moved. This is
  the only test positioned to catch a `loadout.gd` omission. Also: `attack`
  scales `corruption`; `haste` before `MIN_COOLDOWN` (mid-range cooldown, e.g.
  0.20 × 0.70 = 0.14); the 11 excluded keys untouched; a packet expires at
  `travel` and **not** at a player-relative distance (fire, then flee, and
  assert the projectile still reaches its range); `_proj_dist_left` survives
  swap-remove; an expired projectile does not hit on its expiry tick.
- `test_player_sheet.gd` — a run with `memory` r10 starts at 180; a run with
  `bus_speed` r10 moves farther per tick (the meta path into `run.gd:330`,
  distinct from the ward path).

**Updated:** `test_build.gd:48` 15 → **18** (and the `:47` label);
`test_meta.gd:76` 12 → **15**; `test_meta.gd:39` `5850` → `15600`;
`test_meta.gd:59,61,64,69-72` rewritten against `player_sheet()` /
`multipliers()` asserting **positively** on all eight names, with `:71`'s
vacuous negative **deleted**. `test_build.gd` also gains: new keys fold and
rank-scale, `travel`/`ward_duration` do not, `ward_*` and `lifesteal` fold by
max, and `equals` distinguishes ward-only differences.

**Manual gate:** `tools/shot_meta.gd` drives the shop screen; use it to confirm
eight rows and `./intrude` fit 720 px. No automated check exists.

**Perf gate:** `perf_milestone0.gd` must still pass.

## 10. Known risks and what is out of scope

1. **`keylog` is unbounded, and this spec raises its ceiling.** `lifesteal` is
   applied per adjudicated death (`run.gd:666-670`) with no cooldown and no
   per-tick cap, and §3.1 re-points its clamp from `PLAYER_MAX_HEALTH` to
   effective `integrity`, so a `memory`-r10 player heals toward 180 instead of
   100. `maxf` folding (§6.3) holds it to 2.0 HP/kill at r5, which breaks even
   against §6.6's 7.06 dps at **3.53 kills/s** — reachable for a broadcast build
   in a swarm, not during boss contact. This is stated rather than fixed:
   bounding per-kill healing means bridging the drain phase to the integrate
   phase, which is precisely the mechanism that failed review twice (§11).
   Sustain gets its own pass or none.
2. **`attack` triple-dips on corruption builds**: flip rate, flip payoff, and
   botnet aura damage (`_on_flip` computes `corr` at `run.gd:683-685`, assigns
   `_botnet_ratio[bi]` at `:688`).
3. **Wards are conditional passives**, so defense is weakest when the screen is
   empty and strongest under pressure.
4. **The magnitudes come from worked worst cases, not from play.**

**Out of scope:** all new healing; knockback / `throttle` (it wrote into
`enemies.force[i]`, which `_step4_steer` *assigns* rather than accumulates
(`run.gd:414,427`) on a 2-tick slice, giving 4–9 px of displacement against a
12 px radius, and worm segments skip the force path entirely at
`run.gd:409-411`); character select; armor as a regenerating second bar; any
change to `IFRAMES`; dynamic offensive multipliers.

## 11. Review record

Three rounds of a six-reviewer panel plus a two-reviewer verification pass.
Round 1: six REVISE. Round 2: one APPROVED, five REVISE. Round 3: six REVISE.
Verification pass on revision 4: two REVISE. No contradictions between
reviewers except one, resolved in §7.2.

**Every round found the same bug class in the machinery written to fix the
previous round.**

- **R1** — the multipliers would have shipped dead: `loadout.gd` was missing
  from the file list, the new parameter defaulted to `{}`, and every planned
  test called `Compiler.build` directly.
- **R2** — the rebalance covered `harden` and `sandbox` but not `gc` and
  `nice`; `gc` reached 3,600 HP/s against 7.06 dps incoming, and R1's own
  wards-before-early-returns fix is what made it an out-of-combat regen.
- **R3** — the heal gate was unevaluable on PACKET, the starting vector; the
  cross-exploit heal "max" had no read point, so rates summed to immortality;
  and `keylog` was exempt from every bound the document introduced.
- **Verification** — routing `lifesteal` into the `_step2_integrate` rate was
  mechanically impossible (it is generated per-kill in the drain, and revision 4
  deleted the accumulator that could bridge the phases), and arming the heal
  timer at emit time turned PACKET sustain into "heal-on-aim".

**Sustain failed four times, in four different ways. Revision 5 removes it**
rather than attempting a fifth design — the rule revision 4 committed to in
advance. What survives is what never failed review: `armor`/`defense`, the
ward mechanism, the multipliers, the stat sheet, and `travel`.

Revision 5 is the first revision that **deletes** machinery instead of adding
it. That matters given the record above: there is no new mechanism in it to be
wrong. The residual risk is concentrated in §7.2's cull replacement, which is
the one behavioural change that is not a deletion.

Across the drafts, **fifteen** statements about the codebase turned out to be
false — a mischaracterised test file, a fabricated `equals` mechanism, a
mitigation row contradicting its own function, a quoted line that did not
exist, a dilution figure resting on a false claim about `legal_targets`, a
cooldown claim contradicted by `run.gd:432-437`, and nine citations pointing at
wrong lines. Every one was caught by a reviewer opening the file. Two were
settled only by executing the code, and one — the packet travel invariant — was
invalidated by a different section of the same document.
