> Generated: 2026-08-31 | Token-lean format for LLM context

# UI, rendering and tooling

No font files and no image assets: text is Godot's default mono, entities are
procedural shader glyphs, and everything else is `_draw` calls.

## `scripts/run/ui.gd` (529) — `CanvasLayer`, the run HUD and level-up cards

```gdscript
FG   = Color(0.55, 1.00, 0.72)   # green
DIM  = Color(0.35, 0.62, 0.48)
WARN = Color(1.00, 0.45, 0.42)
```

`bind(run)` wires the three run signals: `level_up_offered → _on_cards`,
`run_ended → _on_end`, `stats_changed → _refresh`.

| State | Meaning |
|---|---|
| `_hud`, `_overlay`, `_end` | the three screens |
| `_cards: Array` | the card `PanelContainer`s, so the **selected card** can be lit — the card is the module; a row is only where it goes |
| `_nav: Array` | per card, **enabled rows only** — indexing enabled-only rows is what makes Enter always do something |
| `_col`, `_row`, `_on_decline` | keyboard cursor |

Build/refresh: `_build`, `_refresh`, `_mono(size)`, `_panel(color, width)`,
`_bar(fraction, width)`, `_spacer`, `_stats_line(m)`.

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
than greyed out silently. Any card can be declined for salvage.

### Keyboard navigation
`_input(e)`, `_move_row(±1)`, `_move_card(±1)`, `_activate`, `_hover(card, row)`,
`_hover_decline`, `_apply_highlight`, `_mark(button, on)`, `highlighted()`,
`card_row()`, `decline_button()`. Arrows and WASD; covered by
`tests/test_cards_keyboard.gd`.

## `scripts/meta/meta_screen.gd` (165) — `Control`, the shop (main scene)

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

## `scripts/run/props.gd` (130) — `Node2D`, walls that stand over the swarm

Extruded boxes so walls read as solid and can be seen through:
`WALL_HEIGHT 26.0`, `POST_HEIGHT 78.0`, `FACE_ALPHA 0.6`,
`BACK_EDGE_SCALE 0.35`. Two palettes — `WALL_TOP/NEAR/SIDE/EDGE` and
`RAIL_TOP/NEAR/SIDE/EDGE`. `draw_box(rect, height, top, near, side, …)` is the
shared primitive; `_draw` walks `terrain.rects`.

## Rendering in `run.gd`

Four `MultiMeshInstance2D` (`_mm_enemy _mm_proj _mm_shard _mm_botnet`) built by
`_make_mm(size, z)` / `_build_renderers`, primed by `_prime_constant_instances`.
`_update_renderers` writes transforms + `INSTANCE_CUSTOM`; `_depth_sort` buckets
into `DEPTH_BANDS = 192` for painter's order (`_order`, `_band_count`).
`PROPS_Z = 8`. `_draw` adds ground quads (`_ground_quad`), the voided ground
(`_void_runs`), the lit route (`_route_points`) and the transient fx.
Draw order is gated by `tests/test_draw_order.gd`.

## `tools/`

| File | Purpose |
|---|---|
| `run_tests.sh` | the runner — 26 suites + perf gate, fails on `SCRIPT ERROR`/`Parse Error` in stderr whatever a suite claims |
| `screenshot.gd` | shared headless capture harness |
| `shot_cards shot_collapse shot_fx shot_gate shot_iso shot_meta shot_props shot_seam shot_slots` | one-scene screenshot scripts |
| `fps_probe.gd`, `fps_collapse.gd` | interactive frame-time probes (the gate lives in `tests/perf_milestone0.gd`) |
| `build_manual.py` + `manual_template.html` | generates `site/index.html` |
