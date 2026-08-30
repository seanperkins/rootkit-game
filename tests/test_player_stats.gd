extends SceneTree

var failures := 0

func _init() -> void:
	print("ROOTKIT — player stats\n")
	identity()
	armor_floor()
	defense_curve()
	composed()
	hostile_inputs()
	sheet_merge()
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

## An unbuffed run must behave exactly as it does today.
func identity() -> void:
	for raw in [5.0, 7.0, 12.0, 22.0]:
		_check("identity at 0/0 for %.0f" % raw, PlayerStats.mitigate(raw, 0.0, 0.0), raw)

## The worm row is the tie point: 5 - 4 == 5 * 0.2 == 1.0. It is the first place
## ARMOR_FLOOR engages, and the row the design doc got wrong twice.
func armor_floor() -> void:
	_check("worm 5 at armor 4", PlayerStats.mitigate(5.0, 4.0, 0.0), 1.0)
	_check("daemon 7 at armor 4", PlayerStats.mitigate(7.0, 4.0, 0.0), 3.0)
	_check("firewall 12 at armor 4", PlayerStats.mitigate(12.0, 4.0, 0.0), 8.0)
	_check("ICE 22 at armor 4", PlayerStats.mitigate(22.0, 4.0, 0.0), 18.0)
	# Armor far exceeding the hit floors at 20%, never zero.
	_check("armor 999 floors at 20%", PlayerStats.mitigate(22.0, 999.0, 0.0), 4.4)

## d/(d+K) is asymptotic to 1 and never reaches it.
func defense_curve() -> void:
	_check("defense 0 = no cut", PlayerStats.mitigate(100.0, 0.0, 0.0), 100.0)
	_check("defense K = 50% cut", PlayerStats.mitigate(100.0, 0.0, 60.0), 50.0)
	_check("defense 10K = 90.9% cut", PlayerStats.mitigate(100.0, 0.0, 600.0), 9.090909)
	_check("defense never reaches 0 damage",
		PlayerStats.mitigate(100.0, 0.0, 1.0e9) > 0.0, true)

## Armor first, then defense — the documented order.
func composed() -> void:
	_check("worm 5 at armor 4 / defense 60", PlayerStats.mitigate(5.0, 4.0, 60.0), 0.5)
	_check("ICE 22 at armor 12 / defense 110",
		PlayerStats.mitigate(22.0, 12.0, 110.0), 3.529412)

## user://save.json is user-editable. At defense == -60 the denominator is 0.0
## and GDScript float division yields INF rather than erroring, so a hostile file
## would silently produce nonsense instead of failing loudly.
func hostile_inputs() -> void:
	_check("negative defense clamps to identity",
		PlayerStats.mitigate(10.0, 0.0, -60.0), 10.0)
	_check("very negative defense clamps to identity",
		PlayerStats.mitigate(10.0, 0.0, -1000.0), 10.0)
	_check("negative armor clamps to identity",
		PlayerStats.mitigate(10.0, -50.0, 0.0), 10.0)

func sheet_merge() -> void:
	var s := PlayerStats.sheet({&"integrity": 80.0, &"armor": 6.0})
	_check("sheet adds integrity", s[&"integrity"], 180.0)
	_check("sheet adds armor", s[&"armor"], 6.0)
	_check("sheet keeps untouched base", s[&"clock_speed"], 220.0)
	_check("sheet ignores unknown keys",
		PlayerStats.sheet({&"nonsense": 5.0}).has(&"nonsense"), false)
	var m := PlayerStats.mults({&"attack": 0.4, &"haste": -0.3})
	_check("mults add attack", m[&"attack"], 1.4)
	_check("mults add haste", m[&"haste"], 0.7)
	_check("mults keep untouched base", m[&"reach"], 1.0)
