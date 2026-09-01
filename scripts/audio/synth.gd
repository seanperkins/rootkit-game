class_name Synth extends RefCounted

## Every sound in the game, synthesized in code at boot.
##
## PURE, the way `scripts/build/` is pure — `AudioStreamWAV` is a `Resource`, so
## nothing here touches the scene tree and a suite can assert waveform, length
## and envelope headless.
##
## Procedural rather than sampled because the project has no image assets and no
## font files, and a folder of .ogg files would be the first binary content in
## the repo. It also means every sound is a row in a table that can be tuned in
## a diff.

enum Wave { SINE, SQUARE, SAW, NOISE }

## One rate for every sound. This was briefly a per-spec field, which is a
## constant in disguise — no entry in the table below varies it.
const SAMPLE_RATE := 22050

## 16-bit signed PCM, mono. Named rather than implied: "produces an
## AudioStreamWAV" is not a specification.
const AMPLITUDE := 32767.0

## Default spec. `build` merges over this, so a table row states only what it
## changes.
const DEFAULTS := {
	"wave": Wave.SINE,
	"f0": 440.0,       # start frequency
	"f1": 440.0,       # end frequency, swept linearly
	"dur": 0.12,
	"attack": 0.005,
	"decay": 0.03,
	"sustain": 0.5,    # level, not time
	"release": 0.06,
	"noise": 0.0,      # 0..1 mixed over the tone
	"gain": 0.7,
}

## id -> spec. Fire ids are added per VectorKind by `build_bank`, so a new
## vector kind cannot mint an id the bank has never heard of.
const EVENTS := {
	"hit":            {"wave": Wave.SQUARE, "f0": 620.0, "f1": 380.0, "dur": 0.05,
		"decay": 0.02, "sustain": 0.2, "release": 0.02, "noise": 0.35, "gain": 0.35},
	"kill":           {"wave": Wave.NOISE, "f0": 240.0, "f1": 90.0, "dur": 0.13,
		"noise": 0.8, "gain": 0.5},
	"flip":           {"wave": Wave.SINE, "f0": 520.0, "f1": 1180.0, "dur": 0.18,
		"sustain": 0.6, "gain": 0.45},
	"pickup":         {"wave": Wave.SQUARE, "f0": 880.0, "f1": 1320.0, "dur": 0.045,
		"decay": 0.01, "release": 0.02, "gain": 0.22},
	"level_up":       {"wave": Wave.SAW, "f0": 330.0, "f1": 990.0, "dur": 0.34,
		"sustain": 0.75, "release": 0.12, "gain": 0.6},
	"card_select":    {"wave": Wave.SQUARE, "f0": 700.0, "f1": 940.0, "dur": 0.07,
		"gain": 0.4},
	"card_decline":   {"wave": Wave.SQUARE, "f0": 500.0, "f1": 300.0, "dur": 0.09,
		"gain": 0.35},
	"hurt":           {"wave": Wave.SAW, "f0": 300.0, "f1": 110.0, "dur": 0.2,
		"noise": 0.45, "sustain": 0.55, "gain": 0.65},
	"low_integrity":  {"wave": Wave.SINE, "f0": 200.0, "f1": 150.0, "dur": 0.5,
		"attack": 0.05, "sustain": 0.7, "release": 0.25, "gain": 0.5},
	"miniboss_charge":{"wave": Wave.SAW, "f0": 120.0, "f1": 760.0, "dur": 0.9,
		"attack": 0.3, "decay": 0.1, "sustain": 0.85, "release": 0.2,
		"noise": 0.2, "gain": 0.5},
	"miniboss_arrive":{"wave": Wave.NOISE, "f0": 420.0, "f1": 70.0, "dur": 0.35,
		"noise": 0.85, "sustain": 0.5, "gain": 0.75},
	"miniboss_kill":  {"wave": Wave.SAW, "f0": 380.0, "f1": 90.0, "dur": 0.4,
		"noise": 0.5, "sustain": 0.6, "release": 0.15, "gain": 0.75},
	"ice_charge":     {"wave": Wave.SAW, "f0": 90.0, "f1": 620.0, "dur": 0.9,
		"attack": 0.35, "sustain": 0.9, "release": 0.2, "noise": 0.3, "gain": 0.6},
	"ice_arrive":     {"wave": Wave.NOISE, "f0": 520.0, "f1": 50.0, "dur": 0.45,
		"noise": 0.9, "sustain": 0.6, "gain": 0.9},
	"ice_kill":       {"wave": Wave.SAW, "f0": 440.0, "f1": 60.0, "dur": 0.7,
		"noise": 0.55, "sustain": 0.7, "release": 0.3, "gain": 0.9},
	"gate_open":      {"wave": Wave.SINE, "f0": 260.0, "f1": 780.0, "dur": 0.5,
		"attack": 0.08, "sustain": 0.8, "release": 0.2, "gain": 0.55},
	"collapse":       {"wave": Wave.NOISE, "f0": 180.0, "f1": 60.0, "dur": 0.8,
		"attack": 0.2, "noise": 0.95, "sustain": 0.7, "release": 0.3, "gain": 0.6},
	"win":            {"wave": Wave.SQUARE, "f0": 440.0, "f1": 1320.0, "dur": 0.7,
		"attack": 0.02, "sustain": 0.85, "release": 0.3, "gain": 0.7},
	"death":          {"wave": Wave.SAW, "f0": 320.0, "f1": 40.0, "dur": 0.9,
		"noise": 0.4, "sustain": 0.75, "release": 0.4, "gain": 0.8},
}

## The fire sound for one vector kind. Derived from the enum rather than written
## out, so `Module.VectorKind` being append-only (see CLAUDE.md) is what keeps
## the id set complete.
static func fire_id(kind: int) -> String:
	return "fire_%d" % kind

## Per-kind fire timbres, indexed by VectorKind. A missing entry falls back to
## the first, so appending a kind yields a real sound rather than a crash.
const FIRE_SPECS := [
	{"wave": Wave.SQUARE, "f0": 760.0, "f1": 520.0, "dur": 0.06, "gain": 0.28},
	{"wave": Wave.SQUARE, "f0": 900.0, "f1": 700.0, "dur": 0.05, "gain": 0.26},
	{"wave": Wave.SAW, "f0": 640.0, "f1": 1000.0, "dur": 0.07, "gain": 0.26},
	{"wave": Wave.SINE, "f0": 1200.0, "f1": 400.0, "dur": 0.09, "gain": 0.24},
	{"wave": Wave.NOISE, "f0": 700.0, "f1": 300.0, "dur": 0.08, "noise": 0.7,
		"gain": 0.26},
	{"wave": Wave.SINE, "f0": 300.0, "f1": 620.0, "dur": 0.1, "gain": 0.3},
	{"wave": Wave.SQUARE, "f0": 220.0, "f1": 160.0, "dur": 0.08, "gain": 0.3},
	{"wave": Wave.SINE, "f0": 980.0, "f1": 1240.0, "dur": 0.05, "gain": 0.2},
]

## Every id the game can play, spec included. `build_bank` is the only caller
## that matters, but the key set is what `test_audio_events` asserts against.
static func all_specs() -> Dictionary:
	var out := EVENTS.duplicate(true)
	for k in Module.VectorKind.size():
		var spec: Dictionary = (FIRE_SPECS[k] if k < FIRE_SPECS.size()
			else FIRE_SPECS[0]).duplicate()
		out[fire_id(k)] = spec
	return out

static func build_bank() -> Dictionary:
	var out := {}
	for id in all_specs():
		out[id] = build(all_specs()[id])
	return out

## ADSR that does not fit the duration is SCALED to fit rather than rejected.
## Otherwise "the envelope ends at silence" is unachievable for any spec whose
## attack plus decay plus release exceeds its length, and half this table would
## have to be hand-tuned around the constraint.
static func _envelope(spec: Dictionary, n: int) -> PackedFloat32Array:
	var dur: float = spec["dur"]
	var a: float = spec["attack"]
	var d: float = spec["decay"]
	var r: float = spec["release"]
	var total := a + d + r
	if total > dur and total > 0.0:
		var k := dur / total
		a *= k; d *= k; r *= k
	var sustain_level: float = spec["sustain"]
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / SAMPLE_RATE
		var e := 0.0
		if t < a and a > 0.0:
			e = t / a
		elif t < a + d and d > 0.0:
			e = lerpf(1.0, sustain_level, (t - a) / d)
		elif t < dur - r:
			e = sustain_level
		elif r > 0.0:
			# Lands on exactly 0.0 at t == dur, which is what makes the
			# "ends at silence" assertion hold for every row.
			e = sustain_level * maxf(0.0, (dur - t) / r)
		out[i] = clampf(e, 0.0, 1.0)
	return out

static func build(partial: Dictionary) -> AudioStreamWAV:
	var spec := DEFAULTS.duplicate()
	for k in partial:
		spec[k] = partial[k]

	var n := int(round(float(spec["dur"]) * SAMPLE_RATE))
	n = maxi(n, 1)
	var env := _envelope(spec, n)
	var rng := RandomNumberGenerator.new()
	# Seeded from the spec, so the same spec twice yields identical bytes and a
	# noise sound is still deterministic.
	rng.seed = hash(str(spec))

	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in n:
		var t := float(i) / float(n)
		var freq: float = lerpf(spec["f0"], spec["f1"], t)
		phase += TAU * freq / SAMPLE_RATE
		var tone := 0.0
		match int(spec["wave"]):
			Wave.SINE:   tone = sin(phase)
			Wave.SQUARE: tone = 1.0 if sin(phase) >= 0.0 else -1.0
			Wave.SAW:    tone = fmod(phase, TAU) / PI - 1.0
			Wave.NOISE:  tone = rng.randf_range(-1.0, 1.0)
		var nz: float = spec["noise"]
		if nz > 0.0 and int(spec["wave"]) != Wave.NOISE:
			tone = lerpf(tone, rng.randf_range(-1.0, 1.0), nz)
		var v := clampf(tone * env[i] * float(spec["gain"]), -1.0, 1.0)
		var s := int(v * AMPLITUDE)
		# Little-endian 16-bit signed.
		data[i * 2] = s & 0xFF
		data[i * 2 + 1] = (s >> 8) & 0xFF

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream
