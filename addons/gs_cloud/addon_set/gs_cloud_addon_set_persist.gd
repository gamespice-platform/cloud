extends RefCounted

## Waits for the browser's IndexedDB copy of `user://` to hold given files (the work behind
## [method GSCloudAddonSet.persisted]). Static only; nothing here is specific to an overlay.

const _Checks := preload("gs_cloud_addon_set_checks.gd")

## The engine's object store inside the IndexedDB database that mirrors `user://`
## (Emscripten's IDBFS names the store; the database is named for the mount point).
const IDB_STORE := "FILE_DATA"

## Files up to this size are compared byte for byte; a larger one by its length, which is
## enough for an overlay (named by the hash of its contents, so a file of that name and
## length is that overlay).
const PERSIST_COMPARE_BYTES := 256 * 1024


## Waits until every file in [param paths] is in the browser's IndexedDB exactly as it is
## in `user://` now. Succeeds at once anywhere else, where a closed file is on disk.
##
## [b]What a browser restart has to wait for, and the only way to know.[/b] A browser's
## `user://` is an in-memory copy that reaches IndexedDB only through `FS.syncfs`, which
## the engine runs one at a time from its main loop ([method GSWeb.sync_filesystem] only
## asks for the next one) and which says nothing to a script when it is done. Each sync
## walks EVERY file under `user://` and writes what changed, so it takes as long as the
## player's cache is large: measured at 1 to 5 seconds with under 1 MiB cached, while the
## shell reloaded on a fixed three seconds. A reload in the middle of a sync loses that
## sync, so the plan and the overlay were never written and the page came back to download
## the same addons again. Reading the database itself is the one answer that is not a guess.
##
## Fails with [code]CODE_TIMEOUT[/code] when [param timeout_s] passes first, and with
## [code]CODE_UNSUPPORTED[/code] when the page has no IndexedDB copy of `user://` at all (a
## private window, storage refused): a restart there could only lose what was written, so
## the caller should not restart.
static func wait(paths: PackedStringArray, timeout_s: float = 30.0) -> GSResult:
	if not GSWeb.available():
		return GSResult.success(true)

	var want := {}
	var db_name := ""

	for path in paths:
		if not FileAccess.file_exists(path):
			return GSResult.fail(GSError.CODE_IO, "There is no file to keep.", path)

		var key := ProjectSettings.globalize_path(path)
		var f := FileAccess.open(path, FileAccess.READ)
		var size := f.get_length()
		f.close()
		# A large file by its length only: an overlay part is hundreds of MiB, too much to hold twice.
		var small := size <= PERSIST_COMPARE_BYTES
		want[key] = {"size": size, "sha": GSHash.sha256_bytes(FileAccess.get_file_as_bytes(path)) if small else ""}
		# `/userfs/godot/app_userdata/<name>/...` is kept in the database `/userfs`.
		var parts := key.split("/", false)
		db_name = "/" + parts[0] if parts.size() > 0 else ""

	if want.is_empty():
		return GSResult.success(true)

	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	var waiting: Array = want.keys()

	while true:
		GSWeb.sync_filesystem()
		await tree.create_timer(0.5).timeout

		var read := await _idb_differs(db_name, want)

		if not read.ok:
			return read

		waiting = read.value

		if waiting.is_empty():
			return GSResult.success(true)

		if Time.get_ticks_msec() >= deadline:
			break

	return GSResult.fail(
		GSError.CODE_TIMEOUT,
		"The browser did not save the files a restart needs in time.",
		", ".join(PackedStringArray(waiting))
	)


## The keys of [param want] whose IndexedDB record is missing or not what is on disk.
## Through the page's `indexedDB` object and callbacks, never an eval: the player's page
## refuses `unsafe-eval` (see [method GSWeb.get_global]).
static func _idb_differs(db_name: String, want: Dictionary) -> GSResult:
	var idb: Variant = GSWeb.get_global("indexedDB")

	if idb == null or db_name == "":
		return GSResult.fail(GSError.CODE_UNSUPPORTED, "This page has no IndexedDB.")

	var tree := Engine.get_main_loop() as SceneTree
	# Containers, not scalars: a lambda captures a local by value (docs/gdscript-hazards).
	var state := {"db": null, "done": false, "error": ""}
	var request: Variant = idb.open(db_name)
	request.onsuccess = GSWeb.create_callback("gs_cloud_idb_open", func(_args: Array) -> void:
		state["db"] = request.result
		state["done"] = true
	)
	request.onerror = GSWeb.create_callback("gs_cloud_idb_open_error", func(_args: Array) -> void:
		state["error"] = "the database would not open"
		state["done"] = true
	)

	var give_up := Time.get_ticks_msec() + 10000

	while not state["done"] and Time.get_ticks_msec() < give_up:
		await tree.process_frame

	GSWeb.release_callback("gs_cloud_idb_open")
	GSWeb.release_callback("gs_cloud_idb_open_error")

	var db: Variant = state["db"]

	if db == null:
		return GSResult.fail(GSError.CODE_UNSUPPORTED, "The browser's copy of user:// could not be read.",
			str(state["error"]) if str(state["error"]) != "" else "no answer")

	# An empty database is one this call just created: the engine never had one, so nothing
	# written in this session is kept anywhere.
	if not bool(db.objectStoreNames.contains(IDB_STORE)):
		db.close()
		return GSResult.fail(GSError.CODE_UNSUPPORTED, "This page keeps nothing between loads.", db_name)

	var store: Variant = db.transaction(IDB_STORE, "readonly").objectStore(IDB_STORE)
	var differs: Array = []
	var answered: Array = []
	var bridge := GSWeb.bridge()

	for key: String in want:
		var ask: Variant = store.get(key)
		var name := "gs_cloud_idb_get_%d" % answered.size()
		answered.append(false)
		var slot := answered.size() - 1
		ask.onsuccess = GSWeb.create_callback(name, func(_args: Array) -> void:
			if not _Checks.record_matches(bridge, ask.result, want[key]):
				differs.append(key)
			answered[slot] = true
		)
		ask.onerror = GSWeb.create_callback(name + "_error", func(_args: Array) -> void:
			differs.append(key)
			answered[slot] = true
		)

	while answered.has(false) and Time.get_ticks_msec() < give_up:
		await tree.process_frame

	for i in answered.size():
		GSWeb.release_callback("gs_cloud_idb_get_%d" % i)
		GSWeb.release_callback("gs_cloud_idb_get_%d_error" % i)

	db.close()

	if answered.has(false):
		return GSResult.fail(GSError.CODE_TIMEOUT, "The browser's copy of user:// did not answer.")

	return GSResult.success(differs)

