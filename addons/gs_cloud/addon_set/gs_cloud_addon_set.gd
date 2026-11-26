class_name GSCloudAddonSet
extends RefCounted

## Newer addons for a build that already shipped, as packs, applied at the next boot.
##
## [b]The point: an addon release should not need a new client build.[/b] Every addon tag
## is already published as a signed pack (`gamespice-platform/ui@0.1.5`). A server says which
## addon versions it runs; a client whose build is older fetches those packs, lays them
## over its own `res://addons/<addon>/` in one overlay pack, and restarts into it -- a
## page reload in a browser, a relaunch on desktop.
##
## [b]Why a restart, and not a mount on the spot.[/b] Measured on an exported build: a
## script the process has already compiled keeps running its old code after a newer file
## is mounted over it, `CACHE_MODE_REPLACE` and `Script.reload()` included. The shell has
## compiled most of the addons by the time a server answers. So the overlay is mounted by
## `boot/gs_cloud_boot.gd` -- a main scene that names no addon -- before anything else
## loads, and the rest of the process never sees the older copy.
##
## [b]What the overlay has to carry, besides the files.[/b] Both measured on an exported
## build, both silent when missing:
##
## - [b]A `.remap` per resource[/b], pointing at itself. An export stores `x.gd` as
##   `x.gdc` behind `x.gd.remap`, and `x.tscn` as a binary `.scn` behind `x.tscn.remap`;
##   the loader follows the build's remap to the build's bytes, and a newer `x.gd` mounted
##   beside it is never read.
## - [b]The global class list[/b], with this set's entries swapped in. See
##   [GSCloudScriptClass].
##
## [b]Only ever upward.[/b] A server running an older addon than this build has keeps
## this build's: a client newer than its server is the case the envelope negotiation
## already handles, and following a server DOWN would let any server pin its players to a
## version with a bug that was fixed. Only signed packs from [member namespaces] are taken.

const _Overlay := preload("gs_cloud_addon_set_overlay.gd")
const _Checks := preload("gs_cloud_addon_set_checks.gd")
const _Late := preload("gs_cloud_addon_set_late.gd")
const _Persist := preload("gs_cloud_addon_set_persist.gd")

const CHANNEL := "cloud.addons"

## Where the overlay and its plan live. Fixed, and outside the content cache, because the
## boot script reads it before any configuration exists -- and a session-only content
## cache (`--content-cache off`) must not take a player's addons with it.
const DIR := "user://gs_cloud_addons"
const PLAN := "user://gs_cloud_addons/plan.json"

## The build's own class list, saved by the boot script before an overlay replaces it.
const SHELL_CLASSES := "user://gs_cloud_addons/shell_classes.cfg"

## The build the boot script kept [constant SHELL_CLASSES] for.
const SHELL_CLASSES_BUILD := "user://gs_cloud_addons/shell_classes.build"

## What [method mount_now] did: the overlay runs; it could not be mounted here (the plan is left ready for a restart);
## or it is mounted but an addon still runs the build's compiled copy (the plan is marked failed, as a failed boot is).
enum MountNow { RUNNING, REFUSED, STALE }

## The file an export carries that says which addon versions it was built from.
const BUILT_LOCK := "res://addons.lock"

const FORMAT := 1

## Plan states. `booting` is written before the mount and cleared by [method confirm_boot];
## a boot that finds it still set knows the last one never reached the shell, and skips
## the overlay rather than looping on it.
const STATE_READY := "ready"
const STATE_BOOTING := "booting"
const STATE_OK := "ok"
const STATE_FAILED := "failed"

## The extensions a build may have remapped. Each one in the overlay gets a `.remap`
## pointing at itself; anything else is read with FileAccess and needs none.
const REMAPPED := _Overlay.REMAPPED

## Where an addon pack may come from: an owner (`modcommunity/`, ending in a slash) or one
## exact content id. The signature says who published a pack; this says whose packs may
## replace this build's code, which is a narrower question.
var namespaces: PackedStringArray = PackedStringArray(["modcommunity/", "gamespice-platform/"])

## The client that fetches and verifies the packs.
var cloud: GSCloudClient = null

## The most one overlay file holds; a larger overlay is written as several (the plan's `packs`).
var part_bytes: int = _Overlay.PART_BYTES

## The download groups ([code]groups.json[/code], API 22) the overlay takes beside each pack's
## ungrouped files; `*` is every group. The overlay holds what was fetched, side-filtered
## too, so a server-only file or an unwanted group is neither downloaded nor laid over.
var groups: PackedStringArray = PackedStringArray([GSCloudFile.ALL_GROUPS])


func _init(p_cloud: GSCloudClient = null) -> void:
	cloud = p_cloud


## The addon versions this build shipped with: repo -> version, from [constant BUILT_LOCK].
## Empty when the build carries no lock, which turns this whole mechanism off: without a
## baseline there is no way to say what is newer.
static func built_versions() -> Dictionary:
	var text := FileAccess.get_file_as_string(BUILT_LOCK)
	var out := {}

	for raw in text.split("\n"):
		var line := raw.strip_edges()

		if line == "" or line.begins_with("#"):
			continue

		var parts := line.split("\t", false)

		if parts.size() >= 2:
			out[parts[0].strip_edges()] = parts[1].strip_edges().trim_prefix("v")

	return out


## Which build an overlay was made for. An overlay is only ever mounted over the build it
## was assembled against: over a newer one it could take an addon BACKWARDS.
static func build_fingerprint() -> String:
	var text := FileAccess.get_file_as_string(BUILT_LOCK)
	return text.sha256_text().substr(0, 16) if text != "" else ""


static func read_plan() -> Dictionary:
	var text := FileAccess.get_file_as_string(PLAN)

	if text == "":
		return {}

	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


static func write_plan(plan: Dictionary) -> GSResult:
	var parent := GSPaths.ensure_parent_dir(PLAN)
	if not parent.ok:
		return parent

	var f := FileAccess.open(PLAN, FileAccess.WRITE)

	if f == null:
		return GSResult.fail(GSError.CODE_IO, "Could not write the addon plan.", PLAN)

	f.store_string(JSON.stringify(plan, "\t"))
	f.close()
	GSWeb.sync_filesystem()
	return GSResult.success(true)


## Says the shell came up on the overlay the boot script mounted. Call it once the shell
## has finished building itself: until then a broken addon is still a boot that did not
## arrive, and the next boot should come up without the overlay.
##
## [b]And it checks the overlay is what is running.[/b] The failure this exists to catch is
## silent: an overlay mounted while the build's compiled copy of an addon is still the one
## that loads -- a remap that did not take -- leaves the old code running under the new
## class list. In an exported build a script loaded from its compiled `.gdc` has no source,
## and one loaded from the overlay has its text, so one script per addon is asked
## (`probes`, recorded when the overlay was built). A miss marks the overlay failed, so the
## next start comes up on the build's own addons rather than on a mixture.
static func confirm_boot() -> void:
	var plan := read_plan()

	if str(plan.get("state", "")) != STATE_BOOTING:
		return

	var stale := PackedStringArray()

	# Outside an export every script is loaded from its source, so the question has no
	# answer there -- and nothing is compiled ahead to be wrongly preferred.
	if OS.has_feature("template"):
		var probes: Variant = plan.get("probes", {})

		if probes is Dictionary:
			for dir: String in probes:
				var script := load(str(probes[dir])) as Script

				if script == null or script.source_code == "":
					stale.append(dir)

	if not stale.is_empty():
		plan["state"] = STATE_FAILED
		write_plan(plan)
		GSLog.error(CHANNEL, "the addon overlay is mounted but these addons still run the build's own copy; it is off from the next start", {
			"addons": stale,
		})
		return

	plan["state"] = STATE_OK
	write_plan(plan)
	GSLog.info(CHANNEL, "booted on the addon overlay", {"addons": _Checks.summary(plan.get("addons", {}))})


## Mounts the overlay the plan on disk names in this running process and confirms it, doing what the boot script
## ([code]boot/gs_cloud_boot.gd[/code], which may name no class and so cannot call this) does at a start; keep the two in
## step. Only safe when none of the overlay's addons is already loaded in this process (a first visit that has none of them):
## mounting refreshes the global class list, and a compiled copy already in memory would keep running. The caller checks that.
##
## [constant MountNow.REFUSED] leaves a `ready` plan untouched for a restart onto it (no plan, another state, another
## build, a part missing, or the engine refusing the pack).
static func mount_now() -> MountNow:
	var plan := read_plan()
	var packs: Variant = plan.get("packs", [plan.get("pack", "")])

	if str(plan.get("state", "")) != STATE_READY or not (packs is Array) or (packs as Array).is_empty():
		return MountNow.REFUSED

	var build := build_fingerprint()

	if build == "" or str(plan.get("build", "")) != build:
		return MountNow.REFUSED

	for part: Variant in packs:
		if not str(part).begins_with(DIR + "/") or not FileAccess.file_exists(str(part)):
			return MountNow.REFUSED

	# The build's own class list, kept before the overlay's replaces it: the next overlay is merged from it.
	if FileAccess.get_file_as_string(SHELL_CLASSES_BUILD) != build:
		var classes := FileAccess.get_file_as_string(GSCloudScriptClass.CACHE_PATH)

		if classes != "":
			GSPaths.write_text(SHELL_CLASSES, classes)
			GSPaths.write_text(SHELL_CLASSES_BUILD, build)

	# Booting, as the boot script leaves it, so confirm_boot checks it; and nothing to resume, or the next visit would
	# start this game again.
	var resume: Variant = plan.get("resume", {})
	plan["resume"] = {}
	plan["state"] = STATE_BOOTING
	plan["attempts"] = 0
	write_plan(plan)

	for part: Variant in packs:
		if not ProjectSettings.load_resource_pack(str(part), true):
			plan["state"] = STATE_READY
			plan["resume"] = resume
			write_plan(plan)
			GSLog.warn(CHANNEL, "the engine refused the addon overlay here; restart onto it instead", {"pack": str(part)})
			return MountNow.REFUSED

	var pack := str((packs as Array)[0])
	ProjectSettings.set_setting("gs_cloud/addon_overlay", pack)
	var uids: Variant = plan.get("uids", [])

	if uids is Array:
		for pair: Variant in uids:
			if pair is Array and (pair as Array).size() == 2:
				_register_uid(str(pair[0]), str(pair[1]))

	confirm_boot()

	if str(read_plan().get("state", "")) != STATE_OK:
		return MountNow.STALE

	GSLog.info(CHANNEL, "mounted the addon overlay without a restart", {
		"pack": pack.get_file(), "addons": (plan.get("addons", {}) as Dictionary).keys(),
	})
	return MountNow.RUNNING


## Points a uid the overlay declares at its file, by the boot script's rule: only inside `res://addons/`.
static func _register_uid(text: String, path: String) -> void:
	if not path.begins_with("res://addons/") or path.contains(".."):
		return

	var id := ResourceUID.text_to_id(text)

	if id == ResourceUID.INVALID_ID:
		return

	if ResourceUID.has_id(id):
		if ResourceUID.get_id_path(id).begins_with("res://addons/"):
			ResourceUID.set_id(id, path)
	else:
		ResourceUID.add_id(id, path)


## The addons running right now: the build's, overridden by the overlay if it is mounted.
## repo -> version.
static func running_versions() -> Dictionary:
	var out := built_versions()
	var plan := read_plan()

	if mounted_this_boot(plan):
		var addons: Dictionary = plan.get("addons", {})

		for dir: String in addons:
			var entry: Dictionary = addons[dir]
			var key := _Checks.version_key(out, [str(entry.get("repo", "")), str(entry.get("id", ""))])
			out[key if key != "" else str(entry.get("repo", ""))] = str(entry.get("version", ""))

	return out


## The version [param versions] (repo -> version) holds for a pack named by [param names] (a repo, an id, or both),
## under either id (`gamespice-platform/combat`, `modcommunity/gs-combat`); "" when none. See [method _Checks.pack_key].
static func version_of(versions: Dictionary, names: Array) -> String:
	var key := _Checks.version_key(versions, names)
	return str(versions[key]) if key != "" else ""


## Whether [param versions] knows this pack under either id.
static func has_pack(versions: Dictionary, names: Array) -> bool:
	return _Checks.version_key(versions, names) != ""


## Whether the boot script mounted [param plan]'s overlay in this process.
static func mounted_this_boot(plan: Dictionary) -> bool:
	return ProjectSettings.get_setting("gs_cloud/addon_overlay", "") != "" \
		and str(ProjectSettings.get_setting("gs_cloud/addon_overlay", "")) == str(plan.get("pack", ""))


## What a server's addon set asks of this process.
##
## [param server] is the server's list, as [method GSServer.addon_set] sends it: one
## `{dir, repo, id, version}` per addon. Returns `{wanted, refused}`: [code]wanted[/code]
## is the full set the next overlay should hold (dir -> entry) -- empty when nothing has
## to change -- and [code]refused[/code] says, per entry, why it was not taken.
func plan_for(server: Array) -> Dictionary:
	var built := built_versions()
	var refused := {}

	if built.is_empty():
		return {"wanted": {}, "refused": {"*": "this build carries no %s" % BUILT_LOCK}}

	var current := read_plan()
	var held: Dictionary = current.get("addons", {}) if mounted_this_boot(current) else {}
	var wanted := {}
	var missing := false

	for raw in server:
		if not (raw is Dictionary):
			continue

		var entry := raw as Dictionary
		var dir := str(entry.get("dir", ""))
		var repo := str(entry.get("repo", ""))
		var id := str(entry.get("id", ""))
		var version := str(entry.get("version", "")).trim_prefix("v")
		var why := _refusal(dir, repo, id, version)

		if why != "":
			refused[dir if dir != "" else repo] = why
			continue

		var have := version_of(built, [repo, id])

		if have != "" and compare_versions(version, have) <= 0:
			continue

		wanted[dir] = {"dir": dir, "repo": repo, "id": id, "version": version}

		var mounted: Variant = held.get(dir)

		if mounted == null or compare_versions(str((mounted as Dictionary).get("version", "")), version) < 0:
			missing = true

	if not missing:
		return {"wanted": {}, "refused": refused}

	# [b]Never narrower than what is running.[/b] An addon the overlay already raised and
	# this server does not mention stays raised: dropping it would take it backwards.
	for dir: String in held:
		var entry: Dictionary = held[dir]

		if not wanted.has(dir):
			wanted[dir] = entry
		elif compare_versions(str(entry.get("version", "")), str(wanted[dir]["version"])) > 0:
			wanted[dir] = entry

	return {"wanted": wanted, "refused": refused}


## Whether the last attempt at exactly this set failed to boot. A shell that would build
## it again would only reload into the same failure.
static func failed_before(wanted: Dictionary) -> bool:
	var plan := read_plan()
	return str(plan.get("state", "")) == STATE_FAILED \
		and str(plan.get("build", "")) == build_fingerprint() \
		and _Checks.same_set(plan.get("addons", {}), wanted)


## The overlay files [param plan] names, part 0 first; `packs` is absent from a plan written before overlays had parts.
static func plan_packs(plan: Dictionary) -> PackedStringArray:
	var packs: Variant = plan.get("packs", [])
	var out := PackedStringArray(packs) if packs is Array or packs is PackedStringArray else PackedStringArray()
	return out if not out.is_empty() else PackedStringArray([str(plan.get("pack", ""))])


## What a restart has to find kept: the plan and every overlay file it names.
static func plan_files(plan: Dictionary) -> PackedStringArray:
	var out := PackedStringArray([PLAN])
	out.append_array(plan_packs(plan))
	return out


## Forgets the overlay: the next start comes up on this build's own addons. The pack file
## stays until [method _prune] or a clear removes it, because this process may have it
## mounted.
static func forget() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PLAN))
	GSWeb.sync_filesystem()


## Waits until every file in [param paths] is in the browser's IndexedDB as it is in `user://` now; at once elsewhere.
## Fails with [code]CODE_TIMEOUT[/code] after [param timeout_s], [code]CODE_UNSUPPORTED[/code] without an IndexedDB copy.
## The persist helper says why a browser restart has to wait.
static func persisted(paths: PackedStringArray, timeout_s: float = 30.0) -> GSResult:
	return await _Persist.wait(paths, timeout_s)



func _refusal(dir: String, repo: String, id: String, version: String) -> String:
	if not _Checks.is_component(dir) or dir.begins_with("."):
		return "not a directory name"

	if repo == "" or id == "" or version == "":
		return "incomplete"

	# The repository is what this build's lock is keyed by, so it decides "newer than what
	# I have" -- and it has to be the pack's own name, or a list could compare one addon's
	# version and fetch another's.
	if _Checks.pack_key(id) != _Checks.pack_key(repo):
		return "%s is not the repository %s" % [id, repo]

	var allowed := false

	# An entry ending in `/` is an owner, anything else one exact id: `alice/x` must not
	# also admit `alice/x-evil`.
	for entry in namespaces:
		if (entry.ends_with("/") and id.begins_with(entry)) or id == entry:
			allowed = true
			break

	if not allowed:
		return "%s is not in a namespace this client takes addons from" % id

	if not version.is_valid_filename() or version.contains("/") or version.contains(".."):
		return "not a version"

	return ""


## Numeric, dot by dot: `0.1.10` is newer than `0.1.9`. A part that is not a number
## compares as text. Returns -1, 0 or 1.
static func compare_versions(a: String, b: String) -> int:
	var x := a.trim_prefix("v").split(".")
	var y := b.trim_prefix("v").split(".")

	for i in range(maxi(x.size(), y.size())):
		var p := x[i] if i < x.size() else "0"
		var q := y[i] if i < y.size() else "0"

		if p.is_valid_int() and q.is_valid_int():
			if int(p) != int(q):
				return -1 if int(p) < int(q) else 1
		elif p != q:
			return -1 if p < q else 1

	return 0


## Fetches every pack in [param wanted] and writes the overlay and its plan. Nothing is mounted: the boot script
## does that at the next start. [param resume] is kept in the plan for the shell to act on after the restart.
func build(wanted: Dictionary, resume: Dictionary = {}) -> GSResult:
	if cloud == null:
		return GSResult.fail(GSError.CODE_STATE, "No content client to fetch addons with.")

	var fingerprint := build_fingerprint()

	if fingerprint == "":
		return GSResult.fail(GSError.CODE_STATE, "This build does not say which addons it has.", BUILT_LOCK)

	var manifests := {}

	for dir: String in wanted:
		var entry: Dictionary = wanted[dir]
		var resolved := await cloud.resolve_manifest(StringName(entry["id"]), str(entry["version"]))

		if not resolved.ok:
			return resolved.wrap("Could not find %s %s." % [entry["id"], entry["version"]])

		var manifest: GSCloudManifest = resolved.value

		# [b]An addon pack holds the addon's directory, and its plugin.cfg says where.[/b] Without
		# one the files would land over `res://addons/<dir>/` at the wrong depth.
		if _Overlay.base(manifest, dir) == _Overlay.NOT_AN_ADDON:
			return GSResult.fail(
				GSError.CODE_INVALID,
				"%s is not an addon pack." % manifest.key(),
				"it has no plugin.cfg at its root or at addons/%s/" % dir
			)

		var downloaded := await cloud.download_manifest(manifest, groups)

		if not downloaded.ok:
			return downloaded.wrap("Could not download %s." % manifest.key())

		var same := _Checks.is_that_addon(cloud, dir, manifest)

		if not same.ok:
			return same

		manifests[dir] = manifest

	var assembled := _assemble(manifests, fingerprint)

	if not assembled.ok:
		return assembled

	var plan := {
		"format": FORMAT,
		"build": fingerprint,
		"pack": str(assembled.value["pack"]),
		"packs": assembled.value["packs"],
		"addons": wanted,
		"groups": groups,
		"uids": assembled.value["uids"],
		"probes": assembled.value["probes"],
		"state": STATE_READY,
		"resume": resume,
		"made": Time.get_datetime_string_from_system(true),
	}

	var written := write_plan(plan)
	if not written.ok:
		return written

	_prune(str(plan["pack"]))

	GSLog.info(CHANNEL, "addon overlay ready for the next start", {
		"pack": plan["pack"], "addons": _Checks.summary(wanted),
	})

	return GSResult.success(plan)


## Packs the files [member groups] left out of the overlay and mounts them in place, no restart (API 36). Only for a
## set built with [member groups] other than `*`, once that overlay is mounted. [param wanted] is [method build]'s
## table; [param late] limits the groups. Named by content, so idempotent. Returns {"pack", "files", "bytes", "mounted"}.
func late_pack(wanted: Dictionary, late: PackedStringArray = PackedStringArray()) -> GSResult:
	return await _Late.new(self).run(wanted, late)


## The project setting a game reads (`ProjectSettings.get_setting(LATE_PENDING, false)`) to know groups are still on their way:
## true from the moment a shell decides to top the overlay up until [method late_pack] has mounted it (or failed). A game that
## defers work on those files waits while it is true, and the files it asked for before then are drawn by its own fallback.
const LATE_PENDING := "gs_cloud/late_groups/pending"


## Sets [constant LATE_PENDING].
static func mark_late_pending(pending: bool) -> void:
	ProjectSettings.set_setting(LATE_PENDING, pending)


## Whether [constant LATE_PENDING] is set.
static func late_pending() -> bool:
	return bool(ProjectSettings.get_setting(LATE_PENDING, false))


## Bytes per part of a late pack, much smaller than [member part_bytes]: a part is written inside one frame, and the game is running.
var late_part_bytes: int = 24 * 1024 * 1024

## Milliseconds of packing before [method late_pack] gives the frame back.
var late_slice_msec: int = 6


## The overlay: every file at `res://addons/<dir>/<path>`, a self-pointing remap per
## resource, and the merged class list.
func _assemble(manifests: Dictionary, fingerprint: String) -> GSResult:
	var made := GSPaths.ensure_dir(DIR)
	if not made.ok:
		return made

	# Named by content, not `id@version`: a republished version must not reuse a stale file.
	# Reuse is required: the file may be the overlay this process has mounted, and rewriting
	# a mounted pack corrupts what it reads next.
	var pack_path := _Overlay.path(DIR, manifests, fingerprint, groups)
	var existing := _Overlay.existing_parts(pack_path)
	var reuse := not existing.is_empty()
	var scratch := DIR.path_join("staging")
	GSPaths.remove_tree(scratch)
	GSPaths.ensure_dir(scratch)

	var packer := _Overlay.Parts.new(pack_path, part_bytes)
	var err := OK

	var scripts := {}
	var uids: Array = []
	var probes := {}
	var replaced := PackedStringArray()
	var remap_index := 0

	for dir: String in manifests:
		var manifest: GSCloudManifest = manifests[dir]
		var root := "res://addons/%s" % dir
		var at := _Overlay.base(manifest, dir)
		replaced.append(root)

		for f in manifest.wanted_files(groups):
			if not cloud.store.has(f.sha256):
				return GSResult.fail(GSError.CODE_STATE, "An addon file is not downloaded.", f.path)

			var target := _Overlay.target(manifest, dir, at, f.path)
			var source := cloud.store.path_for(f.sha256)

			if not reuse:
				source = _Overlay.unrelocate(manifest, dir, at, f.path, source, scratch.path_join("t%d" % remap_index))
				err = _Overlay.add(packer, target, source, scratch.path_join("r%d.remap" % remap_index))
				if err != OK:
					return GSResult.failure(GSError.from_engine(err, "adding %s" % target))
			remap_index += 1

			var ext := f.path.get_extension().to_lower()
			# Only the addon's own scripts are classes; a project pack's tools are not.
			if ext == "gd" and target.begins_with(root + "/"):
				scripts[target] = FileAccess.get_file_as_string(source)
				_Overlay.note_probe(probes, dir, manifest, at, target)
			else:
				_Overlay.note_uid(uids, ext, source, target)

	if reuse:
		GSPaths.remove_tree(scratch)
		return GSResult.success({"pack": pack_path, "packs": existing, "uids": uids, "probes": probes, "classes": 0, "reused": true})

	var added := _write_class_cache(scripts, replaced, scratch)
	var cache_file := scratch.path_join("global_script_class_cache.cfg")

	err = packer.add_file(GSCloudScriptClass.CACHE_PATH, cache_file)
	if err != OK:
		return GSResult.failure(GSError.from_engine(err, "adding the class list"))

	err = packer.finish()
	if err != OK:
		return GSResult.failure(GSError.from_engine(err, "writing the addon overlay"))

	GSPaths.remove_tree(scratch)
	GSWeb.sync_filesystem()

	return GSResult.success({"pack": pack_path, "packs": packer.paths, "uids": uids, "probes": probes, "classes": added.size()})


## Writes the merged class list into [param scratch]; returns the entries this set added.
static func _write_class_cache(scripts: Dictionary, replaced: PackedStringArray, scratch: String) -> Array:
	# The build's list as the build shipped it -- saved by the boot script before any
	# overlay replaced it -- and only then this set's entries.
	var base := GSCloudScriptClass.read_cache(SHELL_CLASSES)
	if base.is_empty():
		base = GSCloudScriptClass.read_cache()

	var known := {}
	for e in base:
		if e is Dictionary:
			known[str(e.get("class", ""))] = e

	var added := GSCloudScriptClass.entries_for(scripts, known)
	var merged := GSCloudScriptClass.merge(base, replaced, added)
	var c := FileAccess.open(scratch.path_join("global_script_class_cache.cfg"), FileAccess.WRITE)
	c.store_string(GSCloudScriptClass.cache_text(merged))
	c.close()
	return added


## Deletes every overlay but [param keep] and the one mounted in this process, with their parts. An old
## overlay is never mounted again -- the plan names one -- so the rest is disk.
static func _prune(keep: String) -> void:
	var mounted := str(ProjectSettings.get_setting("gs_cloud/addon_overlay", ""))
	var dir := DirAccess.open(DIR)

	if dir == null:
		return

	for name in dir.get_files():
		var path := DIR.path_join(name)

		if name.begins_with("overlay-") and (name.ends_with(".pck") or name.ends_with(".part")) \
				and not _Overlay.is_part_of(path, keep) and not _Overlay.is_part_of(path, mounted):
			DirAccess.remove_absolute(path)
