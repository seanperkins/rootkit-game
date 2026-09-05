extends "res://tools/fps_probe.gd"

## Compare the new floor against the parent revision IN THE SAME live run.
## Put the old backdrop.gd at res://.tmp/backdrop_baseline.gd first, then:
## godot -s res://tools/fps_world_visuals.gd -- ab_baseline_fullscreen
## The inherited report's "with" is new; "without" is the original floor.
## Append _memory to exercise the densest pattern in the same combat arena.
## ab_props_fullscreen compares new walls + panels against .tmp/props_baseline.gd;
## the accepted circuit floor remains visible in both halves.
## Add _panels to keep three large effect panels visible as a render stress.
var _baseline: Node2D
var _fullscreen_set := false
var _layer_name := "Backdrop"

func _initialize() -> void:
	var baseline_path := "res://.tmp/backdrop_baseline.gd"
	for arg in OS.get_cmdline_user_args():
		if arg.contains("props"):
			_layer_name = "Props"
			baseline_path = "res://.tmp/props_baseline.gd"
	if not FileAccess.file_exists(baseline_path):
		printerr("Copy the parent revision's renderer to ", baseline_path, " first.")
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
	_baseline.set_script(load(baseline_path))
	_baseline.z_index = run.get_node(_layer_name).z_index
	run.add_child(_baseline)
	_baseline.set("target", run)
	_baseline.hide()
	_baseline.set_process(false)
	if cfg.contains("panels"):
		var panels := run.get_node("ZonePanels")
		panels._process(0.0)
		# Presentation-only rectangles: no terrain, collision, or damage edits.
		panels._zones = [
			[0, Rect2(-360, -160, 224, 192), Terrain.Kind.HAZARD],
			[0, Rect2(-112, -160, 224, 192), Terrain.Kind.SLOW],
			[0, Rect2(136, -160, 224, 192), Terrain.Kind.CORRUPTION]]
		print("Render stress: three large effect panels kept in view; simulation unchanged.")
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

func _process(delta: float) -> bool:
	if run != null and cfg.contains("panels"):
		run.get_node("ZonePanels").position = run.to_iso(run.player_pos[run.view_slot])
	return super._process(delta)

func _apply(c: String) -> void:
	# Setting fullscreen on every A/B flip can reconfigure presentation pacing
	# on Metal. Set it once, then uncap AFTER that mode change as well.
	super._apply(c.replace("fullscreen", ""))
	if c.contains("fullscreen") and not _fullscreen_set:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		_fullscreen_set = true
	if (c.contains("baseline") or c.contains("props")) and _baseline != null:
		var backdrop := run.get_node(_layer_name)
		backdrop.hide()
		backdrop.set_process(false)
		_baseline.show()
		_baseline.set_process(true)
		if _layer_name == "Props":
			run.get_node("ZonePanels").hide()
			run.get_node("ZonePanels").set_process(false)

func _unapply(c: String) -> void:
	super._unapply(c)
	if (c.contains("baseline") or c.contains("props")) and _baseline != null:
		var backdrop := run.get_node(_layer_name)
		backdrop.show()
		backdrop.set_process(true)
		_baseline.hide()
		_baseline.set_process(false)
		if _layer_name == "Props":
			run.get_node("ZonePanels").show()
			run.get_node("ZonePanels").set_process(true)
