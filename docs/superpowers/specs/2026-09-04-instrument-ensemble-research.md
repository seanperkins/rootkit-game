# Instrument ensemble — prior art review and revised proposal

Scope: item **1** of `2026-09-04-ideas-proposals-design.md` only. Researches games
that map enemies to instruments, measures ROOTKIT's actual behaviour mix against
the proposed triggers, and proposes a revised shape.

## Recommendation, up front

Keep the idea. Change the mechanism from **event → note** to **census → layer**,
and reserve event-driven notes for the handful of moments that are actually rare.

- **Census layer (build this).** Per-behaviour alive-and-near counts, sampled at
  bar lines exactly like `run.threat()` already is, decide which behaviour layers
  are present and how dense they are. No new emit sites, no new drain list, no
  new `Synth` id family — it is one more poll on the existing `music.gd` clock.
  This is System Shock 1's mechanism, and it is the closest published precedent
  to "instruments represent enemies."
- **Event layer (build second, small).** 4–5 genuinely rare, high-salience
  events only: kill, ambusher surfacing, boss phase, player fire. Ape Out's
  screen-position → kit-position mapping gives these variety without a taxonomy.
- **Pitch comes from a data axis, not from the voice.** Mini Metro's serialism:
  behaviour index → scale degree of the existing Phrygian `SCALE`, screen
  distance → octave, count → dynamics. Every note is a chord tone by
  construction, so the stack cannot go sour.
- **Drop the brass band.** Use the score's own timbral family.

## What the precedents actually do

| Game | Mapping | The transferable lesson |
|---|---|---|
| **Ape Out** | Kill → cymbal, chosen by the enemy's **screen position** mapped onto a drum kit from the drummer's seat; velocity scales with speed and kill count | Percussion is unpitched, so it can never be harmonically wrong at any density. Position, not enemy type, supplies the variety. A macro algorithm picks patterns by *intensity, density and similarity* — the density control is part of the design, not a polish pass |
| **Everyday Shooter** | Each enemy type triggers a **guitar phrase**, and the entire soundtrack is guitar | The reactive layer lives inside the score's instrument family. Phrases, not single notes — Steve Reich's *Electric Counterpoint* is the stated model |
| **System Shock 1** | Per-enemy-type layers overlaid on the level music by **proximity of enemies of that type** | The one precedent that really is "an instrument per enemy," and it is driven by census, not by events |
| **Rez** | Player lock-ons and enemy explosions **quantized** into the track | Quantization is what makes an arrhythmic player musical. The §1 spec already has this |
| **Mini Metro** | Total serialism: line → pitch, station shape → timbre, station count → sequence length, occupancy → dynamics, screen position → panning | Derive every musical parameter from a different game axis. Their postmortem also names the failure below |
| **Metal: Hellsinger** | Combo multiplier gates **layers** — drums → guitars → band → vocals | Escalation as instrumentation, one scalar driving the whole arrangement |

Two negative results are as useful as the positive ones:

- Mini Metro's **procedural drum matrix for trains** was cut in spirit — the
  postmortem calls it "outer complexity" without proportional benefit, and notes
  that rhythm was never meaningfully tied to gameplay the way pitch was.
- Ape Out's first attempt was **composed loops repeated ad infinitum**, abandoned
  as untenable. Boch's summary: *"adopt interesting constraints."*

## Four problems with §1 as written

### 1. The instruments collide with the score

`music.gd` is Phrygian at `ROOT_HZ` 55, built from band-limited SQUARE/SAW/NOISE
with a tritone pedal for bosses. Trombone, tuba, muted trumpet, bass clarinet and
saxophone are a different genre bolted onto it. Every precedent goes the other
way: Everyday Shooter is guitar because the score is guitar; Ape Out is drums
because the score is drums. A "sax" built from SAW plus a vibrato LFO will not
read as a sax anyway — it will read as a detuned saw, which is what the score is
already made of, so the labels buy nothing and the register plan buys everything.

Use **register, articulation and rhythmic role** to separate the six voices, all
inside the existing oscillator set. That is also the only version that costs one
line each in `build_bank()`.

### 2. The trigger density is measured, and it is lopsided

From `spawn_director.gd`'s wave table × `enemy_table.gd` behaviours, one solo
subnet schedules 1288 spawns:

| Behaviour | Rows | Spawns/subnet | Share | First appears |
|---|---|---|---|---|
| CHASE | daemon, firewall, worm | 981 | **76%** | t=0 |
| FLANKER | tracer | 99 | 7.7% | t=70 |
| RANGED | probe | 70 | 5.4% | t=150 |
| AMBUSHER | rootkit | 66 | 5.1% | t=190 |
| CHARGER | sentinel | 50 | 3.9% | t=110 |
| SUPPORT | watchdog | 22.5 | **1.7%** | t=210 |

The beat clock runs 2.9 steps/s at `BPM_CALM` and 4.1 at `BPM_HOT`. Against that:

- **CHASE** is not 76%, it is 100%. Its trigger — separation force over a
  threshold — is a *continuous* per-enemy condition, and with hundreds of enemies
  packed against a wall it is true on every step forever. That voice is a
  metronome, not a part.
- **SUPPORT** is silent for the first 210 seconds of a 300-second subnet, and
  watchdogs are deliberately rare because each runs a radius query per tick. The
  tuba plays for the last 30% of the subnet and rarely then.
- **AMBUSHER** fires ~0.6 events/s inside a 110-second window and never outside
  it — roughly one step in seven, and only late.

So two voices saturate, two are near-silent, and one (SUPPORT) may never be heard
at all in a run that ends early. "One note slot per voice per beat step, first
qualifying event wins" does not fix this: it caps the metronomes without giving
the silent voices anything to play.

A census layer fixes it directly, because a count is a continuous quantity you can
map to density and dynamics rather than a stream of yes/no events.

### 3. It is a diagnostic wearing a compositional label

The §1 header says compositional, not diagnostic — but one voice per entry of a
behaviour *enum* is a readout of that enum. None of the precedents map to a type
taxonomy: Ape Out maps to screen position and kill count, Mini Metro maps to five
independent data axes, Everyday Shooter maps to phrases. System Shock is the only
type-keyed one, and it keys on *how many are near you*, which is information the
player is acting on.

The test to apply: if the player muted the layer, would they lose anything they
were using? "There are chargers on the board and they're close" passes. "A
charger just transitioned from windup to dash" is a hit-confirm — that already
belongs in `sfx.gd`, where `miniboss_charge` and friends live.

### 4. There is no pitch rule at all

The §1 table specifies wave, register and character for each voice and never says
what **note** any of them plays. Six pitched brass voices free-firing on an
8-step grid produce arbitrary vertical intervals against a bass, pulse, offbeat,
arp and (in a boss) a tritone pedal.

The codemap already states the principle for SFX — *"because the SFX step through
the same scale, a pickup or a hit lands on a chord tone rather than beside it"* —
and the ensemble needs the same rule made explicit. Mini Metro's answer, applied
here:

| Musical axis | Game axis |
|---|---|
| Scale degree | behaviour index → index into `SCALE`, transposed by the current `PROGRESSION` step |
| Octave | distance of that behaviour's nearest member from the viewed slot (near = low/loud) |
| Dynamics | count of that behaviour alive and within the census radius |
| Density (which steps fire) | same count, bucketed — bar line → half notes → quarters → eighths, the way `arp` already does |
| Pan | mean screen x of that behaviour's members (Ape Out / Mini Metro both do this) |

Every note is then a scale tone by construction, and the six layers stack into a
voicing rather than a pile.

## Revised proposal

**Layer A — census (the main build).**

Six behaviour layers plus a player layer. At each bar line `music.gd` polls a new
`run.census()` alongside the existing `run.threat()`: per-behaviour count within a
radius of the viewed slot, mean screen x, nearest distance. Those drive presence,
density bucket, octave, dynamics and pan per the table above. Timbre stays inside
the existing oscillator set, separated by register and articulation:

| Behaviour | Role in the arrangement | Built from |
|---|---|---|
| CHASE | low sustained bed, density-gated — the "how surrounded am I" floor | SAW, slow attack, long release |
| CHARGER | mid-low accent on the bar line | SAW, short portamento into the note |
| FLANKER | high clipped stab, offbeat | SQUARE, fast attack, no sustain |
| SUPPORT | held mid pad, present only while a watchdog is alive | SINE + 2 harmonics |
| AMBUSHER | hollow mid-low, odd harmonics only | SINE + odd harmonics |
| RANGED | dry high tick, on the eighth | SQUARE, very short |
| Player (×slot) | mid warm voice, transposed root/+5/+7/+12 per slot | SAW + vibrato — keep §1's per-slot transposition, it is the one part of §1 that is already serialism |

**Layer B — events (small, second).**

Only where the event is genuinely rare and the player is already looking at it:
kill (pan and register from screen position, Ape Out style), ambusher surfacing,
boss phase change, player fire. These go through the existing `feel.emit` /
`drain` path.

**What this drops from §1:** the orchestral labels, the CHASE separation-force
trigger, the SUPPORT heal-tick trigger, the RANGED per-shot trigger, and the
`voice_*` id family for the four census-only behaviours.

## Repo constraints this has to respect

1. **`music.gd` has 8 `VOICES`.** §1's ten simultaneous voices do not fit, and it
   specifies no allocation or stealing rule. The census shape needs an explicit
   priority order (bass and pulse are never stolen; behaviour layers steal from
   the lowest count first).
2. **Bar-line-only sampling is load-bearing.** Threat and BPM are sampled at bar
   lines because per-tick sampling audibly warbles. The census inherits that rule
   verbatim.
3. **Any surviving event id must exist in `Synth.build_bank()`.** `sfx.play`
   returns silently on an unknown id — a sound that never plays, not a crash. And
   an id reached through a lookup table is invisible to `test_audio_events`' grep
   for `feel.emit("literal")`; a new table has to be added to the indirect-site
   scan the way `HIT_SOUNDS` was.
4. **Boot cost.** `build_bank()` is cached in a static because it was a ~1 s hitch
   on `./intrude`. Every new spec is 6 variants; the census shape adds far fewer
   than §1's eight id families.
5. **`run.census()` is derived state.** Compute on demand or classify in
   `NOT_IN_MANIFEST`; caching per-behaviour counters in `run.gd` without
   classifying them fails `test_manifest`. It must also be computed from
   simulation state only — screen x and viewed-slot distance are presentation
   inputs, so the census call belongs above the world guard, reading the tick's
   output rather than participating in it.

## Open questions

1. Census radius — the whole arena, or a "near me" radius? Near-me makes the
   layer tactical (System Shock's proximity model); whole-arena makes it a mood
   meter and duplicates `run.threat()`.
2. Do you want the event layer at all in v1, or census-only first so the
   arrangement can be judged before events are piled on it?
3. Solo vs co-op: census is per viewed slot, so each peer hears a different mix.
   That is correct (it is presentation), but worth confirming it is intended.

## Sources

- [Algorithms, apes and improv: Matt Boch on Ape Out — MusicTech](https://musictech.com/features/interviews/ape-out-matt-boch-game-soundtrack/)
- [Sound and Style Make Ape Out Unforgettable — Cliqist](https://cliqist.com/2019/03/08/sound-and-style-make-ape-out-unforgettable/)
- [Q&A: Everyday Shooter creator Jonathan Mak — GameSpot](https://www.gamespot.com/articles/qanda-everyday-shooter-creator-jonathan-mak/1100-6181581/)
- [Everyday Shooter — Wikipedia](https://en.wikipedia.org/wiki/Everyday_Shooter)
- [System Shock's procedural music system — Procedural Generation](https://procedural-generation.isaackarth.com/2017/05/26/system-shocks-procedural-music-system-theres-a.html)
- [Postmortem: Mini Metro — Disasterpeace](https://disasterpeace.com/blog/mini-metro.postmortem.html)
- [The Programmed Music of Mini Metro — Designing Sound](https://designingsound.org/2016/02/18/the-programmed-music-of-mini-metro-interview-with-rich-vreeland-disasterpeace/)
- [The Making of Rez — Time Extension](https://www.timeextension.com/features/the-making-of-rez-tetsuya-mizuguchis-timeless-masterpiece)
- [Deep Dive: A framework for generative music in video games — Game Developer](https://www.gamedeveloper.com/audio/deep-dive-generative-music-in-video-games)
- [The history of adaptive music in video games — Splice](https://splice.com/blog/adaptive-music-video-games/)
- [Metal: Hellsinger review — Inverse](https://www.inverse.com/gaming/metal-hellsinger-review)
