extends SceneTree
var run: Node2D
var frames := 0
var shown := false
func _initialize() -> void:
	# --headless is the DUMMY renderer: root.get_texture() is null, save_png
	# throws, and the SCRIPT ERROR skips the `return true` that would quit — so
	# the tool spins forever with no output. Fail here, loudly, instead.
	if DisplayServer.get_name() == "headless":
		push_error("shot tools need a window — run without --headless")
		quit(1)
		return
	SaveGame.use_test_paths()
	run = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
func _process(_d: float) -> bool:
	frames += 1
	if run == null or run.loadouts[run.local_slot] == null:
		return false
	if frames == 30:
		# A half-built board, so one screen shows every button state at once:
		# exploit_01 is full, exploit_02 has an empty payload column, and
		# exploit_03 is not founded yet.
		var t := ModuleTable.by_id()
		run.loadouts[run.local_slot].place_at(t[&"corrupt"], 0, 2)
		run.loadouts[run.local_slot].exploits[0].payloads[0].rank = 3
		run.loadouts[run.local_slot].place_at(t[&"broadcast"], 1, 0)
		run.loadouts[run.local_slot].place_at(t[&"on_hit"], 1, 1)
		run._recompile()
	if frames == 60 and not shown:
		shown = true
		run.paused = true
		var ui: CanvasLayer = run.get_children().filter(func(c): return c is CanvasLayer)[0]
		var t := ModuleTable.by_id()
		var cards := []
		for id in [&"corrupt", &"buffer_overflow", &"interval"]:
			cards.append([t[id], run.loadouts[run.local_slot].legal_targets(t[id])])
		ui._cards_data = cards
		ui._show_cards()
		ui._overlay.visible = true
	if frames == 75:
		root.get_texture().get_image().save_png("/tmp/rootkit_slots.png")
		return true
	return false
