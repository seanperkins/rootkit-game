extends Node

## Generative music. No assets, no loops — the arrangement IS the game state.
##
## There is no track to play and no stems to cross-fade. A beat clock runs, and
## on each eighth note this node asks `run.threat()` what is happening and
## decides what, if anything, to sound. Pressure adds layers and tempo; a boss
## adds a dissonant pedal; the walk to the gate strips it back to a pulse. The
## player never hears a transition because there is nothing to transition
## between.
##
## Same Synth as the SFX, so this stays inside the no-assets rule, and the SFX
## step through the same scale — a pickup or a hit lands ON a chord tone rather
## than beside it. Game-audio writing is blunt about this: dissonance between a
## frequent effect and the music reads as irritation the player cannot name.
##
## Direction of coupling matters. This node polls `run`; `run` never references
## this node. Same rule the Sfx node follows, for the same reason — the tick
## stays reachable headless.

const BUS := "Music"

## Phrygian on A. The flat second is what makes it read as menace rather than
## as sadness, and it is the mode most associated with this kind of fiction.
const ROOT_HZ := 55.0
const SCALE := [0, 1, 3, 5, 7, 8, 10]

## Four bars, as scale degrees. i - i - VI - v: it does not resolve, which is
## the point; a run has no cadence until ICE dies.
const PROGRESSION := [0, 0, 5, 4]

const BPM_CALM := 88.0
const BPM_HOT := 124.0

## Eighth notes.
const STEPS_PER_BAR := 8
const VOICES := 8

var run: Node2D

var _bass: Array[AudioStreamWAV] = []
var _arp: Array[AudioStreamWAV] = []
var _pedal: Array[AudioStreamWAV] = []
var _tick: AudioStreamWAV

var _players: Array[AudioStreamPlayer] = []
var _next := 0

var _clock := 0.0
var _step := 0
var _bpm := BPM_CALM
## Smoothed, and only sampled at bar lines: threat swings every tick as the
## swarm dies and respawns, and an arrangement that followed it sample by sample
## would flutter.
var _threat := 0.0
var _bar_threat := 0.0
var _rng := RandomNumberGenerator.new()

static func ensure_bus() -> int:
	var idx := AudioServer.get_bus_index(BUS)
	if idx >= 0:
		return idx
	AudioServer.add_bus()
	idx = AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, BUS)
	AudioServer.set_bus_send(idx, "Master")
	return idx

static func apply_volume(linear: float) -> void:
	var idx := AudioServer.get_bus_index(BUS)
	if idx < 0:
		return
	AudioServer.set_bus_mute(idx, linear <= 0.0)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.0001)))

func _hz(degree: int, octave: int) -> float:
	var semis: float = float(SCALE[degree % SCALE.size()]) \
		+ 12.0 * float(octave + degree / SCALE.size())
	return ROOT_HZ * pow(2.0, semis / 12.0)

func _ready() -> void:
	_rng.randomize()
	ensure_bus()
	for d in SCALE.size():
		# Bass: long, soft, low. The floor the rest sits on.
		_bass.append(Synth.build({"wave": Synth.Wave.SAW,
			"f0": _hz(d, 0), "f1": _hz(d, 0) * 0.995, "dur": 1.1,
			"attack": 0.06, "decay": 0.25, "sustain": 0.55, "release": 0.5,
			"gain": 0.30}))
		# Arp: short plucks two octaves up.
		_arp.append(Synth.build({"wave": Synth.Wave.SQUARE,
			"f0": _hz(d, 2), "f1": _hz(d, 2), "dur": 0.16,
			"attack": 0.004, "decay": 0.05, "sustain": 0.35, "release": 0.09,
			"gain": 0.13}))
	# The pedal is deliberately OUTSIDE the scale — a tritone against the root.
	# It is the sound of something being in the arena that should not be.
	for k in 2:
		_pedal.append(Synth.build({"wave": Synth.Wave.SAW,
			"f0": ROOT_HZ * pow(2.0, (6.0 + 12.0 * float(k)) / 12.0),
			"f1": ROOT_HZ * pow(2.0, (6.0 + 12.0 * float(k)) / 12.0) * 1.01,
			"dur": 1.6, "attack": 0.4, "decay": 0.3, "sustain": 0.7,
			"release": 0.6, "noise": 0.12, "gain": 0.22}))
	_tick = Synth.build({"wave": Synth.Wave.NOISE, "f0": 180.0, "f1": 90.0,
		"dur": 0.06, "attack": 0.001, "decay": 0.02, "sustain": 0.2,
		"release": 0.03, "noise": 1.0, "gain": 0.16})

	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = BUS
		add_child(p)
		_players.append(p)
	apply_volume(float(SaveGame.prefs().get("volume_music", 0.5)))

func _play(stream: AudioStreamWAV, pitch: float = 1.0) -> void:
	if stream == null:
		return
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = stream
	p.pitch_scale = pitch
	p.play()

func _process(dt: float) -> void:
	if run == null:
		return
	# The frame delta, clamped. The hitstop no longer touches a process-global
	# time scale — it freezes the world for whole ticks while presentation clocks
	# like this one keep running — so there is nothing to divide back out.
	var udt: float = minf(dt, 0.1)

	_threat = lerpf(_threat, run.threat(), minf(udt * 1.5, 1.0))

	# Silence rather than a sad cadence: the run summary is the beat, and music
	# under it would be scoring a defeat the player already feels.
	if not run.alive:
		return

	_clock += udt
	var spb := 60.0 / _bpm * 0.5
	while _clock >= spb:
		_clock -= spb
		_on_step()
		spb = 60.0 / _bpm * 0.5

func _on_step() -> void:
	var in_bar := _step % STEPS_PER_BAR
	if in_bar == 0:
		# Sampled once a bar. Tempo included — a continuously-lerped BPM
		# audibly warbles.
		_bar_threat = _threat
		_bpm = lerpf(BPM_CALM, BPM_HOT, _bar_threat)

	var bar := (_step / STEPS_PER_BAR) % PROGRESSION.size()
	var root: int = PROGRESSION[bar]

	# BASS — always. This is the layer that makes it music rather than an
	# effects bed, so it plays at zero threat too.
	if in_bar == 0:
		_play(_bass[root % _bass.size()])

	# PULSE — the heartbeat. Quarter notes, in from the first sign of pressure.
	if _bar_threat > 0.12 and in_bar % 2 == 0:
		_play(_tick, 1.0 if in_bar == 0 else 0.92)

	# OFFBEAT — doubles the pulse once things are busy.
	if _bar_threat > 0.55 and in_bar % 2 == 1:
		_play(_tick, 0.84)

	# ARP — the melodic layer, and the clearest signal that a wave is on you.
	# Density rises with threat rather than switching on: at 0.4 it is every
	# fourth eighth, at 1.0 it is every one.
	if _bar_threat > 0.32:
		var every: int = 4 if _bar_threat < 0.55 else (2 if _bar_threat < 0.8 else 1)
		if in_bar % every == 0:
			var d: int = root + [0, 2, 4, 2, 5, 4, 2, 0][in_bar]
			_play(_arp[d % _arp.size()],
				1.0 if _rng.randf() > 0.2 else 2.0)

	# PEDAL — a tritone against the root, held under a boss fight. Outside the
	# scale on purpose: it is the arrangement saying something is wrong.
	if run.boss_present() and in_bar == 0:
		_play(_pedal[_rng.randi() % _pedal.size()])

	_step += 1
