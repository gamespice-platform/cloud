class_name GSCloudWorkshopDevice
extends RefCounted

## This device's overrides of the subscription list: packs turned off here, and the metered policy.
##
## [b]They stay on the device.[/b] "Off on this phone" is not a subscription change and never
## reaches the site; anything that should follow the player to another device is a scope change
## ([method GSCloudWorkshop.set_scope]). Stored in [code]device.json[/code] beside the cached lists.

const CHANNEL := "gs.cloud.workshop"

var path: String = ""
var _off: Dictionary = {}
var _metered: String = ""
var _suggested: String = ""


func _init(p_path: String = "") -> void:
	path = p_path


## Reads the file. A missing file is an empty override set; a corrupt one is too, with a WARN,
## because a bad device file must never stop a game from starting.
func load_file() -> GSResult:
	_off = {}
	_metered = ""
	_suggested = ""
	if path == "" or not FileAccess.file_exists(path):
		return GSResult.success(self)
	var read := GSPaths.read_json(path)
	if not read.ok:
		GSLog.warn(CHANNEL, "device file unreadable, using no overrides", {"path": path, "why": str(read.error)})
		return GSResult.success(self)
	if read.value is Dictionary:
		var d: Dictionary = read.value
		var off: Variant = d.get("off", [])
		if off is Array:
			for id in off as Array:
				_off[str(id)] = true
		var m := str(d.get("metered", ""))
		if ["ask", "allow", "never"].has(m):
			_metered = m
		var sg := str(d.get("suggested", ""))
		if sg != "" and GSCloudSuggested.valid_mode(sg):
			_suggested = sg
	return GSResult.success(self)


## Writes the file atomically (and flushes the browser's filesystem, through [GSPaths]).
func save_file() -> GSResult:
	if path == "":
		return GSResult.success(null)
	var off: Array = _off.keys()
	off.sort()
	var data := {"off": off}
	if _metered != "":
		data["metered"] = _metered
	if _suggested != "":
		data["suggested"] = _suggested
	return GSPaths.write_json(path, data)


func is_off(content_id: String) -> bool:
	return _off.has(content_id)


func set_off(content_id: String, off: bool) -> void:
	if off:
		_off[content_id] = true
	else:
		_off.erase(content_id)


## The device's metered policy, or [param fallback] when it has none.
func metered_policy(fallback: String) -> String:
	return _metered if _metered != "" else fallback


func set_metered_policy(policy: String) -> GSResult:
	if policy != "" and not ["ask", "allow", "never"].has(policy):
		return GSResult.fail(GSError.CODE_INVALID, "Unknown metered policy.", policy)
	_metered = policy
	return GSResult.success(null)


func off_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for k in _off:
		out.append(str(k))
	out.sort()
	return out


## This device's suggested-packs mode ("" follows the config).
func suggested_mode() -> String:
	return _suggested


func set_suggested_mode(mode: String) -> GSResult:
	if mode != "" and not GSCloudSuggested.valid_mode(mode):
		return GSResult.fail(GSError.CODE_INVALID, "Unknown suggested mode.", mode)
	_suggested = mode
	return GSResult.success(null)
