extends SceneTree

## Shop economics, buff folding, unlocks, and the save-durability rules the
## review called out: atomic rotation, .bak recovery, and range clamping on a
## file the player can hand-edit.

var failures := 0

func _initialize() -> void:
	print("ROOTKIT — meta / save\n")
	price_curve()
	buying()
	buffs_fold_into_compile()
	unlocks()
	clamping()
	bak_recovery()
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

func price_curve() -> void:
	_check("first purchase costs 60", SaveGame.buff_price(0), 60)
	_check("tenth purchase costs 330", SaveGame.buff_price(9), 330)
	var total := 0
	for n in SaveGame.BUFF_MAX:
		total += SaveGame.buff_price(n)
	_check("maxing one line costs 1950", total, 1950)
	_check("all three lines cost 5850", total * 3, 5850)

func buying() -> void:
	SaveGame.use_fresh_state()
	_check("broke: purchase refused", SaveGame.buy(&"cpu_cycles"), false)
	SaveGame.load_state()["salvage"] = 200
	_check("afforded: purchase accepted", SaveGame.buy(&"cpu_cycles"), true)
	_check("salvage debited by the price", SaveGame.load_state()["salvage"], 140)
	_check("rank incremented", SaveGame.load_state()["buffs"]["cpu_cycles"], 1)
	_check("next price stepped up", SaveGame.buff_price(1), 90)
	SaveGame.load_state()["buffs"]["cooling"] = SaveGame.BUFF_MAX
	_check("maxed line refuses further purchase", SaveGame.buy(&"cooling"), false)

## A buff that does not reach ResolvedExploit is a buff that does nothing.
func buffs_fold_into_compile() -> void:
	SaveGame.use_fresh_state()
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"packet"])
	ex.place(t[&"interval"])
	var base := Compiler.build(ex, {})
	SaveGame.load_state()["buffs"]["cpu_cycles"] = 4
	var buffed := Compiler.build(ex, SaveGame.buff_stats())
	_check("4 ranks of +CPU cycles add 6.0 damage", buffed.damage - base.damage, 6.0)
	SaveGame.load_state()["buffs"]["cooling"] = 10
	var cooled := Compiler.build(ex, SaveGame.buff_stats())
	_check("cooling never breaches MIN_COOLDOWN",
		cooled.cooldown >= Compiler.MIN_COOLDOWN, true)

func unlocks() -> void:
	SaveGame.use_fresh_state()
	_check("fresh save starts with 12 modules", SaveGame.unlocked_modules().size(), 12)
	SaveGame.load_state()["flips"] = 49
	_check("49 flips does not unlock worm",
		&"worm" in _ids(SaveGame.unlocked_modules()), false)
	SaveGame.load_state()["flips"] = 50
	_check("50 flips unlocks worm (derived, no bank() call)",
		&"worm" in _ids(SaveGame.unlocked_modules()), true)
	_check("is_unlocked agrees", SaveGame.is_unlocked(&"worm"), true)
	SaveGame.load_state()["kills"] = 212
	_check("212 kills unlocks the 150-kill module without banking",
		SaveGame.is_unlocked(&"on_damage_taken"), true)

func _ids(mods: Array) -> Array:
	var out := []
	for m in mods:
		out.append(m.id)
	return out

## user://save.json is plaintext and the only user-controlled input in the game.
func clamping() -> void:
	SaveGame.use_fresh_state()
	var hostile := {
		"version": 1, "salvage": -5000,
		"buffs": {"cpu_cycles": 500, "cooling": -3, "bandwidth": 2},
		"unlocked": ["worm", "../../etc/passwd", "not_a_module"],
		"kills": -1, "flips": 1e20,
	}
	var f := FileAccess.open(SaveGame.PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(hostile)); f.close()
	SaveGame._cache = {}
	var d := SaveGame.load_state()
	_check("negative salvage clamped to 0", d["salvage"], 0)
	_check("out-of-range buff clamped to max", d["buffs"]["cpu_cycles"], SaveGame.BUFF_MAX)
	_check("negative buff clamped to 0", d["buffs"]["cooling"], 0)
	_check("negative kills clamped to 0", d["kills"], 0)
	_check("unknown module id dropped", d["unlocked"].size(), 1)
	_check("path-traversal id dropped", "../../etc/passwd" in d["unlocked"], false)
	_check("valid id kept", "worm" in d["unlocked"], true)

## A truncated write must recover from .bak, not wipe every unlock the player has.
func bak_recovery() -> void:
	SaveGame.use_fresh_state()
	SaveGame.load_state()["salvage"] = 777
	SaveGame.save_state()
	SaveGame.load_state()["salvage"] = 999
	SaveGame.save_state()                      # rotates 777 into .bak
	var f := FileAccess.open(SaveGame.PATH, FileAccess.WRITE)
	f.store_string('{"version":1,"salvage":12')   # crash mid-write
	f.close()
	print("     (the JSON parse error below is this truncated file, on purpose)")
	SaveGame._cache = {}
	var d := SaveGame.load_state()
	_check("truncated save recovers from .bak", d["salvage"], 777)
	_check("recovery is not a wipe", d["salvage"] != 0, true)
