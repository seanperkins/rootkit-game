# Polish: feel, audio, HUD, input and arrivals

The game is mechanically complete and silent. Nothing acknowledges a hit, a kill
or a death; the camera never moves; the HUD is one 200-character line; there is
no `[audio]` or `[input]` section in `project.godot` at all. This pass adds the
layer that makes the existing systems legible and physical, and it adds no new
mechanics — every change here is feedback about something that already happens.

Six features, in build order:

1. **Feel** — screen shake, hitstop, hit flash, damage numbers, damage vignette
2. **Audio** — a procedural synth and a rate-limited playback pool
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
| Hitstop clock | Wall clock (`Time.get_ticks_msec`), restored above the tick guard |
| Damage numbers | Pooled, hard cap 24, `ThemeDB.fallback_font` |
| Font assets | Still none — the fallback font is engine-provided, not a file |
| Settings | Volume, shake scale, damage numbers; persisted in `save.json` v3 |
| HUD direction | Panelized, still monospace and ASCII — no graphical bars |
| Player pause | Its own flag, never `run.paused` |
| Arrival duration | 1.15s, not interruptible, not skippable |
| Arrival gate site | `_step2_integrate`'s enemy loop — not steer, not hostiles |
| New per-enemy arrays | Two: `_hit_flash`, `_arriving` |

## 0. The presentation split

Everything below depends on one structural change, so it comes first.

`_physics_process` returns before any step when the run is not running
(`run.gd:518-520`):

```gdscript
func _physics_process(dt: float) -> void:
	if paused or not alive or won:
		return
```

The camera write and `queue_redraw()` (`run.gd:551-552`) sit **below** that
guard, along with everything else. That is correct for simulation and wrong for
presentation: the moment the run ends or an overlay opens, the view stops
updating entirely.

So the tick splits in two. Above the guard, every frame, unconditionally:

- advance the feel clock on **unscaled** time
- release an expired hitstop
- age the visual effects — see below
- write the camera (position plus shake offset)
- `queue_redraw()`

Below the guard, only when the run is live: `queue.begin_tick()` and the ordered
simulation steps, exactly as today. `begin_tick` stays below deliberately — the
comment at `run.gd:523-530` records why, and nothing here changes it.

**`_age_fx` has to move, and it is not currently where it looks.** It is called
at `run.gd:832`, which is *inside* `_step2_integrate` (686-856) — below the
guard. Hoisting `queue_redraw()` while leaving the aging behind it produces the
precise failure §0 exists to prevent: on death the world redraws every frame
with `_fx_line`, `_fx_ring`, `_hit_flash` and the damage numbers frozen at their
last live values, forever.

So the presentation half calls `_age_fx` on the unscaled delta, and the call at
`run.gd:832` is removed. Nothing in `_age_fx` touches simulation state — it
decays four presentation-only collections — so the move is safe, but it must be
explicit or an implementer will hoist the redraw and leave the decay.

This is what makes the death shake animate, the pause panel render at full
speed, and the hitstop release reachable. Without it, three features in this
spec are unimplementable, which is what the first review round found.

**Unscaled time.** `Engine.time_scale` scales the delta the engine hands
`_process` and `_physics_process` alike, so at `time_scale = 0.05` a `dt`-fed
timer runs 20× long — a 60ms hitstop becomes 1.2s of wall clock. The
presentation half therefore derives its own delta from `Time.get_ticks_msec()`,
which is unaffected by time scale and is already the idiom here (`run.gd:2327`,
`scripts/run/props.gd:129`). Measured during review: the physics tick *rate* is
unchanged by time scale (still 60/s at 0.05), only the delta shrinks — so the
above-guard release runs at full frequency during a hitstop.

**That delta is clamped to 0.1s.** A wall-clock delta is unbounded across a
first frame, a scene load, or an OS suspend-and-resume, and an unclamped one
would expire every live effect and the hitstop in a single frame after any of
them.

## 1. Feel

### The layer is pure, and does not own the engine

`scripts/run/feel.gd` is a `RefCounted` holding shake trauma, the hitstop
deadline and the damage number pool. No scene tree, no engine calls — the same
discipline `scripts/build/` keeps, so the numbers that decide whether this feels
good are testable without a viewport.

`feel` **reports** a desired time scale; `run.gd` **applies** it. `feel` never
writes `Engine.time_scale`, because a `RefCounted` that touches an engine
singleton is not pure and the analogy to `scripts/build/` would be false. This
splits the testing too, and the split matters: `test_feel` asserts the deadline
arithmetic on a bare object, and `test_run` asserts the engine actually got
restored. The first cannot catch a stranded time scale; only the second can.

### Shake is trauma, not offset

`trauma` is a single float, events add to it, and it decays linearly. The offset
applied is:

```
offset = MAX_OFFSET * trauma * trauma * noise()
```

Squaring is the point: at trauma 0.3 the shake is 9% of maximum and reads as a
nudge; at 1.0 it is violent. One tunable produces the full range.

**Trauma is clamped: `trauma = clampf(trauma + add, 0.0, 1.0)`.** The clamp is
what makes "overlapping events saturate rather than stack" true, and without it
the `MAX_OFFSET` name is a lie — twelve detonations reach 1.8 and an offset of
3.24 × `MAX_OFFSET`. `noise()` returns a vector of magnitude ≤ 1, not
independent per-axis values in `[-1, 1]`, or the diagonal exceeds the bound the
test asserts.

Trauma sources:

| Event | Trauma | Why |
|---|---|---|
| Player damage | `0.25 + 0.5 * clampf(amount / max_integrity, 0.0, 1.0)` | Proportional, and the ratio is clamped because a boss pulse can exceed full integrity. |
| Detonation | `0.15` | Frequent enough that anything larger is constant motion. |
| Mini-boss materialize | `0.5` | A set-piece. |
| ICE materialize | `0.8` | The largest in the game, once per subnet. |
| Player death | `0.7` | Animates because of §0; without that split it would render zero frames. |

The `shake` preference (§4) multiplies the **composed offset in `run.gd`**,
outside `feel`, after the square. Folded into trauma before squaring, a legal
`shake = 2.0` would yield 4× rather than 2×. So `feel`'s own invariant is
`|offset| <= MAX_OFFSET`, and that is what `test_feel` asserts; the preference
scales it afterward.

The camera is written in exactly one place (`run.gd:551`), now above the guard
per §0.

### Hitstop: wall clock, released above the guard

Hitstop drops `Engine.time_scale` to `0.05` for a wall-clock interval. The
simulation is dt-driven, so a global scale stays internally consistent.

**The restore is the hard part, and the first review round found the naive
version unimplementable.** All three chosen triggers halt the tick on the same
frame they fire:

- ICE kill → `won = true` (`run.gd:1643`)
- Player death → `alive = false` (`run.gd:1290`)
- Mini-boss kill → `_offer_cards()` (`run.gd:1626`) → `paused = true` (`run.gd:2020`)

A restore driven from inside the gated tick therefore never runs, and
`Engine.time_scale` is process-global — it survives scene changes, so the end
screen, the shell, the shop and every later run would sit at 5% speed until the
process exits.

The mechanism, stated so it cannot be re-derived wrongly:

1. `feel` stores `_hitstop_until_ms`, an absolute `Time.get_ticks_msec()` value.
2. The check-and-release runs in the presentation half of the tick, **above**
   the `run.gd:519` guard, so `paused` / `not alive` / `won` cannot skip it.
3. **The safety restore lives at run teardown / scene exit, not at the
   triggers.** An earlier revision of this spec put an unconditional
   `Engine.time_scale = 1.0` in `_die()` and at the `won = true` branch — which
   are the death and ICE-kill paths, i.e. two of the three trigger sites. Five
   reviewers found the contradiction independently: ordered before the set it is
   dead code, ordered after it cancels the hitstop at birth. Either way two of
   the three hitstops never happen. So the restore goes where the deadline check
   stops running — `_exit_tree` / the transition back to the shell — and there
   it is **unconditional**.

   Unconditional specifically, because this is the second thing a draft got
   wrong. A later revision made it "conditional on no active deadline", carrying
   a condition that was right at a *trigger* site (do not preempt a live
   hitstop) to a site where its rationale does not hold. After teardown nothing
   releases anything — the presentation tick goes with the scene — so declining
   to restore because a deadline is still live leaks `Engine.time_scale` at 0.05
   in exactly the case that matters: quitting or restarting during the 60ms
   hitstop a death just started. Two reviewers caught it; two others approved
   the wording without tracing that path.
4. Entering player-pause does **not** restore. The release check runs above the
   guard, so `user_paused` no longer skips it, and cancelling there would make
   pausing during a boss kill silently different from not pausing.
5. `test_run` asserts **both** halves: `Engine.time_scale == 0.05` immediately
   after the death path (proving the hitstop engaged), and `1.0` after the
   wall-clock deadline passes (proving it released). Asserting only the second
   is what an earlier draft specified, and it passes identically whether the
   hitstop fired or was cancelled at birth — it tests the safety property while
   appearing to test the feature. A headless suite that leaked 0.05 would slow
   the whole `godot --headless` process and could quietly distort
   `perf_milestone0`.

Hitstop stays on rare events only. At the enemy cap a per-kill hitstop is not
emphasis, it is a permanent stutter.

**Cost, corrected.** `MINIBOSS_TIMES` has 4 entries and `reset()` re-arms them
per subnet, so a full campaign is 4 × 3 mini-bosses plus 3 ICE fights = 15
hitstop events. At 60ms each that is ~0.9s of wall clock, of which the run clock
loses 57ms per event (it advances at 5%, not zero) — ~0.86s per campaign, not
"a few hundred milliseconds a run". Still small enough that nothing reading the
run clock cares, but the number is stated rather than guessed.

### Hit flash

`_hit_flash` is a `PackedFloat32Array` sized `MAX_ENEMIES`, decayed in
`_age_fx`, read in `_update_renderers` to lerp the instance colour toward white.
It composes on top of the existing corruption tint rather than replacing it.

It is set from the drain, and `hit_queue.gd` does not change. `HitQueue`
publishes `hit_exploit` / `hit_target` / `hit_count` — the per-pass list of hits
landed on open targets.

**The walk is `0 ..< queue.hit_count`, after each `drain_pass`.** Not a
`hits_before`-to-`hit_count` window: `drain_pass` zeroes `hit_count` on entry
(`hit_queue.gd:118`, a deliberate fix for an out-of-bounds write), so the
`hits_before` captured at `run.gd:1570` holds the **previous** pass's count. A
range built from it is empty whenever a pass lands fewer hits than the one
before it, and skips an arbitrary prefix otherwise — silently, since the indices
stay in bounds. An earlier draft of this spec specified that window and defended
it; it was wrong.

`hit_target` records a hit whenever `adjudication[i] == OPEN`, including events
that change no integrity. Those flash too: the flash means "this was hit", not
"this lost HP", and splitting the two would need state the queue does not keep.

**Pre-existing, out of scope, but noted here because this spec is the reason
anyone looked:** the ON_HIT gate at `run.gd:1580` (`if queue.hit_count >
hits_before`) has the same cross-pass comparison and appears to be a leftover
from when `hit_count` was reset only in `begin_tick`. Two reviewers flagged it
independently. Changing it alters combat behaviour, so it is **not** part of
this pass — it is raised for a separate decision.

### Damage numbers

Drawn with `draw_string(ThemeDB.fallback_font, ...)`. The fallback font ships
with the engine and is not a file in this repo, so the no-font-assets rule
holds.

The pool is capped at **24 live, oldest evicted**, and entries are pruned on
expiry in `_age_fx` so expired rows cannot hold the cap. Uncapped, a working
build at the enemy cap produces thousands of strings a second.

Numbers are **world-space** — they belong to an enemy at a place, so they are
drawn in `_draw` under the same `to_iso` projection as everything else and move
with the camera. The vignette below is the screen-space one.

### Damage vignette

A red edge-flash on `_damage_player`, decaying over ~0.4s, drawn in the UI layer
because it is a fact about the player and not about a place. It is also the
shake-independent damage tell for anyone who sets `shake = 0`.

## 2. Audio

Two files. An earlier draft had three; `bank.gd` was a const spec table plus a
build call, which is pure data next to a pure builder, so it folds into
`synth.gd` with the discipline intact.

### `scripts/audio/synth.gd` — pure

Builds an `AudioStreamWAV` from a spec: waveform (sine, square, saw, noise),
frequency envelope, amplitude ADSR, noise mix, duration. Also holds the event
table and `build_bank()`.

Format is pinned, because "produces an `AudioStreamWAV`" is not a specification:
**16-bit signed PCM, mono, `const SAMPLE_RATE := 22050`**, sample count
`int(round(duration * SAMPLE_RATE))`. Sample rate is a const, not a per-spec
field — every sound uses the same one, and a per-spec knob nobody varies is a
constant in disguise.

ADSR phases are **normalized to fit duration** when attack + decay + release
exceed it, rather than rejected, so "the envelope ends at silence" is achievable
for every spec in the table rather than for most of them.

`AudioStreamWAV` is a `Resource`, which keeps this inside the same purity rule
`scripts/build/` follows and makes it testable headless.

### `scripts/audio/sfx.gd` — the only part that touches the tree

A node holding a round-robin pool of `AudioStreamPlayer`s, pitch jitter, and
**per-event rate limiting**. Six hundred enemies and a magnet radius produce
kills, hits and pickups by the hundred per second; played faithfully that is
white noise. Each event id carries a maximum plays-per-second and overflow is
dropped, not queued.

### The simulation never calls the node

`run.gd` must not hold a reference to `sfx.gd`, or the tick becomes coupled to
the scene tree and the headless testability §1 just protected is lost — the most
expensive thing in this spec to reverse later, since the hooks are spread across
every combat, economy and lifecycle path.

Instead **`feel` accumulates a per-tick list of event ids** (it is already the
pure sink for presentation events), and `sfx.gd` drains that list after the
tick. Headless suites never instantiate the node; the events are assertable as
data. One boundary, one direction, no node reference below it.

### Buses are created in code

There is no `[audio]` section that declares buses. Godot takes buses from the
bus-layout resource named by `audio/buses/default_bus_layout`, or from runtime
`AudioServer.add_bus`. An earlier draft said "`project.godot` gains an `[audio]`
section with Master and SFX", which is not a thing the engine supports.

So: **create the SFX bus with `AudioServer.add_bus`, idempotently.**
`add_bus` takes an index, not a name — the name is a second call,
`set_bus_name`. And "at boot" is wrong for this codebase in the same way the
hitstop restore was: there are no autoloads, and the game shuttles between
`meta_screen.gd:161` and `ui.gd:540` all session, so anything scoped to a scene
runs once per *run*, not once per process. Creation is therefore guarded on
`get_bus_index("SFX") < 0` and is safe to call on every scene entry.

No new resource file, no binary. Every volume write checks
`get_bus_index("SFX") >= 0` first, because a missing bus returns `-1` and
`set_bus_volume_db(-1, x)` errors on every slider movement.

That guard needs an explicit assertion rather than trust in the runner:
`set_bus_volume_db(-1, …)` emits `ERROR:`, not `SCRIPT ERROR:`, so
`tools/run_tests.sh:33` does not match it and a forgotten guard would pass the
suite silently. `test_audio_events` asserts the bus index is non-negative after
creation directly.

Volume conversion is `linear_to_db(maxf(v, 0.0001))`, with a `set_bus_mute`
branch at zero — `linear_to_db(0.0)` is `-INF`, and a non-finite float entering
an engine setter is worth avoiding even where the engine tolerates it.

### Event ids

Per-vector-kind fire ids are **derived from the `VectorKind` enum**, not
constructed ad hoc, so a new vector kind cannot mint an id the bank has never
heard of. `Module.VectorKind` is append-only (CLAUDE.md), which makes the enum a
safe key source.

`test_audio_events` enumerates the ids the code can actually generate —
iterating `VectorKind` — and asserts each resolves in the bank. Comparing two
static sets would pass while a runtime-generated id crashed, which is the exact
failure shape already documented for `meta_screen.BUFFS` against
`SaveGame._default()`.

Events: per-vector-kind fire, hit, kill, flip, shard pickup, level up, card
select, card decline, player hurt, low integrity, mini-boss charge, mini-boss
arrival, ICE charge, ICE arrival, gate open, collapse start, win, death.

### No music

A procedural ambient bed is a subsystem with its own tempo, mixing and state
machine. Out of scope, worth doing later.

## 3. Input and pause

### An InputMap, with bindings

There is no `[input]` section in `project.godot`; movement is four direct
`Input.is_physical_key_pressed` calls at `run.gd:698-705`. Naming actions
without binding them leaves `Input.get_vector` permanently zero — that would
break keyboard movement while delivering no gamepad support, so the bindings are
part of the spec, not an implementation detail:

| Action | Keyboard | Gamepad |
|---|---|---|
| `move_left` / `move_right` | A / D, ←  / → | D-pad, left stick X |
| `move_up` / `move_down` | W / S, ↑ / ↓ | D-pad, left stick Y |
| `confirm` | Enter, KP-Enter, Space | A / cross |
| `cancel` | Escape | B / circle |
| `pause` | Escape (see routing) | Start |
| `recipes` | R | Y / triangle |
| `restart` | R | X / square |

Stick deadzone 0.2. `Input.get_vector` reads both axes in one call, so analog
movement comes along for free.

`recipes` and `restart` share R because `ui.gd:637` already binds R to
`_restart()` on the end screen while R toggles the recipe panel elsewhere. They
are two actions rather than one because a gamepad has no shared key to
disambiguate, and the routing below decides between them by screen — the same
"one rule, one place" discipline the `cancel` arms follow.

`input_override` stays as it is — a world-space simulation hook for headless
drivers, unrelated to devices.

### `ui.gd` moves to actions

`ui.gd:640-656` matches raw keycodes. `InputEventJoypadButton` has no keycode,
so with movement on actions and nothing else changed, a gamepad player could
walk and pause but could not navigate, confirm or decline a level-up — unable to
operate the build system the game is named for.

So the overlay handler moves from `e.keycode` to action queries. This is what
makes "one rule, both devices" true rather than aspirational, and it is why
`test_cards_keyboard` changes: it synthesizes `InputEventKey` and sets
`.keycode` (`tests/test_cards_keyboard.gd:78-79`), which action matching will
not resolve without a `physical_keycode` and a loaded InputMap. `test_input`
drives the overlay with joypad events as well as key events.

**`tools/shot_cards.gd` is the second consumer, and it is not a test.** Its
`_key()` helper (`tools/shot_cards.gd:17-21`) builds an `InputEventKey`, sets
`.keycode`, and calls `ui._input(e)` directly to drive the level-up overlay for
a screenshot. `grep -rn keycode tools/ tests/` returns exactly two hits — that
file and `test_cards_keyboard` — so this is the complete consumer set, and the
tool is the half no suite covers. Migrated with `ui.gd` or not at all: left
behind, it still writes PNGs, they just show the wrong button selected, which is
a broken screenshot that looks like a working one.

### Player pause gets its own flag

`run.paused` is not free real estate. It means "a modal offer is open", it is
set at `run.gd:1835` (fusion) and `run.gd:2020` (cards), and **four sites clear
it unconditionally** (`run.gd:1868`, `1876`, `2065`, `2073`). `ui.gd:658-662`
force-hides the card overlay whenever `not run.paused`.

Overload it and this happens: a card offer is open, the player presses Start,
the pause panel opens, Resume sets `paused = false`, and `ui.gd:658-662` hides
the cards. Pending cards self-heal at `run.gd:1991`; a pending fusion does not —
`_pending_fusions` is stranded until the next block payout.

So player pause is **`user_paused`, a separate bool**, OR-ed into the tick gate
at `run.gd:519`. The modal protocol's four unconditional clears can then never
release a pause they did not take.

Second-order, and handled: `ui.gd:_process` skips `_refresh()` while paused, so
the new HUD blocks would freeze under the pause panel. `_refresh()` moves to
run on `user_paused` too, or the panel draws over a stale HUD.

### Escape routing needs four arms

"Overlay visible → decline, otherwise → pause" does not cover the screens that
exist. Enumerated from `ui.gd`:

| State | `cancel` does |
|---|---|
| Recipe panel open (child of `_overlay`, `ui.gd:117`/`136`) | Close the panel |
| Card or fusion overlay up | Decline |
| End screen (`_end`, a **sibling** of `_overlay`, `ui.gd:138`) | Back to shell |
| Pause panel up | Resume |
| Otherwise | Pause |

Checked in one place, so the keyboard and the gamepad cannot diverge — the
reasoning `ui.gd:243-248` already records. Without the recipe arm, Escape with
the panel open declines the card underneath it; without the end-screen arm,
Escape on a finished run pauses it.

One input edge produces one transition — the routing reads a just-pressed edge,
not a held state.

## 4. Preferences

`SaveGame` goes to version 3 with a `prefs` block:

| Key | Default | Range |
|---|---|---|
| `volume_master` | 0.8 | 0.0 – 1.0 |
| `volume_sfx` | 0.8 | 0.0 – 1.0 |
| `shake` | 1.0 | 0.0 – 2.0 |
| `damage_numbers` | true | bool |

`_sanitise` rebuilds from `_default()` and overlays what it can read, so a v2
file loads with default prefs and **no migration is needed** — verified against
`save_game.gd:102`, which quarantines only `version > VERSION`.

### The container guard, not just the clamps

An earlier draft promised "an explicit clamp" per key and stopped there. That is
half the existing contract: `_sanitise` guards the **container type** before
indexing it, for `buffs` (`save_game.gd:117`) and `unlocked`
(`save_game.gd:121`) alike.

Without it, `{"prefs": "owned"}` or `{"prefs": [1,2,3]}` makes
`prefs.get(key, default)` a runtime error. Per CLAUDE.md, a GDScript runtime
error aborts the function it happens in — so `_sanitise` aborts, `_cache =
_sanitise(d)` at `save_game.gd:89` never runs, `load_state()` returns null, and
every caller that indexes it errors in turn. A one-token edit to a plaintext
file cascades into the boot path.

So: `var p = d.get("prefs", {})` / `if typeof(p) == TYPE_DICTIONARY:`, exactly
as `buffs` does, with `out["prefs"]` seeded from `_default()` so a failed guard
yields defaults.

Per-key values get a type check too — `float(v)` and `int(v)` are not total. A
small `_num(v, default)` helper closes it for the new keys and the existing
`buffs` block at once, and it must reject **four** things, not the one an
earlier draft named:

- a Dictionary or Array value — invalid-type error, same abort semantics
- **`TYPE_NIL`** — `float(null)` aborts `_sanitise`. This one is reachable in
  ordinary play, not just by hand-editing: see the write-side note below.
- **`NAN`** — `clampf(NAN, 0.0, 2.0)` returns `nan`, measured on Godot 4.7. A
  clamp is not a finiteness check.
- **`±INF`** — for a *different* reason, worth stating rather than eliding:
  `clampf(INF, 0.0, 2.0)` does return `2.0`, so the clamp holds here. It is
  rejected anyway because an INF that reaches the dictionary before the clamp —
  or any key whose clamp is later loosened — persists as `1e99999`, and because
  one rule is easier to keep right than two.

The rule is `is_finite()` plus an explicit type check, not `clampf` alone.

**`_num` covers more than the prefs and `buffs`.** `save_game.gd:113-115` reads
`salvage`, `kills` and `flips` with the same unguarded `int()` coercion, and
their blast radius is worse than the `buffs` case: `_read` succeeds, so
`_sanitise` aborts and `load_state()` returns `{}` rather than a default
profile — which then reaches `meta_screen.gd:116` and sticks. Three more
one-line changes to a helper this pass already introduces; skipping them would
leave the sharpest of the four paths open while closing the other three.

### The version read needs its own guard

`_num` lives in `_sanitise` and therefore does not cover `_read`, which does
`int(parsed.get("version", 0))` at `save_game.gd:102` with no type guard at all.
`{"version": null}` produces `Invalid call. Nonexistent 'int' constructor` —
reproduced under `godot --headless` during review — which aborts `_read`,
discards the save silently, and after two further saves rotates the `.bak` away
permanently. It is outside this pass's nominal scope but it is on the same code
path the `VERSION` bump touches, and it is one guard.

The guard is **finite-number**, not merely non-null: `int(INF)` is
`9223372036854775807`, so `{"version": 1e99999}` sails past a null check and
quarantines the live save (verified — `PATH` gone). And `save_game.gd:103` holds
a *second* `int(parsed["version"])` for the rename suffix, which needs the same
treatment or the guard is only half applied.

### Clamped on write as well as read

`save_state()` stringifies `_cache`, which is sanitised on load and then freely
mutated (`bank()` at `save_game.gd:147`, `buy()` at 243 both write it directly).
A settings screen assigning `prefs["shake"] = value` gets no clamp until the
next cold load.

**The reason an earlier draft gave for this was wrong, and the truth is worse.**
That draft claimed `JSON.stringify` emits `inf`/`nan`, producing invalid JSON
that `_read` discards. Measured on Godot 4.7 during review: `JSON.stringify`
turns `NAN` into `null` and `INF` into `1e99999`, which parses back as `inf`.
Both are valid JSON, so the file is never discarded — the bad value is
faithfully **persisted**. A NaN written once comes back as `null` on the next
load, and `float(null)` aborts `_sanitise`, which cascades exactly as the
container-guard case above. The save is not lost to a parse failure; it is lost
to a permanent crash on read.

So a `SaveGame.set_pref(key, value)` applies the same clamp table and the same
`is_finite` rejection `_sanitise` uses, and the settings screen goes through it.
One definition, both directions — a clamp on the write side alone would not have
caught this, since `clampf(NAN, …)` is `nan`.

### The screen

Copies the row-and-scroll pattern `meta_screen.gd` already uses, reachable from
the shell and the pause panel.

Shake scale reaching zero is deliberate: it is one of the two effects here that
can make a game unplayable rather than merely annoying for some players, and the
other — flashing — is why the vignette and numbers fade rather than strobe.

**`test_meta_layout` is the suite at risk from this section**, not from §5.
It exists because the shop column "already ran to roughly 505px in a 720px
viewport"; adding a settings entry point to that screen is exactly the overflow
it was written to catch.

## 5. HUD

`ui.gd:166` builds one format string carrying integrity, armor, defense, subnet,
timer, level, XP bar, salvage, botnet count, kills and flips, then appends the
mini-boss banner and the collapse countdown to it. It reads as a debug printout
because it is one.

It splits into blocks, all still monospace, still ASCII bars:

- **Left** — integrity bar, armor, defense, level, XP bar
- **Centre** — subnet, timer, and the phase banner as its own line
- **Right** — salvage, botnet, kills, flips
- **Bottom left** — the build panel, which already exists as its own label

The aesthetic does not change. What is wrong is that eleven unrelated values
share one line with no grouping, so nothing can be found by position.

**The mini-boss banner is gated on arrival.** `ui.gd:174-181` scans the
population for `_is_miniboss` and appends `":: <NAME> ACTIVE"` the moment the
entity exists — which under §6 is the start of the 0.9s charge, before anything
is visible. That spoils the entrance the telegraph is building. Gate it on
`_arriving[i] <= 0.0`.

### Run summary

`_on_end` (`ui.gd:527-537`) already prints subnet, kills and flips on a loss and
banked salvage on a win, so this is an improvement on a real starting point
rather than a rescue. It becomes: outcome, time survived, subnet reached, level,
kills, flips, salvage banked, and the three final exploits with resolved stats —
tolerating a run that ended with fewer than three, rather than indexing three
unconditionally.

### Test impact, corrected

An earlier draft said `test_meta_layout` and `test_cards_keyboard` "assert
against HUD node paths". They do not: `grep -rn '_hud|get_node("Top")|"Build"'
tests/` returns nothing. **The HUD has zero test coverage today**, so
`ui.gd:165` and `ui.gd:199` — which index `get_node("Top")` and
`get_node("Build")` with no `.get` — can be renamed with no suite noticing.

`test_hud` is therefore not a supplement, it is the only guard, and it pins
those node names or their successors.

Both suites do still break, but indirectly: `test_meta_layout` duck-types the UI
layer (`tests/test_meta_layout.gd:127-134`) and reaches `ui.recipe_lines()`, so
a script error inside a restructured `_refresh` fails them through the runner's
SCRIPT ERROR discipline rather than through their own assertions.

## 6. Arrivals

### The mechanism exists, with a caveat

`_submerged` is a `PackedByteArray` handed to `grid.rebuild` as the enemy skip
mask (`run.gd:866`). An entity in it is out of the grid — unhittable,
untargetable — and `_update_renderers` draws it at scale zero (`run.gd:2182`).
Player contact damage is a grid query (`run.gd:1240-1245`), so grid exclusion
does cover contact.

It does **not** cover everything, which is where the first draft of this section
was wrong. See "the three direct walks" below.

### `_arriving`, and why it is separate

`_arriving` is a `PackedFloat32Array` of seconds remaining, sized `MAX_ENEMIES`.

Not folded into `_submerged` because `_ambush` writes that byte on its own
schedule, and `kernel_panic` — a real mini-boss (`spawn_director.gd:65`) — would
have two independent states fighting over one flag. `_step3_rebuild` unions them
into a dedicated skip array, **fully rebuilt every tick**, not incrementally
OR-ed; an incremental union leaves an entity permanently unqueryable after
arrival. One O(count) pass over at most 600 entries.

The renderer reads `_arriving` **independently**. The union array is grid-only,
and `run.gd:2182` tests `_submerged[i]` directly — so without its own read the
boss draws at full scale through the entire 0.9s charge phase, before the
materialize ramp begins.

### Both halves of the slot invariant

`_hit_flash` and `_arriving` are per-enemy arrays and need **both** halves:

**Spawn reset** — `_spawn_enemy_state` zeroes them, because `Population.spawn`
recycles slots.

**Swap relocation** — `run.gd:1708-1716` hand-moves eight parallel arrays
tail-into-slot on every despawn, under a comment that says why: *"Population
.despawn swap-removes the tail into slot i, so every parallel array must move
with it. Six of these were missing."* An earlier draft cited only the spawn
half.

That omission is not cosmetic. A mini-boss spawns at the tail; during its 1.15s
arrival the swarm is dying every tick, and every recycle swaps the tail down into
a freed slot. The boss's timer is left behind — it materializes instantly and is
hittable during its own entrance, the feature's headline behaviour gone in
exactly the case it was built for — while the enemy that inherits the old slot
goes invulnerable and invisible for up to a second. ICE escapes only by accident,
because the arena is emptied first.

**Pre-existing, and fixed here because the feature is about to lean on it:**
`_submerged`, `_ai_phase`, `_ai_timer` and `_ai_aim` are themselves absent from
that block. An ambusher self-heals within a tick because `_ambush` rewrites the
byte; the AI arrays do not.

Enumerating the 13 arrays sized `resize(MAX_ENEMIES)` at `run.gd:424-445`
against the eight relocated at `run.gd:1708-1716` leaves **five**, not four:
`_ai_phase`, `_ai_timer`, `_ai_aim`, `_submerged` — and `_order`
(`run.gd:445`), which is the one that genuinely needs nothing, because
`_depth_sort` refills it wholesale every tick (`run.gd:2223-2226`). Four to add,
one to leave alone deliberately. The count is spelled out because the spec asks
the implementer to run this enumeration, and it should come out to the number
stated.

Adding the four alongside the two new ones is a six-line change to one block,
and leaving them out would mean building a boss entrance on the same latent bug.

**There is a second despawn site, and it relocates nothing at all.**
`_step2d_collapse` removes enemies standing on voided ground
(`run.gd:1802-1804`):

```gdscript
for i in range(enemies.count - 1, -1, -1):
	if terrain.is_void(enemies.pos[i]):
		enemies.despawn(i)
```

Reverse iteration does not make this tail-only — the predicate is conditional,
so any enemy in the void is despawned from the middle and the tail is swapped
down over it. This runs during `CLEARED`, which is precisely when a mini-boss
can be mid-arrival. Either it gets the same relocation block, or the relocation
becomes a `_relocate(i, last)` helper both sites call — the second is better,
since a third despawn site added later would otherwise repeat the bug a third
time.

### The three direct walks

Grid exclusion covers hits, targeting and contact. Three passes walk
`enemies.count` directly and need an explicit `_arriving` skip. An earlier draft
named two, and **named the wrong two**:

1. **`_step2_integrate`'s enemy loop (`run.gd:737-752`)** — the one that
   matters, and the one the earlier draft missed entirely. It computes
   `enemies.vel[i] = _behave(i, t, dt) + ...` and integrates position.
   `_behave` (`run.gd:1333`) dispatches to `_charge` / `_ranged` / `_pulse` /
   `_support` / `_ambush` / `_flank`. So without a skip here an arriving boss
   chases at full speed (ICE is CHASE behaviour, `data/enemy_table.gd:11,57`)
   and lands nowhere near where the telegraph promised; `_ranged`
   (`run.gd:1401`) spawns hostile shots via `_fire_hostile`; and `_pulse`
   (`run.gd:1391-1399`) calls `_damage_player` directly on a line-of-sight
   check, with no grid involved at all. An arriving `kernel_panic` would damage
   the player from a body that cannot be seen or hit.
2. **`_step2b_zones` (`run.gd:1553-1564`)** — queues `DAMAGE` for a HAZARD tile
   and `CORRUPTION` for a CORRUPTION tile purely by index. Corruption is the
   flip channel, so a boss can flip mid-entrance while invisible, and per
   CLAUDE.md the flip guard, the boss spawn and the win condition all key off
   `EnemyTable.ICE`.
3. **`_step4_steer`** — writes `enemies.force[i]` only. Skipping it is garnish
   once (1) is gated, but it keeps neighbours from shoving a ghost.

`_step6b_hostiles` is **not** on this list, contrary to the earlier draft: it
iterates `hostiles`, not `enemies` (`run.gd:1427-1440`), advancing
already-spawned shots. There is no enemy index there to skip.

The rule to carry forward is **"every pass that walks `enemies.count`
directly"**, not an enumerated pair.

### The animation

1.15s in two phases, drawn in `_draw` from the `_arriving` timer:

**Charge, 0.9s.** A ground decal grows at the destination, three rings converge
inward, glyph columns rain down the isometric vertical. Orange for a mini-boss,
violet for ICE. The player has nearly a second to see where it lands — which is
only true because of the `_step2_integrate` skip above.

**Materialize, 0.25s.** White flash, shockwave ring expanding outward, entity
scale eases 0 → full with a slight overshoot.

Shake trauma fires on the flash, with a charge whine and an arrival crack.

### ICE gets the full version

The boss spawn already despawns every other enemy first (`run.gd:588-596`), so
the arena empties, holds, and then the thing arrives into open ground.

### Not interruptible, not skippable

An arrival that can be shot through is not an entrance.

**The aggregate cost, and it is not uniform across the 15 arrivals.** Three
drafts of this paragraph got it wrong in three different directions, so the
mechanism is spelled out rather than summarized:

- **The 12 mini-boss arrivals cost no wall-clock at all.** `MINIBOSS_TIMES` is
  `[60, 120, 180, 240]`, every entry inside the subnet's 300s, and
  `spawn_director.gd:143` is `elapsed = minf(elapsed + dt, SUBNET_SECONDS)`.
  Arrivals do not stop the tick, so those seconds are spent *inside* the window
  rather than added to it. The swarm stays alive and killable throughout — a
  mini-boss arriving does not empty the arena.
- **The 3 ICE arrivals each extend their subnet by the full 1.15s.**
  `should_spawn_boss()` is `elapsed >= SUBNET_SECONDS and not boss_spawned`
  (`spawn_director.gd:158-159`), so ICE spawns only *after* elapsed has already
  pegged at 300 — the clamp cannot absorb it. The subnet then ends on ICE's
  death (`run.gd:1637` for CLEARED, `run.gd:1643` for the win), and ICE cannot
  be killed while it is arriving. The delay is strict.

So campaign wall-clock shifts by **3 × 1.15 = 3.45s**, all of it ICE. The other
13.8s is animation the player watches while the fight continues around them.

**No suite asserts that 3.45s, deliberately.** `test_campaign` cannot host it:
`_kill_ice` (`tests/test_campaign.gd:179-183`) spawns ICE and calls `_on_death`
on the very next line — there is no autoplay, no `elapsed`, and no timing
assertion anywhere in it. Writing the expectation there would mean building an
autoplay harness whose flakiness would exceed its value. The 3.45s is stated
here so nobody later reads a longer campaign as a regression; it is documentation,
not a test. `test_campaign` does still change under this pass, but because
`_on_death` on ICE now writes `Engine.time_scale` (§1), not because of §6.

### Telegraph gaps

Charger windup and ambusher surfacing telegraphs already exist
(`run.gd:2397-2413`), and `_pulse` already rings. What is missing: a link line
from a support enemy to what it is buffing, and a brief aim tell before
`_fire_hostile`.

## Testing

New suites, added to `SUITES` in `tools/run_tests.sh`:

- **`test_feel`** — trauma decays to zero; **stacked** events (12 detonations,
  ICE + player hit in one frame) stay inside `MAX_OFFSET`, since a single event
  proves nothing about the clamp; squaring makes small trauma small; the
  hitstop deadline is asserted in unscaled units; the number pool evicts oldest
  at the cap and prunes on expiry. `noise()` is seeded or injectable, so the
  suite can assert more than a magnitude bound — an unseeded source cannot catch
  a sign flip or an axis-correlation bug
- **`test_synth`** — buffer length is `int(round(duration * SAMPLE_RATE))`, no
  sample exceeds ±1, the same spec produces the same buffer twice, the envelope
  ends at silence including for specs whose ADSR needed normalizing
- **`test_audio_events`** — every id the code can generate resolves in the bank,
  enumerated by iterating `VectorKind` rather than comparing static sets; the
  rate limiter drops overflow rather than queueing it
- **`test_prefs`** — out-of-range values clamp; a **non-dictionary** `prefs`
  yields defaults instead of aborting `_sanitise`; a per-key Dictionary, Array,
  **`null`, `NAN` and `INF`** each do the same; **`{"version": null}` does not
  abort `_read`**; a v2 file loads with default prefs; `set_pref` rejects
  non-finite input rather than clamping it; a round trip preserves what was set;
  and `salvage` / `kills` / `flips` survive the same hostile values. Every one of
  these drives `SaveGame.load_state()` against a written file, not a constructed
  dictionary — the failure mode is a script error inside `_sanitise`, which only
  the real path reaches.

  **Each case must reset `SaveGame._cache = {}` first** (the idiom at
  `tests/test_meta.gd:118`). `load_state()` returns the cache when it is
  non-empty, so without the reset every case after the first short-circuits and
  the suite asserts nothing at all while reporting PASS — the precise failure
  class `tools/run_tests.sh` was written to catch, arriving by a route it
  cannot see
- **`test_input`** — every action the code references exists in the map; the
  overlay is drivable by **joypad** events as well as key events; `cancel`
  routes correctly through all five arms; `user_paused` gates the tick and is
  not cleared by a card or fusion decline
- **`test_hud`** — the blocks exist and populate; the node names `ui.gd` indexes
  without `.get` are pinned; the summary reports a finished run and one that
  ended with fewer than three exploits
- **`test_arrivals`** — an arriving boss is skipped by the grid; **does not move
  after `_step2_integrate`**; does not spawn hostile shots; **leaves
  `player_health` unchanged with a PULSE mini-boss arriving in line of sight**;
  takes no damage and gains no corruption **while placed on a HAZARD and on a
  CORRUPTION tile** (on clean terrain the case passes regardless); becomes live
  when the timer ends; `_arriving` is zeroed on a spawn-recycled slot; **the
  timer follows the boss when a lower-indexed enemy dies and `_step9_recycle`
  compacts the tail**; **and it follows the boss through the second despawn site
  too — an enemy removed by `_step2d_collapse` while a mini-boss is arriving**

Additional coverage in existing suites:

- **`test_run`** — the death path sets `Engine.time_scale` to `0.05`
  **and then** back to `1.0` once the wall-clock deadline passes. Both
  assertions, in that order: the second alone passes whether the hitstop fired
  or was cancelled at birth. Also that the composed camera position is finite
  (cheap insurance against a NaN reaching `run.gd:551` and blanking the screen),
  and that effects keep aging after death, which is what `_age_fx` moving above
  the guard buys

Non-suite consumer that changes with them: **`tools/shot_cards.gd`**, whose
`_key()` helper drives `ui._input` with keycode-only events. It is not in
`SUITES` and nothing will report its breakage.

Existing suites that change: `test_cards_keyboard` (keycode → action matching),
`test_meta_layout` (the §4 settings entry point on the shop screen, plus
indirect breakage through `_refresh`), `test_minibosses` (mini-boss death now
crosses arrival and hitstop, `tests/test_minibosses.gd:138-145`),
`test_behaviour` (calls `_behave` and spawn state directly,
`tests/test_behaviour.gd:50-82`, which the `_arriving` gate now guards), and
`test_campaign` (its `_kill_ice` helper drives `_on_death` on ICE directly, which
now writes `Engine.time_scale` — see §1; it does **not** gain a timing
assertion, for the reason given in §6).

`perf_milestone0` must stay green. The per-frame additions are the flash decay,
the number pool and the skip-mask union, all O(n) over the enemy cap.

### Documentation sweep

The pass takes the suite count from 29 to 36. Four places hardcode "26 suites"
and are already stale: `CLAUDE.md:12`, `codemaps/architecture.md:29`,
`codemaps/architecture.md:117`, `codemaps/ui.md:116`.

CLAUDE.md's invariants section also gains the swap-relocation half of the
per-enemy-array rule. It currently documents reset-on-spawn only, which is
exactly the half an earlier draft of this spec cited while missing the other.

## What this pass does not do

- No music
- No new mechanics, enemies, modules or balance changes
- No graphical HUD — it stays text
- **No change to the ON_HIT gate at `run.gd:1580`**, despite it appearing to
  have the same cross-pass bug as the hit-flash window. It alters combat
  behaviour and deserves its own decision.
- **No fix for the save-quarantine name collision.** `save_game.gd:103` renames
  both `PATH` and `BAK` to the same `save.json.v<N>`, so the second overwrites
  the first. Pre-existing; reachable only by running an older build after this
  one. Noted because this pass is what bumps `VERSION`.
- No refactor of `run.gd` beyond the §0 presentation split and moving feel state
  into `feel.gd`. The file is 2438 lines and that is a real problem, but solving
  it is not this pass.
