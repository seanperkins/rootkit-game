> Generated: 2026-09-05 | Token-lean format for LLM context

# UI, rendering and tooling

No image assets or font files. Controls use shared terminal chrome; world
geometry is procedural. Presentation reads simulation state, never owns it.

## `scripts/run/ui.gd` — `CanvasLayer`, HUD and run screens

`bind(run)` builds the UI and connects `level_up_offered → _on_cards`,
`fusion_offered → _on_fusion`, `offer_waiting → _on_waiting`,
`run_ended → _on_end`, `stats_changed → _refresh`, plus the updater signal.

| State | Meaning |
|---|---|
| `_hud`, `_overlay`, `_end`, `_pause_panel`, `_settings`, `_recipes`, `_vignette` | HUD and modal layers |
| `_cards` | Module card panels; selection lights the card and its chosen row |
| `_nav` | Enabled buttons only, grouped by card |
| `_previews`, `_preview_labels` | Cached resolved comparisons aligned with `_nav`; one rich-text widget per module card |
| `_col`, `_row`, `_on_decline` | Selection within the grid or the shared decline button |
| `_nav_held`, `_nav_repeat_left` | Stick edge detection and held-navigation repeat |
| `_net_panel`, `_net_text`, `_net_shown` | Network diagnostics, separate from the FPS display |
| `pending_update` | Seeded from Updater availability, then set by `update_ready` |

### HUD blocks

Named children are looked up directly by `_refresh`; names are runtime contracts.
The health/build readouts use `run.local_slot`, not the spectated slot.

| Child | Contents |
|---|---|
| `Status`, `HealthValue` | Integrity/armor/defense/level with segmented health and XP gauges |
| `Centre`, `Clock`, `Alert` | Subnet and large timer; clock switches to escape countdown during collapse |
| `ObjectivePanel`, `Objective` | Program, active route, optional job direction/distance/progress |
| `Fps` | `Engine.get_frames_per_second()`; warning below 55; rendered FPS, not simulation tick rate |
| `Tally` | Salvage, botnet, local kills/flips, missing-input/recovery/reconnect notices, teammate strip |
| `Build` and five weapon panels | Vector/rank, modules, rearm/inert status, damage/cooldown; clipped labels retain full tooltips |
| `Version` | `BuildInfo.display_version()` and update availability |

Network panel: per-slot receive rates and stall attribution, packet/record
statistics and measured consumed-tick rate. Sampling uses presentation time;
none of its counters drives combat. `netinfo` toggles it in network sessions.

`_on_end` shows outcome, subnet, elapsed time, progression, rewards and final
build. The build summary walks the actual exploit list, not a fixed row count.

### Level-up cards and resolved previews

One card per offered module; its VECTOR/TRIGGER/PAYLOAD column is fixed.
Each of the `Loadout.MAX_EXPLOITS` rows is a placement button. Marks:
`^` rank up, `+` empty slot, `x` replacement, `*` new exploit.
Disabled rows name max rank, an id held elsewhere, the last auto-firing weapon,
or no room. `_nav` omits disabled rows.

```
_make_card(entry, out_buttons, out_previews)
  legal row → _preview_text(module, target)
    _clone_row(live) → apply hypothetical rank/placement to clone
    temporary Loadout {mult: live multipliers, exploits: [live, clone]}
    compile_all() → resolved before/after → formatted changed fields
  aligned caches → _apply_highlight() → selected card's RichTextLabel
button → run.choose_card(module, target) → staged INPUT → consumed tick
```

No preview writes the live loadout or duplicates compiler arithmetic.
Comparisons are compiled while constructing the offer, not every draw frame.
`TRIGGER_WORDS` follows `Module.TriggerKind`; `PREVIEW_FIELDS` selects readable
resolved stats, including shield capacity/rearm and replacement losses.
INTERVAL says `every`; event triggers say `at most every` because a cooldown
is a frequency ceiling, not a promise that an event will occur.

`PREVIEW_MAX_LINES = 9`, `PREVIEW_LINE_H = 17`: fixed-height scrolling region,
not truncated text. Minimum card height is
`121 + 41 * Loadout.MAX_EXPLOITS + PREVIEW_LINE_H * PREVIEW_MAX_LINES`.
Mouse wheel or `ui_page_up`/`ui_page_down` scroll; selection resets scroll to zero.
The shared decline stages +25 salvage; a null-module fallback stages +50.
`_on_waiting` keeps the offer visible until the round settles.

### Input and pause

`_input` uses actions, not raw keycodes: `move_*`, `confirm`, `cancel`,
`pause`, `recipes`, `restart`, `netinfo`, plus built-in preview paging actions.
`_move_card`, `_move_row`, `_activate`, `highlighted`, `card_row`,
`decline_button` implement the grid. Mouse hover shares its selection state.
Analog motion moves on the edge; repeat begins after 0.40 s, then every 0.16 s.
Without an offer, confirm can call `run.cycle_spectate()`.

`run.user_paused` belongs to the player menu; `run.paused` belongs to modal
offers. Solo user pause holds the world; a network pause is a local overlay.
Closing settings copies shake/damage-number preferences to the live run.

## `scripts/meta/settings_panel.gd` — shared `SettingsPanel`

Overlay used by menu and pause. Rows: master/SFX/music volume (step 0.1),
shake (0.25), damage numbers (1.0 toggle). `_nudge` calls
`SaveGame.set_pref`, saves and refreshes. `apply()` sets audio volumes;
`open`/`close` control visibility, with a `closed` signal.

## `scripts/meta/meta_screen.gd` — hub, upgrades, multiplayer

The hub has start new run, disabled continue run, multiplayer, upgrades,
settings and exit. `_pages` holds separate upgrades/multiplayer pages;
`_page_open == ""` means hub. Settings/update modal sit above either page.
There is no mid-run checkpoint behind the disabled continue entry.
`_program_select` is a native `OptionButton`; `_select_program` persists a
sanitised preference. Selection freezes while connected and the lobby shows
program choices. Native `ui_accept`/`ui_cancel` bind keyboard plus controller
A/B in `project.godot`; do not substitute manual `pressed` signals, which bypass
popup behavior. `_input` routes cancel to the top menu layer; activation is native.

Shop: bounded `ScrollContainer` (680×240) for eight upgrade rows; unlock
requirements use `SaveGame.milestone_text`, showing `UNLOCK_ROWS = 2` plus a
summary. Every `BUFFS` id must exist in `SaveGame`'s buff dictionary.

| Shop id | Effect per rank |
|---|---|
| `cpu_cycles` | attack ×1.04 |
| `cooling`, `bus_speed` | move speed +6 each |
| `memory` | integrity +8 |
| `firewall`, `encryption` | armor +0.6 / defense +6 |
| `addressing`, `bandwidth` | range ×1.03 / pickup radius +6 |

Multiplayer page: handle, room-code/address, host, host LAN, join, leave and
session start. The menu owns `NetworkSession` and `Transport` until START.
`_launch_session` configures the run, reparents the existing transport and
attaches it; lobby→run does not recreate the connection.

Version labels use `BuildInfo.display_version`; handshakes use
`BuildInfo.version`. `_on_update_ready` sets the shared availability flag and
menu modal. Choices are install now, install on quit, not now, or the
move-to-/Applications path for App Translocation. Updater survives scene swaps;
the run HUD shows availability without interrupting play with the menu modal.

### Route vote overlay

`route_offered` opens three cards with risk/reward and compiled-party build counts.
Votes stage `run.choose_route`; completed voters wait while lockstep continues.
The tally includes the multiplayer auto-vote deadline. Solo has no deadline.

## Shared chrome — `scripts/ui/`

`TerminalStyle` caches the theme/SystemFont. Font preference order:
SF Mono, Menlo, Consolas, DejaVu Sans Mono, monospace. `panel_style` and
`build_theme` provide consistent code-built controls.
`HudChrome` supplies framed panels and segmented health/XP instruments.
`CRTOverlay` is an autoload `CanvasLayer` at layer 100, above menu and run.
`shaders/damage_vignette.gdshader` shades screen edges behind the HUD.

## World rendering

| Source | Responsibility |
|---|---|
| `scripts/run/backdrop.gd` | Isometric lattice and arena shell; `STEP = Terrain.TILE`, slab depth 30 |
| `scripts/run/props.gd` | Walls, rails, gate posts/lintel and objective block; `draw_box` primitive; wall height 26, post height 78, face alpha 0.6 |
| `scripts/run/run.gd` | `_build_renderers`, `_update_renderers`, `_depth_sort`, procedural effects and world draw |
| `shaders/glyph.gdshader` | Procedural interceptor, enemy hardware, weapon effects and illuminated boss armor; run mesh material |

Four MultiMeshes cover enemies, projectiles, shards and botnet. Sorting is
once per world tick (`DEPTH_BANDS = 192`); `_snapshot_render_state` runs above
the guard so paused entities do not interpolate from an old moving position.
`PROPS_Z = 8` separates floor entities from standing obstacles.
Presentation FX aging is excluded from the deterministic state hash.

## Tooling and validation

| Tool/suite | Purpose |
|---|---|
| `tools/run_tests.sh` | Named suites; fails on script/parse errors regardless of printed PASS |
| `test_cards_keyboard`, `test_input`, `test_hud` | Card navigation/actions and HUD contracts |
| `test_meta_layout`, `test_settings_overlay`, `test_draw_order` | Menu geometry, settings overlay and world layering |
| `tools/shot_cards.gd`, other `shot_*.gd` | Windowed screenshots; headless rendering has no capture texture |
| `tools/fps_probe.gd`, `tools/fps_collapse.gd` | Interactive frame-time probes |
| `tools/build_manual.py` | Generates `site/index.html` |
