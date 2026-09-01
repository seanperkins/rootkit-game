extends SceneTree

## The InputMap, gamepad reachability, and the pause flag.
##
## The gamepad case is the point of the whole migration: an InputEventJoypadButton
## has no keycode, so while ui.gd matched raw keycodes a controller player could
## walk and pause but never navigate, confirm or decline a level-up — unable to
## operate the build system the game is named for.

var failures := 0
var finished := {}

const CASES := ["every_referenced_action_exists", "tools_use_real_actions",
	"a_joypad_can_drive_the_overlay", "user_pause_gates_the_tick",
	"a_card_decline_does_not_release_a_player_pause", "cancel_routes_by_screen"]

func _initialize() -> void:
	print("ROOTKIT — input\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	every_referenced_action_exists()
	tools_use_real_actions()
	await a_joypad_can_drive_the_overlay()
	await user_pause_gates_the_tick()
	await a_card_decline_does_not_release_a_player_pause()
	await cancel_routes_by_screen()
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

func _ui(r: Node2D) -> CanvasLayer:
	for c in r.get_children():
		if c is CanvasLayer and c.has_method("bind"):
			return c
	return null

func _fresh_run() -> Node2D:
	SaveGame.use_fresh_state()
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(r)
	await process_frame
	r.input_override = Vector2.ZERO
	return r

## Named without a binding, Input.get_vector returns zero forever — keyboard
## movement silently stops working and no gamepad support is delivered.
func every_referenced_action_exists() -> void:
	for a in ["move_left", "move_right", "move_up", "move_down",
			"confirm", "cancel", "pause", "recipes", "restart"]:
		_check("action '%s' is in the map" % a, InputMap.has_action(a), true)
		_check("and '%s' has bindings" % a,
			InputMap.action_get_events(a).size() > 0, true)
	finished["every_referenced_action_exists"] = true

## tools/shot_cards.gd drives ui._input directly and is NOT in SUITES, so the
## keycode->action migration could have broken it with nothing reporting it.
func tools_use_real_actions() -> void:
	var f := FileAccess.open("res://tools/shot_cards.gd", FileAccess.READ)
	_check("the screenshot tool is readable", f != null, true)
	if f == null:
		finished["tools_use_real_actions"] = true
		return
	var txt := f.get_as_text()
	f.close()
	_check("it no longer synthesizes raw keycodes",
		txt.contains("e.keycode ="), false)
	var re := RegEx.new()
	re.compile("_act\\(\"([a-z_]+)\"\\)")
	var seen := 0
	for m in re.search_all(txt):
		seen += 1
		_check("tool action '%s' exists" % m.get_string(1),
			InputMap.has_action(m.get_string(1)), true)
	_check("and it drives at least one action", seen > 0, true)
	finished["tools_use_real_actions"] = true

## The migration's whole reason for existing.
func a_joypad_can_drive_the_overlay() -> void:
	var r := await _fresh_run()
	var ui := _ui(r)
	r.pending_levels += 1
	r._offer_cards()
	await process_frame
	_check("the overlay is up", ui._overlay.visible, true)
	var before: String = ui.highlighted().text

	# A real joypad button, not a synthesized action: this is what a controller
	# actually sends, and it carries no keycode at all.
	var e := InputEventJoypadButton.new()
	e.button_index = JOY_BUTTON_DPAD_DOWN
	e.pressed = true
	ui._input(e)
	_check("a D-pad press moves the highlight",
		ui.highlighted().text != before, true)
	r.free()
	await process_frame
	finished["a_joypad_can_drive_the_overlay"] = true

func user_pause_gates_the_tick() -> void:
	var r := await _fresh_run()
	r.user_paused = true
	var before: float = r.director.elapsed
	r._physics_process(1.0 / 60.0)
	_check("a player pause stops the simulation", r.director.elapsed, before)
	r.user_paused = false
	r._physics_process(1.0 / 60.0)
	_check("and resuming starts it again", r.director.elapsed > before, true)
	r.free()
	await process_frame
	finished["user_pause_gates_the_tick"] = true

## `paused` is the modal-offer flag and FOUR sites clear it unconditionally. If
## player pause shared it, declining a card would release a pause it never took
## — and ui.gd's `not run.paused` force-hide would then strand a pending fusion.
func a_card_decline_does_not_release_a_player_pause() -> void:
	var r := await _fresh_run()
	r.user_paused = true
	r.pending_levels += 1
	r._offer_cards()
	_check("the offer set the modal flag", r.paused, true)
	r.decline_card()
	_check("the decline cleared the modal flag", r.paused, false)
	_check("but the player pause survived it", r.user_paused, true)
	r.free()
	await process_frame
	finished["a_card_decline_does_not_release_a_player_pause"] = true

## Five arms, because the recipe panel is a CHILD of the overlay and the end
## screen is a SIBLING of it.
func cancel_routes_by_screen() -> void:
	var r := await _fresh_run()
	var ui := _ui(r)
	r.pending_levels += 1
	r._offer_cards()
	await process_frame

	ui._toggle_recipes()
	_check("the recipe panel is open", ui._recipes.visible, true)
	ui._route_cancel()
	_check("cancel closes the recipe panel first", ui._recipes.visible, false)
	_check("and leaves the card offer standing", ui._overlay.visible, true)

	ui._route_cancel()
	_check("a second cancel declines the card", r.paused, false)

	ui._route_cancel()
	_check("and with nothing up, cancel pauses", r.user_paused, true)
	ui._route_cancel()
	_check("cancel again resumes", r.user_paused, false)
	r.free()
	await process_frame
	finished["cancel_routes_by_screen"] = true
