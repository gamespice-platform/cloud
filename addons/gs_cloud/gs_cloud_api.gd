extends RefCounted

## GameSpice Cloud's API level. The rule for bumping it is on [GSAddonApi].
##
## LEVEL rises by one for anything a game or a tool could call that did not exist before.
## OLDEST is raised to LEVEL when something that could have been called is removed or
## changes meaning.

# 1: everything before this file existed (an absent file reads as 1).
# 2: GSCloudPublisher.extra_files (pack path -> file outside the source).
# 3: acquire refuses a pack whose requires.json asks for more than this build has BEFORE
#    downloading it (CODE_VERSION, no pack bytes fetched).
# 4: GSCloudPublisher.ship_import_sources (off: an imported asset's source is left out of
#    the pack; the CLI's --with-sources turns it back on).
# 5: provides in the manifest (GSCloudProvides), GSCloudScriptScan, GSCloudClient.session_tag / ensure_for_session
#    (uid_policy add_only, allow_root), mounted packs fill GSContentIndex. Needs GameSpice Core API 9.
# 6: GSCloudWorkshop (workshop/): the sync client, GSCloudWorkshopConfig / List / Device, registry name gs_workshop.
# 7: GSCloudWorkshop.client_platform / request_platform / force_platform (the site reviews
#    script packs per platform).
# 8: GSCloudFile.side (client / server, signed in the manifest), GSCloudConfig.side and
#    resolved_side(), GSCloudManifest.fetch_side / side_counts(), GSCloudPublisher.side_rules
#    and the source's sides.json. An older build ignores the field and fetches both sides.
# 9: GSCloudManifest.bundle (one ZIP of the small objects, signed), GSCloudPublisher.write_bundle,
#    GSCloudConfig.use_bundles; the HTTP source's fetch_bundle. An older client ignores the field.
# 10: GSCloudSliceLoader.loaded / named_class_scripts, GSCloudClient.warm_content (its on_progress callable).
# 11: GSCloudPublisher.script_tokens_dir (pre-tokenized .gdc + .gd.remap in place of .gd text).
# 12: GSCloudAutoUpdate / GSCloudAutoUpdateConfig (server/): a dedicated server restarts onto newer packs.
# 13: GSCloudMirrorList (the site's signed mirrors.json, key scope _platform/mirrors), GSCloudConfig.mirrors_url /
#     use_mirrors / prefetch_max_bytes / prefetch_max_packs / prefetch_on_web, GSCloudClient.load_mirror_list /
#     mirror_list / mirror_alternatives / prefetch / parse_prefetch, GSCloudSourceHttp.mirror_list / bases_for
#     (published mirrors before the origin, per-base demotion; the breaker counts files, not bases).
# 14: GSCloudMirrorList.parse_signed(bytes, trusted_keys, now_unix, newest_seen): refuses a signed list older than the
#     newest accepted (replay of an old mirror list).
# 15: GSCloudManifest.dependencies (signed {id, version} list), GSCloudPublisher.dependencies / CLI --depends;
#     GSCloudClient acquires them first (skipped when mounted or already in the store). An older build ignores the field.
# 16: GSCloudSuggested, GSCloudWorkshop.suggested, workshop_suggested (config), GSCloudWorkshopDevice.suggested_mode:
#     a game's suggested packs (its map packs) mount by default for a solo session, with opt-outs.
# 17: GSCloudSuggested.MODE_ASK / asks / device_choice / mode_for_choice, GSCloudWorkshop.set_device_suggested_mode:
#     the per-device Off / Ask / Auto switch for suggested packs; ask prompts once through ask_fn and a refusal skips only those.
# 18: GSCloudJobProgress, GSCloudClient.job / begin_job / end_job / job_progress_changed (one overall bar for a many-pack job).
# 19: GSCloudConfig.parallel_packs (default 4), GSCloudDownloaderPool, GSCloudClient.pool: a collection's dependencies download side by side.
# 20: GSCloudClient.job_register / job_register_manifest / job_download / job_begin_unpack / read_pack_file, GSCloudJobProgress.begin_unpack /
#     note_unpacked (snapshot gains phase, unpack_done, unpack_total), GSCloudWorkshop.defer_mount / mount_pending: one outer job whose total
#     is fixed up front, every download first and every mount after. Additive; a caller that never opens an outer job is unchanged.
# 21: GSCloudInventoryReport (the account site's downloaded-content report body and its pending actions) and the
#     bridge's `sync` op. Additive.
# 22: grouped files are mounted, not only downloaded: GSCloudMounter.mount's `groups` option and covers' groups,
#     GSCloudClient.ensure_groups_at (a game's per-map top-up) and GSCloudFile.ALL_GROUPS ("*", every group). Additive.
# 23: GSCloudClient.job_register / job_register_manifest take `groups`: an outer job counts and downloads them. Additive.
# 24: GSCloudAddonSet.groups: an addon overlay holds this side's files and the chosen groups (default every group). Additive.
# 25: groups.json rules also match an imported output relocated to _imported/ by the asset it stands for (as sides.json does). Additive.
# 26: GSCloudConfig.web_partials_dir / persisted_partials_dir / partials_persisted: on web, partials live in the
#     in-memory /tmp, outside the IndexedDB mirror whose sync they broke; commit moves across filesystems. Additive.
# 27: GSCloudSourceHttp retries a base after 429/5xx (throttle_retries, server_error_retries, backoff_base_sec,
#     backoff_max_sec; Retry-After honoured), download_with_backoff, backoff_delay, retry_limit, throttle_remaining_sec. Additive.
# 28: GSCloudWorkshop takes addon packs for a game whose accepts.kinds has "addon": summary.addons, addon_dirs,
#     addon_clash, addon_running, REASON_ADDON_UNAPPROVED; config workshop_max_addon_packs; max_packs 0 is no limit. Additive.
# 29: GSCloudAddonSet.mount_now / MountNow / SHELL_CLASSES_BUILD: mount the planned overlay in the running process
#     (what a shell does for a first visit whose overlay only adds addons). Additive.
# 30: GSCloudAddonSet.version_of / has_pack: the build's lock is found under the old
#     (`modcommunity/dot-<name>`) or the new (`gamespice-platform/<name>`) id, and `gamespice-platform/` is a default
#     namespace. Additive.
# 31: GSCloudConfig.limit_key / limit_hint, GSCloudStore describe() disk_free; a quota refusal names the limit, the
#     key that sets it, referenced bytes and the disk free. Additive.
# 32: GSCloudSliceLoader.cached_scripts and setting gs_cloud/warm/list_file: a pack's `warm.txt` names the scripts its
#     scene needs, the cover waits for those only and the rest compile behind it. Mount lines carry phase msec. Additive.
# 33: GSCloudStore.web_limit; GSCloudConfig.web_quota_fraction 0 means no share of the browser quota (only cache_bytes
#     and the measured free space limit a download). Additive.
# 34: GSCloudStore.make_room / GSCloudClient.make_room (evict what this process does not hold until the browser's measured
#     free space covers a download) and prune treats refs left by an earlier session as evictable, after unreferenced objects. Additive.
# 35: GSCloudClient.job_download(skip_preflight): download a launch job's packs without the requirements preflight, so a game's
#     pack can download beside the addon overlay it is checked against. Additive.
# 36: GSCloudAddonSet.late_pack: fetch the groups an overlay left out, pack them and mount them in place, so a web
#     shell can start on the early groups and top up in the background. Additive.
const LEVEL := 36
const OLDEST := 1
