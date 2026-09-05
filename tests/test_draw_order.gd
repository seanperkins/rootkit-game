extends SceneTree

## Which canvas draws on top of which.
##
## The world is spread across several canvas items with fixed z_index — the
## backdrop's lattice, the run's own floor and effects, four MultiMesh entity
## layers, and the standing objects. "What occludes what" is therefore not
## visible from any one file, and a renderer added later silently lands wherever
## its number happens to fall. Pinned here instead.

var failures := 0
var finished := {}

const CASES := ["standing_objects_draw_over_everything_that_moves",
	"every_live_player_is_drawn_and_the_camera_follows_the_view",
	"circuit_canvases_are_bounded_culled_and_presentation_only"]

func _initialize() -> void:
	SaveGame.use_test_paths()
	print("ROOTKIT — draw order\n")
	await standing_objects_draw_over_everything_that_moves()
	await every_live_player_is_drawn_and_the_camera_follows_the_view()
	await circuit_canvases_are_bounded_culled_and_presentation_only()
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

func _named(r: Node2D, n: String) -> Node2D:
	for c in r.get_children():
		if c is Node2D and c.name == n:
			return c
	return null

## Walls, corridor rails and gate posts are objects standing ON the floor, so
## they have to occlude what walks in front of them — including the player. They
## used to share the run's own canvas with the floor, which put them UNDER every
## entity: an enemy behind a wall was drawn on top of it.
func standing_objects_draw_over_everything_that_moves() -> void:
	var r := await _fresh_run()
	var props := _named(r, "Props")
	var backdrop := _named(r, "Backdrop")
	_check("there is a layer for standing objects", props != null, true)
	_check("and one for the ground", backdrop != null, true)

	var highest := -9999
	var layers := 0
	for c in r.get_children():
		if c is MultiMeshInstance2D:
			layers += 1
			highest = maxi(highest, c.z_index)
	_check("every entity pool has a renderer", layers, 4)

	_check("standing objects draw above all of them", props.z_index > highest, true)
	_check("and above the run's own floor and effects",
		props.z_index > r.z_index, true)
	_check("the ground stays under everything",
		backdrop.z_index < r.z_index, true)
	r.free()
	finished["standing_objects_draw_over_everything_that_moves"] = true

## Three peers on one screen: every LIVE slot is in the draw list, the local
## one nameless in the solo hue, teammates in distinct hues under their names;
## a DEAD slot vanishes; an ABSENT slot dims where it parked. The camera sits
## on the local slot while it is LIVE and on the spectate target after.
func every_live_player_is_drawn_and_the_camera_follows_the_view() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 3, 0, 20260830)
	var r: Node2D = h.runs[0]
	r._shake_pref = 0.0                   # a death shakes; the camera test wants the anchor alone
	r._refresh_view()
	var list: Array = r.player_draw_list()
	var slots := []
	var hues := {}
	for e in list:
		slots.append(e[0])
		hues[e[1]] = true
	_check("every LIVE slot is drawn", slots, [0, 1, 2])
	_check("the local slot keeps the solo hue, unnamed", [list[0][1], list[0][3]], [r.TEAM_HUES[0], ""])
	_check("teammates carry their names", [list[1][3], list[2][3]], ["p1", "p2"])
	_check("three distinct hues", hues.size(), 3)
	_check("everyone at full alpha", [list[0][2], list[1][2], list[2][2]], [1.0, 1.0, 1.0])
	r._process(0.0)
	_check("the camera follows the local slot while LIVE",
		r._camera.global_position, r.to_iso(r.player_render_pos[0]))
	r._die(1)
	r._park(2)
	list = r.player_draw_list()
	_check("a DEAD slot is not drawn, an ABSENT one is dimmed",
		[list.size(), list[1][0], list[1][2] < 1.0, list[1][3]], [2, 2, true, "p2 (away)"])
	# The local slot dies: the view moves to the next LIVE slot.
	r._return(2, r.lockstep.executed - 1)
	r._die(0)
	r._process(0.0)
	_check("dead, this screen looks through the next LIVE slot", r.view_slot, 2)
	_check("and the camera goes with it",
		r._camera.global_position, r.to_iso(r.player_render_pos[2]))
	_check("a dead local slot is not drawn", r.player_draw_list().size(), 1)
	h.teardown()
	await process_frame
	finished["every_live_player_is_drawn_and_the_camera_follows_the_view"] = true

func circuit_canvases_are_bounded_culled_and_presentation_only() -> void:
	var r := await _fresh_run()
	var backdrop := _named(r, "Backdrop")
	var before: int = r._state_hash()
	for i in 20:
		backdrop._process(float(i) * 0.01)
	_check("scenery never advances hashed state", r._state_hash(), before)
	_check("one cached circuit canvas per arena", backdrop.get_child_count(), r.terrain.arenas.size())
	var first := backdrop.get_child(0)
	_check("circuit canvas inherits backdrop depth", first.z_as_relative, true)
	_check("circuits stay below opaque missing-ground masks",
		backdrop.z_index + first.z_index < r.z_index, true)
	for index in r.terrain.arenas.size():
		r.player_pos[r.view_slot] = r.terrain.arenas[index].get_center()
		backdrop._process(0.016)
		for other in r.terrain.arenas.size():
			_check("arena %d from arena %d culled correctly" % [other, index],
				backdrop.get_child(other).visible, other == index)
	_check("camera travel reuses cached geometry", backdrop.get_child(0), first)
	r.free()
	finished["circuit_canvases_are_bounded_culled_and_presentation_only"] = true
