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

const EXPECTED_CHECKS := 4

var failures := 0
var checks := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	print("ROOTKIT — meta screen layout\n")
	await process_frame
	await fits_the_viewport()
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
