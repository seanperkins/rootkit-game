class_name SettingsPanel extends Control

## The settings screen, shared by the shell and the in-run pause panel.
##
## An OVERLAY rather than rows in the shop column: that column already ran to
## roughly 505px in a 720px viewport before this pass, which is why
## test_meta_layout exists, and four more rows would have been exactly the
## overflow that suite was written to catch.
##
## Every write goes through SaveGame.set_pref, which clamps and rejects
## non-finite on the way in — the settings screen is the only thing that writes
## prefs, so a clamp here that disagreed with _sanitise would be the second copy
## of a table CLAUDE.md already warns about.

const FG := Color(0.55, 1.0, 0.72)
const DIM := Color(0.32, 0.58, 0.45)

## key, label, step. `damage_numbers` steps by its whole range, so it reads as a
## toggle while still going through one numeric path.
const ROWS := [
	["volume_master", "master volume", 0.1],
	["volume_sfx", "sfx volume", 0.1],
	["volume_music", "music volume", 0.1],
	["shake", "screen shake", 0.25],
	["damage_numbers", "damage numbers", 1.0],
]

signal closed

var _value_labels := {}

func _ready() -> void:
	# `set_anchors_and_offsets_preset`, not `set_anchors_preset`: called from
	# _ready, the latter leaves this Control 0x0 for good — the anchors read
	# 1,1 but the rect never resolves, re-anchoring later is a no-op, and the
	# scrim covers nothing, so the pause menu (or the shop) shows straight
	# through the settings screen. test_meta_layout and test_hud measure it.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false

	# OPAQUE, and the shell's own background colour rather than black. This is
	# a modal over another menu — the pause panel and the shop column both stay
	# in the tree underneath it — so anything the scrim lets through is one
	# screen's text drawn across another's. The colour is the project's clear
	# colour, which is what the shell already paints; not a third literal.
	var scrim := ColorRect.new()
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.color = ProjectSettings.get_setting(
		"rendering/environment/defaults/default_clear_color")
	add_child(scrim)

	var col := VBoxContainer.new()
	col.position = Vector2(64, 96)
	col.add_theme_constant_override("separation", 12)
	add_child(col)

	col.add_child(_label("SETTINGS", 22, FG))
	col.add_child(_label("stored in save.json, applied immediately", 13, DIM))
	col.add_child(_spacer(10))

	for r in ROWS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var name_l := _label(r[1], 15, FG)
		name_l.custom_minimum_size = Vector2(200, 0)
		row.add_child(name_l)
		var down := _btn(" -  ")
		down.pressed.connect(_nudge.bind(r[0], -float(r[2])))
		row.add_child(down)
		var val := _label("", 15, FG)
		val.custom_minimum_size = Vector2(120, 0)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(val)
		_value_labels[r[0]] = val
		var up := _btn("  + ")
		up.pressed.connect(_nudge.bind(r[0], float(r[2])))
		row.add_child(up)
		col.add_child(row)

	col.add_child(_spacer(18))
	var back := _btn("  back   [esc]  ")
	back.custom_minimum_size = Vector2(220, 36)
	back.pressed.connect(close)
	col.add_child(back)
	_refresh()

func _label(t: String, size: int, c: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	return l

func _spacer(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	return s

func _btn(t: String) -> Button:
	var b := Button.new()
	b.text = t
	b.custom_minimum_size = Vector2(52, 30)
	b.focus_mode = Control.FOCUS_NONE
	return b

func _nudge(key: String, delta: float) -> void:
	SaveGame.set_pref(key, float(SaveGame.prefs()[key]) + delta)
	SaveGame.save_state()
	_refresh()
	apply()

func _refresh() -> void:
	var p := SaveGame.prefs()
	for key in _value_labels:
		var v := float(p[key])
		if key == "damage_numbers":
			_value_labels[key].text = "on" if v > 0.5 else "off"
		elif key == "shake":
			_value_labels[key].text = "off" if v <= 0.0 else "%.2fx" % v
		else:
			_value_labels[key].text = "%d%%" % int(round(v * 100.0))

## Push the audio prefs at the engine. The bus guard lives in sfx.gd, because a
## missing bus returns -1 and set_bus_volume_db(-1, x) errors on every press —
## and it emits ERROR:, not SCRIPT ERROR:, so the test runner would not see it.
func apply() -> void:
	var p := SaveGame.prefs()
	var sfx := load("res://scripts/audio/sfx.gd")
	sfx.apply_volume(float(p["volume_sfx"]))
	var music := load("res://scripts/audio/music.gd")
	music.apply_volume(float(p["volume_music"]))
	var master := AudioServer.get_bus_index("Master")
	if master >= 0:
		var lin := float(p["volume_master"])
		AudioServer.set_bus_mute(master, lin <= 0.0)
		AudioServer.set_bus_volume_db(master, linear_to_db(maxf(lin, 0.0001)))

func open() -> void:
	_refresh()
	visible = true

func close() -> void:
	visible = false
	emit_signal("closed")
