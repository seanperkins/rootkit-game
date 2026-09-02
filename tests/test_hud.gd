extends SceneTree

## The run HUD, which had NO test coverage at all before this suite.
##
## `grep -rn '_hud|get_node("Top")' tests/` returned nothing, so ui.gd's
## get_node("Status") / ("Centre") / ("Tally") / ("Build") — direct indexes with
## no .get — could be renamed or removed with no suite noticing. This is the
## only guard on those names.

var failures := 0
var finished := {}

const CASES := ["the_blocks_exist_and_populate", "integrity_warns_proportionally",
	"the_summary_reports_a_finished_run", "the_summary_survives_a_short_build",
	"the_teammate_strip_names_everyone_else"]

func _initialize() -> void:
	print("ROOTKIT — hud\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	await the_blocks_exist_and_populate()
	await integrity_warns_proportionally()
	await the_summary_reports_a_finished_run()
	await the_summary_survives_a_short_build()
	await the_teammate_strip_names_everyone_else()
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

func _ui(r: Node2D) -> CanvasLayer:
	for c in r.get_children():
		if c is CanvasLayer and c.has_method("bind"):
			return c
	return null

func _fresh_run() -> Node2D:
	SaveGame.use_fresh_state()
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(r)
	await process_frame
	r.input_override = Vector2.ZERO
	return r

## The node names ui.gd indexes without a fallback. A rename here is a crash in
## _refresh, which the runner sees only as a SCRIPT ERROR with no explanation.
func the_blocks_exist_and_populate() -> void:
	var r := await _fresh_run()
	var ui := _ui(r)
	ui._refresh()
	for n in ["Status", "Centre", "Tally", "Build"]:
		var node = ui._hud.get_node_or_null(n)
		_check("the %s block exists" % n, node != null, true)
		if node != null:
			_check("  and it has text", String(node.text).length() > 0, true)

	var status: String = ui._hud.get_node("Status").text
	_check("status carries integrity", status.contains("integrity"), true)
	_check("status carries the level", status.contains("lvl"), true)
	_check("status draws an ASCII bar", status.contains("#") or
		status.contains("."), true)
	var centre: String = ui._hud.get_node("Centre").text
	_check("centre carries the subnet", centre.contains("subnet"), true)
	var tally: String = ui._hud.get_node("Tally").text
	_check("tally carries kills", tally.contains("kills"), true)
	_check("tally carries salvage", tally.contains("salvage"), true)
	# Each value lives in exactly one block now — that is the whole point.
	_check("salvage is not also in status", status.contains("salvage"), false)
	r.free()
	await process_frame
	finished["the_blocks_exist_and_populate"] = true

## Proportional, not a fixed threshold: a fixed 30 fires at 16.7% on a 180 bar.
func integrity_warns_proportionally() -> void:
	var r := await _fresh_run()
	var ui := _ui(r)
	ui._refresh()
	var status: Label = ui._hud.get_node("Status")
	_check("a healthy player reads normal",
		status.get_theme_color("font_color"), ui.FG)
	r.player_health[r.local_slot] = r._eff_integrity(r.local_slot) * 0.2
	ui._refresh()
	_check("a hurt player reads as warning",
		status.get_theme_color("font_color"), ui.WARN)
	r.free()
	await process_frame
	finished["integrity_warns_proportionally"] = true

func the_summary_reports_a_finished_run() -> void:
	var r := await _fresh_run()
	var ui := _ui(r)
	r.kills[r.local_slot] = 42
	r.flips[r.local_slot] = 7
	ui._on_end(false, 0)
	var t: String = ui._end.get_node("Text").text
	_check("the end screen is up", ui._end.visible, true)
	_check("the summary reports kills", t.contains("42"), true)
	_check("the summary reports flips", t.contains("7"), true)
	_check("the summary names the outcome",
		t.contains("PROCESS TERMINATED"), true)
	_check("the summary lists the build", t.contains("final build"), true)
	_check("and names an exploit", t.contains("exploit_01"), true)
	r.free()
	await process_frame
	finished["the_summary_reports_a_finished_run"] = true

## A run can end holding fewer than three exploits. Indexing three
## unconditionally is how a summary crashes the screen it summarises.
func the_summary_survives_a_short_build() -> void:
	var r := await _fresh_run()
	var ui := _ui(r)
	r.loadouts[r.local_slot].exploits.clear()
	r._recompile()
	ui._on_end(true, 500)
	var t: String = ui._end.get_node("Text").text
	_check("an empty build still renders", t.contains("final build"), true)
	_check("and says so", t.contains("(none)"), true)
	_check("a win still banks its salvage", t.contains("500"), true)
	r.free()
	await process_frame
	finished["the_summary_survives_a_short_build"] = true

func the_teammate_strip_names_everyone_else() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 3, 0, 20260830)
	var r: Node2D = h.runs[0]
	var ui := _ui(r)
	ui._refresh()
	var tally: String = ui._hud.get_node("Tally").text
	_check("teammates are named", tally.contains("p1") and tally.contains("p2"), true)
	_check("the local slot is not in its own strip", tally.contains("p0"), false)
	r._die(1)
	r._park(2)
	ui._refresh()
	tally = ui._hud.get_node("Tally").text
	_check("a dead teammate reads down, a parked one away",
		tally.contains("down") and tally.contains("away"), true)
	r._return(2, r.lockstep.executed - 1)
	r._die(0)
	r._refresh_view()
	ui._refresh()
	tally = ui._hud.get_node("Tally").text
	_check("a dead local slot reads whom it spectates", tally.contains("spectating p2"), true)
	h.teardown()
	await process_frame
	finished["the_teammate_strip_names_everyone_else"] = true
