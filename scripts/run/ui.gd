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

	var slots := VBoxContainer.new()
	slots.name = "Slots"
	slots.position = Vector2(60, 150)
	slots.visible = false
	slots.add_theme_constant_override("separation", 10)
	_overlay.add_child(slots)

	var back := Button.new()
	back.name = "Back"
	back.text = "back  ->  pick a different module"
	back.position = Vector2(60, 470)
	back.custom_minimum_size = Vector2(300, 32)
	back.visible = false
	_overlay.add_child(back)
	back.pressed.connect(_show_cards)

	var row := HBoxContainer.new()
	row.name = "Row"
	row.position = Vector2(60, 150)
	row.add_theme_constant_override("separation", 18)
	_overlay.add_child(row)

	var decline := Button.new()
	decline.name = "Decline"
	decline.text = "decline  ->  +25 salvage"
	decline.position = Vector2(60, 420)
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
	var top: Label = _hud.get_node("Top")
	top.text = "integrity %3d/100   %s   lvl %d  [%s]   salvage %d   botnet %d   kills %d  flips %d" % [
		hp, "%d:%02d" % [int(t) / 60, int(t) % 60], run.level,
		_bar(float(run.xp) / maxf(run.xp_needed, 1), 14), run.salvage,
		run.botnet.count, run.kills, run.flips]
	top.add_theme_color_override("font_color", WARN if hp < 30 else FG)

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
	_overlay.get_node("Title").text = "  LEVEL UP  ::  select module"
	_overlay.get_node("Row").visible = true
	_overlay.get_node("Decline").visible = true
	_overlay.get_node("Slots").visible = false
	_overlay.get_node("Back").visible = false
	var row: HBoxContainer = _overlay.get_node("Row")
	for c in row.get_children():
		row.remove_child(c)
		c.queue_free()
	for entry in _cards_data:
		row.add_child(_make_card(entry))

## Stage 2 — the loadout as a board. Every slot is shown; only the ones this
## module may legally occupy are enabled, so the shape of the build is visible
## at the moment you are deciding.
func _show_slots(m: Module, targets: Array) -> void:
	_overlay.get_node("Title").text = "  %s  ::  choose a slot" % m.display_name
	_overlay.get_node("Row").visible = false
	_overlay.get_node("Decline").visible = false
	_overlay.get_node("Back").visible = true
	var box: VBoxContainer = _overlay.get_node("Slots")
	box.visible = true
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()

	var by_slot := {}
	for t in targets:
		by_slot[t.exploit * 10 + t.slot] = t

	for e in Loadout.MAX_EXPLOITS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var label := _mono(13)
		label.custom_minimum_size = Vector2(110, 0)
		var ex: Exploit = run.loadout.exploits[e] if e < run.loadout.exploits.size() else null
		label.text = "exploit_%02d" % (e + 1)
		label.add_theme_color_override("font_color", FG if ex != null else DIM)
		row.add_child(label)
		for sl in Exploit.SLOT_COUNT:
			row.add_child(_slot_button(m, ex, e, sl, by_slot.get(e * 10 + sl)))
		box.add_child(row)

	var legend := _mono(12)
	legend.add_theme_color_override("font_color", DIM)
	legend.text = "\n  VECTOR      TRIGGER     PAYLOAD     PAYLOAD"
	box.add_child(legend)

func _slot_button(m: Module, ex, e: int, sl: int, target) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(168, 54)
	b.add_theme_font_size_override("font_size", 12)
	var occupant: EquippedModule = ex.at(sl) if ex != null else null
	var occupied_by := ""
	if occupant != null:
		occupied_by = "%s%s" % [occupant.module.display_name,
			"" if occupant.rank == 1 else " ·%d" % occupant.rank]
	else:
		occupied_by = "( empty )"

	if target == null:
		# Not a legal home for this module: wrong slot type, a duplicate id, or
		# the last interval trigger.
		b.disabled = true
		b.text = occupied_by
		b.add_theme_stylebox_override("disabled", _panel(Color(0.18, 0.26, 0.22)))
	else:
		match target.action:
			Loadout.Rule.RANK_UP:
				b.text = "%s\nRANK UP -> %d" % [occupied_by, occupant.rank + 1]
				b.add_theme_stylebox_override("normal", _panel(Color(0.55, 1.0, 0.72)))
			Loadout.Rule.REPLACE:
				b.text = "%s\nREPLACE" % occupied_by
				b.add_theme_stylebox_override("normal", _panel(WARN))
			_:
				b.text = "( empty )\nPLACE"
				b.add_theme_stylebox_override("normal", _panel(FG))
		b.pressed.connect(func(): run.choose_card(m, target))
	return b

func _make_card(entry: Array) -> Control:
	var m = entry[0]
	var targets: Array = entry[1]
	var b := Button.new()
	b.custom_minimum_size = Vector2(268, 210)
	b.add_theme_font_size_override("font_size", 13)
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if m == null:
		b.text = "\n[ salvage ]\n\nno module fits\n\n+50 salvage"
		b.add_theme_stylebox_override("normal", _panel(DIM))
		b.pressed.connect(func(): run.choose_card(null, null))
	else:
		var slot: String = ["VECTOR", "TRIGGER", "PAYLOAD"][int(m.slot)]
		b.text = "\n[ %s ]\n\n%s\n\n%d slot%s available\n\n%s" % [
			slot, m.display_name, targets.size(),
			"" if targets.size() == 1 else "s", _stats_line(m)]
		b.add_theme_stylebox_override("normal", _panel(FG))
		b.pressed.connect(func(): _show_slots(m, targets))
	return b

func _stats_line(m: Module) -> String:
	var parts := []
	for k in m.stats:
		parts.append("%s %+.2f" % [k, m.stats[k]])
	return "\n".join(parts)

func _on_end(won: bool, salvage: int) -> void:
	_overlay.visible = false
	var t: Label = _end.get_node("Text")
	if won:
		t.text = "  CORE BREACHED\n\n  ICE terminated. %d salvage banked." % salvage
		t.add_theme_color_override("font_color", FG)
	else:
		t.text = "  PROCESS TERMINATED\n\n  unbanked salvage lost.\n  kills %d   flips %d" % [
			run.kills, run.flips]
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
