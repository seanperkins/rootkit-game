# Plan: deterministic trigonometry below the world guard (rev 3, final)

Two review rounds, nine reviews, all REVISE. Rev 3 incorporates every surviving
finding plus one decision that was the user's to make (the two-commit
sequencing). Round history is at the end.

## Problem, with evidence

ROOTKIT's online co-op is **lockstep**. The CI job
`determinism matches across architectures` (`.github/workflows/ci.yml:132`,
diff at `:145`) defends it, and has failed on every push since 2026-09-03 03:36.

1. **The test is valid.** The probe run twice on one binary is byte-identical.
2. **Reproduced locally** in Docker (`linux/arm64` vs `linux/amd64`, official
   Godot 4.7 binaries): first divergence tick 1136, 29 of 1800 ticks, re-converging.
3. **One field diverges** — `projectiles.vel`.
4. **Pinned by ablation.** Zeroing `homing` makes 1800 ticks byte-identical.
   The steer is `run.gd:2554-2558`: two `.angle()` and one `.rotated()`.
5. **Not a code regression.** `ed50f9b` changes only `CLAUDE.md` and a codemap and
   fails identically. A runner-image/glibc update removed luck.

## Preconditions, verified

**FP contraction is off on every desktop template.** `-ffp-contract=off` is
appended unconditionally in `platform/linuxbsd/detect.py`, `platform/macos/detect.py`
and `platform/windows/detect.py` (MinGW), with `/fp:strict` for MSVC — all read at
the `4.7-stable` tag. This is why `length()`, `dot()`, `cross()`, `normalized()`
are safe. It is an **engine build property, not IEEE-754**; the web platform sets
no such flag.

`DetMath` must therefore stay **in GDScript**: each arithmetic operator is a
separate VM instruction on doubles and cannot be contracted. A future "optimise
DetMath in C++" reintroduces the bug. Say so in the file.

Empirical corroboration for the linux pair: the ablation ran
`normalized()`/`length()`/`dot()` on the order of **1e7–1e8** times (600 enemies ×
1800 ticks × ~30–60 ops, plus 400 projectiles × ~10) across both architectures
with byte-identical output. A contraction difference would have to hide in 1e7
consecutive draws. Do **not** gate this work on a further Docker FMA probe.

## What today's code actually computes — the correction that drives everything

`Vector2::rotated` is `real_t sine = Math::sin(p_by)` with `real_t = float`, so it
calls `sinf`/`cosf`; `Vector2::angle_to` is `atan2(cross, dot)` on `real_t`.
**Today's homing does its trig in float32.**

Measured in-engine, `Vector2(1,0).rotated(a)` against the double path
`Vector2(cos(a), sin(a))` over 20 000 arguments:

```
differing:        15 723 / 20 000  (78.6%)
worst abs delta:  4.17e-7          (~7 float32 ULPs; float32 ULP ~ 5.96e-8)
```

Consequences, and they replace rev 2's claims:

- The ≤1 ULP-of-double accuracy argument applies **only to the nine
  `Vector2(cos(a), sin(a))` sites** (double, narrowed once). For the six
  `.rotated()` / `.angle()` / `.angle_to()` sites, ANY deterministic replacement
  differs from today on most calls.
- **A perf-gate re-pin is therefore expected, not avoided.** Rev 2 said the
  re-pin "largely evaporates". That was wrong. State the expectation up front so
  a shifted `mean_hits` reads as "expected, re-pin with reason" and not as a bug
  hunt.
- `mean_hits` has been observed at 1.16 / 3.42 / 2.53 across code states
  (`perf_milestone0.gd:398-402`) and the floor is `2.50 × 0.75 = 1.875`, so a
  reshuffle can put the gate below its floor. This is the main risk of the
  change and it is a *balance* risk, not a correctness one.

## Scope

Only code reaching **hashed** state. Presentation keeps libm.

**Runtime sites, 15:**

| primitive | n | locations |
|---|---|---|
| `Vector2(cos(a), sin(a))` | 9 | `run.gd:2272`, `:2363`, `:2518-2519`, `:3819`; `spawn_director.gd:220,223,229`; `terrain.gd:679`; `blocks.gd:66` |
| `.rotated(a)` | 3 | `run.gd:2558`, `:2874`, `:2961` |
| `.angle()` / `.angle_to()` | 3 | `run.gd:2554`, `:2555`, `:2850` |

**`pow`, 3:** `compiler.gd:169`; `spawn_director.gd:45`, `:79`.

**Harness sites that synthesise hashed state, 5:** `tools/determinism_probe.gd:98`
(`_fill`, enemy spawn positions) and `:110` (`_drive`, `input_override`);
`tests/support/perf_fixture.gd:171`, `:183` (`drive`, pinned-slot records) and
**`:332`** (`_gap`, reached from `kite()` at `:255`, whose return is assigned to
`g.input_override` at `:140` — so it is slot 0's movement record, and `_gap` picks
an argmin over sixteen `dot` scores, so a last-bit change flips the heading
discontinuously).

**Total: 23.** The probe is the one that matters most — it is the artefact CI
byte-diffs, so leaving it on libm means a future red run reads as a simulation
regression and a green run proves less than claimed. `perf_fixture` is converted
for uniformity; its only consumers are single-binary runs.

`tools/fps_probe.gd:314,318` also synthesise sim state and are deliberately **out
of scope** — a windowed instrument that is never byte-diffed. Noted because it
shares `perf_fixture` with the gate.

`terrain.gd:679` (`nearest_open`) and `blocks.gd:66` are **runtime**, reached from
spawning and mine placement.

## Commit 1 — transliteration (the determinism fix)

Same algorithms, libm swapped out. Chosen over doing everything at once so that
"stop the desync" and "make it fast" have separate, attributable diffs.

`scripts/core/det_math.gd` — `class_name DetMath extends RefCounted`, pure. Built
only from operations IEEE-754 requires to be correctly rounded: `+ - * /`, `sqrt`,
comparisons, `floorf` (not `floor`, which is Variant-typed and will not infer
under strict typing).

API: `dsin(a)`, `dcos(a)`, `unit(a) -> Vector2`, `rotate(v, a) -> Vector2`,
`rotate_sc(v, s, c) -> Vector2`, `angle(v) -> float`,
`angle_between(a, b) -> float`, `powi(base: float, n: int) -> float`.

**`dsin`/`dcos`, not `sin`/`cos`.** `static func sin()` inside the class makes an
unqualified `sin(x)` in that file resolve to itself and recurse silently
(SHADOWED_GLOBAL_IDENTIFIER). It also keeps the guard regex simple.

**`angle` is defined by exact cases before any division.** `atan2(0,0)` is 0 in
every libm; `0.0/0.0` in GDScript is a silent NaN. Homing takes
`(enemies.pos[tj] - projectiles.pos[i]).angle()` on float32 positions that can
coincide exactly. A NaN would reach `vel`, then `pos`, then `int(floor(NaN))` in
the grid insert — ISA-defined (x86 INT_MIN, ARM 0) — and `_state_hash` hashes raw
bytes (`run.gd:5726`), where x86's quiet NaN is `0xFFC00000` and ARM's is
`0x7FC00000`. Instant permanent desync. Cases: `(0,0) → 0`; `x == 0 → ±PI/2`;
`|y| > |x|` → swapped octant; only then divide. Contract: **finite in, finite out**,
asserted structurally.

**`powi` is left-to-right repeated multiplication**, not binary exponentiation —
`((x²)²)·x` and `((((x·x)·x)·x)·x)` are both deterministic but not bit-equal, and
rev 1 specified one and tested the other. `n = 0 → 1.0`; `n < 0 → 1.0 / powi(base, -n)`.

**The `powi` call site needs a runtime contract, not an assert.**
`Compiler._rank_factor(f: float, rank: float)` (`compiler.gd:168`) takes a float
exponent, integral today only because `MUL_FOLD_KEYS == [&"cadence_mult"]`
(`compiler.gd:18`) and the fractional branch (`compiler.gd:196`,
`1.0 + VECTOR_RADIUS_RANK * float(em.rank - 1)`, 0.25 steps) is gated on
`radius`/`blast_radius`. `assert()` is **compiled out of release exports**, so the
assert is a development aid and the real protection is a suite test pinning
`MUL_FOLD_KEYS ∩ {radius, blast_radius} == ∅`. Use `push_error` + clamp if a
runtime signal is wanted.

**The `pow` conversion is required, not optional.** Rev 2 called those sites "the
least likely divergence source" on the belief glibc's `pow` is correctly rounded.
It is not — documented ≤1 ULP, ~0.52 ULP worst case, and
`sysdeps/x86_64/fpu/multiarch/` ships `e_pow-fma.c` / `e_pow-fma4.c`, the same
ifunc mechanism as `s_sinf-fma.c`. The two Linux arches did not diverge on it
because its arguments here are a handful of constants, but `hp_mult` and
`_rank_factor` run on every peer and a macOS↔Linux pair uses a different libm
entirely: `pow(0.82, 3)` differing in the last bit makes `cadence_mult` differ
from the first card pick. Still ships as **its own commit** so a moved baseline
is attributable.

## Commit 2 — restructure (perf and simplification)

Deferred deliberately. Delete the transcendentals from the tick rather than
reimplement them, using the technique the codebase already advocates at
`run.gd:2871-2873`: *"by complex multiply — no new transcendental enters the tick."*

- **Homing.** θmax = `homing * dt` is a per-exploit constant. Precompute
  `(cos θmax, sin θmax)` once per resolved exploit — **after**
  `r.homing = minf(r.homing, MAX_HOMING)` at `compiler.gd:156`. With
  `h = vel.normalized()`, `w = (target − pos).normalized()`:
  - `h.dot(w) >= cos θmax` → `vel = w * vel.length()` (exact snap; this is what
    `clampf` + `rotated` produces when |Δθ| < θmax, and it renormalises speed
    where `.rotated()` lets magnitude drift)
  - else → `rotate_sc(vel, ±sin θmax, cos θmax)`, sign from `h.cross(w)`
  - **`cross == 0` with `dot < 0` (exactly antiparallel) must pick a documented
    sign.** Today `wrapf(±PI)` then `clampf` turns at full rate; a sign-only
    controller turns by zero forever. Deterministic and measure-zero, but it is a
    semantic change and belongs in the commit message and a test.
  - The `dot` test is what makes this correct: `|sin Δθ| < sin θmax` alone is
    satisfied both for |Δθ| < θmax **and** |Δθ| > π − θmax, so a target behind
    would read as aligned.
  - Pin `MAX_HOMING * TICK_DT < PI/2` in the suite (`MAX_HOMING = 4.0`,
    `compiler.gd:30`; × 1/60 = 0.067 rad today) — the sign/cos comparison is only
    valid below π/2.
  - Where the constant lives is a manifest question: a `ResolvedExploit` field
    must be classified in `equals()` (`resolved_exploit.gd:109-124`) or documented
    as derived; a `run.gd` cache is a `var` that `test_manifest` rejects unless
    listed in `STATE_FIELDS`/`NOT_IN_MANIFEST`. Also makes `SessionRules.TICK_DT`
    a dependency of the pure build layer — say so.
- **Cone** (`run.gd:2850`). `absf(to_e.normalized().angle_to(cdir)) <= CONE_HALF_ANGLE`
  is equivalent, for `C < π/2`, to `dot > 0 and cross² <= tan²(C) · dot²` with
  `tan(C)` a compile-time constant (`CONE_HALF_ANGLE = 0.785`, `run.gd:149`). This
  form is **scale-invariant**, so it works even though `player_facing` can be a raw
  unnormalised record aim (`run.gd:2412`), and cross/dot of float32 components
  computed in GDScript double are **exact** (24×24 < 53 bits). No DetMath call at
  all. This is the highest-frequency angle site in the tick — per enemy in radius,
  per fire.
- **`terrain.gd:679`.** `a := TAU * k / 8.0` for `k in 8`, up to
  `OPEN_SEARCH_RINGS = 8` rings — up to 64 sin/cos per call, called from every
  enemy spawn and mine placement. Replace with a `const RING8` of eight exact unit
  vectors (`±1, 0, ±√2/2`). Bit-exact and faster.
- **Spread / mine ring / spawn rings / orbit.** `DetMath.unit` per *fire* or per
  *spawn*, never per tick.

After commit 2, `angle()` and `angle_between()` have no runtime caller. Either
keep them tested or delete them — do not ship dead surface under a determinism
contract.

Perf context (measured, Godot 4.7 headless, 200k calls): GDScript polynomial trig
is **5.7–10.6×** the builtin (`sin` 0.038→0.216 µs, `rotated` 0.048→0.507,
`angle` 0.047→0.332). Bound at `MAX_PROJECTILES = 400` all homing ≈ **+0.4 ms/tick**
against `BUDGET_MS = 11.0` with p95 already 8.9 ms. That is the cost commit 1 pays
and commit 2 recovers.

## Accuracy contract

Rev 2's "≤1 ULP relative" is **unmeetable as written** and fails its own listed
test points: `sin(PI)` and `cos(PI/2)` have true values ~1.2e-16 and ~6.1e-17 (the
residual of the double constants), and any reduction subtracting `PI` exactly
returns 0.0 — 100% relative error. "A few thousand revolutions out" is worse:
`k · TAU` rounds at `ULP(k·TAU)` ≈ 2.8e-14 at 250 rad (the perf fixture's `spin`
range), hundreds of double ULPs of the result.

Specify instead:

- **Cody–Waite range reduction** (2- or 3-term TAU split), not an asserted bound.
  It is cheap and removes the argument-range question entirely. (The counter-argument
  — that `_orbit_phase` is a `PackedFloat32Array` whose ULP at ~960 rad is 6.1e-5,
  nine orders larger than the reduction error — is true but is about *storage*; the
  spec still has to be meetable at the arguments the suite tests.)
- Error bound of the form `|err| <= 1 ULP(result) + c · ULP(a)`.
- Suite tolerance **≥ 2 ULP** when comparing against the platform's own `sin()` —
  that reference is itself ±1 ULP and differs between the macOS dev box and the
  Linux runner. Otherwise the determinism suite becomes the one platform-flaky
  thing in the repo.
- **Golden bit patterns** (exact float literals or `var_to_bytes` hex) for a dozen
  arguments. Cross-arch identity is guaranteed by construction; the goldens are the
  tripwire for someone re-ordering a Horner step and silently changing every replay.

## Enforcement

Extend `structural_determinism_rules` in `tests/test_determinism_rules.gd:216` —
it already greps source, owns `_func_body`, and strips comments. Do not add a
second suite that greps the same files for adjacent rules.

**Fail closed at BOTH levels.** Rev 2 inverted the function list but left the
*file* set an include list of four, which leaves `scripts/build/compiler.gd:169` —
a site this plan converts — unscanned, along with `player_stats.gd`,
`scripts/combat/`, `scripts/core/`, `scripts/net/lockstep.gd`, `data/*.gd`, and any
new simulation file. Instead:

- Scan **every** `.gd` under `scripts/`, `data/`, plus `tools/determinism_probe.gd`
  and `tests/support/`.
- Exempt **files** by an explicit presentation allowlist: `scripts/ui/`,
  `scripts/audio/`, `scripts/meta/`, `scripts/update/`, `run/feel.gd`,
  `run/props.gd`, `run/backdrop.gd`, `net/transport.gd`.
- Inside the rest, exempt **functions** by an explicit presentation allowlist
  (`_draw`, `_draw_ring`, `_draw_chunk`, `_update_renderers`, `_make_mm`,
  `_build_environment`, `_build_renderers`, `_prime_constant_instances`,
  `_depth_sort`, `_visible_world_rect`, `_void_runs`, `_route_points`,
  `_ground_quad`, `_age_fx`, `to_iso`). A sweep confirms the only transcendental
  users outside the scanned set are `props.gd:186,218`, `backdrop.gd`,
  `scripts/ui/`, `scripts/audio/` and `feel.gd:55` — all presentation.

**The scanner must recognise `static func`.** `_func_body`
(`test_determinism_rules.gd:288`) and the owner loop (`:249`) both match
`line.begins_with("func ")`. `to_iso` is `static func` (`run.gd:48`), so its
allowlist entry would be **dead**; `spawn_director.gd:43 hp_mult` and `:78
threshold_mult` are static and host two of the three `pow` sites;
`compiler.gd:168 _rank_factor` is static; `run.gd` has eight more. Match
`^(static )?func ` in both. There is no false negative today only by luck of
ordering — which is exactly what fail-closed is supposed to remove.

**Pattern details.** `\bsin\(` still matches `DetMath.sin(` because `\b` matches
after `.`; require `(^|[^.A-Za-z0-9_])sin\s*\(`. Comment stripping is
line-leading only (`:251`, `:262` test `strip_edges().begins_with("#")`), so a
trailing `foo() # pow(x)` false-positives — either strip from the first unquoted
`#` or state the limitation. Token set extends well past seven names:
`from_angle`, `slerp`, `lerp_angle`, `angle_to_point`, `ease`, `tan`, `acos`,
`asin`, `atan`, `sinh`, `cosh`, `tanh`, `exp`, `log`, `randfn`, `Transform2D(rot`.
`Vector2.from_angle` is the idiomatic Godot spelling of `DetMath.unit` and would
sail through a seven-name list.

**Test the guard fires**, with a `static func` host in the fixture — otherwise the
`static func` defect survives the very test written to catch it.

## Verification

1. `tools/run_tests.sh`. **Register the new suite in `SUITES`**
   (`tools/run_tests.sh:18-30`, a hard-coded list with no discovery).
   `tests/test_start_delay.gd` is already on disk and unregistered — fix in the
   same change. `test_determinism_rules` is already registered, so the deliverable
   is the new suite plus `test_start_delay`. `CLAUDE.md:12` says "56 suites" and
   should read 61.
2. **Diff the determinism probe before and after the conversion.** This replaces
   rev 2's "run the gate three times before and after", which is empty: the
   fixture is fixed-seed (`perf_fixture.gd:62`) with zero `Time.get_`/`randf`/
   `randomize` hits, so three runs of one build produce one number three times.
   Byte-identical ⇒ no re-pin possible or needed. Different ⇒ one gate run tells
   you where the new trajectory sits, and the re-pin is a judgement about that
   number. (Given the 78.6% measurement above, expect different.)
3. `tools/determinism_cross_arch.sh` — **new deliverable**, does not exist yet.
   Must exit non-zero on a diff; pin the Godot version to `ci.yml`'s; `set -euo
   pipefail` (the probe is piped through `grep`, and without it a crashed Godot
   yields an empty file that `diff` reports as divergence rather than a crash);
   copy CI's filter verbatim (`ci.yml:120`,
   `'^(# determinism probe|[0-9]+ -?[0-9]+$)'` — hashes print as `%d` and can be
   negative); log `grep -o -w fma /proc/cpuinfo | head -1` and `ldd --version` from
   each leg and **refuse to run when the amd64 leg lacks `fma`**, since glibc
   ifunc-selects `s_sinf-fma` on CPUID and a green local run must be comparable
   to CI; fail fast with a clear message when emulation is unavailable.
4. CI's job goes green — meaningful only **after** the harness sites are converted.

**CI is a weak proxy, and the guard is the load-bearing artefact.** glibc
ifunc-selects `__sin_fma`/`__cos_fma`/`__atan2_fma` by CPU feature, so two x86_64
machines can disagree exactly as arm64 vs x86_64 does; macOS and Windows use
different libms entirely. Also, the probe pins `director.elapsed = 999.0` and
`boss_spawned = true` on subnet 1, so `pow(HP_PER_SUBNET, n>0)`, `terrain.gd:679`,
`_advance_subnet`, minibosses and worms may never execute — "CI green" says
nothing about those sites. The guard covers them; the diff does not. Consider a
second seed and a longer `--ticks` in the cross-arch script.

Test coverage the suite must add: `angle(Vector2.ZERO)`, four axis vectors,
negative-zero components, both signs in every octant; `dsin`/`dcos` at ±π/4,
±π/2, ±π, ±TAU and a few thousand revolutions out; the `powi` contract and the
`MUL_FOLD_KEYS` invariant; guard-fires including a `static func` host; and for
commit 2, the homing hemisphere and antiparallel cases (target exactly behind
must turn at full rate; target at 179° must turn at full rate, not by `asin` of a
small cross). No test currently pins projectile coordinates after `rotated` — a
grep over `tests/` for `projectiles.(pos|vel)[…] ==` is empty — so the blast
radius of a trajectory change is the gate's coverage floor, not the unit suites.

## CLAUDE.md invariant

Write it as **"no libm transcendental reaches hashed state on any platform"**,
not "the two Linux runners agree". Cite `-ffp-contract=off` in all three
`detect.py` files, note the web platform sets no such flag, and note this
invariant is enforced **by process, not by a suite** — nothing in GDScript can
test it. Add the cross-arch script to every engine-version bump.

## Consequences

1. **A perf-gate re-pin is expected in commit 1** (78.6% of `rotated` calls
   change), not avoided. Re-pin off the post-change number with the reason
   written in, per the project's rule — do not pre-emptively move floors as a
   plan step, and do not re-pin off a spread that does not exist.
2. The probe's absolute hashes all change. Harmless — it compares arches, never a
   stored value.
3. Commit 1 costs up to +0.4 ms/tick; commit 2 recovers it.
4. A "dev" build passes the version handshake regardless of commit, so a pre-fix
   and post-fix dev build in one session desyncs wanderingly and looks exactly
   like the open relay bug. Worth a line in the co-op notes during the transition.

## Rejected

- **A `DetVector2` restricted type.** Withdrawn by the reviewer who raised it once
  given the packed-array constraint: geometry lives in `PackedVector2Array`, a
  GDScript wrapper would be a RefCounted object or Dictionary, and that is one heap
  object per entity per frame across 600 + 400 + 1500 pools.
- **Encapsulating the population arrays behind intent-based verbs.**
  Structurally sound, but a GDScript call per element access is the cost packed
  arrays exist to avoid. Possible later direction, not this change.
- **Gating on a further Docker FMA probe.** The ablation already provides
  1e7–1e8 identical contractable operations across both arches.

## Citations corrected from rev 2

`ci.yml` diff is at `:145` (not `:141`). `population.gd` is under
`scripts/combat/`, declarations at `:11`, `:20`, `:21`, `:22` (not `:4,13,14,15`).
`_state_hash`'s `hash(var_to_bytes(vals))` is `run.gd:5726` (not `:5727`).
`feel.gd` call is `:55` alone. The fractional branch is `compiler.gd:196` (not
`:197`). Rev 2's "10^9" ablation figure is ~1e7–1e8.

## Round history

**Round 1** (executor, auditor, antigravity, fable, opus — simplifier down on
OpenRouter credits): 5× REVISE. The probe's own libm was found independently by
all four grounded seats. Site count 12→9. Accuracy target restated. `powi`
contradiction. Guard inverted to fail closed.

**Debate**: the Architect's "type system, not linting" position was put against
the packed-array constraint and **withdrawn** — it flipped to APPROVED.

**Round 2** (executor, auditor, antigravity, fable, opus): antigravity APPROVED;
four REVISE. Found `perf_fixture.gd:332`, the `static func` blindness, the
`compiler.gd` file-set omission, the empty "3× before/after" mitigation, the
`\bsin\(` matching `DetMath.sin(`, and — decisively — that today's `.rotated()`
runs in float32, which falsified rev 2's "baselines very likely do not move".

One round-1 claim was **refuted**: the Executor reported `scripts/build/compiler.gd`
absent from the checkout. It exists; verified directly and cited correctly by
three other seats.
