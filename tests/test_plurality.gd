extends SceneTree

## Plurality primitives that do not need real player slots yet: the grid's live
## window sizing and cell-snapping. The party-bound, leash, and census rules that
## need multiple LIVE slots arrive in Task 7 and extend this suite.

var failures := 0
var finished := {}

const CELL := 32.0
const MAX := 7200.0

const CASES := ["window_at_the_minimum", "window_at_the_maximum",
	"edges_snap_to_cells"]

func _initialize() -> void:
	print("ROOTKIT — plurality primitives\n")
	window_at_the_minimum()
	window_at_the_maximum()
	edges_snap_to_cells()
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

func _grid() -> Grid:
	return Grid.new(Vector2.ZERO, Vector2(MAX, MAX), CELL, 4096)

## The 3200-square floor is exactly 100 x 100 = 10,000 cells — the solo window,
## the common case the whole grid is sized around.
func window_at_the_minimum() -> void:
	var g := _grid()
	g.set_window(Rect2(Vector2.ZERO, Vector2(3200.0, 3200.0)))
	_check("the 3200 square is 10,000 live cells", g.live_cell_count(), 10000)
	finished["window_at_the_minimum"] = true

## The 7200-square cap is 225 x 225 = 50,625 cells — the fully-spread party
## window, the ceiling the backing arrays are preallocated for.
func window_at_the_maximum() -> void:
	var g := _grid()
	g.set_window(Rect2(Vector2.ZERO, Vector2(MAX, MAX)))
	_check("the 7200 square is 50,625 live cells", g.live_cell_count(), 50625)
	finished["window_at_the_maximum"] = true

## An unaligned rect snaps OUTWARD — origin floored, far edge ceiled — so a cell
## boundary never slides under an entity. A 3200 window offset by 10 units spans
## one more cell on each axis.
func edges_snap_to_cells() -> void:
	var g := _grid()
	g.set_window(Rect2(Vector2(10.0, 10.0), Vector2(3200.0, 3200.0)))
	_check("the origin floors to a cell boundary", g._origin, Vector2.ZERO)
	_check("the far edge ceils, adding a column", g._cols, 101)
	_check("and a row", g._rows, 101)
	_check("so the unaligned window is 101 x 101", g.live_cell_count(), 101 * 101)

	# An already-aligned window is exactly its nominal size, offset and all.
	g.set_window(Rect2(Vector2(64.0, -32.0), Vector2(3200.0, 3200.0)))
	_check("an aligned window keeps its origin", g._origin, Vector2(64.0, -32.0))
	_check("and is exactly 10,000 cells", g.live_cell_count(), 10000)
	finished["edges_snap_to_cells"] = true
