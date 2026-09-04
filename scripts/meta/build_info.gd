class_name BuildInfo extends RefCounted

## The build version, in the two forms the game needs.
##
## `version()` is CANONICAL: what peers compare in the handshake and what the
## updater measures the feed against. `display_version()` is the same string
## with `.dev` appended in a dev build, and it is for HUMANS ONLY — the run
## HUD's corner and the menu's version label.
##
## The split is the whole point. A dev tree is not the tag it sits on, so it is
## worth SAYING so on screen; but stamping that difference into the wire would
## refuse a local build against a shipped one of the same tag, and testing
## co-op between the two is a thing worth being able to do. Same reasoning for
## the updater: `UpdateFeed.should_update` refuses anything called "dev", so a
## `.dev` canonical version would make ROOTKIT_UPDATE_CHECK=1 unable to
## exercise the very path it exists to exercise.
##
## In a release build both forms are `application/config/version` verbatim —
## the tag `tools/release_mac.sh` and the CI export stamp in — and nothing here
## shells out. The git call happens only when `has_feature("editor")` says this
## is not an exported template.

const DEV_SUFFIX := ".dev"

## Both are resolved once. `OS.execute` costs milliseconds, and
## `ui._version_string()` is called from `_refresh`, which runs every frame.
static var _version := ""
static var _display := ""

## What the handshake and the updater use. The last tag reachable from HEAD in
## a dev build, the stamped tag in a release one.
static func version() -> String:
	if _version.is_empty():
		_version = _resolve()
	return _version

## What the player sees. `version()` plus `.dev` when this is not an exported
## build, so a screenshot of a dev run can never be mistaken for the release
## it was cut from.
static func display_version() -> String:
	if _display.is_empty():
		_display = version() + (DEV_SUFFIX if is_dev() else "")
	return _display

## "editor" is set for any run that is not an exported template, which is
## exactly what "a dev build" means here. Matches the updater's own guard.
static func is_dev() -> bool:
	return OS.has_feature("editor")

static func _stamped() -> String:
	var v: Variant = ProjectSettings.get_setting("application/config/version")
	return "dev" if v == null else String(v)

static func _resolve() -> String:
	var stamped := _stamped()
	if not is_dev():
		return stamped
	var out: Array = []
	# -C the project root rather than trusting the working directory: the game
	# can be launched from anywhere, and `git describe` in the wrong tree would
	# answer confidently about the wrong repository.
	var code := OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"),
		"describe", "--tags", "--abbrev=0"], out)
	return from_git(code, out, stamped)

## The pure half, so a suite can drive every branch — the OS.execute above
## cannot be made to fail on demand.
##
## `git describe --tags --abbrev=0` prints the most recent tag reachable from
## HEAD, which is "the last tag on the branch we are working from". A missing
## git, a tree that is not a repository, and a repository with no tags all
## come back non-zero or empty, and all mean the same thing here: fall back to
## whatever the project file says rather than inventing a version.
static func from_git(code: int, output: Array, stamped: String) -> String:
	if code != 0 or output.is_empty():
		return stamped
	var tag := String(output[0]).strip_edges()
	if tag.is_empty():
		return stamped
	# Tags are cut as v0.4.2; every version string in this codebase is bare.
	# UpdateFeed._parts trims the same prefix for the same reason.
	return tag.trim_prefix("v").trim_prefix("V")
