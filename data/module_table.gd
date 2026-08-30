class_name ModuleTable extends RefCounted

## The module registry, defined in code rather than scanned from .tres files.
##
## Review found that `DirAccess` scanning `data/modules/` works in the editor
## and in CI but not in an exported build — Godot's "convert text resources to
## binary" export setting is on by default, so the scan returns nothing and
## every player gets an empty card pool. A code table cannot go stale against
## itself and needs no build-time manifest step.
##
## Split: 4 VECTOR / 4 TRIGGER / 10 PAYLOAD = 18.
## Unlocked at start: 3 / 3 / 9 = 15. A 3-exploit board needs 3 distinct
## VECTORs and 3 distinct TRIGGERs, so anything less is not fillable.

const S := Module.Slot
const V := Module.VectorKind
const T := Module.TriggerKind

const LOCKED := [&"beam", &"on_damage_taken", &"worm"]

static func all() -> Array:
	return [
		# --- VECTOR ---------------------------------------------------------
		Module.make(&"broadcast", "broadcast()", S.VECTOR,
			{&"damage": 5.0, &"radius": 120.0, &"cooldown": 0.85}, [], V.BROADCAST),
		Module.make(&"packet", "packet()", S.VECTOR,
			{&"damage": 9.0, &"projectile_speed": 420.0, &"cooldown": 0.5,
			 &"travel": 640.0}, [], V.PACKET),
		Module.make(&"chain", "chain()", S.VECTOR,
			{&"damage": 7.0, &"chain_count": 2.0, &"radius": 170.0, &"cooldown": 0.9}, [], V.CHAIN),
		Module.make(&"beam", "beam()", S.VECTOR,
			{&"damage": 5.0, &"pierce": 3.0, &"radius": 240.0, &"cooldown": 0.6}, [], V.BEAM),

		# --- TRIGGER --------------------------------------------------------
		Module.make(&"interval", "interval(t)", S.TRIGGER,
			{&"cooldown": -0.10}, [], 0, T.INTERVAL),
		Module.make(&"on_kill", "on_kill()", S.TRIGGER,
			{&"damage": 3.0, &"cooldown": 0.35}, [], 0, T.ON_KILL),
		Module.make(&"on_hit", "on_hit()", S.TRIGGER,
			{&"damage": 1.0, &"cooldown": 0.20}, [], 0, T.ON_HIT),
		Module.make(&"on_damage_taken", "on_damage_taken()", S.TRIGGER,
			{&"damage": 8.0, &"radius": 40.0}, [], 0, T.ON_DAMAGE_TAKEN),

		# --- PAYLOAD --------------------------------------------------------
		Module.make(&"buffer_overflow", "buffer_overflow", S.PAYLOAD,
			{&"damage": 7.0}),
		Module.make(&"fork_bomb", "fork_bomb", S.PAYLOAD,
			{&"damage": 5.0, &"radius": 60.0}, [&"aoe"]),
		Module.make(&"corrupt", "corrupt", S.PAYLOAD,
			{&"corruption": 4.0}, [&"corruption"]),
		Module.make(&"keylog", "keylog", S.PAYLOAD,
			{&"lifesteal": 0.4}),
		Module.make(&"worm", "worm", S.PAYLOAD,
			{&"corruption": 2.0, &"chain_count": 1.0}, [&"corruption"]),
		Module.make(&"botnet_expand", "fork()", S.PAYLOAD,
			{&"botnet_cap": 2.0}),
		Module.make(&"overclock", "overclock", S.PAYLOAD,
			{&"damage": 2.0, &"cooldown": -0.12}),

		# --- PAYLOAD, defensive ------------------------------------------------
		# None contributes damage, so equipping one is a real cost against the two
		# payload slots. Magnitudes are set from worked worst cases: nice matches
		# the whole maxed bus_speed shop line (+60), so one module in one slot is
		# never worth more than 1,950 salvage of upgrades.
		Module.make(&"harden", "harden", S.PAYLOAD,
			{&"ward_armor": 1.2, &"ward_duration": 2.0}),
		Module.make(&"sandbox", "sandbox", S.PAYLOAD,
			{&"ward_defense": 10.0, &"ward_duration": 3.0}),
		Module.make(&"nice", "nice()", S.PAYLOAD,
			{&"ward_clock_speed": 12.0, &"ward_duration": 1.5}),
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
