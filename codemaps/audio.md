> Generated: 2026-09-05 | Token-lean format for LLM context

# Audio and feel

Every sound in the game is synthesized in code at boot. No `.ogg`, no `.wav` on
disk — the same rule that keeps image assets and font files out of the repo.

Direction of coupling: **the simulation never holds a node reference.** `run.gd`
appends event ids to `feel.sfx` and forgets; the Sfx node drains that list. The
Music node polls `run.threat()`. Both are the reverse of what a naive hookup
would do, and it is what keeps the tick reachable in a headless suite.

```
run.gd ──emit(id)──> feel.sfx ──drained by──> sfx.gd ──> Synth.build_bank()
run.gd <──threat()── music.gd ──> Synth.build(note spec)
```

## `scripts/run/feel.gd` — `Feel`, PURE `RefCounted`

Shake trauma, damage numbers, directional impact bursts, per-slot recoil and
the outbound event list. No scene tree,
no engine calls, no clock.

**Hitstop is not here any more.** It is part of the deterministic tick:
`run.hitstop_ticks` (`SessionRules.HITSTOP_TICKS = 4`) freezes the world for
a fixed number of ticks above the guard, the same ticks on every peer.
Nothing writes `Engine.time_scale`; `test_determinism_rules` greps for it.

| Const | Value | Note |
|---|---|---|
| `MAX_OFFSET` | 26.0 | peak camera displacement at trauma 1.0 |
| `TRAUMA_DECAY` | 1.6 | per second |
| `NUMBER_CAP` | 24 | oldest evicted |
| `NUMBER_LIFE` | 0.75 | pruned in `step` |
| `IMPACT_CAP` / `IMPACT_LIFE` | 24 / 0.24 s | oldest evicted; presentation only |

`offset = MAX_OFFSET * trauma² * noise()`. Squared so one tunable covers a nudge
and a slam; trauma is **clamped to 1.0** or overlapping events exceed the
constant that names the bound. `noise()` returns magnitude ≤ 1 (not independent
axes, which would put the diagonal outside it) and is injectable for tests. The
`shake` preference multiplies the composed offset in `run.gd`, outside the
square.

API: `add_trauma`, `shake_offset`, `add_number`, `add_impact`, `kick(slot)`,
`emit(id)`, `drain_sfx`,
`step(unscaled_dt)`, `set_noise(callable)`. `NUMBER_RISE 42.0`.
`impacts` carries origin/direction/hue/life/destruction; `recoil` has one value
per player, set to 1 by `kick` and decayed at 9/s above the world guard.
Neither is simulation state or a new audio voice.

## `scripts/audio/synth.gd` — `Synth`, PURE `RefCounted`

Builds `AudioStreamWAV` (a `Resource`, hence pure) from a spec dictionary.

| Const | Value |
|---|---|
| `SAMPLE_RATE` | 22050 (16-bit signed PCM, mono) |
| `VARIANTS` | 6 buffers per event id |
| `TABLE_SIZE` / `BASE_HZ` / `BANDS` | 2048 / 55.0 / 6 |

Spec keys: `wave` (SINE/SQUARE/SAW/NOISE), `f0`, `f1` (swept), `dur`, `attack`,
`decay`, `sustain` (level), `release`, `noise`, `gain`, `steps`.

**Band-limited oscillators.** Square and saw are summed from the harmonics that
fit under Nyquist, as a wavetable per octave band. The naive forms carry
harmonics to infinity and everything above Nyquist folds back as *inharmonic*
partials that do not track a pitch sweep — audible as grit, and a bug rather
than a lo-fi aesthetic. Summing per SAMPLE is correct and took 12 s to build the
bank; the tables take ~0.95 s. `test_synth` measures the slew against an actual
naive oscillator rather than a chosen threshold.

**Variation pools.** One buffer plus pitch jitter is still one buffer and the ear
locks onto it — the failure every game-audio source warns about. `steps` is an
array of SEMITONE offsets cycled per variant; detuning by a few percent is
inaudible on a 40 ms blip, and the per-variant noise reseed does nothing for a
pure tone. `test_synth` checks **all** ids for distinct variants; checking a
sample of three is what let every fire sound ship with 6 variants collapsing to
3.

`build_bank()` is cached in a **static** — with no autoloads it otherwise rebuilt
on every `./intrude`, a ~1 s hitch exactly when the player expects the game to
start. Fire ids derive from `Module.VectorKind` (append-only), so a new vector
kind cannot mint an id the bank has never heard of.

## `scripts/audio/sfx.gd` — the only part that touches the tree

`ensure_bus()` guards on `get_bus_index("SFX") < 0`, then `add_bus` +
`set_bus_name` (`add_bus` takes an index, not a name). There is no `[audio]`
section that declares buses, and "at boot" is wrong with no autoloads and a
shell↔run shuttle — so creation is idempotent and safe on every scene entry.

`apply_volume` uses `linear_to_db(maxf(v, 0.0001))` with a mute branch at zero;
`linear_to_db(0.0)` is `-INF`.

| Const | Value |
|---|---|
| `VOICES` | 16, round-robin, pitch jitter 0.94–1.07 |
| `RATE_LIMIT` | hit_light/medium/heavy 11, kill 12, pickup 7, flip 8 |
| `DEFAULT_RATE` | 20.0 |

The limiter is load-bearing, not polish: 600 enemies and a magnet radius produce
hits and pickups by the hundred per second, and played faithfully that is white
noise. Overflow is **dropped**, never queued.

### Event ids

Fire (one per `VectorKind`), `hit_light` / `hit_medium` / `hit_heavy`, `kill`,
`flip`, `pickup`, `level_up`, `card_select`, `card_decline`, `hurt`,
`low_integrity`, `miniboss_charge`, `miniboss_arrive`, `miniboss_kill`,
`ice_charge`, `ice_arrive`, `ice_kill`, `gate_open`, `collapse`, `win`, `death`.

Hit weight comes from `run._hit_weight[type]`, resolved once at boot from the
type's **base** integrity (the table falls into 6–16 / 34–70 / 170–700). Base,
not spawn HP: solidity is what a thing is, and scaling by subnet would make
every daemon sound like a boss by subnet 03.

`test_audio_events` greps `run.gd` for emit sites rather than keeping a list —
and separately parses `HIT_SOUNDS`, because an id reached through a lookup table
is invisible to a grep for `feel.emit("literal")`.

## `scripts/audio/music.gd` — generative, no loops

There is no track and no stems. A beat clock runs at eighth notes; on each step
it asks `run.threat()` what is happening and decides what to sound. The player
never hears a transition because there is nothing to transition between.

| Const | Value |
|---|---|
| `ROOT_HZ` | 55.0 (A1) |
| `SCALE` | `[0, 1, 3, 5, 7, 8, 10]` — Phrygian; the ♭2 reads as menace |
| `PROGRESSION` | `[0, 0, 5, 4]` — i–i–VI–v, deliberately unresolved |
| `BPM_CALM` / `BPM_HOT` | 88 / 124 |
| `STEPS_PER_BAR` / `VOICES` | 8 / 8 |

| Layer | Gate |
|---|---|
| bass | always (bar line) |
| pulse | threat > 0.12, quarter notes |
| offbeat | threat > 0.55 |
| arp | threat > 0.32; density every 4th → 2nd → every eighth |
| pedal | `run.boss_present()` — a **tritone**, outside the scale on purpose |

Threat and BPM are sampled at **bar lines only**: threat swings every tick as the
swarm dies and respawns, and a continuously-lerped BPM audibly warbles.
`run.threat()` is not merely enemy count — a cleared subnet with a hundred
stragglers returns 0.08, a live boss floors it at 0.78.

Because the SFX step through the same scale, a pickup or a hit lands on a chord
tone rather than beside it.

## Preferences

`volume_master`, `volume_sfx`, `volume_music`, `shake` (0–2, zero supported),
`damage_numbers`. Stored in `save.json` v3, clamped on both read and write —
see `codemaps/data.md`. UI in `scripts/meta/settings_panel.gd`, shared by the
shell and the pause panel.

## Suites

`test_feel`, `test_synth`, `test_audio_events`, plus the hitstop-tick
cases in `test_run`.
