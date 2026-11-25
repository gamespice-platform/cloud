extends RefCounted

## The dependency half of [GSCloudClient]'s job tracking, in a file of its own so the client stays
## inside the size budget. Nothing here is used on its own.

const MAX_DEPTH := 4


## Resolves a manifest's dependency tree ahead of the downloads and registers each pack's missing bytes, so the job's total is known before the first byte; manifests are kept for [method ensure_dependency].
## One level is fetched [member GSCloudConfig.parallel_packs] at a time and registered in list order, so the totals do not depend on which fetch finished first; a manifest that fails to resolve is skipped here and fails in [method ensure_all] with its context.
## [param groups] are fetched of this level's packs only, not of theirs.
static func register_dependencies(c: Node, manifest: GSCloudManifest, depth: int, groups: PackedStringArray = PackedStringArray()) -> void:
	if depth >= MAX_DEPTH or c.job == null:
		return
	var wanted: Array = []
	var seen := {}
	for dep in manifest.dependencies:
		var id := StringName(str(dep["id"]))
		var version := str(dep["version"])
		var key: String = c.content_key_for(id, version)
		if seen.has(key) or c.is_mounted(id, version):
			continue
		seen[key] = true
		wanted.append([id, version])
	var results: Array = []
	results.resize(wanted.size())
	var state := {"next": 0, "live": 0, "running": 0}
	var worker := func() -> void:
		while int(state["next"]) < wanted.size():
			var i: int = state["next"]
			state["next"] = i + 1
			state["running"] = int(state["running"]) + 1
			c.resolve_peak = maxi(c.resolve_peak, int(state["running"]))
			results[i] = await c.resolve_manifest(wanted[i][0], wanted[i][1])
			state["running"] = int(state["running"]) - 1
		state["live"] = int(state["live"]) - 1
	for _w in mini(maxi(1, c.config.parallel_packs), wanted.size()):
		state["live"] = int(state["live"]) + 1
		worker.call()
	while int(state["live"]) > 0:
		await c.get_tree().process_frame
	for resolved: GSResult in results:
		if c.job == null:
			return
		if resolved == null or not resolved.ok:
			continue
		var m: GSCloudManifest = resolved.value
		c._job_manifests[m.key()] = m
		if not groups.is_empty():
			c._job_groups[m.key()] = groups
		var plan: Dictionary = c.plan_for(m, groups)
		c.job.add_pack(m.key(), int(plan["missing_bytes"]), int(plan["missing_files"]))
		await register_dependencies(c, m, depth + 1)


## Registers an already resolved manifest and its dependency tree.
static func register_manifest(c: Node, m: GSCloudManifest, groups: PackedStringArray = PackedStringArray()) -> void:
	if c.job == null:
		return
	c._job_manifests[m.key()] = m
	if not groups.is_empty():
		c._job_groups[m.key()] = groups
	var plan: Dictionary = c.plan_for(m, groups)
	c.job.add_pack(m.key(), int(plan["missing_bytes"]), int(plan["missing_files"]))
	await register_dependencies(c, m, 1)


## The download-only pass over every registered manifest, [member GSCloudConfig.parallel_packs] at a time. Returns {key: GSError} for the failures; [param skip_preflight] leaves out the requirements check.
static func download_all(c: Node, skip_preflight: bool = false) -> Dictionary:
	var manifests: Array = c._job_manifests.values()
	var failed := {}
	var state := {"next": 0, "live": 0}
	var worker := func() -> void:
		while int(state["next"]) < manifests.size():
			var i: int = state["next"]
			state["next"] = i + 1
			var m: GSCloudManifest = manifests[i]
			if c.is_mounted(m.content_id, m.version):
				continue
			var key := m.key()
			var got: GSResult = GSResult.success({}) if skip_preflight else await c._preflight_requirements(m, key)
			if got.ok:
				got = await c._download(m, c._job_groups.get(key, PackedStringArray()), key)
			if not got.ok:
				failed[key] = got.error
		state["live"] = int(state["live"]) - 1
	for _w in mini(maxi(1, c.config.parallel_packs), manifests.size()):
		state["live"] = int(state["live"]) + 1
		worker.call()
	while int(state["live"]) > 0:
		await c.get_tree().process_frame
	return failed


## One file of [param m] from the store, fetched alone when missing.
static func read_file(c: Node, m: GSCloudManifest, path: String) -> GSResult:
	var wanted: GSCloudFile = null
	for f in m.files:
		if f.path == path:
			wanted = f
			break
	if wanted == null:
		return GSResult.fail(GSError.CODE_INVALID, "The pack has no %s." % path, m.key())
	if not c.store.has(wanted.sha256):
		var sub := GSCloudManifest.new()
		sub.content_id = m.content_id
		sub.version = m.version
		sub.mount_root = m.mount_root
		sub.mirrors = m.mirrors
		sub.files = [wanted]
		var fetched: GSResult = await c._download(sub, PackedStringArray(), m.key(), false)
		if not fetched.ok:
			return fetched
	return c.store.read(wanted.sha256)


## [method GSCloudClient.ensure] for one dependency, reusing the manifest [method register_dependencies] already fetched.
static func ensure_dependency(c: Node, dep: Dictionary, below: PackedStringArray) -> GSResult:
	var id := StringName(str(dep["id"]))
	var version := str(dep["version"])
	var key: String = c.content_key_for(id, version)
	var known: GSCloudManifest = c._job_manifests.get(key)
	if known == null or c.is_mounted(id, version):
		return await c.ensure(id, version, PackedStringArray(), "", below)
	return await c.acquire_manifest(known, PackedStringArray(), below)


## Acquires every dependency, [member GSCloudConfig.parallel_packs] at a time. A failure stops new ones starting and lets the running ones finish; the result names the first failure in list order and lists every failed id in its context.
static func ensure_all(c: Node, key: String, deps: Array, below: PackedStringArray) -> GSResult:
	var results: Array = []
	results.resize(deps.size())
	var state := {"next": 0, "live": 0, "stop": false}
	var worker := func() -> void:
		while not state["stop"] and int(state["next"]) < deps.size():
			var i: int = state["next"]
			state["next"] = i + 1
			var got: GSResult = await ensure_dependency(c, deps[i], below)
			results[i] = got
			if not got.ok:
				state["stop"] = true
		state["live"] = int(state["live"]) - 1
	var n := mini(maxi(1, c.config.parallel_packs), deps.size())
	for _w in n:
		state["live"] = int(state["live"]) + 1
		worker.call()
	while int(state["live"]) > 0:
		await c.get_tree().process_frame
	var failed := PackedStringArray()
	var first: GSResult = null
	for i in deps.size():
		var got: GSResult = results[i]
		if got == null or got.ok:
			continue
		failed.append("%s@%s" % [deps[i]["id"], deps[i]["version"]])
		if first == null:
			first = got.wrap("%s needs %s@%s" % [key, deps[i]["id"], deps[i]["version"]])
	if first == null:
		return GSResult.success(true)
	var ctx := first.error.context.duplicate()
	ctx["failed_dependencies"] = failed
	first.error.context = ctx
	return first
