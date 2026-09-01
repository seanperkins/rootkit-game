extends Node

## The only part of the audio path that touches the scene tree.
##
## The simulation NEVER holds a reference to this node. `run.gd` appends event
## ids to `feel.sfx` — a plain string list on a pure RefCounted — and this node
## drains it. That boundary is deliberate and it is the most expensive thing
## here to reverse: hooks reach into every combat, economy and lifecycle path,
## and coupling them to a node would take the whole tick out of headless reach.

const BUS := "SFX"

## Per-id ceiling, plays per second. Not a nicety: six hundred enemies, a
## working build and a magnet radius produce kills, hits and pickups by the
## hundred per second, and played faithfully that is white noise at full volume
## — worse than silence, because silence at least does not mask the events that
## matter. Overflow is DROPPED, never queued.
const RATE_LIMIT := {
	"hit": 14.0,
	"kill": 12.0,
	"pickup": 10.0,
	"flip": 8.0,
}
const DEFAULT_RATE := 20.0

## Enough voices for the busiest tick; beyond this the limiter has already
## thinned things out.
const VOICES := 16

var feel: Feel
var _bank: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _last_played: Dictionary = {}
var _rng := RandomNumberGenerator.new()

## Creating the bus, guarded so it is safe on every scene entry.
##
## There is no `[audio]` section that declares buses — Godot takes them from the
## bus-layout resource or from runtime calls — and `add_bus` takes an index, not
## a name, so the name is a second call. "At boot" would also be wrong here:
## there are no autoloads, and the game shuttles between the shell and a run all
## session, so anything scoped to a scene runs once per RUN, not once per
## process.
static func ensure_bus() -> int:
	var idx := AudioServer.get_bus_index(BUS)
	if idx >= 0:
		return idx
	AudioServer.add_bus()
	idx = AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, BUS)
	AudioServer.set_bus_send(idx, "Master")
	return idx

## Linear 0..1 to decibels. linear_to_db(0.0) is -INF, so the floor keeps a
## non-finite float out of an engine setter; true silence goes through the mute
## flag instead. The index guard matters because a missing bus returns -1 and
## set_bus_volume_db(-1, x) errors on every slider movement.
static func apply_volume(linear: float) -> void:
	var idx := AudioServer.get_bus_index(BUS)
	if idx < 0:
		return
	AudioServer.set_bus_mute(idx, linear <= 0.0)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.0001)))

func _ready() -> void:
	_rng.randomize()
	var idx := ensure_bus()
	_bank = Synth.build_bank()
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = BUS
		add_child(p)
		_players.append(p)
	AudioServer.set_bus_volume_db(idx,
		linear_to_db(maxf(SaveGame.prefs().get("volume_sfx", 0.8), 0.0001)))

func _process(_dt: float) -> void:
	if feel == null:
		return
	for id in feel.drain_sfx():
		play(id)

func play(id: String) -> void:
	if not _bank.has(id):
		# A missing id is a bug, not a crash. The bank/event-set agreement is
		# asserted in test_audio_events for exactly this reason.
		return
	var now := Time.get_ticks_msec() / 1000.0
	var gap := 1.0 / float(RATE_LIMIT.get(id, DEFAULT_RATE))
	if now - float(_last_played.get(id, -999.0)) < gap:
		return
	_last_played[id] = now
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	# A different BUFFER each time, not just a different pitch. Pitch jitter on
	# one asset is still one asset, and the ear locks onto it inside a minute.
	var pool: Array = _bank[id]
	p.stream = pool[_rng.randi() % pool.size()]
	p.pitch_scale = _rng.randf_range(0.94, 1.07)
	p.play()
