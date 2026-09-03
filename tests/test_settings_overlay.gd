extends SceneTree

## The settings panel is a full-screen MODAL, and both of the screens that open
## it stay in the tree underneath: the shell's shop column, and the run's pause
## panel. Nothing about that is visible in the source — it only shows up as one
## menu drawn through another.
##
## It shipped broken: `settings_panel.gd` anchored itself from `_ready` with
## `set_anchors_preset`, which keeps the current rect by compensating the
## offsets, so the panel stayed 0x0. Its scrim covered nothing while its labels
## and buttons drew anyway, and the pause menu's own text showed straight
## through the settings rows. A zero-size scrim also stops blocking the mouse,
## which put "abandon run" a stray click away from anyone nudging a volume.
##
## The rect fix is pinned by test_hud and test_meta_layout. This suite pins the
## other half — the scrim is OPAQUE, at BOTH call sites, because a translucent
## one leaves the covered menu legible through it and the two screens build the
## panel independently.

const EXPECTED_CHECKS := 8

var failures := 0
var checks := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	print("ROOTKIT — settings overlay\n")
	await process_frame
	await the_shell_settings_panel_covers_the_screen()
	await the_run_settings_panel_covers_the_pause_menu()
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

func _viewport_size() -> Vector2:
	return Vector2(
		float(ProjectSettings.get_setting("display/window/size/viewport_width")),
		float(ProjectSettings.get_setting("display/window/size/viewport_height")))

func _scrim(panel: Control) -> ColorRect:
	for c in panel.get_children():
		if c is ColorRect:
			return c
	return null

## Four checks, one call site. The panel's own rect is what blocks the mouse;
## the scrim's rect and its alpha are what hide the screen underneath, and a
## translucent scrim would leave the covered menu legible through it.
func _assert_covers(where: String, panel: Control) -> void:
	var vp := _viewport_size()
	_check("%s: the panel is visible" % where, panel.visible, true)
	_check("%s: the panel fills the viewport" % where, panel.get_global_rect().size, vp)
	var scrim := _scrim(panel)
	if scrim == null:
		_check("%s: the panel has a scrim" % where, false, true)
		_check("%s: the scrim is opaque" % where, false, true)
		return
	_check("%s: the scrim fills the viewport" % where, scrim.get_global_rect().size, vp)
	_check("%s: the scrim is opaque" % where, scrim.color.a, 1.0)

func the_shell_settings_panel_covers_the_screen() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 8:
		await process_frame
	main._settings.open()
	for i in 4:
		await process_frame
	_assert_covers("shell", main._settings)
	main.queue_free()
	await process_frame

func _ui(r: Node2D) -> CanvasLayer:
	for c in r.get_children():
		if c is CanvasLayer and c.has_method("bind"):
			return c
	return null

func the_run_settings_panel_covers_the_pause_menu() -> void:
	SaveGame.use_fresh_state()
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(r)
	await process_frame
	r.input_override = Vector2.ZERO
	var ui := _ui(r)
	ui._toggle_pause()
	ui._settings.open()
	for i in 4:
		await process_frame
	_assert_covers("run", ui._settings)
	r.queue_free()
	await process_frame
