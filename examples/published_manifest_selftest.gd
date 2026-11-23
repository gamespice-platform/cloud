extends Node

## Real signed manifests as the CDN serves them (examples/fixtures/prod/), through the parser and
## the signature check. The legacy dot_cloud_signed marker is read, a gs_cloud_signed rewrite of the
## same envelope is read too, and a changed payload is refused.
## Run: godot --headless --path . res://examples/published_manifest_selftest.tscn

const DIR := "res://examples/fixtures/prod/"
const GAMES := {"game-fatal-contact": "gamemann/game-fatal-contact", "dm-morpheus": "gamemann/dm-morpheus"}
const CHECKS := 38

var _failures := 0
var _checks := 0


func _ready() -> void:
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
	_check("every check ran", _checks + 1 == CHECKS, "%d of %d" % [_checks + 1, CHECKS])
	print("\n%d checks, %d failed" % [_checks, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


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
