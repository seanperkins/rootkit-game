extends "res://tools/fps_probe.gd"

## Compare the new floor against the parent revision IN THE SAME live run.
## Put the old backdrop.gd at res://.tmp/backdrop_baseline.gd first, then:
## godot -s res://tools/fps_world_visuals.gd -- ab_baseline_fullscreen
## The inherited report's "with" is new; "without" is the original floor.
## Append _memory to exercise the densest pattern in the same combat arena.
var _baseline: Node2D
var _fullscreen_set := false

func _initialize() -> void:
	if not FileAccess.file_exists("res://.tmp/backdrop_baseline.gd"):
		printerr("Copy the parent revision's backdrop.gd to .tmp/backdrop_baseline.gd first.")
		quit(1)
		return
	await super._initialize()
	if run == null:
		return
	var worlds := 0
	for child in root.get_children():
		if child.get_script() == run.get_script():
			worlds += 1
	if worlds != 1:
		printerr("Invalid benchmark: expected one world, found ", worlds)
		quit(1)
		return
	_baseline = Node2D.new()
	_baseline.set_script(load("res://.tmp/backdrop_baseline.gd"))
	_baseline.z_index = -10
	run.add_child(_baseline)
	_baseline.set("target", run)
	_baseline.hide()
	_baseline.set_process(false)
	if cfg.contains("memory"):
		var backdrop := run.get_node("Backdrop")
		backdrop._process(0.0)
		for i in backdrop.get_child_count():
			for patch in backdrop.get_child(i).get_children():
				for connection in patch.get_signal_connection_list("draw"):
					var callback: Callable = connection["callable"]
					var args := callback.get_bound_arguments()
					patch.disconnect("draw", callback)
					patch.draw.connect(backdrop._draw_circuits.bind(patch, args[1], 1, args[3]))
				patch.queue_redraw()

func _apply(c: String) -> void:
	# Setting fullscreen on every A/B flip can reconfigure presentation pacing
	# on Metal. Set it once, then uncap AFTER that mode change as well.
	super._apply(c.replace("fullscreen", ""))
	if c.contains("fullscreen") and not _fullscreen_set:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		_fullscreen_set = true
	if c.contains("baseline") and _baseline != null:
		var backdrop := run.get_node("Backdrop")
		backdrop.hide()
		backdrop.set_process(false)
		_baseline.show()
		_baseline.set_process(true)

func _unapply(c: String) -> void:
	super._unapply(c)
	if c.contains("baseline") and _baseline != null:
		var backdrop := run.get_node("Backdrop")
		backdrop.show()
		backdrop.set_process(true)
		_baseline.hide()
		_baseline.set_process(false)
