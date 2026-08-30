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
	title.text = "  LEVEL UP  ::  select module"
	title.position = Vector2(60, 90)
	_overlay.add_child(title)

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

func _on_cards(cards: Array) -> void:
	var row: HBoxContainer = _overlay.get_node("Row")
	for c in row.get_children():
		c.queue_free()
	for entry in cards:
		row.add_child(_make_card(entry))
	_overlay.visible = true

func _make_card(entry: Array) -> Control:
	var m = entry[0]
	var p = entry[1]
	var b := Button.new()
	b.custom_minimum_size = Vector2(268, 210)
	b.add_theme_font_size_override("font_size", 13)
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if m == null:
		b.text = "\n[ salvage ]\n\nno module fits\n\n+50 salvage"
		b.add_theme_stylebox_override("normal", _panel(DIM))
	else:
		var slot: String = ["VECTOR", "TRIGGER", "PAYLOAD"][int(m.slot)]
		var action := ""
		match p.rule:
			Loadout.Rule.RANK_UP:     action = "rank up  ->  exploit_%02d" % (p.exploit_index + 1)
			Loadout.Rule.EMPTY_SLOT:  action = "slot in  ->  exploit_%02d" % (p.exploit_index + 1)
			Loadout.Rule.NEW_EXPLOIT: action = "compile  ->  exploit_%02d (new)" % (p.exploit_index + 1)
			Loadout.Rule.REPLACE:     action = "REPLACE %s in exploit_%02d" % [
				p.victim.display_name, p.exploit_index + 1]
		b.text = "\n[ %s ]\n\n%s\n\n%s\n\n%s" % [slot, m.display_name, action, _stats_line(m)]
		b.add_theme_stylebox_override("normal",
			_panel(WARN if p.rule == Loadout.Rule.REPLACE else FG))
	b.pressed.connect(func(): run.choose_card(m, p))
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
