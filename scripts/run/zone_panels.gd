extends Node2D

## Surface markings below the run's zone tint and opaque collapse mask.
## No height or collision: warning hatching, drag bars, and corruption sockets
## distinguish the effects even when their colors are difficult to separate.
const HUES := [Color(1.0, 0.38, 0.30), Color(0.40, 0.70, 1.0),
	Color(0.86, 0.44, 1.0)]

class PanelVisual:
	var outline := PackedVector2Array()
	var detail := PackedVector2Array()
	var indicator := PackedVector2Array()

var target: Node2D
var _terrain: Terrain
var _zones: Array = []
var _cache: Dictionary = {}

func _process(_dt: float) -> void:
	if target == null or target.terrain == null:
		return
	if _terrain != target.terrain:
		_terrain = target.terrain
		_zones.clear()
		_cache.clear()
		for i in _terrain.rects.size():
			var entry: Array = _terrain.rects[i]
			if entry[1] != Terrain.Kind.WALL:
				_zones.append([i, entry[0], entry[1]])
	queue_redraw()

func _charge(index: int, kind: int) -> float:
	if kind != Terrain.Kind.CORRUPTION or index >= target._zone_recharge.size():
		return 1.0
	return clampf(1.0 - target._zone_recharge[index] / Terrain.ZONE_RECHARGE, 0.0, 1.0)

func _draw() -> void:
	if target == null or _terrain == null:
		return
	var view: Rect2 = target._visible_world_rect()
	var time := Time.get_ticks_msec() * 0.001
	for entry in _zones:
		var rect: Rect2 = entry[1]
		if not view.intersects(rect):
			continue
		var index: int = entry[0]
		var kind: int = entry[2]
		var v := _panel_visual(rect, kind)
		var hue: Color = HUES[kind - 1]
		var charge := _charge(index, kind)
		draw_multiline(v.outline, Color(hue, 0.24 + 0.26 * charge), 1.25)
		draw_multiline(v.detail, Color(hue, 0.12 + 0.30 * charge), 1.0)
		if kind == Terrain.Kind.CORRUPTION:
			# Six discrete recharge segments; a dormant socket remains visible
			# but its gauge is empty. Read the same timer as the zone's fill.
			var count := int(floor(charge * 6.0)) * 2
			if count > 0:
				draw_multiline(v.indicator.slice(0, count), Color(hue, 0.80), 2.0)
		else:
			var activity := 0.65 + 0.15 * sin(time * 1.4 + float(index % 19))
			draw_multiline(v.indicator, Color(hue, activity), 2.0)

func _panel_visual(rect: Rect2, kind: int) -> PanelVisual:
	var key := [rect, kind]
	if _cache.has(key):
		return _cache[key]
	var v := PanelVisual.new()
	# An inset perimeter reads as a painted panel within the actual zone.
	_path(v.outline, rect, [Vector2(0.04, 0.04), Vector2(0.96, 0.04),
		Vector2(0.96, 0.96), Vector2(0.04, 0.96), Vector2(0.04, 0.04)])
	match kind:
		Terrain.Kind.HAZARD:
			for i in 5:
				var x := 0.10 + float(i) * 0.16
				_path(v.detail, rect, [Vector2(x, 0.06), Vector2(x + 0.09, 0.18)])
				_path(v.detail, rect, [Vector2(x, 0.82), Vector2(x + 0.09, 0.94)])
			_path(v.detail, rect, [Vector2(0.50, 0.25), Vector2(0.73, 0.68),
				Vector2(0.27, 0.68), Vector2(0.50, 0.25)])
			_path(v.indicator, rect, [Vector2(0.50, 0.39), Vector2(0.50, 0.52)])
			_path(v.indicator, rect, [Vector2(0.48, 0.60), Vector2(0.52, 0.60)])
		Terrain.Kind.SLOW:
			for i in 3:
				var y := 0.28 + float(i) * 0.22
				_path(v.detail, rect, [Vector2(0.16, y - 0.05), Vector2(0.16, y + 0.05)])
				_path(v.detail, rect, [Vector2(0.84, y - 0.05), Vector2(0.84, y + 0.05)])
				_path(v.indicator, rect, [Vector2(0.26, y), Vector2(0.74, y)])
		Terrain.Kind.CORRUPTION:
			_path(v.detail, rect, [Vector2(0.5, 0.20), Vector2(0.80, 0.5),
				Vector2(0.5, 0.80), Vector2(0.20, 0.5), Vector2(0.5, 0.20)])
			_path(v.detail, rect, [Vector2(0.5, 0.36), Vector2(0.64, 0.5),
				Vector2(0.5, 0.64), Vector2(0.36, 0.5), Vector2(0.5, 0.36)])
			for i in 6:
				var x := 0.12 + float(i) * 0.13
				_path(v.indicator, rect, [Vector2(x, 0.90), Vector2(x + 0.085, 0.90)])
	_cache[key] = v
	return v

func _path(out: PackedVector2Array, rect: Rect2, points: Array) -> void:
	for i in points.size() - 1:
		out.append(target.to_iso(rect.position + rect.size * points[i]))
		out.append(target.to_iso(rect.position + rect.size * points[i + 1]))
