extends SceneTree

## A snapshot is a peer's bytes, and a peer may be hostile. Every malformed
## payload here must be REFUSED — false, the live run untouched, no script
## error — and the movement sanitation rule that guards the eight bytes of
## input arriving sixty times a second is pinned alongside it.

var failures := 0
var finished := {}

const CASES := ["garbage_is_refused_untouched", "shapes_are_checked_before_writes",
	"movement_is_bounded_not_clamped"]

func _initialize() -> void:
	print("ROOTKIT — hostile snapshots\n")
	SaveGame.use_fresh_state()
	await garbage_is_refused_untouched()
	await shapes_are_checked_before_writes()
	await movement_is_bounded_not_clamped()
	print("")
	for c in CASES:
		if not finished.has(c):
			print("  FAIL  case '%s' never finished — it aborted part way" % c)
			failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _run() -> Node2D:
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(r)
	await process_frame
	r.set_physics_process(false)
	r.input_override = Vector2.ZERO
	return r

func _done(r: Node2D, name: String) -> void:
	r.free()
	await process_frame
	finished[name] = true

## Refuse `bytes` and prove the run did not move: same hash before and after.
func _refused(r: Node2D, label: String, bytes: PackedByteArray) -> void:
	var before: int = r._state_hash()
	var ok: bool = r.restore_state(bytes, r.tick)
	_check("%s is refused" % label, ok, false)
	_check("%s left the run untouched" % label, r._state_hash(), before)

func garbage_is_refused_untouched() -> void:
	var r: Node2D = await _run()
	var good: PackedByteArray = r.serialize_state(r.tick)
	_refused(r, "an empty payload", PackedByteArray())
	_refused(r, "a truncated payload", good.slice(0, good.size() / 2))
	var random := PackedByteArray()
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for k in 4096:
		random.append(rng.randi_range(0, 255))
	_refused(r, "random bytes", random)
	_refused(r, "a non-dictionary root", var_to_bytes([1, 2, 3]))
	_refused(r, "a dictionary with no fields", var_to_bytes({"v": 1, "tick": r.tick}))
	var wrong_version = bytes_to_var(good)
	wrong_version["v"] = SessionRules.SNAPSHOT_VERSION + 1
	_refused(r, "a wrong version", var_to_bytes(wrong_version))
	var wrong_tick = bytes_to_var(good)
	wrong_tick["tick"] = r.tick + 7
	_refused(r, "a mislabelled tick", var_to_bytes(wrong_tick))
	var oversized := PackedByteArray()
	oversized.resize(SessionRules.SNAPSHOT_MAX + 1)
	_refused(r, "a payload over SNAPSHOT_MAX", oversized)
	await _done(r, "garbage_is_refused_untouched")

## Find the SNAPSHOT-field index of an entry by object key and property.
func _field_index(r: Node2D, key: String, prop: String) -> int:
	var k := 0
	for entry in r.STATE_FIELDS:
		if (int(entry[2]) & r.SNAPSHOT) == 0:
			continue
		if entry[0] == key and entry[1] == prop:
			return k
		k += 1
	return -1

func _mutated(r: Node2D, key: String, prop: String, value) -> PackedByteArray:
	var d = bytes_to_var(r.serialize_state(r.tick))
	d["fields"][_field_index(r, key, prop)] = value
	return var_to_bytes(d)

func shapes_are_checked_before_writes() -> void:
	var r: Node2D = await _run()
	# At least one enemy, so a shorter parallel array is actually shorter.
	if r.enemies.count == 0:
		var e: int = r.enemies.spawn(Vector2(300, 0), Vector2.ZERO, 50.0, 12.0, 0)
		r._spawn_enemy_state(e, 50.0)
	_refused(r, "an enemy count over capacity",
		_mutated(r, "enemies", "count", r.MAX_ENEMIES + 1))
	_refused(r, "a negative count", _mutated(r, "enemies", "count", -1))
	var short := PackedVector2Array()
	short.resize(maxi(r.enemies.count - 1, 0))
	_refused(r, "a parallel array shorter than its count",
		_mutated(r, "enemies", "pos", short))
	var wrong_type := PackedInt32Array()
	wrong_type.resize(r.enemies.count)
	_refused(r, "a parallel array of the wrong type",
		_mutated(r, "enemies", "pos", wrong_type))
	_refused(r, "a bad phase enum", _mutated(r, "run", "phase", 7))
	var bad_slots := PackedByteArray()
	bad_slots.resize(SessionRules.MAX_PLAYERS)
	bad_slots.fill(9)
	_refused(r, "a bad slot state", _mutated(r, "run", "slot_state", bad_slots))
	var too_many_players := PackedFloat32Array()
	too_many_players.resize(SessionRules.MAX_PLAYERS + 1)
	_refused(r, "a fixed array of the wrong size",
		_mutated(r, "run", "player_health", too_many_players))
	_refused(r, "an out-of-range arena", _mutated(r, "terrain", "current", 99))
	_refused(r, "an offer table of the wrong shape",
		_mutated(r, "run", "@offers", [1, 2, 3]))
	_refused(r, "a string where a number belongs", _mutated(r, "run", "level", "nine"))
	# And the unmodified snapshot is still accepted, so the refusals above are
	# the checks and not a broken codec.
	_check("the untouched snapshot restores",
		r.restore_state(r.serialize_state(r.tick), r.tick), true)
	await _done(r, "shapes_are_checked_before_writes")

## Exactly at MOVE_COMPONENT_MAX is preserved; anything past it, or non-finite,
## makes the WHOLE move zero. Never clamped to the bound: a hostile peer must
## not get a free maximum-speed input out of an oversized one.
func movement_is_bounded_not_clamped() -> void:
	var r: Node2D = await _run()
	var cap := SessionRules.MOVE_COMPONENT_MAX
	_check("at the cap, preserved", r._sanitise_move(Vector2(cap, cap)), Vector2(cap, cap))
	_check("a hair over on x zeroes both", r._sanitise_move(Vector2(cap + 0.001, 0.5)),
		Vector2.ZERO)
	_check("a hair over on y zeroes both", r._sanitise_move(Vector2(0.5, -cap - 0.001)),
		Vector2.ZERO)
	_check("NaN zeroes the move", r._sanitise_move(Vector2(NAN, 0.0)), Vector2.ZERO)
	_check("INF zeroes the move", r._sanitise_move(Vector2(0.0, INF)), Vector2.ZERO)
	_check("a finite 1e30 zeroes the move", r._sanitise_move(Vector2(1e30, 0.0)),
		Vector2.ZERO)
	await _done(r, "movement_is_bounded_not_clamped")
