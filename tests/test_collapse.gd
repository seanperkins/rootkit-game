extends SceneTree

## The arena coming apart: the distance field that orders it, and the death it
## deals.

var failures := 0
var finished := {}
const CASES := ["the_field_measures_from_the_gate", "collapse_eats_the_far_side_first",
	"the_route_follows_open_ground", "voided_ground_kills"]

func _initialize() -> void:
	print("ROOTKIT — collapse\n")
	the_field_measures_from_the_gate()
	collapse_eats_the_far_side_first()
	the_route_follows_open_ground()
	await voided_ground_kills()
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

func _fresh_run() -> Node2D:
	SaveGame.use_fresh_state()
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(r)
	await process_frame
	return r

func _built(seed_value: int = 9) -> Terrain:
	var t := Terrain.new(Vector2(3072, 1920), 3, seed_value)
	t.generate(seed_value, Vector2.ZERO)
	t.build_distance_field()
	return t

func _void_count(t: Terrain) -> int:
	var n := 0
	for i in t.voided.size():
		if t.voided[i] != 0: n += 1
	return n

func the_field_measures_from_the_gate() -> void:
	var t := _built()
	_check("the gate itself is distance zero",
		t.dist_from_gate[t.cell_index(t.gate().pos)], 0)
	_check("somewhere is far away", t.max_dist > 20, true)
	# Every open cell of the CURRENT arena, and only those. The campaign is one
	# connected map, so an unbounded fill would measure the subnets ahead as
	# well and hand the collapse a max distance from ground nobody is on.
	var unmeasured := 0
	var c := t.arena_cells(0)
	for y in range(c.position.y, c.end.y):
		for x in range(c.position.x, c.end.x):
			var i := y * t.w + x
			if t.solid[i] == 0 and t.dist_from_gate[i] < 0:
				unmeasured += 1
	_check("every open cell of this arena is measured", unmeasured, 0)

	var beyond := 0
	for k in range(1, t.arenas.size()):
		var c2 := t.arena_cells(k)
		for y in range(c2.position.y, c2.end.y):
			for x in range(c2.position.x, c2.end.x):
				if t.dist_from_gate[y * t.w + x] >= 0:
					beyond += 1
	_check("and no cell of the subnets ahead is", beyond, 0)
	finished["the_field_measures_from_the_gate"] = true

func collapse_eats_the_far_side_first() -> void:
	var t := _built()
	t.collapse_to(t.max_dist)
	_check("nothing has fallen yet", _void_count(t), 0)

	t.collapse_to(int(t.max_dist / 2))
	var bad := 0
	for i in t.solid.size():
		if t.voided[i] != 0 and t.dist_from_gate[i] <= int(t.max_dist / 2):
			bad += 1
	_check("only the far side has gone", bad, 0)
	_check("and some of it has", _void_count(t) > 0, true)

	# The corridor is never voided: it is the way out. Nor is the arena beyond
	# it, which is the subnet still to be fought.
	t.collapse_to(0)
	_check("the corridor survives to the end",
		t.voided[t.cell_index(t.gate().end - t.gate().dir * Terrain.CELL)], 0)
	_check("and so does the gate", t.voided[t.cell_index(t.gate().pos)], 0)
	_check("and so does the subnet ahead",
		t.voided[t.cell_index(t.arenas[1].get_center())], 0)
	finished["collapse_eats_the_far_side_first"] = true

func the_route_follows_open_ground() -> void:
	var t := _built(3)
	var route := t.route_from(Vector2.ZERO, 400)
	_check("a route exists", route.size() > 0, true)
	var ok := true
	for k in range(1, route.size()):
		if t.solid[route[k]] != 0:
			ok = false
		if t.dist_from_gate[route[k]] >= t.dist_from_gate[route[k - 1]]:
			ok = false
	_check("every step is open and closer in", ok, true)
	_check("and it ends at the gate",
		t.dist_from_gate[route[route.size() - 1]], 0)
	finished["the_route_follows_open_ground"] = true

func voided_ground_kills() -> void:
	var r := await _fresh_run()
	var b = r.enemy_types[EnemyTable.ICE]
	var i: int = r.enemies.spawn(Vector2(200, 0), Vector2.ZERO, b.integrity,
		48.0, EnemyTable.ICE)
	r._on_death(i)
	_check("the clock starts on the boss kill", r.collapse_left > 0.0, true)
	# Stand as far from the gate as the field goes, then run the clock out.
	var far := -1
	for k in r.terrain.dist_from_gate.size():
		if r.terrain.dist_from_gate[k] == r.terrain.max_dist:
			far = k
	r.player_pos = r.terrain.origin + Vector2(
		float(far % r.terrain.w) + 0.5, float(far / r.terrain.w) + 0.5) * Terrain.CELL
	r.collapse_left = 0.001
	r._physics_process(1.0 / 60.0)
	_check("collapsed ground is lethal", r.alive, false)
	r.free()
	finished["voided_ground_kills"] = true
