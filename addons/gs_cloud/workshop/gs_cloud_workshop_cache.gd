class_name GSCloudWorkshopCache
extends RefCounted

## The last subscription list per game, kept beside [code]device.json[/code] so an offline launch can still
## mount what the player subscribed to. One JSON file per game; a list from another account is not used.

const CHANNEL := "gs.cloud.workshop"


static func path_for(dir: String, game: String) -> String:
	return dir.path_join("%s_%s.json" % [GSPaths.slugify(game, 40), game.sha256_text().substr(0, 8)])


## The kept file for [param game], or {} when there is none or it cannot be read.
static func read(dir: String, game: String) -> Dictionary:
	var path := path_for(dir, game)
	if not FileAccess.file_exists(path):
		return {}
	var read_result := GSPaths.read_json(path)
	if not read_result.ok or not (read_result.value is Dictionary):
		GSLog.warn(CHANNEL, "cached list unreadable, ignoring it", {"path": path})
		return {}
	var d: Dictionary = read_result.value
	if not (d.get("response", null) is Dictionary):
		return {}
	return d


## True when [param cached] was fetched for [param account_id] (or no account is set).
static func is_this_account(cached: Dictionary, account_id: String) -> bool:
	if account_id == "":
		return true
	return GSValue.same(str(cached.get("account", "")), account_id)


static func write(dir: String, game: String, list: GSCloudWorkshopList) -> void:
	var written := GSPaths.write_json(path_for(dir, game), {
		"account": list.account(), "revision": list.revision(),
		"fetched_at": int(Time.get_unix_time_from_system()), "response": list.response,
	})
	if not written.ok:
		GSLog.warn(CHANNEL, "could not cache the list", {"why": written.code(), "message": written.error.message})


static func drop(dir: String, game: String) -> void:
	var path := path_for(dir, game)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		GSWeb.sync_filesystem()


## Blanks the kept revision so the next sync asks the site for the whole list again.
static func forget_revision(dir: String, game: String) -> void:
	var cached := read(dir, game)
	if cached.is_empty():
		return
	cached["revision"] = ""
	GSPaths.write_json(path_for(dir, game), cached)
