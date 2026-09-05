class_name CampaignNavigation extends RefCounted

## Input-only navigation for campaign instruments. Paths cross cell centers
## with four-way clearance; no position, health or objective-state writes.
var _terrain: Terrain
var _goal := -1
var _path := PackedInt32Array()
var _next := 0

func toward(terrain: Terrain, from: Vector2, target: Vector2) -> Vector2:
	if from.distance_to(target) < 24: return Vector2.ZERO
	var goal := terrain.cell_index(target)
	if terrain != _terrain or goal != _goal or _path.is_empty():
		_terrain = terrain
		_goal = goal
		_path = path(terrain, from, target)
		_next = 0
	while _next < _path.size():
		var i := _path[_next]
		var point := terrain.origin + Vector2(i % terrain.w + 0.5, i / terrain.w + 0.5) * Terrain.CELL
		if from.distance_to(point) > 14: return (point - from).normalized()
		_next += 1
	return (target - from).normalized()

static func path(terrain: Terrain, from: Vector2, target: Vector2) -> PackedInt32Array:
	var start := terrain.cell_index(from)
	var goal := terrain.cell_index(target)
	if start < 0 or goal < 0: return PackedInt32Array()
	var parent := PackedInt32Array()
	parent.resize(terrain.w * terrain.h)
	parent.fill(-2)
	parent[start] = -1
	var queue := PackedInt32Array([start])
	var head := 0
	while head < queue.size() and parent[goal] == -2:
		var i := queue[head]
		head += 1
		for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var xy: Vector2i = Vector2i(i % terrain.w, i / terrain.w) + offset
			if not terrain.in_bounds(xy): continue
			var next: int = xy.y * terrain.w + xy.x
			if parent[next] != -2 or terrain.solid[next] != 0: continue
			if not terrain.voided.is_empty() and terrain.voided[next] != 0: continue
			parent[next] = i
			queue.append(next)
	var result := PackedInt32Array()
	if parent[goal] == -2: return result
	var i := goal
	while i >= 0:
		result.append(i)
		i = parent[i]
	result.reverse()
	return result
