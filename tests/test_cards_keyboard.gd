extends SceneTree

## Choosing a level-up card from the keyboard.
##
## The overlay is a grid: each CARD is a module, each row inside it is the
## exploit that module would go into. So the two axes mean different things —
## left/right picks WHAT, up/down picks WHERE — and the tests below assert that
## separation rather than just "a key moved something".

var failures := 0
var finished := {}

const CASES := [
	"the_overlay_opens_on_a_legal_target",
	"up_and_down_walk_the_exploit_rows",
	"left_and_right_walk_the_modules",
	"enter_places_the_highlighted_target",
	"the_highlight_never_lands_on_a_dead_row",
	"down_past_the_last_row_reaches_decline",
	"escape_declines_outright",
	"decline_sits_clear_of_the_cards",
]

func _initialize() -> void:
	SaveGame.use_test_paths()
	print("ROOTKIT — level-up by keyboard\n")
	await the_overlay_opens_on_a_legal_target()
	await up_and_down_walk_the_exploit_rows()
	await left_and_right_walk_the_modules()
	await enter_places_the_highlighted_target()
	await the_highlight_never_lands_on_a_dead_row()
	await down_past_the_last_row_reaches_decline()
	await escape_declines_outright()
	await decline_sits_clear_of_the_cards()
	print("")
	for c in CASES:
		if not finished.has(c):
			print("  FAIL  case '%s' never finished — it aborted part way" % c)
			failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _fresh_run() -> Node2D:
	SaveGame.use_fresh_state()
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(r)
	await process_frame
	return r

## The HUD layer, found by duck-typing rather than by name: the run builds it
## anonymously, and adding a name for the test's benefit would be test-only code
## living in production.
func _ui(r: Node2D) -> CanvasLayer:
	for c in r.get_children():
		if c is CanvasLayer and c.has_method("bind"):
			return c
	return null

## Open the level-up overlay the way a level-up does.
func _offer(r: Node2D) -> CanvasLayer:
	r.pending_levels += 1
	r._offer_cards()
	return _ui(r)

func _key(ui: CanvasLayer, code: int) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	ui._input(e)

## What the player can see: the text of the highlighted button.
func _label(ui: CanvasLayer) -> String:
	var b = ui.highlighted()
	return "" if b == null else b.text

## The modules on offer, card by card, in the order they are laid out.
func _offered(ui: CanvasLayer) -> Array:
	var out := []
	for entry in ui._cards_data:
		out.append(entry[0])
	return out

## Every exploit's contents WITH RANKS, so a rank-up is as visible as a fresh
## placement. Ranks matter: the offered cards routinely include a module the
## starting loadout already carries, and "does the loadout hold this id" is
## then true before a key is ever pressed.
func _snapshot(r: Node2D) -> Array:
	var out := []
	for ex in r.loadout.exploits:
		var ids := []
		for em in ex.equipped():
			ids.append("%s:%d" % [em.module.id, em.rank])
		ids.sort()
		out.append("+".join(ids))
	return out

## Which exploit rows differ between two snapshots.
func _changed_rows(before: Array, after: Array) -> Array:
	var out := []
	for i in maxi(before.size(), after.size()):
		var b: String = before[i] if i < before.size() else ""
		var a: String = after[i] if i < after.size() else ""
		if a != b:
			out.append(i)
	return out

## The exploit a row button names: " >^  exploit_02   rank 1 -> 2" is row 1.
func _exploit_of(label: String) -> int:
	var k := label.find("exploit_")
	return int(label.substr(k + 8, 2)) - 1

func the_overlay_opens_on_a_legal_target() -> void:
	var r := await _fresh_run()
	var ui := _offer(r)
	_check("the overlay is up", ui._overlay.visible, true)
	_check("something is highlighted", ui.highlighted() != null, true)
	_check("and it is not a dead row", ui.highlighted().disabled, false)
	_check("the first exploit row is where it starts",
		"exploit_01" in _label(ui), true)
	r.free()
	finished["the_overlay_opens_on_a_legal_target"] = true

func up_and_down_walk_the_exploit_rows() -> void:
	var r := await _fresh_run()
	var ui := _offer(r)
	# Onto a card that offers more than one row first. A module id occupies one
	# slot in the whole loadout, so a card for something the starting build
	# already holds has a single row and DOWN from it reaches decline, not
	# exploit_02 — which is the axis this case is about, not a rule about it.
	var mods := _offered(ui)
	var col := 0
	while col < mods.size() and (mods[col] == null
			or r.loadout.legal_targets(mods[col]).size() < 2):
		_key(ui, KEY_RIGHT)
		col += 1
	_check("some card offers a second row", col < mods.size(), true)
	var first := _label(ui)
	_key(ui, KEY_DOWN)
	var second := _label(ui)
	_check("down moves off the first row", second == first, false)
	_check("and onto the second", "exploit_02" in second, true)
	_key(ui, KEY_UP)
	_check("up comes back", _label(ui), first)
	r.free()
	finished["up_and_down_walk_the_exploit_rows"] = true

## The decisive one for the two axes being different: right must change WHICH
## MODULE is on offer, not which row of the same module.
##
## Asserted as an exact delta rather than "the loadout now holds this id". An
## offered card is often a rank-up of something already equipped, so the weaker
## form was true before Enter and passed whether or not RIGHT did anything.
func left_and_right_walk_the_modules() -> void:
	var r := await _fresh_run()
	var ui := _offer(r)
	var mods := _offered(ui)
	_check("three cards are on offer", mods.size(), 3)

	var before := _snapshot(r)
	_key(ui, KEY_RIGHT)
	var e1 := _exploit_of(_label(ui))
	_key(ui, KEY_ENTER)
	var after := _snapshot(r)
	_check("right then enter changes exactly the row it pointed at",
		_changed_rows(before, after), [e1])
	_check("and what landed there is the SECOND card's module",
		String(mods[1].id) in after[e1], true)
	r.free()

	# And it wraps, rather than stopping at the third card.
	var r2 := await _fresh_run()
	var ui2 := _offer(r2)
	var mods2 := _offered(ui2)
	var before2 := _snapshot(r2)
	for k in 3:
		_key(ui2, KEY_RIGHT)
	var e2 := _exploit_of(_label(ui2))
	_key(ui2, KEY_ENTER)
	var after2 := _snapshot(r2)
	_check("three rights wrap back and change one row",
		_changed_rows(before2, after2), [e2])
	_check("and it took the FIRST card's module",
		String(mods2[0].id) in after2[e2], true)
	r2.free()
	finished["left_and_right_walk_the_modules"] = true

func enter_places_the_highlighted_target() -> void:
	var r := await _fresh_run()
	var ui := _offer(r)
	var mods := _offered(ui)

	# Walk RIGHT to a card that actually offers more than one row. A module id
	# occupies one slot in the whole loadout now, so a card for something the
	# starting build already holds offers exactly its own slot — pressing DOWN
	# on that one moves nothing, and the test would assert against row 0.
	var col := 0
	while col < mods.size() and (mods[col] == null
			or r.loadout.legal_targets(mods[col]).size() < 2):
		_key(ui, KEY_RIGHT)
		col += 1
	if col >= mods.size():
		_check("some card offers a second row", false, true)
		r.free()
		finished["enter_places_the_highlighted_target"] = true
		return
	var picked: Module = mods[col]

	# Down one row, so this cannot pass by placing into row 1 by default: the
	# module has to land in the exploit the highlight was actually on.
	_key(ui, KEY_DOWN)
	_check("the highlight really is on the second row",
		"exploit_02" in _label(ui), true)
	_key(ui, KEY_ENTER)

	_check("the run is running again", r.paused, false)
	_check("the highlighted card's module went in",
		r.loadout.holds(picked.id) >= 0, true)
	# holds() reports the FIRST exploit carrying the id, which is the starting
	# row whenever the card was a rank-up. Ask the row the highlight named.
	_check("the second exploit row now exists",
		r.loadout.exploits.size() >= 2, true)
	_check("and it is the one that received the module",
		r.loadout.exploits[1].holds(picked.id) != null, true)
	r.free()
	finished["enter_places_the_highlighted_target"] = true

## A row with no legal home is rendered disabled. Landing on one and pressing
## enter would do nothing at all, which reads as the key being broken.
func the_highlight_never_lands_on_a_dead_row() -> void:
	var r := await _fresh_run()
	var ui := _offer(r)
	var dead := 0
	# Walk the whole cycle several times over, both axes.
	for k in 24:
		_key(ui, KEY_DOWN)
		var b = ui.highlighted()
		if b == null or b.disabled:
			dead += 1
	for k in 12:
		_key(ui, KEY_RIGHT)
		var b2 = ui.highlighted()
		if b2 == null or b2.disabled:
			dead += 1
	_check("no step of the cycle highlights a dead row", dead, 0)
	r.free()
	finished["the_highlight_never_lands_on_a_dead_row"] = true

## Decline sits at the bottom of the vertical cycle, so every option is
## reachable without knowing a shortcut exists.
func down_past_the_last_row_reaches_decline() -> void:
	var r := await _fresh_run()
	var ui := _offer(r)
	var salvage_before: int = r.salvage
	var before := _snapshot(r)

	var guard := 0
	while not ("decline" in _label(ui)) and guard < 12:
		_key(ui, KEY_DOWN)
		guard += 1
	_check("decline is reachable by pressing down", "decline" in _label(ui), true)

	_key(ui, KEY_ENTER)
	_check("and entering it pays the decline salvage",
		r.salvage, salvage_before + 25)
	_check("without placing or ranking anything", _snapshot(r), before)
	r.free()
	finished["down_past_the_last_row_reaches_decline"] = true

func escape_declines_outright() -> void:
	var r := await _fresh_run()
	var ui := _offer(r)
	var salvage_before: int = r.salvage
	var before := _snapshot(r)
	_key(ui, KEY_ESCAPE)
	_check("escape pays the decline salvage", r.salvage, salvage_before + 25)
	_check("places or ranks nothing", _snapshot(r), before)
	_check("and lets the run resume", r.paused, false)
	r.free()
	finished["escape_declines_outright"] = true

func wasd_moves_the_same_as_the_arrows() -> void:
	var r := await _fresh_run()
	var ui := _offer(r)
	_key(ui, KEY_DOWN)
	_key(ui, KEY_RIGHT)
	var by_arrows := _label(ui)
	r.free()

	var r2 := await _fresh_run()
	var ui2 := _offer(r2)
	_key(ui2, KEY_S)
	_key(ui2, KEY_D)
	_check("S and D land where DOWN and RIGHT do", _label(ui2), by_arrows)
	_key(ui2, KEY_W)
	_key(ui2, KEY_A)
	var back := _label(ui2)
	r2.free()

	var r3 := await _fresh_run()
	var ui3 := _offer(r3)
	_check("W and A come back to the start", back, _label(ui3))
	r3.free()
	finished["wasd_moves_the_same_as_the_arrows"] = true

## Decline is the bottom of the vertical cycle, so the highlight lands on it —
## and a highlight you cannot see is not a highlight. It sat at a hardcoded y
## that the card row had already grown past, leaving it drawn underneath the
## first card.
func decline_sits_clear_of_the_cards() -> void:
	var r := await _fresh_run()
	var ui := _offer(r)
	# Containers size on the next frame, so ask after one.
	await process_frame
	var cards: Control = ui.card_row()
	var decline: Button = ui.decline_button()
	_check("the cards have been laid out", cards.size.y > 0.0, true)
	_check("decline starts below the tallest card",
		decline.global_position.y >= cards.global_position.y + cards.size.y, true)
	_check("and is inside the viewport",
		decline.global_position.y + decline.size.y
			<= float(ProjectSettings.get_setting("display/window/size/viewport_height")),
		true)
	r.free()
	finished["decline_sits_clear_of_the_cards"] = true
