# ROOTKIT — Design Spec

**Date:** 2026-08-29
**Engine:** Godot 4.7 stable, GDScript
**Genre:** Bullet heaven (Vampire Survivors lineage), hacking theme

---

## 1. Concept

You are a rogue process descending through a corporate network. You move with
WASD; every weapon fires automatically. You survive five-minute subnets, choose
your next node on a branching map, and either die or reach the core.

Power comes from **compiling exploits** out of modules dropped by level-ups.
The hacking theme is not a skin: the build system *is* the hacking.

Three ideas stack:

- **Setting** — a rogue process in a hostile network. Enemies are firewalls,
  AV daemons, and worms.
- **Build (the spine)** — weapons are exploits assembled from typed modules.
  Every level-up is a real composition decision.
- **Payoff branch** — corrupting an enemy flips it into your botnet. This is
  one branch of the module tree, not a parallel system.

---

## 2. The compile system

### 2.1 Modules

A module is a `Resource` saved as a `.tres` file in `data/modules/`. It has a
slot type, a set of tags, and a flat set of stat contributions.

```gdscript
class_name Module extends Resource

enum Slot { VECTOR, TRIGGER, PAYLOAD }

@export var id: StringName
@export var display_name: String
@export var slot: Slot
@export var tags: Array[StringName]        # e.g. [&"corruption", &"aoe"]
@export var max_rank: int = 5
@export var stats: Dictionary              # additive contributions per rank
@export var hook: StringName               # optional named behavior hook
```

### 2.2 Exploits

An **Exploit** is one weapon. It holds:

| Slot      | Count | Decides                | Examples |
|-----------|-------|------------------------|----------|
| `VECTOR`  | 1     | How it reaches enemies | `broadcast` (aura), `packet` (projectile), `chain(n)`, `beam` |
| `TRIGGER` | 1     | When it fires          | `interval(t)`, `on_kill`, `on_hit`, `on_damage_taken` |
| `PAYLOAD` | 0–2   | What it does on contact| `buffer_overflow` (+dmg), `fork_bomb` (AoE), `corrupt`, `keylog` (lifesteal) |

The player holds up to **5 exploits**. An exploit with no `VECTOR` or no
`TRIGGER` is inert and does not fire.

### 2.3 Compilation

Compilation runs **once per module pick**, never per frame.

`Compiler.build(exploit) -> ResolvedExploit` folds every equipped module into a
single flat struct:

```gdscript
class_name ResolvedExploit extends RefCounted

var damage: float
var corruption: float
var cooldown: float
var radius: float
var pierce: int
var chain_count: int
var projectile_speed: float
var tags: Dictionary            # tag -> accumulated weight
var hooks: Dictionary           # event name -> Array[Callable]
```

Combat code reads only `ResolvedExploit`. This is what keeps hundreds of
entities cheap and what puts every balance number in one place.

Resolution order is fixed and total: base stats from `VECTOR`, then `PAYLOAD`
modules in slot order, then `TRIGGER`. Additive stats sum; multiplicative stats
(marked with a `mul_` prefix) multiply after all additions. This ordering is
deterministic so that two identical loadouts always resolve identically.

### 2.4 Level-up and auto-slotting

On level-up the game pauses and offers **three module cards**. Each card names
its destination exploit (`→ exploit_02`) so the player never opens a menu.

Auto-slot rules, in order:

1. If the module is already equipped and below `max_rank`, offer it as a
   **rank-up** on the exploit that holds it.
2. Otherwise, place it in the first exploit with an empty compatible slot,
   scanning exploits in index order.
3. Otherwise, if an unused exploit slot exists (fewer than 5 exploits), start a
   new exploit with this module.
4. Otherwise, offer it as a **replacement**, naming the module it displaces.

The card shows the resulting delta (`dmg 18 → 26`) so the choice is legible
without arithmetic.

### 2.5 Build depth without special cases

Interactions come from tags, not bespoke code:

- `corrupt` + `chain(3)` — infection spreads through packed groups.
- `on_kill` + `fork_bomb` — chain-reaction detonations.
- `on_damage_taken` + `broadcast` — a punish build that rewards being swarmed.

New modules are new `.tres` files. Only genuinely novel behavior needs a new
hook function.

---

## 3. Enemies, corruption, and the botnet

### 3.1 Enemies

Enemies are pooled `Area2D` nodes. All enemies of a type render through one
`MultiMeshInstance2D` as glyph quads — one draw call per type. Each enemy has:

- `integrity` — hit points. Reaching zero destroys it.
- `corruption` — a second bar filled only by payloads tagged `corruption`.

### 3.2 Flipping

An enemy whose `corruption` reaches its threshold **flips** into a botnet node
that fights for the player, then decays after a lifetime. Flipping consumes the
enemy regardless of remaining `integrity`.

Botnet nodes are capped at **8** by default. The cap is raised by
botnet-branch modules. When at cap, a new flip replaces the oldest node.

Botnet nodes deal a fixed fraction of the player's highest-damage resolved
exploit; they do not run the player's exploits themselves. This keeps the
branch a payoff rather than a second build system.

---

## 4. Run structure

A **subnet** is five minutes in one arena. A `SpawnDirector` reads a wave table:

```
time_start, time_end, enemy_type, spawn_rate, formation
```

Formations are named spawn patterns (`ring`, `stream`, `flank`, `burst`).

At 5:00 an **ICE boss** spawns and normal spawning stops. Killing it ends the
subnet and opens a small branching node map where the player picks the next
subnet. Salvage carries between subnets within a run and is lost on death.

---

## 5. Meta progression

Between runs, salvage buys permanent, small buffs:

- `+CPU cycles` — damage
- `+cooling` — cooldown reduction
- `+bandwidth` — pickup radius

New modules unlock from in-run milestones (e.g. "flip 50 enemies" unlocks
`worm`). Unlocked modules enter the level-up card pool for future runs.

State persists to `user://save.json`: salvage total, purchased buffs, unlocked
module ids, and milestone counters. The save is versioned; an unreadable or
newer-versioned save is discarded and regenerated rather than migrated.

---

## 6. Presentation

Everything is drawn in code on black. No image assets in the repository.

- Player and boss: glowing wireframe polygons.
- Enemies: monospace glyphs rendered as textured quads from a generated font
  atlas.
- Post: a `CanvasLayer` shader applying scanlines and bloom.
- HUD: a fake terminal readout — health as `integrity`, XP as a progress bar of
  hash characters, timer as a countdown.

---

## 7. Architecture

```
project.godot
scenes/
  main.tscn  run.tscn  hud.tscn  level_up.tscn
scripts/
  core/     spatial_index.gd  object_pool.gd  event_bus.gd
  build/    module.gd  exploit.gd  compiler.gd  loadout.gd
  actors/   player.gd  enemy.gd  botnet_node.gd  projectile.gd
  run/      spawn_director.gd  subnet.gd
  meta/     save.gd  unlocks.gd
data/modules/  *.tres
tests/
```

### Unit boundaries

- `Compiler` — pure. Modules in, `ResolvedExploit` out. No scene tree access.
- `Loadout` — owns the player's exploits and the auto-slot rules. Pure.
- `SpatialIndex` — the single interface for "what is near this point".
  Physics-backed initially; swappable to a hand-rolled uniform grid without
  touching game logic if the botnet swarm degrades framerate.
- `ObjectPool` — allocation-free spawn/despawn for enemies and projectiles.
- `EventBus` — an autoload for cross-cutting signals (`enemy_died`,
  `enemy_flipped`, `level_up`) so hooks do not need direct references.

---

## 8. Testing

GUT, run headless via `godot --headless -s addons/gut/gut_cmdln.gd`.

Covered:

- `Compiler` resolution — additive/multiplicative ordering, rank scaling,
  determinism of identical loadouts.
- `Loadout` auto-slot rules — all four branches, including the cap cases.
- Corruption math — flip thresholds, botnet cap and oldest-node eviction.
- `SpawnDirector` — wave table produces the expected counts over a simulated
  five minutes.
- `Save` — round-trip, and discard of malformed or future-versioned files.

Not covered by tests: rendering, shaders, and game feel. Those are playtested.

---

## 9. V1 scope

**In:**

- Subnet 1 and its ICE boss.
- 15 modules spanning all three slot types, including the botnet branch.
- The full compile and level-up loop.
- Meta save with buffs and unlocks.
- The node map, scaffolded with a single route.

**Out of v1:** additional subnets, multiple playable processes, audio, controller
support, and the alternate `SpatialIndex` implementation.

---

## 10. Decisions on record

| Decision | Choice | Why |
|---|---|---|
| Spine | Compiling; botnet is one branch of it | Two full progression systems would fight for balance space |
| Level-up UX | Three cards, auto-slotted, destination named | Keeps pace; no menu drag during combat |
| Run shape | Stacked 5-minute subnets with route choice | Variety and a finished-feeling run |
| Meta | Permanent buffs plus module unlocks | Gives a reason to replay after a loss |
| Art | Vector and glyph neon, drawn in code | No art pipeline; scales to hundreds of entities |
| Controls | WASD only, all auto-fire | Keeps the build as the sole decision layer |
| Language | GDScript | Faster iteration; adequate with pooling and flat resolution |
| Composition | Resource modules plus pooled nodes | Cheap content authoring, idiomatic Godot |
| Perf hedge | `SpatialIndex` interface | Swap in a grid later without touching game logic |
