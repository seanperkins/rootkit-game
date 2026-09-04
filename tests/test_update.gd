extends SceneTree

## The signed update manifest: parsing is strict (a hostile entry is refused,
## not clamped), archive signatures verify RSA-4096/SHA-256, version compares
## are numeric-by-token, and "dev" never updates itself. The crypto here runs
## on a throwaway keypair; the REAL public key's load and the openssl↔Godot
## signature format are pinned by the PUBKEY-load check and by
## tools/verify_feed.gd against a real manifest.

var failures := 0
var finished := {}

const CASES := ["manifest_parse_is_strict", "versions_compare_numerically",
	"dev_never_updates_itself", "archive_verification_rejects_tampering",
	"sha256_of_file_matches_known", "the_embedded_public_key_loads",
	"the_update_log_writes"]

func _initialize() -> void:
	print("ROOTKIT — update feed\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	manifest_parse_is_strict()
	versions_compare_numerically()
	dev_never_updates_itself()
	archive_verification_rejects_tampering()
	sha256_of_file_matches_known()
	the_embedded_public_key_loads()
	await the_update_log_writes()
	print("")
	for c in CASES:
		if not finished.has(c):
			print("  FAIL  case '%s' never finished — it aborted part way" % c)
			failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _manifest(platform: String = "macos") -> String:
	return JSON.stringify({
		"version": "0.4.1",
		"entries": {platform: _entry()}})

func _entry(overrides: Dictionary = {}) -> Dictionary:
	var e := {"version": "0.4.1", "url": "https://x/a.zip",
		"sha256": "a".repeat(64), "sig": "AAAA"}
	for k in overrides:
		e[k] = overrides[k]
	return e

func _with(e: Dictionary) -> String:
	return JSON.stringify({"version": "0.4.1", "entries": {"macos": e}})

func manifest_parse_is_strict() -> void:
	var entry := UpdateFeed.parse_manifest(_manifest(), "macos")
	_check("a well-formed manifest parses", [entry.get("version"), entry.get("url"),
		entry.get("sha256")], ["0.4.1", "https://x/a.zip", "a".repeat(64)])
	_check("on the right platform", entry.get("sig"), "AAAA")
	_check("a missing platform refuses", UpdateFeed.parse_manifest(_manifest("linux"), "macos").is_empty(), true)
	_check("garbage refuses", UpdateFeed.parse_manifest("not json", "macos").is_empty(), true)
	_check("no entries refuse",
		UpdateFeed.parse_manifest(JSON.stringify({"entries": {}}), "macos").is_empty(), true)
	var no_ver := _entry()
	no_ver.erase("version")
	_check("an entry without a version refuses",
		UpdateFeed.parse_manifest(_with(no_ver), "macos").is_empty(), true)
	var empty_v := _entry({"version": ""})
	_check("an empty entry version refuses",
		UpdateFeed.parse_manifest(_with(empty_v), "macos").is_empty(), true)
	# The manifest's top level and the entry's version can DISAGREE (a merged
	# feed from a newer tag carrying an older platform entry); the parse must
	# report the entry's — that is what the client compares against.
	var split := JSON.stringify({"version": "0.9.0", "entries": {"macos": _entry({"version": "0.4.1"})}})
	_check("the entry's own version wins over the top-level one",
		str(UpdateFeed.parse_manifest(split, "macos").get("version", "")), "0.4.1")
	_check("a non-hex sha refuses",
		UpdateFeed.parse_manifest(_with(_entry({"sha256": "Z".repeat(64)})), "macos").is_empty(), true)
	_check("a short sha refuses",
		UpdateFeed.parse_manifest(_with(_entry({"sha256": "a".repeat(63)})), "macos").is_empty(), true)
	_check("an overlong url refuses",
		UpdateFeed.parse_manifest(_with(_entry({"url": "u" + "x".repeat(999)})), "macos").is_empty(), true)
	_check("a missing signature refuses",
		UpdateFeed.parse_manifest(_with(_entry({"sig": ""})), "macos").is_empty(), true)
	_check("a non-string entry version refuses",
		UpdateFeed.parse_manifest(_with(_entry({"version": 5})), "macos").is_empty(), true)
	var old := _entry({"version": "0.4.0"})
	_check("a merged older entry parses at its own version",
		str(UpdateFeed.parse_manifest(_with(old), "macos").get("version", "")), "0.4.0")
	_check("an unknown platform key is empty", UpdateFeed.platform_key("BeOS"), "")
	_check("the real platforms map", [UpdateFeed.platform_key("macOS"), UpdateFeed.platform_key("Windows"),
		UpdateFeed.platform_key("Linux")], ["macos", "windows", "linux"])
	finished["manifest_parse_is_strict"] = true

func versions_compare_numerically() -> void:
	_check("0.4.0 is older than 0.4.1",
		UpdateFeed.compare_versions("0.4.0", "0.4.1"), -1)
	_check("0.4.9 is older than 0.4.10",
		UpdateFeed.compare_versions("0.4.9", "0.4.10"), -1)
	_check("equal versions compare zero",
		UpdateFeed.compare_versions("0.4.0", "0.4.0"), 0)
	_check("a leading v is ignored",
		UpdateFeed.compare_versions("v0.4.1", "0.4.1"), 0)
	_check("short and long forms agree",
		UpdateFeed.compare_versions("0.4", "0.4.0"), 0)
	_check("a suffix starts a new token, not a digit",
		UpdateFeed.compare_versions("0.4.0-rc1", "0.4.0"), 0)
	_check("and it is not newer than the next release",
		UpdateFeed.compare_versions("0.4.0-rc1", "0.4.1"), -1)
	_check("the state says a newer build is wanted",
		UpdateFeed.should_update("0.4.0", "0.4.1"), true)
	_check("and an equal build is not",
		UpdateFeed.should_update("0.4.1", "0.4.1"), false)
	finished["versions_compare_numerically"] = true

func dev_never_updates_itself() -> void:
	_check("dev skips a newer release", UpdateFeed.should_update("dev", "0.4.1"), false)
	_check("and a dev feed entry is never applied", UpdateFeed.should_update("0.4.0", "dev"), false)
	_check("dev sorts below every number", UpdateFeed.compare_versions("dev", "0.0.1"), -1)
	finished["dev_never_updates_itself"] = true

func archive_verification_rejects_tampering() -> void:
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var pub := key.save_to_string(true)
	var msg := "attack at dawn — signed twice".to_utf8_buffer()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(msg)
	var digest := ctx.finish()
	var sig := crypto.sign(HashingContext.HASH_SHA256, digest, key)
	_check("an honest signature verifies",
		UpdateFeed.verify_archive(digest, Marshalls.raw_to_base64(sig), pub), true)
	var bad := sig.duplicate()
	bad[0] ^= 0x01
	_check("a flipped signature byte is refused",
		UpdateFeed.verify_archive(digest, Marshalls.raw_to_base64(bad), pub), false)
	var other := crypto.generate_rsa(2048)
	_check("a signature from another key is refused",
		UpdateFeed.verify_archive(digest, Marshalls.raw_to_base64(sig), other.save_to_string(true)), false)
	_check("a digest of the wrong size is refused",
		UpdateFeed.verify_archive(digest.slice(0, 16), Marshalls.raw_to_base64(sig), pub), false)
	_check("garbage base64 is refused",
		UpdateFeed.verify_archive(digest, "!!!", pub), false)
	finished["archive_verification_rejects_tampering"] = true

func sha256_of_file_matches_known() -> void:
	var path := "user://update_feed_test.bin"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer("abc".to_utf8_buffer())
	f.close()
	var digest := UpdateFeed.sha256_of_file(path)
	var hex := ""
	for b in digest:
		hex += "%02x" % b
	_check("sha256('abc') matches the known digest", hex,
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	_check("a missing file yields an empty digest",
		UpdateFeed.sha256_of_file("user://no_such_file.bin").is_empty(), true)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	finished["sha256_of_file_matches_known"] = true

func the_embedded_public_key_loads() -> void:
	var key := CryptoKey.new()
	_check("the embedded PUBKEY is a loadable RSA public key",
		key.load_from_string(UpdateFeed.PUBKEY, true), OK)
	_check("and it is public-only", key.is_public_only(), true)
	finished["the_embedded_public_key_loads"] = true

## The support log is the only trace for the silent-failure design; READ_WRITE
## refuses to create a missing file, so the first-ever write must take the
## WRITE branch or the log never exists.
func the_update_log_writes() -> void:
	var u = load("res://scripts/update/updater.gd").new()
	root.add_child(u)
	await process_frame
	u._log("hello world")
	var path := "user://update_log.txt"
	_check("the log file is created on first write", FileAccess.file_exists(path), true)
	var f := FileAccess.open(path, FileAccess.READ)
	_check("and retains the line", f != null and f.get_as_text().contains("hello world"), true)
	if f != null:
		f.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	u.queue_free()
	finished["the_update_log_writes"] = true
