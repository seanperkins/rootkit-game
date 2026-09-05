extends Node2D

## Presentation only. Reads tick-addressed transfer state; animation never
## moves a player or decides when a transfer commits.
const CYAN := Color(0.35, 1.55, 1.8)
const BLUE := Color(0.25, 0.65, 1.45)
const DARK := Color(0.018, 0.045, 0.068)
var target: Node2D
var _time := 0.0
var _activation := 0.0
var _was_open := false
var _hologram: Node2D

func _ready() -> void:
	_hologram = Node2D.new()
	_hologram.z_index = 9
	_hologram.draw.connect(_draw_hologram)
	add_child(_hologram)

func _process(dt: float) -> void:
	_time += minf(dt, 0.1)
	if target == null or target.terrain == null: return
	var gate: Terrain.Gate = target.terrain.gate()
	var opened := gate != null and gate.open
	if opened and not _was_open: _activation = 0.0
	_activation = minf(_activation + minf(dt, 0.1), 1.0) if opened else 0.0
	_was_open = opened
	queue_redraw()
	# Remove the upper canvas entirely when no transfer geometry is visible.
	_hologram.visible = _pad_visible() or (target.transfer_ticks > 0 and target.transfer_ticks <= 36)
	_hologram.queue_redraw()

func _ring(at: Vector2, radius: float, height: float, begin: float, length: float, color: Color, width: float, canvas: Node2D) -> void:
	var points := PackedVector2Array()
	for i in 25:
		var a := begin + length * float(i) / 24.0
		points.append(target.to_iso(at + Vector2(cos(a), sin(a)) * radius) - Vector2(0, height))
	canvas.draw_polyline(points, color, width, true)

func _poly(at: Vector2, radius: float, height: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in 8:
		var a := TAU * i / 8.0 + PI / 8.0
		out.append(target.to_iso(at + Vector2(cos(a), sin(a)) * radius) - Vector2(0, height))
	return out

func _pad_visible() -> bool:
	return target != null and target.terrain != null and target.terrain.has_gate() \
		and target._visible_world_rect().grow(220).has_point(target.terrain.teleporter_pos()) \
		and not target.terrain.is_void(target.terrain.teleporter_pos())

func _draw() -> void:
	if target == null or target.terrain == null: return
	_draw_room_floor()
	_draw_room_reward()
	if not _pad_visible(): return
	var at: Vector2 = target.terrain.teleporter_pos()
	var powered: bool = target.terrain.gate().open
	var charge := clampf(float(90 - target.transfer_ticks) / 54.0, 0.0, 1.0) if target.transfer_ticks > 36 else 0.0
	var energy := (0.7 + 0.3 * sin(_time * 2.4)) * _activation + charge
	var hue := CYAN if powered else Color(0.15, 0.29, 0.34)
	var bottom := _poly(at, 114, 0)
	var top := _poly(at, 110, 9)
	draw_colored_polygon(bottom, Color(0.008, 0.018, 0.028))
	draw_colored_polygon(top, DARK)
	for i in 8:
		draw_line(bottom[i], top[i], Color(hue, 0.25), 2.0, true)
		draw_line(top[i], top[(i + 1) % 8], Color(hue, 0.6), 2.0, true)
		var angle := TAU * i / 8.0 + PI / 8.0
		var direction := Vector2(cos(angle), sin(angle))
		var a: Vector2 = target.to_iso(at + direction * 101) - Vector2(0, 10)
		var b: Vector2 = target.to_iso(at + direction * 88) - Vector2(0, 10)
		var c: Vector2 = target.to_iso(at + direction * 83 + Vector2(-direction.y, direction.x) * 10) - Vector2(0, 10)
		draw_polyline(PackedVector2Array([a, b, c]), Color(hue, 0.6), 1.3, true)
	_ring(at, Terrain.GATE_RADIUS, 10, 0, TAU, Color(hue, 0.35), 1.0, self)
	for i in 4:
		var turn := _time * (0.35 + charge * 3.0) if powered else 0.0
		_ring(at, 83, 10, i * PI * 0.5 + turn, PI * 0.35, Color(hue, 0.8), 3.0, self)
		_ring(at, 57, 10, i * PI * 0.5 - turn * 1.4, PI * 0.30, Color(BLUE if powered else hue, 0.7), 2.0, self)
	if powered:
		var sweep := fposmod(_time * 0.65, 1.0)
		_ring(at, 15 + sweep * 57, 11, 0, TAU, Color(CYAN, (1 - sweep) * 0.3), 2.0, self)
	# Circuit socket etched under the player formation.
	var core := _poly(at, 26, 10)
	core.append(core[0])
	draw_polyline(core, Color(hue, 0.55 + 0.2 * energy), 1.2, true)
	for i in 3:
		var p: Vector2 = target.to_iso(at + Vector2(-12 + i * 12, 0)) - Vector2(0, 10)
		draw_line(p - Vector2(0, 5), p + Vector2(0, 5), hue, 2.0, true)

func _draw_hologram() -> void:
	if target == null or target.terrain == null: return
	if target.transfer_ticks > 0 and target.transfer_ticks <= 36:
		var f := float(target.transfer_ticks) / 36.0
		for slot in target._live_slots():
			var at: Vector2 = target.player_render_pos[slot]
			_ring(at, 24 + (1 - f) * 85, 0, 0, TAU, Color(CYAN, f * 0.75), 2.0, _hologram)
			_draw_column(at, 25 * f, 165 * f, f * 0.45)
	if not _pad_visible(): return
	var at: Vector2 = target.terrain.teleporter_pos()
	var powered: bool = target.terrain.gate().open
	var charge := clampf(float(90 - target.transfer_ticks) / 54.0, 0.0, 1.0) if target.transfer_ticks > 36 else 0.0
	var hue := CYAN if powered else Color(0.17, 0.3, 0.36)
	# Four industrial emitters. The upper geometry is transparent so a craft
	# crossing a foreground post remains readable.
	for i in 4:
		var angle := PI * 0.25 + i * PI * 0.5
		var foot: Vector2 = at + Vector2(cos(angle), sin(angle)) * 101
		var p: Vector2 = target.to_iso(foot)
		var height := 36.0 + 25.0 * _activation + charge * 16.0
		var box := PackedVector2Array([p + Vector2(-10, 0), p + Vector2(-10, -height), p + Vector2(0, -height - 6), p + Vector2(10, -height), p + Vector2(10, 0), p + Vector2(0, 6)])
		_hologram.draw_colored_polygon(box, Color(DARK, 0.82))
		box.append(box[0])
		_hologram.draw_polyline(box, Color(hue, 0.65), 1.5, true)
		_hologram.draw_line(p + Vector2(0, -12), p + Vector2(0, -height + 8), hue, 2.3, true)
		_hologram.draw_line(p + Vector2(-5, -height + 4), p + Vector2(5, -height + 4), Color(0.8, 1.8, 2.0) if powered else hue, 3.0, true)
	if powered:
		var lift := 84 * _activation + 7 * sin(_time * 1.7)
		for i in 3:
			_ring(at, 41 + i * 9 + charge * 12, lift + i * 6, _time * (0.6 + charge * 5) * (1 if i % 2 == 0 else -1), PI * 1.4, Color(CYAN if i != 1 else BLUE, 0.6), 1.7, _hologram)
		_draw_column(at, 47 + charge * 18, lift + 28 + charge * 95, 0.10 + charge * 0.35)
		# Packet fragments stream upward; bounded fixed geometry, no particles
		# or simulation RNG and no new scene nodes per fragment.
		for i in 18:
			var phase := fposmod(_time * (0.30 + charge) + i * 0.173, 1.0)
			var a := i * 2.399 + _time * 0.25
			var p: Vector2 = target.to_iso(at + Vector2(cos(a), sin(a)) * (24 + i % 5 * 7)) - Vector2(0, 14 + phase * (115 + charge * 90))
			_hologram.draw_rect(Rect2(p, Vector2(2 + i % 3, 5 + i % 4)), Color(CYAN, sin(phase * PI) * 0.6))
		var live: PackedInt32Array = target._live_slots()
		for i in live.size():
			var s: int = live[i]
			var held: bool = target.player_pos[s].distance_to(at) <= Terrain.GATE_RADIUS - target.PLAYER_RADIUS
			var p: Vector2 = target.to_iso(at) + Vector2((i - (live.size() - 1) * 0.5) * 17, 82)
			_hologram.draw_rect(Rect2(p - Vector2(5, 5), Vector2(10, 5)), CYAN if held else Color(0.12, 0.22, 0.3))
	var label := "TRANSFER NODE / OFFLINE"
	if powered: label = "GATHER / %d OF %d LINKED" % [target.teleporter_gathered(), target._live_slots().size()]
	if target.route_pending: label = "DESTINATION BALLOT OPEN"
	if target.transfer_ticks > 36: label = "UPLOADING // " + str(int(charge * 100)) + "%"
	var anchor: Vector2 = target.to_iso(at) + Vector2(0, 110)
	var font := ThemeDB.fallback_font
	var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	_hologram.draw_string(font, anchor - Vector2(width * 0.5, 0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, hue)

func _draw_column(at: Vector2, radius: float, height: float, opacity: float) -> void:
	var base: Vector2 = target.to_iso(at)
	for i in 6:
		var w := radius * (1 - i * 0.12)
		var vertices := PackedVector2Array([base + Vector2(-w, 0), base + Vector2(-w * 0.45, -height), base + Vector2(w * 0.45, -height), base + Vector2(w, 0)])
		_hologram.draw_colored_polygon(vertices, Color(CYAN, opacity * 0.12))

func _draw_room_floor() -> void:
	var t: Terrain = target.terrain
	if not t.room_unlocked: return
	for r in [t.room_link.grow_individual(64, 0, 0, 0), t.room_rect]:
		if not target._visible_world_rect().intersects(r): continue
		draw_colored_polygon(target._ground_quad(r.position, r.end), Color(0.024, 0.044, 0.072))
		var corners: PackedVector2Array = target._ground_quad(r.position, r.end)
		corners.append(corners[0])
		draw_polyline(corners, Color(0.20, 0.5, 0.9), 2.0, true)
		for y in range(int(r.position.y) + 48, int(r.end.y), 96):
			draw_line(target.to_iso(Vector2(r.position.x, y)), target.to_iso(Vector2(r.end.x, y)), Color(0.10, 0.24, 0.39), 1.0)
		for x in range(int(r.position.x) + 48, int(r.end.x), 96):
			draw_line(target.to_iso(Vector2(x, r.position.y)), target.to_iso(Vector2(x, r.end.y)), Color(0.10, 0.24, 0.39), 1.0)

	# Recessed memory banks along both edges, connected to the extraction
	# socket by paired traces. These are floor inlays, not solid obstacles.
	for side in [-1.0, 1.0]:
		for i in 6:
			var at := t.room_rect.position + Vector2(112 + i * 144, 0)
			at.y = t.room_rect.get_center().y + side * 265
			if not target._visible_world_rect().grow(80).has_point(at): continue
			var r := Rect2(at - Vector2(44, 58), Vector2(88, 116))
			var shape: PackedVector2Array = target._ground_quad(r.position, r.end)
			draw_colored_polygon(shape, Color(0.025, 0.08, 0.12))
			shape.append(shape[0])
			draw_polyline(shape, Color(0.15, 0.46, 0.66), 1.2, true)
			for line in 4:
				var start := at + Vector2(-28, -36 + line * 24)
				draw_line(target.to_iso(start), target.to_iso(start + Vector2(56, 0)), Color(0.22, 0.58, 0.75), 2.0)
			var end := at - Vector2(0, side * 92)
			draw_line(target.to_iso(at - Vector2(0, side * 60)), target.to_iso(end), Color(0.13, 0.5, 0.7), 1.5)
			draw_line(target.to_iso(end), target.to_iso(Vector2(t.room_rect.get_center().x, end.y)), Color(0.11, 0.33, 0.48), 1.0)

func _draw_room_reward() -> void:
	var t: Terrain = target.terrain
	if not t.room_unlocked or not target._visible_world_rect().grow(100).intersects(t.room_rect): return
	var at := t.room_rect.get_center()
	var hue := Color(0.25, 0.45, 0.6) if target.room_claimed else Color(0.65, 1.25, 1.9)
	var p: Vector2 = target.to_iso(at)
	var box := _poly(at, 35, 30)
	var foot := _poly(at, 35, 0)
	for i in 8:
		draw_colored_polygon(PackedVector2Array([box[i], box[(i + 1) % 8], foot[(i + 1) % 8], foot[i]]), Color(0.025, 0.075, 0.12, 0.85))
		draw_line(box[i], foot[i], Color(hue, 0.4), 1.0)
	draw_colored_polygon(box, DARK)
	box.append(box[0])
	draw_polyline(box, hue, 2.0, true)
	for i in 3:
		draw_line(p + Vector2(-14, -35 + i * 5), p + Vector2(14, -35 + i * 5), Color(hue, 0.8), 2.0)
	if not target.room_claimed:
		var lift := 60 + sin(_time * 1.5) * 8
		var glyph := PackedVector2Array([p + Vector2(0, -lift - 12), p + Vector2(14, -lift), p + Vector2(0, -lift + 12), p + Vector2(-14, -lift), p + Vector2(0, -lift - 12)])
		draw_polyline(glyph, hue, 1.5, true)
	_ring(at, 90, 0, _time * 0.3, TAU * 0.85, Color(hue, 0.6), 1.5, self)
	var title := "ARCHIVE EXTRACTED" if target.room_claimed else "HIDDEN ARCHIVE / +100 SALVAGE + RANK"
	draw_string(ThemeDB.fallback_font, p + Vector2(-150, -70), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, hue)
