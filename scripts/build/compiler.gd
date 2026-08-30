class_name Compiler extends RefCounted

## Pure. Modules + meta buffs in, ResolvedExploit out. No scene tree, no globals.
## Runs once per module pick, never per frame — combat reads only the flat result.

const MIN_COOLDOWN := 0.05
const MAX_PROJECTILE_SPEED := 960.0

## Both clamps guard the same bug class: an unbounded additive stat. Cooldown
## reached -1.70s at max rank and hung a `while accumulator >= cooldown` loop.
## projectile_speed had no clamp at all and would have failed silently, as
## missed hits nobody could reproduce. 960 = 60 * (PROJECTILE_RADIUS 4 +
## ENEMY_RADIUS 12): the bound is the smallest combined radius, not the cell size.

static func build(ex: Exploit, buffs: Dictionary = {}) -> ResolvedExploit:
	var r := ResolvedExploit.new()
	r.inert = ex.is_inert()

	# Kinds are read ONLY from their own slot. Folding them from every module in
	# turn lets the TRIGGER module's default enum value clobber the vector.
	if ex.vector != null:
		r.vector_kind = ex.vector.module.vector_kind
	if ex.trigger != null:
		r.trigger_kind = ex.trigger.module.trigger_kind

	# VECTOR, then PAYLOADs sorted by module id, then TRIGGER. Sorting by id —
	# not by slot position — is what makes the fold independent of the order the
	# player happened to acquire them in.
	if ex.vector != null:
		_fold(r, ex.vector)

	var pays := []
	for p in ex.payloads:
		if p != null:
			pays.append(p)
	pays.sort_custom(func(a, b): return String(a.module.id) < String(b.module.id))
	for p in pays:
		_fold(r, p)

	if ex.trigger != null:
		_fold(r, ex.trigger)

	for k in buffs:
		if k in Module.STAT_KEYS:
			r.set(k, r.get(k) + buffs[k])

	r.cooldown = maxf(r.cooldown, MIN_COOLDOWN)
	r.projectile_speed = minf(r.projectile_speed, MAX_PROJECTILE_SPEED)
	# Fold in float, floor ONCE at the end: 0.5 + 0.5 must be 1, not 0 + 0.
	r.pierce = floori(r.pierce)
	r.chain_count = floori(r.chain_count)
	r.botnet_cap = floori(r.botnet_cap)
	return r

static func _fold(r: ResolvedExploit, em: EquippedModule) -> void:
	var m := em.module
	for key in m.stats:
		if not (key in Module.STAT_KEYS):
			push_error("module '%s': unknown stat key '%s'" % [m.id, key])
			continue
		r.set(key, r.get(key) + float(m.stats[key]) * em.rank)
	for t in m.tags:
		r.tags[t] = true

## A module contributing corruption must carry the corruption tag, or the stat
## and the tag drift apart silently: the flip check gates on the tag while the
## amount comes from the stat.
static func validate(m: Module) -> Array[String]:
	var errs: Array[String] = []
	for key in m.stats:
		if not (key in Module.STAT_KEYS):
			errs.append("module '%s': unknown stat key '%s'" % [m.id, key])
	if m.stats.has(&"corruption") and not m.has_tag(&"corruption"):
		errs.append("module '%s': contributes corruption without the corruption tag" % m.id)
	if m.max_rank < 1:
		errs.append("module '%s': max_rank must be >= 1" % m.id)
	return errs
