extends Node

## The auto-updater. Presentation infra: it sits above the world guard and the
## simulation never calls it — the menu drives a check, the player drives the
## install, and nothing inside a session is ever interrupted. Apply happens in
## a platform helper AFTER this process exits: the running executable is the
## code being replaced, so there is no in-place patch of a live process. The
## helper is copied to the OS cache first, because the helper that ships in
## the install directory is about to be deleted by the swap it performs.
##
## Download + verify happen here (HTTPRequest + UpdateFeed). The archive is
## unpacked by the platform helper — NEVER by ZIPReader, which cannot carry a
## macOS app's mode bits or ditto's AppleDouble metadata, and would leave a
## broken, unsigned bundle in its place.

signal update_ready(info: Dictionary)
signal update_state(text: String)
signal update_failed(reason: String)

const FEED_URL := "https://github.com/seanperkins/rootkit-game/releases/latest/download/latest.json"
const STATE_FILE := "user://update_state.json"
const MARKER_STATE := "rootkit-update-state"

var available: Dictionary = {}
var busy := false
var _downloading := false
var _download_path := ""
var _relaunch := false
var _closing := false
var _check_req: HTTPRequest
var _download_req: HTTPRequest

func _ready() -> void:
	_check_req = HTTPRequest.new()
	_check_req.request_completed.connect(_on_check_done)
	# No timeout on a check means a hung connection never answers and the menu
	# silently shows nothing — the one failure mode with no trace.
	_check_req.timeout = 15.0
	add_child(_check_req)
	_download_req = HTTPRequest.new()
	_download_req.request_completed.connect(_on_download_done)
	add_child(_download_req)
	_clear_stale_state()

## The updater is designed to be quiet (background failures never nag the
## player), which makes the "no update appeared" bug class invisible. Keep a
## one-line log for support: every check/download result, timestamped.
func _log(text: String) -> void:
	# READ_WRITE does NOT create a missing file — first call would no-op and
	# the log would never exist. Create with WRITE, then append.
	var f: FileAccess
	if FileAccess.file_exists("user://update_log.txt"):
		f = FileAccess.open("user://update_log.txt", FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
	else:
		f = FileAccess.open("user://update_log.txt", FileAccess.WRITE)
	if f == null:
		return
	f.store_line("[%d] %s" % [Time.get_unix_time_from_system(), text])
	f.close()

func _process(_dt: float) -> void:
	if not _downloading:
		return
	var total := _download_req.get_body_size()
	var got := _download_req.get_downloaded_bytes()
	if total > 0:
		update_state.emit("downloading update — %d%%" % (got * 100 / total))

func current_version() -> String:
	var v: Variant = ProjectSettings.get_setting("application/config/version")
	return "dev" if v == null else str(v)

func translated_platform() -> String:
	match OS.get_name():
		"macOS":
			return "macos"
		"Windows":
			return "windows"
		"Linux":
			return "linux"
	return ""

## Is the game running out of a quarantined read-only mount? macOS relocates a
## downloaded .app launched from anywhere but /Applications (or the app's own
## directory); the mount is read-only, so a self-update would silently fail.
func translocated() -> bool:
	return OS.get_name() == "macOS" and "AppTranslocation" in OS.get_executable_path()

## The directory the update swaps into. macOS: the parent of ROOTKIT.app (the
## whole bundle is replaced — not its contents). Windows/Linux: the game's own
## directory.
func install_target() -> String:
	var exe := OS.get_executable_path()
	if OS.get_name() == "macOS":
		var idx := exe.find("ROOTKIT.app")
		if idx > 0:
			return exe.substr(0, idx)
	return exe.get_base_dir()

## The environment variable that puts the update check back in a dev build.
const CHECK_OVERRIDE_VAR := "ROOTKIT_UPDATE_CHECK"

## Whether a BACKGROUND check should run at all.
##
## A dev build does not phone home. `godot` from the project root is not a
## build any release archive can replace — the swap targets an exported app
## bundle or executable, and there is none — so an update offer there is at
## best noise between the developer and the menu, and at worst an invitation
## to press a button whose install path cannot apply to what is running.
##
## Split out, and handed its inputs rather than reading them, because
## begin_check() returns early on headless and headless is every suite: a
## guard written inline there could never be driven by a test.
static func auto_check_allowed(is_dev: bool, override_value: String) -> bool:
	if not is_dev:
		return true
	# Any value but the empty string and "0" turns it back on, so
	# ROOTKIT_UPDATE_CHECK=1 and =true both do what they look like they do.
	return override_value != "" and override_value != "0"

func begin_check() -> void:
	# No networking in headless runs — the suites load this autoload too.
	if OS.has_feature("headless") or busy:
		return
	# "editor" is set for any run that is not an exported template, which is
	# exactly what "a dev build" means here.
	if not auto_check_allowed(OS.has_feature("editor"),
			OS.get_environment(CHECK_OVERRIDE_VAR)):
		return
	busy = true
	var err := _check_req.request(FEED_URL)
	if err != OK:
		busy = false
		update_failed.emit("cannot reach the update server")

func _on_check_done(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	busy = false
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_log("check failed: result %d, code %d" % [result, code])
		update_failed.emit("cannot reach the update server")
		return
	var entry := UpdateFeed.parse_manifest(body.get_string_from_utf8(),
		translated_platform())
	if entry.is_empty():
		_log("check: feed not readable")
		update_failed.emit("the update feed is not readable")
		return
	if not UpdateFeed.should_update(current_version(), str(entry["version"])):
		_log("check: up to date (%s)" % current_version())
		return
	available = entry
	_log("check: update available v%s" % entry["version"])
	update_ready.emit(available)

## Download + verify + install, then quit and relaunch the new build. The only
## automatic apply points in the game; a session is never interrupted — the
## player is on the menu when they press this.
func install_now() -> void:
	install_with_relaunch(true)

## Download + verify now, swap at the next quit (never mid-run; the helper is
## spawned from WM_CLOSE_REQUEST, which only fires when the window closes).
func install_on_quit() -> void:
	install_with_relaunch(false)

## Set while the PLAYER asked for an install: background failures (check on
## the menu, offline) must not light the strip up on every launch.
var user_requested := false

func install_with_relaunch(relaunch: bool) -> void:
	if available.is_empty():
		user_requested = false
		return
	user_requested = true
	if translocated():
		# The running bundle sits on a read-only mount; the swap must happen
		# in the real install location. Tell the player to move it first.
		update_failed.emit("this copy is quarantined — move ROOTKIT.app to /Applications (button at the bottom) and relaunch")
		return
	_relaunch = relaunch
	_download()

func _download() -> void:
	if busy:
		return
	busy = true
	var dir := DirAccess.open("user://")
	if dir == null or dir.make_dir_recursive("updates") != OK:
		busy = false
		update_failed.emit("cannot write the update directory")
		return
	_download_path = "user://updates/%s-%s.zip" % [str(available["version"]),
		translated_platform()]
	if FileAccess.file_exists(_download_path):
		_on_archive_ready()   # redownloading a 60 MB file to throw it away is waste
		return
	_downloading = true
	update_state.emit("downloading update…")
	# download_file streams the body straight to disk (the archive is ~60 MB;
	# it must never be buffered whole in the request). The bounds are
	# hostile-feed guards: an entry claiming a giant archive is refused by
	# body_size_limit before anything is written, and a hung CDN must not
	# wedge the menu forever.
	_download_req.download_file = ProjectSettings.globalize_path(_download_path)
	_download_req.body_size_limit = 512 << 20
	_download_req.timeout = 90.0
	var err := _download_req.request(str(available["url"]))
	if err != OK:
		_downloading = false
		busy = false
		update_failed.emit("cannot start the download")

func _on_download_done(result: int, code: int, _headers: PackedStringArray,
		_body: PackedByteArray) -> void:
	_downloading = false
	# With download_file set the body never reaches memory — the file on disk
	# IS the deliverable, and its existence is the success signal.
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 \
			or not FileAccess.file_exists(_download_path):
		if FileAccess.file_exists(_download_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(_download_path))
		busy = false
		update_failed.emit("the download failed (code %d)" % code)
		return
	_on_archive_ready()

func _on_archive_ready() -> void:
	update_state.emit("verifying update…")
	var digest := UpdateFeed.sha256_of_file(_download_path)
	var hex := ""
	for b in digest:
		hex += "%02x" % b
	if hex != str(available["sha256"]):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_download_path))
		busy = false
		update_failed.emit("the update failed its checksum")
		return
	if not UpdateFeed.verify_archive(digest, str(available["sig"])):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_download_path))
		busy = false
		update_failed.emit("the update failed its signature — refusing to install")
		return
	if _relaunch:
		update_state.emit("installing — the game will restart…")
		if _spawn_helper(true):
			get_tree().quit()
			return
		busy = false
		update_failed.emit("could not start the installer")
		return
	# Apply at quit: the helper is spawned from WM_CLOSE_REQUEST.
	var state := FileAccess.open(STATE_FILE, FileAccess.WRITE)
	if state != null:
		state.store_string(JSON.stringify({
			"version": str(available["version"]),
			"archive": ProjectSettings.globalize_path(_download_path),
			"target": install_target(),
			"relaunch": false}))
		state.close()
	busy = false
	update_state.emit("update v%s staged — it will apply when you quit the game" % available["version"])

## A pending apply-on-quit exists and must run when the window closes.
func pending() -> bool:
	return FileAccess.file_exists(_state_abs())

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not _closing and pending():
		_closing = true
		_spawn_helper(false)

## The archive a spawn installs. Right after a download it is the in-memory
## path; on a later close of a STAGED session there is no memory, so it comes
## from the state file instead. A staged archive that no longer exists drops
## the state — there is nothing to apply.
func _resolve_archive() -> String:
	if _download_path != "" and FileAccess.file_exists(_download_path):
		return ProjectSettings.globalize_path(_download_path)
	var state := _read_state()
	if state.is_empty():
		return ""
	var archive := str(state.get("archive", ""))
	if archive == "" or not FileAccess.file_exists(archive):
		DirAccess.remove_absolute(_state_abs())
		return ""
	return archive

func _resolve_target() -> String:
	if _download_path != "":
		return install_target()
	var state := _read_state()
	if state.is_empty():
		return install_target()
	var target := str(state.get("target", ""))
	return target if target != "" else install_target()

func _read_state() -> Dictionary:
	if not FileAccess.file_exists(_state_abs()):
		return {}
	var f := FileAccess.open(_state_abs(), FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func _spawn_helper(relaunch: bool) -> bool:
	var archive := _resolve_archive()
	if archive == "":
		update_failed.emit("the update is gone — try installing it again")
		return false
	var src := _helper_source()
	if not FileAccess.file_exists(src):
		update_failed.emit("the installer is missing from this build")
		return false
	var tmp := OS.get_cache_dir().path_join("rootkit-updater." + _helper_ext())
	var copy := FileAccess.open(src, FileAccess.READ)
	if copy == null:
		return false
	var bytes := copy.get_buffer(copy.get_length())
	copy.close()
	var out := FileAccess.open(tmp, FileAccess.WRITE)
	if out == null:
		return false
	out.store_buffer(bytes)
	out.close()
	if OS.get_name() != "Windows":
		OS.execute("chmod", ["+x", tmp])
	var pid := -1
	if OS.get_name() == "Windows":
		pid = OS.create_process("powershell.exe", [
			"-NoProfile", "-WindowStyle", "Hidden",
			"-ExecutionPolicy", "Bypass", "-File", tmp,
			"-Archive", archive,
			"-Target", _resolve_target(),
			"-Relaunch", "1" if relaunch else "0",
			"-State", _state_abs()])
	else:
		var shell := "/bin/bash" if OS.get_name() == "macOS" else "/bin/sh"
		pid = OS.create_process(shell, [
			tmp,
			"--archive", archive,
			"--target", _resolve_target(),
			"--relaunch", "1" if relaunch else "0",
			"--state", _state_abs()])
	return pid > 0

func _state_abs() -> String:
	return ProjectSettings.globalize_path(STATE_FILE)

func _helper_source() -> String:
	var exe := OS.get_executable_path()
	if OS.get_name() == "macOS":
		return exe.get_base_dir().path_join("..").path_join("Resources") \
			.path_join("updater.sh")
	return exe.get_base_dir().path_join("updater.ps1" if OS.get_name() == "Windows" \
		else "updater.sh")

func _helper_ext() -> String:
	return "ps1" if OS.get_name() == "Windows" else "sh"

## A state file whose version equals the running build is a leftover the
## helper did not clear (or a swap that already happened) — no pending work.
func _clear_stale_state() -> void:
	if not FileAccess.file_exists(_state_abs()):
		return
	var f := FileAccess.open(_state_abs(), FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		DirAccess.remove_absolute(_state_abs())
		return
	if str(parsed.get("version", "?")) == current_version():
		DirAccess.remove_absolute(_state_abs())
