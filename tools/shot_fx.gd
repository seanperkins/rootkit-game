extends SceneTree

## One frame with every fire shape in it: a three-slot session, each slot on
## a different pair of vectors, spread along +X, each ringed by tough enemies.
## Run windowed: godot -s res://tools/shot_fx.gd  ->  /tmp/rootkit_fx.png

var run: Node2D
var frames := 0
const SLOTS := 3
const ROWS := [[&"packet", &"broadcast", &"chain"], [&"beam", &"spike", &"bounce"],
	[&"landmine", &"mirror"]]

func _initialize() -> void:
	# --headless is the DUMMY renderer: root.get_texture() is null, save_png
	# throws, and the SCRIPT ERROR skips the `return true` that would quit — so
	# the tool spins forever with no output. Fail here, loudly, instead.
	if DisplayServer.get_name() == "headless":
		push_error("shot tools need a window — run without --headless")
		quit(1)
		return
	SaveGame.use_test_paths()
	var rows := []
	for s in SLOTS:
		rows.append({"slot": s, "name": "p%d" % s,
			"counters": SaveGame.session_counters()})
	var desc := NetworkSession.validate_descriptor({
		"protocol": SessionRules.PROTOCOL, "session_id": 1, "seed": 20260830,
		"delay": 0, "choice_timeout": 0, "roster": rows})
	run = load("res://scenes/run.tscn").instantiate()
	run.configure_session(NetworkSession.create(desc, 0, NetworkSession.Role.HOST))
	root.add_child(run)

func _process(_d: float) -> bool:
	frames += 1
	if run == null or run.loadouts[run.local_slot] == null: return false
	if frames == 10:
		var t := ModuleTable.by_id()
		for s in SLOTS:
			var lo: Loadout = run.loadouts[s]
			lo.exploits = []
			for vid in ROWS[s]:
				var ex := Exploit.new()
				ex.place(t[vid])
				ex.place(t[&"interval"])
				ex.vector.rank = 3
				lo.exploits.append(ex)
			# Spread the party along +X so each slot's shapes have their own
			# ground; the render positions follow so the first frame agrees.
			var p: Vector2 = run.player_pos[0] + Vector2(260.0 * float(s), 0.0)
			run.player_pos[s] = p
			run.player_prev_pos[s] = p
			run.player_render_pos[s] = p
		run._recompile()
		run.director.boss_spawned = true
	if frames > 10:
		# Lockstep waits on every LIVE slot's record; the two remote slots
		# submit neutral movement every frame, as the perf gate's do.
		for s in range(1, SLOTS):
			run.lockstep.submit(s, run.lockstep.executed, Vector2.ZERO, -1, -1, -1)
	if frames > 12:
		run.input_override = Vector2.ZERO
		# A ring of tough enemies around every slot so the shots have targets
		# and persist across the frame.
		while run.enemies.count < 26 * SLOTS:
			var k: int = run.enemies.count
			var s: int = k / 26
			var a: float = TAU * float(k % 26) / 26.0
			var d: float = 90.0 + 40.0 * (k % 3)
			run.enemies.spawn(run.player_pos[s] + Vector2(cos(a), sin(a)) * d,
				Vector2.ZERO, 9999.0, run.ENEMY_RADIUS, k % 3)
	# catch a frame where something has just fired
	if frames > 60 and run._fx.size() > 0:
		root.get_texture().get_image().save_png("/tmp/rootkit_fx.png")
		print("fx=%d" % run._fx.size())
		return true
	if frames > 400:
		print("no fx captured")
		return true
	return false
