extends SceneTree
var run: Node2D
var frames := 0
var shown := false
func _initialize() -> void:
	SaveGame.use_test_paths()
	run = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
func _process(_d: float) -> bool:
	frames += 1
	if run == null or run.loadout == null:
		return false
	if frames == 30:
		# a partially built board so the slot states are all visible at once
		var t := ModuleTable.by_id()
		run.loadout.place_at(t[&"corrupt"], 0, 2)
		run.loadout.exploits[0].payloads[0].rank = 3
		run.loadout.place_at(t[&"broadcast"], 1, 0)
		run.loadout.place_at(t[&"on_hit"], 1, 1)
		run.loadout.place_at(t[&"keylog"], 1, 2)
		run._recompile()
	if frames == 60 and not shown:
		shown = true
		run.paused = true
		var ui: CanvasLayer = run.get_children().filter(func(c): return c is CanvasLayer)[0]
		var m: Module = ModuleTable.by_id()[&"buffer_overflow"]
		ui._cards_data = [[m, run.loadout.legal_targets(m)]]
		ui._overlay.visible = true
		ui._show_slots(m, run.loadout.legal_targets(m))
	if frames == 75:
		root.get_texture().get_image().save_png("/tmp/rootkit_slots.png")
		return true
	return false
