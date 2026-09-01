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

const CASES := ["standing_objects_draw_over_everything_that_moves"]

func _initialize() -> void:
	SaveGame.use_test_paths()
	print("ROOTKIT — draw order\n")
	await standing_objects_draw_over_everything_that_moves()
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
