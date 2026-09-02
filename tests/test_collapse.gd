extends SceneTree

## The arena coming apart: the distance field that orders it, the death it
## deals, and the two things that make the walk out survivable — a lit route to
## the gate and visibly missing floor behind you.

var failures := 0
var finished := {}
const CASES := ["the_field_measures_from_the_gate", "collapse_eats_the_far_side_first",
	"the_route_follows_open_ground", "voided_ground_kills",
	"the_route_home_is_lit", "the_void_is_drawn_as_merged_runs",
	"the_corridor_collapses_after_the_arena"]

func _initialize() -> void:
	print("ROOTKIT — collapse\n")
	the_field_measures_from_the_gate()
	collapse_eats_the_far_side_first()
	the_route_follows_open_ground()
	the_corridor_collapses_after_the_arena()
	await voided_ground_kills()
	await the_route_home_is_lit()
	await the_void_is_drawn_as_merged_runs()
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

## The corridor is appended to the collapse order AFTER the whole arena, ordered
## from the arena end toward g.end, so once the arena is gone the way out itself
## voids and idling in the corridor is fatal. The corridor keys are negative and
## descending, sorting them strictly after every arena cell.
func the_corridor_collapses_after_the_arena() -> void:
	var t := _built()
	_check("the corridor contributes collapse cells",
		t.corridor_collapse_len > 0, true)
	var order: PackedInt32Array = t._collapse_order
	var dist: PackedInt32Array = t._collapse_dist
	var arena_total := order.size() - t.corridor_collapse_len
	_check("the last arena entry is still non-negative",
		dist[arena_total - 1] >= 0, true)

	# Every corridor entry: a real corridor cell (not part of the arena field),
	# a strictly descending negative key, and a projection along the gate
	# direction that only increases — the arena end first, g.end last.
	var g := t.gate()
	var ok_cells := true
	var ok_keys := true
	var ok_order := true
	var prev_proj := -INF
	for k in range(arena_total, order.size()):
		var c: int = order[k]
		if t.solid[c] != 0 or t.dist_from_gate[c] >= 0:
			ok_cells = false
		if dist[k] != -(k - arena_total + 1):
			ok_keys = false
		var cx := c % t.w
		var cy := c / t.w
		var centre := t.origin + Vector2(float(cx) + 0.5, float(cy) + 0.5) * Terrain.CELL
		var proj: float = (centre - g.pos).dot(g.dir)
		if proj < prev_proj:
			ok_order = false
		prev_proj = proj
	_check("every appended cell is a corridor cell", ok_cells, true)
	_check("corridor keys descend -1, -2, … after the arena", ok_keys, true)
	_check("corridor cells run from the arena end toward g.end", ok_order, true)
	finished["the_corridor_collapses_after_the_arena"] = true

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
	r.hitstop_ticks = 0  # drop the boss-kill hitstop; this case drives CLEARED mechanics directly
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

## The collapse is a race to the gate, so the way there has to be visible. The
## route was computed every time the player changed cell and then read by
## nothing at all — the walk out was unlit, which is what "there is no path out"
## looks like from the player's side.
func the_route_home_is_lit() -> void:
	var r := await _fresh_run()
	var b = r.enemy_types[EnemyTable.ICE]
	var i: int = r.enemies.spawn(Vector2(200, 0), Vector2.ZERO, b.integrity,
		48.0, EnemyTable.ICE)
	r._on_death(i)
	r.hitstop_ticks = 0  # drop the boss-kill hitstop; this case drives CLEARED mechanics directly
	r._physics_process(1.0 / 60.0)

	_check("a route exists to draw", r._route.size() > 0, true)
	_check("it starts under the player",
		r._route[0], r.terrain.cell_index(r.player_pos))
	_check("and ends on the gate",
		r.terrain.dist_from_gate[r._route[r._route.size() - 1]], 0)

	# What the renderer actually consumes: world-space cell centres, culled.
	var all := Rect2(r.terrain.origin, r.terrain.size)
	_check("every step of it is drawable", r._route_points(all).size(), r._route.size())
	var none := Rect2(r.terrain.origin - Vector2(9000, 9000), Vector2(10, 10))
	_check("and none of it is drawn off-screen", r._route_points(none).size(), 0)

	# Walking out ends the collapse, so the wash goes with it.
	r.terrain.open_gate()
	var g = r.terrain.gate()
	r.player_pos = g.end + g.dir * 8.0
	r._physics_process(1.0 / 60.0)
	_check("arriving on the next subnet clears the route", r._route.size(), 0)
	r.free()
	finished["the_route_home_is_lit"] = true

## Voided ground was lethal and invisible: you died standing on floor that still
## looked like floor. It is drawn as horizontal RUNS rather than per cell,
## because a collapsed arena is thousands of cells and one quad each is
## thousands of draw calls a frame.
func the_void_is_drawn_as_merged_runs() -> void:
	var r := await _fresh_run()
	var b = r.enemy_types[EnemyTable.ICE]
	var i: int = r.enemies.spawn(Vector2(200, 0), Vector2.ZERO, b.integrity,
		48.0, EnemyTable.ICE)
	r._on_death(i)
	r.hitstop_ticks = 0  # drop the boss-kill hitstop; this case drives CLEARED mechanics directly
	var all := Rect2(r.terrain.origin, r.terrain.size)
	_check("an intact arena has no void to draw", r._void_runs(all).size(), 0)

	r.terrain.collapse_to(int(r.terrain.max_dist / 2))
	var runs: Array = r._void_runs(all)
	_check("once it starts falling there is", runs.size() > 0, true)

	# Every run covers voided cells and only voided cells.
	var wrong := 0
	var covered := {}
	for run in runs:
		for x in range(run.x, run.y + 1):
			var idx: int = run.z * r.terrain.w + x
			if r.terrain.voided[idx] == 0:
				wrong += 1
			covered[idx] = true
	_check("no run paints ground that is still there", wrong, 0)

	var total := 0
	for k in r.terrain.voided.size():
		if r.terrain.voided[k] != 0:
			total += 1
	_check("and every voided cell is covered", covered.size(), total)
	# The whole point of runs: far fewer of them than there are cells.
	_check("adjacent cells merge into one run", runs.size() < total, true)

	# Clipped, so an off-screen collapse costs nothing.
	_check("a view off the map draws none of it",
		r._void_runs(Rect2(r.terrain.origin - Vector2(9000, 9000),
			Vector2(10, 10))).size(), 0)
	r.free()
	finished["the_void_is_drawn_as_merged_runs"] = true
