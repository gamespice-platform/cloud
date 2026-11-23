extends RefCounted

## What [GSCloudStore] removes under pressure and in what order, in a file of its own so the store stays inside the
## size budget. Nothing here is used on its own.


## Whether [param h] is claimed by content mounted or downloaded in this process. A ref from an earlier session does not count.
static func held_now(store: RefCounted, h: String) -> bool:
	for k: Variant in (store._index[h]["refs"] as Array):
		if store._session_keys.has(k) or (store.in_use_fn.is_valid() and bool(store.in_use_fn.call(k))):
			return true
	return false


## Removes objects, least recently used first, until [param target] bytes are freed: unreferenced ones, then those whose
## only refs are from an earlier session (other maps' art nobody has mounted since the page opened). Pinned and held ones stay.
## Returns `{freed, candidates}`.
static func evict(store: RefCounted, target: int) -> Dictionary:
	var index: Dictionary = store._index
	var pinned: Dictionary = store.packs.pinned_hashes()
	var fresh: Array = []
	var stale: Array = []
	for h in index:
		if pinned.has(h):
			continue
		if (index[h]["refs"] as Array).is_empty():
			fresh.append(h)
		elif not held_now(store, h):
			stale.append(h)
	var by_use := func(a: String, b: String) -> bool: return int(index[a]["used"]) < int(index[b]["used"])
	fresh.sort_custom(by_use)
	stale.sort_custom(by_use)
	var candidates := fresh + stale

	var freed := 0
	for h in candidates:
		if freed >= target:
			break
		var size := int(index[h]["size"])
		var err := DirAccess.remove_absolute(store.path_for(h))
		if err != OK and FileAccess.file_exists(store.path_for(h)):
			GSLog.warn(store.CHANNEL, "could not evict object", {"hash": h.substr(0, 12)})
			continue
		store._forget(h)
		freed += size
	GSWeb.sync_filesystem()
	store.flush_index()
	return {"freed": freed, "candidates": candidates}
