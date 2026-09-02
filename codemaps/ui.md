> Generated: 2026-09-02 | Token-lean format for LLM context

# UI, rendering and tooling

No font files and no image assets: text is Godot's default mono, entities are
procedural shader glyphs, and everything else is `_draw` calls.

## `scripts/run/ui.gd` (952) — `CanvasLayer`, the run HUD and its screens

```gdscript
FG   = Color(0.55, 1.00, 0.72)   # green
DIM  = Color(0.35, 0.62, 0.48)
WARN = Color(1.00, 0.45, 0.42)
```

`bind(run)` wires the run signals: `level_up_offered → _on_cards`,
`fusion_offered → _on_fusion`, `offer_waiting → _on_waiting`,
`run_ended → _on_end`, `stats_changed → _refresh`. The HUD renders the LOCAL
slot; everyone else is a strip.

| State | Meaning |
|---|---|
| `_hud`, `_overlay`, `_end`, `_pause_panel`, `_settings`, `_recipes`, `_vignette` | the screens and overlays |
| `_cards: Array` | the card `PanelContainer`s, so the **selected card** can be lit — the card is the module; a row is only where it goes |
| `_nav: Array` | per card, **enabled rows only** — indexing enabled-only rows is what makes Enter always do something |
| `_col`, `_row`, `_on_decline` | keyboard cursor |

Build/refresh: `_build`, `_refresh`, `_build_lines`, `_mono(size)`,
`_panel(color, width)`, `_bar(fraction, width)`, `_spacer`, `_stats_line(m)`.

### The HUD is four blocks, not one line

`Status` (left), `Centre`, `Tally` (right), `Build` (bottom-left) — all indexed
by `get_node(name)` with **no `.get`**, so a rename is a crash inside `_refresh`
that the runner only surfaces as a bare `SCRIPT ERROR`. `test_hud` is the only
guard on those names; before it, nothing tested the HUD at all.

| Block | Carries |
|---|---|
| `Status` | integrity + bar, armor, def, level + XP bar. Warn colour is PROPORTIONAL (<30%), not a fixed threshold |
| `Centre` | subnet, timer, and the phase banner on its own line |
| `Tally` | salvage, botnet, kills, flips; then the notices — `waiting for input: …` after `STALL_NOTICE` ticks, `resynchronising…`, `reconnecting… (attempt n of 10)` — and `_teammate_strip`: one line per other roster slot (name + integrity bar, `down`, `away`), `spectating X — confirm cycles` once the local slot is not LIVE, `at the leash: …` |
| `Build` | one line per exploit, shared with the run summary via `_build_lines` |

The mini-boss banner is gated on `not run.is_arriving(i)` — the entity exists
for the whole 0.9 s charge, and naming it then spoils the entrance.

`_on_end` is a run summary: outcome, subnet, time, level, kills, flips, salvage
and the final build, tolerating a run that ended holding fewer than three
exploits.

### The level-up card
One card per offered module; **one button per exploit row**, all terminal —
pressing it places the module. The column is fixed by the module's slot type, so
column + row is the entire placement, which collapses the old
module-then-slot pair of clicks into one.

```gdscript
COLUMN_NAMES = ["VECTOR", "TRIGGER", "PAYLOAD"]
RANK    = Color(1.00, 0.86, 0.35)   # ^ rank up
NEW_ROW = Color(0.45, 0.72, 1.00)   # * found a new exploit row
OFF     = Color(0.18, 0.26, 0.22)
```
Marks: `^` rank up, `+` fill an empty slot, `x` replace the occupant,
`*` found a new row. `_column_marks(slot)`, `_row_button(m, e, target)`,
`_make_card(entry, out_buttons)`, `_show_cards`, `_reset_selection`.
A `null` target means the row is no legal home — after the column is fixed that
can only be a max-rank duplicate or the last interval trigger, both named rather
than greyed out silently. Any card can be declined for salvage. Every button only STAGES a choice
(`run.choose_card` etc. set `_local_choice`); it lands when the tick consumes
the record, and `_on_waiting(n)` keeps the overlay up with "waiting for N…"
until every teammate's has.

### Input — ACTIONS, not keycodes
`_input(e)` matches InputMap actions. An `InputEventJoypadButton` has no
keycode, so while this matched raw keycodes a controller player could walk and
pause but never operate the level-up overlay. `tools/shot_cards.gd` drives
`ui._input` too and is **not** in `SUITES` — `test_input` asserts its action
names exist.

Actions: `move_*`, `confirm`, `cancel`, `pause`, `recipes`, `restart`
(deadzone 0.2). `recipes` and `restart` share R, disambiguated by screen.

With no overlay up, `confirm` → `run.cycle_spectate()`: a DEAD local slot
looks through the next LIVE slot.

`_move_row(±1)`, `_move_card(±1)`, `_activate`, `_toggle_recipes`,
`_route_cancel`, `_toggle_pause`, `_abandon`, `_on_settings_closed`,
`highlighted()`, `card_row()`, `decline_button()`.

**`cancel` has five arms**, not two: settings → recipe panel → card/fusion
overlay → end screen → otherwise pause. The recipe panel is a CHILD of
`_overlay` and `_end` is a SIBLING of it, so a two-arm rule declined the card
under the panel and paused a finished run. The overlay arm keys off
`run.paused`, not `_overlay.visible`, which lags it by a frame.

**Player pause is `run.user_paused`, never `run.paused`.** The latter means "a
modal offer is open" and four sites clear it unconditionally; sharing it would
let a card decline release a pause it never took and strand a pending fusion.
`_refresh` runs while `user_paused` or the panel draws over a frozen HUD.

## `scripts/meta/settings_panel.gd` (133) — `Control`, shared prefs UI

An OVERLAY, reached from the shell and the pause panel. Rows: master / sfx /
music volume, screen shake, damage numbers. Every write goes through
`SaveGame.set_pref`, which clamps and rejects non-finite — one table, both
directions. `apply()` pushes volumes at the buses.

It is an overlay, and its shell entry button sits BESIDE `./intrude`, because
the shop column already ran to ~505 px in a 720 px viewport — which is exactly
what `test_meta_layout` measures.

## `scripts/meta/meta_screen.gd` (469) — `Control`, the shop and the lobby

The LINK column (`_build_link`, x = 780): handle and address fields
(`SaveGame` string prefs), Host / Join / Leave, the player list, a status
line. `_host` binds `Transport.host(DEFAULT_PORT)`; `_join` dials
`last_address`; `_process` polls the transport and drains `session.inbox`
into `_handle` (HELLO → `admit` + WELCOME to all; WELCOME/START on a client;
LEAVE frees a slot before START). `_start` freezes the descriptor and sends
START; `_launch_session` REPARENTS the transport under the run
(`configure_session`, `attach_transport`) — the same ENet peers carry the
lobby and the game. Solo `./intrude` builds the one-slot descriptor.

`UNLOCK_ROWS = 2` still-locked modules listed before the rest is summarised.
`FG`, `DIM`, `HOT = Color(1.0, 0.72, 0.35)`.

```gdscript
BUFFS = [                      # [id, label, effect text]
  cpu_cycles  "+CPU cycles"  "attack x1.04 per rank"
  cooling     "+cooling"     "attack speed x0.97 per rank"
  memory      "+memory"      "integrity +8 per rank"
  firewall    "+firewall"    "armor +0.6 per rank"
  encryption  "+encryption"  "defense +6 per rank"
  bus_speed   "+bus speed"   "move speed +6 per rank"
  addressing  "+addressing"  "range x1.03 per rank"
  bandwidth   "+bandwidth"   "pickup radius +6 per rank"
]
```
**Every id here must exist in `SaveGame._default()["buffs"]`** — `_refresh`
indexes `d["buffs"][id]` directly with no `.get`, so a missing name crashes the
shop on open. Requirement text comes from `SaveGame.milestone_text`, not a second
copy of the numbers.
`_ready`, `_refresh`, `_label`, `_spacer(h)`, `_pips(n)`, `_buy(id)`, `_start()`,
`_input(e)`. Layout is size-gated by `tests/test_meta_layout.gd`.

## `shaders/glyph.gdshader` — procedural silhouettes

`shader_type canvas_item`. `INSTANCE_CUSTOM.r` carries the glyph index into a
`varying flat float glyph`; 14 branches, one per glyph (indices 0–13 map to the
`glyph` column of `EnemyTable`). `ring(d, radius, width)` is the shared helper.
Distinct outlines are readability, not decoration: 600 identical squares say
nothing about what is closing on you.

## `scripts/run/backdrop.gd` (111) — `Node2D`, the arena shell

Draws the isometric floor lattice and the arena walls under everything.
`STEP = Terrain.TILE`, `DEPTH = 30.0`.
Colors: `LINE`, `EDGE`, `GLOW`, `FACE_NEAR` (y=ymax, lit), `FACE_SIDE` (x=xmax,
turned away), `RIB`. Functions: `_draw`, `_arena(rect)`, `_slab(o, size, nx, ny)`,
`_wall(o, size, inset, color, width)`.

## `scripts/run/props.gd` (222) — `Node2D`, walls that stand over the swarm

Extruded boxes so walls read as solid and can be seen through:
`WALL_HEIGHT 26.0`, `POST_HEIGHT 78.0`, `FACE_ALPHA 0.6`,
`BACK_EDGE_SCALE 0.35`. Two palettes — `WALL_TOP/NEAR/SIDE/EDGE` and
`RAIL_TOP/NEAR/SIDE/EDGE`. `draw_box(rect, height, top, near, side, edge, drop)` is the
shared primitive; `_draw` walks `terrain.rects`.

**Walls fall with the floor.** `PROP_GRAVITY 900.0`, `PROP_FALL_LIFE 2.2`.
`_floor_gone` checks EVERY cell under the rect, not its centre, so a wall
spanning the collapse frontier stands until the last of its footing goes — which
is also what stops a whole row dropping in one frame. Fall timers are keyed by
rect index and cleared when a new subnet empties `terrain.voided`, or walls drop
in an arena the player has not reached. The clock is unscaled: a hitstop must
not hold a collapsing wall in mid-air.

## Players and the view in `run.gd`

`player_draw_list()` → `[slot, colour, alpha, name]`: every LIVE slot, the
local one unnamed in `TEAM_HUES[0]` (the solo hue), teammates in
`slot_hue(s)` under a name tag (`ThemeDB.fallback_font`), an ABSENT slot at
`ABSENT_ALPHA 0.35` where it parked, a DEAD slot skipped. `view_slot`
(`_refresh_view` each frame, `cycle_spectate`) is the local slot while LIVE,
else the spectate target; the camera, `_visible_world_rect` and
`_depth_sort` follow it. Presentation only: never hashed. Gated by
`test_draw_order`, `test_hud`, `test_input`.

## Rendering in `run.gd`

Four `MultiMeshInstance2D` (`_mm_enemy _mm_proj _mm_shard _mm_botnet`) built by
`_make_mm(size, z)` / `_build_renderers`, primed by `_prime_constant_instances`.
`_update_renderers` writes transforms + `INSTANCE_CUSTOM`; `_depth_sort` buckets
into `DEPTH_BANDS = 192` for painter's order (`_order`, `_band_count`).
`PROPS_Z = 8`. `_draw` adds ground quads (`_ground_quad`), the voided ground
(`_void_runs`), **falling floor chunks** (`_draw_chunk`), the lit route
(`_route_points`), boss integrity rings, arrival animations, telegraphs, damage
numbers and the transient fx. Draw order is gated by `tests/test_draw_order.gd`.

Enemy instance colour composes the corruption tint with `_hit_flash` (toward
white) and, for an arriving boss, a scale ramp read from `_arriving`
INDEPENDENTLY of the grid skip union — the renderer tests `_submerged` directly,
so without its own read a boss draws full-size through its whole charge.

**Boss integrity is drawn, not counted**: the ring THINS, walks from the type
colour toward hot red, and FRAGMENTS into fewer arcs (12 → 3). Three channels,
because any one alone is ambiguous at a glance.

## `tools/`

| File | Purpose |
|---|---|
| `run_tests.sh` | the runner — 52 suites + perf gate, fails on `SCRIPT ERROR`/`Parse Error` in stderr whatever a suite claims |
| `determinism_probe.gd` | four-slot run at the enemy cap, `tick hash` per tick; diff its output across arm64 / x86_64 |
| `screenshot.gd` | shared capture harness — needs a WINDOW; `--headless` has no texture and every shot tool exits 1 |
| `shot_cards` | drives `ui._input` with ACTION events; not in `SUITES`, so only `test_input` guards its action names |
| `shot_collapse shot_fx shot_gate shot_iso shot_meta shot_props shot_seam shot_slots` | one-scene screenshot scripts |
| `fps_probe.gd`, `fps_collapse.gd` | interactive frame-time probes (the gate lives in `tests/perf_milestone0.gd`) |
| `build_manual.py` + `manual_template.html` | generates `site/index.html` |
