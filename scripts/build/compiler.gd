class_name Compiler extends RefCounted

## Pure. Modules + global player multipliers in, ResolvedExploit out. No scene
## tree, no globals.
## Runs once per module pick, never per frame — combat reads only the flat result.

const MIN_COOLDOWN := 0.05
const MAX_PROJECTILE_SPEED := 960.0

## The cooldown floor, as a fraction of the VECTOR's own base cadence. An
## absolute floor erases what distinguishes a vector — every fast build converges
## on the same number, and the clamp ends up doing the balancing. A proportional
## one cannot: every vector floors at the same fraction of a DIFFERENT base, so
## the ratio at the floor IS the base ratio, and hitting it is not a failure.
const MIN_CADENCE_FRACTION := 0.12

## Stats that accumulate by product rather than by sum.
const MUL_FOLD_KEYS := [&"cadence_mult"]

## How much of a rank a VECTOR's radius actually collects. See the carve-out in
## _fold for what linear growth did, and why zero growth was no better.
const VECTOR_RADIUS_RANK := 0.25

## Above this an execute stops being a finisher and becomes the damage model.
const MAX_EXECUTE := 0.5

## The turn-rate ceiling. Above roughly this a projectile is on the target
## within one tick at any range the view covers, which is the thing the rate is
## there to prevent.
const MAX_HOMING := 4.0

## Which global multiplier scales which stats. Total and non-overlapping: every
## stat key not named here is deliberately excluded.
##   - lifesteal is excluded so attack is not also the best defensive stat.
##   - projectile_speed is excluded because its cap prevents tunnelling through
##     the smallest combined radius; a multiplier applied before the cap would
##     silently do nothing at high values.
## Defensive magnitudes accumulate by MAX, not by +. One exploit can still carry
## ward_* on two modules at once — a TRIGGER and a PAYLOAD both may — so summing
## would buy double magnitude at zero uptime cost, the opposite of what a second
## source should be worth. This read "both payload slots" until the payload
## column was cut to one; the rule outlived its example.
const MAX_FOLD_KEYS := [
	&"ward_armor", &"ward_defense", &"ward_clock_speed", &"ward_duration",
	&"lifesteal",
	# The slow and the shield join on the same argument: they are magnitudes
	# bought once, and summing them across slots buys uptime for free.
	&"slow_amount", &"slow_duration", &"shield", &"shield_rearm",
	# A fraction. Two sources summing to 0.5 is not "a bit more execute".
	&"execute_below",
]

const MULT_KEYS := {
	&"attack": [&"damage", &"corruption"],
	&"haste":  [&"cooldown"],
	&"reach":  [&"radius", &"travel"],
}
## blast_radius is deliberately absent from `reach`. It takes radius's RANK
## carve-out because both are footprint growth on a vector, but the meta reach
## line is a TARGETING range upgrade — letting it inflate a detonation as well
## would pay one purchase twice on a blast build.

## The projectile_speed clamp guards an unbounded additive stat. The cooldown
## floors guard something else now: cadence is a product of positives, so it can
## no longer reach the -1.70s that once hung a `while accumulator >= cooldown`
## loop. See the two floors in build() for what each one is actually for.
## projectile_speed had no clamp at all and would have failed silently, as
## missed hits nobody could reproduce. 960 = 60 * (PROJECTILE_RADIUS 4 +
## ENEMY_RADIUS 12): the bound is the smallest combined radius, not the cell size.

## A row with a vector and no trigger fires on a BUILT-IN interval at this
## cadence penalty: the weapon works the moment it is placed, and a trigger
## card is an upgrade rather than a prerequisite. Above 1.0 so that placing
## `interval` (1.00) is still a real improvement. Playtest: three rows each
## needing one of three distinct starting triggers before firing at all made
## every new vector dead weight until the right card showed up.
const BARE_CADENCE := 1.30

static func build(ex: Exploit, mult: Dictionary = {}) -> ResolvedExploit:
	var r := ResolvedExploit.new()
	# Only a row with no VECTOR is inert; a row with no trigger is bare and
	# fires on the built-in interval below.
	r.inert = ex.vector == null

	# Kinds are read ONLY from their own slot. Folding them from every module in
	# turn lets the TRIGGER module's default enum value clobber the vector.
	if ex.vector != null:
		r.vector_kind = ex.vector.module.vector_kind
		r.targeting = ex.vector.module.targeting
		# A FUSED vector supplies both kinds, because its row has no trigger.
		if ex.vector.module.is_fused:
			r.trigger_kind = ex.vector.module.trigger_kind
	if not ex.head_is_fused() and ex.trigger != null:
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
	elif ex.vector != null and not ex.head_is_fused():
		# Bare row: the built-in interval, paid in cadence.
		r.trigger_kind = Module.TriggerKind.INTERVAL
		r.cadence_mult *= BARE_CADENCE

	# cooldown is contributed ONLY by vectors now — validate() enforces it — so at
	# this point r.cooldown IS the vector's raw base, which is exactly what the
	# proportional floor needs, with no extra field to carry it.
	var vector_base := r.cooldown
	r.cooldown *= r.cadence_mult
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

	# Two floors. The PROPORTIONAL one is where balance happens: every vector
	# bottoms out at the same fraction of a different base, so the ratio at the
	# floor is the base ratio and reaching it is not a failure.
	#
	# MIN_COOLDOWN is the absolute guard, and its real load is the NULL-VECTOR
	# path: an exploit founded on a TRIGGER has vector_base 0.0, so the
	# proportional floor collapses to 0.0 and only this stands between
	# _step5_fire's `while _fire_acc >= r.cooldown` and a zero cooldown. That
	# state is reachable — legal_targets offers EMPTY_SLOT on a not-yet-created
	# exploit for any slot type — and harmless, since every fire path gates on
	# r.inert, but it is what this constant is actually for.
	r.cooldown = maxf(r.cooldown,
		maxf(MIN_COOLDOWN, vector_base * MIN_CADENCE_FRACTION))
	r.projectile_speed = minf(r.projectile_speed, MAX_PROJECTILE_SPEED)
	# Fold in float, floor ONCE at the end: 0.5 + 0.5 must be 1, not 0 + 0.
	r.pierce = floori(r.pierce)
	r.chain_count = floori(r.chain_count)
	r.botnet_cap = floori(r.botnet_cap)
	r.orbit_count = floori(r.orbit_count)
	r.burst = floori(r.burst)
	r.split_count = floori(r.split_count)
	r.execute_below = clampf(r.execute_below, 0.0, MAX_EXECUTE)
	r.homing = minf(r.homing, MAX_HOMING)
	return r

## Rank scales the two directions of a cadence factor differently, and each half
## is the rule the other direction breaks under.
##
## Compounding a COST diverges: 1.52^5 = 8.1, which measured as a -53%..-63% DPS
## trap on ranking on_kill — the option Loadout.best_target scores highest, so
## the level-up screen would have recommended it. Applying a REDUCTION linearly
## goes NEGATIVE: the threshold is rank > 1/(1-f), so overclock (0.82) crosses at
## rank 6, one above max_rank. Compounding converges toward zero and never
## crosses it.
static func _rank_factor(f: float, rank: float) -> float:
	return pow(f, rank) if f < 1.0 else 1.0 + (f - 1.0) * rank

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
		var scale := float(em.rank)
		if is_vector and (key == &"cooldown" or key == &"travel"):
			# A vector's cadence and its range are base properties, not scaling
			# stats. travel especially: at em.rank a rank-3 packet would fly
			# 1920px and outrun every bound the design has.
			scale = 1.0
		elif is_vector and (key == &"radius" or key == &"blast_radius"):
			# A vector's radius grows, but far slower than its rank. At em.rank a
			# rank-5 broadcast reached 600px — most of a 1280x720 screen, from a
			# module whose whole cost was showing up five times. Freezing it
			# outright overcorrected: radius IS the damage for an AoE vector, and a
			# frozen one made rank close to worthless on three of the four vectors.
			# A quarter rate keeps the upgrade real and the footprint readable —
			# rank 5 is 2x, not 5x. PAYLOAD radius and `reach` still scale fully.
			scale = 1.0 + VECTOR_RADIUS_RANK * float(em.rank - 1)
		elif key == &"ward_duration" or key == &"shield_rearm":
			# Rank buys ward and shield magnitude, never uptime.
			scale = 1.0
		var v := float(m.stats[key]) * scale
		if key in MUL_FOLD_KEYS:
			# The RAW stat and `scale` — never `v`, and never em.rank. `v` is
			# already rank-scaled, so pow(v, rank) raises (value x rank) to the
			# power rank: pow(0.85*3, 3) = 16.58 against a correct 0.614, a 27x
			# SLOWDOWN. And `scale` rather than em.rank so that any carve-out
			# actually applies — reading em.rank here is what made an earlier
			# carve-out dead code.
			r.set(key, r.get(key) * _rank_factor(float(m.stats[key]), scale))
		elif key in MAX_FOLD_KEYS:
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
	# The same rule for slow, and for the same reason: the runtime gates on the
	# tag while the amount comes from the stat, so the two drifting apart is a
	# module that silently does nothing.
	if m.stats.has(&"slow_amount") and not m.has_tag(&"slow"):
		errs.append("module '%s': contributes slow_amount without the slow tag" % m.id)
	if m.max_rank < 1:
		errs.append("module '%s': max_rank must be >= 1" % m.id)

	# A factor of zero, negative, or vanishingly small. 1e-9 passes a bare "> 0".
	if m.stats.has(&"cadence_mult") and float(m.stats[&"cadence_mult"]) < 0.01:
		errs.append("module '%s': cadence_mult must be >= 0.01" % m.id)

	# The floor reads r.cooldown as the vector's raw base. A PAYLOAD shipping
	# {cooldown: 0.40} was measured passing validate(), poisoning vector_base and
	# collapsing broadcast:packet from 1.70 to 1.14.
	if m.slot != Module.Slot.VECTOR and m.stats.has(&"cooldown"):
		errs.append("module '%s': only a VECTOR may carry cooldown" % m.id)

	# The ratio guarantee needs the cadence product to be vector-INDEPENDENT. A
	# packet variant carrying cadence_mult 0.60 was measured producing a
	# SOME-floored state with the ratio sliding 2.83 -> 2.43 -> 1.99 -> 1.70. The
	# configuration also has no expressive power: applied once and unranked it is
	# identical to editing the vector's base, EXCEPT in the floor term, which
	# reads the raw base — so its only distinct behaviour IS the broken ratio.
	if m.slot == Module.Slot.VECTOR and m.stats.has(&"cadence_mult"):
		errs.append("module '%s': a VECTOR may not carry cadence_mult" % m.id)
	# The same argument that keeps cooldown off payloads: a payload granting an
	# execute threshold to every vector it is slotted into is a balance surface
	# nothing else in the table has.
	if m.slot != Module.Slot.VECTOR and m.stats.has(&"execute_below"):
		errs.append("module '%s': only a VECTOR may carry execute_below" % m.id)

	# Only a VECTOR may steer its own shots. A payload contributing homing to a
	# BROADCAST exploit is a stat that silently does nothing — the failure mode
	# the corruption-tag and slow-tag rules exist to catch.
	if m.slot != Module.Slot.VECTOR and m.stats.has(&"homing"):
		errs.append("module '%s': only a VECTOR may carry homing" % m.id)

	# burst is how many times an EVENT produces a shot, so it is meaningless on
	# anything but a trigger — and a payload carrying it would read as a damage
	# multiplier that silently does nothing on an interval build.
	# A FUSED module is the exception, because it IS its own trigger: it carries
	# trigger_kind and nothing else in its row does.
	if m.slot != Module.Slot.TRIGGER and not m.is_fused \
			and m.stats.has(&"burst"):
		errs.append("module '%s': only a TRIGGER or a fused module may carry burst" % m.id)

	# The guarantee's other precondition: below this the ABSOLUTE floor binds for
	# some vectors and not others, and the ratio collapses. Requires the KEY, not
	# merely a value when present — a VECTOR omitting cooldown has vector_base 0.0
	# and fires at a permanent 20/s, and the inert-path argument does not cover
	# it, because such an exploit with a trigger is NOT inert.
	if m.slot == Module.Slot.VECTOR and (not m.stats.has(&"cooldown") \
			or float(m.stats[&"cooldown"]) < MIN_COOLDOWN / MIN_CADENCE_FRACTION):
		errs.append("module '%s': a VECTOR must carry cooldown >= %.4f"
			% [m.id, MIN_COOLDOWN / MIN_CADENCE_FRACTION])
	return errs
