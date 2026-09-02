extends SceneTree

## Facing, the forward vectors, the mine drop, the shield rearm and the fx
## structural checks. Every case builds its own run; the harness cases build
## two.

var failures := 0
var finished := {}
const DT := 1.0 / 60.0

const CASES := ["facing_follows_the_applied_record_and_holds",
	"facing_survives_a_restore", "two_peers_agree_while_turning",
	"a_return_resets_facing",
	"packet_flies_along_facing", "a_homing_packet_still_binds",
	"beam_hits_its_capsule_only", "spike_hits_its_wedge_only",
	"beam_radius_floor_holds_in_the_tables"]

func _initialize() -> void:
	print("ROOTKIT — facing\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	await facing_follows_the_applied_record_and_holds()
	await facing_survives_a_restore()
	await two_peers_agree_while_turning()
	await a_return_resets_facing()
	await packet_flies_along_facing()
	await a_homing_packet_still_binds()
	await beam_hits_its_capsule_only()
	await spike_hits_its_wedge_only()
	beam_radius_floor_holds_in_the_tables()
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

func _fresh_run() -> Node2D:
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	r.external_drive = true
	root.add_child(r)
	await process_frame
	r.input_override = Vector2.ZERO
	return r

func facing_follows_the_applied_record_and_holds() -> void:
	var r := await _fresh_run()
	_check("facing starts right", r.player_facing[r.local_slot], Vector2.RIGHT)
	r.input_override = Vector2(3.0, 4.0)     # not unit: the poll normalises once
	r._physics_process(DT)
	var f: Vector2 = r.player_facing[r.local_slot]
	_check_true("a diagonal record sets a unit facing", absf(f.length() - 1.0) < 1e-5)
	_check_true("pointing the way it moved", f.dot(Vector2(3.0, 4.0).normalized()) > 0.999)
	r.input_override = Vector2.ZERO
	for _i in 5:
		r._physics_process(DT)
	_check("a zero record keeps it", r.player_facing[r.local_slot], f)
	r.free()
	await process_frame
	finished["facing_follows_the_applied_record_and_holds"] = true

func facing_survives_a_restore() -> void:
	var a := await _fresh_run()
	var b := await _fresh_run()
	a.input_override = Vector2(-1.0, 0.0)
	a._physics_process(DT)
	var bytes: PackedByteArray = a.serialize_state(a.tick)
	_check_true("restore accepts it", b.restore_state(bytes, a.tick))
	_check("facing came through the snapshot", b.player_facing[0], a.player_facing[0])
	_check("and the hashes agree", b._state_hash(), a._state_hash())
	a.free(); b.free()
	await process_frame
	finished["facing_survives_a_restore"] = true

func two_peers_agree_while_turning() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, 2, 20260830)
	var fn := func(t: int) -> Array:
		var a := float(t) * 0.05
		return [Vector2(cos(a), sin(a)), Vector2(-sin(a), cos(a))]
	for _i in 600:
		h.step(fn)
	_check("two turning peers agree", h.all_agree(), true)
	if not h.all_agree():
		print("    diff ", h.first_difference(h.runs[0], h.runs[1]))
	h.teardown()
	await process_frame
	finished["two_peers_agree_while_turning"] = true

func a_return_resets_facing() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, 0, 20260830)
	var fn := func(_t: int) -> Array: return [Vector2.ZERO, Vector2(-1.0, 0.0)]
	for _i in 5:
		h.step(fn)
	for r in h.runs:
		_check("slot one faces left before parking", r.player_facing[1], Vector2.LEFT)
		r._park(1)
		r._return(1, r.lockstep.executed - 1)
		_check("a return faces right again", r.player_facing[1], Vector2.RIGHT)
	h.teardown()
	await process_frame
	finished["a_return_resets_facing"] = true

## A run with one exploit on the local slot: vector + interval (+ payloads).
func _with(r: Node2D, vector_id: StringName, payloads: Array = [], fused: Module = null) -> int:
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	if fused != null:
		ex.vector = EquippedModule.new(fused, 1)
	else:
		ex.place(t[vector_id])
	ex.place(t[&"interval"])
	for p in payloads:
		ex.place(t[p])
	r.loadouts[r.local_slot].exploits = [ex]
	r._recompile()
	return r._gid(r.local_slot, 0)

func _face(r: Node2D, dir: Vector2) -> void:
	r.input_override = dir
	r._physics_process(DT)
	r.input_override = Vector2.ZERO

func _spawn(r: Node2D, offset: Vector2) -> int:
	return r.enemies.spawn(r.player_pos[r.local_slot] + offset, Vector2.ZERO, 9999.0, r.ENEMY_RADIUS, 0)

## Which enemies the queue holds DAMAGE events for after one emit.
func _targets_hit(r: Node2D, gid: int) -> Array:
	r.queue.begin_tick()
	r._step3_rebuild()
	r._emit_vector(gid, r.resolved[gid])
	var out := []
	for k in r.queue.count:
		if r.queue.source_exploit[k] == gid and not (r.queue.target[k] in out):
			out.append(r.queue.target[k])
	return out

func packet_flies_along_facing() -> void:
	var r := await _fresh_run()
	var gid := _with(r, &"packet")
	_spawn(r, Vector2(0.0, -300.0))            # an enemy up, off the facing axis
	_face(r, Vector2.LEFT)
	r.queue.begin_tick()
	r._step3_rebuild()
	var before: int = r.projectiles.count
	r._emit_vector(gid, r.resolved[gid])
	_check("a packet spawned", r.projectiles.count, before + 1)
	var i: int = r.projectiles.count - 1
	_check_true("it flies along facing, not at the enemy", r.projectiles.vel[i].normalized().dot(Vector2.LEFT) > 0.999)
	_check("and binds no target", r._proj_target[i], -1)
	r.free(); await process_frame
	finished["packet_flies_along_facing"] = true

func a_homing_packet_still_binds() -> void:
	var r := await _fresh_run()
	var homer := Module.make(&"test_homer", "test_homer()", Module.Slot.VECTOR,
		{&"damage": 5.0, &"projectile_speed": 400.0, &"cooldown": 0.5,
		 &"travel": 900.0, &"homing": 2.6}, [], Module.VectorKind.PACKET, Module.TriggerKind.INTERVAL)
	homer.is_fused = true
	var gid := _with(r, &"", [], homer)
	var e := _spawn(r, Vector2(0.0, -300.0))
	_face(r, Vector2.LEFT)
	r.queue.begin_tick()
	r._step3_rebuild()
	r._emit_vector(gid, r.resolved[gid])
	var i: int = r.projectiles.count - 1
	_check("a homing packet binds its target", r._proj_target[i], e)
	_check_true("and launches toward it", r.projectiles.vel[i].normalized().dot(Vector2.UP) > 0.99)
	r.free(); await process_frame
	finished["a_homing_packet_still_binds"] = true

func beam_hits_its_capsule_only() -> void:
	var r := await _fresh_run()
	var gid := _with(r, &"beam")
	var radius: float = r.resolved[gid].radius
	_face(r, Vector2.RIGHT)
	var far_end := _spawn(r, Vector2(radius - 1.0, 0.0))
	var corner := _spawn(r, Vector2(radius, r.BEAM_HALF_WIDTH + r.ENEMY_RADIUS - 1.0))
	var beside := _spawn(r, Vector2(radius * 0.5, r.BEAM_HALF_WIDTH + r.ENEMY_RADIUS + 20.0))
	var behind := _spawn(r, Vector2(-60.0, 0.0))
	var hit := _targets_hit(r, gid)
	_check("the far end is hit", far_end in hit, true)
	_check("the far-end corner at full offset is hit", corner in hit, true)
	_check("beside the beam is not", beside in hit, false)
	_check("behind is not", behind in hit, false)
	r.free(); await process_frame
	finished["beam_hits_its_capsule_only"] = true

func spike_hits_its_wedge_only() -> void:
	var r := await _fresh_run()
	var gid := _with(r, &"spike")
	_face(r, Vector2.DOWN)
	var ahead := _spawn(r, Vector2(0.0, 80.0))
	var behind := _spawn(r, Vector2(0.0, -80.0))
	var hit := _targets_hit(r, gid)
	_check("inside the wedge is hit", ahead in hit, true)
	_check("behind is not", behind in hit, false)
	r.free(); await process_frame
	finished["spike_hits_its_wedge_only"] = true

func beam_radius_floor_holds_in_the_tables() -> void:
	var bad := []
	for m in ModuleTable.all():
		if m.slot == Module.Slot.VECTOR and m.vector_kind == Module.VectorKind.BEAM \
				and float(m.stats.get(&"radius", 0.0)) < 31.0:
			bad.append(m.id)
	for rec in RecipeTable.all():
		if rec.fused.vector_kind == Module.VectorKind.BEAM \
				and float(rec.fused.stats.get(&"radius", 0.0)) < 31.0:
			bad.append(rec.fused.id)
	_check("every beam radius clears the query-cover floor of 31", bad, [])
	finished["beam_radius_floor_holds_in_the_tables"] = true
