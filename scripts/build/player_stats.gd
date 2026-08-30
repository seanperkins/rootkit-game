class_name PlayerStats extends RefCounted

## The player's own stats, kept separate from ResolvedExploit's weapon stats.
## Pure: no scene tree, no globals — the same discipline as the rest of
## scripts/build.
##
## Two groups, deliberately not one. The additive sheet (integrity, armor,
## defense, clock_speed, pickup_radius) is read directly by run.gd and never
## reaches the compiler. The multipliers (attack, haste, reach) are folded into
## every exploit by Compiler.build AFTER the flat module fold, so a module's
## "+7 damage" stays a flat number and the player layer is the percentage layer.
##
## Keeping them apart is what stops the bug this whole feature is named after: a
## player stat has nowhere to land in the exploit namespace, so it cannot be sold
## in the shop and then silently delivered as something else.

const BASE := {
	&"integrity": 100.0,
	&"armor": 0.0,
	&"defense": 0.0,
	&"clock_speed": 220.0,
	&"pickup_radius": 30.0,
}

const BASE_MULT := {
	&"attack": 1.0,
	&"haste": 1.0,
	&"reach": 1.0,
}

## armor never blocks more than 80% of a hit, so no stack makes a hit free.
const ARMOR_FLOOR := 0.2
## the defense value at which reduction is exactly 50%.
const DEFENSE_K := 60.0

## Armor subtracts flat (floored), then defense cuts a percentage with
## diminishing returns. Bounded by shape rather than by clamp: the floor stops
## armor zeroing a hit, and d/(d+K) is asymptotic to 1 and never reaches it.
##
## The two maxf(0.0, ...) guards are load-bearing, not habit. save.json is
## user-editable, and at defense == -60 the denominator is 0.0 — GDScript float
## division yields INF rather than erroring, so a hostile file would silently
## produce nonsense instead of failing loudly.
static func mitigate(incoming: float, armor: float, defense: float) -> float:
	var a := maxf(0.0, armor)
	var d := maxf(0.0, defense)
	return maxf(incoming * ARMOR_FLOOR, incoming - a) * (1.0 - d / (d + DEFENSE_K))

## BASE plus meta deltas. Unknown keys are dropped rather than added, so a stale
## or edited save cannot invent a stat.
static func sheet(deltas: Dictionary = {}) -> Dictionary:
	var out := BASE.duplicate()
	for k in deltas:
		if out.has(k):
			out[k] = float(out[k]) + float(deltas[k])
	return out

## BASE_MULT plus meta deltas. SaveGame.multipliers() returns DELTAS (+0.40 at
## rank 10), while Compiler multiplies by whatever it is handed — so passing the
## raw delta through would scale damage DOWN by 60%. This is the converter, and
## every caller of SaveGame.multipliers() must go through it.
static func mults(deltas: Dictionary = {}) -> Dictionary:
	var out := BASE_MULT.duplicate()
	for k in deltas:
		if out.has(k):
			out[k] = float(out[k]) + float(deltas[k])
	return out
