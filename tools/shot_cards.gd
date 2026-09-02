extends SceneTree

## The level-up overlay under keyboard control: where the highlight starts, and
## where two moves put it. A test can assert which button is selected; only a
## picture says whether you can SEE which one.

var run: Node2D
var ui: CanvasLayer
var frames := 0

func _initialize() -> void:
	# --headless is the DUMMY renderer: root.get_texture() is null, save_png
	# throws, and the SCRIPT ERROR skips the `return true` that would quit — so
	# the tool spins forever with no output. Fail here, loudly, instead.
	if DisplayServer.get_name() == "headless":
		push_error("shot tools need a window — run without --headless")
		quit(1)
		return
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	run = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)

## Drives the overlay through ACTIONS, matching ui.gd. This tool is not in
## SUITES, so nothing else would have caught the keycode->action migration
## breaking it — it would have kept writing PNGs showing the wrong selection.
func _act(action: String) -> void:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	ui._input(e)

func _process(_d: float) -> bool:
	frames += 1
	if run == null or run.terrain == null:
		return false
	if frames == 20:
		for c in run.get_children():
			if c is CanvasLayer and c.has_method("bind"):
				ui = c
		run.pending_levels += 1
		run._offer_cards(run.local_slot)
	if frames == 40:
		root.get_texture().get_image().save_png("/tmp/cards_1_start.png")
		_act("move_right")
		_act("move_down")
	if frames == 60:
		root.get_texture().get_image().save_png("/tmp/cards_2_moved.png")
		# Down until decline, rather than a guessed count: the cycle is as long
		# as the card has legal rows, and guessing wrapped straight past it.
		var guard := 0
		while not ("decline" in ui.highlighted().text) and guard < 12:
			_act("move_down")
			guard += 1
	if frames == 80:
		root.get_texture().get_image().save_png("/tmp/cards_3_decline.png")
		print("highlighted: %s" % ui.highlighted().text)
		return true
	return false
