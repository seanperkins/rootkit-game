class_name NetLog extends RefCounted

## Diagnostics for a live session. Off unless `--netlog` is passed after `--`.
##
## Nothing in scripts/net/ or run.gd printed anything, so a session that
## hitched or desynced left no record of it: the HUD says "waiting for input"
## and "resynchronising…" and that is the whole story a player or a bug report
## can carry. This turns both into numbers.
##
## It is DIAGNOSTICS, never simulation. It reads what the tick already
## computed, it holds no state the tick reads back, and it is in
## NOT_IN_MANIFEST for that reason. Off, every method is one bool test, which
## is why the calls sit inline in the tick rather than behind a build flag.
##
##   godot -- --netlog                          # from source
##   ROOTKIT.app/Contents/MacOS/ROOTKIT -- --netlog
##
## Lines are prefixed `net` so they can be pulled out of the Godot log:
##   grep '^net ' ~/Library/Application\ Support/Godot/app_userdata/ROOTKIT/logs/godot.log

## One heartbeat per second, on the wall clock.
const HEARTBEAT_MS := 1000

var enabled := false

var _slot := -1
var _role := ""

# The stall in progress: the tick it began on, and how many ticks it has held.
var _stall_tick := -1
var _stall_len := 0

# Since the last heartbeat.
var _stalled_ticks := 0
var _stalls := 0
var _worst_stall := 0
var _last_beat_tick := -1
var _beat_wall := 0

# For the whole session.
var _total_stalled := 0
var _total_stalls := 0
var _desyncs := 0
var _snapshots_sent := 0
var _snapshots_applied := 0

## `--netlog` after `--`. OS.get_cmdline_user_args() is empty for a normal
## launch, so this costs one array read at startup and nothing after.
func configure(slot: int, role: String) -> void:
	enabled = "--netlog" in OS.get_cmdline_user_args()
	_slot = slot
	_role = role
	if enabled:
		_beat_wall = Time.get_ticks_msec()
		_line("open  slot=%d role=%s" % [slot, role])

func _line(text: String) -> void:
	print("net [s%d %s] %s" % [_slot, _role, text])

## The tick could not run: some LIVE slot's record for it has not arrived.
## `missing` is lockstep.missing(tick), which ALLOCATES, so every call site
## guards on `enabled` before building the argument.
func stalled(tick: int, missing: PackedInt32Array) -> void:
	if not enabled:
		return
	_stalled_ticks += 1
	_total_stalled += 1
	if _stall_tick != tick:
		_stall_tick = tick
		_stall_len = 0
		_stalls += 1
		_total_stalls += 1
		_line("stall start tick=%d waiting_on=%s" % [tick, str(missing)])
	_stall_len += 1
	_maybe_beat(tick, Time.get_ticks_msec())

## The tick ran. Closes a stall that was open, which is the only place its
## length is known.
func stepped(tick: int) -> void:
	if not enabled:
		return
	if _stall_tick >= 0:
		_worst_stall = maxi(_worst_stall, _stall_len)
		_line("stall end   tick=%d held=%d ticks (%d ms)"
			% [_stall_tick, _stall_len, roundi(_stall_len * 1000.0 / 60.0)])
		_stall_tick = -1
		_stall_len = 0
	_maybe_beat(tick, Time.get_ticks_msec())

## One printable line for a transport lifecycle event — a peer joined or left,
## a park, a return, a rejoin, a relay error. The run composes the text; this
## class only prefixes it. Guarded by the caller like the allocating sites.
func event(text: String) -> void:
	if not enabled:
		return
	_line("event " + text)

## Host only: the checksums for `tick` disagreed, and these slots are the ones
## that did not match the host.
func desync(tick: int, targets: PackedInt32Array) -> void:
	if not enabled:
		return
	_desyncs += 1
	_line("DESYNC at tick=%d slots=%s (desync #%d this session)"
		% [tick, str(targets), _desyncs])

## A repair boundary was announced. Every peer holds records past it until the
## boundary resolves.
func resync(boundary: int, executed: int) -> void:
	if not enabled:
		return
	_line("resync boundary=%d executed=%d (holding %d ticks of records)"
		% [boundary, executed, boundary - executed])

func snapshot_sent(boundary: int, bytes: int, targets: PackedInt32Array) -> void:
	if not enabled:
		return
	_snapshots_sent += 1
	_line("snapshot sent boundary=%d bytes=%d to=%s" % [boundary, bytes, str(targets)])

func snapshot_applied(boundary: int, ok: bool) -> void:
	if not enabled:
		return
	if ok:
		_snapshots_applied += 1
	_line("snapshot %s boundary=%d" % ["applied" if ok else "REFUSED", boundary])

## Wall-clock heartbeat. Called from BOTH the stalled and the stepped paths,
## because the tick-gated version went silent exactly during a hard stall —
## the one time a log line matters. The headline is what it always was:
## `ran` is how many ticks the world executed per real second, so a session
## running 1 game-second per 3 real seconds prints ran=20.
func _maybe_beat(tick: int, now: int) -> void:
	if _last_beat_tick < 0:
		_last_beat_tick = tick
		_beat_wall = now
		return
	if now - _beat_wall < HEARTBEAT_MS:
		return
	var wall := now - _beat_wall
	var ran := tick - _last_beat_tick
	_line("beat  tick=%d ran=%d stalled=%d stalls=%d worst=%d wall=%dms"
		% [tick, ran, _stalled_ticks, _stalls, _worst_stall, wall])
	_last_beat_tick = tick
	_beat_wall = now
	_stalled_ticks = 0
	_stalls = 0
	_worst_stall = 0

## Printed once when the run ends, so a session that felt bad has a number
## attached to it rather than an impression.
func summary(tick: int) -> void:
	if not enabled:
		return
	var pct := 0.0
	if tick + _total_stalled > 0:
		pct = 100.0 * float(_total_stalled) / float(tick + _total_stalled)
	_line("close tick=%d stalled=%d ticks (%.1f%% of wall) stalls=%d desyncs=%d snapshots=%d/%d"
		% [tick, _total_stalled, pct, _total_stalls, _desyncs,
			_snapshots_sent, _snapshots_applied])
