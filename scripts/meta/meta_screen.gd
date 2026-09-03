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
var _settings: Control

# ------------------------------------------------------------------- link ---
#
# The co-op lobby. It owns the Transport until START, drains the session inbox
# every frame, and hands both to the run when the session starts — the run
# reparents the transport under itself, so the connection is never dropped and
# re-made between the lobby and play. No lobby open means ./intrude is solo.

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
var _session: NetworkSession = null
var _transport: Transport = null

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
	col.add_child(_label("v%s" % _build(), 12, DIM))
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

	# Beside ./intrude rather than under it. The column already ran to roughly
	# 505px in a 720px viewport, which is what test_meta_layout measures, so a
	# settings row of its own would have been exactly the overflow that suite
	# exists to catch.
	var launch := HBoxContainer.new()
	launch.add_theme_constant_override("separation", 12)
	col.add_child(launch)

	var start := Button.new()
	start.text = "  ./intrude  --subnet 01     [ENTER]  "
	start.custom_minimum_size = Vector2(340, 42)
	start.add_theme_font_size_override("font_size", 16)
	start.pressed.connect(_start)
	launch.add_child(start)
	_start_btn = start

	var settings_btn := Button.new()
	settings_btn.text = "  settings  "
	settings_btn.custom_minimum_size = Vector2(140, 42)
	settings_btn.add_theme_font_size_override("font_size", 15)
	launch.add_child(settings_btn)

	_settings = SettingsPanel.new()
	add_child(_settings)
	settings_btn.pressed.connect(_settings.open)

	_build_link()
	start.grab_focus()

	_refresh()

## The link column, BESIDE the shop rather than under it: the shop column
## already runs close to the viewport's height, which test_meta_layout
## measures, so the lobby takes the empty right-hand side instead.
func _build_link() -> void:
	_link = VBoxContainer.new()
	_link.position = Vector2(780, 52)
	_link.add_theme_constant_override("separation", 8)
	add_child(_link)
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
	_link_status = _label("no link — ./intrude runs solo", 13, DIM)
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
	_session = NetworkSession.host_lobby(profile, rng.randi() | 1, rng.randi(), _delay_for(relay))
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
		_link_status.text = "hosting on port %d — ./intrude starts when everyone is in" \
			% SessionRules.DEFAULT_PORT
	_set_link_buttons(true)
	_refresh_players()

func _on_room_ready(code: String) -> void:
	_code_label.text = "room  %s" % code
	_copy_btn.visible = true
	_link_deadline = 0
	_link_status.text = "hosting through the relay — friends join with the code; ./intrude starts when everyone is in"

func _join() -> void:
	if _transport != null:
		return
	_profile()
	_session = NetworkSession.client_lobby()
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
	_link_status.text = "no link — ./intrude runs solo"
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
	# Only a host starts a session, and only once its server is up. A client's
	# ./intrude waits for START.
	_start_btn.disabled = linked and _session.role != NetworkSession.Role.HOST

## A client is connected to the host: introduce this profile.
func _on_connected_to_host(_id: int) -> void:
	if _session == null or _session.role != NetworkSession.Role.CLIENT:
		return
	_transport.bind_peer(Transport.HOST_PEER, 0)
	var p := _profile()
	_transport.send_control(Protocol.Message.HELLO, 0, {
		"protocol": SessionRules.PROTOCOL, "name": p["name"],
		"counters": p["counters"], "session_id": 0, "slot": -1})
	_link_status.text = "connected — waiting for a slot"

func _on_peer_left(id: int) -> void:
	if _session == null:
		return
	if _session.role == NetworkSession.Role.HOST:
		_session.remove_peer(id)
		_broadcast_welcome(-1)
		_refresh_players()
	else:
		_link_status.text = "the host went away"
		_leave()

func _process(_dt: float) -> void:
	if _transport == null or _session == null:
		return
	# _leave() resets the status line, so the reason is written after it.
	if _link_deadline > 0 and Time.get_ticks_msec() > _link_deadline and not _transport.connected():
		var why := "the relay did not answer" if _transport.relayed \
			else "no answer from %s" % SaveGame.string_pref("last_address")
		_leave()
		_link_status.text = why
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

## ./intrude: solo when no link is open; as host, freeze the roster, send START
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
	if e is InputEventKey and e.pressed and e.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		# Not while a field is being typed into: Enter there is text, not launch.
		if _name_edit != null and (_name_edit.has_focus() or _addr_edit.has_focus()):
			return
		if _start_btn != null and _start_btn.disabled:
			return
		_start()
