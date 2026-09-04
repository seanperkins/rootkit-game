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

const EXPECTED_CHECKS := 22

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

func _find_settings(node: Node) -> Node:
	if node.has_method("_nudge"):
		return node
	for c in node.get_children():
		var hit := _find_settings(c)
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

	# The build version rides the subtitle line (meta_screen._build reads
	# application/config/version; "dev" when unset). Pin the text so a layout
	# change cannot silently drop the only in-game display of it.
	var subtitle: Node = _find(main, "Label", "subnet 01")
	var v: Variant = ProjectSettings.get_setting("application/config/version")
	var expect_v := "dev" if v == null else str(v)
	_check("the boot subtitle names the build",
		subtitle != null and ("v%s" % expect_v) in str(subtitle.get("text")), true)

	var r: Rect2 = (start as Control).get_global_rect()
	print("    ./intrude bottom edge at y=%.0f of %.0f" % [r.end.y, vh])
	_check("./intrude fits inside the viewport height", r.end.y <= vh, true)
	_check("./intrude fits inside the viewport width", r.end.x <= vw, true)

	# The settings overlay must actually cover the shop: anchored from _ready
	# with set_anchors_preset it stayed 0x0 and the shop showed through.
	var settings_btn: Node = _find(main, "Button", "settings")
	_check("the settings button exists", settings_btn != null, true)
	if settings_btn != null:
		settings_btn.pressed.emit()
		for i in 4:
			await process_frame
		var shown: Node = _find_settings(main)
		_check("the open settings panel spans the viewport",
			shown != null and (shown as Control).get_global_rect().size == Vector2(vw, vh), true)
		if shown != null:
			shown.close()

	var scroll: Node = _find(main, "ScrollContainer", "")
	_check("the upgrade rows are in a ScrollContainer", scroll != null, true)

	# The link column sits beside the shop, inside the viewport at 1280 wide and
	# clear of the shop column, so neither can push the other off-screen at the
	# smallest supported width.
	# The update strip only appears on update signal; simulate it so a display
	# bug cannot hide behind a network check. It must land INSIDE the viewport
	# (bottom-anchored) with its buttons reachable.
	main._on_update_ready({"version": "0.4.1"})
	for i in 4:
		await process_frame
	var install: Node = _find(main, "Button", "install & restart")
	_check("the update strip appears on update_ready", install != null
		and (install as Control).visible, true)
	if install != null:
		var ir: Rect2 = (install as Control).get_global_rect()
		_check("and its install button fits the viewport",
			ir.end.x <= vw and ir.end.y <= vh, true)
		var row: Control = install.get_parent()
		var rr: Rect2 = row.get_global_rect()
		# Measured here: 448x36 at (64, 656) in a 720px viewport. Godot clamps
		# the control to the row's minimum width (three buttons ≈ 448px), so
		# the anchor-less right edge is not degenerate — but pin the shape
		# anyway: a zero-sized strip renders nothing while every "fits the
		# viewport" check above still passes.
		_check("the strip has a positive size", rr.size.x > 0 and rr.size.y > 0, true)
		_check("and starts inside the viewport",
			rr.position.x >= 0 and rr.position.y >= 0, true)
		print("    update strip rect %s; install button rect %s" % [rr, ir])
	main._on_update_state("")

	var host: Node = _find(main, "Button", "host")
	var join: Node = _find(main, "Button", "join")
	var addr: Node = _find(main, "LineEdit", "")
	_check("the host button exists", host != null, true)
	_check("the join button exists", join != null, true)
	_check("an address field exists", addr != null, true)
	if host != null and join != null:
		var hr: Rect2 = (host as Control).get_global_rect()
		var jr: Rect2 = (join as Control).get_global_rect()
		_check("the link column fits inside the viewport width", jr.end.x <= vw, true)
		_check("and its buttons sit clear of the shop column", hr.position.x >= r.end.x, true)
		_check("and above the viewport's bottom", jr.end.y <= vh, true)

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
	for m in run._unlocked[run.local_slot]:
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
	run.loadouts[run.local_slot].exploits = [ex]
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
