class_name ProgramTable extends RefCounted

## Sidegrades selected before connecting; the descriptor freezes the choice.
const IDS := ["operator", "ghost", "bulwark", "virus"]
const NAMES := ["OPERATOR", "GHOST", "BULWARK", "VIRUS"]
const DETAILS := [
	"packet() / balanced integrity and mobility",
	"spike() / +20% movement, -20% integrity",
	"broadcast() / +25% integrity, -15% movement",
	"chain() + corrupt / -20% weapon damage, -15% integrity"]
const VECTORS := [&"packet", &"spike", &"broadcast", &"chain"]

static func clean(value: Variant) -> String:
	return value if typeof(value) == TYPE_STRING and value in IDS else "operator"

static func index(value: Variant) -> int:
	return IDS.find(clean(value))

static func apply_sheet(sheet: Dictionary, id: String) -> void:
	match id:
		"ghost":
			sheet[&"clock_speed"] *= 1.20
			sheet[&"integrity"] *= 0.80
		"bulwark":
			sheet[&"clock_speed"] *= 0.85
			sheet[&"integrity"] *= 1.25
		"virus":
			sheet[&"integrity"] *= 0.85
