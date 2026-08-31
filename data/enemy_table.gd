class_name EnemyTable extends RefCounted

## Enemy types. contact_damage and shard_value live here, not on the packed
## arrays — every entity of a type shares them, so a type index is enough.

## What an enemy DOES, beyond how much of it there is.
##
## Every enemy used to move identically — normalise toward the player, add a
## separation force — so type changed HP, speed and contact damage and nothing
## else. One tactical question with one answer, which was "kite away".
enum Behaviour { CHASE, CHARGER, FLANKER, SUPPORT, AMBUSHER, RANGED }

class EnemyType extends RefCounted:
	var id: StringName
	var glyph: int              # index into the glyph set
	var color: Color
	var integrity: float
	var speed: float
	var corruption_threshold: float
	var contact_damage: float
	var shard_value: int
	var behaviour: int
	## `bh` defaults, so the four original rows need no change and adding a
	## behaviour to one of them later is a one-word edit.
	func _init(p_id: StringName, g: int, c: Color, hp: float, sp: float,
			ct: float, cd: float, sv: int, bh: int = Behaviour.CHASE) -> void:
		id = p_id; glyph = g; color = c; integrity = hp; speed = sp
		corruption_threshold = ct; contact_damage = cd; shard_value = sv
		behaviour = bh

static func all() -> Array:
	return [
		EnemyType.new(&"daemon",   0, Color(0.30, 1.00, 0.55), 10.0, 74.0,  10.0,  7.0, 1),
		EnemyType.new(&"firewall", 1, Color(1.00, 0.45, 0.30), 34.0, 50.0,  20.0, 12.0, 4),
		EnemyType.new(&"worm",     2, Color(0.55, 0.70, 1.00),  6.0, 118.0,  6.0,  5.0, 2),
		EnemyType.new(&"sentinel", 5, Color(1.00, 0.75, 0.25), 46.0, 78.0,
			26.0, 16.0, 3, Behaviour.CHARGER),
		EnemyType.new(&"tracer",   6, Color(0.55, 1.00, 0.95), 14.0, 124.0,
			12.0,  6.0, 2, Behaviour.FLANKER),
		EnemyType.new(&"watchdog", 7, Color(0.70, 0.85, 1.00), 70.0, 44.0,
			34.0,  4.0, 5, Behaviour.SUPPORT),
		EnemyType.new(&"rootkit",  8, Color(0.85, 0.45, 1.00), 34.0, 96.0,
			22.0, 18.0, 3, Behaviour.AMBUSHER),
		EnemyType.new(&"probe",    9, Color(1.00, 0.55, 0.55), 16.0, 52.0,
			14.0,  3.0, 2, Behaviour.RANGED),
		# ICE stays LAST: EnemyTable.ICE is an index into this list, and the boss
		# spawn, the win condition and the flip guard all read it.
		EnemyType.new(&"ice",      3, Color(1.00, 0.25, 0.85), 700.0, 46.0, 1e18, 22.0, 0),
	]

const ICE := 8   # the boss. corruption_threshold is effectively infinite:
                 # flipping it would bypass the kill-to-win condition.
