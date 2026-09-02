# Online Co-op Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement
> this plan task-by-task. Create an isolated worktree with `using-git-worktrees`
> before changing code. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add deterministic direct-connect co-op for one to four players. Every
peer runs the same packed-array simulation; only input records and recovery
state cross the network. Dropped players park and may reconnect. Only a
host-confirmed ending finishes a network run.

**Architecture:** Keep `run.gd` authoritative over one deterministic 60 Hz
simulation. `Lockstep` is a pure fixed-size input ring and owns required masks,
arrival tags, records, executed tick, and checksum reports. `NetworkSession` is
a pure control-plane state machine holding the immutable descriptor, roster, a
`Lockstep` reference, recovery boundaries, and ending barriers. `Transport` is
the only ENet-facing `Node`; it validates packets, submits INPUT/RELAY records
through `session.lockstep`, and forwards control messages to `NetworkSession`.
`run.gd` polls it above the simulation guard. A single manifest drives snapshot
and checksum consumers. All entities remain packed arrays; players become four
fixed parallel-array slots.

**Tech stack:** Godot 4.7, GDScript, `ENetMultiplayerPeer`, raw packets. No RPC,
`MultiplayerSynchronizer`, `MultiplayerSpawner`, image assets, font files, or
`Area2D`.

**Spec:** `docs/superpowers/specs/2026-09-01-online-coop-design.md`. Read it
alongside this plan. The spec owns protocol semantics; this plan owns sequencing
and exact code surfaces.

## Global constraints

- **Use `tools/run_tests.sh`, never a suite directly.** A GDScript runtime error
  can print PASS and exit zero; only the runner rejects `SCRIPT ERROR` and
  `Parse Error` reliably.
- Run `tools/run_tests.sh --fast` after every task. Run the full
  `tools/run_tests.sh` at the final performance checkpoints.
- Commit after each task. Do not combine independent failures into one commit.
- `scripts/build/`, `scripts/run/feel.gd`, `scripts/audio/synth.gd`,
  `scripts/net/lockstep.gd`, `scripts/net/network_session.gd`, and
  `scripts/net/protocol.gd` stay pure: no scene tree and no engine singleton
  beyond `Resource` / `RefCounted`.
- `scripts/net/transport.gd` is the only class that touches ENet. Simulation
  code never branches on peer state below the guard or while applying input,
  and never receives a node callback.
- One clean cutover: no scalar-player aliases, deprecated packet formats,
  compatibility accessors, or duplicate ending paths remain at completion.
- Per-enemy arrays keep both halves of the slot invariant: reset on spawn and
  relocate before both middle-of-pool despawns.
- Snapshots are primitives only. Decode with `bytes_to_var`, never
  `bytes_to_var_with_objects`. Validate lengths and caps before writing state.
- Input records are immutable once submitted. The tick reads no device, clock,
  connection, or variable delta.
- Each new test case follows the repository's `_check` plus `finished` idiom.
- Add every new suite to `tools/run_tests.sh` when the suite is created.

## Planned new files

| File | Responsibility |
|---|---|
| `data/session_rules.gd` | Shared constants: protocol version, player cap, fixed tick, delays, leash, scaling, packet limits |
| `scripts/net/lockstep.gd` | Pure input ring, required mask, checksums |
| `scripts/net/network_session.gd` | Pure descriptor/roster and recovery/ending control state |
| `scripts/net/protocol.gd` | Pure message codec and field validation |
| `scripts/net/transport.gd` | ENet creation, polling, channels, timeout, packet counters |
| `tests/support/multiplayer_harness.gd` | Deterministic multi-instance stepping and in-memory message pump; not a suite |
| Thirteen `tests/test_*.gd` suites | The verification matrix from the spec |

`StateCodec` is deliberately not another class. `run.gd` already owns the
manifest, counts, pool caps, and derived rebuild rules; splitting decode from
those facts would create a second schema. `serialize_state`, `restore_state`,
and `_state_hash` live beside `STATE_FIELDS` in `run.gd`.

---

## Task 1: Replace wall-clock hitstop with fixed simulation ticks

**Files:**
- Create: `data/session_rules.gd`
- Create: `tests/test_determinism_rules.gd`
- Modify: `scripts/run/run.gd`
- Modify: `scripts/run/feel.gd`
- Modify: `tests/test_feel.gd`
- Modify: `tests/test_run.gd`
- Modify: `tools/run_tests.sh`

**Interfaces:**

```gdscript
# data/session_rules.gd
class_name SessionRules extends RefCounted
const TICK_DT := 1.0 / 60.0
const HITSTOP_TICKS := 4  # Existing 60 ms hitstop rounded up at 60 Hz.
const MAX_PLAYERS := 4
const DEFAULT_DELAY := 4
const LAN_DELAY := 3
const CHOICE_TIMEOUT_TICKS := 1800
const MOVE_COMPONENT_MAX := 1.3635
const MAX_WINDOW := 7200
const LEASH := MAX_WINDOW - 3200
const SNAPSHOT_MAX := 1 << 20
```

- [ ] **Step 1: Add failing deterministic-tick tests.**
  `test_determinism_rules` must prove `_physics_process` ignores its `dt`
  argument below the guard, a hitstop consumes exactly `HITSTOP_TICKS` input
  ticks without stepping the world, `_present` still runs during those ticks,
  and neither `Time.get_*` nor `Engine.time_scale` is reachable from the tick
  call graph. Update `test_run` to assert death hitstop without reading global
  time scale. Update `test_feel` to stop asserting deadline arithmetic.

- [ ] **Step 2: Add `test_determinism_rules` to `SUITES`; run
  `tools/run_tests.sh --fast`, expect that suite to fail.**

- [ ] **Step 3: Implement the fixed tick.** Rename `_physics_process(dt)` to
  `_physics_process(_dt)`. Pass `_dt` only to `_present` as its wall/display
  delta; pass `SessionRules.TICK_DT` to every simulation step. Add
  `hitstop_ticks: int`; `_hitstop()` sets the maximum of the current value and
  `HITSTOP_TICKS`. Above the world-step guard, decrement one tick and return
  while nonzero. Keep input intake/application and `_present` above that return.

- [ ] **Step 4: Delete wall-clock hitstop.** Remove `Feel.HITSTOP_SCALE`,
  `HITSTOP_MS`, `hitstop_until_ms`, `start_hitstop`, `time_scale`, and
  `release_hitstop`. Remove every `Engine.time_scale` write, `Time.get_*` call,
  `_exit_tree` reset, and the scale division in `_present`. Presentation ages
  on `minf(_dt, MAX_PRESENT_DT)` only.

- [ ] **Step 5: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 6: Commit:** `refactor: make hitstop part of the deterministic tick`

---

## Task 2: Introduce the immutable session descriptor and seeded streams

**Files:**
- Create: `scripts/net/network_session.gd`
- Create: `tests/test_meta_derivation.gd`
- Modify: `data/session_rules.gd`
- Modify: `scripts/meta/save_game.gd`
- Modify: `scripts/run/run.gd`
- Modify: `scripts/run/spawn_director.gd`
- Modify: `tests/test_meta.gd`
- Modify: `tests/test_determinism_rules.gd`
- Modify: `tools/run_tests.sh`

**Interfaces:**

```gdscript
# scripts/net/network_session.gd
class_name NetworkSession extends RefCounted

enum Role { SOLO, HOST, CLIENT }
var descriptor: Dictionary  # protocol, session_id, seed, delay, choice_timeout, roster
var local_slot: int
var role: int

static func solo_descriptor(profile: Dictionary, seed: int) -> Dictionary
static func validate_descriptor(raw) -> Dictionary
func profile(slot: int) -> Dictionary
```

```gdscript
# scripts/meta/save_game.gd
static func session_counters() -> Dictionary
static func sanitise_session_counters(raw) -> Dictionary
static func player_sheet_from(counters: Dictionary) -> Dictionary
static func multipliers_from(counters: Dictionary) -> Dictionary
static func unlocked_modules_from(counters: Dictionary) -> Array
```

- [ ] **Step 1: Write `test_meta_derivation`.** Build two profiles with different
  buffs, kills, and flips; exchange them through one descriptor; construct two
  `NetworkSession` objects; assert byte-identical sanitised descriptors and
  byte-identical derived sheet, multipliers, unlock ids, and compiled starting
  loadouts for both slots. Reject unknown fields, hostile numeric values,
  overlong names, bad protocol versions, duplicate slots, and more than four
  roster rows.

- [ ] **Step 2: Add the suite and run `tools/run_tests.sh --fast`; expect
  `test_meta_derivation` to fail.**

- [ ] **Step 3: Refactor save derivation around explicit counters.** Existing
  no-argument readers delegate to the new `*_from` functions using
  `session_counters()`. The remote path never mutates `SaveGame._cache` and
  never trusts stored `unlocked`; milestone counters remain the source.

- [ ] **Step 4: Build the local solo descriptor before `_ready` initialises the
  simulation.** Add `run.configure_session(session)` for tests and lobby use;
  when absent, construct a one-slot descriptor with delay zero and no choice
  timeout. Network descriptors default to delay 4, LAN presets use 3, and lobby
  configuration may tune the delay before START. The session choice timeout is
  `CHOICE_TIMEOUT_TICKS` (1800). Store the session seed once.

- [ ] **Step 5: Derive every RNG from `descriptor.seed`.** Seed `Terrain`,
  `SpawnDirector`, `_rng`, `_block_rng`, and one `_card_rng` per possible slot
  with stable integer salts. Move the existing fork-bomb child offsets and
  miniboss spawn angles out of `_card_rng` into `_rng`; card shuffles and
  block-payout rolls stay in the owning slot's `_card_rng`. No stream calls
  `randomize()`.

- [ ] **Step 6: Extend `test_determinism_rules`** to enumerate every RNG used in
  the tick and prove each seed derives from the descriptor.

- [ ] **Step 7: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 8: Commit:** `feat: derive simulation state from one session descriptor`

---

## Task 3: Close the remaining deterministic prerequisites

**Files:**
- Modify: `scripts/combat/hit_queue.gd`
- Modify: `scripts/run/run.gd`
- Modify: `tests/test_drain.gd`
- Modify: `tests/test_blocks.gd`
- Modify: `tests/test_determinism_rules.gd`
- Modify: `tests/perf_milestone0.gd`

**Interfaces:**

```gdscript
# hit_queue.gd
var dropped := 0
func append(...) -> bool  # increments dropped when full
```

- [ ] **Step 1: Add failing tests** for a full queue incrementing `dropped`,
  resetting `dropped` only when the run is constructed, negative
  `killer_exploit` / `flipper_exploit` never decoding to slot zero, and a block
  payout offering fusion even when no UI signal connection exists.

- [ ] **Step 2: Run `tools/run_tests.sh --fast`; expect failures in the changed
  suites.**

- [ ] **Step 3: Raise the queue capacity** to
  `EVENT_BUDGET * SessionRules.MAX_PLAYERS` (28,800) and make every failed
  append count. Keep the counter permanent, not per tick.

- [ ] **Step 4: Remove `fusion_offered.get_connections()` from `_block_payout`.**
  The offer enters simulation state unconditionally; presentation observes it.

- [ ] **Step 5: Centralise exploit ownership decoding.** Negative gids return
  no owner before division. Replace direct sentinel division in death, flip,
  lifesteal, banking, and trigger attribution.

- [ ] **Step 6: Make the perf fixture assert `queue.dropped == 0`.**

- [ ] **Step 7: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 8: Commit:** `fix: close deterministic multiplayer prerequisites`

---

## Task 4: Build the pure lockstep ring

**Files:**
- Create: `scripts/net/lockstep.gd`
- Create: `tests/test_lockstep.gd`
- Modify: `data/session_rules.gd`
- Modify: `tools/run_tests.sh`

**Interfaces:**

```gdscript
class_name Lockstep extends RefCounted
const RING := 128

var executed := 0
var delay := 0
var _required := 0
# Packed arrays: moves, cards, targets, offers, tick tags, have masks.
# `take` fills caller-owned arrays; the 60 Hz path allocates nothing.

func submit(slot: int, tick: int, move: Vector2, card: int,
    target: int, offer: int) -> bool
func ready(tick: int) -> bool
func take(tick: int, out_moves: PackedVector2Array,
    out_cards: PackedInt32Array, out_targets: PackedInt32Array,
    out_offers: PackedInt32Array) -> bool
func mark_live(slot: int) -> void
func mark_dead(slot: int) -> void
func mark_absent(slot: int) -> void
func mark_present(slot: int) -> void
func prime(first: int, last: int) -> void
func submit_checksum(slot: int, tick: int, hash_value: int) -> bool
func desync_at() -> int
func snapshot_window(after_tick: int) -> Dictionary
func merge_window(raw: Dictionary, after_tick: int) -> bool
```

- [ ] **Step 1: Write the complete `test_lockstep` matrix from the spec.** Cover
  LIVE readiness, ignored DEAD records, empty ABSENT records, primed tick zero,
  immutable resubmission, old wrap tags, stale ticks, the exclusive
  `executed + RING` bound without clearing the current cell, record shape/tick
  validation without mutating field values, checksum agreement/disagreement,
  and snapshot-window merge.

- [ ] **Step 2: Add the suite and run `tools/run_tests.sh --fast`; expect the new
  suite to fail.**

- [ ] **Step 3: Implement with pre-sized packed arrays.** One ring cell stores
  all four slots. A newer absolute tick clears exactly its aliased cell before
  writing. `take(T, ...)` validates readiness, fills four caller-owned packed
  arrays in slot order without allocating, clears nothing needed by the
  retained-report window, and advances `executed` to `T + 1`.

- [ ] **Step 4: Keep arrival state out of checksums.** The ring snapshot is for
  recovery continuity only; `Lockstep` exposes deterministic executed state and
  checksum reports separately.

- [ ] **Step 5: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 6: Commit:** `feat: add a pure deterministic lockstep ring`

---

## Task 5: Add the dynamic party window, leash, and corridor collapse

**Files:**
- Modify: `scripts/core/grid.gd`
- Modify: `scripts/run/terrain.gd`
- Modify: `scripts/run/run.gd`
- Modify: `data/session_rules.gd`
- Modify: `tests/test_flow.gd`
- Modify: `tests/test_collapse.gd`
- Create: `tests/test_plurality.gd`
- Modify: `tools/run_tests.sh`

**Interfaces:**

```gdscript
# grid.gd
func _init(origin, max_size, cell_size, capacity)
func set_window(world_rect: Rect2) -> void
func live_cell_count() -> int

# terrain.gd
const CORRIDOR_COLLAPSE_TICKS := ...
func _clear_collapse_state() -> void
```
- [ ] **Step 1: Add failing tests** for direct `Grid.set_window` rectangles:
  exactly 10,000 live cells at the 3200-square minimum, exactly 50,625 at the
  7200-square maximum, and cell-snapped edges. Also assert corridor cells
  follow arena cells in `_collapse_order` from the arena end toward `g.end`.
  Party-bound and leash behaviour waits for real slots in Task 7.

- [ ] **Step 2: Add `test_plurality` to `SUITES`; run
  `tools/run_tests.sh --fast`, expect failures.**

- [ ] **Step 3: Preallocate `Grid` for `MAX_WINDOW`, but make `_cols`, `_rows`,
  `_ncells`, and `_origin` describe the current snapped rectangle.** Rebuild
  clears and scans only live cells. Queries clamp to the live rectangle.

- [ ] **Step 4: Add the party-window calculation in `run.gd`.** For now the
  one-slot solo descriptor produces exactly the current 3200-square window,
  clamped to terrain bounds.

- [ ] **Step 5: Append corridor cells to terrain collapse order.** Keep one
  `_collapse_idx` and one write path for `voided`. Add
  `_clear_collapse_state()` and call it from `enter_next()`; remove scattered
  partial resets.

- [ ] **Step 6: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 7: Run full `tools/run_tests.sh`.** The solo perf gate must retain
  its current budget before plurality work begins.

- [ ] **Step 8: Commit:** `feat: bound the party grid and collapse corridors`

---

## Task 6: Convert the solo runtime to slot-indexed state

This is the mechanical cutover. Preserve one-player behaviour before adding
plurality. A current source audit finds **27** suites in the migration surface;
migrate that observed set.

**Files:**
- Modify: `scripts/run/run.gd`
- Modify: `scripts/run/ui.gd`
- Modify: `scripts/run/blocks.gd`
- Modify: `scripts/core/flow_field.gd`
- Modify these 27 suites:
  `test_behaviour.gd`, `test_input.gd`, `test_interpolation.gd`,
  `perf_milestone0.gd`, `test_flow.gd`, `test_arrivals.gd`, `test_hud.gd`,
  `test_cards_keyboard.gd`, `test_run.gd`, `test_meta_layout.gd`,
  `test_fusion.gd`, `test_fusion_run.gd`, `test_drain.gd`, `test_blocks.gd`,
  `test_collapse.gd`, `test_terrain_run.gd`, `test_wards.gd`,
  `test_campaign.gd`, `test_gates.gd`, `test_worms.gd`, `test_triggers.gd`,
  `test_travel.gd`, `test_player_sheet.gd`, `test_multipliers.gd`,
  `test_effects.gd`, `test_corruption.gd`, `test_dispatch.gd`
- Modify these 10 tools:
  `tools/fps_collapse.gd`, `tools/fps_probe.gd`, `tools/screenshot.gd`,
  `tools/shot_collapse.gd`, `tools/shot_fx.gd`, `tools/shot_gate.gd`,
  `tools/shot_iso.gd`, `tools/shot_props.gd`, `tools/shot_seam.gd`,
  `tools/shot_slots.gd`

**Slot state:****Slot state:**

```gdscript
enum SlotState { LIVE, DEAD, ABSENT }
var player_pos: PackedVector2Array        # size MAX_PLAYERS
var player_prev_pos: PackedVector2Array
var player_render_pos: PackedVector2Array
var player_vel: PackedVector2Array
var player_health: PackedFloat32Array
var player_iframe: PackedFloat32Array
var player_shield: PackedFloat32Array
var slot_state: PackedByteArray
var kills: PackedInt32Array
var flips: PackedInt32Array
var _banked: Array                       # one primitive dictionary per slot
var _sheet: Array
var pickup_radius: PackedFloat32Array
var _unlocked: Array
var loadouts: Array
var resolved: Array                      # flattened gids
```

- [ ] **Step 1: Change the existing tests and tools first** to index local solo
  state through `run.local_slot`, e.g. `run.player_pos[run.local_slot]`. Change
  loadout reads to `run.loadouts[slot]`. Do not add scalar compatibility
  properties. Run `tools/run_tests.sh --fast`; expect broad compile failures.

- [ ] **Step 2: Allocate and derive all fixed player arrays from the immutable
  roster.** Only descriptor roster slots may become LIVE. Unused capacity is
  ABSENT. `local_slot` replaces `LOCAL_SLOT` as runtime data.

- [ ] **Step 3: Add the three ownership helpers and use them everywhere.**

  ```gdscript
  func _gid(slot: int, exploit_index: int) -> int
  func _decode_exploit(gid: int) -> Vector2i  # (-1, -1) for negative/invalid
  func _resolved(gid: int) -> ResolvedExploit
  func _slot_exploits(slot: int) -> PackedInt32Array
  ```

  `_fire_acc`, `_fire_cd`, `_ward_left`, and `_trigger_fires` are sized
  `MAX_PLAYERS * Loadout.MAX_EXPLOITS`; projectile and hit-queue ownership
  carries gids.

- [ ] **Step 4: Update every former scalar reader to take a slot.** Convert
  `_eff_integrity`, `_ward_max`, `_eff_armor`, `_eff_defense`,
  `_eff_clock_speed`, `_mitigated`, `_recompile`, `_damage_player`, `_die`,
  `_fire_trigger`, `_emit_vector`, `_pick_target`, `_card_pool`, and banking.
  In this task every gameplay caller passes slot zero/local slot, so behaviour
  remains solo-identical.

- [ ] **Step 5: Keep presentation explicitly local.** Camera, visible world
  rectangle, `_depth_sort` lower bound, `_draw`, HUD, and tools use
  `player_render_pos[local_slot]` or `player_pos[local_slot]`.

- [ ] **Step 6: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 7: Run each windowed shot tool in the existing visual workflow.**
  Each tool must exit zero and write its expected nonempty PNG; visually confirm
  the captured player/camera, cards, gate, collapse, props, seam, and FX remain
  present. Do not use `--headless`.

- [ ] **Step 8: Commit:** `refactor: index the solo runtime through player slots`

---

## Task 7: Implement every plurality census rule

**Files:**
- Modify: `scripts/run/run.gd`
- Modify: `data/session_rules.gd`
- Modify: `scripts/run/blocks.gd`
- Modify: `scripts/core/flow_field.gd`
- Modify: `scripts/run/spawn_director.gd`
- Modify: `tests/test_plurality.gd`
- Modify: `tests/test_behaviour.gd`
- Modify: `tests/test_flow.gd`
- Modify: `tests/perf_milestone0.gd`

**The complete `player_pos` site list:**

| Rule | Current functions/sites to replace |
|---|---|
| Session start/local presentation | `_ready` terrain generation; `_process`; `_snapshot_render_state`; `_visible_world_rect`; `_depth_sort`; `_draw` |
| Nearest LIVE target | `_step4_steer`; `_behave`; `_approach_dir`; `_pulse`; `_ranged`; shard magnet in `_step2_integrate`; zone selection |
| Target slot position + velocity | `_charge`; `_fire_hostile`; `_step6b_hostiles`; flanker lead |
| Every LIVE independently | player movement/iframes in `_step2_integrate`; contact and pickup in `_step6_detect`; player zones in `_step2b_zones`; void death and routes in `_step2d_collapse`; low-integrity crossing |
| Owning slot | every `_emit_vector` branch; `_hit` default origin; orbit re-anchor; mine placement; beam/cone/pulse/chain/projectile origins; ward/trigger dispatch |
| Sum over LIVE | botnet cap |
| Cycling LIVE | `_step1_spawn`; ICE/miniboss spawn and rings; block placement |
| Beyond every LIVE | `_step9c_reapproach`, relocating to the nearest slot's spawn ring |
| All LIVE past gate | `_step2c_gate`; `_advance_subnet` healing |
| Nearest LIVE to block | `_step2e_blocks`; `_block_payout` holder and holder RNG |
| One flow field per LIVE | flow rebuild in `_physics_process`; `_approach_dir` chooses nearest target's field |
| Local only | camera, culling, draw order, route display |

Current source anchors, grouped by the rows above: `515`; `712-713`; `785`;
`841`; `872`; `907`; `994`; `1039-1047`; `1119`; `1177`; `1216`; `1236`;
`1250`; `1313-1410`; `1438-1468`; `1540`; `1597`; `1604`; `1756`; `1816`;
`1839`; `1852`; `1965-1967`; `2178-2184`; `2302-2309`; `2332`; `2440`;
`2757`; `2817`. Declaration, documentation, and assignment-only occurrences
are excluded. Task 17 must reconcile the post-cutover search with this list.

- [ ] **Step 1: Expand `test_plurality` to assert every row above.** Include two
  slots on opposite sides of enemies/blocks/gates, party bounds grown by 1600,
  terrain clamping, the 3200-square floor, the 4000-unit leash, a DEAD slot
  skipped by targeting and an ABSENT slot with frozen firing/cooldowns, no
  pickup, and no contact, ownership-specific wards and ON_KILL, shared botnet
  cap, per-slot kill/flip attribution, unowned kills credited to nobody, first
  shard pickup winner, a slot dying when corridor collapse reaches it, and both
  block payout branches: heal the holder when eligible, otherwise add salvage
  to the shared pool.

- [ ] **Step 2: Run `tools/run_tests.sh --fast`; expect `test_plurality` to
  fail.**

- [ ] **Step 3: Add stable LIVE-slot helpers.** `_live_slots()`,
  `_nearest_live(point)`, `_party_bounds()`, `_party_centroid()`, and a
  deterministic cycling cursor. Iterate slot indices in ascending order; ties
  choose the lower slot.

- [ ] **Step 4: Move every LIVE slot and enforce the 4000-unit leash.** Test a
  proposed position against the other LIVE positions before terrain slide;
  clamp only the excess axis toward the centroid. Solo remains unchanged.

- [ ] **Step 5: Convert enemy/player interaction.** Each enemy chooses one
  nearest LIVE slot for the whole behaviour decision so steer direction,
  range gate, terrain avoidance, LOS, charge aim, and hostile lead cannot
  disagree. Contact, zones, iframes, low-integrity, pickup, and void death walk
  every LIVE slot independently.
- [ ] **Step 6: Convert origins, attribution, and banking.** Every exploit loop
  uses `_slot_exploits(slot)`. Ward folds stop at the owning slot. Lifesteal
  heals the owner. ON_KILL fires only the owner's build. Unowned kills credit
  nobody. Salvage remains shared and each bank event copies its full delta to
  every participant's `_banked`; kills and flips remain per slot. Simulation
  updates every slot's manifest state, but each process writes only
  `local_slot` to its local `SaveGame`. A completed block selects the nearest
  LIVE holder; its payout heals that holder when eligible, otherwise credits
  shared salvage.

- [ ] **Step 7: Allocate four `FlowField`s and update the dynamic grid window.**
  Grow LIVE party bounds by 1600, enforce a 3200-square minimum, clamp to the
  terrain grid, then cell-snap outward before `Grid.set_window`. Rebuild at most
  one field per LIVE slot when a boss exists; bosses read the nearest target's
  field. Establish the four-slot/full-leash/four-field perf fixture here; Task
  10 adds worst-case loadouts and hash cost.

- [ ] **Step 8: Apply scaling.** Both spawn rate and integrity scaling use the
  immutable session roster size: rate multiplies by `players`; integrity uses
  `1 + HP_PER_EXTRA_PLAYER * (players - 1)`. Define
  `HP_PER_EXTRA_PLAYER := 0.50` beside `SpawnDirector`'s existing enemy
  integrity constants, with the multiplayer time-to-kill rationale in its
  comment. Death and parking do not lower either. Keep `xp_needed` and
  `MAX_SHARDS` unchanged.

- [ ] **Step 9: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 10: Run full `tools/run_tests.sh`.** Require the four-slot,
  full-leash, four-flow-field, capped-population fixture without `_state_hash`
  or Task 10's worst-case loadouts to PASS the existing 11 ms normalised p95
  budget. Task 10 extends this same fixture and reruns the final gate.

- [ ] **Step 11: Commit:** `feat: make the packed simulation plural`

---

## Task 8: Make offers deterministic per-slot input state

**Files:**
- Create: `tests/test_offers.gd`
- Modify: `scripts/run/run.gd`
- Modify: `scripts/run/ui.gd`
- Modify: `scripts/build/loadout.gd` only if primitive import/export helpers are needed
- Modify: `tests/test_cards_keyboard.gd`
- Modify: `tests/test_fusion_run.gd`
- Modify: `tools/run_tests.sh`
- Modify: `CLAUDE.md`

**Offer row:**

```gdscript
# Primitive manifest data per slot. `contents` stores module-table indices,
# recipe indices, or payout enum values, never names or Resource objects.
{ "seq": int, "kind": int, "contents": PackedInt32Array,
  "deadline": int }
```

The queue stores the same explicit rows. Loadout state is flattened module-table
indices, ranks, and fused flags; no `Module`, `Exploit`, `Loadout`, recipe
object, generic `context`, or StringName enters a snapshot.

- [ ] **Step 1: Write `test_offers`.** Cover a choice with a stale `offer_seq`,
  timeout versus an in-flight stale pick, two level rounds opened on one tick,
  `pending_levels == 2`, a block payout queued behind an open level offer,
  first-card resolution through the generic slot-exit hook for both DEAD and
  ABSENT, fusion through the same choice record, and all LIVE slots resolving
  before `paused` clears. For the full input record, assert movement at
  `MOVE_COMPONENT_MAX` is preserved and movement at
  `MOVE_COMPONENT_MAX + 0.001` or with a non-finite component becomes
  `Vector2.ZERO`. Transport parking is not needed to exercise the hook.

- [ ] **Step 2: Add the suite and run `tools/run_tests.sh --fast`; expect it to
  fail.**

- [ ] **Step 3: Bind `Run` to the existing ring and populate its full record:**
  `{move, card, target, offer}`. Construct one `Lockstep` from the descriptor;
  solo delay zero is ready from tick zero, and tests inject all roster records
  directly. `_poll_local_input` samples UI intent once. During application,
  movement with a non-finite component or
  `abs(component) > SessionRules.MOVE_COMPONENT_MAX` becomes `Vector2.ZERO`;
  otherwise it is preserved unchanged. Validate `card`, `target`, and `offer`
  before offer state is touched.
  A bad choice becomes no choice, not a disconnect; the stored record remains
  immutable and unsanitised.

- [ ] **Step 4: Replace signal-driven choice state with per-slot primitive
  offers.** Every slot has monotonic `offer_seq`, one open offer, and a FIFO.
  `_open_offer`, `_apply_choice`, `_resolve_offer`, `_open_next_offer`, and one
  `_resolve_offer_on_slot_exit(slot)` hook are the only mutation paths. Task 14
  calls the hook on death; Task 15 calls it on parking. Card/fusion signals
  become presentation notices emitted from primitive state.

- [ ] **Step 5: Establish the transport-free tick suffix used by tests.** Once
  the ring is ready: take exactly one tick, apply choices, resolve deadlines,
  open queued rounds, then either hold below the world guard or step the fixed
  simulation. Solo uses delay zero and no timeout. In a session `user_paused`
  is presentation-only and causes that peer to submit neutral movement without
  stopping lockstep, world ticks, or hashes. Task 12 prepends device/network/
  presentation work to this suffix without changing its order.

- [ ] **Step 6: Re-emit the local open offer after restore/rebind.** UI renders
  only `local_slot` and displays `waiting for N…` for unresolved teammates.

- [ ] **Step 7: Update `CLAUDE.md` in this same commit.** Replace the old guard
  rule with: below the guard the world steps; above it run presentation, input
  intake, and input application. Add all three pure net classes to the
  pure-layer list. Count and record the runner's suite total after this task;
  Task 17 updates that count again after the remaining suites land.

- [ ] **Step 8: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 9: Commit:** `feat: make card and fusion offers lockstep inputs`

---

## Task 9: Add the state manifest, checksum, and hostile-safe snapshots

**Files:**
- Modify: `scripts/run/run.gd`
- Modify: `scripts/run/terrain.gd`
- Modify: `scripts/run/blocks.gd`
- Modify: `scripts/run/spawn_director.gd`
- Modify: `scripts/core/flow_field.gd`
- Modify: `scripts/core/grid.gd`
- Modify: `scripts/combat/population.gd`
- Modify: `scripts/combat/hit_queue.gd`
- Modify: `scripts/net/lockstep.gd`
- Modify: `data/session_rules.gd`
- Create: `tests/test_manifest.gd`
- Create: `tests/test_snapshot_hostile.gd`
- Modify: `tools/run_tests.sh`

**Manifest form:**

```gdscript
const SNAPSHOT := 1
const HASH := 2
var STATE_FIELDS: Array  # [object_key, property, flags, slice_rule]
var NOT_IN_MANIFEST: Dictionary  # property -> reconstruction reason

func serialize_state(after_tick: int) -> PackedByteArray
func restore_state(bytes: PackedByteArray, after_tick: int) -> bool
func _state_hash() -> int
```

- [ ] **Step 1: Write the structural half of `test_manifest`.** Parse every
  `var` in the nine files named by the spec. Require exactly one declaration in
  `STATE_FIELDS` or `NOT_IN_MANIFEST`, valid consumer flags, and a reconstruction
  reason for every exclusion. Fail on a new unclassified variable.

- [ ] **Step 2: Write behavioural manifest fixtures.** Include a corridor
  collapse, an open offer plus queued offer, a held block, worm-heavy entity
  state, and a middle-slot enemy despawn. Assert serialize → restore → equal
  hash → 600 equal ticks; exact derived `voided`; empty collapse-derived arrays
  after restoring FIGHTING; rebuilt gate blockers; recompiled loadouts; and a
  worst-case snapshot below `SessionRules.SNAPSHOT_MAX` (`1 << 20` bytes). Two
  peers with equal executed state but different future-ring arrivals must hash
  equally, while serialize/restore preserves each future ring exactly.

- [ ] **Step 3: Write `test_snapshot_hostile`.** Truncated bytes, random bytes,
  non-dictionary roots, oversized counts, mismatched parallel lengths, bad
  enum values, and an oversized packet must return false without mutating the
  live run or printing a script error. Movement exactly at
  `SessionRules.MOVE_COMPONENT_MAX` is preserved; NaN,
  `MOVE_COMPONENT_MAX + 0.001`, and finite `1e30` components each make the
  whole `move` `Vector2.ZERO`.

- [ ] **Step 4: Add both suites and run `tools/run_tests.sh --fast`; expect them
  to fail.**

- [ ] **Step 5: Implement `STATE_FIELDS` with explicit consumers.** Slice every
  population and per-entity parallel array to `count` for both snapshot and
  hash. Include lockstep's future ring as SNAPSHOT-only. Hash floats by their
  raw bytes, containers in stable insertion order, and dictionaries as sorted
  parallel key/value arrays only where the key set is not fixed.

- [ ] **Step 6: Implement transactional restore.** Decode primitives into a
  validated temporary dictionary; check every count, cap, length, enum, and
  required field; only then write objects. Clamp nothing silently except input
  records under their explicit sanitation rule.

- [ ] **Step 7: Rebuild derived state after restore.** Regenerate immutable
  terrain from the descriptor seed if needed; call `_rebuild_blocks`; rebuild
  collapse distance/order plus exact `voided` prefix only in CLEARED; otherwise
  call `_clear_collapse_state`; rebuild loadout objects and `resolved`; rebuild
  grid and hit queue before first read; re-emit the local offer.

- [ ] **Step 8: Snapshot the lockstep interval `(tick, tick + delay]` and merge
  it on restore.** Never overwrite records already delivered after the boundary.

- [ ] **Step 9: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 10: Commit:** `feat: add a bounded simulation state manifest`

---

## Task 10: Prove deterministic multiplayer simulation and its budget

**Files:**
- Create: `tests/support/multiplayer_harness.gd`
- Create: `tests/test_multiplayer_sim.gd`
- Modify: `tests/test_determinism_rules.gd`
- Modify: `tests/perf_milestone0.gd`
- Modify: `tools/run_tests.sh`

- [ ] **Step 1: Build the support harness.** Instantiate two or four `Run`
  nodes from the same descriptor, feed identical slot records in different
  arrival orders, step only when each ring is ready, and expose per-tick hashes.
  It must not use ENet; transport is tested separately.

- [ ] **Step 2: Write `test_multiplayer_sim`.** Run two and then four instances
  for 3600 ticks; compare hashes every tick; set one instance's `user_paused`
  and prove hashes stay equal; assert all queue drop counters remain zero.

- [ ] **Step 3: Expand structural determinism tests** to reject variable deltas,
  clocks, `Input.` outside `_poll_local_input`, `get_connections()`, connection
  state either below the world guard or in input application, unseeded tick
  RNGs, and dictionary iteration in hashed simulation paths without an explicit
  stable order.

- [ ] **Step 4: Add the suite; run `tools/run_tests.sh --fast`; expect all
  green after harness fixes.** Any divergence is a source bug, not a tolerance
  problem; print the first tick and first differing manifest field.

- [ ] **Step 5: Measure the provisional perf gate.** Four slots at full leash,
  four flow fields, cap populations, worst-case loadouts, and `_state_hash()`
  every 60 ticks. Record normalised p95 against the existing 11 ms budget; this
  is diagnostic evidence, not a release pass.

- [ ] **Step 6: If the provisional fixture exceeds 11 ms, profile and optimise
  the implementation without weakening the fixture.** Re-run the full
  `tools/run_tests.sh` until the unchanged worst-case gate passes. No feature,
  population, workload, or budget reduction is accepted as the fix.

- [ ] **Step 7: Commit:** `test: prove four-slot deterministic simulation`

---

## Task 11: Implement the packet codec and ENet transport

**Files:**
- Create: `scripts/net/protocol.gd`
- Create: `scripts/net/transport.gd`
- Create: `tests/test_transport_loopback.gd`
- Modify: `scripts/net/network_session.gd`
- Modify: `data/session_rules.gd`
- Modify: `tools/run_tests.sh`

**Interfaces:**

```gdscript
# protocol.gd
enum Message { HELLO, WELCOME, START, INPUT, RELAY, CHECKSUM, RESYNC,
  SNAPSHOT, ABSENT, PRESENT, LEAVE, END_CANDIDATE, END_CHECK, END }
static func encode_control(kind: int, body: Dictionary) -> PackedByteArray
static func decode_control(bytes: PackedByteArray, context: Dictionary) -> Dictionary
# INPUT has a 20-byte fixed body: move (two float32), card, target, and offer
# (three int32). The tick and declared body length live in the common validated
# envelope; RELAY has a fixed header plus records.
static func encode_input(tick: int, move: Vector2, card: int,
    target: int, offer: int) -> PackedByteArray

# transport.gd
class_name Transport extends Node
func host(port: int, session: NetworkSession) -> Error
func join(address: String, port: int, session: NetworkSession) -> Error
func send_input(tick: int, move: Vector2, card: int,
    target: int, offer: int) -> void
func flush_relay(tick: int, moves: PackedVector2Array,
    cards: PackedInt32Array, targets: PackedInt32Array,
    offers: PackedInt32Array, checksums: PackedInt64Array) -> void
func send_control(kind: int, body: Dictionary, peer: int = 0) -> void
func send_snapshot(peer: int, bytes: PackedByteArray) -> void
func drain_into(session: NetworkSession) -> void
func poll() -> void
func close() -> void
```

- [ ] **Step 1: Write the transport-only half of `test_transport_loopback`**
  using real `ENetMultiplayerPeer` instances on loopback. Cover two user
  channels on both ends; reliable ordered INPUT/RELAY; three withheld poll
  intervals delivered in order; a full-size channel-1 snapshot not delaying
  channel-0 input; 3-second timeout; one relay bundle per peer per tick;
  malformed packet count; protocol/session mismatch; and distinct input,
  retained-report, and announced-boundary tick windows. Task 12 adds the
  START-frozen-roster refusal case.

- [ ] **Step 2: Add the suite and run `tools/run_tests.sh --fast`; expect it to
  fail.**

- [ ] **Step 3: Implement the pure codec.** Include declared body length,
  protocol version, message enum, and session id in the envelope. Validate the
  envelope before reading body fields. Enforce `SNAPSHOT_MAX`, name/address
  limits, slot range, and message-specific tick windows. Return explicit decode
  failure without owning peer counters or connections.

- [ ] **Step 4: Implement ENet creation, channels, and failure policy.** Use
  `create_server(port, 3, 2)` / `create_client(address, port, 2)`, raw
  `put_packet` / `get_packet`, reliable ordered channel 0 for control/input,
  unreliable channel 0 for periodic checksums, and reliable channel 1 for
  snapshots. Apply the 3-second timeout to each packet peer. `Transport` counts
  every codec/validation failure and disconnects a peer at `BAD_PACKETS := 20`.

- [ ] **Step 5: Bundle host relay once per peer per tick.** Do not forward each
  INPUT on receipt. Include all available slot records for that tick and queued
  periodic checksums.

- [ ] **Step 6: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 7: Commit:** `feat: add validated ENet input transport`

---

## Task 12: Wire lobby, handshake, and live lockstep input

**Files:**
- Modify: `scripts/meta/meta_screen.gd`
- Modify: `scripts/meta/save_game.gd`
- Modify: `scripts/run/run.gd`
- Modify: `scripts/run/ui.gd`
- Modify: `scripts/net/network_session.gd`
- Modify: `scripts/net/transport.gd`
- Modify: `tests/test_meta_layout.gd`
- Modify: `tests/test_input.gd`
- Modify: `tests/test_transport_loopback.gd`
- Modify: `project.godot` only if a new explicit lobby action is needed

- [ ] **Step 1: Add the remaining lobby/handshake tests.** Host owns slot zero;
  first remote HELLO gets the lowest free slot; WELCOME refreshes the ordered
  roster; pre-START leave frees a slot; START freezes protocol/session/seed/
  delay/timeout/roster; a new participant after START and mismatched reconnect
  data are refused; solo builds the same shape locally with delay zero.

- [ ] **Step 2: Add hostile-safe string prefs.** Extend SaveGame with separate
  string validation for display name and last address: container guard, maximum
  lengths, explicit printable/hostname character whitelists, defaults, and
  write-side sanitation. Do not push strings through numeric `PREF_RANGES`.

- [ ] **Step 3: Build the lobby in `meta_screen.gd`.** Add Host, Join, address,
  display name, ordered player list, Start, and status. Preserve access to the
  shop and settings. Host Start is disabled until transport is ready. Update
  `test_meta_layout` for 1280×720 and smaller supported viewport bounds.

- [ ] **Step 4: Transfer the live session into the run without reconnecting.**
  Instantiate `run.tscn`, configure it with `NetworkSession` and the existing
  `Transport` before `_ready`, reparent the transport under the run, then replace
  the current scene. A client does the same on START. Solo passes no transport.

- [ ] **Step 5: Integrate the tick in this exact order:** snapshot render past;
  poll local device into a future record; poll/drain transport; submit/relay;
  run presentation; if `lockstep.ready(executed)`, take one tick, apply input
  records/choices, then either hold world state or step fixed simulation.
  On START call `lockstep.prime(0, delay - 1)` before tick zero can be consumed.
  Nothing below the world guard inspects Transport or role.

- [ ] **Step 6: Emit periodic checksums and stall notices.** Every 60 consumed
  ticks, queue `_state_hash`. When readiness is false, keep presentation and
  network polling alive; after 20 missed physics callbacks expose missing slot
  ids for HUD text.

- [ ] **Step 7: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 8: Commit:** `feat: connect the lobby to live lockstep play`

---

## Task 13: Implement future-boundary desync recovery

**Files:**
- Create: `tests/test_recovery.gd`
- Modify: `scripts/net/network_session.gd`
- Modify: `scripts/net/transport.gd`
- Modify: `scripts/run/run.gd`
- Modify: `scripts/run/ui.gd`
- Modify: `tools/run_tests.sh`

- [ ] **Step 1: Write `test_recovery`.** Corrupt one of three instances; detect
  the first mismatching periodic checksum; host announces
  `R >= host_tick + delay + 3`; all correct peers execute through R and continue
  until back-pressure; host waits until its ring holds every required record
  through `R + delay`; snapshot describes state after R; corrupt peer restores
  and resumes at `R + 1`; merged records preserve what it already broadcast;
  all reach `R + delay + 1` and hashes agree. Repeat divergence three times and
  assert the third terminates the session with all offending tick numbers.

- [ ] **Step 2: Add the suite and run `tools/run_tests.sh --fast`; expect it to
  fail.**

- [ ] **Step 3: Add recovery control state to `NetworkSession`.** Track active
  announced boundary, expected snapshot peers, reports, and the session-wide
  desync count plus offending tick list. Only one RESYNC boundary may execute
  at once; queue a later authority repair instead of overwriting it. END_CHECK
  is a separate barrier, and Task 15's flagged reconnect RESYNC may explicitly
  supersede a no-LIVE END_CHECK. Terminate after the third mismatch.

- [ ] **Step 4: Implement host recovery.** Announce reliable RESYNC; continue
  simulating; serialize exactly once when the full ring window exists; send a
  snapshot only to mismatching peers. Correct peers never restore or rewind.

- [ ] **Step 5: Implement client recovery with one transport-owned pre-restore
  buffer.** Between RESYNC/HELLO and snapshot application, `Transport` validates
  record ticks against `NetworkSession`'s announced boundary and retains
  accepted INPUT/RELAY records keyed by absolute tick instead of submitting
  them to a stale ring. Keep boundary-valid traffic out of bad-packet counts.
  After transactional restore establishes the snapshot ring, merge both its
  future window and the buffered records without overwriting either, then
  resume naturally. `NetworkSession` owns the boundary; `Transport` alone owns
  this packet-arrival buffer.

- [ ] **Step 6: Surface `resynchronising…` in HUD without adding it to simulation
  state.**

- [ ] **Step 7: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 8: Commit:** `feat: recover divergent peers at future boundaries`

---

## Task 14: Confirm endings through every PRESENT peer

**Files:**
- Create: `tests/test_ending.gd`
- Modify: `scripts/net/network_session.gd`
- Modify: `scripts/net/transport.gd`
- Modify: `scripts/run/run.gd`
- Modify: `scripts/run/ui.gd`
- Modify: `tools/run_tests.sh`

- [ ] **Step 1: Write `test_ending`.** Cover: false local death while host still
  sees LIVE; neutral records preserve host liveness; correct last death on a
  non-checksum tick; DEAD spectators included in END_CHECK; ABSENT excluded;
  each peer's ending report is reliable channel 0; only host END emits
  `run_ended`; divergent-client-terminal/host-nonterminal recovery and resume;
  host-terminal/client-nonterminal recovery then a second agreeing check;
  campaign win; no remote PRESENT peer confirming immediately.

- [ ] **Step 2: Add the suite and run `tools/run_tests.sh --fast`; expect it to
  fail.**

- [ ] **Step 3: Separate terminal candidate, hold, and final ending.** `_die(slot)`
  marks only that slot DEAD and resolves/banks it. A local DEAD slot or any
  unconfirmed terminal hold samples no gameplay choice and submits neutral
  movement/no-choice records. `won` or no LIVE holds the world below the guard
  but keeps lockstep/network/input consumption above it. No local path emits
  `run_ended` in a session.

- [ ] **Step 4: Implement reliable END_CANDIDATE / END_CHECK / END.** Host picks
  `C >= host_tick + delay + 3`. Every PRESENT peer sends its
  `(C, _state_hash(), outcome-or-NONE)` report reliably on channel 0. This task
  owns the roster rule: DEAD remains PRESENT and contributes; ABSENT does not.
  Host compares that whole roster. Solo or host without remote PRESENT peers
  confirms on the candidate tick.

- [ ] **Step 5: On mismatch, schedule a fresh future RESYNC.** Never attempt to
  restore a past END_CHECK tick. Nonterminal host repairs false-ending clients
  and resumes; terminal host repairs clients, then starts another END_CHECK.
  Reuse recovery's session-wide desync counter: after the third failed check,
  terminate with all three offending tick numbers in the diagnostic.

- [ ] **Step 6: Expose one narrow no-LIVE cancellation operation** for the later
  reconnect task. It may clear a no-LIVE barrier and its collected reports but
  must reject campaign-win barriers. Same-channel ordering requires flagged
  RESYNC before any later ending control.

- [ ] **Step 7: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 8: Commit:** `feat: make network endings host-confirmed barriers`

---

## Task 15: Park missing peers and reconnect both life states

**Files:**
- Create: `tests/test_parking.gd`
- Create: `tests/test_reconnect.gd`
- Modify: `scripts/net/network_session.gd`
- Modify: `scripts/net/transport.gd`
- Modify: `scripts/run/run.gd`
- Modify: `scripts/run/ui.gd`
- Modify: `tools/run_tests.sh`

- [ ] **Step 1: Write `test_parking`.** Withhold one slot; host parks it at the
  first missing tick after timeout/LEAVE; broadcasts ABSENT; resolves its open
  offer to the first card; banks its incremental progress once; run continues;
  raw old-peer traffic without HELLO is disconnected; a pre-START leave remains
  a lobby removal instead. Also assert host transport loss ends the run at the
  observed tick with no migration, while a client treats host silence or
  disconnect as stop-and-HELLO for its original slot.

- [ ] **Step 2: Write the complete `test_reconnect` matrix.** Include the LIVE
  path after subnet advance, ring priming, crossing an already-open gate, and
  channel-0 RELAY records **and `PRESENT`** arriving before the channel-1
  snapshot. Assert both are buffered, survive restore, and apply only after the
  matching snapshot commits, with the first record applying at `tick + 1`.
  Include a DEAD → ABSENT → PRESENT return that stays DEAD, remains outside the
  LIVE required mask, leaves the ending check active, and still contributes to
  that check. Also cover no-LIVE acceptance before any candidate, multiple ticks
  of latch suppression, delayed candidates at `T - 1` and `T`, campaign-win not
  suppressed, an existing no-LIVE barrier cleared by flagged RESYNC, reconnect
  abort re-evaluation, and no END emitted during a successful LIVE return.

- [ ] **Step 3: Add both suites and run `tools/run_tests.sh --fast`; expect them
  to fail.**

- [ ] **Step 4: Implement parking and drop policy.** Save parked health
  separately before `slot_state` becomes ABSENT. Remove from Lockstep's LIVE
  required mask and ending PRESENT roster as specified; keep immutable roster
  identity and counters for reconnect. Resolve the parked offer immediately.
  Never write a remote slot into the host's `SaveGame`; each process persists
  only its local slot's already-derived bank delta. A host drop terminates
  clients; there is no host migration. A client drop stops local simulation
  and begins HELLO retry for its original slot.

- [ ] **Step 5: Implement reconnect acceptance.** Only original protocol,
  session id, and slot before END. Re-send the immutable descriptor. Choose a
  future boundary and arm Task 13's transport-owned pre-restore buffer before
  adding the new peer to the relay set. Buffer both future RELAY records and an
  early channel-0 `PRESENT`; release neither until the matching channel-1
  snapshot is validated and committed. Add the peer to the relay set in the same
  frame the snapshot is serialised, prime neutral records through
  `tick + delay`, and announce PRESENT after tick consumption.

- [ ] **Step 6: Restore life from parked health.** Positive health places at
  `terrain.nearest_open(nearest LIVE position)` or current arena centre when no
  LIVE anchor exists, marks LIVE, and requires records from `tick + 1`. Zero
  health returns DEAD, never enters the required mask, leaves any ending check
  active, and remains in its PRESENT report roster.

- [ ] **Step 7: Implement `pending_live_return` in `NetworkSession`.** Set the
  host-only latch whenever a positive-health return is accepted with no LIVE
  slots, even before a no-LIVE candidate exists. Reject no-LIVE candidates while
  latched; do not reject campaign win. Flag RESYNC only when clearing an
  existing no-LIVE barrier. `PRESENT(T)` clears the latch and makes candidates
  through T stale. Abort clears the latch and immediately reevaluates no-LIVE.

- [ ] **Step 8: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 9: Commit:** `feat: park and reconnect original player slots`

---

## Task 16: Finish co-op presentation, spectating, and notices

**Files:**
- Modify: `scripts/run/run.gd`
- Modify: `scripts/run/ui.gd`
- Modify: `shaders/glyph.gdshader` only if the existing instance channels cannot carry teammate hue
- Modify: `tests/test_hud.gd`
- Modify: `tests/test_input.gd`
- Modify: `tests/test_draw_order.gd`
- Modify: `tests/test_interpolation.gd`
- Modify: `tools/screenshot.gd`
- Modify: relevant `tools/shot_*.gd`

- [ ] **Step 1: Add failing presentation tests.** Every LIVE player is drawn;
  local player keeps the current hue; teammates have a distinct deterministic
  hue and name tag; ABSENT is dimmed; DEAD is not drawn; local camera follows
  local render position while LIVE and the selected spectate target while DEAD;
  confirm cycles LIVE targets; local pause in a session sends zero movement but
  does not stop hashes.

- [ ] **Step 2: Add one fixed-cap player renderer.** Reuse packed instance data
  and interpolation arrays. Do not add Player nodes or `Area2D`. Name tags may
  be pooled Labels updated at display rate; cap is four.

- [ ] **Step 3: Add spectate state as presentation-only.** It is not hashed or
  snapshotted. On target death/absence, choose the next LIVE slot in ascending
  order. Camera and local draw culling use the spectate target; simulation
  targeting does not.

- [ ] **Step 4: Extend HUD.** Keep local status/build/tally blocks; add a compact
  teammate strip with name, integrity/state, plus stall/resync/leash notices.
  Card overlay shows only local contents and unresolved teammate count.

- [ ] **Step 5: Finish input routing.** Task 8 already made session
  `user_paused` a local overlay that submits neutral movement without stopping
  hashes; keep solo pause gating unchanged. Here, bind `confirm` to spectator
  cycling only when no modal offer owns it.

- [ ] **Step 6: Run `tools/run_tests.sh --fast`; expect all green.**

- [ ] **Step 7: Run the game in two local windows and verify:** teammate hue is
  visibly distinct and names match the descriptor; LIVE camera stays local;
  DEAD `confirm` cycles LIVE slots; waiting counts decrement as choices land;
  stall/resync/reconnect notices appear for their state and clear afterward;
  and attempted separation stops at the 4000-unit leash.

- [ ] **Step 8: Commit:** `feat: present teammates and spectator state`

---

## Task 17: Final migration audit, documentation, and release verification

**Files:**
- Modify: `CLAUDE.md`
- Create: `tools/determinism_probe.gd`
- Modify: generated `codemaps/*.md` through the codemap generator, not by hand
- Modify: `tools/run_tests.sh` only if suite ordering/count is wrong
- Modify: `docs/superpowers/specs/2026-09-01-online-coop-design.md` only for an implementation-discovered contract correction approved by the user

- [ ] **Step 1: Run structural audits.** Confirm no scalar-player aliases,
  `Engine.time_scale`, tick clocks, tick `dt`, `get_connections()`, direct
  `resolved[...]` ownership bypass, negative gid division, simulation
  connection branches, object-decoding snapshots, RPC, synchronizers,
  spawners, `Area2D`, image assets, or font files entered the implementation.

- [ ] **Step 2: Audit protocol/state coverage.** Every message kind has codec,
  validation, channel, and test coverage. Every simulation `var` in the nine
  manifest files is classified exactly once. Every STATE_FIELDS flag has a real
  consumer. Every restore-derived field has one reconstruction rule.

- [ ] **Step 3: Audit plurality against the site table in Task 7.** Search the
  final `player_pos` / `player_vel` / health / loadout / resolved callsites and
  account for each as nearest LIVE, target, every LIVE, owner, sum, cycle, all
  past gate, block holder, flow field, or local presentation. No unclassified
  site ships.

- [ ] **Step 4: Count `SUITES` from `tools/run_tests.sh` and update `CLAUDE.md`
  with the actual number.** The expected count is 50 fast suites plus the perf
  gate (51 total) if no suite was merged or added during implementation.

- [ ] **Step 5: Regenerate codemaps** with the `update-codemaps` skill. Do not
  hand-edit generated maps.

- [ ] **Step 6: Run `tools/run_tests.sh --fast`; require all suites green with
  no script errors.**

- [ ] **Step 7: Run full `tools/run_tests.sh`; require the unchanged four-slot
  worst-case perf gate to PASS.** If it fails, profile and optimise the
  implementation without reducing population, workload, features, or the 11 ms
  budget, then rerun it. If it is INCONCLUSIVE, rerun once on a quiet machine;
  a second INCONCLUSIVE is a failed release gate, not passing evidence.

- [ ] **Step 8: Run four real local clients over ENet.** Host three peers, start,
  move all four players, hold the full leash, complete one shared offer, kill
  one slot and spectate, disconnect and reconnect it, then end the run. Observe
  ordered input, no permanent stall, correct return placement, and one
  host-confirmed end screen.

- [ ] **Step 9: Run the ten migrated windowed shot tools.** Each must exit zero
  and write its expected nonempty PNG; inspect the player/camera, cards, gate,
  collapse, props, seam, slots, and FX captures. Never use `--headless`.

- [ ] **Step 10: Run the retained full-manifest determinism probe on arm64 and
  x86_64.** `tools/determinism_probe.gd` uses the same descriptor and 600-enemy
  cap and prints per-tick `_state_hash()` values. Provision both Godot
  architecture binaries before this checkpoint and require byte-identical
  output; missing architecture support blocks completion. Keep the probe so
  the claim remains reproducible.

- [ ] **Step 11: Run `git diff --check` and inspect the final diff by subsystem.**

- [ ] **Step 12: Commit:** `docs: record the online co-op architecture`

## Dependency order

```text
fixed tick
  -> session descriptor + seeded streams
  -> deterministic prerequisites
  -> lockstep ring
  -> grid/leash/corridor primitives
  -> slot-indexed solo cutover
  -> plurality census
  -> deterministic offers
  -> state manifest/snapshots
  -> multiplayer determinism + perf proof
  -> packet codec + ENet
  -> lobby/live input
  -> recovery
  -> ending barrier
  -> parking/reconnect
  -> presentation
  -> final audit
```

Do not parallelise Tasks 1–10: each changes the state shape consumed by the next.
After Task 12, recovery, ending, and reconnect remain protocol-dependent and
must still land in order. Visual presentation is last so it targets the final
slot/session APIs rather than being rewritten repeatedly.
