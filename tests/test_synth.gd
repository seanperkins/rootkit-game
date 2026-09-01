extends SceneTree

## The synth is pure and produces a Resource, so everything about it is
## assertable headless: length, clipping, determinism, and the envelope tail.

var failures := 0
var finished := {}

const CASES := ["length_matches_duration", "never_clips", "is_deterministic",
	"ends_at_silence", "crowded_adsr_is_normalised", "bank_covers_every_id"]

func _initialize() -> void:
	print("ROOTKIT — synth\n")
	length_matches_duration()
	never_clips()
	is_deterministic()
	ends_at_silence()
	crowded_adsr_is_normalised()
	bank_covers_every_id()
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
	for id in Synth.all_specs():
		for s in _samples(Synth.build(Synth.all_specs()[id])):
			worst = maxf(worst, absf(s))
	_check_true("no sample in the whole bank exceeds full scale", worst <= 1.0)
	finished["never_clips"] = true

func is_deterministic() -> void:
	var a := Synth.build(Synth.EVENTS["kill"])
	var b := Synth.build(Synth.EVENTS["kill"])
	_check("the same spec twice yields identical bytes", a.data, b.data)
	finished["is_deterministic"] = true

func ends_at_silence() -> void:
	for id in Synth.all_specs():
		var s := _samples(Synth.build(Synth.all_specs()[id]))
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
	_check("bank size covers events plus one fire per vector kind",
		bank.size(), Synth.EVENTS.size() + Module.VectorKind.size())
	finished["bank_covers_every_id"] = true
