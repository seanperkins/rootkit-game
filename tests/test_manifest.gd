extends SceneTree

## The state manifest, structurally and behaviourally.
##
## STRUCTURAL: every top-level `var` in the nine simulation files is classified
## exactly once — carried by STATE_FIELDS (directly or through a derived entry's
## `covers`) or named in NOT_IN_MANIFEST with a reconstruction reason. A new
## variable that is in neither fails here, which is the whole point: nothing
## enters the simulation without deciding whether a peer needs it.
##
## BEHAVIOURAL: a snapshot taken from a busy run — mid-collapse, an offer open
## with another queued, a block held, worms alive, a middle-slot despawn — is
## restored into a fresh run that then hashes identically and stays identical
## for 600 ticks. Derived state comes back exact. Arrival state is snapshot-only.

var failures := 0
var finished := {}
const DT := 1.0 / 60.0

const FILES := {
	"run": "res://scripts/run/run.gd",
	"population": "res://scripts/combat/population.gd",
	"terrain": "res://scripts/run/terrain.gd",
	"blocks": "res://scripts/run/blocks.gd",
	"director": "res://scripts/run/spawn_director.gd",
	"flow_field": "res://scripts/core/flow_field.gd",
	"grid": "res://scripts/core/grid.gd",
	"hit_queue": "res://scripts/combat/hit_queue.gd",
	"lockstep": "res://scripts/net/lockstep.gd",
}

const CASES := ["every_var_is_classified_once", "flags_have_real_consumers",
	"a_busy_run_round_trips", "fighting_restore_clears_collapse",
	"arrival_state_is_snapshot_only", "the_worst_case_fits"]

func _initialize() -> void:
	print("ROOTKIT — state manifest\n")
	SaveGame.use_fresh_state()
	await every_var_is_classified_once()
	await flags_have_real_consumers()
	await a_busy_run_round_trips()
	await fighting_restore_clears_collapse()
	await arrival_state_is_snapshot_only()
	await the_worst_case_fits()
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

func _check_true(label: String, got: bool) -> void:
	_check(label, got, true)

## A run with a chosen delay, driven ONLY by explicit ticks: the engine's own
## physics callback is disabled after ready so two runs stay in step.
func _run(delay: int = 0) -> Node2D:
	var rows := [{"slot": 0, "name": "p0", "counters": SaveGame.session_counters()}]
	var desc := NetworkSession.validate_descriptor({
		"protocol": SessionRules.PROTOCOL, "session_id": 1, "seed": 20260830,
		"delay": delay, "choice_timeout": 0, "roster": rows})
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	r.configure_session(NetworkSession.create(desc, 0, NetworkSession.Role.HOST))
	root.add_child(r)
	await process_frame
	r.set_physics_process(false)
	r.input_override = Vector2.ZERO
	return r

func _done(r: Node2D, name: String) -> void:
	r.free()
	await process_frame
	finished[name] = true

## Top-level `var` names in a script, by source text.
func _vars_in(path: String) -> Array:
	var out := []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if line.begins_with("var "):
			var rest := line.substr(4)
			var end := 0
			while end < rest.length() and (rest[end] == "_"
					or rest[end].is_valid_identifier() or rest[end].is_valid_int()):
				end += 1
			out.append(rest.substr(0, end))
	return out

func every_var_is_classified_once() -> void:
	var r: Node2D = await _run()
	var manifest: Array = r.STATE_FIELDS
	var not_in: Dictionary = r.NOT_IN_MANIFEST
	var bad := []
	for file in FILES:
		# The set of vars the manifest carries for this file.
		var carried := {}
		for entry in manifest:
			if r.MANIFEST_FILES.get(entry[0], "") != file:
				continue
			var prop: String = entry[1]
			if not prop.begins_with("@"):
				carried[prop] = true
			for c in entry[4]:
				carried[c] = true
		var excluded: Dictionary = not_in.get(file, {})
		for v in _vars_in(FILES[file]):
			var n := (1 if carried.has(v) else 0) + (1 if excluded.has(v) else 0)
			if n != 1:
				bad.append("%s.%s (%s)" % [file, v,
					"in both lists" if n == 2 else "in neither list"])
			elif excluded.has(v) and String(excluded[v]).is_empty():
				bad.append("%s.%s (excluded without a reason)" % [file, v])
	_check("every simulation var is classified exactly once", bad, [])
	await _done(r, "every_var_is_classified_once")

## Every flag is used by a real consumer: the hash visits every HASH field and
## no SNAPSHOT-only field; the snapshot carries exactly the SNAPSHOT fields.
func flags_have_real_consumers() -> void:
	var r: Node2D = await _run()
	var hashed := 0
	var snap := 0
	var arrival_only := 0
	for entry in r.STATE_FIELDS:
		var flags: int = entry[2]
		if (flags & r.HASH) != 0: hashed += 1
		if (flags & r.SNAPSHOT) != 0: snap += 1
		if (flags & r.SNAPSHOT) != 0 and (flags & r.HASH) == 0: arrival_only += 1
		_check_true("entry %s.%s has a consumer" % [entry[0], entry[1]],
			(flags & (r.SNAPSHOT | r.HASH)) != 0)
	_check_true("most of the manifest is hashed", hashed > 50)
	_check("exactly the ring window is snapshot-only", arrival_only, 1)
	var bytes: PackedByteArray = r.serialize_state(r.tick)
	var decoded = bytes_to_var(bytes)
	_check("the snapshot carries one value per SNAPSHOT entry",
		(decoded["fields"] as Array).size(), snap)
	await _done(r, "flags_have_real_consumers")

## Drive a run into the busiest shape the manifest must carry.
func _make_busy(r: Node2D) -> void:
	# Worm-heavy: a long-run director and several worms.
	r.director.elapsed = 240.0
	for k in 4:
		r._spawn_worm(r.player_pos[0] + Vector2(300.0 + 80.0 * k, 0.0))
	# A middle-slot despawn: kill the second enemy so the tail compacts down.
	if r.enemies.count >= 3:
		r._relocate_enemy(1, r.enemies.count - 1)
		r.enemies.despawn(1)
	# A held block.
	r.blocks.alive = true
	r.blocks.pos = r.player_pos[0] + Vector2(40.0, 0.0)
	r.blocks.progress = 2.5
	# An open offer with another queued behind it.
	r._offer_cards(0)
	r._offer_cards(0, r.CardMode.RANK_ONLY)
	# A corridor collapse in progress: clear the subnet, run the arena out,
	# then some of the corridor.
	var b = r.enemy_types[EnemyTable.ICE]
	var i: int = r.enemies.spawn(Vector2(200, 0), Vector2.ZERO, b.integrity,
		48.0, EnemyTable.ICE)
	r._on_death(i)
	r.hitstop_ticks = 0
	# Stand on the NEXT arena's floor, which never voids, so the collapse below
	# does not kill the slot and resolve the offers this fixture exists to carry.
	var g = r.terrain.gate()
	r.player_pos[0] = g.end + g.dir * 8.0
	r.collapse_left = 0.0
	r._corridor_collapse_ticks = Terrain.CORRIDOR_COLLAPSE_TICKS / 2
	r._step2d_collapse(DT)
	r.terrain.add_temp_zone(Vector2(500, 500), 60.0, Terrain.Kind.HAZARD, 4.0)

func _voided_count(t: Terrain) -> int:
	var n := 0
	for b in t.voided:
		if b != 0:
			n += 1
	return n

func a_busy_run_round_trips() -> void:
	var a: Node2D = await _run()
	_make_busy(a)
	var b: Node2D = await _run()
	var h_before: int = a._state_hash()
	var bytes: PackedByteArray = a.serialize_state(a.tick)
	_check_true("the busy snapshot is under the cap", bytes.size() < SessionRules.SNAPSHOT_MAX)
	_check_true("serialize changed nothing", a._state_hash() == h_before)
	_check_true("restore accepts it", b.restore_state(bytes, a.tick))
	_check("the restored run hashes identically", b._state_hash(), h_before)
	_check("voided ground is exact", b.terrain.voided, a.terrain.voided)
	_check_true("and some of it is voided", _voided_count(b.terrain) > 0)
	_check("the corridor collapse cursor is exact",
		b.terrain._collapse_idx, a.terrain._collapse_idx)
	_check("the gate blockers were rebuilt from gate state",
		b.terrain._blocks, a.terrain._blocks)
	_check("the open offer came through",
		int(b._offer_open[0]["seq"]), int(a._offer_open[0]["seq"]))
	_check("and the queued one", (b._offer_queue[0] as Array).size(), 1)
	_check("the build recompiled to the same exploits",
		b._slot_exploits(0), a._slot_exploits(0))
	_check("the held block is held", b.blocks.progress, a.blocks.progress)
	_check("worm trails came through", b._worm_trail.size(), a._worm_trail.size())
	# Now both run 600 ticks on identical records and never diverge.
	var diverged_at := -1
	for t in 600:
		a._physics_process(DT)
		b._physics_process(DT)
		if a._state_hash() != b._state_hash():
			diverged_at = t
			break
	_check("600 ticks later they still agree (first divergence tick, -1 = none)",
		diverged_at, -1)
	a.free()
	await _done(b, "a_busy_run_round_trips")

## Restoring a FIGHTING snapshot into a run that was mid-collapse empties every
## collapse-derived array, or rendering would show the old arena's holes.
func fighting_restore_clears_collapse() -> void:
	var fighting: Node2D = await _run()
	var bytes: PackedByteArray = fighting.serialize_state(fighting.tick)
	var collapsing: Node2D = await _run()
	_make_busy(collapsing)
	_check_true("the target run really was collapsing",
		_voided_count(collapsing.terrain) > 0)
	_check_true("restore accepts the fighting snapshot",
		collapsing.restore_state(bytes, fighting.tick))
	_check("the phase is FIGHTING", collapsing.phase, collapsing.Phase.FIGHTING)
	_check("no cell is voided", _voided_count(collapsing.terrain), 0)
	_check("the collapse order is empty", collapsing.terrain._collapse_order.size(), 0)
	_check("and the cursor is reset", collapsing.terrain._collapse_idx, 0)
	_check("hashes agree", collapsing._state_hash(), fighting._state_hash())
	fighting.free()
	await _done(collapsing, "fighting_restore_clears_collapse")

## Two peers with equal executed state but different in-flight records hash
## equally; serialize/restore still carries each ring window exactly.
func arrival_state_is_snapshot_only() -> void:
	var a: Node2D = await _run(3)
	var b: Node2D = await _run(3)
	var t: int = a.tick
	var ahead: int = a.lockstep.executed + 1
	a.lockstep.submit(0, ahead, Vector2(0.7, -0.2), 1, 0, 9)
	_check("a future record does not change the hash", a._state_hash(), b._state_hash())
	var bytes: PackedByteArray = a.serialize_state(t)
	var c: Node2D = await _run(3)
	_check_true("restore accepts the snapshot", c.restore_state(bytes, t))
	_check("the restored ring window matches the source's",
		c.lockstep.snapshot_window(t), a.lockstep.snapshot_window(t))
	_check("and the restored peer resumes at tick + 1", c.lockstep.executed, t + 1)
	a.free()
	b.free()
	await _done(c, "arrival_state_is_snapshot_only")

## Every pool at cap, four worms of trail, every temp zone, offers queued: the
## snapshot must still fit under SNAPSHOT_MAX.
func the_worst_case_fits() -> void:
	var r: Node2D = await _run()
	_make_busy(r)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	while r.enemies.count < r.MAX_ENEMIES:
		var i: int = r.enemies.spawn(r.player_pos[0] + Vector2(rng.randf_range(-600, 600),
			rng.randf_range(-600, 600)), Vector2.ZERO, 50.0, r.ENEMY_RADIUS, 0)
		if i < 0:
			break
		r._spawn_enemy_state(i, 50.0)
	while r.projectiles.count < r.MAX_PROJECTILES:
		if r.projectiles.spawn(r.player_pos[0], Vector2.RIGHT, 1.0, 4.0, 0) < 0:
			break
	while r.shards.count < r.MAX_SHARDS:
		if r.shards.spawn(r.player_pos[0], Vector2.ZERO, 1.0, 4.0, 0) < 0:
			break
	while r.botnet.count < r.MAX_BOTNET:
		if r.botnet.spawn(r.player_pos[0], Vector2.ZERO, 1.0, 4.0, 0) < 0:
			break
	while r.hostiles.count < r.MAX_HOSTILES:
		if r.hostiles.spawn(r.player_pos[0], Vector2.ZERO, 1.0, 4.0, 0) < 0:
			break
	for k in Terrain.MAX_TEMP_ZONES:
		r.terrain.add_temp_zone(Vector2(k * 10.0, 0.0), 30.0, Terrain.Kind.HAZARD, 9.0)
	var bytes: PackedByteArray = r.serialize_state(r.tick)
	print("  worst-case snapshot: %d bytes" % bytes.size())
	_check_true("the worst case is under SNAPSHOT_MAX",
		bytes.size() < SessionRules.SNAPSHOT_MAX)
	await _done(r, "the_worst_case_fits")
