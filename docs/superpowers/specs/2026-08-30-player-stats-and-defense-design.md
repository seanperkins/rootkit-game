# ROOTKIT — Player Stats & Defensive Modules

**Date:** 2026-08-30
**Status:** design approved, not yet implemented
**Builds on:** `2026-08-29-rootkit-bullet-heaven-design.md`

---

## 1. Problem

The game has two stat namespaces that cannot talk to each other.

Exploit stats live on `ResolvedExploit` and are folded from modules by
`Compiler.build`. Player stats do not exist: `PLAYER_MAX_HEALTH`,
`PLAYER_SPEED`, `PICKUP_RADIUS` and `IFRAMES` are `const` in `run.gd`.

Three consequences:

1. There is no damage mitigation of any kind. `_damage_player` subtracts the
   raw contact damage; only `IFRAMES` limits incoming damage rate.
2. Nothing can adjust movement speed, health, or pickup range — the meta shop
   sells `bandwidth` for pickup radius and, until recently, delivered exploit
   radius instead (`save_game.gd:25`). That bug was a symptom of the missing
   namespace, not a typo.
3. Every payload is offensive. `keylog` (lifesteal) is the sole exception and
   reads as an anomaly rather than a category.

## 2. Decisions

| Question | Decision |
|---|---|
| Scope | One player stat sheet now; a "character" is later a named set of starting values dropped into it. No select screen in this work. |
| Layering | Player sheet holds survivability/mobility outright, plus three global multipliers applied to every exploit after the flat module fold. Modules stay additive-flat. |
| Mitigation | Two stats: `armor` (flat subtract, floored) and `defense` (percentage, diminishing returns). They answer different threats. |
| Defensive modules | No new slot. Defensive modules are legal in PAYLOAD slots and compete with offensive payloads. |
| When defense applies | On the holding exploit's TRIGGER, not passively. Defense is wired through the same grammar as attack. |
| `reach` vs packet | In scope. PACKET gains a dedicated `travel` stat; `reach` scales it. |
| `on_damage_taken` ordering | Restructured: triggers fire *before* damage is applied, so a reactive ward absorbs the hit that triggered it. |

## 3. The stat sheet

`scripts/build/player_stats.gd` — pure, no scene tree, same discipline as
`scripts/build/`.

| Stat | Base | Group | Replaces |
|---|---|---|---|
| `integrity` | 100.0 | survival | `run.gd PLAYER_MAX_HEALTH` |
| `armor` | 0.0 | survival | — new |
| `defense` | 0.0 | survival | — new |
| `clock_speed` | 220.0 | mobility | `run.gd PLAYER_SPEED` |
| `pickup_radius` | 30.0 | mobility | `run.gd PICKUP_RADIUS` |
| `attack` | 1.0 | multiplier | — new |
| `haste` | 1.0 | multiplier | — new |
| `reach` | 1.0 | multiplier | — new |

`integrity` deliberately reuses the name `EnemyTable.EnemyType` already uses
for hit points. One word, one meaning.

The three constants in `run.gd` become the base values here and are deleted.
`IFRAMES` stays a constant — it is a timing guarantee, not a stat, and making
it buyable invites a build that is untouchable.

## 4. Mitigation

```gdscript
const ARMOR_FLOOR := 0.2      # armor never blocks more than 80% of a hit
const DEFENSE_K := 60.0       # defense at which reduction is 50%

static func mitigate(incoming: float, armor: float, defense: float) -> float:
	var after_armor := maxf(incoming * ARMOR_FLOOR, incoming - armor)
	return after_armor * (1.0 - defense / (defense + DEFENSE_K))
```

Both terms are unbounded-input safe: armor cannot zero a hit because of the
floor, and defense cannot reach 1.0 because the ratio is asymptotic. This is
the same bug class the compiler already guards with `MIN_COOLDOWN` and
`MAX_PROJECTILE_SPEED` — an unbounded additive stat — handled by shape rather
than by clamp.

Against the real contact damage in `enemy_table.gd`, at armor 4 / defense 60:

| Enemy | Raw | After armor | After defense |
|---|---|---|---|
| worm | 5 | 2.0 | 1.0 |
| daemon | 7 | 3.0 | 1.5 |
| firewall | 12 | 8.0 | 4.0 |
| ICE | 22 | 18.0 | 9.0 |

Armor cuts swarm chip by 57% and ICE by 18%; defense cuts everything evenly.
Neither obsoletes the other, which is why both are worth a card.

## 5. Global multipliers in the compiler

`Compiler.build` gains a third parameter:

```gdscript
static func build(ex: Exploit, buffs: Dictionary = {},
		mult: Dictionary = {}) -> ResolvedExploit
```

Applied after the additive `buffs` fold and **before** the existing clamps:

| Multiplier | Scales | Note |
|---|---|---|
| `attack` | `damage`, `corruption` | See below |
| `haste` | `cooldown` (values < 1.0 are faster) | Applied before `MIN_COOLDOWN` |
| `reach` | `radius`, `travel` | `travel` is PACKET's range (§7.2) |

**`attack` scales `corruption` as well as `damage`.** Corruption is a damage
type — the design spec calls it "damage tagged corruption". If `attack` scaled
only `damage`, every point of the game's headline offensive stat would be dead
weight to a corruption build, which is exactly the failure the `bandwidth`
bug demonstrated: a stat that silently does nothing for a legal build. The
cost is that corruption builds get both the multiplier and the flip payoff;
that is a balance number to tune, not a structural flaw.

Multipliers do **not** touch ward stats, `pierce`, `chain_count`,
`botnet_*`, or `projectile_speed`. `projectile_speed` is excluded because its
cap exists to prevent tunnelling through the smallest combined radius; a
multiplier applied before the cap would silently do nothing at high values.

`buffs` is retained as a seam even though no shop upgrade feeds it after §8.
Tests use it, and a future additive source is likely.

## 6. Wards and defensive payloads

### 6.1 New stat keys

Eight keys join `Module.STAT_KEYS` (11 → 19) and `ResolvedExploit`:

```
ward_armor  ward_defense  ward_clock_speed  ward_duration
heal  knockback  knockback_radius  travel
```

They fold through the existing `Compiler._fold`, so module rank scales them
with no new machinery. `ResolvedExploit.equals` must be extended to cover all
eight or recompiles will silently dedupe distinct builds.

`knockback_radius` and `travel` are separate keys rather than reuses of
`radius` on purpose. `radius` already means "effect radius" to BROADCAST,
CHAIN and BEAM, and `fork_bomb` contributes 60.0 of it; overloading it for
PACKET range or knockback range would make an unrelated payload silently
change a packet's flight distance. One key, one meaning.

### 6.2 Ward bookkeeping

One float per exploit, in `run.gd`:

```gdscript
var _ward_left: PackedFloat32Array   # sized Loadout.MAX_EXPLOITS
```

- `_emit_vector` sets `_ward_left[ei] = r.ward_duration` when `ward_duration > 0`.
- `_step2_integrate` decrements it alongside `player_iframe`.
- Effective `armor` / `defense` / `clock_speed` = base + meta + the sum of
  `ward_*` over every exploit whose timer is live.

Three floats total. No allocation, no per-effect objects, and the magnitudes
come straight off the already-compiled `ResolvedExploit` — the same
"compile once, combat reads flat values" rule as damage.

Two exploits both running `harden` genuinely stack, which rewards committing
payload slots to defense. The stack is bounded at `MAX_EXPLOITS` by
construction, so no cap is needed.

`heal` and `knockback` are instantaneous and applied directly in
`_emit_vector`. `knockback` queries the grid at `knockback_radius` and writes
into `enemies.force[i]`, the field separation steering already uses, so it
needs no new state.

### 6.3 The modules

Five new PAYLOAD modules. None contributes `damage`, so equipping one is a
real cost against the two payload slots.

| id | Stats | Reads as |
|---|---|---|
| `harden` | `ward_armor` 2.0, `ward_duration` 2.0 | reactive plate |
| `sandbox` | `ward_defense` 18.0, `ward_duration` 3.0 | steady uptime |
| `gc` | `heal` 3.0 | sustain, best on `on_kill` |
| `nice` | `ward_clock_speed` 70.0, `ward_duration` 1.5 | panic escape |
| `throttle` | `knockback` 260.0, `knockback_radius` 90.0 | crowd control |

`keylog` (lifesteal) is retroactively a member of this category and needs no
change.

Module count goes 15 → 20, unlocked 12 → 17. Defensive modules become ~29% of
the offer pool, so roughly one of every three cards. If play shows that is too
much dilution, the fix is a draw weight in `_offer_cards`, not a redesign.

### 6.4 Trigger gating

`_try_event_fire` already refuses to fire while `_fire_cd[ei] > 0.0`. A ward
therefore cannot pop on every incoming hit — its uptime is gated by the
exploit's compiled cooldown. That is the balance lever, and it already exists.

## 7. Trigger ordering and `reach`

### 7.1 `_damage_player` restructure

Today the function subtracts health, then fires `ON_DAMAGE_TAKEN` triggers. A
reactive ward under that order protects against the *next* hit, not the one
that summoned it. The new order:

```gdscript
func _damage_player(amount: float) -> void:
	for ei in resolved.size():                    # 1. triggers first
		var r: ResolvedExploit = resolved[ei]
		if not r.inert and r.trigger_kind == Module.TriggerKind.ON_DAMAGE_TAKEN:
			_try_event_fire(ei, r)
	player_health -= _mitigated(amount)           # 2. then damage, mitigated
	player_iframe = IFRAMES
	...
```

No existing test asserts the old ordering — `test_triggers.gd` covers only the
enum mapping — so this breaks nothing mechanically. The behavioral change is
intended and load-bearing: a `harden` ward can now save a run from a hit that
would otherwise have been lethal.

No recursion risk: the trigger path runs `_emit_vector` → `_hit` →
`queue.append`, and never re-enters `_damage_player`.

### 7.2 PACKET travel distance

`packet` gains `travel: 700.0` in the module table, and the PACKET branch of
`_emit_vector` reads `r.travel` as the projectile's maximum flight distance.
A run-side array in the established `_proj_owner` / `_proj_pierce` pattern
carries it:

```gdscript
var _proj_dist_left: PackedFloat32Array
```

Set on spawn, decremented by `speed * dt` in the projectile half of
`_step2_integrate`, marked dead at `<= 0`.

This makes `reach` mean the same thing for all four vectors and closes the
last case where a stat would be legal to buy and inert for a legal build.
Cost is one packed array and one subtraction in the integrate step;
`perf_milestone0.gd` is the gate.

## 8. Meta shop v2

Eight upgrades, one per stat, replacing the current three.

| Buff | Stat | Per rank | At rank 10 |
|---|---|---|---|
| `cpu_cycles` | `attack` | +0.04 | ×1.40 |
| `cooling` | `haste` | −0.03 | ×0.70 |
| `memory` | `integrity` | +8.0 | 180 |
| `firewall` | `armor` | +0.6 | 6.0 |
| `encryption` | `defense` | +6.0 | 60.0 (50% cut) |
| `bus_speed` | `clock_speed` | +6.0 | 280 |
| `addressing` | `reach` | +0.03 | ×1.30 |
| `bandwidth` | `pickup_radius` | +6.0 | 60 |

`cpu_cycles` and `cooling` change meaning — from `+1.5` flat damage and
`-0.02s` cooldown to multipliers. `SaveGame.VERSION` goes 1 → 2. Existing
ranks carry over and mean the new thing; no refund. The game has no players,
so migration code would guard nothing.

`SaveGame.buff_stats()` splits into `player_sheet()` (additive player stats)
and `multipliers()` (the three scalars). `meta_screen.gd BUFFS` grows to eight
rows; its existing three-column layout takes them unchanged.

Full clear is 1,950 salvage per buff × 8 = 15,600.

## 9. Files and tests

**Modified:** `module.gd` (STAT_KEYS), `resolved_exploit.gd` (six fields +
`equals`), `compiler.gd` (`mult` param), `module_table.gd` (five modules,
`packet.travel`), `run.gd` (ward timers, mitigation, effective stats,
`_damage_player` order, `_proj_dist_left`), `save_game.gd` (eight buffs,
VERSION 2), `meta_screen.gd` (eight rows), `ui.gd` (armor/defense readout,
ward indicator).

**New:** `scripts/build/player_stats.gd`.

**New tests:**

- `test_player_stats.gd` — `mitigate` boundaries: armor far exceeding incoming
  floors at 20%; defense at 0, at `DEFENSE_K`, and at 10× `DEFENSE_K` never
  reaching 1.0; the two composed in the documented order.
- `test_wards.gd` — a ward is set on fire and decays; wards sum across two
  exploits; an expired ward contributes nothing; an `on_damage_taken` ward
  absorbs its own triggering hit; `_fire_cd` gates ward re-application.

**Updated tests:** `test_build.gd` (new stat keys fold and rank-scale;
`equals` distinguishes builds differing only in a ward field), `test_meta.gd`
(eight buffs, a v1 save loads under VERSION 2).

**Gate:** `perf_milestone0.gd` must still pass with `_proj_dist_left` in the
integrate step.

## 10. Known risks

1. **`attack` scaling `corruption` may over-reward corruption builds**, which
   already collect flip value on top. Tunable via the per-rank number; called
   out here so it is watched rather than discovered.
2. **Card dilution at 29% defensive** is a guess. The lever is a draw weight,
   not a redesign.
3. **`_damage_player` reordering** is a real behavior change to a shipped
   trigger. Intended, but any report of "on_damage_taken feels different"
   traces here.

## 11. Explicitly out of scope

Character select, in-run stat pickups outside the module system, armor as a
regenerating second bar, healing outside `gc` and `keylog`, and any change to
`IFRAMES`.
