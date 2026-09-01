extends SceneTree

## The bank/event-set agreement, and the rate limiter.
##
## This is the same failure shape CLAUDE.md already records for
## meta_screen.BUFFS against SaveGame._default(): two sets that must match, kept
## in different files, indexed without a fallback. Here the consequence is a
## silent dropped sound rather than a crash, which is worse for finding it.
##
## The ids are gathered by GREPPING run.gd for feel.emit(...) rather than from a
## hand-kept list, because a hand-kept list is the thing that goes stale.

var failures := 0
var finished := {}

const CASES := ["every_emitted_id_is_in_the_bank", "fire_ids_cover_the_enum",
	"the_bus_is_idempotent", "the_limiter_drops_overflow"]

func _initialize() -> void:
	print("ROOTKIT — audio events\n")
	every_emitted_id_is_in_the_bank()
	fire_ids_cover_the_enum()
	the_bus_is_idempotent()
	await the_limiter_drops_overflow()
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

## Every literal string passed to feel.emit() anywhere in scripts/run/.
func _emitted_ids() -> Array:
	var out := []
	var re := RegEx.new()
	re.compile("feel\\.emit\\(\"([a-z_]+)\"\\)")
	for path in ["res://scripts/run/run.gd", "res://scripts/run/ui.gd"]:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var txt := f.get_as_text()
		f.close()
		for m in re.search_all(txt):
			var id := m.get_string(1)
			if not out.has(id):
				out.append(id)
	# INDIRECT emit sites. An id reached through a lookup table rather than a
	# literal — feel.emit(HIT_SOUNDS[w]) — is invisible to the grep above, and
	# a missing one is a silent dropped sound rather than a crash. Any new
	# table of ids belongs here.
	var tbl := RegEx.new()
	tbl.compile("const HIT_SOUNDS := \\[([^\\]]*)\\]")
	var f2 := FileAccess.open("res://scripts/run/run.gd", FileAccess.READ)
	if f2 != null:
		var body := f2.get_as_text()
		f2.close()
		var m2 := tbl.search(body)
		if m2 != null:
			var inner := RegEx.new()
			inner.compile("\"([a-z_]+)\"")
			for m3 in inner.search_all(m2.get_string(1)):
				if not out.has(m3.get_string(1)):
					out.append(m3.get_string(1))
	return out

func every_emitted_id_is_in_the_bank() -> void:
	var bank := Synth.build_bank()
	var ids := _emitted_ids()
	_check("the grep found emit sites at all", ids.size() > 0, true)
	for id in ids:
		_check("emitted id '%s' resolves in the bank" % id, bank.has(id), true)
	finished["every_emitted_id_is_in_the_bank"] = true

## Enumerated from the enum, not compared against a static list: a static-set
## comparison passes while a runtime-generated id crashes, which is the whole
## point of deriving fire ids from VectorKind.
func fire_ids_cover_the_enum() -> void:
	var bank := Synth.build_bank()
	for k in Module.VectorKind.size():
		_check("VectorKind %d has a fire sound" % k,
			bank.has(Synth.fire_id(k)), true)
	finished["fire_ids_cover_the_enum"] = true

## No autoloads, and the game shuttles shell <-> run all session, so bus
## creation runs once per RUN. It has to be safe to call again.
func the_bus_is_idempotent() -> void:
	var a: int = load("res://scripts/audio/sfx.gd").ensure_bus()
	var before := AudioServer.bus_count
	var b: int = load("res://scripts/audio/sfx.gd").ensure_bus()
	_check("the bus index is real", a >= 0, true)
	_check("a second call returns the same bus", b, a)
	_check("and adds no second bus", AudioServer.bus_count, before)
	# A missing bus returns -1 and set_bus_volume_db(-1, x) errors on every
	# slider movement — and it emits ERROR:, not SCRIPT ERROR:, so the runner
	# would not catch it. Assert the guard directly instead.
	_check("the named lookup finds it",
		AudioServer.get_bus_index("SFX") >= 0, true)
	finished["the_bus_is_idempotent"] = true

## Overflow is dropped, never queued. A queue would just delay the wall of noise.
func the_limiter_drops_overflow() -> void:
	var n := Node.new()
	n.set_script(load("res://scripts/audio/sfx.gd"))
	root.add_child(n)
	await process_frame
	var played := 0
	for i in 200:
		# Untyped: _last_played holds a float, and an int annotation
		# truncates it so the comparison below always differs.
		var before = n._last_played.get("hit_light", -1.0)
		n.play("hit_light")
		if n._last_played.get("hit_light", -1.0) != before:
			played += 1
	_check("200 immediate plays collapse to one", played, 1)
	n.play("nonexistent_id")
	_check("an unknown id is a no-op, not a crash",
		n._last_played.has("nonexistent_id"), false)
	n.free()
	finished["the_limiter_drops_overflow"] = true
