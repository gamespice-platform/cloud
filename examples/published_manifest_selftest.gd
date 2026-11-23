extends Node

## Real signed manifests as the CDN serves them (examples/fixtures/prod/), through the parser and signature check: legacy and gs markers read, a changed payload refused,
## the kept copy verified offline, and the real dot_* requirements met by gs_* addons.
## Run: godot --headless --path . res://examples/published_manifest_selftest.tscn

const DIR := "res://examples/fixtures/prod/"
const GAMES := {"game-fatal-contact": "gamemann/game-fatal-contact", "dm-morpheus": "gamemann/dm-morpheus"}
const CHECKS := 54

var _failures := 0
var _checks := 0


func _ready() -> void:
	await _run()
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])
	print("\n%d checks, %d failed" % [_checks, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _run() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	var keys := {"tmc": FileAccess.get_file_as_string(DIR + "tmc.pem")}
	_check("the prod key loads", keys["tmc"].begins_with("-----BEGIN PUBLIC KEY"))
	for dir in GAMES:
		var id: String = GAMES[dir]
		var raw := FileAccess.get_file_as_bytes(DIR + dir + "/manifest.json")
		var latest: Variant = JSON.parse_string(FileAccess.get_file_as_string(DIR + dir + "/latest.json"))
		_check("%s: latest.json names the id" % dir, latest is Dictionary and latest.get("content_id") == id)
		var text := raw.get_string_from_utf8()
		_check("%s: the fixture is the legacy envelope" % dir, text.contains('"%s"' % GSCloudEnvelope.LEGACY_MARKER) and not text.contains('"%s"' % GSCloudEnvelope.MARKER))
		_variant(dir + " legacy", raw, id, keys, str(latest["version"]))
		var renamed := text.replace('"%s"' % GSCloudEnvelope.LEGACY_MARKER, '"%s"' % GSCloudEnvelope.MARKER)
		_variant(dir + " gs marker", renamed.to_utf8_buffer(), id, keys, str(latest["version"]))
		var env: Dictionary = GSCloudEnvelope.unwrap(raw).value
		var tampered: PackedByteArray = env["payload"].duplicate()
		tampered[tampered.size() / 2] ^= 1
		_check("%s: a changed payload fails the signature" % dir, not GSCloudSignature.verify_for(tampered, env["signature"], keys, id, env["key_id"]).ok)
		_check("%s: a different content id is refused" % dir, not GSCloudSignature.verify_for(env["payload"], env["signature"], {"tmc": {"key": keys["tmc"], "content_ids": ["other/*"]}}, id, env["key_id"]).ok)
	await _kept_copy(keys)
	_requirements()


## A fetched, verified manifest is kept as the envelope, so the kept copy verifies again with the network gone.
func _kept_copy(keys: Dictionary) -> void:
	var raw := FileAccess.get_file_as_bytes(DIR + "game-fatal-contact/manifest.json")
	var m: GSCloudManifest = GSCloudManifest.from_json_bytes(raw).value
	var work := "user://gs_cloud_published_cache"
	GSPaths.remove_tree(work)
	var config := GSCloudConfig.new()
	config.cache_dir = work
	config.trusted_keys = keys
	config.require_signed_manifests = true
	var client := GSCloudClient.new()
	client.config = config
	client.config_file = ""
	client.http_base_urls = PackedStringArray(["http://127.0.0.1:1"])
	client.allow_netchan_fallback = false
	add_child(client)
	await client.start()
	_check("the parsed manifest keeps its envelope", m.envelope_bytes == raw)
	GSCloudManifestCache.remember(client, m)
	var path := GSCloudManifestCache.path_for(work, m.content_id, m.version)
	_check("remember writes the envelope, not the bare payload", GSPaths.read_bytes(path).value == raw)
	var kept: GSResult = GSCloudManifestCache.load_cached(client, m.content_id, m.version)
	_check("the kept copy verifies offline against the prod key", kept.ok, str(kept.error))
	_check("and is the same manifest", kept.ok and kept.value.version == m.version and kept.value.signature_key_id == "tmc")
	GSPaths.write_bytes(path, m.raw_bytes)
	_check("a bare payload kept in its place is refused", not GSCloudManifestCache.load_cached(client, m.content_id, m.version).ok)
	remove_child(client)
	client.queue_free()
	GSPaths.remove_tree(work)


## The real Fatal Contact requires.json names dot_* addons; a build carrying gs_* satisfies them, and a missing one still fails.
func _requirements() -> void:
	var text := FileAccess.get_file_as_string(DIR + "game-fatal-contact/requires.json")
	var parsed := GSAddonApi.parse(text)
	_check("the real requires.json parses", parsed.ok, str(parsed.error))
	var legacy: Dictionary = parsed.value if parsed.ok else {}
	_check("it names legacy dot_ addons", legacy.keys().filter(func(k: String) -> bool: return k.begins_with("dot_")).size() > 10, str(legacy.keys().slice(0, 3)))
	var renamed: Dictionary = GSCloudLegacyRequirements.rename(legacy)
	_check("every dot_ one maps to a gs_ name at its level, others are left alone", renamed.size() == legacy.size() and legacy.keys().all(func(k: String) -> bool: return renamed.get("gs_" + k.substr(4) if k.begins_with("dot_") else k, -1) == legacy[k]))
	var api := GSAddonApi.new()
	for name: String in renamed:
		api.overrides[name] = {"level": 999, "oldest": 1}
	_check("a build with the gs_ addons meets the list", api.check(renamed).ok, str(api.check(renamed).error))
	_check("the unmapped list is still refused", not api.check(legacy).ok)
	var with_missing := renamed.duplicate()
	with_missing["gs_no_such_addon"] = 1
	_check("a missing gs_ addon still fails", not api.check(with_missing).ok)
	api.overrides.erase("gs_core")
	_check("and a pack older than the build's OLDEST is no longer refused", api.check({"gs_core": 1}).ok)
	_check("dash names map too", GSCloudLegacyRequirements.modern_name("dot-audio") == "gs-audio" and GSCloudLegacyRequirements.modern_name("gs_audio") == "gs_audio")
	api.overrides["gs_core"] = 2
	var newer := GSAddonApi.encode({"gs_core": 9})
	_check("a newer pack is refused by default", not GSCloudLegacyRequirements.check_text(api, newer, "client").ok)
	_check("and tried in a solo session (lenient_newer)", GSCloudLegacyRequirements.check_text(api, newer, "client", true).ok)
	_check("both names keep the higher level", GSCloudLegacyRequirements.rename({"dot_core": 3, "gs_core": 5}) == {"gs_core": 5})


func _variant(label: String, bytes: PackedByteArray, id: String, keys: Dictionary, version: String) -> void:
	_check("%s: recognised as an envelope" % label, GSCloudEnvelope.is_envelope(bytes))
	var unwrapped := GSCloudEnvelope.unwrap(bytes)
	_check("%s: unwrapped as signed" % label, unwrapped.ok and unwrapped.value["signed"] and unwrapped.value["key_id"] == "tmc", str(unwrapped.error))
	var parsed := GSCloudManifest.from_json_bytes(bytes)
	_check("%s: parsed" % label, parsed.ok, str(parsed.error))
	if not parsed.ok:
		_check("%s: skipped" % label, false)
		_check("%s: skipped" % label, false)
		_check("%s: skipped" % label, false)
		return
	var m: GSCloudManifest = parsed.value
	_check("%s: content id and version" % label, m.content_id == id and m.version == version, "%s %s" % [m.content_id, m.version])
	_check("%s: lists files" % label, m.files.size() > 0)
	var verified := GSCloudSignature.verify_for(m.raw_bytes, m.signature, keys, m.content_id, m.signature_key_id)
	_check("%s: signature verifies under the prod key" % label, verified.ok, str(verified.error))
	_check("%s: signed by tmc" % label, verified.ok and verified.value == "tmc")


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("  %s %s%s" % ["ok  " if ok else "FAIL", label, "" if ok or detail == "" else " (" + detail + ")"])
