extends SceneTree

## The pure half of the feel layer: trauma, the damage number pool, and the sfx
## drain. Everything here runs without a viewport, which is the point of keeping
## Feel a RefCounted.
##
## The hitstop no longer lives here — it is a fixed tick count on run.gd. Its
## behaviour is asserted in test_determinism_rules against the real tick.

var failures := 0
var finished := {}

const CASES := ["trauma_saturates", "offset_is_bounded", "squaring_is_gentle",
	"trauma_decays_to_zero", "numbers_cap_and_prune",
	"sfx_drains_once", "impact_pool_and_recoil_are_bounded"]

func _initialize() -> void:
	print("ROOTKIT — feel\n")
	trauma_saturates()
	offset_is_bounded()
	squaring_is_gentle()
	trauma_decays_to_zero()
	numbers_cap_and_prune()
	sfx_drains_once()
	impact_pool_and_recoil_are_bounded()
	print("")
	for c in CASES:
		if not finished.has(c):
			print("  FAIL  case '%s' never finished — it aborted part way" % c)
			failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want or (got is float and want is float and abs(got - want) < 1e-5):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _check_true(label: String, got: bool) -> void:
	_check(label, got, true)

## The worst case the noise contract allows: full magnitude, on the diagonal.
func _worst_noise() -> Vector2:
	return Vector2(1, 1).normalized()

## Stacked events saturate. Twelve detonations at 0.15 is 1.8 unclamped, which
## would put the offset at 3.24x MAX_OFFSET and make the constant a lie.
func trauma_saturates() -> void:
	var f := Feel.new()
	for i in 12:
		f.add_trauma(0.15)
	_check("twelve detonations clamp to 1.0", f.trauma, 1.0)
	f.add_trauma(-5.0)
	_check("and trauma never goes negative", f.trauma, 0.0)
	finished["trauma_saturates"] = true

## The bound MAX_OFFSET promises, driven by STACKED events rather than one — a
## single event proves nothing about the clamp.
func offset_is_bounded() -> void:
	var f := Feel.new()
	f.set_noise(_worst_noise)
	f.add_trauma(0.8)   # ICE materialize
	f.add_trauma(0.75)  # a simultaneous player hit
	var o := f.shake_offset()
	_check_true("stacked ICE + hit stays inside MAX_OFFSET",
		o.length() <= Feel.MAX_OFFSET + 1e-4)
	_check_true("and it is actually shaking", o.length() > 0.0)
	finished["offset_is_bounded"] = true

## Squaring is what makes one tunable cover a nudge and a slam.
func squaring_is_gentle() -> void:
	var f := Feel.new()
	f.set_noise(_worst_noise)
	f.add_trauma(0.3)
	var o := f.shake_offset()
	_check_true("trauma 0.3 gives at most 9% of maximum",
		o.length() <= Feel.MAX_OFFSET * 0.09 + 1e-4)
	finished["squaring_is_gentle"] = true

func trauma_decays_to_zero() -> void:
	var f := Feel.new()
	f.add_trauma(1.0)
	for i in 120:
		f.step(1.0 / 60.0)
	_check("trauma reaches exactly zero", f.trauma, 0.0)
	_check("and a zero-trauma offset is zero", f.shake_offset(), Vector2.ZERO)
	finished["trauma_decays_to_zero"] = true

func numbers_cap_and_prune() -> void:
	var f := Feel.new()
	for i in Feel.NUMBER_CAP + 6:
		f.add_number(Vector2(i, 0), str(i), Color.WHITE)
	_check("the pool caps", f.numbers.size(), Feel.NUMBER_CAP)
	_check("and evicts the oldest, not the newest", f.numbers[0][1], "6")
	# Expired rows must be pruned or they hold the cap forever.
	f.step(Feel.NUMBER_LIFE + 0.01)
	_check("expiry prunes the pool", f.numbers.size(), 0)
	finished["numbers_cap_and_prune"] = true

func sfx_drains_once() -> void:
	var f := Feel.new()
	f.emit("kill")
	f.emit("flip")
	var first := f.drain_sfx()
	_check("the drain returns what was emitted", first.size(), 2)
	_check("in order", first[0], "kill")
	_check("and the list is empty after", f.drain_sfx().size(), 0)
	finished["sfx_drains_once"] = true

func impact_pool_and_recoil_are_bounded() -> void:
	var f := Feel.new()
	for i in 100:
		f.add_impact(Vector2(i, 0), Vector2.ZERO, Color.WHITE, i % 2 == 0)
		f.kick(0)
	_check("dense cascades cannot grow the impact pool", f.impacts.size(), Feel.IMPACT_CAP)
	_check("repeated firing cannot stack displacement", f.recoil[0], 1.0)
	_check("a stationary impact has a valid direction", f.impacts[0][1], Vector2.RIGHT)
	f.step(Feel.IMPACT_LIFE + 0.01)
	_check("presentation aging clears old armor fragments", f.impacts.size(), 0)
	_check("and restores the weapon mount", f.recoil[0], 0.0)
	finished["impact_pool_and_recoil_are_bounded"] = true
