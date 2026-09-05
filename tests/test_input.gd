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
	"a_card_decline_does_not_release_a_player_pause", "cancel_routes_by_screen",
	"the_sim_reads_inputs_not_the_device", "input_override_feeds_slot_zero",
	"the_device_is_polled_in_one_place", "confirm_cycles_spectate_targets",
	"the_right_stick_aims", "the_mouse_aims_while_recently_moved",
	"a_joypad_selects_and_cancels_starting_programs"]

const DT := 1.0 / 60.0

func _initialize() -> void:
	print("ROOTKIT — input\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	every_referenced_action_exists()
	tools_use_real_actions()
	await a_joypad_selects_and_cancels_starting_programs()
	await a_joypad_can_drive_the_overlay()
	await user_pause_gates_the_tick()
	await a_card_decline_does_not_release_a_player_pause()
	await cancel_routes_by_screen()
	await the_sim_reads_inputs_not_the_device()
	await input_override_feeds_slot_zero()
	the_device_is_polled_in_one_place()
	await confirm_cycles_spectate_targets()
	await the_right_stick_aims()
	await the_mouse_aims_while_recently_moved()
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
			"aim_left", "aim_right", "aim_up", "aim_down",
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

## Native popup controls must receive real controller events, not a manually
## emitted Button.pressed signal. The latter cannot open an OptionButton.
func a_joypad_selects_and_cancels_starting_programs() -> void:
	var main: Control = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 8:
		await process_frame
	var chooser: OptionButton = main._program_select
	chooser.grab_focus()
	await _joy_button(JOY_BUTTON_A)
	var popup := chooser.get_popup()
	_check("controller confirm opens the program chooser", popup.visible, true)
	if popup.visible:
		await _joy_button(JOY_BUTTON_DPAD_DOWN)
		await _joy_button(JOY_BUTTON_A)
		_check("controller selection changes the starting program",
			SaveGame.string_pref("program"), "ghost")
		await _joy_button(JOY_BUTTON_A)
		await _joy_button(JOY_BUTTON_DPAD_DOWN)
		await _joy_button(JOY_BUTTON_B)
		_check("controller cancel closes the chooser", popup.visible, false)
		_check("cancel preserves the selected program",
			SaveGame.string_pref("program"), "ghost")
	main.free()
	await process_frame
	SaveGame.use_fresh_state()
	finished["a_joypad_selects_and_cancels_starting_programs"] = true

func _joy_button(button: JoyButton) -> void:
	for down in [true, false]:
		var event := InputEventJoypadButton.new()
		event.button_index = button
		event.pressed = down
		# PopupMenu is a Window: Viewport.push_input bypasses its window input
		# signal. Use the engine's device-event entry point for both windows.
		Input.parse_input_event(event)
		await process_frame

## The migration's whole reason for existing.
func a_joypad_can_drive_the_overlay() -> void:
	var r := await _fresh_run()
	var ui := _ui(r)
	r._offer_cards(r.local_slot)
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
	r._offer_cards(r.local_slot)
	_check("the offer set the modal flag", r.paused, true)
	r.decline_card()
	for k in 4:
		if r._local_choice.x == -1:
			break
		r._physics_process(1.0 / 60.0)
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
	r._offer_cards(r.local_slot)
	await process_frame

	ui._toggle_recipes()
	_check("the recipe panel is open", ui._recipes.visible, true)
	ui._route_cancel()
	_check("cancel closes the recipe panel first", ui._recipes.visible, false)
	_check("and leaves the card offer standing", ui._overlay.visible, true)

	ui._route_cancel()
	for k in 4:
		if r._local_choice.x == -1:
			break
		r._physics_process(1.0 / 60.0)
	_check("a second cancel declines the card", r.paused, false)

	ui._route_cancel()
	_check("and with nothing up, cancel pauses", r.user_paused, true)
	ui._route_cancel()
	_check("cancel again resumes", r.user_paused, false)
	r.free()
	await process_frame
	finished["cancel_routes_by_screen"] = true


## The seam a networked client drives. The tick moves the player from
## `inputs[LOCAL_SLOT]` and from nothing else — no InputMap action is pressed
## here and input_override is unset, so if the player moves, the array is the
## only place the direction could have come from.
func the_sim_reads_inputs_not_the_device() -> void:
	var r := await _fresh_run()
	r.input_override = null
	r.phase = r.Phase.FIGHTING
	var before: Vector2 = r.player_pos[r.local_slot]
	r.inputs[r.local_slot] = Vector2.ZERO
	r._step2_integrate(DT)
	_check("zero input: the player stays put", r.player_pos[r.local_slot], before)
	r.inputs[r.local_slot] = Vector2(1, 0)
	r._step2_integrate(DT)
	_check("world +x input: the player moved +x", r.player_pos[r.local_slot].x > before.x, true)
	_check("and only along x", absf(r.player_pos[r.local_slot].y - before.y) < 0.001, true)
	r.queue_free()
	finished["the_sim_reads_inputs_not_the_device"] = true

## input_override is how every headless driver in this repo steers. It must keep
## its exact meaning — a WORLD direction — and land in slot 0 through the same
## poll a real device does, so the suites and the perf gate exercise the seam
## rather than a side door around it.
func input_override_feeds_slot_zero() -> void:
	var r := await _fresh_run()
	r.input_override = Vector2(0, 3)
	r._poll_local_input()
	_check("override lands in slot 0, normalised",
		r.inputs[r.local_slot], Vector2(0, 1))
	r.input_override = null
	r._poll_local_input()
	_check("no override and no device: slot 0 is zero",
		r.inputs[r.local_slot], Vector2.ZERO)
	r.queue_free()
	finished["input_override_feeds_slot_zero"] = true

## Structural: the device is read in exactly one function, above the tick
## guard. A second Input.* call anywhere in the simulation would be a second
## source of truth a remote player has no way to feed.
func the_device_is_polled_in_one_place() -> void:
	var f := FileAccess.open("res://scripts/run/run.gd", FileAccess.READ)
	var body := f.get_as_text()
	f.close()
	var current := ""
	var offenders := []
	var polls := 0
	for line in body.split("\n"):
		if line.begins_with("func "):
			current = line.substr(5, line.find("(") - 5)
		var code := line.strip_edges()
		if code.begins_with("#"):
			continue
		if "Input." in code:
			polls += 1
			if current != "_poll_local_input":
				offenders.append(current)
	_check("run.gd reads the device somewhere", polls > 0, true)
	_check("and only inside _poll_local_input (offenders: %s)" % [offenders],
		offenders.is_empty(), true)
	finished["the_device_is_polled_in_one_place"] = true

func _confirm() -> InputEventAction:
	var e := InputEventAction.new()
	e.action = "confirm"
	e.pressed = true
	return e

## Confirm belongs to the card overlay while one is up; otherwise a spectator
## cycles LIVE targets with it, and a LIVE player gets nothing from it.
func confirm_cycles_spectate_targets() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 3, 0, 20260830)
	var r: Node2D = h.runs[0]
	var ui := _ui(r)
	_check("a LIVE slot has nothing to cycle", r.cycle_spectate(), false)
	r._die(0)
	r._refresh_view()
	_check("dead, the view starts on the next LIVE slot", r.view_slot, 1)
	ui._input(_confirm())
	_check("confirm cycles to the next", r.view_slot, 2)
	ui._input(_confirm())
	_check("and wraps, skipping the dead local slot", r.view_slot, 1)
	r._die(2)
	_check("with one LIVE slot left there is nowhere to cycle", r.cycle_spectate(), false)
	h.teardown()
	await process_frame
	finished["confirm_cycles_spectate_targets"] = true

## The right stick aims through four actions read by ONE get_vector in the
## poll, unprojected like movement so a stick pushed up on screen aims up on
## screen. Input.action_press is the engine's own device simulation.
func the_right_stick_aims() -> void:
	var r := await _fresh_run()
	r.input_override = Vector2.ZERO
	r.aim_override = null
	Input.action_press("aim_up", 1.0)
	r._poll_local_input()
	var want: Vector2 = r.from_iso(Vector2(0.0, -1.0)).normalized()
	_check("a stick pushed up aims up the screen", r.aims[r.local_slot].dot(want) > 0.999, true)
	Input.action_release("aim_up")
	r._poll_local_input()
	_check("a centred stick aims nowhere", r.aims[r.local_slot], Vector2.ZERO)
	r.queue_free()
	await process_frame
	finished["the_right_stick_aims"] = true

## The mouse aims for MOUSE_AIM_HOLD seconds after it last moved, at the
## cursor's world position relative to the local slot; then movement facing
## takes over again.
func the_mouse_aims_while_recently_moved() -> void:
	var r := await _fresh_run()
	r.input_override = Vector2.ZERO
	r.aim_override = null
	var e := InputEventMouseMotion.new()
	e.position = Vector2(10.0, 10.0)
	r._unhandled_input(e)
	_check("a motion event arms the mouse aim", r._mouse_aim_left, r.MOUSE_AIM_HOLD)
	r._mouse_iso = r.to_iso(r.player_render_pos[r.local_slot] + Vector2(0.0, -100.0))
	r._poll_local_input()
	_check("the aim points from the player to the cursor", r.aims[r.local_slot].dot(Vector2(0.0, -1.0)) > 0.999, true)
	r._mouse_aim_left = 0.0
	r._poll_local_input()
	_check("an idle mouse aims nowhere", r.aims[r.local_slot], Vector2.ZERO)
	r.queue_free()
	await process_frame
	finished["the_mouse_aims_while_recently_moved"] = true
