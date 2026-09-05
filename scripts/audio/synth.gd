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
##
## 22050 is enough once the oscillators are band-limited. Raising it to 44100
## was tried and reverted: band-LIMITING is what removes the aliasing, not
## headroom, and at 44100 the bank cost 4.6 MB and twelve seconds of boot. At
## 22050 a 400 Hz tone still carries 27 harmonics to 10.8 kHz, which is more
## than a 50 ms blip needs.
const SAMPLE_RATE := 22050

## How many distinct buffers are generated per event id.
##
## This is the fix for the failure mode game audio writing warns about most
## loudly: one asset plus pitch randomisation is still recognisably one asset,
## and the ear locks onto it. Six buffers cut from different noise seeds and
## slightly different envelopes, chosen at random per play, is the cheap version
## of the variation pools that middleware gives you.
##
## Six, so a scale-stepped sound gets a full pentatonic run rather than a
## truncated one. The bank is cached per process, so the cost is paid once.
const VARIANTS := 6

## 16-bit signed PCM, mono. Named rather than implied: "produces an
## AudioStreamWAV" is not a specification.
const AMPLITUDE := 32767.0

## Default spec. `build` merges over this, so a table row states only what it
## changes.
const DEFAULTS := {
	"vibrato_rate": 0.0,
	"vibrato_depth": 0.0,
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
	# Semitone offsets, one per variant, cycled. This is how a tonal sound gets
	# AUDIBLE variation: detuning by a few percent is inaudible on a 50ms blip,
	# and the noise reseed that varies `hit` and `kill` does nothing at all when
	# `noise` is 0. Steps drawn from a scale also keep a sound that plays
	# hundreds of times per run from fighting the music.
	"steps": [0],
}

## id -> spec. Fire ids are added per VectorKind by `build_bank`, so a new
## vector kind cannot mint an id the bank has never heard of.
const EVENTS := {
	# Three weight classes, not one hit. The player lands hundreds of these a
	# run, so they are both the loudest fatigue risk and the cheapest place to
	# put information: how SOLID a thing feels is something the ear reads
	# instantly and the HUD cannot show without a health bar on every enemy.
	#
	# Light: high, short, papery. Heavy: low, longer, more noise — it reads as
	# thudding into something that is not going to fall over.
	"hit_light":      {"wave": Wave.SQUARE, "f0": 780.0, "f1": 520.0, "dur": 0.035,
		"decay": 0.015, "sustain": 0.15, "release": 0.015, "noise": 0.3,
		"gain": 0.13, "steps": [0, -2, 2, -4, 4, -5]},
	"hit_medium":     {"wave": Wave.SQUARE, "f0": 520.0, "f1": 330.0, "dur": 0.05,
		"decay": 0.02, "sustain": 0.2, "release": 0.02, "noise": 0.4,
		"gain": 0.15, "steps": [0, -2, 2, -4, 3, -5]},
	"hit_heavy":      {"wave": Wave.SAW, "f0": 300.0, "f1": 150.0, "dur": 0.085,
		"decay": 0.03, "sustain": 0.3, "release": 0.04, "noise": 0.55,
		"gain": 0.18, "steps": [0, -2, 1, -3, 2, -5]},
	# Down from 0.5. A kill now lands on top of a hit rather than instead of
	# one, and at the enemy cap they arrive by the dozen.
	"kill":           {"wave": Wave.NOISE, "f0": 240.0, "f1": 90.0, "dur": 0.12,
		"noise": 0.8, "gain": 0.26, "steps": [0, -2, -4, 2, -6, -1]},
	"flip":           {"wave": Wave.SINE, "f0": 520.0, "f1": 1180.0, "dur": 0.18,
		"sustain": 0.6, "gain": 0.42, "steps": [0, 3, 7, 5]},
	# The most frequent sound in the game by a wide margin — one per shard, and
	# a magnet build sweeps up dozens a second. Quiet, short, and stepped
	# through a minor pentatonic so a run of pickups reads as a flourish rather
	# than as one blip stuttering.
	"pickup":         {"wave": Wave.SQUARE, "f0": 880.0, "f1": 1180.0, "dur": 0.04,
		"decay": 0.01, "release": 0.02, "gain": 0.085,
		"steps": [0, 3, 5, 7, 10, 12]},
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
	"sentinel_charge":     {"wave": Wave.SAW, "f0": 90.0, "f1": 620.0, "dur": 0.9,
		"attack": 0.35, "sustain": 0.9, "release": 0.2, "noise": 0.3, "gain": 0.6},
	"sentinel_arrive":     {"wave": Wave.NOISE, "f0": 520.0, "f1": 50.0, "dur": 0.45,
		"noise": 0.9, "sustain": 0.6, "gain": 0.9},
	"sentinel_kill":       {"wave": Wave.SAW, "f0": 440.0, "f1": 60.0, "dur": 0.7,
		"noise": 0.55, "sustain": 0.7, "release": 0.3, "gain": 0.9},
	"worm_charge":     {"wave": Wave.SAW, "f0": 90.0, "f1": 620.0, "dur": 0.9,
		"attack": 0.35, "sustain": 0.9, "release": 0.2, "noise": 0.3, "gain": 0.6},
	"worm_arrive":     {"wave": Wave.NOISE, "f0": 520.0, "f1": 50.0, "dur": 0.45,
		"noise": 0.9, "sustain": 0.6, "gain": 0.9},
	"worm_kill":       {"wave": Wave.SAW, "f0": 440.0, "f1": 60.0, "dur": 0.7,
		"noise": 0.55, "sustain": 0.7, "release": 0.3, "gain": 0.9},
	"root_charge":     {"wave": Wave.SAW, "f0": 90.0, "f1": 620.0, "dur": 0.9,
		"attack": 0.35, "sustain": 0.9, "release": 0.2, "noise": 0.3, "gain": 0.6},
	"root_arrive":     {"wave": Wave.NOISE, "f0": 520.0, "f1": 50.0, "dur": 0.45,
		"noise": 0.9, "sustain": 0.6, "gain": 0.9},
	"root_kill":       {"wave": Wave.SAW, "f0": 440.0, "f1": 60.0, "dur": 0.7,
		"noise": 0.55, "sustain": 0.7, "release": 0.3, "gain": 0.9},
	"spire_capture": {"wave": Wave.SINE, "f0": 440.0, "f1": 880.0, "dur": 0.35, "gain": 0.5},
	"sentinel_exposed": {"wave": Wave.SAW, "f0": 880.0, "f1": 110.0, "dur": 0.65, "gain": 0.5},
	"worm_regen": {"wave": Wave.SQUARE, "f0": 110.0, "f1": 330.0, "dur": 0.4, "gain": 0.45},
	"root_phase": {"wave": Wave.SAW, "f0": 220.0, "f1": 660.0, "dur": 0.4, "gain": 0.5},
	"teleport_charge": {"wave": Wave.SAW, "f0": 90.0, "f1": 1100.0, "dur": 0.9,
		"attack": 0.15, "sustain": 0.6, "release": 0.15, "gain": 0.35},
	"teleport_arrive": {"wave": Wave.SINE, "f0": 1400.0, "f1": 260.0, "dur": 0.6,
		"attack": 0.01, "sustain": 0.4, "release": 0.4, "gain": 0.55},
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
## Per-kind fire timbres, indexed by VectorKind. A missing entry falls back to
## the first, so appending a kind yields a real sound rather than a crash.
##
## Every one carries `steps`. Fire is the most-repeated sound in the game —
## auto-fire across three exploits, for a whole run — so it is the one that most
## needs real variation, and pitch steps drawn from a scale give that without
## making consecutive shots sound out of tune with each other.
const FIRE_SPECS := [
	{"wave": Wave.SQUARE, "f0": 760.0, "f1": 520.0, "dur": 0.06, "gain": 0.24,
		"steps": [0, -2, 3, -5, 5, -7]},
	{"wave": Wave.SQUARE, "f0": 900.0, "f1": 700.0, "dur": 0.05, "gain": 0.22,
		"steps": [0, 3, -2, 7, -5, 2]},
	{"wave": Wave.SAW, "f0": 640.0, "f1": 1000.0, "dur": 0.07, "gain": 0.22,
		"steps": [0, 5, -3, 2, -7, 3]},
	{"wave": Wave.SINE, "f0": 1200.0, "f1": 400.0, "dur": 0.09, "gain": 0.22,
		"steps": [0, -5, 3, -2, 7, -3]},
	{"wave": Wave.NOISE, "f0": 700.0, "f1": 300.0, "dur": 0.08, "noise": 0.7,
		"gain": 0.24, "steps": [0, -2, 2, -4, 4, -6]},
	{"wave": Wave.SINE, "f0": 300.0, "f1": 620.0, "dur": 0.1, "gain": 0.26,
		"steps": [0, 3, 7, -2, 5, -5]},
	{"wave": Wave.SQUARE, "f0": 220.0, "f1": 160.0, "dur": 0.08, "gain": 0.26,
		"steps": [0, -3, 2, -5, 3, -7]},
	{"wave": Wave.SINE, "f0": 980.0, "f1": 1240.0, "dur": 0.05, "gain": 0.18,
		"steps": [0, 2, -3, 5, -2, 7]},
]

## Every id the game can play, spec included. `build_bank` is the only caller
## that matters, but the key set is what `test_audio_events` asserts against.
# All pitched buffers are centered on a harmony reference. Runtime transposition
# supplies scale degrees; variants change envelope only. Even the longest tuba
# tail ends before the fastest eighth note (0.242 s), including variant spread.
const VOICE_SPECS := {
	"voice_chase": {"wave": Wave.NOISE, "f0": 880.0, "f1": 880.0, "dur": 0.075, "attack": 0.003, "decay": 0.025, "sustain": 0.15, "release": 0.04, "gain": 0.10, "steps": [0]},
	"voice_charger": {"wave": Wave.SAW, "f0": 110.0, "f1": 110.0, "dur": 0.15, "attack": 0.014, "decay": 0.035, "sustain": 0.65, "release": 0.07, "gain": 0.16, "steps": [0]},
	"voice_flanker": {"wave": Wave.SQUARE, "f0": 220.0, "f1": 220.0, "dur": 0.095, "attack": 0.004, "decay": 0.025, "sustain": 0.25, "release": 0.045, "gain": 0.10, "steps": [0]},
	"voice_support": {"wave": Wave.SINE, "f0": 55.0, "f1": 55.0, "dur": 0.19, "attack": 0.035, "decay": 0.04, "sustain": 0.85, "release": 0.07, "gain": 0.23, "steps": [0]},
	"voice_ambusher": {"wave": Wave.SQUARE, "f0": 110.0, "f1": 110.0, "dur": 0.17, "attack": 0.02, "decay": 0.045, "sustain": 0.45, "release": 0.065, "gain": 0.12, "steps": [0]},
	"voice_ranged": {"wave": Wave.SAW, "f0": 220.0, "f1": 220.0, "dur": 0.11, "attack": 0.004, "decay": 0.025, "sustain": 0.6, "release": 0.045, "gain": 0.13, "steps": [0]},
	"voice_player": {"wave": Wave.SAW, "f0": 110.0, "f1": 110.0, "dur": 0.17, "attack": 0.012, "decay": 0.035, "sustain": 0.65, "release": 0.07, "gain": 0.12, "vibrato_rate": 5.0, "vibrato_depth": 0.004, "steps": [0]},
}

static func all_specs() -> Dictionary:
	var out := EVENTS.duplicate(true)
	out.merge(VOICE_SPECS, true)
	for k in Module.VectorKind.size():
		var spec: Dictionary = (FIRE_SPECS[k] if k < FIRE_SPECS.size()
			else FIRE_SPECS[0]).duplicate()
		out[fire_id(k)] = spec
	return out

## Built ONCE per process and cached.
##
## There are no autoloads in this project and the game shuttles between the
## shell and a run all session, so anything scoped to a scene runs once per RUN.
## Synthesizing the bank is about a second of work; paying it on every ./intrude
## would be a visible hitch at the exact moment the player expects the game to
## start. Same reasoning as the audio bus guard in sfx.gd, different mechanism —
## a static here, because this class is pure and has no tree to hang off.
static var _bank_cache: Dictionary = {}

## id -> Array[AudioStreamWAV], VARIANTS deep. sfx.gd picks one per play.
static func build_bank() -> Dictionary:
	if not _bank_cache.is_empty():
		return _bank_cache
	var out := {}
	var specs := all_specs()
	for id in specs:
		var pool: Array[AudioStreamWAV] = []
		for v in VARIANTS:
			pool.append(build(specs[id], v))
		out[id] = pool
	_bank_cache = out
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

## BAND-LIMITED square and saw, as wavetables built once per octave.
##
## The naive forms — `sin(phase) >= 0 ? 1 : -1` and `fmod(phase, TAU)/PI - 1` —
## carry harmonics to infinity. Everything above Nyquist folds back as
## INHARMONIC partials: a 1.2 kHz square put its 11th harmonic at 13.2 kHz,
## which reflects to 8.85 kHz — not a multiple of 1200, and it does not move
## with a pitch sweep the way a real overtone would. That inharmonic grit is
## what made these read as cheap and grating, and it is a bug rather than a
## taste.
##
## Summing the harmonics per SAMPLE is correct and far too slow: measured at
## twelve seconds to build the bank. So each waveform is summed once into a
## table per octave band — the band's top frequency decides how many harmonics
## fit under Nyquist — and synthesis is a lookup with linear interpolation.
const TABLE_SIZE := 2048
## Band i covers [BASE_HZ << i, BASE_HZ << (i+1)).
const BASE_HZ := 55.0
const BANDS := 6

static var _tables: Dictionary = {}

static func _band_of(freq: float) -> int:
	if freq <= BASE_HZ:
		return 0
	return clampi(int(log(freq / BASE_HZ) / log(2.0)), 0, BANDS - 1)

## One table: `wave` summed to every harmonic that stays under Nyquist for the
## TOP of this band, so nothing in the band can alias.
static func _build_table(wave: int, band: int) -> PackedFloat32Array:
	var top := BASE_HZ * pow(2.0, float(band + 1))
	var max_h := int(floor((SAMPLE_RATE * 0.5) / maxf(top, 1.0)))
	max_h = maxi(max_h, 1)
	var out := PackedFloat32Array()
	out.resize(TABLE_SIZE)
	var norm := 0.0
	var step := 1 if wave == Wave.SAW else 2
	var h := 1
	while h <= max_h:
		norm += 1.0 / float(h)
		h += step
	norm = maxf(norm, 0.0001)
	for i in TABLE_SIZE:
		var ph := TAU * float(i) / float(TABLE_SIZE)
		var acc := 0.0
		var n := 1
		while n <= max_h:
			acc += sin(ph * n) / float(n)
			n += step
		out[i] = acc / norm
	return out

static func _table(wave: int, band: int) -> PackedFloat32Array:
	var key := wave * 100 + band
	if not _tables.has(key):
		_tables[key] = _build_table(wave, band)
	return _tables[key]

static func _sample_table(wave: int, freq: float, phase: float) -> float:
	var tbl := _table(wave, _band_of(freq))
	var x := fmod(phase, TAU) / TAU * float(TABLE_SIZE)
	if x < 0.0:
		x += float(TABLE_SIZE)
	var i0 := int(x)
	var i1 := (i0 + 1) % TABLE_SIZE
	var frac := x - float(i0)
	return lerpf(tbl[i0 % TABLE_SIZE], tbl[i1], frac)

static func build(partial: Dictionary, variant: int = 0) -> AudioStreamWAV:
	var spec := DEFAULTS.duplicate()
	for k in partial:
		spec[k] = partial[k]
	# Each variant is the same sound with a different noise cut and a slightly
	# different envelope and sweep. Not a different sound — an odd one out is
	# worse than repetition, because the ear starts listening FOR it.
	var steps: Array = spec["steps"]
	if steps.size() > 1:
		# Transpose by a scale degree. Equal temperament: 2^(n/12).
		var semis: float = float(steps[variant % steps.size()])
		var mul: float = pow(2.0, semis / 12.0)
		spec["f0"] = float(spec["f0"]) * mul
		spec["f1"] = float(spec["f1"]) * mul
	if variant > 0:
		# Envelope wobble on top, so two plays of the same degree are still not
		# bit-identical. Spread across the FULL variant range rather than
		# `variant % 3`, which silently collapsed six variants into three for
		# any sound with neither steps nor noise — which was every fire sound.
		var spread := float(variant) / float(maxi(VARIANTS - 1, 1))
		spec["decay"] = float(spec["decay"]) * (0.86 + 0.28 * spread)
		spec["dur"] = float(spec["dur"]) * (0.94 + 0.12 * spread)

	var n := int(round(float(spec["dur"]) * SAMPLE_RATE))
	n = maxi(n, 1)
	var env := _envelope(spec, n)
	var rng := RandomNumberGenerator.new()
	# Seeded from the spec, so the same spec twice yields identical bytes and a
	# noise sound is still deterministic.
	# The old seed includes the serialized defaults. New optional controls
	# must not reseed existing noise buffers when their feature is disabled.
	var seed_spec := spec.duplicate()
	if float(spec["vibrato_depth"]) == 0.0:
		seed_spec.erase("vibrato_rate")
		seed_spec.erase("vibrato_depth")
	rng.seed = hash(str(seed_spec)) + variant * 7919

	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	var vibrato_depth: float = spec["vibrato_depth"]
	var vibrato_rate: float = spec["vibrato_rate"]
	for i in n:
		var t := float(i) / float(n)
		var freq: float = lerpf(spec["f0"], spec["f1"], t)
		if vibrato_depth != 0.0:
			freq *= 1.0 + vibrato_depth * sin(TAU * vibrato_rate * float(i) / SAMPLE_RATE)
		phase += TAU * freq / SAMPLE_RATE
		var tone := 0.0
		match int(spec["wave"]):
			Wave.SINE:   tone = sin(phase)
			Wave.SQUARE: tone = _sample_table(Wave.SQUARE, freq, phase)
			Wave.SAW:    tone = _sample_table(Wave.SAW, freq, phase)
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
