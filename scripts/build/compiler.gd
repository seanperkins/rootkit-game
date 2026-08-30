class_name Compiler extends RefCounted

## Pure. Modules + global player multipliers in, ResolvedExploit out. No scene
## tree, no globals.
## Runs once per module pick, never per frame — combat reads only the flat result.

const MIN_COOLDOWN := 0.05
const MAX_PROJECTILE_SPEED := 960.0

## Which global multiplier scales which stats. Total and non-overlapping: every
## stat key not named here is deliberately excluded.
##   - lifesteal is excluded so attack is not also the best defensive stat.
##   - projectile_speed is excluded because its cap prevents tunnelling through
##     the smallest combined radius; a multiplier applied before the cap would
##     silently do nothing at high values.
## Defensive magnitudes accumulate by MAX, not by +. The same module is legal in
## both payload slots of one exploit, so summing would buy double magnitude at
## zero uptime cost — the opposite of what a second copy should be worth.
const MAX_FOLD_KEYS := [
	&"ward_armor", &"ward_defense", &"ward_clock_speed", &"ward_duration",
	&"lifesteal",
]

const MULT_KEYS := {
	&"attack": [&"damage", &"corruption"],
	&"haste":  [&"cooldown"],
	&"reach":  [&"radius", &"travel"],
}

## Both clamps guard the same bug class: an unbounded additive stat. Cooldown
## reached -1.70s at max rank and hung a `while accumulator >= cooldown` loop.
## projectile_speed had no clamp at all and would have failed silently, as
## missed hits nobody could reproduce. 960 = 60 * (PROJECTILE_RADIUS 4 +
## ENEMY_RADIUS 12): the bound is the smallest combined radius, not the cell size.

static func build(ex: Exploit, mult: Dictionary = {}) -> ResolvedExploit:
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

	# Captured pre-multiplier, pre-clamp. See ResolvedExploit.base_cooldown.
	r.base_cooldown = r.cooldown

	# The player layer is the PERCENTAGE layer: modules contribute flat numbers,
	# and these scale the total afterwards. mult holds absolutes (x1.40), not the
	# deltas SaveGame stores — PlayerStats.mults() is the converter.
	for mk in MULT_KEYS:
		var f := float(mult.get(mk, 1.0))
		if f == 1.0:
			continue
		for sk in MULT_KEYS[mk]:
			r.set(sk, r.get(sk) * f)

	r.cooldown = maxf(r.cooldown, MIN_COOLDOWN)
	r.projectile_speed = minf(r.projectile_speed, MAX_PROJECTILE_SPEED)
	# Fold in float, floor ONCE at the end: 0.5 + 0.5 must be 1, not 0 + 0.
	r.pierce = floori(r.pierce)
	r.chain_count = floori(r.chain_count)
	r.botnet_cap = floori(r.botnet_cap)
	return r

static func _fold(r: ResolvedExploit, em: EquippedModule) -> void:
	var m := em.module
	var is_vector := m.slot == Module.Slot.VECTOR
	for key in m.stats:
		if not (key in Module.STAT_KEYS):
			push_error("module '%s': unknown stat key '%s'" % [m.id, key])
			continue
		# A VECTOR's cooldown is its cadence, not a scaling stat. Folding it per
		# rank meant ranking broadcast (0.85 s) to rank 3 produced 2.55 s — the
		# weapon fired three times slower for three times the damage, which is
		# flat DPS, bad feel, and made MIN_COOLDOWN unreachable from the vector
		# side. Reductions from payloads and triggers still scale with rank.
		var scale: int = em.rank
		if is_vector and (key == &"cooldown" or key == &"travel"):
			# A vector's cadence and its range are base properties, not scaling
			# stats. travel especially: at em.rank a rank-3 packet would fly
			# 1920px and outrun every bound the design has.
			scale = 1
		elif key == &"ward_duration":
			# Rank buys ward magnitude, never uptime.
			scale = 1
		var v := float(m.stats[key]) * scale
		if key in MAX_FOLD_KEYS:
			r.set(key, maxf(r.get(key), v))
		else:
			r.set(key, r.get(key) + v)
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
