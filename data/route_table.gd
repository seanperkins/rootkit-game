class_name RouteTable extends RefCounted

## Modifier packages for the next prebuilt arena; never regenerate terrain.
const NAMES := ["SWARM EXCHANGE", "ARMORED ARCHIVE", "CORRUPTED RELAY"]
const DETAILS := [
	"+25% wave density\n-15% regular enemy integrity\n+1 XP shard per enemy",
	"+25% regular enemy integrity\n-15% wave density\n+150 salvage on boss defeat",
	"-25% corruption thresholds\n+15% wave density\n+4 shared botnet capacity"]
const RATE := [1.25, 0.85, 1.15]
const HP := [0.85, 1.25, 1.0]

static func affinity(route: int, builds: Array) -> String:
	var count := 0
	for r in builds:
		if r == null:
			continue
		match route:
			0:
				if r.vector_kind in [Module.VectorKind.BROADCAST, Module.VectorKind.CONE, Module.VectorKind.CHAIN, Module.VectorKind.PULSE]:
					count += 1
			1:
				if r.damage >= 12.0 or r.pierce > 0:
					count += 1
			2:
				if r.corruption > 0.0:
					count += 1
	var specialty: String = ["crowd-control", "heavy-hit / piercing", "corruption"][route]
	return "%d equipped %s weapon%s" % [count, specialty, "" if count == 1 else "s"]
