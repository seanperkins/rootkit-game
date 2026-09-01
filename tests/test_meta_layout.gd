extends SceneTree

## The shop screen went from three upgrade rows to eight. Five extra rows at
## 40px each is 200px added to a column that already ran to roughly 505px inside
## a 720px viewport, so without the ScrollContainer the ./intrude button falls
## off the bottom — and the button is the only thing on the screen that has to
## be reachable.
##
## The plan called this a manual screenshot gate. It is not: node rectangles are
## readable headlessly, so the check that actually matters is automatable and
## nobody has to remember to look.

const EXPECTED_CHECKS := 9

var failures := 0
var checks := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	print("ROOTKIT — meta screen layout\n")
	await process_frame
	await fits_the_viewport()
	await the_recipe_panel_lists_only_reachable_recipes()
	print("")
	if checks != EXPECTED_CHECKS:
		print("  FAIL — ran %d checks, expected %d (a function aborted early)"
			% [checks, EXPECTED_CHECKS])
		failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	checks += 1
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _find(node: Node, cls: String, needle: String) -> Node:
	if node.is_class(cls):
		if needle == "" or (node.get("text") != null and needle in str(node.get("text"))):
			return node
	for c in node.get_children():
		var hit := _find(c, cls, needle)
		if hit != null:
			return hit
	return null

func fits_the_viewport() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	# Several frames: containers resolve their rectangles over more than one.
	for i in 8:
		await process_frame

	var vh: float = ProjectSettings.get_setting("display/window/size/viewport_height")
	var vw: float = ProjectSettings.get_setting("display/window/size/viewport_width")

	var start: Node = _find(main, "Button", "intrude")
	_check("the start button exists", start != null, true)
	if start == null:
		main.queue_free()
		await process_frame
		return

	var r: Rect2 = (start as Control).get_global_rect()
	print("    ./intrude bottom edge at y=%.0f of %.0f" % [r.end.y, vh])
	_check("./intrude fits inside the viewport height", r.end.y <= vh, true)
	_check("./intrude fits inside the viewport width", r.end.x <= vw, true)

	var scroll: Node = _find(main, "ScrollContainer", "")
	_check("the upgrade rows are in a ScrollContainer", scroll != null, true)

	main.queue_free()
	await process_frame


## Exact triples over 35 modules are not discoverable by play, so the panel is
## part of the feature. It lists only recipes whose three modules are ALL
## unlocked: twenty rows of mostly-unreachable combinations is a wall, not
## information.
func the_recipe_panel_lists_only_reachable_recipes() -> void:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	var ui := _ui(run)

	var unlocked := {}
	for m in run._unlocked:
		unlocked[m.id] = true
	var want := 0
	for r in RecipeTable.all():
		if unlocked.has(r.vector_id) and unlocked.has(r.trigger_id) \
				and unlocked.has(r.payload_id):
			want += 1
	_check("only fully-unlocked recipes are listed",
		ui.recipe_lines().size(), want)
	_check("and there are fewer than all twenty at the start", want < 20, true)

	# A held-but-unranked slot is NOT filled: fusion demands max rank, and a
	# panel that showed [x] at rank 1 would lie about the only gate that matters.
	var mods := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(mods[&"packet"]); ex.place(mods[&"interval"]); ex.place(mods[&"fork_bomb"])
	run.loadout.exploits = [ex]
	var partial := ""
	for line in ui.recipe_lines():
		if line.contains("frag_packet"):
			partial = line
	_check("a held but unranked triple shows no filled mark",
		partial.count("[x]"), 0)
	_check("it shows them as held-but-short instead", partial.count("[-]"), 3)

	for em in ex.equipped():
		em.rank = em.module.max_rank
	var full := ""
	for line in ui.recipe_lines():
		if line.contains("frag_packet"):
			full = line
	_check("a maxed triple shows three filled marks", full.count("[x]"), 3)
	run.queue_free()
	await process_frame

## The HUD layer, found by duck-typing rather than by name: the run builds it
## anonymously, and adding a name for the test's benefit would be test-only code
## living in production.
func _ui(r: Node2D) -> CanvasLayer:
	for c in r.get_children():
		if c is CanvasLayer and c.has_method("bind"):
			return c
	return null
