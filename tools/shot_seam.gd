extends SceneTree

## Four frames of the campaign map, for eyeballing the things a test cannot:
## the player glyph, the lattice at an arena edge, and the seam where a corridor
## meets the next subnet.

var run: Node2D
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

func _process(_d: float) -> bool:
	frames += 1
	if run == null or run.terrain == null:
		return false
	var g = run.terrain.gate()
	match frames:
		20:
			run.player_pos = Vector2.ZERO
		40:
			_save("/tmp/seam_1_start.png")
			# The near corner of the arena, where the lattice meets the wall.
			var a: Rect2 = run.terrain.arena()
			run.player_pos = a.end - Vector2(240, 240)
		60:
			_save("/tmp/seam_2_corner.png")
			run.phase = run.Phase.CLEARED
			run.collapse_left = run.COLLAPSE_SECONDS
			run.terrain.open_gate()
			run.terrain.build_distance_field()
			run.player_pos = g.pos - g.dir * 260.0
		80:
			_save("/tmp/seam_3_gate.png")
			# Standing in the doorway of the NEXT arena, looking back down the
			# corridor: this is the join the whole rework is about.
			run.player_pos = g.end + g.dir * 120.0
		100:
			_save("/tmp/seam_4_arrival.png")
			print("layout %s" % [run.terrain.arenas])
			print("gate0 pos %s dir %s end %s  arena1 %s" % [
				run.terrain.gates[0].pos, run.terrain.gates[0].dir,
				run.terrain.gates[0].end, run.terrain.arenas[1]])
			print("grid %dx%d cells, origin %s" % [
				run.terrain.w, run.terrain.h, run.terrain.origin])
			return true
	return false

func _save(path: String) -> void:
	root.get_texture().get_image().save_png(path)
