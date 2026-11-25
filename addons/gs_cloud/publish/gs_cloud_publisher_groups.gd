extends RefCounted

## The `groups.json` rules of [GSCloudPublisher], in a file of their own so the publisher stays inside
## the size budget. Nothing here is used on its own.

const _Sides := preload("gs_cloud_publisher_sides.gd")
## [constant GROUPS_FILE] lives here so this file never names the publisher.
const GROUPS_FILE := "groups.json"
## Set this meta on the publisher (the CLI's `--skip-groups`) to ignore `groups.json`: for a raw source store, whose group patterns may match nothing in its tree.
const SKIP_META := &"skip_groups"


## Reads the source's `groups.json` and returns pack path -> PackedStringArray of the groups the file joins (a path in no rule is absent). Two shapes, mixable: [code]{"group": ["prefix/", "glob*"]}[/code] and [code]{"prefix/": "group"}[/code]
## (as `sides.json` and [member GSCloudPublisher.group_rules]). Patterns follow the sides rules (trailing `/` is a directory prefix, else a `String.match` glob where `*` crosses `/`); an `.import` marker and an output relocated to `_imported/` ([param owners]) match by their asset's path.
## Refused as CODE_INVALID: a pattern that matches nothing (a typo would publish the files ungrouped and say nothing), an empty group, a pattern that is not a pack path, a malformed entry.
static func groups_for(pub: RefCounted, source_dir: String, relatives: PackedStringArray, owners: Dictionary = {}) -> GSResult:
	var file := source_dir.path_join(GROUPS_FILE)
	if not FileAccess.file_exists(file) or pub.has_meta(SKIP_META):
		return GSResult.success({})
	var read := GSPaths.read_json(file)
	if not read.ok:
		return read.wrap("Could not read %s." % GROUPS_FILE)
	if not (read.value is Dictionary):
		return GSResult.fail(GSError.CODE_PARSE, "%s must be a JSON object." % GROUPS_FILE)

	var rules := _rules(read.value as Dictionary)
	if not rules.ok:
		return rules

	var hits := {}
	var out := {}
	for rel in relatives:
		var names := PackedStringArray([rel])
		if rel.ends_with(".import"):
			names.append(rel.trim_suffix(".import"))
		if owners.has(rel):
			names.append(str(owners[rel]))
		var groups := PackedStringArray()
		for rule: Array in rules.value:
			for n in names:
				if _Sides.pattern_matches(rule[0], n):
					hits[rule[0]] = true
					if not groups.has(rule[1]):
						groups.append(rule[1])
					break
		if not groups.is_empty():
			out[rel] = groups

	for rule: Array in rules.value:
		if not hits.has(rule[0]):
			return GSResult.fail(
				GSError.CODE_INVALID,
				"Group rule '%s' (group '%s') matches nothing in the pack." % [rule[0], rule[1]],
				"a typo here publishes the files ungrouped and says nothing"
			)
	GSLog.debug(_Sides.CHANNEL, "group rules applied", {"content": pub.content_id, "grouped": out.size()})
	return GSResult.success(out)


## The file's entries as [[pattern, group], ...], validated.
static func _rules(doc: Dictionary) -> GSResult:
	var list: Array = []
	for key: Variant in doc:
		var value: Variant = doc[key]
		var pairs: Array = []
		if value is Array:
			if (value as Array).is_empty():
				return _bad("group '%s' lists no pattern" % key)
			for pattern: Variant in (value as Array):
				pairs.append([str(pattern), str(key)])
		elif value is String:
			pairs.append([str(key), str(value)])
		else:
			return _bad("'%s' must be a list of patterns or a group name" % key)
		for pair: Array in pairs:
			var pattern: String = pair[0]
			if str(pair[1]).strip_edges() == "":
				return _bad("an empty group name")
			if str(pair[1]).strip_edges() == GSCloudFile.ALL_GROUPS:
				return _bad("'%s' means every group to a client, so it cannot name one" % GSCloudFile.ALL_GROUPS)
			if pattern.strip_edges() == "" or pattern.begins_with("res://") or pattern.begins_with("/"):
				return _bad("'%s' is not a pack path (relative to the source root, like worlds/ or worlds/a.*)" % pattern)
			list.append(pair)
	return GSResult.success(list)


static func _bad(why: String) -> GSResult:
	return GSResult.fail(GSError.CODE_INVALID, "%s: %s." % [GROUPS_FILE, why])
