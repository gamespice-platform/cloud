class_name GSCloudLegacyRequirements
extends RefCounted

## Packs published before the dot to gs rename ask for dot_<x> addons; this build carries gs_<x>. Read only: nothing here writes the old names.

const OLD_PREFIXES := ["dot_", "dot-"]
const NEW_PREFIXES := ["gs_", "gs-"]


## [method GSAddonApi.check_text] with the legacy names read as gs names.
static func check_text(api: GSAddonApi, text: String, who: String) -> GSResult:
	var parsed := GSAddonApi.parse(text)
	return api.check(rename(parsed.value as Dictionary), who) if parsed.ok else parsed


## [param requirements] ({addon: level}) with every legacy name replaced by its gs name. A pack that names both keeps the higher level.
static func rename(requirements: Dictionary) -> Dictionary:
	var out := {}
	for key in requirements.keys():
		var name := modern_name(str(key))
		var level := int(requirements[key])
		out[name] = maxi(level, int(out.get(name, 0)))
	return out


## The gs name of [param addon], or [param addon] itself when it is not a legacy one.
static func modern_name(addon: String) -> String:
	for i in OLD_PREFIXES.size():
		if addon.begins_with(OLD_PREFIXES[i]):
			return NEW_PREFIXES[i] + addon.substr(OLD_PREFIXES[i].length())
	return addon
