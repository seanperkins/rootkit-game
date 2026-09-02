class_name Module extends Resource

enum Slot        { VECTOR, TRIGGER, PAYLOAD }
## Appended, never reordered: these values are stored on modules, so inserting
## in the middle silently repoints every module defined above the insert.
enum VectorKind  { BROADCAST, PACKET, CHAIN, BEAM, CONE, PULSE, MINE, ORBIT }
enum TriggerKind { INTERVAL, ON_KILL, ON_HIT, ON_DAMAGE_TAKEN,
	ON_LOW_INTEGRITY, ON_FLIP, ON_LEVEL_UP }

## How a vector chooses among the enemies in range. Only CHAIN and the homing
## re-acquire consult it now — BEAM, CONE and PACKET fire along the owner's
## facing, and BROADCAST, PULSE, MINE and ORBIT resolve from the player's
## position. Three modes, not four; the enum is append-safe.
enum Targeting  { NEAREST, STRONGEST, FARTHEST }

## The numeric scalar fields of ResolvedExploit, and the ONLY legal stat keys.
## Asserting against "fields of ResolvedExploit" would admit stats["tags"] = 1.0
## — a float written into a Dictionary.
const STAT_KEYS := [
	&"damage", &"corruption", &"lifesteal", &"cooldown", &"radius",
	&"pierce", &"chain_count", &"projectile_speed",
	&"botnet_cap", &"botnet_lifetime", &"botnet_damage_ratio",
	&"ward_armor", &"ward_defense", &"ward_clock_speed", &"ward_duration",
	&"travel", &"cadence_mult",
	&"knockback", &"slow_amount", &"slow_duration", &"shield", &"orbit_count",
	&"burst", &"split_count", &"blast_radius", &"execute_below", &"homing",
	&"shield_rearm",
]

@export var id: StringName
@export var display_name: String
@export var slot: Slot
@export var tags: Array[StringName] = []
@export var max_rank: int = 5
@export var stats: Dictionary = {}
@export var vector_kind: VectorKind = VectorKind.BROADCAST
@export var trigger_kind: TriggerKind = TriggerKind.INTERVAL

## Fused modules are produced by RecipeTable, not drawn from ModuleTable, and
## are excluded from ordinary card draws. A fused module is a VECTOR that also
## carries a trigger_kind, so its row needs no TRIGGER module.
@export var is_fused: bool = false
@export var targeting: Targeting = Targeting.NEAREST

static func make(p_id: StringName, p_name: String, p_slot: Slot, p_stats: Dictionary,
		p_tags: Array = [], p_vk: int = 0, p_tk: int = 0, p_max_rank: int = 5) -> Module:
	var m := Module.new()
	m.id = p_id
	m.display_name = p_name
	m.slot = p_slot
	m.stats = p_stats
	var t: Array[StringName] = []
	for x in p_tags:
		t.append(x)
	m.tags = t
	m.vector_kind = p_vk
	m.trigger_kind = p_tk
	m.max_rank = p_max_rank
	return m

func has_tag(t: StringName) -> bool:
	return tags.has(t)
