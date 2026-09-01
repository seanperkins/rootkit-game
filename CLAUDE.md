# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

ROOTKIT — a Godot 4.7 / GDScript bullet heaven where the build system is the
hacking. No image assets, no font files, no `Area2D` anywhere.

## Commands

```bash
godot                          # play, from the project root
tools/run_tests.sh             # 36 suites + the perf gate
tools/run_tests.sh --fast      # skip the perf gate
godot --headless -s res://tests/test_build.gd     # one suite
godot --headless -s res://tools/shot_cards.gd     # one screenshot
python3 tools/build_manual.py  # regenerate site/ (gitignored)
```

**Always use `tools/run_tests.sh`, never call a suite by hand and trust it.** A
GDScript runtime error aborts only the function it happens in: the engine prints
`SCRIPT ERROR`, `_initialize` carries on, and a suite whose assertions never ran
exits 0 saying `PASS`. That has hidden two real breakages here. The runner reads
stderr and fails a suite on any `SCRIPT ERROR` or `Parse Error` whatever the
suite claims about itself.

## Architecture

Detailed maps live in `codemaps/` (`architecture.md`, `build.md`, `combat.md`,
`data.md`, `ui.md`) — read those before a change that spans files. The shape:

- **`scripts/build/` is pure.** No scene tree, no globals, no engine calls beyond
  `Resource`/`RefCounted`. It compiles a `Loadout` of 3 `Exploit`s down to flat
  `ResolvedExploit` structs. This runs once per module pick; combat reads only
  the flat result and never touches the build layer. Keep it that way — every
  build test drives it in isolation.
- **Entities are packed arrays over a spatial grid**, not nodes.
  `Population` holds parallel `PackedVector2Array`/`PackedFloat32Array` and
  swap-removes on despawn (which is what keeps `MultiMesh.visible_instance_count`
  correct). `Grid` is a counting-sort window that follows the player, rebuilt
  once per tick and shared by hit detection, proximity queries and steering.
- **All combat resolves in one ordered tick in `run.gd:_physics_process`, never
  inside a callback.** Adding a step means adding a call there, in the right
  place — not a signal.
- **The whole 3-subnet campaign is one terrain grid**, plotted before the first
  frame. Arenas end to end, a corridor per gap. `terrain.current` is the only
  thing that changes; nothing is generated under the player and nothing teleports.

## Invariants that break quietly

These are load-bearing and their failure modes are silent. Most are documented at
the site; this is the index.

- **`Module.VectorKind` / `TriggerKind` are append-only.** Values are stored on
  modules; inserting in the middle repoints every module defined above it.
- **`EnemyTable.ICE` is an index into `all()`, so `ice` must stay the last row.**
  The boss spawn, the win condition and the flip guard all read it.
- **`Module.STAT_KEYS` is the only legal stat-key set.** Validate against it, not
  against "fields of `ResolvedExploit`".
- **`ResolvedExploit.cadence_mult` defaults to `1.0`**, alone among its fields.
  Anything that resets fields generically breaks on it. `pierce`, `chain_count`,
  `botnet_cap`, `orbit_count` and `burst` are untyped on purpose — they
  accumulate as float and `Compiler.build` floors them once at the end.
- **Defensive stats fold by MAX, offensive by SUM.** A module id may occupy any
  number of slots, so summing `ward_*` / `lifesteal` / `slow_*` / `shield` would
  buy magnitude at zero uptime cost. See `Compiler.MAX_FOLD_KEYS`.
- **`SaveGame` holds deltas; the compiler wants absolutes.** Everything must pass
  through `PlayerStats.mults()`, or a +0.40 rank scales damage *down* by 60%.
  Player-sheet stats (`SHEET_EFFECT`) go straight to `run.gd` and must never
  reach the compiler — that separation is what stops a shop upgrade being
  silently delivered as an exploit stat.
- **`Loadout.compile_all` is the only runtime caller of `Compiler.build`.** A
  multiplier that does not go through `Loadout.mult` reaches no exploit at all.
- **The last INTERVAL trigger cannot be displaced** — an all-event loadout could
  never fire.
- **Per-enemy arrays need BOTH halves of the slot invariant.** *Reset on spawn*:
  `Population.spawn` recycles slots, so a stale phase means an enemy commits to a
  dash it never wound up for — use `_clear_ai` / `_spawn_enemy_state`. *Relocate
  on despawn*: `Population.despawn` swap-removes the tail into the freed slot for
  its OWN arrays only, so every parallel array must follow, via
  `_relocate_enemy(i, last)`. There are **two** despawn sites — `_step9_recycle`
  and `_step2d_collapse`, whose `is_void` predicate is conditional and therefore
  not tail-only — and `_step2d_collapse` relocated nothing at all until the
  polish pass. `test_arrivals` asserts the rule structurally: every
  middle-of-pool `enemies.despawn` must relocate first. `_order` is the one
  deliberate exception, because `_depth_sort` refills it wholesale each tick.
- **An entity is adjudicated exactly once per tick, then CLOSED**, from the
  totals of the pass it was first marked in. Flip beats death. `ON_HIT`,
  `ON_KILL` and `ON_DAMAGE_TAKEN` are three different conditions — do not fire
  them from one loop.
- **Every id in `meta_screen.BUFFS` must exist in `SaveGame._default()["buffs"]`.**
  `_refresh` indexes it with no `.get`, so a missing name crashes the shop on open.
- **`SaveGame.MILESTONES` is the single source for the unlock ladder.** The shop's
  requirement text reads it via `milestone_text`; do not hardcode a second copy.
- **`save.json` is user-editable and treated as hostile.** The `maxf(0.0, …)`
  guards in `PlayerStats.mitigate` and the key-dropping in `sheet()`/`mults()`
  are there for that reason, not habit.

## Balance rationale

Numbers in `data/` carry the reasoning that set them in comments beside them.
Two that drive the rest:

- Enemy integrity scales on both axes (`SpawnDirector.hp_mult`) because a rank
  buys damage linearly — with constant HP everything one-shot forever past 34.
- Terrain density is **flat** across subnets. A cramped late arena reads as
  cramped, not hard; escalation lives in enemy HP and the wave table.

Design specs and implementation plans are in `docs/superpowers/`, one pair per
feature. The original spec — including the architecture reversal from pooled
`Area2D` to packed arrays — is
`docs/superpowers/specs/2026-08-29-rootkit-bullet-heaven-design.md`.
