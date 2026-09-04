class_name DetMath extends RefCounted

## Deterministic transcendentals for everything below the world guard.
##
## Lockstep rests on every peer evolving bit-identical state from the same
## records. libm does not provide that: glibc does not guarantee correctly
## rounded `sin`/`cos`/`atan2`/`pow`, its aarch64 and x86_64 implementations
## differ by ~1 ULP, and it even ifunc-selects `__sin_fma` variants by CPU
## feature — so two x86_64 machines can disagree with each other. macOS and
## Windows use different libms again. A runner-image update turned that latent
## difference into a hard CI failure on 2026-09-03; the game had the bug the
## whole time.
##
## Everything here is built from operations IEEE-754 requires to be CORRECTLY
## ROUNDED, and which are therefore bit-identical on every conforming
## implementation: `+ - * /`, `sqrt`, comparisons, and `floorf`. No call in this
## file reaches libm.
##
## TWO PRECONDITIONS, neither of which any test in this repo can check:
##
## 1. This class must stay in GDSCRIPT. Each arithmetic operator is a separate
##    VM instruction on doubles and cannot be fused, which is the whole reason
##    the approach works. Rewriting it in C++ for speed would reintroduce the
##    bug it exists to remove.
## 2. The engine must keep FP contraction off. `Vector2.dot/cross/length/
##    normalized` stay safe only because `-ffp-contract=off` is appended
##    unconditionally in `platform/linuxbsd/detect.py`, `platform/macos/detect.py`
##    and `platform/windows/detect.py` (MinGW), with `/fp:strict` for MSVC. With
##    contraction on, aarch64 fuses `x*x + y*y` and x86_64 SSE2 does not. The web
##    platform sets no such flag.
##
## ACCURACY, measured against this platform's libm over 30k samples per band
## (tests/test_deterministic_math.gd re-measures it):
##
##   |a| <= 10      worst absolute error 1.8e-15   (~8 double ULPs)
##   |a| <= 100      worst absolute error 1.4e-14
##   |a| <= 1000     worst absolute error 1.1e-13
##   _atan, any |t|  worst absolute error 2.2e-16   (1 double ULP)
##   dsin(PI)        4.4e-16 from libm's own residual; dcos(PI/2) 2.2e-16
##
## The error grows with reduction depth, and that is fine: every consumer stores
## the result in a float32 (`PackedVector2Array`, `PackedFloat32Array`), whose
## ULP is 5.96e-8. Even the 1000-rad figure is 2e-6 of one float32 ULP. The only
## argument in the game that grows without bound is `_orbit_phase` (run.gd),
## which reaches ~960 rad over a 24000-tick run.
##
## A "<= 1 ULP relative" contract was considered and rejected as unmeetable: it
## cannot hold at sin(PI) or cos(PI/2), whose true values are the ~1e-16
## residual of the double constants, and it is not what the consumers need.
##
## None of this is what makes lockstep work. Cross-architecture identity comes
## from the OPERATIONS, not the accuracy: the same source runs the same
## correctly-rounded arithmetic everywhere, so every peer gets the same bits
## whether or not those bits are the closest double to the true value. The
## goldens in the suite are the tripwire for someone reordering a Horner step
## and silently changing every replay.
##
## Naming: `dsin`/`dcos`, not `sin`/`cos`. A `static func sin()` here would
## shadow the global inside this file, so an unqualified `sin(x)` in a comment,
## a debug print or a future helper would resolve to itself and recurse.

# --- Cody-Waite split of PI/2 ------------------------------------------------
# PIO2_1 carries the leading 33 bits and its trailing bits are zero, so
# `n * PIO2_1` is EXACT for every quadrant index this game can produce. The
# remainder is subtracted in two further terms. Reducing against a single
# rounded TAU instead would accumulate ~4.4e-16 rad per revolution, which at the
# perf fixture's ~250 rad spin range is already hundreds of double ULPs of the
# result — enough to miss the accuracy contract and make the goldens meaningless.
const PIO2_1 := 1.57079632673412561417e+00
const PIO2_2 := 6.07710050630396597660e-11
const PIO2_2T := 2.02226624879595063154e-21
const TWO_OVER_PI := 6.36619772367581382433e-01

# fdlibm __kernel_sin, |r| <= pi/4
const S1 := -1.66666666666666324348e-01
const S2 := 8.33333333332248946124e-03
const S3 := -1.98412698298579493134e-04
const S4 := 2.75573137070700676789e-06
const S5 := -2.50507602534068634195e-08
const S6 := 1.58969099521155010221e-10

# fdlibm __kernel_cos, |r| <= pi/4
const C1 := 4.16666666666666019037e-02
const C2 := -1.38888888888741095749e-03
const C3 := 2.48015872894767294178e-05
const C4 := -2.75573143513906633035e-07
const C5 := 2.08757232129817482790e-09
const C6 := -1.13596475577881948265e-11

# fdlibm s_atan, segment endpoints and their low-order remainders
const ATAN_HI := [4.63647609000806093515e-01, 7.85398163397448278999e-01,
	9.82793723247329054082e-01, 1.57079632679489655800e+00]
const ATAN_LO := [2.26987774529616870924e-17, 3.06161699786838301793e-17,
	1.39033110312309984516e-17, 6.12323399573676603587e-17]
const AT0 := 3.33333333333329318027e-01
const AT1 := -1.99999999998764832476e-01
const AT2 := 1.42857142725034663711e-01
const AT3 := -1.11111104054623557880e-01
const AT4 := 9.09088713343650656196e-02
const AT5 := -7.69187620504482999495e-02
const AT6 := 6.66107313738753120669e-02
const AT7 := -5.83357013379057348645e-02
const AT8 := 4.97687799461593236017e-02
const AT9 := -3.65315727442169155270e-02
const AT10 := 1.62858201153657823623e-02

## The largest |angle| the reduction is contracted for. Beyond this the two-term
## split stops being enough and the result is still deterministic but no longer
## meets the accuracy bound. `_orbit_phase` (run.gd) accumulates ORBIT_RATE * dt
## with no wrap, so it is the argument that can grow; at 24000 ticks it reaches
## ~960 rad, comfortably inside this.
const MAX_ANGLE := 1.0e6

# ---------------------------------------------------------------- sin / cos ---

## The reduction is INLINED into each entry point rather than factored into a
## helper. A helper would have to return two values, and the only GDScript
## shapes for that — an Array or a Vector2 — either allocate per call on a path
## that runs per projectile per tick, or narrow the result to float32 and throw
## away the precision this whole class exists to provide. `sincos` returning a
## Vector2 did exactly that: it measured a 2.98e-8 worst error, which is half a
## float32 ULP, not an algorithm defect.
##
## Rounds to the nearest quadrant with floorf(x + 0.5) — total, deterministic,
## and not a libm call — then subtracts n*PI/2 in three exact pieces.

static func dsin(a: float) -> float:
	var n := floorf(a * TWO_OVER_PI + 0.5)
	var r := a - n * PIO2_1
	r = r - n * PIO2_2
	r = r - n * PIO2_2T
	match int(n - floorf(n * 0.25) * 4.0):
		0: return _kernel_sin(r)
		1: return _kernel_cos(r)
		2: return -_kernel_sin(r)
		_: return -_kernel_cos(r)
	return 0.0

static func dcos(a: float) -> float:
	var n := floorf(a * TWO_OVER_PI + 0.5)
	var r := a - n * PIO2_1
	r = r - n * PIO2_2
	r = r - n * PIO2_2T
	match int(n - floorf(n * 0.25) * 4.0):
		0: return _kernel_cos(r)
		1: return -_kernel_sin(r)
		2: return -_kernel_cos(r)
		_: return _kernel_sin(r)
	return 0.0

## The nine-site workhorse: the unit vector at angle `a`. One reduction for both
## components. Narrowing to float32 happens HERE, once, in the constructor —
## which is what the call sites were doing anyway.
static func unit(a: float) -> Vector2:
	var n := floorf(a * TWO_OVER_PI + 0.5)
	var r := a - n * PIO2_1
	r = r - n * PIO2_2
	r = r - n * PIO2_2T
	var s := _kernel_sin(r)
	var c := _kernel_cos(r)
	match int(n - floorf(n * 0.25) * 4.0):
		0: return Vector2(c, s)
		1: return Vector2(-s, c)
		2: return Vector2(-c, -s)
		_: return Vector2(s, -c)
	return Vector2.ZERO

static func _kernel_sin(x: float) -> float:
	var z := x * x
	var v := z * x
	var r := S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)))
	return x + v * (S1 + z * r)

static func _kernel_cos(x: float) -> float:
	var z := x * x
	var r := z * (C1 + z * (C2 + z * (C3 + z * (C4 + z * (C5 + z * C6)))))
	return 1.0 - (0.5 * z - z * r)

# ------------------------------------------------------------------ rotate ---

## Rotate `v` by `a`. One reduction, then a complex multiply.
static func rotate(v: Vector2, a: float) -> Vector2:
	return rotate_sc(v, dsin(a), dcos(a))

## Rotate by a PRECOMPUTED (sin, cos) pair. The homing steer's turn cap is a
## per-exploit constant, so its pair is computed once rather than per projectile
## per tick — which is where the cost of an interpreted polynomial would land.
static func rotate_sc(v: Vector2, s: float, c: float) -> Vector2:
	return Vector2(v.x * c - v.y * s, v.x * s + v.y * c)

# ------------------------------------------------------------------- atan2 ---

## The angle of `v`, in (-PI, PI].
##
## Every degenerate case is decided BEFORE any division. A naive octant
## reduction divides by zero: `atan2(0, 0)` is 0.0 in every libm, but `0.0/0.0`
## in GDScript is a silent NaN, and homing takes the angle of
## `enemies.pos[j] - projectiles.pos[i]` on float32 positions that can coincide
## exactly. A NaN would reach `vel`, then `pos`, then `int(floor(NaN))` in the
## grid insert — a conversion whose result is ISA-defined (x86 INT_MIN, ARM 0) —
## and `_state_hash` hashes raw bytes, where x86's quiet NaN is 0xFFC00000 and
## ARM's is 0x7FC00000. Two peers that "agree" the value is NaN still desync,
## permanently.
##
## Deliberate divergence from libm, accepted because it is deterministic: a
## negative-zero `y` is treated as `+0`, so `angle(Vector2(-1, -0.0))` is PI
## where libm gives -PI. Nothing in the simulation distinguishes them.
static func angle(v: Vector2) -> float:
	var x := v.x
	var y := v.y
	if y == 0.0:
		return 0.0 if x > 0.0 else (PI if x < 0.0 else 0.0)
	if x == 0.0:
		return PI * 0.5 if y > 0.0 else -PI * 0.5
	# Keep the ratio inside [-1, 1] so the segmented atan never sees a huge
	# argument; the swap costs one comparison and buys the whole accuracy claim.
	var ax := absf(x)
	var ay := absf(y)
	var base: float
	if ay <= ax:
		base = _atan(y / x)
		if x < 0.0:
			base = base + PI if y > 0.0 else base - PI
	else:
		base = _atan(x / y)
		base = PI * 0.5 - base if y > 0.0 else -PI * 0.5 - base
	return base

## Signed angle from `a` to `b`, in (-PI, PI]. Matches Vector2.angle_to's
## contract (atan2(cross, dot)) without its atan2.
static func angle_between(a: Vector2, b: Vector2) -> float:
	return angle(Vector2(a.x * b.x + a.y * b.y, a.x * b.y - a.y * b.x))

## fdlibm s_atan, segmented so the polynomial only ever sees |t| < 0.4375.
static func _atan(t: float) -> float:
	var neg := t < 0.0
	var x := absf(t)
	var id := -1
	if x >= 0.4375:
		if x < 1.1875:
			if x < 0.6875:
				id = 0
				x = (2.0 * x - 1.0) / (2.0 + x)
			else:
				id = 1
				x = (x - 1.0) / (x + 1.0)
		elif x < 2.4375:
			id = 2
			x = (x - 1.5) / (1.0 + 1.5 * x)
		else:
			id = 3
			x = -1.0 / x
	var z := x * x
	var w := z * z
	var s1 := z * (AT0 + w * (AT2 + w * (AT4 + w * (AT6 + w * (AT8 + w * AT10)))))
	var s2 := w * (AT1 + w * (AT3 + w * (AT5 + w * (AT7 + w * AT9))))
	var r: float
	if id < 0:
		r = x - x * (s1 + s2)
	else:
		var hi: float = ATAN_HI[id]
		var lo: float = ATAN_LO[id]
		r = hi - ((x * (s1 + s2) - lo) - x)
	return -r if neg else r

# -------------------------------------------------------------------- powi ---

## `base` to an INTEGER power, by left-to-right repeated multiplication.
##
## Left-to-right, not binary exponentiation, and the distinction is not
## pedantic: `((x*x)*x)*x` and `(x*x)*(x*x)` round differently. Both are
## deterministic; only one can be the contract, and the suite asserts THIS one.
##
## `pow` is in scope even though its arguments here are constants, because
## glibc's `pow` is not correctly rounded either (~0.52 ULP worst case) and
## ships ifunc-selected FMA variants. `hp_mult` and `_rank_factor` run on every
## peer, and a macOS-versus-Linux pair uses a different libm entirely — one last
## bit in `pow(0.82, 3)` makes `cadence_mult` differ from the first card pick.
static func powi(base: float, n: int) -> float:
	if n == 0:
		return 1.0
	if n < 0:
		return 1.0 / powi(base, -n)
	var r := base
	for _i in range(1, n):
		r *= base
	return r
