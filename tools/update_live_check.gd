extends SceneTree

## Live end-to-end walk of the update channel from the client's point of view:
## fetch the feed through the real redirects, stream-download the platform
## archive through its real redirects (download_file, no memory buffering),
## then verify SHA-256 and the RSA-4096 signature with the embedded PUBKEY.
## No installed game needed; requires network to github.com.
##
##   godot --headless -s res://tools/update_live_check.gd

var _failed := false

func _initialize() -> void:
	print("ROOTKIT — live update channel\n")
	await _run()
	quit(1 if _failed else 0)

func _fail(why: String) -> void:
	_failed = true
	print("FAIL  %s" % why)

func _run() -> void:
	# One source for the URL: the updater script's constant.
	var script := load("res://scripts/update/updater.gd") as GDScript
	var url: String = script.get_script_constant_map()["FEED_URL"]
	var platform := UpdateFeed.platform_key(OS.get_name())
	print("  feed url: %s" % url)
	var fed := HTTPRequest.new()
	root.add_child(fed)
	await process_frame
	fed.timeout = 30.0
	var err := fed.request(url)
	if err != OK:
		_fail("feed request failed: %s" % error_string(err))
		return
	var r1: Array = await fed.request_completed
	fed.queue_free()
	if int(r1[1]) != 200:
		_fail("feed HTTP %d" % int(r1[1]))
		return
	var entry := UpdateFeed.parse_manifest((r1[3] as PackedByteArray).get_string_from_utf8(),
		platform)
	if entry.is_empty():
		_fail("no valid entry for platform %s" % platform)
		return
	print("  feed: v%s" % entry["version"])

	var path := OS.get_user_data_dir().path_join("live_update_check.zip")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var dl := HTTPRequest.new()
	root.add_child(dl)
	dl.download_file = path
	dl.body_size_limit = 512 << 20
	dl.timeout = 600.0
	if dl.request(str(entry["url"])) != OK:
		_fail("download request failed")
		return
	var r2: Array = await dl.request_completed
	dl.queue_free()
	if int(r2[1]) != 200:
		_fail("download HTTP %d" % int(r2[1]))
		return
	if not FileAccess.file_exists(path):
		_fail("download_file wrote nothing")
		return
	var digest := UpdateFeed.sha256_of_file(path)
	var hex := ""
	for b in digest:
		hex += "%02x" % b
	if hex != str(entry["sha256"]):
		_fail("sha256 mismatch")
		return
	if not UpdateFeed.verify_archive(digest, str(entry["sig"])):
		_fail("SIGNATURE MISMATCH")
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var size := f.get_length() if f != null else 0
	if f != null:
		f.close()
	print("VERIFIED — streamed %.1f MB through the real redirects" % (size / 1048576.0))
	DirAccess.remove_absolute(path)
