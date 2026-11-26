extends RefCounted

const _Overlay := preload("gs_cloud_addon_set_overlay.gd")
const _Groups := preload("gs_cloud_addon_set_groups.gd")

## The body of [method GSCloudAddonSet.late_pack], in a file of its own so the addon set stays inside the size budget.
## Nothing here is used on its own.

## Late packs this process has mounted (path -> true).
static var _mounted := {}

var _set: GSCloudAddonSet


func _init(p_set: GSCloudAddonSet) -> void:
	_set = p_set


## [method GSCloudAddonSet.late_pack].
func run(wanted: Dictionary, late: PackedStringArray) -> GSResult:
	if _set.cloud == null:
		return GSResult.fail(GSError.CODE_STATE, "No content client to fetch addons with.")

	if _set.groups.has(GSCloudFile.ALL_GROUPS):
		return GSResult.success(_result("", 0, 0, false))

	var select := late if not late.is_empty() else PackedStringArray([GSCloudFile.ALL_GROUPS])
	var planned := await _plan(wanted, select)

	if not planned.ok:
		return planned

	var plan: Dictionary = planned.value
	var pending: Array = plan["pending"]

	if pending.is_empty():
		return GSResult.success(_result("", 0, 0, false))

	var pack_path := GSCloudAddonSet.DIR.path_join("late-%s.pck" % "\n".join(plan["lines"]).sha256_text().substr(0, 16))
	var made := GSPaths.ensure_dir(GSCloudAddonSet.DIR)

	if not made.ok:
		return made

	var parts := _Overlay.existing_parts(pack_path)

	if parts.is_empty():
		var packed := await _fetch_and_pack(plan["manifests"], select, pending, pack_path)

		if not packed.ok:
			return packed

		parts = packed.value

	return _mount(pack_path, parts, pending, int(plan["bytes"]))


## The files the overlay left out: {"manifests", "pending" ([dir, manifest, base, file]), "lines" (sorted, names the pack), "bytes"}.
func _plan(wanted: Dictionary, select: PackedStringArray) -> GSResult:
	var manifests := {}
	var pending: Array = []
	var lines := PackedStringArray()
	var bytes := 0

	for dir: String in wanted:
		var entry: Dictionary = wanted[dir]
		var resolved := await _set.cloud.resolve_manifest(StringName(entry["id"]), str(entry["version"]))

		if not resolved.ok:
			return resolved.wrap("Could not find %s %s." % [entry["id"], entry["version"]])

		var manifest: GSCloudManifest = resolved.value
		await _Groups.derive(_set.cloud, manifest, _set.groups)
		var at := _Overlay.base(manifest, dir)

		if at == _Overlay.NOT_AN_ADDON:
			continue

		var held := {}
		for f in manifest.wanted_files(_set.groups):
			held[f.path] = true

		for f in manifest.wanted_files(select):
			if not held.has(f.path):
				pending.append([dir, manifest, at, f])
				lines.append("%s/%s:%s" % [dir, f.path, f.sha256])
				bytes += f.size

		manifests[dir] = manifest

	lines.sort()
	return GSResult.success({"manifests": manifests, "pending": pending, "lines": lines, "bytes": bytes})


## Downloads the files and packs them into parts; the value is the part paths.
func _fetch_and_pack(manifests: Dictionary, select: PackedStringArray, pending: Array, pack_path: String) -> GSResult:
	var cloud := _set.cloud

	# One download per manifest, so the store checks and progress stay the downloader's.
	for dir: String in manifests:
		var fetched := await cloud.download_manifest(manifests[dir], select)

		if not fetched.ok:
			return fetched.wrap("Could not download %s." % (manifests[dir] as GSCloudManifest).key())

	var scratch := GSCloudAddonSet.DIR.path_join("late_staging")
	GSPaths.remove_tree(scratch)
	GSPaths.ensure_dir(scratch)
	var packer := _Overlay.Parts.new(pack_path, _set.late_part_bytes)
	var index := 0
	var err := OK
	var tree := Engine.get_main_loop() as SceneTree
	var slice := Time.get_ticks_msec()

	for item: Array in pending:
		# A running game must not feel the packing: a part is written when the next file would not fit, so a frame holds at most one
		# small part, and a frame is given back whenever a few milliseconds are spent.
		if tree != null and Time.get_ticks_msec() - slice >= _set.late_slice_msec:
			await tree.process_frame
			slice = Time.get_ticks_msec()

		var dir: String = item[0]
		var manifest: GSCloudManifest = item[1]
		var f: GSCloudFile = item[3]

		if not cloud.store.has(f.sha256):
			GSPaths.remove_tree(scratch)
			return GSResult.fail(GSError.CODE_STATE, "An addon file is not downloaded.", f.path)

		var target := _Overlay.target(manifest, dir, str(item[2]), f.path)
		var source := _Overlay.unrelocate(manifest, dir, str(item[2]), f.path, cloud.store.path_for(f.sha256), scratch.path_join("t%d" % index))
		err = _Overlay.add(packer, target, source, scratch.path_join("r%d.remap" % index))

		if err != OK:
			GSPaths.remove_tree(scratch)
			return GSResult.failure(GSError.from_engine(err, "adding %s" % target))

		index += 1

	err = packer.finish()
	GSPaths.remove_tree(scratch)

	if err != OK:
		return GSResult.failure(GSError.from_engine(err, "writing the late addon pack"))

	GSWeb.sync_filesystem()
	return GSResult.success(packer.paths)


func _mount(pack_path: String, parts: PackedStringArray, pending: Array, bytes: int) -> GSResult:
	var mounted := false

	if not _mounted.has(pack_path):
		for part: String in parts:
			if not ProjectSettings.load_resource_pack(part, false):
				return GSResult.fail(GSError.CODE_STATE, "The engine refused the late addon pack.", part)

		var uids: Array = []

		for item: Array in pending:
			var f: GSCloudFile = item[3]
			var ext := f.path.get_extension().to_lower()

			if ext == "uid" or ext == "import":
				_Overlay.note_uid(uids, ext, _set.cloud.store.path_for(f.sha256), _Overlay.target(item[1], str(item[0]), str(item[2]), f.path))

		for pair: Array in uids:
			GSCloudAddonSet._register_uid(str(pair[0]), str(pair[1]))

		_mounted[pack_path] = true
		mounted = true
		GSLog.info(GSCloudAddonSet.CHANNEL, "mounted the late addon pack", {"pack": pack_path.get_file(), "files": pending.size(), "bytes": bytes})

	return GSResult.success(_result(pack_path, pending.size(), bytes, mounted))


static func _result(pack: String, files: int, bytes: int, mounted: bool) -> Dictionary:
	return {"pack": pack, "files": files, "bytes": bytes, "mounted": mounted}
