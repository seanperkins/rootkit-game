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
	"packet_flies_at_the_nearest_enemy", "packet_with_no_enemy_keeps_the_aim",
	"a_homing_packet_still_binds",
	"beam_hits_its_capsule_only", "spike_hits_its_wedge_only",
	"beam_radius_floor_holds_in_the_tables",
	"mines_drop_behind_on_open_ground", "mines_avoid_a_wall",
	"the_checksum_payload_rearms_not_refires",
	"redundancy_grants_every_fire_unless_it_carries_checksum",
	"every_emitted_fx_kind_is_drawn",
	"aim_overrides_movement_facing", "a_hostile_aim_is_neutral_and_a_long_one_is_unit",
	"aims_survive_a_restore", "two_peers_agree_while_aiming"]

func _initialize() -> void:
	print("ROOTKIT — facing\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	await facing_follows_the_applied_record_and_holds()
	await facing_survives_a_restore()
	await two_peers_agree_while_turning()
	await a_return_resets_facing()
	await packet_flies_at_the_nearest_enemy()
	await packet_with_no_enemy_keeps_the_aim()
	await a_homing_packet_still_binds()
	await beam_hits_its_capsule_only()
	await spike_hits_its_wedge_only()
	beam_radius_floor_holds_in_the_tables()
	await mines_drop_behind_on_open_ground()
	await mines_avoid_a_wall()
	await the_checksum_payload_rearms_not_refires()
	await redundancy_grants_every_fire_unless_it_carries_checksum()
	every_emitted_fx_kind_is_drawn()
	await aim_overrides_movement_facing()
	await a_hostile_aim_is_neutral_and_a_long_one_is_unit()
	await aims_survive_a_restore()
	await two_peers_agree_while_aiming()
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

func packet_flies_at_the_nearest_enemy() -> void:
	var r := await _fresh_run()
	var gid := _with(r, &"packet")
	var near: int = _spawn(r, Vector2(0.0, -300.0))   # 300 up, closer
	var far: int = _spawn(r, Vector2(-430.0, 0.0))    # 430 left, farther
	_face(r, Vector2.LEFT)
	r.queue.begin_tick()
	r._step3_rebuild()
	var before: int = r.projectiles.count
	r._emit_vector(gid, r.resolved[gid])
	_check("a packet spawned", r.projectiles.count, before + 1)
	var i: int = r.projectiles.count - 1
	# The facing is LEFT; the nearest enemy is UP. The shot must go at the
	# enemy, and must pick the NEAREST of the two, not the first in the grid.
	_check_true("it aims at the nearest enemy, not the facing",
		r.projectiles.vel[i].normalized().dot(Vector2.UP) > 0.99)
	_check("and binds that target", r._proj_target[i], near)
	r.free(); await process_frame
	finished["packet_flies_at_the_nearest_enemy"] = true

func packet_with_no_enemy_keeps_the_aim() -> void:
	var r := await _fresh_run()
	var gid := _with(r, &"packet")
	_face(r, Vector2.LEFT)
	r.queue.begin_tick()
	r._step3_rebuild()
	var before: int = r.projectiles.count
	r._emit_vector(gid, r.resolved[gid])
	var i: int = r.projectiles.count - 1
	_check("empty ground falls back to the aim",
		r.projectiles.vel[i].normalized().dot(Vector2.LEFT) > 0.999, true)
	_check("and binds no target", r._proj_target[i], -1)
	r.free(); await process_frame
	finished["packet_with_no_enemy_keeps_the_aim"] = true

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

func _mine_positions(r: Node2D, gid: int) -> Array:
	var before: int = r.projectiles.count
	r._emit_vector(gid, r.resolved[gid])
	var out := []
	for i in range(before, r.projectiles.count):
		out.append(r.projectiles.pos[i])
	return out

func mines_drop_behind_on_open_ground() -> void:
	var r := await _fresh_run()
	var gid := _with(r, &"landmine")
	_face(r, Vector2.RIGHT)
	var p: Vector2 = r.player_pos[r.local_slot]   # after the facing tick moved it
	var one := _mine_positions(r, gid)
	_check("one mine lands MINE_DROP behind", one[0], p - Vector2.RIGHT * r.MINE_DROP)
	# No base payload carries split_count on a mine; set it on the resolved row.
	var ring := _with(r, &"landmine")
	r.resolved[ring].split_count = 3.0
	var three := _mine_positions(r, ring)
	_check("three mines dropped", three.size(), 3)
	var nearest := INF
	for q in three:
		nearest = minf(nearest, (q - p).length())
	_check("a three-mine ring's nearest vertex is MINE_DROP - MINE_SPREAD behind",
		absf(nearest - (r.MINE_DROP - r.MINE_SPREAD)) < 0.5, true)
	for q in three:
		_check_true("every mine is behind the owner", (q - p).dot(Vector2.RIGHT) < 0.0)
	r.free(); await process_frame
	finished["mines_drop_behind_on_open_ground"] = true

func mines_avoid_a_wall() -> void:
	var r := await _fresh_run()
	var gid := _with(r, &"landmine")
	r.resolved[gid].split_count = 3.0
	_face(r, Vector2.RIGHT)
	var p: Vector2 = r.player_pos[r.local_slot]
	# Wall the ring's centre cell.
	var c: int = r.terrain.cell_index(p - Vector2.RIGHT * r.MINE_DROP)
	r.terrain.solid[c] = 1
	for q in _mine_positions(r, gid):
		_check("every mine lands on open ground", r.terrain.is_solid(q), false)
	r.free(); await process_frame
	finished["mines_avoid_a_wall"] = true

func _fire_n(r: Node2D, gid: int, n: int) -> void:
	for _i in n:
		r.queue.begin_tick()
		r._emit_vector(gid, r.resolved[gid])

func the_checksum_payload_rearms_not_refires() -> void:
	var r := await _fresh_run()
	var gid := _with(r, &"packet", [&"checksum"])
	_fire_n(r, gid, 1)
	_check("the first fire grants the pool", r.player_shield[r.local_slot], 26.0)
	r.player_shield[r.local_slot] = 5.0          # spent under damage
	_fire_n(r, gid, 3)
	_check("further fires inside the rearm grant nothing", r.player_shield[r.local_slot], 5.0)
	r._shield_left[gid] = 0.0                    # the rearm elapsed
	_fire_n(r, gid, 1)
	_check("after the rearm it refills", r.player_shield[r.local_slot], 26.0)
	r.loadouts[r.local_slot].exploits[0].payloads[0].rank = 5
	r._recompile()
	_check("rank scales the pool", r.resolved[gid].shield, 130.0)
	_check("but not the rearm", r.resolved[gid].shield_rearm, 2.6)
	r.free(); await process_frame
	finished["the_checksum_payload_rearms_not_refires"] = true

func redundancy_grants_every_fire_unless_it_carries_checksum() -> void:
	var r := await _fresh_run()
	var rec: RecipeTable.Recipe = null
	for x in RecipeTable.all():
		if x.fused.id == &"redundancy":
			rec = x
	var gid := _with(r, &"", [], rec.fused)
	_fire_n(r, gid, 1)
	r.player_shield[r.local_slot] = 5.0
	_fire_n(r, gid, 1)
	_check("a bare redundancy row refills on every fire", r.player_shield[r.local_slot], 60.0)
	var t := ModuleTable.by_id()
	r.loadouts[r.local_slot].exploits[0].place(t[&"checksum"])
	r._recompile()
	_fire_n(r, gid, 1)
	r.player_shield[r.local_slot] = 5.0
	_fire_n(r, gid, 1)
	_check("with checksum on it, the row refills on the rearm instead", r.player_shield[r.local_slot], 5.0)
	r.free(); await process_frame
	finished["redundancy_grants_every_fire_unless_it_carries_checksum"] = true

## Every kind an emit site appends has a draw arm, and the emit-site counts
## per kind are pinned so a non-fire emitter (the arrival flash, the
## kernel_panic telegraph) cannot be dropped silently.
func every_emitted_fx_kind_is_drawn() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/run/run.gd")
	var draw_start := src.find("func _draw()")
	var draw_body := src.substr(draw_start, src.find("\nfunc ", draw_start + 10) - draw_start)
	var counts := {}
	var re := RegEx.new()
	re.compile("_fx\\.append\\(\\[FxKind\\.([A-Z]+)")
	for m in re.search_all(src):
		var k: String = m.get_string(1)
		counts[k] = counts.get(k, 0) + 1
		_check_true("FxKind.%s has a draw arm" % k, draw_body.contains("FxKind.%s:" % k))
	_check("emit sites per kind are as pinned",
		counts, {"RIPPLE": 2, "DASH": 1, "BOLT": 2, "BEAM": 1, "WEDGE": 1, "PULSE": 2, "BLAST": 1})
	finished["every_emitted_fx_kind_is_drawn"] = true

func aim_overrides_movement_facing() -> void:
	var r := await _fresh_run()
	r.input_override = Vector2.LEFT
	r.aim_override = Vector2.UP
	r._physics_process(DT)
	_check("an aim sets the facing over the movement", r.player_facing[r.local_slot], Vector2.UP)
	_check("the aim is applied into aims", r.aims[r.local_slot], Vector2.UP)
	r.aim_override = Vector2.ZERO
	r._physics_process(DT)
	_check("a zero aim falls back to the movement", r.player_facing[r.local_slot], Vector2.LEFT)
	r.input_override = Vector2.ZERO
	for _i in 3:
		r._physics_process(DT)
	_check("standing still with no aim holds it", r.player_facing[r.local_slot], Vector2.LEFT)
	r.free(); await process_frame
	finished["aim_overrides_movement_facing"] = true

## Sanitised at APPLICATION, like the move: a component past
## MOVE_COMPONENT_MAX or non-finite is a zero aim; a legal non-unit aim is
## normalised so a record cannot set a facing of length 40.
func a_hostile_aim_is_neutral_and_a_long_one_is_unit() -> void:
	var r := await _fresh_run()
	_check("a huge aim is neutral", r._sanitise_aim(Vector2(40.0, 0.0)), Vector2.ZERO)
	_check("a NaN aim is neutral", r._sanitise_aim(Vector2(NAN, 0.0)), Vector2.ZERO)
	_check("a zero aim stays zero", r._sanitise_aim(Vector2.ZERO), Vector2.ZERO)
	var u: Vector2 = r._sanitise_aim(Vector2(1.2, 0.9))
	_check_true("a legal long aim is unit", absf(u.length() - 1.0) < 1e-6)
	# Through the ring: a record placed for the tick the poll would fill stands,
	# so the poll's own submit is refused and this record is what applies.
	r.lockstep.submit(r.local_slot, r.lockstep.executed, Vector2.ZERO, -1, -1, -1, Vector2(40.0, 0.0))
	r._physics_process(DT)
	_check("a hostile aim leaves the facing alone", r.player_facing[r.local_slot], Vector2.RIGHT)
	r.free(); await process_frame
	finished["a_hostile_aim_is_neutral_and_a_long_one_is_unit"] = true

func aims_survive_a_restore() -> void:
	var a := await _fresh_run()
	var b := await _fresh_run()
	a.aim_override = Vector2.DOWN
	a._physics_process(DT)
	var bytes: PackedByteArray = a.serialize_state(a.tick)
	_check_true("restore accepts it", b.restore_state(bytes, a.tick))
	_check("aims came through the snapshot", b.aims[0], a.aims[0])
	_check("and the facing did", b.player_facing[0], Vector2.DOWN)
	_check("and the hashes agree", b._state_hash(), a._state_hash())
	a.free(); b.free()
	await process_frame
	finished["aims_survive_a_restore"] = true

func two_peers_agree_while_aiming() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, 2, 20260830)
	var moves := func(t: int) -> Array:
		var a := float(t) * 0.05
		return [Vector2(cos(a), sin(a)), Vector2(-sin(a), cos(a))]
	var aims := func(t: int) -> Array:
		var a := float(t) * 0.11
		return [Vector2(cos(a), -sin(a)), Vector2.ZERO if t % 7 == 0 else Vector2(sin(a), cos(a))]
	for _i in 600:
		h.step(moves, aims)
	_check("two aiming peers agree", h.all_agree(), true)
	if not h.all_agree():
		print("    diff ", h.first_difference(h.runs[0], h.runs[1]))
	h.teardown()
	await process_frame
	finished["two_peers_agree_while_aiming"] = true
