extends Control

## The between-runs shell. Salvage banked by clearing a subnet is spent here, so
## the meta economy has somewhere to land.

const FG := Color(0.55, 1.0, 0.72)
const DIM := Color(0.32, 0.58, 0.45)
const HOT := Color(1.0, 0.72, 0.35)

const BUFFS := [
	[&"cpu_cycles", "+CPU cycles", "damage +1.5 per rank"],
	[&"cooling",    "+cooling",    "cooldown -0.02 per rank"],
	[&"bandwidth",  "+bandwidth",  "pickup radius +6 per rank"],
]

var _rows: Array = []
var _salvage: Label
var _status: Label

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.016, 0.031, 0.027)
	add_child(bg)

	var col := VBoxContainer.new()
	col.position = Vector2(64, 52)
	col.add_theme_constant_override("separation", 10)
	add_child(col)

	col.add_child(_label("ROOTKIT", 30, FG))
	col.add_child(_label("rogue process // corporate network // subnet 01", 14, DIM))
	col.add_child(_spacer(18))

	_salvage = _label("", 18, HOT)
	col.add_child(_salvage)
	col.add_child(_spacer(6))
	col.add_child(_label("UPGRADES  ::  permanent, applied at compile time", 13, DIM))
	col.add_child(_spacer(4))

	for b in BUFFS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var name_l := _label("", 15, FG)
		name_l.custom_minimum_size = Vector2(230, 0)
		var desc_l := _label(b[2], 13, DIM)
		desc_l.custom_minimum_size = Vector2(240, 0)
		var buy := Button.new()
		buy.custom_minimum_size = Vector2(150, 30)
		buy.pressed.connect(_buy.bind(b[0]))
		row.add_child(name_l)
		row.add_child(desc_l)
		row.add_child(buy)
		col.add_child(row)
		_rows.append({"id": b[0], "label": b[1], "name": name_l, "buy": buy})

	col.add_child(_spacer(14))
	col.add_child(_label("UNLOCKS  ::  earned in-run, banked on a clear", 13, DIM))
	_status = _label("", 13, DIM)
	col.add_child(_status)
	col.add_child(_spacer(22))

	var start := Button.new()
	start.text = "  ./intrude  --subnet 01     [ENTER]  "
	start.custom_minimum_size = Vector2(340, 42)
	start.add_theme_font_size_override("font_size", 16)
	start.pressed.connect(_start)
	col.add_child(start)
	start.grab_focus()

	_refresh()

func _label(t: String, size: int, c: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	return l

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

func _refresh() -> void:
	var d := SaveGame.load_state()
	_salvage.text = "salvage  %d" % d["salvage"]
	for r in _rows:
		var n: int = d["buffs"][String(r["id"])]
		r["name"].text = "%-16s %s" % [r["label"], _pips(n)]
		if n >= SaveGame.BUFF_MAX:
			r["buy"].text = "MAXED"
			r["buy"].disabled = true
		else:
			var price := SaveGame.buff_price(n)
			r["buy"].text = "buy  %d" % price
			r["buy"].disabled = d["salvage"] < price
	var lines := []
	for id in ModuleTable.LOCKED:
		var have: bool = SaveGame.is_unlocked(id)
		lines.append("  %s %-18s %s" % ["[x]" if have else "[ ]", id,
			"unlocked" if have else _requirement(id, d)])
	_status.text = "\n".join(lines)

func _requirement(id: StringName, d: Dictionary) -> String:
	match id:
		&"worm":            return "flip 50 enemies   (%d/50)" % d["flips"]
		&"on_damage_taken": return "150 kills         (%d/150)" % d["kills"]
		&"beam":            return "400 kills         (%d/400)" % d["kills"]
	return ""

func _pips(n: int) -> String:
	return "[" + "#".repeat(n) + ".".repeat(SaveGame.BUFF_MAX - n) + "]"

func _buy(id: StringName) -> void:
	SaveGame.buy(id)
	_refresh()

func _start() -> void:
	get_tree().change_scene_to_file("res://scenes/run.tscn")

func _input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and e.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		_start()
