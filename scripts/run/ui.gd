extends CanvasLayer

const FG := Color(0.55, 1.0, 0.72)
const DIM := Color(0.35, 0.62, 0.48)
const WARN := Color(1.0, 0.45, 0.42)

var run: Node2D
var _hud: Control
var _overlay: Control
var _cards: Array = []
var _end: Control

func bind(r: Node2D) -> void:
	run = r
	_build()
	run.level_up_offered.connect(_on_cards)
	run.run_ended.connect(_on_end)
	run.stats_changed.connect(_refresh)
	_refresh()

func _mono(size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", FG)
	return l

func _panel(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.05, 0.04, 0.92)
	sb.border_color = c
	sb.set_border_width_all(1)
	sb.set_content_margin_all(14)
	return sb

func _build() -> void:
	_hud = Control.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hud)

	var top := _mono(15)
	top.name = "Top"
	top.position = Vector2(18, 12)
	_hud.add_child(top)

	var build := _mono(13)
	build.name = "Build"
	build.position = Vector2(18, 42)
	build.add_theme_color_override("font_color", DIM)
	_hud.add_child(build)

	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.visible = false
	add_child(_overlay)

	var scrim := ColorRect.new()
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.color = Color(0, 0, 0, 0.72)
	_overlay.add_child(scrim)

	var title := _mono(20)
	title.name = "Title"
	title.text = "  LEVEL UP  ::  select module"
	title.position = Vector2(60, 78)
	_overlay.add_child(title)

	var row := HBoxContainer.new()
	row.name = "Row"
	row.position = Vector2(60, 150)
	row.add_theme_constant_override("separation", 18)
	_overlay.add_child(row)

	var decline := Button.new()
	decline.name = "Decline"
	decline.text = "decline  ->  +25 salvage"
	decline.position = Vector2(60, 452)
	decline.custom_minimum_size = Vector2(260, 34)
	_overlay.add_child(decline)
	decline.pressed.connect(func(): run.decline_card())

	_end = Control.new()
	_end.set_anchors_preset(Control.PRESET_FULL_RECT)
	_end.visible = false
	add_child(_end)
	var escrim := ColorRect.new()
	escrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	escrim.color = Color(0, 0, 0, 0.86)
	_end.add_child(escrim)
	var etext := _mono(24)
	etext.name = "Text"
	etext.position = Vector2(60, 160)
	_end.add_child(etext)
	var again := Button.new()
	again.text = "disconnect  ->  shell   [R]"
	again.position = Vector2(60, 260)
	again.custom_minimum_size = Vector2(280, 36)
	_end.add_child(again)
	again.pressed.connect(_restart)

func _refresh() -> void:
	if run == null:
		return
	var t: float = run.time_left()
	var hp := int(run.player_health)
	# The maximum was hardcoded in the FORMAT STRING, so no compiler caught it:
	# a memory-r10 player read "integrity 180/100".
	var maxhp := int(run._eff_integrity())
	var top: Label = _hud.get_node("Top")
	top.text = "integrity %3d/%d  armor %.0f  def %.0f   subnet %d/%d  %s   lvl %d  [%s]   salvage %d   botnet %d   kills %d  flips %d" % [
		hp, maxhp, run._eff_armor(), run._eff_defense(),
		run.subnet, SpawnDirector.CAMPAIGN_SUBNETS,
		"%d:%02d" % [int(t) / 60, int(t) % 60], run.level,
		_bar(float(run.xp) / maxf(run.xp_needed, 1), 14), run.salvage,
		run.botnet.count, run.kills, run.flips]
	# Name a live mini-boss. A set-piece the player does not notice arriving is
	# not a set-piece.
	var mb := ""
	for i in run.enemies.count:
		if run._is_miniboss(run.enemies.type_index[i]):
			mb = String(run.enemy_types[run.enemies.type_index[i]].id)
			break
	if mb != "":
		top.text += "   ::  %s ACTIVE" % mb.to_upper()
	if run.phase == run.Phase.CLEARED:
		top.text += "   >> SUBNET COLLAPSING — %ds to the gate" % int(
			ceil(run.collapse_left))
	# Proportional, not absolute. A fixed 30 fires at 16.7% on a 180 bar.
	top.add_theme_color_override("font_color",
		WARN if float(hp) < float(maxhp) * 0.3 else FG)

	var lines := []
	for i in run.resolved.size():
		var r: ResolvedExploit = run.resolved[i]
		var ex: Exploit = run.loadout.exploits[i]
		var mods := []
		for em in ex.equipped():
			mods.append("%s%s" % [em.module.display_name,
				"" if em.rank == 1 else "·%d" % em.rank])
		lines.append("exploit_%02d  %s%s" % [i + 1, " + ".join(mods),
			"   [INERT]" if r.inert else "   dmg %.0f  cd %.2f  corr %.0f" % [
				r.damage, r.cooldown, r.corruption]])
	_hud.get_node("Build").text = "\n".join(lines)

func _bar(f: float, w: int) -> String:
	var n := int(clampf(f, 0.0, 1.0) * w)
	return "#".repeat(n) + ".".repeat(w - n)

var _cards_data: Array = []

func _on_cards(cards: Array) -> void:
	_cards_data = cards
	_show_cards()
	_overlay.visible = true

func _show_cards() -> void:
	_overlay.get_node("Title").text = "  LEVEL UP  ::  one click places the module"
	var row: HBoxContainer = _overlay.get_node("Row")
	for c in row.get_children():
		row.remove_child(c)
		c.queue_free()
	for entry in _cards_data:
		row.add_child(_make_card(entry))

const COLUMN_NAMES := ["VECTOR", "TRIGGER", "PAYLOAD"]

## One colour and one mark per outcome. Placing and founding a row are both
## "nothing is lost" but they are not the same move — founding spends one of the
## three exploits — so they read differently.
const RANK := Color(1.0, 0.86, 0.35)
const NEW_ROW := Color(0.45, 0.72, 1.0)
const OFF := Color(0.18, 0.26, 0.22)

## Three squares, one per exploit column, this module's own filled. The card
## answers WHERE before it answers what, because with a single slot per column
## the column plus the row is the entire placement — which is what collapses the
## old module-then-slot pair of clicks into one.
func _column_marks(slot: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	for i in COLUMN_NAMES.size():
		var sq := Panel.new()
		sq.custom_minimum_size = Vector2(13, 13)
		var sb := StyleBoxFlat.new()
		sb.bg_color = FG if i == slot else Color(0, 0, 0, 0)
		sb.border_color = FG if i == slot else OFF
		sb.set_border_width_all(1)
		sq.add_theme_stylebox_override("panel", sb)
		row.add_child(sq)
	var l := _mono(11)
	l.text = "  " + COLUMN_NAMES[slot]
	l.add_theme_color_override("font_color", DIM)
	row.add_child(l)
	return row

## One button per exploit row, and every one of them is terminal: pressing it
## places the module. `target` is null when this row is no legal home for it,
## which after the column is fixed can only be a max-rank duplicate or the last
## interval trigger — both worth naming rather than greying out silently.
func _row_button(m: Module, e: int, target) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 34)
	b.add_theme_font_size_override("font_size", 12)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var sl := Exploit.slot_index_of(int(m.slot))
	var founded: bool = e < run.loadout.exploits.size()
	var ex: Exploit = run.loadout.exploits[e] if founded else null
	var occupant: EquippedModule = ex.at(sl) if ex != null else null

	var mark := "·"
	var detail := ""
	var tint := OFF
	if target == null:
		if occupant == null:
			detail = "no room"
		elif not occupant.can_rank_up():
			detail = "%s at max rank" % occupant.module.display_name
		else:
			detail = "%s is the last interval" % occupant.module.display_name
	else:
		match target.action:
			Loadout.Rule.RANK_UP:
				mark = "^"
				detail = "rank %d -> %d" % [occupant.rank, occupant.rank + 1]
				tint = RANK
			Loadout.Rule.REPLACE:
				mark = "x"
				detail = "replace %s" % target.victim.display_name
				tint = WARN
			_:
				if founded:
					mark = "+"
					detail = "empty slot"
					tint = FG
				else:
					mark = "*"
					detail = "new row"
					tint = NEW_ROW

	b.text = " %s  exploit_%02d   %s" % [mark, e + 1, detail]
	if target == null:
		b.disabled = true
		b.add_theme_stylebox_override("disabled", _panel(OFF))
		b.add_theme_color_override("font_disabled_color", OFF)
	else:
		for state in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(state, _panel(tint))
		for state in ["font_color", "font_hover_color", "font_pressed_color"]:
			b.add_theme_color_override(state, tint)
		b.pressed.connect(func(): run.choose_card(m, target))
	return b

## Eats the slack between a card's text and its buttons, so the buttons sit on
## the bottom edge whatever the stats line above them runs to.
func _spacer() -> Control:
	var c := Control.new()
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return c

func _make_card(entry: Array) -> Control:
	var m = entry[0]
	var targets: Array = entry[1]
	var card := PanelContainer.new()
	# A minimum height, and a spacer above the buttons in every branch below.
	# HBoxContainer already stretches all three cards to the tallest one, so
	# without the spacer a card with a short stats line floats its buttons up
	# and the three rows of buttons no longer line up across the screen.
	card.custom_minimum_size = Vector2(268, 244)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	card.add_child(box)

	if m == null:
		card.add_theme_stylebox_override("panel", _panel(DIM))
		var t := _mono(13)
		t.text = "[ salvage ]\n\nno module fits"
		box.add_child(t)
		box.add_child(_spacer())
		var b := Button.new()
		b.text = " +50 salvage"
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 34)
		b.add_theme_font_size_override("font_size", 12)
		for state in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(state, _panel(DIM))
		b.pressed.connect(func(): run.choose_card(null, null))
		box.add_child(b)
		return card

	card.add_theme_stylebox_override("panel", _panel(FG))
	box.add_child(_column_marks(int(m.slot)))
	var name_label := _mono(16)
	name_label.text = m.display_name
	box.add_child(name_label)
	var stats := _mono(11)
	stats.add_theme_color_override("font_color", DIM)
	stats.text = _stats_line(m)
	box.add_child(stats)
	box.add_child(_spacer())

	# At most one target per row now, so a row and a button are the same thing.
	var by_row := {}
	for t in targets:
		by_row[t.exploit] = t
	for e in Loadout.MAX_EXPLOITS:
		box.add_child(_row_button(m, e, by_row.get(e)))
	return card

func _stats_line(m: Module) -> String:
	var parts := []
	for k in m.stats:
		if k == &"cadence_mult":
			# A multiplier, not an addend. Under "%+.2f" on_kill's card reads
			# "cadence_mult +1.52" — a 52% SLOWDOWN rendered as the
			# largest-looking bonus on the card, sitting next to "damage +3.00".
			# The multiplication sign carries the direction that +/- cannot.
			parts.append("cadence x%.2f" % m.stats[k])
		else:
			parts.append("%s %+.2f" % [k, m.stats[k]])
	return "\n".join(parts)

func _on_end(won: bool, salvage: int) -> void:
	_overlay.visible = false
	var t: Label = _end.get_node("Text")
	if won:
		t.text = "  CORE BREACHED\n\n  ICE terminated. %d salvage banked." % salvage
		t.add_theme_color_override("font_color", FG)
	else:
		t.text = "  PROCESS TERMINATED\n\n  died on subnet %d of %d.\n  salvage since the last clear is lost.\n  kills %d   flips %d" % [
			run.subnet, SpawnDirector.CAMPAIGN_SUBNETS, run.kills, run.flips]
		t.add_theme_color_override("font_color", WARN)
	_end.visible = true

func _restart() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")

func _input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and e.keycode == KEY_R and _end.visible:
		_restart()

func _process(_d: float) -> void:
	if run != null and not run.paused:
		if _overlay.visible:
			_overlay.visible = false
		_refresh()
