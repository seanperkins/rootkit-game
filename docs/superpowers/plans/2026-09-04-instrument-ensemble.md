# Instrument ensemble implementation plan

Date: 2026-09-04. Status: implemented; automated checks pass, human listening remains unverified. See [implementation and measurements](../../progression-bosses-music.md). The mechanism
question is resolved — the user kept the action/event-driven ensemble after
reviewing the prior-art research, rejecting both the census/population-layer
alternative and a population-plus-accents hybrid for this pass. Remaining
tuning constants (`CHASE_JOSTLE_FORCE`, `FLANK_COMMIT_BIAS`) and the `v`-bar
diatonic-vs-special-cased voicing choice are recommended defaults to
validate in the listening pass below, not blocking decisions.

Spec: [Instrument ensemble](../specs/2026-09-04-instrument-ensemble-design.md).
Overview: [Ideas review](../specs/2026-09-04-ideas-proposals-design.md)
("Music ensemble" + "Review input before the music spec is written").
Research: [Instrument ensemble research](../specs/2026-09-04-instrument-ensemble-research.md)
(preserved, reviewed in the spec, not adopted).

## Ownership and prerequisites

Per the overview's implementation order, this is item 3 ("build the music
pipeline independently of simulation timing; integrate event hooks with
explicit presentation/hash classification"), sequenced before item 4 (bosses,
teleporter/votes). It is **not** independent of the boss work at the source
level: `_charge`, `_flank`, `_support`, `_ambush`, `_fire_hostile`,
`_relocate_enemy`, `_clear_ai`, `_spawn_enemy_state`, and the `STATE_FIELDS`
per-enemy loop are exactly the functions the themed-boss plan also touches
(Root Cause composes AMBUSHER/RANGED/CHARGER attack patterns; the worm boss
extends segment bookkeeping; the spire boss adds new per-boss state). A
single integration owner must serialize edits to these functions against the
boss plan rather than have both land concurrently; this plan's edits are
additive (new fields, new call sites at named existing lines, nothing
removed or restructured), which keeps the merge surface small but does not
remove the need to coordinate. No shared-file writes between agents editing
`run.gd` at the same time.

## Implementation sequence

1. **`scripts/audio/synth.gd`: seven new spec families, gated vibrato.**
   - Add `vibrato_rate` (Hz, default `0.0`) and `vibrato_depth` (fractional,
     default `0.0`) to `DEFAULTS`. In `build()`'s per-sample loop, apply the
     modulation **only when `vibrato_depth != 0.0`**: skip the `sin()` call
     and the extra multiply entirely for every existing spec (all default to
     `0.0`), so current output is unaffected and no default-path cost is
     added. Verify with a throwaway script hashing a handful of existing
     `EVENTS` buffers pre/post-change — not a permanent test, since the
     existing behavior is not new behavior.
   - Add **seven** new spec entries (one per timbral role: `voice_chase`,
     `voice_charger`, `voice_flanker`, `voice_support`, `voice_ambusher`,
     `voice_ranged`, `voice_player` — not ten, and not four separate player
     entries), each `"steps": [0]` (a single-entry pool: no random pitch
     jitter, since pitch for these six comes from a computed runtime
     `pitch_scale`, never from `build_bank()`'s per-play random variant
     pick — see spec's "Variant pitch neutrality"). Merge into `all_specs()`
     the same way `FIRE_SPECS` is merged today (a third source, not a
     replacement of `EVENTS`/`FIRE_SPECS`). Corrected timbre per the spec:
     `voice_ambusher` uses `Wave.SQUARE` (not SINE); `voice_player` is the
     only one using the new vibrato fields. Measure the boot-time delta
     `build_bank()` adds (seven more ids × `VARIANTS` (6) buffers) against
     the existing ~1s budget in the smoke pass; do not silently accept a
     regression.
2. **`scripts/run/feel.gd`: a ten-bit integer mask, not a growing queue.**
   - Add `const VOICE_COUNT := 10` and an ordered `const VOICE_IDS := [
     "voice_chase", "voice_charger", "voice_flanker", "voice_support",
     "voice_ambusher", "voice_ranged", "voice_player", "voice_player",
     "voice_player", "voice_player"]` (indices 6–9 all name the same spec —
     the shared player family — distinguished only by the runtime pitch
     `music.gd` applies per slot). Add ten named index constants
     (`VOICE_CHASE := 0`, …, `VOICE_PLAYER0 := 6`, … `VOICE_PLAYER3 := 9`)
     so call sites use compile-checked constants, not string literals.
   - Add `var voice_pending: int = 0`, used as a bitmask.
     `func emit_voice(idx: int) -> void`: `voice_pending |= 1 << idx` — a
     plain integer OR, no allocation at all, "first wins" enforced at the
     write site (a second emit for an already-set bit this window is a
     no-op).
   - Add `func drain_voice() -> int`: capture, zero, return —
     `var m := voice_pending; voice_pending = 0; return m`. Called
     **unconditionally every** `music.gd._on_step()` regardless of pause,
     mute or run state, so nothing ever accumulates; whether the returned
     mask is actually played is decided entirely on the consumer side (see
     step 4). Drain-and-discard is also used at lifecycle boundaries;
     periodic draining alone does not exclude between-step stale bits.
     Keep the existing `sfx`/`emit`/`drain_sfx()` path unchanged.
3. **`scripts/run/run.gd`: new per-enemy latches and seven emit call sites.**
   - Declare `_chase_jostling: PackedByteArray` and `_flank_arcing:
     PackedByteArray` beside `_ai_phase`/`_submerged` (~line 237-239);
     allocate/resize alongside the existing `_ai_phase = PackedInt32Array();
     …` block (~line 1468-1470).
   - `_clear_ai` (~line 3218): reset both to `0`. `_relocate_enemy` (~line
     3244): carry both from `last`. Both alongside the existing
     `_ai_phase`/`_submerged` lines already there — do not create a second
     "reset" or "relocate" site. Also zero both explicitly in `_after_restore`
     and on resuming from a full (solo) pause (see spec's manifest section).
   - **Do not** add either array to `STATE_FIELDS`: both are
     presentation-only (nothing reads them back into the deterministic tick;
     only the emit-decision itself does, and that decision only sets a
     presentation bit) — see spec's "Deterministic event state vs.
     presentation fields" for the reasoning that distinguishes this from
     `_ai_phase`'s hashed group. Add them to `NOT_IN_MANIFEST` with a
     one-line reconstruction rule matching the existing dictionary's style
     (e.g. "presentation: gates `feel.emit_voice` only, re-derived by its
     own edge check, explicitly cleared on restore").
   - `_step4_steer()` (~line 2698-2729): capture `push` in its own edge
     check **before** the `enemies.force[i] = push * 2.2 +
     terrain.avoid(...)` assignment — measure `(push * 2.2).length()`
     specifically, not the composite `enemies.force[i]` (which also
     includes wall-avoidance and would false-trigger a wall-pinned enemy
     with no neighbours). Gate on
     `enemy_types[enemies.type_index[i]].behaviour ==
     EnemyTable.Behaviour.CHASE`; on that condition, compute `var over :=
     (push * 2.2).length() > CHASE_JOSTLE_FORCE`, call
     `feel.emit_voice(Feel.VOICE_CHASE)` only when `over and not
     _chase_jostling[i]`, then `_chase_jostling[i] = over`.
   - `_charge()` (~line 3346-3372), `CH_WINDUP` branch: beside `_ai_phase[i]
     = CH_DASH`, add `feel.emit_voice(Feel.VOICE_CHARGER)`.
   - `_flank()` (~line 3514-3529): after computing `speed_frac`, compute
     `var arcing := speed_frac > FLANK_COMMIT_BIAS`, call
     `feel.emit_voice(Feel.VOICE_FLANKER)` only when `arcing and not
     _flank_arcing[i]`, then `_flank_arcing[i] = arcing`.
   - `_support()` (~line 3447-3462): capture `var before :=
     enemies.integrity[j]` ahead of the existing `minf` write; after it,
     `if enemies.integrity[j] > before: feel.emit_voice(Feel.VOICE_SUPPORT)`.
   - `_ambush()` (~line 3491-3496), `AM_SURFACING` branch: beside
     `_ai_phase[i] = AM_ACTIVE`, add `feel.emit_voice(Feel.VOICE_AMBUSHER)`.
   - `_fire_hostile(from)` (~line 3408-3414): **inside** the existing
     `if h >= 0:` branch (alongside `_hostile_life[h] = 4.0`), add
     `feel.emit_voice(Feel.VOICE_RANGED)` — not unconditionally at function
     entry, since `hostiles.spawn(...)` returns `-1` and drops the shot
     when `MAX_HOSTILES` (200) is full; emitting regardless would sound a
     shot that never fired.
   - `_emit_vector(ei, r)` (~line 2782-2787): beside the existing
     `feel.emit(Synth.fire_id(r.vector_kind))`, add
     `feel.emit_voice(Feel.VOICE_PLAYER0 + owner)`.
4. **`scripts/audio/music.gd`: consumer, aggregation, harmony, declick.**
   - Add 10 dedicated `AudioStreamPlayer`s in `_ready()`, indexed 0–9,
     alongside (not replacing) the existing 8-player pool used by
     bass/pulse/offbeat/arp/pedal/tick. Players 6–9 (the player slots) all
     draw from the same `voice_player` buffer family in `Synth.build_bank()`
     — one shared pool of `VARIANTS` (6) buffers, not four.
   - In `_on_step()`: call `feel.drain_voice()` **unconditionally, every
     call**, regardless of pause/mute/run state — this is what keeps the
     mask from ever accumulating a backlog, since `_step_world()` keeps
     setting bits even while the music bus is muted. Whether the drained
     mask is **played** is a separate per-bit check, evaluated every call:
     play only when the music bus is not muted
     (`not AudioServer.is_bus_mute(AudioServer.get_bus_index(BUS))`) **and**
     the run is active and not frozen by a shared offer or a solo pause.
     Read the actual run/session APIs rather than assuming fields named
     `solo`/`ended` exist directly on `run`. A local co-op pause menu
     does not freeze the shared world or gate ensemble playback.
     Otherwise discard the drained mask. Also clear pending bits on
     restore, binding/rebinding, both sides of mute/re-enable and true
     pause/resume, and run end before `_process`'s early return. A muted
     event between beat steps must never leak through on unmute.
   - **Named attribution policy for a rare multi-step catch-up burst, not
     claimed as fully correct**: during a hitch that makes the existing
     `_process` while-loop call `_on_step()` more than once, the first call
     in that burst drains everything pending and the remaining calls in
     the same burst find nothing new and play no new voice notes for those
     steps — dropped, not backdated to a step they did not occur in.
     Document this explicitly in a code comment; do not claim per-step
     correctness the mechanism does not provide.
   - Pitch, shared by all six pitched voices (five enemy + the player
     family): compute `target_semis` from the bar's already-computed `root`
     plus that voice's fixed scale-degree offset (recommended defaults:
     player slots 0–3 → `root+0`/`root+2`/`root+4`/`root+7` degrees; five
     enemy voices → one fixed degree offset each per the spec's register
     table) through `_hz`-equivalent math, then set
     `AudioStreamPlayer.pitch_scale = pow(2.0, (target_semis -
     reference_semis) / 12.0)` before `.play()`. Recomputed fresh from the
     current bar every play — never a baked absolute pitch. CHASE stays
     unpitched (`NOISE`), no pitch computation.
   - **Declick treatment, uniform, no per-voice fade exception**: a
     delayed-restart fade (ramping volume down before restarting) delays
     the new note's audible onset by the fade window — an audible late
     attack against the beat grid, rejected outright. Instead bound every
     pitched and unpitched voice's **actual rendered duration** —
     `nominal_dur * 1.06` (maximum of `0.94 + 0.12 * spread`,
     with `spread` in [0,1]) `/ min_pitch_scale` (lowest runtime
     pitch across every bar/slot it can play at) — comfortably under one
     beat step (`60/BPM_HOT*0.5` ≈ 0.242s at `BPM_HOT`), including
     SUPPORT/tuba: its "sustaining, generous" character is read through a
     slower attack/release *shape* within that bound, not a longer absolute
     duration. Verify audibly (step 6); do not ship unverified.
5. **Coverage: functional bank-ID coverage, no incidental structural pins.**
   - Add a small test asserting every string in `Feel.VOICE_IDS` resolves
     in `Synth.build_bank()` — the same "verify against the bank, don't
     hand-list" property `tests/test_audio_events.gd` already checks for
     `EVENTS`/`FIRE_SPECS`/`HIT_SOUNDS`. Assert the functional property
     only (every id used actually has a bank entry); do not pin incidental
     implementation details as a separate contract — not the exact count of
     spec families, not the literal index-to-string layout, not which
     indices happen to share a string. Those are implementation choices
     this plan documents, not observable behavior a consumer depends on.
   - Rely on the existing `tests/test_manifest.gd`'s already-generic
     structural sweep (fails on any var in neither `STATE_FIELDS` nor
     `NOT_IN_MANIFEST`) to cover `_chase_jostling`/`_flank_arcing` by
     construction once they are declared correctly in source — do not add
     a new test that specifically pins their list membership; that is
     re-asserting source text, not a behavior a plausible bug could break
     independently of the existing sweep.
   - Add a small, headless-testable check for the tertian-pitch arithmetic
     only: the three worked triad qualities (minor/major/diminished) for
     the three distinct `PROGRESSION` roots, and that every player-slot and
     enemy-voice offset resolves to a member of `SCALE` on every bar.
     Extract this arithmetic into a standalone function callable without a
     scene tree if `music.gd`'s current shape does not already allow it; do
     not test through `AudioStreamPlayer` playback, and do not assert the
     exact tuning constants (`CHASE_JOSTLE_FORCE`, `FLANK_COMMIT_BIAS`, or
     specific enemy-voice degree assignments) as if they were locked —
     those are recommended defaults pending the listening pass.
6. **`tools/run_tests.sh`, then the windowed listening acceptance pass.**
   Run the full repository test runner (not `--fast`) after the source
   edits above land, so the perf gate is exercised — the new per-tick work
   in `_step4_steer` (an added behaviour check and edge comparison per
   enemy) and `_flank` (an added comparison per flanker) sits in the exact
   hot path the gate measures, and a regression there must be caught, not
   assumed away. Fix any failure before proceeding; do not re-pin the gate
   to accommodate a regression without a stated reason. Then launch `godot`
   windowed (not `--headless`) with a fresh and a leveled save, solo and a
   2-player local/loopback session if available, and walk every scenario in
   the spec's Acceptance section in order, including the declick check
   (item 10) and the two follow-up-choice judgments (item 8: `v`-bar triad
   quality; item 9: corrected SUPPORT/AMBUSHER timing). Record the observed
   cadence of CHASE/FLANKER against the starting threshold constants and
   adjust them if the listening pass shows a metronome, rather than
   treating the constants as final because they compiled.
7. **Cleanup.** Regenerate `codemaps/audio.md`/`codemaps/combat.md` through
   the established generation process (do not hand-edit the generated
   files). Remove any disposable pre/post hashing script from step 1.
   Update `CLAUDE.md`'s invariants list only if the listening pass surfaces
   a new load-bearing rule in the same shape as the existing entries (e.g.
   if the `NOT_IN_MANIFEST` classification of the two new latches turns out
   to need the same explicit callout `_hit_flash` already gets) — do not
   add prose that merely restates this plan.

## Verification scenarios

| Scenario | Observable requirement |
|---|---|
| Existing combat SFX | Identical timing/behavior to the current build; new voices add nothing to the existing immediate `sfx.gd` path |
| CHASE measured correctly | Trigger reads the separation `push` term alone, not the wall-avoidance-inclusive composite force; a wall-pinned, neighbour-free enemy never fires it |
| RANGED gated on success | No voice note when `hostiles.spawn(...)` returns `-1` (pool full) |
| CHASE/FLANKER edge vs. level | Per-enemy latch prevents re-fire on every tick while sustained above threshold; aggregate cadence recorded and tuned against the named constants |
| Shared harmony, all pitched voices | No note outside `SCALE` on any of the 4 `PROGRESSION` bars, for the player family and all five pitched enemy voices, in solo and multi-slot sessions with staggered fire |
| One shared player buffer | Exactly one `voice_player` spec/buffer family in the bank; four distinct runtime pitches, not four baked buffers |
| Telegraph precedence | CHARGER/AMBUSHER ensemble notes audibly follow, never precede or replace, the existing visual tell |
| Effects budget and declick | 10 dedicated players never steal from each other or from the existing 8; a self-retriggered sustained note (SUPPORT) shows no audible click under the chosen treatment |
| Manifest correctness | Presentation latches and pending bits never affect simulation hashes; restore clears them. Periodic discard plus explicit lifecycle clears prevent stale notes even between beat steps or before an early return |
| Pause/mute gating | A co-op peer's own `user_paused` (non-solo) never silences the shared ensemble; an all-party freeze or solo pause does; a muted bus silences playback every step it stays muted, with no backlog audible on unmute |
| Attribution policy | A forced multi-step catch-up burst plays new voice notes only on the first step of that burst, silently on the rest — matching the documented policy, not silently wrong |
| Boot cost | `build_bank()`'s cache-build time delta (seven new families) measured and reported, not assumed negligible |
| Full test runner | `tools/run_tests.sh` (not `--fast`) passes, perf gate included, after all source edits |

No code, build, audio-listening, or multiplayer verification is claimed by
this plan itself — it names the evidence required; producing that evidence
is the implementation pass's job, per the overview's closing line.
