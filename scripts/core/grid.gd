class_name Grid extends RefCounted

## Uniform spatial grid, rebuilt every tick, serving proximity queries, hit
## detection, and separation steering. Built with a counting sort into flat
## packed arrays (CSR layout) so a rebuild allocates nothing after warm-up.
##
## Indices returned by queries carry a 3-bit population tag in the high bits.
## Three bits, not two: four packed populations plus the player is five values,
## and a 2-bit tag has no encoding left for the player.

const TAG_BITS := 3
const TAG_SHIFT := 28
const INDEX_MASK := (1 << TAG_SHIFT) - 1

enum Pop { ENEMY, PROJECTILE, BOTNET, SHARD, PLAYER, MAX }

## Population bitmask for query filtering. Filtering during the cell walk, not
## at the call site, is what keeps a 24 px steering query from wading through
## every shard in the cluster.
const M_ENEMY := 1 << Pop.ENEMY
const M_PROJECTILE := 1 << Pop.PROJECTILE
const M_BOTNET := 1 << Pop.BOTNET
const M_SHARD := 1 << Pop.SHARD
const M_ALL := 0x7FFFFFFF

static func tag_of(tagged: int) -> int:
	return tagged >> TAG_SHIFT

static func index_of(tagged: int) -> int:
	return tagged & INDEX_MASK

var cell_size: float
## The LIVE rectangle: the window rebuild and every query actually walk. It is a
## sub-region of the preallocated maximum, resized each tick by set_window.
var _cols: int
var _rows: int
var _ncells: int
var _origin: Vector2
## The preallocated maximum. The backing arrays are sized for this once; the live
## rect never exceeds it. A party standing together rebuilds ~10,000 cells even
## though the store holds 50,625.
var _max_cols: int
var _max_rows: int
var _max_cells: int

var _cell_start: PackedInt32Array   # per cell: first item index (valid where _cell_count > 0)
var _cell_count: PackedInt32Array   # per cell: items in the cell; 0 for every untouched cell
var _cursor: PackedInt32Array       # per cell: pass-2 write head
## The cells pass 1 found non-empty, so the prefix sum walks O(entities) cells
## rather than every live cell. At the 50,625-cell party window that is the
## difference between a rebuild that costs what the entities cost and one that
## costs what the map costs.
var _touched: PackedInt32Array
var _touched_n := 0
var _items: PackedInt32Array        # tagged indices, bucketed
var _item_pos: PackedVector2Array   # positions parallel to _items
var _item_mask: PackedInt32Array    # 1 << population, parallel to _items

## The grid is a WINDOW that follows the player, not a map-sized structure.
##
## Rebuild is a counting sort: it clears a cursor and runs a prefix sum over
## every cell, so its cost is O(cells) whether six hundred entities are out
## there or none. Sizing that to the arena meant a five-times-larger map cost
## five times as much per tick to index empty ground nobody was near.
##
## Every query in this game happens close to the player — steering is gated at
## 820 units, weapons fire from the player, contact is at the player — so the
## window only has to cover that neighbourhood, and cell count becomes a
## constant the arena size cannot touch.
##
## The trade, stated plainly: an entity further than half the window from the
## player is not in the grid, so a projectile out there passes through enemies.
## At a 3200-unit window that is far off-screen in every direction, and those
## enemies are already too far away to be steering.
func _init(origin: Vector2, max_size: Vector2, p_cell_size: float,
		capacity: int) -> void:
	cell_size = p_cell_size
	_max_cols = int(ceil(max_size.x / cell_size))
	_max_rows = int(ceil(max_size.y / cell_size))
	_max_cells = _max_cols * _max_rows
	_cell_start.resize(_max_cells + 1)
	_cell_count.resize(_max_cells + 1)
	_cursor.resize(_max_cells)
	_touched.resize(capacity)
	_items.resize(capacity)
	_item_pos.resize(capacity)
	_item_mask.resize(capacity)
	# Start with the whole maximum live; run.gd sizes it down to the party window
	# every tick before rebuild.
	set_window(Rect2(origin, max_size))

## Set the live window to a world rectangle, snapped OUTWARD to whole cells so a
## cell boundary never slides under an entity — origin floored, far edge ceiled.
## `_cols`, `_rows`, `_ncells` and `_origin` describe the live rect that rebuild
## and every query walk; the live cell count never exceeds the preallocated
## maximum.
func set_window(world_rect: Rect2) -> void:
	var start := (world_rect.position / cell_size).floor() * cell_size
	var end := (world_rect.end / cell_size).ceil() * cell_size
	_origin = start
	_cols = mini(int(round((end.x - start.x) / cell_size)), _max_cols)
	_rows = mini(int(round((end.y - start.y) / cell_size)), _max_rows)
	_cols = maxi(_cols, 1)
	_rows = maxi(_rows, 1)
	_ncells = _cols * _rows

## The number of cells the current live window rebuilds — the real per-tick cost,
## not the preallocated maximum.
func live_cell_count() -> int:
	return _ncells

## Re-centre a fixed-size window on a point. Snapped to the cell size so cell
## boundaries do not slide under entities. Kept for callers that want the old
## follow-the-player behaviour; the party window uses set_window directly.
func set_centre(c: Vector2) -> void:
	var half := Vector2(float(_cols), float(_rows)) * cell_size * 0.5
	_origin = ((c - half) / cell_size).floor() * cell_size

func in_window(p: Vector2) -> bool:
	return p.x >= _origin.x and p.y >= _origin.y \
		and p.x < _origin.x + float(_cols) * cell_size \
		and p.y < _origin.y + float(_rows) * cell_size

func _cell_index(p: Vector2) -> int:
	var cx := clampi(int((p.x - _origin.x) / cell_size), 0, _cols - 1)
	var cy := clampi(int((p.y - _origin.y) / cell_size), 0, _rows - 1)
	return cy * _cols + cx

## pos_arrays[p] is the position array for population p; counts[p] is its live
## count. Population index IS the tag, so the caller passes them in Pop order.
## `skips` is an optional array of PackedByteArray, one per population (or null
## for a population with nothing to skip). A non-zero byte keeps that index OUT
## of the grid entirely.
##
## This exists so an enemy can be made untouchable by simply not being here:
## every hit path, proximity query and the player contact check all read the
## grid, so absence from it IS immunity — with no flag threaded through the
## drain and no third Population state.
func rebuild(pos_arrays: Array, counts: PackedInt32Array,
		skips: Array = []) -> void:
	var npops := counts.size()

	# Native fill over the whole backing store, not a GDScript loop over the live
	# cells: at the 50,625-cell party window an interpreted loop cost about a
	# millisecond a tick per pass, and fill() clears the same memory in a few
	# microseconds. Nothing below walks the cells at all — only the entities and
	# the cells they land in.
	_cell_count.fill(0)
	_touched_n = 0

	# The window test and the cell index are INLINED in both passes: at the
	# entity cap that is 8,400 calls a tick otherwise, and a call is most of the
	# cost of the arithmetic it wraps.
	var ox := _origin.x
	var oy := _origin.y
	var inv := 1.0 / cell_size
	var span_x := float(_cols) * cell_size
	var span_y := float(_rows) * cell_size
	var cols := _cols
	var last_col := _cols - 1
	var last_row := _rows - 1

	# Pass 1 — count per cell, noting each cell the first time it is hit.
	for p in npops:
		var pa: PackedVector2Array = pos_arrays[p]
		var sk = skips[p] if p < skips.size() else null
		var n := counts[p]
		for i in n:
			if sk != null and sk[i] != 0:
				continue
			var q := pa[i]
			var rx := q.x - ox
			var ry := q.y - oy
			if rx < 0.0 or ry < 0.0 or rx >= span_x or ry >= span_y:
				continue
			var c := mini(int(ry * inv), last_row) * cols + mini(int(rx * inv), last_col)
			if _cell_count[c] == 0:
				_touched[_touched_n] = c
				_touched_n += 1
			_cell_count[c] += 1

	# Prefix sum over the TOUCHED cells only. Ranges need only be disjoint, not
	# ordered by cell index, so any consistent order over the non-empty cells
	# works; an untouched cell has count 0 and its start is never read.
	var acc := 0
	for k in _touched_n:
		var c := _touched[k]
		_cell_start[c] = acc
		_cursor[c] = acc
		acc += _cell_count[c]

	# Pass 2 — scatter.
	for p in npops:
		var pa: PackedVector2Array = pos_arrays[p]
		var n := counts[p]
		var tag := p << TAG_SHIFT
		var m := 1 << p
		var sk2 = skips[p] if p < skips.size() else null
		for i in n:
			if sk2 != null and sk2[i] != 0:
				continue
			var q := pa[i]
			var rx := q.x - ox
			var ry := q.y - oy
			if rx < 0.0 or ry < 0.0 or rx >= span_x or ry >= span_y:
				continue
			var c := mini(int(ry * inv), last_row) * cols + mini(int(rx * inv), last_col)
			var w := _cursor[c]
			_items[w] = tag | i
			_item_pos[w] = q
			_item_mask[w] = m
			_cursor[c] = w + 1

## Fills `buf` with tagged indices whose position is within `r` of `point`.
## Returns the TOTAL number found, which may exceed buf.size() — the caller
## detects overflow by comparing. Never truncates the search itself: a query
## that silently capped its results is the failure mode this grid exists to
## avoid.
func query_radius_into(point: Vector2, r: float, buf: PackedInt32Array, mask: int = M_ALL) -> int:
	var cap := buf.size()
	var r2 := r * r
	var cx0 := clampi(int((point.x - r - _origin.x) / cell_size), 0, _cols - 1)
	var cx1 := clampi(int((point.x + r - _origin.x) / cell_size), 0, _cols - 1)
	var cy0 := clampi(int((point.y - r - _origin.y) / cell_size), 0, _rows - 1)
	var cy1 := clampi(int((point.y + r - _origin.y) / cell_size), 0, _rows - 1)
	var found := 0
	for cy in range(cy0, cy1 + 1):
		var row := cy * _cols
		for cx in range(cx0, cx1 + 1):
			var c := row + cx
			var cnt := _cell_count[c]
			if cnt == 0:
				continue
			var st := _cell_start[c]
			for k in range(st, st + cnt):
				if _item_mask[k] & mask == 0:
					continue
				if _item_pos[k].distance_squared_to(point) <= r2:
					if found < cap:
						buf[found] = _items[k]
					found += 1
	return found
