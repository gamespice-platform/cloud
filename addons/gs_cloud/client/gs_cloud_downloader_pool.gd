class_name GSCloudDownloaderPool
extends RefCounted

## The downloaders of one [GSCloudClient]: packs download side by side, at most [member GSCloudConfig.parallel_packs] at once.
## One downloader runs one sync, so each concurrent pack needs its own, each with its own HTTPRequest pool (no threads, so it works on web).

## Most syncs seen running together; a test reads it to prove the cap held.
var peak := 0

var _slots: Array[GSCloudDownloader] = []
var _keys: Dictionary = {}  # downloader instance id -> content key
var _make: Callable  # (extra: bool) -> GSCloudDownloader
var _cap: Callable  # () -> int
signal _freed


func _init(first: GSCloudDownloader, make: Callable, cap: Callable) -> void:
	_slots.append(first)
	_make = make
	_cap = cap


func size() -> int:
	return _slots.size()


func running() -> int:
	return _keys.size()


func key_of(d: GSCloudDownloader) -> String:
	return str(_keys.get(d.get_instance_id(), ""))


func any_running() -> bool:
	for d in _slots:
		if d.is_running():
			return true
	return false


func cancel_all() -> void:
	for d in _slots:
		if d.is_running():
			d.cancel()


## Waits for a free downloader (making one while under the cap) and marks it as syncing [param key].
func take(key: String) -> GSCloudDownloader:
	while true:
		var cap := maxi(1, int(_cap.call()))
		if _keys.size() < cap:
			for d in _slots:
				if not _keys.has(d.get_instance_id()):
					return _claim(d, key)
			if _slots.size() < cap:
				var made: GSCloudDownloader = _make.call(true)
				_slots.append(made)
				return _claim(made, key)
		await _freed
	return null


func give_back(d: GSCloudDownloader) -> void:
	_keys.erase(d.get_instance_id())
	# Deferred so a waiter resumes after the caller has moved on; each waiter re-checks for a slot.
	_freed.emit.call_deferred()


func _claim(d: GSCloudDownloader, key: String) -> GSCloudDownloader:
	_keys[d.get_instance_id()] = key
	peak = maxi(peak, _keys.size())
	return d
