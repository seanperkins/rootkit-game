# ROOTKIT

A bullet heaven where the build system is the hacking. You are a rogue process
in a corporate network; you move, everything else fires itself, and your power
comes from compiling exploits out of typed modules.

Godot 4.7, GDScript, no image assets.

## Run it

```
godot                      # from the project root
```

**WASD or arrows.** All weapons auto-fire. A run is a **campaign of three
subnets**: survive five minutes, then kill the ICE that follows.

Clearing ICE does not move you on by itself. A **gate** stands at the arena's
edge from the moment it generates, shut — you fight past it for the whole
subnet. Killing ICE halts the spawns, opens it, lights the route to it across
walkable ground, and starts the arena coming apart from the far side inward.
Ground that has gone is drawn as gone, because standing on it is fatal. Walk in,
cross the corridor, and the far end puts you on the next subnet's
own floor with your build, level and XP intact and 30% of your integrity back,
the gate shutting behind you. Take as long as you like getting there: nothing is
spawning. Clearing the last subnet wins outright — it has no gate.

All three subnets are **plotted before the first frame**, on one grid: three
arenas laid out end to end and a corridor spanning each gap, running from one
arena's edge to the next one's. Nothing is generated under your feet and nothing
moves you — the transition is the walk, and the ground is the same array the
whole way. Which arena is *current* is the only thing that changes.

Enemy integrity scales on both axes — up through each subnet, and again with
the subnet number — because a rank buys damage linearly and constant HP meant
everything one-shot forever once your damage passed 34. Each clear banks its
salvage, so dying on subnet 03 keeps what 01 and 02 paid out; only salvage
earned since the last clear is lost. Kills and flips always count toward
unlocks.

Every arena gets its own **terrain** from the run seed: walls that stop you,
your shots and the swarm, plus hazard, slow and corruption zones. Density is
flat across subnets — a late arena with less room to kite reads as cramped
rather than hard, so difficulty escalates through enemy HP and the wave table
instead. Generation guarantees the whole map is fully connected — an unreachable
pocket would be an unwinnable run, and an arena whose mouth was walled off would
be one too — by filling any sealed region rather than carving into it.

Arenas, corridors and the grid itself all snap to the lattice the ground is
drawn on, so the tiles run edge to edge instead of stopping part way through one
at the arena wall.

## Triggers

A trigger is paid on the axis its FREQUENCY suits. `interval` sits at cadence
1.00 — the baseline, not a bonus. Frequent triggers (`on_hit` 0.62, `on_kill`
0.70, `on_flip` 0.74) go below it, so a build feeding their condition genuinely
out-fires the metronome. Rare ones are paid in **burst** instead — how many
times the vector emits for one event: `on_damage_taken` 3, `on_low_integrity` 5,
`on_level_up` 8. `on_flip` pays in corruption rather than damage, so it feeds
the build that feeds it.

`interval` keeps the one thing none of them can have: it never idles. It fires
on an empty field, during the collapse walk, and at the start of a run when
there is nothing yet to trigger on.

## The build

An **exploit** is one weapon with three slot types:

| Slot | Count | Decides | Modules |
|---|---|---|---|
| `VECTOR` | 1 | how it reaches enemies | broadcast, packet, chain, beam, spike, flood, snipe, landmine, cascade, bounce, mirror, throttle, airgap, checksum |
| `TRIGGER` | 1 | when it fires, how it scales cadence, and how many shots one event produces | interval, on_kill, on_hit, on_damage_taken, on_low_integrity, on_flip, on_level_up |
| `PAYLOAD` | 0–1 | what it does on contact | buffer_overflow, fork_bomb, corrupt, keylog, worm, fork, overclock, harden, sandbox, nice |

You hold three exploits. A module's slot type picks its **column**, so the only
question left is which **row** — and each of the three level-up cards carries one
button per exploit row, marked with what pressing it does: `^` rank up, `+` fill
an empty slot, `x` replace the occupant, `*` found a new row. One click places
the module. Any card can be declined for salvage.

## Fusion

A **recipe** is three exact modules — a vector, a trigger and a payload. There
are twenty, and every vector, trigger and payload appears in at least one, so no
card is ever a dead end. `snipe + on_kill + bitmask` is `zero_day()`: a homing
sniper that picks the strongest thing in range.

Matching the ids is not enough. **All three must be at max rank**, because a
recipe is what three finished modules become rather than a way to skip finishing
them. And matching does not fuse on its own — a **block** materialises in the
arena every 45 seconds, and holding ground inside it for eight seconds is what
compiles the recipe. Step off and the ring drains at twice the rate it filled,
while the swarm keeps coming.

Fusing consumes all three modules and **frees their ids**, which is the point: a
module id occupies exactly one slot in the whole loadout again, so the way to put
`interval` in a second exploit is to fuse the row holding the first. A fused row
keeps one open payload slot, and the fused module ranks 1→5 through the ordinary
card pool like anything else. It cannot be un-fused.

A block that cannot fuse anything still pays: most often a **targeted card** —
the module you are one short of, or one that un-inerts a row — and otherwise
salvage, integrity, or a guaranteed rank-up. Press `r` on the level-up screen for
the recipe list, which shows only recipes whose three modules you have unlocked,
marked `[x]` held and maxed, `[-]` held but short, `[ ]` missing.

Damage tagged `corruption` fills a second bar. An enemy that fills it **flips**
into a botnet node that fights for you, and drops the same shards a kill does,
so a corruption build doesn't starve its own levelling.

Enemies are no longer one behaviour with different numbers. `sentinel`
telegraphs and commits to a dash. `tracer` steers at where you are going rather
than where you are. `watchdog` hangs back healing the swarm, so it is a target
you have to dig for. `rootkit` submerges out of the world entirely —
untouchable and harmless while under — and surfaces on you after a tell.
`probe` keeps its distance and shoots, which is what makes walls worth standing
behind.

A **mini-boss** arrives every minute — `fork_bomb` splits into halves three
generations deep, `packet_filter` takes 90% less damage from the front so you
have to get behind it, `null_ptr` blinks and leaves damaging afterimages where
it vanished, and `kernel_panic` pulses everything with line of sight to it, so
a wall is the only answer. None has to be killed; each pays salvage and a
guaranteed card if you do.

## Architecture

Enemies, projectiles, shards, and botnet nodes are **packed arrays over a
uniform grid** — no `Area2D` anywhere, including the player. Hit detection,
proximity queries, and separation steering all read one grid rebuilt once per
tick.

All combat resolves in one ordered nine-step tick (`scripts/run/run.gd`), never
inside a callback. Each entity is **adjudicated exactly once per tick**, from
the totals of the pass it was first marked in, and flip beats death.

```
scripts/core/    grid
scripts/build/   module  equipped_module  exploit  resolved_exploit
                 compiler  loadout  player_stats                    (pure)
scripts/combat/  population  hit_queue
scripts/run/     run  terrain  spawn_director  ui  backdrop  props
scripts/meta/    save_game  meta_screen
data/            module_table  enemy_table
shaders/         glyph.gdshader
```

`codemaps/` breaks each of those down further — the tick pipeline, the compiler's
fold rules, every table value. `CLAUDE.md` collects the invariants that break
quietly, which is the part worth reading before changing any of it.

## Tests

```
tools/run_tests.sh            # every suite, plus the perf gate
tools/run_tests.sh --fast     # skip the perf gate
```

Use the runner rather than calling suites by hand. A GDScript runtime error
aborts only the function it happens in — the engine prints `SCRIPT ERROR`,
`_initialize` carries on, and a suite whose assertions never ran exits 0 saying
`PASS`. That has hidden two real breakages here. The runner reads stderr as well
as the verdict and fails a suite on any script error, whatever it claims about
itself.

Individually:

```
godot --headless -s res://tests/test_build.gd        # compiler + auto-slot rules
godot --headless -s res://tests/test_drain.gd        # adjudication, both orders
godot --headless -s res://tests/test_corruption.gd   # flip -> botnet
godot --headless -s res://tests/test_meta.gd         # shop, unlocks, save durability
godot --headless -s res://tests/test_run.gd          # a full autopiloted campaign
godot --headless -s res://tests/test_campaign.gd     # subnet advance, banking, the win
godot --headless -s res://tests/test_terrain.gd      # generation, connectivity, collision
godot --headless -s res://tests/test_terrain_run.gd  # zones and terrain in a live run
godot --headless -s res://tests/test_gates.gd        # the gate, the corridor, the walk through
godot --headless -s res://tests/test_collapse.gd     # distance field, collapse order, the route
godot --headless -s res://tests/test_minibosses.gd   # the schedule and the four mechanics
godot --headless -s res://tests/test_cards_keyboard.gd # level-up and fusion by keyboard
godot --headless -s res://tests/test_fusion.gd       # recipes, the fused head, the five mechanics
godot --headless -s res://tests/test_blocks.gd       # the block schedule, the hold, the payout
godot --headless -s res://tests/test_player_stats.gd # mitigation formula, hostile inputs
godot --headless -s res://tests/test_player_sheet.gd # the sheet reaches a live run
godot --headless -s res://tests/test_wards.gd        # ward timers, max-not-sum
godot --headless -s res://tests/test_multipliers.gd  # attack/haste/reach reach combat
godot --headless -s res://tests/test_travel.gd       # packet range and projectile life
godot --headless -s res://tests/test_meta_layout.gd  # the shop fits the viewport
godot --headless -s res://tests/perf_milestone0.gd   # the architecture gate
```

The perf gate drives the **real** `run._physics_process`, not a model of it, and
gates on a full autopiloted run: mean 1.13 ms, p95 2.40 ms against an 11 ms
budget derived from the 60 Hz frame. It also reports a stress figure with every
pool at simultaneous cap (600 enemies + 400 projectiles + 1500 shards + 64
botnet — a load real play never reaches): mean 7.5 ms, p95 9.7 ms, still inside
the frame. It is load-relative, timing a fixed workload first and scaling the
budget, because identical code measures 5.2 ms median on a quiet machine and
8.5 ms under load.

## Not in this build

Audio, additional subnets (the node map is scaffolded but unreachable),
controller support, healing beyond `keylog`'s lifesteal and a block's integrity
payout, un-fusing, and second-tier recipes that fuse a fused row again.

## Design

`docs/superpowers/specs/2026-08-29-rootkit-bullet-heaven-design.md` — the spec,
plus a record of the three review rounds that reshaped it, including the
architecture reversal from pooled `Area2D` to packed arrays.
