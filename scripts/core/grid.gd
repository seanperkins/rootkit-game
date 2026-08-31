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
var _cols: int
var _rows: int
var _ncells: int
var _origin: Vector2

var _cell_start: PackedInt32Array   # size _ncells + 1
var _cursor: PackedInt32Array       # size _ncells, doubles as the pass-1 count
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
func _init(origin: Vector2, size: Vector2, p_cell_size: float, capacity: int) -> void:
	cell_size = p_cell_size
	_origin = origin
	_cols = int(ceil(size.x / cell_size))
	_rows = int(ceil(size.y / cell_size))
	_ncells = _cols * _rows
	_cell_start.resize(_ncells + 1)
	_cursor.resize(_ncells)
	_items.resize(capacity)
	_item_pos.resize(capacity)
	_item_mask.resize(capacity)

## Re-centre the window. Snapped to the cell size so cell boundaries do not
## slide under entities as the player moves, which would let an entity change
## cell without moving.
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

	for c in _ncells:
		_cursor[c] = 0

	# Pass 1 — count per cell.
	for p in npops:
		var pa: PackedVector2Array = pos_arrays[p]
		var sk = skips[p] if p < skips.size() else null
		var n := counts[p]
		for i in n:
			if sk != null and sk[i] != 0:
				continue
			if not in_window(pa[i]):
				continue
			_cursor[_cell_index(pa[i])] += 1

	# Prefix sum. _cursor is rewritten in place to each bucket's write head.
	var acc := 0
	for c in _ncells:
		var k := _cursor[c]
		_cell_start[c] = acc
		_cursor[c] = acc
		acc += k
	_cell_start[_ncells] = acc

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
			if not in_window(q):
				continue
			var c := _cell_index(q)
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
			var e := _cell_start[c + 1]
			for k in range(_cell_start[c], e):
				if _item_mask[k] & mask == 0:
					continue
				if _item_pos[k].distance_squared_to(point) <= r2:
					if found < cap:
						buf[found] = _items[k]
					found += 1
	return found
