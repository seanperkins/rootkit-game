# ROOTKIT — Design Spec

**Date:** 2026-08-29
**Engine:** Godot 4.7 stable, GDScript
**Genre:** Bullet heaven (Vampire Survivors lineage), hacking theme
**Revision:** 3 — after two rounds of a six-reviewer panel. See §12.

---

## 1. Concept

You are a rogue process descending through a corporate network. You move with
WASD; every weapon fires automatically. You survive a five-minute subnet and
either die or reach the core.

Power comes from **compiling exploits** out of modules dropped by level-ups.
The hacking theme is not a skin: the build system *is* the hacking.

- **Setting** — a rogue process in a hostile network. Enemies are firewalls,
  AV daemons, and worms.
- **Build (the spine)** — weapons are exploits assembled from typed modules.
- **Payoff branch** — corrupting an enemy flips it into your botnet. One branch
  of the module tree, not a parallel system.

---

## 2. The compile system

### 2.1 Modules

A module is a `Resource` (`scripts/build/module.gd`) saved as `.tres` in
`data/modules/`.

```gdscript
class_name Module extends Resource

enum Slot        { VECTOR, TRIGGER, PAYLOAD }
enum VectorKind  { BROADCAST, PACKET, CHAIN, BEAM }
enum TriggerKind { INTERVAL, ON_KILL, ON_HIT, ON_DAMAGE_TAKEN }

@export var id: StringName
@export var display_name: String
@export var slot: Slot
@export var tags: Array[StringName]
@export var max_rank: int = 5
@export var stats: Dictionary[StringName, float]
@export var vector_kind: VectorKind    # read only when slot == VECTOR
@export var trigger_kind: TriggerKind  # read only when slot == TRIGGER
```

**Stat key validation.** `stats` keys must name one of the **numeric scalar
fields** of `ResolvedExploit`, enumerated explicitly:

```
damage, corruption, lifesteal, cooldown, radius, pierce, chain_count,
projectile_speed, botnet_cap, botnet_lifetime, botnet_damage_ratio
```

`vector_kind`, `trigger_kind`, and `tags` are **not** valid stat keys —
asserting against "fields of `ResolvedExploit`" would have admitted
`stats["tags"] = 1.0`. `Compiler.build` rejects any other key, naming the
module and the key, and a data-driven test loads every `.tres` in
`data/modules/` and asserts clean resolution.

**Rank.** `stats` are per-rank: a module at rank `r` contributes `value * r`.
Rank starts at **1** on first placement.

**Integer stats.** `pierce`, `chain_count`, and `botnet_cap` are ints on
`ResolvedExploit` but accumulate as floats. The fold is done entirely in float
and `floori()` is applied **once, at the end of `build`** — so 0.5 + 0.5 = 1,
not 0 + 0 = 0. (The `mul_` deletion did not resolve this; additive float→int
has the same ambiguity.)

### 2.2 Exploits

| Slot      | Count | Decides                | Modules |
|-----------|-------|------------------------|---------|
| `VECTOR`  | 1     | How it reaches enemies | `broadcast` (aura), `packet` (projectile), `chain`, `beam` |
| `TRIGGER` | 1     | When it fires          | `interval`, `on_kill`, `on_hit`, `on_damage_taken` |
| `PAYLOAD` | 0–2   | What it does on contact| `buffer_overflow`, `fork_bomb`, `corrupt`, `keylog`, `worm`, `botnet_expand`, `overclock` |

The player holds up to **3 exploits in V1** (§10 gives the arithmetic). An
exploit missing a `VECTOR` or a `TRIGGER` is **inert** and does not fire.

Rule 3 (§2.5) founds a new exploit from a VECTOR, which is inert until a
TRIGGER lands in it. That is a **transient** inert state, and it is fine — the
guarantee §2.5 makes is that no exploit is founded in a state it can never
leave, which is why rule 3 is VECTOR-only. (Revision 2 claimed no inert exploit
could ever exist; that was false against its own rule 3.)

```gdscript
class_name EquippedModule extends RefCounted   # scripts/build/exploit.gd
var module: Module
var rank: int      # 1..module.max_rank
```

**Module ids are globally unique across the loadout.** `Loadout` asserts this
after every mutation; it is what makes the rank-up rule singular.

### 2.3 Compilation

Runs **once per module pick**, never per frame.

```gdscript
class_name ResolvedExploit extends RefCounted  # scripts/build/exploit.gd

var vector_kind: Module.VectorKind
var trigger_kind: Module.TriggerKind
var damage: float
var corruption: float
var lifesteal: float
var cooldown: float
var radius: float
var pierce: int
var chain_count: int
var projectile_speed: float
var botnet_cap: int
var botnet_lifetime: float
var botnet_damage_ratio: float
var tags: Dictionary        # StringName -> true. A set.
```

**Kind fold.** `vector_kind` is read **only** from the VECTOR module,
`trigger_kind` **only** from the TRIGGER module. Folding them from every module
in turn would let the TRIGGER module's default enum value clobber the vector.

**Stat fold.** Base stats from `VECTOR`, then `PAYLOAD` modules **sorted by
module id**, then `TRIGGER`. Then meta buffs (§6). All additive.

**Clamps, applied at the end of `build`:**

- `cooldown = max(cooldown, MIN_COOLDOWN)` where `MIN_COOLDOWN = 0.05`.
- `projectile_speed = min(projectile_speed, MAX_PROJECTILE_SPEED)` where
  `MAX_PROJECTILE_SPEED = 960.0` px/s. §4.2 derives that number. Without this
  clamp, `projectile_speed` was an unbounded additive stat — structurally the
  same bug the cooldown floor exists to prevent, but failing silently as missed
  hits instead of as a hang.
- `floori()` on the three integer fields.

**Expressiveness limit, on record.** A flat struct cannot express sequencing
*inside* one exploit — "this payload fires only on the chain's final bounce."
No V1 module needs it. Adding it later means a nested execution graph and
re-authoring modules: a known one-way door, taken deliberately.

### 2.4 Fire budget

Every exploit has a **per-tick fire budget of 4**, covering *both* firing paths:

- `INTERVAL` exploits accumulate `delta` and fire while `accumulator >= cooldown`,
  spending budget per fire. The accumulator is **decremented by `cooldown`**, not
  zeroed — banking the remainder. Zeroing quantizes the effective period to
  `ceil(cooldown/dt) * dt`, which makes a cooldown of 0.051 s fire at 0.0667 s,
  a 31% DPS loss, and makes `+cooling` purchases do nothing until they cross a
  16.7 ms boundary. The accumulator is clamped to `4 * cooldown`.
- Event-driven exploits (`ON_KILL`, `ON_HIT`, `ON_DAMAGE_TAKEN`) spend from the
  **same** budget. This is the only throttle they have; they carry no cooldown
  of their own.

A **global per-tick event budget of 4800** bounds the queue. Events past it are
dropped and logged.

Both budgets are load-bearing. `ON_HIT` is the only trigger with unbounded
width — an entity can be hit many times per tick, so an `ON_HIT` + `broadcast`
exploit over N enemies in radius generates N events, then N², then N³. At N=100
that is 10⁶ events by the third cascade pass. A depth cap alone does not bound
it; the fire budget does.

### 2.5 Level-up and auto-slotting

**Starting loadout:** one exploit holding `packet` (VECTOR) + `interval`
(TRIGGER), both rank 1. This is what makes rules 2 and 4 total from the first
pick — with an empty loadout, a first card that is a TRIGGER or PAYLOAD fails
rules 1, 2, and 3, and rule 4 has no module of that slot type to displace.

On level-up the game pauses and offers **three module cards**. Each names its
destination exploit (`→ exploit_01`, 1-based in UI; 0-based internally) and
shows the resulting stat delta. Card draw uses a **run-seeded RNG** so a bug
report reproduces. Multiple level-ups crossed in one tick **queue**; screens
are shown in sequence.

Auto-slot rules, in order:

0. **No legal placement** — if none of rules 1-4 can place the module, the card
   is offered as **salvage only** (50). This is the backstop that makes the set
   total under any starting state or unlock configuration.
1. **Rank-up** — the id is in the loadout and below `max_rank`. Destination is
   the exploit holding it (singular, per §2.2's uniqueness invariant).
2. **Empty slot** — lowest-index exploit with an empty compatible slot.
   Compatibility is `Module.slot` only.
3. **New exploit** — only if the module is a **VECTOR** and fewer than 3
   exploits exist.
4. **Replacement** — displace the lowest-rank module of the same slot type,
   tie-broken by lowest exploit index, then lowest payload slot index. The card
   names the victim. **The displaced module's rank is destroyed**: if it is
   drawn again it re-enters at rank 1. This is stated because it is a real
   penalty and it changes rule-4 card deltas.

**Every card can be declined** for 25 salvage, so the player is never forced to
destroy a module they want.

**Card pool** = unlocked modules below `max_rank`. If fewer than three are
legal, the remainder are salvage cards (50 each); the offer is always three.

**Unlock invariant.** At least **3 VECTOR, 3 TRIGGER, and 6 PAYLOAD** modules
must be unlocked on a fresh save, or a 3-exploit board is not fillable and the
advertised cap is unreachable for a new player. V1 ships 12 modules unlocked
(3/3/6) and 3 behind milestones (1 VECTOR, 1 TRIGGER, 1 PAYLOAD). The
data-driven test asserts the invariant.

### 2.6 Build depth

Interactions come from tag membership and trigger composition:

- `corrupt` + `chain` — infection spreads through packed groups.
- `on_kill` + `fork_bomb` — chain reactions, bounded by the §2.4 fire budget.
- `on_damage_taken` + `broadcast` — a punish build that rewards being swarmed.

**Trigger attribution:** `ON_KILL` and `ON_HIT` fire only for kills and hits
made by **the owning exploit**. Botnet-node kills fire nothing.

A genuinely new *behavior* means a new `VectorKind` or `TriggerKind` value and a
branch in `ExploitRunner`. That is the honest cost, stated rather than hidden
behind a hook table.

---

## 3. The tick

**All combat effects run in one ordered phase.** Nothing resolves inside a
collision or signal callback. Godot locks an `Area2D` while its overlap signals
emit, and space-state queries are only safe in `_physics_process` — but §4
removes physics from every high-count entity anyway, so this ordering exists to
make outcomes deterministic, not to dodge the engine.

Each `_physics_process(delta)`, in this exact order:

1. **Spawn** — `SpawnDirector` and any deferred spawns claim pool slots. New
   entities are therefore in this tick's grid and can be hit on their spawn tick.
   **At the 600-enemy cap the spawn is dropped and a counter incremented**; the
   §9 exact-count test asserts the drop count.
2. **Integrate** — apply velocities, using steering forces computed in step 4 of
   the *previous* tick.
3. **Rebuild grid** — clear and repopulate from live entities (§4.2).
4. **Steer** — grid neighbor queries produce forces for the *next* integrate.
   Steering reads the grid only after it is rebuilt; running it in step 2 would
   read a grid whose indices the previous tick's step 9 swap-removes invalidated,
   producing forces from phantom neighbors on every heavy-death frame.
5. **Fire** — `INTERVAL` exploits spend budget and fire. `BROADCAST` and `BEAM`
   query the grid and append `HitEvent`s directly. `PACKET` and `CHAIN` spawn
   projectiles into the pool; **a projectile spawned here is not in this tick's
   grid and first moves and hits on the next tick.**
6. **Detect** — grid overlap tests append `HitEvent`s. Detection never mutates
   state. Order is canonical: **by source index, then target index**, so
   same-tick outcomes are reproducible rather than dependent on bucket iteration.
7. **Drain** — pop events in queue order. Apply damage, then corruption.
   **A terminal flag (`dead` / `flipped`) suppresses further *damage* only.
   Corruption keeps accumulating for the whole tick.** This is what makes step 8
   meaningful: if the flag suppressed everything, an enemy that took lethal
   damage before a corruption event would never flip, and death-vs-flip would
   silently depend on queue order.
8. **Resolve transitions** — for each entity marked this tick: **flip wins over
   death.** Emit drops, advance milestones, and fire `ON_KILL` / `ON_HIT` /
   `ON_DAMAGE_TAKEN` exploits, which append to the queue. `ON_KILL` fires **iff
   the resolved transition is `dead`** — never for a flipped enemy. Steps 7-8
   repeat up to **8 passes**, subject to both §2.4 budgets. **Residual events at
   the cap are discarded and logged**, never carried across ticks.
9. **Recycle** — free dead slots (swap-remove).

**Generation ids.** Slots are freed at step 9 and claimed at step 1 of the next
tick, and events never survive a tick — so within-tick slot reuse cannot occur
and generations guard nothing inside a tick. They are retained deliberately as
cheap defense-in-depth across the Recycle→Spawn boundary. The §9 test asserts a
stale prior-tick event is rejected. (Revision 2 justified them with a
within-tick scenario its own step order forbids.)

```gdscript
class_name HitEvent extends RefCounted   # scripts/combat/hit_queue.gd
var seq: int                  # canonical ordering
var source_exploit: int       # index into the loadout; anchors botnet damage
var source_index: int
var target_index: int         # tagged; see §4.2
var target_generation: int
var damage: float
var corruption: float
```

---

## 4. Entities

### 4.1 No physics, anywhere

Enemies, projectiles, botnet nodes, and XP shards are **not nodes**. All live in
packed arrays:

```gdscript
var pos: PackedVector2Array
var vel: PackedVector2Array
var integrity: PackedFloat32Array
var corruption: PackedFloat32Array
var type_index: PackedInt32Array   # into the enemy stats table
var radius: PackedFloat32Array
var generation: PackedInt32Array
var state: PackedByteArray         # ALIVE | DEAD | FLIPPED
```

`state` is one field, not an `alive` byte plus separate `dead`/`flipped` flags.

They render through one `MultiMeshInstance2D` **per population**, with
`use_custom_data` carrying a per-instance UV offset so a single mesh can draw
different glyphs from the startup-generated atlas. The packed position IS the
transform — the MultiMesh write is the only transform write in the system.

**There is no `Area2D` in the game.** Revision 2 kept one for the player and
pickups; an `Area2D` cannot overlap a packed array, so a player wired that way
would never be hit and `on_damage_taken` would never fire. **Player contact
damage and pickup collection are both grid queries in step 6.** Shards moved
into the packed path for the same reason plus arithmetic: §7's XP curve needs
3212-4420 shards per run, and at partial collection ~1300 uncollected shards
would be live at the boss — more than twice the entire enemy budget, in nodes,
in the system that deleted nodes for performance.

**Caps** (pools and MultiMesh buffers pre-sized, never resized at runtime):
600 enemies, 400 projectiles, 8+ botnet nodes, 1500 shards.

### 4.2 The grid

One uniform grid, rebuilt each tick, serving proximity, hit detection, and
separation steering. It holds **all four populations**; a returned index carries
a **2-bit population tag in its high bits**, so a caller can resolve type
without a second lookup.

```gdscript
func query_radius(point: Vector2, r: float) -> PackedInt32Array
func query_radius_into(point: Vector2, r: float, buf: PackedInt32Array) -> int
```

The `_into` form fills a caller-owned buffer and returns a count. Steering and
detection **must** use it: the allocating form called once per enemy per tick is
36,000 `PackedInt32Array` allocations per second at 600 enemies and 60 Hz,
plausibly the dominant cost of the whole simulation.

`query_radius` **never truncates**. (The old physics-backed design was a trap
partly because `intersect_shape` truncates silently at `max_results`, so a
`broadcast` aura over a packed group would have quietly capped its damage.)

**Uniform hit radii.** All enemies use `ENEMY_RADIUS = 12.0` and all projectiles
`PROJECTILE_RADIUS = 4.0`; the ICE boss is 48.0, which only makes it easier to
hit. Cell size is **32.0 px**. The data-driven test asserts the invariant.

This is what makes discrete per-tick overlap correct. The condition is
`displacement <= r_projectile + r_target` for the **smallest** pair — not
`displacement <= cell size`. With a 32 px cell and a 4+12=16 px minimum combined
radius, revision 2's "one cell per tick" rule permitted a 1920 px/s projectile
to pass clean through a small enemy, silently. Hence
`MAX_PROJECTILE_SPEED = 60 * (4 + 12) = 960.0` px/s, clamped in `Compiler`
(§2.3). Enemy speeds are authored well under the same bound.

### 4.3 Corruption and the botnet

Enemy types define integrity, speed, `corruption_threshold`, `contact_damage`,
and `shard_value` in `data/enemies/`. **The ICE boss is corruption-immune** —
otherwise flipping it would bypass the kill-to-win condition.

Corruption is added only by payloads carrying the `corruption` tag; `Compiler`
asserts that a module contributing the `corruption` stat also carries the tag,
so the two cannot drift.

An enemy reaching its threshold **flips**. Excess corruption is discarded. Flip
beats death (§3 step 8).

**Node damage** = `flipping_exploit.botnet_damage_ratio * flipping_exploit.corruption`
per second, for `flipping_exploit.botnet_lifetime` seconds. Defaults 0.6 and
12.0. "The exploit that flipped it" means **the last one to land corruption that
tick** — so in a mixed build a weak payload landing the final increment creates a
weak node even if a strong exploit supplied most of the corruption. Stated
because it is not quite what "invest in corruption → stronger nodes" implies.

Nodes deal damage via a fixed-radius grid proximity aura, emitting ordinary
`HitEvent`s in step 6 like everything else. They cannot be damaged; they only
expire.

**Cap** = `8 + sum(botnet_cap)` across all three exploits. Eviction is by
monotonic sequence number. If the cap **drops** below the live count (a cap
module displaced by rule 4), no nodes are killed — new flips are blocked until
decay brings the count under.

**Known shape, on record.** Flip rate scales with `corruption` and node damage
scales with `corruption`, so below the cap botnet DPS is **quadratic** in
corruption; above `8/12 = 0.667` flips/sec it goes linear at
`8 * 0.6 * C = 4.8C`. A quadratic ramp into a hard ceiling is the sharpest shape
to balance, and the transition moves whenever a cap module is picked up. §9
asserts a DPS bound.

---

## 5. Run structure

A **subnet** is five minutes in one arena. `SpawnDirector` reads a wave table
(`data/waves/*.tres`, typed `Resource` rows — not CSV):

```
time_start: float, time_end: float, enemy_type: StringName,
spawn_rate: float, formation: Formation   # enum
```

- Intervals are **half-open**: `[time_start, time_end)`.
- `spawn_rate` is **spawns per second**, accumulated as **integer
  milli-spawns** so a five-minute run cannot drift.
- Formations draw from a **run-seeded** RNG. An unknown formation is impossible
  (enum).
- The clock is **injected**, so a headless test simulates five minutes in
  milliseconds and asserts exact counts.

At 5:00 spawning stops and the **ICE boss** spawns. **In V1 this boss is the
core: killing it wins the run.** The branching node map is scaffolded but
unreachable until subnet 2 exists — V1 has no dead end.

---

## 6. Economy and meta

- Enemies drop **data shards** worth `shard_value` (base 1). **A flipped enemy
  drops the same shards a killed one does**, so a corruption build does not
  starve its own level-ups.
- XP for level `n` is `20 + 12(n-1)`; cumulative for N levels is `6N² + 14N`.
  22-26 levels per subnet needs 3212-4420 shards over 300 s, i.e. **10.7-14.7
  kills/sec** sustained. At ~12 kills/s the curve yields N = 23.4, inside the
  band — the curve is coherent.
- Salvage: 500 from the boss, 25 per declined card, 50 per salvage card.
- **Salvage banks on subnet clear — which in V1 is the boss kill.** Unbanked
  salvage is lost on any death, including a death during the boss fight.

**Buffs.** `+CPU cycles` (damage), `+cooling` (cooldown), `+bandwidth` (pickup
radius). Each capped at 10 purchases. The **n-th purchase of a buff costs
`60 + 30(n-1)`** — 1950 to max one line, 5850 for all thirty. At ~600 salvage
per won run that is ~10 wins to max everything, which is the retention math of
V1 and is stated so it can be tuned rather than discovered.

**Meta buffs fold in `Compiler.build`, after module stats and before the
clamps.** Additive, like everything else. Because compilation happens on pick,
buffs are constant for a run: **there is no seam for an in-run stat change**.
Accepted for V1.

Unlocks come from milestones ("flip 50 enemies" → `worm`), subject to §2.5's
unlock invariant.

### Save

`user://save.json`, with a `version: int` field.

- **Write order:** `save.json` → `save.json.bak` (rename), then
  `save.json.tmp` → `save.json` (rename). Renaming `.tmp` over the live file
  without rotating first does not produce a backup.
- **Unreadable:** fall back to `.bak`. Only if both fail is a fresh save made,
  and the player is told.
- **Newer version** (`save.version > LOADER_VERSION`): renamed to
  `save.json.v<N>` — *not* `.bak`, which would clobber the fallback — and a
  fresh save is started.
- **Types:** Godot's JSON returns every number as float. Salvage, milestone
  counters, **and purchased-buff counts** are coerced with `int()`.
- **Ranges:** salvage clamped to `[0, 10^9]`; each buff count clamped to
  `[0, 10]`; milestone counters clamped non-negative. `user://save.json` is
  plaintext and trivially edited, and it is the only user-controlled input in
  the game. (Security sweep: no shell strings, no SQL, no templates, no
  `eval`/`Expression`/`str_to_var`, and no `load()` of a save-derived path.)
- **Unlocked ids** resolve against the module registry. A save string never
  reaches a load path; unknown ids are dropped with a warning.

**Registry.** Built from `data/module_manifest.tres`, a manifest generated at
build time by `tools/build_manifest.gd` and committed. It is **not** a
`DirAccess` scan of `data/modules/`: Godot's "convert text resources to binary"
export setting is on by default, so a scan returns the expected `.tres` names in
the editor and in CI but not in an exported build — which would ship an empty
registry, drop every unlocked id "with a warning", and leave every player with
an empty card pool. Startup asserts the registry is non-empty.

---

## 7. Presentation

Drawn in code on black.

- Player, boss, pickups: glowing wireframe polygons.
- Enemies, projectiles, shards: monospace glyph quads via MultiMesh with
  `use_custom_data` selecting the glyph from an atlas generated at startup from
  a bundled monospace `.ttf` (the one binary asset; license in `data/fonts/`).
- Glow: `WorldEnvironment` glow with `Viewport.use_hdr_2d`. Scanlines are a
  separate full-screen `CanvasLayer` shader. (One CanvasLayer pass cannot do a
  separable blur without a `BackBufferCopy`.)
- HUD: a fake terminal readout.

**Player stats:** health 100, move speed 220 px/s, pickup radius 48 px,
i-frames 0.5 s. Lifesteal is clamped at max health.

---

## 8. Architecture

```
project.godot
scenes/   main.tscn  run.tscn  hud.tscn  level_up.tscn
          meta.tscn  victory.tscn  game_over.tscn
scripts/
  core/     grid.gd  object_pool.gd  event_bus.gd
  build/    module.gd  exploit.gd  compiler.gd  loadout.gd
  combat/   swarm.gd  projectiles.gd  shards.gd  hit_queue.gd  exploit_runner.gd
  actors/   player.gd  botnet.gd  boss.gd
  run/      spawn_director.gd  subnet.gd  economy.gd
  meta/     save.gd  unlocks.gd  registry.gd
tools/    build_manifest.gd
data/     modules/*.tres  module_manifest.tres  enemies/*.tres
          waves/*.tres  fonts/
tests/
```

`exploit.gd` hosts `Exploit`, `EquippedModule`, and `ResolvedExploit`;
`hit_queue.gd` hosts `HitEvent` and `HitQueue`.

### Unit boundaries

- `Compiler` — pure. Modules + meta buffs in, `ResolvedExploit` out.
- `Loadout` — owns exploits and the §2.5 rules. Pure. Asserts id uniqueness.
- `Grid` — a plain data structure. Rebuilt per tick, queried by everything.
- `Swarm` / `Projectiles` / `Shards` — packed-array simulation.
- `HitQueue` — the §3 event queue and drain order. Pure given a grid.
- `ExploitRunner` — the one stateful bridge: reads `ResolvedExploit`, switches
  on `vector_kind` / `trigger_kind`, spends fire budget, spawns into pools.
- `EventBus` — autoload for **non-combat** signals (`level_up`,
  `subnet_cleared`, `milestone_reached`). Combat never uses signals; it uses the
  queue, so ordering is explicit and re-entrancy is impossible.

---

## 9. Testing

GUT, vendored under `addons/gut/` at a pinned commit recorded in
`docs/tooling.md`. Run:

```
godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```

`-gexit` is required or CI hangs instead of reporting.

**Milestone 0 — the perf gate, before any dependent system is built.** A
headless spike: 600 enemies + 400 projectiles + 1500 shards, scripted worst
case, asserting **tick time under 8 ms**. This is the one bet the architecture
rests on and nothing else tests it — the design replaced C++ broadphase in the
physics server with hand-rolled broadphase in interpreted GDScript, and
~10⁴-10⁵ vector ops per tick in an interpreted language can be slower than the
server it replaced. **Escape hatch if it fails: port `grid.gd` and `swarm.gd` to
C#.** The architecture ports cleanly, being node-free.

Covered:

- **Compiler** — additive folding; rank scaling at 1 and `max_rank`; meta-buff
  folding; `MIN_COOLDOWN` holding with every cooldown contributor stacked at max
  rank; `MAX_PROJECTILE_SPEED` likewise; `floori` on int fields in **both** fold
  orders; rejection of non-numeric and unknown stat keys; the corruption
  stat/tag assertion; kind-fold reading vector/trigger from the right module.
- **Permutation determinism** — the same multiset in different fold orders
  resolves identically, **using values chosen to expose float non-associativity**
  (e.g. `1e16, 1.0, -1e16`, where fold order changes the result by 1.0, not by an
  ULP). Under pure addition, commutativity makes an ordinary-valued permutation
  test pass even if the sort is missing entirely.
- **Data sweep** — every `.tres` resolves cleanly; the uniform-radius invariant;
  the 3/3/6 unlock invariant; the registry is non-empty.
- **Loadout** — rules 0-4; the decline path; rule 3 founding only from VECTOR;
  rule 4 victim selection, tie-breaks, and **rank destruction**; id uniqueness;
  the empty-loadout / all-payload-offer case; card-pool starvation.
- **Grid** — cell-boundary correctness; an entity exactly on an edge; `r = 0`;
  `r` spanning the arena; empty grid; the non-truncation promise; the `_into`
  form's count and buffer reuse; population-tag round-trip.
- **HitQueue drain** — damage suppressed but **corruption still accumulating**
  after a terminal flag, constructed as the two-event case (lethal damage then
  threshold-crossing corruption) **in both queue orders**; flip-beats-death;
  `ON_KILL` not firing for a flipped enemy; canonical detect ordering; cascade
  depth cap with residual discard; **cascade width** — a self-feeding
  `on_hit` + `broadcast` exploit with 300 enemies in radius stays inside both
  budgets; stale prior-tick event rejected by generation.
- **Fire budget** — accumulator banks the remainder rather than zeroing (assert
  no DPS cliff across a 16.7 ms boundary); budget shared between interval and
  trigger paths; clamp at `4 * cooldown`.
- **Swap-remove** — dense prefix maintained when despawning the last live index,
  index 0, and the only live entity.
- **Pool exhaustion** — the 601st enemy spawn is dropped and counted.
- **ExploitRunner** — each `VectorKind` × `TriggerKind` pair produces the
  expected events; projectiles spawned in step 5 first hit on the next tick.
- **Botnet** — flip threshold; damage from the flipping exploit; last-lander
  attribution; cap aggregation across exploits; sequence eviction; the over-cap
  path; a DPS bound; boss corruption immunity.
- **SpawnDirector** — exact counts over a simulated five minutes with an
  injected clock and the drop count asserted; half-open boundary at a wave seam;
  no accumulator drift.
- **Economy** — flips and kills drop equal shards; banking on boss kill; loss on
  death during the boss fight.
- **Save** — round-trip including types; truncated file recovers from `.bak`;
  newer-version file preserved to `.v<N>` without clobbering `.bak`; rotation
  order; range clamping per field; unknown module id dropped with the rest
  intact.

Not covered by tests: rendering, shaders, and game feel. Playtested.

---

## 10. V1 scope

**In:** subnet 1 and its ICE boss (V1's core and win condition); **15 modules
split 4 VECTOR / 4 TRIGGER / 7 PAYLOAD**, 12 unlocked at start; the compile and
level-up loop; the botnet branch; meta save, buffs, and unlocks; the perf gate.

**Why 3 exploits.** Three exploits need 3 distinct VECTORs and 3 distinct
TRIGGERs, leaving 6 of 7 payloads for 6 payload slots — the board is fillable
from the pool. With only **4 VECTOR modules** and globally-unique ids, the hard
ceiling is 4 exploits (8 payload slots, 7 payloads, 1 unreachable = 12.5%); a
5-exploit board is not merely wasteful, it is **unfoundable**. Three leaves
headroom and keeps every slot reachable. (Revision 2 justified this with "a
5-exploit board leaves half the payload capacity unreachable" — that was 30%
under the reading it intended, and unreachable-in-principle under the correct
one.)

**When rule 4 goes live.** Not at the 60-placement rank saturation figure —
that is unreachable, since a run yields ~22-26 picks against 12 slots × 5 ranks.
Rule 4 fires on **slot occupancy**: 12 distinct placements, roughly the **55%
mark** of a run. After that ~20% of drawn cards are rule-4 cards, about 6
expected replacement offers over the back half. Still not the default, but the
justification matters because balance will be tuned against it.

**Out of v1:** additional subnets and the reachable node map, multiple playable
processes, audio, controller support, in-run stat changes.

---

## 11. Decisions on record

| Decision | Choice | Why |
|---|---|---|
| Spine | Compiling; botnet is one branch | Two progression systems would fight for balance space |
| Entity model | Packed arrays + one uniform grid; no `Area2D` anywhere | Area2D + MultiMesh paid for both architectures, and hit detection coupled to `area_entered` cannot be abstracted behind a query interface |
| Execution | One ordered 9-step tick | Makes death-vs-flip and cascades deterministic instead of iteration-order-dependent |
| Throttling | Per-exploit fire budget covering both firing paths | A depth-only cascade cap does not bound `ON_HIT` width |
| Stat model | Additive only, no `mul_`, no hooks | No V1 module needed either; both carried ambiguity |
| Level-up UX | Three cards, auto-slotted, declinable, rule 0 backstop | Keeps pace; the rules must be total from the first pick |
| Run shape | 5-minute subnet, boss is V1's core | V1 must have a win state, not a dead-end map |
| Meta | Buffs + unlocks; banks on subnet clear; priced | An economy with unstated prices cannot be balanced or tested |
| Botnet anchor | The flipping exploit's `corruption` | Anchoring on `damage` made the branch scale inversely with its own investment |
| Art | Vector and glyph neon, drawn in code | No art pipeline; one bundled font is the sole binary asset |
| Controls | WASD only, all auto-fire | Keeps the build as the sole decision layer |
| Language | GDScript, gated by milestone 0 | Hand-rolled broadphase in an interpreted language is an unproven bet; C# for `grid.gd`/`swarm.gd` is the named escape hatch |
| Flat `ResolvedExploit` | Kept, limit documented | Cannot express intra-exploit sequencing; no V1 module needs it |

---

## 12. Review history

Six reviewers (GPT-5.6 Luna, GPT-5.6 Terra, GLM-5.2, Gemini 3.1 Pro, and two
Claude skeptics) over two rounds. Both rounds: unanimous REVISE.

**Round 1 → revision 2.** The entity architecture was pooled `Area2D` enemies
mirrored into a MultiMesh, with a `SpatialIndex` interface claimed to make a
later grid swap free. A skeptic showed the claim was false — `SpatialIndex`
abstracts point queries, but hit detection would be written against
`area_entered`, outside that interface. A debate round put this to the two
reviewers who had defended the seam and **both conceded**. The Architect: *"the
Area2D architecture is an existential threat to structural integrity if the team
plans to swap it later."* The Simplifier: *"a seam that hedges the cheap part
while leaving the expensive part un-hedged is worse than no seam."* Also fixed:
unbounded cooldown reduction (−1.70 s at max rank, hanging a
`while accumulator >= cooldown` loop), a meta economy with zero income in V1,
non-atomic saves wiping all progression, rank with no storage, `mul_` and hooks
as machinery no module exercised, and three non-total auto-slot branches.

**Round 2 → revision 3.** The rewrite moved failure modes rather than removing
them, and reviewers converged on five:

- **§3 contradicted itself.** The kill-once flag discarded corruption arriving
  after lethal damage, so "flip beats death" held only when corruption happened
  to drain first — and the test for it would pass or fail on the test author's
  choice of ordering.
- **The cascade cap bounded depth, not width.** `ON_HIT` + `broadcast` over N
  enemies generates N, N², N³ events; at N=100 that is 10⁶ by pass three.
- **Removing physics removed the player's collision channel.** An `Area2D`
  cannot overlap a packed array, so the spec as written described a player who
  could never be hit.
- **Botnet-branch stats had nowhere to live** — no `botnet_cap` field, so such a
  module failed the §2.1 assertion at load and broke CI.
- **The auto-slot rules reopened at the start state**, which no revision had ever
  specified.

Plus corrections to my own arithmetic: the projectile speed bound was the wrong
inequality (cell size, not minimum combined radius), the 4-fire cap was
unreachable at a fixed 60 Hz tick, the 60-placement saturation figure was
irrelevant to when rule 4 actually fires, and the 5-exploit comparison was wrong
under every reading. The XP curve was the one new number that checked out.
