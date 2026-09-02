class_name RecipeTable extends RefCounted

## The twenty recipes, and the fused modules they produce.
##
## A recipe is three EXACT module ids. Nothing is matched by kind or tag: a
## fusion is a specific thing you assembled, and the recipe panel can name it.
##
## Fused modules are VECTORs. That is load-bearing — Compiler._fold freezes a
## vector's cooldown and travel against rank and grows its radius at a quarter
## rate, and a fused module wants all three. It also means they may not carry
## cadence_mult, so each one's trigger cadence is baked into its cooldown, and
## every one must clear MIN_COOLDOWN / MIN_CADENCE_FRACTION = 0.41667.
##
## Every vector, every trigger and every payload appears at least once, so no
## card is ever a dead end for a player hunting recipes.
##
## DAMAGE IS DERIVED, NOT CHOSEN. Fusion consumes three MAXED modules and returns
## a rank-1 one, so each fused module's damage is set so its rank-1 output at
## least matches the triple it eats — otherwise fusing is a downgrade and the
## correct play is never to fuse. The triple's rate is measured with its cadence
## floored at its VECTOR's base cooldown: an event trigger compounds a large
## cadence bonus (on_hit at rank 5 is 0.62^5) but cannot sustainably out-fire its
## own events, so the uncapped figure is theoretical rather than real. Six
## recipes already cleared parity and were left alone.
## tests/test_fusion.gd pins the property; re-derive rather than eyeballing.
##
## The weapons pass rehomed seven recipes onto stronger base vectors and
## re-derived their damage under the rule above; five recipes now sit on
## broadcast, so five fused modules each out-fire a rank-5 broadcast-plus-
## trigger. That is the intended cost of one vector per kind.

const S := Module.Slot
const V := Module.VectorKind
const T := Module.TriggerKind
const G := Module.Targeting

class Recipe extends RefCounted:
	var vector_id: StringName
	var trigger_id: StringName
	var payload_id: StringName
	var fused: Module
	func _init(v: StringName, t: StringName, p: StringName, f: Module) -> void:
		vector_id = v
		trigger_id = t
		payload_id = p
		fused = f

static func _f(id: StringName, name: String, stats: Dictionary,
		vk: int, tk: int, tg: int = G.NEAREST, tags: Array = []) -> Module:
	var m := Module.make(id, name, S.VECTOR, stats, tags, vk, tk)
	m.targeting = tg
	m.is_fused = true
	return m

## Built once. match_exploit is called per row, matched_recipes per exploit and
## near_miss per exploit per recipe, so rebuilding twenty Module resources per
## call put a hundred-odd allocations behind one block payout.
static var _all: Array = []

static func all() -> Array:
	if _all.is_empty():
		_all = _build()
	return _all

static func _build() -> Array:
	return [
		Recipe.new(&"packet", &"on_kill", &"race_condition",
			_f(&"hollow_point", "hollow_point()",
				{&"damage": 49.5, &"projectile_speed": 640.0, &"cooldown": 0.55,
				 &"travel": 900.0, &"pierce": 2.0}, V.PACKET, T.ON_KILL)),
		Recipe.new(&"broadcast", &"interval", &"overclock",
			_f(&"pulse_train", "pulse_train()",
				{&"damage": 18.0, &"radius": 150.0, &"cooldown": 0.55},
				V.BROADCAST, T.INTERVAL)),
		Recipe.new(&"chain", &"on_hit", &"heap_spray",
			_f(&"arp_storm", "arp_storm()",
				{&"damage": 20.5, &"chain_count": 8.0, &"radius": 200.0,
				 &"cooldown": 0.62}, V.CHAIN, T.ON_HIT, G.FARTHEST)),
		Recipe.new(&"beam", &"interval", &"buffer_overflow",
			_f(&"railgun", "railgun()",
				{&"damage": 49.0, &"pierce": 8.0, &"radius": 420.0,
				 &"cooldown": 0.65}, V.BEAM, T.INTERVAL)),
		Recipe.new(&"spike", &"on_kill", &"fork_bomb",
			_f(&"stack_smash", "stack_smash()",
				{&"damage": 74.5, &"radius": 210.0, &"cooldown": 0.70,
				 &"execute_below": 0.18}, V.CONE, T.ON_KILL)),
		Recipe.new(&"broadcast", &"interval", &"tarpit",
			_f(&"dragnet", "dragnet()",
				{&"damage": 21.0, &"radius": 380.0, &"cooldown": 1.0,
				 &"slow_amount": 0.60, &"slow_duration": 2.5},
				V.BROADCAST, T.INTERVAL, G.NEAREST, [&"slow"])),
		Recipe.new(&"packet", &"on_kill", &"bitmask",
			_f(&"zero_day", "zero_day()",
				{&"damage": 94.5, &"projectile_speed": 900.0, &"cooldown": 1.05,
				 &"travel": 1600.0, &"pierce": 6.0, &"homing": 2.6},
				V.PACKET, T.ON_KILL, G.STRONGEST)),
		Recipe.new(&"landmine", &"interval", &"corrupt",
			_f(&"logic_bomb", "logic_bomb()",
				{&"damage": 42.0, &"corruption": 26.5, &"radius": 190.0,
				 &"cooldown": 1.3}, V.MINE, T.INTERVAL, G.NEAREST,
				[&"aoe", &"corruption"])),
		Recipe.new(&"chain", &"on_flip", &"worm",
			_f(&"botnet_cascade", "botnet_cascade()",
				{&"damage": 13.0, &"corruption": 14.5, &"chain_count": 10.0,
				 &"radius": 220.0, &"cooldown": 0.55}, V.CHAIN, T.ON_FLIP,
				G.NEAREST, [&"corruption"])),
		Recipe.new(&"bounce", &"on_hit", &"harden",
			_f(&"bulkhead", "bulkhead()",
				{&"damage": 11.0, &"radius": 230.0, &"cooldown": 0.80,
				 &"knockback": 420.0, &"ward_armor": 3.0, &"ward_duration": 2.5},
				V.PULSE, T.ON_HIT)),
		Recipe.new(&"mirror", &"interval", &"nice",
			_f(&"aegis", "aegis()",
				{&"damage": 14.5, &"radius": 110.0, &"cooldown": 1.6,
				 &"orbit_count": 8.0, &"pierce": 3.0, &"ward_clock_speed": 20.0,
				 &"ward_duration": 1.6}, V.ORBIT, T.INTERVAL)),
		Recipe.new(&"broadcast", &"interval", &"keylog",
			_f(&"tar_siphon", "tar_siphon()",
				{&"damage": 19.0, &"radius": 300.0, &"cooldown": 0.9,
				 &"slow_amount": 0.65, &"slow_duration": 2.5, &"lifesteal": 0.9},
				V.BROADCAST, T.INTERVAL, G.NEAREST, [&"slow"])),
		Recipe.new(&"bounce", &"on_damage_taken", &"sandbox",
			_f(&"panic_room", "panic_room()",
				{&"damage": 41.0, &"radius": 280.0, &"cooldown": 0.9,
				 &"knockback": 620.0, &"ward_defense": 26.0,
				 &"ward_duration": 3.0, &"burst": 4.0},
				V.PULSE, T.ON_DAMAGE_TAKEN)),
		Recipe.new(&"broadcast", &"on_kill", &"checksum",
			_f(&"redundancy", "redundancy()",
				{&"damage": 32.5, &"radius": 130.0, &"cooldown": 0.85,
				 &"shield": 60.0, &"botnet_cap": 6.0, &"botnet_lifetime": 14.0,
				 &"botnet_damage_ratio": 0.6}, V.BROADCAST, T.ON_KILL)),
		# 0.42 against a 0.41667 floor — a 0.8% margin, and the one number in
		# this table a balance tweak can break silently. Pinned by name in
		# tests/test_fusion.gd so an edit trips a check, not the validator.
		Recipe.new(&"packet", &"on_hit", &"overclock",
			_f(&"syn_flood", "syn_flood()",
				{&"damage": 38.0, &"projectile_speed": 560.0, &"cooldown": 0.42,
				 &"travel": 520.0, &"split_count": 3.0}, V.PACKET, T.ON_HIT)),
		Recipe.new(&"packet", &"interval", &"fork_bomb",
			_f(&"frag_packet", "frag_packet()",
				{&"damage": 55.0, &"projectile_speed": 480.0, &"cooldown": 0.55,
				 &"travel": 620.0, &"blast_radius": 110.0}, V.PACKET, T.INTERVAL,
				G.NEAREST, [&"aoe"])),
		Recipe.new(&"chain", &"interval", &"botnet_expand",
			_f(&"hivemind", "hivemind()",
				{&"damage": 19.5, &"chain_count": 5.0, &"radius": 200.0,
				 &"cooldown": 0.70, &"botnet_cap": 8.0, &"botnet_lifetime": 18.0,
				 &"botnet_damage_ratio": 0.7}, V.CHAIN, T.INTERVAL)),
		Recipe.new(&"broadcast", &"on_low_integrity", &"sandbox",
			_f(&"last_resort", "last_resort()",
				{&"damage": 67.5, &"radius": 460.0, &"cooldown": 1.2,
				 &"burst": 6.0, &"ward_defense": 30.0, &"ward_duration": 4.0},
				V.BROADCAST, T.ON_LOW_INTEGRITY)),
		Recipe.new(&"beam", &"on_level_up", &"buffer_overflow",
			_f(&"core_dump", "core_dump()",
				{&"damage": 67.5, &"pierce": 10.0, &"radius": 460.0,
				 &"cooldown": 0.9, &"burst": 12.0}, V.BEAM, T.ON_LEVEL_UP)),
		Recipe.new(&"landmine", &"on_kill", &"bitmask",
			_f(&"minefield", "minefield()",
				{&"damage": 42.5, &"radius": 170.0, &"cooldown": 0.85,
				 &"split_count": 3.0, &"pierce": 2.0}, V.MINE, T.ON_KILL,
				G.NEAREST, [&"aoe"])),
	]

## The recipe a row matches exactly, or null. A row missing any of the three
## matches nothing — an incomplete row is not a partial fusion.
static func match_exploit(ex: Exploit) -> Recipe:
	if ex.head_is_fused() or ex.vector == null or ex.trigger == null:
		return null
	var p: EquippedModule = ex.payloads[0]
	if p == null:
		return null
	for r in all():
		if r.vector_id == ex.vector.module.id \
				and r.trigger_id == ex.trigger.module.id \
				and r.payload_id == p.module.id:
			return r
	return null

static func by_fused_id() -> Dictionary:
	var d := {}
	for r in all():
		d[r.fused.id] = r
	return d

## The module id a row is a SINGLE module short of, or &"" when it is short of
## none or of more than one. This lives here rather than in run.gd because it is
## a question about recipes, and the arena has no business knowing a recipe's
## shape or an exploit's slots.
static func near_miss(ex: Exploit) -> StringName:
	if ex.head_is_fused():
		return &""
	for r in all():
		var want: StringName = &""
		var misses := 0
		for pair in [[ex.vector, r.vector_id], [ex.trigger, r.trigger_id],
				[ex.payloads[0], r.payload_id]]:
			var em: EquippedModule = pair[0]
			if em == null or em.module.id != pair[1]:
				misses += 1
				want = pair[1]
		if misses == 1:
			return want
	return &""
