class_name UpdateFeed extends RefCounted

## The signed update manifest and the verification it implies. PURE: no scene
## tree, no engine singleton beyond RefCounted — the menu drives it, and the
## simulation never will.
##
## One manifest (`latest.json`) per release, attached to the GitHub Release
## alongside the three platform archives. Each entry names the archive URL, its
## SHA-256, and an RSA-4096 signature over that digest. The public key below is
## the only trust anchor in the client: TLS keeps the transport honest, the
## signature keeps the bytes honest, and neither part is optional — an
## unsigned entry is refused, not "trusted with a warning".
##
## The private key NEVER ships. It lives at ~/.config/rootkit/update_sign.key
## for local releases (tools/update_feed.sh genkey) and in the Actions secret
## UPDATE_SIGN_KEY (base64 of the PEM) for CI.

## The update channel's RSA-4096 public key. Verify it against a fresh
## `tools/update_feed.sh genkey` output when rotating; it must be regenerated
## ONLY together with a release that still ships the old key, so clients that
## have not updated can still verify the update that replaces them.
const PUBKEY := """-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAyUtpi0kujcs9/WIEQvM9
sUzfGXrd2jFGmOcaggSscmdGnzccOOadelenX5LQ+qbNzwaaAcyRYBCqsnyEkIg2
cPnjNji+HkmqSU/HMt3JcXdNUMOTDzOZHNqbFLyriz9aZerPgxKPSM7XR2AMt6rw
6fcV9MrJLjPtcWxQyvJM5fQMxP3WQ0uStleuYoAk4KpVu2TJlZAKSFQdj+vJyN7S
6X7rO7ds0A+/FGIhCEFDf5QDhF3BLWd/doFPMv5p/+5+ji3XNeZvNDZjScmpmS3d
mE+QZt/gTWex2seKmw78G2uhQxF127+PzkSvvbuMfigZi+uN80IVv0Nd2e2shr2e
SrIwz4lgA9DTH0r9cvV4FF7z2+kYmAbNeQ0Suhf/z3R3L2Njt3HgAzv2iB31UzGp
YoYCWtSMI4h77rvJkywwY7OvzNWlozzgUcA+LS5K2sOEQFmRN7hHRV8SP70fN20I
3t/8p7+OHLJahUG77eczPc1LiQ9W01avb1eCsyY2gMaZGbSKi9sjjrcKKc5q8U2g
EodgIw6KBaU7t5TFY8yk3PmNLPbKcidKSuRgp001s74FLC2JedJyPigS7wsO5ar1
+3vqYPx6nZ5LviIJ5jaqiqW4kqOir21oPQp/UzdsGQeSUduSjB5mZOugmyHv3ZQD
pZku6EZVaDWa30lZP2AcuZMCAwEAAQ==
-----END PUBLIC KEY-----"""

const VERSION_MAX := 32
const URL_MAX := 512
const SHA256_LEN := 64
const SIG_MAX := 768

## The manifest's platform key for this build, per OS.get_name().
static func platform_key(os_name: String) -> String:
	match os_name:
		"macOS":
			return "macos"
		"Windows":
			return "windows"
		"Linux":
			return "linux"
	return ""

## Parse a raw manifest and return its entry for `platform` — {version, url,
## sha256, sig} — or {} on ANY violation. Hostile fields are refused, not
## clamped: an entry that parses differently between runs must not exist.
static func parse_manifest(raw: String, platform: String) -> Dictionary:
	if platform == "":
		return {}
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var version = parsed.get("version", "")
	if typeof(version) != TYPE_STRING or version.length() > VERSION_MAX \
			or (version as String).is_empty():
		return {}
	var entries: Variant = parsed.get("entries", null)
	if typeof(entries) != TYPE_DICTIONARY:
		return {}
	var entry: Variant = entries.get(platform, null)
	if typeof(entry) != TYPE_DICTIONARY:
		return {}
	var url = entry.get("url", "")
	if typeof(url) != TYPE_STRING or url.length() > URL_MAX:
		return {}
	var sha = entry.get("sha256", "")
	if typeof(sha) != TYPE_STRING or sha.length() != SHA256_LEN:
		return {}
	for c in sha:
		if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f")):
			return {}
	var sig = entry.get("sig", "")
	if typeof(sig) != TYPE_STRING or sig.length() > SIG_MAX or sig.is_empty():
		return {}
	return {"version": version, "url": url, "sha256": sha, "sig": sig}

## Whether `current` should be replaced by `available`. "dev" never updates —
## a developer's build is by definition ahead of or aside from the feed. The
## compare is numeric, dot-separated, so 0.4.9 < 0.4.10.
static func should_update(current: String, available: String) -> bool:
	if current == "dev" or available == "dev":
		return false
	return compare_versions(available, current) > 0

## 1 when a is newer than b, -1 when older, 0 equal. Words compare below any
## number; suffixes after a digit run are ignored (0.4.0-rc1 == 0.4.0).
static func compare_versions(a: String, b: String) -> int:
	return _compare(_parts(a), _parts(b))

static func _parts(version: String) -> Array:
	var v := version.trim_prefix("v").trim_prefix("V")
	if v.is_empty() or v == "dev":
		return [-1]
	var out: Array = []
	for part in v.split("."):
		var digits := ""
		for c in part:
			# Leading digits only: once a suffix starts, its digits must not be
			# absorbed — "0-rc1" would otherwise parse as 1 and 0.4.0-rc1 would
			# sort equal to 0.4.1.
			if c >= "0" and c <= "9":
				digits += c
			else:
				break
		out.append(int(digits) if digits != "" else 0)
	return out

static func _compare(a: Array, b: Array) -> int:
	for k in maxi(a.size(), b.size()):
		var x := int(a[k]) if k < a.size() else 0
		var y := int(b[k]) if k < b.size() else 0
		if x != y:
			return 1 if x > y else -1
	return 0

## The SHA-256 of a file, streamed in 64 KiB chunks; empty on any error.
static func sha256_of_file(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not f.eof_reached():
		var chunk := f.get_buffer(1 << 16)
		if not chunk.is_empty():
			ctx.update(chunk)
	f.close()
	return ctx.finish()

## Verify an RSA-4096 signature over the given SHA-256 digest, base64 on the
## wire. The digest is the hash the archive was signed over, never the archive
## itself — the same shape tools/update_feed.sh produces.
static func verify_archive(digest: PackedByteArray, sig_b64: String,
		pub_pem: String = PUBKEY) -> bool:
	if digest.size() != 32:
		return false
	var sig := Marshalls.base64_to_raw(sig_b64)
	if sig.is_empty():
		return false
	var key := CryptoKey.new()
	if key.load_from_string(pub_pem, true) != OK:
		return false
	var crypto := Crypto.new()
	return crypto.verify(HashingContext.HASH_SHA256, digest, sig, key)
