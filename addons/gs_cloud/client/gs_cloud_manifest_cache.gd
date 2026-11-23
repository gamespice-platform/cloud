class_name GSCloudManifestCache
extends RefCounted

## The manifests this client has fetched and verified, kept beside the object cache so that content already on this machine can still be started when the
## network cannot be reached. A layer of [GSCloudClient]'s manifest resolving; nothing here is used on its own.
##
## It caches bytes, not trust: [method load_cached] runs the same pin, signature and identity checks as a fetch, so a document altered on disk is refused.

const DIR := "manifests"


## Where [param content_id]'s [param version] manifest is kept. The id is a slug pair, never a path, so a hostile one cannot leave the directory.
static func path_for(cache_dir: String, content_id: String, version: String) -> String:
	if cache_dir.strip_edges() == "" or not _safe(content_id) or not _safe(version):
		return ""
	return cache_dir.path_join(DIR).path_join(content_id.replace("/", "__")).path_join(version + ".json")


static func _safe(part: String) -> bool:
	return part != "" and not part.contains("..") and not part.contains("\\") and not part.contains(":") and part.length() <= 160


## Keeps the signed bytes of a manifest that was fetched and verified. A failure is only logged: the cache is a convenience, never a reason to fail a fetch.
static func remember(c: Node, manifest: GSCloudManifest) -> void:
	var path := path_for(c.config.cache_dir, manifest.content_id, manifest.version)
	if path == "" or manifest.raw_bytes.is_empty():
		return
	var written := GSPaths.write_bytes(path, manifest.raw_bytes)
	if not written.ok:
		GSLog.warn("cloud", "could not keep the manifest for offline starts", {"path": path, "detail": written.error.detail})


## Versions of [param content_id] whose manifest is kept, newest first.
static func versions(cache_dir: String, content_id: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := path_for(cache_dir, content_id, "x").get_base_dir()
	if dir == "" or not DirAccess.dir_exists_absolute(dir):
		return out
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".json"):
			out.append(file.trim_suffix(".json"))
	var parsed := {}
	for v in out:
		parsed[v] = GSSemVer.parse(v)
	var list := Array(out)
	list.sort_custom(func(a: String, b: String) -> bool: return (parsed[a] as GSSemVer).compare(parsed[b]) > 0)
	return PackedStringArray(list)


## The kept manifest of [param content_id] at [param version], verified again as a fetch would; the failure says why it cannot be used.
static func load_cached(c: Node, content_id: String, version: String) -> GSResult:
	var path := path_for(c.config.cache_dir, content_id, version)
	if path == "" or not FileAccess.file_exists(path):
		return GSResult.fail(GSError.CODE_STATE, "%s@%s has no manifest kept on this machine." % [content_id, version])
	var read := GSPaths.read_bytes(path)
	if not read.ok:
		return read.wrap("Could not read the kept manifest.")
	var parsed := GSCloudManifest.from_json_bytes(read.value)
	if not parsed.ok:
		return parsed.wrap("The kept manifest of %s@%s is damaged." % [content_id, version])
	var manifest: GSCloudManifest = parsed.value
	if manifest.content_id != content_id or manifest.version != version:
		return GSResult.fail(GSError.CODE_INVALID, "The kept manifest at %s is for other content." % path,
			"asked for %s@%s, it says %s@%s" % [content_id, version, manifest.content_id, manifest.version])
	var checked: GSResult = c.verify_manifest(manifest)
	if not checked.ok:
		return checked
	# Objects live beside the manifest wherever it was published, so the HTTP bases are this copy's mirrors, as a fetch gives it.
	for url: String in c._http_manifest_urls(StringName(content_id), version):
		var here: String = url.get_base_dir()
		if here != "" and not manifest.mirrors.has(here):
			manifest.mirrors.append(here)
	return GSResult.success(manifest)
