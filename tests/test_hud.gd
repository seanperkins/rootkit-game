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
	"the_teammate_strip_names_everyone_else", "the_net_panel_is_session_only",
	"the_stall_is_attributed", "settings_from_pause_cover_the_viewport",
	"abandon_from_the_pause_menu_ends_a_solo_run"]

func _initialize() -> void:
	print("ROOTKIT — hud\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	await the_blocks_exist_and_populate()
	await integrity_warns_proportionally()
	await the_summary_reports_a_finished_run()
	await the_summary_survives_a_short_build()
	await the_teammate_strip_names_everyone_else()
	await the_net_panel_is_session_only()
	await the_stall_is_attributed()
	await settings_from_pause_cover_the_viewport()
	await abandon_from_the_pause_menu_ends_a_solo_run()
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

## The network diagnostics panel exists, is hidden for solo, shows by default
## in a session (no transport in the harness: the panel says so), and F1
## toggles it through the same method the key path calls.
func the_net_panel_is_session_only() -> void:
	var r := await _fresh_run()
	var ui := _ui(r)
	ui._refresh()
	_check("solo keeps the net panel hidden", ui._net_panel.visible, false)
	ui._toggle_netinfo()
	_check("the toggle flips hidden to shown", ui._net_panel.visible, true)
	ui._toggle_netinfo()
	r.free()
	await process_frame
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, 0, 20260830)
	var r2: Node2D = h.runs[0]
	var ui2 := _ui(r2)
	ui2._refresh()
	# The harness carries no transport, so the panel stays hidden — the real
	# lobby always attaches one before the run enters the tree.
	_check("a session with no transport keeps the panel hidden",
		ui2._net_panel.visible, false)
	ui2._toggle_netinfo()
	_check("the toggle still reveals it", ui2._net_panel.visible, true)
	ui2._refresh()
	_check("and the body names the wire", ui2._net_text.text.contains("NET"), true)
	ui2._toggle_netinfo()
	_check("F1 hides it again", ui2._net_panel.visible, false)
	h.teardown()
	await process_frame
	finished["the_net_panel_is_session_only"] = true

## The fault the net panel exists to explain: a peer's records withheld (the
## harness's wire after its controller drops), and the diagnostics must name
## that slot — the persistent one-or-two-frame stall never reaches
## STALL_NOTICE, so the cumulative per-slot attribution is the only signal.
func the_stall_is_attributed() -> void:
	var h := MultiplayerHarness.new()
	await h.setup(self, 2, 2, 20260830)
	h.withheld[1] = [0, 1000000]
	var r: Node2D = h.runs[0]
	for i in 90:
		h.step(func(_t): return [Vector2.ZERO, Vector2.ZERO])
	_check("the host stalled", r._stalled_total > 0, true)
	_check("and attributed it to the withheld slot",
		int(r._stall_slots.get(1, 0)) > 0, true)
	var miss: PackedInt32Array = r.missing_slots()
	_check("the stall names slot one", miss.has(1), true)
	_check("and never the local slot", miss.has(0), false)
	h.teardown()
	await process_frame
	finished["the_stall_is_attributed"] = true

## The settings panel anchored itself from _ready with set_anchors_preset,
## which under a CanvasLayer leaves the Control 0x0 for good: its scrim covered
## nothing and the pause menu drew straight through the settings screen.
func settings_from_pause_cover_the_viewport() -> void:
	var r := await _fresh_run()
	var ui := _ui(r)
	ui._toggle_pause()
	ui._settings.open()
	for i in 4:
		await process_frame
	var vw: float = ProjectSettings.get_setting("display/window/size/viewport_width")
	var vh: float = ProjectSettings.get_setting("display/window/size/viewport_height")
	_check("settings opens over the pause menu", ui._settings.visible, true)
	_check("and its rect spans the viewport",
		ui._settings.get_global_rect().size, Vector2(vw, vh))
	var scrim: Control = ui._settings.get_child(0)
	_check("and so does its scrim", scrim.get_global_rect().size, Vector2(vw, vh))
	ui._settings.close()
	_check("closing it leaves the pause menu up", ui._pause_panel.visible, true)
	r.free()
	await process_frame
	finished["settings_from_pause_cover_the_viewport"] = true

## The pause menu's abandon button called run._die() with no slot after the
## slots refactor gave _die one — a runtime error the button swallowed, so
## pressing it did nothing at all.
func abandon_from_the_pause_menu_ends_a_solo_run() -> void:
	var r := await _fresh_run()
	var ui := _ui(r)
	ui._toggle_pause()
	_check("the run is paused", r.user_paused, true)
	ui._abandon()
	await process_frame
	_check("abandon unpauses", r.user_paused, false)
	_check("and hides the pause menu", ui._pause_panel.visible, false)
	_check("and the local slot is dead", r.slot_state[r.local_slot], r.SlotState.DEAD)
	_check("and the solo session has ended", r._session.ended, true)
	_check("and the summary is up", ui._end.visible, true)
	r.free()
	await process_frame
	finished["abandon_from_the_pause_menu_ends_a_solo_run"] = true
