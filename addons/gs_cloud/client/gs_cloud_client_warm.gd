extends RefCounted

## The script warming of [GSCloudClient] ([method GSCloudClient.warm_content] and the class prewarm), in a
## file of their own so the client stays inside the size budget. Nothing here is used on its own.

const CHANNEL := "cloud"

## Project settings (all optional): msec of script compiling per frame under the cover, msec the cover may wait
## (0 = until every script is warmed), msec per frame for scripts left after that, and extra directories to skip.
const SET_BUDGET := "gs_cloud/warm/budget_msec"
const SET_BLOCKING := "gs_cloud/warm/blocking_msec"
const SET_TAIL_BUDGET := "gs_cloud/warm/background_budget_msec"
const SET_SKIP := "gs_cloud/warm/skip_dirs"
## The pack file (path inside the pack) listing the scripts its scene needs before it opens, written by
## [method GSCloudSliceLoader.cached_scripts]: the cover waits for those only, the rest compile after it.
## Empty, or a pack without the file = every script under the cover, as before.
const SET_LIST := "gs_cloud/warm/list_file"
const DEFAULT_LIST := "warm.txt"
## What happens to the scripts a warm list leaves out: "lazy" (default) compiles none of them, each compiles at its
## first load() and the rest wait in [member GSCloudSliceLoader.unlisted]; "background" compiles them all right after
## the cover drops at background_budget_msec per frame (before API 39; on a single web thread it slowed FC's first seconds).
const SET_UNLISTED := "gs_cloud/warm/unlisted"
## Top-level pack folders whose scripts are not warmed ([constant GSCloudClient.WARM_SKIP_DIRS]).
const SKIP_DIRS := ["tools", "examples", "tests", "ci"]


## True for a file under a tooling directory at any depth: a pack ships `addons/<x>/examples/`, whose scripts do not parse in a running game.
static func _skipped(path: String) -> bool:
	var parts := path.split("/")
	for i in parts.size() - 1:
		if SKIP_DIRS.has(parts[i]) or (ProjectSettings.get_setting(SET_SKIP, PackedStringArray()) as PackedStringArray).has(parts[i]):
			return true
	return false


## The addon classes a pack names, compiled while its big objects still download.
static func prewarm_classes(c: Node, manifest: GSCloudManifest) -> void:
	if GSPlatform.has_threads() or c._prewarming or not c.is_inside_tree():
		return
	var names := PackedStringArray()
	var files := PackedStringArray()
	for file in manifest.files:
		if file.path.get_extension() != "gd" or _skipped(file.path):
			continue
		var object: String = c.store.path_for(file.sha256)
		if FileAccess.file_exists(object):
			names.append(file.path)
			files.append(object)
	c._prewarming = true
	c._prewarm = GSCloudSliceLoader.new()
	var t0 := Time.get_ticks_msec()
	var classes := GSCloudSliceLoader.named_class_scripts(names, files)
	# With a warm list, only the classes it names: the rest (server-only code, menus opened later) compile at first use.
	var listed: Variant = _prewarm_listed(c, manifest)
	var named_count := classes.size()
	if listed != null:
		classes = PackedStringArray(Array(classes).filter(func(p: String) -> bool: return (listed as Dictionary).has(p)))
	var res: GSResult = await c._prewarm.load_all(c.get_tree(), classes, false)
	GSLog.info(CHANNEL, "addon classes prewarmed", {
		"classes": classes.size(), "named": named_count, "listed": listed != null, "left_to_warm": c._prewarm.remaining.size(), "ms": Time.get_ticks_msec() - t0, "ok": res.ok,
	})
	c._prewarming = false
	c._prewarm_done.emit()


## See [method GSCloudClient.warm_content].
static func warm_content(c: Node, tree: SceneTree, keys: PackedStringArray, force: bool, on_progress: Callable) -> GSCloudSliceLoader:
	var loader := GSCloudSliceLoader.new()
	if on_progress.is_valid():
		loader.progress.connect(func(done: int, total: int, _path: String) -> void: on_progress.call(done, total))
	if GSPlatform.has_threads() and not force:
		return loader

	var scripts := PackedStringArray()
	var seen := {}
	for key in keys:
		var manifest: GSCloudManifest = c.manifest_for(key)
		if manifest == null:
			continue
		for file in manifest.files:
			# Tooling and examples are never loaded by a running game; warming them cost ~12 s of a join.
			if _skipped(file.path):
				continue
			var path := manifest.resource_path(file)
			# A tokenized script ships as x.gdc behind x.gd.remap; load the .gd path either way.
			if path.get_extension() == "gdc":
				path = path.trim_suffix("c")
			if path.get_extension() == "gd" and ResourceLoader.exists(path) and not seen.has(path) and not ResourceLoader.has_cached(path):
				seen[path] = true
				scripts.append(path)

	# Take over from the class prewarm instead of idling while it finishes (~9 s of a web join): stop it after
	# its current slice; named_class_scripts below skips what it compiled and queues what it had not reached.
	if c._prewarming and c._prewarm != null:
		c._prewarm.stop_requested = true
	while c._prewarming:
		await c._prewarm_done
	var t0 := Time.get_ticks_msec()
	var named := GSCloudSliceLoader.named_class_scripts(scripts)
	var scan_ms := Time.get_ticks_msec() - t0
	var order := named + scripts
	var unlisted := PackedStringArray()
	var listed := listed_scripts(c, keys)
	var listed_count := -1
	if not listed.is_empty():
		order = _listed_first(named, scripts, listed, unlisted)
		listed_count = order.size()
	# Under the cover the frame can be long (it only animates a bar); the default 16 ms yields twice as often for nothing.
	loader.budget_msec = int(ProjectSettings.get_setting(SET_BUDGET, 40))
	loader.deadline_msec = int(ProjectSettings.get_setting(SET_BLOCKING, 0))
	var res := await loader.load_all(tree, order, false)
	var lazy := str(ProjectSettings.get_setting(SET_UNLISTED, "lazy")) != "background"
	if res.ok:
		if lazy:
			loader.unlisted = unlisted
		else:
			loader.remaining.append_array(unlisted)
	var deferred := loader.remaining.size()
	if deferred > 0:
		loader.load_rest(tree, int(ProjectSettings.get_setting(SET_TAIL_BUDGET, 3)))

	GSLog.info(CHANNEL, "scripts warmed", {
		"content": ",".join(keys), "pack_scripts": scripts.size(), "addon_classes": named.size(),
		"listed": listed_count, "unlisted": unlisted.size(), "lazy": loader.unlisted.size(),
		"scan_ms": scan_ms, "ms": Time.get_ticks_msec() - t0, "frames": loader.frames_yielded,
		"deferred": deferred, "ok": res.ok, "why": "" if res.ok else str(res.error),
	})
	# Which scripts cost the join its seconds; read at DEBUG so a slow web join can be diagnosed from its log.
	for entry in loader.slowest:
		GSLog.debug(CHANNEL, "slow script", {"ms": entry[0], "path": entry[1]})
	return loader


## The listed scripts of [param named] + [param scripts], in that order, so the cover waits for what the scene needs
## (~83% of FC's 771) with the addon classes still compiled first; the others go to [param unlisted]. A listed script
## no scan found (a class reached only through a preload) blocks too, after the addon classes.
static func _listed_first(named: PackedStringArray, scripts: PackedStringArray, listed: Dictionary, unlisted: PackedStringArray) -> PackedStringArray:
	var first := PackedStringArray()
	var found := {}
	for path in named + scripts:
		if listed.has(path):
			first.append(path)
			found[path] = true
		else:
			unlisted.append(path)
	var at := 0
	for path in named:
		if found.has(path):
			at += 1
	for path: String in listed:
		if not found.has(path) and not ResourceLoader.has_cached(path) and ResourceLoader.exists(path):
			first.insert(at, path)
			at += 1
	return first


## The scripts the warm lists of the mounted packs [param keys] name, as resource paths (an ordered set).
## A line is a path inside the pack, or, when the pack has no such file, under res:// (an addon the host ships).
## Only `.gd` lines count; `#` starts a comment. Empty when no pack ships a list or [constant SET_LIST] is "".
static func listed_scripts(c: Node, keys: PackedStringArray) -> Dictionary:
	var out := {}
	var list_name := str(ProjectSettings.get_setting(SET_LIST, DEFAULT_LIST))
	if list_name == "":
		return out
	for key in keys:
		var manifest: GSCloudManifest = c.manifest_for(key)
		if manifest == null:
			continue
		for file in manifest.files:
			if file.path != list_name:
				continue
			var prefix := manifest.mount_prefix()
			for rel in _list_lines(FileAccess.get_file_as_string(manifest.resource_path(file))):
				var path := prefix.path_join(rel)
				out[path if ResourceLoader.exists(path) else "res://" + rel] = true
	return out


## The `.gd` paths of a warm list's text, relative, without comments and escapes.
static func _list_lines(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for line in text.split("\n"):
		var rel := line.split("#", true, 1)[0].strip_edges().simplify_path()
		if rel.get_extension() == "gd" and not rel.begins_with("..") and not rel.contains("://"):
			out.append(rel)
	return out


## The host (res://) scripts the warm list of a pack not yet mounted names, read from its stored object; null when
## the pack ships no list (or the object is not here yet), so the class prewarm takes every named class as before.
static func _prewarm_listed(c: Node, manifest: GSCloudManifest) -> Variant:
	var list_name := str(ProjectSettings.get_setting(SET_LIST, DEFAULT_LIST))
	if list_name == "":
		return null
	for file in manifest.files:
		if file.path == list_name:
			var object: String = c.store.path_for(file.sha256)
			if not FileAccess.file_exists(object):
				return null
			var out := {}
			for rel in _list_lines(FileAccess.get_file_as_string(object)):
				out["res://" + rel] = true
			return out
	return null

