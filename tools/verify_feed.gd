extends SceneTree

## Verify one signed update entry end to end, exactly as the client will:
##   godot --headless -s res://tools/verify_feed.gd <latest.json> <archive>
## Reads the manifest, checks the archive's SHA-256 against the entry, then
## verifies the RSA-4096 signature with the embedded PUBKEY. Exits 1 on any
## mismatch — the release-validation check for tools/update_feed.sh.

func _initialize() -> void:
	var manifest := OS.get_cmdline_user_args()
	if manifest.size() != 2:
		print("usage: godot --headless -s res://tools/verify_feed.gd <latest.json> <archive>")
		quit(2)
		return
	var m := FileAccess.open(manifest[0], FileAccess.READ)
	if m == null:
		print("cannot read %s" % manifest[0])
		quit(1)
		return
	var raw := m.get_as_text()
	m.close()
	var platform := UpdateFeed.platform_key(OS.get_name())
	var entry := UpdateFeed.parse_manifest(raw, platform)
	if entry.is_empty():
		print("manifest has no valid entry for platform %s" % platform)
		quit(1)
		return
	var archive := manifest[1]
	var digest := UpdateFeed.sha256_of_file(archive)
	var hex := ""
	for b in digest:
		hex += "%02x" % b
	if hex != str(entry["sha256"]):
		print("sha256 mismatch: %s != %s" % [hex, entry["sha256"]])
		quit(1)
		return
	if not UpdateFeed.verify_archive(digest, str(entry["sig"])):
		print("SIGNATURE MISMATCH for %s" % archive)
		quit(1)
		return
	print("VERIFIED — %s (v%s)" % [archive, entry["version"]])
	quit(0)
