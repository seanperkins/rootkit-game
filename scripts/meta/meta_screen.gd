extends Control

## The between-runs shell. Salvage banked by clearing a subnet is spent here, so
## the meta economy has somewhere to land.

const FG := Color(0.55, 1.0, 0.72)
## How many still-locked modules the shop lists before summarising the rest.
const UNLOCK_ROWS := 2

const DIM := Color(0.32, 0.58, 0.45)
const HOT := Color(1.0, 0.72, 0.35)

## Every id here MUST exist in SaveGame._default()["buffs"]: _refresh indexes
## d["buffs"][id] directly with no .get, so a name present here and missing there
## crashes the shop on open.
const BUFFS := [
	[&"cpu_cycles", "+CPU cycles", "attack x1.04 per rank"],
	[&"cooling",    "+cooling",    "attack speed x0.97 per rank"],
	[&"memory",     "+memory",     "integrity +8 per rank"],
	[&"firewall",   "+firewall",   "armor +0.6 per rank"],
	[&"encryption", "+encryption", "defense +6 per rank"],
	[&"bus_speed",  "+bus speed",  "move speed +6 per rank"],
	[&"addressing", "+addressing", "range x1.03 per rank"],
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
	col.add_child(_label("UPGRADES  ::  permanent, applied at run start", 13, DIM))
	col.add_child(_spacer(4))

	# Eight rows at 40px each is 320px added to a column that already ran to
	# roughly 505px in a 720px viewport, so the rows scroll and ./intrude does
	# not. The explicit height is load-bearing: an unbounded ScrollContainer
	# adopts its content's minimum height and pushes the start button off-screen
	# exactly as the bare VBoxContainer would. Two columns were the other option
	# and do not fit — one row is 644px wide and two need 1352 against 1280.
	var scroll := ScrollContainer.new()
	# 240, not 300: at 300 the measured bottom edge of ./intrude landed at y=762
	# in a 720px viewport. 240 shows six rows and leaves ~60px of slack for font
	# metrics. test_meta_layout.gd measures this rather than trusting the number.
	scroll.custom_minimum_size = Vector2(680, 240)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 10)
	scroll.add_child(rows)

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
		rows.add_child(row)
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
	# Only what is still to come, and only a few of them.
	#
	# One row per locked module was fine at three and pushed ./intrude off the
	# bottom of the screen at fourteen. A player wants to know what is next, not
	# to read the whole ladder.
	var lines := []
	var have_n := 0
	var hidden := 0
	for id in ModuleTable.LOCKED:
		if SaveGame.is_unlocked(id):
			have_n += 1
			continue
		if lines.size() < UNLOCK_ROWS:
			lines.append("  [ ] %-18s %s" % [id, SaveGame.milestone_text(id, d)])
		else:
			hidden += 1
	# EXACTLY UNLOCK_ROWS + 1 lines, always. The panel sits above ./intrude in a
	# fixed layout, so a list that grows with the table pushes the start button
	# off the bottom of the screen — which is what fourteen locked modules did.
	while lines.size() < UNLOCK_ROWS:
		lines.append("")
	lines.append("  %d of %d unlocked%s" % [have_n, ModuleTable.LOCKED.size(),
		"   (+%d more locked)" % hidden if hidden > 0 else ""])
	_status.text = "\n".join(lines)

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
