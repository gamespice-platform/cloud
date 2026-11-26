extends Node

## A second launch on the same cache asks the network for no object: a versioned `ensure` is answered from the
## kept manifest and the store, a newest-version ask may refetch the manifest only, a lost object refetches just that one.
## Run: godot --headless --path . res://examples/relaunch_selftest.tscn

const TestServer := preload("res://examples/http_test_server.gd")
const WORK := "user://gs_cloud_relaunch"
const ID := "relaunch_test/game"
const VERSION := "1.0.0"
const CHECKS := 8

var _failures := 0
var _checks := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	GSPaths.remove_tree(WORK)
	await _run()
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])
	print("\n%d checks, %d failed" % [_checks, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	var src := WORK.path_join("src")
	for i in 6:
		GSPaths.write_text(src.path_join("f%d.txt" % i), ("object %d\n" % i).repeat(64))
	var pub := GSCloudPublisher.new()
	pub.content_id = ID
	pub.version = VERSION
	pub.entry_scene = "f0.txt"
	var out := pub.publish(src, WORK.path_join("pub").path_join(ID).path_join(VERSION))
	_check("published", out.ok, str(out.error))
	if not out.ok:
		return
	var cdn: Node = TestServer.new()
	cdn.root = WORK.path_join("pub")
	add_child(cdn)
	if not cdn.start(0).ok:
		_check("server", false)
		return
	var cache := WORK.path_join("cache")

	var first := await _client(cache, cdn)
	var got: GSResult = await first.ensure(StringName(ID), VERSION)
	_check("first launch fetches the content", got.ok and cdn.log.size() > 0, str(got.error))
	_drop(first)

	cdn.log.clear()
	var second := await _client(cache, cdn)
	var again: GSResult = await second.ensure(StringName(ID), VERSION)
	_check("second launch succeeds", again.ok, str(again.error))
	_check("second launch makes no request at all", cdn.log.is_empty(), str(cdn.log))
	_drop(second)

	cdn.log.clear()
	var third := await _client(cache, cdn)
	await third.ensure(StringName(ID), "")
	_check("and fetches no object", _objects(cdn) == 0, str(cdn.log))
	_drop(third)

	# One object lost from disk is repaired by fetching only that object.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_first_object(cache)))
	cdn.log.clear()
	var fourth := await _client(cache, cdn)
	var healed: GSResult = await fourth.ensure(StringName(ID), VERSION)
	_check("a lost object is fetched again", healed.ok and _objects(cdn) >= 1, str(healed.error))
	_check("and only that one", _objects(cdn) <= 1, str(cdn.log))
	_drop(fourth)
	cdn.stop()


## Requests for pack files: everything except the manifest, requires.json and latest.json.
func _objects(cdn: Node) -> int:
	var n := 0
	for line in cdn.log:
		if line.contains("manifest.json") or line.contains("requires.json") or line.contains("latest.json"):
			continue
		n += 1
	return n


func _first_object(cache: String) -> String:
	var objects := cache.path_join("objects")
	for shard in DirAccess.get_directories_at(objects):
		for f in DirAccess.get_files_at(objects.path_join(shard)):
			return objects.path_join(shard).path_join(f)
	return ""


func _client(cache: String, cdn: Node) -> GSCloudClient:
	var config := GSCloudConfig.new()
	config.cache_dir = cache
	config.require_signed_manifests = false
	config.file_timeout_sec = 5.0
	var client := GSCloudClient.new()
	client.config = config
	client.config_file = ""
	client.http_base_urls = PackedStringArray([cdn.base_url()])
	client.allow_netchan_fallback = false
	add_child(client)
	await client.start()
	return client


func _drop(client: GSCloudClient) -> void:
	remove_child(client)
	client.queue_free()


func _check(label: String, passed: bool, detail: String = "") -> void:
	_checks += 1
	print("  %s  %s%s" % ["ok  " if passed else "FAIL", label, "" if passed or detail == "" else " (" + detail + ")"])
	if not passed:
		_failures += 1
