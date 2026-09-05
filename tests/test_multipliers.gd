extends SceneTree

## The wiring tests here instantiate a real run and read what _ready() compiled.
## They deliberately do NOT call Compiler.build directly.
##
## Loadout.compile_all is the only runtime caller of the compiler. A change that
## adds a parameter to Compiler.build without teaching loadout.gd about it
## compiles clean and leaves every direct-compiler test green, while three shop
## lines sell for up to 5,850 salvage and do nothing in an actual run. Three
## separate reviewers caught exactly that hole in the design; this file is the
## thing that would have caught it in code.

const DT := 1.0 / 60.0
var failures := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	print("ROOTKIT — global multipliers\n")
	await process_frame
	await attack_reaches_combat()
	await cooling_moves_the_player_not_the_gun()
	corruption_scales()
	exclusions_hold()
	no_global_touches_cadence()
	print("")
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want or (got is float and want is float and abs(got - want) < 1e-5):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _clear_buffs() -> void:
	for name in ["cpu_cycles", "cooling", "memory", "firewall",
			"encryption", "bus_speed", "addressing", "bandwidth"]:
		SaveGame.load_state()["buffs"][name] = 0

## Reads what a freshly-started run actually compiled, so the assertion covers
## run.gd's _ready, Loadout.mult and Compiler.build together.
func _starting_exploit() -> ResolvedExploit:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	var r: ResolvedExploit = run.resolved[0]
	run.queue_free()
	await process_frame
	return r

func attack_reaches_combat() -> void:
	_clear_buffs()
	var base: ResolvedExploit = await _starting_exploit()
	var base_damage: float = base.damage

	SaveGame.load_state()["buffs"]["cpu_cycles"] = 10
	var buffed: ResolvedExploit = await _starting_exploit()

	_check("attack x1.40 reaches the compiled exploit",
		buffed.damage, base_damage * 1.40)
	_clear_buffs()

## The line that used to buy fire rate. It still has to REACH the run — the
## whole point of this file — but it lands on the player sheet now, and the
## compiled weapon must not move at all.
func cooling_moves_the_player_not_the_gun() -> void:
	_clear_buffs()
	var base: ResolvedExploit = await _starting_exploit()
	var base_cd: float = base.cooldown

	SaveGame.load_state()["buffs"]["cooling"] = 10
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	var buffed: ResolvedExploit = run.resolved[0]
	var speed: float = run._sheet[run.local_slot][&"clock_speed"]
	run.queue_free()
	await process_frame

	_check("cooling no longer touches the weapon's cadence", buffed.cooldown, base_cd)
	_check("cooling r10 reaches the run as move speed", speed,
		float(PlayerStats.BASE[&"clock_speed"]) + 60.0)
	_clear_buffs()

## corruption is a damage type. If attack scaled only damage, the game's headline
## offensive stat would be dead weight to a corruption build — the same "legal to
## buy, silently inert" failure the bandwidth bug was.
func corruption_scales() -> void:
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"broadcast"]); ex.place(t[&"interval"]); ex.place(t[&"corrupt"])
	var base := Compiler.build(ex)
	var buffed := Compiler.build(ex, {&"attack": 2.0})
	_check("attack scales damage", buffed.damage, base.damage * 2.0)
	_check("attack scales corruption", buffed.corruption, base.corruption * 2.0)

## The exclusion list is an invariant, not a comment. A future refactor that
## looped over STAT_KEYS would silently scale projectile_speed past its cap.
func exclusions_hold() -> void:
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"packet"]); ex.place(t[&"interval"])
	ex.place(t[&"botnet_expand"]); ex.place(t[&"keylog"])
	var base := Compiler.build(ex)
	var buffed := Compiler.build(ex, {&"attack": 3.0, &"reach": 3.0})
	_check("pierce untouched", buffed.pierce, base.pierce)
	_check("chain_count untouched", buffed.chain_count, base.chain_count)
	_check("projectile_speed untouched", buffed.projectile_speed, base.projectile_speed)
	_check("botnet_cap untouched", buffed.botnet_cap, base.botnet_cap)
	_check("lifesteal untouched", buffed.lifesteal, base.lifesteal)

## Cadence belongs to the TRIGGER column, so no global may reach it. haste is
## gone from MULT_KEYS entirely; this is what catches it coming back, under
## that name or another, and it pins where the cost of holding no trigger is
## paid instead.
func no_global_touches_cadence() -> void:
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"packet"]); ex.place(t[&"interval"])
	var base := Compiler.build(ex)
	_check("mid-range cooldown is above the clamp",
		base.cooldown > Compiler.MIN_COOLDOWN, true)
	# haste passed deliberately: a stale save or a re-added shop line must be
	# inert here, not quietly effective again.
	var buffed := Compiler.build(ex, {&"attack": 3.0, &"reach": 3.0, &"haste": 0.5})
	_check("no multiplier moves the cadence", buffed.cooldown, base.cooldown)
	var bare := Exploit.new()
	bare.place(t[&"packet"])
	_check("the bare row pays the cadence penalty instead",
		Compiler.build(bare).cooldown,
		float(t[&"packet"].stats[&"cooldown"]) * Compiler.BARE_CADENCE)
