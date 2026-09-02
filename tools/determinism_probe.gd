extends SceneTree

## The cross-architecture determinism probe.
##
## One run on a fixed four-slot descriptor, the field held at the 600-enemy
## cap with the perf gate's worst-case loadouts on every slot, driven by a
## deterministic autopilot for PROBE_TICKS ticks; prints `tick hash` from the
## full state manifest every tick. Run it on arm64 and on x86_64 and diff the
## output: lockstep rests on the two being byte-identical, and this is the
## artefact that claim is reproduced from.
##
##   godot --headless -s res://tools/determinism_probe.gd > arm64.txt
##   godot-x86_64 --headless -s res://tools/determinism_probe.gd > x86_64.txt
##   diff arm64.txt x86_64.txt && echo identical
##
## Pass `--ticks N` after `--` to change the length.

const DT := 1.0 / 60.0
const SEED := 20260830
const PROBE_TICKS := 1800
const PARTY_OFFSETS := [Vector2.ZERO, Vector2(4000.0, 0.0),
	Vector2(0.0, 4000.0), Vector2(4000.0, 4000.0)]

var run: Node2D

func _initialize() -> void:
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	var ticks := PROBE_TICKS
	var args := OS.get_cmdline_user_args()
	for k in args.size():
		if args[k] == "--ticks" and k + 1 < args.size():
			ticks = maxi(1, int(args[k + 1]))
	run = await _party_run()
	_arm_loadouts()
	run.director.elapsed = 999.0
	run.director.boss_spawned = true
	print("# determinism probe  seed=%d  slots=%d  ticks=%d  manifest=%d fields" % [
		SEED, SessionRules.MAX_PLAYERS, ticks, run.STATE_FIELDS.size()])
	for t in ticks:
		_fill()
		_drive(t)
		run._physics_process(DT)
		print("%d %d" % [run.tick, run._state_hash()])
	quit(0)

func _party_run() -> Node2D:
	var rows := []
	for s in SessionRules.MAX_PLAYERS:
		rows.append({"slot": s, "name": "p%d" % s,
			"counters": SaveGame.session_counters()})
	var desc := NetworkSession.validate_descriptor({
		"protocol": SessionRules.PROTOCOL, "session_id": 1, "seed": SEED,
		"delay": 0, "choice_timeout": 0, "roster": rows})
	var g: Node2D = load("res://scenes/run.tscn").instantiate()
	g.configure_session(NetworkSession.create(desc, 0, NetworkSession.Role.HOST))
	g.external_drive = true
	g.input_override = Vector2.ZERO
	root.add_child(g)
	await process_frame
	return g

## The perf gate's worst-case build on every slot, so the heaviest fire paths
## — and the widest float surface — are all exercised.
func _arm_loadouts() -> void:
	var tbl := ModuleTable.by_id()
	for s in SessionRules.MAX_PLAYERS:
		var lo: Loadout = run.loadouts[s]
		lo.exploits[0].vector.rank = 5
		var ex2 := Exploit.new()
		ex2.place(tbl[&"broadcast"])
		ex2.place(tbl[&"on_hit"])
		ex2.vector.rank = 5
		lo.exploits.append(ex2)
		var homer := Module.make(&"probe_homer", "probe_homer()", Module.Slot.VECTOR,
			{&"damage": 20.0, &"projectile_speed": 700.0, &"cooldown": 0.45,
			 &"travel": 1200.0, &"pierce": 4.0, &"homing": 2.6}, [],
			Module.VectorKind.PACKET, Module.TriggerKind.INTERVAL)
		homer.is_fused = true
		homer.targeting = Module.Targeting.STRONGEST
		var ex3 := Exploit.new()
		ex3.vector = EquippedModule.new(homer, 5)
		lo.exploits.append(ex3)
		run.player_pos[s] = run.player_pos[0] + PARTY_OFFSETS[s]
		run.player_prev_pos[s] = run.player_pos[s]
	run._recompile()

## Top the field up to the enemy cap around the party, deterministically:
## spawn positions come from the run's own seeded stream.
func _fill() -> void:
	var types: int = run.enemy_types.size() - 1      # never ICE
	var k: int = run.enemies.count
	while run.enemies.count < run.MAX_ENEMIES:
		var ti: int = k % types
		var b = run.enemy_types[ti]
		var a := float(k) * 2.399963
		var slot := k % SessionRules.MAX_PLAYERS
		var at: Vector2 = run.player_pos[slot] + Vector2(cos(a), sin(a)) * (520.0 + float(k % 7) * 60.0)
		var i: int = run.enemies.spawn(run.terrain.nearest_open(at), Vector2.ZERO,
			b.integrity, 12.0, ti)
		if i < 0:
			break
		run._spawn_enemy_state(i, ti)
		k += 1

## Slot zero walks a slow circle; the pinned slots submit neutral records and
## answer every offer with its first card so no round ever holds the world.
func _drive(t: int) -> void:
	var a := float(t) * 0.01
	run.input_override = Vector2(cos(a), sin(a))
	for s in range(1, SessionRules.MAX_PLAYERS):
		var open: Dictionary = run._offer_open[s]
		var seq := int(open["seq"]) if not open.is_empty() else -1
		run.lockstep.submit(s, run.lockstep.executed, Vector2.ZERO,
			0 if seq >= 0 else -1, 0 if seq >= 0 else -1, seq)
	var mine: Dictionary = run._offer_open[0]
	if not mine.is_empty() and run._local_choice.x == -1:
		run._local_choice = Vector3i(0, 0, int(mine["seq"]))
