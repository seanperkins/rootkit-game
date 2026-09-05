class_name RouteTable extends RefCounted

## Stable IDs. The ballot draws three distinct packages before generating the
## destination. Rewards name their source; effects last for that subnet only.
const NAMES := ["SWARM EXCHANGE", "ARMORED ARCHIVE", "CORRUPTED RELAY",
	"THERMAL OVERFLOW", "HUNTER PROTOCOL", "EARLY INTERRUPT", "COMPRESSED CORE"]
const DETAILS := [
	"+25% wave density\n-15% regular enemy integrity\n+1 XP shard per enemy",
	"+25% regular enemy integrity\n-15% wave density\n+150 salvage on boss defeat",
	"-25% corruption thresholds\n+15% wave density\n+4 shared botnet capacity",
	"12 extra terrain panels\n4 hazard / 4 slow / 4 corruption\n+150 salvage on boss defeat",
	"Every third wave enemy is a tracer\nSame total wave count\n+150 salvage on boss defeat",
	"First miniboss at 55s (was 80s)\nOther arrivals unchanged\n+150 salvage on boss defeat",
	"Smaller core + service passage\nAbout 40% less open ground\n+150 salvage on boss defeat"]
const RATE := [1.25, 0.85, 1.15, 1.0, 1.0, 1.0, 1.0]
const HP := [0.85, 1.25, 1.0, 1.0, 1.0, 1.0, 1.0]
const BOSS_SALVAGE := [0, 150, 0, 150, 150, 150, 150]
const LAYOUT := [0, 0, 0, 1, 0, 0, 2]

static func affinity(route: int, builds: Array) -> String:
	if route >= 3:
		return ["Watch panel markings; keep an escape lane.",
			"Tracers lead your movement. Change direction.",
			"Prepare your build for an earlier opening encounter.",
			"Less kiting space; keep the service lane clear."][route - 3]
	var count := 0
	for r in builds:
		if r == null: continue
		match route:
			0:
				if r.vector_kind in [Module.VectorKind.BROADCAST, Module.VectorKind.CONE, Module.VectorKind.CHAIN, Module.VectorKind.PULSE]: count += 1
			1:
				if r.damage >= 12.0 or r.pierce > 0: count += 1
			2:
				if r.corruption > 0.0: count += 1
	return "%d equipped %s weapons" % [count, ["crowd-control", "heavy-hit / piercing", "corruption"][route]]
