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

const EXPECTED_CHECKS := 39

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
	var v: Variant = ProjectSettings.get_setting("application/config/version")
	var expect_v := "dev" if v == null else str(v)

	# The CRT overlay is a project-wide autoload (persists across the menu
	# <-> run scene swap), so it is reachable here regardless of which scene
	# this suite booted. Its ColorRect used set_anchors_preset alone once,
	# the same 0x0-forever trap the modal scrim hit — a screenshot cannot
	# tell a deliberately faint shader effect apart from one that never
	# covers anything, so pin the rect instead.
	var crt := root.get_node_or_null("CRTOverlay")
	_check("the CRT overlay autoload exists", crt != null, true)
	if crt != null and crt.get_child_count() > 0:
		var crect: Control = crt.get_child(0)
		_check("and its ColorRect actually covers the viewport",
			crect.get_global_rect().size, Vector2(vw, vh))

	# --- the hub: six entries, continue disabled, version lower-right -------
	var start: Node = _find(main, "Button", "start new run")
	_check("the start new run button exists", start != null, true)
	if start == null:
		main.queue_free()
		await process_frame
		return

	var cont: Node = _find(main, "Button", "continue run")
	_check("the continue run button exists", cont != null, true)
	_check("and it is disabled — no mid-run checkpoint exists",
		cont != null and (cont as Button).disabled, true)
	_check("the multiplayer button exists", _find(main, "Button", "multiplayer") != null, true)
	_check("the upgrades button exists", _find(main, "Button", "upgrades") != null, true)
	_check("the settings button exists", _find(main, "Button", "settings") != null, true)
	_check("the exit button exists", _find(main, "Button", "exit") != null, true)

	var r: Rect2 = (start as Control).get_global_rect()
	_check("start new run fits inside the viewport height", r.end.y <= vh, true)
	_check("start new run fits inside the viewport width", r.end.x <= vw, true)

	var subtitle: Node = _find(main, "Label", "subnet 01")
	_check("the boot subtitle exists and no longer carries the version",
		subtitle != null and String(subtitle.get("text")) ==
			"rogue process // corporate network // subnet 01", true)

	var vlabel: Label = main._version_label
	_check("the version label exists", vlabel != null, true)
	if vlabel != null:
		var vr: Rect2 = vlabel.get_global_rect()
		print("    version label rect %s" % vr)
		_check("it sits in the lower right corner",
			vr.position.y >= vh - 60.0 and vr.end.x <= vw and vr.position.x >= 0.0, true)
		_check("and has a positive size", vr.size.x > 0.0 and vr.size.y > 0.0, true)
		_check("and reads the build version", String(vlabel.text).begins_with("v%s" % expect_v), true)

	# --- the multiplayer page ------------------------------------------------
	main._open_page("multiplayer")
	for i in 4:
		await process_frame
	var host: Node = _find(main, "Button", "host")
	var join: Node = _find(main, "Button", "join")
	var addr: Node = _find(main, "LineEdit", "")
	var link_start: Node = _find(main, "Button", "start session")
	_check("the host button exists", host != null, true)
	_check("the join button exists", join != null, true)
	_check("an address field exists", addr != null, true)
	_check("a start session button exists on the multiplayer page", link_start != null, true)
	if host != null and join != null:
		var hr: Rect2 = (host as Control).get_global_rect()
		var jr: Rect2 = (join as Control).get_global_rect()
		_check("the link page fits inside the viewport width", jr.end.x <= vw, true)
		_check("and above the viewport's bottom", jr.end.y <= vh, true)
	main._back()
	for i in 4:
		await process_frame
	_check("back returns to the hub", main._hub.visible, true)

	# --- the upgrades page ----------------------------------------------------
	main._open_page("upgrades")
	for i in 4:
		await process_frame
	var scroll: Node = _find(main, "ScrollContainer", "")
	_check("the upgrade rows are in a ScrollContainer", scroll != null, true)
	_check("the salvage label is populated",
		main._salvage != null and String(main._salvage.text).contains("salvage"), true)
	main._back()
	for i in 4:
		await process_frame

	# --- settings --------------------------------------------------------------
	# The settings overlay must actually cover the shop: anchored from _ready
	# with set_anchors_preset it stayed 0x0 and the page showed through.
	var settings_btn: Node = _find(main, "Button", "settings")
	if settings_btn != null:
		settings_btn.pressed.emit()
		for i in 4:
			await process_frame
		var shown: Node = _find_settings(main)
		_check("the open settings panel spans the viewport",
			shown != null and (shown as Control).get_global_rect().size == Vector2(vw, vh), true)
		if shown != null:
			shown.close()

	# --- the update modal --------------------------------------------------------
	# It only appears on the update signal; simulate it so a display bug
	# cannot hide behind a network check. It must land INSIDE the viewport,
	# and dismissing it must leave the [update available] tag on the version.
	main._on_update_ready({"version": "0.4.9"})
	for i in 4:
		await process_frame
	_check("the update modal opens on update_ready",
		main._update_modal != null and main._update_modal.visible, true)
	if main._update_modal != null:
		var mscrim: Control = main._update_modal.get_child(0)
		_check("and its scrim actually covers the viewport — not a 0x0 anchors_preset trap",
			mscrim.get_global_rect().size, Vector2(vw, vh))
		# Size alone would still pass a reintroduced translucent-black bug —
		# the exact one a live screenshot caught: text bled straight through
		# a 0.72-alpha scrim over an already-near-black background.
		_check("and it is opaque, not translucent", mscrim.color.a, 1.0)
	var install: Node = _find(main, "Button", "install & restart")
	_check("and its install button exists", install != null, true)
	if install != null:
		var ir: Rect2 = (install as Control).get_global_rect()
		_check("and it fits the viewport", ir.end.x <= vw and ir.end.y <= vh, true)
	_check("the version tag lights up while an update is pending",
		String(main._version_label.text).contains("[update available]"), true)
	var later: Node = _find(main, "Button", "not now")
	_check("a not-now button exists", later != null, true)
	if later != null:
		later.pressed.emit()
		for i in 4:
			await process_frame
		_check("not now dismisses the modal", main._update_modal.visible, false)

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
