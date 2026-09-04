extends Control

## The between-runs shell. A hub menu: start a run, continue (not yet), join
## the lobby, shop the permanent upgrades, or quit. The old single screen —
## shop, launches and lobby in one column — became three: what is permanent
## goes to the upgrades page, what is online goes to the multiplayer page, and
## the hub is just the six choices. Salvage banked by clearing a subnet is
## spent here, so the meta economy has somewhere to land.

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
var _settings: Control

# ------------------------------------------------------------------ pages --
# _page_open is "" while the hub shows; otherwise exactly that page shows and
# the hub hides. Settings and the update modal sit ABOVE both as overlays.
var _hub: VBoxContainer
var _pages := {}
var _page_open := ""
var _version_label: Label
var _link_start_btn: Button

# ------------------------------------------------------------------- link ---
#
# The co-op lobby. It owns the Transport until START, drains the session inbox
# every frame, and hands both to the run when the session starts — the run
# reparents the transport under itself, so the connection is never dropped and
# re-made between the lobby and play. No lobby open means the hub's start new
# run is solo.

var _link: VBoxContainer
var _name_edit: LineEdit
var _addr_edit: LineEdit
var _host_btn: Button
var _host_lan_btn: Button
var _code_label: Label
var _copy_btn: Button
## When a relay link that has not answered yet gives up (ticks msec), 0 = none.
var _link_deadline := 0
var _join_btn: Button
var _leave_btn: Button
var _start_btn: Button
var _players: Label
var _link_status: Label

# ----------------------------------------------------------------- update --
# On the menu, an update is loud: a scrimmed modal with install now / on quit
# (or move-to-/Applications when translocated) plus not-now. In a run the menu
# scene does not exist, so the HUD's version tag is the in-game signal.
var _update_modal: Control
## Set only by _on_update_ready — the single source the version tag and the
## modal both read, so a suite with no Updater autoload can still drive both
## by calling the handler directly, exactly as the real signal would.
var _update_available := false
var _update_body: Label
var _update_status: Label
var _update_now_btn: Button
var _update_quit_btn: Button
var _update_move_btn: Button
var _session: NetworkSession = null
var _transport: Transport = null

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.016, 0.031, 0.027)
	add_child(bg)

	# Created here (not added yet) so _build_hub can bind its settings button
	# to a real object; added to the tree below, AFTER the hub and pages, so
	# it still draws on top of them once open() makes it visible.
	_settings = SettingsPanel.new()

	_build_hub()
	_build_version_label()
	_build_shop_page()
	_build_link_page()

	add_child(_settings)
	_build_update_modal()

	# Updater is the autoload, so it survives the menu -> run scene swap and
	# can apply-on-quit from inside a run. The menu re-enters this scene every
	# time a run ends, so guard the connections. Headless suites drive this
	# scene without a project main loop, so the autoload may simply not exist.
	if not OS.has_feature("headless"):
		var updater := get_node_or_null("/root/Updater")
		if updater != null and not updater.update_ready.is_connected(_on_update_ready):
			updater.update_ready.connect(_on_update_ready)
			updater.update_state.connect(_on_update_state)
			updater.update_failed.connect(_on_update_failed)
		# This menu may be the SECOND one this process (a run just ended): the
		# autoload kept whatever it found, so re-show it; a fresh process gets
		# the background check.
		if updater != null and not updater.available.is_empty():
			_on_update_ready(updater.available)
		else:
			updater.begin_check()

	_refresh()

## The hub: a centred column of the six entries. Continue Run is disabled until
## mid-run state can actually be saved — sessions are seeded and deterministic,
## but no checkpoint exists, so a "continue" would be a new run with a borrowed
## title.
func _build_hub() -> void:
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	_hub = VBoxContainer.new()
	_hub.add_theme_constant_override("separation", 12)
	centre.add_child(_hub)

	var title := _label("ROOTKIT", 30, FG)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hub.add_child(title)
	var sub := _label("rogue process // corporate network // subnet 01", 14, DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hub.add_child(sub)
	_hub.add_child(_spacer(26))

	_start_btn = _menu_button("start new run")
	_start_btn.pressed.connect(_start)
	_hub.add_child(_start_btn)

	var continue_btn := _menu_button("continue run")
	continue_btn.disabled = true
	continue_btn.tooltip_text = "no saved run - mid-run checkpoints do not exist yet"
	_hub.add_child(continue_btn)

	var multi_btn := _menu_button("multiplayer")
	multi_btn.pressed.connect(_open_page.bind("multiplayer"))
	_hub.add_child(multi_btn)

	var shop_btn := _menu_button("upgrades")
	shop_btn.pressed.connect(_open_page.bind("upgrades"))
	_hub.add_child(shop_btn)

	var settings_btn := _menu_button("settings")
	settings_btn.pressed.connect(_settings.open)
	_hub.add_child(settings_btn)

	var exit_btn := _menu_button("exit")
	exit_btn.pressed.connect(_quit)
	_hub.add_child(exit_btn)

	_start_btn.grab_focus()

## Lower right on every menu view. A pending update lights the [update
## available] tag next to it — the modal is the loud path while the player is
## on the menu; the tag is what a dismissed modal leaves behind.
func _build_version_label() -> void:
	_version_label = _label("v%s" % _build(), 13, DIM)
	_version_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_version_label.offset_left = -220
	_version_label.offset_top = -42
	_version_label.offset_right = -20
	_version_label.offset_bottom = -12
	_version_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_version_label)
	_refresh_version_tag()

func _refresh_version_tag() -> void:
	_version_label.text = "v%s%s" % [_build(),
		"  [update available]" if _update_available else ""]

## The shop: salvage, permanent upgrades, unlocks. No launch button — starting
## is the hub's job.
func _build_shop_page() -> void:
	var page := VBoxContainer.new()
	page.position = Vector2(64, 52)
	page.add_theme_constant_override("separation", 10)
	page.visible = false
	_pages["upgrades"] = page
	add_child(page)

	var back := _menu_button("back")
	back.custom_minimum_size = Vector2(220, 36)
	back.add_theme_font_size_override("font_size", 15)
	back.pressed.connect(_back)
	page.add_child(back)
	page.add_child(_spacer(10))

	_salvage = _label("", 18, HOT)
	page.add_child(_salvage)
	page.add_child(_spacer(6))
	page.add_child(_label("UPGRADES  ::  permanent, applied at run start", 13, DIM))
	page.add_child(_spacer(4))

	# Eight rows at 40px each is 320px of a column, so the rows scroll and the
	# page does not. The explicit height is load-bearing: an unbounded
	# ScrollContainer adopts its content's minimum height and would push the
	# back button (or the whole page) off-screen. test_meta_layout measures a
	# page that fits the viewport rather than trusting the number.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(680, 240)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(scroll)

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

	page.add_child(_spacer(14))
	page.add_child(_label("UNLOCKS  ::  earned in-run, banked on a clear", 13, DIM))
	_status = _label("", 13, DIM)
	page.add_child(_status)

## The multiplayer page: the lobby content that used to sit beside the shop,
## plus its own start-session button, plus a way back.
func _build_link_page() -> void:
	var page := VBoxContainer.new()
	page.position = Vector2(64, 52)
	page.add_theme_constant_override("separation", 8)
	page.visible = false
	_pages["multiplayer"] = page
	add_child(page)

	var back := _menu_button("back")
	back.custom_minimum_size = Vector2(220, 36)
	back.add_theme_font_size_override("font_size", 15)
	back.pressed.connect(_back)
	page.add_child(back)
	page.add_child(_spacer(10))

	_link = VBoxContainer.new()
	_link.add_theme_constant_override("separation", 8)
	page.add_child(_link)
	_link.add_child(_label("LINK  ::  online co-op", 14, DIM))
	_link.add_child(_spacer(6))

	_link.add_child(_label("handle", 12, DIM))
	_name_edit = LineEdit.new()
	_name_edit.custom_minimum_size = Vector2(300, 30)
	_name_edit.max_length = SessionRules.NAME_MAX
	_name_edit.text = SaveGame.string_pref("display_name")
	_name_edit.placeholder_text = "display name"
	_link.add_child(_name_edit)

	_link.add_child(_label("room code or address", 12, DIM))
	_addr_edit = LineEdit.new()
	_addr_edit.custom_minimum_size = Vector2(300, 30)
	_addr_edit.max_length = SessionRules.ADDRESS_MAX
	_addr_edit.text = SaveGame.string_pref("last_address")
	_addr_edit.placeholder_text = "room code or address"
	_link.add_child(_addr_edit)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_link.add_child(row)
	_host_btn = Button.new()
	_host_btn.text = "  host  "
	_host_btn.custom_minimum_size = Vector2(120, 34)
	_host_btn.pressed.connect(_host)
	row.add_child(_host_btn)
	_host_lan_btn = Button.new()
	_host_lan_btn.text = "  host LAN  "
	_host_lan_btn.custom_minimum_size = Vector2(120, 34)
	_host_lan_btn.pressed.connect(_host_lan)
	row.add_child(_host_lan_btn)
	_join_btn = Button.new()
	_join_btn.text = "  join  "
	_join_btn.custom_minimum_size = Vector2(120, 34)
	_join_btn.pressed.connect(_join)
	row.add_child(_join_btn)
	_leave_btn = Button.new()
	_leave_btn.text = "  leave  "
	_leave_btn.custom_minimum_size = Vector2(120, 34)
	_leave_btn.pressed.connect(_leave)
	_leave_btn.disabled = true
	row.add_child(_leave_btn)

	_link.add_child(_spacer(6))
	_link.add_child(_label("players", 12, DIM))
	_players = _label("", 14, FG)
	_players.custom_minimum_size = Vector2(440, 0)
	_link.add_child(_players)
	_link_status = _label("no link - the hub's start new run runs solo", 13, DIM)
	_link_status.custom_minimum_size = Vector2(440, 0)
	_link_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_link.add_child(_link_status)

	# The room code, large enough to read aloud, with a copy button; both
	# empty until the relay answers a host.
	_code_label = _label("", 22, FG)
	_link.add_child(_code_label)
	_copy_btn = Button.new()
	_copy_btn.text = "  copy code  "
	_copy_btn.custom_minimum_size = Vector2(120, 30)
	_copy_btn.visible = false
	_copy_btn.pressed.connect(func(): DisplayServer.clipboard_set(_transport.code if _transport != null else ""))
	_link.add_child(_copy_btn)

	# The lobby's own start, for a host about to go; solo runs start from the
	# hub. A client waits for the host, so the button is disabled in
	# _set_link_buttons.
	var start_row := HBoxContainer.new()
	start_row.add_theme_constant_override("separation", 12)
	_link.add_child(start_row)
	_link_start_btn = _menu_button("start session")
	_link_start_btn.pressed.connect(_start)
	start_row.add_child(_link_start_btn)

## The update modal: a scrimmed panel over the menu. On the MENU an update is
## loud — a pending version is game-changing enough to interrupt the hub. In a
## run the modal does not exist (the menu scene is gone); the HUD's version
## tag is the in-game signal instead.
func _build_update_modal() -> void:
	_update_modal = Control.new()
	_update_modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_update_modal.visible = false
	add_child(_update_modal)
	var scrim := ColorRect.new()
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	# OPAQUE, and the shell's own background colour rather than a translucent
	# black: the hub stays in the tree underneath (page-switch precedent), so
	# anything the scrim lets through is hub text drawn across the modal —
	# exactly the bug settings_panel.gd's own scrim comment warns about.
	scrim.color = ProjectSettings.get_setting(
		"rendering/environment/defaults/default_clear_color")
	_update_modal.add_child(scrim)
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	_update_modal.add_child(centre)
	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 12)
	centre.add_child(panel)
	_update_body = _label("", 15, FG)
	_update_body.custom_minimum_size = Vector2(540, 0)
	_update_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_update_body)
	_update_status = _label("", 13, DIM)
	_update_status.custom_minimum_size = Vector2(540, 22)
	_update_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_update_status)
	panel.add_child(_spacer(6))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)
	_update_now_btn = Button.new()
	_update_now_btn.text = "  install & restart  "
	_update_now_btn.custom_minimum_size = Vector2(170, 36)
	_update_now_btn.pressed.connect(_install_now)
	row.add_child(_update_now_btn)
	_update_quit_btn = Button.new()
	_update_quit_btn.text = "  apply on quit  "
	_update_quit_btn.custom_minimum_size = Vector2(150, 36)
	_update_quit_btn.pressed.connect(_install_on_quit)
	row.add_child(_update_quit_btn)
	_update_move_btn = Button.new()
	_update_move_btn.text = "  move to /Applications  "
	_update_move_btn.custom_minimum_size = Vector2(200, 36)
	_update_move_btn.pressed.connect(_move_to_applications)
	row.add_child(_update_move_btn)
	var later := Button.new()
	later.text = "  not now  "
	later.custom_minimum_size = Vector2(120, 36)
	later.pressed.connect(func() -> void: _update_modal.visible = false)
	row.add_child(later)

## Page switching: one page visible at a time, the hub otherwise.
func _open_page(name: String) -> void:
	_page_open = name
	_hub.visible = false
	for p in _pages:
		_pages[p].visible = (p == name)

func _back() -> void:
	_page_open = ""
	for p in _pages:
		_pages[p].visible = false
	_hub.visible = true
	_start_btn.grab_focus()

func _quit() -> void:
	# A pending apply-on-quit update must run even when the exit is a menu
	# button rather than the window close control — the updater hooks
	# WM_CLOSE_REQUEST, not SceneTree quitting on its own.
	get_tree().root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	get_tree().quit()

func _menu_button(text: String) -> Button:
	var b := Button.new()
	b.text = "  %s  " % text
	b.custom_minimum_size = Vector2(380, 46)
	b.add_theme_font_size_override("font_size", 16)
	return b

## Six characters from the code alphabet route through the relay; anything
## else is a direct address.
func _wants_relay(text: String) -> bool:
	return RelayFrame.is_code(text)

## One extra tick of input delay for the hop through the relay.
func _delay_for(relay: bool) -> int:
	return SessionRules.RELAY_DELAY if relay else SessionRules.DEFAULT_DELAY

## Whatever the fields say, as the save will keep it: sanitised on write.
func _profile() -> Dictionary:
	SaveGame.set_string_pref("display_name", _name_edit.text)
	SaveGame.set_string_pref("last_address", _addr_edit.text)
	SaveGame.save_state()
	return {"slot": 0, "name": SaveGame.string_pref("display_name"),
		"counters": SaveGame.session_counters()}

## The update modal's actions. The player is on the menu when they press
## these — a session is never interrupted; apply happens either right away
## (spawn helper, restart) or at the next quit (the autoload's close hook).
func _install_now() -> void:
	_update_now_btn.disabled = true
	_update_quit_btn.disabled = true
	Updater.install_now()

func _install_on_quit() -> void:
	_update_now_btn.disabled = true
	_update_quit_btn.disabled = true
	Updater.install_on_quit()

## A quarantined zip-launched app runs from a randomized read-only mount; the
## update can only swap the bundle where it lives after the player moves it.
## /Applications needs admin for this, hence the osascript prompt.
func _move_to_applications() -> void:
	var exe := OS.get_executable_path()
	var idx := exe.find("ROOTKIT.app")
	if idx <= 0:
		_update_status.text = "could not find the app bundle to move"
		return
	var src := exe.substr(0, idx + "ROOTKIT.app".length())
	var cmd := "ditto \"%s\" \"/Applications/ROOTKIT.app\" && rm -rf \"%s\"" % [src, src]
	var ok := OS.execute("osascript", ["-e",
		"do shell script \"%s\" with administrator privileges" % cmd.replace("\"", "\\\"")])
	_update_status.text = "now quit and relaunch ROOTKIT from /Applications" if ok == 0 \
		else "could not move it — drag ROOTKIT.app into /Applications and relaunch"

func _on_update_ready(info: Dictionary) -> void:
	_update_available = true
	_update_body.text = "a new version of ROOTKIT is available - v%s (you are on v%s)" \
		% [str(info.get("version", "?")), _build()]
	_update_status.text = ""
	_update_move_btn.visible = Updater.translocated()
	_update_now_btn.visible = not _update_move_btn.visible
	_update_quit_btn.visible = not _update_move_btn.visible
	_update_modal.visible = true
	_refresh_version_tag()

func _on_update_state(text: String) -> void:
	_update_status.text = text
	_update_modal.visible = true

func _on_update_failed(reason: String) -> void:
	# A background check failing (offline, blocked CDN) is normal and common;
	# only failures on a path the player clicked deserve the modal.
	if not Updater.user_requested:
		return
	_update_status.text = reason
	_update_modal.visible = true

func _host() -> void:
	_start_hosting(true)

func _host_lan() -> void:
	_start_hosting(false)

## Host through the relay (a room code friends type) or directly on
## DEFAULT_PORT (LAN, or a forwarded port).
func _start_hosting(relay: bool) -> void:
	if _transport != null:
		return
	var profile := _profile()
	# The session id and seed are the HOST's choice, made once here — outside
	# the simulation, so a real random source is fine.
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_session = NetworkSession.host_lobby(profile, rng.randi() | 1, rng.randi(),
		_delay_for(relay), SessionRules.CHOICE_TIMEOUT_TICKS, _build())
	_transport = Transport.new()
	add_child(_transport)
	var err: Error
	if relay:
		err = _transport.host_relayed(_session)
	else:
		err = _transport.host(SessionRules.DEFAULT_PORT, _session)
	if err != OK:
		if relay:
			_link_status.text = "the relay is not reachable (%s)" % error_string(err)
		else:
			_link_status.text = "could not bind port %d (%s)" % [SessionRules.DEFAULT_PORT,
				error_string(err)]
		_transport.queue_free()
		_transport = null
		_session = null
		return
	_transport.peer_left.connect(_on_peer_left)
	if relay:
		_transport.room_ready.connect(_on_room_ready)
		_link_status.text = "asking the relay for a room…"
		_link_deadline = Time.get_ticks_msec() + 5000
	else:
		_link_status.text = "hosting on port %d — the host's start begins when everyone is in" \
			% SessionRules.DEFAULT_PORT
	_set_link_buttons(true)
	_refresh_players()

func _on_room_ready(code: String) -> void:
	_code_label.text = "room  %s" % code
	_copy_btn.visible = true
	_link_deadline = 0
	_link_status.text = "hosting through the relay — friends join with the code; the host starts when everyone is in"

func _join() -> void:
	if _transport != null:
		return
	_profile()
	_session = NetworkSession.client_lobby(_build())
	_transport = Transport.new()
	add_child(_transport)
	var addr := SaveGame.string_pref("last_address")
	var relay := _wants_relay(addr)
	var err: Error
	if relay:
		err = _transport.join_relayed(addr, _session)
	else:
		err = _transport.join(addr, SessionRules.DEFAULT_PORT, _session)
	if err != OK:
		_link_status.text = "could not start a link to %s (%s)" % [addr, error_string(err)]
		_transport.queue_free()
		_transport = null
		_session = null
		return
	_transport.peer_joined.connect(_on_connected_to_host)
	_transport.peer_left.connect(_on_peer_left)
	_link_deadline = Time.get_ticks_msec() + 5000
	if relay:
		_link_status.text = "joining room %s…" % RelayFrame.normalise_code(addr)
	else:
		_link_status.text = "connecting to %s…" % addr
	_set_link_buttons(true)

func _leave() -> void:
	if _transport == null:
		return
	if _session != null and _session.role == NetworkSession.Role.CLIENT \
			and _session.local_slot >= 0:
		_transport.send_control(Protocol.Message.LEAVE, 0, {"slot": _session.local_slot})
		_transport.poll()
	_transport.close()
	_transport.queue_free()
	_transport = null
	_session = null
	_link_deadline = 0
	_code_label.text = ""
	_copy_btn.visible = false
	_link_status.text = "no link - the hub's start new run runs solo"
	_players.text = ""
	_set_link_buttons(false)
	_start_btn.disabled = false

func _set_link_buttons(linked: bool) -> void:
	_host_btn.disabled = linked
	_host_lan_btn.disabled = linked
	_join_btn.disabled = linked
	_leave_btn.disabled = not linked
	_name_edit.editable = not linked
	_addr_edit.editable = not linked
	# Only a host starts a session - a client waits for START.
	_start_btn.disabled = linked and _session.role != NetworkSession.Role.HOST
	if _link_start_btn != null:
		_link_start_btn.disabled = linked and _session.role != NetworkSession.Role.HOST

## A client is connected to the host: introduce this profile.
func _on_connected_to_host(_id: int) -> void:
	if _session == null or _session.role != NetworkSession.Role.CLIENT:
		return
	_transport.bind_peer(Transport.HOST_PEER, 0)
	var p := _profile()
	_transport.send_control(Protocol.Message.HELLO, 0, {
		"protocol": SessionRules.PROTOCOL, "name": p["name"],
		"counters": p["counters"], "session_id": 0, "slot": -1,
		"version": _build()})
	_link_status.text = "connected — waiting for a slot"

func _on_peer_left(id: int) -> void:
	if _session == null:
		return
	if _session.role == NetworkSession.Role.HOST:
		_session.remove_peer(id)
		_broadcast_welcome(-1)
		_refresh_players()
	else:
		# A link cut before any WELCOME assigned a slot is the host refusing
		# this build at the envelope (old host, new client) or cutting us off;
		# the REFUSED message can only travel between builds that share the
		# enum, so name the likely cause. Capture the flag FIRST: _leave()
		# nulls the session, so reading it after would turn every client
		# disconnect — including a fully admitted one — into a version hint.
		var never_admitted := _session.local_slot < 0
		_link_status.text = "the host went away"
		_leave()
		if never_admitted:
			_link_status.text = "the host closed the link — it may be a different game version; check for updates"

func _process(_dt: float) -> void:
	if _transport == null or _session == null:
		return
	# _leave() resets the status line, so the reason is written after it.
	if _link_deadline > 0 and Time.get_ticks_msec() > _link_deadline and not _transport.connected():
		var why := "the relay did not answer" if _transport.relayed \
			else "no answer from %s" % SaveGame.string_pref("last_address")
		_leave()
		# An OLD build cannot decode REFUSED (its Message enum is shorter), so
		# the version-skew case that can never produce a message is a silent
		# dead link — treat it as probable skew too, like the explicit one.
		_link_status.text = "%s — it may be an older game version; check for updates" % why
		return
	if _transport.relayed and _transport.relay_error != "":
		var reason: String = {"unknown": "no room with that code", "full": "that room is full",
			"closed": "the host closed the room", "bad": "the relay refused the link (version mismatch?)",
			"lost": "lost the relay"}.get(_transport.relay_error, _transport.relay_error)
		_leave()
		_link_status.text = reason
		return
	_transport.poll()
	# poll() delivers peer_disconnected synchronously, and a client's handler
	# calls _leave(), which nulls the session and the transport. Draining a
	# session that just went away would be a crash on the next line.
	if _session == null or _transport == null:
		return
	while not _session.inbox.is_empty():
		var msg: Dictionary = _session.inbox.pop_front()
		_handle(int(msg["kind"]), msg["body"], int(msg["peer"]))

func _handle(kind: int, body: Dictionary, peer: int) -> void:
	match kind:
		Protocol.Message.HELLO:
			if _session.role != NetworkSession.Role.HOST:
				return
			var slot := _session.admit(body, peer)
			if slot == NetworkSession.ADMIT_VERSION_MISMATCH:
				# Same wire protocol, different build: a lockstep friend that
				# has not updated would desync. Name the build, then cut the
				# link — the joiner's client shows the reason in the lobby.
				_transport.send_control(Protocol.Message.REFUSED, 0,
					{"reason": "build", "build": _build()}, peer)
				_transport.peer.disconnect_peer(peer)
				return
			if slot < 0:
				_transport.peer.disconnect_peer(peer)
				return
			_transport.bind_peer(peer, slot)
			_transport.send_control(Protocol.Message.WELCOME, 0,
				{"descriptor": _session.lobby_descriptor(), "slot": slot}, peer)
			_broadcast_welcome(peer)
			_refresh_players()
		Protocol.Message.WELCOME:
			if _session.role != NetworkSession.Role.CLIENT:
				return
			if _session.apply_welcome(body):
				_link_status.text = "in the lobby as slot %d — waiting for the host to start" \
					% _session.local_slot
				_refresh_players()
			elif _session.reject_reason == "version":
				_leave()
				_link_status.text = "the host is running v%s — you are on v%s; update to play together" \
					% [str(body.get("descriptor", {}).get("version", "?")), _build()]
		Protocol.Message.START:
			if _session.role != NetworkSession.Role.CLIENT:
				return
			if _session.apply_start(body):
				_launch_session()
			else:
				_link_status.text = "the host started a session this link does not belong to"
		Protocol.Message.LEAVE:
			if _session.role == NetworkSession.Role.HOST:
				_session.remove_peer(peer)
				_transport.peer.disconnect_peer(peer)
				_broadcast_welcome(-1)
				_refresh_players()
		Protocol.Message.REFUSED:
			if _session.role != NetworkSession.Role.CLIENT:
				return
			if str(body.get("reason", "")) != "build":
				return
			_leave()
			_link_status.text = "the host runs v%s — you are on v%s; update to play together" \
				% [str(body.get("build", "?")), _build()]

## Refresh every OTHER peer's roster after a change; the joining peer already
## has its own WELCOME with its slot.
func _broadcast_welcome(except: int) -> void:
	for id in _transport.slot_of_peer.keys():
		if int(id) == except:
			continue
		_transport.send_control(Protocol.Message.WELCOME, 0,
			{"descriptor": _session.lobby_descriptor(), "slot": -1}, int(id))

func _refresh_players() -> void:
	if _session == null:
		_players.text = ""
		return
	var lines := []
	for row in _session.lobby_rows:
		var tag := "  (you)" if int(row["slot"]) == _session.local_slot else ""
		lines.append("slot %d   %s%s" % [int(row["slot"]),
			row["name"] if String(row["name"]) != "" else "anonymous", tag])
	_players.text = "\n".join(lines)

## Hand the live session and its connection to the run and replace the scene.
## The transport is reparented, not recreated: the same ENet peers carry the
## lobby and the game.
func _launch_session() -> void:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	run.configure_session(_session)
	remove_child(_transport)
	run.add_child(_transport)
	run.attach_transport(_transport)
	_transport = null
	var tree := get_tree()
	tree.root.add_child(run)
	var old := tree.current_scene
	tree.current_scene = run
	if old != null:
		old.queue_free()
	elif is_inside_tree():
		queue_free()

func _exit_tree() -> void:
	if _transport != null:
		_transport.close()

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

## The build number: release_mac.sh stamps the git tag into
## application/config/version, so this reads the tag in release builds and the
## project file's value in dev.
func _build() -> String:
	var v: Variant = ProjectSettings.get_setting("application/config/version")
	return "dev" if v == null else String(v)

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
	# EXACTLY UNLOCK_ROWS + 1 lines, always. The panel sits above the back
	# button in a fixed layout, so a list that grows with the table pushes the
	# page past the bottom of the screen — which is what fourteen locked
	# modules did.
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

## Start: solo when no link is open; as host, freeze the roster, send START
## to every peer and go; as client, nothing — the host starts.
func _start() -> void:
	if _transport == null or _session == null:
		get_tree().change_scene_to_file("res://scenes/run.tscn")
		return
	if _session.role != NetworkSession.Role.HOST:
		return
	var desc := _session.start()
	if desc.is_empty():
		_link_status.text = "the lobby could not be frozen into a session"
		return
	_transport.send_control(Protocol.Message.START, 0, {"descriptor": desc, "slot": -1})
	_transport.poll()
	_launch_session()

func _input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed):
		return
	if e.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		# Not while a field is being typed into: Enter there is text, not launch.
		if _name_edit != null and (_name_edit.has_focus() or _addr_edit.has_focus()):
			return
		# The shop page has nothing to start; Enter is the start only on the hub
		# and in the lobby.
		if _page_open != "" and _page_open != "multiplayer":
			return
		if _start_btn != null and _start_btn.disabled:
			return
		_start()
	elif e.keycode == KEY_ESCAPE:
		if _update_modal.visible:
			_update_modal.visible = false
		elif _settings.visible:
			_settings.close()
		elif _page_open != "":
			_back()
