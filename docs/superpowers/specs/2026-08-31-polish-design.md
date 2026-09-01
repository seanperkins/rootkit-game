# Polish: feel, audio, HUD, input and arrivals

The game is mechanically complete and silent. Nothing acknowledges a hit, a kill
or a death; the camera never moves; the HUD is one 200-character line; there is
no `[audio]` or `[input]` section in `project.godot` at all. This pass adds the
layer that makes the existing systems legible and physical, and it adds no new
mechanics — every change here is feedback about something that already happens.

Six features, in build order:

1. **Feel** — screen shake, hitstop, hit flash, damage numbers, damage vignette
2. **Audio** — a procedural synth, a bank, and a rate-limited playback pool
3. **Input** — an InputMap, gamepad support, and pause
4. **Preferences** — a settings screen, persisted, gating shake and volume
5. **HUD** — the status line broken into blocks, plus a run summary
6. **Arrivals** — mini-bosses and ICE teleport in, and the telegraph gaps close

The order is load-bearing. Arrivals want shake and a sound sting, so they come
after 1 and 2. The settings screen has nothing to configure until 1 and 2 exist.
Pause needs an InputMap before it can be bound, and the settings screen needs
pause to be reachable mid-run.

## Decisions

| Question | Answer |
|---|---|
| Sound production | Procedural — `AudioStreamWAV` synthesized in code, no files |
| Music | Out of scope |
| Hitstop scope | Rare events only: ICE kill, mini-boss kill, player death |
| Damage numbers | Pooled, hard cap 24, `ThemeDB.fallback_font` |
| Font assets | Still none — the fallback font is engine-provided, not a file |
| Settings | Volume, shake scale, damage numbers; persisted in `save.json` v3 |
| HUD direction | Panelized, still monospace and ASCII — no graphical bars |
| Arrival duration | 1.15s, not interruptible, not skippable |
| Arrival invulnerability | Yes — out of the grid, exactly like a submerged ambusher |
| New per-enemy arrays | Two: `_hit_flash`, `_arriving` |

## 1. Feel

### The layer is pure

`scripts/run/feel.gd` is a `RefCounted` holding shake, hitstop and the damage
number pool. No scene tree, no engine calls — the same discipline
`scripts/build/` keeps, and for the same reason: the numbers that decide whether
this feels good are the ones worth testing, and a test should not need a
viewport to reach them.

`run.gd` owns the instance, feeds it events, and reads back an offset, a time
scale and a list of numbers to draw. Everything stateful lives in `feel.gd`;
everything visual stays in `_draw`.

### Shake is trauma, not offset

The naive version — add a random offset per event — accumulates badly and looks
identical for a scratch and a death. Instead `feel` holds a single `trauma`
float in `0..1`, events *add* trauma, and it decays linearly. The offset applied
is:

```
offset = MAX_OFFSET * trauma * trauma * noise()
```

Squaring is the whole point: at trauma 0.3 the shake is 9% of maximum and reads
as a nudge; at 1.0 it is violent. One tunable produces the full range, and
overlapping events saturate rather than stacking into nausea.

Trauma sources, with the reasoning that sets them:

| Event | Trauma | Why |
|---|---|---|
| Player damage | `0.25 + 0.5 * (amount / max_integrity)` | Proportional. A chip hit and a hit that takes a third of your bar are not the same event. |
| Detonation | `0.15` | Frequent enough that anything larger is constant motion. |
| Mini-boss materialize | `0.5` | A set-piece. |
| ICE materialize | `0.8` | The largest in the game, once per subnet. |
| Player death | `0.7` | The run is over; nothing after it needs to stay readable. |

The camera is written in exactly one place, `run.gd:551`, so the offset is added
there and nowhere else.

### Hitstop is global, and therefore rare

Hitstop is `Engine.time_scale`, dropped to `0.05` and restored after a real-time
interval. The simulation is entirely dt-driven, so a global scale stays
internally consistent — there is no desync to manage, only a cost.

That cost is why it fires on **ICE kills, mini-boss kills and player death
only**. At the enemy cap a per-kill hitstop is not emphasis, it is a permanent
stutter — the tick routinely resolves dozens of deaths, and freezing on each
would mean the game never runs at full speed during the part where it is
working.

The coupling to accept explicitly: hitstop is real time the run clock does not
count, so a run gains roughly 60ms per boss kill. Nothing reads the run clock
with that precision, and the alternative — a separate unscaled clock threaded
through the director — buys nothing for a few hundred milliseconds a run.

### Hit flash

`_hit_flash` is a `PackedFloat32Array` sized `MAX_ENEMIES`, decayed in
`_age_fx`, and read in `_update_renderers` to lerp the instance colour toward
white.

It is set from the drain, and `hit_queue.gd` does not change to allow it.
`HitQueue` already publishes `hit_exploit` / `hit_target` / `hit_count` — the
per-pass list of hits landed on open targets — and `_steps78_drain` already
reads `hits_before` and `hit_count` around each pass to decide whether ON_HIT
fires. The flash is set by walking `hit_target` across that same window.

That range is the right one on its own terms: it is every hit that landed on a
target still open to being hit, which is exactly the set that should flash.
Corruption-only events are outside it and stay outside it — the instance colour
already lerps toward magenta by corruption fraction, so those are communicated
by a channel that exists.

**This is a new per-enemy array and falls under the reset invariant.**
`Population.spawn` recycles slots, so `_spawn_enemy_state` must zero it. A stale
flash is a fresh enemy spawning lit — visible, wrong, and exactly the class of
bug the invariant exists to prevent.

The colour already lerps toward magenta by corruption fraction. Flash composes
on top of that rather than replacing it, because an enemy that is both nearly
flipped and just hit is telling the player two true things.

### Damage numbers

Drawn with `draw_string(ThemeDB.fallback_font, ...)` in `_draw`. The fallback
font ships with the engine and is not a file in this repo, so the no-font-assets
rule holds.

The pool is capped at **24 live numbers, oldest evicted**. Uncapped, a working
build at the enemy cap produces thousands of strings a second, which costs more
than the entire rest of the frame and communicates nothing — a number nobody can
read is noise. Eviction rather than refusal keeps the most recent hits visible,
which are the ones the player is looking at.

Numbers rise, fade, and drift slightly by index so two hits on one enemy do not
draw on top of each other. Off by default is wrong for a game about numbers
going up; the preference exists for players who disagree.

### Damage vignette

A red edge-flash on `_damage_player`, decaying over ~0.4s. It is drawn in the UI
layer rather than the world, because it is a fact about the player and not about
a place.

## 2. Audio

Three files, and only the last one touches the scene tree.

### `scripts/audio/synth.gd` — pure

Builds an `AudioStreamWAV` from a spec: waveform (sine, square, saw, noise),
frequency envelope, amplitude ADSR, noise mix, duration, sample rate.
`AudioStreamWAV` is a `Resource`, which keeps this inside the same purity rule
`scripts/build/` follows, and makes it testable headless — buffer length,
clipping, determinism and envelope tail are all assertable without a viewport.

Procedural rather than sampled because the project has no image assets and no
font files, and a folder of `.ogg` files would be the first binary content in
the repo. It also means every sound is a few numbers in a table that can be
tuned in a diff.

### `scripts/audio/bank.gd`

Builds the fixed set of streams once at boot, keyed by event id.

**Every event id played must exist in the bank.** This is the same failure shape
already documented for `meta_screen.BUFFS` against `SaveGame._default()`: a
direct index with no fallback, crashing on a name that was added on one side
only. A test asserts the two sets match, because the alternative is discovering
it when a rare event fires mid-run.

### `scripts/audio/sfx.gd`

A node holding a round-robin pool of `AudioStreamPlayer`s, with pitch jitter so
repeats do not phase against each other, and **per-event rate limiting**.

The rate limiter is not a nicety. Six hundred enemies, a working build and a
magnet radius produce kills, hits and shard pickups by the hundred per second.
Played faithfully that is white noise at full volume — worse than silence,
because silence at least does not hide the events that matter. Each event id
carries a maximum plays-per-second; overflow is dropped, not queued.

### Buses and events

`project.godot` gains an `[audio]` section with Master and SFX. Preferences
drive `AudioServer.set_bus_volume_db`.

Events: per-vector-kind fire, hit, kill, flip, shard pickup, level up, card
select, card decline, player hurt, low integrity, mini-boss charge, mini-boss
arrival, ICE charge, ICE arrival, gate open, collapse start, win, death.

### No music

A procedural ambient bed is a subsystem with its own tempo, mixing and state
machine, and it does not belong in the same pass as everything above. Out of
scope, worth doing later.

## 3. Input and pause

### An InputMap, at last

There is no `[input]` section in `project.godot`. Movement is four direct
`Input.is_physical_key_pressed` calls at `run.gd:698-705`.

Adding actions — `move_left/right/up/down`, `confirm`, `cancel`, `pause`,
`recipes` — and switching movement to `Input.get_vector` brings analog gamepad
sticks along at no extra cost, because the two-axis read is the same call.

`input_override` stays exactly as it is. It is a world-space simulation hook for
headless drivers and has nothing to do with devices.

### Pause, and the one conflict

Escape currently declines a card (`ui.gd:652`). It should also pause. The rule:

> **Overlay visible → decline. Otherwise → pause.**

One rule, checked in one place, so the keyboard and the gamepad cannot diverge —
the same reasoning `ui.gd:243-248` already records for routing Enter through the
button's own `pressed` signal.

The pause panel offers resume, settings and abandon. `run.paused` already exists
and already gates the tick; nothing currently sets it from player input.

## 4. Preferences

`SaveGame` goes to version 3 with a `prefs` block:

| Key | Default | Range |
|---|---|---|
| `volume_master` | 0.8 | 0.0 – 1.0 |
| `volume_sfx` | 0.8 | 0.0 – 1.0 |
| `shake` | 1.0 | 0.0 – 2.0 |
| `damage_numbers` | true | bool |

`_sanitise` rebuilds from `_default()` and overlays what it can read, so a v2
file loads with default prefs and **no migration is needed**. Every key still
gets an explicit clamp there: `save.json` is user-editable and treated as
hostile, and a shake scale of 10000 read straight through is a crash dressed as
a preference.

The settings screen copies the row-and-scroll pattern `meta_screen.gd` already
uses for buffs, and is reachable from both the shell and the pause panel.

Shake scale reaching zero is deliberate. Screen shake is one of the two effects
here that can make a game unplayable for some people rather than merely
annoying, and the other one — flashing — is why damage numbers and the vignette
are tuned to fade rather than strobe.

## 5. HUD

`ui.gd:167` builds one format string carrying integrity, armor, defense, subnet,
timer, level, XP bar, salvage, botnet count, kills and flips, then appends the
mini-boss banner and the collapse countdown to the same line. It reads as a
debug printout because it is one.

It splits into blocks, all still monospace, still ASCII bars, no graphical
chrome:

- **Left** — integrity bar, armor, defense, level, XP bar
- **Centre** — subnet, timer, and the phase banner as its own line
- **Right** — salvage, botnet, kills, flips
- **Bottom left** — the build panel, which already exists as its own label

The aesthetic does not change. A terminal HUD is the right look for this game;
what is wrong is that eleven unrelated values share one line with no grouping,
so nothing can be found by position.

### Run summary

The end screen is currently a label and a restart button. It becomes a summary:
outcome, time survived, subnet reached, level, kills, flips, salvage banked, and
the three final exploits with their resolved stats.

A bullet heaven's end screen is where a run becomes a story the player can
compare against the next one. Ending on `disconnect -> shell` throws that away.

### Test impact

`test_meta_layout` and `test_cards_keyboard` assert against HUD node paths and
will need updating alongside this. A new `test_hud` suite covers the blocks and
the summary.

## 6. Arrivals

### The mechanism already exists

`_submerged` is a `PackedByteArray` handed to `grid.rebuild` as the enemy skip
mask (`run.gd:866`). An entity in it is out of the grid, which means it cannot be
hit, cannot hit you and cannot be targeted, and `_update_renderers` draws it at
scale zero (`run.gd:2179-2181`). An arriving boss is the same condition.

### `_arriving`, and why it is a separate array

`_arriving` is a `PackedFloat32Array` of seconds remaining, sized `MAX_ENEMIES`,
**reset in `_spawn_enemy_state`** under the same invariant as `_hit_flash`.

It is not folded into `_submerged` because `_ambush` writes that byte on its own
schedule, and a mini-boss with the AMBUSHER behaviour would have two independent
states fighting over one flag — arrival clearing a submersion the ambush logic
had just set, or the reverse, depending on tick order. Instead `_step3_rebuild`
unions the two into a dedicated skip array before handing it to the grid. That is
one O(count) pass over at most 600 entries, which does not register against the
rest of the tick, and it keeps both states independently testable.

Being out of the grid covers hits and targeting. Two passes walk the population
directly rather than through the grid and need an explicit skip:

- `_step4_steer` — or an arriving boss drifts toward the player mid-materialize
- `_step6b_hostiles` — or it shoots while still transparent

### The animation

1.15s in two phases, drawn in `_draw` from the `_arriving` timer:

**Charge, 0.9s.** A ground decal grows at the destination, three rings converge
inward on it, and glyph columns rain down the isometric vertical. Orange for a
mini-boss, violet for ICE. The player has nearly a second to see where it lands
and stop being there.

**Materialize, 0.25s.** White flash, shockwave ring expanding outward, and the
entity scales from zero to full with a slight overshoot. The renderer already
multiplies a per-entity scale, so this is one more term on an expression that
exists.

Shake trauma fires on the flash, with a charge whine and an arrival crack from
the audio bank.

### ICE gets the full version

The boss spawn already despawns every other enemy before ICE lands
(`run.gd:588-596`), for mechanical reasons that predate this spec. The side
effect is a perfect set-piece beat: the arena empties, holds for a second, and
then the thing arrives into open ground.

### Not interruptible, not skippable

An arrival that can be shot through is not an entrance. The invulnerability is
the feature, and 1.15s at 420–620px of separation is not long enough to be a
tax.

### Telegraph gaps

Charger windup and ambusher surfacing telegraphs already exist
(`run.gd:2398-2412`), and `_pulse` already rings. What is missing:

- A link line from a support enemy to whatever it is buffing
- A brief aim tell before `_fire_hostile`

## Testing

New suites, added to `SUITES` in `tools/run_tests.sh`:

- **`test_feel`** — trauma decays to zero, offset stays inside `MAX_OFFSET`,
  squaring makes small trauma small, hitstop expires and restores time scale,
  the number pool evicts oldest at the cap
- **`test_synth`** — buffer length matches duration × rate, no sample exceeds
  ±1, the same spec produces the same buffer twice, the envelope ends at silence
- **`test_audio_events`** — every played event id exists in the bank, and the
  rate limiter drops overflow rather than queueing it
- **`test_prefs`** — hostile values clamp, a v2 file loads with default prefs,
  a round trip preserves what was set
- **`test_input`** — every action the code references exists in the map, pause
  toggles `run.paused`, cancel routes to decline with an overlay up and to pause
  without one
- **`test_hud`** — the blocks exist and populate, the summary reports a finished
  run
- **`test_arrivals`** — an arriving boss is skipped by the grid, does not steer,
  does not fire, cannot be damaged, becomes live when the timer ends, and
  `_arriving` is zeroed on a recycled slot

Existing suites that change: `test_meta_layout` and `test_cards_keyboard` for
the HUD split, and `test_campaign` needs checking against the boss arrival —
it autopilots to an ICE kill, and 1.15s of invulnerability per boss shifts its
timing. That is a thing to verify, not to assume.

`perf_milestone0` must stay green. The per-frame additions are the flash decay
and the number pool, both O(n) over the enemy cap and both cheap, but the gate
is the arbiter.

## What this pass does not do

- No music
- No new mechanics, enemies, modules or balance changes
- No graphical HUD — it stays text
- No refactor of `run.gd` beyond moving feel state into `feel.gd`. The file is
  2438 lines and that is a real problem, but solving it is not this pass.
