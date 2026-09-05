extends SceneTree

## The synth is pure and produces a Resource, so everything about it is
## assertable headless: length, clipping, determinism, and the envelope tail.

var failures := 0
var finished := {}

const CASES := ["length_matches_duration", "never_clips", "is_deterministic",
	"ends_at_silence", "crowded_adsr_is_normalised", "bank_covers_every_id",
	"the_pool_actually_varies", "oscillators_are_band_limited"]

func _initialize() -> void:
	print("ROOTKIT — synth\n")
	length_matches_duration()
	never_clips()
	is_deterministic()
	ends_at_silence()
	crowded_adsr_is_normalised()
	bank_covers_every_id()
	the_pool_actually_varies()
	oscillators_are_band_limited()
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

## Decode little-endian signed 16-bit back to floats.
func _samples(st: AudioStreamWAV) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var d := st.data
	out.resize(d.size() / 2)
	for i in out.size():
		var lo := d[i * 2]
		var hi := d[i * 2 + 1]
		var v := lo | (hi << 8)
		if v >= 32768:
			v -= 65536
		out[i] = float(v) / 32767.0
	return out

func length_matches_duration() -> void:
	var st := Synth.build({"dur": 0.25})
	var want := int(round(0.25 * Synth.SAMPLE_RATE))
	_check("sample count is duration x rate", _samples(st).size(), want)
	_check("and the stream reports the rate", st.mix_rate, Synth.SAMPLE_RATE)
	_check("mono", st.stereo, false)
	finished["length_matches_duration"] = true

## Gain is applied before the clamp, so a loud spec must still land in range —
## a wrapped sample is a click.
func never_clips() -> void:
	var worst := 0.0
	var specs := Synth.all_specs()
	for id in specs:
		for v in Synth.VARIANTS:
			for s in _samples(Synth.build(specs[id], v)):
				worst = maxf(worst, absf(s))
	_check_true("no sample in the whole bank exceeds full scale", worst <= 1.0)
	finished["never_clips"] = true

func is_deterministic() -> void:
	var a := Synth.build(Synth.EVENTS["kill"])
	var b := Synth.build(Synth.EVENTS["kill"])
	_check("the same spec twice yields identical bytes", a.data, b.data)
	finished["is_deterministic"] = true

func ends_at_silence() -> void:
	var specs2 := Synth.all_specs()
	for id in specs2:
		var s := _samples(Synth.build(specs2[id]))
		if s.is_empty():
			_check("%s produced samples" % id, false, true)
			continue
		if absf(s[s.size() - 1]) > 0.02:
			_check("%s ends silent" % id, s[s.size() - 1], 0.0)
	_check_true("every bank sound ends at silence", true)
	finished["ends_at_silence"] = true

## attack + decay + release longer than the sound. Normalised to fit rather than
## rejected, or the tail never reaches zero and the case above fails.
func crowded_adsr_is_normalised() -> void:
	var st := Synth.build({"dur": 0.05, "attack": 0.2, "decay": 0.2,
		"release": 0.2})
	var s := _samples(st)
	_check_true("a crowded envelope still produces samples", s.size() > 0)
	_check_true("and still ends silent", absf(s[s.size() - 1]) <= 0.02)
	finished["crowded_adsr_is_normalised"] = true

## The bank must answer for every id the game can generate — including one fire
## id per VectorKind, which is derived from the enum rather than written out.
func bank_covers_every_id() -> void:
	var bank := Synth.build_bank()
	for k in Module.VectorKind.size():
		var id := Synth.fire_id(k)
		_check_true("the bank has %s" % id, bank.has(id))
	for id in Synth.EVENTS:
		_check_true("the bank has %s" % id, bank.has(id))
	_check("bank covers every synthesized spec",
		bank.size(), Synth.all_specs().size())
	for id in bank:
		_check("%s is a pool, not a lone buffer" % id,
			bank[id].size(), Synth.VARIANTS)
	finished["bank_covers_every_id"] = true

## The failure mode game-audio writing warns about most loudly is one asset
## played forever with pitch jitter on top — still one asset, and the ear locks
## onto it. So the variants must genuinely differ from each other.
func the_pool_actually_varies() -> void:
	var bank := Synth.build_bank()
	var thin := []
	for id in bank:
		var pool: Array = bank[id]
		var distinct := []
		for st in pool:
			var sig := str(st.data.size()) + ":" + str(hash(st.data))
			if not distinct.has(sig):
				distinct.append(sig)
		if distinct.size() < Synth.VARIANTS:
			thin.append("%s(%d/%d)" % [id, distinct.size(), Synth.VARIANTS])
	# EVERY id, not a sample of three. Checking three is what let every fire
	# sound ship with six variants that collapsed to three distinct buffers —
	# they have neither noise to reseed nor, at the time, steps to transpose.
	_check("every id in the bank has fully distinct variants", thin, [])
	_check("the bank is not empty", bank.size() > 0, true)
	finished["the_pool_actually_varies"] = true

## A naive square jumps +1 to -1 between adjacent samples — a step of 2.0 — and
## carries harmonics past Nyquist that fold back as INHARMONIC partials: at
## 1.2 kHz the 11th harmonic lands at 13.2 kHz and reflects to 8.85 kHz, which
## is not a multiple of 1200 and does not track a pitch sweep. That grit is what
## made these read as cheap rather than merely lo-fi.
##
## Measured against an actual naive oscillator rather than a magic threshold, so
## the case proves the difference instead of asserting a number I picked.
func oscillators_are_band_limited() -> void:
	var freq := 1200.0
	# What the naive form would do, at the same rate and frequency.
	var naive_worst := 0.0
	var prev := 0.0
	var phase := 0.0
	for i in int(0.1 * Synth.SAMPLE_RATE):
		phase += TAU * freq / Synth.SAMPLE_RATE
		var v: float = 1.0 if sin(phase) >= 0.0 else -1.0
		if i > 0:
			naive_worst = maxf(naive_worst, absf(v - prev))
		prev = v
	_check_true("the naive form really does step by ~2.0", naive_worst > 1.9)

	for wave in [Synth.Wave.SQUARE, Synth.Wave.SAW]:
		var st := Synth.build({"wave": wave, "f0": freq, "f1": freq,
			"dur": 0.1, "attack": 0.0, "decay": 0.0, "release": 0.0,
			"sustain": 1.0, "gain": 1.0})
		var sm := _samples(st)
		var worst := 0.0
		for i in range(1, sm.size()):
			worst = maxf(worst, absf(sm[i] - sm[i - 1]))
		# Half the naive slew is a wide margin — the measured values are around
		# a third — and it cannot pass for anything that still has a hard edge.
		_check_true("wave %d slews %.3f, under half the naive %.3f"
			% [wave, worst, naive_worst], worst < naive_worst * 0.5)
	finished["oscillators_are_band_limited"] = true
