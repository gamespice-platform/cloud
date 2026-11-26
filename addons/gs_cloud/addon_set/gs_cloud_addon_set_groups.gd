extends RefCounted

## Groups for a pack whose signed manifest tags none (API 38). The site's publish path tags sides but not groups, so a pack
## that ships `groups.json` would otherwise come down whole to a client that asked for some groups. The rules are the
## publisher's own (gs_cloud_publisher_groups.gd), read from that file, so a client and a tagging publisher agree.

const _Rules := preload("../publish/gs_cloud_publisher_groups.gd")
const CHANNEL := "cloud"


## Tags [param manifest]'s files from its `groups.json` when [param wanted] is not every group, no file carries a group yet and
## the pack ships the file. Fetches that one file. Anything it cannot read leaves the manifest untagged: the whole pack, as before.
static func derive(cloud: GSCloudClient, manifest: GSCloudManifest, wanted: PackedStringArray) -> void:
	if wanted.has(GSCloudFile.ALL_GROUPS):
		return
	var has_doc := false
	for f in manifest.files:
		if not f.groups.is_empty():
			return
		has_doc = has_doc or f.path == _Rules.GROUPS_FILE
	if not has_doc:
		return

	var read: GSResult = await cloud.read_pack_file(manifest, _Rules.GROUPS_FILE)
	var json := JSON.new()
	if not read.ok or json.parse((read.value as PackedByteArray).get_string_from_utf8()) != OK or not (json.data is Dictionary):
		GSLog.warn(CHANNEL, "groups.json unreadable, fetching the whole pack", {"content": manifest.key()})
		return
	var rules := _Rules.rules_of(json.data as Dictionary)
	if not rules.ok:
		GSLog.warn(CHANNEL, "groups.json invalid, fetching the whole pack", {"content": manifest.key(), "why": rules.error})
		return

	var paths := PackedStringArray()
	for f in manifest.files:
		paths.append(f.path)
	var tagged := _Rules.tag(rules.value, paths, {}, {})
	for f in manifest.files:
		if tagged.has(f.path):
			f.groups = tagged[f.path]
	GSLog.info(CHANNEL, "groups read from groups.json", {"content": manifest.key(), "grouped": tagged.size()})
