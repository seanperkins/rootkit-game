# Ideas review — approved direction and detailed designs

Date: 2026-09-04. Source: `ideas.md` and the one-question-at-a-time interview.
Status: the user approved the instrument mapping, bounce numbers, and three-boss mapping. This is a design package, not an implementation report. Gameplay source remains unchanged by this documentation pass.

## Implementation update — September 5

Weapons/trigger ownership and reserved spawns are implemented. The shared
route/teleporter pass now includes seven route categories, animated upload and
arrival, larger main arenas and hidden archive rooms. The user explicitly
replaced the pre-generated connected campaign with one loaded subnet at a time.
See [the implementation record](../../teleporter-subnets.md). Leveling pace,
action-driven music and the three bespoke bosses remain separate work.

## Read the detailed pairs

### Combat and progression

| Feature | Specification | Implementation plan |
|---|---|---|
| Weapons, trigger ownership and upgrade wording | [Weapons spec](2026-09-04-weapons-trigger-rework-design.md) | [Weapons plan](../plans/2026-09-04-weapons-trigger-rework.md) |
| Leveling pace | [Leveling spec](2026-09-04-leveling-pace-design.md) | [Leveling plan](../plans/2026-09-04-leveling-pace.md) |
| Three themed bosses | [Boss spec](2026-09-04-themed-bosses-design.md) | [Boss plan](../plans/2026-09-04-themed-bosses.md) |

### World and presentation

| Feature | Specification | Implementation plan |
|---|---|---|
| Per-arena spawner points | [Spawner spec](2026-09-04-spawner-points-design.md) | [Spawner plan](../plans/2026-09-04-spawner-points.md) |
| Teleporter and next-subnet vote | [Vote spec](2026-09-04-teleporter-vote-design.md) | [Vote plan](../plans/2026-09-04-teleporter-vote.md) |
| Instrument ensemble | [Music spec](2026-09-04-instrument-ensemble-design.md) — **first read [the research review](2026-09-04-instrument-ensemble-research.md)** | [Music plan](../plans/2026-09-04-instrument-ensemble.md) |

These documents distinguish approved behavior from recommended implementation/tuning details. Proposed APIs and new fields are not claims that the symbols already exist. Source code, not the older generated codemap values, is the baseline.

## Approved decisions

### Weapons

Rank-ups must not increase a weapon's firing frequency. Triggers own cadence; cooling is repurposed to movement and the global haste key is removed. Start with a packet and no equipped trigger. A bare weapon uses 1.5 times its base cooldown; an equipped trigger removes the bare penalty and applies its own condition/cadence. Fused weapons already embed a trigger and are not bare.

Bounce's approved base numbers are damage **1.4**, radius **150**, cooldown **1.5 seconds**; base knockback stays **320**. Retain the shared vector radius growth rule initially, reducing absolute growth from 47.5 to 37.5 units per rank rather than adding a bounce-only compiler exception. Present actual selected-build before/after values in upgrade cards, not raw stat keys or generic rank labels alone.

**Correction to the interview:** vector cooldown already ignores rank in `Compiler._fold`. Global haste and payload cadence were separate fire-rate paths; both are removed in the weapons pass.

**Approved replacements (2026-09-04, revised during implementation):** shop `cooling` adds sheet **`clock_speed`** (move speed). The recovery-only payload prototype was unreachable with one payload slot, so the user selected **own fast shield, no new stat**. `overclock` retains damage and grants a smaller, faster-rearming shield; `race_condition` grants a lighter shield. Neither retains `cadence_mult`. See the weapons spec for tuning values.

### Leveling

Slow progression across the campaign so builds keep developing in later subnets. XP curve first; consider shard/reward economy only after measurement. The detailed spec recommends preserving early costs and adding a late-level surcharge, because the current source records an earlier uniform 2.4 slowdown starving early builds. The candidate curve is not measured gameplay or a locked tuning value.

Count XP-earned rounds separately from direct miniboss and data-block rewards. The party shares XP and earned level-up rounds, so solo-only measurement is insufficient. Do not silently reduce pickup radius, enemy density or survivability to force a target.

### Spawner points

Generate four deterministic, valid spawn points per arena during terrain preparation. Points must be safe for the full player footprint, reachable, spaced from walls and each other, and close enough to start as a party. Reserve and validate the entry formation during generation; refuse an invalid exported layout rather than rely on stripped assertions or coincident fallback points. Use stable slot-to-point assignment at initial spawn and actual teleporter arrival.

### Teleporter and modifiers

After boss death, preserve the existing escape/collapse timing but replace the gate's terminal interaction with a teleporter. **Entering the teleporter triggers the shared vote**, not the boss death itself. Preserve all-LIVE gathering and the existing modal-offer world-pause semantics: unchanged collapse timing means unchanged simulation timers/rates, not a new wall-clock timer that kills players while they read cards.

Offer three shared choices. Each LIVE player votes through staged lockstep input; plurality chooses one next-subnet card. Break ties only among tied winners using deterministic, snapshotted RNG state. Solo selects directly. Final-subnet boss death still wins immediately; no meaningless final vote.

Approved modifier categories:

| Combat modifiers | Terrain and reward modifiers |
|---|---|
| Enemy integrity | More hazard/slow/corruption zones |
| Spawn rate | Arena size or obstacle density |
| Behavior mix bias | Salvage/shard rewards |
| Earlier or additional miniboss | |

Category approval is not approval of every proposed magnitude or card bundle. A reward-only card is beneficial; a bare HP card is a penalty. Neither is automatically a “risk/reward tradeoff.” The detailed vote spec proposes card bundles that make those choices meaningful without a universally superior free reward.

Terrain currently plots one campaign grid before play. Vote-time size/density changes must respect reserved unopened-arena footprints and deterministic restore; they cannot casually regenerate a region with players or boss objectives in it. The terrain and boss specs share safe entry/objective placement requirements.

### Music ensemble

Six enemy behavior voices, event-driven and beat-quantized, plus one player voice per LIVE slot. First qualifying event wins a voice's note slot for that subdivision; excess events drop rather than queue. Player notes follow weapon emissions. Combat timing remains independent of playback quantization; no approval has been given to delay weapon damage or enemy attacks until a musical beat.

| Voice | Approved timbral direction | Event intention |
|---|---|---|
| CHASE | Brushed hi-hat/shaker | Separation steering engages |
| CHARGER | Trombone | Windup commits to dash |
| FLANKER | Muted trumpet | A meaningful flank commitment |
| SUPPORT | Tuba | Actual healing |
| AMBUSHER | Bass clarinet | Surfacing |
| RANGED | Trumpet | Shot emission |
| Players 0–3 | Saxophone in distinct registers | Weapon emission |

The player pitch proposal is root/+5/+7/+12, interpreted musically by the detailed spec rather than arbitrary permanent transpositions outside the harmony. There are **seven timbral roles and ten logical voices**, not eight new instrument specs. Brass/reed names mean synthesized approximations, not realistic acoustic samples. The earlier assertion that existing synth specs already support arbitrary odd-harmonic recipes or vibrato was unsupported; the music plan identifies the required additions. Real clarinets are not literally odd-harmonics-only.

#### Review input before the music spec is written

**Historical review input, preserved below.** Its mechanism question was
resolved in “Decision after the research review”; its spawn-rate arithmetic
is not a measured runtime note rate. The checked music spec supersedes
claims below about event rarity, pitch rules and the number of new families.

Prior-art review and a measurement of this repo's own wave table:
**[Instrument ensemble research](2026-09-04-instrument-ensemble-research.md)**.
Four items the approved direction above does not yet resolve. The first is a
measurement, not an opinion, and it is the one that decides the mechanism:

1. **The event rates are lopsided, measured.** From `spawn_director.gd`'s wave
   table joined to `enemy_table.gd`'s behaviours, one solo subnet's 1288
   spawns are CHASE 76% (981), FLANKER 7.7%, RANGED 5.4%, AMBUSHER 5.1%,
   CHARGER 3.9%, **SUPPORT 1.7%** (22.5, and no watchdog exists before
   t=210 of a 300 s subnet). Worse, CHASE's trigger — separation steering
   engaging — is a *continuous* per-enemy condition true of hundreds of
   enemies at once, so at 2.9–4.1 beat steps/s that voice fires on every
   step for the whole run. "First qualifying event wins, excess drops" caps
   the two saturated voices but gives the two near-silent ones nothing to
   play. Two metronomes and a tuba that may never sound in a short run.
2. **No pitch rule exists for the six enemy voices.** The table fixes timbre
   and register only. Six pitched voices free-firing against `music.gd`'s
   bass, pulse, offbeat, arp and boss tritone pedal produce arbitrary
   vertical intervals. The player-voice paragraph above already accepts this
   problem for slots 0–3; the same fix has to cover the other six.
3. **Ten logical voices do not fit `music.gd`'s 8 `VOICES`**, and no
   allocation or stealing priority is stated.
4. **The palette is a different genre from the score.** `music.gd` is
   Phrygian at `ROOT_HZ` 55 built from band-limited SQUARE/SAW/NOISE. Every
   shipped precedent keeps the reactive layer inside the score's own
   timbral family — Everyday Shooter's reactive notes are guitar because the
   whole soundtrack is guitar; Ape Out is entirely drums. Calling the names
   "synthesized approximations" resolves the fidelity question but not the
   genre one: register and articulation separate the voices, the labels do
   not.

The research file proposes the alternative the precedents converge on —
**census → layer** rather than **event → note**: per-behaviour alive-and-near
counts polled at bar lines the way `run.threat()` already is, driving layer
presence, density, octave, dynamics and pan, with pitch derived from a data
axis (Mini Metro's serialism) so every note is a scale tone by construction.
System Shock 1 is the closest published precedent to "an instrument per enemy"
and is census-driven for this reason. Event-driven notes are kept for the four
genuinely rare, high-salience moments (kill, surfacing, boss phase, player
fire).

The cost asymmetry is the argument for deciding this before the spec is
written: census is one more poll on an existing clock, no new emit sites, no
new drain list, no new `Synth` id family. The event path is eight id families,
`build_bank()` growth on an already ~1 s cached boot, a `test_audio_events`
indirect-site entry (an id reached through a lookup table is invisible to its
grep, and a missing id fails *silently* — a sound that never plays), and a
voice-stealing rule for 10 voices in an 8-voice pool.

Not in dispute: beat quantization, combat timing staying independent of
playback, and the per-slot player transposition.

#### Decision after the research review

The user reviewed the alternatives and selected **Keep action-driven instruments**.
Population-driven layers and a population-plus-accents hybrid are not part of
this pass. Keep the approved timbral direction, adding bounded producer-side
event handling, shared harmony and an explicit voice budget.

The research input above is preserved, not treated as a runtime benchmark:
wave-table spawn totals are not measured note/event rates; the SUPPORT
mini-boss `packet_filter` is scheduled at 145 seconds, before watchdogs at
210; ambushers can surface repeatedly during their lifetimes. Scale
membership alone also does not guarantee chord consonance. See the
[music specification's research review](2026-09-04-instrument-ensemble-design.md)
for the checked conclusions and implementation safeguards.

### Themed bosses

All three bosses are in the approved design scope, not a one-boss trial release:

| Subnet theme | Boss | Core mechanic |
|---|---|---|
| Perimeter defense | Sentinel Array | Capture four protection spires to remove boss invulnerability |
| Replicating malware | Worm.exe | Damageable growing segments with bounded regeneration |
| Kernel/core | Root Cause | Readable ambush, ranged and charge phases |

The user's original spire mechanic was **capture**, not destruction; preserve capture interaction in the detailed design. The prior draft drifted into shooting stationary HP targets. The existing collapse starts after boss death, so it cannot provide time pressure while the invulnerable boss is alive.

Generalize boss identity and clear/win checks through an explicit current-subnet boss lookup. Do not replace `ICE must be last` with another positional rule that the last three rows are bosses. Bosses, capture objects and worm segments must remain distinguishable for death, flip, targeting, pooling and rewards. Existing worm segments are real pooled entities; their visual trail is position history, not the HP or aliveness model.

## Implementation order and shared boundaries

1. Resolve weapons' non-firing haste/payload effect, then implement weapons and spawner points as independent slices with one shared-run integration owner.
2. Measure XP candidates against the revised weapons and retain a labeled current-game baseline; do not treat the performance fixture as a normal campaign bot.
3. Build the music pipeline independently of simulation timing; integrate event hooks with explicit presentation/hash classification.
4. Integrate teleporter/votes and all three bosses around the same arena-variant, spawner and current-boss contracts. They share `run.gd`, UI and snapshot state; serialize those edits.
5. Run the repository runner after source edits settle, exercise real windowed/audio/controller/co-op scenarios, and re-measure combined campaign balance. Finish maintained documentation and remove disposable probes only after successful smoke.

No code, build, gameplay, audio-listening or multiplayer verification is claimed by this design approval. The current pass checks document links, coverage, source facts and numerical examples only. Implementation needs the evidence named in each plan.

Implementation update, 2026-09-05: progression, themed bosses and the action ensemble are now present. See [implementation and validation](../../progression-bosses-music.md) for measured outcomes, rejected XP candidates and outstanding checks; design approval itself is not test evidence.
