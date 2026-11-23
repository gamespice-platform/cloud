extends RefCounted

## Manifest resolving of [GSCloudClient] ([method GSCloudClient.resolve_manifest], [method GSCloudClient.fetch_manifest],
## [method GSCloudClient.verify_manifest]), in a file of its own so the client stays inside the size budget.
## Nothing here is used on its own.

static func resolve(c: Node,
	content_id: StringName,
	version: String = "",
	manifest_url: String = ""
) -> GSResult:
	var id := String(content_id)

	if id == "":
		return GSResult.fail(GSError.CODE_INVALID, "No content id to resolve.")

	if not c._started:
		var started: GSResult = await c.start()
		if not started.ok:
			return started

	var effective_version := version if version != "" else "0.0.0"

	var candidates: PackedStringArray = (
		PackedStringArray([manifest_url]) if manifest_url != ""
		else c.manifest_urls_for(content_id, effective_version)
	)

	if candidates.is_empty():
		return GSResult.fail(
			GSError.CODE_STATE,
			"There is nowhere to fetch %s from." % id,
			"set local_search_dirs or http_base_urls on this GSCloudClient, or give "
			+ "the content a manifest_url of its own"
		)

	var last: GSResult = null
	# Every address asked and why it said no, one per line: the last error alone hid a 404 on the flat fallback over the real cause on the first.
	var tried := PackedStringArray()
	# True while every failure is a transport one (no document came back): a manifest that arrived and was refused is never replaced by an older copy.
	var unreachable := true

	for candidate in candidates:
		var fetched: GSResult = await c.fetch_manifest(candidate)

		if not fetched.ok:
			# Tried in order and the first hit wins, so a base that does not have this
			# content is not a failure until every base has been asked. Only the last
			# error is kept — reporting five 404s helps nobody.
			last = fetched
			tried.append(_describe(candidate, fetched))
			unreachable = unreachable and _is_transport(fetched)
			continue

		var manifest: GSCloudManifest = fetched.value

		# The manifest decides what it is, and it has to agree with what was asked
		# for. Without this a mirror serving the wrong document mounts content under
		# the id the caller wanted and the paths inside it are somebody else's.
		if manifest.content_id != id:
			last = GSResult.fail(
				GSError.CODE_INVALID,
				"The manifest at %s is for different content." % candidate,
				"asked for '%s', it says '%s'" % [id, manifest.content_id]
			)
			tried.append(_describe(candidate, last))
			unreachable = false
			continue

		if version != "" and manifest.version != effective_version:
			last = GSResult.fail(
				GSError.CODE_INVALID,
				"The manifest at %s is the wrong version." % candidate,
				"asked for '%s', it says '%s'" % [effective_version, manifest.version]
			)
			tried.append(_describe(candidate, last))
			unreachable = false
			continue

		# A published directory holds the manifest and the objects it names, so a base that answered
		# for the manifest is where the content is. The URL form does not need this: its caller
		# configured the sources.
		if c.is_local_manifest_url(candidate):
			c._adopt_local_dir(c._local_manifest_path(candidate).get_base_dir())

		if not c.is_local_manifest_url(candidate):
			GSCloudManifestCache.remember(c, manifest)

		return GSResult.success(manifest)

	if last == null:
		return GSResult.fail(GSError.CODE_IO, "Could not get %s's manifest." % id)

	var summary := "\n".join(tried)
	GSLog.warn("cloud", "no address gave a manifest", {"content": id, "version": version, "tried": summary})

	# Offline, or the CDN is down: content this machine already holds still starts, from the manifest that was verified when it was downloaded.
	if unreachable and version != "":
		var kept := GSCloudManifestCache.load_cached(c, id, effective_version)
		if kept.ok:
			GSLog.warn("cloud", "starting from the kept manifest, the content network was not reachable", {"content": id, "version": version})
			c.manifest_from_cache.emit(kept.value, summary)
			return kept
		tried.append("kept copy: %s" % kept.error.message)
		summary = "\n".join(tried)

	return GSResult.fail(last.error.code if last.error != null else GSError.CODE_IO, last.error.message, summary)


## One line of the tried list: the address, then the failure's code, message and detail.
static func _describe(url: String, res: GSResult) -> String:
	if res.error == null:
		return url
	var line := "%s: [%s] %s" % [url, res.error.code, res.error.message]
	if res.error.detail != "":
		line += " (%s)" % res.error.detail
	return line


## Whether a failure means nothing answered usefully (no network, a timeout, an HTTP error or a missing file), as opposed to a document that arrived and was refused.
static func _is_transport(res: GSResult) -> bool:
	return res.error != null and res.error.code in [
		GSError.CODE_NETWORK, GSError.CODE_TIMEOUT, GSError.CODE_HTTP, GSError.CODE_IO,
		GSError.CODE_STATE, GSError.CODE_INVALID, GSError.CODE_RATE_LIMITED,
	]


static func fetch(c: Node, manifest_url: String) -> GSResult:
	var bytes: PackedByteArray

	if c.is_local_manifest_url(manifest_url):
		var read := GSPaths.read_bytes(c._local_manifest_path(manifest_url) as String)
		if not read.ok:
			return read.wrap("Could not read the content manifest.")
		bytes = read.value
	elif not manifest_url.contains("://"):
		# A local search directory that does not hold this pack: not a URL either, so refuse cleanly
		# and let `ensure` try the next candidate, instead of an engine "Invalid URL scheme" error.
		return GSResult.fail(
			GSError.CODE_STATE,
			"No manifest at '%s'." % manifest_url,
			"a local search directory does not hold this content, and the path is "
			+ "not a URL; set http_base_urls to fetch it"
		)
	else:
		var res: GSResult = await c._http.get_bytes(manifest_url)
		if not res.ok:
			return res.wrap("Could not download the content manifest.")
		bytes = res.value

	if c._pinned.has(manifest_url) and GSHash.sha256_bytes(bytes) != c._pinned[manifest_url]:
		return GSResult.fail(
			GSError.CODE_INTEGRITY, "The manifest at %s does not match content.lock.json." % manifest_url,
			"manifest_sha256 pins the signed bytes as served; this is another document"
		)

	var parsed := GSCloudManifest.from_json_bytes(bytes)
	if not parsed.ok:
		return parsed

	var manifest: GSCloudManifest = parsed.value

	var checked: GSResult = c.verify_manifest(manifest)
	if not checked.ok:
		return checked

	# A pack's objects live beside its manifest, so where it came from is always a valid mirror (without it a client pointed at a content root asks
	# one directory too high). Appended, never prepended: a mirror the publisher named is where the operator wants load. A manifest kept on disk
	# names no pack directory, so each HTTP base's own one is used instead.
	var homes: PackedStringArray = PackedStringArray([manifest_url]) if not c.is_local_manifest_url(manifest_url) \
		else c._http_manifest_urls(manifest.content_id, manifest.version)
	for url in homes:
		var here := url.get_base_dir()
		if here != "" and not manifest.mirrors.has(here):
			manifest.mirrors.append(here)

	return GSResult.success(manifest)


static func verify(c: Node, manifest: GSCloudManifest) -> GSResult:
	if not c.config.require_signed_manifests:
		if manifest.signature != "":
			# Verify anyway when a signature is present: it costs nothing and a
			# manifest that claims to be signed but is not should be refused
			# whatever the policy says.
			var opportunistic := GSCloudSignature.verify_for(
				manifest.raw_bytes,
				manifest.signature,
				c.config.trusted_keys,
				manifest.content_id,
				manifest.signature_key_id
			)
			if not opportunistic.ok and not c.config.trusted_keys.is_empty():
				return opportunistic
		return GSResult.success(true)

	c._set_phase(c.Phase.VERIFYING_SIGNATURE, "Checking content signature…")

	if manifest.raw_bytes.is_empty():
		return GSResult.fail(
			GSError.CODE_INTEGRITY,
			"This manifest cannot be verified.",
			"it was constructed in memory rather than received, so there are no "
			+ "signed bytes to check"
		)

	# verify_for, not verify_any: a valid signature is half the question; the key must also be trusted
	# for THIS content id, or a second publisher could sign a manifest claiming to be somebody else's game.
	return GSCloudSignature.verify_for(
		manifest.raw_bytes,
		manifest.signature,
		c.config.trusted_keys,
		manifest.content_id,
		manifest.signature_key_id
	)
