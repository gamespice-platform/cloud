extends Node

## Manifest resolving when the content network cannot be reached: every address tried is named in the failure, and content already fetched starts from the kept,
## re-verified manifest. A manifest that arrived and was refused is never replaced by the kept one.
## Run: godot --headless --path . res://examples/manifest_cache_selftest.tscn

const TestServer := preload("res://examples/http_test_server.gd")
const WORK := "user://gs_cloud_manifest_cache"
const ID := "cache_test/game"
const CHECKS := 26

var _failures := 0
var _checks := 0
var _noticed: Array = []


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	GSPaths.remove_tree(WORK)
	await _run()
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])
	print("\n%d checks, %d failed" % [_checks, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	_test_paths()
	_test_legacy_envelope()
	if not _publish("1.0.0") or not _publish("1.1.0"):
		return
	var cdn: Node = TestServer.new()
	cdn.root = WORK.path_join("pub")
	add_child(cdn)
	var started: GSResult = cdn.start(0)
	if not started.ok:
		_check("server", false, str(started.error))
		return
	var live: String = cdn.base_url()
	var cache := WORK.path_join("cache")

	var online := await _client(cache, [live])
	var got: GSResult = await online.resolve_manifest(StringName(ID), "1.0.0")
	_check("online resolve", got.ok, str(got.error))
	await online.resolve_manifest(StringName(ID), "1.1.0")
	_check("fetched manifests are kept, newest first", Array(GSCloudManifestCache.versions(online.config.cache_dir, ID)) == ["1.1.0", "1.0.0"], str(GSCloudManifestCache.versions(online.config.cache_dir, ID)))
	_check("an online resolve is not reported as cached", _noticed.is_empty())
	_drop(online)
	cdn.stop()

	var dead: String = "http://127.0.0.1:%d" % cdn.port
	var offline := await _client(cache, [dead])
	var kept: GSResult = await offline.resolve_manifest(StringName(ID), "1.0.0")
	_check("offline, the kept manifest resolves", kept.ok, str(kept.error))
	_check("and is the one that was published", kept.ok and kept.value.version == "1.0.0" and kept.value.content_id == ID)
	_check("with the network base as its mirror", kept.ok and Array(kept.value.mirrors).any(func(m: String) -> bool: return m.begins_with(dead)), str(kept.value.mirrors if kept.ok else ""))
	_check("the client says it used the kept copy", _noticed.size() == 1 and str(_noticed[0]).contains(dead), str(_noticed))

	var none: GSResult = await offline.resolve_manifest(StringName(ID), "9.9.9")
	_check("a version never fetched still fails", not none.ok)
	_check("naming every address and why", not none.ok and str(none.error.detail).contains(dead) and str(none.error.detail).contains("manifest.json"), str(none.error))
	_check("and that nothing is kept", not none.ok and str(none.error.detail).contains("9.9.9"), str(none.error))
	var unversioned: GSResult = await offline.resolve_manifest(StringName(ID), "")
	_check("no version asked is never answered from the cache", not unversioned.ok)

	# A damaged copy is refused, not trusted because it is local.
	var path := GSCloudManifestCache.path_for(cache, ID, "1.0.0")
	GSPaths.write_text(path, "{ not json")
	var damaged: GSResult = await offline.resolve_manifest(StringName(ID), "1.0.0")
	_check("a damaged kept manifest fails", not damaged.ok)
	_check("saying the kept copy is the reason", not damaged.ok and str(damaged.error.detail).contains("kept copy"), str(damaged.error))

	# A signed client refuses a kept manifest whose signature is gone.
	GSPaths.write_bytes(path, GSPaths.read_bytes(GSCloudManifestCache.path_for(cache, ID, "1.1.0")).value)
	_check("a kept manifest of another version is refused", not (await offline.resolve_manifest(StringName(ID), "1.0.0")).ok)
	offline.config.require_signed_manifests = true
	var unsigned: GSResult = await offline.resolve_manifest(StringName(ID), "1.1.0")
	_check("an unsigned kept manifest is refused by a client that needs signatures", not unsigned.ok)
	_drop(offline)

	# A live server that has no such manifest (404) counts as unreachable for this: the kept copy of a version fetched before still starts.
	var live2: Node = TestServer.new()
	live2.root = WORK.path_join("empty")
	GSPaths.ensure_dir(live2.root)
	add_child(live2)
	live2.start(0)
	var answered := await _client(cache, [live2.base_url()])
	var nf: GSResult = await answered.resolve_manifest(StringName(ID), "1.1.0")
	_check("a 404 from a live server uses the kept copy of a published version", nf.ok, str(nf.error))
	var told: GSResult = await answered.resolve_manifest(StringName(ID), "7.0.0")
	_check("the failure names the status of the live server", not told.ok and str(told.error.detail).contains(live2.base_url()) and (str(told.error.detail).contains("404") or str(told.error.detail).contains("Not found")), str(told.error))
	_drop(answered)
	live2.stop()


func _test_paths() -> void:
	_check("a path never leaves the cache", GSCloudManifestCache.path_for("user://c", "../x", "1.0.0") == "" and GSCloudManifestCache.path_for("user://c", "a/b", "..") == "")
	_check("an id with a slash is one directory", GSCloudManifestCache.path_for("user://c", "a/b", "1.0.0") == "user://c/manifests/a__b/1.0.0.json")
	_check("no cache directory keeps nothing", GSCloudManifestCache.path_for("", "a", "1.0.0") == "")


## Manifests signed before the rename carry the old marker; read as bare, they failed with "no content_id" and nothing published started.
func _test_legacy_envelope() -> void:
	var inner := JSON.stringify({"content_id": "a/b", "version": "1.0.0", "files": []}).to_utf8_buffer()
	var current := GSCloudEnvelope.wrap(inner, "c2ln", "tmc")
	var old := current.replace('"%s"' % GSCloudEnvelope.MARKER, '"%s"' % GSCloudEnvelope.LEGACY_MARKER)
	var got: GSResult = GSCloudEnvelope.unwrap(old.to_utf8_buffer())
	_check("an envelope with the pre-rename marker is unwrapped as signed", got.ok and got.value["signed"] and got.value["payload"] == inner and got.value["key_id"] == "tmc", str(got.error))
	_check("and is recognised as an envelope", GSCloudEnvelope.is_envelope(old.to_utf8_buffer()) and GSCloudEnvelope.is_envelope(current.to_utf8_buffer()))
	_check("a bare manifest is still not one", not GSCloudEnvelope.is_envelope(inner))


func _publish(version: String) -> bool:
	var src := WORK.path_join("src")
	GSPaths.write_text(src.path_join("a.txt"), ("cache %s\n" % version).repeat(32))
	var pub := GSCloudPublisher.new()
	pub.content_id = ID
	pub.version = version
	pub.entry_scene = "a.txt"
	var out := pub.publish(src, WORK.path_join("pub").path_join(ID).path_join(version))
	_check("published %s" % version, out.ok, str(out.error))
	return out.ok


func _client(cache: String, bases: Array) -> GSCloudClient:
	var config := GSCloudConfig.new()
	config.cache_dir = cache
	config.require_signed_manifests = false
	config.file_timeout_sec = 5.0
	var client := GSCloudClient.new()
	client.config = config
	client.config_file = ""
	client.http_base_urls = PackedStringArray(bases)
	client.allow_netchan_fallback = false
	client.manifest_from_cache.connect(func(_m: GSCloudManifest, detail: String) -> void: _noticed.append(detail))
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
