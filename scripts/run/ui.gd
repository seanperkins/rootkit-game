extends CanvasLayer

const FG := Color(0.78, 0.95, 0.89)
const DIM := Color(0.70, 0.84, 0.86)
const WARN := Color(1.0, 0.45, 0.42)

## Polled from the Updater autoload each _refresh, when it exists. A
## SceneTree-based suite has none, so a driver sets this directly instead —
## the same idiom run.gd uses for input_override.
var pending_update := false
var run: Node2D
var _chrome: Control
var _build_dock: HBoxContainer
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
## The before/after comparison for each enabled row, aligned with `_nav` so the
## highlight indexes both with the same pair of numbers, plus the label in each
## card that shows it. Computed once when the offer is built — a compile per
## draw frame would be the same arithmetic sixty times a second.
var _previews: Array = []
var _preview_labels: Array = []
var _decline: Button
## Which card, which of its enabled rows, or the decline button underneath them.
var _col := 0
var _row := 0

## Card navigation is edge-triggered for the analog stick: a sweep past the
## deadzone arrives as several InputEventJoypadMotion events, every one of
## which reads as "pressed", so one push used to skip three cards. A held
## direction moves once, re-arms on release, and auto-repeats slowly from
## _process while it stays held.
const NAV_ACTIONS := ["move_up", "move_down", "move_left", "move_right"]
const NAV_REPEAT_DELAY := 0.40
const NAV_REPEAT_EVERY := 0.16
var _nav_held := {}
var _nav_repeat_left := NAV_REPEAT_DELAY
var _on_decline := false
var _end: Control

func bind(r: Node2D) -> void:
	run = r
	_build()
	run.level_up_offered.connect(_on_cards)
	run.fusion_offered.connect(_on_fusion)
	run.offer_waiting.connect(_on_waiting)
	run.run_ended.connect(_on_end)
	run.stats_changed.connect(_refresh)
	_bind_updater()
	_refresh()

## The in-game version tag. A check can complete WHILE already in a run (the
## menu started it, the player hit start new run before it answered), so this
## listens for the same signal the menu's modal does, once — never polled, so
## a test can drive pending_update directly with no autoload required, the
## same idiom run.gd uses for input_override.
func _bind_updater() -> void:
	var updater := get_node_or_null("/root/Updater")
	if updater == null:
		return
	pending_update = not updater.available.is_empty()
	if not updater.update_ready.is_connected(_on_updater_ready):
		updater.update_ready.connect(_on_updater_ready)

func _on_updater_ready(_info: Dictionary) -> void:
	pending_update = true

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
	_hud.theme = TerminalStyle.build_theme()
	add_child(_hud)

	_chrome = Control.new()
	_chrome.set_script(load("res://scripts/ui/hud_chrome.gd"))
	_chrome.run = run
	_hud.add_child(_chrome)

	var status := _mono(13)
	status.name = "Status"
	status.position = Vector2(30, 25)
	_hud.add_child(status)
	var health := _mono(26)
	health.name = "HealthValue"
	health.position = Vector2(30, 43)
	_hud.add_child(health)

	var centre := _mono(14)
	centre.name = "Centre"
	centre.set_anchors_preset(Control.PRESET_TOP_WIDE)
	centre.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	centre.offset_top = 25
	centre.offset_bottom = 45
	_hud.add_child(centre)
	var clock := _mono(28)
	clock.name = "Clock"
	clock.set_anchors_preset(Control.PRESET_TOP_WIDE)
	clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	clock.offset_top = 44
	clock.offset_bottom = 82
	_hud.add_child(clock)
	var alert := _mono(12)
	alert.name = "Alert"
	alert.set_anchors_preset(Control.PRESET_TOP_WIDE)
	alert.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	alert.offset_top = 97
	alert.offset_bottom = 121
	alert.add_theme_color_override("font_color", WARN)
	_hud.add_child(alert)

	var fps := _mono(11)
	fps.name = "Fps"
	fps.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fps.offset_left = -100
	fps.offset_top = -17
	fps.offset_right = -20
	fps.offset_bottom = -2
	fps.add_theme_color_override("font_color", DIM)
	_hud.add_child(fps)

	var tally := _mono(14)
	tally.name = "Tally"
	tally.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	tally.offset_left = -278
	tally.offset_top = 25
	tally.offset_right = -28
	tally.offset_bottom = 120
	tally.add_theme_color_override("font_color", DIM)
	tally.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hud.add_child(tally)

	# The network diagnostics panel. Its own small box so it stays readable
	# over the arena; the tick rate it prints is the number a player reports.
	_net_panel = PanelContainer.new()
	_net_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_net_panel.offset_left = -380
	_net_panel.offset_top = 220
	_net_panel.offset_right = -20
	_net_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var npbg := StyleBoxFlat.new()
	npbg.bg_color = Color(0.02, 0.05, 0.04, 0.88)
	npbg.border_color = DIM
	npbg.set_border_width_all(1)
	npbg.set_content_margin_all(8)
	_net_panel.add_theme_stylebox_override("panel", npbg)
	_net_text = _mono(13)
	_net_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_net_text.add_theme_color_override("font_color", DIM)
	_net_panel.add_child(_net_text)
	_hud.add_child(_net_panel)
	# A session without a transport (a test harness, a headless gate) has
	# nothing to report and a panel that says so helps nobody; run.tscn is
	# bound before _ready, so the real lobby always delivers a transport here.
	_net_shown = run != null and run._session != null \
		and run._session.role != NetworkSession.Role.SOLO \
		and run._transport != null
	_net_panel.visible = _net_shown

	var build := _mono(11)
	build.name = "Build"
	build.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	build.position = Vector2(18, -122)
	build.add_theme_color_override("font_color", DIM)
	_hud.add_child(build)

	_build_dock = HBoxContainer.new()
	_build_dock.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_build_dock.offset_left = 16
	_build_dock.offset_right = -16
	_build_dock.offset_top = -103
	_build_dock.offset_bottom = -25
	_build_dock.add_theme_constant_override("separation", 8)
	_hud.add_child(_build_dock)
	for i in Loadout.MAX_EXPLOITS:
		var panel := PanelContainer.new()
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.mouse_filter = Control.MOUSE_FILTER_PASS
		var style := TerminalStyle.panel_style(Color(0.18, 0.37, 0.40), Color(0.015, 0.035, 0.045, 0.98))
		style.set_content_margin_all(9)
		panel.add_theme_stylebox_override("panel", style)
		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", 3)
		panel.add_child(stack)
		for field in ["Head", "Route", "Stats"]:
			var label := _mono(16 if field == "Head" else 12)
			label.name = field
			label.clip_text = true
			label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			label.add_theme_color_override("font_color", FG if field == "Head" else DIM)
			stack.add_child(label)
		_build_dock.add_child(panel)

	var version := _mono(11)
	version.name = "Version"
	version.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	version.offset_left = 18
	version.offset_top = -17
	version.offset_right = 500
	version.offset_bottom = -2
	version.add_theme_color_override("font_color", DIM)
	_hud.add_child(version)

	# The damage vignette. Screen space, because it is a fact about the player
	# rather than about a place, and it fades rather than strobes.
	_vignette = ColorRect.new()
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.color = Color(0.9, 0.1, 0.12, 0.0)
	var damage_material := ShaderMaterial.new()
	damage_material.shader = load("res://shaders/damage_vignette.gdshader")
	_vignette.material = damage_material
	_hud.add_child(_vignette)
	_hud.move_child(_vignette, 0) # damage tint belongs behind instruments

	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.visible = false
	_overlay.theme = TerminalStyle.build_theme()
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
	_pause_panel.theme = TerminalStyle.build_theme()
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

	# The same panel the shell uses. A second settings screen for the same four
	# values would be a second thing to keep in sync.
	_settings = SettingsPanel.new()
	add_child(_settings)
	_settings.closed.connect(_on_settings_closed)
	var psettings := Button.new()
	psettings.text = " settings"
	psettings.custom_minimum_size = Vector2(260, 34)
	psettings.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	psettings.alignment = HORIZONTAL_ALIGNMENT_LEFT
	psettings.focus_mode = Control.FOCUS_NONE
	pcol.add_child(psettings)
	psettings.pressed.connect(_settings.open)

	_end = Control.new()
	_end.set_anchors_preset(Control.PRESET_FULL_RECT)
	_end.visible = false
	_end.theme = TerminalStyle.build_theme()
	add_child(_end)
	var escrim := ColorRect.new()
	escrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	escrim.color = Color(0, 0, 0, 0.86)
	_end.add_child(escrim)
	# 15, not 24: the summary is fourteen rows plus the build, and at 24 it ran
	# off the bottom of a 720px viewport.
	var etext := _mono(15)
	etext.name = "Text"
	etext.position = Vector2(60, 90)
	_end.add_child(etext)
	var again := Button.new()
	again.text = "disconnect  ->  shell   [R]"
	again.position = Vector2(60, 470)
	again.custom_minimum_size = Vector2(280, 36)
	_end.add_child(again)
	again.pressed.connect(_restart)

func _refresh() -> void:
	if run == null:
		return
	var t: float = run.time_left()
	# The HUD renders the LOCAL slot only; teammates get their own strip later.
	var ls: int = run.local_slot
	var hp := int(run.player_health[ls])
	# The maximum was hardcoded in the FORMAT STRING, so no compiler caught it:
	# a memory-r10 player read "integrity 180/100".
	var maxhp := int(run._eff_integrity(ls))

	var status: Label = _hud.get_node("Status")
	status.text = "integrity                 lvl %02d\n\n\narmor %.0f   def %.0f   shield %.0f\nXP %d / %d" % [
		run.level, run._eff_armor(ls), run._eff_defense(ls), run.player_shield[ls], run.xp, run.xp_needed]
	_hud.get_node("HealthValue").text = "%d / %d" % [hp, maxhp]
	_hud.get_node("HealthValue").add_theme_color_override("font_color",
		WARN if float(hp) < float(maxhp) * 0.3 else FG)
	# Proportional, not absolute. A fixed 30 fires at 16.7% on a 180 bar.
	status.add_theme_color_override("font_color",
		WARN if float(hp) < float(maxhp) * 0.3 else FG)

	var centre: Label = _hud.get_node("Centre")
	var banner := ""
	# Name a live mini-boss — a set-piece the player does not notice arriving is
	# not a set-piece. Gated on arrival: under §6 the entity exists for the
	# whole 0.9s charge, and naming it then spoils the entrance the telegraph is
	# building.
	for i in run.enemies.count:
		if run._is_miniboss(run.enemies.type_index[i]) and not run.is_arriving(i):
			banner = "%s ACTIVE" % String(
				run.enemy_types[run.enemies.type_index[i]].id).to_upper()
			break
	if run.phase == run.Phase.CLEARED:
		banner = "COLLAPSE // REACH THE GATE"
	centre.text = "subnet %02d / %02d   //   %s" % [run.subnet,
		SpawnDirector.CAMPAIGN_SUBNETS, ["EDGE", "MEMORY", "CORE"][clampi(run.subnet - 1, 0, 2)]]
	var display_time: int = int(ceil(maxf(run.collapse_left, 0.0))) if run.phase == run.Phase.CLEARED else int(t)
	_hud.get_node("Clock").text = "%02d:%02d" % [display_time / 60, display_time % 60]
	_hud.get_node("Clock").add_theme_color_override("font_color", WARN if run.phase == run.Phase.CLEARED else FG)
	_hud.get_node("Alert").text = banner
	_chrome.alert = banner != ""

	# Display rate, not tick rate — the F1 net panel already reports the tick.
	# Engine.get_frames_per_second() is averaged over the last second, so it
	# does not flicker on a single long frame.
	var fps := Engine.get_frames_per_second()
	var fps_node: Label = _hud.get_node("Fps")
	fps_node.text = "%d fps" % fps
	fps_node.add_theme_color_override("font_color", DIM if fps >= 55 else WARN)

	var tally := "RESOURCES / NETWORK\nsalvage %-7d botnet %d\nkills %-9d flips %d" % [
		run.salvage, run.botnet.count, run.kills[ls], run.flips[ls]]
	# The stall notice: once lockstep has waited STALL_NOTICE callbacks on a
	# record, name the slots it is waiting on. Presentation only.
	if run._stalled_ticks >= SessionRules.STALL_NOTICE:
		var names := []
		for s in run.missing_slots():
			names.append(str(s))
		tally += "\nwaiting for input: %s" % ", ".join(names)
	# Recovery is presentation here and nowhere else: the notice reads session
	# state, and simulation state never carries it.
	if run._session != null and run._session.recovering():
		tally += "\nresynchronising…"
	if run._session != null and run._session.reconnecting:
		tally += "\nreconnecting… (attempt %d of %d)" % [run._reconnect_attempts,
			run.RECONNECT_ATTEMPTS]
	tally += _teammate_strip(ls)
	_hud.get_node("Tally").text = tally

	_chrome.tally_height = maxf(86.0, 26.0 + _hud.get_node("Tally").get_minimum_size().y)
	_net_panel.offset_top = 28.0 + _chrome.tally_height
	_chrome.queue_redraw()
	_hud.get_node("Build").text = "EXPLOIT BUS // %d / %d SLOTS" % [run.loadouts[ls].exploits.size(), Loadout.MAX_EXPLOITS]
	_refresh_build_dock()

	# pending_update is set once at bind() and by the update_ready signal
	# (see _bind_updater) — never polled here, so it cannot be clobbered
	# between real frames or by a test driving it directly.
	_hud.get_node("Version").text = "v%s%s" % [_version_string(),
		"  [update available]" if pending_update else ""]

	if _net_panel != null and _net_panel.visible:
		_refresh_net()

## One line per exploit of the LOCAL slot's build. Shared with the run summary,
## so the two cannot drift. `resolved` is slot-strided, so each exploit's
## compiled row is looked up by its global id.
## The strip for everyone else in the session: name, integrity or state. And
## this screen's own notices — whom it is spectating once its slot is not
## LIVE, and the leash when a teammate is holding it at the window's edge.
## Presentation only, read straight off the run.
func _teammate_strip(ls: int) -> String:
	var out := ""
	if run._session == null:
		return out
	for s in SessionRules.MAX_PLAYERS:
		if s == ls or run._session.profile(s).is_empty():
			continue
		var nm := _slot_name(s)
		match run.slot_state[s]:
			run.SlotState.LIVE:
				var hp := int(run.player_health[s])
				var mx := int(run._eff_integrity(s))
				out += "\n%-10s [%s] %3d" % [nm, _bar(float(hp) / maxf(float(mx), 1.0), 8), hp]
			run.SlotState.DEAD:
				out += "\n%-10s down" % nm
			_:
				out += "\n%-10s away" % nm
	if run.slot_state[ls] != run.SlotState.LIVE and run.view_slot != ls:
		out += "\nspectating %s — confirm cycles" % _slot_name(run.view_slot)
	elif run.slot_state[ls] == run.SlotState.LIVE:
		var held := []
		for s in SessionRules.MAX_PLAYERS:
			if s == ls or run.slot_state[s] != run.SlotState.LIVE:
				continue
			var d: Vector2 = (run.player_pos[s] - run.player_pos[ls]).abs()
			if maxf(d.x, d.y) >= SessionRules.LEASH - 1.0:
				held.append(_slot_name(s))
		if not held.is_empty():
			out += "\nat the leash: %s" % ", ".join(held)
	return out

func _slot_name(s: int) -> String:
	var nm := String(run._session.profile(s).get("name", ""))
	return nm if nm != "" else "slot %d" % s

## The network panel body. Reads transport counters and lockstep state straight
## off the run — presentation only, never the tick. The headline is the tick
## rate against wall time, because that is the slowdown: a healthy link reads
## ~60, and a starved pipeline reads 30 or less.
func _refresh_net() -> void:
	var t: Transport = run._transport
	var stats: Dictionary = t.net_stats() if t != null else {}
	var lines: Array = []
	if t == null:
		_net_text.text = "NET  no wire (offline)"
		return
	var stall_pct := 0.0
	var denom: int = run.tick + run._stalled_total
	if denom > 0:
		stall_pct = 100.0 * float(run._stalled_total) / float(denom)
	var now := Time.get_ticks_msec()
	if _net_sample_ms == 0 or now - _net_sample_ms >= 1000:
		if _net_sample_ms != 0:
			var dt := now - _net_sample_ms
			_net_tick_rate = 1000.0 * float(run.tick - _net_sample_tick) / float(dt)
			_net_recv_rate = 1000.0 * float(
				int(stats.get("records_in", 0)) - _net_recv_total) / float(dt)
			for s in SessionRules.MAX_PLAYERS:
				_net_slot_rate[s] = 1000.0 * float(
					int(stats.get("slot_records_in", {}).get(s, 0))
					- int(_net_slot_recv.get(s, 0))) / float(dt)
			var stall_delta: int = run._stalled_total - _net_stall_total
			_net_slot_stall.clear()
			if stall_delta > 0:
				for s in run._stall_slots.keys():
					var d: int = int(run._stall_slots[s]) - int(_net_prev_stall.get(s, 0))
					if d > 0:
						_net_slot_stall[int(s)] = 100.0 * float(d) / float(stall_delta)
		_net_sample_ms = now
		_net_sample_tick = run.tick
		_net_recv_total = int(stats.get("records_in", 0))
		_net_slot_recv = stats.get("slot_records_in", {}).duplicate()
		_net_stall_total = run._stalled_total
		_net_prev_stall = run._stall_slots.duplicate()
	var head: String = "NET %s  slot %d  d%d  tick %d" % [
		"host" if t.is_host else "client", run.local_slot,
		run.lockstep.delay, run.tick]
	lines.append(head)
	lines.append("rate %4.1f/s   stall %.0f%%   recv %.1f/s" % [
		_net_tick_rate, stall_pct, _net_recv_rate])
	# The delay budget versus the worst measured round trip: the one number
	# that explains the fault — a delay smaller than the RTT starves the
	# pipeline to roughly delay/RTT ticks per second.
	var worst_rtt := 0
	for s in stats.get("ping", {}).keys():
		worst_rtt = maxi(worst_rtt, int(stats.get("ping", {}).get(s, 0)))
	var budget_ms: float = float(run.lockstep.delay) * 1000.0 / 60.0
	if worst_rtt > 0:
		if worst_rtt > budget_ms:
			lines.append("flow d%d=%.0fms vs rtt %3dms  -> ~%d t/s max" % [
				run.lockstep.delay, budget_ms, worst_rtt,
				roundi(1000.0 * float(run.lockstep.delay) / float(worst_rtt))])
		else:
			lines.append("flow d%d=%.0fms vs rtt %3dms  -> ok" % [
				run.lockstep.delay, budget_ms, worst_rtt])
	for s in SessionRules.MAX_PLAYERS:
		if run._session.profile(s).is_empty():
			continue
		var nm: String = "you" if s == run.local_slot else _slot_name(s)
		var st: String = {run.SlotState.LIVE: "LIVE", run.SlotState.DEAD: "DEAD"} \
			.get(run.slot_state[s], "AWAY")
		var rtt := int(stats.get("ping", {}).get(s, 0))
		var rtt_s: String = "%3dms" % rtt if rtt > 0 else "  — "
		var path: String = "local"
		if s != run.local_slot:
			path = "direct" if not t.relayed else (
				"direct" if t.direct_to(int(t.peer_of_slot.get(s, -1))) else "relay ")
		lines.append("%-9s %-4s %s %s %5.1f/s" % [nm, st, rtt_s, path,
			float(_net_slot_rate.get(s, 0.0))])
	var relay_err: String = str(stats.get("relay_error", ""))
	var err_s: String = ("  err %s" % relay_err) if relay_err != "" else ""
	lines.append("pkts %s out/%s in  fb %d  mal %d%s" % [
		_k(int(stats.get("packets_out", 0))), _k(int(stats.get("packets_in", 0))),
		int(stats.get("direct_fallbacks", 0)), int(stats.get("malformed", 0)),
		err_s])
	if run._stalled_ticks > 0 and run._stalled_ticks >= SessionRules.STALL_NOTICE:
		var names: Array = []
		for s in run.missing_slots():
			names.append(_slot_name(s))
		lines.append("waiting on %s  %.1fs" % [", ".join(names),
			float(run._stalled_ticks) / 60.0])
	if not _net_slot_stall.is_empty():
		var parts: Array = []
		for s in _net_slot_stall.keys():
			parts.append("%s %.0f%%" % [_slot_name(int(s)), float(_net_slot_stall[s])])
		lines.append("starved by: %s" % ", ".join(parts))
	_net_text.text = "\n".join(lines)

## 1234 -> "1234", 12345 -> "12.3k": the panel's packet counts stay one word.
func _k(n: int) -> String:
	return str(n) if n < 1000 else "%.1fk" % (float(n) / 1000.0)

## The build number as a human reads it, so a dev run says so in the corner
## (0.4.2.dev) and cannot be mistaken for the release it was cut from. The
## DISPLAY form deliberately — the wire and the updater use BuildInfo.version().
func _version_string() -> String:
	return BuildInfo.display_version()

func _build_lines() -> Array:
	var lines := []
	var ls: int = run.local_slot
	var lo: Loadout = run.loadouts[ls]
	for i in lo.exploits.size():
		var r: ResolvedExploit = run.resolved[run._gid(ls, i)]
		var ex: Exploit = lo.exploits[i]
		var mods := []
		for em in ex.equipped():
			mods.append("%s%s" % [em.module.display_name,
				"" if em.rank == 1 else "·%d" % em.rank])
		if ex.vector != null and ex.trigger == null and not ex.head_is_fused():
			mods.insert(1, "(bare)")        # fires on the built-in interval
		lines.append("exploit_%02d  %s%s" % [i + 1, " + ".join(mods),
			"   [INERT]" if r.inert else "   dmg %.0f  cd %.2f  corr %.0f" % [
				r.damage, r.cooldown, r.corruption]])
	return lines

## Fixed-width slots retain the full build as a hover reference and in the
## end summary, while combat gets names, trigger and readiness at a glance.
func _refresh_build_dock() -> void:
	var ls: int = run.local_slot
	var lo: Loadout = run.loadouts[ls]
	var lines := _build_lines()
	for i in Loadout.MAX_EXPLOITS:
		var panel: PanelContainer = _build_dock.get_child(i)
		var stack := panel.get_child(0)
		if i >= lo.exploits.size():
			stack.get_node("Head").text = "%02d  EMPTY SLOT" % (i + 1)
			stack.get_node("Head").modulate.a = 0.45
			stack.get_node("Route").text = "awaiting vector"
			stack.get_node("Stats").text = "—"
			panel.tooltip_text = ""
			continue
		var ex: Exploit = lo.exploits[i]
		var r: ResolvedExploit = run.resolved[run._gid(ls, i)]
		var equipped: Array = ex.equipped()
		stack.get_node("Head").modulate.a = 1.0
		var title := "EMPTY" if equipped.is_empty() else String(equipped[0].module.display_name)
		var rank := 0 if equipped.is_empty() else int(equipped[0].rank)
		stack.get_node("Head").text = "%02d  %s ·%d" % [i + 1, title, rank]
		var route := []
		for j in range(1, equipped.size()):
			route.append(String(equipped[j].module.display_name))
		stack.get_node("Route").text = " + ".join(route) if not route.is_empty() else "built-in interval"
		var ready := "INERT" if r.inert else ("REARM" if run._fire_cd[run._gid(ls, i)] > 0.0 else "ARMED")
		stack.get_node("Stats").text = "%s  /  DMG %.0f  /  %.2fs" % [ready, r.damage, r.cooldown]
		stack.get_node("Stats").add_theme_color_override("font_color", WARN if r.inert else DIM)
		panel.tooltip_text = String(lines[i])

func _bar(f: float, w: int) -> String:
	var n := int(clampf(f, 0.0, 1.0) * w)
	return "#".repeat(n) + ".".repeat(w - n)

var _cards_data: Array = []
var _fusion_buttons: Array = []
var _recipes: PanelContainer
var _recipes_body: Label
var _vignette: ColorRect
var _pause_panel: Control
var _settings: Control
## The network diagnostics panel, top-right under the tally. F1 toggles it;
## shown by default in a session. Reads transport counters and lockstep state
## every frame — presentation only, never the tick.
var _net_panel: PanelContainer
var _net_text: Label
var _net_shown := false
var _net_sample_ms := 0
var _net_sample_tick := 0
var _net_slot_recv: Dictionary = {}
var _net_slot_rate: Dictionary = {}
var _net_tick_rate := 0.0
var _net_recv_total := 0
var _net_recv_rate := 0.0
var _net_stall_total := 0
var _net_prev_stall: Dictionary = {}
## slot -> percent of the last second's stall callbacks that were waiting on
## it, computed from _net_prev_stall deltas.
var _net_slot_stall: Dictionary = {}

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
	_previews.clear()
	_preview_labels.clear()
	for entry in _cards_data:
		var buttons: Array = []
		var previews: Array = []
		var card := _make_card(entry, buttons, previews)
		row.add_child(card)
		_cards.append(card)
		_nav.append(buttons)
		_previews.append(previews)
		_preview_labels.append(card.get_meta("preview", null))
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
## The local slot has answered its offer; teammates have not. The overlay stays
## up — the world is still held — but shows only the wait, never another
## player's cards: the HUD renders local_slot and nothing else.
func _on_waiting(unresolved: int) -> void:
	_cards_data = []
	_fusion_buttons = []
	var row: HBoxContainer = card_row()
	for c in row.get_children():
		row.remove_child(c)
		c.queue_free()
	_cards.clear()
	_nav.clear()
	_previews.clear()
	_preview_labels.clear()
	if unresolved <= 0:
		return
	_overlay.get_node("Title").text = "  waiting for %d…" % unresolved
	_overlay.visible = true

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
	_previews.clear()
	_preview_labels.clear()
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
	var lo: Loadout = run.loadouts[run.local_slot]
	for m in run._unlocked[run.local_slot]:
		unlocked[m.id] = true
	var out := []
	for r in RecipeTable.all():
		if not (unlocked.has(r.vector_id) and unlocked.has(r.trigger_id)
				and unlocked.has(r.payload_id)):
			continue
		var marks := ""
		for id in [r.vector_id, r.trigger_id, r.payload_id]:
			var at: Array = lo._slot_holding(id)
			if at.is_empty():
				marks += "[ ]"
			else:
				var em: EquippedModule = lo.exploits[at[0]].at(at[1])
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
## MAX_EXPLOITS rows — so they read differently.
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
## which after the column is fixed can only be a max-rank duplicate, an id
## already held elsewhere, or a trigger that would leave the board with nothing
## firing on its own — all three worth naming rather than greying out silently.
func _row_button(m: Module, e: int, target) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 34)
	b.add_theme_font_size_override("font_size", 12)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var sl := Exploit.slot_index_of(int(m.slot))
	var lo: Loadout = run.loadouts[run.local_slot]
	var founded: bool = e < lo.exploits.size()
	var ex: Exploit = lo.exploits[e] if founded else null
	var occupant: EquippedModule = ex.at(sl) if ex != null else null

	var mark := "·"
	var detail := ""
	var tint := OFF
	if target == null:
		if occupant != null and occupant.module.id == m.id:
			detail = "%s at max rank" % occupant.module.display_name
		elif lo.strands_auto_fire(m, e):
			# Not "the last interval": the source being protected is often a
			# BARE row, which holds no trigger module to name.
			detail = "keep one auto-firing weapon"
		elif lo.holds(m.id) >= 0:
			detail = "held in exploit_%02d" % (lo.holds(m.id) + 1)
		else:
			detail = "no room"
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
## out, and `out_previews` the resolved comparison for each of them — the two
## stay index-aligned because the keyboard indexes rows through `_nav` and reads
## the comparison with the same number. Gathered while building rather than by
## walking children afterwards: the builder already knows which rows are legal,
## and a walker would have to re-derive it from the node tree.
func _make_card(entry: Array, out_buttons: Array, out_previews: Array = []) -> Control:
	var m = entry[0]
	var targets: Array = entry[1]
	var card := PanelContainer.new()
	# A minimum height, and a spacer above the buttons in every branch below.
	# HBoxContainer already stretches all three cards to the tallest one, so
	# without the spacer a card with a short stats line floats its buttons up
	# and the rows of buttons no longer line up across the screen. The height
	# carries one 34 px button plus 7 px separation per exploit row, plus the
	# fixed comparison block — reserved rather than fitted, so navigating from
	# a one-line diff to a five-line one does not move the buttons under the
	# cursor.
	card.custom_minimum_size = Vector2(268,
		121.0 + 41.0 * Loadout.MAX_EXPLOITS + PREVIEW_LINE_H * PREVIEW_MAX_LINES)
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
	# Show the resolved comparison instead of raw contributions. A bounded
	# scrollable region keeps every replacement loss available without moving
	# the row buttons as the selection changes.
	var preview := RichTextLabel.new()
	preview.add_theme_font_size_override("normal_font_size", 11)
	preview.add_theme_color_override("default_color", FG)
	preview.custom_minimum_size = Vector2(244, PREVIEW_LINE_H * PREVIEW_MAX_LINES)
	preview.scroll_active = true
	box.add_child(preview)
	card.set_meta("preview", preview)
	box.add_child(_spacer())

	# At most one target per row now, so a row and a button are the same thing.
	var by_row := {}
	for t in targets:
		by_row[t.exploit] = t
	for e in Loadout.MAX_EXPLOITS:
		var t = by_row.get(e)
		var rb := _row_button(m, e, t)
		box.add_child(rb)
		if not rb.disabled:
			out_buttons.append(rb)
			out_previews.append(_preview_text(m, t))
	return card

## The trigger conditions as a player reads them, in enum order.
const TRIGGER_WORDS := ["interval", "on kill", "on hit", "on damage taken",
	"on low integrity", "on flip", "on level up"]

## The resolved fields worth naming, with the precision each is read in. NOT
## every STAT_KEY: a diff across all of them buries the two numbers that
## changed under twenty that did not.
const PREVIEW_FIELDS := [
	[&"damage", "damage", "%.1f"],
	[&"corruption", "corruption", "%.1f"],
	[&"radius", "radius", "%.0f"],
	[&"knockback", "knockback", "%.0f"],
	[&"travel", "travel", "%.0f"],
	[&"projectile_speed", "speed", "%.0f"],
	[&"pierce", "pierce", "%.0f"],
	[&"chain_count", "chain", "%.0f"],
	[&"split_count", "split", "%.0f"],
	[&"orbit_count", "orbit", "%.0f"],
	[&"burst", "burst", "%.0f"],
	[&"blast_radius", "blast", "%.0f"],
	[&"lifesteal", "lifesteal", "%.2f"],
	[&"execute_below", "execute", "%.2f"],
	[&"slow_amount", "slow", "%.2f"],
	[&"slow_duration", "slow time", "%.1fs"],
	[&"homing", "homing", "%.1f"],
	[&"shield", "shield", "%.0f"],
	[&"shield_rearm", "shield rearm", "%.2fs"],
	[&"ward_armor", "ward armor", "%.1f"],
	[&"ward_defense", "ward defense", "%.0f"],
	[&"ward_clock_speed", "ward speed", "%.0f"],
	[&"ward_duration", "ward time", "%.1fs"],
	[&"botnet_cap", "botnet", "%.0f"],
	[&"botnet_lifetime", "botnet time", "%.1fs"],
	[&"botnet_damage_ratio", "botnet dmg", "%.2f"],
]
## Nine visible lines; longer comparisons scroll rather than hiding losses.
const PREVIEW_MAX_LINES := 9
const PREVIEW_LINE_H := 17

## A detached copy of one row, ranks included. The preview must never touch the
## live loadout: it runs while the choice is still only highlighted, and the
## pick itself is a STAGED input record that the tick applies later.
func _clone_row(ex: Exploit) -> Exploit:
	var out := Exploit.new()
	for sl in Exploit.SLOT_COUNT:
		var em := ex.at(sl)
		if em != null:
			out.set_at(sl, EquippedModule.new(em.module, em.rank))
	return out

## What this row would actually become, compiled twice through the real build
## layer rather than described from the module's raw stats.
##
## The card used to print the module's own contributions — "cadence x0.70",
## "damage +3.00" — which is not what the player gets: a rank scales it, the
## row's other modules fold with it, the player's own multipliers scale the
## total, and two floors clamp the result. Compiling a clone means the number
## on the card is the number the run will hold, and there is no second copy of
## the arithmetic to drift from Compiler.build.
func _preview_text(m: Module, target) -> String:
	if target == null:
		return ""
	var lo: Loadout = run.loadouts[run.local_slot]
	var live: Exploit = lo.exploits[target.exploit] \
		if target.exploit < lo.exploits.size() else Exploit.new()
	var after_ex := _clone_row(live)
	if target.action == Loadout.Rule.RANK_UP:
		var em := after_ex.holds(m.id)
		if em != null:
			em.rank += 1
	else:
		# EMPTY_SLOT, a founding row and REPLACE are the same write: the column
		# is fixed by the module's slot, and Loadout._displace clears exactly
		# the occupant of that column before placing.
		after_ex.set_at(target.slot, EquippedModule.new(m))
	var comparison := Loadout.new()
	comparison.mult = lo.mult
	comparison.exploits = [live, after_ex]
	var compiled := comparison.compile_all()
	var before: ResolvedExploit = compiled[0]
	var after: ResolvedExploit = compiled[1]
	var lines := []
	if after.inert:
		lines.append("no vector: this row will not fire")
	else:
		# An event trigger's cooldown is a CEILING on how often the condition
		# may fire it, never a promise of a shot every N seconds.
		var word := "every" if after.trigger_kind == Module.TriggerKind.INTERVAL \
			else "at most every"
		if before.inert:
			lines.append("starts firing %s %.2fs" % [word, after.cooldown])
		else:
			if after.trigger_kind != before.trigger_kind:
				lines.append("fires %s -> %s" % [
					TRIGGER_WORDS[before.trigger_kind],
					TRIGGER_WORDS[after.trigger_kind]])
			if absf(after.cooldown - before.cooldown) > 1e-6:
				lines.append("%s %.2fs -> %.2fs" % [
					word, before.cooldown, after.cooldown])
			else:
				lines.append("%s %.2fs, unchanged" % [word, after.cooldown])
	for f in PREVIEW_FIELDS:
		var b := float(before.get(f[0]))
		var a := float(after.get(f[0]))
		if absf(a - b) <= 1e-6:
			continue
		lines.append("%s %s -> %s" % [f[1], f[2] % b, f[2] % a])
	return "\n".join(lines)

## A run summary rather than a verdict line. This is where a run becomes
## something the player can compare against the next one; _on_end already
## printed subnet, kills and flips, so this is an improvement on a real starting
## point rather than a rescue.
func _on_end(won: bool, salvage: int) -> void:
	_overlay.visible = false
	var t: Label = _end.get_node("Text")
	var elapsed: float = SpawnDirector.SUBNET_SECONDS - run.time_left()
	var head := "  CORE BREACHED" if won else "  PROCESS TERMINATED"
	var rows := [
		"",
		"  outcome        %s" % ("ICE terminated" if won else
			"died on subnet %d" % run.subnet),
		"  subnet         %d of %d" % [run.subnet,
			SpawnDirector.CAMPAIGN_SUBNETS],
		"  time in subnet %d:%02d" % [int(elapsed) / 60, int(elapsed) % 60],
		"  level          %d" % run.level,
		"  kills          %d" % run.kills[run.local_slot],
		"  flips          %d" % run.flips[run.local_slot],
		"  salvage        %s" % ("%d banked" % salvage if won else
			"lost since the last clear"),
		"",
		"  final build",
	]
	# Tolerates a run that ended holding fewer than three: indexing three
	# unconditionally is how a summary crashes the screen it summarises.
	var bl := _build_lines()
	if bl.is_empty():
		rows.append("    (none)")
	else:
		for line in bl:
			rows.append("    " + line)
	t.text = head + "\n" + "\n".join(rows)
	t.add_theme_color_override("font_color", FG if won else WARN)
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
		# The comparison belongs to the row the highlight is ON, so it is
		# written here rather than baked into the button: it follows the
		# selection whether the mouse or the keyboard moved it, and an unlit
		# card shows none — three sets of numbers at once is not a comparison.
		if ci < _preview_labels.size() and _preview_labels[ci] != null:
			var text := ""
			if lit and ci < _previews.size():
				var rows: Array = _previews[ci]
				if _row >= 0 and _row < rows.size():
					text = rows[_row]
			var preview := _preview_labels[ci] as RichTextLabel
			preview.text = text
			preview.scroll_to_line(0)
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
	elif e.is_action_pressed("netinfo") and _net_panel != null \
			and run != null and run._session != null \
			and run._session.role != NetworkSession.Role.SOLO:
		_toggle_netinfo()
	elif _overlay.visible:
		if e.is_action_pressed("ui_page_up") or e.is_action_pressed("ui_page_down"):
			if _col < _preview_labels.size() and _preview_labels[_col] != null:
				var preview := _preview_labels[_col] as RichTextLabel
				var bar := preview.get_v_scroll_bar()
				bar.value += bar.page * (-1.0 if e.is_action_pressed("ui_page_up") else 1.0)
			get_viewport().set_input_as_handled()
			return
		var nav := ""
		for a in NAV_ACTIONS:
			if e.is_action_released(a):
				_nav_held[a] = false
			elif e.is_action_pressed(a):
				nav = a
		if nav != "":
			if e is InputEventJoypadMotion and _nav_held.get(nav, false):
				pass                         # still the same push; see NAV_ACTIONS
			else:
				_nav_held[nav] = true
				_nav_repeat_left = NAV_REPEAT_DELAY
				_nav_move(nav)
		elif e.is_action_pressed("confirm"):      _activate()
		elif e.is_action_pressed("recipes"):      _toggle_recipes()
		else:                                     handled = false
	elif e.is_action_pressed("confirm") and run != null and run.cycle_spectate():
		# No offer owns confirm: a spectator looks through the next LIVE slot.
		pass
	else:
		handled = false
	if not handled:
		return
	var vp := get_viewport()
	if vp != null:
		vp.set_input_as_handled()

## Leaving mid-run banks nothing beyond what a death would, so it goes through
## the same _die path rather than inventing a second one.
## Solo: the local slot dies, so kills and flips still bank and the summary
## shows before the shell. Networked: leave. A death applied here would be
## a callback outside the tick that no other peer sees, so a client's exit is
## the host parking its slot, and a host's exit is the host going away.
func _abandon() -> void:
	if run == null:
		return
	run.user_paused = false
	_pause_panel.visible = false
	if run._session != null and run._session.role != NetworkSession.Role.SOLO:
		_restart()
		return
	run._die(run.local_slot)

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
	if _settings != null and _settings.visible:
		_settings.close()
	elif _recipes != null and _recipes.visible:
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

## The live run holds its own copies of the presentation prefs, so closing the
## panel has to push them across or a shake change would not take effect until
## the next run.
func _on_settings_closed() -> void:
	if run == null:
		return
	var p := SaveGame.prefs()
	run._shake_pref = float(p.get("shake", 1.0))
	run._numbers_pref = float(p.get("damage_numbers", 1.0)) > 0.5

func _toggle_pause() -> void:
	if run == null:
		return
	run.user_paused = not run.user_paused
	_pause_panel.visible = run.user_paused

func _toggle_netinfo() -> void:
	_net_shown = not _net_shown
	_net_panel.visible = _net_shown

func _nav_move(action: String) -> void:
	match action:
		"move_up":    _move_row(-1)
		"move_down":  _move_row(1)
		"move_left":  _move_card(-1)
		"move_right": _move_card(1)

## Auto-repeat for a held navigation direction on the card screen. The UI is
## presentation, so reading the device here is not a second source of truth
## for the simulation (test_input's one-place rule covers run.gd).
func _nav_repeat(d: float) -> void:
	var held := ""
	for a in NAV_ACTIONS:
		if Input.is_action_pressed(a):
			held = a
			break
	if held == "":
		_nav_repeat_left = NAV_REPEAT_DELAY
		return
	_nav_repeat_left -= d
	if _nav_repeat_left <= 0.0:
		_nav_repeat_left = NAV_REPEAT_EVERY
		_nav_move(held)

func _process(d: float) -> void:
	if run != null and _vignette != null:
		_vignette.color.a = clampf(run._vignette, 0.0, 1.0) * 0.30
	if _overlay.visible:
		_nav_repeat(d)
	if run != null and not run.paused:
		if _overlay.visible:
			_overlay.visible = false
		_refresh()
	elif run != null and run.user_paused:
		# The modal-offer guard above stops refreshing while `paused` is set,
		# which would leave the pause panel drawn over a frozen HUD.
		_refresh()
