class_name GSCloudInventoryBridge
extends RefCounted

## Answers an embedding page's requests about downloaded content. Transport-free: [method handle] takes a decoded message and the sender's origin, so the web shell feeds it postMessage events and tests feed it dictionaries.
## Schema: GameSpice Server Deploy docs/web-inventory-bridge.md.

const CHANNEL := "cloud.inventory"
const PROTOCOL := "dot-inventory"
const VERSION := 1
const OPS: PackedStringArray = ["list", "quota", "pin", "pin_game", "delete", "clear", "clear_all", "sync"]

var store: GSCloudStore

## Origins allowed to ask. Empty answers nobody; "*" is never honoured.
var allowed_origins: PackedStringArray = PackedStringArray()

## Optional [code]func() -> GSResult[/code] for [code]clear_all[/code], when the host must also remount or reload.
var clear_all_fn: Callable = Callable()


func _init(p_store: GSCloudStore, p_origins: PackedStringArray = PackedStringArray()) -> void:
	store = p_store
	allowed_origins = p_origins


func is_origin_allowed(origin: String) -> bool:
	return origin != "" and origin != "*" and origin != "null" and allowed_origins.has(origin)


## Whether [param message] is addressed to this bridge, so a transport can ignore unrelated page traffic.
static func is_request(message: Variant) -> bool:
	return message is Dictionary and message.get("dot") == PROTOCOL and message.has("op")


## Returns the reply dictionary, or an empty one when the origin is not allowed (no reply: an unlisted page learns nothing, not even that a bridge exists).
func handle(message: Dictionary, origin: String) -> Dictionary:
	if not is_origin_allowed(origin):
		GSLog.warn(CHANNEL, "request from an origin not on the list", {"origin": origin})
		return {}
	var rid: Variant = message.get("id")
	var op := str(message.get("op", ""))
	var v: Variant = message.get("v", VERSION)
	if not (v is int or v is float) or int(v) != VERSION:
		return _reply(rid, op, GSResult.fail(GSError.CODE_VERSION, "Unsupported bridge version."))
	if not OPS.has(op):
		return _reply(rid, op, GSResult.fail(GSError.CODE_INVALID, "Unknown op."))
	return _reply(rid, op, await _run(op, message))


func _run(op: String, m: Dictionary) -> GSResult:
	var id := str(m.get("pack", ""))
	match op:
		"list":
			return GSResult.success({"packs": store.inventory(), "pinned_games": Array(store.packs.pinned_games)})
		"quota":
			return GSResult.success(await store.quota_report())
		"pin":
			if id == "" or not (m.get("pinned") is bool):
				return GSResult.fail(GSError.CODE_INVALID, "pin needs pack and pinned.")
			return store.set_pinned(id, m["pinned"])
		"pin_game":
			var game := str(m.get("game", ""))
			if game == "" or not (m.get("pinned") is bool):
				return GSResult.fail(GSError.CODE_INVALID, "pin_game needs game and pinned.")
			return store.set_game_pinned(game, m["pinned"])
		"delete":
			if id == "":
				return GSResult.fail(GSError.CODE_INVALID, "delete needs pack.")
			return store.delete(id, str(m.get("version", "")), m.get("force") == true)
		"clear":
			return store.clear_unpinned()
		"sync":
			# The site's account inventory: carry out what it asked for, answer with the report body to forward.
			var pending: Variant = m.get("pending", [])
			if not (pending is Array):
				return GSResult.fail(GSError.CODE_INVALID, "sync needs pending as an array.")
			var applied := GSCloudInventoryReport.apply_pending(store, pending)
			var report := GSCloudInventoryReport.body(store.inventory(), applied["ack"])
			report["done"] = applied["done"]
			report["refused"] = applied["refused"]
			return GSResult.success(report)
		"clear_all":
			if clear_all_fn.is_valid():
				return await clear_all_fn.call()
			return store.clear_all()
	return GSResult.fail(GSError.CODE_INVALID, "Unknown op.")


func _reply(rid: Variant, op: String, res: GSResult) -> Dictionary:
	var out := {"dot": PROTOCOL, "v": VERSION, "id": rid, "op": op, "ok": res.ok}
	if res.ok:
		out["value"] = res.value
	else:
		out["error"] = {"code": res.error.code, "message": res.error.message}
	return out
