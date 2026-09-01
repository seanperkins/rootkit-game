extends CanvasLayer

const FG := Color(0.55, 1.0, 0.72)
const DIM := Color(0.35, 0.62, 0.48)
const WARN := Color(1.0, 0.45, 0.42)

var run: Node2D
var _hud: Control
var _overlay: Control
## The card PanelContainers, so the SELECTED one can be lit. The card is the
## module; the row inside it is only where that module goes, so highlighting a
## row alone loses track of what is being placed.
var _cards: Array = []
## The keyboard's view of the overlay: one entry per card, holding only the
## buttons that can actually be pressed. Indexing enabled-only rows is what
## makes Enter always do something — the highlight can never come to rest on a
## `no room` row, where the key would look broken.
var _nav: Array = []
var _decline: Button
## Which card, which of its enabled rows, or the decline button underneath them.
var _col := 0
var _row := 0
var _on_decline := false
var _end: Control

func bind(r: Node2D) -> void:
	run = r
	_build()
	run.level_up_offered.connect(_on_cards)
	run.fusion_offered.connect(_on_fusion)
	run.run_ended.connect(_on_end)
	run.stats_changed.connect(_refresh)
	_refresh()

func _mono(size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", FG)
	return l

func _panel(c: Color, width: int = 1) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.05, 0.04, 0.92)
	sb.border_color = c
	sb.set_border_width_all(width)
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

	# The damage vignette. Screen space, because it is a fact about the player
	# rather than about a place, and it fades rather than strobes.
	_vignette = ColorRect.new()
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.color = Color(0.9, 0.1, 0.12, 0.0)
	var vg := Gradient.new()
	vg.set_color(0, Color(1, 1, 1, 0))
	vg.set_color(1, Color(1, 1, 1, 1))
	var vt := GradientTexture2D.new()
	vt.gradient = vg
	vt.fill = GradientTexture2D.FILL_RADIAL
	vt.fill_from = Vector2(0.5, 0.5)
	vt.fill_to = Vector2(1.0, 0.5)
	_vignette.material = null
	_vignette.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_hud.add_child(_vignette)

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

	# A column, rather than two hardcoded y positions. The cards stretch to the
	# tallest stats line, and decline sat at a fixed 452 that the row had
	# already grown past — so the one option you reach by pressing DOWN was
	# drawn underneath the first card.
	var column := VBoxContainer.new()
	column.name = "Column"
	column.position = Vector2(60, 150)
	column.add_theme_constant_override("separation", 18)
	_overlay.add_child(column)

	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 18)
	column.add_child(row)

	_decline = Button.new()
	_decline.name = "Decline"
	# A leading space, so the selection marker can replace it without the label
	# shifting sideways as the highlight moves.
	_decline.text = " decline  ->  +25 salvage"
	_decline.custom_minimum_size = Vector2(260, 34)
	# Left-aligned in a box that would otherwise stretch it the full width.
	_decline.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_decline.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_decline.focus_mode = Control.FOCUS_NONE
	_decline.set_meta("base", _decline.text)
	_decline.set_meta("tint", DIM)
	column.add_child(_decline)
	_decline.pressed.connect(_decline_current)
	# Connected once, here rather than per offer: the cards are rebuilt on every
	# level-up but this button is not, and reconnecting would stack handlers.
	_decline.mouse_entered.connect(_hover_decline)

	# The recipe panel, over the level-up overlay. Exact-id recipes are not
	# discoverable by play, so this is part of the feature rather than a nicety.
	_recipes = PanelContainer.new()
	_recipes.name = "Recipes"
	_recipes.add_theme_stylebox_override("panel",
		_panel(Color(0.08, 0.18, 0.15, 0.96), 1))
	# Explicit geometry. A PanelContainer with only an anchor preset sizes to its
	# child's minimum and lands at an anchor-relative origin — not reliably on
	# screen, let alone readable.
	_recipes.set_anchors_preset(Control.PRESET_FULL_RECT)
	_recipes.offset_left = 80
	_recipes.offset_right = -80
	_recipes.offset_top = 60
	_recipes.offset_bottom = -60
	_recipes.visible = false
	var scroll := ScrollContainer.new()
	# Held by reference: the label sits under the ScrollContainer, not directly
	# under _recipes, so a get_node("Body") off the panel would miss it.
	_recipes_body = _mono(13)
	scroll.add_child(_recipes_body)
	_recipes.add_child(scroll)
	_overlay.add_child(_recipes)

	# The pause panel. Its own screen, driven by run.user_paused rather than
	# run.paused — the modal-offer flag has four unconditional clearers, and
	# sharing it would let a card decline release a pause it never took.
	_pause_panel = Control.new()
	_pause_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_panel.visible = false
	add_child(_pause_panel)
	var pscrim := ColorRect.new()
	pscrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	pscrim.color = Color(0, 0, 0, 0.78)
	_pause_panel.add_child(pscrim)
	var pcol := VBoxContainer.new()
	pcol.position = Vector2(60, 150)
	pcol.add_theme_constant_override("separation", 12)
	_pause_panel.add_child(pcol)
	var ptitle := _mono(22)
	ptitle.text = "  SUSPENDED"
	pcol.add_child(ptitle)
	var presume := Button.new()
	presume.text = " resume   [esc]"
	presume.custom_minimum_size = Vector2(260, 34)
	presume.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	presume.alignment = HORIZONTAL_ALIGNMENT_LEFT
	presume.focus_mode = Control.FOCUS_NONE
	pcol.add_child(presume)
	presume.pressed.connect(_toggle_pause)
	var pabandon := Button.new()
	pabandon.text = " abandon run  ->  shell"
	pabandon.custom_minimum_size = Vector2(260, 34)
	pabandon.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	pabandon.alignment = HORIZONTAL_ALIGNMENT_LEFT
	pabandon.focus_mode = Control.FOCUS_NONE
	pcol.add_child(pabandon)
	pabandon.pressed.connect(_abandon)

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
var _fusion_buttons: Array = []
var _recipes: PanelContainer
var _recipes_body: Label
var _vignette: ColorRect
var _pause_panel: Control

func _on_cards(cards: Array) -> void:
	_cards_data = cards
	_show_cards()
	_overlay.visible = true

func _show_cards() -> void:
	_fusion_buttons = []
	_recipes.visible = false
	_overlay.get_node("Title").text = \
		"  LEVEL UP  ::  arrows to choose, enter to place, r for recipes, esc to decline"
	var row: HBoxContainer = card_row()
	for c in row.get_children():
		row.remove_child(c)
		c.queue_free()
	_cards.clear()
	_nav.clear()
	for entry in _cards_data:
		var buttons: Array = []
		var card := _make_card(entry, buttons)
		row.add_child(card)
		_cards.append(card)
		_nav.append(buttons)
	# Hovering moves the highlight, so the mouse and the keyboard never disagree
	# about what Enter would press.
	for ci in _nav.size():
		var list: Array = _nav[ci]
		for bi in list.size():
			(list[bi] as Button).mouse_entered.connect(_hover.bind(ci, bi))
	_reset_selection()

## The cards are rebuilt on every offer, so the selection is too. Index 0 of an
## enabled-only list is always a legal target; a card with no legal row at all
## is skipped, and if none of them has one there is only decline left.
## One decline path for both input devices and both screens. _activate() routes
## Enter through the button's own `pressed` signal precisely so the keyboard and
## the mouse cannot diverge; patching only KEY_ESCAPE would have reopened that
## gap from the other side, leaving every click calling decline_card() on a
## fusion screen — which never clears _pending_fusions and wrongly decrements
## pending_levels.
func _decline_current() -> void:
	if _fusion_buttons.is_empty():
		run.decline_card()
	else:
		_fusion_buttons = []
		run.decline_fusion()

## The one screen this feature adds. It reuses the level-up overlay wholesale —
## same row, same highlight, same keys — because a second navigation model for a
## screen that appears once or twice a run is a second thing to get wrong.
func _on_fusion(matches: Array) -> void:
	_recipes.visible = false
	_cards_data = []
	_fusion_buttons = []
	_overlay.get_node("Title").text = \
		"  FUSION  ::  arrows to choose, enter to compile, esc to decline"
	var row: HBoxContainer = card_row()
	for c in row.get_children():
		row.remove_child(c)
		c.queue_free()
	_cards.clear()
	_nav.clear()
	for i in matches.size():
		var ei: int = matches[i][0]
		var rec = matches[i][1]
		# A PanelContainer, like _make_card produces: _apply_highlight hard-casts
		# every entry of _cards to PanelContainer, and a VBoxContainer there
		# yields null and takes the first offer down with a script error.
		var card := PanelContainer.new()
		var body := VBoxContainer.new()
		body.add_theme_constant_override("separation", 6)
		card.add_child(body)
		var head := _mono(20)
		head.text = rec.fused.display_name
		body.add_child(head)
		var from := _mono(13)
		from.text = "%s + %s + %s" % [rec.vector_id, rec.trigger_id,
			rec.payload_id]
		from.add_theme_color_override("font_color", DIM)
		body.add_child(from)
		var b := Button.new()
		b.custom_minimum_size = Vector2(0, 34)
		b.focus_mode = Control.FOCUS_NONE
		b.text = " * compile into exploit_%02d" % (ei + 1)
		b.set_meta("base", b.text)
		b.pressed.connect(run.choose_fusion.bind(i))
		body.add_child(b)
		row.add_child(card)
		_cards.append(card)
		_nav.append([b])
		_fusion_buttons.append(b)
	_fusion_buttons.append(decline_button())
	# Hover moves the highlight, exactly as _show_cards wires it, under a comment
	# saying it exists so the mouse and the keyboard never disagree about what
	# Enter would press. A fusion screen without it reintroduces that gap.
	for ci in _nav.size():
		var list: Array = _nav[ci]
		for bi in list.size():
			(list[bi] as Button).mouse_entered.connect(_hover.bind(ci, bi))
	_overlay.visible = true
	_reset_selection()

## One line per recipe the player could actually assemble, with a mark per slot
## against what the loadout holds right now. Recipes whose modules are still
## locked are omitted entirely — the point of the panel is to show what is
## within reach, and a wall of unreachable rows is the opposite of that.
##
## A slot counts as filled only when the module is held AND at max rank, because
## that is what fusion demands: a triple sitting at rank 3 is not ready, and a
## panel that said otherwise would be lying about the only gate that matters.
func recipe_lines() -> Array:
	var unlocked := {}
	for m in run._unlocked:
		unlocked[m.id] = true
	var out := []
	for r in RecipeTable.all():
		if not (unlocked.has(r.vector_id) and unlocked.has(r.trigger_id)
				and unlocked.has(r.payload_id)):
			continue
		var marks := ""
		for id in [r.vector_id, r.trigger_id, r.payload_id]:
			var at: Array = run.loadout._slot_holding(id)
			if at.is_empty():
				marks += "[ ]"
			else:
				var em: EquippedModule = run.loadout.exploits[at[0]].at(at[1])
				marks += "[x]" if em.rank >= em.module.max_rank else "[-]"
		out.append("%s  %-18s %s + %s + %s" % [marks, r.fused.display_name,
			r.vector_id, r.trigger_id, r.payload_id])
	return out

func fusion_buttons() -> Array:
	return _fusion_buttons

func _reset_selection() -> void:
	_col = 0
	_row = 0
	_on_decline = false
	while _col < _nav.size() and (_nav[_col] as Array).is_empty():
		_col += 1
	if _col >= _nav.size():
		_col = 0
		_on_decline = true
	_apply_highlight()

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
	# Kept so the highlight can restyle and re-mark this button later without
	# rebuilding it or reverse-engineering which outcome it represents.
	b.set_meta("base", b.text)
	b.set_meta("tint", tint)
	# The engine's own focus navigation would fight the grid below, and the grid
	# is what knows that a card is a module and a row is an exploit.
	b.focus_mode = Control.FOCUS_NONE
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

## `out_buttons` collects this card's pressable rows, in the order they are laid
## out. Gathered while building rather than by walking children afterwards: the
## builder already knows which rows are legal, and a walker would have to
## re-derive it from the node tree.
func _make_card(entry: Array, out_buttons: Array) -> Control:
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
		var t := _mono(13)
		t.text = "[ salvage ]\n\nno module fits"
		box.add_child(t)
		box.add_child(_spacer())
		var b := Button.new()
		b.text = " +50 salvage"
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 34)
		b.add_theme_font_size_override("font_size", 12)
		b.focus_mode = Control.FOCUS_NONE
		b.set_meta("base", b.text)
		b.set_meta("tint", DIM)
		for state in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(state, _panel(DIM))
		b.pressed.connect(func(): run.choose_card(null, null))
		box.add_child(b)
		out_buttons.append(b)
		return card

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
		var rb := _row_button(m, e, by_row.get(e))
		box.add_child(rb)
		if not rb.disabled:
			out_buttons.append(rb)
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

# ------------------------------------------------------- keyboard selection ---

## The button Enter would press, or null when there is nothing to press.
func highlighted() -> Button:
	if _on_decline:
		return _decline
	if _col < 0 or _col >= _nav.size():
		return null
	var list: Array = _nav[_col]
	return list[_row] if _row >= 0 and _row < list.size() else null

## The card strip and the decline button, so their placement is assertable.
func card_row() -> Control:
	return _overlay.get_node("Column/Row")

func decline_button() -> Button:
	return _decline

## Down past the last row lands on decline, and once more wraps to the top, so
## every option is reachable without knowing a shortcut exists.
func _move_row(delta: int) -> void:
	if _nav.is_empty():
		return
	var n: int = (_nav[_col] as Array).size()
	var at := n if _on_decline else _row
	at = posmod(at + delta, n + 1)
	_on_decline = at == n
	_row = 0 if _on_decline else at
	_apply_highlight()

## Sideways picks a different MODULE. Cards with no legal row at all are passed
## over rather than landed on, and from decline this steps back onto the grid —
## decline spans the width, so there is nothing sideways of it to reach.
func _move_card(delta: int) -> void:
	if _nav.is_empty():
		return
	var was_decline := _on_decline
	_on_decline = false
	for _try in _nav.size():
		_col = posmod(_col + delta, _nav.size())
		if not (_nav[_col] as Array).is_empty():
			break
	var n: int = (_nav[_col] as Array).size()
	if n == 0:
		_on_decline = true          # no card has a legal row; only decline left
	else:
		_row = 0 if was_decline else mini(_row, n - 1)
	_apply_highlight()

func _activate() -> void:
	var b := highlighted()
	# Through the button's own signal, so the keyboard and the mouse take
	# exactly the same path into choose_card.
	if b != null and not b.disabled:
		b.pressed.emit()

func _hover(card: int, row: int) -> void:
	_col = card
	_row = row
	_on_decline = false
	_apply_highlight()

func _hover_decline() -> void:
	_on_decline = true
	_apply_highlight()

## The selected card is lit and the others dimmed, and inside it the selected
## row is marked and brightened. Both, because the card is the module and the
## row is only where it goes — a row marked on its own does not say what is
## about to be placed.
func _apply_highlight() -> void:
	for ci in _cards.size():
		var lit: bool = ci == _col and not _on_decline
		(_cards[ci] as PanelContainer).add_theme_stylebox_override(
			"panel", _panel(FG if lit else DIM, 2 if lit else 1))
	var sel := highlighted()
	for ci in _nav.size():
		for b in _nav[ci]:
			_mark(b, b == sel)
	if _decline != null:
		_mark(_decline, _decline == sel)

func _mark(b: Button, on: bool) -> void:
	var base: String = b.get_meta("base", b.text)
	var tint: Color = b.get_meta("tint", FG)
	b.text = (">" + base.substr(1)) if on else base
	var col := tint if on else tint.darkened(0.45)
	for state in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(state, _panel(col, 2 if on else 1))
	for state in ["font_color", "font_hover_color", "font_pressed_color"]:
		b.add_theme_color_override(state, col)

## Actions, not keycodes. An InputEventJoypadButton has no keycode, so a
## keycode match meant a gamepad player could walk and pause but never navigate,
## confirm or decline a level-up — unable to operate the build system the game
## is named for.
func _input(e: InputEvent) -> void:
	if e.is_echo():
		return
	var handled := true
	if e.is_action_pressed("restart") and _end.visible:
		_restart()
	elif e.is_action_pressed("cancel"):
		_route_cancel()
	elif e.is_action_pressed("pause") and _can_pause():
		_toggle_pause()
	elif _overlay.visible:
		if e.is_action_pressed("move_up"):        _move_row(-1)
		elif e.is_action_pressed("move_down"):    _move_row(1)
		elif e.is_action_pressed("move_left"):    _move_card(-1)
		elif e.is_action_pressed("move_right"):   _move_card(1)
		elif e.is_action_pressed("confirm"):      _activate()
		elif e.is_action_pressed("recipes"):      _toggle_recipes()
		else:                                     handled = false
	else:
		handled = false
	if not handled:
		return
	var vp := get_viewport()
	if vp != null:
		vp.set_input_as_handled()

## Leaving mid-run banks nothing beyond what a death would, so it goes through
## the same _die path rather than inventing a second one.
func _abandon() -> void:
	if run == null:
		return
	run.user_paused = false
	_pause_panel.visible = false
	run._die()

func _toggle_recipes() -> void:
	_recipes.visible = not _recipes.visible
	if _recipes.visible:
		_recipes_body.text = "\n".join(recipe_lines())

func _can_pause() -> bool:
	return run != null and run.alive and not run.won and not run.paused

## Five arms, not two. "Overlay visible -> decline, otherwise -> pause" does not
## cover the screens that exist: the recipe panel is a CHILD of _overlay, so
## cancel with it open would decline the card underneath it; _end is a SIBLING,
## so cancel on a finished run would pause it; and the pause panel itself would
## have no way to close.
func _route_cancel() -> void:
	if _recipes != null and _recipes.visible:
		_recipes.visible = false
	elif _pause_panel != null and _pause_panel.visible:
		_toggle_pause()
	# `run.paused`, not `_overlay.visible`: the overlay is hidden by _process,
	# one frame AFTER the decline clears the flag, so keying off visibility made
	# a second cancel in the same frame decline again instead of pausing.
	elif _overlay.visible and run != null and run.paused:
		_decline_current()
	elif _end.visible:
		_restart()
	elif _can_pause():
		_toggle_pause()

func _toggle_pause() -> void:
	if run == null:
		return
	run.user_paused = not run.user_paused
	_pause_panel.visible = run.user_paused

func _process(_d: float) -> void:
	if run != null and _vignette != null:
		_vignette.color.a = clampf(run._vignette, 0.0, 1.0) * 0.30
	if run != null and not run.paused:
		if _overlay.visible:
			_overlay.visible = false
		_refresh()
	elif run != null and run.user_paused:
		# The modal-offer guard above stops refreshing while `paused` is set,
		# which would leave the pause panel drawn over a frozen HUD.
		_refresh()
