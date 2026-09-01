# Fusion, recipes and blocks

Three slots that match a recipe become one much stronger module. Modules go back
to being one-per-loadout, and fusion is how you get one back.

Depends on modules
([2026-08-31-modules-design.md](2026-08-31-modules-design.md)) for the 35-module
table these recipes are drawn from, and on terrain
([2026-08-31-terrain-design.md](2026-08-31-terrain-design.md)) for the walkable
ground a block has to stand on.

## Decisions

| Question | Answer |
|---|---|
| What fusion consumes | All three modules; their ids are freed |
| What the fused row holds | The fused module plus one open PAYLOAD slot |
| How recipes match | Exact module ids, three of them |
| How fusion is triggered | Holding a block in the arena, under fire |
| Uniqueness | Full — one id anywhere in the loadout |
| Fused module ranks | 1–5 through the ordinary card pool |
| New runtime mechanics | Five |

## The loop

A row of three specific modules is a **recipe**. Recipes do not fire on their
own — a **block** spawns in the arena on a cadence, and holding ground inside it
for eight seconds pays out. If a row matches a recipe, the payout is the
**fusion**: the three modules are consumed, the row becomes one fused module
with a much stronger base, and the three ids go back in the pool for another
row to use. If no row matches, the block pays something else.

That is the whole shape, and each half needs the other. Uniqueness without
fusion is the failure `loadout.gd` already records — rows starved of modules
they cannot have twice. Fusion without uniqueness is a stat upgrade with no
cost, because nothing was scarce to begin with.

## Uniqueness returns

`Loadout.legal_targets` skips any slot whose module id is held anywhere else in
the loadout. The slot that already holds it still offers RANK_UP. A card with
zero legal targets falls through to the salvage path that already exists for
rule 0, so the rule set stays total.

The comment at `loadout.gd:52-63` argues **for** non-uniqueness and has to be
rewritten rather than deleted, because the failure it records is real and the
reasons it no longer bites are specific:

- **Placement is the player's decision now.** The observed failure was the
  auto-slotter: it could not place a trigger that was already held, so rows two
  and three got none and sat inert. `legal_targets` offers what is legal and the
  player chooses; a trigger it cannot offer is a card declined for salvage, not
  a row silently left broken.
- **`_is_last_interval` still stands.** Row one keeps an unconditional trigger,
  so `on_kill` and `on_hit` in rows two and three have something to bootstrap
  off.
- **Fusion frees ids.** The escape hatch the old design did not have.

### Fusion may not orphan the loadout

Fusing the row that holds your last `interval` frees `interval` but leaves
nothing firing unconditionally until you re-place it — the same deadlock
`_is_last_interval` was written for, arriving by a different door. So fusion is
**refused** when it would leave no INTERVAL trigger anywhere, unless the fused
module is itself INTERVAL-triggered.

`_is_last_interval` extends to count a fused module whose `trigger_kind` is
INTERVAL as an interval trigger, because it is one.

## The fused row

A fused module **is** a VECTOR — `slot == Module.Slot.VECTOR`, which is what buys
it the right rank scaling — so it occupies `Exploit.vector`, marked by
`is_fused`, and the TRIGGER column is simply left empty.

- `at(0)`, `at(1)`, `at(2)` are unchanged. A row is still three slots, which is
  the invariant the loadout rules and the whole level-up screen are built on.
- `is_inert()` is false: a fused module carries its own `vector_kind` **and**
  `trigger_kind` — both fields `Module` already has — so the row fires with no
  trigger module in it.
- `Exploit.head_is_fused()` is the one new predicate, and `legal_targets` reads
  it twice: never offer the absorbed TRIGGER column, never let the head be
  replaced.

A fused row therefore offers exactly two placements: ranking the fused module,
and filling or replacing its payload.

**A parallel `Exploit.fused` field was the first design, and review rejected it**
— independently, from the structural lane and the complexity lane. It forced an
`if fused != null` branch into `at`, `equipped`, `has_free_slot_for`,
`is_inert`, `legal_targets`, `_interval_count`, `Compiler.build` and the UI, and
it broke the three-slot uniformity everything else assumes, for a distinction
(`absorbed` is not `empty`) that two boolean reads express just as well.

There is no un-fusing. A fused row is a decision for the rest of the run.

## Two new Module fields

| Field | For |
|---|---|
| `is_fused: bool` | Excludes the module from ordinary card draws |
| `targeting: Targeting` | NEAREST (default) / STRONGEST / FARTHEST |

`targeting` is read **only** from the VECTOR-or-fused slot, exactly as
`vector_kind` and `trigger_kind` already are. Folding it from every module in
turn would let a payload's default enum value clobber the vector's choice —
the bug the kind fields already carry a comment about.

Fused modules are `Module` resources in a new `data/recipe_table.gd`, not a new
type. They have `slot == VECTOR`, which buys the right rank scaling for free:
`Compiler._fold` already freezes a vector's `cooldown` and `travel` against rank
and grows its `radius` at a quarter rate, and a fused module wants all three.

Fused modules join the card pool as rank-up-only cards once you hold one. They
are unique like anything else.

## Five new mechanics

Twenty bespoke behaviours would be unshippable. Twenty recipes run on four new
stat keys plus `targeting`; everything else is stat profiles and combinations of
kinds that already exist.

**`targeting`** — swaps the comparator in `_nearest_enemy` (`run.gd:1032`).
BEAM, CONE, CHAIN and PACKET all already call it, so all four inherit it at
once. BROADCAST, PULSE, MINE and ORBIT resolve from the player's position and
ignore it; no recipe on those kinds sets it.

STRONGEST reads `enemies.integrity[i]`, which the scan already has in hand. The
scan stays one linear pass, so the perf gate is unaffected. Three modes, not
four: a fourth (`LOWEST_HP`) that no recipe sets is a branch bought for nothing,
and the enum is append-safe if one ever wants it.

**`split_count`** — a vector emits N of its projectile fanned across a fixed
spread rather than one. Six lines in the `_:` branch of `_emit_vector` for
PACKET and one more in the MINE branch, which spawns the same pooled projectile
with no velocity — that is what lets `minefield()` lay three charges per kill
without a second implementation. Zero means one, following `burst`, so nothing
has to special-case a default.

**`blast_radius`** — a projectile detonates where it lands, damaging in a radius.
`_detonate_mine` (`run.gd:1000`) already is this function; it is generalised to
`_detonate(i)` and called from the projectile-expiry and projectile-hit paths as
well as the mine fuse. No new hit path, which is the same argument MINE was
built on.

**`execute_below`** — an enemy left under this fraction of its integrity dies.
It resolves inside the drain's single adjudication, not as a second pass over
the survivors: while `_steps78_drain` sums a target's damage for the tick it
also takes the MAX `execute_below` over the exploits that contributed, and a
target whose post-damage fraction falls below it is marked dead in the same
adjudication that would have marked it alive. Anything else breaks the "each
entity adjudicated exactly once per tick" invariant.

**Minibosses are exempt.** A threshold that deletes `fork_bomb`,
`packet_filter`, `null_ptr` and `kernel_panic` off the bottom of their health
bars removes the four fights the run is built around.

**`homing`** — a projectile steers toward a target instead of flying straight.
The only one of the five that is new movement code, and the only one with a perf
question, so it is built to answer it: a homing projectile **binds its target
once, at spawn**, into a `_proj_target` array beside `_proj_owner` and
`_proj_pierce`, and re-acquires only when that target dies or leaves range. The
naive version — query the grid per projectile per tick — is a second broadcast
query per shot per frame and would show up in the gate immediately.

Steering is a turn-rate cap in the integrate step, not instant tracking. A
projectile that snaps to its target is a hitscan with extra steps; one that
turns at a bounded rate can be outrun by a `tracer` and wasted on a `rootkit`
that submerges, which is what makes it a property rather than a guarantee.

### Fold rules

The three that are stat keys join `Module.STAT_KEYS` and become fields on
`ResolvedExploit`:

| Key | Fold | Why |
|---|---|---|
| `split_count` | sum, floored once at the end | Like `pierce`: two halves must make one, not zero |
| `blast_radius` | sum, quarter-rate on rank | Shares `radius`'s carve-out for the same reason — a rank-5 blast that covers the screen is a module whose whole cost was showing up five times |
| `execute_below` | **max**, clamped to 0.5 | A fraction. Two sources summing to 0.5 is not "a bit more execute", it is a different game |
| `homing` | sum, clamped to a max turn rate | Radians per second. Unclamped it converges on instant tracking, which is the thing the turn rate exists to prevent |

`validate()` gains two rules, both on the argument that keeps `cooldown` off
payloads. Only a VECTOR may carry `execute_below`: a payload granting an execute
threshold to every vector it is slotted into is a balance surface nothing else
in the table has. Only a VECTOR may carry `homing`, and only a PACKET-kind one
means anything by it — a payload contributing `homing` to a BROADCAST exploit is
a stat that silently does nothing, the failure mode the corruption-tag and
slow-tag rules already exist to catch.

## The recipes

Twenty. Every vector, every trigger and every payload has at least one fusion
path, so no card is ever a dead end for a player hunting recipes.

| # | Vector | Trigger | Payload | Fused | What it becomes |
|---|---|---|---|---|---|
| 1 | packet | on_kill | race_condition | `hollow_point()` | Early sniper. STRONGEST, damage climbs per kill |
| 2 | broadcast | interval | overclock | `pulse_train()` | Relentless metronome nova at the cadence floor |
| 3 | chain | on_hit | heap_spray | `arp_storm()` | Chains 8 deep, FARTHEST, so the arc walks back to you |
| 4 | beam | interval | buffer_overflow | `railgun()` | Full-screen piercing line, STRONGEST |
| 5 | spike | on_kill | fork_bomb | `stack_smash()` | Huge cone, `execute_below` 0.18 |
| 6 | flood | interval | tarpit | `dragnet()` | Screen-wide slow field with real damage |
| 7 | snipe | on_kill | bitmask | `zero_day()` | STRONGEST, homing, pierce 6, massive single hits |
| 8 | landmine | interval | corrupt | `logic_bomb()` | Mines that detonate as corruption, flipping packs |
| 9 | cascade | on_flip | worm | `botnet_cascade()` | Every flip fires a 10-deep corrupting chain |
| 10 | bounce | on_hit | harden | `bulkhead()` | Knockback pulse that wards armor on every hit |
| 11 | mirror | interval | nice | `aegis()` | Eight orbiting piercing blades + movement ward |
| 12 | throttle | interval | keylog | `tar_siphon()` | Slow field that heals off everything caught in it |
| 13 | airgap | on_damage_taken | sandbox | `panic_room()` | Retaliation nova, burst 4, heavy defense ward |
| 14 | checksum | on_kill | botnet_expand | `redundancy()` | Shield per kill, big botnet cap. Pure attrition |
| 15 | packet | on_hit | overclock | `syn_flood()` | Machine gun: `split_count` 3, tiny cooldown |
| 16 | packet | interval | fork_bomb | `frag_packet()` | Projectiles that detonate on impact |
| 17 | chain | interval | botnet_expand | `hivemind()` | Chains that build the botnet; nodes chain too |
| 18 | flood | on_low_integrity | sandbox | `last_resort()` | Burst 6 screen-clear when you are nearly dead |
| 19 | beam | on_level_up | buffer_overflow | `core_dump()` | Burst 12 detonation on every level |
| 20 | landmine | on_kill | bitmask | `minefield()` | Each kill lays three penetrating charges |

Trigger spread is `interval` 8, `on_kill` 5, `on_hit` 3, and one each for the
four rare triggers. The weighting is deliberate: the three unlocked triggers
carry the recipes a player can reach before unlocks land.

Twelve of the twenty — 2, 6, 8, 9, 10, 11, 12, 13, 14, 17, 18, 19 — need no new
code at all. They are stat profiles over kinds that already exist, which is the
point of keeping the mechanics list at five: `logic_bomb()` is a MINE carrying
`corruption`, and `redundancy()` is `shield` and `botnet_cap` on a vector that
already fires on kills.

The other eight each draw on one or two of the five: `targeting` for 1, 3, 4 and
7, `execute_below` for 5, `homing` for 7, `split_count` for 15 and 20, and
`blast_radius` for 16.

**Twelve of the twenty are gated behind unlocks**, because `beam`, `snipe`,
`landmine`, `cascade`, `mirror`, `airgap`, `checksum`, `worm`, `heap_spray`,
`tarpit` and the four rare triggers all ship locked. Eight are live in an early
run. That is the intended shape — fusion is a mid-run payoff, not an opening
move — but it means the early recipe set is small enough that a player can
learn it.

## The block

New `scripts/run/blocks.gd`, holding the state and the rules; `props.gd` draws
it. It is an extruded box standing on the floor, which is exactly what
`props.draw_box` exists for.

- **Spawn.** First at 40 s, then every 45 s, one live at a time. Never once the
  collapse has begun and never in the corridor: the walk to the gate is already
  the thing you are doing, and a second objective competing with it makes both
  worse.
- **Placement.** A point sampled 400–700 px from the player inside the current
  arena, resolved through `terrain.nearest_open()`, so it never lands in a wall
  or outside the connected region.
- **Hold.** Radius 70. Progress accrues while you stand inside and **drains at
  twice the rate while you are outside**, clamped to [0, 8 s]. Spawns keep
  coming and `probe` keeps shooting, so holding ground is a fight rather than a
  wait. This is the only part of the block that is a feel decision rather than a
  derived one; if it plays as punishing, banking progress instead is a
  one-constant change.
- **Payout, then despawn**, and the next spawn is scheduled from that moment.

### What a block pays

1. **A row matches a recipe** — the fusion offer. If several rows match, the
   player picks which. Declining costs nothing and the recipe stays matched, so
   the next block offers it again.
2. **Otherwise, a targeted card, 70% of the time**, when one exists: a card
   screen whose first card is a module that either completes a recipe a row is
   one module short of, or fills a slot keeping a row inert. With twenty exact
   triples over a 35-module table, nothing else makes recipes reachable — the
   targeted card is not a bonus, it is the delivery mechanism.
3. **Otherwise a roll** — salvage scaled by subnet, integrity restored, or a
   guaranteed rank-up on a module the player chooses.

The card screens reuse the level-up path (`run.gd:1717`, `ui._show_cards`), so
they inherit its pause behaviour, its keyboard navigation and its
decline-for-salvage. The fusion offer is a new screen; it is the only new one.

## Discoverability

Exact triples over 35 modules are not discoverable by play. A recipe panel
toggles over the level-up screen, listing each recipe with its three slots
marked lit or unlit against what the loadout currently holds.

**It lists only recipes whose three modules are all unlocked.** Twenty rows of
mostly-unreachable combinations early in a run is a wall, not information.

## Compiler

`build()` reads `vector_kind` and `targeting` from the VECTOR slot as it always
has, and takes `trigger_kind` from that same module when it is fused. Everything
downstream — the vector fold, `vector_base`, the multiplier layer, both cooldown
floors, the clamps — is unchanged, because a fused module is a VECTOR carrying
`cooldown` and the floors read exactly what they always read.

One consequence worth stating: a fused module may not carry `cadence_mult`
(`validate` forbids it on any VECTOR, and the proportional floor is why), so each
one bakes its trigger's cadence into its own `cooldown`. It **may** carry
`burst`, which `validate` otherwise allows only on a TRIGGER — a fused module is
its own trigger, and `panic_room()`, `last_resort()` and `core_dump()` all need
it.

## Tests

**`tests/test_fusion.gd`**

- An exact triple matches; the same three modules in a different row match too.
- One module off matches nothing.
- Fusing frees all three ids: a card for each is placeable again afterwards.
- A fused row compiles non-inert with no trigger module in it, and fires.
- The absorbed trigger slot is never offered by `legal_targets`; the payload
  slot is.
- A fused module ranks 1→5 and its `cooldown`, `travel` and `radius` scale by
  the VECTOR rules.
- Fusing the last interval row is refused unless the fused module is INTERVAL.
- The five mechanics: STRONGEST picks the highest-hp enemy in range, not the
  nearest; `split_count` emits N; `blast_radius` damages at the impact point;
  `execute_below` kills a low enemy and does **not** kill a miniboss; a `homing`
  projectile binds one target at spawn, turns at a bounded rate rather than
  snapping, and re-acquires when that target dies.

**`tests/test_blocks.gd`**

- Schedule: first spawn at 40 s, one live at a time, none during collapse or in
  the corridor.
- Placement is always on open connected ground.
- Progress fills inside, drains at 2× outside, clamps at both ends.
- Payout selection: fusion when matched, targeted card when a row is one short,
  the roll otherwise.

**`tests/test_build.gd`** gains the uniqueness cases: an id held anywhere yields
no legal target elsewhere, the holding slot still offers RANK_UP, and a card
with no target reaches the salvage path.

`test_run.gd` and `test_campaign.gd` autopilot full runs and will catch a
loadout starved by uniqueness.

**The perf gate is the acceptance criterion for `homing`.** Four of the five
mechanics add no per-tick work — one branch in the target comparator, a few
lines in an emit branch, a reused detonation, one comparison in the drain.
Homing adds a steering term per live homing projectile per tick, which is
bounded by the projectile cap and by target binding at spawn. If it moves the
gate, the binding is wrong, not the budget.

## Staging

One precondition comes first. `_step5_fire` opens with `queue.begin_tick()`,
which discards every event appended earlier in the tick — including the mine
fuse in `_step2_integrate` and the hazard and corruption zones in
`_step2b_zones`. Mine blast damage and zone damage to enemies are dead code
today, unnoticed because `landmine` ships LOCKED and no suite asserts either
reduces integrity. `blast_radius` and `split_count` both land in that same
window, so `frag_packet()`, `logic_bomb()` and `minefield()` would ship as
visible explosions dealing nothing, with every test green.

After that the build layer stands alone and is testable headless.

0. `begin_tick` at the top of the tick, so step-2 damage reaches the drain.
1. Uniqueness in `legal_targets`, the rewritten comment, and `test_slots.gd`.
2. `Exploit.fused`, the absorbed slot, `Compiler` reading through it.
3. The five mechanics and their fold rules. `homing` last of the five, because
   it is the one that has to be measured against the gate.
4. `data/recipe_table.gd` and the twenty.
5. `scripts/run/blocks.gd` and the props drawing.
6. The payout paths and the fusion screen.
7. The recipe panel.

## Accepted costs

- **A fusion is permanent for the run.** No un-fusing, and a fused row cannot be
  re-fused into anything else.
- **Uniqueness makes some draws dead.** A card with no legal target is salvage.
  That pressure is the point, but on the early 15-module pool it will sometimes
  read as the game withholding.
- **Twenty recipes is a lot of table to balance**, and only eight are reachable
  before unlocks.
- **The block and the gate are both things you walk to.** They cannot be live
  together — no blocks after the collapse begins — but a player who has learned
  to ignore the gate for five minutes has to learn a second rule for the block.
- **`execute_below` needs its miniboss exemption to stay written down.** It is
  one comparison, and forgetting it deletes four boss fights.
- **The queue-window fix changes shipped balance.** Mines and terrain zones have
  never dealt damage; afterwards they do. A real difficulty change arriving
  inside a feature branch.
- **The perf gate had to grow a homing loadout.** Its stress build carries no
  fused module, so the steering path would have executed zero times and the gate
  could only ever have passed — evidence of nothing.

## Out of scope

Un-fusing; second-tier recipes that fuse a fused row again; two-module recipes;
blocks in the corridor; meta-progression that unlocks or remembers recipes
between runs; per-fused-module visuals beyond colour.
