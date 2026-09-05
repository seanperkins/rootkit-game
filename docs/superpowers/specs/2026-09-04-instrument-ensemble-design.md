# Instrument ensemble: event-driven, beat-quantized voices

Date: 2026-09-04. Status: **mechanism decided** — the user reviewed the
prior-art research summary and chose to keep the action/event-driven
ensemble, rejecting both the research's census/population-layer alternative
and a population-plus-accents hybrid for this pass. The approved mapping,
bounded producer-side events, shared-harmony pitch mechanism, and the ten
explicit logical voices below are the approved direction. Exact tuning
constants (`CHASE_JOSTLE_FORCE`, `FLANK_COMMIT_BIAS`, the `v`-bar diatonic-
vs-special-cased voicing) are recommended defaults to validate in the
listening pass named in Acceptance — tuning inputs, not blocking questions.

Source of the approved design: `docs/superpowers/specs/2026-09-04-ideas-proposals-design.md`
("Music ensemble" section, including its "Review input before the music
spec is written" subsection). That subsection raised the
event-driven-vs-census mechanism question and the census/polling
alternative in `2026-09-04-instrument-ensemble-research.md`; both are
reviewed below for their genuine findings (folded in as fixes) but the
mechanism itself is resolved — event-driven, as this document specifies.

Verified against `scripts/audio/synth.gd`, `scripts/audio/music.gd`,
`scripts/audio/sfx.gd`, `scripts/run/feel.gd`, `scripts/run/run.gd`
(`_step4_steer`, `_behave`, `_charge`, `_flank`, `_support`, `_ambush`,
`_ranged`, `_fire_hostile`, `_step5_fire`, `_emit_vector`, `threat`,
`boss_present`, the `STATE_FIELDS`/`NOT_IN_MANIFEST` manifest, `_relocate_enemy`,
`_clear_ai`, `_spawn_enemy_state`), `scripts/run/spawn_director.gd`
(`MINIBOSS_TIMES`, `MINIBOSS_IDS`), `scripts/combat/population.gd` (`spawn`
returns `-1` on a full pool), `data/enemy_table.gd`, `data/session_rules.gd`,
and `codemaps/audio.md`/`codemaps/combat.md`/`codemaps/architecture.md`
(cross-checked against source directly where a codemap value turned out
stale — see the `MINIBOSS_TIMES` correction below).

## Approved design (from the overview, restated for reference)

| Voice | Timbral direction | Event |
|---|---|---|
| CHASE | Brushed hi-hat/shaker | Separation steering engages |
| CHARGER | Trombone | Windup commits to dash |
| FLANKER | Muted trumpet | A meaningful flank commitment |
| SUPPORT | Tuba | Actual healing |
| AMBUSHER | Bass clarinet | Surfacing |
| RANGED | Trumpet | Shot emission |
| Players 0–3 | Saxophone, distinct registers | Weapon emission |

One note slot per voice per beat subdivision (the existing 8-step bar); the
first qualifying event in that window wins, the rest are dropped, not
queued. Combat timing is independent of playback quantization — no approval
exists to delay weapon damage or enemy attacks until a musical beat, and
nothing in this design does. **Seven timbral roles, ten logical voices**:
seven synthesized instrument buffer families (six enemy voices plus one
shared saxophone family for players), routed into ten independent
first-wins claim slots at the aggregation layer (six enemy slots plus one
per LIVE player slot). The four player slots are not four separate
instrument specs — they are one shared buffer family played through four
distinct claim slots at four distinct runtime pitches. Brass/reed names
describe synthesized approximations built from the existing oscillator set,
not acoustic samples.

## Corrections to prior claims about `Synth`

Read in full: `scripts/audio/synth.gd`. Three claims in the earlier proposal
do not match what the engine can do today:

1. **There is no vibrato/LFO capability.** A spec's `f0`/`f1` is a single
   linear sweep across the note's duration (`build()`'s per-sample loop:
   `freq = lerpf(f0, f1, t)`), computed once per sample with no periodic
   term. "SAW summed with a slow vibrato LFO" for the sax voice is new work:
   a periodic frequency modulation added to that per-sample `freq` before
   the phase increment — **gated behind a nonzero `vibrato_depth`**, so
   every existing spec (`depth` defaulting to `0.0`) pays no extra `sin()`
   call and produces bit-identical output to today; do not compute the
   modulation term unconditionally for every sample of every sound in the
   bank just because ten new specs need it. Portamento (the trombone's
   "short rising pitch bend") is NOT new — that is exactly what `f0 → f1`
   already does, used throughout `EVENTS` today (e.g. `miniboss_charge`:
   120 → 760).
2. **`Wave.SINE` has zero harmonics.** It is `sin(phase)`, full stop — see
   the `match` in `build()`. "SINE fundamental + odd harmonics only" for the
   bass clarinet is not producible with a SINE spec; there is no per-partial
   harmonic-mix parameter for any wave. The already-existing `Wave.SQUARE`
   oscillator, by contrast, IS built from odd harmonics only
   (`_build_table`'s `step := 1 if wave == Wave.SAW else 2`, i.e. SQUARE and
   SINE both take `step=2`, but only SQUARE's table actually carries
   harmonic content to sum). SQUARE is the closest available approximation
   to a hollow, clarinet-like spectrum — not a physically exact one; real
   clarinets are odd-harmonic-**dominant**, not odd-harmonic-**exclusive**,
   so "SQUARE approximates the odd-harmonic character" is the honest framing,
   not "this is what a clarinet is."
3. **`steps` cannot address a voice by identity.** The proposal's line "the
   transposition table is free (`Synth`'s `steps` variant mechanism already
   jitters by semitone)" does not fit this use case. `steps` is a per-event-id
   pool of pitch *variants*, and `sfx.gd`'s `play()` picks one **at random**
   per play (`pool[_rng.randi() % pool.size()]`) purely for anti-repetition.
   It cannot guarantee "slot 0 always plays root, slot 1 always plays +5" —
   that needs a deliberate runtime pitch computed per play, not random
   selection from a fixed pool (see "Player and enemy pitch" below).

None of this needs a new oscillator type — the approved design's "no new
oscillator types needed" framing holds, and it needs only **seven** new
`Synth` spec entries (one per timbral role), not ten: a corrected timbre
choice for one voice (SQUARE, not SINE, for the clarinet-like AMBUSHER), a
new gated periodic-modulation spec field (vibrato) for the shared player
sax family, and one shared player-sax family reused by all four slots via
runtime pitch, not four separate baked specs.

## Current architecture this plugs into

`codemaps/audio.md` states the direction of coupling: the simulation never
holds a node reference. `run.gd` appends string ids to `feel.sfx`
(`Feel.emit`); `sfx.gd` drains and plays them immediately, rate-limited per
id. `music.gd` runs a separate, audio-only beat clock — driven by the
**frame** delta (`_process(dt)`), not the simulation tick — that polls
`run.threat()`/`run.boss_present()` once per bar line and decides what to
layer. Neither consumer is referenced by `run.gd`; both only read from it.
This design keeps that shape, with the producer side bounded rather than an
unbounded append log:

- **Fixed, bounded producer state, not a growing queue.** `Feel` gets a
  single `voice_pending: int` used as a ten-bit mask (a `VOICE_COUNT := 10`
  constant names the bit count), plus an ordered `VOICE_IDS` array mapping
  each of the ten bit indices to the `Synth` spec id it plays (indices 0–5
  map to the six distinct enemy spec ids; indices 6–9 all map to the
  **same** `"voice_player"` spec id, distinguished only by the runtime
  pitch chosen at play time). `run.gd`'s deterministic tick calls
  `feel.emit_voice(idx: int)`, which sets `voice_pending |= (1 << idx)` —
  a plain integer OR, no allocation at all (not even a packed-array copy),
  "first wins" enforced at the **producer** rather than reconstructed later
  by a consumer-side dictionary. A second same-voice event later in the
  same window is a no-op bit-OR, not an appended entry. Using integer bit
  indices (`Feel.VOICE_CHASE`, etc.) rather than string literals also means
  a typo'd call site is a compile-time error, not a silently-no-op'd
  string — an improvement over the existing `feel.emit(id: String)` path's
  failure mode. Combat feedback (`hit_light`, `fire_N`, `kill`, …) keeps
  using the existing immediate `sfx`/`emit`/`drain_sfx()` path unchanged —
  nothing about this design touches it, satisfying "quantization must not
  delay combat."
- **Consumption drains every step, unconditionally; playback is gated,
  every step, not just at a boundary transition.** `music.gd`'s existing
  `_on_step()` calls `feel.drain_voice()` (`var m := voice_pending;
  voice_pending = 0; return m`) on **every** call, regardless of pause,
  mute or run state — this is what keeps the mask from ever accumulating a
  backlog, since the deterministic tick keeps setting bits even while the
  music bus is muted (muting is a presentation-only volume change; nothing
  about it stops `_step_world()`). Whether the drained mask is actually
  **played** is a separate, per-step check: play only when the music bus
  is not muted (`not AudioServer.is_bus_mute(AudioServer.get_bus_index(BUS))`)
  and the run is active and not under a shared offer freeze or a solo
  pause. Read the actual run/session state APIs during implementation;
  this is a semantic contract, not a claim that a bare `ended`/`solo`
  field exists on `run`. A local co-op menu does not freeze the world.
  Drain-and-discard while muted, but also clear the mask at lifecycle
  boundaries below: an event can arrive after the final muted step and
  before unmuting, so periodic draining alone cannot exclude stale notes.
- **Explicit, named attribution policy for a rare multi-step catch-up
  burst.** If a hitch makes the existing `_process` while-loop call
  `_on_step()` more than once in a single frame, the first call in that
  burst drains everything pending since the last real drain and the
  second and later calls in the *same* burst find nothing new (no real
  time passed between them) and play no new voice notes for those steps.
  That is a deliberate, explicit **drop-stale** policy for the extra steps
  in a catch-up burst — not a claim that events are correctly reconstructed
  per-step, and not an invented historical timestamp. It costs at most a
  few silent voice slots during a rare hitch; the existing bass/pulse/
  arp/pedal layers already tolerate the same hitch by their own sampling
  rules.

## Per-voice trigger: exact call site and edge/level semantics

Investigated per the assignment: not every behaviour has a discrete state
machine, so not every trigger can be a bare "this changed" check.

| Voice | Function / site | Semantics | New state needed |
|---|---|---|---|
| CHASE | `_step4_steer()` — measured on the **separation `push` local**, before it is combined with `terrain.avoid(...)` | **Edge**, not level, and measured on the right quantity. `_step4_steer` computes `push` (jostling) and then assigns `enemies.force[i] = push * 2.2 + terrain.avoid(here, player_pos[ts] - here)` — the **composite** includes wall-avoidance steering, which has nothing to do with "jostling in a pack" and would false-trigger an enemy pinned against a wall with no neighbours nearby. Threshold against `(push * 2.2).length()` specifically (the same term already assigned into `enemies.force[i]`'s first addend), not the composite. Also gate on `enemy_types[enemies.type_index[i]].behaviour == EnemyTable.Behaviour.CHASE` (default behaviour for most rows, but not universally true — e.g. `ice`/mini-bosses use CHASE too and must not be excluded, but a CHARGER mid-dash also gets a `push` computed here and must not emit CHASE's note) and on the rising edge of `> CHASE_JOSTLE_FORCE` (recommended starting value below), not level — `push` is computed for **every** enemy within `STEER_RANGE_SQ` of its target, only once every `STEER_SLICES` (2) ticks per enemy (round-robin), and with hundreds of enemies packed together a level trigger reproduces the research doc's measured "metronome" problem. | Yes: `_chase_jostling: PackedByteArray`, sized `MAX_ENEMIES`. |
| CHARGER | `_charge()`, the `CH_WINDUP` branch, exactly where `_ai_phase[i] = CH_DASH` is assigned | **One-shot**, no new state. The phase mutation itself is the once-per-cycle marker — `_ai_phase[i]` cannot pass through `CH_DASH` twice without re-entering `CH_WINDUP` first. Fires at dash launch, i.e. at the end of the existing visual windup tell (`_draw`'s `tell = 1.0 - _ai_timer[i] / CHARGE_WINDUP`), not during it — see "damaging telegraphs" below. | None. |
| FLANKER | `_flank()` | **Edge**, new state entirely. `_flank` has no phase machine at all — it runs every tick, every call, for every flanker, recomputing a steering vector from scratch (confirmed: no `_ai_phase`/`_ai_timer` read or write anywhere in the function). "A meaningful flank commitment" therefore has to be manufactured: use the function's own already-computed `speed_frac` (`clampf(pv.length() / 220.0, 0.0, 1.0)`, currently a local — needs to stay local, just also drive the edge check in the same function) crossing above `FLANK_COMMIT_BIAS` (recommended 0.5) as "the player is moving fast enough that this is a real tangential arc, not just a chase," matching the function's own doc comment. Without an edge latch this refires every tick while sustained above threshold, same failure mode as CHASE. | Yes: `_flank_arcing: PackedByteArray`, sized `MAX_ENEMIES`. |
| SUPPORT | `_support()`, inside the neighbour loop, around `enemies.integrity[j] = minf(_spawn_hp[j], …)` | **Level, deliberately not edge.** Compare `integrity` before and after the `minf` write; emit only when it actually increased (a support standing near an already-full ally does nothing and must not fire). Unlike CHASE/FLANKER this can fire on every qualifying tick while a heal is genuinely landing — the tuba is described as "sustaining, generous," and the per-step aggregator already caps it to one note per beat step. | None new; a before/after compare local to the call. |
| AMBUSHER | `_ambush()`, the `AM_SURFACING` branch, exactly where `_ai_phase[i] = AM_ACTIVE` / `_submerged[i] = 0` is assigned | **One-shot**, no new state, same reasoning as CHARGER. "Surfacing" is the completion of the tell — the `AM_SUBMERGED → AM_SURFACING` edge is the **start** of the visible-but-still-untouchable tell (`_submerged[i]` stays 1 through `AM_SURFACING`); `AM_SURFACING → AM_ACTIVE` is where it actually becomes hittable and resumes chasing. That is the moment that reads as "it surfaced," after the existing visual tell, not instead of it. | None. |
| RANGED | `_fire_hostile(from)`, **inside the `if h >= 0:` branch**, alongside `_hostile_life[h] = 4.0` | **One-shot**, gated on an actual shot existing. `hostiles.spawn(...)` returns `-1` when the `MAX_HOSTILES` (200) pool is full — the spawn is silently dropped, per `Population`'s documented contract. Emitting unconditionally at function entry (rather than only when `h >= 0`) would sound a "shot fired" note for a shot that never actually spawned. Placed here rather than in `_ranged` (its one current caller), so any future enemy type that reuses `_fire_hostile` inherits the correct gating automatically. | None. |
| Player ×4 | `_emit_vector(ei, r)`, beside the existing `feel.emit(Synth.fire_id(r.vector_kind))` | **One-shot**, inherently discrete — one call, one shot, `owner` already decoded at the top of the function (`_owner_slot(ei)`, range 0–3). Only LIVE slots reach this function (`_step5_fire` gates on `_is_live(_owner_slot(ei))` before calling it), so "4 LIVE players" is free. | None. |

## Deterministic event state vs. presentation fields

The manifest draws this line by **whether the deterministic simulation reads
a field back**, not merely by whether the field is computed deterministically
— both `_ai_phase` and the two new latches below are equally tick-
deterministic, and they are classified oppositely for that reason:

- `_ai_phase`, `_ai_timer`, `_ai_aim`, `_submerged` are hashed
  (`STATE_FIELDS`) because the simulation reads them back to make gameplay
  decisions: `_charge` branches its returned velocity on `_ai_phase`,
  `_ambush` does the same, and both feed into `enemies.vel`/position, which
  other hashed state (damage, contact, targeting) then depends on. If two
  peers disagreed on `_ai_phase`, they would disagree on where that enemy
  actually is next tick — a real desync, not a cosmetic one.
- `_hit_flash` is presentation-excluded for a different, additional reason
  on top of "not read back": it also *ages by the variable frame delta*
  inside `_age_fx`, above the guard, so it would diverge peer to peer even
  if something did read it.

The two new per-enemy latches this design adds — `_chase_jostling`,
`_flank_arcing` — are tick-deterministic (computed once, inside the
deterministic step, from already-hashed inputs) but **read by nothing except
the emit-decision that produces them**, and that emit-decision itself only
ever sets a presentation bit (`Feel.voice_pending`). No movement, damage,
targeting, or other hashed field depends on their value. That puts them with
the existing `NOT_IN_MANIFEST` fields that are deterministically computed
but not carried because nothing reads them back — the same shape as
`_enemy_target` ("scratch: decided in `_behave` before any read each tick")
— not with `_ai_phase`'s group. Classify both in `NOT_IN_MANIFEST`:

- Reconstruction rule: not carried; each is fully re-derived by its own edge
  check the next time `_step4_steer`/`_flank` runs for that enemy, and
  explicitly zeroed (`.fill(0)`) in `_after_restore` and on resuming from a
  full (solo) pause — a defensive, purely local reset that costs nothing
  (nothing reads these arrays but the emit-decision) and removes any need to
  reason about whether a locally-stale latch value (unsynced, since it is
  not in the snapshot) matches what the just-restored authoritative state
  implies.
- This is cheaper than hashing, not just as-safe: it avoids adding avoidable
  snapshot/restore surface for state that exists purely to gate a
  presentation-layer bit.

They still need the two existing per-enemy-array disciplines that apply
regardless of hash membership, in the same functions that already maintain
`_ai_phase`/`_submerged`/etc., so a recycled or swap-relocated slot cannot
carry a stale latch onto a different enemy:

- **Reset on spawn** (`_clear_ai`/`_spawn_enemy_state`): a recycled slot must
  not inherit a stale "already jostling"/"already arcing" latch and skip its
  next genuine edge.
- **Relocate on despawn** (`_relocate_enemy(i, last)`): the swap-remove
  invariant `test_arrivals` already asserts structurally for every other
  per-enemy array — this one still needs it for per-enemy correctness even
  though it is unhashed.

`Feel.voice_pending` itself is presentation state for the same "nothing
reads it back into the tick" reason, exactly like the existing `feel.sfx`.
`feel` as a whole is already `NOT_IN_MANIFEST` ("presentation") in `run.gd`'s
manifest dictionary; the new field is simply another entry on that
already-excluded object, not a new carve-out.

## Pause / resync / restore lifecycle

- **Pause** (`paused`, or `user_paused and solo`): every emit call site named
  above sits inside `_step_world()` or a function it calls, all below the
  world guard, so a fully-frozen world (an all-party offer/card screen, or a
  solo player's own pause menu) simply stops setting new bits — the existing
  `feel.sfx` behaviour, unchanged. The consumer-side play-gate (above) uses
  this exact same combined condition, so any bit that happened to be set in
  the instant before the freeze began is drained (as always) but not played
  while the gate holds. `music.gd`'s beat clock itself is **not** gated on
  `paused`/`user_paused` (`_process` only early-returns on `run == null` or
  `not run.alive`), so ambient bass/pulse/arp/pedal keep sounding at the
  last sampled threat while the new voices go silent during a genuine
  world-freeze. **`user_paused` outside solo does not freeze the shared
  world at all** — a local input overlay only, per the existing
  pause-semantics comment in `run.gd` — so in co-op, one peer opening their
  own pause menu does **not** stop the ensemble for the party: the
  deterministic tick and its emit sites keep running normally, the play-gate
  condition stays false-for-frozen (i.e. does not treat this as frozen),
  and every peer keeps hearing the shared ensemble exactly as if no one had
  paused. Only a shared/all-party freeze (`paused`, or `user_paused` in a
  strictly solo session) silences it.
- **Resync/restore** (`host_detect_desync → announce_resync → host_try_snapshot
  → apply_snapshot`, `restore_state`, `_after_restore`): `_ai_phase` et al.
  are restored field-by-field like every other hashed per-enemy array, so
  CHARGER/AMBUSHER telegraphs stay peer-consistent exactly as they do today.
  `_chase_jostling`/`_flank_arcing` are not restored — they are not in the
  manifest — and are explicitly cleared to `0` in `_after_restore` instead,
  so no stale local latch value can disagree with the just-restored world.
  Clear `voice_pending` in `_after_restore` before any resumed playback.
- **Mute**: continue draining/discarding every muted step. Clear pending
  bits both when disabling and before re-enabling ensemble playback; a
  sub-step mute/unmute interval must not replay events accumulated while
  silent. Use the existing `apply_volume`/settings lifecycle with a clear
  owner for that transition; it is presentation state, never hashed.
- **Pause/resume boundaries**: clear pending bits on both sides of a true
  world freeze as well as gating playback during it. A co-op local menu is
  not such a boundary. No transition handling changes combat timing.
- **Run end**: clear pending bits and prevent new ensemble playback. The
  existing `_process` returns on `not run.alive` before advancing its beat
  clock, so cleanup must occur before that early return, not only inside
  `_on_step`. Clear on binding/rebinding a run too.

## Effects budget

`music.gd` currently has 8 `AudioStreamPlayer`s shared round-robin across 5
existing musical roles (bass, pulse, offbeat, arp, pedal — plus the `_tick`
sound reused by pulse/offbeat). This design adds 10 **dedicated**
`AudioStreamPlayer`s — one per logical voice, keyed by index — never shared
with the existing 8 or with each other, so a still-sounding note is never
stolen by an unrelated voice. Four of those ten (the player slots) all point
at the **same** underlying `"voice_player"` buffer family; only their
per-play `pitch_scale` differs.

**A dedicated player retriggering its own still-sounding note is not free of
risk, and is not asserted as correct without a treatment.** Calling `.play()`
on an `AudioStreamPlayer` already mid-playback restarts immediately at
whatever sample the waveform was at — a hard discontinuity, audible as a
click, unless that sample happened to be at or near zero. Because the
aggregator can claim the same voice at most once per beat step, the fastest
possible retrigger interval for any voice is one step (`60/BPM_HOT*0.5` ≈
0.242s at `BPM_HOT`).

**A delayed-restart fade is the wrong fix**: ramping volume down for
15–20ms before restarting delays the new note's audible onset by that same
amount, which is a real, audible late start against the beat grid — the
opposite of what quantization exists for. There is no "fade the old note
while starting the new one on time" primitive available (a single
`AudioStreamPlayer` cannot cross-fade with itself), so a fade-based
treatment necessarily trades a click for a late attack; reject it.

**Conservative default, applied uniformly, no per-voice exception**: bound
every pitched/percussive voice's **actual rendered duration** — not the
nominal `dur` in its spec — to clear before the fastest possible retrigger,
for all six pitched families **including SUPPORT/tuba**, no fade-based
carve-out. "Actual rendered duration" is larger than nominal `dur` for two
reasons that both have to be accounted for, not just the spec's `dur`
field:
- Variant spread is `variant / max(VARIANTS - 1, 1)`, ranging from 0 to 1.
  The actual source multiplier is `0.94 + 0.12 * spread`, so maximum
  nominal duration is **1.06×**, not 1.12×. Prefer checking the generated
  stream's actual sample length, including release behavior and rounding.
- Godot's `AudioStreamPlayer.pitch_scale` changes playback **speed**, not
  only pitch: a note played at the lowest `pitch_scale` this voice's
  harmony mechanism can ever produce (its worst-case low register across
  every bar/slot combination) plays back proportionally **slower**,
  stretching real-world duration further. The bound must divide by that
  voice's minimum plausible `pitch_scale`, not assume `1.0`.
A voice's release tail must reach silence within
`(nominal_dur * 1.06) / min_pitch_scale` comfortably under one step
(0.242s at `BPM_HOT`) for this to hold at every tempo and every register it
can play at — including the tuba, which does not get a longer allowance;
its "sustaining, generous" character has to be read through a slower
attack/release shape within that same bound, not through a longer absolute
duration. Verify audibly in the listening pass; this is a real
implementation decision, not settled by this document.

## Damaging telegraphs cannot be masked

The two enemy voices tied to a damage-relevant telegraph (CHARGER, AMBUSHER)
both fire **after** the existing visual tell completes (dash launch, full
surfacing), not during or instead of it — see the trigger table above. The
pre-existing visual warnings (`_draw`'s per-enemy CHARGER/AMBUSHER ring,
computed straight from already-hashed `_ai_phase`/`_ai_timer`, unaffected by
anything in this design) remain the actual gameplay-critical signal, for
**every** enemy, always — never quantized, never dropped, never budget-
limited. The new ensemble notes are strictly additional atmosphere layered on
top: because of "first qualifying event wins, rest dropped," a specific
charger's dash-commit may produce **no** trombone note at all in a busy fight
(a different charger already claimed that voice's slot this step) — that is
acceptable specifically because the visual tell that actually matters for
survival was never gated on the audio layer in the first place.

## Player and enemy pitch: staying inside the shared harmony

The corrected overview requires the sax intervals to be "interpreted
musically … rather than arbitrary permanent transpositions outside the
harmony," not a fixed absolute pitch per slot — and the same requirement
applies to **every** pitched voice, not only the four sax slots: a fixed
absolute pitch for CHARGER/FLANKER/SUPPORT/AMBUSHER/RANGED would be just as
capable of clashing with whichever chord `PROGRESSION` is currently sounding
as a fixed pitch for the sax would be. All six pitched-voice families (every
enemy voice except the unpitched CHASE shaker, plus the shared player sax
family) use the same mechanism below. Investigated against `music.gd`'s
actual harmony model:

- `SCALE := [0, 1, 3, 5, 7, 8, 10]` (Phrygian, 7 members), `PROGRESSION :=
  [0, 0, 5, 4]` (scale-degree indices, sampled once per bar as `root`),
  `_hz(degree, octave)` converts a **scale-degree index** (not a raw
  semitone count) to Hz, wrapping via `degree % SCALE.size()` with an octave
  carry for `degree / SCALE.size()`. `arp` already transposes bar to bar by
  adding a **degree** offset to `root` (`d := root + [0,2,4,2,5,4,2,0][in_bar]`)
  before the `_hz`-style lookup — never a raw semitone offset, and the
  individual pitches this produces (including third- and fifth-relative
  intervals against whatever the bar's root is) are already part of what
  the arp line plays melodically, one note at a time, on every bar including
  the one discussed below.
- **A raw semitone offset** from the current bar root does not stay in
  scale: at bar root degree 4 (`PROGRESSION[3] = 4`, semitone value
  `SCALE[4] = 7`), a literal "+7 semitones" lands on absolute semitone
  `7 + 7 = 14 ≡ 2 (mod 12)`, and 2 is not a member of `SCALE` — an audible
  chromatic clash against the bass/arp on that bar.
- **Scale membership is not the same guarantee as chord-tone membership.**
  A fixed scale-degree offset keeps every individual note inside `SCALE`,
  but several independently-in-scale notes are not automatically consonant
  with each other — two adjacent scale degrees are both "in scale" and still
  a dissonant second apart. Voices sounding together (the four sax slots at
  once; any enemy voice against the bass/arp) need to land on an actual
  chord, not merely on arbitrary scale members.
- **Recommended mechanism, shared by every pitched voice**: a tertian stack
  through `_hz`, exactly the way `arp` already builds melodic degree offsets,
  reused for harmony instead of melody. For the four sax slots: slot 0 →
  `root + 0` degrees (root), slot 1 → `root + 2` degrees (the bar's own
  third), slot 2 → `root + 4` degrees (the bar's own fifth), slot 3 →
  `root + 7` degrees (exactly one octave, unconditionally, since
  `SCALE.size() == 7` — the only one of the four that is bar-independent by
  construction). Each of the five pitched enemy voices gets one fixed degree
  offset from this same family (e.g. CHARGER at `root + 0` an octave down
  for a mid-low accent, AMBUSHER at `root + 2` low-mid, FLANKER at
  `root + 4` mid-high, RANGED at `root + 4` or `root + 7` mid-high, SUPPORT
  at `root + 0` a further octave down for a low pad — exact assignments are
  a tuning pass, not fixed by this document), computed fresh from the
  **current** `root` every time it plays, not baked to one absolute pitch.
- Worked against `PROGRESSION`'s own `i – i – VI – v` label (`music.gd`'s
  comment), computing each triad's semitones relative to its own root via
  `_hz`, in this specific Phrygian collection (semitones
  `[0,1,3,5,7,8,10]` — note its `♭2` differs from natural minor's whole-tone
  2nd, and that difference is exactly what changes the following result):
  - Bar root degree 0 (`i`): relative semitones 0, 3, 7 — a minor triad,
    matching the lowercase `i`.
  - Bar root degree 5 (`VI`): relative semitones 0, 4, 7 — a major triad,
    matching the uppercase `VI`.
  - Bar root degree 4 (`v`): relative semitones 0, 3, 6 — a **diminished**
    triad, not the minor triad the lowercase `v` label might suggest by
    analogy with a plain minor scale. This is a genuine, mode-specific
    property of **this** Phrygian collection (its `♭2` is what makes the
    5th-degree triad's fifth come out diminished rather than perfect) — not
    a general "the 5th-degree chord is always diminished in a minor mode"
    fact, which is false: natural minor's own diatonic v-chord is minor
    (0, 3, 7), not diminished; the diminished triad in natural minor sits on
    the 2nd degree instead. The individual pitches involved are not new —
    `arp` already plays through degree-based offsets on this bar today, one
    note at a time — what would be new is hearing four of them stacked
    simultaneously as a vertical chord.
  This is the one material follow-up choice this document surfaces:
  **ship the diatonically-correct triad (diminished on the `v` bar), or
  special-case that one bar's fifth to a fixed perfect fifth** (an
  intentional "borrowed" chord). Recommendation: ship it diatonically-
  correct first and judge in the listening pass — a diminished triad under
  a Phrygian `♭2` is a characteristic sound of the mode, not an obviously
  wrong one, and a special case should only be added if it actually sounds
  wrong.
- This changes the **shape** implied by "root/+5/+7/+12" from a quartal
  power-chord voicing (root, 4th, 5th, octave — the literal semitone
  reading) to a tertian triad-plus-octave voicing (root, 3rd, 5th, octave).
  That is the actual content of "interpreted musically… rather than
  arbitrary permanent transpositions outside the harmony."
- Implementation shape: **one** shared saxophone buffer family (not four),
  at a reference pitch (`_hz(0, 1)` — root at octave 1, between bass's
  octave 0 and arp's octave 2), transposed at play time per slot via
  `AudioStreamPlayer.pitch_scale = pow(2.0, (target_semis -
  reference_semis) / 12.0)`, where `target_semis` is recomputed from the
  **current** `root` and that slot's fixed degree offset every time it
  plays — never four baked buffers. This composition (one buffer, a
  computed runtime `pitch_scale`) is not a new mechanism: `arp` already does
  it for its own rare octave-up variant (`_play(_arp[...], 1.0 if … else
  2.0)`); this reuses the same composition, computed instead of
  hand-picked. The five pitched enemy voices use the identical
  buffer-plus-computed-`pitch_scale` composition, one buffer family each,
  retuned to the current bar every play.
- **Variant pitch neutrality.** If these six families are registered through
  `Synth.build_bank()` (rather than built ad hoc like `_bass`/`_arp`
  already are), each must use `"steps": [0]` — a single-entry pool — never
  a multi-semitone `steps` array: `build_bank()`'s per-play variant
  selection is **random** (`sfx.gd`'s `pool[_rng.randi() % pool.size()]`),
  and a random semitone jitter on top of a deliberately-computed chord
  pitch would detune the note away from the harmony this section exists to
  guarantee. `test_synth`'s existing "every id gets distinct variants"
  check still holds at `steps: [0]`: `build()`'s per-variant envelope
  wobble (`decay`/`dur` scaled by `spread`) is independent of `steps` and
  still produces six audibly-distinct buffers by envelope alone — variation
  without pitch drift. Runtime `pitch_scale` supplies the only pitch
  variation, computed, never randomized.
- Different peers hear a different mix only if `music.gd` ever samples a
  per-viewed-slot signal; it currently only samples `run.threat()`/
  `run.boss_present()`, both peer-independent globals, so this design
  introduces no new per-peer divergence. Allowed presentation variance in
  any case, changing no hashed state or attack timing.

## Review of the prior-art research (kept as reference, not adopted)

`2026-09-04-instrument-ensemble-research.md` is preserved unedited; this
section checks its four numbered findings and its revised proposal against
source, without rewriting it. The overview's "Review input" subsection had
raised the event-driven-vs-census mechanism question; **the user has since
decided it** — action/event-driven stays, both the census/layer alternative
and a population-plus-accents hybrid are rejected for this pass. This
section's genuine findings are folded in below as fixes within the kept
mechanism, not as an argument to reopen it.

**1. "The event rates are lopsided, measured."** The 1288-spawn table is a
**computed expected value** from `spawn_director.gd`'s wave-rate formula
joined to `enemy_table.gd`'s behaviours, not an instrumented count from an
actual run — its own SUPPORT figure, "22.5" spawns, is fractional precisely
because it is a rate integral, not an observed integer count. Two of its
per-behaviour rates also conflate **spawn rate** with **behavioural event
rate**, which are different quantities here:
- AMBUSHER's cited "~0.6 events/s" is the *arrival* rate (66 spawns over a
  110 s window). Surfacing is not a one-time-per-spawn event: `_ambush`
  cycles `AM_SUBMERGED (2.0s) → AM_SURFACING (0.6s) → AM_ACTIVE (4.0s)` and
  back, repeatedly, for the enemy's entire life (~6.6 s/cycle). The true
  aggregate surfacing-completion rate scales with *concurrently-alive
  ambusher count* ÷ 6.6 s, not with the arrival rate — likely higher than
  0.6/s once more than one is alive at once, and it does not stop once the
  spawn window (t=190s onward per the cited table) ends, since already-alive
  ambushers keep cycling.
- SUPPORT's cited "silent... until t=210" describes only the **regular**
  `watchdog` row. `packet_filter` — the second mini-boss, `data/enemy_table.gd`
  confirms `Behaviour.SUPPORT` — spawns at `SpawnDirector.MINIBOSS_TIMES[1]
  = 145.0` (verified in `scripts/run/spawn_director.gd`, not the stale `60,
  120, 180, 240` figure a generated codemap carried — source, not the
  codemap, is the baseline), sixty-five seconds earlier, and `_support()`
  does not distinguish a mini-boss target from a regular one when deciding
  whether to heal a nearby ally. The tuba's first realistic entry is closer
  to t=145s than t=210s.
CHASE's core claim survives this check: its trigger is genuinely a
continuous per-enemy condition, and the aggregate risk (an edge-detected
per-enemy latch can still make the pooled voice fire on nearly every beat
step once hundreds of enemies are jostling) is real and already named in
this document's Acceptance scenario 4 — not something this review disputes.

**2. "No pitch rule exists for the six enemy voices."** Correct, and now
addressed above (a fixed degree offset from the current bar root per enemy
voice, shared mechanism with the sax) without adopting the research's full
Mini-Metro-style serialism (octave-by-distance, dynamics-by-count,
pan-by-screen-position), which is a materially larger design than the
approved mapping and would need its own approval pass.

**3. "Ten logical voices do not fit `music.gd`'s 8 `VOICES`."** Correct; see
"Effects budget" above (10 dedicated players, sized to this design's own
concurrency bound, four of them sharing one buffer family rather than each
needing a separate one).

**4. "The palette is a different genre from the score."** A real stylistic
observation, not a new one raised by this document: the user already
approved brass/reed-labeled voices over a Phrygian synth score in the
"Music ensemble" table this document implements. This document's synth
corrections address a narrower, factual claim — what the engine can
actually produce for those labels — not whether the genre pairing itself is
the right taste call, which is not this document's decision to revisit.

**The research document's own revised proposal repeats the same
unsupported synth-capability claims** this document corrects for the
original mapping: its table specifies SUPPORT as "SINE + 2 harmonics" and
AMBUSHER as "SINE + odd harmonics" (Wave.SINE has zero harmonics and no
per-partial mix parameter exists, exactly as above) and the player voice as
"SAW + vibrato" (no periodic-modulation capability exists, exactly as
above, before this document's gated addition). Whichever mechanism ships,
these specific claims need the same correction — they are not specific to
the event-driven mapping.

**The research document's Layer-B "event layer" list mischaracterizes two
of its four proposed events as "genuinely rare."** `player fire` is, by
`synth.gd`'s own comment on `FIRE_SPECS`, "the most-repeated sound in the
game — auto-fire across three exploits, for a whole run." `kill` is rate-
limited in `sfx.gd`'s `RATE_LIMIT` table at 12 plays/second specifically
because uncapped kill events routinely exceed that at the enemy cap
(`codemaps/audio.md`: "600 enemies... produce hits and pickups by the
hundred per second"). Neither is rare or low-frequency; `ambusher surfacing`
and `boss phase change` are the two on that list that actually fit "rare,
high-salience."

**Resolved.** The user reviewed this section's corrected facts and chose to
keep the action/event-driven ensemble, rejecting the census/layer
alternative and a population-plus-accents hybrid for this pass. The
corrected facts weaken two of the research's four arguments for switching
mechanism (SUPPORT is less silent than claimed; AMBUSHER's true event rate
is higher, not "one step in seven") without resolving the two that survive
(CHASE's aggregate saturation; the palette/genre taste question) — both are
carried forward as named, accepted tradeoffs of the chosen mechanism
(Acceptance scenarios 4 and 9), not reasons to revisit it.

## Acceptance (listening test, no automated assertions)

Launch windowed (`godot`, not `--headless`); a real viewport, audio device
and gameplay session are required — none of this is assertable without ears
and a running mixer.

1. **Combat feedback is unaffected.** Existing hit/fire/kill/pickup sounds
   play with no audible added latency versus the current build; disabling
   the new voices entirely must not change any existing sound's timing.
2. **Each of the 7 timbres is distinguishable in isolation.** Solo, no
   co-op: trigger each behaviour deliberately (park near a charger to bait a
   dash, stand in a watchdog's heal radius while damaged, let a rootkit
   surface, etc.) and confirm the corresponding voice is audibly distinct in
   register/character from the other six and from the existing bass/arp/tick
   layers.
3. **No pitched voice ever sounds a note outside the Phrygian collection**,
   across all 4 bars of `PROGRESSION`, in both solo and a 2–4 player session
   with staggered fire timing (so multiple sax voices land in the same and
   in different beat steps).
4. **CHASE and FLANKER read as discrete accents, not a metronome**, during a
   sustained mid-subnet swarm fight — confirm the shaker/muted-trumpet notes
   have audible gaps rather than firing on every single beat step for
   minutes at a time; if the aggregate rate is still effectively continuous,
   record the observed cadence against the recommended threshold constants
   for a follow-up tuning pass rather than treating it as a defect in the
   edge-detection mechanism itself.
5. **CHARGER/AMBUSHER audio lands after the visual tell**, confirmed by
   watching the existing windup/surfacing ring finish before the trombone/
   bass-clarinet note sounds, not simultaneously with the tell's start.
6. **A desync-and-restore mid-fight** (force one via the existing test
   harness or a deliberately stalled peer) produces at most one audibly
   wrong/missing ensemble note around the restore tick, with the same
   CHARGER/AMBUSHER/CHASE/FLANKER latch state audibly consistent across
   peers afterward.
7. **Pause behavior distinguishes a shared world-freeze from a local menu
   overlay.** A card/offer screen (all-party) or a solo player's own pause
   menu stops new ensemble notes from starting, without stopping the
   ambient bass/pulse/arp/pedal layer, exactly as `feel.sfx` already
   behaves today. In co-op specifically, confirm the opposite is also
   true: one peer opening their own pause menu (`user_paused`, not a
   shared offer) does **not** silence the ensemble for the rest of the
   party — the shared world and its emit sites keep running normally.
8. **The `v`-bar diminished triad is judged, not assumed.** Listen to the
   pitched voicing specifically during `PROGRESSION`'s 4th bar (root degree
   4) in a multi-slot session; confirm whether the diminished quality reads
   as characteristic-Phrygian or as wrong, and record the verdict against
   the one material follow-up choice named above rather than silently
   special-casing it either way.
9. **SUPPORT and AMBUSHER are heard earlier and more often than the
   research review's raw numbers suggested.** Confirm the tuba can sound
   from `packet_filter`'s arrival (t=145s, `SpawnDirector.MINIBOSS_TIMES[1]`)
   in a run that reaches the second mini-boss, not only from t=210s onward,
   and confirm the bass clarinet recurs across an ambusher's full lifetime
   (repeated surfacing cycles), not once per spawn.
10. **No audible click on a self-retrigger, and no late attack.** Sustain
    a healing SUPPORT encounter across several consecutive beat steps at
    both `BPM_CALM` and `BPM_HOT`, and confirm the bounded-rendered-
    duration treatment (accounting for variant spread and the voice's
    lowest plausible `pitch_scale`, not nominal `dur`) prevents a hard
    cutoff artifact, with every note's audible onset still landing exactly
    on its beat step — no fade-delayed attack.
