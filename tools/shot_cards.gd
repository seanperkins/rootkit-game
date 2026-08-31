extends SceneTree

## The level-up overlay under keyboard control: where the highlight starts, and
## where two moves put it. A test can assert which button is selected; only a
## picture says whether you can SEE which one.

var run: Node2D
var ui: CanvasLayer
var frames := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	run = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)

func _key(code: int) -> void:
	var e := InputEventKey.new()
	e.keycode = code
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
		run._offer_cards()
	if frames == 40:
		root.get_texture().get_image().save_png("/tmp/cards_1_start.png")
		_key(KEY_RIGHT)
		_key(KEY_DOWN)
	if frames == 60:
		root.get_texture().get_image().save_png("/tmp/cards_2_moved.png")
		# Down until decline, rather than a guessed count: the cycle is as long
		# as the card has legal rows, and guessing wrapped straight past it.
		var guard := 0
		while not ("decline" in ui.highlighted().text) and guard < 12:
			_key(KEY_DOWN)
			guard += 1
	if frames == 80:
		root.get_texture().get_image().save_png("/tmp/cards_3_decline.png")
		print("highlighted: %s" % ui.highlighted().text)
		return true
	return false
