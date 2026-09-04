extends SceneTree

## DetMath — the deterministic transcendentals the tick runs on.
##
## What this suite can and cannot prove. It CANNOT prove cross-architecture
## identity: that comes from the operations being correctly-rounded IEEE basics,
## and only `tools/determinism_cross_arch.sh` and CI's two-runner diff can
## witness it. What it pins is everything that would silently break that
## property or the behaviour built on it:
##
##   - the degenerate inputs that would produce NaN, which is an instant
##     permanent desync because x86 and ARM disagree on the quiet-NaN payload
##     and `_state_hash` hashes raw bytes;
##   - the accuracy actually delivered, band by band, so a regression in the
##     range reduction is caught here rather than as a mysterious balance shift;
##   - GOLDEN BIT PATTERNS, which are the tripwire for someone reordering a
##     Horner step: the reordered version is still perfectly deterministic and
##     still passes every tolerance check, and would silently change every
##     replay and every recorded co-op session;
##   - `powi`'s contract, which is left-to-right multiplication and NOT binary
##     exponentiation — the two round differently and only one can be the rule.

var failures := 0
var checks := 0

func _initialize() -> void:
	print("ROOTKIT — deterministic math\n")
	degenerate_inputs_never_produce_nan()
	angle_matches_atan2_on_the_axes()
	accuracy_holds_band_by_band()
	reduction_seams_are_exact()
	golden_bits_are_unchanged()
	powi_is_left_to_right()
	print("")
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	checks += 1
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _within(label: String, got: float, want: float, tol: float) -> void:
	checks += 1
	if absf(got - want) <= tol:
		print("  ok    %s" % label)
	else:
		print("  FAIL  ", label, " — got ", String.num(got, 17), ", want ",
			String.num(want, 17), " (tol ", String.num(tol, 17), ")")
		failures += 1

## The whole reason `angle` decides its cases before dividing. A coincident
## source and target is reachable: homing takes the angle of
## `enemies.pos[j] - projectiles.pos[i]` on float32 positions.
func degenerate_inputs_never_produce_nan() -> void:
	var cases := [Vector2.ZERO, Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1),
		Vector2(0, -1), Vector2(1, 1), Vector2(-1, -1), Vector2(1e-30, 0.0),
		Vector2(0.0, 1e-30), Vector2(1e30, 1e30), Vector2(-0.0, -0.0)]
	for v in cases:
		var a: float = DetMath.angle(v)
		_check("angle%s is finite" % v, is_finite(a), true)
	# And the same for the producers, including a huge argument.
	for x in [0.0, -0.0, 1e-30, 1e6, -1e6, PI, TAU, 960.0]:
		_check("dsin(%s) finite" % x, is_finite(DetMath.dsin(x)), true)
		_check("dcos(%s) finite" % x, is_finite(DetMath.dcos(x)), true)
		_check("unit(%s) finite" % x, DetMath.unit(x).is_finite(), true)

## `angle` replaces `Vector2.angle()`/`angle_to()`, so it must agree with atan2
## exactly where the answer is exactly representable — the axes and diagonals.
func angle_matches_atan2_on_the_axes() -> void:
	_check("angle(ZERO) is 0, as atan2(0,0) is", DetMath.angle(Vector2.ZERO), 0.0)
	for v in [Vector2(1, 0), Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0),
			Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1),
			Vector2(3, 4), Vector2(-3, 4), Vector2(3, -4), Vector2(-3, -4)]:
		_check("angle%s == atan2" % v, DetMath.angle(v), atan2(v.y, v.x))

## The measured contract from det_math.gd's header. Bands, not one number: the
## error grows with reduction depth and the header says so, so a change that
## breaks the reduction shows up as a band moving rather than as nothing.
func accuracy_holds_band_by_band() -> void:
	# |a| <= 10 is bit-identical to the platform libm. Asserting equality here
	# is safe BECAUSE it is not the determinism claim — if a future libm makes
	# this band non-zero, the tolerance below still holds and only this line
	# needs relaxing.
	_within("|a| <= 10 : dsin within 4e-15", _worst_sin(-10.0, 10.0, 4000), 0.0, 4e-15)
	_within("|a| <= 10 : dcos within 4e-15", _worst_cos(-10.0, 10.0, 4000), 0.0, 4e-15)
	_within("|a| <= 100 : dsin within 3e-14", _worst_sin(-100.0, 100.0, 4000), 0.0, 3e-14)
	_within("|a| <= 1000 : dsin within 3e-13", _worst_sin(-1000.0, 1000.0, 4000), 0.0, 3e-13)
	# _orbit_phase's live range over a full 24000-tick run.
	_within("orbit phase range : dsin within 3e-13", _worst_sin(0.0, 960.0, 4000), 0.0, 3e-13)
	var wa := 0.0
	for k in 4000:
		var t := (float(k) / 4000.0 - 0.5) * 40.0
		wa = maxf(wa, absf(DetMath._atan(t) - atan(t)))
	_within("_atan within 1e-15 over +/-20 (1 ULP)", wa, 0.0, 1e-15)

func _worst_sin(lo: float, hi: float, n: int) -> float:
	var w := 0.0
	for k in n:
		var a := lo + (hi - lo) * float(k) / float(n)
		w = maxf(w, absf(DetMath.dsin(a) - sin(a)))
	return w

func _worst_cos(lo: float, hi: float, n: int) -> float:
	var w := 0.0
	for k in n:
		var a := lo + (hi - lo) * float(k) / float(n)
		w = maxf(w, absf(DetMath.dcos(a) - cos(a)))
	return w

## The quadrant seams, where a range reduction that is off by one quadrant
## produces a plausible-looking wrong answer rather than a crash.
func reduction_seams_are_exact() -> void:
	_within("dsin(0)", DetMath.dsin(0.0), 0.0, 0.0)
	_within("dcos(0)", DetMath.dcos(0.0), 1.0, 0.0)
	_within("dsin(PI) matches libm to 1e-15", DetMath.dsin(PI), sin(PI), 1e-15)
	_within("dcos(PI/2) matches libm to 1e-15", DetMath.dcos(PI * 0.5), cos(PI * 0.5), 1e-15)
	for m in [-2.0, -1.5, -1.0, -0.5, -0.25, 0.25, 0.5, 1.0, 1.5, 2.0]:
		var a: float = PI * m
		_within("dsin(%s*PI)" % m, DetMath.dsin(a), sin(a), 1e-15)
		_within("dcos(%s*PI)" % m, DetMath.dcos(a), cos(a), 1e-15)
	# A few thousand revolutions out, where a single rounded TAU would have
	# accumulated hundreds of ULPs of phase.
	for rev in [100.0, 1000.0]:
		var a2: float = TAU * rev + 0.5
		_within("dsin(%s revolutions + 0.5)" % rev, DetMath.dsin(a2), sin(a2), 1e-12)

## Golden bits. Cross-arch identity is guaranteed by construction, so what these
## catch is a REORDERING — an algebraically equivalent rearrangement that is
## still deterministic, still accurate, and silently changes every stored replay
## and every co-op session recorded against the old bits.
##
## Regenerate deliberately, never to make a red suite green: a diff here means
## either an intended algorithm change (update them in the same commit, and
## expect the perf gate's coverage to move) or an accident.
func golden_bits_are_unchanged() -> void:
	for i in GOLDEN_ARGS.size():
		var a: float = GOLDEN_ARGS[i]
		var got := var_to_bytes(DetMath.dsin(a)).hex_encode()
		var expect: String = GOLDEN_SIN[i]
		if expect == "":
			print("  note  golden dsin(%s) = %s   <- paste into GOLDEN_SIN" % [a, got])
			continue
		_check("golden dsin(%s)" % a, got, expect)

const GOLDEN_ARGS := [0.5, 1.0, -1.0, 2.399963, 100.0, 960.0]
## Byte patterns of `dsin(GOLDEN_ARGS[i])` from `var_to_bytes`, little-endian.
const GOLDEN_SIN := [
	"03000100f0054b74e8aede3f",   # dsin(0.5)
	"03000100ed0c098f54edea3f",   # dsin(1.0)
	"03000100ed0c098f54edeabf",   # dsin(-1.0)
	"03000100b13b452d9e9de53f",   # dsin(2.399963) — the probe's spawn constant
	"03000100264e8cb72534e0bf",   # dsin(100.0)
	"030001003088e54d720eefbf",   # dsin(960.0) — orbit phase at 24000 ticks
]

## Left-to-right repeated multiplication. Binary exponentiation computes
## ((x*x)*x)*x for n=4 as (x*x)*(x*x) and rounds differently; both are
## deterministic and only one can be the contract.
func powi_is_left_to_right() -> void:
	_check("powi(x, 0) == 1", DetMath.powi(7.3, 0), 1.0)
	_check("powi(x, 1) == x", DetMath.powi(7.3, 1), 7.3)
	_check("powi(2, -2) == 0.25", DetMath.powi(2.0, -2), 0.25)
	for base in [1.55, 0.82, 1.15, 3.7]:
		for n in range(2, 6):
			var expect: float = base
			for _i in range(1, n):
				expect *= base
			_check("powi(%s, %d) is left-to-right" % [base, n], DetMath.powi(base, n), expect)
	# The exponents actually in play: spawn_director's subnet index and
	# compiler's module rank.
	_check("powi(1.55, 0) — subnet 1", DetMath.powi(1.55, 0), 1.0)
	_check("powi(1.55, 2) — subnet 3", DetMath.powi(1.55, 2), 1.55 * 1.55)
