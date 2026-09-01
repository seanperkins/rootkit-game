extends SceneTree

## Fusion: the fused head, the recipes, and the mechanics they run on.

const EXPECTED_CHECKS := 12

var failures := 0
var checks := 0
var T := ModuleTable.by_id()

func _init() -> void:
	print("ROOTKIT — fusion\n")
	a_fused_row_fires_with_no_trigger()
	targeting_comes_from_the_head_only()
	print("")
	if checks != EXPECTED_CHECKS:
		print("  FAIL — ran %d checks, expected %d (a function aborted early)"
			% [checks, EXPECTED_CHECKS])
		failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	checks += 1
	if got == want or (got is float and want is float and abs(got - want) < 1e-5):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

## The same helper tests/test_build.gd carries. Repeated rather than shared
## because each suite here is a standalone SceneTree script with no common base.
func _mk(vector_id: StringName, trigger_id: StringName, payloads: Array = []) -> Exploit:
	var ex := Exploit.new()
	if vector_id != &"": ex.place(T[vector_id])
	if trigger_id != &"": ex.place(T[trigger_id])
	for p in payloads: ex.place(T[p])
	return ex

## A fused module carries its own vector_kind AND trigger_kind, so the row is
## not inert with the trigger column empty — that is what absorbing it means.
func _fused_probe() -> Module:
	var m := Module.make(&"probe_fuse", "probe_fuse()", Module.Slot.VECTOR,
		{&"damage": 20.0, &"radius": 200.0, &"cooldown": 0.6}, [],
		Module.VectorKind.BROADCAST, Module.TriggerKind.ON_KILL)
	m.is_fused = true
	return m

func a_fused_row_fires_with_no_trigger() -> void:
	var ex := Exploit.new()
	ex.vector = EquippedModule.new(_fused_probe())
	_check("a fused row is not inert", ex.is_inert(), false)
	_check("slot 0 is the fused module", ex.at(0).module.id, &"probe_fuse")
	_check("the head reads as fused", ex.head_is_fused(), true)
	_check("the trigger column is empty", ex.at(1), null)

	var r := Compiler.build(ex)
	_check("the kind comes from the head", r.vector_kind,
		Module.VectorKind.BROADCAST)
	_check("so does the trigger kind", r.trigger_kind,
		Module.TriggerKind.ON_KILL)
	_check("and the resolve is not inert", r.inert, false)

	# Scoped to THE FUSED ROW. legal_targets loops `for e in MAX_EXPLOITS` and
	# offers EMPTY_SLOT on not-yet-created exploits, so a total count here would
	# be asserting something about rows 1 and 2.
	var lo := Loadout.new()
	lo.exploits = [ex]
	var trig := 0
	var pay := 0
	for t in lo.legal_targets(T[&"on_hit"]):
		if t.exploit == 0: trig += 1
	for t in lo.legal_targets(T[&"corrupt"]):
		if t.exploit == 0: pay += 1
	_check("no trigger card targets the fused row", trig, 0)
	_check("but its payload slot is still open", pay, 1)


## targeting is read ONLY from the vector slot, exactly as the kinds are. A
## payload's default enum value folding in would silently pull every fused
## sniper back to NEAREST.
func targeting_comes_from_the_head_only() -> void:
	var m := _fused_probe()
	m.targeting = Module.Targeting.STRONGEST
	var ex := Exploit.new()
	ex.vector = EquippedModule.new(m)
	ex.place(T[&"keylog"])              # a payload at default NEAREST
	var r := Compiler.build(ex)
	_check("the head's targeting survives the payload fold", r.targeting,
		Module.Targeting.STRONGEST)

	var plain := Exploit.new()
	plain.place(T[&"packet"]); plain.place(T[&"interval"])
	_check("an ordinary exploit defaults to NEAREST",
		Compiler.build(plain).targeting, Module.Targeting.NEAREST)
	_check("and NEAREST is enum zero", Module.Targeting.NEAREST, 0)
