class_name ModuleTable extends RefCounted

## The module registry, defined in code rather than scanned from .tres files.
##
## Review found that `DirAccess` scanning `data/modules/` works in the editor
## and in CI but not in an exported build — Godot's "convert text resources to
## binary" export setting is on by default, so the scan returns nothing and
## every player gets an empty card pool. A code table cannot go stale against
## itself and needs no build-time manifest step.
##
## Split: 8 VECTOR / 7 TRIGGER / 15 PAYLOAD = 30.
## Unlocked at start: 5 / 3 / 11 = 19; see LOCKED below for why the rest is
## gated. A module id occupies exactly one slot (Loadout.legal_targets), so a
## full board of three exploits needs three distinct unlocked VECTORs and three
## distinct unlocked TRIGGERs. The starting pool clears that with room on the
## vector side and none at all on the trigger side: interval, on_kill and
## on_hit are exactly three. Locking a fourth trigger would make the third row
## unfillable until an unlock lands.

const S := Module.Slot
const V := Module.VectorKind
const T := Module.TriggerKind

## Roughly half the new breadth ships locked.
##
## The table went from 18 modules to 35 while a level-up still shows three
## cards, which roughly halves the odds of drawing what a build actually wants —
## and that makes builds mushier, not richer. Gating the breadth behind kill and
## flip milestones keeps the early pool the size and sharpness it has today.
const LOCKED := [&"beam", &"on_damage_taken", &"worm",
	&"landmine", &"mirror", &"checksum",
	&"on_low_integrity", &"on_flip", &"on_level_up",
	&"heap_spray", &"tarpit"]

static func all() -> Array:
	return [
		# --- VECTOR ---------------------------------------------------------
		# Base damage is ~30% off its first pass, and payload damage ~20%, because
		# a rank buys damage LINEARLY while enemy integrity used to be a constant:
		# past firewall's 34 HP everything died in one hit for the rest of the run.
		# SpawnDirector.hp_mult is the other half of that fix and the load-bearing
		# one — these numbers only set where the curve starts.
		Module.make(&"broadcast", "broadcast()", S.VECTOR,
			{&"damage": 3.5, &"radius": 90.0, &"cooldown": 0.85}, [], V.BROADCAST),
		Module.make(&"packet", "packet()", S.VECTOR,
			{&"damage": 6.0, &"projectile_speed": 420.0, &"cooldown": 0.5,
			 &"travel": 640.0}, [], V.PACKET),
		Module.make(&"chain", "chain()", S.VECTOR,
			{&"damage": 5.0, &"chain_count": 2.0, &"radius": 170.0, &"cooldown": 0.9}, [], V.CHAIN),
		Module.make(&"beam", "beam()", S.VECTOR,
			{&"damage": 3.5, &"pierce": 3.0, &"radius": 240.0, &"cooldown": 0.6}, [], V.BEAM),

		# --- TRIGGER --------------------------------------------------------
		# Triggers are paid on the axis their FREQUENCY suits. A frequent one is
		# paid in cadence, because its value is rate; a rare one is paid in
		# burst, because its value is the moment. on_flip is paid in corruption,
		# the resource its own build runs on.
		#
		# interval sits at 1.00 — the baseline every other trigger is measured
		# against, not a bonus. It used to be 0.85, which made it both faster
		# AND unconditional while every event trigger cost cadence for a
		# condition: an event trigger could never win, in any build.
		Module.make(&"interval", "interval(t)", S.TRIGGER,
			{&"cadence_mult": 1.00}, [], 0, T.INTERVAL),
		Module.make(&"on_kill", "on_kill()", S.TRIGGER,
			{&"damage": 3.0, &"cadence_mult": 0.70}, [], 0, T.ON_KILL),
		Module.make(&"on_hit", "on_hit()", S.TRIGGER,
			{&"damage": 1.0, &"cadence_mult": 0.62}, [], 0, T.ON_HIT),
		Module.make(&"on_damage_taken", "on_damage_taken()", S.TRIGGER,
			{&"damage": 8.0, &"radius": 40.0, &"cadence_mult": 0.90,
			 &"burst": 3.0}, [], 0, T.ON_DAMAGE_TAKEN),
		Module.make(&"on_low_integrity", "on_low_integrity()", S.TRIGGER,
			{&"damage": 6.0, &"cadence_mult": 1.00, &"burst": 5.0}, [], 0,
			T.ON_LOW_INTEGRITY),
		Module.make(&"on_flip", "on_flip()", S.TRIGGER,
			{&"corruption": 2.0, &"cadence_mult": 0.74}, [&"corruption"], 0,
			T.ON_FLIP),
		Module.make(&"on_level_up", "on_level_up()", S.TRIGGER,
			{&"cadence_mult": 1.00, &"burst": 8.0}, [], 0, T.ON_LEVEL_UP),

		# --- VECTOR, attack -------------------------------------------------
		Module.make(&"spike", "spike()", S.VECTOR,
			{&"damage": 9.0, &"radius": 150.0, &"cooldown": 0.75}, [], V.CONE),
		Module.make(&"landmine", "landmine()", S.VECTOR,
			{&"damage": 16.0, &"radius": 130.0, &"cooldown": 1.9}, [&"aoe"], V.MINE),

		# --- VECTOR, defensive ----------------------------------------------
		# Still weapons on a cadence; the payoff protects rather than kills.
		#
		# bounce is the one that had to come down. At 190 base radius it covered
		# a quarter of the screen from rank 1, and VECTOR_RADIUS_RANK is a
		# FRACTION of base — so the widest vector also grew the fastest in
		# absolute terms (47.5 px a rank against spike's 37.5). 150 makes that
		# growth 37.5 as well, without a bounce-only carve-out in the compiler.
		# The damage and cadence come down with it because knockback, not
		# damage, is what the module is for: at 2.0/1.1 s it was a defensive
		# vector paying an offensive price nothing else in the column paid.
		Module.make(&"bounce", "bounce()", S.VECTOR,
			{&"damage": 1.4, &"radius": 150.0, &"cooldown": 1.5,
			 &"knockback": 320.0}, [], V.PULSE),
		Module.make(&"mirror", "mirror()", S.VECTOR,
			{&"damage": 4.0, &"radius": 90.0, &"cooldown": 2.2,
			 &"orbit_count": 3.0}, [], V.ORBIT),

		# --- PAYLOAD --------------------------------------------------------
		Module.make(&"buffer_overflow", "buffer_overflow", S.PAYLOAD,
			{&"damage": 5.5}),
		Module.make(&"fork_bomb", "fork_bomb", S.PAYLOAD,
			{&"damage": 4.0, &"radius": 60.0}, [&"aoe"]),
		Module.make(&"corrupt", "corrupt", S.PAYLOAD,
			{&"corruption": 4.0}, [&"corruption"]),
		Module.make(&"keylog", "keylog", S.PAYLOAD,
			{&"lifesteal": 0.4}),
		Module.make(&"worm", "worm", S.PAYLOAD,
			{&"corruption": 2.0, &"chain_count": 1.0}, [&"corruption"]),
		Module.make(&"botnet_expand", "fork()", S.PAYLOAD,
			{&"botnet_cap": 2.0}),
		# Self-contained recovery payloads: one payload slot means neither can
		# borrow checksum's shield. Smaller pools trade capacity for a faster
		# rearm; overclock retains damage and the stronger recovery. Rearm is
		# unranked, so ranks buy shield magnitude without buying firing cadence.
		Module.make(&"overclock", "overclock", S.PAYLOAD,
			{&"damage": 2.0, &"shield": 12.0, &"shield_rearm": 1.6}),

		# --- PAYLOAD, defensive ------------------------------------------------
		# None contributes damage, so equipping one is a real cost against the one
		# payload slot an exploit has. Magnitudes are set from worked worst cases: nice matches
		# the whole maxed bus_speed shop line (+60), so one module in one slot is
		# never worth more than 1,950 salvage of upgrades.
		Module.make(&"harden", "harden", S.PAYLOAD,
			{&"ward_armor": 1.2, &"ward_duration": 2.0}),
		Module.make(&"sandbox", "sandbox", S.PAYLOAD,
			{&"ward_defense": 10.0, &"ward_duration": 3.0}),
		Module.make(&"nice", "nice()", S.PAYLOAD,
			{&"ward_clock_speed": 12.0, &"ward_duration": 1.5}),
		# Shield is a magnitude bought once; the rearm keeps it off the host
		# vector's cadence (a packet at the floor would refill it forty times
		# faster than the 2.6 s the old vector had). Unranked in Compiler._fold.
		Module.make(&"checksum", "checksum()", S.PAYLOAD,
			{&"shield": 26.0, &"shield_rearm": 2.6}),

		# --- PAYLOAD, added with the module set -----------------------------
		Module.make(&"bitmask", "bitmask", S.PAYLOAD, {&"pierce": 1.0}),
		Module.make(&"race_condition", "race_condition", S.PAYLOAD,
			{&"shield": 10.0, &"shield_rearm": 2.0}),
		Module.make(&"heap_spray", "heap_spray", S.PAYLOAD,
			{&"chain_count": 1.0, &"radius": 30.0}),
		Module.make(&"tarpit", "tarpit", S.PAYLOAD,
			{&"slow_amount": 0.35, &"slow_duration": 1.5}, [&"slow"]),
	]

static func by_id() -> Dictionary:
	var d := {}
	for m in all():
		d[m.id] = m
	return d

static func starting_unlocked() -> Array:
	var out := []
	for m in all():
		if not (m.id in LOCKED):
			out.append(m)
	return out
